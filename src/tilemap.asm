; Tilemap 80x32 text-mode driver. One cell = glyph index + attribute.
; Text-mode attribute = pair number << 1 (palette offset in bits 7-1,
; bit 0 = ULA-over-tilemap, kept 0). The glyph pixel selects palette
; entry (offset << 1) | pixel, so pair k lives at entries 2k and 2k+1.

; Switch the display to tilemap text mode. Corrupts all registers.
txt_init:
    nextreg NR_TM_MAP_BASE, TM_MAP_MSB
    nextreg NR_TM_DEF_BASE, TM_DEFS_MSB
    call tm_pal_init
    call tm_font_init
    ld a, 7*2                   ; pair 7 = paper 0 ink 7
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, TM_ROWS
    ld e, TM_COLS
    ld a, GLYPH_SPACE
    call tm_fill_rect
    nextreg NR_ULA_CTRL, ULA_OFF
    nextreg NR_TM_CTRL, TM_CTRL_ON
    ret

; Program the 64 classic pairs: pair k = paper*8 + ink at entries
; 2k (paper RGB) and 2k+1 (ink RGB). Corrupts AF, BC, DE, HL.
tm_pal_init:
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 64
    ld c, 0                     ; pair number k
.pair:
    ld a, c
    rrca
    rrca
    rrca
    and 7                       ; paper = k >> 3
    call tm_colour
    nextreg NR_PAL_VALUE, a
    ld a, c
    and 7                       ; ink = k AND 7
    call tm_colour
    nextreg NR_PAL_VALUE, a
    inc c
    djnz .pair
    ret

; A = colour 0-7 -> A = RGB332. Preserves BC, DE, HL.
tm_colour:
    push hl
    push de
    ld e, a
    ld d, 0
    ld hl, tmColours
    add hl, de
    ld a, (hl)
    pop de
    pop hl
    ret

; Copy the embedded font to TM_DEFS, then try GAME.CHR from SD.
; A valid override is exactly 2048 bytes; anything else restores the
; embedded font and records the rejection. Corrupts all registers.
tm_font_init:
    call .embedded
    xor a
    ld (chrStatus), a
    call esx_getsetdrv
    ret c
    ld ix, chrName
    ld b, ESX_MODE_READ
    call esx_fopen
    ret c                       ; no GAME.CHR - embedded stays
    ld (chrHandle), a
    ld ix, TM_DEFS
    ld bc, 2048
    call esx_fread
    jr c, .bad
    ld a, b                     ; exactly 2048 read?
    cp 8
    jr nz, .bad
    ld a, c
    or a
    jr nz, .bad
    ld a, (chrHandle)           ; and no byte 2049 (size must be exact)
    ld ix, chrScratch
    ld bc, 1
    call esx_fread
    jr c, .bad
    ld a, b
    or c
    jr nz, .bad
    ld a, (chrHandle)
    call esx_fclose
    ld a, 1
    ld (chrStatus), a
    ret
.bad:
    ld a, (chrHandle)
    call esx_fclose
    ld a, 2
    ld (chrStatus), a
    jr .embedded                ; restore, then ret from .embedded
.embedded:
    ld hl, fontData
    ld de, TM_DEFS
    ld bc, 2048
    ldir
    ret

; B=row, C=col -> HL = TM_MAP + row*160 + col*2.
; Corrupts AF; preserves BC, DE.
tm_cell_addr:
    push de
    ld l, b
    ld h, 0
    add hl, hl                  ; row*2
    add hl, hl                  ; row*4
    add hl, hl                  ; row*8
    add hl, hl                  ; row*16
    add hl, hl                  ; row*32
    ld e, l
    ld d, h                     ; DE = row*32
    add hl, hl                  ; row*64
    add hl, hl                  ; row*128
    add hl, de                  ; row*160
    ld e, c
    ld d, 0
    add hl, de
    add hl, de                  ; + col*2
    ld de, TM_MAP
    add hl, de
    pop de
    ret

; B=row, C=col, A=glyph, E=attribute. Writes one cell.
; Corrupts AF, HL; preserves B, C, D, E.
tm_putc_at:
    push af
    call tm_cell_addr
    pop af
    ld (hl), a
    inc hl
    ld (hl), e
    ret

; B=top, C=left, D=height, E=width, A=glyph, attribute from tmAttr.
; Corrupts all registers.
tm_fill_rect:
    ld (tmFillGlyph), a
.rows:
    push bc
    push de
    call tm_cell_addr           ; HL = first cell of this row
    ld b, e                     ; B = width counter
    ld a, (tmFillGlyph)
    ld c, a
    ld a, (tmAttr)
    ld e, a
.cells:
    ld (hl), c
    inc hl
    ld (hl), e
    inc hl
    djnz .cells
    pop de
    pop bc
    inc b                       ; next row
    dec d
    jr nz, .rows
    ret

; B=top, C=left, D=height, E=width. Scrolls the rect up one row and
; blanks the freed bottom row (space + tmAttr). Height 1 just blanks.
; Corrupts all registers.
tm_scroll_rect:
    ld a, e
    ld (tmScrollW), a
    ld a, d
    dec a
    jr z, .blank
    ld (tmScrollH), a           ; rows to move = height-1
.move:
    push bc
    call tm_cell_addr
    ex de, hl                   ; DE = dest row start (row B)
    pop bc
    push bc
    inc b
    call tm_cell_addr           ; HL = source row start (row B+1)
    pop bc
    push bc
    ld a, (tmScrollW)
    add a, a                    ; width*2 bytes per row
    push bc
    ld c, a
    ld b, 0
    ldir
    pop bc
    pop bc
    inc b                       ; move the next row pair
    ld a, (tmScrollH)
    dec a
    ld (tmScrollH), a
    jr nz, .move
.blank:                         ; B = bottom row of the rect
    ld a, (tmScrollW)
    ld e, a
    ld d, 1
    ld a, GLYPH_SPACE
    jp tm_fill_rect

tmColours:                      ; classic Spectrum colours as RRRGGGBB
    db $00, $02, $A0, $A2, $14, $16, $B4, $B6

tmAttr:        db 7*2
tmFillGlyph:   db 0
tmScrollW:     db 0
tmScrollH:     db 0
chrName:       db "GAME.CHR", 0
chrHandle:     db $FF
chrScratch:    db 0
chrStatus:     db 0             ; 0 none, 1 override loaded, 2 rejected

fontData:
    INCBIN "font.chr"           ; 2048 bytes, path relative to src/
