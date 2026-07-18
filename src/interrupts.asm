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
    ld a, IM2_TABLE >> 8
    ld i, a
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
; mainline's own use of those slots survives. aud_tick now also refeeds
; the sample DMA from bank-24 state, windowing sample source pages
; through slot 7 and restoring slot 7 to AUD_PAGE_HI before it returns
; (the ISR's own MMU save/restore covers mainline's mapping regardless).
; Any mainline state -
; including AF' (the ZX0 depacker parks state there across long
; stretches) - survives an interrupt taken mid-mainline. Interrupts stay
; disabled for the whole audio path; only the very last instruction
; before reti re-enables them (matches the fast path's ei placement).
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
    ; Save MMU 6/7 via the register-select port pair. Mainline users of
    ; $243B/$253B are DI-bracketed (hardware.asm nr_read) or run before
    ; im2_init's ei (see the SP7 Task 3 report's port audit), so this
    ; selection cannot race a mainline select.
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
audReqSmpPre:   db 0        ; start-sample: DMA prescaler
audReqSmpLen:   dw 0        ; start-sample: payload bytes, low word (24-bit)
audReqSmpLenHi: db 0        ; start-sample: payload bytes, high byte
audReqSmpChunk: dw 0        ; start-sample: whole bytes copied per frame (rate/50)
audReqSmpFrac:  db 0        ; start-sample: rate mod 50 (chunk fractional part)
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
