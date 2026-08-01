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
ffmpeg         Video decode for cutscene encoding      https://www.gyan.dev/ffmpeg/builds/ (release essentials)   tools\ffmpeg\
videnc.exe     Standalone NXV cutscene encoder         SHIPPED with this kit (first-party, built from ..\lib\videnc.py)  tools\videnc\
vidtune.exe    Per-clip video tuning GUI               SHIPPED with this kit (first-party, built from ..\lib\vidtune\)  tools\vidtune\

After extracting, these paths must exist:
  tools\DAAD-READY\TOOLS\DRC\DRF.exe
  tools\DAAD-READY\TOOLS\DRC\DRB.PHP
  tools\DAAD-READY\PHP\php.exe
  tools\gfx2next\gfx2next.exe
  tools\ArkosTracker3\tools\SongToAky.exe
  tools\ArkosTracker3\tools\SongToSoundEffects.exe
  tools\ArkosTracker3\tools\SongToYm.exe (only needed for STREAM_NNN.aks)
  tools\CSpect\CSpect.exe
  tools\ffmpeg\bin\ffmpeg.exe (only needed for VIDEO\NNN.mp4 cutscenes)
  tools\videnc\videnc.exe (only needed for VIDEO\NNN.mp4 cutscenes)
  tools\vidtune\vidtune.exe (only needed for interactive per-clip tuning)

Video cutscenes (see ..\SETUP.md "Video cutscenes") ARE built by
BUILD.BAT: drop a numeric-named source video (VIDEO\NNN.mp4) into
VIDEO\ and the build encodes it to the interpreter's native NXV v2
format, caching the result as VIDEO\NNN.vid (re-encoded only when the
.mp4 changes). A pre-encoded NXV v2 VIDEO\NNN.vid is staged as-is.
Encoding needs ffmpeg (table above) plus videnc.exe (shipped, no
Python required) - neither matters for a text/graphics/audio-only
game, so ffmpeg is the ONLY extra download for video authoring. If
videnc.exe is ever missing the build falls back to ..\lib\videnc.py,
the script it is built from (needs Python 3 + Pillow + numpy, pip
install Pillow numpy). The encode shape and options are VIDASPECT,
VIDFPS, VIDOPTS and per-video VIDOPTS_NNN in CONFIG.BAT (blank =
full-screen 320x256 at 25 fps); run the encoder by hand for per-file
control (--shape presets or WIDTHxHEIGHT, --aspect free heights,
--fps, --start/--duration clipping, --mono, --dither and more - run
it with -h, and see ..\lib\videnc-README.md). Or run VIDTUNE.BAT (kit
root) for the same per-clip control from a GUI: prefers vidtune.exe
(shipped, no Python required), falls back to ..\lib\vidtune (needs
Python 3 + PySide6, numpy, Pillow) if the exe is missing.

Older .VID files are NOT playable by this interpreter any more: the
NXV v2 rewrite (SP15) replaced NXV v1, which had replaced the six
legacy MakeVid formats (SP14a). Re-encode from the original video
source instead.
