import pytest

from vidtune.configwrite import (ConfigConflict, config_stamp, write_sidecar,
                                 write_vidopts_line)
from vidtune.kitmodel import arg_hash, parse_config

CFG, LOC = "CONFIG.BAT", "CONFIG.local.BAT"


def test_creates_local_and_leaves_config_untouched(fixture_kit):
    before = (fixture_kit / CFG).read_bytes()
    write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    assert (fixture_kit / CFG).read_bytes() == before
    loc = (fixture_kit / LOC).read_bytes()
    assert loc.endswith(b"SET VIDOPTS_005=--direct\r\n") and b"\r\n\r\n" not in loc
    assert parse_config(fixture_kit / CFG).per_clip["005"] == "--direct"
    assert not (fixture_kit / "CONFIG.local.BAT.bak").exists()


def test_override_of_config_line_goes_local(fixture_kit):
    write_vidopts_line(fixture_kit / CFG, "002", "--shape scope")
    assert b"--shape 16:9" in (fixture_kit / CFG).read_bytes()
    assert parse_config(fixture_kit / CFG).per_clip["002"] == "--shape scope"


def test_reset_of_config_value_writes_empty_mask(fixture_kit):
    write_vidopts_line(fixture_kit / CFG, "002", "")
    assert b"SET VIDOPTS_002=\r\n" in (fixture_kit / LOC).read_bytes()
    assert "002" not in parse_config(fixture_kit / CFG).per_clip


def test_reset_of_local_only_value_deletes_line(fixture_kit):
    write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    write_vidopts_line(fixture_kit / CFG, "005", "")
    assert b"VIDOPTS_005" not in (fixture_kit / LOC).read_bytes()


def test_reset_with_nothing_anywhere_creates_no_file(fixture_kit):
    write_vidopts_line(fixture_kit / CFG, "009", "")
    assert not (fixture_kit / LOC).exists()


def test_existing_local_preserved_lf_no_trailing_newline(fixture_kit):
    (fixture_kit / LOC).write_bytes(b"SET RUN=0\nSET TOOLSDIR=..\\tools")
    write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    got = (fixture_kit / LOC).read_bytes()
    assert got.startswith(b"SET RUN=0\nSET TOOLSDIR=..\\tools\n")
    assert b"SET VIDOPTS_005=--direct" in got and b"\r" not in got
    assert (fixture_kit / "CONFIG.local.BAT.bak").read_bytes() == b"SET RUN=0\nSET TOOLSDIR=..\\tools"


def test_stamp_conflict_refused_on_either_file(fixture_kit):
    stamp = config_stamp(fixture_kit / CFG)
    (fixture_kit / LOC).write_bytes(b"SET RUN=0\r\n")   # appears after load
    with pytest.raises(ConfigConflict):
        write_vidopts_line(fixture_kit / CFG, "005", "--direct", expected_stamp=stamp)
    assert b"VIDOPTS_005" not in (fixture_kit / LOC).read_bytes()


def test_write_sidecar(tmp_path):
    sc = tmp_path / "003.vid.args"
    write_sidecar(sc, "pal9k", ["--direct"])
    assert sc.read_bytes() == arg_hash("pal9k", ["--direct"]).encode()  # no newline


def test_insert_with_no_vidopts_anchor(tmp_path):
    """Existing local without VIDOPTS lines gains the new line at the end."""
    cfg = tmp_path / CFG
    cfg.write_bytes(b"@echo off\r\n")
    loc = tmp_path / LOC
    original = b"@echo off\r\nSET RUN=0\r\n"
    loc.write_bytes(original)

    write_vidopts_line(cfg, "005", "--direct")

    assert loc.read_bytes() == original + b"SET VIDOPTS_005=--direct\r\n"
    assert parse_config(cfg).per_clip["005"] == "--direct"


def test_noop_reset_verifies_readback(fixture_kit, monkeypatch):
    import vidtune.configwrite as cw
    monkeypatch.setattr(cw, "parse_config", _lying_parse(cw.parse_config))
    with pytest.raises(RuntimeError):
        write_vidopts_line(fixture_kit / CFG, "009", "")


def _lying_parse(real):
    def parse(*a, **k):
        cfg = real(*a, **k)
        if k.get("local_path") is None:
            cfg.per_clip["009"] = "--ghost"
        return cfg
    return parse


def test_quoted_local_line_replaced(fixture_kit):
    (fixture_kit / LOC).write_bytes(b'SET "VIDOPTS_005=--old"\r\n')
    write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    assert (fixture_kit / LOC).read_bytes() == b"SET VIDOPTS_005=--direct\r\n"
    assert parse_config(fixture_kit / CFG).per_clip["005"] == "--direct"


def test_quoted_local_only_reset_removes_it(fixture_kit):
    (fixture_kit / LOC).write_bytes(b'@echo off\r\nSET "VIDOPTS_005=--old"\r\n')
    write_vidopts_line(fixture_kit / CFG, "005", "")
    assert b"VIDOPTS_005" not in (fixture_kit / LOC).read_bytes()
    assert "005" not in parse_config(fixture_kit / CFG).per_clip


def test_mixed_eol_reset_and_replace(fixture_kit):
    (fixture_kit / LOC).write_bytes(b"SET RUN=0\nSET VIDOPTS_005=--direct\r\n")
    write_vidopts_line(fixture_kit / CFG, "005", "--shape scope")
    assert (fixture_kit / LOC).read_bytes() == \
        b"SET RUN=0\nSET VIDOPTS_005=--shape scope\r\n"
    write_vidopts_line(fixture_kit / CFG, "005", "")
    assert (fixture_kit / LOC).read_bytes() == b"SET RUN=0\n"
    assert "005" not in parse_config(fixture_kit / CFG).per_clip


def test_stamp_conflict_when_config_changes(fixture_kit):
    import os
    stamp = config_stamp(fixture_kit / CFG)
    st = (fixture_kit / CFG).stat()
    os.utime(fixture_kit / CFG, (st.st_atime, st.st_mtime + 10))
    with pytest.raises(ConfigConflict):
        write_vidopts_line(fixture_kit / CFG, "005", "--direct", expected_stamp=stamp)
    assert not (fixture_kit / LOC).exists()


def test_atomic_write_failure_keeps_original(fixture_kit, monkeypatch):
    import os
    import vidtune.configwrite as cw
    loc = fixture_kit / LOC
    original = b"@echo off\r\nSET VIDOPTS_005=--old\r\n"
    loc.write_bytes(original)

    def boom(*a, **k):
        raise OSError("replace failed")
    monkeypatch.setattr(cw.os, "replace", boom)
    with pytest.raises(OSError):
        write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    assert loc.read_bytes() == original
    assert not list(fixture_kit.glob("*.tmp"))


def test_zero_byte_local_gets_crlf_and_no_header(fixture_kit):
    before = (fixture_kit / CFG).read_bytes()
    (fixture_kit / LOC).write_bytes(b"")
    write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    assert (fixture_kit / LOC).read_bytes() == b"SET VIDOPTS_005=--direct\r\n"
    assert (fixture_kit / CFG).read_bytes() == before


def _wrong_read(real):
    def parse(*a, **k):
        cfg = real(*a, **k)
        if k.get("local_path") is None:
            cfg.per_clip["005"] = "--ghost"
        return cfg
    return parse


def test_verify_error_created_this_call(fixture_kit, monkeypatch):
    import vidtune.configwrite as cw
    monkeypatch.setattr(cw, "parse_config", _wrong_read(cw.parse_config))
    with pytest.raises(RuntimeError) as ei:
        write_vidopts_line(fixture_kit / CFG, "005", "--direct")
    msg = str(ei.value)
    assert "delete the new CONFIG.local.BAT" in msg and ".bak" not in msg


def test_verify_error_with_bak(fixture_kit, monkeypatch):
    import vidtune.configwrite as cw
    (fixture_kit / LOC).write_bytes(b"SET VIDOPTS_005=--old\r\n")
    monkeypatch.setattr(cw, "parse_config", _wrong_read(cw.parse_config))
    with pytest.raises(RuntimeError, match="restore from CONFIG.local.BAT.bak"):
        write_vidopts_line(fixture_kit / CFG, "005", "--direct")
