# Getting started

The authoring kit turns your DAAD source into a folder you copy straight
onto an SD card. It compiles the database, converts your artwork and
audio, stages the interpreter beside them, and can launch an emulator on
the result. There is nothing to assemble by hand.

## What you need

Windows: the build scripts are Windows batch files.

The interpreter itself, `nextdaad.nex`, already sits in the kit folder.
The tools below do not - they are third-party, and some may not be
redistributed. Download each and extract it into the kit's `tools\`
folder at the path shown.

| Tool | Provides | Extract into | Needed |
|---|---|---|---|
| DAAD Ready | the DRC compiler (`DRF.exe`, `DRB.PHP`) and PHP | `tools\DAAD-READY\` | always |
| Gfx2Next | PNG to Layer 2 picture conversion | `tools\gfx2next\` | only with an `IMAGES\` folder |
| Arkos Tracker 3 | `SongToAky.exe`, `SongToSoundEffects.exe`, `SongToYm.exe` | `tools\ArkosTracker3\tools\` | only with `.aks` audio |
| CSpect | emulator, to play the result without hardware | `tools\CSpect\` | to run the build |
| ffmpeg | reads your video sources | `tools\ffmpeg\` | only when encoding an `.mp4` cutscene |

`tools\README.txt` lists the download addresses and the exact executable
paths the build checks for. The video encoder ships with the kit, so
ffmpeg is the only extra download cutscenes need.

If you keep your tools somewhere else, point `TOOLSDIR` in `CONFIG.BAT`
at that folder instead.

## Where your files go

Everything the build reads lives in the kit folder:

- **Your adventure**, as a single `.DSF` file in the kit folder. With
  exactly one there, the build finds it by itself; otherwise name it in
  `GAME` in `CONFIG.BAT` (base name, no extension).
- **`IMAGES\`** - location pictures as `001.png`, `002.png` and so on,
  plus `DAAD.png` for a title screen. See [Graphics](graphics.md) for
  the art rules.
- **`AUDIO\`** - Arkos `.aks` music and effects, and `.wav` samples. See
  [Audio](audio.md).
- **`VIDEO\`** - cutscene sources as `001.mp4` (or a pre-encoded
  `001.vid`). See [Video](video.md).
- **Ready-made files in the kit folder itself** - a `FONT.CHR` custom
  font or a `POINTER.SPR` mouse pointer (see
  [Customising](customising.md)), or already-converted title art. These
  are copied through untouched.

A pure-text game needs none of these folders. Graphics, audio and video
are all optional and the build skips whatever is absent.

## Configuration

`CONFIG.BAT` holds every setting:

| Setting | Meaning |
|---------|---------|
| `GAME` | Base name of your `.DSF`. Blank = auto-detect the single `.DSF`. |
| `COMPRESS` | `1` = ZX0-compress pictures (smaller files); `0` = raw. |
| `RUN` | `1` = launch CSpect after a successful build; `0` = build only. |
| `TOOLSDIR` | Folder holding the tools above. Default `tools`. |
| `NEXFILE` | The interpreter to ship. Default `nextdaad.nex`. |
| `VIDASPECT`, `VIDFPS`, `VIDOPTS`, `VIDOPTS_NNN` | Cutscene encoding - see [Video](video.md). |

**Local overrides.** If a file named `CONFIG.local.BAT` sits beside
`CONFIG.BAT`, it is loaded straight after it, so anything it sets wins.
Put settings that belong to your machine rather than to the game there -
a different `TOOLSDIR`, or `RUN=0` for an unattended build - and
`CONFIG.BAT` stays as the settings you would hand to someone else along
with the game.

## Build and run

- **`BUILD.BAT`** - double-click it. It compiles the database, converts
  graphics and audio, encodes any new video, copies the interpreter,
  and launches CSpect if `RUN=1`. It finishes with
  `BUILD OK: RELEASE\ is ready to copy to an SD card`.
- **`RUN.BAT`** - launches CSpect on whatever is already in `RELEASE\`,
  without rebuilding.
- **`CLEAN.BAT`** - empties `RELEASE\` and clears the compiler's staged
  intermediates.

The build stops at the first error, with a message naming the cause. It
clears the converted assets out of `RELEASE\` before it starts, so a
picture or tune you delete from the kit folder cannot linger there from
an earlier build.

Your database is compiled as DAAD version 3. If you are bringing in a
game written for version 2, three behaviours change silently - see
[DAAD V3](daad-v3.md).

## What comes out

`RELEASE\` is the finished SD card image. Copy its **contents** (not the
folder) to the root of the card. It holds:

- `nextdaad.nex` - the interpreter, the file you launch.
- `GAME.DDB` - your compiled adventure.
- `0.XMB` - external message text, if your game uses XMESSAGE or XMES.
  It must stay beside `GAME.DDB`; without it those messages silently
  print nothing.
- `NNN.NX2` / `NNN.NXI` - converted location pictures, and `DAAD.NX2` /
  `DAAD.NXI` for a title screen (with a `.zx0` suffix when
  `COMPRESS=1`).
- `GAME.AKY`, `NNN.AKY`, `NNN.AYS`, `GAME.SFB`, `NNN.WAV` - converted
  and copied audio.
- `NNN.VID` - encoded cutscenes.
- `FONT.CHR`, `POINTER.SPR` - your custom font and pointer, if you
  supplied them.

## The starter game

`STARTER.DSF` ships with the kit along with example graphics, audio and
video, so a first build works before you have written anything. It shows
the Next-specific condacts in use - `PICTURE`/`DISPLAY` for location
art, `SFX` for music and effects, `BEEP` for tones, `GFX` for cutscenes.
Try the verbs MUSIC, MUTE, TUNE, BLEEP, ZAP, SAMPLE, MOVIE and REEL.

## When the build fails

| Message | What to do |
|---|---|
| `set GAME in CONFIG.BAT` | The kit folder holds no `.DSF`, or more than one. Set `GAME` to the base name of the one you want. |
| `required tool missing` | The named path does not exist. Install that tool there, or fix `TOOLSDIR` / `NEXFILE`. |
| `CSpect is running - close it before building` | CSpect holds the `RELEASE\` files open. Close it and build again. |
| `DRF failed compiling` / `DRB failed building the DDB` | The compiler rejected your source. Its own output above the message names the line. |
| `GAME.DDB is N bytes, over the 131072 limit` | The database is too large to ship. See [Limits](reference/limits.md). |
| `gfx2next not found` | Install Gfx2Next, or fix `TOOLSDIR`. |
| `expected a 320 or 256 wide PNG` | Resize the named image to exactly 320 or 256 pixels wide. |
| `must be a paletted 8-bit PNG` | Export the image again as an indexed-colour PNG. Truecolour is rejected. |
| `GAME.AKY is N bytes, over the 10208 song limit` | The tune does not fit the song slot. Shorten it, reduce channels, or stream it - see [Audio](audio.md). |
| `SongToAky not found` / `SongToYm not found` | Install Arkos Tracker 3, or fix `TOOLSDIR`. |
| `this encode cannot stream` / `cannot play at rate` | No encode of that clip fits the playback budget. Use a smaller shape, a lower frame rate, or a shorter clip - see [Video delivery](reference/video-delivery.md). |
| `audio bytes/frame ... exceeds` | The frame rate is below the floor sound needs. Raise `VIDFPS`. |
| `over the NXV player's ... ceiling` | The clip is too big or too long to play. The message names the longest clip your shape and frame rate allow. |

Warnings are different from errors. Anything about the sound-effects
bank, or about picture transparency, is advisory - the build carries on
and the game still ships.

Once a build runs, the game itself may still behave differently from how
it did on another DAAD interpreter. [Platform
notes](platform-notes.md) is the place to look first.
