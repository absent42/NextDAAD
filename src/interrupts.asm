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
    ; plus a ONE-byte carve of the uniform table so CTC channel 0's IM2 vector
    ; (byte IM2_CTC_VEC = 6) routes to ctc_isr instead of im2_isr. IM2_CTC_STUB's
    ; high byte is $BE (== the fill), so table[V+1] already matches - only
    ; table[V]'s low byte is written. A is still $C3 (the JP opcode) from the
    ; frame stub above.
    ld (IM2_CTC_STUB), a
    ld hl, ctc_isr
    ld (IM2_CTC_STUB+1), hl
    ld a, IM2_CTC_STUB & $FF
    ld (IM2_TABLE + IM2_CTC_VEC), a      ; table[V] = low(ctc_stub); table[V+1]
                                         ; is already the $BE fill (= high stub)
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
    nextreg NR_INT_EN_1, %10000001       ; NR C4: expansion-bus INT (bit 7, reset
                                         ; default) + ULA int (bit 0), set explicitly
                                         ; so the frame tick never depends on ambient
                                         ; NextZXOS state (dev-guide example shape)
    nextreg NR_INT_EN_2, %00000001       ; enable CTC channel 0 int (NR C5). playvid
                                         ; and CTCAudio set only NR C0 and still work
                                         ; - this is dev-guide-documented belt-and-
                                         ; braces (hardware checklist verifies which)
    im 2
    ; SP11 frame-tick fix: prime the hw-IM2 daisy chain before releasing
    ; interrupts. Entering hw-IM2 mode (nextreg $C0 bit 0 = 1, above) can leave a
    ; spurious in-service latch set in the interrupt controller; until a RETI
    ; clears it the daisy chain holds that priority level in-service and can
    ; delay or DENY the LOWEST-priority source - the ULA frame interrupt (vector
    ; index 11, chapter-next-interrupts.tex daisy-chain table). That 50Hz tick
    ; drives music tempo (one aud_tick / PLY_AKY_PLAY per im2_isr), so a
    ; deprioritised ULA sags AKY and AYS playback under a CTC sample storm - the
    ; owner's coexistence symptom. Per the docs hw-IM2 is latched-until-serviced
    ; (the $C8/$C9 status bits are hardware-managed, NOT software-clearable, once
    ; in IM2 mode with interrupts enabled - chapter-next-interrupts.tex $C8/$C9),
    ; so a CLEAN chain only ever DELAYS the ULA behind the higher-priority CTC
    ; (ch0 = index 3) within a frame, never drops it; a dropped tick implies an
    ; unclean chain. playvid's field-validated CTC-audio recipe documents and
    ; clears exactly this with a dummy call/reti right after entering hw-IM2
    ; (NextZXOS DotCommands/playvid/main.c: "WHY??? investigate may be hw bug").
    ; A RETI with no source in-service is a harmless daisy-chain no-op, and run
    ; with interrupts still disabled it leaves IFF untouched (unlike RETN it does
    ; not copy IFF2) - it only scrubs the controller state, it does not return
    ; from a real interrupt. No $C8/$C9 status write is added or possible here:
    ; playvid acknowledges nothing (ei/reti only) and the docs disable the
    ; status-clear in IM2 mode - the interrupt-accept cycle and RETI ARE the
    ; acknowledge, so classic-IM2's implicit re-arm is already performed.
    ; im2_init's own epilogue is the scrub: RETI (vs a plain RET) returns to the
    ; boot caller AND emits the daisy-chain end-of-interrupt that clears the
    ; spurious latch - one opcode, +1 resident byte, instead of playvid's
    ; separate dummy call/reti (which the tight DEBUG resident budget cannot
    ; spare). Boot is interrupts-off here (the delayed EI takes effect only after
    ; the RETI), so no live interrupt is being returned from: RETI pops the
    ; call's return address exactly as RET would, and additionally scrubs the
    ; controller. IFF is untouched by RETI (unlike RETN, no IFF2 copy).
    ei
    reti

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
    ; DI sections: nr_read's bracket ~76T (~2.7us) and the tick's pointer brackets
    ; ~20T stay well under one CTC period (~50us at 20kHz); every indefinite-DI
    ; teardown calls audio_init (resets the CTC) first. The AKY player calls in
    ; aud_tick are the DELIBERATE exception - DI-bracketed at an estimated
    ; ~5.5k T (partly instruction-counted, partly unpinned - see aud_tick) (~200us,
    ; longer than a CTC period) because the player repoints SP; during sample+
    ; music coexistence that holds the DAC ~1% duty at 50Hz (accepted v0.1.0
    ; compromise; nesting there would corrupt the song - see aud_tick .gate).
    ei
    ; Save MMU 6/7 via the register-select port pair. Mainline users of
    ; $243B/$253B are DI-bracketed (hardware.asm nr_read) or run before
    ; im2_init's ei (see the SP7 Task 3 report's port audit), so this
    ; selection cannot race a mainline select. A nested ctc_isr never
    ; touches this pair, so it cannot split the select from the read.
    ; SP14c INT-1 (opus-gated): TBBLUE_REG_SEL ($243B) and
    ; TBBLUE_REG_ACC ($253B) differ only in B ($24 vs $25) - load the
    ; pair once and toggle B with inc/dec instead of four LD BC,nn
    ; reloads. Safe against a nested ctc_isr: that ISR (below, fires
    ; freely here since 'ei' ran at :149) touches only AF and HL, never
    ; BC - so B's SEL/ACC state survives a CTC edge landing anywhere in
    ; this sequence unchanged. BC itself is fully saved/restored around
    ; the whole .audio path (both register banks, via the push bc's
    ; above and the pop bc's below) so leaving B on $25 (ACC) on exit
    ; from this block has no caller-visible effect.
    ld bc, TBBLUE_REG_SEL
    ld a, $56
    out (c), a
    inc b                    ; B: SEL -> ACC ($24 -> $25)
    in d, (c)               ; D = MMU6
    dec b                    ; B: ACC -> SEL
    ld a, $57
    out (c), a
    inc b                    ; B: SEL -> ACC
    in e, (c)               ; E = MMU7
    push de
    nextreg $56, AUD_PAGE_LO
    nextreg $57, AUD_PAGE_HI
    call aud_tick
 IFDEF DEBUG
    call aud_dbg_snap        ; SP16 T7b: mirror all three PSGs + the AKY
                             ; player's position cells into the staging
                             ; ring for a scripted state dump. Bank 24 is
                             ; mapped here and every register is already
                             ; saved, so this is the only place the whole
                             ; post-tick state is legible. Self-gated on
                             ; smpFlags (a live sample owns that ring).
 ENDIF
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
; source page in slot 7, mid-ZX0 depack whose AF' parking is untouched here) -
; EXCEPT the AKY player calls, which are DI-bracketed in aud_tick: the player
; repoints SP into song data / RETTABLE, and a nested interrupt-acceptance push
; would corrupt it (see aud_tick .gate and the SP-repoint contract).
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
audReqIdx:  db 0            ; beep: period table index 0..107 (SP16 A4)
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
