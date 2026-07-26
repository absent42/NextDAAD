# NextDAAD authoring kit - video cutscene encode pass (NXV v2, SP15).
# Called by lib\video.bat (cwd = kit root) BEFORE its staging pass.
# Encodes VIDEO\NNN.mp4 -> VIDEO\NNN.vid via lib\videnc whenever the
# .vid is missing or older than its .mp4 (the .vid beside the source is
# the encode cache - BUILD.BAT wipes RELEASE\, not VIDEO\, so a slow
# encode runs once per source change, not once per build; delete the
# .vid by hand to force a re-encode after a CONFIG change). Shape and
# options come from CONFIG.BAT:
#   VIDASPECT   - shape for every encode: a preset (full 16:9 scope
#                 classic classic-wide), an explicit WIDTHxHEIGHT
#                 (width 256 or 320), or a bare display-aspect number
#                 (e.g. 2.35 -> a derived free height at 320 wide).
#                 Blank = full (320x256).
#   VIDFPS      - frames per second. Blank = 25 (the encoder default).
#   VIDOPTS     - extra videnc options for every encode.
#   VIDOPTS_NNN - extra options for video NNN only (3-digit number),
#                 appended AFTER VIDOPTS so later options win.
#   VIDPROFILE  - DEPRECATED v1 name, honored one release: n0-n4 map
#                 to the nearest v2 shape when VIDASPECT is blank.
# An infeasible encode is REFUSED by videnc's supply gates with a
# message naming the remedy (--stream-budget value, smaller shape,
# lower fps, --mono) - fix the config and rebuild. Requires ffmpeg
# (tools\ffmpeg\bin\ffmpeg.exe - see tools\README.txt); nothing here
# is needed unless numeric-named .mp4 files exist in VIDEO\.

$sources = @(Get-ChildItem 'VIDEO\*.mp4' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^\d+$' })
if (-not $sources) { exit 0 }

$work = $sources | Where-Object {
    $vid = [IO.Path]::ChangeExtension($_.FullName, 'vid')
    -not (Test-Path $vid) -or (Get-Item $vid).LastWriteTime -lt $_.LastWriteTime
}
if (-not $work) { exit 0 }

$ffmpeg = Join-Path $env:TOOLSDIR 'ffmpeg\bin\ffmpeg.exe'
if (-not (Test-Path $ffmpeg)) {
    Write-Host "ERROR: ffmpeg not found at $ffmpeg (needed to encode VIDEO\*.mp4)"
    Write-Host "       Download it - see tools\README.txt - or pre-encode to .vid"
    exit 1
}

# Encoder resolution: the standalone videnc.exe (SHIPPED with the kit -
# no Python needed, the normal authoring path) is preferred; the
# lib\videnc.py script (Python 3 + Pillow + numpy) is the fallback for
# anyone who has Python anyway or wants to modify the encoder.
# videnc.exe is probed in BOTH tool locations: the configured TOOLSDIR
# and the kit's own tools\ (a TOOLSDIR override - e.g. the maintainer's
# CONFIG.local.BAT pointing at the repo toolchain - must not hide the
# kit-slot exe). Python candidates are probed for PILLOW, not mere
# presence: py -3 and python can be different installs, and picking a
# Pillow-less one fails mid-encode.
$kitRoot = Split-Path -Parent $PSScriptRoot
$enc = $null
$exeCandidates = @(
    (Join-Path $env:TOOLSDIR 'videnc\videnc.exe'),
    (Join-Path $kitRoot 'tools\videnc\videnc.exe')
)
foreach ($exe in $exeCandidates) {
    # >1MB check: a clone made without git-lfs leaves a tiny text
    # POINTER file at this path, not the real (26MB) binary - skip it
    # and fall through to the Python script rather than "running" text.
    if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 1MB) { $enc = @($exe); break }
}
if (-not $enc) {
    foreach ($cand in @(@('py', '-3'), @('python'))) {
        try {
            & $cand[0] $cand[1..($cand.Length)] -c 'import PIL' *> $null
            if ($LASTEXITCODE -eq 0) { $enc = $cand + 'lib\videnc.py'; break }
        } catch {}
    }
}
if (-not $enc) {
    Write-Host 'ERROR: no encoder for VIDEO\*.mp4 - videnc.exe not found and no Python 3 with Pillow'
    Write-Host "       Easiest: download videnc.exe into $($exeCandidates[-1]) (see tools\README.txt)"
    Write-Host '       Or install Python 3 (https://www.python.org/) plus: pip install Pillow numpy'
    exit 1
}

# Shape resolution: VIDASPECT wins; a set-but-unmapped VIDPROFILE is a
# deprecation shim (v1 kit name, one release). Blank = the encoder's
# default shape (full, 320x256).
$shapeArgs = @()
$aspect = $env:VIDASPECT
if (-not $aspect -and $env:VIDPROFILE) {
    $map = @{ n0 = 'full'; n1 = 'classic'; n2 = 'classic-wide';
              n3 = '16:9'; n4 = 'scope'; auto = '' }
    $prof = $env:VIDPROFILE.ToLower()
    if ($map.ContainsKey($prof)) {
        $aspect = $map[$prof]
        Write-Host "  note: VIDPROFILE is deprecated (v1 profiles are gone) - using shape '$(if ($aspect) { $aspect } else { 'full' })'; set VIDASPECT instead"
    } else {
        Write-Host "ERROR: VIDPROFILE '$($env:VIDPROFILE)' unknown (and deprecated) - set VIDASPECT instead (see CONFIG.BAT)"
        exit 1
    }
}
if ($aspect) {
    if ($aspect -match '^\d+(\.\d+)?$') {
        $shapeArgs = @('--aspect', $aspect)   # bare number = display aspect, free height at 320 wide
    } else {
        $shapeArgs = @('--shape', $aspect)    # preset name or WIDTHxHEIGHT
    }
}
if ($env:VIDFPS) { $shapeArgs += @('--fps', $env:VIDFPS) }

# Extra options: VIDOPTS (every encode) then VIDOPTS_NNN (that video
# only) - appended after the shape args, so later options win (videnc
# takes the last occurrence of a repeated option). Whitespace-split;
# option values must not contain spaces (the ffmpeg path is separate).
$globalOpts = @()
if ($env:VIDOPTS) { $globalOpts = @($env:VIDOPTS -split '\s+' | Where-Object { $_ }) }

foreach ($src in $work) {
    $vid = [IO.Path]::ChangeExtension($src.FullName, 'vid')
    $num3 = '{0:D3}' -f [int]$src.BaseName
    $perOpts = @()
    $perRaw = [Environment]::GetEnvironmentVariable("VIDOPTS_$num3")
    if ($perRaw) { $perOpts = @($perRaw -split '\s+' | Where-Object { $_ }) }
    $desc = @($shapeArgs + $globalOpts + $perOpts) -join ' '
    if (-not $desc) { $desc = 'defaults: full 320x256 @25' }
    Write-Host "  encoding $($src.Name) -> $([IO.Path]::GetFileName($vid)) ($desc)"
    & $enc[0] $enc[1..($enc.Length)] $src.FullName $vid `
        --ffmpeg $ffmpeg @shapeArgs @globalOpts @perOpts
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: videnc failed on $($src.Name)"
        if (Test-Path $vid) { Remove-Item $vid -Force }
        exit 1
    }
}
exit 0
