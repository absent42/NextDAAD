#!/usr/bin/env python3
"""tests/nxv2_copy_census.py - COPY and RUN op census of real NXV v2 files,
split by surface (flat / gapped), and the cost functions the COPY threshold
and gapped-factor rules use."""
import sys
from collections import Counter
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))
import nxv2dec  # noqa: E402
import nxv2enc  # noqa: E402


class Census:
    def __init__(self):
        self.copy8 = Counter()     # L -> ops
        self.copy16 = Counter()    # L -> ops
        self.run = Counter()       # L -> ops (8- and 16-bit)
        self.frames = 0


def ops_of_payload(buf):
    """Yield (opcode, length) for one payload, stopping at FEND/KFLIP."""
    pos = 0
    while pos < len(buf):
        op = buf[pos]
        pos += 1
        if op in nxv2enc.TERMINAL_OPS:
            return
        if op == nxv2enc.OP_KSTART:
            continue
        if op == nxv2enc.OP_SKIP8:
            yield op, buf[pos]
            pos += 1
        elif op == nxv2enc.OP_SKIP16:
            yield op, int.from_bytes(buf[pos:pos + 2], "little")
            pos += 2
        elif op == nxv2enc.OP_RUN8:
            yield op, buf[pos]
            pos += 2
        elif op == nxv2enc.OP_RUN16:
            yield op, int.from_bytes(buf[pos:pos + 2], "little")
            pos += 3
        elif op == nxv2enc.OP_COPY8:
            n = buf[pos]
            yield op, n
            pos += 1 + n
        elif op == nxv2enc.OP_COPY16:
            n = int.from_bytes(buf[pos:pos + 2], "little")
            yield op, n
            pos += 2 + n
        elif op == nxv2enc.OP_PAL:
            pos += nxv2enc.PAL_BLOCK_SIZE
        else:
            raise ValueError(f"reserved opcode ${op:02X}")


def frames_of(vid_path):
    """Yield one list of (opcode, length) per source frame. Raises
    ValueError naming the file and the first issue if the decoder
    recorded any structural problems walking it."""
    buf = Path(vid_path).read_bytes()
    hdr = nxv2enc.unpack_header(buf)
    issues = []
    frames = list(nxv2dec._iter_frames(buf, hdr, issues=issues))
    if issues:
        raise ValueError(f"{vid_path}: {issues[0]}")
    for _pal, _surf, _term, start, length in frames:
        yield list(ops_of_payload(buf[start:start + length]))


def is_gapped_file(vid_path):
    hdr = nxv2enc.unpack_header(Path(vid_path).read_bytes()[:nxv2enc.HEADER_SIZE])
    return nxv2enc.is_gapped(hdr["width"], hdr["height"])


def census(vid_paths):
    out = {"flat": Census(), "gapped": Census()}
    for p in vid_paths:
        c = out["gapped" if is_gapped_file(p) else "flat"]
        for ops in frames_of(p):
            c.frames += 1
            for op, n in ops:
                if op == nxv2enc.OP_COPY8:
                    c.copy8[n] += 1
                elif op == nxv2enc.OP_COPY16:
                    c.copy16[n] += 1
                elif op in (nxv2enc.OP_RUN8, nxv2enc.OP_RUN16):
                    c.run[n] += 1
    return out


def threshold_cost(cen, lines, n, enc=nxv2enc):
    """Total COPY T at threshold n. 8-bit ops: whole-op T from the measured
    bench lines, lines = {"flat": ((a_ldi, b_ldi), (a_dma, b_dma)),
    "gapped": (...)}, T(L) = a + b * L per path. 16-bit ops: the model's
    own op price at copy_dma_min = n, so a DMA tail and an LDI tail each
    carry exactly the terms the model charges (envelope, path, setup,
    trailing-chunk term); the T298-T320 rows verify that pricing."""
    tc = enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"]
    total = 0.0
    try:
        tc["copy_dma_min"] = n
        for surface, c in cen.items():
            (a_l, b_l), (a_d, b_d) = lines[surface]
            for L, k in c.copy8.items():
                total += k * ((a_l + b_l * L) if L < n else (a_d + b_d * L))
            for L, k in c.copy16.items():
                total += k * enc._cost_copy_chunk(L)[1]
    finally:
        tc["copy_dma_min"] = saved
    return total


_KIND = {nxv2enc.OP_SKIP8: "skip", nxv2enc.OP_SKIP16: "skip",
         nxv2enc.OP_RUN8: "run", nxv2enc.OP_RUN16: "run",
         nxv2enc.OP_COPY8: "copy", nxv2enc.OP_COPY16: "copy"}


def _op_class(op, n, copy_thr):
    if op == nxv2enc.OP_COPY8:
        return "copy_dma" if n >= copy_thr else "copy_ldi"
    if op == nxv2enc.OP_COPY16:
        return "copy16"
    if op in (nxv2enc.OP_RUN8, nxv2enc.OP_RUN16):
        return "fill_dma" if n >= nxv2enc.TMODEL_COEFFS["run_dma_min"] else None
    return None


def worst_gapped_fraction(vid_paths, surcharge_t, copy_thr):
    """Largest per-frame share of modelled T that the gapped surcharges
    add, over every frame of the gapped files. surcharge_t maps a class
    ("copy_ldi", "copy_dma", "copy16", "fill_dma") to T per op.
    nxv2enc.op_cost(kind, length) returns (bytes, T). Both the surcharge
    classes and the modelled frame T are priced at copy_dma_min = copy_thr,
    restored on every exit."""
    tc = nxv2enc.TMODEL_COEFFS
    saved = tc["copy_dma_min"]
    worst = 0.0
    try:
        tc["copy_dma_min"] = copy_thr
        for p in vid_paths:
            if not is_gapped_file(p):
                continue
            for ops in frames_of(p):
                modelled = tc["frame_delta_t"]
                added = 0.0
                for op, n in ops:
                    modelled += nxv2enc.op_cost(_KIND[op], n)[1]
                    cls = _op_class(op, n, copy_thr)
                    if cls:
                        added += surcharge_t.get(cls, 0.0)
                worst = max(worst, added / modelled)
    finally:
        tc["copy_dma_min"] = saved
    return worst
