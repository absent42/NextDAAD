; esxDOS wrappers. Files open relative to the launch directory.
esx_init:
    xor a
    rst $08
    db ESX_GETSETDRV
    jr nc, .got
    ld a, '*'                    ; '*' is esxDOS F_OPEN's default-drive byte
.got:                             ; a failed open then shows ERR_NEX_OPEN, not a bad drive
    ld (esxDrive), a
    ret

; HL = ASCIIZ name in resident RAM. Out: CF set, or A = handle.
esx_open_name:
    push hl
    pop ix
    ld a, (esxDrive)
    ld b, ESX_MODE_READ
    rst $08
    db ESX_F_OPEN
    ret

; A = handle, DE = offset in the slot 6 window, BC = count.
; Out: CF set, or BC = bytes read.
esx_read6:
    ld ix, WIN6
    add ix, de
    rst $08
    db ESX_F_READ
    ret

esx_close_a:
    rst $08
    db ESX_F_CLOSE
    ret

; A = handle: rewind to offset 0 (IXL = 0 is the absolute seek mode).
esx_seek0:
    ld ix, 0
    ld bc, 0
    ld de, 0
    rst $08
    db ESX_F_SEEK
    ret

; HL = ASCIIZ suffix. Out: HL = nameBuf holding "INTRO\" + suffix.
name_intro:
    push hl                          ; suffix
    ld hl, introDir
    ld de, nameBuf
    ld bc, 6
    ldir                             ; DE = nameBuf + 6
    pop hl                           ; HL = suffix
.copy:
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    or a
    jr nz, .copy
    ld hl, nameBuf
    ret
introDir: db "INTRO", 92
