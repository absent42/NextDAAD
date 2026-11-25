"""BENCH build variant: Release and DEBUG stay byte-identical to the merge base,
the --bench gate passes and catches its two source rules on mutants, and
build.ps1 refuses -Bench with -BenchQuiet."""
import hashlib
import io
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
OUT = ROOT / "tests" / "out"
BASE_DIR = OUT / "core303-base"
BRANCH_DIR = OUT / "core303-branch"
FLAVOURS = {"release": [], "debug": ["-DDEBUG=1"]}


def _git(*args, binary=False):
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True,
                       text=not binary, timeout=120)
    assert r.returncode == 0, r.stderr
    return r.stdout


def _assemble(main_asm, outdir, defs):
    """sjasmplus as build.ps1 runs it, NEX under outdir/build. Returns its sha256."""
    (outdir / "build").mkdir(parents=True, exist_ok=True)
    nex = outdir / "build" / "nextdaad.nex"
    if nex.exists():
        nex.unlink()
    r = subprocess.run(
        [str(SJASM), "--zxnext=cspect", "--msg=war", "--fullpath",
         f"--outprefix={outdir.as_posix()}/", *defs, str(main_asm)],
        cwd=ROOT, capture_output=True, text=True, timeout=300)
    assert r.returncode == 0 and nex.is_file(), (r.stdout + r.stderr)[-2000:]
    return hashlib.sha256(nex.read_bytes()).hexdigest()


@pytest.fixture(scope="module")
def base_src():
    """The merge base's src/, extracted once per base hash (no deletes)."""
    base = _git("merge-base", "HEAD", "main").strip()
    dest = BASE_DIR / base[:12]
    main_asm = dest / "src" / "main.asm"
    if not main_asm.is_file():
        tar = _git("archive", "--format=tar", base, "src", binary=True)
        dest.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(tar)) as tf:
            tf.extractall(dest, filter="data")
    return dest


def _unchanged(base_src, flavour):
    # The premise holds only while src/ is the merge base's: a branch that changes the
    # interpreter (the working tree is what gets assembled) changes these images on purpose.
    base = _git("merge-base", "HEAD", "main").strip()
    if subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", base, "--", "src"],
                      timeout=120).returncode:
        pytest.skip("src/ differs from the merge base %s: the NEX is expected to differ" % base[:12])
    defs = FLAVOURS[flavour]
    want = _assemble(base_src / "src" / "main.asm", base_src / "out" / flavour, defs)
    got = _assemble(ROOT / "src" / "main.asm", BRANCH_DIR / flavour, defs)
    assert got == want, f"{flavour} NEX differs from the merge base"


def test_release_unchanged(base_src):
    _unchanged(base_src, "release")


def test_debug_unchanged(base_src):
    _unchanged(base_src, "debug")


def test_bench_gate():
    r = subprocess.run([sys.executable, str(ROOT / "tests" / "check_quiet_decode.py"),
                        "--bench"], cwd=ROOT, capture_output=True, text=True,
                       timeout=900)
    assert r.returncode == 0, (r.stdout + r.stderr)[-4000:]
    assert "OK: bench" in r.stdout, r.stdout[-2000:]


MUT_DIR = OUT / "core303-mut"
CHECK = ROOT / "tests" / "check_quiet_decode.py"


def _mutant(name, relpath, block):
    """--bench on a copy of src/ with block appended to relpath. No deletes: the
    copy is refreshed in place and the mutated file rewritten from the original."""
    dest = MUT_DIR / name
    shutil.copytree(ROOT / "src", dest / "src", dirs_exist_ok=True)
    (dest / relpath).write_bytes((ROOT / relpath).read_bytes() + block)
    r = subprocess.run([sys.executable, str(CHECK), "--bench", "--src-root", str(dest)],
                       cwd=ROOT, capture_output=True, text=True, timeout=900)
    return r.returncode, r.stdout + r.stderr


def test_gate_other_branch_statement():
    """A non-emitting statement in an IFDEF BENCH other branch fails unless pinned."""
    rc, out = _mutant("other", "src/banks.asm",
                      b"\n IFDEF BENCH\nMUTA equ 5\n ELSE\nMUTA equ 4\n ENDIF\n")
    assert rc == 1, out[-3000:]
    assert re.search(r"src/banks\.asm:\d+: statement in an IFDEF BENCH other branch "
                     r"is not in BENCH_PINNED \| MUTA equ 4", out), out[-3000:]


def test_gate_bench_line_outside_allowed():
    """A BENCH-only statement in shared source fails unless in BENCH_ALLOWED."""
    rc, out = _mutant("shared", "src/print.asm", b"\n IFDEF BENCH\nMUTB equ 1\n ENDIF\n")
    assert rc == 1, out[-3000:]
    assert re.search(r"src/print\.asm:\d+: BENCH-only statement is not in BENCH_ALLOWED "
                     r"\| MUTB equ 1", out), out[-3000:]
    assert "other branch" not in out, out[-3000:]


def test_gate_bench_symbol_conditional():
    """A shared conditional on a symbol defined only on BENCH lines fails."""
    rc, out = _mutant("symbol", "src/banks.asm",
                      b"\n IFDEF BANK_BCH\nMUTC equ 5\n ELSE\nMUTC equ 4\n ENDIF\n")
    assert rc == 1, out[-3000:]
    assert re.search(r"src/banks\.asm:\d+: conditional on BENCH-only symbol BANK_BCH "
                     r"\| IFDEF BANK_BCH", out), out[-3000:]


def test_gate_bench_symbol_elseif():
    """An ELSEIF expression on a BENCH-only symbol fails like an IF."""
    rc, out = _mutant("elseif", "src/banks.asm",
                      b"\n IF 0\nMUTD equ 1\n ELSEIF exist BANK_BCH\nMUTD equ 2\n"
                      b" ELSE\nMUTD equ 3\n ENDIF\n")
    assert rc == 1, out[-3000:]
    assert re.search(r"src/banks\.asm:\d+: conditional on BENCH-only symbol BANK_BCH "
                     r"\| ELSEIF exist BANK_BCH", out), out[-3000:]


def test_sym_def_forms():
    """SYM_DEF captures column-0 symbols, indented labels, DEFINE and DEFINE+."""
    sys.path.insert(0, str(ROOT / "tests"))
    from check_quiet_decode import SYM_DEF
    for line, name in (("MUTE equ 1", "MUTE"), ("    mute_a:", "mute_a"),
                       ("\tmute_b: nop", "mute_b"), ("    DEFINE MUTF 1", "MUTF"),
                       ("    DEFINE+ MUTG 2", "MUTG")):
        m = SYM_DEF.match(line)
        assert m and next(g for g in m.groups() if g) == name, line
    for line in ("    ld a, b", "    jr nz, .x", "    db \"a:b\""):
        assert not SYM_DEF.match(line), line


def test_bench_refuses():
    r = subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "build.ps1"),
                        "-Bench", "-BenchQuiet"], cwd=ROOT, capture_output=True,
                       text=True, timeout=120)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert "-Bench is a Release image" in out, out
