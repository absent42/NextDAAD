# run.ps1 - launch CSpect on RELEASE\. Launched by RUN.BAT / run.sh, or by
# build.ps1 when RUN=1. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
if (-not (Test-Path -LiteralPath (Join-Path $kitRoot 'RELEASE\nextdaad.nex') -PathType Leaf)) {
    Write-Host "ERROR: nothing built yet - run $BuildLauncherName first"; exit 1
}
$t = Resolve-KitTools $cfg $kitRoot
if (-not (Test-Path -LiteralPath $t.CSPECT -PathType Leaf)) {
    Write-Host "ERROR: CSpect not found at $($t.CSPECT)"
    Write-Host '       Install CSpect there, or set CSPECTDIR in CONFIG.BAT to an'
    Write-Host '       existing install.'
    exit 1
}
$game = if ($cfg.ContainsKey('GAME')) { [string]$cfg['GAME'] } else { '' }
if (-not $game) {
    $dsfs = @(Get-ChildItem -LiteralPath $kitRoot -File | Where-Object { $_.Name -match '(?i)\.DSF$' })
    if ($dsfs.Count -gt 0) { $game = $dsfs[$dsfs.Count - 1].BaseName }
}
$launch = 'RELEASE\nextdaad.nex'
if ($game -and (Test-Path -LiteralPath (Join-Path $kitRoot "RELEASE\$game.NEX") -PathType Leaf)) { $launch = "RELEASE\$game.NEX" }
Start-Process -FilePath $t.CSPECT -ArgumentList @('-w3', '-zxnext', '-esc', '-mmc=RELEASE\', $launch) -Wait
exit 0
