# run.ps1 - launch CSpect on RELEASE\<GAME>\. Launched by RUN.BAT / run.sh, or by
# build.ps1 when RUN=1. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
. (Join-Path $PSScriptRoot 'kitgame.ps1')
$kitRoot = (Get-Location).Path
$cfg0 = Read-KitConfig $kitRoot
try { $g = Resolve-KitGame $cfg0 $kitRoot } catch { Write-Host "$($_.Exception.Message)"; exit 1 }
$cfg = Read-KitConfig $kitRoot $g.CfgFile
Export-KitConfig $cfg
$nexFile = Find-KitFile $g.RelGame "$($g.Name).NEX"
if (-not $nexFile) {
    Write-Host "ERROR: nothing built yet for $($g.Name) - run $BuildLauncherName first"; exit 1
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
# The card root is the game folder, as an author copies it.
$sep = [IO.Path]::DirectorySeparatorChar
$mmc = "RELEASE$sep$($g.Name)$sep"
$launch = "$mmc$($nexFile.Name)"
$mmcArg = "-mmc=$mmc"
# Legacy argument passing (5.1, 7.0-7.2) quotes a spaced argument without
# escaping its trailing \, which would swallow the closing quote: double it.
$pass = "$(Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue)"
if ($OnWindows -and ($pass -in @('', 'Legacy')) -and $mmcArg -match '\s') { $mmcArg += $sep }
# The call operator quotes each argument on both hosts (Start-Process
# -ArgumentList does not); piping to Out-Null waits for CSpect to exit.
if ($OnWindows) { & $t.CSPECT '-w3' '-zxnext' '-esc' $mmcArg $launch | Out-Null }
else { & $t.CSPECTCMD $t.CSPECT '-w3' '-zxnext' '-esc' $mmcArg $launch | Out-Null }
exit 0
