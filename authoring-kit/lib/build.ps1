# build.ps1 - the kit build. Launched by BUILD.BAT with cwd = kit root.
# Messages are the v0.11.0 BUILD.BAT wording, pinned by
# tests\kit-parity\negative.ps1; the outputs by tests\kit-parity\parity.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'kitplatform.ps1')
. (Join-Path $PSScriptRoot 'kitconfig.ps1')
. (Join-Path $PSScriptRoot 'kittools.ps1')
$kitRoot = (Get-Location).Path
$lib = $PSScriptRoot
$cfg = Read-KitConfig $kitRoot
Export-KitConfig $cfg
function cfg([string]$k) { if ($cfg.ContainsKey($k)) { return [string]$cfg[$k] } else { return '' } }
function Fail([string[]]$Lines) { foreach ($l in $Lines) { Write-Host $l }; exit 1 }
# cmd's del ... 2>nul: a file that will not go is left, silently.
function Remove-Quiet([string]$p) { if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }

# Native tools write to stderr; under Stop that would terminate 5.1.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap }
}
# Stage scripts run in-process; their exit N returns here as $LASTEXITCODE.
function Invoke-Stage([string]$Script, [hashtable]$Params) {
    $global:LASTEXITCODE = 0
    try { & (Join-Path $lib $Script) @Params | Out-Host } catch { Write-Host "ERROR: $($_.Exception.Message)"; return 1 }
    return $LASTEXITCODE
}

# ---- GAME: auto-detect a single .DSF when blank ----
$game = cfg 'GAME'
if (-not $game) {
    $dsfs = @(Get-ChildItem -LiteralPath $kitRoot -File | Where-Object { $_.Name -match '(?i)\.DSF$' })
    if ($dsfs.Count -ne 1) { Fail "ERROR: set GAME in CONFIG.BAT (found $($dsfs.Count) .DSF files here, need exactly one)" }
    $game = $dsfs[0].BaseName
}
if (-not (Test-Path -LiteralPath "$game.DSF")) { Fail "ERROR: $game.DSF not found in this folder" }

$t = Resolve-KitTools $cfg $kitRoot
$drTarget = 'nextdaad'
$compress = cfg 'COMPRESS'
$cols = cfg 'COLS'
$nexFile = $t.NEXFILE

# ---- preflight ----
foreach ($need in @($t.NDRC, $nexFile)) {
    if (-not $need -or -not (Test-Path -LiteralPath $need)) { Fail "ERROR: required tool missing: $need" }
}
# BUILD.BAT judged "echo(banner | findstr": echo added the trailing space.
$banner = Get-NdrcBanner $t.NDRC
if (-not "$banner ".Contains("NDRC $($t.NDRCVER) ")) {
    Fail @('ERROR: wrong DAAD compiler version.', "  expected: NDRC $($t.NDRCVER)", "  found:    $banner", "  at:       $($t.NDRC)")
}
if (@(Get-Process -Name CSpect -ErrorAction SilentlyContinue).Count -gt 0) { Fail 'ERROR: CSpect is running - close it before building' }

# ---- prepare RELEASE\ : outputs rebuilt every run are removed ----
# Pictures, sprite sets, audio and video are left to assets.ps1.
$rel = Join-Path $kitRoot 'RELEASE'
if (-not (Test-Path -LiteralPath $rel)) { New-Item -ItemType Directory $rel | Out-Null }
function Remove-OutDir([string]$name) {
    $p = Join-Path $rel $name
    if (Test-Path -LiteralPath $p -PathType Container) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Continue }
}
foreach ($n in 'GAME.DDB', 'FONT.CHR', 'POINTER.SPR', 'GAME.HNT', 'GAME.XBN') { Remove-Quiet (Join-Path $rel $n) }
foreach ($i in 1..9) { Remove-Quiet (Join-Path $rel "FONT$i.CHR"); Remove-Quiet (Join-Path $rel "POINTER$i.SPR") }
Remove-Quiet (Join-Path $rel "$game.NEX")
Remove-OutDir 'INTRO'
foreach ($i in 2..9) { Remove-Quiet (Join-Path $rel "GAME$i.DDB"); Remove-OutDir "PART$i" }

Write-Host "Building $game ..."

# ---- DDB: one .DSF into a DDB; ndrc writes 0.XMB into the cwd ----
function Invoke-Ddb([string]$Game, [string]$DdbOut, [string]$XmbDir) {
    if (-not (Test-Path -LiteralPath $XmbDir)) { New-Item -ItemType Directory $XmbDir | Out-Null }
    Remove-Quiet '0.XMB'
    Remove-Quiet (Join-Path $XmbDir '0.XMB')
    # $ndrcArgs, not $args: $args is PowerShell's automatic variable.
    $ndrcArgs = @($drTarget, 'EN', "$Game.DSF", $DdbOut, '-v3', '-auto-tokens')
    if ($cols) { $ndrcArgs += "-cols=$cols" }
    $code = Invoke-Native $t.NDRC $ndrcArgs
    # cmd's "if errorlevel 1": a negative code falls through to the checks below.
    if ($code -ge 1) {
        Remove-Quiet $DdbOut
        Remove-Quiet '0.XMB'
        Write-Host "ERROR: ndrc failed compiling $Game.DSF - see the message above"; return 1
    }
    if (-not (Test-Path -LiteralPath $DdbOut)) {
        Remove-Quiet '0.XMB'
        Write-Host "ERROR: ndrc reported success but wrote no $DdbOut"; return 1
    }
    $size = (Get-Item -LiteralPath $DdbOut).Length
    if ($size -gt 65535) {
        Remove-Quiet $DdbOut
        Remove-Quiet '0.XMB'
        Write-Host "ERROR: $DdbOut is $size bytes, over the 65535 limit"; return 1
    }
    Write-Host "  DDB $size bytes -> $DdbOut"
    if (Test-Path -LiteralPath '0.XMB') {
        try { Move-Item -LiteralPath '0.XMB' -Destination (Join-Path $XmbDir '0.XMB') -Force }
        catch { Write-Host "ERROR: could not stage 0.XMB into $XmbDir"; return 1 }
        Write-Host "  XMB -> $XmbDir\0.XMB"
    }
    return 0
}
if ((Invoke-Ddb $game 'RELEASE\GAME.DDB' 'RELEASE') -ne 0) { exit 1 }

# ---- pictures, audio, video ----
if ((Invoke-Stage 'assets.ps1' @{ Stage = 'Pictures'; Gfx = $t.GFX; Compress = $compress }) -ne 0) { exit 1 }
if ((Invoke-Stage 'assets.ps1' @{ Stage = 'Audio'; Game = $game; S2A = $t.S2A; S2Y = $t.S2Y; S2E = $t.S2E }) -ne 0) { exit 1 }
if (Test-Path -LiteralPath 'VIDEO') {
    if ((Invoke-Stage 'video.ps1' @{}) -ne 0) { exit 1 }
}
if ((Invoke-Stage 'assets.ps1' @{ Stage = 'Video' }) -ne 0) { exit 1 }

# ---- interpreter ----
try { Copy-Item -LiteralPath $nexFile -Destination (Join-Path $rel 'nextdaad.nex') -Force }
catch { Fail "ERROR: could not copy interpreter $nexFile" }
Write-Host '  interpreter -> RELEASE\nextdaad.nex'

# ---- loader intro: INTRO.TXT into RELEASE\INTRO\ plus RELEASE\<GAME>.NEX ----
if (Test-Path -LiteralPath 'INTRO.TXT') {
    # introc.ps1 runs gfx2next from inside RELEASE\INTRO\, so GFX goes absolute.
    $gfxAbs = if ([IO.Path]::IsPathRooted($t.GFX)) { $t.GFX } else { Join-Path $kitRoot $t.GFX }
    $gfxAbs = [IO.Path]::GetFullPath($gfxAbs)
    if (-not (Test-Path -LiteralPath $gfxAbs)) { Fail "ERROR: gfx2next not found at $gfxAbs - install Gfx2Next, or set GFXDIR in CONFIG.BAT" }
    if (-not (Test-Path -LiteralPath $t.INTRONEX)) { Fail "ERROR: launcher $($t.INTRONEX) not found - the kit is incomplete" }
    # Preflight only the tool the script's MUSIC line needs.
    $mkind = ''
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $kitRoot 'INTRO.TXT'), [Text.Encoding]::GetEncoding(28591))) {
        if ($line -match '^\s*MUSIC\s+([^\s;"]+)') { $mkind = $Matches[1].ToUpperInvariant(); break }
    }
    switch ($mkind) {
        'AKY'    { if (-not (Test-Path -LiteralPath $t.S2A)) { Fail "ERROR: SongToAky not found at $($t.S2A) - MUSIC AKY needs Arkos Tracker 3 (ARKOSDIR in CONFIG.BAT)" } }
        'STREAM' { if (-not (Test-Path -LiteralPath $t.S2Y)) { Fail "ERROR: SongToYm not found at $($t.S2Y) - MUSIC STREAM needs Arkos Tracker 3 (ARKOSDIR in CONFIG.BAT)" } }
        'PCM'    { if (-not (Test-Path -LiteralPath $t.FFMPEG)) { Fail "ERROR: ffmpeg not found at $($t.FFMPEG) - MUSIC PCM needs ffmpeg (FFMPEGDIR in CONFIG.BAT)" } }
        'NDR'    { if (-not (Test-Path -LiteralPath $t.NDAWBIN)) { Fail "ERROR: NextDAW runtime player not found at $($t.NDAWBIN) - MUSIC NDR needs your NextDAW install (NEXTDAWDIR in CONFIG.BAT)" } }
    }
    Write-Host 'Compiling intro ...'
    $introParams = @{
        Script = 'INTRO.TXT'; Root = $kitRoot; Out = 'RELEASE\INTRO'; Cols = $cols; Gfx = $gfxAbs
        S2A = $t.S2A; S2Y = $t.S2Y; Ffmpeg = $t.FFMPEG; NdawBin = $t.NDAWBIN
        Palcheck = (Join-Path $lib 'palcheck.ps1'); Aysconv = (Join-Path $lib 'aysconv.ps1')
        Launcher = $t.INTRONEX; LauncherOut = "RELEASE\$game.NEX"
    }
    if ((Invoke-Stage 'introc.ps1' $introParams) -ne 0) { Fail 'ERROR: intro compile failed - see the message above' }
    Write-Host "  intro -> RELEASE\INTRO\ and RELEASE\$game.NEX (launch this file)"
}

# ---- convertible fonts: one source per slot; a ready-made FONT<n>.CHR wins ----
$fontExts = 'ch8', 'fon', 'psf', 'psfu', 'bdf', 'yaff', 'draw', 'spr', 'fnt'
$slots = @('') + @(1..9 | ForEach-Object { "$_" })
foreach ($slot in $slots) {
    $src = ''; $dup = ''
    foreach ($ext in $fontExts) {
        $cand = "FONT$slot.$ext"
        if (Test-Path -LiteralPath $cand) { if ($src) { $dup = $cand } else { $src = $cand } }
    }
    if ($dup) {
        Fail @("ERROR: both $src and $dup could be converted to FONT$slot.CHR.",
               '       Remove one, or convert it yourself and drop in a ready-made',
               "       FONT$slot.CHR, which always wins over a converted source.")
    }
    if ($src) {
        if ((Invoke-Stage 'fontconv.ps1' @{ In = $src; Out = "RELEASE\FONT$slot.CHR" }) -ne 0) { Fail "ERROR: fontconv failed converting $src" }
        Write-Host "  font $src -> RELEASE\FONT$slot.CHR (converted)"
    }
}

# ---- ready-made fonts, then pointers, staged as-is ----
# BUILD.BAT's copy /Y >nul was unchecked: a failure shows and the build goes on.
function Copy-AsIs([string]$Name, [string]$What, [string]$Note) {
    if (-not (Test-Path -LiteralPath $Name)) { return }
    Copy-Item -LiteralPath $Name -Destination (Join-Path $rel $Name) -Force -ErrorAction Continue
    Write-Host "  $What $Name -> RELEASE\$Name ($Note)"
}
foreach ($slot in $slots) { Copy-AsIs "FONT$slot.CHR" 'font' 'ready-made, staged as-is' }
foreach ($slot in $slots) { Copy-AsIs "POINTER$slot.SPR" 'pointer' 'ready-made, staged as-is' }

# ---- hints and extern ----
if (Test-Path -LiteralPath 'HINTS.TXT') {
    if ((Invoke-Stage 'hintpack.ps1' @{ In = 'HINTS.TXT'; Out = 'RELEASE\GAME.HNT' }) -ne 0) { Fail 'ERROR: hintpack failed - see the message above' }
    Write-Host '  hints HINTS.TXT -> RELEASE\GAME.HNT'
}
Copy-AsIs 'GAME.XBN' 'extern' 'staged as-is'

# ---- multi-part games: PART2..PART9, one .DSF each, other files staged as-is ----
foreach ($n in 2..9) {
    $part = "PART$n"
    if (-not (Test-Path -LiteralPath $part -PathType Container)) { continue }
    $pdsfs = @(Get-ChildItem -LiteralPath $part -File | Where-Object { $_.Name -match '(?i)\.DSF$' })
    if ($pdsfs.Count -eq 0) { continue }
    if ($pdsfs.Count -ne 1) { Fail "ERROR: PART$n\ has $($pdsfs.Count) .DSF files - keep exactly one game source per part folder" }
    $pgame = $pdsfs[0].BaseName
    Write-Host "Building part $n ($pgame) ..."
    if ((Invoke-Ddb "PART$n\$pgame" "RELEASE\GAME$n.DDB" "RELEASE\PART$n") -ne 0) { exit 1 }
    $count = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $part -File)) {
        if ($f.Extension -match '(?i)^\.DSF$') { continue }
        try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $rel "PART$n") -Force }
        catch { Fail "ERROR: could not stage PART$n\$($f.Name) into RELEASE\PART$n" }
        $count++
    }
    Write-Host "  $count asset(s) staged -> RELEASE\PART$n\"
}

Write-Host 'BUILD OK: RELEASE\ is ready to copy to an SD card'
if ((cfg 'RUN') -eq '1') {
    # BUILD.BAT exited 0 after RUN.BAT whatever it returned.
    $runScript = Join-Path $lib 'run.ps1'
    if (Test-Path -LiteralPath $runScript) {
        try { & $runScript | Out-Host } catch { Write-Host "ERROR: $($_.Exception.Message)" }
    }
}
exit 0
