# Video delivery

## Streaming, resident and direct delivery

Resident or streamed is automatic - nothing to choose at authoring
time. A file that fits the player's RAM bank pool (about 1.2 MB on a
fresh boot) is loaded whole and played from RAM; a bigger file streams
from SD through a prefetch ring of the same banks. Either way playback
runs at true rate.

Direct-serve is the exception: it is a per-clip opt-in you set
yourself, described at the end of this section.

Because streaming has a fixed supply rate, every over-pool-size encode
has to fit it. **You do not set that budget - the encoder derives it.**
`--stream-budget` scales the encoder's per-frame quality caps to the
wire, and it is a supply ceiling rather than a quality dial: lowering it
does not compress harder, it hands the encoder fewer bytes, so more of
the picture goes unpainted and PSNR, banding and stale area all get
worse together. There is one right value per clip and it depends on the
footage, so each encode searches for it and prints what it found:

```
  auto-budget: --stream-budget 0.72 -> util 0.90 (target 0.90) - 3 probes, 41.2 s
```

The value it prints is the one to type if you ever want to reproduce
that file by hand. Passing `--stream-budget` yourself (via `VIDOPTS` or
`VIDOPTS_NNN`) overrides the search outright - which is worth doing only
to deliberately de-rate a clip, never as a guess.

The target is **0.90, not 1.00, deliberately**. The supply check is a
whole-clip mean, and a mean sitting at the ceiling still contains frames
well over it - a test clip measured at mean 0.98 has a p95 frame of 1.07
and runs of up to 19 consecutive frames over budget. On real hardware
that shows as banding and judder, so the search leaves margin for it. An
at-capacity encode is *not* "fine, the ring absorbs it"; if you set a
budget by hand and see the warning above 0.90 utilization, that warning
is telling you the picture will likely band. `--budget-target` moves the
line if you are re-deriving it against your own card.

Sometimes the search reports the clip as *content-limited*: utilization
barely responds to the budget because the footage is asking for less
than the caps allow. Cutting further would starve the picture without
relieving the wire, so it stops and keeps the bytes.

Where no budget makes a clip streamable at all, the encode is still
*refused* ("error: this encode cannot stream - mean supply utilization
N.NN > 1.00 ..."). The message shows where the time goes (decode ms + SD
fetch ms per frame period) and names the remedies that remain: a smaller
shape, a lower fps, or a shorter clip.

**Direct-serve (expert opt-in).** `--direct` (per-video via
`VIDOPTS_NNN`) writes an uncompressed encode the player serves straight
from SD to the screen - no delta decode, pixel-exact every frame. It is
never chosen for you; you ask for it. The catch is a strict at-rate
envelope with no ring to absorb bursts: at 25 fps stereo it tops out
around 256x153 (full-screen 320x256 fits at 12.5 fps), and the gate
refuses anything the SD wire cannot sustain - there is deliberately no
slow-playback opt-out (every shipped mode plays at true rate). The
refusal message prints the live envelope menu for your width: the
at-rate height, the same height with a 0.90 margin, and how far
dropping to the audio floor fps opens it (full-screen territory). For
almost all content the normal delta encoder is the better tool;
`--direct` exists for encodes that must be pixel-exact.

## Playback notes

**Game audio during playback.** A cutscene owns the sound hardware
while it plays: a sampled effect is stopped for the duration, and a
LOOPING one that was already playing when the clip started starts again
by itself the moment the clip ends - a one-shot does not, since it was
going to finish anyway; AY music is
frozen in place (paused, not stopped) and resumes automatically the
instant playback ends; and a BEEP still sounding when the video starts
is cut short, staying silent for the rest of its nominal duration
rather than resuming. No author action is needed for any of them.

A resumed loop restarts from the beginning rather than from where the
cutscene interrupted it, keeps whatever channel reservation it had, and
comes back on the same channel it was playing on. It is the second
sound to return, roughly a frame behind the music, and a loop that was
streaming from the card (over 24K) takes a moment longer while its
buffer refills. A video that refuses to play at all restores the loop
the same way.

The one case that does not resume is an effect triggered in the SAME
turn as the video. It has not started playing by the time the cutscene
takes the hardware, so the video discards it rather than let it start
underneath the clip, and there is nothing left to bring back. Trigger
the effect an entry earlier than the video and it resumes normally.

**Automatic picture restore.** When a cutscene ends, the player puts
the screen back by itself: the visible picture surface AND its palette
are snapshotted before the video starts and restored before the screen
is re-shown - no post-video redraw is needed (the starter's MOVIE verb
is just the play). Details worth knowing: the hidden back surface is
NOT preserved (its contents are undefined after a video - only matters
if a game draws there directly), the snapshot reserves a few memory
banks per session (a video refuses with `VID NOBANK2` if the memory
pool cannot cover them - on a 2MB machine that takes a heavily loaded
pool, meaning picture-cache pressure, to bite; a 1MB machine is outside
video support entirely and hits the same refusal far more readily), and
a text-only game with the picture layer hidden pays nothing. A full
redescribe (`CLS` then `RESTART`, the starter's REEL verb) remains a
scene-change choice when the story moves on - a choice, no longer a
necessity.

**Contiguity.** Videos stream from the SD card at a rate that assumes
the file is reasonably contiguous. A heavily fragmented file refuses
to play: the ceiling is 32 fragments for a clip small enough to play
from RAM (exactly 32 is fine, 33 refuses) and 8 fragments for a clip
big enough to stream - or encoded direct-serve - off the card live.
Defragment the card (or re-copy the file to a freshly formatted card)
if a video will not start or stutters.

**60Hz displays.** NXV is 50Hz-designed (frames present on the 50Hz
vblank cadence); on a 60Hz display, expect slower playback and audio
popping - an accepted limitation, not a bug to report.
