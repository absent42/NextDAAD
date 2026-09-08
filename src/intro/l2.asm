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
    and 1
    nextreg NR_PAL_VALUE9, a
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
