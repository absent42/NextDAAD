#!/usr/bin/env python3
"""Host-side shape check for the video player's zxnDMA kernels (src/video.asm).

Reads the EMITTED bytes of build\\nextdaad.nex: the arm trains of vid_fill_dma, vid_copy_dma
and vid_snap_copy must go out as unrolled OUTINB runs with no DI/EI around them. The picture
blits have their own check, tests\\ddma_contract.py, which also uses this file's NEX and SLD
readers.

Run standalone, or via tests\\build-tests.ps1 (which runs it on every
invocation once build\\nextdaad.nex exists). Exit 0 = green.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NEX = ROOT / "build" / "nextdaad.nex"
SLD = ROOT / "build" / "nextdaad.sld"

# Bank order inside a .nex payload (specnext NEX v1.2/v1.3): banks 5, 2,
# 0, 1, 3, 4 first, then 6..111 ascending. Only banks flagged present in
# the 112-byte table at header offset 18 are stored.
NEX_BANK_ORDER = [5, 2, 0, 1, 3, 4] + list(range(6, 112))

DMA_PORT = 0x6B


class Fail(Exception):
    pass


# ---------------------------------------------------------------- inputs

def read_sld():
    """symbol -> (page, value). page -1 means an EQU (value is the number)."""
    syms = {}
    for line in SLD.read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split("|")
        if len(f) < 8 or f[6] not in ("D", "F"):
            continue
        try:
            page, value = int(f[4]), int(f[5])
        except ValueError:
            continue
        syms[f[7]] = (page, value)
    return syms


def read_page(page):
    """Extract one 8K page from the .nex payload."""
    d = NEX.read_bytes()
    if d[0:4] != b"Next":
        raise Fail(f"{NEX} is not a .nex file (magic {d[0:4]!r})")
    present = [b for b in NEX_BANK_ORDER if d[18 + b]]
    bank, half = page // 2, page % 2
    if bank not in present:
        raise Fail(f"page {page} (bank {bank}) is not present in {NEX.name}")
    off = 512 + 16384 * present.index(bank) + 8192 * half
    return d[off:off + 8192]


OUTINB = bytes([0xED, 0x90])


def span(syms, lo_sym, hi_sym):
    lo_page, lo = syms[lo_sym]
    hi_page, hi = syms[hi_sym]
    if lo_page != hi_page:
        raise Fail(f"{lo_sym}..{hi_sym} straddle pages {lo_page}/{hi_page}")
    return read_page(lo_page)[lo & 0x1FFF:hi & 0x1FFF]


def outinb_run(buf, min_len):
    """Offset of the first run of >= min_len OUTINB pairs, or -1."""
    i = 0
    while i < len(buf) - 1:
        if buf[i:i+2] == OUTINB:
            j = i
            while buf[j:j+2] == OUTINB:
                j += 2
            if (j - i) // 2 >= min_len:
                return i
            i = j
        else:
            i += 1
    return -1


def check_video_kernels(syms):
    # 1. Neither hot kernel brackets its arm train in di/ei.
    #    DELIBERATELY an adjacency check (F3 immediately before the
    #    train, FB immediately after), NOT a span-wide F3/FB scan:
    #    operand bytes of unrelated instructions in the span can
    #    legitimately equal F3/FB, so a span-wide scan would
    #    false-positive. A reinstated bracket has to sit hard against
    #    the train to bracket it, which is exactly what this catches.
    for name, lo, hi, arm_len in (
        ("vid_fill_dma", "vid_fill_dma", "vid_copy_dma", 13),
        ("vid_copy_dma", "vid_copy_dma", "vidDmaFiArm", 11),
    ):
        buf = span(syms, lo, hi)
        at = outinb_run(buf, arm_len)
        if at < 0:
            raise Fail(f"{name}: no {arm_len}-pair OUTINB arm train found")
        if at > 0 and buf[at - 1] == 0xF3:
            raise Fail(f"{name}: DI (F3) immediately before the arm train "
                       f"- the bracket is back, the pre-emption permission "
                       f"is being overridden")
        after = at + 2 * arm_len
        if after < len(buf) and buf[after] == 0xFB:
            raise Fail(f"{name}: EI (FB) immediately after the arm train "
                       f"- the bracket is back")

    # 2. The arm descriptor templates are byte-for-byte what the zxnDMA
    #    wants (WR6 disable, WR0 A->B, [WR1 fixed pair, fill only],
    #    WR4 continuous, WR6 load, WR6 enable). Patched dw holes skipped.
    fi_page, fi = syms["vidDmaFiArm"]
    fi_bytes = read_page(fi_page)[fi & 0x1FFF:(fi & 0x1FFF) + 13]
    for off, want in ((0, 0x83), (1, 0x7D), (6, 0x64), (7, 0x02),
                      (8, 0xAD), (11, 0xCF), (12, 0x87)):
        if fi_bytes[off] != want:
            raise Fail(f"vidDmaFiArm[{off}] = {fi_bytes[off]:02X}, "
                       f"want {want:02X}")
    cp_page, cp = syms["vidDmaCpArm"]
    cp_bytes = read_page(cp_page)[cp & 0x1FFF:(cp & 0x1FFF) + 11]
    for off, want in ((0, 0x83), (1, 0x7D), (6, 0xAD), (9, 0xCF),
                      (10, 0x87)):
        if cp_bytes[off] != want:
            raise Fail(f"vidDmaCpArm[{off}] = {cp_bytes[off]:02X}, "
                       f"want {want:02X}")
    wr_page, wr = syms["vidDmaWr1Inc"]
    wr_bytes = read_page(wr_page)[wr & 0x1FFF:(wr & 0x1FFF) + 2]
    if bytes(wr_bytes) != bytes([0x54, 0x02]):
        raise Fail(f"vidDmaWr1Inc = {wr_bytes.hex()}, want 5402")

    # 3. The snapshot path KEEPS its brackets - exactly two di/otir
    #    (F3 ED B3) sites inside vid_snap_copy (the WR2/WR5 session
    #    init and the per-chunk arm). A sweep that deletes them would
    #    admit the frame ISR mid-arm on a path that gains nothing.
    buf = span(syms, "vid_snap_copy", "vidSnapDmaArm")
    n = 0
    for i in range(len(buf) - 2):
        if buf[i] == 0xF3 and buf[i+1] == 0xED and buf[i+2] == 0xB3:
            n += 1
    if n != 2:
        raise Fail(f"vid_snap_copy: expected exactly 2 DI-bracketed OTIR "
                   f"uploads, found {n}")


def main():
    if not NEX.exists() or not SLD.exists():
        print(f"dma_contract: SKIPPED - no {NEX.relative_to(ROOT)} / "
              f"{SLD.relative_to(ROOT)} (run .\\build.ps1 first)")
        return 0

    syms = read_sld()
    for need in ("vid_fill_dma", "vid_copy_dma", "vidDmaFiArm", "vidDmaCpArm",
                 "vidDmaWr1Inc", "vid_snap_copy", "vidSnapDmaArm"):
        if need not in syms:
            raise Fail(f"symbol {need} is missing from {SLD.name}")

    check_video_kernels(syms)

    print("dma_contract: OK - video DMA kernels: unrolled arm trains, no DI/EI")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as exc:
        print(f"dma_contract: FAIL - {exc}", file=sys.stderr)
        sys.exit(1)
