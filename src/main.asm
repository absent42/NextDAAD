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
    call windows_init
    ld hl, prn_char_tok
    ld (prn_char_vec), hl
 IFDEF DEBUG
    call demo_or_suite
 ENDIF
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

 IFDEF DEBUG
; Runs the SP2 demo ONLY for the template DDB (numLocDsc == 3);
; anything else gets the engine. DRC's location count for the suite
; DSF drifts as sections grow (observed 1 then 2), so the template's
; known count is the stable discriminator. Scaffolding - Task 9
; deletes this router entirely.
demo_or_suite:
    ld a, (ddbHeader+HDR_NUMLOC)
    cp 3
    jr nz, .suite
    jp demo
.suite:
    call eng_init_game
    jp eng_run

; Exit-criteria demo: two coloured windows, every declared system
; message with More... paging, a location description, escape tests.
demo:
    ld a, 2
    call win_select
    ld b, 24
    ld c, 0
    ld d, 8
    ld e, TM_COLS               ; window 2: rows 24-31, full width
    call win_set_geom
    ld d, 1
    ld e, 6                     ; yellow ink on blue paper
    call win_set_colour
    call win_cls
    ld a, 2                     ; kind location
    ld e, 0
    call print_msg
    ld a, 1
    call win_select
    ld b, 0
    ld c, 0
    ld d, 24
    ld e, TM_COLS               ; window 1: rows 0-23, white on black
    call win_set_geom
    ld d, 0
    ld e, 7
    call win_set_colour
    call win_cls
    ld e, 0                     ; system message counter
.msgs:
    push de
    ld a, 0
    call print_msg
    call prn_newline
    pop de
    inc e
    ld a, (ddbHeader+6)         ; numSysMsg
    cp e
    jr nz, .msgs
    ld hl, demoString
    jp prn_encoded

demoString:
    db 255-'E', 255-'S', 255-'C', 255-':', 255-' ', 255-'L', 255-'1'
    db 255-$0D                  ; newline escape
    db 255-'E', 255-'X', 255-'T', 255-' '
    db 255-$10, 255-$11, 255-$12, 255-$13, 255-$14, 255-$15, 255-$16, 255-$17
    db 255-$18, 255-$19, 255-$1A, 255-$1B, 255-$1C, 255-$1D, 255-$1E, 255-$1F
    db 255-$0D
    db 255-'K', 255-'E', 255-'Y', 255-'?'
    db 255-$0C                  ; wait-key escape
    db 255-$0B                  ; clear-window escape
    db 255-'C', 255-'L', 255-'E', 255-'A', 255-'R', 255-'E', 255-'D'
    db 255-$0A                  ; terminator
 ENDIF

    INCLUDE "hardware.asm"
    INCLUDE "interrupts.asm"
    INCLUDE "banks.asm"
    INCLUDE "file.asm"
    INCLUDE "tilemap.asm"
    INCLUDE "windows.asm"
    INCLUDE "ddbtext.asm"
    INCLUDE "print.asm"
    INCLUDE "engine.asm"
    INCLUDE "errors.asm"
    INCLUDE "debug.asm"

    ASSERT $ <= RESIDENT_LIMIT

    INCLUDE "overlay0.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
