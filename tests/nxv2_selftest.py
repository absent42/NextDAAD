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
import inspect
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
        audio_bpf = 1250        # stereo@25 - within the v2.0 player
                                # bound pack_header now enforces (3c)
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


@case(1, "audio layout - NXV v2.0 player bound (1280B/frame half) enforced at encode time")
def t1_audio_player_bound():
    # The player's double-buffered audio feed caps real audio at
    # NXV_AUD_HALF = 1280 bytes/frame (open rejects more with VID
    # FMT?). audio_layout must refuse to lay out such an encode with
    # a named error - stereo needs fps > ~24.40, mono fps > ~18.22.
    # stereo 25 fps: 625*2 = 1250 <= 1280 - accepted
    rate, samples, real, padded = enc.audio_layout(25, 2)
    expect(real == 1250 and real <= enc.AUD_HALF, "stereo 25fps fits")
    # mono 20 fps: round(23325/20) = 1166 <= 1280 - accepted
    rate, samples, real, padded = enc.audio_layout(20, 1)
    expect(real == 1166 and real <= enc.AUD_HALF, "mono 20fps fits")
    # stereo 20 fps: round(15625/20)*2 = 1562 > 1280 - rejected with
    # the named floors and the --mono remedy (mono fits at 20)
    try:
        enc.audio_layout(20, 2)
    except SystemExit as e:
        msg = str(e)
        expect("1280" in msg, "error names the 1280-byte player bound")
        expect("24.40" in msg, "error names the stereo fps floor")
        expect("18.22" in msg, "error names the mono fps floor")
        expect("--mono" in msg, "error suggests --mono when mono fits")
    else:
        raise AssertionError("stereo 20fps must be rejected (1562 > 1280)")
    # floors are the boundary: just above passes, just below rejects
    expect(enc.audio_layout(24.40, 2)[2] <= enc.AUD_HALF, "stereo 24.40 fits")
    try:
        enc.audio_layout(24.39, 2)
    except SystemExit:
        pass
    else:
        raise AssertionError("stereo 24.39fps must be rejected")


@case(1, "streaming supply gate - silicon-calibrated (Card #3 VSTR0/VSTR1 anchors)")
def t1_stream_supply_gate():
    # A ring-streamed file must be PRODUCIBLE: mean decode wall time +
    # mean SD fetch time must fit the frame period (utilization <= 1.0
    # or nxv2enc.encode refuses to write). Anchors are the Card #3
    # silicon runs (2026-07-25): 007 classic HEALTHY at ~1.00, 008
    # full COLLAPSED at ~1.74 (65.5 ms frames, underrun every frame).
    clock = enc.TMODEL_COEFFS["clock_khz"]
    # silicon_r: measured composed-player ratios, cluster + interpolation
    expect(enc.silicon_r(256, 192) == enc.TMODEL_SILICON_R["flat_256"], "classic flat R")
    expect(enc.silicon_r(320, 256) == enc.TMODEL_SILICON_R["flat_320"], "full flat R")
    # Card #8 (2026-07-28): the two gapped rows SWAPPED ORDER on
    # re-measurement (h=192 R 1.258 vs h=144 R 1.118), which refutes the
    # 1/height slope rather than re-fitting it. silicon_r() no longer
    # interpolates - every gapped height gets the WORST measured gapped
    # R, sub-144 included (still unmeasured, still not extrapolated).
    worst_gapped = max(enc.TMODEL_SILICON_R["gapped_192"],
                       enc.TMODEL_SILICON_R["gapped_144"])
    expect(enc.silicon_r(320, 192) == worst_gapped,
           "gapped 192 takes the worst measured gapped R")
    expect(enc.silicon_r(320, 144) == worst_gapped,
           "gapped 144 takes the worst measured gapped R (no interpolation)")
    expect(enc.silicon_r(320, 100) == worst_gapped,
           "sub-144 gapped is unmeasured - worst measured R, never an extrapolation")
    expect(enc.silicon_r(256, 100) == enc.TMODEL_SILICON_R["flat_256"],
           "the gapped R must not leak into the flat 256 cluster")
    # BUSY IS TRUE DECODE WALL TIME (Card #8): silicon_r carries R's own
    # /af, so the gate divides by af again. These anchors state the
    # busy_ms they mean and back-solve mean_t through that identity, so
    # they stay pinned to the silicon figure and not to whatever
    # silicon_r currently holds.
    af = enc.TMODEL_COEFFS["audio_factor"]

    def _mean_t_for(busy_ms, width, height):
        return busy_ms * clock * af / enc.silicon_r(width, height)

    expect(abs(enc.stream_supply_check(_mean_t_for(20.0, 320, 256), 20000.0,
                                       1536, 25.0, 320, 256)["busy_ms"] - 20.0) < 1e-9,
           "busy_ms must be the true silicon decode time the anchor names")
    # VSTR1 anchor: the first 008 encode (mean demand 43520 B/f incl
    # 1536B audio pad, true decode 30.19 ms) is UNSTREAMABLE
    t8 = _mean_t_for(30.187, 320, 256)
    s8 = enc.stream_supply_check(t8, 43520.0, 1536, 25.0, 320, 256)
    expect(1.70 < s8["utilization"] < 1.80,
           f"008 anchor utilization {s8['utilization']:.2f} (silicon: collapsed)")
    expect(0.45 < s8["suggested_budget"] < 0.55, "008 suggestion ~0.51")
    # CARD #8 BRACKET (2026-07-28) - the two fixtures that were measured
    # end-to-end on silicon at THIS encoder generation, walked op-by-op
    # from the staged bytes. They bracket the true ceiling from both
    # sides, which is the whole basis of the corrected gate:
    #   008 sb0.51 - underran 914/1286 and 1141/1508 frames on two runs,
    #                ring pinned at depth 1 -> must be REFUSED
    #   009 sb0.54 - zero underruns, min ring depth 42 -> must be ADMITTED
    # The pre-Card #8 gate scored these 0.934 and 0.805: it admitted the
    # one that chronically failed.
    s008 = enc.stream_supply_check(357716.0, 28460.7, 1536, 25.0, 320, 256)
    expect(s008["utilization"] > 1.0,
           f"008 (silicon: 71-76% of frames underran) scores "
           f"{s008['utilization']:.3f} - the gate must refuse it")
    s009 = enc.stream_supply_check(310436.0, 23092.8, 1536, 25.0, 320, 192)
    expect(s009["utilization"] < 1.0,
           f"009 (silicon: zero underruns, min depth 42) scores "
           f"{s009['utilization']:.3f} - the gate must admit it")
    # ... and the corrected model reproduces 008's MEASURED frame time
    # (42.0/42.1 ms across the two runs) to better than 2%.
    predicted_008_ms = s008["busy_ms"] + s008["audio_ms"] + s008["sd_ms"]
    expect(abs(predicted_008_ms - 42.05) < 0.85,
           f"008 predicted frame {predicted_008_ms:.2f} ms vs 42.0/42.1 measured")
    # the AUDIO phase is a real serial term the gate used to omit
    expect(1.2 < s008["audio_ms"] < 1.5,
           f"audio copy term {s008['audio_ms']:.3f} ms (silicon: 20-21.6 ticks/frame)")
    # suggestion self-consistency: scaling busy + payload-SD by the
    # suggested budget lands the mean at STREAM_TARGET_UTIL (the audio
    # pad's fetch AND its copy cost are the invariant part)
    sug = s8["suggested_budget"]
    wire_eff = enc.SD_WIRE_BYTES_PER_MS * af
    audio_sd = 1536 / wire_eff
    scaled = ((s8["busy_ms"] + (s8["sd_ms"] - audio_sd)) * sug
              + audio_sd + s8["audio_ms"])
    expect(abs(scaled / s8["period_ms"] - enc.STREAM_TARGET_UTIL) < 0.01,
           "suggested budget lands the target utilization")
    # monotonicity: more demand can only raise utilization
    expect(enc.stream_supply_check(310436.0, 30000.0, 1536, 25.0, 320, 192)["utilization"]
           > s009["utilization"], "utilization monotonic in demand")


@case(1, "streaming supply gate - encode() end-to-end REFUSAL (no file "
         "written) and admit just below util 1.0")
def t1_stream_supply_gate_e2e():
    # t1_stream_supply_gate above pins stream_supply_check() itself
    # against the silicon anchors. This case pins the WIRING around it:
    # nxv2enc.encode() must actually call the gate, raise SystemExit
    # with the stream-supply message and write NOTHING when a projected
    # encode would exceed util 1.0, and must admit (write the file,
    # report util < 1.0) an operating point just under the line. Uses a
    # synthetic clip/parameters (no ffmpeg, no demo source) by
    # monkeypatching the two internal seams encode() calls by bare name
    # - _extract_source (ffmpeg/PIL extraction) and encode_clip (the
    # numpy delta pipeline) - so the test is fast and exercises the real
    # encode() gate/header/file-write code path exactly as videnc.py
    # drives it.
    width, height, fps = 256, 192, 25.0
    nframes = 50
    payload_len = 30000                      # bytes, fixed per frame
    abytes_real = 1250                       # stereo@25 (within the
    abytes_pad = 1536                        # 1280 player bound the 3c
                                             # pack_header defence now
                                             # enforces on every writer)
    channels, rate = 2, enc.RATE_STEREO
    payload_blocks = (payload_len + 511) // 512
    mean_demand = abytes_pad + payload_blocks * 512
    projected_total = enc.HEADER_SIZE + nframes * mean_demand
    expect(projected_total > enc.STREAM_RESIDENT_POOL_B,
           "fixture must exceed the resident pool to exercise the gate at all")

    # Binary-search mean_t (the modeled decode T/frame the gate would
    # compute) for the util==1.0 boundary using stream_supply_check
    # itself - the same function encode()'s gate calls - so the
    # refuse/admit split below is derived, not hand-guessed.
    lo_t, hi_t = 1.0, 5_000_000.0
    for _ in range(60):
        mid_t = (lo_t + hi_t) / 2.0
        u = enc.stream_supply_check(mid_t, mean_demand, abytes_pad, fps,
                                    width, height)["utilization"]
        if u < 1.0:
            lo_t = mid_t
        else:
            hi_t = mid_t
    admit_t = lo_t            # utilization just under 1.0
    refuse_t = hi_t * 1.20    # comfortably over 1.0

    admit_util = enc.stream_supply_check(admit_t, mean_demand, abytes_pad,
                                         fps, width, height)["utilization"]
    refuse_util = enc.stream_supply_check(refuse_t, mean_demand, abytes_pad,
                                          fps, width, height)["utilization"]
    expect(0.90 < admit_util < 1.0, f"admit boundary util {admit_util:.4f} not just below 1.0")
    expect(refuse_util > 1.0, f"refuse fixture util {refuse_util:.4f} not above 1.0")

    def fake_extract_source(src_path, w, h, fps_val, start, duration, ffmpeg, dither,
                            mono, dither_mode=None, retime=None):
        return dict(orig=np.zeros((1, h, w, 3), dtype=np.uint8),
                    chg=np.zeros(1), po_ceil=np.zeros(1),
                    audio_bytes=bytes(nframes * abytes_real),
                    channels=channels, rate=rate,
                    abytes_real=abytes_real, abytes_pad=abytes_pad,
                    nframes=nframes)

    def make_fake_encode_clip(mean_t):
        def fake_encode_clip(orig, chg, po_ceil, w, h, fps_val, **kw):
            per_frame = dict(bytes=[payload_len] * nframes,
                              psnr=[40.0] * nframes,
                              mode=["full"] * nframes,
                              binding=["none"] * nframes,
                              drift=[0.0] * nframes,
                              t=[mean_t] * nframes)
            return dict(payloads=[bytes(payload_len)] * nframes,
                        kf_span_ranges=[(0, 0)], per_frame=per_frame,
                        scene_cuts=[], kf_events=1, staleness_events=0)
        return fake_encode_clip

    real_extract_source = enc._extract_source
    real_encode_clip = enc.encode_clip
    try:
        enc._extract_source = fake_extract_source

        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / "refuse.vid"
            enc.encode_clip = make_fake_encode_clip(refuse_t)
            try:
                enc.encode("dummy.mp4", str(out_path), shape=(width, height), fps=fps)
            except SystemExit as e:
                msg = str(e)
                expect("cannot stream" in msg, f"refusal message missing 'cannot stream': {msg!r}")
                expect(f"{refuse_util:.2f}" in msg or "utilization" in msg,
                       f"refusal message missing utilization figure: {msg!r}")
            else:
                raise AssertionError("over-budget synthetic encode did not raise SystemExit")
            expect(not out_path.exists(), "refused encode must leave no output file")

        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / "admit.vid"
            enc.encode_clip = make_fake_encode_clip(admit_t)
            report = enc.encode("dummy.mp4", str(out_path), shape=(width, height), fps=fps)
            expect(out_path.exists(), "admitted encode must write its output file")
            expect(out_path.stat().st_size > 0, "admitted encode's output file must be non-empty")
            expect(report.stream_checked, "admitted encode must have run the supply gate")
            expect(report.stream_utilization < 1.0,
                   f"admitted encode utilization {report.stream_utilization:.4f} must be < 1.0")
    finally:
        enc._extract_source = real_extract_source
        enc.encode_clip = real_encode_clip


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
    total_budget_bound = 0
    worst_psnr_overall = float("inf")
    for clip, w, h, fps in combos:
        result = _encode_clip(clip, w, h, fps, None, "3")
        if result is None:
            continue
        any_ran = True
        pf = result["per_frame"]
        # Region-coherent scheduling replaced the greedy-truncation fallback:
        # a budget-bound frame keeps whole contiguous bands ("region:K/N").
        # The dual-budget guarantee holds as long as no frame is FULLY starved
        # (region:0 - not even one band fits), which a single cheap band never
        # is. Assert no fully-starved frame (the catastrophic case).
        starved = [m for m in pf["mode"] if m.startswith("region:0/")]
        expect(starved == [], f"{clip.name} {w}x{h}@{fps}: {len(starved)} fully-starved frame(s) - dual-budget scheduling failed to keep any content")
        total_budget_bound += sum(1 for bd in pf["binding"] if bd == "budget")
        psnr_arr = np.array(pf["psnr"])
        if len(psnr_arr):
            worst_psnr_overall = min(worst_psnr_overall, float(psnr_arr.min()))
    if not any_ran:
        skip("demo sources or ffmpeg not available")
    # SP15 T5 close-out review finding: starved==[] alone is unfalsifiable
    # (an all-skip frame always fits region:0, so the assertion above never
    # fails regardless of whether the budget path ever actually engages).
    # Prove the guarantee is tested UNDER pressure, not in its absence - at
    # least one of the four combos must genuinely hit the budget-bound path.
    # Measured this review (2026-07-26): Sintel 256x192 never binds budget,
    # but Sintel 320x256 (17/75 frames), BBB 256x192 (23/75) and BBB 320x256
    # (71/75) all do.
    expect(total_budget_bound > 0,
           "no combo hit the budget-bound path - zero-truncation guarantee is untested under pressure")
    # worst_psnr floor: re-derived under the wire-true pipeline (review
    # fix-wave 2026-07-27, nearest-lattice snap + corrected DITHER_AMP -
    # dcc2230/5b47727 review). Measured worst across these four fixtures
    # is now 4.02 dB (Sintel 320x256@25, an early hidden-keyframe-span
    # transition frame - not the budget path; was 4.28 dB under the OLD
    # pre-fix pal9 pipeline - the corrected dither amplitude trades a
    # little raw PSNR for banding removal, so wire-true worst moved
    # DOWN, not up). Floor left at 3.5 (NOT raised - wire-true worst
    # only widened, did not shrink, the headroom, now ~0.52 dB) so
    # routine noise doesn't trip it while a real regression (keyframe-
    # span or budget-scheduling defect) still does. Re-verified under
    # the 2026-07-28 blue-noise wave (32x32 void-and-cluster tile,
    # default amplitude 0.5): the full suite passes with the floor
    # unchanged.
    expect(worst_psnr_overall > 3.5,
           f"worst PSNR {worst_psnr_overall:.2f} below the SP15 T5 floor (measured 4.02 this review)")


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
        # Both clips are unstreamable at the 1.00 ceiling (BBB full was
        # the Card #3 VSTR1 finding; Sintel classic joined it when the
        # palette-collapse fix's dithered targets raised delta demand),
        # so each needs an operating point under the gate.
        #
        # AUTO-DERIVED rather than pinned (Card #8, 2026-07-28). This
        # case carried hand-derived budgets (0.88 / 0.51) that had to be
        # re-derived by hand every time the T model or the gate moved -
        # and the Card #8 gate correction refuses both. The budget is
        # not what this case is about (ring/resident sizing, BuildReport
        # fields, validate()), so it now rides the encoder's own search,
        # which is the shipping default and cannot go stale.
        for clip, shape_name, (w, h) in (
                (SINTEL, "256x192", (256, 192)),
                (BBB, "320x256", (320, 256))):
            out = Path(td) / f"{clip.stem}_{shape_name}.vid"
            report = enc.encode(str(clip), str(out), shape=(w, h), fps=25.0,
                                 quality_profile="max", start=None, duration="5",
                                 ffmpeg=str(FFMPEG), stream_budget=None)
            expect(report.frames > 0, "BuildReport.frames > 0")
            expect(report.shape == (w, h), "BuildReport.shape")
            expect(out.stat().st_size % 512 == 0, "output file is a 512B block multiple")
            expect(out.stat().st_size == report.total_bytes, "BuildReport.total_bytes matches file size")
            expect(15.0 < report.mean_psnr < 50.0, f"mean PSNR {report.mean_psnr} outside sane bounds")
            expect(report.keyframes >= 1, "at least one keyframe (startup)")
            expect(report.stream_checked, "5s encodes exceed the resident pool - gate must have run")
            expect(report.stream_utilization <= 1.0,
                   f"admitted encode utilization {report.stream_utilization:.2f} > 1.0")
            issues = dec.validate(out)
            expect(issues == [], f"{clip.name} {w}x{h}: validate() found issues: {issues}")
            print(f"  [{clip.stem} {w}x{h}@25] frames={report.frames} bytes={report.total_bytes} "
                  f"mean/worst PSNR={report.mean_psnr:.2f}/{report.worst_psnr:.2f} "
                  f"kf={report.keyframes} s/MB={report.seconds_per_mb:.2f} "
                  f"stream_util={report.stream_utilization:.2f} "
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
    # SP17: the mem-to-mem DMA COPY terms. task-2-final-settlement.md
    # measured these (CD1..CD4 chunk solve 1091.8 T/chunk; KF-vs-CD3
    # cross-row solve 5.31 T/B unarmed) but they were never wired in -
    # the model priced EVERY copy as LDI, ~2.1x over the silicon cost of
    # a 256 B copy, on the DOMINANT op class.
    expect(tc["copy_dma_setup"] == 1091.8, f"copy_dma_setup should be the silicon 1091.8, got {tc['copy_dma_setup']}")
    expect(tc["copy_dma_per_b"] == 5.31, f"copy_dma_per_b should be the silicon UNARMED 5.31, got {tc['copy_dma_per_b']}")
    expect(tc["copy_dma_chunk"] == 256, "copy DMA chunk must be the 256 B audio-safety cap (NXV2_DMA_CHUNK)")
    # The two kernel-select thresholds, DERIVED 2026-07-28 from the same
    # settlement rows (break-even = setup/(cpu_rate - dma_rate)):
    # fill 849.4/(17.17-5.11) = 70.43 -> 71; copy 1091.8/(20.25-5.31)
    # = 73.08 -> 74. They MIRROR src/nextdaad.inc NXV2_RUN_DMA_MIN /
    # NXV2_COPY_DMA_MIN - if these pins fail because the player moved,
    # the model moved with it or it has desynchronised from the player.
    expect(tc["copy_dma_min"] == 74, "copy DMA threshold must be the PLAYER's NXV2_COPY_DMA_MIN (74)")
    expect(tc["run_dma_min"] == 71, "fill DMA threshold must be the PLAYER's NXV2_RUN_DMA_MIN (71)")
    expect(tc["t_frame_fixed"] == 1132.0, "t_frame_fixed should be the silicon FE 1132")
    # Shape given explicitly (320x256, flat): composition_factor()'s
    # unknown-shape default is the pessimistic gapped factor now (fail-
    # safe fix), so a bare no-shape call here would not read the flat
    # cap - pin the flat baseline against the real flat shape instead.
    # 1120000*0.85/1.14 = 835087.7 (Card #8 re-fit; was 952000 at 1.00)
    expect(abs(enc.usable_budget_t(25.0, 320, 256) - 835087.7) < 1.0,
           f"silicon usable budget @25 (flat 320x256) should be 835087.7 T, got {enc.usable_budget_t(25.0, 320, 256)}")
    # Composed-player safety factor, RE-FITTED on silicon at the SP17 T
    # model (Card #8, 2026-07-28). The restored mem-to-mem DMA copy term
    # made the model ~15% cheaper, so every measured R rose and both
    # factors lost their margin: flat 0.898 -> 1.021 against a 1.00
    # factor, dense gapped 1.023 -> 1.258 against a 1.15 one - and 003
    # duly missed its frame period on silicon (678 ticks vs 625). The
    # rule is unchanged, worst-in-class x 1.12: flat 1.021 -> 1.14,
    # gapped 1.258 -> 1.41. Pinned here so a coefficient re-fit cannot
    # silently drop the de-rating that keeps a clip inside one period.
    cf = enc.TMODEL_COMPOSITION_FACTOR
    expect(cf["flat"] == 1.14, f"flat composition factor should be 1.14, got {cf['flat']}")
    expect(cf["gapped"] == 1.41, f"gapped composition factor should be 1.41, got {cf['gapped']}")
    # the de-rating must still BE a de-rating, and must still exceed the
    # worst measured R in each class (margin, not a coincidence). The
    # gapped height ORDER is deliberately not asserted - Card #8 inverted
    # it, which is why silicon_r() stopped interpolating.
    expect(cf["gapped"] > max(enc.TMODEL_SILICON_R["gapped_144"],
                              enc.TMODEL_SILICON_R["gapped_192"]),
           "gapped factor must carry margin over the worst measured gapped R")
    expect(cf["flat"] > max(enc.TMODEL_SILICON_R["flat_256"],
                            enc.TMODEL_SILICON_R["flat_320"]),
           "flat factor must carry margin over the worst measured flat R")
    expect(enc.is_gapped(320, 192) and enc.is_gapped(320, 144),
           "mode-1 sub-256 heights are gapped")
    expect(not enc.is_gapped(320, 256) and not enc.is_gapped(256, 144)
           and not enc.is_gapped(256, 192),
           "mode-1 full height and ALL mode-0 heights are flat (row-linear)")
    # The budget must actually de-rate for a gapped shape, and not for a
    # flat one - the whole point of threading the shape through.
    expect(abs(enc.usable_budget_t(25.0, 320, 256) - 835087.7) < 1.0,
           "flat 320x256 keeps the flat 835087.7 T budget")
    expect(abs(enc.usable_budget_t(25.0, 256, 144) - 835087.7) < 1.0,
           "flat 256x144 keeps the flat 835087.7 T budget")
    gb = enc.usable_budget_t(25.0, 320, 192)
    # Independent literal, not re-derived from the 1.41 constant above -
    # a coefficient/factor typo that moved both numbers together would
    # otherwise still pass this assertion. 1120000*0.85/1.41 = 675177.3
    expect(abs(gb - 675177.3) < 1.0,
           f"gapped 320x192 budget should be 675177.3 T, got {gb:.0f}")
    # Fail-safe default (nxv2enc.composition_factor): an unset/unknown
    # shape must resolve to the pessimistic gapped factor, not the
    # optimistic flat one.
    expect(abs(enc.usable_budget_t(25.0) - 675177.3) < 1.0,
           f"unknown-shape budget should fail safe to the gapped 675177.3 T, got {enc.usable_budget_t(25.0):.0f}")
    # ... and the keyframe chunk planner must shrink with it (a kf chunk
    # is one long COPY straight down the paint order - it crosses every
    # column boundary the gapped surface has).
    expect(enc.kf_chunk_budget_bytes(25.0, True, 320, 192)
           < enc.kf_chunk_budget_bytes(25.0, True, 320, 256),
           "gapped keyframe chunks must be smaller than flat ones")
    # ... and that de-rating must propagate into the PLAN, not just the
    # per-chunk budget. Asserted on the plan's shape rather than on its
    # chunk COUNT: at the Card #5 factor (1.15) a 61,440 B span happens
    # to need 2 chunks either way, so a count comparison would test
    # where an integer boundary falls, not whether the de-rating
    # applies. Chunk count must never DROP, and the first (budget-sized)
    # chunk must be strictly smaller - that is the contract.
    gap_plan = enc.plan_kf_chunks(320 * 192, 25.0, 320, 192)
    flat_plan = enc.plan_kf_chunks(320 * 192, 25.0, 320, 256)
    expect(len(gap_plan) >= len(flat_plan),
           "a gapped keyframe span never needs FEWER chunks than a flat one")
    expect(gap_plan[0][1] < flat_plan[0][1],
           f"the gapped plan's first chunk must be smaller: "
           f"{gap_plan[0][1]} !< {flat_plan[0][1]}")
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


@case(10, "copy/fill T model - DMA terms gated on the PLAYER's derived kernel thresholds")
def t10_copy_dma_model():
    tc = enc.TMODEL_COEFFS
    rate = tc["fetch_long"]
    setup, per_b, chunk, thr = (tc["copy_dma_setup"], tc["copy_dma_per_b"],
                                tc["copy_dma_chunk"], tc["copy_dma_min"])
    # RULE 1 - below the player's threshold the copy body is pure LDI.
    # The model predicts what the PLAYER DOES (src/video.asm vid_copy_body
    # takes vid_copy_ldi under NXV2_COPY_DMA_MIN).
    for L in (1, 16, 64, 73):
        expect(abs(enc._copy_t(L, rate) - L * rate) < 1e-6,
               f"copy body of {L} B (< {thr}) must be priced as CPU/LDI, got {enc._copy_t(L, rate):.1f}")
    # RULE 1b - the threshold SITS ON the break-even (2026-07-28
    # derivation, src/nextdaad.inc: 1091.8/(20.25-5.31) = 73.08 -> 74),
    # so the player's choice is the cheap one at every length. Pinned as
    # a distance so it self-retunes with the coefficients: the constant
    # in the .inc must stay the ceiling of setup/(cpu_rate - dma_rate).
    # It was 90 before the derivation - 16 B late, and the 74-89 band
    # paid up to +237.8 T of LDI for nothing.
    breakeven = setup / (rate - per_b)
    expect(abs(thr - breakeven) <= 1.5,
           f"copy threshold {thr} must sit on the break-even {breakeven:.2f} B "
           "(re-derive NXV2_COPY_DMA_MIN and this coefficient together)")
    for L in range(1, thr):
        expect(L * rate <= setup + L * per_b + 1e-9,
               f"below the threshold LDI must be the CHEAPER kernel, fails at {L} B")
    # RULE 2 - at/above the threshold: the DMA price, which the player is
    # committed to (no min() floor - see _copy_t).
    for L in (74, 128, 200, 255, 256):
        dma = setup + L * per_b
        expect(abs(enc._copy_t(L, rate) - dma) < 1e-6,
               f"copy body of {L} B must be the DMA price, got {enc._copy_t(L, rate):.1f}")
    expect(abs(enc._copy_t(256, rate) - (setup + 256 * per_b)) < 1e-6,
           "a full 256 B chunk is priced at one DMA setup + 256 B of transfer")
    # RULE 3 - with the threshold ON the break-even the kernel switch is
    # no longer a cost DISCONTINUITY: a copy must never get cheaper by
    # getting longer (that was the old threshold's signature - an 89 -> 90
    # B copy used to cost LESS), and the step across the threshold must be
    # under one byte of LDI.
    prev = 0.0
    for L in range(1, 601):
        cur = enc._copy_t(L, rate)
        expect(cur >= prev - 1e-9,
               f"copy body price must not FALL as length grows: {L - 1} B "
               f"{prev:.1f} -> {L} B {cur:.1f}")
        prev = cur
    expect(enc._copy_t(thr, rate) - enc._copy_t(thr - 1, rate) < rate,
           "the step across the kernel threshold must be under one byte of LDI")
    # RULE 4 - multi-chunk: full 256 B chunks go DMA, a sub-threshold tail
    # goes LDI (the player re-selects per chunk).
    expect(abs(enc._copy_t(300, rate) - ((setup + chunk * per_b) + 44 * rate)) < 1e-6,
           "a 300 B copy = one DMA chunk + a 44 B LDI tail")
    expect(abs(enc._copy_t(2 * chunk, rate) - 2 * (setup + chunk * per_b)) < 1e-6,
           "a 512 B copy = two DMA chunks")
    # RULE 5 - the restored term must never make copy MORE expensive than
    # the old all-LDI model anywhere, and must be materially cheaper on
    # the dominant large-copy class (256 B: 5171 T modelled vs ~2451 T on
    # silicon - the ~2.1x over-price this test exists to prevent).
    for L in (1, 63, 89, 90, 256, 1024, 65535):
        expect(enc._copy_t(L, rate) <= L * rate + 1e-6,
               f"the DMA term may only ever LOWER the {L} B copy price")
    expect(abs((256 * rate) / enc._copy_t(256, rate) - 2.11) < 0.05,
           f"a 256 B copy body was over-priced ~2.11x, got "
           f"{(256 * rate) / enc._copy_t(256, rate):.2f}x")
    # RULE 6 - agreement with the silicon rows the coefficients came from.
    # CD3 (dma copy, 256 B chunks) measured 9.84 T/B over 1024 B ops;
    # the KF row (43008 B COPY16, DMA256) measured 12.2 T/B ARMED, which
    # de-rates to ~10.4 unarmed. Body-only rates, dispatch excluded.
    expect(abs(enc._copy_t(1024, rate) / 1024 - 9.84) < 0.5,
           f"1024 B copy body should sit on CD3's 9.84 T/B, got {enc._copy_t(1024, rate) / 1024:.2f}")
    expect(9.0 < enc._copy_t(43008, rate) / 43008 < 10.6,
           f"43008 B copy body should sit near the KF row's unarmed rate, "
           f"got {enc._copy_t(43008, rate) / 43008:.2f}")
    # RULE 7 - the gate is coefficient-driven, not hardcoded: move the
    # player's threshold and the pricing must follow it.
    saved = dict(enc.TMODEL_COEFFS)
    try:
        enc.TMODEL_COEFFS["copy_dma_min"] = 1024
        expect(abs(enc._copy_t(256, rate) - 256 * rate) < 1e-6,
               "raising copy_dma_min must push a 256 B copy back onto the CPU price")
    finally:
        enc.TMODEL_COEFFS.clear()
        enc.TMODEL_COEFFS.update(saved)
    expect(abs(enc._copy_t(256, rate) - (setup + 256 * per_b)) < 1e-6,
           "coefficients restored")
    # RULE 8 - the FILL model is gated the same way, on the player's own
    # NXV2_RUN_DMA_MIN (src/video.asm vid_run_body re-selects per chunk),
    # with the threshold on its own derived break-even
    # 849.4/(17.17-5.11) = 70.43 -> 71. Before 2026-07-28 _fill_t took a
    # bare min(cpu, dma) over the WHOLE length, which priced a 300 B fill
    # as two DMA setups when the player really runs one DMA chunk and a
    # CPU tail.
    fcpu, fsetup, fper = tc["fill_cpu"], tc["fill_dma_setup"], tc["fill_dma_per_b"]
    fchunk, fthr = tc["fill_dma_min"], tc["run_dma_min"]
    fbreakeven = fsetup / (fcpu - fper)
    expect(abs(fthr - fbreakeven) <= 1.5,
           f"fill threshold {fthr} must sit on the break-even {fbreakeven:.2f} B "
           "(re-derive NXV2_RUN_DMA_MIN and this coefficient together)")
    for L in (1, 16, 64, fthr - 1):
        expect(abs(enc._fill_t(L) - L * fcpu) < 1e-6,
               f"fill body of {L} B (< {fthr}) must be priced as unrolled CPU fill")
        expect(L * fcpu <= fsetup + L * fper + 1e-9,
               f"below the threshold CPU fill must be the CHEAPER kernel, fails at {L} B")
    for L in (fthr, 128, 255, fchunk):
        expect(abs(enc._fill_t(L) - (fsetup + L * fper)) < 1e-6,
               f"fill body of {L} B must be one DMA setup + transfer, got {enc._fill_t(L):.1f}")
    expect(abs(enc._fill_t(300) - ((fsetup + fchunk * fper) + 44 * fcpu)) < 1e-6,
           "a 300 B fill = one DMA chunk + a 44 B CPU tail (the player re-selects per chunk)")
    expect(abs(enc._fill_t(2 * fchunk) - 2 * (fsetup + fchunk * fper)) < 1e-6,
           "a 512 B fill = two DMA chunks")
    saved = dict(enc.TMODEL_COEFFS)
    try:
        enc.TMODEL_COEFFS["run_dma_min"] = 1024
        expect(abs(enc._fill_t(256) - 256 * fcpu) < 1e-6,
               "raising run_dma_min must push a 256 B fill back onto the CPU price")
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
    fit) reveals the screen is wrong. Returns (orig, chg, po_ceil).

    po_ceil (review MAJOR 2 fix, 2026-07-27): built via enc.display_ceiling,
    same as _synth_clip (:1259-1272) - a REACHABLE display-pipeline ceiling
    (dithered, lattice-snapped), not a 24-bit ADAPTIVE ceiling that sits
    above anything the display pipeline can reach (which would either make
    t11_staleness_bounded vacuous - the deficit gate never binds - or
    thrash the staleness/drift trigger into per-frame keyframes)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    base = np.stack([128 + 110 * np.sin(xx * 0.20) * np.cos(yy * 0.13),
                     128 + 110 * np.sin(yy * 0.17 + 1.0),
                     128 + 110 * np.sin((xx + yy) * 0.11 + 2.0)], axis=2)
    orig = np.empty((N, H, W, 3), dtype=np.uint8)
    for i in range(N):
        orig[i] = np.clip(np.roll(base, i, axis=1), 0, 255).astype(np.uint8)
    po = np.empty(N)
    chg = np.zeros(N)
    for i in range(N):
        po[i] = enc.display_ceiling(orig[i])
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
    """po_ceil + chg for a synthetic (N,H,W,3) stack, like _extract_source
    (palette-collapse fix: the ceiling lives in DISPLAY space, exactly as
    _extract_source computes it - a 24-bit ADAPTIVE ceiling would sit
    several dB above anything the display pipeline can reach and thrash
    the drift trigger into per-frame keyframes)."""
    N = orig.shape[0]
    po = np.empty(N)
    chg = np.zeros(N)
    for i in range(N):
        po[i] = enc.display_ceiling(orig[i])
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
            target_idx, _ = enc.dither_quantize(orig[i], held)
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

@case(13, "review fix: run-absorb threshold wired - long runs stay RUN ops (far fewer bytes than force-absorbed), short runs still absorb")
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
    # <= 0) and re-merge the same segments.
    saved = dict(tc)
    try:
        tc["fill_cpu"] = tc["fetch_long"]
        expect(enc.merge_run_absorb_max() == float("inf"), "test setup: forced absorb_max should be +inf")
        _, b_forced, t_forced = enc.merge_delta_stream(gcls, gstarts, glens, target, prev, cap_bytes=n)
    finally:
        tc.clear()
        tc.update(saved)
    # THE TRADE (SP17). Before the T model carried a mem-to-mem DMA copy
    # term, absorbing re-priced the run's body at the 20.2 T/B LDI rate
    # and the guard SAVED decode T outright - the review finding's
    # original claim, and what this case used to assert. With copy bodies
    # now priced at 1091.8 T/chunk + 5.31 T/B the arithmetic INVERTS at
    # this length: absorbing is a few hundred T cheaper, so a pure-T
    # reading would push the crossover from ~121 B out past 700 B.
    #
    # The guard is kept regardless, and this case now pins the reason:
    # what it costs is decode T (noise), what it buys is WIRE BYTES (the
    # binding constraint on every streamed fixture - spec E2). Absorbing
    # a run turns 3-4 opcode bytes into L literal bytes.
    expect(mb < b_forced / 2,
           f"the guard's whole point is bytes: guarded {mb} B must be far under "
           f"the force-absorbed {b_forced} B")
    wire_ms_saved = (b_forced - mb) / enc.SD_WIRE_BYTES_PER_MS
    decode_ms_cost = max(mt - t_forced, 0.0) / enc.TMODEL_COEFFS["clock_khz"]
    expect(wire_ms_saved > 5 * decode_ms_cost,
           f"the guard must buy far more frame time than it spends: "
           f"{wire_ms_saved:.3f} ms of wire saved vs {decode_ms_cost:.3f} ms of decode spent")

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


# =======================================================================
# Step 11 (SP15 3c): direct-serve preset + pack_header defence-in-depth
# =======================================================================

def _synthetic_ex(n, width, height, seed=7, cut_at=None):
    """Build the ex dict _encode_direct consumes, without ffmpeg."""
    rng = np.random.default_rng(seed)
    # blocky content (quantizes losslessly enough to be stable)
    orig = np.repeat(np.repeat(
        rng.integers(0, 255, size=(n, height // 8, width // 8, 3), dtype=np.uint8),
        8, axis=1), 8, axis=2)
    chg = np.zeros(n)
    if cut_at is not None:
        chg[cut_at] = 0.9      # over CUT_T with impulse -> a scene cut
    abytes_real = 1250
    abytes_pad = 1536
    audio = bytes(rng.integers(0, 256, size=n * abytes_real, dtype=np.uint8))
    return dict(orig=orig, chg=chg, audio_bytes=audio, channels=2,
                rate=enc.RATE_STEREO, abytes_real=abytes_real,
                abytes_pad=abytes_pad, nframes=n)


@case(11, "pack_header defence-in-depth - audio bytes over the 1280 player bound rejected")
def t11_pack_header_bound():
    try:
        enc.pack_header(width=256, height=192, fps=25, channels=2,
                        arate=enc.RATE_STEREO, frame_count=1,
                        audio_bytes_per_frame=enc.AUD_HALF + 1,
                        ring_start_margin_blocks=0, per_frame_cap_blocks=1)
    except ValueError as e:
        expect("1280" in str(e), "error names the 1280 player bound")
        expect("VID FMT" in str(e), "error names the player refusal")
    else:
        raise AssertionError("pack_header must reject 1281 audio bytes/frame")
    # the bound itself is legal
    hdr = enc.pack_header(width=256, height=192, fps=25, channels=2,
                          arate=enc.RATE_STEREO, frame_count=1,
                          audio_bytes_per_frame=enc.AUD_HALF,
                          ring_start_margin_blocks=0, per_frame_cap_blocks=1)
    expect(len(hdr) == 512, "1280 exactly is accepted")


def _walk_ops(payload):
    """Return the op list of a raw payload (structure only)."""
    ops, p = [], 0
    while p < len(payload):
        op = payload[p]; p += 1
        ops.append(op)
        if op in (enc.OP_FEND, enc.OP_KFLIP):
            break
        if op == enc.OP_KSTART:
            continue
        if op == enc.OP_PAL:
            p += 512
        elif op == enc.OP_COPY8:
            p += 1 + payload[p]
        elif op == enc.OP_COPY16:
            n = int.from_bytes(payload[p:p + 2], "little"); p += 2 + n
        elif op == enc.OP_RUN8:
            p += 2
        elif op == enc.OP_RUN16:
            p += 3
        elif op == enc.OP_SKIP8:
            p += 1
        elif op == enc.OP_SKIP16:
            p += 2
        else:
            raise AssertionError(f"unexpected op {op:02X} in a direct payload")
    return ops


@case(11, "direct-serve encode - all-literal container, flags bit1, nxv2dec byte-exact")
def t11_direct_serve():
    import tempfile as tf
    # TIGHTEN (Card #5, 2026-07-26): the gate is unconditional - there
    # is no accept_slow override any more, so this container-structure
    # case (the all-literal composition, flags bit1, nxv2dec byte-
    # exactness) must use a shape that is ACTUALLY at-rate under the
    # strict gate. classic-wide 256x144 @25 stereo (1.075) would now be
    # refused outright; 256x128 (raw 32768 B, under the 34298 B budget)
    # keeps the height a clean multiple of 8 for this helper's blocky
    # synthetic content. The gate itself (refusal + its envelope
    # message) is tested in t11_direct_gate below.
    n, width, height = 6, 256, 128
    ex = _synthetic_ex(n, width, height, cut_at=3)
    with tf.TemporaryDirectory() as td:
        out = Path(td) / "direct.vid"
        report = enc._encode_direct(ex, width, height, 25.0, out)
        expect(report.mode == "direct", "report mode")
        expect(report.frames == n, "frame count")
        buf = out.read_bytes()
        hdr = enc.unpack_header(buf)
        expect(hdr["flags"] & enc.FLAG_DIRECT_SERVE, "direct-serve hint set")
        expect(hdr["flags"] & enc.FLAG_DELTA_STREAM, "delta bit still set")
        expect(len(buf) % 512 == 0, "whole 512B blocks")
        issues = dec.validate(out)
        expect(issues == [], f"validate clean, got {issues}")
        # every frame: KSTART [PAL] COPY* KFLIP - literal-only
        pos = enc.HEADER_SIZE
        pal_frames = []
        for i in range(n):
            pos += ex["abytes_pad"]
            ops = _walk_ops(buf[pos:])
            expect(ops[0] == enc.OP_KSTART, f"f{i} opens with KSTART")
            expect(ops[-1] == enc.OP_KFLIP, f"f{i} closes with KFLIP")
            body = [o for o in ops[1:-1] if o != enc.OP_PAL]
            expect(all(o in (enc.OP_COPY8, enc.OP_COPY16) for o in body),
                   f"f{i} body is literal-only, got {[hex(o) for o in body]}")
            if enc.OP_PAL in ops:
                pal_frames.append(i)
            # advance pos past this frame's payload blocks
            plen = _payload_len(buf, pos)
            pos += ((plen + 511) // 512) * 512
        expect(pal_frames == [0, 3], f"PAL on scene starts only, got {pal_frames}")
        # decoded output is pixel-exact vs the encoder's own quantize
        frames = list(dec.decode(out))
        expect(len(frames) == n, "decoded frame count")
        cuts = [3]
        bounds = [0] + cuts + [n]
        fi = 0
        for s_i, e_i in zip(bounds[:-1], bounds[1:]):
            pal = enc.scene_palette(ex["orig"], s_i, e_i)
            for i in range(s_i, e_i):
                # mirrors _encode_direct: dithered target
                idx, _ = enc.dither_quantize(ex["orig"][i], pal)
                dpal, dimg = frames[fi]
                expect(np.array_equal(dimg, idx), f"f{fi} indexed pixel-exact")
                fi += 1
        # header cap covers the worst payload
        expect(hdr["per_frame_cap_blocks"] >= 1, "cap present")


def _payload_len(buf, pos):
    """Length in bytes of the payload starting at pos (walk to the
    terminal op) - mirrors _walk_ops but returns the byte length."""
    p = pos
    while True:
        op = buf[p]; p += 1
        if op in (enc.OP_FEND, enc.OP_KFLIP):
            return p - pos
        if op == enc.OP_KSTART:
            continue
        if op == enc.OP_PAL:
            p += 512
        elif op == enc.OP_COPY8:
            p += 1 + buf[p]
        elif op == enc.OP_COPY16:
            n = int.from_bytes(buf[p:p + 2], "little"); p += 2 + n
        elif op == enc.OP_RUN8:
            p += 2
        elif op == enc.OP_RUN16:
            p += 3
        elif op == enc.OP_SKIP8:
            p += 1
        elif op == enc.OP_SKIP16:
            p += 2
        else:
            raise AssertionError(f"unexpected op {op:02X}")


@case(11, "direct-serve wire gate - TIGHTEN: unconditional refusal, no accept-slow escape")
def t11_direct_gate():
    import tempfile as tf
    import inspect
    ex = _synthetic_ex(2, 320, 256)
    with tf.TemporaryDirectory() as td:
        out = Path(td) / "toobig.vid"
        try:
            enc._encode_direct(ex, 320, 256, 25.0, out)
        except SystemExit as e:
            msg = str(e)
            expect("direct-serve" in msg, "error names the mode")
            expect("utilization" in msg, "error names the utilization")
            expect("stereo" in msg and "mono" in msg,
                   "refusal states the envelope for BOTH channel counts (the full menu)")
            expect("accept-slow" not in msg.lower(),
                   "refusal must not mention a slow-playback override that no longer exists")
            expect(not out.exists(), "no file written on refusal")
        else:
            raise AssertionError("320x256@25 direct must be refused "
                                 "(raw 81920 B/frame over the wire)")
    # DIRECT TRANSPORT RECALIBRATION (Card #5, 2026-07-26): the first
    # silicon rows measured 663.4/663.6 ticks/frame on VDIR/VDIRL =
    # 917 B/ms delivered against the 1100 B/ms the 3c gate assumed.
    # The factor is pinned, and so is the row it reproduces.
    expect(enc.DIRECT_TRANSPORT_FACTOR == 1.20,
           f"direct transport factor should be the silicon 1.20, got {enc.DIRECT_TRANSPORT_FACTOR}")
    mean_frame = 1536 + 73 * 512          # 010's ordinary (no-PAL) section
    ds = enc.direct_supply_check(mean_frame, 25.0)
    expect(abs(ds["sd_ms"] - 42.44) < 0.05,
           f"the recalibrated model must reproduce VDIR's 42.456 ms/frame, got {ds['sd_ms']:.3f}")
    # classic-wide@25 stereo (the ORIGINALLY shipped 010 shape) is NOT
    # at-rate - this is exactly the shape the TIGHTEN ruling refuses
    # outright, with no override available at any layer.
    worst = 1536 + 74 * 512               # + the scene-start PAL block
    expect(1.05 < enc.direct_supply_check(worst, 25.0)["utilization"] < 1.10,
           "classic-wide@25 direct scores ~1.075 under the recalibrated gate - "
           "over 1.00, so it must now be refused unconditionally")
    # the recalibrated at-rate envelope, and its monotonicity
    raw25 = enc.direct_max_raw_bytes(25.0, 2, 1.0)
    expect(34000 < raw25 < 34600, f"25fps stereo direct tops out ~34.3 KB raw, got {raw25}")
    expect(enc.direct_supply_check(
        1536 + ((raw25 + 518 + 511) // 512) * 512, 25.0)["utilization"] <= 1.0,
        "direct_max_raw_bytes must actually pass its own gate")
    expect(enc.direct_max_raw_bytes(18.22, 1, 1.0) > raw25,
           "a lower fps / mono admits a bigger direct surface")
    # 010/011's chosen re-encode point (256x133@25 stereo) must actually
    # be at-rate under the gate - the positive-path complement to the
    # 320x256 refusal above.
    ok_worst = 1536 + ((256 * 133 + 518 + 511) // 512) * 512
    expect(enc.direct_supply_check(ok_worst, 25.0)["utilization"] <= 1.0,
           "256x133@25 stereo (the 010/011 TIGHTEN re-encode shape) must pass the gate")

    # TIGHTEN (Card #5, 2026-07-26 owner ruling): the accept-slow escape
    # is REMOVED, not just unused - assert it no longer exists anywhere
    # in the encoder plumbing, and that the wire gate cannot be talked
    # past by any flag.
    expect(not hasattr(enc, "DIRECT_ACCEPT_SLOW_MAX"),
           "DIRECT_ACCEPT_SLOW_MAX must not exist - no bounded override either")
    direct_params = inspect.signature(enc._encode_direct).parameters
    expect("direct_accept_slow" not in direct_params,
           "_encode_direct must not accept a slow-accept override kwarg")
    encode_params = inspect.signature(enc.encode).parameters
    expect("direct_accept_slow" not in encode_params,
           "encode() must not accept a slow-accept override kwarg")
    try:
        enc._encode_direct(ex, 320, 256, 25.0, out, direct_accept_slow=True)
    except TypeError:
        pass
    else:
        raise AssertionError("_encode_direct must reject an unknown "
                             "direct_accept_slow kwarg outright")
    # ... and at the CLI: --direct-accept-slow must be gone, and an
    # over-wire direct encode must be refused REGARDLESS of any flags
    # thrown at it (there is no flag left that changes the verdict).
    import subprocess
    help_proc = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), "--help"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    expect("--direct-accept-slow" not in help_proc.stdout.decode("utf-8", "replace"),
           "--direct-accept-slow must not appear in videnc.py --help")
    if SINTEL.exists() and FFMPEG.exists():
        with tf.TemporaryDirectory() as td:
            # (a) the removed flag itself: argparse must reject it before
            # the encoder ever runs.
            out2 = Path(td) / "over_wire.vid"
            cmd = [sys.executable, str(LIB / "videnc.py"), str(SINTEL), str(out2),
                   "--shape", "classic-wide", "--fps", "25", "--duration", "1",
                   "--direct", "--direct-accept-slow", "--ffmpeg", str(FFMPEG)]
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            expect(proc.returncode != 0,
                   "an over-wire --direct encode with an (unrecognized) "
                   "--direct-accept-slow flag must still fail")
            expect(not out2.exists(), "no file written")
            stderr = proc.stderr.decode("utf-8", "replace")
            expect("unrecognized arguments" in stderr or "--direct-accept-slow" in stderr,
                   f"argparse should reject the removed flag, got:\n{stderr}")
            # (b) REGARDLESS OF FLAGS: even with only the flags that DO
            # still exist (no accept-slow at all), the same over-wire
            # shape must be refused by the wire gate itself, not just
            # by argparse rejecting an unknown flag.
            out3 = Path(td) / "over_wire_plain.vid"
            cmd2 = [sys.executable, str(LIB / "videnc.py"), str(SINTEL), str(out3),
                    "--shape", "classic-wide", "--fps", "25", "--duration", "1",
                    "--direct", "--ffmpeg", str(FFMPEG)]
            proc2 = subprocess.run(cmd2, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            expect(proc2.returncode != 0,
                   "classic-wide@25 stereo --direct (util 1.075) must be "
                   "refused with no other flags in play")
            expect(not out3.exists(), "no file written on the plain-flag refusal")
            stderr2 = proc2.stderr.decode("utf-8", "replace")
            expect("utilization" in stderr2 and "direct-serve" in stderr2,
                   f"the plain refusal must be the wire-gate message, got:\n{stderr2}")


@case(11, "direct-serve gate refusal - mono-floor menu entry hardened "
          "against the Fraction-rounding knife-edge (Card #5 review fix)")
def t11_direct_gate_mono_floor_menu():
    # Review finding: min_fps_for(1) is, BY CONSTRUCTION, the exact fps
    # where audio_layout's real mono bytes/frame lands on the AUD_HALF
    # boundary. Which side of the boundary Fraction rounding falls on
    # there is a coin flip only a few ULP wide - a raise there inside
    # the refusal-message builder (direct_max_raw_bytes -> audio_layout)
    # would surface as an unrelated SystemExit ("... exceeds the NXV
    # v2.0 player's per-frame audio bound ...") out of what should be
    # the direct-serve wire-gate refusal. The fix rounds the floor UP
    # to the nearest 0.01 fps (math.ceil(...*100)/100, the same idiom
    # audio_layout's own "fits" floors already use) before feeding it
    # back through direct_max_raw_bytes.
    import math as _m
    mono_floor = enc.min_fps_for(1)
    # demonstrate the knife-edge is real: a few ULP below the exact
    # floor flips audio_layout's verdict (samples 1280 -> 1281, one
    # over AUD_HALF) and direct_max_raw_bytes raises unguarded.
    unlucky = mono_floor - 1e-6
    try:
        enc.direct_max_raw_bytes(unlucky, 1, 1.0)
    except SystemExit:
        pass
    else:
        raise AssertionError("test setup: expected the floor minus an "
                             "ULP to demonstrate the raise this case "
                             "guards against")
    # the fix's guard: rounding UP first, at the floor itself AND at
    # the unlucky perturbation, must render without raising either way.
    for fps in (mono_floor, unlucky):
        safe = _m.ceil(fps * 100) / 100
        m_floor_at = enc.direct_max_raw_bytes(safe, 1, 1.0)
        expect(m_floor_at > 0,
               f"direct_max_raw_bytes at the rounded mono floor "
               f"({safe}) must not raise, got {m_floor_at}")
    # end-to-end: the real refusal path (320x256@25, same shape the
    # sibling gate case above refuses) must render the mono-floor menu
    # entry using this same guarded computation - not just be correct
    # in isolation.
    import tempfile as tf
    ex = _synthetic_ex(2, 320, 256)
    with tf.TemporaryDirectory() as td:
        out = Path(td) / "toobig_monofloor.vid"
        try:
            enc._encode_direct(ex, 320, 256, 25.0, out)
        except SystemExit as e:
            msg = str(e)
            expect("mono floor" in msg,
                   f"refusal names the mono-floor envelope entry, got:\n{msg}")
            expect("player's per-frame audio bound" not in msg,
                   f"the mono-floor menu computation must not leak an "
                   f"audio_layout error into the refusal, got:\n{msg}")
            expect(not out.exists(), "no file written on refusal")
        else:
            raise AssertionError("320x256@25 direct must be refused")


@case(12, "review fix: no-audio-source probe skips extraction (no raw "
          "ffmpeg stderr leak), silence bytes unchanged")
def t12_no_audio_source_probe():
    import videnc as vv
    # probe_has_audio regex, pinned against synthetic ffmpeg -i banners
    # (no ffmpeg process needed - stderr= bypasses the subprocess call).
    expect(vv.probe_has_audio(None, None,
           stderr="  Stream #0:1(und): Audio: aac (LC) ...") is True,
           "an audio stream line must be detected")
    expect(vv.probe_has_audio(None, None,
           stderr="  Stream #0:0(und): Video: h264 ...") is False,
           "a video-only banner must report no audio")

    # end-to-end: the real video-only fixture must skip extraction
    # entirely (one informative note, no raw ffmpeg extraction stderr)
    # and still fall back to the same silence bytes as before.
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("Sintel source or ffmpeg not available")
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        ex = enc._extract_source(SINTEL, 256, 192, 25.0, "00:00:01", "1",
                                  str(FFMPEG), dither=False, mono=False)
    captured = buf.getvalue()
    expect("no audio stream" in captured,
           f"expected the one-line no-audio note, got: {captured!r}")
    expect(captured.count("no audio stream") == 1,
           f"expected exactly one note line, got: {captured!r}")
    for scary in ("QT chapter track", "does not contain any stream",
                  "Error opening output files", "Invalid argument"):
        expect(scary not in captured,
               f"raw ffmpeg extraction stderr leaked ({scary!r}): {captured!r}")
    expect(len(ex["audio_bytes"]) > 0, "silence fallback must still be non-empty")
    expect(all(b == enc.SILENCE_U8 for b in ex["audio_bytes"]),
           "audio bytes must be the unchanged SILENCE_U8 fill")


# =======================================================================
# Step 13: blue-noise dither + amplitude knob (2026-07-28 wave - the
# 32x32 void-and-cluster tile replaces 8x8 Bayer; --dither scales it)
# =======================================================================

@case(13, "blue-noise table integrity - 32x32 permutation, deterministic, tiles")
def t13_bluenoise_table_integrity():
    bn = enc.BLUENOISE32
    expect(bn.shape == (32, 32), f"table shape {bn.shape} != (32, 32)")
    expect(sorted(bn.ravel().tolist()) == list(range(1024)),
           "table is not a permutation of 0..1023 (histogram not exactly uniform)")
    # Position determinism: the same frame dithers identically on every
    # call (no runtime randomness anywhere - hard format requirement).
    rng = np.random.default_rng(7)
    f = rng.integers(0, 256, size=(48, 80, 3), dtype=np.uint8)
    a = enc.ordered_dither(f, 1.0)
    b = enc.ordered_dither(f, 1.0)
    expect((a == b).all(), "ordered_dither is not deterministic")
    # Tiling: the offset is a pure function of (y mod 32, x mod 32) -
    # on a constant-colour frame the output must repeat with period 32
    # in both axes.
    const = np.full((64, 64, 3), 128, dtype=np.uint8)
    d = enc.ordered_dither(const, 1.0)
    expect((d[:32, :32] == d[32:, :32]).all() and (d[:32, :32] == d[:32, 32:]).all()
           and (d[:32, :32] == d[32:, 32:]).all(),
           "dither offsets do not tile with period 32")
    # Same offset on all three channels (no hue noise), as before.
    di = d.astype(np.int16) - 128
    expect((di[..., 0] == di[..., 1]).all() and (di[..., 1] == di[..., 2]).all(),
           "per-channel offsets differ - hue noise introduced")


@case(13, "dither amplitude scaling - 0 = pure snap, 1 = full step, 0.5 = half")
def t13_amplitude_scaling():
    step = enc.DITHER_STEP
    expect(abs(step - 255.0 / 7.0) < 1e-9, "DITHER_STEP must be the lattice bin 255/7")
    const = np.full((32, 32, 3), 128, dtype=np.uint8)
    # amp 0: frame passes through untouched -> quantization is the pure
    # nearest-level snap.
    z = enc.ordered_dither(const, 0.0)
    expect((z == const).all(), "amplitude 0 must leave the frame unchanged")
    rng = np.random.default_rng(11)
    f = rng.integers(0, 256, size=(32, 32, 3), dtype=np.uint8)
    expect((enc.snap_to_lattice(enc.ordered_dither(f, 0.0)) == enc.snap_to_lattice(f)).all(),
           "amplitude 0 must reduce to the pure nearest-lattice snap")
    # amp 1: offsets span one full quantization step across the tile
    # (integer truncation costs at most ~2 codes of the span).
    d1 = enc.ordered_dither(const, 1.0).astype(np.int16)
    span1 = int(d1.max() - d1.min())
    expect(abs(span1 - step) <= 2.0,
           f"amplitude 1 span {span1} not ~one step ({step:.1f})")
    # amp 0.5 (the default): half a step.
    dh = enc.ordered_dither(const, 0.5).astype(np.int16)
    spanh = int(dh.max() - dh.min())
    expect(abs(spanh - step / 2) <= 2.0,
           f"amplitude 0.5 span {spanh} not ~half a step ({step / 2:.1f})")


@case(13, "dither amplitude default - 0.5, legacy args normalize, bad values refused")
def t13_amplitude_default():
    expect(enc.DITHER_AMP_DEFAULT == 0.5, "default amplitude must be 0.5")
    rng = np.random.default_rng(13)
    f = rng.integers(0, 256, size=(32, 48, 3), dtype=np.uint8)
    expect((enc.ordered_dither(f) == enc.ordered_dither(f, 0.5)).all(),
           "no-argument dither must equal the 0.5 default")
    # legacy boolean --dither (the old accepted-for-compatibility flag)
    # and None all mean the default - never 0.0/1.0.
    for legacy in (None, False, True):
        expect(enc._dither_amp(legacy) == enc.DITHER_AMP_DEFAULT,
               f"_dither_amp({legacy!r}) must normalize to the default")
    expect(enc._dither_amp(0.25) == 0.25, "a float passes through")
    for bad in (-0.1, 1.5):
        try:
            enc._dither_amp(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"_dither_amp({bad}) must refuse out-of-range values")


@case(13, "dither amplitude threading e2e - non-default --dither reaches "
          "both pipelines through encode(), mirrored at that amplitude")
def t13_amplitude_threading_e2e():
    # Reviewer gap (bf27725 follow-up): the three sibling t13 cases pin
    # ordered_dither/_dither_amp in ISOLATION, but nothing proved a
    # non-default amplitude survives the trip through the real encode()
    # entry point into every pipeline site. The regressions this case
    # exists to catch:
    #   (a) encode() dropping its dither= kwarg before handing off to
    #       _encode_direct / encode_clip (nxv2enc.py 2486/2494/2500);
    #   (b) _encode_direct's scene_palette(..., amplitude=dither_amp)
    #       or its quantize_to_palette(ordered_dither(orig[i],
    #       dither_amp), ...) silently reverting to the 0.5 default
    #       (nxv2enc.py 2323/2326);
    #   (c) encode_clip's frame_dith / kf_pal sites likewise
    #       (nxv2enc.py 2061/2121).
    # Any of those would leave the rest of the suite green today:
    # t11_direct_serve mirrors its reconstruction at the DEFAULT
    # amplitude only, so a drop to the default is invisible to it.
    # Follows the t1_stream_supply_gate_e2e precedent: _extract_source
    # is monkeypatched (no ffmpeg) so encode()'s own threading, gates,
    # header and file writing all run for real.
    import tempfile as tf

    width, height, n, fps = 256, 128, 4, 25.0   # t11's at-rate direct shape
    AMP = 1.0                                    # clearly non-default (0.5)

    # Gradient content: smooth ramps sit BETWEEN lattice levels almost
    # everywhere, so the dither amplitude genuinely moves quantization
    # results - flat/blocky content could quantize identically at every
    # amplitude and make the wire-difference assertions below vacuous.
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    orig = np.empty((n, height, width, 3), dtype=np.uint8)
    for f in range(n):
        r = (xx + yy + f * 7.0) * (255.0 / (width + height))
        g = (xx * 1.3 + f * 5.0) * (255.0 / width)
        b = (yy * 1.7 + f * 3.0) * (255.0 / height)
        orig[f] = np.clip(np.stack([r, g, b], axis=-1), 0.0, 255.0).astype(np.uint8)
    chg = np.zeros(n)
    for f in range(1, n):
        d = np.abs(orig[f].astype(np.int16) - orig[f - 1].astype(np.int16)).max(axis=2)
        chg[f] = float((d > 10).mean())
    abytes_real, abytes_pad = 1250, 1536         # stereo@25, as t11
    audio = bytes([(i * 37) & 0xFF for i in range(n * abytes_real)])

    # Setup sanity (anti-vacuity): this fixture IS amplitude-sensitive -
    # under one shared palette the amp-1.0 and default dithered targets
    # quantize to differing indices, so identical wire bytes below can
    # only mean the amplitude never arrived.
    pal_probe = enc.scene_palette(orig, 0, n)    # default amplitude
    idx_amp, _ = enc.dither_quantize(orig[0], pal_probe, AMP)
    idx_def, _ = enc.dither_quantize(orig[0], pal_probe, None)
    expect(int(np.count_nonzero(idx_amp != idx_def)) > 0,
           "test setup: gradient fixture must quantize differently at "
           "amp 1.0 vs the default or every assertion below is vacuous")

    def fake_extract_source(src_path, w, h, fps_val, start, duration,
                            ffmpeg, dither, mono, dither_mode=None, retime=None):
        # honours its dither argument exactly as the real extractor
        # does: po_ceil is measured at the encode's own amplitude/mode
        amp = enc._dither_amp(dither)
        po = np.array([enc.display_ceiling(orig[i], amplitude=amp,
                                           mode=dither_mode)
                       for i in range(n)])
        return dict(orig=orig, po_ceil=po, chg=chg, audio_bytes=audio,
                    channels=2, rate=enc.RATE_STEREO,
                    abytes_real=abytes_real, abytes_pad=abytes_pad,
                    nframes=n)

    real_extract = enc._extract_source
    try:
        enc._extract_source = fake_extract_source
        with tf.TemporaryDirectory() as td_s:
            td = Path(td_s)

            def run(name, **kw):
                out = td / name
                enc.encode("dummy.mp4", str(out), shape=(width, height),
                           fps=fps, **kw)
                return out.read_bytes()

            # the real entry point, both pipelines, both amplitudes
            direct_amp = run("d_amp.vid", direct=True, dither=AMP)
            direct_def = run("d_def.vid", direct=True)
            stream_amp = run("s_amp.vid", dither=AMP)
            stream_def = run("s_def.vid")

            # determinism control: a re-run at the default is byte-
            # identical, so any amp-vs-default difference below is the
            # amplitude's doing and nothing else's.
            expect(run("d_def2.vid", direct=True) == direct_def,
                   "direct encode must be deterministic at a fixed amplitude")
            expect(run("s_def2.vid") == stream_def,
                   "streaming encode must be deterministic at a fixed amplitude")

            # catches (a)+(b): amplitude reached the direct-serve sites
            expect(direct_amp != direct_def,
                   "direct-serve wire bytes must differ between --dither "
                   "1.0 and the default - amplitude dropped before "
                   "_encode_direct's scene_palette/quantize sites")
            # catches (a)+(c): amplitude reached the streaming/delta sites
            expect(stream_amp != stream_def,
                   "streaming wire bytes must differ between --dither 1.0 "
                   "and the default - amplitude dropped before "
                   "encode_clip's dither_quantize/kf_pal sites")

            # Stronger: mirrored reconstruction AT the non-default
            # amplitude (t11_direct_serve's mirror with AMP threaded
            # through). Catches sites 2323 and 2326 INDIVIDUALLY -
            # a palette built at the wrong amplitude or a target
            # dithered at the wrong amplitude each desynchronizes the
            # decoded indices from this independent reconstruction.
            frames = list(dec.decode(td / "d_amp.vid"))
            expect(len(frames) == n, "decoded frame count")
            cuts = [c for c in enc.detect_scene_cuts(chg) if 0 < c < n]
            expect(cuts == [], "test setup: fixture must be one scene")
            pal = enc.scene_palette(orig, 0, n, amplitude=AMP)
            for i in range(n):
                idx, _ = enc.dither_quantize(orig[i], pal, AMP)
                dpal, dimg = frames[i]
                expect(np.array_equal(dimg, idx),
                       f"f{i} indexed pixel-exact at amplitude {AMP}")

            # Falsifiability: SIMULATE the regression via monkeypatch
            # (nxv2enc.py untouched). Every amplitude consumer bottoms
            # out in ordered_dither (offset mode) or mixture_planner
            # (mixture mode) - quantize targets directly, display_ceiling
            # via dither_quantize - so blinding BOTH to the amplitude IS
            # the "silently fell back to the default" regression at every
            # pipeline site at once, whichever mode is default. Under it,
            # a --dither 1.0 encode must collapse byte-identically onto
            # the default encode on BOTH paths - proving the
            # wire-difference assertions above would fail (i.e. catch the
            # drop), not pass by accident.
            real_od, real_mp = enc.ordered_dither, enc.mixture_planner

            def dropped_amplitude_od(frame, amplitude=None):
                return real_od(frame, enc.DITHER_AMP_DEFAULT)

            def dropped_amplitude_mp(pal, amplitude=None):
                return real_mp(pal, enc.DITHER_AMP_DEFAULT)

            try:
                enc.ordered_dither = dropped_amplitude_od
                enc.mixture_planner = dropped_amplitude_mp
                expect(run("d_regr.vid", direct=True, dither=AMP) == direct_def,
                       "regression sim: an amplitude-blind direct encode "
                       "must equal the default encode byte-for-byte "
                       "(else this case could not catch the drop)")
                expect(run("s_regr.vid", dither=AMP) == stream_def,
                       "regression sim: an amplitude-blind streaming "
                       "encode must equal the default encode byte-for-byte")
            finally:
                enc.ordered_dither = real_od
                enc.mixture_planner = real_mp
    finally:
        enc._extract_source = real_extract


# =======================================================================
# Step 13 (SP17 Yliluoma wave, 2026-07-28): gamma-correct mixing,
# luminance-weighted colour distance, and Yliluoma positional MIXTURE
# dithering (algorithm 2) - the cases that pin the article's formulas
# and this encoder's hard invariants under the new path.
# =======================================================================

@case(13, "gamma-correct mixing - Yliluoma's formula verbatim, 50/50 "
          "black/white lands at 186 not 128")
def t13_gamma_mix_formula():
    g = enc.GAMMA
    expect(abs(g - 2.2) < 1e-12, f"GAMMA must be 2.2, got {g}")
    black = np.zeros(3, dtype=np.uint8)
    white = np.full(3, 255, dtype=np.uint8)
    # The article's own worked example: a gamma-UNAWARE 50/50 mix of
    # black and white gives 128, which is too bright for what the eye
    # integrates; the gamma-aware mix is (0.5)^(1/2.2)*255.
    want = int(round((0.5 ** (1.0 / g)) * 255.0))
    got = enc.gamma_mix(black, white, 0.5)
    expect(want == 186, f"reference value drifted: {want}")
    expect((got == want).all(), f"gamma_mix 50/50 black/white = {got}, want {want}")
    expect(int(got[0]) > 128, "gamma-aware mix must not equal the naive 128")
    # Endpoints are exact, and the general formula holds channelwise for
    # arbitrary colours and ratios: a' = a^g, b' = b^g,
    # r' = a' + (b'-a')*ratio, r = r'^(1/g).
    rng = np.random.default_rng(2207)
    a = rng.integers(0, 256, size=(64, 3), dtype=np.uint8)
    b = rng.integers(0, 256, size=(64, 3), dtype=np.uint8)
    expect((enc.gamma_mix(a, b, 0.0) == a).all(), "ratio 0 must return a")
    expect((enc.gamma_mix(a, b, 1.0) == b).all(), "ratio 1 must return b")
    for ratio in (0.125, 0.5, 0.75):
        la = (a.astype(np.float64) / 255.0) ** g
        lb = (b.astype(np.float64) / 255.0) ** g
        want_v = np.rint(((la + (lb - la) * ratio) ** (1.0 / g)) * 255.0)
        got_v = enc.gamma_mix(a, b, ratio).astype(np.float64)
        # from_linear() is a 4096-step LUT of the same curve
        expect(np.abs(got_v - want_v).max() <= 1.0,
               f"gamma_mix deviates from the article formula at ratio "
               f"{ratio}: max {np.abs(got_v - want_v).max()}")
    # And the mixture planner's achieved colours are gamma-correct: a
    # 50/50 plan over a black/white palette must report ~186, never 128.
    pal = np.zeros((256, 3), dtype=np.uint8)
    pal[1] = 255
    grey = np.full((32, 32, 3), 186, dtype=np.uint8)
    _, tgt = enc.MixturePlanner(pal, 1.0).plan(grey)
    expect(abs(int(tgt[0, 0, 0]) - 186) <= 3,
           f"plan target for a 50/50 black/white mix = {tgt[0, 0, 0]}, "
           f"want ~186 (a gamma-blind planner would report ~128)")


@case(13, "RGBL colour distance - the article's formula, and the 4-D "
          "embedding _nearest uses is exactly equivalent")
def t13_rgbl_metric():
    rng = np.random.default_rng(587)
    a = rng.integers(0, 256, size=(512, 3)).astype(np.float64)
    b = rng.integers(0, 256, size=(512, 3)).astype(np.float64)
    # the article, verbatim
    luma1 = (a[:, 0] * 299 + a[:, 1] * 587 + a[:, 2] * 114) / (255.0 * 1000)
    luma2 = (b[:, 0] * 299 + b[:, 1] * 587 + b[:, 2] * 114) / (255.0 * 1000)
    lumadiff = luma1 - luma2
    dr = (a[:, 0] - b[:, 0]) / 255.0
    dg = (a[:, 1] - b[:, 1]) / 255.0
    db = (a[:, 2] - b[:, 2]) / 255.0
    want = (dr ** 2 * 0.299 + dg ** 2 * 0.587 + db ** 2 * 0.114) * 0.75 + lumadiff ** 2
    got = enc.color_compare(a, b)
    expect(np.abs(got - want).max() < 1e-6,
           f"color_compare deviates from the article: max "
           f"{np.abs(got - want).max():.3e}")
    expect(float(enc.color_compare(a, a).max()) == 0.0, "self-distance must be 0")
    # Luminance weighting is real: an equal-magnitude GREEN error must
    # cost more than a BLUE one (0.587 vs 0.114), which plain Euclidean
    # RGB cannot express.
    base = np.array([[120.0, 120.0, 120.0]])
    d_green = enc.color_compare(base, base + np.array([[0.0, 40.0, 0.0]]))
    d_blue = enc.color_compare(base, base + np.array([[0.0, 0.0, 40.0]]))
    expect(float(d_green[0]) > float(d_blue[0]) * 2.0,
           f"green error {float(d_green[0]):.5f} must dominate blue "
           f"{float(d_blue[0]):.5f}")
    # The embedding _nearest() solves in must reproduce it exactly, or
    # the nearest-colour search is not the metric it claims to be.
    ea, eb = enc._rgbl_embed(a), enc._rgbl_embed(b)
    emb_d = np.sum((ea - eb) ** 2, axis=1)
    expect(np.abs(emb_d - want).max() < 1e-5,
           f"4-D embedding is not isometric to color_compare: max "
           f"{np.abs(emb_d - want).max():.3e}")
    # _nearest_rgbl must therefore pick the RGBL-nearest entry on a
    # case where the two metrics disagree...
    # entry 0 is a LARGE blue error (cheap in RGBL, expensive in RGB),
    # entry 1 a SMALLER green error (expensive in RGBL, cheap in RGB)
    cb = np.array([[120, 140, 180], [120, 168, 120]], dtype=np.uint8)
    q = np.array([[120, 140, 120]], dtype=np.uint8)
    expect(int(enc._nearest_rgbl(q, cb)[0]) == 0,
           "_nearest_rgbl did not use the luminance-weighted metric")
    # ...and the DEFAULT solver must NOT: the shipped nearest-palette
    # search stays on plain squared-RGB, on measurement (see the RGBL
    # block in nxv2enc: swapping it lost 0.36-1.85 dB per-pixel AND
    # 0.9-3.0 dB local-mean PSNR on every leg fixture). Pinned so the
    # perceptual metric cannot leak into the default path unnoticed.
    expect(int(enc._nearest(q, cb)[0]) == 1,
           "the default _nearest must stay plain squared-Euclidean RGB")
    expect(enc.HYSTERESIS_EPS == 150.0,
           "the default hysteresis deadzone must stay in squared-RGB units")


@case(13, "mixture dither is POSITIONAL - output is a pure function of "
          "(x mod 32, y mod 32, colour, palette); no frame/neighbour state")
def t13_mixture_positional_determinism():
    rng = np.random.default_rng(1993)
    pal = enc.display_palette(rng.integers(0, 256, size=(64, 64, 3), dtype=np.uint8))
    H, W = 64, 96
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    frame = np.clip(np.stack([xx * 2.4, yy * 3.1, (xx + yy) * 1.7], -1),
                    0, 255).astype(np.uint8)
    a, _ = enc.dither_quantize(frame, pal)
    b, _ = enc.dither_quantize(frame, pal)
    expect(np.array_equal(a, b), "mixture dither is not deterministic")
    # TILING: a constant-colour frame must repeat with period 32 in both
    # axes - i.e. position enters ONLY as (x mod 32, y mod 32).
    const = np.full((64, 64, 3), 100, dtype=np.uint8)
    c, _ = enc.dither_quantize(const, pal)
    expect((c[:32, :32] == c[32:, :32]).all() and (c[:32, :32] == c[:32, 32:]).all()
           and (c[:32, :32] == c[32:, 32:]).all(),
           "mixture dither does not tile with period 32")
    # TRANSLATION EQUIVARIANCE by a whole tile: shifting the content 32
    # px right must shift the indices 32 px right and change nothing
    # else. Error diffusion, frame counters or neighbour feedback all
    # break this - and any of them would break delta compression.
    shifted = np.roll(frame, 32, axis=1)
    d, _ = enc.dither_quantize(shifted, pal)
    expect(np.array_equal(d, np.roll(a, 32, axis=1)),
           "mixture dither is not translation-equivariant on the tile "
           "period - it depends on something other than (x%32, y%32, "
           "colour, palette)")
    # NO NEIGHBOUR DEPENDENCE: recolouring one pixel must move that
    # pixel's index and NOTHING else's.
    poked = frame.copy()
    poked[20, 40] = np.array([255, 0, 255], dtype=np.uint8)
    e, _ = enc.dither_quantize(poked, pal)
    diff = np.argwhere(e != a)
    expect(diff.shape[0] <= 1 and (diff.shape[0] == 0 or tuple(diff[0]) == (20, 40)),
           f"one changed pixel moved {diff.shape[0]} indices - the "
           f"dither reads its neighbours")
    # QUIET CONTENT -> ZERO CHURN: an unchanged frame re-quantized
    # against the same palette must produce an identical index map (the
    # delta coder's whole premise).
    f2, _ = enc.dither_quantize(frame.copy(), pal)
    expect(np.array_equal(f2, a), "identical frames must dither identically")


@case(13, "mixture plan structure - 32-slot candidate list, luminance "
          "ordered, blue-noise indexed by the article's formula")
def t13_mixture_plan_structure():
    expect(enc.MIX_LEVELS == 32, "candidate list length must be MIX_LEVELS")
    # A pure two-level grey palette: the mixture of the two entries is
    # the only way to hit an intermediate grey, so the plan's structure
    # is fully predictable.
    pal = np.zeros((256, 3), dtype=np.uint8)
    pal[1] = 255
    L = enc.MIX_LEVELS
    planner = enc.MixturePlanner(pal, 1.0)
    thr = enc.BLUENOISE32 * L // 1024
    for target in (60, 128, 186, 220):
        frame = np.full((32, 32, 3), target, dtype=np.uint8)
        idx, tgt = planner.plan(frame)
        # ratio realized across the 32x32 tile must match the ratio the
        # gamma-correct mix of black and white needs for this target
        want = float((target / 255.0) ** enc.GAMMA)
        got = float((idx == 1).mean())
        expect(abs(got - want) <= 1.5 / L,
               f"target {target}: white fraction {got:.3f} != "
               f"gamma-correct {want:.3f} (+/- one list slot)")
        # LUMINANCE ORDER: the article sorts the candidate list by luma
        # and walks it with the threshold, so the WHITE pixels must be
        # exactly those with the highest blue-noise ranks.
        if bool((idx == 1).any()) and bool((idx == 0).any()):
            cut = int(thr[idx == 1].min())
            expect(bool((thr[idx == 1] >= cut).all())
                   and bool((thr[idx == 0] < cut).all()),
                   f"target {target}: emitted colours are not "
                   f"luminance-ordered against the threshold matrix")
    # The threshold index is the article's formula generalised to our
    # matrix: list[ matrix_value * list_size / matrix_max ].
    expect(int(thr.max()) == L - 1,
           "blue-noise index must span the whole candidate list")
    expect(int(thr.min()) == 0, "blue-noise index must start at slot 0")
    # amplitude 0 degenerates to the pure nearest-colour quantize.
    rng = np.random.default_rng(404)
    f = rng.integers(0, 256, size=(48, 48, 3), dtype=np.uint8)
    p2 = enc.display_palette(f)
    zero, _ = enc.dither_quantize(f, p2, 0.0)
    plain, _ = enc.quantize_to_palette(f, p2)
    expect(np.array_equal(zero, plain),
           "--dither 0 must reduce to the pure nearest-colour quantize")


@case(13, "dither mode selector - offset is the DEFAULT, mixture is "
          "opt-in and differs, bad modes refused")
def t13_dither_mode_selector():
    # The default is OFFSET on measurement (see nxv2enc's
    # DITHER_MODE_DEFAULT block: mixture loses per-pixel PSNR on every
    # fixture, carries a per-channel mean bias the offset path does not,
    # and costs up to 26% more wire bytes). Pinned here so a silent flip
    # of the shipped dither cannot pass the suite.
    expect(enc.DITHER_MODE_DEFAULT == enc.DITHER_MODE_OFFSET,
           "offset must be the default mode - mixture ships opt-in")
    expect(set(enc.DITHER_MODES) == {"mixture", "offset"}, "mode set drifted")
    for bad in ("bayer", "", "MIXTURE", 3):
        try:
            enc._dither_mode(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"_dither_mode({bad!r}) must be refused")
    expect(enc._dither_mode(None) == enc.DITHER_MODE_DEFAULT, "None -> default")
    H, W = 48, 64
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    f = np.clip(np.stack([xx * 3.9, yy * 5.1, (xx + yy) * 2.0], -1),
                0, 255).astype(np.uint8)
    pal = enc.display_palette(f)
    mix, _ = enc.dither_quantize(f, pal, 0.5, "mixture")
    off, _ = enc.dither_quantize(f, pal, 0.5, "offset")
    dfl, _ = enc.dither_quantize(f, pal, 0.5)
    expect(not np.array_equal(mix, off),
           "offset mode must not be an alias of mixture mode")
    expect(np.array_equal(dfl, off), "the default must BE the offset path")
    # the offset path is bit-for-bit the ordered-dither one
    legacy, _ = enc.quantize_to_palette(enc.ordered_dither(f, 0.5), pal)
    expect(np.array_equal(off, legacy),
           "offset mode must reproduce the legacy ordered-dither path")
    # ...and it is positional too (same tiling invariant)
    const = np.full((64, 64, 3), 100, dtype=np.uint8)
    c, _ = enc.dither_quantize(const, pal, 0.5, "offset")
    expect((c[:32, :32] == c[32:, 32:]).all(),
           "offset mode does not tile with period 32")


@case(13, "transparency exclusion holds under the mixture path - no "
          "emitted palette entry can pack to the NR $14 $FE colour")
def t13_mixture_transparency_invariant():
    # Bright near-white content is what drove the two colliding lattice
    # points onto real hardware in the first place (Big Buck Bunny),
    # and the mixture path emits palette INDICES chosen from all over
    # the palette - so re-pin the invariant here, on the new path.
    rng = np.random.default_rng(8888)
    H, W = 64, 64
    base = rng.integers(230, 256, size=(H, W, 3)).astype(np.uint8)
    base[:, :20] = np.array([255, 255, 160], dtype=np.uint8)   # straddles both
    base[:, 20:32] = np.array([255, 255, 190], dtype=np.uint8)  # $FE points
    pal = enc.display_palette(base)
    block = enc.build_palette_block(pal)
    for amp in (0.0, 0.25, 0.5, 1.0):
        for mode in enc.DITHER_MODES:
            idx, dec = enc.dither_quantize(base, pal, amp, mode)
            used = set(np.unique(idx).tolist())
            bad = [i for i in used if block[2 * i] == 0xFE]
            expect(not bad,
                   f"amp {amp} mode {mode}: emitted entries {bad} pack to "
                   f"$FE - transparent punch-through on silicon")
            for col in enc.TRANSP_COLLISION:
                hit = ((dec[..., 0] == col[0]) & (dec[..., 1] == col[1])
                       & (dec[..., 2] == col[2]))
                expect(not bool(hit.any()),
                       f"amp {amp} mode {mode}: emitted the excluded "
                       f"display colour {col}")
    # the whole palette, not just the used part, stays clean
    expect(not [i for i in range(256) if block[2 * i] == 0xFE],
           "display_palette emitted a $FE entry")


# =======================================================================
# Step 14: transparency-collision exclusion (pal9d, 2026-07-28). The
# player keeps Layer 2 transparency ACTIVE during video with the global
# transparency colour NR $14 = $FE; hardware transparency compares only
# the palette entry's first byte (RRRGGGBB, the 9th blue bit is not
# compared), so any emitted entry packing to byte0 $FE - display
# colours (255,255,146) and (255,255,182), BOTH 9th-bit variants -
# rendered as transparent holes (black punch-through in bright
# regions, seen on real hardware in the Big Buck Bunny demo). The
# encoder now excludes the two points from the representable lattice
# (nxv2enc TRANSP_COLLISION/TRANSP_REMAP in snap_to_lattice).
# =======================================================================


def _collect_pal_blocks(vid_path):
    """Every raw 512-byte PAL block of a .vid, captured through the
    reference decoder's own stream walk (dec._decode_palette_block spy)
    - exactly the bytes the player forwards to NR $44, no hand parsing."""
    blocks = []
    orig = dec._decode_palette_block

    def spy(block):
        blocks.append(bytes(block))
        return orig(block)

    dec._decode_palette_block = spy
    try:
        issues = dec.validate(vid_path)
    finally:
        dec._decode_palette_block = orig
    expect(issues == [], f"validate() issues: {issues}")
    return blocks


def _fe_entries(blocks):
    """(block_index, entry_index) pairs whose wire byte0 == $FE."""
    return [(bi, i) for bi, b in enumerate(blocks)
            for i in range(256) if b[2 * i] == 0xFE]


def _near_white_gradient(N, h, w):
    """Near-white gradient clip (R=G=255, blue ramping through the
    146/182 lattice levels, slowly drifting so it is a real moving
    clip) - slams the palette straight into the two NR $14 = $FE
    collision points (255,255,146)/(255,255,182). The ramp is x-only,
    so any frame height hits the same lattice points."""
    xx = np.arange(w, dtype=np.float32)[None, :]
    orig = np.empty((N, h, w, 3), dtype=np.uint8)
    for i in range(N):
        ramp = 96.0 + (xx + i * 4.0) % w * (136.0 / w)
        orig[i, ..., 0] = 255
        orig[i, ..., 1] = 255
        orig[i, ..., 2] = np.clip(ramp, 0, 255).astype(np.uint8)
    return orig


@case(14, "no $FE-byte0 palette entry survives an encode of a near-white gradient clip")
def t14_no_transparency_collision_on_wire():
    # The near-white gradient (_near_white_gradient) slams the palette
    # straight into (255,255,146)-(255,255,182). This case FAILS
    # against the pre-fix encoder logic: display_palette's median-cut
    # snap and dithered-composite refill both land on those two lattice
    # points, and build_palette_block packs each to byte0 $FE (verified
    # on the real encodes: sd/008.VID and the kit bunny caches each
    # carried both 9th-bit variants). The negative control below
    # re-encodes with the remap disabled to prove the clip still slams
    # the collision points - so this case cannot rot silently.
    N, h, w = 12, 192, 256
    orig = _near_white_gradient(N, h, w)
    chg, po = _synth_clip(orig)

    def encode_and_scan(tag):
        result = enc.encode_clip(orig, chg, po, w, h, 25.0)
        buf = _build_vid(result, w, h)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / f"transp_{tag}.vid"
            p.write_bytes(buf)
            blocks = _collect_pal_blocks(p)
        expect(len(blocks) >= 1, "encode emitted no palette block at all")
        return blocks

    hits = _fe_entries(encode_and_scan("fixed"))
    expect(hits == [], f"palette entries with byte0 $FE on the wire: {hits}")

    # Negative control: disable the remap (the pre-fix lattice) and
    # confirm the SAME clip does emit $FE entries - proving this case
    # bites the defect rather than passing vacuously.
    saved = enc.TRANSP_REMAP
    try:
        enc.TRANSP_REMAP = {}
        control = _fe_entries(encode_and_scan("prefix"))
    finally:
        enc.TRANSP_REMAP = saved
    expect(control != [], "negative control: pre-fix lattice must emit "
           "$FE entries for this clip (content no longer slams the "
           "collision points - test needs re-arming)")


@case(14, "direct-serve path - same clip through _encode_direct, zero $FE-byte0 entries")
def t14_no_transparency_collision_direct():
    # Sibling of the wire case above, driving the DIRECT-SERVE preset
    # (_encode_direct, as t11_direct_serve does) instead of
    # encode_clip. The direct path derives its palettes on its OWN
    # call sites (scene_palette per keyframe span, op_pal/
    # build_palette_block inside emit_direct_frame_payload), so the
    # shared-code argument is not relied on: a future regression scoped
    # to the direct-serve palette path must trip this standalone
    # assertion. 256x128 keeps the unconditional wire gate at-rate
    # (t11_direct_serve's shape rationale); the gradient is x-only, so
    # the shorter frame slams the same two collision points.
    N, h, w = 12, 128, 256
    orig = _near_white_gradient(N, h, w)
    chg, _ = _synth_clip(orig)
    abytes_real, abytes_pad = 1250, 1536
    ex = dict(orig=orig, chg=chg,
              audio_bytes=bytes(N * abytes_real), channels=2,
              rate=enc.RATE_STEREO, abytes_real=abytes_real,
              abytes_pad=abytes_pad, nframes=N)

    def encode_and_scan(tag):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / f"transp_direct_{tag}.vid"
            report = enc._encode_direct(ex, w, h, 25.0, p)
            expect(report.mode == "direct", "direct-serve report mode")
            blocks = _collect_pal_blocks(p)
        expect(len(blocks) >= 1, "direct encode emitted no palette block at all")
        return blocks

    hits = _fe_entries(encode_and_scan("fixed"))
    expect(hits == [],
           f"direct-serve palette entries with byte0 $FE on the wire: {hits}")

    # Negative control, mirroring the streaming case: the pre-fix
    # lattice must emit $FE entries through the direct path too,
    # proving this case bites rather than passing vacuously.
    saved = enc.TRANSP_REMAP
    try:
        enc.TRANSP_REMAP = {}
        control = _fe_entries(encode_and_scan("prefix"))
    finally:
        enc.TRANSP_REMAP = saved
    expect(control != [], "negative control: pre-fix lattice must emit "
           "$FE entries through the direct path (clip no longer slams "
           "the collision points - test needs re-arming)")


@case(14, "lattice exclusion - representable set excludes exactly the two collision points")
def t14_lattice_exclusion_set():
    levels = enc.LATTICE_EXP3.tolist()
    full = np.array([(r, g, b) for r in levels for g in levels for b in levels],
                    dtype=np.uint8)
    expect(full.shape == (512, 3), "full lattice must be 8x8x8")

    def byte0(v):
        return (int(v[0]) & 0xE0) | ((int(v[1]) >> 3) & 0x1C) | (int(v[2]) >> 6)

    # The full lattice holds exactly two byte0==$FE points - the
    # exclusion set matches the collision set, no over-exclusion.
    fe_points = {tuple(int(c) for c in v) for v in full if byte0(v) == 0xFE}
    expect(fe_points == set(enc.TRANSP_COLLISION),
           f"byte0 $FE lattice points {fe_points} != TRANSP_COLLISION")

    snapped = enc.snap_to_lattice(full)
    moved = {tuple(int(c) for c in v)
             for v in full[np.any(snapped != full, axis=1)]}
    expect(moved == set(enc.TRANSP_COLLISION),
           f"snap moved {moved}, expected exactly the two collision points")
    rep = {tuple(int(c) for c in v) for v in snapped}
    expect(rep == {tuple(int(c) for c in v) for v in full} - set(enc.TRANSP_COLLISION),
           "representable set must be the full lattice minus the two collision points")
    expect(all(byte0(v) != 0xFE for v in rep),
           "a representable lattice point still packs to byte0 $FE")
    # Idempotence: the representable set is a fixed point of the snap.
    expect((enc.snap_to_lattice(snapped) == snapped).all(),
           "snap must be idempotent on the representable set")

    # Replacements sane: blue-axis neighbours (R=G=255 highlights keep
    # their hue), one lattice level away, themselves representable:
    # (255,255,146) -> (255,255,109) and (255,255,182) -> (255,255,219).
    expect(enc.TRANSP_REMAP == {(255, 255, 146): (255, 255, 109),
                                (255, 255, 182): (255, 255, 219)},
           f"unexpected remap table {enc.TRANSP_REMAP}")
    for src, dst in enc.TRANSP_REMAP.items():
        expect(dst[:2] == src[:2], f"{src}: remap must stay on the blue axis")
        expect(abs(dst[2] - src[2]) <= 37,
               f"{src}: remap must move at most one lattice bin")
        expect(dst in rep, f"{src}: replacement {dst} not representable")


# =======================================================================
# Step 15: delta-starvation DIAGNOSTICS - report-only instrumentation
# over the streaming delta path. The mean-rate supply gate is blind to
# picture damage (007 passed it at utilization 1.00 with clean transport
# counters while banding on silicon); starvation_stats() counts
# budget-bound frames, their worst concentrated window, and the
# delta-frame PSNR tail.
#
# The WARNING these stats once fed was DEMOTED to report-only (owner
# ruling 2026-07-28, second ruling): the bound-fraction axis is refuted
# - fixture 008 measures 99.2% budget-bound and is visually CLEAN on
# silicon, 007 measures 36.4% and BANDS - so count does not predict
# visibility (severity probably does, and is unmeasured). These cases
# therefore pin the STATS (definitions, window sizing, plumbing into
# BuildReport/--report) and pin that NO warning line is emitted. The
# retired threshold constants stay in the module for re-derivation.
# =======================================================================

def _starve_clip(N, h, w, motion):
    """Synthetic clip: a fixed dense noise texture rolled `motion` px per
    frame. Palette stays stable (no keyframe thrash, no scene cuts) while
    almost every pixel changes every frame - the demand shape that slams
    the per-frame delta cap. motion=0 gives the calm control."""
    rng = np.random.default_rng(1234)
    base = rng.integers(0, 256, size=(h, w * 2, 3), dtype=np.uint8)
    orig = np.empty((N, h, w, 3), dtype=np.uint8)
    for i in range(N):
        off = (i * motion) % w
        orig[i] = base[:, off:off + w]
    return orig


def _burst_clip(N, h, w, b0, blen, motion=3):
    """Synthetic clip with a CONCENTRATED starvation burst: the same
    dense noise texture held perfectly STATIC (zero delta demand, zero
    starvation) except for frames [b0, b0+blen), which roll it `motion`
    px per frame. The rolled offset is kept afterwards, so the clip goes
    straight back to static. Sized so the burst is a small fraction of
    the whole clip but SATURATES one burst window - the exact shape the
    whole-clip mean dilutes away."""
    rng = np.random.default_rng(1234)
    base = rng.integers(0, 256, size=(h, w * 2, 3), dtype=np.uint8)
    orig = np.empty((N, h, w, 3), dtype=np.uint8)
    off = 0
    for i in range(N):
        if b0 <= i < b0 + blen:
            off = (off + motion) % w
        orig[i] = base[:, off:off + w]
    return orig


@case(15, "starvation diagnostics - starved synthetic encode measures a high budget-bound fraction")
def t15_starvation_trips():
    N, h, w = 24, 192, 256
    orig = _starve_clip(N, h, w, motion=3)
    chg, po = _synth_clip(orig)
    result = enc.encode_clip(orig, chg, po, w, h, 25.0)
    st = result["starvation"]
    expect(st == enc.starvation_stats(result["per_frame"], 25.0),
           "encode_clip must surface exactly starvation_stats(per_frame, fps)")
    expect(st["frames"] == N, f"frames {st['frames']} != {N}")
    # Cross-check the counter against the binding records it summarizes.
    bound = sum(1 for b in result["per_frame"]["binding"] if b == "budget")
    expect(st["budget_bound"] == bound,
           f"budget_bound {st['budget_bound']} != binding-record count {bound}")
    expect(abs(st["bound_fraction"] - bound / N) < 1e-12, "bound_fraction = budget_bound / frames")
    expect(st["bound_fraction"] > 0.5,
           f"starved clip must be mostly budget-bound, got {st['bound_fraction']:.2f}")
    expect(st["burst_peak_fraction"] >= st["bound_fraction"],
           f"the peak window can never read below the whole-clip fraction, got "
           f"{st['burst_peak_fraction']:.2f} < {st['bound_fraction']:.2f}")
    expect(0.0 < st["delta_psnr_p10"] < 40.0,
           f"delta p10 {st['delta_psnr_p10']} outside sane bounds")
    print(f"  [starved] bound {st['bound_fraction']:.1%} "
          f"({st['budget_bound']}/{st['frames']}), p10 {st['delta_psnr_p10']:.2f} dB")


@case(15, "starvation diagnostics - calm synthetic encode measures a zero bound fraction and a null burst")
def t15_starvation_quiet():
    N, h, w = 24, 192, 256
    orig = _starve_clip(N, h, w, motion=0)   # identical frames after the first
    chg, po = _synth_clip(orig)
    result = enc.encode_clip(orig, chg, po, w, h, 25.0)
    st = result["starvation"]
    expect(st["budget_bound"] == 0,
           f"a static clip must have no budget-bound frame, got {st['budget_bound']}")
    expect(st["bound_fraction"] == 0.0, "bound_fraction must be exactly 0.0")
    expect(st["delta_frames"] > 0, "the clip must contain delta frames to report a p10 over")
    # The burst window must not manufacture starvation out of a clip
    # that has none - a zero clip reads zero on both measures.
    expect(st["burst_peak_fraction"] == 0.0,
           f"a static clip's peak window must be 0.0, got {st['burst_peak_fraction']}")
    expect(st["burst_window_frames"] > 0,
           "a non-empty clip must still report a window length")


@case(15, "starvation diagnostics - concentrated burst is visible in the WINDOW stat while the whole-clip fraction stays low")
def t15_starvation_burst_path():
    # The whole-clip mean's blind spot: a short SEVERE run divided by a
    # long clip. fps 8.0 -> a 0.5 s window is 4 frames, so the clip can
    # stay small enough to encode quickly and still be ~25 windows long.
    # The window stat is what makes such a run legible at all, which is
    # why it survives the trigger's retirement as a reported figure.
    N, h, w, fps = 100, 96, 256, 8.0
    orig = _burst_clip(N, h, w, b0=40, blen=8)
    chg, po = _synth_clip(orig)
    result = enc.encode_clip(orig, chg, po, w, h, fps)
    st = result["starvation"]
    expect(st["burst_window_frames"] == 4,
           f"window must be round(STARVE_BURST_WINDOW_S * fps) = 4 at {fps} fps, "
           f"got {st['burst_window_frames']}")
    # (1) the whole-clip fraction all but hides the run...
    expect(st["bound_fraction"] < 0.10,
           f"the burst must stay diluted in the whole-clip figure for this case "
           f"to prove anything - got {st['bound_fraction']:.3f}")
    # (2) ...and the window figure reports it plainly.
    expect(st["burst_peak_fraction"] > 0.60,
           f"a saturated burst window must read near 1.0, got "
           f"{st['burst_peak_fraction']:.2f}")
    expect(st["burst_peak_fraction"] > 5 * st["bound_fraction"],
           f"the window figure must separate from the mean it exists to "
           f"un-dilute, got {st['burst_peak_fraction']:.2f} vs "
           f"{st['bound_fraction']:.3f}")
    expect(40 <= st["burst_peak_frame"] < 40 + 8 + st["burst_window_frames"],
           f"peak window must land on the burst, got frame {st['burst_peak_frame']}")
    print(f"  [burst] whole-clip {st['bound_fraction']:.1%} | peak "
          f"{st['burst_window_frames']}-frame window "
          f"{st['burst_peak_fraction']:.0%} @f{st['burst_peak_frame']}")


@case(15, "starvation diagnostics - stat definitions are what the docstring claims; retired thresholds still present but unused")
def t15_starvation_threshold_and_definitions():
    # RETIRED constants (owner ruling 2026-07-28): the bound-fraction
    # trigger was demoted to report-only because 008 measures 99.2%
    # budget-bound while being visually CLEAN on silicon and 007
    # measures 36.4% while BANDING - count does not predict visibility.
    # The constants are deliberately KEPT (unreferenced by encode()'s
    # output path) so the re-derivation has the old operating point to
    # hand; this case pins that they are still there and unchanged, NOT
    # that they are correct. Any re-derivation is expected to move
    # them, and to move this case with them.
    t = enc.STARVE_WARN_BOUND_FRAC
    expect(abs(t - 0.08) < 1e-12,
           f"retired STARVE_WARN_BOUND_FRAC changed to {t} - it is a placeholder "
           f"for re-derivation, not a live threshold")
    bt = enc.STARVE_WARN_BURST_FRAC
    expect(abs(bt - 0.60) < 1e-12,
           f"retired STARVE_WARN_BURST_FRAC changed to {bt} - same placeholder")
    # starvation_warns() survives as the retired verdict recorded in the
    # report; it must stay a pure function of those two constants.
    expect(enc.starvation_warns(
        {"bound_fraction": t + 0.01, "burst_peak_fraction": 0.0}),
        "starvation_warns must still key off STARVE_WARN_BOUND_FRAC")
    expect(enc.starvation_warns(
        {"bound_fraction": 0.0, "burst_peak_fraction": bt + 0.01}),
        "starvation_warns must still key off STARVE_WARN_BURST_FRAC")
    expect(not enc.starvation_warns(
        {"bound_fraction": t, "burst_peak_fraction": bt}),
        "starvation_warns must be strict on both thresholds")

    # LIVE measurement parameter: the window is a fixed DURATION, so it
    # means the same thing to a viewer at any fps.
    bw = enc.STARVE_BURST_WINDOW_S
    expect(abs(bw - 0.5) < 1e-12,
           f"STARVE_BURST_WINDOW_S changed to {bw} - re-justify the perceptual scale")
    expect(0.25 <= bw <= 1.0, "burst window must stay on the perceptually relevant scale")
    # Window sizing is fps-derived so it means a fixed duration.
    for fps, want in ((25.0, 12), (50.0, 25), (10.0, 5), (2.0, 2)):
        per = {"mode": ["full"] * 400, "binding": ["none"] * 400, "psnr": [30.0] * 400}
        expect(enc.starvation_stats(per, fps)["burst_window_frames"] == want,
               f"window at {fps} fps must be {want} frames")
    # The two figures measure different things: 15 consecutive bound
    # frames in 250 is 6% whole-clip but a fully saturated 0.6 s window.
    per = {"mode": ["full"] * 250, "binding": ["none"] * 250, "psnr": [30.0] * 250}
    for i in range(100, 115):
        per["binding"][i] = "budget"
    st = enc.starvation_stats(per, 25.0)
    expect(abs(st["bound_fraction"] - 0.06) < 1e-12, "15/250 must read 6%")
    expect(st["burst_peak_fraction"] == 1.0, "15 consecutive bound frames must saturate a 12-frame window")
    expect(st["burst_peak_frame"] == 100, f"peak window must start at 100, got {st['burst_peak_frame']}")
    # A clip SHORTER than one window gets a single whole-clip window.
    short = enc.starvation_stats(
        {"mode": ["full"] * 5, "binding": ["budget"] * 2 + ["none"] * 3, "psnr": [30.0] * 5}, 25.0)
    expect(short["burst_window_frames"] == 5, "window clamps to the clip length")
    expect(abs(short["burst_peak_fraction"] - short["bound_fraction"]) < 1e-12,
           "a sub-window clip's burst peak must equal its whole-clip fraction")

    # Definitions: denominator is ALL emitted frames; the p10 excludes
    # keyframe-span frames (the format-intrinsic dips) but keeps
    # deferred-keyframe delta frames.
    per = {
        "mode": ["kf", "kfhold", "kfflip", "full+merge", "region:3/48+merge",
                 "region:1/48+merge:deferred_kf"],
        "binding": ["kf", "kf", "kf", "none", "budget", "budget"],
        "psnr": [4.0, 8.0, 12.0, 30.0, 20.0, 25.0],
    }
    st = enc.starvation_stats(per)
    expect(st["frames"] == 6, "frames counts every emitted frame")
    expect(st["delta_frames"] == 3, f"delta_frames {st['delta_frames']} != 3 (kf* excluded)")
    expect(st["budget_bound"] == 2, f"budget_bound {st['budget_bound']} != 2")
    expect(abs(st["bound_fraction"] - 2 / 6) < 1e-12,
           "bound_fraction denominator must be ALL emitted frames, not just delta frames")
    expect(abs(st["delta_psnr_p10"] - float(np.percentile([30.0, 20.0, 25.0], 10))) < 1e-9,
           f"p10 {st['delta_psnr_p10']} must be the percentile over the three delta frames only "
           "(kf dips excluded, deferred_kf kept)")
    # Empty/degenerate input must not raise or divide by zero.
    empty = enc.starvation_stats({"mode": [], "binding": [], "psnr": []}, 25.0)
    expect(empty["bound_fraction"] == 0.0 and empty["delta_psnr_p10"] == 0.0,
           "empty encode must report zeros, not raise")
    expect(empty["burst_window_frames"] == 0 and empty["burst_peak_fraction"] == 0.0
           and empty["burst_peak_frame"] is None,
           "empty encode must report a null burst, not raise")


@case(15, "starvation diagnostics - --report JSON carries the same key set in both modes (direct zeroes, never omits)")
def t15_starvation_report_key_parity():
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("Sintel source or ffmpeg not available")
    import contextlib
    import io
    import json
    # 256x128 mono at 25 fps is inside the direct-serve wire envelope
    # (256x135 at-rate); 1 s keeps both legs cheap.
    with tempfile.TemporaryDirectory() as td:
        reps = {}
        for tag, direct in (("direct", True), ("streaming", False)):
            rp = Path(td) / f"kp_{tag}.json"
            with contextlib.redirect_stdout(io.StringIO()):
                enc.encode(str(SINTEL), str(Path(td) / f"kp_{tag}.vid"),
                           shape=(256, 128), fps=25.0, duration="1",
                           ffmpeg=str(FFMPEG), mono=True, direct=direct,
                           report_path=str(rp))
            reps[tag] = json.loads(rp.read_text())
        expect(set(reps["direct"]) == set(reps["streaming"]),
               f"report key sets must match across modes; direct-only "
               f"{sorted(set(reps['direct']) - set(reps['streaming']))}, "
               f"streaming-only {sorted(set(reps['streaming']) - set(reps['direct']))}")
        d = reps["direct"]
        for k, want in (("delta_frames", 0), ("budget_bound_frames", 0),
                        ("bound_fraction", 0.0), ("burst_window_frames", 0),
                        ("burst_peak_fraction", 0.0), ("burst_peak_frame", None),
                        ("delta_psnr_p10", 0.0), ("starvation_warned", False)):
            expect(d[k] == want,
                   f"direct-serve report {k} must be {want!r} (all-literal: no "
                   f"deltas to starve), got {d[k]!r}")


@case(15, "starvation diagnostics - end-to-end: BuildReport fields and report line, and NO warning either way (Sintel)")
def t15_starvation_end_to_end():
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("Sintel source or ffmpeg not available")
    import contextlib
    import io
    with tempfile.TemporaryDirectory() as td:
        outs = {}
        # calm leg rides the same 0.88 operating point the step-7 case
        # uses for Sintel classic (the supply gate's own named remedy);
        # 2 s sits under the resident pool, so the gate itself is moot.
        for tag, sb in (("starved", 0.2), ("calm", 0.88)):
            out = Path(td) / f"starve_{tag}.vid"
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                report = enc.encode(str(SINTEL), str(out), shape=(256, 192), fps=25.0,
                                     quality_profile="max", start="00:00:00", duration="2",
                                     ffmpeg=str(FFMPEG), stream_budget=sb, dither=0.25)
            outs[tag] = (report, buf.getvalue())
            # ALWAYS reported, and reported as a measurement only.
            expect("delta stats: budget-bound" in outs[tag][1],
                   f"[{tag}] the stats line must always print: {outs[tag][1]!r}")
            expect(report.delta_frames > 0, f"[{tag}] delta_frames must be counted")
            expect(report.bound_fraction ==
                   (report.budget_bound_frames / report.frames),
                   f"[{tag}] bound_fraction must match its own counters")
            expect(report.burst_window_frames == 12,
                   f"[{tag}] 25 fps must give a 12-frame window, "
                   f"got {report.burst_window_frames}")
            expect("window" in outs[tag][1],
                   f"[{tag}] the stats line must carry the window stat: {outs[tag][1]!r}")
            expect(f"{report.delta_psnr_p10:.2f} dB" in outs[tag][1],
                   f"[{tag}] the stats line must carry the p10 it reported: "
                   f"{outs[tag][1]!r}")
            # DEMOTED TO REPORT-ONLY (owner ruling 2026-07-28): no
            # starvation verdict reaches the author on either leg.
            expect("starvation" not in outs[tag][1],
                   f"[{tag}] no starvation warning may be emitted: {outs[tag][1]!r}")

        starved_rep, starved_out = outs["starved"]
        calm_rep, calm_out = outs["calm"]
        # The stats still separate the two operating points, which is
        # why they stay worth reporting even without a threshold on them.
        expect(starved_rep.bound_fraction > calm_rep.bound_fraction,
               f"the 0.2-budget encode must measure more budget-bound than the "
               f"0.88-budget one, got {starved_rep.bound_fraction:.3f} vs "
               f"{calm_rep.bound_fraction:.3f}")
        expect(starved_rep.bound_fraction > 0.5,
               f"the 0.2-budget encode must starve, got {starved_rep.bound_fraction:.3f}")
        # The retired verdict is still RECORDED (for re-derivation) but
        # never printed - it must stay consistent with its constants.
        for tag, rep in (("starved", starved_rep), ("calm", calm_rep)):
            expect(rep.starvation_warned ==
                   (rep.bound_fraction > enc.STARVE_WARN_BOUND_FRAC
                    or rep.burst_peak_fraction > enc.STARVE_WARN_BURST_FRAC),
                   f"[{tag}] recorded starvation_warned must follow the retired "
                   f"constants it is defined by")
        # Starvation costs picture: the starved encode's tail must be worse.
        expect(starved_rep.delta_psnr_p10 < calm_rep.delta_psnr_p10,
               f"starved p10 {starved_rep.delta_psnr_p10:.2f} should sit below "
               f"calm p10 {calm_rep.delta_psnr_p10:.2f}")
        print(f"  [starved sb0.2] bound {starved_rep.bound_fraction:.1%} "
              f"p10 {starved_rep.delta_psnr_p10:.2f} dB | "
              f"[calm sb0.88] bound {calm_rep.bound_fraction:.1%} "
              f"p10 {calm_rep.delta_psnr_p10:.2f} dB")



# =======================================================================
# Step 16: AUTO-BUDGET (SP17 T1). --stream-budget is a supply ceiling,
# not a quality dial - the E2 ladder measured every metric moving the
# same way as it falls - so the encoder derives it instead of the author
# guessing. These cases pin the four properties the derivation has to
# have: it converges, an explicit budget still wins outright, it never
# hands back a budget the supply gate would refuse, and it is
# deterministic.
# =======================================================================

def _synth_ex(orig, fps=25.0, mono=False):
    """An _extract_source-shaped dict for a synthetic (N,H,W,3) stack -
    the four keys auto_stream_budget/stream_gate_stats actually read."""
    N = orig.shape[0]
    po = np.empty(N)
    chg = np.zeros(N)
    for i in range(N):
        po[i] = enc.display_ceiling(orig[i])
        if i:
            d = np.abs(orig[i].astype(np.int16)
                       - orig[i - 1].astype(np.int16)).max(axis=2)
            chg[i] = float((d > 10).mean())
    abytes_pad = enc.audio_layout(fps, 1 if mono else 2)[3]
    return dict(orig=orig, chg=chg, po_ceil=po, abytes_pad=abytes_pad)


def _small_streaming_ex():
    """A SMALL synthetic clip that the supply gate still applies to,
    made so by lowering the reference resident-pool constant for the
    duration of the case. Cases about the search's mechanics (exactness,
    determinism) need the gate to run but not 80 frames of it - the pool
    size is not what they are testing. Returns (ex, restore); call
    restore() from a finally."""
    ex = _synth_ex(_starve_clip(16, 192, 256, motion=3))
    saved = enc.STREAM_RESIDENT_POOL_B
    enc.STREAM_RESIDENT_POOL_B = 64 * 1024

    def restore():
        enc.STREAM_RESIDENT_POOL_B = saved
    return ex, restore


@case(16, "auto-budget - target point and search constants are the ones the design argues for")
def t16_autobudget_constants():
    # The target is a MARGIN below the refusal line, not the line: SP17
    # E6 measured a clip whose whole-clip mean was 0.981 carrying a p95
    # frame of 1.071 and runs of 19 consecutive frames over budget.
    expect(0.0 < enc.AUTO_BUDGET_TARGET_UTIL < 1.0,
           f"target {enc.AUTO_BUDGET_TARGET_UTIL} must leave margin under 1.00")
    # It is the gate's OWN suggestion target - the search and the gate's
    # advice must name one operating point, not two.
    expect(enc.AUTO_BUDGET_TARGET_UTIL == enc.STREAM_TARGET_UTIL,
           "auto-budget target must be the supply gate's own suggestion target")
    # ...and at or under the at-capacity warning line, so a derived
    # encode never trips the warning that says it will band.
    expect(enc.AUTO_BUDGET_TARGET_UTIL <= enc.STREAM_WARN_UTIL,
           "a derived budget must never land in the at-capacity warning band")
    expect(enc.AUTO_BUDGET_MAX_PROBES >= 2,
           "the search needs at least a ceiling probe and one step")
    expect(0.0 < enc.AUTO_BUDGET_TOL < 0.1, "accept band must be narrow but non-zero")
    expect(enc.AUTO_BUDGET_MIN_SLOPE > 0.0, "plateau cut-off must be positive")
    expect(0.0 < enc.AUTO_BUDGET_MIN < enc.AUTO_BUDGET_TARGET_UTIL,
           "budget floor must sit under the target")
    # The search's one model-informed step reads audio_sd_ms out of the
    # gate stats; it must be the audio pad's share of the fetch term.
    st = enc.stream_supply_check(400000.0, 25508.0, 1536, 25.0, 256, 192)
    wire_eff = enc.SD_WIRE_BYTES_PER_MS * enc.TMODEL_COEFFS["audio_factor"]
    expect(abs(st["audio_sd_ms"] - 1536 / wire_eff) < 1e-9,
           "audio_sd_ms must be the invariant audio pad's own fetch time")
    expect(0.0 < st["audio_sd_ms"] < st["sd_ms"],
           "the audio pad is part of the fetch term, not all of it")


@case(16, "auto-budget - converges inside the probe cap on a streaming clip, and never returns a REFUSED budget")
def t16_autobudget_converges():
    # Dense noise rolled 3 px/frame at FULL shape: every pixel changes
    # every frame, so the per-frame caps bind hard and the budget
    # genuinely drives utilization. 60 frames keeps the file over the
    # resident pool at every budget the search will try, so the supply
    # gate applies throughout.
    #
    # SHAPE RE-BASED at the SP17 copy-DMA model (320x256, was 256x192 at
    # 80 frames): the case needs a clip the gate REFUSES at the 1.00
    # ceiling, and the restored DMA copy term made the classic-shape
    # version feasible there (ceiling probe 1.587 -> 0.969). The premise
    # assertion below is what caught it; the full shape restores it.
    ex = _synth_ex(_starve_clip(60, 256, 320, motion=3))
    search = enc.auto_stream_budget(ex, 320, 256, 25.0)
    probes = search["probes"]
    expect(not search["resident"], "60 full-shape noise frames must exceed the resident pool")
    expect(1 <= len(probes) <= enc.AUTO_BUDGET_MAX_PROBES,
           f"{len(probes)} probes exceeds the cap {enc.AUTO_BUDGET_MAX_PROBES}")
    expect(probes[0][0] == 1.00, "the first probe must be the honest ceiling")
    expect(probes[0][1] > 1.0,
           f"this clip must be refused at the ceiling for the case to mean "
           f"anything, got {probes[0][1]:.3f}")
    b = search["budget"]
    expect(b is not None, "a feasible budget exists for this clip - the search must find it")
    expect(0.0 < b <= 1.0, f"derived budget {b} outside (0, 1]")
    expect(round(b, 2) == b, f"derived budget {b} must be quotable to two decimals")
    util = search["stats"]["utilization"]
    # THE hard property: what comes back is never a budget the gate
    # refuses. Everything else is a quality preference; this is a
    # correctness bound.
    expect(util <= 1.0, f"returned budget {b} measures utilization {util:.3f} > 1.00 - REFUSED")
    expect(util <= search["target"] or search["plateau"],
           f"a non-plateau result must reach the target: util {util:.3f} "
           f"vs target {search['target']:.2f}")
    # The winner is the HIGHEST budget that met the target - handing back
    # a lower one would be throwing away picture for nothing (E2).
    at_target = [pb for pb, pu in probes if pu is not None and pu <= search["target"]]
    if at_target:
        expect(b == max(at_target),
               f"chosen {b} is not the highest budget that met the target {max(at_target)}")
    print(f"  [converge] probes {[(pb, round(pu, 4)) for pb, pu in probes]} "
          f"-> {b:.2f} @ util {util:.4f} in {search['elapsed']:.1f} s")


@case(16, "auto-budget - the derived budget reproduces the same stream when passed explicitly (memo is exact)")
def t16_autobudget_reproducible():
    # The report line tells the author which --stream-budget to type; if
    # typing it produced different bytes the line would be a lie. This
    # also pins the search's quantization memo as a CACHE and not an
    # approximation - the searched pass shares palette solves between
    # probes, the plain pass computes them fresh.
    ex, restore = _small_streaming_ex()
    try:
        search = enc.auto_stream_budget(ex, 256, 192, 25.0)
        b = search["budget"]
        plain = enc.encode_clip(ex["orig"], ex["chg"], ex["po_ceil"], 256, 192,
                                25.0, budget_scale=b)
    finally:
        restore()
    expect(enc._QUANT_MEMO is None, "the memo must be off outside a search")
    expect(len(plain["payloads"]) == len(search["result"]["payloads"]),
           "frame count differs between the searched and the plain pass")
    for i, (p, q) in enumerate(zip(plain["payloads"], search["result"]["payloads"])):
        expect(p == q, f"frame {i} payload differs between searched and plain encode at budget {b}")


@case(16, "auto-budget - deterministic: the same input derives the same budget and the same bytes")
def t16_autobudget_deterministic():
    ex, restore = _small_streaming_ex()
    try:
        a = enc.auto_stream_budget(ex, 256, 192, 25.0)
        b = enc.auto_stream_budget(ex, 256, 192, 25.0)
    finally:
        restore()
    expect(a["budget"] == b["budget"],
           f"two searches over one input chose {a['budget']} and {b['budget']}")
    expect([p for p, _ in a["probes"]] == [p for p, _ in b["probes"]],
           "the probe ladder itself must be reproducible")
    expect([round(u, 12) for _, u in a["probes"]] == [round(u, 12) for _, u in b["probes"]],
           "the measured utilizations must be reproducible")
    expect(a["result"]["payloads"] == b["result"]["payloads"],
           "the written stream must be reproducible")


@case(16, "auto-budget - an explicit --stream-budget wins outright; the default derives and reports")
def t16_autobudget_override_e2e():
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("demo source or ffmpeg not available")
    import contextlib
    import io
    with tempfile.TemporaryDirectory() as td:
        # 2 s of Sintel classic sits under the resident pool, so the
        # supply gate is moot and the search's answer is the ceiling on
        # its first probe - which makes it the cheapest honest end-to-end
        # check of the WIRING (which budget reaches encode_clip, what the
        # report records, what prints).
        auto_out = Path(td) / "auto.vid"
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            auto_rep = enc.encode(str(SINTEL), str(auto_out), shape=(256, 192),
                                   fps=25.0, start="00:00:00", duration="2",
                                   ffmpeg=str(FFMPEG))
        auto_log = buf.getvalue()
        expect(auto_rep.auto_budget, "the default must derive a budget")
        expect("auto-budget: --stream-budget" in auto_log,
               f"the derivation must be reported in one line: {auto_log!r}")
        expect(f"--stream-budget {auto_rep.stream_budget:.2f}" in auto_log,
               "the reported line must name the budget the report records")
        expect(auto_rep.auto_budget_target == enc.AUTO_BUDGET_TARGET_UTIL,
               "the reported target must be the default target")
        expect(auto_rep.auto_budget_probes >= 1, "a search costs at least one probe")

        # Explicit budget: no search, no line, and the value applies
        # verbatim - a de-rated encode must actually be de-rated.
        exp_out = Path(td) / "explicit.vid"
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exp_rep = enc.encode(str(SINTEL), str(exp_out), shape=(256, 192),
                                  fps=25.0, start="00:00:00", duration="2",
                                  ffmpeg=str(FFMPEG), stream_budget=0.40)
        exp_log = buf.getvalue()
        expect(not exp_rep.auto_budget, "an explicit budget must not run the search")
        expect(exp_rep.stream_budget == 0.40,
               f"explicit budget must apply verbatim, report says {exp_rep.stream_budget}")
        expect(exp_rep.auto_budget_probes == 0, "no probes may be spent on an explicit budget")
        expect("auto-budget" not in exp_log,
               f"an explicit budget must print no derivation line: {exp_log!r}")
        expect(exp_out.stat().st_size < auto_out.stat().st_size,
               "budget 0.40 must emit fewer bytes than the derived budget - "
               "the override is not reaching the rate control")
        # ...and the derived budget for a resident clip IS the ceiling,
        # so the auto file must match a hand-set 1.00 byte for byte.
        ceil_out = Path(td) / "ceiling.vid"
        with contextlib.redirect_stdout(io.StringIO()):
            enc.encode(str(SINTEL), str(ceil_out), shape=(256, 192), fps=25.0,
                        start="00:00:00", duration="2", ffmpeg=str(FFMPEG),
                        stream_budget=1.0)
        expect(auto_rep.stream_budget == 1.0,
               f"a resident clip's derived budget must be the ceiling, got "
               f"{auto_rep.stream_budget}")
        expect(ceil_out.read_bytes() == auto_out.read_bytes(),
               "the derived-ceiling encode must be byte-identical to an explicit 1.00")
        print(f"  [override] derived {auto_rep.stream_budget:.2f} "
              f"({auto_rep.auto_budget_probes} probe(s), "
              f"{auto_out.stat().st_size} B) vs explicit 0.40 "
              f"({exp_out.stat().st_size} B)")


@case(16, "auto-budget - a content-limited clip keeps its bytes instead of descending into starvation")
def t16_autobudget_plateau():
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("demo source or ffmpeg not available")
    # 5 s of Sintel at 256x152 / --dither 0.5 streams (over the resident
    # pool) at utilization 0.935 - over the 0.90 target - and that figure
    # does NOT move with the budget, because the content is asking for
    # less than the caps allow. Descending would be a pure quality loss
    # for a hundredth of supply, so the search must not.
    #
    # OPERATING POINT RE-BASED at the LADDER RE-CUT (256x152, back from
    # 256x112): the pal9j ladder spent decode-T on sub-line rungs, which
    # put utilization back under the budget's control at 256x152 and
    # forced a re-base to 112. The re-cut ladder cannot spend supply, so
    # 152 is content-limited again - the same operating point this case
    # used before pal9j. (Previously re-based at the Card #8 gate
    # correction, 256x192 -> 256x160; at the SP17 copy-DMA model, 3 s /
    # dither 0.25 -> 5 s / dither 0.5; at SP17 T0 source retiming,
    # 256x160 -> 256x152; and at the pal9j ladder, 152 -> 112.) The
    # premise assertion at the end is what caught all five.
    ex = enc._extract_source(str(SINTEL), 256, 152, 25.0, "00:00:00", "5.0",
                              str(FFMPEG), 0.5, False)
    search = enc.auto_stream_budget(ex, 256, 152, 25.0, dither_amp=0.5)
    expect(not search["resident"], "5 s of Sintel at 256x152 must exceed the resident pool")
    expect(search["plateau"], "this clip is content-limited - the search must say so")
    expect(search["budget"] == 1.00,
           f"a content-limited clip must keep the ceiling, got {search['budget']}")
    util = search["stats"]["utilization"]
    expect(util <= 1.0, f"the plateau answer is still gate-feasible, got {util:.3f}")
    expect(util > search["target"],
           "this case is only meaningful while the plateau sits above the target")
    line = enc.auto_budget_line(search)
    expect("content-limited" in line, f"the report line must disclose it: {line!r}")
    expect(f"--stream-budget {search['budget']:.2f}" in line,
           f"the report line must name the budget: {line!r}")
    print(f"  [plateau] {line.strip()}")


# =======================================================================
# Step 17: SOURCE RETIMING (SP17 T0). The Next composites at 50 Hz, so
# 25 fps is the only cadence-clean rate - and almost no source material
# is 25p. Reaching 25 by nearest-frame selection drops every 6th frame
# of a 30 fps source (measured: a 73 percent motion spike on every 5th
# OUTPUT frame) and FREEZES one frame per second of a 24 fps one, so
# blended retiming is now the default. These cases pin the four things
# the feature has to get right: detection off the existing banner probe,
# the exact filter string of each of the three modes, the
# do-absolutely-nothing behaviour when the source is already at the
# target (an already-25p encode must stay byte-identical to the pre-SP17
# encoder), and the kit sidecar hash noticing a --retime override.
# =======================================================================

PACE25 = ROOT / "tools" / "demo-files" / "1920x1080-25p.mp4"


@case(17, "retime detection - source rate read off the existing banner probe")
def t17_detect_source_fps():
    import videnc
    if not FFMPEG.exists():
        skip("ffmpeg not available")
    expected = [
        (SINTEL, 24.0), (BBB, 30.0),
        (ROOT / "tools" / "demo-files" / "Jellyfish_1080_10s_30MB.mp4", 29.97),
        (PACE25, 25.0),
    ]
    seen = 0
    for src, want in expected:
        if not src.exists():
            continue
        got = videnc.probe_source_fps(FFMPEG, src)
        expect(got is not None, f"no fps detected for {src.name}")
        expect(abs(got - want) < 0.005,
               f"{src.name}: detected {got} fps, expected {want}")
        seen += 1
    if not seen:
        skip("no demo sources available")
    # The banner is shared: passing a fetched stderr in must cost no
    # extra ffmpeg process and must give the same answer.
    stderr = videnc._probe_stderr(FFMPEG, PACE25 if PACE25.exists() else SINTEL)
    src = PACE25 if PACE25.exists() else SINTEL
    expect(videnc.probe_source_fps(FFMPEG, src, stderr=stderr)
           == videnc.probe_source_fps(FFMPEG, src),
           "shared-banner probe must agree with its own fresh probe")
    # An unparseable banner is None (unknown), never a guess.
    expect(videnc.probe_source_fps(FFMPEG, src, stderr="no video here") is None,
           "a banner with no fps field must report None, not a guess")


@case(17, "retime tolerance - banner rounding absorbed, real rates separated")
def t17_tolerance():
    import videnc
    tol = videnc.RETIME_FPS_TOLERANCE
    plain = ["scale=320:256"]
    # Inside the tolerance (ffmpeg's own 2-decimal banner rounding of
    # 30000/1001 etc.) = the same rate = no filter at all.
    for src in (25.0, 25.0 + tol, 25.0 - tol, 25.0 + tol / 2):
        stages, line = videnc.retime_plan(src, 25.0, 320, 256)
        expect(stages == plain, f"{src} fps vs 25 must not retime: {stages}")
        expect("not retimed" in line, f"report line for {src}: {line!r}")
    # Outside it = a different rate = retimed.
    for src in (25.0 + tol * 2, 25.0 - tol * 2, 24.0, 23.976, 29.97, 30.0):
        stages, line = videnc.retime_plan(src, 25.0, 320, 256)
        expect(stages != plain, f"{src} fps vs 25 must retime: {stages}")
        expect("not retimed" not in line, f"report line for {src}: {line!r}")
    # The tolerance has to be loose enough for the banner's own rounding
    # (29.97 printed for 29.970030) and tight enough to keep the closest
    # pair of real broadcast rates apart (23.976 vs 24, 0.024 apart).
    expect(tol >= 0.001, f"tolerance {tol} too tight for banner rounding")
    expect(tol < 0.024, f"tolerance {tol} would merge 23.976 and 24 fps")


@case(17, "retime modes - exact filter strings for blend/drop/mci")
def t17_mode_filters():
    import videnc
    expect(videnc.RETIME_MODE_DEFAULT == "blend",
           "blended retiming must be the default")
    expect(set(videnc.RETIME_MODES) == {"blend", "drop", "mci"},
           f"unexpected mode set {videnc.RETIME_MODES}")

    # blend: at an INTERMEDIATE resolution (4x the target on each axis),
    # then down to the target - measured clearly better than blending at
    # the target resolution on BBB (cadence-folded judder 0.024 vs 0.142)
    # and free.
    stages, line = videnc.retime_plan(29.97, 25.0, 320, 256, mode="blend")
    expect(stages == ["scale=1280:1024", "framerate=fps=25", "scale=320:256"],
           f"blend stages {stages}")
    expect(line == "  retime: source 29.97 fps -> target 25 fps, blend "
                   "(framerate filter at 1280x1024)", f"blend line {line!r}")
    # ... and the intermediate shape tracks the target shape.
    stages, _ = videnc.retime_plan(24.0, 25.0, 256, 192, mode="blend")
    expect(stages == ["scale=1024:768", "framerate=fps=25", "scale=256:192"],
           f"blend stages at classic {stages}")

    # drop: the pre-SP17 behaviour - no filter at all, ffmpeg's own
    # output -r does the nearest-frame selection.
    stages, line = videnc.retime_plan(29.97, 25.0, 320, 256, mode="drop")
    expect(stages == ["scale=320:256"], f"drop stages {stages}")
    expect(line == "  retime: source 29.97 fps -> target 25 fps, drop "
                   "(nearest source frame)", f"drop line {line!r}")

    # mci: opt-in, at the TARGET resolution (5.5-7.3 s per clip against
    # 82-144 s for the 4x aobmc preset, and not the worse of the two on
    # any source measured).
    stages, line = videnc.retime_plan(29.97, 25.0, 320, 256, mode="mci")
    expect(stages == ["scale=320:256",
                      "minterpolate=fps=25:mi_mode=mci:mc_mode=obmc:"
                      "me_mode=bilat"], f"mci stages {stages}")
    expect(line == "  retime: source 29.97 fps -> target 25 fps, mci "
                   "(minterpolate obmc/bilat at 320x256)", f"mci line {line!r}")

    # A non-integer target rate reaches the filter as an exact rational,
    # not a truncated decimal (the same limit_denominator the encoder
    # uses for the encode rate itself).
    from fractions import Fraction
    stages, _ = videnc.retime_plan(24.0, Fraction(50, 3), 320, 192, mode="blend")
    expect("framerate=fps=50/3" in stages[1], f"rational fps arg {stages}")

    # An unknown mode is refused outright, not silently defaulted.
    try:
        videnc.retime_plan(30.0, 25.0, 320, 256, mode="bilinear")
    except SystemExit:
        pass
    else:
        raise AssertionError("an unknown --retime mode must be refused")


@case(17, "retime skip-at-target - a source already at --fps is untouched "
          "in every mode, and an undetectable rate falls back to drop")
def t17_skip_at_target():
    import videnc
    plain = ["scale=320:256"]
    for mode in videnc.RETIME_MODES:
        stages, line = videnc.retime_plan(25.0, 25.0, 320, 256, mode=mode)
        expect(stages == plain,
               f"mode {mode} must not touch a 25p source: {stages}")
        expect(line == "  retime: source 25 fps already at 25 fps target - "
                       "not retimed", f"skip line for {mode}: {line!r}")
        # Unknown rate: never blend against a guess.
        stages, line = videnc.retime_plan(None, 25.0, 320, 256, mode=mode)
        expect(stages == plain, f"mode {mode} on an unknown rate: {stages}")
        expect("not detected" in line, f"unknown-rate line: {line!r}")
    # Same shape at a non-25 target: 25p material DOES retime then.
    stages, _ = videnc.retime_plan(25.0, 20.0, 320, 256)
    expect(stages != plain, "25p -> 20 fps must retime")


@case(17, "retime end-to-end - already-25p bytes unchanged by the feature, "
          "a 24 fps source genuinely re-encodes")
def t17_end_to_end_identity():
    import hashlib
    import subprocess
    if not FFMPEG.exists() or not PACE25.exists() or not SINTEL.exists():
        skip("demo sources or ffmpeg not available")

    def enc_sha(src, extra):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "r.vid"
            cmd = [sys.executable, str(LIB / "videnc.py"), str(src), str(out),
                   "--shape", "classic", "--fps", "25", "--duration", "0.6",
                   "--ffmpeg", str(FFMPEG)] + extra
            proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
            expect(proc.returncode == 0,
                   f"videnc.py failed:\n{proc.stderr.decode('utf-8', 'replace')}")
            return (hashlib.sha256(out.read_bytes()).hexdigest(),
                    proc.stdout.decode("utf-8", "replace"))

    # 25p source: the default (blend) and the explicit opt-out (drop)
    # must produce the SAME BYTES, because neither inserts a filter. That
    # is the byte-identity guarantee for existing 25p titles - the only
    # way the default can change their output is if the filter fires.
    d_sha, d_out = enc_sha(PACE25, [])
    o_sha, _ = enc_sha(PACE25, ["--retime", "drop"])
    expect(d_sha == o_sha,
           f"25p source: default {d_sha} != --retime drop {o_sha}")
    expect("not retimed" in d_out,
           f"25p encode must report the skip:\n{d_out}")

    # 24 fps source: the default must genuinely differ from the opt-out.
    s_default, s_out = enc_sha(SINTEL, [])
    s_drop, _ = enc_sha(SINTEL, ["--retime", "drop"])
    expect(s_default != s_drop,
           "24 fps source: blended default must not equal --retime drop")
    expect("-> target 25 fps, blend" in s_out,
           f"24 fps encode must report the blend:\n{s_out}")


@case(17, "retime CLI/kit plumbing - --retime is a real option and "
          "participates in the kit's sidecar arg hash")
def t17_cli_and_arg_hash():
    import hashlib
    import re as _re
    import subprocess
    help_out = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), "--help"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout.decode("utf-8", "replace")
    expect("--retime" in help_out, "--retime must appear in videnc.py --help")
    for mode in ("blend", "drop", "mci"):
        expect(mode in help_out, f"--retime {mode} must be documented in --help")
    # argparse must reject an unknown mode before anything runs.
    bad = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), str(SINTEL), "x.vid",
         "--retime", "nearest", "--ffmpeg", str(FFMPEG)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    expect(bad.returncode != 0, "an unknown --retime mode must be rejected")

    # The kit passes VIDOPTS/VIDOPTS_NNN through verbatim into the hashed
    # argument vector, so --retime rides that path with no special case.
    # Pin BOTH halves of that: the script really does hash the option
    # list it invokes the encoder with, and a --retime override really
    # does move the hash.
    ps1 = (ROOT / "authoring-kit" / "lib" / "video.ps1").read_text(encoding="utf-8")
    expect("$videoArgs = @($effShapeArgs + $fpsArgs + $globalOpts + $perOpts)" in ps1,
           "video.ps1 must build the arg vector from VIDOPTS + VIDOPTS_NNN")
    expect("$hash = Get-ArgHash $videoArgs" in ps1,
           "video.ps1 must hash that same vector")
    expect("& $enc[0] $enc[1..($enc.Length)] $src.FullName $vid --ffmpeg $ffmpeg @encArgs" in ps1,
           "video.ps1 must invoke the encoder with the hashed vector")
    m = _re.search(r"\$encoderGeneration = '([^']+)'", ps1)
    expect(m, "video.ps1 must carry an $encoderGeneration stamp")
    gen = m.group(1)

    def kit_hash(arg_list):
        """Get-ArgHash's own rule, mirrored: MD5 of the generation stamp
        joined to the argument vector by single spaces, first 8 hex."""
        joined = " ".join([gen] + arg_list)
        return hashlib.md5(joined.encode("utf-8")).hexdigest()[:8]

    base = ["--shape", "full", "--fps", "25"]
    expect(kit_hash(base) != kit_hash(base + ["--retime", "mci"]),
           "a --retime override must move the sidecar hash (forcing a re-encode)")
    expect(kit_hash(base + ["--retime", "drop"])
           != kit_hash(base + ["--retime", "mci"]),
           "different --retime modes must hash differently")
    # And the generation stamp itself is salted in, which is what covers
    # the DEFAULT-args output change this wave causes.
    expect("(@($encoderGeneration) + $argList) -join ' '" in ps1,
           "the generation stamp must be salted into the hash input")


# =======================================================================
# Step 18: SP17 ADAPTIVE TILE LADDER (re-cut 2026-07-30)
# =======================================================================
# The budget-bound schedule used to spend on a FIXED tile (TILE_BAND rows /
# columns, 1024 B on the two 256-line shapes). SP17 replaces that with an
# ADAPTIVE LADDER - per bound frame, walk the rungs fine -> coarse and keep
# the finest ADMISSIBLE one - and replaces the sqrt(err2) band-importance
# weight with raw err2.
#
# The first cut of that ladder shipped as the literal (32,64,128,256,1024)
# with byte spend as its only admissibility test, and owner silicon caught
# it on fixture 007 (mode-0) the next day: displacement and tearing on a
# clean transport. Both faults are pinned here.
#   - SUB-LINE RUNGS. A rung finer than one paint-order line splits a row
#     (mode-0) / column (mode-1) into independently-scheduled fragments.
#     The re-cut ladder walks WHOLE LINES: 1, 2 and 4 of them (= quarter,
#     half and whole band), so no rung can split a line on any shape.
#   - UNPRICED DECODE-T. Byte spend guards the WIRE and is silent on T,
#     but T is what the supply gate charges as busy_ms and what the
#     auto-budget search pays for in budget - i.e. in wire bytes. The
#     re-cut adds SUPPLY PRESERVATION: a finer rung is admissible only if
#     the gate's own busy+wire arithmetic does not price it above the
#     coarsest rung.
#
# These cases pin: the rungs and the two constants, the whole-line floor,
# the err2 weight (which orders bands differently from sqrt and must), the
# spend-preservation invariant, the supply-preservation invariant (the one
# the regression needed), the decode-T inversion spend preservation exists
# to prevent, and that encode_clip really drives the priced ladder end to
# end.
# =======================================================================


def _price_for(width, height):
    return enc.supply_price(width, height)


def _ladder_costs(target, err2, prev, cap_b, cap_t, ladder):
    """(rung -> (bytes, T)) for a single-rung schedule at each rung."""
    out = {}
    for g in ladder:
        r = enc.encode_delta(target, err2, cap_b, cap_t, surface_flat=prev,
                             tile_px=g)
        out[g] = (r[3], r[4])
    return out


def _ladder_residuals(target, err2, prev, cap_b, cap_t, ladder):
    """(rung -> err2 LEFT on the surface) for a single-rung schedule."""
    out = {}
    for g in ladder:
        r = enc.encode_delta(target, err2, cap_b, cap_t, surface_flat=prev,
                             tile_px=g)
        m = enc._mask_from_segments(r[0], r[1], r[2], err2.size)
        out[g] = float(err2[~m].sum())
    return out


def _ladder_spends(target, err2, prev, cap_b, cap_t, ladder):
    """(rung -> modelled bytes) for a single-rung schedule at each rung."""
    return {g: bt[0] for g, bt in
            _ladder_costs(target, err2, prev, cap_b, cap_t, ladder).items()}


def _expected_rung(costs, ladder, frac, price, slack, resid):
    """The rule, spelled out independently of the implementation: the finest
    rung (ladder is fine -> coarse) that spends at least the coarsest rung's
    bytes (and within `frac` of the best spend), is priced no higher than the
    coarsest rung's supply cost, and leaves no more residual err2 than it.
    Failing all of them, the coarsest rung - which is today's fixed band
    scheduler, so falling back to it is by construction never worse than
    what the ladder replaced."""
    best = max(b for b, _ in costs.values())
    coarse_b, coarse_t = costs[ladder[-1]]
    floor_b = max(coarse_b, frac * best)
    ceil_ms = enc.frame_supply_ms(coarse_b, coarse_t, price) * (1.0 + slack)
    for g in ladder:
        b, t = costs[g]
        if b >= floor_b and enc.frame_supply_ms(b, t, price) <= ceil_ms                 and resid[g] <= resid[ladder[-1]]:
            return g
    return ladder[-1]


@case(18, "adaptive tile ladder - constants, and every rung is a WHOLE paint-order line")
def t18_ladder_constants():
    expect(enc.TILE_LADDER_QUARTERS == (1, 2, 4),
           f"ladder rungs are 1/2/4 quarter-bands: {enc.TILE_LADDER_QUARTERS}")
    expect(not hasattr(enc, "TILE_LADDER"),
           "the literal sub-line ladder (32,64,128,256,1024) is RETIRED - it "
           "is what owner silicon read as displacement and tearing on 007")
    # 0.99, not 0.98 and emphatically not 1.00. Re-verification wave under
    # the shipped OFFSET dither default: 1.00 is an exact-tie requirement
    # that kicks the ladder off the finest rung on 56 of 132 bound frames
    # of a starved Sintel leg (-0.53 dB px / -0.87 dB 4x4); 0.90 strands 3%
    # of fixture 008's wire. Anything outside [0.98, 0.99] is out of band.
    expect(enc.TILE_SPEND_FRAC == 0.99,
           f"spend-preservation threshold must be 0.99, got {enc.TILE_SPEND_FRAC}")
    # ZERO, deliberately - 008 sits 0.001 of utilization under the
    # auto-budget target at its own operating point, so any positive slack
    # is a coin flip on whether its derived budget survives.
    expect(enc.TILE_SUPPLY_SLACK == 0.0,
           f"supply-preservation slack must be 0.0, got {enc.TILE_SUPPLY_SLACK}")
    # The COARSEST rung is the shape's own TILE_BAND band - i.e. exactly
    # today's fixed scheduler - so "spend-preserving" means "never less
    # wire than today" on letterbox shapes too; the FINEST is one whole
    # paint-order line on every shape, never a fragment of one.
    for shape, expect_band, expect_lad in (
            ("full", 1024, (256, 512, 1024)),
            ("classic", 1024, (256, 512, 1024)),
            ("16:9", 768, (192, 384, 768)),
            ("scope", 576, (144, 288, 576)),
            ("classic-wide", 1024, (256, 512, 1024))):
        w, h = enc.resolve_shape(shape)
        cm = (w == 320)
        line = h if cm else w
        band = enc.default_tile_px(w * h, width=w, height=h, column_major=cm)
        expect(band == expect_band,
               f"{shape}: band {band} != {expect_band}")
        lad = enc.tile_ladder_for(band)
        expect(lad == expect_lad, f"{shape}: ladder {lad} != {expect_lad}")
        expect(lad[-1] == band, f"{shape}: ladder must top out at its own band, got {lad}")
        expect(list(lad) == sorted(lad), f"{shape}: ladder must run fine -> coarse: {lad}")
        expect(len(set(lad)) == len(lad), f"{shape}: duplicate rung in {lad}")
        expect(all(g <= band for g in lad),
               f"{shape}: no rung may be coarser than today's band: {lad}")
        # THE WHOLE-LINE FLOOR, stated directly: every rung is an exact
        # multiple of one paint-order line, and none is smaller than one.
        expect(all(g >= line and g % line == 0 for g in lad),
               f"{shape}: rung splits a paint-order line ({line} px): {lad}")


@case(18, "adaptive tile ladder - band importance is sqrt(err2); raw err2 is WITHDRAWN")
def t18_err2_weight():
    # The pal9j wave also replaced the sqrt(err2) band-importance weight with
    # raw err2. That is NOT part of the shipped re-cut, and this case is why.
    # Isolated on real fixtures (ladder collapsed to its band rung so only the
    # weight varied, three streamed clips pinned at their pal9i budgets), raw
    # err2 reads better on two and costs the third its BUDGET: on fixture 008
    # it buys nothing (residual 52.87% -> 52.80%, line CV 0.853 -> 0.867) and
    # raises utilization 0.899 -> 0.902, which is over the auto-budget target,
    # so 008's derived budget falls 0.44 -> 0.43 and 2.3% of its wire with it.
    # 008 is the silicon-validated control. Same currency error as the ladder
    # made - quality bought with decode-T, paid for in bytes by a search the
    # author never sees.
    src = inspect.getsource(enc.encode_delta)
    expect("np.sqrt(err2_flat)" in src,
           "band importance must be sqrt(err2) - the pal9i weight")
    expect("w_e = np.where(mask_full, err2_flat, 0.0)" not in src,
           "the raw-err2 weight is withdrawn (it cost fixture 008 a budget step)")
    # And the weight really is the one being applied: two changed bands built
    # so the two weights RANK THEM OPPOSITELY -
    #   A - narrow (60 B) and badly wrong (err2 40000/px): err2 2.4e6, sqrt 12000
    #   B - wide (900 B) and mildly wrong (err2 400/px):   err2 3.6e5, sqrt 18000
    # sqrt flattens towards AREA and ranks B first; raw err2 ranks A first.
    # The cap admits A's band and nothing bigger, so under the SHIPPED sqrt
    # weight the top-1 prefix is B, B does not fit, and the frame keeps
    # NOTHING - which is exactly what distinguishes the two.
    n = 4096
    tile = 1024
    prev = np.zeros(n, dtype=np.uint8)
    target = prev.copy()
    rng = np.random.default_rng(18)
    err2 = np.zeros(n, dtype=np.float32)
    target[100:160] = rng.integers(200, 256, size=60, dtype=np.uint8)   # A, tile 0
    err2[100:160] = 40000.0
    target[1100:2000] = rng.integers(20, 40, size=900, dtype=np.uint8)  # B, tile 1
    err2[1100:2000] = 400.0
    # TILE sums, not pixel sums - B must sit wholly inside ONE tile or both
    # weights rank tile 0 first and the fixture proves nothing.
    t0e, t1e = err2[0:1024].sum(), err2[1024:2048].sum()
    t0s, t1s = np.sqrt(err2)[0:1024].sum(), np.sqrt(err2)[1024:2048].sum()
    expect(t0e > t1e, f"fixture: err2 must rank tile A first ({t0e} vs {t1e})")
    expect(t0s < t1s, f"fixture: sqrt must rank tile B first ({t0s} vs {t1s})")

    cap = 200          # ~ one 60 B copy plus headers; B's 900 B cannot fit
    gcls, gstarts, glens, b, t, mode, binding, payload = enc.encode_delta(
        target, err2, cap, None, surface_flat=prev, tile_px=tile)
    expect(mode.startswith("region:"), f"expected the bound path, got {mode}")
    expect(b <= cap, f"bound stream exceeds its cap: {b} > {cap}")
    surf = prev.copy()
    dec.run_payload(payload, 0, surf, n)
    a_kept = not np.array_equal(surf[100:160], prev[100:160])
    b_kept = not np.array_equal(surf[1100:2000], prev[1100:2000])
    expect(not a_kept, "the sqrt weight ranks the wide mild band B first, so "
                       "the narrow badly-wrong band A is NOT the top prefix "
                       "(this is the weight's known cost, and the price of "
                       "not cutting fixture 008's budget)")
    expect(not b_kept, "the wide mild band B does not fit and must be deferred")


@case(18, "adaptive tile ladder - spend + supply preservation is exactly the rule")
def t18_spend_preservation():
    # A real-ish bound frame on the shape that regressed: a MODE-0 256x192
    # surface with ten scattered changed streaks of differing length and
    # severity (one big uniform block never makes the ladder adapt - the
    # rungs then differ only in where they cut the same run), scheduled at a
    # spread of caps so different rungs win.
    rng = np.random.default_rng(2002)
    n = 256 * 192
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    for _ in range(10):
        a = int(rng.integers(0, n - 3000))
        ln = int(rng.integers(200, 3000))
        target[a:a + ln] = rng.integers(0, 256, size=ln, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    lad = enc.tile_ladder_for(1024)
    price = _price_for(256, 192)
    seen = set()
    for cap_b, cap_t in ((3000, None), (6000, 120000), (10000, None),
                         (10000, 300000), (16000, 120000), (24000, 120000)):
        costs = _ladder_costs(target, err2, prev, cap_b, cap_t, lad)
        resid = _ladder_residuals(target, err2, prev, cap_b, cap_t, lad)
        spends = {g: bt[0] for g, bt in costs.items()}
        want = _expected_rung(costs, lad, enc.TILE_SPEND_FRAC, price,
                              enc.TILE_SUPPLY_SLACK, resid)
        r = enc.encode_delta(target, err2, cap_b, cap_t, surface_flat=prev,
                             tile_ladder=lad, supply_px=price)
        gcls, gstarts, glens, b, t, mode, binding, payload = r
        seen.add(want)
        expect(mode.endswith(f"@{want}"),
               f"cap ({cap_b},{cap_t}): rule says rung {want}, encoder said {mode} "
               f"(costs {costs})")
        expect(b == spends[want],
               f"cap ({cap_b},{cap_t}): chosen rung must spend what that rung "
               f"spends: {b} != {spends[want]}")
        # the two invariants themselves, stated directly. WIRE is measured
        # against the COARSE rung - today's fixed scheduler - because that
        # is the thing the ladder is forbidden to undercut; the best-spend
        # form of the guard binds only when a FINER rung was actually taken
        # (that is the decode-T inversion it exists to catch).
        expect(b >= spends[lad[-1]],
               f"cap ({cap_b},{cap_t}): the ladder spent LESS wire than "
               f"today's band scheduler: {b} < {spends[lad[-1]]}")
        if want != lad[-1]:
            expect(b >= enc.TILE_SPEND_FRAC * max(spends.values()),
                   f"cap ({cap_b},{cap_t}): a finer rung stranded wire: "
                   f"{b} < {enc.TILE_SPEND_FRAC} * {max(spends.values())}")
        ceil_ms = enc.frame_supply_ms(*costs[lad[-1]], price) * (
            1.0 + enc.TILE_SUPPLY_SLACK)
        expect(enc.frame_supply_ms(b, t, price) <= ceil_ms,
               f"cap ({cap_b},{cap_t}): supply preservation violated: "
               f"{enc.frame_supply_ms(b, t, price)} > {ceil_ms}")
        expect(resid[want] <= resid[lad[-1]],
               f"cap ({cap_b},{cap_t}): the chosen rung leaves MORE error "
               f"than today's band: {resid[want]} > {resid[lad[-1]]}")
        # ... and no FINER rung was available that passed BOTH tests
        for g in lad:
            if g == want:
                break
            gb, gt = costs[g]
            expect(gb < max(spends[lad[-1]],
                            enc.TILE_SPEND_FRAC * max(spends.values()))
                   or enc.frame_supply_ms(gb, gt, price) > ceil_ms
                   or resid[g] > resid[lad[-1]],
                   f"cap ({cap_b},{cap_t}): finer rung {g} was admissible and "
                   f"should have won over {want}")
        expect(b <= cap_b, f"bound stream exceeds its byte cap: {b} > {cap_b}")
        if cap_t is not None:
            expect(t <= cap_t, f"bound stream exceeds its decode-T cap: {t} > {cap_t}")
        surf = prev.copy()
        pos, cursor, term = dec.run_payload(payload, 0, surf, n, issues=None)
        expect(term == enc.OP_FEND and pos == len(payload),
               "every ladder rung must still emit a cleanly-terminated stream")
    expect(len(seen) > 1,
           f"fixture is degenerate - the ladder never adapted (always {seen})")


@case(18, "adaptive tile ladder - a FIXED fine tile strands wire (decode-T inversion); the ladder does not")
def t18_fixed_fine_tile_strands_wire():
    # THE RISK THIS RULE EXISTS FOR. On a decode-T-bound frame a fine tile
    # fragments the op stream: per-op dispatch saturates cap_t while byte
    # budget is left UNSPENT. Measured live during the A/B setup on 320-wide
    # content - a fine tile reached util_T 0.998 at 47% of the byte budget.
    rng = np.random.default_rng(1812)
    n = 320 * 256
    prev = np.zeros(n, dtype=np.uint8)
    target = prev.copy()
    target[10000:60000] = rng.integers(0, 256, size=50000, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    # The sub-line rungs are RETIRED from the shipped ladder, but the
    # inversion they demonstrate is exactly why spend preservation exists,
    # so it is still exercised here with an explicit fixed fine tile.
    lad = enc.tile_ladder_for(1024)
    price = _price_for(320, 256)
    cap_b, cap_t = 20000, 120000        # T binds well before bytes do
    fine = _ladder_spends(target, err2, prev, cap_b, cap_t, (32, 64))
    coarse = _ladder_spends(target, err2, prev, cap_b, cap_t, lad)[lad[-1]]
    expect(fine[32] < 0.60 * coarse,
           f"fixture: a fixed 32 B tile must visibly strand wire here "
           f"(spent {fine[32]} of the coarse rung's {coarse})")
    expect(fine[64] < 0.75 * coarse,
           f"fixture: a fixed 64 B tile must strand wire too ({fine[64]}/{coarse})")
    r = enc.encode_delta(target, err2, cap_b, cap_t, surface_flat=prev,
                         tile_ladder=lad, supply_px=price)
    b, t, mode = r[3], r[4], r[5]
    expect(b >= coarse,
           f"the ladder must NOT strand wire: {b} < {coarse} (mode {mode})")
    expect(t <= cap_t, f"and must still fit the decode-T cap: {t} > {cap_t}")
    # Same frame, decode-T cap LIFTED ENTIRELY. Under the first cut of the
    # ladder that made the finest rung "free" (its bytes now match) and it
    # won. It must NOT win here: an uncapped frame still costs the SD
    # producer every T it burns, the supply gate still charges it, and the
    # auto-budget search still answers with wire bytes. That is precisely
    # the substitution owner silicon caught on 007, and the supply test is
    # what refuses it.
    free = _ladder_costs(target, err2, prev, cap_b, None, lad)
    r2 = enc.encode_delta(target, err2, cap_b, None, surface_flat=prev,
                          tile_ladder=lad, supply_px=price)
    g2 = int(r2[5].split("@")[-1].split(":")[0])
    ceil2 = enc.frame_supply_ms(*free[lad[-1]], price) * (
        1.0 + enc.TILE_SUPPLY_SLACK)
    expect(enc.frame_supply_ms(*free[g2], price) <= ceil2,
           f"an uncapped frame must still not buy granularity with supply: "
           f"rung {g2} (costs {free})")
    expect(free[lad[0]][1] > free[lad[-1]][1],
           f"fixture: the finest rung must cost MORE decode T here, else this "
           f"case proves nothing ({free})")
    expect(g2 == lad[-1],
           f"the finest rung costs {free[lad[0]][1]:.0f} T against the band's "
           f"{free[lad[-1]][1]:.0f} and must be refused, got {r2[5]}")


@case(18, "adaptive tile ladder - never spends less wire than the fixed scheduler it replaces")
def t18_never_below_today():
    # The byte-utilisation guard, in unit form: across a spread of random
    # bound frames and caps, the ladder's spend is never below the guard
    # against the fixed TILE_BAND schedule (= today's encoder). A drop here
    # is the decode-T inversion re-appearing.
    lad = enc.tile_ladder_for(1024)
    price = _price_for(320, 256)
    n = 320 * 256
    for seed in range(4):
        rng = np.random.default_rng(1900 + seed)
        prev = rng.integers(0, 256, size=n, dtype=np.uint8)
        target = prev.copy()
        for _ in range(6):
            a = int(rng.integers(0, n - 9000))
            ln = int(rng.integers(500, 9000))
            target[a:a + ln] = rng.integers(0, 256, size=ln, dtype=np.uint8)
        err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
        for cap_b, cap_t in ((4000, 40000), (12000, 90000), (30000, None)):
            today = enc.encode_delta(target, err2, cap_b, cap_t,
                                     surface_flat=prev, tile_px=lad[-1])[3]
            lad_b = enc.encode_delta(target, err2, cap_b, cap_t,
                                     surface_flat=prev, tile_ladder=lad,
                                     supply_px=price)[3]
            expect(lad_b >= today,
                   f"seed {seed} cap ({cap_b},{cap_t}): ladder spent {lad_b} vs "
                   f"today's {today} - the ladder may never spend LESS wire "
                   f"than the fixed band scheduler it refines")


@case(18, "adaptive tile ladder - encode_clip drives it: every bound frame names a ladder rung")
def t18_end_to_end_clip():
    # Synthetic starved streaming encode (same recipe as the step-6/11
    # bound-path cases): every budget-bound frame's mode must carry an
    # '@<rung>' suffix naming a rung of THIS shape's ladder, and the
    # emitted stream must still decode byte-identically to the encoder's
    # own surface.
    width, height = 320, 256
    raw = width * height
    nframes = 24
    rng = np.random.default_rng(1813)
    yy, xx = np.mgrid[0:height, 0:width]
    base = np.stack([(xx * 255 // width).astype(np.uint8),
                     (yy * 255 // height).astype(np.uint8),
                     np.full((height, width), 90, dtype=np.uint8)], axis=-1)
    orig = []
    for i in range(nframes):
        f = base.copy()
        y = 20 + (i * 9) % (height - 80)
        f[y:y + 60, :, :] = rng.integers(0, 256, size=(60, width, 3), dtype=np.uint8)
        orig.append(f)
    orig = np.stack(orig)
    chg, po_ceil = _synth_clip(orig)
    res = enc.encode_clip(orig, chg, po_ceil, width, height, 25.0,
                          cap_bytes_frac=0.02, budget_scale=0.10)
    lad = enc.tile_ladder_for(enc.default_tile_px(
        raw, width=width, height=height, column_major=True))
    rungs = set()
    bound = 0
    for m, bind in zip(res["per_frame"]["mode"], res["per_frame"]["binding"]):
        if bind != "budget":
            continue
        bound += 1
        expect("@" in m, f"a budget-bound frame must name its ladder rung: {m}")
        g = int(m.split("@")[-1].split(":")[0])
        expect(g in lad, f"rung {g} is not on this shape's ladder {lad} (mode {m})")
        rungs.add(g)
    expect(bound > 0, "fixture did not produce a budget-bound frame")
    expect(rungs, "no rungs recorded")
    # And every ladder-scheduled delta payload is still a structurally
    # valid, cleanly-terminated op stream (keyframe-span chunks are a
    # different payload shape and are covered by the step-12 cases).
    surf = np.zeros(raw, dtype=np.uint8)
    for i, (payload, mode) in enumerate(zip(res["payloads"], res["per_frame"]["mode"])):
        if mode.startswith("kf"):
            continue
        pos, cursor, term = dec.run_payload(payload, 0, surf, raw, issues=None)
        expect(term == enc.OP_FEND, f"frame {i}: stream must terminate with FEND")
        expect(pos == len(payload),
               f"frame {i}: decoder must consume the whole payload: {pos} != {len(payload)}")


@case(18, "adaptive tile ladder - an UNPRICED ladder is refused outright")
def t18_ladder_must_be_priced():
    # The pal9j regression in one line: a ladder whose admissibility test
    # cannot see decode-T trades T for granularity, the supply gate charges
    # the T, and the auto-budget search pays for it in wire BYTES without
    # anyone asking. encode_delta must not let that happen silently.
    n = 4096
    rng = np.random.default_rng(1815)
    prev = np.zeros(n, dtype=np.uint8)
    target = prev.copy()
    # RANDOM, not a flat fill - a constant run costs four bytes and would
    # sail through the fast path without ever reaching the ladder.
    target[100:2000] = rng.integers(1, 256, size=1900, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    lad = enc.tile_ladder_for(1024)
    try:
        enc.encode_delta(target, err2, 300, 40000, surface_flat=prev,
                         tile_ladder=lad)
    except ValueError as exc:
        expect("supply_px" in str(exc),
               f"the refusal must name the missing price: {exc}")
    else:
        expect(False, "a tile_ladder with no supply_px must raise, not "
                      "silently fall back to the unpriced rule")
    # ... and the same call WITH a price works.
    r = enc.encode_delta(target, err2, 300, 40000, surface_flat=prev,
                         tile_ladder=lad, supply_px=_price_for(256, 192))
    expect("@" in r[5], f"a priced ladder must still name its rung: {r[5]}")


@case(18, "adaptive tile ladder - THE INVARIANT: the ladder cannot reduce the derived budget")
def t18_ladder_cannot_cost_budget():
    # WHY THIS CASE EXISTS (owner silicon 2026-07-30, fixture 007). The first
    # cut of the ladder guarded BYTES only. Finer rungs fragment the op
    # stream, decode-T rose 37% on 007's bound frames, the supply gate
    # charged it as busy_ms, measured utilization went 0.892 -> 0.985 at the
    # SAME budget, and the auto-budget search - which the approving A/B had
    # deliberately pinned away - answered by cutting 007 from 0.64 to 0.47.
    # Nineteen percent of the wire, gone, to buy tile granularity.
    #
    # The invariant that forbids it: THE LADDER'S MEAN SUPPLY COST MAY NOT
    # EXCEED THE FIXED BAND SCHEDULER'S. utilization is a strictly
    # increasing function of that mean (stream_supply_check), and the
    # search's answer is a decreasing function of utilization, so a ladder
    # that cannot raise the mean cannot lower the budget. This case measures
    # the mean both ways over a real starved encode.
    width, height = 256, 192          # MODE-0 - the shape that regressed
    raw = width * height
    nframes = 20
    rng = np.random.default_rng(1814)
    yy, xx = np.mgrid[0:height, 0:width]
    base = np.stack([(xx * 255 // width).astype(np.uint8),
                     (yy * 255 // height).astype(np.uint8),
                     np.full((height, width), 70, dtype=np.uint8)], axis=-1)
    orig = []
    for i in range(nframes):
        f = base.copy()
        y = 10 + (i * 7) % (height - 70)
        f[y:y + 50, :, :] = rng.integers(0, 256, size=(50, width, 3), dtype=np.uint8)
        orig.append(f)
    orig = np.stack(orig)
    chg, po_ceil = _synth_clip(orig)
    band = enc.default_tile_px(raw, width=width, height=height,
                               column_major=False)
    lad = enc.tile_ladder_for(band)
    price = _price_for(width, height)

    def run(ladder_rungs):
        real = enc.tile_ladder_for
        enc.tile_ladder_for = lambda c: ladder_rungs
        try:
            return enc.encode_clip(orig, chg, po_ceil, width, height, 25.0,
                                   cap_bytes_frac=0.03, budget_scale=0.12)
        finally:
            enc.tile_ladder_for = real

    fixed = run((band,))               # the ladder collapsed to today's band
    ladder = run(lad)                  # the shipped ladder

    def mean_supply_ms(res):
        pf = res["per_frame"]
        n = len(pf["t"])
        return sum(enc.frame_supply_ms(len(p), t, price)
                   for p, t in zip(res["payloads"], pf["t"])) / n

    m_fixed, m_lad = mean_supply_ms(fixed), mean_supply_ms(ladder)
    expect(m_lad <= m_fixed + 1e-9,
           f"THE LADDER COST SUPPLY: mean {m_lad:.4f} ms/frame vs the fixed "
           f"band scheduler's {m_fixed:.4f} - the auto-budget search would "
           f"answer that by cutting the budget, i.e. the wire (pal9j on 007)")
    # It must also not have thrown wire away to achieve that.
    b_fixed = sum(len(p) for p in fixed["payloads"])
    b_lad = sum(len(p) for p in ladder["payloads"])
    expect(b_lad >= b_fixed,
           f"ladder spent {b_lad} B against the fixed scheduler's {b_fixed} - "
           f"fewer bytes is a wire loss however good the tiling looks")
    # ... nor a worse picture: the whole-clip PSNR must not fall either.
    p_fixed = float(np.mean(fixed["per_frame"]["psnr"]))
    p_lad = float(np.mean(ladder["per_frame"]["psnr"]))
    expect(p_lad >= p_fixed - 1e-9,
           f"ladder PSNR {p_lad:.4f} < the fixed scheduler's {p_fixed:.4f}")
    # And the per-frame invariant on every budget-bound frame, read straight
    # off the modes: the rung it named is one of this shape's, and no rung
    # this shape offers can split a paint-order line.
    bound = 0
    for m, bind in zip(ladder["per_frame"]["mode"],
                       ladder["per_frame"]["binding"]):
        if bind != "budget":
            continue
        bound += 1
        g = int(m.split("@")[-1].split(":")[0])
        expect(g in lad, f"rung {g} is not on this shape's ladder {lad}")
        expect(g % width == 0,
               f"rung {g} splits a {width}px paint-order line (mode {m})")
    expect(bound > 0, "fixture did not produce a budget-bound frame")


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
        except (Exception, SystemExit) as exc:
            # SystemExit is NOT an Exception: the encoder's supply gates
            # raise it, so without naming it here an unexpected gate
            # refusal killed the whole run at that case - no [FAIL] line
            # and no summary at all (observed on the Card #5
            # recalibration wave, which is how this was found).
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
