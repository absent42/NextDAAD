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

; Load GAME.DDB into banks BANK_DDB_FIRST.. via the window.
; Out: A = DDB_OK, DDB_E_FILE, DDB_E_SIZE or DDB_E_HDR.
ddb_load:
    call bank_window_save
    ld a, $FF
    ld (ddbHandle), a       ; $FF = no open handle
    call esx_getsetdrv
    jp c, .efile
    ld ix, ddbName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .efile
    ld (ddbHandle), a
    ld hl, 0
    ld (ddbSize), hl
    xor a
    ld (ddbSizeHi), a       ; size is 24-bit: ddbSizeHi:ddbSize (max 128K)
    ld (ddbBankIdx), a
.chunk:
    ld a, (ddbBankIdx)
    cp DDB_MAX_BANKS
    jr z, .checkover        ; 8 banks full; any more data is oversize
    add a, BANK_DDB_FIRST
    call bank_map_c000
    ld a, (ddbHandle)
    ld ix, WINDOW_ADDR
    ld bc, $4000
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
    cp $40
    jr nz, .loaded          ; short read = end of file
    ld a, (ddbBankIdx)
    inc a
    ld (ddbBankIdx), a
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
    ld a, BANK_DDB_FIRST    ; copy header to resident buffer
    call bank_map_c000
    ld hl, WINDOW_ADDR
    ld de, ddbHeader
    ld bc, DDB_HEADER_SIZE
    ldir
    call bank_window_restore
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
    call bank_window_restore
    pop af
    ret

; A = border colour, HL = ASCIIZ message. Never returns.
fatal:
    out ($FE), a
 IFDEF DEBUG
    push hl
    ld b, 23
    ld c, 0
    call dbg_at
    pop hl
    call dbg_puts
 ENDIF
    di
.halt:
    jr .halt

ddbName:     db "GAME.DDB", 0
ddbHandle:   db $FF
ddbBankIdx:  db 0
ddbSize:     dw 0
ddbSizeHi:   db 0           ; third byte of the 24-bit size
scratchByte: db 0
ddbHeader:   ds DDB_HEADER_SIZE
