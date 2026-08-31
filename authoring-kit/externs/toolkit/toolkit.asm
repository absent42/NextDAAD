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
