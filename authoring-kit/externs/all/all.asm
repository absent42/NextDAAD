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
    DEFINE XBN_HAS_HINTS
    DEFINE XBN_HAS_CLOCK
    DEFINE XBN_HAS_TIMER
    DEFINE XBN_HAS_TOOLKIT
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
    XBN_CHAIN_CAPTURE
    call xbn_setup
    call fade.ext
    XBN_CHAIN_CAPTURE
    call xbn_setup
    call hints.ext
    XBN_CHAIN_CAPTURE
    call xbn_setup
    call clock.ext
    XBN_CHAIN_CAPTURE
    call xbn_setup
    call timer.ext
    XBN_CHAIN_CAPTURE
    call xbn_setup
    call toolkit.ext
    XBN_CHAIN_CAPTURE
    XBN_CHAIN_VERDICT

; #int chain. IX = flags base is the only documented register; every
; module's int is a load-and-test when idle.
; clock.int before timer.int: either order sees the change, but clock
; first lets a state-2 timer react the same frame. Do not reorder.
all_int:
    ld ix, XBN_FLAGS
    call ticker.int
    ld ix, XBN_FLAGS
    call fade.int
    ld ix, XBN_FLAGS
    call hints.int
    ld ix, XBN_FLAGS
    call clock.int
    ld ix, XBN_FLAGS
    call timer.int
    ld ix, XBN_FLAGS
    call toolkit.int
    ret

    XBN_CHAIN_SETUP

    INCLUDE "externs/ticker/ticker.asm"
    INCLUDE "externs/fade/fade.asm"
    INCLUDE "externs/hints/hints.asm"
    INCLUDE "externs/clock/clock.asm"
    INCLUDE "externs/timer/timer.asm"
    INCLUDE "externs/toolkit/toolkit.asm"

xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
