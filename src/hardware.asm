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
    ; NR $06 (Peripheral 2) bits 1:0 - the AUDIO CHIP MODE - is
    ; DELIBERATELY NOT ASSERTED, and this is the record of why, so it
    ; is not re-derived. The primary documentation contradicts itself
    ; three ways on the encoding: registers.txt says "00 = YM, 01 = AY,
    ; 10 = ZXN-8950, 11 = Hold all AY in reset"; config.txt's
    ; user-facing psgmode says "AY (0), YM (1), reserved (2) and
    ; disabled (3)", inverting AY and YM; the dev guide gives a third
    ; reading of value 10 ("Disabled"). Two of the four values are
    ; silence or a different chip model, so writing one blind risks
    ; muting the game on whichever machines the other document
    ; describes correctly. The accepted consequence: two Next machines
    ; can run this interpreter with different PSG models, an AY/YM
    ; difference of envelope resolution and volume curve - timbre and
    ; loudness, not pitch. Resolve by reading the inherited value on
    ; real hardware first; only then consider asserting it. NR $09
    ; (per-AY mono bits) and NR $08 bits 5/4 (stereo mode, internal
    ; speaker) are inherited for the same reason - the or-mask above
    ; can only set bits, so it never disturbs them, and nexload
    ; explicitly refuses to touch the internal speaker ("a user
    ; setting, not a game setting").
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
    ; SP18 item 7 Task 10: mirror the same double soft-reset for channel 2's
    ; CTC. Same reasoning as channel 1 above - reached from boot and every
    ; teardown, each of which then DIs indefinitely, so this is what stops
    ; those DI sections from starving an active channel-2 feed too. Nothing
    ; drives channel 2 yet (Task 11), but the reset is unconditional and
    ; harmless either way, exactly like channel 1's at boot. AUD_CTC2_PORT
    ; is AUD_CTC_PORT with B+1 ($183B -> $193B, same low byte) - inc b
    ; instead of a fresh ld bc reload; A still holds AUD_CTC_RESET.
    inc b
    out (c), a
    out (c), a
    ld a, DAC_SILENCE               ; park the DAC at silence. DAC_SILENCE is the
    ld bc, DAC_PORT                 ; unsigned midpoint $80 (unsigned everywhere on
    out (c), a                      ; the OUT path - real-hardware and CSpect).
                                    ; See nextdaad.inc.
    out (DAC2_PORT), a              ; SP18 item 7 Task 10: park channel 2's DAC
                                    ; pair too, same silence value. Compact
                                    ; out(n),a form (video.asm's own idiom for
                                    ; these ports): the DAC hardware decodes the
                                    ; low address byte only, any upper byte (see
                                    ; nextdaad.inc), so this is exact - unlike
                                    ; the CTC above, which needs the full
                                    ; 16-bit BC port and so keeps ld bc/out(c),a.
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
