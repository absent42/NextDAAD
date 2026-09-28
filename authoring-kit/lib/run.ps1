# run.ps1 - launch CSpect on RELEASE\. Launched by RUN.BAT / run.sh, or by
# build.ps1 when RUN=1. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
$relDir = Join-Path $kitRoot 'RELEASE'
if (-not (Find-KitFile $relDir 'nextdaad.nex')) {
    Write-Host "ERROR: nothing built yet - run $BuildLauncherName first"; exit 1
}
$t = Resolve-KitTools $cfg $kitRoot
if (-not (Test-Path -LiteralPath $t.CSPECT -PathType Leaf)) {
    Write-Host "ERROR: CSpect not found at $($t.CSPECT)"
    Write-Host '       Install CSpect there, or set CSPECTDIR in CONFIG.BAT to an'
    Write-Host '       existing install.'
    exit 1
}
if (-not $OnWindows -and -not (Get-Command $t.CSPECTCMD -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: $($t.CSPECTCMD) not found - CSpect needs mono on Linux (sudo apt install mono-devel), or set CSPECTCMD in CONFIG.BAT"
    exit 1
}
$game = if ($cfg.ContainsKey('GAME')) { [string]$cfg['GAME'] } else { '' }
if (-not $game) {
    # Ordinal order (Get-KitFiles), not directory enumeration order: the
    # "last" .DSF must be the same file on NTFS and ext4.
    $dsfs = @(Get-KitFiles $kitRoot 'DSF')
    if ($dsfs.Count -gt 0) { $game = $dsfs[$dsfs.Count - 1].BaseName }
}
$launch = Join-Path 'RELEASE' 'nextdaad.nex'
$nexFile = if ($game) { Find-KitFile $relDir "$game.NEX" } else { $null }
if ($nexFile) { $launch = Join-Path 'RELEASE' $nexFile.Name }
# The call operator quotes each argument on both hosts (Start-Process
# -ArgumentList does not); piping to Out-Null waits for CSpect to exit.
if ($OnWindows) { & $t.CSPECT '-w3' '-zxnext' '-esc' '-mmc=RELEASE\' $launch | Out-Null }
else { & $t.CSPECTCMD $t.CSPECT '-w3' '-zxnext' '-esc' '-mmc=RELEASE\' $launch | Out-Null }
exit 0
