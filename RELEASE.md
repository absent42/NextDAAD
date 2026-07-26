# NextDAAD Release Checklist

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
   - `./tests/build-tests.ps1 -Part`

   All must compile cleanly (DRF + DRB, no errors) and stage without
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
   - Multi-part fixture: `./tests/build-tests.ps1 -Part`, then run.
     Expect exactly: PA BOOT, PB CARRY OK, the part-two external
     text (clean), PB SAV OK, PA RETURN OK, PB XLOAD OK,
     PA RAMLOAD OK - typing the same save name at all three
     prompts. Any " F" line, garbled external text, or a stall is a
     defect.
   - Title screen: `./tests/build-tests.ps1 -Title`, then run. The
     320x256 title shows with music and any key starts the game; a
     release build shows no banner text while a title is present.
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

6. **NXV v2 test-core caveat re-confirm.** All NXV v2 silicon
   coefficients were settled on core 3.02.04, a KS3 TEST core (freeze
   caveat (b)). Before any release, re-confirm the coefficients on the
   then-current RELEASE core - one CPU row + one DMA row suffices. See
   docs/hardware-test-checklist.md:509-528 for the detail. Do not skip
   this line silently: either the re-confirm has run on the release
   core in use, or this stays an open item.

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