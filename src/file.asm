; esxDOS API wrappers and the DDB loader.
; Errors return CF set with the esxDOS code in A; callers decide policy.
; Reads into banked memory go through the $C000 window; ddb_load
; saves and restores the window mapping around all paging.

esx_getsetdrv:
    xor a
    rst $08
    db ESX_GETSETDRV
    ret

esx_fopen:
    rst $08
    db ESX_F_OPEN
    ret

esx_fread:
    rst $08
    db ESX_F_READ
    ret

esx_fwrite:
    rst $08
    db ESX_F_WRITE
    ret

esx_fseek:
    rst $08
    db ESX_F_SEEK
    ret

esx_fclose:
    rst $08
    db ESX_F_CLOSE
    ret

; Load GAME.DDB into 8K pages DDB_PAGE_FIRST.. via slot 6.
; Out: A = DDB_OK, DDB_E_FILE, DDB_E_SIZE or DDB_E_HDR.
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
    jr c, .efile
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
    ld a, (ddbHeader+0)
    cp DDB_VERSION
    jr nz, .badhdr
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
                                 ; no DDB/SD state (tm_font_init loads it
                                 ; before even trying esxDOS for GAME.CHR),
                                 ; so re-arming it here is always safe,
                                 ; including the esxDOS-absent case that
                                 ; likely caused the failure. fatal() never
                                 ; returns, so clobbering tmUp/tmAttr/the
                                 ; whole tilemap is fine even mid-game.
    ld a, 110                   ; pair 55: magenta paper (3), white ink (7)
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, 1
    ld e, TM_COLS
    ld a, GLYPH_SPACE
    call tm_fill_rect
    pop hl                       ; message ptr back, now that both
                                 ; corrupting calls are done
    call fatal_puts              ; release-safe (errors.asm)
.halt:
    di
    jr .halt

ddbName:     db "GAME.DDB", 0
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
                                 ; after the whole file verifies
savHandle:  db 0
savLocs:    ds 255
ramSaveBuf: ds 512               ; RAMSAVE: flags[256] + locs[<=255]
ramSaveOk:  db 0
