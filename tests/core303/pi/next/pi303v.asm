; PI303V: P4 Next side. Banks: mailbox 16 ($80000), LOAD 6 LDIR pages 17 ($84000), bank 5 save 18
; ($88000), Layer 2 front 19-21 ($8C000), back 22-24 ($98000), result 41-43 ($E4000); all below
; $200000. Build: build.ps1 (STAMP_STR), PI303V.NEX + PI303V.MAP.
    DEVICE ZXSPECTRUMNEXT

    IFNDEF STAMP_STR
    ASSERT 0, "STAMP_STR missing: build with build.ps1"
    DEFINE STAMP_STR 'none'
    ENDIF
    DEFINE LOG_NAME_STR "PI303V.LOG"
    DEFINE BENCH_NAME_STR "PI"

    INCLUDE "../../bench/rowdefs.asm"

; ---- memory: 8K page p at physical $40000 + p x $2000 (zxnddma.gde 2.5) ----
PHYS_RAM         equ $40000
PHYS_LIMIT       equ $200000     ; the Pi's address is 21 bits
MBOX_BANK        equ 16
MIX_BANK         equ 17          ; LOAD 6 LDIR source and destination pages
SAVE_BANK        equ 18          ; bank 5 region save page
L2F_BANK         equ 19          ; NR $12 at start: the front buffer
L2B_BANK         equ 22          ; NR $13 at start: the back buffer
L2_BANKS         equ 3           ; 256x192 = 48K, 3 16K banks (dev guide, Layer 2)
MBOX_PAGE        equ MBOX_BANK * 2
MIX_SRC_PAGE     equ MIX_BANK * 2
MIX_DST_PAGE     equ MIX_BANK * 2 + 1
SAVE_PAGE        equ SAVE_BANK * 2
BANK5_PAGE       equ 10
MBOX_PHYS        equ PHYS_RAM + MBOX_PAGE * $2000
; NR $12 bank b is fetched from SRAM (b + 16) x 16K, blank at 2 MB (30205 layer2.vhd:172,175)
L2F_PHYS         equ PHYS_RAM + L2F_BANK * $4000
L2B_PHYS         equ PHYS_RAM + L2B_BANK * $4000
L2_LEN           equ L2_BANKS * $4000

; ---- mailbox page through MMU2 ($4000): byte offsets, states, commands ----
MB_WIN           equ $4000
MB_MAGIC         equ 0
MB_SEQ           equ 4
MB_CMD           equ 5
MB_ARG0          equ 6
MB_ACK           equ 12
MB_STATE         equ 13
MB_HB_NEXT       equ 14
MB_HB_PI         equ 16
MB_LEADER        equ 18
MB_RES_PHYS      equ 20
MB_RES_LEN       equ 23
MB_LEN           equ 25
ST_READY         equ 1
ST_DONE          equ 2
ST_FAILED        equ 3
ST_EXITING       equ 4
CMD_STOP         equ 3
CMD_LOAD         equ 4
CMD_END          equ 5
PROF_HALT        equ 0           ; LOAD arg0: run 1
PROF_MIX         equ 6           ; run 2; the Pi maps it to P3's LDIR profile ceiling

; ---- watch: frames counted by pi_frame_isr, 50 Hz ----
TIMEOUT_FR       equ 120 * 50    ; no change to hb_pi, cmd_seq or ack_seq
KEY_FR           equ 2 * 50      ; SPACE held
SETTLE_FR        equ 2 * 50      ; hb_pi unchanged before the restore
BOUND_FR         equ 10 * 50
KEY_PORT         equ $7FFE       ; SPACE = bit 0, low when held

; ---- Layer 2 and the loads ----
NR_L2_BANK       equ $12         ; 7-bit 16K bank, read back (30205 zxnext.vhd:5783,6518)
NR_L2_SHADOW     equ $13
NR_L2_XS         equ $16
NR_L2_YS         equ $17
NR_DISP1         equ $69         ; bit 7 = Layer 2 on (30205 zxnext.vhd:4438-4439,6683)
NR_L2_CTRL       equ $70         ; bits 5:4 = 00 256x192, 3:0 palette offset (zxnext.vhd:6039)
L2_ON            equ %10000000
L2_FILL          equ $02
    ASSERT L2_FILL != $E3        ; NR $14 reset value: transparent
NR_PI_EN         equ $A0
PI_SPI_BIT       equ %00000010   ; NR $A0 bit 1: the Pi SPI slave
DATA_WIN         equ $C000       ; MMU6
HI_WIN           equ $E000       ; MMU7
MIX_CHUNK        equ 32          ; bytes per iteration, each part
    ASSERT MIX_CHUNK * 256 == $2000  ; 256 iterations cover a page: one MMU write a step
B5_REGION        equ $6000       ; bank 5 page 11 through MMU3, off the ULA screen
B5_OFF           equ $2000       ; its bank 5 offset
B5_LEN           equ 256
    ASSERT low B5_REGION == 0 && B5_LEN == 256  ; inc l wraps inside the region
B5_DOC           equ 30 + B5_LEN * 21 - 5
B5_COST          equ (B5_DOC * 4 + 2) / 3
STAT_TXT_ROW     equ 1
NOTE_TXT_ROW     equ 5
P1_FRAMES        equ 64          ; dma.asm's reps use probe.asm's names
POLL_FAST        equ 337

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
    ld a, NR_PI_EN
    call nr_read
    ld (savedA0), a
    or PI_SPI_BIT
    nextreg NR_PI_EN, a
    call l2_save
    call log_nr
    call b5_save                 ; LOAD 6's bank 5 region, before state 1
    call l2_setup                ; the Next writes NR $12/$13 again only in restore_all
    call mb_init
    call fi_on
    xor a
    call load_set
    call follow                  ; LOAD 0 and 6 until END
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
    ld hl, tagPi4x
    call log_skip
    jp restore_all

; ---- follower only: the Pi leads; one load step, hb_next, watch, then any new command ----
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
.bad:
    ld hl, (badCmds)             ; any other command or profile: acked, counted
    inc hl
    ld (badCmds), hl
.ack:
    call mb_ack
    jr .lp
.load:
    ld a, (mbSh + MB_ARG0)
    cp PROF_HALT
    jr z, .set
    cp PROF_MIX
    jr nz, .bad
.set:
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

; A = profile (0 or 6): MMU canonical, status row. Corrupts all.
load_set:
    ld (loadProf), a
    push af
    call mmu_canon
    ld bc, STAT_TXT_ROW << 8
    call ula_at
    ld hl, txtLoad
    call ula_puts
    pop af
    add a, '0'
    call ula_putc
    ld hl, txtPad
    jp ula_puts

; One step of the current load, about a frame. Corrupts all.
load_step:
    ld a, (loadProf)
    cp PROF_MIX
    jp z, mix_step
    ei                           ; LOAD 0: HALT to the frame interrupt
    jp pi_halt

; LOAD 6: 256 iterations of a MIX_CHUNK SRAM LDIR (page to page) then MIX_CHUNK bank 5 reads
; and writes; then MMU6 rewritten with its own page. Corrupts all and the alternate set.
mix_step:
    nextreg NR_MMU6, MIX_SRC_PAGE
    nextreg NR_MMU7, MIX_DST_PAGE
    exx
    ld hl, B5_REGION
    exx
    ld hl, DATA_WIN
    ld de, HI_WIN
.it:
    ld bc, MIX_CHUNK
    ldir
    exx
    ld b, MIX_CHUNK
.b5:
    ld a, (hl)
    ld (hl), a
    inc l
    djnz .b5
    exx
    ld a, h
    cp high HI_WIN               ; the source page is done after 256 iterations
    jr nz, .it
    nextreg NR_MMU6, MIX_SRC_PAGE
    jp mmu_canon

; ---- Layer 2 ----
; l2NrList read into l2Saved. Corrupts AF, BC, DE, HL.
l2_save:
    ld hl, l2NrList
    ld de, l2Saved
    ld b, L2_NR_COUNT
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

; "#NR A0=hh" then each saved Layer 2 register. Corrupts AF, B, DE, HL.
log_nr:
    ld hl, txtNrA0
    call log_puts
    ld a, (savedA0)
    call log_hex8
    ld hl, l2NrList
    ld de, l2Saved
    ld b, L2_NR_COUNT
.nr:
    ld a, ' '
    call log_putc
    ld a, (hl)
    inc hl
    call log_hex8
    ld a, '='
    call log_putc
    ld a, (de)
    inc de
    call log_hex8
    djnz .nr
    jp log_eol

; Both buffers cleared, 256x192 at palette offset 0, no scroll, NR $12/$13 set, then
; Layer 2 on. Corrupts all.
l2_setup:
    ld a, L2F_BANK * 2
    call l2_clear
    ld a, L2B_BANK * 2
    call l2_clear
    nextreg NR_L2_CTRL, 0
    nextreg NR_L2_XS, 0
    nextreg NR_L2_YS, 0
    nextreg NR_L2_BANK, L2F_BANK
    nextreg NR_L2_SHADOW, L2B_BANK
    ld a, L2F_BANK
    ld (l2Last), a
    ld a, (l2Saved + L2_I_DISP1)
    or L2_ON
    nextreg NR_DISP1, a
    ret

; A = first 8K page: L2_BANKS x 2 pages filled with L2_FILL through MMU6. Corrupts all.
l2_clear:
    ld b, L2_BANKS * 2
.pg:
    push bc
    push af
    nextreg NR_MMU6, a
    ld hl, DATA_WIN
    ld de, DATA_WIN + 1
    ld bc, $2000 - 1
    ld (hl), L2_FILL
    ldir
    pop af
    pop bc
    inc a
    djnz .pg
    jp mmu_canon

; l2Saved written back in list order: NR $69 first (Layer 2 off as at start). DI only.
; Corrupts AF, BC, DE, HL.
l2_restore:
    ld hl, l2NrList
    ld de, l2Saved
    ld b, L2_NR_COUNT
.nr:
    push bc
    ld bc, NR_SEL
    ld a, (hl)
    out (c), a
    inc b
    ld a, (de)
    out (c), a
    pop bc
    inc hl
    inc de
    djnz .nr
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

; HL = hb_next now.
mb_hb_next:
    call mb_on
    ld hl, (MB_WIN + MB_HB_NEXT)
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

; Frame ISR: piFrames + 1; NR $12 read with the NR select kept (30205 zxnext.vhd:5149), a
; change since the last interrupt counted in framesSeen (one Pi flip). Registers kept.
pi_frame_isr:
    push af
    push bc
    push hl
    ld hl, (piFrames)
    inc hl
    ld (piFrames), hl
    ld bc, NR_SEL
    in l, (c)
    ld a, NR_L2_BANK
    out (c), a
    inc b
    in a, (c)
    dec b
    out (c), l
    ld hl, l2Last
    cp (hl)
    jr z, .same
    ld (hl), a
    ld hl, (framesSeen)
    inc hl
    ld (framesSeen), hl
.same:
    pop hl
    pop bc
    pop af
    ei
    reti

; ---- exit rows ----
; P4NX (N = flips seen; CK = unknown commands, OK = none) and P4HB (N = hb_next).
; Corrupts all.
p4_rows:
    ld hl, tagP4nx
    ld de, (framesSeen)
    call p4_head
    ld hl, logTxtCK
    call log_puts
    ld hl, (badCmds)
    call log_hex16
    ld a, h
    or l
    ld hl, logTxtOK
    jr z, .v
    ld hl, logTxtBAD
.v:
    call log_puts
    call log_row_end
    call mb_hb_next
    ex de, hl
    ld hl, tagP4hb
    call p4_head
    jp log_row_end

; HL = tag, DE = N: "<tag> C=W S=3 R=0001 F=<frames since state 1> D=0000 N=<DE>".
; Corrupts AF, HL.
p4_head:
    push de
    call log_tag
    ld hl, logTxtCW
    call log_puts
    ld a, '3'
    call log_putc
    ld hl, logTxtR
    call log_puts
    ld hl, 1
    call log_hex16
    ld hl, logTxtF
    call log_puts
; F, N and frames_seen are mod 65536; F covers state 1 through exit, the settle included.
    ld hl, (piFrames)
    call log_hex16
    ld hl, logTxtD
    call log_puts
    ld hl, 0
    call log_hex16
    ld hl, logTxtN
    call log_puts
    pop hl
    jp log_hex16

; P4B5 (restore_all): the bank 5 region back from the save page, its ck16 checked.
b5_init:
    nextreg NR_MMU7, SAVE_PAGE
    or a
    ret
b5_body:
    ld hl, HI_WIN
    ld de, B5_REGION
    ld bc, B5_LEN
    ldir
    ret
b5_check:
    ld hl, B5_REGION
    ld bc, B5_LEN
    call ck16
    ld de, (b5Ck)
    jp ck_cmp

; The bank 5 region copied to the save page, its ck16 kept. Corrupts all.
b5_save:
    nextreg NR_MMU7, SAVE_PAGE
    ld hl, B5_REGION
    ld de, HI_WIN
    ld bc, B5_LEN
    ldir
    ld hl, B5_REGION
    ld bc, B5_LEN
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
; Order: exiting, the Pi settled, P4NX/P4HB, Layer 2 registers, bank 5 restored and logged,
; SD flush, result, state (3 if the restore fails its checksum or the SD flush fails).
restore_all:
    di
    ld sp, STACK_TOP
    call mmu_canon
    ld a, ST_EXITING
    call mb_state                ; the Pi stops all writes but a last hb_pi
    call fi_on
    call pi_settle
    jr nc, .settled
    ld hl, tagPi4x
    ld de, txtPiBusy
    call log_skip
.settled:
    call rt_restore              ; DI, frame vector back on the stub: framesSeen is final
    call p4_rows
    call l2_restore
    xor a
    ld (blkBad), a
    ld (rtCkState), a
    ld hl, b5Table
    call run_table               ; P4B5, CK against the startup checksum
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
; The only HALT. Under EI (load_step, pi_settle) it returns at the next interrupt; after
; restore_all it runs under DI and is the end.
pi_halt:
    halt
    ret

    INCLUDE "../../bench/runner.asm"

b5Table:
    ROW "P4B5", B5_LEN, 1, B5_COST, 3, CPU, b5_init, b5_body, b5_check
    db 0

; NR $69 first: l2_restore turns Layer 2 back off before the banks move.
l2NrList:    db NR_DISP1, NR_L2_BANK, NR_L2_SHADOW, NR_L2_XS, NR_L2_YS, NR_L2_CTRL
L2_NR_COUNT  equ $ - l2NrList
L2_I_DISP1   equ 0
l2Saved:     ds L2_NR_COUNT

mbMagic:     db "M303"
tagPi4x:     db "PI4X"
tagP4nx:     db "P4NX"
tagP4hb:     db "P4HB"
txtTimeout:  db "TIMEOUT", 0
txtKey:      db "KEY", 0
txtPiBusy:   db "PIBUSY", 0
txtNrA0:     db "#NR A0=", 0
txtLoad:     db "LOAD ", 0
txtPad:      db "   ", 0
txtState:    db "PI303V STATE ", 0
txtNote1:    db "NR A0 BIT 1 LEFT SET FOR THE PI", 0
txtNote2:    db "RESET TO CLEAR IT", 0
piFrames:    dw 0
framesSeen:  dw 0
l2Last:      db 0
badCmds:     dw 0
wHbPi:       dw 0
wSeq:        db 0
wAck:        db 0
wFrame:      dw 0
wKey:        db 0
wKeyFr:      dw 0
mbSh:        ds MB_LEN
stT0:        dw 0
stT1:        dw 0
stHb:        dw 0
loadProf:    db 0
savedA0:     db 0
endState:    db 0
b5Ck:        dw 0
blkBad:      db 0

    INCLUDE "../../bench/runner_data.asm"

    ASSERT $ <= CODE_LIMIT
    ASSERT LOG_HDR_MAX + LOG_ROW_MAX + (ROW_TOTAL + 5) * LOG_ROW_MAX + LOG_END_MAX <= LOG_CAP
LOG_BANK         equ LOG_PAGE / 2
LOG_BANKS        equ LOG_PAGES / 2
LOG_PHYS         equ PHYS_RAM + LOG_PAGE * $2000
    ASSERT LOG_PAGE % 2 == 0 && LOG_PAGES % 2 == 0
; Declared banks ascending (SAVENEX order), inside 1 MB, clear of the #SRAM probe page.
    ASSERT MBOX_BANK > 15 && MBOX_BANK < MIX_BANK && MIX_BANK < SAVE_BANK && SAVE_BANK < L2F_BANK
    ASSERT L2F_BANK + L2_BANKS <= L2B_BANK && L2B_BANK + L2_BANKS <= LOG_BANK
    ASSERT L2B_PHYS + L2_LEN <= PHYS_LIMIT && L2B_BANK + L2_BANKS <= $80
    ASSERT (LOG_BANK + LOG_BANKS) * 2 <= SRAM_PROBE_PAGE && SRAM_PROBE_PAGE * $2000 + PHYS_RAM <= PHYS_LIMIT

; MAP_<key> -> PI303V.MAP "<key>=<6 hex digits>" (build.ps1): the Pi's addresses.
MAP_mbox_phys          equ MBOX_PHYS
MAP_l2_front_phys      equ L2F_PHYS
MAP_l2_back_phys       equ L2B_PHYS
MAP_l2_front_bank      equ L2F_BANK
MAP_l2_back_bank       equ L2B_BANK
MAP_l2_len             equ L2_LEN
MAP_l2_fill            equ L2_FILL
MAP_mix_src_phys       equ PHYS_RAM + MIX_SRC_PAGE * $2000
MAP_mix_dst_phys       equ PHYS_RAM + MIX_DST_PAGE * $2000
MAP_mix_len            equ $2000
MAP_bank5_save_phys    equ PHYS_RAM + SAVE_PAGE * $2000
MAP_b5_off             equ B5_OFF
MAP_b5_len             equ B5_LEN
MAP_result_phys_region equ LOG_PHYS
MAP_result_len_max     equ LOG_LIMIT
MAP_prof_halt          equ PROF_HALT
MAP_prof_mix           equ PROF_MIX

    INCLUDE "../../bench/isrstubs.asm"
pi_frame_stub:                   ; vector IM2_V_ULA while fi_on's carve is in
    jp pi_frame_isr
    ASSERT high pi_frame_stub == IM2_VEC && high ($ - 1) == IM2_VEC

    SAVENEX OPEN "PI303V.NEX", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX BANK 2, MBOX_BANK, MIX_BANK, SAVE_BANK
NEX_B = L2F_BANK
    DUP L2_BANKS
    SAVENEX BANK NEX_B
NEX_B = NEX_B + 1
    EDUP
NEX_B = L2B_BANK
    DUP L2_BANKS
    SAVENEX BANK NEX_B
NEX_B = NEX_B + 1
    EDUP
NEX_B = LOG_BANK
    DUP LOG_BANKS
    SAVENEX BANK NEX_B
NEX_B = NEX_B + 1
    EDUP
    SAVENEX CLOSE
