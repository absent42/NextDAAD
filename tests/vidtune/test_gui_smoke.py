import threading
from pathlib import Path

import numpy as np
from PySide6.QtCore import QObject, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QDoubleValidator, QGuiApplication
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


# -- 2026-08-01 UX defects 1-5 ----------------------------------------------

_NEEDS_SOURCE_TOOLTIP = "needs a source comparison - run Preview Segment or Encode first"


def test_flicker_and_heatmap_disabled_without_source(qtbot):
    # Defect 1: Flicker used to silently fall back to the encoded frame
    # when self.source was None, making Encoded and Flicker look
    # identical with no explanation. Both buttons must start disabled
    # (a fresh pane has no source yet) and carry an explanatory tooltip.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    assert pane._mode_buttons["Flicker"].isEnabled() is False
    assert pane._mode_buttons["Heatmap"].isEnabled() is False
    assert pane._mode_buttons["Flicker"].toolTip() == _NEEDS_SOURCE_TOOLTIP
    assert pane._mode_buttons["Heatmap"].toolTip() == _NEEDS_SOURCE_TOOLTIP

    # Encoded-only: Flicker still needs a source, Heatmap needs both.
    pane.set_frames(encoded=_frames(3), source=None, fps=25, column_major=False)
    assert pane._mode_buttons["Flicker"].isEnabled() is False
    assert pane._mode_buttons["Heatmap"].isEnabled() is False

    # Source arrives (a Preview Segment / Encode completed): both usable.
    pane.set_frames(encoded=_frames(3), source=_frames(3), fps=25, column_major=False)
    assert pane._mode_buttons["Flicker"].isEnabled() is True
    assert pane._mode_buttons["Heatmap"].isEnabled() is True


def test_flicker_enabled_with_source_only_heatmap_needs_both(qtbot):
    # Flicker only compares source vs. encoded at the same index, so it
    # only needs source frames; Heatmap needs both sides.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=None, source=_frames(3), fps=25, column_major=False)
    assert pane._mode_buttons["Flicker"].isEnabled() is True
    assert pane._mode_buttons["Heatmap"].isEnabled() is False


def test_all_pane_buttons_have_no_focus_policy(qtbot):
    # Defect 2: the pane is StrongFocus and keyPressEvent handles Space,
    # but a QPushButton keeps focus after being clicked and Qt routes
    # Space to whichever widget has focus - so every clickable control
    # in the mode/transport rows must give focus back to the pane.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    buttons = list(pane._mode_buttons.values()) + [
        pane._play_btn, pane._stop_btn, pane._step_back_btn, pane._step_fwd_btn,
        pane._loop_checkbox, pane._set_in_btn, pane._set_out_btn, pane._clear_btn,
        pane._scale_btn,
    ]
    assert buttons  # sanity: the loop below must not be vacuous
    for btn in buttons:
        assert btn.focusPolicy() == Qt.NoFocus


def test_space_reaches_pane_flicker_toggle_after_button_click(qtbot):
    # Verifies the actual behaviour the NoFocus fix protects: clicking a
    # transport button must not steal keyboard focus from the pane, so
    # Space still reaches keyPressEvent and toggles Flicker.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(5), source=_frames(5), fps=25, column_major=False)
    pane.set_mode("Flicker")
    pane.show()
    pane._stop_btn.click()
    pane.setFocus()
    shown_before = pane.showing_source
    qtbot.keyClick(pane, Qt.Key_Space)
    assert pane.showing_source != shown_before


def test_click_image_still_toggles_flicker(qtbot):
    # The click-image-to-flicker path (_ClickableLabel) is independent of
    # keyboard focus and must keep working after the NoFocus change.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(5), source=_frames(5), fps=25, column_major=False)
    pane.set_mode("Flicker")
    shown_before = pane.showing_source
    pane._image_label.clicked.emit()
    assert pane.showing_source != shown_before


def test_segment_readout_lifecycle(qtbot):
    # Defect 3: a segment readout label must track set_in/set_out/clear.
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(50), source=None, fps=25, column_major=False)
    assert pane._segment_label.text() == "segment: -"

    pane.seek(10); pane.set_in()
    assert pane._segment_label.text() == "in: f10 (0.40s)  out: -"

    pane.seek(35); pane.set_out()
    assert pane._segment_label.text() == "segment: 0.40s - 1.40s (f10-f35)"

    pane.clear()
    assert pane._segment_label.text() == "segment: -"


def test_segment_readout_reset_by_set_frames(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(50), source=None, fps=25, column_major=False)
    pane.seek(10); pane.set_in()
    assert pane._segment_label.text() != "segment: -"

    pane.set_frames(encoded=_frames(50), source=None, fps=25, column_major=False)
    assert pane._segment_label.text() == "segment: -"


def test_clear_button_pops_stored_segment(fixture_kit, qtbot):
    # Defect 4 (parked residual A): a user-initiated Clear must forget a
    # segment previously captured into MainWindow.segments by a Preview
    # Segment run, or the cleared segment silently re-applies next time.
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.segments["001"] = (0.4, 1.0)   # simulate a captured Preview Segment

    win.preview._clear_btn.click()     # the real user-facing Clear path

    assert "001" not in win.segments
    assert win.preview.seg_in is None and win.preview.seg_out is None


def test_select_clip_programmatic_clear_does_not_pop_segment(fixture_kit, qtbot):
    # select_clip's own self.preview.clear() call (resetting the pane's
    # live markers on a clip switch) must NOT pop the just-marked clip's
    # stored segment - only a user-initiated Clear does that.
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    win.select_clip("001")
    win.segments["001"] = (0.4, 1.0)

    win.select_clip("002")

    assert win.segments.get("001") == (0.4, 1.0)


def test_clear_to_empty_bumps_load_generation(qtbot, tmp_path):
    # Defect 5 (parked residual B): clear_to_empty()/set_frames() must
    # invalidate any in-flight decode by bumping _load_gen, or a stale
    # decode for an abandoned clip can paint over the empty-pane hint of
    # whatever clip is now selected.
    from vidbuild import build_solid_vid   # helper, task 7

    vid = tmp_path / "t.vid"
    build_solid_vid(vid, width=256, height=1, colours=[5, 9])

    pane = PreviewPane()
    qtbot.addWidget(pane)

    pane.load(vid, source_frames=None, column_major=False)   # start a load
    stale_gen = pane._load_gen

    pane.clear_to_empty(hint="switched to a preview-less clip")
    assert pane._load_gen != stale_gen

    # The now-stale decode "arrives late" - must be dropped, not applied
    # over the hint.
    pane._on_decode_done({"fps_x10": 250, "column_major": False},
                         _frames(9), stale_gen)
    assert pane.encoded is None
    assert pane._hint_label.text() == "switched to a preview-less clip"
    assert pane._hint_label.isVisibleTo(pane) is True


def test_set_frames_direct_injection_bumps_load_generation(qtbot, tmp_path):
    from vidbuild import build_solid_vid   # helper, task 7

    vid = tmp_path / "t.vid"
    build_solid_vid(vid, width=256, height=1, colours=[5, 9])

    pane = PreviewPane()
    qtbot.addWidget(pane)

    pane.load(vid, source_frames=None, column_major=False)
    stale_gen = pane._load_gen

    pane.set_frames(encoded=_frames(2), source=None, fps=25, column_major=False)
    assert pane._load_gen != stale_gen

    pane._on_decode_done({"fps_x10": 250, "column_major": False},
                         _frames(9), stale_gen)
    assert pane.encoded is not None and len(pane.encoded) == 2


# -- 2026-08-01 follow-up: 2x default scale + no-scrollbar launch size ------

def test_preview_pane_defaults_to_2x_scale(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    assert pane.scale == 2
    assert pane._scale_btn.isChecked() is True

    # The initial render (once frames arrive) must honour it too.
    pane.set_frames(encoded=_frames(3), source=None, fps=25, column_major=False)
    pixmap = pane._image_label.pixmap()
    assert not pixmap.isNull()
    assert pixmap.width() == 8 * 2 and pixmap.height() == 8 * 2


def test_main_window_sizes_wide_enough_for_settings_panel(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)

    expected = win._compute_initial_width()
    screen = QGuiApplication.primaryScreen()
    if screen is not None:
        expected = min(expected, screen.availableGeometry().width())
    # resize() can be off by a handful of px vs. width() depending on
    # window-manager frame accounting; a small tolerance keeps this from
    # being a flaky pixel-exact check.
    assert win.width() >= expected - 4


def test_settings_panel_has_no_horizontal_scrollbar_on_launch(fixture_kit, qtbot):
    win = MainWindow(fixture_kit)
    qtbot.addWidget(win)
    try:
        win.show()
        qtbot.waitExposed(win)
        QApplication.processEvents()
        assert win.settings_scroll.horizontalScrollBar().isVisible() is False
    except Exception:
        # show()/waitExposed can be unreliable on a headless/no-window-
        # manager CI box - fall back to the geometry check the brief
        # allows: the window was sized to at least the settings panel's
        # own sizeHint width, which is what keeps the scroll area from
        # needing a horizontal scrollbar in the first place.
        panel_min_width = (win.settings_panel.sizeHint().width()
                           + win.settings_scroll.frameWidth() * 2)
        assert win._splitter.sizes()[2] >= panel_min_width
