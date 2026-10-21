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

On either platform, keep the kit folder on a local drive: NTFS on
Windows; ext4, btrfs or xfs on Linux. A FAT or exFAT USB stick, a
network share or a Docker bind mount cannot keep the precise file times
the incremental build relies on, and the build refuses to run there.

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
CSpect, `CLEAN.BAT` to start over. On a fresh kit the first build makes
the starter game; read [Where your files go](#where-your-files-go)
before you start your own.

### Linux setup

x86_64 Linux with glibc 2.34 or newer: Ubuntu 22.04, Debian 12, Fedora
36 and later. Follow the steps below in order, in a terminal. First the
programs the later steps use:

    sudo apt install unzip wget ca-certificates

Then install **PowerShell 7.4 or newer** (`pwsh`), which runs the build
scripts. Microsoft publishes packages for every major distribution:
https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux

Unzip the kit into its own folder and go into it. Every command from
here on runs in that folder:

    unzip NextDAAD-AuthoringKit-<version>-linux.zip -d NextDAAD-AuthoringKit
    cd NextDAAD-AuthoringKit

The interpreter, the compiler (`lib/ndrc`) and Gfx2Next
(`tools/gfx2next/gfx2next`) ship in the Linux kit. A tool that is on
your `PATH` is found without any setting; a tool under `tools/` is
found there; a setting in `CONFIG.local.BAT` points anywhere else
(see [Configuration](#configuration)). Install only the
optional tools your game uses:

- **Arkos Tracker 3** Linux release from https://www.julien-nevo.com/arkostracker/,
  for `.aks` music only. Extract the Arkos zip into `tools/`: its own
  top folder is `ArkosTracker3/`, giving
  `tools/ArkosTracker3/tools/SongToAky`. Or set `ARKOSDIR`.
- **ffmpeg** from your distribution (`sudo apt install ffmpeg`), for
  video cutscenes and `MUSIC PCM` intros only.
- **CSpect** Linux build from https://mdf200.itch.io/cspect plus mono
  (`sudo apt install mono-devel`), to play the result. Extract into
  `tools/CSpect/`; `run.sh` starts it as `mono CSpect.exe`, or set
  `CSPECTCMD` in `CONFIG.local.BAT` to run it some other way (Linux only,
  ignored on Windows).
- **sjasmplus**, only to rebuild an extern with `externs.sh`: a
  distribution package where one exists (`sudo apt install sjasmplus`
  on Debian), otherwise build it from
  https://github.com/z00m128/sjasmplus.
- **Python 3.10 or newer** with `Pillow` and `numpy`, for video cutscenes
  only, in a virtual environment - see below.

Debian and Ubuntu do not allow pip to install into the system Python,
and `python3 -m venv` needs the `python3-venv` package, so create a
virtual environment once, from inside the kit folder:

    sudo apt install python3 python3-venv
    python3 -m venv ~/nextdaad-venv
    ~/nextdaad-venv/bin/pip install -r lib/requirements.txt
    . ~/nextdaad-venv/bin/activate      # optional: only to run python3 yourself

`lib/requirements.txt` pins the `Pillow` and `numpy` versions the kit
is tested with. The scripts find `~/nextdaad-venv` on their own, so
activating it is optional; a `python3` on your PATH that already has
the packages is used first.

The video tuning window (`./vidtune.sh`) also needs PySide6. Install it
into the same venv, from inside the kit folder:

    ~/nextdaad-venv/bin/pip install -r lib/requirements-vidtune.txt

A minimal install may lack the system libraries Qt needs; on Debian
and Ubuntu, add them with:

    sudo apt install libgl1 libegl1 libxkbcommon0 libfontconfig1 libdbus-1-3 libglib2.0-0

Then build and play:

    chmod +x build.sh run.sh clean.sh externs.sh vidtune.sh lib/ndrc tools/gfx2next/gfx2next   # only if your unzip dropped the execute bits
    ./build.sh
    ./run.sh

The shipped `CONFIG.BAT` has `RUN=1`, so until CSpect is installed each
build ends with `ERROR: CSpect not found` after the build succeeds; set
`RUN=0` in `CONFIG.local.BAT` to build without an emulator.

On a fresh kit the first build makes the starter game; read
[Where your files go](#where-your-files-go) before you start your own.

`build.sh`, `run.sh`, `clean.sh`, `externs.sh` and `vidtune.sh` are the
Linux names of the five `.BAT` launchers and take the same arguments.

Two things differ from Windows:

- **File names are case-sensitive.** Use the names this manual shows:
  `IMAGES/`, `AUDIO/`, `VIDEO/`, `001.png`, `STARTER.DSF`, `FONT.CHR`.
  An `#include` or `#incbin` in your source must match the file's case
  exactly and use `/` between folders.
- **`CONFIG.BAT` keeps its name**, and so does `CONFIG.local.BAT`.
  They are plain settings files of `SET NAME=value` lines that the
  scripts read; nothing executes them. Paths in them may use `/`.

### Already have some of these?

Arkos Tracker, CSpect and ffmpeg are general-purpose tools you may well
have installed already, and there is no need for a second copy.
There is a directory setting per tool - `ARKOSDIR`, `CSPECTDIR`,
`FFMPEGDIR`, `GFXDIR`, `SJASMPLUSDIR` - and each one you set in
`CONFIG.local.BAT` is used
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

Each game lives in its own folder inside the kit folder, called its
**game folder**. The folder and the game's source file share one name:
the game `MYGAME` is `MYGAME\MYGAME.DSF`. One kit can hold any number of
games side by side, and you tell the build which one to work on (see
[Choosing the game](#choosing-the-game)).

The kit ships one game folder, `STARTER\`, holding the starter game.
On a fresh kit with nothing configured, `BUILD.BAT` builds it and runs
it, so you can check your setup before you write anything.

**Copy `STARTER\` before you write your game.** Every kit update
replaces `STARTER\` completely, so anything you change inside it is lost
at the next update. To start from the starter game, copy it to a game
folder of your own first, then edit and build the copy, never
`STARTER\STARTER.DSF` itself. While `STARTER\` is the game being built,
the build reminds you of this every time:

    WARNING: STARTER\ is replaced by every kit update - copy it to your own game folder before writing a game (see Getting started).

The build still succeeds. A game folder named `STARTER` is always
treated as the shipped starter - the warning prints and vidtune will not
save there - so give your own game any other name.

Everything the build reads for a game is inside its game folder:

- **`<GAME>.DSF`** - your adventure. Files it `#include`s or `#incbin`s
  are looked up inside the game folder too.
- **`<GAME>.CFG`** - this game's own settings (see
  [Configuration](#configuration)). Optional.
- **`IMAGES\`** - location pictures as `001.png`, `002.png` and so on,
  plus `DAAD.png` for a title screen. See [Graphics](graphics.md) for
  the art rules.
- **`AUDIO\`** - Arkos `.aks` music and effects, and `.wav` samples. See
  [Audio](audio.md).
- **`VIDEO\`** - cutscene sources as `001.mp4` or `001.mkv` (or a
  pre-encoded `001.vid`). See [Video](video.md).
- **Ready-made files in the game folder itself** - a `FONT.CHR` custom
  font (see [Fonts](fonts.md)) or a `POINTER.SPR` mouse pointer (see
  [Mouse](mouse.md)), or already-converted title art. These
  are copied through untouched.
- **`INTRO.TXT`**, **`HINTS.TXT`**, **`GAME.XBN`**, **`PART2\`** to
  **`PART9\`** - a [loader intro](intro.md), hints and other
  [externs](externs.md), and the extra parts of a
  [multi-part game](multi-part-games.md), when your game has them.

A pure-text game needs only its `.DSF`. Graphics, audio and video are
all optional and the build skips whatever is absent. A game folder is
self-contained: the build never looks in the kit folder or in another
game folder for a file your game is missing, so a new game cannot pick
up the starter's pictures or tunes by accident.

Everything else in the kit folder - the launchers, `CONFIG.BAT`,
`lib\`, `docs\`, `externs\`, `tools\` and the rest - belongs to the kit.
[Updating the kit](#updating-the-kit) lists what an update replaces.

### Starting a new game

1. Copy the `STARTER\` folder to a new folder named after your game,
   say `MYGAME\`. In the copy, rename `STARTER.DSF` to `MYGAME.DSF` and
   `STARTER.CFG` to `MYGAME.CFG`.
2. Copy `CONFIG.local.BAT.sample` in the kit folder to
   `CONFIG.local.BAT`, open it, and add the line `SET GAME=MYGAME`.
3. Put your game's own settings in `MYGAME\MYGAME.CFG`. Leave the
   kit's `CONFIG.BAT` alone.
4. Edit `MYGAME\MYGAME.DSF` and build it with `BUILD.BAT`. Do not edit
   the files in `STARTER\`.

The starter's pictures, audio and video come along in the copy. Keep
what you want and delete or replace the rest. `MYGAME.CFG` holds
`VIDOPTS_001` and `VIDOPTS_002` lines tuned for the starter's two demo
clips; delete them when you replace those clips with your own.

### Choosing the game

Name the game to build in `CONFIG.local.BAT`, one `SET GAME=` line per
game you have, with all but one turned off by `REM`:

    REM SET GAME=MYGAME1
    SET GAME=MYGAME2

To switch games, move the `REM`. `GAME` is the name of the game folder
(and of the `.DSF` inside it), with no extension.

When `GAME` is blank, the build looks for something it can pick without
being told:

- if the kit folder itself holds exactly one `.DSF`, it builds that game
  in the old single-game layout (see
  [Updating the kit](#updating-the-kit));
- otherwise, if the kit folder holds no loose `.DSF` and exactly one
  game folder exists, it builds that one - on a fresh kit that is
  `STARTER\`;
- otherwise it stops with `set GAME in CONFIG.local.BAT`.

So once you have copied the starter to your own folder there are two
game folders, and you need the `SET GAME=` line. The folders `PART2\` to
`PART9\` hold the extra parts of a multi-part game and are never taken
for game folders.

## Configuration

`CONFIG.BAT` in the kit folder holds every setting with its default
value and a note on what it does. It belongs to the kit and every
update replaces it, so do not edit it. Change a setting by copying its
line into one of the two files below and editing the copy:

- **`<GAME>\<GAME>.CFG`** - settings that belong to one game: `COLS`,
  `COMPRESS`, the video options, and so on. Each game keeps its own, so
  two games never share settings by accident.
- **`CONFIG.local.BAT`** in the kit folder - settings that belong to
  your machine, such as tool folders and `RUN`, plus the `GAME`
  selector. Create it from `CONFIG.local.BAT.sample` the first time.

Your own game's `.CFG` and `CONFIG.local.BAT` are never shipped with
the kit (only the starter's `STARTER.CFG` is), so an update never
touches them.
Both use the same `SET NAME=value` lines as `CONFIG.BAT`, and a line
starting `REM` is ignored, so a line copies between the three files
unchanged. The build only reads these files; it never runs them.

The settings:

| Setting | Meaning |
|---------|---------|
| `GAME` | The game to build: the name of its game folder. Set it in `CONFIG.local.BAT`. Blank = pick one automatically, see [Choosing the game](#choosing-the-game). |
| `COMPRESS` | `1` = ZX0-compress pictures (smaller files); `0` = raw. |
| `RUN` | `1` = launch CSpect after a successful build; `0` = build only. |
| `COLS` | Text columns your game is authored for. Blank = 80 (the default), or `40` for the double-width 40-column mode. Sets the compiler's `-cols` option - the interpreter still boots at 80, so a 40-column game must issue `GFX 1 18` in its init process. See [Graphics](graphics.md). |
| `TOOLSDIR` | Folder holding the tools above. Default `tools`. |
| `GFXDIR`, `ARKOSDIR`, `CSPECTDIR`, `FFMPEGDIR` | Where each individual tool lives. Blank means "the folder under `TOOLSDIR`", so leave them alone for the simple layout and set only the ones you keep elsewhere. See [What you need](#what-you-need). |
| `VIDTOOLSDIR` | Same, for the folder holding `videnc.exe` and `vidtune.exe`, which the kit ships. You should not need to set this. On Linux the encoder runs from `lib\videnc.py` and this setting is unused. |
| `NDRCVER` | Normally unset: the compiler version the kit was tested against is pinned in `lib\toolversions.txt` and the build refuses any other. Set it only alongside your own `NDRC` override. |
| `NEXFILE` | The interpreter file to ship. Default `nextdaad.nex`. The build stages it under your game's name - see [What comes out](#what-comes-out). |
| `NEXTDAWDIR` | Your NextDAW install, only for `MUSIC NDR` in a [loader intro](intro.md). |
| `INTRONEX` | The loader intro launcher to ship. Default `intro.nex`. |
| `VIDASPECT`, `VIDFPS`, `VIDOPTS`, `VIDOPTS_NNN` | Cutscene encoding - see [Video](video.md). |

**Local overrides.** The build reads three files in turn, and a later
file wins:

1. `CONFIG.BAT` - the kit's defaults.
2. `<GAME>\<GAME>.CFG` - the selected game's own settings.
3. `CONFIG.local.BAT` - your machine's settings.

Every key works the same way: the last file to set it wins, and an
empty `SET NAME=` clears the value. A line in `CONFIG.BAT` is masked
while the same key is set in either of the other two. `GAME` is the one
exception - a game's own `.CFG` cannot choose a different game, so a
`GAME` line there is ignored, with a warning naming the file.

**Copy only the lines you change.** Never copy the whole of
`CONFIG.BAT` into `CONFIG.local.BAT` or a `.CFG`. A full copy pins every
default - the compiler version, file names, tool folders - and from then
on hides any change a kit update makes to them.

vidtune saves its per-video `VIDOPTS_NNN` settings in the game's
`<GAME>.CFG`, so each game keeps its own tuning and kit updates keep
it. See [Video](video.md).

## Build and run

- **`BUILD.BAT`** (Linux: `./build.sh`) - compiles the database, converts
  graphics and audio, encodes any new video, copies the interpreter,
  and launches CSpect if `RUN=1`. It finishes with
  `BUILD OK: RELEASE\MYGAME\ is ready - copy the contents of RELEASE\ to the root of an SD card`,
  naming your game.
- **`RUN.BAT`** (`./run.sh`) - launches CSpect on the game already built
  in `RELEASE\<GAME>\`, without rebuilding. CSpect sees that folder as
  its SD card, the same shape as the folder you copy to a real card.
- **`CLEAN.BAT`** (`./clean.sh`) - empties `RELEASE\<GAME>\` for the
  selected game only; other games' output is left alone. The next build
  then converts everything from scratch.

All three work on the game `GAME` selects (see
[Choosing the game](#choosing-the-game)). Each launcher is a few lines
that start the matching script in `lib\` (`build.ps1`, `run.ps1`,
`clean.ps1`); the build itself is the same code on both platforms.

The build stops at the first error, with a message naming the cause.

Pictures, sprite sets, sounds, tunes and video are only converted or
copied when their source has changed since the last build. Everything
else in `RELEASE\<GAME>\` is left as it is, so a game with hundreds of
pictures rebuilds in seconds. A file counts as changed when its size or
modified time differs, including a file replaced by an older copy.
Updating the kit or a conversion tool also converts everything again.
The build deletes the output of any picture or tune you remove from the
game folder, so nothing lingers on the card from an earlier build.

Your database is compiled as DAAD version 3. If you are bringing in a
game written for version 2, three behaviours change silently - see
[DAAD V3](daad-v3.md).

## What comes out

Each game builds into its own folder, `RELEASE\<GAME>\`. Copy the
**contents** of `RELEASE\` (not the `RELEASE` folder itself) to the
root of the SD card, and each game arrives in a folder of its own. A
built game holds exactly two things:

- **`<GAME>.NEX`** - the file you launch.
- **`DATA\`** - everything else the game reads.

Without a [loader intro](intro.md), `<GAME>.NEX` is the interpreter
itself. With one, `<GAME>.NEX` is the intro launcher, and the
interpreter it starts is `DATA\nextdaad.nex`. Launch `<GAME>.NEX` either
way.

`DATA\` holds:

- `GAME.DDB` - your compiled adventure.
- `0.XMB` - external message text, if your game uses XMESSAGE or XMES.
  It must stay beside `GAME.DDB`; without it those messages silently
  print nothing.
- `NNN.NX2` / `NNN.NXI` - converted location pictures, `NNN.NX3` for a
  positioned picture, and `DAAD.NX2` /
  `DAAD.NXI` for a title screen (with a `.zx0` suffix when
  `COMPRESS=1`).
- `GAME.AKY`, `NNN.AKY`, `NNN.AYS`, `GAME.SFB`, `NNN.WAV` - converted
  and copied audio.
- `NNN.VID` - encoded cutscenes.
- `FONT.CHR`, `POINTER.SPR` - your custom font and pointer, if you
  supplied them.
- `GAME.XBN`, `GAME.HNT` - externs and hints, if your game has them.
- `nextdaad.nex` and `INTRO\` - the interpreter and the intro's own
  files, only when the game has a loader intro.
- `PART2\` to `PART9\` and `GAME2.DDB` onwards - the extra parts of a
  [multi-part game](multi-part-games.md).

`DATA\` is also where the game writes while it is played: save games,
and the files externs keep, such as `GAME.HPR` (hint progress),
`GAME.HST` (high scores) and `TRANS.TXT` (a transcript), all land in
`<GAME>\DATA\` on the card.

Games built by kits before v0.12.0 put every file loose at the card
root. The interpreter still runs a game laid out that way.

## The starter game

`STARTER\` ships with the kit, holding `STARTER.DSF` along with example
graphics, audio and video, so a first build works before you have
written anything. It shows the Next-specific condacts in use -
`PICTURE`/`DISPLAY` for location art, `SFX` for music and effects,
`BEEP` for tones, `GFX` for cutscenes. Try the verbs `MUSIC`, `MUTE`,
`TUNE`, `BLEEP`, `ZAP`, `SAMPLE`, `MOVIE` and `REEL`. To build on it,
copy it first - see [Starting a new game](#starting-a-new-game).

## When the build fails

| Message | What to do |
|---|---|
| `set GAME in CONFIG.local.BAT (found ... .DSF files and ... game folders here, need exactly one)` | `GAME` is blank and the build cannot pick a game by itself: there is more than one game folder, or none, or more than one loose `.DSF` in the kit folder. Add `SET GAME=` with your game folder's name to `CONFIG.local.BAT` - see [Choosing the game](#choosing-the-game). |
| `MYGAME\ has no MYGAME.DSF` / `MYGAME.DSF not found in MYGAME\ or this folder` | `GAME` names a game that is not there. The folder and the `.DSF` inside it must both carry the name `GAME` gives. |
| `WARNING: STARTER\ is replaced by every kit update` | You are building the shipped starter. Fine for a first try; to write a game, copy it first - see [Starting a new game](#starting-a-new-game). |
| `WARNING: GAME in ... .CFG is ignored` | A game's `.CFG` cannot select the game. Move the `SET GAME=` line into `CONFIG.local.BAT`. |
| `WARNING: RELEASE\ holds ... item(s) from an older kit build` | Files left loose in `RELEASE\` by a kit before v0.12.0. Delete them - see [Updating the kit](#updating-the-kit). |
| `differ only by case - keep one` | Two files in the kit folder have names that differ only in letter case. Windows treats them as one file and Linux as two; rename one. |
| `does not keep sub-microsecond file times` | The kit folder is on a FAT, exFAT, network or bind-mounted drive. Move it to a local NTFS or ext4 folder. |
| `required tool missing` | The named path does not exist. Install that tool there, or fix `TOOLSDIR` / `NEXFILE`. |
| `wrong DAAD compiler version` | The banner `lib\ndrc.exe` prints does not match the version pinned in `lib\toolversions.txt`. This should not happen with the kit as shipped; if you have replaced `ndrc.exe` yourself, set `NDRCVER` in `CONFIG.local.BAT` to match. |
| `CSpect is running - close it before building` | CSpect holds the `RELEASE\` files open. Close it and build again. |
| `ndrc failed compiling` | The compiler rejected your source. Its own output above the message names the line. |
| `WARNING: ... -> on disk as ... (case differs; Linux cannot open it)` / `WARNING: ... -> uses \ (Linux needs /)` | An `#include` or `#incbin` line names a file whose name on disk is spelled with different capitals, or separates folders with `\`. Windows builds it anyway; on Linux the same line is an `ERROR:` and the build stops. Match the case and use `/`. |
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
| `NextDAAD: DDB missing - E1` | There is no `GAME.DDB` beside the interpreter, or the card could not be read at all. The interpreter looks in the `DATA\` folder next to the `<GAME>.NEX` you launched, so keep the game's folder whole: copy the **contents** of `RELEASE\` to the card root, which puts `<GAME>.NEX` and its `DATA\` together in the game's own folder. |
| `NextDAAD: DDB oversize - E2` | `GAME.DDB` is larger than the interpreter will load. See [Limits](reference/limits.md). |
| `NextDAAD: DDB bad header - E3` | The file is there but is not a database this build can load - a truncated or corrupted copy, most often. Rebuild and copy it again. |
| `NextDAAD: DDB wrong machine - E4` | `GAME.DDB` is a perfectly good database, but it was compiled for a different computer - CPC, C64, MSX, PC or another. Recompile it for the Spectrum: the kit's own build already does, so this normally means a `.DDB` arrived from somewhere else. Spanish and English databases are both fine; it is the machine that is wrong, not the language. |
| `NextDAAD: RUNTIME ERROR - E<n>` | The engine hit a fault while running your game. The digit names it: 1 is an invalid location and 4 a nested `DOALL`, both covered in [Known differences](known-differences.md) and [Platform notes](platform-notes.md); 5 is a version 3 opcode in a version 2 database, see [DAAD V3](daad-v3.md). |
| `NextDAAD: RD STACK - E9` | The text reader ran out of nesting depth. This should not happen with a database this kit compiled - if it does, it is worth reporting. |

Once a build runs, the game itself may still behave differently from how
it did on another DAAD interpreter. [Platform
notes](platform-notes.md) is the place to look first.

## Updating the kit

To update, unzip the new kit over your existing kit folder and let it
replace files. Moving up from v0.11.x or earlier is the one exception:
see [Moving from v0.11 to v0.12.0](#moving-from-v011-to-v0120) below.

An update replaces the kit's own files and leaves yours alone.

**Replaced by every update (the kit's files):**

- `CONFIG.BAT` and `CONFIG.local.BAT.sample`
- the launchers: `BUILD.BAT`, `RUN.BAT`, `CLEAN.BAT`, `EXTERNS.BAT`,
  `VIDTUNE.BAT` (Linux: `build.sh`, `run.sh`, `clean.sh`, `externs.sh`,
  `vidtune.sh`)
- the folders `lib\`, `docs\`, `externs\` and `.agents\`
- `AGENTS.md`, `README.txt`, `xbn.inc`, `xbnmod.inc`
- `nextdaad.nex` and `intro.nex`
- `tools\gfx2next\` and `tools\vidtools\`
- `STARTER\`, the starter game

**Never shipped, so never touched (your files):**

- `CONFIG.local.BAT`
- every game folder of your own, including any extern module sources
  you keep inside it
- `RELEASE\`
- the other tools you installed under `tools\` (Arkos Tracker, CSpect,
  ffmpeg, sjasmplus)

**Where your settings belong:**

| Setting | File |
|---|---|
| A game's own settings (`COLS`, `COMPRESS`, intro and video options, `VIDOPTS_NNN`) | `<GAME>\<GAME>.CFG` |
| Machine settings (`TOOLSDIR`, tool folders, `RUN`) and the `GAME` selector | `CONFIG.local.BAT` |
| Nothing | `CONFIG.BAT` - the update replaces it |

Do not edit anything in `STARTER\`: copy it (see
[Starting a new game](#starting-a-new-game)).

**A game still in the old layout.** A game whose `.DSF` sits loose in
the kit folder, as every game did before v0.12.0, still builds. But
its pictures, audio and other files sit in the kit folder too, among the
kit's own files, and any setting you changed in `CONFIG.BAT` is lost at
the next update. The safe course is to move the game into a game folder
of its own, and any `VIDOPTS_NNN` lines into its `.CFG`, before you rely
on updates - the steps below do exactly that.

The build also warns when `RELEASE\` still holds loose files from a
build made by an older kit:

    WARNING: RELEASE\ holds 12 item(s) from an older kit build (001.NX2, 002.NX2, 003.NX2, FONT.CHR, GAME.AKY and 7 more) - delete them; each game now builds into RELEASE\MYGAME\

The build never deletes them for you. Delete them yourself, so they do
not end up on your card.

### Moving from v0.11 to v0.12.0

Do this one update into a **new, empty folder**, not over the old kit.
Unzipped over a v0.11 kit, v0.12.0 would leave the old starter files
(`STARTER.DSF`, `IMAGES\` and the rest) loose in the kit folder, and
with `GAME` blank a loose `.DSF` makes the build use the old layout.

1. Unzip v0.12.0 into a new folder beside your old kit.
2. In the new kit folder, make a folder named after your game, matching
   its `.DSF` - for `MYGAME.DSF`, make `MYGAME\`. From the old kit
   folder, copy into it: the `.DSF` and any source files it includes,
   `IMAGES\`, `AUDIO\`, `VIDEO\`, `INTRO.TXT`, `HINTS.TXT`, the `DAAD.*`
   title files, the `FONT*` and `POINTER*` files, `GAME.XBN`, and any
   `PART2\` to `PART9\` folders. Copy only the ones your game has.
3. Compare your old `CONFIG.BAT` with the `CONFIG.BAT` from the v0.11
   kit zip as it was shipped (re-download the v0.11 kit zip from the
   releases page if you no longer have it), and copy across only the
   lines you changed. Game settings (`COLS`, `COMPRESS`, intro and video options)
   go into a new `MYGAME\MYGAME.CFG`. Machine settings (`TOOLSDIR`, the
   tool folders, `RUN`) go into a new `CONFIG.local.BAT`, made from
   `CONFIG.local.BAT.sample`. The v0.11 `CONFIG.BAT` shipped
   `VIDOPTS_001` and `VIDOPTS_002` lines for the starter's demo clips;
   leave those behind unless your game uses them.
4. From your old `CONFIG.local.BAT`, if you had one: the `VIDOPTS_NNN`
   lines go into `MYGAME\MYGAME.CFG`, and machine settings go into the
   new `CONFIG.local.BAT`. Then add `SET GAME=MYGAME` to the new
   `CONFIG.local.BAT`.
5. Copy across the tools you installed under the old kit's `tools\`
   folder (Arkos Tracker, CSpect, ffmpeg, sjasmplus), unless they live
   somewhere else and `CONFIG.local.BAT` points at them.
6. Build. The video encode cache is kept in `VIDEO\` beside your clips
   (`NNN.vid` with its `NNN.vid.args`), so it moved with `VIDEO\` in
   step 2: your cutscenes do not re-encode, as long as the
   `VIDOPTS_NNN` lines you moved give the same encoder settings.
7. On the SD card, delete your game's old loose files from the card
   root, then copy the new `MYGAME\` folder from `RELEASE\`. Save games
   made with the old layout go into `MYGAME\DATA\` to stay loadable.
8. Once the new kit builds and runs your game, you can retire the old
   kit folder.

If you would rather keep your game in the old layout, do step 2 without
the game folder: copy the same loose game files straight into the new
kit folder. Skip steps 3 and 4 and keep every setting you changed in
`CONFIG.local.BAT`, the one settings file an update leaves alone. It
still builds, but moving the game into its own folder is the better
choice.
