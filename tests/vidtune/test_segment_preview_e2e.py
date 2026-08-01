# tests/vidtune/test_segment_preview_e2e.py
"""Regression for the owner-reported crash (2026-08-01): Set In (past
frame 0), Set Out, Preview Segment -> the real encode succeeds, then the
post-encode Flicker/Heatmap source re-extraction (_extract_matching_source)
used to hand a raw Python float `start` seconds value into
videnc.extract_video's -ss arg, which subprocess.run rejects with
"TypeError: expected str, bytes or os.PathLike object, not float" (fixed
in preview.extract_source - see its docstring). test_preview.py covers
the argv-type-safety half of the regression at the unit level with a
monkeypatched extract_video; this file is the full-flow half: a REAL
MainWindow, a REAL EncodeJob subprocess (videnc + ffmpeg), driven exactly
the way the owner's repro was, proving end to end that (a) the previously
crashing extraction now succeeds with real frames and no error label, and
(b) the process survives the whole flow (the "app crashes and is
relaunched" part of the report could not be reproduced even WITH the bug
present - see the report for details - but this pins the flow as a
standing regression guard either way).

Slow (one real encode) and Windows-only; skipped when ffmpeg or the demo
clip is missing - same skip pattern as test_golden_roundtrip.py.
"""
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

REPO = Path(__file__).resolve().parents[2]
KIT = REPO / "authoring-kit"
FFMPEG = KIT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"
DEMO_CLIP = KIT / "VIDEO" / "002.mp4"

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(sys.platform != "win32", reason="kit tooling is Windows"),
    pytest.mark.skipif(not FFMPEG.is_file(), reason="kit ffmpeg missing"),
    pytest.mark.skipif(not DEMO_CLIP.is_file(), reason="kit demo clip missing"),
]


@pytest.fixture
def temp_mini_kit(tmp_path):
    (tmp_path / "VIDEO").mkdir()
    (tmp_path / "lib").mkdir()
    for name in ("video.ps1", "videnc.py", "nxv2enc.py", "nxv2dec.py"):
        shutil.copyfile(KIT / "lib" / name, tmp_path / "lib" / name)
    shutil.copyfile(DEMO_CLIP, tmp_path / "VIDEO" / "001.mp4")
    (tmp_path / "CONFIG.BAT").write_text(
        "@echo off\r\n"
        f"SET TOOLSDIR={KIT / 'tools'}\r\n"
        "SET VIDASPECT=\r\n"
        "SET VIDFPS=\r\n"
        "SET VIDOPTS=\r\n"
        "SET VIDPROFILE=\r\n",
        newline="")
    return tmp_path


def test_set_in_out_then_preview_segment_does_not_crash(temp_mini_kit, qtbot):
    from vidtune.mainwindow import MainWindow

    win = MainWindow(temp_mini_kit)
    qtbot.addWidget(win)
    assert win.encoder_argv is not None, "encoder not resolved"
    assert Path(win.ffmpeg).is_file(), f"ffmpeg not found at {win.ffmpeg}"

    win.select_clip("001")
    s = win.settings_panel.get_settings()
    s["duration"] = "2"
    s["shape"] = "classic"
    win.settings_panel.set_settings(s, win.kit_base)

    # Fake frames purely so seek()/set_in()/set_out() have something to
    # index into (preview_argv only reads seg_in/seg_out frame indices,
    # never pixel data) - a NONZERO seg_in is essential here: frame 0
    # gives a start of 0.0 seconds, which is falsy and never reaches
    # videnc.extract_video's -ss branch at all, so the bug would not
    # reproduce.
    win.preview.set_frames(encoded=[np.zeros((8, 8, 3), np.uint8)] * 25,
                           source=None, fps=25, column_major=False)
    win.preview.seek(3)
    win.preview.set_in()
    win.preview.seek(15)
    win.preview.set_out()

    argv_preview = win.preview_argv("001")
    assert "--start" in argv_preview and "0.12" in argv_preview

    win.on_preview_segment()
    job = win._job
    assert job is not None, "preview segment job did not start"
    with qtbot.waitSignal(job.finished, timeout=300000) as blocker:
        pass
    code, report = blocker.args
    assert code == 0, ("preview segment encode failed:\n"
                       + win.metrics_bar._failure_box.toPlainText())

    # This is the moment _on_preview_success -> _load_preview ->
    # _extract_matching_source runs (synchronously, on the GUI thread) -
    # the previously-crashing call. No error label.
    assert win._last_source_error is None, win._last_source_error
    assert win.preview._error_label.isVisibleTo(win.preview) is False

    # The extracted source frames are handed to preview.load() as
    # source_frames, but load() decodes the just-encoded .vid on its own
    # QThread first and only calls set_frames() (which actually sets
    # self.source) once that decode completes - wait on the actual
    # condition (source populated), not on the busy label's isVisible():
    # the top-level window is never shown() in this headless test, and
    # QWidget.isVisible() (unlike isVisibleTo()) requires the whole
    # ancestor chain including the top-level window to be shown, so it
    # would read False from the very start regardless of decode state.
    qtbot.waitUntil(lambda: win.preview.source is not None, timeout=15000)
    assert len(win.preview.source) > 0
    assert win.preview.encoded is not None and len(win.preview.encoded) > 0

    # Process is still alive and the window still responds - the
    # "crashes and is relaunched" half of the owner's report, to the
    # extent it is reproducible at all in this harness: any further
    # method call succeeding at all (rather than the interpreter having
    # already aborted) is the proof.
    win.select_clip("001")
    assert win.clip_list.count() == 1
    win.close()
