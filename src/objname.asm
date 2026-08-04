; Object-name printing (_/@ escapes) and the shared list engine.

; A = '_' or '@' (a message substitution) or 0 (plain list output).
; Prints flag-51's OTX; '@' capitalises the first emitted letter.
; '@' only ever reaches here from a SPANISH database - print.asm's
; prn_decoded filters it out for every other language, where '@' is an
; ordinary printable character - so the language test at .emit below is
; now belt-and-braces for this entry point's own contract rather than
; the only gate. Reader bracketed by rd_push/rd_pop, window by
; data_save/data_restore. No referenced object ($FF) prints nothing.
;
; ARTICLE STRIPPING (owner ruling 2026-08-05):
;   LIST OUTPUT (A = 0) strips NOTHING. LISTOBJ/LISTAT/inventory print
;   the object text exactly as authored, articles included. CONFIRMED
;   ON SILICON by the owner against DSNEXTE3.BIN, DAAD Ready's own ZX
;   Next interpreter, which lists "a pair of dungarees" whole. This
;   code used to run ONE state machine for both callers and discard
;   every character up to the first space unconditionally, so it listed
;   "pair of dungarees" - and printed NOTHING AT ALL for a text with no
;   space in it, since the discard only ended when a space arrived.
;   Both references list the text whole - msx2daad's _internal_listat
;   calls printObjectMsg (daad_condacts.c:1941), the printer that does
;   NOT strip (daad_msg.c:88); jDAAD's listObjects passes replace=false
;   (jdaad.js:2396) where its four substitution sites pass true.
;   SUBSTITUTION (A = '_' or '@') strips a leading "a ", "an " or
;   "some " and NOTHING else, case-insensitively (msx2daad uses
;   strnicmp). Any other first word survives: an object text of "rusty
;   sword" substitutes as "rusty sword", not "sword". That is a
;   deliberate departure from jDAAD, which removes the first word
;   whatever it is ("In English, we have to remove the first word,
;   whatever it is", jdaad.js:1588) and so destroys descriptive text;
;   it follows msx2daad's article-only rule (daad_msg.c:127-133, "a "
;   and "an ") extended with "some " per DAAD Ready's manual ("If an
;   object description starts with 'a' or 'some' in English games ...
;   that underscore will be replaced by the object text without the
;   article"). DSNEXTE3.BIN itself cannot be doing article-WORD
;   matching at all: the whole 7976-byte image holds no CP 's'/'S' and
;   no CP 't'/'T', and its only CP 'a'/'A' sites are letter-range
;   classifiers - so it cannot be testing for "some", "the" or even
;   "a"/"an" as words. Its substitution rule is therefore very
;   probably jDAAD's first-word strip, and this is a deliberate
;   divergence from it (authoring-kit/DIVERGENCES.md carries it).
;   LEADING SPACES are not stripped. The article has to be the literal
;   start of the text. msx2daad does the same (strnicmp against the
;   raw buffer); jDAAD alone eats them, and only in the pathological
;   case of an /OTX authored with a leading blank.
;   SPANISH is now UNTOUCHED by this routine: "un"/"una" are not in the
;   set, so a Spanish name substitutes whole (and '@' capitalises it).
;   Both references REPLACE the Spanish article instead of stripping it
;   ("Un palo" -> "El palo", msx2daad daad_msg.c:115-124, jdaad.js
;   1571-1587). NextDAAD does neither yet - reported, awaiting an owner
;   ruling of its own, not implemented here.
; SP16 E3: a SUBSTITUTED name stops at the first "." (jDAAD's
; stopAtDot, msx2daad's Spanish path - both references agree), so an
; object text of "a quaint lamp. It is unlit." substitutes as "quaint
; lamp". List output (A = 0) prints the name whole: the truncation is
; a substitution rule, not a property of the object text.
; SP16 B16 (referenced-object half): objname_print_n is the same
; printer with the object number supplied in B, so the caller does NOT
; have to stage it through flag 51. Both references hand the object
; number straight to their name printer during a listing and never
; touch the referenced object (jdaad.js:2379 listObjects ->
; getMessageOTX(i, ...); daad_condacts.c:1922 _internal_listat ->
; printObjectMsg(lastFound), and msx2daad's referencedObject() is not
; on either path). list_at used to write flag 51 per object and never
; restore it, leaving the referenced object pointing at the last object
; listed after every LISTOBJ/LISTAT.
objname_print_n:                ; A = mode, B = object number
    ld c, a
    ld a, b
    jr objname_chk
objname_print:                  ; A = mode, object number from flag 51
    ld c, a
    ld a, (flags+FLAG_CUROBJ)
objname_chk:
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
    push bc                     ; msg_seek clobbers BC (its own
    call msg_seek               ; ld bc,ddbHeader+$12) and C carries the
    pop bc                      ; mode for BOTH the '@' capitalisation
    jr c, .out                  ; test below and the E3 dot rule - the
                                ; capitalisation was reading a clobbered
                                ; C and could never fire (CF from
                                ; msg_seek survives the pop)
    ld a, (tokActive)
    push af                     ; may run nested inside another stream
    xor a
    ld (tokActive), a
    ld a, c
    or a
    call nz, objname_article    ; substitution only - list output prints
                                ; the text whole, articles included
    ld d, 0                     ; nothing emitted yet: '@' capitalises the
                                ; NEXT character whether or not an article
                                ; was eaten (it used to fire only in the
                                ; just-consumed-an-article state, so an
                                ; article-less name came out uncapitalised)
.loop:
    push bc
    push de
    call txt_next_decoded
    pop de
    pop bc
    jr c, .fin
    cp '.'                      ; SP16 E3
    jr nz, .emit
    ld a, c
    or a
    jr nz, .fin                 ; substitution: the name ends here
    ld a, '.'                   ; list output: the dot is part of the name
.emit:
    ; capitalise first emitted letter for '@' - SPANISH databases only.
    ; Both references gate it on the language: msx2daad consumes the
    ; modifier inside #ifdef LANG_ES (daad_msg.c printObjectMsgModif),
    ; jDAAD honours ESCAPE_OBJNAME_CAPS only when isSpanish()
    ; (jdaad.js:1636 / :550 = bit 0 of header byte 1). An English DDB
    ; renders the name plain on both, so it does here too. This branch
    ; was unreachable by accident until the msg_seek BC bracket above
    ; was added; the language gate is what keeps the newly-live path
    ; reference-correct rather than merely live.
    ld e, a
    ld a, d
    or a
    jr nz, .send                ; not the first emitted character
    ld a, c
    cp '@'
    jr nz, .send
    ld a, (ddbHeader+1)         ; target/machine + language byte
    rrca                        ; bit 0 = Spanish
    jr nc, .send
    ld a, e
    cp 'a'
    jr c, .send
    cp 'z'+1
    jr nc, .send
    sub 32
    ld e, a
.send:
    ld d, 1                     ; something has been emitted
    push bc
    push de
    ld c, e
    call prn_char
    pop de
    pop bc
    jr .loop
.fin:
    call objname_untok          ; the E3 dot can land INSIDE a token
    pop af
    ld (tokActive), a
.out:
    call data_restore
    jp rd_pop

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
; token references across all 13 suite and all 55 Rabenstein object
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
; THE NO-PEEK PROBLEM. Characters arrive from txt_next_decoded, a
; decoding iterator - tokens expand mid-stream and there is no way to
; look ahead and put a character back. Buffering the candidate prefix
; and replaying it verbatim on a miss would need a 4-byte resident
; buffer plus a replay loop that has to re-enter the capitalisation
; path in the right order. Instead the stream is REWOUND: the object
; number is still in B, so a miss simply re-runs the same "msg_seek
; kind 3" this routine's caller used and clears tokActive (the state
; the caller had just set up), putting the reader back byte-for-byte
; at the start of the text. Nothing has been emitted at this point -
; the scan is pure lookahead - so a rewind is invisible and the main
; loop then prints the name whole, in order, in its authored case.
; A token spanning the article boundary is handled by construction:
; the scan sees expanded characters and the rewind restores the
; PRE-token reader position, not a position inside one.
;
; Case folding is RES 5: 'a'-'z' -> 'A'-'Z', and ' ' ($20) -> $00, so a
; zero test IS the space test. Only letters and the separating space
; are ever compared, and decoded characters are 7-bit, so nothing else
; can alias into the set.
objname_article:
    call .nxt
    jr c, .no                   ; empty text
    cp 'A'
    jr z, .an
    cp 'S'
    jr nz, .no
    ld hl, .some
.sloop:
    ld a, (hl)
    inc hl
    inc a
    ret z                       ; sentinel: the whole of "some " is gone
    dec a
    ld e, a
    call .nxt
    jr c, .no
    cp e
    jr z, .sloop
    jr .no
.some:
    db "OME", 0, $FF            ; folded "ome "; $FF ends the pattern
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

; A = location value, C = 0 LISTAT / 1 LISTOBJ.
;
; SP16 B16. The listing FORM is selected by flag 53 (fOFlags) bit 6 on
; both references (jdaad.js:2379 listObjects' continuousListing,
; daad_condacts.c:1922 _internal_listat's contList); NextDAAD forced the
; continuous form and never read the bit.
;   bit 6 set   - continuous: "a, b and c." (SM46 / SM47 / SM48), the
;                 SM1 header running straight into the first name.
;   bit 6 clear - ONE OBJECT PER LINE, which is the DEFAULT (flag 53
;                 starts at 0). jDAAD emits a newline after EVERY name
;                 and no SM48 terminator at all in this form, and gives
;                 the SM1 header its own line; that is what is
;                 reproduced here - the separator slot before each name
;                 after the first becomes a newline, and the tail
;                 emits a newline instead of SM48.
; Bit 7 ("objects were listed") is maintained on BOTH condact paths -
; set when at least one object was listed, cleared when none were.
; NextDAAD's own tail message was already set on both paths but only
; from LISTOBJ, and the LISTAT path never cleared it.
; Empty LISTAT prints SM53 ALONE: jDAAD appends nothing after it and
; msx2daad's SM53 carries its own newline, so NextDAAD's extra
; prn_newline was a third line neither reference produces.
; The terminator stays SM48 for LISTAT as well as LISTOBJ (jDAAD's
; choice; msx2daad uses SM51 there) - reference disagreement recorded
; in docs/daad-compliance-report.md, not this task's to move.
; The referenced object (flag 51) is NOT written - see objname_print_n.
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
    call objscan_tick           ; SP14c gate follow-up: OBJ1 measurement
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
    ld hl, flags+FLAG_OFLAGS    ; hoisted here so both arms can use it;
    or a                        ; LD does not touch F, so the OR still
    jr nz, .some                ; tests the object count in A (doc 02)
    res 7, (hl)                 ; nothing here: clear "listed" on BOTH
    ld a, (lstMode)             ; paths (LISTAT never cleared it)
    or a
    ret nz                      ; LISTOBJ prints nothing at all
    ld e, 53                    ; LISTAT: SM53 alone, no extra newline
    ld a, 0
    jp print_msg
.some:
    set 7, (hl)                 ; objects listed: set "listed" on BOTH
    ld a, (lstMode)             ; paths (LISTAT never set it)
    or a
    jr z, .body
    ld e, 1                     ; "I can also see:" - LISTOBJ only
    ld a, 0
    call print_msg
    ld a, (flags+FLAG_OFLAGS)
    and 64
    call z, prn_newline         ; one-per-line: the header owns its line
.body:
    ld b, 0
    ld d, 0                     ; emitted count
.emit:
    ld a, (numObj)
    cp b
    jr z, .done
    call objscan_tick           ; SP14c gate follow-up: OBJ1 measurement
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
    ld a, (flags+FLAG_OFLAGS)
    and 64
    jr z, .nl                   ; one-per-line: the separator is a
    ld a, (lstTotal)            ; newline before every name but the
    dec a                       ; first, which is jDAAD's "newline
    cp d                        ; after every name" shifted by one
    ld e, 46                    ; ", "
    jr nz, .sep
    ld e, 47                    ; " and "
.sep:
    ld a, 0
    call print_msg
    jr .sepend
.nl:
    call prn_newline
.sepend:
    pop de
    pop bc
.name:
    push bc
    push de
    xor a                       ; list output: no E3 dot truncation.
    call objname_print_n        ; B = object number; flag 51 untouched
    pop de
    pop bc
    inc d
.enext:
    inc b
    jr .emit
.done:
    ld a, (flags+FLAG_OFLAGS)
    and 64
    jp z, prn_newline           ; one-per-line: close the last name's
    ld e, 48                    ; line; jDAAD emits no SM48 in this form
    ld a, 0
    jp print_msg

lstLoc:   db 0
lstMode:  db 0
lstTotal: db 0
