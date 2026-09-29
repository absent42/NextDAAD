import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from vidtune.mainwindow import MainWindow

pytestmark = pytest.mark.skipif(sys.platform == "win32",
                                reason="PATH fallback is non-Windows only (kittools.ps1 Find-OnPath)")


def _fake_ffmpeg(d):
    d.mkdir(parents=True, exist_ok=True)
    exe = d / "ffmpeg"
    exe.write_text("#!/bin/sh\nexit 0\n")
    exe.chmod(0o755)
    return exe


def _resolve(kit, toolsdir="tools", ffmpegdir=""):
    host = SimpleNamespace(kit_root=kit, cfg=SimpleNamespace(toolsdir=toolsdir, ffmpegdir=ffmpegdir))
    return MainWindow._resolve_ffmpeg(host)


def test_path_fallback_when_folders_empty(tmp_path, monkeypatch):
    onpath = _fake_ffmpeg(tmp_path / "bin")
    monkeypatch.setenv("PATH", str(onpath.parent) + os.pathsep + os.environ.get("PATH", ""))
    assert _resolve(tmp_path / "kit") == onpath


def test_ffmpegdir_wins_over_path(tmp_path, monkeypatch):
    onpath = _fake_ffmpeg(tmp_path / "bin")
    monkeypatch.setenv("PATH", str(onpath.parent) + os.pathsep + os.environ.get("PATH", ""))
    own = _fake_ffmpeg(tmp_path / "kit" / "alt" / "bin")
    assert _resolve(tmp_path / "kit", ffmpegdir="alt") == own


def test_toolsdir_ffmpeg_wins_over_path(tmp_path, monkeypatch):
    onpath = _fake_ffmpeg(tmp_path / "bin")
    monkeypatch.setenv("PATH", str(onpath.parent) + os.pathsep + os.environ.get("PATH", ""))
    own = _fake_ffmpeg(tmp_path / "kit" / "tools" / "ffmpeg" / "bin")
    assert _resolve(tmp_path / "kit") == own


def test_nothing_found_names_the_kit_folder(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    assert _resolve(tmp_path / "kit") == Path(tmp_path / "kit" / "tools" / "ffmpeg" / "bin" / "ffmpeg")
