# Audio

Background music, sound effects and digital samples, all from the
`AUDIO\` folder. Everything here is optional - a game with no `AUDIO\`
folder builds and plays fine.

Music and effects are selected in your game with the `SFX` condact.
[Symbols](reference/symbols.md) lists every sub-command and what it does
on this target.

## Music

Compose in Arkos Tracker 3 and drop the `.aks` files into `AUDIO\`:

- **`<GAME>.aks`** - your theme. It plays automatically at boot, and
  `SFX 255 6` (once) or `SFX 255 7` (looped) plays it again from
  anywhere in the game.
- **`NNN.aks`** - numbered songs, played by `SFX n 6` (once) or
  `SFX n 7` (looped).
- **`STREAM_NNN.aks`** - a song too big for the song slot, streamed from
  the SD card instead. Selected exactly the same way, with `SFX n 6` /
  `SFX n 7`.

`SFX n 8` stops music of either kind.

**The song slot is 10208 bytes**, and a lot of real multi-channel tunes
do not fit it. If the build stops with `over the 10208 song limit`, you
have two choices: shorten the tune or reduce its channels, or rename the
source to `STREAM_NNN.aks` and let it stream. Streamed songs have no
fixed slot size - they are bounded only by free memory - at the cost of
reading from the card while they play. Streaming needs Arkos Tracker 3's
`SongToYm.exe` installed; the rest of the conversion is automatic.

## AY sound effects

Build your effects as a single Arkos sound-effects bank named
**`<GAME>_FX.aks`**. Effects from it play with `SFX n 1` (once) or
`SFX n 2` (looped), and `SFX n 5` stops whatever effect is sounding.

The effects bank has 2048 bytes to fit into. If it comes out larger, or
the effects tool is not installed, the build **warns and carries on
without it** - your game still builds and plays, just silently where the
effects would have been.

## Digital samples

Drop 8-bit WAV files into `AUDIO\` named by number - `001.wav`,
`002.wav` - and they are copied to the release untouched. Play one with
`SFX n 1` (once) or `SFX n 2` (looped), the same sub-commands the AY
effects bank uses.

**You supply the file in the right format; nothing converts it for
you.** It must be:

- PCM, **mono**, **8-bit unsigned**,
- sampled between **3500 and 20000 Hz**.

It plays back at whatever rate its own header declares - there is no
resampling - so pick the rate when you export.

**Samples and AY effects share one set of numbers.** `SFX n 1` looks for
`NNN.WAV` first and falls back to the effects bank if there is no such
file, so a sample and an AY effect cannot both use number 7. Numbers 1
to 254 work either way; 255 always plays from the AY bank.

**Size.** Samples load into whatever memory is free rather than one
fixed buffer, so there is no single limit to quote. As a working rule,
**up to 48K always fits**, on any machine, whatever else is loaded.
Beyond that a sample competes with picture caching and streamed songs
for the remaining memory, so test a large one on the memory
configuration you expect players to have.

## BEEP tones

`BEEP` plays a single tone through the AY. Write it the way the DAAD
manual documents - duration first, then tone - and let the compiler
handle the rest.

Two rules the compiler enforces before your game ever runs:

- **Tones outside 48 to 238 are not tones.** The compiler rewrites any
  `BEEP` with a tone below 48 or above 238 into a `PAUSE` of the same
  duration, so it becomes a silent wait rather than a note. The whole 48
  to 238 range sounds, top octave included.
- **Tones must be even.** An odd tone is silent by design.

**Durations are scaled at compile time.** Both `BEEP` and `PAUSE`
durations are multiplied by this target's own note length on the way
into the database, so a duration you authored is not the duration that
ships. `XPLAY`'s generated notes are scaled the same way. If you are
copying timings out of an older DAAD or MALUVA guide, treat its duration
tables as a starting point and check the result by ear.
