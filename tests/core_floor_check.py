#!/usr/bin/env python3
"""tests/core_floor_check.py - host checks for the core 3.03.03 floor.

check_nrget_fixture  NRGET emits ED C7 n shipped, and a 3-byte call into
                     the stand-in sled page under NR_STANDIN.
check_standin_guard  build.ps1's Assert-NoStandIn throws on an SLD that
                     names an nrs_ symbol and passes a clean one.

Run standalone or via tests\\build-tests.ps1. Exit 0 = every check passed.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SJASM = ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
OUT = ROOT / "tests" / "out" / "corefloor"
FIXTURE = "tests/corefloor/nrget_fixture.asm"
BUILD_PS1 = ROOT / "build.ps1"


class Fail(Exception):
    pass


def assemble(src, *defines):
    """Assemble src (repo-relative) as build.ps1 does; return the bytes the
    source writes with OUTPUT to tests/out/corefloor/<stem>.bin."""
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


def fix_page():
    m = re.search(r"^FIX_PAGE\s+equ\s+\$([0-9A-Fa-f]{2})\s*$",
                  (ROOT / FIXTURE).read_text(encoding="utf-8"), re.M)
    if not m:
        raise Fail(f"{FIXTURE}: no 'FIX_PAGE equ $nn' line")
    return int(m.group(1), 16)


def check_nrget_fixture():
    FIX_PAGE = fix_page()
    shipped = assemble(FIXTURE)
    want = bytes([0xED, 0xC7, 0x56, 0xED, 0xC7, 0x6B])
    if shipped != want:
        raise Fail(f"shipped NRGET bytes {shipped.hex(' ')}, want {want.hex(' ')}")
    harness = assemble(FIXTURE, "-DNR_STANDIN=1")
    want = bytes([0xCD, 0x56, FIX_PAGE, 0xCD, 0x6B, FIX_PAGE])
    if harness != want:
        raise Fail(f"harness NRGET bytes {harness.hex(' ')}, want {want.hex(' ')}")


# SLD record: file|line|defFile|defLine|page|value|type|data
GUARD_CASES = {
    "guard_clean.sld": ("src/hardware.asm|149||0|4|33088|F|nr_read\n"
                        "src/hardware.asm|149||0|4|33088|L|,nr_read,,+used\n", True),
    "guard_f.sld": ("src/hardware.asm|190||0|5|47872|F|nrs_common\n", False),
    "guard_l.sld": ("src/hardware.asm|186||0|5|47616|L|,nrs_sled,,+used\n", False),
    "guard_d.sld": ("src/hardware.asm|185||0|-1|186|D|NRS_PAGE\n", False),
}


def run_guard(sld):
    """Run Assert-NoStandIn, extracted from build.ps1's own text, on sld."""
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
        f"Assert-NoStandIn '{sld}'"
    )
    r = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True)
    if r.returncode == 3:
        raise Fail("build.ps1 has no Assert-NoStandIn function")
    return r.returncode == 0


def check_standin_guard():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (body, clean) in GUARD_CASES.items():
        sld = OUT / name
        sld.write_text("|SLD.data.version|1\n" + body, encoding="utf-8")
        passed = run_guard(sld)
        if passed != clean:
            raise Fail(f"Assert-NoStandIn {'threw on' if clean else 'passed'} {name}")


CHECKS = [check_nrget_fixture, check_standin_guard]


def main():
    failed = 0
    for check in CHECKS:
        try:
            check()
            print(f"PASS {check.__name__}")
        except Fail as e:
            failed += 1
            print(f"FAIL {check.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
