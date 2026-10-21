# vidtune.ps1 - VIDTUNE.BAT body. Prefers the shipped exe (>1MB, so an LFS
# pointer file is skipped); -Src or a missing exe falls back to Python.
param([switch]$Src)
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
# Quoted: Start-Process joins -ArgumentList unquoted, and the path may hold spaces.
# Trailing separator trimmed so it cannot escape the quote; a bare drive or
# empty path still resolves to the kit root, the working directory.
$gameArg = @('--game-dir', "`"$($g.SrcRoot.TrimEnd('\', '/'))`"")
if ($g.Mode -eq 'folder') { $gameArg += @('--game-cfg', "`"$($g.CfgFile)`"") }
$t = Resolve-KitTools $cfg $kitRoot
$env:PYTHONPATH = $PSScriptRoot + [IO.Path]::PathSeparator + $env:PYTHONPATH
$kitExe = Join-Path $kitRoot (Join-Path 'tools' (Join-Path 'vidtools' "vidtune$ExeSuffix"))
if (-not $Src) {
    foreach ($exe in @($t.VIDTUNE, $kitExe)) {
        $abs = if ([IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $kitRoot $exe }
        if ((Test-Path -LiteralPath $abs -PathType Leaf) -and (Get-Item -LiteralPath $abs).Length -gt 1000000) {
            Start-Process -FilePath $abs -ArgumentList $gameArg -WorkingDirectory $kitRoot | Out-Null
            exit 0
        }
    }
}
# QtWidgets, not PySide6 alone: only it loads Qt's system libraries.
$py = Find-Python @('PySide6.QtWidgets', 'numpy', 'PIL')
if ($py) {
    $rest = @()
    if ($py.Length -gt 1) { $rest = $py[1..($py.Length - 1)] }
    Start-Process -FilePath $py[0] -ArgumentList ($rest + @('-m', 'vidtune') + $gameArg) -WorkingDirectory $kitRoot | Out-Null
    exit 0
}
# vidtune itself always ships (lib/vidtune); only its Python packages can be
# missing, so name each Python tried and its import error.
$missingLib = $false
Write-Host 'ERROR: vidtune (lib/vidtune) cannot start: no Python 3 here can load PySide6, numpy and Pillow.'
foreach ($cand in (Get-PythonCandidates)) {
    $rest = @()
    if ($cand.Length -gt 1) { $rest = $cand[1..($cand.Length - 1)] }
    $cmd = Get-Command $cand[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Write-Host "       $($cand -join ' '): not found"; continue }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $err = @(& $cmd.Source @rest -c 'import PySide6.QtWidgets, numpy, PIL' 2>&1 | ForEach-Object { "$_" }) | Select-Object -Last 1
    $ErrorActionPreference = $prevEap
    Write-Host "       $($cand -join ' ') ($($cmd.Source)): $err"
    if ("$err" -match '\.so') { $missingLib = $true }
}
if ($OnWindows) {
    if ($Src) { Write-Host '       (-Src: the standalone vidtune was not tried)' }
    else {
        Write-Host '       The standalone vidtune was not found either:'
        Write-Host "         $($t.VIDTUNE)"
        Write-Host "         $kitExe"
        Write-Host '       See tools\README.txt, or set VIDTOOLSDIR in CONFIG.BAT.'
    }
    Write-Host '       To run it from Python instead: pip install -r lib/requirements-vidtune.txt'
} elseif ($missingLib) {
    Write-Host '       The packages are installed but Qt needs system libraries. On Debian/Ubuntu:'
    Write-Host '         sudo apt install libgl1 libegl1 libxkbcommon0 libfontconfig1 libdbus-1-3 libglib2.0-0'
} else {
    Write-Host '       Set up the venv from docs/getting-started.html (Linux setup), then install them:'
    Write-Host '         ~/nextdaad-venv/bin/pip install -r lib/requirements-vidtune.txt'
}
exit 1
