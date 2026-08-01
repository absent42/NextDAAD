from pathlib import Path

from vidtune.kitmodel import find_kit_root, parse_config, list_clips


def test_find_kit_root_from_subdir(fixture_kit):
    sub = fixture_kit / "VIDEO"
    assert find_kit_root(sub) == fixture_kit


def test_find_kit_root_none(tmp_path):
    assert find_kit_root(tmp_path) is None


def test_parse_config(fixture_kit):
    cfg = parse_config(fixture_kit / "CONFIG.BAT")
    assert cfg.vid_aspect == ""
    assert cfg.vid_fps == ""
    assert cfg.vid_opts == ""
    assert cfg.toolsdir == "tools"
    assert cfg.per_clip == {"002": "--shape 16:9"}
    assert cfg.vidprofile == ""


def test_list_clips(fixture_kit):
    clips = list_clips(fixture_kit)
    assert [c.num3 for c in clips] == ["001", "002"]
    assert clips[0].mp4.name == "1.mp4"          # source keeps its own name
    assert clips[0].vid.name == "1.vid"          # cache sits beside the source
    assert clips[0].sidecar.name == "1.vid.args"
