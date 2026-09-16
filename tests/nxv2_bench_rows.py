#!/usr/bin/env python3
"""tests/nxv2_bench_rows.py - silicon decode-bench rows as test data.

Rows come from the DEBUG NXBEN verbs (NXBO/NXBC/NXBK/NXBX/NXBG/NXBL/NXBT)
on real hardware, VGA-0 timing, core 3.02.04. A row is (ops per rep, reps,
frame wraps, raster-line delta) exactly as the bench prints it; the
bench's own conversion is T = (F * 311 + D) * 1824 at 28 MHz. PRE_FIX is
the player before the decode-loop change, kept as history; CURRENT is the
player these coefficients describe, read 2026-09-15.

BENCH_TABLES holds the bench modes 5-8 row geometry (NXBX/NXBG/NXBL/NXBT)
exactly as src/video.asm defines nxbTabThr/nxbTabGap/nxbTabLong/nxbTabNew:
each row carries its own explicit COPY kernel-select value (thr), so the
bench measures a fixed select value directly instead of depending on
whatever NXV2_COPY_DMA_MIN currently ships.
"""
# Bench Next machine timing: +3, 311 lines x 1824 T (28 MHz) per field.
# Every row and shipping coefficient uses this scale.
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

# Sitting 3, 2026-09-16, NXBX run 1 plus the first NXBC block, transcribed
# from the silicon readout. (O, R, F, D) keyed by tag, D signed 16-bit.
SITTING3 = {
    "C001": (255, 64, 9, 117),
    "C004": (255, 64, 11, 5),
    "C008": (255, 48, 10, -30),
    "C016": (255, 48, 13, 58),
    "C038": (197, 48, 18, -123),
    "C080": (96, 64, 20, 127),
    "C081": (95, 64, 17, -19),
    "C103": (75, 64, 15, -211),
    "C256": (30, 96, 16, 102),
    "L048": (157, 64, 22, 28),
    "D048": (157, 64, 25, 6),
    "L056": (136, 64, 22, -100),
    "D056": (136, 64, 22, 92),
    "L060": (127, 64, 21, 105),
    "D060": (127, 64, 21, 35),
    "L064": (119, 64, 21, 6),
    "D064": (119, 64, 20, 18),
    "L072": (106, 64, 21, -91),
    "D072": (106, 64, 19, -200),
    "L080": (96, 64, 20, 127),
    "D080": (96, 64, 17, 19),
    "D081": (95, 64, 17, -19),
}

SITTING4 = {}   # sitting 4 rows, transcribed after the sitting is run

ROWS = {"pre_fix": PRE_FIX, "current": CURRENT,
        "sitting3": SITTING3, "sitting4": SITTING4}

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


# BENCH_TABLES: {mode: ((tag, kind, L, O, R, thr, geo), ...)} for bench
# modes 5-8, exactly as src/video.asm defines nxbTabThr/nxbTabGap/
# nxbTabLong/nxbTabNew. kind is "copy8"/"copy16"/"run8"/"run16"
# (VOP_COPY8/VOP_COPY16/VOP_RUN8/VOP_RUN16). thr 0 = shipping select
# value; geo bit 0 = gapped, bit 1 = mid-page dest.
BENCH_TABLES = {
    5: (   # NXBX - nxbTabThr: COPY path pairs at an explicit select value
        ("L048", "copy8", 48, 157, 64, 81, 0),
        ("D048", "copy8", 48, 157, 64, 1, 0),
        ("L056", "copy8", 56, 136, 64, 81, 0),
        ("D056", "copy8", 56, 136, 64, 1, 0),
        ("L060", "copy8", 60, 127, 64, 81, 0),
        ("D060", "copy8", 60, 127, 64, 1, 0),
        ("L064", "copy8", 64, 119, 64, 81, 0),
        ("D064", "copy8", 64, 119, 64, 1, 0),
        ("L072", "copy8", 72, 106, 64, 81, 0),
        ("D072", "copy8", 72, 106, 64, 1, 0),
        ("L080", "copy8", 80, 96, 64, 81, 0),
        ("D080", "copy8", 80, 96, 64, 1, 0),
        ("D081", "copy8", 81, 95, 64, 81, 0),
    ),
    6: (   # NXBG - nxbTabGap: gapped surface, height 192
        ("GL48", "copy8", 48, 124, 64, 81, 1),
        ("GD48", "copy8", 48, 124, 64, 48, 1),
        ("GL56", "copy8", 56, 106, 64, 81, 1),
        ("GD56", "copy8", 56, 106, 64, 56, 1),
        ("GL60", "copy8", 60, 99, 64, 81, 1),
        ("GD60", "copy8", 60, 99, 64, 60, 1),
        ("GL64", "copy8", 64, 93, 64, 81, 1),
        ("GD64", "copy8", 64, 93, 64, 64, 1),
        ("GL72", "copy8", 72, 82, 64, 81, 1),
        ("GD72", "copy8", 72, 82, 64, 72, 1),
        ("GL80", "copy8", 80, 74, 64, 81, 1),
        ("GD80", "copy8", 80, 74, 64, 80, 1),
        ("GD81", "copy8", 81, 73, 64, 81, 1),
        ("GC03", "copy8", 103, 57, 64, 81, 1),
        ("GK56", "copy16", 256, 23, 96, 81, 1),
        ("GF71", "run8", 71, 83, 64, 0, 1),
        ("GF56", "run16", 256, 23, 96, 0, 1),
    ),
    7: (   # NXBL - nxbTabLong: long COPY16 ops at 81 (LK43 not coverable)
        ("LF1K", "copy16", 1000, 7, 64, 81, 0),
        ("LF4K", "copy16", 4000, 1, 64, 81, 0),
        ("LF7K", "copy16", 7680, 1, 64, 81, 0),
        ("LFDS", "copy16", 7680, 1, 64, 81, 2),
        ("LG1K", "copy16", 1000, 5, 64, 81, 1),
        ("LG4K", "copy16", 4000, 1, 64, 81, 1),
        ("LGDS", "copy16", 4000, 1, 64, 81, 3),
    ),
    8: (   # NXBT - nxbTabNew: rows at a simulated NXV2_COPY_DMA_MIN of 59
        ("E058", "copy8", 58, 131, 64, 59, 0),
        ("E059", "copy8", 59, 129, 64, 59, 0),
        ("T298", "copy16", 298, 26, 96, 59, 0),
        ("T299", "copy16", 299, 26, 96, 59, 0),
        ("U300", "copy16", 300, 26, 96, 81, 0),
        ("T300", "copy16", 300, 26, 96, 59, 0),
        ("U320", "copy16", 320, 24, 96, 81, 0),
        ("T320", "copy16", 320, 24, 96, 59, 0),
        ("S299", "copy16", 299, 19, 96, 59, 1),
        ("V300", "copy16", 300, 19, 96, 81, 1),
        ("S300", "copy16", 300, 19, 96, 59, 1),
    ),
}


def _row(tag):
    for rows in BENCH_TABLES.values():
        for row in rows:
            if row[0] == tag:
                return row
    raise KeyError(tag)


_KIND_PRICE = {
    "copy8": lambda e, L: e._cost_copy_chunk(L)[1],
    "copy16": lambda e, L: e._cost_copy_chunk(L)[1],
    "run8": lambda e, L: e._cost_run_chunk(L)[1],
    "run16": lambda e, L: e._cost_run_chunk(L)[1],
}


def row_predicted(enc, tag):
    """Flat-model T/op for one bench row at its own COPY select value
    (thr 0 = the shipping copy_dma_min). Gapped rows are priced flat on
    purpose: measured minus this is the gapped surcharge."""
    _tag, kind, L, _o, _r, thr, _geo = _row(tag)
    tc = enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"]
    try:
        if thr:
            tc["copy_dma_min"] = thr
        return _KIND_PRICE[kind](enc, L)
    finally:
        tc["copy_dma_min"] = saved


def row_path(tag):
    """"dma" when L >= the row's own select value (thr, or the shipping
    copy_dma_min when thr is 0), else "ldi". COPY8 rows only."""
    _tag, kind, L, _o, _r, thr, _geo = _row(tag)
    if kind != "copy8":
        raise ValueError(f"{tag}: row_path only applies to copy8 rows")
    if thr:
        sel = thr
    else:
        import nxv2enc   # no copy8 row ships thr=0 today; kept for the interface
        sel = nxv2enc.TMODEL_COEFFS["copy_dma_min"]
    return "dma" if L >= sel else "ldi"


def t_per_op(o, r, f, d):
    """Measured T per op for one bench row."""
    return (f * LINES_PER_FRAME + d) * T_PER_LINE / float(r * o)


def priced(enc, sitting="current"):
    """{tag: (measured T/op, modeled T/op)} over the scored tags."""
    rows = ROWS[sitting]
    return {tag: (t_per_op(*rows[tag]), price(enc))
            for tag, price in PRICERS.items() if tag in rows}
