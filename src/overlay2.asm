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
; 256x192, 01 = 320x256), the Layer 2 start bank (NR $12, guide
; 586-599: 16K units, BANK_L2_FIRST = bank 9, guide line 41 "only use
; 16K banks 9 or greater"), and the global transparent index (NR $14 =
; TM_TRANSP_ATTR): with Layer 2 on top (l2_enable) a pixel equal to
; this index falls through to the tilemap/ULA below, so the L2 recipe
; sets it itself. txt_init programs the same register/value for the
; tilemap - shared, harmless, last writer wins with an identical value.
; Then the clip window and scroll offset via l2_clip_set. Remembers the
; mode in l2Mode for l2_clear/l2_testcard. Corrupts AF.
l2_mode_set:
    ld (l2Mode), a
    push af
    or a
    jr z, .m256
    ld a, %00010000              ; NR $70: bits5-4=01 (320x256, 8bpp)
    jr .set
.m256:
    xor a                        ; NR $70: bits5-4=00 (256x192, 8bpp)
.set:
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_BANK, BANK_L2_FIRST
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    pop af
    jp l2_clip_set                ; also zeroes the scroll offset, then ret

; A = 0/1 as above. Programs the Layer 2 clip window (NR $1C index
; reset + 4x NR $18: X1,X2,Y1,Y2, guide 650-669) and zeroes the scroll
; offset (NR $16/$17, guide 623-639). Split from l2_mode_set so the
; DEBUG flow can re-assert the window after its diagnostic runs.
; Mirrors what it writes into l2ClipX1/X2/Y1/Y2 as a software shadow:
; NR $18 cannot be read back for a diagnostic - per wiki.specnext.dev/
; NextReg:$18 a WRITE auto-increments the index (guide 658) but a READ
; does not - so the shadow is the only reliable source of the window
; state. Corrupts AF.
l2_clip_set:
    ; X1/Y1 are always 0; X2/Y2 depend on the mode in A. Fill the shadow,
    ; then program the hardware from it - one shared write sequence.
    or a
    jr nz, .m320
    ld a, 255                     ; 256x192: X2 = 255
    ld (l2ClipX2), a
    ld a, 191                     ; Y2 = 191
    ld (l2ClipY2), a
    jr .prog
.m320:
    ld a, 159                     ; 320x256: X2 = 159 (X in 2-pixel units)
    ld (l2ClipX2), a
    ld a, 255                     ; Y2 = 255
    ld (l2ClipY2), a
.prog:
    xor a
    ld (l2ClipX1), a
    ld (l2ClipY1), a
    nextreg NR_CLIP_IDX, 1        ; bit0: reset the Layer 2 clip index
    nextreg NR_L2_CLIP, 0         ; X1
    ld a, (l2ClipX2)
    nextreg NR_L2_CLIP, a         ; X2
    nextreg NR_L2_CLIP, 0         ; Y1
    ld a, (l2ClipY2)
    nextreg NR_L2_CLIP, a         ; Y2
    ; NR $16/$17: X/Y pixel scroll offset (guide 623-639), zeroed so a
    ; stale offset can't shift/wrap the image.
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    ret

l2ClipX1: db 0
l2ClipX2: db 0
l2ClipY1: db 0
l2ClipY2: db 0

; Enable Layer 2 display (NR $69 bit 7, guide 713-723) via read-modify-
; write, so bits 6-0 (ULA shadow / Timex video-mode aliases, all 0 from
; hw_init) are left undisturbed. NR $69 is used rather than the $123B
; I/O port because a bare `LD A,2 / OUT ($123B)` also zeroes that port's
; other live bits (video-RAM bank select, shadow select, CPU paging)
; every write, which leaves Layer 2 invisible.
;
; Sets the S/L/U layer priority (NR $15 bits 4-2) to %000 - per wiki.
; specnext.dev/NextReg:$15 (matches the local guide verbatim), %000 is
; "S L U": Sprites top, Layer 2 under sprites, Enhanced ULA at bottom -
; i.e. Layer 2 ABOVE the tilemap/ULA slot. (%110/%111 are blend modes,
; unused.) Only correct together with l2_mode_set's NR $14 transparent
; fill: without it, Layer 2 on top would hide the tilemap text instead
; of letting it show through. Corrupts AF, BC.
l2_enable:
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000                 ; bit7: enable Layer 2
    nextreg NR_DISPLAY_CTRL, a
    nextreg NR_LAYERS, %00000000 ; bits4-2=000 "S L U": Layer 2 above
                                  ; the tilemap/ULA slot
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
; NR $14 transparent index (guide 616-620) - read back rather than
; assumed, though l2_mode_set always programs it to TM_TRANSP_ATTR
; first. With Layer 2 on top (l2_enable) a pixel at this index lets the
; tilemap/ULA below show through. 256x192 = 6 x 8K pages, 320x256 = 10 x
; 8K pages (guide 160/306), both from 8K page BANK_L2_FIRST*2 (guide
; 599). A flat memset works for both regardless of the row-/column-major
; layout, since every byte gets the same value. Brackets the remap with
; data_save/data_restore so slot 6 is left as the caller found it.
; Corrupts AF, BC, DE, HL.
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
; card area to the reserved transparent attribute (tm_clear_transparent,
; tilemap.asm; the bottom TWO rows are left for debug.asm's status
; lines), then delegates to l2_bareprobe_draw for the L2 recipe + draw.
; Uses the Next's default identity Layer 2 palette (index N = colour N
; out of reset, chapter-next-palette.tex line 18) so no palette load is
; needed. The card-area clear and the 320-mode 240-line bound (see
; tc_gradient_320) keep Layer 2 transparent wherever the tilemap has
; real content, so text and picture coexist with the picture on top.
; Corrupts everything.
l2_testcard:
    push af
    ld b, 0
    ld c, 0
    ld d, TM_ROWS-2               ; card area only; bottom TWO rows are
    ld e, TM_COLS                 ; debug.asm's status lines, left opaque
    call tm_clear_transparent
    pop af
    jp l2_bareprobe_draw

; A = 0/1 as above. The L2 recipe (mode_set incl. clip+scroll, enable
; incl. priority, clear-to-transparent) plus the gradient + corner-
; marker draw - l2_testcard's guts MINUS the tilemap-transparent clear.
; Split out for the bare-metal isolation ladder (debug.asm's
; l2_bareprobe_hook): its stages 0-1 have no tilemap yet, so they call
; this directly instead of l2_testcard. Corrupts everything.
l2_bareprobe_draw:
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

; A = ladder stage (0-3). Draws (stage+1) filled 16x16-pixel blocks,
; TC_MARK_COLOUR, side by side (20px stride) in the top-left corner -
; the only way to show the stage number when stages 0-1 of the ladder
; have no tilemap. Works in both modes: a square block near the origin
; fits inside 8K page BANK_L2_FIRST*2 whether the surface is row- or
; column-major (see tc_mark). Corrupts everything.
l2_bareprobe_marker:
    inc a                        ; stage -> block count (1-4)
    ld (l2BpBlockCnt), a
    call data_save
    ld a, BANK_L2_FIRST*2
    call data_map_page
    ld hl, DATA_WINDOW
.block:
    push hl
    ld a, 16
    ld (l2BpRowCnt), a
.row:
    push hl
    ld b, 16
.px:
    ld (hl), TC_MARK_COLOUR
    inc hl
    djnz .px
    pop hl
    ld de, 256
    add hl, de
    ld a, (l2BpRowCnt)
    dec a
    ld (l2BpRowCnt), a
    jr nz, .row
    pop hl
    ld de, 20
    add hl, de
    ld a, (l2BpBlockCnt)
    dec a
    ld (l2BpBlockCnt), a
    jr nz, .block
    call data_restore
    ret

l2BpBlockCnt: db 0
l2BpRowCnt:   db 0

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
; gradient). Only fills Y 0-239 (240 lines) per column, NOT the full
; 256: with Layer 2 on top (l2_enable), the bottom 16 lines - where
; debug.asm's two status rows sit (TM_ROWS-2..TM_ROWS-1, 8px/row) - are
; left at l2_clear's transparent fill so the text shows through instead
; of being covered by opaque gradient. Corrupts AF, BC, DE, HL.
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
    ld b, 240                    ; Y 0-239 only - see header comment
.row:
    ld (de), a
    inc e
    djnz .row
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
; TL (X0-3,Y0-3) and BL (X0-3,Y236-239) fall in page 0; TR (X316-319,
; Y0-3) and BR (X316-319,Y236-239) fall in page 9 (316>>5 = 9). Note
; the page split runs left/right here, not top/bottom as in the
; 256x192 case above - exactly the stride difference this card exists
; to catch. BL/BR sit at Y236-239, not Y252-255 - the bottom of the
; 240-line drawable area (see tc_gradient_320's header comment), i.e.
; "bottom corner of the card", not "bottom of the physical screen"
; (Y240-255 there is reserved for the tilemap status rows showing
; through). Corrupts AF, BC, DE, HL.
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
    ld hl, DATA_WINDOW+236               ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, BANK_L2_FIRST*2+9
    ld hl, DATA_WINDOW+28*256+236        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

 ENDIF

    ASSERT $ <= OVL_LIMIT
