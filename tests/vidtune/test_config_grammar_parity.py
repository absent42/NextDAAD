"""Shared-grammar proof: kitmodel.py's CONFIG reader and kitconfig.ps1's
Read-KitConfig must parse the same bytes into the same name->value dict.
Fed one CONFIG.BAT + CONFIG.local.BAT covering the grammar's edge cases
(embedded '=', quoted form, blank value, a name/'=' split by a space -
which matches neither reader, a leading space kept after '=', and
last-wins within and across the two files)."""
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
)

CONFIG_LOCAL_BAT = (
    "SET DUP=third\r\n"
    "SET LOCALONLY=present\r\n"
)

_PROBE_PS1 = (
    "param([string]$KitConfigPath, [string]$KitRoot)\n"
    ". $KitConfigPath\n"
    "$cfg = Read-KitConfig $KitRoot\n"
    "$cfg.GetEnumerator() | Sort-Object Name |"
    " ForEach-Object { Write-Output \"$($_.Name)=$($_.Value)\" }\n"
)


@pytest.mark.skipif(PS is None, reason="neither pwsh nor powershell is on PATH")
def test_kitmodel_matches_kitconfig_ps1(tmp_path):
    (tmp_path / "CONFIG.BAT").write_bytes(CONFIG_BAT.encode())
    (tmp_path / "CONFIG.local.BAT").write_bytes(CONFIG_LOCAL_BAT.encode())

    py_vals = {}
    _read_sets(tmp_path / "CONFIG.BAT", py_vals)
    _read_sets(tmp_path / "CONFIG.local.BAT", py_vals)

    probe = tmp_path / "probe.ps1"
    probe.write_text(_PROBE_PS1, newline="")

    r = subprocess.run(
        [PS, "-NoProfile", "-File", str(probe),
         "-KitConfigPath", str(KITCONFIG_PS1), "-KitRoot", str(tmp_path)],
        capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr

    ps_vals = {}
    for line in r.stdout.splitlines():
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
