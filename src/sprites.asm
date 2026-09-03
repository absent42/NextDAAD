; Sprite animation (SP20): state, loader, cache, allocators, palette, upload,
; tick, stop. Lives on SPR_PAGE (slot 7); frame tables on SPR_TAB_PAGE
; (slot 6). Entered only through spr_call (mainline) or isr_hook_body (ISR),
; which map both pages. Resident helpers: main.asm (spr_call, spr_stop_all,
; isr_hook_body, sprName).
    MMU 7, SPR_PAGE, OVL_ORG

; ---- state. A record is live only while SR_SET != SPR_SET_NONE.
sprRec:       ds SPR_CHANS*SR_SIZE
sprHalfMap:   ds 16               ; pattern half-slots 0-127, bit set = used
sprAttrMap:   ds 16               ; attribute slots 0-127
sprIdentMask: dw 0                ; palette blocks that must stay identity
sprClaimMask: dw 0                ; palette blocks owned by 4-bit sets
pointerMask:  dw 0                ; blocks the pointer pattern touches
sprCache:     ds SPR_CACHE_MAX*CE_SIZE
sprClock:     db 0                ; LRU clock, renormalised by the cache
sprLoads:     db 0                ; SD reads since boot (cache misses), wraps
; scratch for the loader and the hardware path
sprReqSet:    db 0
sprReqOv:     db 0                ; 1 = position override in sprOvX/sprOvY
sprOvX:       dw 0
sprOvY:       db 0
sprL2Mode:    db 0                ; l2Mode mirror passed in by overlay2
sprLdSet:     db 0
sprLdEntry:   db 0
sprLdLen:     dw 0
sprHandle:    db 0
sprPalSave:   db 0
; per-channel block tables: pattern -> palette block, rewritten at load
sprBlkTab:    ds SPR_CHANS*128
sprUpLeft:    dw 0              ; upload bytes remaining
sprUpPage:    db 0              ; image page currently in slot 6 during upload
sprApPat:     db 0              ; hoisted record fields for the apply loops
sprApX8:      db 0
sprApY8:      db 0
sprApA4:      db 0              ; %10000000 | Y8: the 4-bit anchor's byte 4 base
sprApBlk:     dw 0
SPR_AP_LEN equ $-sprApPat
sprApSave:    ds SPR_AP_LEN     ; the tick's shadow of the six cells above
; zxnDMA memory-to-port program: port A memory increment, port B I/O fixed at
; $5B, both cycle length 2, prescaler WRITTEN as zero, CONTINUOUS one-shot.
; Matches the dev guide's memory-to-port-$5B example (chapter-next-dma) byte
; for byte except the explicit timing and prescaler bytes: the prescaler
; register is shared and only reset or a WR2 write with D5 set changes it
; (dma.vhd R2_BYTE_0/R2_BYTE_1); a stale nonzero value would stop this
; transfer yielding to the sample ISR mid-block (doc 11 F3). WR2 is
; programmed I/O-fixed here, where every other non-video descriptor leaves
; it memory-increment; dma_copy resends WR1 and WR2 on every call, so
; nothing inherits the mode this leaves behind. Patched fields: .src,
; .len (exact count, RTL-settled).
sprDma:
    db $83                       ; WR6: disable
    db %01111101                 ; WR0: A->B; Alo, Ahi, len-lo, len-hi follow
.src:
    dw 0
.len:
    dw 0                         ; exact count 1..256
    db %01010100                 ; WR1: A = memory, increment; timing follows
    db %00000010                 ; WR1 timing: cycle length 2
    db %01101000                 ; WR2: B = I/O, fixed; timing follows
    db %00100010                 ; WR2 timing: cycle length 2, D5 = 1: prescaler follows
    db 0                         ; WR2 prescaler: zero, written every time
    db %10101101                 ; WR4: CONTINUOUS; B lo, hi follow
    dw SPRITE_PAT_PORT
    db $82                       ; WR5: stop on end of block
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - the bus stalls here until done
SPR_DMA_LEN equ $-sprDma
    ASSERT SPR_DMA_LEN == 17
SPR_DBG_BLOCK equ sprLoads+1-sprRec
    ASSERT SPR_DBG_BLOCK == 488  ; tests\sprites_dump.py mirrors this size

; Boot: no sets, no cache, half-slots 0/1 (pointer pattern slot 0) and
; attribute slot 0 reserved, channel numbers stamped. Ends in the identity
; recalc, so a re-init never leaves it empty while pointerMask is set.
; Corrupts AF, BC, DE, HL.
spr_state_init:
    ld hl, sprRec
    ld c, 0
.rec:
    ld (hl), SPR_SET_NONE
    push hl
    ld a, SR_CHAN
    add hl, a
    ld (hl), c
    pop hl
    ld a, SR_SIZE
    add hl, a
    inc c
    ld a, c
    cp SPR_CHANS
    jr c, .rec
    ld hl, sprHalfMap
    ld de, sprHalfMap+1
    ld bc, 16+16+2+2-1
    ld (hl), 0
    ldir                           ; both maps, both masks (pointerMask kept)
    ld a, %00000011
    ld (sprHalfMap), a
    ld a, %00000001
    ld (sprAttrMap), a
    ld hl, sprCache
    ld de, sprCache+1
    ld bc, SPR_CACHE_MAX*CE_SIZE-1
    ld (hl), SPR_SET_NONE
    ldir
    xor a
    ld (sprClock), a
    jp spr_ident_recalc

; DE = pointer block mask, from ptr_mask_scan through spr_call.
spr_pointer_mask_set:
    ld (pointerMask), de
    ; fall through

; sprIdentMask = pointerMask OR the block mask of every live 8-bit set.
; Corrupts AF, BC, DE, HL.
spr_ident_recalc:
    ld de, (pointerMask)
    ld hl, sprRec
    ld b, SPR_CHANS
.rec:
    ld a, (hl)
    cp SPR_SET_NONE
    jr z, .next
    inc hl
    ld a, (hl)                  ; SR_KIND
    dec hl
    or a
    jr nz, .next                ; 4-bit sets claim, they do not pin identity
    push hl
    ld a, SR_MASK
    add hl, a
    ld a, (hl)
    or e
    ld e, a
    inc hl
    ld a, (hl)
    or d
    ld d, a
    pop hl
.next:
    ld a, SR_SIZE
    add hl, a
    djnz .rec
    ld (sprIdentMask), de
    ret

; NR $43 bracket: sprite palette 0 for edit. Bit 7 forced clear (auto-
; increment, which the block writes rely on), bit 3 forced clear (sprite
; palette 0 is the displayed one), bits 2-0 kept. Opened ONCE around a run
; of block writes; the old value comes back in spr_pal_leave. Corrupts AF, E.
spr_pal_enter:
    ld e, NR_PAL_CTRL
    call nr_read
    ld (sprPalSave), a
    and %00000111
    or PAL_SPR_EDIT
    nextreg NR_PAL_CTRL, a
    ret
spr_pal_leave:
    ld a, (sprPalSave)
    nextreg NR_PAL_CTRL, a
    ret

; Write block A (0-15) from the 32-byte 9-bit table at HL; bracket open.
; HL exits advanced by 32 (spr_hw_load walks the palettes on it). Corrupts AF, BC.
spr_pal_write_block:
    swapnib                      ; block*16 = first index
    nextreg NR_PAL_INDEX, a
    ld b, 16
.e:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a    ; second write lands the entry, index auto-increments
    djnz .e
    ret

; Restore block A (0-15) to identity; bracket open. Entry i = RGB332 i,
; ninth bit = OR of its two blue bits. Computed, never read back: palette
; RAM holds identity only because .nexload wrote it at launch. Corrupts AF, BC.
spr_pal_identity_block:
    swapnib
    ld c, a
    nextreg NR_PAL_INDEX, a
    ld b, 16
.e:
    ld a, c
    nextreg NR_PAL_VALUE9, a
    ld a, c
    rrca
    or c
    and 1
    nextreg NR_PAL_VALUE9, a
    inc c
    djnz .e
    ret

; Bit A (0-127) of the map at HL: out HL = byte address, A = bit mask.
; Corrupts AF, HL. Preserves BC, DE.
spr_map_bitaddr:
    push bc
    push de
    ld c, a
    rrca
    rrca
    rrca
    and 15
    add hl, a
    ld a, c
    and 7
    ld b, a
    ld de, 1
    bsla de, b                   ; 1 << (bit & 7)
    ld a, e
    pop de
    pop bc
    ret

; ZF set if bits D..D+C-1 of the map at HL are all clear. Preserves HL, D, C. Corrupts AF, E.
spr_map_run_clear:
    push hl
    push de
    ld e, c
.chk:
    push hl
    ld a, d
    call spr_map_bitaddr
    and (hl)
    pop hl
    jr nz, .busy
    inc d
    dec e
    jr nz, .chk
    pop de
    pop hl
    xor a
    ret
.busy:
    pop de
    pop hl
    or 1
    ret

; First-fit from bit 0: HL = map, C = count, B = alignment (1 or 2).
; Out: CF clear, A = start; CF set when no run fits. Corrupts AF, DE.
spr_map_find_low:
    ld d, 0
.try:
    ld a, d
    add a, c
    jr c, .none
    cp 129
    jr nc, .none
    call spr_map_run_clear
    jr z, .got
    ld a, d
    add a, b
    ld d, a
    jr .try
.got:
    ld a, d
    or a
    ret
.none:
    scf
    ret

; Highest-fit: HL = map, C = count. Out: CF clear, A = start (never 0, slot 0 is
; the pointer); CF set when no run fits. Corrupts AF, DE.
spr_map_find_high:
    ld a, 128
    sub c
    ld d, a
.try:
    ld a, d
    or a
    jr z, .none
    call spr_map_run_clear
    jr z, .got
    dec d
    jr .try
.got:
    ld a, d
    or a
    ret
.none:
    scf
    ret

; Set (E = $FF) or clear (E = 0) bits D..D+C-1 of the map at HL. Preserves HL, DE. Corrupts AF, BC.
spr_map_fill:
    push hl
    push de
.b:
    push hl
    push de
    ld a, d
    call spr_map_bitaddr
    pop de
    ld b, a
    ld a, e
    or a
    jr z, .clr
    ld a, (hl)
    or b
    jr .w
.clr:
    ld a, b
    cpl
    and (hl)
.w:
    ld (hl), a
    pop hl
    inc d
    dec c
    jr nz, .b
    pop de
    pop hl
    ret

; Bit A (0-15) of the word at HL. Preserve HL; corrupt AF, BC, DE.
spr_mask_setbit:
    push hl
    call spr_mask_bit
    or (hl)
    ld (hl), a
    pop hl
    ret
spr_mask_clrbit:
    push hl
    call spr_mask_bit
    cpl
    and (hl)
    ld (hl), a
    pop hl
    ret
spr_mask_bit:                   ; out HL -> byte holding bit A, A = its mask. Corrupts HL, B, DE.
    cp 8
    jr c, .lo
    sub 8
    inc hl
.lo:
    ld b, a
    ld de, 1
    bsla de, b
    ld a, e
    ret

; Claim C free blocks for the 4-bit set in IX, lowest first. Fills SR_BLOCKS,
; counts SR_NBLK up as it goes (so a failed claim can be released), sets claim
; bits. Out: CF set when fewer than C are free. Corrupts AF, BC, DE, HL.
spr_blocks_claim:
    ld hl, (sprIdentMask)
    ld de, (sprClaimMask)
    ld a, l
    or e
    ld l, a
    ld a, h
    or d
    ld h, a                      ; HL = busy blocks
    push ix
    pop de
    ld a, SR_BLOCKS
    add de, a
    ld b, 0                      ; block index
.scan:
    ld a, l
    and 1
    jr nz, .busy
    ld a, b
    ld (de), a
    inc de
    inc (ix+SR_NBLK)
    push hl
    push de
    push bc
    ld hl, sprClaimMask
    call spr_mask_setbit         ; corrupts BC and DE, both live here
    pop bc
    pop de
    pop hl
    dec c
    jr z, .ok
.busy:
    srl h
    rr l
    inc b
    ld a, b
    cp 16
    jr c, .scan
    scf
    ret
.ok:
    or a
    ret

; Release the SR_NBLK blocks of the set in IX: identity back, claim bits
; cleared, SR_NBLK zeroed. One palette bracket for the whole run.
; Corrupts AF, BC, DE, HL.
spr_blocks_release:
    ld a, (ix+SR_NBLK)
    or a
    ret z
    ld b, a
    call spr_pal_enter
    push ix
    pop de
    ld a, SR_BLOCKS
    add de, a
.blk:
    ld a, (de)
    push bc
    push de
    push af
    call spr_pal_identity_block
    pop af
    ld hl, sprClaimMask
    call spr_mask_clrbit
    pop de
    pop bc
    inc de
    djnz .blk
    ld (ix+SR_NBLK), 0
    jp spr_pal_leave

; ISR, both sprite pages mapped by isr_hook_body. Records are scanned through
; HL; IX is materialised only for a channel that advances. Records with
; SR_SET = 255 are skipped, which is what makes publish-last and retire-first
; safe.
;
; NR $34 and port $303B keep independent counters unless NR $09 bit 4
; (lockstep) is set. No nextreg in src writes NR $09, and this design
; forbids it: that independence is what lets the tick's NR $34 writes
; interleave with a mainline upload to $5B without corrupting it.
spr_tick:
    ld hl, sprRec
    ld b, SPR_CHANS
    ld de, SR_SIZE
.chan:
    ld a, (hl)
    cp SPR_SET_NONE
    jr z, .next
    push hl
    ld a, SR_COUNT
    add hl, a
    ld a, (hl)
    or a
    jr z, .skip                  ; one-shot holding its last frame
    dec a
    ld (hl), a
    jr nz, .skip
    pop hl
    push hl
    push bc
    push de
    push hl
    pop ix
    ld a, (ix+SR_FRAME)
    inc a
    cp (ix+SR_FRAMES)
    jr c, .set
    ld a, (ix+SR_LOOP)
    or a
    jr z, .hold                  ; SR_COUNT stays 0: hold
    xor a
.set:
    ld (ix+SR_FRAME), a
    call spr_apply_frame_isr
.hold:
 IFDEF DEBUG
    ld d, (ix+SR_CHAN)             ; refresh the two moving bytes in the snapshot
    ld e, SR_SIZE                  ; ($5000 is bank 5, always mapped; slot 2 is
    mul d, e                       ; never remapped by this code). The hold path
    ld hl, SPR_DBG_SNAP+5+SR_FRAME ; passes through here too, so a one-shot's
    add hl, de                     ; settled SR_COUNT = 0 reaches the reader
    ld a, (ix+SR_FRAME)
    ld (hl), a
    inc hl
    ld a, (ix+SR_COUNT)
    ld (hl), a
 ENDIF
    pop de
    pop bc
.skip:
    pop hl
.next:
    add hl, de
    djnz .chan
    ret

; E = reason. DEBUG: "SPR? nn" at the marker column of row 29, the h_gfx idiom,
; then the snapshot. Release: silent. Always returns CF set.
spr_refuse:
 IFDEF DEBUG
    push de
    ld b, 29
    call dbg_markcol
    call dbg_at
    ld hl, msgSprRefuse
    call dbg_puts
    pop de
    ld a, e
    call dbg_hex8
    call spr_dbg_snap
 ENDIF
    scf
    ret

; Reason 12 for h_gfx's flag path (f > 252). Reached through spr_call:
; spr_refuse lives on SPR_PAGE.
spr_refuse_flags:
    ld e, 12
    jp spr_refuse

 IFDEF DEBUG
msgSprRefuse: db "SPR? ", 0
sprDbgSeq:    db 0
; Mirror the state block into the dead ULA pixel window for the ZRCP reader:
; signature, sequence, sprRec..sprLoads, xbnIntOn, sequence again.
; Corrupts AF, BC, DE, HL.
spr_dbg_snap:
    ld hl, sprDbgSeq
    inc (hl)
    ld a, (hl)
    ld hl, msgSprSig
    ld de, SPR_DBG_SNAP
    ld bc, 4
    ldir
    ld (de), a
    inc de
    ld hl, sprRec
    ld bc, SPR_DBG_BLOCK
    ldir
    push af
    ld a, (xbnIntOn)
    ld (de), a
    inc de
    pop af
    ld (de), a
    ret
msgSprSig:    db "SPR1"
 ENDIF

; A = set number (or SPR_SET_NONE to find a free record). Out: IX = record,
; CF clear when found; CF set otherwise. Corrupts F, B, DE.
spr_find_record:
    ld ix, sprRec
    ld b, SPR_CHANS
    ld de, SR_SIZE
.n:
    cp (ix+SR_SET)
    ret z
    add ix, de
    djnz .n
    scf
    ret

; B = set (255 = all). Stopping an inactive set is a no-op.
spr_stop_body:
    ld a, b
    cp SPR_SET_NONE
    jr z, spr_stop_all_body
    call spr_find_record
    ret c
    jr spr_stop_record

spr_stop_all_body:
    ld ix, sprRec
    ld b, SPR_CHANS
.n:
    push bc
    ld a, (ix+SR_SET)
    cp SPR_SET_NONE
    call nz, spr_stop_record
    ld de, SR_SIZE
    add ix, de
    pop bc
    djnz .n
    ret

; IX = live record. Retire first (the tick skips SR_SET = 255 from here),
; then hide, release, recompute identity, disarm when nothing is left.
spr_stop_record:
    ld (ix+SR_SET), SPR_SET_NONE
    call spr_hw_stop
    call spr_release_resources
    call spr_ident_recalc
    ld hl, sprRec
    ld b, SPR_CHANS
    ld de, SR_SIZE
.live:
    ld a, (hl)
    cp SPR_SET_NONE
    jr nz, .snap
    add hl, de
    djnz .live
    ld a, (xbnIntOn)
    and $FF-HOOK_SPR
    ld (xbnIntOn), a
.snap:
 IFDEF DEBUG
    call spr_dbg_snap
 ENDIF
    ret

; Free whatever the record in IX holds. Safe on a partially allocated record:
; SR_PAT 255 = no half-slots, SR_ATTR 0 = no attribute run, SR_NBLK 0 = no blocks.
spr_release_resources:
    ld a, (ix+SR_PAT)
    cp 255
    jr z, .nopat
    ld d, a
    ld c, (ix+SR_PATS)
    ld a, (ix+SR_KIND)
    or a
    jr nz, .cnt
    sla c
.cnt:
    ld e, 0
    ld hl, sprHalfMap
    call spr_map_fill
    ld (ix+SR_PAT), 255
.nopat:
    ld a, (ix+SR_ATTR)
    or a
    jr z, .noattr
    ld d, a
    ld c, (ix+SR_CELLS)
    ld e, 0
    ld hl, sprAttrMap
    call spr_map_fill
    ld (ix+SR_ATTR), 0
.noattr:
    jp spr_blocks_release

; IX = record. Loads SR_COUNT from the frame's delay byte and hoists the
; loop invariants. Out: HL -> first cell byte, B = cells, C = 0, D = anchor
; attribute slot, A = kind. Corrupts AF, BC, DE, HL.
spr_apply_setup:
    ld d, (ix+SR_FRAME)
    ld e, (ix+SR_ROW)
    mul d, e
    ld l, (ix+SR_TAB)
    ld h, (ix+SR_TAB+1)
    add hl, de
    ld a, (hl)
    ld (ix+SR_COUNT), a
    inc hl
    ld a, (ix+SR_PAT)
    ld (sprApPat), a
    ld a, (ix+SR_X8)
    ld (sprApX8), a
    ld a, (ix+SR_Y8)
    ld (sprApY8), a
    or %10000000
    ld (sprApA4), a
    ld e, (ix+SR_BLKTAB)
    ld d, (ix+SR_BLKTAB+1)
    ld (sprApBlk), de
    ld b, (ix+SR_CELLS)
    ld c, 0
    ld d, (ix+SR_ATTR)
    ld a, (ix+SR_KIND)
    ret

; One 8-bit cell. In: D = slot, HL -> cell byte, C = cell index. Advances
; HL, D, C. Byte 4 first, byte 3 last. NR $79 auto-increment is NOT usable
; here: it forces byte 4 last and the write order is what keeps a scanline
; from showing a new pattern under an old half-select or palette block.
    MACRO SPR_CELL8 bracket
    IF bracket
    call spr_di
    ENDIF
    ld a, d
    nextreg NR_SPRITE_SEL, a
    ld a, (hl)
    cp 255
    jr nz, 1F
    nextreg NR_SPRITE_PAT, %01000000   ; hidden: invisible, byte 4 kept
    jr 3F
1:  ld e, a
    ld a, c
    or a
    jr nz, 2F
    ld a, (sprApY8)                    ; anchor: H 0, composite, 1x, Y bit 8
    nextreg NR_SPRITE_ATTR2, a
    jr 4F
2:  nextreg NR_SPRITE_ATTR2, %01000000 ; relative marker
4:  ld a, e
    srl a
    or %11000000                       ; byte 3 last: visible, byte 4, slot = index/2
    nextreg NR_SPRITE_PAT, a
3:  IF bracket
    call spr_ei
    ENDIF
    inc hl
    inc d
    inc c
    ENDM

; One 4-bit cell, same contract. Silicon pin: the dev guide's N6 polarity
; for relatives (chapter-next-sprites.tex "1 to use bytes 0-127") is
; inverted against the RTL. N6 set selects the upper half for anchors and
; relatives alike (RTL, sprites.vhd); the guide says the opposite for
; relatives. Confirmed on silicon 2026-09-03 (set 018, run sheet S14/S16).
    MACRO SPR_CELL4 bracket
    IF bracket
    call spr_di
    ENDIF
    ld a, d
    nextreg NR_SPRITE_SEL, a
    ld a, (hl)
    cp 255
    jr nz, 1F
    nextreg NR_SPRITE_PAT, %01000000
    jr 3F
1:  ld e, a                            ; E = global half-slot index
    ld a, c
    or a
    jr nz, 2F
    ld a, e
    and 1                              ; N6 = index & 1: upper half when set
    rrca
    rrca                               ; bit 0 -> bit 6
    push hl
    ld hl, sprApA4
    or (hl)                            ; H, N6, Y bit 8
    nextreg NR_SPRITE_ATTR2, a
    ld a, e
    ld hl, sprApPat
    sub (hl)                           ; set-relative pattern index
    ld hl, (sprApBlk)
    add hl, a
    ld a, (hl)                         ; assigned block = palette offset
    swapnib
    ld hl, sprApX8
    or (hl)
    pop hl
    nextreg NR_SPRITE_ATTR, a
    jr 4F
2:  ld a, e
    and 1
    rrca
    rrca
    rrca                               ; bit 0 -> bit 5
    or %01000000                       ; relative marker
    nextreg NR_SPRITE_ATTR2, a
    ld a, e
    push hl
    ld hl, sprApPat
    sub (hl)
    ld hl, (sprApBlk)
    add hl, a
    ld a, (hl)
    pop hl
    swapnib                            ; bit 0 clear: independent palette offset
    nextreg NR_SPRITE_ATTR, a
4:  ld a, e
    srl a
    or %11000000
    nextreg NR_SPRITE_PAT, a
3:  IF bracket
    call spr_ei
    ENDIF
    inc hl
    inc d
    inc c
    ENDM

; IX = record, mainline, record unpublished. One bracket per cell.
spr_apply_frame:
    call spr_apply_setup
    or a
    jr nz, .l4
.l8:
    SPR_CELL8 1
    djnz .l8
    ret
.l4:
    SPR_CELL4 1
    djnz .l4
    ret

; IX = record, from the tick. No brackets: the ISR's IFF state is not ours.
; A mainline apply can be parked between its bracketed cells, so its hoisted
; invariants are shadowed across this one.
spr_apply_frame_isr:
    ld hl, sprApPat
    ld de, sprApSave
    ld bc, SPR_AP_LEN
    ldir
    call .body
    ld hl, sprApSave
    ld de, sprApPat
    ld bc, SPR_AP_LEN
    ldir
    ret
.body:
    call spr_apply_setup
    or a
    jr nz, .l4
.l8:
    SPR_CELL8 0
    djnz .l8
    ret
.l4:
    SPR_CELL4 0
    djnz .l4
    ret

; IX = live record, mainline. Retire so the tick cannot interleave, frame 0,
; republish. No allocation, no upload, cannot fail. Out: CF clear.
spr_restart:
    ld (ix+SR_SET), SPR_SET_NONE
    ld (ix+SR_FRAME), 0
    call spr_apply_frame
    ld a, (sprReqSet)
    ld (ix+SR_SET), a
 IFDEF DEBUG
    call spr_dbg_snap
 ENDIF
    or a
    ret

; IX = record being retired (SR_SET already 255). Every attribute slot of the
; set: byte 3 = 0 (invisible, byte 4 disabled) then byte 4 = 0, so no relative
; marker survives into the next owner. Groups of four slots per bracket, one
; select per group, NR $79 auto-increments. No-op when the record was never
; positioned (SR_ATTR 0 would otherwise clear the pointer's slot).
spr_hw_stop:
    ld a, (ix+SR_ATTR)
    or a
    ret z
    ld c, a
    ld b, (ix+SR_CELLS)
.group:
    call spr_di
    ld a, c
    nextreg NR_SPRITE_SEL, a
    ld e, 4
.slot:
    nextreg NR_SPRITE_PAT, 0
    nextreg NR_SPRITE_ATTR2_INC, 0
    inc c
    dec b
    jr z, .done
    dec e
    jr nz, .slot
    call spr_ei
    jr .group
.done:
    call spr_ei
    ret

; IX = allocated, unpublished record; slot 6 = image page 0. Palettes under one
; NR $43 bracket, then the pattern upload. Leaves slot 6 on the last image
; page read; the caller remaps SPR_TAB_PAGE. Cannot fail.
spr_hw_load:
    ld a, (ix+SR_KIND)
    or a
    jr z, .upload
    ld iy, DATA_WINDOW           ; block palettes: after header, table, block bytes
    ld hl, DATA_WINDOW+ANI_HDR
    ld e, (iy+ANI_TLEN)
    ld d, (iy+ANI_TLEN+1)
    add hl, de
    ld a, (ix+SR_PATS)
    add hl, a
    ld b, (ix+SR_NBLK)
    call spr_pal_enter           ; before DE is built: it corrupts E
    push ix
    pop de
    ld a, SR_BLOCKS
    add de, a
.pal:
    ld a, (de)
    push bc
    push de
    call spr_pal_write_block     ; A = block; HL exits advanced by 32
    pop de
    pop bc
    inc de
    djnz .pal
    call spr_pal_leave
.upload:
    ld iy, DATA_WINDOW           ; pattern offset = 16 + tlen + (4-bit: pats + nblk*32), under 8K
    ld hl, ANI_HDR
    ld e, (iy+ANI_TLEN)
    ld d, (iy+ANI_TLEN+1)
    add hl, de
    ld a, (ix+SR_KIND)
    or a
    jr z, .src
    ld a, (ix+SR_PATS)
    add hl, a
    ld d, (ix+SR_NBLK)
    ld e, 32
    mul d, e
    add hl, de
.src:
    ld de, DATA_WINDOW
    add hl, de                   ; HL = source in page 0
    xor a
    ld (sprUpPage), a
    ld d, (ix+SR_PATS)           ; bytes = pats * 256 (8-bit) or * 128 (4-bit)
    ld e, 128
    ld a, (ix+SR_KIND)
    or a
    jr nz, .cnt
    sla d
.cnt:
    mul d, e
    ld (sprUpLeft), de
    ld a, (ix+SR_PAT)            ; port $303B = (PAT >> 1) | (PAT & 1) << 7
    rrca
    ld bc, SPRITE_IDX_PORT
    out (c), a
    jp spr_upload

; HL = source in slot 6, (sprUpLeft) = bytes, (sprUpPage) = image page of HL,
; IX = record. DMA chunks of at most 256 bytes that never cross the $E000
; page end; slot 6 is remapped only when bytes remain. Runs unbracketed
; under the $CC = 0 contract (doc 11): the admitted CTC ISRs are MMU-free,
; RETI-exiting and never touch $5B or $303B, so a mid-block park cannot
; interleave into the pattern stream. Corrupts all.
spr_upload:
.chunk:
    ld de, (sprUpLeft)
    ld a, d
    or e
    ret z
    ld bc, 256                   ; n = min(left, 256)
    ld a, d
    or a
    jr nz, .room
    ld b, d
    ld c, e
.room:
    push hl                      ; src
    ex de, hl
    ld hl, $E000
    or a
    sbc hl, de                   ; HL = room to the page end
    push hl
    or a
    sbc hl, bc                   ; room - n
    pop hl
    jr nc, .go
    ld b, h
    ld c, l                      ; n = room
.go:
    pop hl                       ; src
    ld (sprDma.src), hl
    ld (sprDma.len), bc
    push hl
    push bc
    ld hl, sprDma
    ld b, SPR_DMA_LEN
    ld c, DMA_PORT
    otir                         ; the last byte enables; the bus stalls until done
    pop bc
    pop hl
    add hl, bc                   ; src += n
    push hl
    ld hl, (sprUpLeft)
    or a
    sbc hl, bc
    ld (sprUpLeft), hl           ; left -= n
    ld a, h
    or l
    pop hl
    ret z                        ; done: no remap past the final byte
    ld a, h
    cp $E0
    jr c, .chunk
    ld hl, sprUpPage
    inc (hl)
    ld c, (hl)
    ld a, (ix+SR_CACHE)
    call spr_cache_page
    call data_map_page
    ld hl, DATA_WINDOW
    jr .chunk

; IX = record, slot 6 = SPR_TAB_PAGE. Anchor at the plane position from the
; record, relatives at (cx*16, cy*16), everything invisible, then frame 0 and
; the sprite enable. Groups of four slots per bracket with one select; each
; slot writes $35-$38 then $79, which auto-increments the index.
spr_hw_show:
    call spr_di
    ld a, (ix+SR_ATTR)
    nextreg NR_SPRITE_SEL, a
    ld a, (ix+SR_XLO)
    nextreg NR_SPRITE_X, a
    ld a, (ix+SR_Y)
    nextreg NR_SPRITE_Y, a
    ld a, (ix+SR_X8)
    nextreg NR_SPRITE_ATTR, a
    nextreg NR_SPRITE_PAT, %01000000       ; invisible, byte 4 enabled
    ld a, (ix+SR_Y8)
    nextreg NR_SPRITE_ATTR2_INC, a         ; anchor byte 4; index -> cell 1
    ld b, (ix+SR_CELLS)
    dec b
    jr z, .anchor_only
    ld c, 1                      ; cell index
    ld e, 3                      ; slots left in this bracket (anchor used one)
.rel:
    ld a, c                      ; cx = c mod W, cy = c / W
    ld d, 0
.div:
    cp (ix+SR_W)
    jr c, .xy
    sub (ix+SR_W)
    inc d
    jr .div
.xy:
    swapnib                      ; cx*16 (cx <= 7, so no mask needed)
    nextreg NR_SPRITE_X, a
    ld a, d
    swapnib
    nextreg NR_SPRITE_Y, a
    nextreg NR_SPRITE_ATTR, 0              ; independent palette offset
    nextreg NR_SPRITE_PAT, %01000000       ; invisible, byte 4 enabled
    nextreg NR_SPRITE_ATTR2_INC, %01000000 ; relative marker; N6 set per frame
    inc c
    dec b
    jr z, .placed
    dec e
    jr nz, .rel
    call spr_ei
    call spr_di
    ld a, (ix+SR_ATTR)
    add a, c
    nextreg NR_SPRITE_SEL, a     ; re-select: the tick may have moved NR $34
    ld e, 4
    jr .rel
.placed:
.anchor_only:
    call spr_ei
    ld (ix+SR_FRAME), 0
    call spr_apply_frame         ; record unpublished: the tick cannot touch it
    ld e, NR_SPRITES
    call nr_read
    or SPR_NR15_ON               ; enable, over border, sprite 0 on top
    nextreg NR_SPRITES, a
    ret

; A = set. Out: CF clear and A = entry index on a hit (tick touched); CF set on a miss.
; Corrupts AF, BC, DE, HL.
spr_cache_lookup:
    ld hl, sprCache
    ld de, CE_SIZE
    ld b, SPR_CACHE_MAX
    ld c, 0
.n:
    cp (hl)
    jr z, .hit
    add hl, de
    inc c
    djnz .n
    scf
    ret
.hit:
    inc hl
    inc hl
    inc hl
    call spr_cache_tick
    ld (hl), a
    ld a, c
    or a
    ret

; Next LRU tick. When the clock wraps every tick is halved so order survives.
; Out: A = tick. Preserves HL, BC. Corrupts AF, DE.
spr_cache_tick:
    ld a, (sprClock)
    inc a
    jr nz, .ok
    push hl
    push bc
    ld hl, sprCache+CE_TICK
    ld b, SPR_CACHE_MAX
    ld de, CE_SIZE
.h:
    srl (hl)
    add hl, de
    djnz .h
    pop bc
    pop hl
    ld a, 128
.ok:
    ld (sprClock), a
    ret

; A = cache entry index. ZF set when a live record's SR_CACHE names it.
; Preserves DE, HL. Corrupts AF, BC (its own djnz), IX.
spr_cache_inuse:
    push de
    ld c, a
    ld ix, sprRec
    ld b, SPR_CHANS
    ld de, SR_SIZE
.n:
    ld a, (ix+SR_SET)
    cp SPR_SET_NONE
    jr z, .skip
    ld a, (ix+SR_CACHE)
    cp c
    jr z, .done                  ; ZF: in use
.skip:
    add ix, de
    djnz .n
    or 1                         ; NZ: free to evict
.done:
    pop de
    ret

; Free entry, or the LRU victim with its banks released. Out: A = entry, HL -> entry.
; Corrupts AF, BC, DE, HL.
spr_cache_victim:
    ld hl, sprCache
    ld b, SPR_CACHE_MAX
    ld c, 0
    ld d, 255                    ; best tick so far
    ld e, 0                      ; best index
.n:
    ld a, (hl)
    cp SPR_SET_NONE
    jr z, .free
    ld a, c                      ; an entry a live record's SR_CACHE names is
    push bc                      ; not evictable: its banks are still in use.
    call spr_cache_inuse         ; spr_cache_inuse runs its own djnz, so this
    pop bc                       ; scan's counter and index go on the stack
    jr z, .next
    push hl
    inc hl
    inc hl
    inc hl
    ld a, (hl)
    pop hl
    cp d
    jr nc, .next
    ld d, a
    ld e, c
.next:
    ld a, CE_SIZE
    add hl, a
    inc c
    djnz .n
    ld a, e                      ; evict E
    call spr_cache_entry
    push hl
    push de
    call spr_cache_free_banks
    pop de
    pop hl
    ld a, e
    ret
.free:
    ld a, c
    ret

; Free the banks of the coldest cached entry no live record names, never
; the entry being loaded (its CE_SET is still 255, so the free test skips
; it too). Out: CF clear when one was freed, CF set when none is evictable.
; Corrupts AF, BC, DE, HL, IX.
spr_cache_evict:
    ld hl, sprCache
    ld b, SPR_CACHE_MAX
    ld c, 0
    ld d, 255                    ; best tick so far
    ld e, 255                    ; best index, 255 = nothing evictable
.n:
    ld a, (hl)
    cp SPR_SET_NONE
    jr z, .next
    ld a, (sprLdEntry)
    cp c
    jr z, .next
    ld a, c
    push bc                      ; spr_cache_inuse runs its own djnz
    call spr_cache_inuse
    pop bc
    jr z, .next
    push hl
    inc hl
    inc hl
    inc hl
    ld a, (hl)
    pop hl
    cp d
    jr nc, .next
    ld d, a
    ld e, c
.next:
    ld a, CE_SIZE
    add hl, a
    inc c
    djnz .n
    ld a, e
    cp 255
    scf
    ret z
    call spr_cache_entry
    call spr_cache_free_banks
    or a                         ; CF clear: one entry evicted
    ret

; One pool bank, evicting cold cached sets until the pool yields - the
; gfx_bank_get shape. Out: CF clear + A = bank; CF set when nothing is
; evictable and the pool is still dry. Corrupts AF, BC, DE, HL, IX.
spr_bank_get:
.try:
    call bank_alloc
    ret nc
    call spr_cache_evict
    jr nc, .try
    scf
    ret

; A = entry. Out: HL -> entry. Preserves BC, DE. Corrupts AF, HL.
spr_cache_entry:
    ld hl, sprCache
    add a, a
    add a, a
    add hl, a
    ret

; HL -> entry: release its banks and mark it free. Corrupts AF, HL.
spr_cache_free_banks:
    ld (hl), SPR_SET_NONE
    inc hl
    ld a, (hl)
    cp 255
    call nz, bank_free
    ld (hl), 255
    inc hl
    ld a, (hl)
    cp 255
    call nz, bank_free
    ld (hl), 255
    ret

; Drop every cache entry and its banks. Only valid with no set live (the
; caller stops all first). Corrupts AF, BC, HL.
spr_cache_flush:
    ld hl, sprCache
    ld b, SPR_CACHE_MAX
.e:
    push bc
    push hl
    ld a, (hl)
    cp SPR_SET_NONE
    call nz, spr_cache_free_banks
    pop hl
    ld a, CE_SIZE
    add hl, a
    pop bc
    djnz .e
    ret

; A = entry, C = image page 0-3. Out: A = 8K page number for data_map_page.
; Corrupts AF, E, HL.
spr_cache_page:
    call spr_cache_entry
    inc hl
    ld a, c
    cp 2
    jr c, .b0
    inc hl
    sub 2
.b0:
    ld e, a
    ld a, (hl)
    add a, a
    add a, e
    ret

; Build "PARTn\NNN.ANI" in sprName from sprLdSet and curPart. Out: IX = path
; to open first (prefixed when curPart != 1, else the bare name at +6).
spr_name_build:
    ld a, (curPart)
    add a, '0'
    ld (sprName+4), a
    ld a, (sprLdSet)
    ld hl, sprName+6
    ld b, '0'-1
.h:
    inc b
    sub 100
    jr nc, .h
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.t:
    inc b
    sub 10
    jr nc, .t
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    ld ix, sprName
    ld a, (curPart)
    cp 1
    ret nz
    ld ix, sprName+6
    ret

; IX = path. Open read-only. Out: CF set on failure, else A = handle.
; IX is saved across the drive call: every esxDOS wrapper corrupts it
; (file.asm), and every other call site loads IX after esx_getsetdrv.
spr_open:
    push ix
    call esx_getsetdrv
    pop ix
    ret c
    ld b, ESX_MODE_READ
    jp esx_fopen

; A = set. Reads NNN.ANI into a fresh cache entry (one or two pool banks)
; through slot 6, validates, inserts. Out: CF clear, A = entry; CF set with
; the marker printed. Leaves slot 6 = SPR_TAB_PAGE. Corrupts everything.
spr_cache_load:
    ld (sprLdSet), a
    ld hl, sprLoads
    inc (hl)
    call spr_cache_victim
    ld (sprLdEntry), a
    push hl
    call spr_bank_get            ; evicts cold cached sets when the pool is dry
    pop hl
    ld e, 6
    jp c, spr_refuse             ; entry stays free, nothing taken
    inc hl
    ld (hl), a                   ; CE_BANK0
    inc hl
    ld (hl), 255                 ; CE_BANK1
    call spr_name_build
    call spr_open
    jr nc, .open
    ld a, (curPart)
    cp 1
    jr z, .nofile
    ld ix, sprName+6
    call spr_open
    jr nc, .open
.nofile:
    ld e, 4
    jr .failbanks
.open:
    ld (sprHandle), a
    ld hl, 0
    ld (sprLdLen), hl
    ld c, 0                      ; image page 0-3
.page:
    ld a, c
    cp 2
    jr nz, .havebank
    push bc                      ; spr_bank_get corrupts BC and C is the image page
    call spr_bank_get            ; second bank on demand, evicting as needed
    pop bc
    ld e, 6
    jr c, .failclose
    push af
    ld a, (sprLdEntry)
    call spr_cache_entry
    inc hl
    inc hl
    pop af
    ld (hl), a
.havebank:
    ld a, (sprLdEntry)
    call spr_cache_page
    call data_map_page
    ld a, (sprHandle)
    ld ix, DATA_WINDOW
    push bc
    ld bc, $2000
    call esx_fread
    ld e, 11
    jr c, .failclosebc
    ld hl, (sprLdLen)
    add hl, bc
    ld (sprLdLen), hl
    ld a, b
    cp $20
    pop bc
    jr nz, .done                 ; short read: EOF
    inc c
    ld a, c
    cp 4
    jr c, .page
    ld e, 11                     ; over 32K: not an .ANI
    jr .failclose
.failclosebc:
    pop bc
.failclose:
    push de                      ; the esxDOS wrappers corrupt DE: keep the reason
    ld a, (sprHandle)
    call esx_fclose
    pop de
.failbanks:
    push de
    ld a, (sprLdEntry)
    call spr_cache_entry
    call spr_cache_free_banks
    nextreg NR_MMU6, SPR_TAB_PAGE
    pop de
    jp spr_refuse
.done:
    ld a, (sprHandle)
    call esx_fclose
    ld a, (sprLdEntry)
    ld c, 0
    call spr_cache_page
    call data_map_page           ; image page 0 back in slot 6 for the validator
    call spr_validate            ; CF + E on failure
    jr c, .failbanks
    nextreg NR_MMU6, SPR_TAB_PAGE
    ld a, (sprLdEntry)
    call spr_cache_entry
    ld a, (sprLdSet)
    ld (hl), a
    inc hl
    inc hl
    inc hl
    call spr_cache_tick
    ld (hl), a
    ld a, (sprLdEntry)
    or a
    ret

; Image page 0 in slot 6. Out: CF clear when every format rule holds and the
; file length matches; else CF set, E = 5 (header) or 11 (length).
; Corrupts AF, BC, DE, HL, IY.
spr_validate:
    ld iy, DATA_WINDOW
    ld e, 5
    ld a, (iy+ANI_MAGIC)
    cp 'N'
    jr nz, .bade
    ld a, (iy+ANI_MAGIC+1)
    cp 'A'
    jr nz, .bade
    ld a, (iy+ANI_VER)
    cp 1
    jr nz, .bade
    ld a, (iy+ANI_FLAGS)
    and $FC
    jr nz, .bade
    ld a, (iy+ANI_W)
    dec a
    cp 8
    jr nc, .bade
    ld a, (iy+ANI_H)
    dec a
    cp 8
    jr nc, .bade
    ld a, (iy+ANI_X+1)           ; X 0-319: high byte 0, or 1 with low < 64
    cp 2
    jr nc, .bade
    or a
    jr z, .xok
    ld a, (iy+ANI_X)
    cp 64
    jr nc, .bade
.xok:
    ld a, (iy+ANI_FRAMES)
    or a
    jr z, .bade
    ld a, (iy+ANI_PATS)
    or a
    jr z, .bade
    ld c, 63
    bit 1, (iy+ANI_FLAGS)
    jr z, .p8
    ld c, 127
.p8:
    inc c
    cp c
    jr nc, .bade
    ld a, (iy+ANI_NBLK)
    bit 1, (iy+ANI_FLAGS)
    jr z, .nb8
    or a
    jr z, .bade
    cp 16
    jr nc, .bade
    jr .tlen
.nb8:
    or a
    jr z, .tlen
.bade:                           ; near exit for the header checks above
    scf
    ret
.tlen:
    ld a, (iy+ANI_W)             ; cells = W*H, row = cells+1
    ld d, a
    ld e, (iy+ANI_H)
    mul d, e
    ld a, e
    inc a
    ld d, a
    ld e, (iy+ANI_FRAMES)
    mul d, e                     ; DE = frames*(cells+1)
    ld l, (iy+ANI_TLEN)
    ld h, (iy+ANI_TLEN+1)
    or a
    sbc hl, de
    ld e, 5
    jr nz, .bade
    ld a, (iy+ANI_TLEN+1)        ; tlen <= 1024: high byte < 4, or == 4 with low 0
    cp 4
    jr c, .cells
    jr nz, .bade
    ld a, (iy+ANI_TLEN)
    or a
    jr nz, .bade
.cells:
    ld hl, DATA_WINDOW+ANI_HDR   ; cell bytes < pats or 255; cell 0 never 255
    ld b, (iy+ANI_FRAMES)
.frame:
    inc hl                       ; delay
    ld a, (iy+ANI_W)
    ld d, a
    ld e, (iy+ANI_H)
    mul d, e
    ld c, e                      ; cells
    ld a, (hl)
    cp 255
    jr z, .bad5                  ; anchor hidden; E is scratch below, so reload it
.cell:
    ld a, (hl)
    cp 255
    jr z, .next
    cp (iy+ANI_PATS)
    jr nc, .bad5
.next:
    inc hl
    dec c
    jr nz, .cell
    djnz .frame
    ld de, 0                     ; DE = extra body bytes (4-bit palettes)
    bit 1, (iy+ANI_FLAGS)
    jr z, .len
    ld b, (iy+ANI_PATS)
.blk:
    ld a, (hl)
    cp (iy+ANI_NBLK)
    jr nc, .bad5
    inc hl
    djnz .blk
    ld a, (iy+ANI_NBLK)          ; HL already covers the pats-byte block table
    ld d, a
    ld e, 32
    mul d, e                     ; blocks*32
.len:
    ld bc, DATA_WINDOW           ; expected = HL - base + DE + pats * (256 or 128)
    or a
    sbc hl, bc
    add hl, de
    ld a, (iy+ANI_PATS)
    ld d, a
    bit 1, (iy+ANI_FLAGS)
    jr nz, .m
    sla d                        ; 8-bit: pats*256 = (2*pats)*128; 2*63 fits
.m:
    ld e, 128
    mul d, e
    add hl, de
    ld de, (sprLdLen)
    or a
    sbc hl, de
    ld e, 11
    jr nz, .bad
    or a
    ret
.bad5:
    ld e, 5
.bad:
    scf
    ret

; B = set (0-254), C = flags (bit 0 override, bit 1 l2Mode), DE = override X,
; A = override Y. Via spr_call. Out: CF clear on success.
spr_start_body:
    ld (sprOvY), a
    ld (sprOvX), de
    ld a, c
    and 1
    ld (sprReqOv), a
    jr z, .l2
    ld a, d                      ; override X high byte: only 0 or 1 fits
    cp 2                         ; the 0-319 picture range
    jr c, .l2
    ld e, 12
    jp spr_refuse
.l2:
    ld a, c
    and 2
    ld (sprL2Mode), a            ; 0 = 256x192, nonzero = 320x256
    ld a, b
    cp SPR_SET_NONE
    ld e, 3
    jp z, spr_refuse
    ld (sprReqSet), a
    call spr_find_record
    jp nc, spr_restart           ; live: cheap restart, cannot fail
    ld a, SPR_SET_NONE
    call spr_find_record
    ld e, 2
    jp c, spr_refuse
    push ix
    ld a, (sprReqSet)
    call spr_cache_lookup
    jr nc, .have
    ld a, (sprReqSet)
    call spr_cache_load
    jr nc, .have
    pop ix
    ret                          ; CF set, marker and snapshot done
.have:
    pop ix
    ld (ix+SR_CACHE), a
    ld c, 0
    call spr_cache_page
    call data_map_page           ; slot 6 = image page 0
    call spr_hdr_to_record
    call spr_alloc
    jr c, .fail
    call spr_tables_stage        ; frame table -> SPR_STAGE, blocks -> SR_BLKTAB
    call spr_hw_load             ; palettes and patterns from slot 6 (pages 0-3)
    nextreg NR_MMU6, SPR_TAB_PAGE
    call spr_tables_commit       ; SPR_STAGE -> SR_TAB
    call spr_hw_show             ; position, frame 0, enable
    ld a, (sprReqSet)
    ld (ix+SR_SET), a            ; publish last
    call spr_ident_recalc
    ld a, (xbnIntOn)
    or HOOK_SPR
    ld (xbnIntOn), a
 IFDEF DEBUG
    call spr_dbg_snap
 ENDIF
    or a
    ret
.fail:
    nextreg NR_MMU6, SPR_TAB_PAGE
    jp spr_refuse

; Header in slot 6 -> record fields, including the sprite-plane position.
; Table addresses come from SR_CHAN. Corrupts AF, BC, DE, HL, IY.
spr_hdr_to_record:
    ld iy, DATA_WINDOW
    ld a, (iy+ANI_FLAGS)
    and ANI_FLAG_LOOP
    ld (ix+SR_LOOP), a
    ld a, (iy+ANI_FLAGS)
    and ANI_FLAG_4BIT
    rrca
    ld (ix+SR_KIND), a
    ld a, (iy+ANI_W)
    ld (ix+SR_W), a
    ld d, a
    ld a, (iy+ANI_H)
    ld (ix+SR_H), a
    ld e, a
    mul d, e
    ld a, e
    ld (ix+SR_CELLS), a
    inc a
    ld (ix+SR_ROW), a
    ld a, (iy+ANI_FRAMES)
    ld (ix+SR_FRAMES), a
    ld a, (iy+ANI_PATS)
    ld (ix+SR_PATS), a
    ld a, (iy+ANI_NBLK)
    ld (ix+SR_NBLKREQ), a
    ld a, (iy+ANI_MASK)
    ld (ix+SR_MASK), a
    ld a, (iy+ANI_MASK+1)
    ld (ix+SR_MASK+1), a
    ld (ix+SR_FRAME), 0
    ld (ix+SR_COUNT), 0
    ld a, (sprReqOv)             ; position: baked or override
    or a
    jr nz, .ov
    ld l, (iy+ANI_X)
    ld h, (iy+ANI_X+1)
    ld a, (iy+ANI_Y)
    jr .pos
.ov:
    ld hl, (sprOvX)
    ld a, (sprOvY)
.pos:
    ld e, a
    ld d, 0
    ld a, (sprL2Mode)
    or a
    jr nz, .plane                ; 320x256: picture (0,0) is plane (0,0)
    ld a, 32                     ; 256x192: picture (0,0) is plane (32,32)
    add hl, a
    add de, a
.plane:
    ld (ix+SR_XLO), l
    ld a, h
    and 1
    ld (ix+SR_X8), a
    ld (ix+SR_Y), e
    ld a, d
    and 1
    ld (ix+SR_Y8), a
    ld a, (ix+SR_CHAN)           ; SR_TAB = SPR_TAB_BASE + chan*1024
    add a, a
    add a, a
    add a, high SPR_TAB_BASE
    ld (ix+SR_TAB), 0
    ld (ix+SR_TAB+1), a
    ld a, (ix+SR_CHAN)           ; SR_BLKTAB = sprBlkTab + chan*128
    ld d, a
    ld e, 128
    mul d, e
    ld hl, sprBlkTab
    add hl, de
    ld (ix+SR_BLKTAB), l
    ld (ix+SR_BLKTAB+1), h
    ret

; IX = header-filled record. Takes half-slots, an attribute run, and blocks
; (4-bit). CF + E on failure with everything taken released. Corrupts all.
spr_alloc:
    ld (ix+SR_PAT), 255
    ld (ix+SR_ATTR), 0
    ld (ix+SR_NBLK), 0
    ld a, (ix+SR_KIND)
    or a
    jr nz, .pat
    ld hl, (sprClaimMask)        ; 8-bit: none of its blocks may be claimed
    ld a, (ix+SR_MASK)
    and l
    ld l, a
    ld a, (ix+SR_MASK+1)
    and h
    or l
    ld e, 10
    jr nz, .fail
.pat:
    ld c, (ix+SR_PATS)
    ld b, 1
    ld a, (ix+SR_KIND)
    or a
    jr nz, .find
    sla c
    ld b, 2
.find:
    ld hl, sprHalfMap
    call spr_map_find_low
    ld e, 7
    jr c, .fail
    ld (ix+SR_PAT), a
    ld d, a
    ld e, $FF
    call spr_map_fill
    ld c, (ix+SR_CELLS)
    ld hl, sprAttrMap
    call spr_map_find_high
    ld e, 8
    jr c, .fail
    ld (ix+SR_ATTR), a
    ld d, a
    ld e, $FF
    call spr_map_fill
    ld a, (ix+SR_KIND)
    or a
    ret z
    ld c, (ix+SR_NBLKREQ)
    call spr_blocks_claim
    ld e, 9
    ret nc
.fail:
    push de
    call spr_release_resources
    pop de
    scf
    ret

; Image page 0 in slot 6, IX = allocated record. Frame table -> SPR_STAGE with
; cell bytes rewritten to global half-slot indices; block table -> SR_BLKTAB
; (on SPR_PAGE, so it needs no staging) with file block numbers replaced by
; the assigned ones. Corrupts all.
spr_tables_stage:
    ld hl, DATA_WINDOW+ANI_HDR
    ld de, SPR_STAGE
    ld b, (ix+SR_FRAMES)
.frame:
    ld a, (hl)                   ; delay byte
    ld (de), a
    inc hl
    inc de
    ld c, (ix+SR_CELLS)
.cell:
    ld a, (hl)
    cp 255
    jr z, .put
    push bc
    ld b, a
    ld a, (ix+SR_KIND)
    or a
    ld a, b
    jr nz, .add
    add a, a                     ; 8-bit: two half-slots per pattern
.add:
    add a, (ix+SR_PAT)
    pop bc
.put:
    ld (de), a
    inc hl
    inc de
    dec c
    jr nz, .cell
    djnz .frame
    ld a, (ix+SR_KIND)
    or a
    ret z
    ld e, (ix+SR_BLKTAB)
    ld d, (ix+SR_BLKTAB+1)
    ld b, (ix+SR_PATS)
.blk:
    push bc
    ld a, (hl)
    push hl
    push ix
    pop hl
    add a, SR_BLOCKS
    add hl, a
    ld a, (hl)
    pop hl
    ld (de), a
    inc hl
    inc de
    pop bc
    djnz .blk
    ret

; Slot 6 = SPR_TAB_PAGE. SPR_STAGE -> SR_TAB, frames*row bytes.
; Corrupts AF, BC, DE, HL.
spr_tables_commit:
    ld d, (ix+SR_FRAMES)
    ld e, (ix+SR_ROW)
    mul d, e
    ld b, d
    ld c, e
    ld hl, SPR_STAGE
    ld e, (ix+SR_TAB)
    ld d, (ix+SR_TAB+1)
    ldir
    ret

 IFDEF DEBUG
; Boot-time allocator check, the bank_selftest idiom: prints "SPR FAIL n"
; on the first mismatch. Ends by re-initialising the state (which recalcs
; the identity mask), so it leaves nothing behind.
spr_selftest:
    ld hl, sprHalfMap            ; fresh map: bits 0,1 reserved
    ld c, 4
    ld b, 2
    call spr_map_find_low
    ld e, 1
    jp c, .fail
    cp 2
    jp nz, .fail
    ld d, 2                      ; take 2..5
    ld c, 4
    ld e, $FF
    call spr_map_fill
    ld c, 2
    ld b, 2
    call spr_map_find_low
    ld e, 2
    jp c, .fail
    cp 6
    jp nz, .fail
    ld hl, sprAttrMap            ; bit 0 reserved
    ld c, 4
    call spr_map_find_high
    ld e, 3
    jp c, .fail
    cp 124
    jp nz, .fail
    ld d, 124
    ld c, 4
    ld e, $FF
    call spr_map_fill
    ld c, 4
    call spr_map_find_high
    ld e, 4
    jp c, .fail
    cp 120
    jp nz, .fail
    ld hl, %0000000000000101     ; blocks 0 and 2 pinned
    ld (sprIdentMask), hl
    ld ix, sprRec                ; record 0 is free at boot: scratch
    ld (ix+SR_NBLK), 0
    ld c, 3
    call spr_blocks_claim
    ld e, 5
    jp c, .fail
    ld a, (ix+SR_BLOCKS)
    cp 1
    jp nz, .fail
    ld a, (ix+SR_BLOCKS+2)
    cp 4
    jp nz, .fail
    ld hl, (sprClaimMask)
    ld e, 6
    ld a, l
    cp %00011010
    jp nz, .fail
    call spr_blocks_release      ; identity into blocks 1,3,4: harmless at boot
    ld e, 7
    ld hl, (sprClaimMask)
    ld a, l
    or h
    jp nz, .fail
    jp spr_state_init
.fail:
    push de
    ld b, 23                     ; fixed bottom-left: the marker column is off
    ld c, 0                      ; the 32-column boot console this runs on
    call dbg_at
    ld hl, msgSprFail
    call dbg_puts
    pop de
    ld a, e
    call dbg_hex8
    jp spr_state_init
msgSprFail: db "SPR FAIL ", 0
 ENDIF

    DISPLAY "sprites ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
