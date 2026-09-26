# Converts and stages pictures, sprite sets, audio and video into RELEASE\,
# skipping outputs that are already current, then deletes any output of
# the stage that no source produced this run. Called by gfx.bat, audio.bat
# and video.bat with cwd = kit root.
#
# Current means: a copy whose size and modified time match its source, or
# a conversion whose modified time equals New-Stamp - the newest source
# time to the second, plus a fingerprint of every source and converter
# (name, size, time) in the sub-second digits. Editing or replacing a
# source, updating a converter or editing this script changes the stamp.
# Nothing but shipped files is written to RELEASE\.
param(
    [Parameter(Mandatory=$true)][ValidateSet('Pictures', 'Audio', 'Video')][string]$Stage,
    [string]$Gfx = '',
    [string]$Compress = '0',
    [string]$Game = '',
    [string]$S2A = '',
    [string]$S2Y = '',
    [string]$S2E = ''
)
$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$rel = Join-Path $root 'RELEASE'
$palcheck = Join-Path $PSScriptRoot 'palcheck.ps1'
$anipack = Join-Path $PSScriptRoot 'anipack.ps1'
$aysconv = Join-Path $PSScriptRoot 'aysconv.ps1'
$md5 = [System.Security.Cryptography.MD5]::Create()
$produced = @{}
$script:kept = 0

function Fail([string]$Message) {
    Write-Host "ERROR: $Message"
    exit 1
}

function Resolve-Tool([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $root $Path)
}

function Remove-IfExists([string]$Path) {
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
}

function Add-Produced([string]$Name) { $produced[$Name.ToUpperInvariant()] = $true }

function Get-Sig([string[]]$Paths) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $Paths) {
        $f = New-Object System.IO.FileInfo $p
        [void]$sb.Append($f.Name).Append('|').Append($f.Length).Append('|').Append($f.LastWriteTimeUtc.Ticks).Append(';')
    }
    return $sb.ToString()
}

# $Sig is Get-Sig over the stage's converters, computed once per stage.
function New-Stamp([string[]]$Sources, [string]$Sig) {
    $newest = 0L
    foreach ($p in $Sources) {
        $t = [System.IO.File]::GetLastWriteTimeUtc($p).Ticks
        if ($t -gt $newest) { $newest = $t }
    }
    $h = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Get-Sig $Sources) + $Sig))
    $fp = [long][BitConverter]::ToUInt32($h, 0) % 10000000L
    return (New-Object DateTime (($newest - $newest % 10000000L) + $fp), ([DateTimeKind]::Utc))
}

function Test-Current([string]$Out, [DateTime]$Stamp) {
    if (-not [System.IO.File]::Exists($Out)) { return $false }
    return ([System.IO.File]::GetLastWriteTimeUtc($Out).Ticks -eq $Stamp.Ticks)
}

# Copies $Src to RELEASE\$Name unless size and modified time already match.
# Returns $true when it copied.
function Copy-Staged([string]$Src, [string]$Name) {
    Add-Produced $Name
    $dst = Join-Path $rel $Name
    $s = New-Object System.IO.FileInfo $Src
    $d = New-Object System.IO.FileInfo $dst
    if ($d.Exists -and $d.Length -eq $s.Length -and $d.LastWriteTimeUtc -eq $s.LastWriteTimeUtc) {
        $script:kept++
        return $false
    }
    [System.IO.File]::Copy($Src, $dst, $true)
    [System.IO.File]::SetLastWriteTimeUtc($dst, $s.LastWriteTimeUtc)
    return $true
}

# Native stderr merged under 'Stop' becomes a terminating error in
# Windows PowerShell 5.1, so native calls run under 'Continue'.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [switch]$Quiet) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) { & $Exe @Arguments 2>&1 | Out-Null } else { & $Exe @Arguments | Out-Host }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
}

# Runs a kit script in-process; its own throw messages are the report.
function Invoke-KitScript([string]$Path, [hashtable]$Params) {
    try {
        & $Path @Params | Out-Host
        return $true
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Palcheck([string]$Path) { & $palcheck -Path $Path | Out-Host }

function Get-PngWidth([string]$Path) {
    $b = New-Object byte[] 24
    $fs = [System.IO.File]::OpenRead($Path)
    try { $n = $fs.Read($b, 0, 24) } finally { $fs.Dispose() }
    if ($n -lt 24) { return -1 }
    return (([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19])
}

# Deletes this stage's outputs that no source produced this run: removed
# sources, and the other name of a picture after a COMPRESS change.
function Remove-Orphans([string[]]$Patterns) {
    if (-not (Test-Path -LiteralPath $rel -PathType Container)) { return }
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $rel -File) {
        $owned = $false
        foreach ($p in $Patterns) { if ($f.Name -like $p) { $owned = $true } }
        if ($owned -and -not $produced.ContainsKey($f.Name.ToUpperInvariant())) {
            [System.IO.File]::Delete($f.FullName)
            $n++
        }
    }
    if ($n) { Write-Host "  $n file(s) with no source removed from RELEASE\" }
}

# ---- pictures ----
# gfx2next takes only an input path and writes <base>.nxi (<base>.nxi.zx0
# with -zx0) to the cwd, so each output is moved to its RELEASE\ name.
function Convert-Bitmap([System.IO.FileInfo]$Src, [string]$Name) {
    Add-Produced $Name
    $out = Join-Path $rel $Name
    $stamp = New-Stamp @($Src.FullName) $script:picSig
    if (Test-Current $out $stamp) { $script:kept++; return $false }
    $tmpRaw = Join-Path $root ($Src.BaseName + '.nxi')
    $tmp = $tmpRaw + $script:zsuf
    Remove-IfExists $tmpRaw; Remove-IfExists "$tmpRaw.zx0"
    $argv = @('-bitmap', '-pal-embed')
    if ($script:zsuf) { $argv += '-zx0' }
    $argv += $Src.FullName
    if ((Invoke-Native $script:gfxExe $argv -Quiet) -ne 0) {
        Remove-IfExists $tmpRaw; Remove-IfExists "$tmpRaw.zx0"
        Fail "gfx2next failed on $($Src.Name) - must be a paletted 8-bit PNG (max 256 colours)"
    }
    if (-not [System.IO.File]::Exists($tmp)) { Fail "gfx2next produced no output for $($Src.Name)" }
    Move-Item -LiteralPath $tmp -Destination $out -Force
    [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
    # Advisory; a ZX0 file has no readable palette.
    if (-not $script:zsuf) { Invoke-Palcheck $out }
    return $true
}

function Invoke-Pictures {
    $script:zsuf = ''
    if ($Compress -eq '1') { $script:zsuf = '.zx0' }
    $images = Join-Path $root 'IMAGES'
    $hasImages = Test-Path -LiteralPath $images -PathType Container
    $pointers = @('POINTER.png') + @(1..9 | ForEach-Object { "POINTER$_.png" })
    $pngNums = @{}
    $titleConverted = $false

    if (-not $hasImages) {
        Write-Host '  no IMAGES\ - skipping graphics'
    } else {
        $script:gfxExe = Resolve-Tool $Gfx
        if (-not (Test-Path -LiteralPath $script:gfxExe)) {
            Fail "gfx2next not found at $Gfx - install Gfx2Next, or set GFXDIR in CONFIG.BAT to an existing install"
        }
        $script:picSig = Get-Sig @($script:gfxExe, $PSCommandPath)

        # Numbered art: the first digit run in the name is the picture number.
        $count = 0
        foreach ($f in Get-ChildItem -LiteralPath $images -Filter *.png -File) {
            if ($f.Name -eq 'DAAD.png' -or $pointers -contains $f.Name) { continue }
            $m = [regex]::Match($f.BaseName, '\d+')
            if (-not $m.Success) { Fail "$($f.Name) - no picture number (expected a 320 or 256 wide PNG named with a picture number)" }
            $w = Get-PngWidth $f.FullName
            if ($w -eq 320) { $mode = 'NX2' } elseif ($w -eq 256) { $mode = 'NXI' } else {
                Fail "$($f.Name) - width $w (expected a 320 or 256 wide PNG named with a picture number)"
            }
            $num = '{0:D3}' -f [int]$m.Value
            $pngNums[$num] = $true
            $name = "$num.$mode$($script:zsuf)"
            if (Convert-Bitmap $f $name) {
                $count++
                Write-Host "  image $($f.Name) -> $name"
            }
        }
        Write-Host "  $count image(s) converted"

        # Title screen: same conversion, keeps the DAAD name.
        $titlePng = Join-Path $images 'DAAD.png'
        if (Test-Path -LiteralPath $titlePng -PathType Leaf) {
            $w = Get-PngWidth $titlePng
            if ($w -eq 320) { $mode = 'NX2' } elseif ($w -eq 256) { $mode = 'NXI' } else {
                Fail "DAAD.png - width $w (expected a 320 or 256 wide PNG)"
            }
            $name = "DAAD.$mode$($script:zsuf)"
            if (Convert-Bitmap (Get-Item -LiteralPath $titlePng) $name) { Write-Host "  title DAAD.png -> $name" }
            $titleConverted = $true
        }

        # Pointer art: raw 256-byte 16x16 pattern, rebuilt every run
        # (BUILD.BAT clears POINTER*.SPR so a kit-root .SPR can override it).
        # -pal-std is load-bearing: without it the bytes index a palette
        # nothing loads. Transparent source pixels are #FF00FF ($E3).
        foreach ($pn in $pointers) {
            $p = Join-Path $images $pn
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $base = [System.IO.Path]::GetFileNameWithoutExtension($pn)
            $tmp = Join-Path $root "$base.spr"
            Remove-IfExists $tmp
            if ((Invoke-Native $script:gfxExe @('-sprites', '-pal-std', '-pal-none', $p) -Quiet) -ne 0) {
                Remove-IfExists $tmp
                Fail "gfx2next failed on $pn - must be a paletted 8-bit 16x16 PNG"
            }
            if (-not [System.IO.File]::Exists($tmp)) { Fail "gfx2next produced no output for $pn" }
            # An oversized source exits 0 with several sprites concatenated.
            $size = (New-Object System.IO.FileInfo $tmp).Length
            if ($size -ne 256) {
                Remove-IfExists $tmp
                Fail "$pn converted to $size bytes, not 256 - the source must be exactly 16x16"
            }
            Move-Item -LiteralPath $tmp -Destination (Join-Path $rel "$base.SPR") -Force
            Write-Host "  pointer $pn -> RELEASE\$base.SPR (gfx2next -sprites -pal-std)"
        }

        # Sprite sets: NNN.png (raw PLTE indices via -pal-none, anipack does
        # the colour work) or a ready-made 8-bit NNN.spr, plus NNN.txt.
        $sprites = Join-Path $images 'SPRITES'
        if (Test-Path -LiteralPath $sprites -PathType Container) {
            $aniSig = Get-Sig @($script:gfxExe, $anipack, $PSCommandPath)
            $packed = 0
            $sheets = @(Get-ChildItem -LiteralPath $sprites -Filter *.png -File) + @(Get-ChildItem -LiteralPath $sprites -Filter *.spr -File)
            foreach ($f in $sheets) {
                $m = [regex]::Match($f.BaseName, '\d+')
                if (-not $m.Success -or [int]$m.Value -gt 254) { Fail "$($f.Name) - sprite files are named by set number, 000-254" }
                $num = '{0:D3}' -f [int]$m.Value
                $txt = Join-Path $sprites ($f.BaseName + '.txt')
                if (-not (Test-Path -LiteralPath $txt -PathType Leaf)) { Fail "$($f.Name) has no sidecar IMAGES\SPRITES\$($f.BaseName).txt" }
                $isPng = ($f.Extension -eq '.png')
                if ($isPng -and (Test-Path -LiteralPath (Join-Path $sprites ($f.BaseName + '.spr')) -PathType Leaf)) {
                    Fail "both $($f.BaseName).png and $($f.BaseName).spr exist in IMAGES\SPRITES - keep one"
                }
                $name = "$num.ANI"
                Add-Produced $name
                $out = Join-Path $rel $name
                $stamp = New-Stamp @($f.FullName, $txt) $aniSig
                if (Test-Current $out $stamp) { $script:kept++; continue }
                if ($isPng) {
                    $tmp = Join-Path $root ($f.BaseName + '.spr')
                    Remove-IfExists $tmp
                    if ((Invoke-Native $script:gfxExe @('-sprites', '-pal-none', $f.FullName) -Quiet) -ne 0) {
                        Remove-IfExists $tmp
                        Fail "gfx2next failed on $($f.Name) - must be a paletted 8-bit PNG"
                    }
                    if (-not [System.IO.File]::Exists($tmp)) { Fail "gfx2next produced no output for $($f.Name) - is the sheet at least 16x16?" }
                    try { $ok = Invoke-KitScript $anipack @{ Spr = $tmp; Txt = $txt; Out = $out; Png = $f.FullName } }
                    finally { Remove-IfExists $tmp }
                } else {
                    $ok = Invoke-KitScript $anipack @{ Spr = $f.FullName; Txt = $txt; Out = $out }
                }
                if (-not $ok) { Remove-IfExists $out; exit 1 }
                [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
                $packed++
            }
            Write-Host "  $packed sprite set(s) packed"
        }
    }

    # Ready-made title in the kit root, when IMAGES\DAAD.png did not convert.
    # Probe order matches the interpreter's (compressed variants first).
    if (-not $titleConverted) {
        foreach ($t in 'DAAD.NX2.ZX0', 'DAAD.N2Z', 'DAAD.NX2', 'DAAD.NXI.ZX0', 'DAAD.NXZ', 'DAAD.NXI') {
            $src = Join-Path $root $t
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
            if (Copy-Staged $src $t) {
                if ($t -eq 'DAAD.NX2' -or $t -eq 'DAAD.NXI') { Invoke-Palcheck (Join-Path $rel $t) }
                Write-Host "  title $t -> RELEASE\$t (ready-made, staged as-is)"
            }
            break
        }
    }

    # Ready-made numbered pictures in IMAGES\: probed in the interpreter's
    # gfxExtTab order (src\overlay2.asm), one file per number, and an
    # IMAGES\NNN.png of the same number wins.
    if ($hasImages) {
        $done = @{}
        foreach ($ext in 'NX2.ZX0', 'N2Z', 'NX2', 'NXI.ZX0', 'NXZ', 'NXI') {
            foreach ($f in Get-ChildItem -LiteralPath $images -Filter "*.$ext" -File) {
                $rmNum = $f.Name.Split('.')[0]
                if ($rmNum -notmatch '^[0-9]{1,3}$') {
                    Fail "IMAGES\$($f.Name) - not a picture number (a ready-made picture is NNN.NX2 or NNN.NXI, or a compressed NNN.NX2.ZX0/NNN.N2Z/NNN.NXI.ZX0/NNN.NXZ; a ready-made title screen belongs in the kit folder root as DAAD.*)"
                }
                $num = '{0:D3}' -f [int]$rmNum
                if ($done.ContainsKey($num)) { continue }
                $done[$num] = $true
                if ($pngNums.ContainsKey($num)) { continue }
                $name = "$num.$ext"
                if (Copy-Staged $f.FullName $name) {
                    if ($ext -eq 'NX2' -or $ext -eq 'NXI') { Invoke-Palcheck (Join-Path $rel $name) }
                    Write-Host "  picture $($f.Name) -> RELEASE\$name (ready-made, staged as-is)"
                }
            }
        }
    }
}

# ---- audio ----
# SongToAky encodes at 0xD800; the song slot holds 10208 bytes.
function Convert-Aky([string]$Src, [string]$Name) {
    Add-Produced $Name
    $out = Join-Path $rel $Name
    $stamp = New-Stamp @($Src) $script:akySig
    if (Test-Current $out $stamp) { $script:kept++; return $false }
    $srcName = [System.IO.Path]::GetFileName($Src)
    if ((Invoke-Native $script:s2aExe @('-bin', '--encodingAddress', '0xD800', $Src, $out)) -ne 0) {
        Remove-IfExists $out
        Fail "SongToAky failed on $srcName - the tune may be too large for the song slot (max 10208 bytes encoded at 0xD800)"
    }
    if (-not [System.IO.File]::Exists($out)) { Fail "SongToAky produced no output for $srcName" }
    $len = (New-Object System.IO.FileInfo $out).Length
    if ($len -gt 10208) {
        Remove-IfExists $out
        Fail "$Name is $len bytes, over the 10208 song limit"
    }
    [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
    return $true
}

function Invoke-Audio {
    $audio = Join-Path $root 'AUDIO'
    if (-not (Test-Path -LiteralPath $audio -PathType Container)) {
        Write-Host '  no AUDIO\ - skipping audio'
        return
    }

    # Samples: NNN.wav (PCM mono 8-bit) copied as-is.
    foreach ($f in Get-ChildItem -LiteralPath $audio -Filter *.wav -File) {
        if ($f.BaseName -notmatch '^[0-9]+$') { continue }
        $num = '{0:D3}' -f [int]$f.BaseName
        if (Copy-Staged $f.FullName "$num.WAV") { Write-Host "  sample $num -> $num.WAV" }
    }

    # Name tests are case-sensitive, as the findstr tests they replace were.
    $aks = @(Get-ChildItem -LiteralPath $audio -Filter *.aks -File)
    $hasAky = @($aks | Where-Object { $_.BaseName -cnotmatch '^STREAM_' }).Count -gt 0
    if ($hasAky) {
        $script:s2aExe = Resolve-Tool $S2A
        if (-not (Test-Path -LiteralPath $script:s2aExe)) {
            Fail "SongToAky not found at $S2A - install Arkos Tracker 3, or set ARKOSDIR in CONFIG.BAT to an existing install"
        }
        $script:akySig = Get-Sig @($script:s2aExe, $PSCommandPath)
        $music = Join-Path $audio "$Game.aks"
        if (Test-Path -LiteralPath $music -PathType Leaf) {
            if (Convert-Aky $music 'GAME.AKY') { Write-Host '  music -> GAME.AKY' }
        }
        foreach ($f in $aks) {
            if ($f.BaseName -cnotmatch '^[0-9]+$') { continue }
            $num = '{0:D3}' -f [int]$f.BaseName
            if (Convert-Aky $f.FullName "$num.AKY") { Write-Host "  song $num -> $num.AKY" }
        }
    }

    # Streamed songs: STREAM_NNN.aks -> NNN.AYS via aysconv.ps1 (SongToYm).
    # Every stream is attempted before a failure stops the build.
    $streams = @($aks | Where-Object { $_.BaseName -like 'STREAM_*' })
    if ($streams.Count -gt 0) {
        $s2yExe = Resolve-Tool $S2Y
        if (-not (Test-Path -LiteralPath $s2yExe)) {
            Fail "SongToYm not found at $S2Y - install Arkos Tracker 3, or set ARKOSDIR in CONFIG.BAT to an existing install"
        }
        if (-not (Test-Path -LiteralPath $aysconv)) { Fail "$aysconv missing - kit installation is incomplete" }
        $aysSig = Get-Sig @($s2yExe, $aysconv, $PSCommandPath)
        $failed = $false
        foreach ($f in $streams) {
            if ($f.BaseName -cnotmatch '^STREAM_[0-9]+$') { continue }
            $num = '{0:D3}' -f [int]$f.BaseName.Substring(7)
            $name = "$num.AYS"
            Add-Produced $name
            $out = Join-Path $rel $name
            $stamp = New-Stamp @($f.FullName) $aysSig
            if (Test-Current $out $stamp) { $script:kept++; continue }
            if (Invoke-KitScript $aysconv @{ Song = $f.FullName; Out = "RELEASE\$name"; SongToYm = $s2yExe }) {
                [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
                Write-Host "  stream $num -> $name"
            } else {
                Write-Host "ERROR: aysconv.ps1 failed on $($f.Name)"
                Remove-IfExists $out
                $failed = $true
            }
        }
        if ($failed) { exit 1 }
    }

    # Effects bank: <GAME>_FX.aks -> GAME.SFB at 0xD000, 2048 bytes max.
    # Non-fatal: a skipped bank leaves no GAME.SFB.
    $fx = Join-Path $audio "$($Game)_FX.aks"
    if (Test-Path -LiteralPath $fx -PathType Leaf) {
        $s2eExe = Resolve-Tool $S2E
        if (-not (Test-Path -LiteralPath $s2eExe)) {
            Write-Host '  WARNING: SongToSoundEffects not found - effects bank skipped'
            return
        }
        $out = Join-Path $rel 'GAME.SFB'
        $stamp = New-Stamp @($fx) (Get-Sig @($s2eExe, $PSCommandPath))
        if (Test-Current $out $stamp) {
            Add-Produced 'GAME.SFB'
            $script:kept++
            return
        }
        if ((Invoke-Native $s2eExe @('-bin', '--encodingAddress', '0xD000', $fx, $out)) -ne 0) {
            Write-Host '  WARNING: effects bank skipped - SongToSoundEffects failed (recipe not yet pinned)'
            Remove-IfExists $out
            return
        }
        if (-not [System.IO.File]::Exists($out)) { return }
        $len = (New-Object System.IO.FileInfo $out).Length
        if ($len -gt 2048) {
            Write-Host "  WARNING: GAME.SFB is $len bytes, over the 2048 limit - dropped"
            Remove-IfExists $out
            return
        }
        [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
        Add-Produced 'GAME.SFB'
        Write-Host '  effects -> GAME.SFB'
    }
}

# ---- video: VIDEO\NNN.vid (encoded by video.ps1 or supplied) copied as-is ----
function Invoke-Video {
    $video = Join-Path $root 'VIDEO'
    if (-not (Test-Path -LiteralPath $video -PathType Container)) {
        Write-Host '  no VIDEO\ - skipping video cutscenes'
        return
    }
    foreach ($f in Get-ChildItem -LiteralPath $video -Filter *.vid -File) {
        if ($f.BaseName -notmatch '^[0-9]+$') { continue }
        $num = '{0:D3}' -f [int]$f.BaseName
        if (Copy-Staged $f.FullName "$num.VID") { Write-Host "  video $num -> $num.VID" }
    }
}

try {
    if (-not (Test-Path -LiteralPath $rel -PathType Container)) { Fail 'RELEASE\ does not exist - run BUILD.BAT' }
    switch ($Stage) {
        'Pictures' { Invoke-Pictures; $owned = @('*.NX2', '*.NXI', '*.ZX0', '*.N2Z', '*.NXZ', '*.ANI'); $what = 'picture' }
        'Audio'    { Invoke-Audio;    $owned = @('*.WAV', '*.AKY', '*.AYS', 'GAME.SFB'); $what = 'audio' }
        'Video'    { Invoke-Video;    $owned = @('*.VID'); $what = 'video' }
    }
    if ($script:kept) { Write-Host "  $($script:kept) $what file(s) unchanged, kept" }
    Remove-Orphans $owned
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
exit 0
