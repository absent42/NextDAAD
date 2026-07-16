; Picture cache tables (resident). Tracks which physical RAM banks
; currently hold decoded Layer 2 picture data, LRU-ordered by tick so
; the loader can evict the coldest entry when the pool is full
; (eviction lands in Task 6; until then a full pool fails the load).
; The loader/blitter (overlay2.asm: gfx_load/gfx_blit) consumes
; cache_find/cache_touch and the staged state below. Consumes
; bank_free (banks.asm, resident).

GFX_CACHE_MAX    equ 24       ; resident picture cache slots
GFX_ENTRY_SIZE   equ 6        ; picture#, firstBankIdx, bankCount, mode, height, tick
GFX_BANKLIST_MAX equ 128      ; bank-list arena: raw bank numbers, entries index in
GFX_EMPTY        equ 255      ; sentinel: entry.picture# for an unused slot

; gfxCache entry field offsets
GCE_PIC    equ 0
GCE_FIRST  equ 1              ; index into gfxBankList of this entry's first bank
GCE_COUNT  equ 2              ; number of banks this entry occupies in gfxBankList
GCE_MODE   equ 3              ; 0 = 256x192, 1 = 320x256 (mirrors l2Mode's encoding)
GCE_HEIGHT equ 4             ; picture height in pixels, 0 means 256 - a byte
                             ; cannot hold 256, so 0 is the full-surface height
                             ; (Task 4 consumers decode 0 as 256)
GCE_TICK   equ 5

; A = entry index (0..GFX_CACHE_MAX-1). Out: HL = gfxCache + index*6.
; Corrupts DE, HL. Preserves A, BC.
gce_ptr:
    ld d, GFX_ENTRY_SIZE
    ld e, a
    mul d, e                    ; DE = index * 6 (max 23*6 = 138, fits a byte)
    ld hl, gfxCache
    add hl, de
    ret

; A = picture number. Out: CF clear and A = entry index (0..23) if
; cached; CF set (A undefined) if not found. Corrupts BC, DE, HL.
; Picture GFX_EMPTY (255) is the empty-slot sentinel and is uncacheable -
; never pass it here, or it would false-match every unused slot.
cache_find:
    ld e, a                     ; E = picture# to match
    ld hl, gfxCache
    ld b, 0                     ; B = entry index
.scan:
    ld a, b
    cp GFX_CACHE_MAX
    jr z, .miss
    ld a, (hl)
    cp e
    jr z, .hit
    push bc
    ld bc, GFX_ENTRY_SIZE
    add hl, bc
    pop bc
    inc b
    jr .scan
.hit:
    ld a, b
    or a                        ; CF clear
    ret
.miss:
    scf
    ret

; A = entry index. Bump the global tick and stamp it into the entry's
; tick field (most-recently-used = highest tick). On 8-bit wrap
; (gfxTick 255 -> 0) every entry's tick is halved first, compressing
; the range while preserving relative recency order, so a wrap can
; never make a stale entry look newer than one touched moments before.
; Corrupts AF, BC, DE, HL.
cache_touch:
    push af                     ; A = entry index, survives the renorm pass
    ld a, (gfxTick)
    inc a
    jr nz, .stamp               ; no wrap: new stamp is gfxTick+1
    call gfx_tick_renorm        ; wrapped: halve every entry's tick first
    ld a, 128                   ; invariant: post-renorm stamp must exceed the
                                ; halved maximum (127) so the just-touched entry
                                ; stays the newest of all
.stamp:
    ld (gfxTick), a
    pop af                      ; A = entry index
    call gce_ptr                ; HL -> entry base
    ld bc, GCE_TICK
    add hl, bc
    ld a, (gfxTick)
    ld (hl), a
    ret

; Halve every cache entry's tick field. Only called from cache_touch,
; right before gfxTick wraps 255 -> 0. Corrupts B, DE, HL (preserves AF).
gfx_tick_renorm:
    ld hl, gfxCache + GCE_TICK   ; entry 0's tick field
    ld de, GFX_ENTRY_SIZE
    ld b, GFX_CACHE_MAX
.loop:
    srl (hl)
    add hl, de                   ; step to the next entry's tick field
    djnz .loop
    ret

; A = entry index. Frees every bank in the entry's bank-list range via
; bank_free, then clears the slot (picture# = GFX_EMPTY, counts/mode/
; height/tick zeroed). Safe to call on an already-empty slot (bankCount
; 0 skips the free loop). Corrupts AF, BC, DE, HL.
cache_drop:
    call gce_ptr                 ; HL -> entry base (picture#)
    inc hl                       ; -> firstBankIdx
    ld a, (hl)
    ld c, a                      ; C = firstBankIdx
    inc hl                       ; -> bankCount
    ld a, (hl)
    ld b, a                      ; B = bankCount
    ld d, 0
    ld e, c
    push hl                      ; save pointer (entry base + 2, GCE_COUNT)
    ld hl, gfxBankList
    add hl, de
    ex de, hl                    ; DE -> gfxBankList[firstBankIdx]
    ld a, b
    or a
    jr z, .clear
.free:
    ld a, (de)
    call bank_free               ; preserves BC, DE, HL (banks.asm)
    inc de
    djnz .free
.clear:
    pop hl                       ; HL -> entry base + 2
    dec hl
    dec hl                       ; HL -> entry base
    ld (hl), GFX_EMPTY           ; picture#
    inc hl
    xor a
    ld (hl), a                   ; firstBankIdx
    inc hl
    ld (hl), a                   ; bankCount
    inc hl
    ld (hl), a                   ; mode
    inc hl
    ld (hl), a                   ; height
    inc hl
    ld (hl), a                   ; tick
    ret

gfxTick:      db 0
stagedPic:    db GFX_EMPTY       ; picture# currently being staged, GFX_EMPTY = none
stagedMode:   db 0
stagedHeight: db 0
stagedEntry:  db GFX_EMPTY       ; cache slot reserved for the staged picture
gfxBankNext:  db 0               ; bank-list arena bump cursor: next free index
                                 ; (a failed load rewinds it; compaction on
                                 ; eviction is Task 6's problem)
gfxName:      db "000.NX2.ZX0", 0  ; picture filename scratch - RESIDENT so
                                 ; the path esxDOS reads sits in always-mapped
                                 ; RAM like ddbName/savName, not an overlay
                                 ; page. Sized for the longest probe,
                                 ; "NNN.NX2.ZX0": gfx_open_chain writes the 3
                                 ; digits and 7 NUL-padded extension bytes;
                                 ; the final NUL is never overwritten

; Layer 2 double-buffer surface state (resident so boot_data_init can
; reset it via gfx_cache_reset before any overlay is mapped). Front =
; the surface NR $12 points at (displayed); back = the render target.
; gfx_blit and h_display's clear flip the roles (overlay2.asm).
l2FrontBank:  db BANK_L2_FIRST
l2BackBank:   db BANK_L2BACK_FIRST

gfxBankList: ds GFX_BANKLIST_MAX

; Reset the whole picture cache to cold state: every slot empty, the
; staged sentinels cleared, the arena cursor rewound, the tick zeroed.
; Banks are NOT freed here: the caller (boot_data_init) runs on a path
; where bank_table_init rebuilds the whole allocator anyway, and a warm
; re-entry (see boot_data_init's header) would otherwise leave stale
; cache entries pointing at banks the allocator just recycled.
; Corrupts AF, BC, HL.
gfx_cache_reset:
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    xor a
    ld (gfxTick), a
    ld (stagedMode), a
    ld (stagedHeight), a
    ld (gfxBankNext), a
    ld a, BANK_L2_FIRST          ; double-buffer roles back to boot state
    ld (l2FrontBank), a
    ld a, BANK_L2BACK_FIRST
    ld (l2BackBank), a
    ld hl, gfxCache
    ld b, GFX_CACHE_MAX
.slot:
    ld (hl), GFX_EMPTY           ; picture#
    inc hl
    push bc
    ld b, GFX_ENTRY_SIZE-1
.zero:
    ld (hl), 0                   ; firstBankIdx/bankCount/mode/height/tick
    inc hl
    djnz .zero
    pop bc
    djnz .slot
    ret

; All GFX_CACHE_MAX slots assemble empty (picture# = GFX_EMPTY, all
; other fields 0); gfx_cache_reset above re-establishes the same state
; at boot for the warm re-entry path.
gfxCache:
    REPT GFX_CACHE_MAX
    db GFX_EMPTY, 0, 0, 0, 0, 0
    ENDR
