import pytest

from vidtune.configwrite import ConfigConflict, write_sidecar, write_vidopts_line
from vidtune.kitmodel import arg_hash, parse_config


def config_bytes(kit):
    return (kit / "CONFIG.BAT").read_bytes()


def test_update_existing_line_preserves_rest(fixture_kit):
    before = config_bytes(fixture_kit)
    write_vidopts_line(fixture_kit / "CONFIG.BAT", "002", "--shape scope")
    after = config_bytes(fixture_kit)
    assert b"SET VIDOPTS_002=--shape scope\r\n" in after
    # only that one line differs
    changed = [(a, b) for a, b in
               zip(before.split(b"\r\n"), after.split(b"\r\n")) if a != b]
    assert changed == [(b"SET VIDOPTS_002=--shape 16:9",
                        b"SET VIDOPTS_002=--shape scope")]
    assert (fixture_kit / "CONFIG.BAT.bak").read_bytes() == before


def test_insert_new_line_after_last_vidopts(fixture_kit):
    write_vidopts_line(fixture_kit / "CONFIG.BAT", "005", "--mono")
    cfg = parse_config(fixture_kit / "CONFIG.BAT")
    assert cfg.per_clip["005"] == "--mono"
    assert cfg.per_clip["002"] == "--shape 16:9"   # untouched
    text = config_bytes(fixture_kit)
    assert text.index(b"VIDOPTS_002") < text.index(b"VIDOPTS_005")


def test_empty_opts_removes_line(fixture_kit):
    write_vidopts_line(fixture_kit / "CONFIG.BAT", "002", "")
    cfg = parse_config(fixture_kit / "CONFIG.BAT")
    assert "002" not in cfg.per_clip
    assert b"VIDOPTS_002" not in config_bytes(fixture_kit)


def test_mtime_conflict_refused(fixture_kit):
    path = fixture_kit / "CONFIG.BAT"
    stale_mtime = path.stat().st_mtime - 100
    with pytest.raises(ConfigConflict):
        write_vidopts_line(path, "002", "--mono", expected_mtime=stale_mtime)
    assert b"--shape 16:9" in config_bytes(fixture_kit)   # unchanged


def test_write_sidecar(tmp_path):
    sc = tmp_path / "003.vid.args"
    write_sidecar(sc, "pal9k", ["--mono"])
    assert sc.read_bytes() == arg_hash("pal9k", ["--mono"]).encode()  # no newline
