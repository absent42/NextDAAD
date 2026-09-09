; Music dispatcher by musicKind. Legs: AKY (aud_aky.asm), AYS (aud_ays.asm),
; PCM (aud_pcm.asm), NDR (aud_ndaw.asm). Each later task adds its branch.
aud_open:
    ld a, (musicKind)
    cp MUS_AKY
    jp z, aky_open
    cp MUS_AYS
    jp z, ays_open
    cp MUS_PCM
    jp z, pcm_open
    cp MUS_NDR
    jp z, ndaw_open
    ret
; Main-loop per-frame update (the NDR leg updates outside the frame ISR).
aud_frame:
    ld a, (musicKind)
    cp MUS_NDR
    jp z, ndaw_frame
    ret
; Frame ISR path (all registers and MMU6/7 saved by frame_isr).
aud_isr:
    ld a, (musicKind)
    cp MUS_AKY
    jp z, aky_tick
    cp MUS_AYS
    jp z, ays_tick
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
    ld a, (musicKind)
    cp MUS_NDR
    jp z, ndaw_fade_begin
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
    ld a, (musicKind)
    cp MUS_PCM
    jp z, pcm_xlat_build
    ret
aud_stop:
    xor a
    ld (isrAudio), a
    ld a, (musicKind)
    cp MUS_PCM
    jp z, pcm_stop
    cp MUS_NDR
    jp z, ndaw_stop
    ret

; AKY fade hook (player_aky.asm under PLY_AKY_FADE_HOOK). HL = the
; software register array the player is about to send; scale its R8/R9/R10
; (offsets 6, 8, 10) so an unfaded volume never reaches the chip.
aky_fade_pre:
    push af
    ld a, (fadeVol)
    cp 16
    jr z, .out                       ; no fade: the array goes out untouched
    push de
    push hl
    ld (akyFadePtr), hl
    ld a, 6
    add hl, a                        ; Z80N (doc 10); BC stays the player's
    ld a, (hl)
    ld (akyFadeRaw), a
    call fade_scale_vol
    ld (hl), a
    inc hl
    inc hl
    ld a, (hl)
    ld (akyFadeRaw+1), a
    call fade_scale_vol
    ld (hl), a
    inc hl
    inc hl
    ld a, (hl)
    ld (akyFadeRaw+2), a
    call fade_scale_vol
    ld (hl), a
    ld a, 1
    ld (akyFadeHeld), a
    pop hl
    pop de
.out:
    pop af
    ret
; Put the song's own volumes back after the send: the player leaves an
; unchanged volume in the array, so a scaled one left there would compound.
; Gated on akyFadeHeld, not fadeVol - the main loop steps fadeVol.
aky_fade_post:
    push af
    ld a, (akyFadeHeld)
    or a
    jr z, .out
    push hl
    xor a
    ld (akyFadeHeld), a
    ld hl, (akyFadePtr)
    ld a, 6
    add hl, a
    ld a, (akyFadeRaw)
    ld (hl), a
    inc hl
    inc hl
    ld a, (akyFadeRaw+1)
    ld (hl), a
    inc hl
    inc hl
    ld a, (akyFadeRaw+2)
    ld (hl), a
    pop hl
.out:
    pop af
    ret
akyFadePtr:  dw 0                    ; array the pre-hook scaled
akyFadeRaw:  ds 3                    ; its raw R8/R9/R10
akyFadeHeld: db 0                    ; 1 = a raw triple is held

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
