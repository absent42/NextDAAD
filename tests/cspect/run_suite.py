"""Suite runner for the emulator test scripts, one log per entry per emulator tag.

    python tests/cspect/run_suite.py --tag cspect [--only NAME,...] [--list] [--label L] [--full]
                                     [--plan | --stage-only]

An entry carries per-tag build (build.ps1 arguments), stage (build-tests.ps1
switches, or a command starting with "python") and cmd (python argv). A build
runs only when it differs from the previous entry's. An entry with no cmd for
the tag reports "not ported" and runs nothing. Output: tests/out/cspect-port/<tag>/
<name>.log and summary.md. --label L writes <name>.L.log and a row "<name> (L)",
for re-runs.

Change-aware (tests/stamps.py): build.ps1 and build-tests.ps1 skip unchanged work
themselves; a python stager that does not run build-tests.ps1 is skipped while its
script, imports, arguments and card folders are unchanged. An entry whose definition,
script and imported repo modules (tests/cspect/ through its imports), CSpect version
and the BYTES it loads (build NEX and map, card folders) match its stamp replays its
cached rc and PASS/FAIL counts and prints "cached: unchanged since <time>"; a rebuild
or restage that writes the same bytes runs nothing. Timeouts (124), build or stage
failures (125), tracebacks and interrupted runs are never cached. --full ignores every
stamp. --plan prints run or cached per entry with the reason and builds, stages and
launches nothing. --stage-only builds and stages without launching.
"""
import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import namedtuple

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import stamps  # noqa: E402
OUT = os.path.join(ROOT, "tests", "out", "cspect-port")
SHELL = shutil.which("pwsh") or shutil.which("powershell") or "powershell"
PS = [SHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
ENTRY_TIMEOUT_S = 1500
STAGE_TIMEOUT_S = 1500

Entry = namedtuple("Entry", "name build stage cmd tags")


def work(name, tag="cspect"):
    return "tests/out/cspect-port/%s/work/%s" % (tag, name)


def cspect(name, stage, cmd, build=()):
    """An entry (build: build.ps1 arguments, DEBUG when empty)."""
    return Entry(name, {"cspect": list(build)}, {"cspect": stage}, {"cspect": cmd}, ("cspect",))


def parser(name, argv):
    """A parser harness entry (no staging; DEBUG); --out is the tag's work folder."""
    return cspect(name, None, argv + ["--out", work(name)])


INTRO_ARGV = ["python", "tests/intro/zes_intro.py", "sd/INTRO", "--launch", "SHOW.NEX",
              "--seconds", "90", "--interval", "0.1", "--space-at-frame", "900", "--expect-handoff"]
POOLC_STAGE = ["python", "tests/poolc/stage_poolc.py", "build/nextdaad.nex", "build/nextdaad.nex",
               "build/nextdaad.map", "build/nextdaad.map"]


def poolc(name, leg, case):
    """A pool C entry (DEBUG); port 0 is the first free."""
    argv = ["python", "tests/poolc/poolc_check.py", "sd/" + leg, "tests/out/poolc/%s.map" % leg]
    return cspect(name, POOLC_STAGE, argv + ["0", case])


ENTRIES = [
    cspect("aysreg", ["-AysReg"], ["python", "tests/audio/aysreg_check.py", "--out", work("aysreg")]),
    cspect("stopm_ladr", ["-AudLad"],
           ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_ladr"), "--restart", "LADR"]),
    cspect("stopm_lad1", ["-AudLad"],
           ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_lad1"), "--restart", "LAD1"]),
    cspect("stopm_ladder", ["-AudLad"],
           ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_ladder"), "--ladder"]),
    cspect("refuse", None, ["python", "tests/corefloor/refuse_check.py"], build=["-Release"]),
    cspect("cursor", ["-Cursor"], ["python", "tests/cursor_dump.py"]),
    cspect("cycle", ["-Cycle"], ["python", "tests/cycle_dump.py"]),
    cspect("intro", ["-Intro"], INTRO_ARGV),
    cspect("l2pos", ["-L2Pos"], ["python", "tests/l2pos_check.py"]),
    cspect("l2pos_wide", ["-L2PosWide"], ["python", "tests/l2pos_check.py", "--mode", "1"]),
    cspect("gfxzx0", ["-L2Pos", "-GfxZx0"], ["python", "tests/l2pos_check.py"]),
    cspect("machine_gate", ["-BigDdb"], ["python", "tests/machine_gate.py"]),
    parser("parsertest_condacts", ["python", "tests/parser/parsertest.py", "tests/condacts.dsf",
                                   "tests/parser/scripts/condacts/smoke.json"]),
    parser("parsertest_condacts_full", ["python", "tests/parser/parsertest.py",
                                        "tests/condacts.dsf",
                                        "tests/parser/scripts/condacts/full.json"]),
    parser("v3probe", ["python", "tests/parser/scripts/v3probe/run.py"]),
    poolc("poolc", "LEGPC", "switch"),
    poolc("poolc_restore", "LEGPC", "restore"),
    poolc("poolc_focus5", "LEGPC", "focus5"),
    poolc("poolcc", "LEGPCC", "control"),
    cspect("spraud", ["-SprAud"], ["python", "tests/spraud_dump.py"]),
    cspect("sprites", ["-Sprites"], ["python", "tests/sprites_dump.py"]),
    cspect("txt40", ["-Txt40"], ["python", "tests/txt40_dump.py"]),
    cspect("typeahead", ["-KbLog"], ["python", "tests/typeahead_run.py"]),
    cspect("xbn_hookshape", ["-Xbn"], ["python", "tests/xbn/hookshape.py", "sd/XBN"]),
    cspect("xbn_namecheck", ["-Xbn", "-XbnAll"], ["python", "tests/xbn/namecheck.py", "sd/XBN"]),
    cspect("xbn_tickcheck", ["-Xbn", "-XbnTicker"],
           ["python", "tests/xbn/tickcheck.py", "sd/XBN", "XTCK", "XT40"]),
    cspect("xbn_tickcheck_all", ["-Xbn", "-XbnAll"],
           ["python", "tests/xbn/tickcheck.py", "sd/XBN", "XTCK", "XT40"]),
    cspect("xbn_tickcheck_getdate", ["-Xbn", "-XbnTicker"],
           ["python", "tests/xbn/tickcheck.py", "sd/XBN", "XTCO", "--row", "27",
            "--attr-uniform", "27"]),
    cspect("xbn_transcheck", ["-Xbn", "-XbnTrans"],
           ["python", "tests/xbn/transcheck.py", "sd/XBN", "XTRS", "XTR1", "XTRE"]),
    cspect("text2_reader", ["python", "tests/text2/stage_legs.py", "reader"],
           ["python", "tests/text2/drive_cspect.py", "objverif_walk", "nest4_walk", "xmb_walk",
            "xmb_mismatch_refused", "xmb_fp_refused", "xmb_part_fallback", "timing"]),
    cspect("text2_loader", ["python", "tests/text2/stage_legs.py", "loader"],
           ["python", "tests/text2/loader/run_loader_legs.py"]),
]

ROW = re.compile(r"^\| (.+?) \| (\S.*?) \| (\d+) \| (\d+) \| ([\d.]+) \| ([\d.]+) \|$")
PF = re.compile(r"^\s*(PASS|FAIL)\b")
# build-tests.ps1 ends with "staged leg: sd\NAME"; stage_poolc.py prints "sd\NAME" per card.
CARD = re.compile(r"^(?:staged leg: )?(sd[\\/][A-Za-z0-9_]+)\s*$")
# What an entry loads from build\, keyed by content: the .sld and SYM move with line numbers
# and the src commit, the NEX and map do not.
BUILD_LOADED = ["build/nextdaad.nex", "build/nextdaad.map", "build/intro.nex", "build/intro.map"]
_TRACKED = []


def tracked():
    """Repo files git knows (tracked plus untracked not ignored), posix relative."""
    if not _TRACKED:
        _TRACKED.append(set(stamps.git_files(ROOT, ["."])))
    return _TRACKED[0]


def _rel(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")


def module_inputs(script):
    """script plus the repo modules it imports (transitively) and the repo files its string
    literals name; a name found in several test folders counts every match."""
    files = tracked()
    dirs = sorted({os.path.dirname(f) for f in files if f.startswith("tests/") and f.endswith(".py")} | {"tests"})
    seen, todo = set(), [_rel(os.path.join(ROOT, script))]
    while todo:
        f = todo.pop()
        if f in seen or f not in files:
            continue
        seen.add(f)
        try:
            tree = ast.parse(open(os.path.join(ROOT, f), encoding="utf-8", errors="replace").read())
        except (OSError, SyntaxError):
            continue
        here = os.path.dirname(f)
        cands = []
        for n in ast.walk(tree):
            if isinstance(n, ast.Import):
                for a in n.names:
                    parts = a.name.split(".")
                    cands += [d + "/" + "/".join(parts[:i]) for d in dirs for i in range(1, len(parts) + 1)]
            elif isinstance(n, ast.ImportFrom):
                parts = n.module.split(".") if n.module else []
                up = here
                for _ in range(max(n.level - 1, 0)):
                    up = os.path.dirname(up)
                bases = [up] if n.level else dirs
                for d in bases:
                    stem = "/".join([d] + parts)
                    cands.append(stem)
                    cands += [stem + "/" + a.name for a in n.names]
            elif isinstance(n, ast.Constant) and isinstance(n.value, str) and 0 < len(n.value) < 200:
                s = n.value.replace("\\", "/")
                for base in ("", here + "/", "tests/"):
                    p = os.path.normpath(base + s).replace("\\", "/")
                    if p in files and not p.endswith(".py"):
                        seen.add(p)
        for c in cands:
            c = c.lstrip("/")
            for p in (c + ".py", c + "/__init__.py"):
                if p in files:
                    todo.append(p)
    return sorted(seen)


def cspect_identity():
    """(CSpect.exe path, version) of the source install the launcher reads."""
    try:
        from cspect import launcher
        exe = os.path.join(os.environ.get("CSPECT_DIR") or str(launcher.DEFAULT_SOURCE), "CSpect.exe")
        return exe, ".".join(map(str, launcher.exe_version(exe)))
    except Exception as e:  # noqa: BLE001 - an unreadable version is itself an identity
        return "", "unreadable: %s" % e


def delegates(stage):
    """True for a python stager that runs build-tests.ps1 (change-aware itself)."""
    try:
        return "build-tests.ps1" in open(os.path.join(ROOT, stage[1]), encoding="utf-8").read()
    except OSError:
        return True


def argv_inputs(argv):
    """(sources, outputs, cards) named in argv: existing files, those under build/ or tests/out
    being another step's outputs, and folders under sd/."""
    files, outs, cards = [], [], []
    for a in argv:
        p = os.path.join(ROOT, a)
        r = _rel(p)
        if os.path.isfile(p):
            (outs if r.startswith(("build/", "tests/out/")) else files).append(r)
        elif os.path.isdir(p) and r.startswith("sd/"):
            cards.append(r)
    return files, outs, cards


def stager_spec(stage, cards):
    files, outs, trees = argv_inputs(stage[2:])
    return {"files": sorted(set(module_inputs(stage[1]) + files)), "hash_files": outs, "hash_trees": trees,
            "tools": {"ndrc": "authoring-kit/lib/ndrc.exe"}, "ident": {"stage": json.dumps(stage)},
            "output_trees": sorted(set(cards)), "hash_outputs": True}


def entry_spec(e, tag, cards, build):
    """Sources by mtime (script, imported modules incl. tests/cspect, argv sources); what it
    loads by content (build NEX and map, card folders, argv outputs); CSpect and ndrc."""
    cmd = e.cmd[tag]
    files, outs, argv_cards = argv_inputs(cmd[1:])
    if cmd[0] == "python":
        files += module_inputs(cmd[1])
    exe, version = cspect_identity()
    tools = {"ndrc": "authoring-kit/lib/ndrc.exe"}
    if exe:
        tools["cspect"] = exe
    return {"files": sorted(set(files)), "hash_files": sorted(set(outs + BUILD_LOADED)),
            "hash_trees": sorted(set(argv_cards + cards)), "tools": tools,
            "ident": {"build": json.dumps(build), "stage": json.dumps(e.stage.get(tag)),
                      "cmd": json.dumps(cmd), "cspect": version}}


def cacheable(rc, so, se):
    return rc not in (124, 125) and rc >= 0 and "Traceback (most recent call last)" not in so + se


def run(argv, timeout):
    """Run argv from the repo root; return (rc, stdout, stderr, seconds)."""
    t = time.time()
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return p.returncode, p.stdout, p.stderr, time.time() - t
    except subprocess.TimeoutExpired as e:
        so = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        se = e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        return 124, so, se + "\nTIMEOUT after %ds\n" % timeout, time.time() - t


def stage_argv(stage, tag, full=False, plan=False):
    if stage and stage[0] == "python":
        return stage + (["--full"] if full else []) + (["--plan"] if plan else [])
    return (PS + [os.path.join(ROOT, "tests", "build-tests.ps1")] + stage + (["-Full"] if full else [])
            + (["-Plan"] if plan else []))


def cards_in(text):
    return [m.group(1).replace("\\", "/") for m in map(CARD.match, text.splitlines()) if m]


def stager_name(stage):
    return "stage-%s-%s" % (os.path.basename(stage[1]), hashlib.sha1(json.dumps(stage).encode()).hexdigest()[:10])


PLAN_LINE = re.compile(r"^PLAN\t(.+?)\t(FRESH|RESTORE|STALE|PENDING)\t(.*)$")
PLAN_LEG = re.compile(r"^PLAN-LEG\t(sd\\[A-Za-z0-9_]+)\t(.+?)\t(FRESH|RESTORE|STALE|PENDING)\t(.*)$")


def plan_build(build, cache):
    """(stamp name, state, reason) of a build variant, from build.ps1 -Plan."""
    key = tuple(build)
    if key not in cache:
        rc, so, se, _ = run(PS + [os.path.join(ROOT, "build.ps1")] + build + ["-Plan"], STAGE_TIMEOUT_S)
        m = [x for x in map(PLAN_LINE.match, so.splitlines()) if x]
        cache[key] = (m[0].group(1), m[0].group(2), m[0].group(3)) if rc == 0 and m else \
            ("build", "STALE", "build.ps1 -Plan failed: %s" % (se or so).strip()[-200:])
    return cache[key]


def plan_stage(stage, tag, cache):
    """[(card, stamp name, state, reason)] for a stage, staging nothing."""
    key = json.dumps(stage)
    if key not in cache:
        if stage[0] == "python" and not delegates(stage):
            name = stager_name(stage)
            cards = (((stamps.read_stamp(name) or {}).get("extra")) or {}).get("cards") or []
            state, info, _ = stamps.plan_check(name, stager_spec(stage, cards))
            res = [(c, name, state, info) for c in cards] or [("", name, "STALE", "no stamp")]
        else:
            rc, so, se, _ = run(stage_argv(stage, tag, plan=True), STAGE_TIMEOUT_S)
            res = [(m.group(1).replace("\\", "/"), m.group(2), m.group(3), m.group(4))
                   for m in map(PLAN_LEG.match, so.splitlines()) if m]
            if rc != 0 or not res:
                res = [("", "stage", "STALE", "stage plan failed: %s" % (se or so).strip()[-200:])]
        cache[key] = res
    return cache[key]


def plan_entry(e, tag, bres, legs):
    """("run" | "cached", reason): the entry's stamp against the build and card bytes its
    upstream stamps hold (their copies are what a restore would put back)."""
    bname, bstate, binfo = bres
    if bstate in ("STALE", "PENDING"):
        return "run", "%s: %s" % (bname, binfo)
    for card, sname, state, info in legs:
        if state in ("STALE", "PENDING"):
            return "run", "%s: %s" % (sname, info)
    build = e.build.get(tag) or []
    espec = entry_spec(e, tag, sorted({c for c, _, _, _ in legs if c}), build)
    st = stamps.read_stamp("suite-%s-%s" % (tag, e.name))
    if not st or st.get("status") != "pass" or not st.get("extra"):
        return "run", "no cached result"
    fp = stamps.fingerprint(espec)
    bout = (stamps.read_stamp(bname) or {}).get("outputs") or {}
    for k in BUILD_LOADED:
        if k in bout:
            fp["files"][k] = bout[k]
    for card, sname, _, _ in legs:
        if not card:
            continue
        pre = card + "/"
        lout = (stamps.read_stamp(sname) or {}).get("outputs") or {}
        for k in [k for k in fp["files"] if k.startswith(pre)]:
            del fp["files"][k]
        fp["files"].update({k: v for k, v in lout.items() if k.startswith(pre)})
    if fp == st.get("inputs"):
        return "cached", "unchanged since %s" % st.get("time")
    return "run", stamps.describe(st.get("inputs") or {}, fp)


def plan(picked, tag):
    builds, stages, counts = {}, {}, {"run": 0, "cached": 0}
    for e in picked:
        if not e.cmd.get(tag):
            print("%-26s %-6s %s" % (e.name, "-", "not ported"))
            continue
        bres = plan_build(e.build.get(tag) or [], builds)
        stage = e.stage.get(tag)
        legs = plan_stage(stage, tag, stages) if stage else []
        verdict, why = plan_entry(e, tag, bres, legs)
        counts[verdict] += 1
        print("%-26s %-6s %s" % (e.name, verdict, why), flush=True)
    print("plan: %d run, %d cached" % (counts["run"], counts["cached"]))
    return 0


def run_stage(stage, tag, full, log):
    """Run (or skip, unchanged) one stage; return (rc, seconds, card folders)."""
    if stage[0] == "python" and not delegates(stage):
        name = stager_name(stage)
        prev = stamps.read_stamp(name)
        prev_cards = ((prev or {}).get("extra") or {}).get("cards") or []
        spec = stager_spec(stage, prev_cards)
        t = time.time()
        fresh, info, fp = stamps.check_fp(name, spec, full=full)
        if fresh:
            log += ["--- stage %s: unchanged since %s" % (" ".join(stage), info)]
            print("stage %s: unchanged since %s" % (" ".join(stage), info), flush=True)
            return 0, time.time() - t, prev_cards
        rc, so, se, dt = run(stage, STAGE_TIMEOUT_S)
        log += ["--- stage %s rc=%d %.1fs (%s)" % (" ".join(stage), rc, dt, info), so, se]
        cards = sorted(set(cards_in(so)))
        if rc == 0:
            stamps.begin(name, dict(spec, output_trees=cards), fp=fp)
            stamps.commit(name, extra={"cards": cards})
        return rc, time.time() - t, cards
    rc, so, se, dt = run(stage_argv(stage, tag, full), STAGE_TIMEOUT_S)
    log += ["--- stage %s rc=%d %.1fs" % (" ".join(stage), rc, dt), so, se]
    return rc, dt, sorted(set(cards_in(so)))


def read_rows(path):
    rows = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = ROW.match(line.rstrip("\n"))
                if m:
                    rows[m.group(1)] = (m.group(2), int(m.group(3)), int(m.group(4)),
                                        float(m.group(5)), float(m.group(6)))
    return rows


def write_summary(path, tag, rows, order):
    prep = sum(r[3] for r in rows.values())
    wall = sum(r[4] for r in rows.values())
    # every row is kept: each entry, then its labelled re-runs, then rows of unknown entries
    keys = []
    for k in order:
        if " (" not in k:
            keys += [k] + [r for r in rows if r.startswith(k + " (")]
    keys += [r for r in rows if r not in keys]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# %s suite summary\n\n" % tag)
        f.write("| entry | rc | PASS | FAIL | prep s | wall s |\n|---|---|---|---|---|---|\n")
        for k in keys:
            if k in rows:
                r = rows[k]
                f.write("| %s | %s | %d | %d | %.1f | %.1f |\n" % (k, r[0], r[1], r[2], r[3], r[4]))
        f.write("\nTotal wall time: %.1f s (prep %.1f s + scripts %.1f s) over %d rows\n"
                % (prep + wall, prep, wall, len(rows)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", choices=("cspect",), required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--label", default="")
    ap.add_argument("--full", action="store_true", help="ignore every stamp: build, stage and run all")
    ap.add_argument("--plan", action="store_true", help="say per entry run or cached, and why; build, stage and launch nothing")
    ap.add_argument("--stage-only", action="store_true", help="build and stage every entry; launch nothing")
    a = ap.parse_args()
    only = [n for n in a.only.split(",") if n]
    names = {e.name for e in ENTRIES}
    for n in only:
        if n not in names:
            sys.exit("run_suite: unknown entry %s" % n)
    picked = [e for e in ENTRIES if a.tag in e.tags and (not only or e.name in only)]

    if a.list:
        print("%-26s %-9s %-14s %-28s %s" % ("name", "tag", "build", "stage", "cmd"))
        for e in picked:
            cmd = e.cmd.get(a.tag)
            st = e.stage.get(a.tag)
            print("%-26s %-9s %-14s %-28s %s" % (
                e.name, a.tag, " ".join(e.build.get(a.tag) or []) or "-",
                " ".join(st) if st else "-", " ".join(cmd) if cmd else "(not ported)"))
        return 0
    if a.plan:
        return plan(picked, a.tag)

    tagdir = os.path.join(OUT, a.tag)
    os.makedirs(os.path.join(tagdir, "work"), exist_ok=True)
    summary = os.path.join(tagdir, "summary.md")
    rows = read_rows(summary)
    order = [e.name for e in ENTRIES]
    suffix = " (%s)" % a.label if a.label else ""
    for e in picked:
        if a.label:
            order.insert(order.index(e.name) + 1, e.name + suffix)
    built = "unset"
    for e in picked:
        key = e.name + suffix
        cmd = e.cmd.get(a.tag)
        if not cmd:
            print("%s: not ported" % e.name)
            rows[key] = ("not ported", 0, 0, 0.0, 0.0)
            continue
        log = ["argv: " + " ".join(cmd)]
        prep = 0.0
        build = e.build.get(a.tag) or []
        if build != built:
            argv = PS + [os.path.join(ROOT, "build.ps1")] + build + (["-Full"] if a.full else [])
            rc, so, se, dt = run(argv, STAGE_TIMEOUT_S)
            prep += dt
            log += ["--- build %s rc=%d %.1fs" % (" ".join(build), rc, dt), so, se]
            built = build
            if rc != 0:
                built = "failed"
        stage = e.stage.get(a.tag)
        rc_stage, cards = 0, []
        if stage and built != "failed":
            rc_stage, dt, cards = run_stage(stage, a.tag, a.full, log)
            prep += dt
        if a.stage_only:
            print("%-26s staged rc=%d %.1fs %s" % (e.name, 125 if built == "failed" or rc_stage else 0, prep,
                                                   " ".join(cards)), flush=True)
            continue
        logpath = os.path.join(tagdir, e.name + ("." + a.label if a.label else "") + ".log")
        cached = None
        if built == "failed" or rc_stage != 0:
            rc, so, se, dt = 125, "", "build or stage failed, script not run\n", 0.0
        else:
            ename = "suite-%s-%s" % (a.tag, e.name)
            espec = entry_spec(e, a.tag, cards, build)
            fresh, info, efp = stamps.check_fp(ename, espec, full=a.full)
            st = stamps.read_stamp(ename) if fresh else None
            if st and st.get("extra"):
                cached = (info, st["extra"])
            else:
                log += ["--- entry: run (%s)" % info]
                rc, so, se, dt = run(cmd, ENTRY_TIMEOUT_S)
        if cached:
            info, x = cached
            rc, npass, nfail, dt = x["rc"], x["pass"], x["fail"], 0.0
            if os.path.normcase(os.path.join(ROOT, x["log"])) != os.path.normcase(os.path.abspath(logpath)):
                with open(logpath, "w", encoding="utf-8", newline="\n") as f:
                    f.write("\n".join(log) + "\n--- run\ncached: unchanged since %s\nrc: %d\nlog: %s\n"
                            % (info, rc, x["log"]))
            rows[key] = (str(rc), npass, nfail, prep, dt)
            print("%-26s rc=%-3d PASS=%-3d FAIL=%-3d cached: unchanged since %s"
                  % (key, rc, npass, nfail, info), flush=True)
            write_summary(summary, a.tag, rows, order)
            continue
        npass = sum(1 for l in so.splitlines() if PF.match(l) and l.strip().startswith("PASS"))
        nfail = sum(1 for l in so.splitlines() if PF.match(l) and l.strip().startswith("FAIL"))
        with open(logpath, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(log) + "\n--- run\nrc: %d\nwall: %.1f s\n--- stdout\n%s\n--- stderr\n%s\n"
                    % (rc, dt, so, se))
        if rc != 125 and cacheable(rc, so, se):
            stamps.begin(ename, espec, fp=efp)
            stamps.commit(ename, extra={"rc": rc, "pass": npass, "fail": nfail, "log": _rel(logpath)})
        rows[key] = (str(rc), npass, nfail, prep, dt)
        print("%-26s rc=%-3d PASS=%-3d FAIL=%-3d %.1fs" % (key, rc, npass, nfail, dt), flush=True)
        write_summary(summary, a.tag, rows, order)
    write_summary(summary, a.tag, rows, order)
    return 0


if __name__ == "__main__":
    sys.exit(main())
