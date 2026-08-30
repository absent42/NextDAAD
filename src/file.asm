; esxDOS API wrappers and the DDB loader.
; Errors return CF set with the esxDOS code in A; callers decide policy.
; Reads into banked memory go through the $C000 window; ddb_load
; saves and restores the window mapping around all paging.

; Every wrapper below brackets its rst $08 with the resident cardBusy
; flag (interrupts.asm): set before the call, cleared after it returns.
; cardBusy_set/cardBusy_clear (just below) are the whole bracket body,
; shared by every wrapper - the pre-flags pad (engine.asm ALIGN 256) has
; no room for seven separate inline brackets, so the set/clear logic is
; centralised here and each wrapper only pays for a call in and a jump
; out. Both routines work through HL (SET/RES b,(HL), neither of which
; touches any flag) and never touch A or F: esxDOS is not documented to
; read F on entry to any of these calls, and cardBusy_clear's "jr" tail
; preserves the CF/A result esxDOS just set completely untouched back to
; the wrapper's own caller. HL itself is already documented as corrupted
; by every one of these wrappers (see aud_part_open's tail-call comment,
; overlay1.asm:2651-2652: "a plain tail-call into esx_fopen, so this
; routine's own corruption set is exactly esx_fopen's: Corrupts AF, BC,
; DE, HL, IX") so reusing it here adds no new corruption. esx_fseek's
; caller (vid_raw_seek0) also sets L before the call, but the seek mode
; esxDOS actually reads is IXL, not L - L is set only belt-and-braces
; and is unread on this raw rst $08 caller path (settled finding,
; overlay0.asm:2337-2349, SP11 T5 rider M2), so HL is just as safe for
; cardBusy_set to clobber-and-reload here as everywhere else. esx_fseek
; still brackets the call in push/pop hl anyway (see there) - belt-and-
; braces at zero cost, matching the caller's own posture, not a
; correctness requirement. The SFX refiller (frame ISR, Task 6) gates on
; cardBusy before touching the card - it must never run while any
; wrapper below is mid-call.
cardBusy_set:
    ld hl, cardBusy
    set 0, (hl)
    ret
cardBusy_clear:
    ld hl, cardBusy
    res 0, (hl)
    ret

esx_getsetdrv:
    call cardBusy_set
    xor a
    rst $08
    db ESX_GETSETDRV
    jr cardBusy_clear

esx_fopen:
    call cardBusy_set
    rst $08
    db ESX_F_OPEN
    jr cardBusy_clear

esx_fread:
    call cardBusy_set
    rst $08
    db ESX_F_READ
    jr cardBusy_clear

esx_fwrite:
    call cardBusy_set
    rst $08
    db ESX_F_WRITE
    jr cardBusy_clear

esx_fseek:
    push hl                 ; the mode esxDOS reads is IXL, not L (see
    call cardBusy_set       ; the header comment above) - L is unread
    pop hl                  ; here, so this save/restore is belt-and-
                             ; braces only, not a correctness need
    rst $08
    db ESX_F_SEEK
    jr cardBusy_clear

esx_fclose:
    call cardBusy_set
    rst $08
    db ESX_F_CLOSE
    jr cardBusy_clear

; A = handle, IX = 11-byte buffer. Out: CF set + A = esxDOS error.
; Buffer +7 (4 bytes, little-endian) is the file size.
esx_fstat:
    call cardBusy_set
    rst $08
    db ESX_F_FSTAT
    jr cardBusy_clear

; A = handle, IX = entry buffer (must be at $4000 or above - esxDOS
; writes it with the DivMMC RAM paged in over the low 16K), DE = buffer
; capacity in 6-byte entries. Out: CF set + A = esxDOS error; on success
; A = card/granularity flags, DE = UNUSED entries, HL = address one past
; the last entry written. HL is a RESULT here, unlike every other wrapper
; above, so this one saves it across cardBusy_clear (which works through
; HL) instead of tail-jumping into it. cardBusy_clear touches neither A
; nor F, so the flags/A results still cross back untouched.
esx_filemap:
    call cardBusy_set
    rst $08
    db ESX_DISK_FILEMAP
    push hl
    call cardBusy_clear
    pop hl
    ret

 IFDEF DEBUG
; DeZog quality-of-life fallback (see ddb_load_debug_retry, below): F_CHDIR
; ($a9). In: A=drive specifier, IX=ASCIIZ path. Out: CF set + A=esxDOS
; error code on failure. Only reachable via ddb_load_debug_retry, so
; DEBUG-only - Release never emits this.
esx_fchdir:
    call cardBusy_set
    rst $08
    db ESX_F_CHDIR
    jr cardBusy_clear
 ENDIF

; Load GAME.DDB into 8K pages DDB_PAGE_FIRST.. via slot 6.
; Out: A = DDB_OK, DDB_E_FILE, DDB_E_SIZE, DDB_E_HDR or DDB_E_MACHINE.
ddb_load:
    call data_save
    ld a, $FF
    ld (ddbHandle), a       ; $FF = no open handle
    call esx_getsetdrv
    jp c, .efile
    ; A = default drive from esx_getsetdrv, consumed by esx_fopen - keep A intact
    ld ix, ddbName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .efile
    ld (ddbHandle), a
    ld hl, 0
    ld (ddbSize), hl
    xor a
    ld (ddbSizeHi), a       ; size is 24-bit: ddbSizeHi:ddbSize (max 128K)
    ld (ddbChunk), a
.chunk:
    ld a, (ddbChunk)
    cp DDB_MAX_BANKS*2
    jr z, .checkover        ; 16 chunks full; any more data is oversize
    add a, DDB_PAGE_FIRST
    call data_map_page
    ld a, (ddbHandle)
    ld ix, DATA_WINDOW
    ld bc, $2000
    call esx_fread
    jp c, .efile            ; JP, not JR: the header checks below sit
                            ; between here and .efile and had this at
                            ; +127 with nothing to spare. Line 129
                            ; already uses JP to the same label.
    ld hl, (ddbSize)
    add hl, bc
    ld (ddbSize), hl
    jr nc, .nocarry
    ld hl, ddbSizeHi        ; carry into the third size byte
    inc (hl)
.nocarry:
    ld a, b
    cp $20
    jr nz, .loaded          ; short read = end of file
    ld a, (ddbChunk)
    inc a
    ld (ddbChunk), a
    jr .chunk
.checkover:
    ld a, (ddbHandle)
    ld ix, scratchByte
    ld bc, 1
    call esx_fread
    jr c, .efile
    ld a, b
    or c
    jr nz, .esize           ; a 129th kilobyte exists
.loaded:
    ld a, (ddbHandle)
    call esx_fclose
    ld a, $FF
    ld (ddbHandle), a
    ld a, DDB_PAGE_FIRST     ; copy header to resident buffer
    call data_map_page
    ld hl, DATA_WINDOW
    ld de, ddbHeader
    ld bc, DDB_HEADER_SIZE
    ldir
    call data_restore
    ld a, (ddbSizeHi)       ; 64K+ is always more than a header
    or a
    jr nz, .sizeok
    ld hl, (ddbSize)        ; must be at least a whole header
    ld de, DDB_HEADER_SIZE
    or a
    sbc hl, de
    jr c, .badhdr
.sizeok:
    ; SP16 A1: version 2 AND version 3 databases load. Nothing else in
    ; the header differs between them (compliance report Appendix A
    ; probe 2, re-confirmed 2026-07-31 on a fresh -v3 compile of
    ; BLANK_EN.DSF: byte 2 = 95, numSys = 63, all thirteen pointer
    ; words in the same places). The accepted pair is contiguous, so
    ; one SUB/CP range test replaces the equality test at no extra
    ; branch (doc 05 "range test by subtract-then-compare").
    ; Bytes 0 and 1 are adjacent, so ONE word load serves both tests:
    ; L = version, H = target. LD HL,(nn) is the fast 2A form, 16T/3B
    ; (doc 01), so the pair costs 24T/5B against 26T/6B for two
    ; LD A,(nn) - the machine test is 2 bytes cheaper than it looks.
    ld hl, (ddbHeader)
    ld a, l
    sub DDB_VERSION             ; 2 -> 0, 3 -> 1, anything else >= 2
    cp 2                        ; (0/1 wrap high and fail the same way)
    jr nc, .badhdr
    ld a, h                     ; machine nibble - see DDB_MACHINE_NXD
    and $F0                     ; (nextdaad.inc) for why the low nibble
    cp DDB_MACHINE_NXD << 4     ; MUST be masked off. NextDAAD databases
    ld a, DDB_E_MACHINE         ; ONLY: a classic $8400-based ZX database
    ret nz                      ; is refused here, which is what lets
                                ; rd_seek skip the rebase entirely. LD r,n
                                ; leaves F alone (doc 02), so the refusal
                                ; code stages before the branch and a bare
                                ; RET NZ suffices - no tail block, which
                                ; matters here: an extra block between
                                ; .chunk and .efile is what puts .efile's
                                ; JR out of reach.
    ld a, (ddbHeader+2)
    cp DDB_MAGIC
    jr nz, .badhdr
    xor a                   ; DDB_OK
    ret
.badhdr:
    ld a, DDB_E_HDR
    ret
.esize:
    ld a, DDB_E_SIZE
    jr .cleanup
.efile:
    ld a, DDB_E_FILE
.cleanup:
    push af
    ld a, (ddbHandle)
    cp $FF
    jr z, .noclose
    call esx_fclose
.noclose:
    call data_restore
    pop af
    ret

 IFDEF DEBUG
; DeZog quality-of-life (owner's first real hardware DeZog session): a
; dezogif/serial DeZog launch inherits cwd at the SD ROOT, not wherever
; the debug payload actually lives (the owner keeps it at DBG_DDB_
; FALLBACK_DIR, nextdaad.inc - edit that ONE DEFINE if it ever moves), so
; plain ddb_load's first attempt can come back DDB_E_FILE even though the
; card genuinely has the file. main.asm's boot path calls THIS in place
; of plain ddb_load (DEBUG only - see main.asm's own IFDEF). On DDB_E_
; FILE only, F_CHDIR into the fallback directory and retry ddb_load
; exactly once; any OTHER result (DDB_OK/DDB_E_SIZE/DDB_E_HDR/DDB_E_
; MACHINE) from the first attempt returns immediately, untouched: a
; database that IS there but is built for another target is found on
; the spot, and the fallback directory is never consulted for it. If
; the F_CHDIR itself fails, or the retried ddb_load STILL comes back
; DDB_E_FILE (or any other code), the retry's own return value is passed
; straight through - the net effect is identical to plain ddb_load, plus
; this one extra attempt. A normal Browser launch (cwd already holds
; GAME.DDB) never reaches the F_CHDIR at all: the first ddb_load already
; returns DDB_OK and this returns immediately, same as it always has.
; Out: A = DDB_OK, DDB_E_FILE, DDB_E_SIZE, DDB_E_HDR or DDB_E_MACHINE -
; identical contract to ddb_load.
ddb_load_debug_retry:
    call ddb_load
    cp DDB_E_FILE
    ret nz                       ; success, or a non-"missing" failure:
                                  ; no retry, pass through unchanged
    ld a, '*'                    ; esxDOS F_CHDIR: '*' = default drive
    ld ix, dbgDdbFallbackDir
    call esx_fchdir
    jr nc, .retry                ; chdir worked: try ddb_load once more
    ld a, DDB_E_FILE              ; chdir itself failed - esx_fchdir left
    ret                            ; its OWN esxDOS code in A; discard it
                                    ; and keep ddb_load's own contract
.retry:
    jp ddb_load                    ; tail call: whatever it returns IS the
                                    ; final result, propagated untouched

dbgDdbFallbackDir: db DBG_DDB_FALLBACK_DIR, 0
 ENDIF

; A = border colour, HL = ASCIIZ message. Never returns.
; Un-gated in both builds: dbg_puts/dbg_at are release stubs (debug.asm),
; so the message goes through fatal_puts (errors.asm) via the tilemap
; primitives instead - those are always resident, never stubbed.
fatal:
    out ($FE), a
    di                          ; the halt below never re-enables ints;
    call audio_init             ; silence the PSGs first (di stops the
                                ; ISR re-voicing a note before the
                                ; banner + halt; preserves HL)
                                ; audio_init (hardware.asm:46) must not touch HL - the
                                ; message pointer is still live here, not yet pushed
    push hl                      ; message ptr: kept on the stack across
                                 ; txt_init AND tm_fill_rect below, both
                                 ; of which corrupt HL - only popped once
                                 ; fatal_puts is about to need it
    call txt_init                ; force the tilemap live: a boot-time DDB
                                 ; failure reaches fatal() before
                                 ; windows_init ever runs (tmUp still 0),
                                 ; so the old tmUp gate skipped this whole
                                 ; block - see main.asm's ddb_load branch.
                                 ; txt_init's embedded-font fallback needs
                                 ; no DDB/SD state (tm_font_init is a pure
                                 ; ldir, no esxDOS since SP12 T1),
                                 ; so re-arming it here is always safe,
                                 ; including the esxDOS-absent case that
                                 ; likely caused the failure. fatal() never
                                 ; returns, so clobbering tmUp/tmAttr/the
                                 ; whole tilemap is fine even mid-game.
    ld a, TM_ATTR_ERROR         ; reserved pair 1: magenta paper, white ink
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, 1
    ld a, (tmCols)
    ld e, a
    ld a, GLYPH_SPACE
    call tm_fill_rect
    pop hl                       ; message ptr back, now that both
                                 ; corrupting calls are done
    call fatal_puts              ; release-safe (errors.asm)
.halt:
    di
    jr .halt

; ddbName relocated to errors.asm (SP11 Task 3 review fix 3): it needs
; 10 bytes now (see there) and file.asm's pre-flags region has none to
; spare without tripping engine.asm's flags ALIGN 256 pad - moving it
; post-flags (errors.asm) costs nothing there instead. This file's own
; references (ld ix,ddbName in ddb_load below) are unaffected: they are
; absolute addresses: the operand's VALUE changes at assembly, the
; instruction's byte COUNT does not, so nothing here needed reflowing.
ddbHandle:   db $FF
ddbChunk:    db 0
ddbSize:     dw 0
ddbSizeHi:   db 0           ; third byte of the 24-bit size
scratchByte: db 0
tmUp:        db 0           ; 1 once windows_init has run (tilemap live).
                            ; No longer read by fatal() (which now forces
                            ; the tilemap live itself via txt_init) - kept
                            ; as a general tilemap-state flag in case
                            ; anything else needs it.
; ddbVer IS header byte 0 - the resident header copy is already the
; cached version cell, so the V3 gate costs no extra storage and cannot
; drift out of step with the loaded database (SP16 T6).
ddbVer:
ddbHeader:   ds DDB_HEADER_SIZE

; --- .SAV file core -------------------------------------------------
; esx_fopen: A=drive (in), IX=filename ASCIIZ, B=mode; out CF=0 A=handle,
; CF=1 A=esxDOS error code. esx_fread/esx_fwrite: A=handle, IX=buffer,
; BC=count; out BC=actual count, CF=1 A=error on failure. Confirmed from
; ddb_load's own working usage (ld ix, ... before esx_fopen/esx_fread) -
; not HL, despite what a register-contract comment elsewhere might say.

; Derive savName ("NAME.SAV", 8.3 uppercase) from the typed inpLine.
; Out: CF set = empty or no usable characters. Corrupts AF, BC, HL, DE.
sav_fname:
    ld hl, inpLine
    ld de, savName
    ld b, 8
    ld c, 0
.copy:
    ld a, (hl)
    or a
    jr z, .fin
    inc hl
    cp ' '
    jr z, .copy                 ; spaces dropped, scan continues
    cp 'a'
    jr c, .keep
    cp 'z'+1
    jr nc, .keep
    sub 32                      ; uppercase
.keep:
    ld (de), a
    inc de
    inc c
    djnz .copy
.fin:
    ld a, c                     ; C counts stored chars
    or a
    jr z, .empty
    ex de, hl
    ld (hl), '.'
    inc hl
    ld (hl), 'S'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'V'
    inc hl
    ld (hl), 0
    or a
    ret
.empty:
    scf
    ret

; Save header scratch, filled before writes and validated on reads.
; savHdr+savNObj form one contiguous 6-byte block written/read as a unit.
savHdr:   db "NDSV", 1
savNObj:  db 0
savRdHdr: ds 6                  ; read-side scratch; never overwrites savHdr

; Write flags + object locations to savName. A = 0 OK / 1 io-error.
sav_write:
    call esx_getsetdrv
    jr c, .err
    ld ix, savName
    ld b, ESX_MODE_W
    call esx_fopen
    jr c, .err
    ld (savHandle), a
    ld a, (numObj)
    ld (savNObj), a
    ; header (6 bytes)
    ld a, (savHandle)
    ld ix, savHdr
    ld bc, 6
    call esx_fwrite
    jr c, .errclose
    ; flags (256 bytes)
    ld a, (savHandle)
    ld ix, flags
    ld bc, 256
    call esx_fwrite
    jr c, .errclose
    ; object locations: gather the +0 byte of each 6-byte entry into
    ; savLocs, then write numObj bytes
    call sav_gather_locs        ; fills savLocs, BC = numObj
    ld ix, savLocs
    ld a, (savHandle)
    call esx_fwrite
    jr c, .errclose
    ld a, (savHandle)
    call esx_fclose
    xor a
    ret
.errclose:
    ld a, (savHandle)
    call esx_fclose
.err:
    ld a, 1
    scf
    ret

; Copy objTable[i].loc -> savLocs[i]. Out: BC = numObj. Corrupts A,HL,DE.
sav_gather_locs:
    ld hl, objTable
    ld de, savLocs
    ld a, (numObj)
    or a
    jr z, .none
    ld b, a
.g:
    ld a, (hl)
    ld (de), a
    inc de
    add hl, OBJ_SIZE
    djnz .g
.none:
    ld a, (numObj)
    ld c, a
    ld b, 0
    ret

; Copy savLocs[i] -> objTable[i].loc (inverse of sav_gather_locs).
; In: numObj resident. Corrupts A, HL, DE, B.
sav_scatter_locs:
    ld a, (numObj)
    or a
    ret z
    ld hl, savLocs
    ld de, objTable
    ld b, a
.s:
    ld a, (hl)
    ld (de), a
    inc hl
    add de, OBJ_SIZE
    djnz .s
    ret

; Read savName into flags + object locations.
; A = 0 OK / 1 not-found / 2 io-error / 3 wrong-game.
; esxDOS F_READ clears CF on a short/EOF read (only A=error sets CF), so
; every esx_fread here re-checks the returned BC against the requested
; count: a header shortfall refuses before the byte compare (otherwise a
; zero-length file would leave savRdHdr holding a stale header from a
; previous successful read and pass validation); a flags/locs shortfall
; is classified io-error. The load is ATOMIC: flags and locations are
; staged (savStage/savLocs) and committed to live state only after
; every read verifies, so NO failure mode can damage the session.
sav_read:
    call esx_getsetdrv
    jp c, .ioerr
    ld ix, savName
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
    cp ESX_ENOENT
    jp z, .notfound
    jp .ioerr
.opened:
    ld (savHandle), a
    ; header (6 bytes) into read scratch
    ld a, (savHandle)
    ld ix, savRdHdr
    ld bc, 6
    call esx_fread
    jp c, .errclose_io
    ld hl, 6                    ; short/EOF read: CF clear, BC < 6
    or a
    sbc hl, bc
    jp nz, .errclose_wrong
    ; validate: "NDSV",1 (5 bytes) then numObj byte, before touching flags
    ld hl, savHdr
    ld de, savRdHdr
    ld b, 5
.cmp:
    ld a, (de)
    cp (hl)
    jp nz, .errclose_wrong
    inc hl
    inc de
    djnz .cmp
    ld a, (savRdHdr+5)
    ld hl, numObj
    cp (hl)
    jp nz, .errclose_wrong
    ; flags (256 bytes) into the STAGE, not the live page - the load is
    ; atomic: nothing touches live state until every byte is verified
    ld a, (savHandle)
    ld ix, savStage
    ld bc, 256
    call esx_fread
    jp c, .errclose_io
    ld hl, 256                  ; short/EOF read: CF clear, BC < 256
    or a
    sbc hl, bc
    jp nz, .errclose_io
    ; object locations into their stage
    ld a, (numObj)
    ld c, a
    ld b, 0
    ld ix, savLocs
    ld a, (savHandle)
    call esx_fread
    jp c, .errclose_io
    ld a, (numObj)              ; re-read expected count: BC now holds
    ld h, 0                     ; the actual bytes esx_fread returned,
    ld l, a                     ; not what was requested
    or a
    sbc hl, bc
    jp nz, .errclose_io
    ; everything verified: commit atomically
    ld hl, savStage
    ld de, flags
    ld bc, 256
    ldir
    call sav_scatter_locs
    ld a, (savHandle)
    call esx_fclose
    xor a
    ret
.errclose_io:
    ld a, (savHandle)
    call esx_fclose
    ld a, 2
    scf
    ret
.errclose_wrong:
    ld a, (savHandle)
    call esx_fclose
    ld a, 3
    scf
    ret
.notfound:
    ld a, 1
    scf
    ret
.ioerr:
    ld a, 2
    scf
    ret

savName:    ds 14                ; 8 + ".SAV" + NUL
savStage:   ds 256               ; sav_read staging: flags commit only
                                 ; after the whole file verifies. Also
                                 ; aliased by SVC_GETMSG (main.asm) as
                                 ; its decode buffer - safe because
                                 ; save/load and a service call are both
                                 ; strictly foreground and never overlap.
                                 ; Contract: the returned pointer is
                                 ; valid until the next SVC_GETMSG call
                                 ; OR a save/load.
savHandle:  db 0
savLocs:    ds 255
ramSaveBuf: ds 512               ; RAMSAVE: flags[256] + locs[<=255]
ramSaveOk:  db 0
