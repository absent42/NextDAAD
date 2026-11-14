; Part 1a instruction-class probe: one instruction class per row, unrolled, under DI.
; Sleds are built by init from assembled templates and end in RET.

SLED             equ $E000   ; MMU7 = SLED_PAGE during a sled row
P1_DATA          equ $C000   ; MMU6 = DATA_PAGE (or the bank 5/7 page) during a row
X5_SLED          equ $6000   ; MMU3 = page 11: bank 5 upper half, off the ULA screen
SLED_PAGE        equ 32      ; bank 16: past the system banks 0-8 (src/nextdaad.inc)
DATA_PAGE        equ 33
BANK5_PAGE       equ 10
BANK7_PAGE       equ 14      ; the only bank 7 page in block RAM (30205 zxnext.vhd:3278)
ULA_PORT         equ $FE     ; B = 0 with it: OTIR sends 256 bytes

NOP_N            equ 4096
RD_N             equ 2048
WR_N             equ 2048
LDI_N            equ 1024
LDIR_N           equ 1024
OTIR_N           equ 1024
OTIR_K           equ OTIR_N / 256
IN_N             equ 1024
PP_N             equ 1024    ; PUSH HL + POP HL pairs
JR_N             equ 1024
    ASSERT OTIR_N % 256 == 0
    ASSERT NOP_N + 1 <= $2000 && X5_SLED + NOP_N + 1 <= $8000
    ASSERT 6 + LDI_N * 2 + 1 <= $2000 && 3 + RD_N + 1 <= $2000

; Per body pass: documented T, and cost = documented + 1 per opcode fetch and memory read.
NP_DOC           equ NOP_N * 4
NP_COST          equ NOP_N * 5
RD_DOC           equ 10 + RD_N * 7           ; ld hl,nn then the sled
RD_COST          equ 13 + RD_N * 9
WR_DOC           equ 10 + WR_N * 7
WR_COST          equ 13 + WR_N * 8
LI_DOC           equ 20 + LDI_N * 16
LI_COST          equ 26 + LDI_N * 19
LR_DOC           equ 30 + LDIR_N * 21 - 5    ; 21 per byte, 16 for the last
LR_COST          equ 39 + LDIR_N * 24 - 5    ; each repeat refetches ED B0
OT_DOC           equ 20 + OTIR_N * 21 - 5 * OTIR_K
OT_COST          equ 26 + OTIR_N * 24 - 5 * OTIR_K
IN_DOC           equ 10 + IN_N * 12
IN_COST          equ 13 + IN_N * 14
PP_DOC           equ PP_N * 21
PP_COST          equ PP_N * 25
JR_DOC           equ JR_N * 12
JR_COST          equ JR_N * 14

P1_FRAMES        equ 64      ; span at documented T: margin over the 50-frame floor
POLL_FAST        equ 337     ; POLL_T less its 75 opcode fetches and memory reads

; P1ROW tag, n, doc, cost, speed, init, body: reps span P1_FRAMES at doc T per pass.
    MACRO P1ROW mtag, munits, mdoc, mcost, mspeed, minit, mbody
    ROW mtag, munits, (P1_FRAMES * (FRAME_T0 << (mspeed)) + (mdoc) + POLL_FAST - 1) / ((mdoc) + POLL_FAST), mcost, mspeed, CPU, minit, mbody, 0
    ENDM

; MMU6 = DATA_PAGE, MMU7 = SLED_PAGE; rt_restore puts LOG_BUF's pages 0/1 back.
; Out: CF = 0. Keeps A, BC, DE, HL.
p1_map:
    nextreg NR_MMU6, DATA_PAGE
    nextreg NR_MMU7, SLED_PAGE
    or a
    ret

p1np_init:                       ; P1NP, P1C1
    ld hl, tplNop
    ld bc, NOP_N
p1_sled:                         ; HL = template, BC = unit bytes
    call p1_map
    ld de, SLED
    jp sled_build

p1wr_init:
    ld hl, tplWr
    ld bc, WR_N
    jr p1_sled

p1li_init:
    ld hl, tplLdi
    ld bc, LDI_N * 2
    jr p1_sled

p1in_init:
    ld hl, tplIn
    ld bc, IN_N * 2
    jr p1_sled

p1pp_init:
    ld hl, tplPp
    ld bc, PP_N * 2
    jr p1_sled

p1jr_init:
    ld hl, tplJr
    ld bc, JR_N * 2
    jr p1_sled

p1rd_init:
    ld a, DATA_PAGE
    jr p1_rdx
p1r5_init:
    ld a, BANK5_PAGE
    jr p1_rdx
p1r7_init:
    ld a, BANK7_PAGE
p1_rdx:                          ; A = the page read through MMU6
    call p1_map
    nextreg NR_MMU6, a
    ld hl, tplRd
    ld bc, RD_N
    ld de, SLED
    jp sled_build

p1x5_init:
    nextreg NR_MMU3, BANK5_PAGE + 1
    ld hl, tplNop
    ld bc, NOP_N
    ld de, X5_SLED
    jp sled_build

; OTIR source: OTIR_N zero bytes, so port $FE keeps border 0, MIC and EAR off.
p1ot_init:
    call p1_map
    ld hl, P1_DATA
    ld de, P1_DATA + 1
    ld bc, OTIR_N - 1
    ld (hl), 0
    ldir
    or a
    ret

p1lr_body:                       ; P1LR, P1C2; init p1_map
    ld hl, P1_DATA
    ld de, P1_DATA + LDIR_N
    ld bc, LDIR_N
    ldir
    ret

p1ot_body:
    ld hl, P1_DATA
    ld bc, ULA_PORT              ; each OTIR leaves B = 0 for the next
    REPT OTIR_K
    otir
    ENDR
    ret

; HL = template, DE = destination, BC = unit bytes (even, >= 2). Copies the
; prologue, repeats the 2-byte unit, ends with RET. Out: CF = 0.
sled_build:
    push bc
    ld c, (hl)
    ld b, 0
    inc hl
    ld a, c
    or a
    jr z, .unit
    ldir
.unit:
    pop bc
    push de
    ldi
    ldi
    pop hl
    ld a, b
    or c
    jr z, .ret
    ldir                         ; DE trails HL by 2: the unit repeats
.ret:
    ld a, (tplRet)
    ld (de), a
    or a
    ret

; Template: db prologue length, the prologue, the 2-byte unit.
tplNop:  db .u - $ - 1
.u:      nop
         nop
         ASSERT $ - .u == 2
tplRd:   db .u - $ - 1
         ld hl, P1_DATA
.u:      ld a, (hl)
         ld a, (hl)
         ASSERT $ - .u == 2
tplWr:   db .u - $ - 1
         ld hl, P1_DATA
.u:      ld (hl), a
         ld (hl), a
         ASSERT $ - .u == 2
tplLdi:  db .u - $ - 1
         ld hl, P1_DATA
         ld de, P1_DATA + LDI_N
.u:      ldi
         ASSERT $ - .u == 2
tplIn:   db .u - $ - 1
         ld bc, ULA_PORT
.u:      in a, (c)
         ASSERT $ - .u == 2
tplPp:   db .u - $ - 1
.u:      push hl
         pop hl
         ASSERT $ - .u == 2
tplJr:   db .u - $ - 1
.u:      jr $ + 2
         ASSERT $ - .u == 2
tplRet:  ret
