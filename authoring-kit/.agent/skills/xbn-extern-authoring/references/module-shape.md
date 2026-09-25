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
    SCRATCH_SIZE equ 256        ; optional: scratch RAM at myext.SCRATCH
    STATE_SIZE   equ 4          ; optional: saved bytes at myext.STATE
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
        MODULE myext
        XBN_CLAIMS SCRATCH_SIZE, STATE_SIZE ; 0 for a size you did not declare
        ENDMODULE
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
- **Entry labels at column 0.** `ext`, `int`, and `line`/`out` for a
  hooked module, each at the start of its line inside the `MODULE`
  block, colon recommended. `EXTERNS.BAT` finds them by reading your
  source; an indented one is refused. They, and `SCRATCH_SIZE`/
  `STATE_SIZE`, go in the module's own `.asm`, never in an `INCLUDE`d
  file - the build refuses one it finds only in an included file.
- **Reserved names inside the module:** `ext`, `int`, `line`, `out`,
  `SCRATCH`, `STATE`, `SCRATCH_SIZE`, `STATE_SIZE`. A module handed to
  `EXTERNS.BAT` by path may not reuse the name of a folder in
  `externs\`.

### Scratch RAM claims

Bytes above `xbn_end` are inside the mapped 16K bank but outside the saved
image - RAM you do not pay for in file size. Scratch RAM is never
initialised for you: write before you read.

For a module of your own, declare the size inside your `MODULE` block and
use `SCRATCH` as the base:

    SCRATCH_SIZE equ 256
    ...
        ld hl, SCRATCH

`EXTERNS.BAT` places each declared claim after the collection's, in the
order you name the modules. It prints where each one landed
(`claim myext scratch +2816 (256), state +31 (0)`) and fails the build if
the claims run past the bank. A standalone build places it with
`XBN_CLAIMS` (skeleton above).

A module for the shipped collection claims a fixed offset instead.
`XBN_SCRATCH` only exists once `XBN_SCRATCH_END` has run, and in a
combined build that happens in the top-level source, so the claim goes in
a re-opened `MODULE` block after the closing bracket:

    ; Read buffer, 256 bytes, claimed from XBN_SCRATCH (see xbnmod.inc).
        MODULE myext
    rdbuf:   equ XBN_SCRATCH + 0
        ENDMODULE

Take your offset from `XBN_SCRATCH_FREE` in `xbnmod.inc`, add your claim to
the comment list kept beside it, and bump `XBN_SCRATCH_FREE` past your claim
so the next module does not collide. `XBN_SCRATCH_END` asserts that every
claim still fits inside the mapped bank.

### State area claims

`XBN_STATE` (`$BF80`, 128 bytes, `xbn.inc`) is the one piece of your module's
own memory that travels with the game's save data - `SAVE` writes it, `LOAD`
restores it, `RAMSAVE`/`RAMLOAD` carry it, zeroed only at boot.

A module of your own declares `STATE_SIZE` and uses `STATE`, placed the
same way as its scratch claim: after the collection's, in the order you
name the modules, asserted against `XBN_STATE_LEN`. That order is part of
your save format - adding, removing or reordering state-claiming modules
moves offsets, and a save made with the old binary restores bytes into the
wrong module. Settle the module list before release.

A module for the shipped collection chains a fixed offset off
`XBN_STATE_FREE` in `xbnmod.inc` instead: take the current value as your
offset, add a claim comment, bump the value past your claim.
`XBN_STATE_FREE <= XBN_STATE_LEN` is asserted.

    ; Claims: toolkit.asm pickPool 0 (1), pickUsed 1 (8), tgtWin 9 (1)
    ; Claims: playername.asm name 10 (21)
    XBN_STATE_FREE  equ 31

Membership rule: only state that must agree with the flags after a `LOAD`
belongs here - the same test a flag's own save/load behaviour gets. Session
configuration (armed/disarmed, colours chosen this session, a recorder's own
bookkeeping) stays ordinary bank memory; only what the player would notice
was wrong after loading an old save belongs in the state area. The toolkit's
claim above is the worked example: fn 76's picker pool and fn 84's print
target window are now restored by `LOAD` and `RAMLOAD`, where they used to
go stale.

## The ticker skeleton

`externs\ticker\ticker.asm` is the minimal working module, and its own
comments walk through every decision. The shipped module now carries fns
32-38 (position, colour, mode, speed) and two marquee modes on top of this
skeleton; the wrapper, the `MODULE ticker` shape, the disarm-first arm and
the idle hook below are unchanged. The skeleton, abridged:

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
        ; BC = 0 is a legal empty message - never LDIR it
        ; (see services.md, SVC_GETMSG)
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

## Hooked module

A module that reads or rewrites the player's line, or watches what the
interpreter prints, declares a format 3 header instead of format 2:
`XBN_HEADER3`/`XBN_BEGIN3` in place of `XBN_HEADER`/`XBN_BEGIN`, naming two
more entries (`0` for either you do not need):

    XBN_BEGIN3 myext.ext, myext.int, myext.line, myext.out

`line` gets HL = the typed line (resident, writable, ASCIIZ), B = its length,
IX = flags base, and returns a carry verdict: CLEAR continues to the echo and
parse (your rewrite included, if you changed the bytes at HL), SET consumes
the line silently (re-prompt, no parse, the turn counter does not advance).
`out` gets C = the character about to print (`$0D` = newline), IX = flags
base, and has no return contract - its carry is ignored. See
`references/calling-contract.md` for the full entry/exit rules for both.

In a combined binary there is one `lineEntry` and one `outEntry` in the
header; `xbnmod.inc` chains every hooked module's hook into it:

    all_line:
        XBN_LINE_ENTER
        XBN_LINE_CALL myext.line
        XBN_LINE_END
    all_out:
        XBN_OUT_CALL myext.out
        ret

`XBN_LINE_ENTER` stashes HL/B once; `XBN_LINE_CALL target` recomputes B from
the NUL before each module (a module ahead may have rewritten the line) and
`ret c`s the chain the moment a module consumes it - modules after that one
are skipped for that line. `XBN_LINE_END` is the chain's own `or a` / `ret`
when nobody consumed it. `XBN_OUT_CALL target` brackets the call with a
`push bc` / `pop bc` so C survives across every module in turn. Every module
in a collection still needs an `int` label even when it does nothing -
`int: ret` - because the chain macros and the subset builder call it
unconditionally.

`EXTERNS.BAT` builds those chains for you from the labels it finds: a
module with a `line` label joins the line chain, one with `out` the output
chain, and a hook no module has is `0` in the header - a binary with only a
line hook never pays for a per-character call.

### The transcript skeleton

`externs\transcript\transcript.asm` is the shipped hooked module, built
around a bank-scratch ring buffer (`TR_BUF`, sized `TRANSCRIPT_RING`) that
`line` and `out` both append into and `ext` fn 91/the line hook flush to
disk. Abridged:

    ext:
        ld a, c
        cp 90
        jr z, start              ; fn 90: arm, create/truncate TRANS.TXT,
        ...                      ; write the header line
        cp 91
        jr z, stop                ; fn 91: flush what is queued, disarm
        ...
        or a
        ret

    ; Line hook: queues ">>" + the line + CRLF, then flushes - the file on
    ; the card always ends with the command about to run. Never consumes.
    line:
        ld a, (armed)
        or a
        ret z
        ...append the line...
        call flush                ; failure disarms; the verdict stays clear
        or a
        ret

    ; Output tap: C = character. No service call here, ever.
    out:
        ld a, (armed)
        or a
        ret z
        ...gate on mode/window...
        ld a, c
        jp append_out             ; append_out caps at TR_OUTCAP, not TR_BUFSZ

    ; A -> TR_BUF[tlen], tlen++; one '~' sentinel at the cap, then drops.
    append:
        ...caps at TR_BUFSZ-1...
    append_out:
        ...caps at TR_OUTCAP-1...

    ; Opens RW, seeks to the running length, writes, checks the byte
    ; count, closes. One card round trip per recorded turn.
    flush:
        ...

    int:
        ret                       ; no frame work; the chain calls this anyway

Three things in that skeleton are the whole lesson beyond the ticker's:

- **`out` shares `append`'s body with `line` but through a lower cap.**
  `TR_OUTCAP equ TR_BUFSZ - (INP_MAX+5)` reserves enough room for the worst
  case line-hook marker (a 127-character line plus its wrapping) so a ring
  that fills from printed output still has room for the NEXT command line -
  the file may lose what a turn printed, never what the player typed next.
- **The output hook calls no service**, ever - it only appends a byte to the
  ring. All the file IO happens later, from the line hook.
- **`int: ret` is still required.** Even a module with nothing to do every
  frame defines the label, because the chain calls it unconditionally.

fn 90's mode bit 1 (`EXTERN 2 90` or `3 90`) skips the header's date stamp
entirely - `hdr_build` never calls `SVC_GETDATE` on that path, which is what
makes recording usable under an emulator that hangs on the call (see
`references/pitfalls.md`).

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

A `CALL` entry gets the same `IX`; A, B, C, HL and DE carry nothing
meaningful, since a `CALL` has no parameters. The `#int` hook gets `IX` and
nothing else, and no register survives from a previous frame.

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

A module for the shipped collection is exactly four files, the shape
every module in `externs\` has:

| File | Requirement |
|------|-------------|
| `<name>.asm` | One source file in the combinable shape above, assembling against `xbn.inc` and `xbnmod.inc` alone with the kit root on the include path. No other includes, no interpreter internals |
| `GAME.XBN` | The prebuilt binary, byte-identical to a fresh assembly of the source. Commit both together every time |
| `README.md` | What it does, the exact DSF lines that drive it, every fn code and flag it uses, anything it deliberately does not do. At least 400 characters, and it must mention `EXTERN` |
| `build.ps1` | The rebuild script. Copy one from a shipped module and change the file name |

A fifth file in the folder breaks the contract. If you want the module in the
shipped collection, the submission requirements and the automated audit that
checks them are in the NextDAAD repository's `CONTRIBUTING.md`.

A module for your own game has no such limit. It can `INCLUDE` files
beside it (a relative `INCLUDE` resolves from the module's own folder)
and live anywhere `EXTERNS.BAT` can be pointed at - see the manual's
[Your own modules in a subset](../../../../docs/externs.html#your-own-modules-in-a-subset).

Full detail: the manual's [Externs chapter](../../../../docs/externs.html#building-an-xbn)
and the [XBN format reference](../../../../docs/reference/xbn-format.html#header).
