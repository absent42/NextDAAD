; ub - xbnbuild selftest fixture: no hooks, a state claim only.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN ub.ext, ub.int
    ENDIF

    MODULE ub
STATE_SIZE equ 2
ext:
    or a                        ; claims no fn codes
    ret
int:
    ret
refs:
    dw STATE
    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    MODULE ub
    XBN_CLAIMS 0, STATE_SIZE
    ENDMODULE
    ENDIF
