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
sprIff:       db 0                ; spr_di's IFF2 sample
; per-channel block tables: pattern -> palette block, rewritten at load
sprBlkTab:    ds SPR_CHANS*128

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

; ISR: advance every live set by one tick. Filled in Task 8.
spr_tick:
    ret

; Mainline: stop every live set. Filled in Task 7.
spr_stop_all_body:
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
    ld b, 30
    call dbg_markcol
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
