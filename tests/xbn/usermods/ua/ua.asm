; ua - xbnbuild selftest fixture: line hook only, scratch + state claims,
; a sibling include. The line hook counts typed lines in flag 190.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN3 ua.ext, ua.int, ua.line, 0
    ENDIF

    MODULE ua
SCRATCH_SIZE equ 300
STATE_SIZE   equ 4
ext:
    or a                        ; claims no fn codes
    ret
int:
    ret
line:
    ld a, (XBN_FLAGS + 190)
    inc a
    ld (XBN_FLAGS + 190), a
    or a                        ; CF clear: line not consumed
    ret
    INCLUDE "uainc.asm"
    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    MODULE ua
    XBN_CLAIMS SCRATCH_SIZE, STATE_SIZE
    ENDMODULE
    DISPLAY "standalone ua scratch +", /D, ua.SCRATCH - XBN_SCRATCH, " state +", /D, ua.STATE - XBN_STATE
    ENDIF
