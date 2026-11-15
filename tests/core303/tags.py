"""Tag table: the single source of row meaning for CORE303 logs.

Calibration: per-unit T subtracts a calibration row's per-rep T at the row's
clock and speed. Tag.cal names that row; when it is None the default is CAL0
(S=3) / CAL1 (S=2) for C=W and B0CL (S=3) / B1CL (S=2) for C=L.
BENCH companion rows: a part 2 row whose batch runs a restore before every
workload names a companion that runs the same R x [restore] with an empty
workload, same speed, C=L. Its tag is the workload's with char 2 replaced by
'R' (B2HD and B3HD -> BRHD; the two are told apart by S). The companion's own
Tag has part "0" and no cal.
ISR rows (B2I0/B2IM/B2IS) are the exception: the companion runs the SAME
workload under DI, and per_frame makes the report give the ISR cost per frame,
(row T - companion T) / row F. A companion (any tag some Tag.cal names) is
never SHORT; plain calibration rows keep the CAL_MIN_FRAMES floor.
"""
from dataclasses import dataclass
from typing import Optional

CPU = "CPU"
DMA = "DMA"
BLT = "BLT"


@dataclass(frozen=True)
class Tag:
    part: str
    op: str
    method: str
    size: Optional[int]
    unit: str
    note: str = ""
    cal: Optional[str] = None
    per_frame: bool = False         # report (row T - cal T) / row F instead of T/unit

    @property
    def calibration(self):
        """Part 0: CAL0/CAL1, B0CL/B1CL and every BENCH companion row."""
        return self.part == "0"


# Part 1a notes: expected T per unit of the body as built (setup amortised, 2 dp).
# Old core at 28 MHz: +1 T per SRAM read cycle, fetches included (30205 zxnext.vhd:3471,3492).
TAGS = {
    "CAL0": Tag("0", "poll", CPU, None, "rep", "empty body, S=3"),
    "CAL1": Tag("0", "poll", CPU, None, "rep", "empty body, S=2"),
    "B0CL": Tag("0", "poll", CPU, None, "rep", "long clock, S=3"),
    "B1CL": Tag("0", "poll", CPU, None, "rep", "long clock, S=2"),
    # 1 fetch, 1 wait (30205 zxnext.vhd:3492)
    "P1NP": Tag("1a", "NOP", CPU, None, "NOP", "documented=4 old-core=5"),
    # fetch + read waits, LD HL,nn 3 over 2048 (30205 zxnext.vhd:3492)
    "P1RD": Tag("1a", "LD A,(HL)", CPU, None, "read", "documented=7.00 old-core=9.01"),
    # fetch waits; writes have cpu_rd_n = 1, no wait (30205 zxnext.vhd:3492)
    "P1WR": Tag("1a", "LD (HL),A", CPU, None, "write", "documented=7.00 old-core=8.01"),
    # ED, A0 fetch + read = 3 waits, write none (30205 zxnext.vhd:3492)
    "P1LI": Tag("1a", "LDI", CPU, None, "byte", "documented=16.02 old-core=19.03"),
    # each repeat refetches ED B0 (30205 t80n.vhd:656): 3 waits per byte (30205 zxnext.vhd:3492)
    "P1LR": Tag("1a", "LDIR", CPU, None, "byte", "documented=21.02 old-core=24.03"),
    # 3 waits per byte; the I/O write has no MREQ, so no memcycle (30205 zxnext.vhd:3460)
    "P1OT": Tag("1a", "OTIR $FE", CPU, None, "byte", "documented=21 old-core=24.01"),
    # 2 fetch waits; I/O read has no MREQ, ULA wait off above 3.5 MHz (30205 zxnext.vhd:3460,5027)
    "P1IN": Tag("1a", "IN A,(C) $FE", CPU, None, "IN", "documented=12.01 old-core=14.01"),
    # PUSH 1 fetch wait, POP fetch + 2 reads (30205 zxnext.vhd:3492)
    "P1PP": Tag("1a", "PUSH+POP", CPU, None, "pair", "documented=21 old-core=25"),
    # fetch + displacement read (30205 zxnext.vhd:3492)
    "P1JR": Tag("1a", "JR", CPU, None, "JR", "documented=12 old-core=14"),
    # pages 10/11 leave SRAM but cpu_bank5_sched waits each read (30205 zxnext.vhd:3377,3492,7220)
    "P1X5": Tag("1a", "NOP bank 5", CPU, None, "NOP", "documented=4 old-core=5"),
    # bank 5 read waits via cpu_bank5_sched, fetch in SRAM (30205 zxnext.vhd:3492,7220)
    "P1R5": Tag("1a", "LD A,(HL) bank 5", CPU, None, "read", "documented=7.00 old-core=9.01"),
    # page 14 is not SRAM (3377), no bank 7 wait term (3492), direct port (30205 zxnext.vhd:7330)
    "P1R7": Tag("1a", "LD A,(HL) bank 7", CPU, None, "read", "documented=7.00 old-core=8.01"),
    # cpu_speed /= "11": no wait (30205 zxnext.vhd:3492)
    "P1C1": Tag("1a", "NOP", CPU, None, "NOP", "documented=4 old-core=4"),
    # cpu_speed /= "11": no wait (30205 zxnext.vhd:3492)
    "P1C2": Tag("1a", "LDIR", CPU, None, "byte", "documented=21.02 old-core=21.02"),
    # Part 1b harness rows. D0DT: zxnddma_compare.asm probe, a 1-byte physical copy.
    "D0DT": Tag("1b", "zxnDDMA detect", BLT, None, "probe", "CK=5A00 OK = zxnDDMA present"),
    # NextDAAD dma_prog arm (overlay2.asm), cycle 2/2, quiet; op unique so no break-even pair
    "D0CP": Tag("1b", "copy smoke", DMA, 256, "byte", "smoke row, NextDAAD dma_prog"),
}

# Part 2 BENCH rows (src/bench.asm, fixture tests/core303/fixture/bench.dsf): B2xx at
# S=3, B3xx the same workload at S=2, BRxx the companion at the row's speed.
B2 = {
    # Harness T per char, not subtracted: hd_body jr c/ld (bc),a/inc bc/jr; pr_body
    # ld c,(hl)/push/pop/inc/ld de,nn/or/sbc/add/jr (old core: +1 per fetch and read).
    "HD": ("Huffman decode", "char", "message 0, 114 chars, txt_next_decoded to a buffer; "
           "harness documented=32 old-core=38 T/char included", "restore: msg_seek"),
    "PR": ("print", "char", "message 0 through prn_char + prn_flush, 80x14 window; "
           "harness documented=86 old-core=102 T/char included",
           "restore: window record, 2 rows"),
    "SC": ("window scroll", "scroll", "tm_scroll_rect, 80x14 window (13 rows moved)",
           "restore: 14 rows"),
    "PB": ("NX3 blit", "picture", "256x96, gfx_blit_pos buffer mode, no frame gate",
           "restore: reveal state"),
    "PL": ("NX3 SD load", "picture", "gfx_load, cold cache, 25104 B after 8 missed probes",
           "restore: cache emptied"),
    "I0": ("frame ISR idle", "rep", "spin + poll, interrupts on; companion under DI",
           "DI twin, idle"),
    "IM": ("frame ISR AKY", "rep", "spin + poll, 9-channel song; companion under DI",
           "DI twin, AKY"),
    "IS": ("frame ISR SFX", "rep", "spin + poll, streamed SFX loop; companion under DI; "
           "per frame also holds the 15.6 kHz CTC DAC ISR (about 312 calls a frame) "
           "and the SD burst refill, not only the frame ISR", "DI twin, SFX"),
    # bench_turn: 16 eng_steps, push/call/pop + stop check each, vs eng_run's 29 T/step.
    "GT": ("game turn", "turn", "EXAMINE LAMP injected, PARSE 0 through PRO 1 and PRO 5 "
           "(MES 3, DONE) to REDO; harness documented=1896 old-core=2333 T/turn included",
           "restore: flags, object locations, window record, PRO 1 record, inject"),
}
for _k, (_op, _unit, _note, _rnote) in B2.items():
    TAGS["BR" + _k] = Tag("0", _op, CPU, None, "rep", _rnote)
    TAGS["B2" + _k] = Tag("2", _op, CPU, None, _unit, _note, cal="BR" + _k,
                          per_frame=_k in ("I0", "IM", "IS"))
    if _k in ("HD", "PR", "SC", "PB", "GT"):
        TAGS["B3" + _k] = Tag("2", _op, CPU, None, _unit, _note + ", 14 MHz", cal="BR" + _k)

# Part 1b operation rows: tag D<op><method><size index>, method C (CPU), Z (zxnDMA),
# B (blitter). Size grids as bench/ops.asm rectTab0/C/K, fillTab, scrollTab, vidTab.
SIZE_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
RECT256 = [(16, 16), (32, 32), (64, 64), (128, 96), (256, 192)]
RECT320 = [(16, 16), (64, 64), (160, 128), (320, 256)]
FILL = [64, 256, 1024, 4096, 16384]
SCROLL = [8, 24]            # window rows, 80 columns x 2 bytes (nextdaad.inc TM_MAP); moves rows - 1
SCROLL_STRIDE = 160
VCOPY = [1, 4, 8, 16, 53, 71, 128, 240]
SETUP = ["full program", "short reload"]
GFX_DMA_MIN_LEN = 64        # src/nextdaad.inc: gfx_copy uses LDIR below this width
REF = "reference, not shipping"

OPS = {
    "R": "rect 256x192 mode",
    "C": "rect 320 row-major source",
    "K": "rect 320 col-major source",
    "T": "transparent rect",
    "F": "fill",
    "S": "tilemap scroll",
    "V": "video COPY",
    "U": "setup",
}


def _op_tags():
    out = {}

    def add(op, m, i, method, size, note):
        out["D%s%s%s" % (op, m, SIZE_CHARS[i])] = Tag("1b", OPS[op], method, size, "byte", note)

    for i, (w, h) in enumerate(RECT256):
        g = "%dx%d" % (w, h)
        cpu = "LDIR a row, gfx_copy shape" if w < GFX_DMA_MIN_LEN else "LDIR a row, " + REF
        add("R", "C", i, CPU, w * h, "%s, %s" % (g, cpu))
        add("R", "Z", i, DMA, w * h, "%s, dma_copy a row" % g)
        add("R", "B", i, BLT, w * h, "%s, 2D X,Y, 7-byte reload" % g)
        add("T", "C", i, CPU, w * h, "%s, LDIRX a row, %s" % (g, REF))
        add("T", "B", i, BLT, w * h, "%s, 2D X,Y transparent, 7-byte reload" % g)
    for i, (w, h) in enumerate(RECT320):
        g = "%dx%d" % (w, h)
        add("C", "C", i, CPU, w * h, "%s, LDWS scatter, gfx_pos_row_write320 shape" % g)
        add("C", "B", i, BLT, w * h, "%s, a 2D transfer of 1-byte rows a pixel row" % g)
        add("K", "C", i, CPU, w * h, "%s, LDIR a column, %s (hypothetical format)" % (g, REF))
        add("K", "Z", i, DMA, w * h, "%s, dma_copy a column (hypothetical format)" % g)
        whole = "one transfer" if w * h <= 0xFFFF else "two transfers of %d columns" % (w // 2)
        add("K", "B", i, BLT, w * h, "%s, 2D X,Y, %s (hypothetical format)" % (g, whole))
    for i, n in enumerate(FILL):
        add("F", "C", i, CPU, n, "vid_fill_cpu, 240-byte chunks")
        add("F", "Z", i, DMA, n, "vid_fill_dma, 240-byte chunks")
        add("F", "B", i, BLT, n, "fill mode, physical, one transfer")
    for i, rows in enumerate(SCROLL):
        n = (rows - 1) * SCROLL_STRIDE
        g = "%d rows" % rows
        add("S", "C", i, CPU, n, "%s, tm_scroll_rect LDIR shape" % g)
        add("S", "Z", i, DMA, n, "%s, dma_copy a row" % g)
        add("S", "B", i, BLT, n, "%s, 2D through the MMU, short reload" % g)
    for i, n in enumerate(VCOPY):
        add("V", "C", i, CPU, n, "vid_copy_ldi")
        add("V", "Z", i, DMA, n, "vid_copy_dma")
        add("V", "B", i, BLT, n, "physical, 10-byte reload with length")
    add("U", "Z", 0, DMA, 1, "full program: vidDmaInit + dma_prog arm, 1 byte")
    add("U", "Z", 1, DMA, 1, "short reload: dma_prog arm, 1 byte")
    add("U", "B", 0, BLT, 1, "full program, zxnddma.gde 2.8, 1 byte")
    add("U", "B", 1, BLT, 1, "short reload, zxnddma.gde 2.9 note 1, 1 byte")
    return out


TAGS.update(_op_tags())

# Pi log tags (#PI303 logs, parse.parse_pilog); kept out of TAGS so CORE303 logs reject them.
PI_TAGS = ("P0IM P0NR P0RW P0VR P2CV P2JD P2PY P2RD P2SH P2SM P2SP P3B7 P3BF P3CH P3CP "
           "P3FR P3LR P3NP P3P4 P3R5 P3RD P3RS P3SC P3SV P3TE P3WB P3WP P3WS P4NX P4SK "
           "P4TF P4TS P4VF P4VS BUSY").split()   # BUSY: lock-timeout #SKIP tag
# spi303 stdout rows (tests/core303/pi/c): passes, per-tx losses, end, heartbeat, stream,
# self-test, error.
PI_TAGS += "C3WP C3BP C3RP C3TX C3EN C3HB C3SM C3ST C3ER".split()
