; xbnmod.inc - shared machinery for XBN modules and combined binaries.
; Include AFTER xbn.inc and BEFORE ORG - macros and equates only, emits
; nothing until XBN_BEGIN runs after ORG.

XBN_CALL_SLOTS  equ 8            ; FROZEN at first release. Append only.

; Emits header then 8 three-byte slots at $C00A (slot n = $C00A + 3n);
; absent slots jump to xbn_null_ret. Invoke once per binary.
    MACRO XBN_BEGIN ext_entry, int_entry
        XBN_HEADER ext_entry, int_entry
xbn_call_table:
        IFDEF XBN_HAS_TOOLKIT
        jp toolkit.tk_call0
        jp toolkit.tk_call1
        jp toolkit.tk_call2
        jp toolkit.tk_call3
        ELSE
        jp xbn_null_ret
        jp xbn_null_ret
        jp xbn_null_ret
        jp xbn_null_ret
        ENDIF
        jp xbn_null_ret          ; slot 4 reserved
        jp xbn_null_ret          ; slot 5 reserved
        jp xbn_null_ret          ; slot 6 reserved
        jp xbn_null_ret          ; slot 7 reserved
xbn_null_ret:
        ret
        ASSERT xbn_call_table == XBN_ORG + 10, xbn_call_table moved off $C00A
        ASSERT (xbn_null_ret - xbn_call_table) == 3 * XBN_CALL_SLOTS, call table length does not match XBN_CALL_SLOTS
; Palette ownership: fade and atmosphere both drive the Layer 2 palette
; from the #int hook, and overlapping writes corrupt an entry.
; 0 nobody, 1 fade, 2 atmosphere.
xbn_pal_owner:
        db 0
    ENDM

; Dispatch chain shared by all.asm and xbnbuild's generated source - one
; definition. Rebuilds the entry contract (A=B=param1, C=fn,
; HL=flags+param1, DE=objTable+param1*6, IX=flags base) per module call.

; At the top of a chain's EXTERN entry: park param1 and fn.
    MACRO XBN_CHAIN_ENTER
        ld (xbn_p1save), a
        ld a, c
        ld (xbn_fnsave), a
    ENDM

; Emits xbn_setup and its two saved bytes. Invoke once per binary.
; param1*6 uses Z80N MUL D,E (ED 30, 8T, 2 bytes), as the interpreter
; does for index*6 in src/gfxcache.asm.
    MACRO XBN_CHAIN_SETUP
xbn_setup:
        ld a, (xbn_p1save)
        ld hl, XBN_FLAGS
        ld d, 0
        ld e, a
        add hl, de               ; HL = flags + param1
        push hl
        ld d, 6
        ld e, a
        mul d, e                 ; DE = param1 * 6
        ld hl, XBN_OBJTABLE
        add hl, de
        ex de, hl                ; DE = objTable + param1*6
        pop hl                   ; HL = flags + param1
        ld ix, XBN_FLAGS
        ld a, (xbn_fnsave)
        ld c, a
        ld a, (xbn_p1save)
        ld b, a                  ; A = B = param1
        ret
xbn_p1save:
        db 0
xbn_fnsave:
        db 0
    ENDM
