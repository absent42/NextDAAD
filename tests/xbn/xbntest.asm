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
    jr z, .fn21
    cp 22
    ret nz
    jp fio_probe                ; Task 7
.fn21:
    jp svc_probe                ; Task 6

svc_probe:
    call SVC_VERSION
    ld (XBN_FLAGS+206), a       ; expect 1
    call SVC_RANDOM
    ld b, a
    call SVC_RANDOM
    cp b                        ; two draws differing is probabilistic
    ld a, 1                     ;  but a frozen PRNG returning equal
    jr nz, .ok                  ;  bytes twice is the failure being
    dec a                       ;  hunted (stuck rng) - accept rare 0
.ok:
    ld (XBN_FLAGS+207), a       ; expect 1 (almost always)
    ld hl, .msg
    call SVC_PUTS                ; visible banner on screen
    or a
    ret
.msg: db "XBN SVC OK ", 0

call_target:
    ; COUPLED to tests\extern.dsf's XCAL entry (CALL lsb msb) - the
    ; address here must match the literal bytes in that DSF's PRO 5
    ; XCAL entry. Currently $C05C (lsb 92, msb 192; see
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

; Task 7 probe: write 8 bytes to XBNFIO.TMP, close, reopen, read them
; back and compare. ESX_MODE_W/ESX_MODE_READ are esxDOS's own F_OPEN mode
; byte values (not re-exported by xbn.inc, which documents only the
; service calling convention) - defined locally here matching
; src\nextdaad.inc's ESX_MODE_W ($0E, write/create/truncate) and
; ESX_MODE_READ ($01).
ESX_MODE_READ equ $01
ESX_MODE_W    equ $0E
fio_probe:
    ld ix, .fname
    ld b, ESX_MODE_W
    call SVC_FOPEN
    jr c, .fail
    ld (.hnd), a
    ld ix, .wbuf
    ld bc, 8
    call SVC_FWRITE
    ld a, (.hnd)
    call SVC_FCLOSE
    ld ix, .fname
    ld b, ESX_MODE_READ
    call SVC_FOPEN
    jr c, .fail
    ld (.hnd), a
    ld ix, .rbuf
    ld bc, 8
    call SVC_FREAD
    ld a, (.hnd)
    call SVC_FCLOSE
    ld b, 8
    ld hl, .wbuf
    ld de, .rbuf
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .fail
    inc hl
    inc de
    djnz .cmp
    ld a, 1
    ld (XBN_FLAGS+208), a
    ret
.fail:
    xor a
    ld (XBN_FLAGS+208), a
    ret
.fname: db "XBNFIO.TMP", 0
.hnd:   db 0
.wbuf:  db $11,$22,$33,$44,$55,$66,$77,$88
.rbuf:  ds 8

    ; pad proves >8K binaries load into both pages
    ds $2100, $E5
tail_marker:
    ld a, $99
    ld (XBN_FLAGS+222), a       ; callable via CALL to prove page 2 mapped
    ret
xbn_end:

    SAVEBIN "tests/out/xbn/GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
