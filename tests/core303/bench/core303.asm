; CORE303 standalone bench: raster-timed rows logged to CORE303.LOG.
; Build: tests\core303\bench\build.ps1 (bakes STAMP_STR), out build\core303\CORE303.NEX.
    DEVICE ZXSPECTRUMNEXT

    IFNDEF STAMP_STR
    ASSERT 0, "STAMP_STR missing: build with build.ps1"
    DEFINE STAMP_STR 'none'
    ENDIF

    INCLUDE "rowdefs.asm"
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

    INCLUDE "clock.asm"
    INCLUDE "log.asm"
    INCLUDE "probe.asm"
    INCLUDE "irq.asm"
    INCLUDE "dma.asm"
    INCLUDE "ops.asm"            ; dmainit_ routines: above rowTable (ROW's byte check)

; Run every ROW entry at HL (table ends with db 0). Per row: progress line, NR $07 =
; speed, init, clk_run (timed), 28 MHz, check, rt_restore, then the log line. DMA
; rows: init under irq_setup quiet + DI, irq_state before clk_run, irq_quiet after.
    INCLUDE "runner.asm"
rowTable:
    ROW "CAL0", 1, $FFFF, 0, 3, CPU, row_go, row_empty, 0
    ROW "CAL1", 1, $FFFF, 0, 2, CPU, row_go, row_empty, 0
    P1ROW "P1NP", NOP_N, NP_DOC, NP_COST, 3, p1np_init, SLED
    P1ROW "P1RD", RD_N, RD_DOC, RD_COST, 3, p1rd_init, SLED
    P1ROW "P1WR", WR_N, WR_DOC, WR_COST, 3, p1wr_init, SLED
    P1ROW "P1LI", LDI_N, LI_DOC, LI_COST, 3, p1li_init, SLED
    P1ROW "P1LR", LDIR_N, LR_DOC, LR_COST, 3, p1_map, p1lr_body
    P1ROW "P1OT", OTIR_N, OT_DOC, OT_COST, 3, p1ot_init, p1ot_body
    P1ROW "P1IN", IN_N, IN_DOC, IN_COST, 3, p1in_init, SLED
    P1ROW "P1PP", PP_N, PP_DOC, PP_COST, 3, p1pp_init, SLED
    P1ROW "P1JR", JR_N, JR_DOC, JR_COST, 3, p1jr_init, SLED
    P1ROW "P1X5", NOP_N, NP_DOC, NP_COST, 3, p1x5_init, X5_SLED
    P1ROW "P1R5", RD_N, RD_DOC, RD_COST, 3, p1r5_init, SLED
    P1ROW "P1R7", RD_N, RD_DOC, RD_COST, 3, p1r7_init, SLED
    P1ROW "P1C1", NOP_N, NP_DOC, NP_COST, 2, p1np_init, SLED
    P1ROW "P1C2", LDIR_N, LR_DOC, LR_COST, 2, p1_map, p1lr_body
    ROW "D0DT", 1, DT_REPS, DT_COST, 3, DMA|QS0|QI0|QC3, dmainit_dt, dt_body, dt_check
    ROW "D0CP", CP_LEN, CP_REPS, CP_COST, 3, DMA|QS0|QI0|QC2, dmainit_cp, dma_arm_go, d0cp_check
; Part 1b (ops.asm): CPU quiet; zxnDMA at 2/2 and the blitter at 3/3 and 2/2, quiet,
; and for R, F and V also in states 1 and 2 at both ISR lengths.
    ROW "DRC0", RC0_N, RC0_R, RC0_C, 3, CPU, dmainit_rc, lw_ldir, ck_rect
    ROW "DRC1", RC1_N, RC1_R, RC1_C, 3, CPU, dmainit_rc, lw_ldir, ck_rect
    ROW "DRC2", RC2_N, RC2_R, RC2_C, 3, CPU, dmainit_rc, lw_ldir, ck_rect
    ROW "DRC3", RC3_N, RC3_R, RC3_C, 3, CPU, dmainit_rc, lw_ldir, ck_rect
    ROW "DRC4", RC4_N, RC4_R, RC4_C, 3, CPU, dmainit_rc, lw_ldir, ck_rect
    ROW "DRZ0", RZ0_N, RZ0_R, RZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ1", RZ1_N, RZ1_R, RZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ2", RZ2_N, RZ2_R, RZ2_C, 3, DMA|QS0|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ3", RZ3_N, RZ3_R, RZ3_C, 3, DMA|QS0|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ4", RZ4_N, RZ4_R, RZ4_C, 3, DMA|QS0|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRB0", RB03_N, RB03_R, RB03_C, 3, DMA|QS0|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB02_N, RB02_R, RB02_C, 3, DMA|QS0|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB13_N, RB13_R, RB13_C, 3, DMA|QS0|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB12_N, RB12_R, RB12_C, 3, DMA|QS0|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB23_N, RB23_R, RB23_C, 3, DMA|QS0|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB22_N, RB22_R, RB22_C, 3, DMA|QS0|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB33_N, RB33_R, RB33_C, 3, DMA|QS0|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB32_N, RB32_R, RB32_C, 3, DMA|QS0|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB43_N, RB43_R, RB43_C, 3, DMA|QS0|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB42_N, RB42_R, RB42_C, 3, DMA|QS0|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB02_N, RB02_R, RB02_C, 3, DMA|QS1|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB02_N, RB02_R, RB02_C, 3, DMA|QS1|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB02_N, RB02_R, RB02_C, 3, DMA|QS2|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB02_N, RB02_R, RB02_C, 3, DMA|QS2|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB12_N, RB12_R, RB12_C, 3, DMA|QS1|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB12_N, RB12_R, RB12_C, 3, DMA|QS1|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB12_N, RB12_R, RB12_C, 3, DMA|QS2|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB12_N, RB12_R, RB12_C, 3, DMA|QS2|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB22_N, RB22_R, RB22_C, 3, DMA|QS1|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB22_N, RB22_R, RB22_C, 3, DMA|QS1|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB22_N, RB22_R, RB22_C, 3, DMA|QS2|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB22_N, RB22_R, RB22_C, 3, DMA|QS2|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB32_N, RB32_R, RB32_C, 3, DMA|QS1|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB32_N, RB32_R, RB32_C, 3, DMA|QS1|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB32_N, RB32_R, RB32_C, 3, DMA|QS2|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB32_N, RB32_R, RB32_C, 3, DMA|QS2|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB42_N, RB42_R, RB42_C, 3, DMA|QS1|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB42_N, RB42_R, RB42_C, 3, DMA|QS1|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB42_N, RB42_R, RB42_C, 3, DMA|QS2|QI0|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB42_N, RB42_R, RB42_C, 3, DMA|QS2|QI1|QC2, dmainit_rb, blt_go7, ck_rect
    ROW "DRZ0", RZ0_N, RZ0_R, RZ0_C, 3, DMA|QS1|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ0", RZ0_N, RZ0_R, RZ0_C, 3, DMA|QS1|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ0", RZ0_N, RZ0_R, RZ0_C, 3, DMA|QS2|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ0", RZ0_N, RZ0_R, RZ0_C, 3, DMA|QS2|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ1", RZ1_N, RZ1_R, RZ1_C, 3, DMA|QS1|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ1", RZ1_N, RZ1_R, RZ1_C, 3, DMA|QS1|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ1", RZ1_N, RZ1_R, RZ1_C, 3, DMA|QS2|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ1", RZ1_N, RZ1_R, RZ1_C, 3, DMA|QS2|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ2", RZ2_N, RZ2_R, RZ2_C, 3, DMA|QS1|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ2", RZ2_N, RZ2_R, RZ2_C, 3, DMA|QS1|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ2", RZ2_N, RZ2_R, RZ2_C, 3, DMA|QS2|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ2", RZ2_N, RZ2_R, RZ2_C, 3, DMA|QS2|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ3", RZ3_N, RZ3_R, RZ3_C, 3, DMA|QS1|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ3", RZ3_N, RZ3_R, RZ3_C, 3, DMA|QS1|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ3", RZ3_N, RZ3_R, RZ3_C, 3, DMA|QS2|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ3", RZ3_N, RZ3_R, RZ3_C, 3, DMA|QS2|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ4", RZ4_N, RZ4_R, RZ4_C, 3, DMA|QS1|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ4", RZ4_N, RZ4_R, RZ4_C, 3, DMA|QS1|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ4", RZ4_N, RZ4_R, RZ4_C, 3, DMA|QS2|QI0|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRZ4", RZ4_N, RZ4_R, RZ4_C, 3, DMA|QS2|QI1|QC2, dmainit_rz, lw_dma, ck_rect
    ROW "DRB0", RB03_N, RB03_R, RB03_C, 3, DMA|QS1|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB03_N, RB03_R, RB03_C, 3, DMA|QS1|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB03_N, RB03_R, RB03_C, 3, DMA|QS2|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB0", RB03_N, RB03_R, RB03_C, 3, DMA|QS2|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB13_N, RB13_R, RB13_C, 3, DMA|QS1|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB13_N, RB13_R, RB13_C, 3, DMA|QS1|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB13_N, RB13_R, RB13_C, 3, DMA|QS2|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB1", RB13_N, RB13_R, RB13_C, 3, DMA|QS2|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB23_N, RB23_R, RB23_C, 3, DMA|QS1|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB23_N, RB23_R, RB23_C, 3, DMA|QS1|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB23_N, RB23_R, RB23_C, 3, DMA|QS2|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB2", RB23_N, RB23_R, RB23_C, 3, DMA|QS2|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB33_N, RB33_R, RB33_C, 3, DMA|QS1|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB33_N, RB33_R, RB33_C, 3, DMA|QS1|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB33_N, RB33_R, RB33_C, 3, DMA|QS2|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB3", RB33_N, RB33_R, RB33_C, 3, DMA|QS2|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB43_N, RB43_R, RB43_C, 3, DMA|QS1|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB43_N, RB43_R, RB43_C, 3, DMA|QS1|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB43_N, RB43_R, RB43_C, 3, DMA|QS2|QI0|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DRB4", RB43_N, RB43_R, RB43_C, 3, DMA|QS2|QI1|QC3, dmainit_rb, blt_go7, ck_rect
    ROW "DTC0", TC0_N, TC0_R, TC0_C, 3, CPU, dmainit_tc, lw_ldirx, ck_rect
    ROW "DTC1", TC1_N, TC1_R, TC1_C, 3, CPU, dmainit_tc, lw_ldirx, ck_rect
    ROW "DTC2", TC2_N, TC2_R, TC2_C, 3, CPU, dmainit_tc, lw_ldirx, ck_rect
    ROW "DTC3", TC3_N, TC3_R, TC3_C, 3, CPU, dmainit_tc, lw_ldirx, ck_rect
    ROW "DTC4", TC4_N, TC4_R, TC4_C, 3, CPU, dmainit_tc, lw_ldirx, ck_rect
    ROW "DTB0", TB03_N, TB03_R, TB03_C, 3, DMA|QS0|QI0|QC3, dmainit_tb, blt_go7, ck_rect
    ROW "DTB0", TB02_N, TB02_R, TB02_C, 3, DMA|QS0|QI0|QC2, dmainit_tb, blt_go7, ck_rect
    ROW "DTB1", TB13_N, TB13_R, TB13_C, 3, DMA|QS0|QI0|QC3, dmainit_tb, blt_go7, ck_rect
    ROW "DTB1", TB12_N, TB12_R, TB12_C, 3, DMA|QS0|QI0|QC2, dmainit_tb, blt_go7, ck_rect
    ROW "DTB2", TB23_N, TB23_R, TB23_C, 3, DMA|QS0|QI0|QC3, dmainit_tb, blt_go7, ck_rect
    ROW "DTB2", TB22_N, TB22_R, TB22_C, 3, DMA|QS0|QI0|QC2, dmainit_tb, blt_go7, ck_rect
    ROW "DTB3", TB33_N, TB33_R, TB33_C, 3, DMA|QS0|QI0|QC3, dmainit_tb, blt_go7, ck_rect
    ROW "DTB3", TB32_N, TB32_R, TB32_C, 3, DMA|QS0|QI0|QC2, dmainit_tb, blt_go7, ck_rect
    ROW "DTB4", TB43_N, TB43_R, TB43_C, 3, DMA|QS0|QI0|QC3, dmainit_tb, blt_go7, ck_rect
    ROW "DTB4", TB42_N, TB42_R, TB42_C, 3, DMA|QS0|QI0|QC2, dmainit_tb, blt_go7, ck_rect
    ROW "DCC0", CC0_N, CC0_R, CC0_C, 3, CPU, dmainit_cc, cc_body, ck_rect
    ROW "DCC1", CC1_N, CC1_R, CC1_C, 3, CPU, dmainit_cc, cc_body, ck_rect
    ROW "DCC2", CC2_N, CC2_R, CC2_C, 3, CPU, dmainit_cc, cc_body, ck_rect
    ROW "DCC3", CC3_N, CC3_R, CC3_C, 3, CPU, dmainit_cc, cc_body, ck_rect
    ROW "DCB0", CB03_N, CB03_R, CB03_C, 3, DMA|QS0|QI0|QC3, dmainit_cb, cb_body, ck_rect
    ROW "DCB0", CB02_N, CB02_R, CB02_C, 3, DMA|QS0|QI0|QC2, dmainit_cb, cb_body, ck_rect
    ROW "DCB1", CB13_N, CB13_R, CB13_C, 3, DMA|QS0|QI0|QC3, dmainit_cb, cb_body, ck_rect
    ROW "DCB1", CB12_N, CB12_R, CB12_C, 3, DMA|QS0|QI0|QC2, dmainit_cb, cb_body, ck_rect
    ROW "DCB2", CB23_N, CB23_R, CB23_C, 3, DMA|QS0|QI0|QC3, dmainit_cb, cb_body, ck_rect
    ROW "DCB2", CB22_N, CB22_R, CB22_C, 3, DMA|QS0|QI0|QC2, dmainit_cb, cb_body, ck_rect
    ROW "DCB3", CB33_N, CB33_R, CB33_C, 3, DMA|QS0|QI0|QC3, dmainit_cb, cb_body, ck_rect
    ROW "DCB3", CB32_N, CB32_R, CB32_C, 3, DMA|QS0|QI0|QC2, dmainit_cb, cb_body, ck_rect
    ROW "DKC0", KC0_N, KC0_R, KC0_C, 3, CPU, dmainit_kc, lw_ldir, ck_rect
    ROW "DKC1", KC1_N, KC1_R, KC1_C, 3, CPU, dmainit_kc, lw_ldir, ck_rect
    ROW "DKC2", KC2_N, KC2_R, KC2_C, 3, CPU, dmainit_kc, lw_ldir, ck_rect
    ROW "DKC3", KC3_N, KC3_R, KC3_C, 3, CPU, dmainit_kc, lw_ldir, ck_rect
    ROW "DKZ0", KZ0_N, KZ0_R, KZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_kz, lw_dma, ck_rect
    ROW "DKZ1", KZ1_N, KZ1_R, KZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_kz, lw_dma, ck_rect
    ROW "DKZ2", KZ2_N, KZ2_R, KZ2_C, 3, DMA|QS0|QI0|QC2, dmainit_kz, lw_dma, ck_rect
    ROW "DKZ3", KZ3_N, KZ3_R, KZ3_C, 3, DMA|QS0|QI0|QC2, dmainit_kz, lw_dma, ck_rect
    ROW "DKB0", KB03_N, KB03_R, KB03_C, 3, DMA|QS0|QI0|QC3, dmainit_kb, blt_go7, ck_rect
    ROW "DKB0", KB02_N, KB02_R, KB02_C, 3, DMA|QS0|QI0|QC2, dmainit_kb, blt_go7, ck_rect
    ROW "DKB1", KB13_N, KB13_R, KB13_C, 3, DMA|QS0|QI0|QC3, dmainit_kb, blt_go7, ck_rect
    ROW "DKB1", KB12_N, KB12_R, KB12_C, 3, DMA|QS0|QI0|QC2, dmainit_kb, blt_go7, ck_rect
    ROW "DKB2", KB23_N, KB23_R, KB23_C, 3, DMA|QS0|QI0|QC3, dmainit_kb, blt_go7, ck_rect
    ROW "DKB2", KB22_N, KB22_R, KB22_C, 3, DMA|QS0|QI0|QC2, dmainit_kb, blt_go7, ck_rect
    ROW "DKB3", KB33_N, KB33_R, KB33_C, 3, DMA|QS0|QI0|QC3, dmainit_kb, kb_half, ck_rect
    ROW "DKB3", KB32_N, KB32_R, KB32_C, 3, DMA|QS0|QI0|QC2, dmainit_kb, kb_half, ck_rect
    ROW "DFC0", FC0_N, FC0_R, FC0_C, 3, CPU, dmainit_fc, fc_body, ck_fill
    ROW "DFC1", FC1_N, FC1_R, FC1_C, 3, CPU, dmainit_fc, fc_body, ck_fill
    ROW "DFC2", FC2_N, FC2_R, FC2_C, 3, CPU, dmainit_fc, fc_body, ck_fill
    ROW "DFC3", FC3_N, FC3_R, FC3_C, 3, CPU, dmainit_fc, fc_body, ck_fill
    ROW "DFC4", FC4_N, FC4_R, FC4_C, 3, CPU, dmainit_fc, fc_body, ck_fill
    ROW "DFZ0", FZ0_N, FZ0_R, FZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ1", FZ1_N, FZ1_R, FZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ2", FZ2_N, FZ2_R, FZ2_C, 3, DMA|QS0|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ3", FZ3_N, FZ3_R, FZ3_C, 3, DMA|QS0|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ4", FZ4_N, FZ4_R, FZ4_C, 3, DMA|QS0|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFB0", FB03_N, FB03_R, FB03_C, 3, DMA|QS0|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB02_N, FB02_R, FB02_C, 3, DMA|QS0|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB13_N, FB13_R, FB13_C, 3, DMA|QS0|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB12_N, FB12_R, FB12_C, 3, DMA|QS0|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB23_N, FB23_R, FB23_C, 3, DMA|QS0|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB22_N, FB22_R, FB22_C, 3, DMA|QS0|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB33_N, FB33_R, FB33_C, 3, DMA|QS0|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB32_N, FB32_R, FB32_C, 3, DMA|QS0|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB43_N, FB43_R, FB43_C, 3, DMA|QS0|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB42_N, FB42_R, FB42_C, 3, DMA|QS0|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB02_N, FB02_R, FB02_C, 3, DMA|QS1|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB02_N, FB02_R, FB02_C, 3, DMA|QS1|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB02_N, FB02_R, FB02_C, 3, DMA|QS2|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB02_N, FB02_R, FB02_C, 3, DMA|QS2|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB12_N, FB12_R, FB12_C, 3, DMA|QS1|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB12_N, FB12_R, FB12_C, 3, DMA|QS1|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB12_N, FB12_R, FB12_C, 3, DMA|QS2|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB12_N, FB12_R, FB12_C, 3, DMA|QS2|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB22_N, FB22_R, FB22_C, 3, DMA|QS1|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB22_N, FB22_R, FB22_C, 3, DMA|QS1|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB22_N, FB22_R, FB22_C, 3, DMA|QS2|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB22_N, FB22_R, FB22_C, 3, DMA|QS2|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB32_N, FB32_R, FB32_C, 3, DMA|QS1|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB32_N, FB32_R, FB32_C, 3, DMA|QS1|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB32_N, FB32_R, FB32_C, 3, DMA|QS2|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB32_N, FB32_R, FB32_C, 3, DMA|QS2|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB42_N, FB42_R, FB42_C, 3, DMA|QS1|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB42_N, FB42_R, FB42_C, 3, DMA|QS1|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB42_N, FB42_R, FB42_C, 3, DMA|QS2|QI0|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB42_N, FB42_R, FB42_C, 3, DMA|QS2|QI1|QC2, dmainit_fb, blt_go10, ck_fill
    ROW "DFZ0", FZ0_N, FZ0_R, FZ0_C, 3, DMA|QS1|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ0", FZ0_N, FZ0_R, FZ0_C, 3, DMA|QS1|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ0", FZ0_N, FZ0_R, FZ0_C, 3, DMA|QS2|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ0", FZ0_N, FZ0_R, FZ0_C, 3, DMA|QS2|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ1", FZ1_N, FZ1_R, FZ1_C, 3, DMA|QS1|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ1", FZ1_N, FZ1_R, FZ1_C, 3, DMA|QS1|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ1", FZ1_N, FZ1_R, FZ1_C, 3, DMA|QS2|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ1", FZ1_N, FZ1_R, FZ1_C, 3, DMA|QS2|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ2", FZ2_N, FZ2_R, FZ2_C, 3, DMA|QS1|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ2", FZ2_N, FZ2_R, FZ2_C, 3, DMA|QS1|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ2", FZ2_N, FZ2_R, FZ2_C, 3, DMA|QS2|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ2", FZ2_N, FZ2_R, FZ2_C, 3, DMA|QS2|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ3", FZ3_N, FZ3_R, FZ3_C, 3, DMA|QS1|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ3", FZ3_N, FZ3_R, FZ3_C, 3, DMA|QS1|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ3", FZ3_N, FZ3_R, FZ3_C, 3, DMA|QS2|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ3", FZ3_N, FZ3_R, FZ3_C, 3, DMA|QS2|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ4", FZ4_N, FZ4_R, FZ4_C, 3, DMA|QS1|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ4", FZ4_N, FZ4_R, FZ4_C, 3, DMA|QS1|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ4", FZ4_N, FZ4_R, FZ4_C, 3, DMA|QS2|QI0|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFZ4", FZ4_N, FZ4_R, FZ4_C, 3, DMA|QS2|QI1|QC2, dmainit_fz, fz_body, ck_fill
    ROW "DFB0", FB03_N, FB03_R, FB03_C, 3, DMA|QS1|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB03_N, FB03_R, FB03_C, 3, DMA|QS1|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB03_N, FB03_R, FB03_C, 3, DMA|QS2|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB0", FB03_N, FB03_R, FB03_C, 3, DMA|QS2|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB13_N, FB13_R, FB13_C, 3, DMA|QS1|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB13_N, FB13_R, FB13_C, 3, DMA|QS1|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB13_N, FB13_R, FB13_C, 3, DMA|QS2|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB1", FB13_N, FB13_R, FB13_C, 3, DMA|QS2|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB23_N, FB23_R, FB23_C, 3, DMA|QS1|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB23_N, FB23_R, FB23_C, 3, DMA|QS1|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB23_N, FB23_R, FB23_C, 3, DMA|QS2|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB2", FB23_N, FB23_R, FB23_C, 3, DMA|QS2|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB33_N, FB33_R, FB33_C, 3, DMA|QS1|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB33_N, FB33_R, FB33_C, 3, DMA|QS1|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB33_N, FB33_R, FB33_C, 3, DMA|QS2|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB3", FB33_N, FB33_R, FB33_C, 3, DMA|QS2|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB43_N, FB43_R, FB43_C, 3, DMA|QS1|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB43_N, FB43_R, FB43_C, 3, DMA|QS1|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB43_N, FB43_R, FB43_C, 3, DMA|QS2|QI0|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DFB4", FB43_N, FB43_R, FB43_C, 3, DMA|QS2|QI1|QC3, dmainit_fb, blt_go10, ck_fill
    ROW "DSC0", SC0_N, SC0_R, SC0_C, 3, CPU, dmainit_sc, sc_body, 0
    ROW "DSC1", SC1_N, SC1_R, SC1_C, 3, CPU, dmainit_sc, sc_body, 0
    ROW "DSZ0", SZ0_N, SZ0_R, SZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_sz, sz_body, ck_scroll
    ROW "DSZ1", SZ1_N, SZ1_R, SZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_sz, sz_body, ck_scroll
    ROW "DSB0", SB03_N, SB03_R, SB03_C, 3, DMA|QS0|QI0|QC3, dmainit_sb, blt_go8, ck_scroll
    ROW "DSB0", SB02_N, SB02_R, SB02_C, 3, DMA|QS0|QI0|QC2, dmainit_sb, blt_go8, ck_scroll
    ROW "DSB1", SB13_N, SB13_R, SB13_C, 3, DMA|QS0|QI0|QC3, dmainit_sb, blt_go8, ck_scroll
    ROW "DSB1", SB12_N, SB12_R, SB12_C, 3, DMA|QS0|QI0|QC2, dmainit_sb, blt_go8, ck_scroll
    ROW "DVC0", VC0_N, VC0_R, VC0_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC1", VC1_N, VC1_R, VC1_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC2", VC2_N, VC2_R, VC2_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC3", VC3_N, VC3_R, VC3_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC4", VC4_N, VC4_R, VC4_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC5", VC5_N, VC5_R, VC5_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC6", VC6_N, VC6_R, VC6_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVC7", VC7_N, VC7_R, VC7_C, 3, CPU, dmainit_vc, vc_body, ck_vid
    ROW "DVZ0", VZ0_N, VZ0_R, VZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ1", VZ1_N, VZ1_R, VZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ2", VZ2_N, VZ2_R, VZ2_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ3", VZ3_N, VZ3_R, VZ3_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ4", VZ4_N, VZ4_R, VZ4_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ5", VZ5_N, VZ5_R, VZ5_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ6", VZ6_N, VZ6_R, VZ6_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ7", VZ7_N, VZ7_R, VZ7_C, 3, DMA|QS0|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVB0", VB03_N, VB03_R, VB03_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB02_N, VB02_R, VB02_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB13_N, VB13_R, VB13_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB12_N, VB12_R, VB12_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB23_N, VB23_R, VB23_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB22_N, VB22_R, VB22_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB33_N, VB33_R, VB33_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB32_N, VB32_R, VB32_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB43_N, VB43_R, VB43_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB42_N, VB42_R, VB42_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB53_N, VB53_R, VB53_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB52_N, VB52_R, VB52_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB63_N, VB63_R, VB63_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB62_N, VB62_R, VB62_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB73_N, VB73_R, VB73_C, 3, DMA|QS0|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB72_N, VB72_R, VB72_C, 3, DMA|QS0|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB02_N, VB02_R, VB02_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB02_N, VB02_R, VB02_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB02_N, VB02_R, VB02_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB02_N, VB02_R, VB02_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB12_N, VB12_R, VB12_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB12_N, VB12_R, VB12_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB12_N, VB12_R, VB12_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB12_N, VB12_R, VB12_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB22_N, VB22_R, VB22_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB22_N, VB22_R, VB22_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB22_N, VB22_R, VB22_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB22_N, VB22_R, VB22_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB32_N, VB32_R, VB32_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB32_N, VB32_R, VB32_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB32_N, VB32_R, VB32_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB32_N, VB32_R, VB32_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB42_N, VB42_R, VB42_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB42_N, VB42_R, VB42_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB42_N, VB42_R, VB42_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB42_N, VB42_R, VB42_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB52_N, VB52_R, VB52_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB52_N, VB52_R, VB52_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB52_N, VB52_R, VB52_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB52_N, VB52_R, VB52_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB62_N, VB62_R, VB62_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB62_N, VB62_R, VB62_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB62_N, VB62_R, VB62_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB62_N, VB62_R, VB62_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB72_N, VB72_R, VB72_C, 3, DMA|QS1|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB72_N, VB72_R, VB72_C, 3, DMA|QS1|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB72_N, VB72_R, VB72_C, 3, DMA|QS2|QI0|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB72_N, VB72_R, VB72_C, 3, DMA|QS2|QI1|QC2, dmainit_vb, blt_go10, ck_vid
    ROW "DVZ0", VZ0_N, VZ0_R, VZ0_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ0", VZ0_N, VZ0_R, VZ0_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ0", VZ0_N, VZ0_R, VZ0_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ0", VZ0_N, VZ0_R, VZ0_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ1", VZ1_N, VZ1_R, VZ1_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ1", VZ1_N, VZ1_R, VZ1_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ1", VZ1_N, VZ1_R, VZ1_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ1", VZ1_N, VZ1_R, VZ1_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ2", VZ2_N, VZ2_R, VZ2_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ2", VZ2_N, VZ2_R, VZ2_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ2", VZ2_N, VZ2_R, VZ2_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ2", VZ2_N, VZ2_R, VZ2_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ3", VZ3_N, VZ3_R, VZ3_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ3", VZ3_N, VZ3_R, VZ3_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ3", VZ3_N, VZ3_R, VZ3_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ3", VZ3_N, VZ3_R, VZ3_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ4", VZ4_N, VZ4_R, VZ4_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ4", VZ4_N, VZ4_R, VZ4_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ4", VZ4_N, VZ4_R, VZ4_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ4", VZ4_N, VZ4_R, VZ4_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ5", VZ5_N, VZ5_R, VZ5_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ5", VZ5_N, VZ5_R, VZ5_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ5", VZ5_N, VZ5_R, VZ5_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ5", VZ5_N, VZ5_R, VZ5_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ6", VZ6_N, VZ6_R, VZ6_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ6", VZ6_N, VZ6_R, VZ6_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ6", VZ6_N, VZ6_R, VZ6_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ6", VZ6_N, VZ6_R, VZ6_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ7", VZ7_N, VZ7_R, VZ7_C, 3, DMA|QS1|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ7", VZ7_N, VZ7_R, VZ7_C, 3, DMA|QS1|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ7", VZ7_N, VZ7_R, VZ7_C, 3, DMA|QS2|QI0|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVZ7", VZ7_N, VZ7_R, VZ7_C, 3, DMA|QS2|QI1|QC2, dmainit_vz, vz_body, ck_vid
    ROW "DVB0", VB03_N, VB03_R, VB03_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB03_N, VB03_R, VB03_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB03_N, VB03_R, VB03_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB0", VB03_N, VB03_R, VB03_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB13_N, VB13_R, VB13_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB13_N, VB13_R, VB13_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB13_N, VB13_R, VB13_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB1", VB13_N, VB13_R, VB13_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB23_N, VB23_R, VB23_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB23_N, VB23_R, VB23_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB23_N, VB23_R, VB23_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB2", VB23_N, VB23_R, VB23_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB33_N, VB33_R, VB33_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB33_N, VB33_R, VB33_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB33_N, VB33_R, VB33_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB3", VB33_N, VB33_R, VB33_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB43_N, VB43_R, VB43_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB43_N, VB43_R, VB43_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB43_N, VB43_R, VB43_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB4", VB43_N, VB43_R, VB43_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB53_N, VB53_R, VB53_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB53_N, VB53_R, VB53_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB53_N, VB53_R, VB53_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB5", VB53_N, VB53_R, VB53_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB63_N, VB63_R, VB63_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB63_N, VB63_R, VB63_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB63_N, VB63_R, VB63_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB6", VB63_N, VB63_R, VB63_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB73_N, VB73_R, VB73_C, 3, DMA|QS1|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB73_N, VB73_R, VB73_C, 3, DMA|QS1|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB73_N, VB73_R, VB73_C, 3, DMA|QS2|QI0|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DVB7", VB73_N, VB73_R, VB73_C, 3, DMA|QS2|QI1|QC3, dmainit_vb, blt_go10, ck_vid
    ROW "DUZ0", UZ0_N, UZ0_R, UZ0_C, 3, DMA|QS0|QI0|QC2, dmainit_uz, uz0_body, ck_vid
    ROW "DUZ1", UZ1_N, UZ1_R, UZ1_C, 3, DMA|QS0|QI0|QC2, dmainit_uz, dma_arm_go, ck_vid
    ROW "DUB0", UB03_N, UB03_R, UB03_C, 3, DMA|QS0|QI0|QC3, dmainit_ub, blt_go22, ck_vid
    ROW "DUB0", UB02_N, UB02_R, UB02_C, 3, DMA|QS0|QI0|QC2, dmainit_ub, blt_go22, ck_vid
    ROW "DUB1", UB13_N, UB13_R, UB13_C, 3, DMA|QS0|QI0|QC3, dmainit_ub, blt_go8, ck_vid
    ROW "DUB1", UB12_N, UB12_R, UB12_C, 3, DMA|QS0|QI0|QC2, dmainit_ub, blt_go8, ck_vid
    db 0

    INCLUDE "runner_data.asm"

    ASSERT $ <= CODE_LIMIT
    ASSERT LOG_HDR_MAX + ROW_TOTAL * LOG_ROW_MAX + LOG_END_MAX <= LOG_CAP
    ASSERT LOG_PAGE > OPS_LAST_PAGE      ; log pages clear of every row buffer

    INCLUDE "isrstubs.asm"

    SAVENEX OPEN "CORE303.NEX", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
