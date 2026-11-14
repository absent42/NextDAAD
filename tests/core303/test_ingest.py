import hashlib
from pathlib import Path

import pytest

import ingest
from ingest import IngestError

NR = "#NR 01=00 0E=00 0F=00 03=30 05=00 07=03"
NXB = ("#NXB test\n> nxbo\nN016 O=01 R=0040 F=0040 D=0000\n")


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def core_log(stamp="abc1234"):
    rows = ["CAL0 C=W S=3 R=0040 F=0040 D=0000 N=0001"]
    lines = ["#CORE303 STANDALONE " + stamp, NR, "#SRAM 2048"] + rows + ["#END 0001"]
    return ("\n".join(lines) + "\n").encode("ascii")


def leg(tmp_path, name="sd", stamp="abc1234", log_stamp=None, nxb=False):
    d = tmp_path / name
    d.mkdir()
    (d / "GATES.TXT").write_bytes(("stamp: %s\nbuilt: x\n" % stamp).encode())
    if nxb:
        (d / "NXBENCH.TXT").write_bytes(NXB.encode())
    else:
        (d / "CORE303.LOG").write_bytes(core_log(log_stamp or stamp))
    (d / "GAME.NEX").write_bytes(b"not copied")
    return d


def results(tmp_path):
    r = tmp_path / "results"
    r.mkdir()
    (r / "INDEX.md").write_bytes(
        b"| date | board | leg | verdict | folder |\n|---|---|---|---|---|\n")
    return r


def run(d, res, leg_name="leg1", date="2026-11-20", **kw):
    return ingest.ingest(d, "ks1", leg_name, date, res, **kw)


def test_copies_raw_bytes(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    out = run(d, res)
    for n in ("CORE303.LOG", "GATES.TXT"):
        assert sha(out / n) == sha(d / n)
    assert (out / "sitting.txt").exists() and (out / "report.md").exists()
    assert not (out / "GAME.NEX").exists()


def test_refuses_stamp_mismatch(tmp_path):
    d, res = leg(tmp_path, stamp="abc1234", log_stamp="def5678"), results(tmp_path)
    with pytest.raises(IngestError):
        run(d, res)
    assert not (res / "2026-11-20-ks1-leg1").exists()


def test_refuses_existing_folder(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    run(d, res)
    with pytest.raises(IngestError):
        run(d, res)


def test_index_row_appended(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    before = (res / "INDEX.md").read_text().splitlines()
    run(d, res)
    after = (res / "INDEX.md").read_text().splitlines()
    assert len(after) == len(before) + 1
    assert after[-1].startswith("| 2026-11-20 | ks1 | leg1 |")
    assert after[-1].endswith("| 2026-11-20-ks1-leg1 |")


def test_refuses_dirty(tmp_path):
    d, res = leg(tmp_path, stamp="abc1234-dirty"), results(tmp_path)
    with pytest.raises(IngestError):
        run(d, res)


def test_missing_index_leaves_nothing(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    (res / "INDEX.md").unlink()
    with pytest.raises(IngestError):
        run(d, res)
    assert sorted(p.name for p in res.iterdir()) == []


def test_copy_failure_leaves_nothing(tmp_path, monkeypatch):
    d, res = leg(tmp_path), results(tmp_path)
    before = (res / "INDEX.md").read_bytes()
    real, calls = ingest.shutil.copyfile, []

    def flaky(src, dst):
        calls.append(src)
        if len(calls) == 2:
            raise OSError("disk full")
        return real(src, dst)
    monkeypatch.setattr(ingest.shutil, "copyfile", flaky)
    with pytest.raises(OSError):
        run(d, res)
    assert sorted(p.name for p in res.iterdir()) == ["INDEX.md"]
    assert (res / "INDEX.md").read_bytes() == before


def test_refuses_stale_partial(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    (res / ".2026-11-20-ks1-leg1.partial").mkdir()
    with pytest.raises(IngestError):
        run(d, res)


GATES_B = ("stamp: abc1234\nbuilt: 2026-11-14\nquiet_check: OK quiet 92 routines\n"
           "bench_check: OK bench 14 routines\nnex_sha256: %s\nddb_sha256: %s\n"
           % ("a" * 64, "b" * 64))


def test_gates_extra_keys_and_section(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    (d / "GATES.TXT").write_bytes(GATES_B.encode("ascii"))
    out = run(d, res)
    assert "stamp: abc1234" in (out / "sitting.txt").read_text()
    assert (out / "GATES.TXT").read_bytes() == GATES_B.encode("ascii")
    rep = (out / "report.md").read_text()
    tail = rep[rep.index("## Gates"):].splitlines()
    assert tail == ["## Gates", "", "- quiet_check: OK quiet 92 routines",
                    "- bench_check: OK bench 14 routines"], tail
    assert "ddb_sha256" not in rep


def test_gates_section_missing_lines(tmp_path):
    d, res = leg(tmp_path), results(tmp_path)
    rep = (run(d, res) / "report.md").read_text()
    assert "- quiet_check: MISSING from GATES.TXT" in rep
    assert "- bench_check: MISSING from GATES.TXT" in rep


def test_leg3_needs_leg1(tmp_path):
    res = results(tmp_path)
    d3 = leg(tmp_path, "sd3", nxb=True)
    with pytest.raises(IngestError):
        run(d3, res, "leg3")
    run(leg(tmp_path, "sd1"), res, "leg1")
    out = run(d3, res, "leg3")
    s = (out / "sitting.txt").read_text()
    assert "timing_from: 2026-11-20-ks1-leg1" in s
    assert NR in s
    assert (out / "NXBENCH.TXT").read_bytes() == NXB.encode()
    assert "## NXB" in (out / "report.md").read_text()
