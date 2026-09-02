#!/usr/bin/env python3
"""Front end for the NextDAAD parser test harness.

    python tests/parser/parsertest.py <game.dsf> <script.json> [options]

Builds the game for both interpreters, plays the script through each,
compares them, and writes report.md and findings.json. Exits 0 when the
two interpreters agreed on every turn, 1 otherwise.

Nothing this produces should ever be committed.
"""
import argparse
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

    prepare._run([prepare.NDRC, "nextdaad", lang, dest.name, "next.ddb",
                 "-v3", "-auto-tokens"], workdir)
    next_ddb = workdir / "next.ddb"
    if not next_ddb.exists():
        raise RuntimeError("ndrc did not produce %s" % next_ddb)
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
    # ---- optional third leg (see the --zx block at the end of main) ----
    ap.add_argument("--zx", action="store_true",
                    help="additionally play the script on the ORIGINAL DAAD "
                         "ZX 48K interpreter and write a NextDAAD-vs-ZX TEXT "
                         "differential (zx-report.md). Off by default: the "
                         "jDAAD/NextDAAD pair is the instrument, the ZX leg "
                         "is coverage and adjudication.")
    ap.add_argument("--zx-tap", default=None,
                    help="prebuilt TAP for the ZX leg, instead of building "
                         "one from the DSF (a shipped game with no source)")
    ap.add_argument("--zx-port", type=int, default=10010)
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
    # Script entries may be objects carrying per-turn directives (see
    # nleg.load_script); the report only wants the command text.
    commands = nleg.script_commands(nleg.load_script(args.script))

    findings = report.build_findings(divs, condacts, dsf_text, commands=commands,
                                     nd_turns=nd)
    report.write_report(findings, out / "report.md", out / "findings.json")

    print("%d turn(s) compared, %d finding(s) -> %s"
          % (result["turns_compared"], len(findings), out / "findings.json"))

    if args.zx:
        # The ZX leg runs AFTER everything above, reads nothing the two
        # existing legs wrote except meta.json's pager prompt, and writes
        # only zx-*. The default (no --zx) path therefore executes exactly
        # the code it did before this flag existed - which is the point:
        # the jDAAD/NextDAAD differential is the project's instrument and
        # its replays must stay byte-identical. zleg is imported HERE, not
        # at module scope, so even an import-time fault in the new module
        # cannot reach a normal two-leg run.
        import zleg
        try:
            zx_work = out / "zx"
            zx_work.mkdir(parents=True, exist_ok=True)
            tap, zx_charset = args.zx_tap, None
            if tap:
                sysmess = zleg.load_sysmess(Path(tap).with_suffix(".json"))
            else:
                zx_built = zleg.build_tap(built["dsf"], zx_work)
                tap, sysmess = zx_built["tap"], zx_built["sysmess"]
                # Decode with the font the TAP was BUILT with - the work
                # directory holds no .CHR to re-resolve against, so a
                # game shipping its own font would otherwise be read with
                # the stock one. See zleg.play_charset.
                zx_charset = zx_built["charset"]
            zx_jsonl = out / "zx.jsonl"
            # more_prompt comes from meta.json (jleg wrote it above, out
            # of jDAAD's own getMessage) so the two legs filter the SAME
            # string; sysmess supplies the SM2..SM5 prompt set, which
            # only the ZX leg needs because only it cannot pin flag 42.
            zleg.play(args.script, zx_jsonl, tap=tap, port=args.zx_port,
                      charset=zleg.play_charset(None, zx_charset, tap),
                      more_prompt=nleg.load_more_prompt(out), sysmess=sysmess)
            zx = compare.load_jsonl(zx_jsonl)
            # The ORIGINAL is the reference here, not NextDAAD: this leg
            # exists to say what the lineage does, and a difference is
            # NextDAAD deviating from it (or a known, documented reason
            # why). The Next turns are copied, never mutated: `nd` is the
            # list the jDAAD comparison above already used, and its
            # findings are written by then, but a shared-list edit here
            # would still be a trap for anyone who later moves this block.
            nd_zx = [dict(t, text=zleg.trim_prompt_tail(t["text"], sysmess))
                     for t in nd]
            zres = compare.compare_runs_text(zx, nd_zx)
            zleg.write_text_report(zres["divergences"], "ZX 48K original",
                                   "NextDAAD", out / "zx-report.md",
                                   out / "zx-findings.json",
                                   turns=zres["turns_compared"])
            print("ZX leg: %d turn(s) compared, %d text divergence(s) -> %s"
                  % (zres["turns_compared"], len(zres["divergences"]),
                     out / "zx-report.md"))
        except Exception as exc:
            # Advisory means advisory. findings.json and report.md are
            # already written and the two-leg verdict already stands; a
            # ZX build or emulator failure must not turn a completed run
            # into a crash and take the exit status with it. Reported
            # loudly, and the ZX outputs are simply absent.
            print("ZX leg FAILED (advisory - the two-leg result above "
                  "stands): %s: %s" % (type(exc).__name__, exc))

    # Exit status stays the two-leg verdict even with --zx. The ZX
    # differential is advisory coverage - it legitimately differs
    # wherever a game branches on the ZX subtarget, and a caller
    # scripting the harness must not have that flip its exit code.
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
