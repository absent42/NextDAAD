# run.ps1 - launch CSpect on RELEASE\. Launched by RUN.BAT / run.sh, or by
# build.ps1 when RUN=1. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
if (-not (Test-Path -LiteralPath (Join-Path $kitRoot (Join-Path 'RELEASE' 'nextdaad.nex')) -PathType Leaf)) {
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
$launch = Join-Path 'RELEASE' 'nextdaad.nex'
if ($game -and (Test-Path -LiteralPath (Join-Path $kitRoot (Join-Path 'RELEASE' "$game.NEX")) -PathType Leaf)) { $launch = Join-Path 'RELEASE' "$game.NEX" }
# The call operator passes each array element as one argument (quoted
# correctly on both hosts) and waits for CSpect to exit, per R16.
# Start-Process -ArgumentList joins the array into one string and does not
# re-quote elements containing spaces under 5.1 or pwsh.
& $t.CSPECT '-w3' '-zxnext' '-esc' '-mmc=RELEASE\' $launch | Out-Null
exit 0
