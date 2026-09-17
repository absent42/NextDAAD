#!/usr/bin/env python3
"""tests/nxv2_bench_log.py - runs from the DEBUG bench log NXBENCH.TXT.

Every bench verb ends with the log step (bench mode 15, src/video.asm
nxb_log): a "#NXB hhhh" line (frameCounter), then text rows 0-31 with
trailing spaces trimmed, empty rows skipped, CRLF. The step captures the
screen BEFORE it prints its own LOG OK / LOG ERR xx on row 31, so the LOG
line inside a capture is the previous run's status.

parse(text) -> [Run]. A Run holds the typed command (the last bench verb on
the capture's non-row lines), the rows of that verb's table in print order
as (tag, O, R, F, D) with D two's complement, and the report lines (every
other non-empty line below the command). A two-column session screen prints
rows 8-23 at column 0 and then at column 40, so every column-1 group follows
every column-0 group. Row groups whose tag is not in the verb's table (stale
rows) are dropped.

Text with no #NXB line is read as typed screen text: a line starting with a
bench verb opens a run (PICK lines just above it belong to it), "0=" reads
as "O=", and a LOG line belongs to the run it is typed under.

Usage: python tests/nxv2_bench_log.py NXBENCH.TXT
"""
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import nxv2_bench_rows as bench

# tests/test.dsf: standalone verbs set flags+250 = mode, session verbs flags+248.
STANDALONE_VERBS = {"NXBO": 2, "NXBC": 3, "NXBK": 4, "NXBX": 5, "NXBG": 6, "NXBL": 7,
                    "NXBT": 8, "NXBE": 9, "NXBH": 10, "NXBF": 11, "NXBV": 12}
SESSION_VERBS = {"NXBD": "DS1", "NXBR": "REAL", "NXBQ": "SYN", "NXBY": "SYS"}
VERBS = {**STANDALONE_VERBS, **SESSION_VERBS}
COL2 = 40                                   # NXB_SESS_COL2

# LOG ERR xx: bits 7-5 the step (NXB_LOG_*), bits 4-0 the esxDOS code, or 0 for
# a short count, a file size other than offset + bytes written, or a mismatch.
LOG_STEPS = {1: "open for write", 2: "size, seek to the end", 3: "write",
             4: "close after writing", 5: "reopen, size check, seek back",
             6: "read back", 7: "compare, final close"}

HEADER_RE = re.compile(r"#NXB ([0-9A-F]{4})$")     # may follow a short write's partial line
LOG_RE = re.compile(r"^LOG (OK|ERR [0-9A-F]{2})$", re.IGNORECASE)
_H = "[0-9A-Fa-f]"
GROUP_RE = re.compile(rf"(?<![A-Za-z0-9])([A-Za-z0-9]{{4}})\s+[O0]=({_H}{{2}})\s+R=({_H}{{4}})"
                      rf"\s+F=({_H}{{4}})\s+D=({_H}{{4}})({_H}*)(?![A-Za-z0-9])")
START_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{4}\s+[O0]=")
VERB_RE = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(VERBS) + r")(?![A-Za-z0-9])", re.IGNORECASE)
PICK_RE = re.compile(r"(?<![A-Za-z0-9])PICK\s+(\d+)", re.IGNORECASE)
ERR_RE = re.compile(r"(?<![A-Za-z])ERR=([0-9A-F]{2})")


@dataclass
class Run:
    stamp: int = None          # the #NXB frameCounter; None for typed text
    command: str = None        # the bench verb, upper case
    clip: int = None           # PICK nn above a session verb, when on screen
    table: object = None       # BENCH_TABLES mode or SESSION_TABLES name
    rows: list = field(default_factory=list)      # (tag, O, R, F, D), print order
    report: list = field(default_factory=list)    # lines below the command
    err: int = None            # the first ERR=hh in the report
    log: str = None            # "OK" or "ERR hh": this run's own log status
    dropped: list = field(default_factory=list)   # groups of other tables' tags
    warnings: list = field(default_factory=list)
    lines: list = field(default_factory=list)     # the capture as written


def table_tags(command):
    """The tags a verb's table prints (any delivery), or () for no verb."""
    if command in STANDALONE_VERBS:
        return bench.printed_tags(STANDALONE_VERBS[command])
    if command in SESSION_VERBS:
        return tuple(r[0] for r in bench.SESSION_TABLES[SESSION_VERBS[command]]
                     if r[1] not in bench.SESSION_SILENT)
    return ()


def log_error_step(code):
    """A LOG ERR code -> (step, esxDOS code or 0)."""
    return LOG_STEPS.get(code >> 5, "unknown step"), code & 0x1F


def _groups(line, warnings):
    """-> [(column, (tag, O, R, F, D))] for one line; a row start that does
    not parse, or a D field over 4 digits, adds a warning."""
    out, spans = [], []
    for k, m in enumerate(GROUP_RE.finditer(line)):
        tag = m.group(1).upper()
        o, r, f, d = (int(m.group(i), 16) for i in (2, 3, 4, 5))
        if d >= 0x8000:
            d -= 0x10000
        if m.group(6):
            warnings.append(f"{tag}: D={m.group(5)}{m.group(6)} has over 4 digits, first 4 kept")
        out.append((1 if k or m.start() >= COL2 else 0, (tag, o, r, f, d)))
        spans.append((m.start(), m.end()))
    if any(not any(a <= m.start() < b for a, b in spans) for m in START_RE.finditer(line)):
        warnings.append(f"row text does not parse: {line.strip()!r}")
    return out


def _run(lines, stamp):
    """One capture -> (Run, the LOG status on it or None)."""
    run = Run(stamp=stamp, lines=list(lines))
    at, status = None, None
    for i, line in enumerate(lines):
        if LOG_RE.match(line.strip()) or GROUP_RE.search(line):
            continue
        hits = VERB_RE.findall(line)
        if hits:
            at, run.command = i, hits[-1].upper()
    if at is None:
        run.warnings.append("no bench verb in the capture: no rows attributed")
    else:
        run.table = VERBS[run.command]
        picks = [p for line in lines[:at + 1] for p in PICK_RE.findall(line)]
        if picks and run.command in SESSION_VERBS:
            run.clip = int(picks[-1])
    tags = set(table_tags(run.command))
    cols = ([], [])
    for i, line in enumerate(lines):
        if LOG_RE.match(line.strip()):
            status = line.strip()[4:].upper()
            continue
        groups = _groups(line, run.warnings)
        for col, g in groups:
            (cols[col] if g[0] in tags else run.dropped).append(g)
        if not groups and at is not None and i > at and line.strip():
            run.report.append(line.rstrip())
    run.rows = cols[0] + cols[1]
    errs = [ERR_RE.search(line) for line in run.report]
    run.err = next((int(m.group(1), 16) for m in errs if m), None)
    return run, status


def parse(text):
    """NXBENCH.TXT, or typed screen text, -> [Run] in order."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    typed = not any(HEADER_RE.search(line) for line in lines)
    chunks, pending = [], []                    # [(stamp, lines)], typed PICK lines
    for line in lines:
        h = HEADER_RE.search(line)
        if h:
            if h.start() and chunks:            # a failed step's unterminated line
                chunks[-1][1].append(line[:h.start()])
            chunks.append((int(h.group(1), 16), []))
            continue
        if not typed:
            if chunks:
                chunks[-1][1].append(line)
            continue
        words = line.replace(">", " ").split()
        first = words[0].upper() if words else ""
        if first in VERBS:
            chunks.append((None, pending + [line]))
            pending = []
        elif first == "PICK":
            pending.append(line)
        elif chunks and line.strip():
            chunks[-1][1].append(line)
    runs = []
    for stamp, body in chunks:
        run, status = _run(body, stamp)
        if typed:
            run.log = status
        elif status and runs:
            runs[-1].log = status               # printed after the previous capture
        runs.append(run)
    return runs


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: python tests/nxv2_bench_log.py NXBENCH.TXT", file=sys.stderr)
        return 2
    runs = parse(Path(argv[0]).read_text(encoding="latin-1"))
    bad = 0
    for n, run in enumerate(runs, 1):
        stamp = "typed" if run.stamp is None else f"#NXB {run.stamp:04X}"
        clip = "" if run.clip is None else f" clip {run.clip}"
        err = "-" if run.err is None else f"{run.err:02X}"
        print(f"{n:3} {stamp} {run.command or '?'}{clip}: {len(run.rows)} rows, ERR={err}, "
              f"LOG {run.log or '-'}, {len(run.dropped)} dropped")
        for w in run.warnings:
            print(f"      WARNING {w}")
        if run.log and run.log != "OK":
            step, code = log_error_step(int(run.log[4:], 16))
            print(f"      LOG ERR at step '{step}', esxDOS code {code}")
        bad += bool(run.command is None or run.warnings or run.err
                    or run.log not in (None, "OK"))
    print(f"{len(runs)} runs, {bad} with a problem")
    return 1 if bad or not runs else 0


if __name__ == "__main__":
    sys.exit(main())
