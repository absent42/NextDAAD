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

    ASSERT $ <= OVL_LIMIT
