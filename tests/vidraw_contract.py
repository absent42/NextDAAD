#!/usr/bin/env python3
"""Host execution of the raw direct video reader (src/video.asm).

Runs the EMITTED bytes of build\\nextdaad.nex on the tests\\ddma_contract.py Z80 model, with
the MMU applied and port $EB fed by a model of the SD card's CMD18 stream: the cold schedule
generator (vid_raw_sched_build: slides, palette train, the dispatcher and classic schedule in
page A, the fast frame program in page B - the column train where the rule
nxv2_bench_rows.raw_variant fits one period, else inline sector opens - VR_BS1, VR_BPG and the
page switch stubs, against a reference emitter ref_fast, also with MMU writes one fetch late,
the train's read gaps, registers and counted T) and hot-cell
staging (vid_raw_stage), the raw frame decode (vid_raw_frame) with its sector opens, surface page
step, palette sector and frame tag (vr_sector, vr_sector_n, vr_sector_c, the inline page ends,
vid_raw_pal and the train), the raw sound section reader (vid_raw_pump and the schedule page's
VR_PUMP, against the baseline image's vid_aud_pump), with read spacing from a T trace
(io_gaps), the per-session operand patches (vid_stage_common.vec), the raw sound handlers on
the alternate set (video_ctc_isr_raw_st, video_ctc_isr_raw_mono: every ring start against a
reference, T per path), the play pointer helpers (vid_raw_rd_hl, vid_raw_rdv, vid_raw_prime), the
handler choice in vid_run_l2setup_body and CTC 0's IM2 table entry (raw handler from l2setup,
IM2_CTC_STUB again from vid_run_restore_body; the image's writers). DEBUG images only: the
frame loop's LATE and URUN counters (vid_dbg_late, vid_dbg_urun) and their call sites, and the RW1 bench session (the mode 5 route through
nxb_sess / nxb_ds_rows, nxb_rw_feed, the card rows' bodies and the binned token wait, the arm
kinds and DISARM, the log step's #HIST lines, an RFRAME row's MMU6 return chain, the play
log modes 16 and 17, nxb_entry's mode routes, the open-failure prints on NXB_PAGE behind
their cold stub) and nxb_geo_setup's hop to NXB_PAGE against
the baseline image in tests\\out\\vidraw-dma-base; each is skipped with a note where it is not
assembled.

    .\\build.ps1 (or .\\build.ps1 -Release)   then   python tests\\vidraw_contract.py

Exit 0 = every test passed (skips allowed). The variant read (DEBUG or Release) is printed.
"""
import bisect
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ddma_contract import CPU, Machine, fresh, expect           # noqa: E402,F401
from dma_contract import Fail, read_sld, read_page              # noqa: E402

SLOT = 8192
PHYS_PAGES = 256
SCHED_PAGE = 100            # the schedule bank's page (ring bank 50): page A
SCHED_PAGE_B = SCHED_PAGE + 1                   # its second page: the fast frame program
BACK_BANK = 30              # Layer 2 back surface: 16K banks 30-34 (pages 60-69)
SURF_LEN = 5 * 0x4000       # the 320x256 surface; 256x192 uses the first 48K
STACK = 0xBD00
RET = 0x0001
PORT_SPI = 0xEB
SURF_FILL = 0x55
DAC_L, DAC_R, DAC_M = 0xF3, 0xF9, 0xB3     # VID_DAC_LEFT, VID_DAC_RIGHT, VID_DAC_MONO
DAC_PORTS = (DAC_L, DAC_R, DAC_M)

SHAPES = [(0, 256, 192), (1, 320, 160), (1, 320, 192), (1, 280, 224), (1, 320, 240),
          (1, 256, 240)]
EXTRA = [(1, 320, 256), (1, 4, 1), (1, 320, 191), (0, 256, 1), (1, 280, 256), (0, 256, 100)]
# The train's corners: two check columns (Cp 64, partial), one pass (56, 8x32, 320x9), checks
# never taken (128x96), inline after a train that does not fit (256x14, 200x255).
TRAIN_GEOMS = [(1, 280, 56), (1, 64, 56), (1, 128, 96), (1, 8, 32), (1, 320, 9), (1, 256, 14),
               (1, 200, 255)]
FAST_GEOMS = list(dict.fromkeys(SHAPES + EXTRA + [(1, 320, 240), (1, 256, 240), (1, 280, 256),
                                                  (1, 4, 1), (0, 256, 167)]
                                + TRAIN_GEOMS))

SYMS = {}


def S(name):
    try:
        return SYMS[name][1]
    except KeyError:
        raise Fail(f"symbol {name} is not in the SLD - not built yet?") from None


class Stop(Exception):
    """Execution reached an observed entry (an abort funnel)."""

    def __init__(self, where, a):
        super().__init__(f"{where} reached with A=${a:02X}")
        self.where, self.a = where, a


class Skip(Exception):
    """The test does not apply to the image read."""


# --------------------------------------------------------------------------- card model

class Card:
    """Port $EB serving a CMD18 stream. Per sector: 2 CRC bytes when a sector was read
    before it (or crc_first), `waits` x $FF (a list: per sector), the token, then 512 data
    bytes. open_data: the tail of a sector that is already open (served first, then CRC
    before the next). Every read is logged with its phase and the reading instruction's
    address, and the page at MMU6 in pages."""

    def __init__(self, sectors=(), waits=0, crc_first=False, token=0xFE, open_data=None):
        self.stream, self.phase = bytearray(), []
        prior = crc_first
        if open_data is not None:
            self._add(open_data, "data")
            prior = True
        for i, blk in enumerate(sectors):
            if len(blk) != 512:
                raise Fail("card sector is not 512 bytes")
            if prior:
                self._add(b"\xC1\xC2", "crc")
            self._add(b"\xFF" * (waits[i] if isinstance(waits, (list, tuple)) else waits),
                      "wait")
            self._add(bytes([token]), "token")
            self._add(blk, "data")
            prior = True
        self.pos = 0
        self.log = []
        self.pages = []
        self.cpu = None

    def _add(self, bs, ph):
        self.stream += bytes(bs)
        self.phase += [ph] * len(bs)

    def read(self):
        if self.pos >= len(self.stream):
            raise Fail(f"card read past the end of the stream at ${self.cpu.at:04X}")
        v = self.stream[self.pos]
        self.log.append((self.phase[self.pos], self.cpu.at))
        self.pages.append(self.cpu.mc.mmu[6])
        self.pos += 1
        return v


def blocks(data, pad=0):
    data = bytes(data) + bytes([pad]) * ((-len(data)) % 512)
    return [data[i:i + 512] for i in range(0, len(data), 512)]


# --------------------------------------------------------------------------- Z80 model

def _in_a_n(c):
    n = c.imm8()
    c.a = c.mc.port_in(c.a << 8 | n)


def _out_n_a(c):
    n = c.imm8()
    c.mc.port_out(c.a << 8 | n, c.a)


def _exx(c):
    for r in "bcdehl":
        v = getattr(c, r)
        setattr(c, r, c.alt[r])
        c.alt[r] = v


def _ex_af(c):
    f = (c.fz, c.fc, c.fs)
    c.a, c.alt["a"] = c.alt["a"], c.a
    (c.fz, c.fc, c.fs), c.alt["f"] = c.alt["f"], f


def _di(c):
    c.iff = 0


def _ei(c):
    c.iff = 1


def _ini(c):
    v = c.mc.port_in(c.bc)
    c.m[c.hl] = v
    c.hl = (c.hl + 1) & 0xFFFF
    c.b = (c.b - 1) & 0xFF
    c.fz = 1 if c.b == 0 else 0


def _ldi(c):
    c.m[c.de] = c.m[c.hl]
    c.hl, c.de, c.bc = (c.hl + 1) & 0xFFFF, (c.de + 1) & 0xFFFF, (c.bc - 1) & 0xFFFF


def _reti(c):
    c.pc = c.pop()


def _swapnib(c):
    c.a = ((c.a << 4) | (c.a >> 4)) & 0xFF


def _ex_sp_hl(c):
    v = c.r16(c.sp)
    c.w16(c.sp, c.hl)
    c.hl = v


def _in_r_c(r):
    def h(c):
        v = c.mc.port_in(c.bc)
        if r != 6:
            c.setr(r, v)
        c.zs(v)
    return h


def _out_c_r(r):
    def h(c):
        c.mc.port_out(c.bc, 0 if r == 6 else c.getr(r))
    return h


def _dd(c):
    op = c.imm8()
    if op == 0x21:
        c.ix = c.imm16()
    elif op == 0x2A:
        c.ix = c.r16(c.imm16())
    else:
        raise Fail(f"opcode DD {op:02X} at ${c.at:04X} is not in the model")


EXT = {0xDB: _in_a_n, 0xD3: _out_n_a, 0xD9: _exx, 0x08: _ex_af, 0xF3: _di, 0xFB: _ei,
       0xE3: _ex_sp_hl, 0xDD: _dd}
ED_EXT = {0xA2: _ini, 0xA0: _ldi, 0x4D: _reti, 0x45: _reti, 0x23: _swapnib}
for _r in range(8):
    ED_EXT[0x40 | _r << 3] = _in_r_c(_r)
    ED_EXT[0x41 | _r << 3] = _out_c_r(_r)


class RawCPU(CPU):
    """ddma_contract's model plus the port, alternate-set and interrupt opcodes. IX and IY
    are held as values: of the DD/FD opcodes only ld ix,nn and ld ix,(nn) (the log step's
    esxDOS arguments) are modelled, so other code that touches them fails."""

    def __init__(self, machine):
        super().__init__(machine)
        self.at = 0
        self.iff = 1
        self.ix = self.iy = 0
        self.alt = {r: 0 for r in "bcdehla"}
        self.alt["f"] = (0, 0, 0)

    def out(self, port, v):
        self.mc.port_out(port, v)

    def step(self):
        at = self.pc
        self.at = at
        m = self.m
        op = m[at]
        if op == 0xED:
            h = ED_EXT.get(m[(at + 1) & 0xFFFF])
            if h is not None:
                self.pc = (at + 2) & 0xFFFF
                self.steps += 1
                h(self)
                return
        else:
            h = EXT.get(op)
            if h is not None:
                self.pc = (at + 1) & 0xFFFF
                self.steps += 1
                h(self)
                return
        super().step()


class RawMachine(Machine):
    """64K view over 2 MB of physical pages with the MMU applied: a slot's page is copied
    into the view when mapped and written back when unmapped (no page sits in two slots)."""

    def __init__(self, syms, pages=None):
        self.syms = syms
        self.phys = bytearray(PHYS_PAGES * SLOT)
        for p in (4, 5, self.sym("VID_PAGE"), self.sym("VID_PAGE2")):
            self.phys[p * SLOT:(p + 1) * SLOT] = (pages or read_page)(p)
        self.mem = bytearray(0x10000)
        self.mmu = [0, 1, 10, 11, 4, 5, 12, self.sym("VID_PAGE")]
        for s, p in enumerate(self.mmu):
            self.mem[s * SLOT:(s + 1) * SLOT] = self.phys[p * SLOT:(p + 1) * SLOT]
        self.nr = {}
        self.nrlog = []
        self.mmu_writes = []
        self.sel = 0
        self.card = None
        self.dac = None             # a list: DAC port writes (low byte, value) are logged
        self.cpu = RawCPU(self)

    def map(self, slot, page):
        if page in self.mmu and self.mmu.index(page) != slot:
            raise Fail(f"page {page} mapped in slot {slot} while slot "
                       f"{self.mmu.index(page)} holds it")
        b = slot * SLOT
        old = self.mmu[slot]
        self.phys[old * SLOT:(old + 1) * SLOT] = self.mem[b:b + SLOT]
        self.mmu[slot] = page
        self.mem[b:b + SLOT] = self.phys[page * SLOT:(page + 1) * SLOT]

    def sync(self):
        for s, p in enumerate(self.mmu):
            self.phys[p * SLOT:(p + 1) * SLOT] = self.mem[s * SLOT:(s + 1) * SLOT]

    def load_phys(self, addr, data):
        self.sync()
        self.phys[addr:addr + len(data)] = data
        for s, p in enumerate(self.mmu):
            self.mem[s * SLOT:(s + 1) * SLOT] = self.phys[p * SLOT:(p + 1) * SLOT]

    def nextreg(self, n, v):
        self.nr[n] = v
        self.nrlog.append((n, v))
        if 0x50 <= n <= 0x57:
            self.mmu_writes.append((n, v))
            self.map(n - 0x50, v)

    def port_in(self, port):
        if port & 0xFF == PORT_SPI and self.card is not None:
            return self.card.read()
        raise Fail(f"read of port ${port:04X} at ${self.cpu.at:04X}")

    def port_out(self, port, v):
        if port == 0x243B:
            self.sel = v
        elif port == 0x253B:
            self.nextreg(self.sel, v)
        elif self.dac is not None and port & 0xFF in DAC_PORTS:
            self.dac.append((port & 0xFF, v))
        else:
            raise Fail(f"write to port ${port:04X} at ${self.cpu.at:04X}")

    def set_card(self, card):
        self.card = card
        card.cpu = self.cpu

    def peek(self, name, n=1):
        a = S(name)
        v = self.mem[a:a + n]
        return v[0] if n == 1 else int.from_bytes(v, "little")

    def run(self, name, traps=None, budget=3_000_000, **regs):
        cpu = self.cpu
        for k, v in regs.items():
            setattr(cpu, k, v)
        cpu.sp = STACK
        cpu.push(RET)
        cpu.pc = S(name) if isinstance(name, str) else name
        traps = dict(traps or {})
        while cpu.pc != RET:
            t = traps.get(cpu.pc)
            if t is not None:
                t(cpu)
                continue
            budget -= 1
            if budget <= 0:
                raise Fail(f"{name} did not return")
            cpu.step()
        self.sync()
        return cpu


def aborts():
    """Stop at either abort entry. Release has no position capture, so both labels share
    one address there and the stop names both."""
    def stop(where):
        def t(cpu):
            raise Stop(where, cpu.a)
        return t
    a, b = S("vid_dec_abort"), S("vid_dec_abort_pos")
    if a == b:
        return {a: stop("vid_dec_abort/vid_dec_abort_pos")}
    return {a: stop("vid_dec_abort"), b: stop("vid_dec_abort_pos")}


def reached(e, name):
    return name in e.where.split("/")


def ret_trap(fn):
    """A trap that runs fn(cpu) and returns to the caller."""
    def t(cpu):
        fn(cpu)
        cpu.pc = cpu.pop()
    return t


def forbid(name):
    def t(cpu):
        raise Fail(f"{name} entered")
    return {S(name): t}


# --------------------------------------------------------------------------- helpers

def geom(code, w, h):
    x0 = (320 - w) // 2 if code else 0
    return x0, -(-w * h // 512)


def pixels(n):
    return bytes((i * 7 + 3) & 255 for i in range(n))


def build_sched(mc, code, w, h, x0=None):
    if x0 is None:
        x0, _ = geom(code, w, h)
    mc.map(7, S("VID_PAGE2"))
    mc.map(6, SCHED_PAGE)
    mc.poke("vidRingBanksC", SCHED_PAGE // 2)
    mc.poke("vidP_Shape", code)
    mc.poke("vidP_HeightB", h & 0xFF)
    mc.poke16("vidP_RawW", w)
    mc.poke("vidP_RawX0", x0)
    return mc.run("vid_raw_sched_build", traps=aborts())


def setup_frame(mc, code, w, h, tag=0, remain=0x012345, crc_due=0):
    x0, sectors = geom(code, w, h)
    mc.map(7, S("VID_PAGE"))
    mc.poke("vidRawSchedPage", SCHED_PAGE)
    mc.poke("vidRawSec", sectors)
    mc.poke("vidRawCap", sectors + 1)
    mc.poke("vidRawTag", tag)
    mc.poke("vidRawPage0", x0 >> 5)
    mc.poke("vidRawH0", 0x40 + (x0 & 31))
    mc.poke("l2BackBank", BACK_BANK)
    mc.poke("vidStrmRemainBlk", remain.to_bytes(3, "little"))
    mc.poke16("vidStrmRunBlkH", 0xFFFF)
    mc.poke("vidDsCrcDue", crc_due)
    mc.poke("vidDsFrmBlk", 0)
    mc.poke("vidPalCtrl", 0)
    mc.poke("vidPalPending", 0)
    mc.load_phys(BACK_BANK * 0x4000, bytes([SURF_FILL]) * SURF_LEN)
    return x0, sectors


def want_surface(code, w, h, x0, px):
    want = bytearray([SURF_FILL]) * SURF_LEN
    if code == 0:
        want[:w * h] = px
    else:
        for c in range(w):
            o = (x0 + c) * 256
            want[o:o + h] = px[c * h:(c + 1) * h]
    return bytes(want)


def hot_cells():
    """VID_PAGE offsets a frame may write (the cells it owns or shares)."""
    out = set()
    for name, n in (("vidStrmRemainBlk", 3), ("vidDsFrmBlk", 1), ("vidDstPage", 1),
                    ("vidDstEnd", 1), ("vidDsCrcDue", 1), ("vidStrmRunBlkH", 2),
                    ("vidPalPending", 1), ("vidRawTag", 1), ("vidRlDiv", 1),
                    ("vidRlSpinDiv", 1), ("vidRlLast", 2), ("vidRlFields", 2),
                    ("vidTokPolls", 2), ("vidTokCalls", 2), ("vr_sector_n", 2)):
        if name in SYMS:
            a = SYMS[name][1]
            out |= {(a & 0x1FFF) + k for k in range(n)}
    return out


def stray_writes(before, after, allow):
    """allow: page -> predicate(offset), or True for any. Pages absent must not change."""
    for p in range(PHYS_PAGES):
        o, n = before[p * SLOT:(p + 1) * SLOT], after[p * SLOT:(p + 1) * SLOT]
        ok = allow.get(p)
        if o == n or ok is True:
            continue
        for k in range(SLOT):
            if o[k] != n[k] and (ok is None or not ok(k)):
                raise Fail(f"stray write: page {p} +${k:04X} ${o[k]:02X} -> ${n[k]:02X}")


def frame_allow(extra_sched=None):
    hot = hot_cells()
    scr = S("VR_SCRATCH") - S("VR_SLIDE")
    allow = {S("VID_PAGE"): lambda k: k in hot,
             5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000,
             SCHED_PAGE: lambda k: scr <= k < scr + 512}
    for p in range(BACK_BANK * 2, BACK_BANK * 2 + 10):
        allow[p] = True                    # the surface: compared exactly elsewhere
    return allow


def run_frame(mc, code, w, h, tag=0, waits=1, crc_due=0, pad=0, pal=None, remain=0x012345,
              paths=None):
    """Build the schedule, play one frame, check the surface and every other write. paths: a
    list path_traps fills."""
    cpu = build_sched(mc, code, w, h)
    if cpu.fc:
        raise Fail(f"{code},{w}x{h}: vid_raw_sched_build set CF")
    x0, sectors = setup_frame(mc, code, w, h, tag=tag, remain=remain, crc_due=crc_due)
    px = pixels(w * h)
    data = blocks(px, pad)
    if tag:
        data = [pal] + data
    card = Card(data, waits=waits, crc_first=bool(crc_due))
    mc.set_card(card)
    mc.sync()
    before = bytes(mc.phys)
    cpu = mc.run("vid_raw_frame", traps={**aborts(), **(path_traps(mc, paths)
                                                         if paths is not None else {})})
    if cpu.a != S("VOP_KFLIP"):
        raise Fail(f"{code},{w}x{h}: A=${cpu.a:02X}, expected VOP_KFLIP")
    if card.pos != len(card.stream):
        raise Fail(f"{code},{w}x{h}: {len(card.stream) - card.pos} card bytes left unread")
    base = BACK_BANK * 0x4000
    expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
           f"{code},{w}x{h} back surface")
    stray_writes(before, bytes(mc.phys), frame_allow())
    if mc.peek("vidDsFrmBlk") != sectors + 1:
        raise Fail(f"{code},{w}x{h}: vidDsFrmBlk = {mc.peek('vidDsFrmBlk')}, expected "
                   f"vidRawCap {sectors + 1}")
    return card, sectors, x0


# The schedule's page end: inc e / ld a,e / nextreg NR_MMU2,a / ld h,high VID_DST_WIN.
PAGE_END = bytes([0x1C, 0x7B, 0xED, 0x92, 0x52, 0x26, 0x40])


def ref_open(debug=None):
    """The inline sector open the generator emits for sectors 2..n of the fast program."""
    debug = plain_debug() if debug is None else debug
    return (b"\xDB\xEB\x00\xDB\xEB" + b"\xBE" * S("VR_POLL_PAD_N") + b"\xDB\xEB\x3C\xC4"
            + le(S("VR_BS1")) + b"\xDB\xEB\xFE\xFE\xC4" + le(S("vr_sector_n.s2"))
            + (b"\x16\x00\xCD" + le(S("vid_dst_norm_flat")) if debug else b""))


def raw_items(code, w, h, x0):
    """The generator's rules: ([("sector",), ("read", n), ("colend",), ("page",),
    ("open",) ...], the last sector's pad bytes). A read is min(sector, segment, pixels
    left); a segment is a column of h (gapped) or a page (flat, the first 32 - x0 & 31
    columns long); a page end follows the last column of a page."""
    gapped = code != 0 and h & 0xFF != 0
    pix, cols = w * h, 32 - (x0 & 31)
    seg, seglen = (h, h) if gapped else (cols * 256, 0x2000)
    sec, out = 512, [("sector",)]
    while True:
        n = min(sec, seg, pix)
        out.append(("read", n))
        sec, seg, pix = sec - n, seg - n, pix - n
        if not pix:
            return out, sec
        if not seg:
            seg = seglen
            if gapped:
                out.append(("colend",))
                cols -= 1
            if not gapped or not cols:
                cols = 32
                out.append(("page",))
        if not sec:
            sec = 512
            out.append(("open",))


HOP = b"\x2E\x00\x24"                   # ld l,0 / inc h: a column end


def ref_train(code, w, h, x0=None, debug=None):
    """The column train by the rule's emission (nxv2_bench_rows.raw_train), page B from
    DATA_WINDOW: at each period offset 0..Lp, at a column end its hop, then a check (more than
    one pass, a check column) or a page end (one pass, a page's last column); at a sector start
    a nop (not the first) and the open; each byte an ini; then ret and the driver. -> (bytes,
    the driver's address, the patch address or None); None when the rule has no train (a flat
    surface)."""
    import nxv2_bench_rows as bench
    if x0 is None:
        x0, _ = geom(code, w, h)
    r = bench.raw_train(code, w, h, x0)
    if r is None:
        return None
    opn, dw = ref_open(debug), S("VR_SLIDE")
    hh = h & 0xFF or 256
    multi = r["passes"] > 1
    chk = b"\xCB\x6C\xC4" + le(S("VR_BPG"))
    out, pa = bytearray(), None
    for o in range(r["Lp"] + 1):
        start = len(out)
        if o and o % hh == 0:
            j = o // hh
            out += HOP
            if multi and j < r["Cp"] and (j - r["c0"]) % r["m"] == 0:
                out += chk
            if not multi and j < r["cols"] and (j - r["c0"]) % 32 == 0:
                out += PAGE_END
        if o < r["Lp"] and o % 512 == 0:
            out += (b"\x00" if o else b"") + opn
        if o < r["Lp"]:
            out += b"\xED\xA2"
        if r["partial"] and o == r["patch"]:
            pa = dw + start
    out += b"\xC9"
    drv = dw + len(out)
    out += b"\xCD" + le(S("vr_sector")) + b"\xCD" + le(dw + len(opn))
    for p in range(1, r["passes"]):
        if (p * r["Cp"] - r["c0"]) % 32 == 0:
            out += PAGE_END
        if p == r["passes"] - 1 and r["partial"]:
            out += b"\x3E\xC9\x32" + le(pa)
        out += b"\xCD" + le(dw)
    if r["partial"]:
        out += b"\x3E" + bytes([out[pa - dw]]) + b"\x32" + le(pa)
    out += b"\xC3" + le(S("VR_XOUT"))
    return bytes(out), drv, pa


def ref_fast(code, w, h, x0=None, debug=None):
    """The executable form of the fast program's rules: {a: page A from VR_SCHED (dispatcher,
    classic schedule, VR_TAILA), b: page B from VR_SLIDE (slide and inline program, or the
    train), stub: the 16 stub bytes of both pages, bs1: VR_BS1's 12 and VR_BPG's 8, taila:
    VR_TAILA's address, var: the variant, attempt: an inline geometry's train bytes (the
    generator tries it first: page B may hold their prefix past the program), patch}."""
    import nxv2_bench_rows as bench
    if x0 is None:
        x0, _ = geom(code, w, h)
    items, pad = raw_items(code, w, h, x0)
    end = S("VR_SLIDE_END")
    opn = ref_open(debug)

    def enc(it, inline):
        k = it[0]
        if k == "sector":
            return b"\xCD" + le(S("vr_sector"))
        if k == "read":
            return b"\xCD" + le(end - 2 * it[1])
        if k == "colend":
            return b"\x2E\x00\x24"
        if k == "page":
            return PAGE_END
        return opn if inline else b"\xCD" + le(S("vr_sector_n"))
    tail = (b"\x21" + le(S("VR_SCRATCH")) + b"\xCD" + le(end - 2 * pad) if pad else b"") + b"\xC9"
    classic = b"".join(enc(i, False) for i in items) + tail
    disp = b"\x3A" + le(S("vr_sector_n")) + b"\xFE\xDB\xCA" + le(S("VR_XIN"))
    taila = S("VR_CLASSIC") + len(classic)
    prog = b"".join(enc(i, True) for i in items) + b"\xC3" + le(S("VR_XOUT"))
    var = bench.raw_variant(code, w, h, x0)
    tr = ref_train(code, w, h, x0, debug)
    b, drv, attempt, patch = b"\xED\xA2" * 512 + b"\xC9" + prog, S("VR_PROG"), None, None
    if var == "train":
        b, drv, patch = tr
    elif tr is not None and 2 * bench.raw_train(code, w, h, x0)["Lp"] <= bench.VR_TRAIN_ROOM:
        attempt = tr[0]                 # tried; a longer period is refused before any byte
    stub = (b"\xED\x91\x56" + bytes([SCHED_PAGE_B]) + b"\xC3" + le(drv) + b"\x00"
            + b"\xED\x91\x56" + bytes([SCHED_PAGE]) + b"\xC3" + le(taila) + b"\x00")
    bs1 = (b"\xFE\xFF\xC2" + le(S("vr_sector_n.tokf")) + b"\xE3\xED\x34\x07\x00\xE3\xC9"
           + PAGE_END + b"\xC9")
    return dict(a=disp + classic + tail, b=b, stub=stub, bs1=bs1, taila=taila, var=var,
                attempt=attempt, patch=patch, drv=drv)


def parse_items(mc, page, start, limit):
    """[(kind, value, addr)] from start in page to the program's last item; kind: read
    (value n), sector, sectorn (call vr_sector_n), open (the inline open), page (PAGE_END),
    colend, ldhl (value operand), ret, xout (jp VR_XOUT). -> (items, the address after)."""
    base = page * SLOT - S("VR_SLIDE")
    ph = mc.phys
    a, out = start, []
    end, slide_end = limit, S("VR_SLIDE_END")
    opn = ref_open()
    while True:
        if a + 3 > end:
            raise Fail(f"page {page}'s program runs to ${a:04X}, past ${limit:04X}")
        b, v = ph[base + a], ph[base + a + 1] | ph[base + a + 2] << 8
        if bytes(ph[base + a:base + a + 7]) == PAGE_END:
            out.append(("page", 0, a))
            a += 7
        elif bytes(ph[base + a:base + a + len(opn)]) == opn:
            out.append(("open", 0, a))
            a += len(opn)
        elif b == 0xC3 and v == S("VR_XOUT"):
            out.append(("xout", 0, a))
            return out, a + 3
        elif b == 0xCD:
            if v == S("vr_sector"):
                out.append(("sector", v, a))
            elif v == S("vr_sector_n"):
                out.append(("sectorn", v, a))
            elif S("VR_SLIDE") <= v < slide_end and (slide_end - v) % 2 == 0:
                out.append(("read", (slide_end - v) // 2, a))
            else:
                raise Fail(f"schedule call to ${v:04X} at ${a:04X}")
            a += 3
        elif b == 0x2E and ph[base + a + 1] == 0x00 and ph[base + a + 2] == 0x24:
            out.append(("colend", 0, a))
            a += 3
        elif b == 0x21:
            out.append(("ldhl", v, a))
            a += 3
        elif b == 0xC9:
            out.append(("ret", 0, a))
            return out, a + 1
        else:
            raise Fail(f"page {page} program byte ${b:02X} at ${a:04X}")


def parse_sched(mc):
    """The classic schedule: parse_items from VR_CLASSIC to its ret (page A)."""
    return parse_items(mc, SCHED_PAGE, S("VR_CLASSIC"), S("VR_SCHED_LIMIT"))


def built_var(mc):
    """The variant the last vid_raw_sched_build chose (vrgVar): 'train' or 'inline'."""
    mc.sync()
    return "train" if mc.phys[S("VID_PAGE2") * SLOT + (S("vrgVar") & 0x1FFF)] else "inline"


def fast_entry(mc):
    """Page B's VR_XJP operand: VR_PROG, or the train's driver."""
    mc.sync()
    o = SCHED_PAGE_B * SLOT + S("VR_XJP") + 1 - S("VR_SLIDE")
    return mc.phys[o] | mc.phys[o + 1] << 8


def parse_train(mc):
    """The column train in page B from DATA_WINDOW, [(kind, value, addr)]: the period (open,
    pad, ini (value: the run's length), colend, check, page, ret), then the driver (sector,
    enter (the call past the period's first open), page, patch (value: (byte, address)),
    call (the period), xout). -> (items, the address after)."""
    base, ph = SCHED_PAGE_B * SLOT - S("VR_SLIDE"), mc.phys
    opn, dw = ref_open(), S("VR_SLIDE")
    chk = b"\xCB\x6C\xC4" + le(S("VR_BPG"))
    a, out, period = dw, [], True

    def at(n, k=0):
        return bytes(ph[base + a + k:base + a + k + n])
    while a < S("VR_BEND"):
        b, v = ph[base + a], ph[base + a + 1] | ph[base + a + 2] << 8
        if period and at(2) == b"\xED\xA2":
            n = 1
            while at(2, 2 * n) == b"\xED\xA2":
                n += 1
            out.append(("ini", n, a))
            a += 2 * n
            continue
        for kind, pat in (("open", opn), ("colend", HOP), ("check", chk), ("page", PAGE_END)):
            if (period or kind == "page") and at(len(pat)) == pat:
                out.append((kind, 0, a))
                a += len(pat)
                break
        else:
            if period and b == 0 and at(len(opn), 1) == opn:
                out.append(("pad", 0, a))
                a += 1
            elif period and b == 0xC9:
                out.append(("ret", 0, a))
                a, period = a + 1, False
            elif not period and b == 0xCD and v in (S("vr_sector"), dw + len(opn), dw):
                out.append(({S("vr_sector"): "sector", dw: "call"}.get(v, "enter"), v, a))
                a += 3
            elif not period and b == 0x3E and ph[base + a + 2] == 0x32:
                out.append(("patch", (v & 0xFF, ph[base + a + 3] | ph[base + a + 4] << 8), a))
                a += 5
            elif not period and b == 0xC3 and v == S("VR_XOUT"):
                out.append(("xout", 0, a))
                return out, a + 3
            else:
                raise Fail(f"train byte ${b:02X} at ${a:04X} ({'period' if period else 'driver'})")
    raise Fail("the train runs to VR_BEND")


def parse_fast(mc):
    """The fast program: the inline program (parse_items from VR_PROG to its jp VR_XOUT) or
    the train (parse_train), as the build chose (page B)."""
    if built_var(mc) == "train":
        return parse_train(mc)
    return parse_items(mc, SCHED_PAGE_B, S("VR_PROG"), S("VR_BEND"))


def owner_fn(mc):
    """Map an instruction address to the routine holding it, 'slide', 'paltrain' (the
    schedule page's VR_PALTRAIN .. VR_PALTRAIN + VR_PAL_LEN - 1) or 'pump' (VR_PUMP ..
    VR_PUMP + VR_PUMP_LEN - 1); with page B at MMU6 (page given), 'slide' or 'fast' (the
    inline program, VR_PROG .. VR_BEND - 1), or 'column' (the train, below VR_BEND)."""
    hot = S("VID_PAGE")
    labels = sorted((v, n) for n, (p, v) in SYMS.items()
                    if p == hot and "." not in n and 0xE000 <= v < 0x10000)
    addrs = [v for v, _ in labels]
    lo, hi = S("VR_SLIDE"), S("VR_SLIDE_END")
    col = built_var(mc) == "train"
    train = []

    def owner(pc, page=None):
        if page == SCHED_PAGE_B and pc < 0xE000:
            if col:
                return "column" if pc < S("VR_BEND") else "?"
            if lo <= pc < hi:
                return "slide"
            return "fast" if S("VR_PROG") <= pc < S("VR_BEND") else "?"
        if lo <= pc < hi:
            return "slide"
        if pc < 0xE000:
            if not train:
                train.extend((S("VR_PALTRAIN"), S("VR_PALTRAIN") + S("VR_PAL_LEN"),
                              S("VR_PUMP"), S("VR_PUMP") + S("VR_PUMP_LEN")))
            if train[2] <= pc < train[3]:
                return "pump"
            return "paltrain" if train[0] <= pc < train[1] else "?"
        i = bisect.bisect_right(addrs, pc) - 1
        return labels[i][1] if i >= 0 else "?"
    return owner


ALLOWED = {"crc": {"vr_sector", "vr_sector_n", "vr_sector_c", "fast", "column"},
           "wait": {"vr_sector_n", "vid_sd_tok_h", "fast", "column"},
           "token": {"vr_sector_n", "vid_sd_tok_h", "fast", "column"},
           "data": {"slide", "paltrain", "column"}}

# The palette train vid_raw_sched_build writes at VR_PALTRAIN: 512 x in a,(PORT_SPI_DAT) /
# out (c),a, then ret.
TRAIN = b"\xDB\xEB\xED\x79" * 512 + b"\xC9"


def check_log(mc, card, what):
    owner = owner_fn(mc)
    for i, (ph, pc) in enumerate(card.log):
        who = owner(pc, card.pages[i])
        if who not in ALLOWED[ph]:
            raise Fail(f"{what}: card read {i} ({ph}) by {who} at ${pc:04X} (MMU6 page "
                       f"{card.pages[i]})")


def path_traps(mc, log):
    """Traps recording (where, MMU6) on entering VR_CLASSIC with page A or page B's program
    (VR_XJP's target: VR_PROG or the train's driver) with page B (each steps on): which program
    a frame ran."""
    def t(name, page):
        def h(cpu):
            if mc.mmu[6] == page:
                log.append(name)
            cpu.step()
        return h
    return {S("VR_CLASSIC"): t("classic", SCHED_PAGE), fast_entry(mc): t("fast", SCHED_PAGE_B)}


# --------------------------------------------------------------------------- tests

def test_sched_pixels():
    for i, (code, w, h) in enumerate(SHAPES + EXTRA):
        mc = RawMachine(SYMS)
        card, sectors, _ = run_frame(mc, code, w, h, waits=i % 3)
        check_log(mc, card, f"{code},{w}x{h}")


def test_sched_reads():
    for code, w, h in ((1, 320, 192), (0, 256, 192), (1, 280, 224)):
        for crc_due in (0, 1):
            mc = RawMachine(SYMS)
            card, sectors, _ = run_frame(mc, code, w, h, waits=0, crc_due=crc_due)
            want = sectors * (1 + 512) + (sectors - 1 + crc_due) * 2
            if len(card.log) != want:
                raise Fail(f"{code},{w}x{h} crc_due {crc_due}: {len(card.log)} card reads, "
                           f"expected {want}")
            if mc.peek("vidDsCrcDue") != 1:
                raise Fail(f"{code},{w}x{h}: vidDsCrcDue = {mc.peek('vidDsCrcDue')} on exit")
            check_log(mc, card, f"{code},{w}x{h}")


def test_sched_shape():
    """VR_SCHED is the dispatcher (ld a, (vr_sector_n) / cp $DB / jp z, VR_XIN) and the
    classic schedule follows at VR_CLASSIC. 320x192: 9 inline page ends (PAGE_END), each
    right after a column end (L = 0); 256x192 (flat): 5, each right after a read. Page B's
    inline program (320x240, 256x240, 320x191, 256x14: no train) has the classic's items with
    each call vr_sector_n an inline open, ending jp VR_XOUT in place of the pad tail."""
    mc = RawMachine(SYMS)
    cpu = build_sched(mc, 1, 320, 192)
    if cpu.fc:
        raise Fail("320x192: CF set")
    o = SCHED_PAGE * SLOT + S("VR_SCHED") - S("VR_SLIDE")
    disp = b"\x3A" + le(S("vr_sector_n")) + b"\xFE\xDB\xCA" + le(S("VR_XIN"))
    if (bytes(mc.phys[o:o + 8]), S("VR_DISP_LEN"), S("VR_CLASSIC") - S("VR_SCHED")) \
            != (disp, 8, 8):
        raise Fail(f"VR_SCHED holds {bytes(mc.phys[o:o + 8]).hex(' ')}, expected the "
                   f"dispatcher {disp.hex(' ')}; VR_DISP_LEN {S('VR_DISP_LEN')}")
    for build in ((1, 320, 240), (1, 256, 240), (1, 320, 191), (1, 256, 14)):
        build_sched(mc, *build)
        if built_var(mc) != "inline":
            raise Fail(f"{build}: built the train")
        cls = [(k, v) for k, v, _ in parse_sched(mc)[0]][:-1]          # less the ret
        if len(cls) > 2 and cls[-2][0] == "ldhl":
            cls = cls[:-2]                                             # less the pad read
        want = [("open", 0) if k == "sectorn" else (k, v) for k, v in cls] + [("xout", 0)]
        fast = [(k, v) for k, v, _ in parse_fast(mc)[0]]
        if fast != want:
            raise Fail(f"{build}: page B's {len(fast)} items do not follow the classic's "
                       f"{len(want) - 1} (last {fast[-1]})")
    build_sched(mc, 1, 320, 192)
    items, _ = parse_sched(mc)
    kinds = [k for k, _, _ in items]
    got = {k: kinds.count(k) for k in ("read", "sector", "sectorn", "colend", "page", "ldhl")}
    want = {"read": 400, "sector": 1, "sectorn": 119, "colend": 319, "page": 9, "ldhl": 0}
    if got != want or kinds[0] != "sector" or kinds[-1] != "ret":
        raise Fail(f"320x192 schedule: {got}, first {kinds[0]}, last {kinds[-1]}; expected "
                   f"{want}, vr_sector first, ret last")
    calls = ("read", "sector", "sectorn", "page")
    for i, k in enumerate(kinds):
        if k == "colend" and not (kinds[i - 1] in calls and kinds[i + 1] in calls):
            raise Fail(f"320x192: column end at ${items[i][2]:04X} not between two calls")
        if k == "page" and kinds[i - 1] != "colend":
            raise Fail(f"320x192: page end at ${items[i][2]:04X} after {kinds[i - 1]}")
    if sum(v for k, v, _ in items if k == "read") != 320 * 192:
        raise Fail("320x192: the reads do not add up to the picture")
    build_sched(mc, 0, 256, 192)
    items, _ = parse_sched(mc)
    kinds = [k for k, _, _ in items]
    reads = [v for k, v, _ in items if k == "read"]
    if (kinds.count("sector"), kinds.count("sectorn"), len(reads), set(reads),
            kinds.count("page"), kinds.count("colend")) \
            != (1, 95, 96, {512}, 5, 0) \
            or any(kinds[i - 1] != "read" for i, k in enumerate(kinds) if k == "page"):
        raise Fail(f"256x192 schedule: {kinds.count('sector')} + {kinds.count('sectorn')} "
                   f"sector, {len(reads)} reads {sorted(set(reads))}, "
                   f"{kinds.count('page')} page, {kinds.count('colend')} colend")
    if kinds[0] != "sector" or kinds[-1] != "ret":
        raise Fail("256x192: the schedule does not open with vr_sector and end with ret")


def test_sched_pad():
    """280x224: the classic schedule and VR_TAILA after it both end ld hl, VR_SCRATCH /
    call (the 256 pad bytes) / ret; a frame (page B) leaves the pad in VR_SCRATCH."""
    mc = RawMachine(SYMS)
    build_sched(mc, 1, 280, 224)
    _, end = parse_sched(mc)
    base = SCHED_PAGE * SLOT - S("VR_SLIDE")
    tail = bytes(mc.phys[base + end - 7:base + end])
    taila = bytes(mc.phys[base + end:base + end + 7])
    scr, rd = S("VR_SCRATCH"), S("VR_SLIDE_END") - 512
    want = bytes([0x21, scr & 255, scr >> 8, 0xCD, rd & 255, rd >> 8, 0xC9])
    if tail != want or taila != want:
        raise Fail(f"280x224 schedule ends {tail.hex(' ')}, VR_TAILA {taila.hex(' ')}; "
                   f"expected {want.hex(' ')} both")
    mc = RawMachine(SYMS)
    run_frame(mc, 1, 280, 224, pad=0xAA)
    o = SCHED_PAGE * SLOT + scr - S("VR_SLIDE")
    expect(mc.phys[o:o + 256], b"\xAA" * 256, "280x224 pad in VR_SCRATCH")


def train_at(mc):
    """The VR_PAL_LEN bytes at VR_PALTRAIN in the schedule page (physical)."""
    o = SCHED_PAGE * SLOT + S("VR_PALTRAIN") - S("VR_SLIDE")
    return bytes(mc.phys[o:o + S("VR_PAL_LEN")])


def page_b_allow(k):
    """Page B offsets the generator may write: the slide and program (or the train), VR_BS1,
    VR_BPG and the stub bytes: all of it."""
    return 0 <= k < SLOT


def gen_allow(sched, page_b=page_b_allow):
    """stray_writes allowance for a vid_raw_sched_build run: the generator's cells on
    VID_PAGE2, the stack, sched (a predicate) on the schedule page, page_b on its second
    page (None: no write)."""
    gen = set()
    for name in SYMS:
        if name.startswith("vrg") or name.startswith("vidP_"):
            gen |= {(SYMS[name][1] & 0x1FFF) + k for k in range(3)}
    return {S("VID_PAGE2"): lambda k: k in gen,
            5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000,
            SCHED_PAGE: sched, SCHED_PAGE_B: page_b}


def test_sched_limit():
    """VR_SCHED_LIMIT is VR_PUMP: no legal geometry's classic schedule and VR_TAILA reach it
    (the pump, the train and the stub bytes intact after every build), and no fast program
    reaches VR_BEND; an oversize geometry sets CF and writes nothing at or above VR_PUMP but
    those (the stub bytes zero), nothing in page B, nothing on VID_PAGE2 but the generator's
    cells."""
    lim = S("VR_PUMP")
    if S("VR_SCHED_LIMIT") != lim:
        raise Fail(f"VR_SCHED_LIMIT ${S('VR_SCHED_LIMIT'):04X} is not VR_PUMP ${lim:04X}")
    mc = RawMachine(SYMS)
    top, at, topb, atb = 0, None, 0, None
    for h in (1, 2, 191, 255):
        for w in range(4, 321, 4):
            cpu = build_sched(mc, 1, w, h)
            if cpu.fc:
                raise Fail(f"1,{w}x{h}: CF set for a legal geometry")
            built = (pump_template(), TRAIN, ref_fast(1, w, h)["stub"])
            items, end = parse_sched(mc)
            if sum(v for k, v, _ in items if k == "read") != w * h + (-w * h) % 512:
                raise Fail(f"1,{w}x{h}: the reads do not add up to the sectors")
            end += 7 if items[-2][0] == "read" and items[-3][0] == "ldhl" else 1   # VR_TAILA
            _, endb = parse_fast(mc)
            if end > lim or endb > S("VR_BEND") or page_top(mc) != built:
                raise Fail(f"1,{w}x{h}: page A end ${end:04X}, page B end ${endb:04X}, (pump, "
                           f"train, stub) intact {[a == b for a, b in zip(page_top(mc), built)]}"
                           f" (VR_PUMP ${lim:04X})")
            if end > top:
                top, at = end, (w, h)
            if endb > topb:
                topb, atb = endb, (w, h)
    print(f"  test_sched_limit: largest page A end ${top:04X} ({at[0]}x{at[1]}), limit VR_PUMP "
          f"${lim:04X}; largest page B end ${topb:04X} ({atb[0]}x{atb[1]}), VR_BEND "
          f"${S('VR_BEND'):04X}")
    # oversize synthetic geometry: CF set and nothing at or past the limit but the pump, the
    # train and the stub bytes
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE2"))
    mc.sync()
    before = bytes(mc.phys)
    cpu = build_sched(mc, 1, 1020, 255, x0=0)
    if not cpu.fc:
        raise Fail("1,1020x255: CF clear for an oversize schedule")
    off, after = lim - S("VR_SLIDE"), bytes(mc.phys)
    page = after[SCHED_PAGE * SLOT:(SCHED_PAGE + 1) * SLOT]
    gap = S("VR_PALTRAIN") - lim - len(pump_template())
    want = pump_template() + bytes(gap) + TRAIN + bytes(S("VR_XSTUB_LEN"))
    if page[off:] != want or mc.mmu[6] != SCHED_PAGE:
        raise Fail("1,1020x255: the bytes from VR_PUMP up are not the pump, the train and the "
                   f"zero stub bytes, or MMU6 {mc.mmu[6]} is not page A")
    stray_writes(before, after, gen_allow(lambda k: k < off or page[k] == want[k - off],
                                          page_b=None))


def set_entry(mc, name):
    """vr_sector_n's first two bytes = VR_ENT_FAST or VR_ENT_CROSS, as vid_raw_frame writes."""
    a = S("vr_sector_n")
    mc.mem[a:a + 2] = le(S(name))


def entry_of(mc):
    """'VR_ENT_FAST', 'VR_ENT_CROSS', or the two bytes at vr_sector_n in hex."""
    a = S("vr_sector_n")
    got = bytes(mc.mem[a:a + 2])
    for name in ("VR_ENT_FAST", "VR_ENT_CROSS"):
        if got == le(S(name)):
            return name
    return got.hex()


def poll1_t():
    """CRC 2 to poll 1 on Release and -BenchQuiet: in tail 4 + VR_POLL_PAD_N x cp (hl) 7 +
    in head 7."""
    return 11 + 7 * S("VR_POLL_PAD_N")


def test_sector_runwalk():
    """Two opens from a run of 1 (the first with no CRC due): under VR_ENT_CROSS the count
    falls to 0, then the second open walks once, after its CRC, into a run of 5 and counts
    it (4 left); under VR_ENT_FAST neither open counts and the walk never fires."""
    for entry in ("VR_ENT_CROSS", "VR_ENT_FAST"):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE"))
        mc.poke16("vidStrmRunBlkH", 1)
        mc.poke("vidDsCrcDue", 0)
        set_entry(mc, entry)
        card = Card(blocks(bytes(1024)), waits=1)
        mc.set_card(card)
        fired = []

        def walk(cpu):
            fired.append(card.pos)
            cpu.hl, cpu.fc = 5, 0
            cpu.a = cpu.b = cpu.c = cpu.d = cpu.e = 0xA5     # BC, DE corrupt
        traps = {S("vid_run_walk_h"): ret_trap(walk), **aborts()}
        cross = entry == "VR_ENT_CROSS"
        for k in range(2):
            cpu = mc.run("vr_sector", traps=traps, hl=0x1234)
            if cpu.hl != 0x1234 or cpu.c != PORT_SPI or cpu.sp != STACK:
                raise Fail(f"{entry} call {k + 1}: HL=${cpu.hl:04X} C=${cpu.c:02X} "
                           f"SP=${cpu.sp:04X}")
            if mc.peek("vidDsCrcDue") != 1:
                raise Fail(f"{entry} call {k + 1}: vidDsCrcDue not 1")
            if k == 0:
                if fired or mc.peek("vidStrmRunBlkH", 2) != (0 if cross else 1):
                    raise Fail(f"{entry} call 1: walk fired {len(fired)}, cell "
                               f"{mc.peek('vidStrmRunBlkH', 2)}")
                for _ in range(512):
                    card.read()
        want = ([512 + 1 + 1 + 2], 4) if cross else ([], 1)
        if (fired, mc.peek("vidStrmRunBlkH", 2)) != want:
            raise Fail(f"{entry}: walk at reads {fired}, cell {mc.peek('vidStrmRunBlkH', 2)}; "
                       f"expected {want} (the CRC comes before the walk)")
        if card.pos != len(card.stream) - 512 or entry_of(mc) != entry:
            raise Fail(f"{entry}: {card.pos} card reads after two sector opens, entry "
                       f"{entry_of(mc)}")


def sector_mc(run=100, crc=1, entry="VR_ENT_FAST"):
    """VID_PAGE at MMU7, the run count, vidDsCrcDue, the open's entry, the PLAY divider far
    from its poll."""
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    mc.poke16("vidStrmRunBlkH", run)
    mc.poke("vidDsCrcDue", crc)
    set_entry(mc, entry)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    return mc


def loop_polls(b):
    """The djnz loop's polls after poll 1 for B on entry, before vid_sd_tok_h."""
    return b or 256


def plain_debug():
    """DEBUG without NXB_QUIET: the PLAY divider and the token counter are assembled."""
    return "dbgNoBank" in SYMS and "nxbQuietImage" not in SYMS


def test_sector_badtoken():
    """A byte neither $FF nor $FE at poll 1, poll 2, a later loop poll or in vid_sd_tok_h, both
    entries under each entry patch: VID_ERR_TOKEN at vid_dec_abort_pos, every read up to it
    made, the caller's return address the only word stacked."""
    for (entry, crc), ent in [(e, p) for e in (("vr_sector", False), ("vr_sector_n", True))
                              for p in ("VR_ENT_FAST", "VR_ENT_CROSS")]:
        for k, b in ((0, 0), (1, 0), (2, 0), (3, 1)):
            for bad in (0x00, 0x7F, 0xFC, 0xFD):
                what = f"{entry} {ent} ${bad:02X} after {k} $FF, B {b}"
                mc = sector_mc(crc=int(crc), entry=ent)
                card = Card(blocks(bytes(512)), waits=k, token=bad, crc_first=crc)
                mc.set_card(card)
                try:
                    mc.run(entry, traps=aborts(), hl=0, b=b, c=PORT_SPI)
                except Stop as e:
                    if (not reached(e, "vid_dec_abort_pos") or e.a != S("VID_ERR_TOKEN")
                            or card.pos != len(card.stream) - 512 or mc.cpu.sp != STACK - 2):
                        raise Fail(f"{what}: {e}, {card.pos} reads, SP ${mc.cpu.sp:04X}")
                    continue
                raise Fail(f"{what}: returned")


def test_sector_n():
    """vr_sector_n reads the CRC pair whatever vidDsCrcDue holds and leaves the cell alone; C
    is neither read nor written (entered as $5A, kept); VR_ENT_FAST leaves the run count,
    VR_ENT_CROSS (CRC by vr_sector_c) counts one; the entry bytes are not written."""
    for entry, run, crc_by in (("VR_ENT_FAST", 100, "vr_sector_n"),
                               ("VR_ENT_CROSS", 99, "vr_sector_c")):
        mc = sector_mc(crc=0, entry=entry)
        card = Card(blocks(bytes(512)), waits=2, crc_first=True)
        mc.set_card(card)
        cpu = mc.run("vr_sector_n", traps={**aborts(), **forbid("vid_run_walk_h")}, hl=0x2345,
                     b=0, c=0x5A)
        phases = [p for p, _ in card.log]
        owner = owner_fn(mc)
        if phases != ["crc", "crc", "wait", "wait", "token"] \
                or [owner(pc) for _, pc in card.log[:2]] != [crc_by] * 2:
            raise Fail(f"{entry}: vr_sector_n reads {phases} (CRC by "
                       f"{[owner(pc) for _, pc in card.log[:2]]})")
        if mc.peek("vidDsCrcDue") != 0:
            raise Fail(f"{entry}: vr_sector_n wrote vidDsCrcDue = {mc.peek('vidDsCrcDue')}")
        if (cpu.hl, cpu.c, cpu.sp, mc.peek("vidStrmRunBlkH", 2), entry_of(mc)) != \
                (0x2345, 0x5A, STACK, run, entry):
            raise Fail(f"{entry}: HL ${cpu.hl:04X} C ${cpu.c:02X} SP ${cpu.sp:04X} run "
                       f"{mc.peek('vidStrmRunBlkH', 2)} (expected {run}), entry {entry_of(mc)}")
        check_log(mc, card, f"vr_sector_n {entry}")


def test_sector_fresh():
    """vr_sector with vidDsCrcDue = 0 (vr_sector_n.fresh) under each entry: no CRC read, the
    mode from the entry byte (VR_ENT_FAST leaves the run count, VR_ENT_CROSS counts one, a run
    of 0 walks before the first read); vidDsCrcDue = 1, HL kept, C = PORT_SPI_DAT, SP back at
    the caller's (nothing left stacked on the no-CRC entry into vr_sector_c)."""
    for entry, run, walk_at, left in (("VR_ENT_FAST", 100, [], 100), ("VR_ENT_CROSS", 100, [], 99),
                                      ("VR_ENT_FAST", 0, [], 0), ("VR_ENT_CROSS", 0, [0], 6)):
        what = f"{entry} run {run}"
        mc = sector_mc(run=run, crc=0, entry=entry)
        card = Card(blocks(bytes(512)), waits=1)
        mc.set_card(card)
        fired = []

        def walk(cpu):
            fired.append(card.pos)
            cpu.hl, cpu.fc = 7, 0
            cpu.a = cpu.b = cpu.c = cpu.d = cpu.e = 0xA5
        cpu = mc.run("vr_sector", traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()},
                     hl=0x3456, b=0, c=0x77, de=0x1357)
        phases = [p for p, _ in card.log]
        got = (phases, fired, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidDsCrcDue"), cpu.hl,
               cpu.c, cpu.sp, entry_of(mc))
        want = (["wait", "token"], walk_at, left, 1, 0x3456, PORT_SPI, STACK, entry)
        if got != want:
            raise Fail(f"{what}: (reads, walk at, run, crcDue, HL, C, SP, entry) = {got}, "
                       f"expected {want}")


def test_sector_polls():
    """vr_sector_n for k $FF bytes and B on entry: poll 1, then B (0: 256) djnz polls, then
    vid_sd_tok_h. HL kept, the run count kept (VR_ENT_FAST), the reads in order, each by its
    routine; C
    entered as $5A is kept on the fast path and PORT_SPI_DAT after vid_sd_tok_h."""
    tok = S("vid_sd_tok_h")
    for b in (0, 1, 255):
        for k in (0, 1, 2, 3, 255, 256, 300):
            what = f"{k} $FF, B {b}"
            n = loop_polls(b)
            slow = k > n
            mc = sector_mc()
            card = Card(blocks(bytes(512)), waits=k, crc_first=True)
            mc.set_card(card)
            hits = []

            def enter(cpu):
                hits.append(card.pos)
                cpu.step()
            cpu = mc.run("vr_sector_n", traps={tok: enter, **aborts(),
                                               **forbid("vid_run_walk_h")},
                         hl=0x2345, b=b, c=0x5A)
            owner = owner_fn(mc)
            got = ([p for p, _ in card.log], [owner(pc) for _, pc in card.log], hits, cpu.hl,
                   cpu.c, cpu.sp, mc.peek("vidStrmRunBlkH", 2))
            mine = 2 + (1 + n if slow else k + 1)
            want = (["crc", "crc"] + ["wait"] * k + ["token"],
                    ["vr_sector_n"] * mine + ["vid_sd_tok_h"] * (k + 3 - mine),
                    [mine] if slow else [], 0x2345, PORT_SPI if slow else 0x5A, STACK, 100)
            if got != want:
                raise Fail(f"{what}: phases ok {got[0] == want[0]}, readers ok "
                           f"{got[1] == want[1]} ({mine} by vr_sector_n expected), "
                           f"vid_sd_tok_h entered at read {hits} (expected {want[2]}), HL "
                           f"${cpu.hl:04X} C ${cpu.c:02X} (expected ${want[4]:02X}) SP "
                           f"${cpu.sp:04X} run {got[6]}")


def test_sector_timeout():
    """The wait's bound: 1 + (B or 256) + 65536 polls (poll 1, the djnz loop, vid_sd_tok_h's
    65536). The token on the last poll returns with C = PORT_SPI_DAT; one more $FF aborts with
    VID_ERR_TOKEN at vid_dec_abort_pos, the caller's return address the only word stacked."""
    for b in (1, 0):
        last = loop_polls(b) + 65536
        for k in (last, last + 1):
            what = f"{k} $FF, B {b}"
            mc = sector_mc()
            card = Card(blocks(bytes(512)), waits=k, crc_first=True)
            mc.set_card(card)
            try:
                cpu = mc.run("vr_sector_n", traps=aborts(), hl=0x2345, b=b, c=PORT_SPI,
                             budget=2_000_000)
            except Stop as e:
                if (k == last or not reached(e, "vid_dec_abort_pos")
                        or e.a != S("VID_ERR_TOKEN") or card.pos != 2 + last + 1
                        or mc.cpu.sp != STACK - 2):
                    raise Fail(f"{what}: {e}, {card.pos} reads, SP ${mc.cpu.sp:04X}")
                continue
            if k != last or card.pos != 2 + k + 1 or (cpu.hl, cpu.c) != (0x2345, PORT_SPI):
                raise Fail(f"{what}: returned after {card.pos} reads, HL ${cpu.hl:04X} "
                           f"C ${cpu.c:02X}")


def sector_divider(mc):
    """T of vr_sector_n's DEBUG PLAY divider (ld d,0 / call vid_dst_norm_flat); 0 if absent."""
    if not plain_debug():
        return 0
    return stub_t(mc, b"\x16\x00\xCD" + le(S("vid_dst_norm_flat")) + b"\xC9")


TOKCNT_T = 177                      # vid_sd_tok_h's DEBUG token counter, after the token read


def test_sector_gaps():
    """The schedule's sector (call vr_sector_n / call VR_SLIDE, VR_ENT_FAST) by k $FF bytes and
    B: CRC 15; CRC 2 to poll 1 18 T (+ the PLAY divider in DEBUG); poll 1 to 2 22 T; loop 47;
    loop to vid_sd_tok_h 69, its polls 48; token to the slide 48 T (64 on poll 1, 92 through
    vid_sd_tok_h + its DEBUG counter); the slide 16; its last read to the next CRC 1 41 T."""
    pair = b"\xCD" + le(S("vr_sector_n")) + b"\xCD" + le(S("VR_SLIDE"))
    ctr = TOKCNT_T if plain_debug() else 0
    if poll1_t() != 18:
        raise Fail(f"CRC 2 to poll 1 is {poll1_t()} T (VR_POLL_PAD_N {S('VR_POLL_PAD_N')}), "
                   f"not 18")
    for k, b, nsec in ((0, 0, 1), (1, 0, 2), (3, 0, 1), (2, 1, 1), (3, 1, 1), (300, 1, 1)):
        mc = sector_mc(run=1000)
        rw_sched(mc)
        x = poll1_t() + sector_divider(mc)
        n = loop_polls(b)
        mc.set_card(Card([bytes(512)] * nsec, waits=k, crc_first=True))
        mc.mem[STUB:STUB + 6 * nsec + 1] = pair * nsec + b"\xC9"
        cpu = mc.cpu
        cpu.sp, cpu.hl, cpu.b, cpu.c = STACK, S("VR_SCRATCH"), b, PORT_SPI
        cpu.push(RET)
        gaps = io_gaps(mc, STUB, RET)
        if k == 0:
            polls, tin = [], 64
        elif k <= n:
            polls, tin = [22] + [47] * (k - 1), 48
        else:
            polls, tin = [22] + [47] * (n - 1) + [69] + [48] * (k - n - 1), 92 + ctr
        want = [15, x] + polls + [tin] + [16] * 511
        if nsec == 2:
            want += [41, 15, x, 22, 48] + [16] * 511
        if gaps != want:
            bad = next((i for i, (g, w) in enumerate(zip(gaps, want)) if g != w), len(want))
            raise Fail(f"{k} $FF, B {b}: gap {bad} is {gaps[bad:bad + 1]}, expected "
                       f"{want[bad:bad + 1]} ({len(gaps)} gaps, {len(want)} expected); head "
                       f"{gaps[:6]}")
    print(f"  test_sector_gaps: CRC 15, CRC 2 to poll 1 {x} T, poll 1 to 2 22, loop 47, loop "
          f"to vid_sd_tok_h 69, token to slide 48 / 64 / {92 + ctr}, slide to CRC 41 T")


def open_gaps(mc, code, waits):
    """io_gaps of code called at STUB (ending in ret), the card a CRC pair, waits $FF and the
    token of one sector, then its 512 data bytes (left unread by a bare open)."""
    mc.set_card(Card([bytes(512)], waits=waits, crc_first=True))
    mc.mem[STUB:STUB + len(code)] = code
    cpu = mc.cpu
    cpu.sp, cpu.hl, cpu.b, cpu.c = STACK, S("VR_SCRATCH"), 0, PORT_SPI
    cpu.push(RET)
    return io_gaps(mc, STUB, RET)


def test_poll_pad():
    """CRC 2 to poll 1 is set by VR_POLL_PAD_N alone: 11 + 7 x VR_POLL_PAD_N (18 T) in
    vr_sector_n and its bench mirror nxb_rh_sec, 39 in nxb_rh_sec39; the whole open's gaps
    [15, 18, 22, 47] on Release and -BenchQuiet ([15, 110, 22, 47] crossing, vr_sector_c), plain
    DEBUG's PLAY divider lengthening only CRC 2 to poll 1 and never in the mirrors; every read
    whose value is used (poll 1 on) at least 16 T after the one before. A scratch copy with 4
    cp (hl) (the fallback VR_POLL_PAD_N) puts poll 1 39 T after CRC 2, the rest unchanged.
    Page B's inline open: [15, 11 + 7 x VR_POLL_PAD_N, 25, 59, 47] by waits (its divider
    follows the token), 39 with 4 cp (hl)."""
    n = S("VR_POLL_PAD_N")
    if n < 1 or poll1_t() != 18:
        raise Fail(f"VR_POLL_PAD_N {n}: CRC 2 to poll 1 {poll1_t()} T, expected 18")
    call = lambda name: b"\xCD" + le(S(name)) + b"\xC9"          # noqa: E731
    mc = sector_mc(run=1000)
    div = sector_divider(mc)
    rows = [("vr_sector_n", "VR_ENT_FAST", poll1_t() + div),
            ("vr_sector_n", "VR_ENT_CROSS", 110 + div)]
    if "dbgNoBank" in SYMS:
        rows += [("nxb_rh_sec", None, poll1_t()), ("nxb_rh_sec39", None, 39)]
    got = {}
    for name, ent, x in rows:
        for waits in (2, 3, 0):
            mc = sector_mc(run=1000, entry=ent or "VR_ENT_FAST")
            g = open_gaps(mc, call(name), waits)
            want = [15, x] + ([22] + [47] * (waits - 1) if waits else [])
            if g != want or min(g[1:]) < 16:
                raise Fail(f"{name} {ent or ''} {waits} $FF: gaps {g}, expected {want}")
            if waits == 2:
                got[(name, ent)] = g
    if (div == 0) != (not plain_debug()) or div and got[("vr_sector_n", "VR_ENT_FAST")][1] - div \
            != 18:
        raise Fail(f"PLAY divider {div} T on this image (plain DEBUG {plain_debug()})")
    # the fallback: 4 cp (hl) in a scratch copy (no relative jump crosses the pad)
    for name, end, poll, x in (("vr_sector_n", "vr_sector_n.fresh", "vr_sector_n.poll", 39 + div),
                               ("nxb_rh_sec", "nxb_rh_bin", "nxb_rh_sec.poll", 39)):
        if name not in SYMS or end not in SYMS:
            continue
        mc = sector_mc(run=1000)
        a, k = S(name), S(poll) - S(name)
        code = bytes(mc.mem[a:S(end)])
        if code[k - n:k] != b"\xBE" * n:
            raise Fail(f"{name}: the {n} bytes before .poll are not cp (hl)")
        g = open_gaps(mc, code[:k] + b"\xBE" * (4 - n) + code[k:], 3)
        if g != [15, x, 22, 47, 47]:
            raise Fail(f"{name} with 4 cp (hl): gaps {g}, expected [15, {x}, 22, 47, 47]")
    # page B's inline open as emitted (its VR_BS1 and vr_sector_n.s2 in place): CRC 2 to
    # poll 1 11 + 7 x VR_POLL_PAD_N, the divider after its token; 4 cp (hl): 39
    mc = sector_mc(run=1000)
    build_sched(mc, 1, 320, 192)
    a = next(a for k, _, a in parse_fast(mc)[0] if k == "open")
    o = SCHED_PAGE_B * SLOT + a - S("VR_SLIDE")
    opn = bytes(mc.phys[o:o + len(ref_open())])
    k = 5 + n
    if opn[k - n:k] != b"\xBE" * n:
        raise Fail(f"inline open: the {n} bytes before poll 1 are not cp (hl)")
    for code, x in ((opn, poll1_t()), (opn[:k] + b"\xBE" * (4 - n) + opn[k:], 39)):
        for waits in (0, 1, 2, 3):
            mc.map(7, S("VID_PAGE"))
            mc.map(6, SCHED_PAGE_B)
            g = open_gaps(mc, code + b"\xC9", waits)
            want = [15, x, 25, 59, 47][:waits + 2]
            if g != want or min(g[1:]) < 16:
                raise Fail(f"inline open ({len(code)} bytes), {waits} $FF: gaps {g}, "
                           f"expected {want}")
    got[("inline open", None)] = [15, poll1_t(), 25, 59]
    print("  test_poll_pad: " + "; ".join(f"{k[0]}{' ' + k[1] if k[1] else ''} {v}"
                                          for k, v in got.items()))


def test_sector_t():
    """T from call vr_sector_n to its return (DEBUG less the PLAY divider), VR_ENT_FAST: 101 at
    one $FF (155 with the run count, 252 before the inline wait), 95 with the token on poll
    1, 47 a further $FF; call vr_sector with a CRC due 152, with none 163. VR_ENT_CROSS
    (vr_sector_c, its push de / pop de 21): vr_sector_n 205 at one $FF, vr_sector with none
    due 262."""
    got, want = [], []
    for entry, crc, k, t, ent in (("vr_sector_n", 1, 1, 101, "VR_ENT_FAST"),
                                  ("vr_sector_n", 1, 0, 95, "VR_ENT_FAST"),
                                  ("vr_sector_n", 1, 2, 148, "VR_ENT_FAST"),
                                  ("vr_sector_n", 1, 3, 195, "VR_ENT_FAST"),
                                  ("vr_sector", 1, 1, 152, "VR_ENT_FAST"),
                                  ("vr_sector", 0, 1, 163, "VR_ENT_FAST"),
                                  ("vr_sector_n", 1, 1, 205, "VR_ENT_CROSS"),
                                  ("vr_sector", 0, 1, 262, "VR_ENT_CROSS")):
        mc = sector_mc(crc=crc, entry=ent)
        div = sector_divider(mc)
        mc.set_card(Card(blocks(bytes(512)), waits=k, crc_first=bool(crc)))
        got.append(stub_t(mc, b"\xCD" + le(S(entry)) + b"\xC9", hl=0x2345, b=0, c=PORT_SPI)
                   - div)
        want.append(t)
    if got != want:
        raise Fail(f"T (vr_sector_n 1, 0, 2, 3 $FF; vr_sector CRC due, none; crossing "
                   f"vr_sector_n, vr_sector none due) = {got}, expected {want}")


def test_sector_joins():
    """Palette frames, CRC due, one $FF a wait, page B's inline program (320x240: column and
    sector ends meet at page ends; 280x240: away from them): the gap into each open's CRC 1 by
    what the program runs before it (a slide read 24 T: ini tail 7, ret 10, in head 7; a column
    end 35; a page end 67; the palette train 257: the classic's 197 and the dispatcher 30,
    nextreg 20, jp 10), each open's CRC 15; vid_raw_pal's and the first sector's open CRC 2 to
    poll 1 18 (+ divider), poll 1 to the token 22; the inline opens 18 and 25 (the divider
    follows their token); token on 47+. The train's joins: test_train_gaps."""
    joins = {}
    for code, w, h in ((1, 320, 240), (1, 280, 240)):
        mc = RawMachine(SYMS)
        if build_sched(mc, code, w, h).fc or built_var(mc) != "inline":
            raise Fail(f"{w}x{h}: CF set, or not the inline program")
        items, _ = parse_fast(mc)
        setup_frame(mc, code, w, h, tag=1, crc_due=1)
        for n in ("vidRlDiv", "vidRlSpinDiv"):
            if n in SYMS:
                mc.poke(n, 250)
        x = poll1_t() + sector_divider(mc)
        card = Card([PAL] + blocks(pixels(w * h)), waits=1, crc_first=True)
        mc.set_card(card)
        cpu = mc.cpu
        cpu.sp = STACK
        cpu.push(RET)
        gaps = io_gaps(mc, S("vid_raw_frame"), RET)
        if cpu.a != S("VOP_KFLIP") or card.pos != len(card.stream):
            raise Fail(f"{w}x{h}: A ${cpu.a:02X}, {len(card.stream) - card.pos} reads left")
        ph = [p for p, _ in card.log]
        opens = [i for i, p in enumerate(ph) if p == "crc" and (i == 0 or ph[i - 1] != "crc")]
        sec = [j for j, (kind, _, _) in enumerate(items) if kind in ("sector", "open")]
        if len(opens) != len(sec) + 1:
            raise Fail(f"{w}x{h}: {len(opens)} opens read, the program has {len(sec)} and the "
                       f"palette 1")
        for i, j in zip(opens[1:], sec):
            joins.setdefault("train" if j == 0 else items[j - 1][0], []).append(gaps[i - 1])
        for n, i in enumerate(opens):
            want = [15, x, 22] if n < 2 else [15, poll1_t(), 25]
            if (gaps[i:i + 3], ph[i + 2:i + 5]) != (want, ["wait", "token", "data"]) \
                    or gaps[i + 3] < 47:
                raise Fail(f"{w}x{h}: open at read {i}: gaps {gaps[i:i + 4]}, reads "
                           f"{ph[i:i + 5]}; expected {want} then 47 or more")
    rng = {k: (min(v), max(v), len(v)) for k, v in joins.items()}
    if set(rng) != {"read", "colend", "page", "train"} or rng["read"][:2] != (24, 24) \
            or rng["colend"] != (35, 35, 8) or rng["page"] != (67, 67, 9) \
            or rng["train"] != (257, 257, 2):
        raise Fail(f"into CRC 1 by what precedes the open (min, max, count): {rng}")
    print("  test_sector_joins: into CRC 1 after " + ", ".join(
        f"{k} {v[0]}" + (f"-{v[1]}" if v[1] != v[0] else "") + f" T (x{v[2]})"
        for k, v in sorted(rng.items())) + f"; first sector's CRC 2 to poll 1 {x} T")


def page_trace(code, w, h, run0=0xFFFF):
    """vid_raw_frame (no palette, CRC due, one $FF a wait, the walk trapped: a fresh run of 1000)
    traced in T, vidDstPage/vidDstEnd primed $A7/$B8. -> (machine, card, read I/O marks, page
    ends [(next read index, HL, E, MMU2 on entry, HL, E, MMU2 after, T across)], (T from entry,
    E, MMU2, HL) at VR_SCHED's first instruction, x0)."""
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    pages = {(SCHED_PAGE, a) for k, _, a in parse_sched(mc)[0] if k == "page"}
    pages |= {(SCHED_PAGE_B, a) for k, _, a in parse_fast(mc)[0] if k == "page"}
    if built_var(mc) == "train":
        pages.add((SCHED_PAGE_B, S("VR_BPG")))      # a taken check's page end
    x0, _ = setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    mc.poke16("vidStrmRunBlkH", run0)
    set_entry(mc, "VR_ENT_FAST")
    mc.poke("vidDstPage", 0xA7)
    mc.poke("vidDstEnd", 0xB8)
    card = Card(blocks(pixels(w * h)), waits=1, crc_first=True)
    mc.set_card(card)
    cpu, wa, sched = mc.cpu, S("vid_run_walk_h"), S("VR_SCHED")
    cpu.sp = STACK
    cpu.push(RET)
    cpu.pc = S("vid_raw_frame")
    t, reads, ends, at_sched, pend = 0, [], [], None, None
    while cpu.pc != RET:
        if cpu.pc == wa:
            cpu.hl, cpu.fc, cpu.b, cpu.c = 1000, 0, 0x5A, 0x5A
            cpu.pc = cpu.pop()
            continue
        if mc.mmu[6] in (SCHED_PAGE, SCHED_PAGE_B):
            if cpu.pc == sched and at_sched is None and mc.mmu[6] == SCHED_PAGE:
                at_sched = (t, cpu.e, mc.mmu[2], cpu.hl)
            if pend is not None and cpu.pc == pend[0] + 7:
                ends.append((len(reads), *pend[2:], cpu.hl, cpu.e, mc.mmu[2], t - pend[1]))
                pend = None
            if (mc.mmu[6], cpu.pc) in pages:
                pend = (cpu.pc, t, cpu.hl, cpu.e, mc.mmu[2])
        pc, n = cpu.pc, len(card.log)
        op = mc.mem[pc]
        dt = tstep(mc)
        if len(card.log) != n:
            reads.append(t + (IO_START["in a,(n)"] if op == 0xDB else IO_START["ini"]))
        t += dt
    mc.sync()
    return mc, card, reads, ends, at_sched, x0


def test_page_ends():
    """The schedule's inline page end (PAGE_END: inc e 4, ld a,e 4, nextreg 17, ld h,n 7 =
    32 T) entered with HL = $6000 and E = the page at MMU2, leaving HL = $4000 and E = MMU2 = the
    next page; E = MMU2 = back bank x 2 + x0 / 32 and HL = H0 x 256 at the schedule's entry,
    vid_raw_frame's entry to there 384 T (the direct destination: 117 under vid_dst_base's 501).
    The read gap a page end sits in: the inline program (a frame inside its run) data to CRC 1
    67 after a column end (slide ini tail 7, ret 10, column end 11, 32, in head 7), data to data
    86 (call 17, ini head 9), flat 56 (slide ini tail 7, ret 10, 32, in head 7); the train's
    driver between passes data to CRC 1 84 (the pass's hop 11, ret 10, 32, call 17); a taken
    check data to data 94 (hop 11, bit 8, call nz 17, 32, ret 10); the classic (crossing) 17
    more for call vr_sector_n and 12 more through jr vr_sector_c (85, 96). Page ends per shape;
    surface exact, nothing under 16 but a CRC pair's 15, vidDstPage/vidDstEnd not written."""
    count = {(0, 256, 192): 5, (1, 320, 160): 9, (1, 320, 192): 9, (1, 280, 224): 9,
             (1, 320, 240): 9, (1, 256, 240): 7, (1, 280, 240): 9}
    for code, w, h in SHAPES:
        mc = RawMachine(SYMS)
        build_sched(mc, code, w, h)
        items, _ = parse_sched(mc)
        n = [k for k, _, _ in items].count("page")
        if n != count[(code, w, h)]:
            raise Fail(f"{code},{w}x{h}: {n} page ends, expected {count[(code, w, h)]}")
    got = []
    for code, w, h, run0, gap in ((0, 256, 192, 0xFFFF, {("data", "crc"): 56}),
                                  (1, 320, 192, 0xFFFF, {("data", "crc"): 84}),
                                  (1, 280, 224, 0xFFFF, {("data", "data"): 94}),
                                  (1, 320, 240, 0xFFFF, {("data", "crc"): 67}),
                                  (1, 280, 240, 0xFFFF, {("data", "data"): 86}),
                                  (0, 256, 192, 30, {("data", "crc"): 85}),
                                  (1, 320, 192, 60, {("data", "crc"): 96})):
        what = f"{code},{w}x{h} run {run0}"
        mc, card, reads, ends, at_sched, x0 = page_trace(code, w, h, run0)
        p0 = BACK_BANK * 2 + (x0 >> 5)
        if at_sched is None or at_sched[1:] != (p0, p0, (0x40 + (x0 & 31)) << 8) \
                or (run0 == 0xFFFF and at_sched[0] != 384):
            raise Fail(f"{what}: at VR_SCHED (T, E, MMU2, HL) {at_sched}, expected E = MMU2 = "
                       f"{p0}, HL ${(0x40 + (x0 & 31)) << 8:04X}" + (", 384 T" if run0 == 0xFFFF
                                                                     else ""))
        if len(ends) != count[(code, w, h)]:
            raise Fail(f"{what}: {len(ends)} page ends run")
        ph = [p for p, _ in card.log]
        seen = {}
        for k, (i, hl0, e0, m0, hl1, e1, m1, dt) in enumerate(ends):
            if (hl0, e0, m0, hl1, e1, m1, dt) != (0x6000, p0 + k, p0 + k, 0x4000, p0 + k + 1,
                                                   p0 + k + 1, 32):
                raise Fail(f"{what}: page end {k}: in HL ${hl0:04X} E {e0} MMU2 {m0}, out HL "
                           f"${hl1:04X} E {e1} MMU2 {m1}, {dt} T")
            seen.setdefault((ph[i - 1], ph[i]), set()).add(reads[i] - reads[i - 1])
        if seen != {k: {v} for k, v in gap.items()}:
            raise Fail(f"{what}: gaps at the page ends {seen}, expected {gap}")
        low = [(ph[i - 1], ph[i], reads[i] - reads[i - 1]) for i in range(1, len(reads))
               if reads[i] - reads[i - 1] < 16 and not (ph[i - 1] == ph[i] == "crc"
                                                       and reads[i] - reads[i - 1] == 15)]
        if low or card.pos != len(card.stream) \
                or (mc.peek("vidDstPage"), mc.peek("vidDstEnd")) != (0xA7, 0xB8):
            raise Fail(f"{what}: short gaps {low[:4]}, {len(card.stream) - card.pos} unread, "
                       f"vidDstPage ${mc.peek('vidDstPage'):02X} vidDstEnd "
                       f"${mc.peek('vidDstEnd'):02X}")
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, pixels(w * h)),
               f"{what} surface")
        got.append(f"{w}x{h}{' crossing' if run0 != 0xFFFF else ''} "
                   + "/".join(f"{a}-{b} {min(v)}" for (a, b), v in seen.items()))
    print("  test_page_ends: 32 T a page end, entry to schedule 384 T; gaps " + ", ".join(got))


def test_sector_walkfault():
    """VR_ENT_CROSS, a run of 0: a walk fault aborts with the walk's A after exactly the two
    CRC reads, both entries. VR_ENT_FAST: the walk is never entered (the frame charged the
    run) and the open completes, the count left at 0."""
    for entry in ("vr_sector", "vr_sector_n"):
        for ent in ("VR_ENT_CROSS", "VR_ENT_FAST"):
            what = f"{entry} {ent}"
            mc = sector_mc(run=0, crc=1, entry=ent)
            card = Card(blocks(bytes(512)), crc_first=True)
            mc.set_card(card)
            fired = []

            def walk(cpu):
                fired.append(card.pos)
                cpu.fc, cpu.a, cpu.hl = 1, S("VID_ERR_SHORT"), 0x7777
            try:
                cpu = mc.run(entry, traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()},
                             hl=0x1234, b=0, c=PORT_SPI)
            except Stop as e:
                if ent != "VR_ENT_CROSS" or not reached(e, "vid_dec_abort_pos") \
                        or e.a != S("VID_ERR_SHORT") or card.pos != 2 or fired != [2]:
                    raise Fail(f"{what} walk fault: {e}, {card.pos} card reads, walks {fired}")
                continue
            if ent == "VR_ENT_CROSS" or fired or card.pos != len(card.stream) - 512 \
                    or mc.peek("vidStrmRunBlkH", 2) != 0 or cpu.hl != 0x1234:
                raise Fail(f"{what}: returned after {card.pos} reads, walks {fired}, run "
                           f"{mc.peek('vidStrmRunBlkH', 2)}")


def test_sched_regs():
    """E (the schedule's back surface page) unchanged across every open the schedule calls:
    vr_sector (CRC due and not), vr_sector_n (1 and 300 $FF: vid_sd_tok_h), vr_sector_c (entered
    directly and through VR_ENT_CROSS; a walk trap returning DE = $A5A5); vr_sector with no CRC
    due under VR_ENT_CROSS (vr_sector_n.fresh into vr_sector_c.nocrc), with and without a walk;
    page B's inline open with the token on poll 1 (VR_BS1), poll 2, after 2 $FF (.s2) and 300
    (vid_sd_tok_h). Each returns with SP at the caller's, HL kept, C = PORT_SPI_DAT, the run
    count as counted."""
    cases = [("vr_sector", 1, 1, "VR_ENT_FAST", 100, 100),
             ("vr_sector", 0, 1, "VR_ENT_FAST", 100, 100),
             ("vr_sector_n", 1, 1, "VR_ENT_FAST", 100, 100),
             ("vr_sector_n", 1, 300, "VR_ENT_FAST", 100, 100),
             ("vr_sector_c", 1, 1, "VR_ENT_CROSS", 100, 99),
             ("vr_sector_c", 1, 1, "VR_ENT_CROSS", 0, 49),
             ("vr_sector_n", 1, 2, "VR_ENT_CROSS", 100, 99),
             ("vr_sector_n", 1, 2, "VR_ENT_CROSS", 0, 49),
             ("vr_sector", 0, 1, "VR_ENT_CROSS", 100, 99),
             ("vr_sector", 0, 1, "VR_ENT_CROSS", 0, 49)]
    for name, crc, waits, ent, run, left in cases:
        what = f"{name} CRC due {crc}, {waits} $FF, {ent}, run {run}"
        for e in (0x3C, 0xC3):
            mc = sector_mc(run=run, crc=crc, entry=ent)
            card = Card(blocks(bytes(512)), waits=waits,
                        crc_first=name != "vr_sector" or crc == 1)
            mc.set_card(card)
            fired = []

            def walk(cpu):
                fired.append(card.pos)
                cpu.hl, cpu.fc = 50, 0
                cpu.d = cpu.e = 0xA5
                cpu.b = cpu.c = 0x5A
            cpu = mc.run(name, traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()},
                         hl=0x2345, b=0, c=PORT_SPI, d=0x99, e=e, budget=2_000_000)
            got = (cpu.e, cpu.sp, cpu.hl, cpu.c, mc.peek("vidStrmRunBlkH", 2), len(fired),
                   len(card.stream) - card.pos)
            want = (e, STACK, 0x2345, PORT_SPI, left, int(run == 0), 512)
            if got != want:
                raise Fail(f"{what}, E ${e:02X}: (E, SP, HL, C, run, walks, unread) = "
                           f"{tuple(hex(x) if i < 4 else x for i, x in enumerate(got))}, expected "
                           f"{tuple(hex(x) if i < 4 else x for i, x in enumerate(want))}")
    # page B's inline open (VR_BS1, .s2, vid_sd_tok_h): E, HL, the run count kept, SP back,
    # C kept (PORT_SPI_DAT after vid_sd_tok_h), the sector's data left unread
    mc = sector_mc(run=100)
    build_sched(mc, 1, 320, 192)
    a = next(a for k, _, a in parse_fast(mc)[0] if k == "open")
    o = SCHED_PAGE_B * SLOT + a - S("VR_SLIDE")
    opn = bytes(mc.phys[o:o + len(ref_open())])
    for waits in (0, 1, 2, 300):
        for e in (0x3C, 0xC3):
            mc.map(7, S("VID_PAGE"))
            mc.map(6, SCHED_PAGE_B)
            card = Card(blocks(bytes(512)), waits=waits, crc_first=True)
            mc.set_card(card)
            mc.mem[STUB:STUB + len(opn) + 1] = opn + b"\xC9"
            cpu = mc.run(STUB, traps={**aborts(), **forbid("vid_run_walk_h")}, hl=0x2345, b=0,
                         c=PORT_SPI, d=0x99, e=e, budget=2_000_000)
            got = (cpu.e, cpu.sp, cpu.hl, cpu.c, mc.peek("vidStrmRunBlkH", 2),
                   len(card.stream) - card.pos)
            if got != (e, STACK, 0x2345, PORT_SPI, 100, 512):
                raise Fail(f"inline open, {waits} $FF, E ${e:02X}: (E, SP, HL, C, run, unread) "
                           f"= {got}")


PAL = bytes((i * 29 + 11) & 255 for i in range(512))


def counted_run(run0, n, fresh):
    """The per-open count over n opens from run0: (run left, the opens that walk). A walk at 0
    takes the next fresh run, then the open counts one."""
    run, walks = run0, []
    for j in range(n):
        if run == 0:
            run = fresh[len(walks)]
            walks.append(j)
        run -= 1
    return run, walks


def frame_walk(code, w, h, tag, run0, fresh=(), waits=2, entry="VR_ENT_FAST", crc_due=1,
               remain=0x020000, bad_token=None):
    """vid_raw_frame from run count run0, `entry` left at vr_sector_n (a previous frame's), the
    walk trap handing out `fresh` in order (None: a walk fault, A = VID_ERR_SHORT; BC, DE
    corrupted either way) and recording (read, entry seen); bad_token = an open whose token is
    $FD. -> (machine, card, walks, stop or None, x0, sectors, pixels)."""
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    x0, sectors = setup_frame(mc, code, w, h, tag=tag, remain=remain, crc_due=crc_due)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    mc.poke16("vidStrmRunBlkH", run0)
    set_entry(mc, entry)
    px = pixels(w * h)
    card = Card(([PAL] if tag else []) + blocks(px), waits=waits, crc_first=bool(crc_due))
    if bad_token is not None:
        card.stream[[i for i, p in enumerate(card.phase) if p == "token"][bad_token]] = 0xFD
    mc.set_card(card)
    walks = []

    def walk(cpu):
        walks.append((card.pos, entry_of(mc)))
        if len(walks) > len(fresh):
            raise Fail(f"walk {len(walks)} at read {card.pos}: none expected")
        cpu.b = cpu.c = cpu.d = cpu.e = 0x5A
        if fresh[len(walks) - 1] is None:
            cpu.fc, cpu.a, cpu.hl = 1, S("VID_ERR_SHORT"), 0x7777
        else:
            cpu.fc, cpu.a, cpu.hl = 0, 0x5A, fresh[len(walks) - 1]
    stop = None
    mc.paths, mc.mmu_writes = [], []
    try:
        mc.run("vid_raw_frame", traps={S("vid_run_walk_h"): ret_trap(walk), **aborts(),
                                       **path_traps(mc, mc.paths)})
    except Stop as e:
        stop = e
    return mc, card, walks, stop, x0, sectors, px


def walk_reads(opens, waits, crc_due):
    """The read after which open j's walk runs: its CRC first (none on open 0 if no CRC due)."""
    per = 2 + waits + 1 + 512
    return [j * per + 2 if crc_due else j * per for j in opens]


def frame_case(what, code, w, h, tag, run0, fresh=(), waits=2, entry="VR_ENT_FAST",
               crc_due=1, remain=0x020000):
    """frame_walk, then: the surface exact, every read made by its owner, the walks at the
    per-open count's reads with VR_ENT_CROSS in place (none, VR_ENT_FAST, when the frame fits
    the run), and the four cells: run left, remain - frame sectors, vidDsFrmBlk = vidRawCap,
    vidDsCrcDue = 1; a frame inside its run ran page B's program, a crossing frame
    VR_CLASSIC, and MMU6 is page A on return. Returns the machine."""
    mc, card, walks, stop, x0, sectors, px = frame_walk(code, w, h, tag, run0, fresh, waits,
                                                        entry, crc_due, remain)
    if stop is not None:
        raise Fail(f"{what}: {stop}")
    n = sectors + tag
    run, opens = (run0 - n, []) if run0 >= n else counted_run(run0, n, fresh)
    ent = "VR_ENT_FAST" if run0 >= n else "VR_ENT_CROSS"
    path = ["fast"] if run0 >= n else ["classic"]
    if mc.paths != path or mc.mmu[6] != SCHED_PAGE:
        raise Fail(f"{what}: ran {mc.paths}, expected {path}; MMU6 {mc.mmu[6]} on return")
    base = BACK_BANK * 0x4000
    expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px), f"{what} surface")
    got = (walks, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3),
           mc.peek("vidDsFrmBlk"), mc.peek("vidDsCrcDue"), entry_of(mc),
           len(card.stream) - card.pos)
    want = ([(r, ent) for r in walk_reads(opens, waits, crc_due)], run, remain - n,
            sectors + 1, 1, ent, 0)
    if got != want:
        raise Fail(f"{what}: (walks (read, entry), run, remain, FrmBlk, crcDue, entry, "
                   f"unread) = {got}, expected {want}")
    check_log(mc, card, what)
    return mc


def test_frame_fit():
    """A frame inside the run is charged once at its start (no per-open count, no walk),
    writes VR_ENT_FAST and runs page B's program (the dispatcher's jp z): 320x192 from 1000
    (880 left), from 120 (0 left), with the palette sector from 121 (0 left)."""
    for tag, run0 in ((0, 1000), (0, 120), (1, 121)):
        frame_case(f"320x192 tag {tag} run {run0}", 1, 320, 192, tag, run0)


def test_frame_runwalk():
    """A fragment run ends at sector 50 inside a frame (palette 320x192, 280x224): VR_ENT_CROSS
    during the frame, VR_CLASSIC run, the walk once at read 50 x 517 + 2 (after that sector's
    CRC), the run left fresh - (N - 50), surface and reads exact; the next frame with a long
    run writes VR_ENT_FAST, runs page B's program and plays exactly."""
    for code, w, h, tag in ((1, 320, 192, 1), (1, 280, 224, 0)):
        what = f"{code},{w}x{h} tag {tag}"
        mc = frame_case(what, code, w, h, tag, 50, fresh=(1000,))
        _, sectors = setup_frame(mc, code, w, h, tag=tag, remain=0x010000, crc_due=1)
        if entry_of(mc) != "VR_ENT_CROSS":
            raise Fail(f"{what}: the crossing frame left {entry_of(mc)}")
        mc.poke16("vidStrmRunBlkH", 5000)
        px = pixels(w * h)
        card = Card(([PAL] if tag else []) + blocks(px), waits=1, crc_first=True)
        mc.set_card(card)
        paths = []
        mc.run("vid_raw_frame", traps={**aborts(), **forbid("vid_run_walk_h"),
                                       **path_traps(mc, paths)})
        x0, _ = geom(code, w, h)
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
               f"{what} next frame surface")
        if (entry_of(mc), mc.peek("vidStrmRunBlkH", 2), card.pos, paths) != \
                ("VR_ENT_FAST", 5000 - sectors - tag, len(card.stream), ["fast"]):
            raise Fail(f"{what} next frame: entry {entry_of(mc)}, run "
                       f"{mc.peek('vidStrmRunBlkH', 2)}, {card.pos} reads, ran {paths}")


def test_frame_zero():
    """A run count of 0 at the frame's start (the sound section ended the run): the walk at the
    first open, after its CRC - the first pixel sector (280x224) or the palette sector
    (320x192, vid_raw_pal's open); with no CRC due, before the first read."""
    frame_case("280x224 run 0", 1, 280, 224, 0, 0, fresh=(900,))
    frame_case("320x192 palette run 0", 1, 320, 192, 1, 0, fresh=(900,))
    frame_case("320x192 palette run 0, no CRC due", 1, 320, 192, 1, 0, fresh=(900,), crc_due=0)


def test_entry_stale():
    """The entry a previous frame left never decides: VR_ENT_CROSS left and a run of 1000 - the
    frame runs page B's program and leaves VR_ENT_FAST; VR_ENT_FAST left and a run of 10 - the
    frame runs VR_CLASSIC, crosses and walks at sector 10."""
    for code, w, h, tag in ((1, 320, 192, 1), (0, 256, 192, 0)):
        frame_case(f"{w}x{h} stale CROSS", code, w, h, tag, 1000, entry="VR_ENT_CROSS")
        frame_case(f"{w}x{h} stale FAST", code, w, h, tag, 10, fresh=(1000,),
                   entry="VR_ENT_FAST")


def test_frame_boundaries():
    """A run boundary at each position a frame can hold it (palette 320x192, 121 opens): the
    first pixel sector (run 1), the middle (60), the last pixel sector (120), the palette
    sector (0); 280x224: the last sector (run N - 1); a frame needing two walks (10, then a
    run of 20: walks at opens 10 and 30), with the token on poll 1 and after 3 $FF. The clip's
    last frame (remain = its 121 sectors, 0 after): inside the run (run 121) and crossing at
    its last open (run 120). Crossing with no CRC due (vr_sector_n.fresh into vr_sector_c): a
    walk mid-frame (run 50), and two (run 1, then a run of 3)."""
    for run0 in (1, 60, 120, 0):
        frame_case(f"320x192 palette run {run0}", 1, 320, 192, 1, run0, fresh=(777,))
    _, n = geom(1, 280, 224)
    frame_case(f"280x224 run {n - 1}", 1, 280, 224, 0, n - 1, fresh=(777,))
    for waits in (0, 3):
        frame_case(f"320x192 palette two walks, waits {waits}", 1, 320, 192, 1, 10,
                   fresh=(20, 1000), waits=waits)
    for run0 in (121, 120):
        frame_case(f"320x192 palette last frame, run {run0}", 1, 320, 192, 1, run0,
                   fresh=(500,), remain=121)
    frame_case("320x192 palette no CRC due, run 50", 1, 320, 192, 1, 50, fresh=(900,),
               crc_due=0)
    frame_case("320x192 palette no CRC due, run 1 then 3", 1, 320, 192, 1, 1,
               fresh=(3, 900), crc_due=0)


def test_frame_cross_gaps():
    """Read spacing of a crossing frame (palette 320x192 from a run of 60, CRC due, one $FF a
    wait), traced in T: every open through vr_sector_c - CRC 15, CRC 2 to poll 1 110 (+ the
    PLAY divider in DEBUG; the walked open's gap spans the walk and is left out), poll 1 to
    the token 22; into CRC 1 after a slide read 53 T (the jr vr_sector_c); nothing else
    under 16."""
    code, w, h = 1, 320, 192
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    setup_frame(mc, code, w, h, tag=1, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    mc.poke16("vidStrmRunBlkH", 60)
    set_entry(mc, "VR_ENT_FAST")
    card = Card([PAL] + blocks(pixels(w * h)), waits=1, crc_first=True)
    mc.set_card(card)
    cpu, wa = mc.cpu, S("vid_run_walk_h")
    cpu.sp = STACK
    cpu.push(RET)
    cpu.pc = S("vid_raw_frame")
    t, marks = 0, []
    while cpu.pc != RET:
        if cpu.pc == wa:
            cpu.hl, cpu.fc, cpu.b, cpu.c = 1000, 0, 0x5A, 0x5A
            cpu.pc = cpu.pop()
            marks.append(None)                  # the walk's card commands are not modelled
            continue
        pc, n = cpu.pc, len(card.log)
        op = mc.mem[pc]
        dt = tstep(mc)
        if len(card.log) != n:
            marks.append(t + (IO_START["in a,(n)"] if op == 0xDB else IO_START["ini"]))
        t += dt
    if card.pos != len(card.stream) or entry_of(mc) != "VR_ENT_CROSS" or marks.count(None) != 1:
        raise Fail(f"{card.pos} of {len(card.stream)} reads, entry {entry_of(mc)}, "
                   f"{marks.count(None)} walks")
    ph = [p for p, _ in card.log]
    reads = [m for m in marks if m is not None]
    walk_after = marks.index(None)              # reads made before the walk
    x = 110 + sector_divider(mc)
    pairs = []
    for i in range(1, len(reads)):
        if i == walk_after:
            continue
        pairs.append((ph[i - 1], ph[i], reads[i] - reads[i - 1]))
    crc2 = {g for a, b, g in pairs if a == "crc" and b == "wait"}
    into = {g for a, b, g in pairs if a == "data" and b == "crc"}
    low = [(a, b, g) for a, b, g in pairs if g < 16 and not (a == b == "crc" and g == 15)]
    if crc2 != {x} or min(into) != 53 or low:
        raise Fail(f"CRC 2 to poll 1 {sorted(crc2)} (expected {x}), into CRC 1 {sorted(into)}, "
                   f"short gaps {low[:4]}")
    print(f"  test_frame_cross_gaps: CRC 2 to poll 1 {x} T, into CRC 1 {min(into)}-{max(into)} T")


def test_frame_end_walk():
    """A frame that ends exactly at the run's end (palette 320x192 from 121) is charged to 0
    with no walk; the next sector, the following frame's first sound sector, is opened by
    vid_ds_blkopen (protected), which walks once after its CRC and counts the fresh run."""
    mc = frame_case("320x192 palette run 121", 1, 320, 192, 1, 121)
    mc.poke("vidDsBound", 255)
    remain = mc.peek("vidStrmRemainBlk", 3)
    card = Card([bytes(512)], waits=1, crc_first=True)
    mc.set_card(card)
    fired = []

    def walk(cpu):
        fired.append(card.pos)
        cpu.hl, cpu.fc = 640, 0
    cpu = mc.run("vid_ds_blkopen", traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()},
                 hl=0, bc=0x1111, de=0x2222)
    got = (fired, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3), cpu.hl,
           card.pos, entry_of(mc))
    if got != ([2], 639, remain - 1, 512, 4, "VR_ENT_FAST"):
        raise Fail(f"next sound open: (walk at, run, remain, HL, reads, entry) = {got}")


def test_frame_rewind():
    """The first frame after a loop rewind: vid_loop_rewind (direct) walks inside
    vid_ds_blkopen into run 0 (R blocks) and discards the header; two sound sectors through
    vid_ds_blkopen; then the palette frame: from R = 2000 it fits (VR_ENT_FAST, R - 3 - 121
    left); from R = 8 it crosses at open 5 (VR_ENT_CROSS)."""
    code, w, h = 1, 320, 192
    for r, fresh2 in ((2000, None), (8, 1500)):
        what = f"rewind into a run of {r}"
        mc = RawMachine(SYMS)
        if build_sched(mc, code, w, h).fc:
            raise Fail("vid_raw_sched_build set CF")
        x0, sectors = setup_frame(mc, code, w, h, tag=1)
        for n, v in (("vidDirect", 1), ("vidStreaming", 0), ("vidDsBound", 255),
                     ("vidRlDiv", 250), ("vidRlSpinDiv", 250)):
            if n in SYMS:
                mc.poke(n, v)
        mc.poke("vidTotalBlk", (0x3000).to_bytes(3, "little"))
        set_entry(mc, "VR_ENT_CROSS")                    # the pass's last frame crossed
        px = pixels(w * h)
        hdr = [bytes([0xAA]) * 512]
        snd = [bytes([0x11]) * 512, bytes([0x22]) * 512]
        card = Card(hdr + snd + [PAL] + blocks(px), waits=1)
        mc.set_card(card)
        walks = []

        def walk(cpu):
            walks.append(card.pos)
            cpu.b = cpu.c = cpu.d = cpu.e = 0x5A
            cpu.hl, cpu.fc = (r if len(walks) == 1 else fresh2), 0
        traps = {S("vid_run_walk_h"): ret_trap(walk), S("vid_win_close_h"): ret_trap(lambda c: 0),
                 **aborts()}
        mc.run("vid_loop_rewind", traps=traps)
        for _ in snd:
            mc.run("vid_ds_blkopen", traps=traps, hl=0)
            mc.run("vid_ds_pad", hl=512)
        start = card.pos
        mc.run("vid_raw_frame", traps=traps)
        n = sectors + 1
        run0 = r - 1 - len(snd)
        run, opens = (run0 - n, []) if run0 >= n else counted_run(run0, n, (fresh2,))
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px), f"{what} surface")
        got = (walks, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3),
               mc.peek("vidDsCrcDue"), entry_of(mc), card.pos)
        want = ([0] + [start + p for p in walk_reads(opens, 1, 1)], run, 0x3000 - 1 - 2 - n, 1,
                "VR_ENT_FAST" if run0 >= n else "VR_ENT_CROSS", len(card.stream))
        if got != want:
            raise Fail(f"{what}: (walks, run, remain, crcDue, entry, reads) = {got}, "
                       f"expected {want}")
        owner = owner_fn(mc)
        for i, (ph, pc) in enumerate(card.log[start:], start):
            if owner(pc, card.pages[i]) not in ALLOWED[ph]:
                raise Fail(f"{what}: frame read {i} ({ph}) by {owner(pc, card.pages[i])}")


def test_frame_abort():
    """An abort in mid-frame on each entry: VR_ENT_FAST, a bad token at open 40 (run and remain
    already charged for the frame); VR_ENT_CROSS (run 30), a bad token at open 40 after the
    walk at 30, and a walk fault at 30. Each stops at vid_dec_abort_pos with the reads up to
    the fault made and the cells as the per-open count leaves them; then the next session's
    open (vid_stage_common.vec) writes VR_ENT_FAST and that session's first frame (cells as
    its open stages them, no CRC due) plays exactly with no walk."""
    code, w, h = 1, 320, 192
    per = 2 + 2 + 1 + 512
    for what, run0, fresh, bad, err, reads, run_left, ent in (
            ("fast, token fault at 40", 1000, (), 40, "VID_ERR_TOKEN", 40 * per + 5,
             1000 - 121, "VR_ENT_FAST"),
            ("crossing, token fault at 40", 30, (1000,), 40, "VID_ERR_TOKEN", 40 * per + 5,
             1000 - 11, "VR_ENT_CROSS"),
            ("crossing, walk fault at 30", 30, (None,), None, "VID_ERR_SHORT", 30 * per + 2,
             0, "VR_ENT_CROSS")):
        mc, card, walks, stop, x0, sectors, _ = frame_walk(code, w, h, 1, run0, fresh,
                                                           bad_token=bad)
        if stop is None or not reached(stop, "vid_dec_abort_pos") or stop.a != S(err):
            raise Fail(f"{what}: {stop or 'returned'}, expected vid_dec_abort_pos, {err}")
        got = (card.pos, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3),
               mc.peek("vidDsCrcDue"), mc.peek("vidDsFrmBlk"), entry_of(mc))
        want = (reads, run_left, 0x020000 - 121, 1, sectors + 1, ent)
        if got != want:
            raise Fail(f"{what}: (reads, run, remain, crcDue, FrmBlk, entry) = {got}, "
                       f"expected {want}")
        patch_session(mc, 1, 1)
        if entry_of(mc) != "VR_ENT_FAST":
            raise Fail(f"{what}: the next open left {entry_of(mc)}")
        setup_frame(mc, code, w, h, tag=1, remain=0x000400, crc_due=0)
        mc.poke16("vidStrmRunBlkH", 0x0400)
        px = pixels(w * h)
        card = Card([PAL] + blocks(px), waits=1)
        mc.set_card(card)
        mc.run("vid_raw_frame", traps={**aborts(), **forbid("vid_run_walk_h")})
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
               f"{what}: next session's frame surface")
        if (card.pos, mc.peek("vidStrmRunBlkH", 2), entry_of(mc)) != \
                (len(card.stream), 0x0400 - 121, "VR_ENT_FAST"):
            raise Fail(f"{what}: next session's frame read {card.pos}, run "
                       f"{mc.peek('vidStrmRunBlkH', 2)}, entry {entry_of(mc)}")


def test_frame_remain():
    for code, w, h, remain, after in ((1, 320, 192, 119, None), (1, 4, 1, 0, None),
                                     (1, 4, 1, 0x010000, 0x00FFFF), (1, 4, 1, 1, 0)):
        mc = RawMachine(SYMS)
        build_sched(mc, code, w, h)
        setup_frame(mc, code, w, h, remain=remain)
        card = Card(blocks(pixels(w * h)), waits=0)
        mc.set_card(card)
        try:
            mc.run("vid_raw_frame", traps=aborts())
        except Stop as e:
            if (after is not None or e.a != S("VID_ERR_SRCOVR") or card.pos
                    or not reached(e, "vid_dec_abort_pos")):
                raise Fail(f"{w}x{h} remain {remain}: {e}, {card.pos} card reads")
            continue
        if after is None:
            raise Fail(f"{w}x{h} remain {remain}: no SRCOVR abort")
        if mc.peek("vidStrmRemainBlk", 3) != after:
            raise Fail(f"{w}x{h} remain ${remain:06X}: ${mc.peek('vidStrmRemainBlk', 3):06X}, "
                       f"expected ${after:06X}")


def test_frame_palette():
    code, w, h = 0, 256, 192
    _, sectors = geom(code, w, h)
    pal = bytes((i * 13 + 5) & 255 for i in range(512))
    mc = RawMachine(SYMS)
    card, _, _ = run_frame(mc, code, w, h, tag=1, waits=1, pal=pal, remain=sectors + 1)
    want = (sectors + 1) * (1 + 1 + 512) + sectors * 2
    if len(card.log) != want:
        raise Fail(f"palette frame: {len(card.log)} card reads, expected {want}")
    if mc.peek("vidPalPending") != 1:
        raise Fail("vidPalPending not 1")
    if mc.peek("vidStrmRemainBlk", 3) != 0:
        raise Fail(f"vidStrmRemainBlk fell to {mc.peek('vidStrmRemainBlk', 3)}, expected 0")
    log = mc.nrlog
    vals = [v for n, v in log if n == S("NR_PAL_VALUE9")]
    if bytes(vals) != pal:
        raise Fail(f"NR $44: {len(vals)} writes, stream order "
                   f"{'kept' if bytes(vals[:len(pal)]) == pal else 'broken'}")
    first = next(i for i, (n, _) in enumerate(log) if n == S("NR_PAL_VALUE9"))
    head = log[:first]
    if (S("NR_PAL_CTRL"), 0x40) not in head or (S("NR_PAL_INDEX"), 0) not in head:
        raise Fail(f"palette edit select missing before the burst: {head}")
    check_log(mc, card, "palette frame")


def test_fast_bytes():
    """For each FAST_GEOMS geometry, over junk in both pages, the schedule bank against
    ref_fast: page A = the slide, the dispatcher, the classic schedule and VR_TAILA from
    VR_SCHED, the pump, the train and the stub bytes, the junk elsewhere (nothing between
    VR_TAILA's end and VR_PUMP or the pump and the train); page B = the slide and the inline
    program from VR_SLIDE (or the column train from DATA_WINDOW: no slide), VR_BS1 and VR_BPG,
    the same 16 stub bytes, the junk elsewhere (an inline geometry whose train was tried and
    did not fit: the junk or that train's own byte); the variant built is raw_variant's; a
    second build byte-identical; MMU6 page A on return."""
    slide = S("VR_SLIDE")
    pa_at, pb_at = SCHED_PAGE * SLOT, SCHED_PAGE_B * SLOT
    seen = set()
    for code, w, h in FAST_GEOMS:
        what = f"{code},{w}x{h}"
        ref = ref_fast(code, w, h)
        seen.add(ref["var"] if ref["attempt"] is None else "attempt")
        mc = RawMachine(SYMS)
        mc.load_phys(pa_at, bytes([0xA5]) * SLOT)
        mc.load_phys(pb_at, bytes([0x5A]) * SLOT)
        if build_sched(mc, code, w, h).fc:
            raise Fail(f"{what}: vid_raw_sched_build set CF")
        if built_var(mc) != ref["var"]:
            raise Fail(f"{what}: built {built_var(mc)}, the rule says {ref['var']}")
        want_a = bytearray([0xA5]) * SLOT
        want_b = bytearray([0x5A]) * SLOT

        def put(buf, addr, data):
            buf[addr - slide:addr - slide + len(data)] = data
        put(want_a, slide, b"\xED\xA2" * 512 + b"\xC9")
        put(want_a, S("VR_SCHED"), ref["a"])
        put(want_a, S("VR_PUMP"), pump_template())
        put(want_a, S("VR_PALTRAIN"), TRAIN)
        put(want_a, S("VR_XIN"), ref["stub"])
        put(want_b, slide, ref["b"])
        put(want_b, S("VR_BS1"), ref["bs1"])
        put(want_b, S("VR_XIN"), ref["stub"])
        got_a, got_b = bytes(mc.phys[pa_at:pa_at + SLOT]), bytes(mc.phys[pb_at:pb_at + SLOT])
        if ref["attempt"] is not None:
            for k in range(len(ref["b"]), S("VR_BS1") - slide):
                if k < len(ref["attempt"]) and got_b[k] == ref["attempt"][k]:
                    want_b[k] = got_b[k]
        for name, got, want in (("page A", got_a, want_a), ("page B", got_b, want_b)):
            if got != want:
                k = next(i for i in range(SLOT) if got[i] != want[i])
                raise Fail(f"{what}: {name} differs first at ${slide + k:04X}: "
                           f"{got[k:k + 8].hex(' ')}, expected {bytes(want[k:k + 8]).hex(' ')}")
        if got_a[S("VR_XIN") - slide:] != got_b[S("VR_XIN") - slide:] or mc.mmu[6] != SCHED_PAGE:
            raise Fail(f"{what}: the stub blocks differ, or MMU6 {mc.mmu[6]} is not page A")
        build_sched(mc, code, w, h)
        if (bytes(mc.phys[pa_at:pa_at + SLOT]), bytes(mc.phys[pb_at:pb_at + SLOT])) \
                != (got_a, got_b):
            raise Fail(f"{what}: a second build changed the schedule bank")
    if seen != {"train", "inline", "attempt"}:
        raise Fail(f"FAST_GEOMS cover {sorted(seen)}")


class LateCPU(RawCPU):
    """An MMU write takes effect one opcode fetch late: the next instruction's opcode byte
    comes from the old map, its operands and everything after from the new."""

    def step(self):
        mc = self.mc
        if not mc.pending:
            return super().step()
        pc = self.pc
        op = self.m[pc]
        for slot, page in mc.pending:
            mc.map(slot, page)
        mc.pending = []
        new = self.m[pc]
        self.m[pc] = op
        try:
            super().step()
        finally:
            self.m[pc] = new


class LateMapMachine(RawMachine):
    """RawMachine whose NR $50-$57 writes map one opcode fetch late (LateCPU)."""

    def __init__(self, syms):
        super().__init__(syms)
        self.pending = []
        self.cpu = LateCPU(self)

    def nextreg(self, n, v):
        if 0x50 <= n <= 0x57:
            self.nr[n] = v
            self.nrlog.append((n, v))
            self.mmu_writes.append((n, v))
            self.pending.append((n - 0x50, v))
            return
        super().nextreg(n, v)


def test_xstub_late():
    """With every MMU write one opcode fetch late (the jp after each stub's nextreg fetched
    from the page being left), a frame inside its run (320x192, 256x192 with its palette,
    280x224) still runs page B's program, the surface is exact, every read by its owner, and
    MMU6 = page A on return."""
    for code, w, h, tag in ((1, 320, 192, 0), (0, 256, 192, 1), (1, 280, 224, 0)):
        what = f"{code},{w}x{h} tag {tag}"
        mc = LateMapMachine(SYMS)
        paths = []
        run_frame(mc, code, w, h, tag=tag, pal=PAL, paths=paths)
        if paths != ["fast"] or mc.mmu[6] != SCHED_PAGE or mc.pending:
            raise Fail(f"{what}: ran {paths}, MMU6 {mc.mmu[6]}, pending {mc.pending}")
        check_log(mc, mc.card, what)


def test_fast_pixels():
    """For each FAST_GEOMS geometry a frame inside its run (VR_ENT_FAST; 0, 1, 2 $FF a wait by
    turn; pad bytes $AA): page B's program runs (VR_CLASSIC does not), the surface exact, the
    pad in VR_SCRATCH, every read by its owner, nothing else written (a partial pass's patch
    site holds its byte again); on return MMU6 = NR $56 = page A, SP at the caller's, E = MMU2
    = the first page plus the frame's page ends (the train's checks and driver included)."""
    for i, (code, w, h) in enumerate(FAST_GEOMS):
        what = f"{code},{w}x{h}"
        mc = RawMachine(SYMS)
        paths = []
        card, _, x0 = run_frame(mc, code, w, h, waits=i % 3, pad=0xAA, paths=paths)
        check_log(mc, card, what)
        npad = (-w * h) % 512
        scr = SCHED_PAGE * SLOT + S("VR_SCRATCH") - S("VR_SLIDE")
        e = BACK_BANK * 2 + (x0 >> 5) + frame_pages(code, w, h, x0)
        cpu = mc.cpu
        got = (paths, bytes(mc.phys[scr:scr + npad]) == b"\xAA" * npad, mc.mmu[6],
               mc.nr.get(0x56), cpu.sp, cpu.e, mc.mmu[2])
        if got != (["fast"], True, SCHED_PAGE, SCHED_PAGE, STACK, e, e):
            raise Fail(f"{what}: (ran, pad in VR_SCRATCH, MMU6, NR $56, SP, E, MMU2) = {got}, "
                       f"expected {(['fast'], True, SCHED_PAGE, SCHED_PAGE, STACK, e, e)}")
        pa = ref_fast(code, w, h)["patch"]
        if pa is not None:
            o = SCHED_PAGE_B * SLOT + pa - S("VR_SLIDE")
            if mc.phys[o] not in (0x2E, 0xED) or mc.phys[o] != ref_fast(code, w, h)["b"][
                    pa - S("VR_SLIDE")]:
                raise Fail(f"{what}: the patch site ${pa:04X} holds ${mc.phys[o]:02X}")


def frame_pages(code, w, h, x0):
    """Page ends a frame runs: page boundaries inside the picture (columns of h, or 256-byte
    units on a flat surface; the first page 32 - x0 & 31 of them)."""
    hh = h & 0xFF or 256
    unit = hh if code and hh < 256 else 256
    return sum((u + x0) % 32 == 0 for u in range(1, w * hh // unit))


def test_disp_cross():
    """The dispatcher on a run boundary (palette 320x192 and 280x224 from a run ending at
    sector 50): VR_ENT_CROSS takes VR_CLASSIC (page B never written to MMU6), the walk once at
    read 50 x 517 + 2, surface and reads exact (frame_case); the next frame (a long run)
    maps page B, runs its program and maps page A back."""
    for code, w, h, tag in ((1, 320, 192, 1), (1, 280, 224, 0)):
        what = f"{code},{w}x{h} tag {tag}"
        mc = frame_case(what, code, w, h, tag, 50, fresh=(1000,))
        b6 = [v for n, v in mc.mmu_writes if n == 0x56]
        if SCHED_PAGE_B in b6:
            raise Fail(f"{what}: the crossing frame wrote MMU6 {b6}")
        _, sectors = setup_frame(mc, code, w, h, tag=tag, remain=0x010000, crc_due=1)
        mc.poke16("vidStrmRunBlkH", 5000)
        px = pixels(w * h)
        card = Card(([PAL] if tag else []) + blocks(px), waits=1, crc_first=True)
        mc.set_card(card)
        mc.mmu_writes, paths = [], []
        mc.run("vid_raw_frame", traps={**aborts(), **forbid("vid_run_walk_h"),
                                       **path_traps(mc, paths)})
        x0, _ = geom(code, w, h)
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
               f"{what} next frame surface")
        b6 = [v for n, v in mc.mmu_writes if n == 0x56]
        if (paths, b6, card.pos) != (["fast"], [SCHED_PAGE, SCHED_PAGE_B, SCHED_PAGE],
                                     len(card.stream)):
            raise Fail(f"{what} next frame: ran {paths}, MMU6 writes {b6}, {card.pos} reads")


def open_frame(waits, bad=None, b=0):
    """A 256x192 frame inside its run (CRC due), the waits per sector (a list), the token of
    sector bad (an index) replaced by $00: (machine, card, entries seen at VR_BS1 in page B,
    vr_sector_n.s2 and vid_sd_tok_h, stop or None, pixels)."""
    code, w, h = 0, 256, 192
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    px = pixels(w * h)
    card = Card(blocks(px), waits=waits, crc_first=True)
    if bad is not None:
        card.stream[[i for i, p in enumerate(card.phase) if p == "token"][bad]] = 0x00
    mc.set_card(card)
    seen = {"bs1": 0, "s2": 0, "tok": 0}
    skips = []

    def mark(name, page=None):
        def t(cpu):
            if page is None or mc.mmu[6] == page:
                seen[name] += 1
                if name == "bs1":
                    skips.append(cpu.r16(cpu.sp))
            cpu.step()
        return t

    def bs1_ret(cpu):                       # VR_BS1's ret: where it lands past the call
        cpu.step()
        if mc.mmu[6] == SCHED_PAGE_B and skips:
            skips[-1] = cpu.pc - skips[-1]
    mc.paths = []
    traps = {**aborts(), **forbid("vid_run_walk_h"), **path_traps(mc, mc.paths),
             S("VR_BS1"): mark("bs1", SCHED_PAGE_B), S("vr_sector_n.s2"): mark("s2"),
             S("vid_sd_tok_h"): mark("tok"), S("VR_BPG") - 1: bs1_ret}
    mc.skips = skips
    stop = None
    try:
        mc.run("vid_raw_frame", traps=traps, b=b)
    except Stop as e:
        stop = e
    return mc, card, seen, stop, px


def test_open_polls():
    """The second sector's inline open (256x192 inside its run, B = 0) with 0, 1, 2, 3, 255,
    300 $FF: the token on poll 1 goes through VR_BS1 and skips poll 2 (no data byte lost: the
    surface exact); 2 and more poll on in vr_sector_n's loop (entered at .s2 once a $FF after
    poll 1), 300 into vid_sd_tok_h, each returning into the program; reads by their owners,
    MMU6 page A on return. A bad byte at poll 1 (through VR_BS1) and at poll 2 (through .s2):
    VID_ERR_TOKEN at vid_dec_abort_pos after exactly the reads up to it."""
    x0 = 0
    for k in (0, 1, 2, 3, 255, 300):
        waits = [1] * 96
        waits[1] = k
        mc, card, seen, stop, px = open_frame(waits)
        what = f"{k} $FF at the second sector"
        if stop is not None:
            raise Fail(f"{what}: {stop}")
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(0, 256, 192, x0, px), f"{what} surface")
        check_log(mc, card, what)
        want = {"bs1": int(k == 0), "s2": max(k - 1, 0) if k <= 255 else seen["s2"],
                "tok": int(k > 257)}
        if seen != want or mc.paths != ["fast"] or card.pos != len(card.stream) \
                or mc.mmu[6] != SCHED_PAGE or mc.skips != ([7] if k == 0 else []):
            raise Fail(f"{what}: entries {seen} (expected {want}), ran {mc.paths}, "
                       f"{len(card.stream) - card.pos} reads left, MMU6 {mc.mmu[6]}, VR_BS1 "
                       f"returned past its call by {mc.skips} (expected 7: poll 2's bytes)")
    for k, through in ((0, "bs1"), (1, "s2")):
        waits = [1] * 96
        waits[1] = k
        mc, card, seen, stop, _ = open_frame(waits, bad=1)
        what = f"a bad byte at poll {k + 1}"
        tok = [i for i, p in enumerate(card.phase) if p == "token"][1]
        if stop is None or not reached(stop, "vid_dec_abort_pos") \
                or stop.a != S("VID_ERR_TOKEN") or card.pos != tok + 1 or not seen[through]:
            raise Fail(f"{what}: {stop or 'returned'}, {card.pos} reads (expected {tok + 1}), "
                       f"entries {seen}")


def test_open_gaps():
    """io_gaps of every inline open of a 320x240 frame inside its run (B = 0): three $FF a
    wait [15, 18, 25, 59, 47] (poll 2 to the first loop poll: in tail 4, cp n 7, call nz taken
    17, inc a 4, jr nz 7, djnz 13, in head 7), then 48 to the first slide ini (in tail 4, cp n
    7, ret z 11, call 17, ini head 9); one $FF [15, 18, 25] then 47 (cp n 7, call nz 10, call
    17, ini head 9 after the in tail); plain DEBUG's PLAY divider adds its T after the token
    only. Also the first sector's open and the joins: nothing under 16 but a CRC pair's 15."""
    div = sector_divider(sector_mc())
    for waits, want, tin in ((3, [15, 18, 25, 59, 47], 48), (1, [15, 18, 25], 47)):
        code, w, h = 1, 320, 240
        mc = RawMachine(SYMS)
        if build_sched(mc, code, w, h).fc:
            raise Fail("vid_raw_sched_build set CF")
        setup_frame(mc, code, w, h, crc_due=1)
        for n in ("vidRlDiv", "vidRlSpinDiv"):
            if n in SYMS:
                mc.poke(n, 250)
        card = Card(blocks(pixels(w * h)), waits=waits, crc_first=True)
        mc.set_card(card)
        cpu = mc.cpu
        cpu.sp, cpu.b = STACK, 0
        cpu.push(RET)
        gaps = io_gaps(mc, S("vid_raw_frame"), RET)
        own = owner_fn(mc)
        ph = [p for p, _ in card.log]
        opens = [i for i, (p, pc) in enumerate(card.log)
                 if p == "crc" and ph[i - 1] != "crc" and own(pc, card.pages[i]) == "fast"]
        if len(opens) != 149 or card.pos != len(card.stream):
            raise Fail(f"{waits} $FF: {len(opens)} inline opens read (149 expected), "
                       f"{len(card.stream) - card.pos} reads left")
        n = len(want)
        # B is scrap (ini counts it): an open met with B = 1 or 2 runs out of djnz polls and
        # goes on in vid_sd_tok_h (69 T to its first poll, test_sector_gaps)
        bad = [(i, gaps[i:i + n + 1]) for i in opens if gaps[i:i + n + 1] != want + [tin + div]
               and not (waits == 3 and gaps[i:i + 5] == [15, 18, 25, 59, 69])]
        low = [(i, g) for i, g in enumerate(gaps) if g < 16 and not (ph[i] == ph[i + 1] == "crc"
                                                                    and g == 15)]
        if bad or low:
            raise Fail(f"{waits} $FF: inline open gaps (read, gaps) {bad[:3]} (expected "
                       f"{want + [tin + div]}); short gaps {low[:3]}")
    print(f"  test_open_gaps: [15, 18, 25, 59, 47] then {48 + div}; one $FF [15, 18, 25] then "
          f"{47 + div} T (PLAY divider {div} T)")


def ttrace(mc, stop):
    """Run from the current PC until stop(cpu): [(pc, MMU6 page, T at the instruction's
    start)] and the T at the stop."""
    out, t = [], 0
    while not stop(mc.cpu):
        out.append((mc.cpu.pc, mc.mmu[6], t))
        t += tstep(mc)
    return out, t


def test_fast_t():
    """nxv2_bench_rows' fast program counts traced from the emitted bytes (a 320x240 frame
    inside its run, CRC due, one $FF a wait, no pad): VR_OPEN_T an inline open to its first
    read's call, VR_READ_T a slide call less its ini, VR_HOP_T a column end, VR_PAGE_T a page
    end, VR_FIRST_T the program's call vr_sector to its return (plain DEBUG less the PLAY
    divider), VR_FAST_T the dispatcher, both nextregs and the three jps with VR_TAILA's ret;
    VR_FAST_NET_T a fast frame over the classic, VR_CROSS_T a crossing frame's dispatcher."""
    import nxv2_bench_rows as bench
    code, w, h = 1, 320, 240
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    items, _ = parse_fast(mc)
    setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    mc.set_card(Card(blocks(pixels(w * h)), waits=1, crc_first=True))
    cpu = mc.cpu
    cpu.sp, cpu.pc = STACK, S("vid_raw_frame")
    cpu.push(RET)
    tr, tend = ttrace(mc, lambda c: c.pc == RET)
    first = {}
    for pc, page, t in tr:
        first.setdefault((page, pc), t)
    pb = SCHED_PAGE_B

    def span(a, b, page=pb):
        return first[(page, b)] - first[(page, a)]
    at = {}
    for k, v, a in items:
        at.setdefault(k, (a, v))
    rd, n = at["read"]
    xo = at["xout"][0]
    tx = first[(pb, xo)]
    back = next(t for pc, page, t in tr if t > tx and pc >= 0xE000)
    disp = first[(pb, S("VR_PROG"))] - first[(SCHED_PAGE, S("VR_SCHED"))]
    got = dict(VR_OPEN_T=span(at["open"][0], at["open"][0] + S("VR_OPEN_LEN")),
               VR_READ_T=span(rd, rd + 3) - 16 * n,
               VR_HOP_T=span(at["colend"][0], at["colend"][0] + 3),
               VR_PAGE_T=span(at["page"][0], at["page"][0] + 7),
               VR_FIRST_T=span(S("VR_PROG"), S("VR_PROG") + 3) - sector_divider(sector_mc()),
               VR_FAST_T=disp + back - tx)
    want = {k: getattr(bench, k, None) for k in got}
    if got != want or (disp, back - tx) != (60, 50):
        raise Fail(f"fast program T {got}, nxv2_bench_rows {want}; dispatcher to VR_PROG "
                   f"{disp}, jp VR_XOUT to the return {back - tx}")
    # VR_FAST_NET_T: one inline frame (320x240, no pad) through the classic schedule
    # (vid_raw_frame's call VR_SCHED aimed at VR_CLASSIC) less through the fast program is
    # (sectors - 1) x (CLASSIC_OPEN_T - VR_OPEN_T) - VR_FAST_NET_T; VR_CROSS_T: a crossing
    # frame's dispatcher, VR_SCHED to VR_CLASSIC
    (tf, sec), (tc, _) = (frame_t(1, 320, 240, classic=c) for c in (False, True))
    mc = RawMachine(SYMS)
    if build_sched(mc, 1, 320, 240).fc:
        raise Fail("vid_raw_sched_build set CF")
    setup_frame(mc, 1, 320, 240)
    set_entry(mc, "VR_ENT_CROSS")
    cpu = mc.cpu
    cpu.sp, cpu.pc = STACK, S("VR_SCHED")
    cross = tcount(mc, lambda c: c.pc == S("VR_CLASSIC"))
    got = (tc - tf, cross)
    want = ((sec - 1) * (CLASSIC_OPEN_T - bench.VR_OPEN_T) - bench.VR_FAST_NET_T,
            bench.VR_CROSS_T)
    if got != want or bench.VR_FAST_NET_T != bench.VR_FAST_T - 10:
        raise Fail(f"classic less fast frame (320x240, {sec} sectors), crossing dispatcher = "
                   f"{got}, expected {want} (VR_FAST_NET_T {bench.VR_FAST_NET_T}, VR_FAST_T "
                   f"{bench.VR_FAST_T} less VR_TAILA's ret 10)")


CLASSIC_OPEN_T = 101                # call vr_sector_n at one $FF (test_sector_t)


def frame_t(code, w, h, classic=False):
    """T of vid_raw_frame (inside its run, CRC due, one $FF a wait, no palette) and its pixel
    sectors; classic: its call VR_SCHED aimed at VR_CLASSIC. Surface and reads checked."""
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail(f"{code},{w}x{h}: vid_raw_sched_build set CF")
    x0, sectors = setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    px = pixels(w * h)
    card = Card(blocks(px), waits=1, crc_first=True)
    mc.set_card(card)
    f = S("vid_raw_frame")
    if classic:
        at = find_code(mc, f, f + 0x80, b"\xCD" + le(S("VR_SCHED")))
        mc.mem[at + 1:at + 3] = le(S("VR_CLASSIC"))
    cpu = mc.cpu
    cpu.sp, cpu.pc = STACK, f
    cpu.push(RET)
    t = tcount(mc, lambda c: c.pc == RET)
    mc.sync()
    base = BACK_BANK * 0x4000
    if card.pos != len(card.stream) or cpu.a != S("VOP_KFLIP"):
        raise Fail(f"{code},{w}x{h} classic {classic}: {len(card.stream) - card.pos} reads "
                   f"left, A ${cpu.a:02X}")
    expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
           f"{code},{w}x{h} classic {classic} surface")
    return t, sectors


def test_variant_rule():
    """The generator's variant (vrgVar; vid_raw_stage's vidRawVar on every 25th) against
    nxv2_bench_rows.raw_variant by full builds, centred, nothing written off the schedule bank
    but the generator's cells, every program ending below VR_BEND: shape 0 at every h 1..192;
    shape 1 at every h 1..256 for w 4, 64, 128, 256, 280, 320 and every w 4..320 step 4 for h
    160, 192, 224, 240, 255, 256; 20x197, whose rule bytes equal VR_TRAIN_ROOM (a train); and
    the 32 geometries that fit with the Release open's 19 bytes and not with VR_OPEN_BUDGET
    (inline in every build). The reduced grid: the whole one (20,672 builds) takes about 12
    minutes here, over two. A flat surface (shape 0, h 256) is inline whatever its size."""
    import nxv2_bench_rows as bench
    grid = [(0, 256, h) for h in range(1, 193)]
    for w in (4, 64, 128, 256, 280, 320):
        grid += [(1, w, h) for h in range(1, 257)]
    for h in (160, 192, 224, 240, 255, 256):
        grid += [(1, w, h) for w in range(4, 321, 4) if w not in (4, 64, 128, 256, 280, 320)]
    edge = [(1, 20, 197)]
    budget = [(1, w, h) for w, h in (
        (16, 247), (20, 198), (24, 164), (28, 141), (32, 123), (36, 109), (40, 98), (44, 89),
        (52, 75), (60, 65), (68, 57), (112, 34), (144, 26), (176, 21), (240, 15))]
    budget += [(1, w, 14) for w in range(256, 321, 4)]
    room, slack = bench.VR_TRAIN_ROOM, bench.VR_OPEN_BUDGET - 19
    by = {g: bench.raw_train(*g) for g in edge + budget}
    if (by[edge[0]]["bytes"] != room or len(budget) != 32 or any(
            not room < by[g]["bytes"] <= room + slack * by[g]["starts"] for g in budget)):
        raise Fail("the rule's edge geometries are not the edge any more")
    flat = [(0, 256, 192), (1, 320, 256), (1, 280, 256), (0, 256, 167), (0, 256, 1), (1, 4, 256)]
    if any(bench.raw_variant(*g) != "inline" or bench.raw_train(*g) is not None or g not in grid
           for g in flat) or any(bench.raw_train(c, w, h) is not None
                                 for c, w, h in grid if not c or h == 256):
        raise Fail("raw_train has a train for a flat surface")
    grid += [g for g in edge + budget if g not in grid]
    mc = RawMachine(SYMS)
    off, hot = S("DATA_WINDOW") - S("OVL_ORG"), S("VID_PAGE")
    allow = gen_allow(lambda k: True)
    count = {}
    for n, (code, w, h) in enumerate(grid):
        what = f"{code},{w}x{h}"
        mc.map(7, S("VID_PAGE2"))
        mc.sync()
        before = bytes(mc.phys)
        if build_sched(mc, code, w, h).fc:
            raise Fail(f"{what}: CF set")
        var, want = built_var(mc), bench.raw_variant(code, w, h)
        _, end = parse_fast(mc)
        if var != want or end > S("VR_BEND"):
            raise Fail(f"{what}: built {var}, the rule {want} ({bench.raw_train(code, w, h)}); "
                       f"program end ${end:04X}")
        stray_writes(before, bytes(mc.phys), allow)
        count[var] = count.get(var, 0) + 1
        if n % 25 == 0:
            mc.map(6, hot)
            mc.mem[S("vidRawVar") + off] = 0x77
            mc.run("vid_raw_stage")
            if mc.mem[S("vidRawVar") + off] != (var == "train"):
                raise Fail(f"{what}: vidRawVar {mc.mem[S('vidRawVar') + off]}, built {var}")
    print(f"  test_variant_rule: {len(grid)} builds, {count} as raw_variant")


def train_gaps(code, w, h, mutate=False):
    """A frame inside its run (no palette, CRC due, one $FF a wait) through the train, every
    read gap keyed (phase before, phase, where each read ran: hot, B, A, and the train items
    run between them, in order: parse_train's kinds, 'bpg' for VR_BPG, 'pret' for a ret at the
    patch site). mutate: a scratch copy of the generator whose .inl skips the pad. -> [(key,
    T)], the machine."""
    mc = RawMachine(SYMS)
    if mutate:
        a = S("vid_raw_sched_build.inl1") - 2
        o = S("VID_PAGE2") * SLOT + (a & 0x1FFF)
        if bytes(mc.phys[o:o + 2]) != b"\x2B\x03":
            raise Fail("the generator's .inl does not end dec hl / inc bc")
        mc.phys[o:o + 2] = b"\x00\x00"
    if build_sched(mc, code, w, h).fc or built_var(mc) != "train":
        raise Fail(f"{code},{w}x{h}: CF set, or no train")
    parsed = parse_train(mc)[0]
    items = {a: k for k, _, a in parsed}
    items[S("VR_BPG")] = "bpg"
    pas = {v[1] for k, v, _ in parsed if k == "patch"}
    x0, _ = setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    px = pixels(w * h)
    card = Card(blocks(px), waits=1, crc_first=True)
    mc.set_card(card)
    cpu = mc.cpu
    cpu.sp, cpu.pc = STACK, S("vid_raw_frame")
    cpu.push(RET)
    t, marks, seq = 0, [], []
    while cpu.pc != RET:
        pc, page, n = cpu.pc, mc.mmu[6], len(card.log)
        op, sub = mc.mem[pc], mc.mem[(pc + 1) & 0xFFFF]
        if page == SCHED_PAGE_B and pc in pas and op == 0xC9:
            seq.append("pret")
        elif page == SCHED_PAGE_B and pc in items:
            seq.append(items[pc])
        dt = tstep(mc)
        if len(card.log) != n:
            where = "hot" if pc >= 0xE000 else "B" if page == SCHED_PAGE_B else "A"
            marks.append((t + (IO_START["in a,(n)"] if op == 0xDB else IO_START["ini"]), where,
                          tuple(seq[:-1] if seq and items.get(pc) else seq)))
            seq = []
        t += dt
    mc.sync()
    if card.pos != len(card.stream):
        raise Fail(f"{code},{w}x{h}: {len(card.stream) - card.pos} reads left")
    expect(mc.phys[BACK_BANK * 0x4000:BACK_BANK * 0x4000 + SURF_LEN],
           want_surface(code, w, h, x0, px), f"{code},{w}x{h} surface")
    ph = [p for p, _ in card.log]
    out = []
    for i in range(1, len(marks)):
        out.append(((ph[i - 1], ph[i], marks[i - 1][1], marks[i][1], marks[i][2]),
                    marks[i][0] - marks[i - 1][0]))
    return out, mc


def test_train_gaps():
    """io_gaps of whole frames through the train (320x192; 280x224, its checks and partial
    pass; one pass 8x32; 192x4): inside an ini run 16; across a hop 27; across a check 45
    (taken, its page end at VR_BPG: 94); a one-pass page end 59; a sector's last ini to the
    next open's CRC 1 18 (the nop); across a pass end (hop, ret, call) 52, with the driver's
    page end 84, with the patch before the partial pass 72, with both (192x4) 104; inside an
    open [15, 18, 25] and the token to its first ini 30 (plain DEBUG: the PLAY divider after
    the token); the first sector's open (vr_sector) [15, 18, 22], its token to the pass's
    first ini 48; out to VR_TAILA's pad: the partial pass's patched ret 113, one pass 104.
    Nothing else, none under 15, none but a CRC pair under 16. A generator that drops the pad
    meets a 14."""
    div = sector_divider(sector_mc())
    base = {("crc", "crc", "B", "B", ()): 15, ("crc", "wait", "B", "B", ()): 18,
            ("wait", "token", "B", "B", ()): 25, ("token", "data", "B", "B", ()): 30 + div,
            ("crc", "crc", "hot", "hot", ()): 15, ("crc", "wait", "hot", "hot", ()): 18 + div,
            ("wait", "token", "hot", "hot", ()): 22,
            ("token", "data", "hot", "B", ("enter",)): 48,
            ("data", "data", "B", "B", ()): 16,
            ("data", "data", "B", "B", ("colend",)): 27,
            ("data", "data", "B", "B", ("colend", "check")): 45,
            ("data", "data", "B", "B", ("colend", "check", "bpg")): 94,
            ("data", "crc", "B", "B", ("pad",)): 18,
            ("data", "data", "B", "A", ("pret", "patch", "xout")): 113,
            ("data", "data", "A", "A", ()): 16}
    for mid, dt in (((), 0), (("page",), 32), (("patch",), 20), (("page", "patch"), 52)):
        base[("data", "crc", "B", "B", ("colend", "ret") + mid + ("call",))] = 52 + dt
    base[("data", "data", "B", "A", ("colend", "ret", "xout"))] = 104       # one pass, a pad
    base[("data", "data", "B", "B", ("colend", "page"))] = 59               # one pass's page end
    seen = {}
    for code, w, h in ((1, 320, 192), (1, 280, 224), (1, 8, 32), (1, 192, 4)):
        gaps, _ = train_gaps(code, w, h)
        for key, g in gaps:
            if base.get(key) != g:
                raise Fail(f"{code},{w}x{h}: gap {g} T at {key}, expected {base.get(key)}")
            seen.setdefault(key, set()).add(g)
    need = {("data", "data", "B", "B", ("colend", "check")),
            ("data", "data", "B", "B", ("colend", "check", "bpg")),
            ("data", "crc", "B", "B", ("pad",)),
            ("data", "crc", "B", "B", ("colend", "ret", "call")),
            ("data", "crc", "B", "B", ("colend", "ret", "page", "call")),
            ("data", "crc", "B", "B", ("colend", "ret", "patch", "call")),
            ("data", "crc", "B", "B", ("colend", "ret", "page", "patch", "call")),
            ("data", "data", "B", "A", ("pret", "patch", "xout")),
            ("data", "data", "B", "A", ("colend", "ret", "xout")),
            ("data", "data", "B", "B", ("colend", "page"))}
    if need - set(seen):
        raise Fail(f"joins not met: {sorted(need - set(seen))}")
    gaps, _ = train_gaps(1, 320, 192, mutate=True)
    low = sorted({g for key, g in gaps if g < 15})
    if low != [14]:
        raise Fail(f"a generator with no pad: gaps under 15 {low}, expected [14]")
    print("  test_train_gaps: " + ", ".join(
        f"{'+'.join(k[4]) or '-'} {k[0]}-{k[1]} {min(v)}" for k, v in sorted(
            seen.items(), key=lambda kv: min(kv[1]))) + "; no pad: 14")


def test_train_regs():
    """One pass through the period as the driver calls it (320x192; 280x224 from H = $40, its
    check not taken, and from $54, taken), the token on poll 1 (VR_BS1), poll 2, after 2 $FF
    (.s2) and 300 (vid_sd_tok_h): E unchanged (one more after a taken check), C = PORT_SPI_DAT,
    SP at the caller's, HL past the pass's columns, the pass's sectors read exactly. B is scrap
    (ini and the poll loop count it)."""
    import nxv2_bench_rows as bench
    for code, w, h, h0, taken in ((1, 320, 192, 0x40, 0), (1, 280, 224, 0x40, 0),
                                  (1, 280, 224, 0x54, 1)):
        r = bench.raw_train(code, w, h)
        mc = RawMachine(SYMS)
        if build_sched(mc, code, w, h).fc or built_var(mc) != "train":
            raise Fail(f"{w}x{h}: no train")
        for waits in (0, 1, 2, 300):
            for e in (0x3C, 0xC3):
                mc.map(7, S("VID_PAGE"))
                mc.map(6, SCHED_PAGE_B)
                for n in ("vidRlDiv", "vidRlSpinDiv"):
                    if n in SYMS:
                        mc.poke(n, 250)
                card = Card(blocks(pixels(r["Lp"])), waits=waits, crc_first=True)
                mc.set_card(card)
                cpu = mc.run(S("VR_SLIDE"), traps={**aborts(), **forbid("vid_run_walk_h")},
                             hl=h0 << 8, b=0, c=PORT_SPI, d=0x99, e=e, budget=2_000_000)
                hl = ((0x40 + (h0 + r["cols"] - 0x60)) if taken else h0 + r["cols"]) << 8
                got = (cpu.e, cpu.c, cpu.sp, cpu.hl, len(card.stream) - card.pos)
                if got != ((e + taken) & 0xFF, PORT_SPI, STACK, hl, 0):
                    raise Fail(f"{w}x{h} from H ${h0:02X}, {waits} $FF, E ${e:02X}: (E, C, SP, "
                               f"HL, unread) = {got}")


def test_fast_frame_t():
    """raw_frame_overhead (nxv2_bench_rows) against traced frames (inside the run, CRC due, one
    $FF a wait, no palette): T beyond 16 a data byte, plain DEBUG less a PLAY divider an open,
    for the six target shapes and 280x56, 320x256, 256x167, 8x32; and its counts traced from
    the emitted bytes (280x224): VR_PASS_T a period call and its ret, VR_TPAD_T the nop,
    VR_CHK_T a check not taken, VR_CHK_PAGE_T one taken, VR_PATCH_T both patches, VR_FRAME_T
    vid_raw_frame's own T, VR_PAD_T VR_TAILA's pad read less its bytes."""
    import nxv2_bench_rows as bench
    div = sector_divider(sector_mc())
    got, want = {}, {}
    for code, w, h in SHAPES + [(1, 280, 56), (1, 320, 256), (0, 256, 167), (1, 8, 32)]:
        t, sec = frame_t(code, w, h)
        got[(code, w, h)] = t - sec * (512 * 16 + div)
        want[(code, w, h)] = bench.raw_frame_overhead(code, w, h)
    if got != want:
        raise Fail("frame overhead traced / raw_frame_overhead: " + ", ".join(
            f"{w}x{h} {got[(c, w, h)]}/{want[(c, w, h)]}" for c, w, h in got
            if got[(c, w, h)] != want[(c, w, h)]))
    code, w, h = 1, 280, 224
    mc = RawMachine(SYMS)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    items, _ = parse_train(mc)
    taila = ref_fast(code, w, h)["taila"]
    setup_frame(mc, code, w, h, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)
    mc.set_card(Card(blocks(pixels(w * h)), waits=1, crc_first=True))
    cpu = mc.cpu
    cpu.sp, cpu.pc = STACK, S("vid_raw_frame")
    cpu.push(RET)
    tr, tend = ttrace(mc, lambda c: c.pc == RET)
    tr.append((RET, 0, tend))
    pb = SCHED_PAGE_B
    one = {}                                     # (page, pc) -> its first run's T
    for (pc, p, t), (_, _, t2) in zip(tr, tr[1:]):
        one.setdefault((p, pc), t2 - t)

    def spans(a, b, page=pb):
        """T from each run of (page, a) to the next (page, b) after it."""
        out, start = [], None
        for pc, p, t in tr:
            if p == page and pc == a and start is None:
                start = t
            elif p == page and pc == b and start is not None:
                out.append(t - start)
                start = None
        return out
    at = {}
    for k, v, a in items:
        at.setdefault(k, []).append(a)
    chk = at["check"][0]
    f = S("vid_raw_frame")
    back = find_code(mc, f, f + 0x80, b"\xCD" + le(S("VR_SCHED"))) + 3
    t_sched = next(t for pc, p, t in tr if pc == S("VR_SCHED") and p == SCHED_PAGE)
    t_back = next(t for pc, p, t in tr if pc == back)
    chks = sorted(set(spans(chk, chk + 5)))
    got = dict(VR_PASS_T=one[(pb, at["call"][0])] + one[(pb, at["ret"][0])],
               VR_TPAD_T=one[(pb, at["pad"][0])],
               VR_PATCH_T=sum(one[(pb, a)] + one[(pb, a + 2)] for a in at["patch"]),
               VR_CHK_T=chks[0], VR_CHK_PAGE_T=chks[-1],
               VR_FRAME_T=t_sched + tend - t_back,
               VR_PAD_T=spans(taila, taila + 6, SCHED_PAGE)[0] - 16 * ((-w * h) % 512))
    want = {k: getattr(bench, k) for k in got}
    if got != want or len(chks) != 2:
        raise Fail(f"train T {got}, nxv2_bench_rows {want}; check spans {chks}")
    print(f"  test_fast_frame_t: overhead 320x192 {want_ov(1, 320, 192)}, 280x224 "
          f"{want_ov(1, 280, 224)}, 320x240 {want_ov(1, 320, 240)} T; counts {got}")


def want_ov(code, w, h):
    import nxv2_bench_rows as bench
    return bench.raw_frame_overhead(code, w, h)


def pump_template():
    """vrPumpT's vrPumpLen bytes from this image's VID_PAGE2 (assembled at VR_PUMP)."""
    o = S("vrPumpT") - S("OVL_ORG")
    return bytes(read_page(S("VID_PAGE2"))[o:o + S("vrPumpLen")])


def page_top(mc):
    """(pump bytes, train, stub bytes) at VR_PUMP, VR_PALTRAIN and VR_XIN in the schedule
    page (physical)."""
    base, ph = SCHED_PAGE * SLOT - S("VR_SLIDE"), mc.phys
    return tuple(bytes(ph[base + S(a):base + S(a) + n]) for a, n in
                 (("VR_PUMP", S("vrPumpLen")), ("VR_PALTRAIN", S("VR_PAL_LEN")),
                  ("VR_XIN", S("VR_XSTUB_LEN"))))


def test_paltrain():
    """The page top: VR_PUMP (VR_PUMP_LEN), VR_PALTRAIN (the 2049-byte train), VR_XIN (16 stub
    bytes to the page end), VR_SCHED_LIMIT = VR_PUMP. vid_raw_sched_build writes the pump
    template at VR_PUMP, the train and the 16 stub bytes for every geometry, over any prior
    contents, nothing between the pump's end and the train and nothing below VR_PUMP but the
    schedule; a second build leaves the page byte-identical; the schedule ends below VR_PUMP."""
    lim, n, x, xn = S("VR_PALTRAIN"), S("VR_PAL_LEN"), S("VR_XIN"), S("VR_XSTUB_LEN")
    pump, plen, slide = S("VR_PUMP"), S("vrPumpLen"), S("VR_SLIDE")
    got = (n, lim + n, x, x + xn, pump + S("VR_PUMP_LEN"), S("VR_SCHED_LIMIT"),
           plen <= S("VR_PUMP_LEN"))
    want = (len(TRAIN), x, 0xDFF0, S("DATA_WINDOW") + SLOT, lim, pump, True)
    if got != want:
        raise Fail(f"(VR_PAL_LEN, train end, VR_XIN, stub end, pump area end, VR_SCHED_LIMIT, "
                   f"vrPumpLen <= VR_PUMP_LEN) = {got}, expected {want}")
    tmpl = pump_template()
    o = SCHED_PAGE * SLOT + pump - slide
    top = S("DATA_WINDOW") + SLOT - pump
    for code, w, h in SHAPES + EXTRA:
        what = f"{code},{w}x{h}"
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.load_phys(o - 16, bytes([0xA5]) * (16 + top))   # a guard below, junk from VR_PUMP up
        before = bytes(mc.phys)
        if build_sched(mc, code, w, h).fc:
            raise Fail(f"{what}: vid_raw_sched_build set CF")
        _, end = parse_sched(mc)
        after = bytes(mc.phys)
        gap = after[o + plen:o + lim - pump]
        stub = ref_fast(code, w, h)["stub"]
        if page_top(mc) != (tmpl, TRAIN, stub) or after[o - 16:o] != bytes([0xA5]) * 16 \
                or gap != bytes([0xA5]) * len(gap) or end > pump:
            raise Fail(f"{what}: (pump, train, stub) as built "
                       f"{[a == b for a, b in zip(page_top(mc), (tmpl, TRAIN, stub))]}, "
                       f"guard {after[o - 16:o].hex()}, gap untouched "
                       f"{gap == bytes([0xA5]) * len(gap)}, schedule end ${end:04X}")
        stray_writes(before, after, gen_allow(lambda k: k < pump - 16 - slide
                                              or pump - slide <= k < pump - slide + plen
                                              or k >= lim - slide))
        page = after[SCHED_PAGE * SLOT:(SCHED_PAGE + 1) * SLOT]
        build_sched(mc, code, w, h)
        if bytes(mc.phys[SCHED_PAGE * SLOT:(SCHED_PAGE + 1) * SLOT]) != page:
            raise Fail(f"{what}: a second build changed the schedule page")


def test_pal_t():
    """vid_raw_pal after its call vr_sector, the card at the palette sector's first data byte:
    11,909 T to the return into its caller (123 - 10 + 10 + 512 x 23 + 10; the 49 T loop it
    replaced took 25,216); NR $43 = vidPalCtrl xor $40, NR $40 = 0, then NR $44 selected at
    $243B and given the 512 stream bytes in order, each read by the train 23 T after the last.
    Then a whole palette frame (vid_raw_frame, tag 1, CRC due): token to the first train read
    and the last train read to the next sector's CRC both at least 16 T, no gap under 15."""
    pal = bytes((i * 29 + 11) & 255 for i in range(512))
    mc = RawMachine(SYMS)
    if build_sched(mc, 0, 256, 192).fc:
        raise Fail("vid_raw_sched_build set CF")
    mc.nrlog = []                                   # the generator's own MMU6 writes
    mc.map(7, S("VID_PAGE"))
    mc.poke("vidPalCtrl", 0x10)
    mc.poke("vidPalPending", 0)
    card = Card(open_data=pal)
    mc.set_card(card)
    at = S("vid_raw_pal")
    if bytes(mc.mem[at:at + 3]) != b"\xCD" + le(S("vr_sector")):
        raise Fail("vid_raw_pal does not open with call vr_sector")
    cpu = mc.cpu
    cpu.sp = STACK
    cpu.push(RET)
    cpu.pc, cpu.b, cpu.c, cpu.de, cpu.hl = at + 3, 0x5A, PORT_SPI, 0x1234, 0x4000
    t, marks = io_trace(mc, RET)
    gaps = [b - a for a, b in zip(marks, marks[1:])]
    nr = S("NR_PAL_VALUE9")
    vals = [v for r, v in mc.nrlog if r == nr]
    head = [e for e in mc.nrlog if e[0] != nr]
    got = (t, sorted(set(gaps)), len(gaps), bytes(vals) == pal, len(vals), head, mc.sel,
           mc.peek("vidPalPending"), card.pos, cpu.sp)
    want = (11909, [23], 511, True, 512, [(S("NR_PAL_CTRL"), 0x50), (S("NR_PAL_INDEX"), 0)],
            nr, 1, 512, STACK)
    if got != want:
        raise Fail(f"(T, gaps, n gaps, NR $44 in order, NR $44 writes, other NR, $243B, "
                   f"vidPalPending, reads, SP) = {got}, expected {want}")
    lo, hi = S("VR_PALTRAIN"), S("VR_PALTRAIN") + S("VR_PAL_LEN")
    if any(not lo <= pc < hi for _, pc in card.log):
        raise Fail("a palette byte was read outside the train")
    # a whole palette frame: the joins
    mc = RawMachine(SYMS)
    if build_sched(mc, 0, 256, 192).fc:
        raise Fail("vid_raw_sched_build set CF")
    _, sectors = setup_frame(mc, 0, 256, 192, tag=1, crc_due=1)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)                      # no PLAY poll inside the trace
    card = Card([pal] + blocks(pixels(256 * 192)), waits=1, crc_first=True)
    mc.set_card(card)
    cpu = mc.cpu
    cpu.sp = STACK
    cpu.push(RET)
    gaps = io_gaps(mc, S("vid_raw_frame"), RET)
    if cpu.a != S("VOP_KFLIP") or card.pos != len(card.stream):
        raise Fail(f"palette frame: A ${cpu.a:02X}, {len(card.stream) - card.pos} reads left")
    ph = [p for p, _ in card.log]
    i = ph.index("data")
    tin, tout = gaps[i - 1], gaps[i + 511]
    if (ph[i - 1], ph[i + 512], set(gaps[i:i + 511])) != ("token", "crc", {23}):
        raise Fail(f"palette frame: read {i - 1} {ph[i - 1]}, read {i + 512} {ph[i + 512]}, "
                   f"train gaps {sorted(set(gaps[i:i + 511]))}")
    if min(tin, tout) < 16 or min(gaps) < 15:
        raise Fail(f"palette frame: token to train {tin} T, train to CRC {tout} T, "
                   f"minimum gap {min(gaps)} T")
    print(f"  test_pal_t: token to train {tin} T, train 23 T, train to CRC {tout} T, "
          f"frame minimum {min(gaps)} T")


PUMP_PAGE = 40              # MMU6 at the pump's entry: a page in no other slot
# (real sound bytes, sectors): stereo 25 fps, mono 25 fps, mono 15.26 fps (074: the tag alone
# in the third sector), stereo 16.67 fps, stereo 12.5 fps
PUMP_CASES = ((1250, 3), (625, 2), (1024, 3), (1874, 4), (2500, 5))
PUMP_CELLS = (("vidAudWr", 2), ("vidAudFeedRem", 2), ("vidDsAudBlkRem", 2), ("vidRawTag", 1),
              ("vidStrmRemainBlk", 3), ("vidStrmRunBlkH", 2), ("vidDsFrmBlk", 1),
              ("vidDsCrcDue", 1))


def pad_bytes(n, tag):
    """n - 1 pad bytes, none of them a legal tag, then the tag."""
    return bytes(0x80 | (i * 5) & 0x7F for i in range(n - 1)) + bytes([tag])


def snd_section(real, nsec, tag, seed=0):
    """A raw sound section as the encoder lays it out: the real bytes, the pad, the tag."""
    return (bytes((i * 11 + 5 + seed) & 0xFF for i in range(real))
            + pad_bytes(nsec * 512 - real, tag))


def img_addr(syms, name):
    try:
        return syms[name][1]
    except KeyError:
        raise Fail(f"symbol {name} is not in that image's SLD") from None


def img_aborts(syms):
    """aborts() for an image's symbols."""
    def stop(where):
        def t(cpu):
            raise Stop(where, cpu.a)
        return t
    a, b = img_addr(syms, "vid_dec_abort"), img_addr(syms, "vid_dec_abort_pos")
    if a == b:
        return {a: stop("vid_dec_abort/vid_dec_abort_pos")}
    return {a: stop("vid_dec_abort"), b: stop("vid_dec_abort_pos")}


def pump_mc(real, nsec, wr, rd=None, tag=1, run=1000, crc=1, waits=1, syms=None, pages=None,
            sectors=None):
    """A raw direct session on an image (this build's, or syms and pages: another's): the
    open's patches (vid_stage_common.vec), the schedule bank built (320x192), MMU7 = VID_PAGE,
    MMU6 = PUMP_PAGE; the feed staged for real sound bytes in nsec sectors, the write cursor
    wr, HL' = rd (default wr: the ring empty), the ring $EE, the run count, the remain
    $012345, the bound 255; the card at the section (a CRC pends when crc), waits $FF before
    each token."""
    syms = syms or SYMS
    mc = RawMachine(syms, pages) if pages else RawMachine(syms)
    hot = img_addr(syms, "VID_PAGE")
    mc.map(7, img_addr(syms, "VID_PAGE2"))
    mc.map(6, hot)
    mc.poke("vidDeliverDir", 1)
    mc.poke("vidP_Raw", 1)
    mc.run(img_addr(syms, "vid_stage_common.vec"))
    mc.map(6, SCHED_PAGE)
    mc.poke("vidRingBanksC", SCHED_PAGE // 2)
    mc.poke("vidP_Shape", 1)
    mc.poke("vidP_HeightB", 192)
    mc.poke("vidP_RawW", le(320))
    mc.poke("vidP_RawX0", 0)
    if mc.run(img_addr(syms, "vid_raw_sched_build"), traps=img_aborts(syms)).fc:
        raise Fail("vid_raw_sched_build set CF")
    mapnr(mc, 7, hot)
    mapnr(mc, 6, PUMP_PAGE)
    for name, v in (("vidRawSchedPage", SCHED_PAGE), ("vidDirect", 1), ("vidStreaming", 0),
                    ("vidRawTag", 0x77), ("vidDsCrcDue", crc), ("vidDsFrmBlk", 0),
                    ("vidDsBound", 255), ("vidApadBlk", nsec)):
        mc.poke(name, v)
    for name, v in (("vidABytes", real), ("vidABytesPad", nsec * 512), ("vidAudFeedRem", real),
                    ("vidDsAudBlkRem", 0), ("vidAudWr", wr), ("vidStrmRunBlkH", run)):
        mc.poke(name, le(v))
    mc.poke("vidStrmRemainBlk", (0x012345).to_bytes(3, "little"))
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in syms:
            mc.poke(n, 250)                      # no PLAY poll inside a run
    base = img_addr(syms, "vidAudBuf")
    mc.mem[base:base + 8192] = bytes([0xEE]) * 8192
    set_alt_hl(mc.cpu, wr if rd is None else rd)
    mc.cpu.iff = 1
    if sectors is None:
        sectors = blocks(snd_section(real, nsec, tag))
    mc.set_card(Card(sectors, waits=waits, crc_first=bool(crc)))
    return mc


def pump_state(mc, syms=None):
    """(ring, {cell: value}, card reads) after a pump run."""
    syms = syms or SYMS
    base = img_addr(syms, "vidAudBuf")
    cells = {n: int.from_bytes(mc.mem[img_addr(syms, n):img_addr(syms, n) + k], "little")
             for n, k in PUMP_CELLS}
    return bytes(mc.mem[base:base + 8192]), cells, mc.card.pos


def ring_want(wr, snd):
    """The $EE ring with snd written from wr, wrapping at the ring end."""
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    ring = bytearray([0xEE]) * n
    for i, b in enumerate(snd):
        ring[(wr - base + i) % n] = b
    return bytes(ring)


def pump_run(mc, traps=None):
    """vid_aud_pump, BC = $FFFF, to its return: the number of slide calls (a fetch in
    VR_SLIDE..VR_SLIDE_END with the schedule page at MMU6, after one outside it)."""
    cpu = mc.cpu
    traps = {**aborts(), **(traps or {})}
    cpu.bc, cpu.sp = 0xFFFF, STACK
    cpu.push(RET)
    cpu.pc = S("vid_aud_pump")
    lo, hi = S("VR_SLIDE"), S("VR_SLIDE_END")
    calls, inside, budget = 0, False, 3_000_000
    while cpu.pc != RET:
        t = traps.get(cpu.pc)
        if t is not None:
            t(cpu)
            continue
        now = lo <= cpu.pc <= hi and mc.mmu[6] == SCHED_PAGE
        calls += now and not inside
        inside = now
        cpu.step()
        budget -= 1
        if budget <= 0:
            raise Fail("vid_aud_pump did not return")
    mc.sync()
    return calls


def whole_calls(real):
    """Slide calls of a section with no ring wrap: each whole sector, the last sector's real
    bytes (none when they end on a sector boundary), its pad and tag."""
    return (real >> 9) + (1 if real & 511 else 0) + 1


def pump_allow(mc, cells=None):
    """stray_writes allowance for a pump run on mc: the ring's page, VR_SCRATCH, the stack,
    and on VID_PAGE only cells (default PUMP_CELLS) and the DEBUG PLAY divider's cells."""
    names = (PUMP_CELLS if cells is None else cells) + (
        ("vidRlDiv", 1), ("vidRlSpinDiv", 1), ("vidRlLast", 2), ("vidRlFields", 2),
        ("vidTokPolls", 2), ("vidTokCalls", 2))
    hot = set()
    for name, n in names:
        if name in SYMS:
            hot |= {(SYMS[name][1] & 0x1FFF) + k for k in range(n)}
    scr = S("VR_SCRATCH") - S("VR_SLIDE")
    return {S("VID_PAGE"): lambda k: k in hot,
            mc.mmu[S("vidAudBuf") >> 13]: True,
            5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000,
            SCHED_PAGE: lambda k: scr <= k < scr + 512}


def test_pump_cells():
    """For each PUMP_CASES section (a CRC due, the token on poll 2, the write cursor at
    vidAudBuf + 100, the ring empty, MMU6 another page): the baseline DEBUG image's
    vid_aud_pump (BC = $FFFF; its raw patches: vid_ds_xfer, vid_ds_blkopen, vid_raw_apad)
    against this image's patched vid_aud_pump (vid_raw_pump, VR_PUMP): the ring, vidAudWr,
    vidAudFeedRem, vidDsAudBlkRem, vidRawTag, vidStrmRemainBlk, vidStrmRunBlkH, vidDsFrmBlk,
    vidDsCrcDue and the card reads equal; MMU6 (NR $56 too) = the schedule page; nothing
    written but the ring, those cells, VR_SCRATCH and the stack."""
    osyms, opages = base_image("debug")
    base = S("vidAudBuf")
    if img_addr(osyms, "vidAudBuf") != base:
        raise Fail("the baseline's vidAudBuf differs")
    for real, nsec in PUMP_CASES:
        what = f"{real} sound bytes in {nsec} sectors"
        old = pump_mc(real, nsec, base + 100, syms=osyms, pages=opages)
        old.run(img_addr(osyms, "vid_aud_pump"), traps=img_aborts(osyms), bc=0xFFFF)
        new = pump_mc(real, nsec, base + 100)
        new.sync()
        before = bytes(new.phys)
        pump_run(new)
        stray_writes(before, bytes(new.phys), pump_allow(new))
        o, n = pump_state(old, osyms), pump_state(new)
        if o[0] != n[0]:
            bad = next(i for i in range(len(o[0])) if o[0][i] != n[0][i])
            raise Fail(f"{what}: the ring differs first at +${bad:04X}")
        if o[1:] != n[1:] or (new.mmu[6], new.nr.get(0x56)) != (SCHED_PAGE, SCHED_PAGE):
            diff = {k: (o[1][k], n[1][k]) for k in o[1] if o[1][k] != n[1][k]}
            raise Fail(f"{what}: cells differ (baseline, new) {diff}; card reads {o[2]} / "
                       f"{n[2]}; MMU6 {new.mmu[6]}, NR $56 {new.nr.get(0x56)}")
        if n[1]["vidAudFeedRem"] or n[1]["vidRawTag"] != 1 or n[2] != len(new.card.stream):
            raise Fail(f"{what}: both left the feed {n[1]['vidAudFeedRem']}, tag "
                       f"{n[1]['vidRawTag']}, {len(new.card.stream) - n[2]} reads unmade")


def test_pump_boundary():
    """1024 sound bytes in 3 sectors (clip 074's layout: the tag alone in the third): its
    512 data bytes each by an ini of the slide into VR_SCRATCH in order, the tag its 512th
    byte; a tag above 1 is stored and reaches vid_dec_abort with A = VID_ERR_OP."""
    for tag in (1, 0, 2):
        what = f"1024 bytes, tag {tag}"
        mc = pump_mc(1024, 3, S("vidAudBuf") + 100, tag=tag)
        scr = SCHED_PAGE * SLOT + S("VR_SCRATCH") - S("VR_SLIDE")
        mc.load_phys(scr, bytes([0xA5]) * 512)
        stop = None
        try:
            pump_run(mc)
        except Stop as e:
            stop = e
        mc.sync()
        sec3 = blocks(snd_section(1024, 3, tag))[2]
        log = mc.card.log
        first = 2 * (2 + 1 + 1 + 512) + 2 + 1 + 1           # sector 3's first data read
        rd = [(ph, pc) for ph, pc in log[first:]]
        owner = owner_fn(mc)
        sp = SCHED_PAGE * SLOT - S("VR_SLIDE")
        bad = [i for i, (ph, pc) in enumerate(rd) if ph != "data" or owner(pc) != "slide"
               or bytes(mc.phys[sp + pc:sp + pc + 2]) != b"\xED\xA2"]
        if len(rd) != 512 or bad or bytes(mc.phys[scr:scr + 512]) != sec3:
            raise Fail(f"{what}: {len(rd)} reads after sector 3's token, not slide ini "
                       f"{bad[:4]}, VR_SCRATCH {'is' if mc.phys[scr:scr + 512] == sec3 else 'is not'}"
                       f" sector 3")
        if mc.peek("vidRawTag") != tag:
            raise Fail(f"{what}: vidRawTag {mc.peek('vidRawTag')}")
        if tag >= 2:
            if stop is None or not reached(stop, "vid_dec_abort") or stop.a != S("VID_ERR_OP"):
                raise Fail(f"{what}: {stop or 'returned'}, expected vid_dec_abort, VID_ERR_OP")
        elif stop is not None:
            raise Fail(f"{what}: {stop}")


def test_pump_wrap():
    """A section whose real bytes pass the ring end: written up to $8000, the rest from
    vidAudBuf, one extra slide call, vidAudWr past the wrap. The write cursor $8000 - 300
    with 1250 bytes (the split in a whole sector): vidAudWr = vidAudBuf + 950. Also: a whole
    sector or the last real byte ending on $8000 exactly (no extra call, the cursor wraps to
    vidAudBuf), the split in the last sector's real part, and in a mono first sector. Nothing
    written but the ring, the pump's cells, VR_SCRATCH and the stack."""
    base, end = S("vidAudBuf"), S("vidAudBuf") + S("NXV_AUD_RING")
    for back, real, nsec, extra in ((300, 1250, 3, 1), (512, 1250, 3, 0), (1024, 1250, 3, 0),
                                    (1100, 1250, 3, 1), (1250, 1250, 3, 0), (100, 625, 2, 1),
                                    (2000, 1250, 3, 0)):
        what = f"write cursor $8000 - {back}, {real} bytes"
        wr = end - back
        mc = pump_mc(real, nsec, wr)
        mc.sync()
        before = bytes(mc.phys)
        calls = pump_run(mc)
        stray_writes(before, bytes(mc.phys), pump_allow(mc))
        snd = snd_section(real, nsec, 1)[:real]
        got = (calls, mc.peek("vidAudWr", 2), mc.peek("vidAudFeedRem", 2), mc.peek("vidRawTag"),
               mc.card.pos == len(mc.card.stream))
        want = (whole_calls(real) + extra, base + (wr - base + real) % S("NXV_AUD_RING"), 0, 1,
                True)
        if got != want:
            raise Fail(f"{what}: (slide calls, vidAudWr, feedRem, tag, all read) = {got}, "
                       f"expected {want}")
        if bytes(mc.mem[base:end]) != ring_want(wr, snd):
            ring = mc.mem[base:end]
            bad = next(i for i in range(end - base) if ring[i] != ring_want(wr, snd)[i])
            raise Fail(f"{what}: the ring differs first at +${bad:04X}")


def test_pump_room():
    """Room is all or nothing against the whole feed: room = ring - guard - (writer - reader)
    mod ring. The reader 2 bytes ahead of the writer: no card read, every cell unchanged;
    the reader one frame behind: the feed completes. At the edge (1250 bytes): (writer -
    reader) mod ring = ring - guard - 1250 completes, one byte more reads nothing."""
    base, ring, guard = S("vidAudBuf"), S("NXV_AUD_RING"), S("NXV_AUD_GUARD")
    wr = base + 4000
    for unplayed, done in ((ring - 2, False), (1250, True), (ring - guard - 1250, True),
                           (ring - guard - 1249, False), (0, True)):
        what = f"(writer - reader) mod ring = {unplayed}"
        rd = base + (wr - base - unplayed) % ring
        mc = pump_mc(1250, 3, wr, rd=rd)
        before = pump_state(mc)
        pump_run(mc)
        after = pump_state(mc)
        if done:
            if after[1]["vidAudFeedRem"] or after[2] != len(mc.card.stream) \
                    or after[1]["vidAudWr"] != wr + 1250:
                raise Fail(f"{what}: feedRem {after[1]['vidAudFeedRem']}, "
                           f"{len(mc.card.stream) - after[2]} reads unmade, wr "
                           f"${after[1]['vidAudWr']:04X}")
        elif after != before:
            raise Fail(f"{what}: {after[2]} card reads, cells "
                       f"{ {k: v for k, v in after[1].items() if before[1][k] != v} } changed")
        if (mc.mmu[6], alt_hl(mc.cpu), mc.cpu.iff) != (SCHED_PAGE, rd, 1):
            raise Fail(f"{what}: MMU6 {mc.mmu[6]}, HL' ${alt_hl(mc.cpu):04X}, IFF {mc.cpu.iff}")


def test_pump_runwalk():
    """The run count 1 at the section (1250 bytes, 3 sectors): the first sector takes the
    run's last block; vid_run_walk_h (trapped: a run of 5, BC and DE corrupt) entered once,
    at the second sector after its CRC pair and before its first poll; the third sector
    counts the fresh run (3 left); the ring, vidAudWr and the tag as without the walk."""
    base = S("vidAudBuf")
    mc = pump_mc(1250, 3, base + 100, run=1)
    fired = []

    def walk(cpu):
        fired.append((mc.card.pos, mc.card.log[-1][0]))
        cpu.hl, cpu.fc = 5, 0
        cpu.a = cpu.b = cpu.c = cpu.d = cpu.e = 0xA5
    pump_run(mc, {S("vid_run_walk_h"): ret_trap(walk)})
    snd = snd_section(1250, 3, 1)[:1250]
    got = (fired, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidAudWr", 2), mc.peek("vidRawTag"),
           mc.card.pos == len(mc.card.stream), bytes(mc.mem[base:base + 8192]) == ring_want(
               base + 100, snd))
    want = ([(516 + 2, "crc")], 3, base + 1350, 1, True, True)
    if got != want:
        raise Fail(f"(walks (reads, last phase), run count, wr, tag, all read, ring) = {got}, "
                   f"expected {want}")


def test_pump_faults():
    """The section's charges before its first open (sections of 3 and 2 sectors): the remain
    below the section's sectors (0..n-1) and the bound passed by one (vidDsFrmBlk + n =
    vidDsBound + 1) stop at vid_dec_abort_pos with VID_ERR_SRCOVR, no card read, nothing
    written but vidDsFrmBlk and the stack, the remain kept. The remain $010000 + k (k < n:
    the borrow crosses its 16-bit word) and the bound met exactly complete the section, the
    remain $010000 + k - n."""
    base = S("vidAudBuf")
    for real, nsec in PUMP_CASES[:2]:
        cases = [(f"remain {r}", r, 0, 255, True) for r in range(nsec)]
        cases += [(f"remain ${0x010000 + k:06X}", 0x010000 + k, 0, 255, False)
                  for k in range(nsec)]
        cases += [("bound + 1", 0x012345, 41 - nsec, 40, True),
                  ("bound met", 0x012345, 40 - nsec, 40, False)]
        for what, remain, frm, bound, fault in cases:
            what = f"{real} bytes in {nsec} sectors, {what}"
            mc = pump_mc(real, nsec, base + 100)
            mc.poke("vidStrmRemainBlk", remain.to_bytes(3, "little"))
            mc.poke("vidDsFrmBlk", frm)
            mc.poke("vidDsBound", bound)
            mc.sync()
            before = bytes(mc.phys)
            stop = None
            try:
                pump_run(mc)
            except Stop as e:
                stop = e
            mc.sync()
            got = (mc.peek("vidStrmRemainBlk", 3), mc.peek("vidDsFrmBlk"), mc.card.pos)
            if fault:
                if stop is None or not reached(stop, "vid_dec_abort_pos") \
                        or stop.a != S("VID_ERR_SRCOVR") or got != (remain, frm + nsec, 0):
                    raise Fail(f"{what}: {stop or 'returned'}; (remain, FrmBlk, card reads) = "
                               f"{got}, expected vid_dec_abort_pos with VID_ERR_SRCOVR and "
                               f"{(remain, frm + nsec, 0)}")
                frm_at = S("vidDsFrmBlk") & 0x1FFF
                stray_writes(before, bytes(mc.phys),
                             {S("VID_PAGE"): lambda k: k == frm_at,
                              5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000})
                continue
            if stop is not None or got != (remain - nsec, frm + nsec, len(mc.card.stream)) \
                    or mc.peek("vidAudFeedRem", 2):
                raise Fail(f"{what}: {stop or 'returned'}; (remain, FrmBlk, card reads) = {got}, "
                           f"expected {(remain - nsec, frm + nsec, len(mc.card.stream))}")


def test_pump_t():
    """T from call vid_aud_pump to its return on Release instructions (a plain DEBUG image
    less vr_sector_n's PLAY divider at each sector open): a CRC due, the token on poll 2, no
    wrap, no walk, the ring empty, for (sectors, real) (3, 1250), (2, 625), (3, 1024) equal to
    nxv2_bench_rows RAW_PUMP_T. Prints the baseline image's figure for the same variant (its
    DEBUG probes included on a plain DEBUG image) and the difference."""
    import nxv2_bench_rows as bench
    divider = 0
    if plain_debug():
        divider = stub_t(sector_mc(), b"\x16\x00\xCD" + le(S("vid_dst_norm_flat")) + b"\xC9")
    osyms, opages = base_image()
    call = b"\xCD" + le(S("vid_aud_pump")) + b"\xC9"
    ocall = b"\xCD" + le(img_addr(osyms, "vid_aud_pump")) + b"\xC9"
    got, notes = {}, []
    for real, nsec in PUMP_CASES[:3]:
        mc = pump_mc(real, nsec, S("vidAudBuf") + 100)
        t = stub_t(mc, call, bc=0xFFFF) - nsec * divider
        if mc.peek("vidAudFeedRem", 2) or mc.card.pos != len(mc.card.stream):
            raise Fail(f"{real} bytes: the pump did not complete the section")
        old = pump_mc(real, nsec, S("vidAudBuf") + 100, syms=osyms, pages=opages)
        ot = stub_t(old, ocall, bc=0xFFFF)
        got[(nsec, real)] = t
        notes.append(f"{nsec}x{real}: {t} T ({t - 512 * nsec * 16} over the bytes), baseline "
                     f"{ot} T, {ot - t} less")
    want = getattr(bench, "RAW_PUMP_T", None)
    if got != want:
        raise Fail(f"pump T {got}, nxv2_bench_rows RAW_PUMP_T {want}")
    print("  test_pump_t: " + "; ".join(notes))


def play_mc(real, nsec, tag):
    """Playback after a present: a patched raw direct 256x192 session, the schedule built,
    MMU6 = PUMP_PAGE, the card at a sound section of nsec sectors (real sound bytes, the pad,
    the tag), then the frame (with its palette sector when tag = 1)."""
    mc = RawMachine(SYMS)
    patch_session(mc, 1, 1)
    if build_sched(mc, 0, 256, 192).fc:
        raise Fail("vid_raw_sched_build set CF")
    setup_frame(mc, 0, 256, 192)
    mapnr(mc, 6, PUMP_PAGE)
    rw_cells(mc, run=1000, crc=0)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 250)                      # no PLAY poll inside the trace
    base = S("vidAudBuf")
    mc.poke16("vidABytes", real)
    mc.poke16("vidAudWr", (base + 100) ^ (S("NXV_AUD_RING") // 2))
    set_alt_hl(mc.cpu, base + 100)
    mc.cpu.iff = 1
    snd = bytes((i * 11 + 5) & 0xFF for i in range(real)) + pad_bytes(nsec * 512 - real, tag)
    pal = [bytes((i * 29 + 11) & 255 for i in range(512))] if tag else []
    mc.set_card(Card(blocks(snd) + pal + blocks(pixels(256 * 192)), waits=1))
    return mc


def gap_rules(mc, gaps, what, lows, upto=None):
    """Read gaps against the general rule everywhere (none under 15 T, under 16 only within a
    CRC pair) and the pump's rules for the gaps before index upto (all when None): 16 inside a
    slide call, over 60 between two, token to data over 40, CRC 2 to poll 1 over 100. lows:
    kind -> the least gap seen under the pump's rules."""
    log = mc.card.log
    owner = owner_fn(mc)
    for i, g in enumerate(gaps):
        (p0, a0), (p1, a1) = log[i], log[i + 1]
        pair = p0 == p1 == "crc"
        if g < 15 or g < 16 and not pair:
            raise Fail(f"{what}: read {i} ({p0}) to {i + 1} ({p1}): {g} T")
        if upto is not None and i >= upto:
            continue
        if p0 == p1 == "data" and owner(a0) == owner(a1) == "slide":
            kind, ok = ("slide", g == 16) if a1 == a0 + 2 else ("between slide calls", g > 60)
        elif p0 == "token" and p1 == "data":
            kind, ok = "token to data", g > 40
        elif p0 == "crc" and p1 in ("wait", "token"):
            kind, ok = "CRC 2 to poll 1", g > 100
        elif pair:
            kind, ok = "CRC pair", True
        else:
            kind, ok = f"{p0} to {p1}", True
        if not ok:
            raise Fail(f"{what}: read {i} ({p0}) to {i + 1} ({p1}), {kind}: {g} T")
        lows[kind] = min(lows.get(kind, g), g)


def test_pump_gaps():
    """io_gaps from call vid_aud_pump to its return over each PUMP_CASES section, a CRC due
    and not (the preload), the token on poll 1 and on poll 2, and a ring wrap inside a whole
    sector and inside the last sector's real bytes: no gap under 15 T, under 16 only within a
    CRC pair (values discarded); 16 T inside a slide call, the token to the first data read
    over 40, between two slide calls over 60, CRC 2 to poll 1 over 100. Then playback's calls
    (stage, pump, decode) over sections ending mid-sector, one byte short of a sector and on
    a sector boundary: the last sound byte (or the tag sector's token) to the first pad read
    and the tag to the next sector's CRC at least 16 T, the same rules throughout."""
    lows = {}
    end = S("vidAudBuf") + S("NXV_AUD_RING")
    runs = [(real, nsec, end - 4000, crc, waits) for real, nsec in PUMP_CASES
            for crc in (0, 1) for waits in (0, 1)]
    runs += [(1250, 3, end - 300, 1, 1), (1250, 3, end - 1100, 1, 1), (625, 2, end - 100, 0, 1)]
    for real, nsec, wr, crc, waits in runs:
        what = f"{real} bytes, wr ${wr:04X}, crc {crc}, waits {waits}"
        mc = pump_mc(real, nsec, wr, crc=crc, waits=waits)
        mc.cpu.sp, mc.cpu.bc = STACK, 0xFFFF
        mc.cpu.push(RET)
        gaps = io_gaps(mc, S("vid_aud_pump"), RET)
        if mc.card.pos != len(mc.card.stream) or mc.peek("vidAudFeedRem", 2):
            raise Fail(f"{what}: {len(mc.card.stream) - mc.card.pos} reads left")
        gap_rules(mc, gaps, what, lows)
    stub = (b"\xCD" + le(S("vid_aud_stage")) + b"\x01\xFF\xFF\xCD" + le(S("vid_aud_pump"))
            + b"\xCD" + le(S("vid_decode_any")) + b"\xC9")
    joins = []
    for real, nsec, tag in ((1250, 3, 1), (1023, 2, 0), (1024, 3, 0)):
        what = f"playback, {real} sound bytes, tag {tag}"
        mc = play_mc(real, nsec, tag)
        card = mc.card
        mc.mem[STUB:STUB + len(stub)] = stub
        cpu = mc.cpu
        cpu.sp, cpu.pc = STACK, STUB
        cpu.push(RET)
        _, marks = io_trace(mc, RET)
        if cpu.a != S("VOP_KFLIP") or card.pos != len(card.stream) \
                or mc.peek("vidRawTag") != tag:
            raise Fail(f"{what}: A ${cpu.a:02X}, {len(card.stream) - card.pos} reads left, "
                       f"tag {mc.peek('vidRawTag')}")
        gaps = [b - a for a, b in zip(marks, marks[1:])]
        ph = [p for p, _ in card.log]
        data = [i for i, p in enumerate(ph) if p == "data"]
        pad0, tag_i = data[real], data[nsec * 512 - 1]
        lead = "token" if real % 512 == 0 else "data"
        if ph[pad0 - 1] != lead or ph[tag_i + 1] != "crc":
            raise Fail(f"{what}: before the pad {ph[pad0 - 1]}, after the tag {ph[tag_i + 1]}")
        tin, tout = gaps[pad0 - 1], gaps[tag_i]
        if min(tin, tout) < 16:
            raise Fail(f"{what}: into the pad {tin} T, tag to CRC {tout} T")
        gap_rules(mc, gaps, what, lows, upto=tag_i)
        joins.append(f"{real}: {lead} to pad {tin}, tag to CRC {tout}")
    print("  test_pump_gaps: least " + ", ".join(f"{k} {v}" for k, v in sorted(lows.items()))
          + " T; " + "; ".join(joins) + " T")


def test_vec_patch():
    hot = S("VID_PAGE")
    for direct, raw in ((1, 1), (1, 0), (0, 1), (0, 0)):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.map(6, hot)
        mc.poke("vidDeliverDir", direct)
        mc.poke("vidP_Raw", raw)
        mc.run("vid_stage_common.vec")
        mc.map(6, 12)
        mc.map(7, hot)
        dec, pad = S("vid_decode_any.raw"), S("vid_aud_pump.apad")
        if mc.mem[dec] != 0xC2 or mc.mem[pad] != 0xCD:
            raise Fail("vid_decode_any.raw is not jp nz / vid_aud_pump.apad is not call")
        got = (mc.mem[dec + 1] | mc.mem[dec + 2] << 8, mc.mem[pad + 1] | mc.mem[pad + 2] << 8,
               mc.peek("vidRaw"), mc.peek("vidDirect"))
        want = ((S("vid_raw_frame") if raw else S("vid_decode_frame_ds")), S("vid_ds_pad"),
                raw, direct)
        if got != want:
            raise Fail(f"direct {direct} raw {raw}: operands/cells {[hex(x) for x in got]}, "
                       f"expected {[hex(x) for x in want]}")


def vec_sites(raw):
    """[(site, address, bytes)]: each play pointer and pump site after an open, raw or not
    (vid_aud_pump.rd and .apad are never reached in a raw session and keep their bytes)."""
    prime = b"\xCD" + le(S("vid_raw_prime")) + b"\x00"
    return [("vid_pace_poll.rd", S("vid_pace_poll.rd"),
             b"\xCD" + le(S("vid_raw_rdv")) if raw else b"\xDD\xE5\xE1"),
            ("vid_aud_pump.rd", S("vid_aud_pump.rd"), b"\xDD\xE5\xD1"),
            ("vid_aud_pump", S("vid_aud_pump"), b"\xC3" + le(S("vid_raw_pump")) if raw
             else b"\xED\x43" + bytes([S("vidAudBudget") & 0xFF])),
            ("vid_run.ixp1", S("vid_run.ixp1"), prime if raw else ix_form()),
            ("vid_run.ixp2", S("vid_run.ixp2"), prime if raw else ix_form()),
            ("vid_aud_pump.apad + 1", S("vid_aud_pump.apad") + 1, le(S("vid_ds_pad"))),
            ("vid_raw_rdv", S("vid_raw_rdv"), b"\xC3" + le(S("vid_raw_rd_hl")))]


def test_vec_sites():
    """vid_stage_common.vec for a raw header, then a non-raw one, then raw again on the same
    machine: after each, every site holds its column's bytes (vid_aud_pump's first three bytes
    jp vid_raw_pump, else the assembled ld (vidAudBudget), bc head)."""
    mc = RawMachine(SYMS)
    for raw in (1, 0, 1):
        patch_session(mc, 1, raw)
        for name, a, want in vec_sites(raw):
            got = bytes(mc.mem[a:a + len(want)])
            if got != want:
                raise Fail(f"raw {raw}: {name} {got.hex(' ').upper()}, expected "
                           f"{want.hex(' ').upper()}")


def test_raw_stage():
    hot = S("VID_PAGE")
    for x0, bank, sec, var in ((0, 50, 120, 1), (20, 7, 123, 0), (158, 111, 1, 1),
                               (32, 60, 120, 0)):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.map(6, hot)
        mc.poke("vidRingBanksC", bank)
        mc.poke("vidRawSecC", sec)
        mc.poke("vidCapBlkC", sec + 1)
        mc.poke("vidP_RawX0", x0)
        mc.poke("vrgVar", var)
        off = S("DATA_WINDOW") - S("OVL_ORG")
        mc.mem[S("vidRawTag") + off] = 0x77
        mc.mem[S("vidRawVar") + off] = 0x77
        mc.run("vid_raw_stage")
        got = tuple(mc.mem[S(n) + off] for n in ("vidRawSchedPage", "vidRawSec", "vidRawCap",
                                                 "vidRawPage0", "vidRawH0", "vidRawTag",
                                                 "vidRawVar"))
        want = (bank * 2, sec, sec + 1, x0 >> 5, 0x40 + (x0 & 31), 0, var)
        if got != want:
            raise Fail(f"x0 {x0} bank {bank}: {got}, expected {want}")


# --------------------------------------------------------------------------- sound handlers

MAIN = {"a": 0x5A, "b": 0x12, "c": 0x34, "d": 0x56, "e": 0x78, "h": 0x9A, "l": 0xBC}
MAIN_F = (1, 0, 1)                          # fz, fc, fs
ALT_BCDE = {"b": 0x11, "c": 0x22, "d": 0x33, "e": 0x44}


def set_main(cpu):
    for k, v in MAIN.items():
        setattr(cpu, k, v)
    cpu.fz, cpu.fc, cpu.fs = MAIN_F
    cpu.ix, cpu.iy = 0xDEAD, 0xBEEF


def main_kept(cpu, what, but=()):
    got = {k: getattr(cpu, k) for k in MAIN if k not in but}
    want = {k: v for k, v in MAIN.items() if k not in but}
    if got != want or (cpu.fz, cpu.fc, cpu.fs) != MAIN_F or (cpu.ix, cpu.iy) != (0xDEAD, 0xBEEF):
        raise Fail(f"{what}: main set {got} F {(cpu.fz, cpu.fc, cpu.fs)} IX ${cpu.ix:04X} "
                   f"IY ${cpu.iy:04X}, expected {want} F {MAIN_F} IX $DEAD IY $BEEF")


def alt_hl(cpu):
    return cpu.alt["h"] << 8 | cpu.alt["l"]


def set_alt_hl(cpu, v):
    cpu.alt["h"], cpu.alt["l"] = v >> 8, v & 0xFF


def ring_pattern():
    """Ring bytes that differ from their neighbours and from the same offset a page away."""
    return bytes((i * 37 + 11 + (i >> 8) * 101) & 0xFF for i in range(S("NXV_AUD_RING")))


def isr_machine():
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    ring = ring_pattern()
    base = S("vidAudBuf")
    mc.mem[base:base + len(ring)] = ring
    mc.dac = []
    return mc, ring


def isr_tick(mc, name, hlp, at=None):
    """One interrupt into handler name (or the code at address at): IFF clear (the
    acknowledge), HL' = hlp, run to RETI. Asserts the main set, IX, IY, BC', DE' and SP are
    kept, no memory or NR write, IFF set, one ei, HL' at it a ring address, and the last three
    bytes executed FB ED 4D. Returns (HL', Zilog T entry to RETI inclusive)."""
    cpu = mc.cpu
    set_main(cpu)
    cpu.alt.update(ALT_BCDE)
    set_alt_hl(cpu, hlp)
    cpu.iff = 0
    cpu.sp = STACK
    cpu.push(RET)
    before, nr0 = bytes(mc.mem), len(mc.nrlog)
    pcs, eis, t = [], [], 0
    cpu.pc = S(name) if at is None else at
    while cpu.pc != RET:
        if len(pcs) > 64:
            raise Fail(f"{name}: no RETI after 64 instructions")
        pcs.append(cpu.pc)
        if mc.mem[cpu.pc] == 0xFB:
            eis.append(alt_hl(cpu))
        t += tstep(mc)
    main_kept(cpu, name)
    if cpu.sp != STACK or {k: cpu.alt[k] for k in ALT_BCDE} != ALT_BCDE:
        raise Fail(f"{name}: SP ${cpu.sp:04X} or BC'/DE' changed")
    if bytes(mc.mem) != before or len(mc.nrlog) != nr0:
        raise Fail(f"{name}: wrote memory or a next register")
    if cpu.iff != 1:
        raise Fail(f"{name}: returned with interrupts disabled")
    p, q = pcs[-2], pcs[-1]
    if (mc.mem[p], bytes(mc.mem[q:q + 2]), q - p) != (0xFB, b"\xED\x4D", 1):
        raise Fail(f"{name}: last bytes executed {mc.mem[p]:02X} {bytes(mc.mem[q:q + 2]).hex()}"
                   f" at ${p:04X}/${q:04X}, expected FB ED 4D")
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    if len(eis) != 1 or not base <= eis[0] < base + n:
        raise Fail(f"{name}: ei executed {len(eis)} times, HL' at it "
                   f"{[f'${v:04X}' for v in eis]}")
    return alt_hl(cpu), t


# The handlers' earlier form (inc hl / bit 7,h / jr nz on every tick; relative jumps only, so
# it runs at STUB): the reference pointer and port sequence.
ISR_REF = {
    "video_ctc_isr_raw_st": bytes.fromhex("08D97ED3F32C7ED3F923CB7C2005D908FBED4D266018F7"),
    "video_ctc_isr_raw_mono": bytes.fromhex("08D97ED3B323CB7C2005D908FBED4D266018F7")}
ISR_STEP = {"video_ctc_isr_raw_st": 2, "video_ctc_isr_raw_mono": 1}


def isr_ring(mc, ring, name):
    """From every legal start (stereo: each even offset, mono: each offset) one tick of name
    and one of the reference, each under isr_tick's checks: the same port writes, ring[off]
    (and ring[off + 1]) to the handler's DAC ports, HL' = base + (off + step) mod the ring.
    Returns ({offset: T}, {offset: reference T})."""
    base, n, step = S("vidAudBuf"), S("NXV_AUD_RING"), ISR_STEP[name]
    ports = (DAC_L, DAC_R) if step == 2 else (DAC_M,)
    ref = ISR_REF[name]
    mc.mem[STUB:STUB + len(ref)] = ref
    ts, rts = {}, {}
    for off in range(0, n, step):
        mc.dac = []
        rhl, rts[off] = isr_tick(mc, f"reference from base+${off:X}", base + off, at=STUB)
        rdac, mc.dac = mc.dac, []
        hl, ts[off] = isr_tick(mc, name, base + off)
        want, nxt = [(p, ring[off + i]) for i, p in enumerate(ports)], base + (off + step) % n
        if (mc.dac, hl) != (want, nxt) or (rdac, rhl) != (want, nxt):
            raise Fail(f"{name} from base+${off:X}: ports {mc.dac}, HL' ${hl:04X}; reference "
                       f"{rdac}, ${rhl:04X}; expected {want}, ${nxt:04X}")
    mc.mem[STUB:STUB + len(ref)] = bytes(len(ref))
    return ts, rts


def test_isr_stereo():
    """Common tick, page step and ring end; then every even start against the reference, and
    a whole lap from the base: every pair in order, back to the base."""
    if (S("VID_DAC_LEFT"), S("VID_DAC_RIGHT")) != (DAC_L, DAC_R):
        raise Fail("VID_DAC_LEFT / VID_DAC_RIGHT are not $F3 / $F9")
    mc, ring = isr_machine()
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    for off, nxt in ((10, 12), (0xFE, 0x100), (0x1FE, 0x200), (n - 2, 0)):
        mc.dac = []
        hl, _ = isr_tick(mc, "video_ctc_isr_raw_st", base + off)
        want = [(DAC_L, ring[off]), (DAC_R, ring[off + 1])]
        if mc.dac != want or hl != base + nxt:
            raise Fail(f"HL' = base+${off:X}: ports {mc.dac}, HL' ${hl:04X}; expected {want}, "
                       f"${base + nxt:04X}")
    isr_ring(mc, ring, "video_ctc_isr_raw_st")
    mc.dac, hl = [], base
    for _ in range(n // 2):
        hl, _ = isr_tick(mc, "video_ctc_isr_raw_st", hl)
    want = [(DAC_R if i & 1 else DAC_L, ring[i]) for i in range(n)]
    if mc.dac != want or hl != base:
        bad = next((i for i, (x, y) in enumerate(zip(mc.dac, want)) if x != y), len(mc.dac))
        raise Fail(f"lap: first wrong write {bad} of {len(want)}, HL' ${hl:04X}")


def test_isr_mono():
    """As test_isr_stereo, one byte a tick: every start against the reference, then a lap."""
    if S("VID_DAC_MONO") != DAC_M:
        raise Fail("VID_DAC_MONO is not $B3")
    mc, ring = isr_machine()
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    for off, nxt in ((10, 11), (0xFF, 0x100), (0x1FF, 0x200), (n - 1, 0)):
        mc.dac = []
        hl, _ = isr_tick(mc, "video_ctc_isr_raw_mono", base + off)
        if mc.dac != [(DAC_M, ring[off])] or hl != base + nxt:
            raise Fail(f"HL' = base+${off:X}: ports {mc.dac}, HL' ${hl:04X}; expected "
                       f"[($B3, {ring[off]})], ${base + nxt:04X}")
    isr_ring(mc, ring, "video_ctc_isr_raw_mono")
    mc.dac, hl = [], base
    for _ in range(n):
        hl, _ = isr_tick(mc, "video_ctc_isr_raw_mono", hl)
    if mc.dac != [(DAC_M, v) for v in ring] or hl != base:
        raise Fail(f"lap: {len(mc.dac)} writes, HL' ${hl:04X}")


# T entry to RETI inclusive: a tick, a page step (HL' + step crosses a page), the ring end
# (HL' back to vidAudBuf). IM2_ACK_T: the IM2 acknowledge (Zilog); a raw session's CTC 0
# table entry is the handler itself, so no stub jp follows it.
ISR_T = {"video_ctc_isr_raw_st": (85, 114, 128), "video_ctc_isr_raw_mono": (63, 92, 106)}
IM2_ACK_T = 19
SRC_VIDEO = Path(__file__).resolve().parent.parent / "src" / "video.asm"


def handler_banner():
    """The comment block above video_ctc_isr_raw_st in src/video.asm, one line."""
    lines = SRC_VIDEO.read_text(encoding="utf-8").splitlines()
    i = next((k for k, ln in enumerate(lines) if ln.startswith("video_ctc_isr_raw_st:")), None)
    if i is None:
        raise Fail("src/video.asm has no video_ctc_isr_raw_st: line")
    out = []
    for ln in reversed(lines[:i]):
        s = ln.strip()
        if s.startswith("ASSERT"):
            continue
        if not s.startswith(";"):
            break
        out.append(s.lstrip("; "))
    return " ".join(reversed(out))


def test_isr_t():
    """Each handler's T from every legal start: the common tick, the page step and the ring
    end at their ISR_T figures, HL' as test_isr_stereo/_mono; the handler banner's totals
    (acknowledge + common tick, stereo / mono, and the page step) are these. Prints the
    per-interrupt averages over a ring lap with the acknowledge, and the reference's."""
    import re
    mc, ring = isr_machine()
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    st, mono = ISR_T["video_ctc_isr_raw_st"], ISR_T["video_ctc_isr_raw_mono"]
    want_doc = (st[0] + IM2_ACK_T, mono[0] + IM2_ACK_T, st[1] - st[0])
    if mono[1] - mono[0] != want_doc[2]:
        raise Fail(f"ISR_T: page steps {st[1] - st[0]} / {mono[1] - mono[0]} differ")
    banner = handler_banner()
    m = re.search(r"T with IM2 ack: (\d+) / (\d+), page step \+(\d+)", banner)
    got_doc = tuple(int(x) for x in m.groups()) if m else None
    if got_doc != want_doc:
        raise Fail(f"handler banner {banner!r}: totals {got_doc}, expected 'T with IM2 ack: "
                   f"{want_doc[0]} / {want_doc[1]}, page step +{want_doc[2]}'")
    notes = []
    for name, (common, page, wrap) in ISR_T.items():
        step = ISR_STEP[name]
        for off, want, nxt in ((10, common, 10 + step), (0x100 - step, page, 0x100),
                               (n - step, wrap, 0)):
            hl, t = isr_tick(mc, name, base + off)
            if (t, hl) != (want, base + nxt):
                raise Fail(f"{name} from base+${off:X}: {t} T, HL' ${hl:04X}; expected {want} T, "
                           f"${base + nxt:04X}")
        ts, rts = isr_ring(mc, ring, name)
        for off, t in ts.items():
            want = wrap if off + step == n else page if (off + step) & 0xFF == 0 else common
            if t != want:
                raise Fail(f"{name} from base+${off:X}: {t} T, expected {want}")
        avg, ravg = sum(ts.values()) / len(ts), sum(rts.values()) / len(rts)
        notes.append(f"{'stereo' if step == 2 else 'mono'} {common}/{page}/{wrap} T, lap average "
                     f"{avg + IM2_ACK_T:.2f} with ack (reference {ravg + IM2_ACK_T:.2f}, "
                     f"{ravg - avg:.2f} less)")
    print("  test_isr_t: " + "; ".join(notes))


def span(name):
    """(start, bytes) of routine name: to the next non-local label on VID_PAGE."""
    hot, start = S("VID_PAGE"), S(name)
    nxt = min(v for k, (p, v) in SYMS.items() if p == hot and "." not in k and v > start)
    rd = RawMachine(SYMS)
    return start, bytes(rd.mem[start:nxt])


def test_isr_static():
    from vidraw_oldpaths import decode, ends_flow
    for name, ports in (("video_ctc_isr_raw_st", {DAC_L, DAC_R}),
                        ("video_ctc_isr_raw_mono", {DAC_M})):
        start, buf = span(name)
        ins = decode(buf)
        offs = {x.off for x in ins}
        retis = 0
        for x in ins:
            b = buf[x.off:x.off + x.size]
            at = f"{name}+{x.off} ({b.hex(' ').upper()})"
            if b[0] in (0xC5, 0xD5, 0xE5, 0xF5) or b[:2] == b"\xED\x8A":
                raise Fail(f"{at}: push")
            if b[:2] in (b"\xED\x91", b"\xED\x92"):
                raise Fail(f"{at}: nextreg")
            if b[0] in (0xDD, 0xFD):
                raise Fail(f"{at}: IX/IY")
            if b[0] == 0xD3 and (b[1] == 0x6B or b[1] not in ports):
                raise Fail(f"{at}: out to ${b[1]:02X}")
            if b[0] == 0xED and (b[1] & 0xC7 == 0x41 or b[1] in (0x90, 0xA3, 0xAB, 0xB3, 0xBB)):
                raise Fail(f"{at}: port write by (C)")
            if b[0] in (0xC3, 0xCD, 0xC9, 0xE9) or (b[0] & 0xC0 == 0xC0 and b[0] & 7 in (0, 2, 4, 7)):
                raise Fail(f"{at}: leaves the handler other than by RETI")
            if x.kind == "rel" and x.off + 2 + (b[1] - 256 if b[1] > 127 else b[1]) not in offs:
                raise Fail(f"{at}: jumps out of the handler")
            retis += b == b"\xED\x4D"
        if not retis or not ends_flow(buf, ins[-1]):
            raise Fail(f"{name}: no RETI, or falls through its end")


def test_rd_bytes():
    """vid_raw_rd_hl, vid_raw_rdv (jp vid_raw_rd_hl as assembled) and vid_raw_prime bytes;
    each read returns HL' in HL with interrupts on and every other main register, IX and IY
    kept; vid_raw_prime sets HL' to the ring base and keeps the rest."""
    mc = RawMachine(SYMS)
    b = S("vidAudBuf")
    want = {"vid_raw_rd_hl": bytes.fromhex("F3D9E5D9FBE1C9"),
            "vid_raw_rdv": b"\xC3" + le(S("vid_raw_rd_hl")),
            "vid_raw_prime": bytes([0xD9, 0x21, b & 0xFF, b >> 8, 0xD9, 0xC9])}
    for name, w in want.items():
        got = bytes(mc.mem[S(name):S(name) + len(w)])
        if got != w:
            raise Fail(f"{name}: {got.hex(' ').upper()}, expected {w.hex(' ').upper()}")
    cpu = mc.cpu
    for name in ("vid_raw_rd_hl", "vid_raw_rdv"):
        set_main(cpu)
        cpu.alt.update(ALT_BCDE)
        set_alt_hl(cpu, 0x6789)
        cpu.iff = 1
        mc.run(name)
        main_kept(cpu, name, but=("h", "l"))
        if (cpu.hl, alt_hl(cpu), cpu.iff) != (0x6789, 0x6789, 1):
            raise Fail(f"{name}: read ${cpu.hl:04X}, HL' ${alt_hl(cpu):04X}, IFF {cpu.iff}")
    for iff in (0, 1):
        set_main(cpu)
        set_alt_hl(cpu, 0x1234)
        cpu.iff = iff
        mc.run("vid_raw_prime")
        main_kept(cpu, "vid_raw_prime")
        if (alt_hl(cpu), cpu.iff) != (b, iff):
            raise Fail(f"vid_raw_prime: HL' ${alt_hl(cpu):04X} IFF {cpu.iff}")


def ix_form():
    b = S("vidAudBuf")
    return bytes([0xDD, 0x21, b & 0xFF, b >> 8])


def test_patch_sites_default():
    mc = RawMachine(SYMS)                    # MMU7 = VID_PAGE as assembled: the non-raw set
    for name, a, w in vec_sites(0):
        got = bytes(mc.mem[a:a + len(w)])
        if got != w:
            raise Fail(f"{name}: {got.hex(' ').upper()}, expected {w.hex(' ').upper()}")


def patch_session(mc, direct, raw):
    """vid_stage_common.vec as an open runs it: vidDeliverDir and vidP_Raw seeded, VID_PAGE
    at MMU6 (the open's bracket). Only VID_PAGE and the stack may change."""
    hot = S("VID_PAGE")
    mc.map(7, S("VID_PAGE2"))
    mc.map(6, hot)
    mc.poke("vidDeliverDir", direct)
    mc.poke("vidP_Raw", raw)
    mc.sync()
    before = bytes(mc.phys)
    mc.run("vid_stage_common.vec")
    stray_writes(before, bytes(mc.phys),
                 {hot: True, 5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000})
    mc.map(6, 12)
    mc.map(7, hot)


def hot_page(mc):
    mc.sync()
    h = S("VID_PAGE")
    return bytes(mc.phys[h * SLOT:(h + 1) * SLOT])


def le(v):
    return bytes([v & 0xFF, v >> 8])


def vec_writes(direct, raw):
    """[(address, bytes)]: every byte the .vec tail sets for an open."""
    nxt, fetch, cj, pal, term = (("vid_ds_next", "vid_ds_byte", "vid_ds_copy_body", "vid_ds_pal",
                                  "vid_ds_done") if direct else
                                 ("vid_next", "vid_fetch_ram", "vid_copy_body", "vid_op_pal",
                                  "vid_dec_done"))
    out = [(S("vid_fetch.vec") + 1, le(S(fetch))), (S("vid_slow_op.cj") + 1, le(S(cj))),
           (S("vid_stub") + S("VOP_PAL") + 1, le(S(pal))), (S("vid_term_exit") + 1, le(S(term)))]
    out += [(S(k + ".next") + 1, le(S(nxt)))
            for k in ("vid_skip_body", "vid_run_body", "vid_op_kstart")]
    out += [(S("vid_decode_any.raw") + 1, le(S("vid_raw_frame" if raw else "vid_decode_frame_ds"))),
            (S("vr_sector_n"), le(S("VR_ENT_FAST")))]
    out += [(a, bs) for _, a, bs in vec_sites(raw)]
    return out + [(S("vidRaw"), bytes([raw])), (S("vidDirect"), bytes([direct]))]


def with_writes(page, writes):
    page = bytearray(page)
    for a, bs in writes:
        if not 0xE000 <= a <= 0x10000 - len(bs):
            raise Fail(f"vec_writes: ${a:04X} is not on the hot page")
        page[a - 0xE000:a - 0xE000 + len(bs)] = bs
    return bytes(page)


def describe(want, got):
    """The first differing hot page bytes, each named by the nearest label at or below."""
    hot = S("VID_PAGE")
    labels = sorted((v, k) for k, (p, v) in SYMS.items() if p == hot and 0xE000 <= v < 0x10000)
    addrs = [v for v, _ in labels]
    out = []
    for o in [o for o in range(SLOT) if want[o] != got[o]][:8]:
        a = 0xE000 + o
        i = bisect.bisect_right(addrs, a) - 1
        at = f"{labels[i][1]}+{a - labels[i][0]}" if i >= 0 else "?"
        out.append(f"${a:04X} ({at}) ${want[o]:02X} -> ${got[o]:02X}")
    return "; ".join(out)


def test_patch_roundtrip():
    # premise: the assembled defaults are the RAM, non-raw set the tail writes for (0, 0)
    mc = RawMachine(SYMS)
    snap = hot_page(mc)
    patch_session(mc, 0, 0)
    if hot_page(mc) != snap:
        raise Fail("PREMISE FAILED (stop and report): patch_session(0, 0) on the fresh image "
                   "changed the hot page: " + describe(snap, hot_page(mc)))
    if with_writes(snap, vec_writes(0, 0)) != snap:
        raise Fail("test model: vec_writes(0, 0) differs from the assembled image: "
                   + describe(snap, with_writes(snap, vec_writes(0, 0))))
    mc = RawMachine(SYMS)
    snap = hot_page(mc)
    for direct, raw in ((1, 1), (1, 0), (0, 0)):
        set_entry(mc, "VR_ENT_CROSS")            # a previous session ended on a crossing frame
        patch_session(mc, direct, raw)
        got, want = hot_page(mc), with_writes(snap, vec_writes(direct, raw))
        if got != want:
            raise Fail(f"patch_session({direct}, {raw}): " + describe(want, got))
    if hot_page(mc) != snap:
        raise Fail("after (1, 1), (1, 0), (0, 0) the hot page is not the assembled image")
    if entry_of(RawMachine(SYMS)) != "VR_ENT_FAST":
        raise Fail("vr_sector_n's assembled entry is not VR_ENT_FAST")


def run_to(mc, start, stop, budget=10_000):
    cpu = mc.cpu
    cpu.sp = STACK
    cpu.pc = start
    while cpu.pc != stop:
        budget -= 1
        if budget <= 0:
            raise Fail(f"${start:04X} never reached ${stop:04X}")
        cpu.step()
    mc.sync()
    return cpu


def test_patched_reads():
    """After a raw open the pace poll and the two arm sites run on HL' (the model has no IX:
    an unpatched site would fail on its DD prefix), and vid_aud_pump's first instruction is
    a jump to vid_raw_pump (trapped there: nothing else runs; test_pump_* run it whole)."""
    mc = RawMachine(SYMS)
    patch_session(mc, 1, 1)
    base = S("vidAudBuf")
    cpu = mc.cpu
    if "vidRlSpinDiv" in SYMS:
        mc.poke("vidRlSpinDiv", 100)
    mc.poke16("vidAudRdPrev", base + 100)
    mc.poke16("vidPaceRem", 500)
    set_alt_hl(cpu, base + 300)
    cpu.iff = 1
    mc.run("vid_pace_poll", bc=0x1357)
    got = (mc.peek("vidPaceRem", 2), mc.peek("vidAudRdPrev", 2), cpu.fc, cpu.bc, cpu.iff)
    if got != (300, base + 300, 0, 0x1357, 1):
        raise Fail(f"vid_pace_poll: (rem, rdPrev, CF, BC, IFF) = {got}")
    seen = []
    steps = cpu.steps
    mc.run("vid_aud_pump", traps={S("vid_raw_pump"): ret_trap(lambda c: seen.append(c.bc)),
                                  **aborts()}, bc=0xFFFF)
    if (seen, cpu.steps - steps, cpu.iff) != ([0xFFFF], 1, 1):
        raise Fail(f"vid_aud_pump: vid_raw_pump entries (BC) {seen}, "
                   f"{cpu.steps - steps} instructions before it, IFF {cpu.iff}")
    for site in ("vid_run.ixp1", "vid_run.ixp2"):
        set_main(cpu)
        set_alt_hl(cpu, 0x1234)
        cpu.iff = 1
        run_to(mc, S(site), S(site) + 4)
        main_kept(cpu, site)
        if (alt_hl(cpu), cpu.sp, cpu.iff) != (base, STACK, 1):
            raise Fail(f"{site}: HL' ${alt_hl(cpu):04X} SP ${cpu.sp:04X} IFF {cpu.iff}")


def test_isr_choice():
    stub = S("IM2_CTC_STUB") + 1
    for raw, ach, want in ((0, 2, "video_ctc_isr_stereo"), (0, 1, "video_ctc_isr_stereo"),
                           (1, 2, "video_ctc_isr_raw_st"), (1, 1, "video_ctc_isr_raw_mono")):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.poke("vidP_Raw", raw)
        mc.poke("vidP_AChan", ach)
        mc.mem[stub:stub + 2] = b"\x00\x00"
        at = S("vid_run_l2setup_body.isrset")
        if bytes(mc.mem[at:at + 3]) != b"\x22" + le(stub):
            raise Fail(".isrset is not ld (IM2_CTC_STUB+1), hl")
        run_to(mc, S("vid_run_l2setup_body.isrsel"), at + 3)
        got = mc.mem[stub] | mc.mem[stub + 1] << 8
        if got != S(want):
            raise Fail(f"raw {raw} channels {ach}: vector ${got:04X}, expected {want}")


def im2_default():
    """The IM2 table as im2_init leaves it: the IM2_VECTOR_BYTE fill, CTC 0's entry the stub
    (only its low byte written: the high byte is the fill), CTC 1's entry ctc2_isr."""
    t = bytearray([S("IM2_VECTOR_BYTE")]) * 257
    v, v2, stub = S("IM2_CTC_VEC"), S("IM2_CTC2_VEC"), S("IM2_CTC_STUB")
    if stub >> 8 != S("IM2_VECTOR_BYTE"):
        raise Fail("IM2_CTC_STUB's high byte is not the table fill")
    t[v] = stub & 0xFF
    t[v2:v2 + 2] = le(S("ctc2_isr"))
    return bytes(t)


def set_table(mc, entry=None):
    """im2_default at IM2_TABLE, CTC 0's entry = entry if given."""
    t = bytearray(im2_default())
    if entry is not None:
        t[S("IM2_CTC_VEC"):S("IM2_CTC_VEC") + 2] = le(entry)
    mc.mem[S("IM2_TABLE"):S("IM2_TABLE") + 257] = t


def vec_entry(mc):
    a = S("IM2_TABLE") + S("IM2_CTC_VEC")
    return mc.mem[a] | mc.mem[a + 1] << 8


def table_rest(mc):
    """The IM2 table less CTC 0's entry (bytes IM2_CTC_VEC, +1)."""
    a, v = S("IM2_TABLE"), S("IM2_CTC_VEC")
    t = bytes(mc.mem[a:a + 257])
    return t[:v] + t[v + 2:]


def stub_target(mc):
    a = S("IM2_CTC_STUB") + 1
    return mc.mem[a] | mc.mem[a + 1] << 8


def test_vec_install():
    """vid_run_l2setup_body from .isrsel to its end (MMU6 = VID_PAGE, the body's bracket):
    CTC 0's IM2 table entry is video_ctc_isr_raw_st / video_ctc_isr_raw_mono for a raw stereo
    / mono header and stays IM2_CTC_STUB for a non-raw one; the stub's target is the handler
    as before; no other table byte changes."""
    for raw, ach, entry, target in ((1, 2, "video_ctc_isr_raw_st", "video_ctc_isr_raw_st"),
                                    (1, 1, "video_ctc_isr_raw_mono", "video_ctc_isr_raw_mono"),
                                    (0, 2, "IM2_CTC_STUB", "video_ctc_isr_stereo"),
                                    (0, 1, "IM2_CTC_STUB", "video_ctc_isr_stereo")):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.map(6, S("VID_PAGE"))
        mc.poke("vidP_Raw", raw)
        mc.poke("vidP_AChan", ach)
        set_table(mc)
        stub = S("IM2_CTC_STUB") + 1
        mc.mem[stub:stub + 2] = b"\x00\x00"
        rest = table_rest(mc)
        mc.run(S("vid_run_l2setup_body.isrsel"),
               traps={S("data_restore"): lambda c: setattr(c, "pc", RET)})
        got = (vec_entry(mc), stub_target(mc))
        if got != (S(entry), S(target)) or table_rest(mc) != rest:
            raise Fail(f"raw {raw} channels {ach}: entry ${got[0]:04X}, stub target ${got[1]:04X}"
                       f", rest of the table kept {table_rest(mc) == rest}; expected {entry}, "
                       f"{target}")


def nex_store_sites(addrs):
    """[(routine, page, address)]: every ld (nn),a / ld (nn),hl / ld (nn),rr store and ld
    rr,nn / ld ix,nn / ld iy,nn load naming an address in addrs, over every page in the .nex;
    routine = the nearest non-local SLD label at or below on that page."""
    import dma_contract
    d = dma_contract.NEX.read_bytes()
    present = [b for b in dma_contract.NEX_BANK_ORDER if d[18 + b]]
    pats = []
    for a in addrs:
        w = le(a)
        pats += [bytes([op]) + w for op in (0x22, 0x32, 0x01, 0x11, 0x21)]
        pats += [b"\xED" + bytes([op]) + w for op in (0x43, 0x53, 0x63, 0x73)]
        pats += [bytes([p, 0x21]) + w for p in (0xDD, 0xFD)]
    out = []
    for i, bank in enumerate(present):
        for half in (0, 1):
            page = bank * 2 + half
            buf = d[512 + 16384 * i + 8192 * half:512 + 16384 * i + 8192 * (half + 1)]
            labels = sorted((v, k) for k, (p, v) in SYMS.items() if p == page and "." not in k)
            org = labels[0][0] & 0xE000 if labels else 0
            for pat in pats:
                o = buf.find(pat)
                while o >= 0:
                    a = org + o
                    j = bisect.bisect_right([v for v, _ in labels], a) - 1
                    out.append((labels[j][1] if j >= 0 else "?", page, a))
                    o = buf.find(pat, o + 1)
    return sorted(out)


def test_vec_restore():
    """vid_run_restore_body opens with ld hl, IM2_CTC_STUB / ld (IM2_TABLE + IM2_CTC_VEC), hl;
    run to its hop back after a raw stereo, a raw mono and a non-raw session: CTC 0's entry is
    IM2_CTC_STUB, the stub's target the saved vector, the whole table as im2_init left it
    (CTC 1's entry included). The image names CTC 0's entry only at im2_init, l2setup, the
    restore body and (DEBUG) nxb_kind_rarm / nxb_kind_armold / nxb_kind_disarm."""
    stub, at = S("IM2_CTC_STUB"), S("IM2_TABLE") + S("IM2_CTC_VEC")
    for installed, target in (("video_ctc_isr_raw_st", "video_ctc_isr_raw_st"),
                              ("video_ctc_isr_raw_mono", "video_ctc_isr_raw_mono"),
                              ("IM2_CTC_STUB", "video_ctc_isr_stereo")):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        code_is(mc, "vid_run_restore_body", b"\x21" + le(stub) + b"\x22" + le(at))
        set_table(mc, S(installed))
        mc.mem[stub + 1:stub + 3] = le(S(target))
        mc.poke16("vidSvCtcStub", S("ctc_isr"))
        mc.poke("vidSvMmu2", mc.mmu[2])
        mc.poke("vidSvMmu3", mc.mmu[3])
        hops = []

        def hop(c):
            hops.append(c.hl)
            c.pc = RET
        noop = ret_trap(lambda c: None)
        traps = {S(n): noop for n in ("vid_snap_restore_body", "vid_ring_free",
                                      "vid_aud_bank_free", "vid_snap_free", "vid_stream_close")}
        traps[S("vid_hop1")] = hop
        mc.run("vid_run_restore_body", traps=traps)
        table = bytes(mc.mem[S("IM2_TABLE"):S("IM2_TABLE") + 257])
        if (hops, vec_entry(mc), stub_target(mc)) != ([S("vid_run.restore_tail")], stub,
                                                        S("ctc_isr")) or table != im2_default():
            raise Fail(f"after {installed}: hop {hops}, entry ${vec_entry(mc):04X}, stub target "
                       f"${stub_target(mc):04X}, table as im2_init's {table == im2_default()}")
    sites = nex_store_sites((at - 1, at, at + 1))
    want = sorted(["im2_init", "vid_run_l2setup_body", "vid_run_restore_body"]
                  + (["nxb_kind_armold", "nxb_kind_disarm", "nxb_kind_rarm"]
                     if "dbgNoBank" in SYMS else []))
    if [r for r, _, _ in sites] != want:
        raise Fail(f"code naming IM2_TABLE + IM2_CTC_VEC (+-1): {sites}, expected one site in "
                   f"each of {want}")


ALT_ALL = {"b": 0x11, "c": 0x22, "d": 0x33, "e": 0x44, "h": 0x55, "l": 0x66}


def dbg_cells(mc, arm=0, cnt=0, mx=0, urun=0, rem=0):
    mc.poke("vidLateArm", arm)
    mc.poke16("vidLateCnt", cnt)
    mc.poke16("vidLateMax", mx)
    mc.poke16("vidUrunCnt", urun)
    mc.poke16("vidPaceRem", rem & 0xFFFF)


def dbg_state(mc):
    """(vidLateArm, vidLateCnt, vidLateMax, vidUrunCnt)."""
    return (mc.peek("vidLateArm"), mc.peek("vidLateCnt", 2), mc.peek("vidLateMax", 2),
            mc.peek("vidUrunCnt", 2))


def dbg_enter(cpu, fc=0, hlp=0x5566, ix=0xDEAD):
    set_main(cpu)
    cpu.fc, cpu.ix, cpu.iff = fc, ix, 1
    cpu.alt.update(ALT_ALL)
    set_alt_hl(cpu, hlp)


def dbg_kept(cpu, what, fc, hlp=0x5566, ix=0xDEAD):
    """BC, IX, IY, the alternate set, SP, IFF and CF as dbg_enter left them."""
    alt = dict(ALT_ALL, h=hlp >> 8, l=hlp & 0xFF)
    got = (cpu.bc, cpu.ix, cpu.iy, {k: cpu.alt[k] for k in alt}, cpu.sp, cpu.iff, cpu.fc)
    want = (0x1234, ix, 0xBEEF, alt, STACK, 1, fc)
    if got != want:
        raise Fail(f"{what}: (BC, IX, IY, alt, SP, IFF, CF) = {got}, expected {want}")


def test_dbg_counters():
    """vid_dbg_late after vid_run.pace's poll (CF in): counts only an armed first poll with
    CF set and vidPaceRem negative, MAXL = max(MAXL, -rem), CF out = CF in. vid_dbg_urun at
    .qnext: a further vid_pace_poll (raw form patched to vid_raw_rdv; the IX form's 3-byte
    push ix/pop hl stood in by a trap - the model has no IX) counts rem <= 0 and arms LATE."""
    if "vid_dbg_late" not in SYMS:
        raise Skip("vid_dbg_late is not assembled (Release or -BenchQuiet image)")
    lo, z = S("vidTlFrames"), S("VID_TL_ZERO_LEN")
    if not (lo <= S("vidLateArm") and S("vidUrunCnt") + 2 <= lo + z):
        raise Fail("vidLateArm..vidUrunCnt is not inside the session zero span")
    mc = RawMachine(SYMS)
    cpu = mc.cpu
    # (CF in, arm, rem, cnt, max) -> (arm, cnt, max); CF out must equal CF in
    late = [((1, 1, -0x123, 0, 0), (0, 1, 0x123)),
            ((1, 1, -0x100, 5, 0x200), (0, 6, 0x200)),          # max keeps the larger
            ((1, 1, -0x200, 5, 0x200), (0, 6, 0x200)),          # equal
            ((1, 1, -0x7FFF, 1, 0x200), (0, 2, 0x7FFF)),
            ((1, 1, -1, 0, 0), (0, 1, 1)),
            ((1, 1, 0, 3, 7), (0, 3, 7)),                       # rem 0: on time
            ((0, 1, 0x40, 3, 7), (0, 3, 7)),                    # waited: on time
            ((0, 1, -0x8000, 3, 7), (0, 3, 7)),                 # the poll's CF is clear here
            ((1, 0, -0x50, 3, 7), (0, 3, 7))]                   # unarmed: frame 0, a spin poll
    for (fc, arm, rem, cnt, mx), want in late:
        dbg_cells(mc, arm=arm, cnt=cnt, mx=mx, rem=rem)
        dbg_enter(cpu, fc)
        mc.run("vid_dbg_late")
        what = f"vid_dbg_late CF {fc} arm {arm} rem {rem} cnt {cnt} max ${mx:04X}"
        dbg_kept(cpu, what, fc)
        if dbg_state(mc)[:3] != want or mc.peek("vidPaceRem", 2) != rem & 0xFFFF:
            raise Fail(f"{what}: (arm, cnt, max) = {dbg_state(mc)[:3]}, expected {want}")
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    rd = S("vid_pace_poll.rd")
    if bytes(mc.mem[rd:rd + 3]) != b"\xDD\xE5\xE1":
        raise Fail("vid_pace_poll.rd is not push ix / pop hl in the image")

    def ixsnap(c):
        c.hl = c.ix
        c.pc = rd + 3
    # (rem before, rd before, rd now, vidRlSpinDiv): rem after = rem - (now - before) mod ring
    urun = [(300, 100, 300, 100), (300, 100, 400, 100), (300, 100, 399, 100),
            (300, 100, 600, 1), (100, n - 50, 100, 100), (0x8064, 0, 100, 100),
            (0x8000, 0, 1, 100)]
    for form in ("ix", "raw"):
        if form == "raw":
            patch_session(mc, 1, 1)
        for rem0, p0, p1, div in urun:
            dbg_cells(mc, arm=0, cnt=9, mx=9, urun=4, rem=rem0)
            mc.poke16("vidAudRdPrev", base + p0)
            mc.poke("vidRlSpinDiv", div)
            if form == "raw":
                dbg_enter(cpu, hlp=base + p1)
                mc.run("vid_dbg_urun")
                dbg_kept(cpu, f"vid_dbg_urun {form}", cpu.fc, hlp=base + p1)
            else:
                dbg_enter(cpu, ix=base + p1)
                mc.run("vid_dbg_urun", traps={rd: ixsnap})
                dbg_kept(cpu, f"vid_dbg_urun {form}", cpu.fc, ix=base + p1)
            rem = (rem0 - (p1 - p0) % n) & 0xFFFF
            under = rem == 0 or rem >= 0x8000
            want = (rem, base + p1, (1, 9, 9, 4 + under))
            got = (mc.peek("vidPaceRem", 2), mc.peek("vidAudRdPrev", 2), dbg_state(mc))
            if got != want:
                raise Fail(f"vid_dbg_urun {form} rem ${rem0:04X} rd {p0}->{p1}: (rem, rdPrev, "
                           f"(arm, cnt, max, urun)) = {got}, expected {want}")
    # a session: frame 0 (unarmed), .qnext arms, frame 1's first poll late, a spin poll after
    # an on-time first poll does not count
    dbg_cells(mc)
    for step, (fc, rem, want) in enumerate([(1, -3, (0, 0, 0, 0)), ("q", 1000, (1, 0, 0, 0)),
                                            (1, -0x40, (0, 1, 0x40, 0)), ("q", 1000, (1, 1, 0x40, 0)),
                                            (0, 0x10, (0, 1, 0x40, 0)), (1, -5, (0, 1, 0x40, 0))]):
        mc.poke16("vidPaceRem", rem & 0xFFFF)
        if fc == "q":
            mc.poke16("vidAudRdPrev", base)
            dbg_enter(cpu, hlp=base + 100)
            mc.run("vid_dbg_urun")
        else:
            dbg_enter(cpu, fc)
            mc.run("vid_dbg_late")
        if dbg_state(mc) != want:
            raise Fail(f"session step {step}: (arm, cnt, max, urun) = {dbg_state(mc)}, "
                       f"expected {want}")


# --------------------------------------------------------------------------- RW1 bench session

def bench_only():
    """Release has no NXB bench: skip. A DEBUG image without nxb_rw_feed fails."""
    if "dbgNoBank" not in SYMS:
        raise Skip("Release image: nxb_rw_feed and the NXB bench are DEBUG-only")
    S("nxb_rw_feed")


def mapnr(mc, slot, page):
    mc.map(slot, page)
    mc.nr[0x50 + slot] = page


def nxb_machine(cls=None, syms=None, pages=None):
    """A machine with the NXB page in physical RAM and NR $50-$57 readable (NRGET); syms and
    pages: another image's (default this build's)."""
    cls = cls or RawMachine
    mc = cls(syms or SYMS, pages) if pages else cls(syms or SYMS)
    nxb = mc.sym("NXB_PAGE")
    mc.phys[nxb * SLOT:(nxb + 1) * SLOT] = (pages or read_page)(nxb)
    for s in range(8):
        mc.nr[0x50 + s] = mc.mmu[s]
    return mc


def find_code(mc, start, end, pat):
    """The address of byte pattern pat in [start, end), both in the slot that maps them."""
    o = bytes(mc.mem[start:end]).find(pat)
    if o < 0:
        raise Fail(f"{pat.hex(' ').upper()} not found in ${start:04X}-${end:04X}")
    return start + o


def code_is(mc, name, want):
    got = bytes(mc.mem[S(name):S(name) + len(want)])
    if got != want:
        raise Fail(f"{name}: {got.hex(' ').upper()}, expected {want.hex(' ').upper()}")


def rw_cells(mc, run=0xFFFF, crc=0):
    mc.poke("vidDsCrcDue", crc)
    mc.poke("vidDsFrmBlk", 0)
    mc.poke("vidDsBound", 255)
    mc.poke("vidStrmRemainBlk", (0x012345).to_bytes(3, "little"))
    mc.poke16("vidStrmRunBlkH", run)
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 100)


def rw_sched(mc):
    """The slide built in the schedule page (vid_raw_sched_build), MMU6 = it, MMU7 = VID_PAGE."""
    if build_sched(mc, 1, 320, 192).fc:
        raise Fail("vid_raw_sched_build set CF")
    mapnr(mc, 7, S("VID_PAGE"))
    mc.nr[0x56] = SCHED_PAGE


def test_dbg_calls():
    """vid_run's two DEBUG helper calls (DEBUG image, not -BenchQuiet): at .pace, call
    vid_pace_poll / call vid_dbg_late / jr c; just before .qskip, call vid_dbg_urun."""
    if "vid_dbg_late" not in SYMS:
        raise Skip("vid_dbg_late is not assembled (Release or -BenchQuiet image)")
    mc = RawMachine(SYMS)
    code_is(mc, "vid_run.pace", b"\xCD" + le(S("vid_pace_poll")) + b"\xCD" + le(S("vid_dbg_late"))
            + b"\x38")
    q = S("vid_run.qskip")
    if bytes(mc.mem[q - 3:q]) != b"\xCD" + le(S("vid_dbg_urun")):
        raise Fail(f"before vid_run.qskip: {bytes(mc.mem[q - 3:q]).hex(' ').upper()}, "
                   f"expected call vid_dbg_urun")


def test_rw_shapes():
    """The timed bodies as emitted: what lies inside each RW1 row's window."""
    bench_only()
    mc = RawMachine(SYMS)
    slide, end, scr = S("VR_SLIDE"), S("VR_SLIDE_END"), S("VR_SCRATCH")
    code_is(mc, "nxb_rw_fbody", b"\xCD" + le(S("nxb_rw_feed")) + b"\xC3" + le(S("vid_decode_any")))
    code_is(mc, "nxb_rw_sec", b"\x21" + le(scr) + b"\xCD" + le(S("vr_sector_n")) + b"\xC3" + le(slide))
    code_is(mc, "nxb_rw_col", b"\x21" + le(S("VID_DST_WIN")) + b"\xCD" + le(S("vr_sector_n"))
            + (b"\xCD" + le(end - 128) + b"\x2E\x00\x24") * 8 + b"\xC3" + le(end))
    code_is(mc, "nxb_rh_body", b"\x21" + le(scr) + b"\xCD" + le(S("nxb_rh_sec")) + b"\xCD"
            + le(S("nxb_rh_bin")) + b"\xC3" + le(slide))
    n = S("NXB_RW_SPIN")
    code_is(mc, "nxb_rw_spin", b"\x01" + le(n) + b"\x0B\x78\xB1\x20\xFB\xC9")
    # vid_sd_tok_h's loop (the slow tail): in 11, inc a 4, jr nz 7, dec bc 6, ld a,b 4, or c 4,
    # jr nz 12 = 48 T between data-port reads
    w = S("vid_sd_tok_h.wt")
    b = bytes(mc.mem[w:w + 10])
    if b[:4] != b"\xDB\xEB\x3C\x20" or b[5:8] != b"\x0B\x78\xB1" or b[8:] != b"\x20\xF6" \
            or b[4] > 0x7F:
        raise Fail(f"vid_sd_tok_h.wt: {b.hex(' ').upper()} is not the 48 T poll loop")
    # the mirror: ld b,0, then vr_sector_n's fast sequence from CRC 1, the pad (VR_POLL_PAD_N
    # x cp (hl), after the DEBUG divider in production) and the polls through djnz .p, its two
    # forward jr offsets aside (the targets lie at other distances)
    n = S("VR_POLL_PAD_N")
    p, m = S("vr_sector_n"), S("nxb_rh_sec")
    pp, mp = S("vr_sector_n.poll"), S("nxb_rh_sec.poll")
    prod = bytes(mc.mem[p:p + 5]) + bytes(mc.mem[pp - n:pp + 15])
    mirr = bytes(mc.mem[m + 2:m + 7]) + bytes(mc.mem[mp - n:mp + 15])
    k = 5 + n
    mask = lambda s: bytes(0 if i in (k + 4, k + 12) else v for i, v in enumerate(s))  # noqa: E731
    if mc.mem[m:m + 2] != b"\x06\x00" or mp != m + 7 + n or mask(prod) != mask(mirr) \
            or prod[-2:] != b"\x10\xF6" or prod[5:k] != b"\xBE" * n:
        raise Fail(f"nxb_rh_sec {bytes(mc.mem[m:mp + 15]).hex(' ').upper()} is not ld b,0 + "
                   f"vr_sector_n's {prod.hex(' ').upper()}")
    # the 39 T head: ld b,0, the CRC pair, inc hl / dec hl / nop (16 T), jr nxb_rh_sec.poll
    h = S("nxb_rh_sec39")
    code_is(mc, "nxb_rh_sec39", b"\x06\x00\xDB\xEB\x00\xDB\xEB\x23\x2B\x00\x18"
            + bytes([(mp - (h + 12)) & 0xFF]))
    if not -128 <= mp - (h + 12) <= 127:
        raise Fail("nxb_rh_sec39's jr does not reach nxb_rh_sec.poll")
    if SYMS["nxbHistBin"][0] != S("VID_PAGE") or SYMS["nxbHistN"][0] != S("VID_PAGE"):
        raise Fail("nxbHistBin / nxbHistN are not on VID_PAGE (written with MMU6 = schedule)")


def test_rw_feed():
    """nxb_rw_feed after a raw open's patches, NXB_PAGE at MMU6 as the frame kinds enter
    nxb_lrow: the pointer from HL' through vid_raw_rdv (IX is garbage and never read), the
    writer half a ring ahead, one frame's sound off the wire by the pump (sound, pad and tag
    by the slide, the opens by vr_sector_c), the tag stored, MMU6 left at the schedule page
    and NXB_PAGE unchanged."""
    bench_only()
    mc = nxb_machine()
    patch_session(mc, 1, 1)
    if build_sched(mc, 1, 320, 192).fc:
        raise Fail("vid_raw_sched_build set CF")
    nxb = S("NXB_PAGE")
    mapnr(mc, 7, S("VID_PAGE"))
    mapnr(mc, 6, nxb)
    mc.poke("vidRawSchedPage", SCHED_PAGE)
    nxb_before = bytes(mc.phys[nxb * SLOT:(nxb + 1) * SLOT])
    cpu = mc.cpu
    base, ring = S("vidAudBuf"), S("NXV_AUD_RING")
    snd = bytes((i * 11 + 5) & 0xFF for i in range(1250))
    card = Card(blocks(snd + bytes([0x80]) * (3 * 512 - 1250 - 1) + b"\x01"), waits=2)
    mc.set_card(card)
    rw_cells(mc)
    mc.poke16("vidABytes", 1250)
    mc.poke("vidRawTag", 0x77)
    mc.mem[base:base + ring] = bytes([0xEE]) * ring
    set_alt_hl(cpu, base + 100)
    cpu.ix, cpu.iff = 0x1234, 1
    mc.run("nxb_rw_feed", traps=aborts())
    wr0 = (base + 100) ^ (ring // 2)
    o = wr0 - base
    want = bytes([0xEE]) * o + snd + bytes([0xEE]) * (ring - o - 1250)
    if bytes(mc.mem[base:base + ring]) != want:
        bad = next(i for i in range(ring) if mc.mem[base + i] != want[i])
        raise Fail(f"ring differs first at +${bad:04X} (sound expected at +${o:04X})")
    got = (mc.peek("vidAudFeedRem", 2), mc.peek("vidRawTag"), card.pos, cpu.ix, alt_hl(cpu),
           cpu.iff, mc.peek("vidAudWr", 2))
    if got != (0, 1, len(card.stream), 0x1234, base + 100, 1, wr0 + 1250):
        raise Fail(f"(feedRem, tag, reads, IX, HL', IFF, wr) = {got}")
    owner = owner_fn(mc)
    allowed = {"crc": {"vr_sector_c"}, "wait": {"vr_sector_n"}, "token": {"vr_sector_n"},
               "data": {"slide"}}
    for i, (ph, pc) in enumerate(card.log):
        if owner(pc) not in allowed[ph]:
            raise Fail(f"card read {i} ({ph}) by {owner(pc)}")
    mc.sync()
    got = (mc.mmu[6], mc.nr.get(0x56), bytes(mc.phys[nxb * SLOT:(nxb + 1) * SLOT]) == nxb_before)
    if got != (SCHED_PAGE, SCHED_PAGE, True):
        raise Fail(f"(MMU6, NR $56, NXB_PAGE unchanged) = {got}")


def route(req, direct, raw, streaming=0, hlp=0x1234):
    """nxb_sess's entry state for one request; returns (machine, traps)."""
    mc = nxb_machine()
    cpu = mc.cpu
    for name, v in (("nxbSessReq", req), ("vidDirect", direct), ("vidRaw", raw),
                    ("vidStreaming", streaming), ("vidDsBound", 9), ("nxbHistN", 2)):
        mc.poke(name, v)
    tab = S("nxbTabBuf")
    mc.mem[tab:tab + 4] = b"OLD!"
    stub = S("IM2_CTC_STUB") + 1
    mc.mem[stub:stub + 2] = le(S("video_ctc_isr_raw_st"))
    pr = S("nxb_lrow.pr")
    mc.mem[pr:pr + 2] = le(S("nxb_rh_done"))
    set_alt_hl(cpu, hlp)
    noop = ret_trap(lambda c: None)
    traps = {S(n): noop for n in ("nxb_tm_in", "nxb_blank", "nxb_tm_out", "dbg_at", "dbg_puts")}
    nxb, base = S("NXB_PAGE"), S("vidAudBuf")
    mapnr(mc, 6, nxb)
    at = find_code(mc, S("nxb_sess_setup"), S("nxb_deliv"), b"\xDD\x21" + le(base))
    mapnr(mc, 6, 12)

    def ldix(c):                         # the model has no IX: ld ix, vidAudBuf by hand
        c.ix = base
        c.pc += 4
    traps[at] = ldix

    def walk(c):
        raise Stop("nxb_sess_walk", c.a)
    traps[S("nxb_sess_walk")] = walk
    return mc, traps


def test_rw_route():
    """Mode 5 through the hook's route: nxb_sess returns NC (nxb_sess_setup's vidDirect exit,
    table staged, walk not entered); nxb_ds_rows then lifts the bound, primes HL' and walks.
    Mode 1 keeps HL'; mode 5 on a non-raw clip and mode 1 on a raw clip print NXB SESSION."""
    bench_only()
    import nxv2_bench_rows as bench
    mc = RawMachine(SYMS)
    a = find_code(mc, S("vid_run"), S("vid_run.restore"), b"\xCD" + le(S("nxb_sess")))
    want = (b"\xCD" + le(S("nxb_sess")) + b"\x38\x03\xCD" + le(S("nxb_ds_rows")) + b"\xC3"
            + le(S("vid_run.restore")))
    if bytes(mc.mem[a:a + len(want)]) != want:
        raise Fail(f"vid_run's hook: {bytes(mc.mem[a:a + len(want)]).hex(' ').upper()}")
    base = S("vidAudBuf")
    for req, raw, name, hl_after in ((5, 1, "RW1", base), (1, 0, "DS1", 0x1234)):
        mc, traps = route(req, 1, raw)
        try:
            cpu = mc.run("nxb_sess", traps=traps)
        except Stop as e:
            raise Fail(f"mode {req}: {e} - nxb_sess walked the table itself")
        if cpu.fc or mc.mmu[6] != 12:
            raise Fail(f"mode {req}: CF {cpu.fc}, MMU6 {mc.mmu[6]} after nxb_sess")
        mapnr(mc, 6, S("NXB_PAGE"))
        cells = (mc.peek("nxbSessVec", 2), mc.peek("nxb_lrow.pr", 2), mc.peek("nxbHistN"))
        mapnr(mc, 6, 12)
        if cells != (S("video_ctc_isr_raw_st"), S("nxb_sprint"), 0):
            raise Fail(f"mode {req}: (nxbSessVec, nxb_lrow.pr, nxbHistN) = {cells}")
        if alt_hl(cpu) != 0x1234:
            raise Fail(f"mode {req}: nxb_sess changed HL' to ${alt_hl(cpu):04X}")
        try:
            mc.run("nxb_ds_rows", traps=traps)
        except Stop as e:
            if e.where != "nxb_sess_walk":
                raise
        else:
            raise Fail(f"mode {req}: nxb_ds_rows returned without walking")
        staged = bench.session_table_bytes(name)
        tab = S("nxbTabBuf")
        got = (alt_hl(cpu), mc.peek("vidDsBound"), bytes(mc.mem[tab:tab + len(staged)]))
        if got != (hl_after, 255, staged):
            raise Fail(f"mode {req}: (HL', vidDsBound) = (${got[0]:04X}, {got[1]}), staged "
                       f"{got[2][:12]!r}..., expected {staged[:12]!r}...")
    for req, direct, raw, strm in ((5, 1, 0, 0), (1, 1, 1, 0), (5, 0, 0, 1)):
        mc, traps = route(req, direct, raw, strm)
        cpu = mc.run("nxb_sess", traps=traps)
        tab = S("nxbTabBuf")
        if (cpu.fc, cpu.fz, bytes(mc.mem[tab:tab + 4]), alt_hl(cpu)) != (1, 1, b"OLD!", 0x1234):
            raise Fail(f"mode {req} direct {direct} raw {raw}: CF {cpu.fc} Z {cpu.fz}, table "
                       f"{bytes(mc.mem[tab:tab + 4])!r}, HL' ${alt_hl(cpu):04X}")


def test_rw_card():
    """nxb_rw_go's untimed sector, then one rep of RSEC and of RCOL under VR_ENT_FAST (the run
    charged by nxb_rw_charge, so no open counts it): 2 CRC + waits + token + 512 data reads
    each; RSEC into VR_SCRATCH, RCOL as 8 columns of 64 on the surface page. A whole RSEC row
    from nxb_kind_rblk (a crossing frame's VR_ENT_CROSS left): the run and remain down by reps
    + 1 before the first rep, VR_ENT_FAST written, every sector read, the walk mark O = 00. A
    row whose run is shorter than reps + 1: NXB RUN (not the remain's NXB SHORT), no read,
    nothing charged."""
    bench_only()
    mc = RawMachine(SYMS)
    rw_sched(mc)
    rw_cells(mc, run=1000, crc=1)
    set_entry(mc, "VR_ENT_FAST")
    mc.poke("vidRawSchedPage", SCHED_PAGE)
    mapnr(mc, 6, 12)
    scr = S("VR_SCRATCH")
    data = [bytes((i * 13 + 7 * k) & 0xFF for i in range(512)) for k in range(3)]
    fired = []
    card = Card([data[0]], waits=1, crc_first=True)
    mc.set_card(card)
    mc.run("nxb_rw_go", traps={S("nxb_lrow"): ret_trap(lambda c: fired.append(c.pc)), **aborts()})
    got = (len(fired), mc.mmu[6], card.pos, mc.peek("vidDsCrcDue"), mc.peek("vidStrmRunBlkH", 2))
    if got != (1, SCHED_PAGE, len(card.stream), 1, 1000) or bytes(mc.mem[scr:scr + 512]) != data[0]:
        raise Fail(f"nxb_rw_go: (lrow entries, MMU6, reads, crcDue, run) = {got}")
    check_log(mc, card, "nxb_rw_go")
    mc.poke("vidDsCrcDue", 0)                 # no CRC pends: vr_sector reads none
    mapnr(mc, 6, 12)
    card = Card([data[2]], waits=1)
    mc.set_card(card)
    mc.run("nxb_rw_go", traps={S("nxb_lrow"): ret_trap(lambda c: fired.append(c.pc)), **aborts()})
    if (card.pos, mc.peek("vidDsCrcDue"), mc.peek("vidStrmRunBlkH", 2)) != (len(card.stream), 1, 1000):
        raise Fail(f"nxb_rw_go, no CRC due: {card.pos} reads, crcDue {mc.peek('vidDsCrcDue')}")
    mc.poke16("vidStrmRunBlkH", 999)
    logs = []
    for name, k in (("nxb_rw_sec", 1), ("nxb_rw_col", 2)):
        card = Card([data[k]], waits=3, crc_first=True)
        mc.set_card(card)
        mapnr(mc, 2, BACK_BANK * 2)
        mc.load_phys(BACK_BANK * 0x4000, bytes([SURF_FILL]) * 0x2000)
        mc.sync()
        before = bytes(mc.phys)
        run0 = mc.peek("vidStrmRunBlkH", 2)
        cpu = mc.run(name, traps=aborts())
        phases = [ph for ph, _ in card.log]
        if phases != ["crc"] * 2 + ["wait"] * 3 + ["token"] + ["data"] * 512:
            raise Fail(f"{name}: reads {phases[:8]}... ({len(phases)})")
        check_log(mc, card, name)
        if mc.peek("vidStrmRunBlkH", 2) != run0 or cpu.c != PORT_SPI:
            raise Fail(f"{name}: run {mc.peek('vidStrmRunBlkH', 2)} (counted by the open), "
                       f"C ${cpu.c:02X}")
        surf = BACK_BANK * 2 * SLOT
        if name == "nxb_rw_sec":
            if bytes(mc.mem[scr:scr + 512]) != data[k]:
                raise Fail("nxb_rw_sec: VR_SCRATCH does not hold the sector")
            allow = frame_allow()
            allow[BACK_BANK * 2] = None
        else:
            want = bytearray([SURF_FILL]) * SLOT
            for c in range(8):
                want[c * 256:c * 256 + 64] = data[k][c * 64:(c + 1) * 64]
            if bytes(mc.phys[surf:surf + SLOT]) != bytes(want) or cpu.hl != 0x4800:
                raise Fail(f"nxb_rw_col: surface page differs or HL ${cpu.hl:04X} != $4800")
            allow = frame_allow()
            allow[SCHED_PAGE] = None
        stray_writes(before, bytes(mc.phys), allow)
        logs.append(phases)
    if logs[0] != logs[1]:
        raise Fail("RSEC and RCOL reps read different sequences")
    # whole rows from the kind
    for run0, reps, runs in ((1000, 2, True), (3, 2, True), (2, 2, False)):
        what = f"RSEC row, {reps} reps, run {run0}"
        mc = nxb_machine()
        rw_sched(mc)
        rw_cells(mc, run=run0, crc=1)
        set_entry(mc, "VR_ENT_CROSS")
        mapnr(mc, 6, S("NXB_PAGE"))
        for n, v in (("vidRawSchedPage", SCHED_PAGE), ("l2BackBank", BACK_BANK),
                     ("nxbSO", 0x77)):
            mc.poke(n, v)
        mc.poke16("nxbParam", 0)
        mc.poke16("nxbReps", reps)
        remain0 = mc.peek("vidStrmRemainBlk", 3)
        card = Card([data[k % 3] for k in range(reps + 1)] if runs else [], waits=1,
                    crc_first=True)
        mc.set_card(card)
        seen, msgs, so = [], [], []

        def rep(c):
            seen.append((mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3),
                         entry_of(mc), card.pos))
            c.step()
        def nxb6(fn):
            """A trap for an NXB_PAGE label: only with NXB_PAGE at MMU6 (the slide shares
            the addresses)."""
            def t(c):
                if mc.mmu[6] == S("NXB_PAGE"):
                    fn(c)
                else:
                    c.step()
            return t
        noop = ret_trap(lambda c: None)
        traps = {S("nxb_lc_start"): noop, S("nxb_lc_end"): noop, S("nxb_sat"): nxb6(noop),
                 S("nxb_tm_out"): noop, S("nxb_rw_sec"): rep,
                 S("nxb_sprint"): nxb6(ret_trap(lambda c: so.append(mc.peek("nxbSO")))),
                 S("dbg_puts"): ret_trap(lambda c: msgs.append(c.hl)), **aborts()}
        cpu = mc.run("nxb_kind_rblk", traps=traps)
        got = (card.pos, len(card.stream), mc.peek("vidStrmRunBlkH", 2),
               mc.peek("vidStrmRemainBlk", 3), entry_of(mc), so, msgs, cpu.fc)
        if runs:
            want = (len(card.stream), len(card.stream), run0 - reps - 1, remain0 - reps - 1,
                    "VR_ENT_FAST", [0], [], 0)
            first = (run0 - reps - 1, remain0 - reps - 1, "VR_ENT_FAST", 516)
            if not seen or seen[0] != first or len(seen) != reps:
                raise Fail(f"{what}: at the reps (run, remain, entry, reads) {seen}, the "
                           f"first expected {first}")
            check_log(mc, card, what)
        else:
            want = (0, 0, run0, remain0, "VR_ENT_CROSS", [], [S("nxbMsgRun")], 1)
        if got != want:
            raise Fail(f"{what}: (reads, of, run, remain, entry, O at the print, messages, CF) "
                       f"= {got}, expected {want}")


def test_rw_hist():
    """nxb_rh_body with each head (param 0: nxb_rh_sec, CRC 2 to poll 1 at the production
    18 T; param 1: nxb_rh_sec39, 39 T): RSEC with the wait of k $FF polls binned by the bit
    length of min(k, 256), the two heads binning the same waits identically (bin 0: the token
    on poll 1; past 256 polls vid_sd_tok_h, C reloaded for the slide's 512 reads from $EB);
    the run count never read or counted (the card row charged it), a count of 0 included;
    gaps [15, 18, 22, 47] and [15, 39, 22, 47]; 1 + 256 + 65536 $FF polls or a bad token
    abort with VID_ERR_TOKEN and leave the bins. nxb_kind_rhist writes the head from nxbParam
    before each row: param 1 then param 0."""
    bench_only()
    nb, hb, scr = S("NXB_HIST_BINS"), S("nxbHistBin"), S("VR_SCRATCH")
    if nb != 17:
        raise Fail(f"NXB_HIST_BINS = {nb}")
    sec_at = S("nxb_rh_body.sec")
    last = 256 + 65536
    binned = {}
    for head, poll1 in (("nxb_rh_sec", poll1_t()), ("nxb_rh_sec39", 39)):
        mc = RawMachine(SYMS)
        rw_sched(mc)
        rw_cells(mc, run=1000, crc=1)
        mc.mem[sec_at:sec_at + 2] = le(S(head))
        mc.mem[hb:hb + 2 * nb] = bytes(2 * nb)
        owner = owner_fn(mc)
        want = [0] * nb
        for i, k in enumerate((0, 1, 2, 3, 4, 7, 8, 255, 256, 257, 300, 1000, 65535, last, 5)):
            sec = bytes((j * 5 + i) & 0xFF for j in range(512))
            card = Card([sec], waits=k, crc_first=True)
            mc.set_card(card)
            if k == 5:
                mc.poke16("vidStrmRunBlkH", 0)
            run0 = mc.peek("vidStrmRunBlkH", 2)
            cpu = mc.run("nxb_rh_body", traps={**forbid("vid_run_walk_h"), **aborts()},
                         budget=5_000_000, c=PORT_SPI)
            want[min(k, 256).bit_length()] += 1
            bins = [mc.mem[hb + 2 * j] | mc.mem[hb + 2 * j + 1] << 8 for j in range(nb)]
            run1 = mc.peek("vidStrmRunBlkH", 2)
            if bins != want or card.pos != len(card.stream) or bytes(mc.mem[scr:scr + 512]) != sec:
                raise Fail(f"{head} {k} polls: bins {bins}, expected {want}; {card.pos} of "
                           f"{len(card.stream)} reads")
            if run1 != run0 or cpu.c != PORT_SPI or cpu.hl != scr + 512:
                raise Fail(f"{head} {k} polls: run {run0} -> {run1}, C ${cpu.c:02X}, "
                           f"HL ${cpu.hl:04X}")
            mine = min(k + 1, 257)
            who = [owner(pc) for _, pc in card.log]
            if who != [head] * 2 + ["nxb_rh_sec"] * mine + ["vid_sd_tok_h"] * (k + 1 - mine) \
                    + ["slide"] * 512:
                raise Fail(f"{head} {k} polls: readers {sorted(set(who[:mine + 2]))} then "
                           f"{sorted(set(who[mine + 2:k + 3]))} then "
                           f"{sorted(set(who[k + 3:]))}, expected CRC by {head}, {mine} polls "
                           f"by nxb_rh_sec")
        binned[head] = want
        for what, card, unread in (
                ("1 + 256 + 65536 polls", Card([bytes(512)], waits=last + 1, crc_first=True),
                 513),
                ("token $FD on poll 1", Card([bytes(512)], crc_first=True, token=0xFD), 512),
                ("token $FD on poll 4", Card([bytes(512)], waits=3, crc_first=True, token=0xFD),
                 512),
                ("token $00 in vid_sd_tok_h", Card([bytes(512)], waits=300, crc_first=True,
                                                   token=0x00), 512)):
            mc.set_card(card)
            try:
                mc.run("nxb_rh_body", traps=aborts(), budget=5_000_000, c=PORT_SPI)
            except Stop as e:
                if not reached(e, "vid_dec_abort_pos") or e.a != S("VID_ERR_TOKEN") \
                        or card.pos != len(card.stream) - unread:
                    raise Fail(f"{head} {what}: {e}, {card.pos} reads")
            else:
                raise Fail(f"{head} {what}: no VID_ERR_TOKEN abort")
        bins = [mc.mem[hb + 2 * j] | mc.mem[hb + 2 * j + 1] << 8 for j in range(nb)]
        if bins != want:
            raise Fail(f"{head}: a timed-out wait changed the bins: {bins}")
        mc.cpu.b = 0
        g = open_gaps(mc, b"\xCD" + le(S("nxb_rh_body")) + b"\xC9", 2)[:4]
        if g != [15, poll1, 22, 47]:
            raise Fail(f"{head}: gaps {g}, expected [15, {poll1}, 22, 47]")
    if binned["nxb_rh_sec"] != binned["nxb_rh_sec39"]:
        raise Fail(f"the heads bin the same waits differently: {binned}")
    # nxb_kind_rhist sets the head from nxbParam before every row
    mc = nxb_machine()
    mapnr(mc, 6, S("NXB_PAGE"))
    rw_cells(mc, run=5000, crc=1)
    heads = []
    for param, head in ((1, "nxb_rh_sec39"), (0, "nxb_rh_sec")):
        mc.poke16("nxbParam", param)
        mc.poke16("nxbReps", 16)
        mc.run("nxb_kind_rhist", traps={S("nxb_rw_go"): ret_trap(
            lambda c: heads.append(mc.mem[sec_at] | mc.mem[sec_at + 1] << 8))})
        if heads[-1] != S(head):
            raise Fail(f"nxb_kind_rhist param {param}: nxb_rh_body.sec ${heads[-1]:04X}, "
                       f"expected {head}")


class PortMachine(RawMachine):
    """Logs CTC 0 and DAC port writes with HL', IX, the stub's target and CTC 0's IM2 table
    entry at each write."""

    def __init__(self, syms):
        super().__init__(syms)
        self.ports = []

    def port_out(self, port, v):
        lo, ctc = port & 0xFF, S("AUD_CTC_PORT")
        if port == ctc or lo in (S("DAC_PORT"),) + DAC_PORTS:
            self.ports.append((port if port == ctc else lo, v, alt_hl(self.cpu), self.cpu.ix,
                               stub_target(self), vec_entry(self)))
            return
        super().port_out(port, v)


def test_rw_arms():
    """RARM primes HL' after CTC 0's reset and control word, before its time constant, leaves
    IX alone and points CTC 0's table entry at nxbSessVec before that time constant; ARMOLD,
    entered with the entry at the raw handler (as RARM leaves it), puts the entry at
    IM2_CTC_STUB and installs video_ctc_isr_stereo behind it with CTC 0 stopped and primes IX;
    ARM leaves the entry; DISARM stops CTC 0, parks the DACs, then puts nxbSessVec back and
    the entry to IM2_CTC_STUB. RARM then ARMOLD with no DISARM between: ARMOLD's time constant
    starts the old stereo handler."""
    bench_only()
    ctc, base, sil = S("AUD_CTC_PORT"), S("vidAudBuf"), S("DAC_SILENCE")
    raw_st, stereo = S("video_ctc_isr_raw_st"), S("video_ctc_isr_stereo")
    stub = S("IM2_CTC_STUB") + 1
    im2s = S("IM2_CTC_STUB")
    cw, rst = S("AUD_CTC_CW16"), S("AUD_CTC_RESET")

    def ldix(c):
        c.ix = base
        c.pc += 4

    def runs(mc):
        """The handler CTC 0's interrupt reaches: the entry, through the stub's jp."""
        e = vec_entry(mc)
        return stub_target(mc) if e == im2s and mc.mem[im2s] == 0xC3 else e
    mc = nxb_machine(PortMachine)
    mapnr(mc, 6, S("NXB_PAGE"))
    code_is(mc, "nxb_arm_ix", b"\xDD\x21" + le(base))
    mc.poke("vidCtcTc", 0x70)
    mc.mem[im2s:im2s + 3] = b"\xC3" + le(raw_st)          # im2_init's jp, the session target
    set_table(mc, im2s)
    mc.poke16("nxbSessVec", raw_st)
    seq = []
    for kind in ("nxb_kind_rarm", "nxb_kind_armold"):
        mc.ports = []
        mc.run(kind, traps={S("nxb_arm_ix"): ldix})
        tc = mc.ports[-1]
        seq.append((tc[1], stub_target(mc), vec_entry(mc), runs(mc)))
    if seq != [(0x70, raw_st, raw_st, raw_st), (0x70, stereo, im2s, stereo)]:
        raise Fail(f"RARM then ARMOLD: (time constant, stub target, entry, handler run) = "
                   f"{[tuple(hex(x) for x in s) for s in seq]}; ARMOLD must run "
                   f"video_ctc_isr_stereo ${stereo:04X} through IM2_CTC_STUB ${im2s:04X}")
    for kind in ("nxb_kind_rarm", "nxb_kind_armold", "nxb_kind_arm", "nxb_kind_disarm"):
        mc = nxb_machine(PortMachine)
        mapnr(mc, 6, S("NXB_PAGE"))
        cpu = mc.cpu
        mc.poke("vidCtcTc", 0x70)
        mc.mem[stub:stub + 2] = le(stereo if kind == "nxb_kind_disarm" else raw_st)
        e0 = raw_st if kind in ("nxb_kind_disarm", "nxb_kind_armold") else im2s
        set_table(mc, e0)
        mc.poke16("nxbSessVec", raw_st)
        mc.mem[base:base + S("NXV_AUD_RING")] = bytes([0x11]) * S("NXV_AUD_RING")
        set_alt_hl(cpu, 0x1234)
        cpu.ix = 0xDEAD
        traps = {}
        if kind in ("nxb_kind_armold", "nxb_kind_arm"):
            traps[S("nxb_arm_ix")] = ldix
        mc.run(kind, traps=traps)
        vec, ent = stub_target(mc), vec_entry(mc)
        if kind == "nxb_kind_disarm":
            want = [(ctc, rst, 0x1234, 0xDEAD, stereo, raw_st)] * 2 + [
                (p, sil, 0x1234, 0xDEAD, stereo, raw_st)
                for p in (S("DAC_PORT"), DAC_L, DAC_R, DAC_M)]
            if mc.ports != want or (vec, ent) != (raw_st, im2s):
                raise Fail(f"{kind}: ports {mc.ports}, vector ${vec:04X}, entry ${ent:04X}")
            continue
        hl1, ix1, v1, e1 = {"nxb_kind_rarm": (base, 0xDEAD, raw_st, raw_st),
                            "nxb_kind_armold": (0x1234, base, stereo, im2s),
                            "nxb_kind_arm": (0x1234, base, raw_st, im2s)}[kind]
        want = [(ctc, rst, 0x1234, 0xDEAD, raw_st, e0)] * 2 + [
            (ctc, cw, 0x1234, 0xDEAD, raw_st, e0), (ctc, 0x70, hl1, ix1, v1, e1)]
        ring = bytes(mc.mem[base:base + S("NXV_AUD_RING")])
        if mc.ports != want or (vec, ent) != (v1, e1) or ring != bytes([sil]) * len(ring):
            raise Fail(f"{kind}: ports {mc.ports}, vector ${vec:04X}, entry ${ent:04X}, ring "
                       f"silent {ring == bytes([sil]) * len(ring)}")


def test_vec_bench():
    """RW1's arm rows on a raw session, CTC 0's entry as l2setup leaves it (the handler):
    ARM1 (RARM) has the entry at nxbSessVec at its time constant; DSRM stops CTC 0 with the
    entry in place, then puts IM2_CTC_STUB back; ARM2 (RARM) writes nxbSessVec again; DSRM;
    ARMO runs video_ctc_isr_stereo through the stub (entry IM2_CTC_STUB at its time
    constant); the last DSRM leaves the entry IM2_CTC_STUB and the stub's target nxbSessVec.
    No other table byte changes."""
    bench_only()
    base, im2s, stereo = S("vidAudBuf"), S("IM2_CTC_STUB"), S("video_ctc_isr_stereo")

    def ldix(c):
        c.ix = base
        c.pc += 4
    for h in ("video_ctc_isr_raw_st", "video_ctc_isr_raw_mono"):
        hv = S(h)
        mc = nxb_machine(PortMachine)
        mapnr(mc, 6, S("NXB_PAGE"))
        code_is(mc, "nxb_arm_ix", b"\xDD\x21" + le(base))
        mc.poke("vidCtcTc", 0x70)
        set_table(mc, hv)
        mc.mem[im2s + 1:im2s + 3] = le(hv)
        mc.poke16("nxbSessVec", hv)
        rest = table_rest(mc)
        for row, kind, at_last, entry, target in (
                ("ARM1", "nxb_kind_rarm", hv, hv, hv), ("DSRM", "nxb_kind_disarm", hv, im2s, hv),
                ("ARM2", "nxb_kind_rarm", hv, hv, hv), ("DSRM", "nxb_kind_disarm", hv, im2s, hv),
                ("ARMO", "nxb_kind_armold", im2s, im2s, stereo),
                ("DSRM", "nxb_kind_disarm", im2s, im2s, hv)):
            mc.ports = []
            mc.run(kind, traps={S("nxb_arm_ix"): ldix})
            got = (mc.ports[-1][5], vec_entry(mc), stub_target(mc))
            if got != (at_last, entry, target) or table_rest(mc) != rest:
                raise Fail(f"{h} {row}: entry at the last CTC/DAC write ${got[0]:04X}, after "
                           f"${got[1]:04X}, stub target ${got[2]:04X}, rest of the table kept "
                           f"{table_rest(mc) == rest}; expected ${at_last:04X}, ${entry:04X}, "
                           f"${target:04X}")


def test_rw_kinds():
    """The NXB kinds' untimed setup: RBLK/RHIST charge reps + 1 to the 24-bit remain and to
    the run count, write VR_ENT_FAST and pick the body (RBLK maps the hidden surface page at
    MMU2, RHIST zeroes the bins and patches the print); fewer than NXB_RW_MIN blocks left
    (NXB SHORT) or a run shorter than reps + 1 (NXB RUN) print that marker and run and charge
    nothing; RHIST's print saves tag and bins (NXB_HIST_MAX = 4 slots) and restores the exit;
    RFRAME/SPIN bodies; IDEN's raw picture width."""
    bench_only()
    hb, nb = S("nxbHistBin"), S("NXB_HIST_BINS")
    if S("NXB_HIST_MAX") != 4:
        raise Fail(f"NXB_HIST_MAX = {S('NXB_HIST_MAX')}, expected 4 (RHST, RH39, AHST, AH39)")
    msg = nxb_machine()
    mapnr(msg, 6, S("NXB_PAGE"))
    for name, text in (("nxbMsgShort", b" NXB SHORT\0"), ("nxbMsgRun", b" NXB RUN\0")):
        if bytes(msg.mem[S(name):S(name) + len(text)]) != text:
            raise Fail(f"{name}: {bytes(msg.mem[S(name):S(name) + len(text)])!r}, expected {text!r}")

    def kmc(run=0x5A5A):
        mc = nxb_machine()
        mapnr(mc, 6, S("NXB_PAGE"))
        mc.poke("l2BackBank", BACK_BANK)
        mc.poke16("nxbReps", 128)
        mc.poke("nxbSO", 0x77)
        mc.poke16("vidStrmRunBlkH", run)
        set_entry(mc, "VR_ENT_CROSS")
        return mc
    seen = {}

    def at(name):
        def t(c):
            seen[name] = (c.pc, mc.mem[S("nxb_body") + 1] | mc.mem[S("nxb_body") + 2] << 8)
            c.pc = c.pop()
        return t
    for kind, param, reps, remain, body, left, run in (
            ("nxb_kind_rblk", 0, 128, 0x012345, "nxb_rw_sec", 0x012345 - 129, 0x5A5A),
            ("nxb_kind_rblk", 1, 128, 0x010000, "nxb_rw_col", 0x010000 - 129, 0x5A5A),
            ("nxb_kind_rblk", 1, 128, 5000, "nxb_rw_col", 5000 - 129, 0x5A5A),
            ("nxb_kind_rhist", 0, 2048, 0x020000, "nxb_rh_body", 0x020000 - 2049, 0x5A5A),
            ("nxb_kind_rhist", 1, 2048, 0x020000, "nxb_rh_body", 0x020000 - 2049, 2049),
            ("nxb_kind_rblk", 0, 128, 4999, None, 4999, 0x5A5A),
            ("nxb_kind_rhist", 0, 2048, 0, None, 0, 0x5A5A),
            ("nxb_kind_rblk", 0, 128, 0x012345, None, 0x012345, 128),
            ("nxb_kind_rhist", 1, 2048, 0x020000, None, 0x020000, 0)):
        mc = kmc(run)
        mc.poke16("nxbParam", param)
        mc.poke16("nxbReps", reps)
        mc.poke("vidStrmRemainBlk", remain.to_bytes(3, "little"))
        mc.mem[hb:hb + 2 * nb] = b"\x5A" * (2 * nb)
        pr = S("nxb_lrow.pr")
        mc.mem[pr:pr + 2] = le(S("nxb_sprint"))
        seen.clear()
        msgs = []
        noop = ret_trap(lambda c: None)
        traps = {S("nxb_rw_go"): at("go"), S("nxb_sat"): noop, S("nxb_tm_out"): noop,
                 S("dbg_puts"): ret_trap(lambda c: msgs.append(c.hl))}
        cpu = mc.run(kind, traps=traps)
        what = f"{kind} param {param} remain ${remain:06X} run {run}"
        if mc.peek("vidStrmRemainBlk", 3) != left:
            raise Fail(f"{what}: remain ${mc.peek('vidStrmRemainBlk', 3):06X}, expected ${left:06X}")
        run_left = run if body is None else run - reps - 1
        ent = "VR_ENT_CROSS" if body is None else "VR_ENT_FAST"
        if (mc.peek("vidStrmRunBlkH", 2), entry_of(mc)) != (run_left, ent):
            raise Fail(f"{what}: run {mc.peek('vidStrmRunBlkH', 2)}, entry {entry_of(mc)}; "
                       f"expected {run_left}, {ent}")
        if body is None:
            why = "nxbMsgShort" if remain < S("NXB_RW_MIN") else "nxbMsgRun"
            if "go" in seen or not cpu.fc or msgs != [S(why)]:
                raise Fail(f"{what}: refused row ran or printed {msgs} (CF {cpu.fc}), "
                           f"expected {why}")
            continue
        if seen.get("go", (0, 0))[1] != S(body):
            raise Fail(f"{what}: body ${seen.get('go', (0, 0))[1]:04X}, expected {body}")
        bins = bytes(mc.mem[hb:hb + 2 * nb])
        patched = mc.mem[pr] | mc.mem[pr + 1] << 8
        if (mc.peek("nxbRunB", 2), mc.peek("nxbRemB", 2)) != (run, remain & 0xFFFF):
            raise Fail(f"{what}: walk mark before the row {mc.peek('nxbRunB', 2):04X} "
                       f"{mc.peek('nxbRemB', 2):04X}")
        if kind == "nxb_kind_rhist":
            if bins != bytes(2 * nb) or patched != S("nxb_rh_done"):
                raise Fail(f"{what}: bins not zeroed or nxb_lrow.pr ${patched:04X}")
        elif mc.mmu[2] != BACK_BANK * 2 or patched != S("nxb_rw_done"):
            raise Fail(f"{what}: MMU2 {mc.mmu[2]}, nxb_lrow.pr ${patched:04X}")
    # RHIST's print: slots 0 to 3, then capped
    mc = kmc()
    tab = S("nxbTabBuf")
    sav, ln = S("nxbHistSav"), S("NXB_HIST_LEN")
    mc.mem[sav:sav + 4 * ln] = b"\xEE" * (4 * ln)
    saved = []
    for n, tag in ((0, b"RHST"), (1, b"RH39"), (2, b"AHST"), (3, b"AH39"), (4, b"XHST")):
        mc.poke("nxbHistN", n)
        mc.mem[tab:tab + 4] = tag
        mc.poke16("nxbTag", tab)
        pr = S("nxb_lrow.pr")
        mc.mem[pr:pr + 2] = le(S("nxb_rh_done"))
        binv = bytes((n * 16 + j) & 0xFF for j in range(2 * nb))
        mc.mem[hb:hb + 2 * nb] = binv
        sp = []
        mc.run("nxb_rh_done", traps={S("nxb_sprint"): ret_trap(lambda c: sp.append(1))})
        want_n = min(n + 1, S("NXB_HIST_MAX"))
        if mc.peek("nxbHistN") != want_n or sp != [1] or mc.peek("nxb_lrow.pr", 2) != S("nxb_sprint"):
            raise Fail(f"nxb_rh_done at {n}: nxbHistN {mc.peek('nxbHistN')}, prints {len(sp)}")
        if n < 4:
            saved.append(tag + binv)
        if bytes(mc.mem[sav:sav + 4 * ln]) != b"".join(saved) + b"\xEE" * ((4 - len(saved)) * ln):
            raise Fail(f"nxb_rh_done at {n}: slots hold {bytes(mc.mem[sav:sav + 4 * ln])[:12]!r}...")
    for kind, body, exit_ in (("nxb_kind_rfr", "nxb_rw_fbody", "nxb_rw_done"),
                              ("nxb_kind_spin", "nxb_rw_spin", "nxb_sprint")):
        mc = kmc()
        pr = S("nxb_lrow.pr")
        mc.mem[pr:pr + 2] = le(S("nxb_sprint"))
        seen.clear()
        mc.run(kind, traps={S("nxb_lrow"): at("lrow")})
        if (seen.get("lrow", (0, 0))[1], mc.peek("nxbSO"), mc.peek("nxb_lrow.pr", 2)) != \
                (S(body), 0, S(exit_)):
            raise Fail(f"{kind}: body ${seen.get('lrow', (0, 0))[1]:04X}, expected {body}; "
                       f"exit ${mc.peek('nxb_lrow.pr', 2):04X}")
    # the walk mark at the print: O = 01 when the run count fell by other than the blocks read
    for run0, rem0, run1, rem1, mark in ((1000, 0x2345, 871, 0x22C4, 0),     # 129 read, no walk
                                         (100, 0x2345, 3971, 0x22C4, 1),     # walked into a run
                                         (0, 0x0010, 65535, 0x000F, 0),      # wrap-safe words
                                         (500, 0x8000, 500, 0x7FFF, 1)):     # count stood still
        mc = kmc()
        mc.poke16("nxbRunB", run0)
        mc.poke16("nxbRemB", rem0)
        mc.poke16("vidStrmRunBlkH", run1)
        mc.poke("vidStrmRemainBlk", (rem1 | 0x010000).to_bytes(3, "little"))
        pr = S("nxb_lrow.pr")
        mc.mem[pr:pr + 2] = le(S("nxb_rw_done"))
        sp = []
        mc.run("nxb_rw_done", traps={S("nxb_sprint"): ret_trap(lambda c: sp.append(1))})
        if (mc.peek("nxbSO"), sp, mc.peek("nxb_lrow.pr", 2)) != (mark, [1], S("nxb_sprint")):
            raise Fail(f"walk mark run {run0}->{run1} remain {rem0:04X}->{rem1:04X}: O "
                       f"{mc.peek('nxbSO')}, expected {mark}")
    # mode 14 (EXTERN 0 12 arm) clears the histograms a bailed session would re-log
    mc = RawMachine(SYMS)
    fl = S("flags")
    mc.mem[fl + 250], mc.mem[fl + 248] = S("NXB_MODE_ARM"), 5
    mc.poke("nxbHistN", 2)
    mc.run("nxb_entry")
    if (mc.peek("nxbSessReq"), mc.peek("nxbHistN"), mc.mem[fl + 248], mc.mem[fl + 250]) != (5, 0, 0, 0):
        raise Fail(f"nxb_entry mode 14: request {mc.peek('nxbSessReq')}, nxbHistN "
                   f"{mc.peek('nxbHistN')}")
    # IDEN: F = the surface width, less 2 x x0 for a raw clip; a raw clip's row then " H1C"
    # (raw_fit.MODEL_MARK), printed inside the MMU3 print bracket
    for raw, pages, page0, h0, want in ((1, 10, 0, 0x40, 320), (1, 10, 0, 0x54, 280),
                                        (1, 10, 1, 0x40, 256), (1, 10, 4, 0x5E, 4),
                                        (1, 6, 0, 0x40, 256), (0, 10, 3, 0x41, 320),
                                        (0, 6, 3, 0x41, 256)):
        mc = kmc()
        for name, v in (("vidRaw", raw), ("vidDstPages", pages), ("vidRawPage0", page0),
                        ("vidRawH0", h0), ("vidHeightB", 192), ("nxbSessLive", 1),
                        ("nxbSvTm3", 0x2A), ("nxbSvAud3", 0x2B)):
            mc.poke(name, v)
        out = []

        def puts(c):
            a, s = c.hl, b""
            while mc.mem[a]:
                s, a = s + bytes([mc.mem[a]]), a + 1
            out.append((s.decode("ascii"), mc.nr.get(0x53)))
        mc.run("nxb_kind_id", traps={S("nxb_fprint"): ret_trap(lambda c: out.append("row")),
                                     S("dbg_puts"): ret_trap(puts)})
        mark = ["row", (" H1C", 0x2A)] if raw else ["row"]
        if mc.peek("nxbLcF", 2) != want or out != mark or raw and mc.nr.get(0x53) != 0x2B:
            raise Fail(f"IDEN raw {raw} pages {pages} x0 {page0 * 32 + h0 - 0x40}: F "
                       f"{mc.peek('nxbLcF', 2)}, expected {want}; prints {out}, expected "
                       f"{mark}; MMU3 after {mc.nr.get(0x53)}")


# Zilog T-states (no wait states on core 3.03.03) for tcount. T_COND: (taken, not taken,
# length). ldir/otir/inir are priced from BC/B before the model's one-step loop.
T_MAIN = {op: (7 if op & 7 == 6 or (op >> 3) & 7 == 6 else 4) for op in range(0x40, 0x80)}
T_MAIN.update({op: (7 if op & 7 == 6 else 4) for op in range(0x80, 0xC0)})
del T_MAIN[0x76]
T_MAIN.update({
    0x00: 4, 0x01: 10, 0x02: 7, 0x03: 6, 0x04: 4, 0x05: 4, 0x06: 7, 0x07: 4, 0x08: 4, 0x09: 11,
    0x0A: 7, 0x0B: 6, 0x0C: 4, 0x0D: 4, 0x0E: 7, 0x0F: 4, 0x11: 10, 0x12: 7, 0x13: 6, 0x14: 4,
    0x15: 4, 0x16: 7, 0x17: 4, 0x18: 12, 0x19: 11, 0x1A: 7, 0x1B: 6, 0x1C: 4, 0x1D: 4, 0x1E: 7,
    0x1F: 4, 0x21: 10, 0x22: 16, 0x23: 6, 0x24: 4, 0x25: 4, 0x26: 7, 0x27: 4, 0x29: 11,
    0x2A: 16, 0x2B: 6, 0x2C: 4, 0x2D: 4, 0x2E: 7, 0x2F: 4, 0x31: 10, 0x32: 13, 0x33: 6,
    0x34: 11, 0x35: 11, 0x36: 10, 0x37: 4, 0x39: 11, 0x3A: 13, 0x3B: 6, 0x3C: 4, 0x3D: 4,
    0x3E: 7, 0x3F: 4, 0xC1: 10, 0xC3: 10, 0xC5: 11, 0xC6: 7, 0xC9: 10, 0xCD: 17, 0xCE: 7,
    0xD1: 10, 0xD3: 11, 0xD5: 11, 0xD6: 7, 0xD9: 4, 0xDB: 11, 0xDE: 7, 0xE1: 10, 0xE3: 19,
    0xE5: 11, 0xE6: 7, 0xE9: 4, 0xEB: 4, 0xEE: 7, 0xF1: 10, 0xF3: 4, 0xF5: 11, 0xF6: 7,
    0xF9: 6, 0xFB: 4, 0xFE: 7})
T_MAIN.update({op: 10 for op in range(0xC2, 0x100, 8)})                # jp cc
T_COND = {0x10: (13, 8, 2), 0x20: (12, 7, 2), 0x28: (12, 7, 2), 0x30: (12, 7, 2), 0x38: (12, 7, 2)}
T_COND.update({op: (11, 5, 1) for op in range(0xC0, 0x100, 8)})        # ret cc
T_COND.update({op: (17, 10, 3) for op in range(0xC4, 0x100, 8)})       # call cc
T_ED = {0x40 | r << 3: 12 for r in range(8)}                           # in r,(c)
T_ED.update({0x41 | r << 3: 12 for r in range(8)})                     # out (c),r
T_ED.update({op: 15 for op in (0x42, 0x52, 0x62, 0x72, 0x4A, 0x5A, 0x6A, 0x7A)})
T_ED.update({op: 20 for op in (0x43, 0x53, 0x63, 0x73, 0x4B, 0x5B, 0x6B, 0x7B)})
T_ED.update({0x44: 8, 0x45: 14, 0x4D: 14, 0xA0: 16, 0xA1: 16, 0xA2: 16, 0xA3: 16, 0x23: 8,
             0x24: 8, 0x27: 11, 0x30: 8, 0x31: 8, 0x32: 8, 0x33: 8, 0x34: 16, 0x35: 16,
             0x36: 16, 0x90: 16, 0x91: 20, 0x92: 17})


def tstep(mc):
    """Execute one instruction and return its Zilog T; an opcode with no T entry fails
    (no guessed figure)."""
    cpu, m = mc.cpu, mc.mem
    pc = cpu.pc
    op, cond = m[pc], None
    if op == 0xED:
        sub = m[(pc + 1) & 0xFFFF]
        if sub == 0xB0:
            base = 21 * (cpu.bc or 0x10000) - 5
        elif sub in (0xB2, 0xB3):
            base = 21 * (cpu.b or 256) - 5
        elif sub in T_ED:
            base = T_ED[sub]
        else:
            raise Fail(f"tstep: ED {sub:02X} at ${pc:04X} has no T entry")
    elif op == 0xCB:
        sub = m[(pc + 1) & 0xFFFF]
        base = 8 if sub & 7 != 6 else 12 if 0x40 <= sub < 0x80 else 15
    elif op in T_COND:
        cond = T_COND[op]
    elif op in T_MAIN:
        base = T_MAIN[op]
    else:
        raise Fail(f"tstep: opcode {op:02X} at ${pc:04X} has no T entry")
    cpu.step()
    if cond:
        base = cond[0] if cpu.pc != (pc + cond[2]) & 0xFFFF else cond[1]
    return base


def tcount(mc, stop, budget=2_000_000):
    """Run from the current PC until stop(cpu), summing Zilog T."""
    t = 0
    while not stop(mc.cpu):
        t += tstep(mc)
        budget -= 1
        if budget <= 0:
            raise Fail("tcount: budget spent")
    return t


IO_START = {"in a,(n)": 7, "in r,(c)": 8, "ini": 9}     # T from an instruction's start to its I/O


def io_trace(mc, stop, budget=2_000_000):
    """Run from the current PC until stop (an address, or a predicate on the CPU), summing
    Zilog T. Returns (T, marks): the T of each port $EB read's I/O start (IO_START). A card
    read by any other instruction, or two in one instruction, fails."""
    cpu, card = mc.cpu, mc.card
    done = stop if callable(stop) else (lambda c: c.pc == stop)
    t, marks = 0, []
    while not done(cpu):
        pc, n = cpu.pc, len(card.log)
        op, sub = mc.mem[pc], mc.mem[(pc + 1) & 0xFFFF]
        dt = tstep(mc)
        if len(card.log) != n:
            if len(card.log) - n == 1 and op == 0xDB:
                off = IO_START["in a,(n)"]
            elif len(card.log) - n == 1 and op == 0xED and sub & 0xC7 == 0x40:
                off = IO_START["in r,(c)"]
            elif len(card.log) - n == 1 and op == 0xED and sub == 0xA2:
                off = IO_START["ini"]
            else:
                raise Fail(f"io_trace: {len(card.log) - n} card read(s) by {op:02X} {sub:02X} "
                           f"at ${pc:04X}: no I/O start for it")
            marks.append(t + off)
        t += dt
        budget -= 1
        if budget <= 0:
            raise Fail("io_trace: budget spent")
    return t, marks


def io_gaps(mc, start, stop):
    """T between successive port $EB reads, I/O start to I/O start, from start (an address;
    None = the current PC) until stop (as io_trace). The caller sets SP and the card."""
    if start is not None:
        mc.cpu.pc = start
    _, marks = io_trace(mc, stop)
    return [b - a for a, b in zip(marks, marks[1:])]


STUB = 0xBF00                       # a scratch call site in page 5 (model only)


def stub_t(mc, code, **regs):
    """T of code (ending in ret) called at STUB, less that ret: the caller's own calls."""
    mc.mem[STUB:STUB + len(code)] = code
    cpu = mc.cpu
    for k, v in regs.items():
        setattr(cpu, k, v)
    cpu.sp = STACK
    cpu.push(RET)
    cpu.pc = STUB
    return tcount(mc, lambda c: c.pc == RET) - 10


def rep_t(mc, body):
    """T of one nxb_lrow rep of body, nxb_lrow.rep to the next .rep."""
    b = S("nxb_body")
    mc.mem[b + 1:b + 3] = le(S(body))
    mc.poke16("nxbLeft", 2)
    cpu, rep = mc.cpu, S("nxb_lrow.rep")
    cpu.sp, cpu.pc = STACK, rep
    t = tstep(mc)                                # .rep's own call nxb_body
    return t + tcount(mc, lambda c: c.pc == rep)


def in_gaps(mc, name):
    """T between the starts of successive in a,(n) in routine name (CRC, CRC, the token
    polls): [CRC1-CRC2, CRC2-poll1, poll1-poll2, ...]."""
    cpu, marks, t = mc.cpu, [], 0
    cpu.sp, cpu.hl = STACK, S("VR_SCRATCH")
    cpu.push(RET)
    cpu.pc = S(name)
    while cpu.pc != RET:
        if mc.mem[cpu.pc] == 0xDB:
            marks.append(t)
        t += tstep(mc)
    return [b - a for a, b in zip(marks, marks[1:])]


def test_rw_harness():
    """RW_CARD_HARNESS_T and RW_FRAME_HARNESS_T (nxv2_bench_rows, subtracted by the gate fit)
    pinned to the emitted bytes: an RSEC rep against the schedule's steady-state sector
    (call vr_sector_n / call VR_SLIDE), RCOL - RSEC = 8 column ends of 38 T, a frame-row rep
    against vid_run's call vid_aud_stage / ld bc / call vid_aud_pump / call vid_decode_any;
    the binned wait's polls as far apart as vr_sector_n's (tags' wait shape), [15, 18, 22, 47]
    in both and [15, 39, 22, 47] in nxb_rh_sec39; the reps' reads. VR_ENT_FAST throughout, as
    nxb_rw_charge and a frame inside its run leave it. The mark a raw IDEN row ends with
    (nxbMsgHarn) is raw_fit's model whose frame harness is RW_FRAME_HARNESS_T."""
    bench_only()
    import nxv2_bench_rows as bench
    sys.path.insert(0, str(Path(__file__).resolve().parent / "core303"))
    import tags

    def card_mc(sectors):
        mc = RawMachine(SYMS)
        rw_sched(mc)
        rw_cells(mc, run=1000, crc=1)
        set_entry(mc, "VR_ENT_FAST")
        mapnr(mc, 2, BACK_BANK * 2)
        mc.set_card(Card([bytes(512)] * sectors, waits=0, crc_first=True))
        mc.cpu.b, mc.cpu.c = 0, PORT_SPI             # the open keeps C: the schedule's contract
        return mc
    rsec = rep_t(card_mc(1), "nxb_rw_sec")
    rcol = rep_t(card_mc(1), "nxb_rw_col")
    flat = RawMachine(SYMS)
    build_sched(flat, 0, 256, 192)
    entry = b"\xCD" + le(S("vr_sector_n")) + b"\xCD" + le(S("VR_SLIDE"))
    if entry not in bytes(flat.mem[S("VR_SCHED"):S("VR_SCHED") + 2000]):
        raise Fail("no call vr_sector_n / call VR_SLIDE pair in a 256x192 schedule")
    sched = stub_t(card_mc(1), entry + b"\xC9", hl=S("VR_SCRATCH"))
    if rsec - sched != bench.RW_CARD_HARNESS_T or rcol - rsec != 8 * 38:
        raise Fail(f"RSEC rep {rsec} T, schedule sector {sched} T: harness {rsec - sched} "
                   f"(RW_CARD_HARNESS_T {bench.RW_CARD_HARNESS_T}); RCOL - RSEC {rcol - rsec}")

    def frame_mc():
        mc = RawMachine(SYMS)
        patch_session(mc, 1, 1)
        if build_sched(mc, 0, 256, 192).fc:
            raise Fail("vid_raw_sched_build set CF")
        setup_frame(mc, 0, 256, 192)
        rw_cells(mc, run=1000, crc=0)
        for n in ("vidRlDiv", "vidRlSpinDiv"):
            if n in SYMS:
                mc.poke(n, 250)                  # no PLAY poll inside the trace
        base = S("vidAudBuf")
        mc.poke16("vidABytes", 1250)
        mc.poke16("vidAudWr", (base + 100) ^ (S("NXV_AUD_RING") // 2))
        set_alt_hl(mc.cpu, base + 100)
        mc.cpu.iff = 1
        snd = bytes(1250) + bytes([0x80]) * (1536 - 1251) + b"\x00"
        mc.set_card(Card(blocks(snd) + blocks(pixels(256 * 192)), waits=1))
        return mc
    fbench = rep_t(frame_mc(), "nxb_rw_fbody")
    play = stub_t(frame_mc(), b"\xCD" + le(S("vid_aud_stage")) + b"\x01\xFF\xFF\xCD"
                  + le(S("vid_aud_pump")) + b"\xCD" + le(S("vid_decode_any")) + b"\xC9")
    if fbench - play != bench.RW_FRAME_HARNESS_T:
        raise Fail(f"frame rep {fbench} T, playback's calls {play} T: harness {fbench - play} "
                   f"(RW_FRAME_HARNESS_T {bench.RW_FRAME_HARNESS_T})")
    # the model IDEN prints (nxbMsgHarn) is raw_fit's model of this harness
    import raw_fit
    if SYMS["nxbMsgHarn"][0] != S("NXB_PAGE"):
        raise Fail("nxbMsgHarn is not on NXB_PAGE")
    pg, o = read_page(S("NXB_PAGE")), S("nxbMsgHarn") & 0x1FFF
    mark = bytes(pg[o:pg.index(0, o)]).decode("ascii")
    model = next((m for m, t in raw_fit.MODEL_MARK.items() if " " + t == mark), None)
    if model is None or raw_fit.MODEL_G_FRAME[model] != bench.RW_FRAME_HARNESS_T:
        raise Fail(f"IDEN's mark {mark!r}: raw_fit model {model}, frame harness "
                   f"{raw_fit.MODEL_G_FRAME.get(model)} (RW_FRAME_HARNESS_T "
                   f"{bench.RW_FRAME_HARNESS_T})")
    gaps = {}
    for name in ("vr_sector_n", "nxb_rh_sec", "nxb_rh_sec39"):
        mc = card_mc(1)
        mc.set_card(Card([bytes(512)], waits=2, crc_first=True))
        gaps[name] = in_gaps(mc, name)
    divider = 0
    if "nxbQuietImage" not in SYMS:              # DEBUG: vr_sector_n's PLAY divider
        divider = stub_t(card_mc(1), b"\x16\x00\xCD" + le(S("vid_dst_norm_flat")) + b"\xC9")
    v, h, h39 = gaps["vr_sector_n"], gaps["nxb_rh_sec"], gaps["nxb_rh_sec39"]
    poll = [tags.NXB_HIST_POLL1_T, tags.NXB_HIST_POLL_T]
    if not (v[:4] == [15, poll1_t() + divider] + poll and h[:4] == [15, poll1_t()]
            + poll == [15, 18, 22, 47] and h39[:4] == [15, 39] + poll):
        raise Fail(f"read gaps vr_sector_n {v[:4]}, nxb_rh_sec {h[:4]}, nxb_rh_sec39 "
                   f"{h39[:4]} (divider {divider} T), tags poll T {poll}")
    # a rep's reads: the token to the first slide read 41 T (RSEC's jp), 48 (RCOL's call)
    for name, want in (("nxb_rw_sec", [41] + [16] * 511),
                       ("nxb_rw_col", [48] + ([16] * 63 + [54]) * 7 + [16] * 63)):
        mc = card_mc(1)
        mc.set_card(Card([bytes(512)], waits=1, crc_first=True))
        mc.cpu.sp = STACK
        mc.cpu.push(RET)
        g = io_gaps(mc, S(name), RET)
        if g != [15, poll1_t() + divider, 22] + want:
            raise Fail(f"{name} rep read gaps {g[:6]}.., {sorted(set(g[4:]))} after the token")


def test_rw_card_c():
    """RSEC's first rep reads through the C nxb_rw_go's vr_sector set: from nxb_kind_rblk
    (param 0) through nxb_rw_go, nxb_lrow and the real nxb_lc_start (raster lines from NR
    $1E/$1F), C = PORT_SPI_DAT at the first rep's first slide ini."""
    bench_only()
    mc = nxb_machine()
    rw_sched(mc)
    mapnr(mc, 6, S("NXB_PAGE"))
    rw_cells(mc, run=1000, crc=1)
    mc.poke("vidRawSchedPage", SCHED_PAGE)
    mc.poke("l2BackBank", BACK_BANK)
    mc.poke16("nxbParam", 0)
    mc.poke16("nxbReps", 2)
    mc.nr[S("NXB_LINE_MSB")], mc.nr[S("NXB_LINE_LSB")] = 0, 100       # inside lines 8-239
    card = Card([bytes(512)] * 3, waits=1, crc_first=True)
    mc.set_card(card)
    cpu = mc.cpu
    cpu.sp, cpu.c = STACK, 0x5A
    cpu.push(RET)
    cpu.pc = S("nxb_kind_rblk")
    traps, seen, rep, c_at = aborts(), set(), S("nxb_lrow.rep"), None
    for _ in range(100_000):
        pc = cpu.pc
        if pc in traps:
            traps[pc](cpu)
        seen.add(pc)
        if rep in seen and mc.mem[pc] == 0xED and mc.mem[(pc + 1) & 0xFFFF] == 0xA2:
            c_at = cpu.c
            break
        cpu.step()
    path = [n for n in ("nxb_rw_go", "nxb_lc_start", "nxb_lc_wait", "nxb_line", "nxb_rw_sec",
                        "vr_sector_n") if S(n) not in seen]
    if c_at != PORT_SPI or path or mc.mmu[6] != SCHED_PAGE:
        raise Fail(f"C at the first rep's slide {c_at if c_at is None else hex(c_at)}, not run: "
                   f"{path}, MMU6 {mc.mmu[6]}")


CHAIN_ENTRY6 = 12                   # MMU6 at the walk's call: a page in no other slot


def chain_ctl(m, pc):
    """(kind, fall-through address) of a control transfer opcode at pc, else None."""
    op = m[pc]
    if op == 0xCD or op & 0xC7 == 0xC4:
        return "call", (pc + 3) & 0xFFFF
    if op & 0xC7 == 0xC7:
        return "call", (pc + 1) & 0xFFFF                 # rst
    if op == 0xC3 or op & 0xC7 == 0xC2:
        return "jump", (pc + 3) & 0xFFFF
    if op in (0x10, 0x18, 0x20, 0x28, 0x30, 0x38):
        return "jump", (pc + 2) & 0xFFFF
    if op == 0xE9:
        return "jump", (pc + 1) & 0xFFFF
    if op == 0xC9 or op & 0xC7 == 0xC0:
        return "ret", (pc + 1) & 0xFFFF
    if op == 0xED and m[(pc + 1) & 0xFFFF] in (0x45, 0x4D):
        return "ret", (pc + 2) & 0xFFFF
    return None


def test_rw_chain():
    """An RFRAME row's chain from nxb_hop6 (HL = nxb_srow_go, MMU6 = page 12) over two frames:
    each $C000-$DFFF fetch on the page MMU6 maps (page A's code, page B's column train (320x192:
    period and driver), VR_BS1, VR_BPG and stubs, NXB_PAGE), each entry there named (a label of
    that page, the train's driver, period, pass 1 entry, or a call's return), the MMU6 swaps,
    the print, the card read to its end."""
    bench_only()
    mc = nxb_machine()
    patch_session(mc, 1, 1)
    if build_sched(mc, 1, 320, 192).fc or built_var(mc) != "train":
        raise Fail("vid_raw_sched_build set CF, or built no train")
    ref = ref_fast(1, 320, 192)
    send = S("VR_SCHED") + len(ref["a"])
    _, bend = parse_fast(mc)
    drv = fast_entry(mc)
    setup_frame(mc, 1, 320, 192)
    mapnr(mc, 7, S("VID_PAGE"))
    mapnr(mc, 6, CHAIN_ENTRY6)
    rw_cells(mc, run=1000, crc=0)
    mc.poke16("vidABytes", 1250)
    mc.poke16("nxbReps", 2)
    mc.poke("nxbKind", S("NXB_K_RFRAME"))
    mc.poke("nxbGeo", 0)
    cpu = mc.cpu
    set_alt_hl(cpu, S("vidAudBuf") + 100)
    cpu.iff = 1
    sectors = []
    for f, tag in enumerate((1, 0)):
        snd = bytes((i * 11 + 5 + f) & 0xFF for i in range(1250)) + pad_bytes(3 * 512 - 1250, tag)
        pal = [bytes((i * 29 + 11) & 255 for i in range(512))] if tag else []
        sectors += blocks(snd) + pal + blocks(pixels(320 * 192))
    card = Card(sectors, waits=1)
    mc.set_card(card)
    nxb, sched = S("NXB_PAGE"), SCHED_PAGE
    pump = (S("VR_PUMP"), S("VR_PUMP") + S("vrPumpLen"))
    stubs = (S("VR_XIN"), S("VR_XIN") + S("VR_XSTUB_LEN"))
    code = ((S("VR_SLIDE"), S("VR_SLIDE_END") + 1), (S("VR_SCHED"), send),
            (S("VR_PALTRAIN"), S("VR_PALTRAIN") + S("VR_PAL_LEN")), pump, stubs)
    codeb = ((S("VR_SLIDE"), bend), (S("VR_BS1"), S("VR_XIN")), stubs)
    # the pump's own labels (assembled at VR_PUMP from vrPumpT): its jump and call targets
    pump_labels = {v for k, (p, v) in SYMS.items()
                   if k.startswith("vrPumpT.") and pump[0] <= v < pump[1]}
    seen = {}

    def noop(name):
        def t(c):
            seen.setdefault(name, []).append(mc.mmu[6])
            c.pc = c.pop()
        return t
    traps = {S(n): noop(n) for n in ("nxb_lc_start", "nxb_lc_end", "nxb_sprint", "vid_rl_poll")
             if n in SYMS}
    traps.update(aborts())
    # Named entries: the schedule page's VR_SCHED, VR_PALTRAIN, VR_PUMP and the pump's labels,
    # even slide entries; any NXB_PAGE label; else only a ret to the return address a call
    # pushed with the same page.
    # vrPumpT's labels are DISP'd: the SLD gives them the page at slot 6 when assembled
    # (NXB_PAGE on DEBUG), so they are not NXB_PAGE entries
    labels6 = {v for k, (p, v) in SYMS.items() if p == nxb and 0xC000 <= v < 0xE000
               and not k.startswith("vrPumpT.")}
    fixed = {S("VR_SCHED"), S("VR_PALTRAIN"), S("VR_PUMP"), S("VR_XIN"), ref["taila"]} \
        | pump_labels
    fixedb = {drv, S("VR_SLIDE"), S("VR_SLIDE") + len(ref_open()), S("VR_BPG"), S("VR_XOUT"),
              S("VR_BS1")}
    lo, end = S("VR_SLIDE"), S("VR_SLIDE_END")
    shadow, how, popped, prev_in = {}, "jump", None, False
    rpump, steps = S("vid_raw_pump"), 0
    cpu.sp = STACK
    cpu.push(RET)
    cpu.hl, cpu.pc = S("nxb_srow_go"), S("nxb_hop6")
    while cpu.pc != RET:
        pc, p = cpu.pc, mc.mmu[6]
        win = 0xC000 <= pc < 0xE000
        if win and not (p == nxb or p == sched and any(a <= pc < b for a, b in code)
                        or p == SCHED_PAGE_B and any(a <= pc < b for a, b in codeb)):
            raise Fail(f"fetch at ${pc:04X} with page {p} at MMU6 (step {steps})")
        if win and (how != "seq" or not prev_in):
            slide = lo <= pc <= end and (end - pc) % 2 == 0
            named = (p == sched and (pc in fixed or slide)
                     or p == SCHED_PAGE_B and pc in fixedb
                     or p == nxb and pc in labels6)
            if not named and (how != "ret" or popped != (pc, p)):
                raise Fail(f"entry at ${pc:04X} with page {p} at MMU6 is not a named entry "
                           f"({how}, step {steps})")
        if pc == rpump:
            seen.setdefault("vid_raw_pump", []).append(p)
        t = traps.get(pc)
        if t is not None and (pc < 0xC000 or pc >= 0xE000 or p == nxb):
            slot = cpu.sp
            t(cpu)
            how, popped, prev_in = "ret", shadow.pop(slot, None), False
            continue
        ctl, op, sp0 = chain_ctl(mc.mem, pc), mc.mem[pc], cpu.sp
        cpu.step()
        steps += 1
        prev_in, how = win, "seq"
        if ctl is not None and cpu.pc != ctl[1]:
            how = ctl[0]
            if how == "call":
                shadow[cpu.sp] = (ctl[1], p)
            elif how == "ret":
                popped = shadow.pop(sp0, None)
        elif op in (0xC5, 0xD5, 0xE5, 0xF5, 0xE3):       # push / ex (sp),hl: not a return
            shadow.pop(cpu.sp, None)
        if steps > 2_000_000:
            raise Fail("the chain did not return")
    mc.sync()
    own = owner_fn(mc)
    readers = {(ph, own(pc, card.pages[i])) for i, (ph, pc) in enumerate(card.log)}
    want = {("crc", "vr_sector_c"), ("crc", "vr_sector_n"), ("wait", "vr_sector_n"),
            ("token", "vr_sector_n"), ("data", "slide"), ("data", "paltrain"),
            ("crc", "column"), ("wait", "column"), ("token", "column"), ("data", "column")}
    got = (seen.get("nxb_sprint"), seen.get("vid_raw_pump"), seen.get("nxb_lc_start"),
           seen.get("nxb_lc_end"), mc.mmu[6], mc.nr.get(0x56), cpu.sp,
           mc.peek("nxb_lrow.pr", 2), mc.peek("nxbLeft", 2))
    if got != ([nxb], [nxb, sched], [nxb], [sched], CHAIN_ENTRY6, CHAIN_ENTRY6, STACK,
               S("nxb_sprint"), 0):
        raise Fail(f"(nxb_sprint, vid_raw_pump, clock start, clock end: MMU6 at each entry; "
                   f"MMU6, NR $56, SP, nxb_lrow.pr, nxbLeft) = {got}")
    npal = sum(1 for i, (ph, pc) in enumerate(card.log) if own(pc, card.pages[i]) == "paltrain")
    if card.pos != len(card.stream) or readers != want or npal != 512:
        raise Fail(f"{len(card.stream) - card.pos} card bytes unread, readers "
                   f"{sorted(readers ^ want)} differ, {npal} palette reads")


BASE_DMA = Path(__file__).resolve().parent / "out" / "vidraw-dma-base"


def base_image(tag=None):
    """(syms, page reader) of a baseline in tests\\out\\vidraw-dma-base: tag (debug, quiet,
    release), default this build's variant."""
    import dma_contract as dc
    if tag is None:
        tag = ("quiet" if "nxbQuietImage" in SYMS else "debug" if "dbgNoBank" in SYMS
               else "release")
    nex, sld = BASE_DMA / f"{tag}.nex", BASE_DMA / f"{tag}.sld"
    for p in (nex, sld):
        if not p.exists():
            raise Fail(f"{p} is missing")
    keep = dc.NEX, dc.SLD
    dc.NEX, dc.SLD = nex, sld
    try:
        syms = dc.read_sld()
        names = ("VID_PAGE", "VID_PAGE2") + (("NXB_PAGE",) if "dbgNoBank" in syms else ())
        pages = {p: dc.read_page(p) for p in (4, 5) + tuple(syms[n][1] for n in names)}
    finally:
        dc.NEX, dc.SLD = keep
    return syms, pages.__getitem__


class LoggedMem(bytearray):
    """A machine's 64K view logging each byte store as (address, the page its slot maps)."""

    def __setitem__(self, k, v):
        if isinstance(k, int):
            self.log.append((k, self.mc.mmu[k >> 13]))
        super().__setitem__(k, v)


def geo_run(syms, pages, geo):
    """nxb_geo_setup on an image, nxbGeo = geo, MMU6 = CHAIN_ENTRY6: (CF, stores off the
    stack, machine, MMU6 at each nxb_geo_body entry)."""
    mc = nxb_machine(syms=syms, pages=pages)
    mapnr(mc, 6, CHAIN_ENTRY6)
    mc.poke("nxbGeo", geo)
    mem = LoggedMem(mc.mem)
    mem.mc, mem.log = mc, []
    mc.mem = mc.cpu.m = mem
    seen, traps = [], {}
    if "nxb_geo_body" in syms:
        def body(c):
            seen.append(mc.mmu[6])
            c.step()
        traps[syms["nxb_geo_body"][1]] = body
    cpu = mc.run(syms["nxb_geo_setup"][1], traps=traps, budget=10_000)
    return cpu.fc, [(a, p) for a, p in mem.log if not STACK - 0x40 <= a < STACK], mc, seen


def geo_relabel(at, addrs, hot, a, what):
    """Baseline hot address a as this image's: the same label (a non-local one first) plus
    the same offset."""
    la = addrs[bisect.bisect_right(addrs, a) - 1]
    names = [n for n in sorted(at[la], key=lambda n: ("." in n, n))
             if SYMS.get(n, (0,))[0] == hot]
    if not names:
        raise Fail(f"{what} at {min(at[la])}+{a - la} has no label on this image's VID_PAGE")
    return S(names[0]) + a - la


def test_geo_hop():
    """nxb_geo_setup is ld hl, nxb_geo_body / jp nxb_hop6; the body and its tables are on
    NXB_PAGE. Each nxbGeo value 0-255 against the baseline image: CF equal; the same hot-page
    stores by label with the same values (a stored word naming a hot label maps through both
    SLDs; none with CF set, none elsewhere); the body entered once with NXB_PAGE at MMU6;
    MMU6 (NR $56 too) and MMU7 on return as on entry."""
    bench_only()
    nxb, hot = S("NXB_PAGE"), S("VID_PAGE")
    off = [n for n in ("nxb_geo_body", "nxbGeoH", "nxbGeoDst") if SYMS.get(n, (0,))[0] != nxb]
    if off:
        raise Fail(f"not NXB_PAGE labels: {', '.join(off)}")
    body, hop = S("nxb_geo_body"), S("nxb_hop6")
    code_is(nxb_machine(), "nxb_geo_setup",
            bytes([0x21, body & 0xFF, body >> 8, 0xC3, hop & 0xFF, hop >> 8]))
    osyms, opages = base_image()
    ohot = osyms["VID_PAGE"][1]
    at = {}
    for n, (p, v) in osyms.items():
        if p == ohot and v >= 0xE000:
            at.setdefault(v, []).append(n)
    addrs = sorted(at)
    valid = 0
    for g in range(256):
        ofc, ost, omc, _ = geo_run(osyms, opages, g)
        nfc, nst, nmc, seen = geo_run(SYMS, None, g)
        if nfc != ofc:
            raise Fail(f"nxbGeo ${g:02X}: CF {nfc}, baseline {ofc}")
        stray = [(a, p) for a, p in ost if p != ohot] + [(a, p) for a, p in nst if p != hot]
        if stray:
            raise Fail(f"nxbGeo ${g:02X}: stores off the hot page (address, page) {stray[:4]}")
        want = {}
        log = [a for a, _ in ost]
        i = 0
        while i < len(log):                 # a word store logs its low byte, then a + 1
            a = log[i]
            what = f"nxbGeo ${g:02X}: baseline store"
            na = geo_relabel(at, addrs, hot, a, what)
            if i + 1 < len(log) and log[i + 1] == a + 1:
                v = omc.mem[a] | omc.mem[a + 1] << 8
                if v >= addrs[0]:
                    v = geo_relabel(at, addrs, hot, v, f"{what} of a word")
                want[na], want[na + 1] = v & 0xFF, v >> 8
                i += 2
            else:
                want[na] = omc.mem[a]
                i += 1
        got = {a: nmc.mem[a] for a, _ in nst}
        if got != want or nfc and got:
            diff = sorted((a, want.get(a), got.get(a)) for a in set(want) | set(got)
                          if want.get(a) != got.get(a))
            raise Fail(f"nxbGeo ${g:02X} (CF {nfc}): {len(got)} hot stores, {len(want)} "
                       f"wanted; (address, wanted, got) {diff[:6]}")
        if (seen, nmc.mmu[6], nmc.nr.get(0x56), nmc.mmu[7]) != ([nxb], CHAIN_ENTRY6,
                                                                CHAIN_ENTRY6, hot):
            raise Fail(f"nxbGeo ${g:02X}: (MMU6 at the body, MMU6, NR $56, MMU7) = "
                       f"{(seen, nmc.mmu[6], nmc.nr.get(0x56), nmc.mmu[7])}")
        valid += not nfc
    if valid != 21:
        raise Fail(f"{valid} valid geometry codes, expected 21")


def test_rw_histlog():
    """The log step's pass: after the header and the (here empty) rows, one line per saved
    histogram, "#HIST <tag>" and 17 words, as hist.py and parse.parse_hist read it."""
    bench_only()
    import re
    mc = nxb_machine()
    mapnr(mc, 6, S("NXB_PAGE"))
    mc.mem[0x4000:0x4000 + 2 * 80] = b"\x20" * 160
    mc.poke("tmCols", 80)
    mc.poke16("nxbLogFc", 0x1234)
    line0 = S("nxbLogLine")
    lines = []
    io = 0x0100

    def put(c):
        lines.append(bytes(mc.mem[line0:line0 + c.bc]).decode("ascii"))

    def cell(c):
        c.hl = 0x4000
    traps = {io: ret_trap(put), S("tm_cell_addr"): ret_trap(cell)}
    bins = {"RHST": [0x07F8, 5, 2] + [0] * 13 + [0xABCD], "RH39": [0x0700, 0xF0] + [0] * 15,
            "AHST": [0] * 16 + [1], "AH39": [1] * 17}
    sav, ln = S("nxbHistSav"), S("NXB_HIST_LEN")
    if S("NXB_HIST_MAX") != len(bins):
        raise Fail(f"NXB_HIST_MAX {S('NXB_HIST_MAX')}, expected {len(bins)}")
    for i, (t, b) in enumerate(bins.items()):
        mc.mem[sav + i * ln:sav + (i + 1) * ln] = t.encode() + b"".join(le(n) for n in b)
    for n in (4, 3, 2, 1, 0):
        mc.poke("nxbHistN", n)
        lines.clear()
        mc.run("nxb_log_pass", traps=traps, hl=io)
        want = ["#NXB 1234\r\n"] + ["#HIST " + t + "".join(f" {x:04X}" for x in b) + "\r\n"
                                    for t, b in list(bins.items())[:n]]
        if lines != want:
            raise Fail(f"nxbHistN {n}: lines {lines}, expected {want}")
    for t, b in bins.items():
        text = "#HIST " + t + "".join(f" {x:04X}" for x in b) + "\r\n"
        m = re.fullmatch(r"#HIST ([A-Z0-9]{4})((?: [0-9A-F]{4})+)\s*", text)
        if not m or [int(x, 16) for x in m.group(2).split()] != b:
            raise Fail(f"hist.py's pattern does not read {text!r}")
        if len(text) > S("nxbLogRd") - line0:
            raise Fail(f"a #HIST line ({len(text)} B) overruns nxbLogLine")


# --------------------------------------------------------------------------- play log

class Esx:
    """The esxDOS wrappers the log step calls, trapped over a dict of files: F_OPEN (mode bit
    3 creates), F_FSTAT (+7 the size), F_SEEK (IXL 0 only), F_WRITE, F_READ, F_CLOSE. calls
    logs every entry."""

    def __init__(self, mc, files=None):
        self.mc, self.calls, self.open = mc, [], {}
        self.files = {k: bytearray(v) for k, v in (files or {}).items()}

    def traps(self):
        t = {"esx_getsetdrv": self.drv, "esx_fopen": self.fopen, "esx_fstat": self.fstat,
             "esx_fseek": self.fseek, "esx_fwrite": self.fwrite, "esx_fread": self.fread,
             "esx_fclose": self.fclose}
        return {S(k): ret_trap(f) for k, f in t.items()}

    def drv(self, c):
        self.calls.append(("drv",))
        c.a, c.fc = ord("C"), 0

    def fopen(self, c):
        m = self.mc.mem
        name = bytes(m[c.ix:m.index(0, c.ix)]).decode("ascii")
        self.calls.append(("fopen", name, c.b))
        if c.b & 0x08:
            self.files.setdefault(name, bytearray())
        elif name not in self.files:
            c.a, c.fc = 5, 1
            return
        h = 0x40 + len(self.calls)
        self.open[h] = [name, 0]
        c.a, c.fc = h, 0

    def _f(self, c, what):
        if c.a not in self.open:
            raise Fail(f"{what} on handle ${c.a:02X}, not open")
        f = self.open[c.a]
        self.calls.append((what, f[0]))
        return f

    def fstat(self, c):
        f = self._f(c, "fstat")
        self.mc.mem[c.ix:c.ix + 11] = bytes(7) + len(self.files[f[0]]).to_bytes(4, "little")
        c.fc = 0

    def fseek(self, c):
        f = self._f(c, "fseek")
        if c.ix & 0xFF:
            raise Fail(f"F_SEEK mode {c.ix & 0xFF}, expected 0 (from the start)")
        f[1] = c.bc << 16 | c.de
        c.fc = 0

    def fwrite(self, c):
        f = self._f(c, "fwrite")
        data = bytes(self.mc.mem[c.ix:c.ix + c.bc])
        self.files[f[0]][f[1]:f[1] + len(data)] = data
        f[1] += len(data)
        c.fc = 0

    def fread(self, c):
        f = self._f(c, "fread")
        data = self.files[f[0]][f[1]:f[1] + c.bc]
        self.mc.mem[c.ix:c.ix + len(data)] = data
        f[1] += len(data)
        c.bc, c.fc = len(data), 0

    def fclose(self, c):
        self._f(c, "fclose")
        del self.open[c.a]
        c.fc = 0


def no_esx():
    out = {}
    for n in ("esx_getsetdrv", "esx_fopen", "esx_fstat", "esx_fseek", "esx_fwrite", "esx_fread",
              "esx_fclose"):
        out.update(forbid(n))
    return out


PLAY_ROWS = {23: "VID FMT?", 24: " FRM=00FA/00FA ERR=00 OP=00 POS=000000 PASS=01",
             25: "RING   =0000/0000/00 FILL=0001 SNAP=00",
             26: "PLAY   =01EE NOM=01F4 CHK=0051D039",
             27: "LATE   =0000 MAXL=0000 URUN=0000 RUNS=01"}


def play_machine(rows=None):
    """nxb_machine with an 80-column tilemap: row r holds "ROW rr" and a tail (attribute
    $11) unless rows gives its text; dbg output to the tilemap."""
    mc = nxb_machine()
    mc.poke("tmCols", 80)
    mc.poke("dbgTilemap", 1)
    base = S("TM_MAP")
    for r in range(32):
        text = (rows or {}).get(r, f"ROW {r:02d} " + chr(65 + r % 26) * (r % 9))
        mc.mem[base + r * 160:base + (r + 1) * 160] = b"".join(
            bytes([ord(ch), 0x11]) for ch in text.ljust(80))
    return mc


def tm_bytes(mc, row):
    base = S("TM_MAP") + row * 160
    return bytes(mc.mem[base:base + 160])


def tm_text(mc, row):
    return tm_bytes(mc, row)[::2].decode("latin-1").rstrip(" ")


def test_play_log():
    """Mode 16 through nxb_entry: NXPLAY.TXT opened twice (append, read back), the capture
    appended after what the file held - "#PLAY ccc pp ffff" (flag 140 in decimal,
    vidPoolAtOpen, frameCounter), rows 23-27 trimmed, CRLF ends, nothing from rows 0-22 or
    28-31, no #HIST line with nxbHistN 2 - every handle closed, rows 0-30 unchanged, LOG OK on
    row 31. Then mode 15 on the same screen writes NXBENCH.TXT: every row, both #HIST lines."""
    bench_only()
    fl, hdr = S("flags"), "#PLAY 074 50 1234"
    for clip, pool, fc, want_hdr in ((74, 0x50, 0x1234, hdr), (0, 0, 0, "#PLAY 000 00 0000"),
                                     (9, 0x7F, 0xFFFF, "#PLAY 009 7F FFFF"),
                                     (100, 0xA0, 0x0102, "#PLAY 100 A0 0102"),
                                     (255, 0xFF, 0x8000, "#PLAY 255 FF 8000")):
        mc = play_machine(PLAY_ROWS)
        mc.mem[fl + 140] = clip
        mc.poke("vidPoolAtOpen", pool)
        mc.poke16("frameCounter", fc)
        mc.poke("nxbHistN", 2)
        prior = b"#PLAY 001 4F 0001\r\nVID FILE?\r\n"
        esx = Esx(mc, {"NXPLAY.TXT": prior})
        before = [tm_bytes(mc, r) for r in range(32)]
        mc.mem[fl + 250] = S("NXB_MODE_PLAY")
        mc.run("nxb_entry", traps=esx.traps())
        want = prior + (want_hdr + "\r\n").encode() + b"".join(
            PLAY_ROWS[r].rstrip(" ").encode() + b"\r\n" for r in range(23, 28))
        got = bytes(esx.files.get("NXPLAY.TXT", b""))
        opens = [x for x in esx.calls if x[0] == "fopen"]
        if got != want or set(esx.files) != {"NXPLAY.TXT"}:
            raise Fail(f"flag 140 = {clip}: files {sorted(esx.files)}, NXPLAY.TXT {got!r}, "
                       f"expected {want!r}")
        if opens != [("fopen", "NXPLAY.TXT", S("NXB_LOG_WMODE")),
                     ("fopen", "NXPLAY.TXT", S("ESX_MODE_READ"))] or esx.open:
            raise Fail(f"flag 140 = {clip}: opens {opens}, still open {esx.open}")
        changed = [r for r in range(31) if tm_bytes(mc, r) != before[r]]
        if tm_text(mc, 31) != "LOG OK" or changed or mc.mem[fl + 250]:
            raise Fail(f"flag 140 = {clip}: row 31 {tm_text(mc, 31)!r}, rows changed "
                       f"{changed}, flags+250 = {mc.mem[fl + 250]}")
    # mode 15 after it: NXBENCH.TXT gets every row and the two saved histograms
    sav, ln = S("nxbHistSav"), S("NXB_HIST_LEN")
    o = S("NXB_PAGE") * SLOT + sav - S("DATA_WINDOW")
    hist = [("RHST", list(range(1, 18))), ("AHST", [0x1000 + k for k in range(17)])]
    for i, (t, b) in enumerate(hist):
        mc.phys[o + i * ln:o + (i + 1) * ln] = t.encode() + b"".join(le(n) for n in b)
    screen = [tm_text(mc, r) for r in range(32)]
    mc.mem[fl + 250] = S("NXB_MODE_LOG")
    mc.run("nxb_entry", traps=esx.traps())
    want = f"#NXB {fc:04X}\r\n" + "".join(s + "\r\n" for s in screen if s) + "".join(
        "#HIST " + t + "".join(f" {x:04X}" for x in b) + "\r\n" for t, b in hist)
    got = bytes(esx.files.get("NXBENCH.TXT", b"")).decode("latin-1")
    if got != want or tm_text(mc, 31) != "LOG OK":
        raise Fail(f"mode 15 after 16: NXBENCH.TXT {got!r}, expected {want!r}; row 31 "
                   f"{tm_text(mc, 31)!r}")


def test_play_clr():
    """Mode 17 through nxb_entry: rows 23-27 and 31 blank (spaces at TM_ATTR_DEFAULT over
    tmCols), every other tilemap byte unchanged (rows 22 and 28 hold text), no esxDOS call."""
    bench_only()
    fl = S("flags")
    mc = play_machine({31: "LOG OK"})
    before = [tm_bytes(mc, r) for r in range(32)]
    mc.mem[fl + 250] = S("NXB_MODE_CLR")
    mc.run("nxb_entry", traps=no_esx())
    blank = bytes([S("GLYPH_SPACE"), S("TM_ATTR_DEFAULT")]) * 80
    for r in range(32):
        want = blank if r in (23, 24, 25, 26, 27, 31) else before[r]
        if tm_bytes(mc, r) != want:
            raise Fail(f"mode 17: row {r} reads {tm_text(mc, r)!r} "
                       f"{'not blank' if want == blank else 'changed'}")
    if mc.mem[fl + 250]:
        raise Fail(f"mode 17: flags+250 = {mc.mem[fl + 250]}, not cleared")


def test_play_nofile():
    """GO on a missing clip: mode 17 sets vidPoolAtOpen to $FF (no pool figure), and mode 16
    with no open between logs "#PLAY 074 FF 1234" and the refusal row."""
    bench_only()
    fl = S("flags")
    mc = play_machine()
    mc.mem[fl + 140] = 74
    mc.poke("vidPoolAtOpen", 0x50)
    mc.poke16("frameCounter", 0x1234)
    mc.mem[fl + 250] = S("NXB_MODE_CLR")
    mc.run("nxb_entry", traps=no_esx())
    if mc.peek("vidPoolAtOpen") != 0xFF:
        raise Fail(f"mode 17: vidPoolAtOpen ${mc.peek('vidPoolAtOpen'):02X}, expected $FF")
    tm = S("TM_MAP") + 23 * 160
    mc.mem[tm:tm + 18] = b"".join(bytes([ord(ch), 0]) for ch in "VID FILE?")
    esx = Esx(mc)
    mc.mem[fl + 250] = S("NXB_MODE_PLAY")
    mc.run("nxb_entry", traps=esx.traps())
    got = bytes(esx.files.get("NXPLAY.TXT", b""))
    if got != b"#PLAY 074 FF 1234\r\nVID FILE?\r\n" or tm_text(mc, 31) != "LOG OK":
        raise Fail(f"mode 16 after 17: NXPLAY.TXT {got!r}, row 31 {tm_text(mc, 31)!r}")


def test_fail_print():
    """The DEBUG open-failure prints: vid_play_missing_print (VID FILE?) and vid_open_fail_print
    with B = 1..4 (VID FMT?, VID NOBANK2, VID SIZE?, VID FRAG?) on row VID_FAIL_ROW from column
    0 at TM_ATTR_DEFAULT, nothing else on the tilemap changed. The body and its strings are on
    NXB_PAGE, entered once with NXB_PAGE at MMU6 from a cold stub of at most 20 bytes; MMU6
    (NR $56 too) and MMU7 on return as on entry."""
    bench_only()
    nxb, cold = S("NXB_PAGE"), S("VID_PAGE2")
    names = ("vid_fail_body", "vid_fail_puts", "msgVidMissing", "msgVidNoBank2", "msgVidBadFmt",
             "msgVidTooBig", "msgVidFrag")
    off = [n for n in names if SYMS.get(n, (0,))[0] != nxb]
    stub = [n for n in ("vid_play_missing_print", "vid_open_fail_print")
            if SYMS.get(n, (0,))[0] != cold]
    if off or stub:
        raise Fail(f"not NXB_PAGE labels: {off}; not VID_PAGE2 labels: {stub}")
    after = min(v for k, (pg, v) in SYMS.items()
                if pg == cold and v > S("vid_open_fail_print") and "." not in k)
    if after - S("vid_play_missing_print") > 20:
        raise Fail(f"the cold stub is {after - S('vid_play_missing_print')} bytes")
    row, attr = S("VID_FAIL_ROW"), S("TM_ATTR_DEFAULT")
    for entry, b, text in (("vid_play_missing_print", 0x77, "VID FILE?"),
                           ("vid_open_fail_print", 1, "VID FMT?"),
                           ("vid_open_fail_print", 2, "VID NOBANK2"),
                           ("vid_open_fail_print", 3, "VID SIZE?"),
                           ("vid_open_fail_print", 4, "VID FRAG?")):
        mc = play_machine({row: ""})
        mapnr(mc, 7, cold)
        mapnr(mc, 6, CHAIN_ENTRY6)
        before = [tm_bytes(mc, r) for r in range(32)]
        seen = []
        mc.run(entry, traps={S("vid_fail_body"): lambda c: seen.append(mc.mmu[6]) or c.step()},
               b=b)
        want = b"".join(bytes([ord(ch), attr]) for ch in text) + before[row][2 * len(text):]
        changed = [r for r in range(32) if r != row and tm_bytes(mc, r) != before[r]]
        got = (seen, mc.mmu[6], mc.nr.get(0x56), mc.mmu[7], mc.cpu.sp)
        if tm_bytes(mc, row) != want or changed or got != ([nxb], CHAIN_ENTRY6, CHAIN_ENTRY6,
                                                           cold, STACK):
            raise Fail(f"{entry} B={b}: row {row} {tm_text(mc, row)!r}, expected {text!r}; rows "
                       f"changed {changed}; (MMU6 at the body, MMU6, NR $56, MMU7, SP) = {got}")


def test_entry_modes():
    """nxb_entry: flags+250 = 15, 16, 17 reach nxb_log with NXB_PAGE at MMU6 and nxbMode the
    mode, 14 reaches .arm, none enters the standalone path; 18 and 255 reach nxb_log and show
    LOG ERR 01 on row 31 with no esxDOS call, rows 0-30 unchanged."""
    bench_only()
    fl, nxb = S("flags"), S("NXB_PAGE")
    for mode in (14, 15, 16, 17):
        mc = play_machine()
        mc.mem[fl + 250] = mode
        seen = []
        traps = {S("nxb_log"): ret_trap(lambda c: seen.append(("log", mc.mmu[6],
                                                                mc.peek("nxbMode")))),
                 S("nxb_entry.arm"): ret_trap(lambda c: seen.append(("arm",))),
                 **forbid("nxb_blank"), **no_esx()}
        mc.run("nxb_entry", traps=traps)
        want = [("arm",)] if mode == 14 else [("log", nxb, mode)]
        if seen != want:
            raise Fail(f"mode {mode}: reached {seen}, expected {want}")
    for mode in (18, 255):
        mc = play_machine()
        before = [tm_bytes(mc, r) for r in range(31)]
        mc.mem[fl + 250] = mode
        seen = []

        def watch(c):
            seen.append(mc.mmu[6])
            c.step()
        mc.run("nxb_entry", traps={S("nxb_log"): watch, **forbid("nxb_blank"), **no_esx()})
        changed = [r for r in range(31) if tm_bytes(mc, r) != before[r]]
        if seen != [nxb] or tm_text(mc, 31) != "LOG ERR 01" or changed:
            raise Fail(f"mode {mode}: nxb_log entries {seen}, row 31 {tm_text(mc, 31)!r}, "
                       f"rows changed {changed}")


# --------------------------------------------------------------------------- frame loop

class LoopMachine(RawMachine):
    """Ports the frame loop touches beyond the reader: $FE (no key down), CTC 0 (logged; the
    time constant after the control word arms the modelled handler), the DAC parks."""

    def __init__(self, syms):
        super().__init__(syms)
        self.ctc, self.armed = [], False

    def port_in(self, port):
        if port & 0xFF == 0xFE:
            return 0xFF
        return super().port_in(port)

    def port_out(self, port, v):
        if port == S("AUD_CTC_PORT"):
            self.armed = v != S("AUD_CTC_RESET") and self.ctc[-1:] == [S("AUD_CTC_CW16")]
            self.ctc.append(v)
        elif port & 0xFF in (DAC_L, DAC_R, DAC_M, S("DAC_PORT") & 0xFF):
            pass
        else:
            super().port_out(port, v)


def loop_session(real, frames=2, waits=1):
    """vid_run from the audio-0 preload (ld (vidDecSp),sp before .ixp1) through `frames`
    frame loop iterations, 256x192 mono raw, cells as a raw direct open stages them, the
    card serving frame sections laid out as the encoder writes them (frame 0 carries the
    palette sector). The mono handler is modelled as HL' += 1 per 1792 T (15625 Hz at
    28 MHz) while interrupts are on. Returns (machine, card, events, stop reason)."""
    code, w, h = 0, 256, 192
    x0, sec = geom(code, w, h)
    pad = (real // 512 + 1) * 512
    mc = LoopMachine(SYMS)
    patch_session(mc, 1, 1)
    if build_sched(mc, code, w, h).fc:
        raise Fail("vid_raw_sched_build set CF")
    mc.map(7, S("VID_PAGE"))
    mc.map(6, 12)
    snd = [bytes((f * 41 + i * 7 + 1) & 0x7F for i in range(real)) for f in range(frames + 1)]
    pal = bytes((i * 13 + 5) & 255 for i in range(512))
    data = []
    for f in range(frames + 1):
        tag = 1 if f == 0 else 0
        data += blocks(snd[f] + b"\x80" * (pad - real - 1) + bytes([tag]))
        if f < frames:
            data += ([pal] if tag else []) + blocks(pixels(w * h))
    total = 1 + len(data) + 1000
    need = sec + 1 + pad // 512 + 1                       # vid_strm_validate: cap + apad + 1
    for name, v in (("vidRawSchedPage", SCHED_PAGE), ("vidRawSec", sec), ("vidRawCap", sec + 1),
                    ("vidRawTag", 0), ("vidRawPage0", x0 >> 5), ("vidRawH0", 0x40 + (x0 & 31)),
                    ("l2BackBank", BACK_BANK), ("l2FrontBank", 33), ("vidStreaming", 0),
                    ("vidDsCrcDue", 0), ("vidDsFrmBlk", 0), ("vidDsBound", need),
                    ("vidApadBlk", pad // 512), ("vidLoopMode", 0), ("vidStrmEntryCnt", 1),
                    ("vidStrmEntryIdx", 1), ("vidWinOpenH", 1), ("vidPalCtrl", 0),
                    ("vidPalPending", 0), ("vidInSpan", 0), ("vidCtcTc", 112), ("vidDstPages", 6)):
        mc.poke(name, v)
    for name, v in (("vidABytes", real), ("vidABytesPad", pad), ("vidFrames", 153),
                    ("vidFramesLeft", 153), ("vidAudFeedRem", 0), ("vidDsAudBlkRem", 0),
                    ("vidStrmRunBlkH", total - 1)):
        mc.poke16(name, v)
    mc.poke("vidStrmRemainBlk", (total - 1).to_bytes(3, "little"))
    for n in ("vidRlDiv", "vidRlSpinDiv"):
        if n in SYMS:
            mc.poke(n, 1)
    base, ring = S("vidAudBuf"), S("NXV_AUD_RING")
    mc.mem[base:base + ring] = bytes([0xEE]) * ring
    card = Card(data, waits=waits)
    mc.set_card(card)
    cpu = mc.cpu
    start = S("vid_run.ixp1") - 4
    if bytes(mc.mem[start:start + 2]) != b"\xED\x73":
        raise Fail("the instruction before vid_run.ixp1 is not ld (vidDecSp),sp")
    cpu.sp = STACK
    cpu.push(RET)
    cpu.pc, cpu.iff = start, 1
    ev, why = [], None
    loop, phase = S("vid_run.frameloop"), S("vid_run.phase")
    # sopen: a sound sector's counted open (vr_sector_c, or its .nocrc not fallen into);
    # section: vid_raw_pump entered with a feed staged
    crc0, nocrc, rpump = S("vr_sector_c"), S("vr_sector_c.nocrc"), S("vid_raw_pump")
    watch = {crc0: "sopen", nocrc: "sopen", rpump: "section", S("vid_raw_frame"): "frame",
             loop: "loop"}
    stops = {S("vid_dec_abort"): "vid_dec_abort", S("vid_dec_abort_pos"): "vid_dec_abort_pos",
             S("vid_run.restore"): "vid_run.restore"}
    acc, loops, budget, prev = 0, 0, 20_000_000, 0
    while True:
        pc = cpu.pc
        if pc in stops:
            why = (stops[pc], cpu.a)
            break
        if pc in watch and not (pc == nocrc and crc0 <= prev < nocrc) \
                and not (pc == rpump and mc.peek("vidAudFeedRem", 2) == 0):
            ev.append((watch[pc], card.pos, mc.peek("vidDsFrmBlk")))
            if pc == loop:
                loops += 1
                if loops > frames:
                    break
        if pc == phase:                                   # the field tick the arm waits for
            fc = S("frameCounter")
            mc.mem[fc] = (mc.mem[fc] + 1) & 0xFF
        prev = pc
        try:
            t = tstep(mc)
        except Fail as e:
            if "no T entry" not in str(e):
                raise
            cpu.step()                                    # NRGET (ED C7): timing not asserted
            t = 8
        if mc.armed:
            acc += t
            while acc >= 1792 and cpu.iff:
                acc -= 1792
                set_alt_hl(cpu, base if alt_hl(cpu) + 1 == base + ring else alt_hl(cpu) + 1)
        budget -= 1
        if budget <= 0:
            why = ("budget", 0)
            break
    return mc, card, ev, why, snd


def test_loop_sound_boundary():
    """The preload and two frame loop iterations of a 256x192 mono raw clip, run on the
    emitted vid_run: 1024 sound bytes (clip 074: the tag alone in a third sector, opened by
    the pump) against 625 (two sectors). No abort, every card byte read in order, three
    sections read by the pump, each frame's sound in the ring, the tag of the frame staged
    last kept."""
    for real in (1024, 625):
        mc, card, ev, why, snd = loop_session(real)
        what = f"{real} sound bytes"
        if why is not None:
            trail = [e for e in ev if e[0] != "loop"][-4:]
            raise Fail(f"{what}: {why[0]} reached with A=${why[1]:02X} at card read "
                       f"{card.pos}; last events {trail}")
        pad = (real // 512 + 1) * 512
        n = 3 * pad // 512 + 1 + 2 * 96                   # sound x3, palette, pixels x2
        want_pos = n * 516 - 2                             # CRC 2 (not before the first), $FF, token, 512
        got = (card.pos, mc.peek("vidRawTag"), mc.peek("vidAudFeedRem", 2),
               [e[0] for e in ev].count("section"))
        if got != (want_pos, 0, 0, 3):
            raise Fail(f"{what}: (card reads, tag, feedRem, sections) = {got}, expected "
                       f"({want_pos}, 0, 0, 3)")
        opens = [e for e in ev if e[0] == "sopen"]
        if len(opens) != 3 * pad // 512:
            raise Fail(f"{what}: {len(opens)} sound sector opens, expected {3 * pad // 512} "
                       f"({pad // 512} a frame)")
        if max(e[2] for e in ev) > mc.peek("vidDsBound"):
            raise Fail(f"{what}: vidDsFrmBlk passed vidDsBound {mc.peek('vidDsBound')}")
        base = S("vidAudBuf")
        for f in range(3):
            got = bytes(mc.mem[base + f * real:base + (f + 1) * real])
            if got != snd[f]:
                raise Fail(f"{what}: frame {f} sound not at ring +${f * real:04X}")


TESTS = [test_sched_pixels, test_sched_reads, test_sched_shape, test_sched_pad,
         test_sched_limit, test_sector_runwalk, test_sector_badtoken, test_sector_n,
         test_sector_fresh, test_sector_walkfault, test_sector_polls, test_sector_timeout,
         test_sector_gaps, test_poll_pad, test_sector_t, test_sector_joins, test_page_ends,
         test_sched_regs, test_frame_remain,
         test_frame_palette, test_paltrain, test_pal_t, test_frame_fit, test_frame_runwalk,
         test_frame_zero, test_entry_stale, test_frame_boundaries, test_frame_cross_gaps,
         test_frame_end_walk, test_frame_rewind, test_frame_abort,
         test_fast_bytes, test_xstub_late, test_fast_pixels, test_disp_cross, test_open_polls,
         test_open_gaps, test_fast_t, test_variant_rule, test_train_gaps, test_train_regs,
         test_fast_frame_t,
         test_pump_cells, test_pump_boundary, test_pump_wrap, test_pump_room, test_pump_runwalk,
         test_pump_faults, test_pump_t, test_pump_gaps,
         test_vec_patch, test_vec_sites, test_raw_stage,
         test_isr_stereo, test_isr_mono, test_isr_t, test_isr_static, test_rd_bytes,
         test_patch_sites_default, test_patch_roundtrip, test_patched_reads, test_isr_choice,
         test_vec_install, test_vec_restore,
         test_dbg_counters, test_dbg_calls, test_rw_shapes, test_rw_feed, test_rw_route,
         test_rw_card, test_rw_hist, test_rw_arms, test_vec_bench, test_rw_kinds, test_rw_histlog,
         test_play_log, test_play_clr, test_play_nofile, test_fail_print, test_entry_modes,
         test_rw_harness, test_rw_card_c, test_rw_chain, test_geo_hop, test_loop_sound_boundary]


def main():
    import dma_contract
    if not dma_contract.NEX.exists() or not dma_contract.SLD.exists():
        print("vidraw_contract: FAIL - no build\\nextdaad.nex / .sld (run .\\build.ps1 first)")
        return 1
    SYMS.update(read_sld())
    print("vidraw_contract: %s build" % ("DEBUG" if "dbgNoBank" in SYMS else "Release"))
    passed = failed = skipped = 0
    for t in TESTS:
        try:
            t()
        except Skip as exc:
            skipped += 1
            print(f"  skip {t.__name__}: {exc}")
        except (Fail, Stop) as exc:
            failed += 1
            print(f"  FAIL {t.__name__}: {exc}")
        except Exception as exc:                        # a model or harness fault
            failed += 1
            print(f"  FAIL {t.__name__}: {type(exc).__name__}: {exc}")
        else:
            passed += 1
            print(f"  ok   {t.__name__}")
    print(f"vidraw_contract: {passed} passed, {failed} failed"
          + (f", {skipped} skipped" if skipped else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
