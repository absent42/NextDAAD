#!/usr/bin/env python3
"""tests/fit_gap_bench.py - sitting-5 rules S0-S17 over the bench logs.

Parses NXBENCH-Q.TXT (every quiet-image run) and, with --anchor, NXBENCH-D.TXT
(the standard DEBUG image's NXBC), applies Rules S0-S17 in order and prints
every ruling as `Ruling: <value> - <arithmetic> - <cost if wrong>`. Writes
nothing. Exits 1 on any STOP condition, naming it.

Row times: T per op for a standalone row, (F x 311 + D) x 1824 / (R x O); T per
rep for a session row (O read as 1). Pricing: nxv2_path_sim events per row or
fixture frame, mapped to terms by COUNTER_TERMS (S4 prints the map).

Each rule is one function s<n>(sit, v) -> (new values, printed lines); S0
builds the Sitting from the parsed runs. A Stop names its rule. Values stay
exact through the rules; each ruling prints its coefficient rounded up to
0.1 T, so rounding never moves another term's fit.

Usage: python tests/fit_gap_bench.py NXBENCH-Q.TXT (--anchor NXBENCH-D.TXT |
       --no-anchor) [--launch-status [D:]hhhh=OK ...]
--launch-status is the owner's note for each launch's last run, whose LOG
status the file cannot hold, keyed by its #NXB stamp (D: for the anchor log).
"""
import argparse
import contextlib
import io
import math
import re
import sys
from collections import Counter
from dataclasses import dataclass, field, fields
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "authoring-kit" / "lib"))
sys.path.insert(0, str(HERE))

import numpy as np  # noqa: E402

import nxv2dec  # noqa: E402
import nxv2enc as enc  # noqa: E402
import nxv2_bench_log as blog  # noqa: E402
import nxv2_bench_rows as bench  # noqa: E402
import nxv2_frame_model as fm  # noqa: E402
import nxv2_path_sim as sim  # noqa: E402
import fit_copy_threshold as fct  # noqa: E402
import fit_tmodel  # noqa: E402

LPF = bench.LINES_PER_FRAME
TPL = bench.T_PER_LINE
CLOCK_KHZ = 28000.0                 # S17: 28 MHz is the slowest core 3.02.04 clock
FIELD_HZ = 49.36                    # +3 timing: 311 lines x 1824 T per field
BAND_OP_T = 5.5                     # prices under: > max(5.5 T, one line) below an op row
BAND_SESS = 0.005                   # ... or > 0.5% below a session row
PARALLEL_T_PER_B = 0.01             # S6/S7: lines closer in slope than this do not cross
RESID_STOP = 0.03                   # S4: a residual above 3% of its row
S3_TYPE_AGREE_T = 30.0              # S3: KS01-KS02 against KF01-FE01
S7_LINE_AGREE_T = 5.5               # S7: F070/F071 against the NXBF lines
S15_RESID_STOP = 0.01               # S15: worst residual 1% of its frame
AUD_PAD_B = 1536                    # S10: the fixtures' padded audio bytes per frame
FETCH_SEL = 64                      # the model's LDI rate selector (fetch_long at L >= 64)
VID_RING_MAX = 80                   # src/nextdaad.inc: ring bank list capacity
BANK_B = 16384
POOL_CAP_BANKS = 78                 # S12: never above 78 banks
REMN_MIN_BLOCKS = 256               # S11

# Task 12 hand counts (quiet image, 28 MHz: +1 T per opcode fetch and per memory read).
H_PACE = 104                        # PACE rep-loop control
H_STUB = 144                        # nxb_lp_pace + nxb_lp_next per LOOP iteration
H_AUDREP = 591                      # AUD rep restore and loop control, both deliveries
H_SKIP = {"resident": 492, "streaming": 1174}   # sweep per-frame audio skip
H_SPIN = 161                        # per-block spin overhead around the producer

REPEAT_LINES = {"sweep": 2, "loop": 2}          # S0 repeat tolerance by row kind, else 1
UNTIMED_KINDS = ("id", "ring", "remn")
UNCOMPARED_KINDS = UNTIMED_KINDS + ("scan",)    # SCAN sums per-frame windows: informational

# Part B standalone modes and Part C sessions (table, clip).
STANDALONE = (3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12)
SESSIONS = (("REAL", 1), ("SYN", 1), ("REAL", 2), ("SYN", 2), ("REAL", 3), ("SYN", 3),
            ("REAL", 4), ("SYN", 4), ("REAL", 5), ("REAL", 7), ("SYS", 7), ("REAL", 8),
            ("REAL", 9), ("DS1", 10), ("DS1", 12), ("DS1", 13), ("DS1", 14))
S8_CLASSES = {"flat": (1, 2, 5, 7, 8), "gapped": (3, 4, 9)}
MODEL_CLIPS = (1, 2, 3, 4, 5, 6, 7, 8, 9)
SWEEP_GRID = (55, 60, 65, 70, 75, 81)
REAL_SEL = (65, bench.NXB_RUN_REF)  # FRAME and A065 rows ran COPY 65, RUN 71
S6_TIE_T = 1.0005
S6_SPLIT_MIN = 8
S6_SPLIT_SAVE = 0.002
S16_SHAPES = ((320, 256), (256, 192), (320, 192), (320, 144))

S1_TERMS = ("fetch_short", "fetch_long", "t_skip", "t_skip16", "t_op_run", "t_op_copy",
            "fill_cpu", "copy_dma_per_b", "fill_dma_per_b")
S4_TERMS = ("copy_dma_setup", "copy_dma_path_t", "copy_body_ldi_t", "fill_dma_setup",
            "fill_dma_path_t", "fill_body_cpu_t", "copy16_entry_t", "run16_entry_t",
            "t_skip_pass", "edge_skip_t", "edge_run_t", "edge_copy_t", "dst_seam_t",
            "col_hop_t", "src_parity_seam_t", "src_bank_seam_t", "src_edge_t", "src_slow_hdr_t")
S4_EXTENDED = ("gap_fast_t", "gap_bail_skip_t", "gap_bail_t", "slow_fetch_t", "slow_cmp_t",
               "srcedge_t", "dst_exact_t", "src_exact_t", "gap_chunk_t", "gap_chunk_hi_t",
               "cap_arm_t", "src_wrap_t", "fast_hop_skip_t", "fast_hop_run_t", "fast_hop_copy_t",
               "gap_skip_pass_t")
S4_MODES = (2, 3, 4, 5, 7, 12, 6, 10, 11)       # 6, 10, 11 carry the fast-hop and gapped terms
S4_NXBE = ("C240", "C250", "Q240", "R240", "R250", "W240")
S4_SYN = ("C4K0", "C4KP", "C4KB", "K24K", "K43K", "SE00", "SE01", "SE02", "C4KS", "C4KD")
S4_SPAN_ROWS = ("C4KS", "C4KD")                 # baseline FE01, the rest FE00
S4_COL_SCORED = ("JC72", "JD72", "JR72", "JS72")
S4_TAILS = ("T298", "T299", "T300", "T320")
SPLITTABLE = {"copy_body_ldi_t": "s2_ldi8", "fill_body_cpu_t": "s2_cpu8"}
FRAME_TERMS = ("frame_delta_t", "frame_middle_t", "frame_first_t", "frame_single_t",
               "frame_last_t")


class Stop(Exception):
    """A STOP condition: the rule, what fired, and the rule's lines so far."""

    def __init__(self, rule, lines, notes=None):
        self.rule = rule
        self.lines = [lines] if isinstance(lines, str) else list(lines)
        self.notes = list(notes or [])
        self.printed = []
        super().__init__(f"{rule} STOP: " + "; ".join(self.lines))


def ceil01(x):
    """Round up to 0.1 T (every coefficient)."""
    return math.ceil(round(x * 10.0, 6)) / 10.0


def ruling(value, arithmetic, cost):
    return f"Ruling: {value} - {arithmetic} - {cost}"


def row_lines(row):
    return row[2] * LPF + row[3]


def t_op(row):
    o, r, f, d = row
    return (f * LPF + d) * TPL / float(r * o)


def t_rep(row):
    _o, r, f, d = row
    return (f * LPF + d) * TPL / float(r)


def sigma_op(row):
    """T per op one raster line moves an op row."""
    return TPL / float(row[1] * row[0])


def sigma_rep(row):
    """T per rep one raster line moves a session row."""
    return TPL / float(row[1])


def op_band(row):
    """An op row prices under past max(5.5 T, its own one-line resolution)."""
    return max(BAND_OP_T, sigma_op(row))


def line_bounds(xs, sigmas):
    """(intercept, slope) worst-case moves of a least-squares line under +-1
    line on every point."""
    P = np.linalg.pinv(np.array([[1.0, float(x)] for x in xs]))
    sig = np.array(sigmas, dtype=float)
    return float(np.abs(P[0]) @ sig), float(np.abs(P[1]) @ sig)


def lsq(points):
    """(intercept, slope, worst |residual|) over [(x, y)]."""
    a, b, resid = fit_tmodel._lsq(points)
    return a, b, max(abs(r) for _x, r in resid)


# ---------------------------------------------------------------------------
# Hand counts, src/video.asm paths on the quiet image, 28 MHz (+1 T per opcode
# fetch and per memory read). A term takes its dearer path.
# ---------------------------------------------------------------------------
HAND = {
    "gap_fast_t": (28, "vg_op_run8/copy8 at E + n = h over the flat handler: ld a,e 5, add a,c 5, "
                       "jr c 9, cp h 9, jr c 9, jr z taken 14 = 51, less ld a,d 5, cp $5F 9, jr nc 9 = 23"),
    "gap_bail_skip_t": (50, "vg_op_skip8 over 2+ columns: ld c,(hl) 9, inc hl 7, ld a,e 5, add a,c 5, "
                            "jr c 9, cp 9, jr c 9, jr z 9, sub 9, cp 9, jr nc taken 14, ld b,0 9, jp 13 = 116, "
                            "less vf_op_skip8 .edge: ld a,d 5, cp 9, jr nc taken 14, ld c,(hl) 9, inc hl 7, "
                            "ld b,0 9, jp 13 = 66"),
    "gap_bail_t": (73, "vg_op_run8 over 2+ columns: ld c,(hl) 9, inc hl 7, ld a,c 5, cp 9, jr nc 9, "
                       "ld a,e 5, add a,c 5, jr c 9, cp 9, jr c 9, jr z 9, sub 9, cp 9, jr nc taken 14, "
                       "ld a,(hl) 9, inc hl 7, ld b,0 9, jp 13 = 155, less vf_op_run8 .slow at the edge: "
                       "ld c,(hl) 9, inc hl 7, ld a,d 5, cp 9, jr nc taken 14, ld a,(hl) 9, inc hl 7, "
                       "ld b,0 9, jp 13 = 82; vg_op_copy8 over 2+ columns: ld c,(hl) 9, inc hl 7, ld b,0 9, "
                       "ld a,h 5, cp $DF 9, jr nc 9, ld a,c 5, cp 9, jr nc 9, ld a,e 5, add a,c 5, jr c 9, "
                       "cp 9, jr c 9, jr z 9, sub 9, cp 9, jr nc taken 14, jp 13 = 162, less vf_op_copy8 edge: "
                       "ld c,(hl) 9, inc hl 7, ld b,0 9, ld a,h 5, cp 9, jr nc 9, ld a,d 5, cp 9, "
                       "jr nc taken 14, jp 13 = 89, also 73"),
    "slow_fetch_t": (99, "vid_slow_op .c16's second operand: call vid_fetch 20, jp vid_fetch_ram 13, "
                         "ld a,h 5, cp $E0 9, call nc 13, ld a,(hl) 9, inc hl 7, ret 13, ld b,a 5, "
                         "jr .cj taken 14 = 108, less .c8's ld b,0 9"),
    "slow_cmp_t": (18, "COPY16 at the 6th compare of vid_slow_op's chain, over SE02's COPY8 at the "
                       "5th: cp 9, jr z 9"),
    "srcedge_t": (38, "COPY8 .srcedge at L + n = 256: jr nc,.srcedge taken over not taken +5, ld a,l 5, "
                      "add a,c 5, jr nc 9, jr z,.sok taken 14"),
    "src_edge_t": (69, "opcode at $DF00-$DFFB from an NXVNEXT tail: jr nc taken over not taken +5, "
                       "jp vid_op_edge 13, cp $E0 9, jr c taken 14, ld a,l 5, cp $FC 9, "
                       "jr c,vid_next_fetch taken 14"),
    "src_wrap_t": (17, "vid_op_edge at H = $E0 over the $DFxx detour: jr c 9 (not 14) -5, call "
                       "vid_src_next 20 less the 7 the seam term carries +13, jr vid_next 14, "
                       "ld a,h 5, cp $DF 9, jr nc 9, less ld a,l 5, cp $FC 9, jr c taken 14"),
    "dst_exact_t": (164, "vid_chunk_dst_flat .exact over the cap arm, worst at a count of 242-255 entering "
                         "D = $5F with room 241-254: jr nc,.exact taken over not taken +5, call "
                         "vid_chunk_dst_nocap_flat 20, its clip path push hl 12, ld hl,$6000 13, or a 5, "
                         "sbc hl,de 17, sbc hl,bc 17, jr nc 9, add hl,bc 12, ld b,h 5, ld c,l 5, pop hl 13, "
                         "ret 13 = 121, then ld a,b 5, or a 5, jr nz 9, ld a,c 5, cp 9, ret c 6, ld bc,240 13, "
                         "ret 13 = 65, less the arm below 256 ld a,b 5, or a 5, jr nz 9, ld a,c 5, cp 9, "
                         "ret c taken 14 = 47 (a count >= 256: 234 - 73 = 161)"),
    "src_exact_t": (156, "vid_chunk_all into vid_chunk_src over ret c taken 14: ret c 6, jp 13, push hl 12, "
                         "push de 12, ex de,hl 5, ld hl,$E000 13, or a 5, sbc hl,de 17, sbc hl,bc 17, "
                         "jr nc 9, add hl,bc 12, ld b,h 5, ld c,l 5, pop de 13, pop hl 13, ret 13 = 170"),
    "gap_chunk_t": (47, "gapped RUN/COPY body chunk over flat, height 1-240: vid_dst_norm_gap ld a,height 9, "
                        "cp e 5, jr nz taken 14 = +28; vid_chunk_dst_gap room < count: ld a,height 9, sub e 5, "
                        "inc b 5, dec b 5, jr nz 9, cp c 5, jr nc 9, ld c,a 5, ld b,0 9, ld a,c 5, cp 9, "
                        "ret c 14 = 89, less vid_chunk_dst_flat: ld a,d 5, cp 9, jr nc 9, ld a,b 5, or a 5, "
                        "jr nz 9, ld a,c 5, cp 9, ret c 14 = 70, +19 (room >= count 80 - 70, count >= 256 "
                        "80 - 73)"),
    "gap_chunk_hi_t": (47, "height 241-255: the same instructions as gap_chunk_t; a room of 241-255 adds only "
                           "the cap arm, priced by cap_arm_t (count >= 256 98 = 80 + 18, room >= count "
                           "98 = 80 + 18, room < count 107 = 89 + 18), so +28 + 19"),
    "cap_arm_t": (18, "cap test falling through at C = 241-255 (vid_chunk_dst_flat 942-945, vid_chunk_dst_gap "
                      "973-975): ret c not taken 6 over taken 14 = -8, ld bc,240 13, ret 13"),
}

# ---------------------------------------------------------------------------
# Every Events counter maps to terms or is zero-cost. "gap:"/"strm:" apply on gapped or
# streamed surfaces, "gaplo:" on gapped heights up to 240, "@8"/"@16" name the width S2/S4
# may split, FETCH takes fetch_short or fetch_long by the op's length.
# ---------------------------------------------------------------------------
FETCH = "fetch"
COUNTER_TERMS = {
    "fast_skip8": ("t_skip", "gap:gap_fast_t"),
    "fast_run8": ("t_op_run", "gap:gap_fast_t"),
    "fast_copy8": ("t_op_copy", "gap:gap_fast_t"),
    "thr_run8": ("t_op_run", "fill_dma_path_t"),
    "thr_copy8": ("t_op_copy", "copy_dma_path_t"),
    "edge_skip8": ("edge_skip_t",),
    "edge_run8": ("edge_run_t",),
    "edge_copy8": ("edge_copy_t",),
    "gap_skip8": ("edge_skip_t", "gap_bail_skip_t"),
    "gap_run8": ("edge_run_t", "gap_bail_t"),
    "gap_copy8": ("edge_copy_t", "gap_bail_t"),
    "src_copy8": ("edge_copy_t",),
    "op_skip16": ("t_skip16",),
    "op_run16": ("t_op_run", "run16_entry_t"),
    "op_copy16": ("t_op_copy", "copy16_entry_t"),
    "slow_skip8": ("t_skip",),
    "slow_skip16": ("t_skip16", "slow_fetch_t"),
    "slow_run8": ("t_op_run", "slow_fetch_t"),
    "slow_run16": ("t_op_run", "run16_entry_t", "slow_fetch_t", "slow_fetch_t"),
    "slow_copy8": ("t_op_copy",),
    "slow_copy16": ("t_op_copy", "copy16_entry_t", "slow_fetch_t", "slow_cmp_t"),
    "fast_hop_skip8": ("fast_hop_skip_t",),
    "fast_hop_run8": ("fast_hop_run_t",),
    "fast_hop_copy8": ("fast_hop_copy_t",),
    "fast_hop0_run8": (),
    "fast_hop0_copy8": (),
    "fast_dst_seams": ("dst_seam_t",),
    "copy8_srcedge": ("srcedge_t",),
    "run_fast_b": ("fill_cpu",),
    "copy_fast_b": (FETCH,),
    "skip_passes": ("t_skip_pass",),
    "gap_skip_passes": ("gap_skip_pass_t",),
    "run_cpu_chunks8": ("fill_body_cpu_t@8", "gaplo:gap_chunk_t"),
    "run_cpu_chunks16": ("fill_body_cpu_t@16", "gaplo:gap_chunk_t"),
    "run_dma_chunks8": ("fill_dma_setup", "gaplo:gap_chunk_t"),
    "run_dma_chunks16": ("fill_dma_setup", "gaplo:gap_chunk_t"),
    "copy_ldi_chunks8": ("copy_body_ldi_t@8", "gaplo:gap_chunk_t"),
    "copy_ldi_chunks16": ("copy_body_ldi_t@16", "gaplo:gap_chunk_t"),
    "copy_dma_chunks8": ("copy_dma_setup", "gaplo:gap_chunk_t"),
    "copy_dma_chunks16": ("copy_dma_setup", "gaplo:gap_chunk_t"),
    "run_cpu_b": ("fill_cpu",),
    "run_dma_b": ("fill_dma_per_b",),
    "copy_ldi_b": (FETCH,),
    "copy_dma_b": ("copy_dma_per_b",),
    "dst_exact_chunks": ("dst_exact_t",),
    "cap_arm_chunks": ("cap_arm_t",),
    "gap_hi_chunks": ("gap_chunk_hi_t",),
    "copy_src_chunks": ("src_exact_t",),
    "col_hops": ("col_hop_t",),
    "dst_seams": ("dst_seam_t",),
    "src_parity_seams": ("src_parity_seam_t", "strm:src_seam_strm_t"),
    "src_bank_seams": ("src_bank_seam_t", "strm:src_seam_strm_t"),
    "src_edge_hdr": ("src_edge_t",),
    "src_slow_hdr": ("src_slow_hdr_t",),
    "src_wrap_hdr": ("src_edge_t", "src_wrap_t"),
    "pal_ops": ("t_palette",),
    "pal_straddles": ("t_palette", "pal_straddle_t"),
    "pal_chunks": (),
    "kstart": (),
    "kflip": (),
    "fend": (),
    "fend_span": (),
}
ZERO_COST = {
    "fast_hop0_run8": "a subset of fast_hop_run8, priced at the dearer counted-seg1 form",
    "fast_hop0_copy8": "a subset of fast_hop_copy8, priced at the dearer counted-seg1 form",
    "pal_chunks": "a straddle runs 1 or 2 chunks; PAL2 measures the dearer 2",
    "kstart": "inside the frame-type terms (S3)",
    "kflip": "inside the frame-type terms (S3)",
    "fend": "inside the frame-type terms (S3)",
    "fend_span": "inside the frame-type terms (S3)",
}
REM_TERM = "copy_dma_rem_t"
_EVENT_NAMES = {f.name for f in fields(sim.Events)}
assert set(COUNTER_TERMS) | sim.DIAGNOSTIC == _EVENT_NAMES, "every Events counter is mapped"
assert not set(COUNTER_TERMS) & sim.DIAGNOSTIC
assert {k for k, v in COUNTER_TERMS.items() if not v} == set(ZERO_COST)


def _resolve(term, split):
    """'x_t@8' -> x_t, or x8_t when x_t is split; a gap:/gaplo:/strm: prefix is kept."""
    pre = ""
    if term.startswith(("gap:", "gaplo:", "strm:")):
        pre, term = term.split(":", 1)
        pre += ":"
    if "@" in term:
        base, width = term.split("@")
        term = base[:-2] + width + "_t" if base in split else base
    return pre + term


def counter_map_lines(split=()):
    """The counter-to-term map as coded, one line per counter."""
    out = []
    for name in sorted(COUNTER_TERMS):
        terms = COUNTER_TERMS[name]
        if not terms:
            out.append(f"  {name:<18} zero-cost: {ZERO_COST[name]}")
            continue
        shown = [f"fetch_short (op L < {FETCH_SEL}) or fetch_long" if t == FETCH else _resolve(t, split)
                 for t in terms]
        out.append(f"  {name:<18} {' + '.join(shown)}")
    for name in sorted(sim.DIAGNOSTIC):
        out.append(f"  {name:<18} diagnostic, never priced")
    out.append(f"  {'(op length)':<18} {REM_TERM} per COPY op with L >= 240 and L mod 240 >= its select")
    return out


def term_counts(ev, surface, streaming=False, long_b=0, rem_ops=0, split=()):
    """Events -> Counter {term: count}."""
    gapped = bool(surface[2])
    low = gapped and int(surface[1]) <= sim.DMA_CHUNK
    out = Counter()
    fetch_b = 0
    for name, count in ev.as_dict().items():
        if name in sim.DIAGNOSTIC:
            continue
        for term in COUNTER_TERMS[name]:
            term = _resolve(term, split)
            if term.startswith("gap:"):
                if not gapped:
                    continue
                term = term[4:]
            elif term.startswith("gaplo:"):
                if not low:
                    continue
                term = term[6:]
            elif term.startswith("strm:"):
                if not streaming:
                    continue
                term = term[5:]
            if term == FETCH:
                fetch_b += count
            else:
                out[term] += count
    if fetch_b > long_b:
        out["fetch_short"] += fetch_b - long_b
    if long_b:
        out["fetch_long"] += long_b
    if rem_ops:
        out[REM_TERM] += rem_ops
    return out


def price(counts, values):
    """Sum of count x value; a counted term with no value raises KeyError."""
    total = 0.0
    for term, count in counts.items():
        if count:
            if term not in values:
                raise KeyError(f"no value for term {term!r} ({count})")
            total += count * values[term]
    return total


class _Thr(int):
    """A kernel select that records every value compared against it."""

    def __new__(cls, value, seen):
        obj = int.__new__(cls, value)
        obj.seen = seen
        return obj

    def _note(self, other, result):
        self.seen.add(int(other))
        return result

    def __le__(self, other):
        return self._note(other, int(self) <= int(other))

    def __lt__(self, other):
        return self._note(other, int(self) < int(other))

    def __ge__(self, other):
        return self._note(other, int(self) >= int(other))

    def __gt__(self, other):
        return self._note(other, int(self) > int(other))

    __hash__ = int.__hash__


class _RatePlayer(sim._Player):
    """The simulator's player, also counting LDI bytes of ops at L >= FETCH_SEL
    and COPY ops whose remainder after full chunks is a DMA chunk, and
    recording the values each select decided on."""

    def __init__(self, *args):
        super().__init__(*args)
        self.long_b = 0
        self.rem_ops = 0
        self.copy_seen, self.run_seen = set(), set()
        self.copy_thr = _Thr(self.copy_thr, self.copy_seen)
        self.run_thr = _Thr(self.run_thr, self.run_seen)

    def _copy(self, handler, op, n):
        if op not in (sim.OP_COPY8, sim.OP_COPY16):
            return handler(op, n)
        before = self.ev.copy_fast_b + self.ev.copy_ldi_b
        handler(op, n)
        if n >= FETCH_SEL:
            self.long_b += self.ev.copy_fast_b + self.ev.copy_ldi_b - before
        if n >= sim.DMA_CHUNK and n % sim.DMA_CHUNK >= self.copy_thr:
            self.rem_ops += 1

    def fast_op(self, op, n):
        self._copy(super().fast_op, op, n)

    def slow_op(self, op, n):
        self._copy(super().slow_op, op, n)


def simulate(ops, surface, src_offset, dst, in_span, copy_thr, run_thr, dst_pages=None, seen=None):
    """-> (Events, long_b, rem_ops, State); seen, a list, gets the (COPY, RUN)
    value sets the selects decided on."""
    p = _RatePlayer(surface, src_offset, dst, in_span, copy_thr, run_thr, dst_pages)
    p.run(ops)
    if seen is not None:
        seen[:] = [p.copy_seen, p.run_seen]
    return p.ev, p.long_b, p.rem_ops, sim.State(p.dpage, p.de, p.in_span, p.page * sim.WIN_BYTES + p.w)


def standalone_counts(tag, split=()):
    """{term: count} PER OP for a standalone row at its sitting selects."""
    _t, kind, L, o, _r, _thr, geo = bench._row(tag)
    surface = bench.row_surface(tag)
    _g, _h, dcode = bench.geo_fields(geo)
    copy, run = bench.row_selects(tag, bench.SITTING_SELECTS)
    ops = [(sim.OPCODE_BY_KIND[kind], L)] * o + [(sim.OP_FEND, 0)]
    ev, long_b, rem, _st = simulate(ops, surface, 0, (0, bench.GEO_DESTS[dcode]), False,
                                    copy, run, bench.NXB_DST_PAGES)
    if ev != bench.row_events(tag):
        raise AssertionError(f"{tag}: rate-player events differ from row_events")
    counts = term_counts(ev, surface, False, long_b, rem, split)
    return Counter({k: c / float(o) for k, c in counts.items()})


def synth_counts(table, tag, surface, streaming, split=()):
    """{term: count} PER REP for a SYNTH row on a session surface."""
    row = next(r for r in bench.SESSION_TABLES[table] if r[0] == tag)
    _t, kind, _reps, frame, preset, *sites = row
    if kind == "synth_nocall":
        return Counter()
    ops = bench.synth_ops(frame, sites)
    ev, long_b, rem, _st = simulate(ops, surface, frame, (0, bench.SPAN_PRESET_DE[preset]),
                                    preset != 0, *bench.SITTING_SELECTS)
    if ev != bench.row_events(tag, surface, table):
        raise AssertionError(f"{table} {tag}: rate-player events differ from row_events")
    return term_counts(ev, surface, streaming, long_b, rem, split)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@dataclass
class FrameEv:
    index: int
    type: str
    ev: object
    long_b: int
    rem_ops: int
    offset: int
    nbytes: int
    copy_seen: set = None
    run_seen: set = None
    memo: dict = field(default_factory=dict)


_WALKS = {}          # path -> (header, surface, [(start, ops, type, dst, in_span, end State)])
_FRAME_CACHE = {}    # (path, COPY, RUN) -> [FrameEv]


def fixture_era():
    ps1 = (HERE / "build-tests.ps1").read_text(encoding="utf-8")
    m = re.search(r"\$vidLegSettlementTag = '([^']+)'", ps1)
    if not m:
        raise ValueError("build-tests.ps1 carries no $vidLegSettlementTag")
    return m.group(1)


def fixture_path(clip):
    found = sorted((HERE / "out").glob(f"{int(clip):03d}_*_{fixture_era()}_*_cache.vid"))
    if not found:
        raise FileNotFoundError(f"{int(clip):03d}.VID is not encoded at era {fixture_era()} "
                                f"(tests\\build-tests.ps1 -Vid -VidLong)")
    return found[0]


def fixture_header(path):
    with open(path, "rb") as fh:
        return enc.unpack_header(fh.read(enc.HEADER_SIZE))


def _decided(seen, a, b):
    """True when a select moved from a to b can flip a decision on seen values
    (v >= thr flips for v in [a, b - 1], v > thr for v in [a + 1, b])."""
    if a == b:
        return False
    lo, hi = min(a, b), max(a, b)
    return any(lo <= x <= hi for x in seen)


def fixture_frames(path, copy_thr, run_thr):
    """(header, surface, [FrameEv]) at the selects, cached. The span cursor
    carries across chunk frames as nxv2_frame_model.frames does; a frame whose
    decisions cannot flip between two selects reuses the nearer cached events."""
    path, copy_thr, run_thr = str(path), int(copy_thr), int(run_thr)
    key = (path, copy_thr, run_thr)
    if path not in _WALKS:
        buf = Path(path).read_bytes()
        hdr = enc.unpack_header(buf)
        issues = []
        walked = list(nxv2dec._iter_frames(buf, hdr, issues=issues))
        if issues:
            raise ValueError(f"{path}: {issues[0]}")
        surface = fm.surface_of(hdr)
        frames, frames_ev, in_span, dst = [], [], False, (0, sim.DST_WIN)
        for i, (_p, _s, _t, start, length) in enumerate(walked):
            ops = sim.parse_payload(buf[start:start + length])
            ftype = fm.frame_type(ops, in_span)
            seen = []
            ev, long_b, rem, st = simulate(ops, surface, start, dst, in_span, copy_thr, run_thr, seen=seen)
            frames.append((start, ops, ftype, dst, in_span, st))
            frames_ev.append(FrameEv(i, ftype, ev, long_b, rem, start,
                                     sum(sim.op_bytes(op, n) for op, n in ops), *seen))
            in_span = st.in_span
            dst = (st.page, st.de) if in_span else (0, sim.DST_WIN)
        _WALKS[path] = (hdr, surface, frames)
        _FRAME_CACHE[key] = frames_ev
    if key not in _FRAME_CACHE:
        hdr, surface, frames = _WALKS[path]
        ref_key = min((k for k in _FRAME_CACHE if k[0] == path),
                      key=lambda k: (abs(k[1] - copy_thr) + abs(k[2] - run_thr), k))
        out = []
        for i, fr in enumerate(_FRAME_CACHE[ref_key]):
            if not (_decided(fr.copy_seen, ref_key[1], copy_thr) or _decided(fr.run_seen, ref_key[2], run_thr)):
                out.append(fr)
                continue
            start, ops, ftype, dst, in_span, end = frames[i]
            seen = []
            ev, long_b, rem, st = simulate(ops, surface, start, dst, in_span, copy_thr, run_thr, seen=seen)
            if (st.page, st.de, st.in_span) != (end.page, end.de, end.in_span):
                raise AssertionError(f"{path} frame {i}: the end cursor moved with the selects")
            out.append(FrameEv(i, ftype, ev, long_b, rem, start, fr.nbytes, *seen))
        _FRAME_CACHE[key] = out
    hdr, surface, _frames = _WALKS[path]
    return hdr, surface, _FRAME_CACHE[key]


def frame_price(fr, surface, streaming, values, split=()):
    """Event-priced decode T of one fixture frame, its frame-type term included."""
    key = (bool(surface[2]), bool(streaming), tuple(sorted(split)))
    if key not in fr.memo:
        fr.memo[key] = term_counts(fr.ev, surface, streaming, fr.long_b, fr.rem_ops, split)
    return values[f"frame_{fr.type}_t"] + price(fr.memo[key], values)


def model_total(v, clips, copy_of, run_thr, streaming_of):
    """Modelled decode T summed over every frame of the clips. copy_of(surface) ->
    the COPY select for that surface."""
    total = 0.0
    for clip in clips:
        path = fixture_path(clip)
        surface = fm.surface_of(fixture_header(path))
        _h, _s, frames = fixture_frames(path, copy_of(surface), run_thr)
        strm = streaming_of(clip)
        total += sum(frame_price(fr, surface, strm, v, v["split"]) for fr in frames)
    return total


def expected_delivery(hdr, size, pool):
    """resident / streaming / direct from the header, the file size and the pool
    at open (RING D=); None when the snapshot-bank count decides."""
    if hdr["flags"] & enc.FLAG_DIRECT_SERVE:
        return "direct"
    need = -(-size // BANK_B)
    if need > VID_RING_MAX:
        return "streaming"
    if pool is None:
        return None
    if need + 1 + 5 <= pool:             # ring + audio bank + at most 5 snapshot banks
        return "resident"
    if need + 1 > pool:
        return "streaming"
    return None


def silicon_r(anchors, width, height, density):
    """R from any number of (density, R) anchors per class: linear between
    neighbours, clamped outside, the largest R at density None."""
    key = ("gapped" if enc.is_gapped(width, height)
           else "flat_320" if int(width) == 320 else "flat_256")
    pts = sorted(anchors[key])
    if density is None:
        return max(r for _d, r in pts)
    if density <= pts[0][0]:
        return pts[0][1]
    for (d0, r0), (d1, r1) in zip(pts, pts[1:]):
        if density <= d1:
            return r0 + (r1 - r0) * (density - d0) / (d1 - d0)
    return pts[-1][1]


def supply_exchange_t_per_byte(v, width, height):
    """clock_khz / (SD_WIRE_BYTES_PER_MS x silicon_r(width, height, 1.0))."""
    return CLOCK_KHZ / (v["SD_WIRE_BYTES_PER_MS"] * silicon_r(v["silicon_r"], width, height, 1.0))


# ---------------------------------------------------------------------------
# The parsed sitting
# ---------------------------------------------------------------------------
@dataclass
class Sess:
    table: str
    clip: int
    run: object
    rows: dict
    delivery: str = None
    path: Path = None
    hdr: dict = None
    surface: tuple = None
    invalid: set = field(default_factory=set)

    def T(self, tag):
        if tag in self.invalid:
            raise KeyError(f"{self.label} {tag} was invalidated by S0")
        return t_rep(self.rows[tag])

    @property
    def streaming(self):
        return self.delivery == "streaming"

    @property
    def label(self):
        return f"{self.table} {self.clip:03d}"

    @property
    def fps(self):
        return self.hdr["fps_x10"] / 10.0


@dataclass
class Sitting:
    rows: dict
    sessions: dict
    anchor: dict = None

    def T(self, tag):
        return t_op(self.rows[tag])

    def of(self, table, delivery=None):
        return [s for (t, _c), s in sorted(self.sessions.items())
                if t == table and (delivery is None or s.delivery == delivery)]

    def streaming_of(self, clip):
        for (_t, c), s in self.sessions.items():
            if c == clip and s.delivery in ("resident", "streaming"):
                return s.streaming
        return fixture_path(clip).stat().st_size > enc.STREAM_RESIDENT_POOL_B


def _label(run):
    stamp = "typed" if run.stamp is None else f"#NXB {run.stamp:04X}"
    clip = f" clip {run.clip:03d}" if run.clip is not None else ""
    return f"{stamp} {run.command or '?'}{clip}"


def _row_kinds(table):
    return {r[0]: r[1] for r in bench.SESSION_TABLES[table]}


def _reps_of(table):
    out = {}
    for r in bench.SESSION_TABLES[table]:
        if r[1] in bench.SESSION_SYNTH:
            out[r[0]] = r[2]
        elif r[1] in bench.SESSION_REPS:
            out[r[0]] = r[3]
        else:
            out[r[0]] = 1
    return out


def _compare(label, tag, first, later, tol, slips, fail):
    """One repeat against the first reading: within tol lines, a 311 +- 1 slip
    (use the repeat), or a failure. -> the row to keep."""
    d = row_lines(later) - row_lines(first)
    if abs(d) <= tol:
        return first
    if abs(abs(d) - LPF) <= 1:
        slips.append(f"{label} {tag}: {d:+d} lines against its repeat, a one-field clock slip - "
                     f"the repeat is used")
        return later
    fail.append(f"{label} {tag}: repeat differs by {d:+d} lines (tolerance {tol})")
    return first


def launch_key(text):
    """'71A4=OK', 'D:0200=ERR 60' or '#12=OK' (typed text, run number) ->
    ((log, stamp or '#n'), status)."""
    key, _eq, status = text.partition("=")
    log = "Q"
    if key.upper().startswith("D:"):
        log, key = "D", key[2:]
    if not status or not re.fullmatch(r"#\d+|[0-9A-Fa-f]{1,4}", key):
        raise ValueError(f"--launch-status {text!r}: want [D:]hhhh=OK, [D:]hhhh=ERR xx or [D:]#n=OK")
    return (log, key if key.startswith("#") else int(key, 16)), status.strip().upper()


def _launch_name(log, key):
    return ("D:" if log == "D" else "") + (key if isinstance(key, str) else f"{key:04X}")


def s0(q_text, d_text=None, *, no_anchor=False, launch_status=None,
       sessions=SESSIONS, standalone=STANDALONE):
    """S0 - integrity.
    -> (Sitting, lines); a Stop names every failure. launch_status: {(log, stamp
    or '#n'): status}, the owner's note for each run whose LOG status the file
    cannot hold."""
    lines, fail, slips = [], [], []
    runs = blog.parse(q_text)
    if not runs:
        raise Stop("S0", "the Q log holds no runs")
    d_runs = []
    if d_text is not None:
        d_runs = blog.parse(d_text)
        if not d_runs:
            fail.append("the D log holds no runs")
    elif no_anchor:
        lines.append("D-image NXBC anchor check skipped (--no-anchor)")
    else:
        lines.append("D-image NXBC anchor check skipped: no --anchor log")
        fail.append("S0's D-image check needs --anchor NXBENCH-D.TXT")
    notes, used = dict(launch_status or {}), set()
    for log, group in (("Q", runs), ("D", d_runs)):
        for i, run in enumerate(group):
            if run.log is not None:
                continue
            key = (log, run.stamp if run.stamp is not None else f"#{i + 1}")
            name = _launch_name(*key)
            if key not in notes:
                fail.append(f"{_label(run)}: its LOG status is not in the file (a launch's last run); "
                            f"give the owner's note with --launch-status {name}=OK")
                continue
            used.add(key)
            run.log = notes[key]
            lines.append(f"{_label(run)}: LOG {run.log} from the owner's launch note ({name})")
    for key in sorted(set(notes) - used, key=str):
        fail.append(f"--launch-status {_launch_name(*key)}: names no run whose LOG status the file "
                    f"cannot hold")

    # per-run integrity
    trusted = []
    for run in runs + d_runs:
        where = _label(run)
        bad = []
        if run.command is None:
            bad.append("no bench verb in the capture")
        bad += [f"parser warning: {w}" for w in run.warnings]
        if run.dropped:
            bad.append(f"rows of another table on screen: {[g[0] for g in run.dropped]}")
        if run.log is None:
            continue                       # no launch note: failed above
        if run.log != "OK":
            bad.append(f"LOG {run.log}: untrusted, excluded")
        if bad:
            fail += [f"{where}: {b}" for b in bad]
            continue
        trusted.append(run)

    # sessions: identity, rows, teardown
    by_sess, by_mode = {}, {}
    for run in trusted:
        if run in d_runs:
            continue
        if run.command in blog.SESSION_VERBS:
            by_sess.setdefault((run.table, run.clip), []).append(run)
        else:
            by_mode.setdefault(run.table, []).append(run)
    built = {}
    for (table, clip), sruns in sorted(by_sess.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0)):
        first = None
        for run in sruns:
            sess = _s0_session(run, table, clip, fail, lines)
            if sess is not None and first is None:
                first = sess
            elif sess is not None:
                _s0_session_repeat(first, sess, slips, fail)
        if first is not None:
            built[(table, clip)] = first
    for key in sessions:
        if key not in by_sess:
            fail.append(f"{key[0]} {key[1]:03d}: no trusted session run")

    # standalone: rows, CALL/CALR, repeats
    rows = {}
    for mode in standalone:
        mruns = by_mode.get(mode, [])
        if not mruns:
            fail.append(f"mode {mode} ({bench.printed_tags(mode)[0]}...): no trusted run")
            continue
        table = {r[0]: r for r in bench.BENCH_TABLES[mode]}
        for run in mruns:
            got = {g[0]: g[1:] for g in run.rows}
            missing = [t for t in bench.printed_tags(mode) if t not in got]
            if missing:
                fail.append(f"{_label(run)}: rows missing {missing}")
            for tag, (o, r, f, d) in got.items():
                want = table.get(tag, table.get("CALL"))
                want_o = 0 if tag in ("CALL", "CALR") else want[3]
                if (o, r) != (want_o, want[4]):
                    fail.append(f"{_label(run)} {tag}: O={o:02X} R={r:04X}, the table runs "
                                f"O={want_o:02X} R={want[4]:04X}")
            if "CALL" in got and "CALR" in got and got["CALL"][2:] != got["CALR"][2:]:
                fail.append(f"{_label(run)}: CALL F={got['CALL'][2]:04X} D={got['CALL'][3]} and CALR "
                            f"F={got['CALR'][2]:04X} D={got['CALR'][3]} disagree: the long clock slipped")
        base = {g[0]: g[1:] for g in mruns[0].rows}
        keep = dict(base)
        for run in mruns[1:]:
            for tag, row in ((g[0], g[1:]) for g in run.rows):
                if tag in base:
                    keep[tag] = _compare(_label(run), tag, base[tag], row, 1, slips, fail)
        if mode == 3 and len(mruns) < 2:
            fail.append("NXBC: the start and end runs are both needed")
        rows.update(keep)

    # the D-image anchor
    anchor = None
    if d_runs:
        dc = [r for r in trusted if r in d_runs and r.command == "NXBC"]
        if not dc:
            fail.append("the D log holds no trusted NXBC run")
        else:
            anchor = {g[0]: g[1:] for g in dc[0].rows}
            for tag in bench.printed_tags(3):
                if tag not in anchor:
                    fail.append(f"D-image NXBC: {tag} missing")
                    continue
                want = bench.SITTING4[tag]
                if anchor[tag][:2] != want[:2]:
                    fail.append(f"D-image NXBC {tag}: O/R {anchor[tag][:2]} against sitting 4 {want[:2]}")
                d = row_lines(anchor[tag]) - row_lines(want)
                if abs(d) <= 1:
                    continue
                if abs(abs(d) - LPF) <= 1:
                    slips.append(f"D-image NXBC {tag}: {d:+d} lines against sitting 4, a one-field "
                                 f"clock slip")
                else:
                    fail.append(f"D-image NXBC {tag}: {d:+d} lines against sitting 4 (tolerance 1)")
            lines.append(f"D-image NXBC: {len(anchor)} rows against sitting 4")

    lines += [f"clock slip recorded: {s}" for s in slips]
    if fail:
        raise Stop("S0", fail, lines)
    lines.append(f"{len(runs)} Q runs, {len(d_runs)} D runs: every LOG OK, ERR=00, identity and "
                 f"repeats within tolerance")
    return Sitting(rows, built, anchor), lines


def _s0_session(run, table, clip, fail, lines):
    where = _label(run)
    if clip is None:
        fail.append(f"{where}: no PICK before the session verb")
        return None
    try:
        path = fixture_path(clip)
    except FileNotFoundError as exc:
        fail.append(f"{where}: {exc}")
        return None
    hdr = fixture_header(path)
    rows = {g[0]: g[1:] for g in run.rows}
    iden, ring = rows.get("IDEN"), rows.get("RING")
    if iden is None:
        fail.append(f"{where}: no IDEN row")
        return None
    names = {0: "resident", 1: "streaming", 2: "direct"}
    delivery = names.get(iden[0])
    pool = ring[3] if ring else None
    want = expected_delivery(hdr, path.stat().st_size, pool)
    w, h, frames = hdr["width"], hdr["height"], hdr["frame_count"]
    ident = [(iden[1], frames & 0xFFFF, "frames"), (iden[2], 0x140 if w == 320 else 0x100, "width"),
             (iden[3], h & 0xFF, "height byte")]
    wrong = [f"{what} {got} (want {exp})" for got, exp, what in ident if got != exp]
    if delivery is None or (want is not None and delivery != want):
        wrong.append(f"delivery O={iden[0]:02X} (want {want})")
    if delivery not in bench.SESSION_DELIVERY[table]:
        wrong.append(f"{table} does not run {delivery}")
    if table != "DS1" and ring is not None and (ring[1] == 0) != (delivery == "resident"):
        wrong.append(f"RING R={ring[1]:04X} is not the {delivery} depth")
    if wrong:
        fail.append(f"{where}: IDEN does not name clip {clip:03d} ({w}x{h}, {frames} frames): "
                    + ", ".join(wrong))
        return None
    sess = Sess(table, clip, run, rows, delivery, path, hdr, fm.surface_of(hdr))
    want_tags = bench.session_printed(table, delivery)
    missing = [t for t in want_tags if t not in rows]
    err_ok = run.err == 0
    if run.err is None:
        fail.append(f"{where}: no teardown ERR= line")
    elif run.err != 0:
        through = want_tags[:want_tags.index("REMN") + 1] if "REMN" in want_tags else None
        if (table == "REAL" and delivery == "streaming" and through
                and all(t in rows for t in through)):
            sess.invalid = {"PROD", "APRD"}
            missing = [t for t in missing if t not in sess.invalid]
            lines.append(f"{where}: ERR={run.err:02X} after REMN invalidates PROD and APRD only")
            err_ok = True
        else:
            fail.append(f"{where}: teardown ERR={run.err:02X}")
    if missing:
        fail.append(f"{where}: rows missing {missing}")
    reps, kinds = _reps_of(table), _row_kinds(table)
    for tag, (o, r, _f, _d) in rows.items():
        if tag in sess.invalid or kinds[tag] in UNTIMED_KINDS:
            continue
        if r != reps[tag]:
            fail.append(f"{where} {tag}: R={r:04X}, the table runs {reps[tag]:04X}")
        if kinds[tag] in bench.SESSION_SYNTH:
            preset = next(x for x in bench.SESSION_TABLES[table] if x[0] == tag)[4]
            if o != preset:
                fail.append(f"{where} {tag}: O={o:02X}, the row's span preset is {preset:02X}")
    return sess if err_ok and not missing else None


def _s0_session_repeat(first, later, slips, fail):
    kinds = _row_kinds(first.table)
    where = f"{_label(later.run)} (repeat)"
    for tag, row in later.rows.items():
        if tag not in first.rows or kinds[tag] in UNCOMPARED_KINDS or tag in first.invalid:
            continue
        if row[0] != first.rows[tag][0]:
            if kinds[tag] == "frame":
                continue                   # SCAN may pick another frame on a repeat
            fail.append(f"{where} {tag}: O={row[0]:02X} against the first run's "
                        f"O={first.rows[tag][0]:02X}")
            continue
        tol = REPEAT_LINES.get(kinds[tag], 1)
        first.rows[tag] = _compare(where, tag, first.rows[tag], row, tol, slips, fail)


# ---------------------------------------------------------------------------
# S1 - S3
# ---------------------------------------------------------------------------
S1_FIT_TAGS = ("SK00", "S160", "RU01", "RU17", "CP01", "CP17", "R161", "C161", "F063", "F070",
               "F071", "F256", "K256", "C001", "C004", "C008", "C016", "C038", "C080", "C081",
               "C103", "C256")


def s1(sit, v):
    """S1 - envelopes and slopes.
    fit_tmodel.fit on the Q rows; an intercept is raised until none of its rows
    prices under (by more than max(5.5 T, one line of the row))."""
    T = sit.T
    bench.ROWS["_sitting5q"] = {tag: sit.rows[tag] for tag in S1_FIT_TAGS}
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            fit = fit_tmodel.fit("_sitting5q")
    finally:
        del bench.ROWS["_sitting5q"]
    lines, out, raises, bounds = [], {}, {}, {}
    for name, tags, (icpt, slope) in (("run", ("RU01", "RU17", "F063", "F070"), ("t_op_run", "fill_cpu")),
                                      ("copy", ("C001", "C004", "C008", "C038"), ("t_op_copy", "fetch_short"))):
        pts = [(bench._row(t)[2], T(t)) for t in tags]
        a, b, worst = lsq(pts)
        if abs(a - fit[icpt]) > 1e-6 or abs(b - fit[slope]) > 1e-9:
            raise AssertionError(f"S1 {name} line differs from fit_tmodel.fit")
        lift = max(0.0, max(y - (a + b * x) - op_band(sit.rows[t]) for (x, y), t in zip(pts, tags)))
        if lift:
            raises[icpt] = lift
        out[icpt], out[slope] = a + lift, b
        bounds[icpt], bounds[slope] = line_bounds([x for x, _y in pts], [sigma_op(sit.rows[t]) for t in tags])
        lines.append(ruling(f"{icpt} {ceil01(out[icpt])} T", f"least squares {' '.join(tags)}: {a:.2f} + {b:.4f} L, "
                            f"worst residual {worst:.2f} T, raised {lift:.2f} T, up to 0.1",
                            f"every {name.upper()} op's dispatch misprices by the error"))
        lines.append(ruling(f"{slope} {ceil01(out[slope])} T/B", f"slope of the same fit {b:.4f}, up to 0.1",
                            f"every {name.upper()} byte misprices by the error"))
    longs = {t: (T(t) - out["t_op_copy"]) / bench._row(t)[2] for t in ("L064", "L072", "L080")}
    out["fetch_long"] = max(longs.values())
    bounds["fetch_long"] = max((sigma_op(sit.rows[t]) + bounds["t_op_copy"]) / bench._row(t)[2] for t in longs)
    lines.append(ruling(f"fetch_long {ceil01(out['fetch_long'])} T/B",
                        "max (T - t_op_copy) / L over " + ", ".join(f"{t} {x:.4f}" for t, x in longs.items()),
                        "every LDI byte of a long op misprices"))
    out["t_skip"], out["t_skip16"] = T("SK00"), T("S160")
    bounds["t_skip"], bounds["t_skip16"] = sigma_op(sit.rows["SK00"]), sigma_op(sit.rows["S160"])
    bounds["copy_dma_per_b"] = (sigma_op(sit.rows["C103"]) + sigma_op(sit.rows["C081"])) / 22.0
    bounds["fill_dma_per_b"] = (sigma_op(sit.rows["P200"]) + sigma_op(sit.rows["P071"])) / 129.0
    lines.append(ruling(f"t_skip {ceil01(out['t_skip'])} T", f"T(SK00) {T('SK00'):.2f}", "every SKIP8 op"))
    lines.append(ruling(f"t_skip16 {ceil01(out['t_skip16'])} T", f"T(S160) {T('S160'):.2f}", "every SKIP16 op"))
    per_b = (T("C103") - T("C081")) / 22.0
    out["copy_dma_per_b"] = fit["copy_dma_per_b"]
    lines.append(ruling(f"copy_dma_per_b {ceil01(out['copy_dma_per_b'])} T/B",
                        f"(T(C103) {T('C103'):.2f} - T(C081) {T('C081'):.2f}) / 22 = {per_b:.4f}",
                        "every DMA COPY byte; S4's setups absorb the error"))
    fd = (T("P200") - T("P071")) / 129.0
    out["fill_dma_per_b"] = fd
    lines.append(ruling(f"fill_dma_per_b {ceil01(out['fill_dma_per_b'])} T/B",
                        f"(T(P200) {T('P200'):.2f} - T(P071) {T('P071'):.2f}) / 129 = {fd:.4f}",
                        "every DMA fill byte; S4's setups absorb the error"))
    for term, lift in raises.items():
        lines.append(f"raise: {term} +{lift:.2f} T (a row priced under)")
    out["raises"] = dict(raises)
    out["bounds"] = bounds
    return out, lines


def s2(sit, v):
    """S2 - the 8-bit body chunk-pass estimates S4 checks its values against."""
    T = sit.T
    arm = HAND["cap_arm_t"][0]            # C250/R250's 250 B first chunk takes the cap arm
    ldi = T("C250") - T("C240") - 10 * v["fetch_long"] - arm
    cpu = T("R250") - T("R240") - 10 * v["fill_cpu"] - arm
    lines = [ruling(f"8-bit copy_body_ldi_t estimate {ldi:.1f} T",
                    f"T(C250) {T('C250'):.2f} - T(C240) {T('C240'):.2f} - 10 x fetch_long {v['fetch_long']:.4f} "
                    f"- cap_arm_t {arm}",
                    "a check only: S4 splits 8/16-bit when its value differs by more than 5.5 T"),
             ruling(f"8-bit fill_body_cpu_t estimate {cpu:.1f} T",
                    f"T(R250) {T('R250'):.2f} - T(R240) {T('R240'):.2f} - 10 x fill_cpu {v['fill_cpu']:.4f} "
                    f"- cap_arm_t {arm}",
                    "a check only: S4 splits 8/16-bit when its value differs by more than 5.5 T")]
    return {"s2_ldi8": ldi, "s2_cpu8": cpu}, lines


def s3(sit, v):
    """S3 - frame types, palette and glue."""
    lines, out, fail, bounds = [], {}, [], {}
    synth = sit.of("SYN") + sit.of("SYS")
    if not synth:
        raise Stop("S3", "no SYN or SYS session", lines)
    diffs = {"frame_delta_t": "FE00", "frame_middle_t": "FE01", "frame_first_t": "KS02",
             "frame_single_t": "KS01", "frame_last_t": "KF01"}
    for s in synth:
        a = s.T("KS01") - s.T("KS02")
        b = s.T("KF01") - s.T("FE01")
        lines.append(f"{s.label}: KS01-KS02 {a:.1f} T, KF01-FE01 {b:.1f} T")
        if abs(a - b) > S3_TYPE_AGREE_T:
            fail.append(f"{s.label}: KS01-KS02 {a:.1f} and KF01-FE01 {b:.1f} differ by {a - b:+.1f} T "
                        f"(over {S3_TYPE_AGREE_T:.0f})")
    if fail:
        raise Stop("S3", fail, lines)
    for term, tag in diffs.items():
        per = {s.label: s.T(tag) - s.T("NUL0") for s in synth}
        worst = max(per, key=per.get)
        out[term] = per[worst]
        bounds[term] = max(sigma_rep(s.rows[tag]) + sigma_rep(s.rows["NUL0"]) for s in synth)
        lines.append(ruling(f"{term} {ceil01(out[term])} T", f"max T({tag}) - T(NUL0) over "
                            + ", ".join(f"{k} {x:.1f}" for k, x in per.items()) + f" ({worst})",
                            "every frame of this type misprices"))
    syn = sit.of("SYN")
    pal = {s.label: s.T("PAL1") - s.T("FE00") for s in syn}
    straddle = {s.label: s.T("PAL2") - s.T("PAL1") for s in syn}
    out["t_palette"] = max(pal.values())
    out["pal_straddle_t"] = max(straddle.values())
    bounds["t_palette"] = max(sigma_rep(s.rows["PAL1"]) + sigma_rep(s.rows["FE00"]) for s in syn)
    bounds["pal_straddle_t"] = max(sigma_rep(s.rows["PAL2"]) + sigma_rep(s.rows["PAL1"]) for s in syn)
    lines.append(ruling(f"t_palette {ceil01(out['t_palette'])} T", "max T(PAL1) - T(FE00) over "
                        + ", ".join(f"{k} {x:.1f}" for k, x in pal.items()), "every PAL op"))
    lines.append(ruling(f"pal_straddle_t {ceil01(out['pal_straddle_t'])} T", "max T(PAL2) - T(PAL1) over "
                        + ", ".join(f"{k} {x:.1f}" for k, x in straddle.items())
                        + " (includes PAL2's parity walk)", "every PAL op straddling a window end"))
    for delivery, name in (("resident", "glue_t"), ("streaming", "glue_strm_t")):
        per = {}
        for s in sit.of("REAL", delivery):
            n = s.rows["LOOP"][0]
            if s.rows["WL16"][0] != n:
                raise Stop("S3", f"{s.label}: LOOP O={n} and WL16 O={s.rows['WL16'][0]} differ", lines)
            g = ((s.T("LOOP") - s.T("WL16") - n * s.T("AUD1")) / n + (s.T("PACE") - H_PACE)
                 - H_STUB + H_AUDREP + H_SKIP[delivery])
            per[s.label] = g
            bounds[name] = max(bounds.get(name, 0.0),
                               (sigma_rep(s.rows["LOOP"]) + sigma_rep(s.rows["WL16"])) / n
                               + sigma_rep(s.rows["AUD1"]) + sigma_rep(s.rows["PACE"]))
        if not per:
            raise Stop("S3", f"no {delivery} REAL session for {name}", lines)
        out[name] = max(per.values())
        lines.append(ruling(f"{name} {ceil01(out[name])} T",
                            f"max over {delivery} REAL of (T(LOOP) - T(WL16) - n x T(AUD1)) / n + "
                            f"(T(PACE) - {H_PACE}) - {H_STUB} + {H_AUDREP} + {H_SKIP[delivery]}: "
                            + ", ".join(f"{k} {x:.1f}" for k, x in per.items()),
                            "the usable budget per frame is off by the error"))
    out["bounds"] = bounds
    return out, lines


# ---------------------------------------------------------------------------
# S4
# ---------------------------------------------------------------------------
@dataclass
class S4Row:
    label: str
    counts: Counter
    T: float
    sigma: float
    band: float
    base: float
    col_scored: bool


def _s4_rows(sit, split):
    rows = []
    for mode in S4_MODES + (9,):
        for tag, kind, _L, o, r, _thr, geo in bench.BENCH_TABLES[mode]:
            if kind == bench.CAL_KIND or (mode == 9 and tag not in S4_NXBE):
                continue
            row = sit.rows[tag]
            rows.append(S4Row(tag, standalone_counts(tag, split), t_op(row), TPL / float(r * o),
                              op_band(row), t_op(row), mode in (6, 10) or tag in S4_COL_SCORED))
    for s in sit.of("SYN"):
        reps = _reps_of("SYN")
        for tag in S4_SYN:
            base = "FE01" if tag in S4_SPAN_ROWS else "FE00"
            t_row = s.T(tag)
            sigma = TPL * math.hypot(1.0 / reps[tag], 1.0 / reps[base])
            rows.append(S4Row(f"{s.label} {tag}", synth_counts("SYN", tag, s.surface, False, split),
                              t_row - s.T(base), sigma, BAND_SESS * t_row, t_row,
                              bool(s.surface[2]) and tag.startswith(("C4K", "K"))))
    return rows


def term_band(value):
    """A term's band: max(2 T, 2%)."""
    return max(2.0, 0.02 * abs(value))


def _s4_solve(rows, held, unknowns, held_bound):
    """Joint least squares weighted by each row's one-line resolution. A term the
    rows cannot isolate - rank, or +-1 line on every row moving it past its band -
    takes its hand count. -> (fitted, bound {term: T one line can move it}, hand)."""
    hand = {}
    sig = np.array([r.sigma for r in rows])
    w = 1.0 / sig
    while True:
        terms = [t for t in unknowns if t not in hand]
        fixed = {**held, **{t: HAND[t][0] for t in hand}}
        A = np.array([[r.counts.get(t, 0.0) for t in terms] for r in rows])
        y = np.array([r.T - price(Counter({k: c for k, c in r.counts.items() if k not in terms}), fixed)
                      for r in rows])
        absent = [t for j, t in enumerate(terms) if not np.any(A[:, j])]
        if absent:
            for t in absent:
                if t not in HAND:
                    raise Stop("S4", f"{t}: no S4 row carries it and it has no hand count")
                hand[t] = "no S4 row carries it"
            continue
        Aw = A * w[:, None]
        _u, sv, vt = np.linalg.svd(Aw, full_matrices=False)
        rank = int(np.sum(sv > sv[0] * 1e-10))
        if rank < len(terms):
            weight = np.abs(vt[rank:]).max(axis=0)
            tied = sorted(((weight[j], t) for j, t in enumerate(terms) if weight[j] > 1e-8), reverse=True)
            pick = [t for _w, t in tied if t in HAND]
            if not pick:
                raise Stop("S4", f"the rows cannot separate {[t for _w, t in tied]}, none has a hand count")
            hand[pick[0]] = f"rank {rank} of {len(terms)}: the rows cannot separate it"
            continue
        P = np.linalg.pinv(Aw) * w[None, :]
        x = P @ y
        bound = np.abs(P) @ sig
        for h, e in held_bound.items():
            a_h = np.array([r.counts.get(h, 0.0) for r in rows])
            if e and np.any(a_h):
                bound = bound + np.abs(P @ a_h) * e
        weak = []
        for j, t in enumerate(terms):
            band = term_band(HAND[t][0] if t in HAND else x[j])
            if t in HAND and bound[j] > band:
                weak.append((bound[j] / band, t, bound[j], band))
        if weak:
            _ratio, t, e, band = max(weak)
            hand[t] = f"+-1 line on every row moves it up to {e:.2f} T, over its band {band:.2f} T"
            continue
        return dict(zip(terms, x)), dict(zip(terms, bound)), hand


def _s4_raise(rows, values, fitted, raises):
    """Raise terms, largest shortfall first, until no row prices under. A gapped
    scored row raises col_hop_t; any other row raises the fitted term whose step
    over-prices the other rows least, relative to each row."""
    for _ in range(10000):
        under = [(r.T - price(r.counts, values) - r.band, r) for r in rows]
        under = [(ex, r) for ex, r in under if ex > 1e-9]
        if not under:
            return
        ex, r = max(under, key=lambda p: p[0])
        if r.col_scored and r.counts.get("col_hop_t"):
            term = "col_hop_t"
        else:
            cands = [t for t, c in r.counts.items() if c > 0 and t in fitted]
            if not cands:
                raise Stop("S4", f"{r.label} prices {ex:.1f} T under its band with no fitted term to raise")

            def spill(t):
                step = ex / r.counts[t]
                return max((step * o.counts.get(t, 0.0) / o.base for o in rows if o is not r), default=0.0)
            term = min(cands, key=lambda t: (spill(t), t))
        step = ex / r.counts[term]
        values[term] += step
        raises[term] = raises.get(term, 0.0) + step
    raise Stop("S4", "raises did not converge")


def s4(sit, v):
    """S4 - chunks, seams, columns, edges, passes and entries."""
    split = set(v.get("split", ()))
    held = {t: v[t] for t in S1_TERMS}
    held[REM_TERM] = 0.0
    lines = ["counter-to-term map:"] + counter_map_lines(split)
    try:
        for round_ in range(1, 4):
            unknowns = []
            for t in S4_TERMS + S4_EXTENDED:
                if t in split:
                    unknowns += [t[:-2] + "8_t", t[:-2] + "16_t"]
                else:
                    unknowns.append(t)
            rows = _s4_rows(sit, split)
            fitted, bound, hand = _s4_solve(rows, held, unknowns, {t: v["bounds"][t] for t in S1_TERMS})
            values = {**held, **fitted, **{t: HAND[t][0] for t in hand}}
            under = [(r.T - price(r.counts, values) - r.band, r) for r in rows]
            under = sorted(((ex, r) for ex, r in under if ex > 1e-9), key=lambda p: -p[0])
            lines.append(f"fit {round_}: {len(under)} rows price under before any raise"
                         + "".join(f"; {r.label} {ex:+.1f} T over its {r.band:.1f} T band" for ex, r in under))
            raises = {}
            _s4_raise(rows, values, set(fitted), raises)
            new_split = set(split)
            for term, est in SPLITTABLE.items():
                if term in split:
                    continue
                if abs(values[term] - v[est]) > BAND_OP_T:
                    new_split.add(term)
            if new_split == split:
                break
            split = new_split
            lines += ["counter-to-term map after the split:"] + counter_map_lines(split)
        else:
            raise Stop("S4", "the 8/16-bit split did not settle")
    except Stop as stop:
        stop.notes = lines + stop.notes
        raise
    for term in SPLITTABLE:
        if term in split:
            lines.append(f"S2 check: {term} 8-bit estimate {v[SPLITTABLE[term]]:.1f} T differs from the joint "
                         f"value by more than {BAND_OP_T} T: split into 8-bit and 16-bit variants")
        else:
            lines.append(f"S2 check: {term} {values[term]:.1f} T against the 8-bit estimate "
                         f"{v[SPLITTABLE[term]]:.1f} T: within {BAND_OP_T} T, one term")

    # tail checks at their own select
    tails = {}
    for tag in S4_TAILS:
        c = standalone_counts(tag, split)
        tails[tag] = (sit.T(tag), c)
    tband = {tag: op_band(sit.rows[tag]) for tag in S4_TAILS}
    short = {tag: T - price(c, values) for tag, (T, c) in tails.items()}
    rem = [short[t] for t in ("T299", "T300", "T320") if short[t] > tband[t]]
    if rem:
        values[REM_TERM] = max(rem)
        lines.append(f"tail check: {REM_TERM} = {max(rem):.1f} T, the largest shortfall of T299/T300/T320")
    if short["T298"] > tband["T298"]:
        ldi = "copy_body_ldi16_t" if "copy_body_ldi_t" in split else "copy_body_ldi_t"
        values[ldi] += short["T298"]
        raises[ldi] = raises.get(ldi, 0.0) + short["T298"]
        lines.append(f"tail check: T298 {short['T298']:.1f} T under raises {ldi}")

    out_terms = [t for t in unknowns] + [REM_TERM]
    for t in unknowns:
        if t in hand:
            lines.append(ruling(f"{t} {ceil01(values[t])} T HAND COUNT", f"{hand[t]}; {HAND[t][1]}",
                                "every event on this path misprices by the count's error"))
        else:
            weak = "" if bound[t] <= term_band(values[t]) else f", over its {term_band(values[t]):.2f} T band"
            lines.append(ruling(f"{t} {ceil01(values[t])} T", f"joint least squares over {len(rows)} rows, "
                                f"+-1 line on every row moves it up to {bound[t]:.2f} T{weak}, raised "
                                f"{raises.get(t, 0.0):.2f} T",
                                "every event on this path misprices by the error"))
    lines.append(ruling(f"{REM_TERM} {ceil01(values[REM_TERM])} T", "tail check T299/T300/T320 shortfalls "
                        + ", ".join(f"{t} {short[t]:+.1f}" for t in ("T299", "T300", "T320")),
                        "a DMA remainder chunk after full chunks misprices"))

    # residuals, after every raise
    lines.append("residuals (measured - model, T):")
    bad = []
    for r in rows + [S4Row(t, c, T, 0, tband[t], T, False) for t, (T, c) in tails.items()]:
        m = price(r.counts, values)
        pct = 100.0 * (r.T - m) / r.base
        lines.append(f"  {r.label:<14} measured {r.T:11.1f} model {m:11.1f} residual {r.T - m:+9.1f} "
                     f"({pct:+.2f}% of {r.base:.0f})")
        if abs(r.T - m) > RESID_STOP * r.base:
            bad.append(f"{r.label}: residual {r.T - m:+.1f} T is {pct:+.2f}% of its row: the event model "
                       f"is missing a path")
    for t, amount in sorted(raises.items()):
        lines.append(f"raise: {t} +{amount:.2f} T")
    if bad:
        raise Stop("S4", bad, lines)

    sys_, syn = sit.of("SYS"), [s for s in sit.of("SYN") if s.clip == 1] or sit.of("SYN")
    if not sys_ or not syn:
        raise Stop("S4", "src_seam_strm_t needs a SYS session and SYN 001", lines)
    a = sys_[0].T("C4KP") - sys_[0].T("C4K0")
    b = syn[0].T("C4KP") - syn[0].T("C4K0")
    values["src_seam_strm_t"] = max(0.0, a - b)
    lines.append(ruling(f"src_seam_strm_t {ceil01(values['src_seam_strm_t'])} T",
                        f"({sys_[0].label} C4KP - C4K0 {a:.1f}) - ({syn[0].label} C4KP - C4K0 {b:.1f}), "
                        f"floored at 0", "every source seam on a streamed clip misprices"))
    out = {t: values[t] for t in out_terms + ["src_seam_strm_t"]}
    out["split"] = tuple(sorted(split))
    out["s4_terms"] = tuple(unknowns)
    out["hand"] = dict(hand)
    strm_rows = [sys_[0].rows["C4KP"], sys_[0].rows["C4K0"], syn[0].rows["C4KP"], syn[0].rows["C4K0"]]
    out["bounds"] = {**{t: float(b) for t, b in bound.items()}, **{t: 0.0 for t in hand},
                     "src_seam_strm_t": sum(sigma_rep(r) for r in strm_rows)}
    out["raises"] = raises
    return out, lines


# ---------------------------------------------------------------------------
# S5 - S17
# ---------------------------------------------------------------------------
def s5(sit, v):
    """S5 - audio_factor."""
    ratios, lines = [], []
    for table in ("REAL", "SYN", "SYS", "DS1"):
        for s in sit.of(table):
            for u, a in bench.SESSION_ARMED_PAIRS[table]:
                if u not in s.rows or u in s.invalid or a in s.invalid:
                    continue
                ratios.append((s.T(u) / s.T(a), f"{s.label} {u}/{a}"))
    if not ratios:
        raise Stop("S5", "no armed pairs", lines)
    low, where = min(ratios)
    af = math.floor(100.0 * low) / 100.0
    lines.append(ruling(f"audio_factor {af}", f"floor(100 x min over {len(ratios)} ratios) / 100; "
                        f"min {low:.4f} at {where}", "every usable budget scales by the error"))
    return {"audio_factor": af}, lines


def crossover(rule, name, cpu, dma, lines):
    """L* where the CPU/LDI line a + bL meets the DMA line c + sL; a Stop when
    the lines are near-parallel or meet outside 1..255."""
    a, b = cpu[:2]
    c, s = dma[:2]
    if abs(b - s) < PARALLEL_T_PER_B:
        raise Stop(rule, f"{name}: the lines are near-parallel ({b:.4f} and {s:.4f} T/B)", lines)
    x = (c - a) / (b - s)
    if not 1.0 <= x <= 255.0:
        raise Stop(rule, f"{name}: the lines meet at {x:.1f} B, outside 1..255", lines)
    return x


def search_range(xs):
    """[floor(min), ceil(max)] clamped to 1..255."""
    return max(1, math.floor(min(xs))), min(255, math.ceil(max(xs)))


def _h144_crossover(sit, lines=None):
    ldi = [(bench._row(t)[2], sit.T(t)) for t in (r[0] for r in bench.BENCH_TABLES[10]) if t.startswith("HL")]
    dma = [(bench._row(t)[2], sit.T(t)) for t in (r[0] for r in bench.BENCH_TABLES[10]) if t.startswith("HD")]
    ldi = [p for p in ldi if 144 % p[0]]
    dma = [p for p in dma if 144 % p[0]]
    return crossover("S6", "L*_g144", lsq(ldi), lsq(dma), lines)


def _nearest(grid, x):
    return min(grid, key=lambda g: (abs(g - x), -g))


def _argmin_high(items):
    """{key: value} -> the key of the least value, ties to the higher key."""
    return min(items, key=lambda k: (items[k], -k))


def s6(sit, v):
    """S6 - the COPY threshold."""
    lines = []
    rows = {t: sit.rows[t] for t in fct.FLAT_TAGS | fct.GAPPED_TAGS}
    try:
        res = fct.fit(rows)
    except ValueError as exc:
        raise Stop("S6", f"NXBX fit: {exc}", lines)
    if "error" in res["gapped"]:
        raise Stop("S6", f"NXBG fit: {res['gapped']['error']}", lines)
    cross = {"flat": crossover("S6", "L*_flat", res["ldi"], res["dma"], lines),
             "g192": crossover("S6", "L*_g192", res["gapped"]["ldi"], res["gapped"]["dma"], lines),
             "g144": _h144_crossover(sit, lines)}
    lines.append(ruling("crossovers " + ", ".join(f"L*_{k} {x:.2f} B" for k, x in cross.items()),
                        "fit_copy_threshold lines on Q NXBX and NXBG; NXBH HL/HD lines (L dividing the "
                        "height excluded)", "the search range misses the optimum"))

    def model_n(xs, clips):
        lo, hi = search_range(xs)
        totals = {}
        for n in range(lo, hi + 1):
            totals[n] = model_total(v, clips, lambda surf, n=n: n, bench.NXB_RUN_REF, sit.streaming_of)
        return _argmin_high(totals), totals

    def silicon(sessions):
        return {t: sum(s.T(f"W0{t:02d}") for s in sessions) for t in SWEEP_GRID}

    def rule_n(xs, clips, sessions):
        nm, totals = model_n(xs, clips)
        S = silicon(sessions)
        tstar = _argmin_high(S)
        near = _nearest(SWEEP_GRID, nm)
        n = nm if S[near] <= S[tstar] * S6_TIE_T else tstar
        return n, nm, tstar, near, S, totals

    real = sit.of("REAL")
    flat_s = [s for s in real if not s.surface[2]]
    gap_s = [s for s in real if s.surface[2]]
    flat_c = [c for c in MODEL_CLIPS if not fm.surface_of(fixture_header(fixture_path(c)))[2]]
    gap_c = [c for c in MODEL_CLIPS if c not in flat_c]
    n, nm, tstar, near, S, totals = rule_n(list(cross.values()), MODEL_CLIPS, real)
    lines.append("model decode T over 001-009 at COPY N, RUN 71: "
                 + ", ".join(f"{k} {x:.0f}" for k, x in totals.items()))
    lines.append("silicon S(t) over REAL sessions: " + ", ".join(f"{k} {x:.0f}" for k, x in S.items()))
    n_flat = rule_n([cross["flat"]], flat_c, flat_s)[0]
    n_gap, _nm_g, _t_g, _near_g, S_gap, _tot_g = rule_n([cross["g192"], cross["g144"]], gap_c, gap_s)
    save = S_gap[_nearest(SWEEP_GRID, n)] - S_gap[_nearest(SWEEP_GRID, n_gap)]
    split = abs(n_flat - n_gap) >= S6_SPLIT_MIN and save >= S6_SPLIT_SAVE * S_gap[_nearest(SWEEP_GRID, n)]
    out = {"N": n, "N_m": nm, "t_star": tstar, "N_flat": n_flat, "N_gap": n_gap, "copy_split": split,
           "crossovers": cross}
    lines.append(ruling(f"NXV2_COPY_DMA_MIN {n}", f"N_m {nm} (model optimum); S at nearest grid {near} "
                        f"{S[near]:.0f} against S(t*={tstar}) {S[tstar]:.0f} x {S6_TIE_T} = "
                        f"{S[tstar] * S6_TIE_T:.0f}", "every 59-80 B copy takes the dearer kernel"))
    lines.append(ruling("split" if split else "one constant",
                        f"N_flat {n_flat}, N_gap {n_gap}, |difference| {abs(n_flat - n_gap)} (split at "
                        f">= {S6_SPLIT_MIN}), gapped saving {save:.0f} T of {S_gap[_nearest(SWEEP_GRID, n)]:.0f} "
                        f"(split at {100 * S6_SPLIT_SAVE:.1f}%)", "gapped clips decode at the flat select"))
    s81 = S[81]
    saving = 100.0 * (s81 - S[_nearest(SWEEP_GRID, n)]) / s81
    gap = n - (v["copy_dma_setup"] + v["copy_dma_path_t"]) / (v["fetch_short"] - v["copy_dma_per_b"])
    out.update(saving_pct=saving, gap=gap)
    lines.append(ruling(f"saving against 81 {saving:.3f}%", f"(S(81) {s81:.0f} - S({_nearest(SWEEP_GRID, n)}) "
                        f"{S[_nearest(SWEEP_GRID, n)]:.0f}) / S(81)", "Task 20's evidence line"))
    lines.append(ruling(f"gap {gap:.2f} B", f"N - (copy_dma_setup {v['copy_dma_setup']:.2f} + copy_dma_path_t "
                        f"{v['copy_dma_path_t']:.2f}) / (fetch_short {v['fetch_short']:.4f} - copy_dma_per_b "
                        f"{v['copy_dma_per_b']:.4f})", "Task 20's RULE 1b restatement is off"))
    return out, lines


def _copy_of(v):
    if v.get("copy_split"):
        return lambda surf: v["N_gap"] if surf[2] else v["N_flat"]
    return lambda surf: v["N"]


def s7(sit, v):
    """S7 - the RUN threshold."""
    lines = []
    lines_fit = {}
    for name, cpu, dma in (("flat", "FC", "FD"), ("gapped", "VC", "VD")):
        rows11 = [r for r in bench.BENCH_TABLES[11]]
        c_pts = [(r[2], sit.T(r[0])) for r in rows11 if r[0].startswith(cpu)]
        d_pts = [(r[2], sit.T(r[0])) for r in rows11 if r[0].startswith(dma)]
        a, b, wc = lsq(c_pts)
        c, s, wd = lsq(d_pts)
        x = crossover("S7", f"NXBF {name} L*", (a, b), (c, s), lines)
        lines_fit[name] = (a, b, c, s, x)
        lines.append(f"NXBF {name}: CPU {a:.2f} + {b:.4f} L (worst {wc:.2f}), DMA {c:.2f} + {s:.4f} L "
                     f"(worst {wd:.2f}), L* {x:.2f} B")
    a, b, c, s, _x = lines_fit["flat"]
    f70, f71 = sit.T("F070") - (a + 70 * b), sit.T("F071") - (c + 71 * s)
    lines.append(f"NXBK against the flat lines: F070 {f70:+.2f} T, F071 {f71:+.2f} T")
    if abs(f70) > S7_LINE_AGREE_T or abs(f71) > S7_LINE_AGREE_T:
        raise Stop("S7", f"NXBK F070 {f70:+.2f} T / F071 {f71:+.2f} T off the NXBF flat lines "
                         f"(over {S7_LINE_AGREE_T} T)", lines)
    xs = [lines_fit["flat"][4], lines_fit["gapped"][4]]
    lo, hi = search_range(xs)
    totals = {}
    for m in range(lo, hi + 1):
        totals[m] = model_total(v, MODEL_CLIPS, _copy_of(v), m, sit.streaming_of)
    low = min(totals.values())
    m = min((k for k, x in totals.items() if x == low), key=lambda k: (abs(k - bench.NXB_RUN_REF), -k))
    keep = abs(m - bench.NXB_RUN_REF) <= 1
    value = bench.NXB_RUN_REF if keep else m
    lines.append("model decode T over 001-009 at RUN M: " + ", ".join(f"{k} {x:.0f}" for k, x in totals.items()))
    lines.append(ruling(f"NXV2_RUN_DMA_MIN {value}", f"M {m} over [{lo}, {hi}], "
                        f"a tie taking the minimiser nearest 71 "
                        f"(L*_rf {xs[0]:.2f}, L*_rg {xs[1]:.2f}); |M - 71| {abs(m - 71)} "
                        f"{'<= 1 keeps 71' if keep else '> 1 moves'}", "fills near the crossover take the dearer kernel"))
    return {"M": value, "M_model": m, "run_crossovers": xs}, lines


def _frame_models(sit, s, v, sel):
    _h, _surf, frames = fixture_frames(s.path, *sel)
    return [frame_price(fr, s.surface, s.streaming, v, v["split"]) for fr in frames]


def s8(sit, v):
    """S8 - composition factors."""
    lines, out = [], {}
    af = v["audio_factor"]
    per = {}
    for s in sit.of("REAL"):
        model = _frame_models(sit, s, v, REAL_SEL)
        for tag in ("XA65", "XB65", "XC65"):
            idx = s.rows[tag][0]
            r = s.T(tag) / (model[idx] / af)
            per.setdefault(s.clip, []).append((r, f"{s.label} {tag} frame {idx}"))
            lines.append(f"{s.label} {tag}: frame {idx}, T {s.T(tag):.0f}, model {model[idx]:.0f}, R {r:.4f}")
    factors = {}
    for cls, clips in S8_CLASSES.items():
        got = [x for c in clips for x in per.get(c, [])]
        if not got:
            raise Stop("S8", f"no REAL session in the {cls} class", lines)
        rmax, where = max(got)
        sessions = [s for s in sit.of("REAL") if s.clip in clips]
        aaud = max(s.T("AAUD") for s in sessions)
        period = min(1000.0 / s.fps * CLOCK_KHZ for s in sessions)
        a, b = 1.12 * rmax, rmax * period / (period - aaud)
        factors[cls] = math.ceil(round(100.0 * max(a, b), 6)) / 100.0
        lines.append(ruling(f"TMODEL_COMPOSITION_FACTOR {cls} {factors[cls]}",
                            f"ceil(100 x max(1.12 x R_max {rmax:.4f} = {a:.4f}, R_max x P {period:.0f} / "
                            f"(P - T(AAUD) {aaud:.0f}) = {b:.4f})) / 100; R_max at {where}",
                            "the encode budget's margin is off by the error"))
    out["composition_factor"] = factors
    return out, lines


def usable_budget_t(v, fps, width, height, streaming):
    """Task 21's form: (frame period x audio_factor - glue) / composition factor."""
    glue = v["glue_strm_t" if streaming else "glue_t"]
    factor = v["composition_factor"]["gapped" if enc.is_gapped(width, height) else "flat"]
    return (1000.0 / fps * CLOCK_KHZ * v["audio_factor"] - glue) / factor


def s9(sit, v):
    """S9 - TMODEL_SILICON_R density anchors."""
    lines, raw = [], {}
    af = v["audio_factor"]
    for s in sit.of("REAL"):
        m = s.rows["A065"][0]
        model = _frame_models(sit, s, v, REAL_SEL)[:m]
        r = s.T("A065") / (sum(model) / af)
        w, h = s.hdr["width"], s.hdr["height"]
        density = (sum(model) / m) / usable_budget_t(v, s.fps, w, h, s.streaming)
        key = "gapped" if enc.is_gapped(w, h) else "flat_320" if w == 320 else "flat_256"
        raw.setdefault(key, []).append((density, r, s.label))
        lines.append(f"{s.label}: {m} frames, T(A065) {s.T('A065'):.0f}, model {sum(model):.0f}, "
                     f"R_clip {r:.4f}, density {density:.4f} ({key})")
    anchors = {}
    for key, pts in sorted(raw.items()):
        merged = []
        for d, r, _l in sorted(pts):
            if merged and d - merged[-1][0] <= 0.02:
                merged[-1] = (max(d, merged[-1][0]), max(r, merged[-1][1]))
            else:
                merged.append((d, r))
        anchors[key] = tuple((round(float(d), 3), math.ceil(round(float(r) * 1000, 6)) / 1000) for d, r in merged)
        lines.append(ruling(f"TMODEL_SILICON_R {key} {anchors[key]}",
                            "(density, R_clip) sorted by density, pairs within 0.02 merged at the higher "
                            "density and R: " + ", ".join(f"{l} ({d:.3f}, {r:.4f})" for d, r, l in pts),
                            "streamed clips' busy time misprices"))
    for key in ("flat_256", "flat_320", "gapped"):
        if key not in anchors:
            raise Stop("S9", f"no REAL session anchors class {key}", lines)
    return {"silicon_r": anchors}, lines


def s10(sit, v):
    """S10 - AUDIO_COPY_T_PER_B."""
    per = {s.label: s.T("AAUD") / AUD_PAD_B for s in sit.of("REAL")}
    value = math.ceil(round(10.0 * max(per.values()), 6)) / 10.0
    return {"AUDIO_COPY_T_PER_B": value}, [ruling(
        f"AUDIO_COPY_T_PER_B {value}", f"ceil(10 x max T(AAUD) / {AUD_PAD_B}) / 10 over "
        + ", ".join(f"{k} {x:.3f}" for k, x in per.items()), "the audio phase's share of the frame misprices")]


def s11(sit, v):
    """S11 - SD_WIRE_BYTES_PER_MS, an unarmed rate."""
    lines, rates = [], {}
    for s in sit.of("REAL", "streaming"):
        remn = s.rows["REMN"][1] + (s.rows["REMN"][2] << 16)
        if remn < REMN_MIN_BLOCKS:
            lines.append(f"{s.label}: REMN {remn} blocks under {REMN_MIN_BLOCKS}, excluded")
            continue
        if "PROD" in s.invalid:
            lines.append(f"{s.label}: PROD invalidated by S0, excluded")
            continue
        denom = s.T("PROD") + s.T("PACE") - H_PACE + H_SPIN
        rates[s.label] = 512.0 * CLOCK_KHZ / denom
        ring = s.rows["RING"]
        prefill = ring[1] * 512.0 * FIELD_HZ / ring[2] / 1000.0 if ring[2] else float("nan")
        lines.append(f"{s.label}: REMN {remn}, 512 x 28000 / (T(PROD) {s.T('PROD'):.1f} + T(PACE) "
                     f"{s.T('PACE'):.1f} - {H_PACE} + {H_SPIN}) = {rates[s.label]:.1f} B/ms; prefill "
                     f"cross-check R={ring[1]} blocks over F={ring[2]} fields = {prefill:.1f} B/ms")
    if not rates:
        value = enc.SD_WIRE_BYTES_PER_MS
        lines.append(ruling(f"SD_WIRE_BYTES_PER_MS {value:.1f} held", "no streaming session remains",
                            "the held rate stays unmeasured"))
    else:
        value = float(math.floor(min(rates.values())))
        lines.append(ruling(f"SD_WIRE_BYTES_PER_MS {value:.0f}", "floor of the minimum over "
                            + ", ".join(f"{k} {x:.1f}" for k, x in rates.items()),
                            "streamed encodes over- or under-fill the wire"))
    return {"SD_WIRE_BYTES_PER_MS": value}, lines


def s16(sit, v):
    """S16 - merge exchange rate per shape."""
    rates = {f"{w}x{h}": supply_exchange_t_per_byte(v, w, h) for w, h in S16_SHAPES}
    lines = [ruling(f"supply_exchange_t_per_byte {k} {x:.2f} T/B",
                    f"{CLOCK_KHZ:.0f} / (SD_WIRE_BYTES_PER_MS {v['SD_WIRE_BYTES_PER_MS']:.0f} x "
                    f"silicon_r dense anchor {silicon_r(v['silicon_r'], *map(int, k.split('x')), 1.0):.3f})",
                    "gap merges bridge too much or too little") for k, x in rates.items()]
    return {"supply_exchange": rates}, lines


def s12(sit, v):
    """S12 - fetch selector, FILLMIN, STREAM_RESIDENT_POOL_B."""
    lines, out = [], {}
    tags = ("C001", "C004", "C008", "C016", "C038", "L048", "L056", "L060", "L064", "L072", "L080")
    pts = [(bench._row(t)[2], sit.T(t)) for t in tags]
    _a, one_b, one_w = lsq(pts)
    best = None
    for s in range(16, 81):
        lo = [p for p in pts if p[0] < s]
        hi = [p for p in pts if p[0] >= s]
        if len({x for x, _y in lo}) < 2 or len({x for x, _y in hi}) < 2:
            continue
        la, lb, lw = lsq(lo)
        ha, hb, hw = lsq(hi)
        worst = max(lw, hw)
        if best is None or worst < best[0] - 1e-9:
            best = (worst, s, lb, hb)
    if best and one_w - best[0] > BAND_OP_T:
        out["fetch_selector"] = best[1]
        lines.append(ruling(f"fetch selector L >= {best[1]}: short {best[2]:.4f}, long {best[3]:.4f} T/B",
                            f"two lines split at {best[1]} worst residual {best[0]:.2f} T against one line "
                            f"{one_w:.2f} T: improves {one_w - best[0]:.2f} T > {BAND_OP_T}",
                            "LDI bytes near the split misprice"))
    else:
        out["fetch_selector"] = None
        lines.append(ruling(f"one fetch_long rate {ceil01(v['fetch_long'])} T/B, no selector",
                            f"one line worst residual {one_w:.2f} T (slope {one_b:.4f}); the best split "
                            f"{'at ' + str(best[1]) + ' ' + format(best[0], '.2f') + ' T' if best else 'none'} "
                            f"improves it by no more than {BAND_OP_T} T", "LDI bytes near L = 64 misprice"))
    ex = {**v, **s16(sit, v)[0]}
    lam = ex["supply_exchange"]["320x256"]
    fillmin = None
    for L in range(1, 256):
        if (v["t_op_run"] + L * v["fill_cpu"] + 3 * lam + v["t_op_copy"] + 2 * lam
                <= L * v["fetch_short"] + L * lam):
            fillmin = L
            break
    out["FILLMIN"] = fillmin
    lines.append(ruling(f"FILLMIN {fillmin}", f"smallest L with t_op_run {v['t_op_run']:.2f} + L x fill_cpu "
                        f"{v['fill_cpu']:.4f} + 3 lam + t_op_copy {v['t_op_copy']:.2f} + 2 lam <= L x "
                        f"fetch_short {v['fetch_short']:.4f} + L x lam, lam = supply_exchange_t_per_byte(320, 256) "
                        f"{lam:.2f}",
                        "uniform runs inside a span emit the dearer op"))
    pools = {s.label: s.rows["RING"][3] for key, s in sorted(sit.sessions.items())
             if s.delivery == "resident" and "RING" in s.rows}
    if not pools:
        raise Stop("S12", "no resident session RING row", lines)
    low = min(pools.values())
    banks = min(low + 1 - 1 - 5, POOL_CAP_BANKS)
    out["STREAM_RESIDENT_POOL_B"] = banks * BANK_B
    lines.append(ruling(f"STREAM_RESIDENT_POOL_B {banks} x 16384 = {banks * BANK_B}",
                        f"(min RING D= {low} + 1 bench bank - 1 audio bank - 5 snapshot banks), at most "
                        f"{POOL_CAP_BANKS}; D= per resident session " + ", ".join(f"{k} {x}" for k, x in pools.items()),
                        "a clip that fits resident streams, or one that does not fit loads"))
    return out, lines


def s13(sit, v):
    """S13 - glue budget (recorded by S3)."""
    return {}, [ruling(f"glue budget glue_t {ceil01(v['glue_t'])} T, glue_strm_t {ceil01(v['glue_strm_t'])} T",
                       "recorded by S3; usable_budget_t subtracts it per frame in Task 21",
                       "the usable budget per frame is off by the error")]


def s14(sit, v):
    """S14 - keyframe chunk check on K24K/K43K over every SYN session."""
    lines, raises = [], {}
    values = dict(v)
    for _ in range(1000):
        worst = None
        for s in sit.of("SYN"):
            for tag in ("K24K", "K43K"):
                c = synth_counts("SYN", tag, s.surface, False, v["split"])
                meas = s.T(tag) - s.T("FE00")
                model = price(c, values)
                ex = meas - model - BAND_SESS * s.T(tag)
                if ex > 1e-9 and (worst is None or ex > worst[0]):
                    worst = (ex, s, tag, c)
        if worst is None:
            break
        ex, s, tag, c = worst
        term = "col_hop_t" if s.surface[2] else "dst_seam_t"
        if not c.get(term):
            raise Stop("S14", f"{s.label} {tag} prices {ex:.1f} T under with no {term} event to raise", lines)
        step = ex / c[term]
        values[term] += step
        raises[term] = raises.get(term, 0.0) + step
    for s in sit.of("SYN"):
        for tag in ("K24K", "K43K"):
            c = synth_counts("SYN", tag, s.surface, False, v["split"])
            meas = s.T(tag) - s.T("FE00")
            model = price(c, values)
            lines.append(f"{s.label} {tag}: measured T - T(FE00) {meas:.0f}, priced {model:.0f} "
                         f"({100 * (meas - model) / s.T(tag):+.3f}% of the row)")
    out = {}
    for term, amount in raises.items():
        out[term] = values[term]
        lines.append(ruling(f"{term} {ceil01(out[term])} T", f"raised {amount:.2f} T so no keyframe chunk row prices "
                            f"under", "keyframe chunks decode late"))
    if not raises:
        lines.append(ruling("no raise", "K24K and K43K price within the band on every SYN session",
                            "keyframe chunks decode late"))
    out["raises"] = raises
    return out, lines


def s15(sit, v):
    """S15 - direct-serve transport terms (armed T)."""
    lines, pts = [], []
    read, swept, _blocks = bench.direct_frames("DS1")
    armed_frames = swept[1]
    for s in sit.of("DS1"):
        _h, _surf, frames = fixture_frames(s.path, *bench.SITTING_SELECTS)
        apad = -(-s.hdr["audio_bytes_per_frame"] // 512) * 512
        sizes = {apad + -(-frames[i].nbytes // 512) * 512 for i in armed_frames}
        if len(sizes) != 1:
            raise Stop("S15", f"{s.label}: ADSW frames have section sizes {sorted(sizes)}", lines)
        n = s.rows["ADSW"][0]
        cols = 320 if s.surface[2] else 0
        t_frame = s.T("ADSW") / n
        pts.append((s, sizes.pop(), cols, t_frame))
        lines.append(f"{s.label}: T(ADSW) / {n} = {t_frame:.0f} T, {pts[-1][1]} B, {cols} columns")
    if len(pts) < 3:
        raise Stop("S15", f"{len(pts)} DS1 sessions, three terms", lines)
    A = np.array([[b, c, 1.0] for _s, b, c, _t in pts])
    y = np.array([t for *_x, t in pts])
    x, *_rest = np.linalg.lstsq(A, y, rcond=None)
    sig = np.array([TPL / s.rows["ADSW"][0] for s, *_x in pts])
    fbound = np.abs(np.linalg.pinv(A)) @ sig
    resid = y - A @ x
    worst = max(abs(r) / t for r, t in zip(resid, y))
    lines.append("fit residuals: " + ", ".join(f"{s.label} {r:+.0f} T" for (s, *_x), r in zip(pts, resid)))
    if worst > S15_RESID_STOP:
        raise Stop("S15", f"worst residual {100 * worst:.2f}% of its frame (over {100 * S15_RESID_STOP:.0f}%)",
                   lines)
    names = ("DIRECT_T_PER_B", "DIRECT_COL_T", "DIRECT_FRAME_T")
    vals = dict(zip(names, x))
    lift = max(0.0, max(t - (b * vals[names[0]] + c * vals[names[1]] + vals[names[2]]) - BAND_SESS * t
                        for _s, b, c, t in pts))
    vals["DIRECT_FRAME_T"] += lift
    out = dict(vals)
    out["bounds"] = dict(zip(names, map(float, fbound)))
    out["raises"] = {"DIRECT_FRAME_T": lift} if lift else {}
    for k in names:
        lines.append(ruling(f"{k} {ceil01(out[k])} T", f"least squares over {len(pts)} DS1 sessions "
                            f"{'(raised ' + format(lift, '.1f') + ' T)' if k == 'DIRECT_FRAME_T' and lift else ''}",
                            "direct-serve routes are admitted over or under their wire time"))
    return out, lines


def s17(sit, v):
    """S17 - untouched, with reasons."""
    return {}, [
        ruling("NXV2_DMA_CHUNK stays 240", "the single-byte compares and one fixed number to price",
               "every chunk count and the audio hold-off move"),
        ruling("clock_khz stays 28000", "28 MHz is the slowest CPU clock on core 3.02.04",
               "every T-to-ms conversion scales"),
        ruling("encoder policy untouched", "cap_bytes_frac, close_gaps max_gap, KF_SPAN_PEAK_UTIL, "
               "STREAM_CEILING_UTIL, KF_ROLL_SHARE, KF_CADENCE_S_DEFAULT, the d > 10 / d_now > 12 change "
               "thresholds, the fps/2 refractory window, the max(0.05, ...) budget floor, the keyframe x 0.98 "
               "reserve, the tile and auto-budget policies are policy, not hardware cost",
               "picture tuning moves with no measurement behind it"),
        ruling("AUD_PUMP_CALL_T untouched", "inert: trickle_frac is 0 for every legal file",
               "none while the ring bound holds"),
        ruling("display, palette, format and audio mirrors untouched", "MAX_HEIGHT_BY_WIDTH, pixel aspect, "
               "the transparency remap, the lattice, SILENCE_U8, the direct payload overhead literal are "
               "current", "none measured"),
        ruling("VID_RING_MAX 80 untouched", "a player cap below the pool; S12's pool rule sits below it",
               "none"),
        ruling("the 50 Hz frame ISR unpriced", "the same in armed and unarmed rows, negligible",
               "under 0.1% of a frame"),
    ]


RULES = (("S1", s1), ("S2", s2), ("S3", s3), ("S4", s4), ("S5", s5), ("S6", s6), ("S7", s7),
         ("S8", s8), ("S9", s9), ("S10", s10), ("S11", s11), ("S12", s12), ("S13", s13),
         ("S14", s14), ("S15", s15), ("S16", s16), ("S17", s17))


def ruled_coefficients(v):
    """Every fitted T coefficient as ruled: exact values rounded up to 0.1 T."""
    names = (S1_TERMS + FRAME_TERMS + ("t_palette", "pal_straddle_t", "glue_t", "glue_strm_t")
             + tuple(t for t in v.get("s4_terms", ())) + (REM_TERM, "src_seam_strm_t",
                                                          "DIRECT_T_PER_B", "DIRECT_COL_T", "DIRECT_FRAME_T"))
    return {k: ceil01(v[k]) for k in names if k in v}


def apply_rules(q_text, d_text=None, out=None, **s0_opts):
    """Run S0-S17. -> (values, sitting). Printed lines go to out (a list) as
    they are ruled; a Stop carries them in .printed."""
    printed = out if out is not None else []
    v = {}

    def heading(name, rule):
        return f"== {name} - {rule.__doc__.split(' - ', 1)[1].split(chr(10))[0].rstrip('.')} =="

    name, rule = "S0", s0
    try:
        sit, lines = s0(q_text, d_text, **s0_opts)
        printed += [heading(name, rule)] + lines
        for name, rule in RULES:
            new, lines = rule(sit, v)
            v.setdefault("bounds", {}).update(new.pop("bounds", {}))
            v.setdefault("raises", {})[name] = new.pop("raises", {})
            printed += [heading(name, rule)] + lines
            v.update(new)
        printed.append("== ruled coefficients, rounded up to 0.1 T ==")
        printed += [f"  {k} {x}" for k, x in ruled_coefficients(v).items()]
    except Stop as stop:
        printed += [heading(name, rule)] + stop.notes
        stop.printed = printed
        raise
    return v, sit


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sitting-5 rules S0-S17 over the bench logs; writes nothing.")
    ap.add_argument("q_log")
    ap.add_argument("--anchor", help="NXBENCH-D.TXT, the standard DEBUG image's NXBC")
    ap.add_argument("--no-anchor", action="store_true", help="skip S0's D-image check (testing only)")
    ap.add_argument("--launch-status", action="append", default=[], metavar="[D:]hhhh=OK",
                    help="the owner's note for a launch's last run, by its #NXB stamp (D: the anchor log)")
    args = ap.parse_args(argv)
    try:
        notes = dict(launch_key(item) for item in args.launch_status)
    except ValueError as exc:
        ap.error(str(exc))
    q_text = Path(args.q_log).read_text(encoding="latin-1")
    d_text = Path(args.anchor).read_text(encoding="latin-1") if args.anchor else None
    printed = []
    try:
        apply_rules(q_text, d_text, out=printed, no_anchor=args.no_anchor, launch_status=notes)
    except Stop as stop:
        if printed:
            print("\n".join(printed))
        print(f"STOP {stop.rule}:")
        for line in stop.lines:
            print(f"  {line}")
        return 1
    print("\n".join(printed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
