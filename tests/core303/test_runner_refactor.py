import hashlib
import io
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
BENCH = HERE / "bench"
OUT = ROOT / "tests" / "out"
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
NEX = ROOT / "build" / "core303" / "CORE303.NEX"
MODULES = ["rowdefs.asm", "runner.asm", "runner_data.asm", "isrstubs.asm"]


def _git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True,
                          timeout=60, check=True).stdout


def _base_nex():
    base = OUT / "p2-base"
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True)
    mb = _git("merge-base", "HEAD", "main").decode().strip()
    data = _git("archive", mb, "tests/core303/bench", "src/font.chr")
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        tf.extractall(base)
    res = subprocess.run(
        [str(SJASM), "--zxnext=cspect", "--msg=war", "-DSTAMP_STR='TEST'",
         "--lst=CORE303.lst", str(base / "tests/core303/bench/core303.asm")],
        cwd=base, capture_output=True, text=True, timeout=180)
    assert res.returncode == 0, res.stdout + res.stderr
    return base / "CORE303.NEX"


def test_core303_nex_unchanged():
    for m in MODULES:
        assert (BENCH / m).is_file(), m
    base_nex = _base_nex()
    res = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(BENCH / "build.ps1"),
         "-Stamp", "TEST", "-AllowDirty"],
        capture_output=True, text=True, timeout=180)
    assert res.returncode == 0, res.stdout + res.stderr
    h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    assert h(base_nex) == h(NEX)


def test_modules_assemble_standalone():
    OUT.mkdir(parents=True, exist_ok=True)
    src = OUT / "p2-min.asm"
    b = str(BENCH).replace("\\", "/")
    src.write_text(
        '    DEVICE ZXSPECTRUMNEXT\n'
        '    DEFINE STAMP_STR \'TEST\'\n'
        '    INCLUDE "%s/rowdefs.asm"\n'
        '    ORG $8000\n'
        'main:\n'
        '    di\n'
        '    ld sp, STACK_TOP\n'
        '    ld hl, rowTable\n'
        '    call run_table\n'
        '    halt\n'
        '    INCLUDE "%s/clock.asm"\n'
        '    INCLUDE "%s/log.asm"\n'
        '    INCLUDE "%s/probe.asm"\n'
        '    INCLUDE "%s/irq.asm"\n'
        '    INCLUDE "%s/dma.asm"\n'
        '    INCLUDE "%s/ops.asm"\n'
        '    INCLUDE "%s/runner.asm"\n'
        'rowTable:\n'
        '    ROW "CAL0", 1, $FFFF, 0, 3, CPU, row_go, row_empty, 0\n'
        '    db 0\n'
        '    INCLUDE "%s/runner_data.asm"\n'
        '    INCLUDE "%s/isrstubs.asm"\n'
        '    SAVENEX OPEN "p2-min.nex", main, STACK_TOP\n'
        '    SAVENEX CORE 3, 0, 0\n'
        '    SAVENEX CFG 0\n'
        '    SAVENEX AUTO\n'
        '    SAVENEX CLOSE\n' % ((b,) * 10),
        encoding="ascii")
    res = subprocess.run(
        [str(SJASM), "--zxnext=cspect", "--msg=war", str(src)],
        cwd=OUT, capture_output=True, text=True, timeout=180)
    assert res.returncode == 0, res.stdout + res.stderr
    assert (OUT / "p2-min.nex").is_file()


def test_runner_data_has_font_bytes():
    t = (BENCH / "runner_data.asm").read_text(encoding="ascii")
    assert "INCBIN" in t
    assert "ASSERT $ - font == 96 * 8" in t


def test_isrstubs_has_no_savenex():
    assert "SAVENEX" not in (BENCH / "isrstubs.asm").read_text(encoding="ascii")
    core = (BENCH / "core303.asm").read_text(encoding="ascii")
    assert 'SAVENEX OPEN "CORE303.NEX"' in core
    assert "ASSERT $ <= CODE_LIMIT" in core
    assert "ASSERT LOG_HDR_MAX + ROW_TOTAL * LOG_ROW_MAX + LOG_END_MAX <= LOG_CAP" in core
    assert "ASSERT LOG_PAGE > OPS_LAST_PAGE" in core
