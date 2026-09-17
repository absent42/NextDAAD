#!/usr/bin/env python3
"""tests/nxv2_frame_model.py - per-frame player-path events and model T over
an NXV v2 file.

Walks a .vid with nxv2dec's frame walker (as nxv2_copy_census.frames_of
does, but keeping PAL, KSTART and the terminal), classifies each frame,
runs nxv2_path_sim at the frame's true payload offset with the span cursor
carried across chunk frames, and prices it the way nxv2enc charges it
(nxv2enc.frame_price: clear-source dest events plus the expected
source-window events). Events take the file offset: exact resident, and on a
streamed clip's first pass (see nxv2_path_sim).
"""
import contextlib
import sys
from dataclasses import dataclass
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import nxv2dec  # noqa: E402
import nxv2enc  # noqa: E402
import nxv2_path_sim as sim  # noqa: E402

FRAME_TYPES = ("delta", "first", "middle", "last", "single")


@dataclass
class Frame:
    index: int
    type: str            # FRAME_TYPES
    ops: list            # (opcode, n) through the terminal
    events: object       # sim.Events; None for a direct-serve file
    model_t: float       # nxv2enc.frame_price T; None for a direct-serve file
    offset: int          # payload file offset
    nbytes: int          # payload bytes through the terminal
    dst_start: tuple     # (page, DE) at decode entry


def frame_type(ops, in_span):
    """delta / first / middle / last / single from the op list and the span
    state at decode entry."""
    term = ops[-1][0]
    if in_span:
        return "last" if term == sim.OP_KFLIP else "middle"
    if any(op == sim.OP_KSTART for op, _n in ops):
        return "single" if term == sim.OP_KFLIP else "first"
    if term == sim.OP_KFLIP:
        raise sim.PathError("KFLIP with no span")
    return "delta"


def model_t(ftype, ops, surface, dst=(0, sim.DST_WIN), in_span=False,
            streamed=True, enc=nxv2enc):
    """Current-model T for one frame, as nxv2enc charges it: frame_price of
    its ops on the surface (width, height, gapped) from dst."""
    return enc.frame_price(ops, ftype, surface[0], surface[1], dst=dst,
                           in_span=in_span, streamed=streamed)[1]


@contextlib.contextmanager
def selects(copy_thr=None, run_thr=None, enc=nxv2enc):
    """copy_dma_min/run_dma_min set for the block (None keeps), restored on exit."""
    tc = enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"], tc["run_dma_min"]
    try:
        if copy_thr is not None:
            tc["copy_dma_min"] = copy_thr
        if run_thr is not None:
            tc["run_dma_min"] = run_thr
        yield
    finally:
        tc["copy_dma_min"], tc["run_dma_min"] = saved


def surface_of(hdr):
    """(width, height, gapped) of a header, as nxv2_open_body derives it."""
    w, h = hdr["width"], hdr["height"]
    return w, h, nxv2enc.is_gapped(w, h)


def frames(vid_path, copy_thr=None, run_thr=None, streamed=None):
    """Every frame of a .vid as a Frame, events and model T at the given
    selects (None = the model's copy_dma_min/run_dma_min). streamed: the
    delivery model T prices (None = the file is larger than
    nxv2enc.STREAM_RESIDENT_POOL_B)."""
    buf = Path(vid_path).read_bytes()
    hdr = nxv2enc.unpack_header(buf)
    issues = []
    walked = list(nxv2dec._iter_frames(buf, hdr, issues=issues))
    if issues:
        raise ValueError(f"{vid_path}: {issues[0]}")
    surface = surface_of(hdr)
    direct = bool(hdr["flags"] & nxv2enc.FLAG_DIRECT_SERVE)
    if streamed is None:
        streamed = len(buf) > nxv2enc.STREAM_RESIDENT_POOL_B
    out = []
    in_span, dst = False, (0, sim.DST_WIN)
    with selects(copy_thr, run_thr):
        for i, (_pal, _surf, _term, start, length) in enumerate(walked):
            ops = sim.parse_payload(buf[start:start + length])
            ftype = frame_type(ops, in_span)
            nbytes = sum(sim.op_bytes(op, n) for op, n in ops)
            ev, st = sim.simulate(ops, surface, start, dst=dst, in_span=in_span)
            if direct:
                # vid_decode_frame_ds reads the wire, not the RAM ring: span
                # state and dest cursor only (the dest bodies are shared)
                out.append(Frame(i, ftype, ops, None, None, start, nbytes, dst))
            else:
                out.append(Frame(i, ftype, ops, ev,
                                 model_t(ftype, ops, surface, dst, in_span, streamed),
                                 start, nbytes, dst))
            in_span = st.in_span
            dst = (st.page, st.de) if in_span else (0, sim.DST_WIN)
    return out
