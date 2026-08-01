import numpy as np
from PySide6.QtGui import QDoubleValidator

from vidtune.mainwindow import MainWindow, PreviewPane, SettingsPanel
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
