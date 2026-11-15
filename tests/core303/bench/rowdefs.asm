NR_SEL           equ $243B
NR_SPEED         equ $07
SPEED_28         equ 3
NR_MMU2          equ $52
NR_MMU3          equ $53
NR_MMU6          equ $56
NR_MMU7          equ $57
SRAM_PROBE_PAGE  equ 96      ; bank 48, the first expansion bank (src/banks.asm ram_detect)
SRAM_PROBE_ADDR  equ $C000   ; through MMU6
IM2_TAB          equ $BE00   ; 257 bytes of IM2_VEC
IM2_VEC          equ $BF
STACK_TOP        equ IM2_TAB
CODE_LIMIT       equ IM2_TAB - 256   ; 256 bytes of stack below the table
ROW_TXT_ROW      equ 0
LOG_TXT_ROW      equ 2
DONE_TXT_ROW     equ 3

; Row entry: ds 4 tag, dw n, dw reps, dw init, dw body, dw check, db speed, db kind.
R_N              equ 4
R_REPS           equ 6
R_INIT           equ 8
R_BODY           equ 10
R_CHECK          equ 12
R_SPEED          equ 14
R_KIND           equ 15
ROW_LEN          equ 16

; kind: CPU, or DMA | QSs | QIi | QCc = the row's Q field (interrupt state, ISR length
; index, DMA cycle length).
CPU              equ 0
DMA              equ $80
QS0              equ $00
QS1              equ $10
QS2              equ $20
QS_MASK          equ $30
QI0              equ $00
QI1              equ $08
QC2              equ 2
QC3              equ 3
FRAME_T0         equ 311 * 228   ; frame T at S=0, +3 timing 50 Hz; x2^S at speed S
ROW_TOTAL = 0

; ROW tag, n, reps, body_t, speed, kind, init, body, check
; body_t: worst-case 28 MHz T of one body pass, final ret excluded (POLL_T has it).
; init: CF set = skip with DE = reason. check (0 = none): HL = CK, CF set = BAD.
    MACRO ROW tag, units, reps, cost, speed, kind, initr, bodyr, checkr  ; no shared prefixes
    ASSERT (speed) >= 0 && (speed) <= 3
    ASSERT (reps) >= 1 && (reps) <= $FFFF && (units) >= 0 && (units) <= $FFFF
ROW_AT = $
    db tag
    ASSERT $ - ROW_AT == 4
    IF (kind) == CPU
    ASSERT ((cost) + POLL_T) * 8 < (FRAME_T0 << (speed))
    dw units, reps, initr, bodyr, checkr
    ELSE
    ASSERT ((kind) & ~(QS_MASK | QI1 | 3)) == DMA && ((kind) & QS_MASK) <= QS2 && ((kind) & QC2)
; init (a dmainit_ label, assembled above the table) starts with call dma_reset;
; a row over the DMA bound runs row_bound instead (#SKIP BOUND).
    ASSERT {b initr} == $CD && {initr + 1} == dma_reset, "DMA row init must start with call dma_reset"
    IF ((kind) & QS_MASK) == QS2
; wall W = body + poll + n x ISR, n <= W / P + 1, so W <= (body + poll + ISR) x P / (P - ISR)
ROW_ISR = CTC_ISR_W0 + ((kind) & QI1) / QI1 * (CTC_ISR_W1 - CTC_ISR_W0)
ROW_P = CTC_P0 << (speed)
ROW_OK = ((cost) + POLL_T + ROW_ISR) * 10 < (FRAME_T0 << (speed)) * (ROW_P - ROW_ISR) / ROW_P * 9
    ELSE
ROW_OK = ((cost) + POLL_T) * 10 < (FRAME_T0 << (speed)) * 9
    ENDIF
    IF ROW_OK
    dw units, reps, initr, bodyr, checkr
    ELSE
    dw units, reps, row_bound, bodyr, checkr
    ENDIF
    ENDIF
    db speed, kind
    ASSERT $ - ROW_AT == ROW_LEN
ROW_TOTAL = ROW_TOTAL + 1
    ENDM

