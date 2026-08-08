# Multi-part games

A game can ship as several separate DDBs - "parts" - that switch between
each other at runtime with `EXTERN n 4` (MALUVA's `XPART n`). The two
usual reasons are a game too large for one DDB's
[31744-byte ceiling](reference/limits.md), and a natural chapter or
episode structure.

This is entirely optional. A single-part game, which is what the kit
builds by default, never touches any of the machinery below.

## Laying the parts out

- **Part 1 is your main `.DSF`** in the kit folder, built exactly as it
  always was and staged as `GAME.DDB` at the SD root. Nothing about a
  single-part build changes.
- **Parts 2 to 9** - the supported range - each get a `PART<n>\` folder
  in the kit directory, holding exactly one `.DSF` (auto-detected the
  same way as the main game) plus that part's own already-converted art
  and audio, if any.
- `BUILD.BAT` compiles each `PART<n>\` DSF the same way as the main game
  and stages the result as `RELEASE\GAME<n>.DDB` and
  `RELEASE\PART<n>\0.XMB` if that part uses XMESSAGE or XMES. It then
  copies every other file from `PART<n>\` into `RELEASE\PART<n>\`
  untouched.
- On the SD card that becomes `GAME.DDB`, `GAME2.DDB`, `GAME3.DDB` and
  so on at the root, alongside `PART2\`, `PART3\` folders holding each
  part's own shadowed assets.

**Part folders take converted files, not sources.** Put ready-to-use
`.NX2`, `.NXI`, `.AKY`, `.AYS`, `.WAV`, `.VID`, `GAME.SFB`, `FONT.CHR`
to `FONT9.CHR` and `POINTER.SPR` to `POINTER9.SPR` files in a `PART<n>\`
folder - not `.png` or `.aks` sources. Only the main kit folder's `IMAGES\` and `AUDIO\` are
converted.

A part switch opens its target by the exact name `GAMEn.DDB`, so a stray
file beside it - a `GAMEn.DSF` source left next to the compiled DDB, say
- is ignored and harmless.

## Switching parts

- `EXTERN n 4` (`XPART n` under MALUVA) switches the running game to
  part `n`, 1 to 9. It loads `GAMEn.DDB` (`GAME.DDB` for part 1) from
  the SD root.
- **If that file is not there, the switch is a silent no-op.** The game
  keeps running in the current part, unaffected. A game that ships an
  `EXTERN n 4` trigger must also ship that part's DDB, or the trigger
  quietly does nothing.
- A successful switch is a **fresh entry** into the new part, not a
  resume. It starts at the new part's own `PRO 0`, never at wherever the
  `EXTERN` was called from.

## Shadowed assets

For a part of 2 or above, these asset kinds are looked for in
`PART<n>\<name>` **first**, and fall back to the game root if they are
not there:

- location art (the whole extension probe runs under `PART<n>\`, then
  again at the root if that whole pass misses) - see
  [Graphics](graphics.md)
- `NNN.WAV` samples, and numbered `NNN.AYS` / `NNN.AKY` songs, and
  `GAME.SFB` - see [Audio](audio.md)
- `NNN.VID` videos - see [Video](video.md)
- `0.XMB` external message text
- `FONT.CHR`, and numbered `FONT1.CHR` to `FONT9.CHR`, and
  `POINTER.SPR`, and numbered `POINTER1.SPR` to `POINTER9.SPR` - see
  [Customising](customising.md)

**Root-only, never shadowed:** the title screen (`DAAD.*`, shown once at
cold boot), and the boot-autoplay default song (`GAME.AYS` /
`GAME.AKY`). The music sub-commands' `n=255` sentinel - the "play
`GAME.AYS`/`GAME.AKY`" case, see [Symbols](reference/symbols.md) - is
also always root-only and behaves identically from every part. `SFX 255
6` or `SFX 255 7` plays the game's theme from anywhere. That is by
design, not an override that failed.

Part 1 never looks in `PART<n>\` at all, so a part-1-only game is
byte-identical to a plain single-part build.

## What carries across a switch, what does not

- **All 256 flags carry verbatim.** Score, turns, and every other system
  or user flag survive a switch unchanged (caveat 6).
- **Object locations carry by index**, for as many objects as both parts
  define in common (caveats 1, 2, 4).
- **Object attributes and descriptions do not carry.** Weight,
  container and wearable bits, extended attributes, and text always come
  from the currently active part's own DDB (caveat 3).
- **Vocabulary is per-part and entirely independent.** A word's
  spelling, its ID, and whether it exists at all can differ freely
  between parts. Only OBJECT NUMBERS need a shared convention across
  parts (caveat 1); vocabulary needs none.

## Save, load and RAMSAVE across parts

SAVE always records the current part number in the file, and LOAD reads
it back and switches automatically if it differs from the running part.
A cross-part LOAD is a part entry, exactly like `EXTERN n 4`, not a
resume (caveat 7). Save files share one filename namespace in the game
root regardless of part (caveat 9) - SAVE and LOAD never look inside
`PART<n>\`.

**Only distribute save files your own build wrote, and do not hand-edit
them.** Save files are length-detected, and a malformed or hand-edited
file can be misclassified. The outcome is always bounded to a wrong-part
restore or a clean rejection, never file corruption, but it is a
pointless class of bug to invite.

RAMSAVE and RAMLOAD (caveat 8) use one buffer that also survives a
switch, so a RAMLOAD taken two parts later still restores to wherever
the RAMSAVE was last taken - the "died, try again" checkpoint feature. A
cross-part RAMLOAD is always a full restore: it ignores RAMLOAD's
"restore up to flagno" partial-restore argument, which only applies
within the same part. Refresh RAMSAVE in the new part's `PRO 0` after a
switch if you want the checkpoint to track it.

## Author caveats

1. **OBJECT NUMBERING IS YOUR CONTRACT.** The carry copies object
   locations BY INDEX. Object 7 in part 1 must mean the same thing as
   object 7 in part 2, or a carried lamp becomes whatever part 2 defined
   at that index. Keep a shared object-numbering map across parts, and
   define cross-part objects at the same indexes in every part.
2. **THE WHOLE TABLE CARRIES, NOT JUST THE INVENTORY.** Objects left in
   part-1 rooms arrive in part 2 holding part-1 location NUMBERS, which
   now name different rooms, or nothing. If only carried and worn
   objects matter across a boundary, have the new part's `PRO 0` re-PLACE
   or ABSENT everything else - the classic housekeeping idiom.
3. **Attributes are per-part.** Weight, container and wearable bits, and
   descriptions come from the ACTIVE part's DDB, so a carried object
   weighs what part 2 says it weighs.
4. **Object counts may differ.** Objects the new part defines beyond the
   old part's count start at the new part's compiled initial locations.
5. **Inventory limits are per-part (CTL).** Arriving with more carried
   objects than the new part's limit is stable until the next GET.
   Authors who lower the limit should handle the overflow in `PRO 0`.
6. **ALL 256 FLAGS CARRY - there is no clean slate.** A part that
   assumes its scratch flags start at zero must zero them in `PRO 0`, or
   the previous part must clear them before switching. System flags carry
   too: score and turns carry naturally, and the location flag holds a
   part-1 room number until `PRO 0` places the player. Always set the
   start location first.
7. **SAVE and LOAD.** A save records flags, objects and part; loading it
   from ANY part lands in the SAVED part, and every caveat above applies
   to the restored state exactly as it does to a live switch. A
   cross-part LOAD enters the saved part at `PRO 0` rather than resuming
   mid-turn; a same-part LOAD behaves as classic DAAD.
8. **RAMSAVE is ONE SLOT and survives switches.** A RAMLOAD two parts
   later restores to wherever the RAMSAVE was taken. That is the
   death-retry feature - but a stale slot restores a stale part, so
   authors using RAMSAVE for checkpoints should refresh it after each
   switch, with a RAMSAVE in `PRO 0`.
9. **Save files share one namespace** in the game root regardless of
   part; identical names overwrite across parts.

## Compiling every part the same way

Every part of a multi-part game must be compiled in the same DAAD
dialect, because a part switch reloads a header while the flags carry
across. If you change the compiler version away from the kit default,
change it for the main game and for the `PART<n>\` folders together -
both sites or neither. See [DAAD V3](daad-v3.md).
