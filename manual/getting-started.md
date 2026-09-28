# Getting started

The authoring kit turns your DAAD source into a folder you copy straight
onto an SD card. It compiles the database, converts your artwork and
audio, stages the interpreter beside them, and can launch an emulator on
the result. There is nothing to assemble by hand.

## What you need

The kit runs on Windows and on Linux. The build scripts, the compiler
and the picture converter ship in the kit; the emulator, the music
converters, ffmpeg and the assembler are third-party downloads. Pick
your platform below, then read [Already have some of these?](#already-have-some-of-these).

### Windows setup

Windows 10 or 11. Windows PowerShell, which is part of Windows, runs the
build; nothing else needs installing for a text-only game.

The interpreter, `nextdaad.nex`, and the DAAD compiler,
[`NDRC`](https://condact.xyz/ndrc), as `lib\ndrc.exe`, are in the kit.
Gfx2Next and the video encoder are too. Download the rest and extract
each into the kit's `tools\` folder at the path shown:

| Tool | Provides | Extract into | Needed |
|---|---|---|---|
| Arkos Tracker 3 | `SongToAky.exe`, `SongToSoundEffects.exe`, `SongToYm.exe` | `tools\ArkosTracker3\tools\` | only with `.aks` audio |
| CSpect | emulator, to play the result without hardware | `tools\CSpect\` | to run the build |
| ffmpeg | reads your video sources | `tools\ffmpeg\` | only when encoding an `.mp4` cutscene |
| sjasmplus | Z80 assembler | `tools\sjasmplus\` | only to rebuild an extern with `EXTERNS.BAT` |

`tools\README.txt` lists the download addresses and the exact executable
paths the build checks for.

Double-click `BUILD.BAT` to build, `RUN.BAT` to play the result in
CSpect, `CLEAN.BAT` to start over.

### Linux setup

> The Linux kit is in preparation. This section describes its first
> release; until that release is published, only the Windows kit above
> is available.

x86_64 Linux with glibc 2.34 or newer: Ubuntu 22.04, Debian 12, Fedora
36 and later. Install:

- **PowerShell 7** (`pwsh`), which runs the build scripts. Microsoft
  publishes packages for every major distribution:
  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux
- **Python 3.11 or newer** with `Pillow` and `numpy`, for video
  cutscenes only: `python3 -m pip install Pillow numpy`. The tuning GUI
  also needs `PySide6`.
- **ffmpeg** from your distribution (`sudo apt install ffmpeg`), for
  video cutscenes and `MUSIC PCM` intros only.
- **Arkos Tracker 3** Linux release from https://www.julien-nevo.com/arkostracker/,
  for `.aks` music only. Extract it into `tools/ArkosTracker3/` so that
  `tools/ArkosTracker3/tools/SongToAky` exists, or set `ARKOSDIR`.
- **CSpect** Linux build from https://mdf200.itch.io/cspect plus mono
  (`sudo apt install mono-devel`), to play the result. Extract into
  `tools/CSpect/`; `run.sh` starts it as `mono CSpect.exe`.
- **sjasmplus** (`sudo apt install sjasmplus`, or build it from
  https://github.com/z00m128/sjasmplus), only to rebuild an extern with
  `externs.sh`.

The interpreter, the compiler (`lib/ndrc`) and Gfx2Next
(`tools/gfx2next/gfx2next`) ship in the Linux kit. A tool that is on
your `PATH` is found without any setting; a tool under `tools/` is
found there; `CONFIG.BAT` points anywhere else.

Unzip the kit, then in a terminal:

    cd NextDAAD-AuthoringKit
    chmod +x *.sh lib/ndrc tools/gfx2next/gfx2next   # only if your unzip dropped the execute bits
    ./build.sh
    ./run.sh

`build.sh`, `run.sh`, `clean.sh`, `externs.sh` and `vidtune.sh` are the
Linux names of the five `.BAT` launchers and take the same arguments.

Three things differ from Windows:

- **File names are case-sensitive.** Use the names this manual shows:
  `IMAGES/`, `AUDIO/`, `VIDEO/`, `001.png`, `STARTER.DSF`, `FONT.CHR`.
  A `#include` in your source must match the file's case exactly and
  use `/` between folders.
- **Build on a local Linux filesystem** (ext4, btrfs, xfs). A FAT or
  exFAT USB stick, a network share or a Docker bind mount of a Windows
  folder cannot keep the file times the incremental build relies on,
  and the build refuses to run there.
- **`CONFIG.BAT` keeps its name.** It is a plain settings file of
  `SET NAME=value` lines that the scripts read; nothing executes it.
  Paths in it may use `/`.

### Already have some of these?

Arkos Tracker, CSpect and ffmpeg are general-purpose tools you may well
have installed already, and there is no need for a second copy.
`CONFIG.BAT` has a directory setting per tool - `ARKOSDIR`, `CSPECTDIR`,
`FFMPEGDIR`, `GFXDIR`, `SJASMPLUSDIR` - and each one you set is used
instead of the folder under `TOOLSDIR`. Anything you leave blank still
comes from `TOOLSDIR`, so mixing the two is fine: keep the small stuff
in `tools\` and point the big installs wherever they already are.
Absolute paths, including ones with spaces, are fine:

    SET CSPECTDIR=C:\Emulators\CSpect
    SET ARKOSDIR=C:\Program Files\Arkos Tracker 3
    SET FFMPEGDIR=/usr/bin

Point each at the folder the tool was installed into. Arkos Tracker and
ffmpeg keep their programs in a subfolder (`tools\` and `bin\`); either
the install root or that subfolder is accepted. If you keep every tool
somewhere else, point `TOOLSDIR` at that folder instead.

## Learning DAAD itself

This manual covers what is specific to the Next: the kit, the build,
and how each condact behaves on this target. It does not teach the DAAD
language. For that:

- **The [DAAD Ready manual](https://www.ngpaws.com/daadready/doc_en.html)**
  covers the DSF source format, the condact set, the system flags and
  the symbol tables. It is the go-to reference to write your adventure against.
- **The original DAAD manual** is in the `Docs` folder of the
  [DAAD project](https://github.com/daad-adventure-writer/daad) (or a hardcopy is available [here](https://www.lulu.com/shop/tim-gilberts/aventuras-ad-daad/paperback/product-186692n7.html)), it is
  the fuller treatment of the language, worth reading once you know your
  way around the DAAD Ready manual.

The kit compiles your DSF with its own bundled
`NDRC` (Next DAAD Reborn Compiler). If a `CONFIG.local.BAT` from an older kit still sets `DAADDIR` or
`DRCDIR`, it is safe to delete those lines - neither setting is read
any more since it migrated from DRC to NDRC.

## Setting up an editor

Any text editor can write a `.DSF` file, but a few tools make the job
easier:

- **[VS Code](https://code.visualstudio.com/)** is a good general-purpose
  editor for DAAD source - free, cross-platform, and with an extension
  marketplace covering the two tools below.
- **[DAAD-DSF](https://condact.xyz/daad-vs)** is a VS Code
  extension for the DSF source format: syntax highlighting for the
  condact set, messages and object definitions, plus checking that flags
  potential compiler and structural problems before you run a
  build. Install it from Github releases page in the repository
  above.
- **[git](https://git-scm.com/)** tracks changes to your source as you
  write it, giving you a history to fall back on and, if you keep it on
  GitHub or similar, a backup off your own machine. In VS Code's terminal 
  type `git init` initialise the tracking.

None of this is required - the build only reads the files described
below, however they were written.

For a step-by-step tutorial on setting up a dev environment, please 
see the [condact.xyz](https://condact.xyz/nextdaad/tutorials/dev-environment) website.

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
| `COLS` | Text columns your game is authored for. Blank = 80 (the default), or `40` for the double-width 40-column mode. Sets the compiler's `-cols` option - the interpreter still boots at 80, so a 40-column game must issue `GFX 1 18` in its init process. See [Graphics](graphics.md). |
| `TOOLSDIR` | Folder holding the tools above. Default `tools`. |
| `GFXDIR`, `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR` | Where each individual tool lives. Blank means "the folder under `TOOLSDIR`", so leave them alone for the simple layout and set only the ones you keep elsewhere. See [What you need](#what-you-need). |
| `VIDTOOLSDIR` | Same, for the folder holding `videnc.exe` and `vidtune.exe`, which the kit ships. You should not need to set this. On Linux the encoder runs from `lib\videnc.py` and this setting is unused. |
| `NDRCVER` | Normally unset: the compiler version the kit was tested against is pinned in `lib\toolversions.txt` and the build refuses any other. Set it only alongside your own `NDRC` override. |
| `NEXFILE` | The interpreter to ship. Default `nextdaad.nex`. |
| `NEXTDAWDIR` | Your NextDAW install, only for `MUSIC NDR` in a [loader intro](intro.md). |
| `INTRONEX` | The loader intro launcher to ship. Default `intro.nex`. |
| `VIDASPECT`, `VIDFPS`, `VIDOPTS`, `VIDOPTS_NNN` | Cutscene encoding - see [Video](video.md). |

**Local overrides.** If a file named `CONFIG.local.BAT` sits beside
`CONFIG.BAT`, it is loaded straight after it, so anything it sets wins.
Put settings that belong to your machine rather than to the game there -
a different `TOOLSDIR`, or `RUN=0` for an unattended build - and
`CONFIG.BAT` stays as the settings you would hand to someone else along
with the game.

## Build and run

- **`BUILD.BAT`** (Linux: `./build.sh`) - compiles the database, converts
  graphics and audio, encodes any new video, copies the interpreter,
  and launches CSpect if `RUN=1`. It finishes with
  `BUILD OK: RELEASE\ is ready to copy to an SD card`.
- **`RUN.BAT`** (`./run.sh`) - launches CSpect on whatever is already in
  `RELEASE\`, without rebuilding.
- **`CLEAN.BAT`** (`./clean.sh`) - empties `RELEASE\`. The next build
  then converts everything from scratch.

Each launcher is a few lines that start the matching script in `lib\`
(`build.ps1`, `run.ps1`, `clean.ps1`); the build itself is the same
code on both platforms.

The build stops at the first error, with a message naming the cause.

Pictures, sprite sets, sounds, tunes and video are only converted or
copied when their source has changed since the last build. Everything
else in `RELEASE\` is left as it is, so a game with hundreds of pictures
rebuilds in seconds. A file counts as changed when its size or modified
time differs, including a file replaced by an older copy. Updating the
kit or a conversion tool also converts everything again. The build
deletes the output of any picture or tune you remove from the kit
folder, so nothing lingers on the card from an earlier build.

Your database is compiled as DAAD version 3. If you are bringing in a
game written for version 2, three behaviours change silently - see
[DAAD V3](daad-v3.md).

## What comes out

`RELEASE\` is the finished SD card image. Copy its **contents** (not the
folder) to the root of the card. It holds:

- `nextdaad.nex` - the interpreter, the file you launch.
- `<GAME>.NEX` and `INTRO\` - the loader intro, when you ship one; launch
  `<GAME>.NEX` instead. See [Loader intro](intro.md).
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
Try the verbs `MUSIC`, `MUTE`, `TUNE`, `BLEEP`, `ZAP`, `SAMPLE`, `MOVIE` and `REEL`.

## When the build fails

| Message | What to do |
|---|---|
| `set GAME in CONFIG.BAT` | The kit folder holds no `.DSF`, or more than one. Set `GAME` to the base name of the one you want. |
| `differ only by case - keep one` | Two files in the kit folder have names that differ only in letter case. Windows treats them as one file and Linux as two; rename one. |
| `does not keep sub-microsecond file times` | The kit folder is on a FAT, exFAT, network or bind-mounted drive. Move it to a local NTFS or ext4 folder. |
| `required tool missing` | The named path does not exist. Install that tool there, or fix `TOOLSDIR` / `NEXFILE`. |
| `wrong DAAD compiler version` | The banner `lib\ndrc.exe` prints does not match the version pinned in `lib\toolversions.txt`. This should not happen with the kit as shipped; if you have replaced `ndrc.exe` yourself, set `NDRCVER` in `CONFIG.local.BAT` to match. |
| `CSpect is running - close it before building` | CSpect holds the `RELEASE\` files open. Close it and build again. |
| `ndrc failed compiling` | The compiler rejected your source. Its own output above the message names the line. |
| `WARNING: #include ... case differs` | The included file exists, but its name on disk is spelled with different capitals from the `#include` line. Windows opens it anyway; Linux will not. Match the case. |
| `GAME.DDB is N bytes, over the 65535 limit` | The database is too large. 64K is the format's own ceiling - see [Limits](reference/limits.md), which suggests where to cut. |
| `uses #classic, which NextDAAD does not support` | Remove the `#classic` line from your source. It tells the compiler to imitate the original pre-DRC DAAD compiler, for the benefit of interpreters that cannot read a NextDAAD database in any case; here it only makes the database bigger. |
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
| `NextDAAD: DDB wrong machine - E4` | `GAME.DDB` is a perfectly good database, but it was compiled for a different computer - CPC, C64, MSX, PC or another. Recompile it for the Spectrum: the kit's own build already does, so this normally means a `.DDB` arrived from somewhere else. Spanish and English databases are both fine; it is the machine that is wrong, not the language. |
| `NextDAAD: RUNTIME ERROR - E<n>` | The engine hit a fault while running your game. The digit names it: 1 is an invalid location and 4 a nested `DOALL`, both covered in [Known differences](known-differences.md) and [Platform notes](platform-notes.md); 5 is a version 3 opcode in a version 2 database, see [DAAD V3](daad-v3.md). |
| `NextDAAD: RD STACK - E9` | The text reader ran out of nesting depth. This should not happen with a database this kit compiled - if it does, it is worth reporting. |

Once a build runs, the game itself may still behave differently from how
it did on another DAAD interpreter. [Platform
notes](platform-notes.md) is the place to look first.
