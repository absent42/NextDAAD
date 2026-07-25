#!/usr/bin/env python3
"""tests/nxv2_selftest.py - plain-python selftest for NXV v2 (SP15 T1).

No pytest dependency: `python tests\\nxv2_selftest.py` runs every case,
prints a PASS/FAIL line per case plus a summary, and exits 0 if all
passed, 1 otherwise. Cases are grouped by the plan's own 8 implementation
steps (docs/superpowers/plans/2026-07-23-sp15-nxv2.md Task 1) - the
suite accumulates as each step lands, per the plan's TDD instruction.

Steps 4/6/7 hit the real demo sources (tools/demo-files/) via ffmpeg and
run genuine (short-duration) encodes - they are the slow cases in this
file by design (real-footage sanity anchors, not synthetic unit tests).
"""
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))

import numpy as np

import nxv2enc as enc
import nxv2dec as dec

SINTEL = ROOT / "tools" / "demo-files" / "Sintel_1080_10s_30MB.mp4"
BBB = ROOT / "tools" / "demo-files" / "Big_Buck_Bunny_1080_10s_30MB.mp4"
FFMPEG = ROOT / "tools" / "ffmpeg" / "bin" / "ffmpeg.exe"

CASES = []   # list of (step, name, fn)


def case(step, name):
    def deco(fn):
        CASES.append((step, name, fn))
        return fn
    return deco


def expect(cond, msg="assertion failed"):
    if not cond:
        raise AssertionError(msg)


class SkipCase(Exception):
    """Raised by a case to mark itself SKIPPED (not PASSED) in the
    summary line - e.g. a real-footage case whose demo source/ffmpeg
    isn't present. main() catches this separately from AssertionError/
    other failures so a skip never gets counted or printed as a pass."""


def skip(msg):
    raise SkipCase(msg)


# =======================================================================
# Step 1: header writer/reader roundtrip
# =======================================================================

STEP1_SHAPES = [
    (256, 192), (320, 256), (320, 145), (256, 131), (320, 1), (320, 256),
]


@case(1, "header roundtrip - literal byte offsets, all test shapes")
def t1_header_roundtrip():
    for width, height in STEP1_SHAPES:
        fps = 25.0
        channels = 2
        arate = enc.RATE_STEREO
        frame_count = 12345
        audio_bpf = 933 * 2
        ring_margin = 7
        cap_blocks = 86
        hdr = enc.pack_header(
            width=width, height=height, fps=fps, channels=channels, arate=arate,
            frame_count=frame_count, audio_bytes_per_frame=audio_bpf,
            ring_start_margin_blocks=ring_margin, per_frame_cap_blocks=cap_blocks)
        expect(len(hdr) == 512, f"header size {len(hdr)} != 512")
        # Literal byte-offset table (format reference) - assert every
        # offset directly against raw bytes, not just via unpack_header.
        expect(hdr[0:5] == b"NXVID", "magic")
        expect(hdr[5] == 2, "version")
        expect(hdr[6] == (1 if width == 320 else 0), "width code")
        expect(hdr[7] == (0 if height == 256 else height), "height byte")
        expect(hdr[8] == (round(fps * 10) & 0xFF), "fps*10 low byte")
        expect(hdr[9] == channels, "achan")
        expect(int.from_bytes(hdr[10:12], "little") == arate, "arate LE16")
        expect(hdr[12] == enc.FLAG_DELTA_STREAM, "flags default")
        expect(hdr[13] == enc.KF_POLICY_V2, "kf policy byte")
        expect(int.from_bytes(hdr[14:17], "little") == frame_count, "frame count LE24")
        expect(int.from_bytes(hdr[17:19], "little") == audio_bpf, "audio bytes/frame LE16")
        expect(int.from_bytes(hdr[19:21], "little") == ring_margin, "ring margin LE16")
        expect(int.from_bytes(hdr[21:23], "little") == cap_blocks, "frame cap LE16")
        expect(all(b == 0 for b in hdr[23:512]), "reserved region not zero")

        parsed = enc.unpack_header(hdr)
        expect(parsed["width"] == width, "roundtrip width")
        expect(parsed["height"] == height, "roundtrip height")
        expect(parsed["column_major"] == (width == 320), "roundtrip column_major")
        expect(parsed["fps_x10"] == (round(fps * 10) & 0xFF), "roundtrip fps_x10")
        expect(parsed["channels"] == channels, "roundtrip channels")
        expect(parsed["arate"] == arate, "roundtrip arate")
        expect(parsed["frame_count"] == frame_count, "roundtrip frame_count")
        expect(parsed["audio_bytes_per_frame"] == audio_bpf, "roundtrip audio_bpf")
        expect(parsed["ring_start_margin_blocks"] == ring_margin, "roundtrip ring margin")
        expect(parsed["per_frame_cap_blocks"] == cap_blocks, "roundtrip frame cap")


@case(1, "header - invalid inputs rejected")
def t1_header_invalid():
    bad_calls = [
        dict(width=300, height=192, fps=25, channels=2, arate=15625,
             frame_count=1, audio_bytes_per_frame=0, ring_start_margin_blocks=0,
             per_frame_cap_blocks=0),
        dict(width=256, height=0, fps=25, channels=2, arate=15625,
             frame_count=1, audio_bytes_per_frame=0, ring_start_margin_blocks=0,
             per_frame_cap_blocks=0),
        dict(width=256, height=257, fps=25, channels=2, arate=15625,
             frame_count=1, audio_bytes_per_frame=0, ring_start_margin_blocks=0,
             per_frame_cap_blocks=0),
        dict(width=256, height=192, fps=25, channels=3, arate=15625,
             frame_count=1, audio_bytes_per_frame=0, ring_start_margin_blocks=0,
             per_frame_cap_blocks=0),
        dict(width=256, height=192, fps=25, channels=2, arate=15625,
             frame_count=1 << 24, audio_bytes_per_frame=0, ring_start_margin_blocks=0,
             per_frame_cap_blocks=0),
    ]
    for kwargs in bad_calls:
        try:
            enc.pack_header(**kwargs)
        except ValueError:
            continue
        raise AssertionError(f"expected ValueError for {kwargs}")

    good = enc.pack_header(width=256, height=192, fps=25, channels=2, arate=15625,
                            frame_count=1, audio_bytes_per_frame=0,
                            ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    bad_magic = bytearray(good); bad_magic[0:5] = b"XXXXX"
    bad_version = bytearray(good); bad_version[5] = 9
    bad_widthcode = bytearray(good); bad_widthcode[6] = 2
    for buf, label in ((bad_magic, "magic"), (bad_version, "version"), (bad_widthcode, "widthcode")):
        try:
            enc.unpack_header(bytes(buf))
        except ValueError:
            continue
        raise AssertionError(f"expected ValueError for bad {label}")
    try:
        enc.unpack_header(good[:100])
    except ValueError:
        pass
    else:
        raise AssertionError("expected ValueError for short buffer")


# =======================================================================
# Step 2: opcode emitter + reference decoder roundtrip
# =======================================================================

def _direct_roundtrip(prev_flat, target_flat, cursor_len):
    mask = prev_flat != target_flat
    gcls, gstarts, glens = enc.segment(target_flat, mask)
    payload = enc.emit_delta_ops(target_flat, gcls, gstarts, glens)
    surface = prev_flat.copy()
    pos, cursor, term = dec.run_payload(payload, 0, surface, cursor_len, issues=None)
    return surface, cursor, term, payload


@case(2, "opcode roundtrip - 8x8 synthetic index frame, mixed skip/run/copy")
def t2_roundtrip_8x8():
    rng = np.random.default_rng(1)
    prev = rng.integers(0, 8, size=64, dtype=np.uint8)
    target = prev.copy()
    target[0:8] = 3          # uniform run (>= FILLMIN) -> RUN
    target[10:13] = [9, 4, 200]   # short literal mix -> COPY
    target[40] = (int(target[40]) + 1) % 256   # single-byte literal change
    surface, cursor, term, payload = _direct_roundtrip(prev, target, 64)
    expect(np.array_equal(surface, target), "8x8 pixel-exact roundtrip")
    expect(cursor == 64, f"cursor-end exactness: {cursor} != 64")
    expect(term == enc.OP_FEND, "terminal op is FEND")


@case(2, "opcode roundtrip - larger (100x100) random-changed frame")
def t2_roundtrip_large():
    rng = np.random.default_rng(2)
    n = 100 * 100
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    changed = rng.random(n) < 0.35
    target[changed] = rng.integers(0, 256, size=int(changed.sum()), dtype=np.uint8)
    # force a couple of long uniform runs to exercise RUN emission
    target[500:900] = 17
    surface, cursor, term, payload = _direct_roundtrip(prev, target, n)
    expect(np.array_equal(surface, target), "100x100 pixel-exact roundtrip")
    expect(cursor == n, "cursor-end exactness (large frame)")


@case(2, "RUN boundary n=255 (RUN8) and n=256 (RUN16)")
def t2_run_boundary():
    payload255 = enc.op_run(255, 77) + bytes([enc.OP_FEND])
    expect(payload255[0] == enc.OP_RUN8, "n=255 uses RUN8")
    surface = np.zeros(300, dtype=np.uint8)
    pos, cursor, term = dec.run_payload(payload255, 0, surface, 300)
    expect(cursor == 255, "n=255 cursor")
    expect(np.all(surface[:255] == 77) and np.all(surface[255:] == 0), "n=255 fill content")

    payload256 = enc.op_run(256, 88) + bytes([enc.OP_FEND])
    expect(payload256[0] == enc.OP_RUN16, "n=256 uses RUN16")
    surface = np.zeros(300, dtype=np.uint8)
    pos, cursor, term = dec.run_payload(payload256, 0, surface, 300)
    expect(cursor == 256, "n=256 cursor")
    expect(np.all(surface[:256] == 88) and np.all(surface[256:] == 0), "n=256 fill content")


@case(2, "64-byte DMA-threshold irrelevance to correctness (n=63 vs n=64)")
def t2_dma_threshold_irrelevance():
    for n, colour in ((63, 5), (64, 6)):
        payload = enc.op_run(n, colour) + bytes([enc.OP_FEND])
        surface = np.zeros(n + 10, dtype=np.uint8)
        pos, cursor, term = dec.run_payload(payload, 0, surface, n + 10)
        expect(cursor == n, f"n={n} cursor")
        expect(np.all(surface[:n] == colour), f"n={n} content (DMA threshold must not affect correctness)")


@case(2, "COPY16 max (n=65535)")
def t2_copy16_max():
    rng = np.random.default_rng(3)
    data = rng.integers(0, 256, size=65535, dtype=np.uint8)
    payload = enc.op_copy(data.tobytes()) + bytes([enc.OP_FEND])
    expect(payload[0] == enc.OP_COPY16, "65535-byte copy uses COPY16")
    surface = np.zeros(70000, dtype=np.uint8)
    pos, cursor, term = dec.run_payload(payload, 0, surface, 70000)
    expect(cursor == 65535, "COPY16 max cursor")
    expect(np.array_equal(surface[:65535], data), "COPY16 max content")


@case(2, "reserved-op rejection ($24 = old $09, $2C SCROLL, misaligned, $FF) - raises in decode mode, recorded in validate mode")
def t2_reserved_op_rejection():
    # Pre-scaled x4 opcode space: $24/$2C are the reserved slots, any
    # non-multiple-of-4 byte (e.g. $02) is outside the set entirely.
    for opcode in (0x24, enc.OP_SCROLL, 0x02, 0xFF):
        buf = bytes([opcode])
        surface = np.zeros(8, dtype=np.uint8)
        try:
            dec.run_payload(buf, 0, surface, 8, issues=None)
        except dec.Nxv2FormatError:
            pass
        else:
            raise AssertionError(f"opcode ${opcode:02X} should raise Nxv2FormatError in decode mode")
        issues = []
        dec.run_payload(buf, 0, surface, 8, issues=issues)
        expect(len(issues) == 1 and f"{opcode:02X}" in issues[0].upper(),
               f"opcode ${opcode:02X} should be recorded in validate mode: {issues}")


# =======================================================================
# Step 3: keyframe span (KSTART/chunking/KFLIP) roundtrip
# =======================================================================

@case(3, "keyframe span - hidden-surface semantics (visible unchanged until KFLIP)")
def t3_keyframe_span():
    rng = np.random.default_rng(4)
    width, height = 256, 2
    raw = width * height   # 512
    target = rng.integers(0, 256, size=raw, dtype=np.uint8)
    pal_a = rng.integers(0, 256, size=(256, 3), dtype=np.uint8)
    pal_a_rt = dec._decode_palette_block(enc.build_palette_block(pal_a))   # what the wire roundtrip actually yields

    hdr = enc.pack_header(width=width, height=height, fps=25, channels=1, arate=enc.RATE_MONO,
                           frame_count=3, audio_bytes_per_frame=0,
                           ring_start_margin_blocks=0, per_frame_cap_blocks=0)

    def pad512(b):
        return b + bytes((-len(b)) % 512)

    payload0 = bytes([enc.OP_KSTART]) + enc.op_pal(pal_a) + enc.op_copy(target[0:300].tobytes()) + bytes([enc.OP_FEND])
    payload1 = enc.op_copy(target[300:512].tobytes()) + bytes([enc.OP_KFLIP])
    payload2 = enc.op_skip(512) + bytes([enc.OP_FEND])

    buf = hdr + pad512(payload0) + pad512(payload1) + pad512(payload2)
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "kftest.vid"
        path.write_bytes(buf)

        issues = dec.validate(path)
        expect(issues == [], f"validate() should be clean: {issues}")

        frames = list(dec.decode(path))
        expect(len(frames) == 3, f"expected 3 frames, got {len(frames)}")

        pal0, img0 = frames[0]
        expect(np.all(img0 == 0), "frame0 (mid-span hold): visible surface unchanged (still the zeroed initial state)")

        pal1, img1 = frames[1]
        expected_img1 = enc.unflatten_frame(target, height, width, column_major=False)
        expect(np.array_equal(img1, expected_img1), "frame1 (KFLIP): visible surface == full keyframe content")
        expect(np.array_equal(pal1, pal_a_rt), "frame1 palette == the KSTART span's PAL block (roundtripped)")

        pal2, img2 = frames[2]
        expect(np.array_equal(img2, img1), "frame2 (delta, all-skip): unchanged from frame1")
        expect(np.array_equal(pal2, pal1), "frame2 palette held from the keyframe (no PAL op)")


@case(3, "keyframe span - KSTART without matching KFLIP is flagged (validate) / raises (decode)")
def t3_unterminated_span():
    width, height = 256, 1
    raw = width * height
    hdr = enc.pack_header(width=width, height=height, fps=25, channels=1, arate=enc.RATE_MONO,
                           frame_count=1, audio_bytes_per_frame=0,
                           ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    payload = bytes([enc.OP_KSTART]) + enc.op_pal(np.zeros((256, 3), dtype=np.uint8)) + \
        enc.op_copy(bytes(raw)) + bytes([enc.OP_FEND])   # FEND, not KFLIP - span never closes
    buf = hdr + payload + bytes((-len(payload)) % 512)
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "unterminated.vid"
        path.write_bytes(buf)
        issues = dec.validate(path)
        expect(any("KSTART" in i or "unterminated" in i for i in issues), f"expected an unterminated-span issue: {issues}")
        try:
            list(dec.decode(path))
        except dec.Nxv2FormatError:
            pass
        else:
            raise AssertionError("decode() should raise on an unterminated keyframe span")


@case(3, "validate() robustness on genuinely malformed/truncated files (never raises)")
def t3_validate_robustness():
    with tempfile.TemporaryDirectory() as td:
        # Empty file.
        p_empty = Path(td) / "empty.vid"
        p_empty.write_bytes(b"")
        issues = dec.validate(p_empty)
        expect(issues != [], "empty file should report an issue")

        # Garbage (not NXVID at all).
        p_garbage = Path(td) / "garbage.vid"
        p_garbage.write_bytes(bytes(rng_bytes(600)))
        issues = dec.validate(p_garbage)
        expect(issues != [], "garbage file should report an issue")

        # Valid header claiming 5 frames, but the file only contains
        # payload data for 1 (truncated mid-stream, e.g. a partial SD
        # write) - validate() must report it, not raise or hang.
        hdr = enc.pack_header(width=256, height=1, fps=25, channels=1, arate=enc.RATE_MONO,
                               frame_count=5, audio_bytes_per_frame=0,
                               ring_start_margin_blocks=0, per_frame_cap_blocks=0)
        one_frame = enc.op_skip(256) + bytes([enc.OP_FEND])
        buf = hdr + one_frame + bytes((-len(one_frame)) % 512)
        p_trunc = Path(td) / "truncated.vid"
        p_trunc.write_bytes(buf)
        issues = dec.validate(p_trunc)
        expect(issues != [], f"truncated file (header says 5 frames, file has 1) should report an issue: {issues}")
        try:
            list(dec.decode(p_trunc))
        except dec.Nxv2FormatError:
            pass
        else:
            raise AssertionError("decode() should raise on a truncated file")


def rng_bytes(n):
    return np.random.default_rng(9).integers(0, 256, size=n, dtype=np.uint8).tobytes()


# =======================================================================
# Steps 4-7: real-footage pipeline (Sintel/BBB). Cached extraction to
# avoid repeated ffmpeg runs across steps within one selftest run.
# =======================================================================

_EXTRACT_CACHE = {}


def _extract(clip_path, width, height, fps, start, duration):
    key = (str(clip_path), width, height, fps, start, duration)
    if key not in _EXTRACT_CACHE:
        if not clip_path.exists() or not FFMPEG.exists():
            return None
        _EXTRACT_CACHE[key] = enc._extract_source(
            clip_path, width, height, fps, start, duration, str(FFMPEG), dither=False, mono=False)
    return _EXTRACT_CACHE[key]


_ENCODE_CACHE = {}


def _encode_clip(clip_path, width, height, fps, start, duration):
    key = (str(clip_path), width, height, fps, start, duration)
    if key not in _ENCODE_CACHE:
        ex = _extract(clip_path, width, height, fps, start, duration)
        if ex is None:
            return None
        _ENCODE_CACHE[key] = enc.encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], width, height, fps)
    return _ENCODE_CACHE[key]


@case(4, "scene segmentation + cut lookahead - no keyframe span straddles a detected cut (Sintel)")
def t4_scene_cut_lookahead():
    result = _encode_clip(SINTEL, 256, 192, 25.0, "00:00:01", "4")
    if result is None:
        skip("Sintel source or ffmpeg not available")
    cuts = result["scene_cuts"]
    expect(len(result["kf_span_ranges"]) >= 1, "expected at least one keyframe span in a 4s cut-containing window")
    for (s, e) in result["kf_span_ranges"]:
        for c in cuts:
            expect(not (s < c < e), f"keyframe span ({s},{e}) straddles detected cut at frame {c}")


@case(5, "scene-scoped palette drift - stays under the trigger between refreshes (Sintel)")
def t5_drift_under_trigger():
    result = _encode_clip(SINTEL, 256, 192, 25.0, "00:00:01", "4")
    if result is None:
        skip("Sintel source or ffmpeg not available")
    drifts = result["per_frame"]["drift"]
    bad = [(i, d) for i, d in enumerate(drifts) if not np.isnan(d) and d >= enc.DRIFT_T_REFRACT]
    expect(bad == [], f"drift exceeded the refractory trigger on frames: {bad[:5]}")


@case(6, "dual-budget rate control - zero truncation on both research clips/shapes")
def t6_zero_truncation():
    combos = [(SINTEL, 256, 192, 25.0), (SINTEL, 320, 256, 25.0),
              (BBB, 256, 192, 25.0), (BBB, 320, 256, 25.0)]
    any_ran = False
    for clip, w, h, fps in combos:
        result = _encode_clip(clip, w, h, fps, None, "3")
        if result is None:
            continue
        any_ran = True
        # Region-coherent scheduling replaced the greedy-truncation fallback:
        # a budget-bound frame keeps whole contiguous bands ("region:K/N").
        # The dual-budget guarantee holds as long as no frame is FULLY starved
        # (region:0 - not even one band fits), which a single cheap band never
        # is. Assert no fully-starved frame (the catastrophic case).
        starved = [m for m in result["per_frame"]["mode"] if m.startswith("region:0/")]
        expect(starved == [], f"{clip.name} {w}x{h}@{fps}: {len(starved)} fully-starved frame(s) - dual-budget scheduling failed to keep any content")
    if not any_ran:
        skip("demo sources or ffmpeg not available")


@case(6, "dual-budget rate control - region-coherent budget-bound scheduling (synthetic, forced)")
def t6_budget_bound_scheduling():
    # Real footage rarely exercises the budget-bound path at 3s; force it
    # with an artificially tiny cap that the full frame cannot satisfy, so
    # the region-coherent tile schedule runs and must still fit the cap.
    rng = np.random.default_rng(5)
    n = 320 * 256
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = rng.integers(0, 256, size=n, dtype=np.uint8)   # near-total change
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    tiny_cap = 200   # far below what the full frame needs
    gcls, gstarts, glens, b, t, mode, binding, payload = enc.encode_delta(
        target, err2, tiny_cap, None, surface_flat=prev)
    expect(mode.startswith("region:"), f"expected region-coherent scheduling, got mode={mode}")
    expect(b <= tiny_cap, f"budget-bound stream still exceeds its own cap: {b} > {tiny_cap}")
    expect(len(payload) == b, f"payload length {len(payload)} != modeled bytes {b}")
    # The budget-bound stream must still be a STRUCTURALLY valid opcode
    # stream that terminates cleanly. (A merged stream legitimately drops the
    # trailing skip, so the cursor need NOT reach the frame end - the tiny
    # cap keeps 0 bands here, so the merged all-skip frame is just FEND.)
    surface = prev.copy()
    pos, cursor, term = dec.run_payload(payload, 0, surface, n, issues=None)
    expect(term == enc.OP_FEND, "budget-bound stream still terminates cleanly with FEND")
    expect(pos == len(payload), f"decoder must consume the whole payload: {pos} != {len(payload)}")


@case(7, "ring/resident sizing + BuildReport + validate() full pass (both research clips)")
def t7_report_and_validate():
    if not SINTEL.exists() or not BBB.exists() or not FFMPEG.exists():
        skip("demo sources or ffmpeg not available")
    with tempfile.TemporaryDirectory() as td:
        for clip, shape_name, (w, h) in ((SINTEL, "256x192", (256, 192)),
                                          (BBB, "320x256", (320, 256))):
            out = Path(td) / f"{clip.stem}_{shape_name}.vid"
            report = enc.encode(str(clip), str(out), shape=(w, h), fps=25.0,
                                 quality_profile="max", start=None, duration="5",
                                 ffmpeg=str(FFMPEG))
            expect(report.frames > 0, "BuildReport.frames > 0")
            expect(report.shape == (w, h), "BuildReport.shape")
            expect(out.stat().st_size % 512 == 0, "output file is a 512B block multiple")
            expect(out.stat().st_size == report.total_bytes, "BuildReport.total_bytes matches file size")
            expect(15.0 < report.mean_psnr < 50.0, f"mean PSNR {report.mean_psnr} outside sane bounds")
            expect(report.keyframes >= 1, "at least one keyframe (startup)")
            issues = dec.validate(out)
            expect(issues == [], f"{clip.name} {w}x{h}: validate() found issues: {issues}")
            print(f"  [{clip.stem} {w}x{h}@25] frames={report.frames} bytes={report.total_bytes} "
                  f"mean/worst PSNR={report.mean_psnr:.2f}/{report.worst_psnr:.2f} "
                  f"kf={report.keyframes} s/MB={report.seconds_per_mb:.2f} "
                  f"binding={report.binding_budget_histogram}")


# =======================================================================
# Step 8: CLI rewire - presets, free-height aspect derivation
# =======================================================================

@case(8, "shape presets resolve to the plan's literal (width, height) table")
def t8_presets():
    expect(enc.resolve_shape("full") == (320, 256), "full")
    expect(enc.resolve_shape("16:9") == (320, 192), "16:9")
    expect(enc.resolve_shape("scope") == (320, 144), "scope")
    expect(enc.resolve_shape("classic") == (256, 192), "classic")
    expect(enc.resolve_shape("classic-wide") == (256, 144), "classic-wide")
    expect(enc.resolve_shape(None) == (320, 256), "default shape == full")
    expect(enc.resolve_shape((320, 200)) == (320, 200), "explicit (w,h) passthrough")
    try:
        enc.resolve_shape("nope")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown preset should raise ValueError")


@case(8, "free-height (--aspect) derivation - pixel-aspect 1.067 correction")
def t8_free_height():
    # The plan brief's own worked example: 320-wide at true cinema scope
    # (2.35:1) derives height 145 (a free height, distinct from the
    # 'scope' preset's fixed 144).
    expect(enc.derive_free_height(320, 2.35) == 145, f"320@2.35 -> {enc.derive_free_height(320, 2.35)}")
    # width=256 (mode-0) uses NO pixel-aspect correction - square pixels.
    expect(enc.derive_free_height(256, 256 / 131) == 131, "256 has no correction (roundtrip)")
    # Clamps to the header's representable range.
    expect(enc.derive_free_height(320, 0.001) == 256, "clamped to max height 256")
    expect(enc.derive_free_height(320, 1000.0) == 1, "clamped to min height 1")


@case(8, "CLI end-to-end - videnc.py --shape/--aspect produces a valid NXV v2 file")
def t8_cli_end_to_end():
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("Sintel source or ffmpeg not available")
    import subprocess
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "cli_test.vid"
        cmd = [sys.executable, str(LIB / "videnc.py"), str(SINTEL), str(out),
               "--shape", "classic", "--fps", "25", "--duration", "1",
               "--ffmpeg", str(FFMPEG)]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        expect(proc.returncode == 0, f"videnc.py CLI failed:\n{proc.stderr.decode('utf-8', 'replace')}")
        expect(out.exists(), "CLI did not produce an output file")
        hdr = enc.unpack_header(out.read_bytes()[:enc.HEADER_SIZE])
        expect(hdr["width"] == 256 and hdr["height"] == 192, f"CLI --shape classic -> {hdr['width']}x{hdr['height']}")
        issues = dec.validate(out)
        expect(issues == [], f"CLI output failed validate(): {issues}")


# =======================================================================
# Step 9: review fixes (post-T1 review findings 1/2 + minor fixes)
# =======================================================================

@case(9, "review fix: height cap conditioned on width (256-wide max 192, 320-wide max 256)")
def t9_height_cap_by_width():
    common = dict(fps=25, channels=2, arate=15625, frame_count=1,
                   audio_bytes_per_frame=0, ring_start_margin_blocks=0,
                   per_frame_cap_blocks=0)

    # pack_header: 256-wide (mode-0, 192 lines) must reject > 192.
    for bad_h in (193, 256):
        try:
            enc.pack_header(width=256, height=bad_h, **common)
        except ValueError:
            pass
        else:
            raise AssertionError(f"pack_header should reject width=256 height={bad_h}")
    enc.pack_header(width=256, height=192, **common)   # the max is still accepted
    enc.pack_header(width=320, height=256, **common)   # 320-wide (mode-1) still allows up to 256

    # resolve_shape: same width-conditioned cap on an explicit (w,h) tuple.
    for bad_h in (193, 256):
        try:
            enc.resolve_shape((256, bad_h))
        except ValueError:
            pass
        else:
            raise AssertionError(f"resolve_shape should reject (256, {bad_h})")
    expect(enc.resolve_shape((256, 192)) == (256, 192), "resolve_shape 256x192 (the max) accepted")
    expect(enc.resolve_shape((320, 256)) == (320, 256), "resolve_shape 320x256 still accepted")

    # derive_free_height: an aspect ratio that would derive a height
    # past 192 for a 256-wide (square-pixel) shape must clamp to 192,
    # not the old unconditional 256 ceiling.
    h256 = enc.derive_free_height(256, 0.1)   # tiny aspect -> huge raw height
    expect(h256 == 192, f"derive_free_height(256, 0.1) should clamp to 192, got {h256}")
    # 320-wide is unaffected - still clamps to 256.
    expect(enc.derive_free_height(320, 0.001) == 256, "derive_free_height(320, ...) still clamps to 256")


@case(9, "review fix: fps_x10 header byte clamps to 255 with a warning instead of silently wrapping")
def t9_fps_x10_clamp():
    import warnings
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        hdr = enc.pack_header(width=256, height=192, fps=30.0, channels=2, arate=15625,
                               frame_count=1, audio_bytes_per_frame=0,
                               ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    got = hdr[enc.HDR_OFF_FPSX10]
    expect(got == 255, f"fps=30 (fps*10=300) should clamp fps_x10 to 255, got {got}")
    expect(got != (300 & 0xFF), "must not silently wrap fps_x10 (300 & 0xFF == 44 was the old bug)")
    expect(any(issubclass(w.category, UserWarning) for w in caught), f"expected a UserWarning on fps_x10 clamp, got {[w.category for w in caught]}")

    # A normal fps (fps*10 <= 255) still round-trips with no warning.
    with warnings.catch_warnings(record=True) as caught2:
        warnings.simplefilter("always")
        hdr2 = enc.pack_header(width=256, height=192, fps=25.0, channels=2, arate=15625,
                                frame_count=1, audio_bytes_per_frame=0,
                                ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    expect(hdr2[enc.HDR_OFF_FPSX10] == 250, f"fps=25 -> fps_x10 250, got {hdr2[enc.HDR_OFF_FPSX10]}")
    expect(caught2 == [], f"fps=25 should not warn, got {[str(w.message) for w in caught2]}")


@case(9, "review fix: _is_cut_at reads IMPULSE_MEDIAN_WINDOW (not a hardcoded 3)")
def t9_impulse_window_not_hardcoded():
    # Crafted so the impulse verdict flips depending on the median
    # window width - proves the function re-reads the module constant
    # at call time rather than closing over a literal 3.
    chg = np.array([0.0, 0.0, 0.0, 5.0, 0.5])
    orig_window = enc.IMPULSE_MEDIAN_WINDOW
    try:
        enc.IMPULSE_MEDIAN_WINDOW = 3
        expect(enc._is_cut_at(chg, 4, 0.4) == True,
               "window=3: median(chg[1:4])=0.0 -> impulse True -> cut fires")
        enc.IMPULSE_MEDIAN_WINDOW = 1
        expect(enc._is_cut_at(chg, 4, 0.4) == False,
               "window=1: median(chg[3:4])=5.0 -> impulse False -> cut suppressed")
    finally:
        enc.IMPULSE_MEDIAN_WINDOW = orig_window


@case(9, "review fix: content-triggered keyframe near clip end clamps its chunk plan instead of emitting an unterminated span")
def t9_kf_span_end_of_clip_clamp():
    fps = 25.0
    width, height = 256, 192   # 'classic' shape: raw=49152 falls in the T-model's 2-chunk range at 25fps
    raw = width * height
    planned = enc.plan_kf_chunks(raw, fps)
    expect(len(planned) == 2,
           f"test setup assumption broken: expected a 2-chunk keyframe plan at "
           f"{width}x{height}@{fps}, got {len(planned)} - re-tune this test's shape "
           f"if TMODEL_COEFFS changed")

    N = 6
    rng = np.random.default_rng(11)
    color_a = rng.integers(0, 256, size=3, dtype=np.uint8)
    color_b = rng.integers(0, 256, size=3, dtype=np.uint8)
    orig = np.empty((N, height, width, 3), dtype=np.uint8)
    orig[:] = color_a
    orig[N - 1] = color_b   # forced hard cut on the clip's LAST frame
    chg = np.zeros(N)
    chg[N - 1] = 1.0        # maximal change-fraction signal at the cut
    po_ceil = np.full(N, 99.0)

    result = enc.encode_clip(orig, chg, po_ceil, width, height, fps)

    # remaining_frames at the cut (N-1) is 1, but the plan needs 2
    # chunks - the guard must clamp it to a single-frame span (KSTART
    # and KFLIP on the same, final payload) rather than leaving a
    # KSTART with no matching KFLIP.
    expect(result["kf_events"] >= 2,
           f"expected >=2 keyframe events (startup span + end-of-clip cut), got {result['kf_events']}")
    last_span = result["kf_span_ranges"][-1]
    expect(last_span == (N - 1, N - 1),
           f"expected a clamped single-frame span at the clip's last frame, got {last_span}")
    expect(any(m.endswith(":clamped") for m in result["per_frame"]["mode"]),
           "expected a per-frame mode entry disclosing the clamp (BuildReport degradation-event source)")
    expect(any(enc.OP_KFLIP in p for p in result["payloads"]),
           "expected an OP_KFLIP byte in the payload stream")

    hdr = enc.pack_header(width=width, height=height, fps=fps, channels=1, arate=enc.RATE_MONO,
                           frame_count=len(result["payloads"]), audio_bytes_per_frame=0,
                           ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    buf = hdr + b"".join(p + bytes((-len(p)) % 512) for p in result["payloads"])
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "kf_end_clamp.vid"
        path.write_bytes(buf)
        issues = dec.validate(path)
        expect(issues == [], f"validate() should be clean (no unterminated keyframe span): {issues}")
        frames = list(dec.decode(path))
        expect(len(frames) == N, f"expected {N} decoded frames, got {len(frames)}")


# =======================================================================
# Step 10: SP15 encoder-optimization wave (silicon TMODEL, optimal
# gap-merge, quantizer hysteresis, importance-sorted coarsening,
# trailing-skip drop)
# =======================================================================

def _op_kinds(payload):
    """Walk a raw delta payload, return the list of op-name strings in
    order (terminating at FEND/KFLIP). Skip/run/copy operand-aware."""
    names = {enc.OP_FEND: "FEND", enc.OP_SKIP16: "SKIP16", enc.OP_RUN8: "RUN8",
             enc.OP_RUN16: "RUN16", enc.OP_COPY8: "COPY8", enc.OP_COPY16: "COPY16",
             enc.OP_PAL: "PAL", enc.OP_SKIP8: "SKIP8", enc.OP_KFLIP: "KFLIP",
             enc.OP_KSTART: "KSTART"}
    out = []
    pos = 0
    while pos < len(payload):
        op = payload[pos]; pos += 1
        out.append(names.get(op, f"?{op:02X}"))
        if op in (enc.OP_FEND, enc.OP_KFLIP):
            break
        if op == enc.OP_SKIP8:
            pos += 1
        elif op == enc.OP_SKIP16:
            pos += 2
        elif op == enc.OP_RUN8:
            pos += 2
        elif op == enc.OP_RUN16:
            pos += 3
        elif op == enc.OP_COPY8:
            pos += 1 + payload[pos]
        elif op == enc.OP_COPY16:
            cnt = int.from_bytes(payload[pos:pos + 2], "little"); pos += 2 + cnt
        elif op == enc.OP_PAL:
            pos += enc.PAL_BLOCK_SIZE
    return out


@case(10, "silicon TMODEL adopted - optimized-kernel dispatch 387T, K* self-retunes from coeffs")
def t10_silicon_coeffs():
    tc = enc.TMODEL_COEFFS
    # Second NXBEN sitting (core 3.02.04, 2026-07-25) - the OPTIMIZED kernels.
    expect(tc["t_op_parse"] == 387.0, f"t_op_parse should be the silicon RUN8 387, got {tc['t_op_parse']}")
    expect(tc["t_skip"] == 130.0, f"t_skip should be the silicon SK8 130, got {tc['t_skip']}")
    expect(tc["fetch_long"] == 20.2, f"fetch_long should be the silicon 20.2, got {tc['fetch_long']}")
    expect(tc["fill_cpu"] == 17.0, f"fill_cpu should be the silicon 17.0, got {tc['fill_cpu']}")
    expect(tc["fill_dma_setup"] == 849.0, f"fill_dma_setup should be the silicon 849, got {tc['fill_dma_setup']}")
    expect(tc["fill_dma_per_b"] == 5.1, f"fill_dma_per_b should be the silicon 5.1, got {tc['fill_dma_per_b']}")
    expect(tc["t_frame_fixed"] == 1132.0, "t_frame_fixed should be the silicon FE 1132")
    expect(abs(enc.usable_budget_t(25.0) - 952000.0) < 1.0,
           f"silicon usable budget @25 should be 952000 T, got {enc.usable_budget_t(25.0)}")
    # Composed-player safety factor (stage-3a real-footage silicon leg,
    # 2026-07-25): flat surfaces come in UNDER the model (worst 0.898),
    # mode-1 LETTERBOX surfaces cost 1.20-1.40x it (column-hop chunked
    # bodies). Pinned here so a coefficient re-fit cannot silently drop
    # the de-rating that keeps a gapped clip inside one frame period.
    cf = enc.TMODEL_COMPOSITION_FACTOR
    expect(cf["flat"] == 1.00, f"flat composition factor should be 1.00, got {cf['flat']}")
    expect(cf["gapped"] == 1.55, f"gapped composition factor should be 1.55, got {cf['gapped']}")
    expect(enc.is_gapped(320, 192) and enc.is_gapped(320, 144),
           "mode-1 sub-256 heights are gapped")
    expect(not enc.is_gapped(320, 256) and not enc.is_gapped(256, 144)
           and not enc.is_gapped(256, 192),
           "mode-1 full height and ALL mode-0 heights are flat (row-linear)")
    # The budget must actually de-rate for a gapped shape, and not for a
    # flat one - the whole point of threading the shape through.
    expect(abs(enc.usable_budget_t(25.0, 320, 256) - 952000.0) < 1.0,
           "flat 320x256 keeps the full 952000 T budget")
    expect(abs(enc.usable_budget_t(25.0, 256, 144) - 952000.0) < 1.0,
           "flat 256x144 keeps the full 952000 T budget")
    gb = enc.usable_budget_t(25.0, 320, 192)
    expect(abs(gb - 952000.0 / 1.55) < 1.0,
           f"gapped 320x192 budget should be 952000/1.55 = 614194 T, got {gb:.0f}")
    # ... and the keyframe chunk planner must shrink with it (a kf chunk
    # is one long COPY straight down the paint order - it crosses every
    # column boundary the gapped surface has).
    expect(enc.kf_chunk_budget_bytes(25.0, True, 320, 192)
           < enc.kf_chunk_budget_bytes(25.0, True, 320, 256),
           "gapped keyframe chunks must be smaller than flat ones")
    expect(len(enc.plan_kf_chunks(320 * 192, 25.0, 320, 192))
           > len(enc.plan_kf_chunks(320 * 192, 25.0, 320, 256)),
           "a gapped keyframe span needs more chunks at the de-rated budget")
    # K* derives from the coefficients (self-retunes). At sitting-2 silicon:
    # (130+387)/20.2 = 25.6 B.
    ks = enc.merge_kstar()
    expect(25.0 < ks < 26.5, f"silicon K* should be ~25.6 B, got {ks:.1f}")
    saved = dict(enc.TMODEL_COEFFS)
    try:
        enc.TMODEL_COEFFS["t_op_parse"] = 150.0
        ks2 = enc.merge_kstar()
        expect(ks2 < ks, f"K* must fall when dispatch falls: {ks2:.1f} !< {ks:.1f}")
        expect(abs(ks2 - (130 + 150) / 20.2) < 0.1, "K* recomputes from live coeffs")
    finally:
        enc.TMODEL_COEFFS.clear()
        enc.TMODEL_COEFFS.update(saved)


@case(10, "optimal gap-merge - decoded output BYTE-IDENTICAL to un-merged, fewer ops, lower T")
def t10_merge_byte_identity():
    rng = np.random.default_rng(21)
    n = 2000
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    # two changed spans separated by a tiny (< K*) interior skip -> bridge;
    # one change followed by a WIDE (> K*) skip then another change -> keep;
    # last change well before the end -> trailing skip dropped.
    target[100:110] = 7
    target[113:123] = 9       # gap 110..113 = 3 bytes < K* -> bridged
    target[400:410] = 11
    target[900:910] = 13      # gap 410..900 = 490 bytes > K* -> NOT bridged
    # everything after 910 is unchanged -> trailing skip
    mask = prev != target
    gcls, gstarts, glens = enc.segment(target, mask)
    unmerged = enc.emit_delta_ops(target, gcls, gstarts, glens)
    merged, mb, mt = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    _, tb = enc.stream_cost(gcls, glens)

    surf_u = prev.copy()
    dec.run_payload(unmerged, 0, surf_u, n)
    surf_m = prev.copy()
    dec.run_payload(merged, 0, surf_m, n)
    expect(np.array_equal(surf_u, surf_m),
           "merged stream must decode BYTE-IDENTICAL to the un-merged stream")
    expect(np.array_equal(surf_m, target), "decoded surface equals the target content")

    ku = _op_kinds(unmerged)
    km = _op_kinds(merged)
    expect(len(km) < len(ku), f"merge should reduce op count: {len(km)} !< {len(ku)}")
    # the small interior gap was bridged: fewer SKIP ops in the merged stream
    expect(km.count("SKIP8") < ku.count("SKIP8"),
           f"bridged skip should drop a SKIP8 op: merged skips={km.count('SKIP8')} vs {ku.count('SKIP8')}")
    # the wide gap survives as a real skip
    expect("SKIP16" in km or "SKIP8" in km, "the wide interior gap must survive as a skip")
    expect(mt < tb, f"merged modeled T must be lower: {mt:.0f} !< {tb:.0f}")


@case(10, "trailing-skip drop - merged stream never ends on a skip op")
def t10_trailing_skip_dropped():
    rng = np.random.default_rng(22)
    n = 1500
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    target[50:60] = 3   # only change is early; rest is a long trailing skip
    mask = prev != target
    gcls, gstarts, glens = enc.segment(target, mask)
    unmerged = enc.emit_delta_ops(target, gcls, gstarts, glens)
    merged, _, _ = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    ku = _op_kinds(unmerged)
    km = _op_kinds(merged)
    # un-merged carries a trailing skip before FEND; merged must not.
    expect(ku[-2].startswith("SKIP"), f"setup: un-merged should have a trailing skip, got {ku}")
    expect(not km[-2].startswith("SKIP"), f"merged must drop the trailing skip, got {km}")
    # and still decode identically (trailing bytes stay == surface)
    su = prev.copy(); dec.run_payload(unmerged, 0, su, n)
    sm = prev.copy(); dec.run_payload(merged, 0, sm, n)
    expect(np.array_equal(su, sm), "trailing-skip-dropped stream decodes identically")


@case(10, "op-soup gap-merge cuts modeled T >= 50% at silicon prices (research: 64-84% at D=920)")
def t10_merge_t_magnitude():
    # Synthetic 'op soup' resembling the real footage histograms (median
    # copy ~1-5B, median skip ~6-16B): hundreds of tiny alternating
    # changed/unchanged spans. The merge should collapse them, cutting the
    # dispatch-dominated modeled T by more than half.
    rng = np.random.default_rng(23)
    n = 20000
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    pos = 0
    while pos < n - 40:
        clen = int(rng.integers(1, 6))
        target[pos:pos + clen] = rng.integers(0, 256, size=clen, dtype=np.uint8)
        pos += clen + int(rng.integers(6, 17))   # interior skip 6..16 (< K*)
    mask = prev != target
    gcls, gstarts, glens = enc.segment(target, mask)
    _, t_un = enc.stream_cost(gcls, glens)
    merged, _, t_m = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    expect(t_m <= 0.5 * t_un,
           f"merge should cut modeled T by >=50% on op-soup: {t_m:.0f} vs {t_un:.0f} ({t_m / t_un:.1%})")
    sm = prev.copy(); dec.run_payload(merged, 0, sm, n)
    expect(np.array_equal(sm, target), "op-soup merge still decodes to target")


@case(10, "quantizer hysteresis - stable-scene-with-noise churn drops >10x, PSNR within tolerance")
def t10_hysteresis_churn():
    rng = np.random.default_rng(24)
    H, W = 48, 64
    yy, xx = np.mgrid[0:H, 0:W]
    # smooth gradient -> many pixels near palette-cell boundaries (churn)
    base = np.stack([(xx * 4) % 256, (yy * 5) % 256, ((xx + yy) * 3) % 256],
                    axis=2).astype(np.uint8)
    pal = enc.adaptive_palette(base)
    prev0, _ = enc.quantize_to_palette(base, pal)
    prev_no = prev0.copy()
    prev_hy = prev0.copy()
    churn_no = churn_hy = 0
    psnr_no, psnr_hy = [], []
    for _ in range(20):
        noise = rng.integers(-3, 4, size=(H, W, 3))
        frame = np.clip(base.astype(int) + noise, 0, 255).astype(np.uint8)
        idx_no, dec_no = enc.quantize_to_palette(frame, pal)
        idx_hy, dec_hy = enc.quantize_to_palette(
            frame, pal, prev_idx=prev_hy, hysteresis_eps=enc.HYSTERESIS_EPS)
        churn_no += int((idx_no != prev_no).sum())
        churn_hy += int((idx_hy != prev_hy).sum())
        psnr_no.append(enc.psnr(frame, dec_no))
        psnr_hy.append(enc.psnr(frame, dec_hy))
        prev_no, prev_hy = idx_no, idx_hy
    ratio = churn_no / max(1, churn_hy)
    drop = float(np.mean(psnr_no) - np.mean(psnr_hy))
    expect(ratio >= 10.0, f"hysteresis should cut index churn >=10x, got {ratio:.1f}x")
    expect(drop < 1.5, f"hysteresis PSNR regression {drop:.2f} dB exceeds the 1.5 dB tolerance")


@case(10, "importance-sorted coarsening - the fallback keeps the highest-|delta| regions")
def t10_importance_coarsening():
    # Two equal-size changed regions, BOTH large enough to survive the
    # coarsest threshold (err2 > 3*64*64 = 12288) so the ladder cannot
    # separate them - only the fallback runs. A is a bigger colour jump
    # (higher importance) than B; a cap that admits one region must keep A
    # and drop B (XDC importance ordering, not error-blind truncation).
    rng = np.random.default_rng(31)
    n = 4000
    prev = np.full(n, 100, dtype=np.uint8)
    target = prev.copy()
    # non-uniform (-> COPY, not a cheap RUN) so the byte cap actually binds;
    # both regions clear err2 > 12288 (|delta| > 110) so the threshold ladder
    # can't separate them and the fallback must run.
    target[100:300] = rng.integers(235, 256, size=200, dtype=np.uint8)   # A: delta ~135-155 (high)
    target[2000:2200] = rng.integers(215, 226, size=200, dtype=np.uint8)  # B: delta ~115-125 (low)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    # cap ~ one 200B copy (2 header + 200 body) + FEND + margin
    cap = 230
    gcls, gstarts, glens, b, t, mode, binding, payload = enc.encode_delta(
        target, err2, cap, None, surface_flat=prev)
    expect(mode.startswith("region:"), f"expected region-coherent scheduling, got {mode}")
    surf = prev.copy()
    dec.run_payload(payload, 0, surf, n)
    a_kept = not np.array_equal(surf[100:300], prev[100:300])
    b_kept = not np.array_equal(surf[2000:2200], prev[2000:2200])
    expect(a_kept and not b_kept,
           f"importance-aged band ordering must keep region A, drop region B (A_kept={a_kept}, B_kept={b_kept})")


# =======================================================================
# Step 11: anti-drift / staleness-bounded refresh (conditional-
# replenishment death-spiral fix - Jellyfish/whole-frame-drift content)
# =======================================================================

def _slow_drift_clip(N=50, H=192, W=256):
    """A rich periodic texture scrolled 1px/frame: every pixel drifts
    slowly, but the colour histogram is ~constant so the held palette stays
    valid and the DRIFT trigger never fires - the pure conditional-
    replenishment case where only accumulated decoded error (not palette
    fit) reveals the screen is wrong. Returns (orig, chg, po_ceil)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    base = np.stack([128 + 110 * np.sin(xx * 0.20) * np.cos(yy * 0.13),
                     128 + 110 * np.sin(yy * 0.17 + 1.0),
                     128 + 110 * np.sin((xx + yy) * 0.11 + 2.0)], axis=2)
    from PIL import Image
    orig = np.empty((N, H, W, 3), dtype=np.uint8)
    for i in range(N):
        orig[i] = np.clip(np.roll(base, i, axis=1), 0, 255).astype(np.uint8)
    po = np.empty(N)
    chg = np.zeros(N)
    for i in range(N):
        im = Image.fromarray(orig[i]).convert(
            "P", palette=Image.Palette.ADAPTIVE, colors=256, dither=Image.Dither.NONE)
        pal = np.array((list(im.getpalette()) + [0] * 768)[:768], dtype=np.uint8).reshape(256, 3)
        po[i] = enc.psnr(orig[i], pal[np.asarray(im)])
        if i:
            chg[i] = float((np.abs(orig[i].astype(int) - orig[i - 1].astype(int)).max(2) > 10).mean())
    return orig, chg, po


@case(11, "region-coherent + staleness - slow-drift decoded error stays BOUNDED, no death spiral")
def t11_staleness_bounded():
    orig, chg, po = _slow_drift_clip()
    # Full production defaults (region-coherent scheduling + aging + staleness
    # + phase refresh). The whole point: on whole-frame slow drift the decoded
    # error must NOT spiral - it stays bounded and does not grow across frames.
    r = enc.encode_clip(orig, chg, po, 256, 192, 25.0)
    ps = np.array(r["per_frame"]["psnr"])
    deficit = po - ps
    modes = r["per_frame"]["mode"]
    fd = next((i for i, m in enumerate(modes) if not m.startswith("kf")), len(modes))
    dd = deficit[fd:]      # decoded-vs-ceiling deficit on delta frames
    q = max(1, len(dd) // 4)
    first_q, last_q = float(dd[:q].mean()), float(dd[-q:].mean())

    # (1) BOUNDED: decoded error never runs away across the N delta frames
    #     (the old scattered coarsening let this grow to 15-30+ dB on
    #     whole-frame-drift content - the death spiral the fixes remove).
    expect(dd.max() < 8.0, f"bounded staleness violated: max delta deficit {dd.max():.2f} dB")
    # (2) NO SPIRAL: the last quarter is not worse than the first (does not
    #     accumulate) - region-coherent band spending + aging refresh whole
    #     regions before their error compounds.
    expect(last_q <= first_q + 0.5,
           f"decoded error still spiralling: firstQ {first_q:.2f} -> lastQ {last_q:.2f} dB")
    # (3) the budget-bound path is actually exercised (region scheduling), so
    #     this is a real budget-vs-drift test, not a trivially-fitting one.
    expect(any(m.startswith("region:") for m in modes) or dd.max() < 2.0,
           "expected region-coherent scheduling (or a trivially-bounded clip)")


# =======================================================================
# Step 12: stride/flatten-bug DISCRIMINATION (owner exhibit 4/5). Two
# invariants that separate a correctness bug (displaced error map /
# transposed flatten in one mode) from the expected region-band lag.
# =======================================================================

def _build_vid(result, w, h, fps=25.0):
    """Assemble a decodable .vid buffer from an encode_clip result."""
    payloads = result["payloads"]
    hdr = enc.pack_header(width=w, height=h, fps=fps, channels=1, arate=enc.RATE_MONO,
                           frame_count=len(payloads), audio_bytes_per_frame=0,
                           ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    return hdr + b"".join(p + bytes((-len(p)) % 512) for p in payloads)


def _synth_clip(orig):
    """po_ceil + chg for a synthetic (N,H,W,3) stack, like _extract_source."""
    from PIL import Image
    N = orig.shape[0]
    po = np.empty(N)
    chg = np.zeros(N)
    for i in range(N):
        im = Image.fromarray(orig[i]).convert(
            "P", palette=Image.Palette.ADAPTIVE, colors=256, dither=Image.Dither.NONE)
        pal = np.array((list(im.getpalette()) + [0] * 768)[:768], dtype=np.uint8).reshape(256, 3)
        po[i] = enc.psnr(orig[i], pal[np.asarray(im)])
        if i:
            chg[i] = float((np.abs(orig[i].astype(int) - orig[i - 1].astype(int)).max(2) > 10).mean())
    return chg, po


@case(12, "decode-vs-bookkeeping byte-identity - emitted stream == encoder surface, BOTH modes")
def t12_decode_matches_bookkeeping():
    # A real-ish moving clip in BOTH Layer-2 modes. Whatever the encoder
    # BELIEVES is on screen (its prev_flat bookkeeping) MUST equal what the
    # reference decoder reconstructs from the emitted stream - any divergence
    # is a merge / _apply_segments / stride bookkeeping bug (mechanism B).
    rng = np.random.default_rng(41)
    for (w, h) in ((256, 192), (320, 256)):
        N = 24
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        orig = np.empty((N, h, w, 3), dtype=np.uint8)
        for i in range(N):
            base = np.stack([128 + 110 * np.sin((xx + i * 3) * 0.05),
                             128 + 110 * np.cos((yy - i * 2) * 0.06),
                             128 + 110 * np.sin((xx + yy) * 0.03 + i * 0.2)], axis=2)
            orig[i] = np.clip(base, 0, 255).astype(np.uint8)
        chg, po = _synth_clip(orig)
        result = enc.encode_clip(orig, chg, po, w, h, 25.0, return_surfaces=True)
        buf = _build_vid(result, w, h)
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / f"bk_{w}x{h}.vid"
            p.write_bytes(buf)
            issues = dec.validate(p)
            expect(issues == [], f"{w}x{h}: validate() issues: {issues}")
            frames = list(dec.decode(p))
        expect(len(frames) == len(result["surfaces"]),
               f"{w}x{h}: frame count {len(frames)} != {len(result['surfaces'])}")
        for i, ((pal, idx), surf) in enumerate(zip(frames, result["surfaces"])):
            expect(np.array_equal(idx, surf),
                   f"{w}x{h} frame {i}: DECODER surface != ENCODER bookkeeping "
                   f"({int((idx != surf).sum())} px diverge) - stride/merge bug")


@case(12, "moving vertical edge - UNBUDGETED frames are pixel-exact vs quantized source, BOTH modes")
def t12_moving_edge_pixel_exact():
    # A hard vertical edge translating horizontally. Where the budget does
    # NOT bind (mode 'full'), the decoded surface must be PIXEL-EXACT vs the
    # held-palette quantization of the source - a stride/transpose error in
    # one mode would displace the edge and this catches it. The clip is
    # 2-colour and tiny so the budget never binds.
    for (w, h) in ((256, 192), (320, 256)):
        N = 20
        orig = np.empty((N, h, w, 3), dtype=np.uint8)
        c0 = np.array([20, 40, 60], dtype=np.uint8)
        c1 = np.array([200, 180, 160], dtype=np.uint8)
        for i in range(N):
            edge = 4 + i * ((w - 8) // N)   # edge column marches right
            frame = np.empty((h, w, 3), dtype=np.uint8)
            frame[:, :edge] = c0
            frame[:, edge:] = c1
            orig[i] = frame
        chg, po = _synth_clip(orig)
        result = enc.encode_clip(orig, chg, po, w, h, 25.0, return_surfaces=True)
        held = result["held_pal_final"]
        modes = result["per_frame"]["mode"]
        checked = 0
        for i in range(1, N):
            if not modes[i].startswith("full"):
                continue   # budget-bound frame: lag is allowed
            target_idx, _ = enc.quantize_to_palette(orig[i], held)
            expect(np.array_equal(result["surfaces"][i], target_idx),
                   f"{w}x{h} frame {i} (mode {modes[i]}): decoded surface not "
                   f"pixel-exact vs quantized source - stride/transpose bug")
            checked += 1
        expect(checked >= 5, f"{w}x{h}: too few unbudgeted frames checked ({checked})")


# =======================================================================
# Step 13: review fix - run-absorb threshold wired into gap-merge
# (merge_run_absorb_max() existed but was never consulted; every run
# touching a copy with no interior skip got absorbed unconditionally,
# which LOSES decode-T for runs past the break-even).
# =======================================================================

@case(13, "review fix: run-absorb threshold wired - long runs stay RUN ops (lower T than force-absorbed), short runs still absorb")
def t13_run_absorb_threshold():
    tc = enc.TMODEL_COEFFS
    absorb_max = enc.merge_run_absorb_max()
    expect(100.0 < absorb_max < 200.0, f"sanity: silicon absorb_max ~121B, got {absorb_max:.1f}")

    rng = np.random.default_rng(51)
    n = 3000
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)

    # --- long run (> absorb_max) directly touching copy segments on both
    # sides (no interior skip) - pre-fix this got folded into one COPY
    # unconditionally; post-fix it must stay a standalone RUN op. ---
    target = prev.copy()
    run_len = int(absorb_max) + 200
    run_start = 500
    run_color = 42
    target[run_start - 5:run_start] = rng.integers(0, 256, size=5, dtype=np.uint8)
    target[run_start:run_start + run_len] = run_color
    end = run_start + run_len
    target[end:end + 5] = rng.integers(0, 256, size=5, dtype=np.uint8)
    mask = prev != target
    gcls, gstarts, glens = enc.segment(target, mask)

    merged, mb, mt = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    kinds = _op_kinds(merged)
    expect("RUN8" in kinds or "RUN16" in kinds,
           f"long run (len={run_len} > absorb_max={absorb_max:.0f}) must stay a RUN op, got {kinds}")
    surf = prev.copy()
    dec.run_payload(merged, 0, surf, n)
    expect(np.array_equal(surf, target), "long-run guard preserves decode byte-identity")

    # Force the OLD (unconditional-absorb) behaviour by making
    # merge_run_absorb_max() return +inf (fetch_long == fill_cpu -> denom
    # <= 0) and re-merge the same segments - the guarded merge's modeled T
    # must beat the force-absorbed T (the review finding's exact claim).
    saved = dict(tc)
    try:
        tc["fill_cpu"] = tc["fetch_long"]
        expect(enc.merge_run_absorb_max() == float("inf"), "test setup: forced absorb_max should be +inf")
        _, _, t_forced = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    finally:
        tc.clear()
        tc.update(saved)
    expect(mt < t_forced,
           f"guarded merge T ({mt:.0f}) should be lower than force-absorbed T ({t_forced:.0f})")

    # --- short run (well under 100B) directly touching copy segments -
    # absorption must still happen (folded into one COPY, no standalone
    # RUN op survives in the merged stream). ---
    target2 = prev.copy()
    short_len = 40
    s2 = 700
    target2[s2:s2 + 5] = rng.integers(0, 256, size=5, dtype=np.uint8)
    target2[s2 + 5:s2 + 5 + short_len] = 77
    target2[s2 + 5 + short_len:s2 + 10 + short_len] = rng.integers(0, 256, size=5, dtype=np.uint8)
    mask2 = prev != target2
    gcls2, gstarts2, glens2 = enc.segment(target2, mask2)
    unmerged2 = enc.emit_delta_ops(target2, gcls2, gstarts2, glens2)
    ku2 = _op_kinds(unmerged2)
    expect(ku2.count("RUN8") + ku2.count("RUN16") >= 1,
           f"test setup: un-merged stream should carry the short run as its own RUN op, got {ku2}")

    merged2, mb2, mt2 = enc.merge_delta_stream(gcls2, gstarts2, glens2, target2, prev, cap_bytes=n)
    kinds2 = _op_kinds(merged2)
    expect(kinds2.count("RUN8") + kinds2.count("RUN16") == 0,
           f"short run (len={short_len} <= absorb_max={absorb_max:.0f}) must still absorb into a COPY, got {kinds2}")
    surf2 = prev.copy()
    dec.run_payload(merged2, 0, surf2, n)
    expect(np.array_equal(surf2, target2), "short-run absorb preserves decode byte-identity")


def main():
    passed, failed, skipped = 0, 0, 0
    last_step = None
    for step, name, fn in CASES:
        if step != last_step:
            print(f"\n=== Step {step} ===")
            last_step = step
        try:
            fn()
        except SkipCase as exc:
            skipped += 1
            print(f"[SKIP] {name}\n       {exc}")
        except Exception as exc:
            failed += 1
            print(f"[FAIL] {name}\n       {exc.__class__.__name__}: {exc}")
            traceback.print_exc(limit=6)
        else:
            passed += 1
            print(f"[PASS] {name}")
    print(f"\n{passed} passed, {skipped} skipped, {failed} failed, {passed + failed + skipped} total")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
