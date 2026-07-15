; DDB text access: pointer rebase, bank-crossing stream reader, token
; expansion. DDB pointers are absolute for the classic $8400 base:
; offset = pointer - $8400, 8K page = DDB_PAGE_FIRST + offset/8K.

; HL = absolute DDB pointer. Maps the page, sets rdPtr in slot 6.
; Ends with 'or' - CF clear; msg_seek's success contract relies on this.
rd_seek:
    ld de, DDB_ZX_BASE
    or a
    sbc hl, de                  ; HL = file offset
    ld a, h
    rlca
    rlca
    rlca
    and 7                       ; offset >> 13 (0..7)
    add a, DDB_PAGE_FIRST
    ld (rdPage), a
    call data_map_page
    ld a, h
    and $1F
    or high DATA_WINDOW         ; $C0 | (offset>>8 AND $1F)
    ld h, a
    ld (rdPtr), hl
    ret

; Out: A = next byte. Remaps at the 8K boundary ($DFFF -> next page).
; Preserves BC, DE, HL.
rd_next:
    push hl
    ld hl, (rdPtr)
    ld a, (hl)
    inc hl
    ld (rdPtr), hl
    push af
    ld a, h
    cp high DATA_WINDOW + $20   ; wrapped past $DFFF?
    jr c, .done
    ld a, (rdPage)
    inc a
    ld (rdPage), a
    call data_map_page
    ld hl, DATA_WINDOW
    ld (rdPtr), hl
.done:
    pop af
    pop hl
    ret

; Two-level reader save stack (object-name printing runs inside token
; expansion). Depth overflow is a coding error: fatal, border 2.
rd_push:
    ld a, (rdSaveSP)
    cp 2
    jr nc, rd_stack_fatal
    or a
    jr nz, .slot1
    ld a, (rdPage)
    ld (rdSaveA), a
    ld hl, (rdPtr)
    ld (rdSaveA+1), hl
    jr .done
.slot1:
    ld a, (rdPage)
    ld (rdSaveB), a
    ld hl, (rdPtr)
    ld (rdSaveB+1), hl
.done:
    ld hl, rdSaveSP
    inc (hl)
    ret

rd_pop:
    ld a, (rdSaveSP)
    or a
    jr z, rd_stack_fatal
    dec a
    ld (rdSaveSP), a
    jr nz, .slot1               ; SP was 2 -> restore slot B
    ld a, (rdSaveA)
    ld (rdPage), a
    call data_map_page
    ld hl, (rdSaveA+1)
    ld (rdPtr), hl
    ret
.slot1:
    ld a, (rdSaveB)
    ld (rdPage), a
    call data_map_page
    ld hl, (rdSaveB+1)
    ld (rdPtr), hl
    ret

rd_stack_fatal:
    ld a, 2                     ; red border - reader stack misuse
    ld hl, msgRdStack
    jp fatal

msgRdStack: db "RD STACK", 0

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
    call rd_push
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
    jp rd_pop

prn_vec_call:
    ld hl, (prn_char_vec)
    jp (hl)

rdPage:       db 0
rdPtr:        dw 0
rdSaveSP:     db 0
rdSaveA:      ds 3
rdSaveB:      ds 3
prn_char_vec: dw 0
