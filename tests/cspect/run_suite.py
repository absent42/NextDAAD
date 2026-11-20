"""Suite runner for the emulator test scripts, one log per entry per emulator tag.

    python tests/cspect/run_suite.py --tag zes|cspect [--only NAME,...] [--list] [--label L]

An entry carries per-tag build (build.ps1 arguments), stage (build-tests.ps1
switches, or a command starting with "python") and cmd (python argv). A build
runs only when it differs from the previous entry's. An entry with no cmd for
the tag reports "not ported" and runs nothing. Output: tests/out/cspect-port/<tag>/
<name>.log and summary.md. --label L writes <name>.L.log and a row "<name> (L)",
for re-runs. ZEsarUX cannot run NEXTREG A,n, so tag zes builds and stages -Harness.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from collections import namedtuple

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "tests", "out", "cspect-port")
SHELL = shutil.which("pwsh") or shutil.which("powershell") or "powershell"
PS = [SHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
ENTRY_TIMEOUT_S = 1500
STAGE_TIMEOUT_S = 1500

Entry = namedtuple("Entry", "name build stage cmd tags")

HARN = ["-Harness"]


def work(name):
    return "tests/out/cspect-port/zes/work/" + name


def zes(name, stage, cmd, build=HARN):
    """Entry with only its zes side filled in; the cspect side is a port task's."""
    return Entry(name, {"zes": build}, {"zes": stage}, {"zes": cmd}, ("zes", "cspect"))


ENTRIES = [
    zes("aysreg", ["-AysReg"],
        ["python", "tests/audio/aysreg_check.py", "--out", work("aysreg")]),
    zes("stopm_ladr", ["-AudLad"],
        ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_ladr"), "--restart", "LADR"]),
    zes("stopm_lad1", ["-AudLad"],
        ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_lad1"), "--restart", "LAD1"]),
    zes("stopm_ladder", ["-AudLad"],
        ["python", "tests/audio/stopm_dump.py", "--out", work("stopm_ladder"), "--ladder"]),
    zes("refuse", None, ["python", "tests/corefloor/refuse_check.py"]),
    zes("cursor", ["-Cursor"], ["python", "tests/cursor_dump.py"]),
    zes("cycle", ["-Cycle"], ["python", "tests/cycle_dump.py"]),
    zes("intro", ["-Intro"],
        ["python", "tests/intro/zes_intro.py", "sd/INTRO", "--launch", "SHOW.NEX",
         "--seconds", "90", "--interval", "0.1", "--space-at-frame", "900", "--expect-handoff"]),
    zes("l2pos", ["-L2Pos"], ["python", "tests/l2pos_check.py"]),
    zes("l2pos_wide", ["-L2PosWide"], ["python", "tests/l2pos_check.py", "--mode", "1"]),
    zes("gfxzx0", ["-L2Pos", "-GfxZx0"], ["python", "tests/l2pos_check.py"]),
    zes("machine_gate", ["-BigDdb"], ["python", "tests/machine_gate.py"]),
    zes("parsertest_condacts", None,
        ["python", "tests/parser/parsertest.py", "tests/condacts.dsf",
         "tests/parser/scripts/condacts/smoke.json", "--out", work("parsertest_condacts")]),
    zes("parsertest_condacts_full", None,
        ["python", "tests/parser/parsertest.py", "tests/condacts.dsf",
         "tests/parser/scripts/condacts/full.json", "--out", work("parsertest_condacts_full")]),
    zes("v3probe", None,
        ["python", "tests/parser/scripts/v3probe/run.py", "--out", work("v3probe")]),
    zes("poolc", ["python", "tests/poolc/stage_poolc.py", "build/nextdaad.nex", "build/nextdaad.nex",
                  "build/nextdaad.map", "build/nextdaad.map"],
        ["python", "tests/poolc/poolc_check.py", "sd/LEGPC", "tests/out/poolc/LEGPC.map",
         "10060", "switch"]),
    zes("poolc_restore", ["python", "tests/poolc/stage_poolc.py", "build/nextdaad.nex",
                          "build/nextdaad.nex", "build/nextdaad.map", "build/nextdaad.map"],
        ["python", "tests/poolc/poolc_check.py", "sd/LEGPC", "tests/out/poolc/LEGPC.map",
         "10061", "restore"]),
    zes("poolc_focus5", ["python", "tests/poolc/stage_poolc.py", "build/nextdaad.nex",
                         "build/nextdaad.nex", "build/nextdaad.map", "build/nextdaad.map"],
        ["python", "tests/poolc/poolc_check.py", "sd/LEGPC", "tests/out/poolc/LEGPC.map",
         "10062", "focus5"]),
    zes("poolcc", ["python", "tests/poolc/stage_poolc.py", "build/nextdaad.nex", "build/nextdaad.nex",
                   "build/nextdaad.map", "build/nextdaad.map"],
        ["python", "tests/poolc/poolc_check.py", "sd/LEGPCC", "tests/out/poolc/LEGPCC.map",
         "10063", "control"]),
    zes("spraud", ["-SprAud"], ["python", "tests/spraud_dump.py"]),
    zes("sprites", ["-Sprites"], ["python", "tests/sprites_dump.py"]),
    zes("txt40", ["-Txt40"], ["python", "tests/txt40_dump.py"]),
    zes("typeahead", ["-KbLog"], ["python", "tests/typeahead_run.py"]),
    zes("xbn_hookshape", ["-Xbn"], ["python", "tests/xbn/hookshape.py", "sd/XBN"]),
    zes("xbn_namecheck", ["-Xbn", "-XbnAll"], ["python", "tests/xbn/namecheck.py", "sd/XBN"]),
    zes("xbn_tickcheck", ["-Xbn", "-XbnTicker"],
        ["python", "tests/xbn/tickcheck.py", "sd/XBN", "XTCK", "XT40"]),
    zes("xbn_tickcheck_all", ["-Xbn", "-XbnAll"],
        ["python", "tests/xbn/tickcheck.py", "sd/XBN", "XTCK", "XT40"]),
    zes("xbn_transcheck", ["-Xbn", "-XbnTrans"],
        ["python", "tests/xbn/transcheck.py", "sd/XBN", "XTRS", "XTR1", "XTRE"]),
]

ROW = re.compile(r"^\| (.+?) \| (\S.*?) \| (\d+) \| (\d+) \| ([\d.]+) \| ([\d.]+) \|$")
PF = re.compile(r"^\s*(PASS|FAIL)\b")


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


def stage_argv(stage, tag):
    if stage and stage[0] == "python":
        return stage
    return PS + [os.path.join(ROOT, "tests", "build-tests.ps1")] + (HARN if tag == "zes" else []) + stage


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
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# %s suite summary\n\n" % tag)
        f.write("| entry | rc | PASS | FAIL | prep s | wall s |\n|---|---|---|---|---|---|\n")
        for k in order:
            if k in rows:
                r = rows[k]
                f.write("| %s | %s | %d | %d | %.1f | %.1f |\n" % (k, r[0], r[1], r[2], r[3], r[4]))
        f.write("\nTotal wall time: %.1f s (prep %.1f s + scripts %.1f s) over %d rows\n"
                % (prep + wall, prep, wall, len(rows)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", choices=("zes", "cspect"), required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--label", default="")
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
            argv = PS + [os.path.join(ROOT, "build.ps1")] + build
            rc, so, se, dt = run(argv, STAGE_TIMEOUT_S)
            prep += dt
            log += ["--- build %s rc=%d %.1fs" % (" ".join(build), rc, dt), so, se]
            built = build
            if rc != 0:
                built = "failed"
        stage = e.stage.get(a.tag)
        rc_stage = 0
        if stage and built != "failed":
            rc_stage, so, se, dt = run(stage_argv(stage, a.tag), STAGE_TIMEOUT_S)
            prep += dt
            log += ["--- stage %s rc=%d %.1fs" % (" ".join(stage), rc_stage, dt), so, se]
        if built == "failed" or rc_stage != 0:
            rc, so, se, dt = 125, "", "build or stage failed, script not run\n", 0.0
        else:
            rc, so, se, dt = run(cmd, ENTRY_TIMEOUT_S)
        npass = sum(1 for l in so.splitlines() if PF.match(l) and l.strip().startswith("PASS"))
        nfail = sum(1 for l in so.splitlines() if PF.match(l) and l.strip().startswith("FAIL"))
        with open(os.path.join(tagdir, e.name + ("." + a.label if a.label else "") + ".log"),
                  "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(log) + "\n--- run\nrc: %d\nwall: %.1f s\n--- stdout\n%s\n--- stderr\n%s\n"
                    % (rc, dt, so, se))
        rows[key] = (str(rc), npass, nfail, prep, dt)
        print("%-26s rc=%-3d PASS=%-3d FAIL=%-3d %.1fs" % (key, rc, npass, nfail, dt), flush=True)
        write_summary(summary, a.tag, rows, order)
    write_summary(summary, a.tag, rows, order)
    return 0


if __name__ == "__main__":
    sys.exit(main())
