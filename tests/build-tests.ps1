# Compiles tests\test.dsf (template), tests\condacts.dsf (suite) and
# tests\doallnest.dsf (DOALL depth/error demo) with DRC (version 2
# DDB), generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active sd\GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process); -Rab compiles the modernised next-
# only tools\Rabenstein-master\nextdaad\rabenstein.dsf (the real
# commercial-quality DAAD game), makes that DDB active, and stages the
# Layer 2 art (default N.NX2 -> sd\NNN.NX2). The DDB switches are
# mutually exclusive - if more than one is given, whichever copy runs
# last in this script wins: -Suite copies first, -Err4 copies over
# it, and -Rab copies last of all, since its block comes after -Err4's.
# The template is active if no switch is given.
# Art-staging modifiers (effective only with -Rab, combinable):
#   -Gfx256  stage the 256-wide N.NXI set instead of the N.NX2s
#   -GfxZx0  ZX0-compress each staged file (sd\NNN.NX2.ZX0 / with
#            -Gfx256 sd\NNN.NXI.ZX0) so the interpreter's compressed
#            picture path is exercised
# Audio staging (combinable with any DDB switch):
#   -Aud     stage the test audio assets from tools\audio_assets\
#            (GAME.AKY, 001.AKY, GAME.SFB, 001.WAV - produced by the
#            export script) into sd\, after removing stale sd\*.AKY,
#            sd\GAME.SFB and sd\*.WAV; warns and skips if the folder
#            is empty
param([switch]$Suite, [switch]$Err4, [switch]$Rab, [switch]$Gfx256, [switch]$GfxZx0, [switch]$Aud)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dr = Join-Path $root 'tools\DAAD-READY'

Copy-Item "$PSScriptRoot\test.dsf" "$dr\NDTEST.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDTEST.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDTEST.json NDTEST.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed" }
    Move-Item NDTEST.DDB "$root\sd\GAME.DDB" -Force
}
finally {
    Remove-Item "$dr\NDTEST.DSF", "$dr\NDTEST.json" -ErrorAction SilentlyContinue
    Pop-Location
}

& "$PSScriptRoot\check-cprops.ps1"

New-Item -ItemType Directory -Force "$root\tests\out" | Out-Null

Copy-Item "$PSScriptRoot\condacts.dsf" "$dr\NDSUITE.DSF" -Force
Push-Location $dr
try {
    & .\TOOLS\DRC\DRF.exe zx next NDSUITE.DSF
    if ($LASTEXITCODE -ne 0) { throw "DRF failed (suite)" }
    & .\PHP\php.exe TOOLS\DRC\DRB.PHP zx next EN NDSUITE.json NDSUITE.DDB
    if ($LASTEXITCODE -ne 0) { throw "DRB failed (suite)" }
    Move-Item NDSUITE.DDB "$root\tests\out\condacts.ddb" -Force
}
finally {
    Remove-Item "$dr\NDSUITE.DSF", "$dr\NDSUITE.json" -ErrorAction SilentlyContinue
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

if ($Suite) {
    Copy-Item "$root\tests\out\condacts.ddb" "$root\sd\GAME.DDB" -Force
    Copy-Item "$root\tests\out\badwav.bin" "$root\sd\099.WAV" -Force
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
    $audSrc = "$root\tools\audio_assets"
    $audFiles = @()
    if (Test-Path $audSrc) {
        $audFiles = @(Get-ChildItem "$audSrc\*.AKY", "$audSrc\GAME.SFB", "$audSrc\*.WAV" -ErrorAction SilentlyContinue)
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
if ($rabActive) { "active: rabenstein" }
elseif ($Rab) { "active: rabenstein (sd\GAME.DDB copy failed, see warning above - stale DDB still active)" }
elseif ($Err4) { "active: doallnest (E04 demo)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }
