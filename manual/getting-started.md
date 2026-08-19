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
| DAAD Ready | `DRF.exe`, the compiler front end, and PHP | `tools\DAAD-READY\` | always |
| NextDAAD DRC | `DRB.PHP` carrying the `NEXTDAAD` target - [absent42/DRC](https://github.com/absent42/DRC/tree/nextdaad), branch `nextdaad` | `tools\DRC\` | always, for now |
| Gfx2Next | PNG to Layer 2 picture conversion | `tools\gfx2next\` | only with an `IMAGES\` folder |
| Arkos Tracker 3 | `SongToAky.exe`, `SongToSoundEffects.exe`, `SongToYm.exe` | `tools\ArkosTracker3\tools\` | only with `.aks` audio |
| CSpect | emulator, to play the result without hardware | `tools\CSpect\` | to run the build |
| ffmpeg | reads your video sources | `tools\ffmpeg\` | only when encoding an `.mp4` cutscene |

`tools\README.txt` lists the download addresses and the exact executable
paths the build checks for. The video encoder ships with the kit, so
ffmpeg is the only extra download cutscenes need.

If you keep your tools somewhere else, point `TOOLSDIR` in `CONFIG.BAT`
at that folder instead.

**Already have some of these?** Arkos Tracker, CSpect and ffmpeg are
general-purpose tools you may well have installed already, and there is
no need for a second copy. `CONFIG.BAT` has a directory setting per
tool - `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR`, `DAADDIR`, `DRCDIR`,
`GFXDIR` - and each one you set is used instead of the folder under
`TOOLSDIR`. Anything you leave blank still comes from `TOOLSDIR`, so
mixing the two is fine: keep the small stuff in `tools\` and point the
big installs wherever they already are. Absolute paths, including ones
with spaces, are fine:

    SET CSPECTDIR=C:\Emulators\CSpect
    SET ARKOSDIR=C:\Program Files\Arkos Tracker 3

Point each at the folder the tool was installed into. Arkos Tracker and
ffmpeg keep their programs in a subfolder (`tools\` and `bin\`); either
the install root or that subfolder is accepted.

## Learning DAAD itself

This manual covers what is specific to the Next: the kit, the build,
and how each condact behaves on this target. It does not teach the DAAD
language. For that:

- **The [DAAD Ready manual](https://www.ngpaws.com/daadready/doc_en.html)**
  covers the DSF source format, the condact set, the system flags and
  the symbol tables (its Appendix D is the one these pages cite). It is
  the reference to write your adventure against.
- **The original DAAD manual** is in the `Docs` folder of the
  [DAAD project](https://github.com/daad-adventure-writer/daad). It is
  the fuller treatment of the language, worth reading once you know your
  way around DAAD Ready.

[DAAD Ready](https://www.ngpaws.com/daadready/) itself you need
installed anyway: it supplies `DRF.exe`, the compiler front end, and the
PHP that runs the back end. The back end itself comes from the NextDAAD
DRC fork above, because the `NEXTDAAD` target is not in DAAD Ready's own
DRC yet. When a release ships one that has it, point `DRCDIR` at
`%TOOLSDIR%\DAAD-READY\TOOLS\DRC` and delete `tools\DRC`.

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
  font (see [Fonts](fonts.md)) or a `POINTER.SPR` mouse pointer (see
  [Mouse](mouse.md)), or already-converted title art. These
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
| `DAADDIR`, `DRCDIR`, `GFXDIR`, `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR` | Where each individual tool lives. Blank means "the folder under `TOOLSDIR`", so leave them alone for the simple layout and set only the ones you keep elsewhere. See [What you need](#what-you-need). |
| `VIDENCDIR`, `VIDTUNEDIR` | Same, for the two tools the kit ships. You should not need to set these. |
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
| `GAME.DDB is N bytes, over the 65535 limit` | The database is too large. 64K is the format's own ceiling - see [Limits](reference/limits.md), which suggests where to cut. |
| `uses #classic, which NextDAAD does not support` | Remove the `#classic` line from your source. It tells the compiler to imitate the original pre-DRC DAAD compiler, for the benefit of interpreters that cannot read a NextDAAD database in any case; here it only makes the database bigger. |
| `no DRB.PHP at ...` | The NextDAAD DRC fork is not installed. Put it in `tools\DRC\`, or point `DRCDIR` at it. |
| `the DRC at ... has no NEXTDAAD target` | That copy of DRC is too old, or is DAAD Ready's own. Update the fork, or point `DRCDIR` at one that has the target. |
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

## When the game will not start

A build that finished can still fail on the card. These are the
interpreter's own messages. Each one paints a magenta bar right across
the top row of the screen and prints itself into it in white, so it is
legible whatever the game had drawn - and it appears in a release build
as readily as a debug one. All of them stop the interpreter; reset or
power-cycle to try again.

| Message | What to do |
|---|---|
| `NextDAAD: DDB missing - E1` | There is no `GAME.DDB` beside the interpreter, or the card could not be read at all. Copy the **contents** of `RELEASE\` to the card root, not the folder itself. |
| `NextDAAD: DDB oversize - E2` | `GAME.DDB` is larger than the interpreter will load. See [Limits](reference/limits.md). |
| `NextDAAD: DDB bad header - E3` | The file is there but is not a database this build can load - a truncated or corrupted copy, most often. Rebuild and copy it again. |
| `NextDAAD: DDB wrong machine - E4` | `GAME.DDB` is a perfectly good database, but it was compiled for a different computer - CPC, C64, MSX, PC or another. Recompile it for the Spectrum: the kit's own `ddb.bat` already does, so this normally means a `.DDB` arrived from somewhere else. Spanish and English databases are both fine; it is the machine that is wrong, not the language. |
| `NextDAAD: RUNTIME ERROR - E<n>` | The engine hit a fault while running your game. The digit names it: 1 is an invalid location and 4 a nested `DOALL`, both covered in [Known differences](known-differences.md) and [Platform notes](platform-notes.md); 5 is a version 3 opcode in a version 2 database, see [DAAD V3](daad-v3.md). |
| `NextDAAD: RD STACK - E9` | The text reader ran out of nesting depth. This should not happen with a database this kit compiled - if it does, it is worth reporting. |

Once a build runs, the game itself may still behave differently from how
it did on another DAAD interpreter. [Platform
notes](platform-notes.md) is the place to look first.
