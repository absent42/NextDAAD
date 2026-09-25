; playername.asm - asks for the player's name and keeps it with the game.
;
; DAAD cannot store free text: the DSF reads a line with PARSE 0, fn 20
; copies it out of the interpreter's recall buffer (SVC_GETLINE), fn 21
; prints it. The name lives in the extern state area, so SAVE, LOAD,
; RAMSAVE and RAMLOAD keep it with the game.
;
; fn codes (EXTERN p fn):
;   20 CAPTURE  condition - take the last typed line as the name. Leading and
;               trailing blanks are dropped, it is cut to NAME_MAX characters
;               and its first letter is capitalised. Carry SET = nothing was
;               typed (empty ENTER, timeout or only blanks); the name is left
;               empty. An interpreter older than API 3 has no SVC_GETLINE:
;               the name stays empty and the call passes. p unused.
;   21 PRINT    action - print the name through the current window; prints
;               nothing when there is no name. p unused.
;   22 UNNAMED  condition - carry CLEAR when no name is stored, SET when one
;               is. p unused.
;   23 NOTNAME  condition - carry SET when the name equals message p (any
;               case); CLEAR otherwise, when there is no name, or when
;               message p does not exist.
; Each condition passes when no GAME.XBN is loaded, the safe default for
; every one of them.
;
; Flags: none. State area: NAME_MAX + 1 bytes at offset 111 (xbnmod.inc).

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN playername.ext, playername.int
    ENDIF

    MODULE playername

NAME_MAX    equ 16                          ; characters kept, the NUL is extra
MIN_API     equ 3                           ; SVC_GETLINE arrived with API 3

; Claim: the name, ASCIIZ, at the top of the state area (xbnmod.inc).
name        equ XBN_STATE + 111
    ASSERT 111 >= XBN_STATE_TOP
    ASSERT 111 + NAME_MAX + 1 <= XBN_STATE_LEN

ext:
    ld a, c
    cp 20
    jr z, capture
    cp 21
    jr z, print
    cp 22
    jr z, unnamed
    cp 23
    jr z, notname
.notmine:
    or a                                    ; not ours: carry clear
    ret

; fn 20 - CONDITION, carry set = nothing was typed
capture:
    xor a
    ld (name), a                            ; forget any earlier name first
    call SVC_VERSION
    cp MIN_API
    jr nc, .read
    or a                                    ; no input services: pass, no name
    ret
.read:
    call SVC_GETLINE                        ; HL = line, BC = length
    ret c                                   ; empty ENTER or timeout: fail
.lead:
    ld a, (hl)                              ; skip leading blanks
    cp ' '
    jr nz, .copy
    inc hl
    jr .lead
.copy:
    ld de, name
    ld b, NAME_MAX
.next:
    ld a, (hl)
    or a
    jr z, .cut
    ld (de), a
    inc de
    inc hl
    djnz .next
.cut:
    xor a
    ld (de), a                              ; DE = one past the last copied byte
.trim:
    ld h, d                                 ; drop trailing blanks
    ld l, e
    ld bc, name
    or a
    sbc hl, bc
    jr z, .empty                            ; nothing but blanks
    dec de
    ld a, (de)
    cp ' '
    jr nz, .caps
    xor a
    ld (de), a
    jr .trim
.empty:
    scf                                     ; only blanks: treat as nothing typed
    ret
.caps:
    ld a, (name)                            ; capitalise the first letter only
    call upcase
    ld (name), a
    or a
    ret

; fn 21 - ACTION
print:
    ld a, (name)
    or a
    ret z                                   ; no name: nothing printed, carry clear
    ld hl, name
    call SVC_PUTS
    or a
    ret

; fn 22 - CONDITION, carry set = a name is stored
unnamed:
    ld a, (name)
    or a
    ret z                                   ; empty: carry clear, the entry continues
    scf
    ret

; fn 23 - CONDITION, carry set = the name equals message p (any case)
notname:
    ld a, (name)
    or a
    ret z                                   ; no name: never equal, carry clear
    ld a, b                                 ; p = message number
    call SVC_GETMSG                         ; HL = text, BC = length
    jr c, .differ                           ; no such message
    ld a, b
    or a
    jr nz, .differ                          ; longer than any name
    ld a, c
    cp NAME_MAX + 1
    jr nc, .differ
    ld de, name
.cmp:
    ld a, c
    or a
    jr z, .end                              ; message used up
    ld a, (hl)
    call upcase
    ld b, a
    ld a, (de)
    call upcase
    cp b
    jr nz, .differ
    inc hl
    inc de
    dec c
    jr .cmp
.end:
    ld a, (de)                              ; the name must end here too
    or a
    jr nz, .differ
    scf
    ret
.differ:
    or a
    ret

; A = A in upper case when it is a-z. Corrupts F only.
upcase:
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    sub 32
    ret

int:
    ret                                     ; no frame work

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
