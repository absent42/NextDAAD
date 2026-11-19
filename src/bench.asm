; BENCH driver (build.ps1 -Bench): part 2 rows on the long clock, logged to BENCH303.LOG.
; Entry: a fixture verb does LET 250 <mode> (mode 3 also LET 251 <ISR state>), then
; EXTERN 0 13 (benchres.asm trampoline). Fixture: tests/core303/fixture/bench.dsf.

; Slots: text rows remap MMU6 only; NX3 rows remap MMU6 and need OVL2_PAGE in MMU7; the turn
; remaps both. No 8K slot is safe, so the batch loop is resident (benchres.asm bench_batch
; maps the row's page into MMU7); the clock, setup and logging run here, BCH_PAGE at MMU7.

; Batch timing: the clock is read once either side of R x [restore; workload]. A row with a
; restore lists its companion first: same R, speed and restore, workload bench_none, tag
; char 2 'R' (B2HD/B3HD -> BRHD, told apart by S); tags.py Tag.cal names it.

; Turn (mode 4), no hook: bench_turn (benchres.asm) runs eng_step, eng_run's loop body, on
; a PRO 1 record pushed above the caller's stack until REDO returns it to its first entry,
; the step before PARSE 0 prompts and waits in inp_edit (overlay1.asm h_parse).

    IFNDEF BCH_STAMP
    DEFINE BCH_STAMP 'none'      ; build.ps1 -Bench passes the src\ stamp
    ENDIF

    MMU 7, BCH_PAGE, OVL_ORG

BCH_MODE_ISR     equ 3       ; ISR rows: flag BCH_ISR_FLAG picks the state's table
BCH_MODE_LOG     equ 5       ; the log step; modes 1-4 run benchTabDir tables
BCH_ISR_FLAG     equ 251     ; 0 idle, 1 AKY song, 2 streamed SFX (bench.dsf BISR/BISM/BISS)
BCH_LINE_MSB     equ $1E     ; active video line, bit 8
BCH_LINE_LSB     equ $1F     ; active video line, bits 7:0
BCH_LC_LO        equ 8       ; long clock read window: lines 8-239, clear
BCH_LC_HI        equ 239     ; of the frameCounter tick at line 248
NR_LINE_OFS      equ $64     ; NR $64 line offset: the clock basis needs 0

; Fixture contract, checked by tests/core303/test_fixture.py against bench.dsf.
BCH_MSG          equ 0       ; message 0 (kind 1): plain text, BCH_MSG_LEN characters
BCH_MSG_LEN      equ 114
BCH_PIC          equ 1       ; 001.NX3: 256x96 at 0,0, mode 0
BCH_PB_PAGES     equ 3       ; its 96 rows on the 256-wide surface: 3 x 8K pages
BCH_WIN_W        equ 80      ; window 0: column 0, 80 x 14
BCH_WIN_H        equ 14
BCH_PR_ROWS      equ 2       ; window rows the message prints into
TM_ROW_B         equ TM_COLS*2
BCH_SNAP_PAGE    equ BCH_PAGE + 1    ; bank 47's upper 8K: the window rows' snapshot,
                                     ; at DATA_WINDOW while mapped in slot 6
BCH_GT_PRO       equ 1       ; the turn table: entry 0 is _ _ PARSE 0, REDO ends a turn
BCH_GT_VERB      equ 27      ; gtLine's words: EXAMI (verb), LAMP (noun)
BCH_GT_NOUN      equ 50
BCH_GT_MSG       equ 3       ; PRO 5 answers with MES 3, DONE: one window line
BCH_GT_STEPS     equ 64      ; eng_step bound; the fixture's turn takes 16
GT_SNAP_FLAGS    equ DATA_WINDOW + BCH_WIN_H*TM_ROW_B    ; on BCH_SNAP_PAGE, after the rows
GT_SNAP_LOCS     equ GT_SNAP_FLAGS + 256
GT_SNAP_WINS     equ GT_SNAP_LOCS + 256
GT_ENG_LEN       equ 6       ; procSP, donePrev, isDone, curOpcode, curCondact, curProps
    ASSERT GT_SNAP_WINS + WINDOW_COUNT*WIN_SIZE <= DATA_WINDOW + $2000
    ASSERT donePrev == procSP + 1 && isDone == procSP + 2 && curProps == procSP + GT_ENG_LEN - 1
    ASSERT FLAG_NOUN1 == FLAG_VERB + 1
    ASSERT BCH_MSG_LEN < BCH_PR_ROWS*BCH_WIN_W - 20
    ASSERT WIN_X == 0 && WIN_Y == 1 && WIN_W == 2 && WIN_H == 3

; Reps, sized for at least 50 frames of workload at S=3 on a core without waits.
HD_R             equ 2048    ; about 25-60k T a rep
PR_R             equ 1024    ; about 40-80k T
SC_R             equ 512     ; about 95-105k T with the restore
PB_R             equ 128     ; about 0.4-1 frame
PL_R             equ 48      ; about 1-5 frames (SD)
ISR_R            equ 768     ; about 52-62k T (spin + poll)
ISR_SPIN         equ 2000    ; 26-31 T a pass: about 30 lines, under the 72 from line 239
                             ; to the wrap, so the first poll is never late
GT_R             equ 768     ; about 55-70k T turn, 20-25k T restore

; Row entry: ds 4 tag, dw n, dw reps, db speed, db page, dw init, dw prep, dw body, dw fini.
BR_N             equ 4
BR_REPS          equ 6
BR_SPEED         equ 8
BR_PAGE          equ 9
BR_INIT          equ 10
BR_PREP          equ 12
BR_BODY          equ 14
BR_FINI          equ 16
BR_LEN           equ 18

; init: once, untimed, CF set = #SKIP with DE = reason. prep: the restore before every
; workload, timed, MMU7 = BCH_PAGE. body: the workload, MMU7 = page. fini: HL = E, CF set =
; #SKIP with DE = reason. 0 = none.
    MACRO BROW btag, bunits, breps, bspeed, bpage, binit, bprep, bbody, bfini
BROW_AT = $
    db btag
    ASSERT $ - BROW_AT == 4
    ASSERT (bspeed) >= 0 && (bspeed) <= 3 && (breps) >= 1 && (breps) <= $FFFF
    dw bunits, breps
    db bspeed, bpage
    dw binit, bprep, bbody, bfini
    ASSERT $ - BROW_AT == BR_LEN
    ENDM

LOG_CAP          equ 2048    ; buffer bytes; putc refuses at or past this
    ASSERT low LOG_CAP == 0
LOG_RD_LEN       equ 256
LOG_WMODE        equ $0B     ; open or create, read + write: append by seeking to the size
; LOG FAIL hh: bits 7-5 the step, bits 4-0 the esxDOS error, or 0 for a short count,
; a position or size off, or a mismatch. 1F = the buffer filled (the session is dropped).
LOG_E_FULL       equ $1F
LOG_S_OPEN       equ $20
LOG_S_END        equ $40
LOG_S_WR         equ $60
LOG_S_CLW        equ $80
LOG_S_REOP       equ $A0
LOG_S_RD         equ $C0
LOG_S_CMP        equ $E0

; Mode in flags+250, ISR state in flags+251, both cleared (the nxb_entry convention). An
; empty buffer starts a session first: header, then B0CL and B1CL. NR $64, NR $07 and
; MMU6 restored on exit.
bench_entry:
    ld hl, flags+250
    ld a, (hl)
    ld (hl), 0
    ld (benchMode), a
    ld hl, flags+BCH_ISR_FLAG
    ld a, (hl)
    ld (hl), 0
    ld (benchIsr), a
    ld e, NR_MMU6
    call nr_read
    ld (benchMmu6), a
    ld e, NR_CPU_SPEED
    call nr_read
    ld (benchSpeed), a
    call bench_nr64_zero
    ld hl, (logPtr)
    ld a, h
    or l
    call z, bench_session
    ld a, (benchMode)
    cp BCH_MODE_LOG
    jr z, .log
    dec a
    cp BCH_MODE_LOG - 1
    jr nc, .out                  ; mode 0 or unknown: nothing more
    add a, a
    ld hl, benchTabDir
    add hl, a
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld a, (benchMode)
    cp BCH_MODE_ISR
    jr nz, .run
    ld a, (benchIsr)
    cp 3
    jr nc, .badisr
    add a, a
    add hl, a
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
.run:
    call bench_run_table
    jr .out
.badisr:                         ; flag 251 >= 3: logged, no rows
    ld hl, txtIsrBad
    ld de, txtState
    call log_skip
    jr .out
.log:
    call log_flush
.out:
    ld a, (benchNr64)
    nextreg NR_LINE_OFS, a
    ld a, (benchSpeed)
    and 3
    nextreg NR_CPU_SPEED, a
    ld a, (benchMmu6)
    nextreg NR_MMU6, a
    ret

bench_session:
    call log_header
    ld hl, benchTabCal
    ; falls through

; Run every BROW at HL (table ends with db 0). Corrupts everything.
bench_run_table:
    ld a, (hl)
    or a
    ret z
    ld (brRow), hl
    call bench_row
    ld hl, (brRow)
    ld de, BR_LEN
    add hl, de
    jr bench_run_table

; One row: init, NR $07 = speed, one bench_batch of reps, speed back, fini, log line.
bench_row:
    xor a
    ld (brSoft), a
    ld ix, (brRow)
    ld l, (ix + BR_INIT)
    ld h, (ix + BR_INIT + 1)
    ld a, h
    or l
    jr z, .go
    call jphl
    jp c, .skip
.go:
    ld ix, (brRow)
    ld a, (ix + BR_SPEED)
    nextreg NR_CPU_SPEED, a
    ld e, NR_CPU_SPEED
    call nr_read
    and 3                        ; S = NR $07 bits 1:0 as read back
    ld (brS), a
    xor a
    ld (brEState), a
    ld a, (ix + BR_PAGE)
    ld (bench_batch.page + 3), a ; nextreg reg,n is ED 91 reg n
    ld l, (ix + BR_BODY)
    ld h, (ix + BR_BODY + 1)
    ld (bench_batch.body + 1), hl
    ld l, (ix + BR_PREP)
    ld h, (ix + BR_PREP + 1)
    ld a, h
    or l
    jr nz, .prep
    ld hl, bench_none
.prep:
    ld (bench_batch.restore + 1), hl
    ld l, (ix + BR_REPS)
    ld h, (ix + BR_REPS + 1)
    ld (benchLeft), hl
    call bench_lc_start          ; the window: line0 .. line1 around the loop
    call bench_batch
    call bench_lc_end
    ld (brF), hl
    ld a, (brSoft)
    or a
    call nz, br_soft_f
    ld hl, (benchL1)
    ld de, (benchL0)
    or a
    sbc hl, de
    ld (brD), hl
    ld a, (benchSpeed)
    and 3
    nextreg NR_CPU_SPEED, a
    ld ix, (brRow)
    ld l, (ix + BR_FINI)
    ld h, (ix + BR_FINI + 1)
    ld a, h
    or l
    jr z, .done
    call jphl
    jp c, .skip
    ld (brE), hl
    ld a, 1
    ld (brEState), a
.done:
    ld hl, (brF)
    ld a, h
    and l
    inc a
    jr nz, br_log                ; F = $FFFF: the clock wait timed out
    ld de, brTxtClock
.skip:
    ld hl, (brRow)
    jp log_skip

; DI twin (frameCounter frozen): F = the raster wraps isr_body counted, plus one when
; line1 is below its last poll. A clock timeout keeps $FFFF. Corrupts AF, DE, HL.
br_soft_f:
    ld a, (benchLcBad)
    or a
    ret nz
    ld hl, (benchL1)
    ld de, (isrPrev)
    or a
    sbc hl, de
    ld hl, (isrWraps)
    jr nc, .st
    inc hl
.st:
    ld (brF), hl
    ret

; "<TAG> C=L S=d R=hhhh F=hhhh D=hhhh N=hhhh[ E=hhhh]".
br_log:
    ld hl, (brRow)
    call log_tag
    ld hl, logTxtCL
    call log_puts
    ld a, (brS)
    add a, '0'
    call log_putc
    ld hl, logTxtR
    call log_puts
    ld ix, (brRow)
    ld l, (ix + BR_REPS)
    ld h, (ix + BR_REPS + 1)
    call log_hex16
    ld hl, logTxtF
    call log_puts
    ld hl, (brF)
    call log_hex16
    ld hl, logTxtD
    call log_puts
    ld hl, (brD)
    call log_hex16
    ld hl, logTxtN
    call log_puts
    ld ix, (brRow)
    ld l, (ix + BR_N)
    ld h, (ix + BR_N + 1)
    call log_hex16
    ld a, (brEState)
    or a
    jp z, log_row_end
    ld hl, logTxtE
    call log_puts
    ld hl, (brE)
    call log_hex16
    jp log_row_end

; Out: HL = raster line 0-310. MSB read either side of the LSB, bounded retries.
; Corrupts AF, D.
bench_line:
    ld d, 4
.rd:
    NRGET BCH_LINE_MSB
    ld h, a
    NRGET BCH_LINE_LSB           ; the sample point
    ld l, a
    NRGET BCH_LINE_MSB
    cp h
    jr z, .ok
    dec d
    jr nz, .rd
.ok:
    ld a, h
    and 1
    ld h, a
    ret

; Poll until lines BCH_LC_LO-BCH_LC_HI, at most 65536 polls: a timeout sets
; benchLcBad instead of hanging. Corrupts AF, BC, DE, HL.
bench_lc_wait:
    ld de, 0
.poll:
    push de
    call bench_line
    pop de
    ld a, h
    or a
    jr nz, .next
    ld a, l
    sub BCH_LC_LO
    cp BCH_LC_HI - BCH_LC_LO + 1
    ret c
.next:
    dec de
    ld a, d
    or e
    jr nz, .poll
    dec a
    ld (benchLcBad), a
    ret

; Long clock (+3 timing, NR $64 = 0, as nxb_lc_start): frameCounter ticks 8 T
; into line 248. Wait for lines 8-239, then fc0, then line0. Corrupts AF, BC, DE, HL.
bench_lc_start:
    xor a
    ld (benchLcBad), a
    call bench_lc_wait
    ld hl, (frameCounter)
    ld (benchFc0), hl
    call bench_line
    ld (benchL0), hl
    ret

; line1, then fc1 at once at lines 8-239, else after the wait. Out: HL = F =
; fc1 - fc0 - [line1 in 240-310], $FFFF after a wait timeout. Corrupts AF, BC, DE.
bench_lc_end:
    call bench_line
    ld (benchL1), hl
    ld a, h
    or a
    jr nz, .late                 ; 256-310
    ld a, l
    cp BCH_LC_HI + 1
    jr nc, .late                 ; 240-255
    cp BCH_LC_LO
    call c, bench_lc_wait        ; 0-7
    ld hl, (frameCounter)
    jr .f
.late:
    call bench_lc_wait
    ld hl, (frameCounter)
    dec hl
.f:
    ld de, (benchFc0)
    or a
    sbc hl, de
    ld a, (benchLcBad)
    or a
    ret z
    ld hl, $FFFF
    ret

; NR $64 saved and zeroed; it applies at vc 64, so two backward steps of the line
; are waited, bounded (tests/core303/bench/irq.asm nr64_zero). Corrupts all.
bench_nr64_zero:
    ld e, NR_LINE_OFS
    call nr_read
    ld (benchNr64), a
    nextreg NR_LINE_OFS, 0
    ld hl, 0
    ld (nrLeft), hl              ; 65536 polls
    ld a, 2
    ld (nrSteps), a
    call bench_line
    ld (nrPrev), hl
.lp:
    call bench_line
    ld de, (nrPrev)
    ld (nrPrev), hl
    or a
    sbc hl, de                   ; CF = the line went back
    jr nc, .same
    ld hl, nrSteps
    dec (hl)
    ret z
.same:
    ld hl, (nrLeft)
    dec hl
    ld (nrLeft), hl
    ld a, h
    or l
    jr nz, .lp
    ret

; One untimed pass of bench_batch: HL = restore, DE = workload, A = page. bench_row
; patches the operands again for its own batch. Corrupts all; MMU7 = BCH_PAGE.
bench_once:
    ld (bench_batch.restore + 1), hl
    ld (bench_batch.body + 1), de
    ld (bench_batch.page + 3), a
    ld hl, 1
    ld (benchLeft), hl
    jp bench_batch

; HL += each of the BC bytes at DE (BC >= 1). Corrupts AF, BC, DE.
ck_mem:
    ld a, (de)
    add hl, a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, ck_mem
    ret

; A = 8K page, BC = bytes (1-8192): HL += each, read through slot 6. Corrupts AF, BC, DE.
ck_page:
    nextreg NR_MMU6, a
    ld de, DATA_WINDOW
    jr ck_mem

; HL = overlay2 address -> A = its byte, through slot 6 (left on OVL2_PAGE: bench_entry
; restores slot 6). Corrupts F, HL.
o2_peek:
    nextreg NR_MMU6, OVL2_PAGE
    add hl, (DATA_WINDOW - OVL_ORG) & $FFFF
    ld a, (hl)
    ret

; --- mode 1: text. B2HD decodes message BCH_MSG into hdBuf through txt_next_decoded;
; B2PR prints hdBuf through prn_char; B2SC scrolls the current window once.

; Restore: seek the message and start a fresh stream (print_msg's head). CF = no message.
hd_prep:
    ld a, 1                      ; kind 1: messages (msg_seek)
    ld e, BCH_MSG
    call msg_seek
    ld hl, tokActive
    ld (hl), 0
    ret

; Decode to hdBuf until the end of the message. Out: hdEnd past the last character.
hd_body:
    ld bc, hdBuf
.ch:
    call txt_next_decoded        ; preserves BC only
    jr c, .end
    ld (bc), a
    inc bc
    jr .ch
.end:
    ld (hdEnd), bc
    ret

; Count the message untimed (at most 256, reader depth kept), then decode it into hdBuf.
; CF + DE = reason unless audio is idle and the message is BCH_MSG_LEN characters.
hd_init:
    call isr_idle                ; audEnable sticks: a song or SFX would load every rep
    ret c
    ld a, (rdSaveSP)
    ld (hdDepth), a
    call hd_prep
    ld de, txtMsg
    ret c
    ld bc, 0
.n:
    call txt_next_decoded
    jr c, .e
    inc bc
    ld a, b
    or a
    jr z, .n
.e:
    ld a, (hdDepth)
    ld (rdSaveSP), a
    xor a
    ld (tokActive), a
    ld hl, -BCH_MSG_LEN
    add hl, bc
    ld a, h
    or l
    ld de, txtMsg
    scf
    ret nz
    call hd_prep
    call hd_body
    or a
    ret

; E = the decoded bytes plus the decoded length.
hd_fini:
    ld hl, (hdEnd)
    ld de, hdBuf
    or a
    sbc hl, de
    ld de, hdBuf
    ld bc, BCH_MSG_LEN
    jp ck_mem

; CF + DE = reason unless audio idle, 80-column mode, the window BCH_WIN_H x BCH_WIN_W at
; column 0 and no word pending. Then winRowAddr, winSnap (record), its rows to the snapshot.
tw_init:
    call isr_idle
    ret c
    ld de, txtWin
    ld a, (tmCols)
    cp BCH_WIN_W
    scf
    ret nz
    ld hl, (curWin)
    ld a, (hl)                   ; WIN_X
    or a
    scf
    ret nz
    inc hl
    ld b, (hl)                   ; WIN_Y
    inc hl
    ld a, (hl)                   ; WIN_W
    cp BCH_WIN_W
    scf
    ret nz
    inc hl
    ld a, (hl)                   ; WIN_H
    cp BCH_WIN_H
    scf
    ret nz
    ld a, (wrapLen)
    or a
    scf
    ret nz
    ld c, 0
    call tm_cell_addr            ; HL = row WIN_Y, column 0
    ld (winRowAddr), hl
    nextreg NR_MMU6, BCH_SNAP_PAGE
    ld de, DATA_WINDOW
    ld bc, BCH_WIN_H*TM_ROW_B
    ldir
    ld hl, (curWin)
    ld de, winSnap
    ld bc, WIN_SIZE
    ldir
    or a                         ; A = wrapLen = 0
    ret

; The message in hdBuf, then tw_rep.
pr_init:
    call hd_init
    ret c
; tw_init, then winRep = winSnap with the cursor home, 0 lines.
tw_rep:
    call tw_init
    ret c
    ld hl, winSnap
    ld de, winRep
    ld bc, WIN_SIZE
    ldir
    xor a
    ld (winRep+WIN_CURX), a
    ld (winRep+WIN_CURY), a
    ld (winRep+WIN_LINES), a
    ret

; Restore: window record = winRep, no word pending, the first BCH_PR_ROWS rows back.
pr_prep:
    ld hl, winRep
    ld de, (curWin)
    ld bc, WIN_SIZE
    ldir
    xor a
    ld (wrapLen), a
    nextreg NR_MMU6, BCH_SNAP_PAGE
    ld hl, DATA_WINDOW
    ld de, (winRowAddr)
    ld bc, BCH_PR_ROWS*TM_ROW_B
    ldir
    ret

; Print hdBuf through prn_char, then prn_flush for the last word (print_msg's tail).
pr_body:
    ld hl, hdBuf
.ch:
    ld c, (hl)
    push hl
    call prn_char
    pop hl
    inc hl
    ld de, hdBuf + BCH_MSG_LEN
    or a
    sbc hl, de
    add hl, de                   ; keeps Z from the sbc
    jr nz, .ch
    jp prn_flush

; E = the window record and its BCH_PR_ROWS rows; then winSnap and every row go back.
pr_fini:
    ld hl, 0
    ld de, (curWin)
    ld bc, WIN_SIZE
    call ck_mem
    ld de, (winRowAddr)
    ld bc, BCH_PR_ROWS*TM_ROW_B
    call ck_mem
    push hl
    ld hl, winSnap
    ld de, (curWin)
    ld bc, WIN_SIZE
    ldir
    call sc_prep
    pop hl
    ret

; Restore: every row of the window back from the snapshot.
sc_prep:
    nextreg NR_MMU6, BCH_SNAP_PAGE
    ld hl, DATA_WINDOW
    ld de, (winRowAddr)
    ld bc, BCH_WIN_H*TM_ROW_B
    ldir
    ret

; One window scroll, as win_newline's .scroll does it.
sc_body:
    call win_rect
    jp tm_scroll_rect

; E = the window's rows; then they go back.
sc_fini:
    ld hl, 0
    ld de, (winRowAddr)
    ld bc, BCH_WIN_H*TM_ROW_B
    call ck_mem
    push hl
    call sc_prep
    pop hl
    ret

; --- mode 2: NX3. B2PB redraws the staged picture through gfx_blit_pos in buffer mode
; (gfxDrawTarget 1: back surface only, no frame gate); B2PL loads it with a cold cache.

; CF + DE = reason unless audio idle and picture BCH_PIC staged positioned in the current
; mode, in screen mode with no override. Then the reveal state is kept, buffer mode set.
pb_init:
    call isr_idle
    ret c
    ld de, txtPic
    ld a, (stagedPic)
    cp BCH_PIC
    scf
    ret nz
    ld a, (gfxDrawTarget)
    or a
    scf
    ret nz
    ld hl, stagedPos
    call o2_peek
    rlca
    ccf
    ret c                        ; bit 7 clear: a plain picture
    ld hl, gfxPosOvr
    call o2_peek
    rrca
    ret c                        ; an armed override
    ld hl, l2Mode
    call o2_peek
    ld hl, stagedMode
    cp (hl)
    scf
    ret nz
    ld a, (gfxRevealPend)
    ld (pbPend), a
    ld a, (gfxRevealMode)
    ld (pbMode), a
    ld a, 1
    ld (gfxDrawTarget), a
    or a
    ret

; Restore: the reveal state buffer mode sets.
pb_prep:
    ld a, (pbPend)
    ld (gfxRevealPend), a
    ld a, (pbMode)
    ld (gfxRevealMode), a
    ret

; Screen mode and the reveal state back. E = the back surface's first BCH_PB_PAGES pages.
pb_fini:
    call pb_prep
    xor a
    ld (gfxDrawTarget), a
    ld hl, 0
    ld a, (l2BackBank)
    add a, a
    ld b, BCH_PB_PAGES
.pg:
    push bc
    push af
    ld bc, $2000
    call ck_page
    pop af
    pop bc
    inc a
    djnz .pg
    ret

; Restore: free every cache bank and empty the cache (overlay0 gfx_cache_free_banks).
pl_prep:
    ld a, (gfxBankNext)
    or a
    jp z, gfx_cache_empty
    ld b, a
    ld hl, gfxBankList
.f:
    ld a, (hl)
    call bank_free               ; preserves BC, DE, HL
    inc hl
    djnz .f
    jp gfx_cache_empty

; Audio idle, then one untimed cold load; CF + DE = reason unless BCH_PIC ends up staged.
pl_init:
    call isr_idle
    ret c
    ld hl, pl_prep
    ld de, bench_pic_load
    ld a, OVL2_PAGE
    call bench_once
    ld de, txtLoad
    ld a, (stagedPic)
    cp BCH_PIC
    scf
    ret nz
    or a
    ret

; E = the gfxSizeLo bytes the load cached, through the staged entry's bank run.
pl_fini:
    ld hl, gfxSizeLo
    call o2_peek
    ld e, a
    ld hl, gfxSizeLo + 1
    call o2_peek
    ld d, a
    ld (plLeft), de
    ld hl, 0
    ld a, (stagedEntry)
    cp GFX_EMPTY
    ret z
    ld a, d
    or e
    ret z                        ; nothing cached: no 64K pass
    ld a, (stagedEntry)
    call gce_ptr
    inc hl
    ld a, (hl)                   ; GCE_FIRST
    ld hl, gfxBankList
    add hl, a
    ld (plBank), hl
    ld hl, 0
.bank:
    ld de, (plBank)
    ld a, (de)
    inc de
    ld (plBank), de
    add a, a
    call .page
    ret z
    ld a, (plPage)
    inc a
    call .page
    ret z
    jr .bank
.page:                           ; A = page: HL += min(plLeft, 8K) bytes; Z = none left
    ld (plPage), a
    ld bc, (plLeft)
    ld a, b
    cp $20
    jr c, .take
    ld bc, $2000
.take:
    push hl
    ld hl, (plLeft)
    or a
    sbc hl, bc
    ld (plLeft), hl
    pop hl
    ld a, (plPage)
    call ck_page
    ld de, (plLeft)
    ld a, d
    or e
    ret

; --- mode 3: frame ISR. R x [spin, raster poll] with interrupts on against the same
; under DI; the DI twin is the companion (BRxx), its F counted from raster wraps since
; frameCounter stops. The twins differ only in the byte after the poll: ei or nop.
isr_body:
    ld de, ISR_SPIN
.spin:
    dec de
    ld a, d
    or e
    jr nz, .spin
    di
    call bench_line              ; both twins poll with interrupts off
isrEiOp:
    ei                           ; SMC: nop in the DI twin
    ld de, (isrPrev)
    ld (isrPrev), hl
    or a
    sbc hl, de
    ret nc
    ld hl, (isrWraps)
    inc hl
    ld (isrWraps), hl
    ret

; CF + DE = reason unless audio was never armed (audEnable 0: the ISR fast path).
isr_idle:
    ld a, (audEnable)
    or a
    ret z
    ld de, txtState
    scf
    ret

; Out: A bit 0 = song playing (audFlags bit 0), bit 1 = a sample channel playing
; (SMPB_FLAGS bit 0, either channel). Bank 24 through slot 6. Corrupts F, E, HL.
    ASSERT audFlags >= OVL_ORG && sfxChan0 >= DATA_WINDOW && sfxChan0 < OVL_ORG
aud_now:
    nextreg NR_MMU6, AUD_PAGE_HI
    ld a, (audFlags - OVL_ORG + DATA_WINDOW)
    and 1
    ld e, a
    nextreg NR_MMU6, AUD_PAGE_LO
    ld a, (sfxChan0 + SMPB_FLAGS)
    ld hl, sfxChan1 + SMPB_FLAGS
    or (hl)
    and 1
    add a, a
    or e
    ret

; CF + DE = reason unless the song plays with no sample (state 1) / a sample plays
; with no song (state 2).
isr_song:
    call aud_now
    cp 1
    jr isr_is
isr_sfx:
    call aud_now
    cp 2
isr_is:
    ld de, txtState
    scf
    ret nz
    or a
    ret

isr_on0:
    call isr_idle
    ret c
isr_on:
    ld a, $FB                    ; ei
    jr isr_arm
isr_di0:
    call isr_idle
    ret c
isr_di:
    ld a, 1
    ld (brSoft), a
    di                           ; isr_fini_di enables again
    xor a                        ; nop
isr_arm:
    ld (isrEiOp), a
    ld hl, 0
    ld (isrPrev), hl
    ld (isrWraps), hl
    ret
isr_onm:
    call isr_song
    ret c
    jr isr_on
isr_dim:
    call isr_song
    ret c
    jr isr_di
isr_ons:
    call isr_sfx
    ret c
    jr isr_on
isr_dis:
    call isr_sfx
    ret c
    jr isr_di

; E = the raster wraps the polls counted.
isr_fini_di:
    ei
isr_fini:
    ld hl, (isrWraps)
    ret

; --- mode 4: game turn. B2GT injects gtLine and runs bench_turn: PARSE 0, PRO 1, PRO 5
; (MES BCH_GT_MSG, DONE) and REDO, on a PRO 1 record one level above the caller's stack.

; CF + DE = reason unless audio idle (STATE), the window as tw_init wants (WIN), room for
; two more process levels and table BCH_GT_PRO (TURN). Then the snapshots, the record and
; one untimed turn: TURN unless it ends at REDO with BCH_GT_VERB, BCH_GT_NOUN parsed.
gt_init:
    call isr_idle
    ret c
    call tw_rep
    ret c
    ld de, txtTurn
    ld a, (procSP)
    cp PROC_DEPTH - 1
    ccf
    ret c
    ld a, (ddbHeader+HDR_NUMPRC)
    cp BCH_GT_PRO + 1
    ret c
    ld hl, procSP
    ld de, gtEng
    ld bc, GT_ENG_LEN
    ldir
    nextreg NR_MMU6, BCH_SNAP_PAGE
    ld hl, flags
    ld de, GT_SNAP_FLAGS
    ld bc, 256
    ldir                         ; DE = GT_SNAP_LOCS
    ld a, (numObj)
    or a
    jr z, .rec
    ld b, a
    ld hl, objTable
.loc:
    ld a, (hl)
    ld (de), a
    inc de
    add hl, OBJ_SIZE
    djnz .loc
.rec:
    ld hl, winTable
    ld de, GT_SNAP_WINS
    ld bc, WINDOW_COUNT*WIN_SIZE
    ldir
    ld a, (prevVerb)
    ld (gtPrev), a
    ld a, BCH_GT_PRO
    call eng_push_proc           ; at level L = gtEng's procSP; isDone = 0
    ld a, (gtEng)
    call eng_rec_ptr_a
    ld (gtRecAt), hl
    push hl
    ld de, gtRec
    ld bc, PREC_SIZE
    ldir
    pop hl
    inc hl
    ld (bench_turn.ent + 1), hl
    inc hl
    inc hl
    ld (bench_turn.rec + 1), hl
    ld hl, (gtRec + 1)
    ld (bench_turn.start + 1), hl
    ld a, (procSP)
    ld (bench_turn.base + 1), a
    xor a
    ld (gtRun), a
    ld (gtFail), a
    ld (gtDrift), a
    ld hl, gt_prep
    ld de, bench_turn
    ld a, BCH_PAGE
    call bench_once
    ld a, (gtFail)
    or a
    jr nz, .bad
    ld hl, (flags+FLAG_VERB)     ; L = verb, H = noun 1
    ld de, BCH_GT_VERB | (BCH_GT_NOUN << 8)
    sbc hl, de                   ; CF = 0 from the or
    jr nz, .bad
    call gt_ck
    ld (gtRef), hl
    xor a                        ; CF clear
    ld (gtRun), a
    ret
.bad:
    call gt_back
    ld de, txtTurn
    scf
    ret

; Restore: the last turn checked (gt_check, from the second call), flags, locations, window
; record, wrapLen, the record and procSP, then gtLine injected. Constant time.
gt_prep:
    ld a, (gtRun)
    or a
    call nz, gt_check
    ld a, 1
    ld (gtRun), a
    call gt_put
    ld hl, winRep
    ld de, (curWin)
    ld bc, WIN_SIZE
    ldir
    ld hl, gtRec
    ld de, (gtRecAt)
    ld bc, PREC_SIZE
    ldir
    ld a, (bench_turn.base + 1)
    ld (procSP), a
    xor a
    ld (wrapLen), a
    ld (isDone), a               ; as the push leaves it
    ld (injPending), a           ; the companion never consumes the line: no refusal
    ld hl, gtLine
    jp svc_inject                ; A = 0: no echo

; Flags and object locations back from the snapshot. Corrupts AF, BC, DE, HL.
gt_put:
    nextreg NR_MMU6, BCH_SNAP_PAGE
    ld hl, GT_SNAP_FLAGS
    ld de, flags
    ld bc, 256
    ldir                         ; HL = GT_SNAP_LOCS
    ld a, (numObj)
    or a
    ret z
    ld b, a
    ld de, objTable
.loc:
    ld a, (hl)
    ld (de), a
    inc hl
    add de, OBJ_SIZE
    djnz .loc
    ret

; HL = E: flags 0-255 plus every object's location. Corrupts AF, BC, DE.
gt_ck:
    ld hl, 0
    ld de, flags
    ld bc, 256
    call ck_mem
    ld a, (numObj)
    or a
    ret z
    ld b, a
    ld de, objTable
.loc:
    ld a, (de)
    add hl, a
    add de, OBJ_SIZE
    djnz .loc
    ret

; HL = E; gtDrift |= (E != gtRef) | gtFail, constant time. Corrupts AF, BC, DE.
gt_check:
    call gt_ck
    push hl
    ld de, (gtRef)
    or a
    sbc hl, de
    ld a, h
    or l
    ld hl, gtFail
    or (hl)
    ld hl, gtDrift
    or (hl)
    ld (hl), a
    pop hl
    ret

; As bench_entry found it: flags, locations, every window record, the window's rows,
; wrapLen, prevVerb, no line parked, procSP..curProps. Corrupts all.
gt_back:
    call gt_put
    ld hl, GT_SNAP_WINS
    ld de, winTable
    ld bc, WINDOW_COUNT*WIN_SIZE
    ldir
    call sc_prep
    ld a, (gtPrev)
    ld (prevVerb), a
    xor a
    ld (wrapLen), a
    ld (injPending), a
    ld hl, gtEng
    ld de, procSP
    ld bc, GT_ENG_LEN
    ldir
    ret

; E after the last turn, then gt_back. CF + DE = DRIFT when a turn's E differed from the
; init turn's or a turn failed.
gt_fini:
    call gt_check
    push hl
    call gt_back
    pop hl
    ld a, (gtDrift)
    or a
    ret z
    ld de, txtDrift
    scf
    ret
; Companion: its E is the restored state's, never DRIFT.
gt_fini0:
    call gt_fini
    or a
    ret

; Start the buffer: #CORE303 BENCH <stamp>, #NR and #SRAM lines.
log_header:
    ld hl, 0
    ld (logPtr), hl
    ld (logRows), hl
    xor a
    ld (logOver), a
    ld hl, logTxtHdr
    call log_puts
    ld hl, logTxtStamp
    call log_puts
    call log_eol
    ld hl, logTxtNr
    call log_puts
    ld hl, nrList
    ld b, NR_COUNT
.nr:
    ld a, ' '
    call log_putc
    ld a, (hl)
    call log_hex8
    ld a, '='
    call log_putc
    ld e, (hl)
    call nr_read                 ; preserves BC, DE, HL
    call log_hex8
    inc hl
    djnz .nr
    call log_eol
    ld hl, logTxtSram
    call log_puts
    ld hl, logTxtKb1
    ld a, (ramExpanded)
    or a
    jr z, .kb
    ld hl, logTxtKb2
.kb:
    call log_puts
    jp log_eol

; "#SKIP <tag> <reason>": HL = 4-byte tag, DE = reason (0-terminated).
log_skip:
    push de
    push hl
    ld hl, logTxtSkip
    call log_puts
    pop hl
    call log_tag
    ld a, ' '
    call log_putc
    pop hl
    call log_puts
    jp log_eol

; End a row line and count it for #END. Corrupts AF, HL.
log_row_end:
    ld hl, (logRows)
    inc hl
    ld (logRows), hl
log_eol:
    ld a, 10
; A -> logBuf at logPtr; at LOG_CAP the byte is dropped and logOver set. Corrupts F.
log_putc:
    push hl
    push af
    ld hl, (logPtr)
    ld a, h
    cp high LOG_CAP
    jr nc, .full
    inc hl
    ld (logPtr), hl
    dec hl
    add hl, logBuf
    pop af
    ld (hl), a
    pop hl
    ret
.full:
    ld a, 1
    ld (logOver), a
    pop af
    pop hl
    ret

; HL = 0-terminated string. Out: HL past the 0. Corrupts AF.
log_puts:
    ld a, (hl)
    inc hl
    or a
    ret z
    call log_putc
    jr log_puts

; HL = 4-byte tag. Corrupts AF, HL.
log_tag:
    push bc
    ld b, 4
.ch:
    ld a, (hl)
    inc hl
    call log_putc
    djnz .ch
    pop bc
    ret

; Corrupts AF.
log_hex16:
    ld a, h
    call log_hex8
    ld a, l
log_hex8:
    push af
    swapnib
    call hex_digit
    call log_putc
    pop af
    call hex_digit
    jp log_putc

; A low nibble -> ASCII hex digit.
hex_digit:
    and $0F
    add a, '0'
    cp '9' + 1
    ret c
    add a, 7
    ret

; Append "#END hhhh" and the buffer to BENCH303.LOG, close, reopen, check the size
; grew by exactly the buffer, read it back and compare. LOG OK empties the buffer;
; LOG FAIL hh drops the #END line again, so a retry appends the whole run. Corrupts all.
log_flush:
    ld (logSp), sp               ; every failure unwinds to here
    ld a, $FF
    ld (logH), a                 ; no handle open
    ld hl, (logPtr)
    ld (logMark), hl
    ld hl, logTxtEnd
    call log_puts
    ld hl, (logRows)
    call log_hex16
    call log_eol
    xor a
    ld (logStep), a
    ld a, (logOver)
    or a
    jr z, .room
    xor a                        ; full: log_fail rewinds to logMark = 0, so the
    ld (logOver), a              ; next entry opens a new session
    ld h, a
    ld l, a
    ld (logMark), hl
    ld a, LOG_E_FULL
    jp log_fail
.room:
    ld a, LOG_S_OPEN
    ld (logStep), a
    ld b, LOG_WMODE
    call log_open
    ld a, LOG_S_END
    ld (logStep), a
    call log_size
    ld hl, logStat + 7           ; the size is the append offset
    ld de, logOfs
    ld bc, 4
    ldir
    call log_seek
    ld a, LOG_S_WR
    ld (logStep), a
    ld bc, (logPtr)              ; the whole buffer, one write (under 8K)
    push bc
    ld a, (logH)
    ld ix, logBuf
    call esx_fwrite
    pop hl
    jp c, log_fail
    or a                         ; Fc = 0 can still return a short BC
    sbc hl, bc
    jp nz, log_short
    ld a, LOG_S_CLW
    ld (logStep), a
    call log_close               ; written data persists only once closed
    jp c, log_fail
    ld a, LOG_S_REOP
    ld (logStep), a
    ld b, ESX_MODE_READ
    call log_open
    call log_size
    ld hl, (logStat + 7)         ; size - offset must equal logPtr
    ld de, (logOfs)
    or a
    sbc hl, de
    ex de, hl
    ld hl, (logStat + 9)
    ld bc, (logOfs + 2)
    sbc hl, bc
    jp nz, log_short
    ld hl, (logPtr)
    or a
    sbc hl, de
    jp nz, log_short
    call log_seek
    ld a, LOG_S_RD
    ld (logStep), a
    ld hl, logBuf
    ld (logCmp), hl              ; next buffer byte to compare
    ld hl, (logPtr)
    ld (logLeft), hl
.chunk:
    ld hl, (logLeft)
    ld a, h
    or l
    jr z, .done
    ld bc, LOG_RD_LEN
    ld a, h
    or a
    jr nz, .take
    ld c, l
    ld b, 0
.take:
    or a
    sbc hl, bc
    ld (logLeft), hl
    ld (logChunk), bc
    ld a, (logH)
    ld ix, logRd
    call esx_fread
    jp c, log_fail
    ld hl, (logChunk)            ; EOF before the count
    or a
    sbc hl, bc
    jp nz, log_short
    ld de, (logCmp)
    ld hl, logRd
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .bad
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .cmp
    ld (logCmp), de
    jr .chunk
.bad:
    ld a, LOG_S_CMP
    ld (logStep), a
    jr log_short
.done:
    ld a, LOG_S_CMP
    ld (logStep), a
    call log_close
    jp c, log_fail
    ld hl, 0                     ; logged: the next entry starts a new session
    ld (logPtr), hl
    ld (logRows), hl
    xor a
    jr log_show

; A short count, a position or size off, or a mismatch at the current step.
log_short:
    xor a
; A = the esxDOS error at the current step: close any open handle, drop #END, show.
log_fail:
    and $1F
    ld hl, logStep
    or (hl)
    ld sp, (logSp)
    ld (logErr), a
    ld a, (logH)
    inc a                        ; $FF: no handle
    call nz, log_close           ; its result is not the one reported
    ld hl, (logMark)
    ld (logPtr), hl
    ld a, (logErr)
; A = 0 (LOG OK) or the code (LOG FAIL hh), on a blanked tilemap row 31.
log_show:
    push af
    ld bc, (TM_ROWS - 1) << 8
    ld d, 1
    ld a, (tmCols)
    ld e, a
    call tm_clear_blank
    ld c, 0
    ld hl, logTxtLog
    call bench_puts
    pop af
    or a
    ld hl, logTxtOk
    jr z, bench_puts
    push af
    ld hl, logTxtFail
    call bench_puts
    pop af
    ld hl, logHex
    push hl
    push af
    swapnib
    call hex_digit
    ld (hl), a
    inc hl
    pop af
    call hex_digit
    ld (hl), a
    pop hl
; HL = 0-terminated string, C = column, on row 31. Corrupts AF, B, E, HL.
bench_puts:
    ld a, (hl)
    or a
    ret z
    inc hl
    push hl
    ld b, TM_ROWS - 1
    ld e, TM_ATTR_DEFAULT
    call tm_putc_at
    pop hl
    inc c
    jr bench_puts

; B = F_OPEN mode: default drive, open BENCH303.LOG, keep the handle.
log_open:
    push bc
    call esx_getsetdrv           ; A = the default drive
    pop bc
    jp c, log_fail
    ld ix, logName
    call esx_fopen
    jp c, log_fail
    ld (logH), a
    ret

; F_FSTAT the open handle into logStat.
log_size:
    ld a, (logH)
    ld ix, logStat
    call esx_fstat
    ret nc
    jp log_fail

; Seek to logOfs from the start (IXL = 0); BCDE returned must equal it.
log_seek:
    ld de, (logOfs)
    ld bc, (logOfs + 2)
    ld a, (logH)
    ld ix, 0
    call esx_fseek
    jp c, log_fail
    ld hl, (logOfs)
    or a
    sbc hl, de
    jp nz, log_short
    ld hl, (logOfs + 2)
    sbc hl, bc                   ; CF = 0: the low words matched
    ret z
    jp log_short

; Close the handle and mark it closed. Out: F_CLOSE's CF and A.
log_close:
    ld hl, logH
    ld a, (hl)
    ld (hl), $FF
    jp esx_fclose

; Default calibration: the batch loop with no restore and an empty workload, S=3 and S=2.
benchTabCal:
    BROW "B0CL", 1, $FFFF, 3, BCH_PAGE, 0, 0, bench_none, 0
    BROW "B1CL", 1, $FFFF, 2, BCH_PAGE, 0, 0, bench_none, 0
    db 0
benchTabDir:                     ; modes 1-4
    dw benchTab1, benchTab2, benchTab3, benchTab4
    ASSERT $ - benchTabDir == (BCH_MODE_LOG - 1) * 2
; Text rows: each workload after its companion, 28 MHz then 14 MHz.
benchTab1:
    BROW "BRHD", 1, HD_R, 3, BCH_PAGE, hd_init, hd_prep, bench_none, 0
    BROW "B2HD", BCH_MSG_LEN, HD_R, 3, BCH_PAGE, hd_init, hd_prep, hd_body, hd_fini
    BROW "BRHD", 1, HD_R, 2, BCH_PAGE, hd_init, hd_prep, bench_none, 0
    BROW "B3HD", BCH_MSG_LEN, HD_R, 2, BCH_PAGE, hd_init, hd_prep, hd_body, hd_fini
    BROW "BRPR", 1, PR_R, 3, BCH_PAGE, pr_init, pr_prep, bench_none, pr_fini
    BROW "B2PR", BCH_MSG_LEN, PR_R, 3, BCH_PAGE, pr_init, pr_prep, pr_body, pr_fini
    BROW "BRPR", 1, PR_R, 2, BCH_PAGE, pr_init, pr_prep, bench_none, pr_fini
    BROW "B3PR", BCH_MSG_LEN, PR_R, 2, BCH_PAGE, pr_init, pr_prep, pr_body, pr_fini
    BROW "BRSC", 1, SC_R, 3, BCH_PAGE, tw_init, sc_prep, bench_none, sc_fini
    BROW "B2SC", 1, SC_R, 3, BCH_PAGE, tw_init, sc_prep, sc_body, sc_fini
    BROW "BRSC", 1, SC_R, 2, BCH_PAGE, tw_init, sc_prep, bench_none, sc_fini
    BROW "B3SC", 1, SC_R, 2, BCH_PAGE, tw_init, sc_prep, sc_body, sc_fini
    db 0
; NX3 rows: the blit first (the picture as BPIC staged it), then the cold load.
benchTab2:
    BROW "BRPB", 1, PB_R, 3, OVL2_PAGE, pb_init, pb_prep, bench_none, pb_fini
    BROW "B2PB", 1, PB_R, 3, OVL2_PAGE, pb_init, pb_prep, gfx_blit_pos, pb_fini
    BROW "BRPB", 1, PB_R, 2, OVL2_PAGE, pb_init, pb_prep, bench_none, pb_fini
    BROW "B3PB", 1, PB_R, 2, OVL2_PAGE, pb_init, pb_prep, gfx_blit_pos, pb_fini
    BROW "BRPL", 1, PL_R, 3, OVL2_PAGE, pl_init, pl_prep, bench_none, pl_fini
    BROW "B2PL", 1, PL_R, 3, OVL2_PAGE, pl_init, pl_prep, bench_pic_load, pl_fini
    db 0
benchTab3:                       ; by flag BCH_ISR_FLAG: idle, AKY song, streamed SFX
    dw benchIsr0, benchIsrM, benchIsrS
benchIsr0:
    BROW "BRI0", 1, ISR_R, 3, BCH_PAGE, isr_di0, 0, isr_body, isr_fini_di
    BROW "B2I0", 1, ISR_R, 3, BCH_PAGE, isr_on0, 0, isr_body, isr_fini
    db 0
benchIsrM:
    BROW "BRIM", 1, ISR_R, 3, BCH_PAGE, isr_dim, 0, isr_body, isr_fini_di
    BROW "B2IM", 1, ISR_R, 3, BCH_PAGE, isr_onm, 0, isr_body, isr_fini
    db 0
benchIsrS:
    BROW "BRIS", 1, ISR_R, 3, BCH_PAGE, isr_dis, 0, isr_body, isr_fini_di
    BROW "B2IS", 1, ISR_R, 3, BCH_PAGE, isr_ons, 0, isr_body, isr_fini
    db 0
benchTab4:                       ; game turn
    BROW "BRGT", 1, GT_R, 3, BCH_PAGE, gt_init, gt_prep, bench_none, gt_fini0
    BROW "B2GT", 1, GT_R, 3, BCH_PAGE, gt_init, gt_prep, bench_turn, gt_fini
    BROW "BRGT", 1, GT_R, 2, BCH_PAGE, gt_init, gt_prep, bench_none, gt_fini0
    BROW "B3GT", 1, GT_R, 2, BCH_PAGE, gt_init, gt_prep, bench_turn, gt_fini
    db 0

nrList:      db $01, $0E, $0F, $03, $05, $07
NR_COUNT     equ $ - nrList
logTxtHdr:   db "#CORE303 BENCH ", 0
logTxtStamp: db BCH_STAMP, 0
logTxtNr:    db "#NR", 0
logTxtSram:  db "#SRAM ", 0
logTxtKb1:   db "1024", 0
logTxtKb2:   db "2048", 0
logTxtSkip:  db "#SKIP ", 0
logTxtEnd:   db "#END ", 0
logTxtCL:    db " C=L S=", 0
logTxtR:     db " R=", 0
logTxtF:     db " F=", 0
logTxtD:     db " D=", 0
logTxtN:     db " N=", 0
logTxtE:     db " E=", 0
brTxtClock:  db "CLOCK", 0
txtMsg:      db "MSG", 0
txtWin:      db "WIN", 0
txtPic:      db "PIC", 0
txtLoad:     db "LOAD", 0
txtState:    db "STATE", 0
txtTurn:     db "TURN", 0
txtDrift:    db "DRIFT", 0
gtLine:      db "EXAMINE LAMP", 0
txtIsrBad:   db "B2IX"           ; #SKIP tag for an unknown ISR state (4 bytes)
logName:     db "BENCH303.LOG", 0
logTxtLog:   db "LOG ", 0
logTxtOk:    db "OK", 0
logTxtFail:  db "FAIL ", 0
logHex:      db 0, 0, 0

benchMode:   db 0
benchIsr:    db 0
benchSpeed:  db 0
benchMmu6:   db 0
benchNr64:   db 0
nrLeft:      dw 0
nrPrev:      dw 0
nrSteps:     db 0
brRow:       dw 0
brS:         db 0
brF:         dw 0
brD:         dw 0
brE:         dw 0
brEState:    db 0
brSoft:      db 0                ; 1 = F from isr_body's wrap count (DI twin)
benchFc0:    dw 0
benchL0:     dw 0
benchL1:     dw 0
benchLcBad:  db 0
isrPrev:     dw 0
isrWraps:    dw 0
hdDepth:     db 0
hdEnd:       dw 0
winRowAddr:  dw 0
pbPend:      db 0
pbMode:      db 0
plBank:      dw 0
plLeft:      dw 0
plPage:      db 0
gtRun:       db 0                ; 0 until gt_prep's first call
gtDrift:     db 0
gtPrev:      db 0                ; prevVerb at bench entry
gtRef:       dw 0
gtRecAt:     dw 0
gtRec:       ds PREC_SIZE        ; BCH_GT_PRO at its first entry
gtEng:       ds GT_ENG_LEN       ; procSP..curProps at bench entry
logPtr:      dw 0                ; offset in logBuf; 0 = no session open
logRows:     dw 0
logOver:     db 0
logMark:     dw 0
logSp:       dw 0
logH:        db 0
logStep:     db 0
logErr:      db 0
logLeft:     dw 0
logChunk:    dw 0
logCmp:      dw 0
logOfs:      ds 4
logStat:     ds 11
winSnap:     ds WIN_SIZE
winRep:      ds WIN_SIZE
hdBuf:       ds BCH_MSG_LEN
logRd:       ds LOG_RD_LEN
logBuf:      ds LOG_CAP

    DISPLAY "bench ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
