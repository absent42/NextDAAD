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
;
; Text-mode transparency (chapter-next-tilemap.tex line 357) is NOT
; the normal tilemap mode's NR $4C - it's checked against NR $14
; (NR_L2_TRANSP), the SAME register Layer 2/ULA/LoRes use. Since the
; 128-pair scheme above already covers all 256 tilemap palette entries
; with real paper/ink combinations, one combo - pair 127 (paper 7,
; ink 15, "bright white on white": unreadable anyway, so losing it as
; an opaque option costs nothing in practice) - is reserved as the
; transparent marker (see TM_TRANSP_PAIR/TM_TRANSP_ATTR, nextdaad.inc).
; txt_init programs NR $14 with L2_TRANSP_COLOUR - Layer 2's transparent
; colour, Layer 2's business, not a tilemap attribute. tm_clear_blank
; below writes TM_ATTR_DEFAULT with GLYPH_SPACE, so a blanked cell
; renders as ordinary black paper, the same as a printed one.
; A custom FONT.CHR (font_load, overlay2.asm - the only supported custom-
; font route as of SP12 T1; the legacy GAME.CHR probe this comment used
; to name has been retired) that redefines glyph 32 with non-zero pixels
; would reintroduce ink-coloured specks in "transparent" cells - out of
; scope here, flagged for whoever wires up Task 4's picture display.

; Switch the display to tilemap text mode. Corrupts all registers.
txt_init:
    nextreg NR_TM_MAP_BASE, TM_MAP_MSB
    nextreg NR_TM_DEF_BASE, TM_DEFS_MSB
    call tm_palette_init
    call tm_font_init
    ld a, TM_ATTR_DEFAULT        ; pair 7 = paper 0 ink 7 (white on black)
    ld (tmAttr), a
    ld bc, 0                    ; SP14c batch B TM3
    ld d, TM_ROWS
    ld e, TM_COLS
    ld a, GLYPH_SPACE
    call tm_fill_rect
    nextreg NR_ULA_CTRL, ULA_OFF
    nextreg NR_L2_TRANSP, L2_TRANSP_COLOUR  ; shared register; Layer 2 is
                                 ; its real owner (overlay2's l2_mode_set
                                 ; sets the same value). Written here too
                                 ; so it is correct before Layer 2 comes
                                 ; up - though $E3 is also the hardware
                                 ; reset value, so this is belt and braces.
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

; Copy the embedded font to TM_DEFS. SP12 T1 rider: the GAME.CHR disk
; probe that used to run here (open/read/validate a root-only override,
; esxDOS-dependent) has been retired - it was an undocumented mechanism
; nobody remembered, never wired into any docs, and is now superseded by
; the owner-unified FONT.CHR path (font_load, overlay2.asm), which loads
; later, is PARTn-aware, and is the only supported custom-font route
; going forward. chrStatus is still zeroed here (kept 0, never set
; non-zero again) so debug.asm's dbg_engage_tilemap - which still reads
; it and is out of scope for this file-only change - stays silent
; instead of showing a stale CHR OVERRIDE/CHR BAD banner. Both callers'
; contracts are preserved: main.asm's boot call and errors.asm's fatal()
; re-arm (file.asm ~154, txt_init's embedded-font fallback needs no DDB/
; SD state) both just need TM_DEFS filled unconditionally on return -
; this is now even more robust than before, since there is no longer any
; esxDOS dependency at all on this path. Corrupts all registers.
tm_font_init:
    xor a
    ld (chrStatus), a
    ld hl, fontData
    ld de, TM_DEFS
    ld bc, 2048
    ldir
    ret

; B=row, C=col -> HL = TM_MAP + row*160 + col*2.
; Corrupts AF; preserves BC, DE.
; SP14c batch B TM1: row*160 via Z80N MUL D,E (row max TM_ROWS-1=31,
; product max 4960, well inside MUL D,E's always-safe 65025 ceiling);
; the TM_MAP base-add folds to a bundled ADD HL,nn too (byte-neutral).
tm_cell_addr:
    push de
    ld e, b                     ; row (0..31)
    ld d, 160
    mul d, e                    ; DE = row*160
    ex de, hl                    ; HL = row*160
    ld e, c
    ld d, 0
    add hl, de
    add hl, de                  ; + col*2
    add hl, TM_MAP
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

; B=top, C=left, D=height, E=width. Blank the rect: GLYPH_SPACE at the
; ORDINARY default attribute, so an untouched cell renders exactly like
; a printed one - black paper.
;
; This was tm_clear_transparent and it never made anything transparent.
; It wrote pair 127, whose paper is dadPalette[7], so it painted opaque
; DAAD white; the 2026-08-06 green probe showed that white at boot, in
; the parser and around the test card. Nothing needs tilemap
; transparency: Layer 2 sits ABOVE the tilemap (NR $15 = %000, "S L U")
; and punches DOWN to reveal text, so a transparent tilemap cell would
; only expose the ULA, which this interpreter never draws.
;
; Leaves tmAttr at the default - harmless, every print path sets its
; own. Corrupts all registers.
tm_clear_blank:
    ld a, TM_ATTR_DEFAULT
    ld (tmAttr), a
    ld a, GLYPH_SPACE
    jp tm_fill_rect

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
; SP14c batch B TM2: chrHandle/chrScratch removed - dead (batch A's
; M1 removed the last write, main.asm; zero readers anywhere in the
; tree, confirmed by grep before removal).
chrStatus:     db 0             ; 0 none, 1 override loaded, 2 rejected

 IFNDEF DEBUG
; SP14c batch B accounting note: TM1+TM2+TM3's combined -10 bytes
; landed this module's pre-flags code exactly ON the ALIGN(256)
; boundary from below in the RELEASE variant only (measured via the
; map-address technique: CDISP+384 dropped from 0xA10A to exactly
; 0xA100, so `flags` snapped from 0xA200 to 0xA100 instead of staying
; put - Release's pre-flags slack at this boundary was only 10 bytes,
; far tighter than DEBUG's 158+). This 10-byte pad restores Release's
; original margin so `flags` stays at 0xA200 (the hard constraint) -
; DEBUG is unaffected (its own ALIGN slack absorbed the same -10
; bytes with over a hundred bytes to spare) and keeps the full
; tracked-headroom benefit of TM1-3. Costs nothing meaningful here
; (Release headroom is >3700 bytes) - if a future Release-side
; pre-flags reduction elsewhere changes this margin, re-measure and
; adjust/remove this pad rather than assuming it still applies.
    ds 10
 ENDIF

fontData:
    INCBIN "font.chr"           ; 2048 bytes, path relative to src/
