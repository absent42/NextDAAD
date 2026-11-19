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
check_nex_core       NEX header bytes 135-137 (required core) of
                     build\\nextdaad.nex and build\\intro.nex read 3, 3, 3.
check_gate_first     main runs only di, ld sp and the warm re-entry test before
                     its first call, an unconditional call nz, core_gate
                     (source), and every variant's listing assembles that.
check_gate_once      every variant: core_gate is referenced only by that call,
                     nothing references main, and core_gate and core_refuse
                     sit in the IM2 table area with a first byte that is not
                     the table fill.
check_refuse_closure static call/jp/jr closure of core_gate and core_refuse,
                     fall-through included, over the Release, DEBUG,
                     FORCE_1MB, NXB_QUIET and BENCH listings: every reached
                     routine is in bank 2, its listed bytes match the image,
                     it holds no ED C7 byte pair and no rst, and it is
                     outside the print pipeline. A generated fixture proves
                     the walker, the scan, rst, the allowlist and the image
                     cross-check.

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


# ------------------------------------------------------------- boot gate

NEX_HEADERS = (ROOT / "build" / "nextdaad.nex", ROOT / "build" / "intro.nex")
MAIN_ASM = ROOT / "src" / "main.asm"
INC = ROOT / "src" / "nextdaad.inc"
# main before its gate call: im2_init's fill at IM2_TABLE means a warm re-entry.
GATE_PREFIX = ["di", "ld sp,stack_top", "ld a,(im2_table)", "cp im2_vector_byte"]
# build.ps1's defines per variant; BENCH takes a fixed dummy stamp here.
LST_VARIANTS = {
    "release": (),
    "debug": ("-DDEBUG=1",),
    "force1mb": ("-DDEBUG=1", "-DFORCE_1MB=1"),
    "force1mb-release": ("-DFORCE_1MB=1",),
    "benchquiet": ("-DDEBUG=1", "-DNXB_QUIET=1"),
    "bench": ("-DBENCH=1", "-DBCH_STAMP='0000000'"),
}
# (routine, kind) -> written reason the closure may hold it. kind: "ED C7",
# "rst", "indirect" or "unresolved". Empty: none may.
CLOSURE_ALLOW = {}
# The print pipeline and nr_read: the refusal path must never reach them.
CLOSURE_FORBIDDEN = ("fatal", "txt_init", "tm_width_apply", "windows_init", "win_select",
                     "prn_flush", "prn_glyph", "prn_more_check", "nr_read")
LST_LINE = re.compile(r"\s*\d+\+*\s*([0-9A-F]{4})")
LST_FIELD = re.compile(r"(?:[0-9A-F]{2}(?: [0-9A-F]{2})*(?:\.\.\.)?)?")
DATA_OPS = {"db", "dw", "dd", "defb", "defw", "defd", "defm", "dm", "dz", "dc", "d24",
            "ds", "defs", "block", "incbin", "align", "abyte", "abytec", "abytez"}
ELIDING = {"ds", "defs", "block", "incbin", "align"}
_listings = {}


def check_nex_core():
    for nex in NEX_HEADERS:
        if not nex.exists():
            raise Fail(f"{nex.relative_to(ROOT)} missing: build first")
        core = list(nex.read_bytes()[135:138])
        if core != [3, 3, 3]:
            raise Fail(f"{nex.relative_to(ROOT)} header core {core}, want [3, 3, 3]")
    return "build\\nextdaad.nex, build\\intro.nex"


class Body:
    """A global label's listing lines up to the next global label."""

    def __init__(self, name, addr):
        self.name, self.addr, self.lines, self.next = name, addr, [], None

    def instrs(self):
        """(mnemonic, operands, text) of each line that emits an instruction."""
        for _, _, code, emits, _ in self.lines:
            if emits and code:
                mn, ops = (code.split(None, 1) + [""])[:2]
                mn = mn.lower()
                if mn not in DATA_OPS:
                    yield mn, [o.strip() for o in ops.split(",")] if ops.strip() else [], code

    def ranges(self):
        return [(a, e) for a, e, _, emits, _ in self.lines if emits and e > a]

    def codes(self):
        """Source text of every line that emits bytes."""
        return [code for _, _, code, emits, _ in self.lines if emits and code]


def parse_listing(text):
    """Bodies in assembly order from a sjasmplus --lst. Lines skipped by a false
    conditional (~) are dropped; macro expansion lines (>) are kept."""
    rows = []
    for raw in text.splitlines():
        m = LST_LINE.match(raw)
        if not m:
            continue
        p = m.start(1)
        if raw[p + 5:p + 6] == "~":
            continue
        field = raw[p + 5:p + 17].strip()
        if not LST_FIELD.fullmatch(field):
            raise Fail(f"listing line not understood: {raw}")
        src = raw[p + 18:]
        macro = src.startswith(">")
        code = (src[1:] if macro else src).split(";", 1)[0].rstrip()
        rows.append([int(m.group(1), 16), field, code, macro])
    bodies, cur = [], None
    for i, (addr, field, code, macro) in enumerate(rows):
        nxt = rows[i + 1][0] if i + 1 < len(rows) else addr
        if not macro and re.match(r"[A-Za-z_@]", code):
            lm = re.match(r"([A-Za-z_@][\w@!?.]*):?(.*)$", code)
            rest = lm.group(2).strip()
            if re.match(r"(equ\b|defl\b|=)", rest, re.I):
                continue
            cur = Body(lm.group(1), addr)
            bodies.append(cur)
            code = rest
        code = re.sub(r"^(\.[\w@!?.]*|\d+):?\s*", "", code.strip())   # local or temp label
        mn = (code.split(None, 1) or [""])[0].lower()
        emits = bool(field) or mn in ELIDING
        # Listed bytes give the extent; "..." or none listed (ds, incbin): the next line's address.
        listed = bytes.fromhex(field.rstrip(".").replace(" ", ""))
        end = addr + len(listed) if field and not field.endswith("...") else nxt
        if cur is not None and (field or code):
            cur.lines.append((addr, end if emits else addr, code, emits, listed))
    for a, b in zip(bodies, bodies[1:]):
        a.next = b.name
    return bodies


def listing(tag, src, defines, image_of):
    """Assemble src with --lst in tests/out/corefloor/lst-<tag> (its SAVENEX and
    CSPECTMAP land there, not in build\\). Returns (bodies, bank 2 image)."""
    if tag in _listings:
        return _listings[tag]
    work = OUT / f"lst-{tag}"
    (work / "build").mkdir(parents=True, exist_ok=True)
    lst = work / "main.lst"
    for old in (lst, work / "build" / "nextdaad.nex", work / "build" / "bank2.bin"):
        if old.exists():
            old.unlink()
    r = subprocess.run([str(SJASM), "--zxnext=cspect", "--msg=war", f"--lst={lst.as_posix()}",
                        *defines, Path(src).as_posix()], cwd=work, capture_output=True, text=True)
    if r.returncode != 0 or not lst.exists():
        raise Fail(f"sjasmplus --lst {tag} failed:\n{r.stdout}{r.stderr}")
    _listings[tag] = (parse_listing(lst.read_text(encoding="latin-1")), image_of(work))
    return _listings[tag]


def main_listing(variant):
    return listing(variant, MAIN_ASM, LST_VARIANTS[variant],
                   lambda work: nex_bank2(work / "build" / "nextdaad.nex"))


def check_gate_first():
    lines = MAIN_ASM.read_text(encoding="utf-8").splitlines()
    start = next((i for i, s in enumerate(lines) if re.match(r"main:\s*(;.*)?$", s)), None)
    if start is None:
        raise Fail("src/main.asm has no main: label")
    depth, before, at = 0, [], None
    for i in range(start + 1, len(lines)):
        if re.match(r"[A-Za-z_@]", lines[i]):
            break
        code = lines[i].split(";", 1)[0].strip()
        if not code:
            continue
        word = code.split()[0].lower()
        if word in ("if", "ifdef", "ifndef", "ifused", "ifnused"):
            depth += 1
        elif word == "endif":
            depth -= 1
        elif word in ("else", "elseif"):
            pass
        elif word == "call":
            norm = re.sub(r"\s*,\s*", ",", code.lower())
            if norm != "call nz,core_gate":
                raise Fail(f"src/main.asm:{i + 1}: first call in main is '{code}', want 'call nz, core_gate'")
            if depth:
                raise Fail(f"src/main.asm:{i + 1}: call core_gate is inside a conditional block")
            at = i + 1
            break
        else:
            before.append(re.sub(r"\s*,\s*", ",", code.lower()))
    if at is None:
        raise Fail("main has no call before its next global label")
    if before != GATE_PREFIX:
        raise Fail(f"main runs {before} before call core_gate, want {GATE_PREFIX}")
    want = [("di", []), ("ld", ["sp", "STACK_TOP"]), ("ld", ["a", "(IM2_TABLE)"]),
            ("cp", ["IM2_VECTOR_BYTE"]), ("call", ["nz", "core_gate"])]
    for variant in LST_VARIANTS:
        bodies, _ = main_listing(variant)
        by = {b.name: b for b in bodies}
        if "main" not in by or "core_gate" not in by:
            raise Fail(f"{variant} listing: no main or core_gate label")
        first = [(mn, ops) for mn, ops, _ in list(by["main"].instrs())[:len(want)]]
        if first != want:
            raise Fail(f"{variant} listing: main assembles {first}")
    return f"src/main.asm:{at}, all {len(LST_VARIANTS)} listings agree"


def inc_equ(name):
    m = re.search(rf"^{name}\s+equ\s+\$([0-9A-Fa-f]+)\b", INC.read_text(encoding="utf-8"), re.M)
    if not m:
        raise Fail(f"src/nextdaad.inc: no '{name} equ $nn' line")
    return int(m.group(1), 16)


def check_gate_once():
    """im2_init overwrites the gate: only main's guarded first call may reach it,
    and nothing may call, jump to or take the address of main."""
    table, fill = inc_equ("IM2_TABLE"), inc_equ("IM2_VECTOR_BYTE")
    for variant in LST_VARIANTS:
        bodies, image = main_listing(variant)
        by = {b.name: b for b in bodies}
        refs = [(b.name, re.sub(r"\s*,\s*", ", ", c)) for b in bodies for c in b.codes()
                if re.search(r"\bcore_gate\b", c)]
        if refs != [("main", "call nz, core_gate")]:
            raise Fail(f"{variant}: core_gate referenced by {refs}, want main's call nz, core_gate only")
        mains = [(b.name, c) for b in bodies for c in b.codes() if re.search(r"(?<![\w.@])@?main\b", c)]
        if mains:
            raise Fail(f"{variant}: main is referenced by {mains}")
        for name in ("core_gate", "core_refuse"):
            spans = by[name].ranges()
            lo, hi = min(a for a, _ in spans), max(e for _, e in spans)
            if lo < table or hi > table + 257:
                raise Fail(f"{variant}: {name} ${lo:04X}-${hi:04X} is outside the IM2 table ${table:04X}-${table + 256:04X}")
        if by["core_gate"].addr != table:
            raise Fail(f"{variant}: core_gate at ${by['core_gate'].addr:04X}, want IM2_TABLE ${table:04X}")
        if image[table - 0x8000] == fill:
            raise Fail(f"{variant}: core_gate's first byte is the IM2 fill ${fill:02X}: main's guard would skip it")
    return f"main's call only, main never targeted, gate at ${table:04X} in all {len(LST_VARIANTS)} listings"


def resolve(target, by):
    """('edge', label) | ('local', None) | ('indirect' | 'unresolved', target)."""
    if target.startswith("("):
        return "indirect", target
    if target.startswith(".") or target == "$" or re.fullmatch(r"\$\s*[-+].*|\d+[BbFf]", target):
        return "local", None
    base = target.lstrip("@").split(".", 1)[0]
    return ("edge", base) if base in by else ("unresolved", target)


def terminal(mn, ops):
    return (mn == "ret" and not ops) or mn in ("reti", "retn") or (mn in ("jp", "jr") and len(ops) == 1)


def walk_closure(bodies, roots):
    """Reached bodies (in visit order) and the edges the walk could not follow."""
    by = {b.name: b for b in bodies}
    for r in roots:
        if r not in by:
            raise Fail(f"no {r} label in the listing")
    reached, seen, issues, todo = [], set(), [], list(roots)
    while todo:
        name = todo.pop(0)
        if name in seen:
            continue
        seen.add(name)
        body = by[name]
        reached.append(body)
        last = None
        for mn, ops, code in body.instrs():
            last = (mn, ops)
            if mn in ("call", "jp", "jr", "djnz") and ops:
                kind, target = resolve(ops[-1], by)
                if kind == "edge":
                    todo.append(target)
                elif kind != "local":
                    issues.append((name, kind, code))
            elif mn == "rst":
                issues.append((name, "rst", code))
        if (last is None or not terminal(*last)) and body.next:
            todo.append(body.next)
    return reached, issues


def scan_closure(bodies, image, roots, allow=None):
    """Return (closure text, failures) for the bodies reached from roots. Bytes
    come from the bank 2 image once each listed byte is seen to match it."""
    allow = CLOSURE_ALLOW if allow is None else allow
    reached, issues = walk_closure(bodies, roots)
    failures = [f"{n}: {k} '{c}'" for n, k, c in issues if (n, k) not in allow]
    shown = []
    for body in reached:
        spans = body.ranges()
        lo = min((a for a, _ in spans), default=body.addr)
        hi = max((e for _, e in spans), default=body.addr)
        shown.append(f"{body.name} ${lo:04X}-${hi:04X}")
        if body.name in CLOSURE_FORBIDDEN:
            failures.append(f"{body.name} reached: the refusal path must not enter it")
        if lo < 0x8000 or hi > 0xC000:
            failures.append(f"{body.name} ${lo:04X}-${hi:04X} is outside bank 2")
            continue
        listed = [(a, data) for a, _, _, emits, data in body.lines if emits and data]
        wrong = [a for a, data in listed if image[a - 0x8000:a - 0x8000 + len(data)] != data]
        if wrong:
            failures.append(f"{body.name} ${wrong[0]:04X}: listed bytes differ from bank 2's image")
        elif spans and not listed:
            failures.append(f"{body.name} ${lo:04X}-${hi:04X}: no listed bytes to check the image against")
        if b"\xED\xC7" in image[lo - 0x8000:hi - 0x8000] and (body.name, "ED C7") not in allow:
            failures.append(f"{body.name} ${lo:04X}-${hi:04X} holds ED C7")
    return ", ".join(shown), failures


SELFTEST = """    DEVICE ZXSPECTRUMNEXT
    INCLUDE "{inc}"
    ORG $8000
core_refuse:
    call st_leaf
    jp st_tail
st_leaf:
    ret nz
    rst $08
    jr .out
.out:
    ret
st_tail:
    rst $18
    nop
st_fallen:
    NRGET $56
    ret
st_never:
    rst $08
    NRGET $01
    ret
    SAVEBIN "build/bank2.bin", $8000, $4000
"""
SELFTEST_ALLOW = {("st_tail", "rst"): "self-test: an allowlisted rst is not a failure"}


def check_refuse_closure():
    unexplained = [key for key, reason in CLOSURE_ALLOW.items() if not str(reason).strip()]
    if unexplained:
        raise Fail(f"CLOSURE_ALLOW entries without a written reason: {unexplained}")
    st_dir = OUT / "lst-selftest"
    st_dir.mkdir(parents=True, exist_ok=True)
    st_src = st_dir / "selftest.asm"
    st_src.write_text(SELFTEST.format(inc=INC.as_posix()), encoding="utf-8")
    bodies, image = listing("selftest", st_src, (), lambda work: (work / "build" / "bank2.bin").read_bytes())
    names = sorted(b.name for b in walk_closure(bodies, ["core_refuse"])[0])
    if names != ["core_refuse", "st_fallen", "st_leaf", "st_tail"]:
        raise Fail(f"self-test closure {names}, want core_refuse st_fallen st_leaf st_tail")
    _, failures = scan_closure(bodies, image, ["core_refuse"], SELFTEST_ALLOW)
    kinds = sorted("ED C7" if f.startswith("st_fallen $") and f.endswith(" holds ED C7") else f
                   for f in failures)
    if kinds != ["ED C7", "st_leaf: rst 'rst $08'"]:
        raise Fail(f"self-test scan {failures}, want st_fallen's ED C7 and st_leaf's rst only")
    leaf = next(b for b in bodies if b.name == "st_leaf").addr
    moved = bytearray(image)
    moved[leaf - 0x8000] ^= 0xFF
    _, failures = scan_closure(bodies, bytes(moved), ["core_refuse"], SELFTEST_ALLOW)
    if f"st_leaf ${leaf:04X}: listed bytes differ from bank 2's image" not in failures:
        raise Fail(f"self-test image mismatch not refused: {failures}")
    notes = []
    for variant in LST_VARIANTS:
        bodies, image = main_listing(variant)
        shown, failures = scan_closure(bodies, image, ["core_gate", "core_refuse"])
        print(f"  closure {variant}: {shown}")
        if failures:
            raise Fail(f"{variant}: " + "; ".join(failures))
        notes.append(f"{variant} {shown.count(',') + 1}")
    return "self-test refused ED C7, rst and a moved image; routines " + ", ".join(notes)


CHECKS = [check_nrget_fixture, check_standin_guard, check_nrs_exec,
          check_nex_core, check_gate_first, check_gate_once, check_refuse_closure]


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
