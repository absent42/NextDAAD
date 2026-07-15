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

; Three-level reader save stack (worst case: object name inside token
; expansion when More... fires and SM32 itself starts with a token).
; Depth overflow is a coding error: fatal, border 2.
rd_push:
    ld a, (rdSaveSP)
    cp 3
    jr nc, rd_stack_fatal
    call rd_slot                ; HL -> slot for level A
    ld a, (rdPage)
    ld (hl), a
    inc hl
    ld a, (rdPtr)
    ld (hl), a
    inc hl
    ld a, (rdPtr+1)
    ld (hl), a
    ld hl, rdSaveSP
    inc (hl)
    ret

rd_pop:
    ld a, (rdSaveSP)
    or a
    jr z, rd_stack_fatal
    dec a
    ld (rdSaveSP), a
    call rd_slot
    ld a, (hl)
    ld (rdPage), a
    call data_map_page
    inc hl
    ld a, (hl)
    ld (rdPtr), a
    inc hl
    ld a, (hl)
    ld (rdPtr+1), a
    ret

; A = level 0-2 -> HL = rdSave + A*3. Corrupts DE.
rd_slot:
    ld hl, rdSave
    ld e, a
    ld d, 0
    add hl, de
    add hl, de
    add hl, de
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

; A = next decoded character from the current reader stream, expanding
; token references inline. CF set = end of message (decoded $0A).
; Message bytes are 255-complemented; token bytes are raw 7-bit with
; bit 7 terminating the token. Callers must zero tokActive before the
; first call on a freshly-seeked stream. Preserves BC.
txt_next_decoded:
    ld a, (tokActive)
    or a
    jr nz, .intok
.msg:
    call rd_next
    cpl                         ; decode = 255 - byte
    cp $0A
    jr z, .end
    bit 7, a
    ret z                       ; plain char, CF already clear
    ; token reference: skip (index+1) entries, first entry is unused
    and $7F
    push bc
    push af
    call rd_push
    ld hl, (ddbHeader+HDR_TOKENS)
    call rd_seek
    pop af
    inc a
    ld b, a
.skip:
    call rd_next
    bit 7, a
    jr z, .skip
    djnz .skip
    pop bc
    ld a, 1
    ld (tokActive), a
.intok:
    call rd_next
    bit 7, a
    jr z, .have
    push af                     ; final token char: leave token mode
    xor a
    ld (tokActive), a
    push bc
    call rd_pop
    pop bc
    pop af
.have:
    and $7F
    or a                        ; CF clear
    ret
.end:
    scf
    ret

rdPage:       db 0
rdPtr:        dw 0
rdSaveSP:     db 0
rdSave:       ds 9              ; 3 levels x (page, ptr lo, ptr hi)
tokActive:    db 0              ; txt_next_decoded: inside a token
