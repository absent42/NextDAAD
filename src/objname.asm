; Object-name printing (_/@ escapes) and the shared list engine.

; A = '_' or '@' (a message substitution) or 0 (plain list output).
; Prints flag-51's OTX with the leading article word stripped; '@'
; capitalises the first emitted letter. Reader bracketed by rd_push/
; rd_pop, window by data_save/data_restore. No referenced object ($FF)
; prints nothing. Tokens are expanded by the iterator, so the article
; state machine sees every real character - a token spanning the
; article boundary is handled correctly.
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
    ld d, 0                     ; 0 in-article, 1 begun, 2 emitting
.loop:
    push bc
    push de
    call txt_next_decoded
    pop de
    pop bc
    jr c, .fin
    cp ' '
    jr nz, .chr
    ld a, d
    or a
    jr nz, .spc                 ; spaces inside the name print
    ld d, 1                     ; article consumed
    jr .loop
.spc:
    ld a, ' '
    jr .emit
.chr:
    cp '.'                      ; SP16 E3
    jr nz, .keep
    ld a, c
    or a
    jr nz, .fin                 ; substitution: the name ends here
    ld a, '.'                   ; list output: the dot is part of the name
.keep:
    ld e, a
    ld a, d
    or a
    jr z, .loop                 ; still in the article word
    ld a, e
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
    cp 1
    jr nz, .send
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
    ld d, 2
    push bc
    push de
    ld a, e
    ld c, a
    call prn_char
    pop de
    pop bc
    jr .loop
.fin:
    pop af
    ld (tokActive), a
.out:
    call data_restore
    jp rd_pop

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
