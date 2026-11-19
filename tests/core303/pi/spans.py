"""Span definition shared by P2 (pi303_prep span histograms) and P4 (pi303_video pushes).
numpy only: pi303_video must not pull in PIL.
"""
import numpy as np

GAP = 4                     # equal bytes between differing ones that still merge: under 4


def span_list(prev, cur):
    """[(offset, bytes)] of cur's differing runs, gaps under GAP merged (pi303_prep.span_lens)."""
    a = np.frombuffer(prev, np.uint8)
    b = np.frombuffer(cur, np.uint8)
    idx = np.flatnonzero(a != b)
    if idx.size == 0:
        return []
    cut = np.flatnonzero(np.diff(idx) > GAP)
    starts = np.concatenate(([idx[0]], idx[cut + 1]))
    ends = np.concatenate((idx[cut], [idx[-1]]))
    return [(int(s), bytes(cur[s:e + 1])) for s, e in zip(starts.tolist(), ends.tolist())]
