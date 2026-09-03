#!/usr/bin/env python3
"""SP16 Task 6 - differential runner for the DAAD V3 fixture.

    python tests/parser/scripts/v3probe/run.py [--out DIR] [--port N]

Does what tests/parser/parsertest.py does, and for the same two legs,
but with the three things a V3 database needs that the general front end
cannot give it. It is a SCRIPT-side driver: nothing under
tests/parser/*.py or jleg.js is modified, they are imported and called.

  1. Both targets are compiled via prepare.prepare_from_dsf, which
     builds both legs with ndrc.exe -v3 -auto-tokens, the same way the
     authoring kit ships a game. Nothing is ever written into tools/.

  2. SETAT is authored directly since 2026-09-02. ndrc has a real SETAT
     keyword, so the stand-in patch this script used to carry is gone.

  3. sd/0.XMB is staged for the Next leg. nleg.stage_sd builds a minimal
     card holding only the interpreter and GAME.DDB, and does not clean
     the directory, so the XMB is placed there first and survives.
     jDAAD needs no equivalent: ndrc appends XMBDATA to the .jddb,
     reproducing DRB's writer.

EXPECTED DIVERGENCE - flag 116, and flag 116 alone. jDAAD's
_HASAT (jdaad.js:3273) hardcodes the base-59 attribute bank and ignores
flag 53 bit 1, while its own _SETAT honours it. PCDAAD, msx2daad and
msx2daad's executable V3 spec (unitTests/src/tests_condacts_v3.c,
test_HASAT_altflags / test_HASNAT_altflags) all honour it and NextDAAD
follows them, so the ATT turn is expected to disagree there. Flag 115
is NOT affected: PRO 3's alternative-bank entry runs HASAT and nothing
else, so 115 is written only by the standard-bank HASNAT, where both
interpreters use base 59. See tests/v3probe.dsf's header.

Nothing this produces should ever be committed.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PARSER_DIR = HERE.parent.parent
ROOT = PARSER_DIR.parent.parent
sys.path.insert(0, str(PARSER_DIR))

import compare
import nleg
import prepare
import report
import symbols

DSF = ROOT / "tests" / "v3probe.dsf"
SCRIPT = HERE / "probe.json"


def build_v3(workdir, lang="EN"):
    """Compile tests/v3probe.dsf to both targets via prepare.prepare_from_dsf."""
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    built = prepare.prepare_from_dsf(DSF, workdir, lang)
    next_ddb = built["ddb"]

    # The Next leg reads 0.XMB off its SD card. ndrc drops 0.XMB into cwd
    # (workdir) as a side effect of the nextdaad build; nleg.stage_sd
    # creates workdir/sd and copies GAME.DDB + the .nex into it without
    # cleaning, so placing the XMB there now is enough.
    xmb = workdir / "0.XMB"
    if not xmb.exists():
        raise RuntimeError("ndrc did not produce %s" % xmb)
    sd = workdir / "sd"
    sd.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(xmb, sd / "0.XMB")

    return {"dsf": built["dsf"], "ddb": next_ddb, "header": built["header"]}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--port", type=int, default=10000)
    ap.add_argument("--nex", default=str(ROOT / "build" / "nextdaad.nex"))
    ap.add_argument("--script", default=str(SCRIPT))
    args = ap.parse_args(argv)

    out = Path(args.out) if args.out else (PARSER_DIR / "work" / "v3probe")
    built = build_v3(out)
    print("prepared v3probe.dsf (html v%d, next v%d)"
          % (built["header"]["html"]["version"],
             built["header"]["next"]["version"]))

    jsonl_ref = out / "jdaad.jsonl"
    jsonl_nd = out / "next.jsonl"

    res = subprocess.run(["node", str(PARSER_DIR / "jleg.js"), str(out),
                          args.script, str(jsonl_ref)],
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit("jDAAD leg failed:\n%s" % res.stderr)

    nleg.play(out, args.script, jsonl_nd, args.nex, port=args.port)

    ref = compare.load_jsonl(jsonl_ref)
    nd = compare.load_jsonl(jsonl_nd)
    result = compare.compare_runs(ref, nd)

    condacts = symbols.load_condacts(ROOT / "src" / "engine.asm")
    dsf_text = Path(built["dsf"]).read_text(encoding="utf-8", errors="replace")
    commands = json.loads(Path(args.script).read_text(encoding="utf-8"))
    findings = report.build_findings(result["divergences"], condacts, dsf_text,
                                     commands=commands, nd_turns=nd)
    report.write_report(findings, out / "report.md", out / "findings.json")

    print("%d turn(s) compared, %d finding(s) -> %s"
          % (result["turns_compared"], len(findings), out / "findings.json"))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
