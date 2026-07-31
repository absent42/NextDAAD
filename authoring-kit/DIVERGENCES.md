# NextDAAD deliberate divergences - notes for authors

NextDAAD aims to run a DAAD database exactly as the reference DAAD
interpreters do. Where it deliberately does something different, or
where the reference interpreters disagree with each other and NextDAAD
has had to pick a side, it is written down here.

Everything on this page is a decision, not a defect. None of it is
scheduled to be "fixed" - if a game behaves differently on NextDAAD
than on another DAAD interpreter, this is the first place to look
before assuming a bug. Genuine faults belong in the project's own
issue register instead.

Each item says what the references do, what NextDAAD does, and what it
means for your DSF. For the rest of the kit's authoring guidance see
`SETUP.md` section 8.

Reference names used below:

- **manual** - the DAAD manual (1991) and the DAAD Ready documentation.
- **msx2daad** - the MSX2 DAAD interpreter (full C source).
- **jDAAD** - the DAAD Ready HTML interpreter.
- **the original** - the ZX Spectrum 48K DAAD interpreter, the lineage
  NextDAAD reimplements. Where it has been measured directly, that is
  said.

---

## 1. Timing

### PAUSE and BEEP durations are pre-scaled by the compiler

DRC multiplies every PAUSE and BEEP duration by
`base length / 200`. For the `zx next` target the base length is 120,
so the factor is 0.6: `PAUSE 100` in your DSF compiles to `PAUSE 60`,
and `BEEP 50 120` compiles with a duration of 30.

NextDAAD waits the number of frames the compiled database asks for, at
50 Hz, which is the DAAD-documented unit. It does **not** scale the
value back up. Consequence: an authored one-second pause lasts about
0.6 seconds.

This is left alone deliberately. The scaling exists to match the tick
of the official `DSNEXTE3.BIN` ZX Next interpreter, and that
interpreter's actual tick has not been measured here, so "correcting"
it could just as easily introduce the error as remove it. Undoing the
scaling in the interpreter would also break bit-compatibility with
every other database compiled by the same toolchain.

What to do: author your pauses against what you hear, not against the
arithmetic. One second is `PAUSE 83` on this target - 83 x 0.6 = 50
compiled frames at 50 Hz. `PAUSE 167` gives about two seconds.

---

## 2. Condacts

### ISDONE / ISNDONE look at the last sub-process only

NextDAAD's ISDONE succeeds if the last table that ENDED did so after
executing at least one action - it reads the result of the most
recently popped process. Both msx2daad and jDAAD instead keep a single
"done" flag that any action condact in the current table also sets, so
their ISDONE is true if anything at all has happened since the table
was entered.

The manual's wording ("Succeeds if the last table ended by exiting
after executing at least one Action") supports NextDAAD's reading, and
in the normal idiom

    PROCESS 5
    ISDONE ...

the two are identical. They differ only if you use ISDONE with no
preceding PROCESS in the same table. Write the PROCESS.

### DISPLAY on a tilemap-text platform

- `DISPLAY n` with a non-zero value clears the Layer 2 picture surface
  and flips. msx2daad performs a CLS of the current TEXT window there;
  jDAAD ignores the value entirely. On NextDAAD text lives on the
  tilemap and pictures live on Layer 2, so a text CLS in a picture
  condact would be wrong. The DAAD idiom `DISPLAY @0` ("clear when
  dark") therefore behaves differently here - use `CLS` for text.
- `DISPLAY 0` always re-blits. msx2daad remembers the last picture per
  window and makes a re-stage of the same picture a no-op; NextDAAD has
  no equivalent, so a re-DISPLAY costs a redraw. Harmless, but do not
  rely on it being free inside a tight loop.

### A DOALL inside a DOALL raises runtime error 4

DOALL state on NextDAAD is one global set, not one per process-stack
level, so a sub-process called from inside a DOALL cannot start its own
DOALL - it stops with runtime error 4. jDAAD behaves the same way by
default (`NESTED_DOALL_ENABLED = false`); msx2daad supports nesting.

Do not nest DOALL loops. This is a loud failure rather than a silent
wrong answer, which is the point.

### DESC 255 is an error, not "the player's location"

`DESC 255` raises runtime error 1 ("invalid location") on NextDAAD, as
it does on msx2daad. jDAAD treats 255 as the player's location. Write
`DESC @38` (flag 38 is the player's location) if that is what you
meant.

Note that `PLACE`, `PUTO` and `AUTOT` parameters DO treat 255 as
"here", matching jDAAD - the 255 convention is not uniform across DAAD
condacts in any interpreter, and it is not uniform inside NextDAAD
either: `AUTOP` and `PUTIN` do not translate it, and hit the
invalid-location error instead.

### GFX subs 9 and 10 are no-ops

Both references implement the numbered palette store (9) and recall
(10) through a four-flag block. On NextDAAD the Layer 2 palette is
picture-driven - each picture carries its own embedded palette - so
there is nothing for a numbered palette slot to hold. Both subs are
accepted and do nothing.

### CREATE / DESTROY / PLACE do not set the referenced object

msx2daad sets the referenced object (flags 51, 54-59) in all three;
jDAAD routes all three through its PLACE and does not. NextDAAD follows
jDAAD. The manual is silent.

If you need the referenced object set after moving an object about,
issue an explicit `SETCO n`.

### COPYOO adjusts flag 1

`COPYOO objno1 objno2` copies object 1's location to object 2. jDAAD
routes this through its PLACE, so flag 1 (the carried count) is
adjusted when the object was being carried; msx2daad writes the
location raw and never touches flag 1. NextDAAD follows jDAAD, and also
sets the referenced object to objno 2 as the manual requires of both
COPYOO and SWAP.

`SWAP` by contrast is a raw exchange and does **not** adjust flag 1 -
the manual says so explicitly for SWAP and says nothing for COPYOO.

Status: the COPYOO half of this is awaiting owner ratification and may
change to msx2daad's raw form. If your game depends on flag 1 after a
COPYOO of a carried object, recount with `ABILITY` or avoid the case.

### PUTIN and TAKEOUT message spacing

The composite message these condacts print is SM44 (or SM45 / SM52),
then a space, then the container's name, then a space, then SM51.
msx2daad emits both spaces; jDAAD omits the trailing one; the manual
lists the three parts and mentions no spaces at all. NextDAAD follows
msx2daad.

With a typical SM51 of "." that renders as `The hat is in the old box .`
- the trailing space before the stop is visible. Author around it by
giving SM44/SM45/SM51/SM52 texts that read correctly with a space
between them, or by using your own message.

Status: awaiting owner ratification; it is a one-line change to jDAAD's
form if that is preferred.

### MOUSE sub-commands 6 and 7 are not movement deltas

Despite the DAAD symbol names `DELTAXMS` and `DELTAYMS`, these set the
HOTSPOT offset inside the pointer bitmap (the DRC manual: "originally
the hotspot in the pointer is at x=0, y=0 ... if the pointer is a
cross, you may want to put it at 5,5"). They do not report movement.
Subs 4-7 are implemented on this target - see `SETUP.md` section 8 for
the full table.

---

## 3. Text and messages

### The `@` escape, and capitalisation

Both `_` and `@` substitute the referenced object's name into a
message, in every language. msx2daad does the same; jDAAD honours `@`
only for Spanish databases. NextDAAD matches the majority, so an
English message containing a literal `@` will lose it - write your `@`
signs as something else, or accept the substitution.

The difference between the two escapes is capitalisation: `@` is meant
to capitalise the substituted name. That is now gated on the database
language and fires for **Spanish databases only**, matching jDAAD's own
gate and msx2daad's `LANG_ES` build. In an English database `@` and `_`
render identically.

### Article stripping in substituted names

When an object's text is substituted into a message, the first word of
that text is stripped, whatever it is. jDAAD does the same for English
("we have to remove the first word, whatever it is"); msx2daad strips
only a leading "a " or "an ". NextDAAD matches jDAAD.

So an object text of "a rusty sword" substitutes as "rusty sword", and
a text of "rusty sword" substitutes as "sword". Write your `/OTX`
entries with a leading article.

Plain LISTOBJ / LISTAT output is NOT article-stripped and NOT truncated
- the object text is listed whole. Only substitution into a message
strips and truncates.

### Substituted names stop at the first "."

A substituted object name is truncated at the first full stop, matching
both references. An object text of "a quaint lamp. It is unlit." reads
as "quaint lamp" inside a message, and prints whole in a listing. This
lets one `/OTX` entry serve as both a short name and a longer
description.

---

## 4. Parser

### A bare noun with vocabulary id below 40 acts as a verb

If the player types a noun on its own and no verb was given, DAAD
converts the noun into the verb slot when its vocabulary id is below
40. This threshold was measured directly on the original ZX
interpreter: ids 19, 20, 25 and 39 convert, ids 40 and 60 do not.
msx2daad uses 20 and is the deviation; jDAAD's 39 (that is, "below 40")
is right.

Consequence for authors: any noun you number in the 20-39 band will act
as a command when typed bare. If you have a noun that must never be a
verb, number it 40 or above. Direction words and similar
"typed on their own" nouns belong below 40.

### PARSE 1 and quoted text

`PARSE 1` re-parses the quoted section of the last order. NextDAAD
implements the rule measured on the original interpreter, which no
single reference gets right:

- Whether a quoted section EXISTS decides whether the sentence flags
  are refilled. `SAY HELLO` (no quotes) leaves the current sentence
  untouched. `SAY ""` (empty quotes) clears it.
- What the quoted section CONTAINS decides the condition, by the same
  "a verb or a noun was found" test PARSE 0 uses. So `SAY "PLUGH"`
  fails the condition (it filled a verb), `SAY "FAST"` passes (an
  adverb alone is not a sentence), and `SAY "ZZZZ"` passes.

Words after the closing quote still parse into the normal sentence
(msx2daad's model); jDAAD throws the tail away.

Convertible nouns are converted inside a quoted section too. jDAAD
suppresses that; the original does not, and neither does NextDAAD.

### Spanish enclitic pronouns are not implemented

Verbs ending -LO / -LA / -LOS / -LAS do not inject a pronoun token, and
flag 53 bit 2 (the V3 "suppress enclitics" bit) has nothing to
suppress. Both references implement this. Only Spanish databases are
affected. Deferred, not refused.

---

## 5. Flags

### Flags 37 and 52 start at 4 and 10

The manual gives 4 objects carried and strength 10 as the initial
values, and NextDAAD sets them at initialisation. Neither reference
does - both leave 0 until the game issues `ABILITY`.

Practical effect: a game that forgets `ABILITY` can carry four objects
on NextDAAD and none on the references. Issue `ABILITY` explicitly in
your initialisation process so your game behaves the same everywhere.

### Flag 50 (the DOALL object) is global

jDAAD saves and restores flag 50 across every process-stack push and
pop, so a DOALL inside a sub-process leaves the caller's value intact
when it returns. msx2daad keeps it as a plain global, and so does
NextDAAD.

Consequence: after `PROCESS n` where process n ran a DOALL, flag 50
holds the last object that DOALL touched on NextDAAD and msx2daad, and
the pre-call value on jDAAD. Do not carry a value in flag 50 across a
PROCESS call.

Status: owner ruling pending on whether to adopt jDAAD's per-level
behaviour.

### Flags 29 and 62 report this machine's capabilities

- **Flag 29** (graphics flags) reads 129: bit 7 because Layer 2
  location graphics exist, bit 0 because the MOUSE condact is
  implemented. `HASAT GMODE` is therefore TRUE on NextDAAD, so a
  period game that gates its picture drawing on `HASAT GMODE` draws
  pictures here. Bit 0 is set whether or not a mouse is physically
  attached, which is what jDAAD does too.
- **Flag 62** (screen mode) reads 144: bit 7 for "a graphics-capable
  mode", bit 4 for "a native machine mode that is not one of the
  original ST or PC values" (msx2daad's convention). jDAAD hardcodes
  142. The byte is machine-specific by definition; do not branch on its
  exact value.

Both are written once at initialisation and are not re-published when a
game switches Layer 2 mode. Both references are equally static.

### Flag 55 after a DOALL

jDAAD publishes the found object's weight into flag 55 as part of
setting the referenced object during DOALL iteration; NextDAAD does
not. If you need the current DOALL object's weight, `WEIGH @50 n` it.

---

## 6. DAAD V3

NextDAAD loads both version 2 and version 3 databases.

**The kit compiles version 3 by default.** `BUILD.BAT` passes `-v3` to
DRF, the same as DAAD Ready's own `ZXNEXT.BAT`, so a DSF authored
anywhere else in the DAAD ecosystem for this target builds here in the
dialect its author compiled against. If you are bringing an existing
version 2 game to the kit, read "Moving your game to V3" at the end of
this section first - three things change silently.

To compile version 2 instead, remove `-v3` from the DRF line in
`lib\ddb.bat`, and from the matching line in `BUILD.BAT` if your game
has `PART<n>\` folders. Both sites or neither: every part of a
multi-part game must be the same dialect, because a part switch
reloads a header while the flags carry across.

### Version 2 databases still reject the V3 opcodes

Opcodes 120 (XMES), 122 (INDIR) and 124 (SETAT) raise runtime error 5
in a version 2 database, as they always have and as both references
do. They are live only when the database header says version 3. DRC
cannot emit them into a version 2 database in the first place, so this
is unreachable from normal authoring.

### HASAT honours the V3 alternative attribute bank

Under V3, flag 53 bit 1 moves the attribute flag bank from 59 to 91.
NextDAAD honours that in HASAT, HASNAT and SETAT alike. jDAAD's SETAT
honours it but its HASAT does not, so a database that SETATs into the
alternative bank cannot read it back with HASAT there - a jDAAD
omission, followed by nobody else.

The bank switch is gated on the database being version 3. PCDAAD
applies it to any version; msx2daad and the executable V3 test suite
gate it, and so does NextDAAD, because a version 2 game is entitled to
use flag 53 bit 1 as scratch.

### SYNONYM marks DONE under V2 and not under V3

That split is the DAAD platform table's: the Z80 and 6502 interpreters
mark, the 68000 sources do not. NextDAAD is a Z80 interpreter and
marks. jDAAD never marks, in either version.

### Moving your game to V3

A game written before the kit defaulted to `-v3` needs three checks.
None of them produces a compile error - the game builds and runs, and
misbehaves quietly - so grep for all three before you trust a V3 build
of an existing game. The starter game bundled with the kit passes all
three, and compiles byte-identically in both dialects apart from the
version byte in its header.

1. **`SYNONYM` stops marking the entry DONE.** Grep: `SYNONYM`. If any
   of them is followed by an `ISDONE` that expects the synonym itself
   to have counted as an action, that entry stops firing. Nothing
   errors; the entry just stops behaving. This is the one real
   migration hazard - it is silent and it is a logic change.
2. **`PAUSE 0` stops meaning "wait 256 frames".** Grep: `PAUSE 0`.
   Under V3 it is GETKEY - the game waits for a keypress instead of
   about five seconds. Replace it with `PAUSE 255` (or whatever
   duration you meant) if you wanted the wait.
3. **`HASAT` / `HASNAT` / `SETAT` start honouring flag 53 bit 1.**
   Grep: any write to flag 53 - `LET 53`, `SET 53`, `PLUS 53`,
   `COPYFF`/`COPYBF` with 53 as the destination. Under V3, bit 1 moves
   the attribute bank from flag 59 to flag 91, so a game using flag
   53's low bits as scratch will find its attribute reads looking
   somewhere else entirely. Note that under V3 the interpreter itself
   also writes bits 0, 4 and 5 of flag 53, which it does not touch
   under V2 - so a game that reads flag 53 as a whole value (`EQ 53 n`
   rather than `HASAT`) will see different numbers even if it never
   writes the flag.

What you gain by staying on V3: second-parameter indirection
(`LET 100 @101`), the `GETKEY` keyword, XMES as a native 3-byte opcode
instead of a 4-byte `EXTERN` call with no MALUVA vector involved, the
V3 flag 53 bits the DAAD Ready template already documents, and a kit
that matches the rest of the DAAD ecosystem for this target.

Note that the bundled DRF 0.40 has no `SETAT` keyword at all, so
opcode 124 is unreachable from DSF source whichever version you
compile - the interpreter implements it for databases built by other
means.

---

## 7. Reference-interpreter defects

Recorded so that a difference against one particular reference is not
mistaken for a NextDAAD fault. Each was verified in that reference's
own source during the SP16 compliance sweep.

| Reference | Defect |
| --------- | ------ |
| jDAAD | TAKEOUT of an object lying at the player's location prints SM49 where its own comment, the manual and msx2daad all say SM45. |
| jDAAD | HASAT ignores the V3 alternative attribute bank while its own SETAT honours it. |
| jDAAD | Convertible nouns are suppressed inside a PARSE 1 quoted section. The original converts them. |
| jDAAD | END compares against SM30 and inverts the outcome; the manual and msx2daad use SM31. |
| jDAAD | AUTOG searches here, worn, carried; the manual and msx2daad search here, carried, worn. |
| jDAAD | CHANCE uses `floor(random*101) <= p`, a 101-value off-by-one. |
| jDAAD | RAMLOAD restores flags 0..n-1 where the manual says 0..n inclusive. |
| jDAAD | BEEP accepts tones 24..238 against a 100-entry period table, reading past the end of its own array. |
| msx2daad | The convertible-noun threshold is 20; the original's is 40. |
| msx2daad | A sentence containing nothing but a pronoun counts as parsed. |

---

## 8. Where this comes from

The full evidence for every item above is the SP16 compliance sweep
(2026-07-27 to 2026-07-31): a static comparison of NextDAAD against
msx2daad, jDAAD and the DRC compiler, plus three questions settled by
scripted measurement of the original ZX 48K interpreter (the
convertible-noun threshold, the QUIT/END confirmation input model, and
the PARSE 1 rule).
