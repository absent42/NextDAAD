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
 IFDEF DEBUG
    ; Temporary probe - replaced by the window probe in the next task
    ld b, 2
    ld c, 4
    ld a, 'A'
    ld e, 7*2                   ; pair 7: white on black
    call tm_putc_at
    ld c, 6
    ld a, 'B'
    ld e, (6*8+2)*2             ; pair 50: red ink on yellow paper
    call tm_putc_at
    ld c, 8
    ld a, 'C'
    ld e, (1*8+6)*2             ; pair 14: yellow ink on blue paper
    call tm_putc_at
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
    INCLUDE "debug.asm"

    ASSERT $ <= RESIDENT_LIMIT

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
