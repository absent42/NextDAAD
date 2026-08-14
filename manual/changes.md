# What changed

Changes an author can see, newest first. If a release changed how your
game behaves, how it builds, or what the kit gives you, it is here.

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
  or `examples/fade` (fade the Layer 2 picture to any colour and back -
  fade to black for a scene change, fade up again - with transparent
  regions correctly staying transparent throughout) next to your
  database and try them without assembling anything. Each folder's
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
  [Getting started](getting-started.md).
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
  [Customising](customising.md) for the arithmetic and worked examples.
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
  after switching part. See [Customising](customising.md).
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
- [Customising](customising.md) gains a section on exporting a pointer
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
  [Customising](customising.md), [Multi-part games](multi-part-games.md),
  [DAAD V3](daad-v3.md), [Limits](reference/limits.md),
  [Symbols](reference/symbols.md) and
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
