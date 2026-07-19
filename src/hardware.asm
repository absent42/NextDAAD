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
    ; SP8: DACs on for sampled sound; Turbo Sound on explicitly (both
    ; bits hard-reset to 0 - CSpect is permissive, real hardware/OS
    ; state is not guaranteed; closes a latent SP7 hardware risk too).
    ; Read-modify-write preserves NextZXOS's other peripheral bits.
    ld e, NR_PERIPH3
    call nr_read
    or %00001010                ; bit 3 DACs, bit 1 Turbo Sound
    nextreg NR_PERIPH3, a
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
    ld a, $83                       ; kill any in-flight DMA (now unused by the
    ld bc, DMA_PORT                 ; sample path but harmless - the DMA is free)
    out (c), a
    ; SP10 CTC pivot: stop the sample CTC channel (double soft-reset = timer +
    ; interrupt off) so no per-sample DAC feed survives a reset, error, or exit.
    ; Reached from boot and every teardown (h_exit, h_end, fatal, err_raise),
    ; each of which then DIs indefinitely - stopping the CTC here is what keeps
    ; those DI sections from starving an active feed.
    ld a, AUD_CTC_RESET
    ld bc, AUD_CTC_PORT
    out (c), a
    out (c), a
    ld a, DAC_SILENCE               ; park the DAC at silence. DAC_SILENCE is the
    ld bc, DAC_PORT                 ; unsigned midpoint $80 (unsigned everywhere on
    out (c), a                      ; the OUT path - real-hardware and CSpect).
                                    ; See nextdaad.inc.
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
; IFF-preserving DI bracket: the ISR (interrupts.asm) shares the
; $243B/$253B select+read pair to save/restore MMU 6/7 around aud_tick,
; so the select+read here must be atomic against interrupts - otherwise
; the ISR could re-select the port between our OUT and IN and we would
; read back the wrong register. `ld a,i` samples IFF2 into P/V; that
; result is pushed to the stack immediately (the Z80 stops updating P/V
; the instant DI executes, but any instruction between the sample and
; the DI could still clobber it, so it is saved, not held live).
; LD A,I erratum guard: an interrupt accepted at the instruction's end
; copies IFF2 AFTER acceptance cleared it - P/V reads 0 despite
; interrupts being enabled, and the bracket would then never EI again
; (the next halt hangs). Double-sample: our ISR always exits via EI,
; so a spurious 0 can only mean an interrupt just fired - the second
; sample is conclusive. Whether the Z80N core reproduces the erratum
; is unverified (see docs/hardware-test-checklist.md); the re-sample
; makes it moot either way.
nr_read:
    push bc
    ld a, i
    jp pe, .sampled         ; P/V=1: interrupts definitely enabled
    ld a, i                 ; P/V=0: re-sample (erratum window cannot
                            ; hit twice in successive instructions)
.sampled:
    push af                 ; save IFF2 in P/V on the stack
    di
    ld bc, TBBLUE_REG_SEL
    out (c), e
    ld bc, TBBLUE_REG_ACC
    in a, (c)
    ld b, a                 ; result safe from the AF pop below
    pop af                  ; P/V = saved IFF2
    ld a, b
    jp po, .noei
    ei
.noei:
    pop bc
    ret
