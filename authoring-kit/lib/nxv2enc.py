"""authoring-kit/lib/nxv2enc.py - NXV v2 encoder pipeline (SP15 T1).

NXV v2 replaces the v1 fixed-container format with a FLIC-lineage delta
opcode stream over the Layer 2 surface, content-triggered keyframes, and
a dual-budget (bytes + modeled decode-T) rate control. This module is
the OFFLINE encoder: header layout, opcode emission, scene segmentation,
scene-scoped palettes, and the rate controller. The wire format this
module writes is defined by docs/superpowers/plans/2026-07-23-sp15-
nxv2.md's "Format reference" section - THAT document is the format
authority; the constants below are its literal transcription (T1 keeps
this module byte-identical to the doc's offset table; src/nextdaad.inc
gets its own equates in Task 3 when the player side is built).

nxv2dec.py is the reference decoder (also this encoder's own
verification decoder) and imports the header/opcode constants from this
module - one source of truth for both sides, as the format reference
directs.

Ported from the SP15 research prototypes (.superpowers/sdd/sp15-
research/, code in the round-2 protovid/ scratch directory: flic2.py's
tuned triggers/threshold ladder, tmodel.py's T-state coefficients,
extract2.py's extraction method) and PRODUCTIONIZED against the real
wire opcodes ($00-$0B) rather than the prototype's own alternating-skip
byte scheme - the prototype measured feasibility in the abstract; this
module emits the actual bytes a Z80 decoder will parse.

Playback model: PATCH-IN-PLACE on a single Layer 2 surface for delta
frames (research finding: the shadow-compose variant is priced out at
320x256@25 - see research-realfootage-results.md finding 4). Keyframes
paint the HIDDEN surface across a KSTART..KFLIP span and flip+palette-
swap atomically on KFLIP.
"""
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover - environment guard
    raise ImportError("nxv2enc requires Pillow (pip install Pillow)") from exc

# ---------------------------------------------------------------------
# Header layout (512 bytes) - literal transcription of the format
# reference's byte-offset table. Every offset/width here MUST match
# that table exactly; the roundtrip selftest (tests/nxv2_selftest.py)
# asserts every one of them.
# ---------------------------------------------------------------------
MAGIC = b"NXVID"
VERSION = 2
HEADER_SIZE = 512

HDR_OFF_MAGIC = 0          # 5  magic "NXVID"
HDR_OFF_VERSION = 5        # 1  version = 2
HDR_OFF_WIDTHCODE = 6      # 1  width code: 0 = 256 (mode-0), 1 = 320 (mode-1)
HDR_OFF_HEIGHT = 7         # 1  height: 1-255 lines, 0 = 256 (free heights)
HDR_OFF_FPSX10 = 8         # 1  fps*10 low byte, informational only
HDR_OFF_ACHAN = 9          # 1  audio channels: 1 mono / 2 stereo
HDR_OFF_ARATE = 10         # 2  audio rate Hz LE
HDR_OFF_FLAGS = 12         # 1  flags (see FLAG_* below)
HDR_OFF_KFPOLICY = 13      # 1  keyframe policy byte (encoder bookkeeping)
HDR_OFF_FRAMES = 14        # 3  frame count LE24
HDR_OFF_ABYTES = 17        # 2  audio bytes/frame LE (pre-pad, as v1)
HDR_OFF_RINGMARGIN = 19    # 2  ring start-margin in 512B blocks LE
HDR_OFF_FRAMECAP = 21      # 2  per-frame payload cap in blocks LE
HDR_RESERVED_START = 23    # .. reserved 0 to 512

WIDTH_BY_CODE = {0: 256, 1: 320}
CODE_BY_WIDTH = {256: 0, 320: 1}

# Layer 2 line counts differ by width: mode-0 (256-wide) has 192 lines,
# mode-1 (320-wide) has 256 lines - height must never exceed the mode's
# actual hardware line count (review finding: all three height-cap call
# sites below used to cap at 256 unconditionally, which let a 256-wide
# shape claim up to 256 lines - 64 lines past what mode-0 can display).
MAX_HEIGHT_BY_WIDTH = {256: 192, 320: 256}

FLAG_DELTA_STREAM = 1 << 0   # always 1 in v2
FLAG_DIRECT_SERVE = 1 << 1   # direct-serve hint
FLAG_BAND_PALETTE = 1 << 2   # RESERVED band-palette experiment

RATE_STEREO = 15625   # 28,000,000/16/112 - matches v1's NXV_RATE_STEREO
RATE_MONO = 23325      # matches v1's NXV_RATE_MONO

KF_POLICY_V2 = 1   # encoder bookkeeping only - the player ignores this byte


def pack_header(*, width, height, fps, channels, arate, frame_count,
                 audio_bytes_per_frame, ring_start_margin_blocks,
                 per_frame_cap_blocks, flags=FLAG_DELTA_STREAM,
                 kf_policy=KF_POLICY_V2):
    """Build the 512-byte NXV v2 header. width must be 256 or 320
    (the only two Layer 2 shapes); height is 1-192 for width 256
    (mode-0, 192 lines) or 1-256 for width 320 (mode-1, 256 lines) -
    256 encodes as the sentinel byte 0, see HDR_OFF_HEIGHT."""
    if width not in CODE_BY_WIDTH:
        raise ValueError(f"width must be 256 or 320, got {width}")
    max_height = MAX_HEIGHT_BY_WIDTH[width]
    if not (1 <= height <= max_height):
        raise ValueError(f"height must be 1-{max_height} for width {width} "
                          f"(Layer 2 mode-{CODE_BY_WIDTH[width]} has {max_height} lines), got {height}")
    if channels not in (1, 2):
        raise ValueError(f"channels must be 1 or 2, got {channels}")
    if not (0 <= frame_count < (1 << 24)):
        raise ValueError("frame_count out of the header's 24-bit range")
    if not (0 <= audio_bytes_per_frame < (1 << 16)):
        raise ValueError("audio_bytes_per_frame out of 16-bit range")
    if audio_bytes_per_frame > AUD_HALF:
        # v2.0 PLAYER BOUND defence-in-depth (3b review minor -> 3c):
        # the player rejects such a header at open (VID FMT?), so no
        # writer may build one. audio_layout() enforces this upstream
        # for every real encode path; this guard catches any future
        # caller that bypasses it.
        raise ValueError(
            f"audio_bytes_per_frame {audio_bytes_per_frame} exceeds the "
            f"NXV v2.0 player bound of {AUD_HALF} bytes (one double-"
            f"buffer half, NXV_AUD_HALF - the player refuses the file "
            f"at open with VID FMT?)")
    if not (0 <= ring_start_margin_blocks < (1 << 16)):
        raise ValueError("ring_start_margin_blocks out of 16-bit range")
    if not (0 <= per_frame_cap_blocks < (1 << 16)):
        raise ValueError("per_frame_cap_blocks out of 16-bit range")

    fps_x10 = int(round(float(fps) * 10))
    if fps_x10 > 255:
        import warnings
        warnings.warn(f"fps*10 ({fps_x10}, fps={fps}) exceeds the header's "
                       f"8-bit fps_x10 field - clamping to 255 (25.5fps); "
                       f"this field is informational only and does not "
                       f"affect playback rate")
        fps_x10 = 255
    elif fps_x10 < 0:
        fps_x10 = 0

    hdr = bytearray(HEADER_SIZE)
    hdr[HDR_OFF_MAGIC:HDR_OFF_MAGIC + 5] = MAGIC
    hdr[HDR_OFF_VERSION] = VERSION
    hdr[HDR_OFF_WIDTHCODE] = CODE_BY_WIDTH[width]
    hdr[HDR_OFF_HEIGHT] = 0 if height == 256 else height
    hdr[HDR_OFF_FPSX10] = fps_x10
    hdr[HDR_OFF_ACHAN] = channels
    hdr[HDR_OFF_ARATE:HDR_OFF_ARATE + 2] = int(arate).to_bytes(2, "little")
    hdr[HDR_OFF_FLAGS] = flags & 0xFF
    hdr[HDR_OFF_KFPOLICY] = kf_policy & 0xFF
    hdr[HDR_OFF_FRAMES:HDR_OFF_FRAMES + 3] = int(frame_count).to_bytes(3, "little")
    hdr[HDR_OFF_ABYTES:HDR_OFF_ABYTES + 2] = int(audio_bytes_per_frame).to_bytes(2, "little")
    hdr[HDR_OFF_RINGMARGIN:HDR_OFF_RINGMARGIN + 2] = int(ring_start_margin_blocks).to_bytes(2, "little")
    hdr[HDR_OFF_FRAMECAP:HDR_OFF_FRAMECAP + 2] = int(per_frame_cap_blocks).to_bytes(2, "little")
    return bytes(hdr)


def unpack_header(buf):
    """Inverse of pack_header. Raises ValueError on bad magic/version/
    width code. Returns a dict with the decoded fields plus
    column_major (True for width==320, Layer 2 mode-1 addressing)."""
    if len(buf) < HEADER_SIZE:
        raise ValueError(f"header buffer too short ({len(buf)} < {HEADER_SIZE})")
    if bytes(buf[HDR_OFF_MAGIC:HDR_OFF_MAGIC + 5]) != MAGIC:
        raise ValueError("bad magic - not an NXVID file")
    version = buf[HDR_OFF_VERSION]
    if version != VERSION:
        raise ValueError(f"unsupported NXV version {version} (this module reads v{VERSION})")
    widthcode = buf[HDR_OFF_WIDTHCODE]
    width = WIDTH_BY_CODE.get(widthcode)
    if width is None:
        raise ValueError(f"bad width code {widthcode} (must be 0 or 1)")
    height_b = buf[HDR_OFF_HEIGHT]
    height = 256 if height_b == 0 else height_b
    return dict(
        width=width, height=height, column_major=(width == 320),
        fps_x10=buf[HDR_OFF_FPSX10],
        channels=buf[HDR_OFF_ACHAN],
        arate=int.from_bytes(buf[HDR_OFF_ARATE:HDR_OFF_ARATE + 2], "little"),
        flags=buf[HDR_OFF_FLAGS],
        kf_policy=buf[HDR_OFF_KFPOLICY],
        frame_count=int.from_bytes(buf[HDR_OFF_FRAMES:HDR_OFF_FRAMES + 3], "little"),
        audio_bytes_per_frame=int.from_bytes(buf[HDR_OFF_ABYTES:HDR_OFF_ABYTES + 2], "little"),
        ring_start_margin_blocks=int.from_bytes(buf[HDR_OFF_RINGMARGIN:HDR_OFF_RINGMARGIN + 2], "little"),
        per_frame_cap_blocks=int.from_bytes(buf[HDR_OFF_FRAMECAP:HDR_OFF_FRAMECAP + 2], "little"),
    )


# ---------------------------------------------------------------------
# Opcodes - literal transcription of the format reference. PRE-SCALED
# BY 4 (SP15 optimization wave, owner-authorized re-encoding): the wire
# byte IS the Z80 player's dispatch offset into a 256-aligned page of
# 4-byte jump stubs (opcode -> stub -> handler with zero multiply, zero
# bounds check - every non-stub offset lands on an error slide). Only
# the VALUES changed; the semantics, operand layouts and ordering are
# the original $00-$0B set times 4. Reserved slots keep their positions
# ($24 = old $09, $2C = old SCROLL $0B). Any byte outside the set below
# (including non-multiples of 4) is reserved and rejected by the
# reference decoder.
# ---------------------------------------------------------------------
OP_FEND = 0x00     # frame end - rest of block is padding
OP_SKIP16 = 0x04   # cursor += nn (LE, 2 bytes)
OP_RUN8 = 0x08     # n (1-255) bytes of colour c
OP_RUN16 = 0x0C    # nn (LE) bytes of colour c
OP_COPY8 = 0x10    # n (1-255) literal bytes follow
OP_COPY16 = 0x14   # nn (LE) literal bytes follow
OP_PAL = 0x18      # full 512-byte palette block, NR $44 order
OP_SKIP8 = 0x1C    # cursor += n (1-255)
OP_KFLIP = 0x20    # end of final keyframe chunk: atomic flip + palette swap
OP_KSTART = 0x28   # begin keyframe span: target = hidden surface; cursor = 0
OP_SCROLL = 0x2C   # RESERVED, unimplemented in v2.0 - encoder never emits

VALID_OPS = frozenset({OP_FEND, OP_SKIP16, OP_RUN8, OP_RUN16, OP_COPY8,
                        OP_COPY16, OP_PAL, OP_SKIP8, OP_KFLIP, OP_KSTART})
TERMINAL_OPS = frozenset({OP_FEND, OP_KFLIP})

PAL_BLOCK_SIZE = 512

# ---------------------------------------------------------------------
# TMODEL_COEFFS - Z80N decode+fetch T-state costs. SILICON-SETTLED on the
# SECOND NXBEN sitting (core 3.02.04 KS3 TEST core, 2026-07-25), which
# benched the OPTIMIZED decode kernels (commits bfadc71 + 5cc2c70):
# .superpowers/sdd/task-2-final-settlement.md. Every entry cites its bench
# row and the first-sitting value it replaces. The kernel wave did what it
# claimed: the per-op dispatch envelope went 920 -> 267 T (copy) / 387 T
# (run) and the SKIP8 envelope 360 -> 130 T, so the rate control now prices
# with the optimized silicon truth. Whole-model cross-check: feeding these
# coefficients through the SEG row's manifest op counts reproduces the
# measured 3-frame mixed stream to +0.5%.
#
# Envelope convention (unchanged): the dispatch envelopes are measured on
# real ops that already carry their count byte, so the count-byte parse is
# FOLDED INTO them - header_rate stays 0 to avoid double-counting.
# ---------------------------------------------------------------------
TMODEL_COEFFS = {
    "fetch_long": 20.2,        # T/byte LDI copy body [SILICON C8/C16 joint solve,
                                #   sitting 2: 20.25 incl ~0.13 of window-seam
                                #   cost; body preserved by the wave exactly as
                                #   promised]. sitting 1: 20.2. model was 22.1
    "fetch_short": 20.2,        # T/byte [SILICON]. No separate short-burst body
                                #   penalty exists: C8's 21.6 T/B row is fully the
                                #   267 dispatch amortized over 192B + 20.2 body;
                                #   burst size is dispatch, priced separately
    "t_skip": 130.0,            # SKIP8 op envelope [SILICON SK8 row sitting 2:
                                #   129.9 T incl its count byte; hand count 121].
                                #   sitting 1: 360. model was 45. NOTE the SKIP16
                                #   op measures 295 T (S16 row), inflated by the
                                #   8K window seams the 1024B skips cross - the
                                #   single-key model prices both at the SKIP8
                                #   value (disclosed under-price for 16-bit skips,
                                #   bounded: skips are the cheapest ops)
    "t_op_parse": 387.0,        # copy/run/pal per-op dispatch envelope [SILICON
                                #   sitting 2: RUN8 solve 387 (hand count 383),
                                #   COPY8/COPY16 solve 267 (hand count 267)]. The
                                #   single-key model takes the MORE EXPENSIVE
                                #   class - conservative for feasibility; the run
                                #   envelope carries the computed-entry fill setup
                                #   that the copy path does not. sitting 1: 920.
                                #   model was 50. body priced separately
    "fill_cpu": 17.0,           # T/byte unrolled CPU fill [SILICON R8U/R6U joint
                                #   solve sitting 2: 17.17 incl ~0.13 seam cost;
                                #   body unchanged by the wave as promised].
                                #   sitting 1: 17.0. model was 13.2
    "fill_dma_per_b": 5.1,      # T/byte DMA fill body [SILICON RD chunk solve
                                #   sitting 2, over-determined against the DMA-copy
                                #   KF/CD3 cross-row solve]. Hardware term - the
                                #   wave cannot change it; sitting 1's 4.5 was an
                                #   artifact of attributing 920 T/op. model was 4.0
    "fill_dma_setup": 849.0,    # T per 256B DMA fill chunk [SILICON RD1/RD2/RD3
                                #   solve sitting 2 - both chunk differences give
                                #   849.4 exactly; persistent-descriptor re-arm].
                                #   sitting 1: 1273. hand count 683. model was 355
    "fill_dma_min": 256,        # DMA fill chunk size (bytes); also the audio-safety
                                #   cap (512B bursts starve the sample ISR - 35%
                                #   tick shortfall, both sittings). DMA beats CPU
                                #   fill at L >= 849/(17.0-5.1) = ~71 B
    "header_rate": 0.0,         # count/colour byte parse - FOLDED into the
                                #   dispatch envelopes above on silicon (see the
                                #   envelope-convention note). model was 26.0
    "t_frame_fixed": 1132.0,    # frame-fixed floor [SILICON FE row sitting 2:
                                #   1132.4 T, inside the 1050-1200 hand count].
                                #   Still a conservative overestimate of the
                                #   PLAYER's own fixed cost - the FE row carries
                                #   ~500 T of bench harness on top of it, which
                                #   leaves headroom for the Task 3 player's real
                                #   per-frame work (ring bookkeeping, audio
                                #   hand-off) the bench does not model.
                                #   sitting 1: 1735. model was 1000
    "t_palette": 512 * 22.1 + 256 * 20.0,  # 16435 T - MODEL value kept: no
                                #   silicon PAL row exists in either sitting; the
                                #   wave's unrolled outinb path makes this an
                                #   overestimate. PAL is <0.2% of any frame
    "clock_khz": 28000.0,       # T per ms at 28MHz
    "audio_factor": 0.85,       # usable budget after the armed-decode audio tax
                                #   [SILICON sitting 2: CD armed/unarmed = 1.170-
                                #   1.173 at c64/c128/c256 -> 0.853; held at 0.85].
                                #   sitting 1: 0.85. model was 0.89
}


# ---------------------------------------------------------------------
# TMODEL_COMPOSITION_FACTOR - the COMPOSED-PLAYER safety factor.
#
# TMODEL_COEFFS above are micro-bench truths: isolated kernels, isolated
# dispatch, one op class at a time. The real player composes them - fast
# handler vs chunked body selection, dest-cursor normalization, column
# hops, window-seam walks, the audio-ring interleave and the per-frame
# glue the bench cannot see. The stage-3a real-footage silicon leg
# (2026-07-25, core 3.02.04 KS3 TEST, five staged fixtures sd\001-005,
# DEBUG timeline DECODE rows) measured that composition tax directly:
#
#   R = (silicon DECODE T/frame) / (model T/frame / audio_factor)
#   silicon T/frame = DECODE ticks / FRM * 1792 T   (CTC /16 x TC 112)
#
#   AF CONVENTION (cross-refer stream_supply_check's own note at :447):
#   this formula divides the MODEL side by audio_factor before taking
#   the ratio - af is folded into R's own calibration, once, here. The
#   R values below feed TMODEL_SILICON_R, which stream_supply_check()
#   later multiplies straight onto the RAW (undivided) model T/frame,
#   applying audio_factor separately and only to the wire (SD fetch)
#   term instead. Those are two DIFFERENT placements of the same af,
#   not one convention used twice - see :447 for why they must not be
#   reconciled without re-fitting both against the silicon anchors.
#
#   | fixture | shape             | gap | model T/f | silicon T/f | R     |
#   |---------|-------------------|-----|-----------|-------------|-------|
#   | 001.VID | 320x256 mode-1    | no  |   778,161 |     822,105 | 0.898 |
#   | 002.VID | 256x192 mode-0    | no  |   488,954 |     479,700 | 0.834 |
#   | 003.VID | 320x192 mode-1 LB | YES |   887,452 |   1,250,890 | 1.199 |
#   | 004.VID | 320x144 mode-1 LB | YES |   577,674 |     952,053 | 1.401 |
#   | 005.VID | 256x144 mode-0    | no  |   548,298 |     488,858 | 0.760 |
#
# The rows split into two clean clusters on ONE discriminator: the
# mode-1 letterbox column gap. Flat surfaces (any width, any mode) come
# in UNDER the model (0.76-0.90 - the model over-prices copies at the
# 387 T run envelope). Gapped surfaces cost 1.20-1.40x the model,
# because every op whose length crosses a column boundary leaves the
# SMC'd fast handler and rides the chunked body (normalize + hop +
# multiple chunk sizings). Shorter columns cross more often, which is
# why 004 (h=144) is worse than 003 (h=192). 001 is 320-wide mode-1 and
# FLAT, so this is the column gap and not a mode-1 display-fetch term.
#
# The factor DIVIDES the usable budget, so it is a straight de-rating of
# the modeled-T cap. A frame emitted at the de-rated cap is predicted to
# consume R/FACTOR of one frame period on silicon, leaving real PACE
# margin on both classes.
#
# Calibrated at gapped heights 144 and 192. A NEW gapped height below
# 144 must be re-checked on silicon before it is trusted (the crossing
# rate scales roughly with 1/height).
#
# ---------------------------------------------------------------------
# GAPPED RE-SETTLEMENT (SP15 Card #5, 2026-07-26, core 3.02.04) - the
# COLUMN-HOP payback. Stage 3c gave the gapped fast handlers an INLINE
# single-crossing column hop, so a crossing op no longer falls into the
# chunked bodies. Card #5 re-measured R on the SAME staged streams
# (sd\003/004/006, byte-identical since Card #2 - no re-encode enters
# the ratio), same formula, same 1792 T tick:
#
#   | fixture | shape         | model T/f | silicon T/f | R post | R pre |
#   |---------|---------------|-----------|-------------|--------|-------|
#   | 003.VID | 320x192 LB    |   585,811 |     692,572 | 1.005  | 1.064 |
#   | 004.VID | 320x144 LB    |   561,298 |     675,417 | 1.023  |   -   |
#   | 006.VID | 320x192 LB TC |   251,202 |     566,172 | 1.916  | 2.015 |
#   | 001/002/005 (flat, regression) 0.898 / 0.847 / 0.757 - UNMOVED   |
#
# The dense real-footage gapped rows collapsed onto the flat cluster:
# 1.20/1.40 -> 1.005/1.023. The hop is worth 41,001 T/frame on 003
# (5.6%) and 29,360 T/frame on 006 (4.9%) against the same streams.
#
# TWO REGIMES, and the factor is calibrated on the one the cap governs:
#   - DENSE (003/004): frames are budget-BOUND (22 of 25 on 003), so
#     their mean IS their at-cap cost. R 1.005-1.023. These are the
#     rows a cap de-rating must answer to.
#   - SPARSE (006, the test card): 90% of the surface is skipped every
#     frame and the model prices it at 251 kT while silicon spends
#     566 kT - R 1.92, twice out of family. DISCLOSED MODEL WEAKNESS,
#     not a cap hazard: a sparse frame is cheap in ABSOLUTE terms
#     (006 measures 20.2 ms of a 40 ms period, PACE 285 ticks), and
#     sparseness bounds the byte demand in the same breath. The two
#     gapped operating points are 2 clusters, not a curve - do NOT
#     read a law into them; a third, genuinely intermediate gapped
#     density would be the row that settles the shape.
# Factor = worst DENSE gapped R x the same ~11% margin the 2026-07-25
# calibration used: 1.023 x 1.12 = 1.15.
# ---------------------------------------------------------------------
TMODEL_COMPOSITION_FACTOR = {
    "flat":   1.00,   # worst observed 0.898 (001) - 11% margin, and the
                       #   model is conservative here by construction
    "gapped": 1.15,   # worst observed DENSE 1.023 (004, h=144) - 12%
                       #   margin [Card #5 post-column-hop re-measure,
                       #   2026-07-26]. Was 1.55 (pre-hop worst 1.401).
                       #   Gapped cap @25fps: 614,194 -> 827,826 T
}


def is_gapped(width, height):
    """True for a mode-1 (320-wide) LETTERBOX surface, whose columns are
    256-aligned so a sub-256 content height leaves a gap after every
    column. Mirrors the player's own vidP_GapFlag derivation
    (src/video.asm: mode-1 and height byte != 0/256). Mode-0 (256-wide)
    is row-linear and never gapped, whatever the height."""
    return int(width) == 320 and int(height) != 256


def composition_factor(width=None, height=None):
    """Composed-player de-rating for this surface shape. Shape unknown
    (the legacy one-argument call) -> the GAPPED (pessimistic) factor,
    not the flat one: an unset shape must fail safe toward the de-rated
    budget rather than silently handing back the optimistic 1.00 a
    gapped surface would then blow through."""
    if width is None or height is None:
        return TMODEL_COMPOSITION_FACTOR["gapped"]
    return TMODEL_COMPOSITION_FACTOR["gapped" if is_gapped(width, height) else "flat"]


def frame_period_t(fps):
    return 1000.0 / float(fps) * TMODEL_COEFFS["clock_khz"]


def usable_budget_t(fps, width=None, height=None):
    """Usable decode T per frame after the audio ISR tax AND the
    composed-player safety factor for this surface shape."""
    return (frame_period_t(fps) * TMODEL_COEFFS["audio_factor"]
            / composition_factor(width, height))


# ---------------------------------------------------------------------
# STREAMING SUPPLY MODEL (SP15 3b silicon follow-up, Card #3 VSTR1).
#
# A ring-streamed file must be PRODUCIBLE, not just decodable: the SD
# producer runs only in the pace slack a frame leaves, so the mean
# demand (audio pad + padded payload per frame) must fit
#
#   busy_ms + demand_bytes / (wire * audio_factor)  <=  frame period
#
# The dual budget (bytes + decode-T) bounds PER-FRAME peaks only; it
# happily emits every frame AT the decode-T cap, which leaves ~zero
# pace slack - exactly what shipped in the first -VidLong 008/009
# encodes (mean busy modeled 39.5 ms of a 40 ms period). On silicon
# that collapses into a chronic gate-driven regime: frame time =
# busy + demand/wire, observed on Card #3 as VSTR1's ~1023-tick
# (65.5 ms) frames with an underrun every frame and RING min depth 1.
# The T1 placeholder note ("ring sizing against real prefetch cost
# may refine this") was never followed up - this check is that
# follow-up, silicon-calibrated:
#
#   - wire floor 1264 KB/s: Card #3 FILL row (full-ring prefill).
#   - the ISR audio tax (audio_factor) applies to the pace-window
#     reads as well - the producer's ini loops are CPU-driven.
#   - busy uses TMODEL_SILICON_R, the MEASURED composed-player
#     ratios from the stage-3a five-fixture table above - NOT the
#     margined COMPOSITION factor, which de-rates the encode budget
#     and would reject silicon-healthy encodes here (feasibility
#     wants the honest estimate, budget de-rating wants the margin).
#
# Calibration anchors (Card #3 silicon, 2026-07-25):
#   007 classic  utilization 1.00 -> HEALTHY (period 623.8/625 ticks,
#                0 underruns - at capacity, and it held)
#   008 full     utilization 1.74 -> COLLAPSED (predicted equilibrium
#                ~70 ms/frame vs 65.5 observed; min depth 1)
# The infeasibility line is utilization > 1.0; STREAM_WARN_UTIL warns
# above 0.90 (at-capacity encodes have no burst margin beyond the
# ring). Files at or below STREAM_RESIDENT_POOL_B load RESIDENT on
# the reference fresh-boot 2MB machine and skip the check (smaller
# pools stream them too, disclosed on the leg card as underrun-prone).
# ---------------------------------------------------------------------
# SPARSE-GAPPED CAVEAT (Card #5): the gapped rows below are the DENSE
# real-footage measurement. A SPARSE gapped stream (006-class: most of
# the surface skipped every frame) runs R ~1.92, so busy_ms below is
# ~2x optimistic for such content. It is not a streaming hazard because
# the two terms are anti-correlated - sparseness that inflates R also
# collapses the byte demand the wire term prices: a 006-class streamed
# clip totals busy 20.2 ms + SD 6.0 ms = 0.66 utilization on the
# measured numbers. Disclosed, not machined around (cf. the SKIP16
# under-price, task-2-final-settlement section 5.3).
TMODEL_SILICON_R = {
    "flat_256": 0.84,   # measured 0.834 (002, 256x192) / 0.760 (005)
    "flat_320": 0.90,   # measured 0.898 (001, 320x256 flat)
    "gapped_192": 1.01,  # measured 1.005 (003, 320x192 LB) [Card #5
                          #   post-column-hop; was 1.20 pre-hop]
    "gapped_144": 1.03,  # measured 1.023 (004, 320x144 LB) [Card #5;
                          #   was 1.40 pre-hop]
}

SD_WIRE_BYTES_PER_MS = 1264 * 1024 / 1000.0   # silicon prefill floor -
                                                # ~22.1 T/byte as originally
                                                # documented (research-decode-
                                                # models.md); the SECOND NXBEN
                                                # sitting's settled PF row (see
                                                # TMODEL_COEFFS docstring)
                                                # measured 10,609 T/512B block
                                                # = 20.72 T/byte, ~7% cheaper -
                                                # this constant is left at the
                                                # OLDER, more conservative
                                                # figure deliberately: it is
                                                # part of the same silicon-
                                                # anchor fit as the af
                                                # convention note at :447, and
                                                # moving it to 20.72 without
                                                # re-checking the 007/008
                                                # anchors would shift
                                                # utilization for every file
STREAM_RESIDENT_POOL_B = 78 * 16384            # fresh-boot 2MB pool ring
STREAM_WARN_UTIL = 0.90
STREAM_TARGET_UTIL = 0.90                       # suggestion target


def silicon_r(width, height):
    """Measured composed-player decode ratio (silicon/model) for this
    shape cluster. Gapped surfaces interpolate on height between the
    two measured letterbox rows, 144-192 - the SETTLED, MEASURED
    cluster (Card #5 settlement, 2026-07-26, R 1.005-1.023; see
    .superpowers/sdd/card5-settlement-report.md section 1). Below 144
    is UNMEASURED: the settled slope is ~0.02 R per 48 lines, so the
    naive formula is only ~1.05-1.06 there and would hand out
    optimistic extrapolation over a region the silicon rows never
    covered. Floor it instead, at TMODEL_COMPOSITION_FACTOR["gapped"]'s
    worst-dense basis (1.15), until a sub-144 silicon row lands."""
    if not is_gapped(width, height):
        return TMODEL_SILICON_R["flat_320" if int(width) == 320 else "flat_256"]
    h = int(height)
    if h >= 192:
        return TMODEL_SILICON_R["gapped_192"]
    r = (TMODEL_SILICON_R["gapped_192"]
         + (192 - h) / 48.0 * (TMODEL_SILICON_R["gapped_144"]
                                - TMODEL_SILICON_R["gapped_192"]))
    if h < 144:
        return max(r, 1.15)
    return r


def stream_supply_check(mean_t, mean_demand_bytes, audio_pad_bytes, fps,
                         width, height):
    """Mean-rate streaming feasibility for an emitted stream. mean_t =
    mean modeled decode T/frame (TMODEL prices), mean_demand_bytes =
    mean (audio pad + 512-padded payload) per frame. Returns a dict:
    utilization (busy + SD time over the frame period; > 1.0 is
    unstreamable), busy_ms, sd_ms, period_ms, demand_kbs, and
    suggested_budget (the --stream-budget scale that lands the mean at
    STREAM_TARGET_UTIL, from the audio-demand-invariant solve)."""
    af = TMODEL_COEFFS["audio_factor"]
    clock = TMODEL_COEFFS["clock_khz"]
    period_ms = 1000.0 / float(fps)
    wire_eff = SD_WIRE_BYTES_PER_MS * af
    # AF CONVENTION (documented, not a bug - review closure Important 2):
    # audio_factor de-rates ONLY the wire (SD fetch) term above, via
    # wire_eff. The busy (decode) term below multiplies silicon_r()
    # straight onto mean_t, the RAW model T/frame - audio_factor never
    # touches it. This is NOT the same convention as the R formula that
    # produced these silicon_r/TMODEL_SILICON_R values in the first
    # place (TMODEL_COMPOSITION_FACTOR block above, :296ish:
    # R = silicon / (model / audio_factor) - af divides the MODEL side
    # there, before the ratio is taken).
    #
    # The wire floor SD_WIRE_BYTES_PER_MS is ALSO not the settled
    # silicon figure - it keeps the older, ~7% more conservative value
    # (see its own definition comment above).
    #
    # Both of these - the af placement here and the wire floor's
    # conservatism - are CO-FITTED to the Card #3 silicon anchor points
    # (007 classic healthy at util ~1.00, 008 full collapsed at ~1.74),
    # not independently derived from first principles. A maintainer who
    # "corrects" only one of them - e.g. dividing mean_t by af here to
    # literally match the :296 R formula, or swapping in the settled
    # 20.72 T/B wire figure - without re-fitting the other and
    # re-checking both anchors will shift busy_ms/sd_ms and can refuse
    # silicon-healthy encodes (007-class files) for no silicon reason.
    # Change both together, against the anchors, or change neither.
    busy_ms = mean_t * silicon_r(width, height) / clock
    sd_ms = mean_demand_bytes / wire_eff
    util = (busy_ms + sd_ms) / period_ms
    # scaling the operating point scales busy and the payload part of
    # demand; the audio pad is invariant
    audio_sd_ms = audio_pad_bytes / wire_eff
    payload_sd_ms = sd_ms - audio_sd_ms
    scalable = busy_ms + payload_sd_ms
    suggested = ((period_ms * STREAM_TARGET_UTIL - audio_sd_ms) / scalable
                 if scalable > 0 else 1.0)
    return dict(utilization=util, busy_ms=busy_ms, sd_ms=sd_ms,
                period_ms=period_ms,
                demand_kbs=mean_demand_bytes * float(fps) / 1024.0,
                suggested_budget=max(0.05, min(1.0, suggested)))


# ---------------------------------------------------------------------
# LIMITATION (documented, not implemented - review closure Important 3;
# future work, SP15 3c/T4 candidate): stream_supply_check() above is a
# WHOLE-CLIP MEAN criterion. encode()'s gate divides total projected
# demand and total modeled decode-T by the frame count and compares that
# single mean against one frame period - it has no notion of WHEN in the
# clip the demand lands, only how much of it there is on average.
#
# Two consequences, both currently invisible to the gate:
#   - A sustained high-demand run SHORTER than roughly one ring-depth's
#     worth of frames is absorbed by the ring's own buffering and never
#     underruns, even while its INSTANTANEOUS utilization is well over
#     1.0 - only an excursion that outlasts the ring's absorption
#     capacity actually starves playback. At 008-class heavy demand
#     (~85 blocks/frame) a ring holding ~2495 blocks (Card #3) absorbs
#     roughly 2495/85 =~ 29 frames of such an excursion before it would
#     underrun. A clip whose MEAN is comfortably admissible can still
#     contain a shorter high-demand run the mean never sees.
#   - Keyframe span chunks are deliberately NOT scaled by
#     --stream-budget (encode_clip: rare, ring-amortized on average) -
#     which also means cut-heavy content (frequent keyframes) clusters
#     its highest-demand frames together rather than spreading them out,
#     exactly the excursion shape the whole-clip mean cannot see.
#
# suggested_budget above is ADVISORY, not exact: it is one linear solve
# against the mean-rate invariant (scale busy_ms and the payload part of
# sd_ms, hold the audio pad fixed). Payload size does not respond to
# --stream-budget linearly in practice (a smaller byte/T cap changes
# which frames fall back to fewer changed pixels, coarser fill choices,
# etc.), so a second encode-and-recheck iteration may be needed to land
# inside the target utilization band, particularly after a large
# suggested change.
#
# A WINDOWED/BURST criterion - checking utilization over a sliding
# window sized to the ring depth, not just the whole-clip mean - would
# close both gaps. Out of scope here. (3c note, carried per the stage
# queue: this limitation is DOCUMENTED-ACCEPTED for v2.0 - the direct-
# serve gate below deliberately uses the WORST frame instead, because
# direct delivery has no ring to absorb excursions at all.)
# ---------------------------------------------------------------------


# ---------------------------------------------------------------------
# DIRECT_TRANSPORT_FACTOR - the direct-serve TRANSPORT GLUE term, and
# the 3c gate's one omission. SILICON-SETTLED on Card #5 (2026-07-26,
# core 3.02.04), the first hardware run of the direct path:
#
#   | leg   | FRM  | ticks/frame | ms/frame | B/frame | delivered   |
#   |-------|------|-------------|----------|---------|-------------|
#   | VDIR  |  250 |     663.37  |  42.456  | 38,932  | 916.99 B/ms |
#   | VDIRL | 1016 |     663.60  |  42.470  | 38,932  | 916.69 B/ms |
#
# The 3c gate priced the frame at SD_WIRE_BYTES_PER_MS * audio_factor =
# 1100.19 B/ms and stated that "decode-side overhead beyond the wire is
# second-order ... covered by the same conservative wire floor". IT IS
# NOT. Measured / modeled = 1100.19 / 917 = 1.200 on BOTH legs
# independently (agreement 0.03%), i.e. the direct transport delivers
# only 83% of the bare wire rate. What the missing 20% is:
#   - vid_ds_blkopen once per 512 B block (76 per frame here): previous
#     block's 2 CRC bytes drained off the wire, section-bound + pass-
#     remain accounting, filemap run bookkeeping, and the BOUNDED DATA
#     TOKEN WAIT - the card's own inter-block gap inside an open CMD18
#     window, which no per-byte rate can express;
#   - vid_ds_xfer re-arms inir every <= 256 B (144 arms/frame) with a
#     min/clip chain and two 16-bit sbc pairs per arm;
#   - section padding (793 B/frame here) is discarded through
#     vid_ds_pad's byte loop at ~37 T/B, not through inir's 21 T/B;
#   - vid_ds_copy_body's dest-normalize + chunk walk per segment, and
#     the always-slow op parse (KSTART/COPY/KFLIP, +PAL on cuts).
# All of it scales with BLOCKS, not with picture content, which is why
# one factor on the byte demand reproduces both legs: the recalibrated
# model predicts 010's ordinary (no-palette) frame at 42.44 ms against
# 42.456 measured (0.03%), and its scene-start frame at 43.00 ms - the
# gate's own worst-frame criterion. Same silicon-anchoring discipline
# as the streaming
# gate carries - and like it, the factor is CO-FITTED to the wire floor
# above: do not move SD_WIRE_BYTES_PER_MS without re-deriving this.
DIRECT_TRANSPORT_FACTOR = 1.20

# Policy line (OWNER-FACING, Card #5 TIGHTEN ruling, 2026-07-26): at
# 1.20 the shipped 010 fixture (classic-wide 256x144 @25 stereo) scored
# 1.075 - it would have played ~6% slow, which is what silicon does.
# The owner ruled STRICT: direct-serve is on-rate or it is refused,
# full stop. There is NO accept-slow override - a utilization > 1.0
# ALWAYS raises SystemExit; see _encode_direct. (010/011 were
# re-encoded inside the envelope rather than shipped slow.)


def direct_supply_check(worst_frame_bytes, fps):
    """Direct-serve wire feasibility (SP15 3c, RECALIBRATED Card #5). A
    direct-serve session reads every byte of a frame section (audio
    blocks + payload blocks, padding included) off the SD wire INSIDE
    that frame's own period - the literal bytes are served straight to
    the surface (inir transport, the whole point of the mode), and
    there is NO ring to absorb bursts. The criterion is therefore the
    WORST frame, not the clip mean (contrast stream_supply_check's
    documented mean-rate limitation above). audio_factor de-rates the
    wire exactly as the streaming gate does - the ISR sample tax
    applies to the inir transport identically - and
    DIRECT_TRANSPORT_FACTOR carries the per-block/per-arm transport
    glue the first silicon rows measured (see its block above; the 3c
    gate omitted it and ran 20% optimistic)."""
    af = TMODEL_COEFFS["audio_factor"]
    period_ms = 1000.0 / float(fps)
    sd_ms = (worst_frame_bytes * DIRECT_TRANSPORT_FACTOR
             / (SD_WIRE_BYTES_PER_MS * af))
    return dict(utilization=sd_ms / period_ms, sd_ms=sd_ms,
                period_ms=period_ms,
                demand_kbs=worst_frame_bytes * float(fps) / 1024.0)


def direct_max_raw_bytes(fps, channels=2, util=1.0):
    """Largest RAW surface (width*height) a direct-serve encode can
    carry at this fps/channel count and utilization target, under the
    recalibrated gate. Inverse of direct_supply_check: the frame
    section is audio_pad + 512-rounded(payload), and the payload is
    KSTART(1) + PAL(1+512) + COPY16(3) + raw + terminal(1)."""
    period_ms = 1000.0 / float(fps)
    budget_b = (period_ms * util * SD_WIRE_BYTES_PER_MS
                * TMODEL_COEFFS["audio_factor"] / DIRECT_TRANSPORT_FACTOR)
    # the audio pad comes from audio_layout, NOT a local rate guess -
    # mono runs at RATE_MONO (23325), not the stereo 15625, so a local
    # copy of that arithmetic gets the mono envelope wrong
    apad = audio_layout(fps, channels)[3]
    payload_blocks = int((budget_b - apad) // 512)
    return max(0, payload_blocks * 512 - (1 + 1 + PAL_BLOCK_SIZE + 3 + 1))


# ---------------------------------------------------------------------
# Low-level op emission + costing. Any run/skip/copy segment longer than
# a single op's count field is CHUNKED into consecutive ops of the same
# kind (matches _chunk_lengths below) - correctness never depends on
# the 64-byte DMA threshold, only on the count-field width.
# ---------------------------------------------------------------------

def _chunk_lengths(n):
    """Split n into a list of op-sized chunks: the terminal chunk uses
    the 8-bit count field (<=255) whenever what remains already fits;
    every earlier chunk is a 16-bit count field chunk (<=65535)."""
    out = []
    n = int(n)
    while n > 0:
        if n <= 255:
            out.append(n)
            n = 0
        else:
            c = min(n, 65535)
            out.append(c)
            n -= c
    return out


def op_skip(n):
    parts = []
    for L in _chunk_lengths(n):
        if L <= 255:
            parts.append(bytes([OP_SKIP8, L]))
        else:
            parts.append(bytes([OP_SKIP16]) + L.to_bytes(2, "little"))
    return b"".join(parts)


def op_run(n, colour):
    parts = []
    for L in _chunk_lengths(n):
        if L <= 255:
            parts.append(bytes([OP_RUN8, L, colour & 0xFF]))
        else:
            parts.append(bytes([OP_RUN16]) + L.to_bytes(2, "little") + bytes([colour & 0xFF]))
    return b"".join(parts)


def op_copy(payload):
    """payload: bytes-like literal data (arbitrary length)."""
    payload = bytes(payload)
    n = len(payload)
    parts = []
    pos = 0
    while pos < n:
        remaining = n - pos
        if remaining <= 255:
            parts.append(bytes([OP_COPY8, remaining]) + payload[pos:pos + remaining])
            pos += remaining
        else:
            c = min(remaining, 65535)
            parts.append(bytes([OP_COPY16]) + c.to_bytes(2, "little") + payload[pos:pos + c])
            pos += c
    return b"".join(parts)


def _cost_skip_chunk(L):
    tc = TMODEL_COEFFS
    if L <= 255:
        return 2, tc["t_skip"] + 1 * tc["header_rate"]
    return 3, tc["t_skip"] + 2 * tc["header_rate"]


def _fill_t(L):
    """Modeled fill T for L bytes: min of unrolled CPU fill and DMA fill
    chunked at fill_dma_min (256B) bytes/chunk. Matches the op-economy
    silicon fill model (scratchpad/research-op-economy.md section 0)."""
    tc = TMODEL_COEFFS
    cpu = L * tc["fill_cpu"]
    chunk = tc["fill_dma_min"]
    dma = math.ceil(L / chunk) * tc["fill_dma_setup"] + L * tc["fill_dma_per_b"]
    return min(cpu, dma)


def _cost_run_chunk(L):
    tc = TMODEL_COEFFS
    fill_t = _fill_t(L)
    if L <= 255:
        return 3, tc["t_op_parse"] + 2 * tc["header_rate"] + fill_t
    return 4, tc["t_op_parse"] + 3 * tc["header_rate"] + fill_t


def _cost_copy_chunk(L):
    tc = TMODEL_COEFFS
    rate = tc["fetch_long"] if L >= 64 else tc["fetch_short"]
    if L <= 255:
        return 2 + L, tc["t_op_parse"] + 1 * tc["header_rate"] + L * rate
    return 3 + L, tc["t_op_parse"] + 2 * tc["header_rate"] + L * rate


def op_cost(kind, length):
    """kind: 'skip' | 'run' | 'copy'. Returns (bytes, T) summed across
    however many count-field chunks `length` requires."""
    total_b, total_t = 0, 0.0
    for L in _chunk_lengths(length):
        if kind == "skip":
            b, t = _cost_skip_chunk(L)
        elif kind == "run":
            b, t = _cost_run_chunk(L)
        elif kind == "copy":
            b, t = _cost_copy_chunk(L)
        else:
            raise ValueError(f"unknown op kind {kind!r}")
        total_b += b
        total_t += t
    return total_b, total_t


_KIND_BY_CLS = ("skip", "copy", "run")   # cls 0/1/2, matches _segment below


def stream_cost(gcls, glens):
    """Total (bytes, T) for a frame's segment list, including the
    per-frame fixed cost once. Does NOT include FEND/KFLIP/KSTART/PAL -
    callers that emit those add their own fixed costs."""
    b_total = 0
    t_total = TMODEL_COEFFS["t_frame_fixed"]
    for c, L in zip(gcls, glens):
        b, t = op_cost(_KIND_BY_CLS[int(c)], int(L))
        b_total += b
        t_total += t
    return b_total, t_total


# ---------------------------------------------------------------------
# Segmentation - ported from the research prototype (flic2.py's
# close_gaps + build_ops), operating on a "paint order" flat array
# (mode-1 column-major, mode-0 row-major - see flatten_frame below).
# Unlike the prototype's alternating-skip wire scheme, the real v2
# format needs NO skip=0 separators between adjacent non-skip ops, so
# segmentation here is simpler than the prototype's own emission step.
# ---------------------------------------------------------------------
FILLMIN = 8   # minimum uniform-run length to prefer RUN over COPY

# Content-triggered keyframe thresholds - ported VERBATIM from the
# research prototype's tuned values (flic2.py / research-realfootage-
# results.md "Method deltas" #3).
THRESHOLDS = [2, 4, 6, 8, 12, 16, 24, 32, 48, 64]
CUT_T, CUT_T_REFRACT = 0.45, 0.60
DRIFT_T, DRIFT_T_REFRACT = 1.5, 3.0
IMPULSE_MULT = 1.7
IMPULSE_MEDIAN_WINDOW = 3

# Anti-drift / staleness controls (SP15 task-2b - the conditional-
# replenishment DEATH SPIRAL fix). On whole-frame slow-drift content
# (Jellyfish gradients) every frame carries thousands of tiny deltas the
# silicon-priced budget cannot afford; importance coarsening drops the
# smallest EVERY frame, so the same pixels starve indefinitely and the
# decoded-vs-source error grows unbounded (the drift trigger only sees
# palette FIT vs the frame's own ceiling, not accumulated decoded error).
# Three encoder-only remedies, all keyed off the fact that err2 below is
# already decoded-surface-vs-target error, i.e. how wrong the screen is:
STALE_DB = 3.0             # (1) staleness-bounded refresh: the decoded screen
                           #     may fall at most this far below the frame's own
                           #     quantize ceiling (po_ceil) before a forced
                           #     keyframe - the hard staleness bound
AGE_GAIN = 0.5             # (2) importance aging: a persistently-wrong, un-
                           #     updated pixel's importance grows by this per
                           #     frame (XDC precedent) so it eventually wins
                           #     budget - no pixel starves forever
STALE_ERR2_FLOOR = 16.0    #     squared error above which a pixel counts as
                           #     "wrong" and accrues age (below it: correct)
PHASE_REFRESH_K = 32       # (3) phase-staggered forced refresh: a rotating
                           #     1/K paint-order slice of the WRONG pixels is
                           #     forced into the mask each frame, so worst-case
                           #     staleness is bounded ~K frames by design
PHASE_FLOOR = 3.0 * THRESHOLDS[-1] ** 2 + 1.0   # just above the coarsest mask

# Region-coherent budget-bound scheduling (SP15 task-2b owner exhibit fix):
# when a frame's deltas exceed budget the encoder spends on whole contiguous
# paint-order BANDS (TILE_BAND rows in mode-0 / columns in mode-1) rather
# than scattered per-pixel/per-region picks, so shortfall reads as soft
# regional lag not hard-edged stale patchwork. Tunable granularity.
TILE_BAND = 4

# Dissolve/pan detection (SP15 task-2b owner exhibit fix): a slow crossfade
# or pan is a SUSTAINED elevated change fraction WITHOUT an impulse - the cut
# trigger misses it and incremental visible repair ghosts/seams. Route it
# through the KEYFRAME SPAN (atomic hidden-surface flip) instead. The
# palette-drift component is REQUIRED to distinguish a dissolve (held palette
# losing fit) from whole-frame drift with a stable histogram (Jellyfish) -
# change fraction alone would thrash keyframes on the latter.
DISSOLVE_WINDOW = 4        # frames of sustained elevation to confirm
DISSOLVE_CHG_T = 0.30      # sustained change-fraction floor
DISSOLVE_DRIFT_T = 1.0     # palette-drift floor (the structure-trend gate)
WHOLE_FRAME_FRAC = 0.60    # decoded-error area above which a staleness refresh
                           # is treated as WHOLE-FRAME -> keyframe span, not
                           # incremental in-place repair


def close_gaps(mask, max_gap=2):
    """Fill short (<=max_gap) False runs between True runs - reduces
    op-count fragmentation from isolated single-byte non-changes.
    Ported verbatim from the research prototype."""
    m = mask
    n = m.size
    b = np.flatnonzero(m[1:] != m[:-1]) + 1
    starts = np.concatenate(([0], b))
    ends = np.concatenate((b, [n]))
    vals = m[starts]
    fr = (~vals) & (starts > 0) & (ends < n) & (ends - starts <= max_gap)
    if not fr.any():
        return m
    add = np.zeros(n + 1, dtype=np.int32)
    np.add.at(add, starts[fr], 1)
    np.add.at(add, ends[fr], -1)
    return m | (np.cumsum(add[:-1]) > 0)


def segment(flat_val, mask, fillmin=FILLMIN):
    """Segment a frame (paint order) into classified spans given a
    changed-byte mask. Returns (cls, starts, lens) with cls in
    {0: skip, 1: copy/literal, 2: run/fill}. Adjacent literal spans
    merge into a single COPY op (reduces op-count overhead)."""
    n = flat_val.size
    if not mask.any():
        return (np.array([0]), np.array([0]), np.array([n], dtype=np.int64))
    vm = mask[1:] & (flat_val[1:] != flat_val[:-1])
    mb = mask[1:] != mask[:-1]
    bnd = vm | mb
    starts = np.concatenate(([0], np.flatnonzero(bnd) + 1))
    lens = np.diff(np.concatenate((starts, [n]))).astype(np.int64)
    smask = mask[starts]
    cls = np.where(~smask, 0, np.where(lens >= fillmin, 2, 1))
    is_lit = cls == 1
    new_group = np.ones(len(cls), dtype=bool)
    new_group[1:] = ~(is_lit[1:] & is_lit[:-1])
    gid = np.cumsum(new_group) - 1
    gstarts = starts[new_group]
    glens = np.bincount(gid, weights=lens).astype(np.int64)
    gcls = cls[new_group]
    return gcls, gstarts, glens


def emit_delta_ops(target_flat, gcls, gstarts, glens):
    """Serialize a segmented delta frame into an opcode payload,
    terminated with FEND."""
    parts = []
    for c, s, L in zip(gcls, gstarts, glens):
        c = int(c)
        s = int(s)
        L = int(L)
        if L == 0:
            continue
        if c == 0:
            parts.append(op_skip(L))
        elif c == 1:
            parts.append(op_copy(target_flat[s:s + L].tobytes()))
        elif c == 2:
            parts.append(op_run(L, int(target_flat[s])))
        else:
            raise ValueError(f"bad segment class {c}")
    parts.append(bytes([OP_FEND]))
    return b"".join(parts)


# ---------------------------------------------------------------------
# Optimal gap-merge (SP15 encoder-optimization wave, encoder-only,
# decoded-output-identical). Per-frame greedy pass over the emitted op
# sequence that (a) bridges interior skips shorter than K* by re-copying
# the unchanged surface bytes, (b) absorbs sub-threshold runs into a
# contiguous copy, (c) drops the trailing skip. K* and the run-absorb
# threshold derive from TMODEL_COEFFS at encode time, so the merge
# self-retunes whenever the coefficients change (e.g. the Task-2 re-bench).
# The research op-economy tooling proved this is byte-identical to the
# un-merged decode (scratchpad/research-op-economy.md section 3,
# scratchpad/opeconomy/analyze.py optimal_merge); the selftest asserts it
# by decoding both streams. Empirically the greedy pass approaches the
# DP upper bound the research measured (64-84% T cut at D=920).
# ---------------------------------------------------------------------

def merge_kstar():
    """Interior-skip bridge crossover K* (bytes). Bridging a SKIP that
    sits between two data ops merges SKIP+COPY into a single COPY: it
    saves the skip dispatch AND one copy dispatch and costs K bytes at the
    copy body rate, so it wins while K < (D_skip + D_copy) / copy_rate.
    Derived from TMODEL_COEFFS - self-tunes with the coefficients (91 B at
    the old model's D=920/skip920; ~63 B at sitting-1 silicon D=920/skip360;
    ~26 B at sitting-2 silicon D=387/skip130 - the optimized kernels make
    fewer gaps worth bridging because a dispatch is no longer expensive)."""
    tc = TMODEL_COEFFS
    skip_disp = tc["t_skip"] + tc["header_rate"]      # SKIP8 op envelope
    copy_disp = tc["t_op_parse"]
    return (skip_disp + copy_disp) / tc["fetch_long"]


def merge_run_absorb_max():
    """Max RUN length (bytes) worth absorbing into a contiguous COPY.
    Absorbing drops the run's own dispatch but re-prices its body at the
    copy rate instead of the (cheaper) fill rate, so it wins while
    L < D / (copy_rate - fill_cpu_rate) (~287 B at sitting-1 silicon,
    ~121 B at sitting-2 silicon's D=387).

    Wired into merge_delta_stream's region assembly (review finding, fix):
    this function used to be computed but never consulted, so every run
    touching a copy (no interior skip) got absorbed UNCONDITIONALLY and a
    run longer than this threshold LOST decode-T instead of saving it. A
    run segment longer than this value is now kept as its own standalone
    RUN op regardless of adjacency; only runs at or under it still fold
    into a neighbouring copy region."""
    tc = TMODEL_COEFFS
    denom = tc["fetch_long"] - tc["fill_cpu"]
    if denom <= 0:
        return float("inf")
    return tc["t_op_parse"] / denom


def merge_delta_stream(gcls, gstarts, glens, target_flat, surface_flat,
                        cap_bytes):
    """Gap-merge one delta frame's segment list into a re-expressed opcode
    payload whose DECODE is byte-identical to emit_delta_ops on the same
    segments. Returns (payload_bytes, modeled_bytes, modeled_T).

    Byte-identity mechanism: build a value buffer that holds the current
    SURFACE bytes everywhere and the TARGET bytes on the changed spans.
    Any copy region emitted from that buffer therefore writes surface
    values across bridged skips (== what was already on screen, a no-op
    change) and target values across real changes - so the decoded surface
    is exactly what the un-merged stream produced. The changed-segment list
    itself is unchanged, so encode_clip's _apply_segments still tracks the
    surface correctly.

    cap_bytes bounds the byte inflation a bridge/absorb may add (each
    bridged skip re-sends K literal bytes); a bridge that would push the
    stream past the cap is declined and the skip is kept."""
    kstar = merge_kstar()

    valbuf = np.array(surface_flat, dtype=np.uint8, copy=True)
    segs = []
    for c, s, L in zip(gcls, gstarts, glens):
        c, s, L = int(c), int(s), int(L)
        if L <= 0:
            continue
        segs.append((c, s, L))
        if c != 0:
            valbuf[s:s + L] = target_flat[s:s + L]
    # (c) drop the trailing skip(s) - pure loss, cursor need not reach the
    # frame end. After this the last segment is always a change, so every
    # remaining skip is interior (has a change before and after it).
    while segs and segs[-1][0] == 0:
        segs.pop()

    # Group segments into copy-through REGIONS separated by KEPT skips. A
    # region accumulates contiguous data segments plus any BRIDGED interior
    # skips (skip L < K*, budget permitting); the whole region emits as one
    # COPY from valbuf (surface bytes on bridged skips, target bytes on the
    # changes) EXCEPT a region that is exactly one lone RUN segment - that
    # stays a RUN (fill is cheaper than copy for an un-bridged run). A copy
    # directly touching a run (no skip between) folds it in (run-absorb) -
    # but ONLY while the run is <= merge_run_absorb_max() bytes (review
    # finding, fix): past that length, absorbing re-prices the run's body
    # at the copy rate instead of the cheaper fill rate and LOSES decode-T,
    # so a longer run is emitted as its own standalone RUN op instead,
    # breaking the region on both sides of it.
    ops = []            # primitive ops: ('skip', L) | ('run', L, col) | ('copy', a, b)
    est_bytes = 1       # FEND byte - soft running estimate for the cap guard
    region = None       # [start, end, members] ; members = list of (cls, L)/('bridge', L)
    absorb_max = merge_run_absorb_max()

    def flush():
        nonlocal region
        if region is None:
            return
        rs, re_, members = region
        if len(members) == 1 and members[0][0] == 2:
            ops.append(("run", re_ - rs, int(target_flat[rs])))
        else:
            ops.append(("copy", rs, re_))
        region = None

    for c, s, L in segs:
        if c == 0:                      # skip (interior by construction)
            if (region is not None and L < kstar
                    and est_bytes + L <= cap_bytes):
                # bridge: the skip's surface bytes join the region as
                # copy-through; the region will emit as one COPY.
                region[1] = s + L
                region[2].append(("bridge", L))
                est_bytes += L
                continue
            flush()
            ops.append(("skip", L))
            est_bytes += 2 * max(1, math.ceil(L / 65535))
        elif c == 2 and L > absorb_max:
            # Long run: flush whatever region was accumulating (unaffected
            # by this run) and emit the run as its OWN standalone RUN op,
            # regardless of adjacency to neighbouring data segments - the
            # next data segment starts a fresh region rather than folding
            # this run in.
            flush()
            ops.append(("run", L, int(target_flat[s])))
            est_bytes += L
        elif c in (1, 2):               # data (copy or short run <= absorb_max)
            if region is None:
                region = [s, s + L, [(c, L)]]
            else:
                region[1] = s + L
                region[2].append((c, L))
            est_bytes += L
        else:
            raise ValueError(f"bad segment class {c}")
    flush()

    parts = []
    b_total = 0
    t_total = TMODEL_COEFFS["t_frame_fixed"]
    for op in ops:
        if op[0] == "skip":
            parts.append(op_skip(op[1]))
            bb, tt = op_cost("skip", op[1])
        elif op[0] == "run":
            parts.append(op_run(op[1], op[2]))
            bb, tt = op_cost("run", op[1])
        else:
            data = valbuf[op[1]:op[2]].tobytes()
            parts.append(op_copy(data))
            bb, tt = op_cost("copy", len(data))
        b_total += bb
        t_total += tt
    parts.append(bytes([OP_FEND]))
    b_total += 1                        # FEND byte (dispatch folded into
                                         # t_frame_fixed, matching stream_cost)
    return b"".join(parts), b_total, t_total


def default_tile_px(n, width=None, height=None, column_major=False):
    """Single source of truth for the region-tile size (bytes) used by
    encode_delta's budget-bound tile schedule when the caller doesn't pass
    tile_px explicitly (review finding, fix: encode_delta's own inline
    default and encode_clip's inline TILE_BAND expression used to be two
    independently-hardcoded formulas that could silently diverge; both now
    go through this one function).

    Shape-aware form (width/height/column_major given, as encode_clip
    always supplies): TILE_BAND rows (mode-0) or columns (mode-1) worth of
    paint-order bytes - a contiguous band in display terms.

    Shape-agnostic fallback (width omitted - direct/standalone callers,
    e.g. tests and tooling, that don't know the frame's geometry): a size
    heuristic scaled to the flat length."""
    if width is not None:
        return TILE_BAND * (height if column_major else width)
    return max(256, n // 48)


def _fit_candidate(gcls, gstarts, glens, target_flat, surface_flat,
                   cap_bytes, cap_t, merge_gaps):
    """Cost a changed-segment list. Returns (bytes, T, payload, suffix) for
    the cheapest variant that fits BOTH caps (gap-merged preferred - it kills
    the dominant per-op dispatch), or None if neither variant fits."""
    b_un, t_un = stream_cost(gcls, glens)
    b_un += 1  # FEND byte
    if merge_gaps and surface_flat is not None:
        payload_m, b_m, t_m = merge_delta_stream(
            gcls, gstarts, glens, target_flat, surface_flat, cap_bytes)
        if b_m <= cap_bytes and (cap_t is None or t_m <= cap_t):
            return b_m, t_m, payload_m, "+merge"
    if b_un <= cap_bytes and (cap_t is None or t_un <= cap_t):
        return b_un, t_un, emit_delta_ops(target_flat, gcls, gstarts, glens), ""
    return None


def encode_delta(target_flat, err2_flat, cap_bytes, cap_t,
                 surface_flat=None, merge_gaps=True, tile_px=None):
    """Region-coherent budget-bound delta encoder. Returns
    (gcls, gstarts, glens, bytes, T, mode, binding, payload).

    FAST PATH: the full changed mask (finest de-noise - drop only sub-noise
    pixels) is tried whole; if it fits both caps the frame keeps ALL its real
    changes, gap-merged (mode 'full[+merge]'). This is the common quiet/mild
    case at silicon prices.

    BUDGET-BOUND PATH (region-coherent, SP15 task-2b owner exhibit fix):
    when the full frame does not fit, the budget is spent on CONTIGUOUS TILES
    (paint-order bands) chosen by aggregate importance - a kept tile is
    updated IN FULL, a deferred tile is left intact. Shortfall then reads as
    coherent regional LAG (soft, motion-masked) instead of the scattered
    per-pixel PATCHWORK that error-blind threshold coarsening / per-region
    truncation produced (hard-edged stale islands on motion bursts). The
    caller's importance AGING keeps deferred tiles from starving: their err2
    grows each frame until a later tile schedule admits them. An all-skip
    frame always fits, so the dual-budget guarantee holds by construction.
    mode 'region:<kept>/<total>[+merge]'.

    The returned (gcls, gstarts, glens) is always the CHANGED-segment list
    (un-merged) the caller walks to track the surface; payload is the chosen
    (possibly merged) stream."""
    n = int(err2_flat.size)
    denoise = 3.0 * THRESHOLDS[0] * THRESHOLDS[0]
    mask_full = close_gaps(err2_flat > denoise)
    gcls, gstarts, glens = segment(target_flat, mask_full)
    res = _fit_candidate(gcls, gstarts, glens, target_flat, surface_flat,
                         cap_bytes, cap_t, merge_gaps)
    if res is not None:
        b, t, payload, sfx = res
        return gcls, gstarts, glens, b, t, "full" + sfx, "none", payload

    # ---- region-coherent tile schedule ----
    # Keep the largest importance-ordered PREFIX of whole bands that fits both
    # caps under the EXACT gap-merged cost. Cost is monotone in the prefix
    # length (adding a band only adds changes), so a binary search finds the
    # cut in ~log2(ntiles) exact merges - fast AND budget-accurate (a plain
    # per-tile greedy re-merges the whole growing mask every step; a
    # conservative estimate badly under-fills because the merge frees far more
    # T than it can predict).
    if tile_px is None:
        tile_px = default_tile_px(n)
    ntiles = (n + tile_px - 1) // tile_px
    sqrt_e = np.where(mask_full, np.sqrt(err2_flat), 0.0)
    band_imp = np.array([sqrt_e[ti * tile_px:(ti + 1) * tile_px].sum()
                         for ti in range(ntiles)])
    order = [int(ti) for ti in np.argsort(-band_imp) if band_imp[ti] > 0.0]

    def _prefix_fit(k):
        """Exact (b, t, payload, sfx) for the top-k importance bands, or None."""
        selmask = np.zeros(n, dtype=bool)
        for ti in order[:k]:
            a, z = ti * tile_px, min((ti + 1) * tile_px, n)
            selmask[a:z] |= mask_full[a:z]
        gc, gs, gl = segment(target_flat, selmask)
        r = _fit_candidate(gc, gs, gl, target_flat, surface_flat,
                           cap_bytes, cap_t, merge_gaps)
        if r is None:
            return None
        return (gc, gs, gl) + r

    lo, hi = 0, len(order)
    best_k, best = 0, _prefix_fit(0)     # k=0 (all-skip) always fits
    while lo <= hi:
        mid = (lo + hi) // 2
        res = _prefix_fit(mid)
        if res is not None:
            best_k, best = mid, res
            lo = mid + 1
        else:
            hi = mid - 1
    gc, gs, gl, b, t, payload, sfx = best
    return (gc, gs, gl, b, t,
            f"region:{best_k}/{ntiles}{sfx}", "budget", payload)


# ---------------------------------------------------------------------
# Paint-order flatten/unflatten (mode-1 column-major, mode-0 row-major)
# ---------------------------------------------------------------------

def flatten_frame(idx_hw, column_major):
    """idx_hw: (H,W) uint8 index frame -> 1D paint-order array."""
    if column_major:
        return np.ascontiguousarray(idx_hw.T).ravel()
    return idx_hw.ravel()


def unflatten_frame(flat, height, width, column_major):
    """Inverse of flatten_frame. Accepts either a 1D index array (raw,)
    or an already palette-applied RGB array (raw,3) - the trailing
    channel axis, if present, rides along unchanged."""
    if flat.ndim == 1:
        if column_major:
            return flat.reshape(width, height).T
        return flat.reshape(height, width)
    c = flat.shape[-1]
    if column_major:
        return flat.reshape(width, height, c).transpose(1, 0, 2)
    return flat.reshape(height, width, c)


# ---------------------------------------------------------------------
# Palette helpers (Pillow ADAPTIVE quantize, NR $44 packing)
# ---------------------------------------------------------------------

def adaptive_palette(rgb, colors=256):
    """Pillow ADAPTIVE palette of an (H,W,3) or (rows,W,3) frame stack.
    Returns (colors,3) uint8."""
    im = Image.fromarray(rgb).convert("P", palette=Image.Palette.ADAPTIVE,
                                       colors=colors, dither=Image.Dither.NONE)
    pal = list(im.getpalette() or [])
    pal += [0] * (colors * 3 - len(pal))
    return np.array(pal[:colors * 3], dtype=np.uint8).reshape(colors, 3)


# Quantizer index-hysteresis deadzone (SP15 encoder-optimization wave):
# when re-quantizing to a HELD palette, a pixel keeps its previous-frame
# index whenever that index's colour is within HYSTERESIS_EPS (squared RGB
# distance) of the best match. This kills per-frame nearest-neighbour index
# churn - 30-93% of delta-written bytes sit at visually-STABLE pixels
# (scratchpad/research-op-economy.md section 5) - at near-zero perceptual
# cost. Default tuned so a genuine colour move (well outside the deadzone)
# still re-quantizes freely while sub-quantization-step flicker sticks.
# The existing drift-triggered keyframe (encode_clip DRIFT_T) bounds any
# slow freeze-drift accumulation - the research's drift-accumulator caveat.
#
# Default 150 (squared RGB distance): a pixel keeps its old index while the
# old colour stays within ~sqrt(150) of the best match, aligning the
# deadzone with the churn audit's "visually stable = max-channel source
# move <= 10" population (scratchpad/research-op-economy.md section 5). On
# a stable-scene-with-noise clip this cuts index churn by >10x for <0.5 dB
# PSNR (per-pixel error is bounded eps above the best match - it does NOT
# accumulate, since prev_d is re-measured against the CURRENT source each
# frame). NOTE: on the two research clips at silicon prices the effect is a
# WASH - the byte/T rate control already coarsens the churn away before
# hysteresis can act (task-2b report); hysteresis pays off on quiet content
# where the budget is not the binding constraint.
HYSTERESIS_EPS = 150.0


def _nearest(vecs, cb, chunk=131072, want_dist=False):
    vecs = vecs.astype(np.float32)
    cb = cb.astype(np.float32)
    cbn = np.sum(cb * cb, axis=1)
    out = np.empty(vecs.shape[0], dtype=np.int32)
    dout = np.empty(vecs.shape[0], dtype=np.float32) if want_dist else None
    for s in range(0, vecs.shape[0], chunk):
        v = vecs[s:s + chunk]
        d = v @ cb.T
        d = np.sum(v * v, axis=1)[:, None] - 2 * d + cbn[None, :]
        bi = np.argmin(d, axis=1)
        out[s:s + chunk] = bi
        if want_dist:
            dout[s:s + chunk] = d[np.arange(bi.size), bi]
    if want_dist:
        return out, dout
    return out


def quantize_to_palette(rgb, pal, prev_idx=None, hysteresis_eps=None):
    """Quantize (H,W,3) uint8 RGB to a fixed 256-entry palette. Returns
    (idx (H,W) uint8, decoded rgb (H,W,3) uint8). Nearest-colour.

    prev_idx (H,W): previous-frame index map. When given together with a
    hysteresis_eps deadzone, a pixel keeps prev_idx whenever that index's
    colour distance is within eps of the best match - index hysteresis
    (see HYSTERESIS_EPS). Used only against a HELD palette (delta frames);
    keyframe re-quantization to a fresh palette passes prev_idx=None."""
    H, W, _ = rgb.shape
    palf = pal.astype(np.float32)
    v = rgb.reshape(-1, 3).astype(np.float32)
    if prev_idx is not None and hysteresis_eps is not None:
        idx, best_d = _nearest(v, palf, want_dist=True)
        pv = prev_idx.reshape(-1).astype(np.int64)
        diff = v - palf[pv]
        prev_d = np.sum(diff * diff, axis=1)
        keep = prev_d <= best_d + hysteresis_eps
        idx = np.where(keep, pv, idx).astype(np.uint8)
    else:
        idx = _nearest(v, palf).astype(np.uint8)
    dec = pal[idx].reshape(H, W, 3)
    return idx.reshape(H, W), dec


def psnr(a, b):
    d = a.astype(np.float64) - b.astype(np.float64)
    mse = np.mean(d * d)
    if mse == 0:
        return 99.0
    return 10.0 * np.log10(255.0 * 255.0 / mse)


def build_palette_block(pal_256x3):
    """256 entries x 2 bytes, NR $44 order (same packing as the v1
    encoder's build_palette_block, kept identical so panels/hardware
    behaviour do not shift): byte0 = RRRGGGBB (top bits), byte1 bit0 =
    the 9th (extended) blue bit per the Next's own 8-bit->9-bit
    hardware expansion rule (docs/zx-next-dev-guide-2022-07-15/chapter-
    next-palette.tex:176)."""
    out = bytearray(PAL_BLOCK_SIZE)
    for i in range(256):
        r, g, b = (int(pal_256x3[i, 0]), int(pal_256x3[i, 1]), int(pal_256x3[i, 2]))
        byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
        byte1 = 1 if (byte0 & 3) else 0
        out[i * 2] = byte0
        out[i * 2 + 1] = byte1
    return bytes(out)


def op_pal(pal_256x3):
    return bytes([OP_PAL]) + build_palette_block(pal_256x3)


# ---------------------------------------------------------------------
# Scene segmentation + cut lookahead (T1 step 4)
# ---------------------------------------------------------------------

def detect_scene_cuts(chg):
    """Batch pre-pass over a clip's per-frame source change-fraction
    array using the SAME impulse test as the live cut trigger (non-
    refractory thresholds), producing an independent scene-boundary
    map used both for keyframe-span cut lookahead and for scene-scoped
    palette sampling spans."""
    cuts = []
    N = len(chg)
    for i in range(1, N):
        med3 = float(np.median(chg[max(1, i - IMPULSE_MEDIAN_WINDOW):i])) if i > 1 else 0.0
        impulse = med3 <= 0.0 or chg[i] >= IMPULSE_MULT * med3
        if chg[i] > CUT_T and impulse:
            cuts.append(i)
    return cuts


def _is_cut_at(chg, i, cut_t):
    if i <= 0 or i >= len(chg):
        return False
    med3 = float(np.median(chg[max(1, i - IMPULSE_MEDIAN_WINDOW):i])) if i > 1 else 0.0
    impulse = med3 <= 0.0 or chg[i] >= IMPULSE_MULT * med3
    return chg[i] > cut_t and impulse


# ---------------------------------------------------------------------
# Scene-scoped palette (T1 step 5) - samples multiple frames across the
# upcoming scene span (to the next detected cut, or clip end) instead
# of the research prototype's single-frame kf_pal, reducing in-scene
# drift-trigger frequency.
# ---------------------------------------------------------------------

def scene_palette(orig_frames, start_idx, scene_end_idx, max_samples=6, colors=256):
    n = scene_end_idx - start_idx
    if n <= 1:
        idxs = [start_idx]
    else:
        k = min(max_samples, n)
        idxs = sorted({int(round(start_idx + j * (n - 1) / (k - 1))) for j in range(k)})
    composite = np.concatenate([orig_frames[i] for i in idxs], axis=0)
    return adaptive_palette(composite, colors=colors)


# ---------------------------------------------------------------------
# Keyframe span planning + chunk emission (T1 step 3, chunk sizing T1
# step 6). A span is N consecutive frames: KSTART+PAL+COPY(...) on the
# first, COPY(...) continuing on the middle ones, COPY(...)+KFLIP on
# the last. All chunks paint the HIDDEN surface; only KFLIP exposes it.
# ---------------------------------------------------------------------

def kf_chunk_budget_bytes(fps, first, width=None, height=None):
    """Max keyframe literal bytes this frame's chunk may hold so the
    modeled decode stays inside the usable per-frame T budget (2%
    reserve). Ported from the research prototype's kf_chunk_cap,
    re-costed for the real COPY op overhead (KSTART/PAL dispatch on
    the first chunk). A keyframe chunk is one long COPY straight down
    the paint order, so it crosses every column boundary a gapped
    surface has - the composition factor applies here too."""
    budget_t = usable_budget_t(fps, width, height) * 0.98 - TMODEL_COEFFS["t_frame_fixed"]
    if first:
        budget_t -= TMODEL_COEFFS["t_palette"]
        budget_t -= 2 * TMODEL_COEFFS["t_op_parse"]   # KSTART + PAL dispatch
    L = int(max(0.0, budget_t) / TMODEL_COEFFS["fetch_long"])
    return max(L, 1)


def plan_kf_chunks(raw_len, fps, width=None, height=None):
    """Returns a list of (start, length, first) chunks covering
    raw_len bytes, each sized to kf_chunk_budget_bytes."""
    chunks = []
    remaining, pos, first = raw_len, 0, True
    while remaining:
        c = min(remaining, kf_chunk_budget_bytes(fps, first, width, height))
        chunks.append((pos, c, first))
        pos += c
        remaining -= c
        first = False
    return chunks


def _clamp_kf_chunks_to_frames(raw_len, n_chunks):
    """Re-partition raw_len bytes into exactly n_chunks (start, length,
    first) chunks, evenly sized (remainder spread across the earliest
    chunks). Used by encode_clip's start_kf guard when plan_kf_chunks's
    T-budget-sized plan needs more chunks than there are source frames
    left before the clip ends - a content-triggered keyframe firing
    close to the end must still complete its KSTART..KFLIP span by the
    clip's final frame, or decode() raises "unterminated keyframe span"
    (review finding). This intentionally trades a modeled T-budget
    overrun on the affected final frame(s) for a span that actually
    terminates; encode_clip records each such frame as a degradation
    event in the BuildReport."""
    n_chunks = max(1, int(n_chunks))
    base, extra = divmod(int(raw_len), n_chunks)
    chunks = []
    pos = 0
    for k in range(n_chunks):
        length = base + (1 if k < extra else 0)
        chunks.append((pos, length, k == 0))
        pos += length
    return chunks


def kf_chunk_cost(length, first):
    """Modeled (bytes, T) for one keyframe-span chunk payload, incl.
    the terminal FEND/KFLIP byte and (on the first chunk) KSTART+PAL."""
    b, t = op_cost("copy", length)
    if first:
        b += 1 + 1 + PAL_BLOCK_SIZE   # KSTART op + PAL op + PAL block
        t += TMODEL_COEFFS["t_op_parse"] + TMODEL_COEFFS["t_palette"]
    b += 1   # terminal op byte (FEND/KFLIP)
    t += TMODEL_COEFFS["t_frame_fixed"] + TMODEL_COEFFS["t_op_parse"]
    return b, t


def emit_kf_chunk_payload(target_flat, start, length, first, is_last, kf_pal=None):
    """Serialize one keyframe-span chunk's payload."""
    parts = []
    if first:
        parts.append(bytes([OP_KSTART]))
        parts.append(op_pal(kf_pal))
    parts.append(op_copy(target_flat[start:start + length].tobytes()))
    parts.append(bytes([OP_KFLIP if is_last else OP_FEND]))
    return b"".join(parts)


def emit_direct_frame_payload(target_flat, pal=None):
    """One DIRECT-SERVE frame (SP15 3c): a single-frame keyframe span -
    KSTART [+ PAL on scene starts] + COPY literals of the whole content
    surface + KFLIP. All-literal by construction (op_copy chunks into
    COPY16/COPY8), so the player's direct path can ini the body bytes
    straight from the SD wire to the hidden surface. The frozen wire
    format is untouched - this is just a composition the direct-serve
    header hint (flags bit1) promises."""
    parts = [bytes([OP_KSTART])]
    if pal is not None:
        parts.append(op_pal(pal))
    parts.append(op_copy(np.asarray(target_flat, dtype=np.uint8).tobytes()))
    parts.append(bytes([OP_KFLIP]))
    return b"".join(parts)


# ---------------------------------------------------------------------
# BuildReport (T1 step 7)
# ---------------------------------------------------------------------

@dataclass
class BuildReport:
    mode: str
    shape: tuple
    fps: float
    frames: int
    mean_psnr: float
    worst_psnr: float
    total_bytes: int
    seconds_per_mb: float
    keyframes: int
    degradation_events: int
    staleness_events: int = 0
    binding_budget_histogram: dict = field(default_factory=dict)
    stream_checked: bool = False        # True when the supply gate applied
    stream_utilization: float = 0.0     # (busy + SD)/period, mean-rate
    stream_busy_ms: float = 0.0
    stream_sd_ms: float = 0.0
    stream_demand_kbs: float = 0.0


# ---------------------------------------------------------------------
# Shape presets + free-height (--aspect) derivation (T1 step 8)
# ---------------------------------------------------------------------

# Fixed shipped presets (literal, per the plan doc's own table).
PRESETS = {
    "full": (320, 256),
    "16:9": (320, 192),
    "scope": (320, 144),
    "classic": (256, 192),
    "classic-wide": (256, 144),
}

# Pixel-aspect correction: Layer 2 mode-1 (320-wide) pixels are not
# square - the displayed aspect is (w/h) * PIXEL_ASPECT_CORRECTION_320.
# Mode-0 (256-wide) pixels are square (correction 1.0) - the classic/
# classic-wide presets hit exact 4:3/16:9 with no correction at all.
PIXEL_ASPECT_CORRECTION_320 = 1.067
PIXEL_ASPECT_CORRECTION_256 = 1.0


def derive_free_height(width, display_aspect):
    """Free-height derivation for --aspect: given a Layer 2 width (256
    or 320) and a desired DISPLAYED aspect ratio (w/h, standard square-
    pixel notation, e.g. 2.35 for cinema scope), returns the integer
    pixel height whose corrected aspect matches. width must be 256 or
    320 (the only two Layer 2 shapes); the result is clamped to that
    width's actual Layer 2 line count (192 for 256-wide mode-0, 256 for
    320-wide mode-1 - see MAX_HEIGHT_BY_WIDTH)."""
    if width not in CODE_BY_WIDTH:
        raise ValueError(f"width must be 256 or 320, got {width}")
    correction = PIXEL_ASPECT_CORRECTION_320 if width == 320 else PIXEL_ASPECT_CORRECTION_256
    h = int(round(width * correction / float(display_aspect)))
    max_height = MAX_HEIGHT_BY_WIDTH[width]
    return max(1, min(max_height, h))


def resolve_shape(shape):
    """shape: a preset name, an explicit (width, height) tuple, or
    None (default: 'full', 320x256)."""
    if shape is None:
        return PRESETS["full"]
    if isinstance(shape, str):
        if shape not in PRESETS:
            raise ValueError(f"unknown shape preset {shape!r} - choose one of "
                              f"{sorted(PRESETS)} or an explicit (width, height)")
        return PRESETS[shape]
    width, height = shape
    if width not in CODE_BY_WIDTH:
        raise ValueError(f"width must be 256 or 320, got {width}")
    max_height = MAX_HEIGHT_BY_WIDTH[width]
    if not (1 <= height <= max_height):
        raise ValueError(f"height must be 1-{max_height} for width {width} "
                          f"(Layer 2 mode-{CODE_BY_WIDTH[width]} has {max_height} lines), got {height}")
    return int(width), int(height)


# ---------------------------------------------------------------------
# Audio layout (unchanged from v1's own derivation - same rates, same
# round(rate/fps) samples-per-frame rule) + the NXV v2.0 PLAYER BOUND:
# the player's audio feed is double-buffered in two 1280-byte halves
# (NXV_AUD_HALF, src/nextdaad.inc), and the open path rejects any
# header declaring more than 1280 real audio bytes/frame ("VID FMT?").
# The wire format itself allows more - this is a player capability
# bound, enforced HERE so a doomed encode fails at encode time with a
# named remedy instead of building a file that refuses to play.
# ---------------------------------------------------------------------

AUD_HALF = 1280   # matches NXV_AUD_HALF - one double-buffer half


def min_fps_for(channels):
    """Lowest fps whose round(rate/fps)*channels fits AUD_HALF:
    samples <= smax requires rate/fps < smax + 0.5, i.e.
    fps > rate/(smax + 0.5). Stereo ~24.40, mono ~18.22."""
    rate = RATE_STEREO if channels == 2 else RATE_MONO
    return rate / (AUD_HALF // channels + 0.5)


def audio_layout(fps, channels):
    from fractions import Fraction
    rate = RATE_STEREO if channels == 2 else RATE_MONO
    exact = Fraction(rate) / Fraction(fps).limit_denominator(1000)
    samples = int(exact + Fraction(1, 2))
    real = samples * channels
    if real > AUD_HALF:
        mode = "stereo" if channels == 2 else "mono"
        remedy = "raise --fps"
        if channels == 2:
            mono_fits = int(Fraction(RATE_MONO)
                            / Fraction(fps).limit_denominator(1000)
                            + Fraction(1, 2)) <= AUD_HALF
            if mono_fits:
                remedy += " or use --mono (mono fits at this fps)"
        import math as _math
        raise SystemExit(
            f"error: {real} audio bytes/frame ({mode} at {float(fps):g} "
            f"fps) exceeds the NXV v2.0 player's per-frame audio bound "
            f"of {AUD_HALF} bytes (one double-buffer half - a bigger "
            f"frame is rejected at open with VID FMT?). Stereo requires "
            f"fps >= {_math.ceil(min_fps_for(2) * 100) / 100:.2f}, mono "
            f"fps >= {_math.ceil(min_fps_for(1) * 100) / 100:.2f} "
            f"(the floors themselves fit - 3b re-review wording fix); "
            f"{remedy}.")
    padded = ((real + 511) // 512) * 512
    return rate, samples, real, padded


SILENCE_U8 = 128


# ---------------------------------------------------------------------
# Encoder pipeline (T1 steps 4-7 wired together) + top-level encode()
# entry point (T1 step 8).
# ---------------------------------------------------------------------

def _extract_source(src_path, width, height, fps, start, duration, ffmpeg, dither, mono):
    """Extracts (orig (N,H,W,3) uint8 RGB frames, ref_idx, ref_pal,
    audio_bytes, channels, rate) from a source file, reusing videnc.py's
    own ffmpeg plumbing (probe/crop/extract) - the canonical location
    for that logic per the kit's own docstring. Imported lazily to
    avoid a module-load cycle (videnc.py imports nxv2enc at top level)."""
    import videnc as _videnc

    input_path = Path(src_path)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    ffmpeg_path = Path(ffmpeg) if ffmpeg else _videnc.DEFAULT_FFMPEG
    if not ffmpeg_path.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg_path}")

    src_w, src_h = _videnc.probe_dimensions(ffmpeg_path, input_path)
    crop = _videnc.compute_center_crop(src_w, src_h, width, height)
    from fractions import Fraction
    fps_frac = fps if isinstance(fps, Fraction) else Fraction(fps).limit_denominator(1000)
    channels = 1 if mono else 2
    # Lay out the audio FIRST: the v2.0 player-bound guard (real
    # bytes/frame <= AUD_HALF) rejects a doomed fps/channels combo
    # before the slow ffmpeg extraction, not after.
    rate, samples_per_frame, abytes_real, abytes_pad = audio_layout(fps_frac, channels)
    video_bytes, nframes = _videnc.extract_video(
        ffmpeg_path, input_path, start, duration, width, height, fps_frac, crop=crop)
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/--start/--duration")
    needed = nframes * abytes_real
    try:
        audio_bytes = _videnc.extract_audio(ffmpeg_path, input_path, start, duration,
                                             channels, rate)
    except SystemExit:
        # Source has no audio stream at all (both SP15 research demo
        # clips, Sintel_1080_10s_30MB.mp4 and Big_Buck_Bunny_1080_10s_
        # 30MB.mp4, are video-only) - fall back to silence rather than
        # failing the encode.
        audio_bytes = b""
    if len(audio_bytes) < needed:
        audio_bytes = audio_bytes + bytes([SILENCE_U8]) * (needed - len(audio_bytes))
    elif len(audio_bytes) > needed:
        audio_bytes = audio_bytes[:needed]

    orig = np.frombuffer(video_bytes, dtype=np.uint8).reshape(nframes, height, width, 3)
    dmode = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE
    ref_idx = np.empty((nframes, height, width), dtype=np.uint8)
    ref_pal = np.empty((nframes, 256, 3), dtype=np.uint8)
    po_ceil = np.empty(nframes)
    chg = np.zeros(nframes)
    for i in range(nframes):
        im = Image.fromarray(orig[i]).convert(
            "P", palette=Image.Palette.ADAPTIVE, colors=256, dither=dmode)
        pal = list(im.getpalette() or [])
        pal += [0] * (768 - len(pal))
        ref_idx[i] = np.asarray(im, dtype=np.uint8)
        ref_pal[i] = np.array(pal[:768], dtype=np.uint8).reshape(256, 3)
        po_ceil[i] = psnr(orig[i], ref_pal[i][ref_idx[i]])
        if i:
            d = np.abs(orig[i].astype(np.int16) - orig[i - 1].astype(np.int16)).max(axis=2)
            chg[i] = float((d > 10).mean())
    return dict(orig=orig, ref_idx=ref_idx, ref_pal=ref_pal, po_ceil=po_ceil,
                chg=chg, audio_bytes=audio_bytes, channels=channels, rate=rate,
                abytes_real=abytes_real, abytes_pad=abytes_pad, nframes=nframes)


def encode_clip(orig, chg, po_ceil, width, height, fps, cap_bytes_frac=0.65,
                budget_scale=1.0, merge_gaps=True, hysteresis=True,
                staleness_refresh=True, return_surfaces=False):
    """Runs the full content-triggered-keyframe + dual-budget delta
    encoder over an already-extracted frame stack. Returns a dict:
    payloads (list[bytes], one per emitted frame - a multi-chunk
    keyframe contributes multiple entries), kf_span_ranges (list of
    (start_frame, end_frame_inclusive) for validation), decoded (list
    of (H,W,3) uint8 arrays, the encoder's own verification decode),
    per_frame stats (bytes/psnr/mode/binding), scene_cuts.

    This is the pure numpy/PIL pipeline stage (T1 steps 3-6) - no file
    I/O, no header. encode() below wraps this with header/container
    writing and the BuildReport."""
    N, H, W, _ = orig.shape
    assert (H, W) == (height, width)
    raw = H * W
    column_major = (width == 320)
    # budget_scale (--stream-budget) scales BOTH delta caps - the
    # streaming-supply operating-point lever (keyframe span chunks are
    # deliberately NOT scaled: they are rare, amortized by the ring,
    # and shrinking them just multiplies span length)
    usable = usable_budget_t(fps, width, height) * budget_scale
    refract = max(1, int(round(fps / 2)))
    cap_bytes = int(cap_bytes_frac * budget_scale * raw)
    hyst_eps = HYSTERESIS_EPS if hysteresis else None
    # Region-coherent tile size: a band of TILE_BAND rows (mode-0) / columns
    # (mode-1) is contiguous in paint order, so shortfall lags coherent
    # horizontal/vertical strips.
    tile_px = default_tile_px(raw, width=width, height=height, column_major=column_major)

    scene_cuts = detect_scene_cuts(chg)

    payloads = []
    kf_span_ranges = []
    per_frame = {"bytes": [], "psnr": [], "mode": [], "binding": [], "drift": [],
                 "t": []}   # modeled decode T/frame (streaming supply check)
    decoded = []
    surfaces = []   # (return_surfaces) per-frame index surface the encoder
                     # believes is on screen - for the decode-vs-bookkeeping
                     # byte-identity invariant (stride/merge-bug guard)

    held_pal = None
    prev_flat = None
    kf_chunks = []       # remaining (start, len, first) chunks of the active span
    kf_pal = None
    staging = None
    last_kf_end = -10_000
    span_start_frame = None
    kf_events = 0
    staleness_events = 0
    kf_triggers = {}
    age = np.zeros(raw, dtype=np.float32)   # per-pixel un-updated-wrong age
    kf_span_clamped = False   # True while the active span's chunk plan was
                               # clamped to fit the clip's remaining frames
                               # (finding 2) - marks its chunk-frames' mode

    for i in range(N):
        start_kf = False
        trigger = None
        drift_for_stats = None   # T1 step 5: recorded for plain delta frames
        if kf_chunks:
            pass  # mid-span: keep painting the hidden surface
        elif held_pal is None:
            start_kf, trigger = True, "start"
        else:
            # Drift measures HELD-PALETTE STALENESS (best achievable vs the
            # frame's own ideal), so it must use the non-sticky nearest-
            # colour quantize - applying hysteresis here would conflate
            # index stickiness with palette drift and thrash the keyframe
            # trigger (freeze-drift). Emission below re-quantizes with
            # hysteresis; the trigger stays clean.
            _, target_dec = quantize_to_palette(orig[i], held_pal)
            drift = po_ceil[i] - psnr(orig[i], target_dec)
            drift_for_stats = drift
            in_refract = (i - last_kf_end) <= refract
            ct = CUT_T_REFRACT if in_refract else CUT_T
            dt = DRIFT_T_REFRACT if in_refract else DRIFT_T
            # Staleness of the ACTUAL decoded screen (held_pal[prev_flat]) vs
            # this source - the accumulated decoded error the drift trigger is
            # blind to (it only sees palette FIT). dec_now = current screen;
            # decoded_deficit = how far below the frame's own ceiling it sits;
            # wrong_frac = the AREA that is wrong (whole-frame vs local).
            dec_now = unflatten_frame(held_pal[prev_flat], height, width, column_major)
            decoded_deficit = po_ceil[i] - psnr(orig[i], dec_now)
            d_now = np.abs(orig[i].astype(np.int16) - dec_now.astype(np.int16)).max(axis=2)
            wrong_frac = float((d_now > 12).mean())
            # Dissolve/pan: sustained elevated change WITHOUT an impulse, WITH
            # the held palette losing fit (drift up) - a scene transition. The
            # palette-drift gate excludes palette-stable whole-frame drift
            # (Jellyfish) so it does not thrash keyframes. Route through the
            # keyframe span (atomic flip) so a transition never shows a
            # half-repaired seam/ghost.
            w0 = max(1, i - DISSOLVE_WINDOW + 1)
            sustained_chg = float(np.mean(chg[w0:i + 1]))
            if _is_cut_at(chg, i, ct):
                start_kf, trigger = True, "cut"
            elif (staleness_refresh and not in_refract
                  and sustained_chg > DISSOLVE_CHG_T and drift > DISSOLVE_DRIFT_T):
                start_kf, trigger = True, "dissolve"
            elif (staleness_refresh and not in_refract
                  and decoded_deficit > STALE_DB and wrong_frac > WHOLE_FRAME_FRAC):
                # WHOLE-FRAME accumulated error -> atomic keyframe, not the
                # incremental in-place repair (which would seam). Local
                # staleness (small wrong_frac) is left to the aging + tile
                # schedule to refresh coherently in the delta path.
                start_kf, trigger = True, "staleness"
                staleness_events += 1
            elif drift > dt:
                start_kf, trigger = True, "drift"

        if start_kf:
            scene_end = next((c for c in scene_cuts if c > i), N)
            kf_pal = scene_palette(orig, i, scene_end)
            planned = plan_kf_chunks(raw, fps, width, height)
            # Cut lookahead (T1 step 4): if this span would take >1
            # chunk AND the very next frame independently looks like a
            # hard cut too, defer starting the span to i+1 instead -
            # avoids composing a mixed-scene frame on the hidden
            # surface (research-realfootage-results.md HAZARD FOUND).
            if len(planned) > 1 and prev_flat is not None and _is_cut_at(chg, i + 1, CUT_T):
                prev_idx = unflatten_frame(prev_flat, height, width, column_major)
                target_idx, target_dec = quantize_to_palette(
                    orig[i], held_pal, prev_idx=prev_idx, hysteresis_eps=hyst_eps)
                tflat = flatten_frame(target_idx, column_major)
                prev_dec_flat = held_pal[prev_flat].astype(np.float32)
                targ_dec_flat = held_pal[tflat].astype(np.float32)
                err2 = np.sum((targ_dec_flat - prev_dec_flat) ** 2, axis=1)
                gcls, gstarts, glens, b, t, mode, binding, payload = encode_delta(
                    tflat, err2, cap_bytes, usable,
                    surface_flat=prev_flat, merge_gaps=merge_gaps, tile_px=tile_px)
                prev_flat = np.where(_mask_from_segments(gcls, gstarts, glens, raw), tflat, prev_flat)
                dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
                payloads.append(payload)
                per_frame["bytes"].append(b)
                per_frame["psnr"].append(psnr(orig[i], dec_img))
                per_frame["mode"].append(mode + ":deferred_kf")
                per_frame["binding"].append(binding)
                per_frame["drift"].append(float("nan"))
                per_frame["t"].append(t)
                decoded.append(dec_img)
                if return_surfaces:
                    surfaces.append(unflatten_frame(prev_flat, height, width, column_major).copy())
                continue

            # Finding 2: a content-triggered keyframe firing too close
            # to the clip's end must not plan more chunks than there
            # are source frames left to hold them - the KFLIP chunk
            # would never emit, leaving an unterminated KSTART span
            # (validate() flags it, decode() raises). Clamp the plan to
            # fit the remaining frames by raising the per-chunk budget
            # so the span completes on the clip's final frame (the
            # T-budget cap may be exceeded on those final frames -
            # recorded below as a degradation event); if even a single-
            # frame span cannot fit (no frames remain), suppress the
            # trigger instead and ride the held palette to the end.
            remaining_frames = N - i
            kf_span_clamped = False
            if len(planned) > remaining_frames:
                if remaining_frames >= 1:
                    planned = _clamp_kf_chunks_to_frames(raw, remaining_frames)
                    kf_span_clamped = True
                else:
                    planned = []
                if not planned:
                    start_kf = False

        if start_kf:
            kf_chunks = planned
            kf_events += 1
            kf_triggers[trigger] = kf_triggers.get(trigger, 0) + 1
            span_start_frame = i
            if prev_flat is None:
                prev_flat = np.zeros(raw, dtype=np.uint8)
                held_pal = kf_pal
            staging = prev_flat.copy()

        if kf_chunks:
            s, L, first = kf_chunks.pop(0)
            tidx, _ = quantize_to_palette(orig[i], kf_pal)
            tflat = flatten_frame(tidx, column_major)
            staging[s:s + L] = tflat[s:s + L]
            is_last = not kf_chunks
            payload = emit_kf_chunk_payload(tflat, s, L, first, is_last, kf_pal=kf_pal)
            payloads.append(payload)
            per_frame["bytes"].append(len(payload))   # actual, not kf_chunk_cost's modeled estimate
            per_frame["binding"].append("kf")
            per_frame["drift"].append(float("nan"))
            per_frame["t"].append(kf_chunk_cost(L, first)[1])
            if is_last:
                prev_flat = staging
                staging = None
                held_pal = kf_pal
                last_kf_end = i
                age[:] = 0.0   # KFLIP repaints the whole surface -> all fresh
                kf_span_ranges.append((span_start_frame, i))
                mode = "kf" if first else "kfflip"
            else:
                mode = "kfhold"
            if kf_span_clamped:
                # Finding 2 disclosure: this chunk belongs to a span
                # whose plan was clamped to fit the clip's remaining
                # frames - its T-budget cap may have been exceeded.
                # encode()'s degradation_events count picks this up.
                mode += ":clamped"
            per_frame["mode"].append(mode)
            # Display shows the flipped (hidden->visible) surface only
            # once KFLIP fires on the last chunk; every earlier chunk
            # in the span is a "hold" frame - prev_flat/held_pal are
            # still the PRE-SPAN visible content at this point (both
            # are only reassigned in the is_last branch above), so
            # held_pal[prev_flat] is exactly the correct hold image.
            dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
            decoded.append(dec_img)
            if return_surfaces:
                surfaces.append(unflatten_frame(prev_flat, height, width, column_major).copy())
            per_frame["psnr"].append(psnr(orig[i], dec_img))
        else:
            prev_idx = unflatten_frame(prev_flat, height, width, column_major)
            target_idx, target_dec = quantize_to_palette(
                orig[i], held_pal, prev_idx=prev_idx, hysteresis_eps=hyst_eps)
            tflat = flatten_frame(target_idx, column_major)
            prev_dec_flat = held_pal[prev_flat].astype(np.float32)
            targ_dec_flat = held_pal[tflat].astype(np.float32)
            err2 = np.sum((targ_dec_flat - prev_dec_flat) ** 2, axis=1)
            # err2 IS the decoded-surface-vs-target error, so importance already
            # tracks accumulated wrongness; the death spiral is that a pixel
            # persistently below the coarsest threshold never enters the mask.
            # (2) AGING: boost a wrong pixel's err2 by its age so persistent
            # small errors eventually cross the threshold / win the fallback.
            # (3) PHASE-STAGGER: force a rotating 1/K slice of the wrong pixels
            # over the coarsest mask floor so worst-case staleness ~K frames.
            if staleness_refresh:
                enc_err2 = err2 * (1.0 + AGE_GAIN * age)
                wrong = err2 > STALE_ERR2_FLOOR
                bi = i % PHASE_REFRESH_K
                b0 = bi * raw // PHASE_REFRESH_K
                b1 = (bi + 1) * raw // PHASE_REFRESH_K
                band = np.zeros(raw, dtype=bool)
                band[b0:b1] = True
                force = band & wrong
                enc_err2 = np.where(force, np.maximum(enc_err2, PHASE_FLOOR), enc_err2)
            else:
                enc_err2 = err2
            gcls, gstarts, glens, b, t, mode, binding, payload = encode_delta(
                tflat, enc_err2, cap_bytes, usable,
                surface_flat=prev_flat, merge_gaps=merge_gaps, tile_px=tile_px)
            new_flat = _apply_segments(prev_flat, tflat, gcls, gstarts, glens)
            prev_flat = new_flat
            if staleness_refresh:
                updated = _mask_from_segments(gcls, gstarts, glens, raw)
                wrong = err2 > STALE_ERR2_FLOOR
                age = np.where(updated, 0.0, np.where(wrong, age + 1.0, 0.0))
            payloads.append(payload)
            per_frame["bytes"].append(b)
            per_frame["mode"].append(mode)
            per_frame["binding"].append(binding)
            per_frame["drift"].append(drift_for_stats if drift_for_stats is not None else float("nan"))
            per_frame["t"].append(t)
            dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
            decoded.append(dec_img)
            if return_surfaces:
                surfaces.append(unflatten_frame(prev_flat, height, width, column_major).copy())
            per_frame["psnr"].append(psnr(orig[i], dec_img))

    return dict(payloads=payloads, kf_span_ranges=kf_span_ranges, decoded=decoded,
                per_frame=per_frame, scene_cuts=scene_cuts, kf_events=kf_events,
                staleness_events=staleness_events, kf_triggers=kf_triggers,
                surfaces=surfaces,
                held_pal_final=held_pal, usable_budget_ms=usable / TMODEL_COEFFS["clock_khz"])


def _mask_from_segments(gcls, gstarts, glens, n):
    mask = np.zeros(n, dtype=bool)
    for c, s, L in zip(gcls, gstarts, glens):
        if int(c) != 0:
            mask[int(s):int(s) + int(L)] = True
    return mask


def _apply_segments(prev_flat, target_flat, gcls, gstarts, glens):
    out = prev_flat.copy()
    for c, s, L in zip(gcls, gstarts, glens):
        c = int(c)
        if c != 0:
            s, L = int(s), int(L)
            out[s:s + L] = target_flat[s:s + L]
    return out


def _encode_direct(ex, width, height, fps_val, out_path, report_path=None):
    """SP15 3c DIRECT-SERVE encode (the raw-equivalent all-literal
    preset): every frame is a single-frame keyframe span (KSTART
    [+ PAL] + COPY + KFLIP) and the header sets the direct-serve hint
    (flags bit1), so the player serves the literal bytes straight from
    the SD wire to the hidden surface - no ring, no RAM pass. Scene-
    scoped palettes reuse the delta pipeline's cut detection + sampled
    full-span quantize; there is no delta and no rate control - the
    stream is raw-equivalent by design, gated by WIRE feasibility
    (direct_supply_check: worst frame, no ring absorber). TIGHTEN
    ruling (Card #5, 2026-07-26, owner-decided): this gate is
    UNCONDITIONAL - a worst-frame utilization above 1.00 always
    refuses, there is no slow-playback opt-out."""
    orig = ex["orig"]
    N = ex["nframes"]
    column_major = (width == 320)
    cuts = [c for c in detect_scene_cuts(ex["chg"]) if 0 < c < N]
    bounds = [0] + cuts + [N]
    payloads = []
    psnrs = []
    for s_i, e_i in zip(bounds[:-1], bounds[1:]):
        if s_i == e_i:
            continue
        pal = scene_palette(orig, s_i, e_i)
        for i in range(s_i, e_i):
            idx, dec = quantize_to_palette(orig[i], pal)
            flat = flatten_frame(idx, column_major)
            payloads.append(emit_direct_frame_payload(
                flat, pal if i == s_i else None))
            psnrs.append(psnr(orig[i], dec))
    nframes_out = len(payloads)
    max_payload = max((len(p) for p in payloads), default=0)
    per_frame_cap_blocks = (max_payload + 511) // 512
    abytes_pad = ex["abytes_pad"]

    # --- DIRECT-SERVE WIRE GATE: the worst frame section must cross
    # the SD wire inside one frame period (no ring absorber). TIGHTEN
    # (Card #5, 2026-07-26 owner ruling): UNCONDITIONAL - utilization
    # > 1.00 always refuses, no accept-slow override exists. ---
    worst_frame = abytes_pad + per_frame_cap_blocks * 512
    ds = direct_supply_check(worst_frame, fps_val)
    if ds["utilization"] > 1.0:
        # Full menu (both channel counts, at this fps AND at the mono
        # floor fps) so an expert sees every at-rate option in one
        # refusal, not just the shape they happened to try.
        s_at = direct_max_raw_bytes(fps_val, 2, 1.0)
        s_90 = direct_max_raw_bytes(fps_val, 2, 0.90)
        m_at = direct_max_raw_bytes(fps_val, 1, 1.0)
        m_90 = direct_max_raw_bytes(fps_val, 1, 0.90)
        mono_floor = min_fps_for(1)
        # menu-only hardening: mono_floor sits within a Fraction-
        # rounding tick of audio_layout's AUD_HALF boundary by
        # construction (it IS the floor where real bytes/frame lands
        # at exactly AUD_HALF), so feeding the exact float back through
        # direct_max_raw_bytes -> audio_layout can trip its strict
        # SystemExit depending on which way the rounding falls - a
        # refusal-message computation must never itself raise. Round
        # the floor UP to the nearest 0.01 fps first (the same ceiling
        # idiom audio_layout's own "fits" floors use, and the precision
        # already shown to the user below) to land safely inside the
        # AUD_HALF bucket instead of on its edge.
        mono_floor_safe = math.ceil(mono_floor * 100) / 100
        m_floor_at = direct_max_raw_bytes(mono_floor_safe, 1, 1.0)
        raise SystemExit(
            f"error: this direct-serve encode cannot play at rate - "
            f"worst-frame wire utilization {ds['utilization']:.2f} > "
            f"1.00 ({worst_frame} B/frame needs {ds['sd_ms']:.1f} ms of "
            f"SD wire per {ds['period_ms']:.0f} ms frame; "
            f"{ds['demand_kbs']:.0f} KB/s vs the "
            f"~{SD_WIRE_BYTES_PER_MS * TMODEL_COEFFS['audio_factor'] * 1000 / (1024 * DIRECT_TRANSPORT_FACTOR):.0f} KB/s "
            f"measured direct-transport rate). Direct-serve has NO ring "
            f"to absorb bursts and NO slow-playback opt-out (TIGHTEN "
            f"policy, Card #5 2026-07-26 owner ruling: this gate is "
            f"unconditional above utilization 1.00). The envelope at "
            f"{fps_val:g}fps, {width}-wide: stereo tops out at "
            f"{width}x{s_at // width} at-rate ({width}x{s_90 // width} "
            f"with the 0.90 burst margin every other gate carries); "
            f"mono tops out at {width}x{m_at // width} at-rate "
            f"({width}x{m_90 // width} at 0.90). Dropping to the "
            f"{mono_floor:.2f}fps mono floor opens the envelope to "
            f"{width}x{m_floor_at // width}. Use a smaller shape, lower "
            f"--fps, switch to --mono, or drop --direct and let the "
            f"delta encoder compress it.")
    elif ds["utilization"] > STREAM_WARN_UTIL:
        print(f"  warning: direct-serve wire utilization "
              f"{ds['utilization']:.2f} (> {STREAM_WARN_UTIL:.2f}) - "
              f"at-capacity encode; slow cards may pace-hold")

    header = pack_header(
        width=width, height=height, fps=fps_val, channels=ex["channels"],
        arate=ex["rate"], frame_count=nframes_out,
        audio_bytes_per_frame=ex["abytes_real"],
        ring_start_margin_blocks=per_frame_cap_blocks,
        per_frame_cap_blocks=per_frame_cap_blocks,
        flags=FLAG_DELTA_STREAM | FLAG_DIRECT_SERVE)

    audio_pad = bytes([SILENCE_U8]) * (abytes_pad - ex["abytes_real"])
    total_bytes = HEADER_SIZE
    out_path = Path(out_path)
    with open(out_path, "wb") as f:
        f.write(header)
        audio_bytes = ex["audio_bytes"]
        abr = ex["abytes_real"]
        for i, payload in enumerate(payloads):
            f.write(audio_bytes[i * abr:(i + 1) * abr])
            f.write(audio_pad)
            f.write(payload)
            pad = (-len(payload)) % 512
            if pad:
                f.write(bytes(pad))
            total_bytes += abytes_pad + len(payload) + pad

    psnr_arr = np.array(psnrs)
    seconds = nframes_out / fps_val
    seconds_per_mb = seconds / (total_bytes / (1024 * 1024)) if total_bytes else 0.0
    report = BuildReport(
        mode="direct", shape=(width, height), fps=fps_val, frames=nframes_out,
        mean_psnr=float(psnr_arr.mean()) if len(psnr_arr) else 0.0,
        worst_psnr=float(psnr_arr.min()) if len(psnr_arr) else 0.0,
        total_bytes=total_bytes, seconds_per_mb=seconds_per_mb,
        keyframes=nframes_out, degradation_events=0,
        binding_budget_histogram={"direct": nframes_out},
        stream_checked=True,
        stream_utilization=ds["utilization"],
        stream_busy_ms=0.0, stream_sd_ms=ds["sd_ms"],
        stream_demand_kbs=ds["demand_kbs"])
    if report_path:
        import json
        with open(report_path, "w") as f:
            json.dump(dict(
                mode=report.mode, shape=list(report.shape), fps=report.fps,
                frames=report.frames, mean_psnr=report.mean_psnr,
                worst_psnr=report.worst_psnr, total_bytes=report.total_bytes,
                seconds_per_mb=report.seconds_per_mb, keyframes=report.keyframes,
                degradation_events=0, staleness_events=0,
                binding_budget_histogram=report.binding_budget_histogram,
                stream_checked=True,
                stream_utilization=report.stream_utilization,
                stream_busy_ms=0.0, stream_sd_ms=report.stream_sd_ms,
                stream_demand_kbs=report.stream_demand_kbs,
                scene_cuts=cuts, kf_span_ranges=[[i, i] for i in range(nframes_out)],
            ), f, indent=1)
    return report


def encode(src_path, out_path, *, shape=None, fps=None, quality_profile="max",
           report_path=None, start=None, duration=None, ffmpeg=None,
           dither=False, mono=False, merge_gaps=True, hysteresis=True,
           staleness_refresh=True, cap_bytes_frac=0.65, stream_budget=1.0,
           direct=False):
    """Top-level NXV v2 encoder entry point. Returns a BuildReport.

    quality_profile: only "max" is implemented in T1 (the dual-budget
    streaming cap point from the research - cap_bytes=0.65x raw AND
    cap_t=usable_budget_t(fps)). A byte-only "resident" profile is
    future work (research-realfootage-results.md's resident-mode
    finding: same streams re-priced without fetch cost).

    cap_bytes_frac (--byte-cap): delta per-frame byte cap as a fraction
    of the raw surface. stream_budget (--stream-budget): scales both
    delta caps (bytes AND decode-T) - the operating-point lever for the
    streaming supply gate below. A file bigger than the reference
    resident pool (STREAM_RESIDENT_POOL_B) must pass
    stream_supply_check or this function refuses to write it.

    direct (--direct, SP15 3c): the raw-equivalent all-literal preset -
    every frame a full keyframe repaint, header direct-serve hint set
    (flags bit1), gated by worst-frame WIRE feasibility instead of the
    delta pipeline's dual budgets (see _encode_direct). TIGHTEN ruling
    (Card #5, 2026-07-26): the gate is unconditional - there is no
    slow-playback opt-out at this or any layer above it."""
    if quality_profile != "max":
        raise ValueError(f"quality_profile {quality_profile!r} not implemented - only 'max'")

    width, height = resolve_shape(shape)
    fps_val = 25.0 if fps is None else float(fps)

    ex = _extract_source(src_path, width, height, fps_val, start, duration,
                          ffmpeg, dither, mono)
    if direct:
        # SP15 3c: the all-literal direct-serve preset - no delta
        # pipeline, no rate control; see _encode_direct.
        return _encode_direct(ex, width, height, fps_val, out_path,
                              report_path)
    result = encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], width, height,
                          fps_val, cap_bytes_frac=cap_bytes_frac,
                          budget_scale=stream_budget,
                          merge_gaps=merge_gaps, hysteresis=hysteresis,
                          staleness_refresh=staleness_refresh)

    payloads = result["payloads"]
    nframes_out = len(payloads)
    max_payload = max((len(p) for p in payloads), default=0)
    per_frame_cap_blocks = (max_payload + 511) // 512
    ring_start_margin_blocks = per_frame_cap_blocks   # conservative T1 placeholder -
    # buffer at least one full max-size frame before starting playback;
    # Task 2/3 (ring sizing against real prefetch cost) may refine this.

    # --- STREAMING SUPPLY GATE (silicon follow-up, Card #3 VSTR1) ---
    # Mean demand/decode-T over the emitted stream vs the SD producer's
    # pace-window supply. Checked BEFORE writing: an unstreamable file
    # is refused, not shipped (it would play at ~(busy + demand/wire)
    # ms/frame with an underrun every frame - correct output, wrong
    # wall time, VSTR1's exact silicon signature).
    abytes_pad = ex["abytes_pad"]
    projected_total = HEADER_SIZE + sum(
        abytes_pad + ((len(p) + 511) // 512) * 512 for p in payloads)
    stream_stats = None
    if projected_total > STREAM_RESIDENT_POOL_B and nframes_out:
        mean_t = sum(result["per_frame"]["t"]) / nframes_out
        mean_demand = (projected_total - HEADER_SIZE) / nframes_out
        stream_stats = stream_supply_check(
            mean_t, mean_demand, abytes_pad, fps_val, width, height)
        if stream_stats["utilization"] > 1.0:
            eq_ms = stream_stats["busy_ms"] + stream_stats["sd_ms"]
            raise SystemExit(
                f"error: this encode cannot stream - mean supply "
                f"utilization {stream_stats['utilization']:.2f} > 1.00 "
                f"(decode {stream_stats['busy_ms']:.1f} ms + SD fetch "
                f"{stream_stats['sd_ms']:.1f} ms per {stream_stats['period_ms']:.0f} ms frame; "
                f"{stream_stats['demand_kbs']:.0f} KB/s demand vs the "
                f"~{SD_WIRE_BYTES_PER_MS * TMODEL_COEFFS['audio_factor'] * 1000 / 1024:.0f} KB/s "
                f"pace-window wire rate). It is {projected_total} B - "
                f"bigger than the {STREAM_RESIDENT_POOL_B} B reference "
                f"resident pool, so it MUST stream, and would play at "
                f"~{eq_ms:.0f} ms/frame (target {stream_stats['period_ms']:.0f}) with an "
                f"underrun every frame. Remedy: --stream-budget "
                f"{stream_stats['suggested_budget']:.2f} (scales the "
                f"delta caps to ~{STREAM_TARGET_UTIL:.0%} utilization), "
                f"or a smaller shape, lower --fps, or a shorter/"
                f"resident-sized clip.")
        elif stream_stats["utilization"] > STREAM_WARN_UTIL:
            print(f"  warning: stream utilization "
                  f"{stream_stats['utilization']:.2f} (> {STREAM_WARN_UTIL:.2f}) - "
                  f"at-capacity encode; bursts ride the ring, small "
                  f"underrun counts possible on slow cards")

    header = pack_header(
        width=width, height=height, fps=fps_val, channels=ex["channels"],
        arate=ex["rate"], frame_count=nframes_out,
        audio_bytes_per_frame=ex["abytes_real"],
        ring_start_margin_blocks=ring_start_margin_blocks,
        per_frame_cap_blocks=per_frame_cap_blocks)

    abytes_pad = ex["abytes_pad"]
    audio_pad = bytes([SILENCE_U8]) * (abytes_pad - ex["abytes_real"])
    total_bytes = HEADER_SIZE

    out_path = Path(out_path)
    with open(out_path, "wb") as f:
        f.write(header)
        # Frame-for-source-frame audio: a multi-chunk keyframe span
        # emits multiple payloads (one per source frame in the span),
        # so payloads and source frames stay 1:1 - audio slices the
        # same way.
        audio_bytes = ex["audio_bytes"]
        abr = ex["abytes_real"]
        for i, payload in enumerate(payloads):
            audio_slice = audio_bytes[i * abr:(i + 1) * abr]
            f.write(audio_slice)
            f.write(audio_pad)
            f.write(payload)
            pad = (-len(payload)) % 512
            if pad:
                f.write(bytes(pad))
            total_bytes += abytes_pad + len(payload) + pad

    per_frame = result["per_frame"]
    psnr_arr = np.array(per_frame["psnr"])
    degradation_events = sum(
        1 for m, bd in zip(per_frame["mode"], per_frame["binding"])
        if (not m.startswith("kf") and bd not in ("none",)) or m.endswith(":clamped"))
    hist = {}
    for bd in per_frame["binding"]:
        hist[bd] = hist.get(bd, 0) + 1

    seconds = nframes_out / fps_val
    seconds_per_mb = seconds / (total_bytes / (1024 * 1024)) if total_bytes else 0.0

    report = BuildReport(
        mode="streaming", shape=(width, height), fps=fps_val, frames=nframes_out,
        mean_psnr=float(psnr_arr.mean()) if len(psnr_arr) else 0.0,
        worst_psnr=float(psnr_arr.min()) if len(psnr_arr) else 0.0,
        total_bytes=total_bytes, seconds_per_mb=seconds_per_mb,
        keyframes=result["kf_events"], degradation_events=degradation_events,
        staleness_events=result.get("staleness_events", 0),
        binding_budget_histogram=hist,
        stream_checked=stream_stats is not None,
        stream_utilization=stream_stats["utilization"] if stream_stats else 0.0,
        stream_busy_ms=stream_stats["busy_ms"] if stream_stats else 0.0,
        stream_sd_ms=stream_stats["sd_ms"] if stream_stats else 0.0,
        stream_demand_kbs=stream_stats["demand_kbs"] if stream_stats else 0.0,
    )

    if report_path:
        import json
        with open(report_path, "w") as f:
            json.dump(dict(
                mode=report.mode, shape=list(report.shape), fps=report.fps,
                frames=report.frames, mean_psnr=report.mean_psnr,
                worst_psnr=report.worst_psnr, total_bytes=report.total_bytes,
                seconds_per_mb=report.seconds_per_mb, keyframes=report.keyframes,
                degradation_events=report.degradation_events,
                staleness_events=report.staleness_events,
                binding_budget_histogram=report.binding_budget_histogram,
                stream_checked=report.stream_checked,
                stream_utilization=report.stream_utilization,
                stream_busy_ms=report.stream_busy_ms,
                stream_sd_ms=report.stream_sd_ms,
                stream_demand_kbs=report.stream_demand_kbs,
                scene_cuts=result["scene_cuts"], kf_span_ranges=result["kf_span_ranges"],
            ), f, indent=1)

    return report


# ---------------------------------------------------------------------
# Bench fixtures (SP15 T2 --bench-fixtures). The decode-kernel silicon
# bench (src/video.asm NXBEN verb family, DEBUG builds) measures
# prototype Z80N decode kernels against known payload shapes; the rows
# feed back into TMODEL_COEFFS above, after which the format freezes.
# Every synthetic payload below is a RAW OPCODE STREAM (no header, no
# audio blocks, no 512-byte padding) built from this module's own op
# emitters, then verified against nxv2dec.run_payload - the reference
# decoder stays the single ground truth for what the bytes mean.
#
# MERGE BYPASS (SP15 encoder-optimization wave): the synthetic fixtures
# (NXB0-NXB7, NXB9) are hand-built directly from op_skip/op_run/op_copy and
# NEVER pass through encode_delta / merge_delta_stream - the gap-merge would
# collapse the dispatch-dominated op-soup (NXB0) that the SOU/dispatch bench
# row is measuring, defeating the fixture's whole purpose. They stay dense
# small ops BY DESIGN. NXB8 (the real-stream fixture) must likewise be cut
# from a NON-merged encode to keep its worst-case op density (build-tests
# encodes its segment source with videnc.py --no-merge).
#
# File set (8.3 names, staged to sd\ by build-tests.ps1 -NxBench):
#   NXB0.BIN  op-soup: dense [SKIP8 8][RUN8 8][COPY8 8] groups - the
#             dispatch/parse-dominated worst case
#   NXB1.BIN  all-RUN8: 256 x RUN8 192          (RUN8 CPU fill row)
#   NXB2.BIN  all-RUN16: 48 x RUN16 1024        (RUN16 CPU + DMA rows)
#   NXB3.BIN  all-COPY8: 256 x COPY8 192        (COPY8 CPU row)
#   NXB4.BIN  all-COPY16: 48 x COPY16 1024      (COPY16 CPU + DMA rows)
#   NXB5.BIN  skip8-soup: 6144 x SKIP8 8        (SKIP8 row)
#   NXB6.BIN  all-SKIP16: 48 x SKIP16 1024      (SKIP16 row)
#   NXB7.BIN  keyframe chunk: KSTART + one COPY16 of BENCH_KF_LITERALS
#             literal bytes + KFLIP - the ~43KB shape-A chunk shape
#             (43008 <= 49152, so the same file serves both display
#             modes' rows)
#   NXB8.BIN  real fixture segment: consecutive whole-frame payloads
#             extracted from a real Task-1 encode (classic 256x192@25),
#             concatenated raw, cut at a frame boundary outside any
#             keyframe span, capped at BENCH_SEGMENT_CAP bytes
#   NXB9.BIN  flip micro-payload: KSTART + KFLIP (KSTART/KFLIP row)
#
# All synthetic cursor spans total BENCH_CLASSIC_RAW (256x192 = 49152),
# the classic-shape surface, so mode-0 rows cover the whole surface and
# mode-1 rows cover the first 49152 bytes of the 320x256 surface - the
# payload bytes are identical either way (cursor space is linear paint
# order in both modes).
# ---------------------------------------------------------------------
BENCH_CLASSIC_RAW = 256 * 192       # 49152
BENCH_KF_LITERALS = 43008           # one-COPY16 keyframe chunk (~43KB, the
                                     # 25fps chunk-budget shape - see
                                     # kf_chunk_budget_bytes(25) ~ 44161)
BENCH_SEGMENT_CAP = 61440           # NXB8 cap: 60KB = 8 pool pages, and the
                                     # bench's 16-bit length cells stay clean


def _bench_literals(n, seed=0):
    """Deterministic literal filler (no RNG state dependence): a simple
    affine byte sequence, incompressible enough to be honest COPY data."""
    i = np.arange(n, dtype=np.uint32)
    return ((i * 7 + 13 + seed) & 0xFF).astype(np.uint8).tobytes()


def walk_payload_ops(buf):
    """Structural walk of one raw payload (opcode stream): returns a dict
    with per-op counts, cursor coverage, literal byte total, terminal op
    and whether a KSTART appears. Pure length arithmetic - decode
    semantics stay nxv2dec's job; this only knows the wire lengths (the
    same table the format reference publishes). Raises ValueError on a
    reserved op or a truncated stream - bench fixtures must be clean."""
    counts = {}
    pos = 0
    cursor = 0
    literals = 0
    kstart = False
    n = len(buf)

    def need(k):
        if pos + k > n:
            raise ValueError(f"truncated op at byte {pos}")

    while True:
        if pos >= n:
            raise ValueError("payload ended without FEND/KFLIP")
        op = buf[pos]
        pos += 1
        counts[op] = counts.get(op, 0) + 1
        if op in TERMINAL_OPS:
            return dict(counts=counts, bytes=pos, cursor=cursor,
                        literals=literals, terminal=op, kstart=kstart)
        if op == OP_KSTART:
            kstart = True
            cursor = 0
        elif op == OP_SKIP8:
            need(1); cursor += buf[pos]; pos += 1
        elif op == OP_SKIP16:
            need(2); cursor += int.from_bytes(buf[pos:pos + 2], "little"); pos += 2
        elif op == OP_RUN8:
            need(2); cursor += buf[pos]; pos += 2
        elif op == OP_RUN16:
            need(3); cursor += int.from_bytes(buf[pos:pos + 2], "little"); pos += 3
        elif op == OP_COPY8:
            need(1); cnt = buf[pos]; pos += 1
            need(cnt); cursor += cnt; literals += cnt; pos += cnt
        elif op == OP_COPY16:
            need(2); cnt = int.from_bytes(buf[pos:pos + 2], "little"); pos += 2
            need(cnt); cursor += cnt; literals += cnt; pos += cnt
        elif op == OP_PAL:
            need(PAL_BLOCK_SIZE); pos += PAL_BLOCK_SIZE
        else:
            raise ValueError(f"reserved opcode ${op:02X} at byte {pos - 1}")


def _bench_verify(name, payload, expect_cursor=None, expect_terminal=OP_FEND,
                   cursor_len=BENCH_CLASSIC_RAW):
    """Run one synthetic payload through the REFERENCE decoder
    (nxv2dec.run_payload) and assert it decodes clean to the expected
    cursor/terminal. Imported lazily - nxv2dec imports this module at
    top level, so the reverse import must stay inside the function."""
    import nxv2dec as _dec
    surface = np.zeros(cursor_len, dtype=np.uint8)
    pos, cursor, op = _dec.run_payload(payload, 0, surface, cursor_len)
    if op == OP_KSTART:
        pos, cursor, op = _dec.run_payload(payload, pos, surface, cursor_len,
                                            start_cursor=0)
    if op != expect_terminal:
        raise AssertionError(f"{name}: terminal ${op:02X}, expected ${expect_terminal:02X}")
    if pos != len(payload):
        raise AssertionError(f"{name}: decoder consumed {pos} of {len(payload)} bytes")
    if expect_cursor is not None and cursor != expect_cursor:
        raise AssertionError(f"{name}: cursor {cursor}, expected {expect_cursor}")


def _bench_segment(segment_vid, cap=BENCH_SEGMENT_CAP):
    """Extract consecutive whole-frame payloads from a real NXV v2 file
    (header/audio/padding stripped) into one raw concatenated stream,
    cut at a frame boundary that is NOT inside a keyframe span, capped
    at `cap` bytes. Returns (bytes, frame_count)."""
    buf = Path(segment_vid).read_bytes()
    hdr = unpack_header(buf)
    if (hdr["width"], hdr["height"]) != (256, 192):
        raise ValueError(f"segment source must be the classic 256x192 shape, "
                          f"got {hdr['width']}x{hdr['height']}")
    abytes_pad = ((hdr["audio_bytes_per_frame"] + 511) // 512) * 512
    out = bytearray()
    frames = 0
    cut_len, cut_frames = 0, 0    # last clean cut point (outside any span)
    pos = HEADER_SIZE
    in_span = False
    for _ in range(hdr["frame_count"]):
        pos += abytes_pad
        payload_start = pos
        # find this frame's payload length with the structural walker
        info = walk_payload_ops(buf[payload_start:payload_start +
                                     hdr["per_frame_cap_blocks"] * 512 + 512])
        plen = info["bytes"]
        if len(out) + plen > cap:
            break
        out += buf[payload_start:payload_start + plen]
        frames += 1
        if info["kstart"]:
            in_span = True
        if info["terminal"] == OP_KFLIP:
            in_span = False
        if not in_span:
            cut_len, cut_frames = len(out), frames
        pos = payload_start + ((plen + 511) // 512) * 512
    if cut_frames == 0:
        raise ValueError("segment cap too small to hold even one complete "
                          "frame/keyframe span")
    return bytes(out[:cut_len]), cut_frames


def bench_fixtures(out_dir, segment_vid=None):
    """SP15 T2 --bench-fixtures: write the NXB0-NXB9 bench payload set
    into out_dir (created if absent) plus nxbench-manifest.txt. Every
    synthetic payload is verified against nxv2dec.run_payload before it
    is written. segment_vid (a real classic-shape Task-1 encode, e.g.
    build-tests' tests/out/002_classic_cache.vid) feeds NXB8; when None,
    NXB8 is skipped with a manifest note. Returns the manifest dict."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    raw = BENCH_CLASSIC_RAW
    files = {}

    # NXB0 op-soup: 2048 x [SKIP8 8][RUN8 8][COPY8 8] = 49152 cursor
    parts = []
    for g in range(raw // 24):
        parts.append(op_skip(8))
        parts.append(op_run(8, g & 0xFF))
        parts.append(op_copy(_bench_literals(8, seed=g)))
    parts.append(bytes([OP_FEND]))
    files["NXB0.BIN"] = b"".join(parts)

    # NXB1 all-RUN8: 256 x RUN8 192
    parts = [op_run(192, c & 0xFF) for c in range(raw // 192)]
    parts.append(bytes([OP_FEND]))
    files["NXB1.BIN"] = b"".join(parts)

    # NXB2 all-RUN16: 48 x RUN16 1024
    parts = [op_run(1024, c & 0xFF) for c in range(raw // 1024)]
    parts.append(bytes([OP_FEND]))
    files["NXB2.BIN"] = b"".join(parts)

    # NXB3 all-COPY8: 256 x COPY8 192
    parts = [op_copy(_bench_literals(192, seed=c)) for c in range(raw // 192)]
    parts.append(bytes([OP_FEND]))
    files["NXB3.BIN"] = b"".join(parts)

    # NXB4 all-COPY16: 48 x COPY16 1024
    parts = [op_copy(_bench_literals(1024, seed=c)) for c in range(raw // 1024)]
    parts.append(bytes([OP_FEND]))
    files["NXB4.BIN"] = b"".join(parts)

    # NXB5 skip8-soup: 6144 x SKIP8 8
    files["NXB5.BIN"] = op_skip(8) * (raw // 8) + bytes([OP_FEND])

    # NXB6 all-SKIP16: 48 x SKIP16 1024 (op_skip would fold 1024 into one
    # SKIP16 of 1024 - emit each op individually, same as the others)
    files["NXB6.BIN"] = op_skip(1024) * (raw // 1024) + bytes([OP_FEND])

    # NXB7 keyframe chunk: KSTART + one COPY16 of BENCH_KF_LITERALS + KFLIP
    files["NXB7.BIN"] = (bytes([OP_KSTART])
                          + op_copy(_bench_literals(BENCH_KF_LITERALS))
                          + bytes([OP_KFLIP]))

    # NXB9 flip micro-payload
    files["NXB9.BIN"] = bytes([OP_KSTART, OP_KFLIP])

    # verify the synthetic set against the reference decoder
    _bench_verify("NXB0.BIN", files["NXB0.BIN"], expect_cursor=raw)
    _bench_verify("NXB1.BIN", files["NXB1.BIN"], expect_cursor=raw)
    _bench_verify("NXB2.BIN", files["NXB2.BIN"], expect_cursor=raw)
    _bench_verify("NXB3.BIN", files["NXB3.BIN"], expect_cursor=raw)
    _bench_verify("NXB4.BIN", files["NXB4.BIN"], expect_cursor=raw)
    _bench_verify("NXB5.BIN", files["NXB5.BIN"], expect_cursor=raw)
    _bench_verify("NXB6.BIN", files["NXB6.BIN"], expect_cursor=raw)
    _bench_verify("NXB7.BIN", files["NXB7.BIN"], expect_cursor=BENCH_KF_LITERALS,
                   expect_terminal=OP_KFLIP)
    _bench_verify("NXB9.BIN", files["NXB9.BIN"], expect_cursor=0,
                   expect_terminal=OP_KFLIP)

    segment_note = None
    if segment_vid is not None:
        seg, seg_frames = _bench_segment(segment_vid)
        files["NXB8.BIN"] = seg
    else:
        seg_frames = 0
        segment_note = ("NXB8.BIN skipped: no --segment source given "
                        "(build-tests.ps1 -NxBench passes the classic cache)")

    op_names = {OP_FEND: "FEND", OP_SKIP16: "SKIP16", OP_RUN8: "RUN8",
                OP_RUN16: "RUN16", OP_COPY8: "COPY8", OP_COPY16: "COPY16",
                OP_PAL: "PAL", OP_SKIP8: "SKIP8", OP_KFLIP: "KFLIP",
                OP_KSTART: "KSTART"}
    manifest = {}
    lines = ["NXV v2 bench fixtures (SP15 T2 --bench-fixtures)",
             f"classic surface = {raw} bytes; kf literals = {BENCH_KF_LITERALS}; "
             f"segment cap = {BENCH_SEGMENT_CAP}", ""]
    for name in sorted(files):
        payload = files[name]
        if name == "NXB8.BIN":
            # multi-frame stream: summarize per-frame walks
            total_counts = {}
            pos = 0
            while pos < len(payload):
                info = walk_payload_ops(payload[pos:])
                for op, k in info["counts"].items():
                    total_counts[op] = total_counts.get(op, 0) + k
                pos += info["bytes"]
            desc = (f"{len(payload)} bytes, {seg_frames} frames, ops: "
                    + " ".join(f"{op_names[o]}={k}" for o, k in sorted(total_counts.items())))
            manifest[name] = dict(bytes=len(payload), frames=seg_frames,
                                   counts={op_names[o]: k for o, k in total_counts.items()})
        else:
            info = walk_payload_ops(payload)
            desc = (f"{len(payload)} bytes, cursor {info['cursor']}, "
                    f"literals {info['literals']}, terminal {op_names[info['terminal']]}, ops: "
                    + " ".join(f"{op_names[o]}={k}" for o, k in sorted(info["counts"].items())))
            manifest[name] = dict(bytes=len(payload), cursor=info["cursor"],
                                   literals=info["literals"],
                                   terminal=op_names[info["terminal"]],
                                   counts={op_names[o]: k for o, k in info["counts"].items()})
        (out_dir / name).write_bytes(payload)
        lines.append(f"{name}: {desc}")
    if segment_note:
        lines.append(segment_note)
    (out_dir / "nxbench-manifest.txt").write_text("\n".join(lines) + "\n")
    for ln in lines:
        print(ln)
    return manifest


if __name__ == "__main__":
    # The only CLI this module carries is the T2 bench-fixture emitter -
    # everything else goes through videnc.py (the one canonical CLI).
    import argparse
    ap = argparse.ArgumentParser(
        description="NXV v2 encoder module - CLI exposes --bench-fixtures only")
    ap.add_argument("--bench-fixtures", metavar="OUTDIR", required=True,
                    help="write the NXB0-NXB9 bench payload set to OUTDIR")
    ap.add_argument("--segment", metavar="VIDFILE", default=None,
                    help="real classic-shape NXV v2 file for NXB8 (e.g. "
                         "tests/out/002_classic_cache.vid)")
    args = ap.parse_args()
    bench_fixtures(args.bench_fixtures, segment_vid=args.segment)
