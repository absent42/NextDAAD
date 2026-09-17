; The DAAD process engine. All bytecode positions are absolute DDB
; pointers; every fetch re-seeks slot 6, so handlers may print or
; reposition the reader freely.

; Clear flags, set defaults, build the object table from the DDB,
; count initially-carried objects, select window 0.
eng_init_game:
    ld hl, flags
    ld de, flags+1
    ld bc, 255
    ld (hl), 0
    ldir
    ; Flags 37 (max carried) and 52 (strength) stay zero: neither
    ; reference pre-inits them (msx2daad daad_init.c:110-118; jdaad.js:
    ; 575-581); both set them only in do_ABILITY (daad_condacts.c:
    ; 1597-8). Games set their own via LET or ABILITY. Suite check 04.
    ; Flag 29 fGFlags (HASAT GMODE=bit 7, HASAT MOUSE=bit 0) was never
    ; written, so period games saw text-only. Value reflects this
    ; interpreter's own capabilities (Layer 2 graphics, MOUSE condact
    ; 66), not jDAAD; other bits are unimplemented drawstring-machine
    ; options, so stay clear.
    ld a, %10000001              ; = 129
    ld (flags+FLAG_GFLAGS), a
    ; Flag 62 fScMode (screen-mode byte) was never written. msx2daad's
    ; convention (daad_platform_msx2.c gfxSetScreenModeFlags) is
    ; "16|SCREEN": bit 4 = native mode, bit 7 = palette switching
    ; (both true here); mode 0 mirrors l2Mode's own encoding for
    ; Layer 2 256x192 256-colour, the boot default (overlay2.asm
    ; l2_mode_set). Static - not re-published on a Layer 2 mode switch.
    ld a, %10010000              ; = 144
    ld (flags+FLAG_SCMODE), a
    ld a, (ddbHeader+HDR_NUMOBJ)
    ld (numObj), a
    ld c, 0
    call eng_load_objects
    xor a
    call win_select
    xor a
    ld (procSP), a
    call gfx_drawtarget_clear    ; A still 0 here; GFX 87/4 buffer mode
                                  ; is transient - never survives a game
                                  ; (re)start (3-byte CALL vs 9 bytes of
                                  ; inline stores). The layer order is
                                  ; game-owned and deliberately NOT
                                  ; cleared here - the fall-through into
                                  ; gfx_layer_apply (main.asm) only
                                  ; re-asserts the game's current order
    ld a, $FF
    ld (doallObj), a
    ld a, r
    ld l, a
    ld a, (frameCounter)
    ld h, a
    ld a, h
    or l
    jr nz, .seedok
    ld hl, $A5C3
.seedok:
    ld (rngState), hl
    ret

; Populate objTable: locations from objLocLst, attribs from objAttrPos,
; extAttr from objExtrPos, noun/adj from objNamePos. Also counts
; CARRIED into flag 1. Reused by RESET (locations pass only when C=1).
; In: C = 0 full build, C = 1 locations only.
eng_load_objects:
    call data_save
    xor a
    ld (flags+FLAG_CARRIED_CT), a
    call obj_fill_null          ; undeclared slots first, real ones over
    ld a, (numObj)              ; the top - the references' own order
    or a
    jp z, .doneall
    ld b, a                     ; object counter
    ld ix, objTable
    ld hl, (ddbHeader+HDR_OBJLOC)
    call rd_seek
.locs:
    call rd_next
    ld (ix+0), a
    cp OBJ_CARRIED
    jr nz, .notc
    ld a, (flags+FLAG_CARRIED_CT)
    inc a
    ld (flags+FLAG_CARRIED_CT), a
.notc:
    ld de, OBJ_SIZE
    add ix, de
    djnz .locs
    ld a, c
    or a
    jr nz, .doneall             ; RESET: locations only
    ; attribs
    ld a, (numObj)
    ld b, a
    ld ix, objTable
    ld hl, (ddbHeader+HDR_OBJATTR)
    call rd_seek
.attrs:
    call rd_next
    ld (ix+1), a
    ld de, OBJ_SIZE
    add ix, de
    djnz .attrs
    ; Extended attributes (2 bytes/obj): the DDB stores the 16 user
    ; attribute bits as one little-endian word (drb.php
    ; generateObjectExtraAttr -> writeWord); HASAT n = flags[59-(n>>3)]
    ; so attrs 0-7 -> flag 59 (word's low byte, first in file), 8-15
    ; -> flag 58. Confirmed both references (jdaad.js:739-740,
    ; daad_init.c:168-169 + daad_objects.c:56-57).
    ; objTable holds the pair high-attribute-byte first: +2 = attrs
    ; 8-15 -> flag 58/39, +3 = attrs 0-7 -> flag 59/40. Only place the
    ; file's order is interpreted; obj_set_refs (overlay0.asm) and
    ; obj2_resolve (overlay1.asm) depend on this order - fix both if
    ; it ever changes.
    ld a, (numObj)
    ld b, a
    ld ix, objTable
    ld hl, (ddbHeader+HDR_OBJEXTR)
    call rd_seek
.extr:
    call rd_next
    ld (ix+3), a                ; first file byte = LE low = attrs 0-7
    call rd_next
    ld (ix+2), a                ; second file byte = attrs 8-15
    ld de, OBJ_SIZE
    add ix, de
    djnz .extr
    ; noun + adjective ids
    ld a, (numObj)
    ld b, a
    ld ix, objTable
    ld hl, (ddbHeader+HDR_OBJNAME)
    call rd_seek
.names:
    call rd_next
    ld (ix+4), a
    call rd_next
    ld (ix+5), a
    ld de, OBJ_SIZE
    add ix, de
    djnz .names
.doneall:
    jp data_restore

; A = object number -> HL = objTable entry. All 256 numbers are legal:
; objTable has a slot for each and eng_load_objects pre-fills the ones
; the DDB does not declare, as both references do (jdaad.js:719-725,
; PCDAAD objects.pas:149). Object 255 is NULLWORD and reaches here
; whenever WHATO missed. Corrupts AF, DE. Preserves BC.
obj_ptr:
    push bc
    ld c, a
    ld d, 6                      ; SP14c E4: DE = 6*c (OBJ_SIZE) via
    ld e, c                      ; Z80N MUL (was shift-add *2/*4/+de)
    mul d, e
    ld hl, objTable
    add hl, de
    ld a, c
    pop bc
    ret

; Push process A and run the game loop forever (eng_step restarts
; PRO 0 whenever the process stack fully unwinds - see its stack-empty
; case). PARSE blocks synchronously inside inp_edit, so this busy loop
; only advances once real input (or a timeout) is available.
eng_run:
    xor a                       ; PRO 0; eng_push_proc reads no flags
    call eng_push_proc
.loop:
    call eng_step
    jr .loop

; Push process table A onto the stack. Error 6 if A >= numPrc,
; error 3 if depth exceeded.
eng_push_proc:
    ld c, a
    ld a, (ddbHeader+HDR_NUMPRC)
    dec a
    cp c
    jr nc, .prcok
    ld a, 6
    jp err_raise
.prcok:
    ld a, (procSP)
    cp PROC_DEPTH
    jr c, .depthok
    ld a, 3
    jp err_raise
.depthok:
    call eng_rec_ptr            ; HL -> new record (procSP, not yet inc)
    ld (hl), c                  ; proc number
    push hl
    ld hl, (ddbHeader+HDR_PROCLST)
    ld a, c
    add a, a                    ; c*2, 8-bit exactly as before
    add hl, a                   ; entry in the process list
    call data_save
    call rd_seek
    call rd_next
    ld e, a
    call rd_next
    ld d, a                     ; DE = absolute table address
    call data_restore
    pop hl
    inc hl
    ld (hl), e                  ; entryPtr
    inc hl
    ld (hl), d
    inc hl
    ld (hl), 0                  ; condactPtr = 0 -> "at entry header"
    inc hl
    ld (hl), 0
    xor a                       ; entering a table clears the done state:
    ld (isDone), a              ; msx2daad pushPROC "isDone = false",
                                ; jDAAD _PROCESS "done = false"
    ld hl, procSP
    inc (hl)
    ret

; HL -> stack record for level (procSP). Corrupts AF, DE.
eng_rec_ptr:
    ld a, (procSP)
eng_rec_ptr_a:                  ; entry with A = level
    ld e, a                      ; SP14c E5: DE = 5*level (PREC_SIZE) via
    ld d, PREC_SIZE              ; Z80N MUL (was shift-add *2/*4/+de)
    mul d, e
    ld hl, procStack
    add hl, de
    ret

; One engine step: advance the TOP process. Matching, fetching and
; dispatching happen here; this is the hot loop.
eng_step:
    ld a, (procSP)
    or a
    jr nz, .have
    ; stack empty: Process 0 completed - restart it (game never ends)
    xor a
    jp eng_push_proc
.have:
    dec a
    call eng_rec_ptr_a          ; HL -> top record
    push hl
    pop ix                      ; IX -> record
    ld l, (ix+3)
    ld h, (ix+4)                ; condactPtr
    ld a, h
    or l
    jp nz, eng_exec             ; mid-entry: execute next condact
    ; at an entry header: match it
    ld l, (ix+1)
    ld h, (ix+2)                ; entryPtr
    call data_save
    call rd_seek
    call rd_next                ; verb byte
    or a
    jr z, .tblend
    ld b, a
    call rd_next                ; noun byte
    ld c, a
    call rd_next
    ld e, a
    call rd_next
    ld d, a                     ; DE = condact table offset (absolute)
    call data_restore
    ; verb match: 255 or == flag 33
    ld a, b
    cp 255
    jr z, .vok
    ld hl, flags+FLAG_VERB
    cp (hl)
    jr nz, .skip
.vok:
    ld a, c
    cp 255
    jr z, .nok
    ld hl, flags+FLAG_NOUN1
    cp (hl)
    jr nz, .skip
.nok:
    ld (ix+3), e                ; enter the entry
    ld (ix+4), d
    ret
.skip:
    jp eng_next_entry
.tblend:
    call data_restore
    jp eng_pop_proc

; Advance IX record's entryPtr by 4 (one header).
eng_next_entry:
    ld l, (ix+1)
    ld h, (ix+2)
    ld de, 4
    add hl, de
    ld (ix+1), l
    ld (ix+2), h
    xor a
    ld (ix+3), a
    ld (ix+4), a
    ret

; Pop the top process. isDone is deliberately left ALONE here, so the
; caller reads whatever the sub-process accumulated - that is what makes
; PROCESS n / ISDONE report the sub-process's result and nothing else.
; Both references get this from isDone being one global that only the
; push clears (msx2daad _popPROC and jDAAD's stackPop touch neither).
eng_pop_proc:
    ld a, (doallLevel)
    ld b, a
    ld a, (procSP)
    cp b
    jr nz, eng_pop_tail
    ld a, (doallObj)
    inc a
    jp nz, eng_doall_next       ; DOALL live on this level: iterate
; Shared tail (SP14c E1): both plain-pop paths (normal pop and DOALL-
; exhausted pop) reach this one body, the second via a tail JP. It used
; to be 36 bytes of done-flag propagation; the single isDone cell left
; nothing here but the stack pointer.
eng_pop_tail:
    ld hl, procSP               ; stack empty is fine: eng_step restarts
    dec (hl)                    ; PRO 0, and that push clears isDone
    ret

; Execute the condact at IX's condactPtr (HL already = that pointer
; when entered from eng_step via eng_exec).
eng_exec:
    call data_save
    call rd_seek
.fetch:
    call rd_next                ; opcode byte
    ld (curOpcode), a
    cp $FF                      ; $FF = entry terminator (DRC emits it
    jp z, .endentry             ; on every fall-through entry); CP keeps
                                 ; A intact so the reload below (SP14c E2)
                                 ; is unneeded
    ; DRC's debug marker. Compiling with DRB's -D flag emits
    ; FAKE_DEBUG_CONDACT_CODE = 220 = $DC verbatim into the process
    ; tables (drb.php:18 + 1114/1145), a ZEsarUX breakpoint marker with
    ; ZERO parameters - the opcode byte and nothing else (proved: three
    ; DEBUG lines cost exactly three DDB bytes, tests\build-tests.ps1).
    ; It has to be caught HERE, before the mask below, because $DC & $7F
    ; is 92 = NEWTEXT: every marker would otherwise discard the player's
    ; pending compound order AND stamp the table done (cprops row 92 is
    ; an Action, and the stamp happens BEFORE dispatch, so no handler
    ; could decline it), silently, mid-entry. $DC is unambiguous:
    ; the mask's other reading is NEWTEXT with the indirection bit, and
    ; DRB only sets that bit on a condact with parameters (drb.php:1130)
    ; while NEWTEXT has none, so real NEWTEXT is always plain $5C.
    ; Skipping by re-fetching (rd_next has already stepped over the
    ; marker, and it re-pages itself) is what makes it genuinely
    ; invisible: no print, no done stamp, no flow change, and a live
    ; one-shot INDIR override still lands on the condact that follows.
    cp $DC
    jr z, .fetch
    and $7F
    ld (curCondact), a
    ; SP16 T6: 120/122/124 used to raise E5 here. They are now real
    ; rows in cprops/cdisp (XMES, INDIR, SETAT) and the V2 raise moved
    ; into h_v3only, which each of the three handlers jumps to when
    ; ddbVer is not 3 - the E5 is KEPT for a version 2 database, just
    ; raised one dispatch later, and 15 bytes of resident walker go
    ; away with it. A V2 database never contains these opcodes anyway
    ; (DRF rejects the syntax that produces them outside -v3).
    ; properties
    ld hl, cprops
    add hl, a                   ; Z80N, A = condact 0-127
    ld a, (hl)
    ld (curProps), a
    and 3                       ; argc
    ld b, 0
    ld c, 0
    jr z, .noargs
    push af
    call rd_next
    ld b, a                     ; arg1 raw
    pop af
    cp 2
    jr c, .noargs
    call rd_next
    ld c, a                     ; arg2
.noargs:
    ; SP16 A2 - V3 INDIR (122) one-shot second-parameter override.
    ; h_indir leaves flags[flagno] in indirArg2 with indirValid set;
    ; the very NEXT dispatch spends it on arg2 and clears it. DRB emits
    ; INDIR immediately before its target and never anywhere else
    ; (drb.php:1136-1143), re-dumped from a fresh -v3 compile
    ; 2026-07-31: LET 100 @101 is 7A 65 33 64 65 = INDIR 101 / LET 100
    ; 101, the placeholder byte being the flag number itself.
    ; The references patch that byte in the database image; NextDAAD
    ; reads its bytecode through a banked window, so the override lives
    ; here instead - byte-equivalent, because the opcode's own $80
    ; indirection bit reaches arg1 ONLY. Both mechanisms can be live at
    ; once and DRC does emit that shape: LET @100 @101 compiles to
    ; 7A 65 B3 64 65 (INDIR 101 / LET+$80 100 101), which means
    ; flags[flags[100]] = flags[101] under either implementation.
    ; Clearing unconditionally is what makes it one-shot; the only
    ; dispatch path that skips this point is the $FF terminator, which
    ; DRB never emits between an INDIR and its target.
    ld hl, indirValid
    ld a, (hl)
    ld (hl), 0
    or a
    jr z, .noindir
    dec hl                      ; indirArg2 sits one below indirValid
    ld c, (hl)
.noindir:
    ; XMESSAGE stream discipline: current DRC compiles XMESSAGE to a
    ; 3-parameter EXTERN (offset_lsb, 3, offset_msb) - the only
    ; 3-param shape it emits. Consume the third byte here, in the
    ; walker, so the stream survives whether or not the vector-3
    ; handler runs (engine invariant, not a handler courtesy).
    ld a, (curCondact)
    cp 61
    jr nz, .no3rd
    ld a, c
    cp 3
    jr nz, .no3rd
    push bc
    call rd_next
    ld (extArg3), a             ; offset MSB for ext_xmes
    pop bc
.no3rd:
    ; store advanced pointer back into the record
    call eng_ptr_abs            ; HL = absolute from rdPage/rdPtr
    ld (ix+3), l
    ld (ix+4), h
    call data_restore
    ; indirection: bit 7 of the opcode -> arg1 = flags[arg1]
    ld a, (curOpcode)
    bit 7, a
    jr z, .direct
    push hl
    ld h, high flags            ; flags is 256-aligned (see data block)
    ld l, b
    ld b, (hl)
    pop hl
.direct:
    ; Actions mark done BEFORE dispatch, because DONE/NOTDONE and the
    ; caso-A DOALL arm write the final value themselves and must not be
    ; overwritten afterwards. bit 6 = "action that does NOT mark done":
    ; SKIP and REDO are action-typed only so that the dispatcher ignores
    ; their CF, and neither reference counts them as an Action for
    ; ISDONE (msx2daad condactList flags 0, jDAAD _SKIP/_REDO set no
    ; done). So the stamp fires on bit 7 set AND bit 6 clear.
    ; eng_set_done preserves BC/DE/HL/IX, so the argument bytes and the
    ; record pointer survive it.
    ld a, (curProps)
    and $C0
    cp $80
    call z, eng_set_done
    ; dispatch
    ld a, (curCondact)
    ld e, a
    ld d, 3                     ; SP14c E3: DE = 3*curCondact via Z80N MUL
    mul d, e                    ; (was 3x add hl,de; doc 07(b) idiom)
    ld hl, cdisp
    add hl, de                  ; *3
    ld a, (hl)                  ; page
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    call ovl_map_page
    ex de, hl
    call jphl                   ; call handler: B=arg1, C=arg2
    ; post: only conditions consult CF
    ld a, (curProps)
    bit 7, a
    ret nz                      ; action: its done state is already set
    ret nc                      ; condition passed: continue entry
    call eng_top_ix             ; condition failed: next entry
    jp eng_next_entry
.endentry:
    call data_restore           ; entry fell through its terminator:
    jp eng_next_entry           ; carry on with the next entry

; Resident CALL-able jp (hl): eng_exec, the sprite and SFX page calls
; and the ISR hook (main.asm) share this one copy. It sits after the
; routine because a global label ends the local scope above it.
jphl:
    jp (hl)

; Rebuild an absolute DDB pointer from rdPage/rdPtr.
; offset = (page-DDB_PAGE_FIRST)*$2000 + (rdPtr - DATA_WINDOW)
eng_ptr_abs:
    ld a, (rdPage)
    sub DDB_PAGE_FIRST           ; a = page index, PROVABLY 0..7 (rd_seek
                                 ; masks offset>>13 with AND 7, ddbtext.asm)
    ; a*$2000 as the high byte of a 16-bit word (low byte 0): $2000/
    ; $100 = $20 = 1<<5, exact for the full provable range a=0..7.
    ; Flat 5x ADD A,A is constant-time (124T) for every a, faster than
    ; a data-dependent loop for every a>=1.
    add a, a                    ; T=4 B=1
    add a, a                    ; T=4 B=1
    add a, a                    ; T=4 B=1
    add a, a                    ; T=4 B=1
    add a, a                    ; T=4 B=1  a << 5
    ld d, a
    ld e, 0                     ; DE = a*$2000
    ld hl, (rdPtr)
    ld a, h
    sub high DATA_WINDOW        ; H -= $C0
    ld h, a
    add hl, de                  ; = the file offset, which IS the
    ret                         ; pointer for a NextDAAD database

; V3 INDIR's one-shot arg2 override. Placed HERE, before this file's
; ALIGN 256/flags boundary, to use pre-anchor slack rather than the
; scarce post-flags RESIDENT_LIMIT budget. eng_exec reaches indirArg2
; with DEC HL from indirValid, so the ORDER of these two bytes is
; load-bearing.
indirArg2:  db 0
indirValid: db 0

; IX -> top stack record. Corrupts AF, DE, HL.
eng_top_ix:
    ld a, (procSP)
    dec a
    call eng_rec_ptr_a
    push hl
    pop ix
    ret

; Mark the current table done. Also called directly by the handlers
; that are condition-typed for their CF but still have to mark done:
; QUIT, MOVE, PICTURE, SYNONYM under V2, PARSE, SAVE, LOAD. MOVE and
; PICTURE stamp UNCONDITIONALLY at handler entry (both references mark
; them on every path) and are the only two called from an overlay other
; than 0/1 - PICTURE's call comes from overlay2, which is legal because
; this routine is resident. Corrupts A only - BC/DE/HL/IX all survive,
; which is what lets eng_exec stamp between fetching the arguments and
; dispatching.
eng_set_done:
    ld a, 1
    ld (isDone), a
    ret

; DONE/NOTDONE support: force table end for the top process.
; In: A = 1 done, 0 notdone (overwrites isDone).
eng_exit_table:
    ld (isDone), a
    jp eng_pop_proc

; --- DAAD V3 flag 53 (SP16 T6) ---
; Flag 53's V3 bits are written from THREE places in two different
; overlays plus the resident DOALL walker, so the read-modify-write and
; the version gate live here once, in the always-mapped resident, and
; every caller is a LD DE/CALL pair. Keeping it resident is also what
; lets overlay1's parser afford the feature at all - overlay1 had 40
; bytes of DEBUG headroom when this landed.
;
;   eng_v3unrec  parser skipped an unrecognised word: set bit 5, but
;                only once a verb is in the sentence (PCDAAD
;                parser.pas:572 "if getFlag(FVERB) <> NO_WORD").
;   eng_v3prep   parser stored a preposition: set bit 4, but only while
;                noun1 is still empty (PCDAAD parser.pas:528).
;   eng_v3f53    flag 53 = (flag 53 AND E) OR D. No-op on a version 2
;                database - bits 0-5 of flag 53 are the game's own
;                property under V2 and must not move.
; All three clobber AF, DE, HL and preserve BC/IX/IY.
eng_v3unrec:
    ld a, (flags+FLAG_VERB)
    inc a
    ret z                       ; no verb yet: not "after the verb"
    ld de, (F53_UNRECWRD<<8)|$FF
    jr eng_v3f53
eng_v3prep:
    ld a, (flags+FLAG_NOUN1)
    inc a
    ret nz                      ; noun1 already filled: not "before"
    ld de, (F53_PREPFIRST<<8)|$FF
eng_v3f53:
    ld hl, ddbVer
    bit 0, (hl)                 ; version 2 and 3 differ in bit 0 alone
    ret z
    ld hl, flags+FLAG_OFLAGS
    ld a, (hl)
    and e
    or d
    ld (hl), a
    ret

; --- DOALL ---
; Started by the DOALL handler (stores doallLoc, doallLevel, resets
; doallObj to $FF then falls into next-object search).
eng_doall_next:
    ld a, (doallObj)
    inc a                       ; start after the previous object
    ld b, a
.scan:
    ld a, (numObj)
    cp b
    jr z, .exhausted
    ld a, b
    push bc
    call obj_ptr
    pop bc
    ld a, (doallLoc)
    cp LOC_HERE
    jr nz, .fixed
    ld a, (flags+FLAG_PLAYER)
.fixed:
    cp (hl)
    jr nz, .next
    ; ALL EXCEPT: skip when noun+adj match Noun2/Adject2
    push hl
    pop iy
    ld a, (flags+FLAG_NOUN2)
    cp (iy+4)
    jr nz, .take
    ld a, (flags+FLAG_ADJ2)
    cp (iy+5)
    jr z, .next
.take:
    ; V3 flag 53 bit 0: both references write it at TWO sites - SET at
    ; DOALL entry (h_doall), CLEAR here on first object found (msx2daad
    ; daad_condacts.c:2280/:2255, PCDAAD condacts.pas:1460/1467). A
    ; caso-A-only SET (below) would leave the bit stale through a later
    ; successful DOALL. B is live across this call; eng_v3f53 preserves it.
    ld de, $00FE                ; OR 0, AND ~F53_DOALLNONE
    call eng_v3f53
    ld a, b
    ld (doallObj), a
    ld (flags+FLAG_DOALL), a
    ld a, (iy+4)
    ld (flags+FLAG_NOUN1), a
    ld a, (iy+5)
    ld (flags+FLAG_ADJ1), a
    ; restart the DOALL level's table at its stored resume point
    ; (entry AND condact pointers, so a REDO/SKIP position mid-entry
    ; survives across DOALL iterations)
    call eng_top_ix
    ld hl, (doallResE)
    ld (ix+1), l
    ld (ix+2), h
    ld hl, (doallResC)
    ld (ix+3), l
    ld (ix+4), h
    ret
.next:
    inc b
    jr .scan
.exhausted:
    ; Both references split the exhausted DOALL into two cases;
    ; NextDAAD reaches both through this label, discriminated by the
    ; ENTRY value of doallObj: h_doall resets it to $FF before the
    ; initial scan (overlay0.asm:218), eng_pop_proc's step-4 re-entry
    ; only reaches here when it is NOT $FF (:327-329). Only .take
    ; writes it, and .take returns.
    ;   caso A - INITIAL scan found nothing: NEWTEXT then NOTDONE.
    ;     msx2daad do_DOALL (daad_condacts.c:2286-2295, "Caso A",
    ;     PCDAAD condacts.pas:1486-1491) runs clearLogicalSentences()
    ;     + isDone=false + popPROC; jDAAD's _DOALL else arm (jdaad.js:
    ;     3578-3582) runs newtext(); _NOTDONE(). Without this the level
    ;     exits DONE (DOALL is action-typed, so the dispatcher already
    ;     set done=1) and the rest of the compound order survives.
    ;   caso B - DOALL iterated and ran out: plain pop, DONE. msx2daad
    ;     _internal_doall_continue (:2265-2276) is explicit this must
    ;     not merge with caso A ("No isDone/checkEntry/lsBuffer
    ;     mutation here"); unitTests tests_condacts_v3.c D-CANCEL-2d
    ;     regression-tests against exactly that merge (a NOTDONE here
    ;     made a successful DROP ALL answer "I can't do that").
    ; NEWTEXT is h_newtext's body inlined (clear inpPending, a resident
    ; cell - overlay0.asm:1947-1950); h_newtext itself lives in
    ; overlay0 and cannot be called from here.
    ; Flag 53 bit 0 needs no action here: caso A never reaches .take's
    ; clear, so the entry-time SET from h_doall simply stands.
    xor a
    ld (doallLevel), a
    ld hl, doallObj
    ld a, (hl)
    ld (hl), $FF                ; reset for the next DOALL
    inc a                       ; entry $FF -> 0/Z = caso A
    jp nz, eng_pop_tail         ; caso B: complete as DONE, as before
    xor a
    ld (inpPending), a          ; caso A: NEWTEXT
    jp eng_exit_table           ; then NOTDONE (A = 0) and pop

; --- condact properties: bit 7 = action, bit 6 = no done, argc = 0-1 --
; Bit 7 says "the dispatcher ignores this handler's CF" AND "stamp the
; table done before dispatch". Those two are not the same property:
; SKIP (116) and REDO (108) need the first and must not have the second,
; because neither reference counts them as an Action for ISDONE
; (msx2daad's condactList flags them 0; jDAAD's _SKIP/_REDO set no
; done). Bit 6 splits them apart - $C0/$C1 = action, does not mark done.
; QUIT 20, MOVE 106, PICTURE 84, PARSE 73 deliberately typed as
; conditions (PARSE: CF gates entry continuation - see check 58, which
; relies on a failed/timed-out PARSE aborting its entry). MOVE and
; PICTURE are condition-typed for the CF alone: both references mark
; them done on EVERY path, so their handlers call eng_set_done at entry
; instead (suite checks 105-108).
cprops:
    db 1,1,1,1, 1,1,1,1         ; 0-7   AT..NOTWORN (C,1)
    db 1,1,1,1, 1,2,2,2         ; 8-15  CARRIED..LT (EQ/GT/LT C,2)
    db 1,1                      ; 16-17 ADJECT1, ADVERB (C,1)
    db $82                      ; 18    SFX (A,2)
    db $81                      ; 19    DESC (A,1)
    db 0                        ; 20    QUIT (C,0)
    db $80,$80,$80,$80          ; 21-24 END DONE OK ANYKEY (A,0)
    db 1,1,$81,$81              ; 25-28 SAVE(C,1) LOAD(C,1) DPRINT DISPLAY
                                ; SAVE/LOAD are condition-typed like
                                ; PARSE/QUIT: failure aborts the entry
                                ; so the error message survives the
                                ; game's redraw; done is set on every
                                ; outcome (argc 1 matches DRF)
    db $80,$80,$80,$80,$80,$80  ; 29-34 CLS DROPALL AUTOG AUTOD AUTOW AUTOR
    db $81,2,$81,$81,$81,$81    ; 35-40 PAUSE SYNONYM GOTO MESSAGE REMOVE GET
                                ; SYNONYM (36) is condition-typed, argc
                                ; unchanged at 2: under V3 it must NOT
                                ; mark the level done (PRP019 V3-12,
                                ; tests_condacts_v3.c
                                ; test_SYNONYM_v3_no_done), and an
                                ; action-typed row would have the
                                ; dispatcher stamp done BEFORE the
                                ; handler could decide. h_synonym now
                                ; calls eng_set_done itself on the V2
                                ; path and always returns CF clear, which
                                ; is what the action row did.
    db $81,$81,$81,$81,$82,$82  ; 41-46 DROP WEAR DESTROY CREATE SWAP PLACE
    db $81,$81,$82,$82,$82      ; 47-51 SET CLEAR PLUS MINUS LET
    db $80,$81,$81              ; 52-54 NEWLINE PRINT SYSMESS
    db 2                        ; 55    ISAT (C,2)
    db $81,$80                  ; 56-57 SETCO SPACE
    db 1,1                      ; 58-59 HASAT HASNAT (C,1)
    db $80,$82,$80,$81          ; 60-63 LISTOBJ EXTERN RAMSAVE RAMLOAD
    db $82,$81,$81,$81          ; 64-67 BEEP PAPER INK BORDER
    db 1,1,1                    ; 68-70 PREP NOUN2 ADJECT2 (C,1)
    db $82,$82,1,$81,$81        ; 71-75 ADD SUB PARSE(C) LISTAT PROCESS
    db 2,$81,$81                ; 76-78 SAME(C,2) MES WINDOW
    db 2,2                      ; 79-80 NOTEQ NOTSAME (C,2)
    db $81,$82,$82              ; 81-83 MODE WINAT TIME
    db 1                        ; 84    PICTURE (C,1 - fails the entry when
                                ;       no loadable art exists, like jdaad;
                                ;       h_picture stamps done itself on
                                ;       every exit, as both references do)
    db $81,$82,$82              ; 85-87 DOALL MOUSE GFX (MOUSE argc 2)
    db 2                        ; 88    ISNOTAT (C,2)
    db $82,$82,$82,$80,$82,$81  ; 89-94 WEIGH PUTIN TAKEOUT NEWTEXT ABILITY WEIGHT
    db $81,$82,$80,$80,$82      ; 95-99 RANDOM INPUT SAVEAT BACKAT PRINTAT
    db $80,$82,$81,$80,$81,$81  ; 100-105 WHATO CALL PUTO NOTDONE AUTOP AUTOT (CALL argc 2)
    db 1                        ; 106   MOVE (C,1 - condition-like)
    db $82,$C0,$80,$81          ; 107-110 WINSIZE REDO CENTRE EXIT
                                ; REDO is $C0: action-typed for CF, but
                                ; not an Action for ISDONE
    db 0                        ; 111   INKEY (C,0)
    db 2,2,0,0                  ; 112-115 BIGGER SMALLER ISDONE ISNDONE (C)
    db $C1,$80,$81              ; 116-118 SKIP RESTART TAB
                                ; SKIP is $C1 for the same reason as REDO
    db $82,$82,$82,$81,$82,$82  ; 119-124 COPYOF XMES COPYOO INDIR
                                ; COPYFO SETAT. SP16 A2: 120/122/124
                                ; are the V3 opcodes and carry real
                                ; arity - XMES lsb msb (A,2), INDIR
                                ; flagno (A,1), SETAT value operation
                                ; (A,2), matching PRP013's CONDACTS[]
                                ; table and the bytes DRB emits. All
                                ; three are action-typed ({do_X, 1} in
                                ; msx2daad's condactList). On a version
                                ; 2 database the arguments are consumed
                                ; and the handler then raises E5, so a
                                ; V2 database still dies on them.
                                ; NOTE: DRF.exe's own parameter table
                                ; still calls these three slots "dumb"
                                ; with 0 params, because DRF never
                                ; emits them - the source keywords are
                                ; XMES (its record 128, 1 param) and
                                ; the '@' second-parameter syntax, and
                                ; DRB rewrites both. check-cprops.ps1
                                ; carries the matching exception.
    db $82,$82,$80              ; 125-127 COPYFF COPYBF RESET

; --- dispatch table: 3 bytes per condact (page, addr lo, addr hi) ---
    MACRO DC addr
    db OVL0_PAGE
    dw addr
    ENDM
    MACRO DC1 addr
    db OVL1_PAGE
    dw addr
    ENDM
    MACRO DC2 addr
    db OVL2_PAGE
    dw addr
    ENDM
cdisp:
    ; 128 rows in condact order. Task 2: all DC h_unimpl except the
    ; pilot set; later tasks repoint rows as handlers land.
    DC h_at                      ; 0   AT
    DC h_notat                   ; 1   NOTAT
    DC h_atgt                    ; 2   ATGT
    DC h_atlt                    ; 3   ATLT
    DC h_present                 ; 4   PRESENT
    DC h_absent                  ; 5   ABSENT
    DC h_worn                    ; 6   WORN
    DC h_notworn                 ; 7   NOTWORN
    DC h_carried                 ; 8   CARRIED
    DC h_notcarr                 ; 9   NOTCARR
    DC h_chance                 ; 10  CHANCE
    DC h_zero                   ; 11  ZERO
    DC h_notzero                ; 12  NOTZERO
    DC h_eq                     ; 13  EQ
    DC h_gt                     ; 14  GT
    DC h_lt                     ; 15  LT
    DC h_adject1                ; 16  ADJECT1
    DC h_adverb                 ; 17  ADVERB
    DC1 h_sfx                   ; 18  SFX
    DC h_desc                   ; 19  DESC
    DC h_quit                   ; 20  QUIT
    DC h_end                    ; 21  END
    DC h_done                   ; 22  DONE
    DC h_ok                     ; 23  OK
    DC h_anykey                 ; 24  ANYKEY
    DC1 h_save                  ; 25  SAVE
    DC1 h_load                  ; 26  LOAD
    DC h_dprint                 ; 27  DPRINT
    DC2 h_display               ; 28  DISPLAY
    DC h_cls                    ; 29  CLS
    DC h_dropall                 ; 30  DROPALL
    DC h_autog                   ; 31  AUTOG
    DC h_autod                   ; 32  AUTOD
    DC h_autow                   ; 33  AUTOW
    DC h_autor                   ; 34  AUTOR
    DC h_pause                  ; 35  PAUSE
    DC h_synonym                ; 36  SYNONYM
    DC h_goto                   ; 37  GOTO
    DC h_message                ; 38  MESSAGE
    DC h_remove                  ; 39  REMOVE
    DC h_get                     ; 40  GET
    DC h_drop                    ; 41  DROP
    DC h_wear                    ; 42  WEAR
    DC h_destroy                 ; 43  DESTROY
    DC h_create                  ; 44  CREATE
    DC h_swap                    ; 45  SWAP
    DC h_place                   ; 46  PLACE
    DC h_set                    ; 47  SET
    DC h_clear                  ; 48  CLEAR
    DC h_plus                   ; 49  PLUS
    DC h_minus                  ; 50  MINUS
    DC h_let                    ; 51  LET
    DC h_newline                ; 52  NEWLINE
    DC h_print                  ; 53  PRINT
    DC h_sysmess                ; 54  SYSMESS
    DC h_isat                    ; 55  ISAT
    DC h_setco                   ; 56  SETCO
    DC h_space                  ; 57  SPACE
    DC h_hasat                  ; 58  HASAT
    DC h_hasnat                 ; 59  HASNAT
    DC h_listobj                ; 60  LISTOBJ
    DC h_extern                 ; 61  EXTERN
    DC1 h_ramsave                ; 62  RAMSAVE
    DC1 h_ramload                ; 63  RAMLOAD
    DC1 h_beep                  ; 64  BEEP
    DC h_paper                  ; 65  PAPER
    DC h_ink                    ; 66  INK
    DC h_border                 ; 67  BORDER
    DC h_prep                   ; 68  PREP
    DC h_noun2                  ; 69  NOUN2
    DC h_adject2                ; 70  ADJECT2
    DC h_add                    ; 71  ADD
    DC h_sub                    ; 72  SUB
    DC1 h_parse                 ; 73  PARSE
    DC h_listat                 ; 74  LISTAT
    DC h_process                ; 75  PROCESS
    DC h_same                   ; 76  SAME
    DC h_mes                    ; 77  MES
    DC h_window                 ; 78  WINDOW
    DC h_noteq                  ; 79  NOTEQ
    DC h_notsame                ; 80  NOTSAME
    DC h_mode                   ; 81  MODE
    DC h_winat                  ; 82  WINAT
    DC1 h_time                  ; 83  TIME
    DC2 h_picture               ; 84  PICTURE
    DC h_doall                  ; 85  DOALL
    DC h_mouse                  ; 86  MOUSE
    DC2 h_gfx                   ; 87  GFX
    DC h_isnotat                 ; 88  ISNOTAT
    DC h_weigh                   ; 89  WEIGH
    DC h_putin                   ; 90  PUTIN
    DC h_takeout                 ; 91  TAKEOUT
    DC h_newtext                ; 92  NEWTEXT
    DC h_ability                 ; 93  ABILITY
    DC h_weight                  ; 94  WEIGHT
    DC h_random                 ; 95  RANDOM
    DC1 h_input                 ; 96  INPUT
    DC h_saveat                 ; 97  SAVEAT
    DC h_backat                 ; 98  BACKAT
    DC h_printat                ; 99  PRINTAT
    DC h_whato                   ; 100 WHATO
    DC h_call                   ; 101 CALL
    DC h_puto                    ; 102 PUTO
    DC h_notdone                ; 103 NOTDONE
    DC h_autop                   ; 104 AUTOP
    DC h_autot                   ; 105 AUTOT
    DC h_move                   ; 106 MOVE
    DC h_winsize                ; 107 WINSIZE
    DC h_redo                   ; 108 REDO
    DC h_centre                 ; 109 CENTRE
    DC h_exit                   ; 110 EXIT
    DC h_inkey                  ; 111 INKEY
    DC h_bigger                 ; 112 BIGGER
    DC h_smaller                ; 113 SMALLER
    DC h_isdone                 ; 114 ISDONE
    DC h_isndone                ; 115 ISNDONE
    DC h_skip                   ; 116 SKIP
    DC h_restart                ; 117 RESTART
    DC h_tab                    ; 118 TAB
    DC h_copyof                  ; 119 COPYOF
    DC h_xmes                   ; 120 XMES (V3)
    DC h_copyoo                  ; 121 COPYOO
    DC h_indir                  ; 122 INDIR (V3)
    DC h_copyfo                  ; 123 COPYFO
    DC h_setat                  ; 124 SETAT (V3)
    DC h_copyff                 ; 125 COPYFF
    DC h_copybf                 ; 126 COPYBF
    DC h_reset                   ; 127 RESET

; --- engine data (flags 256-aligned) ---
; The ALIGN pad is a HARD CEILING on pre-flags code, not slack. Bytes
; added anywhere before this point are free - they fill padding rather
; than the RESIDENT_LIMIT headroom main.asm reports - right up until
; the pad runs out, at which point flags snaps to $A300 and the ASSERT
; below fires. That makes it worth printing, because the number is
; invisible otherwise and two budgets now compete: this pad, and the
; post-anchor headroom. Code moved pre-anchor in 2026-09 with the
; sav_write/sav_read deletion is deliberate ballast, marked "Pre-anchor
; ballast" - move any of it back to its post-anchor home to rebalance.
; Moving code in shrinks the pad, deleting code grows it. READ THE DEBUG
; FIGURE: DEBUG carries the most pre-anchor code, so it is the tightest
; variant; the DISPLAY below reports the live pad at every build.
    DISPLAY "pre-flags pad ", /D, $A200 - $, " bytes free"
    ALIGN 256
flags:      ds 256
; SP14c batch B gate follow-up (rubric 7): flags is a frozen-address
; ABI anchor. ALIGN snaps DOWNWARD when pre-flags code shrinks past a
; 256 boundary - the image gets SMALLER, so RESIDENT_LIMIT asserts
; pass while the ABI silently breaks (it happened: Release-only snap
; to $A100, caught at apply time). This assert makes any future snap
; a hard build failure in every variant.
    ASSERT flags == $A200
objTable:   ds 256*OBJ_SIZE
numObj:     db 0
    ASSERT numObj == $A900   ; frozen XBN ABI anchor, same class as flags
procStack:  ds PROC_DEPTH*PREC_SIZE
procSP:     db 0
isDone:     db 0                ; ISDONE/ISNDONE. ONE cell for the whole
                                ; machine, cleared only by a process
                                ; push, set by every Action condact -
                                ; msx2daad's isDone, jDAAD's done
curOpcode:  db 0
curCondact: db 0
curProps:   db 0
extArg3:    db 0                ; EXTERN fn-3 third parameter (offset MSB)
; XBN extern binary boot state (Task 2, overlay0.asm's xbn_boot_load is
; the only writer; xbnBank is the master gate Tasks 3-6 check first - a
; rejected/absent file leaves it $FF and the other four fields undefined).
xbnBank:    db $FF          ; 16K bank holding GAME.XBN, $FF = none
xbnExt:     dw 0            ; cached header extEntry
xbnInt:     dw 0            ; cached header intEntry
xbnEnd:     dw 0            ; $C000 + size (exclusive window limit)
xbnIntOn:   db 0            ; bit 0 = XBN intEntry armed, bit 1 = sprite
                            ; tick, bit 2 = colour cycle tick; ISR tests nonzero
doallObj:   db $FF
doallLoc:   db 0
doallLevel: db 0
doallResE:  dw 0
doallResC:  dw 0
rngState:   dw $A5C3            ; xorshift seed (resident: overlay page
                                ; contents are only valid while page 56
                                ; is mapped in SP7)

; --- post-anchor resident code ---
; Everything above flags: is capped by the ALIGN pad, so this routine
; lives here, on the RESIDENT_LIMIT budget, as its own note explains.

; Give every objTable slot the "not created" shape. The DDB declares
; only numObj objects but all 256 numbers are reachable - WHATO leaves
; 255 (NULLWORD) in flag 51 on a miss and an indirected condact spends
; it - so the undeclared slots must read as a nowhere object rather
; than fault (jdaad.js:719-725, PCDAAD objects.pas:149).
; In: C = 0 full build (all six bytes), C = 1 RESET (location only -
; the DDB-derived fields cannot have changed). Corrupts AF, B, DE, HL.
obj_fill_null:
    ld hl, objTable
    ld b, 0                     ; 256 slots: djnz wraps
    ld a, c
    or a
    jr nz, .locsonly
.full:
    ld (hl), OBJ_NOT_CREATED
    inc hl
    xor a
    ld (hl), a                  ; +1 attributes
    inc hl
    ld (hl), a                  ; +2 ext attrs 8-15
    inc hl
    ld (hl), a                  ; +3 ext attrs 0-7
    inc hl
    dec a                       ; $FF
    ld (hl), a                  ; +4 noun  = no word
    inc hl
    ld (hl), a                  ; +5 adjective
    inc hl
    djnz .full
    ret
.locsonly:
    ld (hl), OBJ_NOT_CREATED
    ld de, OBJ_SIZE
    add hl, de
    djnz .locsonly
    ret
