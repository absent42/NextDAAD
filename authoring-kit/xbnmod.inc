; xbnmod.inc - shared machinery for XBN modules and combined binaries.
; Include AFTER xbn.inc and BEFORE ORG - macros and equates only, emits
; nothing until XBN_BEGIN runs after ORG.

XBN_CALL_SLOTS  equ 8            ; FROZEN at first release. Append only.

; Emits header then 8 three-byte slots at $C00E (slot n = $C00E + 3n);
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
        ASSERT xbn_call_table == XBN_ORG + 14, xbn_call_table moved off $C00E
        ASSERT (xbn_null_ret - xbn_call_table) == 3 * XBN_CALL_SLOTS, call table length does not match XBN_CALL_SLOTS
; Palette ownership: fade and atmosphere both drive the Layer 2 palette
; from the #int hook, but only check ownership there (never acquire) -
; overlapping unchecked writes corrupt an entry.
xbn_pal_owner: db 0              ; 0 free, 1 fade, 2 atmosphere
xbn_pal_acquire:                 ; A = 1 or 2. FOREGROUND-ONLY (EXTERN context) - never from a hook. CF clear = mine now
        push hl
        ld hl, xbn_pal_owner
        cp (hl)
        jr z, .mine
        ld l, (hl)                ; nonzero and not mine: refuse
        inc l
        dec l
        jr nz, .busy
        ld hl, xbn_pal_owner
        ld (hl), a
.mine:
        pop hl
        or a                      ; CF clear
        ret
.busy:
        pop hl
        scf
        ret
xbn_pal_release:                 ; A = 1 or 2 (my id); frees only if mine. Foreground or the owner's own hook
        push hl
        ld hl, xbn_pal_owner
        cp (hl)
        jr nz, .keep
        ld (hl), 0
.keep:
        pop hl
        ret
xbn_pal_check:                   ; A = 1 or 2 (my id). CF clear iff I hold it. ISR-safe (memory only)
        push hl
        ld hl, xbn_pal_owner
        cp (hl)
        pop hl
        ret z                     ; equal: CF clear from cp
        scf
        ret
; Text width from hardware truth (NR $6B bit 6) - one reviewed probe.
; Out: E = 80|40, D = row stride 160|80, HL = bottom-row (27) base.
; Corrupts AF, BC, DE, HL. ISR-safe: the ISR calls the hook only between
; complete select+access pairs (src/interrupts.asm's port audit).
xbn_width:
        ld bc, $243B
        ld a, $6B
        out (c), a
        inc b
        in a, (c)
        ld hl, $70E0
        ld de, 160*256 + 80
        bit 6, a
        ret nz
        ld hl, $6870
        ld de, 80*256 + 40
        ret
    ENDM

; Scratch RAM above xbn_end: bytes inside the mapped 16K bank ($FFFF) but
; outside the saved image. Offset claims from XBN_SCRATCH, chained off
; XBN_SCRATCH_FREE below, so modules do not collide.
;
; Claims: hints.asm rdbuf, offset 0, 256 bytes
; Claims: fade.asm palStage, offset 256, 512 bytes
XBN_SCRATCH_FREE equ 768         ; next unclaimed offset - bump when you add a claim

; Sets XBN_SCRATCH and asserts every claim above still fits inside the
; mapped bank. Invoke once, right after the top-level file's own
; xbn_end: is defined (hints.asm standalone, or all.asm).
    MACRO XBN_SCRATCH_END
XBN_SCRATCH equ xbn_end
        ASSERT XBN_SCRATCH + XBN_SCRATCH_FREE <= $10000, scratch RAM claims run past the mapped 16K bank ($FFFF)
    ENDM

; Dispatch chain shared by all.asm and xbnbuild's generated source - one
; definition. Rebuilds the entry contract (A=B=param1, C=fn,
; HL=flags+param1, DE=objTable+param1*6, IX=flags base) per module call.

; Parks param1/fn and clears the verdict accumulator.
; Carry accumulation across the chain: xbn_setup clobbers F, so each
; module's verdict is folded into xbn_cfacc immediately after its call.
    MACRO XBN_CHAIN_ENTER
        ld (xbn_p1save), a
        ld a, c
        ld (xbn_fnsave), a
        xor a
        ld (xbn_cfacc), a
    ENDM

    MACRO XBN_CHAIN_CAPTURE      ; F = the module's verdict on entry
        ld a, (xbn_cfacc)        ; ld does not touch F
        adc a, 0                 ; +1 iff the module set CF
        ld (xbn_cfacc), a
    ENDM

    MACRO XBN_CHAIN_VERDICT      ; the chain's own RET
        ld a, (xbn_cfacc)
        or a
        ret z                    ; nobody failed: CF clear
        scf
        ret
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
xbn_cfacc:
        db 0
    ENDM
