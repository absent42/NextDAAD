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

im2_isr:
    push af
    push hl
    ; Music playback hooks here in sub-project 7.
    ; ISR invariants: touches only AF, HL and frameCounter - never MMU,
    ; esxDOS or the $C000 window. ddb_load's safety depends on this.
    ld hl, (frameCounter)
    inc hl
    ld (frameCounter), hl
    pop hl
    pop af
    ei
    reti

frameCounter: dw 0
