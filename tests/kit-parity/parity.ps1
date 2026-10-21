# Builds the parity fixture through the kit's own launchers and compares a
# sha256 manifest of RELEASE\ with golden\manifest.txt. Exit 0/1/2.
# nextdaad.nex is a verbatim copy of the kit's interpreter: it is checked
# against that source every run instead, so rebuilds need no re-capture.
param(
    [string]$ToolsDir = '',
    [string]$FfmpegDir = '',
    [switch]$Capture,
    [switch]$NoCompare,
    [switch]$PrepareOnly,
    [string]$Shell = '',
    [ValidateSet('', 'compress')][string]$Variant = '',
    [ValidateSet('', 'folder')][string]$Layout = ''
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
. (Join-Path $kitSrc 'lib/kitplatform.ps1')
$pyc = Find-Python @('PIL', 'numpy'); if (-not $pyc) { Write-Host 'parity: no python with PIL/numpy'; exit 2 }

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
# The shipped STARTER\ game would make a second game beside the fixture.
foreach ($drop in 'STARTER') {
    $p = Join-Path $kit $drop
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
# Fixture: committed text, generated binaries, and the kit's own demo songs.
$fix = Join-Path $PSScriptRoot 'fixture'
Copy-Item -Path "$fix/*" -Destination $kit -Recurse -Force
$pyRest = @(); if ($pyc.Length -gt 1) { $pyRest = $pyc[1..($pyc.Length - 1)] }; & $pyc[0] @pyRest (Join-Path $PSScriptRoot 'mkfixture.py') $kit --ffmpeg $ffmpeg
if ($LASTEXITCODE -ne 0) { throw 'mkfixture.py failed' }
Copy-Item -LiteralPath (Join-Path $kitSrc 'STARTER/AUDIO/STARTER.aks') -Destination (Join-Path $kit 'AUDIO/PARITY.aks')
Copy-Item -LiteralPath (Join-Path $kitSrc 'STARTER/AUDIO/STARTER_FX.aks') -Destination (Join-Path $kit 'AUDIO/PARITY_FX.aks')
Copy-Item -LiteralPath (Join-Path $kitSrc 'STARTER/AUDIO/STARTER.aks') -Destination (Join-Path $kit 'AUDIO/STREAM_001.aks')
# Variant selects which fixture CONFIG/intro pair the kit copy keeps -
# the other variant's files are removed so the copy holds exactly what
# an author would have (never both intros or both CONFIG.fixture*.BAT).
$configName = if ($Variant -eq 'compress') { 'CONFIG.fixture2.BAT' } else { 'CONFIG.fixture.BAT' }
if ($Variant -eq 'compress') {
    Copy-Item -LiteralPath (Join-Path $kit 'INTRO2.TXT') -Destination (Join-Path $kit 'INTRO.TXT') -Force
    Remove-Item -LiteralPath (Join-Path $kit 'CONFIG.fixture.BAT')
} else {
    Remove-Item -LiteralPath (Join-Path $kit 'CONFIG.fixture2.BAT')
}
Remove-Item -LiteralPath (Join-Path $kit 'INTRO2.TXT')
# CONFIG.local.BAT: fixture settings plus absolute tool dirs.
$local = @(Get-Content -LiteralPath (Join-Path $kit $configName) -Encoding ASCII)
$local += "SET TOOLSDIR=$ToolsDir"
$local += "SET FFMPEGDIR=$FfmpegDir"
$local += "SET GFXDIR=$([IO.Path]::GetFullPath((Join-Path $kit 'tools/gfx2next')))"
$local += "SET VIDTOOLSDIR=$([IO.Path]::GetFullPath((Join-Path $kit 'tools/vidtools')))"
[IO.File]::WriteAllLines((Join-Path $kit 'CONFIG.local.BAT'), $local, [Text.Encoding]::ASCII)
Remove-Item -LiteralPath (Join-Path $kit $configName)
# -Layout folder: the same fixture as game folder kit\PARITY\ with its game
# settings in PARITY.CFG; GAME, RUN and tool dirs stay in CONFIG.local.BAT.
$gameDir = Join-Path $kit 'PARITY'
if ($Layout -eq 'folder') {
    New-Item -ItemType Directory -Force $gameDir | Out-Null
    foreach ($mv in 'PARITY.DSF', 'inc', 'PART2', 'IMAGES', 'AUDIO', 'VIDEO', 'INTRO', 'HINTS.TXT', 'INTRO.TXT', 'FONT.psf', 'FONT1.bdf', 'GAME.XBN') {
        $p = Join-Path $kit $mv
        if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination (Join-Path $gameDir $mv) }
    }
    $localPath = Join-Path $kit 'CONFIG.local.BAT'
    $keep = @(); $gameCfg = @()
    foreach ($l in [IO.File]::ReadAllLines($localPath)) {
        if ($l -match '^SET (COMPRESS|VIDOPTS_\d+)=') { $gameCfg += $l } else { $keep += $l }
    }
    [IO.File]::WriteAllLines($localPath, $keep, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllLines((Join-Path $gameDir 'PARITY.CFG'), $gameCfg, [Text.Encoding]::ASCII)
}
if ($PrepareOnly) { Write-Host "parity: prepared $kit"; exit 0 }

# A driver .cmd sidesteps cmd /c quote stripping on a quoted path with
# spaces (the form tests\xbnbuild-selftest.ps1 uses). < nul defeats pause.
function Invoke-Launcher([string]$name, [string[]]$launchArgs, [string]$cwd = $kit) {
    Push-Location $cwd
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
            $cwdFull = [IO.Path]::GetFullPath($cwd)
            $line = "@cd /d `"$cwdFull`"`r`n@call `"$kitFull/$name.BAT`" $($launchArgs -join ' ') < nul`r`n@exit /b %ERRORLEVEL%`r`n"
            [IO.File]::WriteAllText($drv, $line, [Text.Encoding]::ASCII)
            & cmd /c $drv 2>&1 | ForEach-Object { "$_" } | Out-Host
        } else {
            & sh (Join-Path ([IO.Path]::GetFullPath($kit)) "$($name.ToLower()).sh") @launchArgs 2>&1 | ForEach-Object { "$_" } | Out-Host
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
} else {
    $extCwd = if ($Layout -eq 'folder') { $gameDir } else { $kit }
    $code = Invoke-Launcher 'EXTERNS' @('ticker', 'hints') $extCwd
    if ($code -ne 0) { Write-Host "parity: EXTERNS failed ($code)"; exit 1 }
}
if ($Layout -eq 'folder') {
    if (-not (Test-Path -LiteralPath (Join-Path $gameDir 'GAME.XBN'))) { Write-Host 'parity: EXTERNS did not write PARITY/GAME.XBN'; exit 1 }
    if (Test-Path -LiteralPath (Join-Path $kit 'GAME.XBN')) { Write-Host 'parity: EXTERNS left GAME.XBN at the kit root'; exit 1 }
}
function Invoke-Build { if ($Shell) { return (Invoke-LibScript 'build' @()) } else { return (Invoke-Launcher 'BUILD' @()) } }
$code = Invoke-Build
if ($code -ne 0) { Write-Host "parity: BUILD failed ($code)"; exit 1 }

$rel = Join-Path $kit 'RELEASE'
# Runs before -Capture/-NoCompare exits, so the Linux container checks it too.
# The fixture has an intro, so the interpreter is DATA\nextdaad.nex.
$nexOut = Join-Path $rel 'PARITY/DATA/nextdaad.nex'
$nexSrc = Join-Path $kit 'nextdaad.nex'
if (-not (Test-Path -LiteralPath $nexOut)) { Write-Host 'parity: FAIL - RELEASE has no PARITY\DATA\nextdaad.nex'; exit 1 }
$nexSame = [Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($nexOut), [IO.File]::ReadAllBytes($nexSrc))
if (-not $nexSame) { Write-Host 'parity: FAIL - RELEASE\PARITY\DATA\nextdaad.nex differs from the kit''s nextdaad.nex'; exit 1 }
Write-Host 'parity: nextdaad.nex is a byte-exact copy of the kit interpreter'
$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-Manifest {
    $lines = foreach ($f in (Get-ChildItem -LiteralPath $rel -File -Recurse)) {
        $relPath = $f.FullName.Substring($rel.Length + 1) -replace '\\', '/'
        if ($relPath -eq 'PARITY/DATA/nextdaad.nex') { continue }
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $hex = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        "$relPath $($f.Length) $hex"
    }
    $list = New-Object System.Collections.Generic.List[string]
    $list.AddRange([string[]]$lines)
    $list.Sort([StringComparer]::Ordinal)
    return , $list
}
$sorted = Get-Manifest
if ($Layout -eq 'folder') {
    # A second game folder builds into RELEASE\OTHER\ and leaves RELEASE\PARITY\ alone.
    $other = Join-Path $kit 'OTHER'
    New-Item -ItemType Directory -Force $other | Out-Null
    Copy-Item -LiteralPath (Join-Path $gameDir 'PARITY.DSF') -Destination (Join-Path $other 'OTHER.DSF')
    Copy-Item -LiteralPath (Join-Path $gameDir 'inc') -Destination (Join-Path $other 'inc') -Recurse
    $localPath = Join-Path $kit 'CONFIG.local.BAT'
    $localSaved = [IO.File]::ReadAllBytes($localPath)
    [IO.File]::AppendAllText($localPath, "SET GAME=OTHER`r`n", [Text.Encoding]::ASCII)
    $code = Invoke-Build
    [IO.File]::WriteAllBytes($localPath, $localSaved)
    if ($code -ne 0) { Write-Host "parity: BUILD of OTHER failed ($code)"; exit 1 }
    if (-not (Test-Path -LiteralPath (Join-Path $rel 'OTHER/OTHER.NEX'))) { Write-Host 'parity: FAIL - RELEASE has no OTHER\OTHER.NEX'; exit 1 }
    $after = @((Get-Manifest) | Where-Object { $_.StartsWith('PARITY/') })
    if (($after -join "`n") -cne ($sorted -join "`n")) { Write-Host 'parity: FAIL - building OTHER changed RELEASE\PARITY\'; exit 1 }
    Write-Host 'parity: second game OTHER left RELEASE\PARITY\ unchanged'
}
$manifestName = if ($Variant -eq 'compress') { 'manifest-compress.txt' } else { 'manifest.txt' }
$manifest = Join-Path $work $manifestName
[IO.File]::WriteAllText($manifest, (($sorted -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Write-Host "parity: $($sorted.Count) files -> $manifest"

$golden = Join-Path $PSScriptRoot "golden/$manifestName"
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
