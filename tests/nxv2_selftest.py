#!/usr/bin/env python3
"""tests/nxv2_selftest.py - plain-python selftest for NXV v2 (SP15 T1).

No pytest dependency: `python tests\\nxv2_selftest.py` runs every case,
prints a PASS/FAIL line per case plus a summary, and exits 0 if all
passed, 1 otherwise. Cases are grouped by the encoder's 8 TDD steps
(header roundtrip, opcode/decoder roundtrip, keyframe span, scene
segmentation, palettes, rate control, ring sizing, CLI rewire) - the
suite accumulates as each step lands.

Steps 4/6/7 hit the real demo sources (tools/demo-files/) via ffmpeg and
run genuine (short-duration) encodes - they are the slow cases in this
file by design (real-footage sanity anchors, not synthetic unit tests).
"""
import contextlib
import inspect
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np

import nxv2enc as enc
import nxv2dec as dec
import nxv2_bench_rows as bench

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


@contextlib.contextmanager
def _at_chunk_cap(cap):
    """Evaluate the T model at a historic NXV2_DMA_CHUNK.

    A silicon row was taken under one burst-cap value; if the cap has
    since moved, the same op costs differently on the current player,
    so the row must be replayed under its own cap, not today's. Both
    DMA caps move together - fill and copy share vid_chunk_dst_flat/_gap."""
    saved = (enc.TMODEL_COEFFS["copy_dma_chunk"],
             enc.TMODEL_COEFFS["fill_dma_min"])
    enc.TMODEL_COEFFS["copy_dma_chunk"] = cap
    enc.TMODEL_COEFFS["fill_dma_min"] = cap
    try:
        yield
    finally:
        (enc.TMODEL_COEFFS["copy_dma_chunk"],
         enc.TMODEL_COEFFS["fill_dma_min"]) = saved


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
        # MONO REFUSED (2026-08-03): channels == 1 used to be a legal
        # header. It is now refused by the encoder exactly as the
        # player refuses it at open (VID FMT?) - two halves of one
        # contract, and the reason NXV2_OFF_ACHAN is still validated.
        dict(width=256, height=192, fps=25, channels=1, arate=15625,
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


@case(1, "audio layout - NXV player bound (T10 circular feed, 3072B/frame) enforced at encode time")
def t1_audio_player_bound():
    # SP17 T10: the player's circular audio feed is one ring in the
    # session audio bank and NXV_AUD_FRAME_MAX caps a header's REAL
    # audio at 3072 bytes/frame (open rejects more with VID FMT?).
    # audio_layout must refuse to lay out such an encode with a named
    # error - the floor is fps >= ~10.17.
    expect(enc.AUD_RING == 8192, "ring matches NXV_AUD_RING (whole audio bank)")
    expect(enc.AUD_GUARD == 16, "guard matches NXV_AUD_GUARD")
    expect(enc.AUD_FRAME_MAX == 3072, "bound matches NXV_AUD_FRAME_MAX")
    # 25 fps: 625*2 = 1250 <= 3072 - accepted (and its layout
    # is BYTE-IDENTICAL to the pre-T10 layout: same samples/real/pad)
    rate, samples, real, padded = enc.audio_layout(25, 2)
    expect((samples, real, padded) == (625, 1250, 1536),
           "25fps layout unchanged by the bound move")
    expect(rate == enc.RATE_STEREO, "one rate, the stereo pair rate")
    # MONO IS REFUSED (2026-08-03): channels == 1 was a supported
    # layout and is now a ValueError here, matching pack_header and
    # the player's own open-time VID FMT?.
    for bad in (1, 0, 3):
        try:
            enc.audio_layout(20, bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"audio_layout must refuse channels={bad}")
    # 20 fps: round(15625/20)*2 = 1562 - LEGAL now (was the
    # canonical pre-T10 rejection)
    rate, samples, real, padded = enc.audio_layout(20, 2)
    expect(real == 1562, "20fps legal under the T10 bound")
    # 6 fps: round(15625/6)*2 = 5208 > 3072 - rejected, naming the
    # bound and the floor. No --mono remedy exists any more.
    try:
        enc.audio_layout(6, 2)
    except SystemExit as e:
        msg = str(e)
        expect("3072" in msg, "error names the 3072-byte player bound")
        expect("10.17" in msg, "error names the fps floor")
        expect("--mono" not in msg, "the withdrawn --mono is never suggested")
    else:
        raise AssertionError("6fps must be rejected (5208 > 3072)")
    # 10 fps: 3126 > 3072 - rejected, and the only remedy offered is a
    # higher fps (mono used to fit here and used to be suggested)
    try:
        enc.audio_layout(10, 2)
    except SystemExit as e:
        expect("--mono" not in str(e), "no --mono remedy exists")
        expect("raise --fps" in str(e), "the remedy is a higher fps")
    else:
        raise AssertionError("10fps must be rejected (3126 > 3072)")
    # the floor is the boundary: just above passes, just below rejects
    expect(enc.audio_layout(10.17, 2)[2] <= enc.AUD_FRAME_MAX, "10.17 fits")
    try:
        enc.audio_layout(10.16, 2)
    except SystemExit:
        pass
    else:
        raise AssertionError("10.16fps must be rejected")
    # the two headline unlocks (the hardware-round legs)
    expect(enc.audio_layout(12.5, 2)[2] == 2500,
           "320x256@12.5 is legal (2500 <= 3072)")
    expect(enc.audio_layout(24, 2)[2] == 1302,
           "native 24fps is legal (1302 <= 3072)")


@case(1, "audio floor arithmetic - T10 circular-feed floors pinned (bound/ring derivation)")
def t1_audio_floor_arithmetic():
    # SP17 T10: pin the derivation, not just the outcomes. The floor
    # formula is fps > rate/(smax + 0.5) with smax = AUD_FRAME_MAX //
    # 2 - identical formula since the pre-T10 halves, only the
    # bound moves. The bound is NO LONGER ring-guard (2026-08-02): the
    # ring is the whole 8 KB audio bank, and AUD_FRAME_MAX is pinned
    # instead by the player's 8-bit block arithmetic (cap 240 + apad
    # + 1 must stay inside a byte, and the ring-fit test adds apad + 2
    # on top, so apad <= 6 blocks = 3072 padded bytes).
    import math as _m
    expect(enc.AUD_RING == 8192 and enc.AUD_GUARD == 16,
           "ring is the whole audio bank, guard unchanged")
    expect(2 * enc.AUD_FRAME_MAX <= enc.AUD_RING - enc.AUD_GUARD,
           "TWO max frames fit the ring's usable span - the feed is "
           "one-pass by construction at every legal fps")
    expect(((enc.AUD_FRAME_MAX + 511) // 512) <= 6,
           "the padded section stays inside 6 blocks (the player's "
           "8-bit cap+apad+1 and need+apad+2 adds)")
    expect(abs(enc.min_fps_for() - 15625 / (3072 // 2 + 0.5)) < 1e-12,
           "floor = 15625/1536.5")
    # the user-facing (ceil to 0.01) floor named in every message
    expect(_m.ceil(enc.min_fps_for() * 100) / 100 == 10.17,
           "floor rounds to 10.17")
    # every layout at and above the shown floor respects the bound
    for fps in (10.17, 12.5, 23.976, 24, 25):
        expect(enc.audio_layout(fps, 2)[2] <= enc.AUD_FRAME_MAX,
               f"{fps} fps within the T10 bound")
    # THE FIX THIS BOUND EXISTS TO GUARANTEE: no legal encode is
    # room-limited in the player's post-present pump any more.
    for fps in (10.17, 12.5, 20, 23.976, 25):
        real = enc.audio_layout(fps, 2)[2]
        expect(enc.pace_trickle_frac(real) == 0.0,
               f"{fps} fps feeds in one pass (no pace contention)")


@case(1, "streaming supply gate - silicon-calibrated (Card #3 VSTR0/VSTR1 anchors)")
def t1_stream_supply_gate():
    # A ring-streamed file must be PRODUCIBLE: mean decode wall time +
    # mean SD fetch time must fit the frame period (utilization <= 1.0
    # or nxv2enc.encode refuses to write). Anchored on silicon runs of
    # fixtures 007 (streamable) and 008 (collapsed, underran every frame).
    clock = enc.TMODEL_COEFFS["clock_khz"]
    # silicon_r: measured composed-player ratios, density-keyed (W4).
    # With no density (planning-time callers) every class fails safe to
    # its SPARSE-end anchor - the largest measured R in the class.
    expect(enc.silicon_r(256, 192) == max(r for _, r in enc.TMODEL_SILICON_R["flat_256"]),
           "classic flat R")
    expect(enc.silicon_r(320, 256) == max(r for _, r in enc.TMODEL_SILICON_R["flat_320"]),
           "full flat R")
    # Gapped heights have no reliable 1/height slope (silicon rows
    # swapped order on re-measurement), so every gapped height reads
    # one density-keyed class, including unmeasured sub-144 heights.
    worst_gapped = max(r for _, r in enc.TMODEL_SILICON_R["gapped"])
    expect(enc.silicon_r(320, 192) == worst_gapped,
           "gapped 192 fails safe to the sparse-end gapped R")
    expect(enc.silicon_r(320, 144) == worst_gapped,
           "gapped 144 reads the same class (no height key)")
    expect(enc.silicon_r(320, 100) == worst_gapped,
           "sub-144 gapped is unmeasured - the same class, never an extrapolation")
    expect(enc.silicon_r(256, 100) == max(r for _, r in enc.TMODEL_SILICON_R["flat_256"]),
           "the gapped R must not leak into the flat 256 cluster")
    # busy_ms is true decode wall time (silicon_r already carries /af,
    # so the gate divides by af again). Anchors state busy_ms and
    # back-solve mean_t through that identity to stay pinned to it.
    af = enc.TMODEL_COEFFS["audio_factor"]

    def _mean_t_for(busy_ms, width, height):
        t = busy_ms * clock * af / enc.silicon_r(width, height)
        for _ in range(30):
            r = enc.silicon_r(width, height,
                              density=t / enc.usable_budget_t(25.0, width, height))
            t = busy_ms * clock * af / r
        return t

    expect(abs(enc.stream_supply_check(_mean_t_for(20.0, 320, 256), 20000.0,
                                       1536, 25.0, 320, 256)["busy_ms"] - 20.0) < 1e-9,
           "busy_ms must be the true silicon decode time the anchor names")
    # Fixture 008's first encode is unstreamable at its measured
    # demand and decode time.
    t8 = _mean_t_for(30.187, 320, 256)
    s8 = enc.stream_supply_check(t8, 43520.0, 1536, 25.0, 320, 256)
    expect(1.70 < s8["utilization"] < 1.80,
           f"008 anchor utilization {s8['utilization']:.2f} (silicon: collapsed)")
    expect(0.45 < s8["suggested_budget"] < 0.55, "008 suggestion ~0.51")
    # Under the current op-walk model, fixture 008 must be REFUSED
    # (silicon: most frames underran) and 009 ADMITTED, though the
    # gate deliberately prices 009 only marginally inside the line.
    s008 = enc.stream_supply_check(349307.5, 28460.7, 1536, 25.0, 320, 256)
    expect(s008["utilization"] > 1.0,
           f"008 (silicon: 71-76% of frames underran) scores "
           f"{s008['utilization']:.3f} - the gate must refuse it")
    s009 = enc.stream_supply_check(302604.4, 23092.8, 1536, 25.0, 320, 192)
    expect(0.97 < s009["utilization"] < 1.05,
           f"009 sb0.54 (silicon clean) scores {s009['utilization']:.3f} - "
           f"the W4 gate may price it conservatively but only just")
    # The admit side uses 009's actual shipping auto-encode operating
    # point (mean padded payload + audio pad of the same file).
    s009a = enc.stream_supply_check(282340.9, 21435.0, 1536, 25.0, 320, 192)
    expect(0.90 < s009a["utilization"] < 1.0,
           f"009 auto (silicon: zero underruns, min depth 39-42) scores "
           f"{s009a['utilization']:.3f} - the gate must admit it")
    # The model must still bracket 008's measured frame time: never
    # optimistic beyond its error band, conservative only because
    # density interpolation reads above the stream's true R (safe side).
    predicted_008_ms = s008["busy_ms"] + s008["audio_ms"] + s008["sd_ms"]
    expect(42.05 - 0.85 < predicted_008_ms < 42.05 + 1.7,
           f"008 predicted frame {predicted_008_ms:.2f} ms vs 42.0/42.1 measured")
    # audio_ms is a real serial term the gate must include.
    expect(1.2 < s008["audio_ms"] < 1.5,
           f"audio copy term {s008['audio_ms']:.3f} ms (silicon: 20-21.6 ticks/frame)")
    # Suggested budget is self-consistent: scaling busy + payload-SD
    # by it must land mean utilization at STREAM_TARGET_UTIL (the
    # audio pad's fetch and copy cost stay invariant either way).
    sug = s8["suggested_budget"]
    wire_eff = enc.SD_WIRE_BYTES_PER_MS * af
    audio_sd = 1536 / wire_eff
    scaled = ((s8["busy_ms"] + (s8["sd_ms"] - audio_sd)) * sug
              + audio_sd + s8["audio_ms"])
    expect(abs(scaled / s8["period_ms"] - enc.STREAM_TARGET_UTIL) < 0.01,
           "suggested budget lands the target utilization")
    # monotonicity: more demand can only raise utilization
    expect(enc.stream_supply_check(302604.4, 30000.0, 1536, 25.0, 320, 192)["utilization"]
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
    abytes_pad = 1536                        # 2544 T10 player bound the
                                             # 3c pack_header defence
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
                            dither_mode=None, retime=None, **kw):
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


@case(2, "reserved-op rejection ($24/$2C/$30 SCROLL+retired OCOPY, $34, misaligned, $FF) - raises in decode mode, recorded in validate mode")
def t2_reserved_op_rejection():
    # Pre-scaled x4 opcode space: $2C (SCROLL, kept for T5b) and
    # $34-$3C are the reserved slots, any non-multiple-of-4 byte (e.g.
    # $02) is outside the set entirely. $24/$30 briefly held the SP17
    # T5a OCOPY8/OCOPY16 and RETURNED to the reserved set when that
    # coding was withdrawn (2026-08-02) - the player's stub slots are
    # plain error stubs again, and this pins the reference decoder to
    # the same verdict.
    expect(enc.OP_OCOPY8 not in enc.VALID_OPS
           and enc.OP_OCOPY16 not in enc.VALID_OPS,
           "the retired OCOPY opcodes must be outside VALID_OPS")
    for opcode in (enc.OP_OCOPY8, enc.OP_SCROLL, enc.OP_OCOPY16, 0x34, 0x02, 0xFF):
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

    hdr = enc.pack_header(width=width, height=height, fps=25, channels=2, arate=enc.RATE_STEREO,
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
    hdr = enc.pack_header(width=width, height=height, fps=25, channels=2, arate=enc.RATE_STEREO,
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
        hdr = enc.pack_header(width=256, height=1, fps=25, channels=2, arate=enc.RATE_STEREO,
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
            clip_path, width, height, fps, start, duration, str(FFMPEG), dither=False)
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
    # W4 re-base: the drift trigger lives in 4x4 local-mean space now -
    # the guarantee is on drift_lm against the lm refractory bar (the
    # per-pixel drift is diagnostics-only; it is structurally negative)
    drifts = result["per_frame"]["drift_lm"]
    bad = [(i, d) for i, d in enumerate(drifts) if not np.isnan(d) and d >= enc.DRIFT_LM_T_REFRACT]
    expect(bad == [], f"lm drift exceeded the refractory trigger on frames: {bad[:5]}")


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
    expect(len(planned) >= 2,
           f"test setup assumption broken: expected a multi-chunk keyframe plan at "
           f"{width}x{height}@{fps}, got {len(planned)} - re-tune this test's shape "
           f"if TMODEL_COEFFS changed (W4 peak pacing: 3 chunks here)")

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

    hdr = enc.pack_header(width=width, height=height, fps=fps, channels=2, arate=enc.RATE_STEREO,
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


@case(10, "silicon TMODEL adopted - two-key dispatch, K* self-retunes from coeffs")
def t10_silicon_coeffs():
    tc = enc.TMODEL_COEFFS
    # Re-fit 2026-09-15 (NXBO/NXBC/NXBK rows, VGA-0, core 3.02.04) after
    # the chunk-loop change. The TWO-KEY DISPATCH SPLIT stands; both
    # fast-handler envelopes fell, RUN 487.2 -> 367.4 and COPY
    # 336.3 -> 303.7, ratio 1.449 -> 1.210.
    expect("t_op_parse" not in tc, "the single-key t_op_parse must be RETIRED")
    expect(tc["t_op_run"] == 367.4, f"t_op_run should be the NXBO 367.4, got {tc['t_op_run']}")
    expect(tc["t_op_copy"] == 303.7, f"t_op_copy should be the NXBC 303.7, got {tc['t_op_copy']}")
    # >= not ==: t_op_misc is unmeasured and HELD at the dearest envelope
    # ever measured, which no longer equals t_op_run.
    expect(tc["t_op_misc"] >= tc["t_op_run"],
           "unmeasured simple dispatches must be at or above the dearest measured envelope")
    expect(tc["t_skip"] == 141.8, f"t_skip should be the NXBO SK00 141.8, got {tc['t_skip']}")
    expect(tc["t_skip16"] == 210.9, f"t_skip16 should be the NXBO S160 210.9, got {tc['t_skip16']}")
    # ... and the skip pricer actually uses the second key
    expect(enc.op_cost("skip", 255)[1] < enc.op_cost("skip", 256)[1],
           "a 16-bit skip must price at the dearer S160 envelope")
    expect(tc["fetch_long"] == 19.76, f"fetch_long should be the C080 19.76, got {tc['fetch_long']}")
    expect(tc["fetch_short"] == 19.80, f"fetch_short should be the NXBC fit 19.80, got {tc['fetch_short']}")
    expect(tc["fill_cpu"] == 15.86, f"fill_cpu should be the NXBO fit 15.86, got {tc['fill_cpu']}")
    # The fill DMA chunk cost and the 8-bit op's cheaper entry are now
    # carried separately (F256 gives the chunk, F071 the entry); they
    # sum to the 781.1 every break-even figure below reads.
    expect(tc["fill_dma_setup"] == 852.8, f"fill_dma_setup should be the F256 852.8, got {tc['fill_dma_setup']}")
    expect(tc["fill_dma_path_t"] == -71.7,
           f"fill DMA path term should be the F071 -71.7 T/op, got {tc['fill_dma_path_t']}")
    expect(tc["fill_dma_per_b"] == 5.1, f"fill_dma_per_b should be the silicon 5.1, got {tc['fill_dma_per_b']}")
    # The 240 B cap makes every 256-aligned op a chunk plus a tail, and
    # silicon charges a chunk-loop iteration on that tail. The 8-bit and
    # 16-bit terms differ for OPPOSITE reasons: on copy because
    # copy_dma_path_t already cancels the held setup's over-charge, so
    # the 8-bit branch has no slack to net against; on fill because the
    # 16-bit branch pays the t_skip16 - t_skip entry the 8-bit one does
    # not, and R161 measures only their sum.
    expect(tc["copy_dma_tail_t"] == 210.7, f"copy trailing-chunk term should be the C256/K256 210.7, got {tc['copy_dma_tail_t']}")
    expect(tc["copy_dma_tail8_t"] == 489.9, f"8-bit copy trailing-chunk term should be the 489.9 envelope, got {tc['copy_dma_tail8_t']}")
    expect(tc["fill_dma_tail_t"] == 399.0, f"fill trailing-chunk term should be the F256 399.0, got {tc['fill_dma_tail_t']}")
    expect(tc["fill_dma_tail8_t"] == 468.1, f"8-bit fill trailing-chunk term should be 468.1, got {tc['fill_dma_tail8_t']}")
    # Both 8-bit terms are ENVELOPES over the same unmeasured quantity:
    # C161/R161 measure the 16-bit entry and one chunk-loop iteration
    # only as a SUM, so each 8-bit tail takes the dearer end (entry
    # delta zero). These two relations keep the halves from drifting
    # apart; they are documentary, not independent - no scored row
    # constrains the split at all.
    expect(abs((tc["fill_dma_tail_t"] + tc["t_skip16"] - tc["t_skip"])
               - tc["fill_dma_tail8_t"]) < 1e-9,
           "the 16-bit fill entry plus its tail must equal the 8-bit tail - R161 measures that sum")
    # The copy pair carries one extra term: copy_dma_tail_t nets off one
    # chunk of the held setup's over-charge against the 2026-09-15
    # one-chunk cost, and the 8-bit branch has no such slack.
    copy_chunk_one = 881.65
    expect(abs((tc["copy_dma_tail8_t"] - tc["copy_dma_tail_t"]
                - (tc["t_skip16"] - tc["t_skip"]))
               - (tc["copy_dma_setup"] - copy_chunk_one)) < 0.2,
           "the 8-bit copy tail must exceed the 16-bit one by the 16-bit entry plus "
           "the held setup's per-chunk over-charge - re-fit all three together")
    # copy_dma_setup is HELD at its pre-change solve although the
    # 2026-09-15 ONE-chunk rows measure 881.7 T: the per-chunk cost
    # RISES with op length. The cap-256 rows, adjusted by the measured
    # 283.8 T/chunk loop saving, imply 819 (K256, 256 B), 918 (CD3,
    # 1024 B) and 1078 (KF, 43008 B); at 1091.8 the model prices the
    # keyframe class +0.8% over its row, at 881.7 it would price it
    # 8.0% UNDER. copy_dma_tail_t is fitted against this held value.
    expect(tc["copy_dma_setup"] == 1091.8, f"copy_dma_setup should be the silicon 1091.8, got {tc['copy_dma_setup']}")
    expect(tc["copy_dma_per_b"] == 5.10, f"copy_dma_per_b should be the NXBC (C103-C081)/22 slope 5.10, got {tc['copy_dma_per_b']}")
    # The audio-safety burst cap. 256 -> 240 on 2026-08-03: at 256 the
    # player's DI bracket ran 1801 T, 9 T over the VGA-0 1792 T audio
    # period - a bracket starting within 9 T of an edge loses one tick
    # (about 0.5% of brackets). The PLAY= rows recorded that date
    # (+2.1..+5.2% over nominal) came from the DEBUG edge-dropping
    # instrument and do not measure this mechanism. COPY and FILL share
    # ONE cap because the player clips both through vid_chunk_dst_flat/
    # _gap, and it must be <= 255 because their compares and both kernel
    # selects are single-byte.
    expect(tc["copy_dma_chunk"] == 240, "copy DMA chunk must be the 240 B audio-safety cap (NXV2_DMA_CHUNK)")
    expect(tc["fill_dma_min"] == tc["copy_dma_chunk"],
           "fill and copy DMA chunk caps must be the SAME NXV2_DMA_CHUNK (vid_chunk_dst_flat/_gap clips both)")
    expect(tc["copy_dma_chunk"] <= 255,
           "the DMA chunk cap must fit one byte (vid_chunk_dst_flat/_gap / kernel selects are single-byte)")
    # The two kernel-select thresholds mirror src/nextdaad.inc's
    # NXV2_RUN_DMA_MIN / NXV2_COPY_DMA_MIN. If these pins fail because
    # the player moved, the model must move with it.
    expect(tc["copy_dma_min"] == 81, "copy DMA threshold must be the PLAYER's NXV2_COPY_DMA_MIN (81)")
    expect(tc["copy_dma_path_t"] == -227.9,
           "copy DMA path term must be the C081 -227.9 T/op (setup held)")
    expect(tc["run_dma_min"] == 71, "fill DMA threshold must be the PLAYER's NXV2_RUN_DMA_MIN (71)")
    expect(tc["t_frame_fixed"] == 1132.0, "t_frame_fixed should be the silicon FE 1132")
    # Shape given explicitly (320x256, flat): the no-shape default is
    # the pessimistic gapped factor, so a bare call here would not
    # read the flat cap.
    expect(abs(enc.usable_budget_t(25.0, 320, 256) - 800000.0) < 1.0,
           f"silicon usable budget @25 (flat 320x256) should be 800000.0 T, got {enc.usable_budget_t(25.0, 320, 256)}")
    # Composition factor = worst dense measured R x 1.12 (standing
    # rule) - if R is re-fit, the factor must move with it or the
    # cap silently loses its margin.
    cf = enc.TMODEL_COMPOSITION_FACTOR
    expect(cf["flat"] == 1.19, f"flat composition factor should be 1.19, got {cf['flat']}")
    expect(cf["gapped"] == 1.46, f"gapped composition factor should be 1.46, got {cf['gapped']}")
    # the de-rating must still BE a de-rating, and must still exceed
    # every anchored R in its class (margin, not a coincidence). The
    # gapped height ORDER is deliberately not asserted - Card #8
    # inverted it, which is why silicon_r() keys on density, not height.
    expect(cf["gapped"] > max(r for _, r in enc.TMODEL_SILICON_R["gapped"]),
           "gapped factor must carry margin over every anchored gapped R")
    expect(cf["flat"] > max(r for anchors in
                            (enc.TMODEL_SILICON_R["flat_256"],
                             enc.TMODEL_SILICON_R["flat_320"])
                            for _, r in anchors),
           "flat factor must carry margin over every anchored flat R")
    expect(enc.is_gapped(320, 192) and enc.is_gapped(320, 144),
           "mode-1 sub-256 heights are gapped")
    expect(not enc.is_gapped(320, 256) and not enc.is_gapped(256, 144)
           and not enc.is_gapped(256, 192),
           "mode-1 full height and ALL mode-0 heights are flat (row-linear)")
    # The budget must actually de-rate for a gapped shape, and not for a
    # flat one - the whole point of threading the shape through.
    expect(abs(enc.usable_budget_t(25.0, 320, 256) - 800000.0) < 1.0,
           "flat 320x256 keeps the flat 800000.0 T budget")
    expect(abs(enc.usable_budget_t(25.0, 256, 144) - 800000.0) < 1.0,
           "flat 256x144 keeps the flat 800000.0 T budget")
    gb = enc.usable_budget_t(25.0, 320, 192)
    # Independent literal, not re-derived from the 1.46 constant above -
    # a coefficient/factor typo that moved both numbers together would
    # otherwise still pass this assertion. 1120000*0.85/1.46 = 652054.8
    expect(abs(gb - 652054.8) < 1.0,
           f"gapped 320x192 budget should be 652054.8 T, got {gb:.0f}")
    # Fail-safe default (nxv2enc.composition_factor): an unset/unknown
    # shape must resolve to the pessimistic gapped factor, not the
    # optimistic flat one.
    expect(abs(enc.usable_budget_t(25.0) - 652054.8) < 1.0,
           f"unknown-shape budget should fail safe to the gapped 652054.8 T, got {enc.usable_budget_t(25.0):.0f}")
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
    # K* derives from the coefficients (self-retunes). A bridge saves a
    # SKIP8 + a COPY dispatch, and the bytes it costs are priced at the
    # SUPPLY EXCHANGE RATE - the opportunity cost of a wire byte - NOT
    # at any kernel's execution rate: (141.8+303.7)/19.9 = 22.4 B
    # (24.0 before the 2026-09-15 dispatch re-fit).
    ks = enc.merge_kstar()
    expect(21.9 < ks < 22.9, f"silicon K* should be ~22.4 B, got {ks:.1f}")
    expect(abs(ks - (141.8 + 303.7) / enc.SUPPLY_EXCHANGE_T_PER_BYTE) < 1e-9,
           "K* is the dispatch saving over the supply exchange rate")
    saved = dict(enc.TMODEL_COEFFS)
    try:
        enc.TMODEL_COEFFS["t_op_copy"] = 150.0
        ks2 = enc.merge_kstar()
        expect(ks2 < ks, f"K* must fall when dispatch falls: {ks2:.1f} !< {ks:.1f}")
        expect(abs(ks2 - (141.8 + 150) / enc.SUPPLY_EXCHANGE_T_PER_BYTE) < 0.1,
               "K* recomputes from live coeffs")
        # DECOUPLED FROM THE LDI KERNEL (the point of the re-derivation):
        # moving the copy body rate must NOT move a merge threshold.
        enc.TMODEL_COEFFS["fetch_long"] = 30.0
        expect(abs(enc.merge_kstar() - ks2) < 1e-9,
               "K* must not move when fetch_long moves - the coupling that "
               "made 23.66 right for the wrong reason is gone")
    finally:
        enc.TMODEL_COEFFS.clear()
        enc.TMODEL_COEFFS.update(saved)
    # shape-awareness comes free with the lam argument: a gapped shape
    # exchanges at 15.3-16.5 T/B, which RAISES K* there
    expect(enc.merge_kstar(16.0) > ks,
           "a gapped-shape lam must raise K*, not lower it")


@case(10, "silicon bench rows - the model prices every measured row inside its band")
def t10_bench_rows():
    # Band, not equality: a row reads to +-2 raster lines, at most 1.27 T/op
    # here. Over-pricing is the safe direction: up to max(3 T, 5%). Under-
    # pricing makes frames the player cannot decode in time: an ABSOLUTE
    # 5.5 T, since the least-squares fits leave rows up to 4.40 T under
    # (F070) - not a percentage, which would grow with the row.
    OVER, FLOOR, UNDER_T = 0.05, 3.0, 5.5
    bad = []
    for tag, (measured, modeled) in sorted(bench.priced(enc).items()):
        d = modeled - measured
        if not -UNDER_T <= d <= max(FLOOR, OVER * measured):
            bad.append(f"{tag}: model {modeled:.1f} vs silicon {measured:.1f} "
                       f"({d:+.1f} T, {100 * d / measured:+.2f}%)")
    expect(not bad, "rows outside the band:\n  " + "\n  ".join(bad))


def _nxbx_screen(line_ldi, line_dma, shift=None, zero_tag=None, residue_tag=None):
    """An NXBX screen from two exact T(L) lines, rounded to whole raster
    lines as the bench reads them; odd rows take the wrap early (negative
    D). shift = {tag: T/op offset}. -> (text, {tag: (o, r, f, d)})."""
    text, want = [], {}
    for i, (tag, _kind, L, o, r, _thr, _geo) in enumerate(bench.BENCH_TABLES[5]):
        path = bench.row_path(tag)
        a, b = line_ldi if path == "ldi" else line_dma
        t = a + b * L + (shift or {}).get(tag, 0.0)
        f, d = divmod(round(t * r * o / bench.T_PER_LINE), bench.LINES_PER_FRAME)
        if i % 2:
            f, d = f + 1, d - bench.LINES_PER_FRAME
        want[tag] = (o, r, f, d)
        dfield = f"{d & 0xFFFF:04X}" + ("7" if tag == residue_tag else "")
        oname = "0" if tag == zero_tag else "O"
        text.append(f"{tag} {oname}={o:02X} R={r:04X} F={f:04X} D={dfield}")
    return "\n".join(text) + "\n", want


@case(10, "bench tables - pricing anchors and the standalone table rules")
def t10_bench_tables():
    import math
    tc = enc.TMODEL_COEFFS
    ship = tc["copy_dma_min"]
    tc["copy_dma_min"] = 81
    try:
        c080 = bench.PRICERS["C080"](enc)
        c081 = bench.PRICERS["C081"](enc)
    finally:
        tc["copy_dma_min"] = ship
    expect(abs(bench.row_predicted(enc, "L080") - c080) < 1e-9, "L080 must price as C080 at 81")
    expect(abs(bench.row_predicted(enc, "D081") - c081) < 1e-9, "D081 must price as C081 at 81")
    expect(bench.row_predicted(enc, "D060") < bench.row_predicted(enc, "L060"),
           "a forced DMA row must price cheaper than the same L on LDI")
    # A RUN row's thr routes to run_dma_min: RUN8 of 80 at thr 241 is the CPU
    # fill, and both select coefficients come back unchanged.
    run_ship = tc["run_dma_min"]
    tc["run_dma_min"] = 241
    try:
        cpu80 = enc._cost_run_chunk(80)[1]
    finally:
        tc["run_dma_min"] = run_ship
    got = bench.row_price(enc, ("X080", "run8", 80, 1, 1, 241, 0))
    expect(abs(got - cpu80) < 1e-9
           and abs(cpu80 - (tc["t_op_run"] + 2 * tc["header_rate"] + 80 * tc["fill_cpu"])) < 1e-9,
           f"RUN8 80 at thr 241 must price on the CPU fill ({got:.1f} vs {cpu80:.1f})")
    expect(tc["run_dma_min"] == run_ship and tc["copy_dma_min"] == ship,
           "row_price must restore run_dma_min and copy_dma_min")
    expect(abs(bench.row_price(enc, ("X080", "run8", 80, 1, 1, 0, 0)) - cpu80) > 1.0,
           "the same row at thr 0 must price at the shipping run_dma_min (DMA at 80)")
    # Table rules (src/video.asm NXB_PAGE tables, nxb_build's stream layout).
    # Stream bytes per op: opcode + 8/16-bit count, then a RUN colour byte or
    # the COPY literal body. The source cursor must stay below $DF00.
    header = {"skip8": 2, "run8": 2, "copy8": 2, "skip16": 3, "run16": 3, "copy16": 3}
    expect(sorted(bench.BENCH_TABLES) == list(range(2, 13)), "standalone modes are 2-12")
    bad, owner = [], {}
    for mode, rows in sorted(bench.BENCH_TABLES.items()):
        printed = bench.printed_tags(mode)
        if len(printed) > 20:
            bad.append(f"mode {mode}: {len(printed)} printed rows, the screen holds 20")
        for tag in printed:
            if len(tag) != 4 or not all(0x21 <= ord(ch) <= 0x7E for ch in tag):
                bad.append(f"{tag!r}: a tag is exactly 4 printable characters")
            if tag in owner:
                bad.append(f"{tag}: repeated (modes {owner[tag]} and {mode})")
            owner.setdefault(tag, mode)
        for i, (tag, kind, L, o, r, thr, geo) in enumerate(rows):
            if kind == bench.CAL_KIND:
                # NXB_OPC_CAL: only R is read; the CAL rows open NXBE.
                if ((mode, i, tag, L, o, thr, geo) != (9, 0, "CALL", 0, 0, 0, 0)
                        or not 1 <= r <= 0xFFFF):
                    bad.append(f"{tag}: a CAL row is NXBE's first row, CALL, with only R set")
                continue
            if kind not in header:
                bad.append(f"{tag}: unknown kind {kind!r}")
                continue
            if tag in bench.PRINTED:
                bad.append(f"{tag}: only the CAL row prints extra tags")
            if not (1 <= o <= 255 and 1 <= r <= 0xFFFF and 0 <= thr <= 255
                    and 0 <= L <= (255 if kind.endswith("8") else 0xFFFF)):
                bad.append(f"{tag}: O={o} R={r} thr={thr} L={L} do not fit their fields")
            if kind.startswith("run") and thr > 241:
                bad.append(f"{tag}: RUN thr {thr} > 241 (vid_fill_cpu takes at most 240 B)")
            if kind.startswith("skip") and thr:
                bad.append(f"{tag}: SKIP rows carry thr 0 (nxb_sel_row ignores it)")
            price = bench.row_price(enc, (tag, kind, L, o, r, thr, geo))
            if not (math.isfinite(price) and price > 0):
                bad.append(f"{tag}: row_price {price!r} is not a positive T/op")
            body = L if kind.startswith("copy") else 1 if kind.startswith("run") else 0
            if o * (header[kind] + body) >= 7900:
                bad.append(f"{tag}: stream {o * (header[kind] + body)} B, must be < 7900")
            gapped, hcode, dcode = bench.geo_fields(geo)
            if (geo & bench.GEO_RESERVED or hcode == 3 or (gapped and dcode == 3)
                    or (not gapped and hcode)):
                bad.append(f"{tag}: invalid geometry code ${geo:02X}")
                continue
            if gapped:
                limit = 31 * bench.GEO_HEIGHTS[hcode]
            elif dcode == 0:
                limit = 7936                      # no op starts in the last 256 B
            else:                                 # the window plus one seam page
                limit = 0x4000 - (bench.GEO_DESTS[dcode] - 0x4000)
            if o * L > limit:
                bad.append(f"{tag}: ops*count {o * L} > {limit} (geometry ${geo:02X})")
    expect(not bad, "bench table rules:\n  " + "\n  ".join(bad))


def _synth_frame(frame, preset, sites):
    """None when a SYNTH row's frame is fully written: every op byte read from
    the frame offset (opcodes, counts, fill values) is a written site byte, the
    literal and palette bodies are skipped, KSTART/KFLIP match the span state,
    and the walk ends on a terminal. A row with no writes must sit on the
    header's reserved zero bytes, read as one FEND. Else the reason."""
    written = {}
    for offset, data in sites:
        for i, b in enumerate(data):
            written[offset + i] = b
    if not written:
        if enc.HDR_RESERVED_START <= frame < enc.HEADER_SIZE:
            return None
        return f"no writes, and offset {frame} is not a reserved header zero"
    width = {enc.OP_SKIP8: 1, enc.OP_SKIP16: 2, enc.OP_RUN8: 1, enc.OP_RUN16: 2,
             enc.OP_COPY8: 1, enc.OP_COPY16: 2}
    in_span, pos = preset != 0, frame
    for _ in range(64):
        if pos not in written:
            return f"op byte at {pos} is not a written site byte"
        op = written[pos]
        if op == enc.OP_KSTART:
            if in_span:
                return f"KSTART at {pos} inside a span"
            in_span, pos = True, pos + 1
        elif op in (enc.OP_FEND, enc.OP_KFLIP):
            if op == enc.OP_KFLIP and not in_span:
                return f"KFLIP at {pos} outside a span"
            return None
        elif op == enc.OP_PAL:
            pos += 1 + enc.PAL_BLOCK_SIZE
        elif op in width:
            w = width[op]
            fields = range(pos + 1, pos + 1 + w + (1 if op in (enc.OP_RUN8, enc.OP_RUN16) else 0))
            if any(f not in written for f in fields):
                return f"operand of op ${op:02X} at {pos} is not written"
            n = int.from_bytes(bytes(written[f] for f in range(pos + 1, pos + 1 + w)), "little")
            pos = fields[-1] + 1 + (n if op in (enc.OP_COPY8, enc.OP_COPY16) else 0)
        else:
            return f"opcode ${op:02X} at {pos}"
    return "no terminal within 64 ops"


@case(10, "session bench tables - layout by kind, tags, printed rows, armed rows, deliveries")
def t10_session_tables():
    # Session rows (src/video.asm nxbSes* tables, nxb_srow_next/nxb_srow_go):
    # 10 bytes, or 25 for a SYNTH kind, plus a terminator, staged into
    # nxbTabBuf (560 B); 32 printed rows at most (rows 8-23, two columns).
    expect(sorted(bench.SESSION_TABLES) == sorted(bench.SESSION_MODES)
           == sorted(bench.SESSION_DELIVERY),
           "every session table has a flags+248 mode and its deliveries")
    expect(len(set(bench.SESSION_MODES.values())) == len(bench.SESSION_MODES)
           and all(1 <= m <= 4 for m in bench.SESSION_MODES.values()),
           "session modes are distinct, 1-4")
    bad = []
    for name, rows in sorted(bench.SESSION_TABLES.items()):
        deliveries = bench.SESSION_DELIVERY[name]
        if not deliveries or not set(deliveries) <= {"resident", "streaming", "direct"}:
            bad.append(f"{name}: deliveries {deliveries!r}")
        direct = "direct" in deliveries
        if direct and len(deliveries) != 1:
            bad.append(f"{name}: a direct table runs on no other delivery")
        tags = [r[0] for r in rows]
        for tag in tags:
            if len(tag) != 4 or not all(0x21 <= ord(ch) <= 0x7E for ch in tag):
                bad.append(f"{name} {tag!r}: a tag is exactly 4 printable characters")
        for tag in sorted({t for t in tags if tags.count(t) > 1}):
            bad.append(f"{name} {tag}: repeated in the table")
        if not rows or rows[0][:2] != ("IDEN", "id"):
            bad.append(f"{name}: the first row is IDEN (kind id)")
        tail = [bench.session_strm(r) for r in rows if r[1] in bench.SESSION_KINDS]
        if True in tail and not all(tail[tail.index(True):]):
            bad.append(f"{name}: streaming-only rows must form the table's tail")
        scanned = blocks_direct = False
        shape_ok = True
        for row in rows:
            tag, kind = row[0], row[1]
            if kind not in bench.SESSION_KINDS:
                bad.append(f"{name} {tag}: unknown kind {kind!r}")
                shape_ok = False
                continue
            if kind in bench.SESSION_DIRECT and not direct:
                bad.append(f"{name} {tag}: {kind} rows run only in a direct table")
            if direct and kind not in bench.SESSION_DIRECT + ("id", "arm", "disarm"):
                bad.append(f"{name} {tag}: a direct table has no ring, so no {kind} rows")
            if kind in bench.SESSION_SYNTH:
                if len(row) != 7:
                    bad.append(f"{name} {tag}: a SYNTH row is (tag, kind, reps, frame, preset, site1, site2)")
                    shape_ok = False
                    continue
                _t, _k, reps, frame, preset, *sites = row
                if not 1 <= reps <= 0xFFFF:
                    bad.append(f"{name} {tag}: reps {reps} must be 1-65535")
                    shape_ok &= 0 <= reps <= 0xFFFF
                if not 0 <= frame < 1 << 24:
                    bad.append(f"{name} {tag}: frame offset {frame} does not fit 24 bits")
                    shape_ok = False
                if preset not in (0, 1, 2):
                    bad.append(f"{name} {tag}: span preset {preset} must be 0-2")
                    shape_ok &= 0 <= preset <= 255
                if "streaming" in deliveries and frame % 512:
                    bad.append(f"{name} {tag}: a streaming frame offset is a 512 multiple, got {frame}")
                spans = []
                for offset, data in sites:
                    if not (0 <= offset < 1 << 24 and len(data) <= 3
                            and all(0 <= b <= 255 for b in data)):
                        bad.append(f"{name} {tag}: site ({offset}, {data}) does not fit")
                        shape_ok = False
                        continue
                    if (offset & 0x1FFF) + len(data) > 0x2000:
                        bad.append(f"{name} {tag}: site at {offset} straddles an 8K page")
                    if data:
                        spans.append((offset, offset + len(data)))
                if len(spans) == 2 and spans[0][0] < spans[1][1] and spans[1][0] < spans[0][1]:
                    bad.append(f"{name} {tag}: the two sites overlap")
                if kind == "synth_nocall" and (spans or preset):
                    bad.append(f"{name} {tag}: SYNTH-NOCALL writes nothing, preset 0")
                if kind == "synth" and shape_ok:
                    why = _synth_frame(frame, preset, sites)
                    if why:
                        bad.append(f"{name} {tag}: {why}")
                continue
            if len(row) != 6:
                bad.append(f"{name} {tag}: a {kind} row is (tag, kind, param, reps, thr, strm)")
                shape_ok = False
                continue
            _t, _k, param, reps, thr, strm = row
            if kind in ("prod", "remn") and not strm:
                bad.append(f"{name} {tag}: {kind.upper()} rows run only in the streaming tail")
            if strm and "streaming" not in deliveries:
                bad.append(f"{name} {tag}: a strm row in a table no streaming session runs")
            if not (0 <= param <= 0xFFFF and 0 <= reps <= 0xFFFF and 0 <= thr <= 255):
                bad.append(f"{name} {tag}: param={param} reps={reps} thr={thr} do not fit")
                shape_ok = False
            if (kind in bench.SESSION_REPS) != (reps >= 1):
                bad.append(f"{name} {tag}: reps {reps} (1+ for FRAME/AUD/PACE/PROD/DSBLK, else 0)")
            if (kind in bench.SESSION_DECODE) != (thr >= 1):
                bad.append(f"{name} {tag}: thr {thr} (1+ for SCAN/SWEEP/FRAME/LOOP/DSWEEP, else 0)")
            if kind == "frame" and (param > 2 or not scanned):
                bad.append(f"{name} {tag}: FRAME takes slot 0-2 after a SCAN row")
            if kind == "loop" and not 1 <= param <= 255:
                bad.append(f"{name} {tag}: LOOP n {param} must be 1-255")
            if kind == "loop" and not scanned:
                bad.append(f"{name} {tag}: LOOP follows a SCAN row (SCAN's m bounds a streaming n)")
            if kind == "dsweep" and not 1 <= param <= 255:
                bad.append(f"{name} {tag}: DSWEEP frames {param} must be 1-255")
            if kind in ("dsweep", "dskip") and blocks_direct:
                bad.append(f"{name} {tag}: {kind.upper()} after a DSBLK row (the frames are off the wire)")
            if kind == "dsblk" and param > 3:
                bad.append(f"{name} {tag}: DSBLK body {param} must be 0-3")
            if kind not in ("sweep", "frame", "loop", "dsweep", "dsblk") and param:
                bad.append(f"{name} {tag}: {kind} rows carry param 0")
            scanned |= kind == "scan"
            blocks_direct |= kind == "dsblk"
        if shape_ok:
            lengths = [len(bench.session_row_bytes(r)) for r in rows]
            want = [bench.SESSION_SYNTH_LEN if r[1] in bench.SESSION_SYNTH
                    else bench.SESSION_ROW_LEN for r in rows]
            if lengths != want:
                bad.append(f"{name}: row lengths {lengths}, the kinds want {want}")
            size = len(bench.session_table_bytes(name))
            if size > 560:
                bad.append(f"{name}: {size} B, nxbTabBuf holds 560")
        pairs = bench.SESSION_ARMED_PAIRS.get(name, ())
        armed_tags = {a for _u, a in pairs}
        for delivery in deliveries:
            view = delivery
            printed = bench.session_printed(name, delivery)
            if len(printed) > 32:
                bad.append(f"{name} {view}: {len(printed)} printed rows, the screen holds 32")
            state = bench.session_armed(name, delivery)
            armed = False
            for tag, kind, *_ in bench.session_rows(name, delivery):
                if kind == "arm" and armed:
                    bad.append(f"{name} {view} {tag}: ARM while armed")
                if kind == "disarm" and not armed:
                    bad.append(f"{name} {view} {tag}: DISARM while unarmed")
                armed = kind == "arm" or (armed and kind != "disarm")
            for tag in printed:
                if state[tag] != (tag in armed_tags):
                    bad.append(f"{name} {view} {tag}: runs {'armed' if state[tag] else 'unarmed'}"
                               f", the pairs say {'armed' if tag in armed_tags else 'unarmed'}")
        by_tag = {r[0]: r for r in rows}
        for u, a in pairs:
            if u not in by_tag or a not in by_tag:
                bad.append(f"{name}: pair {u}/{a} names a missing row")
            elif by_tag[u][1:] != by_tag[a][1:]:
                bad.append(f"{name}: pair {u}/{a} rows differ beyond the tag")
    expect(not bad, "session table rules:\n  " + "\n  ".join(bad))


@case(10, "direct fixtures - DS1's swept frames share one section size, the file holds DS1")
def t10_direct_payloads():
    import re as _re
    ps1 = (ROOT / "tests" / "build-tests.ps1").read_text(encoding="utf-8")
    m = _re.search(r"\$vidLegSettlementTag = '([^']+)'", ps1)
    expect(m, "build-tests.ps1 must carry $vidLegSettlementTag")
    read, swept, dt_blocks = bench.direct_frames("DS1")
    checked = 0
    for num in ("010", "011", "012", "013", "014"):
        found = sorted((ROOT / "tests" / "out").glob(f"{num}_*_{m.group(1)}_long_cache.vid"))
        if not found:
            print(f"    note: {num}.VID not encoded at era {m.group(1)}, not checked")
            continue
        path = found[0]
        buf = path.read_bytes()
        hdr = enc.unpack_header(buf)
        expect(hdr["flags"] & enc.FLAG_DIRECT_SERVE, f"{path.name}: not a direct-serve clip")
        issues = []
        frames = list(dec._iter_frames(buf, hdr, issues=issues))
        expect(not issues, f"{path.name}: {issues[:1]}")
        expect(len(frames) >= read, f"{path.name}: {len(frames)} frames, DS1 reads {read}")
        blocks = [-(-length // 512) for *_x, _start, length in frames]
        timed = [i for r in swept for i in r]
        sizes = sorted({blocks[i] for i in timed})
        expect(len(sizes) == 1, f"{path.name}: swept frames {timed[0]}-{timed[-1]} "
                                f"have section sizes {sizes} (blocks)")
        apad = -(-hdr["audio_bytes_per_frame"] // 512)
        need = 1 + sum(apad + blocks[i] for i in range(read)) + dt_blocks
        have = len(buf) // 512
        expect(need <= have, f"{path.name}: DS1 reads {need} blocks, the file has {have}")
        checked += 1
    if not checked:
        skip(f"no direct fixture encoded at era {m.group(1)} (build-tests.ps1 -Vid -VidLong)")


def _bench_screen(rows):
    """{row: {column: text}} -> 32 tilemap rows, 80 wide."""
    screen = [[" "] * 80 for _ in range(32)]
    for r, cells in rows.items():
        for c, text in cells.items():
            screen[r][c:c + len(text)] = list(text)
    return ["".join(line) for line in screen]


def _bench_capture(stamp, screen):
    """The log step's bytes for one screen (nxb_log): the header, then each
    non-empty row with trailing spaces trimmed, CRLF line ends."""
    out = f"#NXB {stamp:04X}\r\n"
    return out + "".join(line.rstrip(" ") + "\r\n" for line in screen if line.strip(" "))


def _bench_group(tag, o, r, f, d):
    return f"{tag} O={o:02X} R={r:04X} F={f:04X} D={d & 0xFFFF:04X}"


@case(10, "bench log - NXBENCH.TXT and typed screens parse to runs, tables, reports, LOG")
def t10_bench_log():
    import re as _re
    import nxv2_bench_log as blog
    # The verb map and the log step in tests/test.dsf: every bench verb ends with
    # LET 250 15 / EXTERN 0 12 before any PROCESS 10.
    dsf = (ROOT / "tests" / "test.dsf").read_text(encoding="utf-8")
    seen = {}
    for m in _re.finditer(r"^> (NXB\w)\s+_\s+(.*?)^\s*DONE", dsf, _re.M | _re.S):
        body = [" ".join(x.split(";")[0].split()) for x in m.group(2).splitlines()]
        body = [x for x in body if x]
        first = _re.match(r"LET (250|248) (\d+)$", body[0])
        expect(first, f"{m.group(1)}: opens with {body[0]!r}")
        seen[m.group(1)] = (int(first.group(1)), int(first.group(2)))
        cut = body.index("PROCESS 10") if "PROCESS 10" in body else len(body)
        expect(body[cut - 2:cut] == ["LET 250 15", "EXTERN 0 12"],
               f"{m.group(1)}: the log step must end the rows, before PROCESS 10: {body}")
    want = {v: (250, mode) for v, mode in blog.STANDALONE_VERBS.items()}
    want.update({v: (248, bench.SESSION_MODES[name]) for v, name in blog.SESSION_VERBS.items()})
    expect(seen == want, f"test.dsf bench verbs {seen}, the parser maps {want}")
    asm = (ROOT / "src" / "video.asm").read_text(encoding="utf-8")
    expect(_re.search(r"^NXB_MODE_LOG\s+equ 15\b", asm, _re.M)
           and _re.search(rf"^NXB_SESS_COL2\s+equ {blog.COL2}\b", asm, _re.M),
           "video.asm NXB_MODE_LOG 15 and NXB_SESS_COL2 must match the parser")
    steps = _re.findall(r"^NXB_LOG_(?!WMODE)\w+\s+equ \$([0-9A-F]{2})\s", asm, _re.M)
    expect(sorted(int(s, 16) for s in steps) == [k << 5 for k in sorted(blog.LOG_STEPS)],
           f"LOG step codes {steps} against LOG_STEPS")

    def vals(tags, seed):
        return [(t, (seed + 3 * i) & 0xFF, 0x40 + i, 0x10 + i, (-150 + 97 * i) if i % 2 else 200 + i)
                for i, t in enumerate(tags)]

    # 1. standalone NXBC, first run after a launch (no LOG line yet)
    c_rows = vals(bench.printed_tags(3), 0xF0)
    s1 = _bench_screen({0: {0: "> nxbc"}, **{8 + i: {0: _bench_group(*g)} for i, g in enumerate(c_rows)}})
    # 2. session NXBR on PICK 7, two columns, the teardown report with ERR=00
    r_rows = vals(bench.session_printed("REAL", "resident"), 0x10)
    screen2 = {0: {0: "> nxbc"}, 1: {0: "> pick 7"}, 2: {0: "Clip 7 armed."}, 3: {0: "> nxbr"},
               24: {0: " FRM=00FA/00FA ERR=00 OP=00 POS=000000 PASS=01"},
               25: {0: "RING   =0000/0000/00 FILL=0000 SNAP=00"},
               26: {0: "PLAY   =0131 NOM=0131 CHK=1234ABCD"}, 31: {0: "LOG OK"}}
    for i, g in enumerate(r_rows):
        screen2.setdefault(8 + i % 16, {})[40 if i >= 16 else 0] = _bench_group(*g)
    s2 = _bench_screen(screen2)
    # 3. standalone NXBK with stale NXBX rows below its own (a longer previous verb)
    k_rows = vals(bench.printed_tags(4), 0x7D)
    x_rows = vals(bench.printed_tags(5), 0x9D)
    screen3 = {2: {0: "> nxbx"}, 3: {0: "> nxbk"}, 31: {0: "LOG ERR 60"}}
    for i, g in enumerate(x_rows):
        screen3[8 + i] = {0: _bench_group(*g)}
    for i, g in enumerate(k_rows):
        screen3[8 + i] = {0: _bench_group(*g)}
    s3 = _bench_screen(screen3)
    # 4. session NXBQ that faulted after 5 rows: ERR=FA
    q_rows = vals(bench.session_printed("SYN", "resident")[:5], 0x00)
    screen4 = {7: {0: "> nxbq"}, 24: {0: " FRM=0003/0003 ERR=FA OP=00 POS=00123A PASS=01"},
               31: {0: "LOG OK"}, **{8 + i: {0: _bench_group(*g)} for i, g in enumerate(q_rows)}}
    s4 = _bench_screen(screen4)
    # 5. NXBE: the CALL row prints CALL then CALR
    e_rows = vals(bench.printed_tags(9), 0x03)
    s5 = _bench_screen({0: {0: "> nxbe"}, 31: {0: "LOG OK"},
                        **{8 + i: {0: _bench_group(*g)} for i, g in enumerate(e_rows)}})
    text = "".join(_bench_capture(st, s) for st, s in
                   ((0x0100, s1), (0x0B20, s2), (0x1400, s3), (0x2001, s4), (0x2F00, s5)))
    runs = blog.parse(text)
    expect([r.stamp for r in runs] == [0x0100, 0x0B20, 0x1400, 0x2001, 0x2F00], "stamps")
    expect([r.command for r in runs] == ["NXBC", "NXBR", "NXBK", "NXBQ", "NXBE"], "commands")
    expect([r.table for r in runs] == [3, "REAL", 4, "SYN", 9], "tables")
    expect([r.clip for r in runs] == [None, 7, None, 7, None], "clips: a session verb takes the last PICK")
    for run, want_rows in zip(runs, (c_rows, r_rows, k_rows, q_rows, e_rows)):
        expect(run.rows == want_rows, f"{run.command} rows:\n  {run.rows}\n  {want_rows}")
        expect(not run.warnings, f"{run.command} warnings {run.warnings}")
    expect(runs[1].rows[15][0] == "LOOP" and runs[1].rows[16][0] == "A065",
           "the column-1 rows follow every column-0 row")
    expect(any(d < 0 for *_x, d in runs[1].rows), "a negative D reads two's complement")
    expect(runs[2].dropped == x_rows[len(k_rows):] and not runs[0].dropped,
           f"NXBK must drop exactly the stale NXBX rows, got {runs[2].dropped}")
    expect([r.err for r in runs] == [None, 0x00, None, 0xFA, None], f"ERR= {[r.err for r in runs]}")
    expect(runs[1].report == [" FRM=00FA/00FA ERR=00 OP=00 POS=000000 PASS=01",
                              "RING   =0000/0000/00 FILL=0000 SNAP=00",
                              "PLAY   =0131 NOM=0131 CHK=1234ABCD"], f"report {runs[1].report}")
    expect([r.log for r in runs] == ["OK", "ERR 60", "OK", "OK", None],
           f"each LOG line is the previous run's status, got {[r.log for r in runs]}")
    expect(blog.log_error_step(0x60) == ("write", 0) and blog.log_error_step(0xA5)[1] == 5,
           "LOG ERR step decode")
    expect(blog.parse(text.replace("\r\n", "\n"))[1].rows == r_rows, "LF-only text parses the same")
    # A short write leaves a partial line with no CRLF: the next header follows it.
    cut = _bench_capture(0x0100, s1)
    cut = cut[:cut.index("C008") + 10]
    pruns = blog.parse(cut + _bench_capture(0x0B20, s2))
    expect([r.command for r in pruns] == ["NXBC", "NXBR"] and pruns[0].rows == c_rows[:2]
           and pruns[1].rows == r_rows and pruns[0].log == "OK" and pruns[0].warnings,
           "a header glued to a partial line still opens the next run")
    # A capture with no bench verb attributes no rows.
    lost = blog.parse(_bench_capture(1, _bench_screen({8: {0: _bench_group(*k_rows[0])}})))[0]
    expect(lost.command is None and not lost.rows and lost.dropped == [k_rows[0]] and lost.warnings,
           "a capture with no verb keeps nothing")
    # Typed fallback: verb lines split runs, PICK joins the next verb, 0= reads as
    # O=, two groups per line with any spacing, LOG belongs to its own run.
    typed = ["NXBK"] + [_bench_group(*g).replace(" O=", " 0=") for g in k_rows]
    typed += ["", "PICK 7", "NXBR"]
    for i in range(16):
        right = f"   {_bench_group(*r_rows[16 + i])}" if 16 + i < len(r_rows) else ""
        typed.append(_bench_group(*r_rows[i]) + right)
    typed += [" FRM=00FA/00FA ERR=00 OP=00 POS=000000 PASS=01", "LOG ERR C0"]
    truns = blog.parse("\n".join(typed) + "\n")
    expect([(r.command, r.clip, r.stamp) for r in truns] == [("NXBK", None, None), ("NXBR", 7, None)],
           f"typed runs {[(r.command, r.clip) for r in truns]}")
    expect(truns[0].rows == k_rows and truns[1].rows == r_rows, "typed rows")
    expect([r.log for r in truns] == [None, "ERR C0"] and truns[1].err == 0, "typed LOG and ERR=")
    bad = blog.parse("NXBK\nF063 0=7D R=0040 F=0013 D=003D7\nF070 O=70 R=0040 F=0013\n")[0]
    expect(bad.rows == [("F063", 0x7D, 0x40, 0x13, 0x3D)] and len(bad.warnings) == 2,
           f"a 5-digit D keeps 4 and warns, a short row warns: {bad.rows} {bad.warnings}")
    # Stale screens and lost captures. A: NXBR on PICK 7. B: PICK 12, NXBR fails
    # to open (VID FILE? on row 23 over A's stale rows). C: NXBR on the carried
    # clip 12 (no PICK on screen), row 31 LOG ERR 28 (a capture lost before it).
    # D: NXBR whose rows equal C's, row 31 LOG ERR 60 (step 3 wrote: C's).
    screen_b = dict(screen2)
    screen_b.update({0: {0: "> pick 12"}, 1: {0: "> nxbr"}, 2: {}, 3: {}, 31: {0: "LOG OK"}})
    s_b = _bench_screen(screen_b)
    s_b[23] = "VID FILE?" + s_b[23][9:]
    c_rows2 = vals(bench.session_printed("REAL", "resident"), 0x55)
    screen_c = {0: {0: "> nxbr"}, 31: {0: "LOG ERR 28"}}
    for i, g in enumerate(c_rows2):
        screen_c.setdefault(8 + i % 16, {})[40 if i >= 16 else 0] = _bench_group(*g)
    screen_d = dict(screen_c)
    screen_d[31] = {0: "LOG ERR 60"}
    s_a = list(s2)
    s_a[31] = " " * 80
    log2 = "".join(_bench_capture(st, s) for st, s in
                   ((0x0100, s_a), (0x0200, s_b), (0x0300, _bench_screen(screen_c)),
                    (0x0400, _bench_screen(screen_d))))
    sruns = blog.parse(log2)
    expect([r.clip for r in sruns] == [7, 12, 12, 12], f"carried clips {[r.clip for r in sruns]}")
    expect(sruns[1].rows == r_rows[:15] + r_rows[16:]
           and any("VID FILE?" in w for w in sruns[1].warnings) and len(sruns[1].warnings) == 1,
           f"VID FILE? over stale rows warns: {sruns[1].warnings}")
    expect(not sruns[0].warnings and not any("stale" in w for w in sruns[2].warnings),
           "a fresh run does not warn")
    expect([w for w in sruns[2].warnings] == ["LOG ERR 28: a capture was lost between #NXB 0200 and #NXB 0300"],
           f"lost capture: {sruns[2].warnings}")
    expect(any("rows equal the previous NXBR run's (#NXB 0300)" in w for w in sruns[3].warnings),
           f"identical rows warn: {sruns[3].warnings}")
    expect([r.log for r in sruns] == ["OK", None, "ERR 60", None], f"logs {[r.log for r in sruns]}")
    one = blog.parse(_bench_capture(0x0500, _bench_screen({0: {0: "> nxbc"}, 31: {0: "LOG ERR 46"}})))[0]
    expect(one.warnings == ["LOG ERR 46: a capture was lost before #NXB 0500"],
           f"a lost capture before the first stamp: {one.warnings}")
    fmt = blog.parse(_bench_capture(0x0600, _bench_screen({0: {0: "> nxbq"}, 23: {0: "VID NOBANK2"}})))[0]
    expect(fmt.report == ["VID NOBANK2"] and len(fmt.warnings) == 1, f"VID NOBANK2 alone: {fmt.warnings}")
    import io
    with tempfile.TemporaryDirectory() as td:
        for body, want in ((log2, "4 runs, 3 with a problem"), (_bench_capture(0x0100, s_a), "1 runs, 0 with a problem")):
            path = Path(td) / "NXBENCH.TXT"
            path.write_bytes(body.encode("latin-1"))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = blog.main([str(path)])
            expect(want in out.getvalue() and rc == (1 if want[8] != "0" else 0),
                   f"CLI on {want!r}: rc {rc}: {out.getvalue()}")


@case(10, "player-path events - hand-counted bench, synthetic and edge cases")
def t10_path_events():
    import nxv2_path_sim as ps
    FLAT, G72, G144, G192 = (256, 192, False), (320, 72, True), (320, 144, True), (320, 192, True)
    C8, C16, R8, R16, S8, S16 = 0x10, 0x14, 0x08, 0x0C, 0x1C, 0x04
    END = [(0x00, 0)]

    def row(tag):
        return lambda: bench.row_events(tag)

    def syn(tag, surface):
        return lambda: bench.row_events(tag, surface)

    def run(ops, surface, src, **kw):
        return lambda: ps.events(ops, surface, src, **kw)

    def passes(*lens):
        # vid_copy_ldi blocks / vid_fill_cpu passes: ceil(n / 16) per kernel call, none for 0
        return sum(-(-n // 16) for n in lens)

    def col_segs(n, o, h):
        # o ops of n B from E = 0, each split at the h-row column ends inside it
        segs = []
        for i in range(o):
            a, b = i * n, (i + 1) * n
            cuts = [a] + [k * h for k in range(a // h + 1, (b - 1) // h + 1)] + [b]
            segs += [y - x for x, y in zip(cuts, cuts[1:])]
        return segs

    def gap_c8(n, o, hop0):
        # HLnn / HDnn at h144: o ops of n B cross 30 column ends, hop0 of them at op starts
        # (an empty first segment's call counts no block)
        return ({"fast_copy8": o, "fast_hop_copy8": 30, "fast_hop0_copy8": hop0,
                 "copy_fast_b": o * n, "copy_ldi_passes": passes(*col_segs(n, o, 144)), "fend": 1},
                {"thr_copy8": o, "copy_dma_chunks8": o + 30 - hop0, "copy_dma_b": o * n,
                 "col_hops": 30, "fend": 1})

    cases = [
        # --- NXBE, flat $4000, D <= $5E throughout, thr 0 = 81 / 71 ---
        # C240: 32 thr bails x 1 DMA chunk of 240 (7680 B, ends $5E00)
        ("C240", row("C240"), {"thr_copy8": 32, "copy_dma_chunks8": 32, "copy_dma_b": 7680, "fend": 1}),
        # C250: 31 x (240 DMA + 10 B LDI tail), 7750 B ends $5E46; each 250 B first chunk
        # falls through the cap test (B = 0, C = 250 > 240)
        ("C250", row("C250"), {"thr_copy8": 31, "copy_dma_chunks8": 31, "copy_ldi_chunks8": 31,
                               "copy_tail8": 31, "copy_dma_b": 7440, "copy_ldi_b": 310,
                               "copy_ldi_passes": 31, "cap_arm_chunks": 31, "fend": 1}),
        # Q240: 32 COPY16 x 1 DMA chunk of 240
        ("Q240", row("Q240"), {"op_copy16": 32, "copy_dma_chunks16": 32, "copy_dma_b": 7680, "fend": 1}),
        # R240: 33 RUN8 240 >= 71 bail x 1 DMA chunk (7920 B, last op starts $5E00)
        ("R240", row("R240"), {"thr_run8": 33, "run_dma_chunks8": 33, "run_dma_b": 7920, "fend": 1}),
        # R250: 31 x (240 DMA + 10 B CPU tail), the 250 B first chunks through the cap arm
        ("R250", row("R250"), {"thr_run8": 31, "run_dma_chunks8": 31, "run_cpu_chunks8": 31,
                               "run_tail8": 31, "run_dma_b": 7440, "run_cpu_b": 310,
                               "run_cpu_passes": 31, "cap_arm_chunks": 31, "fend": 1}),
        # W240: 33 RUN16 x 1 DMA chunk of 240
        ("W240", row("W240"), {"op_run16": 33, "run_dma_chunks16": 33, "run_dma_b": 7920, "fend": 1}),
        # P071: 111 x 71 >= 71, one DMA chunk each (7881 B)
        ("P071", row("P071"), {"thr_run8": 111, "run_dma_chunks8": 111, "run_dma_b": 7881, "fend": 1}),
        # P200: 39 x 200, one DMA chunk each (7800 B)
        ("P200", row("P200"), {"thr_run8": 39, "run_dma_chunks8": 39, "run_dma_b": 7800, "fend": 1}),
        # --- NXBH, h144 from E = 0: L rows thr 255 fast, D rows thr 1 body ---
        # HL56/HD56: 79x56 = 4424 B, 144k < 4424 for k <= 30, lcm 1008 -> 4 at op starts; D chunks 79 + 26
        ("HL56", row("HL56"), gap_c8(56, 79, 4)[0]), ("HD56", row("HD56"), gap_c8(56, 79, 4)[1]),
        # HL60/HD60: 74x60 = 4440, lcm 720 -> 6 at op starts; D chunks 74 + 24
        ("HL60", row("HL60"), gap_c8(60, 74, 6)[0]), ("HD60", row("HD60"), gap_c8(60, 74, 6)[1]),
        # HL64/HD64: 69x64 = 4416, lcm 576 -> 7; D chunks 69 + 23
        ("HL64", row("HL64"), gap_c8(64, 69, 7)[0]), ("HD64", row("HD64"), gap_c8(64, 69, 7)[1]),
        # HL68/HD68: 65x68 = 4420, lcm 2448 -> 1; D chunks 65 + 29
        ("HL68", row("HL68"), gap_c8(68, 65, 1)[0]), ("HD68", row("HD68"), gap_c8(68, 65, 1)[1]),
        # HL76/HD76: 58x76 = 4408, lcm 2736 -> 1; D chunks 58 + 29
        ("HL76", row("HL76"), gap_c8(76, 58, 1)[0]), ("HD76", row("HD76"), gap_c8(76, 58, 1)[1]),
        # HL80/HD80: 55x80 = 4400, lcm 720 -> 6; D chunks 55 + 24
        ("HL80", row("HL80"), gap_c8(80, 55, 6)[0]), ("HD80", row("HD80"), gap_c8(80, 55, 6)[1]),
        # HL88/HD88: 50x88 = 4400, lcm 1584 -> 2; D chunks 50 + 28
        ("HL88", row("HL88"), gap_c8(88, 50, 2)[0]), ("HD88", row("HD88"), gap_c8(88, 50, 2)[1]),
        # HL96/HD96: 46x96 = 4416, lcm 288 -> 15; D chunks 46 + 15
        ("HL96", row("HL96"), gap_c8(96, 46, 15)[0]), ("HD96", row("HD96"), gap_c8(96, 46, 15)[1]),
        # HC03: 4429 B from E = 103j mod 144: 13 fit (E <= 41) DMA 1339 B; 30 straddle, first halves 144-E >= 81 at E 42-47,62,63 (8 tails) 760 B, second halves E-41 at E 124-129 513 B: DMA 2612, LDI 1817
        # (LDI chunks are the column segments under 81 B)
        ("HC03", row("HC03"), {"thr_copy8": 43, "copy_dma_chunks8": 27, "copy_ldi_chunks8": 46,
                               "copy_tail8": 8, "copy_dma_b": 2612, "copy_ldi_b": 1817,
                               "copy_ldi_passes": passes(*[x for x in col_segs(103, 43, 144) if x < 81]),
                               "col_hops": 30, "fend": 1}),
        # HK56: 4352 B from E = 112j mod 144 (j 9 deferred): E 112/80/96/64 x2 put 112 B LDI in 2 chunks (tail after DMA), E 48 x2 a 16 B tail, E 128 x2 a 16 B lead: LDI 20 chunks 960 B, 10 tails, DMA 26 chunks 3392 B, 30 hops
        ("HK56", row("HK56"), {"op_copy16": 17, "copy_dma_chunks16": 26, "copy_ldi_chunks16": 20,
                               "copy_tail16": 10, "copy_dma_b": 3392, "copy_ldi_b": 960,
                               "copy_ldi_passes": passes(*[x for x in col_segs(256, 17, 144) if x < 81]),
                               "col_hops": 30, "fend": 1}),
        # --- NXBV ---
        # EC16: 15x16 at $5F00, D = $5F every op: 15 edge bails, 15 exact-sized LDI chunks
        ("EC16", row("EC16"), {"edge_copy8": 15, "copy_ldi_chunks8": 15, "copy_ldi_b": 240,
                               "copy_ldi_passes": 15, "dst_exact_chunks": 15, "fend": 1}),
        # NC16: 15 fast at $4000
        ("NC16", row("NC16"), {"fast_copy8": 15, "copy_fast_b": 240, "copy_ldi_passes": 15, "fend": 1}),
        # ER16: 15 edge bails, 15 exact CPU chunks of 16
        ("ER16", row("ER16"), {"edge_run8": 15, "run_cpu_chunks8": 15, "run_cpu_b": 240,
                               "run_cpu_passes": 15, "dst_exact_chunks": 15, "fend": 1}),
        # NR16: 15 fast fills
        ("NR16", row("NR16"), {"fast_run8": 15, "run_fast_b": 240, "run_cpu_passes": 15, "fend": 1}),
        # ES16: 15 edge bails, 1 pass each
        ("ES16", row("ES16"), {"edge_skip8": 15, "skip_passes": 15, "fend": 1}),
        # NS16: 15 fast skips
        ("NS16", row("NS16"), {"fast_skip8": 15, "fend": 1}),
        # S256: 31 SKIP16 x 1 pass (room >= 256 up to $5E00)
        ("S256", row("S256"), {"op_skip16": 31, "skip_passes": 31, "fend": 1}),
        # S2D0: one op, one pass
        ("S2D0", row("S2D0"), {"op_skip16": 1, "skip_passes": 1, "fend": 1}),
        # SDS1: $5F80 room 128 pass, seam at $6000, 128 B pass
        ("SDS1", row("SDS1"), {"op_skip16": 1, "skip_passes": 2, "dst_seams": 1, "fend": 1}),
        # JC72: 3x720 at h72 thr 81: 10 LDI column chunks per op (5 blocks each), hops 9 + (1 + 9) x 2
        ("JC72", row("JC72"), {"op_copy16": 3, "copy_ldi_chunks16": 30, "copy_ldi_b": 2160,
                               "copy_ldi_passes": 150, "col_hops": 29, "fend": 1}),
        # JD72: as JC72 at thr 59: 72 >= 59, 30 DMA
        ("JD72", row("JD72"), {"op_copy16": 3, "copy_dma_chunks16": 30, "copy_dma_b": 2160,
                               "col_hops": 29, "fend": 1}),
        # JR72: 30 fill chunks of 72 >= 71 DMA, 29 hops
        ("JR72", row("JR72"), {"op_run16": 3, "run_dma_chunks16": 30, "run_dma_b": 2160,
                               "col_hops": 29, "fend": 1}),
        # JS72: 10 passes per op, 29 hops
        ("JS72", row("JS72"), {"op_skip16": 3, "gap_skip_passes": 30, "col_hops": 29, "fend": 1}),
        # JK72: 11x200 > 2x72 all bail; 2200 B cross 30 ends, 1800 at an op start: passes 11 + 29
        ("JK72", row("JK72"), {"gap_skip8": 11, "gap_skip_passes": 40, "col_hops": 30, "fend": 1}),
        # JN72: 37x60, E + 60 - 72 < 72 always: all fast, 30 ends crossed inline
        ("JN72", row("JN72"), {"fast_skip8": 37, "fast_hop_skip8": 30, "fend": 1}),
        # GS3C: 10x576 at h192: 3 passes per op, hops 2 + 9x3
        ("GS3C", row("GS3C"), {"op_skip16": 10, "gap_skip_passes": 30, "col_hops": 29, "fend": 1}),
        # --- NXBL seam rows and twins ---
        # LF1K: 7x1000 flat: 4 DMA + 40 B LDI tail each, ends $5B58
        ("LF1K", row("LF1K"), {"op_copy16": 7, "copy_dma_chunks16": 28, "copy_ldi_chunks16": 7,
                               "copy_tail16": 7, "copy_dma_b": 6720, "copy_ldi_b": 280,
                               "copy_ldi_passes": 21, "fend": 1}),
        # LF7K: 7680 = 32x240 DMA
        ("LF7K", row("LF7K"), {"op_copy16": 1, "copy_dma_chunks16": 32, "copy_dma_b": 7680, "fend": 1}),
        # LFDS: $5000: 16 DMA to $5F00, exact 240, exact 16 B LDI tail, seam, 3584 = 14x240 + 224 DMA
        ("LFDS", row("LFDS"), {"op_copy16": 1, "copy_dma_chunks16": 32, "copy_ldi_chunks16": 1,
                               "copy_tail16": 1, "copy_dma_b": 7664, "copy_ldi_b": 16, "copy_ldi_passes": 1,
                               "dst_exact_chunks": 2, "dst_seams": 1, "fend": 1}),
        # LG1K: 5x1000 h192, E0 = 0/40/80/120/160: 31 chunks, 26 DMA, LDI 40,80,72,32,8 (3 tails), 26 hops
        ("LG1K", row("LG1K"), {"op_copy16": 5, "copy_dma_chunks16": 26, "copy_ldi_chunks16": 5,
                               "copy_tail16": 3, "copy_dma_b": 4768, "copy_ldi_b": 232,
                               "copy_ldi_passes": passes(40, 80, 72, 32, 8), "col_hops": 26, "fend": 1}),
        # LG4K: 4000 = 20x192 + 160, all DMA, 20 hops
        ("LG4K", row("LG4K"), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_dma_b": 4000,
                               "col_hops": 20, "fend": 1}),
        # LGDS: as LG4K from column $50: the hop $5F -> $60 takes one seam
        ("LGDS", row("LGDS"), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_dma_b": 4000,
                               "col_hops": 20, "dst_seams": 1, "fend": 1}),
        # --- gapped COPY16 over k columns ---
        # h192: 2x576 = 3 columns each, 6 DMA, hops 2 + 1 + 2
        ("G192", run([(C16, 576)] * 2 + END, G192, 0, copy_thr=81),
         {"op_copy16": 2, "copy_dma_chunks16": 6, "copy_dma_b": 1152, "col_hops": 5, "fend": 1}),
        # h192 from E = 100: 92 DMA, 192, 192, 24 B LDI tail, 3 hops
        ("G192E", run([(C16, 500)] + END, G192, 0, dst=(0, 0x4064), copy_thr=81),
         {"op_copy16": 1, "copy_dma_chunks16": 3, "copy_ldi_chunks16": 1, "copy_tail16": 1,
          "copy_dma_b": 476, "copy_ldi_b": 24, "copy_ldi_passes": 2, "col_hops": 3, "fend": 1}),
        # --- SYN rows, flat 256x192 at 81/71 ---
        ("NUL0", syn("NUL0", FLAT), {}),
        # FE00: one plain FEND; FE01 the span FEND
        ("FE00", syn("FE00", FLAT), {"fend": 1}),
        ("FE01", syn("FE01", FLAT), {"fend_span": 1}),
        # KS01: KSTART, KFLIP; KS02: KSTART, span FEND; KF01: KFLIP in a span
        ("KS01", syn("KS01", FLAT), {"kstart": 1, "kflip": 1}),
        ("KS02", syn("KS02", FLAT), {"kstart": 1, "fend_span": 1}),
        ("KF01", syn("KF01", FLAT), {"kflip": 1}),
        # PAL1: PAL at $C018, H <= $DD
        ("PAL1", syn("PAL1", FLAT), {"pal_ops": 1, "fend": 1}),
        # PAL2: PAL at $DEDC: H = $DE straddle, 291 B, parity seam, 221 B
        ("PAL2", syn("PAL2", FLAT), {"pal_straddles": 1, "pal_chunks": 2, "src_parity_seams": 1, "fend": 1}),
        # SE00: COPY8 1 at $DB58, all fast
        ("SE00", syn("SE00", FLAT), {"fast_copy8": 1, "copy_fast_b": 1, "copy_ldi_passes": 1, "fend": 1}),
        # SE01: COPY8 1 at $DF40: edge detour, L + 1 refine, FEND at $DF43 detours too
        ("SE01", syn("SE01", FLAT), {"fast_copy8": 1, "copy8_srcedge": 1, "copy_fast_b": 1,
                                     "copy_ldi_passes": 1, "src_edge_hdr": 2, "fend": 1}),
        # SE02: COPY8 1 at $DFFE: slow header, count read to $E000, body walks (parity), 1 B LDI
        ("SE02", syn("SE02", FLAT), {"slow_copy8": 1, "copy_ldi_chunks8": 1, "copy_ldi_b": 1,
                                     "copy_ldi_passes": 1, "src_parity_seams": 1, "src_slow_hdr": 1, "fend": 1}),
        # C4K0: 4096 = 17x240 + 16 B LDI tail from $4000
        ("C4K0", syn("C4K0", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 17, "copy_ldi_chunks16": 1,
                                     "copy_tail16": 1, "copy_dma_b": 4080, "copy_ldi_b": 16,
                                     "copy_ldi_passes": 1, "fend": 1}),
        # C4KP: src $D803: 8x240 to $DF83, exact 125, parity seam, 2051 = 8x240 + 131
        ("C4KP", syn("C4KP", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 18, "copy_dma_b": 4096,
                                     "copy_src_chunks": 1, "src_parity_seams": 1, "fend": 1}),
        # C4KB: C4KP one page on: the walk is a bank seam
        ("C4KB", syn("C4KB", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 18, "copy_dma_b": 4096,
                                     "copy_src_chunks": 1, "src_bank_seams": 1, "fend": 1}),
        # C4KS: C4K0 in a span
        ("C4KS", syn("C4KS", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 17, "copy_ldi_chunks16": 1,
                                     "copy_tail16": 1, "copy_dma_b": 4080, "copy_ldi_b": 16,
                                     "copy_ldi_passes": 1, "fend_span": 1}),
        # C4KD: dest $5800: 8x240 to $5F80, exact 128, seam, 2048 = 8x240 + 128
        ("C4KD", syn("C4KD", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 18, "copy_dma_b": 4096,
                                     "dst_exact_chunks": 1, "dst_seams": 1, "fend_span": 1}),
        # K24K: src off 515 + c, dest c; per 8192 B: 31x240, src-exact 237, walk, 240, 240, dest-exact 35 LDI, seam = 34 DMA; x2 (P, B) + 7616 = 31x240 + src-exact 176: DMA 100 = 24000 - 70; FEND 24515 at $DFC3
        ("K24K", syn("K24K", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 100, "copy_ldi_chunks16": 2,
                                     "copy_tail16": 2, "copy_dma_b": 23930, "copy_ldi_b": 70,
                                     "copy_ldi_passes": passes(35, 35),
                                     "dst_exact_chunks": 2, "copy_src_chunks": 3, "dst_seams": 2,
                                     "src_parity_seams": 1, "src_bank_seams": 1, "src_edge_hdr": 1, "fend": 1}),
        # K43K: five K24K periods (seams P B P B P; 5x34 DMA, 5x35 LDI) + 2048 = 8x240 + 128: DMA 179 = 43008 - 175
        ("K43K", syn("K43K", FLAT), {"op_copy16": 1, "copy_dma_chunks16": 179, "copy_ldi_chunks16": 5,
                                     "copy_tail16": 5, "copy_dma_b": 42833, "copy_ldi_b": 175,
                                     "copy_ldi_passes": passes(35, 35, 35, 35, 35),
                                     "dst_exact_chunks": 5, "copy_src_chunks": 5, "dst_seams": 5,
                                     "src_parity_seams": 3, "src_bank_seams": 2, "fend": 1}),
        # --- SYN rows, gapped 320x192 ---
        # C4K0: 21x192 DMA + 64 B LDI tail, 21 hops
        ("gC4K0", syn("C4K0", G192), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_ldi_chunks16": 1,
                                      "copy_tail16": 1, "copy_dma_b": 4032, "copy_ldi_b": 64,
                                      "copy_ldi_passes": 4, "col_hops": 21, "fend": 1}),
        # C4KP: 10 columns to src off 8067, exact 125 DMA, parity seam, 67 B LDI, 10 columns, 64 B LDI
        ("gC4KP", syn("C4KP", G192), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_ldi_chunks16": 2,
                                      "copy_tail16": 2, "copy_dma_b": 3965, "copy_ldi_b": 131,
                                      "copy_ldi_passes": passes(67, 64),
                                      "copy_src_chunks": 1, "col_hops": 21, "src_parity_seams": 1, "fend": 1}),
        # C4KB: gC4KP one page on, a bank seam
        ("gC4KB", syn("C4KB", G192), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_ldi_chunks16": 2,
                                      "copy_tail16": 2, "copy_dma_b": 3965, "copy_ldi_b": 131,
                                      "copy_ldi_passes": passes(67, 64),
                                      "copy_src_chunks": 1, "col_hops": 21, "src_bank_seams": 1, "fend": 1}),
        # C4KD: gC4K0 from column $58: the hop into $60 seams
        ("gC4KD", syn("C4KD", G192), {"op_copy16": 1, "copy_dma_chunks16": 21, "copy_ldi_chunks16": 1,
                                      "copy_tail16": 1, "copy_dma_b": 4032, "copy_ldi_b": 64,
                                      "copy_ldi_passes": 4, "col_hops": 21, "dst_seams": 1, "fend_span": 1}),
        # K24K: 125x192, 124 hops, seams at columns 32/64/96; src ends split column 39 (src off 8003: 189 DMA + 3) and 82 (8067: 125 + 67), column 124 (7939) exact 192: LDI 70, DMA 23930; FEND at $DFC3
        ("gK24K", syn("K24K", G192), {"op_copy16": 1, "copy_dma_chunks16": 125, "copy_ldi_chunks16": 2,
                                      "copy_tail16": 2, "copy_dma_b": 23930, "copy_ldi_b": 70,
                                      "copy_ldi_passes": passes(3, 67),
                                      "copy_src_chunks": 3, "col_hops": 124, "dst_seams": 3,
                                      "src_parity_seams": 1, "src_bank_seams": 1, "src_edge_hdr": 1, "fend": 1}),
        # K43K: 224x192, 223 hops, 6 seams; src ends split columns 39 (189+3), 82 (125+67), 125 (61 LDI + 131; column 124 exact 192), 167 (189+3), 210 (125+67): LDI 201, DMA 42807
        ("gK43K", syn("K43K", G192), {"op_copy16": 1, "copy_dma_chunks16": 224, "copy_ldi_chunks16": 5,
                                      "copy_tail16": 5, "copy_dma_b": 42807, "copy_ldi_b": 201,
                                      "copy_ldi_passes": passes(3, 67, 61, 3, 67),
                                      "copy_src_chunks": 6, "col_hops": 223, "dst_seams": 6,
                                      "src_parity_seams": 3, "src_bank_seams": 2, "fend": 1}),
        # SYS FE00 at offset 0 reads one FEND
        ("sFE00", lambda: bench.row_events("FE00", FLAT, table="SYS"), {"fend": 1}),
        # --- edge cases ---
        # COPY8 100 at $DF9A: edge detour, L $9C + 100 = 256 stays, thr bail, src-exact 100 DMA to $E000, FEND wraps (parity)
        ("wrap", run([(C8, 100)] + END, FLAT, 8090, copy_thr=81),
         {"src_edge_hdr": 1, "copy8_srcedge": 1, "thr_copy8": 1, "copy_src_chunks": 1,
          "copy_dma_chunks8": 1, "copy_dma_b": 100, "src_wrap_hdr": 1, "src_parity_seams": 1, "fend": 1}),
        # COPY8 100 at page 1 $DF9C: L $9E + 100 = 258 bails, src-exact 98 DMA, bank seam, 2 B LDI tail
        ("srcbail", run([(C8, 100)] + END, FLAT, 16284, copy_thr=81),
         {"src_edge_hdr": 1, "copy8_srcedge": 1, "src_copy8": 1, "copy_src_chunks": 1,
          "copy_dma_chunks8": 1, "copy_ldi_chunks8": 1, "copy_tail8": 1, "copy_dma_b": 98,
          "copy_ldi_b": 2, "copy_ldi_passes": 1, "src_bank_seams": 1, "fend": 1}),
        # SKIP16 300 at $DFFE: slow, the high count byte walks (parity), 1 pass
        ("slow16", run([(S16, 300)] + END, FLAT, 8190),
         {"src_slow_hdr": 1, "slow_skip16": 1, "skip_passes": 1, "src_parity_seams": 1, "fend": 1}),
        # SKIP8 10 at $DFFF: slow, the count byte walks, 1 pass
        ("slow8", run([(S8, 10)] + END, FLAT, 8191),
         {"src_slow_hdr": 1, "slow_skip8": 1, "skip_passes": 1, "src_parity_seams": 1, "fend": 1}),
        # RUN16 300 at $DFFC: slow to $E000, 240 DMA + 60 CPU tail, FEND wraps
        ("slowr16", run([(R16, 300)] + END, FLAT, 8188, run_thr=71),
         {"src_slow_hdr": 1, "slow_run16": 1, "run_dma_chunks16": 1, "run_cpu_chunks16": 1,
          "run_tail16": 1, "run_dma_b": 240, "run_cpu_b": 60, "run_cpu_passes": 4, "src_wrap_hdr": 1,
          "src_parity_seams": 1, "fend": 1}),
        # RUN8 20 at $DFFD: slow to $E000, 20 B CPU, FEND wraps
        ("slowr8", run([(R8, 20)] + END, FLAT, 8189, run_thr=71),
         {"src_slow_hdr": 1, "slow_run8": 1, "run_cpu_chunks8": 1, "run_cpu_b": 20, "run_cpu_passes": 2,
          "src_wrap_hdr": 1, "src_parity_seams": 1, "fend": 1}),
        # COPY16 90 at $DFFD: slow to $E000, the body walks (parity), 90 DMA
        ("slowc16", run([(C16, 90)] + END, FLAT, 8189, copy_thr=81),
         {"src_slow_hdr": 1, "slow_copy16": 1, "copy_dma_chunks16": 1, "copy_dma_b": 90,
          "src_parity_seams": 1, "fend": 1}),
        # h72 column $5F at E = 72: RUN8 30 hops with an empty first segment into $60 (seam);
        # the zero-count seg1 call runs no pass, seg2 30 runs 2
        ("hop0", run([(R8, 30)] + END, G72, 0, dst=(0, 0x5F48), run_thr=71),
         {"fast_run8": 1, "fast_hop_run8": 1, "fast_hop0_run8": 1, "fast_dst_seams": 1,
          "run_fast_b": 30, "run_cpu_passes": 2, "fend": 1}),
        # h192 COPY16 300 from E = 150: 42 LDI before any DMA, hop, 192 DMA, hop, 66 LDI after it
        ("ldifirst", run([(C16, 300)] + END, G192, 0, dst=(0, 0x4096), copy_thr=81),
         {"op_copy16": 1, "copy_ldi_chunks16": 2, "copy_dma_chunks16": 1, "copy_tail16": 1,
          "copy_ldi_b": 108, "copy_dma_b": 192, "copy_ldi_passes": passes(42, 66), "col_hops": 2, "fend": 1}),
        # h192 RUN16 300 from E = 150: 42 CPU, hop, 192 DMA, hop, 66 CPU
        ("cpufirst", run([(R16, 300)] + END, G192, 0, dst=(0, 0x4096), run_thr=71),
         {"op_run16": 1, "run_cpu_chunks16": 2, "run_dma_chunks16": 1, "run_tail16": 1,
          "run_cpu_b": 108, "run_dma_b": 192, "run_cpu_passes": passes(42, 66), "col_hops": 2, "fend": 1}),
        # h72 COPY8 200 under thr 255: gap bail, a DMA-free body of LDI 72 + 72 + 56
        ("nodma", run([(C8, 200)] + END, G72, 0, copy_thr=255),
         {"gap_copy8": 1, "copy_ldi_chunks8": 3, "copy_ldi_b": 200, "copy_ldi_passes": passes(72, 72, 56),
          "col_hops": 2, "fend": 1}),
        # h72 SKIP8 72 from E = 0 lands E = 72 (no hop); SKIP16 10 hops in its normalize, 1 pass
        ("defer", run([(S8, 72), (S16, 10)] + END, G72, 0),
         {"fast_skip8": 1, "op_skip16": 1, "gap_skip_passes": 1, "col_hops": 1, "fend": 1}),
        # h144 from E = 100: SKIP16 300 passes 44 to the column end, hop, 144, hop, 112; the same op flat
        # from $4000 is one pass
        ("gapskip", run([(S16, 300)] + END, G144, 0, dst=(0, 0x4064)),
         {"op_skip16": 1, "gap_skip_passes": 3, "col_hops": 2, "fend": 1}),
        ("flatskip", run([(S16, 300)] + END, FLAT, 0),
         {"op_skip16": 1, "skip_passes": 1, "fend": 1}),
        # h72 RUN8 200 under thr 241: over 128 >= 72 bails, CPU 72 + 72 + 56, 2 hops
        ("gaprun", run([(R8, 200)] + END, G72, 0, run_thr=241),
         {"gap_run8": 1, "run_cpu_chunks8": 3, "run_cpu_b": 200, "run_cpu_passes": passes(72, 72, 56),
          "col_hops": 2, "fend": 1}),
        # h192 COPY8 250 at E = 100 under thr 255: 350 carries, LDI 92 + 158, 1 hop
        ("gapcopy", run([(C8, 250)] + END, G192, 0, dst=(0, 0x4064), copy_thr=255),
         {"gap_copy8": 1, "copy_ldi_chunks8": 2, "copy_ldi_b": 250, "copy_ldi_passes": passes(92, 158),
          "col_hops": 1, "fend": 1}),
        # flat $5FF0: COPY8 16 edge bail to $6000 exact; SKIP8 4 at D = $60 edge bail, seam, 1 pass
        ("edge60", run([(C8, 16), (S8, 4)] + END, FLAT, 0, dst=(0, 0x5FF0), copy_thr=81),
         {"edge_copy8": 1, "copy_ldi_chunks8": 1, "copy_ldi_b": 16, "copy_ldi_passes": 1, "dst_exact_chunks": 1,
          "edge_skip8": 1, "skip_passes": 1, "dst_seams": 1, "fend": 1}),
        # h250 from E = 5: COPY16 300 room 245 takes the cap arm (240 DMA), then LDI 5 to the
        # column end, hop, LDI 55; every chunk on a height over 240
        ("hiarm", run([(C16, 300)] + END, (320, 250, True), 0, dst=(0, 0x4005), copy_thr=81),
         {"op_copy16": 1, "copy_dma_chunks16": 1, "copy_dma_b": 240, "copy_ldi_chunks16": 2,
          "copy_ldi_b": 60, "copy_ldi_passes": passes(5, 55), "copy_tail16": 2, "col_hops": 1,
          "gap_hi_chunks": 3, "cap_arm_chunks": 1, "fend": 1}),
        # h250 from E = 0: RUN8 250 >= 71, C = 250 <= room takes the cap arm (240 DMA), CPU 10
        ("hirun", run([(R8, 250)] + END, (320, 250, True), 0, run_thr=71),
         {"thr_run8": 1, "run_dma_chunks8": 1, "run_dma_b": 240, "run_cpu_chunks8": 1, "run_cpu_b": 10,
          "run_cpu_passes": 1, "run_tail8": 1, "gap_hi_chunks": 2, "cap_arm_chunks": 1, "fend": 1}),
        # KSTART, PAL at $C3E9, COPY16 1000 = 4x240 + 40 B LDI tail, KFLIP
        ("kframe", run([(0x28, 0), (0x18, 512), (C16, 1000), (0x20, 0)], FLAT, 1000, copy_thr=81),
         {"kstart": 1, "pal_ops": 1, "op_copy16": 1, "copy_dma_chunks16": 4, "copy_ldi_chunks16": 1,
          "copy_tail16": 1, "copy_dma_b": 960, "copy_ldi_b": 40, "copy_ldi_passes": 3, "kflip": 1}),
    ]
    # kernel blocks and passes, fast handler and body, at n = 15, 16, 17, 32, 33 (flat $4000, 81/71):
    # vid_copy_ldi 87 + 19n + 13 ceil(n/16) T per call (jp pe 13 T taken or not); vid_fill_cpu
    # 153 + 15n + 15 ceil(n/16) T (djnz 15 T; the last pass's 10 T leaves -5 T in the 153)
    # h72 from E = 64: a 16 B op crosses the column end as 8 + 8, two kernel calls of one block/pass each
    cases += [("gapldi16", run([(C8, 16)] + END, G72, 0, dst=(0, 0x4040), copy_thr=81),
               {"fast_copy8": 1, "fast_hop_copy8": 1, "copy_fast_b": 16, "copy_ldi_passes": passes(8, 8), "fend": 1}),
              ("gapcpu16", run([(R8, 16)] + END, G72, 0, dst=(0, 0x4040), run_thr=71),
               {"fast_run8": 1, "fast_hop_run8": 1, "run_fast_b": 16, "run_cpu_passes": passes(8, 8), "fend": 1})]
    for n, blocks in ((15, 1), (16, 1), (17, 2), (32, 2), (33, 3)):
        cases += [
            (f"ldi{n}", run([(C8, n)] + END, FLAT, 0, copy_thr=81),
             {"fast_copy8": 1, "copy_fast_b": n, "copy_ldi_passes": blocks, "fend": 1}),
            (f"cpu{n}", run([(R8, n)] + END, FLAT, 0, run_thr=71),
             {"fast_run8": 1, "run_fast_b": n, "run_cpu_passes": blocks, "fend": 1}),
            (f"ldib{n}", run([(C16, n)] + END, FLAT, 0, copy_thr=81),
             {"op_copy16": 1, "copy_ldi_chunks16": 1, "copy_ldi_b": n, "copy_ldi_passes": blocks, "fend": 1}),
            (f"cpub{n}", run([(R16, n)] + END, FLAT, 0, run_thr=71),
             {"op_run16": 1, "run_cpu_chunks16": 1, "run_cpu_b": n, "run_cpu_passes": blocks, "fend": 1})]
    bad, seen, got_by = [], set(), {}
    for label, fn, want in cases:
        got = got_by[label] = fn().as_dict()
        seen |= set(got)
        if got != want:
            diff = {k: (got.get(k, 0), want.get(k, 0)) for k in set(got) | set(want)
                    if got.get(k, 0) != want.get(k, 0)}
            bad.append(f"{label}: (sim, hand) {diff}")
    expect(not bad, "event counts:\n  " + "\n  ".join(bad))
    every = set(ps.Events().as_dict(nonzero=False))
    expect(seen == every, f"counters no case exercises: {sorted(every - seen)}")
    # a body LDI/CPU chunk counts wherever it sits; the tail is its diagnostic subset
    body = {k: (g.get("copy_ldi_chunks16", 0) + g.get("copy_ldi_chunks8", 0) + g.get("run_cpu_chunks16", 0),
                g.get("copy_tail16", 0) + g.get("copy_tail8", 0) + g.get("run_tail16", 0))
            for k, g in got_by.items() if k in ("ldifirst", "cpufirst", "nodma", "JC72")}
    expect(body == {"ldifirst": (2, 1), "cpufirst": (2, 1), "nodma": (3, 0), "JC72": (30, 0)},
           f"body chunks and tails: {body}")
    # every standalone op row and SYNTH row simulates on its surfaces
    for mode, rows in bench.BENCH_TABLES.items():
        for r in rows:
            if r[1] != bench.CAL_KIND:
                bench.row_events(r[0])
    for name in ("SYN", "SYS"):
        for r in bench.SESSION_TABLES[name]:
            if r[1] in bench.SESSION_SYNTH:
                for surf in (FLAT, (256, 144, False), (320, 256, False), G192, G144):
                    bench.row_events(r[0], surf, table=name)
    expect(bench.SITTING_SELECTS == (81, 71), "sitting-5 image selects")
    expect(bench.session_row_selects("SYN", "C4K0") == (81, 71)
           and bench.session_row_selects("REAL", "W055") == (55, 71)
           and bench.session_row_selects("REAL", "AUD1") is None,
           "SYNTH rows at 81/71, decode rows at their thr and 71")
    bench.SESSION_TABLES["TST0"] = (("W000", "sweep", 0, 0, 0, False),)
    try:
        expect(bench.session_row_selects("TST0", "W000") == (81, 71), "a thr-0 decode row at 81/71")
    finally:
        del bench.SESSION_TABLES["TST0"]
    expect(bench.row_selects("C080") == (81, 71) and bench.row_selects("GF71") == (81, 71)
           and bench.row_selects("FC56") == (81, 241) and bench.row_selects("JD72") == (59, 71),
           "standalone selects: thr by kind, 0 and the other select at 81/71")
    # thr-0 and SYNTH rows stay at 81/71 when the model selects move; the
    # simulator's own default follows them
    ship_tags = ("NC16", "NR16", "C080", "C081", "F070", "F071", "P071", "HC03", "HK56",
                 "JR72", "GF71", "GF56")
    before = {t: bench.row_events(t) for t in ship_tags}
    syn_before = bench.row_events("C4K0", FLAT)
    tc = enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"], tc["run_dma_min"]
    try:
        tc["copy_dma_min"], tc["run_dma_min"] = 10, 10
        after = {t: bench.row_events(t) for t in ship_tags}
        syn_after = bench.row_events("C4K0", FLAT)
        follows = ps.events([(C8, 16)] * 15 + END, FLAT, 0).as_dict()
    finally:
        tc["copy_dma_min"], tc["run_dma_min"] = saved
    expect(after == before and syn_after == syn_before,
           f"rows moved with the model selects: {[t for t in ship_tags if after[t] != before[t]]}")
    expect(follows == {"thr_copy8": 15, "copy_dma_chunks8": 15, "copy_dma_b": 240, "fend": 1},
           f"the simulator default must follow copy_dma_min: {follows}")
    expect(bench.row_events("NC16", ship=(16, 71)).thr_copy8 == 15, "ship= moves a thr-0 row")
    # player aborts and interface rules
    for ops, surf, kw, what in (([(S16, 8192), (S16, 8192)] + END, FLAT, {"dst_pages": 1}, "DSTOVR"),
                                ([(0x20, 0)], FLAT, {}, "KFLIP"),
                                ([(0x24, 0)] + END, FLAT, {}, "reserved"),
                                ([(0x28, 0), (0x28, 0)] + END, FLAT, {}, "KSTART")):
        try:
            ps.events(ops, surf, 0, **kw)
        except ps.PathError as e:
            expect(what in str(e), f"{what}: {e}")
        else:
            raise AssertionError(f"{what} must raise PathError")
    for bad_call in (lambda: bench.row_events("C4K0"), lambda: bench.row_events("CALL"),
                     lambda: bench.row_events("JC72", G144)):
        try:
            bad_call()
        except ValueError:
            pass
        else:
            raise AssertionError("row_events must refuse a missing or wrong surface and the CAL row")
    ev = bench.row_events("SDS1")
    expect(ev.price({"op_skip16": 200.0, "skip_passes": 10.0, "dst_seams": 50.0, "fend": 1.0}) == 271.0
           and (ev + ev).skip_passes == 4 and ev.scale(0.5).dst_seams == 0.5, "price, add and scale")
    try:
        ev.price({"op_skip16": 200.0})
    except KeyError:
        pass
    else:
        raise AssertionError("price must refuse an unpriced nonzero event")
    c250 = bench.row_events("C250")
    unit = {k: 1.0 for k in c250.as_dict() if k not in ps.DIAGNOSTIC}
    expect(c250.price(unit) == 31 + 31 + 31 + 7440 + 310 + 31 + 31 + 1, "tails are not priced")
    try:
        c250.price(dict(unit, copy_tail8=100.0))
    except ValueError:
        pass
    else:
        raise AssertionError("price must refuse a tail coefficient")


@case(10, "frame model - per-frame model T equals the encoder's, types, offsets, span cursor")
def t10_frame_model():
    import nxv2_frame_model as fm
    import nxv2_path_sim as ps
    apad, areal = 1536, 1250
    for (w, h, n, want_types) in ((320, 192, 6, {"first", "middle", "last", "delta"}),
                                  (256, 64, 4, {"single", "delta"})):
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        orig = np.empty((n, h, w, 3), dtype=np.uint8)
        for i in range(n):
            base = np.stack([128 + 110 * np.sin((xx + i * 5) * 0.05),
                             128 + 110 * np.cos((yy - i * 3) * 0.07),
                             128 + 110 * np.sin((xx + yy) * 0.03 + i * 0.3)], axis=2)
            orig[i] = np.clip(base, 0, 255).astype(np.uint8)
        chg, po = _synth_clip(orig)
        result = enc.encode_clip(orig, chg, po, w, h, 25.0, abytes_pad=apad)
        payloads, want_t = result["payloads"], result["per_frame"]["t"]
        hdr = enc.pack_header(width=w, height=h, fps=25.0, channels=2, arate=enc.RATE_STEREO,
                              frame_count=len(payloads), audio_bytes_per_frame=areal,
                              ring_start_margin_blocks=0, per_frame_cap_blocks=0)
        body = b"".join(bytes(apad) + p + bytes((-len(p)) % 512) for p in payloads)
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / f"fm_{w}x{h}.vid"
            path.write_bytes(hdr + body)
            frames = fm.frames(path)
            saved = dict(enc.TMODEL_COEFFS)
            moved = fm.frames(path, copy_thr=59, run_thr=241)
            expect(enc.TMODEL_COEFFS == saved, "frames() must restore the selects")
        expect(len(frames) == len(payloads) == len(want_t), f"{w}x{h}: {len(frames)} frames")
        types = [f.type for f in frames]
        expect(want_types <= set(types), f"{w}x{h}: frame types {types}")
        offset = enc.HEADER_SIZE
        span_at = 0
        for f, p, t in zip(frames, payloads, want_t):
            offset += apad
            expect(f.offset == offset and f.nbytes == len(p),
                   f"{w}x{h} frame {f.index}: offset {f.offset} / {offset}, bytes {f.nbytes} / {len(p)}")
            offset += -(-len(p) // 512) * 512
            expect(abs(f.model_t - t) <= 0.01,
                   f"{w}x{h} frame {f.index} ({f.type}): model {f.model_t:.4f} vs encoder {t:.4f}")
            surf = fm.surface_of(enc.unpack_header(hdr))
            if f.type in ("middle", "last"):
                expect(ps.dst_linear(*f.dst_start, surf) == span_at,
                       f"{w}x{h} frame {f.index}: span cursor {f.dst_start} is not paint index {span_at}")
            elif f.type != "delta":
                span_at = 0
            if f.type in ("first", "middle"):
                span_at += sum(k for op, k in f.ops if op in (ps.OP_COPY8, ps.OP_COPY16))
        expect(any(f.events != g.events for f, g in zip(frames, moved)),
               f"{w}x{h}: events at COPY 59 / RUN 241 must differ somewhere")
    # direct-serve: a three-chunk span then two single frames on 256x16; no
    # events or model T, but the span state and dest cursor carry
    raw = 256 * 16
    pal = bytes([enc.OP_PAL]) + bytes(enc.PAL_BLOCK_SIZE)
    kst, fend, kflip = bytes([enc.OP_KSTART]), bytes([enc.OP_FEND]), bytes([enc.OP_KFLIP])
    payloads = [kst + pal + enc.op_copy(bytes(1500)) + fend,
                enc.op_copy(bytes(1500)) + fend,
                enc.op_copy(bytes(raw - 3000)) + kflip,
                kst + enc.op_copy(bytes(raw)) + kflip,
                kst + enc.op_copy(bytes(raw)) + kflip]
    hdr = enc.pack_header(width=256, height=16, fps=25.0, channels=2, arate=enc.RATE_STEREO,
                          frame_count=len(payloads), audio_bytes_per_frame=areal,
                          ring_start_margin_blocks=0, per_frame_cap_blocks=0,
                          flags=enc.FLAG_DELTA_STREAM | enc.FLAG_DIRECT_SERVE)
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "fm_direct.vid"
        path.write_bytes(hdr + b"".join(bytes(apad) + p + bytes((-len(p)) % 512) for p in payloads))
        frames = fm.frames(path)
    surf = (256, 16, False)
    got = [(f.type, f.events, f.model_t, ps.dst_linear(*f.dst_start, surf)) for f in frames]
    expect(got == [("first", None, None, 0), ("middle", None, None, 1500), ("last", None, None, 3000),
                   ("single", None, None, 0), ("single", None, None, 0)],
           f"direct span frames: {got}")


# ---------------------------------------------------------------------------
# Synthetic sitting 5 for t10_gap_rules, built and checked by hand-written
# arithmetic over nxv2_path_sim events: nothing below prices through fit_gap_bench.
# ---------------------------------------------------------------------------
_GAP_ZERO = frozenset({"fast_hop0_run8", "fast_hop0_copy8", "pal_chunks", "kstart", "kflip", "fend", "fend_span"})
_GAP_TAILS = frozenset({"run_tail8", "run_tail16", "copy_tail8", "copy_tail16"})


def _gap_chunk(body):
    return (body, None), ("gap_chunk_t", "lo")


_GAP_MAP = {       # counter -> ((term, None | "gap" | "lo" (gapped, height <= 240) | "strm"), ...)
    "fast_skip8": (("t_skip", None), ("gap_fast_t", "gap")),
    "fast_run8": (("t_op_run", None), ("gap_fast_t", "gap")),
    "fast_copy8": (("t_op_copy", None), ("gap_fast_t", "gap")),
    "thr_run8": (("t_op_run", None), ("fill_dma_path_t", None)),
    "thr_copy8": (("t_op_copy", None), ("copy_dma_path_t", None)),
    "edge_skip8": (("edge_skip_t", None),),
    "edge_run8": (("edge_run_t", None),),
    "edge_copy8": (("edge_copy_t", None),),
    "gap_skip8": (("edge_skip_t", None), ("gap_bail_skip_t", None)),
    "gap_run8": (("edge_run_t", None), ("gap_bail_t", None)),
    "gap_copy8": (("edge_copy_t", None), ("gap_bail_t", None)),
    "src_copy8": (("edge_copy_t", None),),
    "op_skip16": (("t_skip16", None),),
    "op_run16": (("t_op_run", None), ("run16_entry_t", None)),
    "op_copy16": (("t_op_copy", None), ("copy16_entry_t", None)),
    "slow_skip8": (("t_skip", None),),
    "slow_skip16": (("t_skip16", None), ("slow_fetch_t", None)),
    "slow_run8": (("t_op_run", None), ("slow_fetch_t", None)),
    "slow_run16": (("t_op_run", None), ("run16_entry_t", None), ("slow_fetch_t", None), ("slow_fetch_t", None)),
    "slow_copy8": (("t_op_copy", None),),
    "slow_copy16": (("t_op_copy", None), ("copy16_entry_t", None), ("slow_fetch_t", None), ("slow_cmp_t", None)),
    "fast_hop_skip8": (("fast_hop_skip_t", None),),
    "fast_hop_run8": (("fast_hop_run_t", None),),
    "fast_hop_copy8": (("fast_hop_copy_t", None),),
    "fast_dst_seams": (("dst_seam_t", None),),
    "copy8_srcedge": (("srcedge_t", None),),
    "run_fast_b": (("fill_cpu", None),),
    "copy_fast_b": (("fetch", None),),
    "copy_ldi_passes": (("copy_ldi_pass_t", None),),
    "run_cpu_passes": (("fill_cpu_pass_t", None),),
    "skip_passes": (("t_skip_pass", None),),
    "gap_skip_passes": (("gap_skip_pass_t", None),),
    "run_cpu_chunks8": _gap_chunk("fill_body_cpu_t"),
    "run_cpu_chunks16": _gap_chunk("fill_body_cpu_t"),
    "run_dma_chunks8": _gap_chunk("fill_dma_setup"),
    "run_dma_chunks16": _gap_chunk("fill_dma_setup"),
    "copy_ldi_chunks8": _gap_chunk("copy_body_ldi_t"),
    "copy_ldi_chunks16": _gap_chunk("copy_body_ldi_t"),
    "copy_dma_chunks8": _gap_chunk("copy_dma_setup"),
    "copy_dma_chunks16": _gap_chunk("copy_dma_setup"),
    "run_cpu_b": (("fill_cpu", None),),
    "run_dma_b": (("fill_dma_per_b", None),),
    "copy_ldi_b": (("fetch", None),),
    "copy_dma_b": (("copy_dma_per_b", None),),
    "dst_exact_chunks": (("dst_exact_t", None),),
    "cap_arm_chunks": (("cap_arm_t", None),),
    "gap_hi_chunks": (("gap_chunk_hi_t", None),),
    "copy_src_chunks": (("src_exact_t", None),),
    "col_hops": (("col_hop_t", None),),
    "dst_seams": (("dst_seam_t", None),),
    "src_parity_seams": (("src_parity_seam_t", None), ("src_seam_strm_t", "strm")),
    "src_bank_seams": (("src_bank_seam_t", None), ("src_seam_strm_t", "strm")),
    "src_edge_hdr": (("src_edge_t", None),),
    "src_slow_hdr": (("src_slow_hdr_t", None),),
    "src_wrap_hdr": (("src_edge_t", None), ("src_wrap_t", None)),
    "pal_ops": (("t_palette", None),),
    "pal_straddles": (("t_palette", None), ("pal_straddle_t", None)),
}
_GAP_FRAMES = {}


def _gap_cost(ev, surface, streaming, long_b, rem, vals, split=()):
    """Decode T of one set of events: counters x terms, LDI bytes at fetch_short or
    (op L >= 64) fetch_long, and copy_dma_rem_t per remainder op."""
    gapped = bool(surface[2])
    low = gapped and surface[1] <= 240
    total, fetch_b = 0.0, 0
    for name, n in ev.as_dict().items():
        if name in _GAP_ZERO or name in _GAP_TAILS:
            continue
        for term, when in _GAP_MAP[name]:
            if (when == "gap" and not gapped) or (when == "lo" and not low) or (when == "strm" and not streaming):
                continue
            if term == "fetch":
                fetch_b += n
                continue
            if term in split:
                term = term[:-2] + ("16" if name.endswith("16") else "8") + "_t"
            total += n * vals[term]
    return (total + (fetch_b - long_b) * vals["fetch_short"] + long_b * vals["fetch_long"]
            + rem * vals["copy_dma_rem_t"])


def _gap_fixture(clip):
    import re as _re
    ps1 = (ROOT / "tests" / "build-tests.ps1").read_text(encoding="utf-8")
    era = _re.search(r"\$vidLegSettlementTag = '([^']+)'", ps1).group(1)
    found = sorted((ROOT / "tests" / "out").glob(f"{clip:03d}_*_{era}_*_cache.vid"))
    return found[0] if found else None


def _gap_frames(clip, copy_thr, run_thr):
    """(header, surface, [(type, events, long LDI bytes, remainder ops)]) for every
    frame of a fixture at the selects; the span cursor carries across chunk frames."""
    import nxv2_frame_model as fm
    import nxv2_path_sim as ps

    class Player(ps._Player):
        long_b = rem = 0

        def _op(self, handler, op, n):
            before = self.ev.copy_fast_b + self.ev.copy_ldi_b
            handler(op, n)
            if op in (ps.OP_COPY8, ps.OP_COPY16):
                self.long_b += (self.ev.copy_fast_b + self.ev.copy_ldi_b - before) if n >= 64 else 0
                self.rem += n >= 240 and n % 240 >= self.copy_thr

        def fast_op(self, op, n):
            self._op(super().fast_op, op, n)

        def slow_op(self, op, n):
            self._op(super().slow_op, op, n)

    key = (clip, copy_thr, run_thr)
    if key not in _GAP_FRAMES:
        buf = _gap_fixture(clip).read_bytes()
        hdr = enc.unpack_header(buf)
        surface = (hdr["width"], hdr["height"], enc.is_gapped(hdr["width"], hdr["height"]))
        out, in_span, dst = [], False, (0, 0x4000)
        for _p, _s, _t, start, length in dec._iter_frames(buf, hdr):
            ops = ps.parse_payload(buf[start:start + length])
            p = Player(surface, start, dst, in_span, copy_thr, run_thr, None)
            ftype = fm.frame_type(ops, in_span)
            p.run(ops)
            out.append((ftype, p.ev, p.long_b, int(p.rem)))
            in_span = p.in_span
            dst = (p.dpage, p.de) if in_span else (0, 0x4000)
        _GAP_FRAMES[key] = (hdr, surface, out)
    return _GAP_FRAMES[key]


def _gap_row_extra():
    """T per op off the model on the COPY fast rows: -16 on L080 less its weighted projection
    onto S1's copy design (1, short L, long L, blocks), so the long rates spread for S1's max
    without moving the joint fit or lifting t_op_copy; the twins C016/NC16 carry none."""
    tags = ("C001", "C004", "C008", "C038", "L048", "L056", "L060", "L064", "L072", "L080")
    rows = [bench._row(t) for t in tags]
    A = np.array([[1.0, L if L < 64 else 0.0, L if L >= 64 else 0.0, -(-L // 16)] for _t, _k, L, *_x in rows])
    w2 = np.array([(r * o / 1824.0) ** 2 for _t, _k, _L, o, r, *_x in rows])
    u = np.array([-16.0 if t == "L080" else 0.0 for t in tags])
    d = u - A @ np.linalg.solve(A.T @ (w2[:, None] * A), A.T @ (w2 * u))
    return dict(zip(tags, map(float, d)))


def _gap_hidden():
    """(terms, resident frame terms, streaming frame terms, extras) for a synthetic
    sitting 5, chosen so each rule's branches bind: pool 80 banks, a nonzero
    remainder term, L064-L080 off one rate, S8's 1.12 binding flat and its audio
    branch gapped (009's large audio stage), an S6 near-tie on the sweeps, and a
    bench harness on every standalone rep (h_rep T, never a model term)."""
    H = {"fetch_short": 19.785, "fetch_long": 19.885, "t_skip": 141.83, "t_skip16": 210.93,
         "t_op_run": 367.43, "t_op_copy": 303.73, "fill_cpu": 15.885, "copy_dma_per_b": 5.065,
         "fill_dma_per_b": 5.085, "copy_ldi_pass_t": 9.4, "fill_cpu_pass_t": 18.6,
         "copy_dma_setup": 881.3, "copy_dma_path_t": -18.4,
         "copy_body_ldi_t": 421.7, "fill_dma_setup": 783.1, "fill_dma_path_t": -71.2,
         "fill_body_cpu_t": 401.9, "copy16_entry_t": 70.3, "run16_entry_t": 68.6, "t_skip_pass": 121.4,
         "gap_skip_pass_t": 97.4, "edge_skip_t": 181.2, "edge_run_t": 203.6, "edge_copy_t": 212.8, "dst_seam_t": 151.7,
         "col_hop_t": 41.3, "src_parity_seam_t": 231.6, "src_bank_seam_t": 331.2, "src_slow_hdr_t": 602.4,
         "fast_hop_skip_t": 46.2, "fast_hop_run_t": 251.4, "fast_hop_copy_t": 241.7, "copy_dma_rem_t": 10.0,
         "t_palette": 16012.4, "pal_straddle_t": 903.6, "src_seam_strm_t": 61.2,
         # hand-countable terms 1 T over their instruction counts
         "gap_fast_t": 29.0, "gap_bail_skip_t": 51.0, "gap_bail_t": 74.0, "slow_fetch_t": 100.0,
         "slow_cmp_t": 19.0, "srcedge_t": 39.0, "src_edge_t": 70.0, "src_wrap_t": 18.0, "dst_exact_t": 165.0,
         "src_exact_t": 157.0, "gap_chunk_t": 48.0, "gap_chunk_hi_t": 48.0, "cap_arm_t": 19.0}
    res = {"frame_delta_t": 1101.2, "frame_middle_t": 1152.8, "frame_first_t": 1503.1,
           "frame_single_t": 1702.4, "frame_last_t": 1349.7}
    strm = {k: x + 150.0 for k, x in res.items()}
    X = {"nul0": {"resident": 352.0, "streaming": 421.0}, "glue": {"resident": 40000.0, "streaming": 46000.0},
         "pace": 301.0, "aud": {c: 140000.0 if c == 9 else 36000.0 for c in range(1, 10)}, "h_frame": 480.0,
         "prod": {7: 10480.0, 8: 10150.0, 9: 10820.0}, "comp": {"flat": 1.031, "gapped": 1.243},
         "direct": (11.53, 60.4, 30120.0), "dt": {"DTI0": 6010.0, "DTB0": 6400.0, "DTC0": 6230.0, "DTD0": 6620.0},
         "pool": 80, "depth": 2400, "fill": 120, "remn": 3000, "m_strm": 40, "cal": 5003, "h_rep": 712.0,
         "row_extra": _gap_row_extra(),                                  # T per op off the model
         "sweep_extra": {55: 3000.0, 60: 3000.0, 65: 0.0, 70: 2000.0, 75: 3000.0, 81: 4000.0},   # T per frame
         "delivery": {**{c: "resident" for c in (1, 2, 3, 4, 5, 6)}, **{c: "streaming" for c in (7, 8, 9)},
                      **{c: "direct" for c in (10, 12, 13, 14)}},
         "h": {"pace": 104, "stub": 144, "audrep": 591, "spin": 161,
               "skip": {"resident": 492, "streaming": 1174}},       # Task 12 hand counts
         "af": {"W065": 0.871, "FA65": 0.869, "FB65": 0.869, "FC65": 0.870, "WL16": 0.872, "AUD1": 0.865,
                "LOOP": 0.868, "PROD": 0.880, "K43K": 0.868, "FE00": 0.8695, "C4K0": 0.867, "K24K": 0.868,
                "DSWP": 0.874, "DTI0": 0.890, "DTC0": 0.885}}
    return H, res, strm, X


_GAP_SESSIONS = (("REAL", 1), ("SYN", 1), ("REAL", 2), ("SYN", 2), ("REAL", 3), ("SYN", 3), ("REAL", 4),
                 ("SYN", 4), ("REAL", 5), ("REAL", 7), ("SYS", 7), ("REAL", 8), ("REAL", 9), ("DS1", 10),
                 ("DS1", 12), ("DS1", 13), ("DS1", 14))
_GAP_GRID = (55, 60, 65, 70, 75, 81)


def _gap_runs(hidden, seed):
    """Every Q run of a synthetic sitting 5 (Parts B-D) with +-1 raster line on
    every timed row, and the D-image NXBC rows. -> ([{stamp, verb, clip, rows,
    log, err}], d_rows)."""
    import random
    import nxv2_bench_log as blog
    H, res, strm, X = hidden
    rng = random.Random(seed)
    values = {"resident": {**H, **res}, "streaming": {**H, **strm}}
    h = X["h"]

    def fd(total_t):
        return divmod(int(round(total_t / 1824.0)) + rng.choice((-1, 0, 1)), 311)

    def standalone(mode):
        rows = []
        for tag in bench.printed_tags(mode):
            if tag in ("CALL", "CALR"):
                rows.append((tag, 0, 16, *divmod(X["cal"], 311)))
                continue
            _t, kind, L, o, r, _thr, _geo = bench._row(tag)
            ev = bench.row_events(tag)
            long_b = ev.copy_fast_b + ev.copy_ldi_b if L >= 64 else 0
            rem = o if kind.startswith("copy") and L >= 240 and L % 240 >= bench.row_selects(tag)[0] else 0
            t_rep = (_gap_cost(ev, bench.row_surface(tag), False, long_b, rem, values["resident"])
                     + X["row_extra"].get(tag, 0.0) * o + X["h_rep"])
            rows.append((tag, o, r, *fd(t_rep * r)))
        return rows

    def session(table, clip):
        deliv = X["delivery"][clip]
        key = "streaming" if deliv == "streaming" else "resident"
        vals, af, out, T = values[key], X["af"], {}, {}
        buf = _gap_fixture(clip).read_bytes()
        hdr = enc.unpack_header(buf)
        surface = (hdr["width"], hdr["height"], enc.is_gapped(hdr["width"], hdr["height"]))
        out["IDEN"] = ({"resident": 0, "streaming": 1, "direct": 2}[deliv], hdr["frame_count"] & 0xFFFF,
                       0x140 if hdr["width"] == 320 else 0x100, hdr["height"] & 0xFF)
        if table != "DS1":
            out["RING"] = (0, X["depth"] if key == "streaming" else 0, X["fill"] if key == "streaming" else 0,
                           X["pool"])
        if table in ("SYN", "SYS"):
            types = {"FE00": "frame_delta_t", "FE01": "frame_middle_t", "KS01": "frame_single_t",
                     "KS02": "frame_first_t", "KF01": "frame_last_t"}
            armed = {a for _u, a in bench.SESSION_ARMED_PAIRS[table]}
            for row in bench.SESSION_TABLES[table]:
                tag, kind = row[0], row[1]
                if kind not in bench.SESSION_SYNTH or tag in armed:
                    continue
                T[tag] = X["nul0"][key] + (vals[types[tag]] if tag in types else 0.0)
                if tag != "NUL0" and tag not in types:
                    _t, _k, _reps, frame, preset, *sites = row
                    n = next((n for op, n in bench.synth_ops(frame, sites) if op in (0x10, 0x14)), 0)
                    ev = bench.row_events(tag, surface, table)
                    long_b = ev.copy_fast_b + ev.copy_ldi_b if n >= 64 else 0
                    rem = 1 if n >= 240 and n % 240 >= 81 else 0
                    T[tag] += (vals["frame_delta_t" if preset == 0 else "frame_middle_t"]
                               + _gap_cost(ev, surface, key == "streaming", long_b, rem, vals))
            for u, a in bench.SESSION_ARMED_PAIRS[table]:
                T[a] = T[u] / af[u]
            for row in bench.SESSION_TABLES[table]:
                if row[1] in bench.SESSION_SYNTH:
                    out[row[0]] = (row[4], row[2], *fd(T[row[0]] * row[2]))
        elif table == "REAL":
            comp = X["comp"]["gapped" if surface[2] else "flat"]
            dect = {}
            for t in _GAP_GRID:
                _h, _s, frames = _gap_frames(clip, t, 71)
                dect[t] = [(vals[f"frame_{ft}_t"] + _gap_cost(ev, surface, key == "streaming", lb, rm, vals)) * comp
                          for ft, ev, lb, rm in frames]
            m = min(X["m_strm"], len(dect[65])) if key == "streaming" else len(dect[65])
            hs, aud = h["skip"][key], X["aud"][clip]
            top = sorted(range(m), key=lambda k: (-dect[65][k], k))[:3]
            out["SCAN"] = (m, 1, *fd(sum(dect[65][:m])))
            for t in _GAP_GRID:
                out[f"W0{t:02d}"] = (m, 1, *fd(sum(x + hs + X["sweep_extra"][t] for x in dect[t][:m])))
            T["W065"] = sum(x + hs for x in dect[65][:m])
            for tag, k in zip(("FA65", "FB65", "FC65"), top):
                T[tag] = dect[65][k] + X["h_frame"]
                out[tag] = (k & 0xFF, 8, *fd(T[tag] * 8))
            T["WL16"] = sum(x + hs for x in dect[65][:16])
            T["AUD1"] = aud + h["audrep"]
            T["LOOP"] = sum(x + aud + h["stub"] + X["glue"][key] for x in dect[65][:16])
            out["WL16"], out["AUD1"] = (16, 1, *fd(T["WL16"])), (0, 64, *fd(T["AUD1"] * 64))
            out["PACE"] = (0, 1024, *fd((X["pace"] + h["pace"]) * 1024))
            out["LOOP"] = (16, 1, *fd(T["LOOP"]))
            out["A065"] = (m, 1, *fd(T["W065"] / af["W065"]))
            for u, a in (("FA65", "XA65"), ("FB65", "XB65"), ("FC65", "XC65")):
                out[a] = (out[u][0], 8, *fd(T[u] / af[u] * 8))
            out["AW16"] = (16, 1, *fd(T["WL16"] / af["WL16"]))
            out["AAUD"] = (0, 64, *fd(T["AUD1"] / af["AUD1"] * 64))
            out["ALOP"] = (16, 1, *fd(T["LOOP"] / af["LOOP"]))
            if key == "streaming":
                out["REMN"] = (0, X["remn"] & 0xFFFF, X["remn"] >> 16, 0)
                out["PROD"] = (0, 128, *fd((X["prod"][clip] + h["pace"]) * 128))
                out["APRD"] = (0, 128, *fd((X["prod"][clip] + h["pace"]) / af["PROD"] * 128))
        else:
            tpb, colt, ft = X["direct"]
            apad = -(-hdr["audio_bytes_per_frame"] // 512) * 512
            armed_t = [(apad + -(-length // 512) * 512) * tpb + (320 if surface[2] else 0) * colt + ft
                       for *_x, length in dec._iter_frames(buf, hdr)]
            _read, swept, _blocks = bench.direct_frames("DS1")
            out["DSWP"] = (16, 1, *fd(sum(armed_t[i] * af["DSWP"] for i in swept[0])))
            out["ADSW"] = (16, 1, *fd(sum(armed_t[i] for i in swept[1])))
            for tag in ("DTI0", "DTB0", "DTC0", "DTD0"):
                out[tag] = (0, 128, *fd(X["dt"][tag] * 128))
            out["ADTI"] = (0, 128, *fd(X["dt"]["DTI0"] / af["DTI0"] * 128))
            out["ADTC"] = (0, 128, *fd(X["dt"]["DTC0"] / af["DTC0"] * 128))
        return [(t, *out[t]) for t in bench.session_printed(table, deliv)]

    verbs = {mode: verb for verb, mode in blog.STANDALONE_VERBS.items()}
    verbs.update({name: verb for verb, name in blog.SESSION_VERBS.items()})
    order = ([("std", m) for m in (3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12)] + [("sess", k) for k in _GAP_SESSIONS]
             + [("std", m) for m in (6, 8, 9, 10, 11, 12)]
             + [("sess", ("SYN", 1)), ("sess", ("REAL", 3)), ("std", 3)])
    runs, first, stamp = [], {}, 0x0100
    for i, (kind, key) in enumerate(order):
        if key in first:
            rows = [(t, o, r, *divmod(f * 311 + d + (0 if t in ("IDEN", "RING", "REMN", "CALL", "CALR")
                                                     else rng.choice((-1, 0, 1))), 311))
                    for t, o, r, f, d in first[key]]
        else:
            rows = first[key] = standalone(key) if kind == "std" else session(*key)
        runs.append({"stamp": stamp, "verb": verbs[key if kind == "std" else key[0]],
                     "clip": None if kind == "std" else key[1], "rows": rows,
                     "log": "LOG OK" if i else None, "err": None if kind == "std" else 0})
        stamp += 0x0321
    d_rows = []
    for tag in bench.printed_tags(3):
        o, r, f, d = bench.SITTING4[tag]
        d_rows.append((tag, o, r, *divmod(f * 311 + d + rng.choice((-1, 0, 1)), 311)))
    return runs, d_rows


def _gap_text(runs, d_rows):
    """The Q and D bench logs for _gap_runs output."""
    out = []
    for run in runs:
        scr = {0: {0: f"> {run['verb'].lower()}"}}
        if run["clip"] is not None:
            scr = {0: {0: f"> pick {run['clip']}"}, 1: {0: f"Clip {run['clip']} armed."},
                   2: {0: f"> {run['verb'].lower()}"},
                   24: {0: f" FRM=0010/0010 ERR={run['err']:02X} OP=00 POS=000000 PASS=01"}}
        for i, grp in enumerate(run["rows"]):
            if run["clip"] is None:
                scr[8 + i] = {0: _bench_group(*grp)}
            else:
                scr.setdefault(8 + i % 16, {})[40 if i >= 16 else 0] = _bench_group(*grp)
        if run["log"]:
            scr[31] = {0: run["log"]}
        out.append(_bench_capture(run["stamp"], _bench_screen(scr)))
    d_scr = {0: {0: "> nxbc"}, **{8 + i: {0: _bench_group(*grp)} for i, grp in enumerate(d_rows)}}
    return "".join(out), _bench_capture(0x0200, _bench_screen(d_scr))


def _gap_expect(runs, v, X):
    """Each S1-S16 output recomputed from the generated rows and the ruled upstream
    values, by hand. -> {name: value} plus the branch facts the sitting must bind."""
    import math
    first, std = {}, {}
    for run in runs:
        rows = {t: (o, r, f, d) for t, o, r, f, d in run["rows"]}
        if run["clip"] is None:
            for t, row in rows.items():
                std.setdefault(t, row)
        else:
            first.setdefault((run["verb"], run["clip"]), rows)
    verb = {"REAL": "NXBR", "SYN": "NXBQ", "SYS": "NXBY", "DS1": "NXBD"}

    def top(tag):
        o, r, f, d = std[tag]
        return (f * 311 + d) * 1824.0 / (r * o)

    def tr(table, clip, tag):
        _o, r, f, d = first[(verb[table], clip)][tag]
        return (f * 311 + d) * 1824.0 / r

    h, e, facts = X["h"], {}, {}

    def ops(tag):
        return bench._row(tag)[3]
    # S1: the harness from each same-L pair's difference (O 255 against 15), the pair
    # weighted by 1 / (sum of both rows' squared line), then every row less h / O
    k = 1.0 / 15 - 1.0 / 255
    pairs = [(top(b) - top(a), sum((1824.0 / (std[t][1] * std[t][0])) ** 2 for t in (a, b)))
             for a, b in (("SK00", "NS16"), ("C016", "NC16"))]
    hrep = sum(dt * k / var for dt, var in pairs) / sum(k * k / var for _dt, var in pairs)
    facts["S1 nxb_rep_t"] = hrep

    def free(tag):
        return top(tag) - hrep / ops(tag)

    def blocks(L):
        return -(-L // 16)
    # the fast rows: one kernel call per op of L bytes, (L + 15) >> 4 blocks/passes; each row weighted
    # by 1 / its line, solved by lstsq on the scaled system
    for terms, tags in ((("t_op_run", "fill_cpu", "fill_cpu_pass_t"),
                         ("RU01", "RU17", "F063", "F070", "NR16", "FC56", "FC60", "FC64", "FC68", "FC72", "FC76")),
                        (("t_op_copy", "fetch_short", "fetch_long", "copy_ldi_pass_t"),
                         ("C001", "C004", "C008", "C016", "C038", "NC16", "L048", "L056", "L060", "L064", "L072",
                          "L080"))):
        Ls = [bench._row(t)[2] for t in tags]
        if len(terms) == 3:
            A = np.array([[1.0, L, blocks(L)] for L in Ls])
        else:
            A = np.array([[1.0, L if L < 64 else 0.0, L if L >= 64 else 0.0, blocks(L)] for L in Ls])
        wt = np.array([std[t][1] * std[t][0] / 1824.0 for t in tags])
        y = np.array([free(t) for t in tags])
        x = np.linalg.lstsq(A * wt[:, None], y * wt, rcond=None)[0]
        lift = max(0.0, max(y - A @ x - np.maximum(5.5, 1.0 / wt)))
        e.update(zip(terms, x))
        e[terms[0]] += lift
    longs = [(free(t) - e["t_op_copy"] - e["copy_ldi_pass_t"] * blocks(bench._row(t)[2])) / bench._row(t)[2]
             for t in ("L064", "L072", "L080")]
    e["fetch_long"] = max(longs)
    facts["fetch_long spread"] = max(longs) - min(longs)
    e["t_skip"], e["t_skip16"] = free("SK00"), free("S160")
    e["copy_dma_per_b"] = (free("C103") - free("C081")) / 22.0
    e["fill_dma_per_b"] = (free("P200") - free("P071")) / 129.0
    # S2 (the 250 B first chunk's cap arm is 18 T), at S1's harness
    # and the 10 B chunk's one kernel block / pass
    e["s2_ldi8"] = free("C250") - free("C240") - 10 * v["fetch_long"] - v["copy_ldi_pass_t"] - 18
    e["s2_cpu8"] = free("R250") - free("R240") - 10 * v["fill_cpu"] - v["fill_cpu_pass_t"] - 18
    # S3
    synth = [("SYN", c) for c in (1, 2, 3, 4)] + [("SYS", 7)]
    for term, tag in (("frame_delta_t", "FE00"), ("frame_middle_t", "FE01"), ("frame_first_t", "KS02"),
                      ("frame_single_t", "KS01"), ("frame_last_t", "KF01")):
        e[term] = max(tr(t, c, tag) - tr(t, c, "NUL0") for t, c in synth)
    e["t_palette"] = max(tr("SYN", c, "PAL1") - tr("SYN", c, "FE00") for c in (1, 2, 3, 4))
    e["pal_straddle_t"] = max(tr("SYN", c, "PAL2") - tr("SYN", c, "PAL1") for c in (1, 2, 3, 4))
    for name, deliv, clips in (("glue_t", "resident", (1, 2, 3, 4, 5)), ("glue_strm_t", "streaming", (7, 8, 9))):
        e[name] = max((tr("REAL", c, "LOOP") - tr("REAL", c, "WL16") - 16 * tr("REAL", c, "AUD1")) / 16
                      + tr("REAL", c, "PACE") - h["pace"] - h["stub"] + h["audrep"] + h["skip"][deliv]
                      for c in clips)
    # S5
    ratios = []
    for table, clips in (("REAL", (1, 2, 3, 4, 5, 7, 8, 9)), ("SYN", (1, 2, 3, 4)), ("SYS", (7,)),
                         ("DS1", (10, 12, 13, 14))):
        for c in clips:
            for u, a in bench.SESSION_ARMED_PAIRS[table]:
                if u in first[(verb[table], c)]:
                    ratios.append(tr(table, c, u) / tr(table, c, a))
    e["audio_factor"] = math.floor(100.0 * min(ratios)) / 100.0
    af = v["audio_factor"]
    # S6 crossovers and the silicon choice of N
    def cross(ldi, dma):
        b, a = np.polyfit([bench._row(t)[2] for t in ldi], [top(t) for t in ldi], 1)
        s, c = np.polyfit([bench._row(t)[2] for t in dma], [top(t) for t in dma], 1)
        return (c - a) / (b - s)
    e["crossovers"] = {
        "flat": cross([f"L0{L}" for L in (48, 56, 60, 64, 72, 80)], [f"D0{L}" for L in (48, 56, 60, 64, 72, 80, 81)]),
        "g192": cross([f"GL{L}" for L in (56, 60, 72, 80)], [f"GD{L}" for L in (56, 60, 72, 80)]),
        "g144": cross([f"HL{L}" for L in (56, 60, 64, 68, 76, 80, 88, 96)],
                      [f"HD{L}" for L in (56, 60, 64, 68, 76, 80, 88, 96)])}
    S = {t: sum(tr("REAL", c, f"W0{t:02d}") for c in (1, 2, 3, 4, 5, 7, 8, 9)) for t in _GAP_GRID}
    tstar = min(_GAP_GRID, key=lambda t: (S[t], -t))
    near = min(_GAP_GRID, key=lambda t: (abs(t - v["N_m"]), -t))
    e["N"] = v["N_m"] if S[near] <= S[tstar] * 1.0005 else tstar
    facts["S6 near/t* ratio"] = S[near] / S[tstar]
    # the per-byte LDI rate carries its block cost on average
    e["gap"] = e["N"] - (v["copy_dma_setup"] + v["copy_dma_path_t"]) / (
        v["fetch_short"] + v["copy_ldi_pass_t"] / 16.0 - v["copy_dma_per_b"])
    e["saving_pct"] = 100.0 * (S[81] - S[min(_GAP_GRID, key=lambda t: (abs(t - e["N"]), -t))]) / S[81]
    run_l = (56, 60, 64, 68, 72, 76)
    e["run_crossovers"] = [cross([f"FC{L}" for L in run_l], [f"FD{L}" for L in run_l]),
                           cross([f"VC{L}" for L in (60, 68, 76)], [f"VD{L}" for L in (60, 68, 76)])]

    # S8, S9 with the ruled terms through this file's own map
    def model(clip, strm):
        _hdr, surface, frames = _gap_frames(clip, 65, 71)
        return [v[f"frame_{ft}_t"] + _gap_cost(ev, surface, strm, lb, rm, v, v["split"]) for ft, ev, lb, rm in frames]
    period = 1000.0 / 25.0 * 28000.0
    r_frame, aaud, raw = {"flat": [], "gapped": []}, {"flat": [], "gapped": []}, {}
    for c in (1, 2, 3, 4, 5, 7, 8, 9):
        strm = X["delivery"][c] == "streaming"
        hdr, surface, _f = _gap_frames(c, 65, 71)
        cls = "gapped" if surface[2] else "flat"
        mt = model(c, strm)
        for u in ("XA65", "XB65", "XC65"):
            r_frame[cls].append(tr("REAL", c, u) / (mt[first[("NXBR", c)][u][0]] / af))
        aaud[cls].append(tr("REAL", c, "AAUD"))
        m = first[("NXBR", c)]["A065"][0]
        raw.setdefault((cls, hdr["width"]), []).append((c, sum(mt[:m]), m, strm, tr("REAL", c, "A065")))
    factors = {}
    for cls in ("flat", "gapped"):
        rmax = max(r_frame[cls])
        a, b = 1.12 * rmax, rmax * period / (period - max(aaud[cls]))
        factors[cls] = math.ceil(round(100.0 * max(a, b), 6)) / 100.0
        facts[f"S8 {cls} audio branch over 1.12"] = b > a
    e["composition_factor"] = factors
    anchors = {}
    for (cls, width), pts in raw.items():
        key = "gapped" if cls == "gapped" else f"flat_{width}"
        for c, total, m, strm, t_a065 in pts:
            usable = (period * af - v["glue_strm_t" if strm else "glue_t"]) / v["composition_factor"][cls]
            anchors.setdefault(key, []).append((total / m / usable, t_a065 / (total / af)))
    e["silicon_r"] = {}
    for key, pts in anchors.items():
        merged = []
        for d, r in sorted(pts):
            if merged and d - merged[-1][0] <= 0.02:
                merged[-1] = (max(d, merged[-1][0]), max(r, merged[-1][1]))
            else:
                merged.append((d, r))
        e["silicon_r"][key] = tuple((round(float(d), 3), math.ceil(round(float(r) * 1000, 6)) / 1000)
                                    for d, r in merged)
    # S10, S11
    e["AUDIO_COPY_T_PER_B"] = math.ceil(round(10.0 * max(tr("REAL", c, "AAUD") for c in (1, 2, 3, 4, 5, 7, 8, 9))
                                              / 1536, 6)) / 10.0
    e["SD_WIRE_BYTES_PER_MS"] = float(math.floor(min(
        512.0 * 28000.0 / (tr("REAL", c, "PROD") + tr("REAL", c, "PACE") - h["pace"] + h["spin"]) for c in (7, 8, 9))))

    # S12, S16
    def silicon_r(key, density):
        pts = sorted(v["silicon_r"][key])
        if density <= pts[0][0]:
            return pts[0][1]
        for (d0, r0), (d1, r1) in zip(pts, pts[1:]):
            if density <= d1:
                return r0 + (r1 - r0) * (density - d0) / (d1 - d0)
        return pts[-1][1]
    e["supply_exchange"] = {f"{w}x{hh}": 28000.0 / (v["SD_WIRE_BYTES_PER_MS"] * silicon_r(key, 1.0))
                            for (w, hh), key in (((320, 256), "flat_320"), ((256, 192), "flat_256"),
                                                 ((320, 192), "gapped"), ((320, 144), "gapped"))}
    pts = [(bench._row(t)[2], top(t) - v["nxb_rep_t"] / ops(t) - v["copy_ldi_pass_t"] * blocks(bench._row(t)[2]))
           for t in ("C001", "C004", "C008", "C016", "C038", "L048", "L056", "L060", "L064", "L072", "L080")]

    def worst(p):
        b, a = np.polyfit([x for x, _y in p], [y for _x, y in p], 1)
        return max(abs(y - a - b * x) for x, y in p)
    splits = [(max(worst([p for p in pts if p[0] < s]), worst([p for p in pts if p[0] >= s])), s)
              for s in range(16, 81)
              if len({x for x, _y in pts if x < s}) >= 2 and len({x for x, _y in pts if x >= s}) >= 2]
    best = min(splits, key=lambda p: (p[0], p[1]))
    e["fetch_selector"] = best[1] if worst(pts) - best[0] > 5.5 else None
    facts["S12 one line"] = (worst(pts), np.polyfit([x for x, _y in pts], [y for _x, y in pts], 1)[0])
    lam = e["supply_exchange"]["320x256"]

    def fillmin(k, passes=1):
        # the RUN op's fill passes against the LDI blocks of the L bytes it replaces
        return next((L for L in range(1, 256)
                     if v["t_op_run"] + L * v["fill_cpu"] + passes * blocks(L) * v["fill_cpu_pass_t"] + k * lam
                     + v["t_op_copy"] <= L * v["fetch_short"] + passes * blocks(L) * v["copy_ldi_pass_t"] + L * lam),
                    None)
    e["FILLMIN"] = fillmin(5)
    facts["FILLMIN moves with a lam"] = fillmin(4) != fillmin(5)
    facts["FILLMIN moves with the pass terms"] = fillmin(5, passes=0) != fillmin(5)
    e["STREAM_RESIDENT_POOL_B"] = min(min(first[(verb[t], c)]["RING"][3] for t, c in
                                          [("REAL", c) for c in (1, 2, 3, 4, 5)] + [("SYN", c) for c in (1, 2, 3, 4)])
                                      + 1 - 1 - 5, 78) * 16384
    # S15
    rows = []
    _read, swept, _blocks = bench.direct_frames("DS1")
    for c in (10, 12, 13, 14):
        buf = _gap_fixture(c).read_bytes()
        hdr = enc.unpack_header(buf)
        lengths = [length for *_x, length in dec._iter_frames(buf, hdr)]
        apad = -(-hdr["audio_bytes_per_frame"] // 512) * 512
        rows.append((apad + -(-lengths[swept[1][0]] // 512) * 512, 320 if enc.is_gapped(hdr["width"], hdr["height"])
                     else 0, tr("DS1", c, "ADSW") / first[("NXBD", c)]["ADSW"][0]))
    A = np.array([[b, cols, 1.0] for b, cols, _t in rows])
    y = np.array([t for *_x, t in rows])
    x = np.linalg.lstsq(A, y, rcond=None)[0]
    lift = max(0.0, max(t - (b * x[0] + cols * x[1] + x[2]) - 0.005 * t for b, cols, t in rows))
    e["DIRECT_T_PER_B"], e["DIRECT_COL_T"], e["DIRECT_FRAME_T"] = x[0], x[1], x[2] + lift
    return e, facts


@case(10, "sitting-5 rules - a synthetic sitting recovers its hidden terms, every rule's arithmetic, S0 STOPs")
def t10_gap_rules():
    import copy
    import io
    import math
    import fit_gap_bench as g
    import nxv2_frame_model as fm
    missing = [c for c in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14) if _gap_fixture(c) is None]
    if missing:
        skip(f"fixtures {missing} are not encoded at this era (build-tests.ps1 -Vid -VidLong)")
    events = set(bench.row_events("C001").as_dict(nonzero=False))
    expect(set(_GAP_MAP) | _GAP_ZERO | _GAP_TAILS == events, "the test's own map covers every Events counter")
    hidden = _gap_hidden()
    H, res, strm, X = hidden
    expect((g.H_PACE, g.H_STUB, g.H_AUDREP, g.H_SPIN, g.H_SKIP)
           == (X["h"]["pace"], X["h"]["stub"], X["h"]["audrep"], X["h"]["spin"], X["h"]["skip"]),
           "the rules script's harness constants are the Task 12 hand counts")
    runs, d_rows = _gap_runs(hidden, seed=17)
    q_text, d_text = _gap_text(runs, d_rows)
    notes = {("Q", runs[-1]["stamp"]): "OK", ("D", 0x0200): "OK"}
    printed = []
    v, sit = g.apply_rules(q_text, d_text, out=printed, launch_status=notes)

    # every rule's arithmetic, recomputed from the generated rows
    e, facts = _gap_expect(runs, v, X)
    expect(facts["fetch_long spread"] > 0.1 and not facts["S8 flat audio branch over 1.12"]
           and facts["S8 gapped audio branch over 1.12"] and facts["FILLMIN moves with a lam"]
           and facts["FILLMIN moves with the pass terms"]
           and 1.0005 < facts["S6 near/t* ratio"] <= 1.05 and v["N"] != v["N_m"]
           and e["STREAM_RESIDENT_POOL_B"] < 78 * 16384 and v["copy_dma_rem_t"] > 0,
           f"the sitting must bind every branch: {facts}, N {v['N']} N_m {v['N_m']}, rem {v['copy_dma_rem_t']}")
    bad = []
    for name, want in e.items():
        got = v[name]
        if isinstance(want, dict):
            same = got.keys() == want.keys() and all(
                (got[k] == want[k]) if isinstance(want[k], tuple) else math.isclose(got[k], want[k], rel_tol=1e-9)
                for k in want)
        elif isinstance(want, list):
            same = all(math.isclose(a, b, rel_tol=1e-9) for a, b in zip(got, want))
        elif want is None or isinstance(want, int) and not isinstance(want, bool):
            same = got == want
        else:
            same = math.isclose(got, want, rel_tol=1e-9, abs_tol=1e-9)
        if not same:
            bad.append(f"{name}: rules {got}, by hand {want}")
    expect(not bad, "rulings differ from the hand arithmetic:\n  " + "\n  ".join(bad))

    # the bench harness: S1's twin estimate as printed, S4's joint value ruled beside its hand count, never exported
    said = [line.split() for line in printed if line.startswith("S1 harness estimate: nxb_rep_t ")]
    expect(len(said) == 1 and abs(float(said[0][4]) - facts["S1 nxb_rep_t"]) <= 0.05,
           f"S1 harness estimate {said}, by hand {facts['S1 nxb_rep_t']:.2f}")
    said = [line for line in printed if line.startswith("Ruling: nxb_rep_t ")]
    expect(len(said) == 1 and g.HARNESS_HAND[1] in said[0]
           and said[0].endswith(" - bench harness only, never exported to the encoder"),
           f"one nxb_rep_t ruling with its hand count: {said}")
    expect("nxb_rep_t" not in g.ruled_coefficients(v) and "nxb_rep_t" in v["s4_terms"],
           "nxb_rep_t is fitted in S4 and never exported")
    # the kernel pass terms: S1 rulings beside their instruction counts, exported, held by S4
    for t in ("copy_ldi_pass_t", "fill_cpu_pass_t"):
        said = [line for line in printed if line.startswith(f"Ruling: {t} ")]
        expect(len(said) == 1 and g.KERNEL_HAND[t] in said[0] and t in g.ruled_coefficients(v)
               and t not in v["s4_terms"], f"{t}: one S1 ruling with its instruction count, exported: {said}")
    # S12 on rows less the harness and the blocks: one line, no selector
    one_w, one_b = facts["S12 one line"]
    said = [line for line in printed if line.startswith("Ruling: one fetch_long rate")]
    expect(v["fetch_selector"] is None and len(said) == 1
           and f"one line worst residual {one_w:.2f} T (slope {one_b:.4f})" in said[0],
           f"S12's one line on harness- and block-free rows, by hand {one_w:.2f} T slope {one_b:.4f}: {said}")

    # the band is max(5.5 T, one line of the row), in S1's lift too
    expect(g.op_band((5, 64, 0, 0)) == 1824.0 / 320 and g.op_band((255, 64, 0, 0)) == 5.5, "op_band")
    run_tags = ("RU01", "RU17", "F063", "F070", "NR16", "FC56", "FC60", "FC64", "FC68", "FC72", "FC76")
    Ls = [bench._row(t)[2] for t in run_tags]
    design = np.array([[1.0, L, -(-L // 16)] for L in Ls])
    hr = facts["S1 nxb_rep_t"]
    for resid, want_lift in ((6.5, 0.0), (8.0, 8.0 - 1824.0 / 255)):
        rows = dict(sit.rows)
        rows["RU17"] = (255, 1, 0, 0.0)                    # R = 1: one line is 7.15 T, and its weight
        wt = np.array([rows[t][1] * rows[t][0] / 1824.0 for t in run_tags])
        hat = design @ np.linalg.pinv(design * wt[:, None]) * wt[None, :]
        ys = np.array([g.t_op(sit.rows[t]) - hr / bench._row(t)[3] for t in run_tags])
        t17 = ys[1] + (resid - (ys - hat @ ys)[1]) / (1 - hat[1, 1])
        rows["RU17"] = (255, 1, 0, (t17 + hr / 255) * 255 / 1824.0)
        lift = g.s1(g.Sitting(rows, {}), {})[0]["raises"].get("t_op_run", 0.0)
        expect(math.isclose(lift, want_lift, abs_tol=1e-6), f"S1 lift at residual {resid} on a 7.15 T row: {lift}")

    # the script prices high-height and cap-arm events as this file's map does
    import nxv2_path_sim as ps
    vals = dict(H, **res)
    vals.update({t: 1000.0 + 37.0 * i for i, t in enumerate(("gap_chunk_t", "gap_chunk_hi_t", "cap_arm_t"))})
    for ops, surf, dst in (([(0x14, 300), (0x00, 0)], (320, 250, True), (0, 0x4005)),
                           ([(0x08, 250), (0x00, 0)], (320, 250, True), (0, 0x4000)),
                           ([(0x10, 250), (0x00, 0)], (256, 192, False), (0, 0x4000)),
                           ([(0x14, 300), (0x00, 0)], (320, 192, True), (0, 0x4005))):
        ev = ps.events(ops, surf, 0, dst=dst, copy_thr=81, run_thr=71)
        lb = ev.copy_fast_b + ev.copy_ldi_b if ops[0][0] in (0x10, 0x14) and ops[0][1] >= 64 else 0
        mine = _gap_cost(ev, surf, False, lb, 0, vals)
        theirs = g.price(g.term_counts(ev, surf, False, lb, 0), vals)
        expect(math.isclose(mine, theirs), f"{ops[0]} on {surf}: script {theirs}, by hand {mine}")

    # N_m is the modelled optimum against its neighbours (this file's own map)
    def total(n):
        t = 0.0
        for c in range(1, 10):
            _hdr, surface, frames = _gap_frames(c, n, 71)
            strm = X["delivery"][c] == "streaming"
            t += sum(v[f"frame_{ft}_t"] + _gap_cost(ev, surface, strm, lb, rm, v, v["split"])
                     for ft, ev, lb, rm in frames)
        return t
    lo, hi = math.floor(min(e["crossovers"].values())), math.ceil(max(e["crossovers"].values()))
    near = {n: total(n) for n in (v["N_m"] - 1, v["N_m"], v["N_m"] + 1) if lo <= n <= hi}
    expect(all(near[v["N_m"]] < t for n, t in near.items() if n > v["N_m"])
           and all(near[v["N_m"]] <= t for t in near.values()), f"N_m {v['N_m']} is not the optimum: {near}")
    expect(v["M"] == 71 and not v["copy_split"] and not v["raises"]["S14"],
           f"M {v['M']}, split {v['copy_split']}, S14 raises {v['raises']['S14']}")

    # hidden terms: within max(2 T, 2%) under, that plus the rule's largest raise over; a term the
    # rows cannot resolve that finely is held to its +-1 line bound instead
    want = {**H, **strm, "pal_straddle_t": H["pal_straddle_t"] + H["src_parity_seam_t"], "nxb_rep_t": X["h_rep"],
            "glue_t": X["glue"]["resident"] + X["pace"], "glue_strm_t": X["glue"]["streaming"] + X["pace"],
            "DIRECT_T_PER_B": X["direct"][0], "DIRECT_COL_T": X["direct"][1], "DIRECT_FRAME_T": X["direct"][2]}
    rule_of = {**{t: "S1" for t in ("fetch_short", "fetch_long", "t_skip", "t_skip16", "t_op_run", "t_op_copy",
                                   "fill_cpu", "copy_dma_per_b", "fill_dma_per_b", "copy_ldi_pass_t",
                                   "fill_cpu_pass_t")},
               **{t: "S3" for t in res}, "t_palette": "S3", "pal_straddle_t": "S3", "glue_t": "S3",
               "glue_strm_t": "S3", "DIRECT_T_PER_B": "S15", "DIRECT_COL_T": "S15", "DIRECT_FRAME_T": "S15"}
    bad, by_bound = [], []
    for term, hid in sorted(want.items()):
        rule = rule_of.get(term, "S4")
        lift = max([0.0] + list(v["raises"][rule].values())
                   + (list(v["raises"]["S14"].values()) if rule == "S4" else []))
        band = max(2.0, 0.02 * abs(hid))
        if v["bounds"].get(term, 0.0) > band:
            band = v["bounds"][term]
            by_bound.append(f"{term} {band:.2f}")
        if not hid - band <= v[term] <= hid + band + lift:
            bad.append(f"{term}: {v[term]:.2f}, hidden {hid:.2f}, band {band:.2f} + raise {lift:.2f}")
    print("    note: held to their +-1 line bound: " + (", ".join(by_bound) or "none"))
    expect(not bad, f"{len(want)} terms, outside:\n  " + "\n  ".join(bad))
    expect(v["audio_factor"] == 0.86 and v["STREAM_RESIDENT_POOL_B"] == 75 * 16384
           and abs(v["SD_WIRE_BYTES_PER_MS"] - 512 * 28000 / (X["prod"][9] + 104 + X["pace"] + 161)) <= 3,
           f"audio_factor {v['audio_factor']}, pool {v['STREAM_RESIDENT_POOL_B']}, wire {v['SD_WIRE_BYTES_PER_MS']}")
    expect(not v["split"] and set(v["hand"]) >= {"slow_fetch_t", "slow_cmp_t", "src_wrap_t", "gap_chunk_hi_t"},
           f"split {v['split']}, hand counts {sorted(v['hand'])}")
    countable = ("gap_fast_t", "gap_bail_skip_t", "gap_bail_t", "slow_fetch_t", "slow_cmp_t", "srcedge_t", "src_edge_t",
                 "src_wrap_t", "dst_exact_t", "src_exact_t", "gap_chunk_t", "gap_chunk_hi_t", "cap_arm_t")
    loose = [t for t in countable if t not in v["hand"] and v["bounds"][t] > max(2.0, 0.02 * abs(v[t]))]
    expect(not loose, f"fitted where a hand count exists and +-1 line moves them past their band: {loose}")
    for t in v["hand"]:
        said = [line for line in printed if line.startswith(f"Ruling: {t} ")]
        expect(len(said) == 1 and "HAND COUNT" in said[0] and g.HAND[t][1] in said[0],
               f"{t}: one HAND COUNT ruling with its instruction list, got {said}")
    at = printed.index("counter-to-term map:") + 1
    block = printed[at:next(i for i in range(at, len(printed)) if not printed[i].startswith("  "))]
    expect(sum(line.split()[0] in g.COUNTER_TERMS for line in block) == len(g.COUNTER_TERMS),
           "the counter-to-term map prints every counter")

    # HK56's per-op breakdown before and after the raises: every counter with its priced terms,
    # summing to the model the residual tables print
    for when, values in (("fit 1 before the raises", None), ("after the raises", v)):
        at = printed.index(next(line for line in printed if line.startswith(f"HK56 per op, {when} ")))
        block = printed[at + 1:next(i for i in range(at + 1, len(printed)) if not printed[i].startswith("  "))]
        counters = [line.split()[0] for line in block[:-1] if not line.split()[0].startswith("(")]
        expect(counters == list(bench.row_events("HK56").as_dict()) and block[-1].startswith("  model "),
               f"HK56 breakdown {when}: {block}")
        if values is not None:
            model = sum(c * v[t] for t, c in g.standalone_counts("HK56", v["split"]).items())
            expect(f"model {model:.1f} T" in block[-1], f"HK56 breakdown after the raises sums to {model:.1f}: {block[-1]}")

    # after the raises no S4 row or tail prices under max(5.5 T, one line) or 0.5%, by this file's map
    under = []
    first_std = {}
    for run in runs:
        if run["clip"] is None:
            for t, o, r, f, d in run["rows"]:
                first_std.setdefault(t, (o, r, f, d))
    for mode in (2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12):
        for tag, kind, L, o, r, _thr, _geo in bench.BENCH_TABLES[mode]:
            if kind == "cal" or (mode == 9 and tag not in ("C240", "C250", "Q240", "R240", "R250", "W240")) or (
                    mode == 8 and tag not in ("T298", "T299", "T300", "T320")):
                continue
            ev = bench.row_events(tag)
            long_b = ev.copy_fast_b + ev.copy_ldi_b if L >= 64 else 0
            rem = o if kind.startswith("copy") and L >= 240 and L % 240 >= bench.row_selects(tag)[0] else 0
            _o, _r, f, d = first_std[tag]
            meas = (f * 311 + d) * 1824.0 / (r * o)
            model = (_gap_cost(ev, bench.row_surface(tag), False, long_b, rem, v, v["split"]) + v["nxb_rep_t"]) / o
            if meas - model > max(5.5, 1824.0 / (r * o)) + 1e-6:
                under.append(f"{tag} {meas - model:+.1f}")
    expect(not under, f"rows priced under after the raises: {under}")

    # decision reuse gives the simulator's own events at a moved select
    path = g.fixture_path(9)
    _h, _s, reused = g.fixture_frames(path, 60, 66)
    direct = fm.frames(path, copy_thr=60, run_thr=66)
    expect([f.ev for f in reused] == [f.events for f in direct], "fixture 009 events at 60/66 differ from fm.frames")

    # S0 STOPs, each on one broken input with no later clean capture of its verb
    def s0_fails(mut_runs=None, mut_d=None, want="", anchor=True, launch=None, lost=None):
        r2, d2 = copy.deepcopy(runs), list(d_rows)
        if mut_runs:
            mut_runs(r2)
        if mut_d:
            d2 = mut_d(d2)
        q2, dt2 = _gap_text(r2, d2)
        try:
            g.s0(q2, dt2 if anchor else None, launch_status=notes if launch is None else launch, lost=lost)
        except g.Stop as stop:
            text = "; ".join(stop.lines)
            expect(stop.rule == "S0" and all(w in text for w in (want if isinstance(want, tuple) else (want,))),
                   f"S0 STOP without {want!r}: {text}")
            return
        raise AssertionError(f"no S0 STOP for {want!r}")

    def shift(rows, tag, lines):
        return [(t, o, r, *divmod(f * 311 + d + (lines if t == tag else 0), 311)) for t, o, r, f, d in rows]

    c004 = ("C004", *bench.SITTING4["C004"][:2],
            *divmod(bench.SITTING4["C004"][2] * 311 + bench.SITTING4["C004"][3] + 2, 311))
    s0_fails(mut_d=lambda rows: [c004 if grp[0] == "C004" else grp for grp in rows], want="D-image NXBC C004: +2 lines")
    nxbe = next(i for i, run in enumerate(runs) if run["verb"] == "NXBE")
    last_e = max(i for i, run in enumerate(runs) if run["verb"] == "NXBE")
    s0_fails(lambda r2: r2[last_e].update(rows=shift(r2[last_e]["rows"], "CALR", 1)),
             want=("CALR", "no later clean capture of NXBE replaces it"))
    real2 = next(i for i, run in enumerate(runs) if run["verb"] == "NXBR" and run["clip"] == 2)
    s0_fails(lambda r2: r2[real2].update(rows=[(t, o, 34 if t == "IDEN" else r, f, d)
                                              for t, o, r, f, d in r2[real2]["rows"]]),
             want="IDEN does not name clip 002")
    s0_fails(lambda r2: r2[last_e + 1].update(log="LOG ERR 60"), want="LOG ERR 60: untrusted")
    s0_fails(want="needs --anchor", anchor=False)
    s0_fails(want=f"--launch-status {runs[-1]['stamp']:04X}=OK", launch={("D", 0x0200): "OK"})
    s0_fails(lambda r2: r2[last_e + 1].update(log=None), want=f"--launch-status {runs[last_e]['stamp']:04X}=OK")
    s0_fails(lambda r2: r2[last_e + 1].update(log=None), want="LOG ERR 60",
             launch={**notes, ("Q", runs[last_e]["stamp"]): "ERR 60"})
    s0_fails(want="names no run", launch={**notes, ("Q", 0x1234): "OK"})
    # a faulted capture with no clean follow-up
    s0_fails(lambda r2: r2[real2].update(err=0xFA),
             want=(f"#NXB {runs[real2]['stamp']:04X} NXBR clip 002: teardown ERR=FA",
                   "no later clean capture of NXBR clip 002 replaces it"))

    # superseded: a faulted NXBR clip 3 (ERR=FA after W065) ahead of its clean capture
    real3 = [i for i, run in enumerate(runs) if run["verb"] == "NXBR" and run["clip"] == 3]

    def faulted_real3(r2):
        bad = copy.deepcopy(r2[real3[0]])
        cut = [t for t, *_x in bad["rows"]].index("W065") + 1
        bad.update(stamp=bad["stamp"] - 0x80, err=0xFA, rows=bad["rows"][:cut])
        r2.insert(real3[0], bad)

    r2 = copy.deepcopy(runs)
    faulted_real3(r2)
    sit2, lines2 = g.s0(*_gap_text(r2, d_rows), launch_status=notes)
    sup = [line for line in lines2 if line.startswith("superseded:")]
    expect(len(sup) == 1 and sup[0].startswith(f"superseded: NXBR clip 003 at #NXB {runs[real3[0]]['stamp'] - 0x80:04X} - ")
           and "teardown ERR=FA" in sup[0] and sup[0].endswith(f"replaced by #NXB {runs[real3[0]]['stamp']:04X}")
           and sit2.sessions[("REAL", 3)].run.stamp == runs[real3[0]]["stamp"], f"one superseded line: {sup}")
    # the deliberate clean repeat of 003 is still compared
    s0_fails(lambda r2: (faulted_real3(r2), r2[real3[1] + 1].update(rows=shift(r2[real3[1] + 1]["rows"], "W065", 5))),
             want=("NXBR clip 003 (repeat) W065: repeat differs by", "(tolerance 2)"))

    # a step-2 LOG ERR lost NXBR clip 5's capture; the owner names it and it is run again
    real5 = next(i for i, run in enumerate(runs) if run["verb"] == "NXBR" and run["clip"] == 5)

    def lose_real5(r2):
        rerun = copy.deepcopy(r2[real5])
        del r2[real5]
        r2[real5]["log"] = "LOG ERR 45"
        rerun.update(stamp=r2[real5]["stamp"] + 0x80, log="LOG OK")
        r2.insert(real5 + 1, rerun)

    after = runs[real5 + 1]["stamp"]
    lost_notes = {**notes, ("Q", runs[real5 - 1]["stamp"]): "OK"}
    r2 = copy.deepcopy(runs)
    lose_real5(r2)
    sit3, lines3 = g.s0(*_gap_text(r2, d_rows), launch_status=lost_notes, lost={("Q", after): ("NXBR", 5)})
    expect(any(line == f"superseded: NXBR clip 005 lost before #NXB {after:04X} - capture lost (ERR 45) - "
                       f"replaced by #NXB {after + 0x80:04X}" for line in lines3)
           and sit3.sessions[("REAL", 5)].run.stamp == after + 0x80, f"lost capture replaced: {lines3}")
    s0_fails(lose_real5, want=f"name the lost verb with --lost {after:04X}=VERB[:clip]", launch=lost_notes)
    s0_fails(lose_real5, want="no later clean capture replaces it", launch=lost_notes,
             lost={("Q", after): ("NXBR", 4)})
    expect(g.lost_key("1400=nxbr:5") == (("Q", 0x1400), ("NXBR", 5)) and g.lost_key("D:0200=NXBC")[1] == ("NXBC", None),
           "--lost notes parse")

    # not STOPs: a relaunch the owner noted OK, a one-field clock slip on a repeat, a SCAN repeat,
    # a streaming fault after REMN
    r2 = copy.deepcopy(runs)
    r2[nxbe + 1]["log"] = None
    nxbg = [i for i, run in enumerate(r2) if run["verb"] == "NXBG"]
    r2[nxbg[1]]["rows"] = shift(r2[nxbg[1]]["rows"], "GL60", 311)
    real3 = [i for i, run in enumerate(r2) if run["verb"] == "NXBR" and run["clip"] == 3]
    r2[real3[1]]["rows"] = shift(r2[real3[1]]["rows"], "SCAN", 50)
    real7 = next(i for i, run in enumerate(r2) if run["verb"] == "NXBR" and run["clip"] == 7)
    r2[real7].update(err=0xFA, rows=[grp for grp in r2[real7]["rows"] if grp[0] not in ("PROD", "APRD")])
    sit2, lines2 = g.s0(*_gap_text(r2, d_rows), launch_status={**notes, ("Q", runs[nxbe]["stamp"]): "OK"})
    expect(sit2.rows["GL60"] == r2[nxbg[1]]["rows"][[t for t, *_x in r2[nxbg[1]]["rows"]].index("GL60")][1:]
           and any("GL60" in line and "clock slip" in line for line in lines2)
           and any("launch note" in line for line in lines2)
           and sit2.sessions[("REAL", 7)].invalid == {"PROD", "APRD"},
           "a noted relaunch, a slip kept the repeat, a SCAN repeat, ERR after REMN")

    # a STOP prints its rule's lines; S4 names the rows priced under before any raise
    r2 = copy.deepcopy(runs)
    r2[last_e + 1]["log"] = "LOG ERR 60"
    try:
        g.apply_rules(*_gap_text(r2, d_rows), out=[], launch_status=notes)
    except g.Stop as stop:
        expect(stop.printed[0] == "== S0 - integrity ==" and len(stop.printed) > 1, f"S0 notes {stop.printed}")
    else:
        raise AssertionError("no S0 STOP on LOG ERR 60")
    r2 = copy.deepcopy(runs)
    for i, run in enumerate(r2):
        if run["verb"] == "NXBV":
            run["rows"] = [(t, o, r, *divmod(int((f * 311 + d) * (1.05 if t == "JC72" else 1)), 311))
                           for t, o, r, f, d in run["rows"]]
    try:
        g.apply_rules(*_gap_text(r2, d_rows), out=[], launch_status=notes)
    except g.Stop as stop:
        expect(stop.rule == "S4" and any(line.startswith("JC72: residual +") and "T before the raises is +" in line
                                         and line.endswith("% of its row: the event model is missing a path")
                                         for line in stop.lines)
               and any(line.startswith("fit 1: residuals before the raises") for line in stop.printed),
               f"S4 STOPs on JC72 before any raise: {stop.lines}")
    else:
        raise AssertionError("no S4 STOP on JC72 +5%")

    # S4 scoring on constructed rows: the 3% test is on the residuals before the raises, a raise
    # that over-prices another row past 3% is a warning, and a gapped row raises the gapped term
    # that over-prices the other rows least
    from collections import Counter

    def s4row(label, counts, T, base, scored=False):
        return g.S4Row(label, Counter(counts), T, 1.0, 5.5, base, scored)
    vals = {"col_hop_t": 30.0, "gap_chunk_t": 16.0, "edge_copy_t": 200.0, "t_op_copy": 300.0}
    # F prices 30 T past its band (1.78% of 2000 T); V carries one hop and is 2 T over before the raise
    F = s4row("F", {"t_op_copy": 1, "col_hop_t": 1}, 330.0 + 5.5 + 30.0, 2000.0, scored=True)
    V = s4row("V", {"t_op_copy": 2.2, "col_hop_t": 1}, 660.0 + 30.0 - 2.0, 700.0)
    lines = []
    g._s4_score_pre([F, V], dict(vals), "pre", lines)
    post, raises = dict(vals), {}
    g._s4_raise([F, V], post, {"col_hop_t"}, raises, lines)
    warned = g._s4_score_post([F, V], post, lines)
    expect(raises == {"col_hop_t": 30.0} and [r.label for r, _dt, _pct in warned] == ["V"]
           and "warning: V is priced over by 32.0 T after the raises, 4.57% of its row (over 3%, the safe direction)"
           in lines, f"a raise past 3% on another row warns: {raises} {lines[-2:]}")
    try:
        g._s4_score_pre([F, s4row("W", {"t_op_copy": 1}, 300.0 + 12.1, 300.0)], dict(vals), "pre", [])
    except g.Stop as stop:
        expect(stop.lines == ["W: residual +12.1 T before the raises is +4.03% of its row: the event model is "
                              "missing a path"], f"pre-raise STOP: {stop.lines}")
    else:
        raise AssertionError("no STOP on a 4% residual before the raises")
    # G carries two hops, one gapped chunk and an edge (spill 0): H carries 5 hops of 500 T, K one chunk of
    # 2000 T. A hop raise of 10 T over-prices H 10%, a chunk raise of 20 T over-prices K 1%: gap_chunk_t
    G = s4row("G", {"t_op_copy": 1, "col_hop_t": 2, "gap_chunk_t": 1, "edge_copy_t": 1},
              300.0 + 60.0 + 16.0 + 200.0 + 5.5 + 20.0, 1000.0, scored=True)
    H = s4row("H", {"t_op_copy": 1, "col_hop_t": 5}, 300.0 + 150.0, 500.0)
    K = s4row("K", {"t_op_copy": 1, "gap_chunk_t": 1}, 300.0 + 16.0, 2000.0)
    lines, post, raises = [], dict(vals), {}
    g._s4_raise([G, H, K], post, {"col_hop_t", "gap_chunk_t", "edge_copy_t"}, raises, lines)
    expect(raises == {"gap_chunk_t": 20.0} and lines == [
        "raise step: G prices 20.00 T under its 5.5 T band -> gap_chunk_t +20.00 T (the gapped term it carries "
        "over-pricing the other rows least: at most 1.000% of a row; col_hop_t 10.000%)"],
           f"the gapped raise takes the least-damage gapped term: {raises} {lines}")
    lines, post, raises = [], dict(vals), {}
    g._s4_raise([g.S4Row("G", G.counts, G.T, 1.0, 5.5, 1000.0, False), H, K], post,
                {"col_hop_t", "gap_chunk_t", "edge_copy_t"}, raises, lines)
    expect(raises == {"edge_copy_t": 20.0}, f"an unscored row takes any fitted term: {raises} {lines}")
    # a harness 114 T over the generator's (R / 16 lines on every standalone row) STOPs S1, naming both values
    r2 = copy.deepcopy(runs)
    for run in r2:
        if run["clip"] is None:
            run["rows"] = [(t, o, r, *divmod(f * 311 + d + (0 if t in ("CALL", "CALR") else r // 16), 311))
                           for t, o, r, f, d in run["rows"]]
    try:
        g.apply_rules(*_gap_text(r2, d_rows), out=[], launch_status=notes)
    except g.Stop as stop:
        expect(stop.rule == "S1" and "is more than 50 T from its hand count 705 T" in stop.lines[0],
               f"harness STOP: {stop.lines}")
    else:
        raise AssertionError("no S1 STOP on a harness 114 T over")
    # a row outside S1's fits priced only by held S1 terms and the harness (CP17: COPY8 17, two blocks)
    # STOPs S4; nxb_rep_t never rises to cover it
    r2 = copy.deepcopy(runs)
    for run in r2:
        if run["verb"] == "NXBO":
            run["rows"] = shift(run["rows"], "CP17", 40)
    try:
        g.apply_rules(*_gap_text(r2, d_rows), out=[], launch_status=notes)
    except g.Stop as stop:
        expect(stop.rule == "S4" and stop.lines[0].startswith("CP17 prices ")
               and stop.lines[0].endswith(" under its band with no fitted term to raise"), f"CP17 STOP: {stop.lines}")
    else:
        raise AssertionError("no S4 STOP on CP17 +40 lines")
    for cpu, dma, want in (((0.0, 19.8), (880.0, 19.795), "near-parallel"),
                           ((0.0, 19.8), (5000.0, 5.1), "outside 1..255")):
        try:
            g.crossover("S6", "L*", cpu, dma, [])
        except g.Stop as stop:
            expect(want in stop.lines[0], f"crossover guard: {stop.lines}")
        else:
            raise AssertionError(f"no crossover STOP for {want}")
    expect(g.search_range([0.4, 58.2]) == (1, 59) and g.search_range([200.0, 300.0]) == (200, 255), "clamped ranges")

    # the CLI prints the STOP and exits 1
    with tempfile.TemporaryDirectory() as td:
        qp = Path(td) / "NXBENCH-Q.TXT"
        qp.write_text(q_text, encoding="latin-1", newline="")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = g.main([str(qp), "--launch-status", f"{runs[-1]['stamp']:04X}=OK"])
    expect(rc == 1 and "STOP S0:" in out.getvalue() and "needs --anchor" in out.getvalue(),
           f"CLI without --anchor: rc {rc}\n{out.getvalue()[-400:]}")


@case(10, "NXBX copy-path fit - crossover, implied threshold, row parser, pricing anchors")
def t10_copy_threshold_fit():
    import io
    import math
    import fit_copy_threshold as fct
    tc = enc.TMODEL_COEFFS
    # Crossover recovered through integer F/D rounding, threshold exact.
    for line_ldi, line_dma in (((303.7, 19.80), (1167.6, 5.10)),
                               ((300.0, 20.0), (1300.0, 6.0))):
        exact = (line_dma[0] - line_ldi[0]) / (line_ldi[1] - line_dma[1])
        text, _ = _nxbx_screen(line_ldi, line_dma)
        rows, warnings = fct.parse_rows(text)
        expect(not warnings and len(rows) == len(bench.BENCH_TABLES[5]),
               f"clean screen must parse whole, warnings {warnings}")
        res = fct.fit(rows)
        expect(abs(res["crossover"] - exact) <= 0.5,
               f"crossover {res['crossover']:.3f} B, lines cross at {exact:.3f}")
        expect(res["threshold"] == math.ceil(exact),
               f"threshold {res['threshold']}, lines imply {math.ceil(exact)}")
        expect(not res["contradictions"], f"exact lines flagged {res['contradictions']}")
        expect(res["span"] == (48, 80) and not res["extrapolated"],
               f"L* {exact:.2f} is inside the measured span, got {res['span']} "
               f"extrapolated={res['extrapolated']}")
    # A crossover below the measured span is flagged as extrapolated.
    res = fct.fit(fct.parse_rows(_nxbx_screen((300.0, 20.0), (700.0, 6.0))[0])[0])
    expect(res["extrapolated"] and res["crossover"] < 48,
           f"L* {res['crossover']:.2f} outside 48-80 must be flagged extrapolated")
    # Parser: 0= for O=, a 5-digit D keeps its first 4 (D048 is also a
    # negative D), fields match what the generator wrote.
    text, want = _nxbx_screen((303.7, 19.80), (1167.6, 5.10),
                              zero_tag="L056", residue_tag="D048")
    d048 = next(line for line in text.splitlines() if line.startswith("D048 "))
    dfield = d048.rsplit("D=", 1)[1]
    expect("L056 0=" in text and len(dfield) == 5
           and all(ch in "0123456789ABCDEF" for ch in dfield),
           f"generator did not write the variants (D048 line {d048!r})")
    rows, warnings = fct.parse_rows(text)
    expect(not warnings, f"variants must parse without warnings, got {warnings}")
    expect(rows == want, f"parsed rows differ:\n  {rows}\n  {want}")
    expect(rows["D048"][3] < 0, "D048's D must parse as signed 16-bit")
    _, warnings = fct.parse_rows("CALR O=00 R=0010 F=0014 D=0012\n")
    expect(not warnings, f"CALR is a printed bench tag, not unknown: {warnings}")
    # A pair whose measured order flips against the lines is flagged.
    text, _ = _nxbx_screen((303.7, 19.80), (1167.6, 5.10), shift={"L060": -40.0})
    res = fct.fit(fct.parse_rows(text)[0])
    expect([c[0] for c in res["contradictions"]] == [60],
           f"L060 pushed under D060 must flag L=60 only, got {res['contradictions']}")
    # The script runs on a file named on the command line.
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "nxbx.txt"
        path.write_text(_nxbx_screen((303.7, 19.80), (1167.6, 5.10))[0])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fct.main([str(path)])
        expect(rc == 0 and "implied NXV2_COPY_DMA_MIN = 59" in out.getvalue(),
               f"CLI run failed (rc {rc}):\n{out.getvalue()}")
    # Gapped fit: a synthetic NXBX+NXBG screen recovers the gapped
    # crossover, and the four L-divides-192 rows are reported as excluded
    # from the fit even when pushed far off the lines.
    gline_ldi, gline_dma = (330.0, 22.0), (1250.0, 7.5)
    gexact = (gline_dma[0] - gline_ldi[0]) / (gline_ldi[1] - gline_dma[1])
    glines = []
    for tag, _kind, L, o, r, _thr, _geo in fct.GAPPED_ROWS:
        path = bench.row_path(tag)
        a, b = gline_ldi if path == "ldi" else gline_dma
        t = a + b * L
        if tag in ("GL48", "GD48", "GL64", "GD64"):
            t += 5000.0
        f, d = divmod(round(t * r * o / bench.T_PER_LINE), bench.LINES_PER_FRAME)
        glines.append(f"{tag} O={o:02X} R={r:04X} F={f:04X} D={d & 0xFFFF:04X}")
    flat_text, _ = _nxbx_screen((303.7, 19.80), (1167.6, 5.10))
    gtext = flat_text + "\n".join(glines) + "\n"
    grows, gwarnings = fct.parse_rows(gtext)
    expect(not gwarnings, f"combined screen must parse whole, warnings {gwarnings}")
    gres = fct.fit(grows)
    expect(abs(gres["gapped"]["crossover"] - gexact) <= 0.5,
           f"gapped crossover {gres['gapped']['crossover']:.3f} B, lines cross at {gexact:.3f}")
    gout = io.StringIO()
    with contextlib.redirect_stdout(gout):
        fct.report(grows, gwarnings, gres)
    printed = gout.getvalue()
    for skip_tag in ("GL48", "GD48", "GL64", "GD64"):
        matches = [ln for ln in printed.splitlines() if ln.strip().startswith(skip_tag + " ")]
        expect(matches and "excluded from the gapped fit (L divides 192)" in matches[0],
               f"{skip_tag} must be reported as excluded from the gapped fit")
    # L080/D081 price as C080/C081 at their own select value; row_predicted
    # reads thr from the row, so a shipped copy_dma_min move can't perturb it.
    ship = tc["copy_dma_min"]
    tc["copy_dma_min"] = 81
    try:
        c080 = bench.PRICERS["C080"](enc)
        c081 = bench.PRICERS["C081"](enc)
    finally:
        tc["copy_dma_min"] = ship
    expect(abs(bench.row_predicted(enc, "L080") - c080) < 1e-9, "L080 must price as C080")
    expect(abs(bench.row_predicted(enc, "D081") - c081) < 1e-9, "D081 must price as C081")
    expect(bench.row_predicted(enc, "D048") > bench.row_predicted(enc, "L048")
           and bench.row_predicted(enc, "D080") < bench.row_predicted(enc, "L080"),
           "forced D rows must price on the DMA path below 81")


@case(10, "copy/fill T model - DMA terms gated on the PLAYER's derived kernel thresholds")
def t10_copy_dma_model():
    tc = enc.TMODEL_COEFFS
    rate = tc["fetch_long"]
    setup, per_b, chunk, thr = (tc["copy_dma_setup"], tc["copy_dma_per_b"],
                                tc["copy_dma_chunk"], tc["copy_dma_min"])
    path = tc["copy_dma_path_t"]
    # RULE 1 - below the player's threshold the copy body is pure LDI,
    # matching src/video.asm vid_copy_body (vid_copy_ldi under
    # NXV2_COPY_DMA_MIN).
    for L in (1, 16, 64, 73, 74, 80):
        expect(abs(enc._copy_t(L, rate) - L * rate) < 1e-6,
               f"copy body of {L} B (< {thr}) must be priced as CPU/LDI, got {enc._copy_t(L, rate):.1f}")
    # RULE 1b - the player's threshold against the coefficients' own
    # break-even, as a SIGNED divergence, not an equality the player no
    # longer satisfies: the 2026-09-15 loop change made the DMA branch
    # cheaper and moved the break-even to 58.77 B while NXV2_COPY_DMA_MIN
    # stays 81. fetch_short is the deciding rate here - the ops at the
    # seam are 73-83 B and run the short body; copy_dma_min's own comment
    # quotes the same break-even at fetch_long (58.9 B), not an error.
    # Worst mispricing: at L=80 the player runs LDI for +312 T/op over
    # what the DMA branch would cost (+309 at fetch_long).
    short = tc["fetch_short"]
    breakeven = (setup + path) / (short - per_b)
    expect(abs(breakeven - 58.77) <= 1.0,
           f"copy break-even should be the 2026-09-15 58.77 B, got {breakeven:.2f}")
    expect(0.0 <= thr - breakeven <= 25.0,
           f"copy threshold {thr} must sit at or above the break-even "
           f"{breakeven:.2f} B and within 25 B of it "
           "(re-derive NXV2_COPY_DMA_MIN and these coefficients together)")
    lost = (thr - 1) * short - (setup + path + (thr - 1) * per_b)
    expect(0.0 < lost <= 340.0,
           f"the LDI band above the break-even costs the player {lost:.0f} T/op "
           f"at {thr - 1} B - bounded at 340")
    for L in range(1, int(breakeven) + 1):
        expect(L * short <= setup + path + L * per_b + 1e-9,
               f"below the break-even LDI must be the CHEAPER path, fails at {L} B")
    # RULE 2 - at/above the threshold: the DMA price, which the player is
    # committed to (no min() floor - see _copy_t), op-class entry cost
    # included. The ENTRY COST is the fast-handler -> slow-body path
    # difference for an 8-bit-operand op, and the measured slow-parser
    # entry (t_skip16 - t_skip) for a 16-bit-operand one, which has no
    # fast handler to bail out of (_copy_t).
    entry16 = tc["t_skip16"] - tc["t_skip"]
    expect(abs(entry16 - 69.1) < 1e-6, "the slow-parser entry is 69.1 T")
    def entry(L):
        return path if L <= 255 else entry16
    for L in (81, 128, 200, chunk - 1, chunk):
        dma = entry(L) + setup + L * per_b
        expect(abs(enc._copy_t(L, rate) - dma) < 1e-6,
               f"copy body of {L} B must be the DMA-path price, got {enc._copy_t(L, rate):.1f}")
    expect(abs(enc._copy_t(chunk, rate) - (entry(chunk) + setup + chunk * per_b)) < 1e-6,
           "a full chunk is priced at the op-class entry + one DMA setup + chunk B of transfer")
    # K256 SILICON (2775.90 T/op, NXBK): the whole op - dispatch
    # envelope + entry + body - must land inside 1% of it. Charging
    # path_t here instead read +2.91% conservative; this is the 2.1 pp
    # the correction bought on the class that carries every keyframe
    # bulk repaint.
    # PINNED TO THE CAP THE ROW WAS MEASURED AT. K256 is a 256 B COPY16
    # run on a player whose NXV2_DMA_CHUNK was 256, so it was ONE DMA
    # chunk. The cap moved to 240 on 2026-08-03 (audio DI bracket), so
    # the same op on the shipping player is one 240 B DMA chunk plus a
    # 16 B LDI tail and legitimately costs more. The silicon row still
    # validates the COEFFICIENTS; it must be evaluated at the cap it was
    # taken under, not at today's.
    # The row also PREDATES the 2026-09-15 chunk-loop change (~279 T per
    # chunk): the change-adjusted row is 2496.9 T and the model prices
    # +10.9% over it - the safe side.
    with _at_chunk_cap(256):
        k256 = tc["t_op_copy"] + enc._copy_t(256, rate)
    expect(abs(k256 / 2775.90 - 1.0) < 0.01,
           f"a 256 B COPY16 at the cap K256 was measured under must model "
           f"within 1% of the silicon row (2775.90 T), got {k256:.1f} "
           f"({100 * (k256 / 2775.90 - 1):+.2f}%)")
    # RULE 3 - the kernel switch must not be an UNBOUNDED cost
    # discontinuity. Two DISCLOSED seams, both asserted rather than
    # wished away: (a) the step across the op threshold now FALLS,
    # because the player's 81 sits 22 B above the break-even (RULE 1b);
    # (b) a remainder crossing the threshold after full chunks falls by
    # at most thr*(rate-per_b) - setup. Assert the bound rather than
    # pretending monotonicity the player does not have.
    thr_seam = (thr - 1) * rate - (path + setup + thr * per_b)
    # The tail bound WIDENS by the trailing-chunk term: a remainder that
    # grows across the threshold drops that term as well as the LDI
    # transfer, so an op with a DMA tail is cheaper than one with a CPU
    # tail by more than the kernel difference alone.
    tail_seam = thr * (rate - per_b) - setup + tc["copy_dma_tail_t"]
    expect(abs(thr_seam - 303.8) <= 5.0,
           f"the op-threshold seam should be the 2026-09-15 303.8 T, got {thr_seam:.1f}")
    seam_bound = max(thr_seam, tail_seam) + 1e-6
    prev = 0.0
    for L in range(1, 601):
        cur = enc._copy_t(L, rate)
        expect(cur >= prev - seam_bound,
               f"copy body price fell by more than the disclosed seam bound "
               f"({seam_bound:.0f} T): {L - 1} B {prev:.1f} -> {L} B {cur:.1f}")
        prev = cur
    expect(abs((enc._copy_t(thr - 1, rate) - enc._copy_t(thr, rate)) - thr_seam) < 1e-6,
           "the step across the kernel threshold must be exactly the disclosed op seam")
    # RULE 4 - multi-chunk: full chunks go DMA (one path term per op), a
    # sub-threshold tail goes LDI (the player re-selects per chunk) AND
    # pays one chunk-loop iteration, copy_dma_tail_t - the charge silicon
    # C256/F256 showed the model owed before it had this term.
    tail300 = 300 - chunk
    expect(tail300 < thr, "the 300 B case must leave a sub-threshold tail")
    # 8-bit ops take the LARGER tail (no path-term slack to net against):
    # a 250 B copy is one chunk + a 10 B tail at copy_dma_tail8_t.
    expect(abs(enc._copy_t(250, rate)
               - (path + (setup + chunk * per_b) + 10 * rate + tc["copy_dma_tail8_t"])) < 1e-6,
           f"a 250 B copy = the 8-bit path term + one DMA chunk + a 10 B LDI tail "
           f"+ the 8-bit trailing-chunk term, got {enc._copy_t(250, rate):.1f}")
    expect(abs(enc._copy_t(300, rate)
               - (entry16 + (setup + chunk * per_b) + tail300 * rate + tc["copy_dma_tail_t"])) < 1e-6,
           f"a 300 B copy = the entry term + one DMA chunk + a {tail300} B LDI tail "
           f"+ the trailing-chunk term")
    expect(abs(enc._copy_t(2 * chunk, rate) - (entry16 + 2 * (setup + chunk * per_b))) < 1e-6,
           f"a {2 * chunk} B copy = the entry term + two DMA chunks")
    # RULE 5 - the restored term must never make copy MORE expensive than
    # the old all-LDI model at any tested length (at exactly thr the
    # DMA path can price a few T above LDI - the measured placement,
    # deliberately excluded here), and must stay materially cheaper on
    # the dominant large-copy class (256 B: 5171 T all-LDI vs ~2579 T
    # with the DMA + path terms, ~2.0x - the over-price this test
    # exists to prevent was ~2.1x before the path term).
    for L in (1, 63, 89, 90, 256, 1024, 65535):
        expect(enc._copy_t(L, rate) <= L * rate + 1e-6,
               f"the DMA term may only ever LOWER the {L} B copy price")
    # (240*19.76)/(-227.9 + 1091.8 + 240*5.10) = 2.27 at the 2026-09-15
    # coefficients (1.99 before the chunk-loop change). A full chunk is
    # the right length to price here because it is the DMA path at its
    # most efficient - one setup amortised over the whole cap.
    fullx = (chunk * rate) / enc._copy_t(chunk, rate)
    expect(abs(fullx - 2.27) < 0.05,
           f"a full-chunk copy body must price ~2.27x under all-LDI, got {fullx:.2f}x")
    # RULE 6 - agreement with the silicon rows the coefficients came
    # from, each EVALUATED AT THE CAP IT WAS MEASURED UNDER (256 - see
    # the K256 note above; the shipping cap is 240 and legitimately
    # prices these lengths dearer). CD3 (dma copy, 256 B chunks)
    # measured 9.84 T/B over 1024 B ops; the KF row (43008 B COPY16,
    # DMA256) measured 12.2 T/B ARMED, which de-rates to ~10.4 unarmed.
    # Body-only rates, dispatch excluded.
    with _at_chunk_cap(256):
        cd3 = enc._copy_t(1024, rate) / 1024
        kfr = enc._copy_t(43008, rate) / 43008
    # CD3 PREDATES the 2026-09-15 chunk-loop change; at cap 256 that
    # change is worth ~1.09 T/B, putting the adjusted row at 8.75 T/B.
    # The model must not price below it.
    expect(8.75 <= cd3 <= 10.34,
           f"1024 B copy body should sit between CD3's change-adjusted 8.75 "
           f"and its measured 9.84+0.5 T/B, got {cd3:.2f}")
    expect(9.0 < kfr < 10.6,
           f"43008 B copy body should sit near the KF row's unarmed rate, "
           f"got {kfr:.2f}")
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
    expect(abs(enc._copy_t(chunk, rate) - (entry(chunk) + setup + chunk * per_b)) < 1e-6,
           "coefficients restored")
    # RULE 8 - the FILL model is gated the same way, on the player's own
    # NXV2_RUN_DMA_MIN (src/video.asm vid_run_body re-selects per chunk),
    # with the threshold checked against its own derived break-even.
    # Before 2026-07-28 _fill_t took a bare min(cpu, dma) over the WHOLE
    # length, which priced a 300 B fill as two DMA setups when the player
    # really runs one DMA chunk and a CPU tail.
    fcpu, fsetup, fper = tc["fill_cpu"], tc["fill_dma_setup"], tc["fill_dma_per_b"]
    fchunk, fthr = tc["fill_dma_min"], tc["run_dma_min"]
    fpath = tc["fill_dma_path_t"]
    # 8-bit ops decide the threshold, so the break-even is read off the
    # SUM of the chunk cost and that op class's cheaper entry (781.1) -
    # the single number F071 measured before the two were separated.
    fbreakeven = (fsetup + fpath) / (fcpu - fper)
    # SIGNED divergence, same shape as RULE 1b. The 2026-09-15 fit puts
    # the break-even at 72.58 B while the PLAYER's constant
    # (NXV2_RUN_DMA_MIN) stays 71, so 71-72 B fills commit to DMA 1.6 B
    # early at a worst mispricing of +17 T/op.
    expect(abs(fbreakeven - 72.58) <= 1.0,
           f"fill break-even should be the 2026-09-15 72.58 B, got {fbreakeven:.2f}")
    expect(-2.5 <= fthr - fbreakeven <= 2.5,
           f"fill threshold {fthr} must sit near the break-even {fbreakeven:.2f} B "
           "(re-derive NXV2_RUN_DMA_MIN and this coefficient together)")
    flost = (fsetup + fpath + fthr * fper) - fthr * fcpu
    expect(0.0 <= flost <= 40.0,
           f"the early-DMA band must cost the player at most 40 T/op, got {flost:.0f}")
    for L in (1, 16, 64, fthr - 1):
        expect(abs(enc._fill_t(L) - L * fcpu) < 1e-6,
               f"fill body of {L} B (< {fthr}) must be priced as unrolled CPU fill")
        expect(L * fcpu <= fsetup + fpath + L * fper + 1e-9,
               f"below the threshold CPU fill must be the CHEAPER kernel, fails at {L} B")
    for L in (fthr, 128, fchunk - 1, fchunk):
        expect(abs(enc._fill_t(L) - (fpath + fsetup + L * fper)) < 1e-6,
               f"fill body of {L} B must be the 8-bit entry + one DMA setup + transfer, "
               f"got {enc._fill_t(L):.1f}")
    # A 16-bit RUN pays the slow-parser entry its 8-bit twin does not -
    # the same t_skip16 - t_skip the copy branch charges.
    fentry16 = tc["t_skip16"] - tc["t_skip"]
    ftail300 = 300 - fchunk
    expect(ftail300 < fthr, "the 300 B fill case must leave a sub-threshold tail")
    expect(abs(enc._fill_t(250)
               - (fpath + (fsetup + fchunk * fper) + 10 * fcpu + tc["fill_dma_tail8_t"])) < 1e-6,
           f"a 250 B fill = the 8-bit path term + one DMA chunk + a 10 B CPU tail "
           f"+ the 8-bit trailing-chunk term, got {enc._fill_t(250):.1f}")
    expect(abs(enc._fill_t(300)
               - (fentry16 + (fsetup + fchunk * fper) + ftail300 * fcpu
                  + tc["fill_dma_tail_t"])) < 1e-6,
           f"a 300 B fill = the 16-bit entry + one DMA chunk + a {ftail300} B CPU tail "
           f"+ the trailing-chunk term")
    expect(abs(enc._fill_t(2 * fchunk) - (fentry16 + 2 * (fsetup + fchunk * fper))) < 1e-6,
           f"a {2 * fchunk} B fill = the 16-bit entry + two DMA chunks (no tail, so the "
           f"entry is charged on its own - it was free before 2026-09-15)")
    saved = dict(enc.TMODEL_COEFFS)
    try:
        enc.TMODEL_COEFFS["run_dma_min"] = 1024
        expect(abs(enc._fill_t(256) - 256 * fcpu) < 1e-6,
               "raising run_dma_min must push a 256 B fill back onto the CPU price")
    finally:
        enc.TMODEL_COEFFS.clear()
        enc.TMODEL_COEFFS.update(saved)


@case(10, "copy census - op walk round-trip, threshold_cost lines, COPY16 model pricing")
def t10_copy_census():
    import nxv2_copy_census as census_mod
    # ops_of_payload must return exactly what was put in, skips included.
    payload = (enc.op_skip(5) + enc.op_run(10, 7) + enc.op_copy(bytes(range(20)))
               + enc.op_skip(300) + enc.op_run(300, 3) + enc.op_copy(bytes(400))
               + bytes([enc.OP_FEND]))
    got = list(census_mod.ops_of_payload(payload))
    want = [(enc.OP_SKIP8, 5), (enc.OP_RUN8, 10), (enc.OP_COPY8, 20),
            (enc.OP_SKIP16, 300), (enc.OP_RUN16, 300), (enc.OP_COPY16, 400)]
    expect(got == want, f"ops_of_payload round-trip: got {got}, want {want}")

    # threshold_cost: hand-built 8-bit census against two made-up lines,
    # one per surface, equals the hand-computed total at n=59 and n=81.
    c_flat = census_mod.Census()
    c_flat.copy8[40] = 3
    c_flat.copy8[70] = 2
    c_flat.copy8[100] = 1
    c_gap = census_mod.Census()
    c_gap.copy8[50] = 4
    c_gap.copy8[90] = 1
    cen = {"flat": c_flat, "gapped": c_gap}
    lines = {"flat": ((300.0, 20.0), (1100.0, 6.0)),
             "gapped": ((350.0, 22.0), (1200.0, 7.0))}
    for n in (59, 81):
        want_total = 0.0
        for surface, c in cen.items():
            (a_l, b_l), (a_d, b_d) = lines[surface]
            want_total += sum(k * ((a_l + b_l * L) if L < n else (a_d + b_d * L))
                              for L, k in c.copy8.items())
        got_total = census_mod.threshold_cost(cen, lines, n, enc=enc)
        expect(abs(got_total - want_total) < 1e-9,
               f"threshold_cost at n={n}: got {got_total:.4f}, want {want_total:.4f}")

    # COPY16: priced by the model's own terms at copy_dma_min = n, not a
    # line intercept - and copy_dma_min must come back afterwards.
    c16 = census_mod.Census()
    c16.copy16[300] = 1
    cen16 = {"flat": c16, "gapped": census_mod.Census()}
    tc = enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"]
    try:
        for n in (59, 81):
            tc["copy_dma_min"] = n
            want16 = enc._cost_copy_chunk(300)[1]
            tc["copy_dma_min"] = saved
            got16 = census_mod.threshold_cost(cen16, lines, n, enc=enc)
            expect(abs(got16 - want16) < 1e-9,
                   f"COPY16 pricing at n={n}: got {got16:.4f}, want {want16:.4f}")
            expect(tc["copy_dma_min"] == saved, "copy_dma_min must be restored after threshold_cost")
    finally:
        tc["copy_dma_min"] = saved

    # worst_gapped_fraction prices the denominator at copy_thr too: a
    # synthetic gapped frame with one 70 B COPY8 must land on the DMA
    # class at copy_thr=59 in BOTH the surcharge and the modelled T.
    orig_is_gapped, orig_frames_of = census_mod.is_gapped_file, census_mod.frames_of
    census_mod.is_gapped_file = lambda p: True
    census_mod.frames_of = lambda p: iter([[(enc.OP_COPY8, 70)]])
    try:
        surcharge = {"copy_dma": 42.0, "copy_ldi": 5.0}
        got_frac = census_mod.worst_gapped_fraction(["fake.vid"], surcharge, 59)
    finally:
        census_mod.is_gapped_file = orig_is_gapped
        census_mod.frames_of = orig_frames_of
    expect(tc["copy_dma_min"] == saved, "copy_dma_min must be restored after worst_gapped_fraction")
    saved2 = tc["copy_dma_min"]
    tc["copy_dma_min"] = 59
    try:
        want_modelled = tc["t_frame_fixed"] + enc.op_cost("copy", 70)[1]
    finally:
        tc["copy_dma_min"] = saved2
    want_frac = surcharge["copy_dma"] / want_modelled
    expect(abs(got_frac - want_frac) < 1e-9,
           f"worst_gapped_fraction at copy_thr=59: got {got_frac:.6f}, want {want_frac:.6f}")


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

    po_ceil is built via enc.display_ceiling: a reachable display-pipeline
    ceiling (dithered, lattice-snapped), not a 24-bit adaptive ceiling -
    the latter would make t11_staleness_bounded's deficit gate vacuous or
    thrash the staleness/drift trigger into per-frame keyframes."""
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
    hdr = enc.pack_header(width=w, height=h, fps=fps, channels=2, arate=enc.RATE_STEREO,
                           frame_count=len(payloads), audio_bytes_per_frame=0,
                           ring_start_margin_blocks=0, per_frame_cap_blocks=0)
    return hdr + b"".join(p + bytes((-len(p)) % 512) for p in payloads)


def _synth_clip(orig):
    """po_ceil + chg for a synthetic (N,H,W,3) stack, like _extract_source.
    Same display-space ceiling reasoning as _slow_drift_clip above."""
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
    # 94.2 B at the 2026-09-15 coefficients (139 before the re-fit): the
    # denominator is a difference of two close terms, so it swings hard.
    expect(80.0 < absorb_max < 160.0, f"sanity: silicon absorb_max ~94B, got {absorb_max:.1f}")

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
    # term, absorbing re-priced the run's body at the LDI rate then in
    # force and the guard SAVED decode T outright - the review finding's
    # original claim, and what this case used to assert. With copy bodies
    # now priced at 1091.8 T/chunk + 5.10 T/B the arithmetic INVERTS at
    # this length: absorbing is a few hundred T cheaper, so a pure-T
    # reading would push the crossover from ~94 B out past 700 B.
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


@case(11, "pack_header defence-in-depth - audio bytes over the 3072 player bound rejected")
def t11_pack_header_bound():
    try:
        enc.pack_header(width=256, height=192, fps=25, channels=2,
                        arate=enc.RATE_STEREO, frame_count=1,
                        audio_bytes_per_frame=enc.AUD_FRAME_MAX + 1,
                        ring_start_margin_blocks=0, per_frame_cap_blocks=1)
    except ValueError as e:
        expect(str(enc.AUD_FRAME_MAX) in str(e),
               "error names the player bound")
        expect("VID FMT" in str(e), "error names the player refusal")
    else:
        raise AssertionError(
            f"pack_header must reject {enc.AUD_FRAME_MAX + 1} audio bytes/frame")
    # the bound itself is legal
    hdr = enc.pack_header(width=256, height=192, fps=25, channels=2,
                          arate=enc.RATE_STEREO, frame_count=1,
                          audio_bytes_per_frame=enc.AUD_FRAME_MAX,
                          ring_start_margin_blocks=0, per_frame_cap_blocks=1)
    expect(len(hdr) == 512, "the bound exactly is accepted")


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
            expect("tops out at" in msg and "audio floor" in msg,
                   "refusal states the at-rate envelope and the floor entry (the full menu)")
            expect("accept-slow" not in msg.lower(),
                   "refusal must not mention a slow-playback override that no longer exists")
            expect(not out.exists(), "no file written on refusal")
        else:
            raise AssertionError("320x256@25 direct must be refused "
                                 "(raw 81920 B/frame over the wire)")
    # Direct transport is priced as the bare wire floor (per-byte
    # factor) plus a fixed per-frame overhead; both constants are
    # pinned against the silicon rows they reproduce.
    expect(enc.DIRECT_TRANSPORT_FACTOR == 1.00,
           f"direct transport byte factor should be the 2026-08-02 "
           f"silicon 1.00, got {enc.DIRECT_TRANSPORT_FACTOR}")
    expect(enc.DIRECT_FRAME_OVERHEAD_MS == 2.2,
           f"direct frame overhead should be the 2026-08-02 silicon "
           f"2.2 ms, got {enc.DIRECT_FRAME_OVERHEAD_MS}")
    # probe 056's ordinary section (256x160@25 stereo, 43,008 B)
    # measured 40.882 ms/frame on silicon; the gate must price it
    # conservatively - above the measurement, but within ~1.5%
    mean_frame = 1536 + 81 * 512
    ds = enc.direct_supply_check(mean_frame, 25.0)
    expect(40.88 <= ds["sd_ms"] <= 41.5,
           f"the re-fitted model must cover 056's measured 40.882 "
           f"ms/frame conservatively, got {ds['sd_ms']:.3f}")
    # 256x160@25 stereo (probe 056's shape, silicon: 2.2% OVER period)
    # is NOT at-rate and must be refused
    worst = 1536 + 82 * 512               # + the scene-start PAL block
    expect(1.02 < enc.direct_supply_check(worst, 25.0)["utilization"] < 1.06,
           "256x160@25 direct scores ~1.044 under the re-fitted gate - "
           "over 1.00, so it must be refused unconditionally")
    # 320x256@12.5 stereo (probe 057's shape, silicon: at rate with
    # pace slack) must be ADMITTED - the T10+T8 full-screen mode
    worst125 = 2560 + 162 * 512
    u125 = enc.direct_supply_check(worst125, 12.5)["utilization"]
    expect(0.99 < u125 <= 1.0,
           f"320x256@12.5 stereo direct must be admitted at the edge "
           f"(silicon at-rate), got {u125:.4f}")
    # the re-fitted at-rate envelope, and its monotonicity
    raw25 = enc.direct_max_raw_bytes(25.0, 1.0)
    expect(39000 < raw25 < 39500, f"25fps stereo direct tops out ~38.5 KB raw, got {raw25}")
    expect(raw25 // 256 == 153,
           f"25fps stereo 256-wide envelope is 256x153, got 256x{raw25 // 256}")
    expect(enc.direct_supply_check(
        1536 + ((raw25 + 518 + 511) // 512) * 512, 25.0)["utilization"] <= 1.0,
        "direct_max_raw_bytes must actually pass its own gate")
    expect(enc.direct_max_raw_bytes(18.22, 1.0) > raw25,
           "a lower fps admits a bigger direct surface")
    # 010/011's chosen re-encode point (256x133@25 stereo) must actually
    # be at-rate under the gate - the positive-path complement to the
    # 320x256 refusal above.
    ok_worst = 1536 + ((256 * 133 + 518 + 511) // 512) * 512
    expect(enc.direct_supply_check(ok_worst, 25.0)["utilization"] <= 1.0,
           "256x133@25 stereo (the 010/011 TIGHTEN re-encode shape) must pass the gate")

    # The accept-slow escape is removed, not just unused: it must not
    # exist anywhere in the encoder plumbing, and the wire gate must
    # not be bypassable by any flag.
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
    # At the CLI: --direct-accept-slow must be gone, and an over-wire
    # direct encode must be refused regardless of any flags (no flag
    # left changes the verdict).
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
                   "--shape", "256x160", "--fps", "25", "--duration", "1",
                   "--direct", "--direct-accept-slow", "--ffmpeg", str(FFMPEG)]
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            expect(proc.returncode != 0,
                   "an over-wire --direct encode with an (unrecognized) "
                   "--direct-accept-slow flag must still fail")
            expect(not out2.exists(), "no file written")
            stderr = proc.stderr.decode("utf-8", "replace")
            expect("unrecognized arguments" in stderr or "--direct-accept-slow" in stderr,
                   f"argparse should reject the removed flag, got:\n{stderr}")
            # (b) even with only the flags that still exist (no
            # accept-slow at all), the same over-wire shape must be
            # refused by the wire gate itself, not just
            # by argparse rejecting an unknown flag.
            out3 = Path(td) / "over_wire_plain.vid"
            cmd2 = [sys.executable, str(LIB / "videnc.py"), str(SINTEL), str(out3),
                    "--shape", "256x160", "--fps", "25", "--duration", "1",
                    "--direct", "--ffmpeg", str(FFMPEG)]
            proc2 = subprocess.run(cmd2, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            expect(proc2.returncode != 0,
                   "256x160@25 stereo --direct (util ~1.044, silicon "
                   "2.2% over) must be refused with no other flags in play")
            expect(not out3.exists(), "no file written on the plain-flag refusal")
            stderr2 = proc2.stderr.decode("utf-8", "replace")
            expect("utilization" in stderr2 and "direct-serve" in stderr2,
                   f"the plain refusal must be the wire-gate message, got:\n{stderr2}")


@case(11, "TOTAL-SIZE admission gate - the player's file ceiling is "
          "priced at encode time, projection exact to the written byte")
def t11_total_size_gate():
    import tempfile as tf
    # --- the constant and its derivation (single source of truth,
    # tied to the player's cursor width / hot filemap). ---
    expect(enc.PLAYER_HOT_FILEMAP_ENTRIES == 8,
           "PLAYER_HOT_FILEMAP_ENTRIES must track VID_STRM_HOT_ENT (8)")
    expect(enc.PLAYER_FILEMAP_BLOCKS_PER_ENTRY == 65535,
           "an esxDOS DISK_FILEMAP extent carries a 16-bit block count")
    expect(enc.PLAYER_MAX_BLOCKS == 8 * 65535,
           "PLAYER_MAX_BLOCKS is entries * blocks-per-entry")
    expect(enc.PLAYER_MAX_BYTES == enc.PLAYER_MAX_BLOCKS * 512,
           "PLAYER_MAX_BYTES is blocks * 512")
    # The CEILING LIFT is the point of the constant: the player's
    # file-level cursors count 512-byte BLOCKS now, so the old 24-bit
    # BYTE ceiling (16 MiB, ~15.7 s of full-screen direct) is gone and
    # the file ceiling is an order of magnitude past it.
    expect(enc.PLAYER_MAX_BYTES > 16 * 1024 * 1024,
           "the ceiling must be past the pre-lift 24-bit BYTE cursor "
           "limit of 16 MiB - that limit is what the lift removed")
    expect(enc.PLAYER_MAX_BYTES <= 1 << 33,
           "the ceiling must stay inside the 24-bit BLOCK cursors (8 GiB)")

    # --- the FRAME ceiling: the player validates the header's top
    # frame-count byte as zero (16-bit frame counters), and the lift
    # made that reachable - a cheap clip hits 65535 frames long before
    # 256 MiB. Priced here and defended in pack_header. ---
    expect(enc.PLAYER_MAX_FRAMES == 65535,
           "the player's frame ceiling is its 16-bit counters")
    enc.total_size_check(1024 * 65535, 65535, "streaming",
                         256, 192, 25, 2)            # exactly at: admitted
    try:
        enc.total_size_check(1024 * 65536, 65536, "streaming",
                             256, 192, 25, 2)
    except SystemExit as e:
        msg = str(e)
        expect("65,535 frame" in msg, "refusal names the frame limit")
        expect("VID FMT" in msg, "refusal names the player's own verdict")
        expect("longest playable clip" in msg and "--duration" in msg,
               "refusal names the max duration and the remedy")
    else:
        raise AssertionError("one frame over the ceiling must be refused")
    try:
        enc.pack_header(width=256, height=192, fps=25, channels=2,
                        arate=enc.RATE_STEREO, frame_count=65536,
                        audio_bytes_per_frame=1250,
                        ring_start_margin_blocks=1, per_frame_cap_blocks=1)
    except ValueError as e:
        expect("65535" in str(e) and "VID FMT" in str(e),
               "pack_header defends the frame bound with the player verdict")
    else:
        raise AssertionError("pack_header must reject 65536 frames")

    # --- the SIZE check: boundary is inclusive, refusal names the
    # limit AND the longest clip at this shape/rate. ---
    enc.total_size_check(enc.PLAYER_MAX_BYTES, 3140, "direct-serve",
                         320, 256, 12.5, 2)          # exactly at: admitted
    try:
        enc.total_size_check(enc.PLAYER_MAX_BYTES + 512, 3200,
                             "direct-serve", 320, 256, 12.5, 2)
    except SystemExit as e:
        msg = str(e)
        expect(f"{enc.PLAYER_MAX_BYTES:,}" in msg,
               "refusal names the byte limit")
        expect("VID FRAG" in msg,
               "refusal names the player refusal an author would see")
        expect("320x256" in msg and "12.5 fps" in msg and "stereo" in msg,
               "refusal names the shape and rate it was measured at")
        expect("longest playable clip" in msg and "--duration" in msg,
               "refusal names the max duration and the remedy")
    else:
        raise AssertionError("one block over the ceiling must be refused")

    # --- WIRING + PROJECTION EXACTNESS. Encode a real (tiny) direct
    # clip, then re-run it with the ceiling pinned at the written size
    # and one byte below: the projection is the writer's own arithmetic,
    # so it must admit at exactly the file size and refuse one below. ---
    real_max = enc.PLAYER_MAX_BYTES
    ex = _synthetic_ex(3, 256, 128)
    try:
        with tf.TemporaryDirectory() as td:
            out = Path(td) / "size.vid"
            enc._encode_direct(ex, 256, 128, 12.5, out)
            written = out.stat().st_size
            expect(written % 512 == 0, "a .VID is whole 512-byte blocks")
            out.unlink()
            enc.PLAYER_MAX_BYTES = written        # projection == written
            enc._encode_direct(ex, 256, 128, 12.5, out)
            expect(out.stat().st_size == written,
                   "at a ceiling of exactly the file size the encode is "
                   "admitted and byte-identical")
            out.unlink()
            enc.PLAYER_MAX_BYTES = written - 1
            try:
                enc._encode_direct(ex, 256, 128, 12.5, out)
            except SystemExit as e:
                expect("file ceiling" in str(e),
                       "the direct writer is guarded by the size gate")
                expect(not out.exists(),
                       "no file written when the size gate refuses")
            else:
                raise AssertionError("one byte under the written size "
                                     "must be refused - the projection "
                                     "is not the writer's arithmetic")
    finally:
        enc.PLAYER_MAX_BYTES = real_max

    # --- EVERY .VID writer is guarded (the streaming path costs an
    # ffmpeg extraction to reach, so it is pinned by inspection): the
    # gate must sit between each writer's own def and its open(). ---
    import re
    src = (LIB / "nxv2enc.py").read_text(encoding="utf-8")
    expect(src.count("def total_size_check(") == 1,
           "the gate is defined exactly once")
    writers = [m.start() for m in
               re.finditer(r'with open\(out_path, "wb"\) as f:', src)]
    expect(len(writers) == 2, f"expected 2 .VID writers, found {len(writers)}")
    for at in writers:
        body = src[src.rindex("\ndef ", 0, at):at]
        expect("total_size_check(" in body,
               "every .VID writer must run the size gate BEFORE writing")


@case(11, "direct-serve transport-factor expert override - scales the "
          "BYTE term only (2026-08-02 two-term re-fit), threads "
          "through the whole gate")
def t11_direct_transport_override():
    import inspect
    import subprocess
    # The governance contract: the SHIPPING defaults are untouched (the
    # 1.00 + 2.2 ms pins live in t11_direct_gate); the override is a
    # per-call parameter, never a mutation of the constant.
    frame = 1536 + 73 * 512
    ds_def = enc.direct_supply_check(frame, 25.0)
    ds_none = enc.direct_supply_check(frame, 25.0, transport_factor=None)
    expect(ds_def == ds_none,
           "transport_factor=None must be exactly the shipping default path")
    # the override scales the BYTE term of sd_ms EXACTLY linearly and
    # leaves the fixed frame overhead alone - nothing else moves
    tf_probe = 0.96
    ds_ovr = enc.direct_supply_check(frame, 25.0, transport_factor=tf_probe)
    ovh = enc.DIRECT_FRAME_OVERHEAD_MS
    expect(abs((ds_ovr["sd_ms"] - ovh) / (ds_def["sd_ms"] - ovh)
               - tf_probe / enc.DIRECT_TRANSPORT_FACTOR) < 1e-9,
           "the override must scale the byte term by factor/default "
           "exactly, leaving the frame overhead fixed")
    expect(ds_ovr["period_ms"] == ds_def["period_ms"]
           and ds_ovr["demand_kbs"] == ds_def["demand_kbs"],
           "the override touches the transport rate only - period and demand are factor-free")
    # a smaller byte factor grows the envelope; at 0.96 (the historical
    # probe rate) the 256-wide stereo @25 envelope reaches 256x159
    # against 256x153 at the shipping 1.00
    raw_def = enc.direct_max_raw_bytes(25.0, 1.0)
    raw_ovr = enc.direct_max_raw_bytes(25.0, 1.0, transport_factor=tf_probe)
    expect(raw_ovr > raw_def,
           "a smaller transport factor must grow the at-rate envelope")
    expect(raw_ovr // 256 == 159,
           f"at byte factor 0.96 the 256-wide envelope is 256x159, "
           f"got 256x{raw_ovr // 256}")
    expect(raw_def // 256 == 153,
           f"at the shipping 1.00 the envelope is 256x153, "
           f"got 256x{raw_def // 256}")
    # plumbing: encode() and _encode_direct() carry the parameter, and
    # the CLI exposes it
    expect("direct_transport_factor" in inspect.signature(enc.encode).parameters,
           "encode() must accept direct_transport_factor")
    expect("direct_transport_factor" in inspect.signature(enc._encode_direct).parameters,
           "_encode_direct() must accept direct_transport_factor")
    help_out = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), "--help"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout.decode("utf-8", "replace")
    expect("--direct-transport-factor" in help_out,
           "videnc.py --help must document --direct-transport-factor")


@case(11, "direct-serve gate refusal - fps-floor menu entry hardened "
          "against the Fraction-rounding knife-edge (Card #5 review fix)")
def t11_direct_gate_fps_floor_menu():
    # Review finding: min_fps_for() is, BY CONSTRUCTION, the exact fps
    # where audio_layout's real bytes/frame lands on the
    # AUD_FRAME_MAX boundary. Which side of the boundary Fraction
    # rounding falls on there is a coin flip only a few ULP wide - a
    # raise there inside the refusal-message builder
    # (direct_max_raw_bytes -> audio_layout) would surface as an
    # unrelated SystemExit ("... exceeds the NXV player's per-frame
    # audio bound ...") out of what should be the direct-serve
    # wire-gate refusal. The fix rounds the floor UP to the nearest
    # 0.01 fps (math.ceil(...*100)/100, the same idiom audio_layout's
    # own "fits" floor already uses) before feeding it back through
    # direct_max_raw_bytes. (The menu entry was the MONO floor until
    # mono was withdrawn on 2026-08-03; the knife-edge is a property
    # of the floor, not of the channel count, so the case survives the
    # removal unchanged in substance.)
    import math as _m
    fps_floor = enc.min_fps_for()
    # demonstrate the knife-edge is real: at and just below the exact
    # floor audio_layout's verdict flips (real 3072 -> 3074, over
    # AUD_FRAME_MAX) and direct_max_raw_bytes raises unguarded.
    unlucky = fps_floor - 1e-4
    try:
        enc.direct_max_raw_bytes(unlucky, 1.0)
    except SystemExit:
        pass
    else:
        raise AssertionError("test setup: expected the floor minus an "
                             "epsilon to demonstrate the raise this "
                             "case guards against")
    # the fix's guard: rounding UP first, at the floor itself AND at
    # the unlucky perturbation, must render without raising either way.
    for fps in (fps_floor, unlucky):
        safe = _m.ceil(fps * 100) / 100
        floor_at = enc.direct_max_raw_bytes(safe, 1.0)
        expect(floor_at > 0,
               f"direct_max_raw_bytes at the rounded fps floor "
               f"({safe}) must not raise, got {floor_at}")
    # end-to-end: the real refusal path (320x256@25, same shape the
    # sibling gate case above refuses) must render the floor menu
    # entry using this same guarded computation - not just be correct
    # in isolation.
    import tempfile as tf
    ex = _synthetic_ex(2, 320, 256)
    with tf.TemporaryDirectory() as td:
        out = Path(td) / "toobig_fpsfloor.vid"
        try:
            enc._encode_direct(ex, 320, 256, 25.0, out)
        except SystemExit as e:
            msg = str(e)
            expect("audio floor" in msg,
                   f"refusal names the fps-floor envelope entry, got:\n{msg}")
            expect("player's per-frame audio bound" not in msg,
                   f"the floor menu computation must not leak an "
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
                                  str(FFMPEG), dither=False)
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
                            ffmpeg, dither, dither_mode=None, retime=None,
                            **kw):
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
          "CHOSEN palette entry can pack to the NR $14 $E3 colour")
def t13_mixture_transparency_invariant():
    # The hazard region moved from near-white (the old cream $FE) to
    # near-magenta - bright red and blue, near-zero green - when NR $14
    # became $E3. The mixture path emits palette INDICES chosen from
    # all over the palette, so re-pin the invariant here, on the new
    # path and the new hazard region.
    rng = np.random.default_rng(8888)
    H, W = 64, 64
    base = rng.integers(230, 256, size=(H, W, 3)).astype(np.uint8)
    base[..., 1] = rng.integers(0, 26, size=(H, W)).astype(np.uint8)
    base[:, :20] = np.array([255, 0, 205], dtype=np.uint8)    # straddles both
    base[:, 20:32] = np.array([255, 0, 245], dtype=np.uint8)  # $E3 points
    pal = enc.display_palette(base)

    # Pre-dodge layer: build_palette_block scrubs byte0 $E3
    # unconditionally, so pack the RGB the encoder chose instead of
    # asserting on its output (same reasoning as t14's first case).
    def _byte0(rgb):
        r, g, b = int(rgb[0]), int(rgb[1]), int(rgb[2])
        return (r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6)

    pal_byte0 = [_byte0(pal[i]) for i in range(256)]
    for amp in (0.0, 0.25, 0.5, 1.0):
        for mode in enc.DITHER_MODES:
            idx, dec = enc.dither_quantize(base, pal, amp, mode)
            used = set(np.unique(idx).tolist())
            bad = [i for i in used if pal_byte0[i] == 0xE3]
            expect(not bad,
                   f"amp {amp} mode {mode}: chose palette entries {bad} "
                   f"({[tuple(int(c) for c in pal[i]) for i in bad]}) that "
                   f"pack to $E3 - only build_palette_block's unconditional "
                   f"dodge would keep that off the wire, and it would be "
                   f"scoring a colour it never emits")
            for col in enc.TRANSP_COLLISION:
                hit = ((dec[..., 0] == col[0]) & (dec[..., 1] == col[1])
                       & (dec[..., 2] == col[2]))
                expect(not bool(hit.any()),
                       f"amp {amp} mode {mode}: emitted the excluded "
                       f"display colour {col}")
    # the whole palette, not just the used part, stays clean
    expect(not [i for i in range(256) if pal_byte0[i] == 0xE3],
           "display_palette chose an entry packing to $E3")


# =======================================================================
# Step 14: transparency-collision exclusion (pal9d, 2026-07-28;
# retargeted pal9t, 2026-08-07). The player keeps Layer 2 transparency
# ACTIVE during video with the global transparency colour NR $14;
# hardware transparency compares only the palette entry's first byte
# (RRRGGGBB, the 9th blue bit is not compared), so any emitted entry
# packing to that byte0 - originally the cream $FE, black punch-through
# in bright regions, seen on real hardware in the Big Buck Bunny demo -
# renders as transparent holes. NR $14 is now $E3; the live collision
# points are display colours (255,0,219) and (255,0,255), BOTH 9th-bit
# variants. The encoder excludes the two points from the representable
# lattice (nxv2enc TRANSP_COLLISION/TRANSP_REMAP in snap_to_lattice).
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
    """(block_index, entry_index) pairs whose wire byte0 == $E3 (the
    live NR $14 transparent colour - name kept from the original $FE
    check for a smaller diff, see the Step 14 header above)."""
    return [(bi, i) for bi, b in enumerate(blocks)
            for i in range(256) if b[2 * i] == 0xE3]


def _collect_pal_rgb(encode_fn):
    """Run encode_fn() with build_palette_block spied so every 24-bit
    RGB palette it is asked to pack is captured BEFORE its own byte0
    -1 dodge runs - i.e. what the encoder's colour selection actually
    chose, not what reached the wire. build_palette_block's dodge
    (9efd280) is unconditional and independent of TRANSP_REMAP, so
    since the retarget it also scrubs $E3 off the WIRE even with
    TRANSP_REMAP disabled - a wire-byte negative control can no longer
    prove the lattice exclusion bites (see the two t14 wire cases
    below). This is the layer where it still can: it inspects what the
    encoder offered to build_palette_block, not what build_palette_block
    did about it. Returns (result, list-of-pal_256x3-copies)."""
    calls = []
    orig = enc.build_palette_block

    def spy(pal_256x3):
        calls.append(np.array(pal_256x3, copy=True))
        return orig(pal_256x3)

    enc.build_palette_block = spy
    try:
        result = encode_fn()
    finally:
        enc.build_palette_block = orig
    return result, calls


def _transp_rgb_hits(pal_rgb_calls):
    """TRANSP_COLLISION 24-bit RGB entries found across captured
    pre-dodge palettes - the lattice-exclusion-specific hit, as opposed
    to _fe_entries' wire-byte check."""
    hits = []
    collision = set(enc.TRANSP_COLLISION)
    for ci, pal in enumerate(pal_rgb_calls):
        for i in range(pal.shape[0]):
            rgb = tuple(int(c) for c in pal[i])
            if rgb in collision:
                hits.append((ci, i, rgb))
    return hits


def _near_white_gradient(N, h, w):
    """Magenta hazard gradient clip (R=255, G=0, blue ramping through
    the 182/219/255 lattice levels, slowly drifting so it is a real
    moving clip) - slams the palette straight into the two NR $14 = $E3
    collision points (255,0,219)/(255,0,255). Name kept from the
    original near-white ($FE) generator for a smaller diff - the
    hazard region itself moved from near-white to near-magenta when NR
    $14 became $E3. The ramp is x-only, so any frame height hits the
    same lattice points."""
    xx = np.arange(w, dtype=np.float32)[None, :]
    orig = np.empty((N, h, w, 3), dtype=np.uint8)
    for i in range(N):
        ramp = 182.0 + (xx + i * 4.0) % w * (73.0 / w)
        orig[i, ..., 0] = 255
        orig[i, ..., 1] = 0
        orig[i, ..., 2] = np.clip(ramp, 0, 255).astype(np.uint8)
    return orig


@case(14, "no $E3-byte0 palette entry survives an encode of a magenta-hazard gradient clip")
def t14_no_transparency_collision_on_wire():
    # The magenta-hazard gradient hits the two $E3 collision lattice
    # points against the pre-fix encoder logic (display_palette's
    # median-cut snap and dithered-composite refill both land there).
    # The negative control below confirms the clip still hits them
    # with the lattice exclusion disabled.
    N, h, w = 12, 192, 256
    orig = _near_white_gradient(N, h, w)
    chg, po = _synth_clip(orig)

    def do_encode():
        result = enc.encode_clip(orig, chg, po, w, h, 25.0)
        buf = _build_vid(result, w, h)
        return buf

    def encode_and_scan(tag, buf):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / f"transp_{tag}.vid"
            p.write_bytes(buf)
            blocks = _collect_pal_blocks(p)
        expect(len(blocks) >= 1, "encode emitted no palette block at all")
        return blocks

    buf, pal_calls = _collect_pal_rgb(do_encode)
    hits = _fe_entries(encode_and_scan("fixed", buf))
    expect(hits == [], f"palette entries with byte0 $E3 on the wire: {hits}")
    rgb_hits = _transp_rgb_hits(pal_calls)
    expect(rgb_hits == [], f"encoder selected the excluded collision "
           f"colour(s) internally, before the wire dodge: {rgb_hits}")

    # Negative control: disable the lattice exclusion and confirm the
    # same clip does select a collision colour internally, proving this
    # case bites rather than passing vacuously. build_palette_block's
    # own byte0 dodge still scrubs $E3 off the wire either way, so the
    # control checks the pre-dodge RGB selection, which only the
    # lattice exclusion guards.
    saved = enc.TRANSP_REMAP
    try:
        enc.TRANSP_REMAP = {}
        control_buf, control_pal_calls = _collect_pal_rgb(do_encode)
        control_wire_hits = _fe_entries(encode_and_scan("prefix", control_buf))
    finally:
        enc.TRANSP_REMAP = saved
    control_rgb_hits = _transp_rgb_hits(control_pal_calls)
    expect(control_rgb_hits != [], "negative control: pre-fix lattice "
           "must select an excluded collision colour internally for "
           "this clip (content no longer slams the collision points - "
           "test needs re-arming)")
    expect(control_wire_hits == [], "build_palette_block's own byte0 "
           "dodge must still keep $E3 off the wire even with the "
           "lattice exclusion disabled - the two mechanisms must not "
           "fight")


@case(14, "direct-serve path - same clip through _encode_direct, zero $E3-byte0 entries")
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

    def do_encode(tag):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / f"transp_direct_{tag}.vid"
            report = enc._encode_direct(ex, w, h, 25.0, p)
            expect(report.mode == "direct", "direct-serve report mode")
            return p.read_bytes()

    def scan(buf):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "transp_direct_scan.vid"
            p.write_bytes(buf)
            blocks = _collect_pal_blocks(p)
        expect(len(blocks) >= 1, "direct encode emitted no palette block at all")
        return blocks

    buf, pal_calls = _collect_pal_rgb(lambda: do_encode("fixed"))
    hits = _fe_entries(scan(buf))
    expect(hits == [],
           f"direct-serve palette entries with byte0 $E3 on the wire: {hits}")
    rgb_hits = _transp_rgb_hits(pal_calls)
    expect(rgb_hits == [], f"direct-serve encoder selected the excluded "
           f"collision colour(s) internally, before the wire dodge: {rgb_hits}")

    # Negative control: see t14's first case for why build_palette_block's
    # dodge doesn't invalidate this.
    saved = enc.TRANSP_REMAP
    try:
        enc.TRANSP_REMAP = {}
        control_buf, control_pal_calls = _collect_pal_rgb(lambda: do_encode("prefix"))
        control_wire_hits = _fe_entries(scan(control_buf))
    finally:
        enc.TRANSP_REMAP = saved
    control_rgb_hits = _transp_rgb_hits(control_pal_calls)
    expect(control_rgb_hits != [], "negative control: pre-fix lattice "
           "must select an excluded collision colour internally through "
           "the direct path too (clip no longer slams the collision "
           "points - test needs re-arming)")
    expect(control_wire_hits == [], "build_palette_block's own byte0 "
           "dodge must still keep $E3 off the direct-serve wire even "
           "with the lattice exclusion disabled - the two mechanisms "
           "must not fight")


@case(14, "lattice exclusion - representable set excludes exactly the two collision points")
def t14_lattice_exclusion_set():
    levels = enc.LATTICE_EXP3.tolist()
    full = np.array([(r, g, b) for r in levels for g in levels for b in levels],
                    dtype=np.uint8)
    expect(full.shape == (512, 3), "full lattice must be 8x8x8")

    def byte0(v):
        return (int(v[0]) & 0xE0) | ((int(v[1]) >> 3) & 0x1C) | (int(v[2]) >> 6)

    # The full lattice holds exactly two byte0==$E3 points - the
    # exclusion set matches the collision set, no over-exclusion.
    fe_points = {tuple(int(c) for c in v) for v in full if byte0(v) == 0xE3}
    expect(fe_points == set(enc.TRANSP_COLLISION),
           f"byte0 $E3 lattice points {fe_points} != TRANSP_COLLISION")

    snapped = enc.snap_to_lattice(full)
    moved = {tuple(int(c) for c in v)
             for v in full[np.any(snapped != full, axis=1)]}
    expect(moved == set(enc.TRANSP_COLLISION),
           f"snap moved {moved}, expected exactly the two collision points")
    rep = {tuple(int(c) for c in v) for v in snapped}
    expect(rep == {tuple(int(c) for c in v) for v in full} - set(enc.TRANSP_COLLISION),
           "representable set must be the full lattice minus the two collision points")
    expect(all(byte0(v) != 0xE3 for v in rep),
           "a representable lattice point still packs to byte0 $E3")
    # Idempotence: the representable set is a fixed point of the snap.
    expect((enc.snap_to_lattice(snapped) == snapped).all(),
           "snap must be idempotent on the representable set")

    # Replacements: the pair collides because both blue-axis levels
    # (219, 255) pack to the same byte0 blue subfield (see the
    # TRANSP_COLLISION header comment in nxv2enc.py). (255,0,219) still
    # has a blue-axis neighbour below it, so it moves there exactly as
    # the old $FE remap moved its lower point down. (255,0,255) sits at
    # the TOP of the blue axis with no upward neighbour - unlike the
    # old pair - so it moves on the GREEN axis instead, to a distinct
    # target rather than collapsing onto (255,0,182) too.
    expect(enc.TRANSP_REMAP == {(255, 0, 219): (255, 0, 182),
                                (255, 0, 255): (255, 36, 255)},
           f"unexpected remap table {enc.TRANSP_REMAP}")
    lo_src, lo_dst = (255, 0, 219), (255, 0, 182)
    hi_src, hi_dst = (255, 0, 255), (255, 36, 255)
    expect(enc.TRANSP_REMAP[lo_src] == lo_dst,
           "lower collision point must move down the blue axis")
    expect(lo_dst[:2] == lo_src[:2],
           "lower point's remap must stay on the blue axis (R, G unchanged)")
    expect(abs(lo_dst[2] - lo_src[2]) <= 37,
           "lower point's remap must move at most one lattice bin")
    expect(enc.TRANSP_REMAP[hi_src] == hi_dst,
           "upper collision point must move on the green axis (no blue headroom)")
    expect(hi_dst[0] == hi_src[0] and hi_dst[2] == hi_src[2],
           "upper point's remap must keep red and blue at the lattice ceiling")
    expect(abs(hi_dst[1] - hi_src[1]) <= 37,
           "upper point's remap must move at most one lattice bin")
    expect(lo_dst != hi_dst,
           "remap targets must remain distinct - no collapse onto one lattice colour")
    for dst in (lo_dst, hi_dst):
        expect(dst in rep, f"replacement {dst} not representable")


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
    # 256x128 at 25 fps is inside the direct-serve wire envelope
    # (256x135 at-rate); 1 s keeps both legs cheap.
    with tempfile.TemporaryDirectory() as td:
        reps = {}
        for tag, direct in (("direct", True), ("streaming", False)):
            rp = Path(td) / f"kp_{tag}.json"
            with contextlib.redirect_stdout(io.StringIO()):
                enc.encode(str(SINTEL), str(Path(td) / f"kp_{tag}.vid"),
                           shape=(256, 128), fps=25.0, duration="1",
                           ffmpeg=str(FFMPEG), direct=direct,
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

def _synth_ex(orig, fps=25.0):
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
    abytes_pad = enc.audio_layout(fps, 2)[3]
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
    if not BBB.exists() or not FFMPEG.exists():
        skip("demo source or ffmpeg not available")
    # A content-limited clip must keep its budget ceiling - descending
    # would be pure quality loss for negligible supply gain. This
    # operating point is re-based against the auto-budget model each
    # time the model changes; the premise assertion below catches drift.
    # RE-BASED 2026-09-15 for the trailing-chunk T model: Sintel 256x152
    # 5 s fell to util 0.891, under the 0.90 target, so that clip was no
    # longer content-limited at all (the search accepted the ceiling on
    # probe 1 and plateau read False). Big Buck Bunny 256x152 5 s is the
    # replacement and demonstrates the flat region outright - budgets
    # 1.00 and 0.95 both measure util 0.976, so a 5% cut buys exactly no
    # supply relief.
    ex = enc._extract_source(str(BBB), 256, 152, 25.0, "00:00:00", "5.0",
                              str(FFMPEG), 0.5)
    search = enc.auto_stream_budget(ex, 256, 152, 25.0, dither_amp=0.5)
    expect(not search["resident"], "5 s of BBB at 256x152 must exceed the resident pool")
    expect(search["plateau"], "this clip is content-limited - the search must say so")
    # ...and by the SLOPE test, not auto_stream_budget's one-probe
    # fallback (plateau = not at_target), which reports the same flag
    # without ever measuring a flat region.
    expect(len(search["probes"]) >= 2,
           f"the plateau must be measured across at least two probes, got {search['probes']}")
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
# Step 18: adaptive tile ladder. Per bound frame, walk rungs fine -> coarse
# and keep the finest admissible one (replaces a fixed-tile spend and the
# sqrt(err2) band-importance weight with raw err2).
#
# Two invariants a finer rung must not violate:
#   - WHOLE-LINE FLOOR. A rung finer than one paint-order line would split
#     a row/column into independently-scheduled fragments, so rungs walk
#     whole lines only (1, 2, 4 = quarter/half/whole band).
#   - SUPPLY PRESERVATION. Byte spend guards the wire but not decode-T; a
#     finer rung is admissible only if the gate's busy+wire arithmetic
#     does not price it above the coarsest rung.
#
# These cases pin: the rungs and constants, the whole-line floor, the err2
# weight ordering, spend/supply preservation, and that encode_clip drives
# the priced ladder end to end.
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
    # surface with scattered changed streaks (one big uniform block never
    # makes the ladder adapt - the rungs then differ only in where they
    # cut the same run), scheduled at a spread of caps so different rungs
    # win.
    #
    # FIXTURE RE-BASED at the pal9l copy-threshold correction: the
    # re-priced copy term (copy_dma_min 81 + copy_dma_path_t) raised the
    # modeled decode-T of fragmented streams, so on the old fixture (ten
    # 200-3000 px streaks) NO bound cap let a finer rung survive the
    # supply-preservation guard any more and the diversity premise below
    # went degenerate. Forty SHORT streaks (30-200 px) give the finer
    # rungs real wire to save (a coarse band drags whole runs of
    # unchanged noise along), which is the content class the ladder
    # exists for - verified: the caps below resolve to rungs {1024, 512}
    # under the new coefficients, all of them bound region frames.
    rng = np.random.default_rng(2002)
    n = 256 * 192
    prev = rng.integers(0, 256, size=n, dtype=np.uint8)
    target = prev.copy()
    for _ in range(40):
        a = int(rng.integers(0, n - 200))
        ln = int(rng.integers(30, 200))
        target[a:a + ln] = rng.integers(0, 256, size=ln, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    lad = enc.tile_ladder_for(1024)
    price = _price_for(256, 192)
    seen = set()
    for cap_b, cap_t in ((1500, None), (3000, None), (4000, None),
                         (5000, 60000), (5000, None), (5000, 300000)):
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
    # A finer ladder rung must not raise mean supply cost above the fixed
    # band scheduler's, or the auto-budget search answers by cutting the
    # derived budget (regressed on fixture 007). Measures the mean both
    # ways over a real starved encode.
    width, height = 256, 192          # MODE-0
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


# =======================================================================
# Step 19: supply-slack knob (--tile-slack), opt-in, default off.
# =======================================================================
# The step-18 ladder is supply-neutral and buys little on its own; an
# opt-in per-title knob lets a title trade supply for tile granularity
# when the content rewards it, since the right value is content-dependent.
#
# The knob relaxes rule (b), the supply-preservation test, and nothing
# else. These cases pin, in order:
#   - the constants, the default (off), and the cap's derivation - the cap
#     is exactly the auto-budget margin, so knob 1.0 lands the worst case
#     on the refusal line and the knob cannot express more;
#   - the whole-line floor is unreachable at every knob value, both in the
#     ladder the encoder builds and in what encode_delta will accept;
#   - default-off really is byte-for-byte today's encoder;
#   - the knob moves the supply test only, monotonically;
#   - the realised cost is bounded by the headroom the knob is quoted in;
#   - the supply gate still refuses rather than shipping an unplayable
#     file, and the knob is nowhere in the gate's own arithmetic;
#   - the CLI/kit plumbing, including the sidecar arg hash.
# =======================================================================


def _slack_clip(width, height, nframes=20, seed=1901, band=50, step=7):
    """A starved synthetic streaming clip on the given shape - the same
    recipe the step-18 cases use, factored out because three cases here
    need one."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:height, 0:width]
    base = np.stack([(xx * 255 // width).astype(np.uint8),
                     (yy * 255 // height).astype(np.uint8),
                     np.full((height, width), 70, dtype=np.uint8)], axis=-1)
    frames = []
    for i in range(nframes):
        f = base.copy()
        y = 10 + (i * step) % (height - band - 20)
        f[y:y + band, :, :] = rng.integers(0, 256, size=(band, width, 3),
                                           dtype=np.uint8)
        frames.append(f)
    orig = np.stack(frames)
    chg, po_ceil = _synth_clip(orig)
    return orig, chg, po_ceil


@case(19, "supply-slack knob - constants, DEFAULT OFF, and the cap is exactly the auto-budget margin")
def t19_slack_constants():
    expect(enc.TILE_SLACK_DEFAULT == 0.0,
           f"the knob must default to OFF, got {enc.TILE_SLACK_DEFAULT}")
    expect(enc.TILE_SUPPLY_SLACK == 0.0,
           f"the module default slack must stay 0.0, got {enc.TILE_SUPPLY_SLACK}")
    expect(enc.TILE_SLACK_MAX == 1.0,
           f"the cap is one whole headroom, got {enc.TILE_SLACK_MAX}")
    expect(enc.STREAM_CEILING_UTIL == 1.0,
           f"the gate's refusal line is 1.00, got {enc.STREAM_CEILING_UTIL}")
    # DEFAULT OFF resolves to exactly zero - not nearly zero. Anything
    # else would perturb ceil_ms and change today's output.
    expect(enc.tile_slack_rel(None) == 0.0, "None must resolve to 0.0 exactly")
    expect(enc.tile_slack_rel(0.0) == 0.0, "0.0 must resolve to 0.0 exactly")
    expect(enc.tile_slack_rel(enc.TILE_SLACK_DEFAULT) == 0.0,
           "the default must resolve to 0.0 exactly")

    # THE CAP'S DERIVATION, checked as arithmetic rather than quoted as a
    # number. frame_supply_ms IS the gate's per-frame busy+wire term, so a
    # per-frame relative allowance s raises the clip mean by at most s x u,
    # u <= the operating point. At the target that worst case is
    #   target x (1 + knob x headroom)
    # and at knob = TILE_SLACK_MAX it must land ON the refusal line - the
    # entire margin the target holds back, and not one part more.
    head = enc.tile_slack_headroom()
    expect(abs(head - (enc.STREAM_CEILING_UTIL - enc.AUTO_BUDGET_TARGET_UTIL)
               / enc.AUTO_BUDGET_TARGET_UTIL) < 1e-15,
           f"headroom must be (ceiling - target)/target, got {head}")
    worst = enc.AUTO_BUDGET_TARGET_UTIL * (
        1.0 + enc.tile_slack_rel(enc.TILE_SLACK_MAX))
    expect(abs(worst - enc.STREAM_CEILING_UTIL) < 1e-12,
           f"the cap must land the worst case exactly on the refusal line, "
           f"got {worst}")
    expect(enc.tile_slack_rel(0.5) * 2.0 == enc.tile_slack_rel(1.0)
           or abs(enc.tile_slack_rel(0.5) * 2.0
                  - enc.tile_slack_rel(1.0)) < 1e-15,
           "the knob must be linear in headroom units")

    # A raised --budget-target leaves LESS margin in the pot, so one unit
    # of slack must be worth less - the knob is quoted against the target
    # actually in force, not against a baked constant.
    expect(enc.tile_slack_rel(1.0, 0.95) < enc.tile_slack_rel(1.0, 0.90),
           "a higher budget target must shrink what one unit of slack buys")
    expect(abs(0.95 * (1.0 + enc.tile_slack_rel(1.0, 0.95))
               - enc.STREAM_CEILING_UTIL) < 1e-12,
           "the cap must track an overridden target too")

    # Out of range RAISES - it does not clamp. A clamp would let a
    # nonsense request (5.0) pass silently as the maximum.
    for bad in (-0.01, 1.01, 5.0):
        try:
            enc.tile_slack_rel(bad)
        except ValueError as exc:
            expect("[0.0, 1.0]" in str(exc),
                   f"the refusal must name the cap: {exc}")
        else:
            expect(False, f"tile slack {bad} must be refused, not clamped")


@case(19, "supply-slack knob - THE WHOLE-LINE FLOOR IS UNREACHABLE at every knob value")
def t19_whole_line_unreachable():
    # The floor is rule (a) and it is PERMANENT. Sub-line rungs caused BOTH
    # the budget collapse (fragmented runs cost 37% more decode-T, charged
    # by the gate, paid for by the auto-budget search in wire) and the
    # widened paint window (write span 58% -> 70% of a LIVE surface against
    # a free-running frame clock). The knob relaxes the SUPPLY rule; it is
    # not an input to the ladder at all, and this case says so three ways.
    knobs = (0.0, 0.05, 0.15, 0.25, 0.5, 0.75, enc.TILE_SLACK_MAX)

    # (1) The ladder itself is a pure function of the shape. tile_ladder_for
    # takes no slack argument, and every rung it yields is a whole number of
    # paint-order lines on every shape.
    expect("slack" not in inspect.signature(enc.tile_ladder_for).parameters,
           "the ladder builder must not take a slack argument")
    for shape in ("full", "classic", "16:9", "scope", "classic-wide"):
        w, h = enc.resolve_shape(shape)
        cm = (w == 320)
        line = h if cm else w
        band = enc.default_tile_px(w * h, width=w, height=h, column_major=cm)
        lad = enc.tile_ladder_for(band)
        expect(all(g >= line and g % line == 0 for g in lad),
               f"{shape}: rung splits a paint-order line ({line} B): {lad}")

    # (2) encode_delta REFUSES a sub-line ladder outright - at every knob
    # value, including the cap. This is the guard that makes the floor an
    # invariant of the code rather than of one call site.
    n = 4096
    rng = np.random.default_rng(1901)
    prev = np.zeros(n, dtype=np.uint8)
    target = prev.copy()
    target[100:2000] = rng.integers(1, 256, size=1900, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    price = _price_for(256, 192)
    good = enc.tile_ladder_for(1024)
    for knob in knobs:
        rel = enc.tile_slack_rel(knob)
        for bad in ((32, 64, 128, 256, 1024),      # the pal9j ladder
                    (128, 256, 1024),              # half a line
                    (256, 384, 1024)):             # 1.5 lines
            try:
                enc.encode_delta(target, err2, 300, 40000, surface_flat=prev,
                                 tile_ladder=bad, supply_px=price,
                                 supply_slack=rel)
            except ValueError as exc:
                expect("WHOLE number of paint-order lines" in str(exc),
                       f"the refusal must name the floor: {exc}")
            else:
                expect(False, f"sub-line ladder {bad} must be refused at "
                              f"--tile-slack {knob}")
        # ... and the legal ladder still works at that same knob value.
        r = enc.encode_delta(target, err2, 300, 40000, surface_flat=prev,
                             tile_ladder=good, supply_px=price,
                             supply_slack=rel)
        expect(int(r[5].split("@")[-1]) in good,
               f"knob {knob}: chosen rung not on the ladder ({r[5]})")

    # (3) End to end on the shape that regressed: at the CAP, every
    # budget-bound frame still names a whole-line rung.
    width, height = 256, 192
    orig, chg, po_ceil = _slack_clip(width, height)
    band = enc.default_tile_px(width * height, width=width, height=height,
                               column_major=False)
    lad = enc.tile_ladder_for(band)
    res = enc.encode_clip(orig, chg, po_ceil, width, height, 25.0,
                          cap_bytes_frac=0.03, budget_scale=0.12,
                          tile_slack=enc.tile_slack_rel(enc.TILE_SLACK_MAX))
    bound = 0
    for m, bind in zip(res["per_frame"]["mode"], res["per_frame"]["binding"]):
        if bind != "budget":
            continue
        bound += 1
        g = int(m.split("@")[-1].split(":")[0])
        expect(g in lad, f"rung {g} is not on this shape's ladder {lad}")
        expect(g % width == 0,
               f"AT THE CAP, rung {g} splits a {width}px paint-order line "
               f"(mode {m}) - the floor must not be reachable from the knob")
    expect(bound > 0, "fixture did not produce a budget-bound frame")


@case(19, "supply-slack knob - DEFAULT OFF is byte-for-byte today's encoder")
def t19_default_off_identical():
    # The knob ships DEFAULT OFF and must not change ANY current output.
    # At slack 0 the supply ceiling is coarse_ms * 1.0 - an exact float
    # identity, not an approximation - so the comparison below is a true
    # byte identity and not a tolerance.
    width, height = 256, 192
    orig, chg, po_ceil = _slack_clip(width, height, seed=1902)
    runs = {}
    for tag, slack in (("omitted", None), ("zero", 0.0),
                       ("resolved", enc.tile_slack_rel(0.0)),
                       ("default", enc.tile_slack_rel(enc.TILE_SLACK_DEFAULT))):
        runs[tag] = enc.encode_clip(orig, chg, po_ceil, width, height, 25.0,
                                    cap_bytes_frac=0.03, budget_scale=0.12,
                                    tile_slack=slack)
    ref = runs["omitted"]
    for tag, res in runs.items():
        expect([bytes(p) for p in res["payloads"]]
               == [bytes(p) for p in ref["payloads"]],
               f"tile_slack={tag} changed the emitted payloads - the knob's "
               f"default MUST be a no-op")
        expect(res["per_frame"]["mode"] == ref["per_frame"]["mode"],
               f"tile_slack={tag} changed the per-frame modes")
    # Same at the encode_delta level, where the ceiling arithmetic lives.
    n = 4096
    rng = np.random.default_rng(1903)
    prev = np.zeros(n, dtype=np.uint8)
    target = prev.copy()
    target[100:2600] = rng.integers(1, 256, size=2500, dtype=np.uint8)
    err2 = (target.astype(np.float32) - prev.astype(np.float32)) ** 2
    lad = enc.tile_ladder_for(1024)
    price = _price_for(width, height)
    a = enc.encode_delta(target, err2, 700, 60000, surface_flat=prev,
                         tile_ladder=lad, supply_px=price)
    b = enc.encode_delta(target, err2, 700, 60000, surface_flat=prev,
                         tile_ladder=lad, supply_px=price, supply_slack=0.0)
    expect(bytes(a[7]) == bytes(b[7]) and a[3] == b[3] and a[5] == b[5],
           "supply_slack=0.0 must be identical to omitting it entirely")


@case(19, "supply-slack knob - it relaxes the SUPPLY test only, and monotonically")
def t19_relaxes_supply_only():
    # A real-ish bound mode-0 frame (the step-18 recipe), scheduled over a
    # spread of caps. Across the whole knob range the rule must stay the
    # rule: whatever rung is chosen still passes SPEND and PICTURE, only
    # the supply ceiling moves, and a bigger knob never picks a COARSER
    # rung than a smaller one.
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
    knobs = (0.0, 0.1, 0.25, 0.5, 1.0)
    relaxed = 0
    checked = 0
    for cap_b in range(1200, 9000, 340):
        costs = _ladder_costs(target, err2, prev, cap_b, None, lad)
        resid = _ladder_residuals(target, err2, prev, cap_b, None, lad)
        picks = []
        for knob in knobs:
            rel = enc.tile_slack_rel(knob)
            r = enc.encode_delta(target, err2, cap_b, None, surface_flat=prev,
                                 tile_ladder=lad, supply_px=price,
                                 supply_slack=rel)
            got = int(r[5].split("@")[-1])
            want = _expected_rung(costs, lad, enc.TILE_SPEND_FRAC, price,
                                  rel, resid)
            expect(got == want,
                   f"cap {cap_b} knob {knob}: chose {got}, the rule says "
                   f"{want} (costs {costs})")
            # SPEND and PICTURE are NOT relaxed by the knob - any rung it
            # takes still satisfies both at every value. (The fallback IS
            # the coarsest rung - today's fixed band scheduler - and is
            # exempt by construction: it is the reference the other two
            # tests are stated against, not a candidate that passed them.)
            if got != lad[-1]:
                best = max(b for b, _ in costs.values())
                floor_b = max(costs[lad[-1]][0], enc.TILE_SPEND_FRAC * best)
                expect(costs[got][0] >= floor_b,
                       f"cap {cap_b} knob {knob}: rung {got} strands wire - "
                       f"the knob must not relax spend preservation")
                expect(resid[got] <= resid[lad[-1]],
                       f"cap {cap_b} knob {knob}: rung {got} leaves MORE "
                       f"residual than the band - the knob must not relax "
                       f"the picture test")
            picks.append(got)
            checked += 1
        # Monotone: more slack can only buy a FINER (or equal) rung.
        expect(picks == sorted(picks, reverse=True),
               f"cap {cap_b}: rung choice must be non-increasing in slack, "
               f"got {dict(zip(knobs, picks))}")
        if picks[0] != picks[-1]:
            relaxed += 1
    expect(checked > 0, "no candidate frames scheduled")
    expect(relaxed > 0,
           "the knob never changed the outcome on this fixture - it would be "
           "unfalsifiable here")
    print(f"  [slack] {relaxed} of {len(range(1200, 9000, 340))} caps took a "
          f"finer rung once the supply test was relaxed")


@case(19, "supply-slack knob - the realised cost is bounded by the headroom it is quoted in")
def t19_cost_is_bounded():
    # THIS IS THE CAP'S ARITHMETIC, measured over a real encode rather
    # than argued. frame_supply_ms is the gate's own per-frame busy+wire
    # term, so the clip's MEAN of it is the utilisation numerator (less
    # the invariant audio pad). If the mean at knob k never exceeds
    # (1 + k x headroom) x the mean at knob 0, then a clip sitting at the
    # 0.90 target cannot be pushed past 1.00 by any legal knob value -
    # which is exactly what the cap claims.
    width, height = 320, 256          # mode-1, the shape the owner's own
    orig, chg, po_ceil = _slack_clip(  # approved A/B ran on
        width, height, nframes=18, seed=1904, band=60, step=9)
    price = _price_for(width, height)

    def mean_supply_ms(res):
        pf = res["per_frame"]
        return sum(enc.frame_supply_ms(len(p), t, price)
                   for p, t in zip(res["payloads"], pf["t"])) / len(pf["t"])

    def run(knob):
        return enc.encode_clip(orig, chg, po_ceil, width, height, 25.0,
                               cap_bytes_frac=0.03, budget_scale=0.12,
                               tile_slack=enc.tile_slack_rel(knob))

    base = run(0.0)
    m0 = mean_supply_ms(base)
    for knob in (0.15, 0.5, enc.TILE_SLACK_MAX):
        res = run(knob)
        m = mean_supply_ms(res)
        rel = enc.tile_slack_rel(knob)
        expect(m <= m0 * (1.0 + rel) + 1e-9,
               f"knob {knob}: mean supply {m:.4f} ms/frame exceeds the bound "
               f"{m0 * (1.0 + rel):.4f} - the cap's derivation does not hold, "
               f"so a legal knob value could push a title past the ceiling")
        # ... and it never throws wire away to stay under that bound.
        expect(sum(len(p) for p in res["payloads"])
               >= sum(len(p) for p in base["payloads"]),
               f"knob {knob} spent FEWER bytes than the default - the knob "
               f"buys granularity, it must not trade wire for it")
    # The worst legal landing point, stated: a clip at the target cannot
    # reach the refusal line from inside the cap.
    expect(enc.AUTO_BUDGET_TARGET_UTIL
           * (1.0 + enc.tile_slack_rel(enc.TILE_SLACK_MAX))
           <= enc.STREAM_CEILING_UTIL + 1e-12,
           "the cap must not admit a value that lands past the refusal line")


@case(19, "supply-slack knob - the supply gate still REFUSES; the knob is nowhere in its arithmetic")
def t19_refusal_path_intact():
    # BOUNDED SO IT CANNOT SHIP AN UNPLAYABLE FILE. The margin the knob
    # spends is the same margin that protects fixture 008 - the file that
    # underran 76% of its frames when the gate was optimistic. The knob is
    # therefore forbidden anywhere in the gate's own arithmetic, and the
    # existing refusal path must still fire under it.
    gate = inspect.getsource(enc.stream_supply_check)
    for word in ("slack", "tile_slack", "TILE_SUPPLY_SLACK", "TILE_SLACK"):
        expect(word not in gate,
               f"the supply gate must not know about the knob ({word} found) "
               f"- the gate is the backstop and the knob must not move it")
    src = inspect.getsource(enc.encode)
    expect('if stream_stats["utilization"] > 1.0:' in src
           and "raise SystemExit(" in src,
           "encode() must still refuse an over-ceiling stream outright")
    # The cost line is printed BEFORE the gate, so a refused encode still
    # tells the author what the knob spent.
    expect(src.index("tile_slack_line(") < src.index(
        'if stream_stats["utilization"] > 1.0:'),
           "the tile-slack cost line must print before the gate's refusal")
    # The at-capacity WARNING band (0.90-1.00) is the margin the knob
    # spends, so a warning raised while the knob is set must name the
    # knob - not tell the author to drop a --stream-budget he never set.
    expect("lower or drop --tile-slack" in src,
           "the at-capacity warning must name --tile-slack when it is what "
           "is spending the margin")

    if not BBB.exists() or not FFMPEG.exists():
        skip("demo source or ffmpeg not available")
    import contextlib
    import io
    # A genuinely infeasible operating point (full 320x256 @25 at a PINNED
    # --stream-budget 1.00, over the resident pool) must be refused with
    # the SAME message at the cap as at the default - the knob cannot buy
    # its way past the gate.
    with tempfile.TemporaryDirectory() as td:
        for knob in (None, enc.TILE_SLACK_MAX):
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    enc.encode(str(BBB), str(Path(td) / "refused.vid"),
                               shape=(320, 256), fps=25.0,
                               start="00:00:03", duration="2.0",
                               ffmpeg=str(FFMPEG), stream_budget=1.0,
                               tile_slack=knob)
            except SystemExit as exc:
                expect("cannot stream" in str(exc),
                       f"knob {knob}: expected the gate's refusal, got {exc}")
            else:
                expect(False, f"knob {knob}: an over-ceiling stream must be "
                              f"REFUSED, not written")
            if knob:
                expect("tile-slack:" in buf.getvalue(),
                       f"a refused encode must still report the knob's cost: "
                       f"{buf.getvalue()!r}")


@case(19, "supply-slack knob - report line, CLI plumbing, and the kit's sidecar arg hash")
def t19_cli_and_arg_hash():
    import hashlib
    import subprocess
    import re as _re

    # THE REPORT LINE. The knob spends margin, so the cost must be
    # visible: the slack as set, the utilisation reached, and what margin
    # is left. Same two-space style as auto_budget_line.
    stats = dict(utilization=0.9134)
    line = enc.tile_slack_line(0.15, stats)
    expect(line.startswith("  tile-slack: "),
           f"the report line must match the encoder's line style: {line!r}")
    expect("0.15" in line, "the line must name the slack that was set")
    expect("0.913" in line, "the line must name the utilisation reached")
    expect("0.087" in line, "the line must name the margin remaining")
    expect("1.00 refusal line" in line,
           "the line must name what the margin is measured to")
    for ch in ("—", "–"):
        expect(ch not in line, "no em/en dashes in encoder output")
    expect(enc.tile_slack_line(0.15, None).endswith("cost nothing"),
           "a resident file has no gate, so the line must say so")

    # CLI: the option exists, is documented, is capped, and reaches the
    # encoder.
    help_out = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), "--help"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout.decode("utf-8", "replace")
    expect("--tile-slack" in help_out, "--tile-slack must appear in --help")
    for word in ("OPT-IN", "headroom", "CAP"):
        expect(word in help_out, f"--help must explain {word!r}")
    for bad in ("1.5", "-0.1"):
        r = subprocess.run(
            [sys.executable, str(LIB / "videnc.py"), str(SINTEL), "x.vid",
             "--tile-slack", bad, "--ffmpeg", str(FFMPEG)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        expect(r.returncode != 0, f"--tile-slack {bad} must be rejected")
        expect(b"--tile-slack must be in" in r.stdout + r.stderr,
               f"the rejection must name the cap for {bad}")
    cli = (LIB / "videnc.py").read_text(encoding="utf-8")
    expect("tile_slack=args.tile_slack" in cli,
           "videnc.py must pass --tile-slack through to nxv2enc.encode")

    # KIT: VIDOPTS/VIDOPTS_NNN pass through verbatim into the hashed
    # argument vector, so a --tile-slack override forces a re-encode of
    # that title and nothing else.
    ps1 = (ROOT / "authoring-kit" / "lib" / "video.ps1").read_text(encoding="utf-8")
    expect("--tile-slack" in ps1,
           "video.ps1 must document --tile-slack for VIDOPTS/VIDOPTS_NNN")
    m = _re.search(r"\$encoderGeneration = '([^']+)'", ps1)
    expect(m, "video.ps1 must carry an $encoderGeneration stamp")
    gen = m.group(1)

    def kit_hash(arg_list):
        return hashlib.md5(" ".join([gen] + arg_list).encode("utf-8")).hexdigest()[:8]

    base = ["--shape", "full", "--fps", "25"]
    expect(kit_hash(base) != kit_hash(base + ["--tile-slack", "0.15"]),
           "a --tile-slack override must move the sidecar hash")
    expect(kit_hash(base + ["--tile-slack", "0.15"])
           != kit_hash(base + ["--tile-slack", "0.25"]),
           "different --tile-slack values must hash differently")


# =======================================================================
# Step 20: motion-locked dither phase. The SP17 T5a offset-copy coding
# this was built for was WITHDRAWN on 2026-08-02 (owner ruling); the
# phase machinery stays because the identity it pins - phase (0,0) is
# byte-identical to the shipped dither - is what makes the default
# dither path provably unmoved.
# =======================================================================


@case(20, "motion-locked dither phase - phase 0 byte-identical, tile travels with content")
def t20_dither_phase():
    rng = np.random.default_rng(7)
    f = rng.integers(0, 256, (37, 53, 3), dtype=np.uint8)
    a = enc.ordered_dither(f, 0.5)
    expect(np.array_equal(a, enc.ordered_dither(f, 0.5, phase=(0, 0))),
           "phase (0,0) must be byte-identical to the shipped dither")
    expect(np.array_equal(a, enc.ordered_dither(f, 0.5, phase=None)),
           "phase None must be byte-identical to the shipped dither")
    # the tile MOVES WITH the content: shifting content and phase
    # together reproduces the same dither decisions on the overlap
    H, W = 64, 96
    dsx, dsy = 3, 2
    base = rng.integers(0, 256, (H, W, 3), dtype=np.uint8)
    shifted = enc._shift_clamp2d(base, dsy, dsx)
    d0 = enc.ordered_dither(base, 0.5)
    d1 = enc.ordered_dither(shifted, 0.5, phase=(dsx, dsy))
    expect(np.array_equal(d1[dsy:, dsx:], d0[:H - dsy, :W - dsx]),
           "a phase-locked dither of shifted content must equal the "
           "shifted dither of the original (the T5a prediction identity)")
    # mixture path: same phase law through dither_plan
    pal = enc.display_palette(base, colors=64)
    i0, _ = enc.dither_plan(base, pal, 0.5, "mixture")
    i1, _ = enc.dither_plan(shifted, pal, 0.5, "mixture", phase=(dsx, dsy))
    expect(np.array_equal(i1[dsy:, dsx:], i0[:H - dsy, :W - dsx]),
           "mixture plan must obey the same phase law")


# =======================================================================
# Step 21: SP17 W4 - keyframe-span peak pacing (T2/E5), keyframe
# cadence, and the local-mean trigger re-base.
# =======================================================================

W4_SHAPES = [(320, 256), (256, 192), (320, 192), (320, 144), (256, 144)]


def _kf_frame_supply_ms(L, first, width, height, abytes_pad, fps=25.0):
    """Modeled supply time of one keyframe-span chunk frame at the
    gate's own prices (decode busy + audio copy + SD wire)."""
    tc = enc.TMODEL_COEFFS
    af = tc["audio_factor"]
    clock = tc["clock_khz"]
    wire_eff = enc.SD_WIRE_BYTES_PER_MS * af
    b, t = enc.kf_chunk_cost(L, first)
    try:
        # a keyframe chunk frame is dense by construction (one long
        # copy at the cap) - the density-keyed model prices it at the
        # dense anchor
        r = enc.silicon_r(width, height, density=1.0)
    except TypeError:      # pre-density-key silicon_r (commit order)
        r = enc.silicon_r(width, height)
    busy = t * r / af / clock
    padded = ((b + 511) // 512) * 512
    audio_ms = abytes_pad * enc.AUDIO_COPY_T_PER_B / clock
    return busy + audio_ms + (abytes_pad + padded) / wire_eff, padded


@case(21, "W4 T2 - keyframe-span chunk frames fit the frame period (peak pacing bound)")
def t21_kf_peak_bound():
    fps, apad = 25.0, 1536   # stereo, the largest layout
    period = 1000.0 / fps
    expect(0.90 <= enc.KF_SPAN_PEAK_UTIL < 1.0,
           f"the peak bound must state a real margin under 1.00, got {enc.KF_SPAN_PEAK_UTIL}")
    for w, h in W4_SHAPES:
        for first in (True, False):
            L = enc.kf_chunk_budget_bytes(fps, first, w, h, apad)
            ms, padded = _kf_frame_supply_ms(L, first, w, h, apad, fps)
            expect(ms <= enc.KF_SPAN_PEAK_UTIL * period + 0.15,
                   f"{w}x{h} first={first}: kf chunk frame supply {ms:.2f} ms "
                   f"exceeds the {enc.KF_SPAN_PEAK_UTIL:.2f} x {period:.0f} ms bound")
            # the acceptance metric itself: WIRE time alone under the period
            wire_ms = (apad + padded) / (enc.SD_WIRE_BYTES_PER_MS
                                          * enc.TMODEL_COEFFS["audio_factor"])
            expect(wire_ms < period,
                   f"{w}x{h}: peak kf frame wire {wire_ms:.2f} ms >= period")
            # ... and the decode-T budget contract is still honoured
            expect(enc.kf_chunk_cost(L, first)[1]
                   <= enc.usable_budget_t(fps, w, h) * 0.98 + 1.0,
                   f"{w}x{h} first={first}: chunk decode T over the usable budget")
        # the plan still covers the surface exactly, first chunk first
        plan = enc.plan_kf_chunks(w * h, fps, w, h, apad)
        expect(sum(c[1] for c in plan) == w * h, "plan must cover raw bytes")
        expect(plan[0][2] and not any(f for _, _, f in plan[1:]),
               "exactly the first chunk is 'first'")
    # the DELTA byte cap is wire-bounded too (the 320x256 budget-1.0 hole:
    # 0.65 x raw = 53 KB of payload against a ~41 KB wire period)
    wc = enc.frame_wire_cap_bytes(fps, apad)
    expect(wc + apad <= enc.KF_SPAN_PEAK_UTIL * period
           * enc.SD_WIRE_BYTES_PER_MS * enc.TMODEL_COEFFS["audio_factor"] + 512,
           "frame_wire_cap_bytes must respect the peak wire bound")
    expect(wc < int(0.65 * 320 * 256),
           "the wire cap must actually bind the 320x256 byte cap at budget 1.0")
    # conservative default pad: omitting abytes_pad must never yield a
    # BIGGER chunk than the stereo layout's own pad at the same fps
    expect(enc.kf_chunk_budget_bytes(fps, False, 320, 256)
           <= enc.kf_chunk_budget_bytes(fps, False, 320, 256, 1024),
           "the default (stereo) pad must be the conservative direction")


def _w5_quiet_clip():
    """The cadence test clip: quiet, cut-free, tiny localized motion -
    3.2 s at 25 fps."""
    rng = np.random.default_rng(11)
    W, H, n = 256, 64, 80
    base = rng.integers(0, 256, (H, W, 3), dtype=np.uint8)
    orig = np.repeat(base[None], n, axis=0).copy()
    for i in range(n):        # tiny localized motion, no cuts, no drift
        orig[i, (i % H):(i % H) + 1, :8] = (i * 5) % 255
    chg = np.zeros(n); chg[1:] = 0.001
    po = np.array([enc.display_ceiling(orig[i]) for i in range(n)])
    lm = np.array([enc.display_ceilings(orig[i])[1] for i in range(n)])
    return orig, chg, po, lm, W, H


@case(21, "W5 - cadence rolling refresh: window honoured, 0 disables, tail guard, default pinned")
def t21_kf_cadence():
    expect(enc.KF_CADENCE_S_DEFAULT == 5.0,
           f"cadence default must be the measured free point 5.0 s, got {enc.KF_CADENCE_S_DEFAULT}")
    expect(0.0 < enc.KF_ROLL_SHARE <= 1.0,
           f"KF_ROLL_SHARE must be a real fraction of the byte cap, got {enc.KF_ROLL_SHARE}")
    orig, chg, po, lm, W, H = _w5_quiet_clip()

    r_off = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm, kf_cadence_s=0)
    expect("cadence" not in r_off["kf_triggers"], "cadence 0 must disable the trigger")
    expect(r_off["kf_roll_events"] == 0, "cadence 0 must disable the rolling refresh")

    r_1s = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm, kf_cadence_s=1.0)
    # W5: the cadence path emits NO keyframe any more - it rolls
    expect("cadence" not in r_1s["kf_triggers"],
           f"the cadence path must not emit keyframes (W5 roll), got {r_1s['kf_triggers']}")
    expect(len(r_1s["kf_span_ranges"]) == 1,
           f"only the start span may exist, got {r_1s['kf_span_ranges']}")
    expect(r_1s["kf_roll_events"] >= 2,
           f"a 1 s cadence over 3.2 quiet seconds must roll repeatedly, got "
           f"{r_1s['kf_roll_events']}")
    wins = r_1s["kf_roll_windows"]
    expect(len(wins) >= 2,
           f"rolls must COMPLETE on an unbound clip, got {wins} "
           f"(pending {r_1s['kf_roll_pending']})")
    # window honoured: a roll starts at least the window after the last ends
    for (s0, e0), (s1, e1) in zip(wins, wins[1:]):
        expect(s1 - e0 >= 25, f"roll started inside the window: end {e0} -> start {s1}")
    # tail guard: no roll is started that cannot nominally complete
    expect(wins[-1][1] < len(orig),
           "roll window must close inside the clip")

    # default (5 s) never engages inside a 3.2 s quiet clip
    r_def = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm)
    expect("cadence" not in r_def["kf_triggers"] and r_def["kf_roll_events"] == 0,
           f"default 5 s cadence must not engage inside 3.2 s, got "
           f"{r_def['kf_triggers']} / {r_def['kf_roll_events']} rolls")
    # ... and the default path is byte-identical to an explicit 5.0
    r_5 = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm, kf_cadence_s=5.0)
    expect([bytes(p) for p in r_def["payloads"]] == [bytes(p) for p in r_5["payloads"]],
           "default cadence must be exactly 5.0 s")


@case(21, "W5 - rolling refresh: NO full-keyframe frame in the window, full clean coverage")
def t21_kf_roll_coverage():
    orig, chg, po, lm, W, H = _w5_quiet_clip()
    r = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm,
                        kf_cadence_s=1.0, return_surfaces=True)
    wins = r["kf_roll_windows"]
    expect(len(wins) >= 1, f"at least one completed roll window, got {wins}")
    modes = r["per_frame"]["mode"]
    pf_bytes = r["per_frame"]["bytes"]
    cap = min(int(0.65 * W * H), enc.frame_wire_cap_bytes(25.0))
    hp = r["held_pal_final"]
    amp, dm = enc._dither_amp(None), enc._dither_mode(None)
    for s, e in wins:
        seg = modes[s:e + 1]
        # THE POINT OF THE FIX: a cadence window contains no single
        # full-keyframe frame - nothing that holds the visible picture
        expect(not any(m.startswith("kf") for m in seg),
               f"cadence window {s}-{e} must contain NO keyframe-span frame, got {seg}")
        expect(any(":roll" in m for m in seg),
               f"window {s}-{e} frames must carry the :roll tag, got {seg}")
        # budget honesty: roll frames obey the ordinary per-frame byte cap
        for i in range(s, e + 1):
            expect(pf_bytes[i] <= cap,
                   f"roll frame {i} spent {pf_bytes[i]} B over the {cap} B cap")
        # ... and full coverage: over the window, every surface position
        # comes to hold the FRESH (non-sticky) held-palette quantize of
        # the frame current when it was refreshed - verified against the
        # encoder's own decoded surfaces, not its bookkeeping counters
        covered = np.zeros(W * H, dtype=bool)
        for i in range(s, e + 1):
            fresh = enc.flatten_frame(
                enc.dither_quantize(orig[i], hp, amp, dm)[0], False)
            surf = enc.flatten_frame(r["surfaces"][i], False)
            covered |= (surf == fresh)
        expect(bool(covered.all()),
               f"window {s}-{e}: {int((~covered).sum())} of {W * H} positions "
               f"never reached a fresh-clean state")


@case(21, "W4 - drift/staleness triggers re-based on the 4x4 local-mean metric")
def t21_lm_trigger_rebase():
    # the re-derived thresholds (W4 corpus derivation - see the
    # STALE_LM_DB block in nxv2enc.py for the distribution table)
    expect(enc.STALE_LM_DB == 15.0,
           f"STALE_LM_DB must be the corpus-derived 15.0, got {enc.STALE_LM_DB}")
    expect((enc.DRIFT_LM_T, enc.DRIFT_LM_T_REFRACT) == (1.5, 3.0),
           f"DRIFT_LM thresholds must be the corpus-derived 1.5/3.0")
    # the local-mean metric itself: dither-like +/-1 checkerboard noise is
    # invisible to it (means cancel), a +8 uniform shift is fully charged
    rng = np.random.default_rng(4)
    a = rng.integers(8, 248, (64, 64, 3), dtype=np.uint8)
    noise = ((np.indices((64, 64)).sum(axis=0) % 2) * 2 - 1)[..., None]
    expect(enc.psnr_lm(a, (a.astype(np.int16) + noise).astype(np.uint8)) > 45.0,
           "psnr_lm must cancel zero-mean dither grain")
    shifted = np.clip(a.astype(np.int16) + 8, 0, 255).astype(np.uint8)
    expect(abs(enc.psnr_lm(a, shifted) - enc.psnr(a, shifted)) < 1.0,
           "psnr_lm must fully charge a structural (mean) shift")

    # STRUCTURAL FIRING CASE: whole-frame slow luminance drift with a
    # stable histogram and a starved budget - the decoded screen falls
    # ever further behind. The retired per-pixel bar could not see this
    # (achieved per-pixel PSNR tracks po_ceil through the dither
    # displacement); the lm deficit crosses STALE_LM_DB and must fire.
    W, H, n = 256, 64, 60
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    base = np.stack([120 + 60 * np.sin(xx * 0.2), 120 + 60 * np.sin(yy * 0.17),
                     120 + 60 * np.sin((xx + yy) * 0.11)], axis=2)
    orig = np.empty((n, H, W, 3), dtype=np.uint8)
    for i in range(n):
        orig[i] = np.clip(base + i * 1.5, 0, 255).astype(np.uint8)  # slow global rise
    chg = np.zeros(n)
    for i in range(1, n):
        d = np.abs(orig[i].astype(np.int16) - orig[i - 1].astype(np.int16)).max(axis=2)
        chg[i] = float((d > 10).mean())
    po = np.array([enc.display_ceiling(orig[i]) for i in range(n)])
    lm = np.array([enc.display_ceilings(orig[i])[1] for i in range(n)])
    r = enc.encode_clip(orig, chg, po, W, H, 25.0, po_ceil_lm=lm,
                        budget_scale=0.05, kf_cadence_s=0)
    fired = (r["kf_triggers"].get("staleness", 0)
             + r["kf_triggers"].get("drift", 0)
             + r["kf_triggers"].get("dissolve", 0))
    expect(fired > 0,
           f"a starved whole-frame drift must fire a re-based trigger, got {r['kf_triggers']}")


@case(21, "W4 - silicon_r density re-key: recompute invariant, interpolation, clamps")
def t21_silicon_r_rekey():
    # THE RECOMPUTE INVARIANT. R_new = R_meas x model_T_old /
    # model_T_new per calibration stream (silicon numerator untouched),
    # so the gate's predicted decode time R x mean_T is UNCHANGED where
    # it was calibrated. Literals from the W4 op-walk of the pal9l
    # staged fixture bytes under both coefficient sets (w4 report;
    # R_meas from Card #8 / the 2026-07-30 streamed rows).
    anchors = [
        # fixture, shape, T_old, T_new, R_meas
        ("002", (256, 192), 477569.7, 459303.2, 1.021),
        ("007", (256, 192), 344132.4, 333137.4, 1.037),
        ("001", (320, 256), 766831.7, 735068.9, 1.008),
        ("008", (320, 256), 280507.9, 273914.3, 1.080),
        ("003", (320, 192), 641052.5, 619350.5, 1.258),
        ("009", (320, 192), 289646.6, 282340.9, 1.402),
    ]
    for name, (w, h), t_old, t_new, r_meas in anchors:
        d = t_new / enc.usable_budget_t(25.0, w, h)
        r_new = enc.silicon_r(w, h, density=d)
        # predicted decode T at the anchor: unchanged within the 0.001
        # rounding the table entries carry
        pred_old = r_meas * t_old
        pred_new = r_new * t_new
        expect(abs(pred_new - pred_old) / pred_old < 0.002,
               f"{name}: predicted decode moved {pred_old:.0f} -> {pred_new:.0f} "
               f"({100 * (pred_new / pred_old - 1):+.2f}%) - the recompute must be pure")
    # density key mechanics: monotone (R never rises with density),
    # clamped at both ends, fail-safe (None) = the sparse-end worst
    for w, h in [(256, 192), (320, 256), (320, 192)]:
        rs = [enc.silicon_r(w, h, density=d) for d in
              (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)]
        expect(all(a >= b - 1e-12 for a, b in zip(rs, rs[1:])),
               f"{w}x{h}: R must be non-increasing in density, got {rs}")
        expect(enc.silicon_r(w, h) == max(rs),
               f"{w}x{h}: density=None must fail safe to the sparse-end worst")
        expect(enc.silicon_r(w, h, density=0.0) == rs[0]
               and enc.silicon_r(w, h, density=2.0) == rs[-1],
               f"{w}x{h}: out-of-range densities must clamp, not extrapolate")
    # every gapped height reads the one gapped class (no height key)
    expect(enc.silicon_r(320, 192, density=0.5) == enc.silicon_r(320, 144, density=0.5),
           "gapped heights share the class (Card #8 refuted the height slope)")
    # a keyframe chunk frame prices at the DENSE anchor
    expect(enc.silicon_r(320, 256, density=1.0)
           == min(r for _, r in enc.TMODEL_SILICON_R["flat_320"]),
           "density 1.0 must clamp to the dense anchor")


@case(21, "low-fps pace contention - RESOLVED AT SOURCE: the whole-bank ring "
          "makes the trickle term zero at every legal fps, guard still live")
def t21_pace_contention():
    # The threshold is the player's own ring arithmetic: the next
    # frame's feed fits the single post-present pump iff
    # 2A <= AUD_RING - AUD_GUARD. That span was 2544 bytes and 12.5 fps
    # stereo (A = 2500) missed it by 1956; it is 8176 now, and
    # AUD_FRAME_MAX 3072 caps 2A at 6144, so NO ENCODABLE FILE can be
    # room-limited. The term is kept as the live guard on that
    # inequality - these cases pin both halves of it.
    span = enc.AUD_RING - enc.AUD_GUARD
    expect(span == 8176, "the usable span is the whole bank minus the guard")
    expect(enc.pace_trickle_frac(1250) == 0.0, "25 fps stereo must be EXACTLY zero")
    expect(enc.pace_trickle_frac(1302) == 0.0, "24 fps must be EXACTLY zero")
    expect(enc.pace_trickle_frac(2500) == 0.0,
           "12.5 fps - THE DEFECT ROW - must now be EXACTLY zero")
    expect(enc.pace_trickle_frac(1562) == 0.0,
           "20 fps must now be EXACTLY zero")
    expect(enc.pace_trickle_frac(enc.AUD_FRAME_MAX) == 0.0,
           "the largest declarable frame must still feed in one pass")
    # the guard itself is still armed: the boundary is the ring's, and
    # one byte past it engages
    expect(enc.pace_trickle_frac(span // 2) == 0.0,
           "the ring boundary itself must be zero")
    expect(enc.pace_trickle_frac(span // 2 + 1) > 0.0,
           "one byte past the ring boundary must still engage the term")
    expect(enc.pace_trickle_frac(0) == 0.0, "no audio -> no contention")
    # 25 fps: every returned field is BIT-identical with and without the
    # argument, which is what protects the 007/008/009 calibration
    a = enc.stream_supply_check(3.0e5, 21000.0, 1536, 25.0, 320, 256)
    b = enc.stream_supply_check(3.0e5, 21000.0, 1536, 25.0, 320, 256,
                                audio_real_bytes=1250)
    for k in ("utilization", "busy_ms", "audio_ms", "sd_ms", "suggested_budget"):
        expect(a[k] == b[k], f"25 fps must not move: {k} {a[k]} != {b[k]}")
    expect(b["pump_ms"] == 0.0, "25 fps pump term must be exactly zero")
    # 12.5 fps stereo: NO LONGER CHARGED. Passing the audio bytes must
    # now leave every field bit-identical too - that is the recovered
    # budget, handed back to the picture.
    c = enc.stream_supply_check(6.0e5, 42000.0, 2560, 12.5, 320, 256)
    d = enc.stream_supply_check(6.0e5, 42000.0, 2560, 12.5, 320, 256,
                                audio_real_bytes=2500)
    expect(d["pump_ms"] == 0.0,
           f"12.5 fps must no longer be charged (got {d['pump_ms']:.2f})")
    for k in ("utilization", "busy_ms", "audio_ms", "sd_ms", "suggested_budget"):
        expect(c[k] == d[k], f"12.5 fps must not move either: {k}")
    # the direct gate is a different path and must be untouched (row 057
    # is silicon-clean at 320x256 @12.5 --direct)
    expect("audio_real_bytes" not in
           inspect.signature(enc.direct_supply_check).parameters,
           "the direct gate must not carry the streamed contention term")


# =======================================================================
# Step 22: SP17 W4 - the measured option --prefilter. OPT-IN: absent,
# the extraction chain is byte-identical to the default encoder.
# (--approx-cuts was the wave's other opt-in; it was dropped on
# 2026-08-02 by owner ruling and its cases went with it.)
# =======================================================================


@case(22, "W4 --prefilter - opt-in stage, absent leaves the extraction chain untouched")
def t22_prefilter():
    import subprocess
    help_out = subprocess.run(
        [sys.executable, str(LIB / "videnc.py"), "--help"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout.decode("utf-8", "replace")
    expect("--prefilter" in help_out, "--prefilter must appear in --help")
    expect("--kf-cadence" in help_out, "--kf-cadence must appear in --help")
    for gone in ("--approx-cuts", "--ocopy"):
        expect(gone not in help_out,
               f"{gone} was withdrawn and must not appear in --help")
    expect("hqdn3d" in help_out, "--help must name the bare-flag filter")
    for word in ("OPT-IN", "default OFF"):
        expect(word in help_out, f"--prefilter help must say {word!r}")
    cli = (LIB / "videnc.py").read_text(encoding="utf-8")
    expect("prefilter=args.prefilter" in cli and "kf_cadence=args.kf_cadence" in cli,
           "videnc.py must pass both surviving W4 options through to nxv2enc.encode")
    # absent = untouched chain: the stage is prepended only when set
    if not SINTEL.exists() or not FFMPEG.exists():
        skip("Sintel source or ffmpeg not available")
    ex_a = enc._extract_source(SINTEL, 256, 144, 25.0, None, "0.4",
                               str(FFMPEG), None)
    ex_b = enc._extract_source(SINTEL, 256, 144, 25.0, None, "0.4",
                               str(FFMPEG), None, prefilter=None)
    expect(np.array_equal(ex_a["orig"], ex_b["orig"]),
           "prefilter=None must not change extraction")
    ex_c = enc._extract_source(SINTEL, 256, 144, 25.0, None, "0.4",
                               str(FFMPEG), None,
                               prefilter="hqdn3d=2:1.5:3:2.25")
    expect(not np.array_equal(ex_a["orig"], ex_c["orig"]),
           "a set prefilter must actually filter the frames")


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
