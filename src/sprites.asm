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
; attribute slot 0 reserved, channel numbers stamped. Corrupts AF, BC, DE, HL.
; Task 6 makes this end in spr_ident_recalc.
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
    ret

; ISR: advance every live set by one tick. Filled in Task 8.
spr_tick:
    ret

; Mainline: stop every live set. Filled in Task 7.
spr_stop_all_body:
    ret

    DISPLAY "sprites ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
