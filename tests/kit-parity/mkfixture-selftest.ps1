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
function PngHeight($p) { $b = [IO.File]::ReadAllBytes($p); return ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23] }
Assert-True (PngWidth "$out/IMAGES/DAAD.png" -eq 320) 'DAAD.png is 320 wide'
Assert-True (PngWidth "$out/IMAGES/001.png" -eq 320) '001.png is 320 wide'
Assert-True (PngHeight "$out/IMAGES/001.png" -eq 106) '001.png is 106 high (text window from row 14)'
Assert-True ((PngWidth "$out/INTRO/INTRO.png" -eq 320) -and (PngHeight "$out/INTRO/INTRO.png" -eq 256)) 'INTRO.png is a 320x256 slide'
Assert-True (PngWidth "$out/IMAGES/002.png" -eq 256) '002.png is 256 wide'
Assert-True (PngWidth "$out/IMAGES/POINTER.png" -eq 16) 'POINTER.png is 16 wide'
Assert-True ((Get-ChildItem "$out/IMAGES/SPRITES" -Filter *.png).Count -ge 1) 'sprite sheets present'
Assert-True ((Get-Item "$out/AUDIO/001.wav").Length -eq 15669) '001.wav is 44 + 15625 bytes'
Assert-True ((Get-Item "$out/FONT.psf").Length -eq 2052) 'FONT.psf is 4 + 2048 bytes'
$psf = [IO.File]::ReadAllBytes("$out/FONT.psf"); $chr = [IO.File]::ReadAllBytes((Join-Path $root 'src/font.chr'))
Assert-True ((Get-Content "$out/FONT1.bdf" -TotalCount 1) -eq 'STARTFONT 2.1') 'FONT1.bdf header'
# Every printable glyph (33-126) must differ between the base font, FONT.psf and
# FONT1.bdf: a converter that ignored or swapped its sources then fails parity.
# '_' (95) is exempt: its bold and underlined forms are both a solid row 7.
$bdf = @{}; $code = -1; $rows = $null
foreach ($l in Get-Content "$out/FONT1.bdf") {
    if ($l -match '^ENCODING (\d+)') { $code = [int]$Matches[1] }
    elseif ($l -eq 'BITMAP') { $rows = @() }
    elseif ($l -eq 'ENDCHAR') { $bdf[$code] = ($rows -join ','); $rows = $null }
    elseif ($null -ne $rows) { $rows += [Convert]::ToInt32($l, 16) }
}
$same = @()
for ($c = 33; $c -le 126; $c++) {
    if ($c -eq 95) { continue }
    $base = ($chr[($c * 8)..($c * 8 + 7)] -join ','); $bold = ($psf[(4 + $c * 8)..(4 + $c * 8 + 7)] -join ',')
    if ($bold -eq $base -or $bdf[$c] -eq $base -or $bdf[$c] -eq $bold) { $same += $c }
}
Assert-True ($same.Count -eq 0) "FONT.psf, FONT1.bdf and src/font.chr differ on every glyph 33-126 (same: $($same -join ' '))"
Assert-True ((($psf[(4 + 256)..(4 + 263)]) -join ',') -eq '0,0,0,0,0,0,0,0' -and $bdf[32] -eq '0,0,0,0,0,0,0,0') 'glyph 32 blank in both'
Assert-True ((Get-Item "$out/VIDEO/001.mp4").Length -gt 1000) '001.mp4 written'
Assert-True (-not (Test-Path "$out/_frames")) 'frame scratch removed'
Write-Output "mkfixture-selftest: $checks checks passed"
