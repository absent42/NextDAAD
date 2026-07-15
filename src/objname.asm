; Object-name printing (_/@ escapes) and the shared list engine.

; A = '_' or '@'. Prints flag-51's OTX with the leading article word
; stripped; '@' capitalises the first emitted letter. Runs inside
; token expansion: reader bracketed by rd_push/rd_pop, window by
; data_save/data_restore. No referenced object ($FF) prints nothing.
objname_print:
    ld c, a
    ld a, (flags+FLAG_CUROBJ)
    cp $FF
    ret z
    ld b, a
    ld a, (ddbHeader+HDR_NUMOBJ)
    dec a
    cp b
    ret c
    push bc
    call rd_push
    call data_save
    pop bc
    ld e, b
    ld a, 3
    call msg_seek
    jr c, .out
    ld d, 0                     ; 0 in-article, 1 begun, 2 emitting
.loop:
    call rd_next
    cpl
    cp $0A
    jr z, .out
    bit 7, a
    jr nz, .tok
    cp ' '
    jr nz, .chr
    ld a, d
    or a
    jr nz, .spc                 ; spaces inside the name print
    ld d, 1                     ; article consumed
    jr .loop
.spc:
    ld a, ' '
    jr .emit
.chr:
    ld e, a
    ld a, d
    or a
    jr z, .loop                 ; still in the article word
    ld a, e
.emit:
    ; capitalise first emitted letter for '@'
    ld e, a
    ld a, d
    cp 1
    jr nz, .send
    ld a, c
    cp '@'
    jr nz, .send
    ld a, e
    cp 'a'
    jr c, .send
    cp 'z'+1
    jr nc, .send
    sub 32
    ld e, a
.send:
    ld d, 2
    push bc
    push de
    ld a, e
    ld c, a
    call prn_char
    pop de
    pop bc
    jr .loop
.tok:
    and $7F
    push bc
    push de
    call tok_print
    pop de
    pop bc
    ld a, d
    or a
    jr nz, .tokd
    jr .loop
.tokd:
    ld d, 2
    jr .loop
.out:
    call data_restore
    jp rd_pop

; A = location value, C = 0 LISTAT / 1 LISTOBJ.
list_at:
    cp LOC_HERE
    jr nz, .fixed
    ld a, (flags+FLAG_PLAYER)
.fixed:
    ld (lstLoc), a
    ld a, c
    ld (lstMode), a
    ld b, 0
    ld d, 0
.count:
    ld a, (numObj)
    cp b
    jr z, .counted
    ld a, b
    push bc
    push de
    call obj_ptr
    ld a, (lstLoc)
    cp (hl)
    pop de
    pop bc
    jr nz, .cnext
    inc d
.cnext:
    inc b
    jr .count
.counted:
    ld a, d
    ld (lstTotal), a
    or a
    jr nz, .some
    ld a, (lstMode)
    or a
    jr z, .emptyat
    ld a, (flags+FLAG_OFLAGS)
    and 127                     ; LISTOBJ empty: clear listed bit
    ld (flags+FLAG_OFLAGS), a
    ret
.emptyat:
    ld e, 53                    ; "Nothing."
    ld a, 0
    call print_msg
    jp prn_newline
.some:
    ld a, (lstMode)
    or a
    jr z, .body
    ld a, (flags+FLAG_OFLAGS)
    or 128
    ld (flags+FLAG_OFLAGS), a
    ld e, 1                     ; "I can also see:"
    ld a, 0
    call print_msg
    call prn_newline
.body:
    ld b, 0
    ld d, 0                     ; emitted count
.emit:
    ld a, (numObj)
    cp b
    jr z, .done
    ld a, b
    push bc
    push de
    call obj_ptr
    ld a, (lstLoc)
    cp (hl)
    pop de
    pop bc
    jr nz, .enext
    ld a, d
    or a
    jr z, .name
    push bc
    push de
    ld a, (lstTotal)
    dec a
    cp d
    ld e, 46                    ; ", "
    jr nz, .sep
    ld e, 47                    ; " and "
.sep:
    ld a, 0
    call print_msg
    pop de
    pop bc
.name:
    push bc
    push de
    ld a, b
    ld (flags+FLAG_CUROBJ), a
    ld a, '_'
    call objname_print
    pop de
    pop bc
    inc d
.enext:
    inc b
    jr .emit
.done:
    ld e, 48                    ; ".\n"
    ld a, 0
    jp print_msg

lstLoc:   db 0
lstMode:  db 0
lstTotal: db 0
