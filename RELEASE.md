# NextDAAD Release Checklist

NextDAAD stays on a 0.x version until public testing earns v1.0. This
milestone (SP10, "compatibility and release") stamps v0.1.0 - the
first kit-complete, publicly-testable build: 128/128 condacts
handled, songs and samples bounded by available RAM rather than fixed
slots, two flagship corpus games plus a smoke set, and this checklist.
The tag/publication act itself is the owner's, done manually whenever
they choose - this file is the checklist to run through first, not an
automated release script.

## Version stamp

- Text: "NEXTDAAD V0.1.0", defined once as VERSION_STR in
  src/nextdaad.inc so both build variants share it and cannot drift
  apart.
- Printed by boot_banner (src/debug.asm) at boot, tilemap row 0, in
  BOTH the DEBUG and RELEASE build variants. It is a startup flash,
  not a persistent HUD: main.asm unconditionally clears the tilemap
  again ("Game takeover", rows 0-11) just before the engine takes
  over, in every successful boot - DEBUG included. Confirming it
  actually appears on screen (a boot-time screenshot or frame
  capture) is an owner eye leg; agents cannot launch an emulator.
- To bump the version for a future milestone, edit VERSION_STR in one
  place (src/nextdaad.inc) - both build variants pick it up
  automatically, nothing else to touch.

## Checklist

Run through this list, top to bottom, before tagging a release.

1. **Builds green.**
   - `./build.ps1`
   - `./build.ps1 -Release`
   - `./build.ps1 -Force1MB`

   All three must assemble with no errors and no ASSERT failures.
   Each prints a `resident ends at ... headroom ...` line - watch for
   a sudden headroom collapse between release passes, a sign new code
   landed somewhere unexpected.

2. **Test scaffolding green.**
   - `./tests/build-tests.ps1`
   - `./tests/build-tests.ps1 -Suite`

   Both must compile cleanly (DRF + DRB, no errors) and stage without
   warnings.

3. **Full condact suite - owner-run in CSpect.**

   `./tests/build-tests.ps1 -Suite`, then run the interpreter (CSpect,
   sd\ mounted) and read the suite's own on-screen output. Expected:
   checks 01 through 80 all report OK (80 checks total).

4. **Corpus legs - owner-run, playthrough by feel.**
   - Rabenstein: `./tests/build-tests.ps1 -Rab` (add -Gfx256/-GfxZx0 as
     wanted), then a playthrough pass in CSpect.
   - Urban Upstart: `./tests/build-tests.ps1 -UU`, then playthrough
     rounds in CSpect - defect, fix wave, re-leg, the same rhythm as
     Rabenstein.
   - Smoke-set boot matrix: PENDING. The smoke set (a small breadth
     collection of classic DAAD sources taken to compile, boot and
     reach the first room - not full playthroughs) needs the owner to
     curate the game list before it can run. Do not skip this line
     silently on a future release pass: either the list has been
     curated and the matrix run, or this stays an open item.

5. **Kit refresh.**

   `./build.ps1 -Kit` - explicitly. A routine `-Release` build does
   NOT touch authoring-kit/nextdaad.nex (only -Kit publishes the
   interpreter into the kit), so this step is easy to forget and has
   stranded the kit on a stale interpreter before. Run it, then smoke-
   test the kit itself: BUILD.BAT on the starter game, confirm
   RELEASE\ comes out with the current nextdaad.nex.

   This is a morning step for the owner, run after the legs above
   pass - not an agent task. No .nex file should ever be committed by
   an agent.

6. **Hardware session.**

   The closing gate: a real-Next session against
   docs/hardware-test-checklist.md (suite 01-80 on silicon, the audio
   checklist sections, Rabenstein and Urban Upstart side by side with
   CSpect, and every item still unchecked in that file). Record
   results by ticking the checklist in place; anything silicon-only
   that fails gets a fix wave and a re-check before the milestone
   closes.

## Kit inventory

What ships inside authoring-kit/ (committed to the repo):

- `nextdaad.nex` - the pre-built interpreter (refreshed by checklist
  step 5 above). The kit ships a binary; it does not compile the
  interpreter from source.
- `BUILD.BAT`, `RUN.BAT`, `CLEAN.BAT`, `CONFIG.BAT` - the author-facing
  entry points.
- `lib\` - the build engine: assemble.bat, ddb.bat, gfx.bat, audio.bat,
  aysconv.ps1 (the AYS stream-song converter), pnginfo.ps1.
- `STARTER.DSF`, `IMAGES\001.png`/`002.png`,
  `AUDIO\STARTER.aks`/`STARTER_FX.aks`/`1.aks`/`001.wav` - the starter
  game, so a first build works out of the box.
- `SETUP.md`, `README.txt`, `tools\README.txt` - the docs. SETUP.md is
  the full guide, including the authoring notes section added this
  milestone: the DDB size ceiling, XMESSAGE limits, WAV sizing, AYS
  streamed songs, and the DRB 0.36 BEEP/PAUSE retune note.
- `tools\` - EMPTY placeholder folders (DAAD-READY, gfx2next,
  ArkosTracker3, CSpect) plus tools\README.txt describing what to
  download into each. The third-party tools themselves are never
  shipped (redistribution restrictions), so a fresh kit checkout
  cannot build until an author populates these.

Not shipped, not committed: `authoring-kit\RELEASE\` (build output,
gitignored) and `authoring-kit\CONFIG.local.BAT` (personal overrides,
gitignored).

## 0.x versioning

NextDAAD stays on a 0.x version (this milestone: v0.1.0) until public
testing earns v1.0. There is no fixed bar for that jump beyond public
testing having actually happened and the result holding up - it is an
owner call, made after real players, not just the corpus and smoke
set, have used the interpreter.
