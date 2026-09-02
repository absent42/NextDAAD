# Assertions over authoring-kit\lib\anipack.ps1 and the gfx2next
# behaviours it relies on. Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\anipack-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$gfx  = "$root\tools\gfx2next\gfx2next.exe"
$pack = "$root\authoring-kit\lib\anipack.ps1"
$work = "$root\tests\out\anipack"
$checks = 0
if (-not (Test-Path $gfx)) { throw "anipack-selftest: gfx2next not found at $gfx" }

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "anipack-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    $threw = $false
    try { & $sb | Out-Null } catch { $threw = $true; if ($_.Exception.Message -notmatch $pattern) { throw "anipack-selftest: $what - wrong message: $($_.Exception.Message)" } }
    if (-not $threw) { throw "anipack-selftest: $what - did not fail" }
}
function Convert-Sheet([string]$png, [string[]]$extra) {
    # gfx2next writes <base>.spr into the CWD, exactly as lib\gfx.bat runs it.
    $base = [IO.Path]::GetFileNameWithoutExtension($png)
    Remove-Item "$work\$base.spr", "$work\$base.spr.zx0" -ErrorAction SilentlyContinue
    Push-Location $work
    try { & $gfx -sprites -pal-none @extra $png | Out-Null; $code = $LASTEXITCODE } finally { Pop-Location }
    return $code
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
& python "$root\tests\art\mkanisheets.py" $work
if ($LASTEXITCODE -ne 0) { throw "anipack-selftest: mkanisheets.py failed" }

# ---- Probe 1: raw index mode emits PLTE indices, cells row-major across the sheet.
Assert-Eq (Convert-Sheet "$work\001.png" @()) 0 'probe: gfx2next exit code'
$spr = [IO.File]::ReadAllBytes("$work\001.spr")
Assert-Eq $spr.Length 1536 'probe: six cells of 256 bytes'
for ($k = 0; $k -lt 6; $k++) {
    Assert-Eq $spr[$k * 256] ($k + 1) "probe: cell $k first byte is PLTE index $($k + 1) (row-major order)"
    Assert-Eq $spr[$k * 256 + 255] ($k + 1) "probe: cell $k last byte"
}
# ---- Probe 2: -zx0 names the output .spr.zx0 (the packer rejects that name).
Assert-Eq (Convert-Sheet "$work\001.png" @('-zx0')) 0 'probe: -zx0 exit code'
Assert-Eq (Test-Path "$work\001.spr.zx0") $true 'probe: -zx0 writes 001.spr.zx0'
Assert-Eq (Test-Path "$work\001.spr") $false 'probe: -zx0 leaves no plain .spr'
# ---- Probe 3: a sheet that is not a multiple of 16 drops the partial cells silently.
& python -c "import sys; sys.path.insert(0, r'$root\tests\art'); import mkanisheets as m; m.write_png(r'$work\odd.png', 24, 16, [m.MAGENTA] + [(0,0,0)]*255, m.fill(24, 16, 0))"
Assert-Eq (Convert-Sheet "$work\odd.png" @()) 0 'probe: 24-wide sheet exit code'
Assert-Eq ([IO.File]::ReadAllBytes("$work\odd.spr")).Length 256 'probe: 24-wide sheet yields one cell, the partial column is dropped'

"anipack-selftest: $checks checks passed"
