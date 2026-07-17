; Picture cache tables (resident). Tracks which physical RAM banks
; currently hold decoded Layer 2 picture data, LRU-ordered by tick so
; the loader can evict the coldest entry when the pool is full
; (cache_evict_lru below; overlay2's gfx_bank_get drives the loop).
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
; 0 skips the free loop). NOTE: this clears the ENTRY but leaves the
; entry's slots in gfxBankList behind - a caller must recompact the
; arena or the density invariant (see gfxBankNext) breaks. The only
; caller is cache_evict_lru below, which owns that compaction.
; Corrupts AF, BC, DE, HL.
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

; Evict the least-recently-used committed cache entry - the lowest
; tick among occupied slots, EXCLUDING the staged slot (stagedEntry):
; gfx_blit re-reads the staged entry's banks at DISPLAY time, so
; evicting it would be a use-after-free (a DISPLAYED-but-unstaged
; picture is safe to evict - its pixels already live on the Layer 2
; surface and its banks are never re-read). The in-flight load's
; reserved slot is still GFX_EMPTY (gfx_load commits only on success)
; so it is excluded naturally. Frees the victim's banks (cache_drop),
; then COMPACTS the arena: the victim's gfxBankList slots are closed
; up by sliding every higher slot down, every surviving entry's
; GCE_FIRST is rebased, and gfxBankNext shrinks - restoring the
; density invariant. The victim's run always sits strictly below any
; in-flight run (loads append at the cursor), so the caller rebases
; its own in-flight arena indices by the same rule: index > E means
; index -= D (overlay2's gfx_evict_fix).
; Out: CF clear with D = removed slot count, E = removed first index;
; CF set (D, E undefined) when nothing is evictable. Corrupts
; AF, BC, DE, HL.
cache_evict_lru:
    ld hl, gfxCache
    ld b, 0                      ; B = scan index
    ld c, GFX_EMPTY              ; C = victim index, none yet
    ld d, 0                      ; D = victim tick (valid once C set)
.scan:
    ld a, (hl)                   ; GCE_PIC
    cp GFX_EMPTY
    jr z, .next                  ; empty slot
    ld a, (stagedEntry)
    cp b
    jr z, .next                  ; staged: gfx_blit may re-read it
    push hl
    ld a, GCE_TICK
    add hl, a
    ld e, (hl)                   ; E = candidate tick
    pop hl
    ld a, c
    cp GFX_EMPTY
    jr z, .take                  ; first candidate is provisional victim
    ld a, e
    cp d
    jr nc, .next                 ; not older than the victim so far
.take:
    ld c, b
    ld d, e
.next:
    push de
    ld de, GFX_ENTRY_SIZE
    add hl, de
    pop de
    inc b
    ld a, b
    cp GFX_CACHE_MAX
    jr c, .scan
    ld a, c
    cp GFX_EMPTY
    jr z, .none
    ; victim found: capture its run before cache_drop clears it
    call gce_ptr                 ; A = victim index; HL -> entry base
    inc hl
    ld a, (hl)                   ; GCE_FIRST
    ld (gceDropFirst), a
    inc hl
    ld a, (hl)                   ; GCE_COUNT
    ld (gceDropCount), a
    ld a, c
    call cache_drop              ; free the banks, clear the slot
    ; slide gfxBankList[first+count .. gfxBankNext-1] down over the
    ; hole (forward LDIR: dest < src, overlap-safe)
    ld a, (gceDropFirst)
    ld e, a
    ld d, 0
    ld hl, gfxBankList
    add hl, de
    ex de, hl                    ; DE = dest = list + first
    ld a, (gceDropCount)
    ld l, a
    ld h, 0
    add hl, de                   ; HL = src = list + first + count
    ld a, (gceDropFirst)
    ld b, a
    ld a, (gceDropCount)
    add a, b                     ; first + count (<= gfxBankNext <= 128)
    ld b, a
    ld a, (gfxBankNext)
    sub b                        ; slots above the hole
    jr z, .slid                  ; victim was the topmost run
    ld c, a
    ld b, 0
    ldir
.slid:
    ; rebase every surviving entry whose run sat above the hole
    ; (empty slots hold GCE_FIRST = 0, never > first, so no guard)
    ld a, (gceDropFirst)
    ld e, a
    ld a, (gceDropCount)
    ld d, a
    ld hl, gfxCache + GCE_FIRST
    ld b, GFX_CACHE_MAX
.rebase:
    ld a, (hl)
    cp e
    jr z, .keep                  ; == first: the cleared victim itself
    jr c, .keep                  ; below the hole: untouched
    sub d
    ld (hl), a
.keep:
    push de
    ld de, GFX_ENTRY_SIZE
    add hl, de
    pop de
    djnz .rebase
    ld a, (gfxBankNext)
    sub d
    ld (gfxBankNext), a
    or a                         ; CF clear; D = count, E = first
    ret
.none:
    scf
    ret

gceDropFirst: db 0               ; cache_evict_lru scratch: victim run
gceDropCount: db 0               ; (first index, slot count)

gfxTick:      db 0
stagedPic:    db GFX_EMPTY       ; picture# currently being staged, GFX_EMPTY = none
stagedMode:   db 0
stagedHeight: db 0
stagedEntry:  db GFX_EMPTY       ; cache slot reserved for the staged picture
gfxBankNext:  db 0               ; bank-list arena cursor: next free index.
                                 ; DENSITY INVARIANT: [0, gfxBankNext) is
                                 ; always dense - committed entries' runs in
                                 ; commit order, then at most one in-flight
                                 ; load's run on top. Every path that removes
                                 ; slots restores it: a failed load rewinds
                                 ; the cursor over its own (topmost) run
                                 ; (gfx_load_rollback), a depack slides its
                                 ; dest run down over the freed scratch run
                                 ; (gfx_depack), an eviction slides everything
                                 ; above the victim down and rebases the
                                 ; survivors (cache_evict_lru)
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
