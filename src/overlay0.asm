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

    ASSERT $ <= OVL_LIMIT
