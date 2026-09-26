; uo - xbnbuild selftest fixture: output hook only, no claims. The
; output hook counts printed characters in flag 191.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN3 uo.ext, uo.int, 0, uo.out
    ENDIF

    MODULE uo
ext:
    or a                        ; claims no fn codes
    ret
int:
    ret
out:
    ld a, (XBN_FLAGS + 191)
    inc a
    ld (XBN_FLAGS + 191), a
    ret
    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
