# Symbols

## Appendix D symbol names (SFX and MOUSE)

[DAAD Ready's manual](https://www.ngpaws.com/daadready/doc_en.html)
lists, in its Appendix D, symbolic names for the sub-command
argument of `SFX` and `MOUSE` (`PLAYSFX`, `SHOWMS`, and so on). The
bundled DRF compiler predefines every one of them, and a DSF written
with the symbolic form compiles byte-identical to the same DSF written
with the raw number - use whichever reads better.

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

## SFX sub-commands 11-16 (channel reservation)

These six are a NextDAAD extension - they are not in DAAD Ready's
Appendix D and the compiler predefines no symbolic names for them, so
write the raw number. They let a game reserve one of the two sample
channels for an effect rather than letting sub 1/2 pick automatically.
See [Audio](../audio.md) for the full explanation, including what a
reservation does and does not survive.

| n | Behaviour on this target |
|---|---------------------------|
| 11 | Play `NNN.WAV` once, reserved to sample channel 1. |
| 12 | As 11, looped. |
| 13 | Play `NNN.WAV` once, reserved to sample channel 2. |
| 14 | As 13, looped. |
| 15 | Stop sample channel 1 and release its reservation. |
| 16 | Stop sample channel 2 and release its reservation. |

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
| 5 | `POINTERMS` | Install pointer shape `n` (the first parameter) into hardware sprite slot 0 and re-arm it. `n` 0 always reaches a known shape - the built-in arrow, then `POINTER.SPR` over it if one exists; `n` 1-9 select `POINTER1.SPR` to `POINTER9.SPR`, and a missing or wrong-size file for that number is a silent no-op - the previously-installed shape stays. Classic `.PTR` pointer files remain unsupported: DOS DAAD loads their bytes as indices into a 256-colour palette it reloads per picture, so the same file renders in different colours depending on the current location graphic, with no fixed table here to translate against. Every call re-uploads and re-arms regardless, so the documented `POINTERMS` then `SHOWMS` idiom always leaves slot 0 holding your pointer, whatever else used the slot meanwhile. See [Customising](../customising.md). |
| 6 | `DELTAXMS` | Set the pointer's hotspot X offset within its bitmap - **not** a movement delta, despite the symbol name. The reported coordinates do not change; the bitmap shifts so the hotspot pixel lands on the reported position. Floors at the plane origin rather than wrapping. |
| 7 | `DELTAYMS` | As 6, for the hotspot Y offset. |

## GFX sub-commands

`GFX n s` takes the sub-command in its **second** parameter, `s`. There
are no symbolic names for these - Appendix D covers `SFX` and `MOUSE`
only - so write the number.

For every sub-command except 13, 14, 16 and 17 the first parameter `n`
is ignored: the buffer operations act on the whole surface and take no
argument. For 13 and 14, `n` is the video number; for 16, it is the font
number; for 17, it is the layer-order selector.

"Front" is the surface you can see; "back" is the off-screen one you
draw into. A sub-command that is not in the table below is accepted and
does nothing at all, so a game that uses one still runs (a DEBUG build
prints a marker). That covers 7, 8, 11, 12 and 15, and everything
from 18 up, as well as 9 and 10 - see
[Platform notes](../platform-notes.md) for why 9, 10 and 15 have nothing
to act on here.

| s | Behaviour on this target |
|---|---------------------------|
| 0 | Copy the back surface onto the front one, in place. What you drew off-screen becomes visible; the two surfaces keep their identities. If a picture is staged behind a pending reveal (drawn while sub 4's buffer mode was open, below), the copy also applies its palette - but the copy is progressive, not atomic, and does not change surface resolution, so it does not support revealing a staged picture whose resolution differs from the one currently on screen. Use 2 for that case. |
| 1 | Copy the front surface onto the back one, in place - the reverse of 0. |
| 2 | Swap the front and back surfaces, and show the new front immediately. Nothing is copied, so this is the cheap way to present an off-screen frame. If a picture is staged behind a pending reveal, the swap lands the surface, its resolution and its palette together, atomically - this is the clean reveal, and the only supported way (besides re-issuing `DISPLAY`) to reveal a staged picture whose resolution differs from the one currently on screen. |
| 3 | Graphics write to the physical screen - the default. `PICTURE`/`DISPLAY` draw and reveal on the visible surface directly; nothing is staged. Also closes buffer mode opened by sub 4. |
| 4 | Graphics write to the back buffer. `DISPLAY 0` stages the incoming picture's pixels and palette into the hidden surface only - the screen stays exactly as it was until a reveal (sub 0 or 2, above). |
| 5 | Clear the front surface - the visible one - in place. |
| 6 | Clear the back surface. |
| 13 | Play video `n` (`NNN.VID`) once. Identical to `SFX n 9` (`PLAYFLI`). See [Video](../video.md). |
| 14 | As 13, looped until a key is pressed. Identical to `SFX n 10` (`PLAYFLIL`). |
| 16 | Install font `n`. `n` 0 is the base font - the embedded table, then `FONT.CHR` over it if one exists; 1-9 select `FONT1.CHR` to `FONT9.CHR`. A missing or wrong-size file is a silent no-op - the previously-installed font stays. See [Customising](../customising.md). |
| 17 | Text layer order. `n` 0 puts the picture on top (Layer 2 above the tilemap - the default, and what every existing game gets); `n` 1 puts the text layer on top. `n` 2 and above is a no-op - the previously-set order stays. See [Graphics](../graphics.md#text-over-a-picture) for the transparent-paper technique this enables. |

Sub 17 composes the layer priority only - it never enables or disables
Layer 2, so it cannot bring back a picture surface the game has hidden.

Sub 17's layer order is NOT transient the way buffer mode (below) is: it
survives every picture operation and it survives `RESTART`, which is
what a template game's movement flow ends in on every turn, so an author
sets it once. It resets to picture-on-top on game start, on a
`RESTART`-of-game through `LOAD`/`RAMLOAD`, and on a part switch, with
the hardware register following the reset immediately.

Buffer mode (sub 4) is transient: once opened it lasts until sub 3,
`RESTART`, a same-part `LOAD`/`RAMLOAD`, or any game (re)start -
whichever comes first. Revealing a staged picture (sub 0 or 2) clears
only the pending reveal, never the mode itself - a game that opens
buffer mode and reveals a picture is still in buffer mode afterwards,
and the next `DISPLAY` stages again rather than drawing to screen. The
canonical sequence for one scene change is `GFX n 4`, `DISPLAY 0`,
`GFX n 2`, `GFX n 3` - always close with an explicit `GFX n 3`, even
though nothing in the reveal itself does it for you.

While a deferred picture's resolution differs from the one currently
on screen, the only supported buffer operations are `DISPLAY 0`
(re-stage) and `GFX n 2` (the reveal, above); `GFX n 0`, `1` and `5`
all operate on front-surface sizing that is stale for the length of
that deferral.

Video playback (`GFX n 13`/`14`) while buffer mode is active is
unsupported - issue `GFX n 3` first.

Known limitation: buffer-mode scene changes are not guaranteed when
the picture cache is exhausted by an oversized, uncompressed picture
(only reachable after a full eviction pass finds nothing left to
evict - effectively unreachable on 2MB-standard hardware). The
fallback loader runs at `PICTURE` time, and in the recommended fade
sequence `GFX n 4` opens buffer mode only after the `PICTURE` condact
(the ordering that protects against dark-room strands) - so when an
exhaustion fallback fires during that `PICTURE`, buffer mode is not
yet open: the fallback draws and flips immediately, a mid-fade flash,
and clears the staged-picture state. The sequence's following
`DISPLAY 0` is then a no-op, no reveal is pending, and `GFX n 2`
performs a plain surface swap rather than the clean reveal - the
fade-in can land on a mismatched surface or palette until the next
picture change.