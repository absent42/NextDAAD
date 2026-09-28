# NextDAAD features

What this interpreter adds on top of standard DAAD, and the exact condact
forms that reach each feature. Every sub-command is a plain number: there are
no symbolic names for `GFX` or `MOUSE` sub-commands beyond the DAAD Ready
`SFX` and `MOUSE` symbols noted below. The manual page for each feature is
linked; go there for anything this file does not settle.

Parameter order matters. In `GFX n s`, `SFX n s` and `MOUSE n s` the
**second** parameter picks the sub-command and the first is its argument.
`GFX 1 13` plays video 1. `GFX 13 1` copies the front buffer to the back.

## Colours (INK, PAPER, BORDER 0-255)

[Manual: colours](../../../../docs/colours.html)

| Value | Meaning |
|---|---|
| 0-7 | Classic Spectrum colours |
| 8-15 | Bright versions of 0-7 |
| 16-255 | Next colour, `n = red*32 + green*4 + blue` (red, green 0-7, blue 0-3) |
| 227 | Reserved: `PAPER 227` transparent paper, `INK 227` transparent glyphs, `BORDER 227` magenta |

Examples: 224 red, 28 green, 255 white, 3 blue (pure blue exists only as 1
or 9). At most 128 distinct ink/paper pairs can be on screen at once.
`BORDER` only shows around 256-wide art or where nothing else is drawn.

## Pictures

[Manual: graphics](../../../../docs/graphics.html)

- Source: `IMAGES\NNN.png`, the first run of digits is the picture number.
  `PICTURE n` / `DISPLAY 0` draw it, exactly as on any DAAD target.
- Must be an 8-bit paletted (indexed) PNG, at most 255 colours in slots
  0-254. Slot 255 is transparency; paint `#FF00FF` there for see-through
  areas. NextDither (preset "NextDAAD Layer 2") is the recommended converter.
- Width picks the shape: 320 wide fills the whole screen including the
  border; 256 wide is the classic paper area. Any other width is a build
  error. Height up to 256 (320-wide) or 192 (256-wide); shorter art is
  top-aligned.
- Title screen: `IMAGES\DAAD.png`, shown once at boot until a key is
  pressed.
- `PICTURE n` is a condition: it fails when picture n does not exist, and
  the entry stops there. STARTER.DSF uses that to fall through to a
  full-screen text window.
- `DISPLAY` touches the picture layer only. `DISPLAY 1` blanks the picture
  (used for darkness). `CLS` clears text.

### Laying text over or beside a picture

The text grid is 80 columns by 32 rows; one cell is 4 x 8 pixels. A window
positioned at `WINAT row col` / `WINSIZE rows cols` covers pixel rectangle
`left = col*4, top = row*8, width = cols*4, height = rows*8`. For 256-wide art
subtract 8 from the column and 4 from the row. At 40 columns a cell is 8
pixels wide. The classic paper area is `WINAT 4 8` + `WINSIZE 24 64`.

STARTER.DSF puts the game text window at `WINAT 14 0` under a 106-pixel
picture.

- `GFX 1 17` puts text above the picture; `GFX 0 17` restores picture on
  top. With text on top, `PAPER 227` makes the picture show through cell
  backgrounds.
- `GFX 1 18` switches to 40 x 32 text; `GFX 0 18` back to 80 x 32. Issue it
  in the init process before anything is drawn, and set `COLS=40` in
  `CONFIG.BAT` so the compiler wraps at 40. Same-width switches are no-ops.

### GFX n s

| s | n is | Effect |
|---|---|---|
| 0 | ignored | Copy back buffer to front |
| 1 | ignored | Copy front to back |
| 2 | ignored | Swap buffers and show (atomic reveal) |
| 3 | ignored | Draw to screen (default); ends buffer mode |
| 4 | ignored | Draw to back buffer; `DISPLAY 0` then stages |
| 5 / 6 | ignored | Clear front / clear back |
| 9 | flag | Set palette entry: flag n = index, n+1..n+3 = R,G,B 0-255 |
| 10 | flag | Read palette entry n into n+1..n+3 |
| 11 | flag | Colour cycle: n = first index, n+1 = last, n+2 = frames per step |
| 12 | ignored | Stop colour cycling |
| 13 | video | Play `NNN.VID` once |
| 14 | video | Loop `NNN.VID` until a key is pressed |
| 16 | font | Install `FONTn.CHR` (1-9); 0 restores the base font |
| 17 | 0/1 | 1 = text layer above picture; 0 = picture above text |
| 18 | 0/1 | 1 = 40 columns; 0 = 80 columns |
| 19 | set | Start animated sprite set n at its baked position |
| 20 | flag | Start set: flag f = set, f+1/f+2 = X lo/hi, f+3 = Y |
| 21 | set | Stop set n; 255 stops all |
| 22 | glyph | Parser cursor glyph (0 = block, `GFX 95 22` = underscore) |
| 23 | frames | Cursor blink period; 0 = steady |
| 24 / 25 | colour | Cursor ink / paper (227 allowed) |
| 26 | ignored | Cursor colours follow the window |

Staged scene change with no flicker: `GFX 0 4`, `DISPLAY 0`, `GFX 0 2`,
`GFX 0 3`. Always close with sub 3. Buffer mode also ends on `RESTART`,
`LOAD` and `RAMLOAD`. No video while buffer mode is open.

Subs 17, 18 and 22-26 are game-owned settings: they survive `RESTART`,
`LOAD` and part switches and are not saved in save files.

## Audio

[Manual: audio](../../../../docs/audio.html)

Files go in `AUDIO\`. Numbers are normalised to three digits (`1.aks`
becomes `001.AKY`).

| Source file | Becomes | Played by |
|---|---|---|
| `<GAME>.aks` (same base name as the DSF) | `GAME.AKY` | Autoplays at boot, looped, with no DSF change; `SFX 255 6` / `SFX 255 7` restart it |
| `NNN.aks` | `NNN.AKY` | `SFX n 6` once, `SFX n 7` looped |
| `STREAM_NNN.aks` | `NNN.AYS` | Same, for songs over the 10208-byte slot |
| `<GAME>_FX.aks` (the one effects bank) | `GAME.SFB` | `SFX n 1` / `SFX n 2` |
| `NNN.wav` | `NNN.WAV` | `SFX n 1` / `SFX n 2` |

- The boot theme keeps looping through the title screen and into play, so
  a game whose only music is `<GAME>.aks` needs no `SFX` at all.
- Arkos Tracker 3 lives at `tools\ArkosTracker3\tools\` (`SongToAky.exe`,
  `SongToSoundEffects.exe`, `SongToYm.exe`), or set `ARKOSDIR` in
  `CONFIG.BAT`. Without it no `.aks` converts.
- Arkos Tracker 3 songs must be composed for 3 PSGs (9 channels). Others
  convert but play silently. A song over 10208 bytes must be renamed
  `STREAM_NNN.aks`. The effects bank is at most 2048 bytes.
- WAV: mono, 8-bit unsigned PCM, 3500-20000 Hz; 15625 Hz recommended. The
  build does not resample.
- Samples and AY effects share numbers: `SFX n 1` plays `NNN.WAV` if it
  exists, else AY effect n from `GAME.SFB`. 255 always plays from the bank.
- `RESTART`, `QUIT` and play-again leave sound running; stop music with
  `SFX 0 8` and effects with `SFX 0 5` yourself where the story needs it.
- `BEEP duration tone`: tone 48-238 and even (odd tones are silent; out of
  range compiles to a PAUSE). Dropped while music or an effect plays.

### SFX n s

| s | DAAD Ready name | Effect |
|---|---|---|
| 1 | PLAYSFX | Play WAV n, else AY effect n, once |
| 2 | PLAYSFXL | Same, looped |
| 3 / 4 | PLAYSFXF / PLAYSFXFL | Same as 1 / 2 |
| 5 | STOPSFX | Stop all effects, release channel reservations |
| 6 | PLAYDRO | Play song n once (255 = the game theme) |
| 7 | PLAYDROL | Play song n looped |
| 8 | STOPDRO | Stop music |
| 9 | PLAYFLI | Play video n once |
| 10 | PLAYFLIL | Loop video n until a key |
| 11 / 12 | | WAV n once / looped, reserved to sample channel 1 |
| 13 / 14 | | WAV n once / looped, reserved to sample channel 2 |
| 15 / 16 | | Stop and release channel 1 / 2 |

The DAAD Ready manual spells one symbol `FPLAYFLIL`; that does not compile.
Use the numbers.

## Timing: PAUSE and BEEP are scaled

The compiler multiplies every `PAUSE` and `BEEP` duration by 0.6 before it
reaches the interpreter. One second is `PAUSE 83`; two seconds is
`PAUSE 167`. Under V3, `PAUSE 0` means wait for a key (GETKEY); use
`PAUSE 255` for the longest timed wait.

## Video cutscenes

[Manual: video](../../../../docs/video.html)

- `VIDEO\NNN.mp4` (or `.mkv`) is encoded at build time to `NNN.VID`;
  `GFX n 13` plays once, `GFX n 14` loops until a key. The location picture
  and colours come back by themselves afterwards.
- Needs a 2MB Next and real hardware; emulators do not play it correctly.
- Encoding is tuned per clip with `VIDOPTS_NNN=` lines in `CONFIG.BAT`
  (delete the shipped `VIDOPTS_001` / `VIDOPTS_002` demo lines when the
  demo clips go). `VIDTUNE.BAT` is the GUI for that.

## Fonts

[Manual: fonts](../../../../docs/fonts.html)

- `FONT.CHR` in the kit root: exactly 2048 bytes (256 glyphs x 8 rows).
  Also accepted and auto-converted: `.ch8`, `.fon`, `.psf`, `.psfu`, `.bdf`,
  `.yaff`, `.draw`, `.spr`, `.fnt`. Same for `FONT1.*` to `FONT9.*`.
- `GFX n 16` swaps to `FONTn.CHR` at runtime, restyling all text at once.
- Glyph 32 must be blank or the screen fills with specks.

## Animated sprites

[Manual: sprites](../../../../docs/sprites.html)

- `IMAGES\SPRITES\NNN.png` (frames left to right, 16-pixel multiples,
  magenta transparent) plus a sidecar `NNN.txt` with `key=value` lines:
  `w`, `h` (16-128), `x`, `y` (baked position), `delay` (ticks per frame,
  one number or a list), `loop` (1 forever, 0 once and hold), `frames`,
  `bits` (8 or 4).
- `GFX n 19` starts set n; `GFX f 20` starts with a position from flags;
  `GFX n 21` stops; `GFX 255 21` stops all. Up to 8 sets at once.
- Sets draw above picture and text and never move once started. `PICTURE`
  and `DISPLAY` stop them, so restart sets in the location process after
  the picture is drawn. They are not saved.

## Mouse

[Manual: mouse](../../../../docs/mouse.html)

`MOUSE n s`; DAAD Ready symbols are predefined.

| s | Symbol | Effect |
|---|---|---|
| 0 | RESETMS | Centre the pointer, clear buttons |
| 1 / 2 | SHOWMS / HIDEMS | Show / hide |
| 3 | GETMS | flag n = buttons (L 1, R 2, M 4), n+1 = column, n+2 = row |
| 4 | GETFINEMS | flag n = buttons, n+1 = X/2, n+2 = Y |
| 5 | POINTERMS | Install shape n (0 base, 1-9 = `POINTERn.SPR`) |
| 6 / 7 | DELTAXMS / DELTAYMS | Hotspot offset |

Only `MOUSE n 3` and `MOUSE n 4` move the pointer; an `INKEY` loop that
never polls leaves it frozen. Custom pointer: `POINTER.SPR` (256 bytes,
16 x 16, RGB332, 227 transparent) in the kit root, or `IMAGES\POINTER.png`.

## Externs

[Manual: externs](../../../../docs/externs.html)

`EXTERN p fn` calls machine code in `GAME.XBN`. The kit ships a collection
in the root `GAME.XBN` so these work out of the box. An extern can be a
condition: when the module says no, the entry stops there, so give every
condition-extern a fallthrough entry that handles the "no". With no
`GAME.XBN` present every `EXTERN` is a harmless no-op that never fails.

| fn | Module | Use |
|---|---|---|
| 4 | built in | `EXTERN n 4` switches to part n of a multi-part game |
| 20-23 | playername | 20 capture the last typed line (condition), 21 print it, 22 "no name yet" (condition), 23 compare with message p |
| 30-39 | ticker | Scrolling one-line message strip: 30 arm, 31 stop, 32-38 row/col/width/ink/paper/mode/speed, 39 type message n at the cursor |
| 40-43 | fade | 40 fade out, 41 fade in, 42 re-snapshot after a picture change, 43 wait for the fade to finish |
| 50-53 | hints | `EXTERN n 50` prints topic n's next hint from `HINTS.TXT` (condition, fails when none left); 51 level count; `0 52` preflight; `0 53` reset |
| 60-62 | clock | In-game clock in flags 224 h, 225 m: 60 start, 61 stop, 62 advance p minutes |
| 63-65 | timer | Countdowns: 63 arm, 64 stop, `d 65` set an in-game-minute deadline |
| 66-69 | realtime | Real-time clock: `0 66` snapshot (condition, fails with no RTC), `f 67` field f into flag 238 (0 sec, 1 min, 2 hour, 3 day, 4 month, 5 year, 6 weekday) |
| 70-84 | toolkit | 70 print flag p as decimal, 71 print 16-bit pair, 72/73 add/sub, 74 compare into 251, 76/77 random pick without repeats, 78 count objects at location, 79 carried weight, 80 object by noun, 82 print HH:MM, 83 MM:SS, 84 set print window |
| 90-94 | transcript | Session transcript to the card; ships separately, not in the root `GAME.XBN` |

Codes 3 and 7 are reserved for the interpreter (`XMESSAGE`, `XUNDONE`);
never write `EXTERN n 3`. Flags 224-251 belong to the collection. A game
that writes its own module puts it in `externs\` and uses codes 16 and up
that no bundled module claims; the `xbn-extern-authoring` skill beside this
one covers that.

Fade scene change:
`EXTERN 0 40`, `EXTERN 0 43`, `PICTURE @38`, `GFX 0 4`, `DISPLAY 0`,
`EXTERN 0 42`, `GFX 0 2`, `GFX 0 3`, `EXTERN 0 41`, `EXTERN 0 43`.

### Hints

`HINTS.TXT` in the kit root: a `[n] label` line starts topic n, each
blank-line-separated paragraph after it is the next stronger hint. The
build packs it into `GAME.HNT`. No `_` and no control characters in hint
text. Progress lives in `GAME.HPR` on the card and is shared by every save.

## XMESSAGE and XMES

`XMESSAGE "text"` (adds a newline) and `XMES "text"` (no newline) store the
string in `0.XMB` beside the DDB instead of inside it. The DDB is limited
to 65535 bytes; `0.XMB` holds another 64K. Move long descriptions there
when the build reports the DDB over the limit. `0.XMB` must ship beside
`GAME.DDB` or those messages print nothing.

## Multi-part games

[Manual: multi-part games](../../../../docs/multi-part-games.html)

- Parts 2-9 each live in `PART<n>\` with one DSF and compile to
  `GAME<n>.DDB`. `EXTERN n 4` switches; the new part starts at its `PRO 0`.
- All 256 flags carry across. Object locations carry by index, so keep
  object numbering consistent between parts. Vocabulary is per part.
- Part folders take converted assets only (`.NX2`, `.AKY`, `.WAV`, ...),
  not `.png` or `.aks`.

## DAAD V3 dialect

[Manual: DAAD V3](../../../../docs/daad-v3.html)

The kit compiles V3. Extras over V2: second-parameter indirection
(`LET 100 @101`), `GETKEY`, native `XMES`, `SETAT`, flag 53 attribute bits.
Three silent changes when porting a V2 source: `SYNONYM` no longer marks
the entry done; `PAUSE 0` is a key wait; flags 25-27 and 39-40 are used by
the second-object machinery and are no longer free.

## Behaviour that differs from other DAAD interpreters

[Manual: platform notes](../../../../docs/platform-notes.html) and
[known differences](../../../../docs/known-differences.html)

Write these forms and the game reads correctly everywhere:

- `DESC @38`, never `DESC 255`. Use 255 as "here" only in `PLACE`, `PUTO`
  and `AUTOT`.
- `CREATE`, `DESTROY` and `PLACE` leave the referenced object (flag 51)
  alone; follow with `SETCO n` when the next condact needs it.
- Flags 37 (max objects) and 52 (max weight) start at 0. Set them in the
  init process or the player can carry nothing.
- Inside a `DOALL`, the object on the current pass is the referenced
  object: flag 51, with flags 54-59 describing it. Flag 50 holds the
  location being searched, as on the original ZX interpreter; jDAAD and
  msx2daad put the object number in flag 50 instead, so read the object
  from flag 51. Writing flag 50 inside the loop moves the rest of the
  loop to that location. Do not carry a value in flag 50 across a
  `PROCESS` call.
- `PICTURE` and `MOVE` always mark the table done. Gate a move on `MOVE`
  itself, not on `ISNDONE` afterwards.
- A `DOALL` that finds nothing does `NEWTEXT` and `NOTDONE`.
- `EXTERN` can fail an entry.
- `PUTIN` / `TAKEOUT` print SM44/45/52, the container name, then SM51 with
  no spaces inserted; put the trailing space inside SM44/45/52.
- `AUTOG` searches here, then carried, then worn.
- Nested `DOALL` raises runtime error 4.
