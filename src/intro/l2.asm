; Layer 2 surfaces A (bank 9) and B (bank 14), mode, clip, palette.
l2_setup:
    ld a, (curSlide+SL_MODE)
    call l2_mode_apply
    jp pal_black

; A = mode (0 = 256x192, 1 = 320x256): resolution, front bank, clip, scroll.
l2_mode_apply:
    ld (l2Mode), a
    or a
    ld a, %00010000
    jr nz, .set
    xor a
.set:
    nextreg NR_L2_CTRL, a
    ld a, (frontBank)
    nextreg NR_L2_BANK, a
    nextreg NR_L2_TRANSP, L2_TRANSP_COLOUR
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_XOFS_MSB, 0
    nextreg NR_L2_YOFS, 0
    nextreg NR_CLIP_IDX, 1
    nextreg NR_L2_CLIP, 0
    ld a, (l2Mode)
    or a
    jr nz, .m320
    nextreg NR_L2_CLIP, 255
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 191
    ret
.m320:
    nextreg NR_L2_CLIP, 159
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 255
    ret

l2_show:
    ld bc, PORT_L2
    ld a, 2
    out (c), a
    ret
l2_hide:
    ld bc, PORT_L2
    xor a
    out (c), a
    ret
; Swap surface roles and point NR $12 at the new front.
l2_swap:
    ld a, (frontBank)
    ld b, a
    ld a, (backBank)
    ld (frontBank), a
    nextreg NR_L2_BANK, a
    ld a, b
    ld (backBank), a
    ret

; HL = 512-byte palette in the slot 6 window: program the Layer 2 palette
; (9-bit pairs through NR $44). Corrupts AF, B, HL.
pal_program:
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 0
.e:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    and 1                             ; also clears bit 7 (L2 priority colour);
    nextreg NR_PAL_VALUE9, a          ; gfx2next output never sets it
    djnz .e
    ret

; All 256 entries black.
pal_black:
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 0
.e:
    nextreg NR_PAL_VALUE9, 0
    nextreg NR_PAL_VALUE9, 0
    djnz .e
    ret

; A = colour 0-255: fill PAL_SOLID (page 39 in slot 6) with its 9-bit pair.
pal_solid:
    ld c, a
    and 3
    ld b, 0
    jr z, .b
    ld b, 1
.b:
    ld a, PG_STAGE
    call map6
    ld hl, PAL_SOLID
    ld d, 0
.f:
    ld (hl), c
    inc hl
    ld (hl), b
    inc hl
    inc d
    jr nz, .f
    ret

; PAL_NEW -> PAL_CUR (page 39 in slot 6).
pal_copy_new_to_cur:
    ld a, PG_STAGE
    call map6
    ld hl, PAL_NEW
    ld de, PAL_CUR
    ld bc, 512
    ldir
    ret

; HL = palette A, DE = palette B (both in the slot 6 window with page 39
; mapped), A = k 0-16: program every Layer 2 entry as A + (B-A)*k/16 per
; RGB333 channel, then the border (NR $4A, the fallback colour that shows
; while the ULA output is off) from lerpBorderA to lerpBorderB at the
; same k. Corrupts everything.
pal_lerp:
    ld (lerpK), a
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 0
.e:
    push bc
    call lerp_entry
    pop bc
    djnz .e
    ld hl, lerpBorderA
    ld de, lerpBorderB
    call lerp_calc
    ld a, (lerpOut)
    nextreg NR_FALLBACK, a
    ret

; A = colour 0-255 -> (HL) = its 9-bit pair.
colour9_store:
    ld (hl), a
    inc hl
    and 3
    ld (hl), 0
    ret z
    ld (hl), 1
    ret

; One entry: (HL) pair A, (DE) pair B -> two NR $44 writes; HL, DE += 2.
lerp_entry:
    call lerp_calc
    ld a, (lerpOut)
    nextreg NR_PAL_VALUE9, a
    ld a, (lerpOut1)
    nextreg NR_PAL_VALUE9, a
    ret
; The arithmetic: (HL) pair A, (DE) pair B -> lerpOut (RRRGGGBB) and
; lerpOut1 (blue LSB); HL, DE += 2.
lerp_calc:
    ld a, (hl)
    ld (lerpA0), a
    inc hl
    ld a, (hl)
    ld (lerpA1), a
    inc hl
    ld a, (de)
    ld (lerpB0), a
    inc de
    ld a, (de)
    ld (lerpB1), a
    inc de
    push hl
    push de
    ; red: bits 7-5 (rotate by 5 = swapnib + rrca, doc 00 peepholes)
    ld a, (lerpA0)
    swapnib
    rrca
    and 7
    ld c, a
    ld a, (lerpB0)
    swapnib
    rrca
    and 7
    call lerp_chan
    rrca
    rrca
    rrca                             ; bits 2-0 -> 7-5 (left 5 = right 3)
    ld (lerpOut), a
    ; green: bits 4-2
    ld a, (lerpA0)
    rrca
    rrca
    and 7
    ld c, a
    ld a, (lerpB0)
    rrca
    rrca
    and 7
    call lerp_chan
    rlca
    rlca
    ld hl, lerpOut
    or (hl)
    ld (hl), a
    ; blue: (byte0 & 3) << 1 | byte1
    ld a, (lerpA0)
    and 3
    add a, a
    ld hl, lerpA1
    or (hl)
    ld c, a
    ld a, (lerpB0)
    and 3
    add a, a
    ld hl, lerpB1
    or (hl)
    call lerp_chan
    ld b, a
    srl a
    ld hl, lerpOut
    or (hl)
    ld (hl), a
    ld a, b
    and 1
    ld (lerpOut1), a
    pop de
    pop hl
    ret

; C = channel of A (0-7), A = channel of B (0-7) -> A = C + lerpTab[k*15 + B-C+7].
lerp_chan:
    sub c
    add a, 7
    ld l, a
    ld a, (lerpK)
    ld e, a
    ld d, 15
    mul d, e
    ld a, l
    add a, e
    ld l, a
    ld h, high lerpTab
    ld a, (hl)
    add a, c
    ret
lerpK:       db 0
lerpA0:      db 0
lerpA1:      db 0
lerpB0:      db 0
lerpB1:      db 0
lerpOut:     db 0
lerpOut1:    db 0
lerpBorderA: dw 0
lerpBorderB: dw 0
