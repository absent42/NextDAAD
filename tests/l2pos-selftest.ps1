# Assertions over the NXP positioned-picture path of authoring-kit\lib\assets.ps1
# and palcheck.ps1. Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\l2pos-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'tests/testtools.ps1')
$gfx  = Get-RepoTool 'gfx2next'
$work = "$root/tests/out/l2pos"
$checks = 0
if (-not (Test-Path $gfx)) { throw "l2pos-selftest: gfx2next not found at $gfx" }
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "l2pos-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    $threw = $false
    try { & $sb | Out-Null } catch { $threw = $true; if ($_.Exception.Message -notmatch $pattern) { throw "l2pos-selftest: $what - wrong message: $($_.Exception.Message)" } }
    if (-not $threw) { throw "l2pos-selftest: $what - did not fail" }
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$work/kit/IMAGES", "$work/kit/RELEASE" | Out-Null

# ---- Part 1: pure functions, loaded out of assets.ps1 without running its stage switch
$src = Get-Content "$root/authoring-kit/lib/assets.ps1" -Raw
$fnText = [regex]::Match($src, '(?s)function Get-PngHeight.*?(?=\n# ---- pictures ----)').Value
if (-not $fnText) { throw 'l2pos-selftest: Get-PngHeight..New-NxpHeader block not found in assets.ps1' }
function Fail([string]$Message) { throw $Message }
Invoke-Expression $fnText

Set-Content "$work/a.txt" "at=8,16`npalette=128-255"
$p = Read-PosSidecar "$work/a.txt"
Assert-Eq $p.Float $false 'a: fixed'; Assert-Eq $p.X 8 'a: X'; Assert-Eq $p.Y 16 'a: Y'
Assert-Eq $p.PalFirst 128 'a: first'; Assert-Eq $p.PalLast 255 'a: last'; Assert-Eq $p.Mode $null 'a: mode unset'
Set-Content "$work/b.txt" "; comment`nat=window`npalette=none`nmode=320"
$p = Read-PosSidecar "$work/b.txt"
Assert-Eq $p.Float $true 'b: floating'; Assert-Eq $p.PalFirst 1 'b: none first'; Assert-Eq $p.PalLast 0 'b: none last'; Assert-Eq $p.Mode 320 'b: mode'
Set-Content "$work/c.txt" "palette=0-10"
Assert-Throws { Read-PosSidecar "$work/c.txt" } "'at' is required" 'c: missing at'
Set-Content "$work/d.txt" "at=8,16`npalette=300-10"
Assert-Throws { Read-PosSidecar "$work/d.txt" } 'palette' 'd: palette out of range'
Set-Content "$work/e.txt" "at=8;16"
Assert-Throws { Read-PosSidecar "$work/e.txt" } 'at=' 'e: bad at syntax'

$h = New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 64 32
Assert-Eq ([Text.Encoding]::ASCII.GetString($h, 0, 3)) 'NXP' 'hdr magic'
Assert-Eq $h[3] 1 'hdr version'; Assert-Eq $h[4] 0 'hdr mode'; Assert-Eq $h[5] 0 'hdr flags fixed'
Assert-Eq $h[6] 8 'hdr X lo'; Assert-Eq $h[7] 0 'hdr X hi'; Assert-Eq $h[8] 16 'hdr Y'
Assert-Eq $h[9] 64 'hdr W lo'; Assert-Eq $h[10] 0 'hdr W hi'; Assert-Eq $h[11] 32 'hdr H'
Assert-Eq $h[12] 128 'hdr pal first'; Assert-Eq $h[13] 255 'hdr pal last'; Assert-Eq $h[14] 0 'hdr rsv0'; Assert-Eq $h[15] 0 'hdr rsv1'
$h = New-NxpHeader (Read-PosSidecar "$work/b.txt") 1 320 256
Assert-Eq $h[5] 1 'hdr flags floating'; Assert-Eq $h[9] 64 'hdr W 320 lo'; Assert-Eq $h[10] 1 'hdr W 320 hi'; Assert-Eq $h[11] 0 'hdr H 256 -> 0'
Assert-Throws { New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 256 192 } 'does not fit' 'hdr: 8,16 + 256x192 off screen'
Assert-Throws { New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 64 200 } 'does not fit' 'hdr: 200 rows in 256 mode'

"l2pos-selftest: $checks checks passed"
