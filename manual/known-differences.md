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

## Text and colour

### `INK`, `PAPER` and `BORDER` above 15 are a NextDAAD extension

jDAAD folds all three condacts modulo 16, so `INK 224` there behaves as
`INK 0`. This interpreter does not fold: 16 to 255 select the standard
Next colour of that number - see [Customising](customising.md) for what
the numbers mean. The extension is deliberate and one-way: a game that
stays inside 0-15 plays identically everywhere, but a game written to
use 16-255 will not look right under jDAAD, since jDAAD folds those
values down to a different colour rather than rejecting them.

Keep every `INK`, `PAPER` and `BORDER` value below 16 if the game needs
to look right on jDAAD too.

### `PAPER 8-15` used to fold to the dim hue; it renders bright now

Before this change, `PAPER` values 8 to 15 silently folded to their dim
equivalent, 0 to 7. They render bright now, which is closer to the
Spectrum's own `BRIGHT` semantics than the old fold. A game that used
those values expecting the dim result will look different here than it
did before.

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
