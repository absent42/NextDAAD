; zxnDDMA (core 3.03.00 blitter) definitions and rules. Port DMA_PORT ($6B) only.
; Command bytes and semantics: zxnDDMA guide 2.5-2.9 (NextZXOS 26.11 docs).
;
; RULES for every blit:
; State: outside a blit the mode flags are 0, and every DMA user sends its own full
;   program. A blit starts with DDMA_RESET and a full program (cycle length 2 on both
;   ports, WR5 $82) and ends with DDMA_MODE, 0. The reset puts both port timings back
;   to 3 cycles and clears the prescaler, flags, 2D values and fill value.
; Interrupt: arm with interrupts enabled, never under DI (an admitted interrupt left
;   pending holds the transfer for good). No transfer above DDMA_XFER_MAX bytes; the
;   tilemap scroll alone may reach DDMA_SCROLL_MAX. The frame interrupt waits that long.
; Reload: a short reload between rows relies on nothing reprogramming the DMA in
;   between; no interrupt handler or interrupt hook may touch port $6B.
; Tail: each time a transfer yields to an admitted interrupt the CPU runs ONE mainline
;   instruction first. So every arm is followed at once by DDMA_PAD: enough harmless
;   instructions to outlast the transfer. Nothing sits between the arm and its pad.

DDMA_RESET      equ $C3
DDMA_LOAD       equ $CF
DDMA_ENABLE     equ $87
DDMA_EXT_A      equ $D7     ; n: port A address bits 23:16
DDMA_EXT_B      equ $DB     ; n: port B address bits 23:16
DDMA_MODE       equ $DF     ; n: mode flags, all set at once
DDMA_ROWLEN     equ $E3     ; lo hi: bytes per row (2D)
DDMA_ROWS       equ $E7     ; lo hi: rows (2D)
DDMA_STRIDE_A   equ $EB     ; lo hi: source row pitch (2D)
DDMA_STRIDE_B   equ $EF     ; lo hi: destination row pitch (2D)
DDMA_FILLVAL    equ $F7     ; n: fill value

DDMA_F_PHYS     equ %00000001   ; 22-bit SRAM addresses, no MMU
DDMA_F_2D       equ %00000010   ; rows x row length with strides
DDMA_F_FILL     equ %00001000   ; no read, the fill value is written

DDMA_WR0        equ %01111101   ; A -> B, port A address + block length follow
DDMA_WR0_ADDR   equ %00011101   ; A -> B, port A address only (short reload)
DDMA_WR1        equ %01010100   ; port A memory, incrementing, timing byte follows
DDMA_WR2        equ %01010000   ; port B memory, incrementing, timing byte follows
DDMA_CYCLE      equ 2           ; the timing byte: cycle length 2
DDMA_WR4        equ %10101101   ; continuous, port B address follows
DDMA_WR5        equ %10000010   ; stop at end of block

DDMA_PHYS_BASE  equ 4           ; extended byte of bank 0 ($40000)

DDMA_XFER_MAX   equ 4096        ; picture transfer cap: about 1 ms of held frame interrupt
DDMA_SCROLL_MAX equ 4960        ; tilemap scroll: 31 rows x 160 bytes, one transfer
    ASSERT low DDMA_XFER_MAX == 0 && DDMA_XFER_MAX <= 16384

; Pad sizing. Two CTC channels may interrupt a transfer (im2_init, NR $CD = %11).
DDMA_T_BYTE_MAX     equ 8       ; T per byte, slowest cycle-2 row measured on silicon
DDMA_CTC_CHANNELS   equ 2
CTC_PERIOD_MIN      equ 1344    ; 16 x TC at AUD_RATE_MAX on the fastest clock
    ASSERT AUD_RATE_MAX == 20000        ; a new ceiling needs a new CTC_PERIOD_MIN
CTC_ISR_T_MAX       equ 256     ; ctc_isr_pair worst path: 218 + ack 19 + stub 10 = 247
DDMA_PAD_DEN        equ CTC_PERIOD_MIN - DDMA_CTC_CHANNELS*CTC_ISR_T_MAX
    ASSERT DDMA_PAD_DEN > 0

; Harmless instructions to follow an arm of at most `bytes` bytes. Corrupts B.
    MACRO DDMA_PAD bytes
    ASSERT ((bytes)*DDMA_T_BYTE_MAX*DDMA_CTC_CHANNELS + DDMA_PAD_DEN - 1)/DDMA_PAD_DEN + 2 <= 255
    ld b, ((bytes)*DDMA_T_BYTE_MAX*DDMA_CTC_CHANNELS + DDMA_PAD_DEN - 1)/DDMA_PAD_DEN + 2
    djnz $
    ENDM
