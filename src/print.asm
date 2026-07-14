; The print pipeline: decode dispatch, escapes, More... paging.
; Paging lives HERE, not in windows.asm: prn_newline and prn_char's
; wrap handling both run the More... check, so wrapped long lines page
; exactly like explicit newlines.

; A = kind 0-3, E = number. Prints one whole message.
print_msg:
    push af
    push de
    call bank_window_save
    pop de
    pop af
    call msg_seek
    jr c, .badnum
.loop:
    call rd_next
    cpl                         ; decode = 255 - byte
    cp $0A
    jr z, .done
    call prn_decoded
    jr .loop
.done:
    jp bank_window_restore
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
    jp bank_window_restore

; A = decoded character. Dispatches escapes, prints the rest.
prn_decoded:
    bit 7, a
    jr z, .notok
    and $7F
    jp tok_print                ; token chars re-enter via prn_char_vec
.notok:
    cp $0D
    jp z, prn_newline
    cp $0B
    jp z, win_cls
    cp $0C
    jp z, wait_key
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
; Preserves nothing. Safe to call between messages or mid-message:
; it preserves the outer reader position AND the outer MMU save slots
; around the nested SM32 print.
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
    ; preserve outer reader and outer MMU-save slots
    ld a, (rdBank)
    ld (moreSaveBank), a
    ld hl, (rdPtr)
    ld (moreSavePtr), hl
    ld a, (savedMMU6)
    ld (moreSaveMMU), a
    ld a, (savedMMU7)
    ld (moreSaveMMU+1), a
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
    ; restore outer MMU-save slots and reader position
    ld a, (moreSaveMMU)
    ld (savedMMU6), a
    ld a, (moreSaveMMU+1)
    ld (savedMMU7), a
    ld a, (moreSaveBank)
    ld (rdBank), a
    call bank_map_c000
    ld hl, (moreSavePtr)
    ld (rdPtr), hl
    ret

; Token characters route here via prn_char_vec. C = char.
prn_char_tok:
    jp prn_char

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

objname_stub:
    ret

chsGfx:       db 0
moreLock:     db 0
objname_hook: dw objname_stub
moreSaveBank: db 0
moreSavePtr:  dw 0
moreSaveMMU:  dw 0
