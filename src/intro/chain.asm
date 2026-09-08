; Hand-off: teardown in the spec's order, copy the loader to $6000 in bank 5
; and run it. The loader replays nexload v18's post-load reset list.
chain_run:
    di
    call aud_stop
    call audio_silence
    ld a, (loadHandle)
    cp $FF
    jr z, .noload
    call esx_close_a
.noload:
    ld a, (pcmHandle)
    cp $FF
    jr z, .nopcm
    call esx_close_a
.nopcm:
    nextreg NR_INT_CTRL, 0
    nextreg NR_INT_EN_1, %10000001
    nextreg NR_INT_EN_2, 0
    nextreg NR_INT_EN_3, 0
    nextreg NR_LAYERS, 0
    nextreg NR_TM_CTRL, 0
    nextreg NR_TM_XOFS_MSB, 0
    nextreg NR_TM_XOFS, 0
    nextreg NR_TM_YOFS, 0
    nextreg NR_TM_TRANSP, $0F
    ld bc, PORT_L2
    xor a
    out (c), a
    nextreg NR_L2_CTRL, 0
    nextreg NR_L2_XOFS_MSB, 0
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    nextreg NR_ULA_CTRL, 0
    call map_bank5
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), 0
    ldir
    xor a
    out ($FE), a
    call input_release_wait
    ld hl, stub_img
    ld de, STUB_ORG
    ld bc, stub_len
    ldir
    jp STUB_ORG

stub_img:
    DISP STUB_ORG
stub:
    di
    ld sp, STUB_SP
    ld a, (esxDrive)
    ld ix, s_name
    ld b, ESX_MODE_READ
    rst $08
    db ESX_F_OPEN
    jr nc, .opened              ; carry-check first: A holds the handle on
    ld a, ERR_NEX_OPEN          ; success and must reach s_hnd unclobbered
    jp fatal_nex
.opened:
    ld (s_hnd), a
    ld ix, STUB_HDR
    ld bc, 512
    rst $08
    db ESX_F_READ
    ld a, ERR_NEX_OPEN
    jp c, fatal_nex
    ld hl, 512
    or a
    sbc hl, bc
    ld a, ERR_NEX_SHORT
    jp nz, fatal_nex             ; fewer than 512 bytes came back
    ; header check: "Next" (0-3), "V1." (4-6), an ASCII digit at 7.
    ld a, (STUB_HDR+0)
    cp 'N'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+1)
    cp 'e'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+2)
    cp 'x'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+3)
    cp 't'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+4)
    cp 'V'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+5)
    cp '1'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+6)
    cp '.'
    jp nz, s_hdrbad
    ld a, (STUB_HDR+7)
    cp '0'
    jp c, s_hdrbad
    cp '9'+1
    jp nc, s_hdrbad
    ld a, (STUB_HDR+10)
    or a
    jp nz, s_hdrbad
    ld a, (STUB_HDR+139)
    or a
    jp nz, s_hdrbad
    ld hl, (STUB_HDR+140)
    ld a, h
    or l
    jp nz, s_hdrbad
    ld a, (STUB_HDR+18+5)
    or a
    ld a, ERR_NEX_BANK5
    jp nz, fatal_nex
    ; banks in file order: 5, 2, 0, 1, 3, 4, 6, 7, then 8..111. Bank 2 lands
    ; over the launcher's own code; from here on failures halt in the stub.
    ld hl, s_order
    ld b, 8
.first:
    ld a, (hl)
    inc hl
    push hl
    push bc
    call s_bank
    pop bc
    pop hl
    djnz .first
    ld a, 8
.rest:
    push af
    call s_bank
    pop af
    inc a
    cp 112
    jr nz, .rest
    ld a, (s_hnd)
    rst $08
    db ESX_F_CLOSE
    ; ---- nexload v18 post-load reset ----
    nextreg NR_COPPER_HI, 0
    nextreg NR_COPPER_LO, 0
    ld bc, TBBLUE_REG_SEL
    ld a, NR_PERIPH2
    out (c), a
    inc b
    in a, (c)
    ld (s_p2), a
    and %11111100
    nextreg NR_PERIPH2, a
    call s_field
    ld a, (s_p2)
    and %11101111
    or %00001000
    nextreg NR_PERIPH2, a
    ld bc, TBBLUE_REG_SEL
    ld a, NR_PERIPH3
    out (c), a
    inc b
    in a, (c)
    set 7, a                         ; locked paging off
    set 6, a                         ; contention off
    res 5, a                         ; ABC stereo
    set 3, a                         ; DACs
    set 2, a                         ; Timex
    set 1, a                         ; Turbo Sound
    res 0, a
    nextreg NR_PERIPH3, a
    ld a, (STUB_HDR+142)             ; expansion bus byte: zero clears the
    or a                             ; top 4 bits of NR $80 (nexload)
    jr nz, .noexp
    ld bc, TBBLUE_REG_SEL
    ld a, NR_EXPBUS
    out (c), a
    inc b
    in a, (c)
    and $0F
    nextreg NR_EXPBUS, a
.noexp:
    nextreg NR_CPU_SPEED, 3
    nextreg NR_L2_BANK, 9
    nextreg NR_L2_SHADOW, 12
    nextreg NR_L2_TRANSP, $E3
    nextreg NR_LAYERS, 1
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    nextreg NR_CLIP_IDX, 15
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 255
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 191
    nextreg NR_SPR_CLIP, 0
    nextreg NR_SPR_CLIP, 255
    nextreg NR_SPR_CLIP, 0
    nextreg NR_SPR_CLIP, 191
    nextreg NR_ULA_CLIP, 0
    nextreg NR_ULA_CLIP, 255
    nextreg NR_ULA_CLIP, 0
    nextreg NR_ULA_CLIP, 191
    nextreg NR_TM_CLIP, 0
    nextreg NR_TM_CLIP, 159
    nextreg NR_TM_CLIP, 0
    nextreg NR_TM_CLIP, 255
    nextreg $2D, 0
    nextreg $32, 0
    nextreg $33, 0
    nextreg NR_PAL_FMT, 15
    nextreg NR_PAL_CTRL, 0
    nextreg NR_PAL_INDEX, 0
    call s_ulapal
    nextreg NR_PAL_INDEX, 128
    call s_ulapal
    nextreg NR_PAL_CTRL, 16
    call s_identity
    nextreg NR_PAL_CTRL, 32
    call s_identity
    nextreg NR_FALLBACK, 0
    nextreg NR_SPR_TRANSP, $E3
    ld bc, PORT_L2
    xor a
    out (c), a
    xor a
    out ($FE), a                     ; black: nexload writes the header's
                                     ; border only with a loading screen
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), 0
    ldir
    nextreg NR_MMU0, 255
    nextreg NR_MMU1, 255
    nextreg NR_MMU2, 10
    nextreg NR_MMU3, 11
    nextreg NR_MMU4, 4
    nextreg NR_MMU5, 5
    nextreg NR_MMU6, 0
    nextreg NR_MMU7, 1
    ld sp, (STUB_HDR+12)
    ld hl, (STUB_HDR+14)
    jp (hl)

s_hdrbad:
    ld a, ERR_NEX_HDR
    jp fatal_nex

; A = bank number: load it through slots 6/7 if its flag is set.
s_bank:
    ld c, a
    ld b, 0
    ld hl, STUB_HDR+18
    add hl, bc
    ld a, (hl)
    or a
    ret z
    ld a, c
    add a, a
    nextreg NR_MMU6, a
    inc a
    nextreg NR_MMU7, a
    ld ix, WIN6
    call s_read8k
    ld ix, WIN7
s_read8k:
    ld bc, 8192
    ld a, (s_hnd)
    rst $08
    db ESX_F_READ
    jr c, s_fail
    ld hl, 8192
    or a
    sbc hl, bc
    jr nz, s_fail
    ret
s_field:                             ; one field by the raster edge, bounded
    ld de, 0                         ; 65536 polls each way (rubric 6)
.w1:
    ld bc, TBBLUE_REG_SEL
    ld a, NR_RASTER_LSB
    out (c), a
    inc b
    in a, (c)
    or a
    jr z, .w2
    dec de
    ld a, d
    or e
    jr nz, .w1
    ret
.w2:
    ld de, 0
.w3:
    ld bc, TBBLUE_REG_SEL
    ld a, NR_RASTER_LSB
    out (c), a
    inc b
    in a, (c)
    or a
    jr nz, .done
    dec de
    ld a, d
    or e
    jr nz, .w3
.done:
    ret
s_ulapal:                            ; the 16 default colours, eight times
    ld c, 8
.o:
    ld hl, s_defpal
    ld b, 16
.p:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE, a
    djnz .p
    dec c
    jr nz, .o
    ret
s_identity:
    nextreg NR_PAL_INDEX, 0
    xor a
.i:
    nextreg NR_PAL_VALUE, a
    inc a
    jr nz, .i
    ret
s_fail:                              ; a bank read failed after loading began
    ld a, 3
    out ($FE), a
    di
    halt
s_order:  db 5, 2, 0, 1, 3, 4, 6, 7
    ASSERT $ - s_order == 8          ; the file's bank data order (rubric 8)
s_defpal: db $00, $02, $A0, $A2, $14, $16, $B4, $B6, $00, $03, $E0, $E7, $1C, $1F, $FC, $FF
    ASSERT $ - s_defpal == 16        ; nexload's DefaultPalette
s_name:   db "nextdaad.nex", 0
s_hnd:    db 0
s_p2:     db 0
    ENT
stub_len equ $ - stub_img
    ASSERT STUB_ORG + stub_len <= FATAL_DEFS   ; stub must not reach its own
                                                ; header/font scratch (rubric 8)
