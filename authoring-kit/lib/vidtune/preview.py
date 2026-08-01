"""Decoded-preview computation: nxv2dec frames to RGB, source frames via
videnc's own extraction path (parity by reuse), diff heatmap and
stale-band overlay. Pure functions; the GUI thread wrapper lives in
mainwindow.py."""
from fractions import Fraction
from pathlib import Path

import numpy as np

import nxv2dec
import nxv2enc
import videnc


def decode_vid(vid_path):
    """Decodes an NXV v2 file. Returns (header dict, RGB frames list) -
    header from nxv2enc.unpack_header, frames (H, W, 3) uint8 with the
    frame's own palette already applied."""
    buf = Path(vid_path).read_bytes()
    hdr = nxv2enc.unpack_header(buf)
    frames = [pal[idx] for pal, idx in nxv2dec.decode(vid_path)]
    return hdr, frames


def extract_source(ffmpeg, mp4, width, height, fps, retime, start, duration):
    """Source frames shaped/retimed exactly as the encoder would see
    them, built on videnc's own probe/crop/retime/extract functions
    (read-only imports - parity by reuse, not reimplementation). Mirrors
    nxv2enc._extract_source's own call sequence: one shared probe banner
    for dimensions and source fps, a center crop, a retime plan, then
    the raw RGB24 extraction.

    start/duration are SECONDS as plain Python floats here (every vidtune
    caller derives them from frame indices or a Knob via to_seconds()) -
    videnc.extract_video's own CLI only ever sees argparse strings for
    these (its --start/--duration have no `type=`), so it never
    stringifies them itself: `-t` gets str(duration), but `-ss` gets the
    raw `start` value unconverted. A truthy float start reaching
    subprocess.run() there raises "TypeError: expected str, bytes or
    os.PathLike object, not float" (owner-reported crash trace,
    2026-08-01: Set In past frame 0, Set Out, Preview Segment - the
    post-encode Flicker/Heatmap source re-extraction hit this on every
    segment with a nonzero start). This is the seam between vidtune and
    the pinned videnc module - stringify HERE, not in videnc.py itself,
    matching the str(float(x)) formatting videnc's own CLI/vidtune's
    argv already use elsewhere (mainwindow._fmt_seconds)."""
    ffmpeg = Path(ffmpeg)
    mp4 = Path(mp4)
    stderr = videnc._probe_stderr(ffmpeg, mp4)
    src_w, src_h = videnc.probe_dimensions(ffmpeg, mp4, stderr=stderr)
    crop = videnc.compute_center_crop(src_w, src_h, width, height)
    fps_frac = fps if isinstance(fps, Fraction) else Fraction(fps).limit_denominator(1000)
    src_fps = videnc.probe_source_fps(ffmpeg, mp4, stderr=stderr)
    stages, _retime_line = videnc.retime_plan(src_fps, fps_frac, width, height,
                                               mode=retime)
    # Falsy (None or 0.0) stays None rather than becoming the string
    # "0.0" (itself truthy) - extract_video's own `if start:`/
    # `if duration:` checks must see the same "omit the flag" case they
    # did before this fix, not gain a redundant "-ss 0.0"/"-t 0.0".
    start_arg = str(float(start)) if start else None
    duration_arg = str(float(duration)) if duration else None
    raw, n = videnc.extract_video(ffmpeg, mp4, start_arg, duration_arg,
                                  width, height, fps_frac, crop=crop,
                                  stages=stages)
    arr = np.frombuffer(raw, np.uint8).reshape(n, height, width, 3)
    return list(arr)


def diff_heatmap(src, enc):
    """(H, W, 3) uint8 red-scaled per-pixel mean abs error, gain 4x,
    clipped."""
    err = np.abs(src.astype(np.int16) - enc.astype(np.int16)).mean(axis=2)
    r = np.clip(err * 4, 0, 255).astype(np.uint8)
    out = np.zeros_like(src)
    out[..., 0] = r
    return out


def stale_bands(prev_src, src, prev_enc, enc, column_major, thresh=12):
    """bool mask, one entry per paint-order band (4 rows, or 4 columns
    when column_major): True where the source band changed beyond
    thresh but the decoded band is byte-identical to the previous
    decoded frame (content the encoder deferred)."""
    axis = 1 if column_major else 0
    n = src.shape[axis] // 4
    mask = np.zeros(n, dtype=bool)
    for b in range(n):
        sl = (slice(None), slice(b * 4, b * 4 + 4)) if column_major \
            else (slice(b * 4, b * 4 + 4),)
        band_src = src[sl]
        src_changed = bool(band_src.size and
                           (np.abs(band_src.astype(np.int16)
                                   - prev_src[sl].astype(np.int16)).max()
                            > thresh))
        enc_static = np.array_equal(enc[sl], prev_enc[sl])
        mask[b] = src_changed and enc_static
    return mask
