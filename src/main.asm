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
    call audio_init
    call im2_init
 IFDEF DEBUG
    ; SP8 prescaler probe: hold D during boot (row $FD bit 2)
    ld bc, $FDFE
    in a, (c)
    bit 2, a
    call z, aud_dmaprobe        ; never returns when entered
 ENDIF
    call dbg_cls
    call boot_banner
    call ram_detect
    call bank_table_init
    call ram_diag
    call bank_selftest
 IFDEF DEBUG
    ; DeZog quality-of-life: dezogif/serial-launch sessions inherit cwd
    ; at the SD root - see file.asm's ddb_load_debug_retry (this wraps
    ; plain ddb_load with a one-shot F_CHDIR-and-retry fallback) for the
    ; full story. Release keeps the plain, unwrapped call below.
    call ddb_load_debug_retry
 ELSE
    call ddb_load
 ENDIF
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
    ; Game takeover: wipe the FULL tilemap to the transparent
    ; attribute. The boot diagnostics have sat in rows 0-11 since
    ; dbg_engage_tilemap and the game windows never cover those rows,
    ; so they would stay resident behind Layer 2 art and reappear
    ; through every transparent pixel. After the DEBUG T-hook (which
    ; repaints the tilemap itself and must keep its own status rows
    ; while it runs), before the engine's first draw. Safe for
    ; fatal(): it re-arms the tilemap itself (txt_init) and paints its
    ; own bar and message; every print path re-sets tmAttr, so leaving
    ; it on the default attribute here binds nothing downstream.
    ld b, 0
    ld c, 0
    ld d, TM_ROWS
    ld e, TM_COLS
    call tm_clear_blank
    ; SP7 boot autoplay: probe GAME.AKY/GAME.SFB (loaders live in
    ; overlay1; the dispatcher-owned slot 7 is free at boot). Fail-
    ; silent when absent - same esxDOS discipline as every loader.
    ld a, OVL1_PAGE
    call ovl_map_page
    call aud_boot_probe
    ; XMES pool-bank claim sentinel (overlay0 data): same cross-bank
    ; boot-reset shape as aud_boot_probe above - see xms_boot_reset's
    ; own header comment (overlay0.asm) for why this needs an explicit
    ; OVL0_PAGE map rather than a plain boot_data_init poke.
    ld a, OVL0_PAGE
    call ovl_map_page
    call xms_boot_reset
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
    ; SP14c M1: chrHandle's boot write removed - the cell (tilemap.asm)
    ; is dead (grep of the whole tree finds only its declaration and
    ; this write, no reader anywhere). The chrHandle/chrScratch storage
    ; cells themselves are batch B's (tilemap.asm) to remove.
    ld a, 255
    ld (prevVerb), a            ; compound-sentence previous verb
    call gfx_cache_reset        ; picture cache: staged sentinels, cache
                                ; table, arena cursor - a warm re-entry
                                ; must not resurrect stale entries whose
                                ; banks bank_table_init recycles
    ld a, 7*2
    ld (tmAttr), a             ; tilemap attribute (white on black)
    xor a
    ld (tmUp), a               ; tilemap-live flag (see file.asm)
    ld (ramSaveOk), a          ; RAMSAVE-present guard for RAMLOAD
    ld (wrapLock), a           ; print-pipeline sentinels (print.asm)
    ld (wrapLen), a
    ld (moreLock), a
    ld (chsGfx), a             ; upper-charset escape latch, same hazard as
                                ; wrapLock/moreLock: read unconditionally
                                ; per printed char (prn_char_raw)
    ld (audEnable), a          ; ISR fast-path gate off until the audio
                                ; API re-enables it; a warm re-entry must
                                ; not leave the full-context audio ISR
                                ; path live against stale bank 24 state
                                ; (audio_init, called before this returns
                                ; to im2_init, already silences the PSGs
                                ; every boot regardless; aud_boot_probe
                                ; resets the bank state block)
    ld (audRequest), a         ; no stale edge-triggered audio requests
    ld (audRequest2), a        ; across a warm re-entry (both mailboxes)
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
    DISPLAY "resident ends at ", $, " headroom ", /D, RESIDENT_LIMIT - $

    INCLUDE "overlay0.asm"
    INCLUDE "overlay1.asm"
    INCLUDE "overlay2.asm"
    INCLUDE "video.asm"
    INCLUDE "audio/audiobank.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
