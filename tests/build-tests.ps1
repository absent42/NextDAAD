# Compiles tests\test.dsf (template), tests\condacts.dsf (suite) and
# tests\doallnest.dsf (DOALL depth/error demo) with DRC (version 2
# DDB), generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active sd\GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process); -Rab compiles tools\Rabenstein-
# master\rabenstein.dsf (the real commercial-quality DAAD game, the
# SP4 milestone) and makes that DDB active instead. The switches are
# mutually exclusive - if more than one is given, whichever copy runs
# last in this script wins: -Suite copies first, -Err4 copies over
# it, and -Rab copies last of all, since its block comes after -Err4's.
# The template is active if no switch is given.
param([switch]$Suite, [switch]$Err4, [switch]$Rab)
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

if ($Suite) {
    Copy-Item "$root\tests\out\condacts.ddb" "$root\sd\GAME.DDB" -Force
}
if ($Err4) {
    Copy-Item "$root\tests\out\doallnest.ddb" "$root\sd\GAME.DDB" -Force
}

$rabActive = $false
if ($Rab) {
    Copy-Item "$root\tools\Rabenstein-master\rabenstein.dsf" "$dr\NDRAB.DSF" -Force
    Copy-Item "$root\tools\Rabenstein-master\MLV_NEXT.BIN" "$dr\MLV_NEXT.BIN" -Force
    Push-Location $dr
    try {
        # Deviation: Rabenstein's DSF was built against an older DRC that still
        # treated XPICTURE/XSAVE/XLOAD/XNEXTCLS/XNEXTRST/XNEXTSPEED as live
        # condacts. The DRC bundled here (TOOLS\DRC) deprecates all of them -
        # DRB.PHP hard-errors (exit 2) on the first one it meets, and DRF
        # doesn't even recognise XNEXTSPEED as a token. Patch the local copy
        # only (never tools\Rabenstein-master\rabenstein.dsf) to the modern
        # equivalents before compiling. Mapping (see task-5-report.md):
        #   XNEXTSPEED 2        -> removed (cosmetic Maluva print-speed tweak,
        #                          no standard-condact equivalent)
        #   XNEXTCLS + XNEXTRST -> EXIT 0 (the two "next"-only termination
        #                          sites; matches the EXIT 0 the non-"next"
        #                          branches already use at the same spots)
        #   XNEXTCLS (solo)     -> CLS (screen-clear-only site)
        #   XSAVE 0 / XLOAD 0   -> SAVE 0 / LOAD 0 (DRF's own error message
        #                          names these as the direct replacements)
        #   XPICTURE n          -> PICTURE n / DISPLAY 0 (documented MALUVA
        #                          expansion)
        $content = [System.IO.File]::ReadAllText("$dr\NDRAB.DSF")

        $speedBlock = "#ifdef ""next""`r`n>`r`n_       _       AT 0`r`n                XNEXTSPEED 2`r`n#endif`r`n"
        if ($content -notmatch [regex]::Escape($speedBlock)) { throw "Rabenstein patch: XNEXTSPEED block not found - source may have changed" }
        $content = $content.Replace($speedBlock, "")

        $pair1 = "XNEXTCLS`r`nXNEXTRST  ; Next cleanup and machine reset`r`n"
        $pair2 = "                XNEXTCLS`r`n                XNEXTRST          ; Next cleanup and machine reset`r`n"
        if ($content -notmatch [regex]::Escape($pair1)) { throw "Rabenstein patch: XNEXTCLS/XNEXTRST pair 1 not found" }
        if ($content -notmatch [regex]::Escape($pair2)) { throw "Rabenstein patch: XNEXTCLS/XNEXTRST pair 2 not found" }
        $content = $content.Replace($pair1, "EXIT 0`r`n")
        $content = $content.Replace($pair2, "                EXIT 0`r`n")

        if (([regex]::Matches($content, 'XNEXTCLS')).Count -ne 1) { throw "Rabenstein patch: expected exactly one standalone XNEXTCLS left" }
        $content = $content -replace 'XNEXTCLS', 'CLS'

        $content = $content -replace 'XSAVE 0', 'SAVE 0'
        $content = $content -replace 'XLOAD 0', 'LOAD 0'
        $content = [regex]::Replace($content, '(?m)^(.*?)XPICTURE[ \t]+(\S+)([ \t]*(?:;.*)?)\r$', "`$1PICTURE `$2`$3`r`n                DISPLAY 0`r")

        [System.IO.File]::WriteAllText("$dr\NDRAB.DSF", $content)

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
        Remove-Item "$dr\NDRAB.DSF", "$dr\NDRAB.json", "$dr\NDRAB.___", "$dr\MLV_NEXT.BIN" -ErrorAction SilentlyContinue
        Pop-Location
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
