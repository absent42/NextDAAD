# NextDAAD - ZX Spectrum Next DAAD interpreter

NextDAAD runs [DAAD](https://github.com/daad-adventure-writer/daad) text
adventures on the ZX Spectrum Next. It is written in Z80 assembly using
the Next's extended instruction set.

In addition to the standard DAAD features it adds Layer 2 location pictures 
up to 320x256 in 8-bit colour, full-screen video cutscenes with sound, AY music and
sampled sound effects across the Turbo Sound Next's three chips and DACs,
an 80-column tilemap based text display with switchable fonts, mouse input, 
and games that span several databases.

An [authoring kit](#for-authors) ships alongside it, so writing a game
for NextDAAD means just editing your source and double-clicking one batch file.

## Requirements

- A ZX Spectrum Next (or an emulator) with an SD card. Video
  cutscenes need 2MB of RAM and a real machine, and so does a sampled
  effect longer than 24K - everything else, including shorter effects,
  runs under emulation.
- A DAAD DSF source file or a compiled DAAD database, and its assets on the card. The authoring kit builds one for you, and existing version 2 and version 3 databases both run as they are.

## Features

- **Location graphics** - 256x192 and 320x256 pictures in Layer 2's
  8-bit colour modes, each with its own palette, optionally
  ZX0-compressed, drawn through a bank-allocated cache and a
  double-buffered surface
- **Title screens** - a picture shown at boot over the theme music,
  needing no changes to your game
- **Video cutscenes** - NXV, NextDAAD's own delta-video format, played
  full screen at true rate with synchronised digitised audio, streamed
  from the card when a clip is too big to hold in RAM
- **AY music** - interrupt-driven Arkos playback over the Turbo Sound
  Next's three PSGs, resident or streamed from the card, with boot
  autoplay and the classic `BEEP` tone
- **Sound effects and samples** - Arkos AY effects, plus 8-bit WAV
  samples of any length via card streaming, on two concurrent DAC
  channels that auto-allocate with stealing or pin outright, looping
  ones resuming after a video
- **80x32 text** - a tilemap text driver with per-character colour and
  its own 80-column font
- **Custom fonts and pointers** - drop in a `FONT.CHR` or a
  `POINTER.SPR` and the interpreter picks them up at boot, and a game
  can switch between up to ten of each while it runs
- **Mouse input** - Kempston mouse with a hardware sprite pointer
- **Multi-part games** - switch between databases at runtime with flags
  and objects intact, with per-part assets and saves that load from any
  part
- **The full engine** - all 128 condacts, the eight-window system, the
  vocabulary parser with multi-command sentences, the object model,
  `SAVE`/`LOAD` and `RAMSAVE` to the card, and the DDB text reader
- **The Next's memory** - RAM detection and an 8K bank allocator across
  the extended memory map

## For authors

`authoring-kit\` is a DAAD-Ready-style workflow. Drop in a `.DSF`, add
PNG artwork, Arkos music and MP4 cutscenes if you want them, and
double-click `BUILD.BAT`: it compiles the database, converts every
asset, and leaves a `RELEASE\` folder to copy straight onto an SD card. A
starter game ships with it so a first build works before you have written
anything.

**The manual is the documentation for all of this.** Open
[`authoring-kit\docs\index.html`](authoring-kit/docs/index.html) - or
read the same pages on GitHub from [`manual/index.md`](manual/index.md),
which is where they are written and where corrections go.

The kit needs a few third-party tools it cannot redistribute:

- [DAAD Ready](https://www.ngpaws.com/daadready/) - the DRC compiler and PHP
- [Gfx2Next](https://www.rustypixels.uk/gfx2next/) - PNG to Layer 2 pictures
- [Arkos Tracker 3](https://www.julien-nevo.com/arkostracker/index.php/download/) - music and sound effects
- [CSpect](https://mdf200.itch.io/cspect) - emulator, to play the result
- [ffmpeg](https://ffmpeg.org/) - only for encoding cutscenes

A packaged kit, holding only what an author needs, is on the
[releases](https://github.com/absent42/NextDAAD/releases) page.

## Building the interpreter

If you wish to modify or build your own version of the interpreter rather than
using the pre-built version included in the authoring kit, the toolchain lives in
`tools\` and is not part of the repository:
[sjasmplus](https://github.com/z00m128/sjasmplus),
[CSpect](https://mdf200.itch.io/cspect),
[DeZog](https://github.com/maziac/DeZog),
[Gfx2Next](https://www.rustypixels.uk/gfx2next/),
DRC via [DAAD Ready](https://www.ngpaws.com/daadready/).

```
powershell -File build.ps1            # debug build
powershell -File build.ps1 -Release   # release build
powershell -File build.ps1 -Run       # build, then launch CSpect
powershell -File build.ps1 -Clean
```

A debug build carries an on-screen diagnostic console and SLD data for
source-level debugging in DeZog. VS Code tasks wrap the same script.

`tests\build-tests.ps1` compiles the test databases and stages a card
folder for whichever leg you ask for - the condact suite, the fixtures,
or a full corpus game. Its switches are documented in the script itself.

`build.ps1 -Kit` assembles the authoring kit, which includes generating
`authoring-kit\docs\` from `manual\` with `scripts\build_manual.py`. Edit
the Markdown, never the generated HTML.

## Acknowledgments

- [Tim Gilberts](http://www.gilsoft.co.uk/) for writing the original [DAAD](https://github.com/daad-adventure-writer/daad)
- [Andres Samudio](https://elviejoarchivero.com/) of Aventuras AD for contributing DAAD to the public domain
- [Uto](https://uto.speccy.org/) for creating [DRC](https://github.com/Utodev/DRC) and [DAAD Ready](https://github.com/Utodev/DAAD-Ready) which influenced a lot of this project
- NataliaPC for creating [MSX2DAAD](https://github.com/nataliapc/msx2daad) which inspired this project
- Julien Nevo for [ArkosTracker](https://www.julien-nevo.com/arkostracker/)
- em00k for [playwav32](https://github.com/em00k/playwav32) which informed the sample sound playback method
- Rusty Pixels for [Gfx2Next](https://www.rustypixels.uk/gfx2next/)
- Mike Dailly for [CSpect](https://mdf200.itch.io/cspect)
- z00m for [sjasmplus](https://github.com/z00m128/sjasmplus)
- Stefan Vogt for [The Curse of Rabenstein](https://github.com/ByteProject/Rabenstein) which was used during development testing
- tadaskay for the [mouse pointer sprite](https://tadaskay.itch.io/pixelated-cursors-16x16)

## Licence

MIT - see [LICENSE](LICENSE).

## Changelog

[CHANGELOG.md](CHANGELOG.md) records what changed in each version.

## Disclaimer

The development of NextDAAD is largely AI agent driven.
