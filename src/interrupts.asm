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
; mainline's own use of those slots survives. Any mainline state -
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

audEnable: db 0

; SP7 audio request mailbox (Task 4). Overlay condact handlers cannot
; call bank-24 code (overlay1 owns slot 7), so they file requests in
; these resident bytes; aud_tick (ISR, bank mapped) consumes them the
; next frame. Edge-triggered: aud_tick clears every bit it consumes.
; audRequest bits: 0 beep, 1 play-effect, 2 stop-effect, 3 stop-music,
; 4 start-music, 5 init-effects.
audRequest: db 0
audReqIdx:  db 0            ; beep: period table index 0..99
audReqDur:  db 0            ; beep: duration in frames
audReqSfx:  db 0            ; play-effect: effect number (>= 1)
audReqLoop: db 0            ; start-music: 1 = loop, 0 = play once

frameCounter: dw 0
