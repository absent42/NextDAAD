; NextDAAD - DAAD interpreter for the ZX Spectrum Next
; Foundation: boot, memory, DDB loading. See docs/superpowers/specs.

    DEVICE ZXSPECTRUMNEXT
    INCLUDE "nextdaad.inc"

    ORG CODE_ORG
main:
    di
    ld sp, STACK_TOP
    call hw_init
    call im2_init
    call dbg_cls
    call boot_banner
    call ram_detect
    call bank_table_init
    call ram_diag
    call bank_selftest
    call ddb_load
    or a
    jr z, .loaded
    dec a
    jr z, .missing
    dec a
    jr z, .oversize
    ld a, ERR_BORDER_BADHDR
    ld hl, msgBadHdr
    jp fatal
.missing:
    ld a, ERR_BORDER_MISSING
    ld hl, msgMissing
    jp fatal
.oversize:
    ld a, ERR_BORDER_OVERSIZE
    ld hl, msgOversize
    jp fatal
.loaded:
    call ddb_diag
    call txt_init
    call dbg_engage_tilemap
    call sdg_load
    call windows_init
    ld hl, objname_print
    ld (objname_hook), hl
    ld c, 0
    call eng_init_game
    call eng_run
    ; eng_run never returns (eng_step re-pushes PRO 0 on an empty stack);
    ; this loop is a dead safety net and the DEBUG FRAMES display.
idle:
 IFDEF DEBUG
    ld b, 31
    ld c, 60
    call dbg_at
    ld hl, msgFrames
    call dbg_puts
    ld hl, (frameCounter)
    call dbg_hex16
 ENDIF
    jr idle

    INCLUDE "hardware.asm"
    INCLUDE "interrupts.asm"
    INCLUDE "banks.asm"
    INCLUDE "file.asm"
    INCLUDE "tilemap.asm"
    INCLUDE "windows.asm"
    INCLUDE "ddbtext.asm"
    INCLUDE "print.asm"
    INCLUDE "input.asm"
    INCLUDE "engine.asm"
    INCLUDE "errors.asm"
    INCLUDE "objname.asm"
    INCLUDE "debug.asm"

    ASSERT $ <= RESIDENT_LIMIT

    INCLUDE "overlay0.asm"
    INCLUDE "overlay1.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
