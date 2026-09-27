# Pins lib\kittools.ps1 against the rules lib\tools.bat implemented.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$lib = "$root/authoring-kit/lib"
. "$lib/kitplatform.ps1"
. "$lib/kitconfig.ps1"
. "$lib/kittools.ps1"
$checks = 0
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kittools-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-PathEq($actual, $expected, $what) {
    $script:checks++
    $a = [IO.Path]::GetFullPath($actual)
    $e = [IO.Path]::GetFullPath($expected)
    if ($a -ne $e) { throw "kittools-selftest: $what - got '$actual' ($a), expected '$expected' ($e)" }
}
$kit = "$root/tests/out/kittools/kit"
if (Test-Path $kit) { Remove-Item $kit -Recurse -Force }
foreach ($d in 'lib', 'tools/ArkosTracker3/tools', 'tools/ffmpeg/bin', 'tools/sjasmplus/sjasmplus-1.23.1', 'alt/ff') {
    New-Item -ItemType Directory -Force "$kit/$d" | Out-Null
}
Copy-Item "$lib/toolversions.txt" "$kit/lib\"
$x = $ExeSuffix
foreach ($f in "tools/ArkosTracker3/tools/SongToAky$x", "tools/ffmpeg/bin/ffmpeg$x", "tools/sjasmplus/sjasmplus-1.23.1/sjasmplus$x", "alt/ff/ffmpeg$x") {
    [IO.File]::WriteAllBytes("$kit/$f", [byte[]]@(0))
}
Push-Location $kit
try {
    $t = Resolve-KitTools @{} $kit
    Assert-Eq $t.TOOLSDIR 'tools' 'TOOLSDIR default'
    Assert-Eq $t.GFXDIR (Join-Path 'tools' 'gfx2next') 'GFXDIR default under TOOLSDIR'
    Assert-Eq $t.GFX (Join-Path (Join-Path 'tools' 'gfx2next') "gfx2next$x") 'GFX'
    Assert-PathEq $t.NDRC (Join-Path $lib "ndrc$x") 'NDRC is lib\ndrc beside kittools.ps1'
    Assert-Eq $t.NDRCVER '0.2.2' 'NDRCVER from toolversions.txt'
    Assert-Eq $t.ARKOSBIN (Join-Path (Join-Path 'tools' 'ArkosTracker3') 'tools') 'Arkos tools\ subfolder probed'
    Assert-Eq $t.S2A (Join-Path $t.ARKOSBIN "SongToAky$x") 'S2A'
    Assert-Eq $t.FFMPEGBIN (Join-Path (Join-Path 'tools' 'ffmpeg') 'bin') 'ffmpeg bin\ probed'
    Assert-Eq $t.SJASMPLUSBIN (Join-Path (Join-Path 'tools' 'sjasmplus') 'sjasmplus-1.23.1') 'nested sjasmplus folder'
    Assert-Eq $t.INTRONEX 'intro.nex' 'INTRONEX default'
    Assert-Eq $t.NEXFILE '' 'NEXFILE comes from CONFIG, no default here'
    Assert-Eq $env:FFMPEG $t.FFMPEG 'FFMPEG exported'
    Assert-Eq $env:VIDENC $t.VIDENC 'VIDENC exported'
    $t2 = Resolve-KitTools @{ FFMPEGDIR = 'alt\ff'; NDRCVER = '9.9.9'; NDRC = 'my\ndrc'; TOOLSDIR = 'elsewhere' } $kit
    Assert-Eq $t2.FFMPEG (Join-Path 'alt\ff' "ffmpeg$x") 'FFMPEGDIR override, root shape'
    Assert-Eq $t2.NDRCVER '9.9.9' 'NDRCVER override from CONFIG'
    Assert-Eq $t2.NDRC 'my\ndrc' 'NDRC override from CONFIG'
    Assert-Eq $t2.GFXDIR (Join-Path 'elsewhere' 'gfx2next') 'relocated TOOLSDIR carries the defaults'
} finally { Pop-Location }
# Relative TOOLSDIR resolves against the kit root even from elsewhere (Review Focus 4).
Push-Location $root
try {
    $t3 = Resolve-KitTools @{ TOOLSDIR = 'tools' } $kit
    Assert-Eq (Test-Path -LiteralPath (Join-Path $kit $t3.S2A)) $true 'relative S2A is kit-root relative'
} finally { Pop-Location }
# tools.bat:70's for /d has no early exit, so it keeps the LAST matching
# subfolder in name order. Two versioned folders pin that against a first-match bug.
$sjkit = "$root/tests/out/kittools/sjasm-multi"
if (Test-Path $sjkit) { Remove-Item $sjkit -Recurse -Force }
foreach ($d in 'tools/sjasmplus/sjasmplus-1.23.1', 'tools/sjasmplus/sjasmplus-1.24.0') {
    New-Item -ItemType Directory -Force "$sjkit/$d" | Out-Null
    [IO.File]::WriteAllBytes("$sjkit/$d/sjasmplus$x", [byte[]]@(0))
}
Push-Location $sjkit
try {
    $t4 = Resolve-KitTools @{} $sjkit
    Assert-Eq $t4.SJASMPLUSBIN (Join-Path (Join-Path 'tools' 'sjasmplus') 'sjasmplus-1.24.0') 'nested sjasmplus folder picks the LAST name, not the first'
} finally { Pop-Location }
$real = "$root/authoring-kit/lib/ndrc$x"
if (Test-Path $real) {
    $banner = Get-NdrcBanner $real
    Assert-Eq ($banner -like 'NDRC * --from-json') $true "banner shape ($banner)"
}
Write-Output "kittools-selftest: $checks checks passed"
