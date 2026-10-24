# run.ps1 - launch CSpect or jNext (EMULATOR) on RELEASE\<GAME>\. Launched by RUN.BAT / run.sh, or by
# build.ps1 when RUN=1. cwd = kit root.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
. (Join-Path $PSScriptRoot 'kitgame.ps1')
. (Join-Path $PSScriptRoot 'kitjnext.ps1')
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
if ($t.EMULATOR -ne 'cspect' -and $t.EMULATOR -ne 'jnext') {
    Write-Host "ERROR: EMULATOR=$($t.EMULATOR) - use cspect or jnext"; exit 1
}
if ($t.EMULATOR -eq 'jnext') {
    $jnextOk = Test-Path -LiteralPath $t.JNEXT -PathType Leaf
    if (-not $jnextOk -and -not $OnWindows) { $jnextOk = [bool](Get-Command $t.JNEXT -CommandType Application -ErrorAction SilentlyContinue) }
    if (-not $jnextOk) {
        Write-Host "ERROR: jNext not found at $($t.JNEXT)"
        Write-Host '       Install jNext 1.1.87 or later there, or set JNEXTDIR in CONFIG.local.BAT.'
        if (-not $OnWindows) { Write-Host '       On Linux, installing the .deb or .rpm package puts jnext on your PATH.' }
        exit 1
    }
    if (-not (Test-Path -LiteralPath $t.JNEXTIMG -PathType Leaf)) {
        Write-Host "ERROR: no jNext SD-card image at $($t.JNEXTIMG)"
        Write-Host '       Start jNext once and let it download its SD-card image, or set JNEXTIMG in CONFIG.local.BAT.'
        exit 1
    }
    if (Test-JNextRunning) { Write-Host 'ERROR: jNext is running - close it before running the game'; exit 1 }
    $jwork = Join-Path (Join-Path $kitRoot 'CACHE') 'jnext'
    $card = Join-Path $jwork 'card.img'
    try { $null = Publish-JNextCard $t.JNEXT $t.JNEXTIMG $card $g.RelGame $nexFile.Name $jwork }
    catch { Write-Host "$($_.Exception.Message)"; exit 1 }
    # jNext EXIT STATUS: 0 success; 130/143 after SIGINT/SIGTERM; any other non-zero is an error.
    $jrc = Invoke-JNextTool $t.JNEXT @('--sdcard', $card)
    if ($jrc -notin @(0, 130, 143)) { Write-Host "note: jNext exited with code $jrc" }
    exit 0
}
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
