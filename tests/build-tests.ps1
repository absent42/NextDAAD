# ===================================================================
# LEG FOLDERS - nothing is staged into the sd\ ROOT any more
# ===================================================================
# 2026-08-03 (owner: "putting everything in the same sd folder is too
# messy, it needs subfolders"). Every staging switch used to write into
# the sd\ root, so each leg's files landed on top of the last one's and
# each switch's stale-clean only removed the file types IT owned. Three
# vacuous passes came out of that in one evening:
#   - a stale 001.NX2 from a video stage HIJACKED PICTURE 1 away from a
#     freshly staged 001.NXI (the picture loader probes .NX2 first), so
#     a Layer 2 DMA test silently drew corpus art down the CPU scatter
#     path instead;
#   - a leftover boot title starved the graphics cache and turned burst
#     picture draws into no-ops;
#   - a leftover .AKY set the audio-enabled flag and destroyed a
#     fixture's silent control leg.
# EVERY run now stages into exactly ONE self-contained subfolder of sd\,
# chosen by the switches given. A NextDAAD game opens GAME.DDB and all
# its assets by RELATIVE name (src\file.asm ddb_load, src\errors.asm
# ddbName), so the cwd it was launched from IS its asset directory: copy
# the one folder to the card, launch the .nex inside it, and no other
# leg's leftovers are reachable even in principle.
#
#   switch(es)          folder        active GAME.DDB
#   ------------------  ------------  --------------------------------
#   (none) / -Aud       sd\TEMPLATE\  tests\test.dsf (the template)
#   -Vid / -VidLong     sd\VID\       template (the VID*/PICK verbs)
#   -NxBench            sd\NXBENCH\   template (the NXB* verbs)
#   -Suite              sd\SUITE\     tests\condacts.dsf
#   -Err4               sd\ERR4\      tests\doallnest.dsf
#   -GMode              sd\GMODE\     tests\gmodegate.dsf
#   -V3                 sd\V3\        tests\v3probe.dsf
#   -Rab                sd\RAB\       Rabenstein
#   -UU                 sd\UU\        Urban Upstart
#   -Part               sd\PART\      NDPARTA + PART2\ shadow
#   -AudLad             sd\AUDLAD\    tests\audlad.dsf
#   -SfxDi              sd\SFXDI\     tests\sfxdi.dsf
#   -SfxLong            sd\SFXLONG\   tests\sfxlong.dsf
#   -Sfx2               sd\SFX2\      tests\sfx2.dsf
#   -L2Holes            sd\L2HOLES\   tests\l2holes.dsf
#   -TileSlack          sd\TILESLK\   tests\tileslack.dsf
#   -Uto                sd\UTO\       tools\TEST.DSF     (V2)
#   -UtoV3              sd\UTOV3\     tools\TEST.DSF     (V3)
#   -FontSw             sd\FONTSW\    tests\fontsw.dsf
#   -Palette            sd\PALETTE\   tests\palette.dsf
#   -BigDdb             sd\BIGDDB\    tests\bigddb.dsf   (past 31744)
#   -Xbn                sd\XBN\       tests\extern.dsf
#   (sd\L2DMA\ is an owner-hand-built folder in the same shape and is
#    never touched by this script)
#
# ONE FOLDER PER INVOCATION. If more than one leg switch is given the
# LAST one in the table above wins - the same last-copy-wins order the
# DDB switches always had, so the folder and the active DDB can never
# disagree. Modifier switches (-Aud, -Title, -Font, -Gfx256, -GfxZx0)
# have no folder of their own; they stage into whichever leg folder the
# run resolved to, exactly as they used to stage alongside whatever was
# in the root.
#
# STALE-CLEAN IS PER FOLDER. The resolved folder is emptied ONCE at the
# start of staging and then filled, so a re-stage is always a known
# state and no per-file-type cleaning is needed (or kept - the old
# sd\*.AKY / sd\*.WAV / six-art-extension sweeps are gone; they existed
# only because the root was shared). Consequence worth knowing:
# -Vid and -VidLong share sd\VID\, so GIVE THEM TOGETHER
# (`-Vid -VidLong`) when you want 001-011+099 on the card. That is what
# the leg cards already ask for and the encodes are cached in
# tests\out\, so the second switch costs file copies, not encodes.
#
# THE .nex IS STAGED TOO. build\nextdaad.nex is copied into the leg
# folder as NEXTDAAD.NEX (skipped with a warning if you have not built
# yet), so the folder is genuinely self-contained: one folder to copy,
# one file to launch. The run prints both at the end.
#
# The sd\ ROOT is no longer read by anything this script stages. Files
# left there by earlier runs are inert - they are not deleted here
# (they are not this script's to delete any more), so clear them by
# hand once you are happy.
# ===================================================================
#
# Compiles tests\test.dsf (template), tests\condacts.dsf (suite),
# tests\doallnest.dsf (DOALL depth/error demo), tests\gmodegate.dsf
# (SP16 GMODE graphics-gate fixture) and tests\debugflag.dsf (DRC's
# -D debug marker - the one fixture compiled twice, with and without
# DRB's -d, and asserted in bytes rather than staged) with DRC
# (version 2 DDB),
# generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process); -GMode makes the gmodegate DDB
# active and stages the single Layer 2 picture it needs (see its own
# block below); -V3 makes the v3probe DDB active - the ONLY fixture
# here compiled with DRF's -v3, so its header byte 0 is 3 - together
# with the 0.XMB its XMES probe reads (see its own block below);
# -Rab compiles the modernised next-only
# tools\Rabenstein-master\nextdaad\rabenstein.dsf (the real
# commercial-quality DAAD game), makes that DDB active, and stages the
# Layer 2 art (default N.NX2 -> NNN.NX2); -UU compiles the owner-
# authored tools\urban-upstart\URBAN-UPSTART.DSF (untracked vendor dir -
# never edit it here), makes that DDB active, and stages whatever
# N.NXI/N.NX2 art exists there as-is to NNN.NXI. In practice that is
# NOTHING: the vendor dir holds 10 PNGs and no converted art at all, so
# -UU stages 0 files and the leg runs TEXT-ONLY. (This went unnoticed
# because the leg could never run - see the DSF filename note below.)
# This script has no image-conversion step by design - Rabenstein's art
# ships pre-converted - so giving -UU pictures means running gfx2next
# on the PNGs to somewhere OUTSIDE the read-only vendor dir and
# pointing $uuSrc's art scan at it. Owner's call, not done.
# All destinations are inside the run's leg folder - see the LEG
# FOLDERS block at the top.
# The DDB switches are mutually exclusive - if more than one is given,
# whichever copy runs last in this script wins: -Suite copies first,
# -Err4 copies over it, -GMode copies over that, -V3 over that,
# -Xbn copies over that, -Rab copies over that,
# -UU copies over that, then -Part, then -AudLad, then -SfxDi, then
# -SfxLong, then -Sfx2, then
# -L2Holes, then -TileSlack last of
# all, in the order their blocks appear below. $legName is resolved in a
# DIFFERENT order (see below), and for -Xbn that order does NOT match
# this physical one: $legName puts XBN last of every switch, but -Xbn's
# staging block physically sits right after -V3's, BEFORE -Rab/-UU/
# -Part/-AudLad/-SfxDi/-SfxLong/-Sfx2/-L2Holes/-TileSlack. Combine -Xbn
# with any of those and $legName will say XBN while that other switch's
# GAME.DDB copy is the one that actually wins. Every leg switch here is
# documented as an alternative to the others, not a companion - this
# risk is latent, not exercised by any switch combination this script
# recommends.
# The template is active if no switch is given.
# Two-part fixture (SP11 Task 6), independent of the single-DDB switches
# above except that it also writes GAME.DDB (see the mutually-
# exclusive note above):
#   -Part    compile and stage both halves of the NDPARTA.DSF/
#            NDPARTB.DSF fixture pair, into sd\PART\. NDPARTA ->
#            GAME.DDB (part 1, byte-identical to a single-part game)
#            + 0.XMB; NDPARTB -> GAME2.DDB (part 2) + PART2\0.XMB
#            (directory created if absent). The two 0.XMB files hold DIFFERENT
#            content at overlapping offsets by design - NDPARTB.DSF's
#            own XMES line only reads back clean if the interpreter's
#            PARTn\ probe (SP11 Task 5) actually wins over the root
#            file; a wrong probe reads part A's bytes at part B's
#            offsets instead (garbled/wrong text, not a crash). Same
#            CSpect-running guard as -Rab/-UU; sd\PART\ is emptied
#            before restaging like every leg folder. The fixture pair's
#            own PRO 0 logic (owner leg only - run ./build.ps1 -Run
#            after staging, see each DSF's own header comment for the
#            full transcript) exercises all four part-switch primitives
#            in one pass: EXTERN forward (part 1 -> 2), EXTERN back
#            (2 -> 1), then a cross-part LOAD auto-switch forward
#            (1 -> 2, h_load's own part-mismatch -> xpart_load_entry ->
#            switch_to_part wiring) and a cross-part RAMLOAD auto-switch
#            back (2 -> 1, the same wiring via h_ramload) - both
#            directions of both switch mechanisms. One typed SAVE and
#            two typed LOADs share a single on-disk file, so the owner
#            answers all three filename prompts with the same name
#            (the fixture suggests "pt").
# Art-staging modifiers (effective only with -Rab, combinable):
#   -Gfx256  stage the 256-wide N.NXI set instead of the N.NX2s
#   -GfxZx0  ZX0-compress each staged file (NNN.NX2.ZX0 / with
#            -Gfx256 NNN.NXI.ZX0) so the interpreter's compressed
#            picture path is exercised
#   (-UU always stages whatever single art shape ships in
#    tools\urban-upstart - no modifiers; that corpus has no parallel
#    NX2/NXI pair to choose between)
# Audio staging (combinable with any DDB switch):
#   -Aud     stage the test audio assets from tools\audio_assets\
#            (GAME.AKY, 001.AKY, GAME.SFB, 001.WAV, 001.AYS, 002.AYS -
#            produced by the export script / aysconv.ps1) into the leg
#            folder (sd\TEMPLATE\ on its own); warns and skips if the
#            source folder is empty
#   -AudLad  SP16 Task 7: make the tests\audlad.dsf DDB active AND stage
#            the AY characterization ladder into sd\AUDLAD\ -
#            L1/L3/L6/L9/L9Q.AKY from
#            tests\audio\ -> 001..005.AKY, the kit's own 9-channel
#            tune (converted here from the tracked
#            authoring-kit\AUDIO\1.aks) -> 006.AKY, and GAME.AKY
#            as a byte-identical copy of 006.AKY - the STOPM control:
#            boot autoplay and the LADR verb then replay the SAME
#            bytes, on the real material. sd\AUDLAD\ holds nothing
#            else, so it and -Aud are alternatives, not companions -
#            run one or the other.
#   -SfxDi   sampled-SFX DI-exposure EAR fixture, staged into sd\SFXDI\:
#            make the
#            tests\sfxdi.dsf DDB active AND stage the two steady-tone
#            stimuli tests\audio\mktone.py generates (440 Hz, 48000
#            bytes = the reserved 48K audio floor) as 001.WAV
#            (16000 Hz, the only rate this project ships) and
#            002.WAV (20000 Hz = AUD_RATE_MAX, README's published
#            ceiling). ALSO stages the Layer 2 corruption-detector card
#            tests\art\mkl2card.py generates as 001.NXI (256x128,
#            256-WIDE so DISPLAY 0 reaches gfx_row_copy256 -> dma_copy).
#            A leftover 001.NX2 winning the probe chain and routing the
#            blit down the CPU scatter path is now impossible by
#            construction: sd\SFXDI\ is emptied first and holds nothing
#            but this fixture's own four files (plus the .nex).
#            Stages NO .AKY at all - a playing song would put the
#            AKY player's own ~5500 T per-frame DI hold under both
#            phases of the readout. The fixture stops and waits for a
#            KEYPRESS at every phase boundary (rev 2a) so a symptom can
#            be attributed to the phase that produced it - the owner
#            drives it a phase at a time, and each burst still runs
#            uninterrupted inside its phase. Run sheet (mode caveat,
#            predicted frequencies, boundary-by-boundary checklist, pass
#            criteria): .superpowers\sdd\sfx-di-audible-test.md. An
#            alternative to -Aud/-AudLad, not a companion.
#   -SfxLong SD-streamed sampled-effect wire fixture (SP18 item 7 Task 7),
#            staged into sd\SFXLONG\: make the tests\sfxlong.dsf DDB
#            active AND stage three generated WAVs (16000 Hz mono 8-bit,
#            same deterministic whole-cycle sine construction as
#            tests\audio\mktone.py, generated inline here rather than by
#            a script) as 001.WAV (effect 1, ~200000 bytes of payload -
#            over SFX_WIN_BYTES/24576, forces the STREAMING arm of
#            sfx_stream_open), 002.WAV (effect 2, ~16000 bytes of
#            payload - under the threshold, takes the COMPLETE/free-
#            hybrid arm) and 003.WAV (effect 3, ~100000 bytes of payload -
#            a SECOND, distinct STREAMING number, added Task 14b so a
#            fresh full open can be contrasted against a cached rewind of
#            effect 1). Verbs PLAY1/LOOP1 (effect 1), PLAY2/LOOP2 (effect
#            2) and PLAY3/LOOP3 (effect 3) map to SFX 1/2/3 1/2, STOP maps
#            to SFX 0 5; boot autoplay starts LOOP1 with no typing needed.
#            Also stages 001.NXI (Task 14b: tests\art\mkl2card.py's
#            generated Layer 2 card, the same file -SfxDi stages, for the
#            PIC verb's PICTURE 1 / DISPLAY 0) and, opportunistically,
#            001.VID (Task 14b: the smallest cached -Vid leg encode
#            already sitting in tests\out\, for the VID verb's SFX 1 9 -
#            no video encoder is run by this switch; if no cache exists
#            yet, 001.VID is left unstaged and staging warns rather than
#            fails). SAVE/LOAD are the standard DAAD condacts (SAVE 0 /
#            LOAD 0). The compiled condact bytes (SFX opcode 18, PICTURE
#            84, DISPLAY 28, SAVE 25, LOAD 26) are asserted below on every
#            run, whether or not this switch is given - the fixture-
#            stimulus rule, DRC can silently rewrite condacts. This leg
#            proves the STREAMING arm is reachable and byte-correct;
#            CSpect cannot exercise the refiller's raw SD SPI at all, so
#            the refiller's own counters (refilled blocks, underruns,
#            fails) can only be read on ZEsarUX or real hardware - the
#            manual wire-smoke procedure is documented in
#            tests\sfxlong.dsf's own header, not automated here.
#   -Sfx2    TWO-CHANNEL sampled-effect API fixture (SP18 item 7 Task
#            12), staged into sd\SFX2\: make the tests\sfx2.dsf DDB
#            active AND stage three generated WAVs (16000 Hz mono
#            8-bit, the same deterministic whole-cycle sine writer the
#            -SfxLong leg uses) as 001.WAV (effect 1, 16000 bytes of
#            payload, 440 Hz - under SFX_WIN_BYTES so it plays COMPLETE),
#            002.WAV (effect 2, 12000 bytes, 880 Hz - also COMPLETE) and
#            003.WAV (effect 3, 40000 bytes, 220 Hz - over the threshold,
#            the STREAMING arm). Verbs cover auto-allocation (SFX n 1/2),
#            the pinned channels (SFX n 11/12/13/14), the per-channel
#            stops (SFX 0 15/16), the stop-all superset (SFX 0 5), the
#            STEAL case (a loop and a one-shot on auto, then a third
#            effect - the one-shot must lose) and the pin-reject case
#            (both channels pinned, third trigger dropped). Boot
#            autoplay starts BOTH effects looping, so the headline
#            claim needs no typing. The compiled SFX condact bytes are
#            asserted below (opcode 18) on every run whether or not this
#            switch is given, INCLUDING the six new sub-commands 11-16 -
#            the fixture-stimulus rule, DRC can silently rewrite
#            condacts.
#            CSPECT: effects 1 and 2 are both COMPLETE, so BOTH CHANNELS
#            PLAY CONCURRENTLY there and every steal/pin/stop verb is
#            observable by ear plus the DEBUG markers ("SFX BUSY?" at
#            row 30 column 50 for a dropped trigger). Effect 3 streams
#            and so dies cleanly on CSpect's SD emulation after
#            SFX_FAIL_LIMIT ticks, which is expected and does not affect
#            what the steal verb proves. An alternative to -Aud/-AudLad/
#            -SfxDi/-SfxLong, not a companion.
#   -L2Holes Layer 2 TRANSPARENCY / punch-out fixture, staged into
#            sd\L2HOLES\: make the tests\l2holes.dsf DDB active AND
#            stage the punch-out card tests\art\mkl2holes.py generates
#            as 001.NXI (256x192). The inverse of -SfxDi's card - that
#            one must contain NO transparent pixel, this one is made of
#            them. The DSF fills all 80x32 tilemap cells with a position
#            ruler ("12-16DG." = row 12, column 16, tag DG), the card
#            covers it with opaque Layer 2 and punches index-255 holes
#            at known places, so what you read THROUGH a hole names the
#            hole without counting cells on the glass. .NXI and not
#            .NX2 deliberately: gfxExtTab routes NXI to mode 0 / width
#            256 and NX2 to mode 1 / width 320, the NX2 variants probe
#            FIRST, and a 320-wide surface would cover the control
#            margin the fixture reads its verdict from. Run sheet (hole
#            table, what a failure of each hole means):
#            docs\superpowers\l2-holes-run-sheet.md. An alternative to
#            every other DDB switch, not a companion.
#   -TileSlack
#            --tile-slack A/B fixture, staged into sd\TILESLK\: make the
#            tests\tileslack.dsf DDB active AND stage FOUR encodes of the
#            authoring kit's own two DEMO clips as two A/B PAIRS -
#            001/002.VID = the BUNNY clip (authoring-kit\VIDEO\001.mp4) at
#            --tile-slack 0.0 and 0.5, 003/004.VID = the JELLYFISH clip
#            (002.mp4) at the same two values. Both pairs are full
#            320x256 @25 mode-1, whole clip, and within a pair NOTHING
#            differs but the knob: the stream budget is DERIVED on arm A
#            and PINNED on arm B, so the finer tile rung cannot move its
#            own supply ceiling and flatter itself.
#            NOT A REPRODUCTION OF THE MANUAL'S --tile-slack BENCHMARK
#            TABLE. That table was measured on two clips ("boat pan",
#            "church zoom") which are NOT in this repository - they are
#            large silent sources that live outside it. This leg asks
#            whether the knob helps on the footage that ships in the box,
#            and nothing here is compared against that table.
#            THE ENCODES COME FROM tests\video\tileslack_ab.py, not from
#            a videnc call here. That script owns the experiment - it
#            derives the pin, runs the four encodes, caches them under
#            tests\out\tileslack\ and prints what it measured.
#            Staging runs it (cached: a re-stage
#            after a completed measurement costs file copies, not
#            encodes) and copies its OWN output files, so the numbers on
#            the page and the picture on the glass are the same bytes.
#            The fixture is the half no metric answers: --tile-slack is a
#            MOTION knob and the owner's own footage banded and juddered
#            on kit defaults after the whole fixture deck passed. NOTE the
#            AT-CAPACITY FINDING: BOTH slack-0.5 arms measure over
#            STREAM_WARN_UTIL (0.912 against 0.90) and print the encoder's
#            own at-capacity warning, so applying the manual's "try 0.5
#            first" advice to the kit's own demo clips trips it - watch
#            those arms for JUDDER and audio breakup specifically. Run
#            sheet (what to look for on each pair, what an outcome means,
#            and why the numbers and the picture can disagree):
#            docs\superpowers\tileslack-ab-run-sheet.md. An alternative
#            to every other DDB switch, not a companion.
#   -Xbn     XBN extern support fixture, staged into sd\XBN\: make the
#            tests\extern.dsf DDB active AND assemble/stage
#            tests\xbn\xbntest.asm's fixture extern as GAME.XBN (the
#            XREG/XCAL/XCNR/XTIK/XSVC/XFIO/XMSG/XABS probe verbs, all
#            live against the interpreter's XBN support as of Task 9).
#            Three companion switches, all no-ops without -Xbn. Not
#            designed to be combined with each other; the staging code
#            checks them in this priority order, so if more than one is
#            given -XbnNoBin wins over -XbnBad wins over -XbnTicker:
#              -XbnNoBin      stage GAME.DDB with NO GAME.XBN at all (the
#                              XABS no-XBN control - EXTERN must stay inert).
#              -XbnBad <kind> stage a corrupt/truncated variant AS
#                              GAME.XBN instead of the good one - magic |
#                              ver | size | trunc; a kind is required, a
#                              bare -XbnBad errors. Omit -XbnBad entirely
#                              to stage the good GAME.XBN (the default).
#                              For Task 2's validation-reject checks; the four
#                              variants (tests\out\xbn\BADMAGIC.XBN /
#                              BADVER.XBN / BADSIZE.XBN / TRUNC.XBN) are
#                              generated unconditionally alongside the good
#                              GAME.XBN so a break in the generator is
#                              caught on a plain run.
#              -XbnTicker     stage the Task 9 shipped worked example
#                              (authoring-kit\externs\ticker\ticker.asm)
#                              as GAME.XBN INSTEAD of the xbntest.asm
#                              fixture, so extern.dsf's XTCK verb has
#                              something to drive. Assembled fresh here
#                              into tests\out\xbn\TICKER.XBN (same source
#                              the example's own build.ps1 uses, not
#                              forked - just built into a scratch cwd so
#                              its SAVEBIN "GAME.XBN" cannot collide with
#                              the fixture's own tests\out\xbn\GAME.XBN,
#                              and the kit example directory stays
#                              build-artifact-free). Every OTHER XBN probe
#                              verb (XREG/XCAL/XCNR/XTIK/XSVC/XFIO/XMSG)
#                              is meaningless in this combination - the
#                              ticker's ext_main only recognises fn 30/31
#                              and no-ops on everything else, same as
#                              xbntest.asm's own unrecognised-fn path.
#              -XbnFade       stage the Layer 2 fade worked example
#                              (authoring-kit\externs\fade\fade.asm) as
#                              GAME.XBN INSTEAD of the fixture, plus the
#                              single Layer 2 picture (001.NX2, the same
#                              Rabenstein source -GMode reuses) that
#                              extern.dsf's XFAD verb draws and fades.
#                              Same scratch-cwd assembly pattern as
#                              -XbnTicker (-> tests\out\xbn\FADE.XBN).
#                              Selection priority when combined:
#                              -XbnNoBin wins over -XbnBad over
#                              -XbnTicker over -XbnFade.
#            An alternative to every other DDB switch, not a companion.
# THIRD-PARTY compliance test (tools\TEST.DSF), the only fixture here
# this project did not write - and the only one whose SOURCE is not in
# this repository:
#
#   LICENCE. tools\TEST.DSF is Uto's TestUnitDAAD
#   (https://github.com/Utodev/TestUnitDAAD), GPL-3.0. NextDAAD does not
#   vendor it and MUST NOT: copying it in - or committing anything
#   derived from it, the compiled DDB included - would either breach the
#   copyleft terms or force this project's own licensing to change.
#   It is treated exactly like DRC, gfx2next and ffmpeg: an owner-
#   supplied third-party tool that lives under the gitignored tools\ and
#   is CONSUMED, never redistributed. The owner downloads it himself;
#   both blocks below read it in place, and every artefact they produce
#   lands in tests\out\ or sd\, both gitignored. Do not "tidy" a copy
#   into tests\ - a modified GPL file is still GPL.
#
#   -Uto     make the V2 build of Uto's own DAAD compliance test the
#            active GAME.DDB, in sd\UTO\. Written by the author of the
#            DRC compiler this project targets, "to test compatibility
#            of the new interpreters". It is the one fixture whose value
#            depends on NOT being edited: it encodes what the DAAD
#            ecosystem considers correct rather than what this project
#            assumed, so a failure is a finding about the interpreter
#            and must never be "fixed" in the DSF.
#            SELF-SCORING. Each condact gets a positive test and usually
#            a negative one; a pass prints "<CONDACT> ... OK", a failure
#            prints "* <CONDACT> ERROR!" and DONEs out of PROCESS 1, so
#            the run STOPS at the first failure and the last line on
#            screen names it. 64 OK lines = a full V2 pass. The visual
#            half that follows is operator-scored (it prints what it
#            expects to look like). Needs NOTHING but the DDB - no art,
#            no audio, no 0.XMB, no save file, and no typed input at all
#            (its /PRO 0 runs the whole test at boot). An alternative to
#            every other DDB switch, not a companion.
#            If tools\TEST.DSF is absent a plain run just warns and
#            skips the two compiles; asking for -Uto/-UtoV3 without it
#            throws, with the download URL in the message.
#            Run sheet: .superpowers\sdd\uto-compliance-runsheet.md
#   -UtoV3   the same source compiled WITH -v3, into sd\UTOV3\. The DSF
#            carries two #ifdef "V3" blocks that DRF only compiles in
#            when -v3 is given (-v3 defines the symbol V3): SETAT x3
#            (set/clear/toggle on flag 57 via attribute 16) and second-
#            parameter indirection (LET 200 @100), plus a GETKEY leg in
#            the visual half. 68 OK lines = a full V3 pass. This is the
#            only INDEPENDENT test of the SP16 V3 work - v3probe.dsf is
#            ours. Worth noting for whoever next touches v3probe: this
#            DRF build has real SETAT and GETKEY keywords (SETAT emits
#            opcode 124 directly, GETKEY compiles to PAUSE 0), so the
#            Invoke-V3SetatPatch stand-in below may no longer be needed
#            there - not changed here, out of this fixture's scope.
# Boot title screen (SP11 Task 1), independent of the DDB switches:
#   -Title   stage the owner 320x256 title into the run's leg folder -
#            copies tools\demo-files\DAAD.NX2, a gfx2next-converted
#            Layer 2 picture (ADAPTIVE 256, -bitmap -pal-embed).
#            tools\demo-files is the home for NEWLY CREATED test
#            graphics/sound/video assets (owner convention 2026-07-19;
#            existing asset dirs stay where they are). Not committed
#            (sd\ is gitignored). Default (no -Title) stages no title -
#            and since the leg folder is emptied every run, a title can
#            no longer survive into a leg that did not ask for one (it
#            used to, and starved the graphics cache when it did).
# Custom font (SP12 Task 2), independent of the DDB switches:
#   -Font    stage a visually distinctive custom font into the run's leg
#            folder - runs authoring-kit\lib\fontconv.ps1
#            on tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 (a 768-
#            byte classic ZX charset, chars 32-127 - the "Crews" ZX-
#            Origins font: a bold, tilted, graffiti-style face, chosen
#            for being obviously different from the interpreter's plain
#            embedded font at a glance, and shipped as a single file with
#            no bold/script weight variants to disambiguate). No test
#            binary is committed - fontconv.ps1 builds FONT.CHR fresh
#            each run from the source .ch8 plus authoring-kit\lib\
#            default.chr. Same CSpect-running guard as -Title (locked
#            sd\ files cause a partial fixture). Default (no -Font)
#            stages no font. The Crews source ships as a .zip under
#            tools\demo-files\fonts and is not always extracted (SP18) -
#            -Font degrades to staging no font (a warning, not a throw)
#            rather than fail the whole run over a missing demo archive.
#            SP12 Task 3 rides the same switch: -Font ALSO generates a
#            fresh 256-byte POINTER.SPR fixture
#            in-script (a 16x16 solid green square, 2px $E3 transparent
#            border, 1px black outline - obviously different from the
#            interpreter's default black/white arrow at a glance). No
#            test binary is committed for this either. The generator
#            (New-PointerFixture, SP18) takes a fill colour, so the same
#            code also produces the three colour-coded shapes the
#            -FontSw leg below stages.
# Video benchmark fixtures (SP13 Task 1, NXV v2 rewrite SP15 T1; LEG SET
# switched to the SP15 3a calibration-wave fixtures 2026-07-25),
# independent of the DDB switches:
#   -Vid     stage the CURRENT LEG SET into sd\VID\001.VID..006.VID -
#            the SAME six fixtures the owner leg card stages
#            (.superpowers\sdd\sp14a-task-4-report.md section 37 + its
#            CALIBRATION WAVE addendum), short real-footage/test-card
#            CUTS sized to the ~950 KB resident ring - NOT full-clip
#            encodes (see the obsolete-cache note below).
#            docs\superpowers\plans\2026-07-23-sp15-nxv2.md is the
#            format authority; authoring-kit\lib\nxv2enc.py/nxv2dec.py
#            are the encoder pipeline/reference decoder, videnc.py the
#            CLI shell (the ONE canonical encoder, shipped in the kit
#            like fontconv.ps1 - no drift-prone test copy). v1's five
#            fixed profiles (n0-n4) are GONE (SP15 T1, owner decision) -
#            v2 has SHAPE presets instead (full/16:9/scope/classic/
#            classic-wide, nxv2enc.PRESETS), each encoded here at 25fps
#            stereo. VIDBENCH (DEBUG builds only, tests\test.dsf)
#            always benches 001.VID (full, the highest data-rate
#            shape - the conservative gate). Stale-cleaning is now the
#            leg folder's, not this switch's: sd\VID\ is emptied once at
#            the start of the run and -Vid/-VidLong then fill it, so
#            GIVE THEM TOGETHER (`-Vid -VidLong`) for the full
#            001-011+099 card - the SP15 T5 per-file scoping this switch
#            used to carry existed only to survive the shared root.
#            Source -> dest mapping (shape, source clip, exact
#            --start/--duration - these values reproduce the leg-staged
#            bytes byte-for-byte, the encoder being deterministic):
#              001.VID <- full          (320x256 mode-1, Sintel_1080_10s_30MB.mp4 @00:00:00 dur 1.35)
#              002.VID <- classic       (256x192 mode-0, Sintel_1080_10s_30MB.mp4 @00:00:00 dur 1.8)
#              003.VID <- 16:9          (320x192 mode-1 letterbox, Big_Buck_Bunny_1080_10s_30MB.mp4 @00:00:03 dur 1.0)
#              004.VID <- scope         (320x144 mode-1 letterbox, Sintel_1080_10s_30MB.mp4 @00:00:00 dur 1.7)
#              005.VID <- classic-wide  (256x144 mode-0 letterbox, Jellyfish_1080_10s_30MB.mp4 @00:00:04 dur 1.6)
#              006.VID <- 16:9          (320x192 mode-1 letterbox, 1920x1080-25p.mp4 test card @00:00:00 dur 5.0 - the PACING CARD, vpace/vpacl)
#            Sources are owner-provisioned research clips plus the
#            existing test-card footage, all under tools\demo-files\
#            (read-only, like everything under tools\). Each encode is
#            SLOW (content-triggered-keyframe, dual-budget delta
#            coding) so results are CACHED at
#            tests\out\00X_<shape>_<settlementTag>_leg_cache.vid and
#            only regenerated when that cache file is missing -
#            tests\out\ is gitignored (persists across runs, unlike
#            sd\VID\, which is emptied at the start of every staging
#            run). $vidLegSettlementTag below is an EXPLICIT TAG BUMP
#            discipline, not a hash: unlike -VidLong's per-entry 'tag'
#            (sb51/sb54/direct/directpace), which fingerprints a CLI
#            operating-point argument, 001-006 take no such argument -
#            their bytes instead depend on nxv2enc.py's SOURCE-level
#            silicon-settled constants (TMODEL_COEFFS,
#            TMODEL_COMPOSITION_FACTOR, TMODEL_SILICON_R), which a CLI-
#            arg hash cannot see. SP17 T1 note: --stream-budget now
#            DEFAULTS to an automatic search, so "no such argument" also
#            means these six ride the auto-budget defaults. All six are
#            under the resident pool (largest is 006 at 1,039,360 B vs
#            1,277,952), so the search returns the ceiling on its first
#            probe and their bytes are unchanged - verified on 003 and
#            006 at the pal9d tag. A future fixture that crosses the
#            pool would NOT be, and would want an explicit budget or a
#            tag bump. The 4814921 gapped resettlement
#            (composition factor 1.55 -> 1.15) changed encoded output
#            with no CLI-arg change at all, and silently restaged the
#            stale pre-resettlement cache once already (SP15 T5 review
#            finding). Rule: bump $vidLegSettlementTag any time a
#            silicon-settled constant in nxv2enc.py changes; the cache
#            name change forces a re-encode. Regenerate by deleting the
#            relevant cache file and re-running -Vid, or directly with
#            e.g.:
#              python authoring-kit\lib\videnc.py tools\demo-files\Sintel_1080_10s_30MB.mp4 tests\out\001_full_pal9d_leg_cache.vid --shape full --fps 25 --start 00:00:00 --duration 1.35
#              python authoring-kit\lib\videnc.py tools\demo-files\1920x1080-25p.mp4 tests\out\006_169_pal9d_leg_cache.vid --shape 16:9 --fps 25 --start 00:00:00 --duration 5.0
#            Same CSpect-running guard as -Rab/-UU/-Title/-Font.
#            sd\*.VID is gitignored (owner edit).
#            PRE-3a LONG-CLIP CACHES ARE OBSOLETE: the five 10-14MB
#            full-60s-clip caches this switch used to stage (encoded
#            from the two 1440x1080-25p.mp4/1920x1080-25p.mp4 sources at
#            the pre-calibration T budget) do NOT match the leg-staged
#            fixtures above and were deleted from tests\out\ (one-time
#            stale-clean, 2026-07-25) rather than left to silently
#            drift. Long-clip staging returned as -VidLong (below)
#            when SP15 3b (streaming) landed; -Vid always means this
#            short leg set.
#   -VidLong stage the SP15 3b STREAMING leg fixtures into sd\VID\ - the
#            three research clips at FULL 10s duration (they exceed
#            the ~1.25MB pool ring and exercise the 3b prefetch
#            producer across multiple ring wraps), plus the
#            deliberate-underrun copy:
#              007.VID <- classic 256x192 (Sintel_1080_10s_30MB.mp4, full clip, ~6.4MB)
#              008.VID <- full 320x256    (Big_Buck_Bunny_1080_10s_30MB.mp4, --stream-budget 0.51)
#              009.VID <- 16:9 320x192 LB (Jellyfish_1080_10s_30MB.mp4, --stream-budget 0.54 - re-derived at the Card #5 gapped prices)
#              010.VID <- 256x133 --direct (Sintel full clip - VDIR/VDIRL, the direct-serve leg)
#              011.VID <- 256x133 --direct (1920x1080-25p test card @00:00:00 dur 5.0 - DPACE/DPACL, the DIRECT PACING CARD)
#              099.VID <- byte-copy of 007.VID (VSTRU: DEBUG builds
#                         throttle the producer for video number 99 -
#                         the deliberate-underrun leg)
#            010/011 TIGHTEN RULING (Card #5, 2026-07-26, owner-decided):
#            the direct-serve gate is UNCONDITIONAL - no accept-slow
#            override. Card #5's first silicon rows put the direct
#            transport at 917 B/ms (not the 1100 the 3c gate assumed), so
#            classic-wide 256x144@25 stereo scored 1.075 (~6% slow) and is
#            now refused outright by its own gate; 010/011 are encoded at
#            256x133@25 stereo instead (util 0.99, at-rate) - the
#            recalibrated gate's largest at-rate classic surface.
#            STREAM OPERATING POINTS (Card #3 VSTR1 follow-up): the
#            first 008/009 encodes rode the full decode-T budget -
#            mean supply utilization 1.74/1.30, mathematically
#            unstreamable (VSTR1 collapsed at ~65.5ms/frame on
#            silicon). videnc's streaming supply gate now refuses
#            such encodes; 007/008/009 carry the --stream-budget
#            values the gate derived (007 sb 0.85 since the pal9
#            palette-collapse fix pushed its old default point to
#            util 1.06; sb 0.85 alone landed at util 1.00 - AT the
#            ceiling, which starved the deltas on the wire, so 007
#            also carries --dither 0.25 and lands at util 0.981;
#            008/009 target ~0.90).
#            007 IS A DELIBERATE AT-CAPACITY STRESS FIXTURE (owner
#            ruling 2026-07-28): its acceptance criterion is TRANSPORT
#            (zero underruns, zero depth clips, ERR=00), proven twice
#            on silicon. Visible horizontal banding is the DOCUMENTED
#            EXPECTED PICTURE for this fixture - the content out-
#            demands the wire at 256x192@25 and no operating point is
#            both at-ceiling and clean. It is 36.4% budget-bound at
#            the shipped point - videnc prints that as a measurement
#            on every re-encode and NEVER warns about it (the
#            starvation trigger was retired 2026-07-28 as
#            uncalibrated: 008 reads 99.2% budget-bound and is clean
#            on silicon, 007 reads 36.4% and bands, so the figure
#            does not grade picture quality). Do not re-derive 007's
#            operating point off these numbers.
#            Cached at tests\out\00X_<shape>[_<tag>]_<settlementTag>_
#            long_cache.vid like -Vid (encode once, copy after;
#            delete a cache to re-encode; the operating point AND the
#            settlement tag are part of the cache name, so changing
#            either re-encodes). Shares sd\VID\ with -Vid - give the two
#            switches TOGETHER for the full 001-011+099 card.
#            Verbs: VSTR0/VSTR1/VSTR2/VSTRU (tests\test.dsf). Same
#            CSpect-lock guard.
#   -NxBench   stage the SP15 T2 decode-kernel bench payloads into
#              sd\NXBENCH\NXB0.BIN..NXB9.BIN (nxv2enc.py
#              --bench-fixtures -
#              raw opcode-stream payloads, no header/audio/padding; see
#              that mode's own comment block for the file-by-file
#              shapes, and .superpowers\sdd\sp14a-task-4-report.md
#              section 36 for the owner bench card). NXB8 (the real
#              classic 256x192@25 segment) is cut from the -Vid cache
#              tests\out\002_classic_cache.vid, which is encoded first
#              if missing (slow - same cache rule as -Vid). Fixture
#              set + manifest land in tests\out\nxbench\ then copy to
#              the leg folder. Same CSpect-lock guard as the
#              other staging switches. sd\ is gitignored.
#   -Nxv2Test  run tests\nxv2_selftest.py (plain python, no pytest -
#              header/opcode/keyframe-span roundtrips, scene-cut
#              lookahead, dual-budget rate control, BuildReport/
#              validate() sanity vs both research demo clips, CLI
#              rewire) and throw if it exits non-zero. Independent of
#              every other switch; does not touch sd\ or the DAAD
#              toolchain. Slow (steps 4-7 run real ffmpeg encodes
#              against tools\demo-files\) - not part of the default
#              (no-switch) run.
param([switch]$Suite, [switch]$Err4, [switch]$GMode, [switch]$FontSw, [switch]$Palette, [switch]$V3, [switch]$Rab, [switch]$UU, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud, [switch]$AudLad, [switch]$SfxDi, [switch]$SfxLong, [switch]$Sfx2, [switch]$L2Holes, [switch]$TileSlack, [switch]$Title, [switch]$Part, [switch]$Font, [switch]$Vid, [switch]$VidLong, [switch]$NxBench, [switch]$Nxv2Test, [switch]$Uto, [switch]$UtoV3, [switch]$BigDdb, [switch]$Xbn, [ValidateSet('', 'magic', 'ver', 'size', 'trunc')][string]$XbnBad = '', [switch]$XbnNoBin, [switch]$XbnTicker, [switch]$XbnFade)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dr = Join-Path $root 'tools\DAAD-READY'

# ---- which DRC compiles the fixtures -------------------------------
# The NEXTDAAD target lives in the fork (tools\DRC\) until DAAD Ready
# ships a DRC carrying it; NEXTDAAD_DRC overrides the location. ONE
# setting for every DRF/DRB call site in this file - there are 41, and
# -v3 has already taught this codebase what happens when one site is
# updated and another is not. DRF needs no substitute: it has no target
# whitelist, so only DRB.PHP comes from the fork.
# Every fixture is a NextDAAD-target database: the interpreter no longer
# reads classic $8400-based ones, so there is no classic route to build.
$drcRoot = if ($env:NEXTDAAD_DRC) { $env:NEXTDAAD_DRC } else { Join-Path $root 'tools\DRC' }
$drcDrb  = Join-Path $drcRoot 'src\drb.php'
$drcPhp  = Join-Path $dr 'PHP\php.exe'
$drcDrf  = Join-Path $dr 'TOOLS\DRC\DRF.exe'
[string[]]$drcTarget = 'nextdaad'   # typed: a bare single-element array unwraps to a string and splats per-character
if (-not (Test-Path -LiteralPath $drcDrb)) {
    throw "no DRB.PHP at $drcDrb - clone the NextDAAD DRC fork into tools\DRC, or set NEXTDAAD_DRC to point at it. DAAD Ready's own DRC does not carry the NEXTDAAD target yet."
}
if (-not (Select-String -LiteralPath $drcDrb -Pattern 'NEXTDAAD' -Quiet)) {
    throw "$drcDrb has no NEXTDAAD target - update the fork clone, or set NEXTDAAD_DRC to one that has it."
}
$sd = Join-Path $root 'sd'

# ---- leg folder (see the LEG FOLDERS block at the top) -------------
# Resolved in the SAME order the DDB copies used to run in, so the last
# switch given wins and the folder can never disagree with the active
# GAME.DDB. Modifier switches (-Aud/-Title/-Font/-Gfx256/-GfxZx0) have
# no entry here - they stage into whatever this resolves to.
$legName = 'TEMPLATE'
if ($Vid -or $VidLong) { $legName = 'VID' }
if ($NxBench)          { $legName = 'NXBENCH' }
if ($Suite)            { $legName = 'SUITE' }
if ($Err4)             { $legName = 'ERR4' }
if ($GMode)            { $legName = 'GMODE' }
if ($V3)               { $legName = 'V3' }
if ($Rab)              { $legName = 'RAB' }
if ($UU)               { $legName = 'UU' }
if ($Part)             { $legName = 'PART' }
if ($AudLad)           { $legName = 'AUDLAD' }
if ($SfxDi)            { $legName = 'SFXDI' }
if ($SfxLong)          { $legName = 'SFXLONG' }
if ($Sfx2)             { $legName = 'SFX2' }
if ($L2Holes)          { $legName = 'L2HOLES' }
if ($TileSlack)        { $legName = 'TILESLK' }
if ($Uto)              { $legName = 'UTO' }
if ($UtoV3)            { $legName = 'UTOV3' }
if ($FontSw)           { $legName = 'FONTSW' }
if ($Palette)          { $legName = 'PALETTE' }
if ($BigDdb)           { $legName = 'BIGDDB' }
if ($Xbn)              { $legName = 'XBN' }
$leg = Join-Path $sd $legName

function Reset-LegDir {
    # Empty the run's leg folder, then recreate it. This is the ONLY
    # stale-clean in the script now - the per-file-type sweeps every
    # switch used to carry (sd\*.AKY, sd\*.WAV, the six art extension
    # variants, sd\DAAD.*, sd\00[1-6].VID) existed solely because the
    # sd\ root was shared, and each one only removed the kinds ITS own
    # switch owned, which is exactly how a stale 001.NX2 / DAAD.NX2 /
    # *.AKY survived into a leg that never asked for it.
    #
    # Deliberately narrow: the name must be one of the known leg
    # folders and the resolved path must sit directly under sd\, so a
    # recursive delete can never be pointed anywhere else (and never at
    # sd\ itself, sd\L2DMA\, or anything outside sd\).
    param([string]$Name)
    $known = @('TEMPLATE', 'VID', 'NXBENCH', 'SUITE', 'ERR4', 'GMODE',
               'V3', 'RAB', 'UU', 'PART', 'AUDLAD', 'SFXDI', 'SFXLONG', 'SFX2',
               'L2HOLES', 'TILESLK', 'UTO', 'UTOV3', 'FONTSW', 'PALETTE',
               'BIGDDB', 'XBN')
    if ($known -notcontains $Name) { throw "Reset-LegDir: '$Name' is not a known leg folder" }
    $p = Join-Path $sd $Name
    if ((Split-Path -Parent $p) -ne $sd) { throw "Reset-LegDir: '$p' is not directly under $sd" }
    if (Test-Path -LiteralPath $p) {
        Get-ChildItem -LiteralPath $p -Force | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Force $p | Out-Null
}

# 16x16 8-bit hardware sprite pattern (POINTER.SPR / POINTERn.SPR), a
# solid $fill square with a 2px $E3 (hardware transparent) border and a
# 1px $00 (black) outline - only the fill colour varies, so which shape
# is live is answerable by eye (SP12 Task 3's original green square,
# generalised for SP18 Task 5's three colour-coded shapes: green/red/
# blue for POINTER.SPR/POINTER1.SPR/POINTER2.SPR).
function New-PointerFixture([byte]$fill) {
    $p = New-Object byte[] 256
    for ($y = 0; $y -lt 16; $y++) {
        for ($x = 0; $x -lt 16; $x++) {
            if ($x -lt 2 -or $x -gt 13 -or $y -lt 2 -or $y -gt 13) { $b = 0xE3 }
            elseif ($x -eq 2 -or $x -eq 13 -or $y -eq 2 -or $y -eq 13) { $b = 0x00 }
            else { $b = $fill }
            $p[$y * 16 + $x] = $b
        }
    }
    return $p
}

# Canonical 44-byte RIFF/WAVE/fmt/data header + deterministic 8-bit
# unsigned sine payload, mono, whole cycles only (no click at a loop
# seam) and centred on 128 = DAC_SILENCE (peaks land on 1 and 255) -
# the same three design rules tests\audio\mktone.py documents for the
# -SfxDi tones, reproduced here inline per the SP18 item 7 Task 7 brief
# (these two sizes are not shared with any other fixture's tone, so a
# dedicated Python script would be one more one-shot generator). Used
# only by the -SfxLong staging block below.
function New-SfxLongWav([int]$Rate, [double]$ToneHz, [int]$PayloadBytes) {
    $cycles = $ToneHz * $PayloadBytes / $Rate
    $cyclesRound = [math]::Round($cycles)
    if ([math]::Abs($cycles - $cyclesRound) -gt 1e-9) {
        throw "New-SfxLongWav: $ToneHz Hz over $PayloadBytes bytes at $Rate Hz gives $cycles cycles - not a whole number, the loop would click"
    }
    $pcm = New-Object byte[] $PayloadBytes
    for ($n = 0; $n -lt $PayloadBytes; $n++) {
        $s = [math]::Sin(2.0 * [math]::PI * $cyclesRound * $n / $PayloadBytes)
        $v = [math]::Floor(128 + 127 * $s + 0.5)
        if ($v -lt 0) { $v = 0 } elseif ($v -gt 255) { $v = 255 }
        $pcm[$n] = [byte]$v
    }
    $wav = New-Object System.Collections.Generic.List[byte]
    $wav.AddRange([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $wav.AddRange([System.BitConverter]::GetBytes([UInt32](36 + $PayloadBytes)))
    $wav.AddRange([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
    $wav.AddRange([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $wav.AddRange([System.BitConverter]::GetBytes([UInt32]16))
    $wav.AddRange([System.BitConverter]::GetBytes([UInt16]1))       # PCM
    $wav.AddRange([System.BitConverter]::GetBytes([UInt16]1))       # mono
    $wav.AddRange([System.BitConverter]::GetBytes([UInt32]$Rate))   # sample rate
    $wav.AddRange([System.BitConverter]::GetBytes([UInt32]$Rate))   # byte rate (1 byte/sample, mono)
    $wav.AddRange([System.BitConverter]::GetBytes([UInt16]1))       # block align
    $wav.AddRange([System.BitConverter]::GetBytes([UInt16]8))       # bits per sample
    $wav.AddRange([System.Text.Encoding]::ASCII.GetBytes("data"))
    $wav.AddRange([System.BitConverter]::GetBytes([UInt32]$PayloadBytes))
    $wav.AddRange($pcm)
    return , $wav.ToArray()
}

New-Item -ItemType Directory -Force "$root\tests\out" | Out-Null
New-Item -ItemType Directory -Force $sd | Out-Null

# The COMPILE half of this script writes nothing into sd\ - every
# fixture lands in tests\out\ and the STAGING section further down copies
# whichever ones the run's switches ask for into the one leg folder.
# Keeping the two halves apart is what makes cross-contamination
# impossible by construction rather than by careful cleaning.
$templateXmb = $false
Copy-Item "$PSScriptRoot\test.dsf" "$dr\NDTEST.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDTEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed" }
    & $drcPhp $drcDrb @drcTarget EN NDTEST.json NDTEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed" }
    Move-Item NDTEST.DDB "$root\tests\out\template.ddb" -Force
    # tests\test.dsf has no XMESSAGE yet (Task 5 adds the verb), so DRB
    # emits no 0.XMB for the template - tolerate absence. Wired now so
    # Task 5 needs no script change: $templateXmb makes the staging
    # section copy it next to the template DDB when it does appear.
    if (Test-Path '0.XMB') {
        Move-Item '0.XMB' "$root\tests\out\template.xmb" -Force
        $templateXmb = $true
    }
}
finally {
    Remove-Item "$dr\NDTEST.DSF", "$dr\NDTEST.json", "$dr\0.XMB" -ErrorAction SilentlyContinue
    Pop-Location
}

& "$PSScriptRoot\check-cprops.ps1"

# ---- Layer 2 transparency constants: three files, one pair of values ----
# The transparent COLOUR ($E3) and the reserved INDEX (255) are written
# out longhand in three places in two languages - src/nextdaad.inc is
# canonical, and the other two are the kit's encoder and its audit
# script. There is no shared header they can include, so the only thing
# that keeps them together is this check. A silent divergence is the
# nastiest shape of failure available here: the interpreter would dodge
# one colour while a converter reserved another, and nothing would say
# so until art punched holes on hardware. Runs on EVERY invocation - it
# is source-only, needs no build, and costs three file reads.
function Assert-TranspConstantsInSync {
    # file -> @{ colour = <regex>; index = <regex> }; each regex must
    # capture the literal in group 1. Index is optional, colour is not.
    $sites = [ordered]@{
        'src\nextdaad.inc' = @{
            colour = '(?m)^\s*L2_TRANSP_COLOUR\s+equ\s+\$([0-9A-Fa-f]+)'
            index  = '(?m)^\s*L2_TRANSP_INDEX\s+equ\s+(\d+)'
        }
        'authoring-kit\lib\nxv2enc.py' = @{
            colour = '(?m)^\s*L2_TRANSPARENT_BYTE0\s*=\s*0x([0-9A-Fa-f]+)'
            index  = $null
        }
        'authoring-kit\lib\palcheck.ps1' = @{
            colour = '(?m)^\s*\$TRANSP\s*=\s*0x([0-9A-Fa-f]+)'
            index  = '(?m)^\s*\$RESERVED\s*=\s*(\d+)'
        }
        'authoring-kit\externs\fade\fade.asm' = @{
            colour = '(?m)^\s*TRANSP\s+equ\s+\$([0-9A-Fa-f]+)'
            index  = $null
        }
    }
    # Dodge sites: the substitute colour written on an $E3 collision.
    # Asm and python derive it as colour+N (group 1 = the offset, the
    # site's OWN parsed colour resolves it); the other two carry the
    # absolute value (group 1 = hex). All five resolved values must
    # agree with the canonical nextdaad.inc one.
    $dodgeSites = [ordered]@{
        'src\nextdaad.inc'                    = @{ rx = '(?m)^\s*L2_TRANSP_DODGE\s+equ\s+L2_TRANSP_COLOUR\+(\d+)'; offset = $true }
        'authoring-kit\externs\fade\fade.asm' = @{ rx = '(?m)^\s*TRANSP_DODGE\s+equ\s+TRANSP\+(\d+)'; offset = $true }
        'authoring-kit\lib\nxv2enc.py'        = @{ rx = '(?m)^\s*L2_DODGE_BYTE0\s*=\s*L2_TRANSPARENT_BYTE0\s*\+\s*(\d+)'; offset = $true }
        'authoring-kit\lib\palcheck.ps1'      = @{ rx = '(?m)^\s*\$DODGE\s*=\s*0x([0-9A-Fa-f]+)'; offset = $false }
        'tests\art\mkpalcard.py'              = @{ rx = '(?m)^\s*TRANSP_DODGE\s*=\s*0x([0-9A-Fa-f]+)'; offset = $false }
    }
    $colours = [ordered]@{}
    $indices = [ordered]@{}
    $texts = @{}
    foreach ($rel in $sites.Keys) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) {
            throw "L2 transparency constant sync: $rel is missing - the agreement check needs it (if the file moved, update Assert-TranspConstantsInSync)"
        }
        $text = Get-Content -LiteralPath $path -Raw
        $texts[$rel] = $text
        $m = [regex]::Match($text, $sites[$rel].colour)
        if (-not $m.Success) {
            throw "L2 transparency constant sync: no transparent-colour definition found in $rel (pattern '$($sites[$rel].colour)') - it was renamed or deleted, so nothing is holding the sync sites together any more"
        }
        $colours[$rel] = [Convert]::ToInt32($m.Groups[1].Value, 16)
        if ($sites[$rel].index) {
            $mi = [regex]::Match($text, $sites[$rel].index)
            if (-not $mi.Success) {
                throw "L2 transparency constant sync: no reserved-index definition found in $rel (pattern '$($sites[$rel].index)')"
            }
            $indices[$rel] = [int]$mi.Groups[1].Value
        }
    }
    $dodges = [ordered]@{}
    foreach ($rel in $dodgeSites.Keys) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) {
            throw "L2 transparency constant sync: $rel is missing - the dodge agreement check needs it (if the file moved, update Assert-TranspConstantsInSync)"
        }
        $text = if ($texts.ContainsKey($rel)) { $texts[$rel] } else { Get-Content -LiteralPath $path -Raw }
        $m = [regex]::Match($text, $dodgeSites[$rel].rx)
        if (-not $m.Success) {
            throw "L2 transparency constant sync: no dodge definition found in $rel (pattern '$($dodgeSites[$rel].rx)')"
        }
        if ($dodgeSites[$rel].offset) {
            $base = if ($colours.Contains($rel)) { $colours[$rel] } else { $colours['src\nextdaad.inc'] }
            $dodges[$rel] = $base + [int]$m.Groups[1].Value
        } else {
            $dodges[$rel] = [Convert]::ToInt32($m.Groups[1].Value, 16)
        }
    }
    foreach ($pair in @(@{ n = 'transparent COLOUR'; v = $colours; f = 'X2' },
                        @{ n = 'reserved INDEX';    v = $indices; f = 'D' },
                        @{ n = 'dodge COLOUR';      v = $dodges;  f = 'X2' })) {
        $canon = 'src\nextdaad.inc'
        $want = $pair.v[$canon]
        $bad = @($pair.v.Keys | Where-Object { $pair.v[$_] -ne $want })
        if ($bad.Count -gt 0) {
            $detail = ($pair.v.Keys | ForEach-Object { "$_ = $($pair.v[$_].ToString($pair.f))" }) -join '; '
            throw ("L2 transparency $($pair.n) DESYNC: src\nextdaad.inc says $($want.ToString($pair.f)) but " +
                   (($bad | ForEach-Object { "$_ says $($pair.v[$_].ToString($pair.f))" }) -join ' and ') +
                   ". All copies must move together - $detail")
        }
    }
    "L2 transparency constants agree: colour `$$($colours['src\nextdaad.inc'].ToString('X2')) (4 sites), index $($indices['src\nextdaad.inc']), dodge `$$($dodges['src\nextdaad.inc'].ToString('X2')) (5 sites)"
}
Assert-TranspConstantsInSync

# Proves the PNG-to-transparency chain end to end (tests\art\pngchain.py
# has the full why): a paletted PNG with the transparent colour in the
# reserved slot must survive gfx2next with its palette index intact.
& python "$PSScriptRoot\art\pngchain.py"
if ($LASTEXITCODE -ne 0) { throw "tests\art\pngchain.py failed - the PNG-to-transparency chain is broken" }

function Assert-ManualFresh {
    # authoring-kit\docs is GENERATED and SHIPPED. A .md edited without
    # regenerating ships stale HTML to authors - the same silent-staleness
    # failure the frozen .exe files had. Fail loudly instead.
    $src = Join-Path $root 'manual'
    if (-not (Test-Path $src)) { return }
    $out = Join-Path $root 'authoring-kit\docs'
    foreach ($md in Get-ChildItem $src -Recurse -Filter *.md) {
        $rel = $md.FullName.Substring($src.Length + 1) -replace '\.md$', '.html'
        $html = Join-Path $out $rel
        if (-not (Test-Path $html)) {
            throw "manual: $rel has no generated HTML - run .\build.ps1 -Kit (or python scripts\build_manual.py)"
        }
        if ((Get-Item $html).LastWriteTime -lt $md.LastWriteTime) {
            throw "manual: $($md.Name) is newer than its generated HTML - run .\build.ps1 -Kit before committing"
        }
    }
}

function Assert-ManualIndexed {
    # A page nobody links to is a page nobody reads. Every document must
    # be reachable from the index. Checked one way only (document -> index),
    # so the index may name a document that does not exist yet during the
    # build-out; the reverse would block incremental work.
    $src = Join-Path $root 'manual'
    if (-not (Test-Path $src)) { return }
    $indexPath = Join-Path $src 'index.md'
    if (-not (Test-Path $indexPath)) { throw "manual: no index.md" }
    $index = Get-Content $indexPath -Raw
    foreach ($md in Get-ChildItem $src -Recurse -Filter *.md) {
        if ($md.Name -eq 'index.md') { continue }
        $rel = ($md.FullName.Substring($src.Length + 1) -replace '\\', '/')
        if ($index -notmatch [regex]::Escape($rel)) {
            throw "manual: $rel is not linked from index.md - add it or nobody will find it"
        }
    }
}

Assert-ManualFresh
Assert-ManualIndexed

if (Test-Path (Join-Path $root 'manual')) {
    & python "$PSScriptRoot\manual_facts.py"
    if ($LASTEXITCODE -ne 0) { throw "tests\manual_facts.py failed - the manual contradicts the source" }
}

# overlay2's dma_copy contract, checked against the EMITTED BYTES of the
# current build\nextdaad.nex (tests\dma_contract.py has the full why).
# This runs on every invocation, not behind a switch: dma_copy carries
# every 256-wide picture row and every GFX 0/1, NOTHING host-side renders
# a picture, and the routine has now been broken three times by edits
# that assembled perfectly clean - most recently one that walked the blit
# out of the slot 6 window and over overlay2's own code at $E000. There
# is no emulator leg here to catch that; this is the substitute.
if ((Test-Path "$root\build\nextdaad.nex") -and (Test-Path "$root\build\nextdaad.sld")) {
    & python "$PSScriptRoot\dma_contract.py"
    if ($LASTEXITCODE -ne 0) { throw "tests\dma_contract.py failed - overlay2's dma_copy is mis-emitting its DMA descriptors, do not run this build on hardware" }
}
else {
    "WARNING: no build\nextdaad.nex + .sld - dma_copy contract check SKIPPED (run .\build.ps1 first)"
}

Copy-Item "$PSScriptRoot\condacts.dsf" "$dr\NDSUITE.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDSUITE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (suite)" }
    & $drcPhp $drcDrb @drcTarget EN NDSUITE.json NDSUITE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (suite)" }
    Move-Item NDSUITE.DDB "$root\tests\out\condacts.ddb" -Force
    # condacts.dsf's check 72 always uses XMESSAGE, so DRB always emits
    # 0.XMB here - no Test-Path guard (an absence would be a real
    # regression worth throwing on).
    Move-Item '0.XMB' "$root\tests\out\condacts.xmb" -Force
}
finally {
    Remove-Item "$dr\NDSUITE.DSF", "$dr\NDSUITE.json", "$dr\0.XMB" -ErrorAction SilentlyContinue
    Pop-Location
}

Copy-Item "$PSScriptRoot\doallnest.dsf" "$dr\NDNEST.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDNEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (doallnest)" }
    & $drcPhp $drcDrb @drcTarget EN NDNEST.json NDNEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (doallnest)" }
    Move-Item NDNEST.DDB "$root\tests\out\doallnest.ddb" -Force
}
finally {
    Remove-Item "$dr\NDNEST.DSF", "$dr\NDNEST.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# Oversize fixture: a database PAST THE OLD 31744-BYTE CEILING. Compiled
# unconditionally like the fixtures around it so a break is caught on a
# plain run; only -BigDdb makes it the active GAME.DDB (sd\BIGDDB\).
#
# WHAT IT IS FOR. A classic ZX database bases its pointers at $8400, so
# nothing past 31744 bytes is expressible. The NEXTDAAD target bases them
# at 0, and this fixture is the proof that the whole 64K is reachable: it
# is ~49 KB, and the structures DRC writes LAST - the process list, the
# location and connection tables, and the text of the high-numbered
# messages - all sit past 31744 where the classic scheme could not name
# them at all.
#
# THE COMPILED BYTES ARE ASSERTED, not assumed - the same rule the -SfxDi
# block states. "It compiled" would pass on a database that never crossed
# the boundary, which is the one thing this fixture exists to guarantee,
# and the fixture's size is an emergent property of DRC's text
# compression rather than something the .dsf states directly. So the
# boundary crossings are re-read out of the DDB here, every run.
Copy-Item "$PSScriptRoot\bigddb.dsf" "$dr\NDBIG.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDBIG.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (bigddb)" }
    & $drcPhp $drcDrb @drcTarget EN NDBIG.json NDBIG.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (bigddb)" }
    Move-Item NDBIG.DDB "$root\tests\out\bigddb.ddb" -Force
}
finally {
    Remove-Item "$dr\NDBIG.DSF", "$dr\NDBIG.json" -ErrorAction SilentlyContinue
    Pop-Location
}
$bigBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\bigddb.ddb")
$bigLen = $bigBytes.Length
function Get-BigWord { param([int]$At) $bigBytes[$At] + 256 * $bigBytes[$At + 1] }
# Header identity first: a database that is not this target proves
# nothing about this target's reach.
if ($bigBytes[2] -ne 95) { throw "bigddb: magic byte is $($bigBytes[2]), expected 95" }
if (($bigBytes[1] -band 0xF0) -ne 0xC0) {
    throw "bigddb: machine nibble is $('0x{0:X2}' -f ($bigBytes[1] -band 0xF0)), expected 0xC0 (NEXTDAAD) - the fixture compiled for the wrong target"
}
if (($bigBytes[1] -band 0x0F) -ne 0) {
    throw "bigddb: language nibble is $($bigBytes[1] -band 0x0F), expected 0 (EN) - the machine nibble must not have eaten the language half"
}
# The point of the fixture. 31744 is the classic ceiling; 65535 is the
# format's own, and the interpreter refuses anything larger with E2, so
# a fixture that drifted past it would fail as an oversize database
# rather than proving reach.
if ($bigLen -le 31744) {
    throw "bigddb: $bigLen bytes - NOT past the 31744 classic ceiling, so it tests nothing. DRC token-compresses the text, so the .dsf must grow to move this."
}
if ($bigLen -gt 65535) {
    throw "bigddb: $bigLen bytes - past the 65535 format ceiling, which the interpreter refuses with E2. Shrink the .dsf."
}
# Pointers are FILE OFFSETS, not $8400-rebased addresses. Under the
# classic scheme every one of these would carry a +$8400 bias and the
# tail of a 49 KB database would run off the end of a 16-bit pointer;
# here every header pointer must land inside the file.
foreach ($h in 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30) {
    $v = Get-BigWord $h
    if ($v -ge $bigLen) {
        throw "bigddb: header pointer at offset $h is $v, outside the $bigLen-byte file - pointers are not plain file offsets"
    }
}
# The structures DRC writes last must actually be past the boundary.
# HDR_PROCLST is the one that matters most: condact dispatch reads it on
# every turn, and under the classic scheme it would be unreachable.
$bigProc = Get-BigWord 10
$bigLoc = Get-BigWord 14
$bigMsg = Get-BigWord 16
$bigCon = Get-BigWord 20
foreach ($t in @{n = 'process list'; v = $bigProc }, @{n = 'location table'; v = $bigLoc },
    @{n = 'message table'; v = $bigMsg }, @{n = 'connection table'; v = $bigCon }) {
    if ($t.v -le 31744) {
        throw "bigddb: the $($t.n) is at $($t.v), inside the classic 31744 reach - the fixture is large but its tables are not past the boundary"
    }
}
# MESSAGE 254 is the on-screen evidence the leg is booted for. BOTH its
# lookup entry and the text that entry points at must live past 31744,
# or a screenshot of it proves only that short messages work.
$big254 = Get-BigWord ($bigMsg + 2 * 254)
$big254e = $bigMsg + 2 * 254
if ($big254e -le 31744) { throw "bigddb: message 254's lookup entry is at $big254e, inside the classic reach" }
if ($big254 -le 31744) {
    throw "bigddb: message 254's TEXT is at $big254, inside the classic reach - the location texts are carrying the size instead of the messages, so the printed evidence proves nothing. Lengthen the messages."
}
if ($bigBytes[5] -ne 255) { throw "bigddb: header message count is $($bigBytes[5]), expected 255 (the byte-wide maximum)" }
# EVERY location description must also be past the boundary, which makes the
# room text under the marker second evidence rather than decoration - and
# means it does not matter which room the fixture opens in. Asserted as a
# minimum over all of them so no start-location constant has to be kept in
# step between the generator and this file.
$bigLocLo = 65536
for ($i = 0; $i -lt $bigBytes[4]; $i++) {
    $v = Get-BigWord ($bigLoc + 2 * $i)
    if ($v -lt $bigLocLo) { $bigLocLo = $v }
}
if ($bigLocLo -le 31744) {
    throw "bigddb: the earliest location description is at $bigLocLo, inside the classic 31744 reach - the room text on screen is not evidence of anything"
}
"bigddb: $bigLen bytes, target C0 - process list @$bigProc, message table @$bigMsg, MESSAGE 254 entry @$big254e text @$big254 (all past the 31744 classic ceiling)"

# SP16 Task 1 GMODE graphics-gate fixture. Compiled unconditionally,
# like the suite and doallnest above, so a break in the DSF is caught
# on a plain run; only -GMode makes it the active GAME.DDB (sd\GMODE\).
Copy-Item "$PSScriptRoot\gmodegate.dsf" "$dr\NDGMODE.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDGMODE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (gmodegate)" }
    & $drcPhp $drcDrb @drcTarget EN NDGMODE.json NDGMODE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (gmodegate)" }
    Move-Item NDGMODE.DDB "$root\tests\out\gmodegate.ddb" -Force
}
finally {
    Remove-Item "$dr\NDGMODE.DSF", "$dr\NDGMODE.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# SP16 Task 7 AY ladder fixture. Compiled unconditionally, like the
# suite, doallnest and gmodegate above, so a break in the DSF is caught
# on a plain run; only -AudLad makes it the active GAME.DDB (sd\AUDLAD\).
Copy-Item "$PSScriptRoot\audlad.dsf" "$dr\NDAUDLAD.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDAUDLAD.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (audlad)" }
    & $drcPhp $drcDrb @drcTarget EN NDAUDLAD.json NDAUDLAD.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (audlad)" }
    Move-Item NDAUDLAD.DDB "$root\tests\out\audlad.ddb" -Force
}
finally {
    Remove-Item "$dr\NDAUDLAD.DSF", "$dr\NDAUDLAD.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# Sampled-SFX DMA pre-emption fixture, rev 2 (2026-08-03). Compiled
# unconditionally like the four above so a break in the DSF is caught on
# a plain run; only -SfxDi makes it the active GAME.DDB (sd\SFXDI\).
#
# THE COMPILED BYTES ARE ASSERTED, not assumed. This is a STIMULUS
# fixture - what the interpreter receives is the whole experiment - and
# DRC rewrites stimulus condacts silently: it multiplies every PAUSE by
# getBaseLength/DEFAULT_NOTE_DURAION (120/200 = 0.6 for ZX NEXT,
# drb.php:871-879 + 1509-1551), exactly as it rewrites out-of-range
# BEEPs into PAUSEs. So every number the experiment depends on is
# re-read out of the DDB here:
#   PAUSE 63 -> 38 frames (0.76 s), the two tone reference phases plus
#     the control leg's closing hold;
#   PAUSE 40 -> 24 frames (0.48 s), the four held renders - authored 40
#     precisely because 40 x 0.6 is exactly 24, with no rounding to
#     argue about;
#   the dense phase must arrive as TWENTY-FOUR contiguous DISPLAY 0
#     (48 bytes of 1C 00) and the accumulator as TWENTY contiguous
#     GFX 0 1 + GFX 0 0 pairs (120 bytes) - runs that cannot occur by
#     coincidence;
#   PICTURE 1 must be there at all, since a fixture that never loads
#     the card is exactly the vacuous shape rev 2 exists to replace.
# If any check fails the fixture no longer says what its comments say.
#
# REV 2a ADDS THE EIGHT KEYPRESS BOUNDARIES (owner request: the phases
# ran too fast to attribute a symptom to one). The wait is ANYKEY
# (opcode 24 = $18, ZERO parameters) - NOT "PAUSE 0": this fixture is
# compiled by the plain "DRF.exe zx next" call above with no -v3, its
# header version byte is 2 (asserted below), and PAUSE 0 only means
# GETKEY under V3. Having no operand, ANYKEY is also immune to the
# duration rescaling that the PAUSE checks exist to catch.
# Each site is pinned by the condacts AROUND it (MES = 77 = $4D one
# param, PROCESS = 75 = $4B, PAUSE = $23, SFX = $12), never by a message
# number - DRC reallocates those whenever any string is edited:
#   8 x "MES <n> ANYKEY" total, and no more - the whole pause set;
#   1 x ANYKEY, MES, PAUSE 38   - the card-up boundary before phase 1/5;
#   2 x PAUSE 38, MES, ANYKEY   - the 1/5 boundary and the control
#                                 leg's closing hold;
#   2 x MES, ANYKEY, PROCESS 10 - the two boundaries that hand straight
#                                 into the shared burst;
#   1 x SFX 0 5, MES, MES, ANYKEY - the boundary after the final phase;
#   and, by offset from the three burst runs, the boundaries that close
#     phases 2/5, 3/5 and 4/5.
# The same offsets prove the NEGATIVE that matters more: nothing sits
# INSIDE a burst. The 24-DISPLAY and 20-pair runs are already asserted
# contiguous, and the four held renders are checked to be 4 bytes apart,
# so no pause can have fallen between them - each burst still runs at
# full speed, which is the load under test.
Copy-Item "$PSScriptRoot\sfxdi.dsf" "$dr\NDSFXDI.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDSFXDI.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (sfxdi)" }
    & $drcPhp $drcDrb @drcTarget EN NDSFXDI.json NDSFXDI.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (sfxdi)" }
    Move-Item NDSFXDI.DDB "$root\tests\out\sfxdi.ddb" -Force
}
finally {
    Remove-Item "$dr\NDSFXDI.DSF", "$dr\NDSFXDI.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# SD-streamed sampled-effect wire fixture (SP18 item 7 Task 7). Compiled
# unconditionally like every fixture above so a break in the DSF is
# caught on a plain run; only -SfxLong makes it the active GAME.DDB
# (sd\SFXLONG\). No -v3, deliberately - the fixture uses nothing V3-only
# and its header version must stay 2 like every other fixture here.
#
# OUT OF TREE, for the same reason as l2holes/tileslack/fontsw above and
# by the same means: DRF.exe and DRB.PHP are run by absolute path with
# the cwd set to tests\out\sfxlong-work, so nothing is written under
# tools\ - read-only working material git cannot restore.
$sfxLongWork = Join-Path $root 'tests\out\sfxlong-work'
New-Item -ItemType Directory -Force $sfxLongWork | Out-Null
Copy-Item "$PSScriptRoot\sfxlong.dsf" "$sfxLongWork\NDSFXLNG.DSF" -Force
Push-Location $sfxLongWork
try {
    & $drcDrf @drcTarget NDSFXLNG.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (sfxlong)" }
    & $drcPhp $drcDrb @drcTarget EN NDSFXLNG.json NDSFXLNG.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (sfxlong)" }
    Copy-Item NDSFXLNG.DDB "$root\tests\out\sfxlong.ddb" -Force
}
finally {
    Pop-Location
}

# Two-channel sampled-effect API fixture (SP18 item 7 Task 12). Compiled
# unconditionally like every fixture above so a break in the DSF is
# caught on a plain run; only -Sfx2 makes it the active GAME.DDB
# (sd\SFX2\). No -v3, deliberately - the fixture uses nothing V3-only and
# its header version must stay 2 like every other fixture here. Built out
# of tree for the same reason and by the same means as sfxlong above.
$sfx2Work = Join-Path $root 'tests\out\sfx2-work'
New-Item -ItemType Directory -Force $sfx2Work | Out-Null
Copy-Item "$PSScriptRoot\sfx2.dsf" "$sfx2Work\NDSFX2.DSF" -Force
Push-Location $sfx2Work
try {
    & $drcDrf @drcTarget NDSFX2.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (sfx2)" }
    & $drcPhp $drcDrb @drcTarget EN NDSFX2.json NDSFX2.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (sfx2)" }
    Copy-Item NDSFX2.DDB "$root\tests\out\sfx2.ddb" -Force
}
finally {
    Pop-Location
}

# DRC debug-marker fixture. Compiled unconditionally like the five above,
# and the ONLY fixture here compiled TWICE from one DRF pass: plain, and
# again through DRB's -d ("forced debug mode"), which is what makes DRB
# keep the fake DEBUG condact instead of dropping it (drb.php:1114).
# There is no leg switch and no staging - the whole experiment is the
# emitted bytes, asserted below. tests\debugflag.dsf's own header
# explains what each of its three shapes is for, including the optional
# owner leg (copy tests\out\debugflag-debug.ddb into a leg folder as
# GAME.DDB and boot it).
Copy-Item "$PSScriptRoot\debugflag.dsf" "$dr\NDDBGF.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDDBGF.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (debugflag)" }
    & $drcPhp $drcDrb @drcTarget EN NDDBGF.json NDDBGF.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (debugflag)" }
    Move-Item NDDBGF.DDB "$root\tests\out\debugflag.ddb" -Force
    & $drcPhp $drcDrb @drcTarget EN NDDBGF.json NDDBGF.DDB -d
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (debugflag -d)" }
    Move-Item NDDBGF.DDB "$root\tests\out\debugflag-debug.ddb" -Force
}
finally {
    Remove-Item "$dr\NDDBGF.DSF", "$dr\NDDBGF.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# Layer 2 TRANSPARENCY / punch-out fixture (2026-08-07). Compiled
# unconditionally like the six above so a break in the DSF is caught on a
# plain run; only -L2Holes makes it the active GAME.DDB (sd\L2HOLES\).
#
# THE TOOLCHAIN IS RUN OUT OF TREE HERE, and this is the ONE fixture that
# does. Every block above copies its DSF INTO tools\DAAD-READY and
# compiles with the cwd set there, which WRITES INTO tools\ - read-only
# working material that git cannot restore. Rather than convert the older
# blocks (a separate change, with its own risk), this one runs DRF.exe and
# DRB.PHP by absolute path with the cwd set to tests\out\l2holes-work and
# writes nothing under tools\ at all. The result is byte-identical: DRF
# takes the DSF path as an argument, and DRB's default compression tokens
# are embedded in the PHP (drb.php's $compressionJSON_EN), read from an
# external file only when a <name>.tok sits next to the input - which is
# true in neither location.
#
# The .json is KEPT, not deleted like the others: the ruler verification
# below reads the compiled messages back out of it.
#
# No -v3, deliberately. The fixture's header version must stay 2 (asserted
# below); nothing here depends on a V3 condact, and a V3 header would
# change SYNONYM/attribute semantics under a fixture whose whole value is
# that exactly one thing moves.
$l2holesWork = Join-Path $root 'tests\out\l2holes-work'
New-Item -ItemType Directory -Force $l2holesWork | Out-Null
Copy-Item "$PSScriptRoot\l2holes.dsf" "$l2holesWork\NDL2HOLE.DSF" -Force
Push-Location $l2holesWork
try {
    & $drcDrf @drcTarget NDL2HOLE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (l2holes)" }
    & $drcPhp $drcDrb @drcTarget EN NDL2HOLE.json NDL2HOLE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (l2holes)" }
    Copy-Item NDL2HOLE.DDB "$root\tests\out\l2holes.ddb" -Force
}
finally {
    Pop-Location
}

# --tile-slack A/B fixture (2026-08-07). Compiled unconditionally like
# every block above so a break in the DSF is caught on a plain run; only
# -TileSlack makes it the active GAME.DDB (sd\TILESLK\).
#
# OUT OF TREE, for the same reason as l2holes above and by the same means:
# DRF.exe and DRB.PHP are run by absolute path with the cwd set to
# tests\out\tileslack-work, so nothing is written under tools\ - read-only
# working material git cannot restore.
#
# The .json is KEPT: the verification below reads the compiled verb table
# and messages back out of it, so an arm label that drifts away from the
# video number it plays is caught in the COMPILED bytes rather than by
# reading the DSF twice.
$tileSlackWork = Join-Path $root 'tests\out\tileslack-work'
New-Item -ItemType Directory -Force $tileSlackWork | Out-Null
Copy-Item "$PSScriptRoot\tileslack.dsf" "$tileSlackWork\NDTILESL.DSF" -Force
Push-Location $tileSlackWork
try {
    & $drcDrf @drcTarget NDTILESL.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (tileslack)" }
    & $drcPhp $drcDrb @drcTarget EN NDTILESL.json NDTILESL.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (tileslack)" }
    Copy-Item NDTILESL.DDB "$root\tests\out\tileslack.ddb" -Force
}
finally {
    Pop-Location
}

# Font/pointer switching stimulus fixture (SP18 Task 1, 2026-08-07).
# Compiled unconditionally like every block above so a break in the DSF
# is caught on a plain run, whether or not -FontSw is given - the byte
# assertions below run every time. -FontSw (SP18 Task 5) is the leg
# switch that stages this DDB plus its numbered font/pointer assets into
# sd\FONTSW\ (see that switch's own block in the STAGING section below);
# a plain run with no switches still compiles and asserts fontsw.ddb, it
# just does not stage it anywhere.
#
# OUT OF TREE, for the same reason as l2holes/tileslack above and by the
# same means: DRF.exe and DRB.PHP are run by absolute path with the cwd
# set to tests\out\fontsw-work, so nothing is written under tools\ -
# read-only working material git cannot restore.
$fontswWork = Join-Path $root 'tests\out\fontsw-work'
New-Item -ItemType Directory -Force $fontswWork | Out-Null
Copy-Item "$PSScriptRoot\fontsw.dsf" "$fontswWork\NDFONTSW.DSF" -Force
Push-Location $fontswWork
try {
    & $drcDrf @drcTarget NDFONTSW.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (fontsw)" }
    & $drcPhp $drcDrb @drcTarget EN NDFONTSW.json NDFONTSW.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (fontsw)" }
    Copy-Item NDFONTSW.DDB "$root\tests\out\fontsw.ddb" -Force
}
finally {
    Pop-Location
}

# 256-colour text stimulus fixture. Compiled unconditionally like every
# block above so a break in the DSF is caught on a plain run, whether or
# not -Palette is given - the byte assertions below run every time.
# OUT OF TREE: DRF.exe and DRB.PHP are run by absolute path with the cwd
# set to tests\out\palette-work, so nothing is written under tools\.
$paletteWork = Join-Path $root 'tests\out\palette-work'
New-Item -ItemType Directory -Force $paletteWork | Out-Null
Copy-Item "$PSScriptRoot\palette.dsf" "$paletteWork\NDPAL.DSF" -Force
Push-Location $paletteWork
try {
    & $drcDrf @drcTarget NDPAL.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (palette)" }
    & $drcPhp $drcDrb @drcTarget EN NDPAL.json NDPAL.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (palette)" }
    Copy-Item NDPAL.DDB "$root\tests\out\palette.ddb" -Force
}
finally {
    Pop-Location
}

function Find-ByteRuns {
    # Every start offset of $needle in $hay. Plain scan - the images
    # here are tens of KB, so nothing cleverer is warranted.
    param([byte[]]$hay, [byte[]]$needle)
    $hits = @()
    for ($i = 0; $i -le $hay.Length - $needle.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if ($ok) { $hits += $i }
    }
    return , $hits
}

function Find-MaskedRuns {
    # As Find-ByteRuns, but $null in $pattern matches any byte. Used by
    # the sfxdi ANYKEY checks below to anchor each keypress boundary on
    # its neighbouring condacts while leaving the MES message number - a
    # value DRC reallocates whenever any string in the DSF changes -
    # unconstrained.
    param([byte[]]$hay, [object[]]$pattern)
    $hits = @()
    for ($i = 0; $i -le $hay.Length - $pattern.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $pattern.Length; $j++) {
            if ($null -ne $pattern[$j] -and $hay[$i + $j] -ne $pattern[$j]) { $ok = $false; break }
        }
        if ($ok) { $hits += $i }
    }
    return , $hits
}

function Find-Bytes {
    # Boolean presence check on top of Find-ByteRuns. Not the same as a
    # bare 'if (Find-ByteRuns ...)': PowerShell collapses a one-element
    # array to the truthiness of that single element, so a hit at
    # offset 0 would read as $false. .Count -gt 0 sidesteps that.
    param([byte[]]$hay, [byte[]]$needle)
    return (Find-ByteRuns $hay $needle).Count -gt 0
}

function Assert-SfxDualChannel {
    # SP18 item 7 / Task 8: written RED, ahead of Task 10's channel-2
    # CTC plumbing. nextreg $C5/$CD must enable BOTH CTC channels (bits
    # 0+1, %00000011). Task 10 landed ctc2_isr, the vector 8 carve and
    # the NR $C5/$CD bit-1 writes, so this now runs unconditionally on
    # every harness invocation and passes.
    param([byte[]]$nex)
    # nextreg $C5, %00000011  ->  ED 91 C5 03
    if (-not (Find-Bytes $nex ([byte[]]@(0xED, 0x91, 0xC5, 0x03)))) {
        throw "SFX2: NR `$C5 is not enabling CTC channels 0+1"
    }
    # nextreg $CD, %00000011  ->  ED 91 CD 03
    if (-not (Find-Bytes $nex ([byte[]]@(0xED, 0x91, 0xCD, 0x03)))) {
        throw "SFX2: NR `$CD does not admit both CTC channels"
    }
    # the old single-channel writes must be GONE
    if (Find-Bytes $nex ([byte[]]@(0xED, 0x91, 0xC5, 0x01))) {
        throw "SFX2: stale NR `$C5,1 write present"
    }
    if (Find-Bytes $nex ([byte[]]@(0xED, 0x91, 0xCD, 0x01))) {
        throw "SFX2: stale NR `$CD,1 write present"
    }
    "SFX2: NR `$C5/`$CD both enable CTC channels 0+1 (ED 91 C5/CD 03), no stale single-channel writes"
}

$sfxdiBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\sfxdi.ddb")
# ANYKEY is the V2 wait-for-key condact and this fixture must stay V2 -
# under V3 the interpreter reads PAUSE 0 as GETKEY and SYNONYM changes
# its done-semantics, neither of which this experiment wants to vary.
if ($sfxdiBytes[0] -ne 2) {
    throw "sfxdi: DDB header version byte is $($sfxdiBytes[0]), expected 2 - the fixture is compiled WITHOUT -v3 and its ANYKEY waits assume V2"
}
# The accumulator: 20 x (GFX 0 1 + GFX 0 0). Opcode 87 = $57, two
# params each, so one pair is 57 00 01 57 00 00 and the run is 120
# bytes. This is the phase whose damage PERSISTS (each copy's source is
# the previous copy's destination), so its length is the fixture's
# sensitivity and is pinned exactly.
$gfxRun = [byte[]]@(1..20 | ForEach-Object { 87, 0, 1, 87, 0, 0 })
$gfxHits = Find-ByteRuns $sfxdiBytes $gfxRun
if ($gfxHits.Count -ne 1) {
    throw "sfxdi: expected exactly one 20x'GFX 0 1 + GFX 0 0' run (120 bytes) in tests\out\sfxdi.ddb, found $($gfxHits.Count)"
}
# The dense shipped-path phase: 24 contiguous DISPLAY 0. Opcode 28 =
# $1C, one param, so 48 bytes of 1C 00. gfx_blit routes the staged
# 256-wide card to gfx_row_copy256 -> dma_copy, one call per row.
$dispRun = [byte[]]@(1..24 | ForEach-Object { 28, 0 })
$dispHits = Find-ByteRuns $sfxdiBytes $dispRun
if ($dispHits.Count -ne 1) {
    throw "sfxdi: expected exactly one 24x'DISPLAY 0' run (48 bytes of 1C 00) in tests\out\sfxdi.ddb, found $($dispHits.Count)"
}
# The four HELD renders: DISPLAY 0 followed by PAUSE 20 (authored 40 x
# DRC's 0.5). Without the hold a damaged render flashes past.
# The 0.5 was 0.6 until 2026-08-12: upstream DRC lowered the ZX NEXT base
# note length from 120 to 100, and this harness now compiles against a DRC
# that has that change. Every duration below moved with it.
$heldHits = Find-ByteRuns $sfxdiBytes ([byte[]]@(28, 0, 35, 20))
if ($heldHits.Count -ne 4) {
    throw "sfxdi: expected exactly four 'DISPLAY 0 + PAUSE 20' held renders (1C 00 23 14); found $($heldHits.Count) - DRC's duration scaling has changed"
}
# ...and the four must be back to back, 4 bytes apart. This is the check
# that a keypress boundary has not been dropped INSIDE phase 3/5: the
# pauses are interstitial by design and a burst interrupted mid-run is
# no longer the load the fixture exists to apply.
for ($i = 1; $i -lt 4; $i++) {
    if (($heldHits[$i] - $heldHits[$i - 1]) -ne 4) {
        throw "sfxdi: held renders $($i-1) and $i are $($heldHits[$i] - $heldHits[$i-1]) bytes apart, expected 4 - something has been inserted inside phase 3/5"
    }
}
# PAUSE ($23) 38 - the authored 63 after DRC's 0.6 ZX NEXT scaling.
# Three sites: the two tone reference phases and the control leg's hold.
$pauseHits = Find-ByteRuns $sfxdiBytes ([byte[]]@(35, 32))
if ($pauseHits.Count -lt 3) {
    throw "sfxdi: expected the reference phases and the control hold to compile to PAUSE 32 (23 20); found $($pauseHits.Count) occurrences - DRC's duration scaling has changed"
}
# PICTURE 1 (opcode 84 = $54): without it Layer 2 never comes up and
# the whole visual leg is vacuous - the rev 1 failure, asserted against.
if ((Find-ByteRuns $sfxdiBytes ([byte[]]@(84, 1))).Count -lt 1) {
    throw "sfxdi: 'PICTURE 1' (54 01) not present in tests\out\sfxdi.ddb - the fixture would never bring Layer 2 up"
}
# The three sample calls: SFX 1 2 / SFX 2 2 (load + loop) and SFX 0 5
# (stop both kinds). Opcode 18 = $12.
foreach ($s in @(@{ n = 'SFX 1 2'; b = [byte[]]@(18, 1, 2) },
                 @{ n = 'SFX 2 2'; b = [byte[]]@(18, 2, 2) },
                 @{ n = 'SFX 0 5'; b = [byte[]]@(18, 0, 5) })) {
    if ((Find-ByteRuns $sfxdiBytes $s.b).Count -lt 1) {
        throw "sfxdi: '$($s.n)' not present in tests\out\sfxdi.ddb"
    }
}

# ---- the eight keypress boundaries (rev 2a) -----------------------
# ANYKEY = 24 = $18, no parameters; every site is "MES <caption> ANYKEY".
# Eight and only eight: before phase 1/5 and after each of the five in a
# tone leg, plus the control leg's own card-up and closing boundaries.
# A ninth would mean a pause has landed somewhere unintended.
$akAll = Find-MaskedRuns $sfxdiBytes @(77, $null, 24)
if ($akAll.Count -ne 8) {
    throw "sfxdi: expected exactly eight 'MES <n> + ANYKEY' keypress boundaries (4D ?? 18) in tests\out\sfxdi.ddb, found $($akAll.Count)"
}
# Named sites, each anchored on what follows or precedes it:
#   ANYKEY, MES, PAUSE 38     - the card-up boundary that opens a tone
#                               leg, immediately before phase 1/5;
#   PAUSE 38, MES, ANYKEY     - x2: the 1/5 boundary and the control
#                               leg's closing hold;
#   MES, ANYKEY, PROCESS 10   - x2: the two boundaries that hand
#                               straight into the shared burst (the tone
#                               leg's 1/5 one and the control leg's);
#   SFX 0 5, MES, MES, ANYKEY - the final boundary, after the tone has
#                               been stopped and the card left held.
foreach ($site in @(
        @{ n = 'card-up boundary before phase 1/5 (ANYKEY, MES, PAUSE 32)'; p = @(24, 77, $null, 35, 32); c = 1 },
        @{ n = 'phase 1/5 + control-leg closing boundaries (PAUSE 32, MES, ANYKEY)'; p = @(35, 32, 77, $null, 24); c = 2 },
        @{ n = 'boundaries handing into the shared burst (MES, ANYKEY, PROCESS 10)'; p = @(77, $null, 24, 75, 10); c = 2 },
        @{ n = 'final boundary after phase 5/5 (SFX 0 5, MES, MES, ANYKEY)'; p = @(18, 0, 5, 77, $null, 77, $null, 24); c = 1 })) {
    $hits = Find-MaskedRuns $sfxdiBytes $site.p
    if ($hits.Count -ne $site.c) {
        throw "sfxdi: expected $($site.c) x '$($site.n)'; found $($hits.Count)"
    }
}
# The three burst boundaries, read off the runs themselves so no offset
# is hard-coded. Phase 2/5's caption sits immediately before its run
# with nothing between; the boundary that CLOSES 2/5 is the FF ending
# that entry followed by 'MES <n> ANYKEY MES <n>' introducing 3/5, and
# the same shape closes 3/5 ahead of the GFX run and closes 4/5 after
# it. Any pause that had fallen inside a run would break these.
$d = $dispHits[0]; $h = $heldHits[0]; $g = $gfxHits[0]
foreach ($chk in @(
        @{ n = 'MES caption immediately before the 24x DISPLAY run'; o = $d - 2; v = 77 },
        @{ n = 'entry end (FF) immediately after the 24x DISPLAY run'; o = $d + 48; v = 255 },
        @{ n = 'phase 2/5 closing MES'; o = $d + 49; v = 77 },
        @{ n = 'phase 2/5 closing ANYKEY'; o = $d + 51; v = 24 },
        @{ n = 'phase 3/5 caption MES before the held renders'; o = $h - 2; v = 77 },
        @{ n = 'phase 2/5 closing ANYKEY ahead of the held renders'; o = $h - 3; v = 24 },
        @{ n = 'phase 3/5 closing MES'; o = $g - 5; v = 77 },
        @{ n = 'phase 3/5 closing ANYKEY'; o = $g - 3; v = 24 },
        @{ n = 'phase 4/5 caption MES immediately before the GFX run'; o = $g - 2; v = 77 },
        @{ n = 'entry end (FF) immediately after the GFX run'; o = $g + 120; v = 255 },
        @{ n = 'phase 4/5 closing MES'; o = $g + 121; v = 77 },
        @{ n = 'phase 4/5 closing ANYKEY'; o = $g + 123; v = 24 })) {
    if ($sfxdiBytes[$chk.o] -ne $chk.v) {
        throw ("sfxdi: $($chk.n) - expected byte $('{0:X2}' -f $chk.v) at offset $($chk.o), found " +
               "$('{0:X2}' -f $sfxdiBytes[$chk.o]) - the phase/pause structure has moved")
    }
}
"sfxdi.ddb: v$($sfxdiBytes[0]), 24x DISPLAY 0 at $($dispHits[0]), 4x held render contiguous at $($heldHits[0]), 20x GFX 0 1/0 0 at $($gfxHits[0]), PAUSE 32 x$($pauseHits.Count), 8 ANYKEY boundaries at $($akAll -join ','), PICTURE 1 + SFX 1 2 / 2 2 / 0 5 all present"

# ---- l2holes: the ruler, cell by cell, then the compiled bytes ------
# THE RULER IS THE INSTRUMENT, and its column accounting is fragile in a
# way nothing downstream would notice: NextDAAD buffers non-space
# characters and flushes on a space (src\print.asm prn_char/prn_flush),
# so each MES must be exactly 15 non-space characters plus ONE trailing
# space. A trailing space eaten by an editor would silently merge two
# segments, shift every column left and re-colour the row - and the card
# would then be judged against a ruler that lies. This restates the hole
# table from tests\art\mkl2holes.py INDEPENDENTLY, so a hole that moves
# without its tag moving fails the build instead of the run.
$l2holesJson = Get-Content "$l2holesWork\NDL2HOLE.json" -Raw | ConvertFrom-Json
$l2hMsgs = @{}
foreach ($m in $l2holesJson.messages) { $l2hMsgs[[int]$m.Value] = [string]$m.Text }
$l2hProcs = @{}
foreach ($p in $l2holesJson.processes) { $l2hProcs[[int]$p.Value] = $p.entries }

$l2hTags = @{
    '4,1' = 'TL'; '5,1' = 'TL'; '4,8' = 'TR'; '5,8' = 'TR'
    '26,1' = 'BL'; '27,1' = 'BL'; '26,8' = 'BR'; '27,8' = 'BR'
    '15,2' = 'DG'; '16,2' = 'DG'; '17,2' = 'DG'
    '16,4' = 'CT'; '16,5' = 'CT'; '18,4' = 'CT'
    '15,6' = 'RN'; '15,7' = 'RN'; '13,6' = 'RN'
    '20,2' = '32'; '21,2' = '32'; '20,4' = '16'; '21,4' = '16'; '20,6' = '08'
    '21,3' = '4C'
    '9,3' = 'E3'; '9,4' = 'E3'; '10,3' = 'E3'; '11,4' = 'E3'
    '9,5' = 'E7'; '9,6' = 'E7'; '10,6' = 'E7'; '11,5' = 'E7'
}

$l2hRows = @()
foreach ($tbl in 2, 3) {
    if (-not $l2hProcs.ContainsKey($tbl)) { throw "l2holes: process $tbl is missing - the ruler would be blank" }
    foreach ($e in $l2hProcs[$tbl]) {
        $texts = @()
        $inks = @()
        foreach ($c in $e.condacts) {
            if ($c.Condact -eq 'MES') { $texts += $l2hMsgs[[int]$c.Param1] }
            elseif ($c.Condact -eq 'INK') { $inks += [int]$c.Param1 }
            else { throw "l2holes: unexpected condact '$($c.Condact)' inside the ruler fill" }
        }
        if ($texts.Count -ne 5 -or $inks.Count -ne 5) {
            throw "l2holes: ruler row $($l2hRows.Count) has $($inks.Count) INK / $($texts.Count) MES, expected 5 of each"
        }
        $l2hRows += , @{ text = ($texts -join ''); parts = $texts; inks = $inks }
    }
}
if ($l2hRows.Count -ne 32) { throw "l2holes: the ruler has $($l2hRows.Count) rows, expected 32" }

for ($r = 0; $r -lt 32; $r++) {
    $row = $l2hRows[$r]
    $last = ($r -eq 31)
    # 31 is one cell short on purpose: an 80th character there would wrap,
    # newline and scroll the whole screen up by one (win_newline,
    # src\windows.asm), destroying row 0.
    $wantLen = if ($last) { 79 } else { 80 }
    if ($row.text.Length -ne $wantLen) {
        throw "l2holes: row $r is $($row.text.Length) columns, expected $wantLen"
    }
    for ($i = 0; $i -lt 5; $i++) {
        $p = $row.parts[$i]
        $wantSeg = if ($last -and $i -eq 4) { 15 } else { 16 }
        if ($p.Length -ne $wantSeg) { throw "l2holes: row $r segment $i is $($p.Length) chars, expected $wantSeg" }
        if (-not $p.EndsWith(' ')) { throw "l2holes: row $r segment $i has no trailing space - it would not flush (see src\print.asm prn_flush)" }
        if ($p.Substring(0, $p.Length - 1).Contains(' ')) { throw "l2holes: row $r segment $i has an interior space - the column accounting assumes exactly one, at the end" }
    }
    if ($r -eq 0 -or $r -eq 31) { continue }   # legend rows, not ruler rows
    for ($u = 0; $u -lt 10; $u++) {
        $cell = $row.text.Substring(8 * $u, 8)
        $want = '{0:d2}-{1:d2}' -f $r, (8 * $u)
        if ($cell.Substring(0, 5) -ne $want) {
            throw "l2holes: row $r unit $u reads '$cell', expected it to start '$want'"
        }
        $t = $cell.Substring(5, 2)
        $key = "$r,$u"
        if ($l2hTags.ContainsKey($key)) {
            if ($t -ne $l2hTags[$key]) { throw "l2holes: row $r unit $u is tagged '$t', the card uncovers '$($l2hTags[$key])' there" }
        }
        elseif ($r -lt 4 -or $r -gt 27 -or $u -eq 0 -or $u -eq 9) {
            if ($t -ne 'CM') { throw "l2holes: row $r unit $u is in the control margin but tagged '$t', not CM" }
        }
    }
}

# The JSON above is the front end's view. These are the bytes the
# interpreter will actually execute - checked because DRC has rewritten
# stimulus condacts under this project before (see the sfxdi block).
$l2holesBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\l2holes.ddb")
if ($l2holesBytes[0] -ne 2) {
    throw "l2holes: DDB header version byte is $($l2holesBytes[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
foreach ($s in @(
        @{ n = 'MODE 2 (the More... pager off - without it the fill stops at 31 lines)'; b = [byte[]]@(81, 2) },
        @{ n = 'WINSIZE 32 80 (the full-screen ruler window)'; b = [byte[]]@(107, 32, 80) },
        @{ n = 'WINAT 31 79 + WINSIZE 1 1 (the ANYKEY parking window)'; b = [byte[]]@(82, 31, 79, 107, 1, 1) },
        @{ n = 'PAPER 1 (dark blue - the binary hole detector)'; b = [byte[]]@(65, 1) },
        @{ n = 'PICTURE 1 (the card)'; b = [byte[]]@(84, 1) },
        @{ n = 'DISPLAY 0 (card up)'; b = [byte[]]@(28, 0) },
        @{ n = 'DISPLAY 1 (card cleared - the A/B reference state)'; b = [byte[]]@(28, 1) },
        @{ n = 'ANYKEY (the toggle wait)'; b = [byte[]]@(24) })) {
    if ((Find-ByteRuns $l2holesBytes $s.b).Count -lt 1) { throw "l2holes: '$($s.n)' is not present in tests\out\l2holes.ddb" }
}
"l2holes.ddb: $($l2holesBytes.Length) bytes, v$($l2holesBytes[0]), ruler 32 rows x 80 columns verified from the compiled messages ($($l2hTags.Count) hole tags), MODE 2 / WINSIZE 32 80 / WINAT 31 79 / PAPER 1 / PICTURE 1 / DISPLAY 0 / DISPLAY 1 / ANYKEY all present"

# ---- tileslack: the LABEL must name the file that actually plays -----
# THE ONE FAULT THIS FIXTURE CANNOT SURVIVE is a label that disagrees with
# the video it introduces: the owner would then judge arm B and write it
# down as arm A, and the run would be worse than worthless because nothing
# on screen would say so. The DSF prints the label from one message number
# and plays the clip from a separate GFX parameter, so the two CAN drift.
# This restates the arm table INDEPENDENTLY of the DSF and checks it in the
# COMPILED output: for each verb, the entry must carry the expected
# GFX <video> <13|14>, must print the expected message BOTH times (before
# and after playback), and that message's TEXT must itself name the same
# video file and the same --tile-slack value.
$tsJson = Get-Content "$tileSlackWork\NDTILESL.json" -Raw | ConvertFrom-Json
$tsMsgs = @{}
foreach ($m in $tsJson.messages) { $tsMsgs[[int]$m.Value] = [string]$m.Text }
$tsProcs = @{}
foreach ($p in $tsJson.processes) { $tsProcs[[int]$p.Value] = $p.entries }
if (-not $tsProcs.ContainsKey(5)) { throw "tileslack: process 5 (the verb table) is missing" }

# verb -> (video number, GFX sub-op, label message, slack, loops)
$tsArms = @(
    @{ verb = 'BUN0';  vid = 1; sub = 13; msg = 1; slack = '0.0'; loop = $false; clip = 'BUNNY' },
    @{ verb = 'BUN5';  vid = 2; sub = 13; msg = 2; slack = '0.5'; loop = $false; clip = 'BUNNY' },
    @{ verb = 'LBUN0'; vid = 1; sub = 14; msg = 1; slack = '0.0'; loop = $true;  clip = 'BUNNY' },
    @{ verb = 'LBUN5'; vid = 2; sub = 14; msg = 2; slack = '0.5'; loop = $true;  clip = 'BUNNY' },
    @{ verb = 'JEL0';  vid = 3; sub = 13; msg = 3; slack = '0.0'; loop = $false; clip = 'JELLYFISH' },
    @{ verb = 'JEL5';  vid = 4; sub = 13; msg = 4; slack = '0.5'; loop = $false; clip = 'JELLYFISH' },
    @{ verb = 'LJEL0'; vid = 3; sub = 14; msg = 3; slack = '0.0'; loop = $true;  clip = 'JELLYFISH' },
    @{ verb = 'LJEL5'; vid = 4; sub = 14; msg = 4; slack = '0.5'; loop = $true;  clip = 'JELLYFISH' }
)
foreach ($a in $tsArms) {
    $entry = @($tsProcs[5] | Where-Object { ([string]$_.Entry).Split(' ')[0] -eq $a.verb })
    if ($entry.Count -ne 1) { throw "tileslack: process 5 has $($entry.Count) entries for verb $($a.verb), expected exactly 1" }
    $cs = $entry[0].condacts
    $gfx = @($cs | Where-Object { $_.Condact -eq 'GFX' })
    if ($gfx.Count -ne 1) { throw "tileslack: $($a.verb) has $($gfx.Count) GFX condacts, expected 1" }
    if ([int]$gfx[0].Param1 -ne $a.vid -or [int]$gfx[0].Param2 -ne $a.sub) {
        throw "tileslack: $($a.verb) compiles to GFX $($gfx[0].Param1) $($gfx[0].Param2), expected GFX $($a.vid) $($a.sub)"
    }
    # The label, printed before playback and again after it. Both must be
    # the SAME message, and it must be the one this arm is named by.
    $lab = @($cs | Where-Object { $_.Condact -eq 'MESSAGE' -and [int]$_.Param1 -eq $a.msg })
    if ($lab.Count -ne 2) {
        throw "tileslack: $($a.verb) prints label message $($a.msg) $($lab.Count) time(s), expected 2 (before and after playback)"
    }
    if ($cs[0].Condact -ne 'PROCESS' -or [int]$cs[0].Param1 -ne 7) {
        throw "tileslack: $($a.verb) does not open with PROCESS 7 (the screen header) - the label could be printed over a stale screen"
    }
    # The message TEXT is the thing the owner actually reads. It has to
    # name this arm's own file and its own knob value, or a correct GFX
    # parameter would still be introduced by the wrong caption.
    $text = [string]$tsMsgs[$a.msg]
    $wantFile = '{0:d3}.VID' -f $a.vid
    if ($text -notlike "*$wantFile*") { throw "tileslack: label message $($a.msg) ('$text') does not name $wantFile, which is what $($a.verb) plays" }
    if ($text -notlike "*--tile-slack $($a.slack)*") { throw "tileslack: label message $($a.msg) ('$text') does not name --tile-slack $($a.slack)" }
    # And the CLIP. The verb, the video number and the caption must all agree
    # on WHICH of the kit's two demo clips this arm is - the fixture was
    # relabelled once already (it shipped naming clips it does not contain),
    # and a caption naming the wrong clip is exactly as unattributable as a
    # caption naming the wrong arm.
    if ($text -notlike "*$($a.clip)*") { throw "tileslack: label message $($a.msg) ('$text') does not name $($a.clip), which is the clip $($a.verb) plays" }
    $mode = @($cs | Where-Object { $_.Condact -eq 'MESSAGE' -and [int]$_.Param1 -eq $(if ($a.loop) { 5 } else { 6 }) })
    if ($mode.Count -ne 1) { throw "tileslack: $($a.verb) does not print its $(if ($a.loop) { 'LOOPS' } else { 'PLAYS ONCE' }) line exactly once" }
}
# Every video number staged must be reachable, and no other one may be:
# a GFX naming an unstaged number plays nothing and would read as a clip
# that "did not band", which is the most dangerous false result here.
$tsVids = @($tsProcs[5] | ForEach-Object { $_.condacts } | Where-Object { $_.Condact -eq 'GFX' } | ForEach-Object { [int]$_.Param1 } | Sort-Object -Unique)
if (($tsVids -join ',') -ne '1,2,3,4') { throw "tileslack: the verb table plays videos ($($tsVids -join ',')), expected exactly 1,2,3,4" }

$tsBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\tileslack.ddb")
if ($tsBytes[0] -ne 2) { throw "tileslack: DDB header version byte is $($tsBytes[0]), expected 2" }
foreach ($s in @(
        @{ n = 'MODE 2 (the More... pager off - without it the menu pages)'; b = [byte[]]@(81, 2) },
        @{ n = 'WINSIZE 32 80 (the full-screen text window)'; b = [byte[]]@(107, 32, 80) },
        @{ n = 'DISPLAY 1 (clears Layer 2 after playback - without it the last frame covers the label)'; b = [byte[]]@(28, 1) },
        @{ n = 'ANYKEY (the read-the-label gate before playback)'; b = [byte[]]@(24) })) {
    if ((Find-ByteRuns $tsBytes $s.b).Count -lt 1) { throw "tileslack: '$($s.n)' is not present in tests\out\tileslack.ddb" }
}
# GFX_OPCODE 87 (tools\DAAD-READY\TOOLS\DRC\drb.php) - all eight arms, in
# bytes, independently of the JSON above.
foreach ($a in $tsArms) {
    if ((Find-ByteRuns $tsBytes ([byte[]]@(87, $a.vid, $a.sub))).Count -lt 1) {
        throw "tileslack: GFX $($a.vid) $($a.sub) ($($a.verb)) is not present in tests\out\tileslack.ddb"
    }
}
"tileslack.ddb: $($tsBytes.Length) bytes, v$($tsBytes[0]), 8 A/B arms verified (label message, --tile-slack value and GFX n 13/14 agree for each), videos 1-4 only, MODE 2 / WINSIZE 32 80 / DISPLAY 1 / ANYKEY all present"

# --- fontsw: the font/pointer switching stimulus ---
$fontswBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\fontsw.ddb")
if ($fontswBytes[0] -ne 2) {
    throw "fontsw: DDB header version byte is $($fontswBytes[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
# GFX is opcode 87 ($57), MOUSE is 86 ($56); both take two parameters,
# so each call is three bytes. Assert DRC emitted the sub-commands we
# authored rather than something it rewrote.
foreach ($c in @(@{ n = 'GFX 2 16';  b = [byte[]]@(87, 2, 16) },
                 @{ n = 'GFX 0 16';  b = [byte[]]@(87, 0, 16) },
                 @{ n = 'GFX 3 16';  b = [byte[]]@(87, 3, 16) },
                 @{ n = 'MOUSE 2 5'; b = [byte[]]@(86, 2, 5) },
                 @{ n = 'MOUSE 1 5'; b = [byte[]]@(86, 1, 5) },
                 @{ n = 'MOUSE 0 5'; b = [byte[]]@(86, 0, 5) },
                 @{ n = 'MOUSE 8 6 (DELTAXMS hotspot)'; b = [byte[]]@(86, 8, 6) },
                 @{ n = 'MOUSE 8 7 (DELTAYMS hotspot)'; b = [byte[]]@(86, 8, 7) })) {
    if ((Find-ByteRuns $fontswBytes $c.b).Count -lt 1) {
        throw "fontsw: '$($c.n)' not present in tests\out\fontsw.ddb - DRC did not emit the authored condact"
    }
}
# SP18 Task 1 rev 2: the live tracking loop (MOUSE 100 3 = GETMS, the
# poll, immediately followed by INKEY then a forward SKIP) is authored
# three times, once per shape. DRF resolves all three to the SAME
# relative distance - SKIP is relative to the CURRENT entry, not an
# absolute address, and in every copy the go-back entry is exactly one
# entry on and the loop's exit target exactly two on - so all three
# compile to the byte-identical stream asserted below, and DRB stores
# that stream ONCE, pointing three separate entry headers at it
# (confirmed against DRF's own NDFONTSW.json: 10 distinct process-0
# entries, three of them sharing one physical offset in the .ddb, three
# more sharing another). COUNT HERE IS CORRECTLY 1, NOT 3 - that is
# DRB's normal dedup of identical trailing condact streams, not a
# rewrite, and must not be "fixed" to expect 3. Asserting the full
# 6-byte run (rather than stopping at the MOUSE 8/6 and 8/7 hotspot
# calls the task called "at minimum") is what would actually catch a
# wrong label resolution: a bad SKIP distance breaks this exact byte
# run even though MOUSE 100 3 alone would still be present.
if ((Find-ByteRuns $fontswBytes ([byte[]]@(86, 100, 3, 111, 116, 1))).Count -lt 1) {
    throw "fontsw: 'MOUSE 100 3 + INKEY + SKIP 1' not present in tests\out\fontsw.ddb - the tracking loop's forward exit did not compile as authored"
}
# The go-back entry (a bare SKIP back to the poll) - same dedup
# reasoning as above; all three copies compile to SKIP -2 (254, "the
# previous one" per the DAAD manual) and share one physical offset.
if ((Find-ByteRuns $fontswBytes ([byte[]]@(116, 254))).Count -lt 1) {
    throw "fontsw: 'SKIP 254' (the tracking loop's go-back jump) not present in tests\out\fontsw.ddb"
}
# Debounce PAUSE after every loop exit: authored 25, DRC's ZX NEXT 0.6
# PAUSE scaling (tests\sfxdi.dsf's own header has the derivation) makes
# it exactly 15 with no rounding to argue about. Unlike the shared loop
# bodies above, these three ARE physically distinct runs - each is
# immediately followed by a different next condact (a different shape's
# MOUSE n 5, or END) - so nothing dedups them and the count is pinned
# at exactly 3, one per shape.
$fontswPauseHits = Find-ByteRuns $fontswBytes ([byte[]]@(35, 13))
if ($fontswPauseHits.Count -ne 3) {
    throw "fontsw: expected exactly 3 'PAUSE 25 -> 13' debounce holds (23 0D); found $($fontswPauseHits.Count) - DRC's duration scaling has changed, or a loop exit lost its debounce"
}
"fontsw.ddb: v$($fontswBytes[0]), GFX 2/0/3 16, MOUSE 2/1/0 5, the 8/8 hotspot, the GETMS tracking loop and its x3 debounce PAUSE all present as authored"

# --- palette: the 256-colour text stimulus ---
# PAPER is opcode 65, INK 66, BORDER 67; each takes one parameter, so
# each call is two bytes. The point of these assertions is that the
# parameter reached the database UNFOLDED - DRC declares all three as a
# generic value checked only against 0-255, and if that ever changes
# these fail rather than the interpreter silently receiving 200 AND 15.
$palBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\palette.ddb")
if ($palBytes[0] -ne 2) {
    throw "palette: DDB header version byte is $($palBytes[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
foreach ($c in @(@{ n = 'INK 200';    b = [byte[]]@(66, 200) },
                 @{ n = 'PAPER 37';   b = [byte[]]@(65, 37) },
                 @{ n = 'BORDER 224'; b = [byte[]]@(67, 224) },
                 @{ n = 'INK 224';    b = [byte[]]@(66, 224) },
                 @{ n = 'PAPER 224';  b = [byte[]]@(65, 224) },
                 @{ n = 'INK 28';     b = [byte[]]@(66, 28) },
                 @{ n = 'INK 255';    b = [byte[]]@(66, 255) },
                 @{ n = 'PAPER 64';   b = [byte[]]@(65, 64) })) {
    if ((Find-ByteRuns $palBytes $c.b).Count -lt 1) {
        throw "palette: '$($c.n)' not present in tests\out\palette.ddb - DRC folded or rewrote the authored parameter"
    }
}
"palette.ddb: $($palBytes.Length) bytes, v$($palBytes[0]), 8 extended INK/PAPER/BORDER parameters survived compilation unfolded"

# The pressure process walks 200 distinct papers, which is more
# combinations than the 128-pair tilemap table holds. Assert a
# representative spread reached the DDB rather than trusting the
# generator, and assert the count so a truncated generation is caught.
$paperRuns = 0
for ($p = 16; $p -lt 216; $p++) {
    if ((Find-ByteRuns $palBytes ([byte[]]@(65, $p))).Count -ge 1) { $paperRuns++ }
}
if ($paperRuns -lt 200) {
    throw "palette: only $paperRuns of 200 pressure PAPER values present in tests\out\palette.ddb - the pressure process did not compile whole"
}
"palette.ddb: 200 distinct pressure PAPER values present - exceeds the 128-pair table"
# The Layer 2 card's own condacts. WINAT is opcode 82 (two parameters),
# WINSIZE 107 (two), PICTURE 84 (one), DISPLAY 28 (one). Asserted for the
# same reason as the colour values above: DRC rewrites some condacts'
# parameters silently, so "the DSF says so" is not evidence the
# interpreter will receive it. A rewrite here would leave the card
# drawing over the text, or not drawing at all, and the fixture would
# look merely odd rather than broken.
#
# THE BACKDROP PAIR IS LOAD-BEARING, not layout garnish. WINAT 0 0 with
# WINSIZE 16 80 is the card's exact footprint, cleared to red so that
# swatch 255 - the reserved transparent index - reads as a hole rather
# than as black. If those two ever drift from the card's real geometry
# the fixture silently stops testing transparency at all, so they are
# asserted alongside the picture condacts.
foreach ($c in @(@{ n = 'WINAT 0 0 (card footprint)';    b = [byte[]]@(82, 0, 0) },
                 @{ n = 'WINSIZE 16 80 (card footprint)'; b = [byte[]]@(107, 16, 80) },
                 @{ n = 'WINAT 16 0 (text window)';       b = [byte[]]@(82, 16, 0) },
                 @{ n = 'PICTURE 1';                      b = [byte[]]@(84, 1) },
                 @{ n = 'DISPLAY 0';                      b = [byte[]]@(28, 0) })) {
    if ((Find-ByteRuns $palBytes $c.b).Count -lt 1) {
        throw "palette: '$($c.n)' not present in tests\out\palette.ddb - the Layer 2 card's layout did not compile as authored"
    }
}
"palette.ddb: Layer 2 card layout present (backdrop WINAT 0 0, text WINAT 16 0, both WINSIZE 16 80, PICTURE 1, DISPLAY 0)"

# --- sfxlong: the SD-streamed sampled-effect wire fixture ---
# THE COMPILED BYTES ARE ASSERTED, same rule as sfxdi/fontsw above: DRC
# can silently rewrite condacts, so what the interpreter actually
# receives is verified here rather than assumed from the DSF. SFX is
# opcode 18 = $12, two parameters, so each call is three bytes. Task
# 14b added PICTURE (84), DISPLAY (28), SAVE (25) and LOAD (26), all
# one-parameter condacts (two bytes each), plus the SFX 3 x / SFX 1 9
# sub-commands - same guard, same idiom the sfxdi/l2holes blocks
# already use for their own PICTURE 1 / DISPLAY 0 checks. The 2026-08-09
# bench screen-discipline pass put a CLS (opcode 29, no parameter) ahead
# of every verb's action and added CLR (DISPLAY with a non-zero
# argument, which clears Layer 2 to transparent - see src\overlay2.asm
# h_display) - both checked below as adjacent-byte runs anchored on a
# verb whose action byte sequence is otherwise unique in this DDB, the
# same anchoring idiom Find-MaskedRuns's own header describes for the
# sfxdi ANYKEY checks.
$sfxLongBytes = [System.IO.File]::ReadAllBytes("$root\tests\out\sfxlong.ddb")
if ($sfxLongBytes[0] -ne 2) {
    throw "sfxlong: DDB header version byte is $($sfxLongBytes[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
foreach ($s in @(@{ n = 'SFX 1 1 (PLAY1, effect 1 once)';    b = [byte[]]@(18, 1, 1) },
                 @{ n = 'SFX 1 2 (LOOP1, effect 1 looped)';   b = [byte[]]@(18, 1, 2) },
                 @{ n = 'SFX 2 1 (PLAY2, effect 2 once)';    b = [byte[]]@(18, 2, 1) },
                 @{ n = 'SFX 2 2 (LOOP2, effect 2 looped)';   b = [byte[]]@(18, 2, 2) },
                 @{ n = 'SFX 3 1 (PLAY3, effect 3 once)';    b = [byte[]]@(18, 3, 1) },
                 @{ n = 'SFX 3 2 (LOOP3, effect 3 looped)';   b = [byte[]]@(18, 3, 2) },
                 @{ n = 'SFX 1 9 (VID, video 1 once)';       b = [byte[]]@(18, 1, 9) },
                 @{ n = 'SFX 0 5 (STOP, stop-all)';          b = [byte[]]@(18, 0, 5) },
                 @{ n = 'PICTURE 1 (PIC)';                   b = [byte[]]@(84, 1) },
                 @{ n = 'DISPLAY 0 (PIC)';                   b = [byte[]]@(28, 0) },
                 @{ n = 'SAVE 0 (SAVE)';                     b = [byte[]]@(25, 0) },
                 @{ n = 'LOAD 0 (LOAD)';                     b = [byte[]]@(26, 0) },
                 @{ n = 'CLS + DISPLAY 1 (CLR, the L2/text clear verb)';      b = [byte[]]@(29, 28, 1) },
                 @{ n = 'CLS + SFX 0 5 (STOP, CLS precedes the verb action)'; b = [byte[]]@(29, 18, 0, 5) })) {
    if ((Find-ByteRuns $sfxLongBytes $s.b).Count -lt 1) {
        throw "sfxlong: '$($s.n)' not present in tests\out\sfxlong.ddb - DRC did not emit the authored condact"
    }
}
# Boot autoplay (/PRO 6) issues SFX 1 2 a second time, ahead of the GOTO -
# so the loop sub must occur at least twice in total: once in LOOP1's
# verb entry and once in the boot autoplay entry. Confirms the autoplay
# trigger compiled, not just the verb.
$loop1Hits = (Find-ByteRuns $sfxLongBytes ([byte[]]@(18, 1, 2))).Count
if ($loop1Hits -lt 2) {
    throw "sfxlong: expected SFX 1 2 (18 01 02) at least twice (the LOOP1 verb and the boot autoplay trigger); found $loop1Hits"
}
"sfxlong.ddb: v$($sfxLongBytes[0]), SFX 1 1 / 1 2 / 2 1 / 2 2 / 3 1 / 3 2 / 1 9 / 0 5 all present, PICTURE 1 / DISPLAY 0 / SAVE 0 / LOAD 0 all present, CLS precedes CLR's DISPLAY 1 and STOP's SFX 0 5, SFX 1 2 occurs $loop1Hits times (verb + boot autoplay)"

# --- sfx2: the two-channel sampled-effect API fixture ---
# THE COMPILED BYTES ARE ASSERTED, same rule as sfxdi/sfxlong/fontsw
# above, and here it is load-bearing rather than routine: sub-commands
# 11-16 are new, and a DRC that clamped, remapped or dropped an unknown
# SFX sub-command would ship a fixture that silently tests the old
# single-channel behaviour instead. SFX is opcode 18 = $12, two
# parameters, so each call is three bytes.
$sfx2Bytes = [System.IO.File]::ReadAllBytes("$root\tests\out\sfx2.ddb")
if ($sfx2Bytes[0] -ne 2) {
    throw "sfx2: DDB header version byte is $($sfx2Bytes[0]), expected 2 - this fixture is compiled WITHOUT -v3"
}
foreach ($s in @(@{ n = 'SFX 1 1 (PLAY1, auto, once)';        b = [byte[]]@(18, 1, 1) },
                 @{ n = 'SFX 1 2 (LOOP1, auto, looped)';      b = [byte[]]@(18, 1, 2) },
                 @{ n = 'SFX 2 1 (PLAY2, auto, once)';        b = [byte[]]@(18, 2, 1) },
                 @{ n = 'SFX 2 2 (LOOP2, auto, looped)';      b = [byte[]]@(18, 2, 2) },
                 @{ n = 'SFX 3 1 (the third, uncached effect)'; b = [byte[]]@(18, 3, 1) },
                 @{ n = 'SFX 1 11 (PIN1, channel 1, once)';   b = [byte[]]@(18, 1, 11) },
                 @{ n = 'SFX 1 12 (PIN1L, channel 1, looped)'; b = [byte[]]@(18, 1, 12) },
                 @{ n = 'SFX 2 13 (PIN2, channel 2, once)';   b = [byte[]]@(18, 2, 13) },
                 @{ n = 'SFX 2 14 (PIN2L, channel 2, looped)'; b = [byte[]]@(18, 2, 14) },
                 @{ n = 'SFX 0 15 (STOP1, stop channel 1)';   b = [byte[]]@(18, 0, 15) },
                 @{ n = 'SFX 0 16 (STOP2, stop channel 2)';   b = [byte[]]@(18, 0, 16) },
                 @{ n = 'SFX 0 5 (STOP, the stop-all superset)'; b = [byte[]]@(18, 0, 5) })) {
    if ((Find-ByteRuns $sfx2Bytes $s.b).Count -lt 1) {
        throw "sfx2: '$($s.n)' not present in tests\out\sfx2.ddb - DRC did not emit the authored condact"
    }
}
# The STEAL verb is a THREE-CONDACT sequence and its order is the whole
# test (loop first, then the one-shot, then the uncached third effect):
# assert the three land contiguously, so a DRC reorder or an inserted
# condact cannot quietly turn it into a different experiment.
$stealRun = [byte[]]@(18, 1, 2, 18, 2, 1, 18, 3, 1)
if ((Find-ByteRuns $sfx2Bytes $stealRun).Count -ne 1) {
    throw "sfx2: expected exactly one contiguous STEAL sequence (SFX 1 2 + SFX 2 1 + SFX 3 1); found $((Find-ByteRuns $sfx2Bytes $stealRun).Count)"
}
# Likewise the pin-reject sequence: pin channel 1, pin channel 2, then
# an auto trigger with nowhere to go.
$bothRun = [byte[]]@(18, 1, 12, 18, 2, 14, 18, 3, 1)
if ((Find-ByteRuns $sfx2Bytes $bothRun).Count -ne 1) {
    throw "sfx2: expected exactly one contiguous pin-reject sequence (SFX 1 12 + SFX 2 14 + SFX 3 1); found $((Find-ByteRuns $sfx2Bytes $bothRun).Count)"
}
# Boot autoplay (/PRO 6) issues SFX 1 2 + SFX 2 2 as a pair, and the DUO
# verb issues the same pair - so that two-condact run must occur twice.
$duoRun = [byte[]]@(18, 1, 2, 18, 2, 2)
$duoHits = (Find-ByteRuns $sfx2Bytes $duoRun).Count
if ($duoHits -ne 2) {
    throw "sfx2: expected exactly two 'SFX 1 2 + SFX 2 2' pairs (the DUO verb and the boot autoplay); found $duoHits"
}
"sfx2.ddb: v$($sfx2Bytes[0]), subs 1/2/5 and all six of 11-16 present as authored, STEAL and pin-reject sequences contiguous, DUO pair occurs $duoHits times (verb + boot autoplay)"

# ---- DRC's -D debug marker, both halves of the contract -------------
# HALF ONE: what DRC EMITS. tests\debugflag.dsf has three DEBUG lines;
# with -d they must arrive as three bare $DC opcode bytes at the
# authored positions and nothing else. Message numbers are masked out
# (DRC reallocates those whenever any string in a DSF is edited) but
# every opcode is pinned.
$dbgPlain = [System.IO.File]::ReadAllBytes("$root\tests\out\debugflag.ddb")
$dbgDebug = [System.IO.File]::ReadAllBytes("$root\tests\out\debugflag-debug.ddb")
# ZERO PARAMETERS, proved rather than assumed: one DRF pass, two DRB
# runs, three DEBUG lines, three bytes. Anything with an operand would
# make this 6 or 9 - and an interpreter that skipped only the opcode of
# an operand-carrying marker would desynchronise the whole entry stream.
if (($dbgDebug.Length - $dbgPlain.Length) -ne 3) {
    throw ("debugflag: -d grew the DDB by $($dbgDebug.Length - $dbgPlain.Length) bytes " +
           "(plain $($dbgPlain.Length), -d $($dbgDebug.Length)), expected exactly 3 for three DEBUG lines - " +
           "DRC's fake debug condact is no longer a bare zero-parameter opcode")
}
# PRO 1: DEBUG ($DC) / ISNDONE (115 = $73) / MESSAGE n (38 = $26) /
# DONE (22 = $16). The marker must not mark the table done: NextDAAD's
# dispatcher stamps done BEFORE dispatch for any Action row, and $DC's
# low seven bits are 92 = NEWTEXT, an Action - so a marker that reached
# the condact table would fail this ISNDONE and take the fixture's
# second entry ("FAIL") instead.
if ((Find-MaskedRuns $dbgDebug @(0xDC, 0x73, 0x26, $null, 0x16)).Count -ne 1) {
    throw "debugflag: expected exactly one 'DEBUG + ISNDONE + MESSAGE n + DONE' (DC 73 26 ?? 16) in tests\out\debugflag-debug.ddb"
}
if ((Find-MaskedRuns $dbgPlain @(0x73, 0x26, $null, 0x16)).Count -ne 1 -or
    (Find-ByteRuns $dbgPlain ([byte[]]@(0xDC, 0x73))).Count -ne 0) {
    throw "debugflag: without -d the same entry must be plain 'ISNDONE + MESSAGE n + DONE' (73 26 ?? 16) with no marker - DRB is no longer dropping the fake DEBUG condact"
}
# PRO 2 (never executed - only PRO 0 runs by itself and nothing does
# PROCESS 2) is THE AMBIGUITY CHECK, in bytes: a real NEWTEXT sits
# between two markers, and it is $5C, not $DC. $DC's other possible
# reading is NEWTEXT with the indirection bit, and DRB only sets that
# bit on a condact that HAS parameters (drb.php:1130) while NEWTEXT has
# none (DRF's own table, checked row by row by check-cprops.ps1) - so
# intercepting $DC cannot shadow any real condact. The trailing $16 is
# PRO 1's fallback DONE, immediately before PRO 2's entry.
if ((Find-ByteRuns $dbgDebug ([byte[]]@(0x16, 0xDC, 0x5C, 0xDC, 0xFF))).Count -ne 1) {
    throw "debugflag: expected exactly one 'DEBUG + NEWTEXT + DEBUG' (DC 5C DC) run in tests\out\debugflag-debug.ddb - the marker and a real NEWTEXT must be distinguishable in the byte stream"
}
if ((Find-ByteRuns $dbgPlain ([byte[]]@(0x16, 0x5C, 0xFF))).Count -ne 1) {
    throw "debugflag: expected exactly one bare NEWTEXT (5C) entry in tests\out\debugflag.ddb"
}

# HALF TWO: what the INTERPRETER does with it, read out of the emitted
# image the same way tests\dma_contract.py reads dma_copy's descriptors.
# eng_exec (src\engine.asm) must test for $DC BEFORE the $7F indirection
# mask and loop back to its own fetch, so the marker is consumed without
# reaching cprops/cdisp at all. In emitted bytes that is:
#   .fetch: CD lo hi     call rd_next
#           32 lo hi     ld (curOpcode), a
#           FE FF        cp $FF          (entry terminator)
#           CA lo hi     jp z, .endentry
#           FE DC        cp $DC          <- the marker test
#           28 F1        jr z, .fetch    (-15, back to the call)
#           E6 7F        and $7F         <- the mask it must precede
# The jr displacement is recomputed here rather than hard-coded, so the
# check says "the skip goes back to the fetch" instead of "the byte is
# F1". Same skip-with-a-warning rule as the dma_copy contract above: a
# tree with no build yet is not a failure.
if (Test-Path "$root\build\nextdaad.nex") {
    $nex = [System.IO.File]::ReadAllBytes("$root\build\nextdaad.nex")
    $guard = Find-MaskedRuns $nex @(0xFE, 0xFF, 0xCA, $null, $null, 0xFE, 0xDC, 0x28, $null, 0xE6, 0x7F)
    if ($guard.Count -ne 1) {
        throw ("debug marker: expected exactly one 'cp `$FF / jp z / cp `$DC / jr z / and `$7F' dispatcher guard in build\nextdaad.nex, found $($guard.Count) - " +
               "eng_exec no longer intercepts DRC's debug condact ahead of the indirection mask, so a -D compile would run NEWTEXT at every marker")
    }
    $g = $guard[0]
    $disp = $nex[$g + 8]
    if ($disp -gt 127) { $disp -= 256 }
    $target = $g + 9 + $disp                  # PC after the 2-byte jr, plus displacement
    if ($target -ne ($g - 6) -or $nex[$g - 6] -ne 0xCD -or $nex[$g - 3] -ne 0x32) {
        throw ("debug marker: the `$DC skip in build\nextdaad.nex jumps to offset $target, expected $($g - 6) - " +
               "the re-fetch must land on eng_exec's own 'call rd_next', or a skipped marker leaves the stream pointer wrong")
    }
    "debugflag: -d adds exactly 3 bytes (DC x3, no operands); NEWTEXT stays 5C; eng_exec guard at nex offset $g re-fetches to $target"

    # --- Layer 2 transparency contract (SP18 Priority 0) ---
    # NR $14 is a COLOUR compare against the top 8 bits of the 9-bit palette
    # entry (wiki Global_Transparency_Colour_Register: "compared only by the
    # MSB bits of the final colour"; chapter-next-tilemap.tex:357). $E3 is the
    # hardware reset value and the conventional chroma-key. The reserved PIXEL
    # index is 255 and is a different kind of thing entirely - the two used to
    # be the same number (254) and that was the whole defect.

    # nextreg NR_L2_TRANSP($14), L2_TRANSP_COLOUR($E3)  ->  ED 91 14 E3
    $tr = Find-ByteRuns $nex ([byte[]]@(0xED, 0x91, 0x14, 0xE3))
    if ($tr.Count -lt 1) {
        throw "L2 transparency: no 'nextreg `$14,`$E3' in build\nextdaad.nex - Layer 2 is not on the standard transparent colour"
    }
    $old = Find-ByteRuns $nex ([byte[]]@(0xED, 0x91, 0x14, 0xFE))
    if ($old.Count -ne 0) {
        throw "L2 transparency: found $($old.Count) 'nextreg `$14,`$FE' write(s) - the old cream transparency colour is still being programmed"
    }

    # l2_pal9_stamp: index 255 <- colour $E3, priority bit clear.
    #   ED 91 40 FF   nextreg NR_PAL_INDEX,  L2_TRANSP_INDEX
    #   ED 91 44 E3   nextreg NR_PAL_VALUE9, L2_TRANSP_COLOUR
    #   ED 91 44 00   nextreg NR_PAL_VALUE9, 0   (blue LSB 0, priority 0)
    $stamp = Find-ByteRuns $nex ([byte[]]@(0xED,0x91,0x40,0xFF, 0xED,0x91,0x44,0xE3, 0xED,0x91,0x44,0x00))
    if ($stamp.Count -ne 1) {
        throw "L2 transparency: expected exactly one index-255/colour-`$E3 palette stamp, found $($stamp.Count) - l2_pal9_stamp is not reserving the right entry (or is not clearing the NR `$44 priority bit, chapter-next-palette.tex:279)"
    }

    # tm_clear_blank must set the ORDINARY default attribute, not the old
    # pair-127 "transparent" attribute. Pair 127's paper is dadPalette[7],
    # so the old value painted opaque DAAD white over every uncovered cell
    # - proved 2026-08-06 by recolouring dadPalette[7] green.
    #   3E 00      ld a, TM_ATTR_DEFAULT (reserved pair 0)
    #   32 lo hi   ld (tmAttr), a
    #   3E 20      ld a, GLYPH_SPACE
    #   C3 lo hi   jp tm_fill_rect
    # NOTE: >= 1, not == 1. src\debug.asm's dbg_bar_white independently
    # emits the identical four instructions (ld a,TM_ATTR_DEFAULT /
    # ld (tmAttr),a / ld a,GLYPH_SPACE / jp tm_fill_rect), so this pattern
    # legitimately appears twice in different pages. Do NOT tighten this
    # to an exact count - it will fail for the wrong reason. The
    # load-bearing half of this check is the attribute-254 scan below,
    # which must stay at 0.
    $blank = Find-MaskedRuns $nex @(0x3E, 0x00, 0x32, $null, $null, 0x3E, 0x20, 0xC3)
    if ($blank.Count -lt 1) {
        throw "tm_clear_blank: no 'ld a,0 / ld (tmAttr),a / ld a,`$20 / jp tm_fill_rect' sequence in build\nextdaad.nex - the tilemap blank is not using the default black-paper attribute"
    }
    $stale = Find-MaskedRuns $nex @(0x3E, 0xFE, 0x32, $null, $null, 0x3E, 0x20, 0xC3)
    if ($stale.Count -ne 0) {
        throw "tm_clear_blank: the old attribute-254 clear is still present - uncovered cells will still paint opaque DAAD white"
    }

    # SP18 item 7 / Task 10 landed channel 2's CTC plumbing, so this
    # now runs unconditionally on every harness invocation.
    Assert-SfxDualChannel $nex
}
else {
    "WARNING: no build\nextdaad.nex - eng_exec debug-marker guard check SKIPPED (run .\build.ps1 first)"
    "debugflag: -d adds exactly 3 bytes (DC x3, no operands); NEWTEXT stays 5C"
}

# SP16 Task 6 DAAD V3 fixture. The ONLY DDB this script builds with
# DRF's -v3, so the only one whose header byte 0 is 3. It exercises the
# three V3 opcodes (XMES 120, INDIR 122, SETAT 124), both attribute
# banks, PAUSE 0 as GETKEY, flag 53's bits 0/4/5 and SYNONYM's V3
# done-semantics; the DSF's own header lists which flag carries which
# answer. Compiled unconditionally like the suite and gmodegate above -
# a break in the DSF (or in DRF's -v3 handling) is then caught on a
# plain run - but only -V3 makes it the active GAME.DDB (sd\V3\).
#
# tests\v3probe.dsf will NOT compile without -v3: DRF rejects '@' on a
# second parameter and rejects GETKEY outside V3. Do not "simplify"
# this to reuse the plain invocation above.
#
# SETAT stand-in patch. DRF 0.40 has no SETAT keyword at all - its
# condact table calls slot 124 "dumb", 0 parameters - so each SETAT in
# the fixture is authored as a LET of the same arity, tagged by a
# preceding "LET 250 <n>", and the tagged LET's opcode is rewritten
# from 51 to 124 here. The six-byte signature includes the tag
# precisely so each one is unique in the image; anything other than
# exactly one match means the fixture no longer says what its comments
# say and the build stops. tests\parser\scripts\v3probe\run.py carries
# the same table for the differential legs - keep the two in step.
function Invoke-V3SetatPatch {
    param([string]$Path)
    $sites = @(
        @{ tag = 7; p1 = 0; p2 = 1 },   # SETAT 0 1 - standard bank, set
        @{ tag = 8; p1 = 0; p2 = 2 },   # SETAT 0 2 - standard bank, toggle
        @{ tag = 9; p1 = 0; p2 = 1 }    # SETAT 0 1 - alternative bank
    )
    $b = [System.IO.File]::ReadAllBytes($Path)
    foreach ($s in $sites) {
        $sig = [byte[]](51, 250, $s.tag, 51, $s.p1, $s.p2)
        $hits = @()
        for ($i = 0; $i -le $b.Length - $sig.Length; $i++) {
            $ok = $true
            for ($j = 0; $j -lt $sig.Length; $j++) {
                if ($b[$i + $j] -ne $sig[$j]) { $ok = $false; break }
            }
            if ($ok) { $hits += $i }
        }
        if ($hits.Count -ne 1) {
            throw "v3probe SETAT stand-in tag $($s.tag): $($hits.Count) signature matches in $Path, expected exactly 1"
        }
        $b[$hits[0] + 3] = 124
    }
    [System.IO.File]::WriteAllBytes($Path, $b)
}

Copy-Item "$PSScriptRoot\v3probe.dsf" "$dr\NDV3.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDV3.DSF -v3
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (v3probe)" }
    & $drcPhp $drcDrb @drcTarget EN NDV3.json NDV3.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (v3probe)" }
    $v3hdr = [System.IO.File]::ReadAllBytes("$dr\NDV3.DDB")
    if ($v3hdr[0] -ne 3) {
        throw "v3probe DDB header byte 0 is $($v3hdr[0]), expected 3 - did -v3 reach DRF?"
    }
    Invoke-V3SetatPatch "$dr\NDV3.DDB"
    Move-Item NDV3.DDB "$root\tests\out\v3probe.ddb" -Force
    # The XMES probe always compiles an xmessage, so 0.XMB is always
    # emitted here - no Test-Path guard, an absence would be a real
    # regression worth throwing on.
    Move-Item '0.XMB' "$root\tests\out\v3probe.xmb" -Force
}
finally {
    Remove-Item "$dr\NDV3.DSF", "$dr\NDV3.json", "$dr\NDV3.DDB", "$dr\0.XMB" -ErrorAction SilentlyContinue
    Pop-Location
}

# ===================================================================
# UTO'S OWN DAAD COMPLIANCE TEST - the one third-party fixture here
# ===================================================================
# tools\TEST.DSF is Uto's TestUnitDAAD - the DAAD compliance test
# written by the author of the DRC compiler this project targets, "to
# test compatibility of the new interpreters". Compiled IN PLACE from
# tools\ (gitignored, owner-supplied) BOTH ways, like every other
# fixture above - so a DSF or toolchain break is caught on a plain run -
# with only -Uto / -UtoV3 making either DDB the active GAME.DDB.
#
# GPL-3.0 - CONSUMED, NEVER REDISTRIBUTED. See the licence paragraph in
# the switch documentation at the top of this file. Neither the source
# nor either compiled DDB may be committed: the source stays in
# gitignored tools\, the DDBs land in gitignored tests\out\ and are
# staged into gitignored sd\. Do not copy the DSF into tests\.
#
# WHY TWO BUILDS. The file is titled a V2 test and its non-visual half
# is pure V2, but it also carries two #ifdef "V3" blocks. DRF's -v3
# defines the symbol V3 (its "[additional symbols]" mechanism, confirmed
# against DRF 0.40), so -v3 both raises the header version byte to 3 AND
# switches those blocks in. The two builds are therefore genuinely
# different tests, not the same test at two header bytes, and each gets
# its own leg folder.
#
# THE COMPILED BYTES ARE ASSERTED, same rule as sfxdi above: the whole
# point of a third-party fixture is that it says what its author wrote,
# so the things that would silently hollow it out are re-read out of the
# DDB rather than assumed.
#   header byte 0 - 2 for the V2 build, 3 for the V3 build;
#   the V3-only condacts - the three SETAT sites (opcode 124 = $7C,
#     attribute 16, ops set/clear/toggle) must be present exactly once
#     each in the V3 image and ABSENT ENTIRELY from the V2 image. That
#     pair is what proves #ifdef "V3" resolved the way each build
#     intends; without the negative half a V2 build that silently
#     compiled the V3 blocks would look identical from the outside;
#   GETKEY - DRB compiles the V3 GETKEY keyword down to PAUSE 0
#     ($23 $00), which is exactly the byte pair the interpreter reads as
#     GETKEY under V3 and as a zero-length pause under V2. Asserted
#     present (followed by its PRINT of flag 60) in the V3 image and
#     absent from the V2 one;
#   the boot chain - RESET, CLEAR 100/101/102, SET 200 followed by
#     PROCESS 1 and EXIT 0. This fixture takes NO typed input: /PRO 0
#     runs the whole test at boot and restarts. If that chain is not in
#     the image the leg boots to a prompt and tests nothing, which is
#     the vacuous shape worth asserting against.
#
# ABSENT SOURCE. tools\ is gitignored and owner-supplied, so a fresh
# clone will not have TEST.DSF until the owner downloads it. A plain run
# then WARNS and skips both compiles (it must not break every other
# fixture over an optional third-party file); asking for -Uto/-UtoV3
# without it THROWS, with the URL. Same shape as every other
# owner-provisioned input this script consumes.
$utoDsf = "$root\tools\TEST.DSF"
$utoUrl = 'https://github.com/Utodev/TestUnitDAAD'
$utoBuilt = $false
$utoSetat = @(@{ n = 'SETAT 16 1 (set)';    b = [byte[]]@(124, 16, 1) },
              @{ n = 'SETAT 16 0 (clear)';  b = [byte[]]@(124, 16, 0) },
              @{ n = 'SETAT 16 2 (toggle)'; b = [byte[]]@(124, 16, 2) })
# GETKEY -> PAUSE 0, pinned by the PRINT 60 that reads the key back.
$utoGetkey = [byte[]]@(35, 0, 53, 60)
# RESET, CLEAR 100, CLEAR 101, CLEAR 102, SET 200 - the head of /PRO 0.
$utoBoot = [byte[]]@(127, 48, 100, 48, 101, 48, 102, 47, 200)

function Assert-UtoImage {
    # $Ver = expected header byte 0; $WantV3 = whether the #ifdef "V3"
    # blocks should have compiled in.
    param([string]$Path, [int]$Ver, [bool]$WantV3)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b[0] -ne $Ver) {
        throw "utotest: DDB header byte 0 is $($b[0]), expected $Ver - did the -v3 flag reach DRF (or reach it when it should not have)?"
    }
    foreach ($s in $utoSetat) {
        $n = (Find-ByteRuns $b $s.b).Count
        if ($WantV3 -and $n -ne 1) {
            throw "utotest V3 build: expected exactly one '$($s.n)' (opcode 124) in $Path, found $n - the #ifdef ""V3"" block did not compile in"
        }
        if ((-not $WantV3) -and $n -ne 0) {
            throw "utotest V2 build: '$($s.n)' present in $Path - the #ifdef ""V3"" block compiled into a build that must stay V2"
        }
    }
    $g = (Find-ByteRuns $b $utoGetkey).Count
    if ($WantV3 -and $g -ne 1) {
        throw "utotest V3 build: expected exactly one GETKEY (compiled as PAUSE 0 + PRINT 60, 23 00 35 3C) in $Path, found $g"
    }
    if ((-not $WantV3) -and $g -ne 0) {
        throw "utotest V2 build: a GETKEY (23 00 35 3C) is present in $Path - that block must not compile without -v3"
    }
    if ((Find-ByteRuns $b $utoBoot).Count -ne 1) {
        throw "utotest: the /PRO 0 boot chain (RESET, CLEAR 100/101/102, SET 200) is not in $Path exactly once - the fixture would not self-start"
    }
    foreach ($s in @(@{ n = 'PROCESS 1'; b = [byte[]]@(75, 1) },
                     @{ n = 'EXIT 0';    b = [byte[]]@(110, 0) },
                     @{ n = 'DOALL 1';   b = [byte[]]@(85, 1) })) {
        if ((Find-ByteRuns $b $s.b).Count -lt 1) {
            throw "utotest: '$($s.n)' not present in $Path"
        }
    }
    return $b.Length
}

if (-not (Test-Path -LiteralPath $utoDsf)) {
    if ($Uto -or $UtoV3) {
        throw "-Uto/-UtoV3 need tools\TEST.DSF and it is not there. It is Uto's TestUnitDAAD (GPL-3.0), a third-party file this repository deliberately does NOT vendor - download it from $utoUrl and put TEST.DSF in tools\, then re-run."
    }
    "WARNING: tools\TEST.DSF absent - Uto's third-party compliance test not built (download from $utoUrl into tools\ to enable -Uto/-UtoV3)"
}
else {
    Copy-Item $utoDsf "$dr\NDUTO.DSF" -Force
    Push-Location $dr
    try {
        & $drcDrf @drcTarget NDUTO.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (utotest V2)" }
        & $drcPhp $drcDrb @drcTarget EN NDUTO.json NDUTO.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (utotest V2)" }
        Move-Item NDUTO.DDB "$root\tests\out\utotest.ddb" -Force
    }
    finally {
        # The DSF copy is a build temporary inside the toolchain dir, the
        # same way every other fixture here is compiled, and is removed
        # again on the way out - tools\ ends the run exactly as it began.
        # No 0.XMB either: the fixture uses no XMESSAGE. Swept anyway so a
        # stray one from an earlier compile cannot ride along.
        Remove-Item "$dr\NDUTO.DSF", "$dr\NDUTO.json", "$dr\NDUTO.DDB", "$dr\0.XMB" -ErrorAction SilentlyContinue
        Pop-Location
    }
    $utoV2Len = Assert-UtoImage "$root\tests\out\utotest.ddb" 2 $false

    Copy-Item $utoDsf "$dr\NDUTO3.DSF" -Force
    Push-Location $dr
    try {
        & $drcDrf @drcTarget NDUTO3.DSF -v3
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (utotest V3)" }
        & $drcPhp $drcDrb @drcTarget EN NDUTO3.json NDUTO3.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (utotest V3)" }
        Move-Item NDUTO3.DDB "$root\tests\out\utotest_v3.ddb" -Force
    }
    finally {
        Remove-Item "$dr\NDUTO3.DSF", "$dr\NDUTO3.json", "$dr\NDUTO3.DDB", "$dr\0.XMB" -ErrorAction SilentlyContinue
        Pop-Location
    }
    $utoV3Len = Assert-UtoImage "$root\tests\out\utotest_v3.ddb" 3 $true
    $utoBuilt = $true
    "utotest (tools\TEST.DSF, GPL-3.0, not redistributed): V2 image $utoV2Len bytes (no V3 blocks), V3 image $utoV3Len bytes (SETAT x3 + GETKEY in)"
}

# XBN extern support Task 1 fixture: tests\extern.dsf drives the
# XREG/XCAL/XCNR/XTIK/XSVC/XABS probe verbs against tests\xbn\xbntest.asm
# (the fixture extern binary - see authoring-kit\xbn.inc). Compiled
# unconditionally, like the fixtures above, so a break in either source
# is caught on a plain run; only -Xbn makes the extern DDB active and
# stages GAME.XBN (see its own block in the STAGING section below).
Copy-Item "$PSScriptRoot\extern.dsf" "$dr\NDXBN.DSF" -Force
Push-Location $dr
try {
    & $drcDrf @drcTarget NDXBN.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (extern)" }
    & $drcPhp $drcDrb @drcTarget EN NDXBN.json NDXBN.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (extern)" }
    Move-Item NDXBN.DDB "$root\tests\out\extern.ddb" -Force
}
finally {
    Remove-Item "$dr\NDXBN.DSF", "$dr\NDXBN.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# tests\xbn\xbntest.asm itself. Assembled from the repo root (same cwd
# convention as build.ps1's own sjasmplus call) so its own
# SAVEBIN "tests/out/xbn/GAME.XBN" resolves the same way every time
# regardless of where this script was invoked from. --sym exports
# call_target's address for extern.dsf's XCAL entry - see the coupling
# comment on both sides (tests\xbn\xbntest.asm's call_target label,
# tests\extern.dsf's XCAL entry).
New-Item -ItemType Directory -Force "$root\tests\out\xbn" | Out-Null
Push-Location $root
try {
    & "$root\tools\sjasmplus\sjasmplus.exe" --msg=war --sym="$root\tests\out\xbn\xbntest.sym" "tests\xbn\xbntest.asm"
    if ($LASTEXITCODE -ne 0) { throw "xbntest.asm assembly failed" }
}
finally {
    Pop-Location
}
# Validation-reject variants for Task 2 (staged instead of the good XBN
# by -XbnBad <kind>). Generated unconditionally alongside the good
# GAME.XBN so a break in the generator is caught on a plain run, exactly
# like the corrupt/oversize DDB variants below.
$xbnGood = [IO.File]::ReadAllBytes("$root\tests\out\xbn\GAME.XBN")
$xbnBadMagic = $xbnGood.Clone(); $xbnBadMagic[0] = 0x5A                    # magic
[IO.File]::WriteAllBytes("$root\tests\out\xbn\BADMAGIC.XBN", $xbnBadMagic)
$xbnBadVer = $xbnGood.Clone(); $xbnBadVer[3] = 2                          # version
[IO.File]::WriteAllBytes("$root\tests\out\xbn\BADVER.XBN", $xbnBadVer)
$xbnBadSize = $xbnGood.Clone(); $xbnBadSize[8] = 0x01; $xbnBadSize[9] = 0x40 # size $4001
[IO.File]::WriteAllBytes("$root\tests\out\xbn\BADSIZE.XBN", $xbnBadSize)
[IO.File]::WriteAllBytes("$root\tests\out\xbn\TRUNC.XBN", $xbnGood[0..99])

# The corrupt/oversize variants are derived from the TEMPLATE image (as
# they always were - this read used to sit after the template's own
# template's own sd\GAME.DDB write and before any leg switch overwrote it).
$good = [System.IO.File]::ReadAllBytes("$root\tests\out\template.ddb")

$bad = [byte[]]$good.Clone()
$bad[0] = 9                                  # wrong version byte
[System.IO.File]::WriteAllBytes("$root\tests\out\corrupt.ddb", $bad)

$big = New-Object byte[] (140kb)             # over the 128K cap
[System.Array]::Copy($good, $big, $good.Length)
[System.IO.File]::WriteAllBytes("$root\tests\out\oversize.ddb", $big)

# Malformed-WAV fixture for suite check 69: 16 bytes of non-RIFF
# garbage staged as sd\099.WAV (suite runs with the emulator closed,
# same lock rules as all staging).
$badWav = [byte[]](1..16)
[System.IO.File]::WriteAllBytes("$root\tests\out\badwav.bin", $badWav)

# Truncated-WAV fixture for suite check 70: a byte-exact valid 44-byte
# RIFF+fmt+data header (PCM/mono/8-bit/15000Hz, data chunk promising
# 1000 bytes) with NO payload bytes written after it, staged as
# sd\098.WAV. aud_load_wav's RIFF/fmt probes pass; the streaming read
# then comes up short against the promised data size and must reject
# cleanly (short-read check), not hang.
$truncWav = New-Object System.Collections.Generic.List[byte]
$truncWav.AddRange([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt32]1036))  # RIFF size (arbitrary)
$truncWav.AddRange([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
$truncWav.AddRange([System.Text.Encoding]::ASCII.GetBytes("fmt "))
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt32]16))    # fmt chunk size
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt16]1))     # PCM
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt16]1))     # mono
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt32]15000)) # sample rate
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt32]15000)) # byte rate (unchecked)
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt16]1))     # block align (unchecked)
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt16]8))     # bits per sample
$truncWav.AddRange([System.Text.Encoding]::ASCII.GetBytes("data"))
$truncWav.AddRange([System.BitConverter]::GetBytes([UInt32]1000))  # data size (promised, not delivered)
[System.IO.File]::WriteAllBytes("$root\tests\out\truncwav.bin", $truncWav.ToArray())

# ===================================================================
# STAGING - from here down, everything writes into $leg and nowhere else
# ===================================================================
# The CSpect guard was per-switch; it is hoisted here because the folder
# reset below is now the first thing any run does to sd\, and a running
# emulator holding a file open would leave the folder half-emptied - the
# same partial-fixture hazard each switch used to guard against, just
# earlier. The per-switch guards are left in place (harmless, and they
# document the hazard at each site).
if (Get-Process CSpect -ErrorAction SilentlyContinue) {
    throw "CSpect is running - close it before staging (locked sd\ files leave a partial leg folder)"
}
Reset-LegDir $legName
# Default active game = the template. Every leg switch below overwrites
# it with its own DDB, in the documented last-one-wins order.
Copy-Item "$root\tests\out\template.ddb" "$leg\GAME.DDB" -Force
# ...but its 0.XMB rides along ONLY where the template is actually the
# active game. In the shared root the template's XMB was staged
# unconditionally and every later leg inherited it (a foreign XMB beside
# a foreign DDB - harmless only because those fixtures happen not to
# call XMES). A self-contained folder should hold that leg's files and
# nothing else, and the legs with their own XMB (-Suite/-V3/-Part) stage
# it themselves below.
if ($templateXmb -and ($legName -in @('TEMPLATE', 'VID', 'NXBENCH'))) {
    Copy-Item "$root\tests\out\template.xmb" "$leg\0.XMB" -Force
    "staged tests\out\template.xmb -> sd\$legName\0.XMB"
}

if ($Suite) {
    # Suite semantics assume no sample/music/effects assets staged EXCEPT
    # the one 002.AYS stream check 76 loads - other residue would reroute
    # checks 66/69 through the sample path and an out-of-range AY effect,
    # and a stray 200.AYS would break check 75. sd\SUITE\ was emptied
    # above and only ever holds what this block puts in it, so no
    # per-kind stale-clean is needed (or possible to get wrong).
    Copy-Item "$root\tests\out\condacts.ddb" "$leg\GAME.DDB" -Force
    Copy-Item "$root\tests\out\truncwav.bin" "$leg\098.WAV" -Force
    Copy-Item "$root\tests\out\badwav.bin" "$leg\099.WAV" -Force
    Copy-Item "$root\tests\out\condacts.xmb" "$leg\0.XMB" -Force
    "staged tests\out\condacts.xmb -> sd\$legName\0.XMB"
    # Streamed-song fixture for check 76 (SFX 2 7). Optional: if the audio
    # export has not been run the check still passes as a clean no-op, so
    # warn and continue rather than fail the suite build.
    $ays2 = "$root\tools\audio_assets\002.AYS"
    if (Test-Path $ays2) {
        Copy-Item $ays2 "$leg\002.AYS" -Force
        "staged tools\audio_assets\002.AYS -> sd\$legName\002.AYS (check 76)"
    }
    else {
        "WARNING: $ays2 absent - check 76 will no-op (run the audio export / aysconv.ps1 to exercise the stream path)"
    }
}
if ($Err4) {
    Copy-Item "$root\tests\out\doallnest.ddb" "$leg\GAME.DDB" -Force
}

if ($BigDdb) {
    # Nothing to stage but the DDB - deliberately. The fixture is pure
    # text and processes, so a picture or a tune in the folder would only
    # add ways for the leg to fail for reasons that are not about reach.
    Copy-Item "$root\tests\out\bigddb.ddb" "$leg\GAME.DDB" -Force
    "staged tests\out\bigddb.ddb -> sd\$legName\GAME.DDB ($bigLen bytes - boot it and read the first line: MESSAGE 254 lives past 31744)"
}

$gmodeActive = $false
if ($GMode) {
    # SP16 Task 1 owner leg fixture: tests\gmodegate.dsf gates its
    # PICTURE/DISPLAY on HASAT GMODE (flag 29 bit 7), so the leg needs
    # exactly one Layer 2 picture staged at the player's location
    # number - the fixture starts the player at location 1, so
    # 001.NX2. Source is the Rabenstein art set (already converted,
    # 320-wide NX2), reused rather than converted here: this script has
    # no image-conversion step (see the -Rab block's own note).
    # Same CSpect lock hazard as -Rab/-UU/-Title/-Font: a running
    # emulator holds sd\ files open and the copies fail
    # piecemeal, leaving a mixed extension set the loader's probe chain
    # resolves unpredictably. Refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial gmodegate fixture)"
    }
    Copy-Item "$root\tests\out\gmodegate.ddb" "$leg\GAME.DDB" -Force
    # No per-extension stale-clean: sd\GMODE\ was emptied at the top of
    # the staging section, so this 001.NX2 is the ONLY number-001 art in
    # the folder and the loader's probe chain has nothing else to find.
    $gmodeArt = "$root\tools\Rabenstein-master\nextdaad\1.NX2"
    if (Test-Path $gmodeArt) {
        Copy-Item $gmodeArt "$leg\001.NX2" -Force
        "staged tools\Rabenstein-master\nextdaad\1.NX2 -> sd\$legName\001.NX2 (gmodegate picture)"
    }
    else {
        # Not fatal: with the gate OPEN and no picture the fixture
        # prints its "gate open, picture missing" branch, which still
        # answers the question the leg is asking (is flag 29 bit 7
        # published?). Say so rather than throwing.
        "WARNING: $gmodeArt absent - gmodegate will report the gate result without a picture"
    }
    $gmodeActive = $true
}

$v3Active = $false
if ($V3) {
    # SP16 Task 6: make the V3 database the active game. Same CSpect
    # lock hazard as every other staging switch - a running emulator
    # holds sd\ files open and the DDB/XMB pair would stage
    # piecemeal, which for this fixture means XMES reading a stale
    # 0.XMB from another fixture at the same offsets.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial v3probe fixture)"
    }
    Copy-Item "$root\tests\out\v3probe.ddb" "$leg\GAME.DDB" -Force
    # sd\V3\ holds this fixture's 0.XMB and no other - the stale-XMB
    # hazard the old per-file clean guarded against cannot arise in a
    # folder that was emptied at the top of the staging section.
    Copy-Item "$root\tests\out\v3probe.xmb" "$leg\0.XMB" -Force
    "staged tests\out\v3probe.xmb -> sd\$legName\0.XMB (XMES probe text)"
    $v3Active = $true
}

$xbnActive = $false
if ($Xbn) {
    # XBN extern support Task 1 owner leg fixture: tests\extern.dsf's
    # XREG/XCAL/XCNR/XTIK/XSVC/XABS verbs against tests\xbn\xbntest.asm.
    # Same CSpect lock hazard as every other staging switch.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial XBN fixture)"
    }
    Copy-Item "$root\tests\out\extern.ddb" "$leg\GAME.DDB" -Force
    if ($XbnNoBin) {
        # XABS/no-XBN control: stage the DDB with NO GAME.XBN at all, so
        # the XABS entry's EXTERN must stay inert (flag 200 stays 0).
        "staged tests\out\extern.ddb -> sd\$legName\GAME.DDB (no GAME.XBN staged - -XbnNoBin)"
    }
    elseif ($XbnBad) {
        $xbnBadFile = @{ magic = 'BADMAGIC.XBN'; ver = 'BADVER.XBN'; size = 'BADSIZE.XBN'; trunc = 'TRUNC.XBN' }[$XbnBad]
        Copy-Item "$root\tests\out\xbn\$xbnBadFile" "$leg\GAME.XBN" -Force
        "staged tests\out\xbn\$xbnBadFile -> sd\$legName\GAME.XBN (-XbnBad $XbnBad reject variant)"
    }
    elseif ($XbnTicker) {
        # Task 9 shipped worked example, staged as GAME.XBN INSTEAD of the
        # xbntest.asm fixture, so extern.dsf's XTCK verb has something to
        # drive. Assembled here from the SAME ticker.asm the example's own
        # build.ps1 uses (not forked) into a scratch cwd, so its
        # SAVEBIN "GAME.XBN" cannot collide with the fixture's own
        # tests\out\xbn\GAME.XBN, then moved to tests\out\xbn\TICKER.XBN so
        # the kit example directory stays build-artifact-free.
        $tickerSrcDir = Join-Path $root 'authoring-kit\externs\ticker'
        $tickerBuildDir = Join-Path $root 'tests\out\xbn\_tickerbuild'
        New-Item -ItemType Directory -Force $tickerBuildDir | Out-Null
        Push-Location $tickerBuildDir
        try {
            & "$root\tools\sjasmplus\sjasmplus.exe" --msg=war -I "$root\authoring-kit" "$tickerSrcDir\ticker.asm"
            if ($LASTEXITCODE -ne 0) { throw "authoring-kit\externs\ticker\ticker.asm assembly failed" }
            Move-Item "GAME.XBN" "$root\tests\out\xbn\TICKER.XBN" -Force
        }
        finally {
            Pop-Location
            Remove-Item $tickerBuildDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        # The kit SHIPS a prebuilt GAME.XBN beside the source (owner
        # decision 2026-08-14). This fresh assembly is the drift guard:
        # if the committed binary does not match the source byte for
        # byte, someone edited one without the other - fail loudly.
        $tickerShipped = Join-Path $tickerSrcDir 'GAME.XBN'
        $freshT = [IO.File]::ReadAllBytes("$root\tests\out\xbn\TICKER.XBN")
        $shipT = [IO.File]::ReadAllBytes($tickerShipped)
        if (-not [System.Linq.Enumerable]::SequenceEqual($freshT, $shipT)) {
            throw "authoring-kit\externs\ticker\GAME.XBN is STALE - rebuild it from ticker.asm (its build.ps1) and commit both together"
        }
        Copy-Item "$root\tests\out\xbn\TICKER.XBN" "$leg\GAME.XBN" -Force
        "staged tests\out\xbn\TICKER.XBN -> sd\$legName\GAME.XBN (-XbnTicker: authoring-kit ticker example, not the fixture; shipped prebuilt verified fresh)"
    }
    elseif ($XbnFade) {
        # Layer 2 fade worked example, staged as GAME.XBN INSTEAD of the
        # fixture, so extern.dsf's XFAD/XFDI verbs have something to
        # drive. Same scratch-cwd pattern as -XbnTicker above; also
        # stages the one Layer 2 picture XFAD draws, from the same
        # Rabenstein source the -GMode block reuses (and with the same
        # CSpect-lock refusal - a running emulator holds sd\ files open).
        if (Get-Process CSpect -ErrorAction SilentlyContinue) {
            throw "CSpect is running - close it before staging (locked sd\ files cause a partial fade fixture)"
        }
        $fadeSrcDir = Join-Path $root 'authoring-kit\externs\fade'
        $fadeBuildDir = Join-Path $root 'tests\out\xbn\_fadebuild'
        New-Item -ItemType Directory -Force $fadeBuildDir | Out-Null
        Push-Location $fadeBuildDir
        try {
            & "$root\tools\sjasmplus\sjasmplus.exe" --msg=war -I "$root\authoring-kit" "$fadeSrcDir\fade.asm"
            if ($LASTEXITCODE -ne 0) { throw "authoring-kit\externs\fade\fade.asm assembly failed" }
            Move-Item "GAME.XBN" "$root\tests\out\xbn\FADE.XBN" -Force
        }
        finally {
            Pop-Location
            Remove-Item $fadeBuildDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Same shipped-prebuilt drift guard as -XbnTicker above.
        $fadeShipped = Join-Path $fadeSrcDir 'GAME.XBN'
        $freshF = [IO.File]::ReadAllBytes("$root\tests\out\xbn\FADE.XBN")
        $shipF = [IO.File]::ReadAllBytes($fadeShipped)
        if (-not [System.Linq.Enumerable]::SequenceEqual($freshF, $shipF)) {
            throw "authoring-kit\externs\fade\GAME.XBN is STALE - rebuild it from fade.asm (its build.ps1) and commit both together"
        }
        Copy-Item "$root\tests\out\xbn\FADE.XBN" "$leg\GAME.XBN" -Force
        "staged tests\out\xbn\FADE.XBN -> sd\$legName\GAME.XBN (-XbnFade: authoring-kit fade example, not the fixture; shipped prebuilt verified fresh)"
        $fadeArt = "$root\tools\Rabenstein-master\nextdaad\1.NX2"
        if (Test-Path $fadeArt) {
            Copy-Item $fadeArt "$leg\001.NX2" -Force
            "staged tools\Rabenstein-master\nextdaad\1.NX2 -> sd\$legName\001.NX2 (XFAD picture)"
        }
        else {
            "WARNING: tools\Rabenstein-master\nextdaad\1.NX2 missing - XFAD will have no picture to fade"
        }
        $fadeArt2 = "$root\tools\Rabenstein-master\nextdaad\2.NX2"
        if (Test-Path $fadeArt2) {
            Copy-Item $fadeArt2 "$leg\002.NX2" -Force
            "staged tools\Rabenstein-master\nextdaad\2.NX2 -> sd\$legName\002.NX2 (XFSC/XFSO second scene)"
        }
        else {
            "WARNING: tools\Rabenstein-master\nextdaad\2.NX2 missing - XFSC/XFSO will have no second scene"
        }
    }
    else {
        Copy-Item "$root\tests\out\xbn\GAME.XBN" "$leg\GAME.XBN" -Force
        "staged tests\out\xbn\GAME.XBN -> sd\$legName\GAME.XBN"
    }
    $xbnActive = $true
}

$rabActive = $false
if ($Rab) {
    # A running CSpect holds sd\ files open: the per-file stale-variant
    # cleanup and copies below then fail piecemeal, leaving a MIXED set
    # of shapes that the loader's probe chain resolves unpredictably
    # (NX2 variants win over NXI). Refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial/mixed art sets)"
    }
    # The modernised, next-only DSF (tools\Rabenstein-master\nextdaad) compiles
    # under the bundled DRC with NO preprocessing - every MALUVA X-condact has
    # been removed at source (PICTURE/DISPLAY, SAVE/LOAD, EXIT for the Next
    # reset), so the old remap/grep-gate/MLV_NEXT.BIN shim is gone.
    $rabSrc = "$root\tools\Rabenstein-master\nextdaad"
    Copy-Item "$rabSrc\rabenstein.dsf" "$dr\NDRAB.DSF" -Force
    Push-Location $dr
    try {
        & $drcDrf @drcTarget NDRAB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (rabenstein)" }
        & $drcPhp $drcDrb @drcTarget EN NDRAB.json NDRAB.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (rabenstein)" }
        Copy-Item NDRAB.DDB "$root\tests\out\rabenstein.ddb" -Force
        try {
            Copy-Item NDRAB.DDB "$leg\GAME.DDB" -Force
            Remove-Item NDRAB.DDB -ErrorAction SilentlyContinue
            $rabActive = $true
        }
        catch {
            "WARNING: could not copy to sd\$legName\GAME.DDB (likely locked by a running CSpect - close it and copy $dr\NDRAB.DDB across manually): $_"
        }
    }
    finally {
        Remove-Item "$dr\NDRAB.DSF", "$dr\NDRAB.json", "$dr\NDRAB.___" -ErrorAction SilentlyContinue
        Pop-Location
    }

    # Stage the Layer 2 location art (names zero-padded to 3 digits, the
    # shape the interpreter's picture loader probes for). Source set:
    # N.NX2 (320-wide) by default, N.NXI (256-wide) with -Gfx256.
    # -GfxZx0 compresses each file at staging time with z88dk-zx0
    # (tools\z88dk\bin; -q quick mode keeps the pass to seconds, the
    # ratio difference does not matter for tests) into NNN.<ext>.ZX0
    # - a single whole-file ZX0 stream, which the interpreter's
    # gfx_depack accepts exactly like Gfx2Next's own two-stream output.
    # Gfx2Next itself only compresses at CONVERSION time, from an 8-bit
    # paletted source image:
    #   gfx2next -bitmap -pal-embed -zx0 pic.png N.NX2   -> N.NX2.zx0
    # (same for N.NXI; -zx0 APPENDS ".zx0" to the output name). This
    # script has no image-conversion step - the Rabenstein art ships
    # pre-converted - so -GfxZx0 compresses the shipped files instead.
    # No per-number stale-variant sweep any more: sd\RAB\ was emptied at
    # the top of the staging section, so exactly ONE shape per number
    # exists and the loader's probe chain (NX2.ZX0 -> N2Z -> NX2 ->
    # NXI.ZX0 -> NXZ -> NXI) has no leftover to pick up.
    $srcExt = if ($Gfx256) { 'NXI' } else { 'NX2' }
    $zx0 = "$root\tools\z88dk\bin\z88dk-zx0.exe"
    $staged = 0
    Get-ChildItem "$rabSrc\*.$srcExt" | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object {
        $art = $_
        $padded = '{0:D3}' -f [int]$art.BaseName
        try {
            if ($GfxZx0) {
                & $zx0 -f -q $art.FullName "$leg\$padded.$srcExt.ZX0" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "z88dk-zx0 exited $LASTEXITCODE" }
            }
            else {
                Copy-Item $art.FullName "$leg\$padded.$srcExt" -Force
            }
            $staged++
        }
        catch {
            "WARNING: could not stage $($art.Name) (likely locked by a running CSpect - close it and retry): $_"
        }
    }
    $shape = $srcExt + $(if ($GfxZx0) { '.ZX0' } else { '' })
    "staged $staged Rabenstein art file(s) -> sd\$legName\NNN.$shape"
}

$uuActive = $false
if ($UU) {
    # Same CSpect lock hazard as -Rab: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial/mixed art sets)"
    }
    # tools\urban-upstart\URBAN-UPSTART.DSF is OWNER-AUTHORED and the vendor
    # dir is untracked working material - never edit it here. Compiled
    # exactly like rabenstein.dsf above: copy into DAAD-READY, run DRF/DRB
    # with no preprocessing, and let a DRC failure abort the script (its
    # error surfacing is the point - do not swallow it).
    # NOTE the HYPHEN. This read URBAN_UPSTART.DSF (underscore) from the
    # day it was written, which matches nothing in the vendor dir, so -UU
    # could never have staged - it died on a bare Copy-Item error that
    # named no cause. The only underscore file there is
    # "URBAN_UPSTART 0.1.DSF", a 16 KB 2020 relic; the real game is the
    # 124 KB hyphenated one. Do not "tidy" this back.
    $uuSrc = "$root\tools\urban-upstart"
    $uuDsf = "$uuSrc\URBAN-UPSTART.DSF"
    if (-not (Test-Path $uuDsf)) {
        $found = (Get-ChildItem "$uuSrc\*.DSF" -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.Name }) -join ', '
        throw "-UU source missing: $uuDsf`n  .DSF files present in ${uuSrc}: $(if ($found) { $found } else { '(none)' })"
    }
    Copy-Item $uuDsf "$dr\NDUU.DSF" -Force
    Push-Location $dr
    try {
        & $drcDrf @drcTarget NDUU.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (urbanupstart)" }
        & $drcPhp $drcDrb @drcTarget EN NDUU.json NDUU.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (urbanupstart)" }
        Copy-Item NDUU.DDB "$root\tests\out\urbanupstart.ddb" -Force
        try {
            Copy-Item NDUU.DDB "$leg\GAME.DDB" -Force
            Remove-Item NDUU.DDB -ErrorAction SilentlyContinue
            $uuActive = $true
        }
        catch {
            "WARNING: could not copy to sd\$legName\GAME.DDB (likely locked by a running CSpect - close it and copy $dr\NDUU.DDB across manually): $_"
        }
    }
    finally {
        Remove-Item "$dr\NDUU.DSF", "$dr\NDUU.json", "$dr\NDUU.___" -ErrorAction SilentlyContinue
        Pop-Location
    }

    # Stage whatever location art exists in the vendor dir root (flat
    # N.NXI/N.NX2, no nextdaad-style subfolder). Prefer NX2 (320-wide) if
    # present, else NXI (256-wide) - today only the NXI set ships (~91
    # files, gaps in the numbering tolerated). No -Gfx256/-GfxZx0
    # modifiers: this corpus ships one art shape, so stage exactly what
    # exists. No stale-variant sweep for the same reason as -Rab: sd\UU\
    # was emptied at the top of the staging section, so a Rabenstein NX2
    # at the same number is not even in this folder.
    $uuExt = if (Get-ChildItem "$uuSrc\*.NX2" -ErrorAction SilentlyContinue) { 'NX2' } else { 'NXI' }
    $uuStaged = 0
    Get-ChildItem "$uuSrc\*.$uuExt" | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object {
        $art = $_
        $padded = '{0:D3}' -f [int]$art.BaseName
        try {
            Copy-Item $art.FullName "$leg\$padded.$uuExt" -Force
            $uuStaged++
        }
        catch {
            "WARNING: could not stage $($art.Name) (likely locked by a running CSpect - close it and retry): $_"
        }
    }
    "staged $uuStaged Urban Upstart art file(s) -> sd\$legName\NNN.$uuExt"
}

$partActive = $false
if ($Part) {
    # SP11 Task 6: two-part fixture pair. Same CSpect-lock hazard as
    # -Rab/-UU (four files across two DDBs this time) - refuse to stage
    # rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial part staging)"
    }
    # sd\PART\ was emptied at the top of the staging section, so all four
    # files below are this run's own; only the PARTn\ shadow directory
    # has to be (re)created.
    New-Item -ItemType Directory -Force "$leg\PART2" | Out-Null

    # Part A (leg-folder root) -> GAME.DDB + 0.XMB. Part 1 is root-only
    # by design (h_xpart/xpart_build_name), and "root" here means the
    # directory the game was launched from - the leg folder - so this is
    # byte-identical to staging any other single-part DDB as the active
    # game.
    Copy-Item "$PSScriptRoot\NDPARTA.DSF" "$dr\NDPARTA.DSF" -Force
    Push-Location $dr
    try {
        # SP10 pre-clean lesson (ddb.bat/4a68620): $dr is shared across
        # every fixture this script compiles - delete a stale 0.XMB
        # before each DRB run so it cannot be mistaken for this run's
        # own output (or, worse, silently reused if this DSF's own
        # XMESSAGE/XMES compile step were ever removed).
        Remove-Item '0.XMB' -ErrorAction SilentlyContinue
        & $drcDrf @drcTarget NDPARTA.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (NDPARTA)" }
        & $drcPhp $drcDrb @drcTarget EN NDPARTA.json NDPARTA.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (NDPARTA)" }
        Move-Item NDPARTA.DDB "$leg\GAME.DDB" -Force
        # NDPARTA.DSF always uses XMESSAGE (its own header comment) -
        # no Test-Path guard, matching -Suite's own condacts.xmb
        # handling: an absence here is a real regression worth throwing
        # on, not a silently-tolerated gap like the plain template.
        if (-not (Test-Path '0.XMB')) { throw "NDPARTA.DSF produced no 0.XMB - XMESSAGE missing from the source?" }
        Move-Item '0.XMB' "$root\tests\out\parta.xmb" -Force
        Copy-Item "$root\tests\out\parta.xmb" "$leg\0.XMB" -Force
    }
    finally {
        Remove-Item "$dr\NDPARTA.DSF", "$dr\NDPARTA.json" -ErrorAction SilentlyContinue
        Pop-Location
    }

    # Part 2 -> GAME2.DDB + PART2\0.XMB (the PARTn\ shadow the
    # interpreter's asset probe expects - SP11 Task 5).
    Copy-Item "$PSScriptRoot\NDPARTB.DSF" "$dr\NDPARTB.DSF" -Force
    Push-Location $dr
    try {
        Remove-Item '0.XMB' -ErrorAction SilentlyContinue
        & $drcDrf @drcTarget NDPARTB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (NDPARTB)" }
        & $drcPhp $drcDrb @drcTarget EN NDPARTB.json NDPARTB.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (NDPARTB)" }
        Move-Item NDPARTB.DDB "$leg\GAME2.DDB" -Force
        if (-not (Test-Path '0.XMB')) { throw "NDPARTB.DSF produced no 0.XMB - XMES missing from the source?" }
        Move-Item '0.XMB' "$root\tests\out\partb.xmb" -Force
        Copy-Item "$root\tests\out\partb.xmb" "$leg\PART2\0.XMB" -Force
    }
    finally {
        Remove-Item "$dr\NDPARTB.DSF", "$dr\NDPARTB.json" -ErrorAction SilentlyContinue
        Pop-Location
    }

    $partActive = $true
    $partaSize = (Get-Item "$leg\GAME.DDB").Length
    $partbSize = (Get-Item "$leg\GAME2.DDB").Length
    $partaXmbSize = (Get-Item "$leg\0.XMB").Length
    $partbXmbSize = (Get-Item "$leg\PART2\0.XMB").Length
    "staged NDPARTA -> sd\$legName\GAME.DDB ($partaSize bytes) + sd\$legName\0.XMB ($partaXmbSize bytes)"
    "staged NDPARTB -> sd\$legName\GAME2.DDB ($partbSize bytes) + sd\$legName\PART2\0.XMB ($partbXmbSize bytes)"
}

if ($Title) {
    # SP11 Task 1 owner leg fixture: title_present/title_boot (overlay2.asm)
    # probe DAAD.* at boot, so the owner-eye-leg needs one staged.
    # tools\demo-files\DAAD.NX2 is the owner-authored 320x256 title,
    # a gfx2next-converted Layer 2 picture (ADAPTIVE 256,
    # -bitmap -pal-embed; 82432 bytes = 512 pal + 320x256).
    # No DAAD.* variant sweep: the leg folder was emptied at the top of
    # the staging section, so exactly one title is present and the
    # NX2-first probe order is what the leg exercises. The flip side
    # matters more - a leg that does NOT pass -Title now gets no title
    # at all, where a survivor in the shared root used to starve the
    # graphics cache and silently turn burst picture draws into no-ops.
    # Same CSpect lock hazard as -Rab/-UU: refuse to stage rather than
    # warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial title fixture)"
    }
    Copy-Item "$root\tools\demo-files\DAAD.NX2" "$leg\DAAD.NX2" -Force
    "staged tools\demo-files\DAAD.NX2 -> sd\$legName\DAAD.NX2 (320x256 owner title)"
}

if ($Font) {
    # SP12 Task 2 owner leg fixture: font_load (overlay2.asm) probes
    # FONT.CHR at boot (and PARTn\FONT.CHR for parts >= 2), so the
    # owner-eye-leg needs one staged. tools\demo-files\fonts\Crews is a
    # 768-byte classic ZX charset (chars 32-127) - a bold, tilted,
    # graffiti-style face, visually distinctive from the interpreter's
    # plain embedded font at a glance. No test binary is committed
    # (authoring-kit hard rule for this task): fontconv.ps1 builds the
    # full 2048-byte FONT.CHR fresh each run from the .ch8 source
    # plus authoring-kit\lib\default.chr.
    # Same CSpect lock hazard as -Rab/-UU/-Title: refuse to stage rather
    # than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial font fixture)"
    }
    # tools\demo-files\fonts\Crews ships as Crews.zip and is not always
    # extracted (owner-provisioned demo material, not this repo's to
    # unpack) - degrade to no custom font rather than let fontconv.ps1
    # throw on a missing source. That matches "Default (no -Font) stages
    # no font" above: without the archive, -Font stages nothing either,
    # just with a warning explaining why.
    $fontSrc = "$root\tools\demo-files\fonts\Crews\Spectrum\Crews.ch8"
    if (Test-Path $fontSrc) {
        & "$root\authoring-kit\lib\fontconv.ps1" -In $fontSrc -Out "$leg\FONT.CHR" | Out-Null
        $fontSize = (Get-Item "$leg\FONT.CHR").Length
        "staged tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 -> sd\$legName\FONT.CHR ($fontSize bytes, via fontconv.ps1)"
    }
    else {
        "WARNING: $fontSrc absent (Crews.zip not extracted under tools\demo-files\fonts) - FONT.CHR not staged, the embedded font will show instead"
    }

    # SP12 Task 3 owner leg fixture: pointer_load (overlay0.asm) probes
    # POINTER.SPR at boot (and PARTn\POINTER.SPR for parts >= 2), so
    # the owner-eye-leg needs one staged alongside the font fixture just
    # above - same switch, no separate -Pointer flag. No binary is
    # committed (same policy as the font fixture): New-PointerFixture
    # (defined above) generates the 256 bytes right here, a 16x16 solid
    # square with a 2px $E3 (hardware transparent) border, a 1px $00
    # (black) outline, and a $1C (pure green, RGB332) fill - a shape and
    # colour obviously different from mouseArrow's own compiled-in
    # black/white diagonal arrow (overlay0.asm) at a glance.
    [System.IO.File]::WriteAllBytes("$leg\POINTER.SPR", (New-PointerFixture 0x1C))
    "staged a generated 16x16 green square (2px `$E3 border, `$00 outline) -> sd\$legName\POINTER.SPR (256 bytes)"
}

# Bump this whenever a silicon-settled constant OR output-shaping
# internal in nxv2enc.py changes (TMODEL_COEFFS,
# TMODEL_COMPOSITION_FACTOR, TMODEL_SILICON_R, palette/dither
# pipeline, etc) - see the -Vid header comment for why an arg-list
# hash can't catch this class of change. History: 'gap115' = the
# Card #5 gapped resettlement (factor 1.55 -> 1.15, commit
# 4814921); 'pal9' = the 2026-07-27 palette-collapse fix
# (display-lattice palettes + true 9th blue bit + ordered dither -
# wire output changes with identical CLI args); 'pal9b' = the
# palette-lattice review fix-wave (2026-07-27, commits dcc2230/
# 5b47727 review): nearest-level lattice snap (was truncating >>5)
# and DITHER_AMP corrected to the true lattice bin spacing (was ~12%
# narrow) - the pal9 encodes were never hardware-eyeballed, so one
# bump covers both the pal9 and pal9b output-shaping changes at once;
# 'pal9c' = the 2026-07-28 blue-noise dither wave: 32x32 void-and-
# cluster threshold tile replaces the 8x8 Bayer matrix and the default
# dither amplitude drops to 0.5 of a quantization step (videnc
# --dither knob) - every default-args encode's bytes change;
# 'pal9d' = the 2026-07-28 transparency-collision exclusion: palette
# entries packing to byte0 $FE (the player's NR $14 global
# transparency colour) rendered as transparent holes on real
# hardware - the two colliding lattice points (255,255,146)/
# (255,255,182) are excluded from the representable lattice.
# Used by BOTH -Vid and -VidLong cache names (the -VidLong per-entry
# 'tag' only fingerprints CLI operating points, so it is equally
# blind to this class).
# 'pal9e' = the 2026-07-28 SP17 copy-DMA T-model restoration: the
# decode-T model gained the mem-to-mem DMA copy term the task-2
# settlement measured (1091.8 T/chunk + 5.31 T/B) and had been dropped
# from the encoder, so every streamed encode re-derives its per-frame
# op budget. See $encoderGeneration 'pal9f' in authoring-kit/lib/video.ps1.
# 'pal9f' = the 2026-07-28 DMA threshold derivation: NXV2_RUN_DMA_MIN
# 64 -> 71 and NXV2_COPY_DMA_MIN 90 -> 74 (both re-derived as
# setup/(cpu_rate - dma_rate) from the task-2 coefficients), with the
# encoder's mirrors and _fill_t's chunk-and-gate moved to match, so the
# modelled cost of copies in the 74-89 B band and of every multi-chunk
# fill changes and streamed encodes re-derive their op budget. See
# $encoderGeneration 'pal9g' in authoring-kit/lib/video.ps1.
# NO BUMP for the SP17 Yliluoma wave (2026-07-28), deliberately: it
# ADDED an opt-in dither (videnc --dither-mode mixture) and left the
# default path untouched - all six fixtures re-encode SHA256-identical
# to the pre-wave encoder for the same arguments, verified, so a bump
# would have forced a full re-encode for no byte change. See the same
# note on $encoderGeneration in authoring-kit/lib/video.ps1.
# BUMP pal9f -> pal9h (Card #8 silicon re-fit, 2026-07-28): the
# composition factors were re-fitted on measured silicon (flat
# 1.00 -> 1.14, gapped 1.15 -> 1.41 - 003 was missing its frame period
# at the shipped value) and the streaming supply gate's busy term was
# corrected to true decode wall time with the omitted AUDIO phase
# added. TMODEL_COMPOSITION_FACTOR, TMODEL_SILICON_R and
# stream_supply_check all moved, so every leg fixture re-encodes.
# Tag jumps straight to pal9h to stay in step with
# $encoderGeneration in authoring-kit/lib/video.ps1.
# BUMP pal9h -> pal9i (SP17 T0 source retiming, 2026-07-30): videnc now
# BLENDS a source whose own frame rate differs from --fps to the target
# rate, where it used to take the nearest source frame (drop/duplicate).
# No CLI argument changes, so this tag is the only thing that can see
# it. Every fixture off a non-25p source re-encodes: Sintel is 24 fps
# (001/002/004/007/010), Big Buck Bunny 30 (003/008), Jellyfish 29.97
# (005/009). 006 and 011 come off tools\demo-files\1920x1080-25p.mp4 and
# are byte-identical - the filter is skipped outright at the target
# rate - but they re-encode anyway because the tag is in their cache
# name. See $encoderGeneration 'pal9i' in authoring-kit/lib/video.ps1.
# BUMP pal9i -> pal9j (SP17 adaptive tile ladder, 2026-07-30): the
# budget-bound delta schedule walks {32,64,128,256,band} per bound frame
# and keeps the finest rung that still spends >= 99% of the best rung's
# bytes, with raw err2 band importance in place of sqrt(err2). Every
# fixture with a budget-bound frame re-encodes; 002/005/006 come out
# byte-identical (no bound frame, or no rung beats the band) but
# re-encode anyway because the tag is in their cache name. See
# $encoderGeneration 'pal9j' in authoring-kit/lib/video.ps1.
# BUMP pal9j -> pal9k (tile ladder RE-CUT, 2026-07-30): owner silicon read
# the pal9j ladder as displacement and tearing on 007 (mode-0). Sub-line
# rungs are struck - the ladder walks whole paint-order LINES now - and a
# finer rung must preserve the frame's modelled SUPPLY cost, not just its
# bytes, so it can no longer take decode-T that the auto-budget search
# then pays for in wire (007's budget went 0.64 -> 0.47 under pal9j).
# Every fixture with a budget-bound frame re-encodes; 002/005/006 come out
# byte-identical again but re-encode because the tag is in their cache
# name. See $encoderGeneration 'pal9k' in authoring-kit/lib/video.ps1.
# NO BUMP for the SP17 supply-slack knob (2026-07-30), deliberately: it
# ADDED an opt-in option (videnc --tile-slack, default 0.0 = off) and
# left the default path untouched - all 11 leg/long fixtures re-encode
# SHA256-identical to the pre-knob encoder for the same arguments,
# verified, so a bump would have forced a full re-encode for no byte
# change. See the same note on $encoderGeneration in
# authoring-kit/lib/video.ps1.
# BUMP pal9k -> pal9l (SP17 T8 wave copy-DMA threshold correction,
# 2026-08-01): NXV2_COPY_DMA_MIN 74 -> 81 on the NXBC C073/C074
# measurement (the kernel-only derivation missed the +128 T/op
# fast-handler -> slow-body path difference; measured break-even 81.4)
# with the encoder mirror (copy_dma_min + the new copy_dma_path_t term)
# moved in the same commit. 74-80 B copies re-price as LDI and every
# DMA-path copy op carries the path term, so the modelled decode-T
# changes and every streamed fixture re-derives its op budget. See
# $encoderGeneration 'pal9l' in authoring-kit/lib/video.ps1.
# BUMP pal9l -> pal9m (SP17 W4 encoder wave, 2026-08-02): keyframe-span
# peak pacing (chunks re-priced at the chunked-DMA rate, per-frame
# supply-bounded to 0.95 of the period - keyframe peaks no longer
# out-demand the wire at any budget), 5 s keyframe cadence default,
# drift/staleness triggers re-based on 4x4 local-mean PSNR, the
# NXBO/NXBC two-key dispatch split with the silicon_r density re-key
# and re-derived composition factors (flat 1.19 / gapped 1.46). Every
# fixture re-encodes; streamed fixtures re-derive their budgets ~2-4%
# tighter. See $encoderGeneration 'pal9m' in authoring-kit/lib/video.ps1.
# BUMP pal9m -> pal9n (direct-gate silicon re-fit, 2026-08-02): the
# direct-serve gate re-fitted from the NXBD re-run and the 056/057
# whole-frame playback pair (DIRECT_TRANSPORT_FACTOR 1.20 -> 1.00
# per-byte + the new fixed DIRECT_FRAME_OVERHEAD_MS 2.2). All 12 leg/
# long fixtures re-encode BYTE-IDENTICAL (the gate moves admission,
# not emitted bytes - 010/011 stay the 256x133 regression anchors,
# verified by SHA on the re-encode); the bump records which gate an
# encode was admitted under, since the direct envelope moved
# (25 fps stereo 256x133 -> 256x153; 320x256@12.5 stereo now legal).
# See $encoderGeneration 'pal9n' in authoring-kit/lib/video.ps1.
# BUMP pal9n -> pal9o (SP17 W5 cadence rolling refresh, 2026-08-02):
# the cadence keyframe span (owner silicon: a mid-clip paused frame -
# the span's paced repaint holds the visible surface until KFLIP) is
# replaced by a rolling refresh expressed as ordinary delta frames
# (forced-clean coverage inside the normal per-frame caps, carry-over
# under contention). Measured at the bump (SHA-verified): legs 001-006
# byte-identical (shorter than the 5 s window), 007 byte-identical
# (its cuts fire natural keyframes inside every window), direct
# 010/011 byte-identical; 008 re-encodes +3072 B and 009 -9728 B with
# roll traffic in place of their cadence keyframes (kf events 2 -> 1
# each). See $encoderGeneration 'pal9o' in authoring-kit/lib/video.ps1.
# BUMP pal9o -> pal9p (SP17 low-fps supply + roll guards, 2026-08-02):
# the streamed supply gate now prices the player's low-fps pace
# contention (room-limited T10 audio feed stealing the SD producer's
# only window - three 12.5 fps silicon rows over rate at gate 0.89-0.90)
# and the W5 rolling refresh gains its two corpus-sweep guards. Every
# leg/long fixture is 25 fps, where the contention term is EXACTLY zero,
# so the GATE change moves no fixture; what does move is the roll -
# 008/009 are the only fixtures whose cadence fires, and the guards
# change what their roll frames spend and when their window closes
# (009's window used to strand 12 positions for 124 frames). Measured at
# the bump, SHA-verified: see the table below. See $encoderGeneration
# 'pal9p' in authoring-kit/lib/video.ps1.
# BUMP pal9p -> pal9q (SP17 audio ring = the whole audio bank,
# 2026-08-02): the player's circular audio feed ring grows 2560 -> 8192
# bytes (the session audio bank was always an exclusive 8 KB page with
# 5632 bytes idle), which removes the low-fps pace contention pal9p had
# just priced, and the declarable per-frame audio bound moves
# 2544 -> 3072. Every leg/long fixture is 25 fps, where the contention
# term was ALREADY exactly zero and the audio layout is unchanged, so
# all twelve re-encode BYTE-IDENTICAL - SHA-verified against the pal9p
# caches. The tag moves because the encoder's constants did, which is
# this switch's whole discipline. See $encoderGeneration 'pal9q' in
# authoring-kit/lib/video.ps1.
# BUMP pal9q -> pal9r (SP17 provenance re-derivation, 2026-08-03): two
# silicon-settled constants in nxv2enc.py moved - merge_kstar is priced
# on the supply exchange rate (19.9 T/B) instead of fetch_long, and a
# 16-bit-operand COPY pays the measured slow-parser entry instead of
# copy_dma_path_t. Both are default-path, so this switch's rule fires.
# Measured at the bump, SHA-verified: see the table below.
# See $encoderGeneration 'pal9r' in authoring-kit/lib/video.ps1.
# BUMP pal9r -> pal9s (SP17 DMA DI-bracket fix, 2026-08-03): the
# player's audio-safety burst cap NXV2_DMA_CHUNK moved 256 -> 240 and
# the encoder's copy_dma_chunk/fill_dma_min moved with it, so every
# clip re-prices its DMA bodies ~0.6% dearer in decode-T and
# budget-bound frames admit marginally less. Default-path, so this
# switch's rule fires. This tag was left at 'pal9r' for one day after
# 446f33d bumped $encoderGeneration - see the sync assertion below,
# which exists so that cannot happen again.
# BUMP pal9s -> pal9t (Layer 2 transparency colour move to $E3, encoder
# side, 2026-08-07): build_palette_block's byte0 dodge and the older
# TRANSP_COLLISION/TRANSP_REMAP lattice exclusion (in snap_to_lattice)
# both moved from guarding the old cream $FE pair to the live $E3 pair
# ((255,0,219)/(255,0,255)) - default-path, so this switch's rule
# fires. See $encoderGeneration 'pal9t' in authoring-kit/lib/video.ps1
# for the full account.
# BUMP pal9t -> pal9u (Layer 2 dodge target move $E2 -> $E7,
# 2026-08-18): build_palette_block's collision nudge moved from
# byte0-1 to byte0+4 in lockstep with the interpreter dodge -
# default-path, so this switch's rule fires. See $encoderGeneration
# 'pal9u' in authoring-kit/lib/video.ps1 for the full account.
$vidLegSettlementTag = 'pal9u'

# INVARIANT: $vidLegSettlementTag MUST equal $encoderGeneration in
# authoring-kit/lib/video.ps1. They are one stamp with two homes - the
# kit's per-title encode-cache key and this harness's fixture-cache key
# - and both exist to force a re-encode when a silicon-settled constant
# in nxv2enc.py moves. If they drift, one side keeps serving a cache
# encoded under the OLD constants and nothing says so. Assert it at the
# point of use rather than at script load, so a desync fails the video
# staging switches and leaves the unrelated DDB fixtures alone.
function Assert-VidEraInSync {
    $videoPs1 = Join-Path $root 'authoring-kit\lib\video.ps1'
    if (-not (Test-Path -LiteralPath $videoPs1)) {
        throw "$videoPs1 missing - cannot verify the encoder era stamp"
    }
    # single-quoted pattern: the `$ must reach the regex engine as a
    # literal, and a double-quoted string would expand it away
    $m = [regex]::Match((Get-Content -LiteralPath $videoPs1 -Raw),
                        '(?m)^\s*\$encoderGeneration\s*=\s*''([^'']+)''')
    if (-not $m.Success) {
        throw "no `$encoderGeneration assignment found in $videoPs1 - the era-stamp sync check needs one"
    }
    if ($m.Groups[1].Value -ne $vidLegSettlementTag) {
        throw ("encoder era stamp DESYNC: video.ps1 `$encoderGeneration = '$($m.Groups[1].Value)' " +
               "but build-tests.ps1 `$vidLegSettlementTag = '$vidLegSettlementTag'. " +
               "Bump both together (they key two encode caches off the same encoder state) " +
               "and add the matching BUMP note in each file.")
    }
}

if ($Vid) {
    Assert-VidEraInSync
    # SP15 T1 NXV v2 LEG SET fixtures (SP15 3a calibration wave,
    # 2026-07-25) - see the -Vid switch's own header comment above for
    # the full shape/source/start/duration mapping and the pre-3a
    # long-clip cache retirement note. Same CSpect-lock hazard as
    # -Rab/-UU/-Title/-Font: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial video fixture)"
    }
    # No stale-clean here: sd\VID\ is emptied once at the top of the
    # staging section and -Vid/-VidLong both fill it, which is why they
    # must be given TOGETHER for the 001-011+099 card (section 40.5).
    # The SP15 T5 per-file scoping this used to carry was a workaround
    # for the shared root and has no job left.
    $vidOutDir = Join-Path $root 'tests\out'
    New-Item -ItemType Directory -Force $vidOutDir | Out-Null
    # dest file -> (NXV v2 shape preset, source clip, --start, --duration)
    # - exact leg-card values (sp14a-task-4-report.md section 37 + the
    # CALIBRATION WAVE addendum) that reproduce the leg-staged bytes
    # byte-for-byte (the encoder is deterministic).
    $vidLegMap = [ordered]@{
        '001.VID' = @{ shape = 'full';         src = (Join-Path $root 'tools\demo-files\Sintel_1080_10s_30MB.mp4');         start = '00:00:00'; duration = '1.35' }
        '002.VID' = @{ shape = 'classic';      src = (Join-Path $root 'tools\demo-files\Sintel_1080_10s_30MB.mp4');         start = '00:00:00'; duration = '1.8' }
        '003.VID' = @{ shape = '16:9';         src = (Join-Path $root 'tools\demo-files\Big_Buck_Bunny_1080_10s_30MB.mp4'); start = '00:00:03'; duration = '1.0' }
        '004.VID' = @{ shape = 'scope';        src = (Join-Path $root 'tools\demo-files\Sintel_1080_10s_30MB.mp4');         start = '00:00:00'; duration = '1.7' }
        '005.VID' = @{ shape = 'classic-wide'; src = (Join-Path $root 'tools\demo-files\Jellyfish_1080_10s_30MB.mp4');      start = '00:00:04'; duration = '1.6' }
        '006.VID' = @{ shape = '16:9';         src = (Join-Path $root 'tools\demo-files\1920x1080-25p.mp4');                start = '00:00:00'; duration = '5.0' }
    }
    $vidStaged = 0
    foreach ($dest in $vidLegMap.Keys) {
        $shape = $vidLegMap[$dest].shape
        $src = $vidLegMap[$dest].src
        $start = $vidLegMap[$dest].start
        $duration = $vidLegMap[$dest].duration
        if (-not (Test-Path -LiteralPath $src)) {
            "WARNING: $src missing - sd\$legName\$dest not generated"
            continue
        }
        $shapeTag = $shape -replace ':', ''
        $cache = Join-Path $vidOutDir "$([IO.Path]::GetFileNameWithoutExtension($dest))_${shapeTag}_${vidLegSettlementTag}_leg_cache.vid"
        if (-not (Test-Path -LiteralPath $cache)) {
            "encoding sd\$legName\$dest (shape $shape, source $(Split-Path -Leaf $src), start $start dur $duration) via videnc.py - slow, cached at tests\out\$(Split-Path -Leaf $cache) after this run..."
            # canonical encoder lives in the kit (see -Vid header); repo
            # tools ffmpeg passed explicitly - the kit default resolves
            # to authoring-kit\tools\ffmpeg, absent on a fresh clone
            & python "$root\authoring-kit\lib\videnc.py" $src $cache --shape $shape --fps 25 --start $start --duration $duration --ffmpeg "$root\tools\ffmpeg\bin\ffmpeg.exe"
            if ($LASTEXITCODE -ne 0) { throw "videnc.py failed (exit $LASTEXITCODE) - sd\$legName\$dest not staged" }
        }
        if (Test-Path -LiteralPath $cache) {
            Copy-Item -LiteralPath $cache -Destination "$leg\$dest" -Force
            $vidStaged++
        }
    }
    "staged $vidStaged video fixture(s) -> sd\$legName\001.VID..006.VID (NXV v2 leg set: full/classic/16:9/scope/classic-wide/16:9-card, sp14a-task-4-report.md section 37)"
}

if ($VidLong) {
    Assert-VidEraInSync
    # SP15 3b STREAMING leg fixtures - full-duration research-clip
    # encodes bigger than the pool ring (see the -VidLong header
    # comment). Cached like -Vid, and shares sd\VID\ with it: give both
    # switches in one invocation for the full 001-011+099 card.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial video fixture)"
    }
    $vidOutDir = Join-Path $root 'tests\out'
    New-Item -ItemType Directory -Force $vidOutDir | Out-Null
    # extraArgs = the streaming-supply operating point (see the -VidLong
    # header comment); tag makes it part of the cache name so a changed
    # point re-encodes instead of silently reusing a stale cache
    $vidLongMap = [ordered]@{
        # 007's operating point RE-DERIVED at the pal9 palette-collapse
        # fix (2026-07-27): dithered display-lattice targets raise the
        # delta demand, the old default point now scores util 1.06 and
        # the gate refuses it; 0.85 is the gate's own named remedy but
        # landed at util 1.00 - AT the streaming ceiling, where the wire
        # bytes carried delta starvation (stale horizontal bands on
        # 123/250 frames at the delta byte ceiling, confirmed on real
        # hardware; player exonerated, zero underruns). Fix (2026-07-28,
        # owner-track): keep sb 0.85, lower dither demand with --dither
        # 0.25 - util 0.981 (below the ceiling), delta-p10 24.68 vs the
        # starved 23.37. Owner ruling 2026-07-28: 007 STAYS this
        # deliberate at-capacity stress fixture - it is still 36.4%
        # budget-bound and still bands on silicon, which is the
        # documented expected picture here (see the -VidLong header).
        # CARD #8 (2026-07-28): all three streamed operating points are
        # now AUTO-DERIVED. The corrected supply gate refuses every one
        # of the hand-pinned budgets below (007 sb0.85+d0.25, 008 sb0.51,
        # 009 sb0.54), and 008 is why: silicon underran it 914/1286 and
        # 1141/1508 frames on two runs with the ring pinned at a depth of
        # one sector, at a budget the OLD gate had passed at util 0.934.
        # Hand-picking a replacement would just be the same guess at a
        # moving target - the encoder's own search (SP17 T1, the shipping
        # default) lands each clip at the 0.90 target under whatever the
        # gate currently is, and re-derives itself when it next moves.
        '007.VID' = @{ shape = 'classic'; src = (Join-Path $root 'tools\demo-files\Sintel_1080_10s_30MB.mp4'); extraArgs = @('--dither', '0.25'); tag = 'autod025' }
        '008.VID' = @{ shape = 'full';    src = (Join-Path $root 'tools\demo-files\Big_Buck_Bunny_1080_10s_30MB.mp4'); extraArgs = @(); tag = 'auto' }
        # 009's operating point RE-DERIVED at the Card #5 gapped prices
        # (composition factor 1.55 -> 1.15, silicon_r gapped 1.20 -> 1.01):
        # the higher decode-T cap made 0.68 unstreamable (gate: util 1.58),
        # and 0.54 lands at util 0.892 - the same ~0.90 target the 3b
        # operating points were chosen against, now +0.63 dB richer
        '009.VID' = @{ shape = '16:9';    src = (Join-Path $root 'tools\demo-files\Jellyfish_1080_10s_30MB.mp4'); extraArgs = @(); tag = 'auto' }
        # SP15 3c: 010 = the DIRECT-SERVE leg (VDIR/VDIRL) - all-literal
        # raw-equivalent encode, header hint set; the player serves it
        # SD-to-surface with no ring.
        # SP15 Card #5 TIGHTEN RULING (2026-07-26, owner-decided): the
        # recalibrated gate is UNCONDITIONAL - no accept-slow override
        # exists. classic-wide 256x144@25 stereo scored 1.075 (~6%
        # slow) and is refused outright by its own gate now, so 010 is
        # re-encoded at 256x133@25 stereo - the recalibrated gate's
        # largest at-rate classic surface (util 0.99, real content;
        # direct demand is content-independent - see 011 below).
        '010.VID' = @{ shape = '256x133'; src = (Join-Path $root 'tools\demo-files\Sintel_1080_10s_30MB.mp4'); extraArgs = @('--direct'); tag = 'direct' }
        # 011 = the DIRECT-MODE PACING CARD (DPACE/DPACL, Card #5): the
        # SAME test-card source and the SAME 5.000 s / 125 frames as
        # 006, encoded --direct at the shipped 010 shape (256x133@25
        # stereo, util 0.99) - so the 1 Hz beep makes the direct rate
        # OBJECTIVELY measurable by stopwatch exactly as VPACL does for
        # the delta paths: TRUE at-rate playback now (12 loop passes =
        # 60 s nominal should land at 60.0 s, not the ~63.6 s the
        # refused 1.075 shape would have produced). The 11-line crop
        # (144 -> 133) was checked via nxv2dec frame export: the pts
        # banner (row 0) and the seconds-digit box (right edge) are
        # both still fully inside the frame, not clipped.
        '011.VID' = @{ shape = '256x133'; src = (Join-Path $root 'tools\demo-files\1920x1080-25p.mp4'); extraArgs = @('--direct'); tag = 'directpace'; start = '00:00:00'; duration = '5.0' }
    }
    $vidLongStaged = 0
    foreach ($dest in $vidLongMap.Keys) {
        $shape = $vidLongMap[$dest].shape
        $src = $vidLongMap[$dest].src
        if (-not (Test-Path -LiteralPath $src)) {
            "WARNING: $src missing - sd\$legName\$dest not generated"
            continue
        }
        $shapeTag = $shape -replace ':', ''
        $tag = $vidLongMap[$dest].tag
        if ($tag) { $shapeTag = "${shapeTag}_${tag}" }
        # settlement tag in the name for the same reason as -Vid: an
        # encoder-internal change re-shapes output with identical args
        $cache = Join-Path $vidOutDir "$([IO.Path]::GetFileNameWithoutExtension($dest))_${shapeTag}_${vidLegSettlementTag}_long_cache.vid"
        # optional cut (011 only - the pacing card is an exact 5.000 s
        # slice of a 60 s source; everything else is a FULL-duration encode)
        $cut = @()
        if ($vidLongMap[$dest].start)    { $cut += @('--start', $vidLongMap[$dest].start) }
        if ($vidLongMap[$dest].duration) { $cut += @('--duration', $vidLongMap[$dest].duration) }
        if (-not (Test-Path -LiteralPath $cache)) {
            "encoding sd\$legName\$dest (shape $shape, source $(Split-Path -Leaf $src), $(if ($cut) { "cut $($vidLongMap[$dest].start) dur $($vidLongMap[$dest].duration)" } else { 'FULL duration' })) via videnc.py - slow, cached at tests\out\$(Split-Path -Leaf $cache) after this run..."
            & python "$root\authoring-kit\lib\videnc.py" $src $cache --shape $shape --fps 25 --ffmpeg "$root\tools\ffmpeg\bin\ffmpeg.exe" @($vidLongMap[$dest].extraArgs) @cut
            if ($LASTEXITCODE -ne 0) { throw "videnc.py failed (exit $LASTEXITCODE) - sd\$legName\$dest not staged" }
        }
        if (Test-Path -LiteralPath $cache) {
            Copy-Item -LiteralPath $cache -Destination "$leg\$dest" -Force
            $vidLongStaged++
        }
    }
    # 099.VID = a byte-copy of 007. (3c: the DEBUG deliberate-underrun
    # THROTTLE for video 99 is RETIRED - VSTRU is a plain streamed
    # regression leg now; the drill's verdict is on record in Cards
    # #3/#4 and git holds the lever.)
    if (Test-Path -LiteralPath "$leg\007.VID") {
        Copy-Item -LiteralPath "$leg\007.VID" -Destination "$leg\099.VID" -Force
        $vidLongStaged++
    }
    "staged $vidLongStaged long fixture(s) -> sd\$legName\007-011.VID + 099.VID (SP15 3b/3c streaming + direct leg set: VSTR0/VSTR1/VSTR2/VSTRU/VDIR/DPACE, sp14a-task-4-report.md sections 38/39)"
}

if ($NxBench) {
    # SP15 T2 decode-kernel bench payloads - see the -NxBench header
    # comment above. Same CSpect-lock hazard as the other staging
    # switches: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial bench fixture set)"
    }
    # NXB8's segment source is a dedicated classic encode built with
    # --no-merge (SP15): the gap-merge would collapse the dense small-op
    # stream that the dispatch bench row measures, so NXB8 must be cut from
    # a NON-merged encode to keep its worst-case op density (nxv2enc
    # bench-fixtures merge-bypass note). This is a SEPARATE cache from the
    # -Vid 002 production (merged) cache.
    $nxbCache = Join-Path $root 'tests\out\002_classic_nomerge_cache.vid'
    if (-not (Test-Path -LiteralPath $nxbCache)) {
        $nxbSrc = Join-Path $root 'tools\demo-files\1440x1080-25p.mp4'
        if (-not (Test-Path -LiteralPath $nxbSrc)) {
            throw "-NxBench: $nxbSrc missing and no cached classic encode exists - cannot build NXB8"
        }
        "encoding tests\out\002_classic_nomerge_cache.vid (shape classic, --no-merge) via videnc.py - slow, cached after this run..."
        & python "$root\authoring-kit\lib\videnc.py" $nxbSrc $nxbCache --shape classic --fps 25 --no-merge --ffmpeg "$root\tools\ffmpeg\bin\ffmpeg.exe"
        if ($LASTEXITCODE -ne 0) { throw "videnc.py failed (exit $LASTEXITCODE) - bench fixtures not staged" }
    }
    $nxbDir = Join-Path $root 'tests\out\nxbench'
    & python "$root\authoring-kit\lib\nxv2enc.py" --bench-fixtures $nxbDir --segment $nxbCache
    if ($LASTEXITCODE -ne 0) { throw "nxv2enc.py --bench-fixtures failed (exit $LASTEXITCODE)" }
    # No NXB*.BIN stale-clean: sd\NXBENCH\ was emptied at the top of the
    # staging section.
    $nxbStaged = 0
    Get-ChildItem "$nxbDir\NXB*.BIN" | ForEach-Object {
        Copy-Item $_.FullName "$leg\$($_.Name)" -Force
        $nxbStaged++
    }
    "staged $nxbStaged bench payload(s) -> sd\$legName\NXB0.BIN..NXB9.BIN (manifest: tests\out\nxbench\nxbench-manifest.txt)"
}

if ($Nxv2Test) {
    # SP15 T1 encoder/decoder selftest - plain python, no pytest dep.
    # Independent of sd\/the DAAD toolchain; slow (steps 4-7 run real
    # ffmpeg encodes against tools\demo-files\ - see tests\
    # nxv2_selftest.py's own header comment).
    & python "$root\tests\nxv2_selftest.py"
    if ($LASTEXITCODE -ne 0) { throw "nxv2_selftest.py failed (exit $LASTEXITCODE)" }
}

if ($Aud) {
    # Same CSpect lock hazard as the art staging: a running emulator
    # holds sd\ files open and the copies fail piecemeal.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial audio sets)"
    }
    # No per-kind stale-audio cleanup: the leg folder was emptied at the
    # top of the staging section, so a song the current asset set no
    # longer provides cannot leak in from an earlier run.
    $audSrc = "$root\tools\audio_assets"
    $audFiles = @()
    if (Test-Path $audSrc) {
        $audFiles = @(Get-ChildItem "$audSrc\*.AKY", "$audSrc\GAME.SFB", "$audSrc\*.WAV", "$audSrc\*.AYS" -ErrorAction SilentlyContinue)
    }
    if ($audFiles.Count -eq 0) {
        "WARNING: -Aud given but $audSrc has no assets (run the audio export script first) - skipped"
    }
    else {
        $audFiles | ForEach-Object { Copy-Item $_.FullName "$leg\$($_.Name)" -Force }
        "staged $($audFiles.Count) audio asset(s) -> sd\$legName\ ($(($audFiles | ForEach-Object Name) -join ', '))"
    }
}

$audLadActive = $false
if ($AudLad) {
    # SP16 Task 7 owner leg fixture. Two jobs, both owned entirely by
    # this switch: make tests\audlad.dsf the active DDB, and stage the
    # five ladder songs tests\audio\mkladder.py generates.
    #
    # GAME.AKY is a COPY OF 001.AKY, not a sixth song. That identity
    # is the whole design of the #T7B STOPM leg: boot autoplay and the
    # LAD1 verb then play the same bytes, so a pitch difference between
    # them cannot be a difference in the material. Do not "tidy" this
    # into a distinct GAME.AKY.
    #
    # Same CSpect lock hazard as -Aud/-Rab/-GMode: a running emulator
    # holds sd\ files open and the copies fail piecemeal, leaving a
    # partial ladder whose missing rungs read as silent no-ops.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial ladder)"
    }
    Copy-Item "$root\tests\out\audlad.ddb" "$leg\GAME.DDB" -Force
    # sd\AUDLAD\ holds this ladder and nothing else - -Aud's own song set
    # under the same names, or a sample/stream the ladder never mentions,
    # is in a different folder entirely. The old cross-kind stale-clean
    # was the shared root's problem, not this switch's.
    $ladSrc = "$root\tests\audio"
    $ladMap = [ordered]@{ 'L1.AKY' = '001.AKY'; 'L3.AKY' = '002.AKY'; 'L6.AKY' = '003.AKY';
                          'L9.AKY' = '004.AKY'; 'L9Q.AKY' = '005.AKY' }
    $ladStaged = 0
    foreach ($src in $ladMap.Keys) {
        $p = Join-Path $ladSrc $src
        if (Test-Path $p) {
            Copy-Item $p "$leg\$($ladMap[$src])" -Force
            $ladStaged++
        }
        else {
            "WARNING: $p absent - rung $($ladMap[$src]) will be a silent no-op (run python tests\audio\mkladder.py)"
        }
    }
    # Rung R - the REAL material. The kit's own 9-channel tune, which is
    # what both parked SP14b sightings were actually heard on: the kit
    # builds RELEASE\GAME.AKY and RELEASE\001.AKY from the same source
    # (AUDIO\1.aks == AUDIO\STARTER.aks, lib\audio.bat), so they are
    # byte-identical, and boot autoplay + MUSIC 1 played the same bytes
    # at the 2026-07-23 STOPM sighting.
    #
    # Converted here from the TRACKED source rather than copied from the
    # kit's RELEASE\ (which is gitignored build output and may be absent
    # or stale): SongToAky with the kit's own flags reproduces
    # RELEASE\GAME.AKY byte for byte (verified, sha256 89ac228e8a7e3147,
    # 7487 bytes). authoring-kit\ is READ-ONLY here - the conversion
    # writes to tests\out\, never back into the kit.
    $realSrc = "$root\authoring-kit\AUDIO\1.aks"
    $realOut = "$root\tests\out\real9.aky"
    $s2a = "$root\tools\ArkosTracker3\tools\SongToAky.exe"
    $realOk = $false
    if ((Test-Path $realSrc) -and (Test-Path $s2a)) {
        & $s2a -bin --encodingAddress 0xD800 $realSrc $realOut | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $realOut)) { $realOk = $true }
        else { "WARNING: SongToAky failed on $realSrc - rung R unavailable" }
    }
    if (-not $realOk -and (Test-Path "$root\authoring-kit\RELEASE\GAME.AKY")) {
        # Fallback: the kit's own build output, if a build has been run.
        Copy-Item "$root\authoring-kit\RELEASE\GAME.AKY" $realOut -Force
        $realOk = $true
        "rung R: SongToAky unavailable - used authoring-kit\RELEASE\GAME.AKY instead"
    }
    if ($realOk) {
        Copy-Item $realOut "$leg\006.AKY" -Force
        $ladStaged++
    }
    else {
        "WARNING: no rung R material (need authoring-kit\AUDIO\1.aks + SongToAky, or a kit build) - LADR and the #T7B STOPM leg will be silent no-ops"
    }
    # GAME.AKY is a copy of 006.AKY, NOT of a synthetic rung: boot
    # autoplay and LADR must play the same bytes, on the real material,
    # because that is the configuration the STOPM symptom was heard in.
    if (Test-Path "$leg\006.AKY") {
        Copy-Item "$leg\006.AKY" "$leg\GAME.AKY" -Force
        "staged $ladStaged ladder song(s) -> sd\$legName\001..006.AKY, GAME.AKY = 006.AKY (real material, STOPM control)"
    }
    else {
        "WARNING: no sd\$legName\006.AKY - boot autoplay and the #T7B STOPM leg have nothing to play"
    }
    foreach ($f in @('001.AKY', '002.AKY', '003.AKY', '004.AKY', '005.AKY', '006.AKY', 'GAME.AKY')) {
        $p = "$leg\$f"
        if (Test-Path $p) { "  sd\$legName\$f $((Get-Item $p).Length) bytes (song slot 10208)" }
    }
    $audLadActive = $true
}

$sfxDiActive = $false
if ($SfxDi) {
    # Sampled-SFX DMA pre-emption leg (rev 2). Three jobs, all owned
    # entirely by this switch: make tests\sfxdi.dsf the active DDB,
    # stage the two steady tones tests\audio\mktone.py generates, and
    # stage the Layer 2 corruption-detector card tests\art\mkl2card.py
    # generates as 001.NXI.
    #
    # THE CARD IS NOT OPTIONAL AND MUST BE .NXI. gfx_blit routes
    # 256-wide art to gfx_row_copy256 -> dma_copy (one DMA call per
    # row) and 320-wide art to gfx_row_scatter320, a CPU column scatter
    # with no DMA branch at all. gfxExtTab is what decides which: NX2
    # rows are mode 1 / width 320, NXI rows mode 0 / width 256, and the
    # NX2 variants probe FIRST. A leftover 001.NX2 from an earlier
    # -Rab/-GMode stage winning the chain, drawing through the scatter
    # path and leaving the fixture exercising nothing IS WHAT HAPPENED
    # (2026-08-03, the vacuous run that motivated the leg folders).
    # sd\SFXDI\ is emptied at the top of the staging section and holds
    # this fixture's four files and nothing else, so no other art of
    # number 001 exists for the probe chain to find.
    #
    # NO SONG IS STAGED, DELIBERATELY. The AKY player masks the CTC feed
    # ~5500 T every frame while a song plays - a CONTINUOUS ~0.67% rate
    # error at 16 kHz that would sit under the reference phases as well
    # as the burst and blunt the very comparison this leg exists to
    # make. Do not "helpfully" add a GAME.AKY here.
    #
    # Same CSpect lock hazard as -Aud/-AudLad: a running emulator holds
    # sd\ files open and the copies fail piecemeal, leaving a fixture
    # whose missing WAV reads as a silent no-op rather than as an error.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial ear fixture)"
    }
    Copy-Item "$root\tests\out\sfxdi.ddb" "$leg\GAME.DDB" -Force
    # No cross-kind audio stale-clean: -Aud/-AudLad material under the
    # right name (001.WAV especially) and a stray autoplaying .AKY are
    # both in other folders now. Nothing this fixture does not stage is
    # in sd\SFXDI\.
    # Generated, not committed: 96 KB of pure sine that is a byte-exact
    # function of four constants. Same rule badwav/truncwav follow above.
    & python "$PSScriptRoot\audio\mktone.py" "$root\tests\out"
    if ($LASTEXITCODE -ne 0) { throw "tests\audio\mktone.py failed" }
    $toneMap = [ordered]@{ 'tone440_16k.wav' = '001.WAV'; 'tone440_20k.wav' = '002.WAV' }
    foreach ($src in $toneMap.Keys) {
        $p = "$root\tests\out\$src"
        if (-not (Test-Path $p)) { throw "mktone.py produced no $src" }
        # aud_load_wav takes the rate verbatim from the fmt chunk and
        # nothing in the pipeline resamples, so the staged header rate IS
        # the played rate - re-read it here rather than trusting the name.
        $wb = [System.IO.File]::ReadAllBytes($p)
        $wrate = [System.BitConverter]::ToUInt32($wb, 24)
        $wbits = [System.BitConverter]::ToUInt16($wb, 34)
        $wch = [System.BitConverter]::ToUInt16($wb, 22)
        if ($wch -ne 1 -or $wbits -ne 8) { throw "$src is not mono 8-bit (ch=$wch bits=$wbits) - aud_load_wav would reject it" }
        Copy-Item $p "$leg\$($toneMap[$src])" -Force
        "staged tests\out\$src -> sd\$legName\$($toneMap[$src])  $($wb.Length) bytes, $wrate Hz mono 8-bit"
    }
    # The Layer 2 card. Generated, not committed - a byte-exact function
    # of the constants in tests\art\mkl2card.py, same rule the tones and
    # the badwav/truncwav variants follow.
    & python "$PSScriptRoot\art\mkl2card.py" "$root\tests\out"
    if ($LASTEXITCODE -ne 0) { throw "tests\art\mkl2card.py failed" }
    $cardSrc = "$root\tests\out\l2card.nxi"
    if (-not (Test-Path $cardSrc)) { throw "mkl2card.py produced no l2card.nxi" }
    # gfx_derive_height reads the row count out of the FILE LENGTH -
    # (bytes - 512) / 256 - and rejects a partial trailing row or more
    # than 192 rows in 256-wide mode, so the size is the one thing that
    # has to be right for the card to load at all.
    $cardBytes = (Get-Item $cardSrc).Length
    if ((($cardBytes - 512) % 256) -ne 0) { throw "l2card.nxi is $cardBytes bytes - not 512 + a whole number of 256-byte rows" }
    $cardRows = ($cardBytes - 512) / 256
    if ($cardRows -lt 1 -or $cardRows -gt 192) { throw "l2card.nxi derives $cardRows rows - gfx_derive_height rejects anything outside 1..192 in 256-wide mode" }
    # No pixel may be index 255 (L2_TRANSP_INDEX, src\nextdaad.inc):
    # l2_palette_load's closing l2_pal9_stamp reserves it as the sole
    # transparent entry, so a card that used it would show holes on a
    # PERFECT copy and the red backdrop under it would read as damage.
    # mkl2card.py asserts the same thing from the generator side (it uses
    # indices 0..15); this is the independent half, from the staging side.
    $cardData = [System.IO.File]::ReadAllBytes($cardSrc)
    $bad255 = 0
    for ($i = 512; $i -lt $cardData.Length; $i++) { if ($cardData[$i] -eq 255) { $bad255++ } }
    if ($bad255 -ne 0) { throw "l2card.nxi uses palette index 255 in $bad255 pixel(s) - that index is reserved transparent, the card would show false holes" }
    Copy-Item $cardSrc "$leg\001.NXI" -Force
    "staged tests\out\l2card.nxi -> sd\$legName\001.NXI  $cardBytes bytes, 256x$cardRows, no pixel uses index 255"
    $sfxDiActive = $true
}

$sfxLongActive = $false
if ($SfxLong) {
    # SD-streamed sampled-effect wire fixture (SP18 item 7 Task 7).
    # Owned entirely by this switch: make tests\sfxlong.dsf the active
    # DDB, and generate + stage the three stimulus WAVs, the PIC verb's
    # picture and (opportunistically) the VID verb's clip - the last
    # three assets added by Task 14b.
    #
    # Same CSpect lock hazard as every other staging switch: refuse to
    # stage rather than leave a partial leg folder whose missing WAV
    # reads as a silent no-op.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial fixture)"
    }
    Copy-Item "$root\tests\out\sfxlong.ddb" "$leg\GAME.DDB" -Force

    # Effect 1: 001.WAV, THE STREAMER. 200000 bytes of payload is
    # comfortably over SFX_WIN_BYTES (24576, src\nextdaad.inc) so
    # sfx_stream_open takes the STREAMING arm. 330 Hz over 200000 bytes
    # at 16000 Hz is 4125.0 whole cycles - New-SfxLongWav throws if that
    # is not exact, so a size/rate typo here is caught immediately
    # rather than shipping a clicking loop seam.
    $streamWav = New-SfxLongWav -Rate 16000 -ToneHz 330.0 -PayloadBytes 200000
    $streamPath = "$root\tests\out\sfxlong_stream.wav"
    [System.IO.File]::WriteAllBytes($streamPath, $streamWav)

    # Effect 2: 002.WAV, THE COMPLETE FILE. 16000 bytes of payload is
    # comfortably under SFX_WIN_BYTES so sfx_stream_open takes the
    # free-hybrid COMPLETE arm - no streaming, no refiller involvement.
    # 660 Hz (an octave above effect 1's tone, deliberately - the two
    # effects are audibly distinguishable on real hardware) over 16000
    # bytes at 16000 Hz is 660.0 whole cycles.
    $completeWav = New-SfxLongWav -Rate 16000 -ToneHz 660.0 -PayloadBytes 16000
    $completePath = "$root\tests\out\sfxlong_complete.wav"
    [System.IO.File]::WriteAllBytes($completePath, $completeWav)

    # Effect 3: 003.WAV, THE SECOND STREAMER (Task 14b). 100000 bytes of
    # payload is also over SFX_WIN_BYTES, taking the STREAMING arm - a
    # second, DISTINCT >24K number from effect 1, so a fresh full open
    # of this number can be contrasted against a cached rewind of effect
    # 1 without one disturbing the other's channel state. 440 Hz over
    # 100000 bytes at 16000 Hz is 2750.0 whole cycles.
    $stream2Wav = New-SfxLongWav -Rate 16000 -ToneHz 440.0 -PayloadBytes 100000
    $stream2Path = "$root\tests\out\sfxlong_stream2.wav"
    [System.IO.File]::WriteAllBytes($stream2Path, $stream2Wav)

    # aud_load_wav takes the rate/channels/bits verbatim from the fmt
    # chunk and rejects anything but mono 8-bit - re-read the generated
    # header rather than trusting the generator arguments, same rule
    # the -SfxDi tone staging follows.
    $wavMap = [ordered]@{ $streamPath = '001.WAV'; $completePath = '002.WAV'; $stream2Path = '003.WAV' }
    foreach ($src in $wavMap.Keys) {
        $wb = [System.IO.File]::ReadAllBytes($src)
        $wrate = [System.BitConverter]::ToUInt32($wb, 24)
        $wbits = [System.BitConverter]::ToUInt16($wb, 34)
        $wch = [System.BitConverter]::ToUInt16($wb, 22)
        if ($wch -ne 1 -or $wbits -ne 8) { throw "$src is not mono 8-bit (ch=$wch bits=$wbits) - aud_load_wav would reject it" }
        $dest = $wavMap[$src]
        # F_FSTAT reports the WHOLE FILE size (header included), and
        # that is exactly what sfx_stream_open compares against
        # SFX_WIN_BYTES (src\audio\streamfx.asm .lenok) - no header
        # adjustment on either side.
        $winBytes = 24576
        $arm = if ($wb.Length -gt $winBytes) { 'STREAMING' } else { 'COMPLETE' }
        Copy-Item $src "$leg\$dest" -Force
        "staged $src -> sd\$legName\$dest  $($wb.Length) bytes, $wrate Hz mono 8-bit, $arm arm"
    }

    # 001.NXI: the PIC verb's picture (Task 14b). Reuses
    # tests\art\mkl2card.py's generated Layer 2 corruption-detector card
    # byte-for-byte - the same deterministic file -SfxDi stages as its
    # own 001.NXI - rather than inventing a second generator; that
    # script's own header already documents the card as reusable by any
    # fixture that just needs "the ONE picture PICTURE 1 loads and
    # DISPLAY 0 blits". 256-wide (.NXI) and 128 rows, the smaller of the
    # two cards tests\art\ ships (tests\art\mkl2holes.py's card is
    # pinned to a full-screen 192 rows).
    & python "$PSScriptRoot\art\mkl2card.py" "$root\tests\out"
    if ($LASTEXITCODE -ne 0) { throw "tests\art\mkl2card.py failed" }
    $picSrc = "$root\tests\out\l2card.nxi"
    if (-not (Test-Path $picSrc)) { throw "mkl2card.py produced no l2card.nxi" }
    # gfx_derive_height reads the row count out of the FILE LENGTH -
    # (bytes - 512) / 256 - and rejects a partial trailing row or more
    # than 192 rows in 256-wide mode, so the size is the one thing that
    # has to be right for the card to load at all.
    $picBytes = (Get-Item $picSrc).Length
    if ((($picBytes - 512) % 256) -ne 0) { throw "l2card.nxi is $picBytes bytes - not 512 + a whole number of 256-byte rows" }
    $picRows = ($picBytes - 512) / 256
    if ($picRows -lt 1 -or $picRows -gt 192) { throw "l2card.nxi derives $picRows rows - gfx_derive_height rejects anything outside 1..192 in 256-wide mode" }
    Copy-Item $picSrc "$leg\001.NXI" -Force
    "staged tests\out\l2card.nxi -> sd\$legName\001.NXI  $picBytes bytes, 256x$picRows (PIC verb picture)"

    # 001.VID: the VID verb's clip (Task 14b). This task does not run
    # the video encoder (tools\ is read-only, and encoding is slow and
    # owner-gated) - it reuses whichever short leg-cache encode a prior
    # -Vid run already left in tests\out\, picking the smallest. Any
    # valid encode works regardless of the shape/number it was
    # originally cached under: the player reads geometry from the
    # file's own NXV v2 header, not from the SD file number that names
    # it (see the -VidLong staging block's own header-verification
    # comment above). Excludes -VidLong's *_long_cache.vid family
    # (multi-MB streaming clips - the wrong order of magnitude for this
    # verb). Sorted by Length then Name so the choice is deterministic
    # (does not depend on filesystem enumeration order) even when two
    # cached files tie on size.
    $vidSrc = Get-ChildItem "$root\tests\out\*_leg_cache.vid" -ErrorAction SilentlyContinue | Sort-Object Length, Name | Select-Object -First 1
    if ($vidSrc) {
        Copy-Item $vidSrc.FullName "$leg\001.VID" -Force
        "staged tests\out\$($vidSrc.Name) -> sd\$legName\001.VID  $($vidSrc.Length) bytes (smallest cached -Vid leg encode; VID verb)"
    }
    else {
        "WARNING: no tests\out\*_leg_cache.vid found - sd\$legName\001.VID NOT staged. Run 'tests\build-tests.ps1 -Vid' once to populate the cache (encodes and caches 001-006.VID), then re-run -SfxLong to pick it up. The VID verb (SFX 1 9) reports a clean miss with nothing staged, rather than failing."
    }

    $sfxLongActive = $true
}

$sfx2Active = $false
if ($Sfx2) {
    # Two-channel sampled-effect API fixture (SP18 item 7 Task 12). Two
    # jobs, both owned entirely by this switch: make tests\sfx2.dsf the
    # active DDB, and generate + stage the three stimulus WAVs.
    #
    # Same CSpect lock hazard as every other staging switch: refuse to
    # stage rather than leave a partial leg folder whose missing WAV
    # reads as a silent no-op.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial fixture)"
    }
    Copy-Item "$root\tests\out\sfx2.ddb" "$leg\GAME.DDB" -Force

    # Effects 1 and 2 are BOTH under SFX_WIN_BYTES (24576,
    # src\nextdaad.inc) on purpose: that is the COMPLETE arm, which is
    # the only sampled path CSpect can run end to end, so the two
    # channels really do play together there. An octave apart so a
    # listener can tell which channel survived a steal. Effect 3 is over
    # the threshold and takes the STREAMING arm - it exists to be a
    # number NEITHER channel caches, which is what forces the allocator
    # past its two cheap cases into the steal/drop decision.
    # New-SfxLongWav throws unless the tone divides the payload into
    # whole cycles, so a size/rate typo here is caught immediately
    # rather than shipping a clicking loop seam.
    $sfx2Specs = @(
        @{ dest = '001.WAV'; hz = 440.0; len = 16000; path = "$root\tests\out\sfx2_e1.wav" },
        @{ dest = '002.WAV'; hz = 880.0; len = 12000; path = "$root\tests\out\sfx2_e2.wav" },
        @{ dest = '003.WAV'; hz = 220.0; len = 40000; path = "$root\tests\out\sfx2_e3.wav" }
    )
    foreach ($spec in $sfx2Specs) {
        $w = New-SfxLongWav -Rate 16000 -ToneHz $spec.hz -PayloadBytes $spec.len
        [System.IO.File]::WriteAllBytes($spec.path, $w)
    }
    # aud_load_wav takes the rate/channels/bits verbatim from the fmt
    # chunk and rejects anything but mono 8-bit - re-read each generated
    # header rather than trusting the generator arguments, the same rule
    # the -SfxDi and -SfxLong tone staging follow.
    foreach ($spec in $sfx2Specs) {
        $wb = [System.IO.File]::ReadAllBytes($spec.path)
        $wrate = [System.BitConverter]::ToUInt32($wb, 24)
        $wbits = [System.BitConverter]::ToUInt16($wb, 34)
        $wch = [System.BitConverter]::ToUInt16($wb, 22)
        if ($wch -ne 1 -or $wbits -ne 8) { throw "$($spec.path) is not mono 8-bit (ch=$wch bits=$wbits) - aud_load_wav would reject it" }
        # F_FSTAT reports the WHOLE FILE size (header included), and that
        # is exactly what sfx_stream_open compares against SFX_WIN_BYTES
        # (src\audio\streamfx.asm .lenok) - no header adjustment on
        # either side.
        $winBytes = 24576
        $arm = if ($wb.Length -gt $winBytes) { 'STREAMING' } else { 'COMPLETE' }
        Copy-Item $spec.path "$leg\$($spec.dest)" -Force
        "staged $($spec.path) -> sd\$legName\$($spec.dest)  $($wb.Length) bytes, $wrate Hz mono 8-bit, $($spec.hz) Hz, $arm arm"
    }
    # The two short effects MUST both take the COMPLETE arm or the leg
    # stops proving concurrent playback under CSpect, and effect 3 MUST
    # take the STREAMING arm or the steal case stops being a steal.
    $e1 = (Get-Item "$leg\001.WAV").Length
    $e2 = (Get-Item "$leg\002.WAV").Length
    $e3 = (Get-Item "$leg\003.WAV").Length
    if ($e1 -gt 24576 -or $e2 -gt 24576) {
        throw "sfx2: 001.WAV ($e1) and 002.WAV ($e2) must both be <= SFX_WIN_BYTES (24576) so both channels play COMPLETE"
    }
    if ($e3 -le 24576) {
        throw "sfx2: 003.WAV ($e3) must exceed SFX_WIN_BYTES (24576) - it is the uncached third effect the steal case needs"
    }
    $sfx2Active = $true
}

$l2holesActive = $false
if ($L2Holes) {
    # Layer 2 TRANSPARENCY / punch-out leg. Two jobs, both owned entirely
    # by this switch: make tests\l2holes.dsf the active DDB, and stage the
    # punch-out card tests\art\mkl2holes.py generates as 001.NXI.
    #
    # THE CARD IS NOT OPTIONAL AND MUST BE .NXI. gfxExtTab routes NXI rows
    # to mode 0 / width 256 and NX2 rows to mode 1 / width 320, and the
    # NX2 variants probe FIRST. A 320-wide surface would cover the control
    # margin this fixture reads its verdict from, so a leftover 001.NX2
    # winning the chain would not merely change the path (the -SfxDi
    # hazard) - it would move the picture out from under the ruler.
    # sd\L2HOLES\ is emptied at the top of the staging section and holds
    # this fixture's three files and nothing else, so no other art of
    # number 001 exists for the probe chain to find.
    #
    # Same CSpect lock hazard as -Aud/-AudLad/-SfxDi, and the same
    # refusal: a running emulator holds sd\ files open, the copies fail
    # one at a time, and a missing 001.NXI makes PICTURE fail - the
    # fixture would then be reporting on staging rather than on Layer 2.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files leave a partial leg folder)"
    }
    Copy-Item "$root\tests\out\l2holes.ddb" "$leg\GAME.DDB" -Force
    # Generated, not committed - a byte-exact function of the constants in
    # tests\art\mkl2holes.py, the same rule the tones and the -SfxDi card
    # follow. That script asserts its own invariants and decodes the file
    # back; the checks here are the independent half, from the staging
    # side, in the terms the interpreter will read it.
    & python "$PSScriptRoot\art\mkl2holes.py" "$root\tests\out"
    if ($LASTEXITCODE -ne 0) { throw "tests\art\mkl2holes.py failed" }
    $holeSrc = "$root\tests\out\l2holes.nxi"
    if (-not (Test-Path $holeSrc)) { throw "mkl2holes.py produced no l2holes.nxi" }
    $hole = [System.IO.File]::ReadAllBytes($holeSrc)
    # gfx_derive_height (src\overlay2.asm) takes the row count from the
    # FILE LENGTH alone - (bytes - 512) / 256 - and rejects anything
    # outside 1..192 in 256-wide mode, so the size is the one thing that
    # must be right for the card to load at all. Pinned to 192 here, not
    # merely bounded: this card must be full-screen or the holes near the
    # bottom edge would have no Layer 2 to punch through.
    if ((($hole.Length - 512) % 256) -ne 0) { throw "l2holes.nxi is $($hole.Length) bytes - not 512 + a whole number of 256-byte rows" }
    $holeRows = ($hole.Length - 512) / 256
    if ($holeRows -ne 192) { throw "l2holes.nxi derives $holeRows rows - this card must be the full-screen 192 (gfx_derive_height's mode 0 ceiling)" }
    # Exactly one non-255 palette entry may pack to $E3, and that entry IS
    # the collision-dodge test (l2_palette_load nudges any entry whose
    # byte0 equals L2_TRANSP_COLOUR to $E7): two would make a hole
    # ambiguous, none would make the E3 block a plain magenta rectangle
    # testing nothing.
    $e3 = @()
    for ($i = 0; $i -lt 256; $i++) { if ($hole[2 * $i] -eq 0xE3) { $e3 += $i } }
    if ($e3.Count -ne 1 -or $e3[0] -ne 14) {
        throw "l2holes.nxi: palette entries packing to `$E3 are ($($e3 -join ',')), expected exactly index 14 - the dodge test is not armed"
    }
    if ($hole[510] -eq 0xE3) {
        throw "l2holes.nxi: palette entry 255 packs to `$E3 - it must carry the bright-green stamp-failure signature instead (see the card's header)"
    }
    # Index 255 (L2_TRANSP_INDEX) must be PRESENT. This card is the exact
    # inverse of -SfxDi's l2card.nxi, which must contain none: there, an
    # index-255 pixel would be a false hole; here, no index-255 pixel at
    # all means nothing to see through and the fixture tests nothing.
    $holePixels = 0
    $maxIdx = 0
    for ($i = 512; $i -lt $hole.Length; $i++) {
        $v = $hole[$i]
        if ($v -eq 255) { $holePixels++ }
        elseif ($v -gt $maxIdx) { $maxIdx = $v }
    }
    if ($holePixels -lt 1) { throw "l2holes.nxi has no index-255 pixel - it would punch no holes and test nothing" }
    if ($maxIdx -gt 15) { throw "l2holes.nxi uses palette index $maxIdx, which has no colour" }
    Copy-Item $holeSrc "$leg\001.NXI" -Force
    "staged tests\out\l2holes.nxi -> sd\$legName\001.NXI  $($hole.Length) bytes, 256x$holeRows, $holePixels transparent pixel(s), index 14 = the `$E3 dodge entry, entry 255 = `$$('{0:X2}' -f $hole[510]) (green, must never be seen)"
    $l2holesActive = $true
}

$tileSlackActive = $false
if ($TileSlack) {
    # --tile-slack A/B leg. Two jobs, both owned entirely by this switch:
    # make tests\tileslack.dsf the active DDB, and stage the four encodes
    # tests\video\tileslack_ab.py produces as 001-004.VID.
    #
    # THE ENCODES ARE NOT MADE HERE. That script owns the experiment -
    # it derives the stream budget on arm A, pins it on arm B, runs the
    # four encodes, and measures the manual's benchmark table off them.
    # Staging copies ITS OUTPUT, so the picture the owner judges is the
    # same bytes the table was measured from, not a second encode that
    # merely used the same arguments. It caches on the encoder hashes and
    # the source hash, so a re-stage after a completed measurement costs
    # file copies rather than four encodes.
    #
    # Same CSpect lock hazard as -Vid/-VidLong/-L2Holes, and the same
    # refusal rather than a warning: a running emulator holds sd\ files
    # open, the copies fail one at a time, and a leg missing one arm of a
    # pair is an A/B with nothing to compare against - which is exactly
    # the failure that cannot be noticed on the glass.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files leave a partial A/B - one arm of a pair missing is not detectable on screen)"
    }
    Copy-Item "$root\tests\out\tileslack.ddb" "$leg\GAME.DDB" -Force
    "running tests\video\tileslack_ab.py (four encodes, cached in tests\out\tileslack\ - slow the first time)..."
    & python "$root\tests\video\tileslack_ab.py"
    if ($LASTEXITCODE -ne 0) { throw "tests\video\tileslack_ab.py failed (exit $LASTEXITCODE) - sd\$legName\ not staged" }
    # dest -> the measurement script's own cache name (clip + slack)
    $tsMap = [ordered]@{
        '001.VID' = 'bunny_s000.vid'
        '002.VID' = 'bunny_s050.vid'
        '003.VID' = 'jellyfish_s000.vid'
        '004.VID' = 'jellyfish_s050.vid'
    }
    $tsWork = Join-Path $root 'tests\out\tileslack'
    $tsInfo = @()
    foreach ($dest in $tsMap.Keys) {
        $src = Join-Path $tsWork $tsMap[$dest]
        if (-not (Test-Path -LiteralPath $src)) {
            throw "tileslack: $($tsMap[$dest]) was not produced - an arm is missing and the pair cannot be judged (check the script's own output above; a supply-gate refusal is reported there, not here)"
        }
        # Independent header verification, from the staging side, in the
        # terms the PLAYER will read the file (nxv2enc.pack_header): magic
        # "NXVID", version 2, width code 1 = 320 (mode-1) and the height
        # sentinel 0 = 256 lines, FLAG_DELTA_STREAM set, stereo. A pair
        # whose two arms were encoded at different SHAPES would not be an
        # A/B at all, and nothing on screen would say so.
        $srcLen = (Get-Item $src).Length
        if ($srcLen -le 512) { throw "tileslack: $($tsMap[$dest]) is $srcLen bytes - header only or empty, the encode did not complete" }
        $h = [byte[]]::new(24)
        $fs = [System.IO.File]::OpenRead($src)
        try { [void]$fs.Read($h, 0, 24) } finally { $fs.Close() }
        if ([System.Text.Encoding]::ASCII.GetString($h, 0, 5) -ne 'NXVID') { throw "tileslack: $($tsMap[$dest]) has no NXVID magic" }
        if ($h[5] -ne 2) { throw "tileslack: $($tsMap[$dest]) is NXV version $($h[5]), expected 2" }
        if ($h[6] -ne 1) { throw "tileslack: $($tsMap[$dest]) width code is $($h[6]), expected 1 (320 wide, mode-1) - the manual's table is measured on 320x256" }
        if ($h[7] -ne 0) { throw "tileslack: $($tsMap[$dest]) height byte is $($h[7]), expected the 256-line sentinel 0" }
        if (($h[12] -band 1) -ne 1) { throw "tileslack: $($tsMap[$dest]) does not carry FLAG_DELTA_STREAM - the tile schedule this test is about only exists on the delta path" }
        if ($h[9] -ne 2) { throw "tileslack: $($tsMap[$dest]) declares $($h[9]) audio channels, expected 2" }
        $frames = $h[14] + 256 * $h[15] + 65536 * $h[16]
        Copy-Item -LiteralPath $src -Destination "$leg\$dest" -Force
        $tsInfo += , @{ dest = $dest; frames = $frames; bytes = $srcLen
                        hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash }
    }
    # THE TWO ARMS OF A PAIR MUST DIFFER, and must be the same clip. If a
    # pair's arms came out byte-identical the knob did nothing on that
    # content and there is NOTHING to see - the owner would stare at two
    # identical files and report "no difference", which would read as a
    # verdict on the picture instead of a fact about the encode. Said here,
    # loudly, rather than discovered on the glass.
    foreach ($p in @(@{ n = 'PAIR 1 bunny'; a = 0; b = 1 }, @{ n = 'PAIR 2 jellyfish'; a = 2; b = 3 })) {
        $x = $tsInfo[$p.a]; $y = $tsInfo[$p.b]
        if ($x.frames -ne $y.frames) {
            throw "tileslack: $($p.n) arms have $($x.frames) and $($y.frames) frames - they are not the same cut and cannot be compared"
        }
        if ($x.hash -eq $y.hash) {
            throw "tileslack: $($p.n) arms are BYTE-IDENTICAL - --tile-slack changed nothing on this content, so there is no A/B to run (that is a finding about the encoder, not a staging fault: report it and do not judge the picture)"
        }
        $d = 100.0 * ($y.bytes - $x.bytes) / $x.bytes
        "$($p.n): $($x.dest) $($x.bytes) B vs $($y.dest) $($y.bytes) B ($('{0:+0.00;-0.00;0.00}' -f $d)%), $($x.frames) frames each, arms differ"
    }
    "staged 4 tile-slack fixture(s) -> sd\$legName\001-004.VID (two A/B pairs: 001/002 the BUNNY clip, 003/004 the JELLYFISH clip - the authoring kit's own demo footage, 320x256 @25 mode-1; odd = --tile-slack 0.0, even = 0.5)"
    $tileSlackActive = $true
}

# Uto's compliance test. Nothing to stage but the DDB - deliberately:
# the fixture loads no picture, plays no sound, reads no 0.XMB and takes
# no typed input, so sd\UTO\ / sd\UTOV3\ hold exactly GAME.DDB and the
# .nex. Anything else in there would be residue.
#
# The DDB is a derivative of a GPL-3.0 source and sd\ is gitignored -
# it goes to the owner's card and nowhere else. Never commit it, and
# never publish sd\UTO\ / sd\UTOV3\ as a release artefact.
$utoActive = $false
$utoV3Active = $false
if ($Uto -or $UtoV3) {
    # Unreachable with the source absent - the compile section throws
    # first - but the guard keeps the staging half honest on its own.
    if (-not $utoBuilt) { throw "-Uto/-UtoV3: no utotest DDB was built (see the tools\TEST.DSF message above)" }
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files leave a partial leg folder)"
    }
    # -UtoV3 last-wins, matching the $legName order resolved at the top.
    if ($UtoV3) {
        Copy-Item "$root\tests\out\utotest_v3.ddb" "$leg\GAME.DDB" -Force
        $utoV3Active = $true
    }
    else {
        Copy-Item "$root\tests\out\utotest.ddb" "$leg\GAME.DDB" -Force
        $utoActive = $true
    }
}

$fontSwActive = $false
if ($FontSw) {
    # SP18 Task 5 owner leg fixture: tests\fontsw.dsf drives GFX n 16
    # (font switching) and MOUSE n 5 (pointer switching) end to end.
    # Unlike -Font (a modifier - see the header comment above - that only
    # ever decorates whichever leg is already active and never sets the
    # active GAME.DDB), this stimulus has to BE the game, so it gets its
    # own leg and its own folder, exactly as -GMode's does for
    # gmodegate.dsf.
    # Same CSpect lock hazard as every other staging switch: refuse to
    # stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial fixture)"
    }
    Copy-Item "$root\tests\out\fontsw.ddb" "$leg\GAME.DDB" -Force

    # FONT.CHR: reuse -Font's own source (the Crews .ch8) when the demo
    # archive happens to be extracted; fall back to a plain copy of
    # authoring-kit\lib\default.chr otherwise, so this leg never fails on
    # an unextracted third-party archive. Either way GFX 0 16's revert-
    # to-base step (tests\fontsw.dsf MESSAGE 1) has a file to find - the
    # fallback is just not visually distinct from the embedded table
    # (default.chr IS that table, byte for byte - see fontconv.ps1's own
    # header note), which only affects the LOOK of the revert step, not
    # whether it runs cleanly.
    $fontSrc = "$root\tools\demo-files\fonts\Crews\Spectrum\Crews.ch8"
    if (Test-Path $fontSrc) {
        & "$root\authoring-kit\lib\fontconv.ps1" -In $fontSrc -Out "$leg\FONT.CHR" | Out-Null
        $fontSize = (Get-Item "$leg\FONT.CHR").Length
        "staged tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 -> sd\$legName\FONT.CHR ($fontSize bytes, via fontconv.ps1)"
    }
    else {
        Copy-Item "$root\authoring-kit\lib\default.chr" "$leg\FONT.CHR" -Force
        "staged authoring-kit\lib\default.chr -> sd\$legName\FONT.CHR ($((Get-Item "$leg\FONT.CHR").Length) bytes, Crews.ch8 not extracted here - GFX 0 16 still has a base font file to find)"
    }

    # FONT2.CHR: the base font emboldened (each row OR'd with itself
    # shifted right 1px). Visibly heavier than FONT.CHR at a glance,
    # which is the whole job of the fixture - and derived, so no binary
    # is committed and no external font archive has to be extracted
    # first (GFX 2 16, tests\fontsw.dsf MESSAGE 0).
    $bold = [System.IO.File]::ReadAllBytes("$root\authoring-kit\lib\default.chr")
    for ($i = 0; $i -lt $bold.Length; $i++) {
        $bold[$i] = [byte](($bold[$i] -bor ($bold[$i] -shr 1)) -band 0xFF)
    }
    [System.IO.File]::WriteAllBytes("$leg\FONT2.CHR", $bold)
    "staged a generated emboldened default.chr -> sd\$legName\FONT2.CHR (2048 bytes)"

    # Deliberately NO FONT3.CHR staged: tests\fontsw.dsf's GFX 3 16 exists
    # to prove an absent numbered font is a silent no-op that leaves font
    # 0 showing and the game running (MESSAGE 2) - staging one here would
    # make that leg of the fixture vacuous.

    # Two colour-coded numbered pointer shapes (MOUSE 2 5 / MOUSE 1 5)
    # via New-PointerFixture (defined near Reset-LegDir above), so which
    # shape is live is answerable by eye: shape 1 red, shape 2 blue.
    #
    # Deliberately NO root POINTER.SPR staged, for the same reason there
    # is no FONT3.CHR above. Shape 0 is the BASE pointer, which means
    # POINTER.SPR when the game ships one and the interpreter's built-in
    # arrow when it does not - so staging one here would hide the
    # built-in arrow behind it and the fixture's MOUSE 0 5 step would
    # only ever prove that a file loads, which shapes 1 and 2 already
    # prove. Leaving it out makes that step show the built-in arrow,
    # which is what every game gets by default and is otherwise not
    # exercised anywhere in the harness. The POINTER.SPR-overrides-the-
    # arrow path stays covered by the -Font modifier leg, which stages
    # exactly that and no numbered shapes.
    [System.IO.File]::WriteAllBytes("$leg\POINTER1.SPR", (New-PointerFixture 0xE0))  # red
    [System.IO.File]::WriteAllBytes("$leg\POINTER2.SPR", (New-PointerFixture 0x03))  # blue
    "staged 2 generated pointer fixtures -> sd\$legName\POINTER1.SPR (red) / POINTER2.SPR (blue), 256 bytes each; no root POINTER.SPR, so MOUSE 0 5 shows the built-in arrow"

    $fontSwActive = $true
}

if ($Palette) {
    Copy-Item "$root\tests\out\palette.ddb" (Join-Path $leg 'GAME.DDB') -Force
    "staged palette.ddb -> $leg\GAME.DDB"
    # The full-colour reference card. Generated, not committed - a
    # byte-exact function of the constants in tests\art\mkpalcard.py,
    # the same rule tests\art\mkl2card.py's card follows.
    #
    # .NX2, and 001 must be the only art in the folder. The picture
    # loader probes NNN.NX2 BEFORE NNN.NXI, so a leftover 001.NXI from
    # another leg cannot win the chain here - but a leftover 001.NX2
    # could, which is the vacuous-run failure the per-leg folders exist
    # to prevent. sd\PALETTE\ is emptied at the top of the staging
    # section, so nothing else of number 001 is reachable.
    #
    # 320-wide art also takes a different blit path from the .NXI cards
    # elsewhere in the suite: gfx_blit routes it to gfx_row_scatter320,
    # a CPU column scatter, rather than gfx_row_copy256 and one DMA call
    # per row. Damage specific to the scatter path shows up here.
    & python "$PSScriptRoot\art\mkpalcard.py" "$root\tests\out"
    if ($LASTEXITCODE -ne 0) { throw "tests\art\mkpalcard.py failed" }
    $palCardSrc = "$root\tests\out\palcard.nx2"
    if (-not (Test-Path $palCardSrc)) { throw "mkpalcard.py produced no palcard.nx2" }
    # gfx_derive_height reads the row count out of the FILE LENGTH -
    # (bytes - 512) / 320 for 320-wide art - and rejects a partial
    # trailing row or more than 256 rows, so the size is the one thing
    # that has to be right for the card to load at all.
    $palCardBytes = (Get-Item $palCardSrc).Length
    if ((($palCardBytes - 512) % 320) -ne 0) {
        throw "palcard.nx2 is $palCardBytes bytes - not 512 + a whole number of 320-byte rows"
    }
    $palCardRows = ($palCardBytes - 512) / 320
    if ($palCardRows -lt 1 -or $palCardRows -gt 256) {
        throw "palcard.nx2 is $palCardRows rows - 320-wide art must be 1 to 256"
    }
    Copy-Item $palCardSrc (Join-Path $leg '001.NX2') -Force
    "staged palcard.nx2 -> $leg\001.NX2  $palCardBytes bytes, 320x$palCardRows"
}

# The interpreter itself, so the folder is genuinely self-contained -
# one folder to copy, one file to launch. Not a rebuild: whatever
# build\nextdaad.nex currently holds is what gets staged (build.ps1 is
# the only thing that makes it).
$nexSrc = "$root\build\nextdaad.nex"
if (Test-Path $nexSrc) {
    Copy-Item $nexSrc "$leg\NEXTDAAD.NEX" -Force
    "staged build\nextdaad.nex -> sd\$legName\NEXTDAAD.NEX ($((Get-Item $nexSrc).Length) bytes)"
}
else {
    "WARNING: no build\nextdaad.nex - sd\$legName\ has no interpreter to launch (run .\build.ps1)"
}

$good = [System.IO.File]::ReadAllBytes("$leg\GAME.DDB")

"size=$($good.Length) (hex $('{0:X4}' -f $good.Length))"
"version=$($good[0]) target=$('{0:X2}' -f $good[1]) magic=$($good[2])"
$ptrs = for ($i = 8; $i -lt 34; $i += 2) { '{0:X4}' -f ($good[$i] + 256 * $good[$i+1]) }
"pointers: $($ptrs -join ' ')"

# EVERY database staged into the leg folder must carry the NEXTDAAD
# machine nibble. This line used to be PRINTED and nothing read it: a
# fixture compiled for the wrong target staged silently and surfaced
# only as "NextDAAD: DDB wrong machine - E4" on the glass, at which
# point it looks like an interpreter fault rather than a harness one.
#
# Scoped to the leg folder ON PURPOSE, not to tests\out\*.ddb. That
# directory legitimately holds classic databases - deliberate negative
# fixtures and one-off comparison builds - so a blanket sweep there
# would fail on files that are SUPPOSED to be machine 01. What must be
# true is narrower and stricter: whatever this run staged is what boots,
# and all of it must be this target.
#
# C1 (Spanish) is accepted as well as C0 (English) because the machine
# nibble is the target and the low nibble is the language - the two are
# independent, and refusing C1 here would encode an assumption the
# interpreter itself does not make.
foreach ($stagedDdb in Get-ChildItem -LiteralPath $leg -Filter '*.DDB' -File) {
    $sb = [System.IO.File]::ReadAllBytes($stagedDdb.FullName)
    if ($sb.Length -lt 3) { throw "$($stagedDdb.Name) is $($sb.Length) bytes - too short to be a database" }
    if (($sb[1] -band 0xF0) -ne 0xC0) {
        throw "sd\$legName\$($stagedDdb.Name) carries machine nibble $('0x{0:X2}' -f ($sb[1] -band 0xF0)), not 0xC0 (NEXTDAAD) - it was compiled for another target and will boot to E4. Check that its compile block passes the configured target."
    }
}
if ($xbnActive) { "active: extern (XBN extern support fixture$(if ($XbnNoBin) { ', no GAME.XBN staged' } elseif ($XbnBad) { ", GAME.XBN = $XbnBad reject variant" } elseif ($XbnTicker) { ', GAME.XBN = authoring-kit ticker example' }))" }
elseif ($fontSwActive) { "active: fontsw (SP18 font/pointer switching fixture)" }
elseif ($partActive) { "active: part 1 of 2 (NDPARTA/NDPARTB fixture pair - GAME2.DDB + PART2\0.XMB also staged)" }
elseif ($uuActive) { "active: urbanupstart" }
elseif ($UU) { "active: urbanupstart (GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($v3Active) { "active: v3probe (SP16 DAAD V3 fixture - header version 3)" }
elseif ($gmodeActive) { "active: gmodegate (SP16 GMODE graphics-gate fixture)" }
elseif ($audLadActive) { "active: audlad (SP16 Task 7 AY ladder / STOPM / BEEP-scale fixture)" }
elseif ($sfxDiActive) { "active: sfxdi (sampled-SFX DI-exposure ear fixture - see .superpowers\sdd\sfx-di-audible-test.md)" }
elseif ($sfxLongActive) { "active: sfxlong (SD-streamed sampled-effect wire fixture - SP18 item 7 Task 7)" }
elseif ($sfx2Active) { "active: sfx2 (two-channel sampled-effect API fixture - SP18 item 7 Task 12)" }
elseif ($l2holesActive) { "active: l2holes (Layer 2 transparency / punch-out fixture - see docs\superpowers\l2-holes-run-sheet.md)" }
elseif ($tileSlackActive) { "active: tileslack (--tile-slack A/B fixture, two pairs - see docs\superpowers\tileslack-ab-run-sheet.md)" }
elseif ($utoV3Active) { "active: utotest V3 (Uto's THIRD-PARTY DAAD compliance test, header version 3 - self-scoring, 68 'OK' lines = full pass; see .superpowers\sdd\uto-compliance-runsheet.md)" }
elseif ($utoActive) { "active: utotest V2 (Uto's THIRD-PARTY DAAD compliance test - self-scoring, 64 'OK' lines = full pass; see .superpowers\sdd\uto-compliance-runsheet.md)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
elseif ($BigDdb) { "active: bigddb ($bigLen bytes, past the 31744 classic ceiling)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }

# ---- what to copy, what to launch ---------------------------------
$legFiles = @(Get-ChildItem -LiteralPath $leg -Force -Recurse -File | Sort-Object FullName)
$legBytes = ($legFiles | Measure-Object -Property Length -Sum).Sum
""
"=== sd\$legName\ - $($legFiles.Count) file(s), $legBytes bytes ==="
foreach ($f in $legFiles) {
    $rel = $f.FullName.Substring($leg.Length + 1)
    "  {0,-18} {1,12}" -f $rel, $f.Length
}
"COPY   sd\$legName\  (the whole folder, to the card)"
"LAUNCH NEXTDAAD.NEX  (from inside that folder - the game reads GAME.DDB and every asset from its own directory)"
