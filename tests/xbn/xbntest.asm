; xbntest.asm - fixture XBN for the sd\XBN leg. Not shipped.
; DEVICE ZXSPECTRUMNEXT (not in the Task 1 brief's fragment): sjasmplus
; only allows SAVEBIN in "real device emulation mode" (See DEVICE) -
; without it the assembler refuses the SAVEBIN below outright. Same
; device src\main.asm's own DEVICE line declares.
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "../../authoring-kit/xbn.inc"
    ORG XBN_ORG
    XBN_HEADER ext_main, int_tick

ext_main:
    ; Contract on entry: A=B=param1, C=fn, HL=flags+param1,
    ; DE=objTable+param1*6, IX=flags base.
    ld (XBN_FLAGS+200), a       ; param1
    ld a, c
    ld (XBN_FLAGS+201), a       ; fn code
    ld a, (hl)
    ld (XBN_FLAGS+202), a       ; *(flags+param1)
    ld a, (de)
    ld (XBN_FLAGS+203), a       ; object location byte
    push ix
    pop hl
    ld a, h
    ld (XBN_FLAGS+204), a       ; IX high byte - expect $A2
    ld a, l
    ld (XBN_FLAGS+205), a       ; IX low byte - expect $00
    ld a, c
    cp 21
    ret nz
    jp svc_probe                ; Task 6 extends this; RET-only until then

svc_probe:
    ret                         ; placeholder body replaced in Task 6

call_target:
    ; COUPLED to tests\extern.dsf's XCAL entry (CALL lsb msb) - the
    ; address here must match the literal bytes in that DSF's PRO 5
    ; XCAL entry. Currently $C02C (lsb 44, msb 192; see
    ; tests\out\xbn\xbntest.sym after assembly) - re-encode extern.dsf's
    ; XCAL entry by hand if this label ever moves.
    ld a, $77
    ld (XBN_FLAGS+220), a
    ret

int_tick:
    ; 50Hz: increment flag 221, wrapping. IX = flags base per contract,
    ; but +221 is outside Z80's (ix+d) signed-displacement range (max
    ; +127 from IX) - the Task 1 brief's "inc (ix+221)" does not
    ; assemble (sjasmplus: "Offset out of range"). Same target byte
    ; (XBN_FLAGS+221) reached via absolute addressing instead; 8-bit
    ; INC wraps 255->0 the same as the ix+d form would have.
    ld a, (XBN_FLAGS+221)
    inc a
    ld (XBN_FLAGS+221), a
    ret

    ; pad proves >8K binaries load into both pages
    ds $2100, $E5
tail_marker:
    ld a, $99
    ld (XBN_FLAGS+222), a       ; callable via CALL to prove page 2 mapped
    ret
xbn_end:

    SAVEBIN "tests/out/xbn/GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
