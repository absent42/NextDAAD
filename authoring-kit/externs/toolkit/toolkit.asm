; toolkit.asm - NextDAAD XBN worked example.
;
; The pure-logic shape: no #int hook, no arming call. Every function takes
; a FLAG NUMBER as the EXTERN parameter rather than a value, so the module
; costs four flags however many values a game manipulates.
;
; Printing goes through SVC_PUTCHAR into whatever DAAD window the author
; has selected. The author brackets the call with WINDOW, exactly as a
; status-line process already does, so this module needs no tilemap
; geometry and no width probe.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN toolkit.ext, toolkit.int
    ENDIF

    MODULE toolkit

FLAG_WIDTH      equ 248          ; 0 = no padding; bit 7 = zero-pad
FLAG_OP2        equ 249          ; immediate or flag number, per fn
FLAG_RESULT     equ 251          ; result and status

ext:
    ld a, b
    ld (param), a                ; park param1 before any call clobbers B
    ld a, c
    cp 70
    jp z, p8
    cp 71
    jp z, p16
    cp 82
    jp z, hhmm
    cp 83
    jp z, mmss
    ret

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
    ld a, (param)
    ld l, a
    ld h, 0
    ld de, XBN_FLAGS
    add hl, de
    ld l, (hl)
    ld h, 0
    jp emit_u16

; fn 71 - print flags param1/param1+1 as decimal 0-65535, low byte first.
p16:
    ld a, (param)
    inc a
    ret z                        ; flag 255 has no flag 256
    dec a
    call pair_read
    jp emit_u16

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
    ret z
    dec a
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
    jp emit_min2

; fn 83 - print flags param1/param1+1, a 16-bit second count, as MM:SS.
mmss:
    ld a, (param)
    inc a
    ret z
    dec a
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
    jp emit_min2

tmpptr:  dw 0
tmpsec:  db 0

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
