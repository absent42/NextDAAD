; xbnmod.inc - shared machinery for XBN modules and combined binaries.
; Include AFTER xbn.inc and BEFORE ORG. This file defines macros and
; equates ONLY: everything it owns is emitted by XBN_BEGIN, which runs
; after ORG. Emitting a byte at include time would land it before the
; ORG and corrupt the binary.
;
; Every shipped binary includes this, standalone single-module binaries
; included: the pinned CALL table must exist at $C00A in every build
; shape or an absent slot is not a safe no-op.

XBN_CALL_SLOTS  equ 8            ; FROZEN at first release. Append only.

; Emits the 10-byte header, then the pinned CALL table, then the shared
; data the table needs. CALL lsb msb targets an absolute address, and
; routine addresses differ between the standalone, combined and subset
; builds, so authors CALL a slot, never a routine: slot n is at
; $C00A + 3n. Slots 0-3 belong to the toolkit; 4-7 are reserved. A slot
; whose module is absent jumps to xbn_null_ret, so a stale CALL is a
; no-op rather than a jump into unrelated code.
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
; Palette ownership: fade and atmosphere both drive the Layer 2 palette
; from the #int hook, and overlapping writes corrupt an entry.
; 0 nobody, 1 fade, 2 atmosphere.
xbn_pal_owner:
        db 0
    ENDM

; --- dispatch chain, shared by all.asm and xbnbuild's generated source ---
; Modules may clobber every register, so the documented entry contract
; (A=B=param1, C=fn, HL=flags+param1, DE=objTable+param1*6, IX=flags base)
; is rebuilt before each module call. Defined here, not in either caller,
; so there is one copy to change.

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
