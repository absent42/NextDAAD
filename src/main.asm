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
    ; Temporary probe - replaced by the demo in the next task.
    ld hl, probe_putc
    ld (prn_char_vec), hl
    xor a
    call win_select
    call win_cls
    call bank_window_save
    ld a, 0                     ; kind system
    ld e, 32
    call msg_seek
    call nc, probe_msg
    call win_newline
    ld a, 0
    ld e, 0
    call msg_seek
    call nc, probe_msg
    call bank_window_restore
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

 IFDEF DEBUG
; Minimal decode loop: terminator, newline and tokens only.
probe_msg:
    call rd_next
    cpl                         ; decode = 255 - byte
    cp $0A
    ret z
    cp $0D
    jr z, .nl
    bit 7, a
    jr z, .plain
    and $7F
    call tok_print
    jr probe_msg
.nl:
    call win_newline
    jr probe_msg
.plain:
    ld c, a
    call probe_putc
    jr probe_msg

; C = char. The probe's prn_char_vec target.
probe_putc:
    ld a, c
    call win_putc
    call c, win_newline
    ret
 ENDIF

    INCLUDE "hardware.asm"
    INCLUDE "interrupts.asm"
    INCLUDE "banks.asm"
    INCLUDE "file.asm"
    INCLUDE "tilemap.asm"
    INCLUDE "windows.asm"
    INCLUDE "ddbtext.asm"
    INCLUDE "debug.asm"

    ASSERT $ <= RESIDENT_LIMIT

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
