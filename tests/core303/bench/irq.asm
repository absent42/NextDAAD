; Interrupt grid for DMA rows: quiet, frame, frame + CTC at 15625 Hz, in hardware IM2
; mode with NR $C0/$C4/$C5/$CC/$CD/$CE as src/interrupts.asm im2_init sets them.

NR_INT_CTRL      equ $C0
NR_INT_EN_1      equ $C4
NR_INT_EN_2      equ $C5
NR_DMA_INT_EN_1  equ $CC
NR_DMA_INT_EN_2  equ $CD
NR_DMA_INT_EN_3  equ $CE
NR_VIDEO_TIMING  equ $11
CTC0_PORT        equ $183B
CTC1_PORT        equ $193B   ; $C5/$CD enable channel 1 too
    ASSERT CTC1_PORT == CTC0_PORT + $0100
NR_CU_OFFSET     equ $64
CTC_RESET        equ $03     ; soft reset, no time constant (src/nextdaad.inc AUD_CTC_RESET)
CTC_CW16         equ $85     ; int, timer, /16, auto trigger, TC follows (AUD_CTC_CW16)
; hw IM2 vector = index * 2: CTC 0 is index 3, ULA index 11 (30204 zxnext.vhd:2218-2226,2286)
IM2_V_CTC0       equ 6
IM2_V_ULA        equ 22
; +3 50 Hz ULA int at vc 1; NR $1E/$1F (cvc) is vc - 64 mod 311 with NR $64 = 0 (nr64_zero)
; (30204 zxula_timing.vhd:199,203,204,462)
FRAME_INT_LINE   equ 248
LPF              equ 311
CTC_P0           equ 224     ; CPU T per CTC tick at S=0: 28 MHz / 8 / 15625; x2^S at speed S

; ISR lengths in T, IM2 acknowledge and stub JP included: documented and 28 MHz worst
; case (+1 per opcode fetch and memory read). Busy loops: frame 20 T, CTC 25 T a pass.
FR_FIX           equ 480
FR_WFIX          equ 584
CTC_FIX          equ 100
CTC_WFIX         equ 122
FR_N0            equ (1000 - FR_FIX) / 20
FR_N1            equ (4000 - FR_FIX) / 20
CTC_N0           equ (150 - CTC_FIX) / 25
CTC_N1           equ (400 - CTC_FIX) / 25
    ASSERT FR_FIX + FR_N0 * 20 == 1000 && FR_FIX + FR_N1 * 20 == 4000 && FR_N1 <= 255
    ASSERT CTC_FIX + CTC_N0 * 25 == 150 && CTC_FIX + CTC_N1 * 25 == 400
FR_ISR_W0        equ FR_WFIX + FR_N0 * 24
FR_ISR_W1        equ FR_WFIX + FR_N1 * 24
CTC_ISR_W0       equ CTC_WFIX + CTC_N0 * 30
CTC_ISR_W1       equ CTC_WFIX + CTC_N1 * 30

; Save the boot interrupt NRs for irq_restore. Corrupts AF, BC, DE, HL.
irq_init:
    ld hl, irqNrList
    ld de, irqSaved
    ld b, IRQ_NR_COUNT
.nr:
    ld a, (hl)
    inc hl
    push bc
    call nr_read
    pop bc
    ld (de), a
    inc de
    djnz .nr
    ret

; A = state, B = ISR length index. DI, CTC 0 stopped, every pending latch dropped,
; then NextDAAD's hardware IM2 setup with the ULA int in states 1 and 2 only.
; Leaves DI. Corrupts AF, BC, HL.
irq_setup:
    di
    push bc
    push af
    call ctc_stop
    nextreg NR_INT_CTRL, 0       ; pulse mode clears im2_int_req (30204 im2_peripheral.vhd:170)
    nextreg NR_INT_CTRL, 1       ; hw IM2, vector base 0
    pop af
    pop bc
    or a
    ld a, %10000000              ; quiet: expansion bus only, no ULA int
    jr z, .c4
    ld a, %10000001              ; expansion bus + ULA int, as im2_init
.c4:
    nextreg NR_INT_EN_1, a
    nextreg NR_INT_EN_2, %00000011
    nextreg NR_DMA_INT_EN_1, 0
    nextreg NR_DMA_INT_EN_2, %00000011
    nextreg NR_DMA_INT_EN_3, 0
    ld a, b
    or a
    ld a, FR_N0
    ld c, CTC_N0
    jr z, .len
    ld a, FR_N1
    ld c, CTC_N1
.len:
    ld (frame_isr.cnt + 1), a
    ld a, c
    ld (ctc_isr.cnt + 1), a
    ld a, low irq_frame_stub
    ld (IM2_TAB + IM2_V_ULA), a
    ld a, low irq_ctc_stub
    ld (IM2_TAB + IM2_V_CTC0), a
    ld a, high IM2_TAB
    ld i, a
    im 2
    xor a
    ld (irqLatMax), a
    call irq_reti                ; daisy-chain scrub under DI, as im2_init's epilogue
    ret
irq_reti:
    reti

; A = 0 quiet | 1 frame | 2 frame + CTC, B = ISR length index 0|1. Ends EI. States 1
; and 2 wait for one frame ISR, then clear the latency it carried from the DI time.
; Out: CF set, DE = reason, if no frame ISR came. Corrupts AF, BC, DE, HL.
irq_state:
    ld (irqS), a
    call irq_setup
    ld a, (irqS)
    cp 2
    call z, ctc_start
    ei
    ld a, (irqS)
    or a
    ret z
    ld a, (irqTick)
    ld c, a
    ld hl, 0                     ; 65536 polls: over 5 frames at any speed
.wait:
    ld a, (irqTick)
    cp c
    jr nz, .ticked
    dec hl
    ld a, h
    or l
    jr nz, .wait
    ld de, irqTxtNoTick
    scf
    ret
.ticked:
    xor a
    ld (irqLatMax), a
    ret

; After the timed reps: DI, CTC 0 and 1 stopped. The hardware IM2 setup stays until irq_restore.
irq_quiet:
    di
; CTC 0 and 1: double soft reset each (src/hardware.asm audio_init). Corrupts AF, BC.
ctc_stop:
    ld bc, CTC0_PORT
    ld a, CTC_RESET
    out (c), a
    out (c), a
    inc b                        ; CTC1_PORT
    out (c), a
    out (c), a
    ret

; NR $64 saved and zeroed, so FRAME_INT_LINE holds; it applies at vc 64, so two
; backward steps of the line (one is a frame or more) are waited, bounded. Corrupts all.
nr64_zero:
    ld a, NR_CU_OFFSET
    call nr_read
    ld (irqNr64), a
    nextreg NR_CU_OFFSET, 0
    ld hl, 0
    ld (irqLeft), hl             ; 65536 polls
    ld e, 2
    CLK_LINE
    ld (irqPrev), hl
.lp:
    CLK_LINE
    ld bc, (irqPrev)
    ld (irqPrev), hl
    sbc hl, bc                   ; CF = 0 from CLK_LINE; CF = the line went back
    jr nc, .same
    dec e
    ret z
.same:
    ld hl, (irqLeft)
    dec hl
    ld (irqLeft), hl
    ld a, h
    or l
    jr nz, .lp
    ret

; NR $64 back to its boot value.
nr64_restore:
    ld a, (irqNr64)
    nextreg NR_CU_OFFSET, a
    ret

; CTC 0 at 15625 Hz: time constant per NR $11 mode (src/video.asm vidCtcTcNxvStereo).
; Corrupts AF, BC, E, HL.
ctc_start:
    ld a, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld hl, irqTcTab
    add hl, a
    ld e, (hl)
    ld bc, CTC0_PORT
    ld a, CTC_RESET
    out (c), a
    out (c), a
    ld a, CTC_CW16
    out (c), a
    out (c), e                   ; time constant: the timer starts
    ret

; A = worst frame-ISR latency in lines since irq_setup or the irq_state tick.
irq_lat_max:
    ld a, (irqLatMax)
    ret

; Back to the boot interrupt NRs and the stub table. Corrupts AF, BC, DE, HL.
irq_restore:
    di
    call ctc_stop
    nextreg NR_INT_CTRL, 0       ; drop pending latches before the boot mode returns
    ld hl, irqNrList
    ld de, irqSaved
    ld b, IRQ_NR_COUNT
.nr:
    push bc
    ld bc, NR_SEL
    ld a, (hl)
    out (c), a
    inc b
    ld a, (de)
    out (c), a                   ; C0 bits 2:1 read the IM mode and are not written
    pop bc
    inc hl
    inc de
    djnz .nr
    ld a, IM2_VEC
    ld (IM2_TAB + IM2_V_ULA), a
    ld (IM2_TAB + IM2_V_CTC0), a
    ret

; Frame ISR: raster line at entry stored, latency past FRAME_INT_LINE (mod LPF, capped
; at 255) worst kept. NR select read back and restored (30204 zxnext.vhd:5095).
; T doc/worst per line; fixed part FR_FIX/FR_WFIX on the no-wrap, no-cap path.
frame_isr:                       ; IM2 ack 19/21 + stub jp 10/13
    push af                      ; 11/12
    push bc                      ; 11/12
    push de                      ; 11/12
    push hl                      ; 11/12
    ld bc, NR_SEL                ; 10/13
    in e, (c)                    ; 12/14
    CLK_LINE                     ; 146/177, CF = 0
    ld bc, NR_SEL                ; 10/13
    out (c), e                   ; 12/14
    ei                           ; 4/5 CTC ISR nests from here
    ld (irqLine), hl             ; 16/19
    ld de, FRAME_INT_LINE        ; 10/13
    sbc hl, de                   ; 15/17
    jr nc, .pos                  ; 12/14
    ld de, LPF
    add hl, de
.pos:
    ld a, h                      ; 4/5
    or a                         ; 4/5
    jr z, .lo                    ; 12/14
    ld l, $FF
.lo:
    ld a, (irqLatMax)            ; 13/17
    cp l                         ; 4/5
    jr nc, .old                  ; 12/14 (new worst: 11/14)
    ld a, l
.old:
    ld (irqLatMax), a            ; 13/16
    ld a, (irqTick)              ; 13/17
    inc a                        ; 4/5
    ld (irqTick), a              ; 13/16
    nop                          ; 4/5 x2 pad
    nop
.cnt:
    ld a, 0                      ; 7/9 count, set by irq_setup
.busy:
    nop                          ; 4/5
    dec a                        ; 4/5
    jr nz, .busy                 ; 12/14, last 7/9
    pop hl                       ; 10/13
    pop de                       ; 10/13
    pop bc                       ; 10/13
    pop af                       ; 10/13
    ei                           ; 4/5
    reti                         ; 14/18

; CTC 0 ISR: MMU-free, no NR select, as src/interrupts.asm ctc_isr. T doc/worst.
ctc_isr:                         ; IM2 ack 19/21 + stub jp 10/13
    push bc                      ; 11/12
    inc bc                       ; 6/7 x3 pad, B reloaded below
    inc bc
    inc bc
    nop                          ; 4/5 x3 pad
    nop
    nop
.cnt:
    ld b, 0                      ; 7/9 count, set by irq_setup
.busy:
    nop                          ; 4/5 x3
    nop
    nop
    djnz .busy                   ; 13/15, last 8/10
    pop bc                       ; 10/13
    ei                           ; 4/5
    reti                         ; 14/18

irqNrList:   db NR_INT_CTRL, NR_INT_EN_1, NR_INT_EN_2, NR_DMA_INT_EN_1, NR_DMA_INT_EN_2, NR_DMA_INT_EN_3
IRQ_NR_COUNT equ $ - irqNrList
irqSaved:    ds IRQ_NR_COUNT
irqTcTab:    db 112, 114, 117, 120, 124, 128, 132, 108
    ASSERT $ - irqTcTab == 8
irqS:        db 0
irqLine:     dw 0            ; raster line the last frame ISR ran at
irqLatMax:   db 0
irqTick:     db 0
irqNr64:     db 0
irqPrev:     dw 0
irqLeft:     dw 0
irqTxtNoTick: db "NOIRQ", 0
