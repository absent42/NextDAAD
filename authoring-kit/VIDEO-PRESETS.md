# NextDAAD video presets - choosing a route for your clip

The kit can encode the same piece of footage two completely different
ways, and on this hardware that choice decides more about how a
cutscene looks than every other setting put together. Pick the right
route and the defaults are usually enough. Pick the wrong one and no
amount of tuning rescues it.

This page is the routing decision first, then a set of ready-made
settings to copy, then what to do about what you actually see on
screen. For what each individual setting means, the full shape table
and the delivery mechanics, see `SETUP.md`, "Video cutscenes".

Everything below assumes your footage is in `VIDEO\` named by video
number - `VIDEO\001.mp4`, `VIDEO\002.mp4` - and played from your DSF
with `GFX n 13` (once) or `GFX n 14` (loop).

---

## 1. The two routes

**Compressed** is the default and needs no options. It sends only
what changed between frames, so it is very efficient on footage that
largely holds still, and it can run at the full 25 fps at the full
320x256 screen size on that kind of material. Its weakness is fine
detail moving everywhere at once: when the frame asks for more than
the card can deliver, parts of the picture are left to catch up on a
later frame, and that shows as **banding** - stripes or blocks that
lag behind the rest of the image, usually vertical on the full-width
shapes and most obvious in water, weather and gradients.

**Uncompressed** (`--direct`) sends every frame whole, straight from
the card to the screen. It cannot band, because nothing is ever left
behind - every pixel of every frame is exactly what the encoder
produced. Its weakness is size: it costs about 1 MB for every second
of screen time, which limits both how long a clip can be and how much
picture you can have at 25 fps.

Neither route is "better". They fail in different directions, and the
footage decides which failure you would rather have.

---

## 2. Pick your route in 30 seconds

Answer these in order and stop at the first one that fits.

1. **Is the clip longer than about 15 seconds?**
   Compressed. Uncompressed clips cannot reach that length at full
   screen, and not much beyond it at any shape (section 6). Go to
   **Preset 5**.

2. **Does the picture mostly hold still?** A slow zoom, a slow pan, a
   held shot, a talking head, a title card, a mostly-static scene with
   one thing moving in it.
   Compressed, at full screen, at 25 fps. This is the cheapest good
   result in the kit and it is already the default. Go to
   **Preset 1**.

3. **Is fine detail moving across the whole frame?** Water, rain,
   falling snow, smoke, foliage, crowds, a camera moving over textured
   ground. This is the class compressed video handles worst, and the
   one where uncompressed wins outright.
   Then ask which you would rather keep:
   - **The big picture** - full 320x256, at half the motion rate. Go
     to **Preset 2**.
   - **The motion** - full 25 fps, at a smaller picture. Go to
     **Preset 3**.

4. **Is the source grainy, noisy or heavily textured?** Old film,
   high-ISO footage, heavy compression artefacts in the source.
   Whichever preset the answers above gave you, add the line from
   **Preset 4**.

5. **Anything else** - start compressed with the defaults
   (**Preset 1**). If the result bands, work down **Preset 6**.

**One thing to settle before any of this: the shape.** The encoder
centre-crops your source to whatever shape you ask for, so a 16:9
source encoded into the 4:3 `full` shape loses its sides. Choose the
shape that matches how your footage is framed first, then apply the
route. The shape names and what each one looks like are in `SETUP.md`,
"Video cutscenes", "Shapes and quality".

---

## 3. Where these settings go

Three ways to apply them, all equivalent:

**Per video, in `CONFIG.BAT`.** Set `VIDOPTS_NNN` for the video
number, and the next build re-encodes that clip:

```
SET VIDOPTS_001=--direct --shape full --fps 12.5
```

This is the normal place for anything in this document, because these
are per-clip decisions - one cutscene may want one route and the next
another. `VIDASPECT`, `VIDFPS` and `VIDOPTS` apply to *every* clip in
the game, so use those only for something you genuinely want
everywhere.

**By hand**, for a one-off encode or to cut a clip from a longer
source:

```
tools\videnc\videnc.exe source.mp4 VIDEO\001.vid --direct --shape full --fps 12.5 --start 00:01:12 --duration 8
```

Keep the source file outside `VIDEO\` when you do this. The build
re-encodes any `VIDEO\NNN.mp4` whose settings it does not recognise, so
a `VIDEO\001.mp4` sitting next to your hand-made `VIDEO\001.vid` will
overwrite it on the next build. A `.vid` with no `.mp4` beside it is
used exactly as you made it.

**In the tuner.** `VIDTUNE.BAT` puts the same settings behind a
preview window; when you accept an encode it writes the matching
`VIDOPTS_NNN` line into `CONFIG.BAT` for you.

**Before you drop your own footage into `VIDEO\001.mp4` or `002.mp4`,
read the `VIDOPTS_NNN` lines already in `CONFIG.BAT`.** Those were
written for the demo clips that ship with the kit. Options that suited
a cartoon will not suit your footage, and they apply silently to
whatever file you put in that slot. Delete or replace them.

---

## 4. The presets

Each one is a complete answer for a class of footage. Copy the
`CONFIG.BAT` line, adjust the video number, build.

### Preset 1 - Quiet scene

**For:** slow zooms and pans, held shots, talking heads, title cards,
establishing shots, anything where most of the frame is the same from
one moment to the next.

```
SET VIDOPTS_001=
```

Nothing at all - the kit defaults are the right answer for this
material. Full 320x256, 25 fps, stereo.

Optional, and worth trying on this class if the motion is continuous
(a zoom or pan that never stops rather than a static shot):

```
SET VIDOPTS_001=--tile-slack 0.5
```

**You get:** the whole screen, at full motion rate, with room to
spare. Footage in this class typically uses less than half of what the
card can deliver, so the picture is not fighting for space.

**You pay:** nothing. Do not send this kind of clip to the
uncompressed route - it looks the same and costs roughly three times
the card space.

### Preset 2 - Full-screen action

**For:** detailed sustained motion filling the whole frame - sea,
weather, falling snow, crowds, smoke - where you want the picture at
full size and can accept less fluid motion.

```
SET VIDOPTS_001=--direct --shape full --fps 12.5
```

For a 16:9 source, use its own shape instead - the half-rate envelope
has room for every shape:

```
SET VIDOPTS_001=--direct --shape 16:9 --fps 12.5
```

**You get:** the full 320x256 screen with no banding whatsoever, every
frame pixel-exact. On the footage this route is meant for, the
difference is not subtle - detail that the compressed route turns into
flat stripes stays as detail.

**You pay:** two things, both real. About twice the card space of the
compressed version of the same clip, and half the motion rate - 12.5
frames a second instead of 25. Motion is noticeably less smooth. It is
still a clean cadence (12.5 divides the display rate evenly, so there
is no stutter or beat on top of the reduced rate), but it reads as
half-rate and you should look at it before committing.

Expect the encoder to print an at-capacity warning about wire
utilization on this preset. Full-screen uncompressed sits at the top
of what the card can carry, by design; that is what makes it possible
at all. It plays at rate on a healthy, defragmented card.

### Preset 3 - Action at full rate

**For:** the same detailed motion as Preset 2, when smooth movement
matters more than picture size.

```
SET VIDOPTS_001=--direct --shape 256x153
```

For a cinematic wide framing at full width instead:

```
SET VIDOPTS_001=--direct --shape 320x123
```

**You get:** the full 25 fps, no banding, every frame pixel-exact.
Motion looks the way it looked in the source.

**You pay:** the picture is smaller. `256x153` plays in the bordered
256-wide frame; `320x123` uses the full width but is heavily
letterboxed. There is no full-screen version of this preset - 25 fps
uncompressed and 320x256 do not fit down the same wire.

These two shapes are the practical maximum at 25 fps with stereo
audio. If you ask for more, the encoder refuses and prints the exact
sizes that do fit for your chosen width - use one of those.

### Preset 4 - Grainy or noisy source

**For:** film grain, sensor noise, heavy source compression, or any
footage that looks busy even where nothing is moving. Grain is motion
as far as the encoder is concerned, and it is paid for on every single
frame.

Add `--prefilter` to whichever preset you are already using - it is an
extra option, not a route of its own:

```
SET VIDOPTS_001=--shape 16:9 --tile-slack 0.5 --prefilter
```

`--prefilter` runs a light temporal denoise before encoding. It can be
given an explicit ffmpeg filter string if you want to control it, but
the bare form is deliberately conservative and is the one to try
first.

**You get:** a modest improvement on genuinely grainy material -
enough to be worth an encode, not enough to change a bad route into a
good one. Compare the two encodes before keeping it. It does most on
the compressed route, where every speck of grain is charged for on
every frame; on the uncompressed route a frame costs the same whatever
is in it, so denoising there only changes how the picture looks.

**You pay:** a little fine texture. On clean sources it takes away more
than it gives, so this is not a default.

### Preset 5 - Long cutscene

**For:** anything over about 15 seconds. Length forces the compressed
route (section 6), so the quality decision moves to the shape.

```
SET VIDOPTS_001=--shape 16:9 --tile-slack 0.5
```

Or, for a 4:3 framing that still needs the room:

```
SET VIDOPTS_001=--shape classic --tile-slack 0.5
```

**You get:** the compressed route working with headroom instead of
against a wall. A smaller shape has real room to spare where full
320x256 has none, and that headroom is what stops banding. Drop
`--tile-slack` if the clip is a series of static shots rather than
continuous movement - it does nothing there.

**You pay:** picture area. A letterboxed or bordered clip is smaller
on screen. This is the trade the compressed route offers and there is
no way around it at length.

If a long sequence really needs to be full-screen and full-motion,
consider cutting it into separate numbered clips played one after
another. Each play is its own load, so expect a beat between them -
this works for a sequence with natural cuts, not for one continuous
shot.

### Preset 6 - When it still bands

Work down this list, re-encoding and looking at each step. Stop at the
first one that fixes it. The order is cheapest-first in terms of what
it costs you on screen, not by how much each one helps - step 2 is the
biggest lever of the six, but it is also the first one that takes
something away.

1. **`--tile-slack 0.5`.** The one picture knob worth trying on any
   clip with continuous motion. Costs a little of the encoder's safety
   margin, helps pans and zooms, does nothing on static material.
   (Compressed encodes only - there is nothing for it to act on in an
   uncompressed one.)

2. **A smaller shape.** `16:9`, then `scope`, then `classic-wide`.
   This works because shape is the real problem: the full screen
   leaves nothing spare, and a smaller one has genuine room. Match the
   shape to your framing so the crop does not hurt.

3. **`--prefilter`**, if the source has any grain or noise in it
   (Preset 4).

4. **`--fps 12.5`.** Halves the motion rate and gives every remaining
   frame twice the room. The same trade Preset 2 makes, on the
   compressed route.

5. **The uncompressed route** - Preset 2 or Preset 3. If the clip is
   short enough to fit, this ends the argument: banding is not
   possible there.

6. **Shorten or re-frame the shot.** A four-second version of a
   difficult shot at a shape that works beats twelve seconds of
   stripes.

**What not to do: do not set `--stream-budget` by hand.** It is not a
quality dial. It tells the encoder how much the card can supply, and
lowering it does not compress harder - it hands the encoder less room,
so more of the picture goes unpainted and everything gets worse at
once. The encoder works out the right value for each clip and prints
it. Setting one yourself can only make the picture worse than the
encoder's own answer.

---

## 5. Matching your source's frame rate

Almost no footage is 25 fps - film is 24, most cameras and stock
libraries are 30 or 29.97 - so nearly every clip is resampled in time
on the way in. The encoder does this by blending, automatically, and
that is the right default for most material. Two overrides are worth
knowing:

| Setting | Use it for |
| ------- | ---------- |
| (nothing) | The default blend. Correct for most footage, and always correct if you are unsure. |
| `--retime mci` | Slow pans and zooms. Reconstructs the in-between motion rather than mixing two frames, and on slow-moving material that reads as smoother. Wrong for water, smoke, crowds and anything else that moves non-rigidly, where it tears. |
| `--retime drop` | Fast or heavily cut material. Picks the nearest source frame and keeps it sharp, at the cost of an uneven cadence. |

**This matters more on the uncompressed route.** Uncompressed playback
reproduces every frame exactly as the encoder made it, blended
in-between frames included, so if you can see the blend you will see it
clearly. On a slow uncompressed shot try `--retime mci`; on a fast cut
one try `--retime drop`. A source that is genuinely 25 fps already is
not touched at all and none of this applies.

---

## 6. Space on the card, and how long a clip can be

**Uncompressed costs about 1 MB for every second of screen time -
roughly 60 MB a minute** at full screen. At 25 fps that is effectively
a fixed rate whatever shape you choose, because every shape that fits
at 25 fps is already at the limit of what the card can carry. At
12.5 fps there is room below the limit, so a smaller shape genuinely
costs less.

| Preset | Shape and rate | Card space |
| ------ | -------------- | ---------- |
| 2 | 320x256 at 12.5 fps | about 1.07 MB per second |
| 2 | 320x192 at 12.5 fps | about 0.81 MB per second |
| 3 | 256x153 at 25 fps | about 1.04 MB per second |
| 3 | 320x123 at 25 fps | about 1.04 MB per second |

**Compressed clips are typically a third to a half the size of the
same footage uncompressed**, and quiet material is far cheaper still -
it varies with the content, which is the whole point of the route. The
encoder prints the finished size, and the `.vid` file in `VIDEO\` is
the file that goes on the card.

Budget accordingly. Three uncompressed cutscenes of twelve seconds
each is most of 40 MB - fine on a modern card, but it is the largest
thing in most games by a wide margin, and it is worth deciding early
which scenes deserve it.

### Clip length limit

A video file can be up to **256 MB**, and no clip may run past
**65535 frames** - roughly 43 minutes at 25 fps, 87 at 12.5. Divide
256 MB by the rate in the table above for the longest uncompressed
clip each shape can carry: **about four minutes at full screen**, and
longer at the smaller shapes. Compressed clips run at a much lower
byte rate, so the same 256 MB carries several times as much of them -
usually ten minutes or more, and the frame count only becomes the
limit on very cheap material.

You do not have to work either limit out yourself: the encoder checks
both before it writes anything, and if a clip is over it says so, and
names the longest clip your shape and frame rate can reach. Nothing it
writes is too big to play.

---

## 7. If it does not look right

**Bands or stripes across the picture.** Parts of the frame are
lagging behind, most visible in water, weather, gradients and fine
texture. This is the compressed route running out of room. Work down
Preset 6.

**Juddery or stuttering motion, at a regular beat.** The source frame
rate is being resampled badly. Check section 5 - if you have set
`--retime drop`, remove it, and if you have not set anything, try
`--retime mci` on slow material.

**Motion that steps rather than flows, but at a steady even cadence.**
A half-rate encode looks like this and is meant to - Preset 2 trades
motion for picture size on purpose. If you did not ask for
`--fps 12.5`, check that no `VIDFPS` or `VIDOPTS` line in `CONFIG.BAT`
is setting it for every clip.

**The whole clip runs slow, with the audio popping.** That is a 60Hz
display, not the encode - see the end of section 8.

**A pause, or a frame that holds, in the middle of a clip.** Usually
the card, not the encode - a fragmented file cannot be read fast
enough to keep up. Defragment the card, or copy the file onto a
freshly formatted one, and try again. If it survives that, and the
clip is uncompressed, it is sitting at the top of what your card can
deliver: move to a smaller shape or to the compressed route.

**Gradients step visibly - skies, fades, soft lighting.** Raise the
dither with `--dither 0.8`. If instead what you are seeing is the
dither pattern itself, as a fine speckle over flat areas, lower it
with `--dither 0.3`. The default is 0.5 and suits most footage.

**Everything looks worse than it did, across every clip.** Check
`VIDOPTS` and `VIDASPECT` in `CONFIG.BAT` - those apply to every video
in the game. Per-clip settings belong in `VIDOPTS_NNN`.

---

## 8. If it will not play

A cutscene that cannot start prints a short message on screen and the
game carries on without it. It is a diagnostic rather than part of the
display, so the game's own text can scroll over it a moment later -
look for it as soon as the cutscene fails to appear.

| Message | What it means |
| ------- | ------------- |
| `VID FILE?` | There is no `NNN.VID` on the card for that video number. Check the number in your `GFX n 13`, and check the file reached `RELEASE\` and then the card. |
| `VID FMT?` | The file is not a video this build can read - an old-format file, a file encoded with a newer option than the interpreter on the card supports, or a damaged copy. Re-encode it with this kit's encoder and re-copy it. |
| `VID NOBANK2` | Not enough free memory to run the cutscene. Video needs a 2MB Next; on a 2MB machine this means the game had already filled memory, so play the cutscene at a quieter moment or reduce what is loaded around it. |
| `VID SIZE?` | Too little memory was free to buffer a clip of that shape. Play the cutscene at a quieter moment, use a smaller shape, or move it to the compressed route. |
| `VID FRAG?` | The file is scattered across too many pieces on the card to be read fast enough - or it is past the 256 MB ceiling (section 6), which no card layout can describe. Defragment the card, or copy the file onto a freshly formatted one. |

If the encoder itself refuses to make the file, it says why and names
the remedies in the same breath - it will not produce a video that
cannot play. The two you are most likely to meet are a frame rate
below the audio floor (raise `--fps`, or add `--mono`) and an
uncompressed shape that will not fit at rate, which prints the exact
list of shapes that do fit at your chosen width. Take one from that
list.

Playback is designed for a 50Hz display. On a 60Hz display expect
slower playback and audio popping - that is a known limitation of the
format, not something a setting will fix.
