# Fresh-install acceptance: the tracked kit plus a machine-only
# CONFIG.local.BAT builds the shipped STARTER\ game. Exit 0/1/2.
param([string]$ToolsDir = '', [string]$FfmpegDir = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kitSrc = Join-Path $root 'authoring-kit'
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
if (-not $ToolsDir) { $ToolsDir = Join-Path $root 'tools' }
if (-not $FfmpegDir) { $FfmpegDir = Join-Path $kitSrc 'tools/ffmpeg' }
$ToolsDir = [IO.Path]::GetFullPath($ToolsDir)
$FfmpegDir = [IO.Path]::GetFullPath($FfmpegDir)
if (-not (Test-Path -LiteralPath $ToolsDir -PathType Container)) { Write-Host "kit-fresh-install: tools missing: $ToolsDir"; exit 2 }

$work = Join-Path $root 'tests/out/kit-fresh'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
foreach ($rel in (& git -C $kitSrc ls-files)) {
    $dst = Join-Path $work $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::Copy((Join-Path $kitSrc $rel), $dst, $true)
}
# Machine-only settings, the parity.ps1 shape: tool dirs and RUN, no GAME.
$local = @(
    '@echo off',
    "SET TOOLSDIR=$ToolsDir",
    "SET FFMPEGDIR=$FfmpegDir",
    "SET GFXDIR=$([IO.Path]::GetFullPath((Join-Path $work 'tools/gfx2next')))",
    "SET VIDTOOLSDIR=$([IO.Path]::GetFullPath((Join-Path $work 'tools/vidtools')))",
    'SET RUN=0'
)
[IO.File]::WriteAllLines((Join-Path $work 'CONFIG.local.BAT'), $local, [Text.Encoding]::ASCII)
$cfgPath = Join-Path $work 'CONFIG.BAT'
$cfgBefore = [IO.File]::ReadAllBytes($cfgPath)

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($onWindows) {
        # A driver .cmd sidesteps cmd /c quote stripping; < nul defeats pause.
        $drv = [IO.Path]::GetFullPath((Join-Path $root 'tests/out/kit-fresh-launch.cmd'))
        $workFull = [IO.Path]::GetFullPath($work)
        $line = "@cd /d `"$workFull`"`r`n@call `"$workFull\BUILD.BAT`" < nul`r`n@exit /b %ERRORLEVEL%`r`n"
        [IO.File]::WriteAllText($drv, $line, [Text.Encoding]::ASCII)
        $out = @(& cmd /c $drv 2>&1 | ForEach-Object { "$_" })
    } else {
        Push-Location $work
        try { $out = @(& sh (Join-Path $work 'build.sh') 2>&1 | ForEach-Object { "$_" }) } finally { Pop-Location }
    }
    $code = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
$out | Out-Host

$fail = @()
if ($code -ne 0) { $fail += "BUILD exited $code" }
if (-not (($out -join "`n").Contains('is replaced by every kit update'))) { $fail += 'no STARTER warning in the build output' }
$rel = Join-Path $work 'RELEASE'
foreach ($p in 'STARTER/STARTER.NEX', 'STARTER/DATA/GAME.DDB') {
    if (-not (Test-Path -LiteralPath (Join-Path $rel $p) -PathType Leaf)) { $fail += "RELEASE/$p missing" }
}
if (Test-Path -LiteralPath $rel) {
    $extra = @(Get-ChildItem -LiteralPath $rel -Force | Where-Object { $_.Name -ne 'STARTER' } | ForEach-Object { $_.Name })
    if ($extra.Count) { $fail += "RELEASE root holds more than STARTER: $($extra -join ', ')" }
}
$cfgAfter = [IO.File]::ReadAllBytes($cfgPath)
if (-not [Linq.Enumerable]::SequenceEqual($cfgBefore, $cfgAfter)) { $fail += 'CONFIG.BAT changed during the build' }
$cfgLines = [IO.File]::ReadAllLines($cfgPath)
if (-not ($cfgLines -ccontains 'SET RUN=1')) { $fail += 'shipped CONFIG.BAT lacks SET RUN=1' }
$gameLines = @($cfgLines | Where-Object { $_ -match '^SET GAME=' })
if ($gameLines.Count -ne 1 -or $gameLines[0] -cne 'SET GAME=') { $fail += "shipped CONFIG.BAT GAME line is not an empty SET GAME= ($($gameLines -join ' | '))" }

if ($fail.Count) { foreach ($f in $fail) { Write-Host "kit-fresh-install: FAIL - $f" }; exit 1 }
Write-Host 'kit-fresh-install: PASS'
exit 0
