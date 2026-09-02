# Module shape

Two shapes. Write the second one unless you are certain the extern will never
be combined with another.

## Standalone

The minimum a lone `GAME.XBN` needs. `XBN_HEADER` emits the fourteen-byte
version 2 header - magic, version, the two entry addresses, the size and four
reserved bytes that must stay zero - from two labels, or `0` for an entry you
do not use. An interrupt-only extern (`ext` entry `0`, hook set) is legal, and
so is the reverse.

    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    ORG XBN_ORG
    XBN_HEADER ext_main, int_tick

    ; your code and data

xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG

You MUST define a label named `xbn_end` right after your last byte:
`XBN_HEADER` computes the size field from it. The loader rejects a size field
that disagrees with the real file length, whichever way it disagrees.

## Combinable

Every collection module builds two ways from one source: standalone, with its
own header and `GAME.XBN`, and as one module among several in a combined
binary that supplies both. The `IFNDEF XBN_MODULE` bracket is what makes that
work - a combined build defines `XBN_MODULE` before including you.

Use `XBN_BEGIN` (from `xbnmod.inc`) rather than `XBN_HEADER`: it emits the
same header followed by the pinned `CALL` slot table at `$C00E`, the palette
interlock helpers and `xbn_width`.

    ; Standalone build emits its own header and call table; a combined
    ; build defines XBN_MODULE and supplies both.
        IFNDEF XBN_MODULE
        DEVICE ZXSPECTRUMNEXT
        INCLUDE "xbn.inc"
        INCLUDE "xbnmod.inc"
        ORG XBN_ORG
        XBN_BEGIN myext.ext, myext.int
        ENDIF

        MODULE myext
    ext:
        ; EXTERN/CALL entry. Test C (the fn code) against your own range
        ; FIRST and return immediately on anything else - in a combined
        ; binary every module's ext sees every EXTERN call.
        or a                    ; not my fn: carry clear
        ret
    int:
        ; Frame hook. Required even as a bare ret - the combined chain and
        ; the subset builder call every module's hook every frame.
        ret
        ENDMODULE

        IFNDEF XBN_MODULE
    xbn_end:
        SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
        XBN_SCRATCH_END
        ENDIF

Rules that come with the shape:

- **`MODULE` / `ENDMODULE` around everything.** Labels become `myext.ext`,
  `myext.int` and so on, so two modules can both own an `ext` and a `.done`.
  Both entry labels passed to `XBN_BEGIN` are written module-qualified.
- **An `int` label always.** Even a bare `ret`. The combined chain calls it
  unconditionally, once per frame, whatever the module is doing.
- **`xbn_end`, `SAVEBIN` and `XBN_SCRATCH_END` stay inside the closing
  `IFNDEF` bracket.** In a combined build the top-level source owns all three;
  emitting your own would truncate the binary at your module.
- **Never publish a routine address as a `CALL` target.** Addresses move
  whenever any module in the binary is edited. Publish a slot number.

### Scratch RAM claims

Bytes above `xbn_end` are inside the mapped 16K bank but outside the saved
image - RAM you do not pay for in file size. `XBN_SCRATCH` only exists once
`XBN_SCRATCH_END` has run, and in a combined build that happens in the
top-level source, so claims go in a re-opened `MODULE` block after the closing
bracket:

    ; Read buffer, 256 bytes, claimed from XBN_SCRATCH (see xbnmod.inc).
        MODULE myext
    rdbuf:   equ XBN_SCRATCH + 0
        ENDMODULE

Take your offset from `XBN_SCRATCH_FREE` in `xbnmod.inc`, add your claim to
the comment list kept beside it, and bump `XBN_SCRATCH_FREE` past your claim
so the next module does not collide. `XBN_SCRATCH_END` asserts that every
claim still fits inside the mapped bank. Scratch RAM is never initialised for
you: write before you read.

## The ticker skeleton

`externs\ticker\ticker.asm` is the minimal working module, and its own
comments walk through every decision. The skeleton, abridged:

    ; Standalone build emits its own header and binary; a combined build
    ; defines XBN_MODULE and supplies both.
        IFNDEF XBN_MODULE
        DEVICE ZXSPECTRUMNEXT
        INCLUDE "xbn.inc"
        INCLUDE "xbnmod.inc"
        ORG XBN_ORG
        XBN_BEGIN ticker.ext, ticker.int
        ENDIF

        MODULE ticker

    ext:
        ; Contract on entry: A=B=param1, C=fn, HL=flags+param1,
        ; DE=objTable+param1*6, IX=flags base.
        ld a, c
        cp 30
        jr z, .arm
        cp 31
        jr nz, .notmine          ; any other fn: not ours
        xor a
        ld (armed), a            ; disarm
        ret                      ; CF clear (xor a above)
    .arm:
        xor a
        ld (armed), a            ; disarm FIRST - every failure below must
                                 ; leave the ticker OFF, not still running
        ld a, b                  ; param1 = user message number
        call SVC_GETMSG          ; out: HL=staging buffer, BC=length
        ret c                    ; out of range: CF stays SET, so this
                                 ; EXTERN fails the entry
        ; copy the staged text into OUR bank, then arm last
        ret                      ; CF clear
    .notmine:
        or a                     ; CF clear: unrecognised fn, no failure
        ret

    int:
        ld a, (armed)
        or a
        ret z                    ; idle: one load-and-test, nothing else
        call SVC_BUSY
        bit 0, a
        ret nz                   ; clip playing: emit nothing, advance
                                 ; nothing, resume where it stopped
        ; emit one character at the live text width
        ret

    armed:   db 0
    text:    ds 256

        ENDMODULE

        IFNDEF XBN_MODULE
    xbn_end:
        SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
        XBN_SCRATCH_END
        ENDIF

Four things in that skeleton are the whole lesson: `.notmine` returns carry
clear so a foreign fn never fails an entry; the arm path disarms before it can
fail; `SVC_GETMSG`'s result is copied into the module's own bank before
anything else runs; and the hook is one load-and-test when idle.

## Registers on entry

`EXTERN p1 fn` reaches your `ext` label with:

| Register | Holds |
|----------|-------|
| A | first parameter (also in B) |
| B | first parameter |
| C | function code - your own dispatch selector |
| HL | address of the flag named by the first parameter (`flags + A`) |
| DE | address of the object entry named by the first parameter (`objTable + A*6`) |
| IX | flags base (`$A200`) |
| IY | undefined |

A `CALL` entry gets the same `IX`; A, B, C, HL and DE carry nothing, since a
`CALL` has no parameters. The `#int` hook gets `IX` and nothing else, and no
register survives from a previous frame.

Return with a plain `RET`. You may clobber A, BC, DE, HL, IX, IY and both
alternate register sets. The one exception is the carry flag, which is your
verdict on the calling entry. Keep stack use modest - your code runs on the
interpreter's own stack, and a couple of hundred bytes of headroom is a safe
budget.

## Function codes and flags

- **Use fn codes 16 and up.** In a Release build the interpreter reserves 3
  (`XMESSAGE`), 4 (`XPART`) and 7 (`XUNDONE`) and they never reach your code;
  a DEBUG build additionally reserves 6 and 8-14 for its own probes. Codes
  outside 3-15 behave identically in both builds.
- **Stay disjoint from the collection.** Function codes and flags are disjoint
  across every module in `externs\`, which is what lets any subset coexist in
  one binary. Check the table in `externs\README.md` before choosing, and
  treat flags 224-251 as the collection's reserved band.
- **One meaning per code.** Document every fn you publish as an ACTION (always
  carry clear) or a CONDITION (with the one thing carry set means).

## A publishable folder

Exactly four files, the shape every module in `externs\` has:

| File | Requirement |
|------|-------------|
| `<name>.asm` | One source file in the combinable shape above, assembling against `xbn.inc` and `xbnmod.inc` alone with the kit root on the include path. No other includes, no interpreter internals |
| `GAME.XBN` | The prebuilt binary, byte-identical to a fresh assembly of the source. Commit both together every time |
| `README.md` | What it does, the exact DSF lines that drive it, every fn code and flag it uses, anything it deliberately does not do. At least 400 characters, and it must mention `EXTERN` |
| `build.ps1` | The rebuild script. Copy one from a shipped module and change the file name |

A fifth file in the folder breaks the contract. If you want the module in the
shipped collection, the submission requirements and the automated audit that
checks them are in the NextDAAD repository's `CONTRIBUTING.md`.

Full detail: the manual's [Externs chapter](../../../../docs/externs.html#building-an-xbn)
and the [XBN format reference](../../../../docs/reference/xbn-format.html#header).
