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
; A = B = param1 (C untouched = fn).
ext_build_contract:
    ld d, 6
    ld e, b
    mul d, e
    add de, objTable
    ld h, high flags            ; flags is ALIGN 256
    ld l, b
    ld ix, flags
    ld a, b
    jp ext_dispatch

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
    ASSERT $ - xbn_api_tpl == XBN_API_ROWS*3

xbn_api_init:                    ; boot; table copy is resident-to-resident,
                                 ; no MMU mapping required
    ld hl, xbn_api_tpl
    ld de, XBN_API
    ld bc, XBN_API_ROWS*3
    ldir
    ret

svc_unimpl:
    ld a, $FF
    scf
    ret

svc_version:
    ld a, 1
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
svc_random:
    push de
    push hl
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
    ld (rngState), hl
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
; the same idiom overlay0.asm's vid_raw_seek0 uses immediately ahead of
; its own esx_fseek call (overlay0.asm:2347), not a push-af/ld a,0/
; ld ixl,a/pop-af shape, which would clobber A in between.
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
    call txt_next_decoded        ; preserves BC
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
