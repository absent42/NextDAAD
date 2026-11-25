# tests\fragcard.ps1 - write one raw NXV clip to an SD card in several runs (a fragmented copy).
#
#   pwsh -File tests\fragcard.ps1 -Drive E: -Source <clip.VID> -Dest <path on the card> -Runs 4 [-WhatIf]
#
# Meant for a FRESHLY FORMATTED card. The clip is split into -Runs chunks, each a whole number of
# the volume's clusters. Each chunk is appended to -Dest (flushed, closed); after every chunk but
# the last a 1-byte pin file FRAGPINn.TMP is written beside it, so the cluster after the clip's
# tail is taken and the next append cannot be adjacent. When the last chunk is written the pin
# files are deleted and -Dest is compared with -Source byte for byte.
# Assumption: each pin lands in the cluster after the clip's tail. That holds on a freshly
# formatted card, not always on a card with free holes earlier on. The run count is verified on
# the Next (RUNS= on the DEBUG report), not by this script.
# Before writing it walks the clip's frames (sound sectors, a palette sector when the frame's tag
# byte is 1, pixel sectors) and moves chunk boundaries by whole clusters until at least one falls
# strictly inside a frame's pixel sectors; it refuses if none can.
# Refuses: a drive that is not Removable, -Runs outside 2..8, an existing -Dest, a pin file
# that already exists, a source that is not a raw clip. Deletes nothing but its own pin files.
# -WhatIf prints the plan and writes nothing.
param(
    [Parameter(Mandatory)][string]$Drive,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Dest,
    [Parameter(Mandatory)][int]$Runs,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

function Stop-Refused([string]$Why) {
    Write-Host "fragcard: REFUSED - $Why"
    exit 2
}

"fragcard: for a freshly formatted card only (the pin method assumes no free holes before the clip)"

# ---- arguments ----------------------------------------------------------
if ($Runs -lt 2 -or $Runs -gt 8) { Stop-Refused "-Runs $Runs is outside 2..8" }
if ($Drive -notmatch '^([A-Za-z]):?\\?$') { Stop-Refused "-Drive '$Drive' is not a drive letter (expected e.g. E:)" }
$letter = $Matches[1].ToUpper()
$root = "${letter}:\"
$di = New-Object System.IO.DriveInfo $root
if ($di.DriveType -ne [System.IO.DriveType]::Removable) {
    Stop-Refused "drive ${letter}: is $($di.DriveType), not Removable"
}
if (-not $di.IsReady) { Stop-Refused "drive ${letter}: is not ready (no card?)" }
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Stop-Refused "no source file $Source" }
$src = (Resolve-Path -LiteralPath $Source).ProviderPath
$destFull = if ([IO.Path]::IsPathRooted($Dest)) { [IO.Path]::GetFullPath($Dest) } else { [IO.Path]::GetFullPath((Join-Path $root $Dest)) }
if (-not $destFull.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Refused "-Dest $destFull is not on drive ${letter}:" }
if (Test-Path -LiteralPath $destFull) { Stop-Refused "-Dest $destFull already exists (delete it first)" }
$destDir = Split-Path -Parent $destFull
if (-not (Test-Path -LiteralPath $destDir -PathType Container)) { Stop-Refused "folder $destDir does not exist on the card" }
$pins = @(for ($i = 1; $i -lt $Runs; $i++) { Join-Path $destDir "FRAGPIN$i.TMP" })
foreach ($p in $pins) { if (Test-Path -LiteralPath $p) { Stop-Refused "$p already exists (this script deletes only pin files it created)" } }

# ---- the volume's cluster size --------------------------------------------
Add-Type -Namespace FragCard -Name Native -MemberDefinition ('[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] ' +
    'public static extern bool GetDiskFreeSpaceW(string root, out uint sectorsPerCluster, out uint bytesPerSector, ' +
    'out uint freeClusters, out uint totalClusters);')
[uint32]$spc = 0; [uint32]$bps = 0; [uint32]$freeCl = 0; [uint32]$totCl = 0
if (-not [FragCard.Native]::GetDiskFreeSpaceW($root, [ref]$spc, [ref]$bps, [ref]$freeCl, [ref]$totCl)) {
    Stop-Refused "cannot read the cluster size of ${letter}:"
}
$cluster = [int64]$spc * $bps
if ($cluster -lt 512 -or $cluster % 512 -ne 0) { Stop-Refused "cluster size $cluster is not a multiple of 512" }

# ---- the clip's layout ----------------------------------------------------
$size = (Get-Item -LiteralPath $src).Length
$fs = [IO.File]::OpenRead($src)
try {
    $hb = New-Object byte[] 512
    if ($fs.Read($hb, 0, 512) -ne 512) { Stop-Refused "$src is shorter than a header" }
    if ([Text.Encoding]::ASCII.GetString($hb, 0, 5) -ne 'NXVID' -or $hb[5] -ne 2 -or $hb[12] -ne 0x13) {
        Stop-Refused "$src is not a raw NXV clip (NXVID, version 2, flags 13)"
    }
    $nFrames = $hb[14] + 256 * $hb[15] + 65536 * $hb[16]
    $real = $hb[17] + 256 * $hb[18]
    $sndSec = [math]::Floor($real / 512) + 1
    $pixSec = ($hb[21] + 256 * $hb[22]) - 1
    # one entry per frame: first sector, palette flag (the tag is the last byte of the sound section)
    $frameStart = New-Object int64[] ($nFrames + 1)
    $framePal = New-Object bool[] $nFrames
    $sec = [int64]1
    $tag = New-Object byte[] 1
    for ($f = 0; $f -lt $nFrames; $f++) {
        $frameStart[$f] = $sec
        [void]$fs.Seek(($sec + $sndSec) * 512 - 1, 'Begin')
        if ($fs.Read($tag, 0, 1) -ne 1) { Stop-Refused "$src ends inside frame $f" }
        if ($tag[0] -gt 1) { Stop-Refused "$src frame $f has tag $($tag[0]) (0 or 1 expected)" }
        $framePal[$f] = $tag[0] -eq 1
        $sec += $sndSec + [int]$framePal[$f] + $pixSec
    }
    $frameStart[$nFrames] = $sec
}
finally { $fs.Close() }
if ($sec * 512 -ne $size) { Stop-Refused "$src is $size bytes, its frames walk to $($sec * 512)" }

# Kind of a sector: frame, sector within the frame, sound / palette / pixel, inside (not the first pixel sector).
function Get-SectorKind([int64]$S) {
    if ($S -eq 0) { return @{ frame = -1; at = 0; kind = 'header'; inside = $false } }
    $lo = 0; $hi = $nFrames - 1
    while ($lo -lt $hi) { $mid = [int](($lo + $hi + 1) / 2); if ($frameStart[$mid] -le $S) { $lo = $mid } else { $hi = $mid - 1 } }
    $at = $S - $frameStart[$lo]
    $p = [int]$framePal[$lo]
    $kind = if ($at -lt $sndSec) { 'sound' } elseif ($p -and $at -eq $sndSec) { 'palette' } else { 'pixel' }
    return @{ frame = $lo; at = $at; kind = $kind; inside = ($kind -eq 'pixel' -and $at -gt $sndSec + $p) }
}

# ---- chunk boundaries -----------------------------------------------------
$clusters = [int64][math]::Ceiling($size / $cluster)
if ($clusters -lt $Runs) { Stop-Refused "the clip is $clusters cluster(s), fewer than -Runs $Runs" }
$bound = @(for ($k = 1; $k -lt $Runs; $k++) { [int64][math]::Round($k * $clusters / $Runs) * $cluster })
$hit = $false
foreach ($b in $bound) { if ((Get-SectorKind ($b / 512)).inside) { $hit = $true; break } }
if (-not $hit) {
    # move one boundary by whole clusters, nearest first, keeping the order and every chunk non-empty
    :search for ($d = 1; $d -lt $clusters; $d++) {
        for ($k = 0; $k -lt $bound.Count; $k++) {
            foreach ($sign in 1, -1) {
                $nb = $bound[$k] + $sign * $d * $cluster
                $lo = if ($k -eq 0) { 0 } else { $bound[$k - 1] }
                $hi = if ($k -eq $bound.Count - 1) { $clusters * $cluster } else { $bound[$k + 1] }
                if ($nb -le $lo -or $nb -ge $hi -or $nb -ge $size) { continue }
                if ((Get-SectorKind ($nb / 512)).inside) { $bound[$k] = $nb; $hit = $true; break search }
            }
        }
    }
}
if (-not $hit) { Stop-Refused "no cluster boundary of this clip falls inside a frame's pixel sectors" }

# ---- the plan -------------------------------------------------------------
$edges = @([int64]0) + $bound + @([int64]$size)
"source   $src ($size bytes, $nFrames frames: $sndSec sound + $pixSec pixel sectors a frame, a palette sector on tagged frames)"
"card     ${letter}: ($($di.DriveType), $($di.DriveFormat), cluster $cluster bytes, $([int64]$freeCl * $cluster) bytes free)"
"dest     $destFull"
"runs     $Runs"
if ($size + ($Runs - 1) * $cluster -gt [int64]$freeCl * $cluster) { Stop-Refused "not enough free space on ${letter}:" }
for ($k = 0; $k -lt $Runs; $k++) {
    $len = $edges[$k + 1] - $edges[$k]
    "chunk $($k + 1): bytes $($edges[$k])-$($edges[$k + 1] - 1) ($len bytes, $([math]::Ceiling($len / $cluster)) clusters): append to dest, flush, close" +
        $(if ($k -lt $Runs - 1) { "; write $($pins[$k]) (1 byte), flush, close" } else { '' })
}
foreach ($b in $bound) {
    $sk = Get-SectorKind ($b / 512)
    "boundary at byte ${b}: file sector $($b / 512) = frame $($sk.frame), sector $($sk.at) of the frame (both count from 0), $($sk.kind)" +
        $(if ($sk.inside) { ' - inside the pixel sectors' } else { '' })
}
"then: delete $($pins -join ', '); compare dest with source byte for byte"
# a filemap entry covers at most 65535 blocks, so a long chunk is more than one run
$want = 0
for ($k = 0; $k -lt $Runs; $k++) { $want += [math]::Ceiling(($edges[$k + 1] - $edges[$k]) / 512 / 65535) }
"expected on the Next: RUNS=$('{0:X2}' -f [int]$want) (up to 08 passes; fewer means the pins did not land after the clip; over 08 is VID FRAG?)"
if ($WhatIf) {
    'WhatIf: nothing written'
    exit 0
}

# ---- write ----------------------------------------------------------------
$made = New-Object System.Collections.Generic.List[string]
$in = [IO.File]::OpenRead($src)
try {
    $buf = New-Object byte[] (1MB)
    for ($k = 0; $k -lt $Runs; $k++) {
        $out = New-Object IO.FileStream($destFull, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
        try {
            [void]$in.Seek($edges[$k], 'Begin')
            $left = $edges[$k + 1] - $edges[$k]
            while ($left -gt 0) {
                $n = $in.Read($buf, 0, [int][math]::Min($buf.Length, $left))
                if ($n -le 0) { throw "source ended early" }
                $out.Write($buf, 0, $n)
                $left -= $n
            }
            $out.Flush($true)
        }
        finally { $out.Close() }
        "chunk $($k + 1) written"
        if ($k -lt $Runs - 1) {
            $pin = New-Object IO.FileStream($pins[$k], [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
            $made.Add($pins[$k])
            try { $pin.WriteByte(0x50); $pin.Flush($true) } finally { $pin.Close() }
            "pin $($pins[$k]) written"
        }
    }
}
finally {
    $in.Close()
    foreach ($p in $made) { Remove-Item -LiteralPath $p -Force; "pin $p deleted" }
}

# ---- compare --------------------------------------------------------------
function Read-Full([IO.Stream]$S, [byte[]]$Buf) {
    $got = 0
    while ($got -lt $Buf.Length) { $n = $S.Read($Buf, $got, $Buf.Length - $got); if ($n -le 0) { break }; $got += $n }
    return $got
}
$a = [IO.File]::OpenRead($src); $b2 = [IO.File]::OpenRead($destFull)
try {
    if ($a.Length -ne $b2.Length) { Write-Host "fragcard: FAILED - dest is $($b2.Length) bytes, source $($a.Length)"; exit 1 }
    $ba = New-Object byte[] (1MB); $bb = New-Object byte[] (1MB); $pos = [int64]0
    while ($true) {
        $na = Read-Full $a $ba; $nb = Read-Full $b2 $bb
        if ($na -ne $nb) { Write-Host "fragcard: FAILED - short read at $pos"; exit 1 }
        if ($na -eq 0) { break }
        if (-not [Linq.Enumerable]::SequenceEqual([ArraySegment[byte]]::new($ba, 0, $na), [ArraySegment[byte]]::new($bb, 0, $na))) {
            Write-Host "fragcard: FAILED - dest differs from source in bytes $pos-$($pos + $na - 1)"; exit 1
        }
        $pos += $na
    }
}
finally { $a.Close(); $b2.Close() }
"fragcard: OK - $destFull written in $Runs chunks and equal to the source; check RUNS= on the Next"
