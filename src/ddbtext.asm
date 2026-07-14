; DDB text access: pointer rebase, bank-crossing stream reader, token
; expansion. DDB pointers are absolute for the classic $8400 base:
; offset = pointer - $8400, bank = BANK_DDB_FIRST + offset/16K.

; HL = absolute DDB pointer. Maps the bank, sets rdPtr.
; Ends with 'or' - CF clear; msg_seek's success contract relies on this.
rd_seek:
    ld de, DDB_ZX_BASE
    or a
    sbc hl, de                  ; HL = file offset
    ld a, h
    rlca
    rlca
    and 3                       ; offset >> 14
    add a, BANK_DDB_FIRST
    ld (rdBank), a
    call bank_map_c000
    ld a, h
    and $3F
    or high WINDOW_ADDR
    ld h, a                     ; window address
    ld (rdPtr), hl
    ret

; Out: A = next byte. Remaps when the pointer wraps past $FFFF.
; Preserves BC, DE, HL.
rd_next:
    push hl
    ld hl, (rdPtr)
    ld a, (hl)
    inc hl
    ld (rdPtr), hl
    push af
    ld a, h
    or l
    jr nz, .done                ; no wrap
    ld a, (rdBank)
    inc a
    ld (rdBank), a
    call bank_map_c000
    ld hl, WINDOW_ADDR
    ld (rdPtr), hl
.done:
    pop af
    pop hl
    ret

rd_save:
    ld hl, (rdPtr)
    ld (rdSavePtr), hl
    ld a, (rdBank)
    ld (rdSaveBank), a
    ret

rd_restore:
    ld a, (rdSaveBank)
    ld (rdBank), a
    call bank_map_c000
    ld hl, (rdSavePtr)
    ld (rdPtr), hl
    ret

; A = kind 0-3, E = number. CF set if number >= count for that kind.
; Kind k: count byte at ddbHeader+6-k, table pointer at ddbHeader+$12-2k.
msg_seek:
    ld hl, ddbHeader+6
    ld bc, ddbHeader+$12
    or a
    jr z, .check
.adj:
    dec hl
    dec bc
    dec bc
    dec a
    jr nz, .adj
.check:
    ld a, e
    cp (hl)                     ; number < count?
    jr c, .ok
    scf
    ret
.ok:
    ld l, c
    ld h, b                     ; HL -> table pointer field in header
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a                     ; HL = absolute table address
    ld d, 0
    add hl, de
    add hl, de                  ; + number*2 = entry address
    call rd_seek
    call rd_next                ; message pointer, little-endian
    ld l, a
    call rd_next
    ld h, a
    jp rd_seek                  ; leaves the reader at the message text
; A = token 0-127. Skips (A+1) entries from tokensPos (the first entry
; is unused per the DDB format), then emits chars via prn_char_vec
; until the bit-7-terminated last char. Chars are raw 7-bit, NOT
; 255-complemented. Saves/restores the reader around itself.
tok_print:
    push af
    call rd_save
    ld hl, (ddbHeader+8)        ; tokensPos, absolute
    call rd_seek
    pop af
    inc a
    ld b, a                     ; entries to skip
.skip:
    call rd_next
    bit 7, a
    jr z, .skip
    djnz .skip
.emit:
    call rd_next
    push af
    and $7F
    ld c, a
    call prn_vec_call
    pop af
    bit 7, a
    jr z, .emit
    jp rd_restore

prn_vec_call:
    ld hl, (prn_char_vec)
    jp (hl)

rdBank:       db 0
rdPtr:        dw 0
rdSaveBank:   db 0
rdSavePtr:    dw 0
prn_char_vec: dw 0
