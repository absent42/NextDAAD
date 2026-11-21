# Stage the blitter silicon legs. Each leg is a complete folder; sd\LEGBLT.TXT indexes them.
#
#   sd\LEGBLT1\  Release, picture walk, 256x192 set
#   sd\LEGBLT2\  Release, picture walk, 320x256 set
#   sd\LEGBLT3\  DEBUG,   picture walk, 256x192 set (the fallback stream steps draw here only)
#   sd\LEGBLT4\  DEBUG,   picture walk, 320x256 set
#   sd\LEGBLT5\  Release, colour-cycle fixture (cycling and a sprite across draws and scrolls)
#
# The walk is tests\l2pos.dsf with three condacts added in front of step 1, so every step runs
# with a looped 20000 Hz sample on each effect channel and a looped AKY song:
#   SFX 1 12 (001.WAV, channel 1), SFX 2 14 (002.WAV, channel 2), SFX 1 7 (001.AKY).
#
#   pwsh -File tests\blit_legs.ps1
#
# Builds both variants (DEBUG is left as the current build), then writes the legs.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$sd = Join-Path $root 'sd'
$out = Join-Path $root 'tests\out'
$work = Join-Path $out 'blt-work'
$ndrc = if ($env:NEXTDAAD_NDRC) { $env:NEXTDAAD_NDRC } else { Join-Path $root 'authoring-kit\lib\ndrc.exe' }

if (Get-Process CSpect -ErrorAction SilentlyContinue) { throw 'CSpect is running - close it before staging' }

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    $o = & $cmd *>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE): $($o | Select-Object -Last 6 | Out-String)" }
    $o
}

# ---- builds
Push-Location $root
try {
    Invoke-Checked 'build.ps1 -Release' { & "$root\build.ps1" -Release } | Out-Null
    $nexRel = Join-Path $out 'blt-release.nex'
    Copy-Item "$root\build\nextdaad.nex" $nexRel -Force
    Invoke-Checked 'build.ps1' { & "$root\build.ps1" } | Out-Null
    $nexDbg = Join-Path $out 'blt-debug.nex'
    Copy-Item "$root\build\nextdaad.nex" $nexDbg -Force
}
finally { Pop-Location }

# ---- the walk with audio
New-Item -ItemType Directory -Force $work | Out-Null
$dsf = [IO.File]::ReadAllText("$PSScriptRoot\l2pos.dsf")
$anchor = '> _ _   MES "STEP 1 LOC1+TA "'
if (([regex]::Matches($dsf, [regex]::Escape($anchor))).Count -ne 1) { throw 'l2pos.dsf: step 1 entry not found exactly once' }
$dsf = $dsf.Replace($anchor, "> _ _   SFX 1 12`n        SFX 2 14`n        SFX 1 7`n        MES `"STEP 1 LOC1+TA `"")
[IO.File]::WriteAllText("$work\BLT.DSF", $dsf)
Push-Location $work
try { Invoke-Checked 'ndrc' { & $ndrc nextdaad EN BLT.DSF BLT.DDB -auto-tokens } | Out-Null }
finally { Pop-Location }
$ddb = [IO.File]::ReadAllBytes("$work\BLT.DDB")
# SFX is condact 18: the three audio condacts must sit contiguously in the DDB
$want = [byte[]]@(18, 1, 12, 18, 2, 14, 18, 1, 7)
$hit = $false
for ($i = 0; $i -le $ddb.Length - $want.Length -and -not $hit; $i++) {
    $j = 0
    while ($j -lt $want.Length -and $ddb[$i + $j] -eq $want[$j]) { $j++ }
    $hit = ($j -eq $want.Length)
}
if (-not $hit) { throw 'BLT.DDB does not contain SFX 1 12 / SFX 2 14 / SFX 1 7 as compiled bytes' }

# ---- audio
Invoke-Checked 'mktone.py' { & python "$PSScriptRoot\audio\mktone.py" $out } | Out-Null
$tone = Join-Path $out 'tone440_20k.wav'
$wb = [IO.File]::ReadAllBytes($tone)
if ([BitConverter]::ToUInt32($wb, 24) -ne 20000) { throw 'tone440_20k.wav is not 20000 Hz' }
$song = Join-Path $PSScriptRoot 'audio\L1.AKY'

# ---- legs
function New-Leg([string]$name, [string]$nex, [int]$mode) {
    $art = Join-Path $out "blt-art$mode"
    Invoke-Checked 'mkl2pos.py' { & python "$PSScriptRoot\art\mkl2pos.py" $art --mode $mode } | Out-Null
    $walk = Get-Content "$art\l2pos_walk.json" -Raw | ConvertFrom-Json
    $leg = Join-Path $sd $name
    New-Item -ItemType Directory -Force $leg | Out-Null
    Get-ChildItem $leg -File | Remove-Item -Force
    Copy-Item "$work\BLT.DDB" "$leg\GAME.DDB"
    Copy-Item $nex "$leg\NEXTDAAD.NEX"
    foreach ($f in @($walk.plain) + @($walk.nx3)) { Copy-Item "$art\$f" "$leg\$f" }
    Copy-Item $tone "$leg\001.WAV"
    Copy-Item $tone "$leg\002.WAV"
    Copy-Item $song "$leg\001.AKY"
    "{0}: {1} files" -f $name, @(Get-ChildItem $leg -File).Count
}
New-Leg 'LEGBLT1' $nexRel 0
New-Leg 'LEGBLT2' $nexRel 1
New-Leg 'LEGBLT3' $nexDbg 0
New-Leg 'LEGBLT4' $nexDbg 1

# ---- colour-cycle fixture on the Release build
Invoke-Checked 'build-tests.ps1 -Cycle' { & pwsh -NoProfile -File "$PSScriptRoot\build-tests.ps1" -Cycle } | Out-Null
$leg = Join-Path $sd 'LEGBLT5'
New-Item -ItemType Directory -Force $leg | Out-Null
Get-ChildItem $leg -File | Remove-Item -Force
Get-ChildItem (Join-Path $sd 'CYCLE') -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $leg $_.Name) }
Copy-Item $nexRel "$leg\NEXTDAAD.NEX" -Force
"LEGBLT5: {0} files" -f @(Get-ChildItem $leg -File).Count

@'
LEGBLT1  Release  picture walk, 256x192 set, samples and music playing
LEGBLT2  Release  picture walk, 320x256 set, samples and music playing
LEGBLT3  DEBUG    picture walk, 256x192 set: the fallback stream steps 10 and 10A draw here
LEGBLT4  DEBUG    picture walk, 320x256 set: the fallback stream steps 10 and 10A draw here
LEGBLT5  Release  colour-cycle fixture: cycling and a sprite across draws and scrolls
Copy each folder whole to the card and launch NEXTDAAD.NEX from inside it.
'@ | Set-Content (Join-Path $sd 'LEGBLT.TXT') -Encoding ascii
'staged: sd\LEGBLT1-5, index sd\LEGBLT.TXT'
