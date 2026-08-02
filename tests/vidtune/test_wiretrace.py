"""Wire trace: the per-frame cost data behind it, and the widget's own
reading of that data.

The trace is the one place in vidtune that shows the wire budget as
something other than a single aggregate number, so these cover both
halves: that preview.decode_vid actually surfaces per-frame costs out of
the decoder walk, and that the widget classifies and locates them the way
the readout claims.
"""
import pytest

from vidtune import theme
from vidtune.preview import decode_vid
from vidtune.previewpane import TRACE_EMPTY, TRACE_UNENCODED, PreviewPane
from vidtune.wiretrace import WireTrace

from vidbuild import build_solid_vid

import numpy as np


def _frames(n, h=8, w=8):
    return [np.zeros((h, w, 3), np.uint8) for _ in range(n)]


# -- decode_vid: the costs come off the decoder walk ---------------------

def test_decode_vid_reports_per_frame_costs(tmp_path):
    vid = tmp_path / "c.vid"
    build_solid_vid(vid, width=256, height=4, colours=[1, 2, 3])
    hdr, frames = decode_vid(vid)

    assert len(hdr["frame_costs"]) == len(frames) == 3
    assert len(hdr["frame_terms"]) == 3
    # Costs are what the player fetches: whole 512-byte blocks.
    for cost in hdr["frame_costs"]:
        assert cost > 0
        assert cost % 512 == 0


def test_decode_vid_reports_cap_when_the_stream_declares_one(tmp_path):
    vid = tmp_path / "capped.vid"
    build_solid_vid(vid, width=256, height=4, colours=[1, 2], cap_blocks=4)
    hdr, _frames = decode_vid(vid)
    assert hdr["cap_bytes"] == 4 * 512


def test_decode_vid_cap_is_none_when_uncapped(tmp_path):
    vid = tmp_path / "uncapped.vid"
    build_solid_vid(vid, width=256, height=4, colours=[1])
    hdr, _frames = decode_vid(vid)
    assert hdr["cap_bytes"] is None


# -- the widget's reading of that data ----------------------------------

def test_trace_classifies_costs_against_the_cap(qtbot):
    trace = WireTrace()
    qtbot.addWidget(trace)
    cap = 1000
    trace.set_trace([100, 900, 1200], cap=cap)

    # Under / near (>= 85% of cap) / over. The near band exists so a
    # frame with no headroom left reads differently from a comfortable
    # one, before it actually breaches.
    assert trace._colour_for(100).name() == theme.WIRE_UNDER
    assert trace._colour_for(900).name() == theme.WIRE_NEAR
    assert trace._colour_for(1200).name() == theme.WIRE_OVER
    assert trace.over_cap_count() == 1


def test_keyframe_spans_are_exempt_from_the_fault_ramp(qtbot):
    # A keyframe span is a full repaint and is SUPPOSED to be expensive.
    # Running it through the same ramp as a delta frame would paint the
    # encoder doing its job as a problem, so it takes a neutral grey.
    trace = WireTrace()
    qtbot.addWidget(trace)
    trace.set_trace([4000, 4000], terms=[0x00, 0x28], cap=1000)

    assert trace._colour_for(4000, 0).name() == theme.WIRE_OVER    # delta
    assert trace._colour_for(4000, 1).name() == theme.INK_FAINT    # keyframe


def test_trace_without_a_cap_never_reports_overruns(qtbot):
    trace = WireTrace()
    qtbot.addWidget(trace)
    trace.set_trace([100, 5000], cap=None)
    assert trace.over_cap_count() == 0
    assert trace._colour_for(5000).name() == theme.WIRE_UNDER


def test_trace_peak_frame_finds_the_most_expensive_frame(qtbot):
    trace = WireTrace()
    qtbot.addWidget(trace)
    assert trace.peak_frame() is None          # nothing loaded
    trace.set_trace([10, 90, 40, 20])
    assert trace.peak_frame() == 1


def test_trace_keeps_an_overrun_visible_above_the_cap_line(qtbot):
    # An overrun drawn clipped flat against the top of the widget would
    # hide the one thing the trace exists to show, so the y-scale always
    # leaves headroom above the cap.
    trace = WireTrace()
    qtbot.addWidget(trace)
    trace.set_trace([100], cap=1000)
    assert trace._top_value() > 1000


def test_trace_x_axis_round_trips_frame_to_pixel_and_back(qtbot):
    trace = WireTrace()
    qtbot.addWidget(trace)
    trace.resize(400, 46)
    trace.set_trace(list(range(100)))
    for frame in (0, 37, 99):
        assert trace._frame_for_x(trace._x_for_frame(frame)) == frame


def test_trace_click_seeks_the_pane(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(100), source=None, fps=25,
                    column_major=False, costs=[512] * 100)
    pane._trace.resize(400, 46)

    pane._trace.seek_requested.emit(60)
    assert pane.frame_index == 60
    assert pane._trace._playhead == 60


# -- the pane wires them together ---------------------------------------

def test_pane_feeds_costs_into_the_trace(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(3), source=None, fps=25,
                    column_major=False, costs=[512, 1024, 512],
                    terms=[0x00, 0x28, 0x20], cap=1024)
    assert pane._trace.has_data() is True
    assert pane._trace._cap == 1024
    assert pane._trace.over_cap_count() == 1


def test_trace_empty_state_distinguishes_no_clip_from_no_encode(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)

    # Source-only frames: there IS a timeline, but nothing has been
    # encoded, so there is no wire cost to plot yet.
    pane.set_frames(encoded=None, source=_frames(5), fps=25,
                    column_major=False)
    assert pane._trace.has_data() is False
    assert pane._trace._empty_text == TRACE_UNENCODED

    # No frames at all is a different empty.
    pane.clear_to_empty()
    assert pane._trace._empty_text == TRACE_EMPTY


def test_trace_segment_follows_the_pane_markers(qtbot):
    pane = PreviewPane()
    qtbot.addWidget(pane)
    pane.set_frames(encoded=_frames(50), source=None, fps=25,
                    column_major=False, costs=[512] * 50)
    pane.seek(10)
    pane.set_in()
    pane.seek(30)
    pane.set_out()
    assert (pane._trace._seg_in, pane._trace._seg_out) == (10, 30)

    pane.clear()
    assert (pane._trace._seg_in, pane._trace._seg_out) == (None, None)


def test_trace_paints_every_state_without_raising(qtbot):
    """paintEvent covers empty, capped, uncapped, segment-marked and
    keyframe-marked states - a paint that raises takes the whole pane
    down, and none of the states above are reachable from the other
    assertions here."""
    pane = PreviewPane()
    qtbot.addWidget(pane)
    trace = pane._trace
    trace.resize(300, 46)

    for costs, terms, cap in (
            ([], None, None),
            ([512] * 20, None, None),
            ([512, 4096, 512] * 6, [0x00, 0x28, 0x20] * 6, 1024),
    ):
        trace.set_trace(costs, terms, cap)
        trace.set_segment(2, 8)
        trace.set_playhead(4)
        trace.grab()          # forces a real paintEvent


@pytest.mark.parametrize("width", [40, 120, 800])
def test_trace_paints_at_any_width(qtbot, width):
    # The cap label is dropped rather than crowded on a narrow strip.
    trace = WireTrace()
    qtbot.addWidget(trace)
    trace.resize(width, 46)
    trace.set_trace([512, 2048, 1024], cap=1024)
    trace.grab()
