; BLT303 standalone bench: the blit transfers of src/overlay2.asm, raster-timed per
; span length and logged to BLT303.LOG. Framework and helpers: tests/core303/bench.
; Build: tests\core303\blit\build.ps1 (bakes STAMP_STR), out build\blt303\BLT303.NEX.
    DEVICE ZXSPECTRUMNEXT

    IFNDEF STAMP_STR
    ASSERT 0, "STAMP_STR missing: build with build.ps1"
    DEFINE STAMP_STR 'none'
    ENDIF
    DEFINE LOG_NAME_STR "BLT303.LOG"

    INCLUDE "../bench/rowdefs.asm"
AUD_RATE_MAX     equ 20000       ; src/nextdaad.inc: ddma.inc pins CTC_PERIOD_MIN to it
    INCLUDE "../../../src/ddma.inc"
    ORG $8000
main:
    di
    ld sp, STACK_TOP
    nextreg NR_SPEED, SPEED_28
    call mmu_canon
    call im2_init
    call irq_init
    call bp_patch
    call nr64_zero
    call ula_cls
    call hdr_read
    call log_header
    call ops_save
    ld hl, rowTable
    call run_table
    call ops_restore             ; NR $12/$13/$70 back before any file I/O
    call log_flush
    call nr64_restore
    ld bc, DONE_TXT_ROW << 8
    call ula_at
    ld hl, txtDone
    call ula_puts
    di
    halt

    INCLUDE "../bench/clock.asm"
    INCLUDE "../bench/log.asm"
    INCLUDE "../bench/probe.asm"
    INCLUDE "../bench/irq.asm"
    INCLUDE "../bench/dma.asm"
    INCLUDE "../bench/ops.asm"
    INCLUDE "blitops.asm"        ; dmainit_ routines: above rowTable (ROW's byte check)
    INCLUDE "../bench/runner.asm"
rowTable:
    INCLUDE "rows.asm"

    INCLUDE "../bench/runner_data.asm"

    ASSERT $ <= CODE_LIMIT
    ASSERT LOG_HDR_MAX + ROW_TOTAL * LOG_ROW_MAX + LOG_END_MAX <= LOG_CAP
    ASSERT LOG_PAGE > OPS_LAST_PAGE      ; log pages clear of every row buffer

    INCLUDE "../bench/isrstubs.asm"

    SAVENEX OPEN "BLT303.NEX", main, STACK_TOP
    SAVENEX CORE 3, 3, 3
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
