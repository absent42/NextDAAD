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
    ld a, (tmCols)
    ld e, a
    call tm_clear_blank
    ; XMES pool-bank claim sentinel (overlay0 data): see xms_boot_reset's
    ; own header comment (overlay0.asm) for why this needs an explicit
    ; OVL0_PAGE map rather than a plain boot_data_init poke.
    ; xbn_boot_load runs here too, BEFORE aud_boot_probe below: both
    ; call bank_alloc against the same shared pool, and a boot-time
    ; XBN load must win that race - a heavy-audio game's aud_boot_probe
    ; (AKY/SFB) can otherwise claim enough pool banks to starve XBN's
    ; single bank_alloc. Order is load-bearing; do not swap these two.
    ld a, OVL0_PAGE
    call ovl_map_page
    call xms_boot_reset
    call xbn_boot_load
    call xbn_api_init           ; copy the frozen SVC table to XBN_API;
                                ; resident (Task 6), so the OVL0_PAGE
                                ; mapping above is incidental, not required
    ; SP7 boot autoplay: probe GAME.AKY/GAME.SFB (loaders live in
    ; overlay1; the dispatcher-owned slot 7 is free at boot). Fail-
    ; silent when absent - same esxDOS discipline as every loader.
    ld a, OVL1_PAGE
    call ovl_map_page
    call aud_boot_probe
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
    ld (xbnIntOn), a           ; XBN frame-ISR gate off until an XBN loads
                                ; its own intEntry; a warm re-entry must not
                                ; leave the ISR calling a stale intEntry
                                ; against banks bank_table_init recycles
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
    jr z, .boot                 ; base model: no expansion pool to free
    ld hl, bankTable+BANK_EXP_FIRST
    ld b, BANK_EXP_LAST-BANK_EXP_FIRST+1
    ld a, BT_FREE
.exp:
    ld (hl), a
    inc hl
    djnz .exp
.boot:
    jp spr_boot_init            ; both exits reach the sprite state init

; ---- Sprite animation (SP20): the resident part. State lives on SPR_PAGE;
; only what must be reachable with that page unmapped is here.
sprName:      db "PART1", 92, "000.ANI", 0   ; 92 = backslash: a "\0" escape
                                             ; would embed a NUL
sprSavedMmu:  db 0, 0
sprIff:       db 0              ; spr_di's IFF2 sample

; Boot, from bank_table_init's tail: empty state, reserved slots.
spr_boot_init:
    ld a, (xbnIntOn)            ; a warm re-entry must never leave the tick
    and $FF-HOOK_SPR            ; armed over the empty state below
    ld (xbnIntOn), a
    ld hl, spr_state_init
    call spr_call
 IFDEF DEBUG
    ld hl, spr_selftest
    call spr_call
 ENDIF
    ret

; Call HL (a SPR_PAGE routine) with SPR_TAB_PAGE in slot 6 and SPR_PAGE in
; slot 7. Callable from any overlay: the remaps happen in resident code and
; the caller's slot-7 return address is only used after MMU7 is restored.
; Callee sees A, BC, DE, IX as passed. Corrupts F, HL. Mainline only: the ISR
; path saves through isr_hook_body.
spr_call:
    push hl
    push af
    push de
    ld e, NR_MMU6
    call nr_read
    ld (sprSavedMmu), a
    ld e, NR_MMU7
    call nr_read
    ld (sprSavedMmu+1), a
    pop de
    pop af
    nextreg NR_MMU6, SPR_TAB_PAGE
    nextreg NR_MMU7, SPR_PAGE
    pop hl
    call .jphl
    push af
    ld a, (sprSavedMmu)
    nextreg NR_MMU6, a
    ld a, (sprSavedMmu+1)
    nextreg NR_MMU7, a
    pop af
    ret
.jphl:
    jp (hl)

; Stop every live set. Free when none is armed. Preserves AF, BC, DE, HL, IX.
spr_stop_all:
    push af
    ld a, (xbnIntOn)
    and HOOK_SPR
    jr z, .none
    push hl
    push de
    push bc
    push ix
    ld hl, spr_stop_all_body
    call spr_call
    pop ix
    pop bc
    pop de
    pop hl
.none:
    pop af
    ret

; Mainline DI bracket for one select-then-write group: the sprite tick shares
; the NR $34 select-then-write sequence. Resident so overlay0's pointer
; sequences can use it with SPR_PAGE unmapped. IFF2 sampled twice through
; ld a,i (P/V), the nr_read idiom: the erratum can zero P/V once but not on
; two successive instructions. A caller that entered with interrupts off
; leaves with them off. Corrupts AF.
spr_di:
    ld a, i
    jp pe, .on
    ld a, i
.on:
    ld a, 0
    jp po, .off
    inc a
.off:
    ld (sprIff), a
    di
    ret
spr_ei:
    ld a, (sprIff)
    or a
    ret z
    ei
    ret

; Frame hook body for both ISR paths (full context already saved). Sprite
; tick first so author code can never delay it, then the XBN #int entry.
isr_hook_body:
    call xbn_isr_mmu_save
    ld a, (xbnIntOn)
    and HOOK_SPR
    jr z, .nospr
    nextreg NR_MMU6, SPR_TAB_PAGE
    nextreg NR_MMU7, SPR_PAGE
    call spr_tick
.nospr:
    ld a, (xbnIntOn)
    and HOOK_XBN
    jr z, .done
    call xbn_mmu_map
    ld ix, flags
    ld hl, (xbnInt)
    call .jphl
.done:
    jp xbn_isr_mmu_restore
.jphl:
    jp (hl)

; DDB_E_MACHINE arm for the boot dispatch at the top of this file, which
; is pre-anchor and could not afford the eight bytes. Reached by its
; JP Z, and ends in fatal(), so nothing returns here.
ddb_err_machine:
    ld a, ERR_BORDER_MACHINE
    ld hl, msgWrongMach
    jp fatal

; --- XBN dispatch (resident; overlay0 callers would unmap themselves) ---
; ext_forward (overlay0.asm) builds the classic EXTERN contract then jumps
; here with A/B/C/DE/IX loaded and extTarget already set. Resident because
; the call must survive overlay0 (slot 7, holding the caller) being paged
; out to map the XBN bank into slots 6+7 for the call, then paged back.
extTarget:  dw 0
extSaved:   dw 0                ; saved MMU6 (lo) / MMU7 (hi)
; ISR-private mirror of extSaved (Task 5's #int frame hook, interrupts.asm).
; ext_dispatch (foreground, above) can be mid-flight - extTarget loaded,
; extSaved holding the pre-extern mapping, XBN bank not yet mapped or
; already mapped and about to be unwound - when the frame ISR fires. If
; the hook reused extSaved/xbn_mmu_save it would overwrite the foreground's
; saved mapping, and ext_dispatch's own xbn_mmu_restore would then remap
; the WRONG pages on return. extSavedIsr and the pair below are the ISR's
; own slot; interrupts.asm's im2_isr never touches extSaved or extTarget.
extSavedIsr: dw 0

xbn_mmu_save:                   ; corrupts A, BC; result in extSaved
    ld bc, $243B
    ld a, NR_MMU6
    out (c), a
    inc b                       ; $253B
    in a, (c)
    ld (extSaved), a
    dec b
    ld a, NR_MMU7
    out (c), a
    inc b
    in a, (c)
    ld (extSaved+1), a
    ret

xbn_mmu_map:                    ; corrupts A; maps xbnBank into slots 6+7
    ld a, (xbnBank)
    add a, a                    ; 8K page = bank*2
    nextreg NR_MMU6, a          ; nextreg reg,A form
    inc a
    nextreg NR_MMU7, a
    ret

xbn_mmu_restore:                ; corrupts A
; CONTRACT: preserves F - the forwarded extern's CF verdict crosses here
; (ld/nextreg/ret set no flags).
    ld a, (extSaved)
    nextreg NR_MMU6, a
    ld a, (extSaved+1)
    nextreg NR_MMU7, a
    ret

; ISR-private twins of xbn_mmu_save/xbn_mmu_restore above, bodies
; identical except the store/load targets extSavedIsr instead of
; extSaved - see extSavedIsr's own comment for why the ISR cannot share
; the foreground pair. xbn_mmu_map (below-declared, above in the file)
; needs no ISR twin: it only reads xbnBank and writes NR_MMU6/7 directly,
; touching neither extSaved/extTarget nor any other foreground state, so
; interrupts.asm calls it as-is.
xbn_isr_mmu_save:               ; corrupts A, BC; result in extSavedIsr
    ld bc, $243B
    ld a, NR_MMU6
    out (c), a
    inc b
    in a, (c)
    ld (extSavedIsr), a
    dec b
    ld a, NR_MMU7
    out (c), a
    inc b
    in a, (c)
    ld (extSavedIsr+1), a
    ret

xbn_isr_mmu_restore:            ; corrupts A
    ld a, (extSavedIsr)
    nextreg NR_MMU6, a
    ld a, (extSavedIsr+1)
    nextreg NR_MMU7, a
    ret

; Full dispatch: contract registers pre-loaded by the caller.
ext_dispatch:
    push af
    push bc
    push de
    push hl
    call xbn_mmu_save
    call xbn_mmu_map
    pop hl
    pop de
    pop bc
    pop af
    call .invoke
    call xbn_mmu_restore
    ret
.invoke:
    push hl
    ld hl, (extTarget)
    ex (sp), hl
    ret                         ; jumps to target, HL intact

; Classic EXTERN register contract, moved out of overlay0's ext_forward
; (whose own guard checks alone filled its remaining DEBUG headroom) into
; this abundant resident tail. B=param1/C=fn still live from h_extern;
; extTarget already set by the caller. A/DE/HL/IX per h_extern's ABI
; comment: DE = objTable + param1*6 (Z80N MUL, same *6-stride idiom as
; overlay1.asm's obj lookup, SP14c OV1-1), HL = flags+param1, IX = flags,
; A = B = param1 (C untouched = fn). May NOT return to its caller on the
; CF-set path below - it fails the entry itself instead.
ext_build_contract:
    ld d, 6
    ld e, b
    mul d, e
    add de, objTable
    ld h, high flags            ; flags is ALIGN 256
    ld l, b
    ld ix, flags
    ld a, b
    call ext_dispatch
    ret nc                      ; action return: CF clear, entry continues
    ; CF set from a FORWARDED extern: fail the entry exactly as a failed
    ; condition, including reverting the done stamp eng_exec wrote
    ; before dispatch (ext_undone's mechanism, generalised).
    xor a
    ld (isDone), a
    pop hl                      ; discard eng_exec's call .jphl return
    call eng_top_ix
    jp eng_next_entry

; CALL lsb msb (dispatcher ABI, cprops row $82): B = lsb, C = msb of the
; target address. overlay0's h_call just jumps straight here - its own
; DEBUG headroom (11 bytes after Task 3) has no room for the range-check
; body, same reasoning as ext_build_contract above. Range-checks the
; target against the loaded XBN's window ($C000..xbnEnd, exclusive) and
; jumps into it via ext_dispatch on success; no XBN staged, or the
; address outside the window: no-op (falls through to ret), which was
; the old documented behaviour for every CALL before XBN support.
; xbnEnd's exclusive-end semantics (including the $FFFF clamp for a
; max-size XBN, Task 2) mean the classic HL:DE unsigned-compare idiom
; below (sbc hl,de / add hl,de - restores HL, carry set iff HL<DE) must
; reject HL == xbnEnd, which it does via ret nc.
call_dispatch:
    ld a, (xbnBank)
    inc a
    ret z                        ; $FF -> 0, no XBN staged
    ld l, b
    ld h, c                      ; HL = target address
    ld a, h
    cp $C0
    ret c                        ; below the window
    ld de, (xbnEnd)
    or a
    sbc hl, de
    add hl, de
    ret nc                       ; >= xbnEnd
    ld (extTarget), hl
    ld ix, flags                 ; contract: IX valid, A/B/C/HL/DE undefined
    jp ext_dispatch

; --- XBN service table (Task 6) ---------------------------------------
; Frozen JP table at XBN_API ($BEC8, nextdaad.inc), called directly by
; extern code with the XBN bank mapped into slots 6+7 (overlay0 NOT
; mapped) - every row target below must therefore be resident. The
; template and boot copy were planned for overlay0 (cheap there), but
; overlay0's DEBUG headroom is 9 bytes at this point in the project and
; cannot take xbn_api_tpl+xbn_api_init (30+9 bytes); this resident tail
; had ~1557 bytes free at the last build, so template, init and every
; service body land here instead. Rows 3-7 (fopen/fread/fwrite/fseek/
; fclose) landed Task 7; row 9 (getmsg) landed Task 8; unimplemented
; rows set CF and A = $FF.
xbn_api_tpl:
    jp svc_version               ; 0
    jp svc_putchar                ; 1
    jp svc_puts                   ; 2
    jp svc_fopen                  ; 3
    jp svc_fread                  ; 4
    jp svc_fwrite                 ; 5
    jp svc_fseek                  ; 6
    jp svc_fclose                 ; 7
    jp svc_random                 ; 8
    jp svc_getmsg                 ; 9
    jp svc_frames                 ; 10
    jp svc_getdate                ; 11
    jp svc_busy                   ; 12
    jp svc_palread                ; 13
    jp svc_window                 ; 14
    ASSERT $ - xbn_api_tpl == XBN_API_ROWS*3

xbn_api_init:                    ; boot; table copy is resident-to-resident,
                                 ; no MMU mapping required
    ld hl, xbn_api_tpl
    ld de, XBN_API
    ld bc, XBN_API_ROWS*3
    ldir
    ret

svc_version:
    ld a, 2
    or a                          ; CF clear
    ret

; xorshift on rngState (engine.asm), sharing the one stream h_random /
; rng_next (overlay0.asm:502-592) already advances for CHANCE/RANDOM.
; rng_next itself is overlay-bound and unreachable here (the extern bank
; occupies slots 6+7 during a service call, not overlay0), so the state
; transform is duplicated verbatim from overlay0.asm:549-574 rather than
; called - both streams still share the one algorithm and the one
; rngState cell. Unlike rng_next this does NOT scale to 1..100: xbn.inc
; documents "SVC_RANDOM: out A = random byte", a raw full-range byte for
; extern use, not the CHANCE-specific 1..100 scaling.
; ISR-safe: the #int hook can call this mid-frame (xbntest.asm fn 35's
; soak) while the foreground is also inside this routine, so the
; rngState RMW is bracketed atomic vs interrupts using nr_read's idiom
; (hardware.asm:145-165) - RTL-verified SAFE, no erratum on the Z80N
; core (P/V latches at T3, interrupt acceptance clears IFF2 at T5, all
; four core variants).
; Double-sample kept anyway for emulator NMOS-erratum modelling parity.
; Consequence: with a hook armed, the shared rngState stream now
; interleaves hook and foreground draws, so its exact sequence is
; timing-dependent - reproducible per boot, not bit-for-bit across runs.
svc_random:
    push de
    push hl
    ld a, i
    jp pe, .sampled
    ld a, i                       ; erratum re-sample (nr_read idiom)
.sampled:
    push af                       ; IFF2 in P/V, on the stack
    di
    ld hl, (rngState)
    ; --- x ^= x << 7 ---
    ld d, h
    ld e, l                      ; DE = x
    xor a
    srl h
    rr l
    rra                          ; HL = x << 7
    ld h, l
    ld l, a
    ld a, h
    xor d
    ld h, a
    ld a, l
    xor e
    ld l, a                      ; HL = x ^ (x << 7)
    ; --- x ^= x >> 9 --- (high byte of x>>9 is always 0)
    ld a, h
    srl a
    xor l
    ld l, a
    ; --- x ^= x << 8 --- (low byte of x<<8 is always 0)
    ld a, h
    xor l
    ld h, a
    ld (rngState), hl             ; L = out random byte, safe across pop af
    pop af                        ; P/V = saved IFF2
    jp po, .noei                  ; interrupts were off: leave them off
    ei
.noei:
    ld a, l                       ; out A = random byte
    pop hl
    pop de
    or a                          ; CF clear
    ret

; Third MMU save/restore slot (svcSaved), same shape as xbn_mmu_save/
; restore (extSaved, above) and xbn_isr_mmu_save/restore (extSavedIsr).
; A service call happens INSIDE an active extern - extSaved already holds
; the pre-extern mapping and slots 6+7 hold the XBN bank - so svc_putchar
; needs its own slot: it brackets the call into PRINT_ENTRY, which can
; repoint NR_MMU6 for its own reasons (DDB message-bank paging behind
; the '_'/'@' object-name escape, the More... prompt's saved-MMU6 dance
; in print.asm), so that slots 6+7 are back on the XBN bank afterward -
; load-bearing for svc_puts, whose HL may point INTO that bank.
svcSaved: dw 0

; SVC_BUSY flags (Task 7). Resident tail, beside svcSaved, NOT
; gfxcache.asm (pre-anchor - a new byte there shifts the flags anchor).
; video.asm/overlay2.asm write these by absolute address, the same
; overlay-writes-resident pattern as h_picture's eng_set_done call
; (overlay2.asm) - both writers are always-mapped resident code from
; the banked overlays' point of view.
vidPlaying: db 0             ; 1 while vid_run owns the machine (set at
                              ; its single entry, cleared at its single
                              ; restore tail)
palBusy:    db 0             ; 1 only across gfx_blit's live palette
                              ; reveal and h_gfx .swap's reveal tail -
                              ; NARROW by owner ruling, not the whole
                              ; draw path

xbn_svc_mmu_save:                ; corrupts A, BC; result in svcSaved
    ld bc, $243B
    ld a, NR_MMU6
    out (c), a
    inc b                        ; $253B
    in a, (c)
    ld (svcSaved), a
    dec b
    ld a, NR_MMU7
    out (c), a
    inc b
    in a, (c)
    ld (svcSaved+1), a
    ret

xbn_svc_mmu_restore:             ; corrupts A
    ld a, (svcSaved)
    nextreg NR_MMU6, a
    ld a, (svcSaved+1)
    nextreg NR_MMU7, a
    ret

; A = char, through the DAAD window. PRINT_ENTRY = prn_decoded
; (print.asm), confirmed resident: print.asm is INCLUDEd ahead of
; engine.asm's flags/objTable ALIGN 256 anchor, entirely inside the
; resident image checked by the ASSERT below.
svc_putchar:
    push af
    call xbn_svc_mmu_save
    pop af
    call prn_decoded
    call xbn_svc_mmu_restore
    or a                          ; CF clear
    ret

; HL = ASCIIZ, may live in the extern bank. svc_putchar restores the
; extern's own MMU mapping after every character (see xbn_svc_mmu_save's
; comment), so (HL) stays readable across the loop despite PRINT_ENTRY's
; own mapping excursions. prn_flush after the loop mirrors print_msg's
; own idiom (print.asm) - without it the final buffered word stays in
; wrapBuf, unprinted, until the next unrelated print call flushes it.
svc_puts:
.loop:
    ld a, (hl)
    or a
    jr z, .done
    push hl
    call svc_putchar
    pop hl
    inc hl
    jr .loop
.done:
    call prn_flush
    or a                          ; CF clear
    ret

; File services (Task 7): thin veneers over file.asm's resident esx_*
; wrappers (esx_getsetdrv/esx_fopen/esx_fread/esx_fwrite/esx_fseek/
; esx_fclose), confirmed resident above (file.asm is INCLUDEd ahead of
; engine.asm's flags/objTable anchor, same as svc_putchar's PRINT_ENTRY).
; Each esx_* wrapper already brackets its rst $08 with cardBusy
; (file.asm's header comment) - these veneers add nothing on that front.
; No MMU work either: esxDOS's rst $08 does not remap MMU6/7, and a
; caller's buffer at $C000-$FFFF is exactly what it wants read or written
; while ITS OWN extern-bank mapping is still live in slots 6+7 - unlike
; svc_putchar/svc_puts, none of these call back into interpreter code
; that could repage those slots, so there is no svcSaved-style bracket to
; add. Signatures per authoring-kit/xbn.inc; register conventions per
; file.asm's esx_* wrappers and their existing overlay0.asm/overlay1.asm
; callers (sav_write_v2/sav_read_v2, vid_raw_seek0).
svc_fopen:                       ; in IX=name, B=mode; out A=handle/CF
    push bc
    push ix
    call esx_getsetdrv             ; sets the default drive; its own A/CF
                                    ; result is not what fopen wants back
    pop ix
    pop bc
    ret c
    jp esx_fopen

svc_fread:  jp esx_fread          ; in A=handle, IX=buf, BC=len; out BC/CF
svc_fwrite: jp esx_fwrite         ; in A=handle, IX=buf, BC=len; out CF

; in A=handle, BCDE=offset; out CF. xbn.inc's SVC_FSEEK contract carries
; no mode parameter - always mode 0 (absolute, from start). "ld ix, 0"
; sets IXL=0 (the register esxDOS's F_SEEK actually reads for the seek
; mode) without touching A, the handle already loaded by the caller -
; the same idiom vid_raw_seek0 (video.asm:7023-7029) uses immediately
; ahead of its own esx_fseek call, and the same idiom overlay0.asm:2350
; uses inside ext_xmes, not a push-af/ld a,0/ld ixl,a/pop-af shape,
; which would clobber A in between.
svc_fseek:
    ld ix, 0
    jp esx_fseek

svc_fclose: jp esx_fclose         ; in A=handle

; A = user message number (kind 1 = MTX, h_mes's own kind) -> savStage;
; out HL = savStage, BC = length (<=256, truncated), CF clear. CF set +
; A = $FF for a number >= numUsrMsg. Shares print_msg's own machinery
; (msg_seek then a txt_next_decoded loop, print.asm:7-24) with a
; store-to-buffer sink standing in for prn_decoded. Bytes are token-
; expanded (txt_next_decoded's own job) but control escapes ('_'/'@'
; and friends) are left raw - those are prn_decoded's job, not this
; routine's, so they are NOT interpreted here. savStage (file.asm:593)
; aliases sav_read's flags staging; safe because save/load and a
; service call are both strictly foreground and never overlap - see
; savStage's own comment. Buffer valid until the next SVC_GETMSG call
; OR a save/load.
;
; Bracketed by BOTH xbn_svc_mmu_save/restore (svcSaved - restores the
; extern's own slot 6+7 mapping so extern code resumes correctly after
; return, same idiom as svc_putchar's PRINT_ENTRY bracket above) and
; data_save/data_restore (the DDB walk's own slot-6-only bracket, the
; same idiom print_msg and objname_chk use around msg_seek). The two
; are not a nesting violation: data_save's single global slot
; (savedMMU6) is never live anywhere else while a service body runs -
; services are invoked from extern code via ext_dispatch, which uses
; its own extSaved slot, not data_save; the ISR uses extSavedIsr; so
; nothing else touches data_save's slot while this routine's data_save
; is live. xbn_svc_mmu_restore then also restores slot 7 (never
; touched by the DDB walk, so that half is a no-op here) purely to keep
; this body's shape identical to every other MMU-touching service.
svc_getmsg:
    push af                      ; message number
    call xbn_svc_mmu_save        ; extern's own slot6+7 mapping -> svcSaved
    call data_save                ; DDB walk's own slot6 bracket (print_msg idiom)
    pop af
    ld e, a
    ld a, 1                      ; kind 1 = user messages (MTX)
    call msg_seek
    jr c, .bad                   ; CF from msg_seek = number out of range
    xor a
    ld (tokActive), a            ; fresh stream (print_msg:15-16 idiom)
    ld hl, savStage
    ld bc, 0                     ; running count
.loop:
    push hl                      ; the store pointer MUST be preserved
                                 ; by us, not by the callee:
                                 ; txt_next_decoded guarantees only BC.
                                 ; Its token paths load HL with the
                                 ; token-table seek address and rd_pop
                                 ; corrupts HL outright - without this
                                 ; bracket every decoded byte after the
                                 ; first token reference was stored
                                 ; THROUGH the stale HL into the mapped
                                 ; DDB page, physically overwriting the
                                 ; token table (the svc-getmsg
                                 ; corruption defect, found in the
                                 ; field 2026-08-15; print_msg never
                                 ; hit it because it holds no pointer
                                 ; across the call)
    call txt_next_decoded        ; preserves BC (and only BC)
    pop hl
    jr c, .done                  ; CF = message terminator
    ld (hl), a
    inc hl
    inc bc
    ld a, b
    or a
    jr z, .loop                  ; B stays 0 until the 256th byte lands;
                                  ; then B=1 and the loop stops - BC=256
                                  ; on exit either way (cap reached), not
                                  ; 257 and not short of the true count
.done:
    call data_restore
    call xbn_svc_mmu_restore
    ld hl, savStage
    or a                          ; CF clear
    ret
.bad:
    call data_restore
    call xbn_svc_mmu_restore
    ld a, $FF
    scf
    ret

; Row 10. ld hl,(nn) is ONE instruction and interrupts are accepted only
; at instruction boundaries, so the 16-bit read cannot tear - no DI
; bracket needed. ISR-safe: resident, no MMU bracket, no shared buffer.
svc_frames:
    ld hl, (frameCounter)
    or a                          ; CF clear
    ret

; M_GETDATE: BC=date DE=time H=secs L=hundredths, CF set = no RTC.
; esx_filemap shape (file.asm:96-104): results cross cardBusy_clear via
; push/pop, since cardBusy_clear runs between the rst $08 and the
; caller seeing its result. cardBusy_set/clear work through HL only and
; touch no flags (file.asm:12-16) - push af here protects the CF
; verdict, push hl the H=secs/L=hundredths result; BC/DE cross
; cardBusy_clear untouched (never pushed, never touched by it). Lives
; here rather than file.asm: file.asm is pre-anchor (main.asm INCLUDE
; order, recon) and any new byte there shifts the flags anchor - this
; wrapper is resident tail only, same as the svc bodies beside it.
esx_getdate:
    call cardBusy_set
    rst $08
    db ESX_M_GETDATE
    push af
    push hl
    call cardBusy_clear
    pop hl
    pop af
    ret

svc_getdate: jp esx_getdate

; Row 12. Pure resident reads - ISR-safe. Bits append-only (bit 0
; vidPlaying, bit 1 cardBusy, bit 2 palBusy). Bits 0/2 are foreground-
; invisible (video playback and draws are foreground-synchronous) -
; observable only from the hook. Corrupts AF, L (documented in
; authoring-kit/xbn.inc's SVC_BUSY equate comment) - the smaller
; contract: HL is not a result register anywhere else in this table,
; so preserving it with push/pop would cost 4 bytes and 20T to protect
; a register no caller needs back.
svc_busy:
    ld a, (vidPlaying)
    and 1
    ld l, a
    ld a, (cardBusy)
    and 1
    add a, a
    or l
    ld l, a
    ld a, (palBusy)
    and 1
    add a, a
    add a, a
    or l                          ; A = bit2|bit1|bit0
    or a                          ; CF clear (A may be nonzero - or a still clears CF)
    ret

; Row 13. Reads NR $41/$44 straight from hardware - no interpreter-held
; palette table exists (gfx_blit reloads from the picture file itself
; every DISPLAY). Reads do NOT auto-increment (core nextreg.txt) - NR
; $40 is written explicitly for every entry. Edit-select is derived
; from whichever bank NR $43's display bit shows RIGHT NOW (never an
; unconditional first-bank select, never a constant $43 write - the
; fade rule, pal_edit_ctl's own reasoning), crossed with the A input;
; NR $43 is restored before return. This is the sanctioned foreground
; read path fade fn 42's hidden-bank blanking workaround no longer needs.
; A=1 reads the bank the display does not show - the staged palette
; while GFX 87/4 buffer mode is open.
; In IX = 512-byte buffer, A = bank select (0 displayed, 1 other/staged);
; 256 x (RRRGGGBB, %11000001-masked second byte); corrupts AF, BC, E, IX;
; CF clear; foreground-only.
svc_palread:
    ld c, a                       ; C = bank select (0 displayed, 1 other)
    ld e, NR_PAL_CTRL
    call nr_read                  ; A = live $43
    ld b, a                       ; B = saved $43 (restored at exit)
    and %00001111                 ; keep display/layer bits, clear edit field
    bit 2, a                      ; display shows bank 2?
    jr z, .shows1
    ; display shows bank 2: edit bank 2 unless inverted
    bit 0, c
    jr nz, .edit1
    or PAL_L2_EDIT_SECOND
    jr .apply
.shows1:
    bit 0, c
    jr nz, .edit2
.edit1:
    or PAL_L2_FIRST
    jr .apply
.edit2:
    or PAL_L2_EDIT_SECOND
.apply:
    nextreg NR_PAL_CTRL, a
    ld c, b                       ; C = saved $43 for the exit restore
    ld b, 0                       ; loop counter AND colour index, wraps
                                  ; 0..255 (256 reads)
.loop:
    ld a, b
    nextreg NR_PAL_INDEX, a
    ld e, NR_PAL_VALUE
    call nr_read
    ld (ix+0), a
    ld e, NR_PAL_VALUE9
    call nr_read
    and %11000001                ; bits 7-6 priority field (core latches
                                 ; two bits on a $44 write), bit 0 blue LSB
    ld (ix+1), a
    inc ix
    inc ix
    inc b
    jr nz, .loop
    ld a, c
    nextreg NR_PAL_CTRL, a        ; restore the foreground's NR $43
    or a                          ; CF clear
    ret

; Row 14. Selection flushes through the print path (win_select ->
; prn_flush - MMU6 dance, possible More prompt in the OLD window,
; documented) via svc_putchar's own bracket (xbn_svc_mmu_save/restore,
; svcSaved). Previous number is DERIVED from the curWin pointer, not a
; maintained byte: overlay1.asm:1874 (inp_stream_pop) writes curWin
; directly and flag 63 already rotted stale against that same write
; - a mirrored byte here would take the identical hit. Max 7
; subtractions of WIN_SIZE from the byte offset.
; xbn_svc_mmu_save corrupts A, BC (its own header comment) and
; win_select corrupts all registers (it calls prn_flush, documented
; "Corrupts all registers") - B (the derived previous number) needs a
; stack slot across BOTH calls, not one; xbn_svc_mmu_restore corrupts
; only A, so BC rides through that call unprotected. A resident scratch
; byte would work too, but costs a byte for no benefit over the stack
; here - the file's own svc_putchar/svc_puts bracket already parks AF
; on the stack across the identical MMU calls, so this stays consistent
; with that idiom rather than introducing a new storage class.
; In A = 0-7 (target). Out A = previous number, CF clear. A > 7: CF
; set, A/state unchanged. Foreground-only.
svc_window:
    cp 8
    jr c, .ok
    scf
    ret
.ok:
    push af                       ; target window number, for win_select
    ld hl, (curWin)
    ld de, winTable
    or a
    sbc hl, de                    ; HL = byte offset into winTable
    ld b, -1
.div:
    inc b
    ld de, WIN_SIZE
    or a
    sbc hl, de
    jr nc, .div                   ; B = offset / WIN_SIZE = previous number
    push bc                       ; B survives xbn_svc_mmu_save's BC clobber
    call xbn_svc_mmu_save
    pop bc
    pop af                        ; target window number back in A
    push bc                       ; B survives win_select's full clobber
    call win_select
    call xbn_svc_mmu_restore      ; A only - BC untouched
    pop bc
    ld a, b                       ; A = previous window number
    or a                          ; CF clear
    ret

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

; GFX 87 subs 3/4 draw-target state clear (Task 2). gfx_cache_reset
; (gfxcache.asm), eng_init_game (engine.asm) and overlay1.asm's two
; same-part LOAD/RAMLOAD paths all need to zero the THREE contiguous
; gfxDrawTarget/gfxRevealPend/gfxRevealMode bytes. Buffer mode is the
; only transient state here.
;
; gfxLayerOrder IS NOT WALKED and is never cleared by anything (owner
; ruling 2026-08-18). The layer order is game-owned presentation state,
; like INK, PAPER and the window table: boot establishes picture on top
; (the assembled db 0 plus hw_init) and only GFX n 17 changes it after
; that. A player loading a save in a text-on-top game must not be handed
; picture-on-top unreadable text, and an author must not have to
; re-assert the order after every RESTART, LOAD, RAMLOAD or part switch.
;
; The FALL-THROUGH into gfx_layer_apply stays, and its job has changed
; from pushing a cleared order to RE-ASSERTING the current one. That is
; harmless - the value written is the value already in force - and it is
; what keeps the byte and NR $15 in agreement at every reset, whatever
; else those paths did to the register on the way through. The walker
; also stops every live sprite set (sets are transient like pictures;
; the cache stays), so one 3-byte CALL still buys all three.
; Entry: A=0. Corrupts HL, and (via the fall-through) AF and E too -
; every caller is tolerant: eng_init_game reloads A with $FF next and
; never reads E; gfx_cache_reset's next instruction reloads A too and
; its loop below uses B, which nr_read preserves; overlay1's same-part
; LOAD site continues into eng_set_done (ld a,1 / ld (isDone),a / ret)
; and h_ramload simply rets to the dispatcher, which stamped the done
; flag before dispatch and consults neither A, E nor CF for an action
; condact - so no caller reads what this corrupts.
gfx_drawtarget_clear:
    call spr_stop_all           ; sets are transient like pictures; the cache
                                ; stays. Preserves every register.
    ld hl, gfxDrawTarget
    ld (hl), a
    inc hl
    ld (hl), a
    inc hl
    ld (hl), a
                                ; falls through: clearing the three
                                ; transient bytes and RE-ASSERTING the
                                ; game's layer order are one operation
                                ; at every reset site
; Push gfxLayerOrder to NR $15 bits 4-2, leaving every other bit of that
; register alone (lores enable, sprite priority, sprite border clip,
; sprite over border, sprite enable). RESIDENT on purpose: the sites
; that need it are the same-part LOAD paths in overlay1, which cannot
; reach l2_enable in overlay2.
; l2_enable and GFX sub 17 call THIS ENTRY POINT ALONE (compose only -
; they must not wipe draw-target/reveal state mid-game); the reset
; sites above call gfx_drawtarget_clear and fall into this body, where
; it re-asserts rather than resets. So exactly one routine composes this
; field and the byte can never disagree with the register.
; Corrupts AF, E; preserves BC (nr_read pushes it) and HL.
gfx_layer_apply:
    ld e, NR_LAYERS
    call nr_read
    and %11100011               ; clear bits 4-2, keep everything else
    ld e, a
    ld a, (gfxLayerOrder)
    or a
    ld a, e
    jr z, .write                ; 0 = picture on top: bits 4-2 = %000
    or %00001000                ; 1 = text on top:    bits 4-2 = %010
.write:
    nextreg NR_LAYERS, a
    ret

; A = width in columns (80 or 40). The one composer of NR $6B outside
; video playback (vid_play saves/restores the register wholesale) and
; the only writer of tmCols and tmStride. Clean slate per the GFX 18
; contract: full map blanked, all 8 windows reset at the new width.
; RESIDENT alongside gfx_layer_apply above (same reason: callable from
; overlay2). Corrupts everything.
tm_width_apply:
    ld (tmCols), a
    cp 40
    ld d, 80                     ; 40-col: 40*2 bytes/row
    ld e, TM_CTRL_ON & %10111111 ; bit 6 clear = 40x32
    jr z, .got
    ld d, 160                    ; 80-col: 80*2 bytes/row
    ld e, TM_CTRL_ON
.got:
    ld a, d
    ld (tmStride), a
    ; Blank the FULL 80x32 region in both modes: cells past the 40x32
    ; map would otherwise return stale on a later widen (display and
    ; pair_reclaim both walk them). Raw fill, not tm_cell_addr - the
    ; stride was just patched.
    ld a, TM_ATTR_DEFAULT
    ld (tmAttr), a
    ld hl, TM_MAP
    ld (hl), GLYPH_SPACE
    inc hl
    ld (hl), a
    dec hl
    push de
    ld de, TM_MAP+2
    ld bc, TM_COLS*TM_ROWS*2-2
    ldir
    pop de
    ld a, e
    nextreg NR_TM_CTRL, a        ; width bit flips only after the map is clean
    xor a
    ld (wrapLen), a              ; discard the pending wrap word: windows_init
                                 ; falls into win_select, whose prn_flush would
                                 ; print it onto the cleared screen
    jp windows_init              ; all 8 windows full-screen at (tmCols),
                                 ; cursors homed, window 0 reselected

    ASSERT $ <= RESIDENT_LIMIT
    DISPLAY "resident ends at ", $, " headroom ", /D, RESIDENT_LIMIT - $

    INCLUDE "overlay0.asm"
    INCLUDE "overlay1.asm"
    INCLUDE "overlay2.asm"
    INCLUDE "video.asm"
    INCLUDE "audio/audiobank.asm"
    INCLUDE "audio/streamfx.asm"
    INCLUDE "sprites.asm"

    CSPECTMAP "build/nextdaad.map"
    SAVENEX OPEN "build/nextdaad.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
