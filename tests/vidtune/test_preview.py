import numpy as np

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
