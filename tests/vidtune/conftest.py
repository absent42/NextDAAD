import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))          # vidtune package + nxv2dec/videnc siblings


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "slow: real-encode / integration tests, minutes not ms")


@pytest.fixture
def fixture_kit(tmp_path):
    """A minimal kit: CONFIG.BAT + lib/video.ps1 + VIDEO/ with two dummy
    sources (legacy layout)."""
    (tmp_path / "VIDEO").mkdir()
    (tmp_path / "lib").mkdir()
    (tmp_path / "lib" / "video.ps1").write_text("# fixture: no stamp\n")
    (tmp_path / "VIDEO" / "1.mp4").write_bytes(b"x")
    (tmp_path / "VIDEO" / "002.mp4").write_bytes(b"x")
    (tmp_path / "CONFIG.BAT").write_text(
        "@echo off\r\n"
        "REM comment line\r\n"
        "SET GAME=\r\n"
        "SET TOOLSDIR=tools\r\n"
        "SET VIDASPECT=\r\n"
        "SET VIDFPS=\r\n"
        "SET VIDOPTS=\r\n"
        "SET VIDOPTS_002=--shape 16:9\r\n"
        "SET VIDPROFILE=\r\n",
        newline="")
    return tmp_path


@pytest.fixture
def game_kit(fixture_kit):
    """fixture_kit plus a game folder MYGAME2/ with its own .CFG and VIDEO/."""
    g = fixture_kit / "MYGAME2"
    (g / "VIDEO").mkdir(parents=True)
    (g / "VIDEO" / "001.mp4").write_bytes(b"x")
    (g / "MYGAME2.DSF").write_bytes(b"")
    (g / "MYGAME2.CFG").write_bytes(b"@echo off\r\nSET VIDFPS=\r\n")
    return fixture_kit