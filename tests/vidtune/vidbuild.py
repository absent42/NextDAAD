"""Builds minimal synthetic NXV v2 files for decode tests. Pattern
follows tests/nxv2_selftest.py - read that file first; it is the
worked example of hand-assembling frames the reference decoder accepts.

nxv2enc.pack_header only accepts width 256 or 320 (the two Layer 2
shapes) with height capped at 192/256 respectively - there is no way to
build a real NXV v2 header for an arbitrary tiny width like 32. So this
helper's width/height must be one of those real shapes; callers wanting
a small/fast fixture use a small HEIGHT (down to 1) rather than an
off-format width.
"""
import nxv2enc as enc


def build_solid_vid(path, width, height, colours):
    """Writes an NXV v2 file with one frame per entry in colours, each
    frame a solid fill of that palette index across the whole
    width*height surface (OP_RUN then OP_FEND, no PAL op - the decoder's
    default all-zero palette is fine for a solid-fill roundtrip check).
    fps=25, channels=2, audio_bytes_per_frame=0 (no audio block between
    payloads - nxv2dec._round_up_block(0) == 0, so this is legal and
    keeps the fixture minimal)."""
    raw = width * height
    hdr = enc.pack_header(
        width=width, height=height, fps=25, channels=2, arate=enc.RATE_STEREO,
        frame_count=len(colours), audio_bytes_per_frame=0,
        ring_start_margin_blocks=0, per_frame_cap_blocks=0)

    def pad512(b):
        return b + bytes((-len(b)) % 512)

    parts = [hdr]
    for colour in colours:
        payload = enc.op_run(raw, colour) + bytes([enc.OP_FEND])
        parts.append(pad512(payload))
    path.write_bytes(b"".join(parts))
