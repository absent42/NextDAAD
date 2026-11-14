; zxnDMA harness for D rows: reset, NextDAAD session init, copy arm, zxnDDMA
; detection, SRAM buffer check, checksum. Port $6B only.

DMA_PORT         equ $6B
DMA_ARM_LEN      equ 11
DMA_PAGE         equ 34      ; bank 17: D0CP buffers through MMU6
DDMA_PAGE        equ 60      ; zxnDDMA writes the probe at $0B0000 + its CPU address
SRAM_PAGES_1M    equ SRAM_PROBE_PAGE
SRAM_PAGES_2M    equ 224
DMA_XFER_PAD     equ 16      ; bus request, acknowledge and finish states: margin
DDMA_PHYSICAL    equ %00000001

; $C3 on port $6B: settings of zxnddma.gde 2.6 cleared, cycle length 3/3. Corrupts A.
dma_reset:
    ld a, $C3
    out (DMA_PORT), a            ; decoded on A7-A0 only (zxnddma.gde 2.1)
    ret

; NextDAAD's session init, bytes of src/video.asm vidDmaInit (= nxbDmaInit); the
; WR1/WR2/WR5 bytes are also src/overlay2.asm dma_prog_static. Corrupts BC, HL.
dma_init_nd:
    ld hl, dmaInitNd
    ld bc, DMA_INIT_ND_LEN << 8 | DMA_PORT
    otir
    ret

; HL = source, DE = destination, BC = length (exact on port $6B, zxnddma.gde 2.9 note 6).
dma_arm_set:
    ld (dmaArm.aaddr), hl
    ld (dmaArm.baddr), de
    ld (dmaArm.alen), bc
    ret

; Send the arm as src/overlay2.asm dma_copy does: returns when the block has moved.
; Corrupts BC, HL. T doc/worst: 20/26 + 11 x 16/19, then the transfer.
dma_arm_go:
    ld hl, dmaArm
    ld bc, DMA_PORT              ; B = 0: OUTINB keeps it
    DUP DMA_ARM_LEN
    outinb
    EDUP
    ret

; A = 8K page -> MMU6 = A, CF = 0; or CF set, DE = reason, when the page is past the
; detected SRAM (#SRAM). Corrupts F, DE.
buf_page:
    push af
    ld a, (sramExp)
    or a
    ld e, SRAM_PAGES_1M
    jr z, .lim
    ld e, SRAM_PAGES_2M
.lim:
    pop af
    cp e                         ; CF = inside
    ccf
    ld de, dmaTxtSram
    ret c
    nextreg NR_MMU6, a
    ret

; zxnddma_compare.asm detect: a 1-byte physical copy lands in page DDMA_PAGE on a
; zxnDDMA, in dmaProbeTo on a plain zxnDMA. Out: CF set, DE = reason, when absent.
; Corrupts AF, BC, DE, HL.
ddma_detect:
    xor a
    ld (ddmaOk), a
    call ddma_save
    call ddma_clear
    call dt_body
    call ddma_read
    call ddma_restore
    ld de, $5A00
    or a
    sbc hl, de
    ld de, dmaTxtAbsent
    scf
    ret nz
    ld a, 1
    ld (ddmaOk), a
    or a
    ret

; Blitter row inits call this after dma_reset. CF set, DE = reason, without zxnDDMA.
ddma_need:
    ld a, (ddmaOk)
    cp 1                         ; CF = 0 detected
    ld de, dmaTxtNoDdma
    ret

; Zero both probe landing bytes; the page byte is marked for ddma_undo. Out: CF = 0.
; Corrupts A. Only after ddma_save.
ddma_clear:
    ld a, 1
    ld (ddmaDirty), a
    xor a
    ld (dmaProbeTo), a
    nextreg NR_MMU7, DDMA_PAGE
    ld (DDMA_TWIN), a
    nextreg NR_MMU7, 1
    ret

; The page DDMA_PAGE byte the probe lands on, kept and put back. Corrupt A.
ddma_save:
    nextreg NR_MMU7, DDMA_PAGE
    ld a, (DDMA_TWIN)
    ld (ddmaSaved), a
    nextreg NR_MMU7, 1
    ret
; rt_restore: the page byte back if a skipped row left it cleared. Corrupts AF.
ddma_undo:
    ld a, (ddmaDirty)
    or a
    ret z
    jr ddma_restore
ddma_restore:
    xor a
    ld (ddmaDirty), a
    nextreg NR_MMU7, DDMA_PAGE
    ld a, (ddmaSaved)
    ld (DDMA_TWIN), a
    nextreg NR_MMU7, 1
    ret

; HL = zxnDDMA landing byte : plain landing byte. Corrupts A.
ddma_read:
    nextreg NR_MMU7, DDMA_PAGE
    ld a, (DDMA_TWIN)
    ld h, a
    nextreg NR_MMU7, 1
    ld a, (dmaProbeTo)
    ld l, a
    ret

; D0DT: detection untimed, then the probe byte cleared so the reps write it again.
dmainit_dt:
    call dma_reset
    call ddma_detect
    ret c                        ; #SKIP D0DT ABSENT
    jp ddma_clear

; The detection program as one OTIR. Corrupts BC, HL.
dt_body:
    ld hl, ddmaProg
    ld bc, DDMA_PROG_LEN << 8 | DMA_PORT
    otir
    ret

; CK = landing bytes, OK = 5A00 (zxnDDMA wrote, plain copy did not). Byte put back.
dt_check:
    call ddma_read
    call ddma_restore
    ld de, $5A00
    jp ck_cmp

; D0CP smoke row: 256-byte copy with NextDAAD's programming, quiet state.
CP_LEN           equ 256
CP_SRC           equ $C000
CP_DST           equ CP_SRC + CP_LEN
CP_REF           equ CP_DST + CP_LEN
CP_FILL          equ $E5
    ASSERT low CP_SRC == 0 && CP_REF + CP_LEN <= $E000
; Per pass: arm upload, CP_LEN bytes at cycle 2/2 (+1 read wait at 28 MHz, 30204 dma.vhd:337).
CP_DOC           equ 20 + DMA_ARM_LEN * 16 + CP_LEN * 4
CP_COST          equ 26 + DMA_ARM_LEN * 19 + CP_LEN * 5 + DMA_XFER_PAD
CP_REPS          equ (P1_FRAMES * (FRAME_T0 << 3) + CP_DOC + POLL_FAST - 1) / (CP_DOC + POLL_FAST)

dmainit_cp:
    call dma_reset
    call dma_init_nd
    ld a, DMA_PAGE
    call buf_page
    ret c                        ; #SKIP D0CP SRAM
    ld hl, CP_SRC
    xor a
.src:
    ld (hl), a                   ; source byte n = n
    inc a
    inc l
    jr nz, .src
    ld hl, CP_DST
    ld de, CP_DST + 1
    ld bc, CP_LEN * 2 - 1
    ld (hl), CP_FILL
    ldir                         ; DST and REF start the same
    ld hl, CP_SRC
    ld de, CP_DST
    ld bc, CP_LEN
    call dma_arm_set
    or a
    ret

; Check framework: HL = CPU reference routine (may corrupt all but SP), A = REF_ONCE
; for idempotent ops (copy, fill, transparent copy), REF_REPS (the row's reps) otherwise.
REF_ONCE         equ 0
REF_REPS         equ 1
ref_run:
    ld (.call + 1), hl
    or a
    ld hl, 1
    call nz, row_reps
.lp:
    ld (refLeft), hl
.call:
    call 0                       ; SMC: the reference
    ld hl, (refLeft)
    dec hl
    ld a, h
    or l
    jr nz, .lp
    ret

; CPU reference once (a copy is idempotent), then DST checked against REF.
d0cp_check:
    ld hl, cp_ref
    ld a, REF_ONCE
    call ref_run
    ld hl, CP_REF
    ld bc, CP_LEN
    call ck16
    push hl
    ld hl, CP_DST
    ld bc, CP_LEN
    call ck16
    pop de
    jp ck_cmp

cp_ref:
    ld hl, CP_SRC
    ld de, CP_REF
    ld bc, CP_LEN
    ldir
    ret

; HL = measured, DE = expected -> CF set if they differ. Keeps HL.
ck_cmp:
    ld a, h
    cp d
    jr nz, .bad
    ld a, l
    cp e
    ret z                        ; CF = 0
.bad:
    scf
    ret

; HL = address, BC = length (0 = none) -> HL = rotate-left-and-add checksum.
; Corrupts AF, BC, DE.
ck16:
    ex de, hl
    ld hl, 0
.lp:
    ld a, b
    or c
    ret z
    add hl, hl                   ; bit 15 -> CF
    jr nc, .nc
    inc l                        ; -> bit 0, clear after the shift
.nc:
    ld a, (de)
    add a, l
    ld l, a
    jr nc, .nc2
    inc h
.nc2:
    inc de
    dec bc
    jr .lp

dmaInitNd:
    db $83                       ; WR6: disable
    db %01010100                 ; WR1: A memory, incrementing, timing byte follows
    db %00000010                 ; A cycle length 2
    db %01010000                 ; WR2: B memory, incrementing, timing byte follows
    db %00000010                 ; B cycle length 2, no prescaler
    db %10000010                 ; WR5: stop at the end of the block
DMA_INIT_ND_LEN  equ $ - dmaInitNd
    ASSERT DMA_INIT_ND_LEN == 6

; Bytes of src/overlay2.asm dma_prog: the per-transfer arm.
dmaArm:
    db $83                       ; WR6: disable
    db %01111101                 ; WR0: A to B, port A address and length follow
.aaddr:
    dw 0
.alen:
    dw 0
    db %10101101                 ; WR4: continuous, port B address follows
.baddr:
    dw 0
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable
    ASSERT $ - dmaArm == DMA_ARM_LEN

; zxnddma_compare.asm detect_dma; data bytes after zxnDDMA commands stay below $80.
ddmaProg:
    db $83, $C3                  ; disable, reset
    db $D7, $04                  ; port A bits 23:16: bank 2 ($048000 = CPU $8000)
    db $DB, $0B                  ; port B bits 23:16: page DDMA_PAGE for $8000-$9FFF
    db $DF, DDMA_PHYSICAL
    db $83, $83, $83, $83        ; end any register write a plain zxnDMA was left in
    db $83, $83, $83, $83
    db %01111101                 ; WR0: A to B, port A address and length follow
    dw dmaProbeFrom, 1
    db $14, $10                  ; WR1, WR2: memory, incrementing
    db %10101101                 ; WR4: continuous, port B address follows
    dw dmaProbeTo
    db $82                       ; WR5: stop at the end
    db $CF, $87                  ; load, enable
DDMA_PROG_LEN    equ $ - ddmaProg
; Per pass: OTIR of the program, 1 byte at cycle 3/3 (+1 read wait at 28 MHz).
DT_DOC           equ 20 + DDMA_PROG_LEN * 21 - 5 + 6
DT_COST          equ 26 + DDMA_PROG_LEN * 24 - 5 + 7 + DMA_XFER_PAD
DT_REPS          equ (P1_FRAMES * (FRAME_T0 << 3) + DT_DOC + POLL_FAST - 1) / (DT_DOC + POLL_FAST)

dmaProbeFrom: db $5A
dmaProbeTo:   db 0
    ASSERT dmaProbeFrom >= $8000 && dmaProbeTo < $A000 && DDMA_PAGE < SRAM_PAGES_1M
DDMA_TWIN        equ $E000 + (dmaProbeTo & $1FFF)
ddmaOk:       db 0
ddmaSaved:    db 0
ddmaDirty:    db 0            ; 1 = the page byte holds a probe value, not ddmaSaved
refLeft:      dw 0

dmaTxtAbsent: db "ABSENT", 0
dmaTxtNoDdma: db "NODDMA", 0
dmaTxtSram:   db "SRAM", 0
