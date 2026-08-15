; DDB text access: bank-crossing stream reader, token expansion.
; A NextDAAD database's pointers are plain file offsets (base 0), so
; there is no rebase: 8K page = DDB_PAGE_FIRST + offset/8K. Classic
; $8400-based databases are refused at load (file.asm), which is what
; lets this be pure page arithmetic.

; HL = absolute DDB pointer. Maps the page, sets rdPtr in slot 6.
; Ends with 'or' - CF clear; msg_seek's success contract relies on this.
rd_seek:
    ld a, h                     ; HL IS the file offset - NextDAAD
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

; Point the stream reader at arbitrary banked memory: A = 8K page,
; HL = offset within the page (0-$1FFF). rd_next's page-crossing
; walks into page A+1, so a source spanning both halves of one 16K
; bank reads seamlessly. Used by ext_xmes (XMB text in the XMES
; bank); everything downstream (txt_next_decoded, tokens, the
; XOR-$FF decode, the $0A terminator) behaves exactly as for DDB
; text - the XMB encoding is identical by construction.
rd_seek_page:
    ld (rdPage), a
    call data_map_page
    ld a, h
    and $1F
    or high DATA_WINDOW         ; $C0 | (offset>>8 AND $1F)
    ld h, a
    ld (rdPtr), hl
    ret

; Out: A = next byte. Remaps at the 8K boundary ($DFFF -> next page).
; Preserves BC, DE, HL. Corrupts F.
; SP14c DDB2 (landed after the 34-site cross-batch liveness audit,
; batch-C findings): the per-call push af/pop af bracket is gone from
; the hot path. The wrap test is bit 5,h - rdPtr lives in $C000-$DFFF
; (H = $C0-$DF, bit 5 clear) and the only out-of-window value inc hl
; can produce is exactly $E000 (bit 5 set) - so the byte simply stays
; in A on the hot path (-29T/call; rd_next is plausibly the hottest
; CALL in the interpreter - every text/token byte and every condact
; argument fetch routes through it). The rare page-crossing branch
; (once per 8K of stream) still brackets AF around its housekeeping.
rd_next:
    push hl
    ld hl, (rdPtr)
    ld a, (hl)
    inc hl
    ld (rdPtr), hl
    bit 5, h                    ; wrapped past $DFFF? (H == $E0)
    jr nz, .wrap
    pop hl
    ret
.wrap:
    push af
    ld a, (rdPage)
    inc a
    ld (rdPage), a
    call data_map_page
    ld hl, DATA_WINDOW
    ld (rdPtr), hl
    pop af
    pop hl
    ret

; Four-level reader save stack (worst case: message token -> objname ->
; name token -> More... fires -> tokenized SM32). Depth overflow is a
; coding error: fatal, border 2. Preserves DE.
rd_push:
    ld a, (rdSaveSP)
    cp 4
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

; Preserves DE. Corrupts HL, A.
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

; A = level 0-3 -> HL = rdSave + A*3. Preserves DE.
; SP14c batch B DDB1: Z80N MUL D,E replaces the three ADD HL,DE
; (byte-neutral, -14T per call - rd_push/rd_pop fire at every
; token/message nesting transition).
rd_slot:
    push de
    ld d, 3
    ld e, a
    mul d, e
    ld hl, rdSave
    add hl, de
    pop de
    ret

rd_stack_fatal:
    ld a, 2                     ; red border - reader stack misuse
    ld hl, msgRdStack            ; string lives in overlay0 now, mapped
    jp fatal                     ; by fatal_puts (this file is pre-flags
                                 ; resident: no room to grow a message
                                 ; here - see fatal())

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
; first call on a freshly-seeked stream. Preserves BC - AND NOTHING
; ELSE: the token paths CORRUPT HL (.tokref loads the token-table
; address and rd_seeks it; rd_pop corrupts HL by its own contract).
; A caller holding a pointer across this call must bracket it in
; push/pop itself - svc_getmsg (main.asm) shipped without that
; bracket and every post-token store landed in the mapped DDB page,
; overwriting the token table (the svc-getmsg corruption defect,
; 2026-08-15).
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
    jr nz, .tokref
    or a                        ; cp left CF set for chars $00-$09
    ret                         ; plain char, CF now clear
.tokref:
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

; objname_print's two helpers (src/objname.asm is their only caller)
; moved back to objname.asm (SP18 item 7 T4): T4's cardBusy bracket
; (file.asm) needed pre-anchor pad the ballast was occupying - see the
; locator comment at objname.asm for the mechanics and the reversal
; note. Every symbol they used here - txt_next_decoded, msg_seek,
; rd_pop, tokActive - stays resident in this file and remains directly
; callable from objname.asm's post-anchor position.

rdPage:       db 0
rdPtr:        dw 0
rdSaveSP:     db 0
rdSave:       ds 12             ; 4 levels x (page, ptr lo, ptr hi)
tokActive:    db 0              ; txt_next_decoded: inside a token
