; Hardware setup, register access and small arithmetic helpers.

hw_init:
    nextreg NR_CPU_SPEED, 3
    nextreg NR_LAYERS, 0             ; sprites off
    nextreg NR_DISPLAY_CTRL, 0
    ld bc, PORT_L2
    xor a
    out (c), a                       ; Layer 2 hidden
    nextreg NR_ULA_CTRL, ULA_OFF     ; classic bitmap off, tilemap unaffected
    nextreg NR_FALLBACK, 0
    xor a
    out ($FE), a
    ld e, NR_PERIPH3
    call nr_read
    or %00001010                     ; DACs + Turbo Sound (hw_init precedent)
    nextreg NR_PERIPH3, a
    ld e, NR_PERIPH2
    call nr_read
    and %11110111                    ; Multiface off for the show
    nextreg NR_PERIPH2, a
    nextreg NR_L2_TRANSP, L2_TRANSP_COLOUR
    ld e, NR_PERIPH1
    call nr_read
    and %00000100
    jr z, .hz50
    ld a, 1
.hz50:
    ld (hz60), a
    jp map_bank5

map_bank5:
    nextreg NR_MMU2, PG_MAP
    nextreg NR_MMU3, PG_DEFS
    ret
map6:
    nextreg NR_MMU6, a
    ret
map7:
    nextreg NR_MMU7, a
    ret

; E = register, out A. Preserves BC. IFF-preserving DI bracket (hardware.asm).
nr_read:
    push bc
    ld a, i
    jp pe, .sampled
    ld a, i
.sampled:
    push af
    di
    ld bc, TBBLUE_REG_SEL
    out (c), e
    ld bc, TBBLUE_REG_ACC
    in a, (c)
    ld b, a
    pop af
    ld a, b
    jp po, .noei
    ei
.noei:
    pop bc
    ret

; DMA killed, both sample CTC channels double-reset, DACs parked, three
; PSGs silenced (audio_init precedent). Corrupts AF, BC, DE.
audio_silence:
    ld a, $83
    ld bc, DMA_PORT
    out (c), a
    ld a, AUD_CTC_RESET
    ld bc, AUD_CTC_PORT
    out (c), a
    out (c), a
    inc b
    out (c), a
    out (c), a
    ld a, DAC_SILENCE
    ld bc, DAC_PORT
    out (c), a
    out (DAC2_PORT), a
    out (VID_DAC_LEFT), a
    out (VID_DAC_RIGHT), a
    ld e, $FD
.psg:
    ld bc, PSG_SEL_PORT
    out (c), e
    ld d, 7
    ld a, $3F
    call psg_write
    ld d, 8
.vol:
    xor a
    call psg_write
    inc d
    ld a, d
    cp 11
    jr c, .vol
    inc e
    jr nz, .psg
    ret
; D = register, A = value, on the selected PSG. Corrupts BC.
psg_write:
    ld bc, PSG_SEL_PORT
    out (c), d
    ld b, high PSG_DATA_PORT
    out (c), a
    ret
; A = PSG select value ($FF PSG 1, $FE PSG 2, $FD PSG 3). Corrupts BC.
psg_select:
    ld bc, PSG_SEL_PORT
    out (c), a
    ret

; BC / DE -> BC = quotient, HL = remainder. DE preserved. Corrupts AF.
; The canonical restoring divide, stack-free.
div16:
    ld hl, 0
    ld a, 16
.loop:
    sla c
    rl b
    adc hl, hl
    sbc hl, de
    jr nc, .set
    add hl, de
    jr .cont
.set:
    inc c
.cont:
    dec a
    jr nz, .loop
    ret

; HL = 50 Hz frame count, out HL scaled by 6/5 (nearest) when hz60.
; Corrupts AF, BC, DE.
scale_hz:
    ld a, (hz60)
    or a
    ret z
    push hl
    ld b, h
    ld c, l
    ld de, 5
    call div16                       ; BC = frames/5, L = remainder 0-4
    ld a, l
    pop hl
    add hl, bc
    cp 3
    ret c
    inc hl
    ret

; lerpTab[k*15 + d + 7] = round(d*k/16), k 0..16, d -7..7 (255 bytes).
lerp_init:
    ld hl, lerpTab
    ld c, 0
.k:
    ld b, -7
.d:
    push bc
    ld a, b
    or a
    jp p, .pos
    neg
.pos:
    ld d, a
    ld e, c
    mul d, e
    ld a, e
    bit 7, b
    jr z, .keep
    neg
.keep:
    add a, 8
    sra a
    sra a
    sra a
    sra a
    ld (hl), a
    inc hl
    pop bc
    inc b
    ld a, b
    cp LERP_D-7
    jr nz, .d
    inc c
    ld a, c
    cp LERP_K
    jr nz, .k
    ret
