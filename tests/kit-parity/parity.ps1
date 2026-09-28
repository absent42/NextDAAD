# Builds the parity fixture through the kit's own launchers and compares a
# sha256 manifest of RELEASE\ with golden\manifest.txt. Exit 0/1/2.
param(
    [string]$ToolsDir = '',
    [string]$FfmpegDir = '',
    [switch]$Capture,
    [switch]$NoCompare,
    [switch]$PrepareOnly,
    [string]$Shell = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$kitSrc = Join-Path $root 'authoring-kit'
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$exe = if ($onWindows) { '.exe' } else { '' }
if (-not $ToolsDir) { $ToolsDir = Join-Path $root 'tools' }
if (-not $FfmpegDir) { $FfmpegDir = Join-Path $kitSrc 'tools/ffmpeg' }
$ToolsDir = [IO.Path]::GetFullPath($ToolsDir)
$FfmpegDir = [IO.Path]::GetFullPath($FfmpegDir)
$ffmpeg = Join-Path (Join-Path $FfmpegDir 'bin') "ffmpeg$exe"
if (-not (Test-Path -LiteralPath $ffmpeg)) { $ffmpeg = Join-Path $FfmpegDir "ffmpeg$exe" }
foreach ($need in @($ffmpeg, (Join-Path $ToolsDir "ArkosTracker3/tools/SongToAky$exe"), (Join-Path $ToolsDir "sjasmplus/sjasmplus$exe"))) {
    if (-not (Test-Path -LiteralPath $need)) { Write-Host "parity: tool missing: $need"; exit 2 }
}
$py = if ($onWindows) { 'python' } else { 'python3' }
& $py -c 'import PIL, numpy' *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "parity: $py lacks PIL/numpy"; exit 2 }

$work = Join-Path $root 'tests/out/kit parity'
$kit = Join-Path $work 'kit'
if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
New-Item -ItemType Directory -Force $kit | Out-Null

# Tracked files only: a clone is what users get.
$tracked = & git -C $kitSrc ls-files
foreach ($rel in $tracked) {
    $src = Join-Path $kitSrc $rel
    $dst = Join-Path $kit $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    [IO.File]::Copy($src, $dst, $true)
}
foreach ($drop in 'IMAGES', 'AUDIO', 'VIDEO', 'HINTS.TXT', 'STARTER.DSF', 'INTRO.TXT.sample') {
    $p = Join-Path $kit $drop
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
# Fixture: committed text, generated binaries, and the kit's own demo songs.
$fix = Join-Path $PSScriptRoot 'fixture'
Copy-Item -Path "$fix/*" -Destination $kit -Recurse -Force
& $py (Join-Path $PSScriptRoot 'mkfixture.py') $kit --ffmpeg $ffmpeg
if ($LASTEXITCODE -ne 0) { throw 'mkfixture.py failed' }
Copy-Item -LiteralPath (Join-Path $kitSrc 'AUDIO/STARTER.aks') -Destination (Join-Path $kit 'AUDIO/PARITY.aks')
Copy-Item -LiteralPath (Join-Path $kitSrc 'AUDIO/STARTER_FX.aks') -Destination (Join-Path $kit 'AUDIO/PARITY_FX.aks')
Copy-Item -LiteralPath (Join-Path $kitSrc 'AUDIO/STARTER.aks') -Destination (Join-Path $kit 'AUDIO/STREAM_001.aks')
# CONFIG.local.BAT: fixture settings plus absolute tool dirs.
$local = @(Get-Content -LiteralPath (Join-Path $kit 'CONFIG.fixture.BAT') -Encoding ASCII)
$local += "SET TOOLSDIR=$ToolsDir"
$local += "SET FFMPEGDIR=$FfmpegDir"
$local += "SET GFXDIR=$([IO.Path]::GetFullPath((Join-Path $kit 'tools/gfx2next')))"
$local += "SET VIDTOOLSDIR=$([IO.Path]::GetFullPath((Join-Path $kit 'tools/vidtools')))"
[IO.File]::WriteAllLines((Join-Path $kit 'CONFIG.local.BAT'), $local, [Text.Encoding]::ASCII)
Remove-Item -LiteralPath (Join-Path $kit 'CONFIG.fixture.BAT')
if ($PrepareOnly) { Write-Host "parity: prepared $kit"; exit 0 }

# A driver .cmd sidesteps cmd /c quote stripping on a quoted path with
# spaces (the form tests\xbnbuild-selftest.ps1 uses). < nul defeats pause.
function Invoke-Launcher([string]$name, [string[]]$launchArgs) {
    Push-Location $kit
    # A native tool's stderr (eg. sjasmplus' banner) becomes a terminating
    # error under -Stop merged with 2>&1, even on exit code 0. Scope
    # Continue to just this call; $LASTEXITCODE is checked explicitly.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($onWindows) {
            $drv = Join-Path $work 'launch.cmd'
            $drv = [IO.Path]::GetFullPath($drv)
            $kitFull = [IO.Path]::GetFullPath($kit)
            $line = "@cd /d `"$kitFull`"`r`n@call `"$kitFull/$name.BAT`" $($launchArgs -join ' ') < nul`r`n@exit /b %ERRORLEVEL%`r`n"
            [IO.File]::WriteAllText($drv, $line, [Text.Encoding]::ASCII)
            & cmd /c $drv 2>&1 | ForEach-Object { "$_" } | Out-Host
        } else {
            & sh "./$($name.ToLower()).sh" @launchArgs 2>&1 | ForEach-Object { "$_" } | Out-Host
        }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap; Pop-Location }
}
# -Shell runs the lib script directly under a chosen PowerShell host,
# bypassing the launcher .BAT/.sh, to test that host without the shim.
function Invoke-LibScript([string]$name, [string[]]$scriptArgs) {
    Push-Location $kit
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lib = Join-Path (Join-Path $kit 'lib') "$name.ps1"
        & $Shell -NoProfile -File $lib @scriptArgs 2>&1 | ForEach-Object { "$_" } | Out-Host
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap; Pop-Location }
}
# Externs first: BUILD stages the kit-root GAME.XBN into RELEASE.
if ($Shell) {
    # Bare module list, no -BaseDir: the golden GAME.XBN fails if
    # externs.ps1 binds the first module to -BaseDir by position.
    $code = Invoke-LibScript 'externs' @('ticker', 'hints')
    if ($code -ne 0) { Write-Host "parity: EXTERNS failed ($code)"; exit 1 }
    $code = Invoke-LibScript 'build' @()
    if ($code -ne 0) { Write-Host "parity: BUILD failed ($code)"; exit 1 }
} else {
    $code = Invoke-Launcher 'EXTERNS' @('ticker', 'hints')
    if ($code -ne 0) { Write-Host "parity: EXTERNS failed ($code)"; exit 1 }
    $code = Invoke-Launcher 'BUILD' @()
    if ($code -ne 0) { Write-Host "parity: BUILD failed ($code)"; exit 1 }
}

$rel = Join-Path $kit 'RELEASE'
$sha = [System.Security.Cryptography.SHA256]::Create()
$lines = foreach ($f in (Get-ChildItem -LiteralPath $rel -File -Recurse)) {
    $relPath = $f.FullName.Substring($rel.Length + 1) -replace '\\', '/'
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hex = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    "$relPath $($f.Length) $hex"
}
$sorted = New-Object System.Collections.Generic.List[string]
$sorted.AddRange([string[]]$lines)
$sorted.Sort([StringComparer]::Ordinal)
$manifest = Join-Path $work 'manifest.txt'
[IO.File]::WriteAllText($manifest, (($sorted -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Write-Host "parity: $($sorted.Count) files -> $manifest"

$golden = Join-Path $PSScriptRoot 'golden/manifest.txt'
if ($Capture) {
    New-Item -ItemType Directory -Force (Split-Path $golden) | Out-Null
    [IO.File]::Copy($manifest, $golden, $true)
    Write-Host "parity: golden captured"
    exit 0
}
if ($NoCompare) { exit 0 }
if (-not (Test-Path -LiteralPath $golden)) { Write-Host 'parity: no golden - run with -Capture'; exit 2 }
$a = [IO.File]::ReadAllText($golden)
$b = [IO.File]::ReadAllText($manifest)
if ($a -ceq $b) { Write-Host 'parity: PASS (identical to golden)'; exit 0 }
Write-Host 'parity: FAIL - manifest differs from golden'
$ga = [IO.File]::ReadAllLines($golden); $gb = [IO.File]::ReadAllLines($manifest)
if (($ga -join "`n") -ceq ($gb -join "`n")) { Write-Host 'parity: manifest differs only in line endings'; exit 1 }
foreach ($l in $ga) { if ($gb -notcontains $l) { Write-Host "- $l" } }
foreach ($l in $gb) { if ($ga -notcontains $l) { Write-Host "+ $l" } }
exit 1
