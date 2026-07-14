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
    call windows_init
 IFDEF DEBUG
    ; Temporary probe - replaced by the message probe in the next task
    ld a, 1
    call win_select
    ld b, 1
    ld c, 2
    ld d, 5
    ld e, 20                    ; window 1: 20 wide, 5 high at (2,1)
    call win_set_geom
    ld d, 1
    ld e, 6                     ; yellow ink on blue paper
    call win_set_colour
    call win_cls
    ld b, 30
.probe1:
    push bc
    ld a, 'X'
    call win_putc
    call c, win_newline         ; honour the wrap signal
    pop bc
    djnz .probe1
    call win_newline
    ld a, 'Y'
    call win_putc
    ld a, 2
    call win_select
    ld b, 10
    ld c, 40
    ld d, 4
    ld e, 12                    ; window 2: 12 wide, 4 high at (40,10)
    call win_set_geom
    ld d, 4
    ld e, 0                     ; black ink on green paper
    call win_set_colour
    call win_cls
    ld b, 8
.probe2:
    push bc
    ld a, 'Z'
    call win_putc
    call win_newline
    pop bc
    djnz .probe2
 ENDIF
idle:
 IFDEF DEBUG
    ld b, 3
    ld c, 0
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
    INCLUDE "debug.asm"

    ASSERT $ <= RESIDENT_LIMIT

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
