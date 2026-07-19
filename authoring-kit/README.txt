NextDAAD Authoring Kit
======================

Quick start:
  1. Put your adventure source here as a single .DSF file (or set GAME= in
     CONFIG.BAT to its base name).
  2. Optional graphics: put PNGs in IMAGES\ named by picture number
     (e.g. 001.png). 320-wide PNGs use full-screen mode, 256-wide PNGs use
     the classic bordered mode.
  3. Optional audio: put Arkos .aks files in AUDIO\ :
       <GAME>.aks       background music (auto-plays at boot)
       NNN.aks          songs selected by SFX n 6/7
       STREAM_NNN.aks   big songs, streamed from SD (also SFX n 6/7)
       <GAME>_FX.aks    sound-effects bank
       NNN.wav          digitised samples (SFX n 1/2; supplied ready-made,
                        PCM mono 8-bit unsigned)
  4. Optional title screen: IMAGES\DAAD.png (shown at boot until a key is
     pressed). Multi-part games: see SETUP.md section 9.
  5. Double-click BUILD.BAT. Output appears in RELEASE\ - copy its contents
     to an SD card, or let CSpect launch automatically (CONFIG.BAT RUN=1).

Other scripts:
  RUN.BAT    - launch CSpect on the current RELEASE\ without rebuilding
  CLEAN.BAT  - remove RELEASE\ contents and build intermediates

A starter game (STARTER.DSF) with example graphics and audio ships with the
kit so a first build works out of the box.

For full setup instructions, tool downloads, and troubleshooting, see SETUP.md.
