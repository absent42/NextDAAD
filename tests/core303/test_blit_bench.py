"""BLT303 (tests/core303/blit): the bench assembles, its rows run on the host Z80 and
blitter model of tests/ddma_contract.py, and its program stays the shipped one."""
import re
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
BLIT = HERE / "blit"
OUT = ROOT / "build" / "blt303"
sys.path.insert(0, str(HERE.parent))

import ddma_contract as dc  # noqa: E402
from tags import TAGS  # noqa: E402

PAGE = 0x2000
PHYS_RAM = 0x40000
ROW_LEN = 16
SIZES = (1, 4, 8, 16, 53, 71, 128, 240)


class Paged:
    """64K through the MMU: slot s holds 8K page mc.map[s] of mc.phys."""

    def __init__(self, mc):
        self.mc = mc

    def _at(self, a):
        return self.mc.map[a >> 13] * PAGE + (a & (PAGE - 1))

    def __getitem__(self, a):
        if isinstance(a, slice):
            return bytes(self[i] for i in range(*a.indices(0x10000)))
        return self.mc.phys[self._at(a)]

    def __setitem__(self, a, v):
        self.mc.phys[self._at(a)] = v


class BenchCPU(dc.CPU):
    def step(self):
        op = self.m[self.pc]
        if op == 0x08:                                  # ex af,af'
            self.pc += 1
            now = (self.a, self.fz, self.fc, self.fs)
            self.a, self.fz, self.fc, self.fs = getattr(self, "alt", (0, 0, 0, 0))
            self.alt = now
        elif op == 0xDD and self.m[self.pc + 1] == 0x2A:   # ld ix,(nn)
            a = self.m[self.pc + 2] | self.m[self.pc + 3] << 8
            self.ix = self.m[a] | self.m[a + 1] << 8
            self.pc += 4
        elif op == 0xDD and self.m[self.pc + 1] == 0x7E:   # ld a,(ix+d)
            self.a = self.m[self.ix + self.m[self.pc + 2]]
            self.pc += 3
        else:
            super().step()


class BenchMachine:
    def __init__(self, nex, syms):
        self.syms = syms
        self.phys = bytearray(256 * PAGE)
        self.map = [254, 255, 10, 11, 4, 5, 0, 1]
        self.phys[4 * PAGE:6 * PAGE] = nex[512:512 + 2 * PAGE]
        self.mem = Paged(self)
        self.nr = {}
        self.blit = dc.Blitter(self)
        self.cpu = BenchCPU(self)

    def nextreg(self, n, v):
        self.nr[n] = v
        if 0x50 <= n <= 0x57:
            assert n - 0x50 not in (4, 5), "the bench never remaps its own code"
            self.map[n - 0x50] = v

    def pread(self, a):
        return self.phys[a - PHYS_RAM]

    def pwrite(self, a, v):
        self.phys[a - PHYS_RAM] = v

    def mread(self, a):
        return self.mem[a & 0xFFFF]

    def mwrite(self, a, v):
        self.mem[a & 0xFFFF] = v

    def w16(self, name, v):
        a = self.syms[name]
        self.mem[a] = v & 0xFF
        self.mem[a + 1] = v >> 8

    def r16(self, a):
        return self.mem[a] | self.mem[a + 1] << 8

    def call(self, addr, budget=60_000_000):
        cpu = self.cpu
        cpu.sp = 0xBD00
        cpu.push(dc.RET)
        cpu.pc = addr
        while cpu.pc != dc.RET:
            budget -= 1
            assert budget > 0, "routine at %04X did not return" % addr
            cpu.step()
        return cpu


@pytest.fixture(scope="module")
def built():
    res = subprocess.run(["pwsh", "-NoProfile", "-File", str(BLIT / "build.ps1"), "-AllowDirty"],
                         capture_output=True, text=True, timeout=180)
    out = res.stdout + res.stderr
    assert res.returncode == 0, out
    assert "error" not in out.lower() and "warning" not in out.lower(), out
    syms = {}
    for line in (OUT / "BLT303.sym").read_text(encoding="ascii").splitlines():
        m = re.fullmatch(r"(\S+): EQU 0x([0-9A-F]{8})", line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    nex = (OUT / "BLT303.NEX").read_bytes()
    m = re.search(r"^stamp: (\S+)$", out, re.M)
    assert m and m.group(1).encode("ascii") in nex
    return nex, syms


def rows(mc):
    out = {}
    a = mc.syms["rowTable"]
    while mc.mem[a]:
        tag = bytes(mc.mem[a:a + 4]).decode("ascii")
        out[tag] = a
        a += ROW_LEN
    return out


def run_row(built, tag, body=True):
    """Init, one body pass and the check of a row. -> (machine, CK, CF of the check)."""
    nex, syms = built
    mc = BenchMachine(nex, syms)
    a = rows(mc)[tag]
    mc.w16("rtRow", a)
    mc.mem[syms["rtKind"]] = mc.mem[a + 15]
    mc.mem[syms["ddmaOk"]] = 1
    assert mc.r16(a + 8) != syms["row_bound"], tag
    cpu = mc.call(mc.r16(a + 8))
    assert cpu.fc == 0, "%s init refused" % tag
    primed = len(mc.blit.transfers)
    if body:
        mc.call(mc.r16(a + 10))
    cpu = mc.call(mc.r16(a + 12))
    return mc, cpu.hl, cpu.fc, primed


def test_tags_known(built):
    text = (BLIT / "rows.asm").read_text(encoding="ascii")
    found = re.findall(r'ROW\s+"(\w{4})"', text)
    assert len(found) == len(set(found)) and len(found) > 100
    for tag in found:
        assert tag in TAGS, tag
    mc = BenchMachine(*built)
    assert list(rows(mc)) == found
    for tag, a in rows(mc).items():
        assert mc.r16(a + 8) != built[1]["row_bound"], tag


def test_sizes_match_tags(built):
    mc = BenchMachine(*built)
    a = built[1]["vidTab"]
    assert tuple(mc.r16(a + 2 * k) for k in range(8)) == SIZES
    for k, n in enumerate(SIZES):
        for s in "XYZ":
            for fam in ("CP", "LN", "RF", "RR", "KF", "KR"):
                assert TAGS["%s%s%d" % (s, fam, k)].size == n


@pytest.mark.parametrize("tag,shape", [
    ("XLN0", (1, 1, 1, None)), ("XLN7", (1, 240, 1, None)),
    ("XRF0", (3, 1, 1, None)), ("XRF4", (3, 53, 1, None)), ("XRF7", (3, 240, 1, None)),
    ("XRR3", (3, 16, 1, None)), ("XRR7", (3, 240, 1, None)),
    ("XKF3", (3, 1, 16, 256)), ("XKR7", (3, 1, 240, 256)),
    ("XSP0", (3, 256, 1, None)), ("XSP1", (3, 256, 16, 256)), ("XSP2", (3, 256, 16, 256)),
    ("XSP3", (3, 1, 320, 256)), ("XSP4", (3, 1, 320, 256)), ("XSP5", (3, 256, 1, None)),
])
def test_row_moves_its_bytes(built, tag, shape):
    mc, ck, cf, primed = run_row(built, tag)
    assert cf == 0, "%s CK=%04X BAD" % (tag, ck)
    reload = tag[1:3] in ("RR", "KR") or tag in ("XSP0", "XSP1", "XSP3")
    assert primed == (1 if reload else 0)
    assert len(mc.blit.transfers) == primed + 1
    t = mc.blit.transfers[-1]
    assert t["full"] is (not reload)
    mode, rowlen, rows_, strb = shape
    assert (t["mode"], t["rowlen"], t["rows"]) == (mode, rowlen, rows_)
    if strb is not None:
        assert t["strb"] == strb and t["stra"] == (256 if rowlen == 256 else 1)
    assert t["src"] >> 16 == 0x0B and t["dst"] >> 16 == 0x08


@pytest.mark.parametrize("tag", ["XLN0", "XLN7", "XRF7", "XKF3", "XKF7", "XSP2", "XSP4", "XSP5"])
def test_check_catches_no_transfer(built, tag):
    """Negative control: a full-program row whose body never ran fails its check."""
    _, ck, cf, _ = run_row(built, tag, body=False)
    assert (ck, cf) == (0xBAD0, 1)


@pytest.mark.parametrize("tag", ["ZPF0", "ZPF1", "ZPF2", "ZPF3", "ZPF4"])
def test_pad_proof(built, tag):
    mc, ck, cf, _ = run_row(built, tag)
    assert (ck, cf) == (0, 0)
    # the proof reads the byte the transfer wrote last: break the transfer, it must count
    nex, syms = built
    mc = BenchMachine(nex, syms)
    a = rows(mc)[tag]
    mc.w16("rtRow", a)
    mc.mem[syms["ddmaOk"]] = 1
    mc.call(mc.r16(a + 8))
    mc.blit.run = lambda: None
    mc.call(mc.r16(a + 10))
    cpu = mc.call(mc.r16(a + 12))
    assert (cpu.hl, cpu.fc) == (1, 1)


def test_pads_follow_the_arm(built):
    """Every body: OTIR, then at once LD B,n / DJNZ $ with n as ddma.inc sizes it."""
    nex, syms = built
    mc = BenchMachine(nex, syms)
    want = {"bp_f%d" % k: n for k, n in enumerate(SIZES)}
    want.update({"bp_r%d" % k: n for k, n in enumerate(SIZES)})
    want.update(bp_f320=320, bp_r320=320, bp_fmax=4096, bp_rmax=4096)
    for name, n in want.items():
        a = syms[name]
        code = bytes(mc.mem[a:a + 13])
        plen = 14 if "_r" in name else 36
        prog = syms["bpAgain" if "_r" in name else "bpProg"]
        assert code[:6] == bytes([0x21, prog & 0xFF, prog >> 8, 0x01, dc.DMA_PORT, plen]), name
        assert code[6:13] == bytes([0xED, 0xB3, 0x06, dc.pad_n(n, 256), 0x10, 0xFE, 0xC9]), name
    for name in ("pf_fmax", "pf_rmax", "pf_f320", "pf_r320"):
        a = syms[name]
        code = bytes(mc.mem[a:a + 40])
        i = code.index(bytes([0xED, 0xB3]))
        n = 4096 if "max" in name else 320
        assert code[i + 2:i + 7] == bytes([0x06, dc.pad_n(n, 256), 0x10, 0xFE, 0x1A]), name


def _layout(text, first, last):
    out = []
    i = text.index("\n" + first + ":")
    body = text[i:text.index(last, i)]
    for line in body.splitlines()[2:]:
        code = re.sub(r"^\.?\w+:", "", line.split(";")[0]).strip()
        m = re.fullmatch(r"(db|dw)\s+(.*)", code)
        if not m:
            assert not code, line
            continue
        for arg in m.group(2).split(","):
            arg = arg.strip()
            out.append(arg if arg.startswith("DDMA_") else "?" * (2 if m.group(1) == "dw" else 1))
    return out


def test_program_is_the_shipped_one():
    shipped = _layout((ROOT / "src" / "overlay2.asm").read_text(encoding="utf-8"),
                      "ddma_prog", "DDMA_AGAIN_LEN equ")
    bench = _layout((BLIT / "blitops.asm").read_text(encoding="ascii"), "bpProg", "BP_AGAIN_LEN ")
    assert bench == shipped and len(shipped) == 29


def test_constants_follow_the_source(built):
    _, syms = built
    inc = (ROOT / "src" / "nextdaad.inc").read_text(encoding="utf-8")
    m = re.search(r"^AUD_RATE_MAX\s+equ\s+(\d+)", inc, re.M)
    assert m and int(m.group(1)) == syms["AUD_RATE_MAX"]
    m = re.search(r"^IM2_CTC2_VEC\s+equ\s+(\d+)", inc, re.M)
    assert m and int(m.group(1)) == syms["IM2_V_CTC1"]
    assert syms["CTC20_TC"] * 16 == dc.CTC_PERIOD_MIN


def test_state_patch(built):
    nex, syms = built
    mc = BenchMachine(nex, syms)
    at = syms["irq_state"] + 11
    assert mc.mem[at] == 0xCC and mc.r16(at + 1) == syms["ctc_start"]
    mc.call(syms["bp_patch"])
    assert mc.r16(at + 1) == syms["ctc_sel"]
