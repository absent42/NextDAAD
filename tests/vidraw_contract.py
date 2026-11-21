#!/usr/bin/env python3
"""Host execution of the raw direct video reader (src/video.asm).

Runs the EMITTED bytes of build\\nextdaad.nex on the tests\\ddma_contract.py Z80 model, with
the MMU applied and port $EB fed by a model of the SD card's CMD18 stream: the cold schedule
generator (vid_raw_sched_build) and hot-cell staging (vid_raw_stage), the raw frame decode
(vid_raw_frame) with its sector opens, surface page step, palette sector and frame tag
(vr_sector, vr_sector_n, vr_page, vid_raw_pal, vid_raw_apad), and the per-session operand patches
(vid_stage_common.vec).

    .\\build.ps1 (or .\\build.ps1 -Release)   then   python tests\\vidraw_contract.py

Exit 0 = every test passed. The variant read (DEBUG or Release) is printed.
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


def _reti(c):
    c.pc = c.pop()


def _swapnib(c):
    c.a = ((c.a << 4) | (c.a >> 4)) & 0xFF


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


EXT = {0xDB: _in_a_n, 0xD3: _out_n_a, 0xD9: _exx, 0x08: _ex_af, 0xF3: _di, 0xFB: _ei}
ED_EXT = {0xA2: _ini, 0x4D: _reti, 0x45: _reti, 0x23: _swapnib}
for _r in range(8):
    ED_EXT[0x40 | _r << 3] = _in_r_c(_r)
    ED_EXT[0x41 | _r << 3] = _out_c_r(_r)


class RawCPU(CPU):
    """ddma_contract's model plus the port, alternate-set and interrupt opcodes."""

    def __init__(self, machine):
        super().__init__(machine)
        self.at = 0
        self.iff = 1
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


TESTS = [test_sched_pixels, test_sched_reads, test_sched_shape, test_sched_pad,
         test_sched_limit, test_sector_runwalk, test_sector_badtoken, test_sector_n,
         test_sector_walkfault, test_frame_remain, test_frame_palette, test_frame_runwalk,
         test_apad, test_apad_boundary, test_vr_page, test_vec_patch, test_raw_stage]


def main():
    import dma_contract
    if not dma_contract.NEX.exists() or not dma_contract.SLD.exists():
        print("vidraw_contract: FAIL - no build\\nextdaad.nex / .sld (run .\\build.ps1 first)")
        return 1
    SYMS.update(read_sld())
    print("vidraw_contract: %s build" % ("DEBUG" if "dbgNoBank" in SYMS else "Release"))
    passed = failed = 0
    for t in TESTS:
        try:
            t()
        except (Fail, Stop) as exc:
            failed += 1
            print(f"  FAIL {t.__name__}: {exc}")
        except Exception as exc:                        # a model or harness fault
            failed += 1
            print(f"  FAIL {t.__name__}: {type(exc).__name__}: {exc}")
        else:
            passed += 1
            print(f"  ok   {t.__name__}")
    print(f"vidraw_contract: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
