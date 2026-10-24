# clean.ps1 - remove RELEASE\<GAME>\ for the selected game and CACHE\jnext\; other
# games' output in RELEASE\ is left. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kitgame.ps1')
$kitRoot = (Get-Location).Path
$cfg0 = Read-KitConfig $kitRoot
try { $g = Resolve-KitGame $cfg0 $kitRoot } catch { Write-Host "$($_.Exception.Message)"; exit 1 }
$rel = $g.RelGame
$cleaned = $false
if (Test-Path -LiteralPath $rel -PathType Container) {
    Remove-Item -LiteralPath $rel -Recurse -Force
    Write-Host "cleaned $(Join-KitPath @('RELEASE', $g.Name))$([IO.Path]::DirectorySeparatorChar)"
    $cleaned = $true
}
$jdir = Join-Path (Join-Path $kitRoot 'CACHE') 'jnext'
if (Test-Path -LiteralPath $jdir -PathType Container) {
    Remove-Item -LiteralPath $jdir -Recurse -Force
    Write-Host "removed $(Join-KitPath @('CACHE', 'jnext'))$([IO.Path]::DirectorySeparatorChar)"
    $cleaned = $true
}
if (-not $cleaned) { Write-Host 'nothing to clean' }
exit 0
