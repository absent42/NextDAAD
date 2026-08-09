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
    ; SP18 item 7 Task 10: channel 2's carve skips the stub-trampoline
    ; indirection channel 1 uses just above. That indirection is NOT
    ; kept for fill-byte economy alone (letting table[V+1], the target's
    ; high byte, stay the uniform $BE fill unwritten) - it is ALSO the
    ; runtime hijack point: video.asm rewrites IM2_CTC_STUB+1 (this same
    ; 3-byte JP's target field) to swap channel 0's ISR to
    ; video_ctc_isr_stereo for a clip's duration and back, leaving the
    ; table entry itself untouched throughout. The stub is what makes
    ; that swap a single 2-byte write instead of a table rewrite -
    ; removing it (e.g. by "optimising" channel 1 to this same direct
    ; write) would silently stop installing video's stereo ISR.
    ; Channel 2 has NO such stub because nothing today repoints channel
    ; 2's ISR at runtime - the direct table write below is safe only in
    ; that absence, which is why it costs less. A future channel-2
    ; hijack (mirroring video's channel-1 trick) must either install a
    ; JP at IM2_CTC2_STUB first and point the table at IT instead
    ; (channel 1's shape), or keep writing IM2_TABLE + IM2_CTC2_VEC
    ; directly on each hijack/release, as this carve already does here.
    ld hl, ctc2_isr
    ld (IM2_TABLE + IM2_CTC2_VEC), hl
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
    nextreg NR_INT_EN_2, %00000011       ; enable CTC channels 0+1 int (NR C5).
                                         ; playvid and CTCAudio set only NR C0 and
                                         ; still work for their own single channel -
                                         ; this is dev-guide-documented belt-and-
                                         ; braces (hardware checklist verifies which).
                                         ; SP18 item 7 Task 10: bit 1 added for
                                         ; channel 2's CTC (ctc2_isr, above) - same
                                         ; belt-and-braces reasoning, one channel over.
    ; DMA PRE-EMPTION PERMISSIONS (NR $CC/$CD/$CE) - 2026-08-03, CONFIRMED
    ; ON SILICON. The zxnDMA's mem-to-mem transfers run in CONTINUOUS mode,
    ; which "runs to completion without allowing the CPU to run" (dev guide
    ; chapter-next-dma.tex, WR4 bits 6-5; tools/NextZXOS/docs/extra-hw/dma/
    ; zxndma.txt says the same). The CPU is BUS-STALLED for the whole
    ; transfer and no ei can shorten that, so a picture blit used to hold
    ; ctc_isr off the DAC for ~1900 T per chunk - not a lost tick (hardware
    ; IM2 CACHES a held request) but a late one, which pulse-width-mangles
    ; the reconstruction staircase. That is audible, and it is what the
    ; owner heard as gross distortion on tests/sfxdi.dsf. In hardware IM2
    ; (nextreg $C0 bit 0, set above) the stall can be broken PER SOURCE:
    ; $CC/$CD/$CE choose which interrupters may interrupt a running DMA
    ; (chapter-next-interrupts.tex:296-301 for the feature, :512-564 for the
    ; bit layouts). With these three writes plus the deletion of dma_copy's
    ; per-chunk di/ei, a 16 kHz sampled effect stayed CLEAN through a forty-
    ; call GFX 0 0 burst that was grossly distorted before (owner, real
    ; Next, HDMI). An independent LDIR-only build was clean too, so the
    ; bus-stall mechanism is confirmed twice over.
    ;
    ; ALL THREE ARE WRITTEN EXPLICITLY. The dev guide gives the bit layouts
    ; but states NO reset value for any of the three registers, so the
    ; ambient default is unknown in both directions - and both directions
    ; matter. A restrictive default would deny the permission this fix
    ; needs; a PERMISSIVE one would mean the frame ISR could already have
    ; been pre-empting every DMA in the tree, with only the DI suppressing
    ; it. Writing all three settles it either way.
    nextreg NR_DMA_INT_EN_1, 0           ; $CC = 0: neither the ULA frame
                                         ; interrupt (bit 0) nor the line
                                         ; interrupt (bit 1) may EVER interrupt
                                         ; a DMA. MANDATORY, not tidiness:
                                         ; im2_isr's full-context path REMAPS
                                         ; MMU6/7 around aud_tick, so a
                                         ; transfer left running across a frame
                                         ; tick would read and write through the
                                         ; AUDIO banks' mapping instead of the
                                         ; caller's - a corrupt picture and
                                         ; trashed audio state. That hazard is
                                         ; the ORIGINAL reason dma_copy carried
                                         ; a DI at all (see its header in
                                         ; overlay2.asm); $CC = 0 is what
                                         ; replaces the DI, and it must never be
                                         ; relaxed without re-reading that
                                         ; hazard note.
    nextreg NR_DMA_INT_EN_2, %00000011   ; $CD bit 0 = CTC channel 0, the DAC
                                         ; sample timer - one of the two sources
                                         ; allowed to pre-empt a DMA. Safe because
                                         ; its ISR is MMU-free BY EXPLICIT CONTRACT:
                                         ; ctc_isr (below) saves only AF/HL and
                                         ; touches no MMU slot, no $243B/$253B
                                         ; register-select pair, no banked
                                         ; memory and never the DMA port - the
                                         ; same contract that already makes it
                                         ; nestable inside im2_isr. A transfer
                                         ; resumed after it therefore sees
                                         ; exactly the mapping it was armed
                                         ; with. Channels 2-7 stay barred here
                                         ; and are not enabled in $C5 either.
                                         ; NOTE FOR THE VIDEO PATH: video.asm
                                         ; repoints IM2_CTC_STUB to
                                         ; video_ctc_isr_stereo while a clip
                                         ; plays, so this permission also
                                         ; applies to the video player's own DMA
                                         ; kernels. That ISR meets the same
                                         ; contract (AF/IX only, the DAC pair,
                                         ; the MMU3 ring pinned for the whole
                                         ; session, RETI exit). Since SP18
                                         ; item 5 the video kernels run
                                         ; unbracketed and this permission is
                                         ; their only guard (silicon leg
                                         ; PASSED 2026-08-08: corruption gate
                                         ; byte-exact on every staged clip
                                         ; including the fill path; core
                                         ; 3.02.04).
                                         ; SP18 item 7 Task 10: bit 1 = CTC
                                         ; channel 1, SFX channel 2's DAC sample
                                         ; timer, admitted under the IDENTICAL
                                         ; MMU-free/RETI contract - ctc2_isr
                                         ; (above) saves only AF/HL, touches no
                                         ; MMU slot, no register-select pair, no
                                         ; banked memory and never the DMA port,
                                         ; the sole condition of admission stated
                                         ; above. Nothing drives channel 2 yet
                                         ; (Task 11 wires the pump/mailbox), so
                                         ; this permission is armed ahead of use,
                                         ; exactly as channel 0's already is
                                         ; before the first sample plays.
    nextreg NR_DMA_INT_EN_3, 0           ; $CE = 0: no UART source may interrupt
                                         ; a DMA. Nothing here uses the UARTs
                                         ; and $C6 is never written, so this
                                         ; closes an ambient default that would
                                         ; otherwise simply be inherited.
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
    ; SFX stream refiller (SP18 item 7 Task 6), AFTER the pump: it tops
    ; the effect windows up from the card in short CMD18 bursts, and is
    ; self-gated on cardBusy and on the channel's SMPB_FLAGS bits 2/4.
    ; It needs exactly what aud_tick returns with - page 48 in slot 6
    ; (the channel block, its window descriptor) - and it hands slot 6
    ; back as AUD_PAGE_LO itself; only slot 7 has to be swapped, because
    ; SFX_PAGE shares that window with the state page. Slot 7 goes back
    ; to AUD_PAGE_HI for aud_dbg_snap's $FFE0 reads (the ISR's own MMU
    ; restore below would cover mainline regardless).
    ; SITED HERE, NOT INSIDE aud_tick, for one reason: page 48 is the
    ; binding budget of this sub-project and the two nextregs plus the
    ; call cost 11 of its bytes, against 59 free in this resident region.
    ; Nothing else moves - this is still one call per frame, immediately
    ; after the sample pump, with the same slot 6/7 state either way.
    nextreg NR_MMU7, SFX_PAGE
    call aud_sfx_refill
    nextreg NR_MMU7, AUD_PAGE_HI
 IFDEF DEBUG
    call aud_dbg_snap        ; SP16 T7b: mirror all three PSGs + the AKY
                             ; player's position cells into the staging
                             ; ring for a scripted state dump. Bank 24 is
                             ; mapped here and every register is already
                             ; saved, so this is the only place the whole
                             ; post-tick state is legible. Self-gated on
                             ; SMPB_FLAGS (a live sample owns that ring).
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
; SINCE 2026-08-03 THAT CONTRACT IS ALSO WHAT LETS THIS ISR PRE-EMPT A
; RUNNING zxnDMA (nextreg $CD bit 0, set in im2_init): a transfer that
; resumes after this body must find the MMU map exactly as it was armed,
; which is true only because nothing here writes a slot. Adding an MMU
; write, a $243B/$253B select, a banked-memory access or a DMA-port touch
; to this routine would silently corrupt every DMA in the tree.
; The exit instruction is part of the contract too: RETI is what hands
; the bus back to a suspended DMA - never change it to RET.
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

; SP18 item 7 Task 10: channel 2's per-sample DAC feeder, fired by CTC
; channel 1 through its carved IM2 vector (byte IM2_CTC2_VEC = 8). SAME
; CONTRACT as ctc_isr above, verbatim: saves ONLY AF and HL, touches NO
; MMU slot, NO register-select pair, NO banked memory - just this
; channel's resident ring pointers, the ring at AUD_STAGE2 (a candidate
; address, OP1/V1-gated - see nextdaad.inc), and one raw OUT to
; DAC2_PORT. That is what makes it nestable anywhere the frame ISR EIs,
; and it is the sole condition of admission to NR $CD (DMA pre-emption
; permission, im2_init) - identical reasoning to ctc_isr's own header,
; not repeated here. RETI is part of the contract: never change it to
; RET. It outputs (smp2PlayPtr), then advances with the same
; branchless power-of-two wrap as channel 1, holding the last byte when
; play has caught the producer (aud_smp_tick pads a DAC_SILENCE guard
; at W on drain, exactly as channel 1's tick does). Cost ~167T body,
; same shape as ctc_isr; ei precedes reti so the body is non-reentrant
; against a second CTC edge on this same channel.
; Nothing starts channel 2 yet (Task 11 wires the pump/mailbox) - this
; ISR is wired and armable but its ring stays at rest until then.
ctc2_isr:
    push af
    push hl
    ld hl, (smp2PlayPtr)
    ld a, (hl)
    out (DAC2_PORT), a
    ld a, (smp2WritePtr)
    cp l
    jr nz, .adv
    ld a, (smp2WritePtr+1)
    cp h
    jr z, .done                  ; play caught producer: hold last byte
.adv:
    inc hl
    ld a, h
    and (AUD_STAGE2_RING-1) >> 8
    or AUD_STAGE2 >> 8
    ld h, a
    ld (smp2PlayPtr), hl
.done:
    pop hl
    pop af
    ei
    reti

; Resident ring cursors for channel 2, same discipline as smpPlayPtr/
; smpWritePtr above (single-producer/single-consumer, tick DI-brackets
; its 16-bit accesses).
smp2PlayPtr:  dw AUD_STAGE2
smp2WritePtr: dw AUD_STAGE2

; Channel 2's pump state block, sfxChan1, is resident too but is NOT
; declared here: this file is entirely pre-anchor (included ahead of
; engine.asm's ALIGN 256) and the pre-flags pad it draws on has no room
; for a block this size. It sits in the post-anchor resident tail, declared
; at the foot of main.asm beside sfx_page_call. Channel 1's block,
; sfxChan0, is page-48 data (audiobank.asm) - the asymmetry is a budget
; decision and nothing else, since every aud_smp_* routine reaches its
; block IX-relative and so does not care which it gets.

audEnable: db 0             ; sticky by design: armed once by the first
                            ; audio use, never re-cleared - the cheap
                            ; ISR fast path only serves pre-first-audio

cardBusy:  db 0             ; nonzero while mainline is inside an esxDOS
                            ; call (SPI wire + DivMMC paging both live);
                            ; the SFX refiller (frame ISR) must not touch
                            ; the card while this is set - single-byte
                            ; store, atomic against the ISR

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
; The keep-last number used to be a single resident byte here
; (smpLoadedNum). SP18 item 7 Task 12 retired it: with two channels the
; question is not "what is loaded" but "WHICH CHANNEL caches this
; effect", so the number lives per channel in SMPB_KEEP instead.
sfbCount:       db 0        ; GAME.SFB effect count ((table[0]-$D000)/2);
                            ; 0 = no bank loaded - h_sfx bounds guard

; SP10 banked-stream request mailbox (client 2: AYS streamed song), and
; since SP18 item 7 Task 11 also sampled-effect CHANNEL 2's stop/start.
; Streams are music, so their stop/start mirror audRequest bits 3/4 and
; are consumed BEFORE the audRequest chain in aud_tick (a stale stop
; filed while audio was off can never kill a same-frame start).
; audRequest2 bits:
;   0 = stop stream          2 = stop sample channel 2
;   1 = start stream         3 = start sample channel 2
; Bits 2/3 are the exact mirror of audRequest bits 7/6 (channel 1's
; stop/start), consumed stop-before-start in the same pass, and are
; equally safe to halt-wait on from mainline - video.asm's entry abort
; files audRequest bit 7 (channel 1) and audRequest2 bit 2 (channel 2,
; this byte) and waits until BOTH are clear.
; The audReqSmp* PARAMETER cells below are shared by both channels; see
; the limitation stated at aud_tick's header (audiobank.asm).
; Edge-triggered: aud_tick clears each bit it consumes (single res,
; atomic vs mainline).
audRequest2: db 0
audReq2Loop: db 0          ; start-stream: 1 = loop, 0 = play once

frameCounter: dw 0
