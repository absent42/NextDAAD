; BENCH resident pad: the vector 13 trampoline and the batch loop. A workload may
; remap MMU6 and MMU7 (bench.asm header), so only the loop between the two clock
; reads and its shims run from here; the clock, setup and logging stay on BCH_PAGE.

; EXTERN vector 13 (overlay0 extVec): the nxb_trampoline idiom.
bench_trampoline:
    ld hl, bench_entry
    push hl
    ld a, BCH_PAGE
    jp ovl_map_page

; benchLeft x [MMU7 = BCH_PAGE, the restore, MMU7 = the row's page, the workload].
; bench_row (bench.asm) patches the three SMC operands and benchLeft first.
; Neither call takes register input. Out: MMU7 = BCH_PAGE. Corrupts all.
bench_batch:
    nextreg NR_MMU7, BCH_PAGE
.restore:
    call bench_none              ; SMC: the row's restore
.page:
    nextreg NR_MMU7, BCH_PAGE    ; SMC: the row's page
.body:
    call bench_none              ; SMC: the row's workload
    ld hl, (benchLeft)
    dec hl
    ld (benchLeft), hl
    ld a, h
    or l
    jr nz, bench_batch
    nextreg NR_MMU7, BCH_PAGE
; The empty restore and the calibration rows' empty workload.
bench_none:
    ret
    ASSERT {b bench_batch.page} == $ED && {b bench_batch.page + 2} == NR_MMU7
    ASSERT {b bench_batch.restore} == $CD && {b bench_batch.body} == $CD

; B2PL workload (MMU7 = OVL2_PAGE): gfx_load takes the picture number in A.
bench_pic_load:
    ld a, BCH_PIC
    jp gfx_load

; B2GT workload: eng_step (eng_run's loop body) until REDO puts the turn's record back
; on its first entry; gt_init patches the operands. gtFail = 1 if the stack drops below
; the record or BCH_GT_STEPS pass. Handlers remap MMU6/MMU7, so this stays resident.
bench_turn:
    ld b, BCH_GT_STEPS
.step:
    push bc
    call eng_step                ; corrupts all
    pop bc
    ld a, (procSP)
.base:
    cp 0                         ; SMC: the record's level + 1
    jr c, .fail
.rec:
    ld hl, (0)                   ; SMC: its condactPtr
    ld a, h
    or l
    jr nz, .next
.ent:
    ld hl, (0)                   ; SMC: its entryPtr
.start:
    ld de, 0                     ; SMC: the table's first entry
    sbc hl, de                   ; CF = 0 from the or
    ret z
.next:
    djnz .step
.fail:
    ld a, 1
    ld (gtFail), a
    ret
    ASSERT {b bench_turn.base} == $FE && {b bench_turn.start} == $11
    ASSERT {b bench_turn.rec} == $2A && {b bench_turn.ent} == $2A
    ASSERT BCH_GT_STEPS >= 1 && BCH_GT_STEPS <= 255

benchLeft:  dw 0
gtFail:     db 0
