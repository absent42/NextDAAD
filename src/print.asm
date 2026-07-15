; The print pipeline: decode dispatch, escapes, More... paging.
; Paging lives HERE, not in windows.asm: prn_newline and prn_char's
; wrap handling both run the More... check, so wrapped long lines page
; exactly like explicit newlines.

; A = kind 0-3, E = number. Prints one whole message.
print_msg:
    push af
    push de
    call data_save
    pop de
    pop af
    call msg_seek
    jr c, .badnum
    xor a
    ld (tokActive), a           ; fresh stream
.loop:
    call txt_next_decoded
    jr c, .done
    call prn_decoded
    jr .loop
.done:
    jp data_restore
.badnum:
 IFDEF DEBUG
    ld c, '?'
    call prn_char
    ld c, 'M'
    call prn_char
    ld c, 'S'
    call prn_char
    ld c, 'G'
    call prn_char
 ENDIF
    jp data_restore

; A = decoded 7-bit character. Dispatches escapes, prints the rest.
; Token references are resolved by txt_next_decoded before this runs.
prn_decoded:
    cp $0D
    jp z, prn_newline
    cp $0B
    jp z, win_cls
    cp $0C
    jp z, wait_key_reset
    cp $0E
    jr z, .gfxon
    cp $0F
    jr z, .gfxoff
    cp '_'
    jr z, .objname
    cp '@'
    jr z, .objname
    ld c, a
    jr prn_char
.gfxon:
    ld a, 128
    ld (chsGfx), a
    ret
.gfxoff:
    xor a
    ld (chsGfx), a
    ret
.objname:
    ld hl, (objname_hook)
    jp (hl)

; C = printable decoded char. Applies the charset offset ($20-$7F only),
; prints, and runs the More... check when the print wrapped the line.
prn_char:
    ld a, c
    cp $20
    jr c, .have                 ; $10-$1F extended glyphs print direct
    cp $80
    jr nc, .have
    ld a, WIN_FLAGS
    call win_field
    bit 0, (hl)                 ; window forces upper charset?
    jr nz, .upper
    ld a, (chsGfx)
    or a
    jr nz, .upper
    ld a, c
    jr .have
.upper:
    ld a, c
    add a, 128
.have:
    call win_putc
    ret nc                      ; no wrap
    call win_newline_only       ; complete the wrap's line advance
    jr prn_more_check

; Explicit newline with paging.
prn_newline:
    call win_newline_only
    jr prn_more_check

; The raw window newline (windows.asm's win_newline), named for
; clarity at call sites in this module.
win_newline_only:
    jp win_newline

; Fire the More... prompt when the window's printed lines reach h-1.
; Corrupts all registers. Preserves the outer reader, its in-flight
; push depth and physical MMU state around the nested SM32 print.
prn_more_check:
    ld a, (moreLock)
    or a
    ret nz
    ld a, WIN_FLAGS
    call win_field
    bit 1, (hl)                 ; More disabled for this window?
    ret nz
    ld a, WIN_H
    call win_field
    ld a, (hl)
    dec a
    ld e, a                     ; trigger threshold = h-1
    ld a, WIN_LINES
    call win_field
    ld a, (hl)
    cp e
    ret c
    ld (hl), 0                  ; reset the counter
    ; preserve the outer reader position and in-flight push depth
    ; (a nested SM32 token print may push/pop the reader stack)
    ld a, (rdPage)
    ld (moreSaveRdSv), a
    ld hl, (rdPtr)
    ld (moreSaveRdSv+1), hl
    ld a, (rdSaveSP)
    ld (moreSaveRdSv+3), a
    ld a, (tokActive)
    ld (moreSaveRdSv+4), a
    xor a
    ld (tokActive), a           ; SM32 starts its own fresh stream
    ; preserve the outer MMU-save shadow (the nested print_msg overwrites it)
    ld a, (savedMMU6)
    ld (moreSaveMMU), a
    ; preserve the physical MMU slot exactly as mapped pre-fire
    ld e, NR_MMU6
    call nr_read
    ld (morePhysMMU6), a
    ld a, 1
    ld (moreLock), a
    ld a, 0                     ; SM32 through the normal pipeline
    ld e, 32
    call print_msg
    call wait_key
    xor a
    ld (moreLock), a
    ; erase the prompt line and return the cursor to its start
    ld a, WIN_CURX
    call win_field
    ld (hl), 0
    call win_attr
    ld a, e
    ld (tmAttr), a
    ld hl, (curWin)
    ld c, (hl)                  ; window x
    inc hl
    ld b, (hl)                  ; window y
    inc hl
    ld e, (hl)                  ; width
    push de
    ld a, WIN_CURY
    call win_field
    ld a, (hl)
    add a, b
    ld b, a                     ; screen row of the prompt line
    pop de
    ld d, 1
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ; restore the outer MMU-save shadow (savedMMU6)
    ld a, (moreSaveMMU)
    ld (savedMMU6), a
    ; restore reader position and push depth (variables only - no
    ; physical remap here)
    ld a, (moreSaveRdSv)
    ld (rdPage), a
    ld hl, (moreSaveRdSv+1)
    ld (rdPtr), hl
    ld a, (moreSaveRdSv+3)
    ld (rdSaveSP), a
    ld a, (moreSaveRdSv+4)
    ld (tokActive), a
    ; restore the physical MMU slot exactly as it was pre-fire
    ld a, (morePhysMMU6)
    nextreg NR_MMU6, a
    ret

; HL = resident encoded string (255-complemented), terminated by an
; encoded $0A (byte $F5). Same escapes as messages, no tokens.
prn_encoded:
    ld a, (hl)
    inc hl
    cpl
    cp $0A
    ret z
    push hl
    call prn_decoded
    pop hl
    jr prn_encoded

; Block until any key is pressed then released. Corrupts AF.
wait_key:
.press:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr z, .press
.release:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr nz, .release
    ret

; $0C escape: wait for a key, then the pause restarts the page count.
wait_key_reset:
    call wait_key
    jr prn_reset_lines

; Reset the current window's printed-line counter (the More... pager).
prn_reset_lines:
    ld a, WIN_LINES
    call win_field
    ld (hl), 0
    ret

objname_stub:
    ret

; A = byte -> decimal via prn_char, no leading zeros ("0" for zero).
prn_dec8:
    ld l, a
    ld h, 0
; HL = word -> decimal via prn_char. Corrupts all.
prn_dec16:
    ld e, 0                     ; digits-started flag
    ld bc, -10000
    call prn_dec_digit
    ld bc, -1000
    call prn_dec_digit
    ld bc, -100
    call prn_dec_digit
    ld bc, -10
    call prn_dec_digit
    ld a, l
    add a, '0'
    ld c, a
    jp prn_char

prn_dec_digit:
    ld a, '0'-1
.sub:
    inc a
    add hl, bc
    jr c, .sub
    sbc hl, bc                  ; undo the overshoot
    cp '0'
    jr nz, .emit
    bit 0, e
    ret z                       ; suppress leading zero
.emit:
    ld e, 1
    push hl
    push de
    ld c, a
    call prn_char
    pop de
    pop hl
    ret

chsGfx:       db 0
moreLock:     db 0
objname_hook: dw objname_stub
moreSaveMMU:  db 0
morePhysMMU6: db 0
moreSaveRdSv: ds 5
