NextDAAD Authoring Kit - Required Tools
=======================================

These tools are NOT included (they are third-party, and some may not be
redistributed). Download each and extract it into the matching folder below,
then double-click BUILD.BAT in the kit root. See ..\SETUP.md for full details.

Tool           Provides                                Download                                                   Extract into
-------------  --------------------------------------  ---------------------------------------------------------  --------------------------
DAAD Ready     DRC compiler (DRF.exe, DRB.PHP) + PHP   https://www.ngpaws.com/daadready/                          tools\DAAD-READY\
Gfx2Next       PNG to Layer 2 conversion               https://www.rustypixels.uk/gfx2next/                       tools\gfx2next\
Arkos Tracker  SongToAky/SongToSoundEffects/SongToYm   https://www.julien-nevo.com/arkostracker/index.php/download/  tools\ArkosTracker3\tools\
CSpect         Emulator for testing                    https://mdf200.itch.io/cspect                              tools\CSpect\

After extracting, these paths must exist:
  tools\DAAD-READY\TOOLS\DRC\DRF.exe
  tools\DAAD-READY\TOOLS\DRC\DRB.PHP
  tools\DAAD-READY\PHP\php.exe
  tools\gfx2next\gfx2next.exe
  tools\ArkosTracker3\tools\SongToAky.exe
  tools\ArkosTracker3\tools\SongToSoundEffects.exe
  tools\ArkosTracker3\tools\SongToYm.exe (only needed for STREAM_NNN.aks)
  tools\CSpect\CSpect.exe

Video cutscenes (VIDEO\NNN.vid, see ..\SETUP.md "Video cutscenes") are NOT
built by BUILD.BAT - they are pre-encoded .VID files staged as-is, like WAV
samples. Two ways to make one, neither wired into BUILD.BAT:

Tool           Provides                                Download                                                   Where
-------------  --------------------------------------  ---------------------------------------------------------  --------------------------
MakeVid        GUI .VID encoder (5 of the 6 formats)   https://github.com/em00k/MakeVid-Release                  run standalone, save output into VIDEO\
lib\videnc.py  CLI .VID encoder (all 6 formats)        shipped with this kit                                      ..\lib\videnc.py

MakeVid 1.77's "with palette" formats (0/2/4) are currently broken (raw
RGB24 pixel data, never palette-indexed) - use its non-palette formats
(1/3/5), or use lib\videnc.py for every format including palette, which
is proven correct. lib\videnc.py needs Python 3, Pillow (pip install
Pillow) and ffmpeg (default path tools\ffmpeg\bin\ffmpeg.exe, override
with --ffmpeg PATH) - not required for a text/graphics/audio-only game,
only if you author video cutscenes.
