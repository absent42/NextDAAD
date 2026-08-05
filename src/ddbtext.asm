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

; --------------------------------------------------------------------
; objname_print's two helpers (src/objname.asm is their only caller).
; They live HERE, not there, purely for PLACEMENT: this file is
; included before engine.asm, so it lands BEFORE the "ALIGN 256 /
; flags / ASSERT flags == $A200" anchor and its bytes are absorbed by
; the ALIGN pad instead of coming off the RESIDENT_LIMIT headroom
; objname.asm shares with debug.asm. Every symbol they use -
; txt_next_decoded, msg_seek, rd_pop, tokActive - is in this file
; anyway. THE PAD IS A HARD CEILING, NOT SLACK: overrun it and flags
; moves off $A200 and the ASSERT fires. Every build prints
; "pre-flags pad N bytes free" (engine.asm) - read the DEBUG variant's
; figure, it is always the tightest - before adding anything else
; pre-anchor. This pair is the ballast between the two budgets: move
; it back to objname.asm to hand ~103 bytes back to the pad.
;
; Abandoning a text stream part-way through a token leaves the level
; txt_next_decoded's .tokref pushed on the reader save stack: .intok
; only pops it when the token's last character is read. Whoever stops
; early has to unwind it, or the next rd_pop restores the TOKEN TABLE
; position over the caller's and the stack never comes back to depth.
; At most one level can be pending - token bytes are raw 7-bit and
; cannot themselves reference a token, so .tokref never nests. Two
; callers stop early: the article scan's rewind, and the SP16 E3 dot
; truncation, which has been able to leak since E3 landed. DRC/DRB as
; measured 2026-08-05 does NOT tokenise the /OTX table at all (zero
; token references across all 14 suite and all 55 Rabenstein object
; texts, while their system messages are heavily tokenised), so no
; fixture here reaches this - but the DDB format allows it, other
; toolchains use it, and correctness must not rest on one compiler's
; choice of what to compress.
objname_untok:
    ld a, (tokActive)
    or a
    ret z
    jp rd_pop

; Eat a leading English article from the object-text stream. Entered
; only for a SUBSTITUTED name (C = '_' or '@'); B = the object number,
; which is what makes the rewind below possible. Preserves BC.
;
; THE SET IS "a", "an", "some", "the" (owner ruling 2026-08-05, on a
; measured survey of 323 object texts across 9 corpus games: 231
; a/an, 27 the - 19 of them in tests\parser\work\survey\MYST_EN, 8 in
; Rabenstein - 15 some, 50 none of the above). "the" earns its place
; on that count alone.
; WHAT THIS DELIBERATELY DOES NOT FIX, so nobody re-opens it: MYST_EN
; also carries "my wallet", "my notebook", "my coat" and "two D
; batteries", i.e. it was authored against jDAAD's strip-the-first-
; word-whatever-it-is rule, and four of its objects still read "You
; now have the my wallet." Accepted. The alternative is first-word
; strip, and that mutilates Golden Seas' 34 "'Alapetia'; a wig maker"
; texts by deleting the character's own name - a worse failure on more
; objects. Article-only is the lesser evil, not a complete answer.
;
; THE NO-PEEK PROBLEM. Characters arrive from txt_next_decoded, a
; decoding iterator - tokens expand mid-stream and there is no way to
; look ahead and put a character back. Buffering the candidate prefix
; and replaying it verbatim on a miss would need a resident buffer
; plus a replay loop that has to re-enter the capitalisation path in
; the right order. Instead the stream is REWOUND: the object number is
; still in B, so a miss simply re-runs the same "msg_seek kind 3" this
; routine's caller used and clears tokActive (the state the caller had
; just set up), putting the reader back byte-for-byte at the start of
; the text. Nothing has been emitted at this point - the scan is pure
; lookahead - so a rewind is invisible and the main loop then prints
; the name whole, in order, in its authored case.
; A token spanning the article boundary is handled by construction:
; the scan sees expanded characters and the rewind restores the
; PRE-token reader position, not a position inside one.
;
; Case folding is RES 5: 'a'-'z' -> 'A'-'Z', and ' ' ($20) -> $00, so a
; zero test IS the space test. Only letters and the separating space
; are ever compared, and decoded characters are 7-bit, so nothing else
; can alias into the set.
; "some" and "the" share ONE pattern walker - they differ only in the
; table HL is loaded with - so the deep-divergence case (a word that
; matches the article for its whole length and then does not end,
; "somersault" / "theatre") is the same code on both arms and the
; suite only has to exercise it once.
objname_article:
    call .nxt
    jr c, .no                   ; empty text
    cp 'A'
    jr z, .an
    ld hl, .some
    cp 'S'
    jr z, .sloop
    ld hl, .the
    cp 'T'
    jr nz, .no
.sloop:
    ld a, (hl)
    inc hl
    inc a
    ret z                       ; sentinel: the whole article is gone
    dec a
    ld e, a
    call .nxt
    jr c, .no
    cp e
    jr z, .sloop
    jr .no
.some:
    db "OME", 0, $FF            ; folded "ome "; $FF ends the pattern
.the:
    db "HE", 0, $FF             ; folded "he "
.an:
    call .nxt
    jr c, .no
    or a
    ret z                       ; "a " consumed
    cp 'N'
    jr nz, .no
    call .nxt
    jr c, .no
    or a
    ret z                       ; "an " consumed
.no:                            ; not an article - put the stream back
    call objname_untok          ; the scan can stop INSIDE a token
    xor a
    ld (tokActive), a           ; the rewind point is a fresh stream
    ld e, b
    ld a, 3
    push bc                     ; msg_seek clobbers BC (ld bc,ddbHeader+$12)
    call msg_seek
    pop bc
    ret
.nxt:
    push bc
    push de
    push hl                     ; .sloop walks the pattern in HL and the
    call txt_next_decoded       ; iterator's TOKEN path clobbers it
    pop hl                      ; (ld hl,(ddbHeader+HDR_TOKENS), rd_pop).
    pop de                      ; DRB happens not to tokenise /OTX, but
    pop bc                      ; the format allows it - see objname_untok
    ret c                       ; CF = end of text (POP leaves flags alone)
    res 5, a
    ret

rdPage:       db 0
rdPtr:        dw 0
rdSaveSP:     db 0
rdSave:       ds 12             ; 4 levels x (page, ptr lo, ptr hi)
tokActive:    db 0              ; txt_next_decoded: inside a token
