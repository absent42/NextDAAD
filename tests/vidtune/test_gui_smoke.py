from PySide6.QtGui import QDoubleValidator

from vidtune.mainwindow import MainWindow, SettingsPanel
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
