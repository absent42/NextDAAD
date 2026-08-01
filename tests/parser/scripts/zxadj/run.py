#!/usr/bin/env python3
"""Regression test for the ZX leg: re-run the SP16 adjudication fixture.

    python tests/parser/scripts/zxadj/run.py [--out DIR] [--port N]

SP16 Task 5 settled five register entries against the ORIGINAL DAAD ZX
interpreter with a one-off script (.superpowers/sdd/sp16-adjudications/
zxadj_run.py) and archived the transcript it produced. tests/parser/
zleg.py is that rig promoted into the harness. This driver proves the
promotion changed no measurement: it rebuilds the same fixture, plays the
same words through the NEW leg, and checks every answer against the
archived numbers, which are PINNED below so the check still runs on a
clean checkout (.superpowers/ is gitignored - if the archive IS present
the pin is verified against it first, so the two can never drift apart
silently).

The fixture DSF is referenced by path and never copied into the repo.

What is being compared. Both sections read state out of the fixture's own
status line - "V=33 N=34 Q QV QN A=36" - because the ZX leg has no memory
channel to read flags through (zleg.py's docstring explains why, and why
a printing fixture is the supported substitute). The archived transcript
prints exactly that line per word, so the comparison is the measurement
itself, not a proxy for it.

  D2  convertible-noun threshold: eight bare words straddling 39/40.
  B21 PARSE 1 over a quoted section: seven SAY forms.

E4 (the QUIT confirmation) is deliberately NOT replayed here: it ends the
game on purpose, twice, from two different input models, and a driver
whose whole job is a byte comparison should not also be the place that
proves the harness can drive a machine to its death. nleg.py's "?"
directive documents the settled answer.
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PARSER_DIR = HERE.parent.parent
ROOT = PARSER_DIR.parent.parent
sys.path.insert(0, str(PARSER_DIR))

import zleg  # noqa: E402

DSF = ROOT / ".superpowers" / "sdd" / "sp16-adjudications" / "zxadj.dsf"
ARCHIVE = (ROOT / ".superpowers" / "sdd" / "sp16-adjudications"
           / "zxadj-transcript.txt")

# Transcribed from that archived transcript, section by section. Each
# entry is (command, the fixture's status line after the parse).
PINNED = {
    "d2": [
        ("LOOK",  "V=10 N=255 Q=0 QV=0 QN=0 A=255"),
        ("ZZZZ",  "V=255 N=255 Q=0 QV=0 QN=0 A=255"),
        ("N19",   "V=19 N=19 Q=0 QV=0 QN=0 A=255"),
        ("N20",   "V=20 N=20 Q=0 QV=0 QN=0 A=255"),
        ("PLUGH", "V=25 N=25 Q=0 QV=0 QN=0 A=255"),
        ("N39",   "V=39 N=39 Q=0 QV=0 QN=0 A=255"),
        ("N40",   "V=255 N=40 Q=0 QV=0 QN=0 A=255"),
        ("BOX",   "V=255 N=60 Q=0 QV=0 QN=0 A=255"),
    ],
    "b21": [
        ('SAY FAST PLUGH',   "V=40 N=25 Q=0 QV=254 QN=254 A=55"),
        ('SAY "PLUGH"',      "V=25 N=25 Q=0 QV=25 QN=25 A=255"),
        ('SAY "N40"',        "V=255 N=40 Q=0 QV=255 QN=40 A=255"),
        ('SAY "LOOK PLUGH"', "V=10 N=25 Q=0 QV=10 QN=25 A=255"),
        ('SAY ""',           "V=255 N=255 Q=0 QV=254 QN=254 A=255"),
        ('SAY "ZZZZ"',       "V=255 N=255 Q=0 QV=254 QN=254 A=255"),
        ('SAY "FAST"',       "V=255 N=255 Q=0 QV=254 QN=254 A=55"),
    ],
}


def archived_pairs():
    """(command, status line) pairs parsed out of the archived transcript,
    or None when the archive is not on disk."""
    if not ARCHIVE.exists():
        return None
    pairs = []
    for line in ARCHIVE.read_text(encoding="utf-8",
                                  errors="replace").splitlines():
        m = re.match(r"\s+(\S.*?)\s+->\s+(V=.*)$", line)
        if m:
            pairs.append((m.group(1).strip(), m.group(2).strip()))
    return pairs


def check_pin_against_archive():
    pairs = archived_pairs()
    if pairs is None:
        print("archive absent (%s) - running against the pin alone" % ARCHIVE)
        return
    want = PINNED["d2"] + PINNED["b21"]
    if pairs != want:
        for a, b in zip(pairs, want):
            if a != b:
                print("  archive %r != pin %r" % (a, b))
        raise SystemExit("PINNED table no longer matches the archived "
                         "transcript - one of them was edited")
    print("pin verified against %s (%d lines)" % (ARCHIVE.name, len(pairs)))


def status_line(turn):
    """The fixture's status line out of one jsonl turn."""
    for line in reversed(turn["text"].splitlines()):
        if line.startswith("V="):
            return line.strip()
    return "(no status line: %r)" % turn["text"]


def run_section(name, out, port):
    script = HERE / (name + ".json")
    work = out / name
    work.mkdir(parents=True, exist_ok=True)
    built = zleg.build_tap(DSF, work)
    jsonl = work / "zx.jsonl"
    zleg.play(work, script, jsonl, tap=built["tap"], port=port, verbose=False)

    turns = [json.loads(l) for l in
             jsonl.read_text(encoding="utf-8").splitlines() if l.strip()]
    want = PINNED[name]
    if len(turns) != len(want):
        raise SystemExit("%s: leg produced %d turns, expected %d"
                         % (name, len(turns), len(want)))
    bad = 0
    for turn, (cmd, expected) in zip(turns, want):
        got = status_line(turn)
        ok = (turn["command"] == cmd and got == expected)
        bad += 0 if ok else 1
        print("  %-4s %-18s %s%s" % ("ok" if ok else "FAIL", turn["command"],
                                     got, "" if ok else
                                     "   expected %s" % expected))
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--port", type=int, default=zleg.DEFAULT_PORT)
    args = ap.parse_args(argv)
    if not DSF.exists():
        raise SystemExit(
            "the SP16 fixture is not on disk: %s\n"
            ".superpowers/ is gitignored, so this replay needs that "
            "workspace present." % DSF)

    out = Path(args.out) if args.out else (PARSER_DIR / "work" / "zxadj")
    out.mkdir(parents=True, exist_ok=True)
    check_pin_against_archive()

    bad = 0
    for name in ("d2", "b21"):
        print("== %s" % name)
        bad += run_section(name, out, args.port)
    print("---")
    print("%d/%d lines match the SP16 transcript"
          % (len(PINNED["d2"]) + len(PINNED["b21"]) - bad,
             len(PINNED["d2"]) + len(PINNED["b21"])))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
