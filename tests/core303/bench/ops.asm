; Part 1b operation rows: rectangle copy (256x192, and 320x256 from a row-major or a
; column-major source), transparent copy, fill, tilemap scroll, video COPY and setup
; cost, each by CPU, zxnDMA and the zxnDDMA blitter. Port $6B only.

L2_BANK          equ 18
L2_PAGE          equ L2_BANK * 2  ; 36-45: Layer 2 destination (NR $12)
SRC_PAGE         equ 62           ; 62-71: source pool
EXP_PAGE         equ 72           ; 72-81: CPU-built expected image
OPS_LAST_PAGE    equ EXP_PAGE + 9
TM_PAGE          equ BANK5_PAGE + 1
    ASSERT L2_PAGE > DMA_PAGE && L2_PAGE + 9 < DDMA_PAGE && SRC_PAGE > DDMA_PAGE
    ASSERT OPS_LAST_PAGE < SRAM_PAGES_1M
PHYS_RAM         equ $40000       ; 8K page p at PHYS_RAM + p x $2000 (zxnddma.gde 2.5)
SRC_PHYS         equ PHYS_RAM + SRC_PAGE * $2000
L2_PHYS          equ PHYS_RAM + L2_PAGE * $2000

SRC_WIN          equ $4000        ; MMU2/MMU3 = source pages n, n+1: a line fits
SRC_WIN_END      equ high (SRC_WIN + $2000)
DST_WIN          equ $C000        ; MMU6 (and MMU7 for fills and video COPY)
T_KEY            equ $E3          ; transparent colour
FILL_VAL         equ $3C
FILL_CHUNK       equ 240          ; src/nextdaad.inc NXV2_DMA_CHUNK
V_OFS            equ $0100
V_SRC            equ DST_WIN + V_OFS            ; MMU6 = SRC_PAGE
V_DST            equ DST_WIN + $2000 + V_OFS    ; MMU7 = L2_PAGE
TM_MAP_B         equ $6000        ; src/nextdaad.inc TM_MAP: bank 5, MMU3 = TM_PAGE
SC_STRIDE        equ 160          ; 80 columns x 2 bytes (src/nextdaad.inc TM_COLS)
SC_TOP           equ 2
SC_SRC           equ TM_MAP_B + (SC_TOP + 1) * SC_STRIDE
SC_DST           equ TM_MAP_B + SC_TOP * SC_STRIDE
SEED_SRC         equ $17
SEED_DST         equ $A5
; Per 2D row: a margin, as DMA_XFER_PAD; no local RTL has the zxnDDMA (new_dma.vhd).
DDMA_ROW_PAD     equ 2

; Program lengths: the DUP counts need them first; ASSERTs pin them to the programs.
CB_LEN           equ 12
BLT_XY_LEN       equ 7
BLT_SHORT_LEN    equ 8
BLT_LIN_LEN      equ 10
BLT_FULL_LEN     equ 22
FI_ARM_LEN       equ 13

; $DF mode flags (zxnddma.gde 2.5)
DF_PHYS          equ %00000001
DF_2D            equ %00000010
DF_TRANSP        equ %00000100
DF_FILL          equ %00001000
DF_XY            equ %00010000
NR_L2_BANK       equ $12
NR_L2_SHADOW     equ $13
NR_L2_CTRL       equ $70
L2_MODE_256      equ %00000000    ; NR $70 bits 5:4
L2_MODE_320      equ %00010000

; Rect entry: dw W, H, X; db Y, P (lines a CPU rep); defines name_W, name_H, name_P.
RECT_LEN         equ 8
    MACRO RECTE name, w, h, x, y, p
name_W equ w
name_H equ h
name_P equ p
    dw w, h, x
    db y, p
    ENDM
rectTab0:                        ; 256x192 mode: R, T
    RECTE R0, 16, 16, 120, 88, 16
    RECTE R1, 32, 32, 112, 80, 32
    RECTE R2, 64, 64, 96, 64, 16
    RECTE R3, 128, 96, 64, 48, 8
    RECTE R4, 256, 192, 0, 0, 4
    ASSERT $ - rectTab0 == 5 * RECT_LEN
rectTabC:                        ; 320x256 mode, row-major source: P rows
    RECTE C0, 16, 16, 152, 120, 16
    RECTE C1, 64, 64, 128, 96, 8
    RECTE C2, 160, 128, 80, 64, 4
    RECTE C3, 320, 256, 0, 0, 2
rectTabK:                        ; 320x256 mode, column-major source: P columns
    RECTE K0, 16, 16, 152, 120, 16
    RECTE K1, 64, 64, 128, 96, 16
    RECTE K2, 160, 128, 80, 64, 8
    RECTE K3, 320, 256, 0, 0, 4
    ASSERT $ - rectTabC == 8 * RECT_LEN

    MACRO FILLE name, size, piece
name_S equ size
name_PC equ piece
    dw size, piece
    ENDM
fillTab:
    FILLE F0, 64, 64
    FILLE F1, 256, 256
    FILLE F2, 1024, 1024
    FILLE F3, 4096, 2048
    FILLE F4, 16384, 2048
    ASSERT $ - fillTab == 5 * 4

    MACRO SCRE name, h, p
name_H equ h
name_P equ p
    db h, p
    ENDM
scrollTab:                       ; window rows at full width, CPU rows a rep
    SCRE S0, 8, 7
    SCRE S1, 24, 8

    MACRO VIDE name, len
name_L equ len
    dw len
    ENDM
vidTab:
    VIDE V0, 1
    VIDE V1, 4
    VIDE V2, 8
    VIDE V3, 16
    VIDE V4, 53
    VIDE V5, 71
    VIDE V6, 128
    VIDE V7, 240
    ASSERT $ - vidTab == 8 * 2

; NR $12, $13, $70 kept for ops_restore (main, around run_table). Corrupts AF, BC, HL.
ops_save:
    ld hl, opsNr
    ld a, NR_L2_BANK
    call nr_read
    ld (hl), a
    inc hl
    ld a, NR_L2_SHADOW
    call nr_read
    ld (hl), a
    inc hl
    ld a, NR_L2_CTRL
    call nr_read
    ld (hl), a
    ret
ops_restore:
    ld a, (opsNr)
    nextreg NR_L2_BANK, a
    ld a, (opsNr + 1)
    nextreg NR_L2_SHADOW, a
    ld a, (opsNr + 2)
    nextreg NR_L2_CTRL, a
    ret

; ---- timed bodies; T per instruction is documented T ----

; lnP lines a rep from line pcIdx, wrap at lnCount: lnLen bytes at pcSrcPg:pcSrcAd to
; page L2_PAGE + (u >> 5), $C0 + (u & 31) : lnV, u = lnU0 + line (gfx_pos_row_write256).
; act 0 LDIR, 1 LDIRX, 2 dma_copy, 3 the 320 row scatter (cc_row, row = Y + line).
    MACRO WALK act
    ld hl, (lnP)                 ; 16
    ld (lnLeft), hl              ; 16
.ln:
    ld a, (pcSrcPg)              ; 13
    add a, SRC_PAGE              ; 7
    nextreg NR_MMU2, a           ; 17
    inc a                        ; 4
    nextreg NR_MMU3, a           ; 17
    IF act == 3
    ld a, (pcIdx)                ; 13
    ld hl, opY                   ; 10
    add a, (hl)                  ; 7
    ld (ccRowY), a               ; 13
    ld hl, (pcSrcAd)             ; 16
    call cc_row                  ; 17
    ELSE
    ld hl, (pcIdx)               ; 16
    ld de, (lnU0)                ; 20
    add hl, de                   ; 11
    ld a, l                      ; 4
    and $E0                      ; 7
    or h                         ; 4
    rlca                         ; 4
    rlca                         ; 4
    rlca                         ; 4 A = u >> 5, u < 512
    add a, L2_PAGE               ; 7
    nextreg NR_MMU6, a           ; 17
    ld a, l                      ; 4
    and 31                       ; 7
    or high DST_WIN              ; 7
    ld d, a                      ; 4
    ld a, (lnV)                  ; 13
    ld e, a                      ; 4
    ld hl, (pcSrcAd)             ; 16
    ld bc, (lnLen)               ; 20
    IF act == 0
    ldir                         ; 21n-5
    ENDIF
    IF act == 1
    ld a, T_KEY                  ; 7
    ldirx                        ; 21n-5: a byte equal to A is not written
    ENDIF
    IF act == 2
    call nd_dma_copy             ; 17 + ND_FIX + transfer
    ENDIF
    ENDIF
    ld a, h                      ; 4 HL = past the line's source
    cp SRC_WIN_END               ; 7
    jr c, .in                    ; 7 worst: page crossed
    sub $20                      ; 7
    ld h, a                      ; 4
    ld a, (pcSrcPg)              ; 13
    inc a                        ; 4
    ld (pcSrcPg), a              ; 13
.in:
    ld (pcSrcAd), hl             ; 16
    ld hl, (pcIdx)               ; 16
    inc hl                       ; 6
    ld de, (lnCount)             ; 20
    or a                         ; 4
    sbc hl, de                   ; 15
    jr nz, .nw                   ; 12; the wrap (once a rep at most) is 66
    xor a                        ; 4
    ld (pcSrcPg), a              ; 13
    ld de, SRC_WIN               ; 10
    ld (pcSrcAd), de             ; 20
    jr .st                       ; 12 HL = 0
.nw:
    add hl, de                   ; 11
.st:
    ld (pcIdx), hl               ; 16
    ld hl, (lnLeft)              ; 16
    dec hl                       ; 6
    ld (lnLeft), hl              ; 16
    ld a, h                      ; 4
    or l                         ; 4
    jr nz, .ln                   ; 12
    ENDM
; Per line, no wrap, act excluded; per rep: prologue 32 + one wrap 43 - last jr 5.
LW_LINE          equ 58 + 173 + 233
LW_FIX           equ 32 + 43 - 5
CC_LINE          equ 58 + 76 + 233   ; call cc_row included, cc_row excluded

lw_ldir:                         ; R and K CPU
    WALK 0
    ret
lw_ldirx:                        ; T CPU, reference, not shipping
    WALK 1
    ret
lw_dma:                          ; R and K zxnDMA
    WALK 2
    ret
cc_body:                         ; C CPU
    WALK 3
    ret

; overlay2.asm gfx_pos_row_write320: runs of up to 32 pixels, one LDWS each, page
; L2_PAGE + (x >> 5); LDWS steps L only, so a run is split where L wraps.
; HL = source row (left past it), row ccRowY. Corrupts AF, BC, DE.
cc_row:
    ld de, (opX)                 ; 20
    ld (ccX), de                 ; 20
    ld de, (opW)                 ; 20
    ld (ccLeft), de              ; 20
.page:
    ld de, (ccX)                 ; 20
    ld a, e                      ; 4
    and $E0                      ; 7
    or d                         ; 4
    rlca                         ; 4
    rlca                         ; 4
    rlca                         ; 4 A = x >> 5 (x < 512, D = 0/1)
    add a, L2_PAGE               ; 7
    nextreg NR_MMU6, a           ; 17
    ld a, e                      ; 4
    and 31                       ; 7
    ld c, a                      ; 4
    or high DST_WIN              ; 7
    ld d, a                      ; 4
    ld a, (ccRowY)               ; 13
    ld e, a                      ; 4 DE = dest
    ld a, 32                     ; 7
    sub c                        ; 4 A = room in this page, 1..32
    ld bc, (ccLeft)              ; 20
    inc b                        ; 4
    dec b                        ; 4
    jr nz, .run                  ; 7 worst: left < 256
    cp c                         ; 4
    jr c, .run                   ; 7
    ld a, c                      ; 4 run = left
.run:
    ld (ccRun), a                ; 13
    ld b, a                      ; 4
    ld a, l                      ; 4
    neg                          ; 8 A = pixels before L wraps (0 = 256)
    jr z, .tail                  ; 7 worst: split
    cp b                         ; 4
    jr nc, .tail                 ; 7
    ld c, a                      ; 4
    ld a, b                      ; 4
    sub c                        ; 4
    ld b, c                      ; 4
    ld c, a                      ; 4 B = before the wrap, C = after
.pre:
    ldws                         ; 14
    djnz .pre                    ; 13/8
    inc h                        ; 4
    ld b, c                      ; 4
.tail:
    ldws                         ; 14
    djnz .tail                   ; 13/8
    ld a, l                      ; 4
    or a                         ; 4
    jr nz, .adv                  ; 7 worst
    inc h                        ; 4 wrap landed on the run end
.adv:
    ld a, (ccRun)                ; 13
    ld c, a                      ; 4
    ld de, (ccX)                 ; 20
    add de, a                    ; 8
    ld (ccX), de                 ; 20
    ld de, (ccLeft)              ; 20
    ld a, e                      ; 4
    sub c                        ; 4
    ld e, a                      ; 4
    jr nc, .nob                  ; 7 worst
    dec d                        ; 6
.nob:
    ld (ccLeft), de              ; 20
    ld a, d                      ; 4
    or e                         ; 4
    jr nz, .page                 ; 12
    ret                          ; 10
; Prologue + ret - last jr; a run worst case (split) less its pixels; a pixel.
CCR_FIX          equ 80 + 10 - 5
CCR_RUN          equ 153 + 22 + 29 + 38 + 8 + 19 + 150 - 10
CCR_PX           equ 14 + 13

; src/overlay2.asm dma_copy (DMA_CHUNK_MAX = 256): static prefix, then one arm a chunk.
; HL = source, DE = dest, BC = length. Out: LDIR's end state. Corrupts AF, BC, DE, HL.
nd_dma_copy:
    push hl                      ; 11
    push bc                      ; 11
    ld hl, dmaInitNd + 1         ; 10 WR1/WR2/WR5 = src/overlay2.asm dma_prog_static
    ld bc, DMA_PORT              ; 10
    DUP DMA_INIT_ND_LEN - 1
    outinb                       ; 16
    EDUP
    pop bc                       ; 10
    pop hl                       ; 10
.loop:
    ld a, b                      ; 4
    or c                         ; 4
    ret z                        ; 5/11 CF = 0 for the sbc
    push hl                      ; 11
    ld hl, 256                   ; 10
    sbc hl, bc                   ; 15
    ld hl, 256                   ; 10
    jr c, .len                   ; 7 (length <= 256)
    ld h, b                      ; 4
    ld l, c                      ; 4
.len:
    ld (dmaArm.alen), hl         ; 16
    pop hl                       ; 10
    ld (dmaArm.aaddr), hl        ; 16
    ld (dmaArm.baddr), de        ; 20
    push bc                      ; 11
    ld hl, dmaArm                ; 10
    ld bc, DMA_PORT              ; 10
    DUP DMA_ARM_LEN
    outinb                       ; 16
    EDUP
    pop bc                       ; 10
    ld h, b                      ; 4
    ld l, c                      ; 4
    ld de, (dmaArm.alen)         ; 20
    or a                         ; 4
    sbc hl, de                   ; 15
    ld b, h                      ; 4
    ld c, l                      ; 4
    ld hl, (dmaArm.aaddr)        ; 16
    add hl, de                   ; 11
    push hl                      ; 11
    ld hl, (dmaArm.baddr)        ; 16
    add hl, de                   ; 11
    ex de, hl                    ; 4
    pop hl                       ; 10
    jp .loop                     ; 10
    ASSERT DMA_INIT_ND_LEN - 1 == 5
; One chunk (length <= 256): prefix 142, pass 497, final test 19; act = call + this.
ND_FIX           equ 142 + 497 + 19
ND_ACT           equ 17 + ND_FIX

; C blitter: one 2D transfer a pixel row (W rows of 1 byte, port B stride 256 by X,Y),
; lnP rows a rep, wrapping at lnCount. Source address and Y patched each row.
cb_body:
    ld hl, (lnP)                 ; 16
    ld (lnLeft), hl              ; 16
.row:
    ld hl, cbProg                ; 10
    ld bc, DMA_PORT              ; 10
    DUP CB_LEN
    outinb                       ; 16
    EDUP
    ld hl, (cbProg.alo)          ; 16
    ld bc, (opW)                 ; 20
    add hl, bc                   ; 11
    ld (cbProg.alo), hl          ; 16
    jr nc, .nc                   ; 7 worst: carry into bits 23:16
    ld hl, cbProg.ext            ; 10
    inc (hl)                     ; 11
.nc:
    ld hl, cbProg.y              ; 10
    inc (hl)                     ; 11
    ld hl, (pcIdx)               ; 16
    inc hl                       ; 6
    ld de, (lnCount)             ; 20
    or a                         ; 4
    sbc hl, de                   ; 15
    jr nz, .nw                   ; 12; the wrap is 95
    ld de, SRC_PHYS & $FFFF      ; 10
    ld (cbProg.alo), de          ; 20
    ld a, SRC_PHYS >> 16         ; 7
    ld (cbProg.ext), a           ; 13
    ld a, (opY)                  ; 13
    ld (cbProg.y), a             ; 13
    jr .st                       ; 12 HL = 0
.nw:
    add hl, de                   ; 11
.st:
    ld (pcIdx), hl               ; 16
    ld hl, (lnLeft)              ; 16
    dec hl                       ; 6
    ld (lnLeft), hl              ; 16
    ld a, h                      ; 4
    or l                         ; 4
    jr nz, .row                  ; 12
    ret
CB_ROW           equ 20 + CB_LEN * 16 + 63 + 28 + 21 + 61 + 23 + 16 + 58
CB_FIX           equ 32 + (95 - 23) - 5

; Blitter bodies: the per-transfer program from bltXY / bltShort / bltLin / bltFull.
blt_go7:
    ld hl, bltXY
    ld bc, DMA_PORT              ; B = 0: OUTINB keeps it
    DUP BLT_XY_LEN
    outinb
    EDUP
    ret
blt_go8:
    ld hl, bltShort
    ld bc, DMA_PORT
    DUP BLT_SHORT_LEN
    outinb
    EDUP
    ret
blt_go10:
    ld hl, bltLin
    ld bc, DMA_PORT
    DUP BLT_LIN_LEN
    outinb
    EDUP
    ret
blt_go22:
    ld hl, bltFull
    ld bc, DMA_PORT
    DUP BLT_FULL_LEN
    outinb
    EDUP
    ret
; K 320x256 blitter: N is 16-bit, so two transfers of 160 columns, one a rep in turn.
kb_half:
    ld hl, (kbNext)              ; 16
    ld bc, DMA_PORT              ; 10
    DUP CB_LEN
    outinb                       ; 16
    EDUP
    ld a, l                      ; 4
    cp low kbProgEnd             ; 7
    jr nz, .st                   ; 7 worst
    ld hl, kbProgA               ; 10
.st:
    ld (kbNext), hl              ; 16
    ret
KBH_DOC          equ 26 + CB_LEN * 16 + 44
BLT_GO7_DOC      equ 20 + BLT_XY_LEN * 16
BLT_GO8_DOC      equ 20 + BLT_SHORT_LEN * 16
BLT_GO10_DOC     equ 20 + BLT_LIN_LEN * 16
BLT_GO22_DOC     equ 20 + BLT_FULL_LEN * 16

; Fill CPU: fiPiece bytes a rep from pcDst, in vfc chunks of up to FILL_CHUNK, as
; src/video.asm vid_run_body's CPU branch; wraps at fiEnd.
fc_body:
    ld de, (pcDst)               ; 20
    ld hl, (fiPiece)             ; 16
    ld (fcLeft), hl              ; 16
.seg:
    ld bc, (fcLeft)              ; 20
    ld a, b                      ; 4
    or c                         ; 4 CF = 0 for the sbc
    jr z, .done                  ; 7, 12 at the end
    ld hl, FILL_CHUNK            ; 10
    sbc hl, bc                   ; 15
    jr nc, .fit                  ; 7 worst: capped
    ld bc, FILL_CHUNK            ; 10
.fit:
    ld hl, (fcLeft)              ; 16
    or a                         ; 4
    sbc hl, bc                   ; 15
    ld (fcLeft), hl              ; 16
    ld a, FILL_VAL               ; 7
    call vfc                     ; 17
    jr .seg                      ; 12
.done:
    ld hl, (fiEnd)               ; 16
    or a                         ; 4
    sbc hl, de                   ; 15
    jr nz, .st                   ; 7 worst: wrap
    ld de, DST_WIN               ; 10
.st:
    ld (pcDst), de               ; 20
    ret
; Prologue 52, last test 40, wrap 72; a chunk 164 + vfc's fixed 121 (bytes 13, passes 13).
FC_FIX           equ 52 + 40 + 72
FC_CHUNK         equ 164 + 121

; Fill zxnDMA: the whole fill, in vfd chunks of up to FILL_CHUNK.
fz_body:
    ld de, DST_WIN               ; 10
    ld hl, (fiSize)              ; 16
    ld (fcLeft), hl              ; 16
.seg:
    ld bc, (fcLeft)              ; 20
    ld a, b                      ; 4
    or c                         ; 4
    ret z                        ; 5/11
    ld hl, FILL_CHUNK            ; 10
    sbc hl, bc                   ; 15
    jr nc, .fit                  ; 7
    ld bc, FILL_CHUNK            ; 10
.fit:
    ld hl, (fcLeft)              ; 16
    or a                         ; 4
    sbc hl, bc                   ; 15
    ld (fcLeft), hl              ; 16
    call vfd                     ; 17
    jr .seg                      ; 12
FZ_FIX           equ 42 + 39
FZ_CHUNK         equ 155 + VFD_DOC

; Scroll walker: src/tilemap.asm tm_scroll_rect .move loop (cell address a row,
; width x 2 bytes), lnP rows a rep from row SC_TOP + pcIdx, wrapping at scEnd.
; act 0 LDIR, 2 dma_copy in its place (gfx_copy's drop-in).
    MACRO SWALK act
    ld a, (lnP)                  ; 13
    ld (scLeft), a               ; 13
    ld a, (pcIdx)                ; 13
    add a, SC_TOP                ; 7
    ld b, a                      ; 4
    ld c, 0                      ; 7 left column
.move:
    push bc                      ; 11
    call sc_cell_addr            ; 17
    ex de, hl                    ; 4 DE = dest row start
    pop bc                       ; 10
    push bc                      ; 11
    inc b                        ; 4
    call sc_cell_addr            ; 17 HL = source row start
    pop bc                       ; 10
    push bc                      ; 11
    ld a, (scW)                  ; 13
    add a, a                     ; 4 width x 2 bytes
    push bc                      ; 11
    ld c, a                      ; 4
    ld b, 0                      ; 7
    IF act == 0
    ldir                         ; 21n-5
    ELSE
    call nd_dma_copy             ; 17 + ND_FIX + transfer
    ENDIF
    pop bc                       ; 10
    pop bc                       ; 10
    inc b                        ; 4
    ld a, (scEnd)                ; 13
    cp b                         ; 4
    jr nz, .nw                   ; 7 worst: wrap
    ld b, SC_TOP                 ; 7
.nw:
    ld a, (scLeft)               ; 13
    dec a                        ; 4
    ld (scLeft), a               ; 13
    jr nz, .move                 ; 12
    ld a, b                      ; 4
    sub SC_TOP                   ; 7
    ld (pcIdx), a                ; 13
    ENDM
SW_ROW           equ 134 + 2 * SCA_DOC + 97 ; act excluded
SW_FIX           equ 57 - 5 + 24

sc_body:
    SWALK 0
    ret
sz_body:
    SWALK 2
    ret

; src/tilemap.asm tm_cell_addr at 160 bytes a row: B = row, C = col -> HL.
sc_cell_addr:
    push de                      ; 11
    ld e, b                      ; 4
    ld d, SC_STRIDE              ; 7
    mul d, e                     ; 8
    ex de, hl                    ; 4
    ld a, c                      ; 4
    add a, a                     ; 4
    add hl, a                    ; 8
    add hl, TM_MAP_B             ; 16
    pop de                       ; 10
    ret                          ; 10
SCA_DOC          equ 86

; Video COPY: src/video.asm vid_copy_ldi (CPU) and vid_copy_dma (zxnDMA) call sites.
vc_body:
    ld hl, V_SRC                 ; 10
    ld de, V_DST                 ; 10
    ld bc, (vLen)                ; 20
    call vcl                     ; 17
    ret
vz_body:
    ld hl, V_SRC                 ; 10
    ld de, V_DST                 ; 10
    ld bc, (vLen)                ; 20
    call vcd                     ; 17
    ret
VC_FIX           equ 57 + 59 + 10   ; + LDI 16 a byte, jp pe 10 a pass of 16
VZ_FIX           equ 57 + VCD_DOC

; Setup rows: NextDAAD's full program (session init + arm) and the arm alone.
uz0_body:
    call dma_init_nd             ; 17 + 151
    jp dma_arm_go                ; 10 + 196
UZ0_DOC          equ 168 + 10 + 196
UZ1_DOC          equ 196

; src/video.asm vid_fill_cpu: A = colour, DE = dest, C = chunk 0..240. DE += chunk;
; corrupts AF, BC, IYL. IYH = high vfc_blk (dmainit_fc), as IYH = high vid_stub there.
vfc:
    push hl                      ; 11
    ex de, hl                    ; 4
    ld e, a                      ; 4
    ld a, c                      ; 4
    neg                          ; 8
    and 15                       ; 7
    add a, a                     ; 4
    add a, low vfc_blk           ; 7
    ld iyl, a                    ; 8
    ld a, c                      ; 4
    add a, 15                    ; 7
    swapnib                      ; 8
    and 15                       ; 7 passes = (C + 15) >> 4
    ld b, a                      ; 4
    jr z, vfc_done               ; 7
    jp (iy)                      ; 8
    ALIGN 64
vfc_blk:
    DUP 16
    ld (hl), e                   ; 7
    inc hl                       ; 6
    EDUP
    djnz vfc_blk                 ; 13/8
vfc_done:
    ex de, hl                    ; 4
    pop hl                       ; 10
    ret                          ; 10
    ASSERT low vfc_blk <= 256 - 40

; src/video.asm vid_copy_ldi: HL = src, DE = dest, BC = count. IYH = high vcl_blk.
vcl:
    ld a, b                      ; 4
    or c                         ; 4
    ret z                        ; 5
    ld a, c                      ; 4
    neg                          ; 8
    and 15                       ; 7
    add a, a                     ; 4
    add a, low vcl_blk           ; 7
    ld iyl, a                    ; 8
    jp (iy)                      ; 8
    ALIGN 64
vcl_blk:
    DUP 16
    ldi                          ; 16
    EDUP
    jp pe, vcl_blk               ; 10 P/V = BC != 0
    ret                          ; 10
    ASSERT low vcl_blk <= 256 - 36

; src/video.asm vid_fill_dma: HL kept, DE = dest (+= chunk), BC = chunk. Port A is
; the fixed colour cell; WR1 back to incrementing after the arm.
vfd:
    ld (fiArm.blen), bc          ; 20
    ld (fiArm.bdst), de          ; 20
    ex de, hl                    ; 4
    add hl, bc                   ; 11
    ex de, hl                    ; 4
    push hl                      ; 11
    ld hl, fiArm                 ; 10
    ld bc, DMA_PORT              ; 10
    DUP FI_ARM_LEN
    outinb                       ; 16
    EDUP
    ld hl, wr1Inc                ; 10
    ld b, 2                      ; 7
    otir                         ; 21 + 16
    pop hl                       ; 10
    ret                          ; 10
VFD_DOC          equ 90 + FI_ARM_LEN * 16 + 54 + 20

; src/video.asm vid_copy_dma (its arm is dma.asm dmaArm, the same 11 bytes).
vcd:
    ld (dmaArm.aaddr), hl        ; 16
    ld (dmaArm.alen), bc         ; 20
    ld (dmaArm.baddr), de        ; 20
    add hl, bc                   ; 11
    ex de, hl                    ; 4
    add hl, bc                   ; 11
    ex de, hl                    ; 4
    push hl                      ; 11
    push de                      ; 11
    ld hl, dmaArm                ; 10
    ld bc, DMA_PORT              ; 10
    DUP DMA_ARM_LEN
    outinb                       ; 16
    EDUP
    pop de                       ; 10
    pop hl                       ; 10
    ret                          ; 10
VCD_DOC          equ 128 + DMA_ARM_LEN * 16 + 30

; ---- inits (untimed). CF set = skip, DE = reason ----

; A = the row's size index: tag char 4, 0-9 then A-Z. Corrupts F, IX.
op_idx:
    ld ix, (rtRow)
    ld a, (ix + 3)
    sub '0'
    cp 10
    ret c
    sub 'A' - '0' - 10
    ret

; A = WR1/WR2 timing byte for the row's cycle length: 3 -> %01, 2 -> %10.
op_timing:
    ld a, (rtKind)
    and 3
    neg
    add a, 4
    ret

; HL = rect table, C = NR $70 mode. Entry for the size into opW..opP, NR $12/$70,
; source, Layer 2 and expected pages filled, walker at line 0. Corrupts all.
rect_load:
    push hl
    push bc
    ld a, OPS_LAST_PAGE
    call buf_page
    pop bc
    pop hl
    ret c                        ; #SKIP SRAM
    push bc
    call op_idx
    add a, a
    add a, a
    add a, a
    add hl, a
    ld de, opW
    ld bc, RECT_LEN
    ldir
    pop bc
    nextreg NR_L2_BANK, L2_BANK
    ld a, c
    nextreg NR_L2_CTRL, a
    or a
    ld a, 6                      ; 256x192: 3 banks
    jr z, .pg
    ld a, 10                     ; 320x256: 5 banks
.pg:
    ld (opPages), a
    ld a, SRC_PAGE
    ld b, 10
    ld c, SEED_SRC
    call pat_fill
    ld a, (opPages)
    ld b, a
    push bc
    ld a, L2_PAGE
    ld c, SEED_DST
    call pat_fill
    pop bc
    ld a, EXP_PAGE
    ld c, SEED_DST
    call pat_fill
    ld a, (opP)
    ld l, a
    ld h, 0
    ld (lnP), hl
; Line 0, source at the pool start. Out: CF = 0. Corrupts A, HL.
walk_reset:
    ld hl, 0
    ld (pcIdx), hl
    ld hl, SRC_WIN
    ld (pcSrcAd), hl
    xor a
    ld (pcSrcPg), a
    ret

; R and T: lines are rows (W bytes, H of them), u = Y, v = X. Out: CF = 0.
lines_rows:
    ld a, (opY)
    ld l, a
    ld h, 0
    ld (lnU0), hl
    ld (rfU), hl
    ld a, (opX)
    ld (lnV), a
    ld (rfV), a
    ld hl, (opW)
    ld (lnLen), hl
    ld (rfLen), hl
    ld hl, (opH)
    ld (lnCount), hl
    ld (rfLines), hl
    jr lines_end
; K: lines are columns (H bytes, W of them), u = X, v = Y. Out: CF = 0.
lines_cols:
    ld hl, (opX)
    ld (lnU0), hl
    ld (rfU), hl
    ld a, (opY)
    ld (lnV), a
    ld (rfV), a
    ld hl, (opH)
    ld (lnLen), hl
    ld (rfLen), hl
    ld hl, (opW)
    ld (lnCount), hl
    ld (rfLines), hl
lines_end:
    ld hl, $0001                 ; rfUi = 1, rfVi = 0
    ld (rfUi), hl
    xor a
    ld (rfStep), a
    ld (rfKey), a
    ret
; C: H rows of W bytes; the reference steps 256 along a row (column-major surface).
lines_c:
    ld hl, (opH)
    ld (lnCount), hl
    ld (rfLines), hl
    ld hl, (opW)
    ld (rfLen), hl
    ld hl, (opX)
    ld (rfU), hl
    ld a, (opY)
    ld (rfV), a
    ld hl, $0100                 ; rfUi = 0, rfVi = 1
    ld (rfUi), hl
    ld a, 1
    ld (rfStep), a
    xor a
    ld (rfKey), a
    ret

; T: a source byte whose low 2 bits are 0 becomes T_KEY; the reference skips them.
key_src:
    ld a, 1
    ld (rfKey), a
    ld a, SRC_PAGE
    ld b, 10
.pg:
    nextreg NR_MMU6, a
    push af
    ld hl, DST_WIN
.b:
    ld a, (hl)
    and 3
    jr nz, .n
    ld (hl), T_KEY
.n:
    inc hl
    ld a, h
    cp high (DST_WIN + $2000)
    jr nz, .b
    pop af
    inc a
    djnz .pg
    or a
    ret

; HL = 2D row length, DE = rows, BC = source stride, A = $DF flags: the X,Y rect
; set-up sent (zxnddma.gde 2.8, example 3 order); bltXY and cbProg set.
bxy_init:
    ld (bltXY.f), a
    ld (cbProg.f), a
    ld (rxInit.rl), hl
    ld (rxInit.nr), de
    ld (rxInit.st), bc
    ld hl, (opX)
    ld (bltXY.x), hl
    ld (cbProg.x), hl
    ld a, (opY)
    ld (bltXY.y), a
    ld (cbProg.y), a
    ld hl, SRC_PHYS & $FFFF
    ld (cbProg.alo), hl
    ld a, SRC_PHYS >> 16
    ld (cbProg.ext), a
    call op_timing
    ld (rxInit.t1), a
    ld (rxInit.t2), a
    ld hl, rxInit
    ld bc, RX_INIT_LEN << 8 | DMA_PORT
    otir
    or a
    ret

dmainit_rc:                      ; R CPU
    call dma_reset
    ld hl, rectTab0
    ld c, L2_MODE_256
    call rect_load
    ret c
    jp lines_rows

dmainit_rz:                      ; R zxnDMA
    call dma_reset
    call dma_init_nd
    ld hl, rectTab0
    ld c, L2_MODE_256
    call rect_load
    ret c
    jp lines_rows

dmainit_rb:                      ; R blitter
    call dma_reset
    call ddma_need
    ret c                        ; #SKIP NODDMA
    ld hl, rectTab0
    ld c, L2_MODE_256
    call rect_load
    ret c
    call lines_rows
    ld a, DF_PHYS | DF_2D | DF_XY
rb_xy:                           ; rows of W, H rows, stride W
    ld hl, (opW)
    ld de, (opH)
    ld bc, (opW)
    jp bxy_init

dmainit_tc:                      ; T CPU
    call dma_reset
    ld hl, rectTab0
    ld c, L2_MODE_256
    call rect_load
    ret c
    call lines_rows
    jp key_src

dmainit_tb:                      ; T blitter
    call dma_reset
    call ddma_need
    ret c
    ld hl, rectTab0
    ld c, L2_MODE_256
    call rect_load
    ret c
    call lines_rows
    call key_src
    ld a, DF_PHYS | DF_2D | DF_TRANSP | DF_XY
    jr rb_xy

dmainit_cc:                      ; C CPU
    call dma_reset
    ld hl, rectTabC
    ld c, L2_MODE_320
    call rect_load
    ret c
    jp lines_c

dmainit_cb:                      ; C blitter
    call dma_reset
    call ddma_need
    ret c
    ld hl, rectTabC
    ld c, L2_MODE_320
    call rect_load
    ret c
    call lines_c
    ld hl, 1                     ; a 2D row is one pixel, W of them, stride 1
    ld de, (opW)
    ld bc, 1
    ld a, DF_PHYS | DF_2D | DF_XY
    jp bxy_init

dmainit_kc:                      ; K CPU
    call dma_reset
    ld hl, rectTabK
    ld c, L2_MODE_320
    call rect_load
    ret c
    jp lines_cols

dmainit_kz:                      ; K zxnDMA
    call dma_reset
    call dma_init_nd
    ld hl, rectTabK
    ld c, L2_MODE_320
    call rect_load
    ret c
    jp lines_cols

dmainit_kb:                      ; K blitter
    call dma_reset
    call ddma_need
    ret c
    ld hl, rectTabK
    ld c, L2_MODE_320
    call rect_load
    ret c
    call lines_cols
    ld de, (opW)
    ld a, d
    or a
    jr z, .one
    srl d                        ; 320 wide: two transfers of W / 2 columns
    rr e
.one:
    ld hl, (opH)                 ; a 2D row is a column (zxnddma.gde 2.5)
    ld bc, (opH)
    push de
    ld a, DF_PHYS | DF_2D | DF_XY
    call bxy_init
    ld hl, cbProg                ; kbProgA: columns from X, kbProgB: from X + E
    ld de, kbProgA
    ld bc, CB_LEN
    ldir
    ld hl, cbProg
    ld de, kbProgB
    ld bc, CB_LEN
    ldir
    pop de                       ; E = columns a transfer (1..255)
    ld hl, (opX)
    ld a, e
    add hl, a
    ld (kbProgB + CB_X), hl
    ld hl, 0
    ld bc, (opH)
.mul:
    add hl, bc                   ; HL = columns x H
    dec a
    jr nz, .mul
    ld de, SRC_PHYS & $FFFF
    add hl, de
    ld (kbProgB + CB_ALO), hl
    ld a, SRC_PHYS >> 16
    adc a, 0
    ld (kbProgB + CB_EXT), a
    ld hl, kbProgA
    ld (kbNext), hl
    or a
    ret

; Fill entry for the size; Layer 2 pages 0-1 at MMU6/7, they and the expected pages
; filled. Out: CF set, DE = reason, past SRAM. Corrupts all.
fill_load:
    ld a, OPS_LAST_PAGE
    call buf_page
    ret c
    call op_idx
    add a, a
    add a, a
    ld hl, fillTab
    add hl, a
    ld de, fiSize
    ld bc, 4
    ldir                         ; fiSize, fiPiece
    ld hl, (fiSize)
    ld de, DST_WIN
    ld (pcDst), de
    add hl, de
    ld (fiEnd), hl
    ld a, L2_PAGE
    ld b, 2
    ld c, SEED_DST
    call pat_fill
    ld a, EXP_PAGE
    ld b, 2
    ld c, SEED_DST
    call pat_fill
    nextreg NR_MMU6, L2_PAGE
    nextreg NR_MMU7, L2_PAGE + 1
    or a
    ret

dmainit_fc:                      ; F CPU
    call dma_reset
    call fill_load
    ret c
    ld iy, vfc_blk
    ret

dmainit_fz:                      ; F zxnDMA
    call dma_reset
    call dma_init_nd
    jp fill_load

dmainit_fb:                      ; F blitter
    call dma_reset
    call ddma_need
    ret c
    call fill_load
    ret c
    ld hl, SRC_PHYS & $FFFF      ; port A: not read in fill mode
    ld de, L2_PHYS & $FFFF
    ld bc, (fiSize)
    ld a, DF_PHYS | DF_FILL
    jp lin_init

; HL = port A, DE = port B (bits 15:0; 23:16 are SRC_PHYS's and L2_PHYS's), BC =
; length, A = $DF flags: the linear set-up sent; bltLin and bltShort set.
lin_init:
    ld (linInit.f), a
    ld (linInit.alo), hl
    ld (bltLin.alo), hl
    ld (bltShort.alo), hl
    ld (bltFull.alo), hl
    ld (linInit.blo), de
    ld (bltLin.blo), de
    ld (bltShort.blo), de
    ld (bltFull.blo), de
    ld (linInit.len), bc
    ld (bltLin.len), bc
    call op_timing
    ld (linInit.t1), a
    ld (linInit.t2), a
    ld (bltFull.t1), a
    ld (bltFull.t2), a
    ld hl, linInit
    ld bc, LIN_INIT_LEN << 8 | DMA_PORT
    otir
    or a
    ret

; Video COPY length for the size; source, Layer 2 and expected page 0 filled,
; MMU6 = source, MMU7 = Layer 2. Out: CF set, DE = reason, past SRAM.
vid_load:
    ld a, OPS_LAST_PAGE
    call buf_page
    ret c
    call op_idx
    add a, a
    ld hl, vidTab
    add hl, a
    ld e, (hl)
    inc hl
    ld d, (hl)
vid_pages:                       ; DE = length
    ld (vLen), de
    ld a, SRC_PAGE
    ld b, 1
    ld c, SEED_SRC
    call pat_fill
    ld a, L2_PAGE
    ld b, 1
    ld c, SEED_DST
    call pat_fill
    ld a, EXP_PAGE
    ld b, 1
    ld c, SEED_DST
    call pat_fill
    nextreg NR_MMU6, SRC_PAGE
    nextreg NR_MMU7, L2_PAGE
    or a
    ret
; Setup rows: a 1-byte video COPY.
u_load:
    ld a, OPS_LAST_PAGE
    call buf_page
    ret c
    ld de, 1
    jr vid_pages

dmainit_vc:                      ; V CPU
    call dma_reset
    call vid_load
    ret c
    ld iy, vcl_blk
    ret

dmainit_vz:                      ; V zxnDMA
    call dma_reset
    call dma_init_nd
    jp vid_load

dmainit_vb:                      ; V blitter: physical, no paging
    call dma_reset
    call ddma_need
    ret c
    call vid_load
    ret c
    ld bc, (vLen)
v_lin:
    ld hl, (SRC_PHYS + V_OFS) & $FFFF
    ld de, (L2_PHYS + V_OFS) & $FFFF
    ld a, DF_PHYS
    jp lin_init

dmainit_uz:                      ; U zxnDMA: DUZ0 full program, DUZ1 arm only
    call dma_reset
    call dma_init_nd
    call u_load
    ret c
    ld hl, V_SRC
    ld de, V_DST
    ld bc, 1
    call dma_arm_set
    or a
    ret

dmainit_ub:                      ; U blitter: DUB0 full program, DUB1 short reload
    call dma_reset
    call ddma_need
    ret c
    call u_load
    ret c
    ld bc, 1
    jr v_lin

; Scroll window for the size; the tilemap page (MMU3) filled and copied to the
; expected page. Out: CF set, DE = reason, past SRAM.
scroll_load:
    ld a, OPS_LAST_PAGE
    call buf_page
    ret c
    call op_idx
    add a, a
    ld hl, scrollTab
    add hl, a
    ld a, (hl)
    dec a                        ; rows moved = height - 1
    ld (scRows), a
    ld e, a
    add a, SC_TOP
    ld (scEnd), a
    inc hl
    ld a, (hl)
    ld l, a
    ld h, 0
    ld (lnP), hl
    ld d, SC_STRIDE
    mul d, e
    ld (scBytes), de
    ld hl, 0
    ld (pcIdx), hl
    nextreg NR_MMU3, TM_PAGE
    ld a, TM_PAGE
    ld b, 1
    ld c, SEED_SRC
    call pat_fill
    nextreg NR_MMU6, TM_PAGE
    nextreg NR_MMU7, EXP_PAGE
    ld hl, DST_WIN
    ld de, DST_WIN + $2000
    ld bc, $2000
    ldir
    or a
    ret

dmainit_sc:                      ; S CPU
    call dma_reset
    jp scroll_load

dmainit_sz:                      ; S zxnDMA: the whole scroll a rep
    call dma_reset
    call dma_init_nd
    call scroll_load
    ret c
    ld a, (scRows)
    ld (lnP), a
    ret

dmainit_sb:                      ; S blitter: 2D through the MMU (bank 5 is block RAM)
    call dma_reset
    call ddma_need
    ret c
    call scroll_load
    ret c
    ld hl, SC_SRC
    ld (scInit.alo), hl
    ld (bltShort.alo), hl
    ld hl, SC_DST
    ld (scInit.blo), hl
    ld (bltShort.blo), hl
    ld a, (scRows)
    ld l, a
    ld h, 0
    ld (scInit.nr), hl
    call op_timing
    ld (scInit.t1), a
    ld (scInit.t2), a
    ld hl, scInit
    ld bc, SC_INIT_LEN << 8 | DMA_PORT
    otir
    or a
    ret

; A = first page, B = page count, C = seed: byte = L xor low(H x 29) xor seed through
; MMU6, seed += 101 a page. Corrupts AF, C, DE, HL.
pat_fill:
.pg:
    nextreg NR_MMU6, a
    push af
    push bc
    ld hl, DST_WIN
.blk:
    ld a, h
    and $1F
    ld e, a
    ld d, 29
    mul d, e
    ld a, e
    xor c
    ld e, a
.b:
    ld a, l
    xor e
    ld (hl), a
    inc l
    jr nz, .b
    inc h
    ld a, h
    cp high (DST_WIN + $2000)
    jr nz, .blk
    pop bc
    pop af
    inc a
    ld e, a
    ld a, c
    add a, 101
    ld c, a
    ld a, e
    djnz .pg
    ret

; ---- checks: every one ends in jp ck_cmp ----

ck_rect:
    ld hl, ref_rect
    ld a, REF_ONCE
    call ref_run
    ld a, (opPages)
    ld b, a
    ld a, L2_PAGE
    call ck_pair
    jp ck_cmp

ck_fill:
    ld hl, ref_fill
    ld a, REF_ONCE
    call ref_run
    ld b, 2
    ld a, L2_PAGE
    call ck_pair
    jp ck_cmp

ck_vid:                          ; V and U
    ld hl, ref_vid
    ld a, REF_ONCE
    call ref_run
    ld b, 1
    ld a, L2_PAGE
    call ck_pair
    jp ck_cmp

ck_scroll:                       ; not idempotent: the reference runs the row's reps
    ld hl, ref_scroll
    ld a, REF_REPS
    call ref_run
    ld b, 1
    ld a, TM_PAGE
    call ck_pair
    jp ck_cmp

; A = measured first page, B = page count -> HL = measured, DE = expected (the same
; count from EXP_PAGE). Corrupts AF, BC.
ck_pair:
    push af
    push bc
    ld a, EXP_PAGE
    call ckp
    pop bc
    pop af
    push hl
    call ckp
    pop de
    ret

; A = first page, B = page count -> HL = ck16's rotate-left-and-add over the pages,
; read through MMU6. Corrupts AF, BC, DE.
ckp:
    ld hl, 0
.pg:
    nextreg NR_MMU6, a
    push af
    push bc
    ld de, DST_WIN
    ld bc, $2000
.lp:
    add hl, hl
    jr nc, .nc
    inc l
.nc:
    ld a, (de)
    add a, l
    ld l, a
    jr nc, .nc2
    inc h
.nc2:
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .lp
    pop bc
    pop af
    inc a
    djnz .pg
    ret

; ---- references: byte by byte into the expected pages ----

; rfLines lines of rfLen source bytes (pool order); a line starts at dest (U, V) =
; (rfU + n x rfUi, rfV + n x rfVi) and steps V (rfStep 0) or U (1) a byte. Dest
; offset U x 256 + V, page EXP_PAGE + (U >> 5). rfKey: skip T_KEY bytes.
ref_rect:
    xor a
    ld (rfPg), a
    ld hl, SRC_WIN
    ld (rfAd), hl
    ld hl, (rfLines)
    ld (rfLeft), hl
    ld hl, (rfU)
    ld (rfCu), hl
    ld a, (rfV)
    ld (rfCv), a
.line:
    ld a, (rfPg)
    add a, SRC_PAGE
    nextreg NR_MMU2, a
    inc a
    nextreg NR_MMU3, a
    ld hl, (rfCu)
    ld (rfDu), hl
    ld a, (rfCv)
    ld (rfDv), a
    ld de, (rfAd)
    ld bc, (rfLen)
.px:
    ld a, (de)
    inc de
    push bc
    ld c, a
    ld a, (rfKey)
    or a
    jr z, .wr
    ld a, c
    cp T_KEY
    jr z, .skip
.wr:
    ld hl, (rfDu)
    ld a, l
    and $E0
    or h
    rlca
    rlca
    rlca
    add a, EXP_PAGE
    nextreg NR_MMU6, a
    ld a, l
    and 31
    or high DST_WIN
    ld h, a
    ld a, (rfDv)
    ld l, a
    ld (hl), c
.skip:
    ld a, (rfStep)
    or a
    jr nz, .u
    ld hl, rfDv
    inc (hl)
    jr nz, .adv
.u:
    ld hl, (rfDu)
    inc hl
    ld (rfDu), hl
.adv:
    pop bc
    dec bc
    ld a, b
    or c
    jr nz, .px
    ex de, hl
    ld a, h
    cp SRC_WIN_END
    jr c, .in
    sub $20
    ld h, a
    ld a, (rfPg)
    inc a
    ld (rfPg), a
.in:
    ld (rfAd), hl
    ld a, (rfUi)
    ld hl, (rfCu)
    add hl, a
    ld (rfCu), hl
    ld a, (rfVi)
    ld hl, rfCv
    add a, (hl)
    ld (hl), a
    ld hl, (rfLeft)
    dec hl
    ld (rfLeft), hl
    ld a, h
    or l
    jp nz, .line
    ret

ref_fill:
    nextreg NR_MMU6, EXP_PAGE
    nextreg NR_MMU7, EXP_PAGE + 1
    ld hl, DST_WIN
    ld bc, (fiSize)
.lp:
    ld (hl), FILL_VAL
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .lp
    ret

ref_vid:
    nextreg NR_MMU6, SRC_PAGE
    nextreg NR_MMU7, EXP_PAGE
    ld hl, V_SRC
    ld de, V_DST
    ld bc, (vLen)
.lp:
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .lp
    ret

; One whole scroll of the expected copy: rows SC_TOP+1.. up one, ascending.
ref_scroll:
    nextreg NR_MMU3, EXP_PAGE
    ld hl, SC_SRC
    ld de, SC_DST
    ld bc, (scBytes)
    ldir
    ret

; ---- programs ----

; X,Y rect set-up (zxnddma.gde example 3 order): WR0..WR5, $D7, 2D, $F3.
rxInit:
    db $7D                       ; WR0: A to B, port A address and length follow
    dw SRC_PHYS & $FFFF
    dw 0                         ; length: not used in 2D (zxnddma.gde 2.5)
    db $54                       ; WR1: memory, up, timing follows
.t1:
    db 0
    db $50                       ; WR2: memory, up, timing follows
.t2:
    db 0
    db $A1, $82                  ; WR4 continuous, no address (X,Y gives it); WR5 stop
    db $D7, SRC_PHYS >> 16
    db $E3
.rl:
    dw 0
    db $E7
.nr:
    dw 0
    db $EB
.st:
    dw 0
    db $F3, T_KEY                ; used only with DF_TRANSP
RX_INIT_LEN      equ $ - rxInit
    ASSERT RX_INIT_LEN == 24

; X,Y body (example 3's short reload): $DF flags X Y, load, go.
bltXY:
    db $DF
.f:
    db 0
.x:
    dw 0
.y:
    db 0
    db $CF, $87
    ASSERT $ - bltXY == BLT_XY_LEN

; C body: $D7, $1D (zxnddma.gde 2.9 note 1), then the X,Y form of $DF.
cbProg:
    db $D7
.ext:
    db 0
    db $1D                       ; WR0: A to B, port A address only
.alo:
    dw 0
    db $DF
.f:
    db 0
.x:
    dw 0
.y:
    db 0
    db $CF, $87
    ASSERT $ - cbProg == CB_LEN
CB_EXT           equ cbProg.ext - cbProg
CB_ALO           equ cbProg.alo - cbProg
CB_X             equ cbProg.x - cbProg
    ALIGN 32                     ; kb_half compares the low byte only
kbProgA:      ds CB_LEN
kbProgB:      ds CB_LEN
kbProgEnd:
    ASSERT high kbProgA == high kbProgEnd
kbNext:       dw kbProgA

; Linear set-up: physical ($DF bit 0), port B by WR4, fill value for DF_FILL.
linInit:
    db $7D
.alo:
    dw 0
.len:
    dw 0
    db $54
.t1:
    db 0
    db $50
.t2:
    db 0
    db $AD                       ; WR4: continuous, port B address follows
.blo:
    dw 0
    db $82
    db $D7, SRC_PHYS >> 16
    db $DB, L2_PHYS >> 16
    db $F7, FILL_VAL
    db $DF
.f:
    db 0
LIN_INIT_LEN     equ $ - linInit
    ASSERT LIN_INIT_LEN == 21

; Linear body: both addresses and the length, load, go (a COPY or RUN of any length).
bltLin:
    db $7D
.alo:
    dw 0
.len:
    dw 0
    db $AD
.blo:
    dw 0
    db $CF, $87
    ASSERT $ - bltLin == BLT_LIN_LEN

; Short reload (zxnddma.gde 2.9 note 1): $1D lo hi, $AD lo hi, $CF $87.
bltShort:
    db $1D
.alo:
    dw 0
    db $AD
.blo:
    dw 0
    db $CF, $87
    ASSERT $ - bltShort == BLT_SHORT_LEN

; Full program, zxnddma.gde 2.8 order, 1 byte, physical.
bltFull:
    db $C3
    db $D7, SRC_PHYS >> 16
    db $DB, L2_PHYS >> 16
    db $DF, DF_PHYS
    db $7D
.alo:
    dw 0
    dw 1
    db $54
.t1:
    db 0
    db $50
.t2:
    db 0
    db $AD
.blo:
    dw 0
    db $82
    db $CF, $87
    ASSERT $ - bltFull == BLT_FULL_LEN

; Scroll set-up: 2D through the MMU, both strides one tilemap row.
scInit:
    db $7D
.alo:
    dw 0
    dw 0
    db $54
.t1:
    db 0
    db $50
.t2:
    db 0
    db $AD
.blo:
    dw 0
    db $82
    db $E3
    dw SC_STRIDE
    db $E7
.nr:
    dw 0
    db $EB
    dw SC_STRIDE
    db $EF
    dw SC_STRIDE
    db $DF, DF_2D
SC_INIT_LEN      equ $ - scInit
    ASSERT SC_INIT_LEN == 27

; src/video.asm vidDmaFiArm: port A fixed at the colour cell.
fiArm:
    db $83                       ; WR6: disable
    db %01111101                 ; WR0: A to B, port A address and length follow
    dw fiColour
.blen:
    dw 0
    db %01100100                 ; WR1: A memory, fixed, timing follows
    db %00000010                 ; A cycle length 2
    db %10101101                 ; WR4: continuous, port B address follows
.bdst:
    dw 0
    db $CF, $87
    ASSERT $ - fiArm == FI_ARM_LEN
wr1Inc:                          ; src/video.asm vidDmaWr1Inc
    db %01010100, %00000010
fiColour:     db FILL_VAL

; ---- cells ----
opW:          dw 0
opH:          dw 0
opX:          dw 0
opY:          db 0
opP:          db 0
    ASSERT opP - opW == RECT_LEN - 1
opPages:      db 0
pcIdx:        dw 0
pcSrcPg:      db 0
pcSrcAd:      dw 0
pcDst:        dw 0
lnU0:         dw 0
lnV:          db 0
lnLen:        dw 0
lnCount:      dw 0
lnP:          dw 0
lnLeft:       dw 0
ccX:          dw 0
ccLeft:       dw 0
ccRun:        db 0
ccRowY:       db 0
fiSize:       dw 0
fiPiece:      dw 0
    ASSERT fiPiece == fiSize + 2
fiEnd:        dw 0
fcLeft:       dw 0
vLen:         dw 0
scW:          db SC_STRIDE / 2   ; tmScrollW: the window's width in cells
scLeft:       db 0
scEnd:        db 0
scRows:       db 0
scBytes:      dw 0
rfLines:      dw 0
rfLen:        dw 0
rfU:          dw 0
rfUi:         db 0
rfVi:         db 0
    ASSERT rfVi == rfUi + 1
rfV:          db 0
rfStep:       db 0
rfKey:        db 0
rfPg:         db 0
rfAd:         dw 0
rfLeft:       dw 0
rfCu:         dw 0
rfCv:         db 0
rfDu:         dw 0
rfDv:         db 0
opsNr:        ds 3

; ---- row constants: name_N (units a rep), name_C (worst-case T), name_R (reps) ----
; Worst case: CPU code x 4/3 (+1 T on a fetch or a read, each >= 3 T at 28 MHz);
; a transferred byte +1 (read wait); DMA_XFER_PAD a transfer, DDMA_ROW_PAD a 2D row.
    MACRO OPK name, units, doc, cost
name_N = units
name_C = cost
name_D = doc
name_R = (P1_FRAMES * (FRAME_T0 << 3) + (doc) + POLL_FAST - 1) / ((doc) + POLL_FAST)
    IF name_R > $FFFF
name_R = $FFFF
    ENDIF
    ASSERT name_R * ((doc) + POLL_FAST) >= 50 * (FRAME_T0 << 3), "row spans under 50 frames"
    ENDM
    MACRO OPC name, units, doc
    OPK name, units, doc, ((doc) * 4 + 2) / 3
    ENDM
    MACRO OPD name, units, cdoc, xdoc, xcost
    OPK name, units, (cdoc) + (xdoc), ((cdoc) * 4 + 2) / 3 + (xcost)
    ENDM
    MACRO K_LINE name, len, lines, actd
    OPC name, (lines) * (len), LW_FIX + (lines) * (LW_LINE + (actd))
    ENDM
    MACRO K_LDMA name, len, lines
    OPD name, (lines) * (len), LW_FIX + (lines) * (LW_LINE + ND_ACT), (lines) * 4 * (len), (lines) * (5 * (len) + DMA_XFER_PAD)
    ENDM
    MACRO K_BXY name, bytes, rows, cyc
    OPD name, bytes, BLT_GO7_DOC, (bytes) * 2 * (cyc), (bytes) * (2 * (cyc) + 1) + (rows) * DDMA_ROW_PAD + DMA_XFER_PAD
    ENDM
    MACRO K_BXH name, bytes, rows, cyc
    OPD name, bytes, KBH_DOC, (bytes) * 2 * (cyc), (bytes) * (2 * (cyc) + 1) + (rows) * DDMA_ROW_PAD + DMA_XFER_PAD
    ENDM
    MACRO K_CC name, w, lines
    OPC name, (lines) * (w), LW_FIX + (lines) * (CC_LINE + CCR_FIX + ((w) / 32 + 2) * CCR_RUN + (w) * CCR_PX)
    ENDM
    MACRO K_CB name, w, lines, cyc
    OPD name, (lines) * (w), CB_FIX + (lines) * CB_ROW, (lines) * (w) * 2 * (cyc), (lines) * ((w) * (2 * (cyc) + 1 + DDMA_ROW_PAD) + DMA_XFER_PAD)
    ENDM
    MACRO K_FC name, piece
    OPC name, piece, FC_FIX + ((piece) + FILL_CHUNK - 1) / FILL_CHUNK * FC_CHUNK + 13 * (piece) + 13 * (((piece) + 15) / 16)
    ENDM
    MACRO K_FZ name, size
    OPD name, size, FZ_FIX + ((size) + FILL_CHUNK - 1) / FILL_CHUNK * FZ_CHUNK, 4 * (size), 5 * (size) + ((size) + FILL_CHUNK - 1) / FILL_CHUNK * DMA_XFER_PAD
    ENDM
    MACRO K_FB name, size, cyc
    OPD name, size, BLT_GO10_DOC, (size) * (cyc), (size) * ((cyc) + 1) + DMA_XFER_PAD
    ENDM
    MACRO K_SC name, rows
    OPC name, (rows) * SC_STRIDE, SW_FIX + (rows) * (SW_ROW + 21 * SC_STRIDE - 5)
    ENDM
    MACRO K_SZ name, rows
    OPD name, (rows) * SC_STRIDE, SW_FIX + (rows) * (SW_ROW + ND_ACT), (rows) * 4 * SC_STRIDE, (rows) * (5 * SC_STRIDE + DMA_XFER_PAD)
    ENDM
    MACRO K_SB name, rows, cyc
    OPD name, (rows) * SC_STRIDE, BLT_GO8_DOC, (rows) * SC_STRIDE * 2 * (cyc), (rows) * (SC_STRIDE * (2 * (cyc) + 1) + DDMA_ROW_PAD) + DMA_XFER_PAD
    ENDM
    MACRO K_VC name, len
    OPC name, len, VC_FIX + 16 * (len) + 10 * (((len) + 15) / 16)
    ENDM
    MACRO K_VZ name, len
    OPD name, len, VZ_FIX, 4 * (len), 5 * (len) + DMA_XFER_PAD
    ENDM
    MACRO K_LB name, len, cdoc, cyc
    OPD name, len, cdoc, 2 * (cyc) * (len), (2 * (cyc) + 1) * (len) + DMA_XFER_PAD
    ENDM

    K_LINE RC0, R0_W, R0_P, 21 * R0_W - 5
    K_LINE RC1, R1_W, R1_P, 21 * R1_W - 5
    K_LINE RC2, R2_W, R2_P, 21 * R2_W - 5
    K_LINE RC3, R3_W, R3_P, 21 * R3_W - 5
    K_LINE RC4, R4_W, R4_P, 21 * R4_W - 5
    K_LDMA RZ0, R0_W, R0_P
    K_LDMA RZ1, R1_W, R1_P
    K_LDMA RZ2, R2_W, R2_P
    K_LDMA RZ3, R3_W, R3_P
    K_LDMA RZ4, R4_W, R4_P
    K_BXY RB03, R0_W * R0_H, R0_H, 3
    K_BXY RB13, R1_W * R1_H, R1_H, 3
    K_BXY RB23, R2_W * R2_H, R2_H, 3
    K_BXY RB33, R3_W * R3_H, R3_H, 3
    K_BXY RB43, R4_W * R4_H, R4_H, 3
    K_BXY RB02, R0_W * R0_H, R0_H, 2
    K_BXY RB12, R1_W * R1_H, R1_H, 2
    K_BXY RB22, R2_W * R2_H, R2_H, 2
    K_BXY RB32, R3_W * R3_H, R3_H, 2
    K_BXY RB42, R4_W * R4_H, R4_H, 2

    K_LINE TC0, R0_W, R0_P, 21 * R0_W + 2
    K_LINE TC1, R1_W, R1_P, 21 * R1_W + 2
    K_LINE TC2, R2_W, R2_P, 21 * R2_W + 2
    K_LINE TC3, R3_W, R3_P, 21 * R3_W + 2
    K_LINE TC4, R4_W, R4_P, 21 * R4_W + 2
    K_BXY TB03, R0_W * R0_H, R0_H, 3
    K_BXY TB13, R1_W * R1_H, R1_H, 3
    K_BXY TB23, R2_W * R2_H, R2_H, 3
    K_BXY TB33, R3_W * R3_H, R3_H, 3
    K_BXY TB43, R4_W * R4_H, R4_H, 3
    K_BXY TB02, R0_W * R0_H, R0_H, 2
    K_BXY TB12, R1_W * R1_H, R1_H, 2
    K_BXY TB22, R2_W * R2_H, R2_H, 2
    K_BXY TB32, R3_W * R3_H, R3_H, 2
    K_BXY TB42, R4_W * R4_H, R4_H, 2

    K_CC CC0, C0_W, C0_P
    K_CC CC1, C1_W, C1_P
    K_CC CC2, C2_W, C2_P
    K_CC CC3, C3_W, C3_P
    K_CB CB03, C0_W, C0_P, 3
    K_CB CB13, C1_W, C1_P, 3
    K_CB CB23, C2_W, C2_P, 3
    K_CB CB33, C3_W, C3_P, 3
    K_CB CB02, C0_W, C0_P, 2
    K_CB CB12, C1_W, C1_P, 2
    K_CB CB22, C2_W, C2_P, 2
    K_CB CB32, C3_W, C3_P, 2

    K_LINE KC0, K0_H, K0_P, 21 * K0_H - 5
    K_LINE KC1, K1_H, K1_P, 21 * K1_H - 5
    K_LINE KC2, K2_H, K2_P, 21 * K2_H - 5
    K_LINE KC3, K3_H, K3_P, 21 * K3_H - 5
    K_LDMA KZ0, K0_H, K0_P
    K_LDMA KZ1, K1_H, K1_P
    K_LDMA KZ2, K2_H, K2_P
    K_LDMA KZ3, K3_H, K3_P
    K_BXY KB03, K0_W * K0_H, K0_W, 3
    K_BXY KB13, K1_W * K1_H, K1_W, 3
    K_BXY KB23, K2_W * K2_H, K2_W, 3
    K_BXH KB33, K3_W / 2 * K3_H, K3_W / 2, 3
    K_BXY KB02, K0_W * K0_H, K0_W, 2
    K_BXY KB12, K1_W * K1_H, K1_W, 2
    K_BXY KB22, K2_W * K2_H, K2_W, 2
    K_BXH KB32, K3_W / 2 * K3_H, K3_W / 2, 2

    K_FC FC0, F0_PC
    K_FC FC1, F1_PC
    K_FC FC2, F2_PC
    K_FC FC3, F3_PC
    K_FC FC4, F4_PC
    K_FZ FZ0, F0_S
    K_FZ FZ1, F1_S
    K_FZ FZ2, F2_S
    K_FZ FZ3, F3_S
    K_FZ FZ4, F4_S
    K_FB FB03, F0_S, 3
    K_FB FB13, F1_S, 3
    K_FB FB23, F2_S, 3
    K_FB FB33, F3_S, 3
    K_FB FB43, F4_S, 3
    K_FB FB02, F0_S, 2
    K_FB FB12, F1_S, 2
    K_FB FB22, F2_S, 2
    K_FB FB32, F3_S, 2
    K_FB FB42, F4_S, 2

    K_SC SC0, S0_P
    K_SC SC1, S1_P
    K_SZ SZ0, S0_H - 1
    K_SZ SZ1, S1_H - 1
    K_SB SB03, S0_H - 1, 3
    K_SB SB13, S1_H - 1, 3
    K_SB SB02, S0_H - 1, 2
    K_SB SB12, S1_H - 1, 2

    K_VC VC0, V0_L
    K_VC VC1, V1_L
    K_VC VC2, V2_L
    K_VC VC3, V3_L
    K_VC VC4, V4_L
    K_VC VC5, V5_L
    K_VC VC6, V6_L
    K_VC VC7, V7_L
    K_VZ VZ0, V0_L
    K_VZ VZ1, V1_L
    K_VZ VZ2, V2_L
    K_VZ VZ3, V3_L
    K_VZ VZ4, V4_L
    K_VZ VZ5, V5_L
    K_VZ VZ6, V6_L
    K_VZ VZ7, V7_L
    K_LB VB03, V0_L, BLT_GO10_DOC, 3
    K_LB VB13, V1_L, BLT_GO10_DOC, 3
    K_LB VB23, V2_L, BLT_GO10_DOC, 3
    K_LB VB33, V3_L, BLT_GO10_DOC, 3
    K_LB VB43, V4_L, BLT_GO10_DOC, 3
    K_LB VB53, V5_L, BLT_GO10_DOC, 3
    K_LB VB63, V6_L, BLT_GO10_DOC, 3
    K_LB VB73, V7_L, BLT_GO10_DOC, 3
    K_LB VB02, V0_L, BLT_GO10_DOC, 2
    K_LB VB12, V1_L, BLT_GO10_DOC, 2
    K_LB VB22, V2_L, BLT_GO10_DOC, 2
    K_LB VB32, V3_L, BLT_GO10_DOC, 2
    K_LB VB42, V4_L, BLT_GO10_DOC, 2
    K_LB VB52, V5_L, BLT_GO10_DOC, 2
    K_LB VB62, V6_L, BLT_GO10_DOC, 2
    K_LB VB72, V7_L, BLT_GO10_DOC, 2

    OPD UZ0, 1, UZ0_DOC, 4, 5 + DMA_XFER_PAD
    OPD UZ1, 1, UZ1_DOC, 4, 5 + DMA_XFER_PAD
    K_LB UB03, 1, BLT_GO22_DOC, 3
    K_LB UB02, 1, BLT_GO22_DOC, 2
    K_LB UB13, 1, BLT_GO8_DOC, 3
    K_LB UB12, 1, BLT_GO8_DOC, 2
