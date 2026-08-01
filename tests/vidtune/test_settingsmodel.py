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
