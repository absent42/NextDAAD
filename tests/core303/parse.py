"""Parse CORE303 bench logs and NXB screen dumps; print a markdown report.

Usage: python tests/core303/parse.py <log>... [--nxb LOG --baseline LOG]
"""
import argparse
import re
import sys
from dataclasses import dataclass, field
from fractions import Fraction
from math import ceil
from pathlib import Path
from typing import Optional

import tags as tagtab
from tags import TAGS

# Standalone NXB verbs, modes 2-12 (tests/test.dsf:322-332). NXBR/NXBD are session verbs.
STANDALONE_VERBS = frozenset(
    "nxbo nxbc nxbk nxbx nxbg nxbl nxbt nxbe nxbh nxbf nxbv".split())

# RUN crossover letters: group 11 flat rows FCnn (CPU fill) / FDnn (DMA fill),
# src/video.asm:5319-5320 (nxbTabFill). Gapped rows VCnn/VDnn are not used.
RUN_CPU = "FC"
RUN_DMA = "FD"
# COPY crossover letters: L (LDI) / D (DMA), NXB group 5 (src/video.asm:3757).
COPY_CPU = "L"
COPY_DMA = "D"

CURRENT_COPY_MIN = 53
CURRENT_RUN_MIN = 71

# C=W / C=L calibration tags by (clock, speed).
CAL_TAG = {("W", 3): "CAL0", ("W", 2): "CAL1", ("L", 3): "B0CL", ("L", 2): "B1CL"}
MIN_FRAMES = 50
# Calibration rows (Tag.calibration): R=hhhh caps an empty pass at about 17.6 frames
# (B0CL at S=3, no waits); 1 line over 65535 reps is about 0.03 T per rep.
CAL_MIN_FRAMES = 15


class LogError(Exception):
    pass


@dataclass
class Row:
    tag: str
    clock: str
    speed: int
    r: int
    f: int
    d: int
    n: int
    ck: Optional[int] = None
    ck_ok: Optional[bool] = None
    lat: Optional[int] = None
    end: Optional[int] = None
    q: Optional[tuple] = None


@dataclass
class Log:
    bench: str
    stamp: str
    nr: dict
    sram_kb: int
    rows: list
    skips: list
    runs: int = 1
    ignored: list = field(default_factory=list)


@dataclass
class NxbRun:
    tag: str
    size: Optional[int]
    o: int
    r: int
    f: int
    d: int
    section: int
    kind: str


def _s16(v):
    return v - 0x10000 if v >= 0x8000 else v


def _hex(tok, n, what):
    if not re.fullmatch(r"[0-9A-F]{%d}" % n, tok):
        raise LogError("malformed %s: %r" % (what, tok))
    return int(tok, 16)


def _read(path):
    raw = Path(path).read_bytes()
    if not raw.endswith(b"\n"):
        raise LogError("%s: truncated (no final LF)" % path)
    try:
        return raw.decode("ascii")
    except UnicodeDecodeError:
        raise LogError("%s: non-ASCII bytes" % path)


def _parse_row(line):
    tok = line.split(" ")
    if not re.fullmatch(r"[A-Z0-9]{4}", tok[0]):
        raise LogError("unknown line: %r" % line)
    tag = tok[0]
    if tag not in TAGS:
        raise LogError("unknown tag %s" % tag)
    kv = {}
    i = 1
    ck_ok = None
    while i < len(tok):
        k, eq, v = tok[i].partition("=")
        if not eq:
            raise LogError("malformed field %r in %r" % (tok[i], line))
        if k == "CK":
            if i + 1 >= len(tok) or tok[i + 1] not in ("OK", "BAD"):
                raise LogError("CK without verdict: %r" % line)
            ck_ok = tok[i + 1] == "OK"
            i += 1
        if k in kv:
            raise LogError("duplicate field %s: %r" % (k, line))
        kv[k] = v
        i += 1
    for k in "CSRFDN":
        if k not in kv:
            raise LogError("missing field %s: %r" % (k, line))
    if kv["C"] not in ("W", "L") or not re.fullmatch(r"[0-3]", kv["S"]):
        raise LogError("malformed C/S: %r" % line)
    q = None
    if "Q" in kv:
        if not re.fullmatch(r"[0-2][01][23]", kv["Q"]):
            raise LogError("malformed Q: %r" % line)
        q = tuple(int(c) for c in kv["Q"])
    row = Row(tag, kv["C"], int(kv["S"]), _hex(kv["R"], 4, "R"), _hex(kv["F"], 4, "F"),
              _s16(_hex(kv["D"], 4, "D")), _hex(kv["N"], 4, "N"), q=q)
    if "CK" in kv:
        row.ck, row.ck_ok = _hex(kv["CK"], 4, "CK"), ck_ok
    if "L" in kv:
        row.lat = _hex(kv["L"], 2, "L")
    if "E" in kv:
        row.end = _hex(kv["E"], 4, "E")
    if set(kv) - set("CSRFDNQ") - {"CK", "L", "E"}:
        raise LogError("unknown field in %r" % line)
    if row.r == 0:
        raise LogError("R=0: %r" % line)
    return row


def parse_log(path):
    """Each #CORE303 line starts a run (the writer appends). The last run must be
    complete and is returned; an earlier run without #END is listed in .ignored."""
    segs = []
    for line in _read(path).split("\n")[:-1]:
        if line.startswith("#CORE303") or not segs:
            segs.append([])
        segs[-1].append(line)
    log = _parse_run(segs[-1])
    log.runs = len(segs)
    log.ignored = [k for k, s in enumerate(segs[:-1], 1)
                   if not any(l.startswith("#END ") for l in s)]
    return log


def _parse_run(lines):
    bench = stamp = None
    nr = {}
    sram = None
    rows, skips = [], []
    end = None
    for line in lines:
        if end is not None:
            raise LogError("data after #END: %r" % line)
        if line.startswith("#CORE303 "):
            m = re.fullmatch(r"#CORE303 (STANDALONE|BENCH) (\S+)", line)
            if not m:
                raise LogError("bad header: %r" % line)
            bench, stamp = m.groups()
        elif line.startswith("#NR "):
            for t in line.split(" ")[1:]:
                k, eq, v = t.partition("=")
                if not eq:
                    raise LogError("bad #NR: %r" % line)
                nr[k] = _hex(v, 2, "NR")
        elif line.startswith("#SRAM "):
            if not re.fullmatch(r"#SRAM \d+", line):
                raise LogError("bad #SRAM: %r" % line)
            sram = int(line.split(" ")[1])
        elif line.startswith("#SKIP "):
            m = re.fullmatch(r"#SKIP ([A-Z0-9]{4}) (.+)", line)
            if not m:
                raise LogError("bad #SKIP: %r" % line)
            skips.append(m.groups())
        elif line.startswith("#END "):
            end = _hex(line[5:], 4, "#END")
        elif line.startswith("#"):
            raise LogError("unknown line: %r" % line)
        else:
            rows.append(_parse_row(line))
    if end is None:
        raise LogError("truncated: no #END")
    if end != len(rows):
        raise LogError("row count %d != #END %d" % (len(rows), end))
    if bench is None or sram is None or not nr:
        raise LogError("missing header, #NR or #SRAM")
    return Log(bench, stamp, nr, sram, rows, skips)


_NXB_ROW = re.compile(
    r"(?<![A-Z0-9])([A-Z0-9]{4}) O=([0-9A-F]{2}) R=([0-9A-F]{4}) F=([0-9A-F]{4}) D=([0-9A-F]{4})")
_SIZE_TAG = re.compile(r"[A-Z]\d{3}")


def parse_nxb(path):
    """Parse an NXB screen dump. No tag-table check (the format has no tag table).

    The screen is not cleared, so a row identical in every field to one in the
    previous section is the same run and is counted once. This would collapse a
    genuine re-run that happens to produce identical counts (as KS02 does in the
    Q log); that is harmless for ratios. The same tag with different values is a
    new run, kept in order.
    """
    text = _read(path)
    runs = []
    section = 0
    verb = None
    prev_keys, cur_keys = set(), set()
    for line in text.split("\n")[:-1]:
        line = line.rstrip("\r")
        if line.startswith("LOG ERR"):
            raise LogError("%s: %s" % (path, line))
        if line.startswith("#NXB "):
            section += 1
            verb = None
            prev_keys, cur_keys = cur_keys, set()
            continue
        m = re.match(r">\s*(\S+)", line)
        if m:
            verb = m.group(1).lower()
            continue
        found = _NXB_ROW.findall(line)
        if not found:
            if "O=" in line:
                raise LogError("malformed row line: %r" % line)
            continue
        for tg, o, r, f, d in found:
            key = (tg, o, r, f, d)
            cur_keys.add(key)
            if key in prev_keys:
                continue
            ov = int(o, 16)
            kind = "table" if (ov != 0 and len(found) == 1
                               and verb in STANDALONE_VERBS) else "session"
            size = int(tg[1:]) if _SIZE_TAG.fullmatch(tg) else None
            runs.append(NxbRun(tg, size, ov, int(r, 16), int(f, 16),
                               _s16(int(d, 16)), section, kind))
    return runs


def timing(nr):
    """Return (LPF, TPL at 3.5 MHz); only +3 timing at 50 Hz is verified."""
    if (nr.get("03", 0) >> 4) & 7 != 3 or nr.get("05", 0) & 4:
        raise LogError("timing mode not verified")
    return 311, 228


def row_t(row, lpf, tpl35):
    return (row.f * lpf + row.d) * tpl35 * (1 << row.speed)


def _cal_name(row):
    """The calibration tag this row subtracts (Tag.cal, else CAL_TAG), or None."""
    name = TAGS[row.tag].cal or CAL_TAG.get((row.clock, row.speed))
    return None if row.tag == name else name


def _cal_row(log, row):
    name = _cal_name(row)
    if name is None:
        return None
    for c in log.rows:
        if c.tag == name and c.clock == row.clock and c.speed == row.speed:
            return c
    return None


def per_unit(log, row, lpf, tpl35):
    """T per unit = (row T per rep - its cal row's T per rep, same clock and
    speed) / N, or None (no cal row in the log, or N = 0)."""
    cal = _cal_row(log, row)
    if cal is None or row.n == 0:
        return None
    rep = Fraction(row_t(row, lpf, tpl35), row.r)
    crep = Fraction(row_t(cal, lpf, tpl35), cal.r)
    return (rep - crep) / row.n


def isr_per_frame(log, row, lpf, tpl35):
    """Tag.per_frame rows: (row T - its cal row's T) / row F, or None."""
    cal = _cal_row(log, row)
    if cal is None or row.f == 0:
        return None
    return Fraction(row_t(row, lpf, tpl35) - row_t(cal, lpf, tpl35), row.f)


ISR_IDLE = "B2I0"
CROSS_PAIRS = ("HD", "PR", "SC", "PB", "GT")
CONTROL_TAGS = ("P1C1", "P1C2")
NO_ISR = "no ISR figure"


def isr_idle(log, lpf, tpl35):
    """Idle frame-ISR T per frame from the first B2I0 row, or None."""
    for r in log.rows:
        if r.tag == ISR_IDLE:
            return isr_per_frame(log, r, lpf, tpl35)
    return None


def per_unit_ex_isr(log, row, lpf, tpl35, isr):
    """per_unit with each run's ISR share (its F x isr) taken out of both the row
    and its companion, so the companion does not remove the row's share twice."""
    cal = _cal_row(log, row)
    if cal is None or row.n == 0:
        return None
    rep = Fraction(row_t(row, lpf, tpl35) - row.f * isr, row.r)
    crep = Fraction(row_t(cal, lpf, tpl35) - cal.f * isr, cal.r)
    return (rep - crep) / row.n


def _documented(tag):
    return float(re.search(r"documented=([\d.]+)", TAGS[tag].note).group(1))


def _control(log, lpf, tpl35):
    """14 MHz control rows (C=W, S=2) against their documented T, +/-0.05 T."""
    got = {}
    for r in log.rows:
        if r.tag in CONTROL_TAGS and r.clock == "W" and r.speed == 2 \
                and r.ck_ok is not False and r.tag not in got:
            got[r.tag] = per_unit(log, r, lpf, tpl35)
    if not got:
        return []
    out = []
    for tag in CONTROL_TAGS:
        v, doc = got.get(tag), _documented(tag)
        if v is None:
            out.append("14 MHZ CONTROL %s: NOT MEASURED" % tag)
        else:
            ok = abs(float(v) - doc) <= 0.05
            out.append("14 MHZ CONTROL %s: %.2f T vs documented %.2f: %s" % (
                tag, float(v), doc, "OK" if ok else "MISMATCH"))
    return out


def _cross_check(log, lpf, tpl35, isr):
    """Part 2 workloads at 28 MHz (B2) against 14 MHz (B3): T/unit and E."""
    first = {}
    for r in log.rows:
        first.setdefault(r.tag, r)
    out = []
    for k in CROSS_PAIRS:
        b2, b3 = first.get("B2" + k), first.get("B3" + k)
        if b2 is None and b3 is None:
            continue
        if b2 is None or b3 is None:
            out.append("B2/B3 %s: %s missing" % (k, "B2" if b2 is None else "B3"))
            continue
        unit = TAGS["B2" + k].unit
        u2, u3 = per_unit(log, b2, lpf, tpl35), per_unit(log, b3, lpf, tpl35)
        line = "B2/B3 %s: 28MHz %s 14MHz %s T/%s" % (k, _fmt(u2), _fmt(u3), unit)
        if isr is None:
            line += ", " + NO_ISR
        else:
            line += ", ex-ISR %s / %s" % (_fmt(per_unit_ex_isr(log, b2, lpf, tpl35, isr)),
                                          _fmt(per_unit_ex_isr(log, b3, lpf, tpl35, isr)))
        if b2.end is None and b3.end is None:
            line += "; E none"
        elif b2.end == b3.end:
            line += "; E %04X EQUAL" % b2.end
        else:
            line += "; E DIFFER B2=%s B3=%s" % tuple(
                "-" if e is None else "%04X" % e for e in (b2.end, b3.end))
        out.append(line)
    return out


def _companion(tag):
    """True when some Tag.cal names this tag (a BENCH companion row)."""
    return any(t.cal == tag for t in TAGS.values())


def _flags(row, lpf, tpl35, log=None):
    out = []
    if log is not None and _cal_name(row) and _cal_row(log, row) is None:
        out.append("NOCAL")
    frame = lpf * tpl35 * (1 << row.speed)
    rep = Fraction(row_t(row, lpf, tpl35), row.r)
    if row.clock == "W":
        if TAGS[row.tag].method == tagtab.CPU:
            if rep * 8 >= frame:
                out.append("CLOCK?")
        elif rep * 10 >= 9 * frame:
            out.append("CLOCK?")
    if row.ck_ok is False:
        out.append("UNUSABLE")
    # A companion's error is 1 line over R reps sized by its workload: never SHORT.
    cal = TAGS[row.tag].calibration
    if row.f < MIN_FRAMES and not (cal and row.f >= CAL_MIN_FRAMES) \
            and not _companion(row.tag):
        out.append("SHORT")
    if TAGS[row.tag].per_frame:
        out.append("T/frame")
    if row.speed == 2:
        out.append("14MHz")
    return out


def _cross(points):
    """points: (size, cpu T, dma T). First size where DMA <= CPU, interpolated."""
    pts = sorted(points)
    diffs = [(s, dma - cpu) for s, cpu, dma in pts]
    wins = [d <= 0 for _, d in diffs]
    if all(wins):
        return "below %d" % pts[0][0]
    if not any(wins):
        return "above %d" % pts[-1][0]
    flips = [i for i in range(1, len(wins)) if wins[i] != wins[i - 1]]
    (s0, d0), (s1, d1) = diffs[flips[0] - 1], diffs[flips[0]]
    x = s0 + (s1 - s0) * Fraction(d0) / (d0 - d1)
    out = str(ceil(x))
    return out + " NON-MONOTONIC" if len(flips) > 1 else out


def _nxb_t(run, lpf, tpl35):
    return (run.f * lpf + run.d) * tpl35 * 8   # C=W at S=3


def _per_op(run, lpf, tpl35):
    return Fraction(_nxb_t(run, lpf, tpl35), run.r * run.o)


def crossover(rows, cpu, dma, lpf, tpl):
    """Smallest size where DMA per-op T <= CPU, over <cpu><size>/<dma><size> table pairs."""
    multi = set()

    def table(prefix):
        out, seen = {}, {}
        for r in rows:
            if r.kind == "table" and r.tag.startswith(prefix) and r.tag[len(prefix):].isdigit():
                out[int(r.tag[len(prefix):])] = _per_op(r, lpf, tpl)
                seen.setdefault(r.tag, set()).add((r.o, r.r, r.f, r.d))
        return out, {t for t, k in seen.items() if len(k) > 1}
    (c, mc), (d, md) = table(cpu), table(dma)
    pts = [(s, c[s], d[s]) for s in c if s in d]
    if not pts:
        raise LogError("no %s/%s pairs" % (cpu, dma))
    hit = any(t[len(cpu):].isdigit() and int(t[len(cpu):]) in {p[0] for p in pts}
              for t in mc) or any(t[len(dma):].isdigit() and int(t[len(dma):]) in
                                  {p[0] for p in pts} for t in md)
    return _cross(pts) + (" MULTI-RUN" if hit else "")


def multi_run_tags(runs):
    """Return {tag: count} for tags with more than one distinct table run."""
    seen = {}
    for r in runs:
        if r.kind == "table":
            seen.setdefault(r.tag, set()).add((r.o, r.r, r.f, r.d))
    return {t: len(k) for t, k in seen.items() if len(k) > 1}


def _fmt(v):
    return "-" if v is None else "%.2f" % float(v)


def _verdict(log, lpf, tpl35):
    got = {}
    for r in log.rows:
        if r.tag in ("P1NP", "P1RD") and r.clock == "W" and r.speed == 3 \
                and r.ck_ok is not False and r.tag not in got:
            got[r.tag] = per_unit(log, r, lpf, tpl35)
    if not got:
        return None
    nop, rd = got.get("P1NP"), got.get("P1RD")
    if nop is None or rd is None:
        return "WAIT STATES: NOT MEASURED"

    def vals(tag):
        m = re.search(r"documented=([\d.]+) old-core=([\d.]+)", TAGS[tag].note)
        return float(m.group(1)), float(m.group(2))
    near = lambda v, w: abs(float(v) - w) <= 0.05
    (nd, no), (rdd, rdo) = vals("P1NP"), vals("P1RD")
    if near(nop, nd) and near(rd, rdd):
        return "WAIT STATES: ABSENT"
    if near(nop, no) and near(rd, rdo):
        return "WAIT STATES: PRESENT"
    return "WAIT STATES: UNEXPLAINED (NOP=%.2f RD=%.2f)" % (float(nop), float(rd))


def _report_log(log, lpf, tpl35, out):
    out.append("## %s %s" % (log.bench, log.stamp))
    out.append("")
    out.append("NR: " + " ".join("%s=%02X" % kv for kv in log.nr.items()) +
               "  SRAM: %d KB" % log.sram_kb)
    if log.runs > 1:
        out.append("")
        out.append("RUNS: %d (last used)" % log.runs)
    for k in log.ignored:
        out.append("TRUNCATED RUN %d ignored" % k)
    out.append("")
    parts = sorted({TAGS[r.tag].part for r in log.rows})
    isr = isr_idle(log, lpf, tpl35)
    for part in parts:
        p2 = part == "2"
        out.append("### Part %s" % part)
        out.append("")
        if p2:
            out.append("ISR share: row F x B2I0 T/frame, taken out of the row and its "
                       "companion (%s)." % ("%.2f T/frame" % float(isr) if isr is not None
                                            else NO_ISR))
            out.append("")
            out.append("| tag | op | method | size | T/rep | T/unit | T/unit ex-ISR | notes |")
            out.append("|---|---|---|---|---|---|---|---|")
        else:
            out.append("| tag | op | method | size | T/rep | T/unit | notes |")
            out.append("|---|---|---|---|---|---|---|")
        for r in (x for x in log.rows if TAGS[x.tag].part == part):
            t = TAGS[r.tag]
            name = r.tag + ("" if r.q is None else " Q=%d%d%d" % r.q)
            notes = _flags(r, lpf, tpl35, log)
            if part == "1a" and t.note:
                notes.append("[%s]" % t.note)
            rep = Fraction(row_t(r, lpf, tpl35), r.r)
            unit = isr_per_frame(log, r, lpf, tpl35) if t.per_frame else \
                per_unit(log, r, lpf, tpl35)
            cells = [name, t.op, t.method, "-" if t.size is None else t.size, _fmt(rep),
                     _fmt(unit)]
            if p2:
                if t.per_frame:
                    cells.append("-")
                elif isr is None:
                    cells.append(NO_ISR)
                else:
                    cells.append(_fmt(per_unit_ex_isr(log, r, lpf, tpl35, isr)))
            cells.append(" ".join(notes))
            out.append("| " + " | ".join(str(c) for c in cells) + " |")
        out.append("")
        if part == "1a":
            ctl = _control(log, lpf, tpl35)
            out += ctl + ([""] if ctl else [])
        if p2:
            xc = _cross_check(log, lpf, tpl35, isr)
            out += xc + ([""] if xc else [])
    # Break-even, OK rows only: each DMA/BLT (op, method, Q) group against the CPU
    # rows of the same op (the quiet baseline, which carries no Q), size by size.
    base, groups = {}, {}
    for r in log.rows:
        t = TAGS[r.tag]
        if r.ck_ok is False or t.size is None:
            continue
        u = per_unit(log, r, lpf, tpl35)
        if u is None:
            continue
        if t.method == tagtab.CPU:
            base.setdefault((t.part, t.op), {})[t.size] = u
        else:
            groups.setdefault((t.part, t.op, t.method, r.q), {})[t.size] = u
    for (part, op, method, q), d in sorted(groups.items(), key=str):
        c = base.get((part, op), {})
        pts = [(s, c[s], d[s]) for s in c if s in d]
        if pts:
            out.append("BREAK-EVEN part %s %s %s%s: %s" % (
                part, op, method, "" if q is None else " Q=%d%d%d" % q, _cross(pts)))
    for tg, why in log.skips:
        out.append("SKIP %s %s" % (tg, why))
    v = _verdict(log, lpf, tpl35)
    if v:
        out.append(v)
    out.append("")


ISR_NOTE = ("Ratios include a small frame-ISR change since the baseline (im2_isr gained call kb_tick); "
            "NXB puts the live frame ISR under 1% of a row.")


def _report_nxb(runs, base, lpf, tpl35, ratio_tags, out):
    out.append("## NXB")
    out.append("")
    out.append("| tag | size | kind | O | R | F | D | T | T/op |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        per = _fmt(_per_op(r, lpf, tpl35)) if r.kind == "table" else "-"
        out.append("| %s | %s | %s | %02X | %04X | %04X | %04X | %d | %s |" % (
            r.tag, "-" if r.size is None else r.size, r.kind, r.o, r.r, r.f,
            r.d & 0xFFFF, _nxb_t(r, lpf, tpl35), per))
    out.append("")
    multi = multi_run_tags(runs)
    for tg, n in sorted(multi.items()):
        out.append("MULTI-RUN %s: %d table runs, last used" % (tg, n))
    if multi:
        out.append("")
    if base and ratio_tags:
        def last(rs):
            return {x.tag: x for x in rs if x.kind == "table"}
        new, old = last(runs), last(base)
        shown = False
        for tg in ratio_tags:
            if tg in new and tg in old:
                if not shown:
                    out.append(ISR_NOTE)
                    shown = True
                mark = " MULTI-RUN" if tg in multi or tg in multi_run_tags(base) else ""
                out.append("RATIO %s old/new = %.3f%s" % (
                    tg, float(_per_op(old[tg], lpf, tpl35) / _per_op(new[tg], lpf, tpl35)), mark))
        out.append("")
    for name, cpu, dma, cur in (("NXV2_COPY_DMA_MIN", COPY_CPU, COPY_DMA, CURRENT_COPY_MIN),
                                ("NXV2_RUN_DMA_MIN", RUN_CPU, RUN_DMA, CURRENT_RUN_MIN)):
        try:
            res = crossover(runs, cpu, dma, lpf, tpl35)
        except LogError:
            res = "no pairs"
        out.append("%s: %s (current %d)" % (name, res, cur))
    out.append("")


def report(logs, nxb, baseline, timing=None, ratio_tags=()):
    """Markdown report. timing=(LPF, TPL35) is used for NXB when no log is given."""
    out = ["# CORE303 report", ""]
    tm = timing
    for log in logs:
        lpf, tpl35 = _timing(log.nr)
        tm = tm or (lpf, tpl35)
        _report_log(log, lpf, tpl35, out)
    if nxb is not None:
        if tm is None:
            raise LogError("NXB needs a timing mode: pass a CORE303 log or timing=")
        _report_nxb(nxb, baseline, tm[0], tm[1], ratio_tags, out)
    return "\n".join(out) + "\n"


_timing = timing   # report() shadows the name with its keyword


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="*")
    ap.add_argument("--nxb")
    ap.add_argument("--baseline")
    ap.add_argument("--ratio-tags", default="")
    a = ap.parse_args(argv)
    try:
        logs = [parse_log(p) for p in a.logs]
        nxb = parse_nxb(a.nxb) if a.nxb else None
        base = parse_nxb(a.baseline) if a.baseline else None
        sys.stdout.write(report(logs, nxb, base,
                                ratio_tags=[t for t in a.ratio_tags.split(",") if t]))
    except LogError as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
