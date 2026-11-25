import os

import numpy as np
import pytest

from vidtune import preview as vt_preview
from vidtune.preview import decode_vid, diff_heatmap, stale_bands


def test_diff_heatmap_shape_and_gain():
    src = np.zeros((8, 8, 3), np.uint8)
    enc = np.zeros((8, 8, 3), np.uint8)
    enc[0, 0] = (30, 0, 0)                      # mean err 10, x4 gain = 40
    hm = diff_heatmap(src, enc)
    assert hm.shape == (8, 8, 3)
    assert hm[0, 0, 0] == 40 and hm[0, 0, 1] == 0
    assert hm[1, 1].tolist() == [0, 0, 0]


def test_stale_bands_row_major():
    h, w = 16, 8                                # 4 bands of 4 rows
    prev_src = np.zeros((h, w, 3), np.uint8)
    src = prev_src.copy(); src[4:8] = 200       # band 1 source changed
    prev_enc = np.zeros((h, w, 3), np.uint8)
    enc = prev_enc.copy()                       # encode did not update it
    mask = stale_bands(prev_src, src, prev_enc, enc, column_major=False)
    assert mask.tolist() == [False, True, False, False]
    # once the encode catches up, no longer stale
    enc2 = enc.copy(); enc2[4:8] = 199
    assert stale_bands(prev_src, src, prev_enc, enc2,
                       column_major=False).tolist()[1] is False


def test_stale_bands_column_major():
    h, w = 8, 16
    prev_src = np.zeros((h, w, 3), np.uint8)
    src = prev_src.copy(); src[:, 0:4] = 200
    prev_enc = np.zeros((h, w, 3), np.uint8)
    mask = stale_bands(prev_src, src, prev_enc, prev_enc.copy(),
                       column_major=True)
    assert mask.tolist() == [True, False, False, False]


def test_decode_vid_roundtrip(tmp_path):
    # nxv2enc.pack_header only accepts the two real Layer 2 widths (256
    # or 320) - see vidbuild.py's docstring - so this uses width=256
    # with a minimal height=1 (raw=256) rather than the brief's
    # off-format 32x8, and keeps two frames for a solid-fill roundtrip.
    from vidbuild import build_solid_vid   # helper, this task
    vid = tmp_path / "t.vid"
    build_solid_vid(vid, width=256, height=1, colours=[5, 9])
    hdr, frames = decode_vid(vid)
    assert hdr["width"] == 256 and hdr["height"] == 1
    assert len(frames) == 2
    assert frames[0].shape == (1, 256, 3)
    assert (frames[0] == frames[0][0, 0]).all()   # solid frame 0


def test_decode_vid_raw_clip_true_shape_and_colours(tmp_path):
    # 280x224 sits pillarboxed on the 320 surface: frames are 280 wide
    from vidbuild import build_raw_vid
    import nxv2enc
    vid = tmp_path / "r.vid"
    want = build_raw_vid(vid, 280, 224, channels=1)
    hdr, frames = decode_vid(vid)
    assert hdr["width"] == 320 and hdr["raw_width"] == 280 and hdr["height"] == 224
    assert len(frames) == len(want) == 3
    for got, exp in zip(frames, want):
        assert got.shape == (224, 280, 3)
        assert np.array_equal(got, exp)
    px = nxv2enc.raw_layout(280, 224, 320)["sectors"] * 512
    assert hdr["frame_costs"] == [512 + px, px, 512 + px]   # palette sector on frames 0 and 2
    assert hdr["cap_bytes"] == px + 512
    assert hdr["frame_terms"] == [nxv2enc.OP_KFLIP] * 3     # whole pictures, as old direct


def _direct_routes():
    from vidtune import presets
    return [r for r in presets.all_routes() if r.values.get("direct")]


@pytest.mark.parametrize("route", _direct_routes(), ids=lambda r: r.key)
def test_every_direct_route_previews_at_its_shape(route, tmp_path, monkeypatch):
    """A route's options through videnc and the encoder (extraction faked),
    then the preview decode: frames at the route's shape and colours."""
    import nxv2enc
    from vidbuild import raw_source_ex, record_quantised
    from vidtune import presets
    from vidtune.kitmodel import KitConfig
    from vidtune.settingsmodel import deviations, effective_settings
    cfg = KitConfig()
    base = effective_settings(cfg, "001")
    opts = deviations(presets.apply_route(base, base, route), cfg)
    shape = route.values["shape"]
    w, h = nxv2enc.PRESETS.get(shape) or tuple(map(int, shape.split("x")))
    made = {}

    def fake_extract(src, width, height, fps, start, duration, ffmpeg, dither,
                     dither_mode=None, retime=None, prefilter=None, raw=False, channels=2):
        made.update(shape=(width, height), raw=raw, channels=channels)
        return raw_source_ex(2, width, height, fps=float(fps), channels=channels)
    monkeypatch.setattr(vt_preview.videnc, "probe_dimensions",
                        lambda ffmpeg, path, stderr=None: (640, 480))
    monkeypatch.setattr(nxv2enc, "_extract_source", fake_extract)
    src, out = tmp_path / "src.mp4", tmp_path / "r.vid"
    src.write_bytes(b"x")
    with record_quantised() as want:
        rc = vt_preview.videnc.main(["videnc", str(src), str(out), "--ffmpeg", str(src)] + opts)
    assert rc == 0 and made["raw"] and made["shape"] == (w, h)
    hdr, frames = decode_vid(out)
    assert hdr["raw"] and hdr["raw_width"] == w and hdr["height"] == h
    assert hdr["channels"] == made["channels"]
    assert ("mono" in route.blurb.lower()) == (made["channels"] == 1)
    assert len(frames) == len(want) == 2
    for got, exp in zip(frames, want):
        assert got.shape == (h, w, 3)
        assert np.array_equal(got, exp)


def _patch_videnc_probes(monkeypatch, captured):
    """Stubs every videnc probe/plan call extract_source makes before
    extract_video, so only extract_video's own call - the one under
    test - needs a real fake. captured["start"/"duration"] records what
    extract_source actually handed to videnc.extract_video."""
    monkeypatch.setattr(vt_preview.videnc, "_probe_stderr",
                        lambda ffmpeg, mp4: ", 640x480, 25 fps,")
    monkeypatch.setattr(vt_preview.videnc, "probe_dimensions",
                        lambda ffmpeg, mp4, stderr=None: (640, 480))
    monkeypatch.setattr(vt_preview.videnc, "probe_source_fps",
                        lambda ffmpeg, mp4, stderr=None: 25.0)
    monkeypatch.setattr(vt_preview.videnc, "compute_center_crop",
                        lambda sw, sh, w, h: None)
    monkeypatch.setattr(vt_preview.videnc, "retime_plan",
                        lambda src_fps, target_fps, w, h, mode: (None, "no retime"))

    def fake_extract_video(ffmpeg, input_path, start, duration, width, height,
                           fps, crop=None, stages=None):
        captured["start"] = start
        captured["duration"] = duration
        # subprocess.run requires str/bytes/PathLike argv elements;
        # check before this would reach a real subprocess.run.
        for value in (start, duration):
            if value is not None:
                assert isinstance(value, (str, bytes, os.PathLike)), (
                    f"non-str/bytes/PathLike would-be argv element: "
                    f"{value!r} ({type(value).__name__})")
        return bytes(width * height * 3), 1   # one blank RGB24 frame
    monkeypatch.setattr(vt_preview.videnc, "extract_video", fake_extract_video)


def test_extract_source_stringifies_truthy_start_duration(monkeypatch, tmp_path):
    """extract_source must stringify truthy start/duration before calling
    videnc.extract_video, whose -ss arg otherwise gets an unconverted
    float and raises a TypeError."""
    captured = {}
    _patch_videnc_probes(monkeypatch, captured)

    frames = vt_preview.extract_source("ffmpeg.exe", tmp_path / "in.mp4",
                                       640, 480, 25.0, "blend",
                                       start=0.12, duration=0.48)
    assert len(frames) == 1
    assert captured["start"] == "0.12"
    assert captured["duration"] == "0.48"


def test_extract_source_omits_flag_for_falsy_start_duration(monkeypatch, tmp_path):
    """Falsy (None or 0.0) start/duration must stay None, not become the
    truthy string "0.0", so extract_video's `if start:`/`if duration:`
    checks still omit -ss/-t rather than adding a redundant 0.0."""
    captured = {}
    _patch_videnc_probes(monkeypatch, captured)

    frames = vt_preview.extract_source("ffmpeg.exe", tmp_path / "in.mp4",
                                       640, 480, 25.0, "blend",
                                       start=0.0, duration=None)
    assert len(frames) == 1
    assert captured["start"] is None
    assert captured["duration"] is None
