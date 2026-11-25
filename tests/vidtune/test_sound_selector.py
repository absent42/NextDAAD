"""The sound selector: --direct-sound for uncompressed clips only."""
import nxv2enc
from PySide6.QtCore import Qt

from vidtune import mainwindow as vt_mainwindow
from vidtune import presets
from vidtune.encoderun import summarize_report
from vidtune.kitmodel import KitConfig, arg_hash, parse_config
from vidtune.mainwindow import MainWindow, SettingsPanel
from vidtune.preview import sound_form
from vidtune.settingsmodel import (build_arg_vector, deviations,
                                   effective_settings, split_opts)


def _add_lines(kit, *lines):
    path = kit / "CONFIG.BAT"
    text = path.read_text()
    extra = "".join(f"{line}\r\n" for line in lines)
    path.write_text(text.replace("SET VIDPROFILE=", extra + "SET VIDPROFILE="),
                    newline="")


def _window(kit, qtbot):
    win = MainWindow(kit)
    qtbot.addWidget(win)
    win.stamp = "pal9k"
    for clip in win.clips:
        clip.vid.write_bytes(b"FAKEVID")
        clip.sidecar.write_text(arg_hash("pal9k", build_arg_vector(win.cfg, clip.num3)))
    win._populate_clip_list()
    return win


def _sound(panel):
    return panel._rows["direct_sound"]


def _choose(panel, text):
    _sound(panel)["widget"].setCurrentText(text)


def _status(win, num3):
    for i in range(win.clip_list.count()):
        item = win.clip_list.item(i)
        if item.data(Qt.UserRole) == num3:
            return item.data(vt_mainwindow._ClipDelegate.STATUS_ROLE)
    return None


def _accept(win):
    num3 = win._current_clip
    win.full_ok[num3] = win.full_argv(num3)
    (win.scratch_dir / f"full_{num3}.vid").write_bytes(b"FAKEVID")
    win.on_accept()


def test_selector_shows_only_for_uncompressed(qtbot):
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(KitConfig(), "001")
    panel.set_settings(s, s.copy())
    row = _sound(panel)
    assert row["label"].isHidden() and row["container"].isHidden()
    assert row["label"].text() == "sound" and row["knob"].level == "basic"
    panel._rows["direct"]["widget"].setChecked(True)
    assert not row["label"].isHidden() and not row["container"].isHidden()
    assert [row["widget"].itemText(i) for i in range(row["widget"].count())] \
        == ["auto", "stereo", "mono"]
    assert panel.get_settings()["direct_sound"] == "auto"
    panel._on_route_chosen("cutscene")
    assert row["container"].isHidden()


def test_each_choice_round_trips_through_save_and_reload(fixture_kit, qtbot):
    for choice, token in (("auto", None), ("stereo", "stereo"), ("mono", "mono")):
        win = _window(fixture_kit, qtbot)
        win.select_clip("001")
        _choose(win.settings_panel, "stereo" if choice == "auto" else choice)
        _choose(win.settings_panel, choice)
        _accept(win)
        line = split_opts(parse_config(fixture_kit / "CONFIG.BAT").per_clip["001"])
        if token is None:
            assert "--direct-sound" not in line
        else:
            assert line.count("--direct-sound") == 1
            assert line[line.index("--direct-sound") + 1] == token
        again = _window(fixture_kit, qtbot)
        again.select_clip("001")
        assert again.settings_panel.get_settings()["direct_sound"] == choice
        assert _status(again, "001") != "edited"


def test_auto_leaves_an_existing_line_byte_identical(fixture_kit, qtbot):
    line = "--shape 256x192 --fps 16.67 --direct"
    _add_lines(fixture_kit, f"SET VIDOPTS_003={line}")
    (fixture_kit / "VIDEO" / "003.mp4").write_bytes(b"x")
    cfg = parse_config(fixture_kit / "CONFIG.BAT")
    assert " ".join(deviations(effective_settings(cfg, "003"), cfg)) == line
    win = _window(fixture_kit, qtbot)
    win.select_clip("003")
    assert win.settings_panel.get_settings()["direct_sound"] == "auto"
    assert _status(win, "003") != "edited"
    _accept(win)
    assert parse_config(fixture_kit / "CONFIG.BAT").per_clip["003"] == line


def test_hand_typed_token_loads_into_selector_once(fixture_kit, qtbot):
    _add_lines(fixture_kit, "SET VIDOPTS_003=--shape 256x192 --direct --direct-sound mono")
    (fixture_kit / "VIDEO" / "003.mp4").write_bytes(b"x")
    cfg = parse_config(fixture_kit / "CONFIG.BAT")
    s = effective_settings(cfg, "003")
    assert s["direct_sound"] == "mono" and s["extra"] == []
    win = _window(fixture_kit, qtbot)
    win.select_clip("003")
    panel = win.settings_panel
    assert _sound(panel)["widget"].currentText() == "mono"
    assert panel._extra_label.isHidden()
    assert _status(win, "003") != "edited"
    argv = win.full_argv("003")
    assert argv.count("--direct-sound") == 1
    assert argv[argv.index("--direct-sound") + 1] == "mono"
    _accept(win)
    saved = split_opts(parse_config(fixture_kit / "CONFIG.BAT").per_clip["003"])
    assert saved.count("--direct-sound") == 1


def test_route_round_trip_leaves_no_stray_token(qtbot):
    cfg = KitConfig()
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())
    panel._on_route_chosen("cutscene")
    panel._on_route_chosen("fullrate")
    _choose(panel, "mono")
    assert "--direct-sound" in deviations(panel.get_settings(), cfg)
    panel._on_route_chosen("cutscene")
    assert "--direct-sound" not in deviations(panel.get_settings(), cfg)
    panel._on_route_chosen("fullrate")
    assert panel.get_settings()["direct_sound"] == "auto"
    # turning --direct off by hand drops the token too
    _choose(panel, "mono")
    panel._rows["direct"]["widget"].setChecked(False)
    assert "--direct-sound" not in deviations(panel.get_settings(), cfg)


def test_route_with_its_own_sound_sets_the_selector():
    s = effective_settings(KitConfig(), "001")
    route = presets.Route("t", "t", "t", {"direct": True, "shape": "256x192",
                                          "direct_sound": "mono"})
    assert presets.apply_route(s, s, route)["direct_sound"] == "mono"
    assert "direct_sound" in presets.ROUTE_KNOBS


def test_selector_change_is_an_edit_opening_is_not(fixture_kit, qtbot):
    win = _window(fixture_kit, qtbot)
    win.select_clip("002")
    win.select_clip("001")
    assert _status(win, "001") == "default"
    _choose(win.settings_panel, "mono")
    assert _status(win, "001") == "edited"


def test_size_line_differs_by_the_sound_bytes(qtbot):
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    s = effective_settings(KitConfig(), "001")
    panel.set_settings(s, s.copy())
    panel._on_route_chosen("fullrate")
    stereo = presets.raw_rate(panel.get_settings())
    assert panel.size_label.text() == "uncompressed, stereo: 1.27 MB a second"
    _choose(panel, "mono")
    mono = presets.raw_rate(panel.get_settings())
    assert mono["form"] == "mono"
    snd = {ch: nxv2enc.audio_layout(25.0, ch, raw=True)[3] for ch in (1, 2)}
    assert stereo["frame_bytes"] - mono["frame_bytes"] == snd[2] - snd[1]
    assert panel.size_label.text() == (
        f"uncompressed, mono: {mono['per_second'] / 1e6:.2f} MB a second")
    assert panel.size_label.text() != "uncompressed, stereo: 1.27 MB a second"


def _vid(path, channels, raw=True):
    flags = nxv2enc.FLAG_DELTA_STREAM | nxv2enc.FLAG_DIRECT_SERVE
    if raw:
        flags |= nxv2enc.FLAG_RAW
    elif channels == 1:
        raise ValueError("compressed clips are stereo")
    path.write_bytes(nxv2enc.pack_header(
        width=256, height=192, fps=25, channels=channels, arate=15625,
        frame_count=1, audio_bytes_per_frame=1250, ring_start_margin_blocks=10,
        per_frame_cap_blocks=10, flags=flags, raw_width=256 if raw else None))
    return path


def test_readout_shows_the_encoded_files_sound(fixture_kit, qtbot, monkeypatch, tmp_path):
    win = _window(fixture_kit, qtbot)
    monkeypatch.setattr(win.preview, "load", lambda *a, **k: None)
    monkeypatch.setattr(win, "_extract_matching_source", lambda *a: None)
    bar = win.metrics_bar
    cases = [
        (_vid(tmp_path / "m.vid", 1), ["--direct"], "sound: mono (auto)"),
        (_vid(tmp_path / "s.vid", 2), ["--direct"], "sound: stereo (auto)"),
        (_vid(tmp_path / "mm.vid", 1), ["--direct", "--direct-sound", "mono"],
         "sound: mono"),
        (_vid(tmp_path / "ss.vid", 2), ["--direct", "--direct-sound", "stereo"],
         "sound: stereo"),
        (_vid(tmp_path / "c.vid", 2, raw=False), [], "sound: stereo"),
    ]
    for path, argv, want in cases:
        win._on_full_success("001", path, argv, summarize_report({}))
        assert bar.sound_text() == want
    win.select_clip("002")
    assert bar.sound_text() == ""            # header-less FAKEVID: left out
    assert sound_form(tmp_path / "missing.vid", []) is None
