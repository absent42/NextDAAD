"""nxb_diff: same-revision identity, the frame ISR change, the allow-list."""
import nxb_diff

BASELINE = nxb_diff.BASELINE_REV


def test_self_identical():
    d = nxb_diff.nxb_diff(BASELINE, BASELINE)
    assert d and all(d.values())


def test_im2_isr_changed():
    assert nxb_diff.nxb_diff(BASELINE, "main")["im2_isr"] is False


def test_row_routines_follow_geometry():
    flat = nxb_diff.row_routines("VOP_COPY8", 48, 81, 0)
    gap = nxb_diff.row_routines("VOP_COPY8", 48, 1, 1)
    assert "vf_op_copy8" in flat and "vg_op_copy8" not in flat
    assert "vg_op_copy8" in gap and "vid_dst_norm_gap" in gap
    assert "vid_copy_dma" in gap and "vid_copy_dma" not in flat
    assert "im2_isr" not in flat


def test_allow_list_is_table_rows_only():
    log = nxb_diff.RESULTS / nxb_diff.BASELINE_LOG
    allowed, why = nxb_diff.nxb_allow(BASELINE, "main", log)
    assert allowed
    assert not {"CALL", "CALR", "PLAY", "RING"} & set(allowed)
    assert not set(allowed) & set(why)
