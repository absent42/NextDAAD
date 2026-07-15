# Compiles tests\test.dsf (template), tests\condacts.dsf (suite) and
# tests\doallnest.dsf (DOALL depth/error demo) with DRC (version 2
# DDB), generates corrupt/oversize variants from the template, prints
# a header report. -Suite makes the suite DDB the active sd\GAME.DDB;
# -Err4 makes the doallnest DDB active instead (deliberate error 4:
# nested DOALL on the same process). -Suite and -Err4 are mutually
# exclusive - if both are given, whichever is applied last (Err4)
# wins, since it copies over sd\GAME.DDB after -Suite's copy. The
# template is active if neither switch is given.
param([switch]$Suite, [switch]$Err4)
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

$good = [System.IO.File]::ReadAllBytes("$root\sd\GAME.DDB")

"size=$($good.Length) (hex $('{0:X4}' -f $good.Length))"
"version=$($good[0]) target=$('{0:X2}' -f $good[1]) magic=$($good[2])"
$ptrs = for ($i = 8; $i -lt 34; $i += 2) { '{0:X4}' -f ($good[$i] + 256 * $good[$i+1]) }
"pointers: $($ptrs -join ' ')"
if ($Err4) { "active: doallnest (E04 demo)" }
elseif ($Suite) { "active: suite" }
else { "active: template" }
