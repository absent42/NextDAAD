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

# Case-only name pairs are one file on Windows, two on Linux: refuse.
# tools\ and RELEASE\ are not author files.
$seenCi = @{}
foreach ($f in Get-ChildItem -LiteralPath $kitRoot -File -Recurse) {
    $relPath = $f.FullName.Substring($kitRoot.Length + 1)
    if ($relPath -match '^(RELEASE|tools)[\\/]') { continue }
    $k = ($relPath -replace '[\\/]', '/').ToUpperInvariant()
    if ($seenCi.ContainsKey($k)) { Fail "ERROR: $($seenCi[$k]) and $relPath differ only by case - keep one" }
    $seenCi[$k] = $relPath
}

# Native tools write to stderr; under Stop that would terminate 5.1.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap }
}
# Stage scripts run in-process; their exit N returns here as $LASTEXITCODE.
# Each starts at a fresh -File process's 'Continue'; stages wanting Stop set it.
function Invoke-Stage([string]$Script, [hashtable]$Params) {
    $ErrorActionPreference = 'Continue'
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
$dsfFile = Find-KitFile $kitRoot "$game.DSF"
if (-not $dsfFile) { Fail "ERROR: $game.DSF not found in this folder" }

$t = Resolve-KitTools $cfg $kitRoot
$drTarget = 'nextdaad'
$compress = cfg 'COMPRESS'
$cols = cfg 'COLS'
$nexFile = $t.NEXFILE

# ---- preflight ----
foreach ($need in @($t.NDRC, $nexFile)) {
    if (-not $need -or -not (Test-Path -LiteralPath $need)) { Fail "ERROR: required tool missing: $need" }
}
# Linux: an unzip that dropped every execute bit leaves a kit that cannot
# run its own compiler; say what to do instead of failing the banner check.
function Test-Executable([string]$Path) {
    if ($OnWindows) { return $true }
    # PWSH_MIN is 7.4, so GetUnixFileMode exists; no process spawn needed.
    $mode = [IO.File]::GetUnixFileMode($Path)
    # Runnable by the current user via owner, group or other execute bit -
    # a file owned by a different uid with g+x/o+x still runs.
    $x = [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute
    return (($mode -band $x) -ne 0)
}
foreach ($need in @($t.NDRC, $t.GFX)) {
    if ((Test-Path -LiteralPath $need -PathType Leaf) -and -not (Test-Executable $need)) {
        Fail "ERROR: $need is not executable - run: chmod +x build.sh run.sh clean.sh externs.sh vidtune.sh lib/ndrc tools/gfx2next/gfx2next"
    }
}
# BUILD.BAT judged "echo(banner | findstr": echo added the trailing space.
$banner = Get-NdrcBanner $t.NDRC
if (-not "$banner ".Contains("NDRC $($t.NDRCVER) ")) {
    Fail @('ERROR: wrong DAAD compiler version.', "  expected: NDRC $($t.NDRCVER)", "  found:    $banner", "  at:       $($t.NDRC)")
}
# Windows: the process is CSpect. Linux: it is mono, so match the command line.
function Test-CSpectRunning {
    if ($OnWindows) { return (@(Get-Process -Name CSpect -ErrorAction SilentlyContinue).Count -gt 0) }
    # First match only: usrmerge hosts list both /usr/bin/pgrep and /bin/pgrep.
    $pg = Get-Command pgrep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pg) { Write-Host 'note: pgrep not found - the running-CSpect check is skipped'; return $false }
    & $pg.Source -f 'CSpect\.exe' *> $null
    return ($LASTEXITCODE -eq 0)
}
if (Test-CSpectRunning) { Fail 'ERROR: CSpect is running - close it before building' }

# NDRC opens names verbatim, case-sensitively, from the cwd = kit root
# (include.c:197-208). #include: column 10 on, cut at ';', trimmed
# (include.c:121-139); #incbin: quoted token (sintactic.c:1349-1356).
function Test-DsfIncludes([string]$DsfPath) {
    $problems = @()
    $names = @()
    foreach ($line in [IO.File]::ReadAllLines($DsfPath, [Text.Encoding]::GetEncoding(28591))) {
        if ($line -cmatch '^#include\b') {
            $name = if ($line.Length -gt 9) { $line.Substring(9) } else { '' }
            $semi = $name.IndexOf(';'); if ($semi -ge 0) { $name = $name.Substring(0, $semi) }
            $name = $name.Trim()
            if ($name) { $names += , @($line, $name) }
        }
        # NDRC's lexer drops ';' to end of line before tokenising; cut here
        # too (unless the ';' is inside a quoted string) so a commented-out
        # #incbin is not linted.
        $code = $line; $inQuote = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            if ($line[$i] -eq '"') { $inQuote = -not $inQuote }
            elseif ($line[$i] -eq ';' -and -not $inQuote) { $code = $line.Substring(0, $i); break }
        }
        foreach ($m in [regex]::Matches($code, '#incbin\s+"([^"]*)"', 'IgnoreCase')) {
            $names += , @($line, $m.Groups[1].Value)
        }
    }
    foreach ($pair in $names) {
        $line = $pair[0]; $name = $pair[1]
        # Walk one path component at a time from the kit root: a wrong-case
        # FOLDER (not just the leaf) must be caught too. Report the first
        # component whose case differs.
        $parts = @(($name -replace '\\', '/').Split('/') | Where-Object { $_ })
        $cur = $kitRoot
        $mismatch = $null
        foreach ($part in $parts) {
            $entries = @(Get-ChildItem -LiteralPath $cur -ErrorAction SilentlyContinue)
            $exact = @($entries | Where-Object { $_.Name -ceq $part })
            if ($exact.Count -gt 0) { $cur = $exact[0].FullName; continue }
            $loose = @($entries | Where-Object { $_.Name -eq $part })
            if ($loose.Count -gt 0) { $mismatch = $loose[0].Name }
            break
        }
        if ($mismatch) { $problems += "$line -> on disk as $mismatch (case differs; Linux cannot open it)" }
        if ($name -match '\\') { $problems += "$line -> uses \ (Linux needs /)" }
    }
    return $problems
}
foreach ($p in (Test-DsfIncludes $dsfFile.FullName)) {
    if ($OnWindows) { Write-Host "WARNING: $p" } else { Fail "ERROR: $p" }
}

# ---- prepare RELEASE\ : outputs rebuilt every run are removed ----
# Pictures, sprite sets, audio and video are left to assets.ps1.
$rel = Join-Path $kitRoot 'RELEASE'
if (-not (Test-Path -LiteralPath $rel)) { New-Item -ItemType Directory $rel | Out-Null }

# assets.ps1 stamps outputs with 100 ns mtime ticks; a coarse filesystem
# (FAT, exFAT, 9p, drvfs) would rebuild everything or keep stale outputs.
function Test-MtimeResolution([string]$Dir) {
    $probe = Join-Path $Dir '.mtime-probe'
    try {
        [IO.File]::WriteAllBytes($probe, [byte[]]@(0))
        $want = New-Object DateTime (630000000001234567L), ([DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc($probe, $want)
        return ([IO.File]::GetLastWriteTimeUtc($probe).Ticks -eq $want.Ticks)
    } finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
}
if (-not (Test-MtimeResolution $rel)) { Fail "ERROR: $rel does not keep sub-microsecond file times - build on a local NTFS or ext4 folder, not a network, FAT or container bind mount" }
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
# $DsfPath is the resolved on-disk name (exact case, extension included):
# a hardcoded ".DSF" suffix would miss a lowercase-extension source on Linux.
function Invoke-Ddb([string]$DsfPath, [string]$DdbOut, [string]$XmbDir) {
    if (-not (Test-Path -LiteralPath $XmbDir)) { New-Item -ItemType Directory $XmbDir | Out-Null }
    Remove-Quiet '0.XMB'
    Remove-Quiet (Join-Path $XmbDir '0.XMB')
    # $ndrcArgs, not $args: $args is PowerShell's automatic variable.
    $ndrcArgs = @($drTarget, 'EN', $DsfPath, $DdbOut, '-v3', '-auto-tokens')
    if ($cols) { $ndrcArgs += "-cols=$cols" }
    $code = Invoke-Native $t.NDRC $ndrcArgs
    # Any non-zero code fails, negative Windows crash codes (0xC0000005) included.
    if ($code -ne 0) {
        Remove-Quiet $DdbOut
        Remove-Quiet '0.XMB'
        Write-Host "ERROR: ndrc failed compiling $DsfPath - see the message above"; return 1
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
if ((Invoke-Ddb $dsfFile.Name (Join-Path 'RELEASE' 'GAME.DDB') 'RELEASE') -ne 0) { exit 1 }

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
$introFile = Find-KitFile $kitRoot 'INTRO.TXT'
if ($introFile) {
    # introc.ps1 runs gfx2next from inside RELEASE\INTRO\, so GFX goes absolute.
    $gfxAbs = if ([IO.Path]::IsPathRooted($t.GFX)) { $t.GFX } else { Join-Path $kitRoot $t.GFX }
    $gfxAbs = [IO.Path]::GetFullPath($gfxAbs)
    if (-not (Test-Path -LiteralPath $gfxAbs)) { Fail "ERROR: gfx2next not found at $gfxAbs - install Gfx2Next, or set GFXDIR in CONFIG.BAT" }
    if (-not (Test-Path -LiteralPath $t.INTRONEX)) { Fail "ERROR: launcher $($t.INTRONEX) not found - the kit is incomplete" }
    # Preflight only the tool the script's MUSIC line needs.
    $mkind = ''
    foreach ($line in [IO.File]::ReadAllLines($introFile.FullName, [Text.Encoding]::GetEncoding(28591))) {
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
        Script = $introFile.FullName; Root = $kitRoot; Out = (Join-Path 'RELEASE' 'INTRO'); Cols = $cols; Gfx = $gfxAbs
        S2A = $t.S2A; S2Y = $t.S2Y; Ffmpeg = $t.FFMPEG; NdawBin = $t.NDAWBIN
        Palcheck = (Join-Path $lib 'palcheck.ps1'); Aysconv = (Join-Path $lib 'aysconv.ps1')
        Launcher = $t.INTRONEX; LauncherOut = (Join-Path 'RELEASE' "$game.NEX")
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
        $f = Find-KitFile $kitRoot $cand
        if ($f) { if ($src) { $dup = $f.Name } else { $src = $f.Name } }
    }
    if ($dup) {
        Fail @("ERROR: both $src and $dup could be converted to FONT$slot.CHR.",
               '       Remove one, or convert it yourself and drop in a ready-made',
               "       FONT$slot.CHR, which always wins over a converted source.")
    }
    if ($src) {
        if ((Invoke-Stage 'fontconv.ps1' @{ In = $src; Out = (Join-Path 'RELEASE' "FONT$slot.CHR") }) -ne 0) { Fail "ERROR: fontconv failed converting $src" }
        Write-Host "  font $src -> RELEASE\FONT$slot.CHR (converted)"
    }
}

# ---- ready-made fonts, then pointers, staged as-is ----
# BUILD.BAT's copy /Y >nul was unchecked: a failure shows and the build goes on.
function Copy-AsIs([string]$Name, [string]$What, [string]$Note) {
    $f = Find-KitFile $kitRoot $Name
    if (-not $f) { return }
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $rel $Name) -Force -ErrorAction Continue
    Write-Host "  $What $Name -> RELEASE\$Name ($Note)"
}
foreach ($slot in $slots) { Copy-AsIs "FONT$slot.CHR" 'font' 'ready-made, staged as-is' }
foreach ($slot in $slots) { Copy-AsIs "POINTER$slot.SPR" 'pointer' 'ready-made, staged as-is' }

# ---- hints and extern ----
$hintsFile = Find-KitFile $kitRoot 'HINTS.TXT'
if ($hintsFile) {
    if ((Invoke-Stage 'hintpack.ps1' @{ In = $hintsFile.Name; Out = (Join-Path 'RELEASE' 'GAME.HNT') }) -ne 0) { Fail 'ERROR: hintpack failed - see the message above' }
    Write-Host "  hints $($hintsFile.Name) -> RELEASE\GAME.HNT"
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
    # NDRC resolves this part's includes against the kit root too (the
    # process cwd), not PART$n\: the lint must match.
    foreach ($p in (Test-DsfIncludes $pdsfs[0].FullName)) {
        if ($OnWindows) { Write-Host "WARNING: $p" } else { Fail "ERROR: $p" }
    }
    if ((Invoke-Ddb (Join-Path $part $pdsfs[0].Name) (Join-Path 'RELEASE' "GAME$n.DDB") (Join-Path 'RELEASE' $part)) -ne 0) { exit 1 }
    $count = 0
    foreach ($f in Get-KitFiles $part '*') {
        if ($f.Extension -match '(?i)^\.DSF$') { continue }
        try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $rel "PART$n") -Force }
        catch {
            Fail "ERROR: could not stage PART$n\$($f.Name) into RELEASE\PART$n"
        }
        $count++
    }
    Write-Host "  $count asset(s) staged -> RELEASE\PART$n\"
}

Write-Host 'BUILD OK: RELEASE\ is ready to copy to an SD card'
if ((cfg 'RUN') -eq '1') {
    # BUILD.BAT exited 0 after RUN.BAT whatever it returned. On Windows a
    # failed run pauses so its error stays readable in a double-clicked console.
    $runScript = Join-Path $lib 'run.ps1'
    if (Test-Path -LiteralPath $runScript) {
        $global:LASTEXITCODE = 0
        $runCode = 0
        try { & $runScript | Out-Host; $runCode = $LASTEXITCODE } catch { Write-Host "ERROR: $($_.Exception.Message)"; $runCode = 1 }
        if ($runCode -ne 0 -and $OnWindows) { & cmd /c pause }
    }
}
exit 0
