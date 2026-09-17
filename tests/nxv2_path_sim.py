#!/usr/bin/env python3
"""tests/nxv2_path_sim.py - player-path event simulator for the NXV v2 RAM
decode (resident and streaming; direct-serve decodes off the wire instead).

A Python port of the geometry decisions src/video.asm makes per op: the flat
and gapped fast handlers, the chunked bodies and their kernel selects, the
chunk sizers, the dest normalize and both seam walkers, and the PAL handler.
It counts the events each op executes and prices nothing; Events.price is
the pricing hook. Every ported branch cites its video.asm line.

Source cursor: HL = $C000 + (position & $1FFF) on linear page position >> 13
(bank = page >> 1, parity = page & 1). Resident, the position is the file
offset. Streaming, the ring holds the file at identity offsets on the first
pass and wraps in whole banks; a loop pass restarts at the previous pass's
end block, which shifts the seams. Dest cursor: (page, DE) inside the MMU2
window $4000-$6000; gapped surfaces keep E = row within a 256-aligned column
(E == height is the deferred-hop state).
"""
import sys
from dataclasses import dataclass, fields
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))
import nxv2enc  # noqa: E402

# src/nextdaad.inc mirrors
SRC_WIN = 0xC000          # VID_SRC_WIN
WIN_BYTES = 0x2000
DST_WIN = 0x4000          # VID_DST_WIN
DST_TOP = 0x6000
DMA_CHUNK = 240           # NXV2_DMA_CHUNK
MAX_OPERANDS = 4          # NXV2_MAX_OPERANDS
PAL_BYTES = 512           # NXV_PAL_BYTES

OP_FEND, OP_SKIP16, OP_RUN8, OP_RUN16 = 0x00, 0x04, 0x08, 0x0C
OP_COPY8, OP_COPY16, OP_PAL, OP_SKIP8 = 0x10, 0x14, 0x18, 0x1C
OP_KFLIP, OP_KSTART = 0x20, 0x28
assert (OP_FEND, OP_SKIP8, OP_RUN8, OP_COPY8, OP_PAL, OP_KSTART) == (
    nxv2enc.OP_FEND, nxv2enc.OP_SKIP8, nxv2enc.OP_RUN8, nxv2enc.OP_COPY8,
    nxv2enc.OP_PAL, nxv2enc.OP_KSTART)
assert (OP_SKIP16, OP_RUN16, OP_COPY16, OP_KFLIP) == (
    nxv2enc.OP_SKIP16, nxv2enc.OP_RUN16, nxv2enc.OP_COPY16, nxv2enc.OP_KFLIP)
assert DMA_CHUNK == nxv2enc.TMODEL_COEFFS["copy_dma_chunk"] == nxv2enc.TMODEL_COEFFS["fill_dma_min"]

# operand bytes after the opcode (RUN carries the colour byte)
OPERANDS = {OP_SKIP8: 1, OP_SKIP16: 2, OP_RUN8: 2, OP_RUN16: 3,
            OP_COPY8: 1, OP_COPY16: 2}
COUNT8 = frozenset({OP_SKIP8, OP_RUN8, OP_COPY8})      # 1-byte count field
OPCODE_BY_KIND = {"skip8": OP_SKIP8, "skip16": OP_SKIP16, "run8": OP_RUN8,
                  "run16": OP_RUN16, "copy8": OP_COPY8, "copy16": OP_COPY16}
_TERMINAL = (OP_FEND, OP_KFLIP)
_KNOWN = frozenset(OPERANDS) | {OP_FEND, OP_KFLIP, OP_KSTART, OP_PAL}
# a subset of the body LDI/CPU chunk counts by position; never priced
DIAGNOSTIC = frozenset({"run_tail8", "run_tail16", "copy_tail8", "copy_tail16"})


class PathError(ValueError):
    """The player would abort (VID_ERR_*) or the op list is malformed."""


@dataclass
class Events:
    """Event counts for one decode. 8/16 = the op's count width; a chunk
    is keyed by the width of the op that entered the body. Every body
    LDI/CPU chunk pays the same loop pass wherever it sits, so the
    *_tail* counters (DIAGNOSTIC) are a diagnostic subset of the body
    chunk counts and are never priced."""
    # ops completed in a fast handler (vf_op_*, vg_op_*)
    fast_skip8: int = 0
    fast_run8: int = 0
    fast_copy8: int = 0
    # fast handler bails into the body, by reason
    thr_run8: int = 0          # count at/over the kernel select
    thr_copy8: int = 0
    edge_skip8: int = 0        # flat: D >= $5F
    edge_run8: int = 0
    edge_copy8: int = 0
    gap_skip8: int = 0         # gapped: 9-bit sum or 2+ columns
    gap_run8: int = 0
    gap_copy8: int = 0
    src_copy8: int = 0         # COPY8 body straddles the source window end
    # 16-bit ops (always the body)
    op_skip16: int = 0
    op_run16: int = 0
    op_copy16: int = 0
    # ops parsed through vid_slow_op (always the body)
    slow_skip8: int = 0
    slow_skip16: int = 0
    slow_run8: int = 0
    slow_run16: int = 0
    slow_copy8: int = 0
    slow_copy16: int = 0
    # gapped fast-handler inline hops; hop0 = empty first segment (E == height)
    fast_hop_skip8: int = 0
    fast_hop_run8: int = 0
    fast_hop_copy8: int = 0
    fast_hop0_run8: int = 0
    fast_hop0_copy8: int = 0
    fast_dst_seams: int = 0    # vid_dst_next from an inline hop
    copy8_srcedge: int = 0     # COPY8 fast handler's L + count refine at $DFxx
    run_fast_b: int = 0
    copy_fast_b: int = 0
    # chunked bodies
    skip_passes: int = 0
    run_cpu_chunks8: int = 0
    run_cpu_chunks16: int = 0
    run_dma_chunks8: int = 0
    run_dma_chunks16: int = 0
    copy_ldi_chunks8: int = 0
    copy_ldi_chunks16: int = 0
    copy_dma_chunks8: int = 0
    copy_dma_chunks16: int = 0
    run_tail8: int = 0         # diagnostic: body CPU/LDI chunk after a DMA chunk
    run_tail16: int = 0
    copy_tail8: int = 0
    copy_tail16: int = 0
    run_cpu_b: int = 0
    run_dma_b: int = 0
    copy_ldi_b: int = 0
    copy_dma_b: int = 0
    dst_exact_chunks: int = 0  # RUN/COPY chunk sized by vid_chunk_dst_flat .exact
    cap_arm_chunks: int = 0    # RUN/COPY chunk whose cap test falls through at 241-255 (not .exact)
    gap_hi_chunks: int = 0     # RUN/COPY body chunk on a gapped surface of height 241-255
    copy_src_chunks: int = 0   # COPY chunk sized through vid_chunk_src
    col_hops: int = 0          # vid_dst_norm_gap column hop
    dst_seams: int = 0         # vid_dst_next from a body normalize
    # source window
    src_parity_seams: int = 0  # vid_src_next into an odd page (same bank)
    src_bank_seams: int = 0    # vid_src_next into an even page (next bank)
    src_edge_hdr: int = 0      # opcode at $DF00-$DFFB: vid_op_edge .instr detour
    src_slow_hdr: int = 0      # opcode at $DFFC-$DFFF: vid_slow_op
    src_wrap_hdr: int = 0      # vid_op_edge at H = $E0: walk, then vid_next
    # PAL, KSTART and terminals
    pal_ops: int = 0
    pal_straddles: int = 0
    pal_chunks: int = 0        # straddle-loop chunks
    kstart: int = 0
    kflip: int = 0
    fend: int = 0
    fend_span: int = 0         # FEND inside a span (cursor spilled)

    def as_dict(self, nonzero=True):
        d = {f.name: getattr(self, f.name) for f in fields(self)}
        return {k: v for k, v in d.items() if v} if nonzero else d

    def __add__(self, other):
        return Events(**{f.name: getattr(self, f.name) + getattr(other, f.name)
                         for f in fields(self)})

    def scale(self, k):
        """Every count times k (per-op views of a rep divide by its ops)."""
        return Events(**{f.name: getattr(self, f.name) * k for f in fields(self)})

    def price(self, coeffs, strict=True):
        """Sum of count x coeffs[name]. strict: a nonzero count with no
        coefficient raises KeyError, so no event is priced free by omission.
        A coefficient for a DIAGNOSTIC counter raises ValueError."""
        named = DIAGNOSTIC & set(coeffs)
        if named:
            raise ValueError(f"diagnostic counters are never priced: {sorted(named)}")
        total = 0.0
        for name, count in self.as_dict().items():
            if name in DIAGNOSTIC:
                continue
            if name in coeffs:
                total += count * coeffs[name]
            elif strict:
                raise KeyError(f"no coefficient for event {name!r} ({count})")
        return total


def op_bytes(op, n):
    """Wire bytes of one op: opcode, operands and a COPY/PAL body."""
    if op in OPERANDS:
        return 1 + OPERANDS[op] + (n if op in (OP_COPY8, OP_COPY16) else 0)
    if op == OP_PAL:
        return 1 + PAL_BYTES
    if op in (OP_FEND, OP_KFLIP, OP_KSTART):
        return 1
    raise PathError(f"reserved opcode ${op:02X}")


def parse_payload(buf):
    """Full op list of one payload through its terminal: (opcode, n), with
    KSTART and the terminal as n = 0 and PAL as n = 512."""
    ops, pos = [], 0
    while pos < len(buf):
        op = buf[pos]
        if op in COUNT8:
            n = buf[pos + 1] if pos + 1 < len(buf) else 0
        elif op in (OP_SKIP16, OP_RUN16, OP_COPY16):
            n = int.from_bytes(buf[pos + 1:pos + 3], "little")
        elif op == OP_PAL:
            n = PAL_BYTES
        elif op in (OP_FEND, OP_KFLIP, OP_KSTART):
            n = 0
        else:
            raise PathError(f"reserved opcode ${op:02X} at payload byte {pos}")
        ops.append((op, n))
        pos += op_bytes(op, n)
        if pos > len(buf):
            raise PathError(f"op ${op:02X} runs past the payload end")
        if op in _TERMINAL:
            return ops
    raise PathError("payload has no FEND/KFLIP")


def surface_pages(width):
    """Dest pages the open grants (nxv2_open_body): 10 mode-1, 6 mode-0."""
    return 10 if int(width) == 320 else 6


def dst_linear(page, de, surface):
    """Paint-order cursor index of a dest state."""
    _w, height, gapped = surface
    if gapped:
        return (page * 32 + (de >> 8) - (DST_WIN >> 8)) * height + (de & 0xFF)
    return page * WIN_BYTES + de - DST_WIN


@dataclass
class State:
    """Decoder cursors after a decode: dest page and DE, span flag, and the
    source position of the byte after the terminal."""
    page: int
    de: int
    in_span: bool
    src_pos: int


class _Player:
    def __init__(self, surface, src_offset, dst, in_span, copy_thr, run_thr, dst_pages):
        width, height, gapped = surface
        tc = nxv2enc.TMODEL_COEFFS
        self.ev = Events()
        self.gapped = bool(gapped)
        self.h = int(height)
        if self.gapped and not 1 <= self.h <= 255:
            raise PathError(f"gapped height {height} must be 1-255")
        self.copy_thr = int(tc["copy_dma_min"] if copy_thr is None else copy_thr)
        self.run_thr = int(tc["run_dma_min"] if run_thr is None else run_thr)
        self.dst_pages = surface_pages(width) if dst_pages is None else int(dst_pages)
        self.page = int(src_offset) >> 13          # vid_src_seek 1683-1716
        self.w = int(src_offset) & (WIN_BYTES - 1)
        self.dpage, self.de = dst
        if not (0 <= self.dpage < self.dst_pages and DST_WIN <= self.de <= DST_TOP):
            raise PathError(f"dest ({dst[0]}, ${dst[1]:04X}) outside the surface")
        if self.gapped and (self.de & 0xFF) > self.h:
            raise PathError(f"dest E ${self.de & 0xFF:02X} over height {self.h}")
        self.in_span = bool(in_span)

    # ---- source cursor ----
    def H(self):
        return (SRC_WIN + self.w) >> 8

    def L(self):
        return (SRC_WIN + self.w) & 0xFF

    def src_next(self):
        # vid_src_next 1041-1091: H = $E0 at every seam; parity 0 -> 1 same
        # bank (1057-1060), parity 1 -> 0 next bank (1061-1082)
        if self.w != WIN_BYTES:
            raise PathError("source walk off a window end")
        self.page += 1
        self.w = 0
        if self.page & 1:
            self.ev.src_parity_seams += 1
        else:
            self.ev.src_bank_seams += 1

    def take(self, n):
        # a direct read: the caller has proven the window room
        self.w += n
        if self.w > WIN_BYTES:
            raise PathError("direct read past the source window")

    def fetch(self, n):
        # vid_fetch_ram 606-612: walk at H >= $E0, then read, per byte
        for _ in range(n):
            if self.H() >= 0xE0:
                self.src_next()
            self.w += 1

    # ---- dest cursor ----
    @property
    def D(self):
        return self.de >> 8

    @property
    def E(self):
        return self.de & 0xFF

    def dst_next(self):
        # vid_dst_next 1095-1110: page + 1 >= end aborts DSTOVR; D -= $20
        self.dpage += 1
        if self.dpage >= self.dst_pages:
            raise PathError("VID_ERR_DSTOVR: dest past the surface")
        self.de -= WIN_BYTES

    def norm(self):
        if self.gapped:
            # vid_dst_norm_gap 743-749: E == height hops to the next column
            if self.E == self.h:
                self.de = (self.D + 1) << 8
                self.ev.col_hops += 1
        # vid_dst_norm_gap 750-754 / vid_dst_norm_flat 765-768
        if self.D >= 0x60:
            self.dst_next()
            self.ev.dst_seams += 1

    def dst_room(self):
        if self.gapped:
            return self.h - self.E     # vid_chunk_dst_*_gap 960-961 / 982-983
        return DST_TOP - self.de       # vid_chunk_dst_nocap_flat 996-998

    def chunk_dst(self, remain):
        # RUN/COPY dest step with the DMA cap
        if self.gapped:
            if self.h > DMA_CHUNK:
                self.ev.gap_hi_chunks += 1                   # room can pass the cap
            if DMA_CHUNK < min(remain, self.dst_room()) <= 255:
                self.ev.cap_arm_chunks += 1                  # 973-975: ret c falls through
            return min(remain, self.dst_room(), DMA_CHUNK)   # 958-975
        if self.D <= 0x5E:
            if DMA_CHUNK < remain <= 255:
                self.ev.cap_arm_chunks += 1                  # 942-945: ret c falls through
            return min(remain, DMA_CHUNK)                    # 931-945
        self.ev.dst_exact_chunks += 1                        # 946-956
        return min(remain, self.dst_room(), DMA_CHUNK)

    # ---- dispatch ----
    def dispatch(self):
        """vid_next / NXVNEXT: True when the header takes vid_slow_op."""
        # vid_next 265-267, NXVNEXT 178-180: H >= $DF -> vid_op_edge
        while self.H() >= 0xDF:
            if self.H() >= 0xE0:
                # vid_op_edge 278-281: walk, jr vid_next
                self.ev.src_wrap_hdr += 1
                self.src_next()
                continue
            if self.L() < 0x100 - MAX_OPERANDS:
                self.ev.src_edge_hdr += 1                    # 288-290
                return False
            self.ev.src_slow_hdr += 1                        # 291
            return True
        return False

    def run(self, ops):
        ops = list(ops)
        for i, (op, n) in enumerate(ops):
            if op not in _KNOWN:
                raise PathError(f"VID_ERR_OP: reserved opcode ${op:02X}")   # 294-299
            n = int(n)
            if op in OPERANDS and not 0 <= n <= (255 if op in COUNT8 else 0xFFFF):
                raise PathError(f"op ${op:02X} count {n} does not fit its field")
            slow = self.dispatch()
            if slow:
                self.fetch(1)                                # vid_slow_op 541
            else:
                self.take(1)                                 # 269-270
            if op in _TERMINAL:
                self.terminal(op)
                if i != len(ops) - 1:
                    raise PathError("ops after the terminal")
                return
            if op == OP_KSTART:
                self.kstart()
            elif op == OP_PAL:
                self.pal()
            elif slow:
                self.slow_op(op, n)
            else:
                self.fast_op(op, n)
        raise PathError("op list has no FEND/KFLIP")

    def slow_op(self, op, n):
        # vid_slow_op 546-596: operands through vid_fetch, then the body
        self.fetch(OPERANDS[op])
        width = 16 if op in (OP_SKIP16, OP_RUN16, OP_COPY16) else 8
        kind = {OP_SKIP8: "skip", OP_SKIP16: "skip", OP_RUN8: "run",
                OP_RUN16: "run", OP_COPY8: "copy", OP_COPY16: "copy"}[op]
        setattr(self.ev, f"slow_{kind}{width}", getattr(self.ev, f"slow_{kind}{width}") + 1)
        getattr(self, f"{kind}_body")(n, width)

    def fast_op(self, op, n):
        if op == OP_SKIP16:                                  # 511-516
            self.take(2)
            self.ev.op_skip16 += 1
            self.skip_body(n, 16)
        elif op == OP_RUN16:                                 # 518-525
            self.take(3)
            self.ev.op_run16 += 1
            self.run_body(n, 16)
        elif op == OP_COPY16:                                # 527-532
            self.take(2)
            self.ev.op_copy16 += 1
            self.copy_body(n, 16)
        elif self.gapped:
            {OP_SKIP8: self.vg_skip8, OP_RUN8: self.vg_run8, OP_COPY8: self.vg_copy8}[op](n)
        else:
            {OP_SKIP8: self.vf_skip8, OP_RUN8: self.vf_run8, OP_COPY8: self.vf_copy8}[op](n)

    # ---- flat fast handlers ----
    def vf_skip8(self, n):
        if self.D >= 0x5F:                                   # 192-194, .edge 199-203
            self.take(1)
            self.ev.edge_skip8 += 1
            return self.skip_body(n, 8)
        self.take(1)                                         # 195-197
        self.de += n
        self.ev.fast_skip8 += 1

    def vf_run8(self, n):
        self.take(1)                                         # 208-209
        if self.D >= 0x5F:                                   # 210-212
            self.take(1)
            self.ev.edge_run8 += 1
            return self.run_body(n, 8)
        if n >= self.run_thr:                                # 213-216
            self.take(1)
            self.ev.thr_run8 += 1
            return self.run_body(n, 8)
        self.take(1)                                         # 217-220
        self.de += n
        self.ev.fast_run8 += 1
        self.ev.run_fast_b += n

    def vf_copy8(self, n):
        self.take(1)                                         # 232-234
        if self.H() >= 0xDF:                                 # 235-237, .srcedge 248-252
            self.ev.copy8_srcedge += 1
            if self.L() + n > 0x100:
                self.ev.src_copy8 += 1
                return self.copy_body(n, 8)
        if self.D >= 0x5F:                                   # 239-241
            self.ev.edge_copy8 += 1
            return self.copy_body(n, 8)
        if n >= self.copy_thr:                               # 242-245
            self.ev.thr_copy8 += 1
            return self.copy_body(n, 8)
        self.take(n)                                         # 246
        self.de += n
        self.ev.fast_copy8 += 1
        self.ev.copy_fast_b += n

    # ---- gapped fast handlers ----
    def _gap_split(self, n):
        """vg_op_*8 .hcmp/.hsub/.hcmp2: None = the body, 0 = inside the
        column, else seg2 of a single crossing."""
        a = self.E + n
        if a > 0xFF:
            return None                                      # add a,c; jr c
        if a <= self.h:
            return 0                                         # jr c/jr z .in
        over = a - self.h
        if over >= self.h:
            return None                                      # cp h; jr nc .slow
        return over

    def _inline_hop(self):
        # ld e,0 / inc d, then cp $60; call nc, vid_dst_next (376-380, 422-426, 488-492)
        self.de = (self.D + 1) << 8
        if self.D >= 0x60:
            self.dst_next()
            self.ev.fast_dst_seams += 1

    def vg_skip8(self, n):
        self.take(1)                                         # 361-362
        seg2 = self._gap_split(n)                            # 363-375
        if seg2 is None:
            self.ev.gap_skip8 += 1
            return self.skip_body(n, 8)                      # .slow 386-388
        if seg2:
            self._inline_hop()                               # 376-381
            self.de |= seg2
            self.ev.fast_hop_skip8 += 1
        else:
            self.de += n                                     # .in 382-383
        self.ev.fast_skip8 += 1

    def vg_run8(self, n):
        self.take(1)                                         # 391-392
        if n >= self.run_thr:                                # 393-396
            self.take(1)
            self.ev.thr_run8 += 1
            return self.run_body(n, 8)
        seg2 = self._gap_split(n)                            # 398-409
        self.take(1)
        if seg2 is None:
            self.ev.gap_run8 += 1
            return self.run_body(n, 8)                       # .slow 440-444
        if seg2:
            seg1 = n - seg2                                  # 410-431
            self.ev.fast_hop_run8 += 1
            if seg1 == 0:
                self.ev.fast_hop0_run8 += 1
            self._inline_hop()
            self.de |= seg2
        else:
            self.de += n                                     # .in 433-437
        self.ev.fast_run8 += 1
        self.ev.run_fast_b += n

    def vg_copy8(self, n):
        self.take(1)                                         # 455-457
        if self.H() >= 0xDF:                                 # 458-460, .srcedge 499-503
            self.ev.copy8_srcedge += 1
            if self.L() + n > 0x100:
                self.ev.src_copy8 += 1
                return self.copy_body(n, 8)
        if n >= self.copy_thr:                               # 462-465
            self.ev.thr_copy8 += 1
            return self.copy_body(n, 8)
        seg2 = self._gap_split(n)                            # 466-477
        if seg2 is None:
            self.ev.gap_copy8 += 1
            return self.copy_body(n, 8)
        self.take(n)
        if seg2:
            seg1 = n - seg2                                  # 478-494
            self.ev.fast_hop_copy8 += 1
            if seg1 == 0:
                self.ev.fast_hop0_copy8 += 1
            self._inline_hop()
            self.de |= seg2
        else:
            self.de += n                                     # .in 495-496
        self.ev.fast_copy8 += 1
        self.ev.copy_fast_b += n

    # ---- chunked bodies ----
    def skip_body(self, remain, width):
        # vid_skip_body 624-648
        while remain:                                        # .seg 627-631
            self.norm()                                      # .dn 635
            chunk = min(remain, self.dst_room())             # .cd 637 (nocap)
            remain -= chunk
            self.de += chunk
            self.ev.skip_passes += 1

    def run_body(self, remain, width):
        # vid_run_body 650-680
        dma_seen = False
        while remain:                                        # .seg 654-658
            self.norm()                                      # .dn 660
            chunk = self.chunk_dst(remain)                   # .cd 662
            remain -= chunk
            if chunk >= self.run_thr:                        # 671-674
                self._bump("run_dma_chunks", width)
                self.ev.run_dma_b += chunk
                dma_seen = True
            else:
                self._bump("run_cpu_chunks", width)
                self.ev.run_cpu_b += chunk
                if dma_seen:
                    self._bump("run_tail", width)
            self.de += chunk

    def copy_body(self, remain, width):
        # vid_copy_body 682-710
        dma_seen = False
        while remain:                                        # .seg 685-688
            if self.H() >= 0xE0:                             # 689-691
                self.src_next()
            self.norm()                                      # .dn 693
            chunk = self.chunk_dst(remain)                   # vid_chunk_all 923
            if self.H() >= 0xDF:                             # 924-927, vid_chunk_src 1012-1027
                chunk = min(chunk, WIN_BYTES - self.w)
                self.ev.copy_src_chunks += 1
            remain -= chunk
            if chunk >= self.copy_thr:                       # 701-705
                self._bump("copy_dma_chunks", width)
                self.ev.copy_dma_b += chunk
                dma_seen = True
            else:
                self._bump("copy_ldi_chunks", width)
                self.ev.copy_ldi_b += chunk
                if dma_seen:
                    self._bump("copy_tail", width)
            self.take(chunk)
            self.de += chunk

    def _bump(self, name, width):
        key = f"{name}{width}"
        setattr(self.ev, key, getattr(self.ev, key) + 1)

    # ---- PAL, KSTART, terminals ----
    def pal(self):
        # vid_op_pal 1131-1133: H <= $DD takes the in-window unroll
        if self.H() < 0xDE:
            self.take(PAL_BYTES)                             # 1134-1147
            self.ev.pal_ops += 1
            return
        self.ev.pal_straddles += 1                           # .straddle 1148-1180
        remain = PAL_BYTES
        while remain:
            if self.H() >= 0xE0:                             # 1156-1158
                self.src_next()
            chunk = min(remain, WIN_BYTES - self.w)          # 1159
            remain -= chunk
            self.take(chunk)
            self.ev.pal_chunks += 1

    def kstart(self):
        # vid_op_kstart 1189-1205: a duplicate aborts; hidden surface, cursor 0
        if self.in_span:
            raise PathError("VID_ERR_OP: KSTART inside a span")
        self.in_span = True
        self.dpage, self.de = 0, DST_WIN
        self.ev.kstart += 1

    def terminal(self, op):
        if op == OP_KFLIP:
            # vid_op_kflip 1211-1221
            if not self.in_span:
                raise PathError("VID_ERR_OP: KFLIP with no span")
            self.in_span = False
            self.ev.kflip += 1
        elif self.in_span:
            self.ev.fend_span += 1                           # vid_op_fend 1227-1232
        else:
            self.ev.fend += 1                                # .plain 1233


def simulate(ops, surface, src_offset, *, dst=(0, DST_WIN), in_span=False,
             copy_thr=None, run_thr=None, dst_pages=None):
    """Run one payload's ops through the player path. -> (Events, State).

    ops: (opcode, n) through the terminal (parse_payload's form). surface:
    (width, height, gapped). src_offset: file/ring position of the first op
    byte. dst: (page, DE) at entry - (0, $4000) fresh, the spilled cursor for
    a span continuation. copy_thr/run_thr: kernel selects, None = the model's
    copy_dma_min/run_dma_min. dst_pages: None = the surface's page count."""
    p = _Player(surface, src_offset, dst, in_span, copy_thr, run_thr, dst_pages)
    p.run(ops)
    return p.ev, State(p.dpage, p.de, p.in_span, p.page * WIN_BYTES + p.w)


def events(ops, surface, src_offset, **kw):
    """Events for one payload; keywords as simulate()."""
    return simulate(ops, surface, src_offset, **kw)[0]
