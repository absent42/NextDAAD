; DAAD runtime errors 0-8. Debug: classic diagnostic on row 30.
; Both build types paint a magenta bar across tilemap row 0 - the
; classic border is INVISIBLE behind the full-coverage 640x256
; tilemap, so the border write alone signals nothing once the
; engine display is active (owner-discovered). The border write is
; kept for completeness. Never returns.
; Codes raised in SP3: 0 (obj_ptr), 2 (obj_move to 255), 3 (PROCESS
; depth), 4 (nested DOALL), 5 (illegal opcode), 6 (bad process),
; 7 (bad message/location number). Codes 1 and 8 are defined for
; parity and first raised by later sub-projects.
; Bar: tm_fill_rect row 0, full width, space glyph, pair 55
; (paper 3 magenta, ink 7 white) = attr 110 via tmAttr - classic ULA
; puts magenta at index 3 and white at index 7.
err_raise:
    ld (errCode), a
 IFDEF DEBUG
    ld b, 30
    ld c, 0
    call dbg_at
    ld hl, msgErr
    call dbg_puts
    ld a, (errCode)
    call dbg_hex8
    ld hl, msgErrP
    call dbg_puts
    ld a, (procSP)
    or a
    jr z, .nop
    dec a
    call eng_rec_ptr_a
    ld a, (hl)
.nop:
    call dbg_hex8
    ld hl, msgErrV
    call dbg_puts
    ld a, (flags+FLAG_VERB)
    call dbg_hex8
    ld hl, msgErrN
    call dbg_puts
    ld a, (flags+FLAG_NOUN1)
    call dbg_hex8
    ld hl, msgErrC
    call dbg_puts
    ld a, (curCondact)
    call dbg_hex8
 ENDIF
    ld a, 110                   ; pair 55: magenta paper (3), white ink (7)
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, 1
    ld e, TM_COLS               ; magenta bar across row 0
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ld a, 3                     ; border too (invisible under the
    out ($FE), a                ; tilemap, correct elsewhere)
    di
.halt:
    jr .halt

errCode: db 0
 IFDEF DEBUG
msgErr:  db "E", 0
msgErrP: db " P", 0
msgErrV: db " V", 0
msgErrN: db " N", 0
msgErrC: db " C", 0
 ENDIF
