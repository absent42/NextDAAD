# tests/vidtune/test_golden_roundtrip.py
"""After a headless model-layer Accept, the kit's real video.ps1 must
find nothing stale. This is the byte-compatibility proof for the arg
vector + sidecar hash pipeline. Slow (one real encode) and Windows-only;
skipped when ffmpeg or the demo clip is missing."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from vidtune.configwrite import write_sidecar, write_vidopts_line
from vidtune.encoderun import resolve_encoder
from vidtune.kitmodel import (list_clips, parse_config, read_generation_stamp)
from vidtune.settingsmodel import build_arg_vector

REPO = Path(__file__).resolve().parents[2]
KIT = REPO / "authoring-kit"
FFMPEG = KIT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(sys.platform != "win32", reason="video.ps1 is Windows"),
    pytest.mark.skipif(not FFMPEG.is_file(), reason="kit ffmpeg missing"),
]


def test_accept_then_video_ps1_finds_nothing_stale(tmp_path):
    # 1. Miniature kit: real scripts + one real demo source, tiny encode.
    (tmp_path / "lib").mkdir(); (tmp_path / "VIDEO").mkdir()
    (tmp_path / "tools").mkdir()
    for f in ("video.ps1", "videnc.py", "nxv2enc.py", "nxv2dec.py"):
        shutil.copy(KIT / "lib" / f, tmp_path / "lib" / f)
    shutil.copytree(KIT / "tools" / "ffmpeg", tmp_path / "tools" / "ffmpeg")
    src = KIT / "VIDEO" / "002.mp4"
    if not src.is_file():
        pytest.skip("kit demo clip missing")
    shutil.copy(src, tmp_path / "VIDEO" / "001.mp4")
    (tmp_path / "CONFIG.BAT").write_text(
        "SET TOOLSDIR=tools\r\nSET VIDASPECT=\r\nSET VIDFPS=\r\n"
        "SET VIDOPTS=\r\nSET VIDPROFILE=\r\n", newline="")

    # 2. Headless "tune + accept": set a per-clip option, encode with the
    #    exact arg vector, write sidecar.
    write_vidopts_line(tmp_path / "CONFIG.BAT", "001",
                       "--shape classic --duration 1")
    cfg = parse_config(tmp_path / "CONFIG.BAT")
    stamp = read_generation_stamp(tmp_path)
    assert stamp is not None
    clip = list_clips(tmp_path)[0]
    argv = build_arg_vector(cfg, "001")
    enc = resolve_encoder(tmp_path, cfg.toolsdir)
    assert enc is not None
    r = subprocess.run(enc + [str(clip.mp4), str(clip.vid),
                              "--ffmpeg", str(FFMPEG)] + argv,
                       capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, r.stdout + r.stderr
    write_sidecar(clip.sidecar, stamp, argv)
    vid_bytes = clip.vid.read_bytes()

    # 3. The kit's own encode pass must see a fresh cache: video.ps1
    #    exits 0 without re-encoding (the .vid is byte-identical after).
    env_ps = (f"$env:TOOLSDIR='tools'; $env:VIDASPECT=''; $env:VIDFPS='';"
              f"$env:VIDOPTS=''; $env:VIDPROFILE='';"
              f"$env:VIDOPTS_001='--shape classic --duration 1';"
              f"& '{tmp_path / 'lib' / 'video.ps1'}'")
    r2 = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy",
                         "Bypass", "-Command", env_ps],
                        cwd=tmp_path, capture_output=True, text=True,
                        timeout=600)
    assert r2.returncode == 0, r2.stdout + r2.stderr
    assert "encoding" not in r2.stdout        # nothing was stale
    assert clip.vid.read_bytes() == vid_bytes # cache untouched

    # 4. Negative control: exit 0 + no "encoding" + untouched bytes is
    #    also what a video.ps1 that saw ZERO sources (e.g. a cwd
    #    regression in the subprocess.run above) would produce, so phase
    #    3 alone cannot tell "cache judged fresh" from "harness never
    #    looked". Delete the sidecar to force staleness and re-run the
    #    identical invocation: only a video.ps1 that actually found and
    #    re-priced VIDEO\001.mp4 can print "encoding" and rewrite the
    #    sidecar, so this proves phase 3's silence meant fresh, not blind.
    clip.sidecar.unlink()
    r3 = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy",
                         "Bypass", "-Command", env_ps],
                        cwd=tmp_path, capture_output=True, text=True,
                        timeout=600)
    assert r3.returncode == 0, r3.stdout + r3.stderr
    assert "encoding" in r3.stdout            # forced-stale re-encode fired
    assert clip.sidecar.is_file()             # video.ps1 rewrote the sidecar
