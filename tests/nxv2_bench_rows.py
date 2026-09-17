#!/usr/bin/env python3
"""tests/nxv2_bench_rows.py - silicon decode-bench rows as test data.

Rows come from the DEBUG NXBEN verbs (NXBO/NXBC/NXBK/NXBX/NXBG/NXBL/NXBT)
on real hardware, VGA-0 timing, core 3.02.04. A row is (ops per rep, reps,
frame wraps, raster-line delta) exactly as the bench prints it; the
bench's own conversion is T = (F * 311 + D) * 1824 at 28 MHz. PRE_FIX is
the player before the decode-loop change, kept as history; CURRENT is the
player these coefficients describe, read 2026-09-15.

BENCH_TABLES holds the standalone bench modes 2-12 (NXBO/NXBC/NXBK/NXBX/
NXBG/NXBL/NXBT/NXBE/NXBH/NXBF/NXBV) exactly as src/video.asm's NXB_PAGE
tables define them: each row carries its own explicit kernel-select value
(thr) for its kind, so the bench measures a fixed select value directly
instead of depending on whatever NXV2_COPY_DMA_MIN or NXV2_RUN_DMA_MIN
currently ships. SESSION_TABLES holds the session modes that ride a
staged clip (DS1/REAL/SYN/SYS, verbs NXBD/NXBR/NXBQ/NXBY) the same way.
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

# Sitting 4, 2026-09-16: NXBO, NXBK, first NXBC, NXBX and run 1 of NXBG/
# NXBL/NXBT. O and R are the table values (LFDS read O=7, a slip); T298
# keeps the dearer of its two readings (run 1, 8 lines over run 2).
SITTING4 = {
    "SK00": (255, 64, 4, 26),
    "S160": (255, 64, 6, 21),
    "RU01": (255, 32, 5, 158),
    "RU17": (255, 32, 9, 55),
    "CP01": (255, 32, 4, 215),
    "CP17": (255, 32, 10, -233),
    "R161": (255, 32, 12, 77),
    "C161": (255, 32, 12, -93),
    "F063": (125, 64, 19, 61),
    "F070": (112, 64, 19, -85),
    "F071": (111, 64, 19, -27),
    "F256": (30, 96, 16, 22),
    "K256": (30, 96, 17, -210),
    "C001": (255, 64, 10, -194),
    "C004": (255, 64, 11, 6),
    "C008": (255, 48, 10, -30),
    "C016": (255, 48, 13, 57),
    "C038": (197, 48, 18, -123),
    "C080": (96, 64, 20, 127),
    "C081": (95, 64, 17, -18),
    "C103": (75, 64, 15, -211),
    "C256": (30, 96, 16, 102),
    "L048": (157, 64, 22, 28),
    "D048": (157, 64, 25, 6),
    "L056": (136, 64, 22, -100),
    "D056": (136, 64, 23, -218),
    "L060": (127, 64, 21, 106),
    "D060": (127, 64, 21, 35),
    "L064": (119, 64, 21, 6),
    "D064": (119, 64, 20, 18),
    "L072": (106, 64, 21, -91),
    "D072": (106, 64, 19, -201),
    "L080": (96, 64, 20, 127),
    "D080": (96, 64, 17, 20),
    "D081": (95, 64, 17, -19),
    "GL48": (124, 64, 19, -177),
    "GD48": (124, 64, 20, 6),
    "GL56": (106, 64, 18, 0),
    "GD56": (106, 64, 21, -22),
    "GL60": (99, 64, 18, -84),
    "GD60": (99, 64, 20, -28),
    "GL64": (93, 64, 18, 198),
    "GD64": (93, 64, 16, -36),
    "GL72": (82, 64, 18, -166),
    "GD72": (82, 64, 17, 149),
    "GL80": (74, 64, 18, -109),
    "GD80": (74, 64, 17, 106),
    "GD81": (73, 64, 19, -271),
    "GC03": (57, 64, 15, 219),
    "GK56": (23, 96, 15, -62),
    "GF71": (83, 64, 18, 52),
    "GF56": (23, 96, 15, -259),
    "LF1K": (7, 64, 8, -16),
    "LF4K": (1, 64, 4, 24),
    "LF7K": (1, 64, 8, -103),
    "LFDS": (1, 64, 8, -59),
    "LG1K": (5, 64, 6, 160),
    "LG4K": (1, 64, 5, -127),
    "LGDS": (1, 64, 5, -123),
    "E058": (131, 64, 22, -172),
    "E059": (129, 64, 21, 116),
    "T298": (26, 96, 18, -38),
    "T299": (26, 96, 15, 151),
    "U300": (26, 96, 18, 5),
    "T300": (26, 96, 15, 158),
    "U320": (24, 96, 18, 74),
    "T320": (24, 96, 15, -84),
    "S299": (19, 96, 14, -206),
    "V300": (19, 96, 13, 218),
    "S300": (19, 96, 14, -231),
}

# Sitting 5: {run key: {tag: (O, R, F, D)}} from fit_gap_bench's parsed logs,
# empty until the sitting. Keyed by run, so not in ROWS.
SITTING5 = {}

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


# The geometry byte (nxb_geo_setup): bit 0 gapped; bits 3:2 gapped height
# code (3 faults the row as NXB GEO); bits 5:4 dest start code; bits 7:6
# and bit 1 zero. A gapped row may not use dest code 3 (E must be 0).
GEO_GAPPED = 0x01
GEO_HEIGHTS = (192, 144, 72)
GEO_DESTS = (0x4000, 0x5000, 0x5F00, 0x5F80)
GEO_RESERVED = 0xC2


def geo_fields(geo):
    """-> (gapped, height code, dest code) of a geometry byte."""
    return bool(geo & GEO_GAPPED), (geo >> 2) & 3, (geo >> 4) & 3


# BENCH_TABLES: {mode: ((tag, kind, L, O, R, thr, geo), ...)} for the
# standalone bench modes 2-12, in row order, the fields of the 12-byte row
# (ds 4 tag, db opcode, dw count, db ops, dw reps, db thr, db geo). kind is
# "skip8"/"skip16"/"run8"/"run16"/"copy8"/"copy16" (VOP_*), or "cal" for the
# special CALL row (opcode NXB_OPC_CAL, only R used). thr 0 = the shipping
# select value for the row's kind (RUN or COPY); SKIP rows carry 0.
CAL_KIND = "cal"

# Rows that print more than their own tag, in print order. CALL prints
# CALL (O = NR $11, F = the long clock) then CALR (O = NR $64, F = the
# body's own wrap count); the two F and D fields must match.
PRINTED = {"CALL": ("CALL", "CALR")}

BENCH_TABLES = {
    2: (   # NXBO - nxbTabOpd: op dispatch envelope
        ("SK00", "skip8", 0, 255, 64, 0, 0),
        ("S160", "skip16", 0, 255, 64, 0, 0),
        ("RU01", "run8", 1, 255, 32, 0, 0),
        ("RU17", "run8", 17, 255, 32, 0, 0),
        ("CP01", "copy8", 1, 255, 32, 0, 0),
        ("CP17", "copy8", 17, 255, 32, 0, 0),
        ("R161", "run16", 1, 255, 32, 0, 0),
        ("C161", "copy16", 1, 255, 32, 0, 0),
    ),
    3: (   # NXBC - nxbTabCpy: COPY kernel size ladder
        ("C001", "copy8", 1, 255, 64, 0, 0),
        ("C004", "copy8", 4, 255, 64, 0, 0),
        ("C008", "copy8", 8, 255, 48, 0, 0),
        ("C016", "copy8", 16, 255, 48, 0, 0),
        ("C038", "copy8", 38, 197, 48, 0, 0),
        ("C080", "copy8", 80, 96, 64, 0, 0),
        ("C081", "copy8", 81, 95, 64, 0, 0),
        ("C103", "copy8", 103, 75, 64, 0, 0),
        ("C256", "copy16", 256, 30, 96, 0, 0),
    ),
    4: (   # NXBK - nxbTabKrn: fill crossover + DMA DI window
        ("F063", "run8", 63, 125, 64, 0, 0),
        ("F070", "run8", 70, 112, 64, 0, 0),
        ("F071", "run8", 71, 111, 64, 0, 0),
        ("F256", "run16", 256, 30, 96, 0, 0),
        ("K256", "copy16", 256, 30, 96, 0, 0),
    ),
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
        ("LFDS", "copy16", 7680, 1, 64, 81, 0x10),
        ("LG1K", "copy16", 1000, 5, 64, 81, 1),
        ("LG4K", "copy16", 4000, 1, 64, 81, 1),
        ("LGDS", "copy16", 4000, 1, 64, 81, 0x11),
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
    9: (   # NXBE - nxbTabTail: CAL row, DMA chunk tails, 16-bit entries
        ("CALL", CAL_KIND, 0, 0, 16, 0, 0),
        ("C240", "copy8", 240, 32, 64, 0, 0),
        ("C250", "copy8", 250, 31, 64, 0, 0),
        ("Q240", "copy16", 240, 32, 64, 0, 0),
        ("R240", "run8", 240, 33, 64, 0, 0),
        ("R250", "run8", 250, 31, 64, 0, 0),
        ("W240", "run16", 240, 33, 64, 0, 0),
        ("P071", "run8", 71, 111, 64, 0, 0),
        ("P200", "run8", 200, 39, 64, 0, 0),
    ),
    10: (  # NXBH - nxbTabH144: COPY path pairs, gapped at height 144
        ("HL56", "copy8", 56, 79, 64, 255, 0x05),
        ("HD56", "copy8", 56, 79, 64, 1, 0x05),
        ("HL60", "copy8", 60, 74, 64, 255, 0x05),
        ("HD60", "copy8", 60, 74, 64, 1, 0x05),
        ("HL64", "copy8", 64, 69, 64, 255, 0x05),
        ("HD64", "copy8", 64, 69, 64, 1, 0x05),
        ("HL68", "copy8", 68, 65, 64, 255, 0x05),
        ("HD68", "copy8", 68, 65, 64, 1, 0x05),
        ("HL76", "copy8", 76, 58, 64, 255, 0x05),
        ("HD76", "copy8", 76, 58, 64, 1, 0x05),
        ("HL80", "copy8", 80, 55, 64, 255, 0x05),
        ("HD80", "copy8", 80, 55, 64, 1, 0x05),
        ("HL88", "copy8", 88, 50, 64, 255, 0x05),
        ("HD88", "copy8", 88, 50, 64, 1, 0x05),
        ("HL96", "copy8", 96, 46, 64, 255, 0x05),
        ("HD96", "copy8", 96, 46, 64, 1, 0x05),
        ("HC03", "copy8", 103, 43, 64, 0, 0x05),
        ("HK56", "copy16", 256, 17, 96, 0, 0x05),
    ),
    11: (  # NXBF - nxbTabFill: RUN path pairs (C thr 241 CPU, D thr 1 DMA)
        ("FC56", "run8", 56, 141, 64, 241, 0),
        ("FD56", "run8", 56, 141, 64, 1, 0),
        ("FC60", "run8", 60, 132, 64, 241, 0),
        ("FD60", "run8", 60, 132, 64, 1, 0),
        ("FC64", "run8", 64, 124, 64, 241, 0),
        ("FD64", "run8", 64, 124, 64, 1, 0),
        ("FC68", "run8", 68, 116, 64, 241, 0),
        ("FD68", "run8", 68, 116, 64, 1, 0),
        ("FC72", "run8", 72, 110, 64, 241, 0),
        ("FD72", "run8", 72, 110, 64, 1, 0),
        ("FC76", "run8", 76, 104, 64, 241, 0),
        ("FD76", "run8", 76, 104, 64, 1, 0),
        ("VC60", "run8", 60, 99, 64, 241, 1),
        ("VD60", "run8", 60, 99, 64, 1, 1),
        ("VC68", "run8", 68, 87, 64, 241, 1),
        ("VD68", "run8", 68, 87, 64, 1, 1),
        ("VC76", "run8", 76, 78, 64, 241, 1),
        ("VD76", "run8", 76, 78, 64, 1, 1),
    ),
    12: (  # NXBV - nxbTabEvt: edge bails, SKIP passes, a dest seam, columns
        ("EC16", "copy8", 16, 15, 64, 0, 0x20),
        ("NC16", "copy8", 16, 15, 64, 0, 0),
        ("ER16", "run8", 16, 15, 64, 0, 0x20),
        ("NR16", "run8", 16, 15, 64, 0, 0),
        ("ES16", "skip8", 16, 15, 64, 0, 0x20),
        ("NS16", "skip8", 16, 15, 64, 0, 0),
        ("S256", "skip16", 256, 31, 64, 0, 0),
        ("S2D0", "skip16", 256, 1, 1024, 0, 0),
        ("SDS1", "skip16", 256, 1, 1024, 0, 0x30),
        ("JC72", "copy16", 720, 3, 128, 81, 0x09),
        ("JD72", "copy16", 720, 3, 128, 59, 0x09),
        ("JR72", "run16", 720, 3, 128, 0, 0x09),
        ("JS72", "skip16", 720, 3, 128, 0, 0x09),
        ("JK72", "skip8", 200, 11, 128, 0, 0x09),
        ("JN72", "skip8", 60, 37, 128, 0, 0x09),
        ("GS3C", "skip16", 576, 10, 64, 0, 0x01),
    ),
}


# SESSION_TABLES: {name: (row, ...)} for the session bench modes (flags+248),
# in row order, as the NXB_PAGE tables define them. kind is one of
# SESSION_KINDS (NXB_K_* order) and sets the row's layout and length:
#   (tag, kind, param, reps, thr, strm): 10 bytes (ds 4 tag, db kind, dw param,
#     dw reps, db thr); strm marks NXB_K_STRM, a row only a streaming session
#     runs;
#   (tag, kind, reps, frame, preset, site1, site2) for the SESSION_SYNTH kinds:
#     25 bytes (ds 4 tag, db kind, dw reps, d24 frame offset, db span preset,
#     then per site d24 offset, db length 0-3, ds 3 bytes); a site is
#     (offset, bytes).
# ARM, DISARM and DSKIP rows print nothing.
SESSION_KINDS = ("id", "ring", "remn", "scan", "sweep", "frame", "aud", "pace",
                 "loop", "arm", "disarm", "prod", "dsweep", "dsblk", "dskip",
                 "synth", "synth_nocall")
SESSION_SILENT = ("arm", "disarm", "dskip")
SESSION_REPS = ("frame", "aud", "pace", "prod", "dsblk")   # reps >= 1
SESSION_DECODE = ("scan", "sweep", "frame", "loop", "dsweep")  # thr = COPY select
SESSION_SYNTH = ("synth", "synth_nocall")
SESSION_DIRECT = ("dsweep", "dsblk", "dskip")        # direct-serve only
SESSION_ROW_LEN = 10
SESSION_SYNTH_LEN = 25
SESSION_MODES = {"DS1": 1, "REAL": 2, "SYN": 3, "SYS": 4}   # flags+248
# The deliveries each mode runs on (nxbSessDir's mask); anything else prints
# NXB SESSION.
SESSION_DELIVERY = {"DS1": ("direct",), "REAL": ("resident", "streaming"),
                    "SYN": ("resident",), "SYS": ("streaming",)}
NXB_DS_REPS = 128                                    # blocks per DT row
NOSITE = (0, ())

SESSION_TABLES = {
    "DS1": (    # NXBD - nxbSesDs1: frame 0 untimed, sweeps of frames 1-32, transport
        ("IDEN", "id", 0, 0, 0, False),
        ("DSKP", "dskip", 0, 0, 0, False),
        ("DSWP", "dsweep", 16, 0, 65, False),
        ("ARM1", "arm", 0, 0, 0, False),
        ("ADSW", "dsweep", 16, 0, 65, False),
        ("DSRM", "disarm", 0, 0, 0, False),
        ("DTI0", "dsblk", 0, NXB_DS_REPS, 0, False),
        ("DTB0", "dsblk", 1, NXB_DS_REPS, 0, False),
        ("DTC0", "dsblk", 2, NXB_DS_REPS, 0, False),
        ("DTD0", "dsblk", 3, NXB_DS_REPS, 0, False),
        ("ARM2", "arm", 0, 0, 0, False),
        ("ADTI", "dsblk", 0, NXB_DS_REPS, 0, False),
        ("ADTC", "dsblk", 2, NXB_DS_REPS, 0, False),
    ),
    "SYN": (    # NXBQ - nxbSesSyn: synthetic frames in a resident clip
        ("IDEN", "id", 0, 0, 0, False),
        ("RING", "ring", 0, 0, 0, False),
        ("NUL0", "synth_nocall", 1024, 24, 0, NOSITE, NOSITE),
        ("FE00", "synth", 1024, 24, 0, NOSITE, NOSITE),
        ("FE01", "synth", 1024, 24, 1, NOSITE, NOSITE),
        ("KS01", "synth", 1024, 24, 0, (24, (0x28, 0x20)), NOSITE),
        ("KS02", "synth", 1024, 24, 0, (24, (0x28, 0x00)), NOSITE),
        ("KF01", "synth", 1024, 24, 1, (24, (0x20,)), NOSITE),
        ("PAL1", "synth", 256, 24, 0, (24, (0x18,)), (537, (0x00,))),
        ("PAL2", "synth", 256, 7900, 0, (7900, (0x18,)), (8413, (0x00,))),
        ("SE00", "synth", 1024, 7000, 0, (7000, (0x10, 0x01)), (7003, (0x00,))),
        ("SE01", "synth", 1024, 8000, 0, (8000, (0x10, 0x01)), (8003, (0x00,))),
        ("SE02", "synth", 1024, 8190, 0, (8190, (0x10, 0x01)), (8193, (0x00,))),
        ("C4K0", "synth", 1024, 512, 0, (512, (0x14, 0x00, 0x10)), (4611, (0x00,))),
        ("C4KP", "synth", 1024, 6144, 0, (6144, (0x14, 0x00, 0x10)), (10243, (0x00,))),
        ("C4KB", "synth", 1024, 14336, 0, (14336, (0x14, 0x00, 0x10)), (18435, (0x00,))),
        ("C4KS", "synth", 1024, 512, 1, (512, (0x14, 0x00, 0x10)), (4611, (0x00,))),
        ("C4KD", "synth", 1024, 512, 2, (512, (0x14, 0x00, 0x10)), (4611, (0x00,))),
        ("K24K", "synth", 64, 512, 0, (512, (0x14, 0xC0, 0x5D)), (24515, (0x00,))),
        ("K43K", "synth", 64, 512, 0, (512, (0x14, 0x00, 0xA8)), (43523, (0x00,))),
        ("ARM1", "arm", 0, 0, 0, False),
        ("AK43", "synth", 64, 512, 0, (512, (0x14, 0x00, 0xA8)), (43523, (0x00,))),
        ("AFE0", "synth", 1024, 24, 0, NOSITE, NOSITE),
        ("AC4K", "synth", 1024, 512, 0, (512, (0x14, 0x00, 0x10)), (4611, (0x00,))),
    ),
    "SYS": (    # NXBY - nxbSesSys: synthetic frames in a streaming clip
        ("IDEN", "id", 0, 0, 0, False),
        ("RING", "ring", 0, 0, 0, False),
        ("NUL0", "synth_nocall", 1024, 512, 0, NOSITE, NOSITE),
        ("FE00", "synth", 1024, 0, 0, (0, (0x00,)), NOSITE),
        ("FE01", "synth", 1024, 0, 1, (0, (0x00,)), NOSITE),
        ("KS01", "synth", 1024, 0, 0, (0, (0x28, 0x20)), NOSITE),
        ("KS02", "synth", 1024, 0, 0, (0, (0x28, 0x00)), NOSITE),
        ("KF01", "synth", 1024, 0, 1, (0, (0x20,)), NOSITE),
        ("C4K0", "synth", 1024, 512, 0, (512, (0x14, 0x00, 0x10)), (4611, (0x00,))),
        ("C4KP", "synth", 1024, 6144, 0, (6144, (0x14, 0x00, 0x10)), (10243, (0x00,))),
        ("C4KB", "synth", 1024, 14336, 0, (14336, (0x14, 0x00, 0x10)), (18435, (0x00,))),
        ("K24K", "synth", 64, 512, 0, (512, (0x14, 0xC0, 0x5D)), (24515, (0x00,))),
        ("ARM1", "arm", 0, 0, 0, False),
        ("AK24", "synth", 64, 512, 0, (512, (0x14, 0xC0, 0x5D)), (24515, (0x00,))),
        ("AFE0", "synth", 1024, 0, 0, (0, (0x00,)), NOSITE),
    ),
    "REAL": (   # NXBR - nxbSesReal: real frames, audio, loop, producer, armed
        ("IDEN", "id", 0, 0, 0, False),
        ("RING", "ring", 0, 0, 0, False),
        ("SCAN", "scan", 0, 0, 65, False),
        ("W055", "sweep", 0, 0, 55, False),
        ("W060", "sweep", 0, 0, 60, False),
        ("W065", "sweep", 0, 0, 65, False),
        ("W070", "sweep", 0, 0, 70, False),
        ("W075", "sweep", 0, 0, 75, False),
        ("W081", "sweep", 0, 0, 81, False),
        ("FA65", "frame", 0, 8, 65, False),
        ("FB65", "frame", 1, 8, 65, False),
        ("FC65", "frame", 2, 8, 65, False),
        ("WL16", "sweep", 16, 0, 65, False),
        ("AUD1", "aud", 0, 64, 0, False),
        ("PACE", "pace", 0, 1024, 0, False),
        ("LOOP", "loop", 16, 0, 65, False),
        ("ARM1", "arm", 0, 0, 0, False),
        ("A065", "sweep", 0, 0, 65, False),
        ("XA65", "frame", 0, 8, 65, False),
        ("XB65", "frame", 1, 8, 65, False),
        ("XC65", "frame", 2, 8, 65, False),
        ("AW16", "sweep", 16, 0, 65, False),
        ("AAUD", "aud", 0, 64, 0, False),
        ("ALOP", "loop", 16, 0, 65, False),
        ("DSRM", "disarm", 0, 0, 0, True),
        ("REMN", "remn", 0, 0, 0, True),
        ("PROD", "prod", 0, 128, 0, True),
        ("ARM2", "arm", 0, 0, 0, True),
        ("APRD", "prod", 0, 128, 0, True),
    ),
}

# (unarmed, armed) twins per session table: the same row, run before and
# after ARM. Every other printed row runs unarmed.
SESSION_ARMED_PAIRS = {
    "DS1": (("DSWP", "ADSW"), ("DTI0", "ADTI"), ("DTC0", "ADTC")),
    "REAL": (("W065", "A065"), ("FA65", "XA65"), ("FB65", "XB65"),
             ("FC65", "XC65"), ("WL16", "AW16"), ("AUD1", "AAUD"),
             ("LOOP", "ALOP"), ("PROD", "APRD")),
    "SYN": (("K43K", "AK43"), ("FE00", "AFE0"), ("C4K0", "AC4K")),
    "SYS": (("K24K", "AK24"), ("FE00", "AFE0")),
}


def session_strm(row):
    """True for a 10-byte row marked NXB_K_STRM; SYNTH rows carry no mark."""
    return row[1] not in SESSION_SYNTH and bool(row[5])


def session_row_bytes(row):
    """One session row as its NXB_PAGE table assembles it."""
    tag, kind = row[0], row[1]
    out = bytearray(tag.encode("ascii"))
    code = SESSION_KINDS.index(kind)
    if kind in SESSION_SYNTH:
        _tag, _kind, reps, frame, preset, *sites = row
        out += bytes([code]) + reps.to_bytes(2, "little")
        out += frame.to_bytes(3, "little") + bytes([preset])
        for offset, data in sites:
            out += offset.to_bytes(3, "little") + bytes([len(data)])
            out += bytes(data) + bytes(3 - len(data))
    else:
        _tag, _kind, param, reps, thr, strm = row
        out += bytes([code | (0x80 if strm else 0)])
        out += param.to_bytes(2, "little") + reps.to_bytes(2, "little") + bytes([thr])
    return bytes(out)


def session_table_bytes(name):
    """The table staged into nxbTabBuf: its rows, then the terminator."""
    return b"".join(session_row_bytes(r) for r in SESSION_TABLES[name]) + b"\0"


def direct_frames(name):
    """(frames read off the wire, the frame ranges DSWEEP rows time, blocks the
    DSBLK rows read) for a direct table, in row order."""
    pos, swept, blocks = 0, [], 0
    for row in SESSION_TABLES[name]:
        if row[1] == "dskip":
            pos += 1
        elif row[1] == "dsweep":
            swept.append(range(pos, pos + row[2]))
            pos += row[2]
        elif row[1] == "dsblk":
            blocks += row[3]
    return pos, swept, blocks


def session_rows(name, delivery):
    """The rows one session runs, in order. delivery is "resident",
    "streaming" or "direct" (True/False read as streaming/resident): only a
    streaming session runs strm rows."""
    streaming = delivery is True or delivery == "streaming"
    return tuple(r for r in SESSION_TABLES[name] if streaming or not session_strm(r))


def session_printed(name, delivery):
    """The tags one session prints, in print order."""
    return tuple(r[0] for r in session_rows(name, delivery)
                 if r[1] not in SESSION_SILENT)


def session_armed(name, delivery):
    """{tag: True when the row runs after ARM with no DISARM since}."""
    armed, out = False, {}
    for tag, kind, *_ in session_rows(name, delivery):
        if kind == "arm":
            armed = True
        elif kind == "disarm":
            armed = False
        out[tag] = armed
    return out


def printed_tags(mode):
    """The tags one standalone mode prints, in print order (CALL adds CALR)."""
    return tuple(t for row in BENCH_TABLES[mode] for t in PRINTED.get(row[0], (row[0],)))


def _row(tag):
    for rows in BENCH_TABLES.values():
        for row in rows:
            if row[0] == tag:
                return row
    raise KeyError(tag)


_KIND_PRICE = {
    "skip8": lambda e, L: e._cost_skip_chunk(L)[1],
    "skip16": lambda e, L: e._cost_skip_chunk(L)[1],
    "copy8": lambda e, L: e._cost_copy_chunk(L)[1],
    "copy16": lambda e, L: e._cost_copy_chunk(L)[1],
    "run8": lambda e, L: e._cost_run_chunk(L)[1],
    "run16": lambda e, L: e._cost_run_chunk(L)[1],
}


def row_predicted(enc, tag):
    """Flat-model T/op for one bench op row at its own select value: a RUN
    row's thr sets run_dma_min, a COPY row's copy_dma_min (thr 0 = the
    shipping value), as nxb_sel_row routes it. The model has no term for
    gapped columns, dest-edge bails, dest seams or SKIP body passes, and it
    picks the 8- or 16-bit envelope by L, not by the row's opcode: those
    terms are omitted here, so measured minus this is the missing term."""
    return row_price(enc, _row(tag))


def row_price(enc, row):
    """row_predicted for a (tag, kind, L, O, R, thr, geo) tuple; the
    select coefficient is restored on every exit. The CAL row has no
    price (KeyError)."""
    _tag, kind, L, _o, _r, thr, _geo = row
    price = _KIND_PRICE[kind]
    key = ("run_dma_min" if kind.startswith("run")
           else "copy_dma_min" if kind.startswith("copy") else None)
    if key is None:
        return price(enc, L)
    tc = enc.TMODEL_COEFFS
    saved = tc[key]
    try:
        if thr:
            tc[key] = thr
        return price(enc, L)
    finally:
        tc[key] = saved


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


# Row events (nxv2_path_sim). A standalone rep is nxb_build's stream at $C000
# (O ops, then FEND) painted from the geometry dest into one pool bank.
NXB_DST_PAGES = 2                  # nxb_ops_setup: vidDstEnd = page + 2
NXB_RUN_REF = 71                   # video.asm NXB_RUN_REF, session decode rows
# (COPY, RUN) selects assembled into the sitting-5 image (NXV2_COPY_DMA_MIN,
# NXV2_RUN_DMA_MIN): thr 0 rows and SYNTH rows ran at these, whatever the
# model's copy_dma_min/run_dma_min later become
SITTING_SELECTS = (81, 71)
SPAN_PRESET_DE = {0: 0x4000, 1: 0x4000, 2: 0x5800}   # nxb_kind_synth presets


def row_surface(tag):
    """A standalone row's own (width, height, gapped). Flat rows depend only
    on the dest window, so any flat surface serves."""
    _tag, kind, _L, _o, _r, _thr, geo = _row(tag)
    gapped, hcode, _dcode = geo_fields(geo)
    return (320, GEO_HEIGHTS[hcode], True) if gapped else (256, 192, False)


def row_selects(tag, ship=SITTING_SELECTS):
    """(COPY, RUN) selects one standalone row runs at (nxb_sel_row): its thr
    goes to its kind's select, 0 and the other select take ship."""
    _tag, kind, _L, _o, _r, thr, _geo = _row(tag)
    copy, run = ship
    if kind.startswith("copy") and thr:
        copy = thr
    elif kind.startswith("run") and thr:
        run = thr
    return copy, run


def session_row_selects(name, tag, ship=SITTING_SELECTS):
    """(COPY, RUN) selects one session row decodes at: SYNTH rows at ship,
    SCAN/SWEEP/FRAME/LOOP/DSWEEP rows at their COPY thr and NXB_RUN_REF. thr
    0 leaves nxb_srow_go's selects as they stand, the session-entry ship
    values (table rules keep decode rows at thr >= 1). None for rows that
    decode nothing."""
    for row in SESSION_TABLES[name]:
        if row[0] != tag:
            continue
        if row[1] == "synth" or (row[1] in SESSION_DECODE and not row[4]):
            return ship
        if row[1] in SESSION_DECODE:
            return row[4], NXB_RUN_REF
        return None
    raise KeyError(f"{name} {tag}")


def synth_ops(frame, sites):
    """A SYNTH frame's op list, read from its written site bytes (COPY and PAL
    bodies skipped). No writes: the frame sits on the header's reserved zero
    bytes and reads one FEND. ValueError when an op byte is not written."""
    import nxv2_path_sim as sim
    written = {}
    for offset, data in sites:
        for i, b in enumerate(data):
            written[offset + i] = b
    if not written:
        if sim.nxv2enc.HDR_RESERVED_START <= frame < sim.nxv2enc.HEADER_SIZE:
            return [(sim.OP_FEND, 0)]
        raise ValueError(f"no writes, and offset {frame} is not a reserved header zero")
    ops, pos = [], frame
    for _ in range(64):
        if pos not in written:
            raise ValueError(f"op byte at {pos} is not written")
        op = written[pos]
        if op in sim.OPERANDS:
            k = sim.OPERANDS[op]
            if any(pos + 1 + i not in written for i in range(k)):
                raise ValueError(f"operand of op ${op:02X} at {pos} is not written")
            width = 1 if op in sim.COUNT8 else 2
            n = int.from_bytes(bytes(written[pos + 1 + i] for i in range(width)), "little")
        elif op == sim.OP_PAL:
            n = sim.PAL_BYTES
        elif op in (sim.OP_FEND, sim.OP_KFLIP, sim.OP_KSTART):
            n = 0
        else:
            raise ValueError(f"opcode ${op:02X} at {pos}")
        ops.append((op, n))
        if op in (sim.OP_FEND, sim.OP_KFLIP):
            return ops
        pos += sim.op_bytes(op, n)
    raise ValueError("no terminal within 64 ops")


def row_events(tag, surface=None, table=None, ship=SITTING_SELECTS):
    """nxv2_path_sim Events for ONE REP of a standalone or SYNTH row.

    Standalone: O ops then FEND at source offset 0, dest from the geometry
    byte, two dest pages, selects from row_selects (thr 0 = ship). surface
    None = row_surface(tag); a given surface must agree. SYNTH (SYN/SYS):
    surface is the session's (width, height, gapped); the frame offset, span
    preset and site ops at ship. table names SYN or SYS when a tag's rows
    differ between them. NUL0 decodes nothing."""
    import nxv2_path_sim as sim
    try:
        row = _row(tag)
    except KeyError:
        row = None
    if row is not None:
        _tag, kind, L, o, _r, _thr, geo = row
        if kind == CAL_KIND:
            raise ValueError(f"{tag}: the CAL row runs no ops")
        own = row_surface(tag)
        if surface is not None and (bool(surface[2]) != own[2]
                                    or (own[2] and surface[1] != own[1])):
            raise ValueError(f"{tag}: surface {surface} is not the row's own {own}")
        _g, _h, dcode = geo_fields(geo)
        copy, run = row_selects(tag, ship)
        ops = [(sim.OPCODE_BY_KIND[kind], L)] * o + [(sim.OP_FEND, 0)]
        return sim.events(ops, own, 0, dst=(0, GEO_DESTS[dcode]),
                          dst_pages=NXB_DST_PAGES, copy_thr=copy, run_thr=run)
    names = [table] if table else [n for n in ("SYN", "SYS")
                                   if any(r[0] == tag for r in SESSION_TABLES[n])]
    if not names:
        raise KeyError(tag)
    if surface is None:
        raise ValueError(f"{tag}: a SYNTH row needs the session surface")
    found = []
    for name in names:
        match = [r for r in SESSION_TABLES[name] if r[0] == tag]
        if not match or match[0][1] not in SESSION_SYNTH:
            raise KeyError(f"{name} {tag}: not a SYNTH row")
        _t, kind, _reps, frame, preset, *sites = match[0]
        if kind == "synth_nocall":
            found.append(sim.Events())
            continue
        found.append(sim.events(synth_ops(frame, sites), surface, frame,
                                dst=(0, SPAN_PRESET_DE[preset]), in_span=preset != 0,
                                copy_thr=ship[0], run_thr=ship[1]))
    if any(ev != found[0] for ev in found[1:]):
        raise ValueError(f"{tag}: SYN and SYS rows differ, name the table")
    return found[0]


def t_per_op(o, r, f, d):
    """Measured T per op for one bench row."""
    return (f * LINES_PER_FRAME + d) * T_PER_LINE / float(r * o)


def priced(enc, sitting="current"):
    """{tag: (measured T/op, modeled T/op)} over the scored tags."""
    rows = ROWS[sitting]
    return {tag: (t_per_op(*rows[tag]), price(enc))
            for tag, price in PRICERS.items() if tag in rows}
