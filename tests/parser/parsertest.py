#!/usr/bin/env python3
"""Front end for the NextDAAD parser test harness.

    python tests/parser/parsertest.py <game.dsf> <script.json> [options]

Builds the game for both interpreters, plays the script through each,
compares them, and writes report.md and findings.json. Exits 0 when the
two interpreters agreed on every turn, 1 otherwise.

Nothing this produces should ever be committed.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compare
import nleg
import prepare
import report
import symbols

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

# The one tracked fixture this whole harness has been built and tested
# against (tests/condacts.dsf). --mutate-next-only (below) assumes the
# "game" path it is given is a deliberately mutated COPY of this file -
# see that flag's handling in main() for why.
CONDACTS_DSF = ROOT / "tests" / "condacts.dsf"


def _rebuild_next_only(mutated_dsf, workdir, lang="EN"):
    """Rebuild ONLY the Next DDB, from `mutated_dsf`, into `workdir`.

    Used exclusively by the --mutate-next-only negative-control hook (see
    main()). The caller is expected to have already built a normal,
    matched pair in `workdir` from the real, unmutated CONDACTS_DSF, so
    the jDAAD .jddb staged there reflects the true original text; this
    function then overwrites just next.ddb with a build compiled from
    the mutated copy, so the two legs genuinely - and deliberately -
    disagree. assert_matched() is intentionally never called against
    this result: the whole point of this path is that the pair is NOT
    matched, and prepare_from_dsf's usual guarantee (both targets
    compiled from the same source in one call) is knowingly violated
    here to prove the harness can detect exactly that kind of divergence.
    Do not route normal runs through this function.
    """
    workdir = Path(workdir)
    mutated_dsf = Path(mutated_dsf)
    dest = workdir / mutated_dsf.name
    if mutated_dsf.resolve() != dest.resolve():
        dest.write_bytes(mutated_dsf.read_bytes())

    prepare._run([prepare.DRF, "zx", "next", dest.name, "next.json"], workdir)
    prepare._run([prepare.PHP, prepare.DRB, "zx", "next", lang, "next.json",
                 "next.ddb"], workdir)
    next_ddb = workdir / "next.ddb"
    if not next_ddb.exists():
        raise RuntimeError("DRB did not produce %s" % next_ddb)
    return next_ddb


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("game", help="path to a .dsf source file")
    ap.add_argument("script", help="path to a JSON command script")
    ap.add_argument("--out", default=None, help="output directory")
    ap.add_argument("--port", type=int, default=10000)
    ap.add_argument("--nex", default=str(ROOT / "build" / "nextdaad.nex"))
    ap.add_argument("--stop-on-first", action="store_true",
                    help="truncate the comparison at the primary divergence")
    ap.add_argument("--mutate-next-only", action="store_true",
                    help=argparse.SUPPRESS)   # negative-control hook
    args = ap.parse_args(argv)

    out = Path(args.out) if args.out else (
        ROOT / "tests" / "parser" / "work" / Path(args.game).stem)
    out.mkdir(parents=True, exist_ok=True)

    if args.mutate_next_only:
        # Negative-control hook. `args.game` here is NOT treated as "the"
        # source - it is a deliberately mutated COPY of CONDACTS_DSF (see
        # tests/parser/parser_selftest.py's t11_negative_control_is_detected,
        # which builds it from tests/condacts.dsf's own text). If we built
        # both targets from args.game as usual, jDAAD and NextDAAD would
        # BOTH see the mutation and agree - no divergence, no proof of
        # anything. Instead: build the normal MATCHED pair from the real,
        # unmutated CONDACTS_DSF first (so jDAAD's .jddb reflects the true
        # original text), then rebuild ONLY next.ddb from the mutant. That
        # is the only way the two legs are made to genuinely disagree.
        # This deliberately violates prepare_from_dsf's matched-pair
        # guarantee (both targets from the SAME source in one call) - on
        # purpose, and only reachable via this suppressed flag, never in
        # normal use.
        built = prepare.prepare_from_dsf(CONDACTS_DSF, out)
        _rebuild_next_only(args.game, out)
    else:
        built = prepare.prepare_from_dsf(args.game, out)

    print("prepared %s (html v%d, next v%d)"
          % (Path(args.game).name, built["header"]["html"]["version"],
             built["header"]["next"]["version"]))

    jsonl_ref = out / "jdaad.jsonl"
    jsonl_nd = out / "next.jsonl"

    res = subprocess.run(["node", str(HERE / "jleg.js"), str(out),
                          str(args.script), str(jsonl_ref)],
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit("jDAAD leg failed:\n%s" % res.stderr)

    nleg.play(out, args.script, jsonl_nd, args.nex, port=args.port)

    ref = compare.load_jsonl(jsonl_ref)
    nd = compare.load_jsonl(jsonl_nd)
    result = compare.compare_runs(ref, nd)

    divs = result["divergences"]
    if args.stop_on_first and divs:
        divs = [divs[0]]

    condacts = symbols.load_condacts(ROOT / "src" / "engine.asm")
    dsf_text = Path(built["dsf"]).read_text(encoding="utf-8", errors="replace")
    commands = json.loads(Path(args.script).read_text(encoding="utf-8"))

    findings = report.build_findings(divs, condacts, dsf_text, commands=commands,
                                     nd_turns=nd)
    report.write_report(findings, out / "report.md", out / "findings.json")

    print("%d turn(s) compared, %d finding(s) -> %s"
          % (result["turns_compared"], len(findings), out / "findings.json"))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
