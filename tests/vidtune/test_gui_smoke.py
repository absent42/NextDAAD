import threading
from pathlib import Path

import numpy as np
from PySide6.QtCore import QObject, QThread, QTimer, Signal
from PySide6.QtGui import QDoubleValidator
from PySide6.QtWidgets import QApplication

from vidtune import mainwindow as vt_mainwindow
from vidtune.mainwindow import MainWindow, PreviewPane, SettingsPanel
from vidtune.encoderun import MetricsSummary
from vidtune.kitmodel import KitConfig, arg_hash, clip_state
from vidtune.settingsmodel import build_arg_vector, effective_settings


def test_window_populates_clip_list(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    texts = [win.clip_list.item(i).text() for i in range(win.clip_list.count())]
    assert len(texts) == 2
    assert texts[0].startswith("001")
    assert "stale" in texts[0]            # no .vid exists yet


def test_settings_panel_roundtrip(fixture_kit, qtbot):
    cfg = KitConfig()
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())
    assert panel.get_settings()["dither"] == "0.5"


def test_clip_switch_preserves_session_edits(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    s = win.settings_panel.get_settings()
    s["dither"] = "0.2"
    win.settings_panel.set_settings(s, win.kit_base)
    win.select_clip("002")
    win.select_clip("001")
    assert win.settings_panel.get_settings()["dither"] == "0.2"


def test_advanced_group_collapses(fixture_kit, qtbot):
    cfg = KitConfig()
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())

    assert panel._advanced_content.isVisibleTo(panel) is False

    panel._advanced_group.setChecked(True)
    assert panel._advanced_content.isVisibleTo(panel) is True

    panel._advanced_group.setChecked(False)
    assert panel._advanced_content.isVisibleTo(panel) is False


def test_float_validator_uses_c_locale(fixture_kit, qtbot):
    cfg = KitConfig()
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())

    validator = panel._rows["dither"]["widget"].validator()
    assert validator.validate("0.5", 3)[0] == QDoubleValidator.Acceptable
    assert validator.locale().decimalPoint() == "."


def _frames(n, h=8, w=8):
    # (i * 10) % 256, not i * 10: numpy 2.x raises OverflowError building
    # a uint8 array from a Python int fill value outside 0..255, and the
    # segment-marker test below needs n=50 (i * 10 reaches 490 unmodded).
    return [np.full((h, w, 3), (i * 10) % 256, np.uint8) for i in range(n)]


def test_preview_modes_and_transport(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(5), source=_frames(5), fps=25,
                    column_major=False)
    assert pane.frame_index == 0
    pane.step(+1)
    assert pane.frame_index == 1
    pane.set_mode("Flicker")
    shown_before = pane.showing_source
    pane.toggle_flicker()
    assert pane.showing_source != shown_before
    pane.set_mode("Heatmap")          # both sides present: allowed
    assert pane.mode == "Heatmap"


def test_preview_segment_markers(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(50), source=None, fps=25,
                    column_major=False)
    pane.seek(10); pane.set_in()
    pane.seek(30); pane.set_out()
    assert pane.segment_times(25.0) == (0.4, 0.8)   # (start_s, duration_s)


def test_heatmap_disabled_without_source(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(3), source=None, fps=25,
                    column_major=False)
    pane.set_mode("Heatmap")
    assert pane.mode == "Encoded"     # refused, falls back


def test_load_generation_guard_ignores_stale_decode(qtbot):
    # Simulates a second load() starting before a first decode lands:
    # _load_gen has moved on by the time the stale worker's result
    # arrives, so _on_decode_done/_on_decode_failed must drop it
    # instead of clobbering the current frames.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(2), source=None, fps=25,
                    column_major=False)
    stale_gen = pane._load_gen  # snapshot before a newer load() starts
    pane._load_gen += 1         # a newer load() has since begun

    pane._on_decode_done({"fps_x10": 250, "column_major": False},
                         _frames(9), stale_gen)
    assert pane.encoded is not None and len(pane.encoded) == 2

    pane._on_decode_failed("boom", stale_gen)
    assert pane._error_label.text() == ""
    assert pane._error_label.isVisibleTo(pane) is False


def test_heatmap_handles_length_mismatch(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(5), source=_frames(3), fps=25,
                    column_major=False)
    pane.set_mode("Heatmap")
    pane.seek(4)                      # beyond the 3-frame source
    assert pane.mode == "Heatmap"
    assert not pane._image_label.pixmap().isNull()


class _ThreadRecordingPane(PreviewPane):
    """Test-only subclass that records, on every _on_decode_done call,
    which thread it actually ran on - the point of the generation-in-
    signal-payload fix is that connecting worker.done to a bound
    method (this override remains one) gives Qt the receiver affinity
    it needs to auto-promote the connection to Queued, so the slot
    runs on the GUI thread even though the signal is emitted from the
    decode thread. A bare lambda receiver, which the fix replaced,
    would run this on the decode thread instead - the previous
    Critical regression this test guards against."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.decode_done_idents = []
        self.decode_done_on_gui_thread = []

    def _on_decode_done(self, hdr, frames, gen):
        self.decode_done_idents.append(threading.get_ident())
        self.decode_done_on_gui_thread.append(
            QThread.currentThread() is QApplication.instance().thread())
        super()._on_decode_done(hdr, frames, gen)


def test_load_decode_callback_runs_on_gui_thread(qtbot, tmp_path):
    from vidbuild import build_solid_vid   # helper, task 7

    vid = tmp_path / "t.vid"
    build_solid_vid(vid, width=256, height=1, colours=[5, 9])

    pane = _ThreadRecordingPane()
    qtbot.addWidget(pane)
    gui_ident = threading.get_ident()

    pane.load(vid, source_frames=None, column_major=False)
    qtbot.waitUntil(lambda: pane.encoded is not None, timeout=5000)

    assert pane.decode_done_idents == [gui_ident]
    assert pane.decode_done_on_gui_thread == [True]


def test_preview_argv_pins_budget_and_segment(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.pinned_budgets["001"] = 0.72
    win.preview.set_frames(encoded=_frames(50), source=None, fps=25,
                           column_major=False)
    win.preview.seek(10); win.preview.set_in()
    win.preview.seek(35); win.preview.set_out()
    argv = win.preview_argv("001")
    assert "--stream-budget" in argv and "0.72" in argv
    assert "--start" in argv and "0.4" in argv
    assert "--duration" in argv and "1.0" in argv


def test_full_argv_never_pins(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.pinned_budgets["001"] = 0.72
    assert "--stream-budget" not in win.full_argv("001")


def test_accept_requires_full_encode(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    assert not win.accept_button.isEnabled()


def test_preview_success_labels_provisional_budget_until_full_encode(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")

    summary = MetricsSummary(stream_budget=0.5)
    win._on_preview_success("001", None, [], summary)
    assert win.metrics_bar.status_text() == "budget provisional (derived on segment)"

    # Switching clips must not carry clip 001's provisional label onto
    # clip 002 - nothing has run a job for 002 yet.
    win.select_clip("002")
    assert win.metrics_bar.status_text() == ""

    win.select_clip("001")
    win._on_preview_success("001", None, [], summary)
    win._on_full_success("001", None, [], summary)
    assert win.metrics_bar.status_text() == ""


# -- Finding 1: segment markers self-destruct / leak across clips ---------

def test_segment_persists_across_preview_argv_calls(fixture_kit, qtbot):
    """previewpane.set_frames wipes the pane's live seg_in/seg_out at
    the end of every load() - including the preview load a Preview
    Segment click itself triggers. Without the self.segments store, a
    second preview_argv() call (as a re-click of Preview Segment would
    make) sees no live markers and silently falls back to a full-clip
    encode."""
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.preview.set_frames(encoded=_frames(50), source=None, fps=25,
                           column_major=False)
    win.preview.seek(10); win.preview.set_in()
    win.preview.seek(35); win.preview.set_out()

    argv1 = win.preview_argv("001")
    assert "--start" in argv1 and "0.4" in argv1
    assert "--duration" in argv1 and "1.0" in argv1

    # Simulate what a real Preview Segment success does: the pane
    # reloads and its own markers are gone.
    win.preview.set_frames(encoded=_frames(50), source=None, fps=25,
                           column_major=False)
    assert win.preview.seg_in is None and win.preview.seg_out is None

    argv2 = win.preview_argv("001")
    assert "--start" in argv2 and "0.4" in argv2
    assert "--duration" in argv2 and "1.0" in argv2


def test_select_clip_clears_pane_markers_and_does_not_leak_segment(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.preview.set_frames(encoded=_frames(50), source=None, fps=25,
                           column_major=False)
    win.preview.seek(10); win.preview.set_in()
    win.preview.seek(35); win.preview.set_out()

    win.select_clip("002")
    assert win.preview.seg_in is None and win.preview.seg_out is None
    # clip 002 has never had a segment marked - it must not inherit
    # clip 001's stored segment either.
    assert "--start" not in win.preview_argv("002")

    # Re-marking clip 001's segment overwrites the stored one.
    win.select_clip("001")
    win.preview.set_frames(encoded=_frames(50), source=None, fps=25,
                           column_major=False)
    win.preview.seek(5); win.preview.set_in()
    win.preview.seek(15); win.preview.set_out()
    argv3 = win.preview_argv("001")
    assert "--start" in argv3 and "0.2" in argv3
    assert "--duration" in argv3 and "0.4" in argv3


# -- Finding 2: select_clip never loads the preview / clears+tags metrics --

def test_select_clip_shows_hint_when_no_fresh_preview(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    assert win.preview.encoded is None
    assert win.preview._hint_label.isVisibleTo(win.preview) is True


def test_select_clip_loads_fresh_vid_preview(fixture_kit, qtbot):
    from vidbuild import build_solid_vid   # helper, task 7

    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)

    clip = win._clip_by_num3("001")
    build_solid_vid(clip.vid, width=320, height=256, colours=[3])
    win.stamp = "pal9k"
    clip.sidecar.write_text(arg_hash("pal9k", build_arg_vector(win.cfg, "001")))

    win.select_clip("001")
    qtbot.waitUntil(lambda: win.preview.encoded is not None, timeout=5000)
    assert len(win.preview.encoded) == 1
    assert win.preview._hint_label.isVisibleTo(win.preview) is False


def test_select_clip_clears_and_tags_metrics(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")

    summary = MetricsSummary(psnr_mean=30.0, bound_fraction=0.4,
                             util=0.8, wire_bytes=1234)
    win.metrics_bar.update_from(summary, False, "001")
    assert win.metrics_bar.clip_tag() == "clip 001"
    assert win.metrics_bar._psnr_label.text() != "psnr: -"

    # A job finishing after a mid-job clip switch must not be mistaken
    # for the newly-selected clip's numbers: switching clears the
    # figures and re-tags immediately.
    win.select_clip("002")
    assert win.metrics_bar.clip_tag() == "clip 002"
    assert win.metrics_bar._psnr_label.text() == "psnr: -"
    assert win.metrics_bar._bound_label.text() == "bound: -"
    assert win.metrics_bar._util_label.text() == "util: -"
    assert win.metrics_bar._wire_label.text() == "wire: -"


# -- Finding 3: a bad VIDASPECT must not crash the window -----------------

def test_bad_vidaspect_shows_banner_instead_of_crashing(tmp_path, qtbot):
    # A .vid + fresh-looking sidecar + generation stamp is needed so
    # clip_state actually reaches build_arg_vector (it short-circuits
    # to "stale" without calling it when no .vid exists yet) - this is
    # what makes _populate_clip_list, during MainWindow.__init__, the
    # one that hits the ValueError, exactly as the finding describes:
    # "clip_state -> build_arg_vector -> _shape_args raises ValueError
    # for e.g. VIDASPECT=wide, killing MainWindow.__init__".
    (tmp_path / "VIDEO").mkdir()
    (tmp_path / "lib").mkdir()
    (tmp_path / "VIDEO" / "1.mp4").write_bytes(b"x")
    (tmp_path / "VIDEO" / "1.vid").write_bytes(b"x")
    (tmp_path / "VIDEO" / "1.vid.args").write_text("stale-hash")
    (tmp_path / "lib" / "video.ps1").write_text("$encoderGeneration = 'pal9k'\n")
    (tmp_path / "CONFIG.BAT").write_text(
        "@echo off\r\n"
        "SET TOOLSDIR=tools\r\n"
        "SET VIDASPECT=wide\r\n"     # not a preset/WxH/decimal - malformed
        "SET VIDFPS=\r\n"
        "SET VIDOPTS=\r\n",
        newline="")

    win = MainWindow(tmp_path)      # must not raise
    qtbot.addWidget(win)

    assert win._banner.isVisibleTo(win) is True
    assert "VIDASPECT" in win._banner.text()
    assert win.clip_list.count() == 0
    assert win.preview_button.isEnabled() is False
    assert win.encode_button.isEnabled() is False
    assert win.encode_all_button.isEnabled() is False


def test_full_argv_guarded_after_bad_config_edit(fixture_kit, qtbot):
    """A VIDASPECT typo introduced after construction (e.g. CONFIG.BAT
    hand-edited and reloaded) must be caught at every argv-building
    entry point reachable from the UI, not just __init__."""
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")

    win.cfg.vid_aspect = "wide"
    win._update_accept_enabled()    # must not raise
    assert win._banner.isVisibleTo(win) is True
    assert win.accept_button.isEnabled() is False

    win._banner.setVisible(False)
    assert win._guarded(win.preview_argv, "001") is None
    assert win._banner.isVisibleTo(win) is True

    win._banner.setVisible(False)
    assert win._guarded(win.full_argv, "001") is None
    assert win._banner.isVisibleTo(win) is True


# -- Finding 4: HH:MM:SS --start must not silently drop source compare ----

def test_parse_start_duration_accepts_hhmmss(fixture_kit, qtbot):
    start, duration = vt_mainwindow._parse_start_duration(
        ["--shape", "full", "--start", "00:01:30", "--duration", "5"])
    assert start == 90.0
    assert duration == 5.0


def test_extract_matching_source_failure_logs_to_pane_not_silence(fixture_kit, qtbot, monkeypatch):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")

    # Pretend ffmpeg is available so _extract_matching_source doesn't
    # bail out on the "no ffmpeg" early return before reaching the part
    # under test.
    fake_ffmpeg = fixture_kit / "fake_ffmpeg.exe"
    fake_ffmpeg.write_bytes(b"x")
    win.ffmpeg = fake_ffmpeg

    def boom(*a, **kw):
        raise RuntimeError("ffmpeg probe failed: boom")
    monkeypatch.setattr(vt_mainwindow, "extract_source", boom)

    win._load_preview("001", None, [])
    assert win.preview._error_label.isVisibleTo(win.preview) is True
    assert "boom" in win.preview._error_label.text()


# -- Finding 5: encode-all-stale queue coverage ----------------------------

class _FakeEncodeJob(QObject):
    """Stand-in for encoderun.EncodeJob: synchronously "succeeds",
    writing a fake .vid straight to output_path and deferring its
    finished signal by one event-loop tick (QTimer.singleShot(0, ...))
    so MainWindow's normal async job-completion plumbing (job.finished
    -> _on_job_finished -> _advance_all_queue) runs exactly as it would
    against the real QProcess-backed EncodeJob."""
    line = Signal(str)
    progress = Signal(dict)
    finished = Signal(int, dict)

    def __init__(self, encoder_argv, ffmpeg, parent=None):
        super().__init__(parent)

    def start(self, input_path, output_path, args):
        Path(output_path).write_bytes(b"FAKEVID")
        QTimer.singleShot(0, lambda: self.finished.emit(0, {}))

    def cancel(self):
        pass


def test_encode_all_stale_runs_serially_and_writes_sidecars(fixture_kit, qtbot, monkeypatch):
    monkeypatch.setattr(vt_mainwindow, "EncodeJob", _FakeEncodeJob)

    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.encoder_argv = ["fake-encoder"]
    win.ffmpeg = Path("fake-ffmpeg.exe")
    win.stamp = "pal9k"   # fixture_kit has no lib/video.ps1; a None stamp
                          # makes clip_state always-stale regardless of
                          # sidecar contents, which would make the
                          # post-queue freshness check below meaningless

    clip1, clip2 = win.clips
    assert clip_state(clip1, win.cfg, win.stamp)[1]   # both start stale
    assert clip_state(clip2, win.cfg, win.stamp)[1]

    win.on_encode_all_stale()
    qtbot.waitUntil(lambda: clip2.vid.is_file(), timeout=5000)
    qtbot.waitUntil(lambda: win._job is None, timeout=5000)

    for clip in (clip1, clip2):
        assert clip.vid.read_bytes() == b"FAKEVID"
        want = arg_hash(win.stamp or "", build_arg_vector(win.cfg, clip.num3))
        assert clip.sidecar.read_text().strip() == want
        assert not clip_state(clip, win.cfg, win.stamp)[1]   # fresh now


def test_encode_all_stale_cancel_after_current_stops_queue(fixture_kit, qtbot, monkeypatch):
    monkeypatch.setattr(vt_mainwindow, "EncodeJob", _FakeEncodeJob)

    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.encoder_argv = ["fake-encoder"]
    win.ffmpeg = Path("fake-ffmpeg.exe")

    clip1, clip2 = win.clips

    win.on_encode_all_stale()
    # clip1's job writes its output synchronously inside start(); its
    # finished signal is deferred one event-loop tick, so cancelling
    # here (before any qtbot.wait spins the loop) is guaranteed to land
    # before _advance_all_queue would otherwise start clip2.
    assert clip1.vid.is_file()
    assert not clip2.vid.is_file()
    win._on_cancel_requested()

    qtbot.waitUntil(lambda: win._job is None, timeout=5000)
    qtbot.wait(50)   # give a stray second job a chance to prove it wrong

    want = arg_hash(win.stamp or "", build_arg_vector(win.cfg, clip1.num3))
    assert clip1.sidecar.read_text().strip() == want
    assert not clip2.vid.is_file()
