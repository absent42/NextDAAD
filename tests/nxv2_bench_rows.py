#!/usr/bin/env python3
"""tests/nxv2_bench_rows.py - silicon decode-bench rows as test data.

Rows come from the DEBUG NXBEN verbs (NXBO/NXBC/NXBK) on real hardware,
VGA-0 timing, core 3.02.04. A row is (ops per rep, reps, frame wraps,
raster-line delta) exactly as the bench prints it; the bench's own
conversion is T = (F * 311 + D) * 1824 at 28 MHz. PRE_FIX is the player
before the decode-loop change, kept as history; CURRENT is the player
these coefficients describe, read 2026-09-15.
"""
# Model's fitted scale (NOT the bench machine's physical VGA-0 timing,
# 312 x 1792). Every earlier row and shipping coefficient uses this
# scale - do not "correct" it, that would under-price the model.
LINES_PER_FRAME = 311
T_PER_LINE = 1824

PRE_FIX = {
    "SK00": (255, 64, 4, 25),    "S160": (255, 64, 6, 21),
    "RU01": (255, 32, 5, 159),   "RU17": (255, 32, 9, 56),
    "CP01": (255, 32, 4, 214),   "CP17": (255, 32, 10, -233),
    "R161": (255, 32, 14, 230),  "C161": (255, 32, 15, 223),
    "C001": (255, 64, 9, 118),   "C004": (255, 64, 11, 6),
    "C008": (255, 48, 10, -30),  "C016": (255, 48, 13, 57),
    "C038": (197, 48, 18, -123), "C080": (96, 64, 20, 127),
    "C081": (95, 64, 20, -21),   "C103": (75, 64, 17, -99),
    "C256": (30, 96, 19, 49),    "F063": (125, 64, 19, 61),
    "F070": (112, 64, 19, -85),  "F071": (111, 64, 21, 25),
    "F256": (30, 96, 18, -53),   "K256": (30, 96, 19, 50),
}

# Sitting 1, 2026-09-15, post decode-loop change (commit 8c0cb61).
CURRENT = {
    "SK00": (255, 64, 4, 25),
    "S160": (255, 64, 6, 21),
    "RU01": (255, 32, 5, 158),
    "RU17": (255, 32, 9, 56),
    "CP01": (255, 32, 4, 214),
    "CP17": (255, 32, 10, -233),
    "R161": (255, 32, 12, 77),
    "C161": (255, 32, 12, -93),
    "C001": (255, 64, 9, 117),
    "C004": (255, 64, 11, 5),
    "C008": (255, 48, 10, -30),
    "C016": (255, 48, 13, 58),
    "C038": (197, 48, 18, -123),
    "C080": (96, 64, 20, 127),
    "C081": (95, 64, 17, -19),
    "C103": (75, 64, 15, -211),
    "C256": (30, 96, 16, 101),
    "F063": (125, 64, 19, 62),
    "F070": (112, 64, 19, -85),
    "F071": (111, 64, 19, -26),
    "F256": (30, 96, 16, 23),
    "K256": (30, 96, 17, -210),
}

ROWS = {"pre_fix": PRE_FIX, "current": CURRENT}

# R161/C161 are NOT scored: they are 16-bit-operand ops of 1 byte, which
# the encoder never emits (below 256 B it emits the 8-bit op), and the
# model picks its envelope by length, so it would price them as 8-bit.
PRICERS = {
    "SK00": lambda e: e._cost_skip_chunk(1)[1],
    "S160": lambda e: e._cost_skip_chunk(256)[1],
    "RU01": lambda e: e._cost_run_chunk(1)[1],
    "RU17": lambda e: e._cost_run_chunk(17)[1],
    "CP01": lambda e: e._cost_copy_chunk(1)[1],
    "CP17": lambda e: e._cost_copy_chunk(17)[1],
    "C001": lambda e: e._cost_copy_chunk(1)[1],
    "C004": lambda e: e._cost_copy_chunk(4)[1],
    "C008": lambda e: e._cost_copy_chunk(8)[1],
    "C016": lambda e: e._cost_copy_chunk(16)[1],
    "C038": lambda e: e._cost_copy_chunk(38)[1],
    "C080": lambda e: e._cost_copy_chunk(80)[1],
    "C081": lambda e: e._cost_copy_chunk(81)[1],
    "C103": lambda e: e._cost_copy_chunk(103)[1],
    "C256": lambda e: e._cost_copy_chunk(256)[1],
    "F063": lambda e: e._cost_run_chunk(63)[1],
    "F070": lambda e: e._cost_run_chunk(70)[1],
    "F071": lambda e: e._cost_run_chunk(71)[1],
    "F256": lambda e: e._cost_run_chunk(256)[1],
    "K256": lambda e: e._cost_copy_chunk(256)[1],
}


def t_per_op(o, r, f, d):
    """Measured T per op for one bench row."""
    return (f * LINES_PER_FRAME + d) * T_PER_LINE / float(r * o)


def priced(enc, sitting="current"):
    """{tag: (measured T/op, modeled T/op)} over the scored tags."""
    rows = ROWS[sitting]
    return {tag: (t_per_op(*rows[tag]), price(enc))
            for tag, price in PRICERS.items() if tag in rows}
