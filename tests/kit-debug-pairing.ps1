# The kit's NEXTDAAD.SYM must pair with the kit's nextdaad.nex: every hook line's
# check bytes must equal the NEX bytes at that address/page, and the SYM must be
# a Release build. Bank layout as scripts/make-sym.ps1.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit = Join-Path $root 'authoring-kit'
$symPath = Join-Path $kit 'NEXTDAAD.SYM'
$nexPath = Join-Path $kit 'nextdaad.nex'
$mismatch = 'NEXTDAAD.SYM does not match nextdaad.nex - rebuild the kit with build.ps1 -Kit'
function Fail([string]$m) { throw "kit-debug-pairing: $m" }

if (-not (Test-Path -LiteralPath $symPath)) { Fail "no $symPath - $mismatch" }
if (-not (Test-Path -LiteralPath $nexPath)) { Fail "no $nexPath" }
$lines = [IO.File]::ReadAllText($symPath) -split "`n" | Where-Object { $_ -ne '' }
if ($lines[0] -ne "NEXTDAAD-SYM`t1") { Fail "bad SYM header '$($lines[0])'" }
$build = $lines | Where-Object { $_.StartsWith("build`t") } | Select-Object -First 1
if (-not $build) { Fail 'SYM has no build line' }
$variant = ($build -split "`t")[2]
if ($variant -ne 'Release') { Fail "SYM build variant is '$variant', the kit must ship Release - rebuild the kit with build.ps1 -Kit" }

$nex = [IO.File]::ReadAllBytes($nexPath)
if ([Text.Encoding]::ASCII.GetString($nex, 0, 4) -ne 'Next') { Fail 'nextdaad.nex is not a NEX file' }
$bankOff = @{}; $pos = 512
foreach ($b in @(5, 2, 0, 1, 3, 4) + (6..111)) { if ($nex[18 + $b]) { $bankOff[$b] = $pos; $pos += 16384 } }

$hooks = 0
foreach ($l in $lines) {
    $f = $l -split "`t"
    if ($f[0] -ne 'hook') { continue }
    $hooks++
    $addr = [Convert]::ToInt32($f[2], 16); $page = [Convert]::ToInt32($f[3], 16)
    $want = $f[4].ToUpperInvariant()
    $bank = $page -shr 1
    if (-not $bankOff.ContainsKey($bank)) { Fail "hook $($f[1]): bank $bank not in the NEX - $mismatch" }
    $start = $bankOff[$bank] + ($page -band 1) * 8192 + ($addr -band 0x1FFF)
    $n = $want.Length / 2
    $got = -join ($nex[$start..($start + $n - 1)] | ForEach-Object { '{0:X2}' -f $_ })
    if ($got -ne $want) { Fail "hook $($f[1]) bytes differ: $mismatch" }
}
if ($hooks -eq 0) { Fail 'SYM has no hook lines' }
Write-Output "kit-debug-pairing: $hooks hooks paired, Release"
