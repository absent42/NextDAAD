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

h_isdone:                       ; 114: lastDone != 0
    ld a, (lastDone)
    or a
    jp nz, c_true
    jp c_false
h_isndone:                      ; 115: lastDone == 0
    ld a, (lastDone)
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
; B = param -> HL = flags + (59 - B/8), A = 1 << (B mod 8).
; DAAD numbers attributes DOWN from flag 59: attr 0-7 -> flag 59,
; 8-15 -> flag 58, WEARABLE 23 -> flag 57 bit 7, MOUSE 240 -> flag 29
; bit 0 (manual 1062-1069). Corrupts AF, E.
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
    sub b
    ld b, a                     ; B = 59 - B/8
    call fptr
    ld a, 1
.shift:
    dec e
    ret m
    add a, a
    jr .shift
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
rng_next:
    push bc
    push hl
    ld hl, (rngState)
    ld a, h
    rrca
    xor l
    ld l, a
    ld a, h
    rlca
    rlca
    xor l
    ld h, a
    ld a, l
    rrca
    xor h
    ld l, a
    ld (rngState), hl
    ld a, h
    xor l
.reduce:
    cp 200
    jr c, .half
    sub 200
    jr .reduce
.half:
    cp 100
    jr c, .fin
    sub 100
.fin:
    inc a
    pop hl
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
    ld a, (hl)
    ld (flags+FLAG_COATT), a
    inc hl
    ld a, (hl)
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
h_swap:                         ; 45: exchange locations, flag-1 safe
    ld a, b
    call obj_ptr
    ld a, (hl)                  ; A = loc(B)
    push af                     ; obj_ptr corrupts AF/DE; stash across
    ld a, c                     ; the second call rather than trust D
    call obj_ptr
    ld e, (hl)                  ; E = loc(C)
    pop af
    ld d, a                     ; D = loc(B)
    push bc
    push de
    ld a, b
    ld c, e
    call obj_move               ; B -> old loc(C)
    pop de
    pop bc
    ld a, c
    ld c, d
    jp obj_move                 ; C -> old loc(B)
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
    ld a, c
    ld c, d
    jp obj_move
h_copyfo:                       ; 123: loc(obj C) = flags[B]
    call fptr
    ld d, (hl)
    ld a, c
    ld c, d
    jp obj_move
h_whato:                        ; 100: find by Noun1/Adj1
    call obj_find_n1
    jr c, .none
    jp obj_set_refs
.none:
    ld a, $FF
    ld (flags+FLAG_CUROBJ), a
    ret

; D = location to scan ($FE = anywhere). Matcher on Noun1/Adj1.
; Out: A = object CF clear, else CF set. Preserves D.
obj_find_pass:
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
    cp $FE
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
    jr z, .hit
    ld a, (iy+5)
    cp 255
    jr nz, .next
.hit:
    ld a, b
    or a
    ret
.next:
    inc b
    jr .scan
.miss:
    scf
    ret

; Standard ordering: carried, worn, here, anywhere.
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
    ld d, $FE
    jp obj_find_pass

; E = system message: print + newline, exit the table as DONE.
refuse:
    ld a, 0
    call print_msg
    call prn_newline
    ld a, 1
    jp eng_exit_table

; Cancel any active DOALL loop (GET/TAKEOUT SM27 capacity refusal,
; manual 1137-1140, 1270-1273). Mirrors the DOALL-completion clear in
; eng_doall_next. Corrupts AF.
doall_cancel:
    xor a
    ld (doallLevel), a
    dec a                       ; $FF
    ld (doallObj), a
    ret

h_ok:                           ; 23: SM15 then DONE - refuse IS that
    ld e, 15
    jp refuse

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
    ld a, (flags+FLAG_MAXCARR)
    ld e, a
    ld a, (flags+FLAG_CARRIED_CT)
    cp e
    jr c, .cap
    call doall_cancel           ; SM27 refusal cancels any DOALL
    ld e, 27
    jp refuse
.cap:
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
    ld a, 255                   ; carried+object > 255: saturate so an
.noovf:                         ; overloaded total cannot pass the check
    ld e, a
    ld a, (flags+FLAG_STRENGTH)
    cp e
    jr nc, .take
    ld e, 43
    jp refuse
.take:
    ld a, b
    ld c, OBJ_CARRIED
    jp obj_move
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
    ld a, (hl)
    cp OBJ_WORN
    jr z, .worn
    cp OBJ_CARRIED
    jr nz, .nothave
    ld a, (flags+FLAG_PLAYER)
    ld c, a
    ld a, b
    jp obj_move
.worn:
    ld e, 24
    jp refuse
.nothave:
    ld e, 28
    jp refuse

h_wear:                         ; 42
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
    ld d, (hl)
    inc hl
    bit 7, (hl)
    jr z, .cant
    ld a, d
    cp OBJ_WORN
    jr z, .already
    cp OBJ_CARRIED
    jr nz, .nothave
    ld a, b
    ld c, OBJ_WORN
    jp obj_move
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
    ld d, (hl)
    inc hl
    bit 7, (hl)
    jr z, .cant
    ld a, d
    cp OBJ_WORN
    jr nz, .notworn
    ld a, (flags+FLAG_MAXCARR)
    ld e, a
    ld a, (flags+FLAG_CARRIED_CT)
    cp e
    jr c, .rem
    ld e, 42
    jp refuse
.rem:
    ld a, b
    ld c, OBJ_CARRIED
    jp obj_move
.cant:
    ld e, 41
    jp refuse
.notworn:
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
    jp refuse
.go:
    ld b, a
    jp h_get
h_autod:                        ; 32: carried, worn, here
    call auto_cwh
    jr nc, .go
    ld e, 28
    jp refuse
.go:
    ld b, a
    jp h_drop
h_autow:                        ; 33: carried, worn, here
    call auto_cwh
    jr nc, .go
    ld e, 28
    jp refuse
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
    jp refuse
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
    ld a, (hl)
    cp OBJ_CARRIED
    jr nz, .nothave
    ld a, b
    jp obj_move
.nothave:
    ld e, 28
    jp refuse
h_takeout:                      ; 91: obj B out of container loc C
    ld a, b
    call obj_set_refs
    ld a, b
    call obj_ptr
    ld a, (hl)
    cp c
    jr nz, .notin
    ld a, (flags+FLAG_MAXCARR)
    ld e, a
    ld a, (flags+FLAG_CARRIED_CT)
    cp e
    jr nc, .full
    ld a, b
    ld c, OBJ_CARRIED
    jp obj_move
.full:
    call doall_cancel           ; SM27 refusal cancels any DOALL
    ld e, 27
    jp refuse
.notin:
    ld e, 52
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
    jp refuse
h_autot:                        ; 105: container first, then usual
    push bc
    ld d, b
    call obj_find_pass          ; preserves D, clobbers B
    pop de                      ; D = container location
    jr nc, .found
    push de
    call obj_find_n1            ; loads D per pass - bracket it
    pop de
    jr c, .none
.found:
    ld c, d
    ld b, a
    jp h_takeout
.none:
    ld e, 52
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
    ld b, a                     ; B = running total
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
    ld a, 7
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
    ld a, b
    and 7
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
h_paper:                        ; 65: DAAD paper maps to a hardware
    ld a, b                     ; palette index; 16+ FOLDS mod 16 (the
    and 15                      ; and 15, = jdaad's param%16). win_attr
    ld b, a                     ; masks paper to the 8 tilemap paper
                                ; slots at render time.
    ld a, WIN_PAPER
    call win_field
    ld (hl), b
    ret
h_ink:                          ; 66: DAAD ink maps to a palette index,
    ld a, b                     ; 16+ folding mod 16 like h_paper (the
    and 15                      ; tilemap carries the full 16 ink
    ld b, a                     ; colours)
    ld a, WIN_INK
    call win_field
    ld (hl), b
    ret
; 67 BORDER: B AND 7 selects the classic colour. txt_init disables the
; ULA layer at text-mode takeover (NR $68 bit 7), so the classic
; border register is invisible; what actually shows around the screen
; is the global fallback colour NR $4A - output wherever tilemap and
; Layer 2 are both transparent, i.e. the whole true border region plus
; any gaps a 256-wide-art layout leaves uncovered. So BORDER programs
; NR $4A with the DAAD colour's RRRGGGBB (dadPalette first byte,
; resident, tilemap.asm; hw_init boots the register black, this
; overrides at runtime). The out ($FE) write is kept - one
; instruction, and BORDER keeps its classic meaning if the ULA layer
; is ever re-enabled. Corrupts AF, HL.
h_border:                       ; 67
    ld a, b
    and 7
    out ($FE), a
    add a, a                    ; dadPalette entries are 2 bytes
    ld hl, dadPalette
    add hl, a
    ld a, (hl)                  ; byte 0 of the pair = RRRGGGBB
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
    ld (flags+FLAG_KEY1), a
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

; Shared confirmation: prints SM E, waits, folds case, compares to the
; first char of SM C. In: E = prompt SM, C = compare SM. Out: ZF set =
; reply starts with SM C's first char. Corrupts all.
confirm:
    push bc                     ; C = compare SM survives print/key/reset
    ld a, 0
    call print_msg
    call prn_newline
    call key_wait_char
    push af                     ; save key
    call prn_reset_lines
    pop af                      ; A = key
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
h_end:                          ; 21: reply N (SM31) = exit to OS, any
    ld e, 13                    ; other key = restart (manual 2004-2010)
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
h_exit:                         ; 110: 0 = reset, else XPART stub
    ld a, b
    or a
    jp nz, h_unimpl
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
    call eng_set_done
    jp c_true
.nomatch:
    call data_restore
    pop hl
    jp c_false
h_synonym:                      ; 36
    ld a, b
    cp 255
    jr z, .noun
    ld (flags+FLAG_VERB), a
.noun:
    ld a, c
    cp 255
    ret z
    ld (flags+FLAG_NOUN1), a
    ret
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
    call eng_top_ix             ; stamp the engine wrote before
    xor a                       ; dispatching this action - the entry
    ld (ix+5), a                ; continues, the level reads notdone
    ret

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
 IFDEF DEBUG
    ; XMB rider (xmb-corruption-report.md, "prescribed next instrument"
    ; #1): print xmsOff and the first DECODED byte (DATA_WINDOW, post-
    ; cpl - message bytes are 255-complemented, see this routine's own
    ; header) immediately after this esx_fread, before the Sentinel
    ; write or any print work touches the buffer. Row 31 (TM_ROWS-1),
    ; col 68+: right of h_unimpl's own row-31/col-0 STUB marker, outside
    ; every window the suite fixtures use (test.dsf's window is rows
    ; 0-24) - same idiom already used for msgXmesFail below. Two XMES
    ; runs on hardware in one session convict/clear the offset-18 seek
    ; hypothesis: xmsOff=0 both times but the byte differs -> the seek
    ; is landing wrong; both consistent -> the bug is not here. Only BC
    ; (the byte count the Sentinel logic below needs) is live past this
    ; point - bracketed; A/HL are already about to be freshly reloaded.
    push bc
    ld b, 31
    ld c, 68
    call dbg_at
    ld a, 'O'
    call dbg_putc
    ld hl, (xmsOff)
    call dbg_hex16
    ld a, ' '
    call dbg_putc
    ld a, 'B'
    call dbg_putc
    ld a, (DATA_WINDOW)
    cpl
    call dbg_hex8
    pop bc
 ENDIF
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

extVec:
    dw ext_stub, ext_stub, ext_stub, ext_xmes
    dw h_xpart, ext_stub
 IFDEF DEBUG
    dw ktest_trampoline           ; vector 6, DEBUG only
 ELSE
    dw ext_stub                   ; vector 6, release: unimplemented stub
 ENDIF
    dw ext_undone
    dw ext_stub, ext_stub, ext_stub, ext_stub
    dw ext_stub, ext_stub, ext_stub, ext_stub

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
; Pointer: hardware sprite 0, a 16x16 solid arrow (mousePattern,
; below). NR $15 bits 0-1 are read-modify-written UNCONDITIONALLY on
; every sub-1 call, preserving every other bit (layer priority etc):
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
h_mouse:
    ld a, c
    cp 0
    jr z, .reset
    cp 1
    jr z, .show
    cp 2
    jr z, .hide
    cp 3
    jr z, .read
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
                                 ; 0-3 (ours 4-7 no-ops are exact parity)
                                 ; and has no wheel surface at all.
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

msgMouseUnk: db "MOUSE? ", 0

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

; One-time upload of the 16x16 arrow pattern to hardware sprite pattern
; slot 0. Port $303B selects the slot (chapter-next-sprites, "Loading
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
    ld a, l
    nextreg NR_SPRITE_X, a
    ld a, h
    ld b, a                     ; stash X's bit 8 (0 or 1 only)
    ld a, (mouseY)
    ld l, a
    ld h, 0
    add hl, de                  ; HL = mouseY+32 (9-bit, max 287)
    ld a, l
    nextreg NR_SPRITE_Y, a
    ld a, b
    and 1
    nextreg NR_SPRITE_ATTR, a   ; bit 0 = X's 9th bit; no mirror/rotate
    ld a, h
    and 1
    nextreg NR_SPRITE_ATTR2, a  ; bit 0 = Y's 9th bit; 8-bit anchor, 1x
    ret

mouseX:       dw 160
mouseY:       db 128
mouseBtn:     db 0
mouseXraw:    db 0
mouseYraw:    db 0
mouseBaseSet: db 0
mouseReady:   db 0
mouseP1:      db 0
mouseCol80:   db 0
mouseRow32:   db 0
mouseCol53:   db 0

; 16x16 solid-arrow hardware sprite pattern, 8-bit colour index per
; pixel (chapter-next-sprites: 256 bytes/pattern slot for 8-bit
; sprites). Hotspot (registration point) is the tip at (0,0), matching
; mouse_sprite_pos's use of mouseX/mouseY as the sprite's own (0,0)
; corner - left edge and diagonal hypotenuse outlined in $00 (RGB332
; black), $FF fill (RGB332 white), $E3 transparent (NR $4B's hardware
; soft-reset default, registers.txt: "soft reset = 0xe3" - nothing in
; this codebase reprograms it, so relying on it needs no extra write).
; Row 0  B...............      Row 8  BWWWWWWWB.......
; Row 1  BB..............      Row 9  BWWWWWWWWB......
; Row 2  BWB.............      Row 10 BWWWWWWWWWB.....
; Row 3  BWWB............      Row 11 BWWWWWWWWWWB....
; Row 4  BWWWB...........      Row 12 BWWWWWWWWWWWB...
; Row 5  BWWWWB..........      Row 13 BWWWWWWWWWWWWB..
; Row 6  BWWWWWB.........      Row 14 BWWWWWWWWWWWWWB.
; Row 7  BWWWWWWB........      Row 15 BWWWWWWWWWWWWWWB
mousePattern:
    db $00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00,$E3
    db $00,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$00

; --- SP12 Task 3: custom mouse pointer load (boot + part switch) ---
;
; Step 1 ground truth: mousePattern (above) is a plain `db` table
; assembled into overlay0's code page - overlay pages are ordinary RAM
; at runtime (not ROM), so it is writable, and nothing else in this
; codebase writes it (grepped: mouse_pattern_load only ever READS it,
; via its fixed `ld hl, mousePattern` source address - the only write
; site is this routine's own ldir below). mouseReady (above) is the
; "pattern already uploaded to hardware sprite slot 0" latch h_mouse's
; sub-1 checks (.show, above): 0 = mouse_pattern_load runs on the next
; MOUSE 1, then mouseReady is set to 1 so it does not run again until
; something clears it - exactly the hook this routine uses: overwrite
; mousePattern, then clear mouseReady so the NEXT MOUSE 1 (existing
; lazy-upload code, unmodified) re-OTIRs the new bytes to hardware.
; Zero mouse-machinery changes needed.
;
; Load a custom pointer: PARTn\POINTER.SPR (curPart >= 2) then
; POINTER.SPR, a raw 256-byte 16x16 8-bit hardware sprite pattern (see
; mousePattern's own header above for the format: $E3 transparent
; border/fill, hotspot at the (0,0) corner). Absent = silent
; (mousePattern keeps its compiled-in arrow); wrong size = silent +
; DEBUG marker. Never reads straight into the live mousePattern: MOUSE 1
; can fire at any time and re-OTIR whatever is there the instant
; mouseReady reads 0, so a short/failed read must never leave the live
; buffer half-overwritten - the file lands in swapStage first (scratch-
; then-install) and is only ldir'd into mousePattern once the exact size
; is confirmed. Exact-size validation (BC checked, not CF alone - the
; F_READ/F_WRITE count lesson) plus a 1-byte-overshoot probe mirror
; font_load's own FONT.CHR check byte for byte (overlay2.asm, SP12 T1).
;
; Scratch buffer: swapStage (512 bytes, above) reused rather than a new
; static buffer or a bank_alloc dance - it is directly addressable from
; this page with no DATA_WINDOW mapping needed (unlike font_load's
; 2048-byte FONT.CHR, which does not fit this page's margin as a static
; buffer - see that routine's header), and 257 bytes fits its capacity
; trivially. Safety of the reuse: swapStage is idle outside a live part
; switch (nothing touches it at boot before the first switch), and at
; switch time this routine's own call site (switch_to_part's .noobjs,
; above) runs AFTER swapStage's flags/object-location payload has
; already been fully installed into flags/objTable - the install loop
; immediately above .noobjs is the LAST reader of that payload, so by
; the time control reaches here swapStage is free scratch, exactly the
; ordering the task brief requires (verified directly against
; switch_to_part's own instruction order, not assumed).
;
; Corrupts AF, BC, DE, HL, IX.
pointer_load:
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
    ld hl, ptrName                ; copy "POINTER.SPR",0 verbatim (12 bytes)
    ld bc, 12
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
    ld ix, ptrName
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
    ld de, mousePattern               ; live buffer (the only write to
    ld bc, 256                        ; mousePattern anywhere but its own
    ldir                               ; compiled-in initialiser above)
    xor a
    ld (mouseReady), a               ; force the next MOUSE 1 to re-OTIR
    jr .close                        ; the new pattern to hardware
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

; SP12 T3 pointer-load state, overlay0-local - parallel to fontHandle/
; fontNamePart's own PARTn machinery (overlay2.asm), but no scratch bank
; is needed here (see pointer_load's header: swapStage is directly
; addressable from this page already).
ptrHandle:    db $FF              ; esxDOS handle, $FF = none open
; "PARTn\POINTER.SPR",0 = 6 ("PARTn\") + 12 ("POINTER.SPR",0) = 18 bytes.
; The task brief's plan said `ds 17` - that arithmetic undercounted:
; "POINTER.SPR" is 11 characters, +1 for the NUL terminator = 12 (not
; 11), so 6+12 = 18 is the correct total, used here instead.
ptrNamePart:  ds 18
ptrName:      db "POINTER.SPR", 0  ; root fallback name AND the PARTn\
                                   ; suffix (copied into ptrNamePart+6,
                                   ; 12 bytes - the fontNamePart/fontName
                                   ; reuse idiom, overlay2.asm SP12 T1)
msgPtrBad:    db "PTR BAD", 0

; Relocated from errors.asm (post-flags resident there had no room to
; grow - see fatal_puts's MMU7 map, errors.asm). fatal_puts is the only
; reader: it maps this page at MMU7 before dereferencing either string,
; reached via err_raise directly or ddbtext.asm's rd_stack_fatal -> fatal.
; Fixed prefix; err_raise appends the single decimal digit itself.
msgRuntimeErr: db "NextDAAD: RUNTIME ERROR - E", 0
; Reader stack depth overflow (ddbtext.asm's rd_push/rd_pop).
msgRdStack:    db "NextDAAD: RD STACK - E9", 0

    DISPLAY "overlay0 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
