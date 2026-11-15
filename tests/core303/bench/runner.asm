run_table:
    ld (rtTab), hl
    ld de, ROW_LEN
    ld bc, 0
.count:
    ld a, (hl)
    or a
    jr z, .counted
    add hl, de
    inc bc
    jr .count
.counted:
    ld (rtTotal), bc
    ld hl, 0
    ld (rtNum), hl
    ld hl, (rtTab)
.row:
    ld a, (hl)
    or a
    ret z
    ld (rtRow), hl
    ld hl, (rtNum)
    inc hl
    ld (rtNum), hl
    call rt_progress
    ld ix, (rtRow)
    ld a, (ix + R_SPEED)
    nextreg NR_SPEED, a
    ld a, (ix + R_KIND)
    ld (rtKind), a
    or a
    jr z, .init
    xor a
    ld b, a
    call irq_setup               ; quiet, DI: no source can hold an init transfer back
.init:
    ld ix, (rtRow)
    ld l, (ix + R_INIT)
    ld h, (ix + R_INIT + 1)
    call call_hl
    jp c, .skip
    ld a, (rtKind)
    or a
    jr z, .timed
    call rt_q
    call irq_state
    jp c, .skip
.timed:
    ld a, NR_SPEED
    call nr_read
    and 3                        ; S = NR $07 bits 1:0 as read back
    ld (rtS), a
    ld ix, (rtRow)
    ld l, (ix + R_BODY)
    ld h, (ix + R_BODY + 1)
    ld e, (ix + R_REPS)
    ld d, (ix + R_REPS + 1)
    call clk_run
    ld (rtF), hl
    ld (rtD), de
    ld a, (rtKind)
    or a
    jr z, .fast
    call irq_quiet
    call irq_lat_max
    ld (rtL), a
.fast:
    nextreg NR_SPEED, SPEED_28
    ld ix, (rtRow)
    ld l, (ix + R_CHECK)
    ld h, (ix + R_CHECK + 1)
    ld a, h
    or l
    jr z, .ck                    ; A = 0: no CK field
    call call_hl
    ld (rtCk), hl
    ld a, 1
    adc a, 0                     ; 1 = OK, 2 = BAD
.ck:
    ld (rtCkState), a
    call rt_restore
    call rt_log
    jr .next
.skip:
    push de
    call rt_restore
    pop de
    ld hl, (rtRow)
    call log_skip
.next:
    ld hl, (rtRow)
    ld de, ROW_LEN
    add hl, de
    jp .row

; A = the row's interrupt state, B = its ISR length index (from rtKind).
rt_q:
    ld a, (rtKind)
    ld b, 0
    bit 3, a
    jr z, .s
    inc b
.s:
    rrca
    rrca
    rrca
    rrca
    and 3
    ret

; HL = the current row's reps. Corrupts IX.
row_reps:
    ld ix, (rtRow)
    ld l, (ix + R_REPS)
    ld h, (ix + R_REPS + 1)
    ret

; Init of a DMA row over the bound.
row_bound:
    ld de, rowTxtBound
    scf
    ret

; "<TAG> C=W S=d R=hhhh F=hhhh D=hhhh N=hhhh[ Q=sic][ CK=hhhh OK|BAD][ L=hh]";
; L for DMA rows in states 1 and 2.
rt_log:
    ld hl, (rtRow)
    call log_tag
    ld hl, logTxtCW
    call log_puts
    ld a, (rtS)
    add a, '0'
    call log_putc
    ld hl, logTxtR
    call log_puts
    ld ix, (rtRow)
    ld l, (ix + R_REPS)
    ld h, (ix + R_REPS + 1)
    call log_hex16
    ld hl, logTxtF
    call log_puts
    ld hl, (rtF)
    call log_hex16
    ld hl, logTxtD
    call log_puts
    ld hl, (rtD)
    call log_hex16
    ld hl, logTxtN
    call log_puts
    ld ix, (rtRow)
    ld l, (ix + R_N)
    ld h, (ix + R_N + 1)
    call log_hex16
    ld a, (rtKind)
    or a
    jr z, .ck
    ld hl, logTxtQ
    call log_puts
    call rt_q
    add a, '0'
    call log_putc
    ld a, b
    add a, '0'
    call log_putc
    ld a, (rtKind)
    and 3
    add a, '0'
    call log_putc
.ck:
    ld a, (rtCkState)
    or a
    jr z, .lat
    ld hl, logTxtCK
    call log_puts
    ld hl, (rtCk)
    call log_hex16
    ld a, (rtCkState)
    dec a
    ld hl, logTxtOK
    jr z, .v
    ld hl, logTxtBAD
.v:
    call log_puts
.lat:
    ld a, (rtKind)
    and QS_MASK                  ; CPU rows and quiet DMA rows: no L
    jp z, log_row_end
    ld hl, logTxtL
    call log_puts
    ld a, (rtL)
    call log_hex8
    jp log_row_end

; "ROW nnnn/mmmm" in hex; falls into ula_hex16.
rt_progress:
    ld bc, ROW_TXT_ROW << 8
    call ula_at
    ld hl, txtRow
    call ula_puts
    ld hl, (rtNum)
    call ula_hex16
    ld a, '/'
    call ula_putc
    ld hl, (rtTotal)
; HL -> 4 hex digits. Corrupts AF, DE, HL.
ula_hex16:
    push hl
    ld a, h
    call ula_hex8
    pop hl
    ld a, l
    jp ula_hex8

; After every row: DI, 28 MHz, boot interrupt NRs, DMA reset, probe byte, the stub
; IM2 table, MMU2/3/6/7 back. Corrupts AF, BC, DE, HL.
rt_restore:
    di
    nextreg NR_SPEED, SPEED_28
    call irq_restore
    call dma_reset
    call ddma_undo
    ld a, high IM2_TAB
    ld i, a
    im 2
mmu_canon:
    nextreg NR_MMU2, 10
    nextreg NR_MMU3, 11
    nextreg NR_MMU6, 0
    nextreg NR_MMU7, 1
    ret

; Every vector lands on isr_stub, so an interrupt that esxDOS lets in is harmless.
im2_init:
    ld hl, IM2_TAB
    ld de, IM2_TAB + 1
    ld bc, 256
    ld (hl), IM2_VEC
    ldir
    ld a, high IM2_TAB
    ld i, a
    im 2
    ret

; NR values for #NR, then the SRAM probe: two patterns written and read back at
; SRAM_PROBE_PAGE through MMU6, byte restored (src/banks.asm ram_detect).
hdr_read:
    ld hl, nrList
    ld de, nrVals
    ld b, NR_COUNT
.nr:
    ld a, (hl)
    inc hl
    push bc
    call nr_read
    pop bc
    ld (de), a
    inc de
    djnz .nr
    nextreg NR_MMU6, SRAM_PROBE_PAGE
    ld hl, SRAM_PROBE_ADDR
    ld c, (hl)
    ld (hl), $A5
    ld a, (hl)
    cp $A5
    jr nz, .absent
    ld (hl), $5A
    ld a, (hl)
    cp $5A
    jr nz, .absent
    ld a, 1
    jr .store
.absent:
    xor a
.store:
    ld (sramExp), a
    ld (hl), c
    nextreg NR_MMU6, 0
    ret

; A = NextReg -> A = its value. Corrupts BC.
nr_read:
    ld bc, NR_SEL
    out (c), a
    inc b
    in a, (c)
    ret

call_hl:
    jp (hl)

; A low nibble -> ASCII hex digit.
hex_digit:
    and $0F
    add a, '0'
    cp '9' + 1
    ret c
    add a, 7
    ret

ula_cls:
    xor a
    out ($FE), a
    ld hl, $4000
    ld de, $4001
    ld bc, $17FF
    ld (hl), a
    ldir
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), $07                 ; white ink, black paper
    ldir
    ret

; B = text row (0-23), C = column.
ula_at:
    ld a, b
    and $18
    or $40
    ld h, a
    ld a, b
    and 7
    rrca
    rrca
    rrca
    or c
    ld l, a
    ld (ulaPos), hl
    ret

; A = ASCII 32-127. Corrupts AF, DE, HL.
ula_putc:
    push bc
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, font - 32 * 8
    add hl, de
    ex de, hl
    ld hl, (ulaPos)
    push hl
    ld b, 8
.ln:
    ld a, (de)
    ld (hl), a
    inc de
    inc h
    djnz .ln
    pop hl
    inc l
    ld (ulaPos), hl
    pop bc
    ret

; HL = 0-terminated string. Corrupts AF, DE, HL.
ula_puts:
    ld a, (hl)
    or a
    ret z
    push hl
    call ula_putc
    pop hl
    inc hl
    jr ula_puts

; Corrupts AF, DE, HL.
ula_hex8:
    push af
    swapnib
    call hex_digit
    call ula_putc
    pop af
    call hex_digit
    jp ula_putc

; Calibration rows: empty body, so T per rep is the poll overhead.
row_go:
    or a                         ; CF = 0: run the row
    ret
row_empty:
    ret

