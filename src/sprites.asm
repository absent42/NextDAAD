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
sprUpLeft:    dw 0              ; upload bytes remaining
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

; ISR: advance every live set by one tick. Filled in Task 8.
spr_tick:
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

; Task 8 fills these.
spr_restart:
    or a
    ret
spr_hw_load:
    ret
spr_hw_show:
    ret
spr_hw_stop:
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
; Preserves DE, HL. Corrupts AF, BC, IX.
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
    call spr_cache_inuse         ; not evictable: its banks are still in use
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
    call bank_alloc
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
    push bc                      ; bank_alloc corrupts BC and C is the image page
    call bank_alloc              ; second bank on demand
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
