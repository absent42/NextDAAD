#!/usr/bin/env python3
"""Old-path guard: the existing video hot routines keep their emitted bytes.

For each name in PROTECTED, the routine's bytes in build\\nextdaad.nex must equal its bytes
in the baseline image captured at the branch point, wherever either copy sits. A routine
is the span from its label to the next non-local address label in the same page of the
same SLD. The one allowance: a 16-bit operand whose old and new values read as the same
label plus the same offset (old SLD vs new SLD, see targets()). MAY_CHANGE lists the only
other exceptions. A routine with no closing jp/jr/ret must still run on into the same label.

    .\\build.ps1            then  python tests\\vidraw_oldpaths.py --variant debug
    .\\build.ps1 -Release   then  python tests\\vidraw_oldpaths.py --variant release
    python tests\\vidraw_oldpaths.py --selftest

Baselines read: tests\\out\\vidraw-base\\debug.nex, debug.sld, release.nex, release.sld.
Exit 0 = every routine equal; 1 = a difference or a missing routine; 2 = setup error.
"""

import argparse
import bisect
import shutil
import sys
import tempfile
from collections import namedtuple
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dma_contract as dc    # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BUILD_NEX = ROOT / "build" / "nextdaad.nex"
BUILD_SLD = ROOT / "build" / "nextdaad.sld"
BASE_DIR = ROOT / "tests" / "out" / "vidraw-base"
DEBUG_MARKER = "dbgNoBank"      # DEBUG-only symbol, as tests\ddma_contract.py reads it
PAGE = 8192
MAX_LISTED = 16                 # differences listed per routine

PROTECTED = [
    "video_ctc_isr_stereo", "vid_decode_frame", "vid_decode_frame_ds", "vid_decode_any",
    "vid_ds_next", "vid_ds_byte", "vid_ds_blkopen", "vid_ds_pad", "vid_ds_xfer",
    "vid_ds_copy_body", "vid_ds_pal", "vid_ds_done", "vid_pace_poll", "vid_aud_stage",
    "vid_aud_pump", "vid_loop_rewind", "vid_dst_setup", "vid_dst_base", "vid_dst_next",
    "vid_dst_norm_gap", "vid_dst_norm_flat", "vid_run_walk_h", "vid_next_run_h", "vid_run",
]

# (routine, variant, call targets). In that variant, every `call nn` (CD lo hi) in the new
# routine whose operand is exactly a listed label is removed - each name exactly once - and
# the rest is compared instruction by instruction; jr/djnz by the instruction they land on.
MAY_CHANGE = []


class Setup(Exception):
    pass


class Undecodable(Exception):
    def __init__(self, off, code):
        super().__init__(f"undecodable opcode {code.hex().upper()} at +{off}")
        self.off = off


# ---------------------------------------------------------------- Z80 / Z80N decoder

# op: offset of the 16-bit operand or None. kind: "imm" (a value), "mem" (an address
# read, written or jumped to), "rel" (jr/djnz) or None.
Insn = namedtuple("Insn", "off size op big kind")
Rout = namedtuple("Rout", "page start end buf")

N8 = {0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E, 0xC6, 0xCE, 0xD6, 0xDE,
      0xE6, 0xEE, 0xF6, 0xFE, 0xD3, 0xDB}
REL = {0x10, 0x18, 0x20, 0x28, 0x30, 0x38}
NN_IMM = {0x01, 0x11, 0x21, 0x31}
NN_MEM = ({0x22, 0x2A, 0x32, 0x3A, 0xC3, 0xCD}
          | {0xC2 + 8 * k for k in range(8)} | {0xC4 + 8 * k for k in range(8)})
IX_MEM = {0x34, 0x35, 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E, 0x70, 0x71, 0x72, 0x73,
          0x74, 0x75, 0x77, 0x86, 0x8E, 0x96, 0x9E, 0xA6, 0xAE, 0xB6, 0xBE}
IX_ONE = ({0x09, 0x19, 0x29, 0x39, 0x23, 0x2B, 0x24, 0x25, 0x2C, 0x2D, 0xE1, 0xE3, 0xE5,
           0xE9, 0xF9, 0x44, 0x45, 0x4C, 0x4D, 0x54, 0x55, 0x5C, 0x5D, 0x7C, 0x7D,
           0x84, 0x85, 0x8C, 0x8D, 0x94, 0x95, 0x9C, 0x9D, 0xA4, 0xA5, 0xAC, 0xAD,
           0xB4, 0xB5, 0xBC, 0xBD}
          | (set(range(0x60, 0x70)) - {0x66, 0x6E}))
ED_ONE = ({0x40, 0x41, 0x42, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4D, 0x4F,
           0x50, 0x51, 0x52, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5E, 0x5F, 0x60, 0x61,
           0x62, 0x67, 0x68, 0x69, 0x6A, 0x6F, 0x70, 0x71, 0x72, 0x78, 0x79, 0x7A}
          | {0xA0, 0xA1, 0xA2, 0xA3, 0xA8, 0xA9, 0xAA, 0xAB,
             0xB0, 0xB1, 0xB2, 0xB3, 0xB8, 0xB9, 0xBA, 0xBB}
          # Z80N: swapnib mirror bsla bsra bsrl bsrf brlc mul add rr,a outinb pixeldn
          # pixelad setae jp (c) ldix ldws lddx ldirx ldpirx lddrx
          | {0x23, 0x24, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x30, 0x31, 0x32, 0x33,
             0x90, 0x93, 0x94, 0x95, 0x98, 0xA4, 0xA5, 0xAC, 0xB4, 0xB7, 0xBC})
ED_NN = {0x43, 0x4B, 0x53, 0x5B, 0x63, 0x6B, 0x73, 0x7B}     # ld (nn),rr / ld rr,(nn)


def insn(buf, i):
    """(size, op, big, kind) of the instruction at buf[i]; raises Undecodable."""
    def need(n):
        if i + n > len(buf):
            raise Undecodable(i, bytes(buf[i:]))
    need(1)
    b = buf[i]
    if b == 0xCB:
        need(2)
        return 2, None, False, None
    if b in (0xDD, 0xFD):
        need(2)
        c = buf[i + 1]
        if c in (0xCB, 0x36):
            need(4)
            return 4, None, False, None
        if c in (0x21, 0x22, 0x2A):
            need(4)
            return 4, 2, False, "imm" if c == 0x21 else "mem"
        if c in IX_MEM or c in (0x26, 0x2E):
            need(3)
            return 3, None, False, None
        if c in IX_ONE:
            return 2, None, False, None
        raise Undecodable(i, bytes(buf[i:i + 2]))
    if b == 0xED:
        need(2)
        c = buf[i + 1]
        if c in ED_ONE:
            return 2, None, False, None
        if c in ED_NN:
            need(4)
            return 4, 2, False, "mem"
        if c in (0x34, 0x35, 0x36):                         # Z80N add hl/de/bc,nn
            need(4)
            return 4, 2, False, "imm"
        if c == 0x8A:                                       # Z80N push nn: high byte first
            need(4)
            return 4, 2, True, "imm"
        if c in (0x27, 0x92, 0xC7):     # test n / nextreg r,a / NRGET's nextreg a,r (3.03.03)
            need(3)
            return 3, None, False, None
        if c == 0x91:                                       # nextreg r,n
            need(4)
            return 4, None, False, None
        raise Undecodable(i, bytes(buf[i:i + 2]))
    if b in N8:
        need(2)
        return 2, None, False, None
    if b in REL:
        need(2)
        return 2, None, False, "rel"
    if b in NN_IMM or b in NN_MEM:
        need(3)
        return 3, 1, False, "imm" if b in NN_IMM else "mem"
    return 1, None, False, None


def decode(buf, stop=None):
    """Instruction list for buf (up to offset stop); raises Undecodable."""
    out, i = [], 0
    while i < len(buf) and (stop is None or i < stop):
        size, op, big, kind = insn(buf, i)
        out.append(Insn(i, size, op, big, kind))
        i += size
    return out


def op16(buf, ins):
    lo, hi = buf[ins.off + ins.op], buf[ins.off + ins.op + 1]
    return (lo << 8 | hi) if ins.big else (hi << 8 | lo)


def rel_target(buf, ins):
    d = buf[ins.off + 1]
    return ins.off + 2 + (d - 256 if d > 127 else d)


def ends_flow(buf, ins):
    """True when the instruction never falls through: jp, jr, ret, reti, retn, jp (rr)."""
    b = bytes(buf[ins.off:ins.off + ins.size])
    return b[0] in (0xC3, 0xC9, 0x18, 0xE9) or b in (
        b"\xED\x4D", b"\xED\x45", b"\xED\x98", b"\xDD\xE9", b"\xFD\xE9")


def same_shape(ob, oi, nb, ni):
    """Same size and operand slot, and equal bytes outside the 16-bit operand."""
    if oi.size != ni.size or oi.op != ni.op or oi.big != ni.big or oi.op is None:
        return False
    keep = [k for k in range(oi.size) if k not in (oi.op, oi.op + 1)]
    return all(ob[oi.off + k] == nb[ni.off + k] for k in keep)


# ---------------------------------------------------------------- images

class Image:
    """One build: symbols, SLD instruction-line addresses (T records) and NEX pages."""

    def __init__(self, label, syms, local, equ, trace, page_fn):
        self.label = label
        self.syms = syms                # name -> (page, value); page -1 = EQU
        self.local, self.equ = local, equ
        self.trace = trace              # page -> set of instruction-line addresses, or None
        self._page_fn = page_fn
        self._pages = {}
        self.bypage = {}                # page -> (sorted values, names): address labels
        self.nonlocal_ = {}             # page -> sorted values of non-local address labels
        self.slot_pages = {}            # 8K slot -> pages holding address labels in it
        rows = {}
        for name, (page, value) in syms.items():
            if page < 0 or name in equ:
                continue
            rows.setdefault(page, []).append((value, name))
            self.slot_pages.setdefault(value >> 13, set()).add(page)
            if name not in local:
                self.nonlocal_.setdefault(page, []).append(value)
        for page, r in rows.items():
            r.sort()
            self.bypage[page] = ([v for v, _ in r], [n for _, n in r])
        for page in self.nonlocal_:
            self.nonlocal_[page].sort()

    def page(self, p):
        if p not in self._pages:
            self._pages[p] = bytes(self._page_fn(p))
        return self._pages[p]

    def routine(self, name):
        """Rout for name; raises Setup naming the routine."""
        if name not in self.syms:
            raise Setup(f"{name}: not in the {self.label} SLD")
        page, start = self.syms[name]
        if page < 0 or name in self.equ or name in self.local:
            raise Setup(f"{name}: not a non-local address label in the {self.label} SLD")
        vals = self.nonlocal_.get(page, [])
        k = bisect.bisect_right(vals, start)
        base = start & ~(PAGE - 1)
        if k >= len(vals) or vals[k] >= base + PAGE:
            raise Setup(f"{name}: no following non-local label in page {page} of the "
                        f"{self.label} SLD - routine end unknown")
        end = vals[k]
        return Rout(page, start, end, self.page(page)[start - base:end - base])

    def successors(self, rout):
        """Names of the non-local address labels that end rout."""
        vals, names = self.bypage[rout.page]
        lo, hi = bisect.bisect_left(vals, rout.end), bisect.bisect_right(vals, rout.end)
        return {n for n in names[lo:hi] if n not in self.local}

    def resolve(self, v, page):
        """{(label, offset)}: the address labels of page nearest at or below v, same slot."""
        vals, names = self.bypage.get(page, ([], []))
        i = bisect.bisect_right(vals, v) - 1
        if i < 0 or vals[i] >> 13 != v >> 13:
            return set()
        at, out = vals[i], set()
        while i >= 0 and vals[i] == at:
            out.add((names[i], v - at))
            i -= 1
        return out

    def targets(self, rout, kind, v):
        """(label, offset) readings of operand v in rout. Own slot: the running page is mapped,
        so mem/rel read only it; imm reads it at any offset, other pages as exact labels only.
        Other slots: a lone page at any offset, several pages as exact labels only."""
        slot = v >> 13
        pages = self.slot_pages.get(slot, set())
        if slot == rout.start >> 13:
            own = rout.page
            if kind in ("mem", "rel"):
                pages = {own}
        else:
            own = next(iter(pages)) if len(pages) == 1 else None
        out = set()
        for p in pages:
            r = self.resolve(v, p)
            out |= r if p == own else {x for x in r if x[1] == 0}
        return out

    def check_trace(self, rout, ins):
        """Offset of an SLD instruction-line address that no decoded instruction starts at."""
        if self.trace is None:
            return None
        starts = {x.off for x in ins}
        for a in sorted(self.trace.get(rout.page, ())):
            if rout.start <= a < rout.end and (a - rout.start) not in starts:
                return a - rout.start
        return None


def sld_extra(path):
    """(local names, equ names, page -> T-record addresses) from an SLD file."""
    local, equ, trace = set(), set(), {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split("|")
        if len(f) < 8:
            continue
        if f[6] == "T":
            try:
                trace.setdefault(int(f[4]), set()).add(int(f[5]))
            except ValueError:
                continue
        elif f[6] == "L":
            d = f[7].split(",")
            if len(d) < 3:
                continue
            name = ".".join(x for x in d[:3] if x)
            if "+local" in d[3:]:
                local.add(name)
            if "+equ" in d[3:]:
                equ.add(name)
    return local, equ, trace


def load(label, nex, sld):
    nex, sld = Path(nex), Path(sld)
    for p in (nex, sld):
        if not p.exists():
            raise Setup(f"{p} is missing")
    dc.SLD = sld
    syms = dc.read_sld()
    local, equ, trace = sld_extra(sld)

    def page_fn(p):
        dc.NEX = nex
        try:
            return dc.read_page(p)
        except dc.Fail as exc:
            raise Setup(f"{label}: {exc}")
    return Image(label, syms, local, equ, trace, page_fn)


def same_target(old, orout, vo, new, nrout, vn, kind):
    return vo == vn or bool(old.targets(orout, kind, vo) & new.targets(nrout, kind, vn))


# ---------------------------------------------------------------- comparison

def decode_routine(img, rout):
    """(instructions, fault offset or None, fault text); a fault ends the list."""
    try:
        ins = decode(rout.buf)
    except Undecodable as exc:
        return decode(rout.buf, exc.off), exc.off, str(exc)
    bad = img.check_trace(rout, ins)
    if bad is not None:
        return ins, bad, f"SLD instruction line at +{bad} is inside a decoded instruction"
    return ins, None, None


def decode_pair(name, old, orout, new, nrout):
    oi, ofault, omsg = decode_routine(old, orout)
    if ofault is not None:
        raise Setup(f"{name}: baseline does not decode - {omsg}")
    ni, nfault, nmsg = decode_routine(new, nrout)
    return oi, ni, nfault, nmsg


def at(buf, o):
    return buf[o] if o < len(buf) else None


def compare_plain(name, old, orout, new, nrout):
    """([(offset, old byte, new byte, note)], relocated operand count)."""
    ob, nb = orout.buf, nrout.buf
    oi, ni, nfault, nmsg = decode_pair(name, old, orout, new, nrout)
    notes = {}                       # offset -> note; every offset listed once
    if nfault is not None:
        notes[nfault] = nmsg
    owner = {x.off + k: x for x in oi for k in range(x.size)}
    nstart = {x.off: x for x in ni}
    verdict = {}
    for o in range(min(len(ob), len(nb))):
        if ob[o] == nb[o]:
            continue
        x = owner[o]
        if x.off not in verdict:
            y = nstart.get(x.off)
            verdict[x.off] = (y is not None and same_shape(ob, x, nb, y)
                              and same_target(old, orout, op16(ob, x), new, nrout,
                                              op16(nb, y), x.kind))
        if not verdict[x.off]:
            notes.setdefault(o, "")
    if len(ob) != len(nb):
        o = min(len(ob), len(nb))
        notes[o] = "; ".join(s for s in (notes.get(o), f"length old {len(ob)} new {len(nb)}")
                             if s)
    diffs = [(o, at(ob, o), at(nb, o), notes[o]) for o in sorted(notes)]
    return diffs, sum(verdict.values())


def compare_aligned(name, old, orout, new, nrout, calls):
    """compare_plain's result for a MAY_CHANGE routine, plus the removed call count."""
    ob, nb = orout.buf, nrout.buf
    oi, ni, nfault, nmsg = decode_pair(name, old, orout, new, nrout)
    if nfault is not None:
        return [(nfault, at(ob, nfault), at(nb, nfault), nmsg)], 0, 0
    diffs = []
    seen = {c: 0 for c in calls}
    kept = []
    for y in ni:
        hit = None
        if y.size == 3 and nb[y.off] == 0xCD:
            names = {n for n, off in new.targets(nrout, "mem", op16(nb, y)) if off == 0}
            hit = next((c for c in calls if c in names), None)
        if hit:
            seen[hit] += 1
        else:
            kept.append(y)
    for c, n in seen.items():
        if n != 1:
            diffs.append((0, None, None, f"call {c} inserted {n} times, want exactly 1"))
    oidx = {x.off: k for k, x in enumerate(oi)}
    oidx[len(ob)] = len(oi)
    nidx, k = {}, 0
    for y in ni:                     # a removed call maps to the next kept instruction
        nidx[y.off] = k
        if k < len(kept) and kept[k] is y:
            k += 1
    nidx[len(nb)] = len(kept)
    relocated = 0
    for x, y in zip(oi, kept):
        xb, yb = ob[x.off:x.off + x.size], nb[y.off:y.off + y.size]
        why = f"instruction old {xb.hex().upper()} new {yb.hex().upper()}"
        if x.kind == "rel" or y.kind == "rel":
            ok = x.kind == y.kind and xb[0] == yb[0]
            if ok:
                to, tn = rel_target(ob, x), rel_target(nb, y)
                inside_o, inside_n = 0 <= to <= len(ob), 0 <= tn <= len(nb)
                if inside_o and inside_n:
                    ok = to in oidx and tn in nidx and oidx[to] == nidx[tn]
                    why += f", lands on old +{to} new +{tn}, not the same instruction"
                elif not inside_o and not inside_n:
                    ok = same_target(old, orout, orout.start + to, new, nrout,
                                     nrout.start + tn, "rel")
                    why += ", lands outside on different targets"
                else:
                    ok = False
                    why += ", lands inside the routine on one side only"
        elif xb == yb:
            ok = True
        else:
            ok = same_shape(ob, x, nb, y) and same_target(
                old, orout, op16(ob, x), new, nrout, op16(nb, y), x.kind)
            relocated += ok
        if not ok:
            k = next((j for j in range(min(x.size, y.size)) if xb[j] != yb[j]), 0)
            diffs.append((x.off + k, at(xb, k), at(yb, k), why))
    if len(oi) != len(kept):
        diffs.append((len(ob), None, None,
                      f"instruction count old {len(oi)} new {len(kept)} after removal"))
    return sorted(diffs, key=lambda d: d[0]), relocated, sum(seen.values())


def byte_str(b):
    return "--" if b is None else f"{b:02X}"


def guard(variant, old, new, names, may_change, out):
    """Compare every routine in names; returns the exit code."""
    for r, v, _ in may_change:
        if r not in names or v not in ("debug", "release"):
            raise Setup(f"MAY_CHANGE entry ({r}, {v}) names no protected routine/variant")
    entries = {r: calls for r, v, calls in may_change if v == variant}
    total, failed, relocated, removed, missing = 0, 0, 0, 0, 0
    for name in names:
        try:
            orout = old.routine(name)
            nrout = new.routine(name)
        except Setup as exc:
            out(f"  MISSING {exc}")
            missing += 1
            continue
        if name in entries:
            diffs, rel, rem = compare_aligned(name, old, orout, new, nrout, entries[name])
            removed += rem
        else:
            diffs, rel = compare_plain(name, old, orout, new, nrout)
        relocated += rel
        last = decode(orout.buf)[-1]
        so, sn = old.successors(orout), new.successors(nrout)
        if not ends_flow(orout.buf, last) and not so & sn:
            diffs.append((len(orout.buf), None, None,
                          f"runs on into {'/'.join(sorted(so))} in the baseline, "
                          f"{'/'.join(sorted(sn))} in the build"))
        if diffs:
            failed += 1
            total += len(diffs)
            for o, a, b, note in diffs[:MAX_LISTED]:
                out(f"  DIFF {name} +{o}: old {byte_str(a)} new {byte_str(b)}"
                    + (f" ({note})" if note else ""))
            if len(diffs) > MAX_LISTED:
                out(f"  DIFF {name}: {len(diffs) - MAX_LISTED} more")
    n = len(names)
    if total == 0 and missing == 0:
        out(f"vidraw_oldpaths: {variant}: 0 differences in {n} routines")
        if relocated or removed:
            out(f"vidraw_oldpaths: {variant}: {relocated} relocated operands, "
                f"{removed} MAY_CHANGE calls removed")
        return 0
    out(f"vidraw_oldpaths: {variant}: FAIL - {total} differences in {failed} of {n} "
        f"routines, {missing} routines missing")
    return 1


def run(variant):
    base = load("baseline", BASE_DIR / f"{variant}.nex", BASE_DIR / f"{variant}.sld")
    new = load("build", BUILD_NEX, BUILD_SLD)
    is_debug = DEBUG_MARKER in new.syms
    if is_debug != (variant == "debug"):
        raise Setup(f"{BUILD_NEX.relative_to(ROOT)} is a "
                    f"{'DEBUG' if is_debug else 'Release'} build; run .\\build.ps1"
                    f"{'' if variant == 'debug' else ' -Release'} first")
    return guard(variant, base, new, PROTECTED, MAY_CHANGE, print)


# ---------------------------------------------------------------- selftest

def page_offset(nex_bytes, page):
    present = [b for b in dc.NEX_BANK_ORDER if nex_bytes[18 + b]]
    return 512 + 16384 * present.index(page // 2) + 8192 * (page % 2)


def write_copy(tmp, tag, base_nex, base_sld, page=None, page_bytes=None, sld_lines=None):
    nex, sld = Path(tmp) / f"{tag}.nex", Path(tmp) / f"{tag}.sld"
    d = bytearray(Path(base_nex).read_bytes())
    if page is not None:
        o = page_offset(d, page)
        d[o:o + PAGE] = page_bytes
    nex.write_bytes(bytes(d))
    if sld_lines is None:
        shutil.copyfile(base_sld, sld)
    else:
        sld.write_text("\n".join(sld_lines) + "\n", encoding="utf-8")
    return nex, sld


def poke(img, tmp, tag, files, name, off, values):
    """Copy of files (img's NEX and SLD) with bytes at name+off replaced."""
    r = img.routine(name)
    pb = bytearray(img.page(r.page))
    o = (r.start & (PAGE - 1)) + off
    pb[o:o + len(values)] = bytes(values)
    return write_copy(tmp, tag, *files, r.page, pb)


def shifted(base, tmp, tag, files, addr_name, delta, ins, label=None):
    """Copy of the baseline with ins inserted at addr_name+delta (under a new non-local
    label when label is given): page bytes, SLD addresses, protected 16-bit operands and
    crossing relative branches all moved as the assembler would move them."""
    r0 = base.routine(addr_name)
    page, a, n = r0.page, r0.start + delta, len(ins)
    lo = r0.start & ~(PAGE - 1)
    pb = bytearray(base.page(page))
    old_pb = bytes(pb)
    top = base.bypage[page][0][-1] + 16     # past the last label: constants, not references

    def moved(x):
        return x + n if x >= a else x
    for name in PROTECTED:
        r = base.routine(name)
        if r.page != page:
            continue
        if r.end + n > lo + PAGE:
            raise Setup(f"selftest: shift pushes {name} off its page")
        ins_list = decode(r.buf)
        if r.start < a < r.end and (a - r.start) not in {x.off for x in ins_list}:
            raise Setup(f"selftest: insertion point splits an instruction in {name}")
        for x in ins_list:
            src = r.start + x.off
            if x.op is not None:
                v = op16(r.buf, x)
                if a <= v < top:
                    v += n
                    pb[src - lo + x.op:src - lo + x.op + 2] = (
                        bytes([v >> 8, v & 0xFF]) if x.big else bytes([v & 0xFF, v >> 8]))
            if x.kind == "rel":
                d = moved(r.start + rel_target(r.buf, x)) - (moved(src) + 2)
                if not -128 <= d <= 127:
                    raise Setup(f"selftest: shift puts a branch in {name} out of range")
                pb[src - lo + 1] = d & 0xFF
    if any(old_pb[PAGE - n:]):
        raise Setup("selftest: shift drops non-zero bytes at the page end")
    o = a - lo
    new_pb = pb[:o] + bytearray(ins) + pb[o:PAGE - n]
    lines = []
    for line in Path(files[1]).read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split("|")
        if len(f) >= 8 and f[6] in ("F", "L", "T") and f[4] == str(page):
            v = int(f[5])
            if v >= a:
                f[5] = str(v + n)
                line = "|".join(f)
        lines.append(line)
    if label:
        lines += [f"selftest|1||0|{page}|{a}|F|{label}",
                  f"selftest|1||0|{page}|{a}|L|,{label},,+used"]
    return write_copy(tmp, tag, *files, page, new_pb, lines)


def without(tmp, tag, files, name):
    """Copy of files whose SLD lacks the label name."""
    lines = []
    for line in Path(files[1]).read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split("|")
        if len(f) >= 8 and ((f[6] == "F" and f[7] == name)
                            or (f[6] == "L" and f[7].startswith(f",{name},,"))):
            continue
        lines.append(line)
    return write_copy(tmp, tag, *files, sld_lines=lines)


def find_insn(img, name, pred):
    buf = img.routine(name).buf
    for x in decode(buf):
        if pred(buf, x):
            return x
    raise Setup(f"selftest: no matching instruction in {name}")


def mem_image(syms, pages, local=()):
    return Image("synthetic", syms, set(local), set(), None, lambda p: pages[p])


def synthetic(point=b"", jr_disp=None, jr_as_jp=False):
    """syn_run at $E000 and call targets at $E100, page 59. syn_run is
    ld b,4 / .top: inc a / jr z,.x / jp nz,.y / [point] / dec a / djnz .top / nop /
    .y: nop / .x: ret, then syn_end. jr z spans the point forward, djnz backward."""
    n, w = len(point), 1 if jr_as_jp else 0
    y, x, end = 12 + w + n, 13 + w + n, 14 + w + n
    body = bytearray([0x06, 0x04, 0x3C])
    if jr_as_jp:
        body += bytes([0xCA, x, 0xE0])
    else:
        body += bytes([0x28, x - 5 if jr_disp is None else jr_disp])
    body += bytes([0xC2, y, 0xE0]) + bytes(point)
    body += bytes([0x3D, 0x10, -(9 + w + n) & 0xFF, 0x00, 0x00, 0xC9])
    assert len(body) == end
    syms = {"syn_run": (59, 0xE000), "syn_run.top": (59, 0xE002),
            "syn_run.y": (59, 0xE000 + y), "syn_run.x": (59, 0xE000 + x),
            "syn_end": (59, 0xE000 + end), "vid_dbg_late": (59, 0xE100),
            "vid_dbg_urun": (59, 0xE103), "vid_other": (59, 0xE106)}
    pb = bytearray(PAGE)
    pb[:end] = body
    pb[0x100:0x109] = bytes([0xC9] * 9)
    return mem_image(syms, {59: pb}, ("syn_run.top", "syn_run.y", "syn_run.x"))


def crosspage(code, cold):
    """syn_ref at $E000 (page 59): code then ret; cells cellA $E100, cellB $E104 in page
    59; label cold at the given address in page 57 (another page sharing slot 7)."""
    pb = bytearray(PAGE)
    pb[:len(code) + 1] = bytes(code) + b"\xC9"
    syms = {"syn_ref": (59, 0xE000), "syn_ref_end": (59, 0xE000 + len(code) + 1),
            "cellA": (59, 0xE100), "cellB": (59, 0xE104), "cold": (57, cold)}
    return mem_image(syms, {59: pb, 57: bytes(PAGE)})


def call_to(addr):
    return bytes([0xCD, addr & 0xFF, addr >> 8])


def selftest():
    dfiles = (BASE_DIR / "debug.nex", BASE_DIR / "debug.sld")
    rfiles = (BASE_DIR / "release.nex", BASE_DIR / "release.sld")
    base = load("baseline", *dfiles)
    rbase = load("baseline", *rfiles)
    results = []

    def check(title, old, new, want, names=PROTECTED, variant="debug", may=(), expect=()):
        lines = []
        try:
            code = guard(variant, old, new, names, list(may), lines.append)
        except Setup as exc:
            code, lines = 2, [f"SETUP {exc}"]
        text = "\n".join(lines)
        ok = code == want and all(e in text for e in expect)
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {title}: exit {code}")
        for line in lines if (not ok or want) else lines[1:]:
            print(f"     {line}")

    def img(files):
        return load("build", *files)

    with tempfile.TemporaryDirectory() as tmp:
        check("baseline debug vs itself", base, base, 0,
              expect=["0 differences in 24 routines"])
        check("baseline release vs itself", rbase, rbase, 0, variant="release",
              expect=["0 differences in 24 routines"])

        x = find_insn(base, "vid_ds_xfer", lambda b, i: b[i.off] == 0xB1)
        check("flip one opcode byte in vid_ds_xfer (or c -> or b)", base,
              img(poke(base, tmp, "flip", dfiles, "vid_ds_xfer", x.off, [0xB0])), 1,
              expect=[f"DIFF vid_ds_xfer +{x.off}: old B1 new B0", "1 differences in 1 of 24"])

        x = find_insn(base, "vid_ds_xfer", lambda b, i: b[i.off:i.off + 2] == b"\xE6\x1F")
        check("8-bit immediate changed in vid_ds_xfer (and 31 -> and 30)", base,
              img(poke(base, tmp, "imm", dfiles, "vid_ds_xfer", x.off + 1, [0x1E])), 1,
              expect=[f"DIFF vid_ds_xfer +{x.off + 1}: old 1F new 1E"])

        blk = base.syms["vid_ds_blkopen"][1]
        pad = base.syms["vid_ds_pad"][1]
        x = find_insn(base, "vid_ds_xfer", lambda b, i: b[i.off] == 0xCC and op16(b, i) == blk)
        check("16-bit operand pointed at another symbol (call z,vid_ds_pad)", base,
              img(poke(base, tmp, "sym", dfiles, "vid_ds_xfer", x.off + 1,
                       [pad & 0xFF, pad >> 8])), 1,
              expect=[f"DIFF vid_ds_xfer +{x.off + 1}:"])
        check("16-bit operand moved one byte (call z,vid_ds_blkopen+1)", base,
              img(poke(base, tmp, "off1", dfiles, "vid_ds_xfer", x.off + 1,
                       [(blk + 1) & 0xFF, (blk + 1) >> 8])), 1,
              expect=[f"DIFF vid_ds_xfer +{x.off + 1}:"])

        sfiles = shifted(base, tmp, "shift", dfiles, "vid_ds_xfer", 0, b"\0\0\0",
                         label="vidraw_selftest_ins")
        sh = img(sfiles)
        check("insert 3 bytes before vid_ds_xfer, symbols and operands moved", base, sh, 0,
              expect=["0 differences in 24 routines", "relocated operands"])

        xfer = base.syms["vid_ds_xfer"][1] + 3
        x = find_insn(sh, "vid_ds_copy_body",
                      lambda b, i: b[i.off] == 0xCD and op16(b, i) == xfer)
        check("shifted copy with one call operand relocated by 2, not 3", base,
              img(poke(sh, tmp, "wrong", sfiles, "vid_ds_copy_body", x.off + 1,
                       [(xfer - 1) & 0xFF, (xfer - 1) >> 8])), 1,
              expect=[f"DIFF vid_ds_copy_body +{x.off + 1}:", "in 1 of 24"])

        check("labelled 3 bytes inserted where vid_dst_setup runs on into vid_dst_base", base,
              img(shifted(base, tmp, "runon", dfiles, "vid_dst_base", 0, b"\0\0\0",
                          label="vidraw_selftest_runon")), 1,
              expect=["runs on into vid_dst_base in the baseline, vidraw_selftest_runon in "
                      "the build", "in 1 of 24"])

        check("insert a nop inside vid_ds_pad, the rest moved", base,
              img(shifted(base, tmp, "nop", dfiles, "vid_ds_pad", 3, b"\0")), 1,
              expect=["DIFF vid_ds_pad +3: old DB new 00", "length old 11 new 12",
                      "in 1 of 24"])

        x = find_insn(base, "vid_ds_xfer", lambda b, i: b[i.off] == 0xB1)
        check("undecodable opcode in the build (ED 00 over or c / ret z)", base,
              img(poke(base, tmp, "undec", dfiles, "vid_ds_xfer", x.off, [0xED, 0x00])), 1,
              expect=[f"DIFF vid_ds_xfer +{x.off}: old B1 new ED (undecodable opcode ED00"])

        x = find_insn(base, "vid_ds_xfer", lambda b, i: b[i.off] == 0xCC)
        r = base.routine("vid_ds_xfer")
        extra = [f"selftest|1||0|{r.page}|{r.start + x.off + 1}|T|"]
        lines = Path(dfiles[1]).read_text(encoding="utf-8").splitlines() + extra
        check("SLD instruction line inside a decoded instruction", base,
              img(write_copy(tmp, "desync", *dfiles, sld_lines=lines)), 1,
              expect=[f"SLD instruction line at +{x.off + 1} is inside a decoded instruction"])

        a4 = r.start + 4
        extra = [f"selftest|1||0|-1|{a4}|D|vidraw_selftest_equ",
                 f"selftest|1||0|-1|{a4}|L|,vidraw_selftest_equ,,+equ",
                 f"selftest|1||0|{r.page}|{a4}|D|vidraw_selftest_equp",
                 f"selftest|1||0|{r.page}|{a4}|L|,vidraw_selftest_equp,,+equ",
                 f"selftest|1||0|58|{a4}|F|vidraw_selftest_p58",
                 f"selftest|1||0|58|{a4}|L|,vidraw_selftest_p58,,+used",
                 f"selftest|1||0|{r.page}|{a4}|F|vid_ds_xfer.vidraw_selftest",
                 f"selftest|1||0|{r.page}|{a4}|L|,vid_ds_xfer,vidraw_selftest,+local"]
        lines = Path(dfiles[1]).read_text(encoding="utf-8").splitlines() + extra
        check("equ, page 58 and local labels inside vid_ds_xfer do not end it", base,
              img(write_copy(tmp, "spans", *dfiles, sld_lines=lines)), 0,
              expect=["0 differences in 24 routines"])

        check("protected label missing from the build SLD", base,
              img(without(tmp, "miss", dfiles, "vid_ds_pal")), 1,
              expect=["MISSING vid_ds_pal: not in the build SLD"])
        check("protected label missing from the baseline SLD",
              load("baseline", *without(tmp, "missb", dfiles, "vid_aud_stage")), base, 1,
              expect=["MISSING vid_aud_stage: not in the baseline SLD"])

    ref = ["syn_ref"]
    check("cross-page: ld a,(cellA) -> (cellB) while page 57 moved by the same 4", crosspage(
        b"\x3A\x00\xE1", 0xE0F0), crosspage(b"\x3A\x04\xE1", 0xE0F4), 1, names=ref)
    check("cross-page: ld hl,cellA -> cellB while page 57 moved by the same 4", crosspage(
        b"\x21\x00\xE1", 0xE0F0), crosspage(b"\x21\x04\xE1", 0xE0F4), 1, names=ref)
    check("cross-page: ld hl,cold with cold moved in page 57", crosspage(
        b"\x21\xF0\xE0", 0xE0F0), crosspage(b"\x21\xF4\xE0", 0xE0F4), 0, names=ref,
        expect=["1 relocated operands"])

    syn = ["syn_run"]
    may = [("syn_run", "debug", ("vid_dbg_late",))]
    old = synthetic()
    check("synthetic: allowed call inserted over jr/djnz/jp", old,
          synthetic(call_to(0xE100)), 0, names=syn, may=may,
          expect=["0 differences in 1 routines", "1 MAY_CHANGE calls removed"])
    check("synthetic: unlisted call inserted", old,
          synthetic(call_to(0xE106)), 1, names=syn, may=may)
    check("synthetic: ld hl,nn inserted", old,
          synthetic(bytes([0x21, 0x00, 0xE1])), 1, names=syn, may=may)
    check("synthetic: allowed call, jr displacement not adjusted", old,
          synthetic(call_to(0xE100), jr_disp=8), 1, names=syn, may=may)
    check("synthetic: allowed call, jr lands on another instruction", old,
          synthetic(call_to(0xE100), jr_disp=9), 1, names=syn, may=may)
    check("synthetic: allowed call, jr widened to jp", old,
          synthetic(call_to(0xE100), jr_as_jp=True), 1, names=syn, may=may)
    check("synthetic: allowed call inserted twice", old,
          synthetic(call_to(0xE100) * 2), 1, names=syn, may=may)
    check("synthetic: entry listed but no call inserted", old, synthetic(), 1,
          names=syn, may=may)
    check("synthetic: allowed call in the other variant", old,
          synthetic(call_to(0xE100)), 1, names=syn, may=may, variant="release")
    check("synthetic: allowed call with no entry", old,
          synthetic(call_to(0xE100)), 1, names=syn)

    bad = results.count(False)
    print(f"vidraw_oldpaths: selftest {len(results) - bad}/{len(results)} passed")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--variant", choices=("debug", "release"))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if not a.selftest and not a.variant:
        ap.error("give --variant debug|release or --selftest")
    try:
        return selftest() if a.selftest else run(a.variant)
    except Setup as exc:
        print(f"vidraw_oldpaths: SETUP - {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
