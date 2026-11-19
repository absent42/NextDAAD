"""stage.ps1 -WhatIf: lists exactly the four sd writes, in build order, and builds nothing;
raw logs left in a LEG303 folder refuse the run before any step. Phase 2 modes run into
tmp sd and results roots; -PushPi only ever reaches a fake plink/pscp."""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent
STAGE = HERE / "stage.ps1"
REPO = HERE.parents[1]
PI = HERE / "pi"
KS1 = HERE / "results" / "2026-11-14-ks1-staged"
FRAMES = REPO / "build" / "core303" / "frames"
PUSH_TREE = {"-Phase2": REPO / "tests" / "out" / "core303-phase2" / "pi",
             "-P2Only": REPO / "tests" / "out" / "core303-p2only" / "pi"}

import bundle  # noqa: E402  (conftest puts tests/core303 and pi on sys.path)
from ingest import verify_staged  # noqa: E402


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


# Phase 2 modes. pwsh always gets tmp -SdRoot/-ResultsRoot; plink/pscp are fakes or absent.

HOST = "root@10.1.10.107"
P2ARGS = ["-Board", "KS3", "-Date", "2026-11-20"]
ONLYARGS = ["-Board", "ks1pi", "-Date", "2026-11-15"]
PI_LEGS = ["LEG303P0", "LEG303P2", "LEG303P3", "LEG303P4"]

FAKE_PY = r'''import hashlib, json, os, re, sys
from pathlib import Path
with open(os.environ["CORE303_FAKE_LOG"], "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}) + "\n")
cmd = sys.argv[-1]
if sys.argv[1] == "plink" and "bundle_hash" in cmd:
    if os.environ.get("CORE303_FAKE_BAD"):
        print("000000000000 000000000000")
        sys.exit(0)
    root = os.environ["CORE303_FAKE_PI_ROOT"]
    sys.path.insert(0, root)
    import bundle
    paths = [re.sub(r"^/root/core303/[0-9a-f]{12}", lambda m: root, p)
             for p in cmd.rsplit("'", 1)[1].split()]
    print(bundle.bundle_hash(paths[0]), bundle.dir_hash(paths[1]),
          *[hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths[2:]])
'''


def _ps(args, env=None, timeout=900):
    e = {k: v for k, v in os.environ.items() if not k.startswith("CORE303_")}
    e.update(env or {})
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(STAGE)] + [str(a) for a in args],
                          capture_output=True, text=True, timeout=timeout, env=e)


def _ok(r):
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.splitlines()


def _roots(tmp):
    sd, res = tmp / "sd", tmp / "results"
    sd.mkdir()
    res.mkdir()
    return sd, res


def _sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def _gates(p):
    keys = {}
    for line in Path(p).read_text(encoding="ascii").splitlines():
        k, _, v = line.partition(": ")
        keys.setdefault(k, v)
    return keys


def _tree(tmp, dirty=None):
    """A throwaway git repo standing in for the repo's clean-tree check; dirty adds an
    untracked file at that relative path."""
    t = tmp / "tree"
    t.mkdir()
    subprocess.run(["git", "init", "-q", str(t)], check=True)
    if dirty:
        (t / dirty).parent.mkdir(parents=True, exist_ok=True)
        (t / dirty).write_bytes(b"x\n")
    return t


def _fake_pi(tmp, mode, bad=False):
    """plink/pscp stand-ins: each call appends its argv to a JSON-lines log; the remote
    hash check answers from the local push tree, as if the push had landed."""
    d = tmp / "fakepi"
    d.mkdir()
    py = d / "fakepi.py"
    py.write_text(FAKE_PY, encoding="ascii")
    for name in ("plink", "pscp"):
        (d / (name + ".cmd")).write_text('@"%s" "%s" %s %%*\r\n' % (sys.executable, py, name),
                                         encoding="ascii")
    env = {"CORE303_PLINK": str(d / "plink.cmd"), "CORE303_PSCP": str(d / "pscp.cmd"),
           "CORE303_FAKE_LOG": str(d / "calls.jsonl"),
           "CORE303_FAKE_PI_ROOT": str(PUSH_TREE[mode]),
           "CORE303_TREE_ROOT": str(_tree(tmp))}
    if bad:
        env["CORE303_FAKE_BAD"] = "1"
    return env, d / "calls.jsonl"


def _log_in(sd, rel):
    p = sd / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"#PI303 pi303_spi 000000000000\n")


def _cmds(lines):
    return [l for l in lines if l.startswith(("REMOTE ", "RUN ", "FETCH "))]


def _remote_paths(text):
    return re.findall(r"(?<![\w.])/[\w./*-]+", text)


def _under(p, rb):
    return p == rb.rstrip("/") or p.startswith(rb)


def test_rerun_refuses_tampered(tmp_path):
    rec = tmp_path / "2026-11-14-ks1-staged"
    shutil.copytree(KS1, rec)
    f = rec / "LEG303C" / "NXB0.BIN"
    b = bytearray(f.read_bytes())
    b[0] ^= 1
    f.write_bytes(bytes(b))
    sd, _ = _roots(tmp_path)
    r = _ps(["-Ks3Rerun", "-StagedRecord", rec, "-SdRoot", sd])
    assert r.returncode != 0
    assert "MISMATCH LEG303C/NXB0.BIN" in r.stdout + r.stderr
    assert list(sd.iterdir()) == []


def test_rerun_stages_legs(tmp_path):
    sd, _ = _roots(tmp_path)
    _ok(_ps(["-Ks3Rerun", "-SdRoot", sd]))
    assert sorted(p.name for p in sd.iterdir()) == ["LEG303A3", "LEG303B3", "LEG303C3",
                                                     "LEG303R.TXT"]
    want = set()
    for line in (KS1 / "MANIFEST.txt").read_text(encoding="ascii").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        sha, rel, _loc = line.split()
        leg, name = rel.split("/")
        dst = sd / (leg + "3") / name
        want.add((leg + "3", name))
        if name == "GATES.TXT":
            assert dst.read_bytes() == (KS1 / rel).read_bytes() + b"rerun_of: 2026-11-14-ks1\n"
            assert "bundle" not in _gates(dst) and "frames" not in _gates(dst)
        else:
            assert _sha(dst) == sha, rel
    assert {(p.parent.name, p.name) for p in sd.glob("LEG303*3/*")} == want


def test_rerun_whatif_paths(tmp_path):
    sd, _ = _roots(tmp_path)
    lines = _ok(_ps(["-Ks3Rerun", "-WhatIf", "-SdRoot", sd]))
    writes = [l for l in lines if l.startswith("WRITE ")]
    assert writes == ["WRITE sd\\LEG303A3\\", "WRITE sd\\LEG303B3\\", "WRITE sd\\LEG303C3\\",
                      "WRITE sd\\LEG303R.TXT"], writes
    assert "  LEG303B3/001.AKY <- tests/audio/L9.AKY" in lines
    assert "  LEG303C3/NXB9.BIN <- tests\\core303\\results\\2026-11-14-ks1-staged\\LEG303C\\NXB9.BIN" \
        in lines
    assert not _cmds(lines)
    assert not any("build" in l for l in lines), lines
    for l in lines:
        for m in re.findall(r"sd\\\S+", l):
            assert l.startswith(("WRITE ", "STEP 0")), l
    assert list(sd.iterdir()) == []


def test_phase2_whatif_paths(tmp_path):
    sd, res = _roots(tmp_path)
    lines = _ok(_ps(["-Phase2", *P2ARGS, "-WhatIf", "-SdRoot", sd, "-ResultsRoot", res]))
    writes = [l for l in lines if l.startswith("WRITE ")]
    assert writes == ["WRITE build\\core303\\PI303.NEX PI303.MAP PI303V.NEX PI303V.MAP",
                      "WRITE build\\core303\\frames\\",
                      "WRITE %s\\2026-11-20-ks3-staged\\ (as .2026-11-20-ks3-staged.partial,"
                      " renamed when verified)" % res] + \
        ["WRITE sd\\%s\\" % l for l in PI_LEGS] + ["WRITE sd\\LEG303P.TXT"], writes
    assert any("no -AllowDirty" in l for l in lines)
    assert "STEP 0: refuse if git status --porcelain -- tests/core303/pi tests/core303/stage.ps1" \
        " prints anything" in lines
    assert any(_b12() in l for l in lines)
    assert not _cmds(lines)
    assert list(sd.iterdir()) == [] and list(res.iterdir()) == []


def _b12():
    return bundle.bundle_hash(PI)


@pytest.mark.parametrize("rel", ["LEG303P0/PROBE.LOG", "LEG303P2/PREP.LOG", "LEG303P3/PI303.LOG",
                                 "LEG303P3/out/SPI.LOG", "LEG303P4/NXBENCH1.TXT"])
def test_phase2_refuses_logs(tmp_path, rel):
    sd, res = _roots(tmp_path)
    _log_in(sd, rel)
    for extra in (["-WhatIf"], []):
        r = _ps(["-Phase2", *P2ARGS, "-SdRoot", sd, "-ResultsRoot", res] + extra)
        assert r.returncode != 0
        assert "ingest first" in r.stdout + r.stderr
        assert "STEP 1" not in r.stdout
    assert sorted(p.relative_to(sd).as_posix() for p in sd.rglob("*") if p.is_file()) == [rel]
    assert list(res.iterdir()) == []


@pytest.mark.parametrize("log_rel,args,refused", [
    ("LEG303P3/SPI.LOG", ["-Ks3Rerun"], False),
    ("LEG303A3/CORE303.LOG", ["-Ks3Rerun"], True),
    ("LEG303C3/NXBENCH0.TXT", ["-Ks3Rerun"], True),
    ("LEG303A3/CORE303.LOG", ["-Phase2", *P2ARGS], False),
    ("LEG303P2KS1PI/PREP.LOG", ["-Phase2", *P2ARGS], False),
    ("LEG303P2/PREP.LOG", ["-P2Only", *ONLYARGS], False),
    ("LEG303P3/SPI.LOG", ["-P2Only", *ONLYARGS], False),
    ("LEG303P2KS1PI/PREP.LOG", ["-P2Only", *ONLYARGS], True),
])
def test_guard_scoping(tmp_path, log_rel, args, refused):
    sd, res = _roots(tmp_path)
    _log_in(sd, log_rel)
    roots = ["-SdRoot", sd] + ([] if args[0] == "-Ks3Rerun" else ["-ResultsRoot", res])
    r = _ps(args + ["-WhatIf"] + roots)
    assert (r.returncode != 0) == refused, r.stdout + r.stderr
    assert ("ingest first:" in r.stderr) == refused


@pytest.mark.parametrize("args,msg", [
    (["-Phase2", "-Board", "ks3", "-Date", "2026-1-20"], "-Date"),
    (["-Phase2", "-Board", "ks 3", "-Date", "2026-11-20"], "-Board"),
    (["-Phase2", "-Date", "2026-11-20"], "-Board"),
    (["-P2Only", "-Board", "ks1pi"], "-Date"),
    (["-Ks3Rerun", "-Board", "ks3"], "-Board"),
    (["-Phase2", "-P2Only", *ONLYARGS], "exactly one"),
    (["-Bogus"], "unknown arguments: -Bogus"),
    (["-P2Only", *ONLYARGS, "-Phase-2"], "unknown arguments: -Phase-2"),
])
def test_mode_args_checked(tmp_path, args, msg):
    sd, _ = _roots(tmp_path)
    r = _ps(args + ["-WhatIf", "-SdRoot", sd])
    assert r.returncode != 0
    assert msg in r.stdout + r.stderr


def test_p2only_writes_no_nex(tmp_path):
    sd, res = _roots(tmp_path)
    env, log = _fake_pi(tmp_path, "-P2Only")
    lines = _ok(_ps(["-P2Only", *ONLYARGS, "-SdRoot", sd, "-ResultsRoot", res], env))
    assert [p.name for p in sd.iterdir()] == ["LEG303P2KS1PI"]
    assert [p.name for p in (sd / "LEG303P2KS1PI").iterdir()] == ["GATES.TXT"]
    assert not list(sd.rglob("*.NEX")) and not list(sd.rglob("*.MAP"))
    assert list(res.iterdir()) == []
    g = _gates(sd / "LEG303P2KS1PI" / "GATES.TXT")
    assert g["bundle"] == _b12()
    assert g["frames"] == bundle.dir_hash(FRAMES)
    assert "stamp" not in g and "nex_sha256" not in g
    assert not log.exists()
    assert not _cmds(lines)
    w = _ok(_ps(["-P2Only", *ONLYARGS, "-WhatIf", "-SdRoot", sd, "-ResultsRoot", res]))
    assert [l for l in w if l.startswith("WRITE ")] == ["WRITE build\\core303\\frames\\",
                                                        "WRITE sd\\LEG303P2KS1PI\\"]
    assert not any(".NEX" in l or "next\\build.ps1" in l for l in w)


def test_pushpi_requires_flag(tmp_path):
    sd, res = _roots(tmp_path)
    for args in (["-PushPi"], ["-Ks3Rerun", "-PushPi"], ["-PushPi", "-WhatIf"]):
        r = _ps(args + ["-SdRoot", sd, "-ResultsRoot", res])
        assert r.returncode != 0
        assert "-PushPi needs -Phase2 or -P2Only" in r.stdout + r.stderr
    base = ["-P2Only", *ONLYARGS, "-WhatIf", "-SdRoot", sd, "-ResultsRoot", res]
    assert not _cmds(_ok(_ps(base)))
    lines = _ok(_ps(base + ["-PushPi"]))
    rb = "/root/core303/%s/" % _b12()
    runs = [l for l in lines if l.startswith(("RUN ", "FETCH "))]
    assert [l.split(": ", 1)[0] for l in runs] == ["RUN P2", "FETCH P2"]
    assert runs[1] == "FETCH P2: pscp -batch %s:%sout/P2/* sd\\LEG303P2KS1PI\\" % (HOST, rb)
    remote = [l for l in lines if l.startswith("REMOTE ")]
    assert len(remote) == 4 and "spi303" in remote[3] and "prep303" in remote[3]
    assert not any(" map" in l for l in remote)
    assert list(sd.iterdir()) == [] and list(res.iterdir()) == []


def test_pushpi_remote_mismatch_writes_nothing(tmp_path):
    sd, res = _roots(tmp_path)
    env, log = _fake_pi(tmp_path, "-P2Only", bad=True)
    r = _ps(["-P2Only", *ONLYARGS, "-PushPi", "-SdRoot", sd, "-ResultsRoot", res], env)
    assert r.returncode != 0
    assert "remote hash" in r.stdout + r.stderr
    assert list(sd.iterdir()) == []
    kinds = [json.loads(l)["argv"][0] for l in log.read_text().splitlines()]
    assert kinds == ["plink", "pscp", "plink"]          # no gcc after a failed check


@pytest.fixture(scope="module")
def phase2(tmp_path_factory):
    """One real -Phase2 -PushPi run (real PI303 build and frames, fake plink/pscp)."""
    dirty = subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--",
                            "tests/core303/pi", "tests/core303/bench"],
                           capture_output=True, text=True).stdout
    if dirty.strip():
        pytest.skip("tests/core303/pi or bench has uncommitted changes: the PI303 build refuses")
    tmp = tmp_path_factory.mktemp("phase2")
    sd, res = _roots(tmp)
    env, log = _fake_pi(tmp, "-Phase2")
    args = ["-Phase2", *P2ARGS, "-SdRoot", sd, "-ResultsRoot", res, "-PushPi"]
    whatif = _ok(_ps(args + ["-WhatIf"], env))
    assert not log.exists()
    lines = _ok(_ps(args, env))
    return {"tmp": tmp, "sd": sd, "res": res, "log": log, "lines": lines, "whatif": whatif,
            "args": args, "env": env}


def test_gates_in_every_leg(phase2):
    import ingest
    sd = phase2["sd"]
    b12, fh = _b12(), bundle.dir_hash(FRAMES)
    assert sorted(p.name for p in sd.iterdir()) == sorted(PI_LEGS + ["LEG303P.TXT"])
    for leg in PI_LEGS:
        g = _gates(sd / leg / "GATES.TXT")
        assert g["bundle"] == b12 and g["frames"] == fh, leg
        assert g["board"] == "ks3" and g["sitting"] == "2026-11-20"
        assert ingest._gates(sd / leg)["bundle"] == b12
    for leg in ("LEG303P0", "LEG303P2"):
        assert [p.name for p in (sd / leg).iterdir()] == ["GATES.TXT"]
        assert "stamp" not in _gates(sd / leg / "GATES.TXT")
    for leg, nex in (("LEG303P3", "PI303"), ("LEG303P4", "PI303V")):
        d = sd / leg
        assert sorted(p.name for p in d.iterdir()) == sorted(["GATES.TXT", nex + ".NEX",
                                                              nex + ".MAP"])
        g = _gates(d / "GATES.TXT")
        assert re.fullmatch(r"[0-9a-f]{7,12}", g["stamp"]), g["stamp"]
        assert g["nex_sha256"] == _sha(d / (nex + ".NEX"))
        assert g["map_sha256"] == _sha(d / (nex + ".MAP"))
        assert (d / (nex + ".NEX")).read_bytes() == (REPO / "build/core303" / (nex + ".NEX")).read_bytes()
        for line in (d / (nex + ".MAP")).read_text(encoding="ascii").splitlines():
            k, v = line.split("=")
            assert g["map_" + k] == v
    assert _gates(sd / "LEG303P3" / "GATES.TXT")["stamp"] == \
        _gates(sd / "LEG303P4" / "GATES.TXT")["stamp"]


def test_phase2_staged_record_verifies(phase2):
    rec = phase2["res"] / "2026-11-20-ks3-staged"
    assert [p.name for p in phase2["res"].iterdir()] == [rec.name]
    assert verify_staged(rec) == []
    names = sorted(p.relative_to(rec).as_posix() for p in rec.rglob("*") if p.is_file())
    assert names == sorted(["MANIFEST.txt", "BUNDLE.lst", "FRAMES.lst"] +
                           ["%s/GATES.TXT" % l for l in PI_LEGS] +
                           ["LEG303P3/PI303.NEX", "LEG303P3/PI303.MAP",
                            "LEG303P4/PI303V.NEX", "LEG303P4/PI303V.MAP"])
    for n in names:
        if n.startswith("LEG"):
            assert (rec / n).read_bytes() == (phase2["sd"] / n).read_bytes(), n
    data = [l for l in (rec / "MANIFEST.txt").read_text(encoding="ascii").splitlines()
            if l.strip() and not l.startswith("#")]
    assert len(data) == len(names) - 1
    for l in data:
        sha, rel, loc = l.split("  ")
        assert loc == "here" and _sha(rec / rel) == sha
    assert hashlib.sha256((rec / "BUNDLE.lst").read_bytes()).hexdigest()[:12] == _b12()
    assert hashlib.sha256((rec / "FRAMES.lst").read_bytes()).hexdigest()[:12] == \
        bundle.dir_hash(FRAMES)
    cp = phase2["tmp"] / "tampered"
    shutil.copytree(rec, cp)
    m = cp / "LEG303P3" / "PI303.MAP"
    m.write_bytes(m.read_bytes() + b"x=1\n")
    assert verify_staged(cp) == ["MISMATCH LEG303P3/PI303.MAP"]


def test_phase2_refuses_existing_record(phase2):
    sd = phase2["sd"]
    before = {p: p.read_bytes() for p in sd.rglob("*") if p.is_file()}
    r = _ps(phase2["args"], phase2["env"])
    assert r.returncode != 0
    assert "exists" in r.stdout + r.stderr
    assert "STEP 1" not in r.stdout
    assert {p: p.read_bytes() for p in sd.rglob("*") if p.is_file()} == before


def test_pushpi_commands(phase2):
    b12 = _b12()
    rb = "/root/core303/%s/" % b12
    runs = [l for l in phase2["lines"] if l.startswith(("RUN ", "FETCH "))]
    assert runs == [l for l in phase2["whatif"] if l.startswith(("RUN ", "FETCH "))]
    assert [l.split(": ", 1)[0] for l in runs] == \
        ["RUN P0", "FETCH P0", "RUN P2", "FETCH P2", "RUN P3", "FETCH P3", "RUN P4", "FETCH P4"]
    tool = {"P0": "python3 {r}pi303_probe.py --out {r}out/P0 --bundle {b}",
            "P2": "python3 {r}pi303_prep.py --frames {r}frames --out {r}out/P2 --bundle {b}",
            "P3": "python3 {r}pi303_spi.py --map {r}map/PI303.MAP --tool {r}spi303"
                  " --out {r}out/P3 --bundle {b}",
            "P4": "python3 {r}pi303_video.py --map {r}map/PI303V.MAP --spi-log {r}out/P3/SPI.LOG"
                  " --frames {r}frames --tool {r}spi303 --out {r}out/P4 --bundle {b}"}
    logs = {"P0": ["PROBE.LOG"], "P2": ["PREP.LOG"], "P3": ["SPI.LOG", "PI_PI303.LOG"],
            "P4": ["VIDEO.LOG", "PI_PI303V.LOG"]}
    for leg, t in tool.items():
        t = t.format(r=rb, b=b12)
        rm = "rm -f " + " ".join("%sout/%s/%s" % (rb, leg, n) for n in logs[leg])
        assert 'RUN %s: plink -batch %s "cd %s && %s && %s"' % (
            leg, HOST, rb.rstrip("/"), rm, t) in runs
        assert "FETCH %s: pscp -batch %s:%sout/%s/* sd\\LEG303%s\\" % (leg, HOST, rb, leg, leg) \
            in runs
        src = (PI / t.split()[1][len(rb):]).read_text(encoding="ascii")
        for flag in re.findall(r" (--[a-z-]+)", t):
            assert 'add_argument("%s"' % flag in src, (leg, flag)
    for l in runs:
        for p in _remote_paths(l):
            assert _under(p, rb), l
        if l.startswith("RUN "):
            rm = l.split(" && ")[1]
            assert rm.startswith("rm -f /") and "*" not in rm, l
        assert "-r" not in l.split() and "-rf" not in l


@pytest.mark.parametrize("mode", [["-P2Only", *ONLYARGS], ["-Phase2", *P2ARGS]])
@pytest.mark.parametrize("dirty", ["tests/core303/pi/new.py", "tests/core303/stage.ps1"])
def test_dirty_tree_refuses(tmp_path, mode, dirty):
    sd, res = _roots(tmp_path)
    env = {"CORE303_TREE_ROOT": str(_tree(tmp_path, dirty))}
    r = _ps(mode + ["-SdRoot", sd, "-ResultsRoot", res], env)
    assert r.returncode != 0
    assert "uncommitted changes under" in r.stderr
    assert list(sd.iterdir()) == [] and list(res.iterdir()) == []
    assert "bundle:" not in r.stdout


def test_phase2_refuses_stale_partial(tmp_path):
    sd, res = _roots(tmp_path)
    (res / ".2026-11-20-ks3-staged.partial").mkdir()
    for extra in (["-WhatIf"], []):
        r = _ps(["-Phase2", *P2ARGS, "-SdRoot", sd, "-ResultsRoot", res] + extra)
        assert r.returncode != 0
        assert "stale partial record" in r.stderr
    assert [p.name for p in res.iterdir()] == [".2026-11-20-ks3-staged.partial"]
    assert list(sd.iterdir()) == []


@pytest.mark.parametrize("args", [["-Ks3Rerun"], ["-Phase2", *P2ARGS], ["-P2Only", *ONLYARGS],
                                  []])
def test_overrides_warn_first(tmp_path, args):
    sd, res = _roots(tmp_path)
    env = {"CORE303_TREE_ROOT": "X:\\tree", "CORE303_PLINK": "X:\\plink.cmd",
           "CORE303_PSCP": "X:\\pscp.cmd"}
    roots = ["-SdRoot", sd] + (["-ResultsRoot", res] if args[:1] in (["-Phase2"], ["-P2Only"]) else [])
    lines = _ok(_ps(args + ["-WhatIf"] + roots, env))
    assert lines[:3] == ["WARNING: CORE303_TREE_ROOT set - clean-tree git check -> X:\\tree",
                         "WARNING: CORE303_PLINK set - plink executable -> X:\\plink.cmd",
                         "WARNING: CORE303_PSCP set - pscp executable -> X:\\pscp.cmd"], lines[:4]
    plain = _ok(_ps(args + ["-WhatIf"] + roots))
    assert not any(l.startswith("WARNING:") for l in plain)


def test_python_calls_skip_bytecode():
    src = STAGE.read_text(encoding="ascii")
    calls = re.findall(r"& python\b[^\n]*", src)
    assert calls and all(c.startswith("& python -B ") for c in calls), calls


def test_fake_pi_records_argv(phase2):
    rb = "/root/core303/%s/" % _b12()
    calls = [json.loads(l) for l in phase2["log"].read_text().splitlines()]
    assert [c["argv"][0] for c in calls] == ["plink", "pscp", "plink", "plink"]
    for c in calls:
        a = c["argv"][1:]
        assert a[0] == "-batch"
        text = " ".join(a)
        assert not re.search(r"\brm\b", text)
        for p in _remote_paths(text):
            assert _under(p, rb) or p == "/usr/include/jpeglib.h", (p, text)
    mk, push, check, gcc = (c["argv"] for c in calls)
    assert mk[2] == HOST and mk[3] == "mkdir -p " + " ".join(
        "%sout/%s" % (rb, l) for l in ("P0", "P2", "P3", "P4"))
    assert push[-1] == "%s:%s" % (HOST, rb) and "-r" in push
    names = [n.strip() for n in (PI / "BUNDLE.txt").read_text().splitlines() if n.strip()]
    tops = [n for n in names if "/" not in n] + ["BUNDLE.txt", "c", "frames", "map"]
    assert sorted(push[push.index("-r") + 1:-1]) == sorted(tops)
    assert Path(calls[1]["cwd"]) == PUSH_TREE["-Phase2"]
    assert check[2] == HOST and "map/PI303.MAP" in check[3] and "map/PI303V.MAP" in check[3]
    assert "gcc" in gcc[3] and "-o spi303" in gcc[3] and "-o prep303" in gcc[3]
    remote = [l for l in phase2["lines"] if l.startswith("REMOTE ")]
    assert len(remote) == 4
    assert remote == [l for l in phase2["whatif"] if l.startswith("REMOTE ")]
