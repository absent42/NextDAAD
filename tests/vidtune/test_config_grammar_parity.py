"""kitmodel.py's CONFIG reader and kitconfig.ps1's Read-KitConfig must
parse the same Latin-1 bytes into the same name->value dict."""
import shutil
import subprocess
from pathlib import Path

import pytest

from vidtune.kitmodel import _read_sets

REPO = Path(__file__).resolve().parents[2]
KITCONFIG_PS1 = REPO / "authoring-kit" / "lib" / "kitconfig.ps1"

PS = shutil.which("pwsh") or shutil.which("powershell")

CONFIG_BAT = (
    "@echo off\r\n"
    "REM comment line\r\n"
    "SET VIDOPTS=--dither=0.3\r\n"
    'set "QUOTED=a b"\r\n'
    "SET BLANK=\r\n"
    "SET   SPACED = x\r\n"
    "SET LEADSPACE= leading\r\n"
    "SET DUP=first\r\n"
    "SET DUP=second\r\n"
    "SET ACCENT=C:\\Jeux\\Donn\xe9es\r\n"
    "SET NEL=a\x85b\r\n"
)

CONFIG_LOCAL_BAT = (
    "SET DUP=third\r\n"
    "SET LOCALONLY=present\r\n"
)

# Output goes to a UTF-8 file: console encodings differ by host and locale.
_PROBE_PS1 = (
    "param([string]$KitConfigPath, [string]$KitRoot, [string]$OutPath)\n"
    ". $KitConfigPath\n"
    "$cfg = Read-KitConfig $KitRoot\n"
    "$lines = @($cfg.GetEnumerator() | Sort-Object Name |"
    " ForEach-Object { \"$($_.Name)=$($_.Value)\" })\n"
    "[IO.File]::WriteAllText($OutPath, ($lines -join \"`n\"),"
    " (New-Object Text.UTF8Encoding $false))\n"
)


@pytest.mark.skipif(PS is None, reason="neither pwsh nor powershell is on PATH")
def test_kitmodel_matches_kitconfig_ps1(tmp_path):
    (tmp_path / "CONFIG.BAT").write_bytes(CONFIG_BAT.encode("latin-1"))
    (tmp_path / "CONFIG.local.BAT").write_bytes(CONFIG_LOCAL_BAT.encode("latin-1"))

    py_vals = {}
    _read_sets(tmp_path / "CONFIG.BAT", py_vals)
    _read_sets(tmp_path / "CONFIG.local.BAT", py_vals)

    probe = tmp_path / "probe.ps1"
    probe.write_text(_PROBE_PS1, newline="")
    out = tmp_path / "probe-out.txt"

    r = subprocess.run(
        [PS, "-NoProfile", "-File", str(probe),
         "-KitConfigPath", str(KITCONFIG_PS1), "-KitRoot", str(tmp_path),
         "-OutPath", str(out)],
        capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr

    ps_vals = {}
    for line in out.read_text(encoding="utf-8").split("\n"):
        if not line:
            continue
        name, _, value = line.partition("=")
        ps_vals[name] = value

    assert "SPACED" not in py_vals and "SPACED" not in ps_vals
    assert py_vals == ps_vals
    assert py_vals["DUP"] == "third"             # last-wins across files
    assert py_vals["LEADSPACE"] == " leading"     # leading space kept
    assert py_vals["QUOTED"] == "a b"
    assert py_vals["VIDOPTS"] == "--dither=0.3"   # '=' inside the value
    assert py_vals["BLANK"] == ""
    assert py_vals["LOCALONLY"] == "present"
    assert py_vals["ACCENT"] == "C:\\Jeux\\Donn\xe9es"  # Latin-1 byte 0xE9
    assert py_vals["NEL"] == "a\x85b"  # 0x85 is not a line break
