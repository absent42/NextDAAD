; Overlay page 0: condact handlers (sub-project 3). Assembled into
; 8K page 56 (bank 28, lower half) at $E000, mapped into slot 7 by
; the dispatcher only. Handler ABI: B = arg1 (indirection already
; applied), C = arg2; conditions return CF clear (true) / set (false).
    MMU 7, OVL0_PAGE, OVL_ORG

; Unimplemented / future-sub-project condact: debug marker, no-op.
; Returns CF SET so stub conditions (INKEY until Task 8) fail
; safely; harmless for actions (the engine ignores CF on actions).
h_unimpl:
 IFDEF DEBUG
    push bc
    ld a, (curCondact)
    ld b, 31
    ld c, 0
    ld hl, msgStub
    call dbg_mark_hex
    pop bc
 ENDIF
    scf
    ret

h_zero:                         ; 11: flags[B] == 0
    ld h, high flags
    ld l, b
    ld a, (hl)
    or a
    ret z
    scf
    ret

h_notzero:                      ; 12
    ld h, high flags
    ld l, b
    ld a, (hl)
    sub 1
    ret

h_eq:                           ; 13: flags[B] == C
    ld h, high flags
    ld l, b
    ld a, (hl)
    cp c
    ret z
    scf
    ret

h_let:                          ; 51: flags[B] = C
    ld h, high flags
    ld l, b
    ld (hl), c
    ret

h_plus:                         ; 49: flags[B] += C, saturate 255
    ld h, high flags
    ld l, b
    ld a, (hl)
    add a, c
    jr nc, .st
    ld a, 255
.st:
    ld (hl), a
    ret

h_minus:                        ; 50: flags[B] -= C, floor 0
    ld h, high flags
    ld l, b
    ld a, (hl)
    sub c
    jr nc, .st
    xor a
.st:
    ld (hl), a
    ret

h_newline:                      ; 52
    jp prn_newline

h_sysmess:                      ; 54: system message B, checked
    ld a, (ddbHeader+HDR_NUMSYS)
    dec a
    cp b
    jr nc, .ok
    ld a, 7
    jp err_raise
.ok:
    ld e, b
    xor a                       ; kind 0 = system message
    jp print_msg

h_message:                      ; 38: user message B + newline
    call h_mes
    jp prn_newline

h_mes:                          ; 77
    ld a, (ddbHeader+HDR_NUMMSG)
    dec a
    cp b
    jr nc, .ok
    ld a, 7
    jp err_raise
.ok:
    ld e, b
    ld a, 1
    jp print_msg

h_done:                         ; 22
    ld a, 1
    jp eng_exit_table

h_notdone:                      ; 103
    xor a
    jp eng_exit_table

h_cls:                          ; 29 (pilot: the driver clears the
    call prn_flush               ; boot diagnostics before the suite)
    call win_cls
    jp prn_reset_lines

h_process:                      ; 75 (pilot: the driver nests PRO 1)
    ld a, b
    jp eng_push_proc

h_skip:                         ; 116: jump B (signed) + 1 entries on.
    call eng_top_ix             ; SKIP 0 = next entry, SKIP 1 skips one,
    ld e, b                     ; SKIP 254 (-2) re-runs the previous.
    ld a, b
    add a, a                    ; CF = sign bit
    sbc a, a                    ; D = $FF / $00, the sign of the distance
    ld d, a
    inc de                      ; entries to advance = distance + 1
    ld l, (ix+1)
    ld h, (ix+2)                ; entryPtr
    ex de, hl
    add hl, hl
    add hl, hl                  ; count*4 (two's complement safe)
    add hl, de                  ; entryPtr + count*4
    ld (ix+1), l
    ld (ix+2), h
    xor a
    ld (ix+3), a
    ld (ix+4), a
    ret

h_isdone:                       ; 114: anything done since this table
    ld a, (isDone)              ; was entered - a PROCESS push is what
    sub 1                       ; clears isDone, so after PROCESS n the
    ret                         ; answer is that sub-process's alone
h_isndone:                      ; 115: the complement of ISDONE
    ld a, (isDone)
    or a
    ret z
    scf
    ret

h_redo:                         ; 108: restart the top table from its
    call eng_top_ix             ; first entry (own process number)
    ld hl, (ddbHeader+HDR_PROCLST)
    ld a, (ix+0)
    add hl, a                   ; + process*2 in 16 bits: tables 128-254
    add hl, a                   ; are legal (Z80N; carry cleared, unread)
    call data_save
    call rd_seek
    call rd_next
    ld e, a
    call rd_next
    ld d, a
    call data_restore           ; IX from the first eng_top_ix survives
    ld (ix+1), e                ; data_save/rd_seek/rd_next/data_restore;
    ld (ix+2), d                ; a second call would clobber DE first
    xor a
    ld (ix+3), a
    ld (ix+4), a
    ret

h_restart:                      ; 117: wipe the process stack and the
    xor a                       ; DOALL state; eng_step re-pushes PRO 0
    ld (procSP), a              ; from an empty stack
    ld (doallLevel), a
    ld (gfxDrawTarget), a       ; A=0: clear transient GFX 87/4 buffer
    ld (gfxRevealPend), a       ; state inline (not via
    ld (gfxRevealMode), a       ; gfx_drawtarget_clear). gfxLayerOrder is
                                ; NOT touched: RESTART re-runs process 0
                                ; every move, so the GFX 87/17 layer
                                ; order must survive it or an author
                                ; would need to re-issue it each turn.
                                ; It still resets at game start, part
                                ; switch and same-part LOAD/RAMLOAD.
    ld a, $FF
    ld (doallObj), a
    ret

h_doall:                        ; 85: B = location (255 = here). Error
    ld a, (doallObj)            ; 4 if a DOALL is already active on
    inc a                       ; this process (nesting not supported).
    jr z, .fresh
    ld a, 4
    jp err_raise
.fresh:
    ; V3 flag 53 bit 0: SET on entry ("nothing found yet"), CLEARED by
    ; eng_doall_next's .take on the first object. B is live across this
    ; call and eng_v3f53 preserves it.
    ld de, F53_DOALLNONE<<8 | $FF
    call eng_v3f53
    ld a, b
    ld (doallLoc), a
    ld a, (procSP)
    ld (doallLevel), a
    call eng_top_ix
    push ix                     ; IX+1..IX+4 = entryPtr, count word ->
    pop hl                      ; doallResE, doallResC (contiguous,
    inc hl                      ; engine.asm - asserted below)
    ld de, doallResE
    ld bc, 4
    ldir
    ld a, $FF
    ld (doallObj), a
    jp eng_doall_next
    ASSERT doallResC == doallResE+2

h_at:                           ; 0: flags[38] == B
    ld a, (flags+FLAG_PLAYER)
    cp b
    ret z
    scf
    ret
h_notat:                        ; 1
    ld a, (flags+FLAG_PLAYER)
    sub b
    sub 1
    ret
h_atgt:                         ; 2: player > B
    ld a, (flags+FLAG_PLAYER)
    scf
    sbc a, b
    ret
h_atlt:                         ; 3: player < B
    ld a, (flags+FLAG_PLAYER)
    cp b
    ccf
    ret
h_gt:                           ; 14: flags[B] > C
    ld h, high flags
    ld l, b
    ld a, (hl)
    scf
    sbc a, c
    ret
h_lt:                           ; 15: flags[B] < C
    ld h, high flags
    ld l, b
    ld a, (hl)
    cp c
    ccf
    ret
h_noteq:                        ; 79
    ld h, high flags
    ld l, b
    ld a, (hl)
    sub c
    sub 1
    ret
h_same:                         ; 76: flags[B] == flags[C]
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, (hl)
    cp d
    ret z
    scf
    ret
h_notsame:                      ; 80
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, (hl)
    sub d
    sub 1
    ret
h_bigger:                       ; 112: flags[B] > flags[C]
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, d
    scf
    sbc a, (hl)
    ret
h_smaller:                      ; 113: flags[B] < flags[C]
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, d
    cp (hl)
    ccf
    ret
h_adject1:                      ; 16
    ld a, (flags+FLAG_ADJ1)
    cp b
    ret z
    scf
    ret
h_adverb:                       ; 17
    ld a, (flags+FLAG_ADVERB)
    cp b
    ret z
    scf
    ret
h_prep:                         ; 68
    ld a, (flags+FLAG_PREP)
    cp b
    ret z
    scf
    ret
h_noun2:                        ; 69
    ld a, (flags+FLAG_NOUN2)
    cp b
    ret z
    scf
    ret
h_adject2:                      ; 70
    ld a, (flags+FLAG_ADJ2)
    cp b
    ret z
    scf
    ret
h_set:                          ; 47: flags[B] = 255
    ld h, high flags
    ld l, b
    ld (hl), 255
    ret
h_clear:                        ; 48
    ld h, high flags
    ld l, b
    ld (hl), 0
    ret
h_add:                          ; 71: flags[C] += flags[B], sat 255
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, (hl)
    add a, d
    jr nc, .st
    ld a, 255
.st:
    ld (hl), a
    ret
h_sub:                          ; 72: flags[C] -= flags[B], floor 0
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld a, (hl)
    sub d
    jr nc, .st
    xor a
.st:
    ld (hl), a
    ret
h_copyff:                       ; 125: flags[C] = flags[B]
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld l, c
    ld (hl), d
    ret
h_copybf:                       ; 126: flags[B] = flags[C]
    ld h, high flags
    ld l, c
    ld d, (hl)
    ld l, b
    ld (hl), d
    ret
h_print:                        ; 53: flags[B] as decimal
    ld h, high flags
    ld l, b
    ld a, (hl)
    call prn_dec8
    jp prn_flush
h_dprint:                       ; 27: 16-bit from flags[B], flags[B+1]
    ld h, high flags
    ld l, b
    ld a, (hl)
    inc l                       ; flags is 256-aligned: L wrap-safe
    ld h, (hl)
    ld l, a
    call prn_dec16
    jp prn_flush
h_space:                        ; 57
    ld c, ' '
    jp prn_char
h_hasat:                        ; 58: bit (B mod 8) of flags[B/8]
    call hasat_ptr
    and (hl)
    sub 1
    ret
h_hasnat:                       ; 59
    call hasat_ptr
    and (hl)
    ret z
    scf
    ret
; B = param -> HL = flags + (base - B/8), A = 1 << (B mod 8).
; DAAD numbers attributes DOWN from flag 59: attr 0-7 -> flag 59,
; 8-15 -> flag 58, WEARABLE 23 -> flag 57 bit 7, MOUSE 240 -> flag 29
; bit 0 (manual 1062-1069). Corrupts AF, B, E, HL.
;
; Under V3, flag 53 bit 1 (F53_ALTFLAGS) moves the whole bank to base
; 91 instead (flags 60-91, same 256 attributes). The bit-1 test is
; gated on V3 only: under V2 flag 53's low bits are the game's own
; property, so a V2 game is never affected. Shared by HASAT (58),
; HASNAT (59) and SETAT (124).
hasat_ptr:
    ld a, b
    and 7
    ld e, a                     ; E = bit index = B mod 8
    ld a, b
    rrca
    rrca
    rrca
    and $1F                     ; A = B / 8 (0..31)
    ld b, a
    ld a, 59
    ld hl, ddbVer
    bit 0, (hl)                 ; V3 database?
    jr z, .base
    ld hl, flags+FLAG_OFLAGS
    bit 1, (hl)                 ; F53_ALTFLAGS (bit number pinned below)
    ASSERT F53_ALTFLAGS == 1<<1
    jr z, .base
    ld a, 91                    ; alternative bank: flags 60-91
.base:
    sub b
    ld l, a                     ; HL = flags + (base - B/8)
    ld h, high flags
    ld a, 1
.shift:
    dec e
    ret m
    add a, a
    jr .shift

; --- DAAD V3 condacts (SP16 A2) ---
; 120/122/124 are live opcodes only in a version 3 database. The
; dispatcher no longer screens them (engine.asm), so each handler makes
; the version call itself and a version 2 database gets the E5 it
; always got, from here.
h_v3only:
    ld a, 5
    jp err_raise

h_setat:                        ; 124: B = attribute, C = operation
    ld hl, ddbVer
    bit 0, (hl)
    jr z, h_v3only
    call hasat_ptr              ; HL -> flag, A = bit mask, C survives
    ld e, a
    ld a, c
    and 3                       ; operation AND 3 (PRP013 V3-08)
    jr z, .clear                ; 0 = clear
    dec a
    jr z, .set                  ; 1 = set
    ld a, (hl)                  ; 2 and 3 both toggle
    xor e
    ld (hl), a
    ret
.set:
    ld a, (hl)
    or e
    ld (hl), a
    ret
.clear:
    ld a, e
    cpl
    and (hl)
    ld (hl), a
    ret

h_indir:                        ; 122: B = flag number
    ld hl, ddbVer
    bit 0, (hl)
    jr z, h_v3only
    ; Arm the dispatcher's one-shot arg2 override (engine.asm .noargs
    ; carries the full mechanism note). The references patch the second
    ; parameter byte of the following condact in the database image;
    ; NextDAAD's bytecode lives behind a banked read window, so nothing
    ; is written to it here.
    ld h, high flags
    ld l, b
    ld a, (hl)
    ld (indirArg2), a
    ld a, 1
    ld (indirValid), a
    ret
h_random:                       ; 95: flags[B] = 1..100
    call rng_next
    ld h, high flags
    ld l, b
    ld (hl), a
    ret
h_chance:                       ; 10: true B% of the time
    call rng_next
    ld c, a
    ld a, b
    cp c                        ; B - rand: carry clear (true) when rand <= B
    ret
; 16-bit xorshift (x ^= x<<7; x ^= x>>9; x ^= x<<8), seeded at
; eng_init_game, period 65535 (every non-zero state exactly once).
; Out A = (x*100)>>16 + 1 = 1..100, scaled over the full 16-bit state
; so each outcome draws 655 or 656 states (uniform), matching jdaad's
; floor(random()*100)+1. Preserves BC.
rng_next:
    push bc
    push de
    push hl
    call rng_step               ; resident, DI-bracketed: atomic vs a
                                ; hook's svc_random (same stream)
    ; --- A = (HL * 100) >> 16, then +1 -> 1..100 ---
    ld d, 100
    ld e, h
    mul d, e                    ; Z80N: DE = H*100 (the 2^8-weighted half)
    ld b, d
    ld c, e                     ; BC = H*100
    ld d, 100
    ld e, l
    mul d, e                    ; Z80N: DE = L*100
    ld a, d                     ; A = (L*100) >> 8
    add a, c                    ; ripple into the weighted half
    ld a, b
    adc a, 0                    ; A = (x*100) >> 16 = 0..99
    inc a                       ; 1..100
    pop hl
    pop de
    pop bc
    ret

; A = obj, C = new location. Flag 1 bookkeeping; error 2 on loc 255.
obj_move:
    ld e, a
    ld a, c
    cp 255
    jr nz, .legal
    ld a, 2
    jp err_raise
.legal:
    ld a, e
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jr nz, .oldnc
    ld a, (flags+FLAG_CARRIED_CT)
    dec a
    ld (flags+FLAG_CARRIED_CT), a
.oldnc:
    ld (hl), c
    ld a, c
    cp OBJ_CARRIED
    ret nz
    ld a, (flags+FLAG_CARRIED_CT)
    inc a
    ld (flags+FLAG_CARRIED_CT), a
    ret

; A = obj: update flags 51, 54..59.
; Flags 58/59 are the extended attribute pair. objTable holds it in
; flag order (engine.asm eng_load_objects, SP16 A5): +2 = attributes
; 8-15 -> flag 58, +3 = attributes 0-7 -> flag 59. HASAT n reads
; flags[59 - (n>>3)], so flag 59 must be the DDB word's LOW byte,
; which is the first byte in the file - the swap is done once, at
; load time. The sequential copy below is therefore correct as
; written and must stay in step with obj2_resolve (overlay1.asm).
obj_set_refs:
    ld (flags+FLAG_CUROBJ), a
    call obj_ptr
    ld a, (hl)
    ld (flags+FLAG_COLOC), a
    inc hl
    ld d, (hl)
    ld a, d
    and $3F
    ld (flags+FLAG_COWEI), a
    xor a
    bit 6, d
    jr z, .ncon
    ld a, 128
.ncon:
    ld (flags+FLAG_COCON), a
    xor a
    bit 7, d
    jr z, .nwr
    ld a, 128
.nwr:
    ld (flags+FLAG_COWR), a
    inc hl
    ld a, (hl)                  ; objTable+2 = attrs 8-15 -> flag 58
    ld (flags+FLAG_COATT), a
    inc hl
    ld a, (hl)                  ; objTable+3 = attrs 0-7  -> flag 59
    ld (flags+FLAG_COATT+1), a
    ret

; B = object: set the reference flags, then HL -> its objTable entry.
; Corrupts AF, DE, HL; preserves BC. Shared opener of GET/DROP/WEAR/
; REMOVE/PUTIN/TAKEOUT.
setrefs_ptr:
    ld a, b
    call obj_set_refs
    ld a, b
    jp obj_ptr

h_present:                      ; 4
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    ret z
    cp OBJ_WORN
    ret z
    ld e, a
    ld a, (flags+FLAG_PLAYER)
    cp e
    ret z
    scf
    ret
h_absent:                       ; 5
    call h_present
    ccf
    ret
h_worn:                         ; 6
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_WORN
    ret z
    scf
    ret
h_notworn:                      ; 7
    call h_worn
    ccf
    ret
h_carried:                      ; 8
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    ret z
    scf
    ret
h_notcarr:                      ; 9
    call h_carried
    ccf
    ret
h_isat:                         ; 55: obj B at loc C (255 = player's)
    ld a, b
    call obj_ptr
    ld a, c
    cp LOC_HERE
    jr nz, .fixed
    ld a, (flags+FLAG_PLAYER)
.fixed:
    cp (hl)
    ret z
    scf
    ret
h_isnotat:                      ; 88
    call h_isat
    ccf
    ret
h_destroy:                      ; 43
    ld a, b
    ld c, OBJ_NOT_CREATED
    jp obj_move
h_create:                       ; 44
    ld a, (flags+FLAG_PLAYER)
    ld c, a
    ld a, b
    jp obj_move
h_place:                        ; 46: obj B to loc C (255 = HERE)
    ld a, c
    inc a                       ; C == 255?
    jr nz, .go
    ld a, (flags+FLAG_PLAYER)
    ld c, a
.go:
    ld a, b
    jp obj_move
h_swap:                         ; 45: exchange locations
    ld a, b                     ; SP16 B11: a RAW exchange of the two
    call obj_ptr                ; location bytes. The manual is explicit
    push hl                     ; - "Flag 1 is not adjusted" - so
    ld a, c                     ; obj_move, which maintains the carried
    call obj_ptr                ; count, must NOT be used: swapping two
    pop de                      ; CARRIED objects went through obj_move
    ld a, (de)                  ; twice and decremented flag 1 twice with
    ld b, (hl)                  ; no matching increment, leaving it two
    ld (hl), a                  ; too low. Both references assign the two
    ld a, b                     ; location fields directly (jdaad.js:3172
    ld (de), a                  ; _SWAP, msx2daad do_SWAP) and then set
    ld a, c                     ; the referenced object to objno 2, which
    jp obj_set_refs             ; NextDAAD never did at all
h_setco:                        ; 56
    ld a, b
    jp obj_set_refs
h_puto:                         ; 102: current object -> loc B (255 = HERE)
    ld a, b
    inc a                       ; B == 255?
    jr nz, .go
    ld a, (flags+FLAG_PLAYER)
    ld b, a
.go:
    ld a, (flags+FLAG_CUROBJ)
    ld c, b
    jp obj_move
h_copyof:                       ; 119: flags[C] = loc(obj B)
    ld a, b
    call obj_ptr
    ld d, (hl)
    ld h, high flags
    ld l, c
    ld (hl), d
    ret
h_copyoo:                       ; 121: loc(obj C) = loc(obj B)
    ld a, b
    call obj_ptr
    ld d, (hl)
    ld b, c                     ; SP16 B12: keep objno 2 across the move -
    ld a, c                     ; obj_move preserves BC, and the manual's
    ld c, d                     ; "the currently referenced object is set
    call obj_move               ; to be Object objno 2" applies to COPYOO
    ld a, b                     ; as well. The move itself stays: jDAAD
    jp obj_set_refs             ; routes COPYOO through _PLACE, which does
                                ; adjust flag 1 (jdaad.js:4198)
h_copyfo:                       ; 123: loc(obj C) = flags[B]
    ld h, high flags
    ld l, b
    ld d, (hl)
    ld a, c
    ld c, d
    jp obj_move
h_whato:                        ; 100: find by Noun1/Adj1
    call obj_find_n1            ; carried, worn, here, anywhere - jDAAD's
    jr c, .none                 ; _WHATO keeps the anywhere pass and says
    jp obj_set_refs             ; so in its own comment (jdaad.js:3917)
.none:                          ; SP16 B17: not found = referencedObject
    ld a, $FF                   ; (NULLWORD), and msx2daad substitutes an
    ld (flags+FLAG_CUROBJ), a   ; all-zero nullObject there (daad_init.c
    ld hl, flags+FLAG_COLOC     ; :14, daad_objects.c:47), so flags 54-59
    ld b, 6                     ; are ZEROED - they used to be left
    xor a                       ; holding the PREVIOUS object's data
.zero:
    ld (hl), a
    inc hl
    djnz .zero
    ret

; The "scan every location" sentinel for D, below. Must differ from
; OBJ_CARRIED ($FE, nextdaad.inc:283) and every real/special location
; byte (0-254); $FF is the only value never stored in an object's
; location, so it is unambiguous with the object specials.
OBJ_ANYLOC      equ $FF

; D = location to scan (OBJ_ANYLOC = anywhere). Matcher on Noun1/Adj1.
; Out: A = object CF clear, else CF set. Preserves D and E.
; Corrupts AF, B, C, HL, IY.
;
; Selection rule, one pass:
;   FULL match    = noun equal AND (adjectives equal, or the object's
;                   adjective is 255 "takes any adjective"). Wins
;                   outright, returns immediately.
;   PARTIAL match = noun equal AND flags[35] == 255 (player named no
;                   adjective). The FIRST partial is remembered in C
;                   and the scan continues, since a full match later
;                   in the table still beats it; returned only if the
;                   scan ends without a full match.
; The AUTO- family and obj_find_n1 call this once per location in
; priority order, so a partial at a higher-priority location beats a
; full match at a lower one.
;
; obj2_resolve (overlay1.asm) resolves Noun2/Adj2 and stays lenient by
; design: it accepts object-adj 255, player-adj 255, or an exact pair,
; taking the first table-order candidate with no full-beats-partial
; preference. The two agree whenever there is a full match; they can
; differ only in which candidate a bare noun picks among several.
obj_find_pass:
    ld c, $FF                   ; C = remembered partial, $FF = none
    ld b, 0
.scan:
    ld a, (numObj)
    cp b
    jr z, .miss
 IFDEF DEBUG
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
 ENDIF
    ld a, b
    push de                     ; obj_ptr corrupts DE, preserves BC
    call obj_ptr
    pop de
    ld a, d
    cp OBJ_ANYLOC
    jr z, .anyloc
    cp (hl)
    jr nz, .next
.anyloc:
    push hl
    pop iy
    ld a, (flags+FLAG_NOUN1)
    cp (iy+4)
    jr nz, .next
    ld a, (flags+FLAG_ADJ1)
    cp (iy+5)
    jr z, .hit                  ; adjectives equal (both-255 included)
    inc a                       ; flags[35] == 255: no adjective given
    jr z, .partial
    ld a, (iy+5)
    inc a                       ; object adjective 255: takes any
    jr nz, .next
.hit:
    ld a, b
    or a
    ret
.partial:
    ld a, c
    inc a
    jr nz, .next                ; already holding one - keep the FIRST
    ld c, b
.next:
    inc b
    jr .scan
.miss:
    ld a, c
    inc a
    scf
    ret z                       ; no full match and no partial
    ld a, c                     ; no full match: the partial stands in
    or a
    ret

; WHATO's ordering: carried, worn, here, anywhere. The anywhere pass is
; correct for WHATO (documentation notwithstanding) but wrong for
; AUTOT, which calls auto_cwh instead.
obj_find_n1:
    ld d, OBJ_CARRIED
    call obj_find_pass
    ret nc
    ld d, OBJ_WORN
    call obj_find_pass
    ret nc
    ld a, (flags+FLAG_PLAYER)
    ld d, a
    call obj_find_pass
    ret nc
    ld d, OBJ_ANYLOC
    jp obj_find_pass

; E = system message: print it. No newline is added - the references
; add none either, and a message that wants one carries its own #n.
sysmsg:
    xor a                       ; kind 0 = system message
    jp print_msg

; E = system message: print + newline, exit the table as DONE.
refuse:
    call sysmsg
refuse_tail:                    ; message(s) already printed
    call prn_newline
    call h_newtext              ; SP16 B2: every refusal performs NEWTEXT
    ld a, 1                     ; before DONE (msx2daad's do_NEWTEXT() +
    jp eng_exit_table           ; do_DONE() tail), so a refused order kills
                                ; the rest of a compound sentence

; SP16 B9: the AUTO- family found nothing with its own search chain.
; Both references then make ONE further pass over ALL locations.
; Out: CF SET  = the noun is a real word that is not an object anywhere
;                in the game, so SM8 ("I can't do that") is printed;
;      CF CLEAR = the family's own "not here" message stands (the object
;                exists somewhere, or Noun1 was not in the vocabulary).
; Preserves BC (via the bracket below - obj_find_pass uses B as its
; loop counter and C as SP16 D1's partial-match slot) and E, which
; obj_find_pass never touches.
auto_probe:
    push bc
    ld d, OBJ_ANYLOC            ; obj_find_pass's own anywhere sentinel
    call obj_find_pass
    pop bc
    ret nc                      ; exists somewhere: family message
    ld a, (flags+FLAG_NOUN1)
    inc a                       ; 255 = not in the vocabulary -> 0
    scf
    ret nz                      ; real word, not an object: SM8
    ccf                         ; CF clear: family message
    ret

; E = the family's "not here" message. B9 tail shared by AUTOG/AUTOD/
; AUTOW/AUTOR/AUTOP (AUTOT's family message is a composite - see there).
auto_end:
    call auto_probe
    jr nc, refuse
    ld e, 8
    jr refuse

; CF SET while there is still room for one more carried object
; (flag 1 < flag 37). Corrupts AF and E.
hands_room:
    ld a, (flags+FLAG_MAXCARR)
    ld e, a
    ld a, (flags+FLAG_CARRIED_CT)
    cp e
    ret

; B = the object about to be picked up. CF SET when carried + worn +
; that object would exceed flag 52. The running total saturates at 255
; so an overloaded total cannot pass the check. Corrupts AF/DE,
; preserves BC. Shared by GET and TAKEOUT (both reference interpreters
; run the identical test in both).
weight_bust:
    ld a, b
    call obj_weight_of          ; preserves BC; E comes back as 10, dead here
    ld d, a
    push bc
    push de
    call weight_total
    pop de
    pop bc
    add a, d
    jr nc, .noovf
    ld a, 255
.noovf:
    ld e, a
    ld a, (flags+FLAG_STRENGTH)
    cp e                        ; CF set = strength < total = too heavy
    ret

; E = leading system message, C = the container object. Prints the
; PUTIN/TAKEOUT composite "<SMe><container name><SM51>" with NO inserted
; spaces: the original ZX interpreters (EN and ES) print the three parts
; back to back and the stock SM44/45/52 texts carry their own trailing
; space (owner ruling 2026-09-22; msx2daad/jDAAD insert one, and
; double-space the stock text). The name goes through the same objname
; path the '_' escape uses, which reads flag 51, so flag 51 holds the
; CONTAINER for the duration and is put back afterwards - the
; referenced object is game-visible state and must not shift.
msg_in_obj:
    push bc
    call sysmsg
    pop bc
    ld a, (flags+FLAG_CUROBJ)
    push af
    ld a, c
    ld (flags+FLAG_CUROBJ), a
    ld a, '_'
    call objname_print
    pop af
    ld (flags+FLAG_CUROBJ), a
    ld e, 51
    jp sysmsg

; Cancel any active DOALL loop (GET/TAKEOUT SM27 capacity refusal,
; manual 1137-1140, 1270-1273). Mirrors the DOALL-completion clear in
; eng_doall_next. Corrupts AF.
doall_cancel:
    xor a
    ld (doallLevel), a
    dec a                       ; $FF
    ld (doallObj), a
    ret

h_ok:                           ; 23: SM15 then DONE, and NOTHING else.
    ld e, 15                    ; This is deliberately NOT refuse: since
    call sysmsg                 ; SP16 B2 refuse also performs NEWTEXT,
    call prn_newline            ; and OK is the standard tail of a
    ld a, 1                     ; SUCCESSFUL response entry - killing the
    jp eng_exit_table           ; compound tail there would silently drop
                                ; the second half of "PUSH BUTTON AND GO
                                ; NORTH". Both references print SM15 and
                                ; DONE only (daad_condacts.c do_OK,
                                ; jdaad.js _OK), as does the manual.

h_get:                          ; 40
    call setrefs_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jr z, .have
    cp OBJ_WORN
    jr z, .have
    ld e, a
    ld a, (flags+FLAG_PLAYER)
    cp e
    jr nz, .nothere
.wtest:                         ; B = object. Shared with TAKEOUT (h_takeout)
    call weight_bust            ; SP16 B3: WEIGHT is tested BEFORE the
    jr nc, .cap                 ; hands-full count, not after it - the
    ld e, 43                    ; order both references use
    jp refuse
.cap:
    call hands_room
    jr c, .take
    call doall_cancel           ; SM27 refusal cancels any DOALL
    ld e, 27
    jp refuse
.take:
    ld a, b
    ld c, OBJ_CARRIED
    call obj_move
    ld e, 36                    ; SP16 B1: "I now have the _."
    jp sysmsg
.have:
    ld e, 25
    jp refuse
.nothere:
    ld e, 26
    jp refuse

h_drop:                         ; 41
    call setrefs_ptr
    ld a, (hl)                  ; HL stays on the location byte for the
    cp OBJ_WORN                 ; at-location test below (doc 01: cp (hl)
    jr z, .worn                 ; is 1 byte against a 3-byte reload)
    cp OBJ_CARRIED
    jr z, .drop
    ld a, (flags+FLAG_PLAYER)   ; SP16 B4: an object lying at the
    ld e, 28                    ; player's location answers SM49, not
    cp (hl)                     ; the generic SM28
    jr nz, .no
    ld e, 49
.no:
    jp refuse
.drop:
    ld a, (flags+FLAG_PLAYER)
    ld c, a
    ld a, b
    call obj_move
    ld e, 39                    ; SP16 B1: "I've dropped the _."
    jp sysmsg
.worn:
    ld e, 24
    jp refuse

h_wear:                         ; 42
    call setrefs_ptr
    ld d, (hl)                  ; SP16 B5: reference order is at-location,
    ld a, (flags+FLAG_PLAYER)   ; worn, not-carried, not-wearable - the
    cp d                        ; wearable test came FIRST here, which
    jr z, .here                 ; hid SM49 completely
    ld a, d
    cp OBJ_WORN
    jr z, .already
    cp OBJ_CARRIED
    jr nz, .nothave
    inc hl
    bit 7, (hl)
    jr z, .cant
    ld a, b
    ld c, OBJ_WORN
    call obj_move
    ld e, 37                    ; SP16 B1: "I'm now wearing the _."
    jp sysmsg
.here:
    ld e, 49
    jp refuse
.cant:
    ld e, 40
    jp refuse
.already:
    ld e, 29
    jp refuse
.nothave:
    ld e, 28
    jp refuse

h_remove:                       ; 39
    call setrefs_ptr
    ld d, (hl)                  ; SP16 B6: reference order is carried-or-
    ld a, d                     ; at-location (SM50), not-worn (SM23),
    cp OBJ_CARRIED              ; not-wearable, hands-full. SM23 was
    jr z, .nowear               ; unreachable before this
    ld a, (flags+FLAG_PLAYER)
    cp d
    jr z, .nowear
    ld a, d
    cp OBJ_WORN
    jr nz, .notworn
    inc hl
    bit 7, (hl)
    jr z, .cant
    call hands_room
    jr c, .rem
    ld e, 42
    jp refuse
.rem:
    ld a, b
    ld c, OBJ_CARRIED
    call obj_move
    ld e, 38                    ; SP16 B1: "I've removed the _."
    jp sysmsg
.cant:
    ld e, 41
    jp refuse
.notworn:
    ld e, 23
    jp refuse
.nowear:
    ld e, 50
    jp refuse

; AUTO*: resolve Noun1 with the classic priority, delegate.
h_autog:                        ; 31: here, carried, worn
    ld a, (flags+FLAG_PLAYER)
    ld d, a
    call obj_find_pass
    jr nc, .go
    ld d, OBJ_CARRIED
    call obj_find_pass
    jr nc, .go
    ld d, OBJ_WORN
    call obj_find_pass
    jr nc, .go
    ld e, 26
    jp auto_end                 ; SP16 B9
.go:
    ld b, a
    jp h_get
h_autod:                        ; 32: carried, worn, here
    call auto_cwh
    jr nc, .go
    ld e, 28
    jp auto_end                 ; SP16 B9
.go:
    ld b, a
    jp h_drop
h_autow:                        ; 33: carried, worn, here
    call auto_cwh
    jr nc, .go
    ld e, 28
    jp auto_end                 ; SP16 B9
.go:
    ld b, a
    jp h_wear
h_autor:                        ; 34: worn, carried, here
    ld d, OBJ_WORN
    call obj_find_pass
    jr nc, .go
    ld d, OBJ_CARRIED
    call obj_find_pass
    jr nc, .go
    ld a, (flags+FLAG_PLAYER)
    ld d, a
    call obj_find_pass
    jr nc, .go
    ld e, 23
    jp auto_end                 ; SP16 B9
.go:
    ld b, a
    jp h_remove
auto_cwh:                       ; carried, worn, here ordering
    ld d, OBJ_CARRIED
    call obj_find_pass
    ret nc
    ld d, OBJ_WORN
    call obj_find_pass
    ret nc
    ld a, (flags+FLAG_PLAYER)
    ld d, a
    jp obj_find_pass

h_dropall:                      ; 30
    ld b, 0
.scan:
    ld a, (numObj)
    cp b
    ret z
 IFDEF DEBUG
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
 ENDIF
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jr z, .drop
    cp OBJ_WORN
    jr nz, .next
.drop:
    ld a, (flags+FLAG_PLAYER)
    ld c, a                     ; C is dead in h_dropall (B is the counter)
    ld a, b
    call obj_move               ; A, E, HL and flags; B untouched
.next:
    inc b
    jr .scan

h_putin:                        ; 90: carried obj B -> container loc C
    call setrefs_ptr
    ld a, (hl)                  ; SP16 B7: worn -> SM24, at the player's
    cp OBJ_WORN                 ; location -> SM49, anywhere else ->
    jr z, .worn                 ; SM28 (only SM28 existed before)
    cp OBJ_CARRIED
    jr z, .go
    ld a, (flags+FLAG_PLAYER)
    ld e, 28
    cp (hl)
    jr nz, .no
    ld e, 49
.no:
    jp refuse
.worn:
    ld e, 24
    jp refuse
.go:
    push bc
    ld a, b
    call obj_move               ; C = the container, flag 1 decremented
    pop bc                      ; by obj_move's own carried-source rule
    ld e, 44                    ; SP16 B1: "The _ is in the <name>."
    jp msg_in_obj
h_takeout:                      ; 91: obj B out of container loc C
    call setrefs_ptr
    ld a, (hl)                  ; SP16 B8: full reference ladder
    cp OBJ_WORN
    jr z, .have
    cp OBJ_CARRIED
    jr z, .have
    ld d, a                     ; D = the object's location
    ld a, (flags+FLAG_PLAYER)
    ld e, 45                    ; at the player's location, not in the
    cp d                        ; container: "The _ isn't in the <name>."
    jr z, .named
    ld a, d
    cp c
    ld e, 52                    ; nowhere near the container: "There
    jr nz, .named               ; isn't one of those in the <name>."
    jp h_get.wtest              ; weight, hands, take: byte-identical to GET's tail
.named:
    call msg_in_obj
    jp refuse_tail              ; composite already printed: newline,
.have:                          ; NEWTEXT, DONE - refuse's own tail
    ld e, 25
    jp refuse
h_autop:                        ; 104: B = container loc; find Noun1.
    push bc                     ; obj_find_pass clobbers B (its loop
    call auto_cwh               ; counter) - preserve the container
    pop de                      ; D = container location (flags kept)
    jr c, .none
    ld c, d                     ; C = container loc, B = object
    ld b, a
    jp h_putin
.none:
    ld e, 28
    jp auto_end                 ; SP16 B9
h_autot:                        ; 105: container first, then usual
    ld a, b                     ; B == 255 -> the player's location, the
    inc a                       ; same translation h_place and h_puto do
    jr nz, .go                  ; and the one jDAAD's _AUTOT opens with
    ld a, (flags+FLAG_PLAYER)   ; ("if (Parameter1 == LOC_HERE) ..."). It
    ld b, a                     ; also keeps 255 out of D, which is now
.go:                            ; obj_find_pass's anywhere sentinel
    push bc
    ld d, b
    call obj_find_pass          ; preserves D, clobbers B
    pop de                      ; D = container location
    jr nc, .found
    push de
    call auto_cwh               ; loads D per pass - bracket it. SP16 B10:
    pop de                      ; carried, worn, here and STOP. This used
    jr c, .none                 ; to be obj_find_n1, whose fourth pass
                                ; matches at ANY location - neither
                                ; reference has an anywhere leg in AUTOT's
                                ; search chain (jdaad.js:3991 _AUTOT), so
                                ; NextDAAD could take an object out of a
                                ; container the player was nowhere near.
                                ; jDAAD's own anywhere pass there is the
                                ; MESSAGE decision only, which is what
                                ; auto_probe already does at .none below.
.found:
    ld c, d
    ld b, a
    jp h_takeout
.none:                          ; SP16 B9, composite family message:
    ld c, d                     ; SM52 + the container's name + SM51
    ld e, 52
    call auto_probe
    jr c, .cant
    call msg_in_obj
    jp refuse_tail
.cant:
    ld e, 8
    jp refuse

; A = obj number -> A = true weight including container contents.
; Recursive core with an explicit depth budget in E.
obj_weight_of:
    ld e, 10
owf_core:
    push bc
    push de
    ld c, a                     ; C = this object's number
    call obj_ptr
    inc hl
    ld d, (hl)                  ; attrib byte
    ld a, d
    and $3F
    ld b, a                     ; B = running total (LD does not touch F,
    jr z, .fin                  ; so the AND's Z still stands here). SP16
                                ; B29, the manual's "magic bag": a
                                ; container of ZERO own weight transmits
                                ; zero for its contents too, so the
                                ; recursion is skipped outright
                                ; (msx2daad _sumLocation only descends
                                ; when w > 0, daad_getObjectWeight.c)
    bit 6, d
    jr z, .fin
    pop de
    push de
    ld a, e
    dec a
    jr z, .fin                  ; depth exhausted
    ld e, a
    ld d, 0                     ; D = child index
.scan:
    ld a, (numObj)
    cp d
    jr z, .fin
 IFDEF DEBUG
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
 ENDIF
    ld a, d
    push de                     ; D = child index, E = depth; BC survives obj_ptr
    call obj_ptr
    ld a, (hl)
    pop de
    cp c                        ; located "at" this container's number?
    jr nz, .next
    push bc
    push de
    ld a, d
    call owf_core
    pop de
    pop bc
    add a, b
    jr nc, .acc
    ld a, 255
.acc:
    ld b, a
.next:
    inc d
    jr .scan
.fin:
    ld a, b
    pop de
    pop bc
    ret

; Total carried+worn weight.
weight_total:
    ld bc, 0                    ; SP14c OV0-1
.scan:
    ld a, (numObj)
    cp b
    jr z, .done
 IFDEF DEBUG
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
 ENDIF
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jr z, .add
    cp OBJ_WORN
    jr nz, .next
.add:
    ld a, b
    call obj_weight_of          ; preserves BC (owf_core brackets)
    add a, c
    jr nc, .st
    ld a, 255
.st:
    ld c, a
.next:
    inc b
    jr .scan
.done:
    ld a, c
    ret

h_weigh:                        ; 89: flags[C] = weight of obj B
    ld a, b
    call obj_weight_of          ; preserves BC; C = flag number, read below
    ld d, a
    ld h, high flags
    ld l, c
    ld (hl), d
    ret
h_weight:                       ; 94: flags[B] = carried+worn total
    push bc
    call weight_total
    pop bc
    ld d, a
    ld h, high flags
    ld l, b
    ld (hl), d
    ret
h_ability:                      ; 93
    ld a, b
    ld (flags+FLAG_MAXCARR), a
    ld a, c
    ld (flags+FLAG_STRENGTH), a
    ret
h_reset:                        ; 127: initial positions
    ld c, 1
    jp eng_load_objects

h_desc:                         ; 19: location B, checked
    ld a, (ddbHeader+HDR_NUMLOC)
    dec a
    cp b
    jr nc, .ok
    ld a, 1                     ; SP16 B30: a bad LOCATION is error 1,
                                 ; not error 7 ("bad message") - the
                                 ; message printers at :94 and :110 keep
                                 ; 7 because theirs really is a message
                                 ; number. msx2daad's printLocationMsg
                                 ; raises errorCode(1) here
                                 ; (daad_msg.c:76).
    jp err_raise
.ok:
    ld e, b
    ld a, 2
    jp print_msg
h_listobj:                      ; 60
    ld a, LOC_HERE
    ld c, 1
    jp list_at
h_listat:                       ; 74: B = location (arg1; DRC only
                                 ; accepts a flag-sourced location via
                                 ; @flag, which the dispatcher's generic
                                 ; indirection already resolves into B)
    ld a, b
    ld c, 0
    jp list_at
h_window:                       ; 78
    ld a, b                     ; SP16 B28: an out-of-range window is
    cp WINDOW_COUNT             ; IGNORED - the current window stays
    ret nc                      ; selected. Masking with 7 made
                                 ; WINDOW 8 select window 0, which is a
                                 ; silently wrong window rather than a
                                 ; no-op. Both references bail:
                                 ; msx2daad "if (window >= WINDOWS_NUM)
                                 ; return;" (daad_condacts.c:1674),
                                 ; jDAAD "if (Parameter1 < NUM_WINDOWS)"
                                 ; (jdaad.js:3455). win_select's own
                                 ; internal AND 7 is now unreachable
                                 ; from here but stays - it has other
                                 ; callers.
    ld (flags+FLAG_CURWIN), a
    jp win_select
h_mode:                         ; 81
    ld a, WIN_FLAGS
    call win_field
    ld (hl), b
    ret
h_winat:                        ; 82: line B, col C, clamped; size
                                 ; re-clamped against the new origin
    ld a, b
    cp TM_ROWS
    jr c, .rok
    ld a, TM_ROWS-1
.rok:
    ld b, a
    ld a, (tmCols)
    dec a                       ; highest valid column
    cp c
    jr c, .cok                  ; col out of range: A already = max
    ld a, c                     ; in range: keep it
.cok:
    ld c, a
    ld a, WIN_X
    call win_field
    ld (hl), c
    inc hl
    ld (hl), b
    ld a, (tmCols)
    sub c
    ld e, a
    ld a, WIN_W
    call win_field
    ld a, (hl)
    cp e
    jr c, .wok
    ld (hl), e
.wok:
    ld a, TM_ROWS
    sub b
    ld e, a
    ld a, WIN_H
    call win_field
    ld a, (hl)
    cp e
    jr c, .hok
    ld (hl), e
.hok:
    jp win_home
h_winsize:                      ; 107: height B, width C, min 1, clamped
    ld a, b
    or a
    jr nz, .h1
    inc a
.h1:
    ld b, a
    ld a, c
    or a
    jr nz, .w1
    inc a
.w1:
    ld c, a
    ld a, WIN_Y
    call win_field
    ld e, (hl)
    ld a, TM_ROWS
    sub e
    cp b
    jr nc, .hok
    ld b, a
.hok:
    ld a, WIN_X
    call win_field
    ld e, (hl)
    ld a, (tmCols)
    sub e
    cp c
    jr nc, .wok
    ld c, a
.wok:
    ld a, WIN_W
    call win_field
    ld (hl), c
    inc hl
    ld (hl), b
    jp win_home
h_saveat:                       ; 97
    ld a, WIN_CURX
    call win_field
    ld a, (hl)
    ld (savedCurX), a
    inc hl
    ld a, (hl)
    ld (savedCurY), a
    ret
h_backat:                       ; 98
    call prn_flush
    ld a, WIN_CURX
    call win_field
    ld a, (savedCurX)
    ld (hl), a
    inc hl
    ld a, (savedCurY)
    ld (hl), a
    ret
h_printat:                      ; 99: line B, col C inside the window
    push bc                     ; prn_flush corrupts all regs; B/C are
    call prn_flush               ; still needed below
    pop bc
    ld a, WIN_H
    call win_field
    ld a, (hl)
    dec a
    cp b
    jr nc, .rok
    ld b, a
.rok:
    ld a, WIN_W
    call win_field
    ld a, (hl)
    dec a
    cp c
    jr nc, .cok
    ld c, a
.cok:
    ld a, WIN_CURX
    call win_field
    ld (hl), c
    inc hl
    ld (hl), b
    ret
h_tab:                          ; 118: column B, row kept
    push bc                     ; prn_flush corrupts all regs; B is
    call prn_flush               ; still needed below
    pop bc
    ld c, b
    ld a, WIN_W
    call win_field
    ld a, (hl)
    dec a
    cp c
    jr nc, .cok
    ld c, a
.cok:
    ld a, WIN_CURX
    call win_field
    ld (hl), c
    ret
h_centre:                       ; 109
    ld a, WIN_W
    call win_field
    ld a, (tmCols)
    sub (hl)
    srl a
    ld e, a
    ld a, WIN_X
    call win_field
    ld (hl), e
    ret
h_paper:                        ; 65: the full 0-255 the database carries.
    ld a, WIN_PAPER             ; DRC declares PAPER as a generic value
    call win_field              ; checked only against 0-255, so an author
    ld (hl), b                  ; can select any of the 256 logical colours
    jp win_attr_resolve         ; pal_colour computes (no colour table).
h_ink:                          ; 66
    ld a, WIN_INK
    call win_field
    ld (hl), b
    jp win_attr_resolve
; 67 BORDER: B AND 7 still selects the classic ULA colour, and the
; out ($FE) write is kept so BORDER retains its classic meaning if the
; ULA layer is ever re-enabled - but txt_init disables that layer at
; text-mode takeover (NR $68 bit 7), so the write is invisible; what
; actually shows around the screen is the global fallback colour
; NR $4A - output wherever tilemap and Layer 2 are both transparent,
; i.e. the whole true border region plus any gaps a 256-wide-art
; layout leaves uncovered. So BORDER also resolves B through the full
; 0-255 logical palette (pal_colour; dadPalette is only the source for
; logical entries 0-15) and programs NR $4A with the resulting
; RRRGGGBB (hw_init boots the register black, this overrides at
; runtime). Corrupts AF, DE, HL.
h_border:                       ; 67
    ld a, b
    and 7
    out ($FE), a
    ld a, b
    call pal_colour
    ld a, d
    nextreg NR_FALLBACK, a
    ret
; --- key decoder ---
; Half-row scan -> ASCII. Unshifted; letters lowercase; digits; space;
; enter = 13. 0 = nothing pressed. Corrupts AF, BC, DE, HL.
key_scan:
    ld hl, keyRows
    ld d, 8
.row:
    ld a, (hl)
    inc hl
    ld b, a
    ld c, $FE
    in a, (c)
    cpl
    and $1F
    ; held shift keys must be invisible: caps is row $FE bit 0, symbol
    ; shift row $7F bit 1. A capital typed as a caps+letter chord
    ; otherwise wins the scan as the caps key itself (char 0), so
    ; QUIT/END's Y/N confirm rejected shifted replies. Scratch in C
    ; (reloaded per row) - E must survive no-hit scans for callers.
    ld c, a
    ld a, b
    cp $FE
    jr nz, .n1
    res 0, c
.n1:
    cp $7F
    jr nz, .n2
    res 1, c
.n2:
    ld a, c
    or a
    jr nz, .hit
    add hl, 5                   ; Z80N ADD HL,nn - SP14c OV0-2 (BC dead
                                 ; here; byte-neutral, -5T/row missed)
    dec d
    jr nz, .row
    xor a
    ret
.hit:
    ld e, a
.bit:
    srl e
    jr c, .found
    inc hl
    jr .bit
.found:
    ld a, (hl)
    ret

keyRows:                        ; port MSB, then bits 0-4's chars
    db $FE, 0,  'z','x','c','v'
    db $FD, 'a','s','d','f','g'
    db $FB, 'q','w','e','r','t'
    db $F7, '1','2','3','4','5'
    db $EF, '0','9','8','7','6'
    db $DF, 'p','o','i','u','y'
    db $BF, 13, 'l','k','j','h'
    db $7F, ' ', 0, 'm','n','b'

; Block for a fresh press (waits for prior release first).
key_wait_char:
.settle:
    call key_scan
    or a
    jr nz, .settle
.press:
    call key_scan
    or a
    jr z, .press
    ld (kwcChar), a             ; NOT a register: key_scan's hit path
.release:                       ; shreds E on every pass while the key
    call key_scan               ; is still held, so the old ld e, a
    or a                        ; stash read back 0 after release
    jr nz, .release
    ld a, (kwcChar)
    ret
kwcChar: db 0

; --- interaction / movement / stub condacts ---
h_inkey:                        ; 111: condition; key -> flag 60
    call key_scan
    ; Flag 61 (fKey2, the IBM extended code) is cleared whenever flag
    ; 60 is written, following jDAAD's _INKEY2 (writes both flags on
    ; both the hit and miss path). key_scan returns 0 for "no key", so
    ; the code below writes both flags unconditionally either way.
    ; This is the ONLY writer of flag 60.
    ld hl, flags+FLAG_KEY1      ; doc 07 (a): flags is ALIGN 256, so
    ld (hl), a                  ; the pair is one INC L apart and the
    inc l                       ; store leaves A and F alone for the
    ld (hl), 0                  ; condition test below
    sub 1
    ret
h_anykey:                       ; 24
    ld e, 16
    xor a
    call print_msg
    ld e, $04                   ; ANYKEY timeout arm bit
    call wait_key_timeout
    jp prn_reset_lines
h_pause:                        ; 35: B frames, 0 = 256
    ; Under V3, PAUSE 0 is GETKEY: block for a keypress and store it
    ; in flags 60/61. DRB compiles the GETKEY keyword to PAUSE 0 and
    ; rejects it outside -v3. No prn_reset_lines on this arm: GETKEY
    ; is a value read, not a pager pause like ANYKEY.
    ld a, b
    or a
    jr nz, .timed
    ld hl, ddbVer
    bit 0, (hl)
    jr z, .timed                ; V2: 0 still means 256 frames
    call key_wait_char
    ld hl, flags+FLAG_KEY1      ; flags is ALIGN 256: the pair is one
    ld (hl), a                  ; INC L apart (doc 07 (a))
    inc l
    ld (hl), 0
    ret
.timed:
    ld a, (frameCounter)
    ld e, a
.wait:
    ld a, (frameCounter)
    cp e
    jr z, .wait
    ld e, a
    djnz .wait
    jp prn_reset_lines

; E = SM number -> D = first decoded character (token-aware).
; rd_push, data_save and rd_pop preserve DE; data_restore corrupts A only.
sm_first_char:
    call rd_push
    call data_save
    xor a                       ; kind 0
    call msg_seek
    jr c, .none
    call rd_next
    cpl
    bit 7, a
    jr z, .plain
    and $7F
    push af
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
    call rd_next
    and $7F
.plain:
    ld d, a
    call data_restore
    call rd_pop
    ret
.none:
    ld a, 'Y'                   ; missing SM: default to Y
    jr .plain

; Read one LINE of confirmation input: echo each printable character,
; ENTER ends it, and the FIRST printable character is the answer.
; Out: A = that character, or 0 for an empty line. Corrupts all.
;
; The original ZX interpreter reads a full line at a confirmation
; prompt (echoing each character, acting only on ENTER), not a single
; keypress; jDAAD and msx2daad agree. This reproduces that: the input
; is a LINE, nothing acts until ENTER, and the first character decides.
; Unlike inp_edit (overlay1) this has no in-line editing (no backspace,
; no recall) - there is no resident trampoline to reach inp_edit from
; overlay0.
confirm_read:
    xor a
    ld (cfmFirst), a
    ; Both locks, for the same two reasons inp_edit takes them (see its
    ; head). wrapLock: prn_char otherwise BUFFERS printable non-space
    ; characters into wrapBuf to wrap whole words (print.asm), so the
    ; reply would not appear until the newline flushed it - the echo has
    ; to be live, because live is what the original does
    ; ("Are you sure?>Y" BEFORE enter). moreLock: without it a long
    ; reply can push the line count over the More... pager, which would
    ; then eat a keypress in the middle of a confirmation.
    ld a, 1
    ld (wrapLock), a
    ld (moreLock), a
.key:
    call key_wait_char
    cp 13
    jr z, .done
    cp ' '
    jr c, .key                  ; other controls: ignored, not echoed
    call fold_upper             ; fold to upper before BOTH the echo and
                                ; the latch: key_scan's map is lowercase
                                ; only; classic DAAD input reads all-caps
    ld c, a                     ; C = the char, for prn_char
    ld a, (cfmFirst)
    or a
    jr nz, .echo
    ld a, c
    ld (cfmFirst), a            ; latch the first printable character
.echo:
    call prn_char
    jr .key
.done:
    call prn_newline            ; the ENTER moves off the reply line -
                                 ; still under moreLock, so it cannot
                                 ; trip the pager on the way out
    xor a
    ld (wrapLock), a
    ld (moreLock), a
    ld a, (cfmFirst)
    ret
cfmFirst: db 0

; Shared confirmation: prints SM E, reads a line, folds case, compares
; its first character to the first char of SM C. In: E = prompt SM,
; C = compare SM. Out: ZF set = reply starts with SM C's first char.
; An empty line never confirms (A = 0 matches no system message's first
; character), which is jdaad's `if (inputBuffer != '')` guard.
; Corrupts all.
confirm:
    push bc                     ; C = compare SM survives print/read/reset
    xor a
    call print_msg
    call prn_newline
    call confirm_read
    push af                     ; save the reply's first char
    call prn_reset_lines
    pop af                      ; A = reply's first char
    pop bc                      ; C = compare SM
    ld e, c
    push af
    call sm_first_char          ; D = compare SM's first char
    pop af
    call fold_upper
    cp d
    ret

; A = char. a-z folded to A-Z, anything else unchanged. Corrupts AF.
; overlay1 has a byte-identical twin: both overlays share MMU slot 7 and
; are never mapped together, so the two copies cannot be merged.
fold_upper:
    cp 'a'
    ret c
    cp 'z'+1
    ret nc
    sub 32
    ret

h_quit:                         ; 20: condition - Y (SM30) confirms quit
    ld e, 12
    ld c, 30
    call confirm
    scf
    ret nz
    call eng_set_done
    or a
    ret
h_end:                          ; 21: a reply starting with N (SM31) =
    ld e, 13                    ; exit to OS, anything else = restart.
                                 ; Reads a line via confirm (see
                                 ; confirm_read), same as QUIT.
    ld c, 31
    call confirm
    jr z, .off
    ld c, 0
    call eng_init_game          ; clears procSP itself (engine.asm)
    ret
.off:
    jr h_exit.hard              ; same silence-then-reset tail
h_exit:                         ; 110: 0 = hard reset, else full restart
    ld a, b
    or a
    jr z, .hard
    ; A non-zero EXIT restarts the whole game, unlike RESTART which
    ; only restarts processing: it clears and resets windows too.
    ; eng_init_game clears all 256 flags, restores their defaults,
    ; rebuilds the object table from the DDB and recounts flag 1, then
    ; selects window 0 and empties the process stack; windows_init
    ; re-establishes the eight windows' geometry on top of that.
    ; h_restart's DOALL wipe completes the RESTART half, same as
    ; h_end's restart branch above.
    xor a
    ld (wrapLen), a             ; drop any half-buffered word BEFORE the
                                 ; window records are reset - win_select
                                 ; (which windows_init falls into)
                                 ; flushes through curWin, and a restart
                                 ; discards pending display state rather
                                 ; than spilling it at 0,0
    call windows_init           ; also selects window 0
    call eng_init_game          ; clears procSP and doallObj itself
    xor a                       ; (engine.asm:48-53); doallLevel is the
    ld (doallLevel), a          ; one piece of DOALL state it does NOT
    ret                         ; touch, so h_restart's wipe needs only
                                 ; this much on top to be complete
.hard:
    di                          ; silence the PSGs before the reset -
    call audio_init             ; the AY keeps sounding its last note
    nextreg 2, 1                ; through nextreg 2,1 otherwise
    jr $
h_goto:                         ; 37
    ld a, b
    ld (flags+FLAG_PLAYER), a
    ret
h_move:                         ; 106: condition-like action. B = flag
                                 ; holding the location to search (in/out);
                                 ; verb comes from flag 33. Verb is stashed
                                 ; to moveVerb (not kept live in D) because
                                 ; rd_seek clobbers DE across the two seeks
                                 ; below; rd_next (used in .pair) preserves
                                 ; DE, so D is safe once reloaded after the
                                 ; last rd_seek.
                                 ;
                                 ; MOVE marks the table done on all three
                                 ; exits (verb bail, .match, .nomatch),
                                 ; following msx2daad. Stamped once at
                                 ; entry instead of three times: nothing
                                 ; between here and the exits can abort
                                 ; the handler or clear isDone, so
                                 ; entry-once and exit-thrice are the same
                                 ; set for fewer bytes.
    call eng_set_done
    ld a, (flags+FLAG_VERB)
    cp 14
    ccf
    ret c
    ld (moveVerb), a
    ld h, high flags
    ld l, b                     ; HL = flags + B
    ld a, (hl)                  ; A = flags[B] (location to search)
    push hl                     ; save flags+B pointer for the write-back
    ld hl, (ddbHeader+HDR_CONLST)
    add hl, a
    add hl, a                   ; HL = HDR_CONLST + location*2 (Z80N)
    call data_save
    call rd_seek
    call rd_next
    ld e, a
    call rd_next
    ld d, a                     ; DE = absolute connection-list pointer
    ex de, hl
    call rd_seek
    ld a, (moveVerb)
    ld d, a                     ; D = verb, safe now (only rd_next below)
.pair:
    call rd_next
    cp $FF
    jr z, .nomatch
    cp d
    jr z, .match
    call rd_next
    jr .pair
.match:
    call rd_next
    ld c, a                     ; C = destination location
    call data_restore
    pop hl                      ; HL = flags+B pointer
    ld (hl), c
    or a                        ; (done already stamped at entry)
    ret
.nomatch:
    call data_restore
    pop hl
    scf
    ret
; SYNONYM verb noun (36). The substitution is version-independent, the
; done-marking is not: under V2, SYNONYM marks DONE; under V3 it does
; not. cprops row 36 is condition-typed (engine.asm) so the handler can
; mark done itself rather than un-stamping an action row's dispatcher
; stamp, which would also wipe an earlier condact's done in the same
; entry. Both arms return CF clear, so the entry continues either way.
; ISDONE reads the accumulating isDone cell, so the V2/V3 split is
; visible within a single entry.
h_synonym:                      ; 36
    ld a, b
    cp 255
    jr z, .noun
    ld (flags+FLAG_VERB), a
.noun:
    ld a, c
    cp 255
    jr z, .done
    ld (flags+FLAG_NOUN1), a
.done:
    ld a, (ddbVer)
    rra
    ccf
    ret nc                      ; V3: SYNONYM does not mark done
    call eng_set_done
    or a
    ret
h_newtext:                      ; 92: discard pending input orders so a
    xor a                       ; rejected order's compound tail dies
    ld (inpPending), a          ; (inpPending is resident)
    ret
h_extern:                       ; 61: fn C via vector, A = B on entry
    ld a, c
    cp 16
    jp nc, ext_forward
    add a, a                    ; C < 16: no carry
    ld hl, extVec
    add hl, a                   ; Z80N word-table index
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld a, b
    ex de, hl
    jp (hl)
ext_undone:                     ; EXTERN 0 7 (XUNDONE): clear the done
    xor a                       ; stamp the engine wrote before
    ld (isDone), a              ; dispatching this action - the entry
    ret                         ; continues, the table reads notdone

; EXTERN offset_lsb 3 offset_msb (XMESSAGE): print a message from the
; DRC-emitted external text file 0.XMB. The engine has already
; consumed the third byte into extArg3. Message bytes are staged into
; the XMES bank (claimed once, kept for the session) and printed via
; rd_seek_page (same XOR-$FF/$0A encoding as DDB text; DRF bakes the
; trailing newline into the text, so no extra prn_newline). All
; failures are silent no-ops; the DEBUG marker shows on the missing-
; file/read-fail paths. EXTERN is action-typed, so the engine never
; consults the CF this leaves.
; XMES lsb msb (condact 120) is the V3-native spelling of the same
; thing, a thin wrapper over the primitive below. DRB rewrites the
; source keyword XMES into opcode 120 with the 16-bit 0.XMB offset
; split across the two parameters, so the offset arrives in B (LSB)
; and C (MSB) instead of B and extArg3.
h_xmes:                         ; 120: B = offset LSB, C = offset MSB
    ld hl, ddbVer
    bit 0, (hl)
    jp z, h_v3only              ; jr out of range from here
    ld a, c
    ld (extArg3), a
    ld a, b
    jp ext_xmes

ext_xmes:
    ld l, a                     ; A = B = offset LSB (h_extern contract)
    ld a, (extArg3)
    ld h, a
    ld (xmsOff), hl
    ; claim the XMES bank once
    ld a, (xmsBank)
    inc a                       ; $FF = unclaimed
    jr nz, .have
    call bank_alloc             ; out: A = bank, CF clear; CF set = none
    jp c, .fail                 ; free (banks.asm ~99-117)
    ld (xmsBank), a
.have:
    ; SP11 T5 PARTn probe - keep in step with the other four sites
    ; (art in overlay2.asm, WAV/songs/SFB in overlay1.asm). curPart >=
    ; 2: try PARTn\0.XMB first, root (.rootonly below, shared pool)
    ; fallback. curPart == 1: skip straight to .rootonly - zero new
    ; opens, byte-identical to pre-T5 code.
    ld a, (curPart)
    dec a
    jr z, .rootonly
    ld hl, xmsNamePart
    ld (hl), 'P'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'R'
    inc hl
    ld (hl), 'T'
    inc hl
    ld a, (curPart)
    add a, '0'
    ld (hl), a
    inc hl
    ld (hl), '\'
    inc hl
    ex de, hl                   ; de = xmsNamePart+6
    ld hl, xmsName                ; copy "0.XMB",0 verbatim (6 bytes)
    ld bc, 6
    ldir
    call esx_getsetdrv
    jr c, .rootonly
    ld ix, xmsNamePart
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .partopened
    ; --- end additive block; .rootonly below is the ORIGINAL code,
    ; unchanged
.rootonly:
    call esx_getsetdrv
    jp c, .fail
    ld ix, xmsName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail
.partopened:
    ld (xmsHandle), a
    ; seek to xmsOff (16-bit -> BCDE with high word 0, mode 0 start).
    ; NextZXOS F_SEEK: A=handle, BCDE=offset, IXL=mode (esxDOS API odt,
    ; F_SEEK entry: "IXL [L from dot command] = seek mode" - IXL is the
    ; register a raw rst $08 caller like this one must set; L is what a
    ; NextZXOS dot command supplies through its own wrapper. main.asm's
    ; svc_fseek and video.asm's vid_raw_seek0 set IX the same way.
    ; IXL is the mode register for a raw rst $08 caller; L is not read.
    ld bc, 0
    ld de, (xmsOff)
    ld ix, 0                    ; mode 0 = from start
    ld a, (xmsHandle)
    call esx_fseek
    jr c, .failclose
    ; read up to one 8K page into the XMES bank through the window
    call data_save
    ld a, (xmsBank)
    add a, a                    ; 16K bank -> its lower 8K page
    call data_map_page
    ld a, (xmsHandle)
    ld ix, DATA_WINDOW
    ld bc, $2000
    call esx_fread
    jr c, .failpost
    ld a, b                     ; zero bytes read = offset at/past EOF
    or c
    jr z, .failpost
    ; Sentinel: terminate the freshly-read chunk at DATA_WINDOW+BC with
    ; an encoded $0A ($F5 = NOT $0A) so txt_next_decoded (driven by
    ; print_msg.loop below) cannot run past genuinely-read bytes into
    ; stale window contents left by whatever last occupied this page -
    ; ddbtext.asm's txt_next_decoded decodes via cpl/cp $0A, so $F5 is
    ; the exact encoded byte it stops on (verified against that code,
    ; not assumed). BC is 1..$2000 here (0 already handled above);
    ; DATA_WINDOW+BC only escapes the 8K window when BC == $2000 (->
    ; $E000, one past $DFFF), so clamp that one case to DATA_WINDOW+
    ; $1FFF (the window's last byte) instead - an exactly-8K read is
    ; already past any conforming message, so the overwritten byte is
    ; academic.
    ld hl, DATA_WINDOW
    add hl, bc
    ld a, b
    cp $20                       ; BC == $2000? (B alone suffices - BC
    jr nz, .sentok                ; can't exceed the $2000 requested)
    dec hl                        ; clamp to DATA_WINDOW+$1FFF
.sentok:
    ld (hl), $F5
    call data_restore           ; CLOSE the window bracket before any
    ld a, (xmsHandle)           ; printing: data_save is NON-NESTABLE
    call esx_fclose              ; and the print pipeline (More paging,
                                 ; SM32) brackets its own window use
    ; print: a fresh data_save, reader onto the XMES page via
    ; rd_seek_page (replaces print_msg's msg_seek/rd_seek step),
    ; tokActive reset, then REUSE print_msg's own decode loop rather
    ; than duplicate it - print_msg.loop's local .done tail already
    ; ends in prn_flush + data_restore, so it closes THIS bracket;
    ; do not add a second data_restore after calling it.
    call data_save
    ld a, (xmsBank)
    add a, a
    ld hl, 0
    call rd_seek_page
    xor a
    ld (tokActive), a           ; fresh stream, mirrors print_msg
    jp print_msg.loop           ; tail into the shared loop (same idiom
                                 ; as h_mes/h_sysmess's jp print_msg) -
                                 ; its .done closes THIS data_save and
                                 ; returns straight to ext_xmes's caller
.failpost:
    call data_restore
.failclose:
    ld a, (xmsHandle)
    call esx_fclose
.fail:
 IFDEF DEBUG                    ; inline marker, same idiom as h_sfx's
    push bc
    ld b, 30
    ld c, 60
    ld hl, msgXmesFail
    call dbg_mark
    pop bc
 ENDIF
    ret

xmsName:    db "0.XMB", 0
xmsHandle:  db 0
xmsOff:     dw 0
xmsBank:    db $FF              ; claimed pool bank, $FF = none yet
; SP11 T5: PARTn\ prefixed scratch for ext_xmes, overlay0-local (xmsName
; itself is already overlay0-only, but not grown in place - same small-
; local-buffer shape used at the other four sites). Sized 6 ("PARTn\")
; + 6 (xmsName's own size, "0.XMB\0") = 12.
xmsNamePart: ds 12

; Boot-time reset for xmsBank. This byte lives in overlay0's own data
; (mapped into slot 7 only when the dispatcher or a caller explicitly
; maps OVL0_PAGE there), so it cannot be poked directly from resident
; boot code the way boot_data_init resets plain resident sentinels -
; the caller (main.asm) maps OVL0_PAGE first, mirroring exactly how
; aud_boot_probe's overlay1 state gets an explicit OVL1_PAGE map
; before that call. A warm re-entry (nextreg 2,1 soft reset) must not
; leave xmsBank pointing at a bank bank_table_init has since recycled
; to a new owner - see main.asm for why this runs on every boot.
xms_boot_reset:
    ld a, $FF
    ld (xmsBank), a
    ret

; Boot-only: probe GAME.XBN, load + validate into one allocated 16K
; bank. Any failure frees the bank (if one was allocated) and leaves
; xbnBank = $FF - the master "feature off" gate Tasks 3-6 check first,
; so a half-written xbnExt/xbnInt/xbnEnd on a rejected file is
; harmless. DEBUG builds report a reason marker at a fixed row;
; Release stays silent (dbg_at/dbg_puts are RET-only stubs there, see
; debug.asm). Called once from main.asm's boot sequence, directly
; after xms_boot_reset, with OVL0_PAGE already mapped into slot 7.
; Corrupts everything; no return value - the resident state vars
; (engine.asm, after extArg3) are the result.
;
; Shape mirrors ddb_load (file.asm) for the chunked fstat/read and
; ext_xmes (above) for the open/bracket/DEBUG-marker idiom - see
; those two for the precedents this follows rather than reinvents.
xbn_boot_load:
    ; Warm re-entry (nextreg 2,1 soft reset) can re-enter this routine
    ; with the PREVIOUS boot's state still resident - reset the whole
    ; group unconditionally before anything below can fail, same idiom
    ; as xms_boot_reset just above. Every exit that is not the success
    ; path at the bottom (including the two early "ret c" gates right
    ; below) then leaves the feature cleanly off.
    ld a, $FF
    ld (xbnBank), a
    ld a, (xbnIntOn)
    and $FF-HOOK_XBN             ; bit 1 (sprite tick) is not ours to clear
    ld (xbnIntOn), a
    ld hl, 0
    ld (xbnExt), hl
    ld (xbnInt), hl
    ld (xbnEnd), hl
    call esx_getsetdrv
    ret c                        ; no card / no default drive: off
    ld ix, .name
    ld b, ESX_MODE_READ
    call esx_fopen
    ret c                        ; absent file: feature off, no marker
                                  ; (same "optional file, not an error"
                                  ; policy as ddb_load/ext_xmes)
    ld (.handle), a
    ld ix, .statbuf
    call esx_fstat
    jp c, .rejclose
    ld hl, (.statbuf+9)          ; size high word (offset+7, 4 bytes LE)
    ld a, h
    or l
    jp nz, .rejclose             ; over 64K on disk
    ld de, (.statbuf+7)          ; de = actual file size (low word)
    ld hl, XBN_MAX_SIZE
    or a
    sbc hl, de
    jp c, .rejclose              ; > XBN_MAX_SIZE on disk
    ld (.fsize), de

    call bank_alloc
    jp c, .rejclose              ; no bank free
    ld (xbnBank), a

    ; --- load the file into the bank across its (up to two) 8K pages ---
    call data_save
    ld a, (xbnBank)
    add a, a
    call data_map_page
    ld a, (.handle)
    ld ix, DATA_WINDOW
    ld bc, $2000
    call esx_fread
    jp c, .reject
    ld (.got), bc
    ld a, b
    cp $20
    jr nz, .rdok                 ; short read: whole file in page 1
    ld a, (xbnBank)
    add a, a
    inc a
    call data_map_page
    ld a, (.handle)
    ld ix, DATA_WINDOW
    ld hl, (.fsize)
    ld de, $2000
    or a
    sbc hl, de                   ; remaining bytes (fsize - $2000)
    ld b, h
    ld c, l
    call esx_fread
    jp c, .reject
    ld hl, (.got)
    add hl, bc
    ld (.got), hl
.rdok:
    ; --- validate the header (page 1, offset 0 = XBN_ORG = DATA_WINDOW) ---
    ld a, (xbnBank)
    add a, a
    call data_map_page
    ld hl, (.got)
    ld de, XBN_HDR_LEN
    or a
    sbc hl, de
    jp c, .reject                 ; fewer bytes than a header: truncated
    ld hl, DATA_WINDOW
    ld de, .magic
    ld b, 4
.m:
    ld a, (de)
    cp (hl)                     ; "XBN",2 - HL lands on the ext word
    jp nz, .reject
    inc hl
    inc de
    djnz .m
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (.hdrExt), de
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (.hdrInt), de
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (.hdrSize), de

    ; v2: four reserved bytes, must be zero - the future door. A later
    ; release may make one load-bearing; this reject is what makes that
    ; safe without another version cliff.
    inc hl
    ld a, (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    jp nz, .reject

    call data_restore             ; window done; the rest is arithmetic
                                  ; on the cached fields - .reject below
                                  ; calls data_restore again on any later
                                  ; failure, harmless (idempotent restore)

    ; size word: <= XBN_MAX_SIZE and == bytes actually read
    ld de, (.hdrSize)
    ld hl, XBN_MAX_SIZE
    or a
    sbc hl, de
    jp c, .reject
    ld hl, (.got)
    or a
    sbc hl, de
    jp nz, .reject                ; must equal bytes actually read

    ld hl, (.hdrSize)             ; xbnEnd = $C000 + size, except size ==
    ld de, XBN_MAX_SIZE           ; XBN_MAX_SIZE ($4000): $C000+$4000 =
    or a                          ; $10000 wraps to $0000 in 16 bits, which
    sbc hl, de                    ; would fail every later "< xbnEnd" range
    jr nz, .endnowrap              ; check. Controller ruling: size $4000
    ld hl, $FFFF                  ; - window top clamped to $FFFF - the
    jr .endset                    ; single top byte is not addressable as
.endnowrap:                       ; an entry/CALL target anyway.
    ld hl, (.hdrSize)
    ld de, DATA_WINDOW
    add hl, de
.endset:
    ld (.hdrEnd), hl

    ld hl, (.hdrEnd)
    ld de, (.hdrExt)
    call .checkEntry
    jp c, .reject
    ld hl, (.hdrEnd)
    ld de, (.hdrInt)
    call .checkEntry
    jp c, .reject

    ; --- commit resident state (Tasks 3-6 read these) ---
    ld hl, (.hdrExt)
    ld (xbnExt), hl
    ld hl, (.hdrInt)
    ld (xbnInt), hl
    ld a, h
    or l
    jr z, .noint
    ld a, (xbnIntOn)
    or HOOK_XBN
    jr .setint
.noint:
    ld a, (xbnIntOn)
    and $FF-HOOK_XBN
.setint:
    ld (xbnIntOn), a
    ld hl, (.hdrEnd)
    ld (xbnEnd), hl
    ld a, (.handle)
    jp esx_fclose

; DE = candidate entry address, HL = xbnEnd. Out: CF set if DE is
; neither 0 nor within [$C000, xbnEnd). Corrupts AF; preserves HL.
.checkEntry:
    ld a, d
    or e
    ret z                         ; 0 = unused entry: always OK, CF clear
    ld a, d
    cp $C0
    jr c, .badEntry                ; DE < $C000
    push hl
    or a
    sbc hl, de                    ; xbnEnd - DE
    pop hl
    jr z, .badEntry                ; DE == xbnEnd (must be strictly less)
    ret nc                         ; DE < xbnEnd: OK, CF already clear
.badEntry:
    scf
    ret

.reject:
    call data_restore              ; undo the load/validate window remap
    ld a, (xbnBank)
    call bank_free
    ld a, $FF
    ld (xbnBank), a
.rejclose:
 IFDEF DEBUG                      ; inline marker, same idiom as ext_xmes's
    push bc
    ld b, 28
    ld c, 60
    ld hl, msgXbnFail
    call dbg_mark
    pop bc
 ENDIF
    ld a, (.handle)
    jp esx_fclose

.name:      db "GAME.XBN", 0
.handle:    db 0
.statbuf:   ds 11
.fsize:     dw 0
.got:       dw 0
.hdrExt:    dw 0
.hdrInt:    dw 0
.hdrSize:   dw 0
.hdrEnd:    dw 0
.magic:     db "XBN", 2

; --- part switch primitive (EXTERN n 4 / XPART) ---

; h_xpart: EXTERN n 4 (XPART). h_extern's contract leaves A = B = the
; first EXTERN argument (n, the target part 1-9) on entry; C still
; holds the vector index (4, unused here). Validates n, then snapshots
; the LIVE 256 flags + object-location table into swapStage before
; handing off to switch_to_part. Both failure exits (n out of range,
; or n == curPart) return with CF set, which EXTERN being action-typed
; means eng_exec never consults. curPart is not written until
; switch_to_part has a confirmed-successful probe, so both failure
; exits here leave the current part fully untouched. Out-of-range n
; gets a DEBUG marker; n == curPart stays silent on purpose (a
; same-part EXTERN is a benign author idiom, not an error).
h_xpart:
    cp 1
    jr c, .range                ; n < 1
    cp 10
    jr nc, .range                ; n > 9
    ld hl, curPart
    cp (hl)
    jr z, .noop                  ; n == curPart: see header, no marker
    ld (xpartTarget), a         ; n survives the snapshot below (which
                                 ; clobbers AF/BC/DE/HL/IX freely)
    ld hl, flags
    ld de, swapStage
    ld bc, 256
    ldir                        ; swapStage[0..255] = live flags, verbatim
    ld a, (numObj)
    ld (swapObjCount), a        ; old part's object count, for the
                                 ; min(old,new) rule at install time
    ld ix, objTable
    ld hl, swapStage+256
    ld de, OBJ_SIZE
    ld b, 0                     ; 256 iterations = objTable's declared
                                 ; capacity (swapStage's own comment
                                 ; below has the full arithmetic)
.snap:
    ld a, (ix+0)                ; objTable entry's location byte
    ld (hl), a
    inc hl
    add ix, de
    djnz .snap
    ld a, (xpartTarget)
    jp switch_to_part           ; tail-jump: on failure, switch_to_part's
                                 ; own ret lands exactly where h_xpart's
                                 ; own ret would have
.range:                         ; n < 1 or n > 9: no-op with a marker,
 IFDEF DEBUG                    ; same idiom as h_sfx/h_mouse's unknown-
    push af                     ; sub-command markers - preserve n
    call dbg_markcol             ; (here in A, not C) across dbg_markcol
    ld b, 29                    ; (corrupts A) before dbg_mark_hex takes
    pop af                      ; over preserving it across the print.
    ld hl, msgXpartRange
    call dbg_mark_hex
 ENDIF
.noop:
    scf
    ret

; switch_to_part: A = target part number 1-9. Caller contract: swapStage
; (256 live flags + up to 256 object-location bytes) and swapObjCount
; (the OLD part's object count, for the install's min(old,new) rule)
; are already populated - h_xpart does this from live state; LOAD's
; auto-switch populates them from a save file's payload instead and
; reuses this same entry point. On probe failure: CF set, ret, current
; part untouched. On success: NEVER RETURNS - resets SP and enters the
; new part fresh at PRO 0.
;
; eng_init_game has no label between its flag/object init and the
; rest, so this runs the FULL eng_init_game against the newly-loaded
; DDB (rebuilds flags to defaults and objTable to the new part's
; compiled initial state), then RE-INSTALLS swapStage over that fresh
; state before ever entering eng_run.
;
; ddbName (errors.asm, resident) is a 10-byte buffer: "GAMEn.DDB",0 is
; 9 characters + NUL, fitting exactly. xpart_build_name below writes
; the LITERAL target name for every part, n=1 included - no wildcard.
switch_to_part:
    ; The LOAD/RAMLOAD path hands an unvalidated SAV trailing part byte
    ; here (h_xpart's own 1-9 range check is EXTERN-only); route any
    ; out-of-range byte to .fail so it is refused the same way as a
    ; missing GAMEn.DDB - h_xpart's check becomes redundant-but-harmless
    ; belt-and-braces for its own caller, left as is.
    cp 1
    jr c, .fail
    cp 10
    jr nc, .fail
    ld (xpartTarget), a
    call xpart_build_name        ; ddbName <- target name (see above)
    call esx_getsetdrv
    jr c, .fail
    ; A = default drive from esx_getsetdrv, consumed by esx_fopen -
    ; keep A intact (mirrors ddb_load's own call shape, file.asm)
    ld ix, ddbName
    ld b, ESX_MODE_READ
    call esx_fopen
    jr c, .fail                  ; missing -> current part untouched
    call esx_fclose               ; probe only; ddb_load reopens fresh
    call ddb_load                 ; destructive from here. Return code
                                  ; intentionally unchecked: the probe
                                  ; already confirmed the file opens - a
                                  ; read error/bad header mid-load is an
                                  ; accepted documented residual (brief
                                  ; Step 3b), not handled specially
    ld a, (xpartTarget)
    ld (curPart), a
    call gfx_cache_reset          ; resident (gfxcache.asm) - free to
                                  ; call from overlay0 (context note 2)
    call xms_boot_reset           ; overlay0-local; MMU7 is already
                                  ; OVL0_PAGE throughout this routine
    call eng_init_game            ; resident; full re-init from the
                                  ; just-loaded ddbHeader (h_end already
                                  ; calls this from overlay0 - overlay0.
                                  ; asm:1548 - proven-safe precedent)
    ld hl, swapStage
    ld de, flags
    ld bc, 256
    ldir                          ; flags carried verbatim over the
                                  ; fresh defaults eng_init_game just set
    ld a, (swapObjCount)          ; old count
    ld hl, numObj                 ; new count (eng_init_game just set it
                                  ; from the new ddbHeader)
    cp (hl)
    jr c, .haveMin                ; old < new: A already = old = min
    ld a, (hl)                    ; old >= new: A = new = min
.haveMin:
    or a
    jr z, .noobjs
    ld b, a
    ld ix, objTable
    ld hl, swapStage+256
    ld de, OBJ_SIZE
.instloop:
    ld a, (hl)                    ; carried location, verbatim (what a
    ld (ix+0), a                  ; part-1 number means in part n is the
    inc hl                        ; author's contract, not this engine
    add ix, de                    ; seam's concern); indices >= min keep
    djnz .instloop                ; the NEW part's compiled locations,
                                  ; already installed by eng_init_game
                                  ; and left untouched here
.noobjs:
    ; SP12 T3: PARTn-aware mouse pointer reload. Already same-page (both
    ; switch_to_part and pointer_load live in overlay0) - a plain call,
    ; zero trampoline needed, unlike the font/audio hops below. curPart
    ; was committed several lines above (right after ddb_load, well
    ; before this point), so the PARTn\ prefix is already active - same
    ; ordering the font/audio re-probes rely on. Runs on the OLD stack,
    ; still valid here (before the "point of no return" SP reset just
    ; below), so this call/ret is fully balanced and leaves nothing
    ; behind.
    call spr_stop_all            ; before pointer_load rescans pointerMask
    ld hl, spr_cache_flush       ; set numbers are per part
    call spr_call
    ld a, $FF
    ld (ptrCur), a               ; part switch re-probes the base shape
    xor a
    call pointer_load
    ; Point of no return: abandon the old (deep, process-interpreter)
    ; stack entirely and enter the new part from scratch (nothing on
    ; the old stack matters past this line).
    ld sp, STACK_TOP
    ; One-way cross-overlay DOUBLE hop: font reload (overlay2), then the
    ; SFB re-probe (overlay1). aud_load_sfb (overlay1.asm) and font_load
    ; (overlay2.asm) are both PARTn\-prefix-aware; curPart is already
    ; committed above, so both prefixes activate automatically. Both
    ; targets are reached via the push-target/jp-ovl_map_page trampoline
    ; and are normal call/ret routines reached here via jp, so nothing
    ; of ours is on the stack for their rets to consume except what we
    ; push. Pushing eng_run's (resident) address BELOW font_load_switch's
    ; on the fresh stack means font_load_switch's own tail-hop to
    ; aud_load_sfb, and that routine's own ret, land directly on eng_run
    ; once the chain finishes. eng_run is resident, so MMU7 being left
    ; on OVL1_PAGE afterward is harmless - the condact dispatcher remaps
    ; per-condact as it always does.
    ld hl, eng_run
    push hl
    ld hl, font_load_switch
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
.fail:
 IFDEF DEBUG
    push bc
    ld b, 29
    ld c, 60
    ld hl, msgXpartFail
    call dbg_mark
    pop bc
 ENDIF
    scf
    ret

; Part A (1-9) -> ddbName (errors.asm's resident 10-byte buffer): n=1
; copies "GAME.DDB",0,0, n=2-9 copy "GAME?.DDB",0 and poke the digit.
; Corrupts AF, BC, DE, HL.
xpart_build_name:
    ld hl, .gameddb
    cp 1
    jr z, .cp
    ld hl, .tpl
.cp:
    ld de, ddbName
    ld bc, 10
    ldir                        ; LDIR writes only P/V: the cp 1 Z survives
    ret z                       ; part 1: done
    add a, '0'
    ld (ddbName+4), a
    ret
.gameddb: db "GAME.DDB", 0, 0     ; 8 chars + NUL + 1 spare = 10
.tpl:     db "GAME?.DDB", 0       ; digit poked at +4

; swapStage: staging buffer for a part switch. [0..255] = the full
; flags array, copied verbatim. [256..511] = one byte per object =
; objTable's location field ONLY (attribs/extattr/noun/adj are never
; carried - they always come from the new part's own compiled data),
; sized to objTable's declared maximum of 256 entries. swapObjCount is
; the companion: the snapshot source part's object count at capture
; time, needed at install time to compute min(oldCount, newCount).
; Both are populated by h_xpart from live state, or by LOAD's
; auto-switch from a save file's payload, via the same switch_to_part
; entry point.
swapStage:     ds 512
swapObjCount:  db 0
xpartTarget:   db 0

; --- cross-part LOAD/RAMLOAD trampoline entry ---
; Shared landing pad for BOTH sav_read_v2's cross-part SAV LOAD path
; and h_ramload's cross-part path (overlay1.asm) - swapStage/
; swapObjCount above live in this (OVL0) page and cannot be written
; directly from overlay1, so both callers stage their payload into a
; resident buffer first and hop here via the standard trampoline idiom
; (push target, ld a,OVL0_PAGE, jp ovl_map_page).
;
; Entry (ovl_map_page corrupts AF only): HL = flags source (256 bytes,
; verbatim), IX = object-location source (packed one byte per object),
; B = source part's object count 0-255, C = target part 1-9.
;
; Calls switch_to_part via CALL, not a tail-jump: on success it never
; returns, so the pushed return address is abandoned with the rest of
; the old stack. On a probe failure switch_to_part does a bare scf/ret
; with no MMU7 remap, which is not safe here (that ret would land on
; our caller's return address while MMU7 is still mapped OVL0_PAGE).
; So the failure is caught here (CALL, not JP) and explicitly
; return-trampolined back to overlay1's xpart_load_fail, which remaps
; MMU7 to OVL1_PAGE before its own ret fires, landing correctly back
; on whichever of sav_read_v2/h_ramload called us, with CF set.
xpart_load_entry:
    push bc                      ; ldir below clobbers BC as its counter
    ld de, swapStage
    ld bc, 256
    ldir                         ; swapStage[0..255] = flags, verbatim
    pop bc                       ; B = source object count, C = target
    ld a, b
    ld (swapObjCount), a
    or a
    jr z, .noobjs
    ld hl, swapStage+256
.cp:
    ld a, (ix+0)
    ld (hl), a
    inc hl
    inc ix
    djnz .cp
.noobjs:
    ld a, c
    call switch_to_part
    ; only reached on failure (CF set); success never returns
    ld hl, xpart_load_fail
    push hl
    ld a, OVL1_PAGE
    jp ovl_map_page

; EXTERN forwarding: fn not claimed natively, XBN loaded with a live
; extEntry -> classic-contract dispatch. Else exactly the old stub.
; The register-contract build (DE/HL/IX/A) is resident (ext_build_contract,
; main.asm) - overlay0's own headroom has no room to spare for it.
; The h_unimpl fallbacks below stay CF-blind by construction: they
; return through the ordinary action path, never through
; ext_build_contract's split return.
ext_forward:
    ld a, (xbnBank)
    inc a                       ; $FF -> 0
    jp z, h_unimpl
    ld hl, (xbnExt)
    ld a, h
    or l
    jp z, h_unimpl              ; interrupt-only binary
    ld (extTarget), hl
    jp ext_build_contract       ; resident; B/C still hold param1/fn

; DEBUG EXTERN probe routes (vectors 6, 8-14): the trampoline bodies
; (KTEST, L2MOD/LHIDE/LSHOW, LSxxx, NXB) and the ring-2 probe verbs
; live in debug.asm's resident DEBUG tail, not on this page - this
; overlay's DEBUG headroom had none to spare. h_extern dispatches with
; resident always mapped, so the extVec rows below point straight at
; resident addresses. extVec is DATA, not code - the IFDEFs on the
; rows cost nothing in Release (byte-identical). Release forwards
; vectors 6 and 8-14 to the XBN (same as 5); DEBUG reserves them for
; the probes instead.
extVec:
    dw ext_forward, ext_forward, ext_forward, ext_xmes
    dw h_xpart, ext_forward
 IFDEF DEBUG
    dw ktest_trampoline           ; vector 6, DEBUG only
 ELSE
    dw ext_forward                 ; vector 6, release: forwards to the XBN
 ENDIF
    dw ext_undone
 IFDEF DEBUG
    dw l2mod_trampoline           ; vector 8, DEBUG only (Card #6)
    dw l2hide_trampoline          ; vector 9, DEBUG only (Card #6)
    dw l2show_trampoline          ; vector 10, DEBUG only (Card #6)
 ELSE
    dw ext_forward, ext_forward, ext_forward ; vectors 8-10, release: forward to the XBN
 ENDIF
 IFDEF DEBUG
    dw l2scr_trampoline           ; vector 11, DEBUG only (SP17 T5)
 ELSE
    dw ext_forward                 ; vector 11, release: forwards to the XBN
 ENDIF
 IFDEF DEBUG
    dw nxb_trampoline             ; vector 12, DEBUG only (SP17 bench)
 ELSE
    dw ext_forward                 ; vector 12, release: forwards to the XBN
 ENDIF
; EXTERN vectors 13/14: ring-2 placement probe, fallback for when
; DeZog CALL-injection is unavailable. Route tests/sfxlong.dsf's
; R2FILL/R2CHK verbs straight to ring2_fill/ring2_chk (debug.asm's
; resident DEBUG tail) - no trampoline needed: resident is always
; mapped. DEBUG-only, vector 15 stays spare.
 IFDEF DEBUG
    dw ring2_fill                 ; vector 13
    dw ring2_chk                  ; vector 14
 ELSE
    dw ext_forward, ext_forward   ; vectors 13-14, release: forward to the XBN
 ENDIF
    dw ext_forward                 ; vector 15: spare

savedCurX: db 0
savedCurY: db 0
moveVerb:  db 0

; --- CALL closure + Kempston mouse ---

h_call:                         ; 101: CALL lsb msb: run code at that
                                 ; address inside the loaded XBN's extent
                                 ; ($C000..xbnEnd). No XBN staged, or the
                                 ; address out of range: no-op - the same
                                 ; documented behaviour CALL always had
                                 ; before XBN support (jdaad.js's own
                                 ; _CALL() likewise just marks done, "CALL
                                 ; not supported by jDAAD"). Range-check
                                 ; and dispatch body is resident
                                 ; (call_dispatch, main.asm) - overlay0's
                                 ; own DEBUG headroom has no room to spare
                                 ; for it.
    jp call_dispatch

; MOUSE (86): B = P1 (flag base, sub 3 only), C = sub 0-7 (RESETMS,
; SHOWMS, HIDEMS, GETMS, GETFINEMS, POINTERMS, DELTAXMS, DELTAYMS).
; Sub 3 reads flags[P1..P1+3] = buttons, X/8 (clamped tmCols-1), Y/8,
; X/6 (clamped 0-53). DELTAXMS/DELTAYMS do NOT report movement deltas:
; per the DRC manual they move the pointer's hotspot within the
; pointer bitmap (default 0,0).
; mouseX (word, 0-319) / mouseY (byte, screen-downward) are resident
; accumulated positions, updated only on a sub-3 poll by taking a
; signed 8-bit delta against the last raw Kempston-mouse-port reading
; (mouseBaseSet gates the first poll, which only latches a baseline).
; Pointer is hardware sprite 0, a 16x16 pattern (built-in arrow until
; a POINTER.SPR replaces it). NR $15 bits 0 (visibility) and 1
; (sprites over border, needed since the pointer's range reaches the
; border - per the sprites chapter) are read-modify-written
; unconditionally on every sub-1 call, not latched behind mouseReady,
; so a warm CSpect nextreg-2,1 re-entry cannot leave the sprite stuck
; invisible. Dispatch is a word table over the dense 0-7 set.
h_mouse:
    ld a, c
    cp 8
    jr nc, .unknown
    ld hl, mouseSubs
    add a, a                    ; word table: index * 2
    add hl, a                   ; Z80N ADD HL,A (doc 07 (a) / doc 10)
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl                   ; B and C reach the handler untouched
    jp (hl)
.unknown:
 IFDEF DEBUG                    ; unknown sub-command: no-op with a
    push bc                     ; marker, same idiom as h_sfx/h_gfx.
    ld a, c                     ; sub, needed after dbg_markcol
    push af                     ; overwrites C - save it across that call.
    call dbg_markcol
    ld b, 28
    ld hl, msgMouseUnk
    pop af
    call dbg_mark_hex
    pop bc
 ENDIF
    ret
.reset:                         ; sub 0: centre position, zero buttons,
    ld hl, 160                  ; re-latch the raw baseline from the
    ld (mouseX), hl             ; CURRENT hardware counters so the next
    ld a, 128                   ; sub-3 poll sees a real (small) delta
    ld (mouseY), a              ; instead of jumping by whatever the
    xor a                       ; mouse did before this reset ran.
    ld (mouseBtn), a            ; Matches jdaad's sub 0 in spirit only -
    ld (mouseHotX), a           ; SP16 B23: the sub 6/7 hotspot is part
    ld (mouseHotY), a           ; of the pointer's geometry, so a real
                                 ; mouse reset restores its (0,0) default
                                 ; too - otherwise MOUSE 0 0 leaves the
                                 ; bitmap shifted by whatever a previous
                                 ; DELTAXMS/DELTAYMS set.
    ld bc, KMOUSE_X_PORT        ; jdaad's own case 0 is a no-op ("was
    in a, (c)                   ; ResetMouse() but it makes no sense in
    ld (mouseXraw), a           ; JS"); we DO maintain real state, so a
    ld bc, KMOUSE_Y_PORT        ; real reset is meaningful here.
    in a, (c)
    ld (mouseYraw), a
    ld a, 1
    ld (mouseBaseSet), a
    ret
.show:                          ; sub 1: one-time pattern upload, then
    ld a, (mouseReady)          ; ALWAYS re-arm NR $15 bits 0+1 and
    or a                        ; (re)position/show sprite 0. The NR $15
    jr nz, .patternok           ; RMW is cheap (one register read/write)
    call mouse_pattern_load     ; and deliberately NOT latched behind
    ld a, 1                     ; mouseReady like the pattern upload is -
    ld (mouseReady), a          ; see h_mouse's header comment for why
.patternok:                     ; this needs to be unconditional.
    ld e, NR_SPRITES
    call nr_read                ; RMW: preserve every other bit (layer
    or SPR_NR15_ON              ; priority etc) - only touch bit 0
    nextreg NR_SPRITES, a       ; (sprites enable), bit 1 (sprites over
                                 ; border - our pointer's range legitimately
                                 ; reaches into the border, see h_mouse's
                                 ; header comment) and bit 6: sprite 0 (the
                                 ; pointer) on top of every set; reset
                                 ; default is highest slot on top
    call spr_di                 ; DI: the sprite tick (isr_hook_body) shares
    call mouse_sprite_body      ; the NR $34 select-then-write sequence, so
    ld a, %11000000              ; the select and the writes under it are one
    nextreg NR_SPRITE_PAT, a    ; group (visible(7) + byte4(6) + pattern 0)
    jp spr_ei
.hide:                          ; sub 2: invisible attribute only -
    call spr_di                 ; sprites master (NR $15) stays enabled
    xor a
    nextreg NR_SPRITE_SEL, a
    ld a, %01000000              ; invisible + byte4-enable kept
    nextreg NR_SPRITE_PAT, a
    jp spr_ei
.read:                          ; sub 3: poll, write flags[P1..P1+3],
    ld a, b                     ; reposition the sprite (harmless if
    ld (mouseP1), a             ; it's currently hidden)
    call mouse_poll
    ; col80 = mouseX/8, clamped to tmCols-1 (word >> 3)
    ld de, (mouseX)
    ld b, 3
    bsrl de, b                  ; Z80N barrel shift (core v2+; nex demands 3)
    ld a, (tmCols)
    dec a                       ; highest valid column
    cp e                        ; E = mouseX>>3 (mouseX <= 319, so D = 0)
    jr c, .c80ok                ; over: A already = max
    ld a, e
.c80ok:
    ld (mouseCol80), a
    ; row32 = mouseY/8: a byte >> 3 is 0-31, no clamp needed
    ld a, (mouseY)
    rrca
    rrca
    rrca
    and $1F
    ld (mouseRow32), a
    ; col53 = mouseX/6, clamped 0-53 (repeated subtraction: quotient
    ; never exceeds 53, cheap enough for a condact handler)
    ld hl, (mouseX)
    ld de, 6
    ld c, 0
.d6:
    or a
    sbc hl, de
    jr c, .d6done
    inc c
    jr .d6
.d6done:
    ld a, c
    cp 54
    jr c, .c53ok
    ld a, 53
.c53ok:
    ld (mouseCol53), a
    ; commit flags[P1..P1+3] - flags is 256-aligned, so L wraps safely
    ld a, (mouseP1)
    ld h, high flags
    ld l, a
    call mouse_btn_jd            ; A = buttons, jdaad convention; HL kept
    ld (hl), a
    inc l
    ld a, (mouseCol80)
    ld (hl), a
    inc l
    ld a, (mouseRow32)
    ld (hl), a
    inc l
    ld a, (mouseCol53)
    ld (hl), a
    jp mouse_sprite_pos
.fine:                           ; sub 4 GETFINEMS: "Similar to the
                                 ; previous one, but in the flag+1 the X
                                 ; position divided by 2 will be stored
                                 ; if we are in VGA mode ... and in the
                                 ; flag+2 the Y position ... not divided
                                 ; if it is VGA" (DRC manual). Three
                                 ; flags, not four - the manual's own
                                 ; example is "MOUSE 100 4; Reads fine
                                 ; position in flags 100, 101 and 102".
                                 ; NextDAAD's pointer plane is 320x256
                                 ; (MOUSE_X_MAX/MOUSE_Y_MAX), i.e. the
                                 ; VGA case exactly: X/2 spans 0-159 and
                                 ; undivided Y spans 0-255, so both fit
                                 ; a flag with no clamp and no loss of
                                 ; range. The SVGA halves are not used -
                                 ; there is no wider plane here to name.
    ld a, b
    ld (mouseP1), a
    call mouse_poll
    ld hl, (mouseX)
    srl h                        ; X/2 (doc 05: no single 16-bit shift
    rr l                         ; right; SRL H / RR L is the idiom)
    ld d, l                      ; D survives mouse_btn_jd (AF/BC only)
    ld a, (mouseP1)
    ld h, high flags
    ld l, a
    call mouse_btn_jd
    ld (hl), a                   ; flag+0 = buttons, as sub 3
    inc l
    ld (hl), d                   ; flag+1 = X/2
    inc l
    ld a, (mouseY)
    ld (hl), a                   ; flag+2 = Y, undivided
    jp mouse_sprite_pos
.pointer:                        ; sub 5 POINTERMS: "load the file with
                                 ; PTR extension defined by first
                                 ; parameter" (DOS only; 81-byte 9x9
                                 ; bitmaps, colours indices into a per-
                                 ; picture 256-colour palette). NextDAAD
                                 ; has no per-picture palette for a
                                 ; pointer to index into, so .PTR files
                                 ; remain unsupported and untranslatable;
                                 ; the parameter is repurposed as a
                                 ; shape NUMBER instead (0-9): 0 is the
                                 ; built-in 16x16 arrow (hardware sprite
                                 ; pattern slot 0), then POINTER.SPR over
                                 ; it if one exists; 1-9 are
                                 ; POINTERn.SPR - see ptr_name_build/
                                 ; pointer_load, below. Out of range is a
                                 ; re-arm only, same as before. The
                                 ; re-arm guarantee is unchanged: every
                                 ; call re-uploads and re-arms mouseReady
                                 ; below, so the documented DAAD idiom
                                 ; "POINTERMS then SHOWMS" always leaves
                                 ; slot 0 holding this interpreter's
                                 ; pointer whatever else has used the
                                 ; slot meanwhile.
    ld a, b
    cp 10
    jr nc, .ptrarm               ; out of range: re-arm only, as before
    ld hl, ptrCur
    cp (hl)
    jr z, .ptrarm                ; same shape already live: skip the SD
                                 ; read but STILL re-upload below - sub
                                 ; 5's documented guarantee is that slot
                                 ; 0 holds your pointer whatever else
                                 ; used it, and that must not weaken
    or a
    jr nz, .ptrfile
    call ptr_arrow_install       ; 0: built-in arrow first, then
    xor a                        ; POINTER.SPR over it if one exists
    ld (ptrCur), a
    jr .ptrload                  ; A is already 0 - do NOT fall through to
                                 ; `ld a,b`; ptr_arrow_install corrupts BC
.ptrfile:
    ld a, b
.ptrload:
    call pointer_load
.ptrarm:
    call mouse_pattern_load
    ld a, 1
    ld (mouseReady), a
    ret
.hotx:                           ; sub 6 DELTAXMS: hotspot X within the
                                 ; pointer bitmap (NOT a movement delta -
                                 ; see the routine header). The arrow's
                                 ; hotspot is its tip at (0,0), which is
                                 ; why mouse_sprite_pos uses mouseX/
                                 ; mouseY as the sprite's own top-left.
                                 ; A non-zero hotspot shifts the BITMAP
                                 ; back by that much so the hotspot pixel
                                 ; lands on the reported coordinate.
                                 ; Applied immediately - mouse_sprite_pos
                                 ; is safe to call while hidden.
    ld a, b
    ld (mouseHotX), a
    jp mouse_sprite_pos
.hoty:                           ; sub 7 DELTAYMS: hotspot Y, as above.
    ld a, b
    ld (mouseHotY), a
    jp mouse_sprite_pos

; Kempston button byte -> jdaad's author-facing convention, in A.
; Split out of sub 3 so GETFINEMS reports buttons identically.
; Corrupts AF, BC. PRESERVES DE and HL (sub 3/4 both hold the flag
; pointer in HL across this call).
mouse_btn_jd:
    ld a, (mouseBtn)             ; raw Kempston byte (mouseBtn's own
                                 ; internal latch stays untouched, raw,
                                 ; for mouse_poll/mouse_move_x/y's own
                                 ; use elsewhere) - transform to jdaad's
                                 ; author-facing convention at this
                                 ; commit ONLY. Parity authority: jdaad.
                                 ; js _MOUSE case 3 / GetMouse (github.
                                 ; com/Utodev/jDAAD) - mouseButtons is
                                 ; active-HIGH, idle 0, additive combos:
                                 ;   bit0 LEFT(1)  bit1 RIGHT(2)  bit2 MIDDLE(4)
                                 ; KMOUSE_BTN_PORT (nextdaad.inc) is
                                 ; active-LOW, idle 7, Kempston order:
                                 ;   bit0 RIGHT  bit1 LEFT  bit2 MIDDLE  bits7-4 wheel
                                 ; jdaad implements only sub-commands
                                 ; 0-3, so its authority covers the
                                 ; button byte for BOTH of ours that
                                 ; report one (3 and 4); it has no wheel
                                 ; surface at all.
    cpl                          ; idle 0, pressed 1 now; still Kempston
                                 ; bit order (0=right,1=left,2=middle);
                                 ; bits 7-3 = inverted wheel noise
    and %00000111                ; drop the wheel bits - reclaimable
                                 ; later as an extension, not a jdaad-
                                 ; parity loss (jdaad has no wheel)
    ld b, a                      ; B = idle-0, Kempston-order, 3-bit value
    rrca                         ; whole-byte rotate right 1: bit0 of A
                                 ; is now B's old bit1 (left)
    xor b                        ; A's bit0 = (old bit1) XOR (old bit0):
                                 ; 1 exactly where the two differ
    and 1                        ; isolate that bit: 1 iff bit0/bit1 of
                                 ; B differ, else 0
    ld c, a
    add a, a                     ; duplicate into bit1 too
    or c                         ; A = swap-mask: %011 if bit0/bit1
                                 ; differ (both must flip to swap), %000
                                 ; if they already match (no flip needed)
    xor b                        ; B with bit0/bit1 swapped (right<->
                                 ; left), bit2 (middle) untouched, bits
                                 ; 3-7 still 0 - classic adjacent-bit XOR
                                 ; swap. Result: idle 0, left 1, right 2,
                                 ; middle 4, combinations additive -
                                 ; exact jdaad parity.
    ret

; Sub-command vector table, dense 0-7 (doc 07 (a)). Placed after
; h_mouse's body so its dot-locals still belong to h_mouse.
mouseSubs:
    dw h_mouse.reset             ; 0 RESETMS
    dw h_mouse.show              ; 1 SHOWMS
    dw h_mouse.hide              ; 2 HIDEMS
    dw h_mouse.read              ; 3 GETMS
    dw h_mouse.fine              ; 4 GETFINEMS
    dw h_mouse.pointer           ; 5 POINTERMS
    dw h_mouse.hotx              ; 6 DELTAXMS
    dw h_mouse.hoty              ; 7 DELTAYMS

; Poll Kempston mouse hardware: latches mouseBtn (raw byte, bit0 right/
; bit1 left/bit2 middle/bits7-4 wheel), and accumulates mouseX/mouseY
; from signed deltas of the wrapping X/Y counters via mouse_move_x/y.
; First-ever call (mouseBaseSet==0) only latches the raw baseline - see
; h_mouse's header comment for why. Corrupts AF, BC, DE, HL.
mouse_poll:
    ld bc, KMOUSE_BTN_PORT
    in a, (c)
    ld (mouseBtn), a
    ld bc, KMOUSE_X_PORT
    in a, (c)
    ld c, a                     ; C = new raw X
    ld a, (mouseBaseSet)
    or a
    jr z, .basex
    ld a, c
    ld hl, mouseXraw
    sub (hl)                    ; A = new - old = signed delta
    ld (hl), c
    call mouse_move_x
    jr .yaxis
.basex:
    ld a, c
    ld (mouseXraw), a
.yaxis:
    ld bc, KMOUSE_Y_PORT
    in a, (c)
    ld c, a                     ; C = new raw Y
    ld a, (mouseBaseSet)
    or a
    jr z, .basey
    ld a, c
    ld hl, mouseYraw
    sub (hl)                    ; A = new - old, RAW direction (+ = up)
    ld (hl), c
    neg                         ; screen delta = -(raw delta)
    call mouse_move_y
    jr .done
.basey:
    ld a, c
    ld (mouseYraw), a
.done:
    ld a, 1
    ld (mouseBaseSet), a
    ret

; A = signed delta. mouseX (word) += A, clamped [0,MOUSE_X_MAX].
; Corrupts AF, DE, HL.
mouse_move_x:
    call mouse_sext
    ld hl, (mouseX)
    add hl, de
    ld de, MOUSE_X_MAX
    call mouse_clamp
    ld (mouseX), hl
    ret

; A = signed SCREEN-space delta. mouseY (byte) += A, clamped
; [0,MOUSE_Y_MAX]. Corrupts AF, DE, HL.
mouse_move_y:
    call mouse_sext
    ld a, (mouseY)
    ld l, a
    ld h, 0
    add hl, de
    ld de, MOUSE_Y_MAX
    call mouse_clamp
    ld a, l
    ld (mouseY), a
    ret

; A = signed delta -> DE sign-extended (D = $00/$FF, E = A). Corrupts AF.
mouse_sext:
    ld e, a
    add a, a
    sbc a, a
    ld d, a
    ret

; In: HL = signed-16-bit candidate, DE = inclusive max (0 <= DE < $8000).
; Out: HL clamped to [0,DE]. Corrupts AF.
mouse_clamp:
    bit 7, h
    jr z, .nonneg
    ld hl, 0
    ret
.nonneg:
    or a
    sbc hl, de
    jr nc, .over
    add hl, de                  ; was in range: undo the probe subtract
    ret
.over:
    push de
    pop hl
    ret

; Upload the live 16x16 pattern (mousePattern - the built-in arrow, or
; whatever POINTER.SPR/POINTERn.SPR last replaced it with) to hardware
; sprite pattern slot 0. NOT one-time: MOUSE 1 runs it lazily whenever
; mouseReady reads 0 (which either mousePattern writer clears), and
; MOUSE n 5 calls it unconditionally on every single call, shape change
; or not - that is sub 5's re-arm guarantee (h_mouse.pointer, above).
; Port $303B selects the slot (chapter-next-sprites, "Loading
; Patterns into FPGA Memory"), port $xx5B streams the 256 bytes with
; auto-increment; B=0 into SPRITE_PAT_PORT's OTIR gives exactly 256
; iterations (nextdaad.inc). Corrupts AF, BC, HL.
mouse_pattern_load:
    xor a
    ld bc, SPRITE_IDX_PORT
    out (c), a                  ; pattern slot 0 (bit7=0, bits6-0=0)
    ld hl, mousePattern
    ld bc, SPRITE_PAT_PORT
    otir
    ret

; Position hardware sprite 0 at (mouseX+32, mouseY+32) - the sprites
; chapter's "fully on-screen" origin offset (Patterns: (32,32) is where
; a sprite is entirely inside the visible area; the coordinate plane
; overlaps the border by 32px each side). Does not touch the visible
; bit (register 38/NR_SPRITE_PAT) - safe to call any time, including
; before MOUSE 1 has ever run (the sprite just sits invisible at the
; new coordinates - harmless, since bit 7 there stays whatever sub
; 1/2 last left it, cold-default 0/invisible until sub 1 first runs).
; Corrupts AF, BC, DE, HL.
mouse_sprite_pos:
    call spr_di                 ; DI: the sprite tick (isr_hook_body) shares
    call mouse_sprite_body      ; the NR $34 select-then-write sequence
    jp spr_ei
mouse_sprite_body:              ; unbracketed: h_mouse.show wraps its own
    xor a
    nextreg NR_SPRITE_SEL, a
    ld hl, (mouseX)             ; plane coordinate as-is (0-319): the mouse
                                ; domain IS the 320x256 sprite plane, and the
                                ; tilemap GETMS reports against covers the same
                                ; plane, so no border inset (one put the arrow
                                ; four text rows below the row GETMS returned
                                ; and kept it out of the top-left 32px band)
    ld a, (mouseHotX)           ; SP16 B23 sub 6: shift the bitmap back
    call mouse_hotsub           ; so the hotspot pixel sits on mouseX
    ld a, l
    nextreg NR_SPRITE_X, a
    ld a, h
    ld b, a                     ; stash X's bit 8 (0 or 1 only)
    ld a, (mouseY)
    ld l, a
    ld h, 0                     ; HL = mouseY (0-255)
    ld a, (mouseHotY)           ; SP16 B23 sub 7 (B survives the call)
    call mouse_hotsub
    ld a, l
    nextreg NR_SPRITE_Y, a
    ld a, b
    and 1
    nextreg NR_SPRITE_ATTR, a   ; bit 0 = X's 9th bit; no mirror/rotate
    ld a, h
    and 1
    nextreg NR_SPRITE_ATTR2, a  ; bit 0 = Y's 9th bit; 8-bit anchor, 1x
    ret

; HL = max(HL - A, 0). The hotspot is a byte, HL is the 9-bit sprite
; coordinate, and a large hotspot near the plane's origin can underflow
; - floored rather than wrapped so the pointer parks at the edge
; instead of jumping to the far side. Corrupts AF, C. Preserves B, DE.
mouse_hotsub:
    or a
    ret z                       ; hotspot 0 (the default): no work
    ld c, a
    ld a, l
    sub c
    ld l, a
    ret nc
    dec h                       ; borrow into the 9th bit
    ret p                       ; H still 0 or 1: in range
    ld hl, 0                    ; went negative: floor at the plane's 0
    ret

mouseX:       dw 160
mouseY:       db 128
mouseHotX:    db 0           ; SP16 B23 DELTAXMS: pointer hotspot within
mouseHotY:    db 0           ; the bitmap, default (0,0) = the arrow tip
mouseBtn:     db 0
mouseXraw:    db 0
mouseYraw:    db 0
mouseBaseSet: db 0
mouseReady:   db 0
mouseP1:      db 0
mouseCol80:   db 0
mouseRow32:   db 0
mouseCol53:   db 0

; 16x16 arrow-cursor hardware sprite pattern, 8-bit colour index per
; pixel (chapter-next-sprites: 256 bytes/pattern slot for 8-bit
; sprites). Hotspot (registration point) is the tip at (0,0), matching
; mouse_sprite_pos's use of mouseX/mouseY as the sprite's own (0,0)
; corner - a conventional pointer arrow outlined in $00 (RGB332 black)
; with $FF fill (RGB332 white), on $E3 transparent (NR $4B's hardware
; soft-reset default, registers.txt: "soft reset = 0xe3" - nothing in
; this codebase reprograms it, so relying on it needs no extra write).
;
; ON THE THREE BYTE VALUES, because pointer art arrives wrong otherwise:
; a sprite pattern byte here is a COLOUR, not a palette index. This
; interpreter never loads a sprite palette, so the hardware's default
; identity palette applies and byte N renders as RGB332 colour N. Sprite
; editors and exporters that emit palette INDICES alongside their own
; palette file therefore do not drop straight in - their background
; index renders as whatever colour that number happens to be, opaque,
; instead of vanishing. Only $E3 is transparent, and it is transparent
; by INDEX compare (NR $4B), so exactly one byte value ever punches
; through - unlike Layer 2, where the compare is on colour and two of
; the 512 entries match.
; Row 0  BB..............      Row 8  BWWWBBBBB.......
; Row 1  BWB.............      Row 9  BWWB............
; Row 2  BWWB............      Row 10 BWB.............
; Row 3  BWWWB...........      Row 11 BB..............
; Row 4  BWWWWB..........      Row 12 ................
; Row 5  BWWWWWB.........      Row 13 ................
; Row 6  BWWWWWWB........      Row 14 ................
; Row 7  BWWWWWWWB.......      Row 15 ................
mouseArrow:
    db $00,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$00,$00,$00,$00,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3

; The LIVE pattern mouse_pattern_load uploads. Initialised from
; mouseArrow at boot; pointer_load overwrites it. Kept separate so
; MOUSE 0 5 can restore the built-in arrow after a numbered shape has
; replaced it - the pointer's analogue of tm_font_init, and the reason
; it costs 256 bytes of this page rather than nothing.
mousePattern: ds 256

; --- custom mouse pointer load ---
; Three triggers: boot, a part switch, and MOUSE n 5 at any point
; during play.
;
; mouseArrow (above) is a read-only `db` table. mousePattern (also
; above) is the LIVE `ds 256` buffer mouse_pattern_load uploads; it
; has exactly two writers: ptr_arrow_install's ldir (mouseArrow ->
; mousePattern, the revert-to-built-in path, below) and this routine's
; own ldir further down (a validated POINTER.SPR/POINTERn.SPR).
; mouseReady is the "pattern already uploaded to hardware sprite slot
; 0" latch h_mouse's sub-1 (.show) checks: both writers overwrite
; mousePattern then clear mouseReady, so the next MOUSE 1 re-OTIRs the
; new bytes to hardware.
;
; Restore the built-in arrow into the live buffer. Corrupts AF, BC, DE, HL.
ptr_arrow_install:
    ld hl, mouseArrow
    ld de, mousePattern
    ld bc, 256
    ldir
    call ptr_mask_scan
    xor a
    ld (mouseReady), a           ; force the next MOUSE 1 to re-OTIR
    ret

; Mark every palette block an opaque mousePattern byte falls in, so 4-bit
; sets never claim them. Both mousePattern writers call this, so the
; built-in arrow is covered when no pointer file ships. Corrupts AF, BC, DE, HL.
ptr_mask_scan:
    ld de, mousePattern
    ld hl, 0                     ; HL = mask
    ld b, 0                      ; 256 pixels via djnz
.px:
    ld a, (de)
    cp L2_TRANSP_COLOUR
    jr z, .skip
    swapnib
    and 15                       ; block = top nibble
    push bc
    push de
    ld b, a
    ld de, 1
    bsla de, b                   ; DE = 1 << block
    ld a, e
    or l
    ld l, a
    ld a, d
    or h
    ld h, a
    pop de
    pop bc
.skip:
    inc de
    djnz .px
    ex de, hl                    ; DE = mask; spr_call passes DE through
    ld hl, spr_pointer_mask_set
    jp spr_call

; A = shape number 0-9 -> ptrNameBuf = "POINTER.SPR",0 for 0, or
; "POINTERn.SPR",0 for 1-9, with ptrNameLen set to the byte count
; including the NUL. "POINTER9" is 8 characters, so every generated
; name is still 8.3. Corrupts AF, BC, DE, HL.
ptr_name_build:
    ld (ptrNum), a
    ld hl, ptrNameStem
    ld de, ptrNameBuf
    ld bc, 7                     ; "POINTER"
    ldir
    ld a, (ptrNum)
    or a
    ld c, 12                     ; "POINTER.SPR" + NUL
    jr z, .ext                   ; ld c does not touch flags
    add a, '0'
    ld (de), a
    inc de
    ld c, 13                     ; "POINTERn.SPR" + NUL
.ext:
    ld a, c
    ld (ptrNameLen), a
    ld hl, ptrNameExt
    ld bc, 5                     ; ".SPR" + NUL
    ldir
    ret

; A = shape number (0-9); ptr_name_build (above) turns it into
; POINTER.SPR (0) or POINTER<n>.SPR (1-9) in ptrNameBuf. Load:
; PARTn\<name> (curPart >= 2) then <name> at the root, a raw 256-byte
; 16x16 8-bit hardware sprite pattern. Absent = silent (the previously
; installed pattern stays); wrong size = silent + DEBUG marker.
; Never reads straight into the live mousePattern: MOUSE 1 can fire at
; any time and re-OTIR it, so the file lands in swapStage first and is
; only ldir'd into mousePattern once the exact size is confirmed.
; ptrCur is written only after that final ldir, so a failed load
; leaves it exactly as found (the n=0 caller, h_mouse.pointer, writes
; it beforehand since ptr_arrow_install has already installed the
; built-in arrow by then).
;
; Scratch buffer: swapStage (512 bytes, above) is reused rather than a
; new buffer - it is directly addressable from this page and 257 bytes
; fits its capacity. It is safe to reuse because swapStage only holds
; a live payload strictly within a single h_xpart/xpart_load_entry ->
; switch_to_part call chain, and this routine's own call site within
; that chain runs after the payload has already been installed into
; flags/objTable, so swapStage is free scratch by the time control
; reaches here.
;
; Corrupts AF, BC, DE, HL, IX.
pointer_load:
    call ptr_name_build          ; A = shape number, in
    ld a, (curPart)
    dec a
    jr z, .rootonly              ; curPart == 1: skip straight to the
                                  ; root name (T5 idiom, gfx_open_chain/
                                  ; font_load)
    ld hl, ptrNamePart
    ld (hl), 'P'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'R'
    inc hl
    ld (hl), 'T'
    inc hl
    ld a, (curPart)
    add a, '0'
    ld (hl), a
    inc hl
    ld (hl), '\'
    inc hl                        ; hl = ptrNamePart+6
    ex de, hl
    ld hl, ptrNameBuf            ; copy the built name (12 or 13 bytes)
    ld a, (ptrNameLen)
    ld c, a
    ld b, 0
    ldir
    call esx_getsetdrv
    jr c, .rootonly
    ld ix, ptrNamePart
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.rootonly:                        ; ORIGINAL (non-PARTn) name, reached
                                  ; both when curPart == 1 and as the
                                  ; PARTn\ fallback above
    call esx_getsetdrv
    ret c                         ; no drive at all: silent, buffer untouched
    ld ix, ptrNameBuf
    ld b, ESX_MODE_READ
    call esx_fopen
    ret c                         ; no POINTER.SPR either: silent, untouched
.opened:
    ld (ptrHandle), a
    ld a, (ptrHandle)
    ld ix, swapStage
    ld bc, 256
    call esx_fread
    jr c, .bad
    ld a, b                        ; exactly 256 read? (BC discipline -
    cp 1                           ; CF alone lies, the F_READ/F_WRITE
    jr nz, .bad                    ; count lesson; mirrors font_load)
    ld a, c
    or a
    jr nz, .bad
    ld a, (ptrHandle)               ; probe for a 257th byte - size must
    ld ix, swapStage+256            ; be exact, not just >= 256 (same
    ld bc, 1                        ; probe font_load itself runs)
    call esx_fread
    jr c, .bad
    ld a, b
    or c
    jr nz, .bad                     ; a successful 1-byte read here means
                                    ; the file is LONGER than 256: reject
    ld hl, swapStage                 ; exact size confirmed: scratch ->
    ld de, mousePattern               ; live buffer (this ldir and
    ld bc, 256                        ; ptr_arrow_install's, above, are
    ldir                               ; mousePattern's only two writers)
    call ptr_mask_scan
    xor a
    ld (mouseReady), a               ; force the next MOUSE 1 to re-OTIR
                                     ; the new pattern to hardware
    ld a, (ptrNum)                   ; installed: remember which
    ld (ptrCur), a
    jr .close
.bad:
 IFDEF DEBUG                        ; wrong size: no-op with a marker,
    call dbg_markcol                ; same idiom as h_sfx/h_mouse/
    ld b, 29                        ; font_load's own markers
    ld hl, msgPtrBad
    call dbg_mark
 ENDIF
.close:
    ld a, (ptrHandle)
    jp esx_fclose               ; tail call: same registers, flags and stack for the caller

; Boot-only glue for title_boot's one-way OVL2->OVL0 hop (overlay2.asm,
; .toPointer): neither this call nor switch_to_part is guaranteed to
; run before the game's first MOUSE 1 (h_mouse's own header, above), so
; the live buffer is never uninitialised - the pristine arrow goes down
; FIRST, then the base-shape probe runs over it exactly as MOUSE 0 5
; does, including that same ptrCur=0 pre-set (h_mouse.pointer's sub 5
; body, above) so an absent POINTER.SPR still leaves shape 0 correctly
; cached instead of $FF/unknown. A is set explicitly AFTER
; ptr_arrow_install's corrupting call, not inherited from it - see that
; same sub 5 body for the discipline and why it matters. Both calls
; live on this page, so one hop from overlay2 is enough; pointer_load's
; own ret still lands on whatever title_boot's caller was, unchanged.
; Corrupts AF, BC, DE, HL, IX (the union of both calls).
pointer_load_boot:
    call ptr_arrow_install
    xor a                        ; base shape number, explicit
    ld (ptrCur), a                ; installed: same pre-set as MOUSE 0 5
    jp pointer_load

; SP12 T3 pointer-load state, overlay0-local - parallel to fontHandle/
; fontNamePart's own PARTn machinery (overlay2.asm), but no scratch bank
; is needed here (see pointer_load's header: swapStage is directly
; addressable from this page already).
ptrHandle:    db $FF              ; esxDOS handle, valid only inside pointer_load
ptrNum:       db 0                ; number being built/loaded
ptrNameLen:   db 12               ; bytes in ptrNameBuf including the NUL
ptrCur:       db $FF              ; installed shape, $FF = unknown
ptrNameBuf:   ds 13               ; "POINTERn.SPR",0 worst case
; "PARTm\" (6) + the longest built name (13)
ptrNamePart:  ds 19
ptrNameStem:  db "POINTER"
ptrNameExt:   db ".SPR", 0

; Relocated from errors.asm (post-flags resident there had no room to
; grow - see fatal_puts's MMU7 map, file.asm). fatal_puts is the only
; reader: it maps this page at MMU7 before dereferencing either string,
; reached via err_raise directly or ddbtext.asm's rd_stack_fatal -> fatal.
; Fixed prefix; err_raise appends the single decimal digit itself.
msgRuntimeErr: db "NextDAAD: RUNTIME ERROR - E", 0
; Reader stack depth overflow (ddbtext.asm's rd_push/rd_pop).
msgRdStack:    db "NextDAAD: RD STACK - E9", 0

    DISPLAY "overlay0 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
