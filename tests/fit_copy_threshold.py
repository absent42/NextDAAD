#!/usr/bin/env python3
"""tests/fit_copy_threshold.py - NXV2_COPY_DMA_MIN from NXBX/NXBG bench
rows: fits L (LDI) and D (DMA) lines per surface, prints the crossover
and implied threshold. Usage: python tests/fit_copy_threshold.py ROWS.txt
"""
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import nxv2enc as enc
import nxv2_bench_rows as bench
from fit_tmodel import _lsq

FLAT_ROWS = bench.BENCH_TABLES[5]
GAPPED_ROWS = tuple(r for r in bench.BENCH_TABLES[6] if r[0][:2] in ("GL", "GD"))
FLAT_TAGS = {r[0] for r in FLAT_ROWS}
GAPPED_TAGS = {r[0] for r in GAPPED_ROWS}
GAPPED_FIT_L = (56, 60, 72, 80)
GAPPED_SKIP_L = (48, 64)   # L divides 192: excluded, alignment artifact

GEOMETRY = {tag: (L, o, r, bench.row_path(tag))
            for tag, _kind, L, o, r, _thr, _geo in FLAT_ROWS + GAPPED_ROWS}

# Every tag any bench mode defines - used only to tell a genuinely unknown
# tag apart from a known row this script does not fit (GC03/GK56/GF71/GF56).
ALL_BENCH_TAGS = {r[0] for rows in bench.BENCH_TABLES.values() for r in rows}

ROW_RE = re.compile(r"^\s*([A-Z0-9]{4})\s+[O0]=([0-9A-F]{2})\s+R=([0-9A-F]{4})"
                    r"\s+F=([0-9A-F]{4})\s+D=([0-9A-F]{4,})", re.IGNORECASE)


def parse_rows(text):
    """-> ({tag: (o, r, f, d)} with d signed 16-bit, [warnings])."""
    rows, warnings = {}, []
    for n, line in enumerate(text.splitlines(), 1):
        m = ROW_RE.match(line)
        if not m:
            head = line.strip()[:4].upper()
            if head in GEOMETRY:
                warnings.append(f"line {n}: {head} row does not parse: {line.strip()!r}")
            continue
        tag = m.group(1).upper()
        if tag not in GEOMETRY:
            if tag not in ALL_BENCH_TAGS:
                warnings.append(f"line {n}: {tag} is not a known bench row, ignored")
            continue
        o, r, f = (int(m.group(i), 16) for i in (2, 3, 4))
        d = int(m.group(5)[:4], 16)
        if d >= 0x8000:
            d -= 0x10000
        L, go, gr, _ = GEOMETRY[tag]
        if (o, r) != (go, gr):
            warnings.append(f"line {n}: {tag} O={o} R={r}, the bench runs O={go} R={gr}")
        if tag in rows:
            warnings.append(f"line {n}: {tag} repeated, this reading kept")
        rows[tag] = (o, r, f, d)
    return rows, warnings


def _fit_surface(t, tags, fit_l, pair_of):
    """Least-squares L/D lines and crossover for one surface's rows
    present in t. fit_l, given, restricts the fitted points to those L
    values (rows outside it are still measured, just not fitted).
    ValueError when a path has under two distinct fitted L."""
    lines = {}
    for path in ("ldi", "dma"):
        pts = [(GEOMETRY[tag][0], t[tag]) for tag in t
               if tag in tags and GEOMETRY[tag][3] == path
               and (fit_l is None or GEOMETRY[tag][0] in fit_l)]
        if len({x for x, _ in pts}) < 2:
            raise ValueError(f"{path} rows need at least two distinct L, have {len(pts)}")
        lines[path] = _lsq(pts)
    a, b, _ = lines["ldi"]
    c, s, _ = lines["dma"]
    crossover = (c - a) / (b - s) if b != s else None
    threshold = (math.ceil(crossover - 1e-9)
                 if crossover is not None and s < b else None)
    spans = [[GEOMETRY[tag][0] for tag in t if tag in tags and GEOMETRY[tag][3] == p
              and (fit_l is None or GEOMETRY[tag][0] in fit_l)] for p in ("ldi", "dma")]
    span = (max(min(x) for x in spans), min(max(x) for x in spans))
    extrapolated = crossover is not None and not span[0] <= crossover <= span[1]
    contradictions = []
    for tag in sorted(tags, key=lambda tg: (GEOMETRY[tg][0], tg)):
        if tag not in t or GEOMETRY[tag][3] != "ldi":
            continue
        L = GEOMETRY[tag][0]
        if fit_l is not None and L not in fit_l:
            continue
        pair = pair_of(tag)
        if pair not in t or pair not in tags:
            continue
        measured = t[tag] - t[pair]
        fitted = (a + b * L) - (c + s * L)
        if measured * fitted < 0:
            contradictions.append((L, measured, fitted))
    return {"ldi": lines["ldi"], "dma": lines["dma"], "crossover": crossover,
            "threshold": threshold, "span": span, "extrapolated": extrapolated,
            "contradictions": contradictions}


def fit(rows):
    """Flat surface result at top level (unchanged shape); res["gapped"]
    holds the gapped fit, or {"error": ...} when too few gapped rows are
    present. Raises ValueError only when the flat fit itself fails."""
    t = {tag: bench.t_per_op(*rows[tag]) for tag in rows}
    out = _fit_surface(t, FLAT_TAGS, None, lambda tag: "D" + tag[1:])
    out["t"] = t
    try:
        out["gapped"] = _fit_surface(t, GAPPED_TAGS, GAPPED_FIT_L,
                                      lambda tag: "GD" + tag[2:])
    except ValueError as exc:
        out["gapped"] = {"error": str(exc)}
    return out


def _report_rows(rows, res, table, name, gapped=False):
    print(f"{name} rows, T/op = (F*{bench.LINES_PER_FRAME} + D)*{bench.T_PER_LINE}/(R*O)")
    print("  tag    L  path      O   R     F     D   measured      model      diff  note")
    for tag, _kind, L, _o, _r, _thr, _geo in table:
        note = "excluded from the gapped fit (L divides 192)" if gapped and L in GAPPED_SKIP_L else ""
        path = GEOMETRY[tag][3]
        if tag not in rows:
            print(f"  {tag} {L:>4}  {path}  missing  {note}")
            continue
        o, r, f, d = rows[tag]
        m = res["t"][tag]
        model = bench.row_predicted(enc, tag)
        print(f"  {tag} {L:>4}  {path}  {o:>5} {r:>3} {f:>5} {d:>5} "
              f"{m:>10.2f} {model:>10.2f} {m - model:>+9.2f}  {note}")


def _report_fit(fit_res, label, line_prefix=""):
    """label: '' for the flat surface (message text unchanged from the
    original single-surface script) or 'gapped ' for the gapped surface.
    line_prefix: '' or 'G' for the L/D line names (L/D vs GL/GD)."""
    if "error" in fit_res:
        print(f"no {label}fit: {fit_res['error']}")
        return
    for path, name in (("ldi", "L"), ("dma", "D")):
        icpt, slope, resid = fit_res[path]
        worst = max(abs(dv) for _, dv in resid)
        print(f"{line_prefix}{name} line  T = {icpt:.2f} + {slope:.4f} L   "
              f"({len(resid)} rows, worst residual {worst:.2f} T)")
    if fit_res["crossover"] is None:
        print(f"{label}crossover: none, the lines are parallel")
    else:
        print(f"{label}crossover L* = {fit_res['crossover']:.2f} B")
    if fit_res["extrapolated"]:
        print(f"WARNING {label}L* is outside the measured L span "
              f"{fit_res['span'][0]}-{fit_res['span'][1]} B (extrapolated)")
    shipping = enc.TMODEL_COEFFS["copy_dma_min"]
    if fit_res["threshold"] is None:
        print(f"implied {label}threshold: none, the D slope is not below the L slope")
    else:
        print(f"implied {label}NXV2_COPY_DMA_MIN = {fit_res['threshold']} (shipping {shipping})")
    pair_name = f"{line_prefix}L-{line_prefix}D" if line_prefix else "L-D"
    if not fit_res["contradictions"]:
        print(f"{label}pair order: every measured pair agrees with the lines")
    for L, measured, fitted in fit_res["contradictions"]:
        print(f"{label.upper()}CONTRADICTS at L={L}: measured {pair_name} "
              f"{measured:+.2f} T, lines {pair_name} {fitted:+.2f} T")


def report(rows, warnings, res):
    for w in warnings:
        print(f"WARNING {w}")
    _report_rows(rows, res, FLAT_ROWS, "NXBX")
    _report_fit(res, "")
    print()
    _report_rows(rows, res, GAPPED_ROWS, "NXBG", gapped=True)
    _report_fit(res["gapped"], "gapped ", "G")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: python tests/fit_copy_threshold.py ROWS.txt", file=sys.stderr)
        return 2
    rows, warnings = parse_rows(Path(argv[0]).read_text(encoding="utf-8", errors="replace"))
    try:
        res = fit(rows)
    except ValueError as exc:
        for w in warnings:
            print(f"WARNING {w}")
        print(f"no fit: {exc}")
        return 1
    report(rows, warnings, res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
