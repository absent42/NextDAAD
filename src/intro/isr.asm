; Hardware IM2 (interrupts.asm layout): table $BD00 of $BE, frame stub
; $BEBE, CTC channel 0 stub $BEC2 on vector byte 6.
im2_init:
    di
    ld hl, IM2_TABLE
    ld a, IM2_VECTOR_BYTE
    ld b, 0
.fill:
    ld (hl), a
    inc hl
    djnz .fill
    ld (hl), a
    ld a, $C3
    ld (IM2_STUB), a
    ld hl, frame_isr
    ld (IM2_STUB+1), hl
    ld a, $C3
    ld (IM2_CTC_STUB), a
    ld hl, pcm_isr_idle
    ld (IM2_CTC_STUB+1), hl
    ld a, IM2_CTC_STUB & $FF
    ld (IM2_TABLE + IM2_CTC_VEC), a
    ld a, IM2_TABLE >> 8
    ld i, a
    im 2
    nextreg NR_INT_CTRL, 1
    nextreg NR_INT_EN_1, %10000001
    nextreg NR_INT_EN_2, %00000001
    nextreg NR_DMA_INT_EN_1, 0
    nextreg NR_DMA_INT_EN_2, 0
    nextreg NR_DMA_INT_EN_3, 0
    ret

pcm_isr_idle:
    ei
    reti

; Frame tick: counter and flag; with isrAudio set, full context save,
; MMU6/7 save, aud_isr, restore. No DI around player calls (AKY lesson).
frame_isr:
    push af
    push hl
    ld hl, (frameCounter)
    inc hl
    ld (frameCounter), hl
    ld a, 1
    ld (frameFlag), a
    ld a, (isrAudio)
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
    ld bc, TBBLUE_REG_SEL
    ld a, NR_MMU6
    out (c), a
    inc b
    in d, (c)
    dec b
    ld a, NR_MMU7
    out (c), a
    inc b
    in e, (c)
    push de
    call aud_isr
    pop de
    ld a, d
    nextreg NR_MMU6, a
    ld a, e
    nextreg NR_MMU7, a
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

; Needs interrupts enabled (frame_isr sets frameFlag). Bounded to 65536
; polls (rubric 6); on expiry, returns as if the frame had ticked.
; Corrupts AF, BC.
wait_frame:
    ld bc, 0
.w:
    ld a, (frameFlag)
    or a
    jr nz, .got
    dec bc
    ld a, b
    or c
    jr nz, .w
.got:
    xor a
    ld (frameFlag), a
    ret
