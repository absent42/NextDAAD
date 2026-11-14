"""Ingest one silicon leg into the tracked results tree.

Usage: python tests/core303/ingest.py <leg_dir> --board ks1 --leg leg1
           [--date YYYY-MM-DD] [--nxb-baseline LOG --allow FILE]
"""
import argparse
import datetime
import os
import re
import shutil
import sys
from pathlib import Path

import parse
from parse import LogError

NAME = re.compile(r"[A-Za-z0-9_]+")


class IngestError(Exception):
    pass


def _first_line(path):
    with open(path, "rb") as f:
        return f.readline().decode("ascii", "replace").rstrip("\r\n")


def _gates_stamp(leg_dir):
    g = leg_dir / "GATES.TXT"
    if not g.is_file():
        raise IngestError("GATES.TXT missing in %s" % leg_dir)
    for line in g.read_text(encoding="ascii", errors="replace").splitlines():
        if line.startswith("stamp:"):
            stamp = line.split(":", 1)[1].strip()
            if not stamp or stamp.endswith("-dirty"):
                raise IngestError("GATES.TXT stamp unusable: %r" % stamp)
            return stamp
    raise IngestError("GATES.TXT has no stamp: line")


GATE_KEYS = ("quiet_check:", "bench_check:")


def _gates_section(leg_dir):
    """report.md tail: the GATES.TXT quiet and bench check lines, under Gates."""
    text = (leg_dir / "GATES.TXT").read_text(encoding="ascii", errors="replace")
    got = [l.strip() for l in text.splitlines() if l.startswith(GATE_KEYS)]
    for k in GATE_KEYS:
        if not any(l.startswith(k) for l in got):
            got.append("%s MISSING from GATES.TXT" % k)
    return "## Gates\n\n" + "".join("- %s\n" % l for l in got)


def _raw_logs(leg_dir):
    found = sorted(p for p in leg_dir.iterdir() if p.is_file() and (
        p.suffix.upper() == ".LOG" or
        (p.name.upper().startswith("NXBENCH") and p.suffix.upper() == ".TXT")))
    if not found:
        raise IngestError("no logs in %s" % leg_dir)
    return found


def _nr_line(path):
    for line in path.read_text(encoding="ascii").splitlines():
        if line.startswith("#NR "):
            return line
    raise IngestError("no #NR line in %s" % path)


def _leg1(results, date, board):
    folder = results / ("%s-%s-leg1" % (date, board))
    if not folder.is_dir():
        raise IngestError("leg 1 not ingested yet: %s" % folder.name)
    for p in sorted(folder.glob("*.LOG")):
        if _first_line(p).startswith("#CORE303 "):
            log = parse.parse_log(p)
            return folder.name, _nr_line(p), log
    raise IngestError("no CORE303 log in %s" % folder.name)


def ingest(leg_dir, board, leg, date, results, nxb_baseline=None, allow=None):
    leg_dir, results = Path(leg_dir), Path(results)
    for v in (board, leg):
        if not NAME.fullmatch(v):
            raise IngestError("bad name: %r" % v)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise IngestError("bad date: %r" % date)
    dest = results / ("%s-%s-%s" % (date, board, leg))
    if dest.exists():
        raise IngestError("%s exists; sittings are never overwritten" % dest.name)
    tmp = results / ("." + dest.name + ".partial")
    if tmp.exists():
        raise IngestError("%s exists from a crashed run; remove it" % tmp.name)
    idx = results / "INDEX.md"
    if not idx.is_file():
        raise IngestError("INDEX.md missing in %s" % results)
    old_index = idx.read_bytes()
    sep = b"" if old_index.endswith(b"\n") else b"\n"
    stamp = _gates_stamp(leg_dir)
    raws = _raw_logs(leg_dir)
    cores, nxbs = [], []
    try:
        for p in raws:
            if _first_line(p).startswith("#NXB"):
                nxbs.append(p)
            else:
                log = parse.parse_log(p)
                if log.stamp != stamp:
                    raise IngestError("%s stamp %s != GATES.TXT %s" % (p.name, log.stamp, stamp))
                cores.append((p, log))
        timing_from = None
        ref = cores[0] if cores else None
        if nxbs and not cores:
            timing_from, nr_line, ref_log = _leg1(results, date, board)
            nr, nr_line_out = ref_log.nr, nr_line
        elif ref:
            nr = ref[1].nr
            nr_line_out = _nr_line(ref[0])
        else:
            raise IngestError("no CORE303 or NXB log")
        tm = parse.timing(nr)
        nxb = None
        for p in nxbs:
            nxb = (nxb or []) + parse.parse_nxb(p)
        base = parse.parse_nxb(nxb_baseline) if nxb_baseline else None
        tags = []
        if allow:
            tags = [t.strip() for t in Path(allow).read_text().splitlines() if t.strip()]
        text = parse.report([c[1] for c in cores], nxb, base, timing=tm, ratio_tags=tags)
        text += "\n" + _gates_section(leg_dir)
    except LogError as e:
        raise IngestError(str(e))
    verdict = next((l for l in text.splitlines() if l.startswith("WAIT STATES:")), "ingested")

    tmp.mkdir()
    try:
        _write(tmp, leg_dir, raws, text, date, board, leg, stamp, nr, nr_line_out,
               timing_from)
        os.rename(tmp, dest)
        row = "| %s | %s | %s | %s | %s |\n" % (date, board, leg, verdict, dest.name)
        new = results / "INDEX.md.tmp"
        new.write_bytes(old_index + sep + row.encode("ascii"))
        os.replace(new, idx)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return dest


def _write(dest, leg_dir, raws, text, date, board, leg, stamp, nr, nr_line_out,
           timing_from):
    for p in [leg_dir / "GATES.TXT"] + raws:
        shutil.copyfile(p, dest / p.name)
    lines = ["date: " + date, "board: " + board, "leg: " + leg, "stamp: " + stamp,
             "core: %02X.%02X" % (nr.get("01", 0), nr.get("0E", 0)),
             "board_id: %02X" % nr.get("0F", 0),
             "sd_folder: " + leg_dir.name,
             "logs: " + ",".join(p.name for p in raws),
             "nr: " + nr_line_out]
    if timing_from:
        lines.append("timing_from: " + timing_from)
    (dest / "sitting.txt").write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    (dest / "report.md").write_bytes(text.encode("ascii", "replace"))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("leg_dir")
    ap.add_argument("--board", required=True)
    ap.add_argument("--leg", required=True)
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--nxb-baseline")
    ap.add_argument("--allow")
    a = ap.parse_args(argv)
    results = Path(__file__).parent / "results"
    try:
        dest = ingest(Path(a.leg_dir), a.board, a.leg, a.date, results,
                      a.nxb_baseline and Path(a.nxb_baseline), a.allow and Path(a.allow))
    except (IngestError, OSError, UnicodeDecodeError) as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
