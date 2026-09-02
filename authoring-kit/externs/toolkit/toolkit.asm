; toolkit.asm - NextDAAD XBN worked example.
;
; The pure-logic shape: no #int hook. Fns 70-75, 82 and 83 take a FLAG
; NUMBER as the EXTERN parameter rather than a value, so the module costs
; four flags however many values a game manipulates; 78-81 take a location,
; noun or bit. Fns 76 and 84 arm module state that LOAD and RESTART do not
; reset - re-arm both wherever your game re-establishes state.
;
; Printing goes through SVC_PUTCHAR into whatever DAAD window the author
; has selected. The author brackets the call with WINDOW, or sets fn 84's
; print target once and lets the module bracket itself via SVC_WINDOW -
; either way the module needs no tilemap geometry and no width probe.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    DEFINE XBN_HAS_TOOLKIT       ; fills the pinned CALL slots in the
                                 ; standalone binary too; a combined or
                                 ; subset build defines it for itself
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN toolkit.ext, toolkit.int
    ENDIF

    MODULE toolkit

FLAG_WIDTH      equ 248          ; 0 = no padding; bit 7 = zero-pad
FLAG_OP2        equ 249          ; immediate or flag number, per fn
FLAG_HIGH       equ 250          ; high byte of fn 79's 16-bit result
FLAG_RESULT     equ 251          ; result and status

OBJ_WORN        equ 253          ; location pseudo-values (nextdaad.inc)
OBJ_CARRIED     equ 254

ext:
    ld a, b
    ld (param), a                ; park param1 before any call clobbers B
    ld a, c
    cp 70
    jp z, p8
    cp 71
    jp z, p16
    cp 72
    jp z, add8
    cp 73
    jp z, sub8
    cp 74
    jp z, cmpp
    cp 75
    jp z, addp
    cp 76
    jp z, pckarm
    cp 77
    jp z, pckget
    cp 78
    jp z, atloc
    cp 79
    jp z, wtot
    cp 80
    jp z, bynoun
    cp 81
    jp z, attrcnt
    cp 82
    jp z, hhmm
    cp 83
    jp z, mmss
    cp 84
    jp z, settgt
.notmine:
    or a                          ; CF clear: unrecognised fn, no failure
    ret

; Pinned CALL slots 0-3, at $C00E + 3n. xbnmod.inc jumps here by name, so
; these labels are part of the module's contract with the kit.
; CALL carries no parameter: the flag number comes from flag 249.
tk_call0:
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld (param), a
    jp p8
tk_call1:
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld (param), a
    jp p16
tk_call2:
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld (param), a
    jp hhmm
tk_call3:
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld (param), a
    jp mmss

pow10:   dw 10000, 1000, 100, 10, 1
digbuf:  ds 5
digix:   db 0                    ; index of the first digit to print
padn:    db 0                    ; pad characters still to emit
padc:    db 0                    ; the pad character itself

; HL = value -> digbuf holds five ASCII digits, no zero suppression.
; Corrupts AF, BC, DE, HL, IX.
u16_digits:
    ld (tmpval), hl
    ld ix, digbuf
    ld hl, pow10
    ld b, 5
.each:
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    push hl                      ; the pow10 cursor, restored below
    ld hl, (tmpval)
    ld c, '0'-1
.sub:
    inc c
    or a                         ; clear CF for the sbc below
    sbc hl, de
    jr nc, .sub
    add hl, de                   ; undo the overshoot
    ld (tmpval), hl
    ld (ix+0), c
    inc ix
    pop hl
    djnz .each
    ret

tmpval:  dw 0

; HL = value. Prints it as decimal 0-65535, zero-suppressed, padded to
; flag 248's width. Corrupts everything.
emit_u16:
    call u16_digits
    ld hl, digbuf
    ld b, 4                      ; the last digit always prints
    ld c, 0
.sig:
    ld a, (hl)
    cp '0'
    jr nz, .found
    inc hl
    inc c
    djnz .sig
.found:
    ld a, c
    ld (digix), a
    ld a, 5
    sub c
    ld c, a                      ; C = digits that will print
    ld a, (XBN_FLAGS + FLAG_WIDTH)
    ld b, a                      ; B keeps bit 7, the pad-style select
    and $7F
    sub c
    jr c, .nopad                 ; width narrower than the number: print
    jr z, .nopad                 ; it in full rather than truncating
    ld (padn), a
    ld a, ' '
    bit 7, b
    jr z, .setpad
    ld a, '0'
.setpad:
    ld (padc), a
    jr emit_pad
.nopad:
    xor a
    ld (padn), a

; Emits (padn) pad characters then digbuf from (digix) to the end.
; Entered directly by the time formats with padn already zeroed.
emit_pad:
    ld a, (padn)
    or a
    jr z, .digits
    dec a
    ld (padn), a
    ld a, (padc)
    call SVC_PUTCHAR
    jr emit_pad
.digits:
    ld a, (digix)
    cp 5
    ret nc
    inc a
    ld (digix), a
    dec a
    ld l, a
    ld h, 0
    ld de, digbuf
    add hl, de
    ld a, (hl)
    call SVC_PUTCHAR
    jr .digits

; HL = value. Prints it with AT LEAST two digits, zero-padded, ignoring
; flag 248 - the time formats need a fixed two-digit field.
emit_min2:
    call u16_digits
    ld hl, digbuf
    ld b, 3                      ; stop at index 3 so two digits survive
    ld c, 0
.sig:
    ld a, (hl)
    cp '0'
    jr nz, .found
    inc hl
    inc c
    djnz .sig
.found:
    ld a, c
    ld (digix), a
    xor a
    ld (padn), a
    jr emit_pad

; fn 70 - print flag param1 as decimal 0-255.
p8:
    call print_enter
    ld a, (param)
    ld l, a
    ld h, 0
    ld de, XBN_FLAGS
    add hl, de
    ld l, (hl)
    ld h, 0
    call emit_u16
    jp print_leave

; fn 71 - print flags param1/param1+1 as decimal 0-65535, low byte first.
p16:
    ld a, (param)
    inc a
    jr z, .noop                  ; flag 255 has no flag 256
    call print_enter
    ld a, (param)                ; re-fetch: print_enter clobbers A
    call pair_read
    call emit_u16
    jp print_leave
.noop:
    or a
    ret

; A = flag number -> HL = the pair at [A],[A+1], low byte first. Parks the
; pointer for pair_store. Caller has already rejected A = 255.
pair_read:
    ld l, a
    ld h, 0
    ld de, XBN_FLAGS
    add hl, de
    ld (pairp), hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ret

; HL = value -> written to the pair pair_read last addressed.
pair_store:
    ld de, (pairp)
    ex de, hl
    ld (hl), e
    inc hl
    ld (hl), d
    ret

pairp:   dw 0

; fn 72 - [n,n+1] += flag 249 as an immediate. Flag 251 = 1 on overflow.
add8:
    ld a, (param)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld c, a
    ld b, 0
    add hl, bc
    ld a, 0                      ; does not disturb CF
    adc a, 0
    ld (XBN_FLAGS + FLAG_RESULT), a
    jp pair_store
.noop:
    or a
    ret

; fn 73 - [n,n+1] -= flag 249 as an immediate. Flag 251 = 1 on underflow.
sub8:
    ld a, (param)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld a, (XBN_FLAGS + FLAG_OP2)
    ld c, a
    ld b, 0
    or a                         ; clear CF; A holds op2, which is in C now
    sbc hl, bc
    ld a, 0
    adc a, 0
    ld (XBN_FLAGS + FLAG_RESULT), a
    jp pair_store
.noop:
    or a
    ret

; fn 74 - compare [n,n+1] against the pair at flag 249.
; Flag 251 = 0 less, 1 equal, 2 greater. Neither pair is written.
cmpp:
    ld a, (XBN_FLAGS + FLAG_OP2)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld (tmp16), hl
    ld a, (param)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld de, (tmp16)
    or a
    sbc hl, de
    ld a, 1
    jr z, .store
    ld a, 0
    jr c, .store
    ld a, 2
.store:
    ld (XBN_FLAGS + FLAG_RESULT), a
    or a                         ; CF clear: sbc above leaves the borrow live
    ret
.noop:
    or a
    ret

; fn 75 - [n,n+1] += the pair at flag 249. Flag 251 = 1 on overflow.
; Operand first, target second: pair_read parks the pointer pair_store uses.
addp:
    ld a, (XBN_FLAGS + FLAG_OP2)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld (tmp16), hl
    ld a, (param)
    inc a
    jr z, .noop
    dec a
    call pair_read
    ld de, (tmp16)
    add hl, de
    ld a, 0
    adc a, 0
    ld (XBN_FLAGS + FLAG_RESULT), a
    jp pair_store
.noop:
    or a
    ret

tmp16:   dw 0

; HL / C -> HL quotient, A remainder. C must be 128 or less: the rla
; shifts the remainder's bit 7 out into CF, and a larger divisor allows a
; remainder that needs it. Only ever called with 60. Corrupts AF, B, HL.
div16_8:
    xor a
    ld b, 16
.loop:
    add hl, hl
    rla
    cp c
    jr c, .skip
    sub c
    inc l
.skip:
    djnz .loop
    ret

; fn 82 - print flags param1/param1+1 as HH:MM. Two separate byte flags,
; not a 16-bit pair: the clock module keeps its hour and minute that way.
hhmm:
    ld a, (param)
    inc a
    jr z, .noop
    call print_enter
    ld a, (param)                ; re-fetch: print_enter clobbers A
    ld l, a
    ld h, 0
    ld de, XBN_FLAGS
    add hl, de
    ld a, (hl)
    inc hl
    ld (tmpptr), hl
    ld l, a
    ld h, 0
    call emit_min2
    ld a, ':'
    call SVC_PUTCHAR
    ld hl, (tmpptr)
    ld l, (hl)
    ld h, 0
    call emit_min2
    jp print_leave
.noop:
    or a
    ret

; fn 83 - print flags param1/param1+1, a 16-bit second count, as MM:SS.
mmss:
    ld a, (param)
    inc a
    jr z, .noop
    call print_enter
    ld a, (param)                ; re-fetch: print_enter clobbers A
    call pair_read               ; HL = total seconds
    ld c, 60
    call div16_8                 ; HL = minutes, A = seconds
    ld (tmpsec), a
    call emit_min2
    ld a, ':'
    call SVC_PUTCHAR
    ld a, (tmpsec)
    ld l, a
    ld h, 0
    call emit_min2
    jp print_leave
.noop:
    or a
    ret

tmpptr:  dw 0
tmpsec:  db 0

; --- Print target window (fn 84) --------------------------------------
; tgtWin 0 = none (the author brackets prints with WINDOW). tgtWin 1-7 =
; the four printing fns bracket their own output: print_enter selects it
; and parks the replaced window, print_leave restores it - and so flushes.
tgtWin:  db 0
prevWin: db 0

; fn 84 - EXTERN w 84. p1 1-7 sets the target; p1 = 0 or p1 > 7 clears it
; (never masks 8-255 onto a real window number). p1 is the window number
; itself, not a flag number - unlike every other fn in this module.
settgt:
    ld a, (param)
    cp 8
    jr nc, .none
    or a
    jr z, .none
    ld (tgtWin), a
    jr .done
.none:
    xor a
    ld (tgtWin), a
.done:
    or a
    ret

; Entered after a printing fn's own flag-255 guard; a no-op while
; tgtWin is 0. SVC_WINDOW's out A is the window it replaced.
print_enter:
    ld a, (tgtWin)
    or a
    ret z
    call SVC_WINDOW
    ld (prevWin), a
    ret

; Tail-called as a printing fn's final, CF-clear ret. SVC_WINDOW leaves
; CF clear for any A in 0-7 (xbn.inc), which prevWin always is here.
print_leave:
    ld a, (tgtWin)
    or a
    ret z
    ld a, (prevWin)
    call SVC_WINDOW
    ret

; --- Object queries (fns 76-81) ---------------------------------------
; Every walk runs 0..(XBN_NUMOBJ)-1: entries past the live count are
; stale, so a fixed 256 would count rubbish.

; A = object -> HL = XBN_OBJTABLE + A*6, the same Z80N MUL index as
; src/engine.asm's obj_ptr. Corrupts DE, F; A and BC survive.
obj_ptr_of:
    ld d, OBJ_SIZE
    ld e, a
    mul d, e
    ld hl, XBN_OBJTABLE
    add hl, de
    ret

; A = bit 0-7 -> A = 1 << bit. Corrupts B, F.
mask_of:
    ld b, a
    ld a, 1
    inc b
.shl:
    dec b
    ret z
    add a, a
    jr .shl

; A = count -> flag 251, CF set when zero. The shared condition tail of
; fns 78 and 81: under v2 a set CF fails the DAAD entry.
cnt_result:
    ld (XBN_FLAGS + FLAG_RESULT), a
    or a
    ret nz
    scf
    ret

qwant:   db 0                    ; wanted location / noun / attribute mask
qofs:    db 0                    ; attribute byte offset, 2 or 3

; fn 78 - EXTERN loc 78. CONDITION: objects whose location byte is loc
; counted into flag 251 (252/253/254 pseudo-locations included); CF set
; when the count is zero.
atloc:
    ld a, (param)
    ld (qwant), a
    ld bc, 0                     ; B = object index, C = count
.scan:
    ld a, (XBN_NUMOBJ)
    cp b
    jr z, .done
    ld a, b
    call obj_ptr_of
    ld a, (hl)                   ; +0 location
    ld hl, qwant
    cp (hl)
    jr nz, .next
    inc c
.next:
    inc b
    jr .scan
.done:
    ld a, c
    jp cnt_result

; fn 80 - EXTERN noun 80. CONDITION: the LOWEST-numbered object whose
; noun byte is noun, into flag 251; CF set with 251 = 0 when none
; matches. Object 0 is a valid answer, so CF is the discriminator.
bynoun:
    ld a, (param)
    ld (qwant), a
    ld b, 0
.scan:
    ld a, (XBN_NUMOBJ)
    cp b
    jr z, .none
    ld a, b
    call obj_ptr_of
    ld de, 4
    add hl, de                   ; +4 noun
    ld a, (hl)
    ld hl, qwant
    cp (hl)
    jr z, .found
    inc b
    jr .scan
.found:
    ld a, b
    ld (XBN_FLAGS + FLAG_RESULT), a
    or a                         ; CF clear: found
    ret
.none:
    xor a
    ld (XBN_FLAGS + FLAG_RESULT), a
    scf
    ret

; fn 81 - EXTERN bit 81. CONDITION: objects with extended-attribute bit
; (0-15) set counted into flag 251; CF set with 251 = 0 when zero, and for
; bit > 15. FLAG order (src/engine.asm): +3 = attrs 0-7, +2 = attrs 8-15.
attrcnt:
    ld a, (param)
    cp 16
    jr nc, .none
    ld c, 3                      ; +3 holds attributes 0-7
    cp 8
    jr c, .mask
    sub 8
    dec c                        ; +2 holds attributes 8-15
.mask:
    ld hl, qofs
    ld (hl), c
    call mask_of
    ld (qwant), a
    ld bc, 0                     ; B = object index, C = count
.scan:
    ld a, (XBN_NUMOBJ)
    cp b
    jr z, .done
    ld a, b
    call obj_ptr_of
    ld a, (qofs)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (qwant)
    and (hl)
    jr z, .next
    inc c
.next:
    inc b
    jr .scan
.done:
    ld a, c
    jp cnt_result
.none:
    xor a
    ld (XBN_FLAGS + FLAG_RESULT), a
    scf
    ret

; fn 79 - EXTERN 0 79. ACTION (CF always clear): the total weight of
; everything carried or worn, 16-BIT - flag 251 = low byte, 250 = high.
wtot:
    ld hl, 0
    ld (wtacc), hl
    ld b, 0
.scan:
    ld a, (XBN_NUMOBJ)
    cp b
    jr z, .done
    ld a, b
    call obj_ptr_of
    ld a, (hl)                   ; +0 location
    cp OBJ_CARRIED
    jr z, .add
    cp OBJ_WORN
    jr nz, .next
.add:
    push bc
    ld a, b
    call obj_wt16
    ld de, (wtacc)
    add hl, de                   ; 16-bit, no saturation (see obj_wt16)
    ld (wtacc), hl
    pop bc
.next:
    inc b
    jr .scan
.done:
    ld hl, (wtacc)
    ld a, l
    ld (XBN_FLAGS + FLAG_RESULT), a
    ld a, h
    ld (XBN_FLAGS + FLAG_HIGH), a
    or a                         ; CF clear: fn 79 is an action
    ret

wtacc:   dw 0                    ; the running carried+worn total

; A = object -> HL = its true weight, own plus contents. Deliberate
; divergence from src/overlay0.asm obj_weight_of / weight_total: both
; accumulators are 16-BIT with NO 255 saturation; the rest is its semantics.
obj_wt16:
    ld e, 10
owf16:
    push bc
    push de
    ld c, a                      ; C = this object's number
    call obj_ptr_of
    inc hl
    ld a, (hl)                   ; +1 weight/attribute byte
    ld b, a
    and $3F
    ld l, a
    ld h, 0                      ; HL = the running 16-bit total
    or a
    jr z, .fin                   ; zero own weight: no descent
    bit 6, b
    jr z, .fin                   ; not a container
    pop de
    push de                      ; recover the incoming depth in E
    ld a, e
    dec a
    jr z, .fin                   ; depth budget spent
    ld e, a
    ld d, 0                      ; D = child index
.scan:
    ld a, (XBN_NUMOBJ)
    cp d
    jr z, .fin
    push bc
    push de
    push hl
    ld a, d
    call obj_ptr_of
    ld a, (hl)                   ; child's +0 location
    pop hl
    pop de
    pop bc
    cp c                         ; located at this container's number?
    jr nz, .next
    push bc
    push de
    push hl                      ; the running total
    ld a, d
    call owf16                   ; E already holds the child's depth
    pop bc
    add hl, bc                   ; total += child weight
    pop de
    pop bc
.next:
    inc d
    jr .scan
.fin:
    pop de
    pop bc
    ret

; --- Random without repeat (fns 76-77) --------------------------------
pickPool: db 0                   ; pool size 1-64; 0 = not armed
pickUsed: ds 8                   ; 64-bit used bitmap

; A = index 0-63 -> HL = its pickUsed byte, A = its mask within that
; byte. Corrupts E, F; preserves BC.
bit_addr:
    push bc
    ld c, a
    and 7
    call mask_of
    ld e, a
    ld a, c
    srl a
    srl a
    srl a                        ; A = index / 8, 0-7
    ld c, a
    ld b, 0
    ld hl, pickUsed
    add hl, bc
    ld a, e
    pop bc
    ret

; A = index -> Z set when it is still unused. Corrupts AF, E, HL.
bit_test:
    call bit_addr
    and (hl)
    ret

; A = index -> marked used; A = the updated byte, always nonzero.
bit_set:
    call bit_addr
    or (hl)
    ld (hl), a
    ret

; fn 76 - EXTERN n 76. Arms the picker with pool size n and clears the
; used bitmap. n = 0 or n > 64 refuses: CF set, nothing changed.
pckarm:
    ld a, (param)
    or a
    jr z, .bad
    cp 65
    jr nc, .bad
    ld (pickPool), a
    ld hl, pickUsed
    ld b, 8
    xor a
.clr:
    ld (hl), a
    inc hl
    djnz .clr
    or a                         ; CF clear: armed
    ret
.bad:
    scf
    ret

; fn 77 - EXTERN 0 77. CONDITION: one still-unused index 0..n-1 into flag
; 251; CF set with 251 = 0 when the pool is unarmed or exhausted (no
; auto-reset - fn 76 re-arms). Cyclic advance from one draw, bounded by n.
pckget:
    ld a, (pickPool)
    or a
    jr z, .empty
    ld c, a                      ; C = pool size n
    ld b, 0
.any:
    ld a, b
    cp c
    jr z, .empty                 ; every index used
    ld a, b
    call bit_test
    jr z, .draw
    inc b
    jr .any
.draw:
    call SVC_RANDOM              ; A = raw byte; BC survives (src/main.asm)
.mod:
    cp c                         ; reduce mod n by subtraction, n <= 64
    jr c, .from
    sub c
    jr .mod
.from:
    ld b, a                      ; B = the drawn index
.step:
    ld a, b
    call bit_test
    jr z, .take
    inc b
    ld a, b
    cp c
    jr c, .step
    ld b, 0                      ; wrap; .any proved one index is free
    jr .step
.take:
    ld a, b
    ld (XBN_FLAGS + FLAG_RESULT), a
    call bit_set
    or a                         ; CF clear: fn 77 passes
    ret
.empty:
    xor a
    ld (XBN_FLAGS + FLAG_RESULT), a
    scf                          ; 251 = 0 with CF set, the fns 80/81 shape
    ret

; No hook. The interpreter still calls this every frame in a combined
; build, so it must exist and must return at once.
int:
    ret

param:   db 0

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
