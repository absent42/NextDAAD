"""Window torn down while preview decodes are in flight. Qt aborts the
process (0xC0000409 on Windows) when a running QThread is deleted, so each
case runs in a child interpreter and asserts its exit code."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("PySide6")

LIB = Path(__file__).resolve().parents[2] / "authoring-kit" / "lib"

CHILD = r"""
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from PySide6.QtWidgets import QApplication
import shiboken6
from vidtune import previewpane
from vidtune.mainwindow import MainWindow
from vidtune.kitmodel import arg_hash
from vidtune.settingsmodel import build_arg_vector

def slow_decode(path):
    time.sleep(0.3)             # still decoding when the window goes
    raise ValueError("not a vid")
previewpane.decode_vid = slow_decode

app = QApplication([])
kit, how = Path(sys.argv[2]), sys.argv[3]
win = MainWindow(kit)
win.stamp = "pal9k"
for clip in win.clips:
    clip.vid.write_bytes(b"FAKEVID")
    clip.sidecar.write_text(arg_hash("pal9k", build_arg_vector(win.cfg, clip.num3)))
win._populate_clip_list()
for _ in range(3):
    for clip in win.clips:
        win.select_clip(clip.num3)
assert win.preview._threads, "no decode in flight"
if how == "close":
    win.close()
shiboken6.delete(win)
app.processEvents()
print("OK", flush=True)
"""


def _kit(root):
    (root / "VIDEO").mkdir()
    (root / "lib").mkdir()
    (root / "lib" / "video.ps1").write_text("# fixture: no stamp\n")
    for n in ("001", "002", "003"):
        (root / "VIDEO" / f"{n}.mp4").write_bytes(b"x")
    (root / "CONFIG.BAT").write_text(
        "@echo off\r\nSET GAME=\r\nSET TOOLSDIR=tools\r\nSET VIDASPECT=\r\n"
        "SET VIDFPS=\r\nSET VIDOPTS=\r\nSET VIDPROFILE=\r\n", newline="")
    return root


@pytest.mark.parametrize("how", ["delete", "close"])
def test_teardown_during_decode_does_not_abort(tmp_path, how):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    r = subprocess.run([sys.executable, "-c", CHILD, str(LIB), str(_kit(tmp_path)), how],
                       capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode == 0 and "OK" in r.stdout, (r.returncode, r.stdout, r.stderr)
