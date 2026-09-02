# The calling contract

## EXTERN is a condition

`EXTERN p1 fn` is a condition as well as an action. The carry flag your `ext`
label returns is the verdict on the entry that called it:

- **Carry CLEAR** - the entry continues past the `EXTERN` exactly as before.
- **Carry SET** - the calling entry FAILS. Processing falls to the next
  matching entry, the way a failed `AT` or `PRESENT` behaves.

One edge comes with failing an entry: the entry's done state is CLEARED, so an
`ISDONE` afterwards reads not-done even if an action earlier in the same entry
had already run. Put the `EXTERN` guard FIRST, before the actions that depend
on it, and that edge never shows.

## Every exit returns a deliberate carry

`or a` clears carry, `scf` sets it. Never let a carry left over from a `cp`,
an `sbc` or an `add` reach a `ret` - that is the commonest way an extern fails
an entry it never meant to touch.

An unrecognised fn code must return carry clear. In a combined binary every
module's `ext` sees every `EXTERN` call, so a module that returned an
incidental carry for a foreign fn would fail every other module's entries.
The shared `.notmine` exit is what keeps the collection composable:

    ext:
        ld a, c
        cp 20
        jp z, my_action
        cp 21
        jp z, my_condition
    .notmine:
        or a                ; not my fn: carry clear, the entry continues
        ret

    my_action:              ; an ACTION: always carry clear on the way out
        ; ...
        or a
        ret

    my_condition:           ; a CONDITION: carry set = "no", the entry fails
        ld a, (XBN_FLAGS + 100)
        cp 5
        jr c, .no
        or a
        ret
    .no:
        scf
        ret

## A condition worth copying

Use a condition for anything a built-in condition would be used for: a guard
("is the hint book present?"), a predicate query ("is there an object with
this noun?"), or a chance test that behaves like `CHANCE`:

    > LOOK _   EXTERN  77 21    ; passes about 30% of the time, like CHANCE 30
               MES     3        ; "You notice something."
               DONE
    > LOOK _   MES     4        ; the fallthrough entry
               DONE

Fn 21 is four instructions:

    call SVC_RANDOM             ; B still holds param1: SVC_RANDOM preserves BC
    cp b
    ccf
    ret

`cp` sets carry when the byte is below B, and `ccf` turns that into the
verdict - carry clear is a pass. 77 of the 256 possible bytes pass, about 30%,
which is what `CHANCE 30` does with the same stream. Note the inversion:
`cp`'s carry sense is the opposite of the verdict's.

## The result convention

Carry is the ONE failure channel, with one documented meaning per function.
Flags carry three things only:

- **values** - a count, a result, a found object number;
- **inputs** - parameters the game sets with `LET` before the call;
- **async state** - a completion or expiry the game polls across turns, since
  carry speaks only at the moment of `RET` (a fade's "done" has to live in a
  flag).

Do NOT invent status enumerations. A failure reason the game needs to
distinguish belongs to a separate guard function that answers it as a
condition, checked once up front. The collection modules follow this to the
letter and are the worked examples.

Document every published fn as ACTION or CONDITION, and for a condition state
the single thing carry set means.

## What never fails an entry

Three things return carry clear whatever your code does:

- an `EXTERN` with no `GAME.XBN` loaded - still a pure no-op, which is what
  keeps a database written against an extern shippable to a player who has
  none;
- the interpreter's reserved codes 3, 4 and 7 (and, in a DEBUG build, the
  probe codes 6 and 8-14), which never reach your code at all;
- `CALL`, which is a pure action with no return contract - the interpreter
  ignores your carry there, as it does for the `#int` hook.

## Parameters

`EXTERN` carries exactly two bytes: the first parameter (in A and B, with HL
and DE pre-resolved to that flag and that object entry) and the fn code in C.

This interpreter does NOT let an extern consume extra bytes inline from the
condact stream - there is no way to read "the next byte after this `EXTERN`"
the way some classic machines' externs could. Pass extra data through flags
instead: `LET` a value before the `EXTERN` call, or build a lookup table in
your XBN indexed by the fn code.

Reading and writing flags and object state needs no service - the interpreter
just exposes the memory. Flags 0-127 are `(ix+n)`; flags 128-255 need
`XBN_FLAGS+n`, because an `IX` displacement cannot express a value past 127.
The object table is six bytes per entry at `XBN_OBJTABLE`: `+0` location, `+1`
weight and attribute bits, `+2`/`+3` extended attributes in flag order (`+3`
holds bits 0-7, `+2` holds bits 8-15), `+4` noun, `+5` adjective. Walk objects
`0` to `(XBN_NUMOBJ) - 1` using the byte's value, never a fixed 256 - entries
past the count are stale.

## CALL

`CALL lsb msb` assembles a 16-bit address from its two arguments and runs the
code there IF the address falls inside your loaded binary's extent (`$C000` up
to but not including the end of the file). An address outside that range, or
no XBN loaded, is a safe no-op. It cannot reach anywhere else in the address
space.

In a combined binary, `CALL` targets are SLOTS in the fixed jump table at
`$C00E` that `XBN_BEGIN` emits - slot n at `$C00E + 3n`, so slot 0 is
`CALL 14 192`. There are eight, frozen and append-only. An unowned slot jumps
to a bare `RET` and does nothing, which is why a subset build that omits a
module leaves its slots harmless rather than dangerous.

Never publish a routine address as a `CALL` target: routine addresses move
whenever any module in the binary is edited.

Full detail: the manual's [EXTERN contract](../../../../docs/externs.html#the-extern-contract),
[Condition semantics](../../../../docs/externs.html#condition-semantics),
[The result convention](../../../../docs/externs.html#the-result-convention),
[CALL](../../../../docs/externs.html#call) and
[Flags and objects](../../../../docs/externs.html#flags-and-objects).
