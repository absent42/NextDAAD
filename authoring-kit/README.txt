NextDAAD Authoring Kit
======================

Open docs\index.html for the manual.

AI coding assistants: see AGENTS.md. The skills are in .agents\skills\.

Quick start:
  1. Populate tools\ - see tools\README.txt for what to download
  2. Run BUILD.BAT - on a fresh kit it builds the starter game, STARTER\
  3. Run RUN.BAT to play the result
  On Linux the launchers are ./build.sh and ./run.sh.
  DEBUG.BAT (./debug.sh) builds and runs the game in the debugger
  (CSpect 4.0 or later) - see docs\debugger.html.

Writing your own game:
  1. Copy STARTER\ to a folder named after your game, e.g. MYGAME\, and
     rename STARTER.DSF and STARTER.CFG inside it to MYGAME.DSF and
     MYGAME.CFG, and AUDIO\STARTER.aks and AUDIO\STARTER_FX.aks to
     AUDIO\MYGAME.aks and AUDIO\MYGAME_FX.aks (the game's music and
     sound effects). Every kit update replaces STARTER\, so never write
     your game in it.
  2. Copy CONFIG.local.BAT.sample to CONFIG.local.BAT and add
     SET GAME=MYGAME
  3. Put your game's settings in MYGAME\MYGAME.CFG and your machine's
     settings (tool folders, RUN) in CONFIG.local.BAT. Do not edit
     CONFIG.BAT: a kit update replaces it.
  4. Edit MYGAME\MYGAME.DSF and run BUILD.BAT. The game is built into
     RELEASE\MYGAME\. Copy the contents of RELEASE\ to the root of an SD
     card and launch MYGAME\MYGAME.NEX.

Updating from v0.11 or earlier: unzip this kit into a new folder, not over
the old one - see "Updating the kit" in docs\getting-started.html.

STARTER\STARTER.DSF contains some examples of NextDAAD features and externs.
Type HINT to get some pointers.

Everything else is in the manual.
