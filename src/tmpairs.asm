; Program the two pairs reserved for system text, in the FIRST palette
; (the displayed one). Pair 0 = paper 0 / ink 7, pair 1 = paper 3 /
; ink 7. Their bits are set in pairUsed at boot and never cleared, so
; neither reclaim nor eviction can take them. Both use classic colours
; only, so tm_pal_write9 (which indexes dadPalette) serves directly.
; Corrupts AF, BC, DE, HL.
tm_reserved_pairs:
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, 0
    ld a, 0                     ; pair 0 paper
    call tm_pal_write9
    ld a, 7                     ; pair 0 ink
    call tm_pal_write9
    ld a, 3                     ; pair 1 paper
    call tm_pal_write9
    ld a, 7                     ; pair 1 ink
    call tm_pal_write9
    ret

; A = logical colour 0-255. Out: DE = its 9-bit value, D = RRRGGGBB and
; E = blue LSB in bit 0. There is no colour table anywhere: colours 0-15
; are the classic ULA entries already resident in dadPalette, and 16-255
; ARE their own RRRGGGBB value, so the answer is computed. The ninth bit
; for a computed colour is (B1 OR B0), which is exactly what the core
; derives on an NR $41 write (zxnext.vhd line 5425) - reproduced here so
; every palette write in this module can go through NR $44 uniformly.
; Touches no palette register at all, so NR $43 is left alone.
; Preserves BC. Corrupts AF, HL.
pal_colour:
    cp 16
    jr nc, .computed
    add a, a                    ; classic: two bytes per entry
    ld l, a
    ld h, 0
    ld de, dadPalette
    add hl, de
    ld d, (hl)                  ; byte 0 = RRRGGGBB
    inc hl
    ld e, (hl)                  ; byte 1 = blue LSB
    ret
.computed:
    ld d, a                     ; RRRGGGBB is the number itself
    and 3                       ; the two blue bits
    jr z, .noblue                ; both clear: ninth bit clear
    ld a, 1                      ; either set: ninth bit set (B1 OR B0)
.noblue:
    ld e, a
    ret

; --- tilemap pair allocator ---------------------------------------
; Tilemap text mode builds its palette index as
; (attribute AND $FE) OR pixel, so paper always lands on an even entry
; and ink on the odd entry above it. A (paper, ink) combination is
; therefore a PAIR, and the FIRST palette holds exactly 128 of them.
; They are allocated as combinations are used rather than pre-committed
; to a fixed cross-product, which is what makes all 256 logical colours
; reachable on both axes.
;
; There is deliberately no table of pair contents. A pair's identity is
; read back from the palette itself, so matching compares COLOURS, not
; colour numbers - two numbers resolving to the same RGB share one pair
; for free, and 256 bytes of state disappear.

pairUsed:   ds 16               ; bit k set = pair k allocated. Bits 0
                                ; and 1 are the reserved system pairs and
                                ; are set at boot, never cleared.
pairNext:   db 2                ; round-robin eviction cursor, wrapping
                                ; 2..127 so the reserved pairs are skipped
pairWantP:  dw 0                ; the 9-bit paper colour being resolved
pairWantI:  dw 0                ; the 9-bit ink colour being resolved

; A = palette entry index. Out: DE = the entry, D = RRRGGGBB and E =
; blue LSB in bit 0. Reads the palette currently selected in NR $43 -
; callers select PAL_TM_FIRST before looping. The index is set every
; time because the core increments it only on writes.
; Preserves BC and HL. Corrupts AF.
pair_read:
    push bc
    nextreg NR_PAL_INDEX, a
    ld bc, $243B
    ld a, NR_PAL_VALUE8
    out (c), a
    inc b
    in a, (c)
    ld d, a
    dec b
    ld a, NR_PAL_VALUE9
    out (c), a
    inc b
    in a, (c)
    and 1                       ; NR $44 reads carry more than the blue
    ld e, a                     ; bit, so mask to bit 0
    pop bc
    ret

; A = pair number 0-127. Sets its bit in pairUsed.
; Corrupts AF, BC, DE, HL.
pair_mark:
    push af
    and 7
    ld b, a
    inc b
    ld a, 1
.sh:
    dec b
    jr z, .mask
    add a, a
    jr .sh
.mask:
    ld c, a                     ; C = 1 << (pair AND 7)
    pop af
    rrca
    rrca
    rrca
    and 15                      ; byte index = pair >> 3 (pair < 128)
    ld l, a
    ld h, 0
    ld de, pairUsed
    add hl, de
    ld a, (hl)
    or c
    ld (hl), a
    ret

; Out: CF clear and A = a free pair number; CF set = none free.
; Corrupts AF, BC, HL.
pair_free_find:
    ld hl, pairUsed
    ld c, 0
.byte:
    ld a, (hl)
    cp $FF
    jr nz, .found
    inc hl
    ld a, c
    add a, 8
    ld c, a
    cp 128
    jr nz, .byte
    scf
    ret
.found:
    ld b, 8
    ld a, (hl)
.bit:
    rrca
    jr nc, .gotbit
    inc c
    djnz .bit
.gotbit:
    ld a, c
    or a                        ; CF clear
    ret

; Rebuild pairUsed from what is genuinely still needed: every pair an
; on-screen cell uses, plus the reserved pairs, plus every window's
; cached attribute and the cursor's inverse - so a colour selected but
; not yet printed cannot be stolen. Runs only when all 128 pairs are
; taken, which no realistic adventure reaches.
; Corrupts all registers.
pair_reclaim:
    ld hl, pairUsed
    ld de, pairUsed+1
    ld bc, 15
    ld (hl), 0
    ldir
    ld a, %00000011             ; the reserved pairs survive unconditionally
    ld (pairUsed), a
    ld hl, TM_MAP+1             ; first cell's attribute byte
    ld de, TM_COLS*TM_ROWS
.cell:
    push hl
    push de
    ld a, (hl)
    srl a                       ; attribute -> pair number
    call pair_mark
    pop de
    pop hl
    inc hl
    inc hl
    dec de
    ld a, d
    or e
    jr nz, .cell
    ld hl, winTable+WIN_ATTR
    ld b, WINDOW_COUNT
.win:
    push bc
    push hl
    ld a, (hl)
    srl a
    call pair_mark
    pop hl
    ld de, WIN_SIZE
    add hl, de
    pop bc
    djnz .win
    ld a, (inpAttrInv)
    srl a
    jp pair_mark

; B = paper colour 0-255, C = ink colour 0-255.
; Out: A = the tilemap attribute byte for that combination.
; Corrupts all registers.
pair_get:
    ld a, b
    call pal_colour
    ld (pairWantP), de
    ld a, c
    call pal_colour
    ld (pairWantI), de
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    ld b, 0
.scan:
    ld a, b
    add a, a                    ; entry 2k = paper
    call pair_read
    ld hl, (pairWantP)
    or a
    sbc hl, de
    jr nz, .next
    ld a, b
    add a, a
    inc a                       ; entry 2k+1 = ink
    call pair_read
    ld hl, (pairWantI)
    or a
    sbc hl, de
    jr z, .hit
.next:
    inc b
    ld a, b
    cp 128
    jr nz, .scan
    jp pair_alloc
.hit:                           ; a match in a slot whose bit was clear is
    ld a, b                     ; valid and free: the stale contents are
    add a, a                    ; exactly the colours wanted, so no palette
    push af                     ; write is needed, only the bit.
    ld a, b                     ; pair_mark corrupts BC, so the attribute
    call pair_mark              ; is computed and stacked BEFORE the call
    nextreg NR_PAL_CTRL, PAL_L2_FIRST   ; restore the standing convention
    pop af
    ret

; No pair holds the wanted combination. Take a free one, or reclaim, or
; evict. Out: A = the attribute byte. Corrupts all registers.
pair_alloc:
    call pair_free_find
    jr nc, .have
    call pair_reclaim
    call pair_free_find
    jr nc, .have
    ld a, (pairNext)            ; 128 combinations genuinely live: evict
    ld c, a
    inc a
    cp 128
    jr c, .stored
    ld a, 2                     ; wrap past the reserved pairs
.stored:
    ld (pairNext), a
    ld a, c
.have:
    push af
    call pair_mark
    pop af
    push af
    add a, a                    ; entry 2k
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, a
    ld de, (pairWantP)
    ld a, d
    nextreg NR_PAL_VALUE9, a
    ld a, e
    nextreg NR_PAL_VALUE9, a    ; auto-increment moves to entry 2k+1
    ld de, (pairWantI)
    ld a, d
    nextreg NR_PAL_VALUE9, a
    ld a, e
    nextreg NR_PAL_VALUE9, a
    nextreg NR_PAL_CTRL, PAL_L2_FIRST   ; restore the standing convention
    pop af
    add a, a
    ret

; Re-resolve the current window's attribute and the cursor's inverted
; attribute from its ink and paper. Called whenever either changes.
; Corrupts all registers.
win_attr_resolve:
    ld a, WIN_INK
    call win_field
    ld c, (hl)                  ; ink
    inc hl
    ld b, (hl)                  ; paper
    push bc
    call pair_get
    ld e, a
    ld a, WIN_ATTR
    call win_field
    ld (hl), e
    pop bc
    ld a, b                     ; swap the roles for the block cursor
    ld b, c
    ld c, a
    call pair_get
    ld (inpAttrInv), a
    ret
