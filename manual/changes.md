# What changed

Changes an author can see. If a release changed how your
game behaves, how it builds, or what the kit gives you, it is here.

## 0.9.0 - 3 September 2026

- **Animated sprites.** `GFX 19`, `20` and `21` start and stop sprite
  sets packed by the kit from `IMAGES\SPRITES`; 8-bit and 4-bit sets,
  up to eight at once, cached after the first load. See
  [Animated sprites](sprites.md).
- **Externs speak XBN format 2.** The header is fourteen bytes now,
  with a version byte of 2 and four reserved bytes that must be
  zero; a version 1 `GAME.XBN` is rejected and the game plays with
  externs off - rebuild your extern against the current `xbn.inc`.
  See [XBN format](reference/xbn-format.md#header).
- **`EXTERN` is now a condition, not just an action.** A carry flag
  set on return fails the entry the way a failed `AT` or `PRESENT`
  does, and clears its done state; carry clear continues past it
  exactly as before. An `EXTERN` with no `GAME.XBN` loaded, the
  interpreter's reserved function codes, and `CALL` itself can never
  fail an entry this way. See
  [Condition semantics](externs.md#condition-semantics).
- **Five new services, and `SVC_VERSION` now reads 2.**
  `SVC_FRAMES`, `SVC_GETDATE`, `SVC_BUSY`, `SVC_PALREAD` and
  `SVC_WINDOW` join the table at `$BEC8`, which now marks the rows
  safe to call from the `#int` hook - `SVC_VERSION`, `SVC_RANDOM`,
  `SVC_FRAMES` and `SVC_BUSY`. The object count byte, `XBN_NUMOBJ`,
  is a frozen address at `$A900`. See
  [Services](externs.md#services).
- **The extern collection reworked for v2.** Every module returns a
  deliberate carry verdict; hints reports through carry alone now,
  so flag 243 is only fn 51's level count, never a status code.
  Clock and timer keep time from `SVC_FRAMES` deltas instead of
  counting their own invocations. Fade reads the staged palette back
  through `SVC_PALREAD` and holds the palette interlock before it
  writes. The ticker stays silent while a video clip owns the
  tilemap window and follows a `GFX n 18` width switch mid-message.
  `CALL` slots in a collection binary moved to `$C00E`. See
  [The extern collection](externs.md#the-extern-collection).
- **New: the `realtime` module.** Fns 66-69 and flags 238-239 read
  the Next's own clock for date and time fields, and keep a day
  stamp in `GAME.HST` beside the database so a game can tell how
  long it has been since the last visit. See
  [realtime - the wall clock and day stamps](externs.md#realtime-the-wall-clock-and-day-stamps).
- **Toolkit grew fns 76-81 and 84.** A random-without-repeat picker,
  object queries by location, noun and extended attribute, total
  carried and worn weight as a 16-bit pair, and a print-target
  window that brackets its own output, so a status line no longer
  needs a `WINDOW` switch wrapped around it. See
  [toolkit - printing and 16-bit arithmetic](externs.md#toolkit-printing-and-16-bit-arithmetic).
- **An agent skill for writing externs.** The kit ships one at
  `.agent\skills\xbn-extern-authoring\` for any AI coding assistant
  to load before writing an extern.
- **Fix: Sampled/AY mixing** - Sample audio played at the 
  same time as AY music no longer distorts

## 0.8.0 - 30 August 2026

- **A new 40-column text mode: fewer, wider columns, for a game that
  wants bigger glyphs at the cost of characters per line.** `GFX 1 18` switches
  the tilemap to 40x32 double-width text; `GFX 0 18` returns to the
  80x32 default. Switching is a clean slate - the screen clears, all 8
  windows reset to full screen at the new width, and a pending
  word-wrap fragment is discarded - so re-issue `WINAT`/`WINSIZE`
  afterwards if you use custom windows. The width is game-owned, the
  same way as the `GFX n 17` layer order: it survives `RESTART`,
  `LOAD`, `RAMLOAD` and a part switch, and a same-width call does
  nothing, so `GFX 1 18` in your init process is safe to issue
  unconditionally. Flags 29 and 62 are unaffected - they read 129 and
  144 in both widths, because graphics remain available at either
  width. The whole authoring pattern, including the Layer 2
  hole-cutting arithmetic at the new width, is in
  [40-column games](graphics.md#40-column-games); the sub-command is
  in the [GFX reference](graphics.md#gfx-sub-commands). `MOUSE 3`
  (`GETMS`)'s reported column clamps to 0-39 in 40-column mode instead
  of 0-79 - see [Mouse](mouse.md#mouse-sub-commands).
- **NDRC v0.2.1`-cols=40` or `-cols=80`** sets the compiler's exported
  `COLS` symbol to match the width your game runs at, so window and
  centring arithmetic written against `COLS` comes out right whichever
  width you chose. `-cols=80` is the default and matches the
  interpreter's boot width.
-  **NDRC v0.2.1** `-auto-tokens` option enabled: per-game text compression. Instead of
  DRC's fixed per-language token table, the compiler selects up to 128
  tokens from the compiling game's own text and encodes the text with
  an optimal parse. Compressed text measures 8-14% smaller than the
  builtin table across a corpus of real games.

## 0.7.4 - 28 August 2026

- **Streamlined toolkit with less dependencies.**
  The kit now builds your database with its own compiler [`NDRC`](https://github.com/absent42/NDRC) (Next DAAD Reborn Compiler). 
  NDRC v0.1 ships in `lib\ndrc.exe` and compiles the `NEXTDAAD` target
  byte-identical to the DRC reference pipeline it replaces - a single
  exe, no PHP, no separate front and back end. DAAD Ready, PHP and the
  NextDAAD DRC fork are no longer required to build a game with this
  kit. `NDRC` is a port of [DRC](https://github.com/Utodev/DRC) under GPL-3.0,
  credit to Uto. See [Getting started](getting-started.md).
- **`NEXTDAAD` compiles at its real 80x32 geometry.** A game that reads
  `COLS`/`ROWS` (or otherwise sizes a window off them) now gets the
  correct 80x32 figures; the compiler previously handed every target,
  NEXTDAAD included, the classic 42x25 defaults.
- **`#ifdef "bit8"` blocks now compile on `NEXTDAAD`.** They were
  silently skipped before. A game imported from an 8-bit target with
  `#ifdef "bit8"` sections now pulls that code in - check what is
  inside before rebuilding.
- **`#ifdef "NEXTDAAD"` can be used in DSF source to compile code that conditionally targets NextDAAD 
  game builds.**

## 0.7.3 - 19 August 2026

- **Text over an unmodified full-frame picture: put the text layer on
  top and let transparent paper decide where the art shows.** Until now
  the only way to mix text and a picture was to cut a hole in the
  artwork where the text would land, which welded each picture to one
  layout. `GFX 1 17` puts the text layer above the picture and `GFX 0
  17` restores the default; with the text on top, `PAPER 227` makes a
  cell's background transparent so the picture shows through it, and
  `INK 227` goes the other way and makes the glyph shapes themselves
  transparent - stencil letters with the artwork inside them. The same
  full-frame picture now serves any layout, and the layout can change
  at runtime. The order belongs to your game: boot starts at picture on
  top, and nothing in the interpreter changes it afterwards - it
  survives every picture operation, `RESTART`, `LOAD`, `RAMLOAD` and a
  part switch, so set it once and a player restoring a save comes back
  in the order you chose. `BORDER 227` stays an ordinary magenta - the
  border is final output and has no transparency to trigger. The whole
  recipe, including keeping text readable over busy art, is in
  [Text over a picture](graphics.md#text-over-a-picture); the
  sub-command is in the [GFX reference](graphics.md#gfx-sub-commands).
- **`PAPER 11` and `INK 11` render bright magenta now, instead of
  punching holes.** Classic colour 11's hardware value happens to be
  the reserved transparency colour, so until now `PAPER 11` opened a
  hole in the text and `INK 11` printed invisible glyphs - with nothing
  on screen to explain why. Both are now nudged one green step, the
  same escape converted artwork already gets, so they render as a
  near-identical bright magenta. If an existing game of yours uses
  colour 11, it looks very slightly different and works, where before
  it was broken.
- **The mouse pointer survives picture draws.** Showing a picture used
  to switch the pointer's sprite off as a side effect, so a pointer
  shown with `MOUSE n 1` vanished at the next picture operation until
  something re-armed it. It stays on screen now, in either layer order.
- The near-magenta substitute for artwork that collides with the
  transparency colour moved from two blue steps down to one green step
  up, which is much closer to the authored colour on screen - and the
  same substitute everywhere, so a dodged colour now renders
  identically in stills and video. If a picture of yours leaned on the
  old substitute, it renders fractionally differently; nothing needs
  re-converting.
- **Fonts can be converted from PC, Linux and X11 formats now, not just
  ZX charsets.** `lib\fontconv.ps1` reads Windows `.fon` bitmap fonts,
  Linux console `.psf` and `.psfu`, X11 `.bdf`, and a raw glyph dump of
  any length with `-First` naming the character code its first glyph
  belongs to - alongside the 768-byte `.ch8` and the full 2048-byte
  table it already took. This is worth having because NextDAAD prints
  80 columns, where each pixel is half the physical width it has at 32
  and the two-pixel stems that read as bold on a Spectrum fill in;
  fonts drawn for 80-column displays have one-pixel stems and open
  counters and survive the transfer. A source whose ink needs more than
  an 8x8 cell is refused rather than squeezed - a squeezed descender is
  not worth reading. New options `-First`, `-Face` (which face of a
  `.fon` that holds several) and `-Slots` are all in
  [Fonts](fonts.md).
- **You can draw your own font and convert it with gfx2next.** Lay the
  glyphs out as 8 by 8 cells in an image editor and run
  `gfx2next -font MyFont.png FONT.spr`; a 96-glyph sheet covering
  characters 32 to 127 comes out at 768 bytes and needs nothing else.
  Use `-font` and not `-font-y`: both write a file of the same length,
  neither records which you used, and a `-font-y` file has its rows
  interleaved by a number that is not stored anywhere, so it cannot be
  put back in order. A `.spr` sheet keeps its own characters 96 and 127
  the same way a `.ch8` does.
- The build picks all of them up. A `FONT.ch8`, `.fon`, `.psf`,
  `.psfu`, `.bdf`, `.spr` or `.fnt` in the kit folder - or `FONT1.*` to
  `FONT9.*` - is converted for you, the way `FONT.ch8` already was. Two
  convertible sources for the same number is an error rather than a
  guess, and a ready-made `.CHR` still wins over both.
- **A converted font now fills glyphs 160 to 255 with a copy of its own
  32 to 127.** Those are the glyphs `GFX ON` and an upper-charset
  window print through, so a game using either used to print half a
  sentence in your font and half in the built-in one. A ready-made
  2048-byte `FONT.CHR` is still passed through untouched and keeps
  whatever you put at 160 to 255.
- Characters 96 and 127 are a pound sterling and a copyright sign here
  but a grave accent and a house on a PC, so a converted font takes
  those two from the built-in font. Only 96 can stay in the converted
  face, and only when the source declares itself OEM/CP437 and has a
  pound of its own at slot 156; 127 always comes from the built-in font,
  because CP437 has no copyright sign to lift from. A 768-byte classic
  ZX charset is exempt from both - it is the ZX charset by definition,
  so its own pound and copyright are kept in its own face. `-Slots
  Source` keeps the PC glyphs instead. Either way the output line names
  which of the three ran.

## 0.7.2 - 17 August 2026

- **Scene changes behind a fade: change the picture mid-fade, with no
  flash of the new image.** Two additions to `externs/fade` and two
  GFX sub-commands from the original DAAD set, working together. The
  fade snapshot is taken when you fade out, so changing the picture
  used to fade back up to the colours of a scene that was no longer
  there - `EXTERN 0 42` re-takes the snapshot for the new picture. And
  on real hardware the new image could still show a brief strip at
  full brightness between the fade out and the fade in - closed by
  `GFX 0 4`, which sends drawing to the back buffer so `PICTURE` /
  `DISPLAY 0` stages the new picture without showing anything, and
  `GFX 0 2`, which reveals it: surface, resolution and colours
  together. The screen holds the fade colour through the whole change
  and the new picture only ever appears through the fade. Order
  matters: `PICTURE` comes before `GFX 0 4`, so a dark room or missing
  picture cannot leave drawing stuck in the buffer. `EXTERN 0 43`
  blocks until the running fade finishes, replacing a flag-poll loop.
  The exact sequence is in the fade example's README and the
  [GFX reference](graphics.md#gfx-sub-commands). The example's prebuilt
  `GAME.XBN` is rebuilt again - copy it over yours.
- **Fixed: the fade example did not put a picture's colours back
  exactly.** Fading out and back left a slight colour cast - on a
  red-heavy photograph red and green returned exactly, but blue came
  back short, and any colour marked to sit in front of the other
  layers quietly lost that marking. Pictures are stored with more blue
  precision than the example was capturing. It now snapshots and
  restores the full colour, so a completed fade-in is bit for bit what
  you started with. If you use `examples/fade`, copy its rebuilt
  `GAME.XBN` over your old one - unlike the fix above, this one does
  need the new binary.
  
## 0.7.1 - 15 August 2026

- **Fixed: fetching more than one message from an extern corrupted the
  game.** `SVC_GETMSG` damaged the database's text compression tables
  whenever it decoded a compressed message, so a second fetch returned
  wrong text, ordinary game messages garbled, and the interpreter
  eventually stopped with `RD STACK - E9`. If your extern fetched one
  message per session you were safe - the shipped ticker example was -
  but anything more ambitious hit it.

## 0.7.0 - 14 August 2026

- **Your game can now run your own machine code.** Put a `GAME.XBN`
  binary next to `GAME.DDB` and the interpreter loads it at boot:
  `EXTERN` calls reach your code with the classic register contract,
  `CALL` jumps to any routine in it, and an optional hook in it runs
  once per frame at 50Hz - music-style timers, animations, effects.
  Assemble against the kit's `xbn.inc`; a bad or missing file simply
  means the game plays without externs. See [Externs](externs.md) for
  the whole story and [XBN format](reference/xbn-format.md) for the
  binary layout.
- **Ten interpreter services your code can call** - print through the
  game's own text windows, read and write files on the card, random
  numbers, and fetching any user message's text. They live at a fixed
  address that will never move between releases, so a compiled XBN
  keeps working on every future interpreter.
- **Two ready-to-run examples ship in the kit, binaries included.**
  Copy the prebuilt `GAME.XBN` from `examples/ticker` (a news-ticker
  that types a game message across the screen character by character)
  or `examples/fade` (fade the Layer 2 picture to any colour and back,
  with transparent regions correctly staying transparent throughout -
  changing the picture between the two halves needs 0.7.2, see above)
  next to your database and try them without assembling anything. Each folder's
  README shows the two or three DSF lines that drive it.
- **What externs cannot do**, so you are not surprised: parameters
  travel in the two EXTERN bytes and in flags (there is no inline data
  after the condact), the binary's memory is not saved into save games
  (keep durable state in flags), and `SFX` remains the interpreter's
  own audio system. The full list is in
  [Known differences](known-differences.md).

## 0.6.0 - 13 August 2026

- **The kit now builds NextDAAD-specific databases.** Your game is
  compiled for a new `NEXTDAAD` compiler target, which lifts the database
  ceiling from 31744 bytes to 64K - roughly twice the room for text,
  rooms and processes. Two consequences worth knowing:
  - The build needs one extra download, the NextDAAD DRC fork, into
    `tools\DRC\`. DAAD Ready is still required and still supplies the
    compiler front end and PHP. This is temporary: when a DAAD Ready
    release carries the new target, point `DRCDIR` in `CONFIG.BAT` at it
    and delete `tools\DRC`. See [Getting started](getting-started.md).
    Superseded in 0.7.4: the kit bundles its own compiler, `ndrc`, and
    neither DAAD Ready, PHP nor the DRC fork are needed to build any
    more.
  - A database built this way runs on NextDAAD only. It will not run on
    the ZX Spectrum interpreter DAAD Ready builds for the Next, and
    NextDAAD no longer loads databases built for those targets - it
    refuses them at boot with `DDB wrong machine - E4`. Rebuilding an
    existing game from its source is all that is needed.
- **`#classic` is refused.** That directive tells the compiler to  pad the token table and
  turning off the sharing of identical condact sequences. The build now stops and
  says so rather than spending your 64K on it.
- **Each tool can live in its own folder.** If you already have Arkos
  Tracker, CSpect or ffmpeg installed, you no longer need a second copy
  under `tools\`. `CONFIG.BAT` has a directory setting per tool -
  `DAADDIR`, `DRCDIR`, `GFXDIR`, `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR` -
  and each one you set is used instead of the folder under `TOOLSDIR`.
  Leave them blank and nothing changes, so you can set only the ones you
  keep elsewhere. Arkos Tracker and ffmpeg accept either the install root
  or the subfolder their programs sit in. See
  [Getting started](getting-started.md). `DAADDIR` and `DRCDIR` are gone
  as of 0.7.4, along with the tools they pointed at; delete them from a
  `CONFIG.local.BAT` that still sets either.
- **Timing change:** `PAUSE`, `BEEP` and `XPLAY` durations come out about
  17% shorter than before. This is a change in DRC itself, not in
  NextDAAD - the compiler lowered the note-length base for this machine -
  and it arrives with any newer DRC. A game tuned to the old timings
  plays slightly quicker; adjust the values if it matters.

## 0.5.0 - 12 August 2026

- `INK n`, `PAPER n` and `BORDER n` now take any value from 0 to 255,
  not just 0 to 15. 0 to 15 are the classic Spectrum colours, unchanged;
  16 to 255 are the standard Next colour of that number, the same
  `RRRGGGBB` convention used for Layer 2 artwork. See
  [Colours](colours.md) for the arithmetic and worked examples.
- `PAPER 8-15` now renders bright rather than folding to the dim hue,
  matching the Spectrum's own `BRIGHT` semantics more closely. A game
  that used those values expecting the old dim fold will look different.
- A `GAME.DDB` compiled for another computer - CPC, C64, MSX, PC and the
  rest - is now refused at boot with `NextDAAD: DDB wrong machine - E4`
  rather than loading and then behaving strangely. The kit compiles for
  the Spectrum already, so this only bites on a database that arrived
  from elsewhere. See [Getting started](getting-started.md) for the full
  list of boot messages.

## 0.4.0 - 10 August 2026

- Your game can change its text font while it runs. `GFX n 16` installs
  font n: 0 is the base font, and 1 to 9 are `FONT1.CHR` to `FONT9.CHR`
  in the kit folder. The whole screen restyles at once, including text
  already printed, because the hardware reads the glyph table live. A
  part switch reinstalls the base font, so re-select a numbered one
  after switching part. See [Fonts](fonts.md).
- `MOUSE n 5` (`POINTERMS`) now selects a pointer shape, where before
  the number did nothing. Shape 0 is the base pointer, and 1 to 9 are
  `POINTER1.SPR` to `POINTER9.SPR`. The hotspot you set with `MOUSE 6`
  and `MOUSE 7` is not disturbed by a shape change.
- The built-in mouse pointer is now a conventional arrow cursor. If
  your game ships no `POINTER.SPR`, `MOUSE 0 5` returns to it even
  after a numbered shape has been shown.
- A font or pointer file that is missing or the wrong size is ignored,
  as before: whatever is already installed stays and your game carries
  on.
- The build converts and stages the numbered files for you. Drop
  `IMAGES\POINTER1.png` to `POINTER9.png` in for pointer artwork, or a
  classic 768-byte `FONT1.ch8` to `FONT9.ch8` in the kit folder for
  fonts. A ready-made `.CHR` or `.SPR` still wins over a converted
  source of the same number.
- `lib\fontconv.ps1` takes a new `-Base` option so a second font can be
  padded against your own first font instead of the built-in one, which
  is how you keep custom glyphs across a font change.
- The build now stops with an error if a converted pointer is not
  exactly 256 bytes, rather than staging a file the interpreter would
  silently refuse. A 32x32 source is the usual cause; pointers are
  16x16.
- [Mouse](mouse.md) gains a section on exporting a pointer
  from a sprite editor, and why an export can be exactly the right size
  and still come out as a solid block of the wrong colour.
- Sound effects and samples can now play two at once. `SFX n 1` and
  `SFX n 2` pick a channel for you automatically, or you can reserve
  one outright with the new sub-commands 11 to 16. See
  [Audio](audio.md) for the full two-channel picture, including how a
  channel gets taken over when both are busy.
- A sample's length is no longer limited by memory - files of any size
  now play, small ones from a fast fixed area and large ones streamed
  from the card. See [Audio](audio.md) for what changes at 24K and
  what a very large looping effect sounds like at its seam.
- 15625 Hz is now the recommended rate for new WAV samples, because it
  matches the hardware's own clock on most video modes. Existing
  samples at 16000 Hz keep working exactly as before - nothing needs
  re-exporting.

## 0.3.2 - 7 August 2026

- Location pictures can now have holes. Palette slot 255 is reserved:
  paint the Spectrum Next's standard transparency magenta into that slot
  and pixels drawn with it show the text layer through. If you do not
  want a hole, quantize your art to 255 colours (indices 0-254) instead
  and leave slot 255 unused - see [Graphics](graphics.md) for what the
  build warns about and what it cannot check.
- The screen no longer shows a white background before a game's first
  picture, or in any area a game has not painted.
- The kit's documentation is now a manual you read in a browser. Open
  `docs\index.html`. The old single-file guides are gone and their
  contents are spread across the pages that own each subject:
  `SETUP.md` across [Getting started](getting-started.md),
  [Graphics](graphics.md), [Audio](audio.md), [Video](video.md),
  [Fonts](fonts.md), [Mouse](mouse.md), [Colours](colours.md),
  [Multi-part games](multi-part-games.md),
  [DAAD V3](daad-v3.md), [Limits](reference/limits.md) and
  [Video delivery](reference/video-delivery.md); `DIVERGENCES.md` across
  [Platform notes](platform-notes.md),
  [Known differences](known-differences.md) and
  [DAAD V3](daad-v3.md); `VIDEO-PRESETS.md` into
  [Video](video.md); `NX2-FORMAT.md` into
  [Picture format](reference/picture-format.md); and the encoder's own
  readme into [Video format](reference/video-format.md).

## 0.3.1 - 4 August 2026

A compliance release. NextDAAD now runs real DAAD databases the way the
reference interpreters do across messages, object resolution, flags and
refusals, and it accepts DAAD version 3 databases, so the standard DAAD
Ready authoring path for this target works unmodified.

**Behaviour changes are the point of this release.** A game tuned around
any of the old behaviour below - the silent `GET`, the forced continuous
listing, the old random sequence, the old convertible-noun threshold -
plays differently now.

### Breaking: cutscene audio is always stereo

The --mono encoder option is gone. Mono cost more playback time than it
saved and made no audible difference against 8-bit sound. A mono source
still needs nothing from you; it is put on both channels automatically.

If a `CONFIG.BAT` still carries --mono in `VIDOPTS` or `VIDOPTS_NNN`,
the build now stops with an unrecognised-argument error. Delete the
option; nothing replaces it.

### DAAD V3

- Version 3 databases load and run, and the kit compiles `-v3` by
  default. A version 2 database behaves exactly as it did before.
- `XMES`, second-parameter indirection and `SETAT` are implemented, as
  are the version 3 flag 53 bits. `PAUSE 0` under version 3 means "wait
  for a key". `SYNONYM` no longer marks its entry done under version 3.
- An existing version 2 game needs three checks before you trust a
  version 3 build of it - see [DAAD V3](daad-v3.md).

### Objects and messages

- `GET`, `DROP`, `WEAR`, `REMOVE`, `PUTIN` and `TAKEOUT` print their
  success messages. The objects always moved; the player was simply
  never told. `GET ALL` and `DROP ALL` were completely silent.
- Refusal messages come out in the right order across the whole family,
  so the message that appears is the one that fits. A refusal now
  performs `NEWTEXT` and aborts the rest of a compound order, so
  `GET SWORD AND KILL ORC WITH IT` no longer attacks the orc when the
  sword was refused. `OK` deliberately does not abort.
- The AUTO- family tells "there is no such object anywhere" apart from
  "that word is not an object".
- `TAKEOUT` performs the weight check it never had.
- Object names are no longer article-stripped in listings. `LISTOBJ`,
  `LISTAT`, the inventory and `LOOK` print the text as authored - "a
  pair of dungarees", not "pair of dungarees".
- Substituting a name into a message removes only a leading "a ",
  "an ", "some " or "the ", and keeps any other first word, so "rusty
  sword" stays "rusty sword". A substituted name is also truncated at
  the first ".". See [Platform notes](platform-notes.md).
- An object text with no space in it used to print nothing at all. It
  now prints.
- Abandoning a name part-way through no longer leaves the text that
  follows reading from the wrong place.
- `@` substitutes only in Spanish databases now, matching DAAD Ready's
  own escape table. In an English database `@` is an ordinary printable
  character, so a message containing `-@@-` prints `-@@-`; it used to
  eat any literal `@` an English message contained. In a Spanish
  database its capitalisation now actually happens.
- Extended object attributes are loaded in the right order. `HASAT` for
  attributes 0-7 was reading 8-15 and the other way round, which
  silently corrupted every attribute test in every game.
- A bare noun resolves against an object that carries an adjective, so
  `GET LAMP` finds a "QUAINT LAMP". A full adjective match still beats a
  partial one.
- Search priority is restored for the AUTO- family and `WHATO`. Every
  "carried" pass was really an "anywhere" pass, which could match
  objects that had never been created and let `AUTOT` take something out
  of a container the player was nowhere near.
- `WHATO` with no match clears flags 54-59 instead of leaving the
  previous object's data in them.
- `SWAP` is a raw exchange that no longer adjusts flag 1, and sets the
  referenced object. `COPYOO` sets the referenced object and does adjust
  flag 1.
- Zero-weight containers are magic bags: their contents no longer
  transmit weight.

### Listings and flow

- `LISTOBJ` and `LISTAT` honour flag 53 bit 6 - clear lists one object
  per line, set gives the continuous "a, b and c." form. The continuous
  form used to be forced. Flag 53 bit 7 is maintained on both paths, and
  an empty `LISTAT` prints SM53 alone.
- A listing no longer overwrites the referenced object.
- `ISDONE` and `ISNDONE` report everything done since the current
  process table was entered. `SKIP` and `REDO` no longer count.
- `PICTURE` and `MOVE` mark the process table done on every exit,
  including their failing ones. **One authoring pattern changes:** a
  `PROCESS` holding only a `MOVE`, tested afterwards with `ISNDONE` to
  print "I can't go in that direction", no longer prints it. Let `MOVE`
  gate the entry itself and put the message in the following entry,
  which reads the same everywhere.
- A `DOALL` that finds nothing performs `NEWTEXT` and `NOTDONE`; one
  that iterated and ran out still completes done.
- `EXIT n` with n non-zero restarts the game. It used to do nothing.
- `WINDOW n` out of range keeps the current window instead of falling
  back to window 0.
- An out-of-range location raises runtime error 1, not error 7.
- `RANDOM` and `CHANCE` use a real generator. The old one returned six
  distinct values in a repeating cycle of eight, and `CHANCE 50` fired
  62 per cent of the time. Any game that depended on the old sequence
  now differs.

### Parser and input

- `PARSE 1` re-parses the quoted section of the last order, so
  `SAY "..."` commands work - see [Platform notes](platform-notes.md).
- `INPUT stream options` switches the active window for the input and
  restores it afterwards.
- `QUIT` and `END` read a whole line at the confirmation prompt, echoed
  live, and act on ENTER. They used to act on a single keypress.
- The convertible-noun threshold is 40, not 20. **Any noun numbered
  20-39 now acts as a command when typed on its own.**

### Flags

- Flag 29 reads 129 and flag 62 reads 144. Flag 29 was never written at
  all, so a game gating its artwork on `HASAT GMODE` drew nothing.
- Flags 37 and 52 start at 0 rather than 4 and 10. Set your own limits
  in your reset process with `ABILITY`, or `LET fMaxCarr` /
  `LET fStrength`. Every corpus game and the starter already do.
- Flag 61 is cleared whenever flag 60 is written.
- Saves made before this release still load, but they carry the old
  values of flags 29, 53 and 62. Start a fresh game to pick up the
  current ones.

### Audio

- `BEEP` plays the note and the length the compiler actually emitted.
  The two parameters were being read the wrong way round, so most
  authored `BEEP`s played a wrong note or were dropped. The tone ceiling
  is 238 rather than 222, which recovers the top eight semitones.
- Sampled sound effects no longer distort while a picture is drawn.
- Two AY music symptoms remain open: distortion when all nine channels
  are driven at once, and a tune restarting at a lower tone after
  `STOPM`.

### Video

- A clip can be up to 256 MB, lifted from 16 MB, and the encoder refuses
  an over-size clip at build time with a message naming the limit -
  it used to write a file the player then refused to open. See
  [Video](video.md) section 6 and
  [Video format](reference/video-format.md).
- Shapes replace the five fixed profiles: `full`, `16:9`, `scope`,
  `classic` and `classic-wide`, plus any explicit width by height and a
  free height derived from an aspect ratio. Whether a clip plays
  resident or streams is chosen for you; direct-serve is a separate
  per-clip opt-in (`--direct` in `VIDOPTS_NNN`).
- The mid-clip pause is gone, keyframes no longer hitch, and half-rate
  clips play at their true rate.
- Sources that are not 25 fps are retimed by blending rather than by
  dropping frames, which removes the motion stutter the old method
  caused. `--retime` selects the other methods.
- The frame-rate floor for sound is 10.17 fps, down from 24.4, so a
  12.5 fps encode of a demanding clip is a real option.
- Uncompressed playback reaches 256x153 at 25 fps, and full-screen
  320x256 at 12.5 fps.
- The streaming budget is derived per clip rather than guessed, and the
  encoder reports what it chose. The kit no longer ships per-clip budget
  values.
- New: `--prefilter` for grainy sources and `--tile-slack` for
  sustained motion. Removed: offset copy and cut approximation, neither
  of which improved the picture.
- Stale-picture recovery now works, so a screen that has drifted too far
  from the source is refreshed.
- A clip stored in exactly 32 fragments on the card was falsely refused.
  The real limits are 32 fragments for a resident clip and 8 for a
  streamed or direct one.
- A cutscene that fails to open now says why on screen instead of
  silently skipping.
- Video needs a 2MB Next. A 1MB machine has too small a memory pool to
  hold or stream clips reliably.

### The kit

- New `VIDTUNE.BAT`: pick a clip, preview a segment, change the shape,
  frame rate and dither, encode and accept - the settings are written
  into `VIDOPTS_NNN` in `CONFIG.BAT`, so the next build reproduces what
  you previewed. Ships ready to run.
- Location pictures draw slightly faster.
- The "!" glyph was redrawn to match the font's stroke and baseline.

## 0.2.0 - 23 July 2026

- Cutscene video: the native NXV format and a build step that encodes
  `VIDEO\NNN.mp4` for you and caches the result. Playback with
  `GFX n 13` and `GFX n 14`.
- `videnc.exe` ships with the kit, so no Python is needed to encode a
  cutscene. ffmpeg is the only extra download video authoring wants.
- AY music is parked during a cutscene and resumes after it.
- Deleting a source no longer leaves its converted file behind in
  `RELEASE\`. A tune or picture you remove from the kit folder is
  cleared out on the next build instead of lingering on the card.
- Keyboard fixes: the symbol-shift map was off by one from F onward, and
  CAPS+2 typed a literal 2 instead of toggling caps lock.
- Font fixes: a proper ampersand and pound sign in place of the euro
  sign and apostrophe the inherited font carried.

## 0.1.0 - 20 July 2026

First release: a DAAD interpreter for the ZX Spectrum Next, with Layer 2
location graphics, tilemap text, AY music and sound effects, sampled
sound, and the authoring kit that builds an SD card image from your DSF.
