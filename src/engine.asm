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
    ld a, 4
    ld (flags+FLAG_MAXCARR), a
    ld a, 10
    ld (flags+FLAG_STRENGTH), a
    ; SP16 C1 (docs/daad-compliance-report.md section 4): flag 29
    ; fGFlags is the capability byte a period game gates its artwork
    ; on - "HASAT GMODE" (attribute 247 -> flag 29 bit 7) is the
    ; canonical test, "HASAT MOUSE" (240 -> bit 0) the other. It was
    ; never written, so every such game ran here as if text-only.
    ; The value is DERIVED FROM THIS INTERPRETER'S CAPABILITIES, not
    ; copied from jDAAD (owner ruling 2026-07-27): bit 7 because
    ; Layer 2 location graphics exist, bit 0 because MOUSE (condact
    ; 66) is implemented. Bits 1-6 are drawstring-machine options
    ; (invisible draw, pictures off, wait-for-key, border) that this
    ; interpreter does not have, so they stay clear.
    ld a, %10000001              ; = 129
    ld (flags+FLAG_GFLAGS), a
    ; SP16 C2: flag 62 fScMode is the absolute screen-mode byte,
    ; also never written. msx2daad's convention (daad_platform_msx2.c
    ; gfxSetScreenModeFlags) is "16|SCREEN" - bit 4 marks a native
    ; machine mode, distinguishing it from the ST (bits 0-3 = 0/1)
    ; and PC (4/7/13) values the field originally carried - with
    ; bits 0-3 naming the mode. Bit 7 means "palette switching
    ; available", which the Next has (the template's own comment
    ; reads "2=Text, 4=CGA, 13=EGA, 141=VGA"; jDAAD forces 14+128).
    ; So: bit 7 + bit 4 + mode 0, where 0 mirrors l2Mode's own
    ; encoding for Layer 2 256x192 256-colour, the boot default
    ; (overlay2.asm l2_mode_set). Static - this interpreter does not
    ; re-publish the byte when a game switches Layer 2 mode.
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
    ld a, (numObj)
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
    ; Extended attributes (2 bytes each). SP16 A5
    ; (docs/daad-compliance-report.md section 2, Appendix A probe 4):
    ; the DDB stores the 16 user attribute bits as ONE LITTLE-ENDIAN
    ; WORD (drb.php generateObjectExtraAttr -> writeWord). HASAT n
    ; addresses them as flags[59 - (n>>3)], so attributes 0-7 must
    ; reach flag 59 and 8-15 flag 58 - i.e. flag 59 takes the word's
    ; LOW byte, which is the FIRST byte in the file. A probe object
    ; declared with only attribute 0 set compiles to the bytes
    ; 01 00, and both references agree (jdaad.js:739-740,
    ; daad_init.c:168-169 + daad_objects.c:56-57).
    ; objTable therefore holds the pair in FLAG ORDER, high attribute
    ; byte first: +2 = attrs 8-15 -> flag 58 / 39, +3 = attrs 0-7 ->
    ; flag 59 / 40. This is the ONLY place the file's order is
    ; interpreted; obj_set_refs (overlay0.asm) and obj2_resolve
    ; (overlay1.asm) then copy +2/+3 out sequentially and both land
    ; correctly. Do not "fix" the swap here without fixing both.
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

; A = object number -> HL = objTable entry. Error 0 if out of range.
; Corrupts AF, DE. Preserves BC.
obj_ptr:
    push bc
    ld c, a
    ld a, (numObj)
    dec a
    cp c
    jr c, .bad
    ld d, 6                      ; SP14c E4: DE = 6*c (OBJ_SIZE) via
    ld e, c                      ; Z80N MUL (was shift-add *2/*4/+de)
    mul d, e
    ld hl, objTable
    add hl, de
    ld a, c
    pop bc
    ret
.bad:
    pop bc
    xor a                       ; error 0: invalid object
    jp err_raise

; Push process A and run the game loop forever (eng_step restarts
; PRO 0 whenever the process stack fully unwinds - see its stack-empty
; case). PARSE blocks synchronously inside inp_edit, so this busy loop
; only advances once real input (or a timeout) is available.
eng_run:
    ld a, 0
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
    add a, a
    ld e, a
    ld d, 0
    add hl, de                  ; entry in the process list
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
    inc hl
    ld (hl), 0                  ; done-flag
    ld hl, procSP
    inc (hl)
    ret

; HL -> stack record for level (procSP). Corrupts AF, DE.
eng_rec_ptr:
    ld a, (procSP)
eng_rec_ptr_a:                  ; entry with A = level
    ld e, a                      ; SP14c E5: DE = 6*level (PREC_SIZE) via
    ld d, 6                      ; Z80N MUL (was shift-add *2/*4/+de)
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
    call eng_next_entry
    ret
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

; Pop the top process. The popped level's done-flag becomes lastDone
; (ISDONE/ISNDONE) and ORs into the caller's done-flag.
eng_pop_proc:
    ld a, (doallLevel)
    ld b, a
    ld a, (procSP)
    cp b
    jr nz, eng_pop_tail
    ld a, (doallObj)
    inc a
    jp nz, eng_doall_next       ; DOALL live on this level: iterate
; Shared tail (SP14c E1): this exact 36-byte sequence was duplicated
; verbatim as eng_doall_next's .plainpop2 (dead-code duplication found
; in the SP14c sweep) - both plain-pop paths (normal pop and DOALL-
; exhausted pop) now share this one body via a tail JP.
eng_pop_tail:
    ld a, (procSP)
    dec a
    ld (procSP), a
    call eng_rec_ptr_a
    ld de, 5
    add hl, de
    ld a, (hl)                  ; popped done-flag
    ld (lastDone), a
    ld b, a
    ld a, (procSP)
    or a
    ret z                       ; stack empty; eng_step restarts PRO 0
    dec a
    call eng_rec_ptr_a
    ld de, 5
    add hl, de
    ld a, (hl)
    or b
    ld (hl), a                  ; propagate done into caller
    ret

; Execute the condact at IX's condactPtr (HL already = that pointer
; when entered from eng_step via eng_exec).
eng_exec:
    call data_save
    call rd_seek
    call rd_next                ; opcode byte
    ld (curOpcode), a
    cp $FF                      ; $FF = entry terminator (DRC emits it
    jp z, .endentry             ; on every fall-through entry); CP keeps
                                 ; A intact so the reload below (SP14c E2)
                                 ; is unneeded
    and $7F
    ld (curCondact), a
    cp 120
    jp z, .illegal               ; jr out of range once fn-3 consumption
    cp 122                       ; is inserted below (~+145): illegal
    jp z, .illegal               ; opcodes are a cold path, jp costs
    cp 124                       ; nothing that matters here
    jp z, .illegal
    ; properties
    ld e, a
    ld d, 0
    ld hl, cprops
    add hl, de
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
    ld hl, (rdPtr)              ; NOTE: window-relative; rebuild absolute
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
    ; actions mark the level done BEFORE dispatch: handlers like
    ; PROCESS/DONE/RESTART change the stack, so marking after the
    ; call would stamp the wrong record
    ld a, (curProps)
    bit 7, a
    jr z, .nodone
    push bc
    call eng_set_done
    pop bc
.nodone:
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
    call .jphl                  ; call handler: B=arg1, C=arg2
    ; post: only conditions consult CF
    ld a, (curProps)
    bit 7, a
    ret nz                      ; action: done already recorded
    ret nc                      ; condition passed: continue entry
    call eng_top_ix             ; condition failed: next entry
    jp eng_next_entry
.jphl:
    jp (hl)
.endentry:
    call data_restore           ; entry fell through its terminator:
    jp eng_next_entry           ; carry on with the next entry
.illegal:
    call data_restore
    ld a, 5
    jp err_raise

; Rebuild an absolute DDB pointer from rdPage/rdPtr.
; offset = (page-DDB_PAGE_FIRST)*$2000 + (rdPtr - DATA_WINDOW)
eng_ptr_abs:
    ld a, (rdPage)
    sub DDB_PAGE_FIRST           ; a = page index, PROVABLY 0..7 (rd_seek
                                 ; masks offset>>13 with AND 7, ddbtext.asm)
 IFDEF DEBUG
    ; SP14c E6 histogram instrument (KEPT post-apply - owner's request;
    ; one optional Urban Upstart cross-check remains, strips at batch
    ; close). Bucket[a] counts condact dispatches with page-crossing
    ; index a (0-7), saturating at 255. Preserves AF/HL/DE exactly
    ; (push/pop brackets) - zero behavioural effect on the function.
    ; Read-out: peek the 8 bytes at label ENG_PTR_ABS_HIST (see
    ; build\nextdaad.map after assembly) in CSpect's/DeZog's memory
    ; viewer. Verdict already landed (owner-measured Rabenstein
    ; session, real gameplay): buckets = 00 00 FF 00 00 00 00 00 -
    ; every condact dispatch that session hit page index a=2, nothing
    ; else, ever (DRC places process tables at the END of the DDB, so
    ; condact fetches always target the highest pages present).
    push af
    push hl
    push de
    ld e, a                     ; E = page index (0-7); A unchanged,
    ld d, 0                     ; restored below by pop af regardless
    ld hl, eng_ptr_abs_hist
    add hl, de
    ld a, (hl)
    cp 255
    jr z, .e6hist_sat
    inc (hl)
.e6hist_sat:
    pop de
    pop hl
    pop af
 ENDIF
    ; SP14c E6 (owner-endorsed on the histogram above): flat,
    ; unconditional shift replaces the old data-dependent DEC-loop.
    ; a*$2000 = (a<<5) placed as the high byte of a 16-bit word (low
    ; byte 0), since $2000/$100 = $20 = 1<<5; exact for the full
    ; provable range a=0..7 (2^5*7 = 224, fits one byte, no overflow).
    ; Verdict rationale: real dispatch never observed a=0 (the
    ; feared regression case the gate's rule guarded against), so the
    ; old loop's a=0 fast exit bought nothing in practice while its
    ; cost grew with a on every other call; this form is constant-time
    ; (124T) for every a in 0..7, faster than the loop at every a>=1
    ; and only slightly slower than the loop's unreachable a=0 case
    ; (106T) - see the findings report for the full instruction-by-
    ; instruction derivation (doc 05/06 shift-by-constant idiom).
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
    add hl, de
    ld de, DDB_ZX_BASE
    add hl, de
    ret

 IFDEF DEBUG
; SP14c E6 histogram data (see eng_ptr_abs above). Deliberately placed
; HERE - before this file's ALIGN 256/flags boundary - not after: the
; SP14c T1 batch freed slack ahead of that boundary, and landing this
; DEBUG-only diagnostic table there spends slack that is otherwise
; invisible to the plan's tracked tail headroom, rather than the
; scarcer post-flags RESIDENT_LIMIT budget. 8 bytes; verified (see
; report) not to cross the 256-byte alignment threshold.
eng_ptr_abs_hist: ds 8
 ENDIF

; IX -> top stack record. Corrupts AF, DE, HL.
eng_top_ix:
    ld a, (procSP)
    dec a
    call eng_rec_ptr_a
    push hl
    pop ix
    ret

; Set the current level's done-flag (QUIT/MOVE success path).
eng_set_done:
    call eng_top_ix
    ld a, 1
    ld (ix+5), a
    ret

; DONE/NOTDONE support: force table end for the top process.
; In: A = 1 done, 0 notdone (overwrites the level's done-flag).
eng_exit_table:
    push af
    call eng_top_ix
    pop af
    ld (ix+5), a
    jp eng_pop_proc

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
    ld a, $FF
    ld (doallObj), a
    xor a
    ld (doallLevel), a
    ; complete as DONE: plain pop (SP14c E1 - shared tail, see eng_pop_proc)
    jp eng_pop_tail

; --- condact properties: bit 7 = action, bits 0-1 = argc ---
; QUIT 20, MOVE 106, PICTURE 84, PARSE 73 deliberately typed as
; conditions (PARSE: CF gates entry continuation - see check 58, which
; relies on a failed/timed-out PARSE aborting its entry).
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
    db $81,$82,$81,$81,$81,$81  ; 35-40 PAUSE SYNONYM GOTO MESSAGE REMOVE GET
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
                                ;       no loadable art exists, like jdaad)
    db $81,$82,$82              ; 85-87 DOALL MOUSE GFX (MOUSE argc 2)
    db 2                        ; 88    ISNOTAT (C,2)
    db $82,$82,$82,$80,$82,$81  ; 89-94 WEIGH PUTIN TAKEOUT NEWTEXT ABILITY WEIGHT
    db $81,$82,$80,$80,$82      ; 95-99 RANDOM INPUT SAVEAT BACKAT PRINTAT
    db $80,$82,$81,$80,$81,$81  ; 100-105 WHATO CALL PUTO NOTDONE AUTOP AUTOT (CALL argc 2)
    db 1                        ; 106   MOVE (C,1 - condition-like)
    db $82,$80,$80,$81          ; 107-110 WINSIZE REDO CENTRE EXIT
    db 0                        ; 111   INKEY (C,0)
    db 2,2,0,0                  ; 112-115 BIGGER SMALLER ISDONE ISNDONE (C)
    db $81,$80,$81              ; 116-118 SKIP RESTART TAB
    db $82,0,$82,0,$82,0        ; 119-124 COPYOF (119) COPYOO (121) COPYFO (123); 120/122/124 illegal
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
    DC h_unimpl                 ; 120 (unused)
    DC h_copyoo                  ; 121 COPYOO
    DC h_unimpl                 ; 122 (unused)
    DC h_copyfo                  ; 123 COPYFO
    DC h_unimpl                 ; 124 (unused)
    DC h_copyff                 ; 125 COPYFF
    DC h_copybf                 ; 126 COPYBF
    DC h_reset                   ; 127 RESET

; --- engine data (flags 256-aligned) ---
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
procStack:  ds PROC_DEPTH*PREC_SIZE
procSP:     db 0
lastDone:   db 0
curOpcode:  db 0
curCondact: db 0
curProps:   db 0
extArg3:    db 0                ; EXTERN fn-3 third parameter (offset MSB)
doallObj:   db $FF
doallLoc:   db 0
doallLevel: db 0
doallResE:  dw 0
doallResC:  dw 0
rngState:   dw $A5C3            ; xorshift seed (resident: overlay page
                                ; contents are only valid while page 56
                                ; is mapped in SP7)
