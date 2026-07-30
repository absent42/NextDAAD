# Compiles tests\test.dsf (template), tests\condacts.dsf (suite) and
# tests\doallnest.dsf (DOALL depth/error demo) with DRC (version 2
# DDB), generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active sd\GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process); -Rab compiles the modernised next-
# only tools\Rabenstein-master\nextdaad\rabenstein.dsf (the real
# commercial-quality DAAD game), makes that DDB active, and stages the
# Layer 2 art (default N.NX2 -> sd\NNN.NX2); -UU compiles the owner-
# authored tools\urban-upstart\URBAN_UPSTART.DSF (untracked vendor dir -
# never edit it here), makes that DDB active, and stages whatever
# N.NXI/N.NX2 art exists there as-is (currently NXI-only) to sd\NNN.NXI.
# The DDB switches are mutually exclusive - if more than one is given,
# whichever copy runs last in this script wins: -Suite copies first,
# -Err4 copies over it, -Rab copies over that, -UU copies over that, and
# -Part copies last of all (both its files - see below), since its
# block comes after -UU's. The template is active if no switch is given.
# Two-part fixture (SP11 Task 6), independent of the single-DDB switches
# above except that it also writes sd\GAME.DDB (see the mutually-
# exclusive note):
#   -Part    compile and stage both halves of the NDPARTA.DSF/
#            NDPARTB.DSF fixture pair. NDPARTA -> sd\GAME.DDB (part 1,
#            byte-identical to a single-part game) + sd\0.XMB; NDPARTB
#            -> sd\GAME2.DDB (part 2) + sd\PART2\0.XMB (directory
#            created if absent). The two 0.XMB files hold DIFFERENT
#            content at overlapping offsets by design - NDPARTB.DSF's
#            own XMES line only reads back clean if the interpreter's
#            PARTn\ probe (SP11 Task 5) actually wins over the root
#            file; a wrong probe reads part A's bytes at part B's
#            offsets instead (garbled/wrong text, not a crash). Same
#            CSpect-running guard as -Rab/-UU; stale-cleans sd\GAME2.DDB
#            and both 0.XMB files before restaging. The fixture pair's
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
#   -GfxZx0  ZX0-compress each staged file (sd\NNN.NX2.ZX0 / with
#            -Gfx256 sd\NNN.NXI.ZX0) so the interpreter's compressed
#            picture path is exercised
#   (-UU always stages whatever single art shape ships in
#    tools\urban-upstart - no modifiers; that corpus has no parallel
#    NX2/NXI pair to choose between)
# Audio staging (combinable with any DDB switch):
#   -Aud     stage the test audio assets from tools\audio_assets\
#            (GAME.AKY, 001.AKY, GAME.SFB, 001.WAV, 001.AYS, 002.AYS -
#            produced by the export script / aysconv.ps1) into sd\, after
#            removing stale sd\*.AKY, sd\GAME.SFB, sd\*.WAV and sd\*.AYS;
#            warns and skips if the folder is empty
# Boot title screen (SP11 Task 1), independent of the DDB switches:
#   -Title   stage the owner 320x256 title into sd\ - stale-cleans
#            sd\DAAD.* variants then copies tools\demo-files\DAAD.NX2
#            (converted from demo-files\DAAD.png via tools\png2nx.py).
#            tools\demo-files is the home for NEWLY CREATED test
#            graphics/sound/video assets (owner convention 2026-07-19;
#            existing asset dirs stay where they are). Not committed
#            (sd\ is gitignored). Default (no -Title) leaves sd\
#            untouched.
# Custom font (SP12 Task 2), independent of the DDB switches:
#   -Font    stage a visually distinctive custom font into sd\ - stale-
#            cleans sd\FONT.CHR then runs authoring-kit\lib\fontconv.ps1
#            on tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 (a 768-
#            byte classic ZX charset, chars 32-127 - the "Crews" ZX-
#            Origins font: a bold, tilted, graffiti-style face, chosen
#            for being obviously different from the interpreter's plain
#            embedded font at a glance, and shipped as a single file with
#            no bold/script weight variants to disambiguate). No test
#            binary is committed - fontconv.ps1 builds sd\FONT.CHR fresh
#            each run from the source .ch8 plus authoring-kit\lib\
#            default.chr. Same CSpect-running guard as -Title (locked
#            sd\ files cause a partial fixture). Default (no -Font)
#            leaves sd\ untouched.
#            SP12 Task 3 rides the same switch: -Font ALSO stale-cleans
#            sd\POINTER.SPR then generates a fresh 256-byte fixture
#            in-script (a 16x16 solid green square, 2px $E3 transparent
#            border, 1px black outline - obviously different from the
#            interpreter's default black/white arrow at a glance). No
#            test binary is committed for this either.
# Video benchmark fixtures (SP13 Task 1, NXV v2 rewrite SP15 T1; LEG SET
# switched to the SP15 3a calibration-wave fixtures 2026-07-25),
# independent of the DDB switches:
#   -Vid     stage the CURRENT LEG SET into sd\001.VID..sd\006.VID - the
#            SAME six fixtures the owner leg card stages
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
#            always benches sd\001.VID (full, the highest data-rate
#            shape - the conservative gate). Stale-cleans ONLY the
#            files this switch owns, sd\001.VID..sd\006.VID (SP15 T5
#            review fix: a bare sd\*.VID wipe used to also delete
#            007-011.VID/099.VID, breaking a -Vid-then-VidLong combined
#            stage). Source -> dest mapping (shape, source clip, exact
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
#            sd\001-006.VID which this switch always stale-cleans
#            first). $vidLegSettlementTag below is an EXPLICIT TAG BUMP
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
#   -VidLong stage the SP15 3b STREAMING leg fixtures into sd\ - the
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
#            either re-encodes). Does NOT touch
#            sd\001-006.VID, so it can be staged alongside -Vid.
#            Verbs: VSTR0/VSTR1/VSTR2/VSTRU (tests\test.dsf). Same
#            CSpect-lock guard.
#   -NxBench   stage the SP15 T2 decode-kernel bench payloads into
#              sd\NXB0.BIN..sd\NXB9.BIN (nxv2enc.py --bench-fixtures -
#              raw opcode-stream payloads, no header/audio/padding; see
#              that mode's own comment block for the file-by-file
#              shapes, and .superpowers\sdd\sp14a-task-4-report.md
#              section 36 for the owner bench card). NXB8 (the real
#              classic 256x192@25 segment) is cut from the -Vid cache
#              tests\out\002_classic_cache.vid, which is encoded first
#              if missing (slow - same cache rule as -Vid). Fixture
#              set + manifest land in tests\out\nxbench\ then copy to
#              sd\ (stale-clean first). Same CSpect-lock guard as the
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
param([switch]$Suite, [switch]$Err4, [switch]$Rab, [switch]$UU, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud, [switch]$Title, [switch]$Part, [switch]$Font, [switch]$Vid, [switch]$VidLong, [switch]$NxBench, [switch]$Nxv2Test)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dr = Join-Path $root 'tools\DAAD-READY'

New-Item -ItemType Directory -Force "$root\tests\out" | Out-Null

Copy-Item "$PSScriptRoot\test.dsf" "$dr\NDTEST.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDTEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDTEST.json NDTEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed" }
    Move-Item NDTEST.DDB "$root\sd\GAME.DDB" -Force
    # tests\test.dsf has no XMESSAGE yet (Task 5 adds the verb), so DRB
    # emits no 0.XMB for the template - tolerate absence. Wired now so
    # Task 5 needs no script change: stage sd\0.XMB in the same
    # default/template path the DDB copy above uses, right after it.
    if (Test-Path '0.XMB') {
        Move-Item '0.XMB' "$root\tests\out\template.xmb" -Force
        Copy-Item "$root\tests\out\template.xmb" "$root\sd\0.XMB" -Force
        "staged tests\out\template.xmb -> sd\0.XMB"
    }
}
finally {
    Remove-Item "$dr\NDTEST.DSF", "$dr\NDTEST.json", "$dr\0.XMB" -ErrorAction SilentlyContinue
    Pop-Location
}

& "$PSScriptRoot\check-cprops.ps1"

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

$good = [System.IO.File]::ReadAllBytes("$root\sd\GAME.DDB")

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

if ($Suite) {
    # Suite semantics assume no sample/music/effects assets staged EXCEPT
    # the one 002.AYS stream check 76 loads - an earlier -Aud run's other
    # residue would reroute checks 66/69 through the sample path and an
    # out-of-range AY effect, and a stray 200.AYS would break check 75.
    # Stale-clean every audio kind first (including *.AYS), then copy the
    # 098/099 fixtures and the single 002.AYS in.
    Remove-Item "$root\sd\*.WAV", "$root\sd\*.AKY", "$root\sd\*.AYS", "$root\sd\GAME.SFB", "$root\sd\0.XMB" -Force -ErrorAction SilentlyContinue
    Copy-Item "$root\tests\out\condacts.ddb" "$root\sd\GAME.DDB" -Force
    Copy-Item "$root\tests\out\truncwav.bin" "$root\sd\098.WAV" -Force
    Copy-Item "$root\tests\out\badwav.bin" "$root\sd\099.WAV" -Force
    Copy-Item "$root\tests\out\condacts.xmb" "$root\sd\0.XMB" -Force
    "staged tests\out\condacts.xmb -> sd\0.XMB"
    # Streamed-song fixture for check 76 (SFX 2 7). Optional: if the audio
    # export has not been run the check still passes as a clean no-op, so
    # warn and continue rather than fail the suite build.
    $ays2 = "$root\tools\audio_assets\002.AYS"
    if (Test-Path $ays2) {
        Copy-Item $ays2 "$root\sd\002.AYS" -Force
        "staged tools\audio_assets\002.AYS -> sd\002.AYS (check 76)"
    }
    else {
        "WARNING: $ays2 absent - check 76 will no-op (run the audio export / aysconv.ps1 to exercise the stream path)"
    }
}
if ($Err4) {
    Copy-Item "$root\tests\out\doallnest.ddb" "$root\sd\GAME.DDB" -Force
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
            Copy-Item NDRAB.DDB "$root\sd\GAME.DDB" -Force
            Remove-Item NDRAB.DDB -ErrorAction SilentlyContinue
            $rabActive = $true
        }
        catch {
            "WARNING: could not copy to sd\GAME.DDB (likely locked by a running CSpect - close it and copy $dr\NDRAB.DDB across manually): $_"
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
    # ratio difference does not matter for tests) into sd\NNN.<ext>.ZX0
    # - a single whole-file ZX0 stream, which the interpreter's
    # gfx_depack accepts exactly like Gfx2Next's own two-stream output.
    # Gfx2Next itself only compresses at CONVERSION time, from an 8-bit
    # paletted source image:
    #   gfx2next -bitmap -pal-embed -zx0 pic.png N.NX2   -> N.NX2.zx0
    # (same for N.NXI; -zx0 APPENDS ".zx0" to the output name). This
    # script has no image-conversion step - the Rabenstein art ships
    # pre-converted - so -GfxZx0 compresses the shipped files instead.
    # Stale variants of each staged number are removed first so the
    # loader's probe chain (NX2.ZX0 -> N2Z -> NX2 -> NXI.ZX0 -> NXZ ->
    # NXI) cannot pick up a leftover from a previous staging run.
    $srcExt = if ($Gfx256) { 'NXI' } else { 'NX2' }
    $zx0 = "$root\tools\z88dk\bin\z88dk-zx0.exe"
    $staged = 0
    Get-ChildItem "$rabSrc\*.$srcExt" | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object {
        $art = $_
        $padded = '{0:D3}' -f [int]$art.BaseName
        try {
            foreach ($stale in @('NX2', 'NXI', 'N2Z', 'NXZ', 'NX2.ZX0', 'NXI.ZX0')) {
                Remove-Item "$root\sd\$padded.$stale" -Force -ErrorAction SilentlyContinue
            }
            if ($GfxZx0) {
                & $zx0 -f -q $art.FullName "$root\sd\$padded.$srcExt.ZX0" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "z88dk-zx0 exited $LASTEXITCODE" }
            }
            else {
                Copy-Item $art.FullName "$root\sd\$padded.$srcExt" -Force
            }
            $staged++
        }
        catch {
            "WARNING: could not stage $($art.Name) (likely locked by a running CSpect - close it and retry): $_"
        }
    }
    $shape = $srcExt + $(if ($GfxZx0) { '.ZX0' } else { '' })
    "staged $staged Rabenstein art file(s) -> sd\NNN.$shape"
}

$uuActive = $false
if ($UU) {
    # Same CSpect lock hazard as -Rab: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial/mixed art sets)"
    }
    # tools\urban-upstart\URBAN_UPSTART.DSF is OWNER-AUTHORED and the vendor
    # dir is untracked working material - never edit it here. Compiled
    # exactly like rabenstein.dsf above: copy into DAAD-READY, run DRF/DRB
    # with no preprocessing, and let a DRC failure abort the script (its
    # error surfacing is the point - do not swallow it).
    $uuSrc = "$root\tools\urban-upstart"
    Copy-Item "$uuSrc\URBAN_UPSTART.DSF" "$dr\NDUU.DSF" -Force
    Push-Location $dr
    try {
        & .\TOOLS\DRC\DRF.exe zx next NDUU.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (urbanupstart)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDUU.json NDUU.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (urbanupstart)" }
        Copy-Item NDUU.DDB "$root\tests\out\urbanupstart.ddb" -Force
        try {
            Copy-Item NDUU.DDB "$root\sd\GAME.DDB" -Force
            Remove-Item NDUU.DDB -ErrorAction SilentlyContinue
            $uuActive = $true
        }
        catch {
            "WARNING: could not copy to sd\GAME.DDB (likely locked by a running CSpect - close it and copy $dr\NDUU.DDB across manually): $_"
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
    # exists. Same stale-variant cleanup per staged number as -Rab, so a
    # leftover Rabenstein NX2 at the same number cannot survive alongside it.
    $uuExt = if (Get-ChildItem "$uuSrc\*.NX2" -ErrorAction SilentlyContinue) { 'NX2' } else { 'NXI' }
    $uuStaged = 0
    Get-ChildItem "$uuSrc\*.$uuExt" | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object {
        $art = $_
        $padded = '{0:D3}' -f [int]$art.BaseName
        try {
            foreach ($stale in @('NX2', 'NXI', 'N2Z', 'NXZ', 'NX2.ZX0', 'NXI.ZX0')) {
                Remove-Item "$root\sd\$padded.$stale" -Force -ErrorAction SilentlyContinue
            }
            Copy-Item $art.FullName "$root\sd\$padded.$uuExt" -Force
            $uuStaged++
        }
        catch {
            "WARNING: could not stage $($art.Name) (likely locked by a running CSpect - close it and retry): $_"
        }
    }
    "staged $uuStaged Urban Upstart art file(s) -> sd\NNN.$uuExt"
}

$partActive = $false
if ($Part) {
    # SP11 Task 6: two-part fixture pair. Same CSpect-lock hazard as
    # -Rab/-UU (four files across two DDBs this time) - refuse to stage
    # rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial part staging)"
    }
    New-Item -ItemType Directory -Force "$root\sd\PART2" | Out-Null
    # Stale-clean both DDBs' worth of previous output before restaging -
    # sd\GAME.DDB itself is always overwritten below (-Force), but the
    # other three are only ever written by this switch, so a stale copy
    # from an interrupted/older run would otherwise survive untouched.
    Remove-Item "$root\sd\GAME.DDB", "$root\sd\0.XMB", "$root\sd\GAME2.DDB", "$root\sd\PART2\0.XMB" -Force -ErrorAction SilentlyContinue

    # Part A (root) -> sd\GAME.DDB + sd\0.XMB. Part 1 is root-only by
    # design (h_xpart/xpart_build_name), so this is byte-identical to
    # staging any other single-part DDB as the active game.
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
        Move-Item NDPARTA.DDB "$root\sd\GAME.DDB" -Force
        # NDPARTA.DSF always uses XMESSAGE (its own header comment) -
        # no Test-Path guard, matching -Suite's own condacts.xmb
        # handling: an absence here is a real regression worth throwing
        # on, not a silently-tolerated gap like the plain template.
        if (-not (Test-Path '0.XMB')) { throw "NDPARTA.DSF produced no 0.XMB - XMESSAGE missing from the source?" }
        Move-Item '0.XMB' "$root\tests\out\parta.xmb" -Force
        Copy-Item "$root\tests\out\parta.xmb" "$root\sd\0.XMB" -Force
    }
    finally {
        Remove-Item "$dr\NDPARTA.DSF", "$dr\NDPARTA.json" -ErrorAction SilentlyContinue
        Pop-Location
    }

    # Part 2 -> sd\GAME2.DDB + sd\PART2\0.XMB (the PARTn\ shadow the
    # interpreter's asset probe expects - SP11 Task 5).
    Copy-Item "$PSScriptRoot\NDPARTB.DSF" "$dr\NDPARTB.DSF" -Force
    Push-Location $dr
    try {
        Remove-Item '0.XMB' -ErrorAction SilentlyContinue
        & .\TOOLS\DRC\DRF.exe zx next NDPARTB.DSF
        if ($LASTEXITCODE -ne 0) { throw "DRF failed (NDPARTB)" }
        & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDPARTB.json NDPARTB.DDB
        if ($LASTEXITCODE -ne 0) { throw "DRB failed (NDPARTB)" }
        Move-Item NDPARTB.DDB "$root\sd\GAME2.DDB" -Force
        if (-not (Test-Path '0.XMB')) { throw "NDPARTB.DSF produced no 0.XMB - XMES missing from the source?" }
        Move-Item '0.XMB' "$root\tests\out\partb.xmb" -Force
        Copy-Item "$root\tests\out\partb.xmb" "$root\sd\PART2\0.XMB" -Force
    }
    finally {
        Remove-Item "$dr\NDPARTB.DSF", "$dr\NDPARTB.json" -ErrorAction SilentlyContinue
        Pop-Location
    }

    $partActive = $true
    $partaSize = (Get-Item "$root\sd\GAME.DDB").Length
    $partbSize = (Get-Item "$root\sd\GAME2.DDB").Length
    $partaXmbSize = (Get-Item "$root\sd\0.XMB").Length
    $partbXmbSize = (Get-Item "$root\sd\PART2\0.XMB").Length
    "staged NDPARTA -> sd\GAME.DDB ($partaSize bytes) + sd\0.XMB ($partaXmbSize bytes)"
    "staged NDPARTB -> sd\GAME2.DDB ($partbSize bytes) + sd\PART2\0.XMB ($partbXmbSize bytes)"
}

if ($Title) {
    # SP11 Task 1 owner leg fixture: title_present/title_boot (overlay2.asm)
    # probe sd\DAAD.* at boot, so the owner-eye-leg needs one staged.
    # The owner-authored 320x256 title (tools\demo-files\DAAD.png) is
    # converted to tools\demo-files\DAAD.NX2 by tools\png2nx.py
    # (ADAPTIVE 256, gfx2next -bitmap -pal-embed; 82432 bytes =
    # 512 pal + 320x256).
    # Stale DAAD.* variants are cleared first so exactly one title is
    # staged and the NX2-first probe order is what the leg exercises.
    # Same CSpect lock hazard as -Rab/-UU: refuse to stage rather than
    # warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial title fixture)"
    }
    foreach ($v in @('NX2', 'NXI', 'N2Z', 'NXZ', 'NX2.ZX0', 'NXI.ZX0')) {
        Remove-Item "$root\sd\DAAD.$v" -Force -ErrorAction SilentlyContinue
    }
    Copy-Item "$root\tools\demo-files\DAAD.NX2" "$root\sd\DAAD.NX2" -Force
    "staged tools\demo-files\DAAD.NX2 -> sd\DAAD.NX2 (320x256 owner title)"
}

if ($Font) {
    # SP12 Task 2 owner leg fixture: font_load (overlay2.asm) probes
    # sd\FONT.CHR at boot (and PARTn\FONT.CHR for parts >= 2), so the
    # owner-eye-leg needs one staged. tools\demo-files\fonts\Crews is a
    # 768-byte classic ZX charset (chars 32-127) - a bold, tilted,
    # graffiti-style face, visually distinctive from the interpreter's
    # plain embedded font at a glance. No test binary is committed
    # (authoring-kit hard rule for this task): fontconv.ps1 builds the
    # full 2048-byte sd\FONT.CHR fresh each run from the .ch8 source
    # plus authoring-kit\lib\default.chr.
    # Same CSpect lock hazard as -Rab/-UU/-Title: refuse to stage rather
    # than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial font fixture)"
    }
    Remove-Item "$root\sd\FONT.CHR" -Force -ErrorAction SilentlyContinue
    $fontSrc = "$root\tools\demo-files\fonts\Crews\Spectrum\Crews.ch8"
    & "$root\authoring-kit\lib\fontconv.ps1" -In $fontSrc -Out "$root\sd\FONT.CHR" | Out-Null
    $fontSize = (Get-Item "$root\sd\FONT.CHR").Length
    "staged tools\demo-files\fonts\Crews\Spectrum\Crews.ch8 -> sd\FONT.CHR ($fontSize bytes, via fontconv.ps1)"

    # SP12 Task 3 owner leg fixture: pointer_load (overlay0.asm) probes
    # sd\POINTER.SPR at boot (and PARTn\POINTER.SPR for parts >= 2), so
    # the owner-eye-leg needs one staged alongside the font fixture just
    # above - same switch, no separate -Pointer flag. No binary is
    # committed (same policy as the font fixture): the 256 bytes are
    # generated right here, a 16x16 solid square with a 2px $E3
    # (hardware transparent) border, a 1px $00 (black) outline, and a
    # $1C (pure green, RGB332) fill - a shape and colour obviously
    # different from mousePattern's own compiled-in black/white diagonal
    # arrow (overlay0.asm) at a glance.
    Remove-Item "$root\sd\POINTER.SPR" -Force -ErrorAction SilentlyContinue
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
    [System.IO.File]::WriteAllBytes("$root\sd\POINTER.SPR", $ptr)
    "staged a generated 16x16 green square (2px `$E3 border, `$00 outline) -> sd\POINTER.SPR (256 bytes)"
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
$vidLegSettlementTag = 'pal9k'

if ($Vid) {
    # SP15 T1 NXV v2 LEG SET fixtures (SP15 3a calibration wave,
    # 2026-07-25) - see the -Vid switch's own header comment above for
    # the full shape/source/start/duration mapping and the pre-3a
    # long-clip cache retirement note. Same CSpect-lock hazard as
    # -Rab/-UU/-Title/-Font: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial video fixture)"
    }
    # SP15 T5 review fix: scope the stale-clean to the files THIS switch
    # owns (001-006) - a bare sd\*.VID wipe also deleted -VidLong's
    # 007-011.VID/099.VID, breaking a combined -Vid + -VidLong stage
    # (card section 40.5 needs 001-011+099 staged together).
    Remove-Item "$root\sd\00[1-6].VID" -Force -ErrorAction SilentlyContinue
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
            "WARNING: $src missing - sd\$dest not generated"
            continue
        }
        $shapeTag = $shape -replace ':', ''
        $cache = Join-Path $vidOutDir "$([IO.Path]::GetFileNameWithoutExtension($dest))_${shapeTag}_${vidLegSettlementTag}_leg_cache.vid"
        if (-not (Test-Path -LiteralPath $cache)) {
            "encoding sd\$dest (shape $shape, source $(Split-Path -Leaf $src), start $start dur $duration) via videnc.py - slow, cached at tests\out\$(Split-Path -Leaf $cache) after this run..."
            # canonical encoder lives in the kit (see -Vid header); repo
            # tools ffmpeg passed explicitly - the kit default resolves
            # to authoring-kit\tools\ffmpeg, absent on a fresh clone
            & python "$root\authoring-kit\lib\videnc.py" $src $cache --shape $shape --fps 25 --start $start --duration $duration --ffmpeg "$root\tools\ffmpeg\bin\ffmpeg.exe"
            if ($LASTEXITCODE -ne 0) { throw "videnc.py failed (exit $LASTEXITCODE) - sd\$dest not staged" }
        }
        if (Test-Path -LiteralPath $cache) {
            Copy-Item -LiteralPath $cache -Destination "$root\sd\$dest" -Force
            $vidStaged++
        }
    }
    "staged $vidStaged video fixture(s) -> sd\001.VID..sd\006.VID (NXV v2 leg set: full/classic/16:9/scope/classic-wide/16:9-card, sp14a-task-4-report.md section 37)"
}

if ($VidLong) {
    # SP15 3b STREAMING leg fixtures - full-duration research-clip
    # encodes bigger than the pool ring (see the -VidLong header
    # comment). Cached like -Vid; does not touch sd\001-006.VID.
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
            "WARNING: $src missing - sd\$dest not generated"
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
            "encoding sd\$dest (shape $shape, source $(Split-Path -Leaf $src), $(if ($cut) { "cut $($vidLongMap[$dest].start) dur $($vidLongMap[$dest].duration)" } else { 'FULL duration' })) via videnc.py - slow, cached at tests\out\$(Split-Path -Leaf $cache) after this run..."
            & python "$root\authoring-kit\lib\videnc.py" $src $cache --shape $shape --fps 25 --ffmpeg "$root\tools\ffmpeg\bin\ffmpeg.exe" @($vidLongMap[$dest].extraArgs) @cut
            if ($LASTEXITCODE -ne 0) { throw "videnc.py failed (exit $LASTEXITCODE) - sd\$dest not staged" }
        }
        if (Test-Path -LiteralPath $cache) {
            Copy-Item -LiteralPath $cache -Destination "$root\sd\$dest" -Force
            $vidLongStaged++
        }
    }
    # 099.VID = a byte-copy of 007. (3c: the DEBUG deliberate-underrun
    # THROTTLE for video 99 is RETIRED - VSTRU is a plain streamed
    # regression leg now; the drill's verdict is on record in Cards
    # #3/#4 and git holds the lever.)
    if (Test-Path -LiteralPath "$root\sd\007.VID") {
        Copy-Item -LiteralPath "$root\sd\007.VID" -Destination "$root\sd\099.VID" -Force
        $vidLongStaged++
    }
    "staged $vidLongStaged long fixture(s) -> sd\007-011.VID + sd\099.VID (SP15 3b/3c streaming + direct leg set: VSTR0/VSTR1/VSTR2/VSTRU/VDIR/DPACE, sp14a-task-4-report.md sections 38/39)"
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
    Remove-Item "$root\sd\NXB*.BIN" -Force -ErrorAction SilentlyContinue
    $nxbStaged = 0
    Get-ChildItem "$nxbDir\NXB*.BIN" | ForEach-Object {
        Copy-Item $_.FullName "$root\sd\$($_.Name)" -Force
        $nxbStaged++
    }
    "staged $nxbStaged bench payload(s) -> sd\NXB0.BIN..sd\NXB9.BIN (manifest: tests\out\nxbench\nxbench-manifest.txt)"
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
    # holds sd\ files open and the cleanup/copies fail piecemeal.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause partial audio sets)"
    }
    # Stale-audio cleanup first so a previous staging run cannot leak
    # a song the current asset set no longer provides.
    Remove-Item "$root\sd\*.AKY" -Force -ErrorAction SilentlyContinue
    Remove-Item "$root\sd\GAME.SFB" -Force -ErrorAction SilentlyContinue
    Remove-Item "$root\sd\*.WAV" -Force -ErrorAction SilentlyContinue
    Remove-Item "$root\sd\*.AYS" -Force -ErrorAction SilentlyContinue
    $audSrc = "$root\tools\audio_assets"
    $audFiles = @()
    if (Test-Path $audSrc) {
        $audFiles = @(Get-ChildItem "$audSrc\*.AKY", "$audSrc\GAME.SFB", "$audSrc\*.WAV", "$audSrc\*.AYS" -ErrorAction SilentlyContinue)
    }
    if ($audFiles.Count -eq 0) {
        "WARNING: -Aud given but $audSrc has no assets (run the audio export script first) - skipped"
    }
    else {
        $audFiles | ForEach-Object { Copy-Item $_.FullName "$root\sd\$($_.Name)" -Force }
        "staged $($audFiles.Count) audio asset(s) -> sd\ ($(($audFiles | ForEach-Object Name) -join ', '))"
    }
}

$good = [System.IO.File]::ReadAllBytes("$root\sd\GAME.DDB")

"size=$($good.Length) (hex $('{0:X4}' -f $good.Length))"
"version=$($good[0]) target=$('{0:X2}' -f $good[1]) magic=$($good[2])"
$ptrs = for ($i = 8; $i -lt 34; $i += 2) { '{0:X4}' -f ($good[$i] + 256 * $good[$i+1]) }
"pointers: $($ptrs -join ' ')"
if ($partActive) { "active: part 1 of 2 (NDPARTA/NDPARTB fixture pair - sd\GAME2.DDB + sd\PART2\0.XMB also staged)" }
elseif ($uuActive) { "active: urbanupstart" }
elseif ($UU) { "active: urbanupstart (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }
if ($partActive) {
    # Confirm the four files this switch is responsible for, not the
    # whole (possibly art-laden, from an earlier -Rab/-UU run) sd\ tree.
    $part2Entries = Get-ChildItem "$root\sd\PART2" -Force | ForEach-Object { $_.Name } | Sort-Object
    "sd\PART2\ contents: $($part2Entries -join ', ')"
}
