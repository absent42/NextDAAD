; Next hardware setup and register access.

hw_init:
    nextreg NR_CPU_SPEED, 3         ; 28MHz
    nextreg NR_SPRITES, 0           ; sprites off
    nextreg NR_DISPLAY_CTRL, 0      ; Layer 2 off, Timex off
    nextreg NR_ULA_CTRL, 0          ; ULA output enabled
    nextreg NR_FALLBACK, 0          ; global fallback colour black: shows
                                    ; wherever ALL layers are transparent
                                    ; (or none covers, e.g. the top band
                                    ; beside 256x192 Layer 2 art); CSpect
                                    ; powers up non-black
    xor a
    out ($FE), a                    ; black border
    jp ula_cls

; Clear ULA pixels, set attrs to white ink on black paper.
ula_cls:
    ld hl, $4000
    ld de, $4001
    ld bc, $17FF
    ld (hl), 0
    ldir
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), $07                    ; paper 0 (black), ink 7 (white)
    ldir
    ret

; Boot-time PSG silence: select each of the three Turbo Sound Next
; PSGs via port $FFFD ($FD/$FE/$FF - the same inlined select values
; the converted Arkos player uses, src/audio/player_aky.asm) and
; write mixer R7 = $3F (all tone/noise off) and volumes
; R8/R9/R10 = 0. Register number goes to $FFFD, data to $BFFD.
; Called once from boot after hw_init, before interrupts are enabled.
; Corrupts AF, BC, DE.
audio_init:
    ld e, $FD                       ; PSG 3, then $FE (2), then $FF (1)
.psg:
    ld bc, $FFFD
    out (c), e                      ; Turbo Sound: select PSG
    ld d, 7
    ld a, $3F
    call .write                     ; R7 mixer all off
    ld d, 8
.vol:
    xor a
    call .write                     ; R8/R9/R10 volume 0
    inc d
    ld a, d
    cp 11
    jr c, .vol
    inc e
    jr nz, .psg                     ; $FD -> $FE -> $FF -> $00 done
    ret
.write:                             ; D = register, A = value
    ld bc, $FFFD
    out (c), d
    ld b, $BF
    out (c), a
    ret

; Read a Next register. E = register, returns A = value. Preserves BC.
nr_read:
    push bc
    ld bc, TBBLUE_REG_SEL
    out (c), e
    ld bc, TBBLUE_REG_ACC
    in a, (c)
    pop bc
    ret
