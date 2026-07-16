; NextDAAD - DAAD interpreter for the ZX Spectrum Next
; Foundation: boot, memory, DDB loading. See docs/superpowers/specs.

    DEVICE ZXSPECTRUMNEXT
    INCLUDE "nextdaad.inc"

    ORG CODE_ORG
main:
    di
    ld sp, STACK_TOP
 IFDEF DEBUG
    call l2_bareprobe_hook       ; Layer 2 bare-metal isolation ladder
                                  ; (Task 2, round 8); no-op unless P
                                  ; is held - checked before ANY other
                                  ; init, never returns if entered
 ENDIF
    call boot_data_init
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
 IFDEF DEBUG
    call l2_dbg_hook             ; Layer 2 bring-up test card (Task 2);
                                  ; no-op unless T is held (debug.asm)
 ENDIF
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

; Reset the mutable resident sentinels that boot-time and first-turn code read
; before writing, to their assembly-time values. A warm re-entry (nextreg 2,1
; soft reset - QUIT reply N, and the game ending - which under CSpect re-enters
; this .nex with dirty RAM instead of reloading the file image) must boot as if
; cold. The boot-critical allocator/DDB/engine state (bankTable, ramExpanded,
; ddbHandle, flags, procSP, doallObj, rngState) is already rebuilt
; unconditionally by bank_table_init / ram_detect / ddb_load / eng_init_game;
; these are the remaining read-before-write sentinels not covered elsewhere.
; dbgTilemap (DEBUG only) is reset here too: dbg_engage_tilemap (debug.asm)
; doesn't set it until after boot_banner/ram_diag/bank_selftest have already
; read it to route their output, so it must be cold-equivalent before those
; first run. On real hardware nextreg 2,1 hands control back to NextZXOS, so
; this path is exercised only under the CSpect dev loop - but a cold-equivalent
; boot is correct robustness regardless.
boot_data_init:
    ld a, $FF
    ld (chrHandle), a           ; CHR font handle: $FF = no open handle
    ld a, 255
    ld (prevVerb), a            ; compound-sentence previous verb
    ld a, GFX_EMPTY
    ld (stagedPic), a           ; picture cache staging sentinels
    ld (stagedEntry), a         ; all gfx staged state resets together
    xor a
    ld (gfxTick), a
    ld (stagedMode), a
    ld (stagedHeight), a
    ld a, 7*2
    ld (tmAttr), a             ; tilemap attribute (white on black)
    xor a
    ld (tmUp), a               ; tilemap-live flag (fatal-path display route)
    ld (ramSaveOk), a          ; RAMSAVE-present guard for RAMLOAD
    ld (wrapLock), a           ; print-pipeline sentinels (print.asm)
    ld (wrapLen), a
    ld (moreLock), a
    ld (chsGfx), a             ; upper-charset escape latch, same hazard as
                                ; wrapLock/moreLock: read unconditionally
                                ; per printed char (prn_char_raw)
 IFDEF DEBUG
    ld (dbgTilemap), a         ; force the ULA route until dbg_engage_tilemap
                                ; runs, matching cold boot
 ENDIF
    ret

    INCLUDE "hardware.asm"
    INCLUDE "interrupts.asm"
    INCLUDE "banks.asm"
    INCLUDE "gfxcache.asm"
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
    INCLUDE "overlay2.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
