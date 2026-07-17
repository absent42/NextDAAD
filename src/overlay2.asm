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
; of letting it show through. Corrupts AF, E (nr_read preserves BC;
; only the ld e register-select setup touches DE).
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
; prioritise. Corrupts AF, E (nr_read preserves BC; only the ld e
; register-select setup touches DE).
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
    jr l2_pal9_stamp
.fmt9:
    ld b, 0
    call l2_pal9_run
    ; fall through to the stamp

; Force entry 254 = the reserved transparent colour (l2_palette_load
; header). Every palette-programming path ends here. Corrupts AF.
l2_pal9_stamp:
    nextreg NR_PAL_INDEX, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, 0     ; blue LSB 0, priority 0
    ret

; Program B 9-bit palette entries (0 = 256) from HL via NR $44, with
; the $FE collision dodge (l2_palette_load header). The caller owns
; the NR $43/$40 setup and the final l2_pal9_stamp - split out so
; gfx_direct_stream can feed the 512-byte palette through gfxRowBuf
; in two 256-byte halves. Corrupts AF, B, HL.
l2_pal9_run:
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
    ret

l2Mode:     db 0                 ; last mode set by l2_mode_set
l2FillByte: db 0
l2PageCur:  db 0
l2PageCnt:  db 0

; --- picture loader / blitter / PICTURE / DISPLAY (Tasks 4+5) ---
; File format (Gfx2Next -pal-embed): 512-byte palette (256 x 2-byte
; 9-bit entries, NR $44 order) followed by width*height pixel bytes,
; emitted row by row. NNN.NX2 = 320 wide, NNN.NXI = 256 wide; the
; height is whatever the file size says: (size - 512) / width.
;
; Gfx2Next invocations (tools/gfx2next; source must be an 8-bit
; paletted PNG/BMP of the target width):
;   raw:        gfx2next -bitmap -pal-embed pic.png N.NX2   (320 wide)
;               gfx2next -bitmap -pal-embed pic.png N.NXI   (256 wide)
;   compressed: add -zx0 to either - Gfx2Next then APPENDS ".zx0" to
;               the given output name (N.NX2 -> N.NX2.zx0), hence the
;               double extension the probe chain tries first. Verified
;               against gfx2next.exe: the -zx0 -pal-embed output is TWO
;               sequential self-terminating ZX0 streams, palette (512
;               bytes decompressed) then pixels.
; A whole raw file compressed in one pass (tools/z88dk/bin/z88dk-zx0
; NNN.NX2 NNN.NX2.ZX0 - what build-tests.ps1 -GfxZx0 stages) is ONE
; stream; gfx_depack accepts both by depacking streams back to back
; until the compressed input is exhausted. Either way the decompressed
; bytes are identical to the raw file, so everything downstream of the
; load (gfx_derive_height, gfx_blit, l2_palette_load) is unchanged.

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
; access. Miss: reserve a cache slot (evicting the coldest entry via
; gfx_evict_fix when every slot is committed), probe the extension
; chain (gfxExtTab order - ZX0-compressed variants win over raw),
; stream the file into freshly allocated 16K banks with count-checked
; reads - gfx_bank_get evicts cold entries as the pool runs dry - for
; a compressed variant depack those scratch banks into a fresh
; destination run (gfx_depack), derive the height from the
; (decompressed) byte total, then commit the entry and stage it.
; When even a full eviction pass cannot supply banks (or an evictable
; slot), a RAW file takes the direct-stream fallback instead
; (gfx_direct_stream: fused load+blit, nothing cached, stage cleared
; so a revisit reloads - but PICTURE itself still succeeds);
; compressed variants cannot (see gfx_direct_stream's header) and
; fail cleanly. Out: CF clear = staged (or fallback-drawn). CF set =
; failed (no file, depack error, malformed size, exhaustion with no
; fallback): every partially allocated bank is freed - scratch and
; destination alike, the arena cursor still covers both - the cursor
; rewound, and the stage cleared - jdaad unstages on a failed PICTURE
; too. Corrupts everything.
gfx_load:
    ld (gfxPicNum), a
    cp GFX_EMPTY                ; 255 = the empty-slot sentinel; passing it
    jp z, .failclean            ; to cache_find would false-match every
                                ; unused slot, so it is simply unloadable
    call cache_find
    jr c, .miss
    ld (gfxEntryIdx), a         ; hit: A = entry index
    call cache_touch
    jr .stage
.miss:
    xor a
    ld (gfxAllocFail), a
.slot:
    call gfx_find_empty         ; reserve a slot; not written until the
    jr nc, .gotslot             ; load has fully verified
    call gfx_evict_fix          ; every slot committed: evict the
    jr nc, .slot                ; coldest and rescan
    jr .exhausted               ; nothing evictable (only the staged
                                ; slot left - the GFX_CACHE_MAX=1
                                ; degradation shape): fallback territory
.gotslot:
    ld (gfxEntryIdx), a
    call gfx_open_chain
    jp c, .failclean
    call gfx_read_banks         ; closes the file on every path
    jr c, .failbanks
    ld a, (gfxCompressed)
    or a                        ; also clears CF for the skip case
    call nz, gfx_depack         ; scratch banks -> decompressed run
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
    ld a, (gfxAllocFail)        ; exhaustion (banks/arena, post-eviction)
    or a                        ; is the only failure the fallback can
    jr z, .failclean            ; help; io/shape errors fail clean
    ld a, (gfxCompressed)
    or a
    jr nz, .failclean           ; compressed: no fallback (see
                                ; gfx_direct_stream's header)
.exhausted:
    ; pool exhausted even after a full eviction pass: direct-stream a
    ; RAW file. (Re)open via the probe chain - it deterministically
    ; re-finds the same file and re-sets gfxMode/gfxWidth/gfxCompressed,
    ; which the .slot-exhaustion path arrives here without.
    call gfx_open_chain
    jr c, .failclean
    ld a, (gfxCompressed)
    or a
    jr nz, .failcloseh          ; compressed: close + clean fail
    call gfx_direct_stream      ; closes the handle on every path
    jr c, .failclean
    ; drawn + flipped, transient: no cache entry claims it and the
    ; stage is cleared so a revisit reloads; PICTURE still succeeds
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    or a
    ret
.failcloseh:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.failclean:
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    scf
    ret

; Find the first empty cache slot. Out: CF clear + A = entry index;
; CF set when every slot is committed (gfx_load then evicts and
; rescans). Corrupts AF, B, DE, HL.
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
; clear with the handle in gfxHandle and gfxMode/gfxWidth/
; gfxCompressed set from the matching row; CF set when no candidate
; exists on SD. Corrupts everything.
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
    ld bc, GFX_EXT_NAME         ; 7 NUL-padded extension characters -
    ldir                        ; a short extension carries its own
                                ; terminator; gfxName's final NUL backs
                                ; the full-length "NX2.ZX0" rows
    ld a, (hl)                  ; row's mode byte
    ld (gfxMode), a
    inc hl
    ld a, (hl)                  ; row's compressed flag
    ld (gfxCompressed), a
    ld a, (gfxMode)
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
    call gfx_bank_get           ; out: A = 16K bank; evicts cold cache
    jr c, .fail                 ; entries before giving up (CF +
                                ; gfxAllocFail set = true exhaustion)
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

; Allocate one 16K bank for the arena, evicting the coldest cache
; entry (and compacting the arena) as many times as it takes until
; both a free bank and arena room exist. Every eviction frees at
; least one bank and at least one arena slot (committed entries hold
; >= 1 bank), and the victim set only shrinks, so the loop
; terminates. Out: CF clear + A = bank (the caller appends it at
; gfxBankNext); CF set + gfxAllocFail = 1 when nothing evictable
; remains and the pool is still dry - TRUE exhaustion, gfx_load's
; fallback trigger. Corrupts AF, BC, DE, HL.
gfx_bank_get:
.try:
    ld a, (gfxBankNext)
    cp GFX_BANKLIST_MAX
    jr nc, .evict               ; bank-list arena full
    call bank_alloc             ; out: A = 16K bank, CF = none free
    ret nc
.evict:
    call gfx_evict_fix
    jr nc, .try
    ld a, 1
    ld (gfxAllocFail), a
    scf
    ret

; Evict the LRU cache entry (cache_evict_lru: excludes the staged
; slot, frees the banks, compacts the arena, rebases the surviving
; entries) and rebase this load's own in-flight arena indices by the
; same rule - any index above the removed run slides down with it.
; The victim's run always sits strictly below the in-flight run (the
; density invariant, gfxcache.asm), so gfxArenaStart and the depack
; cursors always qualify when live; when no load/depack is in flight
; they hold stale values that the next load re-initialises before
; reading, so the blind rebase is harmless. Out: CF set = nothing
; evictable. Corrupts AF, BC, DE, HL.
gfx_evict_fix:
    call cache_evict_lru        ; out: D = removed count, E = first
    ret c
    ld hl, gfxArenaStart
    call .fix
    ld hl, zx0SrcIdx
    call .fix
    ld hl, zx0DstStart
    call .fix
    or a
    ret
.fix:
    ld a, (hl)
    cp e                        ; index <= removed first: untouched
    ret c
    ret z
    sub d
    ld (hl), a
    ret

; Fused load+blit fallback for pool exhaustion - RAW files only.
; In: gfxHandle = an OPEN read handle on gfxName at offset 0, with
; gfxMode/gfxWidth set by gfx_open_chain and gfxCompressed = 0 (the
; caller enforces it). Streams the file from SD straight onto the
; BACK Layer 2 surface: commit l2Mode (front's mode snapshotted for
; the failure restore - see the entry comment) + clear the back, skip
; the 512-byte embedded palette, then per
; row esx_fread gfxWidth bytes into gfxRowBuf and write it with the
; SAME row writers gfx_blit uses (gfx_row_copy256/gfx_row_scatter320
; - the walks cannot diverge), enforcing gfx_derive_height's shape
; rules on the fly (>= 1 row, no partial trailing row, <= 192 rows on
; the 256-wide surface, <= 256 on the 320-wide). Then the palette:
; the file cursor is past it and F_SEEK is unproven in this codebase,
; so the file is closed and REOPENED (gfx_open_chain deterministically
; re-finds the same file) and the 512 bytes are programmed in two
; 256-byte halves through the shared l2_pal9_run + l2_pal9_stamp (the
; same $FE dodge and entry-254 stamp as l2_palette_load). Finally the
; flip, exactly as gfx_blit ends. NOTHING is cached and the caller
; clears the stage: the result is transient, a revisit reloads.
; WHY RAW ONLY: a compressed fallback would have to depack directly
; into the Layer 2 banks, but ZX0 back-references read earlier OUTPUT
; bytes assuming the linear layout the depacker's dest window
; provides, and the 320-wide surface is COLUMN-MAJOR - the scatter
; reorders bytes, so match copies would read reordered data. A 256-
; wide surface is linear, but a single fallback shape keeps this
; corner simple: compressed loads that exhaust eviction fail cleanly
; in gfx_load instead (CF, no picture, session unharmed). On a 1MB
; machine any legal picture still fits after a full eviction pass, so
; this whole routine is single-load-bigger-than-everything territory.
; Out: CF clear = drawn, flipped, handle closed. CF set = failed,
; handle closed, l2Mode restored to the still-displayed front
; surface's mode; the back surface may hold partial paint - invisible,
; never flipped, so the session is unharmed. Corrupts everything.
gfx_direct_stream:
    ; l2Mode is committed to the NEW mode before the clear (it sizes
    ; l2_clear_back's page count) but the flip only happens on success:
    ; snapshot the front surface's mode and restore it on the failure
    ; funnel, or a later DISPLAY n!=0 would size its back clear for the
    ; wrong surface (front=320, failed 256 fallback: only 6 of the 10
    ; pages cleared - garbage band after that flip). Chosen over making
    ; l2_clear_back unconditionally clear 10 pages: the snapshot is
    ; smaller and costs successful draws nothing. gfx_blit shares the
    ; commit-before-flip shape but has no failure path after its
    ; commit, so it needs no snapshot.
    ld a, (l2Mode)
    ld (gfxModeSave), a
    ld a, (gfxMode)
    ld (l2Mode), a              ; variable only - sizes l2_clear_back;
                                ; NR $70/$12 wait for the flip
    ld a, (l2BackBank)
    add a, a
    ld (gfxSurfPage), a
    call l2_clear_back          ; own data_save/restore - run BEFORE
                                ; ours, exactly as gfx_blit orders it
                                ; (no nested data_save)
    call data_save
    ld b, 2                     ; skip the palette: 2 x 256-byte
.skip:                          ; discard reads through gfxRowBuf
    push bc
    call gfx_direct_read256
    pop bc
    jp c, .fail
    djnz .skip
    ; render state exactly as gfx_blit stages it
    ld a, (gfxSurfPage)         ; 256-wide linear dest stream init
    ld (gfxDstPage), a          ; (the 320-wide scatter reinitialises
    ld hl, DATA_WINDOW          ; gfxDstPage itself every row)
    ld (gfxDstPtr), hl
    xor a
    ld (gfxRowY), a             ; doubles as the written-row count
    ld (gfxRowFull), a
.row:
    ld a, (gfxHandle)
    ld ix, gfxRowBuf
    ld bc, (gfxWidth)
    call esx_fread              ; out: BC = ACTUAL bytes read
    jp c, .fail
    ld a, b
    or c
    jr z, .eof                  ; clean EOF on a row boundary
    ld hl, (gfxWidth)
    or a
    sbc hl, bc
    jp nz, .fail                ; partial trailing row: malformed
    ; enforce the surface's row capacity BEFORE writing
    ld a, (gfxRowFull)
    or a
    jp nz, .fail                ; 257th row on the 320-wide surface
    ld a, (gfxMode)
    or a
    jr nz, .fits
    ld a, (gfxRowY)
    cp 192
    jp nc, .fail                ; 193rd row on the 256-wide surface
.fits:
    ld a, (gfxMode)
    or a
    jr z, .linear
    call gfx_row_scatter320
    jr .wrote
.linear:
    call gfx_row_copy256
.wrote:
    ld hl, gfxRowY
    inc (hl)
    jr nz, .row
    ld a, 1                     ; row 255 written, counter wrapped: the
    ld (gfxRowFull), a          ; full 256-row surface is painted -
    jr .row                     ; only EOF may follow
.eof:
    ld a, (gfxRowY)
    ld hl, gfxRowFull
    or (hl)
    jr z, .fail                 ; no pixel rows at all
    ; palette pass: reopen at offset 0 (header comment)
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call gfx_open_chain
    jr c, .faildone
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 2
.pal:
    push bc
    call gfx_direct_read256
    jr c, .palfail
    ld hl, gfxRowBuf
    ld b, 128                   ; 128 9-bit entries per 256-byte half
    call l2_pal9_run            ; shared $FE-dodge programming loop
    pop bc
    djnz .pal
    call l2_pal9_stamp          ; entry 254 = the reserved transparent
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call data_restore
    ; flip exactly as gfx_blit ends: swap the surface roles, then the
    ; resolution and new front bank back-to-back (l2_flip_swap header)
    call l2_flip_swap
    ld a, (gfxMode)
    call l2_mode_set
    call l2_enable
    or a
    ret
.palfail:
    pop bc
.fail:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.faildone:
    call data_restore
    ld a, (gfxModeSave)         ; no flip happened: re-sync l2Mode with
    ld (l2Mode), a              ; the still-displayed front surface
    scf
    ret

; Read exactly 256 bytes from gfxHandle into gfxRowBuf. Out: CF set
; on an esxDOS error or a short read. Corrupts everything (esx_fread
; makes no register promises). Only gfx_direct_stream calls this.
gfx_direct_read256:
    ld a, (gfxHandle)
    ld ix, gfxRowBuf
    ld bc, 256
    call esx_fread              ; out: BC = ACTUAL bytes read
    ret c
    ld hl, 256
    or a
    sbc hl, bc
    ret z                       ; full read: ZF set, CF clear
    scf
    ret

; --- ZX0 depacker (Task 5) ---
; Core algorithm vendored from Einar Saukas's dzx0_standard.asm
; ("Standard" ZX0 decoder, https://github.com/einar-saukas/ZX0,
; BSD-licensed / freely reusable with attribution; the copy shipped
; with z88dk at tools/z88dk/libsrc/_DEVELOPMENT/compress/zx0/z80/
; dzx0_standard.asm was the vendoring source). Control flow, the
; interlaced-Elias reader and the negative-offset arithmetic are kept
; verbatim; only the three memory primitives differ, because here
; neither the source nor the destination is flat memory:
;
;   upstream                    this port
;   ld a,(hl)/inc hl (source) = zx0_src_byte  (resident-ish chunk buf)
;   ldir to DE       (dest)   = zx0_dst_write (slot 6 window, banked)
;   ldir from DE-off (match)  = zx0_ref_read  (slot 6 window, banked)
;
; Banked windowing scheme (the scheme the loader lives or dies by):
; slot 6 ($C000, the ONLY data window - slot 7 holds this overlay's
; code) belongs to the DESTINATION. DE walks the mapped 8K dest page;
; zx0DstOrd counts which ordinal page of the destination run that is,
; and zx0MapOrd remembers which ordinal is actually mapped so remaps
; are lazy. The compressed SOURCE never needs the window at the same
; time: zx0_src_byte hands out bytes from a chunk buffer (gfxRowBuf -
; idle during loads, addressable at $Exxx in this overlay page) which
; zx0_chunk_refill refills from the scratch banks, briefly stealing
; slot 6 and invalidating zx0MapOrd so the next dest access remaps.
; Invariants:
;   - slot 6 holds the zx0MapOrd-th dest page, except inside
;     zx0_chunk_refill (which sets zx0MapOrd = $FF on exit);
;   - DE is always inside $C000..$E000; $E000 means "page full, step
;     pending" and is normalised by the next write or match setup;
;   - back-references are served BYTE BY BYTE in ascending order -
;     exactly LDIR's semantics, so overlapped (RLE) matches are
;     correct - with zx0_ref_read/zx0_dst_write each remapping slot 6
;     to their own page only when zx0MapOrd says it is not theirs
;     (same-page matches, the common case, run remap-free);
;   - bit-accumulator reloads happen ONLY at Elias stop-bit reads,
;     exactly as upstream (whose plain add-a,a discriminator/data-bit
;     reads have no reload path either): a ZX0 stream never drains the
;     accumulator at those reads - verified over the whole Rabenstein
;     corpus plus gfx2next -zx0 output with an instrumented model
;     decoder before porting.
;
; Failure discipline: any fault (source exhausted mid-stream, output
; past the 6-bank cap, bank/arena exhaustion, match offset before the
; output start) jumps to zx0_fail, which rewinds SP to the snapshot
; gfx_depack took and exits CF set; gfx_load's rollback then frees
; scratch and destination banks alike. The compressed INPUT was capped
; by gfx_read_banks' own 6-bank (96K) ceiling - generous, since ZX0
; output is never usefully larger than the 82432-byte raw maximum.

GFX_ZX0_CHUNK   equ 320         ; chunk buffer size = gfxRowBuf's
GFX_DST_ORD_MAX equ 12          ; dest cap: 6 banks x 2 pages, the same
                                ; ceiling gfx_read_banks puts on raw art

; Depack the streamed compressed file. In: the scratch run described
; by gfxArenaStart/gfxBankCount/gfxSizeHi:Lo (gfx_read_banks' output).
; Decompresses every back-to-back ZX0 stream in it (gfx2next -zx0
; emits two - palette then pixels; a z88dk-zx0 whole-file pass emits
; one) into freshly allocated banks appended after the scratch run,
; then frees the scratch banks, slides the destination bank numbers
; down over their arena slots and rewinds the cursor - so on success
; gfxArenaStart/gfxBankCount/gfxSize* describe a decompressed run
; byte-identical to a raw file load. Out: CF clear on success; CF set
; on any failure, all appended banks (scratch + dest) left for
; gfx_load_rollback, which the caller runs. Brackets slot 6 with
; data_save/data_restore. Corrupts everything.
gfx_depack:
    call data_save
    ld (zx0DepackSP), sp        ; zx0_fail's longjmp target
    ; source stream = the scratch run, from its first byte
    ld a, (gfxArenaStart)
    ld (zx0SrcIdx), a
    xor a
    ld (zx0SrcHalf), a
    ld hl, DATA_WINDOW
    ld (zx0SrcRd), hl
    ld hl, (gfxSizeLo)
    ld (zx0SrcLeft), hl
    ld a, (gfxSizeHi)
    ld (zx0SrcLeft+2), a
    ld hl, gfxRowBuf            ; empty chunk: the first fetch refills
    ld (zx0ChunkPtr), hl
    ld (zx0ChunkEnd), hl
    ; destination run appends to the arena after the scratch run
    ld a, (gfxBankNext)
    ld (zx0DstStart), a
    xor a
    ld (zx0DstCount), a
    ld (zx0DstOrd), a
    call zx0_dst_bank_alloc     ; ordinal 0 needs its bank up front
    ld a, $FF
    ld (zx0MapOrd), a           ; nothing mapped yet
    ld de, DATA_WINDOW
.stream:
    call dzx0_banked            ; one self-terminating stream
    ; unconsumed compressed bytes mean another stream follows
    ld hl, (zx0ChunkEnd)
    push de
    ld de, (zx0ChunkPtr)
    or a
    sbc hl, de
    pop de
    jr nz, .stream              ; chunk buffer not drained
    ld a, (zx0SrcLeft+2)
    ld hl, (zx0SrcLeft)
    or h
    or l
    jr nz, .stream              ; scratch banks not drained
    ; success: decompressed total = zx0DstOrd*$2000 + (DE - $C000),
    ; a 24-bit value (max 98304)
    ld a, d
    sub high DATA_WINDOW
    ld h, a                     ; H:L = bytes into the current page
    ld l, e                     ; (H = $20 when DE sits at $E000)
    ld a, (zx0DstOrd)
    ld c, a
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                    ; (ord & 7) << 5
    add a, h
    ld h, a
    ld a, 0                     ; keep the carry for the high byte
    adc a, a
    ld b, a
    ld a, c
    srl a
    srl a
    srl a                       ; ord >> 3
    add a, b
    ld (gfxSizeHi), a
    ld (gfxSizeLo), hl
    ; swap the arena runs: free the scratch banks, slide the dest bank
    ; numbers down over their slots, rewind the cursor - the committed
    ; entry then points at a dense run at the same gfxArenaStart
    ld a, (zx0DstStart)
    ld hl, gfxArenaStart
    sub (hl)
    ld b, a                     ; B = scratch bank count (>= 1)
    ld a, (gfxArenaStart)
    ld hl, gfxBankList
    add hl, a
    push hl                     ; slide destination
.freescratch:
    ld a, (hl)
    call bank_free              ; preserves BC, DE, HL (banks.asm)
    inc hl
    djnz .freescratch
    pop de                      ; HL ran up to the dest run's numbers
    ld a, (zx0DstCount)
    ld c, a
    ld b, 0
    ldir
    ld a, (gfxArenaStart)
    ld hl, zx0DstCount
    add a, (hl)
    ld (gfxBankNext), a
    ld a, (zx0DstCount)
    ld (gfxBankCount), a
    call data_restore
    or a
    ret
.fail:                          ; zx0_fail lands here, SP already rewound
    call data_restore
    scf
    ret

; Abort the depack from any depth: rewind SP to gfx_depack's snapshot
; and exit through its failure path. Never returns to the caller.
zx0_fail:
    ld sp, (zx0DepackSP)
    jr gfx_depack.fail

; One ZX0 stream (dzx0_standard's main loop, primitives swapped as per
; the scheme comment). In: DE = dest window cursor, dest/source state
; live. Out: DE advanced past the stream's output; BC = end-marker
; residue. A carries the bit accumulator throughout, parked in AF'
; around byte-copy loops and the new-offset arithmetic (upstream parks
; it there transiently too). Corrupts AF, AF', BC, HL.
dzx0_banked:
    ld hl, $FFFF                ; initial offset = 1, negative form -
    ld (zx0Offset), hl          ; upstream's `ld bc,$ffff / push bc`
    ld bc, 0
    ld a, $80                   ; empty accumulator: sentinel bit only
.literals:
    call zx0_elias              ; BC = literal count
    ex af, af'                  ; park the accumulator
.litcopy:
    call zx0_src_byte
    call zx0_dst_write
    dec bc
    ld a, b
    or c
    jr nz, .litcopy
    ex af, af'
    add a, a                    ; copy from last offset or new offset?
    jr c, .newoffset
    call zx0_elias              ; BC = copy length
    call .copy
    add a, a                    ; copy from literals or new offset?
    jr nc, .literals
.newoffset:
    call zx0_elias              ; BC = offset MSB (Elias value)
    ex af, af'                  ; park accumulator + its CF=1 (ret c)
    xor a
    sub c                       ; A = -MSB
    ret z                       ; C = 0 (value 256): end-of-stream
    ld b, a
    call zx0_src_byte           ; A = offset LSB (safe: the accumulator
    ld c, a                     ; and its carry sit parked in AF')
    ex af, af'                  ; accumulator back, CF = 1 again
    rr b                        ; BC = negative offset; the bit shifted
    rr c                        ; out of C = the first length bit
    ld (zx0Offset), bc
    ld bc, 1
    call nc, zx0_elias_bt       ; length gamma continues on a 0 bit
    inc bc
    call .copy
    add a, a                    ; copy from literals or new offset?
    jr c, .newoffset
    jr .literals
; copy BC match bytes from (write position + zx0Offset), strictly
; ascending byte order = LDIR semantics, overlap-safe
.copy:
    ex af, af'                  ; park the accumulator
    call zx0_ref_setup
.cploop:
    call zx0_ref_read
    call zx0_dst_write
    dec bc
    ld a, b
    or c
    jr nz, .cploop
    ex af, af'
    ret

; Interlaced Elias gamma read (upstream dzx0s_elias, source fetch
; through the chunk buffer). In: BC = 0 (zx0_elias) or 1 with the
; first data bit consumed (zx0_elias_bt), A = bit accumulator. Out:
; BC = value, CF set, accumulator updated. Corrupts F, HL.
zx0_elias:
    inc c
.loop:
    add a, a                    ; stop bit
    jr nz, .skip
    ; accumulator drained - the shifted-out bit was the bit-0 sentinel
    ; (always 1); fetch 8 fresh bits and re-supply the sentinel by scf,
    ; standing in for upstream's carried-over rla input
    call zx0_src_byte
    scf
    rla
.skip:
    ret c
zx0_elias_bt:
    add a, a                    ; data bit (never drains here - stream
    rl c                        ; invariant, see the scheme comment)
    rl b
    jr zx0_elias.loop

; Next compressed byte through the chunk buffer. Out: A = byte.
; Preserves BC, DE. Corrupts F, HL.
zx0_src_byte:
    ld hl, (zx0ChunkPtr)
    push de
    ld de, (zx0ChunkEnd)
    or a
    sbc hl, de
    pop de
    call z, zx0_chunk_refill
    ld hl, (zx0ChunkPtr)
    ld a, (hl)
    inc hl
    ld (zx0ChunkPtr), hl
    ret

; Refill gfxRowBuf (dual use: the blit row bounce buffer is idle
; during loads) with the next run of compressed bytes from the scratch
; banks. Steals slot 6 for the copy and invalidates zx0MapOrd so the
; next destination access remaps. Fails via zx0_fail when the stream
; demands bytes the file does not have. Preserves BC, DE. Corrupts
; AF, HL.
zx0_chunk_refill:
    push bc
    push de
    ld a, (zx0SrcLeft+2)
    ld hl, (zx0SrcLeft)
    or h
    or l
    jp z, zx0_fail              ; source exhausted mid-stream
    ld hl, (zx0SrcRd)
    ld a, h
    cp high GFX_SRC_END
    jr c, .have
    ; scratch page drained: upper half, then the run's next bank
    ld hl, zx0SrcHalf
    ld a, (hl)
    xor 1
    ld (hl), a
    jr nz, .rewind
    ld hl, zx0SrcIdx
    inc (hl)
.rewind:
    ld hl, DATA_WINDOW
    ld (zx0SrcRd), hl
.have:
    ld hl, gfxBankList
    ld a, (zx0SrcIdx)
    add hl, a
    ld a, (hl)
    add a, a
    ld hl, zx0SrcHalf
    add a, (hl)
    call data_map_page
    ld a, $FF
    ld (zx0MapOrd), a           ; slot 6 no longer holds a dest page
    ; count = min(page remainder, chunk capacity, source remainder)
    ld hl, GFX_SRC_END
    ld de, (zx0SrcRd)
    or a
    sbc hl, de                  ; page remainder (1..8192)
    ld de, GFX_ZX0_CHUNK
    or a
    sbc hl, de
    jr c, .cap1
    ld hl, 0                    ; min(HL, DE) idiom: HL-DE kept only
.cap1:                          ; when negative, DE added back
    add hl, de
    ld a, (zx0SrcLeft+2)
    or a
    jr nz, .fits                ; 64K+ unread: no source clamp needed
    ld de, (zx0SrcLeft)
    or a
    sbc hl, de
    jr c, .cap2
    ld hl, 0
.cap2:
    add hl, de
.fits:
    ld b, h                     ; BC = refill count (>= 1)
    ld c, l
    push bc
    ld hl, (zx0SrcRd)
    ld de, gfxRowBuf
    ldir
    ld (zx0SrcRd), hl           ; may land on GFX_SRC_END - the next
                                ; refill's page check advances then
    ld (zx0ChunkEnd), de
    ld hl, gfxRowBuf
    ld (zx0ChunkPtr), hl
    pop bc
    ld hl, (zx0SrcLeft)         ; 24-bit source remainder -= count
    or a
    sbc hl, bc
    ld (zx0SrcLeft), hl
    jr nc, .nb
    ld hl, zx0SrcLeft+2
    dec (hl)
.nb:
    pop de
    pop bc
    ret

; Write A to the destination stream through slot 6, stepping pages
; (and allocating destination banks) as the run grows. In/out: DE =
; window cursor. Preserves A, BC. Corrupts F, HL.
zx0_dst_write:
    push af
    ld a, d
    cp high GFX_SRC_END
    call nc, zx0_dst_advance    ; page full: step, DE = window base
    ld a, (zx0DstOrd)
    ld hl, zx0MapOrd
    cp (hl)
    call nz, zx0_map_ord
    pop af
    ld (de), a
    inc de
    ret

; Step the destination cursor to its next 8K page: the current bank's
; upper half on odd ordinals, a freshly allocated bank on even ones.
; Enforces the decompressed-output cap. Out: DE = DATA_WINDOW.
; Preserves BC. Corrupts AF, HL.
zx0_dst_advance:
    ld a, (zx0DstOrd)
    inc a
    ld (zx0DstOrd), a
    cp GFX_DST_ORD_MAX
    jp nc, zx0_fail             ; output overran the 6-bank cap
    bit 0, a
    call z, zx0_dst_bank_alloc  ; even ordinal: a new bank
    ld de, DATA_WINDOW
    ret

; Allocate one destination bank and append it to the arena run.
; gfx_bank_get may evict cache entries mid-depack: that only touches
; resident tables (the physical banks never move, slot 6's mapping
; stays valid), and gfx_evict_fix rebases zx0SrcIdx/zx0DstStart/
; gfxArenaStart to follow the compacted arena, so the depack cursors
; stay coherent. Preserves BC, DE. Corrupts AF, HL.
zx0_dst_bank_alloc:
    push bc
    push de                     ; eviction corrupts DE
    call gfx_bank_get           ; out: A = 16K bank; CF = exhausted
    pop de
    jp c, zx0_fail              ; (zx0_fail rewinds SP - the pushed BC
                                ; is reclaimed by the rewind)
    ld c, a
    ld hl, gfxBankList
    ld a, (gfxBankNext)
    add hl, a
    ld (hl), c
    inc a
    ld (gfxBankNext), a
    ld hl, zx0DstCount
    inc (hl)
    pop bc
    ret

; Map destination-run ordinal A (0-based 8K page) into slot 6 and
; remember it in zx0MapOrd. Preserves BC, DE. Corrupts AF, HL.
zx0_map_ord:
    ld (zx0MapOrd), a
    push bc
    ld b, a                     ; B = ordinal
    srl a
    ld c, a                     ; C = bank slot within the run
    ld a, (zx0DstStart)
    add a, c                    ; arena index
    ld hl, gfxBankList
    add hl, a
    ld a, (hl)
    add a, a                    ; the bank's lower 8K page
    bit 0, b
    jr z, .map
    inc a                       ; odd ordinal: upper half
.map:
    pop bc
    jp data_map_page

; Aim the back-reference cursor for the next match: ref position =
; 24-bit write position + zx0Offset (held negative, upstream form).
; A pending page step (DE = $E000) is normalised first so the write
; position is single-valued. Fails when the offset reaches before the
; output start (corrupt stream). Preserves BC, DE (bar the pending
; step). Corrupts AF, HL.
zx0_ref_setup:
    ld a, d
    cp high GFX_SRC_END
    call nc, zx0_dst_advance
    push bc
    push de
    ; W = zx0DstOrd*$2000 + (DE - $C000), built as hi:mid:lo = B:H:L
    ld a, (zx0DstOrd)
    ld c, a
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                    ; (ord & 7) << 5
    ld h, a
    ld a, d
    sub high DATA_WINDOW        ; 0..31, disjoint from the field above
    or h
    ld h, a                     ; H = W mid byte
    ld l, e                     ; L = W low byte
    ld a, c
    srl a
    srl a
    srl a
    ld b, a                     ; B = W high byte (ord >> 3)
    ; R = W + negative offset, sign-extended to 24 bits ($FF high)
    ld de, (zx0Offset)
    ld a, l
    add a, e
    ld l, a
    ld a, h
    adc a, d
    ld h, a
    ld a, b
    adc a, $FF
    jp nc, zx0_fail             ; no wrap = offset before output start
    ; A:H:L = R; split into ordinal (R >> 13) and window offset
    add a, a
    add a, a
    add a, a
    ld c, a                     ; R hi << 3
    ld a, h
    and %11100000
    rlca
    rlca
    rlca                        ; R mid >> 5
    or c
    ld (zx0RefOrd), a
    ld a, h
    and $1F
    or high DATA_WINDOW         ; window base + (R & $1FFF)
    ld h, a
    ld (zx0RefPtr), hl
    pop de
    pop bc
    ret

; Read the next back-reference byte from the destination run through
; slot 6, remapping only when the cursor's page is not the mapped one.
; Out: A = byte, cursor advanced. Preserves BC, DE. Corrupts F, HL.
zx0_ref_read:
    ld hl, (zx0RefPtr)
    ld a, h
    cp high GFX_SRC_END
    jr c, .inpage
    ld hl, zx0RefOrd            ; cursor ran off the page: next ordinal
    inc (hl)                    ; (always already allocated - the ref
    ld hl, DATA_WINDOW          ; trails the write position)
    ld (zx0RefPtr), hl
.inpage:
    ld a, (zx0RefOrd)
    ld hl, zx0MapOrd
    cp (hl)
    call nz, zx0_map_ord
    ld hl, (zx0RefPtr)
    ld a, (hl)
    inc hl
    ld (zx0RefPtr), hl
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

; Extension probe chain, tried in gfx_open_chain order. Row = 7 ASCII
; extension characters (NUL-padded; 7 fits the longest, "NX2.ZX0") +
; the mode byte (0 = 256-wide row-major, 1 = 320-wide column-major;
; mirrors l2Mode's encoding) + the compressed flag (1 = ZX0, load via
; gfx_depack). Per shape the ZX0 variants probe before raw so
; compressed art wins, the Gfx2Next-emitted double extension before
; its 8.3 synonym (kept for plain-FAT/no-LFN setups).
gfxExtTab:
    db "NX2.ZX0",          1, 1
    db "N2Z", 0, 0, 0, 0,  1, 1
    db "NX2", 0, 0, 0, 0,  1, 0
    db "NXI.ZX0",          0, 1
    db "NXZ", 0, 0, 0, 0,  0, 1
    db "NXI", 0, 0, 0, 0,  0, 0
gfxExtEnd:
GFX_EXT_NAME equ 7
GFX_EXT_ROW  equ GFX_EXT_NAME+2

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
gfxCompressed: db 0              ; candidate row's compressed flag
gfxAllocFail:  db 0              ; 1 = the load failed on TRUE pool
                                 ; exhaustion (gfx_bank_get gave up
                                 ; post-eviction) - gfx_load's
                                 ; direct-stream fallback trigger
gfxRowFull:    db 0              ; direct stream: the 256th row was
                                 ; written (gfxRowY wrapped), only EOF
                                 ; may follow
gfxModeSave:   db 0              ; direct stream: front surface's mode
                                 ; at entry, restored to l2Mode on the
                                 ; failure funnel (no flip happened)
gfxRowBuf:     ds 320            ; row bounce buffer: slot 6 can only hold
                                 ; source OR dest, so each row stages here
                                 ; (in this overlay page - both users above
                                 ; run only with page 58 mapped; sized for
                                 ; the wider 320-pixel row). DUAL USE: the
                                 ; depacker borrows it as the compressed-
                                 ; source chunk buffer (zx0_chunk_refill) -
                                 ; loads and blits never overlap
    ASSERT GFX_ZX0_CHUNK <= 320

; ZX0 depack state (all cursors in memory: the registers belong to the
; vendored dzx0 loop)
zx0SrcIdx:   db 0                ; scratch stream: arena index of its bank
zx0SrcHalf:  db 0                ; 0 = lower 8K page, 1 = upper
zx0SrcRd:    dw 0                ; scratch stream: window read cursor
zx0SrcLeft:  db 0, 0, 0          ; 24-bit compressed bytes not yet chunked
zx0ChunkPtr: dw 0                ; next byte to hand out of gfxRowBuf
zx0ChunkEnd: dw 0                ; end of the chunk's valid bytes
zx0DstStart: db 0                ; arena index of the first dest bank
zx0DstCount: db 0                ; dest banks allocated so far
zx0DstOrd:   db 0                ; dest ordinal 8K page being written
zx0MapOrd:   db 0                ; dest ordinal mapped in slot 6, $FF = none
zx0RefOrd:   db 0                ; back-ref cursor: dest ordinal page
zx0RefPtr:   dw 0                ; back-ref cursor: window offset
zx0Offset:   dw 0                ; current match offset, negative form
zx0DepackSP: dw 0                ; SP snapshot for zx0_fail's rewind

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
