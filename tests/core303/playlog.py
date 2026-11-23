#!/usr/bin/env python3
"""Parse NXPLAY.TXT (the DEBUG log step's mode 16, after every GO or LOOP of the test game)
into one markdown row per capture.

Usage: python tests/core303/playlog.py NXPLAY.TXT [--out playback.md]

A capture is the header "#PLAY ccc pp ffff" (ccc = flag 140 in decimal, the clip PICK armed;
pp = vidPoolAtOpen, the free pool banks before that open; ffff = frameCounter) and the
non-empty screen rows 23-27: the open-refusal row, then the timeline report rows (FRM, RING,
PLAY, LATE). The table's Step is the capture number; raw_fit.read_playback reads its Step,
Clip, PLAY, FRM, LATE and URUN columns. Absent fields print "-". Exit 0, or 2 on a log error.
"""
import argparse
import re
import sys
from pathlib import Path

COLUMNS = ["Step", "Clip", "Pool", "Row 23", "FRM", "ERR", "OP", "POS", "PASS", "RING",
           "FILL", "SNAP", "PLAY", "NOM", "CHK", "LATE", "MAXL", "URUN", "RUNS"]
FIELDS = COLUMNS[4:]

HEADER = re.compile(r"#PLAY (\d{3}) ([0-9A-F]{2}) ([0-9A-F]{4})")
REPORT_ROW = re.compile(r"\s*(FRM|RING|PLAY|LATE)\s*=")
PAIR = re.compile(r"([A-Z]+)\s*=([0-9A-F]+(?:/[0-9A-F]+)*)")


class PlayLogError(Exception):
    pass


def _report_fields(line, cap, n):
    pairs = PAIR.findall(line)
    if PAIR.sub("", line).strip():
        raise PlayLogError("line %d: unreadable report row %r" % (n, line))
    for key, value in pairs:
        if key not in FIELDS:
            raise PlayLogError("line %d: unknown field %s" % (n, key))
        if cap[key] != "-":
            raise PlayLogError("line %d: %s twice in one capture" % (n, key))
        cap[key] = value


def parse_playlog(path):
    """[{column: cell}] in COLUMNS order, one per capture."""
    caps, row23 = [], []
    for n, line in enumerate(Path(path).read_bytes().decode("latin-1").splitlines(), 1):
        if not line.strip():
            continue
        m = HEADER.fullmatch(line)
        if m:
            caps.append(dict.fromkeys(COLUMNS, "-"))
            caps[-1].update(Step=str(len(caps)), Clip=m.group(1), Pool=m.group(2))
            row23.append([])
        elif line.startswith("#PLAY") or not caps:
            raise PlayLogError("line %d: %r is not a #PLAY ccc pp ffff header" % (n, line))
        elif REPORT_ROW.match(line):
            _report_fields(line, caps[-1], n)
        else:
            row23[-1].append(line.strip())
    for cap, text in zip(caps, row23):
        if text:
            cap["Row 23"] = " / ".join(text)
    return caps


def markdown(caps, source):
    out = ["# Play log %s - %d captures" % (source, len(caps)), "",
           "| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS)]
    for cap in caps:
        out.append("| " + " | ".join(cap[k].replace("|", "&#124;") for k in COLUMNS) + " |")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="NXPLAY.TXT to a markdown table")
    ap.add_argument("log")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    try:
        caps = parse_playlog(a.log)
    except (OSError, PlayLogError) as exc:
        print("playlog: %s" % exc, file=sys.stderr)
        return 2
    text = markdown(caps, Path(a.log).name)
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
