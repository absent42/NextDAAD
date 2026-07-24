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


@case(2, "reserved-op rejection ($09, $0B SCROLL) - raises in decode mode, recorded in validate mode")
def t2_reserved_op_rejection():
    for opcode in (0x09, enc.OP_SCROLL, 0x0C, 0xFF):
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
        print("  SKIP (Sintel source or ffmpeg not available)")
        return
    cuts = result["scene_cuts"]
    expect(len(result["kf_span_ranges"]) >= 1, "expected at least one keyframe span in a 4s cut-containing window")
    for (s, e) in result["kf_span_ranges"]:
        for c in cuts:
            expect(not (s < c < e), f"keyframe span ({s},{e}) straddles detected cut at frame {c}")


@case(5, "scene-scoped palette drift - stays under the trigger between refreshes (Sintel)")
def t5_drift_under_trigger():
    result = _encode_clip(SINTEL, 256, 192, 25.0, "00:00:01", "4")
    if result is None:
        print("  SKIP (Sintel source or ffmpeg not available)")
        return
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
        trunc = [m for m in result["per_frame"]["mode"] if m == "trunc"]
        expect(trunc == [], f"{clip.name} {w}x{h}@{fps}: {len(trunc)} truncated frame(s) - dual-budget cap failed to protect the budget")
    if not any_ran:
        print("  SKIP (demo sources or ffmpeg not available)")


@case(7, "ring/resident sizing + BuildReport + validate() full pass (both research clips)")
def t7_report_and_validate():
    if not SINTEL.exists() or not BBB.exists() or not FFMPEG.exists():
        print("  SKIP (demo sources or ffmpeg not available)")
        return
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
        print("  SKIP (Sintel source or ffmpeg not available)")
        return
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


def main():
    passed, failed = 0, 0
    last_step = None
    for step, name, fn in CASES:
        if step != last_step:
            print(f"\n=== Step {step} ===")
            last_step = step
        try:
            fn()
        except Exception as exc:
            failed += 1
            print(f"[FAIL] {name}\n       {exc.__class__.__name__}: {exc}")
            traceback.print_exc(limit=6)
        else:
            passed += 1
            print(f"[PASS] {name}")
    print(f"\n{passed} passed, {failed} failed, {passed + failed} total")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
