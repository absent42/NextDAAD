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
fatal:
    out ($FE), a
    ld a, (tmUp)
    or a
    jr z, .halt0
    push hl
    ld a, 62                    ; pair 31: magenta paper, white ink
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, 1
    ld e, TM_COLS
    ld a, GLYPH_SPACE
    call tm_fill_rect
    pop hl
 IFDEF DEBUG
    push hl
    ld b, 23
    ld c, 0
    call dbg_at
    pop hl
    call dbg_puts
 ENDIF
.halt0:
    di
.halt:
    jr .halt

ddbName:     db "GAME.DDB", 0
ddbHandle:   db $FF
ddbChunk:    db 0
ddbSize:     dw 0
ddbSizeHi:   db 0           ; third byte of the 24-bit size
scratchByte: db 0
tmUp:        db 0           ; 1 once windows_init has run (tilemap live)
ddbHeader:   ds DDB_HEADER_SIZE
