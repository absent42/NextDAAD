#!/usr/bin/env python3
"""tests/core_floor_check.py - host checks for the core 3.03.03 floor.

check_nrget_fixture  NRGET emits ED C7 n shipped, and a 3-byte call into
                     the stand-in sled page under NR_STANDIN.
check_standin_guard  build.ps1's Assert-NoStandIn throws naming the nrs_
                     symbol in an SLD that has one, and passes a clean one.
check_nrs_exec       executes the assembled stand-in (src/hardware.asm under
                     NR_STANDIN) for every register number: A = the value,
                     every other register, the flags, the $243B selection,
                     the interrupt state and SP kept. Two broken copies must
                     fail. Matches build\\nextdaad.nex when it is a harness build.

Run standalone or via tests\\build-tests.ps1. Exit 0 = every check passed.
"""

import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
OUT = ROOT / "tests" / "out" / "corefloor"
FIXTURE = "tests/corefloor/nrget_fixture.asm"
EXEC_FIXTURE = "tests/corefloor/nrs_exec_fixture.asm"
BUILD_PS1 = ROOT / "build.ps1"
NEX = ROOT / "build" / "nextdaad.nex"
HARNESS_MARK = ROOT / "build" / "harness.txt"


class Fail(Exception):
    pass


def assemble(src, *defines):
    """Assemble src (repo-relative) as build.ps1 does; return the bytes the
    source writes with OUTPUT or SAVEBIN to tests/out/corefloor/<stem>.bin."""
    raw = OUT / (Path(src).stem + ".bin")
    OUT.mkdir(parents=True, exist_ok=True)
    if raw.exists():
        raw.unlink()
    r = subprocess.run([str(SJASM), "--zxnext=cspect", "--msg=war", *defines, src],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not raw.exists():
        raise Fail(f"sjasmplus {' '.join(defines) or '(shipped)'} {src} failed:\n"
                   + r.stdout + r.stderr)
    return raw.read_bytes()


def fixture_equ(src, name):
    m = re.search(rf"^{name}\s+equ\s+\$([0-9A-Fa-f]+)\s*$",
                  (ROOT / src).read_text(encoding="utf-8"), re.M)
    if not m:
        raise Fail(f"{src}: no '{name} equ $nn' line")
    return int(m.group(1), 16)


def check_nrget_fixture():
    FIX_PAGE = fixture_equ(FIXTURE, "FIX_PAGE")
    shipped = assemble(FIXTURE)
    want = bytes([0xED, 0xC7, 0x56, 0xED, 0xC7, 0x6B])
    if shipped != want:
        raise Fail(f"shipped NRGET bytes {shipped.hex(' ')}, want {want.hex(' ')}")
    harness = assemble(FIXTURE, "-DNR_STANDIN=1")
    want = bytes([0xCD, 0x56, FIX_PAGE, 0xCD, 0x6B, FIX_PAGE])
    if harness != want:
        raise Fail(f"harness NRGET bytes {harness.hex(' ')}, want {want.hex(' ')}")


# SLD record: file|line|defFile|defLine|page|value|type|data
# name -> (records, the nrs_ symbol the guard must name, or None = clean)
GUARD_CASES = {
    "guard_clean.sld": ("src/hardware.asm|149||0|4|33088|F|nr_read\n"
                        "src/hardware.asm|149||0|4|33088|L|,nr_read,,+used\n"
                        "src/nextdaad.inc|20||0|-1|192|D|NR_INT_CTRL\n"
                        "src/nextdaad.inc|20||0|-1|192|L|,NR_INT_CTRL,,+equ\n", None),
    "guard_f.sld": ("src/hardware.asm|190||0|5|47872|F|nrs_common\n", "nrs_common"),
    "guard_l.sld": ("src/hardware.asm|186||0|5|47616|L|,nrs_sled,,+used\n", "nrs_sled"),
    "guard_d.sld": ("src/hardware.asm|185||0|-1|186|D|NRS_PAGE\n", "NRS_PAGE"),
}


def run_guard(sld):
    """Run Assert-NoStandIn, extracted from build.ps1's own text, on sld.
    Returns (passed, the thrown message or '')."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        raise Fail("pwsh not on PATH: cannot run build.ps1's Assert-NoStandIn")
    script = (
        "$ErrorActionPreference = 'Stop'; "
        f"$ast = [System.Management.Automation.Language.Parser]::ParseFile('{BUILD_PS1}', [ref]$null, [ref]$null); "
        "$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] "
        "-and $n.Name -eq 'Assert-NoStandIn' }, $true); "
        "if (-not $fn) { exit 3 }; "
        ". ([scriptblock]::Create($fn.Extent.Text)); "
        f"try {{ Assert-NoStandIn '{sld}' }} "
        "catch { [Console]::Out.WriteLine('THREW ' + $_.Exception.Message); exit 1 }"
    )
    r = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True)
    if r.returncode == 3:
        raise Fail("build.ps1 has no Assert-NoStandIn function")
    if r.returncode not in (0, 1):
        raise Fail(f"pwsh exit {r.returncode} on {sld.name}:\n{r.stdout}{r.stderr}")
    return r.returncode == 0, r.stdout.strip()


def check_standin_guard():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (body, symbol) in GUARD_CASES.items():
        sld = OUT / name
        sld.write_text("|SLD.data.version|1\n" + body, encoding="utf-8")
        passed, said = run_guard(sld)
        if symbol is None:
            if not passed:
                raise Fail(f"Assert-NoStandIn threw on {name}: {said}")
        elif passed:
            raise Fail(f"Assert-NoStandIn passed {name}")
        elif f"names stand-in symbol {symbol} -" not in said:
            raise Fail(f"Assert-NoStandIn on {name} did not name {symbol}: {said}")


# ---------------------------------------------------------------- executor

TB_SEL, TB_ACC = 0x243B, 0x253B
SP0 = 0xBD00                     # stack for a probe, clear of the stand-in
PUSH = {0xC5: "bc", 0xD5: "de", 0xE5: "hl", 0xF5: "af"}
POP = {0xC1: "bc", 0xD1: "de", 0xE1: "hl", 0xF1: "af"}
IN_C = {0x40: "b", 0x48: "c", 0x50: "d", 0x58: "e", 0x60: "h", 0x68: "l", 0x78: "a"}
OUT_C = {0x41: "b", 0x49: "c", 0x51: "d", 0x59: "e", 0x61: "h", 0x69: "l", 0x79: "a"}


def regval(sel):
    """Value the model's Next register sel holds: distinct for every sel."""
    return (sel * 37 + 11) & 0xFF


class Z80:
    """The opcodes the sled and nrs_common use, nothing more: an unmodelled
    opcode fails, so an edit reaching IX, IY or the alternate set must
    extend this. Flag-writing ops leave random flags, so a kept F is earned.
    Port model: $243B select latch (readable), $253B = regval(latch)."""

    def __init__(self, mem, rng):
        self.m, self.rng = mem, rng

    def r16(self, a):
        return self.m[a] | self.m[(a + 1) & 0xFFFF] << 8

    def pair(self, n):
        return getattr(self, n[0]) << 8 | getattr(self, n[1])

    def setpair(self, n, v):
        setattr(self, n[0], v >> 8 & 0xFF)
        setattr(self, n[1], v & 0xFF)

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.m[self.sp] = v & 0xFF
        self.m[(self.sp + 1) & 0xFFFF] = v >> 8 & 0xFF

    def pop(self):
        v = self.r16(self.sp)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def scramble(self):
        self.f = self.rng.randrange(256)

    def port(self, bc, value=None):
        if self.iff1:
            raise Fail(f"port {bc:04X} accessed with interrupts enabled")
        if value is None and bc == TB_SEL:
            return self.sel
        if value is None and bc == TB_ACC:
            return regval(self.sel)
        if value is not None and bc == TB_SEL:
            self.sel = value
            return None
        raise Fail(f"{'IN from' if value is None else 'OUT to'} unmodelled port {bc:04X}")

    def step(self):
        m, at = self.m, self.pc
        op = m[at]
        self.pc = at + 1
        hl, de = self.pair("hl"), self.pair("de")
        if op == 0x00:
            pass
        elif op in PUSH:
            self.push(self.pair(PUSH[op]))
        elif op in POP:
            self.setpair(POP[op], self.pop())
        elif op in (0xF3, 0xFB):                 # di / ei
            self.iff1 = self.iff2 = int(op == 0xFB)
        elif op in (0xEA, 0xE2):                 # jp pe / jp po
            t = self.r16(self.pc)
            self.pc += 2
            if bool(self.f & 4) == (op == 0xEA):
                self.pc = t
        elif op in (0x01, 0x21):
            self.setpair("bc" if op == 0x01 else "hl", self.r16(self.pc))
            self.pc += 2
        elif op == 0x39:                         # add hl,sp
            self.setpair("hl", hl + self.sp)
            self.scramble()
        elif op == 0x5E:
            self.e = m[hl]
        elif op == 0x56:
            self.d = m[hl]
        elif op == 0x77:
            m[hl] = self.a
        elif op == 0x1A:
            self.a = m[de]
        elif op in (0x23, 0x2B):
            self.setpair("hl", hl + (1 if op == 0x23 else -1))
        elif op == 0x1B:
            self.setpair("de", de - 1)
        elif op in (0x04, 0x05):
            self.b = (self.b + (1 if op == 0x04 else -1)) & 0xFF
            self.scramble()
        elif op == 0xC9:
            self.pc = self.pop()
        elif op == 0xCD:
            t = self.r16(self.pc)
            self.push(self.pc + 2)
            self.pc = t
        elif op == 0xED:
            op2 = m[self.pc]
            self.pc += 1
            if op2 == 0x57:                      # ld a,i: P/V = IFF2, but 0 once on the erratum
                self.a = self.i
                pv = 0 if self.erratum else self.iff2
                self.erratum = False
                self.f = (self.rng.randrange(256) & ~4) | pv << 2
            elif op2 in IN_C:
                setattr(self, IN_C[op2], self.port(self.pair("bc")))
                self.scramble()
            elif op2 in OUT_C:
                self.port(self.pair("bc"), getattr(self, OUT_C[op2]))
            else:
                raise Fail(f"executor: unmodelled ED {op2:02X} at {at:04X}")
        else:
            raise Fail(f"executor: unmodelled opcode {op:02X} at {at:04X}")


def run_probe(mem, probe, reg, iff, erratum, rng, sel=None):
    """Run NRGET reg from the probe table to its halt; raise Fail on any
    broken contract item."""
    cpu = Z80(mem, rng)
    start = probe + 4 * reg
    cpu.pc, cpu.sp = start, SP0
    for n in "afbcdehl":
        setattr(cpu, n, rng.randrange(256))
    cpu.i = rng.randrange(256)
    cpu.iff1 = cpu.iff2 = iff
    cpu.erratum = erratum
    cpu.sel = rng.randrange(256) if sel is None else sel
    kept = {n: getattr(cpu, n) for n in "fbcdehl"}
    sel0, image = cpu.sel, bytes(mem)
    for _ in range(1000):
        if cpu.pc == start + 3:
            break
        cpu.step()
    else:
        raise Fail(f"NRGET ${reg:02X}: no return to the probe")
    tag = f"NRGET ${reg:02X} (interrupts {'on' if iff else 'off'}{', erratum' if erratum else ''})"
    if cpu.a != regval(reg):
        raise Fail(f"{tag}: A = ${cpu.a:02X}, want ${regval(reg):02X}")
    for n, v in kept.items():
        if getattr(cpu, n) != v:
            raise Fail(f"{tag}: {n.upper()} ${v:02X} -> ${getattr(cpu, n):02X}")
    if cpu.sel != sel0:
        raise Fail(f"{tag}: $243B selection ${sel0:02X} -> ${cpu.sel:02X}")
    if (cpu.iff1, cpu.iff2) != (iff, iff):
        raise Fail(f"{tag}: interrupt state {iff} -> {cpu.iff1}")
    if cpu.sp != SP0:
        raise Fail(f"{tag}: SP ${SP0:04X} -> ${cpu.sp:04X}")
    if mem[:SP0 - 16] != image[:SP0 - 16] or mem[SP0:] != image[SP0:]:
        raise Fail(f"{tag}: memory written outside its stack")


def broken(mem, page, pattern, nth):
    """Copy of mem with the nth pattern in nrs_common replaced by NOPs."""
    common = (page + 1) * 256
    at = common - 1
    for _ in range(nth):
        at = mem.find(pattern, at + 1, common + 64)
        if at < 0:
            raise Fail(f"nrs_common has no {pattern.hex(' ')} number {nth} to break")
    m = bytearray(mem)
    m[at:at + len(pattern)] = bytes(len(pattern))
    return m


def nex_bank2(path):
    nex = path.read_bytes()
    pos = 512
    for b in [5, 2, 0, 1, 3, 4] + list(range(6, 112)):
        if nex[18 + b]:
            if b == 2:
                return nex[pos:pos + 16384]
            pos += 16384
    raise Fail(f"{path}: no bank 2")


def check_nrs_exec():
    probe = fixture_equ(EXEC_FIXTURE, "PROBE")
    img = assemble(EXEC_FIXTURE, "-DNR_STANDIN=1")
    mem = bytearray(0x10000)
    mem[0x8000:0x8000 + len(img)] = img
    if mem[probe] != 0xCD:
        raise Fail(f"probe at ${probe:04X} is not a call: NR_STANDIN NRGET missing")
    page = mem[probe + 2]
    rng = random.Random(1)
    runs = 0
    for reg in range(256):
        for iff, erratum in ((0, False), (1, False), (1, True)):
            for _ in range(2):
                run_probe(mem, probe, reg, iff, erratum, rng)
                runs += 1
    for pattern, nth, iff, erratum, sel, want in (
            (b"\xED\x59", 1, 0, False, 0x56 ^ 0xFF, "$243B selection"),
            (b"\xED\x57", 2, 1, True, None, "interrupt state 1 -> 0")):
        try:
            run_probe(broken(mem, page, pattern, nth), probe, 0x56, iff, erratum, rng, sel)
        except Fail as e:
            if want not in str(e):
                raise Fail(f"broken {pattern.hex(' ')} #{nth} failed for another reason: {e}")
        else:
            raise Fail(f"the executor passed nrs_common with {pattern.hex(' ')} #{nth} removed")
    note = f"{runs} runs, 2 broken copies refused"
    if HARNESS_MARK.exists() and NEX.exists():
        lo = page * 256
        if nex_bank2(NEX)[lo - 0x8000:lo - 0x7E00] != bytes(mem[lo:lo + 512]):
            raise Fail(f"build\\nextdaad.nex sled/nrs_common at ${lo:04X} differ from the fixture's")
        note += "; matches build\\nextdaad.nex"
    else:
        note += "; no harness build to compare"
    return note


CHECKS = [check_nrget_fixture, check_standin_guard, check_nrs_exec]


def main():
    failed = 0
    for check in CHECKS:
        try:
            note = check()
            print(f"PASS {check.__name__}" + (f" ({note})" if note else ""))
        except Fail as e:
            failed += 1
            print(f"FAIL {check.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
