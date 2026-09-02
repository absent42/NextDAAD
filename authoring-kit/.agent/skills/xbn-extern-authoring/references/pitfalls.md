# Pitfalls

Twelve mistakes that have already cost someone a debugging session. Each is
the lesson and the rule it produced.

## halt is not a frame

**Lesson.** A wait that counted `halt` returns ran up to 312 times fast the
moment a sampled sound effect was playing. The mechanism is in the manual's
[#int hook section](../../../../docs/externs.html#the-int-hook) - read it
there rather than guessing at it.

**Rule.** A wait that needs frames gates on `SVC_FRAMES`: snapshot the
counter, `halt` as a wakeup ONLY, and step your count on a change in the
counter, never on the wakeup itself.

## Every hook wait needs a bound

**Lesson.** A foreground wait that spins until the hook says it is finished
hangs the game forever if the hook never runs.

**Rule.** Carry a maximum frame count in a register pair, decrement it on
every frame edge, and return when it is spent. A bounded wait that gives up
early is a visible glitch; an unbounded one is a dead machine.

## The flush trap and the print target

**Lesson.** `MES "Score "` followed by an extern that prints a number into a
status window put "Score" in the game window and the number in the status
window, rather than side by side, because selecting a window flushes the
pending word of the window you are LEAVING - and that flush can raise the More
prompt there.

**Rule.** Do not mix `MES` text and extern output on one line across a window
switch. Either print both through the same window, or clear the print target
first (the toolkit's `EXTERN 0 84`). And a number printed as the last thing in
an entry stays in the word wrapper until a space, a newline or a window switch
flushes it, so end the line deliberately.

## CF discipline

**Lesson.** `cp`'s carry sense is the opposite of the verdict's, and `sbc` and
`add` leave a carry too. An incidental carry reaching a `ret` fails an entry
nobody meant to fail - and in a combined binary, fails every other module's
entries as well.

**Rule.** Every exit sets carry deliberately: `or a` for an action, `scf` for
a condition's "no". Unrecognised fn codes fall to a shared `.notmine: or a /
ret`. Audit every `ret c` and every `ret` that follows arithmetic.

## Leg scoping

**Lesson.** A test that only ever takes one branch proves half the contract. A
condition the test cannot make fail proves nothing at all, and a flag that
already held the value you expected proves nothing either.

**Rule.** For every function, write two DSF entries: one where it passes and
one where it fails, and check the failing one really does fall through to the
next matching entry. Poison the flag (`LET n 255`) before the call that is
meant to write it. End each pass-path entry with `DONE`, so a fallthrough
proves failure rather than ordering.

## fn and flag disjointness

**Lesson.** In a combined binary every module's `ext` sees every `EXTERN`
call, and every module's flags live in the same 256 bytes. Two modules
claiming the same fn code, or the same flag, break each other silently.

**Rule.** Check the collection table in `externs\README.md` before choosing
anything. Use fn codes 16 and up. Treat flags 224-251 as the collection's
reserved band and 0-63 as the interpreter's.

## The tilemap during video clips

**Lesson.** A hook writing the tilemap during a video clip with an audio track
corrupted the clip's sound, because the interpreter borrows that same window
as the clip's audio feed for the clip's whole duration - and the hook keeps
firing throughout.

**Rule.** Call `SVC_BUSY` at the top of any hook that writes the tilemap and
skip the frame while bit 0 is set. Emit nothing and advance nothing, so your
output resumes where it stopped rather than losing characters.

## Rows 4-27

**Lesson.** The tilemap's origin sits 32 pixels above and left of the ULA
origin, so of its 32 rows, 0-3 and 28-31 land in the border area. Real display
chains crop border pixels: content parked there can be invisible on hardware
while an emulator window shows it perfectly.

**Rule.** Anything that must be visible on every display stays in rows 4-27.
If you want a border row, verify it on your own target display first.

## The width switch

**Lesson.** A game can switch between 80x32 and 40x32 text at any time with
`GFX n 18`. Code that cached the row stride wrote past the end of the row
after the switch.

**Rule.** The width is not part of the frozen ABI. Ask the hardware each time
through `xbnmod.inc`'s `xbn_width` (hook-safe: width in E, stride in D,
bottom-row base in HL), and handle a width that SHRANK mid-output rather than
assuming your column is still in range.

## The register-select bracket

**Lesson.** The interpreter's own foreground code drives the palette and other
hardware through the same indexed register interface your hook does, and the
hook can fire in the middle of anything.

**Rule.** Save and restore any shared indexed hardware register interface you
touch - the select latch and the control register - around every burst, so a
foreground sequence your hook landed in the middle of resumes unharmed. The
fade module's bracket is the worked pattern.

## Emulators are not the finish line

**Lesson.** Emulators may not expose a real-time clock or persist card writes
faithfully - test `SVC_GETDATE` and any file-writing function on hardware.

**Rule.** Anything that reads the clock or writes a file on the card gets a
run on a real machine before you publish it. Write the no-clock path as the
normal case, not as an error: carry set from `SVC_GETDATE` means BC and DE are
zero and HL is UNDEFINED.

## A v1 binary is rejected silently

**Lesson.** The header changed at format 2, and a version 1 binary is rejected
by this interpreter. In a Release build that rejection is SILENT: the game
plays exactly as it would with no `GAME.XBN` at all, so an extern that "does
nothing" looks like a bug in your code rather than a stale binary.

**Rule.** Reassemble against the current `xbn.inc` after any interpreter
update, and make a stale binary your first suspicion when nothing happens. The
loader's full check order - size, magic, version, the four reserved bytes,
the size field against the real file length, and both entry points inside the
extent - is in the
[format reference](../../../../docs/reference/xbn-format.html#validation).
