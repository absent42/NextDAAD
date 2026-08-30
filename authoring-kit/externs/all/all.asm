; all.asm - every collection module in one GAME.XBN.
;
; One source file, so the externs folder contract (one .asm, GAME.XBN,
; README.md, build.ps1) still holds. Modules are INCLUDEd by kit-relative
; path, resolved by the -I <kit root> build.ps1 and the audit both pass.
;
; Adding a module: define its XBN_HAS_ symbol, INCLUDE it, and add its
; .ext to all_ext and its .int to all_int. Nothing else moves.

    DEVICE ZXSPECTRUMNEXT
    DEFINE XBN_MODULE
    DEFINE XBN_HAS_TICKER
    DEFINE XBN_HAS_FADE
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN all_ext, all_int

; EXTERN/CALL chain. xbn_setup rebuilds the documented entry contract
; before each module call - modules may clobber everything. Each module
; returns immediately for fn codes outside its own range.
all_ext:
    XBN_CHAIN_ENTER
    call xbn_setup
    call ticker.ext
    call xbn_setup
    call fade.ext
    ret

; #int chain. IX = flags base is the only documented register; every
; module's int is a load-and-test when idle.
all_int:
    ld ix, XBN_FLAGS
    call ticker.int
    ld ix, XBN_FLAGS
    call fade.int
    ret

    XBN_CHAIN_SETUP

    INCLUDE "externs/ticker/ticker.asm"
    INCLUDE "externs/fade/fade.asm"

xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
