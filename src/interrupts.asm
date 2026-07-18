; IM2 skeleton. The vector table lives at IM2_TABLE ($BD00-$BE00,
; 257 bytes of IM2_VECTOR_BYTE) and the stub JP at IM2_STUB ($BEBE),
; both outside the assembled image and written at runtime.

im2_init:
    di
    ld hl, IM2_TABLE
    ld a, IM2_VECTOR_BYTE
    ld b, 0                 ; 256 iterations
.fill:
    ld (hl), a
    inc hl
    djnz .fill
    ld (hl), a              ; 257th byte
    ld a, $C3               ; JP opcode
    ld (IM2_STUB), a
    ld hl, im2_isr
    ld (IM2_STUB+1), hl
    ; SP10 CTC pivot: a second runtime-written stub for the per-sample DAC feed,
    ; plus a two-byte carve of the uniform table so CTC channel 0's IM2 vector
    ; (byte IM2_CTC_VEC = 6) routes to ctc_isr instead of im2_isr. IM2_CTC_STUB's
    ; high byte is $BE (== the fill), so table[V+1] already matches the fill and
    ; only the low byte at table[V] truly changes.
    ld a, $C3
    ld (IM2_CTC_STUB), a
    ld hl, ctc_isr
    ld (IM2_CTC_STUB+1), hl
    ld hl, IM2_TABLE + IM2_CTC_VEC
    ld (hl), IM2_CTC_STUB & $FF          ; table[V]   = low(ctc_stub)
    inc hl
    ld (hl), IM2_CTC_STUB >> 8           ; table[V+1] = high(ctc_stub) (= $BE fill)
    ld a, IM2_TABLE >> 8
    ld i, a
    ; Enter Next hardware IM2 mode. This GLOBAL switch relocates the ULA's own
    ; vblank vector from classic $FF to index 11 (byte 22), but the uniform
    ; table still routes byte 22 to $BEBE -> im2_isr, so the frame path is
    ; unchanged; only CTC channel 0's byte 6 is carved. The Next has no classic-
    ; Zilog CTC interrupt vector in pulse mode (every source floats $FF), so
    ; hardware IM2 is the ONLY way to give the CTC a distinct vector - both
    ; playvid and em00k CTCAudio ship exactly this shape (nextreg $C0 bit 0).
    nextreg NR_INT_CTRL, NR_INT_C0_VAL   ; hw IM2, vector base 0 (bit 3 stackless
                                         ; NMI is 0 on every cold/soft-reset boot)
    nextreg NR_INT_EN_2, %00000001       ; enable CTC channel 0 int (NR C5). playvid
                                         ; and CTCAudio set only NR C0 and still work
                                         ; - this is dev-guide-documented belt-and-
                                         ; braces (hardware checklist verifies which)
    im 2
    ei
    ret

; ISR contract (SP7 Task 3): the fast path (audEnable = 0) touches only
; AF, HL and frameCounter, exactly as before - never MMU, esxDOS or the
; $C000 window. Once audEnable is nonzero the ISR takes the full-context
; path: EVERY register pair including both shadow sets is saved before
; aud_tick runs (which corrupts anything - PLY_AKY_PLAY reuses SP
; internally but restores it per its own contract) and restored after,
; and MMU slots 6/7 are saved/restored around the bank-24 mapping so
; mainline's own use of those slots survives. aud_tick also refills the
; sample ring from bank-24 state, windowing sample source pages through
; slot 7 and restoring slot 7 to AUD_PAGE_HI before it returns (the ISR's
; own MMU save/restore covers mainline's mapping regardless).
; Any mainline state -
; including AF' (the ZX0 depacker parks state there across long
; stretches) - survives an interrupt taken mid-mainline. SP10 CTC pivot:
; the audio path now re-enables interrupts EARLY (right after the full
; context save, before the MMU save and aud_tick) so CTC channel 0's per-
; sample DAC feed (ctc_isr) nests through the multi-ms tick - see the ei
; site below for the full nesting-safety argument.
im2_isr:
    push af
    push hl
    ld hl, (frameCounter)
    inc hl
    ld (frameCounter), hl
    ld a, (audEnable)
    or a
    jr nz, .audio
    pop hl
    pop af
    ei
    reti
.audio:
    push bc
    push de
    push ix
    push iy
    ex af, af'
    push af
    exx
    push bc
    push de
    push hl
    ; SP10 CTC pivot: re-enable interrupts NOW - full context saved, but before
    ; the MMU save and the multi-ms aud_tick - so CTC channel 0's per-sample DAC
    ; feed keeps firing (nested) through the entire audio path. Safety:
    ;  (1) ULA re-entry is impossible: in hw-IM2 daisy-chain the ULA source
    ;      (index 11) is masked while its own handler is in service, and the path
    ;      finishes in << 20ms regardless.
    ;  (2) A CTC edge may land ANYWHERE below - including between a $243B select
    ;      and its $253B read, or mid-aud_smp_copy with a source page in slot 7 -
    ;      yet does no harm: ctc_isr saves only AF/HL and touches no MMU slot, no
    ;      register-select port, no bank-24 memory (only the resident ring
    ;      pointers, the always-mapped $7C00 ring, and a raw OUT to the DAC). So
    ;      the selected register, the slot 6/7 mapping, and AF' all survive intact.
    ;  (3) Only one CTC nest is ever live (period >> its ~196T body), +4 bytes of
    ;      stack. ctc_isr is non-reentrant against itself (its ei precedes reti).
    ; DI sections elsewhere stay < one CTC period (min ~50us at 20kHz): nr_read's
    ; bracket is ~76T (~2.7us); the tick's pointer brackets are ~20T; every
    ; indefinite-DI teardown calls audio_init (which resets the CTC) first.
    ei
    ; Save MMU 6/7 via the register-select port pair. Mainline users of
    ; $243B/$253B are DI-bracketed (hardware.asm nr_read) or run before
    ; im2_init's ei (see the SP7 Task 3 report's port audit), so this
    ; selection cannot race a mainline select. A nested ctc_isr never
    ; touches this pair, so it cannot split the select from the read.
    ld bc, TBBLUE_REG_SEL
    ld a, $56
    out (c), a
    ld bc, TBBLUE_REG_ACC
    in d, (c)               ; D = MMU6
    ld bc, TBBLUE_REG_SEL
    ld a, $57
    out (c), a
    ld bc, TBBLUE_REG_ACC
    in e, (c)               ; E = MMU7
    push de
    nextreg $56, AUD_PAGE_LO
    nextreg $57, AUD_PAGE_HI
    call aud_tick
    pop de
    ld a, d
    nextreg $56, a
    ld a, e
    nextreg $57, a
    pop hl
    pop de
    pop bc
    exx
    pop af
    ex af, af'
    pop iy
    pop ix
    pop de
    pop bc
    pop hl
    pop af
    ei
    reti

; SP10 CTC pivot: the per-sample DAC feeder, fired by CTC channel 0 at the
; sample rate through its carved IM2 vector. The depacker-safe memory-pointer
; variant: saves ONLY AF and HL, touches NO MMU slot, NO register-select pair,
; NO banked memory - just the resident ring pointers, the ALWAYS-mapped ring
; ($7C00, MMU3), and one raw OUT to the DAC. That is what makes it nestable
; anywhere the frame ISR EIs (mid-tick with bank 24 mapped, mid-copy with a
; source page in slot 7, mid-ZX0 depack whose AF' parking is untouched here).
; It outputs (smpPlayPtr), then advances with a branchless power-of-two wrap;
; when play has caught the producer (smpPlayPtr == smpWritePtr) it holds the
; current byte - natural hold-last; aud_smp_tick pads a DAC_SILENCE guard at W
; on drain so the held byte is silence, not stale. Cost ~167T body (~196T incl.
; IM2 ack + the 3-byte stub JP); at 16 kHz ~11% of a 28 MHz frame. ei precedes
; reti so the body is non-reentrant against a second CTC edge (period >> body);
; the nesting we require is the frame tick's, not CTC-in-CTC.
ctc_isr:
    push af
    push hl
    ld hl, (smpPlayPtr)
    ld a, (hl)
    out (DAC_PORT), a                    ; raw out (n),a: A on high addr, $DF decode
    ld a, (smpWritePtr)                  ; hold when play has caught the producer
    cp l
    jr nz, .adv
    ld a, (smpWritePtr+1)
    cp h
    jr z, .done
.adv:
    inc hl
    ld a, h                              ; branchless 1K-ring wrap ($7C00-$7FFF):
    and ((AUD_STAGE_RING-1) >> 8)        ; keep the offset's high bits...
    or (AUD_STAGE0 >> 8)                 ; ...and force the ring base ($8000 -> $7C00)
    ld h, a
    ld (smpPlayPtr), hl
.done:
    pop hl
    pop af
    ei
    reti

; Resident ring cursors, read by ctc_isr with no MMU touch and always mapped.
; smpPlayPtr = the ISR read cursor; smpWritePtr = the producer boundary
; (aud_smp_tick publishes it). Single-producer/single-consumer: the ISR only
; advances play, the tick only advances write; the tick DI-brackets its 16-bit
; accesses so the ISR never reads a torn value.
smpPlayPtr:  dw AUD_STAGE0
smpWritePtr: dw AUD_STAGE0

audEnable: db 0             ; sticky by design: armed once by the first
                            ; audio use, never re-cleared - the cheap
                            ; ISR fast path only serves pre-first-audio

; SP7 audio request mailbox (Task 4). Overlay condact handlers cannot
; call bank-24 code (overlay1 owns slot 7), so they file requests in
; these resident bytes; aud_tick (ISR, bank mapped) consumes them the
; next frame. Edge-triggered: aud_tick clears every bit it consumes.
; audRequest bits: 0 beep, 1 play-effect, 2 stop-effect, 3 stop-music,
; 4 start-music, 5 init-effects, 6 start-sample, 7 stop-sample.
; The byte is now fully allocated - no further audio triggers planned.
audRequest: db 0
audReqIdx:  db 0            ; beep: period table index 0..99
audReqDur:  db 0            ; beep: duration in frames
audReqSfx:  db 0            ; play-effect: effect number (>= 1)
audReqLoop: db 0            ; start-music: 1 = loop, 0 = play once
audReqSmpLoop:  db 0        ; start-sample: 1 = loop, 0 = play once
audReqSmpCtrl:  db 0        ; start-sample: CTC control word ($85 /16, $A5 /256)
audReqSmpTc:    db 0        ; start-sample: CTC time constant (rate + video mode)
audReqSmpLen:   dw 0        ; start-sample: payload bytes, low word (24-bit)
audReqSmpLenHi: db 0        ; start-sample: payload bytes, high byte
smpLoadedNum:   db $FF      ; keep-last: sample number resident in the
                            ; claimed page-table banks ($FF = none); owned
                            ; by aud_load_wav, reset by aud_boot_probe on
                            ; (warm) boot
sfbCount:       db 0        ; GAME.SFB effect count ((table[0]-$D000)/2);
                            ; 0 = no bank loaded - h_sfx bounds guard

; SP10 banked-stream request mailbox (client 2: AYS streamed song).
; Streams are music, so their stop/start mirror audRequest bits 3/4 and
; are consumed BEFORE the audRequest chain in aud_tick (a stale stop
; filed while audio was off can never kill a same-frame start).
; audRequest2 bits: 0 = stop stream, 1 = start stream. Edge-triggered:
; aud_tick clears each bit it consumes (single res, atomic vs mainline).
audRequest2: db 0
audReq2Loop: db 0          ; start-stream: 1 = loop, 0 = play once

frameCounter: dw 0
