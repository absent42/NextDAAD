"""Route presets, the prefilter modifier, and the banding ladder.

Structured around the "Behavioural requirements" section of
docs/superpowers/specs/2026-08-02-vidtune-preset-row-spec.md - each
requirement there has at least one test here, since most of them are
rules about what a preset must NOT disturb, which is exactly the kind of
thing that rots silently.
"""
import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QMenu

from vidtune import presets
from vidtune.kitmodel import KitConfig
from vidtune.mainwindow import SettingsPanel
from vidtune.presetrow import CHOOSE_TEXT, LadderPanel, RouteMenuButton
from vidtune.settingsmodel import (KNOBS, deviations, effective_settings,
                                   parse_opts)


def _base(**overrides):
    cfg = KitConfig()
    s = effective_settings(cfg, "001")
    s.update(overrides)
    return cfg, s


# -- preset CONTENT matches VIDEO-PRESETS.md ----------------------------

EXPECTED = {
    "quiet":          {},
    "quiet-motion":   {"tile_slack": "0.5"},
    "action":         {"direct": True, "shape": "full", "fps": "12.5"},
    "action-169":     {"direct": True, "shape": "16:9", "fps": "12.5"},
    "fullrate":       {"direct": True, "shape": "256x153"},
    "fullrate-wide":  {"direct": True, "shape": "320x123"},
    "cutscene":       {"shape": "16:9", "tile_slack": "0.5"},
    "cutscene-43":    {"shape": "classic", "tile_slack": "0.5"},
}


def test_every_route_matches_the_presets_doc():
    assert {r.key for r in presets.all_routes()} == set(EXPECTED)
    for key, values in EXPECTED.items():
        assert presets.route_by_key(key).values == values


def test_applied_route_round_trips_through_deviations():
    """A preset must reach the encoder through the ordinary deviation
    path - no preset name in CONFIG.BAT, no bypass. Applying one and
    parsing the resulting option string back must give the same values.

    Compared as parsed VALUES, not as the doc's literal option string:
    deviations() emits in KNOBS order and correctly omits any value that
    already equals the kit default (preset 2's `--shape full` on a kit
    that is already `full`), so the strings differ while the meaning does
    not."""
    for key, expected in EXPECTED.items():
        cfg, settings = _base()
        after = presets.apply_route(settings, settings, presets.route_by_key(key))
        opts = deviations(after, cfg)
        known, extra = parse_opts(opts)
        assert extra == [], f"{key} produced unmapped tokens: {extra}"
        for name, value in expected.items():
            base_value = settings.get(name)
            if value == base_value:
                continue          # already the kit default; nothing to emit
            assert known.get(name) == value, f"{key}: {name}"


# -- requirement 1: reset the other route knobs first -------------------

def test_route_resets_stale_route_knobs():
    # A leftover --fps 12.5 from a previous route must not survive into a
    # preset that never mentions fps, or the preset does not mean what
    # it says.
    cfg, settings = _base(fps="12.5", direct=True, tile_slack="0.9")
    _cfg, kit_base = _base()

    after = presets.apply_route(settings, kit_base, presets.route_by_key("cutscene"))
    assert after["fps"] == kit_base["fps"]      # reset, not carried over
    assert after["direct"] == kit_base["direct"]
    assert after["shape"] == "16:9"             # stamped
    assert after["tile_slack"] == "0.5"         # stamped over the stale 0.9


def test_quiet_route_is_the_reset():
    cfg, settings = _base(fps="12.5", direct=True, shape="scope",
                          tile_slack="0.5")
    _cfg, kit_base = _base()
    after = presets.apply_route(settings, kit_base, presets.route_by_key("quiet"))
    for name in presets.ROUTE_KNOBS:
        assert after[name] == kit_base[name], name


# -- requirement 1/2: modifier and trim are orthogonal ------------------

@pytest.mark.parametrize("key", list(EXPECTED))
def test_route_never_touches_modifier_or_trim(key):
    cfg, settings = _base(prefilter=True, start="00:00:10", duration="4.5")
    _cfg, kit_base = _base()
    after = presets.apply_route(settings, kit_base, presets.route_by_key(key))
    assert after["prefilter"] is True
    assert after["start"] == "00:00:10"
    assert after["duration"] == "4.5"


def test_route_never_touches_extra_passthrough():
    cfg, settings = _base()
    settings["extra"] = ["--no-merge"]
    _cfg, kit_base = _base()
    after = presets.apply_route(settings, kit_base, presets.route_by_key("action"))
    assert after["extra"] == ["--no-merge"]


def test_shape_stamping_clears_the_other_shape_spellings():
    # shape/width/aspect are three ways to say the same thing and
    # build_arg_vector treats any of them as "the clip carries a shape";
    # leaving a stale aspect behind would emit both at once.
    cfg, settings = _base(aspect="2.35", width="320")
    _cfg, kit_base = _base()
    after = presets.apply_route(settings, kit_base, presets.route_by_key("cutscene"))
    assert after["shape"] == "16:9"
    assert after["aspect"] is None
    assert after["width"] is None


# -- requirement 3: a preset says what it will overwrite ----------------

def test_deltas_name_a_shape_overwrite():
    cfg, settings = _base(shape="full")
    _cfg, kit_base = _base()
    deltas = presets.route_deltas(settings, kit_base,
                                  presets.route_by_key("cutscene"))
    lines = presets.format_deltas(deltas)
    assert any("shape" in line and "16:9" in line for line in lines)


def test_deltas_on_an_unchanged_route_say_no_change():
    cfg, settings = _base()
    assert presets.format_deltas(
        presets.route_deltas(settings, settings,
                             presets.route_by_key("quiet"))) == ["no change"]


def test_flag_deltas_read_as_plus_and_minus():
    assert presets.format_delta("direct", False, True) == "+direct"
    assert presets.format_delta("direct", True, False) == "-direct"
    assert presets.format_delta("fps", "25", "12.5") == "fps 25 -> 12.5"


# -- requirement 5: never offer --stream-budget -------------------------

def test_nothing_in_the_preset_system_sets_stream_budget():
    # VIDEO-PRESETS.md preset 6 is explicit that setting this by hand can
    # only make the picture worse than the encoder's own answer.
    for route in presets.all_routes():
        assert "stream_budget" not in route.values
    assert "stream_budget" not in presets.ROUTE_KNOBS
    for step in presets.ladder_steps({}):
        assert "stream_budget" not in (step.values or {})


# -- preset 6: the ladder, derived on every call ------------------------

def test_ladder_step_states_are_derived_from_the_knobs():
    done = {s.n: s.done for s in presets.ladder_steps({"tile_slack": "0.5"})}
    assert done[1] is True
    assert done[3] is False

    # Take it away again and the step goes back to not-done. A stored
    # ladder position could not do this.
    done = {s.n: s.done for s in presets.ladder_steps({"tile_slack": "0.0"})}
    assert done[1] is False


def test_ladder_marks_prefilter_and_fps_steps_done():
    steps = {s.n: s for s in presets.ladder_steps(
        {"prefilter": True, "fps": "12.5"})}
    assert steps[3].done is True
    assert steps[4].done is True


def test_ladder_shape_step_advances_one_place_at_a_time():
    assert presets.next_shape({"shape": "full"}) == "16:9"
    assert presets.next_shape({"shape": "16:9"}) == "scope"
    assert presets.next_shape({"shape": "scope"}) == "classic-wide"
    assert presets.next_shape({"shape": "classic-wide"}) is None


def test_ladder_is_blocked_on_the_uncompressed_route():
    # Banding is not possible on a --direct encode, so offering remedies
    # for it would be advising a fix for a problem that cannot occur.
    assert presets.ladder_blocked_reason({"direct": True}) != ""
    assert presets.ladder_blocked_reason({"direct": False}) == ""


def test_ladder_step_five_offers_both_uncompressed_routes():
    step = {s.n: s for s in presets.ladder_steps({})}[5]
    assert step.routes == ("action", "fullrate")
    assert step.done is False


def test_ladder_step_six_is_advice_with_no_setting():
    step = {s.n: s for s in presets.ladder_steps({})}[6]
    assert step.values is None and step.routes == ()


def test_apply_step_only_changes_that_step():
    settings = {"shape": "full", "fps": "25", "prefilter": False}
    out = presets.apply_step(settings, presets.ladder_steps(settings)[0])
    assert out["tile_slack"] == "0.5"
    assert out["shape"] == "full" and out["fps"] == "25"


# -- the Qt surface -----------------------------------------------------

def test_route_menu_builds_an_item_for_every_route(qtbot):
    cfg, settings = _base()
    button = RouteMenuButton(lambda: (settings, settings))
    qtbot.addWidget(button)
    menu = QMenu()
    for route in presets.ROUTES:
        button._add(menu, route, settings, settings, indent=False)
        if route.variant is not None:
            button._add(menu, route.variant, settings, settings, indent=True)
    assert len(menu.actions()) == len(presets.all_routes())


def test_route_button_never_claims_a_route_is_active(qtbot):
    # Requirement 6: preset state is not sticky. The control is
    # momentary, so its caption must not change to name what was picked.
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    cfg = KitConfig()
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())

    panel._on_route_chosen("cutscene")
    assert panel._route_button.text() == CHOOSE_TEXT


def test_panel_route_stamps_the_knob_widgets(qtbot):
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    cfg = KitConfig()
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())

    with qtbot.waitSignal(panel.changed):
        panel._on_route_chosen("action")

    out = panel.get_settings()
    assert out["direct"] is True
    assert out["fps"] == "12.5"
    assert out["shape"] == "full"


def test_panel_ladder_apply_stamps_one_value(qtbot):
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    cfg = KitConfig()
    s = effective_settings(cfg, "001")
    panel.set_settings(s, s.copy())

    panel._on_apply_values({"tile_slack": "0.5"})
    assert panel.get_settings()["tile_slack"] == "0.5"
    assert panel.get_settings()["shape"] == s["shape"]      # nothing else


def test_ladder_panel_rebuilds_rows_on_refresh(qtbot):
    state = {"tile_slack": "0.0", "fps": "25"}
    ladder = LadderPanel(lambda: state)
    qtbot.addWidget(ladder)
    first = ladder._rows.count()
    assert first == len(presets.ladder_steps(state))

    state["tile_slack"] = "0.5"
    ladder.refresh()
    assert ladder._rows.count() == first        # same six rungs, restated


def test_wrap_label_reserves_room_for_its_wrapped_lines(qtbot):
    """The settings rail is a QScrollArea, and QScrollArea does not
    honour heightForWidth - so a wrapped label that does not reserve its
    own height reports one line and its later lines clip into whatever
    sits below it. That defect was live in the rail and invisible to
    every other test here, because nothing else measures geometry."""
    from vidtune.presetrow import _WrapLabel

    label = _WrapLabel("a fairly long run of guidance text " * 6)
    qtbot.addWidget(label)
    label.resize(180, 10)
    # minimumSizeHint, not minimumHeight: resizeEvent is POSTED, so with
    # no event loop turn the sync has not run yet - and a layout pass
    # that happens before it must still be told the truth.
    assert label.minimumSizeHint().height() > label.fontMetrics().height() * 2


def test_wrap_label_is_top_aligned(qtbot):
    # Surplus reserved height must fall below the text; centred, a
    # step's detail drifts toward the NEXT step's title.
    from vidtune.presetrow import _WrapLabel

    label = _WrapLabel("x")
    qtbot.addWidget(label)
    assert label.alignment() & Qt.AlignTop


def test_preset_row_uses_only_real_knob_names():
    # A typo'd knob name would stamp a key nothing reads, and the preset
    # would silently do nothing.
    names = {k.name for k in KNOBS}
    for route in presets.all_routes():
        assert set(route.values) <= names, route.key
    for step in presets.ladder_steps({}):
        assert set(step.values or {}) <= names, step.n
    assert set(presets.ROUTE_KNOBS) <= names
    assert set(presets.PRESERVED_KNOBS) <= names
