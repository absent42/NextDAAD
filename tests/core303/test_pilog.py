import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import ingest
import parse
from ingest import IngestError
from parse import LogError

HERE = Path(__file__).parent
STAGED = HERE / "results" / "2026-11-14-ks1-staged"
NR = "#NR 01=00 0E=00 0F=00 03=30 05=00 07=03"
BUNDLE = "0123456789ab"


def pilog_text(rows=("P3WS rate=2000000 n=5", "P3RD rate=2500000 n=0"), end=None,
               bundle=BUNDLE, nl="\n"):
    lines = ["#PI303 spisweep " + bundle,
             "#PIENV model=zero1.3 arm=700 kernel=6.1.21 spi_open=12,34",
             "#SPI version=01 caps=FF core_clk=0 core_clk_src=none"]
    lines += list(rows)
    lines += ["#SKIP P3FR FRAMING"]
    lines += ["#END %04X" % (len(rows) if end is None else end)]
    return nl.join(lines) + nl


def write(tmp_path, text, name="PI.LOG"):
    p = tmp_path / name
    p.write_bytes(text.encode("ascii"))
    return p


def test_pilog_parses(tmp_path):
    for nl in ("\n", "\r\n"):
        pl = parse.parse_pilog(write(tmp_path, pilog_text(nl=nl)))
        assert (pl.tool, pl.bundle) == ("spisweep", BUNDLE)
        assert pl.env["arm"] == "700" and pl.env["spi_open"] == "12,34"
        assert pl.spi["caps"] == "FF" and pl.spi["core_clk_src"] == "none"
        assert [r.tag for r in pl.rows] == ["P3WS", "P3RD"]
        assert pl.rows[0].fields == {"rate": 2000000, "n": 5}
        assert pl.skips == [("P3FR", "FRAMING")]


def test_pilog_busy_lock(tmp_path):
    p = write(tmp_path, "#PI303 spisweep %s\n#SKIP BUSY LOCK\n#END 0000\n" % BUNDLE)
    pl = parse.parse_pilog(p)
    assert pl.rows == [] and pl.skips == [("BUSY", "LOCK")]


def test_pilog_truncated(tmp_path):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text().replace("#END 0002\n", "")))
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text().rstrip("\n")))


@pytest.mark.parametrize("row", ["P3WS b2-3=4", "P3WS 2b=4", "P3WS rate=x", "P3WS rate=",
                                 "P3WS rate", "P3W rate=1", "p3ws rate=1",
                                 "P3WS rate=1 rate=2"])
def test_pilog_bad_row_raises(tmp_path, row):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text(rows=(row,))))


def test_pilog_bad_key_raises(tmp_path):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text(rows=("P3WS b2-3=4",))))


def test_pilog_unknown_tag_raises(tmp_path):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text(rows=("ZZZZ rate=1",))))
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text().replace("P3FR", "ZZZZ")))


def test_core_log_rejects_pi_tag(tmp_path):
    p = tmp_path / "C.LOG"
    p.write_bytes(("#CORE303 STANDALONE abc1234\n" + NR + "\n#SRAM 2048\n"
                   "P0IM C=W S=3 R=0040 F=0040 D=0000 N=0001\n#END 0001\n").encode())
    with pytest.raises(LogError):
        parse.parse_log(p)


def test_pienv_empty_value_ok(tmp_path):
    t = pilog_text().replace("spi_open=12,34", "spi_open=")
    assert parse.parse_pilog(write(tmp_path, t)).env["spi_open"] == ""
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text().replace("version=01", "version=")))


def test_pilog_bare_row_raises(tmp_path):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text(rows=("P3WS",))))


def test_pilog_row_before_header_raises(tmp_path):
    t = pilog_text()
    lines = t.split("\n")
    lines.insert(0, "P3WS rate=1")
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, "\n".join(lines)))


def test_pilog_count_mismatch_and_unknown_line(tmp_path):
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text(end=5)))
    with pytest.raises(LogError):
        parse.parse_pilog(write(tmp_path, pilog_text().replace("#SKIP", "#WHAT")))


def test_report_pi(tmp_path):
    pl = parse.parse_pilog(write(tmp_path, pilog_text()))
    txt = parse.report_pi([pl], [])
    assert "spisweep" in txt and BUNDLE in txt and "P3WS" in txt and "SKIP P3FR FRAMING" in txt


# Pi-read comparison ---------------------------------------------------------

def core_run(stamp="abc1234", n=1):
    lines = ["#CORE303 STANDALONE " + stamp, NR, "#SRAM 2048"]
    lines += ["CAL0 C=W S=3 R=0040 F=0040 D=0000 N=0001",
              "P1NP C=W S=3 R=0040 F=%04X D=0000 N=0001" % (0x40 + n), "#END 0002"]
    return ("\n".join(lines) + "\n").encode("ascii")


def pi_leg(tmp_path, sd_bytes, pi_bytes, name="sd"):
    d = tmp_path / name
    d.mkdir()
    (d / "GATES.TXT").write_bytes(b"stamp: abc1234\nbuilt: x\n")
    (d / "CORE303.LOG").write_bytes(sd_bytes)
    if pi_bytes is not None:
        (d / "PI_CORE303.LOG").write_bytes(pi_bytes)
    return d


def results(tmp_path):
    r = tmp_path / "results"
    r.mkdir(exist_ok=True)
    idx = r / "INDEX.md"
    if not idx.exists():
        idx.write_bytes(b"| date | board | leg | verdict | folder |\n|---|---|---|---|---|\n")
    return r


def run(d, res, leg="leg1", board="ks1", date="2026-11-20", **kw):
    return ingest.ingest(d, board, leg, date, res, **kw)


def test_pi_read_compares_last_run(tmp_path):
    run1, run2 = core_run(n=1), core_run(n=2)
    d = pi_leg(tmp_path, run1 + run2, run2)
    rep = (run(d, results(tmp_path)) / "report.md").read_text()
    assert "PI-READ MATCH" in rep and "MISMATCH" not in rep
    assert (run(pi_leg(tmp_path, run1 + run2, run1, "sd2"), results(tmp_path), "leg2")
            / "report.md").read_text().count("PI-READ MISMATCH first_offset=") == 1


def test_pi_read_mismatch_is_finding(tmp_path):
    sd = core_run()
    pi = bytearray(sd)
    pi[40] ^= 0x01
    d = pi_leg(tmp_path, sd, bytes(pi))
    out = run(d, results(tmp_path))
    assert "PI-READ MISMATCH first_offset=40" in (out / "report.md").read_text()
    assert (out / "PI_CORE303.LOG").read_bytes() == bytes(pi)


def test_pi_read_truncated_copy_offset(tmp_path):
    sd = core_run()
    d = pi_leg(tmp_path, sd, sd[:30])
    out = run(d, results(tmp_path))
    assert "PI-READ MISMATCH first_offset=30" in (out / "report.md").read_text()


# Manifest verify ------------------------------------------------------------

def test_verify_staged_clean():
    assert ingest.verify_staged(STAGED) == []


def stage_copy(tmp_path):
    dst = tmp_path / "staged"
    shutil.copytree(STAGED, dst)
    return dst


def test_verify_staged_detects_change(tmp_path):
    dst = stage_copy(tmp_path)
    f = dst / "LEG303A" / "CORE303.NEX"
    b = bytearray(f.read_bytes())
    b[100] ^= 0xFF
    f.write_bytes(bytes(b))
    bad = ingest.verify_staged(dst)
    assert len(bad) == 1 and "LEG303A/CORE303.NEX" in bad[0]


def test_verify_staged_missing_and_extra(tmp_path):
    dst = stage_copy(tmp_path)
    (dst / "LEG303C" / "NXB3.BIN").unlink()
    (dst / "LEG303C" / "STRAY.NEX").write_bytes(b"x")
    (dst / "LEG303C" / "RUN.LOG").write_bytes(b"logs are ignored")
    bad = ingest.verify_staged(dst)
    assert len(bad) == 2
    assert any("NXB3.BIN" in l for l in bad) and any("STRAY.NEX" in l for l in bad)


def test_verify_staged_cli_exit(tmp_path):
    cmd = [sys.executable, str(HERE / "ingest.py"), "--verify-staged"]
    ok = subprocess.run(cmd + [str(STAGED)], capture_output=True, text=True)
    assert ok.returncode == 0, ok.stderr
    dst = stage_copy(tmp_path)
    f = dst / "LEG303B" / "GAME.DDB"
    f.write_bytes(f.read_bytes() + b"\0")
    bad = subprocess.run(cmd + [str(dst)], capture_output=True, text=True)
    assert bad.returncode != 0 and "LEG303B/GAME.DDB" in bad.stdout + bad.stderr


# GATES by leg kind ----------------------------------------------------------

def pi_gates_leg(tmp_path, gates, pilog=None, name="sdp", core=None):
    d = tmp_path / name
    d.mkdir()
    (d / "GATES.TXT").write_bytes(gates.encode("ascii"))
    (d / "PI303.LOG").write_bytes((pilog or pilog_text()).encode("ascii"))
    if core is not None:
        (d / "CORE303.LOG").write_bytes(core)
    return d


def test_gates_pi_leg_bundle_only(tmp_path):
    d = pi_gates_leg(tmp_path, "bundle: %s\nframes: ffee00112233\n" % BUNDLE)
    out = run(d, results(tmp_path), "p2", "ks1")
    assert "bundle: " + BUNDLE in (out / "sitting.txt").read_text()
    rep = (out / "report.md").read_text()
    assert "spisweep" in rep and "MISSING" not in rep


def test_gates_bundle_mismatch_refused(tmp_path):
    d = pi_gates_leg(tmp_path, "bundle: ffffffffffff\nframes: x\n")
    res = results(tmp_path)
    with pytest.raises(IngestError):
        run(d, res, "p2")
    assert not (res / "2026-11-20-ks1-p2").exists()


def test_gates_neither_key_refused(tmp_path):
    d = pi_gates_leg(tmp_path, "built: x\nframes: y\n")
    with pytest.raises(IngestError):
        run(d, results(tmp_path), "p2")


def test_gates_p3_stamp_and_bundle(tmp_path):
    g = "bundle: %s\nframes: x\nstamp: abc1234\nnex_sha256: %s\n" % (BUNDLE, "a" * 64)
    d = pi_gates_leg(tmp_path, g, core=core_run())
    run(d, results(tmp_path), "p3")
    d2 = pi_gates_leg(tmp_path, g.replace("stamp: abc1234", "stamp: zzz9999"),
                      core=core_run(), name="sdq")
    with pytest.raises(IngestError):
        run(d2, results(tmp_path), "p3b")


def test_gates_optional_checks_listed(tmp_path):
    g = "bundle: %s\nframes: x\nquiet_check: OK q\n" % BUNDLE
    out = run(pi_gates_leg(tmp_path, g), results(tmp_path), "p2")
    rep = (out / "report.md").read_text()
    assert "- quiet_check: OK q" in rep and "bench_check" not in rep


def test_gates_rerun_keys(tmp_path):
    g = ("stamp: abc1234\nbuilt: 2026-11-14\nquiet_check: OK a\nbench_check: OK b\n"
         "nex_sha256: %s\nddb_sha256: %s\nrerun_of: 2026-11-14-ks1\n" % ("a" * 64, "b" * 64))
    d = pi_leg(tmp_path, core_run(), None)
    (d / "GATES.TXT").write_bytes(g.encode("ascii"))
    out = run(d, results(tmp_path), "leg1", "ks3")
    s = (out / "sitting.txt").read_text()
    assert "rerun_of: 2026-11-14-ks1" in s
    rep = (out / "report.md").read_text()
    assert "- quiet_check: OK a" in rep and "- bench_check: OK b" in rep


def test_out_dir_logs_copied(tmp_path):
    d = pi_gates_leg(tmp_path, "bundle: %s\nframes: x\n" % BUNDLE)
    (d / "PI303.LOG").unlink()
    (d / "out").mkdir()
    (d / "out" / "PI303.LOG").write_bytes(pilog_text().encode("ascii"))
    out = run(d, results(tmp_path), "p2")
    assert (out / "out" / "PI303.LOG").is_file()


# KS1/KS3 compare ------------------------------------------------------------

def test_ks1_ks3_compare_lines(tmp_path):
    res = results(tmp_path)
    d1 = pi_leg(tmp_path, core_run(n=0), None, "k1")
    run(d1, res, "leg1", "ks1", "2026-11-14")
    d3 = pi_leg(tmp_path, core_run(n=8), None, "k3")
    out = run(d3, res, "leg1", "ks3", "2026-11-20")
    lines = [l for l in (out / "report.md").read_text().splitlines()
             if l.startswith("KS1/KS3 ")]
    assert lines and lines[0].startswith("KS1/KS3 P1NP ks1=") and " ks3=" in lines[0]
    other = run(pi_leg(tmp_path, core_run(), None, "k4"), res, "leg2", "ks3", "2026-11-21")
    assert "KS1/KS3" not in (other / "report.md").read_text()
