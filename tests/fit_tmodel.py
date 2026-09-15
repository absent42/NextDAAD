#!/usr/bin/env python3
"""tests/fit_tmodel.py - fit TMODEL_COEFFS from a silicon bench sitting.

Reads a sitting from nxv2_bench_rows, fits the model's coefficients by
least squares over the rows named in the fit recipe, and prints each
constant with its residuals. A fit whose worst residual exceeds
RESIDUAL_LIMIT prints REFUSED instead of a value - a constant that noisy
is not evidence.

Terms that need a held input (fill_dma_per_b, copy_dma_setup, the DMA
chunk cap) read it from TMODEL_COEFFS and print it inline.

Usage: python tests/fit_tmodel.py [pre_fix|current]

The pre_fix sitting is the control: it must reproduce t_op_run 367.6 and
fill_cpu 15.856 with residuals at or under 5.3 T.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import nxv2enc as enc
import nxv2_bench_rows as bench

RESIDUAL_LIMIT = 15.0   # T; above this a fit is not evidence


def _lsq(points):
    """Least-squares line over [(x, y), ...] -> (intercept, slope, residuals)."""
    n = len(points)
    sx = sum(x for x, _ in points)
    sy = sum(y for _, y in points)
    sxx = sum(x * x for x, _ in points)
    sxy = sum(x * y for x, y in points)
    det = n * sxx - sx * sx
    slope = (n * sxy - sx * sy) / det
    intercept = (sy - slope * sx) / n
    resid = [(x, y - (intercept + slope * x)) for x, y in points]
    return intercept, slope, resid


def _fmt(name, value, worst, note=""):
    if worst > RESIDUAL_LIMIT:
        return f"  {name:<18} REFUSED (worst residual {worst:.1f} T > {RESIDUAL_LIMIT}) {note}"
    return f"  {name:<18} {value:>10.4f}   worst residual {worst:>6.2f} T  {note}"


def fit(sitting):
    rows = bench.ROWS[sitting]
    t = {tag: bench.t_per_op(*rows[tag]) for tag in rows}
    tc = enc.TMODEL_COEFFS
    out = {}

    print(f"=== sitting: {sitting} ===")
    print("measured T/op")
    for tag in sorted(t):
        print(f"  {tag:<6} {t[tag]:>10.2f}")

    print("\nfits")
    # RUN CPU line: fast-handler fill ops, dispatch intercept + per-byte slope.
    pts = [(1, t["RU01"]), (17, t["RU17"]), (63, t["F063"]), (70, t["F070"])]
    t_op_run, fill_cpu, r = _lsq(pts)
    worst = max(abs(d) for _, d in r)
    out["t_op_run"], out["fill_cpu"] = t_op_run, fill_cpu
    print(_fmt("t_op_run", t_op_run, worst, "[RU01 RU17 F063 F070]"))
    print(_fmt("fill_cpu", fill_cpu, worst, "[RU01 RU17 F063 F070]"))
    print("    residuals: " + ", ".join(f"L={x}:{d:+.2f}" for x, d in r))

    # COPY CPU line: fast-handler copy ops under 64 B (fetch_short band).
    pts = [(1, t["C001"]), (4, t["C004"]), (8, t["C008"]), (38, t["C038"])]
    t_op_copy, fetch_short, r = _lsq(pts)
    worst_c = max(abs(d) for _, d in r)
    out["t_op_copy"], out["fetch_short"] = t_op_copy, fetch_short
    print(_fmt("t_op_copy", t_op_copy, worst_c, "[C001 C004 C008 C038]"))
    print(_fmt("fetch_short", fetch_short, worst_c, "[C001 C004 C008 C038]"))
    print("    residuals: " + ", ".join(f"L={x}:{d:+.2f}" for x, d in r))

    # fetch_long: one row, so no residual - single-row evidence.
    fetch_long = (t["C080"] - t_op_copy) / 80.0
    out["fetch_long"] = fetch_long
    print(_fmt("fetch_long", fetch_long, 0.0, "[C080 - t_op_copy, SINGLE ROW]"))

    # fill DMA setup: F071 is the shortest fill that commits to the DMA
    # kernel. fill_dma_per_b is a held hardware term, not re-fit here.
    fdper = tc["fill_dma_per_b"]
    fill_dma_setup = t["F071"] - t_op_run - 71 * fdper
    out["fill_dma_setup"] = fill_dma_setup
    print(_fmt("fill_dma_setup", fill_dma_setup, 0.0,
               f"[F071 - t_op_run - 71*{fdper}, SINGLE ROW]"))

    # COPY DMA line: two slow-body rows 22 B apart give the per-byte
    # slope; C081 then places the path term against the held setup.
    copy_dma_per_b = (t["C103"] - t["C081"]) / 22.0
    out["copy_dma_per_b"] = copy_dma_per_b
    print(_fmt("copy_dma_per_b", copy_dma_per_b, 0.0, "[(C103-C081)/22, TWO ROWS]"))
    copy_dma_setup = tc["copy_dma_setup"]
    copy_dma_path_t = t["C081"] - t_op_copy - copy_dma_setup - 81 * copy_dma_per_b
    out["copy_dma_path_t"] = copy_dma_path_t
    print(_fmt("copy_dma_path_t", copy_dma_path_t, 0.0,
               f"[C081 - t_op_copy - {copy_dma_setup} - 81*per_b, SINGLE ROW]"))

    # skips are read straight off their rows.
    out["t_skip"], out["t_skip16"] = t["SK00"], t["S160"]
    print(_fmt("t_skip", t["SK00"], 0.0, "[SK00]"))
    print(_fmt("t_skip16", t["S160"], 0.0, "[S160]"))

    # Trailing-chunk evidence: what the model still owes on a 256 B op
    # once the fitted terms above are charged. 256 B = one 240 B DMA
    # chunk plus a sub-threshold tail the model prices as bare CPU.
    print("\ntrailing-chunk evidence (model owes, per op)")
    chunk = tc["copy_dma_chunk"]
    c256_model = (t_op_copy + (tc["t_skip16"] - tc["t_skip"])
                  + copy_dma_setup + chunk * copy_dma_per_b
                  + (256 - chunk) * fetch_long)
    f256_model = (t_op_run + fill_dma_setup + chunk * fdper
                  + (256 - chunk) * fill_cpu)
    print(f"  copy trailing term  {t['C256'] - c256_model:>10.2f} T  [C256 - modelled C256]")
    print(f"  fill trailing term  {t['F256'] - f256_model:>10.2f} T  [F256 - modelled F256]")

    # Slow-body intercept, measured on its own. C161/R161 are 16-bit ops
    # of one byte: they enter the slow body directly and run its cheapest
    # kernel, so they price slow-body entry + one chunk iteration with no
    # DMA and almost no transfer. Not scored (the encoder never emits a
    # 16-bit op below 256 B) but a valid measurement.
    print("\nslow-body intercept (C161/R161, not scored)")
    sb_copy = t["C161"] - 1 * fetch_short
    sb_run = t["R161"] - 1 * fill_cpu
    print(f"  copy slow body      {sb_copy:>10.2f} T   vs t_op_copy {t_op_copy:.2f} "
          f"(+{sb_copy - t_op_copy:.2f})")
    print(f"  run  slow body      {sb_run:>10.2f} T   vs t_op_run  {t_op_run:.2f} "
          f"(+{sb_run - t_op_run:.2f})")
    return out


def main():
    sitting = sys.argv[1] if len(sys.argv) > 1 else "current"
    if sitting not in bench.ROWS:
        raise SystemExit(f"unknown sitting {sitting!r}; have {sorted(bench.ROWS)}")
    fit(sitting)
    return 0


if __name__ == "__main__":
    sys.exit(main())
