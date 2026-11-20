#!/usr/bin/env python3
"""tests/core_floor_check.py - host checks for the core 3.03.03 floor.

check_nrget_fixture  NRGET emits ED C7 n.
check_nex_core       NEX header bytes 135-137 (required core) of
                     build\\nextdaad.nex and build\\intro.nex read 3, 3, 3.
check_gate_first     main runs only di, ld sp and the warm re-entry test before
                     its first call, an unconditional call nz, core_gate
                     (source), and every variant's listing assembles that.
check_gate_once      every variant: each label in the IM2 table area (the gate
                     code, overwritten by im2_init) is named only from gate
                     code, except main's one call nz, core_gate; nothing names
                     main; the gate fits the table and its first byte is not
                     the table fill.
check_refuse_closure static call/jp/jr closure of core_gate and core_refuse,
                     fall-through included, over every variant build.ps1
                     accepts (LST_VARIANTS, combinations included): every reached
                     routine is in bank 2, its listed bytes match the image,
                     it holds no ED C7 byte pair and no rst, and it is
                     outside the print pipeline. A generated fixture proves
                     the walker, the scan, rst, the allowlist and the image
                     cross-check.

check_no_const_nr_read no code line under src/ (not src/intro/) references
                     nr_read: every Next-register read is an NRGET.
check_emulator_launchers tests reach CSpect only through Session.boot, launcher.launch
                     or the nleg helpers: no raw emulator launch, and EMU_LAUNCHERS
                     equals the discovered session users. Self-tested on generated input.
check_extern_fresh   each kit extern assembles to its committed GAME.XBN and
                     STARTER matches the all collection.
check_fade_source    fade.asm source pins: latch read, NRGET + nextreg, API 4
                     gate ordering and the fn 40 refusal.

Run standalone or via tests\\build-tests.ps1. Exit 0 = every check passed.
"""

import ast
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
OUT = ROOT / "tests" / "out" / "corefloor"
FIXTURE = "tests/corefloor/nrget_fixture.asm"


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


def check_nrget_fixture():
    shipped = assemble(FIXTURE)
    want = bytes([0xED, 0xC7, 0x56, 0xED, 0xC7, 0x6B])
    if shipped != want:
        raise Fail(f"NRGET bytes {shipped.hex(' ')}, want {want.hex(' ')}")


def nex_bank2(path):
    nex = path.read_bytes()
    pos = 512
    for b in [5, 2, 0, 1, 3, 4] + list(range(6, 112)):
        if nex[18 + b]:
            if b == 2:
                return nex[pos:pos + 16384]
            pos += 16384
    raise Fail(f"{path}: no bank 2")


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
    "force1mb-benchquiet": ("-DDEBUG=1", "-DFORCE_1MB=1", "-DNXB_QUIET=1"),
    "bench": ("-DBENCH=1", "-DBCH_STAMP='0000000'"),
    "bench-force1mb": ("-DFORCE_1MB=1", "-DBENCH=1", "-DBCH_STAMP='0000000'"),
}
# (routine, kind) -> written reason the closure may hold it. kind: "ED C7",
# "rst", "indirect" or "unresolved". Empty: none may.
CLOSURE_ALLOW = {}
# The print pipeline: the refusal path must never reach it.
CLOSURE_FORBIDDEN = ("fatal", "txt_init", "tm_width_apply", "windows_init", "win_select",
                     "prn_flush", "prn_glyph", "prn_more_check")
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


def names_label(code, name):
    return re.search(rf"(?<![\w.@])@?{re.escape(name)}\b", code) is not None


def check_gate_once():
    """im2_init overwrites the gate: every label in the IM2 table area is named
    only from gate code, bar main's one guarded call nz, core_gate; nothing
    names main."""
    table, fill = inc_equ("IM2_TABLE"), inc_equ("IM2_VECTOR_BYTE")
    for variant in LST_VARIANTS:
        bodies, image = main_listing(variant)
        names = [b.name for b in bodies]
        if "core_gate" not in names:
            raise Fail(f"{variant} listing: no core_gate label")
        first = names.index("core_gate")
        if bodies[first].addr != table:
            raise Fail(f"{variant}: core_gate at ${bodies[first].addr:04X}, want IM2_TABLE ${table:04X}")
        gate = []
        for body in bodies[first:]:
            if not table <= body.addr < table + 257:
                break
            gate.append(body)
        for body in gate:
            hi = max((e for _, e in body.ranges()), default=body.addr)
            if hi > table + 257:
                raise Fail(f"{variant}: {body.name} ends at ${hi:04X}, past the IM2 table ${table:04X}-${table + 256:04X}")
        gate_names = [b.name for b in gate]
        outside = [(b.name, n, re.sub(r"\s*,\s*", ", ", c)) for b in bodies if b not in gate
                   for c in b.codes() for n in gate_names if names_label(c, n)]
        if outside != [("main", "core_gate", "call nz, core_gate")]:
            raise Fail(f"{variant}: gate labels {gate_names} named from outside the gate by {outside}, "
                       "want main's call nz, core_gate only")
        mains = [(b.name, c) for b in bodies for c in b.codes() if names_label(c, "main")]
        if mains:
            raise Fail(f"{variant}: main is referenced by {mains}")
        if image[table - 0x8000] == fill:
            raise Fail(f"{variant}: core_gate's first byte is the IM2 fill ${fill:02X}: main's guard would skip it")
    return (f"gate labels {', '.join(gate_names)} named only from gate code and main's call; "
            f"main never named; {len(LST_VARIANTS)} listings")


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


EMU_LAUNCHERS = [
    "tests/audio/aysreg_check.py",
    "tests/audio/stopm_dump.py",
    "tests/corefloor/refuse_check.py",
    "tests/cursor_dump.py",
    "tests/cycle_dump.py",
    "tests/intro/zes_intro.py",
    "tests/l2pos_check.py",
    "tests/machine_gate.py",
    "tests/parser/nleg.py",
    "tests/parser/parser_selftest.py",
    "tests/parser/parsertest.py",
    "tests/parser/scripts/v3probe/run.py",
    "tests/parser/scripts/zxadj/run.py",
    "tests/poolc/poolc_check.py",
    "tests/spraud_dump.py",
    "tests/sprites_dump.py",
    "tests/text2/console_move_check.py",
    "tests/text2/drive_cspect.py",
    "tests/text2/loader/run_loader_legs.py",
    "tests/txt40_dump.py",
    "tests/typeahead_run.py",
    "tests/xbn/hookshape.py",
    "tests/xbn/namecheck.py",
    "tests/xbn/tickcheck.py",
    "tests/xbn/transcheck.py",
    "tests/xbn/xbnrun.py",
]
# Not session users: the classic-machine drivers, the launcher layer itself
# (it names CSpect.exe), generated output and this file.
EMU_SKIP_DIRS = ("tests/cspect/", "tests/objshare/classic/", "tests/out/")
EMU_SKIP_FILES = ("tests/parser/zleg.py", "tests/parser/zscreen.py", "tests/parser/zrcp.py",
                  "tests/core_floor_check.py")
EMU_NAMES = re.compile(r"zesarux\.exe|--enable-remoteprotocol|CSpect\.exe", re.I)
EMU_BOOT_CALLS = {"cspect.Session.boot", "cspect.session.Session.boot",
                  "cspect.launcher.launch"}
EMU_SPAWNERS = {"subprocess.Popen", "subprocess.run", "subprocess.call", "subprocess.check_call",
                "subprocess.check_output", "os.system", "os.popen"}


def emu_calls(tree, node=None):
    """[(qualified name, Call)] under node (default the module) with the module's import
    aliases resolved: `import subprocess as sp` gives sp.Popen -> subprocess.Popen,
    `from nleg import launch` gives launch -> nleg.launch."""
    alias = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                alias[(a.asname or a.name).split(".")[0]] = a.name if a.asname else a.name.split(".")[0]
        elif isinstance(n, ast.ImportFrom) and n.module:
            for a in n.names:
                alias[a.asname or a.name] = f"{n.module}.{a.name}"
    out = []
    for n in ast.walk(tree if node is None else node):
        if isinstance(n, ast.Call):
            head, _, rest = ast.unparse(n.func).partition(".")
            out.append(((alias[head] + ("." + rest if rest else "")) if head in alias else
                        ast.unparse(n.func), n))
    return out


def names_emulator(call):
    """True when a call's arguments mention an emulator executable (a name or string
    holding zesarux, or a string holding cspect.exe)."""
    for arg in [*call.args, *(k.value for k in call.keywords)]:
        for n in ast.walk(arg):
            if isinstance(n, (ast.Name, ast.Attribute)) and "zesarux" in (n.id if isinstance(n, ast.Name) else n.attr).lower():
                return True
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and (
                    "zesarux" in n.value.lower() or "cspect.exe" in n.value.lower()):
                return True
    return False


def emu_parse(root, f):
    try:
        return ast.parse((root / f).read_text(encoding="utf-8", errors="replace"))
    except SyntaxError as err:
        raise Fail(f"{f}: does not parse: {err}")


def emu_files(root, files=None):
    """Tracked tests/**/*.py outside EMU_SKIP_DIRS and EMU_SKIP_FILES (files: an
    override list, repo-relative)."""
    if files is None:
        r = subprocess.run(["git", "ls-files", "tests"], cwd=root, capture_output=True, text=True)
        files = r.stdout.split()
    return sorted(f for f in files if f.endswith(".py") and not f.startswith(EMU_SKIP_DIRS)
                  and f not in EMU_SKIP_FILES)


def emu_defs(tree):
    """{def or class name: qualified calls inside it} for every def in the module."""
    return {n.name: [q for q, _ in emu_calls(tree, n)] for n in ast.walk(tree)
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}


def emu_launches(q, stem, launching):
    """True when qualified call q boots CSpect: a session/launcher boot call, or a
    def known to (a bare or self. name in this module, or module.name elsewhere)."""
    if q in EMU_BOOT_CALLS:
        return True
    head, _, name = q.rpartition(".")
    mod = head.rpartition(".")[2]
    if not head or head == "self":
        return name in launching.get(stem, ())
    return name in launching.get(mod, ())


def emu_users(root=ROOT, files=None):
    """Sorted tracked test .py files that boot CSpect: they call Session.boot or
    launcher.launch, or a def (nleg.launch, a Leg class, a boot helper) that does,
    resolved to a fixpoint across modules by call."""
    mods = {}
    for f in emu_files(root, files):
        tree = emu_parse(root, f)
        mods[f] = (Path(f).stem, tree, emu_defs(tree))
    launching = {stem: set() for stem, _, _ in mods.values()}
    changed = True
    while changed:
        changed = False
        for stem, _, defs in mods.values():
            for name, qs in defs.items():
                if name not in launching[stem] and any(emu_launches(q, stem, launching) for q in qs):
                    launching[stem].add(name)
                    changed = True
    return sorted(f for f, (stem, tree, _) in mods.items()
                  if any(emu_launches(q, stem, launching) for q, _ in emu_calls(tree)))


def check_emulator_launchers(root=ROOT, listed=None, files=None, selftest=True):
    """Tests reach CSpect only through the session layer: no tracked test .py outside
    the skip lists names zesarux.exe, --enable-remoteprotocol or CSpect.exe, or calls a
    subprocess/os spawner on an emulator executable, and EMU_LAUNCHERS equals the
    discovered users of Session.boot / launcher.launch / the nleg helpers exactly."""
    cases = emu_selftest() if selftest else 0
    listed = EMU_LAUNCHERS if listed is None else listed
    bad = []
    for f in emu_files(root, files):
        text = (root / f).read_text(encoding="utf-8", errors="replace")
        hit = EMU_NAMES.search(text)
        if hit:
            bad.append(f"{f}: names {hit.group(0)}")
        for q, c in emu_calls(emu_parse(root, f)):
            if q in EMU_SPAWNERS and names_emulator(c):
                bad.append(f"{f}: raw {q} call line {c.lineno}")
    found = set(emu_users(root, files))
    bad += [f"{f}: boots CSpect but is not in EMU_LAUNCHERS" for f in sorted(found - set(listed))]
    bad += [f"{f}: in EMU_LAUNCHERS but boots no CSpect" for f in sorted(set(listed) - found)]
    if bad:
        raise Fail("; ".join(bad))
    return f"{len(found)} session users, no raw emulator launch, {cases} self-test cases"


EMU_SELFTEST = {
    "tests/t_zes.py": "import subprocess\nsubprocess.Popen(['zesarux.exe', '--vo', 'null'])\n",
    "tests/t_cspect.py": "import subprocess\nsubprocess.Popen(['x', 'CSpect.exe', '-w1'])\n",
    "tests/t_good.py": "from cspect import Session\nwith Session.boot(a, b, c) as s:\n    pass\n",
    "tests/t_prose.py": "# ZEsarUX drove this before; now CSpect\nx = 1\n",
    "tests/t_helper.py": "import t_good\nt_good.go()\n",
    "tests/t_alias.py": "import subprocess as sp\nsp.run(['tools/zesarux/zesarux', 'x'])\n",
}


def emu_selftest():
    """The check on generated input: a raw ZEsarUX or CSpect.exe launch is flagged, a
    Session.boot user passes, an unlisted user is flagged, prose is not a hit."""
    d = OUT / "emu-selftest"
    if d.exists():
        shutil.rmtree(d)
    (d / "tests").mkdir(parents=True)
    for rel, body in EMU_SELFTEST.items():
        (d / rel).write_text(body, encoding="utf-8")
    (d / "tests/t_good.py").write_text(
        "from cspect import Session\ndef go():\n    with Session.boot(a, b, c) as s:\n        pass\n",
        encoding="utf-8")

    def verdict(*names, listed):
        try:
            check_emulator_launchers(d, listed, [f"tests/{n}.py" for n in names], selftest=False)
        except Fail as e:
            return str(e)
        return ""

    got = verdict("t_zes", listed=[])
    if "t_zes.py: names zesarux.exe" not in got:
        raise Fail(f"self-test: a zesarux.exe launch was not flagged: {got!r}")
    got = verdict("t_cspect", listed=[])
    if "t_cspect.py: names CSpect.exe" not in got or "raw subprocess.Popen" not in got:
        raise Fail(f"self-test: a CSpect.exe Popen was not flagged: {got!r}")
    got = verdict("t_alias", listed=[])
    if "raw subprocess.run" not in got:
        raise Fail(f"self-test: an aliased spawner on zesarux was not flagged: {got!r}")
    got = verdict("t_good", listed=["tests/t_good.py"])
    if got:
        raise Fail(f"self-test: a Session.boot user was refused: {got!r}")
    got = verdict("t_good", listed=[])
    if "t_good.py: boots CSpect but is not in EMU_LAUNCHERS" not in got:
        raise Fail(f"self-test: an unlisted session user was not flagged: {got!r}")
    got = verdict("t_good", "t_helper", listed=["tests/t_good.py"])
    if "t_helper.py: boots CSpect but is not in EMU_LAUNCHERS" not in got:
        raise Fail(f"self-test: an unlisted helper caller was not flagged: {got!r}")
    got = verdict("t_prose", listed=[])
    if got:
        raise Fail(f"self-test: prose naming ZEsarUX was flagged: {got!r}")
    got = verdict("t_prose", listed=["tests/t_prose.py"])
    if "in EMU_LAUNCHERS but boots no CSpect" not in got:
        raise Fail(f"self-test: a stale list entry was not flagged: {got!r}")
    return 8


NR_READ_CODE = re.compile(r"\bnr_read\b")


def code_part(line):
    """The line up to the first ';' outside single or double quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == ";":
            return line[:i]
    return line


def check_no_const_nr_read(root=ROOT):
    """nr_read is gone: no code line under src/ (not src/intro/) names it, so
    every Next-register read is an NRGET."""
    bad = []
    for f in sorted((root / "src").rglob("*")):
        if f.suffix not in (".asm", ".inc") or "intro" in f.relative_to(root / "src").parts:
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if NR_READ_CODE.search(code_part(line)):
                bad.append(f"{f.relative_to(root).as_posix()}:{n}")
    if bad:
        raise Fail("nr_read still referenced: " + ", ".join(bad))
    return "no nr_read reference outside src/intro"


KIT = ROOT / "authoring-kit"
KIT_EXTERNS = ["all", "clock", "fade", "hints", "playername", "realtime",
               "ticker", "timer", "toolkit", "transcript"]
FRESH = ROOT / "tests" / "out" / "xbnfresh"


def check_extern_fresh():
    """Each kit extern assembles to exactly its committed GAME.XBN, and
    STARTER\\GAME.XBN is a byte copy of externs\\all\\GAME.XBN."""
    bad = []
    for name in KIT_EXTERNS:
        out = FRESH / name
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        src = KIT / "externs" / name / (name + ".asm")
        r = subprocess.run([str(SJASM), "--msg=war", "-I", str(KIT), str(src)],
                           cwd=out, capture_output=True, text=True)
        built = out / "GAME.XBN"
        if r.returncode != 0 or not built.exists():
            raise Fail(f"{name}: assembly failed:\n" + r.stdout + r.stderr)
        if built.read_bytes() != (KIT / "externs" / name / "GAME.XBN").read_bytes():
            bad.append(name)
    if bad:
        raise Fail("committed GAME.XBN differs from a fresh build: " + ", ".join(bad))
    if (KIT / "STARTER" / "GAME.XBN").read_bytes() != (KIT / "externs" / "all" / "GAME.XBN").read_bytes():
        raise Fail("STARTER\\GAME.XBN is not a copy of externs\\all\\GAME.XBN")
    return f"{len(KIT_EXTERNS)} externs byte-identical to a fresh build, STARTER matches all"


FADE_IN_C = re.compile(r"\bin\s+[abcdehl]\s*,\s*\(\s*c\s*\)", re.I)


def fade_source_problems(text):
    """Problems in fade.asm source text; empty when it is clean."""
    lines = [code_part(l).strip() for l in text.splitlines()]
    bad = []
    for i, l in enumerate(lines):
        if FADE_IN_C.search(l):
            prev = next((p for p in reversed(lines[:i]) if p), "")
            if not re.fullmatch(r"ld\s+bc\s*,\s*TB_SELECT", prev, re.I):
                bad.append(f"line {i + 1}: in r,(c) that is not the $243B latch read: {l}")
    for label in ("apply", "apply9"):
        start = lines.index(label + ":")
        end = next(i for i in range(start, len(lines)) if lines[i] == "ret")
        body = lines[start:end + 1]
        if "NRGET NR_PAL_CTL" not in body:
            bad.append(f"{label}: NR $43 is not read with NRGET")
        if sum(bool(re.fullmatch(r"nextreg\s+NR_PAL_CTL\s*,\s*a", l, re.I)) for l in body) != 2:
            bad.append(f"{label}: NR $43 must be written with nextreg twice (edit, restore)")
        if any(re.fullmatch(r"ld\s+a\s*,\s*NR_PAL_CTL", l, re.I) for l in body):
            bad.append(f"{label}: NR $43 selected through a port (ld a, NR_PAL_CTL)")
    if not any(re.fullmatch(r"MIN_API\s+equ\s+4", l, re.I) for l in lines):
        bad.append("no MIN_API equ 4")
    try:
        ext = lines.index("ext:")
        first = next(i for i in range(ext, len(lines))
                     if re.fullmatch(r"jr\s+z\s*,\s*\.fadeout", lines[i], re.I))
        body = [l for l in lines[ext:first] if l]
        norm = [re.sub(r"\s+", " ", l.lower()) for l in body]
        ver = next(i for i, l in enumerate(norm) if l == "call svc_version")
        guard = ["ld a, c", "cp 40", "jr c, .notmine", "cp 44", "jr nc, .notmine"]
        if not any(norm[i:i + 5] == guard for i in range(ver)):
            bad.append("ext: the fn 40-43 range guard does not precede call SVC_VERSION")
        if norm[ver + 1] != "cp min_api":
            raise StopIteration
        ok = next(i for i, l in enumerate(norm) if l == ".apiok:")
        refusal = norm[ver + 2:ok]
        refused = ["ld a, c", "cp 40", "jp z, .refused"]
        if not any(refusal[i:i + 3] == refused for i in range(len(refusal))):
            bad.append("ext: refusal is not ld a, c / cp 40 / jp z, .refused (flag 240)")
    except StopIteration:
        bad.append("ext: call SVC_VERSION / cp MIN_API does not precede the function dispatch")
    return bad


def check_fade_source():
    """fade.asm: the only in r,(c) is the $243B latch read straight after
    ld bc, TB_SELECT; apply and apply9 read NR $43 with NRGET, write it back
    with nextreg and never select it through a port; ext checks the API
    (call SVC_VERSION / cp MIN_API) before dispatch and a refused fn 40 goes
    to .refused, which sets flag 240."""
    text = (KIT / "externs" / "fade" / "fade.asm").read_text(encoding="utf-8")
    bad = fade_source_problems(text)
    if bad:
        raise Fail("; ".join(bad))
    return "latch read only, NRGET + nextreg in apply/apply9, API 4 gate with fn 40 refusal"


CHECKS = [check_nrget_fixture, check_nex_core, check_gate_first, check_gate_once,
          check_refuse_closure, check_emulator_launchers, check_no_const_nr_read,
          check_extern_fresh, check_fade_source]


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
