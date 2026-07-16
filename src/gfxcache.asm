; Picture cache tables (resident). Tracks which physical RAM banks
; currently hold decoded Layer 2 picture data, LRU-ordered by tick so
; a future loader (Task 4/6) can evict the coldest entry when the pool
; is full. Nothing calls cache_find/cache_touch/cache_drop yet -
; picture staging (Task 4) and Layer 2 picture display (Task 6) wire
; them up. Consumes bank_free (banks.asm, resident).

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
    ld l, a
    ld h, 0
    add hl, hl                  ; *2
    ld d, h
    ld e, l
    add hl, hl                  ; *4
    add hl, de                  ; *6
    ld de, gfxCache
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
; right before gfxTick wraps 255 -> 0. Corrupts AF, BC, DE, HL.
gfx_tick_renorm:
    ld b, 0
.loop:
    ld a, b
    call gce_ptr
    ld de, GCE_TICK
    add hl, de
    srl (hl)
    inc b
    ld a, b
    cp GFX_CACHE_MAX
    jr nz, .loop
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

gfxBankList: ds GFX_BANKLIST_MAX

; All GFX_CACHE_MAX slots start empty (picture# = GFX_EMPTY, all other
; fields 0) - assembled directly rather than zeroed by a boot routine,
; since nothing reads the table until a future task wires up a loader.
gfxCache:
    REPT GFX_CACHE_MAX
    db GFX_EMPTY, 0, 0, 0, 0, 0
    ENDR
