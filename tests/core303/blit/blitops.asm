; Blit-rule rows: the transfers src/overlay2.asm sends (ddma_prog, its ddma_again tail,
; DDMA_PAD after the arm), timed per span length. Physical addresses, cycle length 2.
;   linear        - as ddma_copy: mode physical, WR0 length
;   row piece     - as gfx_seg on a row-major surface: 2D, row length n, 1 row
;   column piece  - as gfx_seg on a column-major surface: 2D, row length 1, n rows 256 apart
; A reload row sends the full program once in its init, then the tail each rep.

COL_V            equ $10          ; column pieces: offset of every byte in its 256
BLK_ROW          equ 256          ; block rows: 256 wide, 16 rows
BLK_LEN          equ 4096
ROW_256          equ 256
ROW_320          equ 320
    ASSERT BLK_LEN == DDMA_XFER_MAX && V_OFS + BLK_LEN <= $2000 && COL_V < 256
    ASSERT (ROW_320 - 1) * 256 + COL_V < 10 * $2000     ; a 320 column piece ends in page 9

IM2_V_CTC1       equ 8            ; CTC 1: index 4 (src/interrupts.asm IM2_CTC2_VEC)
CTC20_TC         equ CTC_PERIOD_MIN / 16
CTC20_N          equ (CTC_ISR_T_MAX - CTC_FIX) / 25
    ASSERT CTC20_TC * 16 == CTC_PERIOD_MIN && CTC20_N >= 1
    ASSERT CTC_FIX + CTC20_N * 25 <= CTC_ISR_T_MAX && CTC_FIX + CTC20_N * 25 >= 247

; main: irq_state's call z, ctc_start goes to ctc_sel instead.
IRQ_STATE_CALL   equ irq_state + 11
bp_patch:
    ld hl, ctc_sel
    ld (IRQ_STATE_CALL + 1), hl
    ret

; State 2 by the row's ISR length index: 0 = CTC 0 at 15625 Hz (irq.asm ctc_start, the
; video session's load), 1 = CTC 0 and 1 at the period and ISR length DDMA_PAD is
; sized for (ddma.inc). Corrupts AF, BC, E, HL.
ctc_sel:
    ld a, (rtKind)
    and QI1
    jp z, ctc_start
    ld a, low irq_ctc_stub
    ld (IM2_TAB + IM2_V_CTC1), a
    ld a, CTC20_N
    ld (ctc_isr.cnt + 1), a
    ld bc, CTC0_PORT
    call .ch
    inc b                        ; CTC1_PORT
.ch:
    ld a, CTC_RESET
    out (c), a
    out (c), a
    ld a, CTC_CW16
    out (c), a
    ld a, CTC20_TC
    out (c), a                   ; time constant: the timer starts
    ret

; DE = length -> as vid_load. Out: CF set, DE = reason, past SRAM.
sp_load:
    push de
    ld a, OPS_LAST_PAGE
    call buf_page
    pop hl
    ret c
    ex de, hl
    jp vid_pages

; The 10 Layer 2 and expected pages filled for a column piece. Out: CF = 0.
col_pages:
    ld a, L2_PAGE
    ld b, 10
    ld c, SEED_DST
    call pat_fill
    ld a, EXP_PAGE
    ld b, 10
    ld c, SEED_DST
    call pat_fill
    or a
    ret

; A = mode flags, HL = row length, DE = rows, BC = destination bits 15:0; length vLen,
; pitches 1 and 256 (ddma_row). Out: CF = 0.
bp_set:
    ld (bpProg.mode), a
    ld (bpProg.rowlen), hl
    ld (bpProg.rows), de
    ld (bpAgain.dst), bc
    ld hl, (vLen)
    ld (bpAgain.len), hl
    ld hl, 1
    ld (bpProg.sa), hl
    inc h
    dec l
    ld (bpProg.sb), hl
    or a
    ret
bp_lin:
    ld a, DDMA_F_PHYS
    jr bp_one
bp_row:
    ld a, DDMA_F_PHYS|DDMA_F_2D
bp_one:
    ld hl, (vLen)
    ld de, 1
    ld bc, (L2_PHYS + V_OFS) & $FFFF
    jr bp_set
bp_col:
    ld a, DDMA_F_PHYS|DDMA_F_2D
    ld hl, 1
    ld de, (vLen)
    ld bc, (L2_PHYS + COL_V) & $FFFF
    jr bp_set
bp_blk:                          ; BLK_LEN as rows of BLK_ROW, both pitches BLK_ROW
    ld a, DDMA_F_PHYS|DDMA_F_2D
    ld hl, BLK_ROW
    ld de, BLK_LEN / BLK_ROW
    ld bc, (L2_PHYS + V_OFS) & $FFFF
    call bp_set
    ld hl, BLK_ROW
    ld (bpProg.sa), hl
    ret

; The full program once, for a reload row. Init runs quiet under DI: nothing is
; pending, so the transfer cannot be held. Out: CF = 0.
bp_prime:
    ld hl, bpProg
    ld bc, BP_PROG_LEN << 8 | DMA_PORT
    otir
    or a
    ret

    MACRO BP_HEAD
    call dma_reset
    call ddma_need
    ret c
    ENDM

dmainit_xl:                      ; linear, full program
    BP_HEAD
    call vid_load
    ret c
    jr bp_lin
dmainit_xf:                      ; row piece, full program
    BP_HEAD
    call vid_load
    ret c
    jr bp_row
dmainit_xr:                      ; row piece, reload
    BP_HEAD
    call vid_load
    ret c
    call bp_row
    jr bp_prime
dmainit_xg:                      ; column piece, full program
    BP_HEAD
    call vid_load
    ret c
    call col_pages
    jr bp_col
dmainit_xh:                      ; column piece, reload
    BP_HEAD
    call vid_load
    ret c
    call col_pages
    call bp_col
    jr bp_prime

; Shapes src/overlay2.asm sends whole: a 256 and a 320 row, and a BLK_LEN block.
dmainit_s0:                      ; row 256, reload
    BP_HEAD
    ld de, ROW_256
    call sp_load
    ret c
    call bp_row
    jr bp_prime
dmainit_s1:                      ; block, reload
    BP_HEAD
    ld de, BLK_LEN
    call sp_load
    ret c
    call bp_blk
    jr bp_prime
dmainit_s2:                      ; block, full program
    BP_HEAD
    ld de, BLK_LEN
    call sp_load
    ret c
    jp bp_blk
dmainit_s3:                      ; column 320, reload
    BP_HEAD
    ld de, ROW_320
    call sp_load
    ret c
    call col_pages
    call bp_col
    jp bp_prime
dmainit_s4:                      ; column 320, full program
    BP_HEAD
    ld de, ROW_320
    call sp_load
    ret c
    call col_pages
    jp bp_col
dmainit_s5:                      ; row 256, full program
    BP_HEAD
    ld de, ROW_256
    call sp_load
    ret c
    jp bp_row

; Pad proof rows: a shape above, then the last byte's address in both windows.
; MMU6 = source page, MMU7 = the Layer 2 page the last byte lands in.
dmainit_p0:                      ; block, full program
    call dma_reset
    call dmainit_s2
    jr pf_lin
dmainit_p1:                      ; block, reload
    call dma_reset
    call dmainit_s1
    jr pf_lin
dmainit_p2:                      ; row 256, reload
    call dma_reset
    call dmainit_s0
pf_lin:
    ret c
    ld hl, (vLen)
    dec hl
    push hl
    ld de, V_DST
    add hl, de
    ld (pfDst), hl
    pop hl
    ld de, V_SRC
    add hl, de
    ld (pfSrc), hl
    jr pf_zero
dmainit_p3:                      ; column 320, reload
    call dma_reset
    call dmainit_s3
    jr pf_col
dmainit_p4:                      ; column 320, full program
    call dma_reset
    call dmainit_s4
pf_col:
    ret c
    ld hl, (vLen)
    dec hl                       ; HL = n: page n >> 5, offset (n & 31) << 8 | COL_V
    push hl
    ld de, V_SRC
    add hl, de
    ld (pfSrc), hl
    pop hl
    ld a, l
    and 31
    or high (DST_WIN + $2000)
    ld d, a
    ld e, COL_V
    ld (pfDst), de
    add hl, hl
    add hl, hl
    add hl, hl
    ld a, h
    add a, L2_PAGE
    nextreg NR_MMU7, a
    nextreg NR_MMU6, SRC_PAGE    ; col_pages left MMU6 on an expected page
pf_zero:
    ld hl, 0
    ld (pfMiss), hl
    or a
    ret

; Bodies: the program by OTIR (the enable is its last byte), then the pad at once.
    MACRO BP_BODY name, prog, len, bytes
name:
    ld hl, prog                  ; 10
    ld bc, (len) << 8 | DMA_PORT ; 10
    otir                         ; 21 a byte, the last 16
    DDMA_PAD bytes
    ret
    ENDM

; Proof body: the last destination byte is set to the complement of its source byte,
; and read back by the first instruction after the pad. A' = the source byte.
    MACRO PF_BODY name, prog, len, bytes
name:
    ld hl, (pfSrc)
    ld a, (hl)
    ld de, (pfDst)
    cpl
    ld (de), a
    cpl
    ex af, af'
    ld hl, prog
    ld bc, (len) << 8 | DMA_PORT
    otir
    DDMA_PAD bytes
    ld a, (de)                   ; nothing between the pad and this read
    ld e, a
    ex af, af'
    cp e
    ret z
    jp pf_miss
    ENDM

    BP_BODY bp_f0, bpProg, BP_PROG_LEN, V0_L
    BP_BODY bp_f1, bpProg, BP_PROG_LEN, V1_L
    BP_BODY bp_f2, bpProg, BP_PROG_LEN, V2_L
    BP_BODY bp_f3, bpProg, BP_PROG_LEN, V3_L
    BP_BODY bp_f4, bpProg, BP_PROG_LEN, V4_L
    BP_BODY bp_f5, bpProg, BP_PROG_LEN, V5_L
    BP_BODY bp_f6, bpProg, BP_PROG_LEN, V6_L
    BP_BODY bp_f7, bpProg, BP_PROG_LEN, V7_L
    BP_BODY bp_r0, bpAgain, BP_AGAIN_LEN, V0_L
    BP_BODY bp_r1, bpAgain, BP_AGAIN_LEN, V1_L
    BP_BODY bp_r2, bpAgain, BP_AGAIN_LEN, V2_L
    BP_BODY bp_r3, bpAgain, BP_AGAIN_LEN, V3_L
    BP_BODY bp_r4, bpAgain, BP_AGAIN_LEN, V4_L
    BP_BODY bp_r5, bpAgain, BP_AGAIN_LEN, V5_L
    BP_BODY bp_r6, bpAgain, BP_AGAIN_LEN, V6_L
    BP_BODY bp_r7, bpAgain, BP_AGAIN_LEN, V7_L
; As sent: ddma_row_send pads for 320 whatever the row, ddma_go for DDMA_XFER_MAX.
    BP_BODY bp_f320, bpProg, BP_PROG_LEN, ROW_320
    BP_BODY bp_r320, bpAgain, BP_AGAIN_LEN, ROW_320
    BP_BODY bp_fmax, bpProg, BP_PROG_LEN, DDMA_XFER_MAX
    BP_BODY bp_rmax, bpAgain, BP_AGAIN_LEN, DDMA_XFER_MAX
    PF_BODY pf_fmax, bpProg, BP_PROG_LEN, DDMA_XFER_MAX
    PF_BODY pf_rmax, bpAgain, BP_AGAIN_LEN, DDMA_XFER_MAX
    PF_BODY pf_f320, bpProg, BP_PROG_LEN, ROW_320
    PF_BODY pf_r320, bpAgain, BP_AGAIN_LEN, ROW_320

pf_miss:
    ld hl, (pfMiss)
    inc hl
    ld (pfMiss), hl
    ret

; CK = reps whose last byte had not landed after the pad: 0000 OK.
ck_pad:
    ld hl, (pfMiss)
    ld de, 0
    jp ck_cmp

; ck_vid's page checksum is the same with and without a 240-byte copy, so the moved
; bytes are compared one by one first. CK = BAD0 on a difference.
ck_lin:
    nextreg NR_MMU6, SRC_PAGE
    nextreg NR_MMU7, L2_PAGE
    ld hl, V_SRC
    ld de, V_DST
    ld bc, (vLen)
.lp:
    ld a, (de)
    cp (hl)
    jr nz, ck_bad
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .lp
    jp ck_vid
ck_bad:
    ld hl, $BAD0
    scf
    ret

; Column piece: the moved bytes one by one, then the 10 pages against the reference.
ck_col:
    nextreg NR_MMU2, SRC_PAGE
    ld a, L2_PAGE
    ld (colPg), a
    nextreg NR_MMU6, a
    ld de, SRC_WIN + V_OFS
    ld hl, DST_WIN + COL_V
    ld bc, (vLen)
.lp:
    ld a, (de)
    cp (hl)
    jr nz, ck_bad
    inc de
    dec bc
    ld a, b
    or c
    jr z, .sum
    inc h
    ld a, h
    cp high (DST_WIN + $2000)
    jr nz, .lp
    ld h, high DST_WIN
    ld a, (colPg)
    inc a
    ld (colPg), a
    nextreg NR_MMU6, a
    jr .lp
.sum:
    ld hl, ref_col
    ld a, REF_ONCE
    call ref_run
    ld b, 10
    ld a, L2_PAGE
    call ck_pair
    jp ck_cmp

; vLen source bytes into the expected pages, 256 apart from COL_V.
ref_col:
    nextreg NR_MMU2, SRC_PAGE
    ld a, EXP_PAGE
    ld (colPg), a
    nextreg NR_MMU6, a
    ld de, SRC_WIN + V_OFS
    ld hl, DST_WIN + COL_V
    ld bc, (vLen)
.lp:
    ld a, (de)
    ld (hl), a
    inc de
    dec bc
    ld a, b
    or c
    ret z
    inc h
    ld a, h
    cp high (DST_WIN + $2000)
    jr nz, .lp
    ld h, high DST_WIN
    ld a, (colPg)
    inc a
    ld (colPg), a
    nextreg NR_MMU6, a
    jr .lp

colPg:        db 0
pfSrc:        dw 0
pfDst:        dw 0
pfMiss:       dw 0

; The program, laid out as src/overlay2.asm ddma_prog; its tail from bpAgain is the
; short reload (ddma_again).
bpProg:
    db DDMA_RESET
    db DDMA_MODE
.mode:        db 0
    db DDMA_ROWLEN
.rowlen:      dw 0
    db DDMA_ROWS
.rows:        dw 0
    db DDMA_STRIDE_A
.sa:          dw 0
    db DDMA_STRIDE_B
.sb:          dw 0
    db DDMA_FILLVAL
    db 0
    db DDMA_WR1, DDMA_CYCLE
    db DDMA_WR2, DDMA_CYCLE
    db DDMA_WR5
bpAgain:
    db DDMA_EXT_A
    db SRC_PHYS >> 16
    db DDMA_EXT_B
    db L2_PHYS >> 16
    db DDMA_WR0
    dw (SRC_PHYS + V_OFS) & $FFFF
.len:         dw 0
    db DDMA_WR4
.dst:         dw 0
    db DDMA_LOAD, DDMA_ENABLE
BP_AGAIN_LEN     equ $ - bpAgain
BP_PROG_LEN      equ $ - bpProg
    ASSERT BP_PROG_LEN == 36 && BP_AGAIN_LEN == 14
    ASSERT (SRC_PHYS + V_OFS) >> 16 == SRC_PHYS >> 16
    ASSERT (L2_PHYS + V_OFS + BLK_LEN - 1) >> 16 == L2_PHYS >> 16
    ASSERT {b IRQ_STATE_CALL} == $CC && {IRQ_STATE_CALL + 1} == ctc_start

; ---- row constants: OPD (ops.asm). OTIR 21 a byte, a DDMA_PAD pass 13 ----
    MACRO K_BP name, len, plen, padbytes
    OPD name, len, 20 + 21 * (plen) + 13 * (((padbytes) * DDMA_T_BYTE_MAX * DDMA_CTC_CHANNELS + DDMA_PAD_DEN - 1) / DDMA_PAD_DEN + 2), 4 * (len), (DDMA_T_BYTE_MAX + DDMA_ROW_PAD + 1) * (len) + DMA_XFER_PAD
    ENDM
    K_BP XF0, V0_L, BP_PROG_LEN, V0_L
    K_BP XF1, V1_L, BP_PROG_LEN, V1_L
    K_BP XF2, V2_L, BP_PROG_LEN, V2_L
    K_BP XF3, V3_L, BP_PROG_LEN, V3_L
    K_BP XF4, V4_L, BP_PROG_LEN, V4_L
    K_BP XF5, V5_L, BP_PROG_LEN, V5_L
    K_BP XF6, V6_L, BP_PROG_LEN, V6_L
    K_BP XF7, V7_L, BP_PROG_LEN, V7_L
    K_BP XR0, V0_L, BP_AGAIN_LEN, V0_L
    K_BP XR1, V1_L, BP_AGAIN_LEN, V1_L
    K_BP XR2, V2_L, BP_AGAIN_LEN, V2_L
    K_BP XR3, V3_L, BP_AGAIN_LEN, V3_L
    K_BP XR4, V4_L, BP_AGAIN_LEN, V4_L
    K_BP XR5, V5_L, BP_AGAIN_LEN, V5_L
    K_BP XR6, V6_L, BP_AGAIN_LEN, V6_L
    K_BP XR7, V7_L, BP_AGAIN_LEN, V7_L
    K_BP XS0, ROW_256, BP_AGAIN_LEN, ROW_320
    K_BP XS1, BLK_LEN, BP_AGAIN_LEN, DDMA_XFER_MAX
    K_BP XS2, BLK_LEN, BP_PROG_LEN, DDMA_XFER_MAX
    K_BP XS3, ROW_320, BP_AGAIN_LEN, ROW_320
    K_BP XS4, ROW_320, BP_PROG_LEN, ROW_320
    K_BP XS5, ROW_256, BP_PROG_LEN, ROW_320
