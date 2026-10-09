# Converts and stages pictures, sprite sets, audio and video into RELEASE\,
# skipping outputs that are already current, then deletes any output of
# the stage that no source produced this run. Called by build.ps1
# with cwd = kit root.
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
. (Join-Path $PSScriptRoot 'kitplatform.ps1')

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

function Get-PngHeight([string]$Path) {
    $b = New-Object byte[] 24
    $fs = [System.IO.File]::OpenRead($Path)
    try { $n = $fs.Read($b, 0, 24) } finally { $fs.Dispose() }
    if ($n -lt 24) { return -1 }
    return (([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23])
}

# IMAGES\NNN.txt beside a numbered PNG: key=value lines, ; comments.
#   at=X,Y | at=window     required
#   palette=F-L | none     optional, default 0-255; none = apply nothing (1-0)
#   mode=256 | 320         optional
function Read-PosSidecar([string]$Txt) {
    $keys = @{}
    foreach ($line in (Get-Content -LiteralPath $Txt -Encoding UTF8)) {
        $l = ($line -replace ';.*$', '').Trim()
        if ($l -eq '') { continue }
        if ($l -notmatch '^(\w+)\s*=\s*(.+)$') { Fail "$Txt - cannot parse '$line'" }
        $keys[$Matches[1].ToLower()] = $Matches[2].Trim()
    }
    foreach ($k in $keys.Keys) {
        if ($k -notin 'at', 'palette', 'mode') { Fail "$Txt - unknown key '$k' (allowed: at, palette, mode)" }
    }
    if (-not $keys.ContainsKey('at')) { Fail "$Txt - 'at' is required (at=X,Y or at=window)" }
    $pos = @{ Float = $false; X = 0; Y = 0; PalFirst = 0; PalLast = 255; Mode = $null }
    $at = $keys['at']
    if ($at -eq 'window') { $pos.Float = $true }
    elseif ($at -match '^(\d{1,4})\s*,\s*(\d{1,4})$') {
        $pos.X = [int]$Matches[1]; $pos.Y = [int]$Matches[2]
        if ($pos.X -gt 319 -or $pos.Y -gt 255) { Fail "$Txt - at= X must be 0-319 and Y 0-255" }
    } else { Fail "$Txt - at= must be X,Y or window (got '$at')" }
    if ($keys.ContainsKey('palette')) {
        $pal = $keys['palette']
        if ($pal -eq 'none') { $pos.PalFirst = 1; $pos.PalLast = 0 }
        elseif ($pal -match '^(\d{1,4})\s*-\s*(\d{1,4})$' -and [int]$Matches[1] -le 255 -and [int]$Matches[2] -le 255) {
            $pos.PalFirst = [int]$Matches[1]; $pos.PalLast = [int]$Matches[2]
        } else { Fail "$Txt - palette= must be F-L with both 0-255, or none (got '$pal')" }
    }
    if ($keys.ContainsKey('mode')) {
        if ($keys['mode'] -ne '256' -and $keys['mode'] -ne '320') { Fail "$Txt - mode= must be 256 or 320" }
        $pos.Mode = [int]$keys['mode']
    }
    return $pos
}

# The 16-byte NXP header (manual/reference/picture-format.md, NXP section).
function New-NxpHeader([hashtable]$Pos, [int]$Mode, [int]$W, [int]$H, [string]$Who = '') {
    if ($Who) { $Who = "$Who - " }
    $sw = if ($Mode -eq 1) { 320 } else { 256 }
    $sh = if ($Mode -eq 1) { 256 } else { 192 }
    if ($W -lt 1 -or $W -gt $sw -or $H -lt 1 -or $H -gt $sh) { Fail "${Who}${W}x${H} does not fit the $sw x $sh screen" }
    if (-not $Pos.Float -and ($Pos.X + $W -gt $sw -or $Pos.Y + $H -gt $sh)) { Fail "${Who}at=$($Pos.X),$($Pos.Y) + ${W}x${H} does not fit the $sw x $sh screen" }
    $hdr = New-Object byte[] 16
    $hdr[0] = 0x4E; $hdr[1] = 0x58; $hdr[2] = 0x50; $hdr[3] = 1
    $hdr[4] = [byte]$Mode
    $hdr[5] = if ($Pos.Float) { 1 } else { 0 }
    $hdr[6] = [byte]($Pos.X -band 0xFF); $hdr[7] = [byte]($Pos.X -shr 8)
    $hdr[8] = [byte]$Pos.Y
    $hdr[9] = [byte]($W -band 0xFF); $hdr[10] = [byte]($W -shr 8)
    $hdr[11] = [byte]($H -band 0xFF)        # 256 -> 0
    $hdr[12] = [byte]$Pos.PalFirst; $hdr[13] = [byte]$Pos.PalLast
    return $hdr
}

# Deletes this stage's outputs that no source produced this run: removed
# sources, and the other name of a picture after a COMPRESS change.
function Remove-Orphans([string[]]$Patterns) {
    if (-not (Test-Path -LiteralPath $rel -PathType Container)) { return }
    $n = 0
    foreach ($f in Get-KitFiles $rel '*') {
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
# gfx2next gets a bare dstfile, written to the cwd (kit root) on both hosts:
# Windows drops a dst directory, Linux writes beside the source without a
# dst. -zx0 appends .zx0. Each output is moved to its RELEASE\ name.
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
    $argv += @($Src.FullName, [System.IO.Path]::GetFileName($tmpRaw))
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

# Positioned picture: gfx2next payload as Convert-Bitmap makes it, with the
# 16-byte NXP header in front. The header is never compressed.
function Convert-Positioned([System.IO.FileInfo]$Src, [string]$Txt, [string]$Name, [int]$Mode) {
    Add-Produced $Name
    $out = Join-Path $rel $Name
    $stamp = New-Stamp @($Src.FullName, $Txt) ($script:picSig + "|m$Mode")
    if (Test-Current $out $stamp) { $script:kept++; return $false }
    $pos = Read-PosSidecar $Txt
    $w = Get-PngWidth $Src.FullName; $ht = Get-PngHeight $Src.FullName
    if ($w -lt 1 -or $ht -lt 1) { Fail "$($Src.Name) - not a PNG" }
    $hdr = New-NxpHeader $pos $Mode $w $ht "$($Src.Name) + $([System.IO.Path]::GetFileName($Txt))"
    $tmpRaw = Join-Path $root ($Src.BaseName + '.nxi')
    $tmp = $tmpRaw + $script:zsuf
    Remove-IfExists $tmpRaw; Remove-IfExists "$tmpRaw.zx0"
    $argv = @('-bitmap', '-pal-embed')
    if ($script:zsuf) { $argv += '-zx0' }
    $argv += @($Src.FullName, [System.IO.Path]::GetFileName($tmpRaw))
    if ((Invoke-Native $script:gfxExe $argv -Quiet) -ne 0) {
        Remove-IfExists $tmpRaw; Remove-IfExists "$tmpRaw.zx0"
        Fail "gfx2next failed on $($Src.Name) - must be a paletted 8-bit PNG (max 256 colours)"
    }
    if (-not [System.IO.File]::Exists($tmp)) { Fail "gfx2next produced no output for $($Src.Name)" }
    $payload = [System.IO.File]::ReadAllBytes($tmp)
    Remove-IfExists $tmp
    if (-not $script:zsuf -and $payload.Length -ne (512 + $w * $ht)) { Fail "$($Src.Name) - gfx2next wrote $($payload.Length) bytes, expected $(512 + $w * $ht)" }
    $all = New-Object byte[] (16 + $payload.Length)
    [Array]::Copy($hdr, 0, $all, 0, 16)
    [Array]::Copy($payload, 0, $all, 16, $payload.Length)
    [System.IO.File]::WriteAllBytes($out, $all)
    [System.IO.File]::SetLastWriteTimeUtc($out, $stamp)
    if (-not $script:zsuf) { Invoke-Palcheck $out }
    return $true
}

# Ready-made NXP: header sanity; returns the mode byte. Mode -1 skips the game-mode comparison.
function Test-NxpReadyMade([string]$Path, [int]$Mode, [bool]$Compressed) {
    $b = New-Object byte[] 16
    $fs = [System.IO.File]::OpenRead($Path)
    try { $n = $fs.Read($b, 0, 16); $len = $fs.Length } finally { $fs.Dispose() }
    $name = Split-Path $Path -Leaf
    if ($n -lt 16 -or $b[0] -ne 0x4E -or $b[1] -ne 0x58 -or $b[2] -ne 0x50) { Fail "IMAGES\$name - not an NXP file (no NXP magic)" }
    if ($b[3] -ne 1) { Fail "IMAGES\$name - NXP version $($b[3]) is not 1" }
    if ($b[4] -gt 1) { Fail "IMAGES\$name - NXP mode byte $($b[4]) is not 0 or 1" }
    if ($Mode -ge 0 -and $b[4] -ne $Mode) { Fail "IMAGES\$name - NXP mode $(if ($b[4]) {320} else {256}) but the game is $(if ($Mode) {320} else {256})-mode" }
    $w = [int]$b[9] -bor ([int]$b[10] -shl 8); $ht = [int]$b[11]; if ($ht -eq 0) { $ht = 256 }
    if (-not $Compressed -and $len -ne (16 + 512 + $w * $ht)) { Fail "IMAGES\$name - $len bytes, header says $(16 + 512 + $w * $ht)" }
    return [int]$b[4]
}

# Game-wide Layer 2 mode: 1 = 320x256, 0 = 256x192. First speaker wins.
function Set-GameMode([int]$M, [string]$Who) {
    if ($null -eq $script:gameMode) { $script:gameMode = $M; $script:modeFrom = $Who; return }
    if ($script:gameMode -ne $M) { Fail "$Who is $(if ($M) {320} else {256})-mode but $script:modeFrom fixed the game at $(if ($script:gameMode) {320} else {256}) - one Layer 2 mode per game" }
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

        # Positioned pictures: NNN.txt beside NNN.png (Read-PosSidecar) or a
        # ready-made NNN.NXP. Only such a game decides one Layer 2 mode; the
        # voters are plain location art, sidecar mode= keys and NXP mode
        # bytes. The title does not vote. No vote => 256.
        $script:gameMode = $null; $script:modeFrom = ''
        $posPngs = @{}
        foreach ($f in Get-KitFiles $images 'png') {
            if ($f.Name -eq 'DAAD.png' -or $pointers -contains $f.Name) { continue }
            $txt = Join-Path $images ($f.BaseName + '.txt')
            if (Test-Path -LiteralPath $txt -PathType Leaf) { $posPngs[$f.Name] = $txt }
        }
        $nxpFiles = @()
        foreach ($ext in 'NXP.ZX0', 'NPZ', 'NXP') {
            foreach ($f in Get-KitFiles $images ([regex]::Escape($ext))) { $nxpFiles += , @($f, ($ext -ne 'NXP')) }
        }
        if ($posPngs.Count -gt 0 -or $nxpFiles.Count -gt 0) {
            foreach ($f in Get-KitFiles $images 'png') {
                if ($f.Name -eq 'DAAD.png' -or $pointers -contains $f.Name -or $posPngs.ContainsKey($f.Name)) { continue }
                $pw = Get-PngWidth $f.FullName
                if ($pw -eq 320) { Set-GameMode 1 $f.Name } elseif ($pw -eq 256) { Set-GameMode 0 $f.Name }
            }
            foreach ($ext in 'NX2.ZX0', 'N2Z', 'NX2') { foreach ($f in Get-KitFiles $images ([regex]::Escape($ext))) { Set-GameMode 1 $f.Name } }
            foreach ($ext in 'NXI.ZX0', 'NXZ', 'NXI') { foreach ($f in Get-KitFiles $images ([regex]::Escape($ext))) { Set-GameMode 0 $f.Name } }
            foreach ($png in $posPngs.Keys) {
                $sc = Read-PosSidecar $posPngs[$png]
                if ($null -ne $sc.Mode) { Set-GameMode $(if ($sc.Mode -eq 320) {1} else {0}) $png }
            }
            foreach ($nf in $nxpFiles) { Set-GameMode (Test-NxpReadyMade $nf[0].FullName -1 $nf[1]) $nf[0].Name }
            # A picture-number sidecar (digit run in the name) needs its PNG.
            foreach ($t in Get-KitFiles $images 'txt') {
                if ($t.BaseName -notmatch '\d') { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $images ($t.BaseName + '.png')) -PathType Leaf)) {
                    Fail "IMAGES\$($t.Name) has no $($t.BaseName).png beside it - a picture sidecar needs its PNG"
                }
            }
            if ($null -eq $script:gameMode) { $script:gameMode = 0 }
        }

        # Numbered art: the first digit run in the name is the picture number.
        $count = 0
        foreach ($f in Get-KitFiles $images 'png') {
            if ($f.Name -eq 'DAAD.png' -or $pointers -contains $f.Name) { continue }
            $m = [regex]::Match($f.BaseName, '\d+')
            if (-not $m.Success) { Fail "$($f.Name) - no picture number (expected a 320 or 256 wide PNG named with a picture number)" }
            if ($posPngs.ContainsKey($f.Name)) {
                $num = '{0:D3}' -f [int]$m.Value
                $pngNums[$num] = $true
                $name = "$num.NXP$($script:zsuf)"
                if (Convert-Positioned $f $posPngs[$f.Name] $name $script:gameMode) { $count++; Write-Host "  image $($f.Name) + $($f.BaseName).txt -> $name" }
                continue
            }
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
            if ((Invoke-Native $script:gfxExe @('-sprites', '-pal-std', '-pal-none', $p, "$base.spr") -Quiet) -ne 0) {
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
            $sheets = @(Get-KitFiles $sprites 'png') + @(Get-KitFiles $sprites 'spr')
            foreach ($f in $sheets) {
                $m = [regex]::Match($f.BaseName, '\d+')
                if (-not $m.Success -or [int]$m.Value -gt 254) { Fail "$($f.Name) - sprite files are named by set number, 000-254" }
                $num = '{0:D3}' -f [int]$m.Value
                $txt = Join-Path $sprites ($f.BaseName + '.txt')
                if (-not (Test-Path -LiteralPath $txt -PathType Leaf)) {
                    Fail "$($f.Name) has no sidecar IMAGES\SPRITES\$($f.BaseName).txt"
                }
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
                    if ((Invoke-Native $script:gfxExe @('-sprites', '-pal-none', $f.FullName, ($f.BaseName + '.spr')) -Quiet) -ne 0) {
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
        foreach ($ext in 'NXP.ZX0', 'NPZ', 'NXP', 'NX2.ZX0', 'N2Z', 'NX2', 'NXI.ZX0', 'NXZ', 'NXI') {
            foreach ($f in Get-KitFiles $images ([regex]::Escape($ext))) {
                $rmNum = $f.Name.Split('.')[0]
                if ($rmNum -notmatch '^[0-9]{1,3}$') {
                    Fail "IMAGES\$($f.Name) - not a picture number (a ready-made picture is NNN.NX2, NNN.NXI or NNN.NXP, or a compressed NNN.NX2.ZX0/NNN.N2Z/NNN.NXI.ZX0/NNN.NXZ/NNN.NXP.ZX0/NNN.NPZ; a ready-made title screen belongs in the kit folder root as DAAD.*)"
                }
                $num = '{0:D3}' -f [int]$rmNum
                if ($done.ContainsKey($num)) { continue }
                $done[$num] = $true
                if ($pngNums.ContainsKey($num)) { continue }
                $name = "$num.$ext"
                if ($ext -like 'NXP*' -or $ext -eq 'NPZ') { [void](Test-NxpReadyMade $f.FullName $script:gameMode ($ext -ne 'NXP')) }
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
    foreach ($f in Get-KitFiles $audio 'wav') {
        if ($f.BaseName -notmatch '^[0-9]+$') { continue }
        $num = '{0:D3}' -f [int]$f.BaseName
        if (Copy-Staged $f.FullName "$num.WAV") { Write-Host "  sample $num -> $num.WAV" }
    }

    # Name tests are case-sensitive, as the findstr tests they replace were.
    $aks = @(Get-KitFiles $audio 'aks')
    $hasAky = @($aks | Where-Object { $_.BaseName -cnotmatch '^STREAM_' }).Count -gt 0
    if ($hasAky) {
        $script:s2aExe = Resolve-Tool $S2A
        if (-not (Test-Path -LiteralPath $script:s2aExe)) {
            Fail "SongToAky not found at $S2A - install Arkos Tracker 3, or set ARKOSDIR in CONFIG.BAT to an existing install"
        }
        $script:akySig = Get-Sig @($script:s2aExe, $PSCommandPath)
        $music = $aks | Where-Object { $_.Name -eq "$Game.aks" } | Select-Object -First 1
        if ($music) {
            if (Convert-Aky $music.FullName 'GAME.AKY') { Write-Host '  music -> GAME.AKY' }
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
            if (Invoke-KitScript $aysconv @{ Song = $f.FullName; Out = (Join-Path 'RELEASE' $name); SongToYm = $s2yExe }) {
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
    $fx = $aks | Where-Object { $_.Name -eq "$($Game)_FX.aks" } | Select-Object -First 1
    if ($fx) {
        $s2eExe = Resolve-Tool $S2E
        if (-not (Test-Path -LiteralPath $s2eExe)) {
            Write-Host '  WARNING: SongToSoundEffects not found - effects bank skipped'
            return
        }
        $out = Join-Path $rel 'GAME.SFB'
        $stamp = New-Stamp @($fx.FullName) (Get-Sig @($s2eExe, $PSCommandPath))
        if (Test-Current $out $stamp) {
            Add-Produced 'GAME.SFB'
            $script:kept++
            return
        }
        if ((Invoke-Native $s2eExe @('-bin', '--encodingAddress', '0xD000', $fx.FullName, $out)) -ne 0) {
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
    foreach ($f in Get-KitFiles $video 'vid') {
        if ($f.BaseName -notmatch '^[0-9]+$') { continue }
        $num = '{0:D3}' -f [int]$f.BaseName
        if (Copy-Staged $f.FullName "$num.VID") { Write-Host "  video $num -> $num.VID" }
    }
}

try {
    if (-not (Test-Path -LiteralPath $rel -PathType Container)) { Fail 'RELEASE\ does not exist - run BUILD.BAT' }
    switch ($Stage) {
        'Pictures' { Invoke-Pictures; $owned = @('*.NX2', '*.NXI', '*.ZX0', '*.N2Z', '*.NXZ', '*.NXP', '*.NPZ', '*.ANI'); $what = 'picture' }
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
