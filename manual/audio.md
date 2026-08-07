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

**Compose for three PSGs - nine channels.** The Next's Turbo Sound has
three AY chips, and the resident song player is built for exactly that
shape. A `.aks` written for one or two PSGs converts without complaint
and then does not play at all: the interpreter checks the channel count
as it loads and refuses anything but nine, so the `SFX` that selects it
is silently a no-op. Nothing in the build catches this for you. Set the
song to 3 PSGs in Arkos Tracker and leave the channels you do not want
empty - unused channels cost nothing and stay silent. (A streamed
`STREAM_NNN.aks` is not restricted this way; the rule is the resident
player's.)

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

**Size.** A WAV's audio payload may be at most **1 MB**. That ceiling is
checked before any memory is claimed, so a bigger file is refused
outright however much memory is free. Below it there is no fixed
per-sample buffer - samples load into whatever memory is free - and as a
working rule **up to 48K always fits**, on any machine, whatever else is
loaded. Between 48K and the ceiling a sample competes with picture
caching and streamed songs for the remaining memory, so test a large one
on the memory configuration you expect players to have.

**Bringing samples over from DOS.** A DAAD Ready DOS game's `SOUNDS`
set - at most 32000 bytes per effect, sampled 5000 to 20000 Hz -
already fits every limit above, so those files drop straight in
unconverted.

**A restart does not stop the sound.** Starting over from inside the
game leaves the music and any playing sample running straight through,
the same way they survive a `SAVE` and `LOAD`. `RESTART`, a confirmed
`QUIT` and answering `END`'s prompt to play again all leave the sound
alone. Stop or change it yourself with `SFX n 7` / `SFX 0 8` and
`SFX n 5` if a new game should start quiet. Leaving the game for real -
declining the play-again prompt, `EXIT 0`, a fatal error - silences
everything.

**Repeats are free.** Only the first play of a given sample number reads
the card; the payload stays resident and plays instantly every time
after that, until a different number is asked for. A sound you fire
often costs the card read once.

**Testing samples in an emulator.** A sample playing over music drags
the music's tempo down under CSpect. That is the emulator, not your
game - on real hardware the tune holds its tempo while a sample plays.
Judge the mix on hardware before you change anything.

## BEEP tones

`BEEP` plays a single tone through the AY. Write it the way the DAAD
manual documents (see [Getting started](getting-started.md)) - duration
first, then tone - and let the compiler handle the rest.

Three rules turn a `BEEP` you wrote into silence, and none of them
raises a compile error:

- **Tones outside 48 to 238 are not tones.** The compiler rewrites any
  `BEEP` with a tone below 48 or above 238 into a `PAUSE` of the same
  duration, so it becomes a silent wait rather than a note. The whole 48
  to 238 range sounds, top octave included.
- **Tones must be even.** An odd tone is silent by design.
- **A duration of 0 does nothing at all.** A `BEEP` with duration 0
  returns immediately: no tone, and no wait either. Give every tone a
  duration of at least 1.

**Music and effects win.** `BEEP` sounds on the third AY, the same chip
the music and the sound effects use, and they have priority: a `BEEP`
asked for while a looping song or a sound effect is playing is dropped
and never sounds. The condact still blocks for its full duration, so the
timing of everything around it is unchanged - you simply hear nothing.
Use a sound effect, not a `BEEP`, for a sting over music; once a
play-once tune (`SFX n 6`) has finished, `BEEP` sounds again.

**Durations are scaled at compile time.** Both `BEEP` and `PAUSE`
durations are multiplied by this target's own note length on the way
into the database, so a duration you authored is not the duration that
ships. `XPLAY`'s generated notes are scaled the same way. If you are
copying timings out of an older DAAD or MALUVA guide, treat its duration
tables as a starting point and check the result by ear.
