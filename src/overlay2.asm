; NextDAAD code overlay 2 (8K page 58 -> MMU slot 7 at $E000).
; Layer 2 bring-up: mode select, enable/disable, clear-to-transparent,
; palette load, and (DEBUG only) a hardware bring-up test card.
; Reached only via the engine dispatcher (cdisp page byte) or the
; DEBUG boot hook (debug.asm). Calls RESIDENT services only - never
; overlay0/overlay1.
;
; Register recipes below are cited against docs/zx-next-dev-guide-
; 2022-07-15/chapter-next-layer2.tex (section "Layer 2 Registers") and
; chapter-next-palette.tex, cross-checked against the guide's own
; samples/layer2-256x192 and samples/layer2-320x256 example code.

    MMU 7, OVL2_PAGE, OVL_ORG

; condition result helpers (CF contract, local to this overlay)
ovl2_true:
    or a
    ret
ovl2_false:
    scf
    ret

; --- mode / enable / disable ---

; A = 0 (256x192 256-colour) or 1 (320x256 256-colour) on entry.
; Programs the resolution (NR $70 bits 5-4, guide 728-744: 00 =
; 256x192, 01 = 320x256), the starting 16K bank (NR $12, guide
; 586-599: bits 6-0, 16K units) - both modes start at BANK_L2_FIRST
; (bank 9, "recommended to only use 16K banks 9 or greater", guide
; line 41) - and the Layer 2 clip window (NR $18, guide 650-669):
; without this the window is whatever CSpect/hardware left it at,
; which on a bare .nex boot is $00,$00,$00,$00 - a degenerate window
; that clips Layer 2 to nothing (the round-4/5 bring-up bug: enable,
; bank and pixel data were all correct, but a never-programmed clip
; window hid everything regardless). NR $1C bit 0 resets the Layer 2
; clip index (guide 679-687, "1 to reset Layer 2 clip-window register
; index"); each subsequent NR $18 write both sets the next coordinate
; AND auto-increments the index (guide 658), so the 4 writes below
; must land in X1,X2,Y1,Y2 order. X positions are guide-documented as
; doubled in 320x256 (guide 658: "X positions are doubled for 320x256
; mode"), matching the guide's own full-window table (line 660-669):
; 256x192 = 0,255,0,191; 320x256 = 0,159,0,255. Remembers the mode
; locally for l2_clear/l2_testcard. Corrupts AF.
l2_mode_set:
    ld (l2Mode), a
    or a
    jr z, .m256
    ld a, %00010000              ; NR $70: bits5-4=01 (320x256, 8bpp)
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_BANK, BANK_L2_FIRST
    nextreg NR_CLIP_IDX, 1        ; bit0: reset the Layer 2 clip index
    nextreg NR_L2_CLIP, 0         ; X1
    nextreg NR_L2_CLIP, 159       ; X2 (320x256: X in 2-pixel units)
    nextreg NR_L2_CLIP, 0         ; Y1
    nextreg NR_L2_CLIP, 255       ; Y2
    ret
.m256:
    xor a                        ; NR $70: bits5-4=00 (256x192, 8bpp)
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_BANK, BANK_L2_FIRST
    nextreg NR_CLIP_IDX, 1        ; bit0: reset the Layer 2 clip index
    nextreg NR_L2_CLIP, 0         ; X1
    nextreg NR_L2_CLIP, 255       ; X2
    nextreg NR_L2_CLIP, 0         ; Y1
    nextreg NR_L2_CLIP, 191       ; Y2
    ret

; Enable Layer 2 display via NR $69 bit 7 (guide 713-723: "1 to enable
; Layer 2 (alias for bit 1 in $123B)") and set the S/L/U layer
; priority (NR $15 bits 4-2, guide chapter-next-tilemap.tex 200-230)
; to "S U L" (010) so the tilemap - which rides the U slot, see
; chapter-next-tilemap.tex 96-104 - stays above Layer 2.
;
; Round 1 used the $123B I/O port directly (the guide's own worked
; example: LD BC,$123B / LD A,2 / OUT (C),A). That produced a screen-
; wide grey (the NR $4A all-layers-transparent fallback, per hardware
; guide/owner bring-up) with the tilemap correctly transparent and the
; testcard's pixel data correctly in place - i.e. Layer 2 was never
; actually visible despite the enable write. $123B is a combined
; write-organised port (bits 7-6 video-RAM bank select, bit 3 shadow
; select, bit 2/0 CPU paging) and a blind `LD A,2` also zeroes those
; other bits every time; NR $69 is the plain nextreg alias for the
; same enable flip-flop (bit 7) with no other live bits sharing the
; write, so this is the safer, simpler route - read-modify-write so
; bits 6-0 (ULA shadow / Timex video mode aliases, all 0 from
; hw_init and untouched anywhere else - grepped) are never disturbed.
; hw_init leaves NR $69 = 0 (Layer 2 off) and NR $15 = 0 ("S L U",
; Layer 2 over the tilemap, harmless while invisible) - both
; reprogrammed here explicitly rather than assumed.
;
; NR $15 = %010 ("S U L" in the guide's own naming, chapter-next-
; tilemap.tex line 213-218) is deliberate, NOT a typo for the guide's
; %000 ("S L U"): those two labels only share three letters by
; coincidence of naming. %000 is defined as "Sprites are at top,
; Layer 2 UNDER [sprites], [Enhanced] ULA at bottom" - i.e. Layer 2
; ABOVE the tilemap, the opposite of what's needed. The design spec
; (docs/superpowers/specs/2026-07-16-layer2-graphics-design.md line
; 87) says "Layer order stays SLU (tilemap over Layer 2)" - its own
; parenthetical defines what "SLU" means for this project: tilemap on
; top. Of the six non-blend encodings, only 010/011/100/101 put U
; ahead of L; %010 was chosen because it's the smallest single-bit-set
; change from hw_init's boot value (0) and leaves sprites (unused,
; invisible per hw_init) topmost same as the reset default. Corrupts
; AF, BC.
l2_enable:
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000                 ; bit7: enable Layer 2
    nextreg NR_DISPLAY_CTRL, a
    nextreg NR_LAYERS, %00001000 ; bits4-2=010: Sprites, Tilemap/ULA, Layer2
    ret

; Disable Layer 2 display (NR $69 bit 7 = 0, other bits preserved).
; Layer priority (NR $15) is left as l2_enable set it - harmless,
; since with Layer 2 invisible the S/L/U order has nothing to
; prioritise. Corrupts AF, BC.
l2_disable:
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a
    ret

; Fill the active surface (per the last l2_mode_set) with the current
; Layer 2/ULA/LoRes transparent index (NR $14, guide line 616-620).
; 256x192 = 6 x 8K pages (48K, guide 160); 320x256 = 10 x 8K pages
; (80K, guide 306), both starting at 8K page BANK_L2_FIRST*2 (guide
; line 599: "8K banks... multiply by 2"). A flat memset works
; regardless of the row-major/column-major addressing difference
; between the two modes, since every byte in the span gets the same
; value. Brackets the remap with data_save/data_restore so slot 6 is
; always left as the caller found it. Corrupts AF, BC, DE, HL.
l2_clear:
    call data_save
    ld e, NR_L2_TRANSP
    call nr_read
    ld (l2FillByte), a
    ld a, (l2Mode)
    or a
    jr nz, .m320
    ld a, 6
    jr .cnt
.m320:
    ld a, 10
.cnt:
    ld (l2PageCnt), a
    ld a, BANK_L2_FIRST*2
    ld (l2PageCur), a
.loop:
    ld a, (l2PageCur)
    call data_map_page
    ld hl, DATA_WINDOW
    ld a, (l2FillByte)
    ld (hl), a
    ld de, DATA_WINDOW+1
    ld bc, 8191
    ldir
    ld hl, l2PageCur
    inc (hl)
    ld hl, l2PageCnt
    dec (hl)
    jr nz, .loop
    call data_restore
    ret

; HL = source (resident or already-banked) palette data, B = format:
; 0 = 256 x 1-byte 8-bit RRRGGGBB entries (NR $41, guide 152-179);
; 1 = 256 x 2-byte 9-bit entries (NR $44, guide 236-284: first byte
; RRRGGGBB, second byte bit0 = extra blue bit / bit7 = L2 priority).
; Programs the Layer 2 FIRST palette (NR $43 = PAL_L2_FIRST selects it
; for edit and as the active display palette, auto-increment on,
; guide 203-230), index reset to 0 (NR $40 = 0). Corrupts AF, BC, HL.
l2_palette_load:
    ld a, b
    push af
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    pop af
    or a
    jr nz, .fmt9
    ld b, 0                      ; B=0 -> djnz runs 256 times
.l8:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE, a
    djnz .l8
    ret
.fmt9:
    ld b, 0
.l9:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    djnz .l9
    ret

l2Mode:     db 0                 ; last mode set by l2_mode_set
l2FillByte: db 0
l2PageCur:  db 0
l2PageCnt:  db 0

; --- DEBUG bring-up test card ---
; Owner-driven hardware verification hook, wired from debug.asm's
; l2_dbg_hook (holding T at boot, see that file for the key protocol).
; Not reached from anywhere else; safe to strip along with the rest
; of the IFDEF DEBUG block for a release build.

 IFDEF DEBUG

TC_MARK_COLOUR equ 255           ; distinct from the gradient's low end

; A = 0 (256x192) or 1 (320x256) on entry. Clears the tilemap over the
; card area to the reserved transparent attribute (resident
; tm_clear_transparent, tilemap.asm - the bottom row is left alone for
; debug.asm's status line), then selects the mode, enables Layer 2
; with the tilemap kept on top (l2_enable), clears the Layer 2 surface
; to transparent, paints an X-indexed gradient - relying on the Next's
; default identity Layer 2 palette (index N reads back as colour N
; out of reset, guide line "initialized with default values, so they
; are usable out of the box" - chapter-next-palette.tex line 18) so no
; palette load is needed for the bring-up check - then stamps a 4x4
; marker block at all four visual corners. Without the tilemap clear,
; every cell of the (opaque, white-on-black) boot text tilemap sits in
; front of Layer 2 and the card is invisible regardless of what's
; drawn to it - this was the Task 2 review finding that sent the card
; back for rework. Corrupts everything.
l2_testcard:
    push af
    ld b, 0
    ld c, 0
    ld d, TM_ROWS-2               ; card area only; bottom TWO rows are
    ld e, TM_COLS                 ; debug.asm's status lines, left opaque
    call tm_clear_transparent
    pop af
    push af
    call l2_mode_set
    call l2_enable
    call l2_clear
    pop af
    or a
    jr nz, .tc320
    call tc_gradient_256
    call tc_mark_256
    ret
.tc320:
    call tc_gradient_320
    call tc_mark_320
    ret

; Read back byte 0 of Layer 2 8K page BANK_L2_FIRST*2 (18, i.e. bank
; 9) - where both modes' top-left corner marker lands (tc_mark_256/
; tc_mark_320 both write TC_MARK_COLOUR there). Lets the boot hook
; distinguish "content never made it into the banks" (reads back the
; transparent fill byte or garbage) from "the banks are right but
; another layer is hiding them" (reads back TC_MARK_COLOUR, $FF, even
; though the screen doesn't show it) regardless of what the display
; shows. Out: A = the byte read. Corrupts AF only.
l2_peek_marker:
    call data_save
    ld a, BANK_L2_FIRST*2
    call data_map_page
    ld a, (DATA_WINDOW)
    push af
    call data_restore            ; corrupts A - stash the peeked byte first
    pop af
    ret

; 256x192: 6 x 8K pages, row-major (guide 162: "upper byte Y, lower
; byte X"), 32 rows/page of 256 bytes. Every row is filled with X
; (0..255), giving a horizontal rainbow repeated on all 192 lines.
; Corrupts AF, BC, DE, HL.
tc_gradient_256:
    call data_save
    ld a, BANK_L2_FIRST*2
    ld (l2PageCur), a
    ld b, 6
.page:
    push bc
    ld a, (l2PageCur)
    call data_map_page
    ld hl, DATA_WINDOW
    ld b, 32                     ; rows in this page
.row:
    push bc
    push hl
    ld c, 0
.px:
    ld a, c
    ld (hl), a
    inc hl
    inc c
    jr nz, .px
    pop hl
    ld de, 256
    add hl, de
    pop bc
    djnz .row
    pop bc
    ld hl, l2PageCur
    inc (hl)
    djnz .page
    call data_restore
    ret

; 320x256: 10 x 8K pages, column-major (guide 310: upper byte X, lower
; byte Y; 8K page holds 32 columns). Every column (D = $C0..$DF, the
; in-page column) is filled with a colour that increments once per
; column across the whole 320-wide sweep, giving a vertical rainbow
; repeated left to right (wraps once at column 256 - still clearly a
; gradient). Corrupts AF, BC, DE, HL.
tc_gradient_320:
    call data_save
    ld a, BANK_L2_FIRST*2
    ld (l2PageCur), a
    xor a
    ld (l2GradCol), a
    ld b, 10
.page:
    push bc
    ld a, (l2PageCur)
    call data_map_page
    ld d, $C0
    ld b, 32                     ; columns in this page
.col:
    push bc
    ld a, (l2GradCol)
    ld e, 0
.row:
    ld (de), a
    inc e
    jr nz, .row
    ld hl, l2GradCol
    inc (hl)
    inc d
    pop bc
    djnz .col
    pop bc
    ld hl, l2PageCur
    inc (hl)
    djnz .page
    call data_restore
    ret

l2GradCol: db 0

; A = 8K page, HL = base address within the page ($C000-based), C =
; marker colour. Stamps a 4x4 block: 4 groups of 4 contiguous bytes,
; 256 bytes apart. A square block is symmetric under an X/Y axis
; swap, so the same routine marks a corner correctly whether the
; caller's HL offset was built row-major or column-major - only the
; four (page, offset) call sites below know which is which. Corrupts
; AF, BC, DE, HL.
tc_mark:
    call data_map_page
    ld b, 4
.outer:
    push hl
    push bc
    ld b, 4
.inner:
    ld (hl), c
    inc hl
    djnz .inner
    pop bc
    pop hl
    ld de, 256
    add hl, de
    djnz .outer
    ret

; 256x192 corners (row-major: page = Y>>5, offset = (Y&31)*256 + X).
; TL (X0-3,Y0-3) and TR (X252-255,Y0-3) fall in page 0; BL (X0-3,
; Y188-191) and BR (X252-255,Y188-191) fall in page 5 (188>>5 = 5).
; Corrupts AF, BC, DE, HL.
tc_mark_256:
    call data_save
    ld a, BANK_L2_FIRST*2
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2
    ld hl, DATA_WINDOW+252               ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2+5
    ld hl, DATA_WINDOW+28*256            ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2+5
    ld hl, DATA_WINDOW+28*256+252        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

; 320x256 corners (column-major: page = X>>5, offset = (X&31)*256 + Y).
; TL (X0-3,Y0-3) and BL (X0-3,Y252-255) fall in page 0; TR (X316-319,
; Y0-3) and BR (X316-319,Y252-255) fall in page 9 (316>>5 = 9). Note
; the page split runs left/right here, not top/bottom as in the
; 256x192 case above - exactly the stride difference this card exists
; to catch. Corrupts AF, BC, DE, HL.
tc_mark_320:
    call data_save
    ld a, BANK_L2_FIRST*2
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2+9
    ld hl, DATA_WINDOW+28*256            ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2
    ld hl, DATA_WINDOW+252               ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2+9
    ld hl, DATA_WINDOW+28*256+252        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

 ENDIF

    ASSERT $ <= OVL_LIMIT
