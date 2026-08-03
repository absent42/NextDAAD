Staging folder for test/leg fixtures. Gitignored except this file.

Nothing is staged into THIS directory. tests\build-tests.ps1 stages each
leg into its own self-contained subfolder - GAME.DDB, every asset that
leg needs, and a copy of build\nextdaad.nex as NEXTDAAD.NEX:

  TEMPLATE\  plain build (also -Aud)   VID\     -Vid / -VidLong
  SUITE\     -Suite                    NXBENCH\ -NxBench
  ERR4\      -Err4                     GMODE\   -GMode
  V3\        -V3                       RAB\     -Rab
  UU\        -UU                       PART\    -Part (+ PART2\ shadow)
  AUDLAD\    -AudLad                   SFXDI\   -SfxDi
  L2DMA\     owner-hand-built, in the same shape

A NextDAAD game opens GAME.DDB and all its assets by RELATIVE name, so
the directory it was launched from IS its asset directory. Copy one
folder to the card, launch NEXTDAAD.NEX from inside it, and no other
leg's leftovers are reachable. Each staging run EMPTIES its own folder
first, so a re-stage is always a known state.

Why: with everything in this one directory, each leg's files landed on
top of the last one's - a stale 001.NX2 hijacked PICTURE 1 from a freshly
staged 001.NXI, a leftover boot title starved the graphics cache, a
leftover .AKY destroyed a silent control leg. Three vacuous passes in one
evening (2026-08-03).

build.ps1 -Run mounts a leg folder as the emulated card: -Leg <name>, or
the most recently staged one if you do not say.
