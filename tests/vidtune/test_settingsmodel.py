import pytest

from vidtune.kitmodel import KitConfig
from vidtune.settingsmodel import (VidprofileUnsupported, build_arg_vector,
                                   deviations, effective_settings, parse_opts,
                                   split_opts)


def cfg(**kw):
    return KitConfig(**kw)


# --- build_arg_vector: fixture table lifted from video.ps1's rules ---

def test_argvec_all_blank_is_empty():
    assert build_arg_vector(cfg(), "001") == []


def test_argvec_preset_shape():
    assert build_arg_vector(cfg(vid_aspect="16:9"), "001") == ["--shape", "16:9"]


def test_argvec_explicit_wxh():
    assert build_arg_vector(cfg(vid_aspect="320x150"), "001") == ["--shape", "320x150"]


def test_argvec_bare_aspect_comma_locale():
    assert build_arg_vector(cfg(vid_aspect="2,35"), "001") == ["--aspect", "2.35"]


def test_argvec_fps_and_opts_order():
    c = cfg(vid_aspect="scope", vid_fps="20", vid_opts="--mono",
            per_clip={"003": "--tile-slack 0.5"})
    assert build_arg_vector(c, "003") == [
        "--shape", "scope", "--fps", "20", "--mono", "--tile-slack", "0.5"]


def test_argvec_per_clip_shape_suppresses_global():
    c = cfg(vid_aspect="full", per_clip={"002": "--shape 16:9"})
    assert build_arg_vector(c, "002") == ["--shape", "16:9"]
    # --width and --aspect trigger the same suppression
    c2 = cfg(vid_aspect="full", per_clip={"002": "--aspect 2.35 --width 320"})
    assert build_arg_vector(c2, "002") == ["--aspect", "2.35", "--width", "320"]


def test_argvec_vidprofile_unsupported():
    with pytest.raises(VidprofileUnsupported):
        build_arg_vector(cfg(vidprofile="n1"), "001")


def test_argvec_bad_aspect_raises():
    with pytest.raises(ValueError):
        build_arg_vector(cfg(vid_aspect="wide"), "001")


# --- parse_opts / effective_settings / deviations round-trip ---

def test_parse_opts_known_and_unknown():
    known, extra = parse_opts(split_opts(
        "--dither 0.3 --mono --no-merge --dither 0.4"))
    assert known["dither"] == "0.4"      # last occurrence wins
    assert known["mono"] is True
    assert extra == ["--no-merge"]


def test_effective_settings_layering():
    c = cfg(vid_opts="--dither 0.3", per_clip={"003": "--dither 0.6 --mono"})
    s = effective_settings(c, "003")
    assert s["dither"] == "0.6"
    assert s["mono"] is True
    assert s["retime"] == "blend"        # untouched default


def test_deviations_only_deltas():
    c = cfg(vid_opts="--dither 0.3")
    s = effective_settings(c, "003")
    s["tile_slack"] = "0.5"
    assert deviations(s, c) == ["--tile-slack", "0.5"]


def test_deviations_shape_included_when_changed():
    c = cfg(vid_aspect="full")
    s = effective_settings(c, "004")
    s["shape"] = "16:9"
    assert deviations(s, c) == ["--shape", "16:9"]


def test_deviations_empty_when_untouched():
    c = cfg(vid_aspect="scope", vid_opts="--mono")
    assert deviations(effective_settings(c, "001"), c) == []


# --- new KNOBS (2026-08-02): prefilter/kf_cadence ------------------------

def test_parse_opts_prefilter_bare():
    known, extra = parse_opts(split_opts("--prefilter"))
    assert known["prefilter"] is True
    assert extra == []


def test_parse_opts_prefilter_with_value():
    known, extra = parse_opts(split_opts("--prefilter myfilter=1:2:3"))
    assert known["prefilter"] == "myfilter=1:2:3"
    assert extra == []


def test_parse_opts_prefilter_followed_by_another_flag():
    # The next token is a value only if it does NOT start with "--" -
    # "--prefilter --mono" is bare --prefilter (const default) then
    # --mono, not --prefilter with value "--mono".
    known, extra = parse_opts(split_opts("--prefilter --mono"))
    assert known["prefilter"] is True
    assert known["mono"] is True
    assert extra == []


def test_deviations_prefilter_three_states():
    c = cfg()
    base = effective_settings(c, "001")

    off = dict(base)
    assert deviations(off, c) == []                  # untouched: nothing

    on_default = dict(base); on_default["prefilter"] = True
    assert deviations(on_default, c) == ["--prefilter"]

    on_explicit = dict(base); on_explicit["prefilter"] = "myfilter=1:2:3"
    assert deviations(on_explicit, c) == ["--prefilter", "myfilter=1:2:3"]


def test_parse_opts_and_deviations_kf_cadence():
    known, extra = parse_opts(split_opts("--kf-cadence 2.5"))
    assert known["kf_cadence"] == "2.5"
    assert extra == []

    c = cfg()
    base = effective_settings(c, "001")
    s = dict(base); s["kf_cadence"] = "2.5"
    assert deviations(s, c) == ["--kf-cadence", "2.5"]


def test_deviations_kf_cadence_zero_emits():
    # videnc's argparse default is None but the encoder applies 5.0
    # internally - "5.0" (the Knob default here) untouched must emit
    # nothing, and "0" (a real value: it DISABLES the cadence) must
    # still emit --kf-cadence 0, not be swallowed by a falsy check.
    c = cfg()
    base = effective_settings(c, "001")

    untouched = dict(base)
    assert deviations(untouched, c) == []

    disabled = dict(base); disabled["kf_cadence"] = "0"
    assert deviations(disabled, c) == ["--kf-cadence", "0"]


def test_no_merge_and_direct_transport_factor_stay_unmapped():
    # Deliberately excluded (bench-fixture-only / expert gate override) -
    # they must still round-trip harmlessly through the extra passthrough.
    known, extra = parse_opts(split_opts("--no-merge"))
    assert "no_merge" not in known
    assert extra == ["--no-merge"]

    known2, extra2 = parse_opts(split_opts("--direct-transport-factor 1.1"))
    assert "direct_transport_factor" not in known2
    assert extra2 == ["--direct-transport-factor", "1.1"]


def test_approx_cuts_and_ocopy_removed_fall_back_to_extra():
    # --approx-cuts and --ocopy were mapped as Knob rows briefly
    # (2026-08-02) and REMOVED the same day when the owner pulled both
    # options from the encoder. No special-casing: an existing
    # --approx-cuts/--ocopy in a user's VIDOPTS_NNN simply falls back to
    # the extra passthrough, preserved verbatim - the same graceful path
    # every other unmapped flag takes.
    known, extra = parse_opts(split_opts("--ocopy --approx-cuts"))
    assert "ocopy" not in known and "approx_cuts" not in known
    assert extra == ["--ocopy", "--approx-cuts"]

    c = cfg(per_clip={"003": "--ocopy --approx-cuts"})
    s = effective_settings(c, "003")
    assert deviations(s, c) == ["--ocopy", "--approx-cuts"]


def test_deviations_extra_pairwise_no_orphaned_value():
    # Ledgered minor, now fixed: a global "--foo A" plus a per-clip
    # "--foo B" used to filter token-by-token, keeping the orphaned "B"
    # (its flag "--foo" was in base's extra, so excluded) and corrupting
    # the arg vector. Whole (flag, value) UNITS must be diffed instead.
    c = cfg(vid_opts="--foo A", per_clip={"003": "--foo B"})
    s = effective_settings(c, "003")
    assert s["extra"] == ["--foo", "A", "--foo", "B"]
    assert deviations(s, c) == ["--foo", "B"]


def test_deviations_extra_pairwise_unchanged_value_not_reemitted():
    c = cfg(vid_opts="--foo A", per_clip={"003": "--foo A"})
    s = effective_settings(c, "003")
    assert deviations(s, c) == []
