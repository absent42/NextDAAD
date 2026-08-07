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
#   -L2Holes            sd\L2HOLES\   tests\l2holes.dsf
#   -Uto                sd\UTO\       tools\TEST.DSF     (V2)
#   -UtoV3              sd\UTOV3\     tools\TEST.DSF     (V3)
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
# ships pre-converted - so giving -UU pictures means converting the
# PNGs with tools\png2nx.py to somewhere OUTSIDE the read-only vendor
# dir and pointing $uuSrc's art scan at it. Owner's call, not done.
# All destinations are inside the run's leg folder - see the LEG
# FOLDERS block at the top.
# The DDB switches are mutually exclusive - if more than one is given,
# whichever copy runs last in this script wins: -Suite copies first,
# -Err4 copies over it, -GMode copies over that, -V3 over that,
# -Rab copies over that,
# -UU copies over that, then -Part, then -AudLad, then -SfxDi, then
# -L2Holes last of
# all, in the order their blocks appear below. $legName is resolved in
# exactly that order, so the folder and the active DDB always agree.
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
#            copies tools\demo-files\DAAD.NX2
#            (converted from demo-files\DAAD.png via tools\png2nx.py).
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
#            stages no font.
#            SP12 Task 3 rides the same switch: -Font ALSO generates a
#            fresh 256-byte POINTER.SPR fixture
#            in-script (a 16x16 solid green square, 2px $E3 transparent
#            border, 1px black outline - obviously different from the
#            interpreter's default black/white arrow at a glance). No
#            test binary is committed for this either.
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
param([switch]$Suite, [switch]$Err4, [switch]$GMode, [switch]$V3, [switch]$Rab, [switch]$UU, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud, [switch]$AudLad, [switch]$SfxDi, [switch]$L2Holes, [switch]$Title, [switch]$Part, [switch]$Font, [switch]$Vid, [switch]$VidLong, [switch]$NxBench, [switch]$Nxv2Test, [switch]$Uto, [switch]$UtoV3)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dr = Join-Path $root 'tools\DAAD-READY'
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
if ($L2Holes)          { $legName = 'L2HOLES' }
if ($Uto)              { $legName = 'UTO' }
if ($UtoV3)            { $legName = 'UTOV3' }
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
               'V3', 'RAB', 'UU', 'PART', 'AUDLAD', 'SFXDI', 'L2HOLES',
               'UTO', 'UTOV3')
    if ($known -notcontains $Name) { throw "Reset-LegDir: '$Name' is not a known leg folder" }
    $p = Join-Path $sd $Name
    if ((Split-Path -Parent $p) -ne $sd) { throw "Reset-LegDir: '$p' is not directly under $sd" }
    if (Test-Path -LiteralPath $p) {
        Get-ChildItem -LiteralPath $p -Force | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Force $p | Out-Null
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
    & .\TOOLS\DRC\DRF.exe zx next NDTEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDTEST.json NDTEST.DDB
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

# ---- Layer 2 transparency constants: four files, one pair of values ----
# The transparent COLOUR ($E3) and the reserved INDEX (255) are written
# out longhand in four places in three languages - src/nextdaad.inc is
# canonical, and the other three are the converters and the kit's audit
# script. There is no shared header they can include, so the only thing
# that keeps them together is this check. A silent divergence is the
# nastiest shape of failure available here: the interpreter would dodge
# one colour while a converter reserved another, and nothing would say
# so until art punched holes on hardware. Runs on EVERY invocation - it
# is source-only, needs no build, and costs four file reads.
function Assert-TranspConstantsInSync {
    # file -> @{ colour = <regex>; index = <regex> }; each regex must
    # capture the literal in group 1. Index is optional (nxv2enc.py only
    # deals with the colour), colour is not.
    $sites = [ordered]@{
        'src\nextdaad.inc' = @{
            colour = '(?m)^\s*L2_TRANSP_COLOUR\s+equ\s+\$([0-9A-Fa-f]+)'
            index  = '(?m)^\s*L2_TRANSP_INDEX\s+equ\s+(\d+)'
        }
        'scripts\png2nx.py' = @{
            colour = '(?m)^\s*L2_TRANSPARENT_BYTE0\s*=\s*0x([0-9A-Fa-f]+)'
            index  = '(?m)^\s*RESERVED_INDEX\s*=\s*(\d+)'
        }
        'authoring-kit\lib\nxv2enc.py' = @{
            colour = '(?m)^\s*L2_TRANSPARENT_BYTE0\s*=\s*0x([0-9A-Fa-f]+)'
            index  = $null
        }
        'authoring-kit\lib\palcheck.ps1' = @{
            colour = '(?m)^\s*\$TRANSP\s*=\s*0x([0-9A-Fa-f]+)'
            index  = '(?m)^\s*\$RESERVED\s*=\s*(\d+)'
        }
    }
    $colours = [ordered]@{}
    $indices = [ordered]@{}
    foreach ($rel in $sites.Keys) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) {
            throw "L2 transparency constant sync: $rel is missing - the four-file agreement check needs it (if the file moved, update Assert-TranspConstantsInSync)"
        }
        $text = Get-Content -LiteralPath $path -Raw
        $m = [regex]::Match($text, $sites[$rel].colour)
        if (-not $m.Success) {
            throw "L2 transparency constant sync: no transparent-colour definition found in $rel (pattern '$($sites[$rel].colour)') - it was renamed or deleted, so nothing is holding the four files together any more"
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
    foreach ($pair in @(@{ n = 'transparent COLOUR'; v = $colours; f = 'X2' },
                        @{ n = 'reserved INDEX';    v = $indices; f = 'D' })) {
        $canon = 'src\nextdaad.inc'
        $want = $pair.v[$canon]
        $bad = @($pair.v.Keys | Where-Object { $pair.v[$_] -ne $want })
        if ($bad.Count -gt 0) {
            $detail = ($pair.v.Keys | ForEach-Object { "$_ = $($pair.v[$_].ToString($pair.f))" }) -join '; '
            throw ("L2 transparency $($pair.n) DESYNC: src\nextdaad.inc says $($want.ToString($pair.f)) but " +
                   (($bad | ForEach-Object { "$_ says $($pair.v[$_].ToString($pair.f))" }) -join ' and ') +
                   ". All four copies must move together - $detail")
        }
    }
    "L2 transparency constants agree across 4 files: colour `$$($colours['src\nextdaad.inc'].ToString('X2')), index $($indices['src\nextdaad.inc'])"
}
Assert-TranspConstantsInSync

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
    & .\TOOLS\DRC\DRF.exe zx next NDSUITE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (suite)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDSUITE.json NDSUITE.DDB
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
    & .\TOOLS\DRC\DRF.exe zx next NDNEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (doallnest)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDNEST.json NDNEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (doallnest)" }
    Move-Item NDNEST.DDB "$root\tests\out\doallnest.ddb" -Force
}
finally {
    Remove-Item "$dr\NDNEST.DSF", "$dr\NDNEST.json" -ErrorAction SilentlyContinue
    Pop-Location
}

# SP16 Task 1 GMODE graphics-gate fixture. Compiled unconditionally,
# like the suite and doallnest above, so a break in the DSF is caught
# on a plain run; only -GMode makes it the active GAME.DDB (sd\GMODE\).
Copy-Item "$PSScriptRoot\gmodegate.dsf" "$dr\NDGMODE.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDGMODE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (gmodegate)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDGMODE.json NDGMODE.DDB
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
    & .\TOOLS\DRC\DRF.exe zx next NDAUDLAD.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (audlad)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDAUDLAD.json NDAUDLAD.DDB
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
    & .\TOOLS\DRC\DRF.exe zx next NDSFXDI.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (sfxdi)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDSFXDI.json NDSFXDI.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (sfxdi)" }
    Move-Item NDSFXDI.DDB "$root\tests\out\sfxdi.ddb" -Force
}
finally {
    Remove-Item "$dr\NDSFXDI.DSF", "$dr\NDSFXDI.json" -ErrorAction SilentlyContinue
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
    & .\TOOLS\DRC\DRF.exe zx next NDDBGF.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (debugflag)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDDBGF.json NDDBGF.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (debugflag)" }
    Move-Item NDDBGF.DDB "$root\tests\out\debugflag.ddb" -Force
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDDBGF.json NDDBGF.DDB -d
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
    & "$dr\TOOLS\DRC\DRF.exe" zx next NDL2HOLE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (l2holes)" }
    & "$dr\PHP\php.exe" "$dr\TOOLS\DRC\DRB.PHP" zx next EN NDL2HOLE.json NDL2HOLE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (l2holes)" }
    Copy-Item NDL2HOLE.DDB "$root\tests\out\l2holes.ddb" -Force
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
# The four HELD renders: DISPLAY 0 followed by PAUSE 24 (authored 40 x
# DRC's 0.6). Without the hold a damaged render flashes past in ~75 ms.
$heldHits = Find-ByteRuns $sfxdiBytes ([byte[]]@(28, 0, 35, 24))
if ($heldHits.Count -ne 4) {
    throw "sfxdi: expected exactly four 'DISPLAY 0 + PAUSE 24' held renders (1C 00 23 18); found $($heldHits.Count) - DRC's duration scaling has changed"
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
$pauseHits = Find-ByteRuns $sfxdiBytes ([byte[]]@(35, 38))
if ($pauseHits.Count -lt 3) {
    throw "sfxdi: expected the reference phases and the control hold to compile to PAUSE 38 (23 26); found $($pauseHits.Count) occurrences - DRC's duration scaling has changed"
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
        @{ n = 'card-up boundary before phase 1/5 (ANYKEY, MES, PAUSE 38)'; p = @(24, 77, $null, 35, 38); c = 1 },
        @{ n = 'phase 1/5 + control-leg closing boundaries (PAUSE 38, MES, ANYKEY)'; p = @(35, 38, 77, $null, 24); c = 2 },
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
"sfxdi.ddb: v$($sfxdiBytes[0]), 24x DISPLAY 0 at $($dispHits[0]), 4x held render contiguous at $($heldHits[0]), 20x GFX 0 1/0 0 at $($gfxHits[0]), PAUSE 38 x$($pauseHits.Count), 8 ANYKEY boundaries at $($akAll -join ','), PICTURE 1 + SFX 1 2 / 2 2 / 0 5 all present"

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
    #   3E 0E      ld a, TM_ATTR_DEFAULT (7*2 = 14)
    #   32 lo hi   ld (tmAttr), a
    #   3E 20      ld a, GLYPH_SPACE
    #   C3 lo hi   jp tm_fill_rect
    # NOTE: >= 1, not == 1. src\debug.asm's dbg_bar_white independently
    # emits the identical four instructions (ld a,7*2 / ld (tmAttr),a /
    # ld a,GLYPH_SPACE / jp tm_fill_rect), so this pattern legitimately
    # appears twice in different pages. Do NOT tighten this to an exact
    # count - it will fail for the wrong reason. The load-bearing half of
    # this check is the attribute-254 scan below, which must stay at 0.
    $blank = Find-MaskedRuns $nex @(0x3E, 0x0E, 0x32, $null, $null, 0x3E, 0x20, 0xC3)
    if ($blank.Count -lt 1) {
        throw "tm_clear_blank: no 'ld a,14 / ld (tmAttr),a / ld a,`$20 / jp tm_fill_rect' sequence in build\nextdaad.nex - the tilemap blank is not using the default black-paper attribute"
    }
    $stale = Find-MaskedRuns $nex @(0x3E, 0xFE, 0x32, $null, $null, 0x3E, 0x20, 0xC3)
    if ($stale.Count -ne 0) {
        throw "tm_clear_blank: the old attribute-254 clear is still present - uncovered cells will still paint opaque DAAD white"
    }
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
    & .\TOOLS\DRC\DRF.exe zx next NDV3.DSF -v3
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (v3probe)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDV3.json NDV3.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDUTO.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (utotest V2)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDUTO.json NDUTO.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDUTO3.DSF -v3
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (utotest V3)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDUTO3.json NDUTO3.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDRAB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (rabenstein)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDRAB.json NDRAB.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDUU.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (urbanupstart)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDUU.json NDUU.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDPARTA.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (NDPARTA)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDPARTA.json NDPARTA.DDB
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
        & .\TOOLS\DRC\DRF.exe zx next NDPARTB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (NDPARTB)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDPARTB.json NDPARTB.DDB
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
    # The owner-authored 320x256 title (tools\demo-files\DAAD.png) is
    # converted to tools\demo-files\DAAD.NX2 by tools\png2nx.py
    # (ADAPTIVE 256, gfx2next -bitmap -pal-embed; 82432 bytes =
    # 512 pal + 320x256).
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
    $fontSrc = "$root\tools\demo-files\fonts\Crews\Spectrum\Crews.ch8"
    & "$root\authoring-kit\lib\fontconv.ps1" -In $fontSrc -Out "$leg\FONT.CHR" | Out-Null
    $fontSize = (Get-Item "$leg\FONT.CHR").Length
    "staged tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 -> sd\$legName\FONT.CHR ($fontSize bytes, via fontconv.ps1)"

    # SP12 Task 3 owner leg fixture: pointer_load (overlay0.asm) probes
    # POINTER.SPR at boot (and PARTn\POINTER.SPR for parts >= 2), so
    # the owner-eye-leg needs one staged alongside the font fixture just
    # above - same switch, no separate -Pointer flag. No binary is
    # committed (same policy as the font fixture): the 256 bytes are
    # generated right here, a 16x16 solid square with a 2px $E3
    # (hardware transparent) border, a 1px $00 (black) outline, and a
    # $1C (pure green, RGB332) fill - a shape and colour obviously
    # different from mousePattern's own compiled-in black/white diagonal
    # arrow (overlay0.asm) at a glance.
    $ptr = New-Object byte[] 256
    for ($y = 0; $y -lt 16; $y++) {
        for ($x = 0; $x -lt 16; $x++) {
            if ($x -lt 2 -or $x -gt 13 -or $y -lt 2 -or $y -gt 13) {
                $b = 0xE3                          # transparent border
            } elseif ($x -eq 2 -or $x -eq 13 -or $y -eq 2 -or $y -eq 13) {
                $b = 0x00                          # black outline
            } else {
                $b = 0x1C                          # green fill
            }
            $ptr[$y * 16 + $x] = $b
        }
    }
    [System.IO.File]::WriteAllBytes("$leg\POINTER.SPR", $ptr)
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
$vidLegSettlementTag = 'pal9t'

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
    # byte0 equals L2_TRANSP_COLOUR to $E2): two would make a hole
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
if ($partActive) { "active: part 1 of 2 (NDPARTA/NDPARTB fixture pair - GAME2.DDB + PART2\0.XMB also staged)" }
elseif ($uuActive) { "active: urbanupstart" }
elseif ($UU) { "active: urbanupstart (GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($v3Active) { "active: v3probe (SP16 DAAD V3 fixture - header version 3)" }
elseif ($gmodeActive) { "active: gmodegate (SP16 GMODE graphics-gate fixture)" }
elseif ($audLadActive) { "active: audlad (SP16 Task 7 AY ladder / STOPM / BEEP-scale fixture)" }
elseif ($sfxDiActive) { "active: sfxdi (sampled-SFX DI-exposure ear fixture - see .superpowers\sdd\sfx-di-audible-test.md)" }
elseif ($l2holesActive) { "active: l2holes (Layer 2 transparency / punch-out fixture - see docs\superpowers\l2-holes-run-sheet.md)" }
elseif ($utoV3Active) { "active: utotest V3 (Uto's THIRD-PARTY DAAD compliance test, header version 3 - self-scoring, 68 'OK' lines = full pass; see .superpowers\sdd\uto-compliance-runsheet.md)" }
elseif ($utoActive) { "active: utotest V2 (Uto's THIRD-PARTY DAAD compliance test - self-scoring, 64 'OK' lines = full pass; see .superpowers\sdd\uto-compliance-runsheet.md)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
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
