; Tilemap 80x32 text-mode driver. One cell = glyph index + attribute.
; Text-mode attribute = pair number << 1 (palette offset in bits 7-1,
; bit 0 = ULA-over-tilemap, kept 0). The glyph pixel selects palette
; entry (offset << 1) | pixel, so pair k lives at entries 2k and 2k+1.
;
; 16-colour scheme (SP6): a pair encodes paper in bits 6-4 and ink in
; bits 3-0, i.e. pair = paper*16 + ink. That is 8 papers (0-7) x 16
; inks (0-15) = 128 pairs = all 256 tilemap palette entries. Ink gets
; the full DAAD 0-15 range (body text, coloured prompts); paper is
; limited to the 8 base colours by the tilemap's 128-pair ceiling, so
; win_attr masks paper to 0-7 (a paper 8-15 renders as its base hue).
; dadPalette holds the 16 DAAD colours; entry 2k = dadPalette[paper],
; entry 2k+1 = dadPalette[ink].

; Switch the display to tilemap text mode. Corrupts all registers.
txt_init:
    nextreg NR_TM_MAP_BASE, TM_MAP_MSB
    nextreg NR_TM_DEF_BASE, TM_DEFS_MSB
    call tm_palette_init
    call tm_font_init
    ld a, 7*2                   ; pair 7 = paper 0 ink 7 (white on black)
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

; Program all 128 pairs from dadPalette: pair k = paper*16 + ink, with
; paper = k >> 4 (0-7) at entry 2k and ink = k AND 15 (0-15) at entry
; 2k+1. Each palette entry is a 9-bit value (NR $44, two writes).
; Corrupts AF, BC, DE, HL.
tm_palette_init:
    nextreg NR_PAL_CTRL, PAL_TM_FIRST   ; tilemap first palette, auto-inc
    nextreg NR_PAL_INDEX, 0
    ld c, 0                     ; pair number k (0..127)
.pair:
    ld a, c
    swapnib
    and 15                      ; paper = k >> 4 (0-7)
    call tm_pal_write9          ; entry 2k = dadPalette[paper]
    ld a, c
    and 15                      ; ink = k AND 15 (0-15)
    call tm_pal_write9          ; entry 2k+1 = dadPalette[ink]
    inc c
    ld a, c
    cp 128
    jr nz, .pair
    ret

; A = dadPalette index 0-15 -> write its 9-bit entry (NR $44 twice).
; Corrupts AF; preserves BC, DE, HL.
tm_pal_write9:
    push hl
    push de
    add a, a                    ; *2 (two bytes per entry)
    ld e, a
    ld d, 0
    ld hl, dadPalette
    add hl, de
    ld a, (hl)                  ; byte 0 = RRRGGGBB
    nextreg NR_PAL_VALUE9, a
    inc hl
    ld a, (hl)                  ; byte 1 = blue LSB (bit 0)
    nextreg NR_PAL_VALUE9, a
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

; The 16 hardware text colours as Next 9-bit palette entries (2 bytes
; each: RRRGGGBB, then blue LSB in bit 0). These are the CLASSIC ZX
; Spectrum ULA colours - dim (0-7) and bright (8-15) - in ULA order.
; Provenance: the shipped Rabenstein Next release and the DAAD-Ready
; Next player (DSNEXTE3.BIN) both render text on the plain ULA (verified:
; neither programs a tilemap/ULANext palette, only Layer 2). There is NO
; custom hardware palette. DAAD INK/PAPER 0-15 index this table directly
; (current DRC output is the contract - it embeds the identity colour
; mapping, so INK 1 = hardware 1 = blue). ULA RGB levels: dim = 6/7,
; bright = 7/7 per channel.
dadPalette:
    db $00, $00                 ; 0  black
    db $03, $00                 ; 1  blue
    db $C0, $00                 ; 2  red
    db $C3, $00                 ; 3  magenta
    db $18, $00                 ; 4  green
    db $1B, $00                 ; 5  cyan
    db $D8, $00                 ; 6  yellow
    db $DB, $00                 ; 7  white
    db $00, $00                 ; 8  bright black = black
    db $03, $01                 ; 9  bright blue
    db $E0, $00                 ; 10 bright red
    db $E3, $01                 ; 11 bright magenta
    db $1C, $00                 ; 12 bright green
    db $1F, $01                 ; 13 bright cyan
    db $FC, $00                 ; 14 bright yellow
    db $FF, $01                 ; 15 bright white

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
