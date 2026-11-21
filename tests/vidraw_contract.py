#!/usr/bin/env python3
"""Host execution of the raw direct video reader (src/video.asm).

Runs the EMITTED bytes of build\\nextdaad.nex on the tests\\ddma_contract.py Z80 model, with
the MMU applied and port $EB fed by a model of the SD card's CMD18 stream: the cold schedule
generator (vid_raw_sched_build) and hot-cell staging (vid_raw_stage), the raw frame decode
(vid_raw_frame) with its sector opens, surface page step, palette sector and frame tag
(vr_sector, vr_sector_n, vr_page, vid_raw_pal, vid_raw_apad), the per-session operand patches
(vid_stage_common.vec), the raw sound handlers on the alternate set (video_ctc_isr_raw_st,
video_ctc_isr_raw_mono), the play pointer helpers (vid_raw_rd_hl, vid_raw_rd_de, vid_raw_prime)
and the handler choice in vid_run_l2setup_body. DEBUG images only: the frame loop's LATE and
URUN counters (vid_dbg_late, vid_dbg_urun) and their call sites, and the RW1 bench session
(the mode 5 route through nxb_sess / nxb_ds_rows, nxb_rw_feed, the card rows' bodies and the
binned token wait, the arm kinds and DISARM, the log step's #HIST lines); each is skipped
with a note where it is not assembled.

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
SCHED_PAGE = 100            # the schedule bank's page (ring bank 50)
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
EXTRA = [(1, 320, 256), (1, 4, 1), (1, 320, 191), (0, 256, 1)]

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
    before it (or crc_first), `waits` x $FF, the token, then 512 data bytes. open_data:
    the tail of a sector that is already open (served first, then CRC before the next).
    Every read is logged with its phase and the reading instruction's address."""

    def __init__(self, sectors=(), waits=0, crc_first=False, token=0xFE, open_data=None):
        self.stream, self.phase = bytearray(), []
        prior = crc_first
        if open_data is not None:
            self._add(open_data, "data")
            prior = True
        for blk in sectors:
            if len(blk) != 512:
                raise Fail("card sector is not 512 bytes")
            if prior:
                self._add(b"\xC1\xC2", "crc")
            self._add(b"\xFF" * waits, "wait")
            self._add(bytes([token]), "token")
            self._add(blk, "data")
            prior = True
        self.pos = 0
        self.log = []
        self.cpu = None

    def _add(self, bs, ph):
        self.stream += bytes(bs)
        self.phase += [ph] * len(bs)

    def read(self):
        if self.pos >= len(self.stream):
            raise Fail(f"card read past the end of the stream at ${self.cpu.at:04X}")
        v = self.stream[self.pos]
        self.log.append((self.phase[self.pos], self.cpu.at))
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


EXT = {0xDB: _in_a_n, 0xD3: _out_n_a, 0xD9: _exx, 0x08: _ex_af, 0xF3: _di, 0xFB: _ei,
       0xE3: _ex_sp_hl}
ED_EXT = {0xA2: _ini, 0xA0: _ldi, 0x4D: _reti, 0x45: _reti, 0x23: _swapnib}
for _r in range(8):
    ED_EXT[0x40 | _r << 3] = _in_r_c(_r)
    ED_EXT[0x41 | _r << 3] = _out_c_r(_r)


class RawCPU(CPU):
    """ddma_contract's model plus the port, alternate-set and interrupt opcodes. IX and IY
    are held as values only: no DD/FD opcode is modelled, so code that touches them fails."""

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

    def __init__(self, syms):
        self.syms = syms
        self.phys = bytearray(PHYS_PAGES * SLOT)
        for p in (4, 5, S("VID_PAGE"), S("VID_PAGE2")):
            self.phys[p * SLOT:(p + 1) * SLOT] = read_page(p)
        self.mem = bytearray(0x10000)
        self.mmu = [0, 1, 10, 11, 4, 5, 12, S("VID_PAGE")]
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
                    ("vidTokPolls", 2), ("vidTokCalls", 2)):
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


def run_frame(mc, code, w, h, tag=0, waits=1, crc_due=0, pad=0, pal=None, remain=0x012345):
    """Build the schedule, play one frame, check the surface and every other write."""
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
    cpu = mc.run("vid_raw_frame", traps=aborts())
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


def parse_sched(mc):
    """[(kind, value, addr)] from VR_SCHED to its ret; kind: read (value n), sector,
    sectorn (vr_sector_n), page, colend, ldhl (value operand), ret."""
    base = SCHED_PAGE * SLOT - S("VR_SLIDE")
    ph = mc.phys
    a, out = S("VR_SCHED"), []
    end, slide_end = S("VR_SCHED_LIMIT"), S("VR_SLIDE_END")
    while True:
        if a + 3 > end:
            raise Fail(f"schedule runs to ${a:04X}, past VR_SCHED_LIMIT")
        b, v = ph[base + a], ph[base + a + 1] | ph[base + a + 2] << 8
        if b == 0xCD:
            if v == S("vr_sector"):
                out.append(("sector", v, a))
            elif v == S("vr_sector_n"):
                out.append(("sectorn", v, a))
            elif v == S("vr_page"):
                out.append(("page", v, a))
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
            raise Fail(f"schedule byte ${b:02X} at ${a:04X}")


def owner_fn(mc):
    """Map an instruction address to the routine holding it (or 'slide')."""
    hot = S("VID_PAGE")
    labels = sorted((v, n) for n, (p, v) in SYMS.items()
                    if p == hot and "." not in n and 0xE000 <= v < 0x10000)
    addrs = [v for v, _ in labels]
    lo, hi = S("VR_SLIDE"), S("VR_SLIDE_END")

    def owner(pc):
        if lo <= pc < hi:
            return "slide"
        i = bisect.bisect_right(addrs, pc) - 1
        return labels[i][1] if i >= 0 else "?"
    return owner


ALLOWED = {"crc": {"vr_sector", "vr_sector_n"}, "wait": {"vid_sd_tok_h"},
           "token": {"vid_sd_tok_h"},
           "data": {"slide", "vid_raw_pal", "vid_ds_pad", "vid_raw_apad"}}


def check_log(mc, card, what):
    owner = owner_fn(mc)
    for i, (ph, pc) in enumerate(card.log):
        who = owner(pc)
        if who not in ALLOWED[ph]:
            raise Fail(f"{what}: card read {i} ({ph}) by {who} at ${pc:04X}")


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
    mc = RawMachine(SYMS)
    cpu = build_sched(mc, 1, 320, 192)
    if cpu.fc:
        raise Fail("320x192: CF set")
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
    if sum(v for k, v, _ in items if k == "read") != 320 * 192:
        raise Fail("320x192: the reads do not add up to the picture")
    build_sched(mc, 0, 256, 192)
    items, _ = parse_sched(mc)
    kinds = [k for k, _, _ in items]
    reads = [v for k, v, _ in items if k == "read"]
    if (kinds.count("sector"), kinds.count("sectorn"), len(reads), set(reads),
            kinds.count("page"), kinds.count("colend")) != (1, 95, 96, {512}, 5, 0):
        raise Fail(f"256x192 schedule: {kinds.count('sector')} + {kinds.count('sectorn')} "
                   f"sector, {len(reads)} reads {sorted(set(reads))}, "
                   f"{kinds.count('page')} page, {kinds.count('colend')} colend")
    if kinds[0] != "sector" or kinds[-1] != "ret":
        raise Fail("256x192: the schedule does not open with vr_sector and end with ret")


def test_sched_pad():
    mc = RawMachine(SYMS)
    build_sched(mc, 1, 280, 224)
    _, end = parse_sched(mc)
    base = SCHED_PAGE * SLOT - S("VR_SLIDE")
    tail = bytes(mc.phys[base + end - 7:base + end])
    scr, rd = S("VR_SCRATCH"), S("VR_SLIDE_END") - 512
    want = bytes([0x21, scr & 255, scr >> 8, 0xCD, rd & 255, rd >> 8, 0xC9])
    if tail != want:
        raise Fail(f"280x224 schedule ends {tail.hex(' ')}, expected {want.hex(' ')}")
    mc = RawMachine(SYMS)
    run_frame(mc, 1, 280, 224, pad=0xAA)
    o = SCHED_PAGE * SLOT + scr - S("VR_SLIDE")
    expect(mc.phys[o:o + 256], b"\xAA" * 256, "280x224 pad in VR_SCRATCH")


def test_sched_limit():
    mc = RawMachine(SYMS)
    top, at = 0, None
    for h in (1, 2, 191, 255):
        for w in range(4, 321, 4):
            cpu = build_sched(mc, 1, w, h)
            if cpu.fc:
                raise Fail(f"1,{w}x{h}: CF set for a legal geometry")
            items, end = parse_sched(mc)
            if sum(v for k, v, _ in items if k == "read") != w * h + (-w * h) % 512:
                raise Fail(f"1,{w}x{h}: the reads do not add up to the sectors")
            if end > top:
                top, at = end, (w, h)
    print(f"  test_sched_limit: largest schedule end ${top:04X} ({at[0]}x{at[1]}), "
          f"limit ${S('VR_SCHED_LIMIT'):04X}")
    # oversize synthetic geometry: CF set and nothing written at or past the limit
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE2"))
    mc.sync()
    before = bytes(mc.phys)
    cpu = build_sched(mc, 1, 1020, 255, x0=0)
    if not cpu.fc:
        raise Fail("1,1020x255: CF clear for an oversize schedule")
    gen = set()
    for name in SYMS:
        if name.startswith("vrg") or name.startswith("vidP_"):
            gen |= {(SYMS[name][1] & 0x1FFF) + k for k in range(3)}
    allow = {S("VID_PAGE2"): lambda k: k in gen,
             5: lambda k: (STACK - 0x100) - 0xA000 <= k < STACK - 0xA000,
             SCHED_PAGE: True}
    stray_writes(before, bytes(mc.phys), allow)


def test_sector_runwalk():
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    mc.poke16("vidStrmRunBlkH", 1)
    mc.poke("vidDsCrcDue", 0)
    card = Card(blocks(bytes(1024)), waits=1)
    mc.set_card(card)
    fired = []

    def walk(cpu):
        fired.append(card.pos)
        cpu.hl, cpu.fc = 5, 0
        cpu.a = cpu.b = cpu.c = cpu.d = cpu.e = 0xA5     # BC, DE corrupt
    traps = {S("vid_run_walk_h"): ret_trap(walk), **aborts()}
    for k in range(2):
        cpu = mc.run("vr_sector", traps=traps, hl=0x1234)
        if cpu.hl != 0x1234 or cpu.c != PORT_SPI:
            raise Fail(f"call {k + 1}: HL=${cpu.hl:04X} C=${cpu.c:02X}")
        if mc.peek("vidDsCrcDue") != 1:
            raise Fail(f"call {k + 1}: vidDsCrcDue not 1")
        if k == 0:
            if fired or mc.peek("vidStrmRunBlkH", 2) != 0:
                raise Fail(f"call 1: walk fired {len(fired)}, cell "
                           f"{mc.peek('vidStrmRunBlkH', 2)}")
            for _ in range(512):
                card.read()
    if len(fired) != 1 or mc.peek("vidStrmRunBlkH", 2) != 4:
        raise Fail(f"walk fired {len(fired)} times, cell {mc.peek('vidStrmRunBlkH', 2)}")
    if fired[0] != 512 + 1 + 1 + 2:
        raise Fail(f"the walk ran after {fired[0]} reads: the CRC must come first")
    if card.pos != len(card.stream) - 512:
        raise Fail(f"{card.pos} card reads after two sector opens")


def test_sector_badtoken():
    for entry, crc in (("vr_sector", False), ("vr_sector_n", True)):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE"))
        mc.poke16("vidStrmRunBlkH", 100)
        mc.poke("vidDsCrcDue", int(crc))
        mc.set_card(Card(blocks(bytes(512)), token=0xFC, crc_first=crc))
        try:
            mc.run(entry, traps=aborts(), hl=0)
        except Stop as e:
            if not reached(e, "vid_dec_abort_pos") or e.a != S("VID_ERR_TOKEN"):
                raise Fail(f"{entry} bad token: {e}")
            continue
        raise Fail(f"{entry} bad token: returned")


def test_sector_n():
    """vr_sector_n reads the CRC pair whatever vidDsCrcDue holds and leaves the cell alone."""
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    mc.poke16("vidStrmRunBlkH", 100)
    mc.poke("vidDsCrcDue", 0)
    card = Card(blocks(bytes(512)), waits=2, crc_first=True)
    mc.set_card(card)
    cpu = mc.run("vr_sector_n", traps={**aborts(), **forbid("vid_run_walk_h")}, hl=0x2345)
    phases = [p for p, _ in card.log]
    if phases != ["crc", "crc", "wait", "wait", "token"]:
        raise Fail(f"vr_sector_n reads {phases}")
    if mc.peek("vidDsCrcDue") != 0:
        raise Fail(f"vr_sector_n wrote vidDsCrcDue = {mc.peek('vidDsCrcDue')}")
    if cpu.hl != 0x2345 or cpu.c != PORT_SPI or mc.peek("vidStrmRunBlkH", 2) != 99:
        raise Fail(f"vr_sector_n: HL ${cpu.hl:04X} C ${cpu.c:02X} run "
                   f"{mc.peek('vidStrmRunBlkH', 2)}")
    check_log(mc, card, "vr_sector_n")


def test_sector_walkfault():
    """A run walk fault aborts with the walk's A after exactly the two CRC reads."""
    for entry in ("vr_sector", "vr_sector_n"):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE"))
        mc.poke16("vidStrmRunBlkH", 0)
        mc.poke("vidDsCrcDue", 1)
        card = Card(blocks(bytes(512)), crc_first=True)
        mc.set_card(card)

        def walk(cpu):
            cpu.fc, cpu.a, cpu.hl = 1, S("VID_ERR_SHORT"), 0x7777
        try:
            mc.run(entry, traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()}, hl=0x1234)
        except Stop as e:
            if not reached(e, "vid_dec_abort_pos") or e.a != S("VID_ERR_SHORT") or card.pos != 2:
                raise Fail(f"{entry} walk fault: {e}, {card.pos} card reads")
            continue
        raise Fail(f"{entry} walk fault: returned")


def test_frame_runwalk():
    """A fragment run ends at sector 50 inside a frame: the walk fires once, after that
    sector's CRC, and the frame completes exactly."""
    for code, w, h, tag in ((1, 320, 192, 1), (1, 280, 224, 0)):
        mc = RawMachine(SYMS)
        build_sched(mc, code, w, h)
        x0, sectors = setup_frame(mc, code, w, h, tag=tag, remain=0x020000, crc_due=1)
        mc.poke16("vidStrmRunBlkH", 50)
        px = pixels(w * h)
        data = blocks(px)
        if tag:
            data = [bytes(range(256)) * 2] + data
        card = Card(data, waits=2, crc_first=True)
        mc.set_card(card)
        fired = []

        def walk(cpu):
            fired.append(card.pos)
            cpu.hl, cpu.fc = 1000, 0
            cpu.a = cpu.b = cpu.c = cpu.d = cpu.e = 0x5A
        cpu = mc.run("vid_raw_frame", traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()})
        what = f"{code},{w}x{h} tag {tag}"
        per = 2 + 2 + 1 + 512
        base = BACK_BANK * 0x4000
        expect(mc.phys[base:base + SURF_LEN], want_surface(code, w, h, x0, px),
               f"{what} back surface")
        got = (cpu.a, fired, mc.peek("vidStrmRunBlkH", 2), mc.peek("vidStrmRemainBlk", 3),
               len(card.stream) - card.pos, mc.peek("vidDsFrmBlk"))
        want = (S("VOP_KFLIP"), [50 * per + 2], 1000 - (sectors + tag - 50),
                0x020000 - sectors - tag, 0, sectors + 1)
        if got != want:
            raise Fail(f"{what}: (A, walk at, run left, remain, unread, FrmBlk) = {got}, "
                       f"expected {want}")
        check_log(mc, card, what)


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


def test_apad():
    for n, tag in ((286, 1), (1, 0), (511, 1), (286, 2)):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE"))
        mc.poke("vidRawTag", 0x77)
        card = Card(open_data=bytes([0x80] * (n - 1) + [tag]))
        mc.set_card(card)
        traps = {**aborts(), **forbid("vid_ds_blkopen")}
        try:
            cpu = mc.run("vid_raw_apad", traps=traps, hl=n)
        except Stop as e:
            if tag < 2 or not reached(e, "vid_dec_abort") or e.a != S("VID_ERR_OP"):
                raise Fail(f"HL={n} tag {tag}: {e}")
            continue
        if tag >= 2:
            raise Fail(f"HL={n} tag {tag}: no VID_ERR_OP abort")
        if card.pos != n or mc.peek("vidRawTag") != tag or cpu.hl != 0:
            raise Fail(f"HL={n}: {card.pos} reads, vidRawTag {mc.peek('vidRawTag')}, "
                       f"HL ${cpu.hl:04X}")
        check_log(mc, card, f"apad HL={n}")


def test_apad_boundary():
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    card = Card(open_data=bytes([0x80] * 511 + [1]))
    mc.set_card(card)
    fired = []

    def blkopen(cpu):
        fired.append(card.pos)
        cpu.hl = 512
    traps = {S("vid_ds_blkopen"): ret_trap(blkopen), **aborts()}
    cpu = mc.run("vid_raw_apad", traps=traps, hl=0)
    if fired != [0]:
        raise Fail(f"vid_ds_blkopen entries at reads {fired}, expected one before any read")
    if card.pos != 512 or mc.peek("vidRawTag") != 1 or cpu.hl != 0:
        raise Fail(f"{card.pos} reads, vidRawTag {mc.peek('vidRawTag')}, HL ${cpu.hl:04X}")


def test_vr_page():
    mc = RawMachine(SYMS)
    mc.map(7, S("VID_PAGE"))
    mc.poke("vidDstPage", 61)
    cpu = mc.run("vr_page", bc=0x12EB, de=0x3456, hl=0x6000)
    if (cpu.hl, mc.peek("vidDstPage"), mc.mmu[2], cpu.bc, cpu.de) != (0x4000, 62, 62,
                                                                         0x12EB, 0x3456):
        raise Fail(f"vr_page: HL ${cpu.hl:04X} page {mc.peek('vidDstPage')} MMU2 "
                   f"{mc.mmu[2]} BC ${cpu.bc:04X} DE ${cpu.de:04X}")


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
        want = ((S("vid_raw_frame") if raw else S("vid_decode_frame_ds")),
                (S("vid_raw_apad") if raw else S("vid_ds_pad")), raw, direct)
        if got != want:
            raise Fail(f"direct {direct} raw {raw}: operands/cells {[hex(x) for x in got]}, "
                       f"expected {[hex(x) for x in want]}")


def test_raw_stage():
    hot = S("VID_PAGE")
    for x0, bank, sec in ((0, 50, 120), (20, 7, 123), (158, 111, 1), (32, 60, 120)):
        mc = RawMachine(SYMS)
        mc.map(7, S("VID_PAGE2"))
        mc.map(6, hot)
        mc.poke("vidRingBanksC", bank)
        mc.poke("vidRawSecC", sec)
        mc.poke("vidCapBlkC", sec + 1)
        mc.poke("vidP_RawX0", x0)
        off = S("DATA_WINDOW") - S("OVL_ORG")
        mc.mem[S("vidRawTag") + off] = 0x77
        mc.run("vid_raw_stage")
        got = tuple(mc.mem[S(n) + off] for n in ("vidRawSchedPage", "vidRawSec", "vidRawCap",
                                                 "vidRawPage0", "vidRawH0", "vidRawTag"))
        want = (bank * 2, sec, sec + 1, x0 >> 5, 0x40 + (x0 & 31), 0)
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


def isr_tick(mc, name, hlp):
    """One interrupt into handler name: IFF clear (the acknowledge), HL' = hlp, run to RETI.
    Asserts the main set, IX, IY, BC', DE' and SP are kept, no memory or NR write, IFF set,
    and the last three bytes executed are FB ED 4D. Returns HL'."""
    cpu = mc.cpu
    set_main(cpu)
    cpu.alt.update(ALT_BCDE)
    set_alt_hl(cpu, hlp)
    cpu.iff = 0
    cpu.sp = STACK
    cpu.push(RET)
    before, nr0 = bytes(mc.mem), len(mc.nrlog)
    pcs = []
    cpu.pc = S(name)
    while cpu.pc != RET:
        if len(pcs) > 64:
            raise Fail(f"{name}: no RETI after 64 instructions")
        pcs.append(cpu.pc)
        cpu.step()
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
    return alt_hl(cpu)


def test_isr_stereo():
    if (S("VID_DAC_LEFT"), S("VID_DAC_RIGHT")) != (DAC_L, DAC_R):
        raise Fail("VID_DAC_LEFT / VID_DAC_RIGHT are not $F3 / $F9")
    mc, ring = isr_machine()
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    for off, nxt in ((10, 12), (0xFE, 0x100), (n - 2, 0)):
        mc.dac = []
        hl = isr_tick(mc, "video_ctc_isr_raw_st", base + off)
        want = [(DAC_L, ring[off]), (DAC_R, ring[off + 1])]
        if mc.dac != want or hl != base + nxt:
            raise Fail(f"HL' = base+${off:X}: ports {mc.dac}, HL' ${hl:04X}; expected {want}, "
                       f"${base + nxt:04X}")
    mc.dac, hl = [], base                    # a whole lap: every pair in order, back to base
    for _ in range(n // 2):
        hl = isr_tick(mc, "video_ctc_isr_raw_st", hl)
    want = [(DAC_R if i & 1 else DAC_L, ring[i]) for i in range(n)]
    if mc.dac != want or hl != base:
        bad = next((i for i, (x, y) in enumerate(zip(mc.dac, want)) if x != y), len(mc.dac))
        raise Fail(f"lap: first wrong write {bad} of {len(want)}, HL' ${hl:04X}")


def test_isr_mono():
    if S("VID_DAC_MONO") != DAC_M:
        raise Fail("VID_DAC_MONO is not $B3")
    mc, ring = isr_machine()
    base, n = S("vidAudBuf"), S("NXV_AUD_RING")
    for off, nxt in ((10, 11), (0xFF, 0x100), (n - 1, 0)):
        mc.dac = []
        hl = isr_tick(mc, "video_ctc_isr_raw_mono", base + off)
        if mc.dac != [(DAC_M, ring[off])] or hl != base + nxt:
            raise Fail(f"HL' = base+${off:X}: ports {mc.dac}, HL' ${hl:04X}; expected "
                       f"[($B3, {ring[off]})], ${base + nxt:04X}")
    mc.dac, hl = [], base
    for _ in range(n):
        hl = isr_tick(mc, "video_ctc_isr_raw_mono", hl)
    if mc.dac != [(DAC_M, v) for v in ring] or hl != base:
        raise Fail(f"lap: {len(mc.dac)} writes, HL' ${hl:04X}")


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
    mc = RawMachine(SYMS)
    b = S("vidAudBuf")
    want = {"vid_raw_rd_hl": bytes.fromhex("F3D9E5D9FBE1C9"),
            "vid_raw_rd_de": bytes.fromhex("F3D9E5D9FBD1C9"),
            "vid_raw_prime": bytes([0xD9, 0x21, b & 0xFF, b >> 8, 0xD9, 0xC9])}
    for name, w in want.items():
        got = bytes(mc.mem[S(name):S(name) + len(w)])
        if got != w:
            raise Fail(f"{name}: {got.hex(' ').upper()}, expected {w.hex(' ').upper()}")
    cpu = mc.cpu
    for name, reg in (("vid_raw_rd_hl", "h"), ("vid_raw_rd_de", "d")):
        set_main(cpu)
        cpu.alt.update(ALT_BCDE)
        set_alt_hl(cpu, 0x6789)
        cpu.iff = 1
        mc.run(name)
        got = getattr(cpu, reg + ("l" if reg == "h" else "e"))
        main_kept(cpu, name, but=(reg, "l" if reg == "h" else "e"))
        if (got, alt_hl(cpu), cpu.iff) != (0x6789, 0x6789, 1):
            raise Fail(f"{name}: read ${got:04X}, HL' ${alt_hl(cpu):04X}, IFF {cpu.iff}")
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
    mc = RawMachine(SYMS)                    # MMU7 = VID_PAGE as assembled
    for name, w in (("vid_pace_poll.rd", b"\xDD\xE5\xE1"), ("vid_aud_pump.rd", b"\xDD\xE5\xD1"),
                    ("vid_run.ixp1", ix_form()), ("vid_run.ixp2", ix_form())):
        got = bytes(mc.mem[S(name):S(name) + len(w)])
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
            (S("vid_aud_pump.apad") + 1, le(S("vid_raw_apad" if raw else "vid_ds_pad")))]
    if raw:
        prime = b"\xCD" + le(S("vid_raw_prime")) + b"\x00"
        out += [(S("vid_pace_poll.rd"), b"\xCD" + le(S("vid_raw_rd_hl"))),
                (S("vid_aud_pump.rd"), b"\xCD" + le(S("vid_raw_rd_de"))),
                (S("vid_run.ixp1"), prime), (S("vid_run.ixp2"), prime)]
    else:
        out += [(S("vid_pace_poll.rd"), b"\xDD\xE5\xE1"), (S("vid_aud_pump.rd"), b"\xDD\xE5\xD1"),
                (S("vid_run.ixp1"), ix_form()), (S("vid_run.ixp2"), ix_form())]
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
        patch_session(mc, direct, raw)
        got, want = hot_page(mc), with_writes(snap, vec_writes(direct, raw))
        if got != want:
            raise Fail(f"patch_session({direct}, {raw}): " + describe(want, got))
    if hot_page(mc) != snap:
        raise Fail("after (1, 1), (1, 0), (0, 0) the hot page is not the assembled image")


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
    """After a raw open the pace poll, the pump and the two arm sites run on HL' (the model
    has no IX: an unpatched site would fail on its DD prefix)."""
    mc = RawMachine(SYMS)
    patch_session(mc, 1, 1)
    base, n, guard = S("vidAudBuf"), S("NXV_AUD_RING"), S("NXV_AUD_GUARD")
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
    if "vidRlSpinDiv" in SYMS:
        mc.poke("vidRlSpinDiv", 100)
    mc.poke16("vidAudFeedRem", 1000)
    mc.poke16("vidAudWr", base + 1500)
    mc.poke16("vidDsAudBlkRem", 7)
    set_alt_hl(cpu, base + 2000)
    seen = []

    def xfer(c):
        seen.append(c.bc)
        c.de = (c.de + c.bc) & 0xFFFF
        c.hl = 3
    mc.run("vid_aud_pump", traps={S("vid_ds_xfer"): ret_trap(xfer), **aborts()},
           bc=0xFFFF, de=0x2468)
    room = n - guard - (1500 - 2000) % n
    got = (seen, mc.peek("vidAudFeedRem", 2), mc.peek("vidAudWr", 2), cpu.iff)
    if got != ([room], 1000 - room, base + 1500 + room, 1):
        raise Fail(f"vid_aud_pump: (chunks, feedRem, wr, IFF) = {got}, expected "
                   f"([{room}], {1000 - room}, {base + 1500 + room}, 1)")
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
    .qnext: a further vid_pace_poll (raw form patched to vid_raw_rd_hl; the IX form's 3-byte
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


def nxb_machine(cls=None):
    """A machine with the NXB page in physical RAM and NR $50-$57 readable (NRGET)."""
    mc = (cls or RawMachine)(SYMS)
    nxb = S("NXB_PAGE")
    mc.phys[nxb * SLOT:(nxb + 1) * SLOT] = read_page(nxb)
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
    code_is(mc, "nxb_rh_body", b"\x21" + le(scr) + b"\xCD" + le(S("nxb_rh_sec")) + b"\xC3" + le(slide))
    n = S("NXB_RW_SPIN")
    code_is(mc, "nxb_rw_spin", b"\x01" + le(n) + b"\x0B\x78\xB1\x20\xFB\xC9")
    # the binned wait polls as vid_sd_tok_h does: in 11, inc a 4, jr nz 7, a 16-bit step 6,
    # ld a,r 4, or r 4, jr nz 12 = 48 T between data-port reads
    for name, step in (("nxb_rh_sec.w", b"\x13\x7A\xB3"), ("vid_sd_tok_h.wt", b"\x0B\x78\xB1")):
        w = S(name)
        b = bytes(mc.mem[w:w + 10])
        if b[:4] != b"\xDB\xEB\x3C\x20" or b[5:8] != step or b[8:] != b"\x20\xF6" or b[4] > 0x7F:
            raise Fail(f"{name}: {b.hex(' ').upper()} is not the 48 T poll loop")
    if SYMS["nxbHistBin"][0] != S("VID_PAGE") or SYMS["nxbHistN"][0] != S("VID_PAGE"):
        raise Fail("nxbHistBin / nxbHistN are not on VID_PAGE (written with MMU6 = schedule)")


def test_rw_feed():
    """nxb_rw_feed after a raw open's patches: the pointer from HL' (IX is garbage and never
    read), the writer half a ring ahead, one frame's sound off the wire, the tag stored."""
    bench_only()
    mc = RawMachine(SYMS)
    patch_session(mc, 1, 1)
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
    allowed = {"crc": {"vid_ds_blkopen"}, "wait": {"vid_sd_tok_h"}, "token": {"vid_sd_tok_h"},
               "data": {"vid_ds_iblk", "vid_ds_pad", "vid_raw_apad"}}
    for i, (ph, pc) in enumerate(card.log):
        if owner(pc) not in allowed[ph]:
            raise Fail(f"card read {i} ({ph}) by {owner(pc)}")


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
    """nxb_rw_go's untimed sector, then one rep of RSEC and of RCOL: 2 CRC + waits + token +
    512 data reads each; RSEC into VR_SCRATCH, RCOL as 8 columns of 64 on the surface page."""
    bench_only()
    mc = RawMachine(SYMS)
    rw_sched(mc)
    rw_cells(mc, run=1000, crc=1)
    mc.poke("vidRawSchedPage", SCHED_PAGE)
    mapnr(mc, 6, 12)
    scr = S("VR_SCRATCH")
    data = [bytes((i * 13 + 7 * k) & 0xFF for i in range(512)) for k in range(3)]
    fired = []
    card = Card([data[0]], waits=1, crc_first=True)
    mc.set_card(card)
    mc.run("nxb_rw_go", traps={S("nxb_lrow"): ret_trap(lambda c: fired.append(c.pc)), **aborts()})
    got = (len(fired), mc.mmu[6], card.pos, mc.peek("vidDsCrcDue"), mc.peek("vidStrmRunBlkH", 2))
    if got != (1, SCHED_PAGE, len(card.stream), 1, 999) or bytes(mc.mem[scr:scr + 512]) != data[0]:
        raise Fail(f"nxb_rw_go: (lrow entries, MMU6, reads, crcDue, run) = {got}")
    check_log(mc, card, "nxb_rw_go")
    mc.poke("vidDsCrcDue", 0)                 # no CRC pends: vr_sector reads none
    mapnr(mc, 6, 12)
    card = Card([data[2]], waits=1)
    mc.set_card(card)
    mc.run("nxb_rw_go", traps={S("nxb_lrow"): ret_trap(lambda c: fired.append(c.pc)), **aborts()})
    if (card.pos, mc.peek("vidDsCrcDue"), mc.peek("vidStrmRunBlkH", 2)) != (len(card.stream), 1, 998):
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
        if mc.peek("vidStrmRunBlkH", 2) != run0 - 1 or cpu.c != PORT_SPI:
            raise Fail(f"{name}: run {mc.peek('vidStrmRunBlkH', 2)}, C ${cpu.c:02X}")
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


def test_rw_hist():
    """nxb_rh_body: a sector as RSEC with the token wait of k $FF polls counted into bin
    bitlength(k); a fragment walk's wait binned too; 65536 polls abort with VID_ERR_TOKEN."""
    bench_only()
    mc = RawMachine(SYMS)
    rw_sched(mc)
    rw_cells(mc, run=1000, crc=1)
    nb, hb, scr = S("NXB_HIST_BINS"), S("nxbHistBin"), S("VR_SCRATCH")
    if nb != 17:
        raise Fail(f"NXB_HIST_BINS = {nb}")
    mc.mem[hb:hb + 2 * nb] = bytes(2 * nb)
    allowed = {"crc": {"nxb_rh_sec"}, "wait": {"nxb_rh_sec"}, "token": {"nxb_rh_sec"},
               "data": {"slide"}}
    owner = owner_fn(mc)
    want = [0] * nb
    fired = []

    def walk(c):
        fired.append(card.pos)
        c.hl, c.fc = 50, 0
    for i, k in enumerate((0, 1, 2, 3, 4, 7, 8, 255, 256, 1000, 65535, 5)):
        sec = bytes((j * 5 + i) & 0xFF for j in range(512))
        card = Card([sec], waits=k, crc_first=True)
        mc.set_card(card)
        if k == 5:
            mc.poke16("vidStrmRunBlkH", 0)
        run0 = mc.peek("vidStrmRunBlkH", 2)
        cpu = mc.run("nxb_rh_body", traps={S("vid_run_walk_h"): ret_trap(walk), **aborts()},
                     budget=5_000_000)
        want[k.bit_length()] += 1
        bins = [mc.mem[hb + 2 * j] | mc.mem[hb + 2 * j + 1] << 8 for j in range(nb)]
        run1 = mc.peek("vidStrmRunBlkH", 2)
        if bins != want or card.pos != len(card.stream) or bytes(mc.mem[scr:scr + 512]) != sec:
            raise Fail(f"{k} polls: bins {bins}, expected {want}; {card.pos} of "
                       f"{len(card.stream)} reads")
        if run1 != (49 if k == 5 else run0 - 1) or cpu.c != PORT_SPI or cpu.hl != scr + 512:
            raise Fail(f"{k} polls: run {run0} -> {run1}, C ${cpu.c:02X}, HL ${cpu.hl:04X}")
        for j, (ph, pc) in enumerate(card.log):
            if owner(pc) not in allowed[ph]:
                raise Fail(f"{k} polls: read {j} ({ph}) by {owner(pc)}")
    if fired != [2]:
        raise Fail(f"vid_run_walk_h entries at reads {fired}, expected one after the 2 CRC reads")
    for what, card in (("65536 polls", Card([bytes(512)], waits=65536, crc_first=True)),
                       ("token $FD", Card([bytes(512)], waits=3, crc_first=True, token=0xFD))):
        mc.set_card(card)
        try:
            mc.run("nxb_rh_body", traps=aborts(), budget=5_000_000)
        except Stop as e:
            if not reached(e, "vid_dec_abort_pos") or e.a != S("VID_ERR_TOKEN"):
                raise Fail(f"{what}: {e}")
        else:
            raise Fail(f"{what}: no VID_ERR_TOKEN abort")
    bins = [mc.mem[hb + 2 * j] | mc.mem[hb + 2 * j + 1] << 8 for j in range(nb)]
    if bins != want:
        raise Fail(f"a timed-out wait changed the bins: {bins}")


class PortMachine(RawMachine):
    """Logs CTC 0 and DAC port writes with HL', IX and the CTC 0 vector at each write."""

    def __init__(self, syms):
        super().__init__(syms)
        self.ports = []

    def port_out(self, port, v):
        lo, ctc = port & 0xFF, S("AUD_CTC_PORT")
        if port == ctc or lo in (S("DAC_PORT"),) + DAC_PORTS:
            stub = S("IM2_CTC_STUB") + 1
            self.ports.append((port if port == ctc else lo, v, alt_hl(self.cpu), self.cpu.ix,
                               self.mem[stub] | self.mem[stub + 1] << 8))
            return
        super().port_out(port, v)


def test_rw_arms():
    """RARM primes HL' after CTC 0's reset and control word, before its time constant, and
    leaves IX alone; ARMOLD installs video_ctc_isr_stereo with CTC 0 stopped and primes IX;
    ARM is unchanged; DISARM stops CTC 0, parks the DACs, then puts nxbSessVec back."""
    bench_only()
    ctc, base, sil = S("AUD_CTC_PORT"), S("vidAudBuf"), S("DAC_SILENCE")
    raw_st, stereo = S("video_ctc_isr_raw_st"), S("video_ctc_isr_stereo")
    stub = S("IM2_CTC_STUB") + 1
    cw, rst = S("AUD_CTC_CW16"), S("AUD_CTC_RESET")
    for kind in ("nxb_kind_rarm", "nxb_kind_armold", "nxb_kind_arm", "nxb_kind_disarm"):
        mc = nxb_machine(PortMachine)
        mapnr(mc, 6, S("NXB_PAGE"))
        cpu = mc.cpu
        mc.poke("vidCtcTc", 0x70)
        mc.mem[stub:stub + 2] = le(stereo if kind == "nxb_kind_disarm" else raw_st)
        mc.poke16("nxbSessVec", raw_st)
        mc.mem[base:base + S("NXV_AUD_RING")] = bytes([0x11]) * S("NXV_AUD_RING")
        set_alt_hl(cpu, 0x1234)
        cpu.ix = 0xDEAD
        traps = {}
        if kind in ("nxb_kind_armold", "nxb_kind_arm"):
            code_is(mc, "nxb_arm_ix", b"\xDD\x21" + le(base))

            def ldix(c):
                c.ix = base
                c.pc += 4
            traps[S("nxb_arm_ix")] = ldix
        mc.run(kind, traps=traps)
        vec = mc.mem[stub] | mc.mem[stub + 1] << 8
        if kind == "nxb_kind_disarm":
            want = [(ctc, rst, 0x1234, 0xDEAD, stereo)] * 2 + [
                (p, sil, 0x1234, 0xDEAD, stereo) for p in (S("DAC_PORT"), DAC_L, DAC_R, DAC_M)]
            if mc.ports != want or vec != raw_st:
                raise Fail(f"{kind}: ports {mc.ports}, vector ${vec:04X}")
            continue
        hl1, ix1, v1 = {"nxb_kind_rarm": (base, 0xDEAD, raw_st),
                        "nxb_kind_armold": (0x1234, base, stereo),
                        "nxb_kind_arm": (0x1234, base, raw_st)}[kind]
        want = [(ctc, rst, 0x1234, 0xDEAD, raw_st)] * 2 + [(ctc, cw, 0x1234, 0xDEAD, raw_st),
                                                         (ctc, 0x70, hl1, ix1, v1)]
        ring = bytes(mc.mem[base:base + S("NXV_AUD_RING")])
        if mc.ports != want or vec != v1 or ring != bytes([sil]) * len(ring):
            raise Fail(f"{kind}: ports {mc.ports}, vector ${vec:04X}, ring silent "
                       f"{ring == bytes([sil]) * len(ring)}")


def test_rw_kinds():
    """The NXB kinds' untimed setup: RBLK/RHIST charge reps + 1 to the 24-bit remain and pick
    the body (RBLK maps the hidden surface page at MMU2, RHIST zeroes the bins and patches the
    print), fewer than NXB_RW_MIN blocks print NXB SHORT and run nothing; RHIST's print saves
    tag and bins (at most NXB_HIST_MAX) and restores the exit; RFRAME/SPIN bodies; IDEN's
    raw picture width."""
    bench_only()
    hb, nb = S("nxbHistBin"), S("NXB_HIST_BINS")

    def kmc():
        mc = nxb_machine()
        mapnr(mc, 6, S("NXB_PAGE"))
        mc.poke("l2BackBank", BACK_BANK)
        mc.poke16("nxbReps", 128)
        mc.poke("nxbSO", 0x77)
        return mc
    seen = {}

    def at(name):
        def t(c):
            seen[name] = (c.pc, mc.mem[S("nxb_body") + 1] | mc.mem[S("nxb_body") + 2] << 8)
            c.pc = c.pop()
        return t
    for kind, param, reps, remain, body, left in (
            ("nxb_kind_rblk", 0, 128, 0x012345, "nxb_rw_sec", 0x012345 - 129),
            ("nxb_kind_rblk", 1, 128, 0x010000, "nxb_rw_col", 0x010000 - 129),
            ("nxb_kind_rblk", 1, 128, 5000, "nxb_rw_col", 5000 - 129),
            ("nxb_kind_rhist", 0, 2048, 0x020000, "nxb_rh_body", 0x020000 - 2049),
            ("nxb_kind_rblk", 0, 128, 4999, None, 4999),
            ("nxb_kind_rhist", 0, 2048, 0, None, 0)):
        mc = kmc()
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
        what = f"{kind} param {param} remain ${remain:06X}"
        if mc.peek("vidStrmRemainBlk", 3) != left:
            raise Fail(f"{what}: remain ${mc.peek('vidStrmRemainBlk', 3):06X}, expected ${left:06X}")
        if body is None:
            if "go" in seen or not cpu.fc or msgs != [S("nxbMsgShort")]:
                raise Fail(f"{what}: refused row ran or printed {msgs} (CF {cpu.fc})")
            continue
        if seen.get("go", (0, 0))[1] != S(body) or mc.peek("nxbSO") != 0:
            raise Fail(f"{what}: body ${seen.get('go', (0, 0))[1]:04X}, expected {body}")
        bins = bytes(mc.mem[hb:hb + 2 * nb])
        patched = mc.mem[pr] | mc.mem[pr + 1] << 8
        if kind == "nxb_kind_rhist":
            if bins != bytes(2 * nb) or patched != S("nxb_rh_done"):
                raise Fail(f"{what}: bins not zeroed or nxb_lrow.pr ${patched:04X}")
        elif mc.mmu[2] != BACK_BANK * 2 or patched != S("nxb_sprint"):
            raise Fail(f"{what}: MMU2 {mc.mmu[2]}, nxb_lrow.pr ${patched:04X}")
    # RHIST's print: slots 0 and 1, then capped
    mc = kmc()
    tab = S("nxbTabBuf")
    sav, ln = S("nxbHistSav"), S("NXB_HIST_LEN")
    mc.mem[sav:sav + 2 * ln] = b"\xEE" * (2 * ln)
    saved = []
    for n, tag in ((0, b"RHST"), (1, b"AHST"), (2, b"XHST")):
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
        if n < 2:
            saved.append(tag + binv)
        if bytes(mc.mem[sav:sav + 2 * ln]) != b"".join(saved) + b"\xEE" * ((2 - len(saved)) * ln):
            raise Fail(f"nxb_rh_done at {n}: slots hold {bytes(mc.mem[sav:sav + 2 * ln])[:12]!r}...")
    for kind, body in (("nxb_kind_rfr", "nxb_rw_fbody"), ("nxb_kind_spin", "nxb_rw_spin")):
        mc = kmc()
        seen.clear()
        mc.run(kind, traps={S("nxb_lrow"): at("lrow")})
        if seen.get("lrow", (0, 0))[1] != S(body) or mc.peek("nxbSO") != 0:
            raise Fail(f"{kind}: body ${seen.get('lrow', (0, 0))[1]:04X}, expected {body}")
    # IDEN: F = the surface width, less 2 x x0 for a raw clip
    for raw, pages, page0, h0, want in ((1, 10, 0, 0x40, 320), (1, 10, 0, 0x54, 280),
                                        (1, 10, 1, 0x40, 256), (1, 10, 4, 0x5E, 4),
                                        (1, 6, 0, 0x40, 256), (0, 10, 3, 0x41, 320),
                                        (0, 6, 3, 0x41, 256)):
        mc = kmc()
        for name, v in (("vidRaw", raw), ("vidDstPages", pages), ("vidRawPage0", page0),
                        ("vidRawH0", h0), ("vidHeightB", 192)):
            mc.poke(name, v)
        mc.run("nxb_kind_id", traps={S("nxb_fprint"): ret_trap(lambda c: None)})
        if mc.peek("nxbLcF", 2) != want:
            raise Fail(f"IDEN raw {raw} pages {pages} x0 {page0 * 32 + h0 - 0x40}: F "
                       f"{mc.peek('nxbLcF', 2)}, expected {want}")


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
    bins = {"RHST": [0x07F8, 5, 2] + [0] * 13 + [0xABCD], "AHST": [0] * 16 + [1]}
    sav, ln = S("nxbHistSav"), S("NXB_HIST_LEN")
    for i, (t, b) in enumerate(bins.items()):
        mc.mem[sav + i * ln:sav + (i + 1) * ln] = t.encode() + b"".join(le(n) for n in b)
    for n in (2, 1, 0):
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


TESTS = [test_sched_pixels, test_sched_reads, test_sched_shape, test_sched_pad,
         test_sched_limit, test_sector_runwalk, test_sector_badtoken, test_sector_n,
         test_sector_walkfault, test_frame_remain, test_frame_palette, test_frame_runwalk,
         test_apad, test_apad_boundary, test_vr_page, test_vec_patch, test_raw_stage,
         test_isr_stereo, test_isr_mono, test_isr_static, test_rd_bytes,
         test_patch_sites_default, test_patch_roundtrip, test_patched_reads, test_isr_choice,
         test_dbg_counters, test_dbg_calls, test_rw_shapes, test_rw_feed, test_rw_route,
         test_rw_card, test_rw_hist, test_rw_arms, test_rw_kinds, test_rw_histlog]


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
