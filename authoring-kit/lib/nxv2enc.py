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
import hashlib
import math
import sys
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
HDR_OFF_ACHAN = 9          # 1  audio channels - ALWAYS 2. Frozen wire
                           #    field: mono (1) was withdrawn
                           #    2026-08-03 and the player refuses it
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
FLAG_OCOPY = 1 << 3          # RETIRED SP17 T5a offset-copy capability
                             # (withdrawn on owner ruling 2026-08-02 -
                             # both silicon arms judged worse than plain
                             # delta). NEVER SET by this encoder any
                             # more. The bit is kept named and kept
                             # RESERVED because the shipping player
                             # validates the whole flags byte and
                             # refuses it (VID FMT?) - a legacy T5a file
                             # must fail at open, not mis-decode. Do not
                             # re-use bit3 for anything else

RATE_STEREO = 15625   # 28,000,000/16/112 - matches v1's NXV_RATE_STEREO
                      # and is the ONLY rate the player accepts. Mono
                      # (23325 Hz, one ISR per sample) was withdrawn
                      # 2026-08-03: its only advantage was a higher
                      # sample rate for fewer bytes, but both modes are
                      # 8-bit so quantisation sets the quality floor,
                      # and it charged 49% more interrupts plus a 128 B
                      # DMA burst cap against DECODE - the binding
                      # constraint for picture. A mono SOURCE is still
                      # accepted and is upmixed to stereo by ffmpeg
                      # (videnc.extract_audio passes -ac 2)

KF_POLICY_V2 = 1   # encoder bookkeeping only - the player ignores this byte

# ---------------------------------------------------------------------
# PLAYER FILE-SIZE CEILING - the single source of truth for the largest
# .VID this player can address. The encoder priced RATE and never TOTAL
# SIZE, so it happily emitted files the player refused at open; the
# admission check below (total_size_check) closes that.
#
# The player's file-level cursors count 512-BYTE BLOCKS since the
# 2026-08-02 ceiling lift (src/video.asm: vidTotalBlk,
# vidStrmRemainBlk, vidFileEnd and the streaming vidFramePos - 3 bytes
# each; vid_file_blocks is the one conversion point). Before the lift
# they were 24-bit BYTE quantities and the open path refused any file
# >= 16,777,216 B outright - streamed with VID SIZE?, direct folded
# into VID FMT?. At 24 bits of BLOCKS those same cells reach 8 GiB, so
# the cursors are no longer what binds. Three structural limits sit
# above the format, and the smallest governs:
#
#   * the 24-bit block cursors                       8 GiB
#   * F_FSTAT hands the player a 32-bit byte size    4 GiB
#   * the HOT FILEMAP holds VID_STRM_HOT_ENT = 8 extents, and esxDOS's
#     DISK_FILEMAP entry carries a 16-bit block count, so a file needs
#     at most 8 * 65535 blocks to be describable - above that even a
#     perfectly contiguous file is refused VID FRAG? at open.
#
# The filemap ceiling governs. Bump PLAYER_MAX_BLOCKS only together
# with VID_STRM_HOT_ENT in src/nextdaad.inc.
PLAYER_HOT_FILEMAP_ENTRIES = 8      # VID_STRM_HOT_ENT
PLAYER_FILEMAP_BLOCKS_PER_ENTRY = 65535   # esxDOS 16-bit extent count
PLAYER_MAX_BLOCKS = (PLAYER_HOT_FILEMAP_ENTRIES
                     * PLAYER_FILEMAP_BLOCKS_PER_ENTRY)
PLAYER_MAX_BYTES = PLAYER_MAX_BLOCKS * 512      # 268,431,360 B

# The OTHER limit the lift exposed: the header carries a 24-bit frame
# count but the player validates the top byte as zero and runs 16-bit
# frame counters (vidFrames / vidFramesLeft), so 65535 frames is the
# hard bound - VID FMT? above it. It was unreachable while the file
# ceiling was 16 MB (16384 frames at the 1024 B/frame floor); with the
# ceiling at 256 MB a cheap compressed clip reaches it first, so it is
# priced alongside the size.
PLAYER_MAX_FRAMES = 65535


def _clock(seconds):
    return f"{int(seconds) // 60}:{int(seconds) % 60:02d}"


def total_size_check(total_bytes, frames, mode, width, height, fps,
                     channels):
    """Admission check on the WHOLE FILE, run before a byte is written.

    The rate gates upstream price one FRAME against the wire; nothing
    priced the total, so a long clip at a legal rate could still be
    unplayable - and was (SP17 W5 emitted 18 MB files against a 16 MB
    player ceiling). Refuses on either whole-file bound the player
    carries, naming the limit and the longest clip this shape/rate can
    reach, so the remedy is arithmetic rather than trial and error.
    total_bytes is the projected size (the writer's own arithmetic,
    computed ahead of the write)."""
    seconds = frames / float(fps) if fps else 0.0
    chan = "stereo"                 # the only channel count v2 carries
    if frames > PLAYER_MAX_FRAMES:
        max_seconds = PLAYER_MAX_FRAMES / float(fps)
        raise SystemExit(
            f"error: this {mode} encode is {frames:,} frames - over the "
            f"NXV player's {PLAYER_MAX_FRAMES:,} frame ceiling (its "
            f"frame counters are 16-bit), so the player would refuse it "
            f"at open with VID FMT?. At {float(fps):g} fps the longest "
            f"playable clip is {max_seconds:.1f} s ({_clock(max_seconds)}); "
            f"this one is {seconds:.1f} s. Remedy: shorten the clip "
            f"(--duration {max_seconds:.1f} or less), lower --fps, or "
            f"split it across several .VID files and play them back to "
            f"back.")
    if total_bytes <= PLAYER_MAX_BYTES:
        return
    rate_bps = total_bytes / seconds if seconds else 0.0
    max_seconds = (PLAYER_MAX_BYTES / rate_bps) if rate_bps else 0.0
    raise SystemExit(
        f"error: this {mode} encode is {total_bytes:,} B - over the NXV "
        f"player's {PLAYER_MAX_BYTES:,} B "
        f"({PLAYER_MAX_BYTES / (1024 * 1024):.1f} MiB) file ceiling, so "
        f"the player would refuse it at open with VID FRAG? even on a "
        f"perfectly unfragmented card (the ceiling is the hot filemap: "
        f"{PLAYER_HOT_FILEMAP_ENTRIES} extents of at most "
        f"{PLAYER_FILEMAP_BLOCKS_PER_ENTRY:,} 512-byte blocks). At this "
        f"shape and rate ({width}x{height} @ {float(fps):g} fps {chan}, "
        f"{rate_bps / 1024:.0f} KB/s) the longest playable clip is "
        f"{max_seconds:.1f} s ({_clock(max_seconds)}); this one is "
        f"{seconds:.1f} s. Remedy: shorten the clip (--duration "
        f"{max_seconds:.1f} or less), use a smaller shape or a lower "
        f"--fps, or split it across several .VID files and play them "
        f"back to back.")


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
    if channels != 2:
        # Mono withdrawn 2026-08-03 (owner ruling). The FIELD stays -
        # it is frozen wire format at offset 9 - and the player still
        # validates it, refusing anything but 2 with VID FMT? at open.
        # This is the encoder half of that contract.
        raise ValueError(f"channels must be 2, got {channels}")
    if not (0 <= frame_count < (1 << 24)):
        raise ValueError("frame_count out of the header's 24-bit range")
    if frame_count > PLAYER_MAX_FRAMES:
        # PLAYER BOUND defence-in-depth, same idiom as the audio bound
        # below: the player validates the header's top frame-count byte
        # as zero and refuses anything above (VID FMT?), because its own
        # frame counters are 16-bit. total_size_check() enforces this
        # upstream for every real encode path with an author-facing
        # remedy; this guard catches any future caller that bypasses it.
        # Unreachable until the 2026-08-02 ceiling lift: the old 16 MB
        # file ceiling capped a clip at 16384 frames.
        raise ValueError(
            f"frame_count {frame_count} exceeds the NXV player bound of "
            f"{PLAYER_MAX_FRAMES} frames (the player's frame counters "
            f"are 16-bit and it refuses a bigger count at open with "
            f"VID FMT?)")
    if not (0 <= audio_bytes_per_frame < (1 << 16)):
        raise ValueError("audio_bytes_per_frame out of 16-bit range")
    if audio_bytes_per_frame > AUD_FRAME_MAX:
        # PLAYER BOUND defence-in-depth (3b review minor -> 3c; bound
        # moved by SP17 T10's circular feed, and again 2026-08-02 when
        # the ring took the whole audio bank): the player rejects such
        # a header at open (VID FMT?), so no writer may build one.
        # audio_layout() enforces this upstream for every real encode
        # path; this guard catches any future caller that bypasses it.
        raise ValueError(
            f"audio_bytes_per_frame {audio_bytes_per_frame} exceeds the "
            f"NXV player bound of {AUD_FRAME_MAX} bytes "
            f"(NXV_AUD_FRAME_MAX - the player refuses the file at open "
            f"with VID FMT?)")
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
        ocopy=bool(buf[HDR_OFF_FLAGS] & FLAG_OCOPY),
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
OP_OCOPY8 = 0x24   # RESERVED - the retired SP17 T5a offset-copy op.
                   # Decode was withdrawn from the player on 2026-08-02;
                   # the slot is listed here so it stays reserved and is
                   # never re-used, and it is deliberately OUT of
                   # VALID_OPS so the reference decoder rejects it
OP_KSTART = 0x28   # begin keyframe span: target = hidden surface; cursor = 0
OP_SCROLL = 0x2C   # RESERVED, unimplemented in v2.0 - encoder never emits
                   # (kept for T5b hardware scroll)
OP_OCOPY16 = 0x30  # RESERVED - as OP_OCOPY8, the 16-bit-length form

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
    "fetch_short": 19.80,       # T/byte short-copy LDI body [SILICON NXBC
                                #   sitting 3, 2026-08-01: C001..C073 CPU fit
                                #   slope 19.797 T/B, residuals under 4 T].
                                #   was 20.2 (= fetch_long); the short-burst
                                #   rows resolve their own body now. No
                                #   separate short-burst PENALTY exists -
                                #   burst size is dispatch, priced separately
    "t_skip": 141.6,            # SKIP8 op envelope [SILICON NXBO SK00 row,
                                #   sitting 3 (2026-08-01 NXBO/NXBC bench,
                                #   production routines): 141.61 T incl its
                                #   count byte]. sitting 2: 130 (prototype
                                #   kernel). sitting 1: 360. model was 45
    "t_skip16": 210.7,          # SKIP16 op envelope [SILICON NXBO S160 row
                                #   sitting 3: 210.68 T - the slow-parser
                                #   16-bit path costs +69 T over SK00]. The
                                #   old single-key model priced SKIP16 at the
                                #   SKIP8 value (disclosed 62% under-price);
                                #   the second key retires that disclosure
    "t_op_run": 487.2,          # RUN op dispatch envelope [SILICON NXBO
                                #   sitting 3: RU01/RU17/F063/F070 joint fit
                                #   envelope 487.21 T, body 16.703 T/B]. The
                                #   run envelope carries the computed-entry
                                #   fill setup the copy path does not - the
                                #   measured RUN/COPY ratio 1.449 equals the
                                #   sitting-2 387/267 ratio exactly, so the
                                #   TWO-KEY SPLIT retires the old single-key
                                #   "take the dearer class" compromise (387)
                                #   that over-priced the DOMINANT copy class
                                #   15% and under-priced runs 21%. sitting 2:
                                #   387 single-key. body priced separately
    "t_op_copy": 336.3,         # COPY op dispatch envelope [SILICON NXBC
                                #   sitting 3: C001..C073 CPU fit envelope
                                #   336.32 T, residuals under 4 T]. sitting 2
                                #   measured the same class at 267 on the
                                #   prototype kernel; the production dispatch
                                #   carries more glue. body priced separately
    "t_op_misc": 487.2,         # KSTART/KFLIP/FEND/PAL dispatch - UNMEASURED
                                #   simple handlers, priced at the dearest
                                #   measured envelope (t_op_run) by the same
                                #   conservative-for-feasibility convention
                                #   the single-key model used. Well under
                                #   0.5% of any frame
    "fill_cpu": 16.70,          # T/byte unrolled CPU fill [SILICON NXBO
                                #   sitting 3: RUN fit slope 16.703 T/B on the
                                #   production routine]. sitting 2: 17.17
                                #   (R8U/R6U joint solve). sitting 1: 17.0.
                                #   model was 13.2
    "fill_dma_per_b": 5.1,      # T/byte DMA fill body [SILICON RD chunk solve
                                #   sitting 2, over-determined against the DMA-copy
                                #   KF/CD3 cross-row solve]. Hardware term - the
                                #   wave cannot change it; sitting 1's 4.5 was an
                                #   artifact of attributing 920 T/op. model was 4.0
    "fill_dma_setup": 849.0,    # T per 256B DMA fill chunk [SILICON RD1/RD2/RD3
                                #   solve sitting 2 - both chunk differences give
                                #   849.4 exactly; persistent-descriptor re-arm].
                                #   sitting 1: 1273. hand count 683. model was 355
    "fill_dma_min": 256,        # DMA fill CHUNK size (bytes); also the audio-safety
                                #   cap (512B bursts starve the sample ISR - 35%
                                #   tick shortfall, both sittings). Historic name -
                                #   it is a chunk size, not a threshold; the
                                #   threshold is run_dma_min below
    "run_dma_min": 71,          # the PLAYER's fill kernel-select threshold
                                #   (NXV2_RUN_DMA_MIN, src/nextdaad.inc): a fill
                                #   chunk shorter than this goes unrolled-CPU.
                                #   The 2026-07-28 derivation
                                #   849.4/(17.17-5.11) = 70.43 -> 71 quoted TWO
                                #   SUPERSEDED coefficients (17.17 became
                                #   fill_cpu 16.703; 5.11 became ~5.0). Fresh
                                #   NXBK rows (2026-08-03) solve the two
                                #   envelopes directly - CPU 476.7 + 16.703 L
                                #   against DMA 1289.6 + 4.888 L - and put the
                                #   crossover at 68.8 -> 69.
                                #   VALUE HELD AT 71: taking CPU for 69-70 B
                                #   fills costs <= 34 T/op on a class that is
                                #   0.00-0.08% of corpus decode-T. See the
                                #   .inc comment for the full derivation and
                                #   for why RUN correctly charges NO path
                                #   term (measured at -36 T, not assumed)
    "copy_dma_min": 81,         # the PLAYER's copy kernel-select threshold
                                #   (NXV2_COPY_DMA_MIN, src/nextdaad.inc).
                                #   MEASURED break-even 81.4 B (SP17 NXBC
                                #   C073/C074 silicon rows): the 2026-07-28
                                #   kernel-only derivation (1091.8/(20.25-5.31)
                                #   = 73.08 -> 74) missed the fast-handler ->
                                #   slow-body PATH difference (copy_dma_path_t
                                #   below).
                                #   DENOMINATOR CORRECTED 2026-08-03: the
                                #   shipped arithmetic (1091.8+128)/14.94 =
                                #   81.65 used fetch_long 20.25, but
                                #   fetch_long is the >= 64 B LDI body and the
                                #   ops that DECIDE this crossover are 73-83 B
                                #   and run fetch_short. At sitting-3
                                #   coefficients (1091.8+128)/(19.797-5.082)
                                #   = 82.90. VALUE HELD AT 81 (the measured
                                #   placement; silicon read 81.4, and the
                                #   correction only means DMA is taken ~2 B
                                #   early, worst +28 T/op at L=81 on ~0.3% of
                                #   ops - inside the row resolution).
                                #   History: 90 (undocumented) -> 74
                                #   (kernel-only) -> 81 (measured)
    "copy_dma_path_t": 128.0,   # T/op fast-handler -> slow-body path
                                #   difference a sub-256 COPY8 pays to REACH
                                #   the DMA kernel (NXBC C073/C074: DMA at the
                                #   old 74 threshold cost +128 T/op over the
                                #   fast LDI path). Charged once per op in
                                #   _copy_t's DMA branch, and ONLY on
                                #   8-bit-operand ops since 2026-08-03: a
                                #   >= 256 B op has no fast handler to bail
                                #   out of, so it pays the measured
                                #   slow-parser entry (t_skip16 - t_skip)
                                #   instead. Charging path_t there was a
                                #   deliberate double-cover and it was the
                                #   WHOLE of the model's 2.9% pessimism on
                                #   K256 (REDERIVATION.md 6.4)
    "copy_dma_per_b": 5.08,     # T/byte mem-to-mem DMA COPY body [SILICON
                                #   NXBC sitting 3: C074-C103 slow-body slope
                                #   5.082 T/B, UNARMED]. sitting 2: 5.31
                                #   (KF-vs-CD3 cross-row solve; 6.21 armed -
                                #   the armed tax is carried globally by
                                #   audio_factor, so the unarmed rate is the
                                #   right one here)
    "copy_dma_setup": 1091.8,   # T per DMA copy chunk [SILICON CD1..CD4 chunk
                                #   solve sitting 2: the three chunk differences
                                #   give 1091.8 / 1091.6 / 1091.9]. sitting 1:
                                #   1273 (under the 920 T/op attribution error)
    "copy_dma_chunk": 256,      # DMA copy chunk size (bytes) = NXV2_DMA_CHUNK,
                                #   the audio-safety burst cap the player clips
                                #   every copy chunk to (vid_chunk_all).
                                #   UNCONDITIONALLY CORRECT since 2026-08-03.
                                #   It carried a "STEREO ONLY" caveat while a
                                #   mono session took a 128 B cap the model
                                #   could not see (which mispriced a mono
                                #   stream ~10-38% optimistic on decode); mono
                                #   was withdrawn with the cap that served it,
                                #   so there is now exactly ONE cap, the
                                #   player always applies it, and this value
                                #   models the player exactly
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
                                #   sitting 1: 0.85. model was 0.89.
                                #   UNCONDITIONALLY CORRECT since 2026-08-03.
                                #   The fit was taken at the stereo tick rate,
                                #   which used to make it a "STEREO ONLY"
                                #   caveat: the mono ISR was cheaper per tick
                                #   (~145 T against ~190 T hand-counted) but
                                #   fired 49% more often, ~14% more duty, an
                                #   effective 0.83 - so mono streams were
                                #   admitted ~2-2.5% optimistically
                                #   (sp17-corpus/REDERIVATION.md 6.7). Mono is
                                #   withdrawn, there is one tick rate, and
                                #   this coefficient is fitted at it
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
#   AF CONVENTION (cross-refer stream_supply_check's own note): this
#   formula divides the MODEL side by audio_factor before taking the
#   ratio - af is folded into R's own calibration, once, here. So
#   R x model_T = af x (true silicon decode T), and any consumer that
#   wants the TRUE silicon decode time must divide by af again.
#   stream_supply_check() now does exactly that (Card #8, 2026-07-28);
#   it used to multiply R straight onto the raw model T and thereby
#   price busy at 85% of the decode time silicon actually spends. That
#   understatement was harmless while the T model was ~15% dearer than
#   silicon and is not harmless now - see the gate's own block.
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
#
# ---------------------------------------------------------------------
# SP17 RE-FIT - CLOSED ON SILICON (Card #8 Group A, 2026-07-28, core
# 3.02.04, DEBUG nex BA2CA168). This block was OPEN: R had been fitted
# against the PRE-SP17 T model, and SP17 then restored the mem-to-mem
# DMA copy term the task-2 settlement measured but the encoder never
# wired in (_copy_t / copy_dma_* in TMODEL_COEFFS), making the model
# side ~15% cheaper. The paper prediction was that every R would rise
# by 1.09x-1.31x and eat both margins. It was NOT re-fitted from that
# arithmetic - a calibration whose authority is that it was measured
# does not get corrected on paper. Card #8 measured it.
#
# Same method, same 1792 T tick, same op-walk of the EXACT staged bytes
# (sd\001-006, sizes verified against the card - no re-encode enters
# the ratio):
#
#   | fixture | shape          | class        | model T/f | silicon T/f | R     |
#   |---------|----------------|--------------|-----------|-------------|-------|
#   | 001.VID | 320x256        | FLAT         |   785,622 |     931,260 | 1.008 |
#   | 002.VID | 256x192        | FLAT         |   449,158 |     539,432 | 1.021 |
#   | 005.VID | 256x144        | FLAT         |   416,927 |     500,506 | 1.020 |
#   | 003.VID | 320x192 LB     | GAPPED dense |   757,852 |   1,121,362 | 1.258 |
#   | 004.VID | 320x144 LB     | GAPPED dense |   565,430 |     743,972 | 1.118 |
#   | 006.VID | 320x192 LB TC  | GAPPED SPARSE|   261,853 |     582,386 | 1.890 |
#
# The prediction held and the margins were gone: flat 0.90 -> 1.01-1.02,
# dense gapped 1.005/1.023 -> 1.258/1.118. Re-fitted by the same rule:
#
#   flat   = worst flat R  1.021 (002) x 1.12 = 1.144 -> 1.14
#   gapped = worst DENSE R 1.258 (003) x 1.12 = 1.409 -> 1.41
#
# THE SHIPPED FACTORS WERE ALREADY BEING BLOWN THROUGH, and 003 proves
# it directly rather than by extrapolation: its Card #8 row spends
# 625.8 ticks/frame in DECODE ALONE (40.05 ms) and its whole frame
# takes 678.0 ticks (43.4 ms) against a 625-tick period - the only row
# in the set that misses its period. Every other fixture paces at
# 616-622 ticks. At the shipped 1.15 the gapped cap is 827,826 T, which
# at R 1.258 predicts 1,225,000 T = 43.8 ms on silicon; at 1.41 the cap
# is 675,177 T and predicts 999,300 T = 35.7 ms, back inside the period
# with the intended margin.
#
# HEIGHT SLOPE REFUTED. Card #5's gapped rows sloped with 1/height
# (144 worse than 192, the crossing-rate story). Card #8 inverts it:
# 003 (h=192) R 1.258 is now WORSE than 004 (h=144) R 1.118, on
# fixtures whose density also changed. Two points that swapped order
# are not a law in either direction, so silicon_r() no longer
# interpolates on height - it returns the worst measured gapped R for
# every gapped height. A third, genuinely intermediate gapped row is
# still what would settle the shape.
#
# SPARSE ROW UNMOVED. 006 re-measures R 1.890 against Card #5's 1.916
# - the disclosed model weakness (90% of the surface skipped every
# frame, priced at 262 kT against 582 kT of silicon) is exactly where
# it was, neither healed nor worse. It is still not a cap hazard: 006
# spends 325.0 ticks (20.8 ms) of a 40 ms period and paces at 622.4
# ticks. It does NOT drive the dense factor - the rule says worst DENSE.
#
# ---------------------------------------------------------------------
# RE-CONFIRMED ON FRESH SILICON (2026-07-30, core 3.02.04, DEBUG nex
# 847A6D80, era pal9h). The Card #8 re-fit was measured on the pal9f
# staged bytes; the fixtures were then RE-ENCODED under the new factors,
# so this sitting is an independent test of the fixed point: if the
# factors are right, the re-encoded (smaller-budget) streams must come
# back with the SAME R and now fit their period. Same method, same
# 1792 T tick, op-walk of the exact pal9h staged bytes (the walk
# consumes all nine files to the byte, header + audio pad + payload +
# 512 B padding - no re-encode enters the ratio):
#
#   | fixture | shape         | class         | model T/f | silicon T/f | R     |
#   |---------|---------------|---------------|-----------|-------------|-------|
#   | 001.VID | 320x256       | FLAT at-cap   |   744,921 |     884,932 | 1.010 |
#   | 002.VID | 256x192       | FLAT          |   449,340 |     539,950 | 1.021 |
#   | 005.VID | 256x144       | FLAT          |   416,918 |     500,506 | 1.020 |
#   | 003.VID | 320x192 LB    | GAPPED at-cap |   638,907 |     942,735 | 1.254 |
#   | 004.VID | 320x144 LB    | GAPPED dense  |   564,510 |     741,888 | 1.117 |
#   | 006.VID | 320x192 LB TC | GAPPED SPARSE |   261,761 |     582,271 | 1.891 |
#   | 007.VID | 256x192 str   | FLAT sparse   |   338,195 |     412,633 | 1.037 |
#   | 008.VID | 320x256 str   | FLAT sparse   |   276,289 |     351,100 | 1.080 |
#   | 009.VID | 320x192 LB str| GAPPED sparse |   282,919 |     466,588 | 1.402 |
#
# EVERY Card #8 R REPRODUCES: 1.008->1.010, 1.021->1.021, 1.020->1.020,
# 1.258->1.254, 1.118->1.117, 1.890->1.891 - inside 0.4%, against staged
# bytes that moved by up to 15.7% (003's model T fell 757,852 ->
# 638,907 as the tighter cap bit, and its silicon decode fell with it,
# 1,121,362 -> 942,735). R is a property of the shape/density cluster,
# not of the operating point, which is what makes the factor a fixed
# point and not a moving target. The flat rows also repeat ACROSS
# SITTINGS to ~0.1% on the raw tick counts.
#
# 003 NOW MAKES ITS PERIOD - the one row that missed it at pal9f. Its
# phase sum is 590.7 ticks/frame (PACE 44.2 + AUDIO 19.9 + DECODE 526.1
# + FLIP 0.5 + OTHER 0.2) against the 625-tick period: 34.3 ticks
# (2.2 ms, 5.5%) of margin where Card #8 measured 678.0 ticks, 8.5%
# OVER. DECODE alone went 625.8 -> 526.1 ticks (40.05 -> 33.67 ms), and
# PACE is nonzero on all nine rows, so every fixture fits its period.
#
# FACTORS UNCHANGED. Worst at-cap flat R 1.021 x 1.12 = 1.14; worst
# at-cap gapped R 1.254 x 1.12 = 1.404, and 1.41 ships - the shipped
# gapped factor now carries its 12% margin plus 0.4%. Neither needs
# moving. The at-cap rows are 001 (74% of frames within 3% of the cap),
# 003 (96%) and 004 (98% of the cap at its peak); 002 and 005 are
# content-limited (peak 0.61 / 0.53 of the cap) and 006/007/008/009 are
# streamed at derived budgets, so none of those four can drive a cap
# de-rating.
#
# THE SPARSE END, NOW WITH FOUR POINTS. R rises monotonically as
# density falls, on both classes: flat 1.010-1.021 at-cap -> 1.037/1.080
# on the two streamed flat clips (mean 0.33-0.41 of the cap), gapped
# 1.254 at-cap -> 1.402 (009, streamed) -> 1.891 (006, test card, 8.6%
# of the surface touched). 009 IS the intermediate gapped row Card #5
# and Card #8 both asked for, and it says the two gapped clusters are
# joined by a density slope rather than a height one - but it is a
# STREAMED row at a derived budget, so it does NOT bear on the cap
# de-rating (an at-cap frame is a DENSE frame by construction, and the
# dense end is where the factor is fitted). It bears on the SUPPLY
# GATE's busy term instead - see the note in stream_supply_check.
# ---------------------------------------------------------------------
# W4 RE-DERIVATION (2026-08-02, same standing rule: worst DENSE
# measured R x 1.12). The two-key dispatch split made the model ~3.5-4%
# cheaper on the calibration streams, so every recomputed R rose by the
# same arithmetic (silicon numerator untouched) and the factors move
# with them or the cap silently loses its margin: a cap-full of
# NEW-model work is MORE silicon work than a cap-full of old-model
# work. flat: worst dense 1.062 (002) x 1.12 = 1.189 -> 1.19; gapped:
# worst dense 1.302 (003) x 1.12 = 1.458 -> 1.46. Caps @25fps:
# flat 835,088 -> 800,000 T; gapped 675,177 -> 652,055 T (-4.2% / -3.4%
# of budget, which is the honest price of the model having been
# over-priced on the dominant copy class).
TMODEL_COMPOSITION_FACTOR = {
    "flat":   1.19,   # worst DENSE re-keyed R 1.062 (002) x 1.12 [W4,
                       #   2026-08-02]. Was 1.14 (Card #8 re-fit at the
                       #   single-key model, worst 1.021), 1.00 before.
    "gapped": 1.46,   # worst DENSE re-keyed R 1.302 (003) x 1.12 [W4,
                       #   2026-08-02]. Was 1.41 (Card #8, worst 1.258),
                       #   1.15/1.55 before that.
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
#   busy_ms + audio_ms + demand_bytes / (wire * audio_factor)
#                                                   <=  frame period
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
#     ratios from the fixture table above - NOT the margined
#     COMPOSITION factor, which de-rates the encode budget and would
#     reject silicon-healthy encodes here (feasibility wants the
#     honest estimate, budget de-rating wants the margin) - and it is
#     converted to TRUE decode wall time (Card #8; see the function).
#   - the AUDIO phase is serial with both, so it is subtracted too.
#
# Calibration anchors:
#   007 classic  utilization 1.00 -> HEALTHY [Card #3, 2026-07-25]
#                (period 623.8/625 ticks, 0 underruns - at capacity,
#                and it held). Under the Card #8 gate this file reads
#                ~1.07-1.10; see the RESIDUAL note in the function.
#   008 full     utilization 1.74 -> COLLAPSED [Card #3] (predicted
#                equilibrium ~70 ms/frame vs 65.5 observed; depth 1)
#   008 sb0.51   utilization 0.934 under the PRE-Card #8 gate ->
#                ADMITTED, and silicon underran it 914/1286 and
#                1141/1508 frames on two runs, min depth 1 sector,
#                frames 656-658 ticks vs a 625-tick period [Card #8,
#                2026-07-28]. THE FAILURE THAT DROVE THE CORRECTION -
#                the corrected gate reads it 1.060 and refuses it.
#   009 sb0.54   utilization 0.805 pre-Card #8 / 0.970 corrected ->
#                ADMITTED both ways, and silicon is CLEAN (zero
#                underruns, min ring depth 42 blocks) [Card #8]. The
#                pair 008/009 brackets the true ceiling from both
#                sides, which is what makes the correction testable.
#   008 pal9h    auto-derived budget 0.43, gate 0.879 -> ADMITTED, and
#                silicon is CLEAN [2026-07-30, nex 847A6D80]: 772 frames
#                (4 passes), ZERO underruns, zero depth clips, min ring
#                depth 2103 blocks (1.08 MB = 44 frames of demand),
#                624.5 ticks/frame against 625, ERR=00. THE CORRECTION'S
#                OWN TEST PASSED - this is the file the pre-correction
#                gate admitted at 0.934 and silicon underran on 71-76%
#                of frames with the ring pinned at depth 1. Not
#                over-corrected either: with the MEASURED R the true
#                mean is 0.899 (the 0.90 target exactly) and the true
#                ceiling (util 1.00) sits at sb ~0.48, so 0.43 is the
#                intended ~10% p95 margin below capacity.
#   009 pal9h    gate 0.896 -> ADMITTED, silicon CLEAN again (zero
#                underruns, zero depth clips, FRM 252/252, 623.6
#                ticks/frame; min depth 39 blocks is the play-once EOF
#                drain) - no regression against the Card #8 row it
#                repeats [2026-07-30].
# The infeasibility line is utilization > 1.0; STREAM_WARN_UTIL warns
# above 0.90 (at-capacity encodes have no burst margin beyond the
# ring). Files at or below STREAM_RESIDENT_POOL_B load RESIDENT on
# the reference fresh-boot 2MB machine and skip the check (smaller
# pools stream them too, disclosed on the leg card as underrun-prone).
# ---------------------------------------------------------------------
# SPARSE-GAPPED CAVEAT (Card #5, re-measured Card #8): the gapped rows
# below are the DENSE real-footage measurement. A SPARSE gapped stream
# (006-class: most of the surface skipped every frame) runs R ~1.89
# (1.92 on Card #5 - unmoved), so busy_ms below is ~1.5x optimistic for
# such content. It is not a streaming hazard because
# the two terms are anti-correlated - sparseness that inflates R also
# collapses the byte demand the wire term prices: a 006-class streamed
# clip totals busy 20.2 ms + SD 6.0 ms = 0.66 utilization on the
# measured numbers. Disclosed, not machined around (cf. the SKIP16
# under-price, task-2-final-settlement section 5.3).
# 2026-07-30 EXTENDS THE CAVEAT TO EVERY CLASS AND PUTS NUMBERS ON IT:
# the three STREAMED fixtures were measured directly (007 R 1.037, 008
# 1.080, 009 1.402 vs the 1.02 / 1.01 / 1.26 below), so the table is
# 1.6-10.1% optimistic on the sparse-because-budget-scaled files this
# gate actually governs, not only on 006-class test cards. Still not a
# hazard - all three ran silicon-clean and their TRUE utilizations are
# 0.896 / 0.899 / 0.938 - and still disclosed rather than nudged: the
# under-price is a DENSITY effect, and re-keying these entries on
# density (instead of shape alone) is the honest fix, not a constant
# bump that would over-price dense streams. See stream_supply_check.
# W4 RE-KEY (2026-08-02): the table is now DENSITY-keyed inside each
# shape class - the 2026-07-30 sitting's own finding ("R rises
# monotonically as density falls, on both classes") made actionable,
# replacing the shape-only key that was 1.6-10.1% optimistic on exactly
# the budget-scaled streamed files the supply gate governs. Each class
# carries (density, R) anchors, where density = mean modeled decode-T
# utilization of the shape's usable budget (the quantity the gate has
# in hand); silicon_r() interpolates linearly between anchors and
# CLAMPS to the nearest measured point outside them - no extrapolation.
#
# ANCHOR PROVENANCE - every R below is the W4 ARITHMETIC RECOMPUTE of a
# measured row (R_new = R_measured x model_T_old / model_T_new, the
# silicon numerator untouched; op-walk of the pal9l staged bytes under
# both coefficient sets, W4 report table). Dense anchors: Card #8
# (2026-07-28); streamed anchors: the 2026-07-30 sitting rows
# 007/008/009. The recompute preserves R x model_T on the calibration
# streams EXACTLY, so the gate's predicted decode time is unchanged
# where it was calibrated (selftest-pinned):
#
#   | anchor | fixture | R meas | T old/new ratio | R re-keyed | density |
#   |--------|---------|--------|-----------------|------------|---------|
#   | flat_256 dense    | 002 | 1.021 | 1.03977 | 1.062 | 0.574 |
#   | flat_256 streamed | 007 | 1.037 | 1.03300 | 1.071 | 0.416 |
#   | flat_320 dense    | 001 | 1.008 | 1.04321 | 1.052 | 0.919 |
#   | flat_320 streamed | 008 | 1.080 | 1.02407 | 1.106 | 0.342 |
#   | gapped dense      | 003 | 1.258 | 1.03504 | 1.302 | 0.950 |
#   | gapped streamed   | 009 | 1.402 | 1.02588 | 1.438 | 0.433 |
#
# Densities are quoted against the W4 caps (usable_budget_t at the
# re-derived composition factors below) - the exact quantity the gate
# computes for its own streams.
#
# Not anchored, disclosed: 005 (flat_256 dense, re-keyed 1.057 at
# density 0.520) reads ~1% under the interpolated line - the line is
# the conservative side and 002 stays the binding dense row, exactly as
# the old worst-in-class key had it. 004 (gapped dense, re-keyed 1.165
# at 0.878) is likewise below the gapped dense anchor - the class still
# takes the WORST dense row (003), unchanged convention since Card #8
# refuted the height slope. 006 (gapped SPARSE test card, re-keyed
# 1.967 at density 0.386) sits far above the streamed anchor at nearly
# the same density: mean-T density does not separate a skip-dominated
# test card from a budget-scaled real clip, so the sparse end CLAMPS at
# the streamed anchor and the 006-class under-price stays a disclosed
# caveat exactly as before (not a hazard - sparseness collapses the
# byte demand the wire term prices; see the block above).
TMODEL_SILICON_R = {
    "flat_256": ((0.416, 1.071), (0.574, 1.062)),
    "flat_320": ((0.342, 1.106), (0.919, 1.052)),
    "gapped":   ((0.433, 1.438), (0.950, 1.302)),
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
                                                # figure deliberately, and
                                                # Card #8 EXONERATED it: see
                                                # the wire-term note in
                                                # stream_supply_check, which
                                                # measures what the ring
                                                # producer actually delivered
                                                # on silicon (1163 B/ms) and
                                                # finds wire x af = 1100 B/ms
                                                # conservative by 5.5%, i.e.
                                                # margin and not the defect

# Per-frame AUDIO-COPY cost, in T per PADDED audio byte - the timeline's
# own AUDIO phase (vid_aud_copy's 1250 B seam-walked LDIR into the
# double buffer, plus the hand-off), which is serial with DECODE and
# with the pace window and is therefore time the SD producer does NOT
# have. The streaming gate omitted it entirely.
#
# DERIVED (Card #8, 2026-07-28) from the AUDIO phase of all eight Group
# A rows at a 1536 B padded stereo layout: 19.88 / 20.09 / 20.60 /
# 20.09 / 20.10 / 20.38 / 21.55 + 21.61 (008, two runs) / 20.81
# ticks/frame. Taking the WORST, 21.61 ticks x 1792 T = 38,725 T over
# 1536 padded bytes = 25.2 T/B -> 25.0. Expressed per padded byte
# because that is the quantity the gate is handed; the copy itself is
# one double-buffer half per frame, so the term tracks the layout.
AUDIO_COPY_T_PER_B = 25.0

# ---------------------------------------------------------------------
# LOW-FPS PACE CONTENTION (SP17, silicon 2026-08-02). The supply gate
# below is EXACTLY fps-invariant by construction - every term is a
# per-frame quantity over a per-frame period, so halving the fps doubles
# both and the utilisation does not move. Silicon says that invariance
# is wrong at 12.5 fps, and the player says why.
#
# RESOLVED AT SOURCE 2026-08-02 - READ THIS FIRST. The player's ring is
# now the WHOLE 8 KB audio bank (NXV_AUD_RING 2560 -> 8192) and the
# declarable per-frame bound is pinned at 3072, so the room condition
# below holds for EVERY legal file with 2032 bytes to spare and
# trickle_frac is identically zero at every encodable fps. The term,
# its constant and this whole derivation are KEPT - they are the record
# of what the defect was and the guard that re-prices it should either
# constant ever move again - but they no longer fire. What follows is
# stated in the past tense where it describes the pre-fix player.
#
# THE PLAYER MECHANISM (src/video.asm, the T10 circular audio feed).
# The writer may never be more than the ring's usable span (ring minus
# the writer guard) ahead of the ISR read pointer, and at the pace
# release the ring already holds one whole frame of audio. So the NEXT
# frame's feed fits the single post-present pump (the `.qnext`
# `ld bc,$FFFF` call) if and only if 2 x aBytes <= AUD_RING-AUD_GUARD.
# That span was 2544 bytes; above it the remainder was ROOM-LIMITED and
# trickled from the `.pace` spin - which is the SD producer's only
# window. Each spin iteration was then
#     vid_pace_poll -> vid_aud_pump (full path) -> ONE vid_prod_step
# instead of poll -> `ret z` -> produce, so every produced 512 B block
# also paid a complete pump call: two room computations, vid_src_seek
# (ring-page derive + MMU6 map + cursor spill), a ~12-15 B LDIR, the
# budget/feedRem/write-pointer accounting and vid_rl_mod's 24-bit
# modulo. Only the LDIR was charged, through AUDIO_COPY_T_PER_B; the
# rest was unpriced. Worse, the chunk loop advanced at the READER's
# rate (a byte per ~896 T against a 1300-1400 T loop pass), so the
# owner's 12.5 fps silicon rows spent 24-26 ms/frame in there against
# 1.41 ms at 25 fps - ~8x pure waste, with the SD producer stopped.
#
# AND THE TERM UNDER-READ IT BY ~4x, recorded here because
# AUD_PUMP_CALL_T is the sort of constant that gets reused. pump_ms
# priced the per-produced-BLOCK pump overhead (5.2-6.2 ms/frame on
# 016/017/018) but not the reader-paced WAIT, which the AUDIO phase
# measured at 21.8-23.4 ms/frame on top of the ~2.3 ms one-pass copy.
# The error is one-directional and benign: the three clips re-derive
# their budgets from the smaller figure (0.69/0.73/0.83 ->
# 0.75/0.87/0.93), so they get back less picture than the player
# actually recovered and run with margin rather than at the line.
#
#   trickle_frac = max(0, 2*aBytes - (AUD_RING-AUD_GUARD)) / aBytes
#                                 at 2544 span    at 8176 span
#   25 fps      aBytes 1250 -> 0.0000          0.0000
#   23.976 fps  aBytes 1304 -> 0.0491          0.0000
#   20 fps      aBytes 1562 -> 0.3714          0.0000
#   12.5 fps    aBytes 2500 -> 0.9824          0.0000
#   10.17 fps   (the floor, aBytes 3072)       0.0000
#
# THE SILICON THAT FOUND IT (three independent rows, 2026-08-02, all
# 320x256 stereo streamed, all admitted by the uncorrected gate):
#   053 boat 12.5      gate 0.890 -> shallow ring
#   054 Caprica lt 12.5 gate 0.898 -> shallow ring
#   061 Caprica bm 12.5 gate 0.904 -> 2.9% OVER RATE, 85/107 underruns,
#                                      min ring depth 4 blocks
# The 25 fps arms of the same sources are clean at the same demand per
# second (048 boat 522.3 KB/s vs 053 518.0; 060 Caprica bm 612.4 vs 061
# 616.9), and the emitted op census matches per second (048/053: 8373 vs
# 8410 ops/s, 16.86 vs 16.79 model T per payload byte) - so the missing
# time is not decode, and silicon_r is not the defect. It is supply, and
# it appears only where the pace loop is contended.
#
# AUD_PUMP_CALL_T is the HAND COUNT of that pump path from
# src/video.asm (~1660 T unarmed, ~1950 T with the armed audio tax - the
# gate's other terms are true wall time, so the armed figure is the one
# used), NOT a fit to the desired verdict. The three rows above bracket
# it at 1470-2890 T (1470 puts 054 at the 0.95 warn line, 2224 puts 061
# exactly on the 1.00 refusal line, and 052 - clean at 12.5, util 0.727,
# budget 1.00 - tolerates up to 7809 T), and the hand count sits inside
# that bracket. MEASUREMENT ROW: a DEBUG timeline pair on the already
# staged 048 (25 fps) and 053 (12.5 fps) - same source, same shape, same
# demand per second - gives (PACE ticks / blocks produced) at each rate;
# the difference divided by trickle_frac is this constant directly.
# Card #8 already holds the 25 fps side (1163-1166 B/ms).
#
# RESIDUAL, DISCLOSED (superseded by the fix, kept for the record). At
# 1950 T the corrected gate read the shipped 061 at 0.988, not the
# 1.029 it measured - ~4% still optimistic on the worst row (2224 T
# would put it exactly on the refusal line). That residual is moot on
# the whole-bank ring: the term is zero, and what those three rows now
# get back is the 7.4-8.9% of their frame the contention was charging.
#
# SCOPE. Streamed ring transport ONLY. The DIRECT path never runs the
# producer (SD-to-surface, no ring) and has its own gate, and row 057
# (320x256 @12.5 --direct) is silicon-clean - so direct_supply_check and
# SD_WIRE_BYTES_PER_MS (co-fitted to DIRECT_TRANSPORT_FACTOR) are left
# alone. At 25 fps the term was already EXACTLY zero, so every silicon
# anchor the gate is calibrated on (007/008/009, Card #3, Card #8) was
# untouched by the term and is untouched by its removal.
# ---------------------------------------------------------------------
AUD_PUMP_CALL_T = 1950.0

STREAM_RESIDENT_POOL_B = 78 * 16384            # fresh-boot 2MB pool ring
STREAM_WARN_UTIL = 0.90
STREAM_TARGET_UTIL = 0.90                       # suggestion target


# ---------------------------------------------------------------------
# AUTO-BUDGET (SP17 T1) - the encoder derives --stream-budget itself
# ---------------------------------------------------------------------
# WHY. --stream-budget is a SUPPLY CEILING, not a quality dial. SP17 E2
# measured the whole ladder on one clip (Sintel classic, only the budget
# varied): 0.85 -> util 1.00 / PSNR 25.27 / 42% of frames budget-bound;
# 0.70 -> 0.89 / 23.83 / 66%; 0.55 -> 0.74 / 22.10 / 88%; 0.40 -> 0.56 /
# 20.11 / 92%. Every metric moves the same way - a lower budget buys
# nothing, it only starves the picture. There is exactly one right
# answer per clip (the highest budget the wire can carry), no author can
# guess it, and the default 1.0 is refused outright on ordinary content.
# So the encoder searches for it, by default, and the author sets a
# budget only to override that search.
#
# TARGET POINT (AUTO_BUDGET_TARGET_UTIL). "Highest accepted" is the
# WRONG answer: the gate is a whole-clip MEAN (see its own limitation
# block below), and SP17 E6 measured what a mean at the ceiling actually
# contains - fixture 007 at mean utilization 0.981 has p95 1.071, max
# 1.502, 138/250 frames instantaneously over budget in runs up to 19
# consecutive frames (0.76 s). Owner silicon calls that band-and-judder,
# not "fine, the ring absorbs it". The margin is derived from that same
# row: p95/mean = 1.071/0.981 = 1.09, so holding the p95 frame at or
# under 1.00 wants a mean at or under 1/1.09 = 0.917. 0.90 is the next
# round figure below it, and it is already this module's own
# STREAM_TARGET_UTIL - the point the supply gate's suggested_budget
# aims at - so the automatic search and the gate's own advice now name
# the same operating point instead of two different ones, and an
# auto-derived encode never trips STREAM_WARN_UTIL either. Overridable
# per encode (videnc --budget-target) for anyone re-deriving it against
# fresh silicon.
AUTO_BUDGET_TARGET_UTIL = STREAM_TARGET_UTIL

# Accept band. A probe landing in [target - TOL, target] stops the
# search: closing further costs a full encode pass and buys under half a
# dB. The band is one-sided on purpose - the search never accepts a
# probe ABOVE the target while it still has probes left.
AUTO_BUDGET_TOL = 0.02

# Cap on encode passes per clip, INCLUDING the first (budget 1.00) probe
# and the pass whose payloads are ultimately written - the accepted
# probe's stream is reused verbatim, so a converged search costs exactly
# this many encode_clip passes and not one more. Measured (SP17 T1): 2
# passes when the answer is the ceiling or the clip is content-limited,
# 5 on the hardest case tried (Sintel classic at full 10 s - the E2
# ladder clip - probing 1.00/0.85/0.65/0.72/0.71). 6 leaves one pass of
# headroom without ever letting a kit BUILD run away.
AUTO_BUDGET_MAX_PROBES = 6

# Floor for a derived budget - matches stream_supply_check's own
# suggested_budget clamp. Below this the picture is gone anyway and the
# right answer is a smaller shape or a lower fps, which the gate's
# refusal message already names.
AUTO_BUDGET_MIN = 0.05

# PLATEAU cut-off, in utilization per unit of budget, measured
# CUMULATIVELY from the first (budget 1.00) probe - see the guard's own
# comment in auto_stream_budget for why a single step is not evidence.
# Above the point where the per-frame caps actually bind, utilization is
# set by the CONTENT and a budget cut moves it barely at all; below that
# point the E2 ladder measures a slope near 0.7-1.0 (0.85/0.70 ->
# 1.00/0.89 is 0.73). Anything under 0.10 is the flat region, where a
# further cut is pure picture loss for no supply relief - the search
# stops there rather than paying it.
AUTO_BUDGET_MIN_SLOPE = 0.10

# Largest single UNBRACKETED downward step. The secant's slope early in
# a search is read off points that may both sit on the plateau, which
# understates how fast utilization falls once the cap bites; without a
# leash one blind step lands deep in starvation and the probe budget is
# spent climbing back out.
AUTO_BUDGET_MAX_STEP = 0.20

# Step taken when two consecutive probes measure the SAME utilization
# and there is nothing feasible yet to stop on - the cut was too small
# to bite, so take a real one.
AUTO_BUDGET_STEP = 0.10


# ---------------------------------------------------------------------
# DELTA-STARVATION DIAGNOSTICS (report-only; thresholds RETIRED)
# ---------------------------------------------------------------------
# WHAT IS MEASURED, AND WHY IT IS WORTH MEASURING. The supply gate above
# is a whole-clip MEAN over the transport and is blind to picture
# damage: fixture 007 passed it at utilization 1.00 with every transport
# counter clean on silicon (zero underruns, zero depth clips, ERR=00)
# while the picture carried sustained horizontal banding. The artifact
# is in the WIRE bytes, not the transport - when a frame's deltas do not
# fit the per-frame caps, encode_delta spends the budget on whole
# paint-order tiles (SP17: the finest ladder rung the byte spend allows,
# coarsest TILE_BAND = 4 rows in mode-0) and the deferred tiles read as
# strips of stale content. starvation_stats()
# counts those budget-bound frames, their worst concentrated run, and
# the delta-frame PSNR tail. Those measurements are sound and are
# REPORTED on every streaming encode.
#
# WHAT WAS WITHDRAWN. Owner ruling 2026-07-28 (second ruling, same day):
# the WARNING this section used to emit is gone from the author-facing
# output path. encode() now prints measurements and no verdict. The two
# threshold constants and starvation_warns() below are RETIRED /
# UNCALIBRATED - kept in place, unreferenced by encode(), so the
# re-derivation work has them to hand. DO NOT re-enable a warning on
# these numbers without new ground truth.
#
# WHY (do not re-derive the same wrong metric). The trigger fired on
# budget-bound frame FRACTION, and that metric is refuted by its own
# anchor:
#
#   008 (BBB full 320x256, sb 0.51)   250/252 = 99.2% bound, p10 25.98
#                                     - owner passed it VISUALLY CLEAN
#                                       on silicon
#   007 (Sintel classic, sb 0.85,      91/250 = 36.4% bound, p10 24.68
#        --dither 0.25)                - visibly BANDED on silicon
#
# A metric on which the CLEAN fixture scores nearly three times the
# BANDED one separates nothing, in either direction. 0.08 was fitted to
# a two-orders-of-magnitude gap that does not exist: the 008 row was
# first transcribed as 2/252 = 0.8%, and a re-encode on 008's own
# build-tests recipe reproduces util 0.93 and p10 25.98 EXACTLY while
# reading 250/252 - so "0.8%" was "99.2%" with digits lost, not a
# different operating point. The remaining fitted ground truth is void
# as well: the owner reports banding across his own content, so the
# 007/008 pair is not the banded/clean population pair the thresholds
# were derived against.
#
# WHAT TO MEASURE INSTEAD. Deferral COUNT does not predict visibility -
# deferral SEVERITY does. Every frame of a heavy clip can be
# budget-bound while each defers only a band or two (invisible), and a
# single frame that defers most of its bands is ruined on its own. The
# likely axis is HOW MUCH of a bound frame went unpainted (deferred
# bands, or deferred bytes as a fraction of that frame's full delta
# demand) and how long any one band is held stale - not how many frames
# touched the cap. Re-derivation needs a fresh silicon-graded ground
# truth set; the per-frame records starvation_stats() already walks are
# the right raw material to build the severity measure from.
#
# MEASURED POINTS, retained for re-derivation (007 = Sintel fight,
# classic 256x192@25 sb 0.85; budget-bound = per_frame binding
# "budget", over all emitted frames):
#
#   007 --dither 1.00   114/250 = 45.6%   p10 21.94  worst banding
#   007 --dither 0.50   106/250 = 42.4%   p10 23.37  SEVERELY banded on silicon
#   007 --dither 0.25    91/250 = 36.4%   p10 24.68  still visibly banded on silicon
#   007 --dither 0.00    54/250 = 21.6%   p10 25.88  (not silicon-viewed)
#   008 (util 0.93)     250/252 = 99.2%   p10 25.98  visually CLEAN on silicon
#
# (The 007 diagnosis also quoted 123/250 for the shipped d0.50 file:
# that is the WIRE-TRACE count of frames within 512 B of the byte
# ceiling, a looser proxy. These rows count the encoder's own binding
# label, which is exact - a frame is budget-bound iff the full delta did
# not fit and the region schedule ran.)
#
# RETIRED trigger, whole-clip. Was: warn above this bound fraction.
# Refuted by the 008 row above - not calibrated, not referenced by
# encode(), kept only as the starting point for re-derivation.
STARVE_WARN_BOUND_FRAC = 0.08

# RETIRED trigger, concentrated burst. Was: warn when the worst sliding
# window over the emitted frame sequence exceeded this fraction, to
# catch short severe runs the whole-clip mean dilutes (15 consecutive
# bound frames in a 250-frame clip is 6.0%, but at 25 fps it is 0.6 s of
# unbroken banding). The window IDEA survives the retirement - a
# severity measure will still need a concentration term - but the 0.60
# bar was derived from the same refuted bound-fraction axis and against
# the mis-transcribed 008 anchor, so it is UNCALIBRATED too.
STARVE_WARN_BURST_FRAC = 0.60

# LIVE measurement parameter (not a threshold): the sliding-window
# LENGTH used by starvation_stats() to report the worst concentrated
# run. A fixed DURATION converted to frames per clip fps - an
# fps-invariant window is the only one that means the same thing to a
# viewer (a fixed frame count would be 0.5 s at 25 fps and 1.25 s at
# 10 fps). 0.5 s is the perceptually relevant scale: below roughly a
# quarter-second a stale band reads as a transient flicker the eye
# forgives, while half a second of held-stale strips reads
# unambiguously as broken picture.
STARVE_BURST_WINDOW_S = 0.5


def silicon_r(width, height, density=None):
    """Measured composed-player decode ratio for this shape cluster at
    this DENSITY (mean modeled decode-T utilization of the shape's
    usable budget): R = silicon T/frame / (model T/frame / audio_factor),
    so R x model_T is af x the true silicon decode T (see the AF
    CONVENTION note in the composition-factor block - a caller wanting
    true decode time divides by af again).

    density None fails safe to the SPARSE-end anchor (the largest R in
    the class) - the conservative direction for every planning-time
    caller that cannot know its stream's density yet. Callers with a
    dense-by-construction frame (keyframe chunks) pass density=1.0 and
    clamp to the dense anchor.

    W4 DENSITY KEY (2026-08-02): linear between the class's measured
    anchors, clamped outside them - see the TMODEL_SILICON_R block for
    the anchors, their provenance and the disclosed non-anchored rows.
    NO HEIGHT INTERPOLATION on gapped shapes, unchanged since Card #8
    refuted the height slope (h=192/h=144 swapped order): every gapped
    height reads the one gapped class, worst dense row anchored."""
    if not is_gapped(width, height):
        key = "flat_320" if int(width) == 320 else "flat_256"
    else:
        key = "gapped"
    (d_lo, r_lo), (d_hi, r_hi) = TMODEL_SILICON_R[key]
    if density is None:
        return max(r_lo, r_hi)
    d = float(density)
    if d <= d_lo:
        return r_lo
    if d >= d_hi:
        return r_hi
    return r_lo + (r_hi - r_lo) * (d - d_lo) / (d_hi - d_lo)


def pace_trickle_frac(audio_real_bytes):
    """Fraction of a frame's audio feed that is ROOM-LIMITED and must
    trickle from the player's `.pace` spin (see the LOW-FPS PACE
    CONTENTION block). 0.0 whenever 2 x aBytes fits the ring's usable
    span - which, since the ring became the whole audio bank, is EVERY
    encodable fps: AUD_FRAME_MAX 3072 caps 2 x aBytes at 6144 against a
    span of 8176. The function is kept as the live guard on that
    inequality rather than hard-wired to zero, so that moving either
    constant re-prices the gate instead of silently under-charging it.

    NOTE the span is AUD_RING-AUD_GUARD, not AUD_FRAME_MAX: the two
    were the same number until 2026-08-02 and this used the bound by
    coincidence. The player's room test is against the ring."""
    a = float(audio_real_bytes or 0)
    if a <= 0.0:
        return 0.0
    span = AUD_RING - AUD_GUARD
    return max(0.0, min(1.0, (2.0 * a - span) / a))


def stream_supply_check(mean_t, mean_demand_bytes, audio_pad_bytes, fps,
                         width, height, audio_real_bytes=None):
    """Mean-rate streaming feasibility for an emitted stream. mean_t =
    mean modeled decode T/frame (TMODEL prices), mean_demand_bytes =
    mean (audio pad + 512-padded payload) per frame. Returns a dict:
    utilization (busy + audio copy + SD time + pace-pump contention
    over the frame period; > 1.0 is unstreamable), busy_ms, audio_ms,
    sd_ms, pump_ms, period_ms, demand_kbs, and suggested_budget (the
    --stream-budget scale that lands the mean at STREAM_TARGET_UTIL,
    from the audio-demand-invariant solve). audio_real_bytes: the
    encode's REAL (pre-pad) audio bytes/frame - the quantity the
    player's ring room test uses; None (legacy callers) prices no pace
    contention, which since 2026-08-02 is correct at EVERY encodable
    fps (the ring is the whole audio bank - see pace_trickle_frac)."""
    af = TMODEL_COEFFS["audio_factor"]
    clock = TMODEL_COEFFS["clock_khz"]
    period_ms = 1000.0 / float(fps)
    wire_eff = SD_WIRE_BYTES_PER_MS * af
    # W4 density re-key: the gate knows its stream's density exactly -
    # mean modeled T over the shape's usable budget - so the busy term
    # reads the density-keyed R instead of the shape-only worst
    density = mean_t / usable_budget_t(fps, width, height)
    # THE BUSY TERM IS THE TRUE SILICON DECODE TIME (Card #8 correction,
    # 2026-07-28). silicon_r() carries R's own /af (see the AF
    # CONVENTION note in the composition-factor block), so R x mean_t is
    # af x the decode time silicon actually spends; dividing by af here
    # undoes that and leaves wall-clock decode. This term used to be
    # mean_t * silicon_r / clock, defended as a deliberate second
    # placement of af co-fitted with the wire floor - and it was
    # measurably wrong on Card #8: for 008 it priced busy at 11.50 ms
    # against a MEASURED DECODE phase of 16.18 ms (two runs, 252.8 and
    # 252.4 ticks/frame). Two independent errors stacked: silicon_r was
    # still fitted against the pre-SP17 T model (~15%), and the af
    # division was never undone (~15%). The gate therefore admitted 008
    # at utilization 0.934 - and silicon underran it on 71.1% and 75.7%
    # of frames across two runs, ring pinned at a MINIMUM DEPTH OF ONE
    # SECTOR throughout, frames stretched to 656-658 ticks (42.0 ms)
    # against a 625-tick period. Both errors are fixed here (R re-fitted
    # from Card #8's own rows; af undone).
    #
    # THE WIRE TERM IS NOT THE DEFECT, and Card #8 says so with a
    # measurement rather than an argument. In 008's chronic regime the
    # producer never idles, so its whole pace window IS production time:
    # 28,461 B/frame over a PACE phase of 381.4 ticks (run 1) and 383.0
    # ticks (run 2) = 1166 and 1161 B/ms delivered, agreeing to 0.4%.
    # wire_eff below is 1100 B/ms - 5.5% CONSERVATIVE against what the
    # ring producer actually achieved. SD_WIRE_BYTES_PER_MS stays where
    # it is (and so, therefore, does DIRECT_TRANSPORT_FACTOR, which is
    # co-fitted to it): the af on the wire is doing the work of a
    # transport de-rating - the same per-block open, token-wait and
    # re-arm glue the direct path measured explicitly as 1.20 - not a
    # second audio tax, and it is carrying real margin.
    #
    # VALIDATION. With both corrections the gate predicts 008's frame at
    # busy 15.18 + audio 1.37 + wire 25.87 = 42.42 ms against 42.0/42.1
    # ms measured on two runs (0.9%), and 009 at 38.80 ms - inside the
    # period, which is what 009 measured (zero underruns, min ring depth
    # 42 blocks). The gate refuses 008 at 1.060 and admits 009 at 0.970.
    #
    # RESIDUAL SETTLED (2026-07-30 silicon, DEBUG nex 847A6D80, pal9h).
    # Card #8 left this open: the Card #3 007 anchor was silicon-healthy
    # at 623.8/625 ticks and admitted at util ~1.00 by the old gate, read
    # ~1.07-1.10 under the correction, and its own DECODE phase had never
    # been transcribed - so a low class R (0.78 rather than 0.834) was
    # the available reconciliation. A VSTR0 row WITH its DECODE phase now
    # exists (0000E0DE over 250 frames = 230.3 ticks = 14.74 ms/frame),
    # and it REFUTES the low-R reading: 007-class content measures R
    # 1.037 - at, and slightly ABOVE, the flat class value of 1.02, never
    # anywhere near 0.78. So the old anchor's health at gate-util 1.00 is
    # not explained by a cheap decode, and the correction stands on the
    # measurement rather than on the conservative direction. What the old
    # anchor actually was is an at-capacity operating point whose
    # TRANSPORT counters were clean while the picture banded (SP17 E6),
    # which is precisely the regime this gate now declines to admit.
    # 007 remains the documented at-capacity stress fixture (owner
    # ruling): on this sitting it still shows heavy horizontal banding
    # with a completely clean transport (ERR=00, zero underruns, zero
    # depth clips) at its auto-derived budget - and the walk says why,
    # 67% of its frames are pinned at the BYTE cap (payload 21,086 B of
    # a 21,086 B cap) rather than at the decode-T cap. That is content
    # out-demanding the wire, not a supply defect.
    #
    # THE BUSY TERM IS OPTIMISTIC ON SPARSE STREAMS, QUANTIFIED. The
    # three streamed fixtures measured on 2026-07-30 read R 1.037 (007),
    # 1.080 (008) and 1.402 (009) against the class table's 1.02 / 1.01 /
    # 1.26, because a stream at a derived budget is SPARSER than the
    # at-cap rows the table was fitted on and R rises as density falls
    # (see the composition-factor block's four-point sparse table). Busy
    # is therefore under-priced by 1.6% / 6.5% / 10.1% on exactly the
    # class of file this gate governs, and the true mean utilizations are
    # 0.896 / 0.899 / 0.938 where the gate reports 0.890 / 0.879 / 0.896.
    # All three are silicon-CLEAN, so this is margin consumed, not a
    # failure - but it is the AUTO_BUDGET_TARGET_UTIL margin (0.90 held
    # for p95 excursions) that is being consumed. The honest fix is a
    # DENSITY-AWARE R rather than a nudge to the shape-keyed table (a
    # nudge would over-price dense streams, which measure 1.25 at cap),
    # so it is disclosed here and left to owner ratification.
    busy_ms = mean_t * silicon_r(width, height, density) / af / clock
    # the AUDIO phase: serial with decode and with the pace window, so
    # it is period the producer never gets (see AUDIO_COPY_T_PER_B)
    audio_ms = audio_pad_bytes * AUDIO_COPY_T_PER_B / clock
    sd_ms = mean_demand_bytes / wire_eff
    # PACE CONTENTION (see the LOW-FPS PACE CONTENTION block): when the
    # audio feed is room-limited the producer pays one full vid_aud_pump
    # per produced 512 B block over trickle_frac of the frame. EXACTLY
    # zero at every encodable fps since the player's ring became the
    # whole audio bank, so this line cannot move ANY encode by so much
    # as a rounding tick - it is the guard, not a live charge.
    pump_ms = (pace_trickle_frac(audio_real_bytes)
               * (mean_demand_bytes / 512.0) * AUD_PUMP_CALL_T / clock)
    util = (busy_ms + audio_ms + sd_ms + pump_ms) / period_ms
    # scaling the operating point scales busy and the payload part of
    # demand; the audio pad and its copy cost are invariant. pump_ms is
    # proportional to the produced blocks, so it scales too - which is
    # what makes a contended clip RE-BUDGET rather than merely fail.
    audio_sd_ms = audio_pad_bytes / wire_eff
    payload_sd_ms = sd_ms - audio_sd_ms
    fixed = audio_sd_ms + audio_ms
    scalable = busy_ms + payload_sd_ms + pump_ms
    suggested = ((period_ms * STREAM_TARGET_UTIL - fixed) / scalable
                 if scalable > 0 else 1.0)
    return dict(utilization=util, busy_ms=busy_ms, audio_ms=audio_ms,
                sd_ms=sd_ms, pump_ms=pump_ms,
                period_ms=period_ms, audio_sd_ms=audio_sd_ms,
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
#
# GOVERNANCE (SP17 T8, 2026-08-01) - RESOLVED 2026-08-02, see the
# re-fit below. The player's direct transport was REBUILT in the T8
# wave (vid_ds_xfer inir arms -> computed-entry unrolled-ini run;
# vid_ds_pad byte loop -> unrolled in a,(n) run - REVERTED to the byte
# loop 2026-08-02, commit 01466ec, after the silicon ERR=FD regression;
# blkopen reload slim). The W2 arithmetic predicted factor 0.93-0.99,
# but 1.20 was silicon-settled against the OLD transport, so the
# default was HELD at 1.20 until the hardware round's NXBD re-run
# measured the true new rate. That re-run has now happened.
#
# RE-FITTED FROM FRESH SILICON (2026-08-02, owner hardware, DEBUG nex
# 6404FC6E post-01466ec, 010.VID at pal9m, DeZog per-row and full-table
# dumps in exact agreement). NXBD rows, raster lines (T = lines * 1824
# over 128 blocks; instrument ~167 T/block inside the absolutes):
#
#   | row | new  | 07-30 | T/blk new | T/blk old | meaning            |
#   |-----|------|-------|-----------|-----------|--------------------|
#   | DTA |  731 |  731  |  10,417   |  10,417   | wire ref, unchanged|
#   | DTI |  756 |  757  |  10,773   |  10,787   | blkopen slim ~-14 T|
#   | DTB | 1670 | 1672  |  23,798   |  23,826   | pad revert confirmed|
#   | DTC |  816 |  961  |  11,628   |  13,694   | xfer swap: -2,066 T|
#   | DTD |  894 | 1023  |  12,740   |  14,578   | 4x128B arm shape   |
#   | TOK | 640/640 (2.000 polls/blk, ~126 T token wait - unchanged)  |
#
# The unrolled-ini xfer landed: whole-block transport 22.4 T/B against
# 26.4 pre-W2 (DTC absolutes less instrument). DTB-DTI is POSITIVE
# again (+25.4 T/B pad excess, matching July-30 within the one-line
# quantum) - the pad revert on silicon, as expected. DTD-DTC rose
# 883 -> 1112 T (the computed-entry per-call price on short arms);
# irrelevant to shipping, real chunks are block-sized.
#
# THE SHIPPING NUMBERS COME FROM WHOLE-FRAME PLAYBACK, same sitting,
# same build (Card #8 discipline: fit what the transport DELIVERED).
# Two direct probes at --direct-transport-factor 0.96:
#   056  256x160@25 stereo:  TOT unwraps 638.79 ticks/frame = 40.882
#        ms for the 43,008 B ordinary section (2.2% OVER period);
#   057  320x256@12.5 stereo: TOT exactly 1250 ticks/frame, PACE 1366
#        ticks/74 frames -> busy 78.819 ms for the 84,992 B section.
# Two-point solve (direct sections are 512-aligned, so per-block and
# per-byte fold into one rate; what remains is per-FRAME):
#   rate r = 41,984 / (78.819 - 40.882) = 1106.7 B/ms armed
#   fixed F = 40.882 - 43,008/r        = 2.021 ms/frame
# r sits 0.6% ABOVE wire*af (1100.19 B/ms): the T8 xfer win took the
# per-byte transport to the bare wire floor. The old FLAT factor can no
# longer express the truth: the 25 fps refusal line needs an effective
# 1.047 (056 measured 1.046) while 12.5 fps needs 1.020 (057 measured
# 1.020) - NO single flat factor both refuses 256x160@25 (silicon: 2.2%
# slow) and admits 320x256@12.5 (silicon: at rate, 0.7 ms true slack).
# The fps-dependence IS a fixed per-frame term, so the gate now carries
# TWO constants: a per-byte factor and a per-frame overhead. F's
# attribution: the section-pad byte-loop discard (~1.0-1.1 ms at the
# reverted ~46 T/B), the audio-feed trickle bookkeeping, op parse
# (KSTART/COPY16/KFLIP, +PAL on cuts) and per-frame session glue.
# Bench cross-check: DTC absolute (22.39 T/B unarmed) puts the armed
# block rate at 1063 B/ms, 4% under the playback r - the bench's tight
# loop hits every data-token wait cold where playback's between-block
# work gives the card staging time; playback is the authority.
#
# SHIPPED VALUES AND MARGIN. Factor 1.00 (+0.6% over the measured
# 0.994) and overhead 2.2 ms (+8.9% over the measured 2.021) - a
# combined ~1.1% margin at the 25 fps refusal line, ~0.8% at 12.5 fps.
# Admissions against this sitting's silicon:
#   256x160@25 st  refused at util 1.044 (silicon: 2.2% over - correct)
#   320x256@12.5 st admitted at 0.999    (silicon: at rate + slack)
#   256x153@25 st  admitted at 0.997, predicted worst 39.49 ms (the
#                  re-encoded 056 acceptance probe - must play at rate)
#   256x133@25 st  (010/011 anchors) 0.881, predicted 34.4 ms - clean,
#                  as this sitting's PICK 10/11 exact-TOT rows show.
# Direct at-rate envelope under this gate (util 1.00 / 0.90):
#   25   fps  256x153 / 320x123   (0.90: 256x135 / 320x108)
#   12.5 fps  full screen both widths (0.90: 320x228)
# The expert override videnc --direct-transport-factor still exists and
# overrides the BYTE factor only - the frame overhead is measured
# physics, not policy, and always applies. Do not move either constant
# without a fresh whole-frame silicon pair; both are co-fitted to
# SD_WIRE_BYTES_PER_MS * audio_factor exactly as before.
DIRECT_TRANSPORT_FACTOR = 1.00

# The per-frame direct transport overhead (ms) - the fixed term of the
# 2026-08-02 two-point whole-frame fit above (measured 2.021, shipped
# 2.2 with the margin argued there). Applies to every direct-serve
# frame regardless of size or fps; the transport_factor expert override
# does NOT scale it.
DIRECT_FRAME_OVERHEAD_MS = 2.2

# Policy line (OWNER-FACING, Card #5 TIGHTEN ruling, 2026-07-26): at
# 1.20 the shipped 010 fixture (classic-wide 256x144 @25 stereo) scored
# 1.075 - it would have played ~6% slow, which is what silicon does.
# The owner ruled STRICT: direct-serve is on-rate or it is refused,
# full stop. There is NO accept-slow override - a utilization > 1.0
# ALWAYS raises SystemExit; see _encode_direct. (010/011 were
# re-encoded inside the envelope rather than shipped slow.)


def direct_supply_check(worst_frame_bytes, fps, transport_factor=None):
    """Direct-serve wire feasibility (SP15 3c, RECALIBRATED Card #5). A
    direct-serve session reads every byte of a frame section (audio
    blocks + payload blocks, padding included) off the SD wire INSIDE
    that frame's own period - the literal bytes are served straight to
    the surface (the unrolled-ini transport, the whole point of the
    mode), and there is NO ring to absorb bursts. The criterion is
    therefore the WORST frame, not the clip mean (contrast
    stream_supply_check's documented mean-rate limitation above).
    audio_factor de-rates the wire exactly as the streaming gate does -
    the ISR sample tax applies to the ini transport identically. The
    cost model is TWO-TERM (2026-08-02 whole-frame silicon re-fit, see
    the DIRECT_TRANSPORT_FACTOR block): a per-byte factor on the wire
    rate (DIRECT_TRANSPORT_FACTOR - the T8 rebuild took the per-block
    transport to the bare wire floor) plus a fixed per-frame overhead
    (DIRECT_FRAME_OVERHEAD_MS - pad discard, audio-feed bookkeeping,
    op parse, session glue; the term a flat factor could not express,
    which is why 25 fps and 12.5 fps silicon disagreed under one).
    transport_factor=None means the shipping DIRECT_TRANSPORT_FACTOR;
    a number is the expert override, which scales the BYTE term only -
    the frame overhead is measured physics and always applies."""
    tf = (DIRECT_TRANSPORT_FACTOR if transport_factor is None
          else float(transport_factor))
    af = TMODEL_COEFFS["audio_factor"]
    period_ms = 1000.0 / float(fps)
    sd_ms = (worst_frame_bytes * tf
             / (SD_WIRE_BYTES_PER_MS * af)) + DIRECT_FRAME_OVERHEAD_MS
    return dict(utilization=sd_ms / period_ms, sd_ms=sd_ms,
                period_ms=period_ms,
                demand_kbs=worst_frame_bytes * float(fps) / 1024.0)


def direct_max_raw_bytes(fps, util=1.0, transport_factor=None):
    """Largest RAW surface (width*height) a direct-serve encode can
    carry at this fps and utilization target, under the recalibrated
    gate. Inverse of direct_supply_check: the frame section is
    audio_pad + 512-rounded(payload), and the payload is KSTART(1) +
    PAL(1+512) + COPY16(3) + raw + terminal(1).
    transport_factor as in direct_supply_check."""
    tf = (DIRECT_TRANSPORT_FACTOR if transport_factor is None
          else float(transport_factor))
    period_ms = 1000.0 / float(fps)
    # the fixed per-frame overhead comes off the period BEFORE the
    # byte budget is priced (inverse of direct_supply_check's two-term
    # model; the override scales the byte term only, as there)
    budget_b = ((period_ms * util - DIRECT_FRAME_OVERHEAD_MS)
                * SD_WIRE_BYTES_PER_MS
                * TMODEL_COEFFS["audio_factor"] / tf)
    # the audio pad comes from audio_layout, NOT a local rate guess -
    # one source of truth for the rate/rounding arithmetic
    apad = audio_layout(fps)[3]
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
    return 3, tc["t_skip16"] + 2 * tc["header_rate"]


def _fill_t(L):
    """Modeled fill-body T for L bytes, gated on the PLAYER's own kernel-
    select rule - the same shape as _copy_t.

    The player (src/video.asm vid_run_body) clips every fill chunk to
    NXV2_DMA_CHUNK via vid_chunk_dst, then takes vid_fill_dma when the
    chunk is 256 or >= NXV2_RUN_DMA_MIN (71) and vid_fill_cpu otherwise.
    So the full 256 B chunks are DMA and only the trailing remainder is
    re-selected - a 300 B fill is one DMA chunk plus a 44 B CPU tail,
    NOT two DMA setups. The model must predict what the player DOES.

    run_dma_min sits at the derived break-even
    (849.4/(17.17-5.11) = 70.43 -> 71), so the gate costs nothing against
    the unconstrained optimum. There is deliberately NO min(cpu, dma)
    floor: above its threshold the player is COMMITTED to the DMA kernel,
    so a min() would model a cheaper kernel than the player can select -
    optimism is the exact failure mode this model exists to avoid. If a
    future re-fit made DMA dearer above the threshold, the honest answer
    is to re-derive the threshold (and the .inc constant with it), not to
    let the model quietly price a kernel the player never runs."""
    tc = TMODEL_COEFFS
    thr = tc["run_dma_min"]
    if L < thr:
        return L * tc["fill_cpu"]
    chunk = tc["fill_dma_min"]
    full, rem = divmod(L, chunk)
    dma = full * (tc["fill_dma_setup"] + chunk * tc["fill_dma_per_b"])
    if rem:
        if rem >= thr:
            dma += tc["fill_dma_setup"] + rem * tc["fill_dma_per_b"]
        else:
            dma += rem * tc["fill_cpu"]
    return dma


def _cost_run_chunk(L):
    tc = TMODEL_COEFFS
    fill_t = _fill_t(L)
    if L <= 255:
        return 3, tc["t_op_run"] + 2 * tc["header_rate"] + fill_t
    return 4, tc["t_op_run"] + 3 * tc["header_rate"] + fill_t


def _copy_t(L, rate):
    """Modeled copy-body T for L bytes: min of the LDI body and the
    mem-to-mem DMA body, chunked at copy_dma_chunk (256B), gated on the
    PLAYER's own kernel-select rule.

    The player (src/video.asm vid_copy_body/.seg) clips every copy chunk
    to NXV2_DMA_CHUNK via vid_chunk_all, then takes vid_copy_dma when the
    chunk is 256 or >= NXV2_COPY_DMA_MIN (81) and vid_copy_ldi otherwise.
    So a body under 81 B is priced as pure LDI, and a trailing sub-81
    remainder after the full 256B chunks is priced as LDI too - the model
    must predict what the player DOES. (The player also splits on
    src/dest window room, which the model cannot see; those splits only
    add setups, so this stays the optimistic-but-close side of the real
    chunking.)

    Mirrors _fill_t's chunk-and-gate shape. copy_dma_min sits at the
    MEASURED break-even (81.4 B, NXBC C073/C074 - the kernel-only
    73.08 derivation missed the +128 T/op fast-handler -> slow-body
    path difference, carried as copy_dma_path_t and charged once per
    DMA-path op below), and there is deliberately no min(cpu, dma)
    floor - see _fill_t for why (above its threshold the player is
    committed to DMA; a floor would price a kernel the player never
    runs).

    Two disclosed edges of the measured threshold, both faithful to
    what the player DOES: (1) at exactly copy_dma_min the DMA path can
    price a few T above pure LDI (81 sits a fraction below the modeled
    81.9 break-even - the measured placement, inside the bench row
    resolution); (2) a sub-threshold REMAINDER after full 256 B chunks
    is priced as LDI even where the bare DMA kernel would be cheaper,
    because the player's single threshold constant governs the
    in-slow-body re-select too - the model follows the player, not the
    unconstrained optimum.

    Restores the settlement term the T model dropped: task-2 measured
    DMA copy at 1091.8 T/chunk + 5.31 T/B (final settlement, CD1..CD4 +
    KF rows) but the model priced EVERY copy as LDI, over-pricing a 256B
    copy 5171 T vs ~2451 T on silicon - on the dominant op class."""
    tc = TMODEL_COEFFS
    if L < tc["copy_dma_min"]:
        return L * rate
    chunk = tc["copy_dma_chunk"]
    full, rem = divmod(L, chunk)
    # OP-CLASS ENTRY COST (2026-08-03, REDERIVATION.md 6.4). An
    # 8-BIT-operand COPY reaches the DMA kernel by bailing out of the
    # fast LDI handler into the slow chunked body, and pays the
    # measured path difference copy_dma_path_t for doing so. A
    # 16-BIT-operand COPY (L >= 256) has NO fast handler to bail out
    # of - it enters the slow parser directly - so it never pays that
    # difference. What it does pay is the slow parser's own wider
    # entry, measured as the SKIP16-vs-SKIP8 envelope delta
    # (t_skip16 - t_skip = 69.1 T). Charging path_t there instead was
    # deliberate "conservative double-cover", and the K256 silicon row
    # measures exactly what that cost: modelled +2.91% against
    # silicon, +0.80% with this term. Independent support: the same
    # construction reads a RUN16 envelope of 386.3 T off F256 and a
    # COPY16 envelope of 383.6 T off K256 - two different op classes
    # landing 0.7% apart on the shared slow-parser entry.
    dma = (tc["copy_dma_path_t"] if L <= 255
           else tc["t_skip16"] - tc["t_skip"])
    dma += full * (tc["copy_dma_setup"] + chunk * tc["copy_dma_per_b"])
    if rem:
        if rem >= tc["copy_dma_min"]:
            dma += tc["copy_dma_setup"] + rem * tc["copy_dma_per_b"]
        else:
            dma += rem * rate
    return dma


def _cost_copy_chunk(L):
    tc = TMODEL_COEFFS
    rate = tc["fetch_long"] if L >= 64 else tc["fetch_short"]
    body = _copy_t(L, rate)
    if L <= 255:
        return 2 + L, tc["t_op_copy"] + 1 * tc["header_rate"] + body
    return 3 + L, tc["t_op_copy"] + 2 * tc["header_rate"] + body


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
                           #     keyframe - the hard staleness bound.
                           #     RETIRED AS A TRIGGER (SP17 W4, 2026-08-01):
                           #     measured on the owner's own pan clip the
                           #     PER-PIXEL decoded deficit runs NEGATIVE
                           #     (-1.21 dB mean - the dither displacement
                           #     penalty puts achieved per-pixel PSNR at or
                           #     above po_ceil), so a +3.0 dB bar was
                           #     structurally uncrossable on whole-frame
                           #     slow drift. The staleness guard now
                           #     compares in 4x4 LOCAL-MEAN space (see
                           #     STALE_LM_DB below); this constant is kept
                           #     for the per-frame diagnostics only.

# ---------------------------------------------------------------------
# LOCAL-MEAN (4x4) TRIGGER RE-BASE (SP17 W4, 2026-08-01). The palette-
# lifecycle wave measured why the whole-frame staleness guard and the
# drift trigger could not fire on slow whole-frame decay: both compared
# PER-PIXEL PSNR against po_ceil, and per-pixel PSNR is dominated by
# the deliberate dither displacement, which tracks the ceiling by
# construction (001 pan: decoded deficit MEAN -1.21 dB against a +3.0
# bar). The 4x4 local-mean metric cancels the dither grain and exposes
# the accumulated structural error the triggers exist to bound - it is
# also the metric every SP17 quality claim reads (palette-wave rule:
# LOCAL-MEAN, never per-pixel).
#
# Thresholds DERIVED FROM THE CORPUS (W4 trigger-rebase measurement,
# 2026-08-02: 12-clip C0 subset + the owner's two pan clips at their
# shipped full-shape operating points, triggers silenced, per-frame
# lm-deficit / lm-drift traces; full table in the W4 report):
#
#   lm DEFICIT (decoded screen vs the frame's own lm ceiling):
#     clean/static      church 0.64 max, owner-002 0.69, bunny 2.13
#     at-capacity       boat 5.88, owner-001 pan 5.61, dracula 7.24,
#     equilibria        12 Monkeys 12.55, Miami Vice talk 13.75,
#     (eyes accept)     jellyfish 14.91 - plateaus that OSCILLATE or
#                       hold; the aging/phase machinery plus the 5 s
#                       cadence refresh bound them
#     broken screens    Caprica bomb p50 12.3 max 24.5, car chase
#     (C0 problem list) p50 16.6 max 23.5, sintel p50 16.8 max 27.6,
#                       police car p90 22.7 max 26.3, From diner
#                       p99 19.0 (the one straddler - it fired the old
#                       px staleness twice as well)
#
# STALE_LM_DB = 15.0 sits ABOVE every visually-accepted plateau
# measured (worst: jellyfish 14.91) and INSIDE every problem clip's
# operating band - the triggers fire where the screen is genuinely
# broken and cannot thrash the accepted equilibria. Slow decay below
# the bar belongs to the cadence path (KF_CADENCE_S_DEFAULT - since W5
# a rolling refresh, see the ROLLING REFRESH block), which the palette
# wave measured FREE at 5 s.
#
#   lm DRIFT (held-palette fit loss on a fresh quantize):
#     palette-stable content maxes 0.00-0.15 dB (10x under the bar);
#     missed-transition spikes read 1.50 (police car), 1.89 (car
#     chase), 3.09 (sintel).
# DRIFT_LM_T = 1.5 / 3.0 (refractory) keeps the old pair's shape in
# the space where it can actually be crossed: silent on every stable
# clip, fires exactly on the non-impulse palette breaks the cut
# trigger misses.
# ---------------------------------------------------------------------
STALE_LM_DB = 15.0         # whole-frame staleness bar, 4x4 local-mean dB
DRIFT_LM_T, DRIFT_LM_T_REFRACT = 1.5, 3.0   # held-palette lm drift bar

# ---------------------------------------------------------------------
# KEYFRAME CADENCE (SP17 W4 item 2, 2026-08-01). Measured (palette-
# lifecycle wave, owner clips): a forced keyframe every 5 s on the 001
# pan is FREE in bytes (-0.1%) and buys +0.39 dB 4x4 local-mean; a 2 s
# cadence on 002 costs +9.3% bytes for +0.65 dB overall / +1.02 dB
# last-tenth - real but not free. The default is the measured free
# point; 0 disables. The cadence engages only when no NATURAL keyframe
# (cut / dissolve / staleness / drift) has occurred within the window,
# and never when the remaining clip cannot hold a nominal refresh
# window (a prophylactic refresh must not buy tail-of-clip
# degradation).
#
# ROLLING REFRESH (SP17 W5, owner-ruled 2026-08-02). The W4 cadence
# emitted a full KEYFRAME SPAN, and owner silicon read it as "a paused
# frame in the middle" of every ~10 s clip (048/049 boat, 050/051
# church, 040/041 car chase) - bench rows EXACT rate, ZERO ring
# underruns, so the pause is not a transport fault: a span's paced
# repaint targets the HIDDEN surface, so the visible picture HOLDS for
# the whole span (2-8 frame periods) until KFLIP. T2's peak pacing
# removed the hitch; the hold was the residual visible cost.
#
# The cadence path therefore no longer emits a keyframe at all. It
# schedules forced-clean coverage of the whole surface across N
# consecutive ORDINARY delta frames (wire format untouched - the
# refresh is plain RUN/COPY/SKIP traffic): each roll frame force-cleans
# the next paint-order slice of pending positions to the FRESH
# non-hysteresis quantize under the HELD palette (the drift probe's own
# decode, so it costs no extra quantize) - which removes exactly what
# the cadence keyframe removed short of a palette change: accumulated
# paint drift and hysteresis index stickiness. Palette renewal remains
# the business of the REAL triggers - cut/dissolve/staleness/drift
# still emit true keyframe spans, because a genuinely broken screen
# needs the atomic repaint.
#
# BUDGET HONESTY: the forced slice is substituted into the frame's
# target and boosted to PHASE_FLOOR importance, then priced by the
# SAME per-frame byte/decode-T caps and band scheduler as all other
# delta traffic - no side budget, and the supply gate sees the real
# emitted bytes. Positions the caps could not afford CARRY OVER to the
# next frame, so contention lengthens the window (degrades the refresh
# PERIOD); it never degrades the rate and never holds a frame.
#
# KF_ROLL_SHARE sizes the per-frame quota CEILING: the slice's
# worst-case literal bytes may claim at most this fraction of the
# frame's own delta byte cap, so the nominal N = ceil(raw /
# (KF_ROLL_SHARE * cap_bytes)) and a lower budget stretches the window
# by construction. 0.5 is a stated margin, not a fitted value: at least
# half of every roll frame's byte cap is always left to the normal
# motion updates, and at the owner pair's operating points (048 boat
# budget 0.42, 050 church 0.57, 320x256) it lands N at 8 and 6 frames -
# the same order as the span the roll replaces (4 chunk frames), spread
# thin instead of held.
#
# TWO GUARDS (corpus sweep .superpowers/sdd/sp17-corpus/ROLL-SWEEP.md,
# verdict GO WITH CAVEAT; 90 matched pairs, 43/46 scored windows
# improve, 150 held frames removed, but 33/46 still lose motion
# coverage at the cadence position by up to -21%):
#
# (a) STRICTLY OPPORTUNISTIC. The roll may consume only byte budget the
#     MOTION schedule did not want. Each armed frame is first scheduled
#     WITHOUT the roll; the frame's quota is then min(KF_ROLL_SHARE
#     ceiling, cap_bytes - motion bytes). A saturated frame leaves
#     nothing, so it emits the motion-only schedule byte for byte and
#     the pending positions carry over until slack appears. The sweep
#     is unambiguous about why: all three corpus rows the roll made
#     WORSE sit at byte-utilisation p95 0.998-0.999 (bunny sound
#     classic, Pam Am Airport classic, jellyfish sound 16:9) - there the
#     roll can only DISPLACE motion - while every large winner refreshes
#     out of genuine slack (church byte-util p95 0.339-0.501, From car 2
#     classic mean 0.472, 12 Monkeys classic mean 0.438), where the
#     KF_ROLL_SHARE ceiling still binds and the behaviour is unchanged.
#     Whole-clip quality cost of spending nothing on the saturated rows
#     is within +-0.05 dB everywhere.
#
# (b) DISCHARGE ON "WAS UPDATED", NOT EXACT EQUALITY. The first
#     implementation retired a forced position only when the surface
#     later held the exact value it had been assigned. A position that
#     WAS repainted, but to a different value because the content moved
#     on between scheduling and emission, stayed pending forever - and
#     `roll_pending is None` gates re-arming, so one stranded position
#     disabled every future refresh for the rest of the clip. The sweep
#     found it on 6 of 47 rows (fixture 009 stranded 12 positions for
#     124 frames against a nominal N of 7). A slice is now discharged
#     in the SAME frame, on the frame's own paint mask (plus positions
#     that already held their fresh target when the slice was cut).
#
# NOT DONE, on the sweep's explicit guidance: the cadence mechanism is
# not dropped (corpus clips are 6-19 s - too short to show what a
# refresh prevents over a long title), the keyframe is not restored (it
# is worse on 43 of 46 windows), and KF_ROLL_SHARE is not tuned (it sets
# how thinly the tax is spread, not whether it is levied).
# ---------------------------------------------------------------------
KF_CADENCE_S_DEFAULT = 5.0
KF_ROLL_SHARE = 0.5

# ---------------------------------------------------------------------
# KEYFRAME-SPAN PEAK PACING (SP17 W4 item T2, charter E5). Keyframe
# chunks were sized by decode-T alone, so the byte peak was identical
# (47,616 B) at every budget rung: 35.8-43.3 ms of SD wire ALONE
# against a 40 ms frame period - every keyframe event a guaranteed
# hitch, and blocks_max == hdr_cap_blocks on every fixture. The fix
# bounds the PER-FRAME SUPPLY TIME of every span chunk frame (decode
# busy + audio copy + SD wire for audio pad and 512-padded payload, the
# supply gate's own prices) to this fraction of the frame period, which
# splits oversized spans across more frames instead of hitching. 0.95
# is the stated margin: 5% under the 1.00 infeasibility line, on wire
# terms that are themselves conservative (Card #8 measured the
# 1264 KB/s x af floor 5.5% under what the producer delivered).
# Chosen over the charter's other two options because (a) scaling spans
# with the budget multiplies span length on low-budget encodes that
# never had a wire problem, and (b) a bare block-count cap ignores the
# decode side of the same frame; bounding the modeled supply time
# bounds both with one stated number.
# ---------------------------------------------------------------------
KF_SPAN_PEAK_UTIL = 0.95
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

# ADAPTIVE TILE LADDER (SP17, owner-approved on a hardware A/B 2026-07-30).
# TILE_BAND alone is too coarse for concentrated motion: at 1024 B a bound
# frame buys whole 4-row/4-column bands, so a small fast-moving region drags
# in its whole band and the byte budget buys far less picture than it could.
# A FIXED fine tile is NOT the fix - it fragments the op stream, decode-T
# saturates before the byte budget does, and the encode strands wire it was
# allowed to spend (measured: fixed t64/t32 strand 18%/38% of fixture 008's
# byte budget, and 008 is the silicon-validated control).
#
# The rule that IS the fix is SPEND-PRESERVING. Per budget-bound frame, walk
# the ladder fine -> coarse and keep the FINEST rung that still spends at
# least TILE_SPEND_FRAC of the best (in practice the coarsest = today's)
# rung's bytes. (READ THE LADDER RE-CUT BLOCK BELOW BEFORE ACTING ON THIS
# ONE: spend preservation is necessary and was never sufficient - the rungs
# and the rest of the admissibility test were both re-cut on 2026-07-30.) Finer granularity is taken only when it is FREE in wire
# terms, so the decode-T inversion cannot bite: a rung that saturates
# decode-T while leaving bytes unspent fails the spend test and is rejected.
#
# THRESHOLD PROVENANCE - the band is narrow, do not re-tune by eye.
# Re-verified under the shipped OFFSET dither default:
#   1.00  WRONG - an exact-tie requirement kicks the ladder off the finest
#         rung on 56 of 132 bound frames on a starved Sintel leg
#         (-0.53 dB per-pixel, -0.87 dB 4x4).
#   0.99  SHIPPED - ties or beats 0.98 on all three legs and restores
#         decode-T headroom.
#   0.98  acceptable, no leg prefers it.
#   0.90  OUT OF BAND under offset - strands 3% of fixture 008's wire
#         (benign under the opt-in mixture dither, not under the default).
TILE_SPEND_FRAC = 0.99

# ---------------------------------------------------------------------
# LADDER RE-CUT (2026-07-30, owner silicon caught the first cut)
# ---------------------------------------------------------------------
# The ladder above shipped as the literal (32, 64, 128, 256, 1024) with
# spend-preservation as its only admissibility test. Owner silicon on the
# very next sitting called fixture 007 (classic 256x192, MODE-0) "lots of
# displacement and tearing" with a completely clean transport - worse than
# the encoder it replaced - while the owner's own mode-1 clips improved.
# Two faults, one root cause, both measured (scratchpad ladder-regression):
#
# 1. SUB-LINE RUNGS FRAGMENT THE PICTURE. A rung finer than one paint-order
#    LINE cuts a scanline (mode-0) or a column (mode-1) into pieces that are
#    scheduled independently, so one row can carry up to eight differently-
#    AGED fragments side by side. That is not the "coherent regional lag"
#    this scheduler exists to produce - it reads as displacement/tearing on
#    moving edges. 007 took rung 32 (an EIGHTH of a row) on 184 of 184 bound
#    frames; the owner-approved A/B ran on 320x256 mode-1 where the rule
#    settled on 256 = exactly one column on 222 of 247 frames, so the
#    sub-line region was approved by extrapolation and never eyeballed.
#    Op-stream profile of the shipped 007: mean write patch 96.4 px -> 59.9,
#    write ops/frame 195 -> 234, on 25% FEWER pixels painted per frame.
#
# 2. SUB-LINE RUNGS ALSO COST THE BYTE SUPPLY. Fragmenting runs multiplies
#    per-op dispatch, so decode-T explodes: on 007 at a pinned 0.64 the
#    shipped rule spent 1.37x the coarse rung's decode T to buy 1.7% more
#    bytes. The supply gate charges that time (busy_ms), so measured
#    utilization went 0.892 -> 0.985 at the SAME budget and the auto-budget
#    search - which production always runs and the A/B deliberately pinned
#    away - backed 007 off 0.64 to 0.47: 19% of the wire GONE, budget-bound
#    frames 72.8% -> 93.6%. Spend preservation guards BYTES and is silent
#    on T, and T is what sets the derived budget. That was the hole.
#
# THE RE-CUT, therefore, is two rules, not one:
#
#   (a) THE LADDER WALKS WHOLE LINES. Rungs are TILE_LADDER_QUARTERS
#       quarter-bands - and a quarter band IS one paint-order line on every
#       shape (default_tile_px = TILE_BAND lines), so the finest rung is one
#       whole row (mode-0) / column (mode-1) and no rung can ever split one.
#       This is a granularity floor in DISPLAY terms, which is the term the
#       artifact is in; it also keeps exactly the rung the hardware A/B
#       actually exercised and approved.
#   (b) THE RUNG MUST BE FREE, AND MUST PAY. A finer rung is admissible only
#       if it spends AT LEAST the coarsest rung's bytes, costs NO MORE than
#       the coarsest rung's modelled SUPPLY - the supply gate's OWN busy +
#       wire arithmetic, see supply_price() - and leaves NO MORE residual
#       err2 on the surface. Finer tiling is then taken only where it is
#       free in the currency that sets the budget AND actually improves the
#       picture, so the derived budget cannot move, the byte supply cannot
#       be traded away behind the author's back, and a rung cannot win on
#       granularity alone.
#
# TILE_SUPPLY_SLACK is the tolerance on (b) and its DEFAULT is 0.0.
# Measured margin below the auto-budget target at the pal9i operating
# points: 007 0.008, 009 0.005, 008 0.001. Fixture 008 - the silicon
# control that underran once already - has one thousandth of utilization
# in hand, so any positive slack is a coin flip on whether its budget
# survives, and a budget step costs ~0.0105 of utilization to buy back.
# By default, therefore, "free" means free. The SUPPLY-SLACK KNOB block
# below is how an author opts a single title out of that default; rule
# (a), the whole-line floor, is NOT reachable from the knob or from
# anywhere else.
TILE_LADDER_QUARTERS = (1, 2, 4)
TILE_SUPPLY_SLACK = 0.0


# ---------------------------------------------------------------------
# THE SUPPLY-SLACK KNOB (--tile-slack) - OPT-IN, DEFAULT OFF
# ---------------------------------------------------------------------
# WHY IT EXISTS. With rule (b) at TILE_SUPPLY_SLACK = 0.0 the ladder
# buys almost nothing: it engages on 21 of 007's 183 bound frames, 8 of
# 247 on 008, 12 of 249 on 009, and is a near no-op on the owner's own
# footage. But the behaviour the owner SAW AND APPROVED on hardware was
# the pal9j ladder on his own 320-wide clips, where it settled on the
# ONE-COLUMN rung (256 B) on 222 of 247 frames. That gain was real, and
# it was bought with SUPPLY - roughly one auto-budget step (util 0.880
# -> 0.891 at a pinned budget on the boat pan). Owner ruling
# (2026-07-30): ship the gain behind an opt-in knob, because the right
# value is CONTENT-DEPENDENT - one-column granularity helped his 320-wide
# pans and going finer wrecked the 256-wide fixture - which makes it a
# per-clip setting, not a global default.
#
# WHAT IT RELAXES, AND WHAT IT CANNOT REACH. The knob moves rule (b)
# ONLY. Rule (a), the whole-line floor, is not a tunable: sub-line rungs
# are what owner silicon read as displacement and tearing, and they are
# also what widened the write span from 58% to 70% of the surface on a
# LIVE patched surface against a free-running frame clock. The ladder is
# built by tile_ladder_for() from TILE_LADDER_QUARTERS alone - the knob
# is not an input to it - and encode_delta re-asserts the floor on the
# rungs it is handed, at every knob value. See t19 in the selftest.
#
# PARAMETERISATION: FRACTIONS OF THE AUTO-BUDGET UTILISATION HEADROOM.
# The raw quantity rule (b) compares is a per-frame RELATIVE supply
# allowance (ceil_ms = coarse_ms * (1 + s)), and a raw s is meaningless
# to an author - it is a number in a unit nothing else in this encoder
# is quoted in. What an author can reason about is the margin the
# encoder is holding back on his behalf: the auto-budget search targets
# AUTO_BUDGET_TARGET_UTIL (0.90) and the gate refuses above
# STREAM_CEILING_UTIL (1.00), so there is exactly one pot of utilisation
# the ladder could spend, and the knob is quoted as a FRACTION OF THAT
# POT. --tile-slack 0.15 means "let the ladder spend up to 15% of the
# margin between the target and the refusal line". 0.0 spends none of
# it (today's behaviour, and the default); 1.0 spends all of it and the
# knob cannot express more.
#
# THE CAP, AND WHERE IT COMES FROM. frame_supply_ms() IS the supply
# gate's own per-frame busy + wire arithmetic, so the sum of it over the
# clip is precisely the utilisation numerator the gate divides (less the
# invariant audio pad, which no rung moves). A per-frame relative
# allowance s therefore raises the clip's mean utilisation by AT MOST
# s x u, where u is the utilisation the ladder's frames contribute -
# bounded above by the clip's whole u. At the operating point the search
# aims at, u = AUTO_BUDGET_TARGET_UTIL, so the worst case a knob value k
# can land on is
#
#     u_max = AUTO_BUDGET_TARGET_UTIL x (1 + k x HEADROOM)
#
# and setting u_max = STREAM_CEILING_UTIL gives
#
#     HEADROOM = (STREAM_CEILING_UTIL - target) / target = 0.1111...
#
# i.e. k = TILE_SLACK_MAX = 1.0 spends the entire margin the target
# holds back and NOT ONE PART MORE. That is the cap, and it is the
# reason the knob is expressed in headroom units rather than in raw
# relative supply: the cap is then 1.0 by construction and stays correct
# if the target is ever re-derived (or overridden per encode with
# --budget-target, which tile_slack_rel honours).
#
# The bound is loose in three independent directions - only BOUND frames
# reach the ladder at all, only frames where a finer rung both wins and
# actually costs more pay any of it, and with the default automatic
# search the budget is re-derived so the realised utilisation comes back
# to the target anyway (the knob's cost then shows up as BYTES, which is
# what the report line makes visible). What the cap has to survive is
# the OTHER case: an explicit --stream-budget, where nothing re-derives
# and the utilisation simply rises. There the existing supply gate is
# the backstop and it is unchanged - over 1.00 it REFUSES, it does not
# emit a file that will not play. The knob can make an encode be
# refused; it cannot make an unplayable file be written.
STREAM_CEILING_UTIL = 1.0        # the gate's own refusal line
TILE_SLACK_DEFAULT = 0.0         # OFF - today's supply-neutral ladder
TILE_SLACK_MAX = 1.0             # the whole auto-budget margin, no more


def tile_slack_headroom(target_util=None):
    """The utilisation margin one unit of --tile-slack buys, as a
    RELATIVE supply allowance: (ceiling - target) / target.

    target_util defaults to AUTO_BUDGET_TARGET_UTIL - the point the
    automatic search aims at and the point stream_supply_check's own
    suggested_budget solves for. An explicit --budget-target moves it,
    and the knob's meaning moves with it: raise the target and there is
    less margin in the pot, so one unit of slack is worth less."""
    tgt = AUTO_BUDGET_TARGET_UTIL if target_util is None else float(target_util)
    if not (0.0 < tgt <= STREAM_CEILING_UTIL):
        raise ValueError(f"budget target must be in (0, {STREAM_CEILING_UTIL}], "
                          f"got {tgt}")
    return (STREAM_CEILING_UTIL - tgt) / tgt


def tile_slack_rel(knob, target_util=None):
    """Resolve a --tile-slack knob value (in HEADROOM units, see the
    block above) to the per-frame RELATIVE supply allowance rule (b)
    charges - the number encode_delta actually compares against.

    knob None means TILE_SLACK_DEFAULT, which is 0.0, which resolves to
    0.0 exactly: the default path is bit-for-bit the supply-neutral
    ladder and no arithmetic happens on it at all. Out-of-range values
    RAISE rather than clamp - a mis-set knob is an author error worth a
    message, and silently clamping 5.0 to 1.0 would hide the fact that
    the request was nonsense."""
    k = TILE_SLACK_DEFAULT if knob is None else float(knob)
    if not (0.0 <= k <= TILE_SLACK_MAX):
        raise ValueError(
            f"tile slack must be in [0.0, {TILE_SLACK_MAX}], got {k} - the "
            f"knob is quoted in fractions of the auto-budget utilisation "
            f"headroom, and {TILE_SLACK_MAX} already spends ALL of the "
            f"margin between the {AUTO_BUDGET_TARGET_UTIL:.2f} target and "
            f"the {STREAM_CEILING_UTIL:.2f} refusal line")
    if k == 0.0:
        return 0.0
    return k * tile_slack_headroom(target_util)

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

# THE SUPPLY EXCHANGE RATE - what one WIRE byte is worth in decode
# T-states at the clip-level supply gate. Measured in
# sp17-corpus/DECODE-COST.md section 3c from the shipped gate's own
# arithmetic:
#
#     1 wire byte = 1/(SD_WIRE x af) ms = 9.089e-4 ms
#     1 decode T  = R/af/clock ms       = 4.48e-5 ms   (church-050)
#     ---------------------------------------------------------------
#     1 wire byte = 19.9 decode T-states   (19.6-20.2 on flat shapes,
#                                           15.3-16.5 on gapped ones)
#
# This is an OPPORTUNITY COST, not an execution cost: it is what the
# encoder gives up in decode budget when it spends a byte on the wire,
# and both sides of that trade are priced against the same frame period
# by stream_supply_check. It is deliberately NOT keyed to any kernel -
# see merge_kstar for the error that made.
SUPPLY_EXCHANGE_T_PER_BYTE = 19.9


def merge_kstar(lam=None):
    """Interior-skip bridge crossover K* (bytes). Bridging a SKIP that
    sits between two data ops merges SKIP+COPY into a single COPY: it
    saves the skip dispatch AND one copy dispatch, and costs K EXTRA
    WIRE BYTES.

        K* = (t_skip + header_rate + t_op_copy) / lam

    DENOMINATOR RE-DERIVED 2026-08-03 (REDERIVATION.md section 7). The
    numerator was never in question - bridging removes one SKIP
    dispatch and one COPY dispatch, 477.9 T of decode, exactly. The
    denominator was: it used to be fetch_long (20.2 T/B), which is what
    it costs the PLAYER to EXECUTE a bridged byte. But the question the
    encoder is asking is "should I spend a wire byte to buy decode
    time?", so the price of a bridged byte is its OPPORTUNITY COST -
    the supply exchange rate lam above.

    The two are unrelated quantities that happened to agree to 1.5%, so
    the shipped 23.66 was right for the wrong reason; the value moves
    to 24.02 and the COUPLING to fetch_long - under which an
    improvement to the LDI kernel would silently move a MERGE threshold
    that has nothing to do with LDI - is gone. (DECODE-COST.md once
    proposed 9.345 T/B, the DMA marginal rate, giving 51.1 B: that is
    the SAME category error on the other kernel, it would more than
    double the threshold, and it is struck in that file.)

    lam=None means SUPPLY_EXCHANGE_T_PER_BYTE, the flat-shape default.
    Passing a shape-specific lam makes the threshold shape-aware for
    free: gapped (letterbox) shapes exchange at 15.3-16.5 T/B, which
    raises K* to 29-31 B there - and DECODE-COST.md measures the gapped
    clips as the ones with the most merge headroom.

    History of the value: 91 B at the old model's D=920/skip920; ~63 B
    at sitting-1 silicon; ~26 B at sitting-2's D=387/skip130 - the
    optimized kernels make fewer gaps worth bridging because a dispatch
    is no longer expensive."""
    tc = TMODEL_COEFFS
    if lam is None:
        lam = SUPPLY_EXCHANGE_T_PER_BYTE
    skip_disp = tc["t_skip"] + tc["header_rate"]      # SKIP8 op envelope
    copy_disp = tc["t_op_copy"]
    return (skip_disp + copy_disp) / lam


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
    into a neighbouring copy region.

    VALUE HELD, DERIVATION DISCLOSED (2026-08-03, REDERIVATION.md 6.6).
    139.2 B is NOT re-derived here, on purpose - RUN is 0.00-0.08% of
    corpus decode-T, so moving it churns encoder output on a class that
    cannot pay for the regression it would need. But three faults in the
    derivation are recorded so nobody trusts it further than it goes:

    1. WRONG COPY RATE. A region of <= 139 B runs fetch_short, not
       fetch_long: 487.2/(19.797-16.703) = 157.5 B, 13% higher.
    2. WRONG REGIME FOR THE CASE THAT MATTERS. If the absorbing COPY is
       already on the DMA path its marginal rate is 5.082 T/B, BELOW
       fill_cpu 16.703 - the denominator goes negative and absorption
       always wins, at any length. One global answer cannot express
       that, so this function declines absorptions that would win.
    3. NUMERICALLY FRAGILE BY CONSTRUCTION. The denominator is a
       difference of two nearly equal remeasured coefficients (3.5 out
       of 20), so a 3% move in either moves the threshold 17%. Its
       history for one unchanged physical fact: 152.2 -> 125.6 ->
       139.3 -> 157.5 at sitting-3 rates. A proper fix is regime-aware
       (it has to know which kernel the absorbing copy will run), not a
       coefficient swap."""
    tc = TMODEL_COEFFS
    denom = tc["fetch_long"] - tc["fill_cpu"]
    if denom <= 0:
        return float("inf")
    return tc["t_op_run"] / denom


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


def tile_ladder_for(coarsest):
    """The adaptive tile ladder to walk for a clip whose COARSEST rung is
    `coarsest` bytes (i.e. default_tile_px for that shape - today's fixed
    scheduler, which the ladder must never spend less wire than).

    The rungs are TILE_LADDER_QUARTERS QUARTER-BANDS, fine -> coarse, and a
    quarter band is exactly one paint-order LINE on every shape, because
    default_tile_px is TILE_BAND (= 4) lines: 001-full 320x256 and
    002-classic 256x192 both give a band of 1024 and a ladder of
    (256, 512, 1024) - one, two and four lines; 003-16:9 320x192 gives
    (192, 384, 768) and 004-scope 320x144 gives (144, 288, 576). So the
    finest rung is one whole row (mode-0) / column (mode-1) on every shape,
    the coarsest is always today's fixed scheduler, and NO rung can ever
    split a line (see the LADDER RE-CUT block: sub-line rungs are what the
    owner's silicon read as displacement and tearing, and what took 37% more
    decode T out of the byte supply)."""
    coarsest = int(coarsest)
    line = max(1, coarsest // TILE_BAND)
    lad = tuple(sorted({min(q * line, coarsest)
                        for q in TILE_LADDER_QUARTERS} | {coarsest}))
    # The whole-line floor is a property of THIS function and of nothing
    # else - no argument, and in particular no --tile-slack value, is an
    # input to it. Asserted rather than merely arranged, so a future edit
    # to TILE_LADDER_QUARTERS cannot re-introduce a sub-line rung quietly.
    assert all(g >= line and g % line == 0 for g in lad), \
        f"tile ladder {lad} splits a paint-order line ({line} B)"
    return lad


def supply_price(width, height):
    """(ms per modelled decode T, ms per SD byte) for this surface - the
    SAME two prices stream_supply_check charges, factored out so the tile
    ladder's admissibility test and the supply gate cannot drift apart.

    A ladder rung that raises a frame's supply cost raises the clip's
    measured utilization, and the auto-budget search pays for that with
    BUDGET - i.e. with wire bytes. Charging the rung the gate's own prices
    is what makes "the ladder must not cost byte supply" an invariant of
    the rule rather than an observation about one fixture."""
    af = TMODEL_COEFFS["audio_factor"]
    # density unknown at ladder-planning time -> silicon_r fails safe to
    # the sparse-end (largest) R: a finer rung must justify itself at
    # the dearest measured decode price (W4 density re-key)
    return (silicon_r(width, height) / af / TMODEL_COEFFS["clock_khz"],
            1.0 / (SD_WIRE_BYTES_PER_MS * af))


def frame_supply_ms(nbytes, t, price):
    """A frame's modelled supply cost in ms at `price` (supply_price()):
    decode busy time plus the SD time for its 512-padded payload. The
    invariant audio pad is the same on every rung and is left out - only
    DIFFERENCES between rungs are ever compared."""
    return t * price[0] + (((int(nbytes) + 511) // 512) * 512) * price[1]


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
                 surface_flat=None, merge_gaps=True, tile_px=None,
                 tile_ladder=None, supply_px=None, supply_slack=None):
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

    ADAPTIVE TILE LADDER (tile_ladder given, as encode_clip always supplies -
    see tile_ladder_for() and the LADDER RE-CUT block): the tile GRANULARITY
    is chosen per bound frame instead of being fixed. Every rung is scheduled
    in full and the FINEST ADMISSIBLE rung wins; mode gains an '@<rung>'
    suffix naming the granularity that was used. A rung is admissible when it
    passes BOTH preservation tests:

      WIRE   its bytes are >= the COARSEST rung's (never less wire than the
             fixed band scheduler it refines) AND >= TILE_SPEND_FRAC of the
             best rung's, so a finer rung can never strand budget the frame
             was allowed to spend (the decode-T inversion).
      SUPPLY its modelled supply cost - the gate's own busy + wire prices,
             frame_supply_ms() at `supply_px` - is within `supply_slack`
             (default TILE_SUPPLY_SLACK = 0.0) of the COARSEST rung's, so by
             default a finer rung can never cost the clip utilization, which
             is what the auto-budget search pays for in BYTES. Requires
             supply_px; passing tile_ladder without it is a programming error
             and raises, because a silently-unpriced ladder is exactly the
             defect owner silicon caught on 2026-07-30. supply_slack is the
             OPT-IN --tile-slack knob, already resolved from headroom units
             to a relative allowance by tile_slack_rel(); it relaxes THIS
             test and nothing else - see THE SUPPLY-SLACK KNOB block.

      PICTURE the err2 it LEAVES on the surface is no higher than the
             coarsest rung's. Wire and supply preservation say a rung costs
             nothing; neither says it BUYS anything, and a rung that spends
             the same wire on a worse-chosen set of tiles is a pure loss that
             then propagates through the surface into later frames.

    The three together are the owner's own acceptance test made a per-frame
    invariant: NEVER FEWER BYTES, NEVER MORE SUPPLY, NEVER A WORSE PICTURE
    THAN TODAY. Nothing in the rule needs tuning to hold it.

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
    if tile_ladder:
        # ---- adaptive tile ladder (SP17, re-cut 2026-07-30) ----
        # Schedule the frame at every rung, then keep the finest rung that
        # preserves the wire spend, the supply cost AND the picture (see the
        # docstring and the LADDER RE-CUT block). Cost: one full schedule per
        # rung on BOUND frames only (the fast path above already returned for
        # everything else).
        if supply_px is None:
            raise ValueError(
                "encode_delta: tile_ladder needs supply_px - an unpriced "
                "ladder can trade decode-T for granularity and the "
                "auto-budget search silently pays for it in wire bytes "
                "(the pal9j regression); pass supply_price(width, height)")
        # RULE (a), RE-ASSERTED HERE, AND DELIBERATELY NOT A FUNCTION OF
        # supply_slack. The coarsest rung is the shape's TILE_BAND band, so
        # one paint-order line is band // TILE_BAND and every rung must be a
        # whole number of them. This is checked on the rungs encode_delta is
        # actually handed rather than trusted from tile_ladder_for(), because
        # the whole-line floor is the invariant the OPT-IN knob below must
        # never be able to reach past: sub-line rungs are what owner silicon
        # read as displacement and tearing, and no setting of any knob may
        # produce one.
        line_px = max(1, int(tile_ladder[-1]) // TILE_BAND)
        if any(int(g) < line_px or int(g) % line_px for g in tile_ladder):
            raise ValueError(
                f"encode_delta: every ladder rung must be a WHOLE number of "
                f"paint-order lines ({line_px} B each on this shape), got "
                f"{tuple(tile_ladder)} - a sub-line rung splits a row/column "
                f"into independently-aged fragments (displacement and tearing "
                f"on owner silicon, 2026-07-30) and no --tile-slack value may "
                f"produce one")
        slack = TILE_SUPPLY_SLACK if supply_slack is None else float(supply_slack)
        cands = [(rung, encode_delta(target_flat, err2_flat, cap_bytes, cap_t,
                                     surface_flat=surface_flat,
                                     merge_gaps=merge_gaps, tile_px=rung))
                 for rung in tile_ladder]
        best_b = max(r[3] for _, r in cands)
        coarse_b = cands[-1][1][3]
        coarse_ms = frame_supply_ms(coarse_b, cands[-1][1][4], supply_px)
        ceil_ms = coarse_ms * (1.0 + slack)
        # NEVER FEWER BYTES THAN TODAY - the coarsest rung IS today's fixed
        # band scheduler - and never strand wire against the best rung either.
        floor_b = max(coarse_b, TILE_SPEND_FRAC * best_b)

        def _residual(r):
            """err2 this candidate LEAVES on the surface."""
            m = _mask_from_segments(r[0], r[1], r[2], n)
            return float(err2_flat[~m].sum())

        # ... AND NEVER A WORSE PICTURE. Wire and supply preservation say the
        # rung costs nothing; they do not say it BUYS anything, and a rung
        # that spends the same wire on a worse-chosen set of tiles is a pure
        # loss whose damage then propagates (the next frame inherits the
        # surface). Requiring the residual to fall too makes every rung the
        # ladder takes a strict Pareto improvement on today's schedule -
        # more picture, no more supply, no less wire.
        coarse_res = _residual(cands[-1][1])
        for rung, r in cands:            # tile_ladder is fine -> coarse
            if r[3] >= floor_b and \
                    frame_supply_ms(r[3], r[4], supply_px) <= ceil_ms and \
                    _residual(r) <= coarse_res:
                gc, gs, gl, b, t, mode, binding, payload = r
                return (gc, gs, gl, b, t, f"{mode}@{rung}", binding, payload)
        # Unreachable in practice - the coarsest rung passes all three tests
        # by construction (it IS the wire, supply and picture reference) -
        # but the ladder must never fall out
        # without an answer, and the answer is the fixed band scheduler it
        # is allowed to refine and never to undercut.
        rung, r = cands[-1]
        gc, gs, gl, b, t, mode, binding, payload = r
        return (gc, gs, gl, b, t, f"{mode}@{rung}", binding, payload)
    ntiles = (n + tile_px - 1) // tile_px
    # Band importance is sqrt(err2) - the pal9i weight, RESTORED 2026-07-30.
    # The pal9j wave switched it to raw err2 on the argument that sqrt
    # flattens the ranking towards area. Isolated afterwards (the ladder
    # collapsed to its band rung so ONLY the weight varied, three streamed
    # fixtures pinned at their pal9i budgets), raw err2 measured:
    #   007  resid 18.59 -> 17.75%, +0.16 dB px, +0.19 dB 4x4, util 0.892 ->
    #        0.894 - a real gain.
    #   009  resid 30.96 -> 28.28%, +0.28 dB px, +0.70 dB 4x4, but line CV
    #        1.345 -> 1.418 and util 0.895 -> 0.906.
    #   008  resid 52.87 -> 52.80% (nothing), line CV 0.853 -> 0.867, and
    #        util 0.899 -> 0.902 - which is OVER the auto-budget target, so
    #        008's derived budget falls 0.44 -> 0.43 and it loses 2.3% of its
    #        wire for no quality at all.
    # 008 is the silicon-validated control and it sits one THOUSANDTH of
    # utilization under the target, so a weight that reorders bands into more
    # decode-T is a budget cut on that fixture however well it reads
    # elsewhere - the same currency error as the ladder's, in a different
    # place. Re-propose it only with evidence that it does not raise
    # utilization.
    w_e = np.where(mask_full, np.sqrt(err2_flat), 0.0)
    pad = ntiles * tile_px - n
    band_imp = (np.concatenate([w_e, np.zeros(pad, dtype=w_e.dtype)])
                if pad else w_e).reshape(ntiles, tile_px).sum(axis=1)
    order = [int(ti) for ti in np.argsort(-band_imp) if band_imp[ti] > 0.0]

    # Rank per pixel, so _prefix_fit's selection mask is one vectorised
    # compare instead of a Python loop over the kept bands (the ladder runs
    # the binary search once per rung, so this inner cost now multiplies).
    _rank = np.full(ntiles, len(order), dtype=np.int32)
    for _p, _ti in enumerate(order):
        _rank[_ti] = _p
    _rank_px = np.repeat(_rank, tile_px)[:n]

    def _prefix_fit(k):
        """Exact (b, t, payload, sfx) for the top-k importance bands, or None."""
        selmask = mask_full & (_rank_px < k)
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


# ---------------------------------------------------------------------
# Hardware display lattice (SP15 palette-collapse fix, 2026-07-27).
#
# ROOT CAUSE this block exists for: the NR $44 palette is 9-bit RGB333
# (512 displayable colours). The encoder used to generate/assign
# palettes in 24-bit space and only truncate at build_palette_block
# time - AND synthesized the 9th blue bit with the hardware's 8-bit
# auto-expand OR rule (4 effective blue levels: 0/109/182/255). On real
# footage the 256 ADAPTIVE entries collapsed onto ~19 distinct
# displayed colours (004/001 leg fixtures, measured), while every
# quality number (BuildReport PSNR, panels, drift triggers) was
# computed against the UN-truncated 8-bit palette - a wire PSNR of
# ~21 dB reported as ~36 dB. Verified NOT a regression: the T1-era
# encoder (caa48ed) wire-measures identically (19 colours, 20.63 dB).
#
# Fix, encoder-side only (wire format untouched - byte1 bit0 was
# always spec'd as the 9th blue bit and the player forwards the whole
# 512-byte block to NR $44):
#   1. palettes are generated IN lattice space (display_palette):
#      median-cut, snap to lattice, dedupe, refill freed entries with
#      the most-frequent unused lattice colours of the dithered scene
#      composite - all 256 entries are distinct displayable colours,
#      stored in decoder-expanded 8-bit form so the encoder's internal
#      decode is byte-identical to the wire decode (PSNR is wire-true);
#   2. build_palette_block writes the TRUE 9th blue bit (b>>5 & 1),
#      doubling blue resolution (exact round-trip for lattice values);
#   3. quantization targets are ordered-dithered (32x32 blue-noise
#      threshold tile, amplitude a settable fraction of one lattice
#      bin - see BLUENOISE32/DITHER_AMP_DEFAULT below): position-
#      deterministic, so temporally STABLE (no frame-to-frame dither
#      churn feeding the delta coder), recovering the gradient depth
#      the 512-colour gamut cannot carry flat (foggy/skin gradients: a
#      frame often CONTAINS only ~36 distinct lattice colours
#      undithered).
# ---------------------------------------------------------------------

# 3-bit -> 8-bit expansion, the reference decoder's own rule
# (nxv2dec._decode_palette_block): value v -> (v<<5)|(v<<2)|(v>>1).
LATTICE_EXP3 = np.array([(v << 5) | (v << 2) | (v >> 1) for v in range(8)],
                        dtype=np.uint8)

# Lattice bin spacing (255/7): the 8 reconstruction levels 0/36/73/109/
# 146/182/219/255 are not quite evenly spaced (36/37 alternating), so
# this is the mean/nominal bin width used for the dither amplitude below.
LATTICE_BIN = 255.0 / 7.0   # 36.42857...


def _nearest_lattice_lut():
    """256-entry LUT, uint8 -> nearest LATTICE_EXP3 level (decoder-
    expanded). Review MAJOR 1 fix (2026-07-27): the old snap was a
    truncating >>5 (floor to the level BELOW x), a worst-case error of
    one full bin (~36/255) with a systematic downward bias. Nearest-
    level rounding halves the worst case to <=18/255 (half a bin) and
    is bias-free (ties split evenly, not always down)."""
    levels = LATTICE_EXP3.astype(np.int32)
    x = np.arange(256, dtype=np.int32)[:, None]
    d = np.abs(x - levels[None, :])
    idx = np.argmin(d, axis=1)
    return LATTICE_EXP3[idx]


LATTICE_NEAREST = _nearest_lattice_lut()

# Transparency-collision exclusion (pal9d, 2026-07-28): the player keeps
# Layer 2 transparency ACTIVE during video with the global transparency
# colour NR $14 = $FE (src/video.asm, TM_TRANSP_ATTR). Hardware
# transparency is a colour compare on the palette entry's FIRST byte
# only (RRRGGGBB) - the 9th blue bit is not compared - so any palette
# entry whose byte0 packs to $FE (R=111, G=111, Bhi=10: display colours
# (255,255,146) and (255,255,182), BOTH 9th-bit variants) renders as
# transparent holes over the blanked layer below (black punch-through
# in bright regions, seen on real hardware in the Big Buck Bunny demo).
# The resident location-graphics path dodges this player-side
# (src/overlay2.asm writes $FF); wire palettes are dodged HERE, at the
# lattice level, so the two points are simply not representable: the
# nearest-level snap, palette derivation and every quantization target
# land on the nearest remaining lattice colour, and the wire-true
# metrics automatically measure what is actually displayed. The remap
# stays on the blue axis (R=G=255 highlights keep their hue; the
# R/G-axis alternatives are 1/255 nearer in raw distance but tint
# near-white highlights pink/green).
TRANSP_COLLISION = ((255, 255, 146), (255, 255, 182))
TRANSP_REMAP = {(255, 255, 146): (255, 255, 109),
                (255, 255, 182): (255, 255, 219)}


def snap_to_lattice(rgb):
    """Snap uint8 RGB (any shape, last axis 3) to the 9-bit display
    lattice, returning decoder-expanded 8-bit values (the colours the
    hardware will actually show). NEAREST-level snap (LATTICE_NEAREST),
    not truncation - see _nearest_lattice_lut. The two NR $14 = $FE
    transparency-collision points are excluded from the representable
    lattice and remapped to their blue-axis neighbours (TRANSP_REMAP)."""
    out = np.empty_like(rgb)
    out[..., 0] = LATTICE_NEAREST[rgb[..., 0]]
    out[..., 1] = LATTICE_NEAREST[rgb[..., 1]]
    out[..., 2] = LATTICE_NEAREST[rgb[..., 2]]
    for src, dst in TRANSP_REMAP.items():
        hit = ((out[..., 0] == src[0]) & (out[..., 1] == src[1])
               & (out[..., 2] == src[2]))
        out[hit] = np.array(dst, dtype=out.dtype)
    return out


# Ordered-dither threshold tile: 32x32 BLUE-NOISE rank matrix
# (replaces the original 8x8 Bayer matrix, owner-approved 2026-07-28:
# Bayer's regular crosshatch was visibly objectionable on smooth
# content - Big Buck Bunny/jellyfish - on real hardware; blue noise
# carries the same mean offset with no low-frequency structure).
#
# PROVENANCE: generated OFFLINE by the void-and-cluster algorithm
# (Ulichney 1993) with a toroidally-wrapped Gaussian energy filter,
# sigma 1.5, on a 32x32 tile; numpy default_rng seed 20260728;
# generated 2026-07-28 by a scratchpad script (gen_bluenoise.py - the
# generator is NOT shipped; this literal table is the single source of
# truth). The table is a permutation of 0..1023 (every rank exactly
# once - tests/nxv2_selftest.py asserts it); spectral check of the
# half-threshold slice: low/high frequency energy ratio 0.021 (no
# low-frequency clumping). NO RUNTIME RANDOMNESS: the dither stays a
# pure position-deterministic function of (y mod 32, x mod 32) and the
# amplitude - identical source pixels dither identically every frame,
# a hard format requirement (zero delta churn on quiet content).
BLUENOISE32 = np.array([
     635,  488,  267,  695,   19,  746,  602,  447,  715,  922,  197,  827,   45,  675,  131,  339,  634,  171,  399,  537,  742,  920,  786,  205,  355,  730,  921,  271,   37,  908,  734,   67,
     800,  137,  844,  994,  326,  899,  145, 1005,   51,  517,  632,  283,  574,  937,  436,  767,  907,  277, 1015,  673,   86,  299,  629,  477,  880,  132,  416,  507,  665,  368,  456,  216,
     970,  378,  603,  187,  458,  539,  243,  648,  311,  761,  373,  989,  160,  796,  234,   92,  563,  472,   41,  820,  431,  168,  985,   58,  577,  688,  233, 1000,  166,  873,  770,  566,
     260,  514,   80,  669,  781,   98,  864,  409,  823,  134,  872,   11,  408,  528,  324,  982,  712,  209,  601,  334,  905,  541,  719,  398,  285,  837,   22,  784,  551,  104,  313,   12,
     855,  721,  895,  349,  946,  278,  708,   34,  576,  229,  473,  622,  737,  892,  660,   25,  383,  798,  962,  122,  661,  235,  860,  143,  955,  469,  637,  341,  438,  709,  956,  652,
     164,  448,  223,   27,  429,  555,  977,  482,  912,  677,  958,  303,  108,  199,  459,  841,  154,  508,  288,  754,  484,    2,  347,  614,  758,   81,  931,  254,  897,  210,  494,  365,
     105,  984,  597,  808,  656,  113,  208,  335,  146,  388,   63,  769,  567, 1020,  268,  591,  934,  674,   46,  885,  377,  973,  797,  509,  207,  369,  568,  135,  814,   40,  612,  828,
     760,  530,  298,  926,  376,  753,  843,  611,  722,  865,  244,  497,  819,  402,   59,  743,  351,  228,  427,  570,  196,  647,  273,   96, 1019,  697,  446,  750,  641,  412, 1008,  284,
     396,  679,   64,  162,  498,  261, 1013,   83,  433,  553,  971,  356,  136,  685,  863,  524,  115,  816, 1007,  733,  121,  840,  439,  582,  869,  290,   52,  961,  328,  167,  560,   78,
     201,  963,  444,  884,  705,    7,  534,  310,  807,  190,   21,  633,  929,  218,  315,  975,  455,  608,   66,  314,  520,  952,   26,  773,  161,  500,  806,  236,  531,  915,  731,  881,
     624,  812,  251,  583,  353,  943,  649,  144,  898,  682,  282,  762,  478,  588,   38,  662,  192,  275,  701,  903,  400,  237,  680,  323,  414,  900,  604,  129,  692,    5,  466,  346,
     515,   29,  716,  123,  852,  220,  419,  757,  348,  483, 1003,  395,   88,  891,  795,  410,  933,  845,  496,  159,  803,  592,  114,  992,  723,   42,  371,  979,  428,  259,  804,  138,
     308, 1022,  386,  489,  778,   87,  573,  964,   39,  594,  120,  861,  239,  340,  532,  127,  741,   20,  370,  643,   54,  932,  453,  533,  194,  645,  280,  756,  847,  593,  954,  671,
     879,  578,  186,  928,  320,  670,  468,  265,  830,  206,  644,  510,  681,  988,  184,  631,  309,  569,  996,  249,  745,  337,  854,  266,  793,  927,  559,   77,  176,  385,   47,  227,
     763,   70,  818,  623,   36, 1002,  148,  726,  390,  925,  301,  787,   14,  403,  752,  949,  463,  102,  874,  430,  543,  163,  693,   10,  422,  142,  475,  342,  997,  513,  725,  450,
     367,  526,  270,  432,  747,  221,  878,  505,   65,  702,  440,  169,  848,  587,   72,  272,  825,  700,  204,  775,   93,  959,  389,  579, 1012,  713,  889,  606,  691,  256,  935,  153,
     651,  993,   95,  916,  547,  380,  609,  312,  976,  556,  103,  957,  487,  217,  890,  523,  155,  391,  610,  319,  887,  626,  222,  832,   82,  305,  215,   30,  824,  109,  580,  839,
     304,  213,  720,  332,  124,  829,    0,  764,  181,  822,  252,  627,  316,  727,  366,  654,  930,    3, 1018,  519,   60,  460,  736,  352,  525,  666,  789,  437,  322,  902,  405,    9,
     950,  557,  859,  464,  696,  953,  262,  653,  471,  359,  689,  856,   28, 1006,  110,  777,  295,  457,  706,  250,  811,  173,  978,  107,  871,  150,  945,  538,  646,  180,  503,  782,
     442,  156,   68,  615,  198,  415,  529,  911,  106,  995,   69,  516,  413,  607,  479,  202,  562,  851,  157,  919,  379,  659,  274,  600,  476,  382,  248,   44,  740, 1017,  258,  699,
     358,  906,  774,  296,  987,   50,  776,  165,  397,  561,  771,  191,  913,  257,  813,  942,   97,  407,  616,   43,  765,  540,  909,   18,  759,  986,  620,  882,  362,  133,  599,   49,
     522,  238,  664,  501,  834,  585,  333,  875,  711,  279,  888,  330,  663,   84,  375,  638,  732,  287,  966,  495,  321,  119,  421,  672,  318,  189,  493,   85,  801,  435,  936,  833,
     724, 1004,   15,  384,  140,  245,  650,  474,   16,  625,  125,  490,  738,  981,  178,  499,   23,  794,  219,  684,  831,  983,  231,  790,  101,  850,  717,  281,  550,  678,  297,  193,
     572,  126,  462,  886,  735,  938,   89, 1014,  226,  805,  968,  418,   33,  558,  849,  317, 1011,  565,  451,   73,  175,  595,  502,  894,  449,  584,  374,  998,  147,  893,   79,  424,
     338,  817,  630,  289,  552,  345,  426,  749,  518,  372,  589,  188,  783,  263,  443,  676,  130,  867,  302,  940,  401,  739,   35,  344,  170,  948,    8,  640,  230,  491,  772,  960,
     690,  174,  972,   55,  183,  821,  668,  158,  918,   62,  291,  901,  642,  941,   53,  768,  387,  203,  714,  619,  846,  255, 1021,  554,  704,  269,  779,  434,  835,  350,  618,   32,
     276,  521,  417,  703,  917,  485,   24,  307,  617,  836,  707,  116,  357,  511,  225,  605,  904,  480,    6,  512,  128,  360,  667,   91,  876,  492,  141,  910,   74,  542,  182,  862,
     944,  100,  788,  354,  575,  224,  868,  991,  461,  232,  420,  548,  866,   94,  990,  329,  112,  810,  999,  240,  785,  914,  452,  214,  766,  325,  590,  698,  293, 1009,  744,  445,
     581,  658,  241, 1023,   75,  729,  393,  544,   99,  780,  947,  200,  748,  441,  799,  686,  549,  286,  657,  406,  546,   48,  598,  967,  404,   31,  951,  212,  423,  628,  117,  364,
       1,  883,  465,  151,  636,  294,  792,  177,  683,  336,    4,  639,  292,  596,   61,  394,  185,  924,   71,  755,  179,  858,  306,  139,  655,  853,  527,  751,   57,  870,  247,  826,
     195,  718,  331,  809,  939,  504,   56,  965,  586,  857,  506, 1016,  149,  896,  246,  974,  710,  467,  327,  613,  980,  481,  694,  815,  264,  454,  172,  343,  969,  470,  687,  536,
     392,  923,   90,  564,  411,  211,  842,  361,  253,  111,  425,  728,  363,  486,  838,  535,   17,  791,  877,  118,  242,  381,   13,  545, 1010,   76,  621,  802,  571,  152,  300, 1001,
], dtype=np.int32).reshape(32, 32)

# Dither amplitude knob (owner-approved 2026-07-28; the SP17 Yliluoma
# wave 2026-07-28 added a SECOND meaning for the opt-in mixture mode -
# see the DITHER_MODE block below):
#
#   mode "offset" (DEFAULT, unchanged behaviour):
#       the per-pixel offset is (threshold_norm - 0.5) * DITHER_STEP *
#       amplitude - one full lattice quantization step at 1.0, 0.0 is
#       a pure nearest-colour snap.
#   mode "mixture" (OPT-IN, Yliluoma positional mixture dithering):
#       amplitude is the FRACTION OF THE PIXEL'S QUANTIZATION ERROR the
#       dither is asked to correct. The mixture target is the gamma-
#       correct mix of the pixel's nearest palette colour (amplitude 0)
#       and the true source colour (amplitude 1); the mixture planner
#       then reproduces THAT target. 0.0 = pure nearest-colour, no
#       dither; 1.0 = full Yliluoma (local mean reproduces the source).
#       There is no single "offset" any more - a mixture plan has no
#       amplitude - so this is the amplitude analogue that keeps the
#       knob monotone, keeps 0.0 meaning "off", and keeps author control.
#
# DEFAULT 0.5 is UNCHANGED (the owner's ratified "0.5 looks best"). The
# mixture meaning was chosen so that at 0.5 its measured GRAIN (fraction
# of pixels emitted away from the pure nearest colour) lands on the
# offset path's own 0.5 grain on all three leg sources (Sintel .286 vs
# .320, Big Buck Bunny .30 vs .30, Jellyfish .21 vs .20) - the two modes
# are comparable at the same number.
# CLI: videnc --dither / --dither-mode; kit config: VIDOPTS/VIDOPTS_NNN.
DITHER_STEP = LATTICE_BIN
DITHER_AMP_DEFAULT = 0.5

# WHICH DITHER IS DEFAULT (SP17 Yliluoma wave, decided on measurement
# 2026-07-28). OFFSET, with the Yliluoma mixture path shipped OPT-IN.
# The mixture algorithm is implemented in full below and is a genuine
# improvement on some content, but it is NOT a win on this project's
# real content and it must not be the silent default. The evidence, so
# nobody re-litigates this blind:
#
#  - PER-PIXEL WIRE PSNR: mixture loses on EVERY fixture measured -
#    -0.43 to -3.55 dB across the eleven leg fixtures here, and an
#    independent measurement wave on the owner's own boat-pan and
#    church-zoom clips found the same (-0.75 to -1.46 dB). Some of that
#    is inherent to any dither, but the size of it is not.
#  - LOCAL-MEAN FIDELITY (the metric that should favour a mixture
#    dither): SPLIT. Mixture wins clearly on Jellyfish and on Sintel and
#    at high amplitude everywhere, and loses on Big Buck Bunny and on
#    the owner's church-zoom clip. It is not a uniform win.
#  - COLOUR CAST: mixture carries a systematic PER-CHANNEL MEAN BIAS
#    that the offset dither does not. Measured over 8 frames against
#    the source mean: Big Buck Bunny blue -3.1 (offset -0.9) at
#    amplitude 0.5 and -4.7 at 1.0; the independent wave measured the
#    same shape as a green deficit on dark content. The cause is
#    structural, not a bug: the plan minimizes the RGBL distance of the
#    list's MEAN to the target, and RGBL deliberately discounts chroma
#    (x0.75) against luma (+lumadiff^2), so the planner will trade a
#    per-channel mean error for a luma match. Nothing in the article
#    claims otherwise.
#  - DELTA COST: up to +26% wire bytes on colourful moving content, and
#    it pushed 003 from 72% to 92% budget-bound. See the wave report.
#  - PALETTE MATERIAL: the display lattice holds only 510 usable
#    colours and real clips occupy ~100 of them across a whole clip
#    (~70 per frame), so scene palettes carry only ~85-95 DISTINCT
#    entries. Algorithm 2 assumes a richer set to mix from than this
#    content actually provides.
#  - IT WEAKENS TWO KEYFRAME TRIGGERS. display_ceiling measures a
#    FULLY dithered frame, while the achieved surface keeps pixels
#    closer to the source (index hysteresis, partial delta updates).
#    Mixture dithering's per-pixel penalty is large enough to invert
#    that: measured over three leg clips, po_ceil - achieved stays
#    POSITIVE on 110/110 frames in offset mode but goes NEGATIVE on
#    105/110 in mixture mode (mean -0.63 to +0.09 dB, min -1.13). A
#    negative deficit can never cross DRIFT_T or STALE_DB, so the drift
#    and staleness keyframes go structurally inert. Fixing that means
#    re-basing po_ceil, which would re-calibrate the triggers for BOTH
#    modes - deliberately not done in this wave. Anyone promoting
#    mixture to default must deal with this first.
#
# Both modes stay positionally deterministic, both honour --dither, and
# the two unconditional halves of the wave - gamma-correct mixing and
# the luminance-weighted RGBL distance metric - apply in BOTH modes and
# stand on their own. Flip with videnc --dither-mode mixture.
DITHER_MODE_MIXTURE = "mixture"
DITHER_MODE_OFFSET = "offset"
DITHER_MODE_DEFAULT = DITHER_MODE_OFFSET
DITHER_MODES = (DITHER_MODE_MIXTURE, DITHER_MODE_OFFSET)


def _dither_amp(amplitude):
    """Normalize a dither-amplitude argument: None - and the legacy
    boolean --dither flag, EITHER value (it was an accepted-for-
    compatibility no-op) - mean DITHER_AMP_DEFAULT; anything else is a
    float validated into 0.0-1.0."""
    if amplitude is None or isinstance(amplitude, bool):
        return DITHER_AMP_DEFAULT
    a = float(amplitude)
    if not (0.0 <= a <= 1.0):
        raise ValueError(f"dither amplitude must be 0.0-1.0, got {amplitude}")
    return a


def _dither_mode(mode):
    if mode is None:
        return DITHER_MODE_DEFAULT
    m = str(mode)
    if m not in DITHER_MODES:
        raise ValueError(f"dither mode must be one of {DITHER_MODES}, got {mode!r}")
    return m


def _bluenoise_tile(H, W, phase=None):
    """The (H,W) blue-noise threshold tile, its origin displaced by
    `phase` = (px, py) pixels so the matrix travels WITH content
    (SP17 T5a motion-locked dither: value previously at (y, x) appears
    at (y+py, x+px)). phase None/(0,0) indexes exactly as the shipped
    expression - byte-identical, asserted by the selftest - so
    non-shifted content is bit-unchanged."""
    if phase:
        px, py = int(phase[0]) % 32, int(phase[1]) % 32
    else:
        px = py = 0
    return BLUENOISE32[(np.arange(H)[:, None] - py) % 32,
                       (np.arange(W)[None, :] - px) % 32]


def ordered_dither(frame, amplitude=None, phase=None):
    """LEGACY (mode "offset") blue-noise ordered dither of an (H,W,3)
    uint8 frame: per-pixel offset (threshold_norm - 0.5) * DITHER_STEP *
    amplitude, the same offset on all three channels (no hue noise).
    Position-deterministic (a pure function of y%32, x%32 and the
    amplitude): identical source pixels dither identically every frame,
    so quiet content produces ZERO index churn. amplitude None ->
    DITHER_AMP_DEFAULT; 0.0 returns the frame unchanged (pure nearest
    snap happens downstream). phase (SP17 T5a): displaces the threshold
    tile origin so the matrix travels with panning content - None/(0,0)
    is byte-identical to the pre-T5a function.

    This is the DEFAULT dither path (see the DITHER_MODE_DEFAULT block
    above for why the Yliluoma mixture path ships opt-in), and it also
    drives the palette-refill spread probe (PALETTE_SPREAD_AMP)."""
    amp = _dither_amp(amplitude)
    H, W, _ = frame.shape
    t = ((_bluenoise_tile(H, W, phase).astype(np.float32) + 0.5)
         / 1024.0 - 0.5)
    f = frame.astype(np.float32) + (t * (DITHER_STEP * amp))[..., None]
    return np.clip(f, 0.0, 255.0).astype(np.uint8)


# ---------------------------------------------------------------------
# GAMMA-CORRECT MIXING + LUMINANCE-WEIGHTED COLOUR DISTANCE
# (SP17 Yliluoma wave, 2026-07-28 - Joel Yliluoma, "Arbitrary-palette
# positional dithering algorithm", https://bisqwit.iki.fi/story/howto/
# dither/jy/).
#
# WHY. Two of the article's points apply to this encoder verbatim:
#
#  1. MIXING MUST BE GAMMA-AWARE. Light adds LINEARLY; sRGB-ish 8-bit
#     values do not. Averaging 8-bit values directly ("a + (b-a)*ratio")
#     produces a mix that misrepresents what the eye will see when the
#     two colours alternate spatially - a 50/50 black/white dither reads
#     as ~186, not 128. Every place this encoder MIXES or AVERAGES
#     colours uses gamma_mix()'s formula with gamma 2.2. (The DEFAULT
#     offset dither mixes nothing - it displaces one pixel and snaps -
#     so in practice this governs the mixture path; it is stated and
#     tested here so no future mixing site gets it wrong.)
#         a' = a^g,  b' = b^g,  r' = a' + (b'-a')*ratio,  r = r'^(1/g)
#     WHERE GAMMA DOES NOT APPLY (deliberately, all verified below):
#       - snap_to_lattice / LATTICE_NEAREST: a nearest-ENTRY lookup, no
#         mixing happens, and the lattice levels are hardware
#         reconstruction values - snapping in linear space would bias
#         the choice away from the hardware's own spacing.
#       - _nearest / colour distance: a comparison, not a mix.
#       - psnr(): a WIRE-TRUE error metric against the displayed 8-bit
#         values - re-basing it would silently change every reported
#         number and every drift trigger threshold.
#       - build_palette_block / the 3-bit lattice packing: bit layout.
#
#  2. COLOUR DISTANCE, LUMINANCE-WEIGHTED. Plain Euclidean RGB treats a
#     blue error as it treats a green one; the eye does not. The
#     article's cheap "RGBL" metric (its own CIEDE2000 section reports
#     that metric "works better for some pictures than for others" and
#     can scatter yellow pixels, so the cheap metric is the right
#     target) is:
#         lumadiff = (r1-r2)*.299 + (g1-g2)*.587 + (b1-b2)*.114, /255
#         D = (dR^2*.299 + dG^2*.587 + dB^2*.114)*0.75 + lumadiff^2
#     with dR/dG/dB normalized to 0..1. D expands to a plain SQUARED
#     EUCLIDEAN distance in a 4-D embedding (_rgbl_embed): three axes
#     c*sqrt(0.75*w_c) plus one luma axis - so the same matmul
#     nearest-neighbour solver carries it, at 4/3 the width
#     (_nearest_rgbl).
#
#     WHERE IT IS USED: the mixture dither, everywhere - every plan
#     decision and its nearest-colour anchor. WHERE IT IS NOT: the
#     DEFAULT (offset) path's nearest-palette search and hysteresis,
#     which stay on plain squared-RGB. That is a MEASURED decision, not
#     an oversight. Swapping the shipped nearest-colour search to RGBL
#     was tried and re-encoded across all eleven leg fixtures: it lost
#     0.36-1.85 dB of per-pixel wire PSNR AND 0.9-3.0 dB of 4x4
#     local-mean PSNR - every fixture worse on both metrics - and it
#     made the per-channel mean bias worse, not better (001 red -4.99
#     -> -6.16, blue -3.82 -> +1.08: a visible cast). The cause is the
#     palette: these are sparse subsets of a 510-colour hardware
#     lattice, so "perceptually nearest" routinely means a chroma jump
#     the eye does see, and there is no denser entry to fall back on.
#     Nothing in the article claims otherwise - it assumes a palette
#     you can actually mix within.
#
#     PALETTE DERIVATION is Pillow's own median-cut (adaptive_palette),
#     which exposes no distance hook, so no metric applies to the cut
#     itself; the lattice snap + frequency refill that follow it are
#     exact-match operations with no distance in them.
# ---------------------------------------------------------------------

GAMMA = 2.2
_GAMMA_LIN = ((np.arange(256, dtype=np.float64) / 255.0) ** GAMMA).astype(np.float32)
_GAMMA_SRGB_N = 4096
_GAMMA_SRGB = ((np.linspace(0.0, 1.0, _GAMMA_SRGB_N) ** (1.0 / GAMMA))
               * 255.0).astype(np.float32)
RGBL_W = np.array([0.299, 0.587, 0.114], dtype=np.float32)


def to_linear(rgb8):
    """uint8 sRGB-ish value(s) -> linear light 0..1 (LUT, exact)."""
    return _GAMMA_LIN[np.asarray(rgb8, dtype=np.uint8)]


def from_linear(lin):
    """Linear light 0..1 -> 0..255 float. LUT-interpolated at
    _GAMMA_SRGB_N steps: a pow() per element costs ~50x more and the
    step (1/4096 of full scale) is 1/580 of one lattice bin."""
    i = np.clip(np.asarray(lin, dtype=np.float32) * (_GAMMA_SRGB_N - 1),
                0, _GAMMA_SRGB_N - 1).astype(np.int32)
    return _GAMMA_SRGB[i]


def gamma_mix(a, b, ratio):
    """Yliluoma's gamma-aware mix of two uint8 colours: a'=a^g, b'=b^g,
    r'=a'+(b'-a')*ratio, r=r'^(1/g). ratio 0 -> a, 1 -> b. Returns
    uint8 (rounded). `ratio` must be a scalar or already broadcastable
    against the (...,3) colour arrays (pass (...,1), not (...,)) - no
    axis is guessed, because a length-3 ratio vector would be
    indistinguishable from a per-channel one.

    The encoder's own two mixing sites work in unrounded float on the
    same formula rather than calling this (MixturePlanner._solve
    accumulates the candidate list in linear light; MixturePlanner.plan
    pulls the dither target from the nearest palette colour toward the
    source) - rounding to uint8 mid-pipeline would cost precision for
    nothing. This is the shared, testable statement of the formula."""
    la = (np.asarray(a, dtype=np.float64) / 255.0) ** GAMMA
    lb = (np.asarray(b, dtype=np.float64) / 255.0) ** GAMMA
    r = np.asarray(ratio, dtype=np.float64)
    m = np.clip(la + (lb - la) * r, 0.0, 1.0)
    # exact pow, not from_linear()'s LUT: this is the reference
    # statement of the formula and must round-trip its endpoints
    # exactly (ratio 0 -> a, ratio 1 -> b), not to within a code
    return np.clip(np.rint((m ** (1.0 / GAMMA)) * 255.0), 0, 255).astype(np.uint8)


def color_compare(a, b):
    """Yliluoma's RGBL colour difference (see the block comment above).
    a/b are float/uint8 arrays (...,3) on the 0..255 scale; returns the
    squared perceptual distance (0 .. ~1.75)."""
    d = (np.asarray(a, dtype=np.float32) - np.asarray(b, dtype=np.float32)) / 255.0
    return ((d[..., 0] ** 2 * 0.299 + d[..., 1] ** 2 * 0.587
             + d[..., 2] ** 2 * 0.114) * 0.75 + (d @ RGBL_W) ** 2)


def _rgbl_embed(rgb):
    """(...,3) 0..255 -> (...,4) float32 whose SQUARED EUCLIDEAN
    distance is exactly color_compare(): three colour axes scaled by
    sqrt(0.75*w_c) plus a luma axis. Lets the matmul nearest-neighbour
    solver carry the perceptual metric with no change of shape."""
    v = np.asarray(rgb, dtype=np.float32) / 255.0
    return np.concatenate([v * np.sqrt(0.75 * RGBL_W), (v @ RGBL_W)[..., None]],
                          axis=-1).astype(np.float32)


# ---------------------------------------------------------------------
# YLILUOMA POSITIONAL MIXTURE DITHERING - Algorithm 2 (the N-way
# iterative mixing plan), SP17 wave 2026-07-28.
#
# WHICH VARIANT, AND WHY. The article offers algorithm 1 (best PAIR of
# palette entries + a mixing ratio; "refined" solves that ratio
# analytically instead of scanning it), and algorithm 2 (greedily builds
# an N-COLOUR candidate list). Measured here, on this encoder's own
# palettes, algorithm 1 is structurally too weak: our palettes are
# subsets of a 512-colour hardware lattice and a scene often carries
# only 45-190 DISTINCT entries with ~36/255 gaps, so the best two-colour
# mixture cannot land near the target. On the 001 Sintel leg frame the
# best algorithm-1 plan still sat 6.8 RMS from the source and its
# realized 16x16 local mean was 5.4 RMS off, WORSE than the offset
# dither it replaces (1.8); algorithm 2, which may spend its 32 list
# slots over several entries, reaches 0.66. The analytic-ratio
# refinement only accelerates algorithm 1's ratio scan, so it inherits
# that ceiling and buys nothing here. Algorithm 2 it is.
#
# PSYCHOVISUAL PENALTY: NOT INCLUDED, on measurement (the article makes
# it optional - "if your measurements support it"). Algorithm 1's
# penalty term (component difference x 0.1 x mixing evenness) was ported
# to algorithm 2 as a per-component "distance from target x share of the
# list" term and swept at weights 0.25/0.5/1/2/4/8 on all three leg
# sources. It reduces grain, but strictly WORSE than simply lowering the
# amplitude does: at matched grain it cost 15-80% more local-mean error
# on every clip (e.g. Sintel at grain .32: penalty 6.97 RMS vs amplitude
# 3.82 RMS). The article's OTHER stated pruning - restrict the mixable
# set - is kept instead, as MIX_NEIGHBOURS: it is self-normalizing
# against palette density, which is the whole point of the exercise.
#
# HARD INVARIANTS (all pinned by tests/nxv2_selftest.py step 13):
#   - POSITIONAL DETERMINISM. The emitted index is a pure function of
#     (x mod 32, y mod 32, source colour, palette, amplitude). No frame
#     index, no randomness, no error diffusion, no dependence on any
#     neighbouring pixel's RESULT. Delta compression depends on it.
#   - The threshold matrix stays BLUENOISE32 (owner-ratified on silicon
#     over Bayer). The article's index formula generalises to any
#     matrix: list[ matrix_value * list_size / matrix_max ]; here that
#     is BLUENOISE32 (0..1023) * MIX_LEVELS // 1024.
#   - Only palette indices are ever emitted, so the $FE transparency
#     exclusion baked into display_palette/snap_to_lattice still holds
#     by construction.
# ---------------------------------------------------------------------

# Candidate-list length: the mixing plan is MIX_LEVELS palette slots,
# luminance-sorted, indexed by the blue-noise rank. 32 measured better
# than 16 (finer ratios: Sintel local-mean RMS 0.66 vs 0.83 at full
# amplitude) for ~1.3x the plan cost; 64 added <0.1 RMS for 2x.
MIX_LEVELS = 32

# Mixable set per target: the MIX_NEIGHBOURS nearest DISTINCT palette
# entries under RGBL. This is the article's "prune implausible mixes"
# step, and it is what makes the dither adapt to palette DENSITY (the
# defect that started this wave): where the palette is dense the 8
# nearest entries are all close, so mixtures stay subtle; where it is
# sparse they are the only material available. 8 measured better than 4
# on local-mean fidelity at equal grain and better than 16/32 on
# per-pixel PSNR (16+ starts reaching for far colours - the article's
# "scattered pixels" hazard).
MIX_NEIGHBOURS = 8

# Mixture targets are cached on a 6-bit-per-channel grid (step 4/255,
# i.e. 1/9 of a lattice bin; the resulting noise floor sits at ~47 dB,
# ~20 dB below anything this codec reports). The grid is what makes the
# plan cache hit across frames of a scene - without it every frame pays
# the full solve. 6 vs 7 bits measured 1.8x faster for 0.05-0.09 dB of
# per-frame ceiling; 5 bits was 0.4 dB and too coarse.
MIX_QBITS = 6

# display_ceiling() subsamples by this stride on both axes before
# solving, IN MIXTURE MODE ONLY (the palette is still derived from the
# whole frame). The ceiling is a per-frame PSNR yardstick, not an
# emitted picture, and a stride-4 sample of a 320x256 frame is still
# 5120 pixels covering 64 distinct blue-noise threshold cells -
# measured within 0.06 dB of the full-frame ceiling on both leg
# sources, for 3-5x the speed. It is needed because a fresh palette per
# frame means a cold mixture plan cache every time, which made this the
# single hottest call in the encoder. The DEFAULT path is cheap and
# takes no stride, so its po_ceil - and therefore every drift and
# staleness trigger, and therefore every emitted byte - is bit-for-bit
# what it was before this wave.
CEILING_STRIDE = 4

# Plan-cache ceiling (distinct quantized targets held per palette).
# Reached only by very long, very colourful scenes; overflow simply
# resets the cache, which is exact (a cache miss recomputes the same
# plan) and costs time, never bytes.
MIX_CACHE_MAX = 600_000

# Palette-refill spread probe. display_palette fills slots left over
# after the median cut with the most-frequent lattice colours an
# ORDERED-DITHERED composite asks for. In offset mode that probe is the
# encode's own dither, unchanged. In MIXTURE mode --dither no longer
# maps onto a spread at all, so the probe is pinned to a FIXED 0.5 -
# which also makes mixture-mode palettes identical to the offset-mode
# ones at the default amplitude, so a mode A/B measures the DITHER and
# nothing else.
PALETTE_SPREAD_AMP = 0.5


class MixturePlanner:
    """Yliluoma algorithm-2 mixing plans for one (palette, amplitude).

    Holds a target-colour -> candidate-list cache that persists across
    the frames of a scene (the palette is held for a whole scene, so the
    hit rate after the first frame is high). Purely functional: the
    cache never changes an answer, only the time to get it."""

    def __init__(self, pal, amplitude=None, levels=MIX_LEVELS,
                 neighbours=MIX_NEIGHBOURS, qbits=MIX_QBITS):
        self.pal = np.ascontiguousarray(pal, dtype=np.uint8)
        self.amp = _dither_amp(amplitude)
        self.levels = int(levels)
        self.qbits = int(qbits)
        # Distinct palette colours only: display_palette pads unused
        # slots with a copy of entry 0, and mixing a colour with itself
        # is a wasted candidate slot.
        uniq, inv = np.unique(self.pal.reshape(-1, 3), axis=0, return_inverse=True)
        self.uniq = uniq
        self.neighbours = int(min(neighbours, uniq.shape[0]))
        # distinct -> a palette index that carries that colour (lowest
        # index wins, so plans stay stable against slot duplication)
        dmap = np.zeros(uniq.shape[0], dtype=np.uint8)
        for i in range(self.pal.shape[0] - 1, -1, -1):
            dmap[inv[i]] = i
        self.dmap = dmap
        self._uniq_lin = to_linear(uniq)
        self._uniq_emb = _rgbl_embed(uniq)
        self._uniq_lum = (uniq.astype(np.float32) @ RGBL_W)
        self._keys = np.zeros(0, dtype=np.int32)
        self._lists = np.zeros((0, self.levels), dtype=np.uint8)
        self._plan_rgb = np.zeros((0, 3), dtype=np.uint8)

    # -- Algorithm 2 proper -------------------------------------------
    def _solve(self, targets, chunk=4096):
        """targets (U,3) float 0..255 -> (lists (U,L) uint8 index into
        self.uniq, plan_rgb (U,3) uint8 the plan's achieved colour).

        The article's loop: repeatedly pick the palette colour (and a
        power-of-two repeat count) whose addition brings the running
        MEAN closest to the target, until the list is full; then sort
        the list by luminance."""
        L = self.levels
        U = targets.shape[0]
        lists = np.zeros((U, L), dtype=np.uint8)
        plan_rgb = np.zeros((U, 3), dtype=np.uint8)
        for s in range(0, U, chunk):
            tg = np.ascontiguousarray(targets[s:s + chunk], dtype=np.float32)
            n = tg.shape[0]
            te = _rgbl_embed(tg)
            pe = self._uniq_emb
            d = (np.sum(te * te, 1)[:, None] - 2.0 * (te @ pe.T)
                 + np.sum(pe * pe, 1)[None, :])
            k = self.neighbours
            nb = (np.argpartition(d, k - 1, axis=1)[:, :k] if k < d.shape[1]
                  else np.tile(np.arange(d.shape[1]), (n, 1)))
            cand = self._uniq_lin[nb]                  # (n,k,3) linear light
            so_far = np.zeros((n, 3), dtype=np.float32)
            total = np.zeros(n, dtype=np.int32)
            lst = np.zeros((n, L), dtype=np.uint8)
            tgn = tg / 255.0
            pos = np.arange(L)[None, :]
            scale = np.float32(_GAMMA_SRGB_N - 1)
            # ACTIVE SET. A target's plan is finished as soon as its list
            # is full, and the greedy step often adds only one slot, so a
            # naive loop would keep re-evaluating long-finished rows for
            # up to L passes. Compacting to the still-unfinished rows each
            # pass is the difference between ~8x and ~1x the necessary
            # work on real footage; it changes no result.
            act = np.arange(n)
            while act.size:
                a_tot = total[act]
                a_so = so_far[act]
                a_cand = cand[act]
                a_tgn = tgn[act]
                m = act.size
                best_pen = np.full(m, np.inf, dtype=np.float32)
                best_c = np.zeros(m, dtype=np.int32)
                best_p = np.ones(m, dtype=np.int32)
                maxp = np.maximum(1, a_tot)
                p = 1
                while p <= L:
                    ok = p <= maxp
                    if bool(ok.any()):
                        t = (a_tot + p).astype(np.float32)[:, None, None]
                        # linear mean of the candidate list if `p` copies
                        # of each candidate were appended; the convex
                        # combination is in [0,1] by construction, so the
                        # sRGB LUT index needs no clip
                        lin = (a_so[:, None, :] + a_cand * p) / t
                        test = _GAMMA_SRGB[(lin * scale).astype(np.int32)] * np.float32(1.0 / 255.0)
                        dd = a_tgn[:, None, :] - test
                        pen = ((dd[..., 0] ** 2 * 0.299 + dd[..., 1] ** 2 * 0.587
                                + dd[..., 2] ** 2 * 0.114) * 0.75 + (dd @ RGBL_W) ** 2)
                        bi = np.argmin(pen, axis=1)
                        bv = pen[np.arange(m), bi]
                        take = ok & (bv < best_pen)
                        best_pen = np.where(take, bv, best_pen)
                        best_c = np.where(take, bi, best_c)
                        best_p = np.where(take, p, best_p)
                    p *= 2
                cnt = np.minimum(best_p, L - a_tot)
                gi = nb[act, best_c]                   # index into self.uniq
                mask = (pos >= a_tot[:, None]) & (pos < (a_tot + cnt)[:, None])
                lst[act] = np.where(mask, gi[:, None].astype(np.uint8), lst[act])
                so_far[act] = a_so + self._uniq_lin[gi] * cnt[:, None]
                total[act] = a_tot + cnt
                act = act[total[act] < L]
            # luminance sort: the article's candidate list is ordered so
            # the threshold matrix walks it from dark to light
            order = np.argsort(self._uniq_lum[lst], axis=1, kind="stable")
            lists[s:s + n] = np.take_along_axis(lst, order, axis=1)
            plan_rgb[s:s + n] = np.clip(
                np.rint(from_linear(so_far / float(L))), 0, 255).astype(np.uint8)
        return lists, plan_rgb

    def _lookup(self, codes):
        """Plan ids for packed quantized target codes, solving+caching
        any that are new."""
        uc = np.unique(codes)
        if self._keys.size:
            new = uc[~np.isin(uc, self._keys, assume_unique=True)]
        else:
            new = uc
        if new.size:
            if self._keys.size + new.size > MIX_CACHE_MAX:
                self._keys = np.zeros(0, dtype=np.int32)
                self._lists = np.zeros((0, self.levels), dtype=np.uint8)
                self._plan_rgb = np.zeros((0, 3), dtype=np.uint8)
                new = uc
            ut = np.stack([(new >> 16) & 255, (new >> 8) & 255, new & 255],
                          axis=1).astype(np.float32)
            nl, nrgb = self._solve(ut)
            allk = np.concatenate([self._keys, new])
            o = np.argsort(allk)
            self._keys = allk[o]
            self._lists = np.concatenate([self._lists, nl])[o]
            self._plan_rgb = np.concatenate([self._plan_rgb, nrgb])[o]
        return np.searchsorted(self._keys, codes)

    def plan(self, frame, phase=None):
        """(H,W,3) uint8 source -> (idx (H,W) uint8 palette indices,
        target (H,W,3) uint8 the mixture target each pixel aimed at).
        phase: threshold-tile origin displacement (SP17 T5a motion
        lock) - None/(0,0) is byte-identical to the pre-T5a plan."""
        H, W, _ = frame.shape
        f = frame.reshape(-1, 3)
        if self.amp >= 1.0:
            tgt = f.astype(np.float32)
        elif self.amp <= 0.0:
            tgt = self.pal[_nearest_rgbl(f, self.pal)].astype(np.float32)
        else:
            # amplitude: gamma_mix()'s formula, in unrounded float -
            # pull the dither target from the pixel's nearest palette
            # colour toward its true source colour
            near_lin = to_linear(self.pal[_nearest_rgbl(f, self.pal)])
            tgt = from_linear(near_lin + (to_linear(f) - near_lin) * self.amp)
        step = 1 << (8 - self.qbits)
        q = np.clip(np.rint(tgt / step) * step, 0, 255).astype(np.int32)
        codes = (q[:, 0] << 16) | (q[:, 1] << 8) | q[:, 2]
        pid = self._lookup(codes)
        # the article's indexing formula, generalised to our matrix:
        #   list[ matrix_value * list_size / matrix_max ]
        t = (_bluenoise_tile(H, W, phase)
             * self.levels // 1024).reshape(-1)
        idx = self.dmap[self._lists[pid, t]]
        return idx.reshape(H, W), self._plan_rgb[pid].reshape(H, W, 3)


# Planner cache: encode_clip alternates between a held palette and a
# fresh keyframe palette, and the auto-budget search replays the same
# clip several times, so a handful of live planners covers everything.
_MIX_PLANNERS = {}
_MIX_PLANNER_MAX = 4


def mixture_planner(pal, amplitude=None):
    key = (hashlib.blake2b(np.ascontiguousarray(pal, dtype=np.uint8).tobytes(),
                           digest_size=16).digest(), _dither_amp(amplitude))
    p = _MIX_PLANNERS.get(key)
    if p is None:
        if len(_MIX_PLANNERS) >= _MIX_PLANNER_MAX:
            _MIX_PLANNERS.pop(next(iter(_MIX_PLANNERS)))
        p = MixturePlanner(pal, amplitude)
        _MIX_PLANNERS[key] = p
    return p


def _lattice_codes(rgb_flat):
    v = rgb_flat.astype(np.int32)
    return (v[:, 0] << 16) | (v[:, 1] << 8) | v[:, 2]


def display_palette(composite, colors=256, amplitude=None, mode=None):
    """Palette of `colors` DISTINCT displayable lattice colours for an
    (rows,W,3) composite: Pillow median-cut (keeps rare-but-salient
    colours), snapped to the lattice and deduped, then freed slots
    refilled with the most-frequent unused lattice colours of the
    ordered-dithered composite (what the dithered pixels will actually
    ask for). Entries are decoder-expanded 8-bit values; if the scene
    holds fewer distinct lattice colours than `colors`, the tail
    duplicates entry 0 (never selected by nearest-match).

    The refill SPREAD probe follows the encode's own dither in offset
    mode; in mixture mode it is pinned to PALETTE_SPREAD_AMP (see that
    constant - it keeps palettes identical to the pre-Yliluoma encoder
    so the wave's numbers measure the dither alone)."""
    spread = (amplitude if _dither_mode(mode) == DITHER_MODE_OFFSET
              else PALETTE_SPREAD_AMP)
    snapped = snap_to_lattice(adaptive_palette(composite, colors=colors))
    codes = _lattice_codes(snapped)
    seen = set()
    kept = []
    for c in codes.tolist():
        if c not in seen:
            seen.add(c)
            kept.append(c)
    if len(kept) < colors:
        dpost = snap_to_lattice(ordered_dither(composite, spread)).reshape(-1, 3)
        uniq, counts = np.unique(_lattice_codes(dpost), return_counts=True)
        for c in uniq[np.argsort(-counts)].tolist():
            if len(kept) >= colors:
                break
            if c not in seen:
                seen.add(c)
                kept.append(c)
    pal = np.zeros((colors, 3), dtype=np.uint8)
    n = len(kept)
    arr = np.array(kept, dtype=np.int64)
    pal[:n, 0] = (arr >> 16) & 0xFF
    pal[:n, 1] = (arr >> 8) & 0xFF
    pal[:n, 2] = arr & 0xFF
    if n < colors:
        pal[n:] = pal[0]
    return pal


def display_ceiling(frame, amplitude=None, mode=None):
    """Per-frame quality ceiling in DISPLAY space: the PSNR of the
    frame's own best display_palette applied to its dithered self - the
    wire-true analogue of the old 24-bit ADAPTIVE po_ceil (drift
    triggers compare achieved PSNR against this, so both sides of that
    comparison must live in the same space, at the SAME dither amplitude
    AND MODE as the encode itself)."""
    return display_ceilings(frame, amplitude=amplitude, mode=mode)[0]


def display_ceilings(frame, amplitude=None, mode=None):
    """(per-pixel ceiling, 4x4 local-mean ceiling) for one frame - the
    same fresh-palette dithered decode scored in both spaces at once
    (one palette solve, one quantize). The lm ceiling is the reference
    the W4 re-based drift/staleness triggers compare against; both
    sides of each comparison must live in the same space at the same
    dither amplitude and mode."""
    m = _dither_mode(mode)
    pal = display_palette(frame, amplitude=amplitude, mode=m)
    sub = (frame if m == DITHER_MODE_OFFSET
           else frame[::CEILING_STRIDE, ::CEILING_STRIDE])
    _, dec = dither_quantize(sub, pal, amplitude=amplitude, mode=m)
    return psnr(sub, dec), psnr_lm(sub, dec)


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
# 150 (squared RGB distance): a pixel keeps its old index while the
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

# The same deadzone expressed in RGBL units, for the opt-in mixture path
# (which compares in RGBL throughout). RGBL is ANISOTROPIC - it weights
# a luma error ~1.75x and a pure-chroma one 0.75x - so no single scalar
# reproduces the Euclidean deadzone in every direction. This takes the
# SMALLEST ratio (a blue-only error, 0.0985/1) so the mixture path's
# deadzone is never LARGER than the default path's in any direction;
# scaling on the grey axis instead measured as a visible blue/red cast
# (frozen chroma), which is exactly what an over-wide deadzone does.
HYSTERESIS_EPS_RGBL = 150.0 * 0.0985 / (255.0 * 255.0)


def _nearest(vecs, cb, chunk=32768, want_dist=False):
    """Nearest-colour solve, PLAIN squared-Euclidean RGB. This is the
    shipped default path and it is deliberately NOT the RGBL metric -
    see the RGBL block above for the measurement that kept it that
    way; _nearest_rgbl() below carries the perceptual metric for the
    opt-in mixture dither."""
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


def _nearest_rgbl(vecs, cb, chunk=32768):
    """Nearest-colour solve under the RGBL metric: both sides are
    embedded into the 4-D space whose squared Euclidean distance IS
    color_compare(), so this is the same matmul + argmin at 4/3 the
    width. Used by the mixture dither only."""
    return _nearest(_rgbl_embed(vecs), _rgbl_embed(cb), chunk=chunk)


# ---------------------------------------------------------------------
# QUANTIZATION MEMO (SP17 T1 auto-budget). _nearest() is 85% of
# encode_clip's wall time, and its result is a pure function of (frame
# pixels, palette) - NOT of --stream-budget. The auto-budget search runs
# encode_clip several times over the same extracted frame stack at
# different budgets, and the (frame, palette) pairs it presents are
# identical every pass (measured 147/147 reuse across budgets 1.00/0.85/
# 0.70/0.55 on Sintel classic): scene palettes come from the cut
# detector, which reads `chg` - budget-independent. So the search
# memoizes the nearest-colour solve and pays for it once.
#
# EXACTNESS. This is a cache, not an approximation: a hit returns the
# bytes _nearest() would have computed, so a searched encode is
# byte-identical to the same budget encoded straight. The memo is OFF
# (None) outside auto_stream_budget - an explicit --stream-budget runs
# the untouched path, which is what the wire-byte identity check pins.
_QUANT_MEMO = None            # None = disabled; else {key: (idx, dist)}
_QUANT_MEMO_BYTES = 0
QUANT_MEMO_MAX_BYTES = 320 * 1024 * 1024   # stop caching past this;
# a 15 s 320x256 clip (375 frames x ~410 KB/entry) fits inside it, and
# a longer one degrades to plain recomputation rather than to swapping


def _quant_memo_enable():
    global _QUANT_MEMO, _QUANT_MEMO_BYTES
    _QUANT_MEMO, _QUANT_MEMO_BYTES = {}, 0


def _quant_memo_disable():
    global _QUANT_MEMO, _QUANT_MEMO_BYTES
    _QUANT_MEMO, _QUANT_MEMO_BYTES = None, 0


def _quant_memo_solve(v, palf, rgb, pal):
    """_nearest(v, palf, want_dist=True) through the memo when it is
    enabled. Always solves WITH distances so one entry serves both the
    hysteresis (delta) and plain (keyframe) call sites."""
    global _QUANT_MEMO_BYTES
    if _QUANT_MEMO is None:
        idx, dist = _nearest(v, palf, want_dist=True)
        return idx, dist
    import hashlib
    key = (hashlib.blake2b(rgb.tobytes(), digest_size=16).digest(),
           hashlib.blake2b(pal.tobytes(), digest_size=16).digest())
    hit = _QUANT_MEMO.get(key)
    if hit is not None:
        return hit
    idx, dist = _nearest(v, palf, want_dist=True)
    idx = idx.astype(np.uint8)      # palettes are 256 entries - lossless
    entry = (idx, dist)
    cost = idx.nbytes + dist.nbytes
    if _QUANT_MEMO_BYTES + cost <= QUANT_MEMO_MAX_BYTES:
        _QUANT_MEMO[key] = entry
        _QUANT_MEMO_BYTES += cost
    return entry


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
        idx, best_d = _quant_memo_solve(v, palf, rgb, pal)
        pv = prev_idx.reshape(-1).astype(np.int64)
        diff = v - palf[pv]
        prev_d = np.sum(diff * diff, axis=1)
        keep = prev_d <= best_d + hysteresis_eps
        idx = np.where(keep, pv, idx).astype(np.uint8)
    elif _QUANT_MEMO is not None:
        idx = _quant_memo_solve(v, palf, rgb, pal)[0].astype(np.uint8)
    else:
        idx = _nearest(v, palf).astype(np.uint8)
    dec = pal[idx].reshape(H, W, 3)
    return idx.reshape(H, W), dec


# Dither-plan memo: same contract and same store as the quantization
# memo above (enabled only inside auto_stream_budget, exact on hit).
# Keyed on (frame bytes, palette bytes, amplitude, mode) - everything
# the plan is a function of.
# Small ALWAYS-ON plan cache. encode_clip asks for the same (frame,
# palette) plan two or three times per frame - the drift probe, the
# hysteresis re-quantize, and the keyframe-chunk quantize - and a plan
# is by far the most expensive thing in the encoder, so a couple of
# live entries removes most of the repeat work. Exact (a hit returns
# what the solve would have returned), bounded, and independent of the
# auto-budget memo below, which covers the whole-clip replay.
_PLAN_LRU = {}
_PLAN_LRU_MAX = 3


def _norm_phase(phase):
    """Normalize a dither-phase argument to a hashable (px, py) mod-32
    pair; None and (0,0) both mean the un-displaced tile."""
    if not phase:
        return (0, 0)
    return (int(phase[0]) % 32, int(phase[1]) % 32)


def _dither_plan_memo(frame, pal, amp, mode, phase=(0, 0)):
    key = ("plan", hashlib.blake2b(frame.tobytes(), digest_size=16).digest(),
           hashlib.blake2b(pal.tobytes(), digest_size=16).digest(), amp, mode,
           phase)
    if _QUANT_MEMO is not None:
        hit = _QUANT_MEMO.get(key)
        if hit is not None:
            return key, hit
    return key, _PLAN_LRU.get(key)


def dither_plan(frame, pal, amplitude=None, mode=None, phase=None):
    """The dither decision for one (frame, palette): returns
    (idx (H,W) uint8 palette indices, target (H,W,3) uint8), where
    `target` is the colour the dither was AIMING at for that pixel -
    the offset-displaced source in offset mode, the mixture plan's own
    achieved colour in mixture mode. Callers that need hysteresis
    compare against `target`, so both modes share one rule.

    Positionally deterministic in both modes: a pure function of
    (x mod 32, y mod 32, source colour, palette, amplitude, mode, and
    the SP17 T5a motion-lock phase - None/(0,0) is the shipped
    un-displaced tile, byte-identical to the pre-T5a plan)."""
    global _QUANT_MEMO_BYTES
    amp = _dither_amp(amplitude)
    m = _dither_mode(mode)
    ph = _norm_phase(phase)
    key, hit = _dither_plan_memo(frame, pal, amp, m, ph)
    if hit is not None:
        return hit
    if m == DITHER_MODE_OFFSET:
        tgt = (ordered_dither(frame, amp) if ph == (0, 0)
               else ordered_dither(frame, amp, phase=ph))
        idx, _ = quantize_to_palette(tgt, pal)   # plain-RGB nearest
    else:
        idx, tgt = (mixture_planner(pal, amp).plan(frame) if ph == (0, 0)
                    else mixture_planner(pal, amp).plan(frame, phase=ph))
    out = (idx.astype(np.uint8), tgt)
    if _QUANT_MEMO is not None:
        cost = out[0].nbytes + out[1].nbytes
        if _QUANT_MEMO_BYTES + cost <= QUANT_MEMO_MAX_BYTES:
            _QUANT_MEMO[key] = out
            _QUANT_MEMO_BYTES += cost
    if len(_PLAN_LRU) >= _PLAN_LRU_MAX:
        _PLAN_LRU.pop(next(iter(_PLAN_LRU)))
    _PLAN_LRU[key] = out
    return out


def dither_quantize(frame, pal, amplitude=None, mode=None, prev_idx=None,
                    hysteresis_eps=None, phase=None):
    """Dither + quantize (H,W,3) uint8 source to a 256-entry palette:
    the single entry point every encode path uses. Returns (idx (H,W)
    uint8, decoded rgb (H,W,3) uint8).

    prev_idx + hysteresis_eps: index hysteresis (see HYSTERESIS_EPS) -
    a pixel keeps its previous index whenever that index's colour is
    within eps of the dither TARGET, i.e. whenever holding still costs
    almost nothing against what this frame was aiming at. Used only
    against a HELD palette (delta frames).

    phase (SP17 T5a): the motion-locked dither phase - threshold tile
    displaced with the content. None/(0,0) leaves every byte of the
    pipeline exactly as it was.

    In OFFSET mode this is exactly the pre-2026-07-28 call chain
    (ordered_dither -> quantize_to_palette), byte for byte."""
    m = _dither_mode(mode)
    ph = _norm_phase(phase)
    if m == DITHER_MODE_OFFSET:
        # phase (0,0) takes the LEGACY call shape exactly - byte-for-
        # byte the pre-T5a chain, and monkeypatch-compatible with
        # two-argument ordered_dither doubles (the selftest's own
        # negative controls)
        dithered = (ordered_dither(frame, amplitude) if ph == (0, 0)
                    else ordered_dither(frame, amplitude, phase=ph))
        return quantize_to_palette(dithered, pal,
                                    prev_idx=prev_idx,
                                    hysteresis_eps=hysteresis_eps)
    idx, tgt = dither_plan(frame, pal, amplitude, m, phase=ph)
    if prev_idx is not None and hysteresis_eps is not None:
        # the mixture path compares in RGBL throughout, so its deadzone
        # is the RGBL-scaled one (see HYSTERESIS_EPS_RGBL)
        eps = (HYSTERESIS_EPS_RGBL if hysteresis_eps == HYSTERESIS_EPS
               else hysteresis_eps)
        t = tgt.reshape(-1, 3).astype(np.float32)
        palf = pal.astype(np.float32)
        cur = idx.reshape(-1).astype(np.int64)
        pv = prev_idx.reshape(-1).astype(np.int64)
        keep = color_compare(t, palf[pv]) <= color_compare(t, palf[cur]) + eps
        idx = np.where(keep, pv, cur).astype(np.uint8).reshape(idx.shape)
    return idx, pal[idx].reshape(frame.shape)


def psnr(a, b):
    d = a.astype(np.float64) - b.astype(np.float64)
    mse = np.mean(d * d)
    if mse == 0:
        return 99.0
    return 10.0 * np.log10(255.0 * 255.0 / mse)


def _boxmean4(a):
    """4x4 block means of an (H,W[,C]) array (trailing rows/cols beyond
    a multiple of 4 are cropped - every Layer 2 shape is a multiple of 4
    on both axes, so nothing is cropped in practice)."""
    a = np.asarray(a, dtype=np.float64)
    H = a.shape[0] & ~3
    W = a.shape[1] & ~3
    a = a[:H, :W]
    if a.ndim == 2:
        a = a[..., None]
    return a.reshape(H // 4, 4, W // 4, 4, a.shape[-1]).mean(axis=(1, 3))


def psnr_lm(a, b):
    """4x4 LOCAL-MEAN PSNR - the palette-wave metric every SP17 quality
    claim reads. Averaging 4x4 blocks before the PSNR cancels the
    deliberate dither grain (which the per-pixel metric charges as
    error), so this is the space where accumulated STRUCTURAL error is
    visible - the drift/staleness triggers compare here (W4 re-base)."""
    return psnr(_boxmean4(a), _boxmean4(b))


def build_palette_block(pal_256x3):
    """256 entries x 2 bytes, NR $44 order: byte0 = RRRGGGBB (top
    bits), byte1 bit0 = the 9th (extended) blue bit, taken from the
    TRUE source blue bit 5 (palette-collapse fix 2026-07-27: the old
    packing synthesized it with the hardware's 8-bit auto-expand OR
    rule, quietly halving blue to 4 effective levels). For palettes in
    decoder-expanded lattice form (display_palette) this packing
    round-trips exactly through nxv2dec._decode_palette_block."""
    out = bytearray(PAL_BLOCK_SIZE)
    for i in range(256):
        r, g, b = (int(pal_256x3[i, 0]), int(pal_256x3[i, 1]), int(pal_256x3[i, 2]))
        byte0 = (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)
        byte1 = (b >> 5) & 1
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

def scene_palette(orig_frames, start_idx, scene_end_idx, max_samples=6, colors=256,
                  amplitude=None, mode=None):
    n = scene_end_idx - start_idx
    if n <= 1:
        idxs = [start_idx]
    else:
        k = min(max_samples, n)
        idxs = sorted({int(round(start_idx + j * (n - 1) / (k - 1))) for j in range(k)})
    composite = np.concatenate([orig_frames[i] for i in idxs], axis=0)
    # palette-collapse fix: palettes live in DISPLAY lattice space (256
    # distinct displayable colours, decoder-expanded) - see the
    # display_palette block for the mechanism.
    return display_palette(composite, colors=colors, amplitude=amplitude, mode=mode)


# ---------------------------------------------------------------------
# Keyframe span planning + chunk emission (T1 step 3, chunk sizing T1
# step 6). A span is N consecutive frames: KSTART+PAL+COPY(...) on the
# first, COPY(...) continuing on the middle ones, COPY(...)+KFLIP on
# the last. All chunks paint the HIDDEN surface; only KFLIP exposes it.
# ---------------------------------------------------------------------

def _default_abytes_pad(fps):
    """Conservative (largest-layout) padded audio bytes/frame for
    callers that do not thread the encode's real audio layout - the
    layout at this fps (a larger pad shrinks the chunk, which is the
    safe direction for a peak bound)."""
    try:
        from fractions import Fraction
        f = fps if isinstance(fps, Fraction) else Fraction(float(fps)).limit_denominator(1000)
        return audio_layout(f, 2)[3]
    except SystemExit:
        # out-of-contract fps (the audio guard refuses it) - estimate
        real = int(round(RATE_STEREO / float(fps))) * 2
        return ((real + 511) // 512) * 512


def kf_chunk_wire_cap_bytes(fps, width=None, height=None, abytes_pad=None,
                            overhead_b=0, fixed_t=0.0):
    """Max 512-padded PAYLOAD bytes a single frame may carry so its
    whole modeled supply time - decode busy + the per-frame audio copy
    + SD wire for the audio pad and the padded payload, at the supply
    gate's own prices - stays within KF_SPAN_PEAK_UTIL of the frame
    period (the T2/E5 peak pacing bound; see the constant's block).
    overhead_b/fixed_t: payload bytes and decode T the frame spends
    beside the literal body (op headers, PAL block, KSTART/KFLIP)."""
    tc = TMODEL_COEFFS
    af = tc["audio_factor"]
    clock = tc["clock_khz"]
    period_ms = 1000.0 / float(fps)
    wire_eff = SD_WIRE_BYTES_PER_MS * af
    if abytes_pad is None:
        abytes_pad = _default_abytes_pad(fps)
    # a keyframe chunk frame is DENSE by construction (one long copy
    # at the cap), so it reads the dense-end anchor (W4 density re-key)
    r = silicon_r(width if width is not None else 320,
                  height if height is not None else 192, density=1.0)
    # ms per literal byte: chunked-DMA decode (a keyframe chunk is
    # exactly the long DMA COPY the KF row measured) + SD wire
    dma_rate = tc["copy_dma_setup"] / tc["copy_dma_chunk"] + tc["copy_dma_per_b"]
    busy_per_b = dma_rate * r / af / clock
    wire_per_b = 1.0 / wire_eff
    fixed_ms = ((fixed_t + tc["t_frame_fixed"]) * r / af / clock
                + abytes_pad * AUDIO_COPY_T_PER_B / clock
                + abytes_pad * wire_per_b)
    avail_ms = KF_SPAN_PEAK_UTIL * period_ms - fixed_ms
    if avail_ms <= 0:
        return 1
    L = int(avail_ms / (busy_per_b + wire_per_b))
    # refine against the exact padded-payload wire cost until it fits
    while L > 1:
        padded = ((L + overhead_b + 511) // 512) * 512
        t_body = _copy_t(L, tc["fetch_long"])
        ms = (fixed_ms - abytes_pad * wire_per_b
              + (t_body * r / af / clock)
              + (abytes_pad + padded) * wire_per_b)
        if ms <= KF_SPAN_PEAK_UTIL * period_ms:
            break
        L -= 512
    return max(L, 1)


def frame_wire_cap_bytes(fps, abytes_pad=None):
    """Max unpadded PAYLOAD bytes whose 512-padded wire fetch, together
    with the audio pad and the serial audio copy, fits KF_SPAN_PEAK_UTIL
    of the frame period on SD wire time alone - the T2 peak bound in its
    wire-only form, applied to the delta byte cap (delta decode-T is
    separately capped by usable_budget_t)."""
    tc = TMODEL_COEFFS
    wire_eff = SD_WIRE_BYTES_PER_MS * tc["audio_factor"]
    period_ms = 1000.0 / float(fps)
    if abytes_pad is None:
        abytes_pad = _default_abytes_pad(fps)
    avail_ms = (KF_SPAN_PEAK_UTIL * period_ms
                - abytes_pad * AUDIO_COPY_T_PER_B / tc["clock_khz"]
                - abytes_pad / wire_eff)
    if avail_ms <= 0:
        return 1
    padded = int(avail_ms * wire_eff) // 512 * 512
    return max(padded, 1)


def kf_chunk_budget_bytes(fps, first, width=None, height=None,
                          abytes_pad=None):
    """Max keyframe literal bytes this frame's chunk may hold. Two
    bounds, the tighter wins:

    DECODE-T: the modeled decode stays inside the usable per-frame T
    budget (2% reserve), priced at the CHUNKED-DMA copy rate - a
    keyframe chunk is exactly the long mem-to-mem DMA COPY the task-2
    KF row measured, so the old fetch_long (LDI) pricing over-priced it
    ~2.1x and under-sized nothing (flagged in e7b38fd's report,
    deliberately left until this wave).

    WIRE/SUPPLY (T2, charter E5): the frame's whole modeled supply time
    (decode + audio copy + SD wire, the gate's prices) stays within
    KF_SPAN_PEAK_UTIL of the frame period, so a keyframe event can
    never demand more wire than a frame period buys - the peak is now
    budget-independent by DESIGN instead of unbounded by accident.
    abytes_pad: the encode's padded audio bytes/frame (None = the
    conservative stereo layout for this fps).

    Ported from the research prototype's kf_chunk_cap, re-costed for
    the real COPY op overhead (KSTART/PAL dispatch on the first chunk).
    A keyframe chunk is one long COPY straight down the paint order, so
    it crosses every column boundary a gapped surface has - the
    composition factor applies here too."""
    tc = TMODEL_COEFFS
    budget_t = usable_budget_t(fps, width, height) * 0.98 - tc["t_frame_fixed"]
    # the COPY op's own dispatch + the terminal FEND/KFLIP dispatch
    fixed_t = tc["t_op_copy"] + tc["t_op_misc"]
    overhead_b = 4 + 1                       # COPY16 header + FEND/KFLIP
    if first:
        fixed_t += tc["t_palette"] + 2 * tc["t_op_misc"]   # KSTART + PAL
        overhead_b += 1 + 1 + PAL_BLOCK_SIZE
    budget_t -= fixed_t
    # decode-T bound at the chunked-DMA rate, refined with the exact
    # kernel-select model (sub-chunk remainders re-price as LDI)
    dma_rate = tc["copy_dma_setup"] / tc["copy_dma_chunk"] + tc["copy_dma_per_b"]
    L_t = int(max(0.0, budget_t) / dma_rate)
    while L_t > 1 and _copy_t(L_t, tc["fetch_long"]) > budget_t:
        L_t -= 256
    L_w = kf_chunk_wire_cap_bytes(fps, width, height, abytes_pad,
                                  overhead_b=overhead_b, fixed_t=fixed_t)
    return max(min(L_t, L_w), 1)


def plan_kf_chunks(raw_len, fps, width=None, height=None, abytes_pad=None):
    """Returns a list of (start, length, first) chunks covering
    raw_len bytes, each sized to kf_chunk_budget_bytes."""
    chunks = []
    remaining, pos, first = raw_len, 0, True
    while remaining:
        c = min(remaining, kf_chunk_budget_bytes(fps, first, width, height,
                                                 abytes_pad))
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
        t += TMODEL_COEFFS["t_op_misc"] + TMODEL_COEFFS["t_palette"]
    b += 1   # terminal op byte (FEND/KFLIP)
    t += TMODEL_COEFFS["t_frame_fixed"] + TMODEL_COEFFS["t_op_misc"]
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
    stream_pump_ms: float = 0.0
    stream_demand_kbs: float = 0.0
    # Delta-starvation diagnostics (report-only, see starvation_stats).
    # Streaming encodes only - the direct-serve preset is all-literal,
    # it has no deltas to starve, and leaves these at their zero
    # defaults so both modes carry the same key set.
    delta_frames: int = 0
    budget_bound_frames: int = 0
    bound_fraction: float = 0.0
    burst_window_frames: int = 0        # sliding window length, frames
    burst_peak_fraction: float = 0.0    # peak window's bound fraction
    burst_peak_frame: int = None        # that window's first frame index
    delta_psnr_p10: float = 0.0
    starvation_warned: bool = False     # RETIRED verdict, NOT a quality
                                        # judgement - see starvation_warns()
    # SP17 T1 auto-budget: the budget this encode actually ran at, and
    # how it was arrived at. stream_budget is authoritative whether it
    # came from the author or from the search; auto_budget_probes is 0
    # for an explicit budget (no search ran).
    stream_budget: float = 1.0
    auto_budget: bool = False           # True = derived, not author-set
    auto_budget_target: float = 0.0     # the target the search aimed at
    auto_budget_probes: int = 0         # encode passes the search spent


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
# round(rate/fps) samples-per-frame rule) + the NXV PLAYER BOUND
# (SP17 T10, circular feed): the player's audio feed is ONE circular
# ring in the session's audio bank (NXV_AUD_RING, src/nextdaad.inc) -
# the ISR's read pointer free-runs around it and the frame loop writes
# behind it, so capacity per frame is the WHOLE ring minus a small
# writer guard, not one fixed half. The open path rejects any header
# declaring more than AUD_FRAME_MAX real audio bytes/frame
# ("VID FMT?"). The wire format itself allows more - this is a player
# capability bound, enforced HERE so a doomed encode fails at encode
# time with a named remedy instead of building a file that refuses to
# play.
#
# Derivation of the bound and the fps floors:
#   AUD_RING      = 8192  - the WHOLE audio bank (2026-08-02). It sat
#                           at 2560 (what the pre-T10 double buffer
#                           had occupied) while the bank had always
#                           been an exclusive 8 KB pool page, so 5632
#                           bytes were allocated and idle. See the
#                           LOW-FPS PACE CONTENTION block: the
#                           room-limited feed it prices is exactly
#                           what those bytes now buy back.
#   AUD_GUARD     = 16    - the writer keeps 16 bytes clear of the
#                           read pointer. REQUIRED minimum is one
#                           stereo pair (2 bytes): the player ISR's
#                           (ix+0)/(ix+1) pair fetch is not atomic
#                           against the writer's byte stores. The
#                           room computation's read-pointer snapshot
#                           only goes stale in the SAFE direction
#                           (the reader advances, so true room only
#                           grows), so 16 is a deliberate 8x safety
#                           margin, stated conservative.
#   AUD_FRAME_MAX = 3072  - NOT ring-guard (which is 8176). The bound
#                           stopped being what the RING limits and
#                           became what the player's streaming and
#                           direct gates admit: both compute the
#                           per-frame block need as an 8-bit
#                           `cap + apad + 1`, and the streaming
#                           ring-fit test adds `apad + 2` on top of
#                           that, so with the header's own cap at its
#                           documented maximum (NXV2_STRM_CAP_MAX =
#                           240) they stay inside a byte if and only
#                           if apad <= 6 blocks - i.e. iff the PADDED
#                           audio section is <= 3072 B. Those adds
#                           carry "<= 247: no carry possible" in
#                           video.asm and have exactly zero headroom,
#                           so the declarable bound is pinned to them
#                           rather than widened: at 8176 a legal
#                           header would give apad 16 and wrap the
#                           byte (240 + 16 + 1 = 257).
# CONTENTION-FREE BY CONSTRUCTION: 2 x 3072 = 6144 <= 8176, so every
# legal file's next-frame feed completes in the player's single
# post-present pump with 2032 bytes to spare - see pace_trickle_frac,
# which is now identically zero for anything that can be encoded.
# Floor (min_fps_for, same formula as before): samples <= smax
# requires rate/fps < smax + 0.5, i.e. fps > rate/(smax + 0.5) with
# smax = AUD_FRAME_MAX // 2:
#   15625 / 1536.5 = 10.1692... -> fps >= 10.17
# (pre-T10: 1280 -> 24.40; at the 2560-byte ring: 2544 -> 12.28.)
# 320x256@12.5 (2500 B/frame) and native 24 fps (1302 B/frame) stay
# legal.
# LEGALITY ONLY changes: any previously legal fps lays out
# byte-identically (same rate/samples/real/padded - the bound is a
# comparison, not an operand of the layout arithmetic), so the AUDIO
# PAYLOAD of every existing encode is bit-for-bit unaffected.
# ---------------------------------------------------------------------

AUD_RING = 8192       # matches NXV_AUD_RING - the circular feed ring
AUD_GUARD = 16        # matches NXV_AUD_GUARD - writer guard bytes
AUD_FRAME_MAX = 3072  # matches NXV_AUD_FRAME_MAX - pinned by the
                      # player's 8-bit block arithmetic, NOT by the
                      # ring (see the derivation above)
assert 2 * AUD_FRAME_MAX <= AUD_RING - AUD_GUARD


def min_fps_for():
    """Lowest fps whose round(RATE_STEREO/fps)*2 fits AUD_FRAME_MAX:
    samples <= smax requires rate/fps < smax + 0.5, i.e.
    fps > rate/(smax + 0.5), with smax = AUD_FRAME_MAX // 2. ~10.17
    (T10 circular feed at the whole-bank ring; the 2560-byte ring gave
    12.28 and the pre-T10 half-buffers 24.40). Took a `channels`
    argument until 2026-08-03 - mono's floor was 7.60."""
    return RATE_STEREO / (AUD_FRAME_MAX // 2 + 0.5)


def audio_layout(fps, channels=2):
    """Audio layout for one frame: (rate, samples, real, padded).

    channels is retained because the layout arithmetic genuinely uses
    it (real = samples * channels) and because it is a frozen header
    field - but 2 is the only value the format carries since mono was
    withdrawn, and anything else is refused here as it is at open."""
    from fractions import Fraction
    if channels != 2:
        raise ValueError(f"channels must be 2, got {channels}")
    rate = RATE_STEREO
    exact = Fraction(rate) / Fraction(fps).limit_denominator(1000)
    samples = int(exact + Fraction(1, 2))
    real = samples * channels
    if real > AUD_FRAME_MAX:
        import math as _math
        raise SystemExit(
            f"error: {real} audio bytes/frame at {float(fps):g} "
            f"fps exceeds the NXV player's per-frame audio bound "
            f"of {AUD_FRAME_MAX} bytes (the T10 circular feed's "
            f"per-frame section bound - a bigger frame is rejected at "
            f"open with VID FMT?). The lowest playable rate is "
            f"fps >= {_math.ceil(min_fps_for() * 100) / 100:.2f} "
            f"(the floor itself fits - 3b re-review wording fix); "
            f"raise --fps.")
    padded = ((real + 511) // 512) * 512
    return rate, samples, real, padded


SILENCE_U8 = 128


# ---------------------------------------------------------------------
# Encoder pipeline (T1 steps 4-7 wired together) + top-level encode()
# entry point (T1 step 8).
# ---------------------------------------------------------------------

def _extract_source(src_path, width, height, fps, start, duration, ffmpeg, dither,
                    dither_mode=None, retime=None, prefilter=None):
    """Extracts (orig (N,H,W,3) uint8 RGB frames, po_ceil, chg,
    audio_bytes, channels, rate) from a source file, reusing videnc.py's
    own ffmpeg plumbing (probe/crop/extract) - the canonical location
    for that logic per the kit's own docstring. Imported lazily to
    avoid a module-load cycle (videnc.py imports nxv2enc at top level).
    dither: the dither amplitude (0.0-1.0, None/legacy-bool ->
    DITHER_AMP_DEFAULT); dither_mode: "mixture" or "offset" - po_ceil
    must be measured at the encode's own amplitude AND mode or the
    drift triggers compare across spaces. retime: how to resample the
    source in TIME when its own rate differs from fps (videnc.
    RETIME_MODES, None = the blended default) - the source rate comes
    off the SAME banner probe as the dimensions, so detection is free."""
    import videnc as _videnc

    dither_amp = _dither_amp(dither)
    dither_mode = _dither_mode(dither_mode)

    input_path = Path(src_path)
    if not input_path.exists():
        raise SystemExit(f"error: input not found: {input_path}")
    ffmpeg_path = Path(ffmpeg) if ffmpeg else _videnc.DEFAULT_FFMPEG
    if not ffmpeg_path.exists():
        raise SystemExit(f"error: ffmpeg not found at {ffmpeg_path}")

    probe_stderr = _videnc._probe_stderr(ffmpeg_path, input_path)
    src_w, src_h = _videnc.probe_dimensions(ffmpeg_path, input_path, stderr=probe_stderr)
    has_audio = _videnc.probe_has_audio(ffmpeg_path, input_path, stderr=probe_stderr)
    crop = _videnc.compute_center_crop(src_w, src_h, width, height)
    from fractions import Fraction
    fps_frac = fps if isinstance(fps, Fraction) else Fraction(fps).limit_denominator(1000)
    channels = 2                 # the only channel count v2 carries; a
                                 # mono SOURCE is upmixed by ffmpeg's
                                 # -ac 2 in videnc.extract_audio
    # Lay out the audio FIRST: the player-bound guard (real
    # bytes/frame <= AUD_FRAME_MAX) rejects a doomed fps
    # before the slow ffmpeg extraction, not after.
    rate, samples_per_frame, abytes_real, abytes_pad = audio_layout(fps_frac, channels)
    # SP17 T0: resample in TIME to the target rate when the source is not
    # already at it. Free to detect (same banner as the dimensions above),
    # and a source already at the target takes no filter at all - so a 25p
    # source encodes to exactly the bytes it did before retiming existed.
    src_fps = _videnc.probe_source_fps(ffmpeg_path, input_path, stderr=probe_stderr)
    stages, retime_line = _videnc.retime_plan(src_fps, fps_frac, width, height,
                                               mode=retime)
    print(retime_line)
    # W4 --prefilter (opt-in, default OFF = filter chain untouched):
    # light temporal denoise at SOURCE resolution, before any scaling,
    # so grain is removed while its full-resolution structure is still
    # separable from content. A measured option for the sitting, not a
    # default (see videnc --prefilter's own help text).
    if prefilter:
        stages = [prefilter] + list(stages)
        print(f"  prefilter: {prefilter} (before scale/retime)")
    video_bytes, nframes = _videnc.extract_video(
        ffmpeg_path, input_path, start, duration, width, height, fps_frac,
        crop=crop, stages=stages)
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/--start/--duration")
    needed = nframes * abytes_real
    if not has_audio:
        # Source has no audio stream at all (both SP15 research demo
        # clips, Sintel_1080_10s_30MB.mp4 and Big_Buck_Bunny_1080_10s_
        # 30MB.mp4, are video-only) - skip the doomed extraction (and
        # the raw ffmpeg stderr it would print on the way down) and go
        # straight to silence.
        print("note: source has no audio stream - encoding with silence",
              file=sys.stderr)
        audio_bytes = b""
    else:
        try:
            audio_bytes = _videnc.extract_audio(ffmpeg_path, input_path, start, duration,
                                                 channels, rate)
        except SystemExit:
            # Extraction failed even though a stream was reported -
            # genuinely anomalous; let the raw ffmpeg stderr through
            # and still fall back to silence rather than failing the
            # encode outright.
            audio_bytes = b""
    if len(audio_bytes) < needed:
        audio_bytes = audio_bytes + bytes([SILENCE_U8]) * (needed - len(audio_bytes))
    elif len(audio_bytes) > needed:
        audio_bytes = audio_bytes[:needed]

    orig = np.frombuffer(video_bytes, dtype=np.uint8).reshape(nframes, height, width, 3)
    # po_ceil: per-frame quality ceiling in DISPLAY space (palette-
    # collapse fix - the old 24-bit ADAPTIVE reference over-stated the
    # ceiling by the whole lattice truncation, so drift never saw it;
    # the legacy --dither/FS reference flag is subsumed: ordered
    # dithering into the lattice is now integral to the pipeline, and
    # --dither instead sets its amplitude - see _dither_amp).
    po_ceil = np.empty(nframes)
    po_ceil_lm = np.empty(nframes)   # 4x4 local-mean ceiling (W4 trigger
    chg = np.zeros(nframes)           # re-base) - same decode, second space
    for i in range(nframes):
        po_ceil[i], po_ceil_lm[i] = display_ceilings(
            orig[i], amplitude=dither_amp, mode=dither_mode)
        if i:
            d = np.abs(orig[i].astype(np.int16) - orig[i - 1].astype(np.int16)).max(axis=2)
            chg[i] = float((d > 10).mean())
    return dict(orig=orig, po_ceil=po_ceil, po_ceil_lm=po_ceil_lm,
                chg=chg, audio_bytes=audio_bytes, channels=channels, rate=rate,
                abytes_real=abytes_real, abytes_pad=abytes_pad, nframes=nframes)


# ---------------------------------------------------------------------
# Motion-locked dither phase helper (SP17 T5a residue, KEPT). The
# offset-copy coding it was built for was withdrawn on 2026-08-02,
# but the phase-locked dither identity it pins is a property of
# ordered_dither/dither_plan and stays selftest-pinned: phase (0,0)
# is byte-identical to the shipped dither, which is what makes the
# default path provably unmoved.
# ---------------------------------------------------------------------

def _shift_clamp2d(a, dy, dx):
    """Edge-clamped integer shift of an (H,W[,C]) array: content moves
    by (+dy, +dx). The Wave 0 shift_clamp, ported."""
    if dy == 0 and dx == 0:
        return a
    h, w = a.shape[:2]
    ys = np.clip(np.arange(h) - dy, 0, h - 1)
    xs = np.clip(np.arange(w) - dx, 0, w - 1)
    return a[ys][:, xs]


def encode_clip(orig, chg, po_ceil, width, height, fps, cap_bytes_frac=0.65,
                budget_scale=1.0, merge_gaps=True, hysteresis=True,
                staleness_refresh=True, return_surfaces=False,
                dither_amp=None, dither_mode=None, tile_slack=None,
                po_ceil_lm=None, abytes_pad=None,
                kf_cadence_s=None):
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
    dither_amp = _dither_amp(dither_amp)   # caller's po_ceil must be
    dither_mode = _dither_mode(dither_mode)   # measured at this same
    # amplitude AND mode (encode() threads one pair to both
    # _extract_source and here)
    # W4 trigger re-base: the drift/staleness comparisons live in 4x4
    # local-mean space. A caller that did not thread po_ceil_lm (tests,
    # standalone tooling) gets it derived here from the same per-frame
    # fresh-palette decode _extract_source uses.
    if po_ceil_lm is None:
        po_ceil_lm = np.empty(N)
        for _i in range(N):
            po_ceil_lm[_i] = display_ceilings(
                orig[_i], amplitude=dither_amp, mode=dither_mode)[1]
    # budget_scale (--stream-budget) scales BOTH delta caps - the
    # streaming-supply operating-point lever. Keyframe span chunks are
    # deliberately NOT budget-scaled (shrinking them with the budget
    # just multiplies span length on encodes that never had a wire
    # problem) - instead every chunk frame is bounded by the T2 peak
    # pacing rule (KF_SPAN_PEAK_UTIL), which is budget-independent.
    usable = usable_budget_t(fps, width, height) * budget_scale
    refract = max(1, int(round(fps / 2)))
    cap_bytes = int(cap_bytes_frac * budget_scale * raw)
    # The T2 peak WIRE bound applies to DELTA frames as well: a byte cap
    # above the per-frame wire ceiling could emit a delta frame that no
    # budget rung can fetch inside the period (reachable at budget ~1.0
    # on the 320x256 shape, where 0.65 x raw = 53 KB of payload against
    # a ~41 KB wire period). Delta decode-T is already capped by
    # `usable`, so only the wire term is bounded here - the kf chunks
    # above carry the full supply bound instead because their decode is
    # not otherwise capped per frame.
    cap_bytes = min(cap_bytes, frame_wire_cap_bytes(fps, abytes_pad))
    # keyframe cadence (W4 item 2): frames per window; 0/None disables
    kf_cadence_s = KF_CADENCE_S_DEFAULT if kf_cadence_s is None else float(kf_cadence_s)
    cadence_frames = int(round(kf_cadence_s * fps)) if kf_cadence_s > 0 else 0
    hyst_eps = HYSTERESIS_EPS if hysteresis else None
    # Region-coherent tile size: a band of TILE_BAND rows (mode-0) / columns
    # (mode-1) is contiguous in paint order, so shortfall lags coherent
    # horizontal/vertical strips. That band is the COARSEST rung of the
    # adaptive ladder (SP17) - encode_delta picks a finer granularity per
    # bound frame whenever a finer one is free in bytes AND in supply, and
    # actually improves the picture (LADDER RE-CUT).
    tile_px = default_tile_px(raw, width=width, height=height, column_major=column_major)
    tile_ladder = tile_ladder_for(tile_px)
    # The ladder is priced with the SUPPLY GATE's own prices, so a finer
    # rung can never buy granularity with the decode time the auto-budget
    # search would otherwise have spent on wire bytes.
    supply_px = supply_price(width, height)
    # tile_slack is the ALREADY-RESOLVED relative supply allowance (the
    # opt-in --tile-slack knob, converted out of headroom units by
    # tile_slack_rel() at the one place that knows the budget target -
    # encode()). None/0.0 is the default and is the supply-neutral rule.
    tile_slack = TILE_SUPPLY_SLACK if tile_slack is None else float(tile_slack)

    scene_cuts = detect_scene_cuts(chg)
    # W5 rolling refresh (the cadence path - see the ROLLING REFRESH
    # block): per-frame forced-clean quota sized so the slice's
    # worst-case literal bytes claim at most KF_ROLL_SHARE of the
    # frame's own delta byte cap - the roll is priced INSIDE the
    # existing caps, so a lower budget stretches the window (longer
    # nominal N), never the rate.
    roll_quota = max(1, int(KF_ROLL_SHARE * cap_bytes))
    roll_nominal = -(-raw // roll_quota)   # ceil(raw / quota) frames

    # Palette-collapse fix: all quantization TARGETS are DITHERED
    # (position-deterministic - quiet content dithers identically every
    # frame, so this feeds no churn to the delta coder); PSNR/staleness
    # are still measured against the true source. Dithered PER-FRAME
    # inside the loop below, through dither_quantize (review minor,
    # 2026-07-27: a precomputed (N,H,W,3) stack doubled encode_clip's
    # peak RAM against the already-resident `orig` stack). SP17
    # Yliluoma wave: the mixture plan depends on the PALETTE as well as
    # the frame, so the drift probe (held palette), the emission
    # (held palette) and the keyframe chunk (fresh palette) each ask
    # dither_quantize for their own - _PLAN_LRU keeps the repeats free.

    payloads = []
    kf_span_ranges = []
    per_frame = {"bytes": [], "psnr": [], "mode": [], "binding": [], "drift": [],
                 "drift_lm": [], "deficit_lm": [],   # W4 lm trigger diagnostics
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
    # W5 rolling-refresh state (the cadence path)
    last_roll_end = -10_000
    roll_pending = None   # bool[raw]: positions still owed a forced clean
    roll_start_frame = None
    roll_events = 0
    roll_frames = 0
    roll_windows = []     # completed (start_frame, end_frame) windows
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
        drift_lm_stats = None    # W4: lm-space trigger diagnostics for
        deficit_lm_stats = None  # plain delta frames
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
            fresh_idx, target_dec = dither_quantize(orig[i], held_pal,
                                                    dither_amp, dither_mode)
            drift = po_ceil[i] - psnr(orig[i], target_dec)
            drift_for_stats = drift
            # W4 re-base: held-palette fit loss in 4x4 local-mean space
            # - the metric the dither grain cannot mask (the per-pixel
            # drift above stays for the dissolve gate and diagnostics).
            drift_lm = po_ceil_lm[i] - psnr_lm(orig[i], target_dec)
            drift_lm_stats = drift_lm
            in_refract = (i - last_kf_end) <= refract
            ct = CUT_T_REFRACT if in_refract else CUT_T
            dt = DRIFT_LM_T_REFRACT if in_refract else DRIFT_LM_T
            # Staleness of the ACTUAL decoded screen (held_pal[prev_flat]) vs
            # this source - the accumulated decoded error the drift trigger is
            # blind to (it only sees palette FIT). dec_now = current screen;
            # decoded_deficit = how far below the frame's own ceiling it sits;
            # wrong_frac = the AREA that is wrong (whole-frame vs local).
            # wrong_frac compares the screen against the ACHIEVABLE target
            # (both lattice-decoded) rather than the raw source - against the
            # source, deliberate dither displacement would count as wrong and
            # saturate the area gate (palette-collapse fix).
            dec_now = unflatten_frame(held_pal[prev_flat], height, width, column_major)
            decoded_deficit = po_ceil[i] - psnr(orig[i], dec_now)
            # W4 re-base: the ACCUMULATED decoded error in local-mean
            # space. The per-pixel deficit above is structurally pinned
            # at/below zero by the dither displacement (measured -1.21
            # dB mean on the owner's pan) and could never cross a +3 dB
            # bar; the lm deficit is the error that actually grows.
            deficit_lm = po_ceil_lm[i] - psnr_lm(orig[i], dec_now)
            deficit_lm_stats = deficit_lm
            d_now = np.abs(target_dec.astype(np.int16) - dec_now.astype(np.int16)).max(axis=2)
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
                  and deficit_lm > STALE_LM_DB and wrong_frac > WHOLE_FRAME_FRAC):
                # WHOLE-FRAME accumulated error -> atomic keyframe, not the
                # incremental in-place repair (which would seam). Local
                # staleness (small wrong_frac) is left to the aging + tile
                # schedule to refresh coherently in the delta path.
                start_kf, trigger = True, "staleness"
                staleness_events += 1
            elif drift_lm > dt:
                start_kf, trigger = True, "drift"
            elif (cadence_frames and roll_pending is None
                  and (i - max(last_kf_end, last_roll_end)) >= cadence_frames
                  and roll_nominal <= N - i):
                # W5 cadence ROLLING REFRESH (owner-ruled 2026-08-02):
                # no natural keyframe inside the window -> forced-clean
                # coverage spread across ordinary delta frames instead
                # of the W4 keyframe span, whose paced repaint HELD the
                # visible picture (the mid-clip pause owner silicon
                # saw). Trigger-forced keyframes above stay real
                # keyframes. Suppressed when the remaining clip cannot
                # hold a nominal window (the span's own tail guard).
                roll_pending = np.ones(raw, dtype=bool)
                roll_start_frame = i
                roll_events += 1

        if start_kf:
            scene_end = next((c for c in scene_cuts if c > i), N)
            kf_pal = scene_palette(orig, i, scene_end, amplitude=dither_amp,
                                   mode=dither_mode)
            planned = plan_kf_chunks(raw, fps, width, height, abytes_pad)
            # Cut lookahead (T1 step 4): if this span would take >1
            # chunk AND the very next frame independently looks like a
            # hard cut too, defer starting the span to i+1 instead -
            # avoids composing a mixed-scene frame on the hidden
            # surface (research-realfootage-results.md HAZARD FOUND).
            if len(planned) > 1 and prev_flat is not None and _is_cut_at(chg, i + 1, CUT_T):
                prev_idx = unflatten_frame(prev_flat, height, width, column_major)
                target_idx, target_dec = dither_quantize(
                    orig[i], held_pal, dither_amp, dither_mode,
                    prev_idx=prev_idx, hysteresis_eps=hyst_eps)
                tflat = flatten_frame(target_idx, column_major)
                prev_dec_flat = held_pal[prev_flat].astype(np.float32)
                targ_dec_flat = held_pal[tflat].astype(np.float32)
                err2 = np.sum((targ_dec_flat - prev_dec_flat) ** 2, axis=1)
                gcls, gstarts, glens, b, t, mode, binding, payload = encode_delta(
                    tflat, err2, cap_bytes, usable,
                    surface_flat=prev_flat, merge_gaps=merge_gaps,
                    tile_px=tile_px, tile_ladder=tile_ladder,
                    supply_px=supply_px, supply_slack=tile_slack)
                prev_flat = np.where(_mask_from_segments(gcls, gstarts, glens, raw), tflat, prev_flat)
                dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
                payloads.append(payload)
                per_frame["bytes"].append(b)
                per_frame["psnr"].append(psnr(orig[i], dec_img))
                per_frame["mode"].append(mode + ":deferred_kf")
                per_frame["binding"].append(binding)
                per_frame["drift"].append(float("nan"))
                per_frame["drift_lm"].append(float("nan"))
                per_frame["deficit_lm"].append(float("nan"))
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
            if roll_pending is not None:
                # a real keyframe repaints the whole surface - the
                # in-flight roll is moot and the cadence clock restarts
                # from this span's KFLIP
                roll_pending = None
            if prev_flat is None:
                prev_flat = np.zeros(raw, dtype=np.uint8)
                held_pal = kf_pal
            staging = prev_flat.copy()

        if kf_chunks:
            s, L, first = kf_chunks.pop(0)
            tidx, _ = dither_quantize(orig[i], kf_pal, dither_amp, dither_mode)
            tflat = flatten_frame(tidx, column_major)
            staging[s:s + L] = tflat[s:s + L]
            is_last = not kf_chunks
            payload = emit_kf_chunk_payload(tflat, s, L, first, is_last, kf_pal=kf_pal)
            payloads.append(payload)
            per_frame["bytes"].append(len(payload))   # actual, not kf_chunk_cost's modeled estimate
            per_frame["binding"].append("kf")
            per_frame["drift"].append(float("nan"))
            per_frame["drift_lm"].append(float("nan"))
            per_frame["deficit_lm"].append(float("nan"))
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
            target_idx, target_dec = dither_quantize(
                orig[i], held_pal, dither_amp, dither_mode,
                prev_idx=prev_idx, hysteresis_eps=hyst_eps)
            tflat = flatten_frame(target_idx, column_major)

            def _schedule(tf, forced):
                """err2 + the band schedule for one candidate target.
                `forced` (or None) are roll positions boosted into the
                mask. Called ONCE on a plain frame - the arithmetic and
                its order are exactly what shipped - and a second time
                only when the roll actually engages."""
                pdec = held_pal[prev_flat].astype(np.float32)
                tdec = held_pal[tf].astype(np.float32)
                e2 = np.sum((tdec - pdec) ** 2, axis=1)
                # err2 IS the decoded-surface-vs-target error, so importance
                # already tracks accumulated wrongness; the death spiral is that
                # a pixel persistently below the coarsest threshold never enters
                # the mask.
                # (2) AGING: boost a wrong pixel's err2 by its age so persistent
                # small errors eventually cross the threshold / win the fallback.
                # (3) PHASE-STAGGER: force a rotating 1/K slice of the wrong
                # pixels over the coarsest mask floor so worst-case staleness
                # ~K frames.
                if staleness_refresh:
                    ee = e2 * (1.0 + AGE_GAIN * age)
                    bi = i % PHASE_REFRESH_K
                    b0 = bi * raw // PHASE_REFRESH_K
                    b1 = (bi + 1) * raw // PHASE_REFRESH_K
                    band = np.zeros(raw, dtype=bool)
                    band[b0:b1] = True
                    force = band & (e2 > STALE_ERR2_FLOOR)
                    ee = np.where(force, np.maximum(ee, PHASE_FLOOR), ee)
                else:
                    ee = e2
                if forced is not None:
                    # roll slice positions that still differ from their
                    # fresh target must enter the mask this frame -
                    # already-clean positions (err2 0) cost nothing
                    rmask = np.zeros(raw, dtype=bool)
                    rmask[forced] = True
                    ee = np.where(rmask & (e2 > 0.0),
                                  np.maximum(ee, PHASE_FLOOR), ee)
                return e2, encode_delta(
                    tf, ee, cap_bytes, usable,
                    surface_flat=prev_flat, merge_gaps=merge_gaps,
                    tile_px=tile_px, tile_ladder=tile_ladder,
                    supply_px=supply_px, supply_slack=tile_slack)

            err2, sched = _schedule(tflat, None)
            roll_idx = roll_clean = None
            if roll_pending is not None:
                # GUARD (a) STRICTLY OPPORTUNISTIC (ROLLING REFRESH
                # block): the roll gets only the byte budget the motion
                # schedule above left unspent. On a saturated frame that
                # is nothing, the motion-only schedule stands byte for
                # byte, and the pending positions wait for slack.
                free_bytes = cap_bytes - int(sched[3])
                quota_i = min(roll_quota, max(0, free_bytes))
                if quota_i:
                    # force-clean the next paint-order slice of pending
                    # positions to the FRESH non-sticky quantize under
                    # the HELD palette (fresh_idx - the drift probe's own
                    # decode, so this costs no extra quantize). The
                    # substitution makes the slice's whole residual
                    # (paint drift AND hysteresis stickiness) visible to
                    # err2; the PHASE_FLOOR boost puts it in the mask;
                    # the ordinary caps and band scheduler then price it
                    # like any other delta traffic.
                    roll_idx = np.flatnonzero(roll_pending)[:quota_i]
                    fresh_flat = flatten_frame(fresh_idx, column_major)
                    roll_clean = prev_flat[roll_idx] == fresh_flat[roll_idx]
                    tflat = tflat.copy()
                    tflat[roll_idx] = fresh_flat[roll_idx]
                    err2, sched = _schedule(tflat, roll_idx)
                    roll_frames += 1
            gcls, gstarts, glens, b, t, mode, binding, payload = sched

            new_flat = _apply_segments(prev_flat, tflat, gcls, gstarts, glens)
            prev_flat = new_flat
            updated = None
            if staleness_refresh:
                updated = _mask_from_segments(gcls, gstarts, glens, raw)
                wrong = err2 > STALE_ERR2_FLOOR
                age = np.where(updated, 0.0, np.where(wrong, age + 1.0, 0.0))
            if roll_idx is not None:
                # GUARD (b) DISCHARGE ON "WAS UPDATED": a forced position
                # retires when this frame PAINTED it (whatever value it
                # landed on) or when it already held its fresh target
                # when the slice was cut. The rest CARRY OVER -
                # contention lengthens the window, never the rate - and
                # nothing can strand, so the cadence always re-arms.
                if updated is None:
                    updated = _mask_from_segments(gcls, gstarts, glens, raw)
                roll_pending[roll_idx[updated[roll_idx] | roll_clean]] = False
                if not roll_pending.any():
                    roll_pending = None
                    roll_windows.append((roll_start_frame, i))
                    last_roll_end = i
            payloads.append(payload)
            per_frame["bytes"].append(b)
            per_frame["mode"].append(
                mode + (":roll" if roll_idx is not None else ""))
            per_frame["binding"].append(binding)
            per_frame["drift"].append(drift_for_stats if drift_for_stats is not None else float("nan"))
            per_frame["drift_lm"].append(drift_lm_stats if drift_lm_stats is not None else float("nan"))
            per_frame["deficit_lm"].append(deficit_lm_stats if deficit_lm_stats is not None else float("nan"))
            per_frame["t"].append(t)
            dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
            decoded.append(dec_img)
            if return_surfaces:
                surfaces.append(unflatten_frame(prev_flat, height, width, column_major).copy())
            per_frame["psnr"].append(psnr(orig[i], dec_img))

    starve = starvation_stats(per_frame, fps)
    return dict(payloads=payloads, kf_span_ranges=kf_span_ranges, decoded=decoded,
                per_frame=per_frame, scene_cuts=scene_cuts, kf_events=kf_events,
                staleness_events=staleness_events, kf_triggers=kf_triggers,
                kf_roll_events=roll_events, kf_roll_frames=roll_frames,
                kf_roll_windows=roll_windows,
                kf_roll_pending=(int(roll_pending.sum())
                                 if roll_pending is not None else 0),
                kf_roll_nominal_frames=roll_nominal,
                surfaces=surfaces, starvation=starve,
                held_pal_final=held_pal, usable_budget_ms=usable / TMODEL_COEFFS["clock_khz"])


def starvation_stats(per_frame, fps=25.0):
    """Delta-starvation instrumentation for one streaming encode (see
    the DELTA-STARVATION DIAGNOSTICS block above). Pure measurement over
    encode_clip's own per-frame records - it changes no wire byte, and
    it carries no verdict: the warning these stats once fed is RETIRED
    (the bound-fraction axis is refuted; see that block).

    fps is the clip's frame rate, used ONLY to size the burst window in
    frames so the window means a fixed DURATION (STARVE_BURST_WINDOW_S).

    Returns dict:
      frames              emitted frames
      delta_frames        frames outside a keyframe span
      budget_bound        frames whose deltas did not fit the per-frame
                          caps, so encode_delta fell back to the region
                          (tile-band) schedule - binding == "budget"
      bound_fraction      budget_bound / frames (0.0 for an empty encode)
      burst_window_frames sliding-window length in frames (0 if empty)
      burst_peak_fraction worst bound fraction over any window (0.0 if
                          empty) - the CONCENTRATED-starvation measure
      burst_peak_frame    first frame index of that worst window (None
                          if empty)
      delta_psnr_p10      10th-percentile PSNR over delta frames

    Definitions match the 2026-07-28 007 diagnosis measurements, so
    reported numbers stay comparable with the recorded points:
      - bound_fraction's denominator is ALL emitted frames (not just
        delta frames) - keyframe-span frames cannot be budget-bound, so
        including them prices a starved clip against its whole length.
      - the burst window uses the same denominator convention (every
        emitted frame in the window), for the same reason: a run of
        keyframe-span frames genuinely is not a run of banded ones.
      - delta_psnr_p10 excludes keyframe-span frames (mode "kf*"), which
        carry the format-intrinsic dips: the startup repaint, the
        one-frame stale hold before a cut's KFLIP, and the KFLIP frame
        itself at a hard cut. Cut-adjacent DEFERRED-keyframe frames
        (mode "...:deferred_kf") are ordinary delta frames and stay in,
        exactly as the diagnosis measured them.

    Window sizing: round(STARVE_BURST_WINDOW_S * fps), floored at 2
    frames (a 1-frame window would report a boolean, not a burst) and
    clamped to the clip length - a clip shorter than one window gets a
    single window over the whole clip, so its burst_peak_fraction equals
    its bound_fraction. Peak is taken over every window start,
    running-sum, O(n).
    """
    modes = per_frame["mode"]
    n = len(modes)
    delta_mask = [not m.startswith("kf") for m in modes]
    bound_flags = [1 if bd == "budget" else 0 for bd in per_frame["binding"]]
    bound = sum(bound_flags)
    dpsnr = [p for p, d in zip(per_frame["psnr"], delta_mask) if d]

    win = 0
    peak_frac = 0.0
    peak_at = None
    if n:
        win = min(n, max(2, int(round(STARVE_BURST_WINDOW_S * float(fps)))))
        run = sum(bound_flags[:win])
        peak_run, peak_at = run, 0
        for s in range(1, n - win + 1):
            run += bound_flags[s + win - 1] - bound_flags[s - 1]
            if run > peak_run:
                peak_run, peak_at = run, s
        peak_frac = peak_run / win

    return dict(
        frames=n,
        delta_frames=sum(1 for d in delta_mask if d),
        budget_bound=bound,
        bound_fraction=(bound / n) if n else 0.0,
        burst_window_frames=win,
        burst_peak_fraction=peak_frac,
        burst_peak_frame=peak_at,
        delta_psnr_p10=float(np.percentile(np.array(dpsnr), 10)) if dpsnr else 0.0,
    )


def starvation_warns(starve):
    """RETIRED / UNCALIBRATED verdict - kept for re-derivation only.

    The withdrawn gate's decision: EITHER the whole-clip bound fraction
    or the worst-window (burst) fraction over its threshold. The
    bound-fraction axis is refuted (008 reads 99.2% bound and is
    visually clean; 007 reads 36.4% and bands) - see the
    DELTA-STARVATION DIAGNOSTICS block. encode() no longer prints
    anything on the strength of this; the value is still recorded in
    BuildReport/--report as starvation_warned so the re-derivation has
    the old verdict alongside the stats. It is NOT a quality verdict."""
    return (starve["bound_fraction"] > STARVE_WARN_BOUND_FRAC
            or starve["burst_peak_fraction"] > STARVE_WARN_BURST_FRAC)


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


def _encode_direct(ex, width, height, fps_val, out_path, report_path=None,
                   dither_amp=None, dither_mode=None,
                   direct_transport_factor=None):
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
    dither_amp = _dither_amp(dither_amp)
    dither_mode = _dither_mode(dither_mode)
    cuts = [c for c in detect_scene_cuts(ex["chg"]) if 0 < c < N]
    bounds = [0] + cuts + [N]
    payloads = []
    psnrs = []
    for s_i, e_i in zip(bounds[:-1], bounds[1:]):
        if s_i == e_i:
            continue
        pal = scene_palette(orig, s_i, e_i, amplitude=dither_amp, mode=dither_mode)
        for i in range(s_i, e_i):
            # palette-collapse fix: dithered target, source-true PSNR
            idx, dec = dither_quantize(orig[i], pal, dither_amp, dither_mode)
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
    tf = direct_transport_factor  # None = shipping DIRECT_TRANSPORT_FACTOR
    if tf is not None:
        # T8 expert override, said out loud on every use: probe encodes
        # for the hardware round are DIAGNOSTIC (governance block at
        # DIRECT_TRANSPORT_FACTOR).
        print(f"  note: --direct-transport-factor {float(tf):g} overrides "
              f"the silicon-settled {DIRECT_TRANSPORT_FACTOR:.2f} BYTE "
              f"factor for this encode (the {DIRECT_FRAME_OVERHEAD_MS:g} "
              f"ms/frame transport overhead still applies - 2026-08-02 "
              f"whole-frame re-fit, see the governance block)")
    ds = direct_supply_check(worst_frame, fps_val, transport_factor=tf)
    if ds["utilization"] > 1.0:
        # Full menu (at this fps AND at the audio floor fps) so an
        # expert sees every at-rate option in one refusal, not just
        # the shape they happened to try.
        s_at = direct_max_raw_bytes(fps_val, 1.0, transport_factor=tf)
        s_90 = direct_max_raw_bytes(fps_val, 0.90, transport_factor=tf)
        fps_floor = min_fps_for()
        # menu-only hardening: fps_floor sits within a Fraction-
        # rounding tick of audio_layout's AUD_FRAME_MAX boundary by
        # construction (it IS the floor where real bytes/frame lands
        # at exactly AUD_FRAME_MAX), so feeding the exact float back through
        # direct_max_raw_bytes -> audio_layout can trip its strict
        # SystemExit depending on which way the rounding falls - a
        # refusal-message computation must never itself raise. Round
        # the floor UP to the nearest 0.01 fps first (the same ceiling
        # idiom audio_layout's own "fits" floor uses, and the precision
        # already shown to the user below) to land safely inside the
        # AUD_FRAME_MAX bucket instead of on its edge.
        fps_floor_safe = math.ceil(fps_floor * 100) / 100
        floor_at = direct_max_raw_bytes(fps_floor_safe, 1.0,
                                        transport_factor=tf)
        eff_tf = DIRECT_TRANSPORT_FACTOR if tf is None else float(tf)
        raise SystemExit(
            f"error: this direct-serve encode cannot play at rate - "
            f"worst-frame wire utilization {ds['utilization']:.2f} > "
            f"1.00 ({worst_frame} B/frame needs {ds['sd_ms']:.1f} ms of "
            f"SD wire per {ds['period_ms']:.0f} ms frame; "
            f"{ds['demand_kbs']:.0f} KB/s vs the "
            f"~{SD_WIRE_BYTES_PER_MS * TMODEL_COEFFS['audio_factor'] * 1000 / (1024 * eff_tf):.0f} KB/s "
            f"direct-transport rate at byte factor {eff_tf:g} plus the "
            f"{DIRECT_FRAME_OVERHEAD_MS:g} ms/frame transport overhead). "
            f"Direct-serve has NO ring "
            f"to absorb bursts and NO slow-playback opt-out (TIGHTEN "
            f"policy, Card #5 2026-07-26 owner ruling: this gate is "
            f"unconditional above utilization 1.00). The envelope at "
            f"{fps_val:g}fps, {width}-wide: it tops out at "
            f"{width}x{s_at // width} at-rate ({width}x{s_90 // width} "
            f"with the 0.90 burst margin every other gate carries). "
            f"Dropping to the {fps_floor:.2f}fps audio floor opens the "
            f"envelope to {width}x{floor_at // width}. Use a smaller "
            f"shape, lower --fps, or drop --direct and let the "
            f"delta encoder compress it.")
    elif ds["utilization"] > STREAM_WARN_UTIL:
        print(f"  warning: direct-serve wire utilization "
              f"{ds['utilization']:.2f} (> {STREAM_WARN_UTIL:.2f}) - "
              f"at-capacity encode; slow cards may pace-hold")

    # --- TOTAL-SIZE ADMISSION: the wire gate above prices ONE frame;
    # nothing priced the whole file, and direct-serve is the shape that
    # gets there fastest (a full-screen clip runs ~1 MB/s). Projected
    # from the writer's own arithmetic, checked before a byte is
    # written. ---
    projected_total = HEADER_SIZE + sum(
        abytes_pad + len(p) + (-len(p)) % 512 for p in payloads)
    total_size_check(projected_total, nframes_out, "direct-serve",
                     width, height, fps_val, ex["channels"])

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
                stream_pump_ms=0.0,
                stream_demand_kbs=report.stream_demand_kbs,
                # Direct-serve is all-literal: no deltas, nothing to
                # starve. The keys are emitted at their zero/None
                # defaults anyway (as staleness_events already is) so a
                # consumer can parse both modes' reports uniformly
                # without missing-key handling.
                delta_frames=report.delta_frames,
                budget_bound_frames=report.budget_bound_frames,
                bound_fraction=report.bound_fraction,
                burst_window_frames=report.burst_window_frames,
                burst_peak_fraction=report.burst_peak_fraction,
                burst_peak_frame=report.burst_peak_frame,
                delta_psnr_p10=report.delta_psnr_p10,
                starvation_warned=report.starvation_warned,
                # Direct-serve has no delta budget to scale, so the
                # auto-budget keys are emitted at their defaults for the
                # same uniform-parse reason as the starvation ones.
                stream_budget=report.stream_budget,
                auto_budget=report.auto_budget,
                auto_budget_target=report.auto_budget_target,
                auto_budget_probes=report.auto_budget_probes,
                auto_budget_ladder=[],
                scene_cuts=cuts, kf_span_ranges=[[i, i] for i in range(nframes_out)],
                # every direct frame is a full repaint - no trigger
                # machinery runs, empty map for uniform parse (W4)
                kf_triggers={},
                # W5 rolling refresh never runs on the direct preset
                # (no delta path) - zero defaults for uniform parse
                kf_roll_events=0, kf_roll_frames=0,
                kf_roll_windows=[], kf_roll_pending=0,
            ), f, indent=1)
    return report


def stream_gate_stats(result, ex, width, height, fps):
    """The shipped supply gate's own arithmetic over an encode_clip()
    result, factored out so the auto-budget search below and encode()'s
    refusal path measure the SAME number (a search that optimised
    against a second, near-copy of the gate is how a converged budget
    ends up refused). Returns (projected_total_bytes, stats-or-None);
    None means the gate does not apply - the file loads resident, or
    there are no frames."""
    payloads = result["payloads"]
    n = len(payloads)
    projected_total = HEADER_SIZE + sum(
        ex["abytes_pad"] + ((len(p) + 511) // 512) * 512 for p in payloads)
    if not n or projected_total <= STREAM_RESIDENT_POOL_B:
        return projected_total, None
    mean_t = sum(result["per_frame"]["t"]) / n
    mean_demand = (projected_total - HEADER_SIZE) / n
    return projected_total, stream_supply_check(
        mean_t, mean_demand, ex["abytes_pad"], fps, width, height,
        audio_real_bytes=ex.get("abytes_real"))


def auto_stream_budget(ex, width, height, fps, *, cap_bytes_frac=0.65,
                        merge_gaps=True, hysteresis=True,
                        staleness_refresh=True, dither_amp=None,
                        dither_mode=None, target_util=None,
                        max_probes=AUTO_BUDGET_MAX_PROBES, tile_slack=None,
                        kf_cadence_s=None):
    """SP17 T1. Derives the --stream-budget for this clip instead of
    making the author guess one, and returns the winning encode with it
    so nothing is encoded twice. Result dict: budget, result (the
    encode_clip() output at that budget), stats (its gate stats, None
    when the file loads resident), projected_total, probes (list of
    (budget, util-or-None) in the order tried), elapsed, resident,
    target.

    SEARCH. Utilization rises smoothly and monotonically with the budget
    (SP17 E2's ladder: 0.40/0.55/0.70/0.85 -> 0.56/0.74/0.89/1.00), so
    the search is an interpolation, not a bisection:

      probe 1   budget 1.00 - the honest ceiling. If the file is
                resident, or already fits at 1.00, that IS the answer
                and the search stops here at one encode pass.
      probe 2   the supply gate's own linear solve from that 1.00
                measurement (scale busy + the payload part of the fetch,
                hold the invariant audio pad). SP17 E3 measured that the
                gate's suggestion OSCILLATES near the ceiling - refused
                at 0.90 it suggests 0.88, refused at 0.88 it suggests
                0.89 - so a suggestion-following loop never converges.
                Only the FIRST suggestion, from the 1.00 refusal, is
                admissible, and that is the only place it is used here.
      probe 3+  secant / regula falsi on MEASURED utilization through
                the last two probes, clamped inside whatever bracket the
                search has established.

    Budgets are quoted to two decimals throughout - the value the report
    line prints is the value that reproduces the file by hand, and the
    finite grid also makes the loop terminate.

    NEVER RETURNS A REFUSED BUDGET. Only a probe that MEASURED at or
    under the target is returned; failing that, the least-loaded probe
    still at or under 1.00 (see the winner block at the end). If every
    probe was over 1.00 the search returns budget None and leaves
    encode() to raise the gate's own refusal message, which names the
    remedies a budget cannot fix (smaller shape, lower fps, shorter
    clip).

    PLATEAU. Utilization is monotone in the budget but not everywhere
    RESPONSIVE to it: above the point where the caps bind, the content
    sets the demand and cutting the budget buys nothing. The search
    detects that flat region and refuses to descend into starvation for
    a margin it cannot reach (AUTO_BUDGET_MIN_SLOPE), reporting the
    outcome as content-limited.

    COST. The nearest-colour palette solve is 85% of an encode pass and
    depends only on (frame pixels, palette), never on the budget, so the
    passes share one memo (see _quant_memo_solve) - after the first pass
    a probe costs about a fifth of a full encode. Measured (SP17 T1): 1
    pass when the ceiling already fits, 2 when the clip is
    content-limited, 4-5 on genuinely over-demanding footage;
    max_probes caps it."""
    import time
    target = AUTO_BUDGET_TARGET_UTIL if target_util is None else float(target_util)
    t0 = time.time()
    probes = []          # (budget, util or None) in probe order
    measured = []        # (budget, util) - the secant's own history
    kept = []            # (budget, util, result, stats, projected_total)
    budget = 1.00
    tried = set()
    plateau = False

    _quant_memo_enable()
    try:
        for k in range(max_probes):
            tried.add(budget)
            res = encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], width,
                               height, fps, cap_bytes_frac=cap_bytes_frac,
                               budget_scale=budget, merge_gaps=merge_gaps,
                               hysteresis=hysteresis,
                               staleness_refresh=staleness_refresh,
                               dither_amp=dither_amp, dither_mode=dither_mode,
                               tile_slack=tile_slack,
                               po_ceil_lm=ex.get("po_ceil_lm"),
                               abytes_pad=ex.get("abytes_pad"),
                               kf_cadence_s=kf_cadence_s)
            proj, stats = stream_gate_stats(res, ex, width, height, fps)
            if stats is None:
                # Resident (or empty): no supply gate applies at all.
                probes.append((budget, None))
                if not kept:
                    # The ceiling itself loads resident - that IS the
                    # answer, at one encode pass.
                    return dict(budget=budget, result=res, stats=None,
                                projected_total=proj, probes=probes,
                                elapsed=time.time() - t0, resident=True,
                                target=target, plateau=False)
                # A LOWER budget shrank the file under the resident pool
                # while the ceiling was over it. That is feasible by
                # definition (nothing to stream), so record it as fully
                # unloaded and stop - descending further can only cost
                # picture. A higher budget that already met the target
                # still outranks it in the winner block below.
                kept.append((budget, 0.0, res, None, proj))
                break
            util = stats["utilization"]
            probes.append((budget, util))
            kept.append((budget, util, res, stats, proj))
            feasible = [p for p in kept if p[1] <= 1.0]
            at_target = [p for p in kept if p[1] <= target]

            # PLATEAU GUARD. Above the point where the cap starts to
            # bind, utilization is set by the CONTENT, not by the budget:
            # cutting the budget there changes nothing until it does bite,
            # and then it bites hard. Descending across that flat region
            # trades a large quality loss for no supply relief at all -
            # measured on Sintel classic 3 s, where budgets 1.00/0.98/0.88
            # all read utilization 0.9135 and 0.60 was the first value to
            # move it (to 0.81, at 61% budget-bound against 1.3%). So once
            # cutting stops paying, stop cutting - provided something
            # feasible is already in hand. When NOTHING is feasible yet, a
            # flat step means the cut was simply too small, and the search
            # must keep going or there is no file at all.
            #
            # The slope is measured CUMULATIVELY, from the highest budget
            # probed down to here, never from the last step alone. Inside
            # the binding region the response is a fine staircase (the
            # region scheduler fits whole bands, so a 0.02 budget step can
            # fit the same band count and read as flat) and a one-step
            # test mistakes a stair tread for the plateau. The plateau is
            # by construction the region at the TOP - once the caps bind
            # they stay bound as the budget falls - so the whole descent
            # is the honest evidence for whether they ever did.
            if feasible and measured:
                b_top, u_top = measured[0]
                if b_top - budget >= 0.01 and \
                        (u_top - util) / (b_top - budget) < AUTO_BUDGET_MIN_SLOPE:
                    plateau = True
            measured.append((budget, util))
            if plateau:
                break
            lo = max(at_target, key=lambda p: p[0]) if at_target else None
            over = [p for p in kept if p[1] > target]
            hi = min(over, key=lambda p: p[0]) if over else None
            lo_b = lo[0] if lo else None
            hi_b = hi[0] if hi else None
            if lo is not None and lo[1] >= target - AUTO_BUDGET_TOL:
                break                          # inside the accept band
            if lo_b is not None and hi_b is not None and hi_b - lo_b <= 0.011:
                break                          # bracket at grid resolution
            if k == max_probes - 1:
                break

            if len(measured) == 1:
                # E3-admissible model step (see the docstring): the gate's
                # own audio-invariant linear solve, used exactly once.
                audio_sd = stats["audio_sd_ms"]
                scalable = stats["busy_ms"] + stats["sd_ms"] - audio_sd
                nxt = (budget * (stats["period_ms"] * target - audio_sd)
                       / scalable) if scalable > 0 else budget * 0.9
            else:
                (b0, u0), (b1, u1) = measured[-2], measured[-1]
                nxt = (b1 - AUTO_BUDGET_STEP if u1 == u0 else
                       b1 + (target - u1) * (b1 - b0) / (u1 - u0))
            if lo_b is not None and hi_b is not None:
                nxt = min(max(nxt, lo_b + 0.005), hi_b - 0.005)
            elif nxt < budget:
                # Unbracketed extrapolation. The secant's slope is read
                # off points that may still sit on the plateau, where it
                # badly UNDER-states how fast utilization falls once the
                # cap bites - left alone it overshoots into starvation.
                # Cap the reach of one blind step.
                nxt = max(nxt, min(tried) - AUTO_BUDGET_MAX_STEP)
            if not feasible and k == max_probes - 2:
                # Last probe available and still nothing the gate would
                # accept: undershoot deliberately rather than spend it on
                # a value that might land over the line again and leave
                # the author with a refusal instead of a file.
                nxt *= 0.85
            nxt = round(min(1.0, max(AUTO_BUDGET_MIN, nxt)), 2)
            if nxt in tried:
                if lo_b is not None and hi_b is not None and hi_b - lo_b > 0.011:
                    nxt = round((lo_b + hi_b) / 2.0, 2)
                if nxt in tried:
                    break                      # nothing new at 0.01 steps
            budget = nxt
    finally:
        _quant_memo_disable()

    # WINNER. First choice: the highest budget that measured at or under
    # the target - the most bytes inside the safety margin. Failing that
    # (a plateau clip whose content demand never falls to the target, or
    # a search stopped by the probe cap), the least-loaded FEASIBLE probe
    # - with ties inside one accept band broken toward the higher budget,
    # since equal utilization at a higher budget is the same wire cost
    # for a better picture (SP17 E2).
    at_target = [p for p in kept if p[1] <= target]
    feasible = [p for p in kept if p[1] <= 1.0]
    if at_target:
        winner = max(at_target, key=lambda p: p[0])
    elif feasible:
        u_min = min(p[1] for p in feasible)
        winner = max((p for p in feasible if p[1] <= u_min + AUTO_BUDGET_TOL),
                     key=lambda p: p[0])
    else:
        return dict(budget=None, result=None, stats=None,
                    projected_total=None, probes=probes,
                    elapsed=time.time() - t0, resident=False, target=target,
                    plateau=plateau,
                    worst=min(kept, key=lambda p: p[1]) if kept else None)
    b, u, res, stats, proj = winner
    return dict(budget=b, result=res, stats=stats, projected_total=proj,
                probes=probes, elapsed=time.time() - t0,
                resident=(stats is None), target=target,
                plateau=(not at_target))


def auto_budget_line(search):
    """The one-line author-facing report for an auto-budget search, in
    the same two-space indented style as the encoder's other progress
    lines. Kept next to the search so the wording and the numbers stay
    together."""
    n = len(search["probes"])
    plural = "" if n == 1 else "s"
    where = ("resident, no supply gate" if search["resident"]
             else f"util {search['stats']['utilization']:.2f}")
    why = (f"target {search['target']:.2f} - content-limited, no lower "
           f"budget relieves the wire" if search.get("plateau")
           else f"target {search['target']:.2f}")
    return (f"  auto-budget: --stream-budget {search['budget']:.2f} -> "
            f"{where} ({why}) - "
            f"{n} probe{plural}, {search['elapsed']:.1f} s")


def tile_slack_line(knob, stats, target_util=None):
    """The one-line author-facing report for a NON-ZERO --tile-slack, in
    the same two-space indented style as auto_budget_line() above.

    The knob spends margin, so the cost has to be VISIBLE - an author
    who cannot see what he paid cannot judge whether he wanted it, and a
    UI cannot surface a number the encoder never printed. Named here:
    the slack as set, the relative supply allowance it resolved to, the
    utilisation the encode actually landed at, and how much of the
    margin to the refusal line is left. stats is stream_supply_check()'s
    dict, or None for a resident file (no gate applies, so there is no
    utilisation to quote and the knob cost nothing)."""
    rel = tile_slack_rel(knob, target_util)
    tgt = AUTO_BUDGET_TARGET_UTIL if target_util is None else float(target_util)
    head = f"  tile-slack: {float(knob):.2f} of headroom (target {tgt:.2f}, " \
           f"per-frame supply allowance {100.0 * rel:.2f}%)"
    if stats is None:
        return head + " - resident, no supply gate: cost nothing"
    util = stats["utilization"]
    return (head + f" - stream util {util:.3f}, margin "
            f"{STREAM_CEILING_UTIL - util:.3f} to the "
            f"{STREAM_CEILING_UTIL:.2f} refusal line")


def encode(src_path, out_path, *, shape=None, fps=None, quality_profile="max",
           report_path=None, start=None, duration=None, ffmpeg=None,
           dither=None, dither_mode=None, merge_gaps=True, hysteresis=True,
           staleness_refresh=True, cap_bytes_frac=0.65, stream_budget=None,
           budget_target=None, direct=False, retime=None, tile_slack=None,
           direct_transport_factor=None, kf_cadence=None,
           prefilter=None):
    """Top-level NXV v2 encoder entry point. Returns a BuildReport.

    dither (--dither): dither strength, a float 0.0-1.0. In the default
    MIXTURE mode (Yliluoma positional mixture dithering) it is the
    fraction of each pixel's quantization error the dither is asked to
    correct - 0.0 is pure nearest-colour, 1.0 full mixture; in OFFSET
    mode (--dither-mode offset, the pre-2026-07-28 escape hatch) it is
    the blue-noise offset depth as a fraction of one lattice
    quantization step. None (and either legacy boolean value - the old
    --dither flag was an accepted-for-compatibility no-op) means
    DITHER_AMP_DEFAULT (0.5). dither_mode (--dither-mode): "mixture" or
    "offset". One (amplitude, mode) pair threads through extraction
    (po_ceil), the delta pipeline and the direct preset alike - the
    ceiling and the targets
    must live at the same amplitude.

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

    stream_budget=None (the DEFAULT since SP17 T1) means DERIVE IT:
    auto_stream_budget() searches for the highest budget whose measured
    utilization still sits at or under budget_target (default
    AUTO_BUDGET_TARGET_UTIL) and the winning pass's stream is written.
    An explicit stream_budget wins outright and skips the search
    entirely - manual control is unchanged, only the default is.
    budget_target has no effect when stream_budget is explicit.

    retime (--retime, SP17 T0): how a source whose own frame rate is
    not fps gets resampled in TIME - "blend" (the default, a linear
    blend of the two neighbouring source frames at 4x the target
    resolution), "drop" (nearest source frame, the pre-SP17 behaviour)
    or "mci" (motion-compensated interpolation, opt-in). None means the
    default. videnc.retime_plan holds the filter strings and the wave
    measurements they come from. A source ALREADY at fps is untouched
    in every mode, filter chain and bytes alike.

    tile_slack (--tile-slack, SP17, owner-approved 2026-07-30): the
    OPT-IN supply-slack knob for the adaptive tile ladder, in fractions
    of the auto-budget utilisation headroom - 0.0 (the default) is the
    supply-neutral ladder and byte-for-byte today's output, 1.0 spends
    the entire margin between budget_target and the 1.00 refusal line
    and is the cap. It relaxes the ladder's supply-preservation test
    ONLY; the whole-line rung floor is not reachable from it at any
    value. See THE SUPPLY-SLACK KNOB block for the parameterisation and
    the cap's derivation. A non-zero value prints tile_slack_line().

    direct (--direct, SP15 3c): the raw-equivalent all-literal preset -
    every frame a full keyframe repaint, header direct-serve hint set
    (flags bit1), gated by worst-frame WIRE feasibility instead of the
    delta pipeline's dual budgets (see _encode_direct). TIGHTEN ruling
    (Card #5, 2026-07-26): the gate is unconditional - there is no
    slow-playback opt-out at this or any layer above it.

    direct_transport_factor (--direct-transport-factor, SP17 T8): the
    EXPERT OVERRIDE for the direct gate's transport factor - None (the
    default) is the shipping silicon-settled DIRECT_TRANSPORT_FACTOR;
    a number replaces it for THIS encode only, so the hardware round
    can stage probe files at the predicted post-T8 rate (0.93-0.99)
    before the NXBD re-run moves the default. See the governance block
    at the constant. Only meaningful with direct=True; ignored (with
    a note) otherwise - the delta pipeline's gate does not use it.

    kf_cadence (--kf-cadence, SP17 W4, re-shaped W5): keyframe cadence
    window in SECONDS - whenever no natural keyframe (cut / dissolve /
    staleness / drift) has occurred within the window, the encoder
    schedules a ROLLING REFRESH: forced-clean coverage of the whole
    surface spread across ordinary delta frames (W5 owner ruling
    2026-08-02 - the W4 forced keyframe SPAN this replaces held the
    visible picture for the whole paced repaint and read as a mid-clip
    pause on silicon). Trigger-forced keyframes stay real keyframes.
    None means KF_CADENCE_S_DEFAULT (5 s, the measured free point:
    -0.1% bytes for +0.39 dB 4x4 on the owner's pan clip); 0 disables
    the cadence outright.

    prefilter (--prefilter, W4): OPT-IN ffmpeg filter stage inserted at
    SOURCE resolution before scaling (bare flag = conservative hqdn3d
    temporal denoise). None (the default) leaves the extraction chain
    byte-identical to what it was."""
    if quality_profile != "max":
        raise ValueError(f"quality_profile {quality_profile!r} not implemented - only 'max'")

    width, height = resolve_shape(shape)
    fps_val = 25.0 if fps is None else float(fps)
    dither_amp = _dither_amp(dither)   # validate once, up front
    dmode = _dither_mode(dither_mode)
    # The one place that knows BOTH the knob and the budget target, so
    # the headroom-unit -> relative-allowance conversion happens exactly
    # once and everything downstream carries the resolved number.
    slack_knob = TILE_SLACK_DEFAULT if tile_slack is None else float(tile_slack)
    slack_rel = tile_slack_rel(slack_knob, budget_target)

    ex = _extract_source(src_path, width, height, fps_val, start, duration,
                          ffmpeg, dither_amp, dither_mode=dmode,
                          retime=retime, prefilter=prefilter)
    if direct:
        # SP15 3c: the all-literal direct-serve preset - no delta
        # pipeline, no rate control; see _encode_direct.
        if slack_knob:
            # Said out loud rather than ignored: --direct has no delta
            # schedule, so there is no tile ladder for the knob to relax.
            print("  note: --tile-slack has no effect with --direct - the "
                  "direct-serve preset repaints every frame in full and "
                  "runs no tile schedule")
        return _encode_direct(ex, width, height, fps_val, out_path,
                              report_path, dither_amp=dither_amp,
                              dither_mode=dmode,
                              direct_transport_factor=direct_transport_factor)
    if direct_transport_factor is not None:
        # Said out loud rather than ignored, same idiom as --tile-slack
        # above: the streaming gate carries its own wire calibration and
        # the override governs only the direct gate.
        print("  note: --direct-transport-factor has no effect without "
              "--direct - only the direct-serve wire gate reads it")
    # SP17 T1: no explicit budget means DERIVE one (see
    # auto_stream_budget). The search hands back the winning pass, so
    # the accepted budget is never re-encoded.
    auto_search = None
    if stream_budget is None:
        auto_search = auto_stream_budget(
            ex, width, height, fps_val, cap_bytes_frac=cap_bytes_frac,
            merge_gaps=merge_gaps, hysteresis=hysteresis,
            staleness_refresh=staleness_refresh, dither_amp=dither_amp,
            dither_mode=dmode, target_util=budget_target,
            tile_slack=slack_rel, kf_cadence_s=kf_cadence)
        stream_budget = auto_search["budget"]
        if stream_budget is None:
            # Every probe was over the line - fall through to the gate's
            # own refusal on the least infeasible one, which names the
            # remedies no budget can supply.
            worst = auto_search["worst"]
            stream_budget, result = worst[0], worst[2]
        else:
            print(auto_budget_line(auto_search))
            result = auto_search["result"]
    else:
        result = encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], width, height,
                              fps_val, cap_bytes_frac=cap_bytes_frac,
                              budget_scale=stream_budget,
                              merge_gaps=merge_gaps, hysteresis=hysteresis,
                              staleness_refresh=staleness_refresh,
                              dither_amp=dither_amp, dither_mode=dmode,
                              tile_slack=slack_rel,
                              po_ceil_lm=ex.get("po_ceil_lm"),
                              abytes_pad=ex.get("abytes_pad"),
                              kf_cadence_s=kf_cadence)

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
    projected_total, stream_stats = stream_gate_stats(
        result, ex, width, height, fps_val)
    # The opt-in knob's cost, printed BEFORE the gate so it is on record
    # even when the gate then refuses - "you spent margin and this is
    # where it landed" is exactly the context a refusal needs. Silent at
    # the default (0.0), which is every encode that did not ask for it.
    if slack_knob:
        print(tile_slack_line(slack_knob, stream_stats, budget_target))
    if stream_stats is not None:
        if stream_stats["utilization"] > 1.0:
            eq_ms = stream_stats["busy_ms"] + stream_stats["sd_ms"]
            raise SystemExit(
                f"error: this encode cannot stream - mean supply "
                f"utilization {stream_stats['utilization']:.2f} > 1.00 "
                f"(decode {stream_stats['busy_ms']:.1f} ms + SD fetch "
                f"{stream_stats['sd_ms']:.1f} ms"
                + (f" + pace-pump contention {stream_stats['pump_ms']:.1f} ms"
                   if stream_stats.get("pump_ms") else "")
                + f" per {stream_stats['period_ms']:.0f} ms frame; "
                f"{stream_stats['demand_kbs']:.0f} KB/s demand vs the "
                f"~{SD_WIRE_BYTES_PER_MS * TMODEL_COEFFS['audio_factor'] * 1000 / 1024:.0f} KB/s "
                f"pace-window wire rate). It is {projected_total} B - "
                f"bigger than the {STREAM_RESIDENT_POOL_B} B reference "
                f"resident pool, so it MUST stream, and would play at "
                f"~{eq_ms:.0f} ms/frame (target {stream_stats['period_ms']:.0f}) with an "
                f"underrun every frame. Remedy: "
                + (f"drop the explicit --stream-budget and let the "
                   f"encoder derive one (or try --stream-budget "
                   f"{stream_stats['suggested_budget']:.2f}), "
                   if auto_search is None else
                   f"the automatic budget search could not find a "
                   f"feasible operating point in "
                   f"{len(auto_search['probes'])} probes - this content "
                   f"out-demands the wire at this shape/fps, so use ")
                + f"a smaller shape, lower --fps, or a shorter/"
                f"resident-sized clip.")
        elif stream_stats["utilization"] > STREAM_WARN_UTIL:
            # Owner silicon, SP17 E6: an at-capacity MEAN is not a
            # healthy encode that the ring quietly absorbs. Fixture 007
            # at mean 0.981 measures p95 1.071 and runs of up to 19
            # consecutive frames over budget - it bands and judders on
            # real hardware.
            #
            # THREE WAYS TO GET HERE, and the remedy is different for
            # each, so the message names the one that applies. It used
            # to name only the first, on the argument that the automatic
            # search targets AUTO_BUDGET_TARGET_UTIL and never lands
            # above it - which is not true of a CONTENT-LIMITED search
            # (the plateau guard stops rather than starving the picture
            # for a margin it cannot reach), and is less true again now
            # that --tile-slack can deliberately spend into this band.
            # Telling an author to drop a --stream-budget he never set
            # is worse than saying nothing.
            if slack_knob:
                remedy = (f"lower or drop --tile-slack (currently "
                          f"{slack_knob:.2f}) - it is spending exactly this "
                          f"margin by design")
            elif auto_search is None:
                remedy = (f"drop the explicit --stream-budget to let the "
                          f"encoder derive one at "
                          f"~{AUTO_BUDGET_TARGET_UTIL:.2f}")
            else:
                remedy = (f"the automatic search could not reach "
                          f"~{AUTO_BUDGET_TARGET_UTIL:.2f} on this content - "
                          f"a smaller shape, lower --fps, lower --dither or "
                          f"a calmer cut are the levers a budget cannot "
                          f"supply")
            print(f"  warning: stream utilization "
                  f"{stream_stats['utilization']:.2f} (> {STREAM_WARN_UTIL:.2f}) - "
                  f"at-capacity encode: the whole-clip mean hides "
                  f"per-frame excursions well over 1.00, which read as "
                  f"banding and judder on hardware. Remedy: {remedy}")

    # --- TOTAL-SIZE ADMISSION: the supply gate above prices the mean
    # FRAME against the wire; nothing priced the whole file. Projected
    # from the writer's own arithmetic, checked before a byte is
    # written. ---
    projected_size = HEADER_SIZE + sum(
        abytes_pad + len(p) + (-len(p)) % 512 for p in payloads)
    total_size_check(projected_size, nframes_out, "streaming",
                     width, height, fps_val, ex["channels"])

    # FLAG_OCOPY (bit3) is never set: the T5a offset-copy coding was
    # withdrawn on 2026-08-02 and the shipping player refuses a file
    # that declares it. Streamed delta files carry FLAG_DELTA_STREAM
    # alone, exactly as they did before T5a.
    hdr_flags = FLAG_DELTA_STREAM
    header = pack_header(
        width=width, height=height, fps=fps_val, channels=ex["channels"],
        arate=ex["rate"], frame_count=nframes_out,
        audio_bytes_per_frame=ex["abytes_real"],
        ring_start_margin_blocks=ring_start_margin_blocks,
        per_frame_cap_blocks=per_frame_cap_blocks, flags=hdr_flags)

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

    # --- DELTA-STARVATION DIAGNOSTICS (owner ruling 2026-07-28) ---
    # REPORT-ONLY. The measurements always print for a streaming
    # encode; no warning is emitted and no threshold is consulted on
    # this path - the bound-fraction trigger is RETIRED as refuted (see
    # the DELTA-STARVATION DIAGNOSTICS block by the constants). The
    # retired verdict is still recorded in the report for whoever
    # re-derives the metric, but it is never shown to the author.
    starve = result.get("starvation") or starvation_stats(per_frame, fps_val)
    starvation_warned = starvation_warns(starve)      # RETIRED, not surfaced
    print(f"  delta stats: budget-bound {starve['bound_fraction']:.1%} "
          f"({starve['budget_bound']}/{starve['frames']} frames), "
          f"peak {starve['burst_window_frames']}-frame window "
          f"{starve['burst_peak_fraction']:.0%}"
          + (f" @f{starve['burst_peak_frame']}"
             if starve['burst_peak_frame'] is not None else "")
          + f", delta-frame PSNR p10 {starve['delta_psnr_p10']:.2f} dB")

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
        stream_pump_ms=stream_stats["pump_ms"] if stream_stats else 0.0,
        stream_demand_kbs=stream_stats["demand_kbs"] if stream_stats else 0.0,
        delta_frames=starve["delta_frames"],
        budget_bound_frames=starve["budget_bound"],
        bound_fraction=starve["bound_fraction"],
        burst_window_frames=starve["burst_window_frames"],
        burst_peak_fraction=starve["burst_peak_fraction"],
        burst_peak_frame=starve["burst_peak_frame"],
        delta_psnr_p10=starve["delta_psnr_p10"],
        starvation_warned=starvation_warned,
        stream_budget=float(stream_budget),
        auto_budget=auto_search is not None,
        auto_budget_target=(auto_search["target"] if auto_search else 0.0),
        auto_budget_probes=(len(auto_search["probes"]) if auto_search else 0),
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
                stream_pump_ms=report.stream_pump_ms,
                stream_demand_kbs=report.stream_demand_kbs,
                delta_frames=report.delta_frames,
                budget_bound_frames=report.budget_bound_frames,
                bound_fraction=report.bound_fraction,
                burst_window_frames=report.burst_window_frames,
                burst_peak_fraction=report.burst_peak_fraction,
                burst_peak_frame=report.burst_peak_frame,
                delta_psnr_p10=report.delta_psnr_p10,
                starvation_warned=report.starvation_warned,
                stream_budget=report.stream_budget,
                auto_budget=report.auto_budget,
                auto_budget_target=report.auto_budget_target,
                auto_budget_probes=report.auto_budget_probes,
                auto_budget_ladder=(
                    [[b, u] for b, u in auto_search["probes"]] if auto_search else []),
                scene_cuts=result["scene_cuts"], kf_span_ranges=result["kf_span_ranges"],
                kf_triggers=result.get("kf_triggers", {}),
                kf_roll_events=result.get("kf_roll_events", 0),
                kf_roll_frames=result.get("kf_roll_frames", 0),
                kf_roll_windows=result.get("kf_roll_windows", []),
                kf_roll_pending=result.get("kf_roll_pending", 0),
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
