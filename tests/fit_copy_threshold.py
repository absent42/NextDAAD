#!/usr/bin/env python3
"""tests/fit_copy_threshold.py - NXV2_COPY_DMA_MIN from NXBX bench rows.

Usage: python tests/fit_copy_threshold.py ROWS.txt

ROWS.txt is the NXBX screen as transcribed, one row per line:
    L048 O=9D R=0040 F=0013 D=003E
0= parses as O=; a D= field longer than 4 hex digits keeps its first 4
(screen residue). Lines that are not NXBX rows are ignored.

Fits a least-squares line T(L) to the L rows (fast-handler LDI) and to
the D rows (body + DMA, D081 included), then prints both lines, their
crossover L*, the threshold it implies (smallest integer L >= L*), each
row against the model, and any pair whose measured order contradicts
the lines.
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

GEOMETRY = {tag: (L, o, r, path) for tag, L, o, r, path in bench.NXBX_ROWS}
ROW_RE = re.compile(r"^\s*([LD]\d{3})\s+[O0]=([0-9A-F]{2})\s+R=([0-9A-F]{4})"
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
            warnings.append(f"line {n}: {tag} is not an NXBX row, ignored")
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


def fit(rows):
    """Measured T/op per row, both lines, crossover, implied threshold and
    contradicting pairs. ValueError when a set has under two distinct L."""
    t = {tag: bench.t_per_op(*rows[tag]) for tag in rows}
    lines = {}
    for path in ("ldi", "dma"):
        pts = [(GEOMETRY[tag][0], t[tag]) for tag in t if GEOMETRY[tag][3] == path]
        if len({x for x, _ in pts}) < 2:
            raise ValueError(f"{path} rows need at least two distinct L, have {len(pts)}")
        lines[path] = _lsq(pts)
    a, b, _ = lines["ldi"]
    c, s, _ = lines["dma"]
    crossover = (c - a) / (b - s) if b != s else None
    threshold = (math.ceil(crossover - 1e-9)
                 if crossover is not None and s < b else None)
    contradictions = []
    for tag, (L, _o, _r, path) in GEOMETRY.items():
        pair = "D" + tag[1:]
        if path != "ldi" or tag not in t or pair not in t:
            continue
        measured = t[tag] - t[pair]
        fitted = (a + b * L) - (c + s * L)
        if measured * fitted < 0:
            contradictions.append((L, measured, fitted))
    return {"t": t, "ldi": lines["ldi"], "dma": lines["dma"],
            "crossover": crossover, "threshold": threshold,
            "contradictions": contradictions}


def report(rows, warnings, res):
    model = bench.nxbx_predicted(enc)
    for w in warnings:
        print(f"WARNING {w}")
    print(f"NXBX rows, T/op = (F*{bench.LINES_PER_FRAME} + D)*{bench.T_PER_LINE}/(R*O)")
    print("  tag    L  path      O   R     F     D   measured      model      diff")
    for tag, L, _o, _r, path in bench.NXBX_ROWS:
        if tag not in rows:
            print(f"  {tag} {L:>4}  {path}  missing")
            continue
        o, r, f, d = rows[tag]
        m = res["t"][tag]
        print(f"  {tag} {L:>4}  {path}  {o:>5} {r:>3} {f:>5} {d:>5} {m:>10.2f} "
              f"{model[tag]:>10.2f} {m - model[tag]:>+9.2f}")
    for path, name in (("ldi", "L"), ("dma", "D")):
        icpt, slope, resid = res[path]
        worst = max(abs(dv) for _, dv in resid)
        print(f"{name} line  T = {icpt:.2f} + {slope:.4f} L   "
              f"({len(resid)} rows, worst residual {worst:.2f} T)")
    if res["crossover"] is None:
        print("crossover: none, the lines are parallel")
    else:
        print(f"crossover L* = {res['crossover']:.2f} B")
    shipping = enc.TMODEL_COEFFS["copy_dma_min"]
    if res["threshold"] is None:
        print("implied threshold: none, the D slope is not below the L slope")
    else:
        print(f"implied NXV2_COPY_DMA_MIN = {res['threshold']} (shipping {shipping})")
    if not res["contradictions"]:
        print("pair order: every measured pair agrees with the lines")
    for L, measured, fitted in res["contradictions"]:
        print(f"CONTRADICTS at L={L}: measured L-D {measured:+.2f} T, "
              f"lines L-D {fitted:+.2f} T")


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
