# The kit's NEXTDAAD.SYM must pair with the kit's nextdaad.nex: exactly the hooks the
# plugin needs (SymbolFile.RequiredHooks), each line's check bytes equal to the NEX bytes
# at that address/page, and both files Release: the SYM label says so and the NEX loads
# no BANK_NXB (the DEBUG-only bench bank). Bank layout as scripts/make-sym.ps1.
# Run by build.ps1 -Kit and the release workflow. -KitDir checks another folder's pair.
param([string]$KitDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit = if ($KitDir) { $KitDir } else { Join-Path $root 'authoring-kit' }
$symPath = Join-Path $kit 'NEXTDAAD.SYM'
$nexPath = Join-Path $kit 'nextdaad.nex'
$mismatch = 'NEXTDAAD.SYM does not match nextdaad.nex - rebuild the kit with build.ps1 -Kit'
function Fail([string]$m) { throw "kit-debug-pairing: $m" }

$symSrc = [IO.File]::ReadAllText((Join-Path $root 'cspect-plugin/src/SymbolFile.cs'))
if ($symSrc -notmatch 'RequiredHooks\s*=\s*\{([^}]*)\}') { Fail 'RequiredHooks not found in cspect-plugin/src/SymbolFile.cs' }
[string[]]$required = @([regex]::Matches($Matches[1], '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
[Array]::Sort($required, [StringComparer]::Ordinal)
if ($required.Count -eq 0) { Fail 'RequiredHooks lists no hook' }
$inc = [IO.File]::ReadAllText((Join-Path $root 'src/nextdaad.inc'))
if ($inc -notmatch '(?m)^BANK_NXB\s+equ\s+(\d+)') { Fail 'BANK_NXB not found in src/nextdaad.inc' }
$debugBank = [int]$Matches[1]

if (-not (Test-Path -LiteralPath $symPath)) { Fail "no $symPath - $mismatch" }
if (-not (Test-Path -LiteralPath $nexPath)) { Fail "no $nexPath" }
$lines = [IO.File]::ReadAllText($symPath) -split '\r?\n' | Where-Object { $_ -ne '' }
if ($lines[0] -ne "NEXTDAAD-SYM`t1") { Fail "bad SYM header '$($lines[0])'" }
$build = $lines | Where-Object { $_.StartsWith("build`t") } | Select-Object -First 1
if (-not $build) { Fail 'SYM has no build line' }
$variant = ($build -split "`t")[2]
if ($variant -ne 'Release') { Fail "SYM build variant is '$variant', the kit must ship Release - rebuild the kit with build.ps1 -Kit" }

$nex = [IO.File]::ReadAllBytes($nexPath)
if ([Text.Encoding]::ASCII.GetString($nex, 0, 4) -ne 'Next') { Fail 'nextdaad.nex is not a NEX file' }
if ($nex[18 + $debugBank]) { Fail "nextdaad.nex loads bank $debugBank (BANK_NXB) - it is a DEBUG build; rebuild the kit with build.ps1 -Kit" }
$bankOff = @{}; $pos = 512
foreach ($b in @(5, 2, 0, 1, 3, 4) + (6..111)) { if ($nex[18 + $b]) { $bankOff[$b] = $pos; $pos += 16384 } }

$names = New-Object Collections.Generic.List[string]
foreach ($l in $lines) {
    $f = $l -split "`t"
    if ($f[0] -ne 'hook') { continue }
    $names.Add($f[1])
    $addr = [Convert]::ToInt32($f[2], 16); $page = [Convert]::ToInt32($f[3], 16)
    $want = $f[4].ToUpperInvariant()
    $bank = $page -shr 1
    if (-not $bankOff.ContainsKey($bank)) { Fail "hook $($f[1]): bank $bank not in the NEX - $mismatch" }
    $start = $bankOff[$bank] + ($page -band 1) * 8192 + ($addr -band 0x1FFF)
    $n = $want.Length / 2
    $got = -join ($nex[$start..($start + $n - 1)] | ForEach-Object { '{0:X2}' -f $_ })
    if ($got -ne $want) { Fail "hook $($f[1]) bytes differ: $mismatch" }
}
[string[]]$have = $names.ToArray()
[Array]::Sort($have, [StringComparer]::Ordinal)
if (($have -join ',') -cne ($required -join ',')) { Fail "SYM hooks are '$($have -join ',')', the plugin needs '$($required -join ',')' - $mismatch" }
Write-Output "kit-debug-pairing: $($have.Count) hooks paired ($($have -join ', ')), Release"
