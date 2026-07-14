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
; Returns CF SET so stub conditions (INKEY until Task 8, PICTURE
; forever this SP) fail safely; harmless for actions (the engine
; ignores CF on actions).
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
    call win_cls                ; boot diagnostics before the suite)
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

h_parse:                        ; 73: SP3 halt latch
    ld a, 1
    ld (parseHalt), a
 IFDEF DEBUG
    ld b, 31
    ld c, 20
    call dbg_at
    ld hl, msgParse
    call dbg_puts
 ENDIF
    ld a, 1                     ; exit as done; eng_run stops on the
    jp eng_exit_table           ; latch before any further step
msgParse: db "PARSE", 0

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
    jp prn_dec8
h_dprint:                       ; 27: 16-bit from flags[B], flags[B+1]
    call fptr
    ld a, (hl)
    inc l                       ; flags is 256-aligned: L wrap-safe
    ld h, (hl)
    ld l, a
    jp prn_dec16
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
; B = param -> HL = flags + B/8, A = 1 << (B mod 8). Corrupts AF, E.
hasat_ptr:
    ld a, b
    and 7
    ld e, a
    ld a, b
    rrca
    rrca
    rrca
    and $1F
    ld b, a
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
rngState: dw $A5C3

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
h_place:                        ; 46: obj B to loc C
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
h_puto:                         ; 102: current object -> loc B
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
    ld e, 27
    jp refuse
.notin:
    ld e, 52
    jp refuse
h_autop:                        ; 104: B = container loc; find Noun1
    call auto_cwh
    jr c, .none
    ld c, b                     ; C = container loc, B = object
    ld b, a
    jp h_putin
.none:
    ld e, 28
    jp refuse
h_autot:                        ; 105: container first, then usual
    ld d, b
    call obj_find_pass
    jr nc, .found
    call obj_find_n1
    jr c, .none
.found:
    ld c, b
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
    ld b, 0
    ld c, 0
.scan:
    ld a, (numObj)
    cp b
    jr z, .done
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

    ASSERT $ <= OVL_LIMIT
