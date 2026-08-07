# Symbols

## Appendix D symbol names (SFX and MOUSE)

DAAD Ready's Appendix D lists symbolic names for the sub-command
argument of `SFX` and `MOUSE` (`PLAYSFX`, `SHOWMS`, and so on). The
bundled DRF compiler predefines every one of them, and a DSF written
with the symbolic form compiles byte-identical to the same DSF written
with the raw number - use whichever reads better. Confirmed by
compiling a test suite both ways and comparing the resulting DDBs
byte-for-byte.

**Typo warning:** the DAAD Ready manual's own Appendix D table names
value 10 `FPLAYFLIL`. That is a documentation typo - `FPLAYFLIL` does
not compile. The compiler defines `PLAYFLI` (9) and `PLAYFLIL` (10).

## SFX sub-commands

| n | Symbol | Behaviour on this target |
|---|--------|---------------------------|
| 1 | `PLAYSFX` | Play `NNN.WAV` once. If no matching WAV exists, the same number plays as an AY sound effect from the effects bank instead. |
| 2 | `PLAYSFXL` | As 1, looped. |
| 3 | `PLAYSFXF` | Same as `PLAYSFX` (1) - the DOS-specific file-rate byte does not exist in this toolchain's DDB output, so the WAV's own header rate plays. |
| 4 | `PLAYSFXFL` | Same as `PLAYSFXL` (2), for the same reason. |
| 5 | `STOPSFX` | Stop whichever effect kind is currently active (sample and AY). |
| 6 | `PLAYDRO` | Play music once - a GAME-numbered AYS stream is tried first, an AKY song plays if none exists. On DOS these condacts played OPL music; on this target they are the music surface. |
| 7 | `PLAYDROL` | As 6, looped. |
| 8 | `STOPDRO` | Stop music of both kinds (AYS stream and AKY song). |
| 9 | `PLAYFLI` | Play video `NNN.VID` once - the classic DOS video symbol, now real: identical to `GFX n 13`. See [Video](../video.md) for cutscene playback. |
| 10 | `PLAYFLIL` | As 9, looped until a key is pressed - identical to `GFX n 14`. |

Sample numbers 1-254 may resolve to a WAV or fall back to an AY
effect; 255 is reserved and always plays from the AY effects bank.

## MOUSE sub-commands

All eight documented sub-commands (0-7) are implemented. A sub-command
number above 7 no-ops silently (a DEBUG build shows a marker), the same
idiom `SFX` uses for a sub-command it does not recognise.

| n | Symbol | Behaviour on this target |
|---|--------|---------------------------|
| 0 | `RESETMS` | Re-centre the pointer at (160,128), zero the buttons, clear the hotspot offset, and re-latch the movement baseline. |
| 1 | `SHOWMS` | Show the hardware sprite pointer. |
| 2 | `HIDEMS` | Hide the hardware sprite pointer. |
| 3 | `GETMS` | Read mouse state into four flags starting at the first argument: `flags[n]` = buttons (idle 0, left 1, right 2, middle 4, chords additive - jdaad parity, not the raw Kempston byte), `flags[n+1]` = column 0-79 (X/8), `flags[n+2]` = row 0-31 (Y/8), `flags[n+3]` = column 0-53 (X/6). |
| 4 | `GETFINEMS` | Fine position into **three** flags: `flags[n]` = buttons (same convention as 3), `flags[n+1]` = X/2 (0-159), `flags[n+2]` = Y undivided (0-255). This is the DRC manual's VGA case, which is what a 320x256 pointer plane is; `flags[n+3]` is NOT written. |
| 5 | `POINTERMS` | Re-upload the built-in pointer pattern into hardware sprite slot 0 and re-arm it. There are no `.PTR` pointer files on this target and only one pointer shape, so the parameter selects nothing; the sub exists so the documented `POINTERMS` then `SHOWMS` idiom always leaves slot 0 holding this interpreter's pointer, whatever else used the slot meanwhile. |
| 6 | `DELTAXMS` | Set the pointer's hotspot X offset within its bitmap - **not** a movement delta, despite the symbol name. The reported coordinates do not change; the bitmap shifts so the hotspot pixel lands on the reported position. Floors at the plane origin rather than wrapping. |
| 7 | `DELTAYMS` | As 6, for the hotspot Y offset. |

## GFX sub-commands

`GFX n s` takes the sub-command in its **second** parameter, `s`. There
are no symbolic names for these - Appendix D covers `SFX` and `MOUSE`
only - so write the number.

For every sub-command except 13 and 14 the first parameter `n` is
ignored: the buffer operations act on the whole surface and take no
argument. For 13 and 14, `n` is the video number.

"Front" is the surface you can see; "back" is the off-screen one you
draw into. A sub-command that is not in the table below is accepted and
does nothing at all, so a game that uses one still runs (a DEBUG build
prints a marker). That covers 3, 4, 7, 8, 11, 12 and everything from 15
up, as well as 9 and 10 - see
[Platform notes](../platform-notes.md) for why the numbered palette
store and recall have nothing to act on here.

| s | Behaviour on this target |
|---|---------------------------|
| 0 | Copy the back surface onto the front one, in place. What you drew off-screen becomes visible; the two surfaces keep their identities. |
| 1 | Copy the front surface onto the back one, in place - the reverse of 0. |
| 2 | Swap the front and back surfaces, and show the new front immediately. Nothing is copied, so this is the cheap way to present an off-screen frame. |
| 5 | Clear the front surface - the visible one - in place. |
| 6 | Clear the back surface. |
| 13 | Play video `n` (`NNN.VID`) once. Identical to `SFX n 9` (`PLAYFLI`). See [Video](../video.md). |
| 14 | As 13, looped until a key is pressed. Identical to `SFX n 10` (`PLAYFLIL`). |
