# Audio

Background music, sound effects and digital samples, all from the
`AUDIO\` folder. Everything here is optional - a game with no `AUDIO\`
folder builds and plays fine.

Music and effects are selected in your game with the `SFX` condact -
the tables below list every sub-command and what it does on this
target.

## SFX sub-commands

[DAAD Ready's manual](https://www.ngpaws.com/daadready/doc_en.html)
lists, in its Appendix D, symbolic names for the sub-command
argument of `SFX` (`PLAYSFX`, `PLAYDRO`, and so on). The bundled ndrc
compiler predefines every one of them, and a DSF written with the
symbolic form compiles byte-identical to the same DSF written with
the raw number - use whichever reads better.

**Typo warning:** the DAAD Ready manual's own Appendix D table names
value 10 `FPLAYFLIL`. That is a documentation typo - `FPLAYFLIL` does
not compile. The compiler defines `PLAYFLI` (9) and `PLAYFLIL` (10).

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
| 9 | `PLAYFLI` | Play video `NNN.VID` once - the classic DOS video symbol, now real: identical to `GFX n 13`. See [Video](video.md) for cutscene playback. |
| 10 | `PLAYFLIL` | As 9, looped until a key is pressed - identical to `GFX n 14`. |

Sample numbers 1-254 may resolve to a WAV or fall back to an AY
effect; 255 is reserved and always plays from the AY effects bank.

## SFX sub-commands 11-16 (channel reservation)

These six are a NextDAAD extension - they are not in DAAD Ready's
Appendix D and the compiler predefines no symbolic names for them, so
write the raw number. They let a game reserve one of the two sample
channels for an effect rather than letting sub 1/2 pick automatically.
See [Two sample channels](#two-sample-channels) below for the full
explanation, including what a reservation does and does not survive.

| n | Behaviour on this target |
|---|---------------------------|
| 11 | Play `NNN.WAV` once, reserved to sample channel 1. |
| 12 | As 11, looped. |
| 13 | Play `NNN.WAV` once, reserved to sample channel 2. |
| 14 | As 13, looped. |
| 15 | Stop sample channel 1 and release its reservation. |
| 16 | Stop sample channel 2 and release its reservation. |

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
resampling - so pick the rate when you export. **15625 Hz is the
recommended rate**: it divides the hardware's own timing clock exactly
on six of the eight video modes, so on those modes the sample plays at
exactly the authored pitch, with no rounding at all. 16000 Hz - the
rate most existing NextDAAD samples already use - stays fully
supported: the hardware's own clock varies by video mode and 16000
rarely divides it exactly, so it plays a little sharp on most modes, up
to about 0.7% in the worst case - inaudible in a game sound effect.
Nothing about an existing WAV needs to change; 15625 Hz is only worth
picking for new samples where you want the theoretical best case.

**Samples and AY effects share one set of numbers.** `SFX n 1` looks for
`NNN.WAV` first and falls back to the effects bank if there is no such
file, so a sample and an AY effect cannot both use number 7. Numbers 1
to 254 work either way; 255 always plays from the AY bank.

## Two sample channels

Samples play on either of two independent hardware channels, mixed
together in the output and both centred, so two effects can sound at
once. `SFX n 1` and `SFX n 2` choose a channel for you automatically:

- if a channel that is not reserved (see below) is already holding
  number `n` from a previous play, it plays there again - even if that
  channel is still playing it, in which case the effect simply
  restarts in place rather than a second copy starting elsewhere;
- otherwise, an idle channel that is not reserved takes it;
- if both channels are busy, one is taken over: a channel currently
  playing a one-shot effect is taken in preference to one playing a
  loop, and between two one-shots the older one goes. A reserved
  channel (see below) is never taken over, playing or not;
- if both channels are reserved - playing or not - the new effect is
  simply dropped: nothing plays, and nothing queues.

Reserve a channel for an effect with these four sub-commands, so
nothing else can take it from under you while you need it there. Each
always takes its channel outright, stopping whatever was playing there
before, reserved or not:

| n | Effect |
|---|--------|
| 11 | Play `NNN.WAV` once, reserved to channel 1 |
| 12 | As 11, looped |
| 13 | Play `NNN.WAV` once, reserved to channel 2 |
| 14 | As 13, looped |
| 15 | Stop channel 1 and release its reservation |
| 16 | Stop channel 2 and release its reservation |

A reservation lasts until you release it with 15, 16, or `SFX n 5`
below - including if the sample failed to load. A `NNN.WAV` that turns
out to be missing still reserves the channel it was asked for, because
the reservation is made before the file is opened; release it
explicitly rather than assuming a failed play left the channel free.
`SFX 255` always plays the AY effects bank on any of these
sub-commands, and never reserves a channel either - a reservation only
ever applies to a WAV sample.

`SFX n 5` stops everything sampled - whichever effect is playing on
either channel - and the AY effect too, and releases both
reservations. It is the "make it quiet" reset to reach for between
scenes.

**A cutscene does not cost you a looping bed.** A [video](video.md)
takes the sound hardware for as long as it runs, so both channels go
quiet while it plays - but a loop that was ALREADY PLAYING when the clip
started comes back on its own channel, with its reservation intact, as
soon as the clip ends. One-shots are left stopped. There is nothing to
re-trigger afterwards.

Start the bed a turn BEFORE the video, though. An effect triggered in
the same turn as the video has not begun playing by the time the
cutscene takes the hardware, so there is nothing there to notice and
bring back: the video discards it, and the channel is silent when the
clip ends. Put the `SFX` in an earlier entry than the video and it
resumes as described.

## Length and streaming

An effect's length is no longer capped by memory - a WAV of any size
plays. Files up to 24K per channel stage entirely into a fixed area
kept for the purpose; once staged they replay instantly and for free,
however many times you trigger them and whatever else is loaded. A
larger file streams from the card as it plays instead, and the channel
that played it keeps hold of it: the allocator remembers which channel
last played the number, and a repeat trigger goes straight back to that
channel and restarts the effect from the beginning without re-opening
it or searching the card again. All a repeat costs is refilling the
channel's window - a fraction of the first play's work, and no
rummaging at all. Budget that refill for anything over 24K; anything
under it is free to fire as often as you like.

The saving only survives while the channel is still holding the file.
Play a different effect on that channel - or let the allocator steal it
for one - and the next trigger of the big effect opens the card afresh,
as the first play did.

A streamed (over 24K) looping effect has one audible quirk at the loop
point: instead of a silent gap while the next lap catches up, the last
sample briefly holds - a short click or hold rather than silence. It is
easy to miss on most material, but worth an ear check on anything that
leans on a clean loop.

**Effects split across more than 8 pieces on the card are refused
outright**, whatever their size - the same ceiling [video](video.md)
files are held to. The build stages files contiguously so this is rare
in practice, but a heavily used or badly fragmented card can produce
one. Defragment the card if a large effect will not play.

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

**A streamed effect needs real hardware to hear in full.** An effect up
to 24K - about one and a half seconds at the recommended rates - plays
completely under CSpect, so short effects develop and test fine there.
A longer effect streams from the card as it plays: under CSpect it
plays only that opening ~1.5 seconds, then stops cleanly; under
ZEsarUX it is inaudible entirely - nothing plays. A real Next plays a
streamed effect all the way through, however long it runs.

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
