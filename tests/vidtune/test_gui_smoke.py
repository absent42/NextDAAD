import threading

import numpy as np
from PySide6.QtCore import QThread
from PySide6.QtGui import QDoubleValidator
from PySide6.QtWidgets import QApplication

from vidtune.mainwindow import MainWindow, PreviewPane, SettingsPanel
from vidtune.encoderun import MetricsSummary
from vidtune.kitmodel import KitConfig
from vidtune.settingsmodel import effective_settings


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

    win._on_full_success("001", None, [], summary)
    assert win.metrics_bar.status_text() == ""
