; Overlay page 0: condact handlers (sub-project 3). Assembled into
; 8K page 56 (bank 28, lower half) at $E000, mapped into slot 7 by
; the dispatcher only. Handler ABI: B = arg1 (indirection already
; applied), C = arg2; conditions return CF clear (true) / set (false).
    MMU 7, OVL0_PAGE, OVL_ORG

; --- shared condition returns ---
c_true:
    or a
    ret
c_false:
    scf
    ret

; Unimplemented / future-sub-project condact: debug marker, no-op.
; Returns CF SET so stub conditions (INKEY until Task 8) fail
; safely; harmless for actions (the engine ignores CF on actions).
h_unimpl:
 IFDEF DEBUG
    push bc
    ld b, 31
    ld c, 0
    call dbg_at
    ld hl, msgStub
    call dbg_puts
    ld a, (curCondact)
    call dbg_hex8
    pop bc
 ENDIF
    scf
    ret
msgStub: db "STUB ", 0

; B = flag number helper: HL -> flags[B]
fptr:
    ld h, high flags
    ld l, b
    ret

h_zero:                         ; 11: flags[B] == 0
    call fptr
    ld a, (hl)
    or a
    jp z, c_true
    jp c_false

h_notzero:                      ; 12
    call fptr
    ld a, (hl)
    or a
    jp nz, c_true
    jp c_false

h_eq:                           ; 13: flags[B] == C
    call fptr
    ld a, (hl)
    cp c
    jp z, c_true
    jp c_false

h_let:                          ; 51: flags[B] = C
    call fptr
    ld (hl), c
    ret

h_plus:                         ; 49: flags[B] += C, saturate 255
    call fptr
    ld a, (hl)
    add a, c
    jr nc, .st
    ld a, 255
.st:
    ld (hl), a
    ret

h_minus:                        ; 50: flags[B] -= C, floor 0
    call fptr
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
    ld a, 0
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
    ld a, b                     ; SKIP 254 (-2) re-runs the previous.
    ld e, a
    ld d, 0
    bit 7, a
    jr z, .pos
    ld d, $FF                   ; sign extend the distance
.pos:
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
    or a                        ; clears isDone, so after PROCESS n the
    jp nz, c_true               ; answer is that sub-process's alone
    jp c_false
h_isndone:                      ; 115: the complement of ISDONE
    ld a, (isDone)
    or a
    jp z, c_true
    jp c_false

h_redo:                         ; 108: restart the top table from its
    call eng_top_ix             ; first entry (own process number)
    ld a, (ix+0)
    add a, a
    ld e, a
    ld d, 0
    ld hl, (ddbHeader+HDR_PROCLST)
    add hl, de
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
    ; SP16 T6, V3 flag 53 bit 0: SET on entry ("nothing found yet"),
    ; CLEARED by eng_doall_next's .take on the first object. Two sites,
    ; both references - see the note at .take (engine.asm). B is live
    ; across this call and eng_v3f53 preserves it.
    ld de, F53_DOALLNONE<<8 | $FF
    call eng_v3f53
    ld a, b
    ld (doallLoc), a
    ld a, (procSP)
    ld (doallLevel), a
    call eng_top_ix
    ld a, (ix+1)
    ld (doallResE), a
    ld a, (ix+2)
    ld (doallResE+1), a
    ld a, (ix+3)
    ld (doallResC), a
    ld a, (ix+4)
    ld (doallResC+1), a
    ld a, $FF
    ld (doallObj), a
    jp eng_doall_next

h_at:                           ; 0: flags[38] == B
    ld a, (flags+FLAG_PLAYER)
    cp b
    jp z, c_true
    jp c_false
h_notat:                        ; 1
    ld a, (flags+FLAG_PLAYER)
    cp b
    jp nz, c_true
    jp c_false
h_atgt:                         ; 2: player > B
    ld a, (flags+FLAG_PLAYER)
    cp b
    jr z, cfalse_j
    jp nc, c_true
cfalse_j:
    jp c_false
h_atlt:                         ; 3: player < B
    ld a, (flags+FLAG_PLAYER)
    cp b
    jp c, c_true
    jp c_false
h_gt:                           ; 14: flags[B] > C
    call fptr
    ld a, (hl)
    cp c
    jr z, cfalse_j
    jp nc, c_true
    jp c_false
h_lt:                           ; 15: flags[B] < C
    call fptr
    ld a, (hl)
    cp c
    jp c, c_true
    jp c_false
h_noteq:                        ; 79
    call fptr
    ld a, (hl)
    cp c
    jp nz, c_true
    jp c_false
h_same:                         ; 76: flags[B] == flags[C]
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, (hl)
    cp d
    jp z, c_true
    jp c_false
h_notsame:                      ; 80
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, (hl)
    cp d
    jp nz, c_true
    jp c_false
h_bigger:                       ; 112: flags[B] > flags[C]
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, d
    cp (hl)
    jr z, cfalse_j
    jp nc, c_true
    jp c_false
h_smaller:                      ; 113: flags[B] < flags[C]
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, d
    cp (hl)
    jp c, c_true
    jp c_false
h_adject1:                      ; 16
    ld a, (flags+FLAG_ADJ1)
    cp b
    jp z, c_true
    jp c_false
h_adverb:                       ; 17
    ld a, (flags+FLAG_ADVERB)
    cp b
    jp z, c_true
    jp c_false
h_prep:                         ; 68
    ld a, (flags+FLAG_PREP)
    cp b
    jp z, c_true
    jp c_false
h_noun2:                        ; 69
    ld a, (flags+FLAG_NOUN2)
    cp b
    jp z, c_true
    jp c_false
h_adject2:                      ; 70
    ld a, (flags+FLAG_ADJ2)
    cp b
    jp z, c_true
    jp c_false
h_set:                          ; 47: flags[B] = 255
    call fptr
    ld (hl), 255
    ret
h_clear:                        ; 48
    call fptr
    ld (hl), 0
    ret
h_add:                          ; 71: flags[C] += flags[B], sat 255
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, (hl)
    add a, d
    jr nc, .st
    ld a, 255
.st:
    ld (hl), a
    ret
h_sub:                          ; 72: flags[C] -= flags[B], floor 0
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld a, (hl)
    sub d
    jr nc, .st
    xor a
.st:
    ld (hl), a
    ret
h_copyff:                       ; 125: flags[C] = flags[B]
    call fptr
    ld d, (hl)
    ld b, c
    call fptr
    ld (hl), d
    ret
h_copybf:                       ; 126: flags[B] = flags[C]
    ld e, b
    ld b, c
    call fptr
    ld d, (hl)
    ld b, e
    call fptr
    ld (hl), d
    ret
h_print:                        ; 53: flags[B] as decimal
    call fptr
    ld a, (hl)
    call prn_dec8
    jp prn_flush
h_dprint:                       ; 27: 16-bit from flags[B], flags[B+1]
    call fptr
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
    jp nz, c_true
    jp c_false
h_hasnat:                       ; 59
    call hasat_ptr
    and (hl)
    jp z, c_true
    jp c_false
; B = param -> HL = flags + (base - B/8), A = 1 << (B mod 8).
; DAAD numbers attributes DOWN from flag 59: attr 0-7 -> flag 59,
; 8-15 -> flag 58, WEARABLE 23 -> flag 57 bit 7, MOUSE 240 -> flag 29
; bit 0 (manual 1062-1069). Corrupts AF, B, E, HL.
;
; SP16 T6, V3: flag 53 bit 1 moves the whole bank to base 91 instead -
; flags 60-91, exactly 32 bytes, the same 256 attributes (PRP013 V3-04,
; PCDAAD condacts.pas:1207-1218). This is the ONE addressing helper for
; HASAT (58), HASNAT (59) and the new SETAT (124), so SP16 A5's byte
; order and this base selection are shared by all three by construction
; rather than by three copies agreeing.
;
; PCDAAD applies the bit-1 test on any database version; msx2daad gates
; it on ISV3. NextDAAD follows msx2daad: under V2 flag 53's low bits are
; the game's own property (only bits 6 and 7 are specified), and moving
; the attribute bank out from under a V2 game that happens to store
; something in bit 1 would be a regression, not a feature.
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
    bit 1, (hl)                 ; F53_ALTFLAGS
    jr z, .base
    ld a, 91                    ; alternative bank: flags 60-91
.base:
    sub b
    ld b, a                     ; B = base - B/8
    call fptr
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
    call fptr
    ld a, (hl)
    ld (indirArg2), a
    ld a, 1
    ld (indirValid), a
    ret
h_random:                       ; 95: flags[B] = 1..100
    call rng_next
    call fptr
    ld (hl), a
    ret
h_chance:                       ; 10: true B% of the time
    call rng_next
    cp b
    jp c, c_true
    jp z, c_true
    jp c_false
; 16-bit xorshift, seeded at eng_init_game. Out A = 1..100.
; Preserves BC.
;
; SP16 (parser-bugs entry 3). This used to rotate (rrca/rlca) where a
; xorshift needs to SHIFT, which made the state transform a tiny-order
; permutation: every seed landed on a cycle of at most 16 states, the
; shipped seed produced only six distinct RANDOM values, and CHANCE 50
; fired 62% of the time. Now the real thing:
;
;   x ^= x << 7;  x ^= x >> 9;  x ^= x << 8
;
; period 65535 (verified exhaustively: the orbit is every non-zero
; state exactly once). The constants are the Z80-cheap triple - a
; shift by 8 is a register move (doc 06a "Shift Left/Right 8", 3
; bytes), and 7 and 9 are each one move plus one shift (doc 06a
; "Shift Left 7" fastest form, "Shift Right 9").
;
; Byte-level identities used below, with x = (H,L):
;   x<<7 = ( (H&1)<<7 | L>>1 , (L&1)<<7 )   -> the SRL H/RR L/RRA form
;   x>>9 = ( 0 , H>>1 )                     -> low byte only
;   x<<8 = ( L , 0 )                        -> high byte only
;
; Output scaling is A = (x * 100) >> 16, +1. The old scaling folded the
; state to one byte (H xor L) and reduced it mod 200 then mod 100,
; which is NOT uniform over 1..100: 200..255 wrapped onto 1..56, so
; those 56 values drew 3 tickets in 256 and the rest drew 2, and
; CHANCE 50 would have fired 58.6% of the time even on a perfect
; generator. Scaling the whole 16-bit state instead gives 655 or 656
; states per outcome across the period - CHANCE 50 measures 50.00%
; exactly - and matches what the references compute (jdaad _RANDOM:
; floor(random()*100)+1). Two Z80N MUL D,E do the 16x8 product
; (doc 11: MUL is the Next's one-instruction 8x8, 8T).
rng_next:
    push bc
    push de
    push hl
    ld hl, (rngState)
    ; --- x ^= x << 7 ---
    ld d, h
    ld e, l                     ; DE = x
    xor a
    srl h
    rr l
    rra                         ; HL = x << 7 (doc 06a shift-left-7)
    ld h, l
    ld l, a
    ld a, h
    xor d
    ld h, a
    ld a, l
    xor e
    ld l, a                     ; HL = x ^ (x << 7)
    ; --- x ^= x >> 9 --- (high byte of x>>9 is always 0)
    ld a, h
    srl a
    xor l
    ld l, a
    ; --- x ^= x << 8 --- (low byte of x<<8 is always 0)
    ld a, h
    xor l
    ld h, a
    ld (rngState), hl
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

h_present:                      ; 4
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jp z, c_true
    cp OBJ_WORN
    jp z, c_true
    ld e, a
    ld a, (flags+FLAG_PLAYER)
    cp e
    jp z, c_true
    jp c_false
h_absent:                       ; 5
    call h_present
    ccf
    ret
h_worn:                         ; 6
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_WORN
    jp z, c_true
    jp c_false
h_notworn:                      ; 7
    call h_worn
    ccf
    ret
h_carried:                      ; 8
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jp z, c_true
    jp c_false
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
    jp z, c_true
    jp c_false
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
    ld b, c
    call fptr
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
    call fptr
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

; The "scan every location" sentinel for D, below. It CANNOT be $FE:
; that is OBJ_CARRIED (nextdaad.inc:283), and every "carried" pass in
; this file loads exactly that value - so `ld d, OBJ_CARRIED` was
; landing on the anywhere branch and scanning the whole table instead
; of the carried objects. obj_find_n1 read [anywhere, worn, here,
; anywhere], auto_cwh read [anywhere, worn, here], and the search
; PRIORITY the AUTO- family is built on did not exist. Found while
; testing D1, whose partial/full rule is priority-sensitive by
; construction (see check 90 in tests/condacts.dsf). $FF is the only
; safe value left: 0-251 are real locations, 252/253/254 are the object
; specials, and no object's location byte is ever 255 - obj_move raises
; error 2 rather than store one, and 255 as a CONDACT parameter means
; "the player's location" and is translated before it gets here
; (h_place, h_puto, and now h_autot).
OBJ_ANYLOC      equ $FF

; D = location to scan (OBJ_ANYLOC = anywhere). Matcher on Noun1/Adj1.
; Out: A = object CF clear, else CF set. Preserves D and E.
; Corrupts AF, B, C, HL, IY.
;
; SP16 D1 - jDAAD's partial-match rule, best-so-far in a single scan
; (jdaad.js:756-781, getObjectByVocabularyAtLocation):
;   FULL match    = noun equal AND (the adjectives are equal, or the
;                   object's adjective is 255 "takes any adjective").
;                   Wins outright, returns immediately.
;   PARTIAL match = noun equal AND flags[35] == 255, i.e. the player
;                   named no adjective. The FIRST partial is remembered
;                   in C and the scan CONTINUES, because a full match
;                   further down the table still beats it; the partial
;                   is returned only if the scan ends without one.
; Before this, flags[35] == 255 against an object that HAS an adjective
; was no match at all, so "GET LAMP" could not reach a "QUAINT LAMP".
; Keeping the partial subordinate to a full match is what preserves
; disambiguation: with a RUSTY and a SHINY SWORD in the table,
; "GET RUSTY SWORD" still takes the rusty one whatever the table order.
;
; The partial/full decision is deliberately resolved INSIDE one pass.
; The AUTO- family and obj_find_n1 call this once per location, in
; priority order, so a partial found here beats any match at a LOWER
; priority location and loses to a full match at THIS one - which is
; exactly what the references do, they run the whole matcher per
; location too. auto_probe's all-locations existence probe (SP16 B9)
; uses the same routine and simply gets a truer answer now: an object
; whose adjective the player omitted counts as existing.
;
; obj2_resolve (overlay1.asm) resolves Noun2/Adj2 and stays LENIENT by
; design: it accepts object-adj 255, player-adj 255, or an exact pair,
; and takes the first candidate in table order with no full-beats-
; partial preference (msx2daad's getObjectId rule, daad_objects.c:22).
; The two agree on every input that has a full match; they can differ
; only in WHICH candidate a bare noun picks when several share it.
obj_find_pass:
    ld c, $FF                   ; C = remembered partial, $FF = none
    ld b, 0
.scan:
    ld a, (numObj)
    cp b
    jr z, .miss
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
    ld a, b
    push bc
    push de
    call obj_ptr
    pop de
    pop bc
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

; WHATO's ordering: carried, worn, here, anywhere. Since SP16 B10 this
; is WHATO's alone - the anywhere pass is correct there (both references
; keep it, jDAAD with a comment saying the documentation is wrong about
; it) and wrong for AUTOT, which now calls auto_cwh instead.
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
    ld a, 0
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
    push bc
    call obj_weight_of
    pop bc
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
; PUTIN/TAKEOUT composite "<SMe> <container name><SM51>" (msx2daad
; _internal_putin / _internal_takeout). There is NO space before SM51 -
; owner ruling 2026-08-01 on parser-bugs entry 28: SM51 is "." in the
; stock message table, so the trailing space rendered "the old box ."
; The LEADING space stays (msx2daad prints it; jDAAD does not).
; The name goes through the same
; objname path the '_' escape uses, which reads flag 51, so flag 51
; holds the CONTAINER for the duration and is put back afterwards -
; the referenced object is game-visible state and must not shift.
msg_in_obj:
    push bc
    call sysmsg
    pop bc
    ld a, (flags+FLAG_CUROBJ)
    push af
    ld a, c
    ld (flags+FLAG_CUROBJ), a
    ld c, ' '
    call prn_char
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
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp OBJ_CARRIED
    jr z, .have
    cp OBJ_WORN
    jr z, .have
    ld e, a
    ld a, (flags+FLAG_PLAYER)
    cp e
    jr nz, .nothere
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
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
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
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
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
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
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
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
    ld a, b
    push bc
    call obj_ptr
    ld a, (hl)
    pop bc
    cp OBJ_CARRIED
    jr z, .drop
    cp OBJ_WORN
    jr nz, .next
.drop:
    push bc
    ld a, (flags+FLAG_PLAYER)
    ld c, a
    ld a, b
    call obj_move
    pop bc
.next:
    inc b
    jr .scan

h_putin:                        ; 90: carried obj B -> container loc C
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
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
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
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
    call weight_bust            ; restored: TAKEOUT had no weight test
    jr nc, .cap
    ld e, 43
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
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
    ld a, d
    push bc
    push de
    call obj_ptr
    ld a, (hl)
    pop de
    pop bc
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
    call objscan_tick           ; SP14c gate follow-up: OV0-3 measurement
    ld a, b
    push bc
    call obj_ptr
    ld a, (hl)
    pop bc
    cp OBJ_CARRIED
    jr z, .add
    cp OBJ_WORN
    jr nz, .next
.add:
    push bc
    ld a, b
    call obj_weight_of
    pop bc
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
    push bc
    call obj_weight_of
    pop bc
    ld d, a
    ld b, c
    call fptr
    ld (hl), d
    ret
h_weight:                       ; 94: flags[B] = carried+worn total
    push bc
    call weight_total
    pop bc
    ld d, a
    call fptr
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
    ld a, c
    cp TM_COLS
    jr c, .cok
    ld a, TM_COLS-1
.cok:
    ld c, a
    ld a, WIN_X
    call win_field
    ld (hl), c
    inc hl
    ld (hl), b
    ld a, TM_COLS
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
    ld a, TM_COLS
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
    ld a, TM_COLS
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
    ; SP16 (docs/daad-compliance-report.md section 4, "Flag 61"):
    ; flag 61 (fKey2, the IBM extended code) is cleared whenever flag
    ; 60 is written. This handler used to write flag 60 alone and
    ; leave a previous game's value in 61.
    ; THE REFERENCES DISAGREE, so be precise about which one this
    ; follows. jDAAD's _INKEY2 (jdaad.js:4111-4125) writes BOTH flags
    ; on BOTH paths - hit: 60 = key, 61 = 0; miss: 60 = 0, 61 = 0.
    ; msx2daad's do_INKEY (daad_condacts.c:644-651) writes flag 60
    ; ONLY on a hit and never touches flag 61 at all; the one place it
    ; clears fKey2 is the DAADV3 "PAUSE 0" GETKEY path (line 2100).
    ; We follow jDAAD. key_scan returns 0 for "no key", so the code
    ; below writes both flags unconditionally and lands on jDAAD's
    ; behaviour for the hit and the miss alike.
    ; This is the ONLY writer of flag 60 (grepped).
    ld hl, flags+FLAG_KEY1      ; doc 07 (a): flags is ALIGN 256, so
    ld (hl), a                  ; the pair is one INC L apart and the
    inc l                       ; store leaves A and F alone for the
    ld (hl), 0                  ; condition test below
    or a
    jp nz, c_true
    jp c_false
h_anykey:                       ; 24
    ld e, 16
    ld a, 0
    call print_msg
    ld e, $04                   ; ANYKEY timeout arm bit
    call wait_key_timeout
    jp prn_reset_lines
h_pause:                        ; 35: B frames, 0 = 256
    ; SP16 A2 tail. Under V3, PAUSE 0 is GETKEY: block for a keypress
    ; and store it in flags 60/61, exactly as msx2daad's do_PAUSE V3
    ; branch does (PRP013 V3-09). DRB compiles the GETKEY keyword to
    ; PAUSE 0 and rejects it outside -v3 (drb.php:947-955), and a fresh
    ; -v3 compile emits 23 00 for it. No prn_reset_lines on this arm -
    ; the reference returns straight out, and GETKEY is a value read,
    ; not a pager pause like ANYKEY.
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
sm_first_char:
    push de                     ; rd_push and data_save both preserve DE
    call rd_push                ; now; bracket kept but redundant
    call data_save
    pop de
    ld a, 0
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
    push de
    call rd_pop
    pop de
    ret
.none:
    ld d, 'Y'
    call data_restore
    push de
    call rd_pop
    pop de
    ret

; Read one LINE of confirmation input: echo each printable character,
; ENTER ends it, and the FIRST printable character is the answer.
; Out: A = that character, or 0 for an empty line. Corrupts all.
;
; SP16 parser-bugs entry 4, SETTLED 2026-07-31 against the ORIGINAL ZX
; interpreter. NextDAAD used to take a single keypress here, citing the
; DAAD manual; jDAAD (_QUIT -> getPlayerOrders) and msx2daad (do_QUIT ->
; prompt(false), whose doc comment says "the remainder of the entry is
; discarded" - language that only makes sense for a line) both read a
; line, leaving NextDAAD the outlier of three. The tie-breaker was run:
; .superpowers/sdd/sp16-adjudications/zxadj.dsf on ASSETS/ZX/
; ZXSPECTRUM/DS48IE3.BIN under ZEsarUX, driving QUIT to its SM12
; prompt and then sending a bare Y with NO enter -
;
;     [after QUIT - SM12 prompt]      Are you sure?>_
;     [after a bare Y with NO enter]  Are you sure?>Y_     (flag still 0)
;     [after the following ENTER]     V=30 N=255 Q=1       (accepted)
;
; The Y is ECHOED into a line and nothing happens until ENTER. Full
; transcript: sp16-adjudications/zxadj-transcript.txt. So NextDAAD was
; wrong and now reads a line too.
;
; Scope of the reproduction: the original prompts through its full line
; editor, this reads a line without in-line editing (no backspace, no
; recall). inp_edit, which has all of that, lives in overlay1 and there
; is no resident trampoline for overlay0 to reach it - ovl_map_page's
; own contract is "call from resident code". What IS reproduced is the
; part the divergence was about: the input is a LINE, nothing acts
; until ENTER, and the first character decides.
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
    cp 'a'                      ; fold to upper before BOTH the echo and
    jr c, .fold                 ; the latch: key_scan's map is lowercase
    cp 'z'+1                    ; only (no caps/symbol layer down here -
    jr nc, .fold                ; that lives in overlay1's kb_char), and
    sub 32                      ; classic DAAD input reads all-caps
.fold:
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
    ld a, 0
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
    cp 'a'
    jr c, .cmp
    cp 'z'+1
    jr nc, .cmp
    sub 32
.cmp:
    cp d
    ret

h_quit:                         ; 20: condition - Y (SM30) confirms quit
    ld e, 12
    ld c, 30
    call confirm
    jp nz, c_false
    call eng_set_done
    jp c_true
h_end:                          ; 21: a reply starting with N (SM31) =
    ld e, 13                    ; exit to OS, anything else = restart.
                                 ; The manual (2004-2010) describes this
                                 ; as a keypress; SP16 measured the
                                 ; original ZX interpreter reading a
                                 ; LINE at the sibling QUIT prompt (see
                                 ; confirm_read above), so END reads one
                                 ; too - both go through confirm.
    ld c, 31
    call confirm
    jr z, .off
    ld c, 0
    call eng_init_game
    xor a
    ld (procSP), a
    ret
.off:
    di                          ; no ISR tick may re-voice a note
    call audio_init             ; between the silence and the reset
    nextreg 2, 1
    jr $
h_exit:                         ; 110: 0 = hard reset, else full restart
    ld a, b
    or a
    jr z, .hard
    ; SP16 B18: a NON-ZERO EXIT restarts the whole game. It was routed
    ; to h_unimpl (a no-op). The manual: "Any value other than 0 will
    ; restart the whole game. Note that unlike RESTART which only
    ; restarts processing, this will clear and reset windows etc."
    ; Both references agree - msx2daad's do_EXIT runs initFlags();
    ; do_RESET(); do_RESTART() (daad_condacts.c:2367), jDAAD's _EXIT
    ; runs resetWindows(); resetFlags(); resetObjects(); _RESTART()
    ; (jdaad.js:4081). eng_init_game IS that machinery here: it clears
    ; all 256 flags, restores the SP16 C1/C2 defaults, rebuilds the
    ; object table from the DDB (locations, attributes, names) and
    ; recounts flag 1, then selects window 0 and empties the process
    ; stack; windows_init re-establishes the eight windows' geometry,
    ; which eng_init_game alone does not. h_restart's DOALL wipe
    ; completes the RESTART half - eng_step then re-pushes PRO 0 from
    ; the empty stack, exactly as h_end's restart branch above does.
    ; On platforms with PARTS the value is a part number; that is
    ; NextDAAD's separate XPART/EXTERN 4 mechanism and is untouched.
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
                                 ; MOVE MARKS THE TABLE DONE ON ALL THREE
                                 ; EXITS (owner ruling 2026-08-04): the
                                 ; verb bail below, .match and .nomatch.
                                 ; msx2daad is the model - its row is
                                 ; { do_MOVE, 1 } (daad_condacts.c:49) and
                                 ; the dispatcher's "isDone |= ce->flag"
                                 ; (:204) runs after do_MOVE returns down
                                 ; ANY of its paths, including the
                                 ; "if (flags[fVerb]<14)" guard (:1543)
                                 ; falling straight through to
                                 ; "checkEntry = false" (:1554). jdaad
                                 ; marks on failure only - _MOVE's
                                 ; success arm "return"s at jdaad.js:4048
                                 ; before the trailing "done = true" at
                                 ; :4053 - which reads as a jdaad bug,
                                 ; hence msx2daad.
                                 ;
                                 ; Stamped at ENTRY rather than three
                                 ; times: nothing between here and the
                                 ; three exits can abort the handler (the
                                 ; readers and fptr all return normally,
                                 ; and no path pushes a process, which is
                                 ; the only thing that CLEARS isDone), so
                                 ; entry-once and exit-thrice are the same
                                 ; set for 6 fewer bytes. eng_set_done
                                 ; corrupts A only, so B - the flag
                                 ; number - survives, and A is reloaded on
                                 ; the next line anyway.
    call eng_set_done
    ld a, (flags+FLAG_VERB)
    cp 14
    jp nc, c_false
    ld (moveVerb), a
    call fptr                   ; HL = flags + B
    ld a, (hl)                  ; A = flags[B] (location to search)
    push hl                     ; save flags+B pointer for the write-back
    ld hl, (ddbHeader+HDR_CONLST)
    ld e, a
    ld d, 0
    add hl, de
    add hl, de                  ; HL = HDR_CONLST + location*2
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
    jp c_true                   ; (done already stamped at entry)
.nomatch:
    call data_restore
    pop hl
    jp c_false
; SYNONYM verb noun (36). SP16 T6 / PRP019 V3-12: the substitution is
; version-independent, the done-marking is not. Z80 and 6502 DAAD V2
; mark DONE; the 68k sources had already stopped, and V3 makes that
; official ("In V3, SYNONYM no longer marks DONE"). NextDAAD is a Z80
; interpreter, so V2 keeps the mark.
;
; This is why cprops row 36 is condition-typed (engine.asm): an action
; row has the dispatcher stamp the table done before the handler runs,
; and the handler cannot un-stamp it without also wiping a done that an
; EARLIER condact in the same entry set. Marking it here instead is
; exact. Both arms return c_true, so the entry continues either way -
; identical to the action row's post-dispatch path.
;
; ISDONE now reads the accumulating isDone cell, so the V2/V3 split is
; visible WITHIN a single entry, exactly as it is in the references:
; tests_condacts_v3.c's entry-level SYNONYM/ISDONE cases were written
; against that model. (Until the SP18 fix NextDAAD read the last POPPED
; process's flag instead - compliance report B20 - and those cases could
; only show up on the PROCESS n / ISDONE idiom.)
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
    ld hl, ddbVer
    bit 0, (hl)
    jp nz, c_true               ; V3: SYNONYM does not mark done
    call eng_set_done
    jp c_true
h_newtext:                      ; 92: discard pending input orders so a
    xor a                       ; rejected order's compound tail dies
    ld (inpPending), a          ; (inpPending is resident)
    ret
h_extern:                       ; 61: fn C via vector, A = B on entry
    ld a, c
    cp 16
    jp nc, h_unimpl
    ld l, c
    ld h, 0
    add hl, hl
    ld de, extVec
    add hl, de
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

; EXTERN offset_lsb 3 offset_msb (XMESSAGE): print a message from
; the DRC-emitted external text file 0.XMB. The engine has already
; consumed the third byte into extArg3 (stream integrity). The
; message bytes are staged into the XMES bank - claimed from the
; pool once, kept for the session - and printed with the standard
; DDB text machinery via rd_seek_page (identical encoding: XOR-$FF
; bytes, $0A terminator, DRF bakes XMESSAGE's trailing newline into
; the text itself, so no prn_newline call is needed here). All
; failures are silent no-ops; the DEBUG marker shows on the missing-
; file/read-fail paths. EXTERN is action-typed (cprops), so the
; engine never consults the CF this leaves - unlike a condition
; handler there is no success/failure contract to honour on return.
; XMES lsb msb (condact 120) - the V3-native spelling of the same
; thing, and a thin wrapper over the primitive below (SP16 A2; the
; sav-machinery convention: overlays extend by adding routines on top
; of the resident/existing primitive, never by relocating it). DRB
; rewrites the source keyword XMES into opcode 120 with the 16-bit
; 0.XMB offset split across the two parameters (drb.php:842-855), so
; the offset arrives in B (LSB) and C (MSB) instead of B and extArg3.
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
    ; NextZXOS dot command supplies through its own wrapper. The
    ; previous comment's defrag.asm/fragmentation.asm citation was a
    ; category error - those ARE dot commands, so they exercise the L
    ; convention, not this one; SP11 T4's sav_append_part (overlay1.asm)
    ; is the correct raw-caller precedent, cross-confirmed against
    ; tools/NextZXOS's bundled bmp2spr.asm (same "ld ix,0" idiom).
    ; Fixed per SP11 T5 rider (opus-review finding M2): IXL now set
    ; explicitly; L kept too, belt-and-braces (harmless - unread on
    ; this path). This worked on CSpect before possibly by register
    ; coincidence; the hardware sweep re-verifies.
    ld bc, 0
    ld de, (xmsOff)
    ld l, 0                     ; mode 0 = from start (belt-and-braces
                                 ; only - see comment above)
    ld ix, 0                    ; mode 0 = from start (the register
                                 ; that actually matters - see above)
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
    ; (The XMB rider instrument - xmb-corruption-report.md "prescribed
    ; next instrument" #1, xmsOff + first-decoded-byte print - lived
    ; here until the SP17 T8 wave: its B1 question was ANSWERED on
    ; silicon, hypothesis 4b cleared, and the rider was stripped as
    ; promised.)
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
    call dbg_at
    ld hl, msgXmesFail
    call dbg_puts
    pop bc
 ENDIF
    ret

msgXmesFail: db "XMES?", 0
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
    ld a, (hl)
    cp 'X'
    jp nz, .reject
    inc hl
    ld a, (hl)
    cp 'B'
    jp nz, .reject
    inc hl
    ld a, (hl)
    cp 'N'
    jp nz, .reject
    inc hl
    ld a, (hl)
    cp 1
    jp nz, .reject
    inc hl
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

    ld hl, (.hdrSize)             ; xbnEnd = $C000 + size
    ld de, DATA_WINDOW
    add hl, de
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
    ld a, 1
    jr .setint
.noint:
    xor a
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
    call dbg_at
    ld hl, .msgFail
    call dbg_puts
    pop bc
 ENDIF
    ld a, (.handle)
    jp esx_fclose

.msgFail:   db "XBN?", 0
.name:      db "GAME.XBN", 0
.handle:    db 0
.statbuf:   ds 11
.fsize:     dw 0
.got:       dw 0
.hdrExt:    dw 0
.hdrInt:    dw 0
.hdrSize:   dw 0
.hdrEnd:    dw 0

; --- SP11 Task 3: part switch primitive (EXTERN n 4 / XPART) ---

; h_xpart: EXTERN n 4 (XPART). h_extern's contract leaves A = B = the
; first EXTERN argument (n, the target part 1-9) on entry; C still
; holds the vector index (4, unused here). Validates n, then snapshots
; the LIVE 256 flags + object-location table into swapStage before
; handing off to switch_to_part. Both failure exits (n out of range,
; or n == curPart) return with CF set: EXTERN is action-typed (cprops
; $82 - engine.asm's cprops table), so eng_exec never consults the CF
; this leaves (ext_xmes's header comment notes the same); the ret
; simply returns to h_extern's caller (eng_exec's post-dispatch code)
; via the same return address h_extern's own jp-tail-chain left on the
; stack, exactly as if EXTERN had dispatched to ext_stub. curPart is
; not written until switch_to_part has a confirmed-successful probe,
; so both failure exits here leave the current part fully untouched.
; Out-of-range n gets a DEBUG marker (author diagnostics, same idiom
; as h_sfx/h_mouse's unknown-sub-command markers); n == curPart stays
; silent on purpose - see .noop below.
h_xpart:
    cp 1
    jr c, .range                ; n < 1
    cp 10
    jr nc, .range                ; n > 9
    ld hl, curPart
    cp (hl)
    jr z, .noop                  ; n == curPart: a same-part EXTERN is a
                                 ; benign author idiom (e.g. a shared
                                 ; process reached while already in part
                                 ; n), not an error - stays silent, no
                                 ; DEBUG marker, unlike the range check
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
    push af                     ; (here in A, not C) across dbg_at/
    ld b, 29                    ; dbg_puts (both corrupt AF) for the
    ld c, 70                    ; dbg_hex8 below.
    call dbg_at
    ld hl, msgXpartRange
    call dbg_puts
    pop af
    call dbg_hex8
    pop af
 ENDIF
.noop:
    scf
    ret

; switch_to_part: A = target part number 1-9. Caller contract: swapStage
; (256 live flags + up to 256 object-location bytes) and swapObjCount
; (the OLD part's object count, for the install's min(old,new) rule)
; are already populated - h_xpart does this from live state above;
; Task 4's LOAD auto-switch is expected to populate them from a save
; file's payload instead and reuse this exact entry point. On probe
; failure: CF set, ret, current part untouched (DEBUG marker - the
; author tests their own part graph, per the design doc's convention).
; On success: NEVER RETURNS - resets SP and enters the new part fresh
; at PRO 0.
;
; Step 1 ground truth (engine.asm, read-only): eng_init_game has no
; label between its flag/object init and the rest (window select,
; procSP/doallObj reset, RNG reseed) - the two are not separable, so
; the "existing post-init entry label" shape is unavailable. This uses
; the brief's approved alternative instead: run the FULL eng_init_game
; against the newly-loaded DDB (rebuilds flags to defaults and objTable
; to the new part's compiled initial state), then RE-INSTALL swapStage
; over that fresh state before ever entering eng_run - double init,
; zero engine.asm bytes, correct per the brief's Step 3(i) fallback.
;
; ddbName (errors.asm, resident - the buffer ddb_load unconditionally
; reads via its own hardcoded "ld ix, ddbName" in file.asm, unmodified)
; is a 10-byte buffer: "GAMEn.DDB",0 is 9 characters + NUL, fitting
; exactly. xpart_build_name below writes the LITERAL target name for
; every part, n=1 included - no wildcard.
;
; History (superseded - kept for the review trail): the first cut of
; this routine wrote a wildcarded "GAMEn.D*" into file.asm's ORIGINAL
; 9-byte ddbName (one byte short of the literal 10-byte name; ddbHandle,
; the very next resident byte there with no gap, was clobbered by
; ddb_load's own preamble before the name was ever read, so there was
; no slack to borrow), relying on esxDOS F_OPEN's documented '*'/'?'
; wildcard support for read-only opens of an existing file. That is
; correct against the DOCUMENTED esxDOS contract, but the owner's
; CSpect sweep found CSpect's esxDOS emulation does not implement
; wildcard F_OPEN - the fixture failed on CSpect specifically (a real-
; hardware run was confirming in parallel). Fix: ddbName moved to
; errors.asm's post-flags region (file.asm's pre-flags region had no
; room to grow by 1 byte without risking engine.asm's flags ALIGN 256
; pad - a pre-flags SHRINK is safe there, per T7's precedent, but a
; GROWTH is not) with 1 extra byte of capacity, eliminating the
; wildcard and the ddbHandle-adjacency hazard together (ddbHandle stays
; in file.asm, no longer adjacent to ddbName at all). Our own pre-load
; probe below opens that SAME ddbName content (not a separate
; exact-name buffer), so the probe and the load always resolve to the
; identical file.
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
    ld a, $FF
    ld (ptrCur), a               ; part switch re-probes the base shape
    xor a
    call pointer_load
    ; Point of no return: abandon the old (deep, process-interpreter)
    ; stack entirely and enter the new part from scratch (nothing on
    ; the old stack matters past this line).
    ld sp, STACK_TOP
    ; One-way cross-overlay DOUBLE hop: font reload (overlay2), then the
    ; SFB re-probe (overlay1, brief Step 3h) - SP12 T1 inserts the font
    ; leg ahead of the pre-existing SFB one. aud_load_sfb (overlay1.asm)
    ; has been PARTn\-prefix-aware since SP11 Task 5, and font_load
    ; (overlay2.asm, SP12 T1) the same way; curPart is already committed
    ; above (several lines up), before this call, so both prefixes
    ; activate automatically on every switch - no extra wiring needed
    ; here. Both targets live in overlays other than this one, reached
    ; via the push-target/jp-ovl_map_page trampoline (banks.asm's
    ; ovl_map_page contract; the title_chain precedent, overlay1.asm
    ; ~2046). font_load_switch (overlay2) and aud_load_sfb (overlay1)
    ; are both normal call/ret routines reached here via jp, not call -
    ; so nothing of ours is on the stack for their rets to consume
    ; except what we push. Pushing eng_run's (resident) address BELOW
    ; font_load_switch's on the fresh stack means font_load_switch's own
    ; tail-hop to aud_load_sfb, and THAT routine's own ret, land directly
    ; on eng_run once the whole chain finishes - a second, automatic
    ; one-way hop that needs no new resident landing pad (off-limits -
    ; HARD RULES touch only overlay0.asm/overlay2.asm this task).
    ; eng_run is resident, so MMU7 being left on OVL1_PAGE afterward is
    ; harmless - the condact dispatcher remaps per-condact as it always
    ; does.
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
    call dbg_at
    ld hl, msgXpartFail
    call dbg_puts
    pop bc
 ENDIF
    scf
    ret

; Build the DDB filename for part A (1-9) into ddbName (errors.asm's
; resident 10-byte buffer - see switch_to_part's header comment for
; the relocation history). n=1 writes the exact, literal "GAME.DDB"
; (byte-identical to ddbName's assembled default, all 10 bytes incl.
; the spare). n=2-9 write the exact, literal "GAMEn.DDB" (9 characters
; + NUL, fills all 10 bytes with zero spare). No wildcard either way.
; Corrupts AF, HL.
xpart_build_name:
    cp 1
    jr nz, .multi
    ld hl, .gameddb
    ld de, ddbName
    ld bc, 10
    ldir
    ret
.multi:
    add a, '0'
    ld hl, ddbName
    ld (hl), 'G'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'M'
    inc hl
    ld (hl), 'E'
    inc hl
    ld (hl), a
    inc hl
    ld (hl), '.'
    inc hl
    ld (hl), 'D'
    inc hl
    ld (hl), 'D'
    inc hl
    ld (hl), 'B'
    inc hl
    ld (hl), 0
    ret
.gameddb: db "GAME.DDB", 0, 0     ; byte-identical to ddbName's own
                                  ; compiled default (errors.asm) -
                                  ; 8 chars + NUL + 1 spare = 10

 IFDEF DEBUG
msgXpartFail:  db "XPART?", 0
msgXpartRange: db "XPART N? ", 0
 ENDIF

; swapStage: staging buffer for a part switch. [0..255] = the full
; flags array, copied verbatim. [256..511] = one byte per object =
; objTable's location field ONLY (attribs/extattr/noun/adj are never
; carried - they always come from the new part's own compiled data),
; sized to objTable's declared maximum of 256 entries (engine.asm:
; "objTable: ds 256*OBJ_SIZE", OBJ_SIZE=6 - so 256 entries, matching
; the fixed maximum here even though numObj, a byte, can only ever
; reach 255 in practice). swapObjCount is the companion: the snapshot
; source part's object count at capture time, needed at install time
; to compute min(oldCount, newCount) (brief's OBJECT RULE). Both are
; populated by h_xpart from live state today; Task 4's LOAD auto-switch
; is expected to populate them from a save file's payload instead,
; using the same switch_to_part entry point unchanged.
swapStage:     ds 512
swapObjCount:  db 0
xpartTarget:   db 0

; --- SP11 Task 4: cross-part LOAD/RAMLOAD trampoline entry ----------
; Shared landing pad for BOTH sav_read_v2's cross-part SAV LOAD path
; and h_ramload's cross-part path (overlay1.asm) - swapStage/
; swapObjCount above live in this (OVL0) page and cannot be written
; directly from overlay1 ("Calls RESIDENT services only - never
; overlay0", overlay1.asm's own header comment), so both callers stage
; their payload into a resident buffer first (savStage+savLocs for
; LOAD, ramSaveBuf+ramSaveBuf+256 for RAMLOAD) and hop here via the
; established trampoline idiom (push target, ld a,OVL0_PAGE, jp
; ovl_map_page - precedented by switch_to_part's own SFB re-probe hop
; into overlay1, above).
;
; Entry (ovl_map_page corrupts AF only - BC/DE/HL/IX all survive the
; hop, per its own header comment in banks.asm): HL = flags source
; (256 bytes, verbatim), IX = object-location source (packed one byte
; per object), B = source part's object count 0-255, C = target part
; 1-9.
;
; Calls switch_to_part (unmodified) via CALL, not a tail-jump: on
; success switch_to_part never returns (resets SP, enters the new part
; fresh), so the pushed return address is simply abandoned with the
; rest of the old stack, same as every other switch_to_part caller. On
; a probe failure switch_to_part does a bare scf/ret with no MMU7
; remap - safe for h_xpart (same page, this file) but NOT safe here:
; that ret would land on OUR caller's return address while MMU7 is
; still mapped OVL0_PAGE, fetching this page's bytes at what is really
; an OVL1_PAGE address - wrong code executed. So the failure is caught
; here (CALL, not JP) and explicitly return-trampolined back to
; overlay1's xpart_load_fail, which remaps MMU7 to OVL1_PAGE before its
; own ret fires - landing correctly back on whichever of sav_read_v2/
; h_ramload called us, with CF set, exactly mirroring a same-part LOAD
; failure (brief's sanctioned "fail-silent abort of the whole LOAD -
; current part continues unchanged" choice).
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

ext_stub:
    jp h_unimpl

; EXTERN vector 6 (silicon keyboard-defect task): DEBUG-only route to
; KTEST, the keyboard matrix/decode diagnostic (tests/test.dsf's KTEST
; verb; body lives in overlay1.asm/OVL1_PAGE alongside kb_raw/kb_char).
; Reuses vector 6 - free since VIDBENCH's retirement (see that commit's
; own note); avoids 3/4/7 (live: XMESSAGE/XPART/XUNDONE) and 5 (suite
; check 44 depends on it staying ext_stub forever). extVec is DATA, not
; code - the IFDEF on the table row costs nothing in Release (byte-
; identical to before this task); the trampoline body is itself IFDEF
; DEBUG so no dead code reaches overlay0 in Release either.
 IFDEF DEBUG
ktest_trampoline:
    ld hl, ktest_poll             ; established push-target/ovl_map_page
    push hl                       ; trampoline idiom (font_load_switch,
    ld a, OVL1_PAGE               ; xpart_load_fail's own hop, the old
    jp ovl_map_page                ; vid_bench_trampoline, etc.)
 ENDIF

; EXTERN vector 8: NXBEN (the SP15 T2 decode-kernel bench) is RETIRED
; with the v2 format freeze (SP15 3a page-layout redesign): its job -
; the silicon coefficients behind the freeze - is done, its kernels
; graduated into the production decoder (video.asm hot page), and its
; ~2.4KB of VID_PAGE2 DEBUG space now funds the v2 open/load cluster
; plus the streaming cluster's move off the hot page. git holds the
; bench (commits 5cc2c70/a63ccfd lineage) and the DMAT/DMACC
; precedent before it. Vector 8 is reused below (Card #6 fixture
; wave); 5 must stay ext_stub forever (suite check 44), 6 is KTEST's.
;
; EXTERN vectors 8/9/10 (Card #6 SNAP=03/00 sitting follow-up,
; .superpowers/sdd/sp14a-task-4-report.md section 41): DEBUG-only
; routes for tests/test.dsf's L2MOD/LHIDE/LSHOW verbs, so the owner
; can drive the two snapshot branches the seven-leg sitting could not
; reach (the test template runs 320x256 mode-1 always, so
; vid_snap_geom's mode-0/hidden-L2 branches never ran on silicon).
; L2MOD (vector 8) drops the template into the mode-0 test-card state
; (l2_testcard, overlay2.asm) - a following VPLY1 should then read
; SNAP=03. LHIDE/LSHOW (vectors 9/10) trampoline straight to the
; resident l2_disable/l2_enable (overlay2.asm) - the same NR $69 bit
; vid_snap_geom reads - so a following VPLY1 after LHIDE should read
; SNAP=00. Same push-target/ovl_map_page idiom as ktest_trampoline.
; l2mod_run's overlay2.asm wrapper exists only because l2_testcard
; needs A = mode on entry, which this trampoline cannot set before
; the page switch (ovl_map_page's own A-clobber, loading OVL2_PAGE);
; LHIDE/LSHOW need no such wrapper since l2_disable/l2_enable take no
; argument, so they push the resident routines directly.
 IFDEF DEBUG
l2mod_trampoline:
    ld hl, l2mod_run
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
l2hide_trampoline:
    ld hl, l2_disable
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
l2show_trampoline:
    ld hl, l2_enable
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
 ENDIF

; EXTERN vector 11 (SP17 T5 Layer 2 scroll bring-up, run sheet
; .superpowers/sdd/sp14a-task-4-report.md section 41.4): DEBUG-only
; route for tests/test.dsf's ten LSxxx owner verbs, which prove the
; Layer 2 offset registers on silicon (the 9th X bit NR $71, X/Y wrap
; at both modes, clip-window interaction, mid-raster write tearing)
; before T5 designs a pan around them. ONE vector for all ten: the
; EXTERN's first parameter selects a config row in overlay2's l2sCfg,
; so a new probe costs a table row, not a vector (11-15 are the last
; free ones - 5 must stay ext_stub forever, suite check 44). Same
; push-target/ovl_map_page idiom as the trampolines above; the config
; index rides in B because ovl_map_page clobbers A (h_extern leaves
; the parameter in both).
 IFDEF DEBUG
l2scr_trampoline:
    ld hl, l2scr_run
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
 ENDIF

; EXTERN vector 12 (SP17 player bench - the NXBEN revival, card
; .superpowers/sdd/sp14a-task-4-report.md section 42): DEBUG-only
; route for tests/test.dsf's NXBO/NXBC/NXBK verbs. NXBEN's vector 8
; went to the Card #6 fixture wave while the bench was retired, so the
; revival takes 12 (12-15 are the last free ones; 5 must stay
; ext_stub forever, suite check 44). ONE vector for all three modes:
; the mode rides flags+250 (the stage-ladder convention the retired
; bench used), set by the verb's LET before the shared EXTERN, so a
; new mode costs a table row rather than a vector. The bench's fourth
; row group (direct-serve transport) needs a LIVE armed session and
; cannot come through here at all - it rides the player instead
; (flags+248 + a GFX n 13 verb; see video.asm's vid_run bench hook).
; Same push-target/ovl_map_page idiom as the trampolines above.
 IFDEF DEBUG
nxb_trampoline:
    ld hl, nxb_entry
    push hl
    ld a, VID_PAGE
    jp ovl_map_page
 ENDIF
extVec:
    dw ext_stub, ext_stub, ext_stub, ext_xmes
    dw h_xpart, ext_stub
 IFDEF DEBUG
    dw ktest_trampoline           ; vector 6, DEBUG only
 ELSE
    dw ext_stub                   ; vector 6, release: unimplemented stub
 ENDIF
    dw ext_undone
 IFDEF DEBUG
    dw l2mod_trampoline           ; vector 8, DEBUG only (Card #6)
    dw l2hide_trampoline          ; vector 9, DEBUG only (Card #6)
    dw l2show_trampoline          ; vector 10, DEBUG only (Card #6)
 ELSE
    dw ext_stub, ext_stub, ext_stub ; vectors 8-10, release: stubs
 ENDIF
 IFDEF DEBUG
    dw l2scr_trampoline           ; vector 11, DEBUG only (SP17 T5)
 ELSE
    dw ext_stub                   ; vector 11, release: stub
 ENDIF
 IFDEF DEBUG
    dw nxb_trampoline             ; vector 12, DEBUG only (SP17 bench)
 ELSE
    dw ext_stub                   ; vector 12, release: stub
 ENDIF
; EXTERN vectors 13/14 (SP18 item 7 Tasks 9/10 ring-2 placement probe,
; owner-ratified fallback 2026-08-09: the DeZog CALL-injection
; mechanism is unavailable in the owner's DeZog build). Route
; tests/sfxlong.dsf's R2FILL/R2CHK verbs straight to ring2_fill/
; ring2_chk (this page, below) - no trampoline needed: h_extern already
; dispatches with overlay0 mapped into slot 7, the same page these two
; routines live on. DEBUG-only, vector 15 stays spare.
 IFDEF DEBUG
    dw ring2_fill                 ; vector 13
    dw ring2_chk                  ; vector 14
 ELSE
    dw ext_stub, ext_stub         ; vectors 13-14, release: stubs
 ENDIF
    dw ext_stub                    ; vector 15: spare

savedCurX: db 0
savedCurY: db 0
moveVerb:  db 0

; --- SP10 Task 5: CALL closure + Kempston mouse ---

h_call:                         ; 101: CALL (invoke machine code at an
                                 ; address) has no meaning in a bytecode
                                 ; interpreter. jdaad.js's own _CALL() is
                                 ; the same shape - "// CALL not
                                 ; supported by jDAAD", then just marks
                                 ; done. Clean, documented no-op - no
                                 ; DEBUG marker: this is a documented-
                                 ; unsupported condact, not an
                                 ; unimplemented one.
    ret

; MOUSE (86): B = P1 (flag base, sub 3 only), C = sub. Sub map per
; jdaad's _MOUSE() (tools/DAAD-READY/ASSETS/HTML/jdaad.js ~3587-3615):
;   0 = reset (centre position, zero buttons)
;   1 = show the pointer (hardware sprite 0)
;   2 = hide it
;   3 = read into flags[P1..P1+3] = buttons, X/8, Y/8, X/6
; Position model: mouseX (word, 0-319) / mouseY (byte, 0-255, screen-
; downward) are accumulated resident positions, updated ONLY when sub 3
; polls - no ISR involvement. Each poll reads the Kempston counters
; (KMOUSE_X_PORT/KMOUSE_Y_PORT/KMOUSE_BTN_PORT, nextdaad.inc) and takes
; a SIGNED 8-bit delta against the last raw reading (new-old; correct
; under wraparound as long as true movement between two polls stays
; within +-127 counts - CSpect itself caps/scales its emulated deltas
; for exactly this kind of usability, per CSpectReadme.txt "Capped
; Mouse deltas to help slow mouse down"). Y's raw delta is negated
; (nextdaad.inc: the port counts UP on upward movement). The very
; first poll of a session has no valid "last" reading yet - rather
; than diff against a compile-time 0 (which would read as a large
; bogus jump against whatever the host mouse already reads at that
; point), mouseBaseSet gates a latch-only first call.
; jdaad's own X/8 clamp is 0-39 (its 320-wide/40-column screen); ours
; is widened to 0-79 for our 80-column tilemap grid - the mouseX
; domain itself is still the standard 0-319 sprite/mouse plane (per
; the sprites chapter, matching jdaad and the hardware sprite
; coordinate space), so in practice X/8 never exceeds 39 either; the
; wider ceiling is future-safe spec compliance, not a reachable case
; today. X/6 (0-53) is unchanged jdaad parity (319/6 floors to 53
; exactly, so it never clamps either).
; Pointer: hardware sprite 0, a 16x16 pattern - the built-in solid
; arrow (mouseArrow, below) until a POINTER.SPR/POINTERn.SPR replaces
; it in the live upload buffer (mousePattern, also below - a plain
; ds 256, blank at assembly time; see ptr_arrow_install/pointer_load
; for which of them writes it when). NR $15 bits 0-1 are read-modify-
; written UNCONDITIONALLY on every sub-1 call, preserving every other
; bit (layer priority etc):
; bit 0 is sprite visibility; bit 1 is "sprites over border" - per
; registers.txt (0x15) and the sprites chapter ("sprites can be made
; visible or invisible when over the border... specified by port 15"),
; a sprite positioned in the 32px border margin is invisible unless
; bit 1 is set, and mouse_sprite_pos's +32 offset legitimately parks
; the pointer there across its own range (mouseX/Y near their maxima
; put the sprite well past the classic 256x192 visible area). Bit 5
; ("enable sprite clipping in over border mode", also soft-reset 0,
; separate from bit 1) is left untouched, so port $19's clip window
; (default 0,255,0,191) never engages - the pointer is not further
; restricted to that sub-box. Sprites stay off (hw_init's cold
; default) for games that never touch MOUSE. Neither bit is latched
; behind mouseReady the way the (expensive, 256-byte OTIR) pattern
; upload is: a CSpect warm nextreg-2,1 re-entry re-runs hw_init's
; "nextreg NR_SPRITES,0" against otherwise-dirty overlay RAM (main.asm's
; boot_data_init header), and a latched mouseReady=1 surviving that
; would skip re-arming these bits while the register itself just got
; zeroed - stuck-invisible until the next cold boot. The RMW itself is
; one register read + write, cheap enough to just always do.
; mouseReady/mouseBaseSet/mouseX/mouseY are NOT
; reset at boot the way xmsBank is (no analogous mouse_boot_reset here)
; - overlay0's resident CALLER (main.asm) has zero spare bytes before
; engine.asm's own "ALIGN 256" for the flags array (confirmed by
; build: the pre-align resident code already lands exactly on that
; boundary, so any growth there - even a single 3-byte CALL, regardless
; of target - costs a full extra 256-byte alignment cycle and blows
; RESIDENT_LIMIT). The residual exposure is narrow and self-correcting:
; only mouseX/mouseY/mouseBaseSet can carry a stale value across such a
; warm re-entry, producing at most one over-large position jump on the
; first post-restart sub-3 poll (which then immediately re-latches a
; fresh baseline) - cosmetic, CSpect-dev-loop-only (real hardware's
; nextreg 2,1 hands off to NextZXOS instead of silently re-running
; dirty RAM), and no worse than the one-time jump every cold boot
; already accepts before mouseBaseSet's first latch.
; SP16 B23. The DRC symbol set defines EIGHT sub-commands (RESETMS 0,
; SHOWMS 1, HIDEMS 2, GETMS 3, GETFINEMS 4, POINTERMS 5, DELTAXMS 6,
; DELTAYMS 7 - doc_en.html, "Appendix D - Symbols"); only 0-3 existed
; here, and jDAAD implements only 0-3 too, so 4-7 had no reference to
; adjudicate against. Semantics below are taken from the DRC manual's
; own MOUSE table (doc_en.html, condact MOUSE) and mapped onto this
; interpreter's pointer model; each handler states its mapping and why.
; NOTE ON THE SYMBOL NAMES: DELTAXMS/DELTAYMS do NOT report mouse
; movement deltas. The manual defines them as "Changes hotspot coord X
; value" / "...Y value" - they MOVE THE POINTER'S HOTSPOT within the
; pointer bitmap ("originally the hotspot in the pointer is at x=0,
; y=0 ... if the pointer is a cross, you may want to put it at 5,5").
; That is what is implemented.
; Sub-command dispatch is a word table over the dense 0-7 set (doc 07
; section (a)) rather than a compare chain: the added handlers sit past
; jr range from the top of the routine, so a chain would have cost four
; 5-byte cp/jp pairs against the table's 2 bytes per entry.
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
    push bc                     ; second push keeps C (the sub) safe
    ld b, 28                    ; across dbg_puts (corrupts BC) for the
    ld c, 70                    ; dbg_hex8 below.
    call dbg_at
    ld hl, msgMouseUnk
    call dbg_puts
    pop bc
    ld a, c
    call dbg_hex8
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
    or %00000011                ; priority etc) - only touch bit 0
    nextreg NR_SPRITES, a       ; (sprites enable) and bit 1 (sprites
                                 ; over border - our pointer's range
                                 ; legitimately reaches into the border,
                                 ; see h_mouse's header comment)
    call mouse_sprite_pos       ; leaves sprite 0 selected (NR $34)
    ld a, %11000000              ; visible(7) + byte4-enable(6) + pattern 0
    nextreg NR_SPRITE_PAT, a
    ret
.hide:                          ; sub 2: invisible attribute only -
    xor a                       ; sprites master (NR $15) stays enabled
    nextreg NR_SPRITE_SEL, a
    ld a, %01000000              ; invisible + byte4-enable kept
    nextreg NR_SPRITE_PAT, a
    ret
.read:                          ; sub 3: poll, write flags[P1..P1+3],
    ld a, b                     ; reposition the sprite (harmless if
    ld (mouseP1), a             ; it's currently hidden)
    call mouse_poll
    ; col80 = mouseX/8, clamped 0-79 (word >> 3)
    ld hl, (mouseX)
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a, l
    cp 80
    jr c, .c80ok
    ld a, 79
.c80ok:
    ld (mouseCol80), a
    ; row32 = mouseY/8, clamped 0-31 (byte, zero-extended >> 3)
    ld a, (mouseY)
    ld l, a
    ld h, 0
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a, l
    cp 32
    jr c, .r32ok
    ld a, 31
.r32ok:
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

msgMouseUnk: db "MOUSE? ", 0

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
    xor a
    nextreg NR_SPRITE_SEL, a
    ld hl, (mouseX)
    ld de, SPRITE_BORDER
    add hl, de                  ; HL = mouseX+32 (9-bit, max 351)
    ld a, (mouseHotX)           ; SP16 B23 sub 6: shift the bitmap back
    call mouse_hotsub           ; so the hotspot pixel sits on mouseX
    ld a, l
    nextreg NR_SPRITE_X, a
    ld a, h
    ld b, a                     ; stash X's bit 8 (0 or 1 only)
    ld a, (mouseY)
    ld l, a
    ld h, 0
    add hl, de                  ; HL = mouseY+32 (9-bit, max 287)
    ld a, (mouseHotY)           ; SP16 B23 sub 7 (DE survives the call,
    call mouse_hotsub           ; and so does B)
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

; --- SP12 Task 3: custom mouse pointer load ---
; Three triggers, not two: boot, a part switch, and (SP18) MOUSE n 5 at
; any point during play.
;
; Step 1 ground truth: mouseArrow (above) is a plain `db` table
; assembled into overlay0's code page, read-only in practice - nothing
; ever writes it. mousePattern (also above) is the LIVE `ds 256`
; buffer mouse_pattern_load actually uploads (its fixed
; `ld hl, mousePattern` source address never changes); it has exactly
; two writers: ptr_arrow_install's ldir (mouseArrow -> mousePattern,
; the revert-to-built-in path, below) and this routine's own ldir
; further down (a successfully validated POINTER.SPR/POINTERn.SPR).
; mouseReady (above) is the "pattern already uploaded to hardware
; sprite slot 0" latch h_mouse's sub-1 checks (.show, above): 0 =
; mouse_pattern_load runs on the next MOUSE 1, then mouseReady is set
; to 1 so it does not run again until something clears it - exactly the
; hook both writers use: overwrite mousePattern, then clear mouseReady
; so the NEXT MOUSE 1 (existing lazy-upload code, unmodified) re-OTIRs
; the new bytes to hardware. Zero mouse-machinery changes needed.
;
; Restore the built-in arrow into the live buffer. Corrupts AF, BC, DE, HL.
ptr_arrow_install:
    ld hl, mouseArrow
    ld de, mousePattern
    ld bc, 256
    ldir
    xor a
    ld (mouseReady), a           ; force the next MOUSE 1 to re-OTIR
    ret

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
; 16x16 8-bit hardware sprite pattern (see mouseArrow's own header
; above for the format: $E3 transparent border/fill, hotspot at the
; (0,0) corner). Absent = silent (the previously-installed pattern
; stays); wrong size = silent + DEBUG marker. Never reads straight into
; the live mousePattern: MOUSE 1 can fire at any time and re-OTIR
; whatever is there the instant mouseReady reads 0, so a short/failed
; read must never leave the live buffer half-overwritten - the file
; lands in swapStage first (scratch-then-install) and is only ldir'd
; into mousePattern once the exact size is confirmed. Exact-size
; validation (BC checked, not CF alone - the F_READ/F_WRITE count
; lesson) plus a 1-byte-overshoot probe mirror font_load's own FONT.CHR
; check byte for byte (overlay2.asm, SP12 T1). THIS ROUTINE only ever
; writes ptrCur after that final ldir, so a failed load (absent file,
; wrong size, no drive) leaves it exactly as this routine found it.
; Note that its CALLER h_mouse.pointer does write it beforehand, for
; the n=0 path, and unlike the font mirror it legitimately writes 0
; rather than $FF: shape 0 means "the built-in arrow, then POINTER.SPR
; over it if one exists", and ptr_arrow_install has already put the
; arrow in the live buffer by then, so every way THIS routine can then
; fail still leaves shape 0 genuinely installed and ptrCur=0 honest.
; That asymmetry with font_load is real and not an oversight: the font
; path has a fourth failure mode (no free bank) that this one does not,
; because it stages 2048 bytes through a bank_alloc'd scratch bank that
; a warm picture cache can starve, whereas this routine stages through
; the static swapStage below and cannot fail that way at all.
; So the invariant holds on both sides: Cur NAMES A NUMBER only when
; that number's data is genuinely live, and MOUSE sub 5's already-
; installed check can never short-circuit a retry of a shape that
; failed to install.
;
; Scratch buffer: swapStage (512 bytes, above) reused rather than a new
; static buffer or a bank_alloc dance - it is directly addressable from
; this page with no DATA_WINDOW mapping needed (unlike font_load's
; 2048-byte FONT.CHR, which does not fit this page's margin as a static
; buffer - see that routine's header), and 257 bytes fits its capacity
; trivially. Safety of the reuse: swapStage only ever holds a LIVE,
; not-yet-consumed payload strictly within a single h_xpart/
; xpart_load_entry -> switch_to_part call chain (both producers hand
; off to switch_to_part immediately, with no intervening ret to the
; condact dispatcher), so it is idle at every OTHER entry to this
; routine - including MOUSE n 5 (h_mouse.pointer, above), reachable at
; any point during normal play with no part switch anywhere on the call
; stack; the Z80 has one call stack and no condact pre-emption (im2_isr/
; ctc_isr, interrupts.asm, only ever drive music/sample timing), so
; that window and this one can never overlap. Within the part-switch
; chain, this routine's own call site (switch_to_part's .noobjs, above)
; runs AFTER swapStage's flags/object-location payload has already been
; fully installed into flags/objTable - the install loop immediately
; above .noobjs is the LAST reader of that payload, so by the time
; control reaches here swapStage is free scratch, exactly the ordering
; the original task brief required (verified directly against
; switch_to_part's own instruction order, not assumed).
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
    xor a
    ld (mouseReady), a               ; force the next MOUSE 1 to re-OTIR
                                     ; the new pattern to hardware
    ld a, (ptrNum)                   ; installed: remember which
    ld (ptrCur), a
    jr .close
.bad:
 IFDEF DEBUG                        ; wrong size: no-op with a marker,
    ld b, 29                        ; same idiom as h_sfx/h_mouse/
    ld c, 70                        ; font_load's own markers
    call dbg_at
    ld hl, msgPtrBad
    call dbg_puts
 ENDIF
.close:
    ld a, (ptrHandle)
    call esx_fclose
    ret

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
ptrHandle:    db $FF              ; esxDOS handle, $FF = none open
ptrNum:       db 0                ; number being built/loaded
ptrNameLen:   db 12               ; bytes in ptrNameBuf including the NUL
ptrCur:       db $FF              ; installed shape, $FF = unknown
ptrNameBuf:   ds 13               ; "POINTERn.SPR",0 worst case
; "PARTm\" (6) + the longest built name (13)
ptrNamePart:  ds 19
ptrNameStem:  db "POINTER"
ptrNameExt:   db ".SPR", 0
msgPtrBad:    db "PTR BAD", 0

; Relocated from errors.asm (post-flags resident there had no room to
; grow - see fatal_puts's MMU7 map, errors.asm). fatal_puts is the only
; reader: it maps this page at MMU7 before dereferencing either string,
; reached via err_raise directly or ddbtext.asm's rd_stack_fatal -> fatal.
; Fixed prefix; err_raise appends the single decimal digit itself.
msgRuntimeErr: db "NextDAAD: RUNTIME ERROR - E", 0
; Reader stack depth overflow (ddbtext.asm's rd_push/rd_pop).
msgRdStack:    db "NextDAAD: RD STACK - E9", 0

; --- Ring-2 placement probe (SP18 item 7 Task 9, spec OP1; relocated
; from src/debug.asm by Task 10 - resident's DEBUG tail had only 3
; bytes free after Task 9 landed these here, and Task 10's ctc2_isr +
; cursors need ~40-45 more, so these two verbs (~56 bytes) moved to
; make room). ------------------------------------------------------
; V1 silicon instruments for the AUD_STAGE2 candidate: $4400-$47FF (1K)
; inside the classic ULA pixel screen ($4000-$57FF), believed dead once
; the tilemap/Layer 2 are up. RING2FILL primes the candidate with a
; $A5 sentinel; RING2CHK scans it back and reports the first mismatch
; (address + byte, via dbg_hex16/dbg_hex8) or "OK". Owner-invoked only,
; via a debugger CALL to the symbol - no automatic call site exists
; anywhere in the boot or engine flow, so Release carries none of this
; (both routines are IFDEF DEBUG).
;
; RELOCATION IS SAFE: the routines' documented invocation precondition
; (below) is "CALL only once the interpreter is idle at the parser
; prompt", and the parser prompt is reached only with overlay0 mapped
; into slot 7 - it is the dispatcher's own condact-handler page, and
; nothing else can be mapped there while mainline waits on input. So
; moving these verbs onto overlay0 adds no new constraint beyond the
; one they already had: a debugger CALL to their address at the idle
; prompt lands on the correct bytes either way. They still call
; resident dbg_* helpers (fine to reach from an overlay page - the
; call itself does not depend on which page is mapped) and touch only
; $4400-$47FF, which is always mapped regardless of slot 7's content.
;
; TIMING PRECONDITION: only call these once dbgTilemap=1 (i.e. after
; dbg_engage_tilemap has run - boot has reached the parser). Before
; that point dbg_puts/dbg_putc route through debug.asm's ULA-pixel
; fallback, which plots at H = $40 + (y AND $18) .. +7 - rows 0-7 land
; on H=$40-$47, overlapping this exact candidate ($44-$47). An early
; call would have its OWN status print corrupt the region under test.
; Neither routine calls dbg_cls for the same reason: it unconditionally
; clears the WHOLE ULA screen via ula_cls (hardware.asm).
 IFDEF DEBUG
RING2_BASE equ $4400
RING2_LEN  equ $0400              ; 1K
RING2_ROW  equ 20                 ; fixed row: repeat calls overwrite,
                                  ; not scroll

; Fill RING2_BASE..+RING2_LEN-1 with $A5. No screen output (RING2CHK,
; called right after, both confirms the fill and reports it). Corrupts
; AF, BC, DE, HL.
ring2_fill:
    ld hl, RING2_BASE
    ld de, RING2_BASE+1
    ld bc, RING2_LEN-1
    ld (hl), $A5
    ldir
    ret

; Scan RING2_BASE..+RING2_LEN-1 for the first byte != $A5. Prints "OK"
; on row RING2_ROW if the whole range is intact, else the mismatching
; address (4 hex digits) then a space then its byte (2 hex digits) on
; that same row. Corrupts everything (dbg_* helpers' own contract).
ring2_chk:
    ld b, RING2_ROW
    call dbg_at0
    ld hl, RING2_BASE
    ld bc, RING2_LEN
.loop:
    ld a, (hl)
    cp $A5
    jr nz, .bad
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .loop
    ld hl, .msgok
    jp dbg_puts
.bad:
    push af                     ; mismatching byte value (dbg_hex16
                                 ; below would corrupt it otherwise)
    call dbg_hex16              ; HL is still the mismatch address
    call dbg_space
    pop af
    jp dbg_hex8
.msgok: db "OK", 0
 ENDIF

    DISPLAY "overlay0 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
