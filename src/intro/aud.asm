; Music dispatcher by musicKind. Legs: AKY (aud_aky.asm), AYS (aud_ays.asm),
; PCM (aud_pcm.asm), NDR (aud_ndaw.asm). Each later task adds its branch.
aud_open:
    ld a, (musicKind)
    cp MUS_AKY
    jp z, aky_open
    ret
aud_frame:
    ret
; Frame ISR path (all registers and MMU6/7 saved by frame_isr).
aud_isr:
    ld a, (musicKind)
    cp MUS_AKY
    jp z, aky_tick
    ret
; HL = frames. Volume 16 -> 0 over the frames; fadeVol is read by the legs.
aud_fade_begin:
    ld (fadeFrames), hl
    ld hl, 0
    ld (fadeFrame), hl
    ld a, 1
    ld (fading), a
    ld a, 16
    ld (fadeVol), a
    ret
aud_fade_step:
    ld a, (fading)
    or a
    ret z
    ld hl, (fadeFrame)
    inc hl
    ld (fadeFrame), hl
    ld de, (fadeFrames)
    call fade_k_for
    ld b, a
    ld a, 16
    sub b
    ld hl, fadeVol
    cp (hl)
    ret z
    ld (hl), a
    ret
aud_stop:
    xor a
    ld (isrAudio), a
    ret

; Rescale registers 8-10 of all three PSGs by fadeVol/16. ISR context.
psg_fade_pass:
    ld a, (fading)
    or a
    ret z
    ld e, $FD
.psg:
    ld a, e
    call psg_select
    ld d, 8
.reg:
    push de
    ld bc, PSG_SEL_PORT
    out (c), d
    in a, (c)
    call fade_scale_vol
    pop de
    push de
    call psg_write
    pop de
    inc d
    ld a, d
    cp 11
    jr c, .reg
    inc e
    jr nz, .psg
    ret

; A = AY volume register value -> A = (value & 15) * fadeVol / 16; an
; envelope-driven value (bit 4) becomes a scaled fixed 15.
fade_scale_vol:                      ; corrupts AF, DE
    bit 4, a
    jr z, .fixed
    ld a, 15
.fixed:
    and 15
    ld d, a
    ld a, (fadeVol)
    ld e, a
    mul d, e
    ld a, e
    swapnib                          ; >> 4 (doc 00)
    and 15
    ret
