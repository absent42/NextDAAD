; PI303: P3 Next side. Banks: mailbox 16 ($80000), sled 18 ($88000), read sled 19, row data
; 20 ($90000), bank 7/5 save 21 ($94000), loads 22, scratch 24-39 ($A0000-$DFFFF), result 41-43
; ($E4000, the row log); all below $200000. Build: build.ps1 (STAMP_STR), PI303.NEX + PI303.MAP.
    DEVICE ZXSPECTRUMNEXT

    IFNDEF STAMP_STR
    ASSERT 0, "STAMP_STR missing: build with build.ps1"
    DEFINE STAMP_STR 'none'
    ENDIF
    DEFINE LOG_NAME_STR "PI303.LOG"
    DEFINE BENCH_NAME_STR "PI"

    INCLUDE "../../bench/rowdefs.asm"

; ---- memory: 8K page p at physical $40000 + p x $2000 (zxnddma.gde 2.5) ----
PHYS_RAM         equ $40000
PHYS_LIMIT       equ $200000     ; the Pi's address is 21 bits
MBOX_BANK        equ 16
SLED_BANK        equ 18          ; P3NP's sled alone
CODE_BANK        equ 19          ; the read sled (P3RS, P3R5)
DATA_BANK        equ 20          ; RS buffer, LR source and destination, BF destination
SAVE_BANK        equ 21          ; bank 7 save page; pre-stream copy + bank 5 save page
LOAD_BANK        equ 22          ; LOAD 1 and 3 buffers
SCR_BANK         equ 24
SCR_BANKS        equ 16          ; 256 KB scratch, also the U target
MBOX_PAGE        equ MBOX_BANK * 2
SLED_PAGE        equ SLED_BANK * 2
CODE_PAGE        equ CODE_BANK * 2
DATA_PAGE        equ DATA_BANK * 2
B7SAVE_PAGE      equ SAVE_BANK * 2
COPY_PAGE        equ SAVE_BANK * 2 + 1
LOAD_PAGE        equ LOAD_BANK * 2
BANK5_PAGE       equ 10
BANK7_PAGE       equ 14          ; the only bank 7 page in block RAM (30205 zxnext.vhd:3278)
MBOX_PHYS        equ PHYS_RAM + MBOX_PAGE * $2000
SLED_PHYS        equ PHYS_RAM + SLED_PAGE * $2000
DATA_PHYS        equ PHYS_RAM + DATA_PAGE * $2000
B7SAVE_PHYS      equ PHYS_RAM + B7SAVE_PAGE * $2000
LOAD_PHYS        equ PHYS_RAM + LOAD_PAGE * $2000
SCR_PHYS         equ PHYS_RAM + SCR_BANK * $4000

; ---- mailbox page through MMU2 ($4000): byte offsets, states, commands ----
MB_WIN           equ $4000
MB_MAGIC         equ 0
MB_SEQ           equ 4
MB_CMD           equ 5
MB_ARG0          equ 6
MB_ARG1          equ 7
MB_ARG32         equ 8
MB_ACK           equ 12
MB_STATE         equ 13
MB_HB_NEXT       equ 14
MB_HB_PI         equ 16
MB_LEADER        equ 18
MB_RES_PHYS      equ 20
MB_RES_LEN       equ 23
MB_LEN           equ 25
ST_BOOT          equ 0
ST_READY         equ 1
ST_DONE          equ 2
ST_FAILED        equ 3
ST_EXITING       equ 4
CMD_QUIET        equ 1
CMD_STREAM       equ 2
CMD_STOP         equ 3
CMD_LOAD         equ 4
CMD_END          equ 5
CMD_HANDOVER     equ 6
CMD_YIELD        equ 7
TGT_U            equ 0           ; STREAM arg1 (ruling E)
TGT_S            equ 1
TGT_B            equ 2
ROW_NP           equ 0           ; QUIET/STREAM arg0
ROW_RS           equ 1
ROW_R5           equ 2
ROW_LR           equ 3
ROW_BF           equ 4
ROW_CAL          equ 5
PROF_IDLE        equ 0           ; LOAD arg0
PROF_LDIR        equ 1
PROF_B5          equ 2
PROF_BLT         equ 3
PROF_L2          equ 4
PROF_N           equ 5

; ---- watch: frames counted by pi_frame_isr, 50 Hz ----
TIMEOUT_FR       equ 120 * 50    ; no change to hb_pi, cmd_seq or ack_seq
KEY_FR           equ 2 * 50      ; SPACE held
SETTLE_FR        equ 2 * 50      ; hb_pi unchanged before the restore
BOUND_FR         equ 10 * 50
KEY_PORT         equ $7FFE       ; SPACE = bit 0, low when held

; ---- rows ----
DATA_WIN         equ $C000       ; MMU6
HI_WIN           equ $E000       ; MMU7: sled, read sled, save or copy page
NOP_N            equ 4096
RD_N             equ 2048
LDIR_N           equ 1024
BF_LEN           equ 4096
RS_OFF           equ 0
LR_SRC_OFF       equ RS_OFF + RD_N
LR_DST_OFF       equ LR_SRC_OFF + LDIR_N
BF_OFF           equ LR_DST_OFF + LDIR_N
    ASSERT BF_OFF + BF_LEN <= $2000
BF_PHYS          equ DATA_PHYS + BF_OFF
R5_ADDR          equ $6000       ; bank 5 page 11 through MMU3, off the ULA screen
R5_OFF           equ $2000       ; its bank 5 offset, the Pi's BRAM address
B5SAVE           equ HI_WIN + $1000  ; R5 region save, COPY_PAGE at MMU7, past the copy area
    ASSERT NOP_N <= $1000 && BF_LEN <= $1000 && $1000 + RD_N <= $2000
B5_DATA          equ R5_ADDR + RD_N
B5_CODE          equ $7000
B5_PASSES        equ 32
LOAD_LEN         equ $4000
FILL_VAL         equ $3C
DF_PHYS          equ %00000001   ; $DF mode flags (zxnddma.gde 2.5)
DF_FILL          equ %00001000
BLT_BODY_LEN     equ 10
BLT_GO_DOC       equ 20 + BLT_BODY_LEN * 16
NR_PI_EN         equ $A0
PI_SPI_BIT       equ %00000010   ; NR $A0 bit 1: the Pi SPI slave
NR_DISP1         equ $69
L2_ON            equ %10000000
STAT_TXT_ROW     equ 1
NOTE_TXT_ROW     equ 5
P1_FRAMES        equ 64          ; dma.asm's reps use probe.asm's names
POLL_FAST        equ 337
TPUS             equ 27          ; T per us at the slowest NR $11 clock: windows err long
QUIET_PAD_US     equ 50000
QUIET_MAX_US     equ 10000000    ; far under the 120 s no-progress timer

; Documented and worst-case T per body pass (+1 per fetch and read at 28 MHz).
NP_DOC           equ NOP_N * 4
NP_COST          equ NOP_N * 5
RS_DOC           equ 10 + 10 + RD_N * 13          ; ld hl,nn; jp nn; ld a,(hl) / inc hl
RS_COST          equ 13 + 13 + RD_N * 16
LR_DOC           equ 30 + LDIR_N * 21 - 5
LR_COST          equ 39 + LDIR_N * 24 - 5
BF_DOC           equ BLT_GO_DOC + BF_LEN * 2       ; cycle 2 a byte (ops.asm K_FB)
BF_COST          equ (BLT_GO_DOC * 4 + 2) / 3 + BF_LEN * 3 + DMA_XFER_PAD
B7_UNIT          equ 1024
B7_REPS          equ $2000 / B7_UNIT
B5_REPS          equ RD_N / B7_UNIT
B7_DOC           equ 16 + 20 + 10 + B7_UNIT * 21 - 5 + 16 + 20
B7_COST          equ (B7_DOC * 4 + 2) / 3

; Reps spanning P1_FRAMES frames at documented T (probe.asm P1ROW rule).
    MACRO P3REPS zname, zdoc
zname = (P1_FRAMES * (FRAME_T0 << 3) + (zdoc) + POLL_FAST - 1) / ((zdoc) + POLL_FAST)
    ASSERT zname >= 1 && zname <= $FFFF && zname * ((zdoc) + POLL_FAST) >= 50 * (FRAME_T0 << 3)
    ENDM
    P3REPS NP_REPS, NP_DOC
    P3REPS RS_REPS, RS_DOC
    P3REPS LR_REPS, LR_DOC
    P3REPS BF_REPS, BF_DOC

; Lead entry: header (cmd, arg0 row, arg1 target, flags, arg32) then a one-row ROW table.
; QUIET arg32 = worst-case row T + 20% + 50 ms, in us.
LH_ARG0          equ 1
LH_FLAGS         equ 3
LH_LEN           equ 8
LEAD_LEN         equ LH_LEN + ROW_LEN + 1
PRECOPY          equ 1           ; S target with a check: region copied before STREAM
    MACRO LEAD zcmd, zrow, ztgt, zflg, ztag, zunits, zreps, zcost, zkind, zinit, zbody, zcheck
LEAD_AT = $
    db zcmd, zrow, ztgt, zflg
    IF (zcmd) == CMD_QUIET
LEAD_Q = ((zreps) * ((zcost) + POLL_T) / TPUS) * 12 / 10 + QUIET_PAD_US
    ASSERT LEAD_Q < QUIET_MAX_US, "QUIET window over 10 s"
    dd LEAD_Q
    ELSE
    dd 0
    ENDIF
    ROW ztag, zunits, zreps, zcost, 3, zkind, zinit, zbody, zcheck
    db 0
    ASSERT $ - LEAD_AT == LEAD_LEN
    ENDM

    ORG $8000
main:
    di
    ld sp, STACK_TOP
    nextreg NR_SPEED, SPEED_28
    call mmu_canon
    call im2_init
    call irq_init
    call nr64_zero
    call ula_cls
    call hdr_read
    call log_header
    call ddma_detect             ; its probe byte (DDMA_PAGE) is in scratch: before the Pi is on
    call data_init
    ld a, NR_PI_EN
    call nr_read
    ld (savedA0), a
    or PI_SPI_BIT
    nextreg NR_PI_EN, a
    ld hl, txtNrA0
    call log_puts
    ld a, (savedA0)
    call log_hex8
    call log_eol
    call b7_save
    call b5_save                 ; S3R5's bank 5 region, before state 1 lets the Pi write
    ld a, NR_DISP1
    call nr_read
    and L2_ON ^ $FF
    ld (disp69), a
    call mb_init
    call fi_on
    xor a
    call load_set
    call follow                  ; LOAD 0 while the Pi sweeps, until HANDOVER
    call lead
    call follow                  ; the Pi's loads until END
    jp exit_end

    INCLUDE "../../bench/clock.asm"
    INCLUDE "../../bench/log.asm"
    INCLUDE "../../bench/irq.asm"
    INCLUDE "../../bench/dma.asm"

; ---- local exits: each logs its reason, then restore_all ----
exit_end:
    ld sp, STACK_TOP
    jp restore_all
exit_timeout:
    ld de, txtTimeout
    jr exit_skip
exit_key:
    ld de, txtKey
exit_skip:
    ld sp, STACK_TOP
    ld hl, tagPi3x
    call log_skip
    jp restore_all

; ---- follower: the Pi leads; one load step, hb_next, watch, then any new command ----
follow:
.lp:
    call load_step
    call hbn_bump
    call watch
    ld a, (mbSh + MB_SEQ)
    ld hl, mbSh + MB_ACK
    cp (hl)
    jr z, .lp                    ; acked already: nothing new
    ld a, (mbSh + MB_CMD)
    cp CMD_LOAD
    jr z, .load
    cp CMD_STOP
    jr z, .stop
    cp CMD_END
    jr z, .end
    cp CMD_HANDOVER
    jr z, .hand
.ack:
    call mb_ack                  ; any other command: acked, ignored
    jr .lp
.load:
    ld a, (mbSh + MB_ARG0)
    cp PROF_N
    jr nc, .ack
    call load_set
    jr .ack
.stop:
    xor a
    call load_set
    jr .ack
.end:
    xor a
    call load_set
    call mb_ack
    jp exit_end
.hand:
    xor a
    call load_set
    ld a, (ledDone)
    or a
    jr nz, .ack                  ; one lead a run
    inc a
    ld (ledDone), a
    call mb_ack
    ld a, 1
    jp mb_leader

; A = profile: the current load left (Layer 2 off, DMA reset, MMU canonical), A's set up.
; LOAD 3 without zxnDDMA idles. Corrupts all.
load_set:
    push af
    ld a, (disp69)
    nextreg NR_DISP1, a
    call dma_reset
    call mmu_canon
    pop af
    ld (loadProf), a
    push af
    ld bc, STAT_TXT_ROW << 8
    call ula_at
    ld hl, txtLoad
    call ula_puts
    pop af
    push af
    add a, '0'
    call ula_putc
    ld hl, txtPad
    call ula_puts
    pop af
    cp PROF_L2
    jr z, .l2
    cp PROF_BLT
    ret nz
    call ddma_need
    jr c, .idle
    ld hl, LOAD_PHYS & $FFFF
    ld a, LOAD_PHYS >> 16
    ld bc, LOAD_LEN
    jp blt_setup
.idle:
    xor a
    ld (loadProf), a
    ret
.l2:
    ld a, (disp69)
    or L2_ON
    nextreg NR_DISP1, a
    ret

; One step of the current load, about a frame. Corrupts all.
load_step:
    ld a, (loadProf)
    cp PROF_LDIR
    jr z, .ldir
    cp PROF_B5
    jr z, .b5
    cp PROF_BLT
    jr z, .blt
    ei                           ; profiles 0 and 4: HALT idle to the frame interrupt
    jp pi_halt
.ldir:
    nextreg NR_MMU6, LOAD_PAGE
    nextreg NR_MMU7, LOAD_PAGE + 1
    ld hl, DATA_WIN
    ld de, HI_WIN
    ld bc, $2000
    ldir
    jp mmu_canon
.b5:
    jp B5_CODE
.blt:
    call blt_go
    call blt_go
    call blt_go
    jp blt_go

; ---- leader: each lead entry's command, its row, then STOP for a STREAM; YIELD last ----
lead:
    ld hl, leadList
.row:
    ld a, (hl)
    or a
    jp z, .yield
    ld (ldHdr), hl
    call ld_status
    ld hl, (ldHdr)
    ld de, LH_FLAGS
    add hl, de
    ld a, (hl)
    and PRECOPY
    jr z, .send
    ld hl, (ldHdr)
    inc hl
    ld a, (hl)                   ; LH_ARG0: row code
    call precopy
.send:
    ld hl, (ldHdr)
    call mb_send
    ld hl, (ldHdr)
    ld a, (hl)
    cp CMD_STREAM
    jr z, .hb0
    call pi_halt                 ; QUIET: a frame for the Pi's ack read-back to finish
    jr .run
.hb0:
    call mb_hb_pi
    ld (strHb0), hl
    ld a, 1
    ld (strOn), a
.run:
    ld hl, (logPtr)
    ld (ldLogPtr), hl
    ld hl, (logRows)
    ld (ldLogRows), hl
    di
    ld hl, (ldHdr)
    ld de, LH_LEN
    add hl, de
    call run_table
    call fi_on
    ld hl, (ldHdr)
    ld a, (hl)
    cp CMD_STREAM
    jr nz, .next
    call stream_end              ; a no-op when the row's check stopped it
    ld hl, (logRows)
    ld de, (ldLogRows)
    or a
    sbc hl, de
    jr z, .next                  ; row skipped by its init: no timed window
    ld hl, (strHb1)
    ld de, (strHb0)
    or a
    sbc hl, de
    jr nz, .next
    ld hl, (ldLogPtr)            ; hb_pi did not move: the row line becomes a skip
    ld (logPtr), hl
    ld hl, (ldLogRows)
    ld (logRows), hl
    ld hl, (ldHdr)
    ld de, LH_LEN
    add hl, de
    ld de, txtNoStream
    call log_skip
.next:
    ld hl, (ldHdr)
    ld de, LEAD_LEN
    add hl, de
    jp .row
.yield:
    ld hl, hdrYield
    call mb_send
    xor a
    jp mb_leader                 ; leader = 0 once the Pi has acked YIELD

; "LEAD <tag>" on the status row. Corrupts AF, BC, DE, HL.
ld_status:
    ld bc, STAT_TXT_ROW << 8
    call ula_at
    ld hl, txtLead
    call ula_puts
    ld hl, (ldHdr)
    ld de, LH_LEN
    add hl, de
    ld b, 4
.ch:
    ld a, (hl)
    inc hl
    push hl
    call ula_putc
    pop hl
    djnz .ch
    ret

; Once a loaded row: hb_pi end sample, then STOP acked. Ends EI. Corrupts all.
stream_end:
    ld a, (strOn)
    or a
    ret z
    xor a
    ld (strOn), a
    call mb_hb_pi
    ld (strHb1), hl
    ld hl, hdrStop
    jp mb_send

; A = row code: its region copied to the copy page. Corrupts all.
precopy:
    call reg_map
    ld de, HI_WIN
    ldir
    jp mmu_canon

; A = row code -> MMU6 = its page, HL = region in DATA_WIN, BC = length, MMU7 = copy page.
; Corrupts AF, DE.
reg_map:
    ld l, a
    add a, a
    add a, a
    add a, l
    ld hl, regTab
    add hl, a
    ld a, (hl)
    nextreg NR_MMU6, a
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld c, (hl)
    inc hl
    ld b, (hl)
    ex de, hl
    nextreg NR_MMU7, COPY_PAGE
    ret

; ---- mailbox (MMU2 mapped only inside these helpers) ----
mb_on:
    nextreg NR_MMU2, MBOX_PAGE
    ret
mb_off:
    nextreg NR_MMU2, BANK5_PAGE
    ret

; Mailbox head -> mbSh (same offsets). Corrupts BC, DE, HL.
mb_read:
    call mb_on
    ld hl, MB_WIN
    ld de, mbSh
    ld bc, MB_LEN
    ldir
    jp mb_off

; A = state. Corrupts nothing else.
mb_state:
    call mb_on
    ld (MB_WIN + MB_STATE), a
    jp mb_off

; A = leader (0 Pi, 1 Next).
mb_leader:
    call mb_on
    ld (MB_WIN + MB_LEADER), a
    jp mb_off

; Follower: ack_seq = the cmd_seq just handled. Corrupts A.
mb_ack:
    ld a, (mbSh + MB_SEQ)
    call mb_on
    ld (MB_WIN + MB_ACK), a
    jp mb_off

; HL = hb_pi now.
mb_hb_pi:
    call mb_on
    ld hl, (MB_WIN + MB_HB_PI)
    jp mb_off

; Corrupts HL.
hbn_bump:
    call mb_on
    ld hl, (MB_WIN + MB_HB_NEXT)
    inc hl
    ld (MB_WIN + MB_HB_NEXT), hl
    jp mb_off

; result_phys/result_len = this run's log text: LOG_PAGE on, logPtr bytes, #END included.
mb_result:
    call mb_on
    ld hl, LOG_PHYS & $FFFF
    ld (MB_WIN + MB_RES_PHYS), hl
    ld a, LOG_PHYS >> 16
    ld (MB_WIN + MB_RES_PHYS + 2), a
    ld hl, (logPtr)
    ld (MB_WIN + MB_RES_LEN), hl
    jp mb_off

; Boot state, magic, ack_seq = cmd_seq (older commands count as acked), leader 0, then
; state 1 last. Corrupts all.
mb_init:
    call mb_on
    xor a
    ld (MB_WIN + MB_STATE), a
    ld hl, mbMagic
    ld de, MB_WIN + MB_MAGIC
    ld bc, 4
    ldir
    ld a, (MB_WIN + MB_SEQ)
    ld (MB_WIN + MB_ACK), a
    xor a
    ld (MB_WIN + MB_LEADER), a
    ld h, a
    ld l, a
    ld (MB_WIN + MB_HB_NEXT), hl
    ld (MB_WIN + MB_RES_PHYS), hl
    ld (MB_WIN + MB_RES_PHYS + 2), a
    ld (MB_WIN + MB_RES_LEN), hl
    ld a, ST_READY
    ld (MB_WIN + MB_STATE), a
    call mb_off
    call mb_read
    xor a
    ld (wKey), a
    jp watch.mark

; Leader: HL = header (cmd, arg0, arg1, flags, arg32); args, cmd, then cmd_seq + 1 last.
mb_send:
    call mb_on
    ld a, (hl)
    ld (MB_WIN + MB_CMD), a
    inc hl
    ld a, (hl)
    ld (MB_WIN + MB_ARG0), a
    inc hl
    ld a, (hl)
    ld (MB_WIN + MB_ARG1), a
    inc hl
    inc hl
    ld de, MB_WIN + MB_ARG32
    ld bc, 4
    ldir
    ld a, (MB_WIN + MB_SEQ)
    inc a
    ld (MB_WIN + MB_SEQ), a
    ld (mbWant), a
    call mb_off
    ei                           ; until ack_seq = mbWant, watch every pass; ends EI
.lp:
    call watch
    ld a, (mbSh + MB_ACK)
    ld hl, mbWant
    cp (hl)
    jr nz, .lp
    ret

; Local exits: any change to hb_pi, cmd_seq or ack_seq restarts the 120 s timer; SPACE
; held 2 s. Leaves the mailbox head in mbSh. Corrupts all.
watch:
    call mb_read
    ld hl, (mbSh + MB_HB_PI)
    ld de, (wHbPi)
    or a
    sbc hl, de
    jr nz, .mark
    ld a, (mbSh + MB_SEQ)
    ld hl, wSeq
    cp (hl)
    jr nz, .mark
    ld a, (mbSh + MB_ACK)
    ld hl, wAck
    cp (hl)
    jr z, .still
.mark:
    ld hl, (mbSh + MB_HB_PI)
    ld (wHbPi), hl
    ld a, (mbSh + MB_SEQ)
    ld (wSeq), a
    ld a, (mbSh + MB_ACK)
    ld (wAck), a
    ld hl, (piFrames)
    ld (wFrame), hl
.still:
    ld hl, (piFrames)
    ld de, (wFrame)
    or a
    sbc hl, de
    ld de, TIMEOUT_FR
    or a
    sbc hl, de
    jp nc, exit_timeout
    ld bc, KEY_PORT
    in a, (c)
    rra
    jr c, .up
    ld a, (wKey)
    or a
    jr nz, .held
    inc a
    ld (wKey), a
    ld hl, (piFrames)
    ld (wKeyFr), hl
    ret
.held:
    ld hl, (piFrames)
    ld de, (wKeyFr)
    or a
    sbc hl, de
    ld de, KEY_FR
    or a
    sbc hl, de
    jp nc, exit_key
    ret
.up:
    xor a
    ld (wKey), a
    ret

; hb_pi unchanged for SETTLE_FR frames: CF = 0; still changing at BOUND_FR: CF set.
; One frame a pass. Ends EI. Corrupts all.
pi_settle:
    ld hl, (piFrames)
    ld (stT0), hl
    ld (stT1), hl
    call mb_hb_pi
    ld (stHb), hl
.lp:
    ei
    call pi_halt
    call mb_hb_pi
    ld de, (stHb)
    or a
    sbc hl, de
    jr z, .same
    add hl, de
    ld (stHb), hl
    ld hl, (piFrames)
    ld (stT1), hl
.same:
    ld hl, (piFrames)
    ld de, (stT1)
    or a
    sbc hl, de
    ld de, SETTLE_FR
    or a
    sbc hl, de
    ret nc
    ld hl, (piFrames)
    ld de, (stT0)
    or a
    sbc hl, de
    ld de, BOUND_FR
    or a
    sbc hl, de
    jr c, .lp
    scf
    ret

; Hardware IM2, ULA frame interrupt only (irq_setup state 1), vector on pi_frame_stub.
; Ends EI. Corrupts AF, BC, HL.
fi_on:
    ld a, 1
    ld b, 0
    call irq_setup
    ld a, low pi_frame_stub
    ld (IM2_TAB + IM2_V_ULA), a
    ei
    ret

; Frame ISR: piFrames + 1, flags untouched.
pi_frame_isr:
    push hl
    ld hl, (piFrames)
    inc hl
    ld (piFrames), hl
    pop hl
    ei
    reti

; ---- row routines (init CF = 0; check HL = CK, CF = BAD) ----
np_init:
    nextreg NR_MMU7, SLED_PAGE
    or a
    ret
rs_init:
    nextreg NR_MMU6, DATA_PAGE
    nextreg NR_MMU7, CODE_PAGE
    or a
    ret
r5_init:
    nextreg NR_MMU7, CODE_PAGE   ; MMU3 = page 11 (mmu_canon)
    or a
    ret
lr_init:
    nextreg NR_MMU6, DATA_PAGE
    or a
    ret
rs_body:
    ld hl, DATA_WIN + RS_OFF
    jp rd_sled
r5_body:
    ld hl, R5_ADDR
    jp rd_sled
lr_body:
    ld hl, DATA_WIN + LR_SRC_OFF
    ld de, DATA_WIN + LR_DST_OFF
    ld bc, LDIR_N
    ldir
    ret

; S rows with a region: hb_pi end and STOP first, then CK = bytes that differ from the
; pre-stream copy (0 = OK).
ck_s:
    call stream_end
    di
    ld hl, (ldHdr)
    inc hl
    ld a, (hl)
    call reg_map
    ld de, HI_WIN
    ld ix, 0
.lp:
    ld a, (de)
    cp (hl)
    jr z, .same
    inc ix
.same:
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .lp
    push ix
    pop hl
    ld de, 0
    jp ck_cmp

; P3BF: blitter fill set-up as ops.asm dmainit_fb, destination BF_PHYS, cycle 2/2.
dmainit_bf:
    call dma_reset
    call ddma_need
    ret c                        ; #SKIP <tag> NODDMA
    ld hl, BF_PHYS & $FFFF
    ld a, BF_PHYS >> 16
    ld bc, BF_LEN
    jp blt_setup

; HL = port A and B bits 15:0, A = bits 23:16, BC = length: the fill set-up sent and
; bltBody set. Out: CF = 0. Corrupts AF, BC, HL.
blt_setup:
    ld (bltSet.alo), hl
    ld (bltSet.blo), hl
    ld (bltBody.alo), hl
    ld (bltBody.blo), hl
    ld (bltSet.ahi), a
    ld (bltSet.bhi), a
    ld (bltSet.len), bc
    ld (bltBody.len), bc
    ld hl, bltSet
    ld bc, BLT_SET_LEN << 8 | DMA_PORT
    otir
    or a
    ret

; One fill: bltBody by OUTINB (B = 0 kept); returns when the block is written.
blt_go:
    ld hl, bltBody
    ld bc, DMA_PORT
    DUP BLT_BODY_LEN
    outinb
    EDUP
    ret

; P3B7 (restore_all): bank 7 page 14 back from the save page, B7_UNIT bytes a rep.
b7_init:
    nextreg NR_MMU6, BANK7_PAGE
    nextreg NR_MMU7, B7SAVE_PAGE
    ld hl, HI_WIN
    ld (rbSrc), hl
    ld hl, DATA_WIN
    ld (rbDst), hl
    or a
    ret
; P3B7 and P3B5 body: B7_UNIT bytes from rbSrc to rbDst, both advanced.
rb_body:
    ld hl, (rbSrc)
    ld de, (rbDst)
    ld bc, B7_UNIT
    ldir
    ld (rbSrc), hl
    ld (rbDst), de
    ret
b7_check:
    ld hl, DATA_WIN
    ld bc, $2000
    call ck16
    ld de, (b7Ck)
    jp ck_cmp

; P3B5 (restore_all): the R5 region (bank 5 page 11, MMU3) back from B5SAVE.
b5_init:
    nextreg NR_MMU7, COPY_PAGE
    ld hl, B5SAVE
    ld (rbSrc), hl
    ld hl, R5_ADDR
    ld (rbDst), hl
    or a
    ret
b5_check:
    ld hl, R5_ADDR
    ld bc, RD_N
    call ck16
    ld de, (b5Ck)
    jp ck_cmp

; The R5 region copied to B5SAVE, its ck16 kept. Corrupts all.
b5_save:
    nextreg NR_MMU7, COPY_PAGE
    ld hl, R5_ADDR
    ld de, B5SAVE
    ld bc, RD_N
    ldir
    ld hl, R5_ADDR
    ld bc, RD_N
    call ck16
    ld (b5Ck), hl
    jp mmu_canon

; rtCkState after a restore row: anything but OK sets blkBad. Corrupts AF.
blk_ck:
    ld a, (rtCkState)
    cp 1
    ret z
    ld a, 1
    ld (blkBad), a
    ret

; Bank 7 page 14 copied to the save page, its ck16 kept. Corrupts all.
b7_save:
    nextreg NR_MMU6, BANK7_PAGE
    nextreg NR_MMU7, B7SAVE_PAGE
    ld hl, DATA_WIN
    ld de, HI_WIN
    ld bc, $2000
    ldir
    ld hl, DATA_WIN
    ld bc, $2000
    call ck16
    ld (b7Ck), hl
    jp mmu_canon

; Row data, R5 region and the bank 5 load loop. Corrupts all.
data_init:
    nextreg NR_MMU6, DATA_PAGE
    ld hl, DATA_WIN + RS_OFF
    ld bc, RD_N + LDIR_N         ; RS buffer, then LR source
    call pat_fill
    ld hl, DATA_WIN + LR_DST_OFF
    ld de, DATA_WIN + LR_DST_OFF + 1
    ld bc, LDIR_N - 1
    ld (hl), 0
    ldir
    ld hl, DATA_WIN + BF_OFF
    ld de, DATA_WIN + BF_OFF + 1
    ld bc, BF_LEN - 1
    ld (hl), FILL_VAL
    ldir
    ld hl, R5_ADDR
    ld bc, RD_N
    call pat_fill
    ld hl, b5Image
    ld de, B5_CODE
    ld bc, B5_IMAGE_LEN
    ldir
    jp mmu_canon

; HL = address, BC = length (> 0): byte = (L xor H) + $5A. Corrupts AF, BC, HL.
pat_fill:
    ld a, l
    xor h
    add a, $5A
    ld (hl), a
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, pat_fill
    ret

; Screen note for the owner: state, and NR $A0 bit 1 left set. Corrupts all.
end_note:
    ld bc, NOTE_TXT_ROW << 8
    call ula_at
    ld hl, txtState
    call ula_puts
    ld a, (endState)
    add a, '0'
    call ula_putc
    ld bc, (NOTE_TXT_ROW + 1) << 8
    call ula_at
    ld hl, txtNote1
    call ula_puts
    ld bc, (NOTE_TXT_ROW + 2) << 8
    call ula_at
    ld hl, txtNote2
    jp ula_puts

; Every exit lands here (END, timeout, key; log_flush's failure unwind returns inside).
; Order: exiting, the Pi settled, bank 7 then bank 5 restored and logged, SD flush, result,
; state (3 if a restore fails its checksum or the SD flush fails).
restore_all:
    di
    ld sp, STACK_TOP
    call mmu_canon
    ld a, ST_EXITING
    call mb_state                ; the Pi stops all writes but a last hb_pi
    call fi_on
    call pi_settle
    jr nc, .settled
    ld hl, tagPi3x
    ld de, txtPiBusy
    call log_skip
.settled:
    call rt_restore              ; DI, 28 MHz, boot interrupt NRs, DMA reset, MMU canonical
    ld a, (disp69)
    nextreg NR_DISP1, a          ; Layer 2 off
    xor a
    ld (blkBad), a
    ld (rtCkState), a
    ld hl, b7Table
    call run_table               ; P3B7, CK against the startup checksum
    call blk_ck
    xor a
    ld (rtCkState), a
    ld hl, b5Table
    call run_table               ; P3B5, the same for the S3R5 bank 5 region
    call blk_ck
    xor a
    ld (logErr), a
    call log_flush
    ld a, (logErr)
    or a
    jr z, .flushed
    ld (blkBad), a               ; no SD log: state 3, the Pi copy is the only record
.flushed:
    call nr64_restore
    call mb_result
    ld a, (blkBad)
    or a
    ld a, ST_DONE
    jr z, .st
    ld a, ST_FAILED
.st:
    ld (endState), a
    call mb_state
    call end_note                ; NR $A0 bit 1 stays set for the Pi's fetch
    di
    ld sp, STACK_TOP
    ld hl, pi_halt
    push hl                      ; an NMI's return lands on the halt again
; The only HALT. Under EI (load_step, pi_settle, lead's QUIET guard) it returns at the next
; interrupt; after restore_all it runs under DI and is the end.
pi_halt:
    halt
    ret

    INCLUDE "../../bench/runner.asm"

; ---- rows: CAL0 and the P3 baselines under QUIET, each followed by its U, S, B streams ----
leadList:
    LEAD CMD_QUIET, ROW_CAL, TGT_U, 0, "CAL0", 1, $FFFF, 0, CPU, row_go, row_empty, 0
    LEAD CMD_QUIET, ROW_NP, TGT_U, 0, "P3NP", NOP_N, NP_REPS, NP_COST, CPU, np_init, p3_sled, 0
    LEAD CMD_STREAM, ROW_NP, TGT_U, 0, "U3NP", NOP_N, NP_REPS, NP_COST, CPU, np_init, p3_sled, 0
    LEAD CMD_STREAM, ROW_NP, TGT_S, PRECOPY, "S3NP", NOP_N, NP_REPS, NP_COST, CPU, np_init, p3_sled, ck_s
    LEAD CMD_STREAM, ROW_NP, TGT_B, 0, "B3NP", NOP_N, NP_REPS, NP_COST, CPU, np_init, p3_sled, 0
    LEAD CMD_QUIET, ROW_RS, TGT_U, 0, "P3RS", RD_N, RS_REPS, RS_COST, CPU, rs_init, rs_body, 0
    LEAD CMD_STREAM, ROW_RS, TGT_U, 0, "U3RS", RD_N, RS_REPS, RS_COST, CPU, rs_init, rs_body, 0
    LEAD CMD_STREAM, ROW_RS, TGT_S, PRECOPY, "S3RS", RD_N, RS_REPS, RS_COST, CPU, rs_init, rs_body, ck_s
    LEAD CMD_STREAM, ROW_RS, TGT_B, 0, "B3RS", RD_N, RS_REPS, RS_COST, CPU, rs_init, rs_body, 0
    LEAD CMD_QUIET, ROW_R5, TGT_U, 0, "P3R5", RD_N, RS_REPS, RS_COST, CPU, r5_init, r5_body, 0
    LEAD CMD_STREAM, ROW_R5, TGT_U, 0, "U3R5", RD_N, RS_REPS, RS_COST, CPU, r5_init, r5_body, 0
    LEAD CMD_STREAM, ROW_R5, TGT_S, 0, "S3R5", RD_N, RS_REPS, RS_COST, CPU, r5_init, r5_body, 0
    LEAD CMD_STREAM, ROW_R5, TGT_B, 0, "B3R5", RD_N, RS_REPS, RS_COST, CPU, r5_init, r5_body, 0
    LEAD CMD_QUIET, ROW_LR, TGT_U, 0, "P3LR", LDIR_N, LR_REPS, LR_COST, CPU, lr_init, lr_body, 0
    LEAD CMD_STREAM, ROW_LR, TGT_U, 0, "U3LR", LDIR_N, LR_REPS, LR_COST, CPU, lr_init, lr_body, 0
    LEAD CMD_STREAM, ROW_LR, TGT_S, PRECOPY, "S3LR", LDIR_N, LR_REPS, LR_COST, CPU, lr_init, lr_body, ck_s
    LEAD CMD_STREAM, ROW_LR, TGT_B, 0, "B3LR", LDIR_N, LR_REPS, LR_COST, CPU, lr_init, lr_body, 0
    LEAD CMD_QUIET, ROW_BF, TGT_U, 0, "P3BF", BF_LEN, BF_REPS, BF_COST, DMA|QS0|QI0|QC2, dmainit_bf, blt_go, 0
    LEAD CMD_STREAM, ROW_BF, TGT_U, 0, "U3BF", BF_LEN, BF_REPS, BF_COST, DMA|QS0|QI0|QC2, dmainit_bf, blt_go, 0
    LEAD CMD_STREAM, ROW_BF, TGT_S, 0, "S3BF", BF_LEN, BF_REPS, BF_COST, DMA|QS0|QI0|QC2, dmainit_bf, blt_go, 0
    LEAD CMD_STREAM, ROW_BF, TGT_B, 0, "B3BF", BF_LEN, BF_REPS, BF_COST, DMA|QS0|QI0|QC2, dmainit_bf, blt_go, 0
    db 0

b7Table:
    ROW "P3B7", B7_UNIT, B7_REPS, B7_COST, 3, CPU, b7_init, rb_body, b7_check
    db 0
b5Table:
    ROW "P3B5", B7_UNIT, B5_REPS, B7_COST, 3, CPU, b5_init, rb_body, b5_check
    db 0

; Region per row code: db page, dw address with the page at MMU6, dw length (> 0).
regTab:
    db SLED_PAGE
    dw DATA_WIN, NOP_N
    db DATA_PAGE
    dw DATA_WIN + RS_OFF, RD_N
    db BANK5_PAGE + 1
    dw DATA_WIN + (R5_ADDR & $1FFF), RD_N
    db DATA_PAGE
    dw DATA_WIN + LR_SRC_OFF, LDIR_N
    db DATA_PAGE
    dw DATA_WIN + BF_OFF, BF_LEN
    ASSERT $ - regTab == 5 * (ROW_BF + 1)

; Fill set-up (ops.asm linInit order): port A unread in fill mode, physical, cycle 2/2.
bltSet:
    db $7D                       ; WR0: A to B, port A address and length follow
.alo:
    dw 0
.len:
    dw 0
    db $54, %00000010            ; WR1: A memory, incrementing; cycle 2
    db $50, %00000010            ; WR2: B memory, incrementing; cycle 2, no prescaler
    db $AD                       ; WR4: continuous, port B address follows
.blo:
    dw 0
    db $82                       ; WR5: stop at the end of the block
    db $D7                       ; port A bits 23:16
.ahi:
    db 0
    db $DB                       ; port B bits 23:16
.bhi:
    db 0
    db $F7, FILL_VAL
    db $DF, DF_PHYS | DF_FILL
BLT_SET_LEN      equ $ - bltSet
    ASSERT BLT_SET_LEN == 21

; Per-fill body (ops.asm bltLin): both addresses and the length, load, enable.
bltBody:
    db $7D
.alo:
    dw 0
.len:
    dw 0
    db $AD
.blo:
    dw 0
    db $CF, $87
    ASSERT $ - bltBody == BLT_BODY_LEN

; LOAD 2, copied to bank 5 page 11: bank 5 reads and writes only, about 9 ms a call.
b5Image:
    DISP B5_CODE
b5_loop:
    ld c, B5_PASSES
.pass:
    ld hl, B5_DATA
    ld b, 0
.byte:
    ld a, (hl)
    ld (hl), a
    inc l
    djnz .byte
    dec c
    jr nz, .pass
    ret
    ENT
B5_IMAGE_LEN     equ $ - b5Image
    ASSERT B5_DATA + 256 <= B5_CODE && B5_CODE + B5_IMAGE_LEN <= $8000

hdrStop:     db CMD_STOP, 0, 0, 0
             dd 0
hdrYield:    db CMD_YIELD, 0, 0, 0
             dd 0
mbMagic:     db "M303"
tagPi3x:     db "PI3X"
txtTimeout:  db "TIMEOUT", 0
txtKey:      db "KEY", 0
txtPiBusy:   db "PIBUSY", 0
txtNoStream: db "NOSTREAM", 0
txtNrA0:     db "#NR A0=", 0
txtLead:     db "LEAD ", 0
txtLoad:     db "LOAD ", 0
txtPad:      db "   ", 0
txtState:    db "PI303 STATE ", 0
txtNote1:    db "NR A0 BIT 1 LEFT SET FOR THE PI", 0
txtNote2:    db "RESET TO CLEAR IT", 0
piFrames:    dw 0
wHbPi:       dw 0
wSeq:        db 0
wAck:        db 0
wFrame:      dw 0
wKey:        db 0
wKeyFr:      dw 0
mbSh:        ds MB_LEN
mbWant:      db 0
ldHdr:       dw 0
ldLogPtr:    dw 0
ldLogRows:   dw 0
strOn:       db 0
strHb0:      dw 0
strHb1:      dw 0
stT0:        dw 0
stT1:        dw 0
stHb:        dw 0
loadProf:    db 0
ledDone:     db 0
savedA0:     db 0
disp69:      db 0
endState:    db 0
b7Ck:        dw 0
b5Ck:        dw 0
blkBad:      db 0
rbSrc:       dw 0
rbDst:       dw 0

    INCLUDE "../../bench/runner_data.asm"

    ASSERT $ <= CODE_LIMIT
    ASSERT LOG_HDR_MAX + LOG_ROW_MAX + (ROW_TOTAL + 2) * LOG_ROW_MAX + LOG_END_MAX <= LOG_CAP
LOG_BANK         equ LOG_PAGE / 2
LOG_BANKS        equ LOG_PAGES / 2
LOG_PHYS         equ PHYS_RAM + LOG_PAGE * $2000
    ASSERT LOG_PAGE % 2 == 0 && LOG_PAGES % 2 == 0
; Declared banks ascending (SAVENEX order), inside 1 MB, clear of the #SRAM probe page.
    ASSERT MBOX_BANK > 15 && MBOX_BANK < SLED_BANK && SLED_BANK < CODE_BANK
    ASSERT CODE_BANK < DATA_BANK && DATA_BANK < SAVE_BANK && SAVE_BANK < LOAD_BANK
    ASSERT LOAD_BANK < SCR_BANK && SCR_BANK + SCR_BANKS <= LOG_BANK
    ASSERT (LOG_BANK + LOG_BANKS) * 2 <= SRAM_PROBE_PAGE && SRAM_PROBE_PAGE * $2000 + PHYS_RAM <= PHYS_LIMIT

; MAP_<key> -> PI303.MAP "<key>=<6 hex digits>" (build.ps1): the Pi's addresses.
MAP_mbox_phys          equ MBOX_PHYS
MAP_scratch_phys       equ SCR_PHYS
MAP_scratch_len        equ SCR_BANKS * $4000
MAP_u_phys             equ SCR_PHYS
MAP_sled_phys          equ SLED_PHYS
MAP_sled_len           equ NOP_N
MAP_rs_phys            equ DATA_PHYS + RS_OFF
MAP_rs_len             equ RD_N
MAP_r5_off             equ R5_OFF
MAP_r5_len             equ RD_N
MAP_lr_src_phys        equ DATA_PHYS + LR_SRC_OFF
MAP_lr_len             equ LDIR_N
MAP_bf_dst_phys        equ BF_PHYS
MAP_bf_len             equ BF_LEN
MAP_fill_val           equ FILL_VAL
MAP_bank7_save_phys    equ B7SAVE_PHYS
MAP_bank5_save_phys    equ PHYS_RAM + COPY_PAGE * $2000 + (B5SAVE - HI_WIN)
MAP_result_phys_region equ LOG_PHYS
MAP_result_len_max     equ LOG_LIMIT
MAP_row_np             equ ROW_NP
MAP_row_rs             equ ROW_RS
MAP_row_r5             equ ROW_R5
MAP_row_lr             equ ROW_LR
MAP_row_bf             equ ROW_BF
MAP_row_cal            equ ROW_CAL

    INCLUDE "../../bench/isrstubs.asm"
pi_frame_stub:                   ; vector IM2_V_ULA while fi_on's carve is in
    jp pi_frame_isr
    ASSERT high pi_frame_stub == IM2_VEC && high ($ - 1) == IM2_VEC

; P3NP's sled, alone in its bank; the closing ret is past the streamed NOPs.
    MMU 7 e, SLED_PAGE, HI_WIN
p3_sled:
    ds NOP_N, 0
    ret

; Read sled for P3RS and P3R5: HL = the first byte.
    MMU 7 e, CODE_PAGE, HI_WIN
rd_sled:
    DUP RD_N
    ld a, (hl)
    inc hl
    EDUP
    ret

    SAVENEX OPEN "PI303.NEX", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX BANK 2, MBOX_BANK, SLED_BANK, CODE_BANK, DATA_BANK, SAVE_BANK, LOAD_BANK
NEX_B = SCR_BANK
    DUP SCR_BANKS
    SAVENEX BANK NEX_B
NEX_B = NEX_B + 1
    EDUP
NEX_B = LOG_BANK
    DUP LOG_BANKS
    SAVENEX BANK NEX_B
NEX_B = NEX_B + 1
    EDUP
    SAVENEX CLOSE
