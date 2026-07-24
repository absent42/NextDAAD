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
    (the only two Layer 2 shapes); height 1-256 (256 encodes as the
    sentinel byte 0 - see HDR_OFF_HEIGHT)."""
    if width not in CODE_BY_WIDTH:
        raise ValueError(f"width must be 256 or 320, got {width}")
    if not (1 <= height <= 256):
        raise ValueError(f"height must be 1-256, got {height}")
    if channels not in (1, 2):
        raise ValueError(f"channels must be 1 or 2, got {channels}")
    if not (0 <= frame_count < (1 << 24)):
        raise ValueError("frame_count out of the header's 24-bit range")
    if not (0 <= audio_bytes_per_frame < (1 << 16)):
        raise ValueError("audio_bytes_per_frame out of 16-bit range")
    if not (0 <= ring_start_margin_blocks < (1 << 16)):
        raise ValueError("ring_start_margin_blocks out of 16-bit range")
    if not (0 <= per_frame_cap_blocks < (1 << 16)):
        raise ValueError("per_frame_cap_blocks out of 16-bit range")

    hdr = bytearray(HEADER_SIZE)
    hdr[HDR_OFF_MAGIC:HDR_OFF_MAGIC + 5] = MAGIC
    hdr[HDR_OFF_VERSION] = VERSION
    hdr[HDR_OFF_WIDTHCODE] = CODE_BY_WIDTH[width]
    hdr[HDR_OFF_HEIGHT] = 0 if height == 256 else height
    hdr[HDR_OFF_FPSX10] = int(round(float(fps) * 10)) & 0xFF
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
# Opcodes ($00-$0B) - literal transcription of the format reference.
# ---------------------------------------------------------------------
OP_FEND = 0x00     # frame end - rest of block is padding
OP_SKIP16 = 0x01   # cursor += nn (LE, 2 bytes)
OP_RUN8 = 0x02     # n (1-255) bytes of colour c
OP_RUN16 = 0x03    # nn (LE) bytes of colour c
OP_COPY8 = 0x04    # n (1-255) literal bytes follow
OP_COPY16 = 0x05   # nn (LE) literal bytes follow
OP_PAL = 0x06      # full 512-byte palette block, NR $44 order
OP_SKIP8 = 0x07    # cursor += n (1-255)
OP_KFLIP = 0x08    # end of final keyframe chunk: atomic flip + palette swap
OP_KSTART = 0x0A   # begin keyframe span: target = hidden surface; cursor = 0
OP_SCROLL = 0x0B   # RESERVED, unimplemented in v2.0 - encoder never emits

VALID_OPS = frozenset({OP_FEND, OP_SKIP16, OP_RUN8, OP_RUN16, OP_COPY8,
                        OP_COPY16, OP_PAL, OP_SKIP8, OP_KFLIP, OP_KSTART})
TERMINAL_OPS = frozenset({OP_FEND, OP_KFLIP})

PAL_BLOCK_SIZE = 512

# ---------------------------------------------------------------------
# TMODEL_COEFFS - modeled Z80N decode+fetch T-state costs, ported
# VERBATIM from the research tmodel (.superpowers/sdd/sp15-research/
# research-decode-models.md kernel-d coefficients, protovid/tmodel.py).
# MODEL-NOT-SILICON: fetch_long/fetch_short are silicon-measured, every
# other number here is a research estimate. Task 2's silicon bench
# replaces this whole dict with measured coefficients before the format
# freezes - do not treat these as final.
# ---------------------------------------------------------------------
TMODEL_COEFFS = {
    "fetch_long": 22.1,        # T/byte, ini burst >= 64B [SILICON]
    "fetch_short": 26.0,       # T/byte, burst < 64B [SILICON]
    "t_skip": 45.0,             # skip op: pointer add + count parse
    "t_op_parse": 50.0,         # run/copy/pal op dispatch + parse
    "fill_cpu": 13.2,           # T/byte CPU fill, runs < dma threshold
    "fill_dma_per_b": 4.0,      # T/byte DMA fill (runs >= dma threshold)
    "fill_dma_setup": 355.0,    # DMA program upload, once per fill op
    "fill_dma_min": 64,         # bytes - DMA vs CPU fill crossover
    "header_rate": 26.0,        # T/byte for count/colour bytes (short reads)
    "t_frame_fixed": 1000.0,    # frame header + loop setup, once/frame
    "t_palette": 512 * 22.1 + 256 * 20.0,  # PAL op: 512B fetch + 256 nextreg writes
    "clock_khz": 28000.0,       # T per ms at 28MHz
    "audio_factor": 0.89,       # usable budget after the 11% audio ISR tax
}


def frame_period_t(fps):
    return 1000.0 / float(fps) * TMODEL_COEFFS["clock_khz"]


def usable_budget_t(fps):
    """Usable decode T per frame after the audio ISR tax."""
    return frame_period_t(fps) * TMODEL_COEFFS["audio_factor"]


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


def _cost_run_chunk(L):
    tc = TMODEL_COEFFS
    if L >= tc["fill_dma_min"]:
        fill_t = tc["fill_dma_setup"] + L * tc["fill_dma_per_b"]
    else:
        fill_t = L * tc["fill_cpu"]
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


def encode_delta(target_flat, err2_flat, cap_bytes, cap_t):
    """Threshold ladder with a byte cap and an optional modeled-T cap.
    Coarsens THRESHOLDS until both fit; falls back to greedy priority
    truncation (highest per-region squared error kept first) if even
    the coarsest threshold does not fit either cap. Ported from the
    research prototype's encode_delta, re-costed against the real op
    format. Returns (gcls, gstarts, glens, bytes, T, mode, binding)."""
    binding = "none"
    last_fail = None
    for k, T in enumerate(THRESHOLDS):
        mask = close_gaps(err2_flat > 3.0 * T * T)
        gcls, gstarts, glens = segment(target_flat, mask)
        b, t = stream_cost(gcls, glens)
        b += 1  # FEND
        ok_b = b <= cap_bytes
        ok_t = cap_t is None or t <= cap_t
        if ok_b and ok_t:
            if k > 0:
                binding = last_fail
            return gcls, gstarts, glens, b, t, f"thresh:{T}", binding
        last_fail = ("both" if (not ok_b and not ok_t)
                     else ("bytes" if not ok_b else "T"))

    # Coarsest threshold still over budget: greedy priority truncation,
    # highest-error changed regions kept first, ported from the
    # research prototype's fallback.
    T = THRESHOLDS[-1]
    mask = close_gaps(err2_flat > 3.0 * T * T)
    bnd = np.flatnonzero(mask[1:] != mask[:-1]) + 1
    starts = np.concatenate(([0], bnd))
    ends = np.concatenate((bnd, [mask.size]))
    vals = mask[starts]
    rs, re = starts[vals], ends[vals]
    if len(rs) == 0:
        gcls, gstarts, glens = segment(target_flat, np.zeros_like(mask))
        b, t = stream_cost(gcls, glens)
        return gcls, gstarts, glens, b + 1, t, "trunc", "trunc"
    cs = np.concatenate(([0.0], np.cumsum(err2_flat)))
    rerr = cs[re] - cs[rs]
    order = np.argsort(-rerr)
    sel = []
    ab, at = 1.0, TMODEL_COEFFS["t_frame_fixed"]   # +1 for the FEND byte
    mb = cap_bytes * 0.97
    mt = None if cap_t is None else cap_t * 0.97
    for ri in order:
        L = int(re[ri] - rs[ri])
        cb, ct = op_cost("copy", L)
        if ab + cb > mb or (mt is not None and at + ct > mt):
            continue
        ab += cb
        at += ct
        sel.append(ri)
    selmask = np.zeros(mask.size, dtype=bool)
    for ri in sel:
        selmask[rs[ri]:re[ri]] = True
    gcls, gstarts, glens = segment(target_flat, selmask)
    b, t = stream_cost(gcls, glens)
    b += 1
    guard = 0
    while (b > cap_bytes or (cap_t is not None and t > cap_t)) and sel and guard < 40:
        ri = sel.pop()
        selmask[rs[ri]:re[ri]] = False
        gcls, gstarts, glens = segment(target_flat, selmask)
        b, t = stream_cost(gcls, glens)
        b += 1
        guard += 1
    return gcls, gstarts, glens, b, t, "trunc", "trunc"


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


def _nearest(vecs, cb, chunk=131072):
    vecs = vecs.astype(np.float32)
    cb = cb.astype(np.float32)
    cbn = np.sum(cb * cb, axis=1)
    out = np.empty(vecs.shape[0], dtype=np.int32)
    for s in range(0, vecs.shape[0], chunk):
        v = vecs[s:s + chunk]
        d = v @ cb.T
        d = np.sum(v * v, axis=1)[:, None] - 2 * d + cbn[None, :]
        out[s:s + chunk] = np.argmin(d, axis=1)
    return out


def quantize_to_palette(rgb, pal):
    """Quantize (H,W,3) uint8 RGB to a fixed 256-entry palette. Returns
    (idx (H,W) uint8, decoded rgb (H,W,3) uint8). Nearest-colour."""
    H, W, _ = rgb.shape
    v = rgb.reshape(-1, 3).astype(np.float32)
    idx = _nearest(v, pal.astype(np.float32)).astype(np.uint8)
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
    med3 = float(np.median(chg[max(1, i - 3):i])) if i > 1 else 0.0
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

def kf_chunk_budget_bytes(fps, first):
    """Max keyframe literal bytes this frame's chunk may hold so the
    modeled decode stays inside the usable per-frame T budget (2%
    reserve). Ported from the research prototype's kf_chunk_cap,
    re-costed for the real COPY op overhead (KSTART/PAL dispatch on
    the first chunk)."""
    budget_t = usable_budget_t(fps) * 0.98 - TMODEL_COEFFS["t_frame_fixed"]
    if first:
        budget_t -= TMODEL_COEFFS["t_palette"]
        budget_t -= 2 * TMODEL_COEFFS["t_op_parse"]   # KSTART + PAL dispatch
    L = int(max(0.0, budget_t) / TMODEL_COEFFS["fetch_long"])
    return max(L, 1)


def plan_kf_chunks(raw_len, fps):
    """Returns a list of (start, length, first) chunks covering
    raw_len bytes, each sized to kf_chunk_budget_bytes."""
    chunks = []
    remaining, pos, first = raw_len, 0, True
    while remaining:
        c = min(remaining, kf_chunk_budget_bytes(fps, first))
        chunks.append((pos, c, first))
        pos += c
        remaining -= c
        first = False
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
    binding_budget_histogram: dict = field(default_factory=dict)


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
    320 (the only two Layer 2 shapes)."""
    if width not in CODE_BY_WIDTH:
        raise ValueError(f"width must be 256 or 320, got {width}")
    correction = PIXEL_ASPECT_CORRECTION_320 if width == 320 else PIXEL_ASPECT_CORRECTION_256
    h = int(round(width * correction / float(display_aspect)))
    return max(1, min(256, h))


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
    if not (1 <= height <= 256):
        raise ValueError(f"height must be 1-256, got {height}")
    return int(width), int(height)


# ---------------------------------------------------------------------
# Audio layout (unchanged from v1's own derivation - same rates, same
# round(rate/fps) samples-per-frame rule).
# ---------------------------------------------------------------------

def audio_layout(fps, channels):
    from fractions import Fraction
    rate = RATE_STEREO if channels == 2 else RATE_MONO
    exact = Fraction(rate) / Fraction(fps).limit_denominator(1000)
    samples = int(exact + Fraction(1, 2))
    real = samples * channels
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
    video_bytes, nframes = _videnc.extract_video(
        ffmpeg_path, input_path, start, duration, width, height, fps_frac, crop=crop)
    if nframes == 0:
        raise SystemExit("error: no frames decoded - check input/--start/--duration")

    channels = 1 if mono else 2
    rate, samples_per_frame, abytes_real, abytes_pad = audio_layout(fps_frac, channels)
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


def encode_clip(orig, chg, po_ceil, width, height, fps, cap_bytes_frac=0.65):
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
    usable = usable_budget_t(fps)
    refract = max(1, int(round(fps / 2)))
    cap_bytes = int(cap_bytes_frac * raw)

    scene_cuts = detect_scene_cuts(chg)

    payloads = []
    kf_span_ranges = []
    per_frame = {"bytes": [], "psnr": [], "mode": [], "binding": [], "drift": []}
    decoded = []

    held_pal = None
    prev_flat = None
    kf_chunks = []       # remaining (start, len, first) chunks of the active span
    kf_pal = None
    staging = None
    last_kf_end = -10_000
    span_start_frame = None
    kf_events = 0

    for i in range(N):
        start_kf = False
        trigger = None
        drift_for_stats = None   # T1 step 5: recorded for plain delta frames
        if kf_chunks:
            pass  # mid-span: keep painting the hidden surface
        elif held_pal is None:
            start_kf, trigger = True, "start"
        else:
            target_idx, target_dec = quantize_to_palette(orig[i], held_pal)
            drift = po_ceil[i] - psnr(orig[i], target_dec)
            drift_for_stats = drift
            in_refract = (i - last_kf_end) <= refract
            ct = CUT_T_REFRACT if in_refract else CUT_T
            dt = DRIFT_T_REFRACT if in_refract else DRIFT_T
            if _is_cut_at(chg, i, ct):
                start_kf, trigger = True, "cut"
            elif drift > dt:
                start_kf, trigger = True, "drift"

        if start_kf:
            scene_end = next((c for c in scene_cuts if c > i), N)
            kf_pal = scene_palette(orig, i, scene_end)
            planned = plan_kf_chunks(raw, fps)
            # Cut lookahead (T1 step 4): if this span would take >1
            # chunk AND the very next frame independently looks like a
            # hard cut too, defer starting the span to i+1 instead -
            # avoids composing a mixed-scene frame on the hidden
            # surface (research-realfootage-results.md HAZARD FOUND).
            if len(planned) > 1 and prev_flat is not None and _is_cut_at(chg, i + 1, CUT_T):
                target_idx, target_dec = quantize_to_palette(orig[i], held_pal)
                tflat = flatten_frame(target_idx, column_major)
                prev_dec_flat = held_pal[prev_flat].astype(np.float32)
                targ_dec_flat = held_pal[tflat].astype(np.float32)
                err2 = np.sum((targ_dec_flat - prev_dec_flat) ** 2, axis=1)
                gcls, gstarts, glens, b, t, mode, binding = encode_delta(
                    tflat, err2, cap_bytes, usable)
                payload = emit_delta_ops(tflat, gcls, gstarts, glens)
                prev_flat = np.where(_mask_from_segments(gcls, gstarts, glens, raw), tflat, prev_flat)
                dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
                payloads.append(payload)
                per_frame["bytes"].append(b)
                per_frame["psnr"].append(psnr(orig[i], dec_img))
                per_frame["mode"].append(mode + ":deferred_kf")
                per_frame["binding"].append(binding)
                per_frame["drift"].append(float("nan"))
                decoded.append(dec_img)
                continue
            kf_chunks = planned
            kf_events += 1
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
            if is_last:
                prev_flat = staging
                staging = None
                held_pal = kf_pal
                last_kf_end = i
                kf_span_ranges.append((span_start_frame, i))
                mode = "kf" if first else "kfflip"
            else:
                mode = "kfhold"
            per_frame["mode"].append(mode)
            # Display shows the flipped (hidden->visible) surface only
            # once KFLIP fires on the last chunk; every earlier chunk
            # in the span is a "hold" frame - prev_flat/held_pal are
            # still the PRE-SPAN visible content at this point (both
            # are only reassigned in the is_last branch above), so
            # held_pal[prev_flat] is exactly the correct hold image.
            dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
            decoded.append(dec_img)
            per_frame["psnr"].append(psnr(orig[i], dec_img))
        else:
            target_idx, target_dec = quantize_to_palette(orig[i], held_pal)
            tflat = flatten_frame(target_idx, column_major)
            prev_dec_flat = held_pal[prev_flat].astype(np.float32)
            targ_dec_flat = held_pal[tflat].astype(np.float32)
            err2 = np.sum((targ_dec_flat - prev_dec_flat) ** 2, axis=1)
            gcls, gstarts, glens, b, t, mode, binding = encode_delta(
                tflat, err2, cap_bytes, usable)
            payload = emit_delta_ops(tflat, gcls, gstarts, glens)
            new_flat = _apply_segments(prev_flat, tflat, gcls, gstarts, glens)
            prev_flat = new_flat
            payloads.append(payload)
            per_frame["bytes"].append(b)
            per_frame["mode"].append(mode)
            per_frame["binding"].append(binding)
            per_frame["drift"].append(drift_for_stats if drift_for_stats is not None else float("nan"))
            dec_img = unflatten_frame(held_pal[prev_flat], height, width, column_major).astype(np.uint8)
            decoded.append(dec_img)
            per_frame["psnr"].append(psnr(orig[i], dec_img))

    return dict(payloads=payloads, kf_span_ranges=kf_span_ranges, decoded=decoded,
                per_frame=per_frame, scene_cuts=scene_cuts, kf_events=kf_events,
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


def encode(src_path, out_path, *, shape=None, fps=None, quality_profile="max",
           report_path=None, start=None, duration=None, ffmpeg=None,
           dither=False, mono=False):
    """Top-level NXV v2 encoder entry point. Returns a BuildReport.

    quality_profile: only "max" is implemented in T1 (the dual-budget
    streaming cap point from the research - cap_bytes=0.65x raw AND
    cap_t=usable_budget_t(fps)). A byte-only "resident" profile is
    future work (research-realfootage-results.md's resident-mode
    finding: same streams re-priced without fetch cost)."""
    if quality_profile != "max":
        raise ValueError(f"quality_profile {quality_profile!r} not implemented - only 'max'")

    width, height = resolve_shape(shape)
    fps_val = 25.0 if fps is None else float(fps)

    ex = _extract_source(src_path, width, height, fps_val, start, duration,
                          ffmpeg, dither, mono)
    result = encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], width, height, fps_val)

    payloads = result["payloads"]
    nframes_out = len(payloads)
    max_payload = max((len(p) for p in payloads), default=0)
    per_frame_cap_blocks = (max_payload + 511) // 512
    ring_start_margin_blocks = per_frame_cap_blocks   # conservative T1 placeholder -
    # buffer at least one full max-size frame before starting playback;
    # Task 2/3 (ring sizing against real prefetch cost) may refine this.

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
        if not m.startswith("kf") and bd not in ("none",))
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
        binding_budget_histogram=hist,
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
                binding_budget_histogram=report.binding_budget_histogram,
                scene_cuts=result["scene_cuts"], kf_span_ranges=result["kf_span_ranges"],
            ), f, indent=1)

    return report
