; DAAD runtime errors 0-8. Debug: classic diagnostic on row 30.
; Release: border 3, halt. Never returns.
; Codes raised in SP3: 0 (obj_ptr), 2 (obj_move to 255), 3 (PROCESS
; depth), 4 (nested DOALL), 5 (illegal opcode), 6 (bad process),
; 7 (bad message/location number). Codes 1 and 8 are defined for
; parity and first raised by later sub-projects.
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
    ld a, 3                     ; magenta border = runtime error
    out ($FE), a
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
