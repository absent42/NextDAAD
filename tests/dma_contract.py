#!/usr/bin/env python3
"""Host-side contract check for overlay2's dma_copy.

WHY THIS EXISTS. dma_copy (src/overlay2.asm) is the block mover behind
every 256-wide picture row (gfx_row_copy256) and behind GFX 0/1
(l2_copy_back_front). Nothing host-side renders a picture, so the only
way this routine was ever exercised was on silicon, by eye - and it has
now been broken THREE times in a way no build check could see:

  1. the original hard-wired `ld a, high DMA_CHUNK_MAX`, which is 0 for
     any cap below 256 (a zero-length block, a dead transfer);
  2. 4cda75e's byte-wise rewrite, which pinned alen's high byte to a
     constant 0 and so BARRED a cap of exactly 256;
  3. 4cda75e again, and this is the one that crashed the machine: the
     per-call descriptor prefix was inserted at the top of dma_copy
     using HL and BC for its own OUTINB stream, WITHOUT SAVING THE
     CALLER'S. .loop then read HL = dma_prog and BC = DMA_PORT ($006B)
     as its source and length, so every call moved 107 bytes of the
     overlay's own code and returned DE only 107 bytes on.
     gfx_row_copy256 advances its destination by that returned DE, so
     the 256-wide blit walked out of the slot 6 window and wrote over
     $E000 - overlay2's own live code - on row 76 of every draw.

So this check does not read the source. It EXECUTES THE EMITTED BYTES
out of build\\nextdaad.nex, with the DMA port trapped, and asserts the
whole published contract of the routine:

  - HL = source, DE = dest, BC = length on entry, all three honoured;
  - the chunk list is the greedy split of BC by DMA_CHUNK_MAX, with
    every length carried in the descriptor as an exact 16-bit count
    (this is what a cap of exactly 256 needs, and what 0/65536 would
    fail);
  - source and destination advance contiguously across chunks;
  - the descriptor byte template (WR6/WR0/WR4 and the static WR1/WR2/
    WR5 prefix) is byte-for-byte what the zxnDMA is documented to want;
  - on return HL/DE/BC hold LDIR's exact end state, which is the
    contract gfx_row_copy256's page walk depends on.

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


# ------------------------------------------------------------- the model
# A deliberately tiny Z80 model: exactly the opcodes dma_copy emits today
# and nothing else. An unknown opcode is a HARD FAILURE, not a skip - if
# a future edit changes the instruction mix, the model must be extended
# and the contract re-verified by a human. That is the point.

class CPU:
    def __init__(self, mem, sp=0xBD00):
        self.m = mem                 # 64K bytearray
        self.a = self.f_z = self.f_c = 0
        self.b = self.c = self.d = self.e = self.h = self.l = 0
        self.sp = sp
        self.pc = 0
        self.out = []                # (port, byte) trapped writes
        self.flags_undef = False     # set by OUTINB (Z80N: flags undefined)

    # 16-bit register pairs
    def _get(self, hi, lo):
        return (getattr(self, hi) << 8) | getattr(self, lo)

    def _set(self, hi, lo, v):
        v &= 0xFFFF
        setattr(self, hi, v >> 8)
        setattr(self, lo, v & 0xFF)

    bc = property(lambda s: s._get("b", "c"), lambda s, v: s._set("b", "c", v))
    de = property(lambda s: s._get("d", "e"), lambda s, v: s._set("d", "e", v))
    hl = property(lambda s: s._get("h", "l"), lambda s, v: s._set("h", "l", v))

    def r16(self, a):
        return self.m[a] | (self.m[a + 1] << 8)

    def w16(self, a, v):
        self.m[a] = v & 0xFF
        self.m[a + 1] = (v >> 8) & 0xFF

    def imm16(self):
        v = self.r16(self.pc)
        self.pc += 2
        return v

    def use_flags(self):
        if self.flags_undef:
            raise Fail("a flag is read after OUTINB, whose flags the Z80N "
                       "leaves UNDEFINED (docs/Z80/10-next-extended-opcodes.md)")

    def step(self):
        op = self.m[self.pc]
        self.pc += 1
        if op == 0x01:                                   # ld bc,nn
            self.bc = self.imm16()
        elif op == 0x21:                                 # ld hl,nn
            self.hl = self.imm16()
        elif op == 0x22:                                 # ld (nn),hl
            self.w16(self.imm16(), self.hl)
        elif op == 0x2A:                                 # ld hl,(nn)
            self.hl = self.r16(self.imm16())
        elif op == 0x19:                                 # add hl,de
            r = self.hl + self.de
            self.f_c = 1 if r > 0xFFFF else 0            # ZF unaffected
            self.hl = r
            self.flags_undef = False
        elif op == 0x44:                                 # ld b,h
            self.b = self.h
        elif op == 0x4D:                                 # ld c,l
            self.c = self.l
        elif op == 0x60:                                 # ld h,b
            self.h = self.b
        elif op == 0x69:                                 # ld l,c
            self.l = self.c
        elif op == 0x78:                                 # ld a,b
            self.a = self.b
        elif op in (0xB1, 0xB7):                         # or c / or a
            self.a |= self.c if op == 0xB1 else self.a
            self.f_z = 1 if self.a == 0 else 0
            self.f_c = 0
            self.flags_undef = False
        elif op == 0xC5:                                 # push bc
            self.sp = (self.sp - 2) & 0xFFFF
            self.w16(self.sp, self.bc)
        elif op == 0xE5:                                 # push hl
            self.sp = (self.sp - 2) & 0xFFFF
            self.w16(self.sp, self.hl)
        elif op == 0xC1:                                 # pop bc
            self.bc = self.r16(self.sp)
            self.sp = (self.sp + 2) & 0xFFFF
        elif op == 0xE1:                                 # pop hl
            self.hl = self.r16(self.sp)
            self.sp = (self.sp + 2) & 0xFFFF
        elif op == 0xEB:                                 # ex de,hl
            self.de, self.hl = self.hl, self.de
        elif op == 0x38:                                 # jr c,d
            d = self.m[self.pc]
            self.pc += 1
            self.use_flags()
            if self.f_c:
                self.pc = (self.pc + (d - 256 if d > 127 else d)) & 0xFFFF
        elif op == 0xC3:                                 # jp nn
            self.pc = self.imm16()
        elif op == 0xC8:                                 # ret z
            self.use_flags()
            if self.f_z:
                self.pc = self.r16(self.sp)
                self.sp = (self.sp + 2) & 0xFFFF
        elif op == 0xC9:                                 # ret
            self.pc = self.r16(self.sp)
            self.sp = (self.sp + 2) & 0xFFFF
        elif op == 0xED:
            op2 = self.m[self.pc]
            self.pc += 1
            if op2 == 0x90:                              # outinb (Z80N)
                self.out.append((self.bc, self.m[self.hl]))
                self.hl = (self.hl + 1) & 0xFFFF         # B is NOT decremented
                self.flags_undef = True
            elif op2 in (0x42, 0x52):                    # sbc hl,bc / sbc hl,de
                self.use_flags()
                rhs = self.bc if op2 == 0x42 else self.de
                r = self.hl - rhs - self.f_c
                self.f_c = 1 if r < 0 else 0
                self.f_z = 1 if (r & 0xFFFF) == 0 else 0
                self.hl = r
                self.flags_undef = False
            elif op2 == 0x53:                            # ld (nn),de
                self.w16(self.imm16(), self.de)
            elif op2 == 0x5B:                            # ld de,(nn)
                self.de = self.r16(self.imm16())
            else:
                raise Fail(f"dma_copy emits an opcode this model does not "
                           f"know: ED {op2:02X} at ${self.pc - 2:04X}. Extend "
                           f"the model and RE-VERIFY the contract by hand.")
        else:
            raise Fail(f"dma_copy emits an opcode this model does not know: "
                       f"{op:02X} at ${self.pc - 1:04X}. Extend the model and "
                       f"RE-VERIFY the contract by hand.")


# ------------------------------------------------------------- the check

def run_call(page_img, entry, src, dst, length):
    """Execute one dma_copy call; return (chunks, exit_hl, exit_de, exit_bc).

    chunks is the list of (aaddr, alen, baddr) the DMA actually saw,
    decoded from the trapped port stream - not read back out of memory.
    """
    mem = bytearray(0x10000)
    mem[0xE000:0xE000 + len(page_img)] = page_img
    cpu = CPU(mem)
    cpu.hl, cpu.de, cpu.bc = src, dst, length
    RET_SENTINEL = 0x0001
    cpu.sp -= 2
    cpu.w16(cpu.sp, RET_SENTINEL)
    cpu.pc = entry

    budget = 200000
    while cpu.pc != RET_SENTINEL:
        budget -= 1
        if budget <= 0:
            raise Fail("dma_copy did not return - a cap of 0, or a chunk "
                       "length that never retires BC, loops forever here")
        cpu.step()

    for port, _ in cpu.out:
        if (port & 0xFF) != DMA_PORT:
            raise Fail(f"dma_copy drove port ${port:04X}; the zxnDMA decodes "
                       f"on low byte ${DMA_PORT:02X}")
    return [b for _, b in cpu.out], cpu.hl, cpu.de, cpu.bc


# The zxnDMA descriptor, byte for byte. Any drift here is a silent
# mis-programming of the controller, so it is pinned rather than parsed.
STATIC_PREFIX = [0b01010100, 0b00000010,   # WR1 A mem inc + timing byte
                 0b01010000, 0b00000010,   # WR2 B mem inc + timing byte
                 0b10000010]               # WR5 $82 stop on end of block
ARM_HEAD = [0x83, 0b01111101]              # WR6 disable, WR0 A->B + fields
ARM_MID = [0b10101101]                     # WR4 continuous, port B addr
ARM_TAIL = [0xCF, 0x87]                    # WR6 load, WR6 enable


def decode_stream(stream):
    """Split the trapped port stream into (aaddr, alen, baddr) chunks."""
    if stream[:len(STATIC_PREFIX)] != STATIC_PREFIX:
        raise Fail(f"the per-call static prefix is "
                   f"{[hex(b) for b in stream[:5]]}, not the documented "
                   f"WR1/WR2/WR5 template {[hex(b) for b in STATIC_PREFIX]}")
    rest, chunks = stream[len(STATIC_PREFIX):], []
    while rest:
        if len(rest) < 11:
            raise Fail(f"a trailing {len(rest)}-byte fragment follows the "
                       f"last complete arm - the descriptor desynced")
        arm, rest = rest[:11], rest[11:]
        if arm[0:2] != ARM_HEAD or arm[6:7] != ARM_MID or arm[9:11] != ARM_TAIL:
            raise Fail(f"arm template drift: {[hex(b) for b in arm]}")
        chunks.append((arm[2] | arm[3] << 8,      # port A start  = source
                       arm[4] | arm[5] << 8,      # block length  = EXACT count
                       arm[7] | arm[8] << 8))     # port B start  = dest
    if not chunks:
        raise Fail("no arm was uploaded at all - nothing would transfer")
    return chunks


def expected_split(length, cap):
    out = []
    while length:
        n = min(length, cap)
        out.append(n)
        length -= n
    return out


# ---------------------------------------------------- video kernels
# SP18 item 5: the video DMA kernels run with interrupts LIVE (the
# per-source permission in im2_init is the guard, not a DI bracket).
# These checks pin the emitted shape so a well-meaning edit cannot
# quietly reintroduce the bracket - or delete the ONE bracket that is
# still deliberate (vidSnapDmaArm's, which runs outside the CTC-armed
# window).

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
    for need in ("dma_copy", "dma_prog", "dma_prog_static", "DMA_CHUNK_MAX",
                 "OVL2_PAGE", "GFX_SRC_END", "DATA_WINDOW",
                 "vid_fill_dma", "vid_copy_dma", "vidDmaFiArm", "vidDmaCpArm",
                 "vidDmaWr1Inc", "vid_snap_copy", "vidSnapDmaArm"):
        if need not in syms:
            raise Fail(f"symbol {need} is missing from {SLD.name}")

    cap = syms["DMA_CHUNK_MAX"][1]
    ovl2_page, ovl2_org = syms["OVL2_PAGE"][1], 0xE000
    dma_page, dma_entry = syms["dma_copy"]
    if dma_page != ovl2_page:
        raise Fail(f"dma_copy is on page {dma_page}, expected overlay2's "
                   f"{ovl2_page}")
    if not 1 <= cap <= 256:
        raise Fail(f"DMA_CHUNK_MAX = {cap} is outside the legal 1..256 - the "
                   f"block length is a 16-bit EXACT count")

    page_img = read_page(ovl2_page)

    # The lengths that matter: both shipped callers hand exactly 256
    # (gfx_row_copy256's row, l2_copy_back_front's GFX_COPY_CHUNK), the
    # cap itself and its neighbours, the 320-wide row width, a multi-
    # chunk length, and 107 = DMA_PORT, the length the register-clobber
    # regression produced.
    cases = [1, 2, 63, 64, 107, 128, 192, 255, 256, 257, 320, 512, 8192]
    SRC, DST = 0xC000, 0x9000
    for n in cases:
        stream, hl, de, bc = run_call(page_img, dma_entry, SRC, DST, n)
        chunks = decode_stream(stream)
        want = expected_split(n, cap)
        got = [c[1] for c in chunks]
        if got != want:
            raise Fail(f"length {n}: the DMA was armed with block lengths "
                       f"{got}, expected the greedy split by DMA_CHUNK_MAX "
                       f"{cap} -> {want}")
        pos = 0
        for (aaddr, alen, baddr) in chunks:
            if aaddr != SRC + pos:
                raise Fail(f"length {n}: chunk at offset {pos} reads from "
                           f"${aaddr:04X}, expected ${SRC + pos:04X} (the "
                           f"CALLER's HL must reach the descriptor - this is "
                           f"exactly what the 4cda75e clobber broke)")
            if baddr != DST + pos:
                raise Fail(f"length {n}: chunk at offset {pos} writes to "
                           f"${baddr:04X}, expected ${DST + pos:04X}")
            pos += alen
        if pos != n:
            raise Fail(f"length {n}: the arms move {pos} bytes in total")
        # LDIR's exact end state - gfx_row_copy256 walks its destination
        # page cursor off the returned DE, so this is load-bearing.
        if (hl, de, bc) != ((SRC + n) & 0xFFFF, (DST + n) & 0xFFFF, 0):
            raise Fail(f"length {n}: returned HL=${hl:04X} DE=${de:04X} "
                       f"BC={bc}, expected LDIR's end state HL=${SRC + n:04X} "
                       f"DE=${DST + n:04X} BC=0")

    # BC = 0 must move nothing at all (no caller passes it, but a chunk
    # of 0 armed here would be a runaway transfer on silicon).
    stream, hl, de, bc = run_call(page_img, dma_entry, SRC, DST, 0)
    if stream != STATIC_PREFIX or (hl, de, bc) != (SRC, DST, 0):
        raise Fail("length 0 armed a transfer or moved the pointers")

    # The row the crash was actually made of: 256-wide art blits one
    # 256-byte row per dma_copy call and advances its destination by the
    # returned DE. Walk a full-height page the way gfx_row_copy256 does
    # and confirm no write ever leaves the slot 6 window - the overrun
    # landed on $E000, which is OVL_ORG, overlay2's own live code.
    win_lo, win_hi = syms["DATA_WINDOW"][1], syms["GFX_SRC_END"][1]
    de = win_lo
    for row in range(192):
        stream, _, de_out, _ = run_call(page_img, dma_entry, 0xA000, de, 256)
        end = decode_stream(stream)[-1][2] + decode_stream(stream)[-1][1]
        if end > win_hi:
            raise Fail(f"row {row}: the blit writes ${de:04X}..${end - 1:04X}, "
                       f"past the slot 6 window end ${win_hi:04X} - on silicon "
                       f"that is overlay2's own code at OVL_ORG")
        de = de_out
        if (de >> 8) >= (win_hi >> 8):
            de = win_lo

    check_video_kernels(syms)

    print(f"dma_contract: OK - dma_copy at page {ovl2_page} ${dma_entry:04X}, "
          f"DMA_CHUNK_MAX {cap}, {len(cases)} lengths + 192-row window walk, "
          f"descriptor template byte-exact")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as exc:
        print(f"dma_contract: FAIL - {exc}", file=sys.stderr)
        sys.exit(1)
