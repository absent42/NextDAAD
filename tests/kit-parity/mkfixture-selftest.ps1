# Runs mkfixture.py into tests\out and checks the files it promises exist
# with the headers the kit expects. Exit 2 when ffmpeg or Python is missing.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
$ffmpeg = Join-Path $root "authoring-kit/tools/ffmpeg/bin/ffmpeg$ExeSuffix"
if (-not (Test-Path -LiteralPath $ffmpeg)) { Write-Host "mkfixture-selftest: no ffmpeg at $ffmpeg"; exit 2 }
$pyc = Find-Python @('PIL', 'numpy')
if (-not $pyc) { Write-Host 'mkfixture-selftest: no python with PIL/numpy'; exit 2 }
$pyRest = @(); if ($pyc.Length -gt 1) { $pyRest = $pyc[1..($pyc.Length - 1)] }
$out = Join-Path $root 'tests/out/kit parity/fixture-gen'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null
& $pyc[0] @pyRest (Join-Path $PSScriptRoot 'mkfixture.py') $out --ffmpeg $ffmpeg
if ($LASTEXITCODE -ne 0) { throw 'mkfixture.py failed' }
$checks = 0
function Assert-True($cond, $what) { $script:checks++; if (-not $cond) { throw "mkfixture-selftest: $what" } }
function PngWidth($p) { $b = [IO.File]::ReadAllBytes($p); return ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19] }
Assert-True (PngWidth "$out/IMAGES/DAAD.png" -eq 320) 'DAAD.png is 320 wide'
Assert-True (PngWidth "$out/IMAGES/001.png" -eq 320) '001.png is 320 wide'
Assert-True (PngWidth "$out/IMAGES/002.png" -eq 256) '002.png is 256 wide'
Assert-True (PngWidth "$out/IMAGES/POINTER.png" -eq 16) 'POINTER.png is 16 wide'
Assert-True ((Get-ChildItem "$out/IMAGES/SPRITES" -Filter *.png).Count -ge 1) 'sprite sheets present'
Assert-True ((Get-Item "$out/AUDIO/001.wav").Length -eq 15669) '001.wav is 44 + 15625 bytes'
Assert-True ((Get-Item "$out/FONT.psf").Length -eq 2052) 'FONT.psf is 4 + 2048 bytes'
Assert-True ((Get-Content "$out/FONT1.bdf" -TotalCount 1) -eq 'STARTFONT 2.1') 'FONT1.bdf header'
Assert-True ((Get-Item "$out/VIDEO/001.mp4").Length -gt 1000) '001.mp4 written'
Assert-True (-not (Test-Path "$out/_frames")) 'frame scratch removed'
Write-Output "mkfixture-selftest: $checks checks passed"
