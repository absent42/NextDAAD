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
; 586-599: 16K units, guide line 41 "only use 16K banks 9 or
; greater") from l2FrontBank - the double-buffer flip (l2_flip_swap)
; swaps the surface roles FIRST and then calls here, so the
; resolution and the new front bank land back-to-back (see
; l2_flip_swap's header for the glitch-window math) - and the global
; transparent colour (NR $14 = TM_TRANSP_ATTR): with Layer 2 on top
; (l2_enable) a pixel whose palette output equals this colour falls
; through to the tilemap/ULA below, so the L2 recipe sets it itself.
; txt_init programs the same register/value for the tilemap - shared,
; harmless, last writer wins with an identical value. Then the clip
; window and scroll offset via l2_clip_set. Remembers the mode in
; l2Mode for l2_clear/l2_testcard. Corrupts AF.
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
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
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

; Fill a Layer 2 surface with the current NR $14 transparent colour
; (guide 616-620) - read back rather than assumed, though l2_mode_set
; always programs it to TM_TRANSP_ATTR first. With Layer 2 on top
; (l2_enable) a pixel whose palette output equals that colour lets the
; tilemap/ULA below show through. Page count per l2Mode: 256x192 = 6 x
; 8K pages, 320x256 = 10 x 8K pages (guide 160/306). A flat memset
; works for both regardless of the row-/column-major layout, since
; every byte gets the same value. Brackets the remap with data_save/
; data_restore so slot 6 is left as the caller found it. Three entry
; points - all corrupt AF, BC, DE, HL:
;   l2_clear      - the FRONT (displayed) surface: DEBUG diagnostics,
;                   which have no flip step;
;   l2_clear_back - the BACK (render target) surface: gfx_blit's
;                   pre-clear and h_display's instant clear, both
;                   invisible until the flip;
;   l2_clear_at   - A = first 8K page of any surface (internal).
l2_clear:
    ld a, (l2FrontBank)
    add a, a
    jr l2_clear_at
l2_clear_back:
    ld a, (l2BackBank)
    add a, a
l2_clear_at:
    ld (l2PageCur), a
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
;
; Transparency invariant: NR $14 transparency is a COLOUR compare, not
; an index compare - the hardware matches each Layer 2 pixel's final
; RRRGGGBB palette output against the register (wiki.specnext.dev/
; NextReg:$14 "Global Transparency", and guide chapter-next-layer2.tex
; line 71 "transparent colour of Layer 2"; the guide's register table
; at line 619 says "index", but the owner's milestone run proved the
; colour reading: all 21 Rabenstein NX2 palettes map entry 254 to
; black, and the $FE surface fill rendered opaque black over the text
; rows). So a loaded palette must reserve one colour for punch-through:
; - copy loops dodge collisions: any entry whose FIRST byte equals
;   TM_TRANSP_ATTR ($FE) is written as $FF instead - one blue LSB off,
;   imperceptible; only the RRRGGGBB byte is compared, so dodging it
;   suffices (the 9-bit second byte passes through as supplied). Art
;   scan: 3/12/13.NX2 each carry one $FE-coloured entry that would
;   otherwise punch unintended holes;
; - entry 254 is then stamped $FE via the 9-bit pair (NR $44 = $FE,
;   then 0: blue LSB 0, priority 0 - chosen over an NR $41 write so
;   the priority bit is explicitly cleared), making index 254 the ONLY
;   transparent entry after ANY l2_palette_load. No Rabenstein art
;   uses pixel value $FE, so reserving the index costs nothing; the
;   DEBUG test card's identity palette already satisfied the invariant.
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
    cp TM_TRANSP_ATTR            ; colour collision with the reserved
    jr nz, .w8                   ; transparent colour: dodge to $FF
    ld a, $FF
.w8:
    nextreg NR_PAL_VALUE, a
    djnz .l8
    jr .stamp
.fmt9:
    ld b, 0
.l9:
    ld a, (hl)
    inc hl
    cp TM_TRANSP_ATTR            ; dodge the RRRGGGBB byte only - the
    jr nz, .w9                   ; compare ignores the second byte
    ld a, $FF
.w9:
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    djnz .l9
.stamp:
    ; force entry 254 = the reserved transparent colour (see header)
    nextreg NR_PAL_INDEX, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, 0     ; blue LSB 0, priority 0
    ret

l2Mode:     db 0                 ; last mode set by l2_mode_set
l2FillByte: db 0
l2PageCur:  db 0
l2PageCnt:  db 0

; --- picture loader / blitter / PICTURE / DISPLAY (Task 4) ---
; File format (Gfx2Next -pal-embed): 512-byte palette (256 x 2-byte
; 9-bit entries, NR $44 order) followed by width*height pixel bytes,
; emitted row by row. NNN.NX2 = 320 wide, NNN.NXI = 256 wide; the
; height is whatever the file size says: (size - 512) / width.

GFX_SRC_END equ DATA_WINDOW+$2000   ; first address past the slot 6 window

; 84 PICTURE (condition): stage picture B for a later DISPLAY 0.
; Semantics pinned against jdaad _PICTURE (jdaad.js 3505-3529): it
; stages only - "imageBufferID = Parameter1" on success, nothing is
; drawn; a missing image clears the stage ("imageBufferID = false")
; and fails the condition (condactResult = false). CF mirrors
; condactResult through ovl2_false. jdaad's fallback probe of
; jDAADSounds is not carried over - sampled SFX are a separate
; subsystem here. Corrupts everything.
h_picture:
    ld a, b
    call gfx_load
    jp c, ovl2_false
    jp ovl2_true

; Swap the front/back Layer 2 surface roles - VARIABLES ONLY, no
; hardware write. The caller owns the NR $12 update: gfx_blit swaps
; and then calls l2_mode_set, so the resolution (NR $70) and the new
; front bank (NR $12) land back-to-back - two nextreg writes one
; register load apart, ~40 T-states = ~1.4us at 28MHz, so the worst
; case is the raster catching a sub-scanline sliver of the old
; surface in the new mode (one scanline is 64us), versus a full frame
; of wrong-mode flash if either register changed alone with the other
; waiting a frame; h_display's clear path writes NR $12
; directly (no mode change, no window at all). Corrupts AF, B.
l2_flip_swap:
    ld a, (l2FrontBank)
    ld b, a
    ld a, (l2BackBank)
    ld (l2FrontBank), a
    ld a, b
    ld (l2BackBank), a
    ret

; 28 DISPLAY (action): B = 0 draws the staged picture, B != 0 clears
; the picture plane. Semantics pinned against jdaad _DISPLAY
; (jdaad.js 2750-2754): jdaad IGNORES its argument entirely - it
; always draws the staged imageBufferID, and silently no-ops when
; nothing is staged ("if (imageBufferID === false) return;"). The
; DAAD reference (condacts table, row 28) is what gives the argument
; meaning: "If 0: show buffered picture. If non-0: clear window
; area". Pinned here: B = 0 follows both (blit the stage, no-op when
; empty, per the jdaad line above); B != 0 follows the DAAD
; reference, with "window area" read as the picture plane - the
; Layer 2 surface is cleared to the transparent colour so the tilemap
; text underneath shows through. (The old overlay0 stub's text-window
; CLS for non-zero was wrong on this architecture: pictures never
; occupy the text plane, so DISPLAY must never destroy text.)
; The clear goes through the BACK surface + flip rather than clearing
; the front in place: one NR $12 write makes it instantaneous, where
; a front clear would wipe 48-80K through the visible surface -
; exactly the progressive-paint artifact double buffering exists to
; kill. Mode, clip and palette are left as they stand. Corrupts
; everything.
h_display:
    ld a, b
    or a
    jp z, gfx_blit
    call l2_clear_back
    call l2_flip_swap
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    ret

; A = picture number. Ensure its palette+pixels are in cache banks
; and stage it for DISPLAY 0. Cache hit: cache_touch + stage, no SD
; access. Miss: reserve a cache slot, probe the extension chain
; (gfxExtTab order - Task 5 prepends its ZX0-compressed probes there),
; stream the file into freshly allocated 16K banks with count-checked
; reads, derive the height from the byte total, then commit the entry
; and stage it. Out: CF clear = staged. CF set = failed (no file, no
; free slot/bank/arena room, malformed size): every partially
; allocated bank is freed, the arena cursor rewound, and the stage
; cleared - jdaad unstages on a failed PICTURE too. Eviction when the
; pool is full is Task 6; this task fails such loads cleanly instead.
; Corrupts everything.
gfx_load:
    ld (gfxPicNum), a
    cp GFX_EMPTY                ; 255 = the empty-slot sentinel; passing it
    jr z, .failclean            ; to cache_find would false-match every
                                ; unused slot, so it is simply unloadable
    call cache_find
    jr c, .miss
    ld (gfxEntryIdx), a         ; hit: A = entry index
    call cache_touch
    jr .stage
.miss:
    call gfx_find_empty         ; reserve a slot; not written until the
    jr c, .failclean            ; load has fully verified
    ld (gfxEntryIdx), a
    call gfx_open_chain
    jr c, .failclean
    call gfx_read_banks         ; closes the file on every path
    jr c, .failbanks
    call gfx_derive_height
    jr c, .failbanks
    ; everything verified: commit the cache entry
    ld a, (gfxEntryIdx)
    call gce_ptr
    ld a, (gfxPicNum)
    ld (hl), a                  ; GCE_PIC
    inc hl
    ld a, (gfxArenaStart)
    ld (hl), a                  ; GCE_FIRST
    inc hl
    ld a, (gfxBankCount)
    ld (hl), a                  ; GCE_COUNT
    inc hl
    ld a, (gfxMode)
    ld (hl), a                  ; GCE_MODE
    inc hl
    ld a, (gfxHeight)
    ld (hl), a                  ; GCE_HEIGHT (0 encodes 256)
    ld a, (gfxEntryIdx)
    call cache_touch
.stage:
    ld a, (gfxEntryIdx)
    call gce_ptr
    ld bc, GCE_MODE
    add hl, bc
    ld a, (hl)
    ld (stagedMode), a
    inc hl
    ld a, (hl)                  ; GCE_HEIGHT
    ld (stagedHeight), a
    ld a, (gfxPicNum)
    ld (stagedPic), a
    ld a, (gfxEntryIdx)
    ld (stagedEntry), a
    or a
    ret
.failbanks:
    call gfx_load_rollback
.failclean:
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    scf
    ret

; Find the first empty cache slot. Out: CF clear + A = entry index;
; CF set when every slot is in use (eviction is Task 6). Corrupts
; AF, B, DE, HL.
gfx_find_empty:
    ld hl, gfxCache
    ld de, GFX_ENTRY_SIZE
    ld b, 0
.scan:
    ld a, (hl)
    cp GFX_EMPTY
    jr z, .got
    add hl, de
    inc b
    ld a, b
    cp GFX_CACHE_MAX
    jr c, .scan
    scf
    ret
.got:
    ld a, b
    or a
    ret

; Build gfxName's "NNN" digits from gfxPicNum (3-digit zero-padded
; decimal, the project's repeated-subtraction decade idiom - see
; prn_dec_digit, print.asm), then probe the extension chain: each
; gfxExtTab row is tried with esx_fopen until one opens. Out: CF
; clear with the handle in gfxHandle and gfxMode/gfxWidth set from
; the matching row; CF set when no candidate exists on SD. Corrupts
; everything.
gfx_open_chain:
    ld a, (gfxPicNum)
    ld hl, gfxName
    ld b, '0'-1
.hund:
    inc b
    sub 100
    jr nc, .hund
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.tens:
    inc b
    sub 10
    jr nc, .tens
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    ld hl, gfxExtTab
.row:
    ld (gfxExtPtr), hl
    ld de, gfxName+4            ; past "NNN."
    ldi                         ; 3 extension characters
    ldi
    ldi
    ld a, (hl)                  ; row's mode byte
    ld (gfxMode), a
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    call esx_getsetdrv          ; A = default drive for esx_fopen
    jr c, .next
    ld ix, gfxName
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.next:
    ld hl, (gfxExtPtr)
    ld de, GFX_EXT_ROW
    add hl, de
    push hl
    ld de, gfxExtEnd
    or a
    sbc hl, de
    pop hl
    jr nz, .row
    scf                         ; chain exhausted
    ret
.opened:
    ld (gfxHandle), a
    or a
    ret

; Stream the open gfxHandle file into freshly allocated 16K cache
; banks through slot 6, 8K per esx_fread. Every read is count-checked
; against BC-out (esxDOS clears CF on a short/EOF read; only a real
; error sets CF), a short read being EOF. Bank numbers are appended
; to gfxBankList at gfxBankNext. The file is CLOSED on every path.
; Out: CF clear with gfxArenaStart/gfxBankCount/gfxSize* filled
; (an EOF landing exactly on a bank boundary can leave one appended
; bank empty - harmless, the blitter only reads height*width bytes);
; CF set on error or oversize, allocated banks NOT yet freed - the
; caller's rollback owns that, the arena cursor still covers them.
; Brackets slot 6 with data_save/data_restore. Corrupts everything.
gfx_read_banks:
    call data_save
    ld a, (gfxBankNext)
    ld (gfxArenaStart), a
    xor a
    ld (gfxBankCount), a
    ld (gfxSizeHi), a
    ld hl, 0
    ld (gfxSizeLo), hl
.bank:
    ; the largest acceptable file, a 320x256 NX2 (512 + 81920 =
    ; 82432 bytes), fits in 6 banks; needing a 7th means this is not
    ; a picture this interpreter accepts
    ld a, (gfxBankCount)
    cp 6
    jr nc, .fail
    ld a, (gfxBankNext)
    cp GFX_BANKLIST_MAX
    jr nc, .fail                ; bank-list arena full
    call bank_alloc             ; out: A = 16K bank, CF = none free
    jr c, .fail
    ld e, a
    ld hl, gfxBankList
    ld a, (gfxBankNext)
    add hl, a
    ld (hl), e                  ; append the bank
    inc a
    ld (gfxBankNext), a
    ld hl, gfxBankCount
    inc (hl)
    ld a, e
    add a, a                    ; lower 8K page of the bank
    ld (gfxCurPage), a
    call gfx_read_page
    jr c, .fail
    jr nz, .eof                 ; short read = end of file
    ld hl, gfxCurPage
    inc (hl)                    ; upper 8K page
    ld a, (hl)
    call gfx_read_page
    jr c, .fail
    jr nz, .eof
    jr .bank
.eof:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call data_restore
    or a
    ret
.fail:
    ld a, (gfxHandle)
    cp $FF
    jr z, .noclose
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.noclose:
    call data_restore
    scf
    ret

; A = 8K page: map it into slot 6 and esx_fread up to $2000 bytes
; into the window, accumulating the actual count into the 24-bit
; gfxSizeHi:gfxSizeLo. Out: CF set = esxDOS error; else ZF clear =
; short read (EOF), ZF set = full page read. Corrupts everything
; (esxDOS makes no register promises); the caller keeps its own
; state in memory.
gfx_read_page:
    call data_map_page
    ld a, (gfxHandle)
    ld ix, DATA_WINDOW
    ld bc, $2000
    call esx_fread              ; out: BC = ACTUAL bytes read
    ret c
    ld hl, (gfxSizeLo)
    add hl, bc
    ld (gfxSizeLo), hl
    jr nc, .nocarry
    ld hl, gfxSizeHi
    inc (hl)
.nocarry:
    ld hl, $2000
    or a
    sbc hl, bc                  ; ZF = full read (CF impossible, BC <= $2000)
    ret

; Derive the pixel-row count: rows = (24-bit total - 512) / gfxWidth
; by repeated subtraction (at most 256 rounds - the tallest legal
; picture is one full 256-row surface). Out: CF clear + gfxHeight
; (0 encodes 256 rows, the GCE_HEIGHT convention); CF set when the
; size is malformed - shorter than the palette, zero rows, a partial
; trailing row, or taller than the mode's surface (192 rows in
; 256-wide mode, 256 rows in 320-wide mode). Corrupts everything.
gfx_derive_height:
    ld hl, (gfxSizeLo)
    ld de, 512
    or a
    sbc hl, de
    ld a, (gfxSizeHi)
    sbc a, 0
    jr c, .bad                  ; shorter than the palette
    ld c, a                     ; C:HL = pixel byte count
    or h
    or l
    jr z, .bad                  ; no pixel data at all
    ld de, (gfxWidth)
    ld b, 0                     ; completed rows, mod 256
.row:
    and a                       ; clear CF (A holds scan junk)
    sbc hl, de
    jr nc, .noborrow
    dec c
.noborrow:
    ld a, c                     ; C legitimately reaches at most 1
    inc a                       ; ($14000 = 320*256 pixels), so $FF can
    jr z, .bad                  ; only mean a partial trailing row
    inc b
    ld a, h
    or l
    or c
    jr z, .done
    ld a, b
    or a
    jr nz, .row
    jr .bad                     ; 256 rows consumed, bytes remain
.done:
    ld a, (gfxMode)
    or a
    jr nz, .m320                ; 320-wide surface: any row count fits
    ld a, b                     ; 256-wide surface holds 192 rows
    or a
    jr z, .bad                  ; B = 0 encodes 256 rows
    cp 193
    jr nc, .bad
.m320:
    ld a, b
    ld (gfxHeight), a
    or a
    ret
.bad:
    scf
    ret

; Free the banks a failed load appended (arena indices gfxArenaStart
; .. gfxBankNext-1) and rewind the arena cursor. The reserved cache
; slot was never written, so it is still empty - nothing else to
; drop. Corrupts AF, B, HL.
gfx_load_rollback:
    ld a, (gfxBankNext)
    ld hl, gfxArenaStart
    sub (hl)
    ld b, a                     ; banks to free
    ld a, (hl)
    ld (gfxBankNext), a         ; rewind
    ld hl, gfxBankList
    add hl, a
    ld a, b
    or a
    ret z
.free:
    ld a, (hl)
    call bank_free              ; preserves BC, DE, HL (banks.asm)
    inc hl
    djnz .free
    ret

; Draw the staged cache entry, double-buffered: everything renders to
; the BACK surface (invisible - the old picture stays intact on the
; front throughout), then the surfaces flip. Sequence: stage the mode
; in l2Mode (variable only - the hardware keeps displaying the old
; picture in the old mode), clear the back surface to the transparent
; colour (also pre-clears the remainder below a short picture to
; $FE), copy the pixel rows top-aligned, load the file's embedded
; 512-byte 9-bit palette (deliberately LAST before the flip: the
; palette is global, so the old picture wears the new colours only
; for the ~1ms the load takes instead of the whole render), then
; l2_flip_swap + l2_mode_set - resolution and new front bank land
; back-to-back, no wrong-mode flash (see l2_flip_swap) - and
; l2_enable. No-op when nothing is staged. Corrupts everything.
;
; Walk order: SOURCE-ROWS-SCATTER, chosen over dest-columns-gather.
; The source stream is row-major (Gfx2Next emits rows sequentially);
; the 320-wide surface is column-major (dest = x*256 + y). Slot 6
; remaps per 320x200 picture:
;   rows-scatter:   per row 1 src remap (the 320-byte row crosses an
;                   8K page every 8192/320 = 25.6 rows, +1 then) +
;                   10 dest remaps (page = x>>5 changes every 32
;                   pixels) = ~11.04; 200 rows -> ~2210 remaps, and
;                   both the fetch (LDIR) and the scatter (fixed row
;                   in E, INC D per pixel) are straight-line walks.
;   columns-gather: per column a stride-320 walk of the whole 64000-
;                   byte pixel area = ceil(64000/8192) = 8 src remaps
;                   + 1 dest remap (amortised 1/32 but the alternating
;                   src maps force it every column) = ~9; 320 columns
;                   -> ~2890 remaps, AND a 16-bit stride-add with a
;                   page-crossing test per pixel in the inner loop.
; Scatter wins on both remap count and inner-loop cost. With the back-
; buffer render the paint is no longer visible mid-blit - a DMA upgrade
; (SP8 rider) would now only shorten the redraw latency, not fix an
; artifact. 256-wide mode is trivially linear-to-linear (row-major
; both sides): 2 remaps per row.
gfx_blit:
    ld a, (stagedEntry)
    cp GFX_EMPTY
    ret z
    ld a, (stagedMode)
    ld (l2Mode), a              ; variable only - sizes l2_clear_back's
                                ; page count; NR $70/$12 wait for the flip
    ld a, (l2BackBank)
    add a, a
    ld (gfxSurfPage), a         ; render target = the back surface
    call l2_clear_back          ; own data_save/restore - run BEFORE ours
    call data_save
    ; source stream = the entry's bank-list run, from its first page
    ld a, (stagedEntry)
    call gce_ptr
    inc hl
    ld a, (hl)                  ; GCE_FIRST
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a          ; (no remap needed here - gfx_row_fetch
    ld hl, DATA_WINDOW+512      ; re-asserts the source mapping itself)
    ld (gfxSrcPtr), hl          ; skip the palette (loaded after the rows)
    ld a, (stagedMode)
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    ld a, (gfxSurfPage)         ; 256-wide linear dest stream init
    ld (gfxDstPage), a          ; (320-wide scatter reinitialises
    ld hl, DATA_WINDOW          ; gfxDstPage itself every row)
    ld (gfxDstPtr), hl
    xor a
    ld (gfxRowY), a
    ld a, (stagedHeight)
    ld (gfxRowsLeft), a         ; 0 = 256 rows (djnz-style wrap)
.row:
    call gfx_row_fetch
    ld a, (stagedMode)
    or a
    jr z, .linear
    call gfx_row_scatter320
    jr .next
.linear:
    call gfx_row_copy256
.next:
    ld hl, gfxRowY
    inc (hl)
    ld hl, gfxRowsLeft
    dec (hl)
    jr nz, .row
    ; rows done: rewind the source stream to the file's 512-byte
    ; palette (offset 0, wholly inside the run's first page) and load
    ; it now, as late as possible before the flip (header comment)
    ld a, (stagedEntry)
    call gce_ptr
    inc hl
    ld a, (hl)                  ; GCE_FIRST again
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a
    call gfx_src_remap
    ld hl, DATA_WINDOW
    ld b, 1                     ; format 1 = 256 x 2-byte 9-bit entries
    call l2_palette_load
    call data_restore
    ; flip: swap surface roles, then program resolution + new front
    ; bank back-to-back via l2_mode_set (see l2_flip_swap header)
    call l2_flip_swap
    ld a, (stagedMode)
    call l2_mode_set
    jp l2_enable

; Map the current source page (gfxBankList[gfxSrcIdx]*2 + gfxSrcHalf)
; into slot 6 - the row writers leave slot 6 on a Layer 2 page, so
; each fetch re-asserts the source mapping. Corrupts AF, HL.
gfx_src_remap:
    ld hl, gfxBankList
    ld a, (gfxSrcIdx)
    add hl, a
    ld a, (hl)
    add a, a
    ld hl, gfxSrcHalf
    add a, (hl)
    jp data_map_page

; Advance the source stream to its next 8K page (the bank's upper
; half, then the next bank in the arena run), map it, and rewind
; gfxSrcPtr to the window base. Corrupts AF, HL.
gfx_src_advance:
    ld hl, gfxSrcHalf
    ld a, (hl)
    xor 1
    ld (hl), a
    jr nz, .map                 ; 0 -> 1: same bank, upper page
    ld hl, gfxSrcIdx
    inc (hl)                    ; 1 -> 0: next bank
.map:
    call gfx_src_remap
    ld hl, DATA_WINDOW
    ld (gfxSrcPtr), hl
    ret

; Stage one source row (gfxWidth bytes) from the cache-bank stream
; into gfxRowBuf, crossing 8K page boundaries as needed. Corrupts
; AF, BC, DE, HL.
gfx_row_fetch:
    call gfx_src_remap
    ld de, gfxRowBuf
    ld bc, (gfxWidth)           ; BC = bytes still to stage
.chunk:
    ld hl, (gfxSrcPtr)
    ld a, h
    cp high GFX_SRC_END
    jr c, .have
    call gfx_src_advance        ; previous row drained the page exactly
    ld hl, (gfxSrcPtr)          ; = DATA_WINDOW
.have:
    ; does the whole remainder fit before the window end?
    push hl
    add hl, bc                  ; HL = end = src + remaining (cannot
    ld a, h                     ; carry: src < $E000, remaining <= 320)
    cp high GFX_SRC_END
    jr c, .fits                 ; end < $E000
    jr nz, .nofit               ; end >= $E100
    ld a, l
    or a
    jr z, .fits                 ; end == $E000 exactly: still one page
.nofit:
    pop hl                      ; HL = src
.split:
    ; copy only what this page still holds, then advance
    push bc                     ; remaining
    push de                     ; dest
    ex de, hl
    ld hl, GFX_SRC_END
    or a
    sbc hl, de                  ; HL = bytes left in the page (>= 1)
    ld b, h
    ld c, l
    ex de, hl                   ; HL = src
    pop de                      ; dest
    push bc                     ; left
    ldir
    pop hl                      ; HL = left
    pop bc                      ; BC = remaining
    ld a, c                     ; remaining -= left
    sub l
    ld c, a
    ld a, b
    sbc a, h
    ld b, a
    call gfx_src_advance        ; preserves BC, DE
    jr .chunk
.fits:
    pop hl                      ; HL = src
    ldir
    ld (gfxSrcPtr), hl          ; may land exactly on GFX_SRC_END -
    ret                         ; the next fetch's .chunk check handles it

; Write the staged row to the row-major 256-wide surface: one LDIR to
; the linear destination stream, advancing the dest page every 32
; rows (8192/256; a 256-byte row never splits across pages). Corrupts
; AF, BC, DE, HL.
gfx_row_copy256:
    ld a, (gfxDstPage)
    call data_map_page
    ld hl, gfxRowBuf
    ld de, (gfxDstPtr)
    ld bc, 256
    ldir
    ld a, d
    cp high GFX_SRC_END
    jr c, .store
    ld a, (gfxDstPage)
    inc a
    ld (gfxDstPage), a
    ld de, DATA_WINDOW
.store:
    ld (gfxDstPtr), de
    ret

; Write the staged row to the column-major 320-wide surface. Dest
; address of pixel (x, y): 8K page gfxSurfPage + (x >> 5), in-page
; offset (x & 31)*256 + y - so with D = $C0 + (x & 31) and E = y, a
; step of +1 in x is INC D, and the page advances every 32 pixels:
; ten page runs per row. Reuses gfxDstPage as its page cursor (the
; linear 256-wide walk and this one never mix within a blit).
; Corrupts AF, BC, DE, HL.
gfx_row_scatter320:
    ld hl, gfxRowBuf
    ld a, (gfxSurfPage)
    ld (gfxDstPage), a
    ld c, 10
.page:
    ld a, (gfxDstPage)
    call data_map_page
    ld a, (gfxRowY)
    ld e, a
    ld d, high DATA_WINDOW
    ld b, 32
.px:
    ld a, (hl)
    inc hl
    ld (de), a
    inc d
    djnz .px
    ld a, (gfxDstPage)
    inc a
    ld (gfxDstPage), a
    dec c
    jr nz, .page
    ret

; Extension probe chain, tried in gfx_open_chain order. Row = 3 ASCII
; extension characters + the mode byte (0 = 256-wide row-major, 1 =
; 320-wide column-major; mirrors l2Mode's encoding). Task 5 PREPENDS
; its ZX0-compressed probe rows here so compressed art wins over raw.
gfxExtTab:
    db "NX2", 1
    db "NXI", 0
gfxExtEnd:
GFX_EXT_ROW equ 4

gfxPicNum:     db 0              ; picture being loaded/staged
gfxEntryIdx:   db 0              ; cache slot in use
gfxMode:       db 0              ; candidate mode from the chain row
gfxWidth:      dw 0              ; 320 or 256, per mode
gfxHandle:     db $FF            ; esxDOS handle, $FF = none open
gfxArenaStart: db 0              ; gfxBankNext at load start (rollback point)
gfxBankCount:  db 0              ; banks appended by this load
gfxCurPage:    db 0              ; 8K page being read into
gfxSizeLo:     dw 0              ; 24-bit byte total: gfxSizeHi:gfxSizeLo
gfxSizeHi:     db 0
gfxHeight:     db 0              ; derived rows (0 encodes 256)
gfxExtPtr:     dw 0              ; chain walk cursor
gfxSrcIdx:     db 0              ; blit source: arena index of current bank
gfxSrcHalf:    db 0              ; 0 = lower 8K page, 1 = upper
gfxSrcPtr:     dw 0              ; blit source: window-relative read cursor
gfxSurfPage:   db 0              ; blit dest: first 8K page of the BACK
                                 ; surface, latched at blit start
gfxDstPage:    db 0              ; blit dest: current 8K Layer 2 page
gfxDstPtr:     dw 0              ; blit dest: linear cursor (256-wide mode)
gfxRowY:       db 0              ; current pixel row
gfxRowsLeft:   db 0              ; rows still to copy (initial 0 = 256)
gfxRowBuf:     ds 320            ; row bounce buffer: slot 6 can only hold
                                 ; source OR dest, so each row stages here
                                 ; (in this overlay page - both users above
                                 ; run only with page 58 mapped; sized for
                                 ; the wider 320-pixel row)

; --- DEBUG bring-up test card ---
; Owner-driven hardware verification hook, wired from debug.asm's
; l2_dbg_hook (holding T at boot, see that file for the key protocol).
; Not reached from anywhere else; safe to strip along with the rest
; of the IFDEF DEBUG block for a release build.
;
; Double-buffer split: these diagnostics draw to the CURRENT FRONT
; surface directly (l2FrontBank - immediately visible, no flip step);
; gfx_blit alone renders to the back surface and flips. Both boot
; hooks run before any game blit, so front here is always banks 9-13
; in practice - the variable (rather than the constant) just keeps a
; warm re-entry with a stale flip state coherent until boot_data_init
; resets it.

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
; fits inside the front surface's first 8K page whether the surface
; is row- or column-major (see tc_mark). Corrupts everything.
l2_bareprobe_marker:
    inc a                        ; stage -> block count (1-4)
    ld (l2BpBlockCnt), a
    call data_save
    ld a, (l2FrontBank)
    add a, a
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

; Read back byte 0 of the front surface's first 8K page - where both
; modes' top-left corner marker lands (tc_mark_256/tc_mark_320 both
; write TC_MARK_COLOUR there). Lets the boot hook
; distinguish "content never made it into the banks" (reads back the
; transparent fill byte or garbage) from "the banks are right but
; another layer is hiding them" (reads back TC_MARK_COLOUR, $FF, even
; though the screen doesn't show it) regardless of what the display
; shows. Out: A = the byte read. Corrupts AF only.
l2_peek_marker:
    call data_save
    ld a, (l2FrontBank)
    add a, a
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
    ld a, (l2FrontBank)
    add a, a
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
    ld a, (l2FrontBank)
    add a, a
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
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW+252               ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 5
    ld hl, DATA_WINDOW+28*256            ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 5
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
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 9
    ld hl, DATA_WINDOW+28*256            ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW+236               ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 9
    ld hl, DATA_WINDOW+28*256+236        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

 ENDIF

    ASSERT $ <= OVL_LIMIT
