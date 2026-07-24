"""authoring-kit/lib/nxv2dec.py - NXV v2 reference decoder (SP15 T1).

This is the EXECUTABLE SPEC for the eventual Z80 player: Task 2's
silicon bench and Task 3's hand-traces cite this module's behaviour as
ground truth. It is also the encoder's own verification decoder (used
by nxv2enc.py's selftest and BuildReport PSNR pass). No hardware, no
emulators - pure Python/numpy over the wire format nxv2enc.py writes.

Two entry points:
  decode(path)   -> iterator of (palette (256,3) uint8, indexed_frame
                     (H,W) ndarray uint8) pairs, one per VISIBLE frame
                     (delta frames and the KFLIP frame of a keyframe
                     span; kf-hold chunks are not separate visible
                     frames from the player's perspective, but decode()
                     still yields one entry per source frame with the
                     held content repeated, matching the container's
                     own frame count / audio pacing).
  validate(path) -> list of issue strings (structural: op bounds,
                     cursor overruns, cap violations, KSTART/KFLIP
                     pairing). Never raises on a malformed file - it
                     reports issues instead, so a caller can decide.

Header/opcode constants are imported from nxv2enc (the single source of
truth for both sides, per the format reference)."""
from pathlib import Path

import numpy as np

from nxv2enc import (
    HEADER_SIZE, unpack_header,
    OP_FEND, OP_SKIP16, OP_RUN8, OP_RUN16, OP_COPY8, OP_COPY16, OP_PAL,
    OP_SKIP8, OP_KFLIP, OP_KSTART, VALID_OPS, TERMINAL_OPS,
    unflatten_frame,
)


class Nxv2FormatError(Exception):
    """Raised by decode() on a structural violation. validate() catches
    these itself and reports them as issue strings instead."""


def _decode_palette_block(block):
    """Inverse of nxv2enc.build_palette_block: NR $44 order (byte0 =
    RRRGGGBB, byte1 bit0 = the 9th/extended blue bit) -> (256,3) uint8
    RGB, reconstructing the Next's own 3-bit blue channel (matches the
    hardware 8-bit->9-bit expansion rule the encoder's own comment
    cites) rather than a naive 2-bit blue expansion."""
    pal = np.empty((256, 3), dtype=np.uint8)
    for i in range(256):
        byte0 = block[i * 2]
        byte1 = block[i * 2 + 1]
        r3 = (byte0 >> 5) & 7
        g3 = (byte0 >> 2) & 7
        b2 = byte0 & 3
        b3 = (b2 << 1) | (byte1 & 1)
        pal[i, 0] = (r3 << 5) | (r3 << 2) | (r3 >> 1)
        pal[i, 1] = (g3 << 5) | (g3 << 2) | (g3 >> 1)
        pal[i, 2] = (b3 << 5) | (b3 << 2) | (b3 >> 1)
    return pal


def run_payload(buf, pos, surface, cursor_len, palette_out=None, issues=None, start_cursor=0):
    """Execute ops from buf[pos:] into `surface` (a mutable 1D uint8
    ndarray of length cursor_len, paint order) until a terminal op
    (FEND/KFLIP) or KSTART. Returns (new_pos, cursor, opcode).

    start_cursor: the cursor position to resume at. Ordinary (non-
    keyframe) payloads always start fresh at 0 (the default) - each is
    an independent full-surface composition. A multi-chunk keyframe
    span's cursor instead CONTINUES across the chunk-frame payloads
    (only KSTART itself resets it to 0 - format reference) - callers
    stitching a span together pass the previous chunk's returned
    cursor back in here.

    If `issues` is a list, structural problems are appended to it and
    decoding continues on a best-effort basis (validate() mode);
    otherwise Nxv2FormatError is raised immediately (decode() mode)."""
    def fail(msg):
        if issues is not None:
            issues.append(msg)
        else:
            raise Nxv2FormatError(msg)

    cursor = start_cursor
    n = len(buf)
    while True:
        if pos >= n:
            fail(f"payload ran past end of file at byte {pos} without FEND/KFLIP")
            return pos, cursor, OP_FEND
        op = buf[pos]
        pos += 1
        if op in TERMINAL_OPS:
            return pos, cursor, op
        if op == OP_KSTART:
            return pos, cursor, op
        if op == OP_SKIP8:
            if pos >= n:
                fail("truncated SKIP8"); return pos, cursor, OP_FEND
            cnt = buf[pos]; pos += 1
            if cnt == 0:
                fail(f"SKIP8 with n=0 at byte {pos - 2} (spec requires 1-255)")
            cursor += cnt
        elif op == OP_SKIP16:
            if pos + 2 > n:
                fail("truncated SKIP16"); return pos, cursor, OP_FEND
            cnt = int.from_bytes(buf[pos:pos + 2], "little"); pos += 2
            cursor += cnt
        elif op == OP_RUN8:
            if pos + 2 > n:
                fail("truncated RUN8"); return pos, cursor, OP_FEND
            cnt, colour = buf[pos], buf[pos + 1]; pos += 2
            if cnt == 0:
                fail(f"RUN8 with n=0 at byte {pos - 3} (spec requires 1-255)")
            if cursor + cnt > cursor_len:
                fail(f"RUN8 cursor overrun: {cursor}+{cnt} > {cursor_len}")
                cnt = max(0, cursor_len - cursor)
            surface[cursor:cursor + cnt] = colour
            cursor += cnt
        elif op == OP_RUN16:
            if pos + 3 > n:
                fail("truncated RUN16"); return pos, cursor, OP_FEND
            cnt = int.from_bytes(buf[pos:pos + 2], "little"); colour = buf[pos + 2]; pos += 3
            if cursor + cnt > cursor_len:
                fail(f"RUN16 cursor overrun: {cursor}+{cnt} > {cursor_len}")
                cnt = max(0, cursor_len - cursor)
            surface[cursor:cursor + cnt] = colour
            cursor += cnt
        elif op == OP_COPY8:
            if pos >= n:
                fail("truncated COPY8"); return pos, cursor, OP_FEND
            cnt = buf[pos]; pos += 1
            if cnt == 0:
                fail(f"COPY8 with n=0 at byte {pos - 2} (spec requires 1-255)")
            if pos + cnt > n:
                fail(f"COPY8 payload runs past end of file ({pos}+{cnt} > {n})")
                cnt = max(0, n - pos)
            if cursor + cnt > cursor_len:
                fail(f"COPY8 cursor overrun: {cursor}+{cnt} > {cursor_len}")
                cnt = max(0, cursor_len - cursor)
            surface[cursor:cursor + cnt] = np.frombuffer(buf, dtype=np.uint8, count=cnt, offset=pos)
            pos += cnt
            cursor += cnt
        elif op == OP_COPY16:
            if pos + 2 > n:
                fail("truncated COPY16"); return pos, cursor, OP_FEND
            cnt = int.from_bytes(buf[pos:pos + 2], "little"); pos += 2
            if pos + cnt > n:
                fail(f"COPY16 payload runs past end of file ({pos}+{cnt} > {n})")
                cnt = max(0, n - pos)
            if cursor + cnt > cursor_len:
                fail(f"COPY16 cursor overrun: {cursor}+{cnt} > {cursor_len}")
                cnt = max(0, cursor_len - cursor)
            surface[cursor:cursor + cnt] = np.frombuffer(buf, dtype=np.uint8, count=cnt, offset=pos)
            pos += cnt
            cursor += cnt
        elif op == OP_PAL:
            if pos + 512 > n:
                fail("truncated PAL block"); return pos, cursor, OP_FEND
            if palette_out is not None:
                palette_out[:] = _decode_palette_block(buf[pos:pos + 512])
            pos += 512
        else:
            fail(f"reserved/unimplemented opcode ${op:02X} at byte {pos - 1}")
            # Cannot safely continue - no length is known for a
            # reserved opcode. Treat as an implicit frame end.
            return pos, cursor, OP_FEND


def _round_up_block(n):
    return ((n + 511) // 512) * 512


def _iter_frames(buf, hdr, issues=None):
    """Internal frame walker shared by decode()/validate(). Yields, per
    SOURCE frame (a multi-chunk keyframe span contributes one entry per
    chunk-frame, matching the container's own per-frame audio pacing):
    (visible_palette_copy, visible_surface_copy, span_terminal_opcode,
    payload_start_offset, payload_len_used).

    validate() mode (issues is a list): problems are recorded and
    walking continues best-effort. decode() mode (issues is None):
    the same problems raise Nxv2FormatError immediately."""
    def fail(msg):
        if issues is not None:
            issues.append(msg)
        else:
            raise Nxv2FormatError(msg)

    width, height = hdr["width"], hdr["height"]
    raw = width * height
    abytes_pad = _round_up_block(hdr["audio_bytes_per_frame"])

    visible_surface = np.zeros(raw, dtype=np.uint8)
    visible_palette = np.zeros((256, 3), dtype=np.uint8)
    hidden_surface = np.zeros(raw, dtype=np.uint8)
    hidden_palette = np.zeros((256, 3), dtype=np.uint8)
    in_span = False
    span_frame_idx = None
    span_cursor = 0   # persists across a span's chunk-frame payloads; only
                       # KSTART resets it to 0 (format reference) - ordinary
                       # (non-span) payloads always start fresh at 0.

    pos = HEADER_SIZE
    n = len(buf)
    for fi in range(hdr["frame_count"]):
        pos += abytes_pad
        if pos > n:
            fail(f"frame {fi}: audio block runs past end of file")
            break
        payload_start = pos

        target = hidden_surface if in_span else visible_surface
        pal_out = hidden_palette if in_span else visible_palette
        start_cursor = span_cursor if in_span else 0
        pos, cursor, term = run_payload(buf, pos, target, raw,
                                         palette_out=pal_out, issues=issues,
                                         start_cursor=start_cursor)

        if term == OP_KSTART:
            if in_span:
                fail(f"frame {fi}: KSTART while already inside a keyframe span")
            in_span = True
            span_frame_idx = fi
            hidden_surface[:] = visible_surface   # span starts from current visible content
            # KSTART is not itself terminal for the payload - the rest
            # of this frame's ops (PAL, COPY, .., FEND/KFLIP) continue
            # right after it, now targeting the hidden surface, cursor
            # reset to 0 (KSTART's own effect).
            pos, cursor, term2 = run_payload(buf, pos, hidden_surface, raw,
                                              palette_out=hidden_palette, issues=issues,
                                              start_cursor=0)
            term = term2
            if term == OP_KSTART:
                fail(f"frame {fi}: duplicate KSTART inside one payload")

        span_cursor = cursor if (in_span and term == OP_FEND) else 0

        block_end = payload_start + _round_up_block(pos - payload_start)
        if hdr.get("per_frame_cap_blocks", 0):
            cap_bytes = hdr["per_frame_cap_blocks"] * 512
            used = pos - payload_start
            if used > cap_bytes:
                fail(f"frame {fi}: payload {used}B exceeds header cap "
                     f"{cap_bytes}B ({hdr['per_frame_cap_blocks']} blocks)")
        pos = block_end
        if pos > n:
            fail(f"frame {fi}: payload block runs past end of file")

        if term == OP_KFLIP:
            if not in_span:
                fail(f"frame {fi}: KFLIP with no preceding KSTART")
            visible_surface[:] = hidden_surface
            visible_palette[:] = hidden_palette
            in_span = False
            span_frame_idx = None
        elif term == OP_FEND:
            pass  # in_span unchanged: mid-span hold, or an ordinary delta frame
        yield visible_palette.copy(), visible_surface.copy(), term, payload_start, pos - payload_start

    if in_span:
        fail(f"unterminated keyframe span: KSTART at frame {span_frame_idx} "
             f"never reached KFLIP")


def decode(vid_path):
    """Decode an NXV v2 file. Yields (palette (256,3) uint8, indexed
    frame (H,W) uint8) pairs, one per source frame (container frame
    count), in display order. Raises Nxv2FormatError on the first
    structural violation encountered."""
    path = Path(vid_path)
    buf = path.read_bytes()
    hdr = unpack_header(buf)
    width, height, colmajor = hdr["width"], hdr["height"], hdr["column_major"]
    for pal, surf, term, _, _ in _iter_frames(buf, hdr, issues=None):
        img = unflatten_frame(surf, height, width, colmajor)
        yield pal, img


def validate(vid_path):
    """Structural validation pass: op bounds, cursor overruns, cap
    violations, KSTART/KFLIP pairing, frame-count consistency. Returns
    a list of issue strings (empty = clean). Never raises."""
    issues = []
    path = Path(vid_path)
    try:
        buf = path.read_bytes()
    except OSError as exc:
        return [f"could not read file: {exc}"]
    if len(buf) < HEADER_SIZE:
        return ["file shorter than the 512-byte header"]
    try:
        hdr = unpack_header(buf)
    except ValueError as exc:
        return [f"header: {exc}"]
    if len(buf) % 512 != 0:
        issues.append(f"file size {len(buf)} is not a 512-byte block multiple")
    count = 0
    for _ in _iter_frames(buf, hdr, issues=issues):
        count += 1
    if count != hdr["frame_count"]:
        issues.append(f"decoded {count} frames, header declares {hdr['frame_count']}")
    return issues
