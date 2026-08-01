import hashlib
from pathlib import Path

from vidtune.kitmodel import find_kit_root, parse_config, list_clips, arg_hash, clip_state, read_generation_stamp


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


def test_read_generation_stamp(fixture_kit):
    (fixture_kit / "lib" / "video.ps1").write_text(
        "# header\n$encoderGeneration = 'pal9k'\nrest\n")
    assert read_generation_stamp(fixture_kit) == "pal9k"


def test_read_generation_stamp_missing(fixture_kit):
    assert read_generation_stamp(fixture_kit) is None


def test_arg_hash_matches_powershell_recipe():
    # Same recipe as video.ps1 Get-ArgHash: MD5(utf8(join ' ')), first 8 hex.
    expected = hashlib.md5("pal9k --shape 16:9".encode()).hexdigest()[:8]
    assert arg_hash("pal9k", ["--shape", "16:9"]) == expected
    assert len(arg_hash("pal9k", [])) == 8


def test_clip_state_lifecycle(fixture_kit):
    from vidtune.kitmodel import KitConfig, list_clips
    cfg = KitConfig(per_clip={"002": "--shape 16:9"})
    c001, c002 = list_clips(fixture_kit)
    assert clip_state(c001, cfg, "pal9k") == (False, True)   # no .vid yet
    # fresh: vid newer than mp4 + matching sidecar
    c002.vid.write_bytes(b"v")
    c002.sidecar.write_text(arg_hash("pal9k", ["--shape", "16:9"]))
    assert clip_state(c002, cfg, "pal9k") == (True, False)
    # config change flips it stale
    cfg2 = KitConfig(per_clip={"002": "--shape scope"})
    assert clip_state(c002, cfg2, "pal9k") == (True, True)
    # unknown stamp: stale, conservatively
    assert clip_state(c002, cfg, None) == (True, True)
