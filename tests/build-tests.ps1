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
# Video benchmark fixtures (SP13 Task 1), independent of the DDB
# switches:
#   -Vid     stage the owner's MakeVid demo matrix into sd\001.VID..
#            sd\006.VID, one file per format, named in vid_classify's
#            priority order (video.asm: 0=320x240 palette .. 5=256x192
#            no-palette). VIDBENCH (DEBUG builds only, tests/test.dsf)
#            always benches sd\001.VID - the highest data-rate format
#            (79360 B/frame @ 16.7fps), the conservative gate number.
#            Stale-cleans sd\*.VID first. Source -> dest mapping (tools\
#            demo-files\001_<WxH><auto|autopal>[c10g10s10].vid):
#              001.VID <- 001_320x240autopal[c10g10s10].vid (fmt 0, 155 sect/frame)
#              002.VID <- 001_320x240auto[c10g10s10].vid     (fmt 1, 154 sect/frame)
#              003.VID <- 001_256x240autopal[c10g10s10].vid (fmt 2, 129 sect/frame)
#              004.VID <- 001_256x240auto[c10g10s10].vid     (fmt 3, 128 sect/frame)
#              005.VID <- 001_256x192autopal[c10g10s10].vid (fmt 4, 99 sect/frame)
#              006.VID <- 001_256x192auto[c10g10s10].vid     (fmt 5, 98 sect/frame)
#            NOTE (re-derived against the owner's 2026-07-20 REGENERATED
#            tools\demo-files bytes with the fixed vid_classify
#            arithmetic - sector count = size/512, first exact divisor
#            in priority order 155,154,129,128,99,98 wins, else CF).
#            What the fixed classifier reports for these six fixtures:
#              001.VID size 39838720  77810 sect  -> 0 (155)  [intended 0, correct]
#              002.VID size 39581696  77308 sect  -> 1 (154)  [intended 1, correct]
#              003.VID size 33156096  64758 sect  -> 2 (129)  [intended 2, correct]
#              004.VID size 32899072  64256 sect  -> 3 (128)  [intended 3, correct]
#              005.VID size 38066688  74349 sect  -> 4 (99)   [intended 4, correct]
#              006.VID size 37682176  73598 sect  -> 5 (98)   [intended 5, correct]
#            005/006 carry 2 trailing sectors beyond a whole number of
#            frames in the SOURCE tools\demo-files fixtures (99x751+2 and
#            98x751+2 - consistent MakeVid output for the 256x192 formats,
#            seen in both the pre-incident and regenerated encodes).
#            playvid's own size-only classifier has the same limitation
#            (its README offers -4/-5 to force the format). SP13 Task 2:
#            the STAGED COPIES of 005.VID/006.VID (never the tools\ source
#            - read-only) are now TRUNCATED to their last whole-frame
#            boundary (fmt4 frame = 99*512=50688 B, fmt5 = 98*512=50176 B)
#            immediately after copying, dropping only the 2-sector tail
#            padding, never a whole frame - both now classify clean, and
#            the T2 player's owner leg (GFX n 13/14, SFX n 9/10) needs
#            classification-clean fixtures to reach the run loop at all.
#            Same CSpect-running guard as -Rab/-UU/-Title/-Font.
#            sd\*.VID is gitignored (owner edit).
param([switch]$Suite, [switch]$Err4, [switch]$Rab, [switch]$UU, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud, [switch]$Title, [switch]$Part, [switch]$Font, [switch]$Vid)
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

if ($Vid) {
    # SP13 Task 1 owner leg fixture - see the -Vid switch's own header
    # comment above for the full source->dest mapping and the 005/006
    # classification-quirk note. Same CSpect-lock hazard as -Rab/-UU/
    # -Title/-Font: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial video fixture)"
    }
    Remove-Item "$root\sd\*.VID" -Force -ErrorAction SilentlyContinue
    $vidSrc = "$root\tools\demo-files"
    $vidMap = [ordered]@{
        '001.VID' = '001_320x240autopal[c10g10s10].vid'
        '002.VID' = '001_320x240auto[c10g10s10].vid'
        '003.VID' = '001_256x240autopal[c10g10s10].vid'
        '004.VID' = '001_256x240auto[c10g10s10].vid'
        '005.VID' = '001_256x192autopal[c10g10s10].vid'
        '006.VID' = '001_256x192auto[c10g10s10].vid'
    }
    # -LiteralPath throughout: the source names' [c10g10s10] suffix is
    # otherwise parsed as a PowerShell wildcard character class (Test-
    # Path/Copy-Item's default -Path behaviour), not matched literally.
    $vidStaged = 0
    foreach ($dest in $vidMap.Keys) {
        $src = Join-Path $vidSrc $vidMap[$dest]
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination "$root\sd\$dest" -Force
            $vidStaged++
        }
        else {
            "WARNING: $src missing - sd\$dest not staged"
        }
    }
    # SP13 Task 2: truncate the STAGED COPIES of 005.VID/006.VID (256x192
    # formats) to their last whole-frame boundary - the source fixtures
    # carry a 2-sector MakeVid tail beyond a whole number of frames (see
    # the -Vid header comment above), which leaves 005 unclassifiable and
    # 006 colliding with an earlier format's divisor. Truncating drops
    # only the tail padding, never a whole frame. tools\demo-files itself
    # is never modified (read-only per project rules) - this rewrites
    # only the sd\ copy just staged above.
    $vidFrameBytes = [ordered]@{ '005.VID' = 50688; '006.VID' = 50176 }   # fmt4 99*512, fmt5 98*512
    foreach ($dest in $vidFrameBytes.Keys) {
        $path = "$root\sd\$dest"
        if (Test-Path -LiteralPath $path) {
            $frameBytes = $vidFrameBytes[$dest]
            $size = (Get-Item -LiteralPath $path).Length
            $truncated = [math]::Floor($size / $frameBytes) * $frameBytes
            if ($truncated -lt $size) {
                $stream = [System.IO.File]::Open($path, 'Open', 'Write')
                $stream.SetLength($truncated)
                $stream.Close()
                "truncated sd\$dest $size -> $truncated bytes (whole-frame boundary, $($size - $truncated) tail bytes dropped)"
            }
        }
    }
    "staged $vidStaged video fixture(s) -> sd\001.VID..sd\006.VID (tools\demo-files MakeVid matrix, classification-priority order)"
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
