# externs.ps1 - EXTERNS.BAT / externs.sh body; cwd = kit root.
# PositionalBinding off: a bare first module must not bind to -BaseDir.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$BaseDir = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Modules = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
$t = Resolve-KitTools $cfg $kitRoot
if (-not $BaseDir) { $BaseDir = $kitRoot }
# Absolute now: xbnbuild changes directory, and TOOLSDIR defaults relative.
$sj = if ([IO.Path]::IsPathRooted($t.SJASMPLUS)) { $t.SJASMPLUS } else { Join-Path $kitRoot $t.SJASMPLUS }
$xb = Join-Path $PSScriptRoot 'xbnbuild.ps1'
$out = Join-Path $kitRoot 'GAME.XBN'
# -SjasmPlus only when the file exists, so xbnbuild's PATH fallback stays reachable.
if (Test-Path -LiteralPath $sj -PathType Leaf) { & $xb @Modules -Out $out -BaseDir $BaseDir -SjasmPlus $sj }
else { & $xb @Modules -Out $out -BaseDir $BaseDir }
exit $LASTEXITCODE
