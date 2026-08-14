# Known differences

**This page is meant to disappear.**

Everything on it is a place where NextDAAD does not yet do what a DAAD
author has the right to expect, and every entry is written to be
deleted: when the difference goes, so does its entry. Nothing here is a
decision we mean to keep.

That is what separates this page from [Platform notes](platform-notes.md),
which is the opposite list - behaviour that is settled, whether the
hardware forced it or we chose it, and that is not going to move. If
something surprises you, check there first; it is much the longer list.

Each entry below says what happens today and what to write instead. The
workarounds are all things that read correctly on every DAAD
interpreter, so a game written around them keeps working when the
difference is fixed.

## Locations

### `DESC 255` is an error, not "here"

`DESC 255` raises runtime error 1, "invalid location". Write `DESC @38`
instead - flag 38 holds the player's location - which is unambiguous
everywhere.

The wider problem is that 255 does not mean the same thing in every
condact. It is translated to the player's location in `PLACE`, `PUTO`
and `AUTOT` parameters, and it is not translated in `AUTOP` or `PUTIN`,
which hit the invalid-location error instead. Until that is even, use
255 only in the three condacts that accept it, and write `@38` anywhere
else you mean "here".

## Objects

### `CREATE`, `DESTROY` and `PLACE` do not set the referenced object

After any of the three, the referenced object - flag 51 and its
companions in flags 54 to 59 - still holds whatever it held before.

If you need the referenced object to follow the object you just moved,
say so explicitly with `SETCO n`. That works on every interpreter and
costs one condact.

### `COPYOO` adjusts flag 1

`COPYOO objno1 objno2` copies object 1's location to object 2, and flag
1 - the carried count - is adjusted to match: down if the move takes
object 2 out of the player's hands, up if it puts one into them.
`SWAP` behaves differently: it is a raw exchange of two locations and
never touches flag 1.

Interpreters disagree about this, so a game that reads flag 1
immediately after a `COPYOO` can see a different number elsewhere.
There is no condact that recounts the carried objects on demand -
`ABILITY` only sets the carry limits in flags 37 and 52, and the
condacts that do rebuild the count all restart the game. If the exact
number matters at that point, set flag 1 yourself rather than waiting
for a recount.

### `PUTIN` and `TAKEOUT` space their message differently elsewhere

The composite message these condacts print is SM44 (or SM45, or SM52),
then a space, then the container's name, then SM51 with no space before
it. With the stock SM51 of "." that gives

    The hat is in the old box.

Other interpreters put the spaces in different places, so a game whose
system messages were tuned against one of them can come out with a
doubled or a missing space here. Write SM44, SM45 and SM52 with no
trailing space of their own, and SM51 as the punctuation you want the
sentence to end on; that reads correctly on all of them.

## Flags

### Flag 50 does not survive a `PROCESS` call

Flag 50 holds the object a `DOALL` is currently working on, and it is a
plain global here. After `PROCESS n`, where process n ran a `DOALL` of
its own, flag 50 holds the last object that `DOALL` touched rather than
whatever you left in it. Some interpreters save and restore it around
the call.

Do not carry a value in flag 50 across a `PROCESS` call. Use one of the
general-purpose flags for anything you need to survive.

### Flag 55 is not set while a `DOALL` runs

The weight of the object a `DOALL` has just reached is not published
into flag 55. If you need it inside the loop, ask for it directly with
`WEIGH @50 n`.

## Externs

### EXTERN and CALL do not consume extra bytes from the condact stream

Some classic interpreters let an extern advance past its own condact and
read further bytes the compiler left sitting in the stream immediately
after it - an inline-parameter convention. This interpreter does not
support that: the condact stream position is private to the engine, and
an extern gets exactly the registers [Externs](externs.md) documents,
nothing more.

Pass extra data through a flag instead - `LET` it before the `EXTERN`
call - or build a lookup table inside your XBN indexed by the function
code. Either reads correctly regardless of which interpreter a database
targets, since neither relies on inline stream bytes existing at all.

### The object table an extern sees is not a flat locations array

An extern reads object state directly at `XBN_OBJTABLE`, and that table
is six bytes per object (location, weight/attribute bits, extended
attributes, noun and adjective vocabulary IDs), not the flat
one-byte-per-object locations array some classic externs assumed. `DE`
already points at the right object's entry base on entry to an `EXTERN`
call, so `ld a, (de)` reads its location without needing to know the
stride - but code ported from a classic extern that indexed a flat
array directly will read the wrong bytes if it is not adjusted.

### SFX cannot be overridden by author code

The `SFX` condact always drives this interpreter's own native audio
path - background music, AY effects and sampled sound. An extern cannot
intercept or replace it, unlike some classic implementations that let
author code take over sound entirely. There is no workaround; author
audio work belongs in the `#int` hook driving hardware directly (see
[Externs](externs.md#the-int-hook)) rather than through `SFX`.

### CALL only reaches addresses inside your own loaded XBN

`CALL lsb msb` only runs code that falls inside the extent of the
currently loaded `GAME.XBN` - it cannot jump anywhere else in the
address space the way a classic `CALL` into a flat memory map could.
An out-of-range address, or no XBN loaded at all, is a silent no-op.

### The #int hook is the 50Hz frame interrupt, and services do not run inside it

An extern's interrupt entry point runs once per frame, timed by the
interpreter's own vertical-blank interrupt - there is no author-selectable
interrupt source or rate. None of the ten [services](externs.md#services)
may be called from inside it; every one of them is foreground-only
(`EXTERN`/`CALL` context) and will misbehave if called from `#int`. Do
any file IO, printing or random-number work the hook needs from a
foreground `EXTERN` call instead, staging the result somewhere the hook
can read without calling a service itself.

## Spanish databases

Two pieces of Spanish support are missing. Only Spanish databases are
affected; an English game sees none of this.

### Articles are not replaced in a substituted name

Substituting an object name into a message leaves a Spanish article as
the author wrote it - "Un palo" substitutes as "Un palo". Other
interpreters replace it with the definite form, giving "El palo".

For now, write the `/OTX` text so that it reads correctly unchanged in
the messages that use it, or supply your own wording in the message
rather than relying on the substitution to adjust the article.

### Enclitic pronouns are not implemented

Verbs ending -LO, -LA, -LOS or -LAS do not inject a pronoun token, so a
player typing `COGELO` does not get the "it" the verb is carrying. Flag
53 bit 2, the V3 bit that suppresses enclitics, consequently has nothing
to suppress.

Ask for the pronoun as a separate word in your vocabulary until this
lands.
