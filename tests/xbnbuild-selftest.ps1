# Assertions over authoring-kit\lib\xbnbuild.ps1 (EXTERNS.BAT's builder)
# and xbnmod.inc's claim macros. Run by tests\build-tests.ps1 and
# standalone:
#   pwsh -NoProfile -File tests\xbnbuild-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit  = "$root\authoring-kit"
$xb   = "$kit\lib\xbnbuild.ps1"
$sj   = "$root\tools\sjasmplus\sjasmplus.exe"
$fix  = "$root\tests\xbn\usermods"
$work = "$root\tests\out\xbnbuild"
$checks = 0
if (-not (Test-Path $sj)) { throw "xbnbuild-selftest: sjasmplus not found at $sj" }

# Collection claims end here (xbnmod.inc): XBN_SCRATCH_FREE = 768 +
# TRANSCRIPT_RING (2048), XBN_STATE_FREE = 10. Re-pin if either moves.
$scrBase = 2816
$stBase = 10

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "xbnbuild-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Match([string]$text, [string]$pattern, $what) {
    $script:checks++
    if ($text -notmatch $pattern) { throw "xbnbuild-selftest: $what - output did not match '$pattern':`n$text" }
}
# Native tools write to stderr; keep that from terminating under Stop.
# "$_" per record: Out-String wraps 5.1's stderr records at console width.
function Invoke-Native([scriptblock]$sb) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $sb 2>&1 | ForEach-Object { "$_" }) -join "`n") } finally { $ErrorActionPreference = $old }
}
function Header([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    [pscustomobject]@{
        Format = [int]$b[3]
        Line   = [int]$b[10] -bor ([int]$b[11] -shl 8)
        Out    = [int]$b[12] -bor ([int]$b[13] -shl 8)
    }
}
# Assembles one fixture on its own (its IFNDEF XBN_MODULE branch).
function Build-Standalone([string]$module) {
    $dir = "$work\standalone\$module"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try { $text = Invoke-Native { & $sj --msg=war -I "$kit" "$fix\$module\$module.asm" } }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "xbnbuild-selftest: standalone $module failed:`n$text" }
    $script:checks++
    [pscustomobject]@{ Text = $text; Header = (Header "$dir\GAME.XBN") }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

# Standalone: XBN_CLAIMS starts a module's claims where the collection's end.
$ua = Build-Standalone 'ua'
Assert-Match $ua.Text "standalone ua scratch \+$scrBase state \+$stBase" 'standalone ua claim offsets'
Assert-Eq $ua.Header.Format 3 'standalone ua header format'
Assert-Eq ($ua.Header.Line -ne 0) $true 'standalone ua lineEntry'
Assert-Eq $ua.Header.Out 0 'standalone ua outEntry'
$ub = Build-Standalone 'ub'
Assert-Eq $ub.Header.Format 2 'standalone ub header format'
$uo = Build-Standalone 'uo'
Assert-Eq $uo.Header.Format 3 'standalone uo header format'
Assert-Eq $uo.Header.Line 0 'standalone uo lineEntry'
Assert-Eq ($uo.Header.Out -ne 0) $true 'standalone uo outEntry'

Write-Output "xbnbuild-selftest: $checks checks passed"
