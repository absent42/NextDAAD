; NextDAAD - DAAD interpreter for the ZX Spectrum Next
; Foundation: boot, memory, DDB loading. See docs/superpowers/specs.

    DEVICE ZXSPECTRUMNEXT
    SLDOPT COMMENT WPMEM, LOGPOINT, ASSERTION
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
    dec a
    dec a
    jp z, ddb_err_machine   ; 4 = DDB_E_MACHINE, tested EXPLICITLY so the
    ld a, ERR_BORDER_BADHDR ; chain still falls through to bad-header for
    ld hl, msgBadHdr        ; 3 and for any code the loader never returns.
    jp fatal                ; Its arm lives POST-anchor (resident tail,
                            ; below the INCLUDEs) - everything here is
                            ; pre-anchor and spends the pre-flags pad,
                            ; which the DDB machine guard had already
                            ; taken 10 bytes of.
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
    ; Game takeover: wipe the FULL tilemap to blank cells at the
    ; default attribute (tm_clear_blank - the tilemap has no
    ; transparency). The boot diagnostics have sat in rows 0-11 since
    ; dbg_engage_tilemap and the game windows never cover those rows,
    ; so they would stay resident behind Layer 2 art and reappear
    ; through every transparent pixel, before the engine's first draw.
    ; Safe for fatal(): it re-arms the tilemap itself (txt_init) and
    ; paints its own bar and message; every print path re-sets tmAttr,
    ; so leaving it on the default attribute here binds nothing
    ; downstream.
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
    ld a, TM_ATTR_DEFAULT
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
    INCLUDE "tmpairs.asm"
    INCLUDE "debug.asm"

; --- SP18 item 7 Task 11: resident tail (POST-anchor) -----------------
; These two live here rather than beside the other audio cells in
; interrupts.asm because that file is entirely PRE-anchor: it is included
; above, ahead of engine.asm's ALIGN 256, and every byte added there
; comes out of the pre-flags pad, which has 19 bytes free in DEBUG (34
; before the DDB machine-nibble guard). This point is past the anchor, so
; these draw on the resident tail the ASSERT below guards instead.
; interrupts.asm's audio-cell block carries a pointer comment to here.

; Settle which pointer base the loaded database uses and write it into
; the two LD DE,nn immediates that consume it: rd_seek (ddbtext.asm)
; subtracts it to reach a file offset, eng_ptr_abs (engine.asm) adds it
; back to rebuild an absolute pointer for the process stack. They must
; always agree or a saved resume point decodes somewhere else.
;
; Self-modified rather than read from a variable so the hot path keeps
; LD DE,nn at 3 bytes and 10T - rd_seek is on every text seek and every
; condact re-seek, and LD DE,(nn) would cost a byte and 10T at both
; sites (doc 08). The assembly-time value of both operands is
; DDB_ZX_BASE, so a classic database is correct even if this never runs.
; Called from ddb_load once the header has validated; a warm re-entry
; re-runs ddb_load and so re-resolves. Corrupts AF, DE.
ddb_base_resolve:
    ld de, DDB_ZX_BASE
    ld a, (ddbHeader+1)
    and $F0
    cp DDB_MACHINE_ZX << 4
    jr z, .set
    ld de, DDB_NXD_BASE
.set:
    ld (rd_seek_base), de
    ld (eng_ptr_base), de
    ret

; Build the bank allocator's table: everything reserved, then the pools
; freed. MOVED HERE from banks.asm (2026-08-12): it runs once at boot,
; and banks.asm is entirely pre-anchor, so 53 bytes of one-shot boot
; code were being paid for out of the scarcest region in the project.
; The rest of the allocator stays there - bank_alloc, bank_free and
; data_map_page are hot and belong beside each other.
; What is free is decided HERE and asserted by debug.asm's
; bank_selftest; the two must be changed together.
bank_table_init:
    ld hl, bankTable
    ld b, BANK_TABLE_SIZE
    xor a                   ; BT_RESERVED
.zero:
    ld (hl), a
    inc hl
    djnz .zero
    ld a, BT_FREE
    ld (bankTable+BANK_POOL_A), a
    ld (bankTable+BANK_POOL_A_END), a
    ld hl, bankTable+BANK_POOL_C     ; 20-23: released from the DDB
    ld b, BANK_POOL_C_END-BANK_POOL_C+1
.poolc:
    ld (hl), a
    inc hl
    djnz .poolc                      ; A still holds BT_FREE for the
                                     ; pool B loop below
    ld hl, bankTable+BANK_POOL_B
    ld b, BANK_BASE_LAST-BANK_POOL_B+1
.pool:
    ld (hl), a
    inc hl
    djnz .pool
    ld a, (ramExpanded)
    or a
    ret z
    ld hl, bankTable+BANK_EXP_FIRST
    ld b, BANK_EXP_LAST-BANK_EXP_FIRST+1
    ld a, BT_FREE
.exp:
    ld (hl), a
    inc hl
    djnz .exp
    ret

; DDB_E_MACHINE arm for the boot dispatch at the top of this file, which
; is pre-anchor and could not afford the eight bytes. Reached by its
; JP Z, and ends in fatal(), so nothing returns here.
ddb_err_machine:
    ld a, ERR_BORDER_MACHINE
    ld hl, msgWrongMach
    jp fatal

; Call HL (a routine on SFX_PAGE) on overlay1's behalf, exactly as
; sfx_open_tramp (banks.asm) does for sfx_stream_open: overlay1 and
; SFX_PAGE share the slot-7 window, so the nextreg that pages the callee
; in also pages the caller out, and the map/call/unmap has to run from
; resident memory. Slot 7 goes back to OVL1_PAGE before returning, so the
; caller resumes on its own page. Slot 6 must already hold AUD_PAGE_LO
; where the callee touches channel 1's block or a window descriptor -
; aud_sfx_init, sfx_alloc and sfx_stream_rewind all map it first.
; aud_ctc_params does not touch slot 6 at all, so aud_load_wav's call
; (the fresh-TC ruling's new fourth user of this trampoline) needs no
; such mapping.
;
; Generic (HL) rather than one trampoline per callee because the resident
; tail is the scarcest pool in the project: aud_sfx_init, sfx_alloc,
; sfx_stream_rewind and (2026-08-10 fresh-TC ruling) aud_ctc_params all
; share these 14 bytes. sfx_open_tramp stays separate - sfx_stream_open
; takes its parameters in A/L/DE/IX, so HL is not free there.
; DE crosses BOTH WAYS UNTOUCHED: the return address rides the Z80's own
; CALL/RET stacking through .enter below rather than a register, so
; nothing here needs DE as scratch. Load-bearing for aud_ctc_params, whose
; own parameter (the rate) is DE. A and F cross both ways untouched too:
; nextreg (ED 91) writes neither, so a callee's return value and carry
; survive the unmap. Every other register is whatever the CALLEE leaves -
; this is a plain call with a page swap around it, not a preserving wrapper.
sfx_page_call:
    nextreg NR_MMU7, SFX_PAGE
    call .enter
    nextreg NR_MMU7, OVL1_PAGE
    ret
.enter:
    jp (hl)

; Channel 2's sampled-effect pump state block (SMPB_* offsets in
; nextdaad.inc), seeded once at boot by aud_sfx_init. RESIDENT, unlike
; channel 1's sfxChan0, which is page-48 data: page 48 is this
; sub-project's binding budget, and an always-mapped block costs the pump
; nothing, since every aud_smp_* routine reaches its block IX-relative
; and so does not care which slot it is in. Being always mapped also
; removes the "page 48 must be in slot 6" precondition from any future
; reader of channel 2's state, mainline or ISR.
sfxChan1: ds SMPB_SIZE

    ASSERT $ <= RESIDENT_LIMIT
    DISPLAY "resident ends at ", $, " headroom ", /D, RESIDENT_LIMIT - $

    INCLUDE "overlay0.asm"
    INCLUDE "overlay1.asm"
    INCLUDE "overlay2.asm"
    INCLUDE "video.asm"
    INCLUDE "audio/audiobank.asm"
    INCLUDE "audio/streamfx.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
