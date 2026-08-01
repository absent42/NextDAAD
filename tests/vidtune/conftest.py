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
    """A minimal kit: CONFIG.BAT + VIDEO/ with two dummy sources."""
    (tmp_path / "VIDEO").mkdir()
    (tmp_path / "lib").mkdir()
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
