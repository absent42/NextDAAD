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

  2. The SETAT stand-ins are patched. DRF 0.40 has no SETAT keyword, so
     tests/v3probe.dsf authors each SETAT as a tagged LET and the opcode
     is rewritten to 124 afterwards - in the Next DDB and in the jDAAD
     .jddb's DDBDATA array alike, so both legs run the same condacts.
     tests/build-tests.ps1's Invoke-V3SetatPatch carries the same table
     for the -V3 staging path; keep the two in step. ndrc has a real
     SETAT keyword, so this stand-in is retirable; that is a separate,
     owner-proposed change.

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
import re
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

# SETAT stand-ins: (tag, param1, param2). The six-byte signature is
# LET 250 <tag> / LET <p1> <p2>, and the second opcode becomes 124.
SETAT_SITES = ((7, 0, 1), (8, 0, 2), (9, 0, 1))


def _patch_bytes(data, where):
    """Rewrite each stand-in's opcode to 124. Insists on exactly one
    match per signature - anything else means the fixture no longer
    says what its comments say, and a silently unpatched stand-in would
    write flags 0 and 3 instead of touching an attribute bit."""
    out = bytearray(data)
    for tag, p1, p2 in SETAT_SITES:
        sig = bytes((51, 250, tag, 51, p1, p2))
        hits = [i for i in range(len(out) - len(sig) + 1)
                if out[i:i + len(sig)] == sig]
        if len(hits) != 1:
            raise RuntimeError(
                "%s: SETAT stand-in tag %d matched %d times, expected 1"
                % (where, tag, len(hits)))
        out[hits[0] + 3] = 124
    return bytes(out)


def _patch_jddb(path):
    """Same patch, applied to the DDBDATA array inside a .jddb.

    The file is plain JavaScript: 'var DDBDATA = [0x..,0x..,// 0x0009'
    and, when the game has external messages, a second 'var XMBDATA'
    array after it. Only the first array is the database, so the split
    is on the XMBDATA declaration and only the head is rewritten.

    ndrc punctuates every tenth byte with a '// 0x0009' running-offset
    comment, reproducing DRB's writer (drb.php:1392), whose text looks
    exactly like a data token, so the comments come out BEFORE the
    tokens are read - leaving them in injects a phantom byte every ten
    and the signatures stop matching (which is how this was found).
    """
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    split = text.find("var XMBDATA")
    head, tail = (text[:split], text[split:]) if split >= 0 else (text, "")
    head = re.sub(r"//[^\n]*", "", head)
    tokens = re.findall(r"0x[0-9a-fA-F]+", head)
    if not tokens:
        raise RuntimeError("%s: no DDBDATA bytes found" % path)
    data = bytes(int(t, 16) & 0xFF for t in tokens)
    # Sanity check against the binary ndrc produced alongside. ndrc
    # reproduces DRB's writer, which loops on !feof() with fgetc(), so it
    # always emits ONE trailing 0x0 past the end of the file
    # (drb.php:1386-1396, visible as the "...,0x0\n];" every .jddb ends
    # with) - hence the +1.
    ddb = Path(path).with_name("html.DDB")
    if ddb.exists() and len(data) not in (ddb.stat().st_size,
                                          ddb.stat().st_size + 1):
        raise RuntimeError("%s: parsed %d DDBDATA bytes, html.DDB is %d"
                           % (path, len(data), ddb.stat().st_size))
    data = _patch_bytes(data, str(path))
    body = ",".join("0x%x" % b for b in data)
    Path(path).write_text("var DDBDATA = [\n%s\n];\n%s" % (body, tail),
                          encoding="utf-8")


def build_v3(workdir, lang="EN"):
    """Compile tests/v3probe.dsf to both targets via prepare.prepare_from_dsf,
    then apply the SETAT stand-in patch (see module docstring point 2)."""
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    built = prepare.prepare_from_dsf(DSF, workdir, lang)
    next_ddb = built["ddb"]
    jddb = built["jddb"]

    next_ddb.write_bytes(_patch_bytes(next_ddb.read_bytes(), str(next_ddb)))

    # prepare_from_dsf already staged an unpatched daad.jddb for jDAAD;
    # patch jddb in place then re-copy it over daad.jddb so jDAAD loads
    # the patched database.
    _patch_jddb(jddb)
    shutil.copyfile(jddb, workdir / "daad.jddb")

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
