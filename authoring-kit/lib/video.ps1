# NextDAAD authoring kit - video cutscene encode pass (SP14a NXV).
# Called by lib\video.bat (cwd = kit root) BEFORE its staging pass.
# Encodes VIDEO\NNN.mp4 -> VIDEO\NNN.vid via lib\videnc.py whenever the
# .vid is missing or older than its .mp4 (the .vid beside the source is
# the encode cache - BUILD.BAT wipes RELEASE\, not VIDEO\, so a slow
# encode runs once per source change, not once per build). Profile comes
# from VIDPROFILE in CONFIG.BAT (blank = auto). Requires Python 3 +
# Pillow and ffmpeg (tools\ffmpeg\bin\ffmpeg.exe - see tools\README.txt);
# neither is needed unless numeric-named .mp4 files exist in VIDEO\.

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

# Encoder resolution: the standalone videnc.exe (a NextDAAD release
# download - no Python needed, the normal authoring path) is preferred;
# the lib\videnc.py script (Python 3 + Pillow) is the fallback for
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
    Write-Host '       Or install Python 3 (https://www.python.org/) plus: pip install Pillow'
    exit 1
}

$vidProfile = if ($env:VIDPROFILE) { $env:VIDPROFILE } else { 'auto' }
foreach ($src in $work) {
    $vid = [IO.Path]::ChangeExtension($src.FullName, 'vid')
    Write-Host "  encoding $($src.Name) -> $([IO.Path]::GetFileName($vid)) (profile $vidProfile)"
    & $enc[0] $enc[1..($enc.Length)] $src.FullName $vid `
        --profile $vidProfile --ffmpeg $ffmpeg
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: videnc failed on $($src.Name)"
        if (Test-Path $vid) { Remove-Item $vid -Force }
        exit 1
    }
}
exit 0
