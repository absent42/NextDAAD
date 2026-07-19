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
# -Err4 copies over it, -Rab copies over that, and -UU copies last of
# all, since its block comes after -Rab's. The template is active if no
# switch is given.
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
#   -Title   stage a DAAD.NXI title-screen fixture into sd\ - copies
#            tools\Rabenstein-master\nextdaad\0.NXI (the same corpus
#            -Rab -Gfx256 stages; every numbered NXI there is 25088
#            bytes, so "smallest" is a tie broken by lowest number) to
#            sd\DAAD.NXI. Not committed (sd/*.NXI is gitignored).
#            Default (no -Title) leaves sd\ untouched.
param([switch]$Suite, [switch]$Err4, [switch]$Rab, [switch]$UU, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud, [switch]$Title)
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

if ($Title) {
    # SP11 Task 1 owner leg fixture: title_present/title_boot (overlay2.asm)
    # probe sd\DAAD.* at boot, so the owner-eye-leg needs one staged.
    # Sourced from the same corpus -Rab -Gfx256 stages
    # (tools\Rabenstein-master\nextdaad\*.NXI) rather than a committed
    # binary - every numbered NXI there is 25088 bytes (21 files, all
    # identical size), so "the smallest" is a tie; 0.NXI is the
    # deterministic pick (lowest number). Same CSpect lock hazard as
    # -Rab/-UU: refuse to stage rather than warn.
    if (Get-Process CSpect -ErrorAction SilentlyContinue) {
        throw "CSpect is running - close it before staging (locked sd\ files cause a partial title fixture)"
    }
    Copy-Item "$root\tools\Rabenstein-master\nextdaad\0.NXI" "$root\sd\DAAD.NXI" -Force
    "staged tools\Rabenstein-master\nextdaad\0.NXI -> sd\DAAD.NXI"
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
if ($uuActive) { "active: urbanupstart" }
elseif ($UU) { "active: urbanupstart (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }
