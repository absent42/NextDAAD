"""stage.ps1 -WhatIf: lists exactly the four sd writes, in build order, and builds nothing;
raw logs left in a LEG303 folder refuse the run before any step."""
import re
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).parent
STAGE = HERE / "stage.ps1"


def _run(sd_root):
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(STAGE), "-WhatIf",
                           "-SdRoot", str(sd_root)],
                          capture_output=True, text=True, timeout=60)


def _plan(sd_root):
    r = _run(sd_root)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.splitlines()


def test_stage_dry(tmp_path):
    lines = _plan(tmp_path)
    writes = [l for l in lines if l.startswith("WRITE ")]
    assert writes == ["WRITE sd\\LEG303A\\", "WRITE sd\\LEG303B\\", "WRITE sd\\LEG303C\\",
                      "WRITE sd\\LEG303.TXT"], writes
    for l in lines:
        for m in re.findall(r"sd\\\S+", l):
            assert l.startswith("WRITE ") or m.startswith("sd\\NXBENCH"), l
    order = ["ingest first", "bench\\build.ps1", "check_quiet_decode.py",
             "check_quiet_decode.py --bench", "build.ps1 -Bench,", "build-tests.ps1 -NxBench",
             "build.ps1 -BenchQuiet", "GATES.TXT"]
    pos = []
    for key in order:
        hits = [i for i, l in enumerate(lines) if key in l]
        assert hits, key
        pos.append(hits[0])
    assert pos == sorted(pos), pos
    assert max(pos) < lines.index(writes[0])


@pytest.mark.parametrize("name", ["CORE303.LOG", "BENCH303.LOG", "NXBENCH-Q.TXT",
                                  "nxbench2.txt"])
def test_stage_refuses_raw_logs(tmp_path, name):
    leg = tmp_path / "LEG303B"
    leg.mkdir()
    (leg / "GATES.TXT").write_bytes(b"stamp: abc1234\n")
    (leg / name).write_bytes(b"#CORE303 BENCH abc1234\n")
    r = _run(tmp_path)
    assert r.returncode != 0
    assert "ingest first" in r.stdout + r.stderr
    assert "STEP 1" not in r.stdout
    assert sorted(p.name for p in leg.iterdir()) == sorted(["GATES.TXT", name])


def test_stage_ignores_other_files(tmp_path):
    leg = tmp_path / "LEG303C"
    leg.mkdir()
    for n in ("GATES.TXT", "NEXTDAAD.NEX", "NXB0.BIN"):
        (leg / n).write_bytes(b"x")
    (tmp_path / "LEG303.TXT").write_bytes(b"x")
    (tmp_path / "OTHER").mkdir()
    (tmp_path / "OTHER" / "X.LOG").write_bytes(b"x")
    assert any(l.startswith("STEP 1") for l in _plan(tmp_path))
