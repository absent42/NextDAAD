# authoring-kit/lib/fontfmt.ps1
#
# Container parsers for lib\fontconv.ps1. Dot-sourced, never run on its
# own. Everything here is about FILE FORMATS - nothing in this file
# knows what NextDAAD does with a glyph, what size its table is, or
# which slots the ZX charset puts a pound sterling in. That division is
# what lets the acceptance gate and the slot rules live in exactly one
# place instead of once per format.
#
# Every Read-Font* function returns the same object:
#   Format   'RAW' | 'FON' | 'PSF1' | 'PSF2' | 'BDF'
#   FaceName human-readable, for messages
#   Width    declared glyph width in pixels
#   Height   declared glyph height in rows
#   Charset  'OEM' | 'ANSI' | 'UNKNOWN' - only 'OEM' enables
#            fontconv.ps1's in-face pound sterling rule
#   Glyphs   hashtable, character code (int) -> byte[] of Height rows,
#            most significant bit leftmost, left-aligned in the byte
#   Faces    one entry per face the container held, each with Index,
#            Width, Height and Name - used to build a useful error when
#            no face fits
#
# Rows come back at the SOURCE's height, not padded to 8. Padding and
# the fit decision belong to the caller, which does them once.

function Get-FontFormat([byte[]]$bytes) {
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) { return 'FON' }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x36 -and $bytes[1] -eq 0x04) { return 'PSF1' }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x72 -and $bytes[1] -eq 0xB5 -and
        $bytes[2] -eq 0x4A -and $bytes[3] -eq 0x86) { return 'PSF2' }
    if ($bytes.Length -ge 9) {
        $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 9)
        if ($head -eq 'STARTFONT') { return 'BDF' }
    }
    if ($bytes.Length -ge 10) {
        $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 10)
        if ($head -eq 'JSJ SINTAC') { return 'SINTAC' }
    }
    return 'RAW'
}

function New-FontResult($format, $faceName, $width, $height, $charset, $glyphs, $faces) {
    [PSCustomObject]@{
        Format   = $format
        FaceName = $faceName
        Width    = $width
        Height   = $height
        Charset  = $charset
        Glyphs   = $glyphs
        Faces    = $faces
    }
}

# Raw glyph table: no header at all, just Height rows per glyph in
# ascending character order. Height is fixed at 8 because that is the
# only height a headerless dump can be read at without being told, and
# -First says which character the first glyph is.
function Read-FontRaw([byte[]]$bytes, [string]$path, [int]$first) {
    if ($bytes.Length % 8 -ne 0) {
        throw "fontconv: $path is $($bytes.Length) bytes, which is not a multiple of 8 - a raw glyph table is 8 rows per glyph"
    }
    $count  = $bytes.Length / 8
    $glyphs = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $rows = New-Object byte[] 8
        [System.Array]::Copy($bytes, $i * 8, $rows, 0, 8)
        $glyphs[$first + $i] = $rows
    }
    $name = [System.IO.Path]::GetFileName($path)
    New-FontResult 'RAW' $name 8 8 'UNKNOWN' $glyphs @(@{ Index = 0; Width = 8; Height = 8; Name = $name })
}

# Windows FON: a 16-bit NE executable wrapping one or more FNT
# resources. See the plan's Task 2 for the field offsets, every one of
# which was confirmed against C:\Windows\Fonts\cga80woa.fon rather than
# recalled - in particular RT_FONT is type 8 (0x8008 with the high bit
# set), NOT 7. Type 7 is RT_FONTDIR, a small decoy resource that parses
# into a nonsense cell size.
function Read-FontFon([byte[]]$b, [string]$path, [string]$want) {
    if ($b.Length -lt 0x40) { throw "fontconv: $path is too short to be a FON" }
    $ne = [BitConverter]::ToInt32($b, 0x3C)
    if ($ne -le 0 -or $ne + 0x26 -ge $b.Length) { throw "fontconv: $path has no usable NE header" }
    if ($b[$ne] -ne 0x4E -or $b[$ne+1] -ne 0x45) {
        throw "fontconv: $path is not a 16-bit NE font file (no 'NE' signature). PE-wrapped .fon files are not supported."
    }
    $rsrcRel = [BitConverter]::ToUInt16($b, $ne + 0x24)
    if ($rsrcRel -eq 0) { throw "fontconv: $path has no resource table" }
    $rsrc  = $ne + $rsrcRel
    $shift = [BitConverter]::ToUInt16($b, $rsrc)

    $entries = @()
    $o = $rsrc + 2
    while ($true) {
        if ($o + 8 -gt $b.Length) { break }
        $tid = [BitConverter]::ToUInt16($b, $o)
        if ($tid -eq 0) { break }
        $cnt = [BitConverter]::ToUInt16($b, $o + 2)
        $e = $o + 8
        for ($i = 0; $i -lt $cnt; $i++) {
            if ($tid -eq 0x8008) {
                $entries += [PSCustomObject]@{
                    Offset = ([int][BitConverter]::ToUInt16($b, $e))     -shl $shift
                    Length = ([int][BitConverter]::ToUInt16($b, $e + 2)) -shl $shift
                }
            }
            $e += 12
        }
        $o = $e
    }
    if ($entries.Count -eq 0) { throw "fontconv: $path contains no RT_FONT resources" }

    # Describe every face first, so a refusal can list them.
    $faces = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $f = $entries[$i].Offset
        $faces += @{
            Index  = $i
            Width  = [int][BitConverter]::ToUInt16($b, $f + 86)
            Height = [int][BitConverter]::ToUInt16($b, $f + 88)
            Name   = "face $i"
        }
    }

    # Pick one: an exact 8x8 wins; otherwise the tallest that fits,
    # tie-broken on width and then on file order.
    $pick = -1
    if ($want) {
        if ($want -match '^\d+$') { $pick = [int]$want }
        elseif ($want -match '^(\d+)x(\d+)$') {
            for ($i = 0; $i -lt $faces.Count; $i++) {
                if ($faces[$i].Width -eq [int]$Matches[1] -and $faces[$i].Height -eq [int]$Matches[2]) { $pick = $i; break }
            }
        }
        if ($pick -lt 0 -or $pick -ge $faces.Count) {
            $list = ($faces | ForEach-Object { "$($_.Index): $($_.Width)x$($_.Height)" }) -join '; '
            throw "fontconv: -Face '$want' matches nothing in $path. Faces present: $list"
        }
    }
    else {
        $fit = $faces | Where-Object { $_.Width -le 8 -and $_.Height -le 8 } |
               Sort-Object @{E={$_.Height};D=$true}, @{E={$_.Width};D=$true}, @{E={$_.Index}}
        $exact = $faces | Where-Object { $_.Width -eq 8 -and $_.Height -eq 8 } | Select-Object -First 1
        if ($exact)        { $pick = $exact.Index }
        elseif ($fit)      { $pick = @($fit)[0].Index }
        else {
            $list = ($faces | ForEach-Object { "$($_.Width)x$($_.Height)" }) -join '; '
            throw "fontconv: no face in $path fits an 8x8 cell. Faces present: $list. NextDAAD tiles are 8x8 and this converter will not scale or crop a face to fit."
        }
    }

    $f      = $entries[$pick].Offset
    $ver    = [BitConverter]::ToUInt16($b, $f)
    $cset   = $b[$f + 85]
    $height = [int][BitConverter]::ToUInt16($b, $f + 88)
    $width  = [int][BitConverter]::ToUInt16($b, $f + 86)
    $fc     = [int]$b[$f + 95]
    $lc     = [int]$b[$f + 96]
    if ($ver -ne 0x0200 -and $ver -ne 0x0300) {
        throw "fontconv: $path face $pick is FNT version 0x$('{0:X4}' -f $ver), expected 0x0200 or 0x0300"
    }
    $ctab = $f + $(if ($ver -eq 0x0200) { 118 } else { 148 })
    $esz  = if ($ver -eq 0x0200) { 4 } else { 6 }

    $glyphs = @{}
    for ($c = $fc; $c -le $lc; $c++) {
        $e  = $ctab + ($c - $fc) * $esz
        if ($e + $esz -gt $b.Length) { break }
        $gw = [int][BitConverter]::ToUInt16($b, $e)
        $go = if ($esz -eq 4) { [int][BitConverter]::ToUInt16($b, $e + 2) } else { [int][BitConverter]::ToInt32($b, $e + 2) }
        if ($gw -le 0 -or $gw -gt 8) { continue }   # wider than the cell; the gate reports it
        $start = $f + $go
        if ($start -lt 0 -or $start + $height -gt $b.Length) { continue }
        $rows = New-Object byte[] $height
        [System.Array]::Copy($b, $start, $rows, 0, $height)
        $glyphs[$c] = $rows
    }

    $charset = switch ($cset) { 0xFF { 'OEM' } 0x00 { 'ANSI' } default { 'UNKNOWN' } }
    $name    = [System.IO.Path]::GetFileNameWithoutExtension($path)
    New-FontResult 'FON' $name $width $height $charset $glyphs $faces
}

function Read-FontFile([byte[]]$bytes, [string]$path, [int]$first, [string]$face) {
    switch (Get-FontFormat $bytes) {
        'SINTAC' {
            throw "fontconv: $path is a JSJ SINTAC font (the format DAAD Ready's PC.FNT and PCDAAD's DAAD.FNT use). That format is not supported - it stores per-character width tables rather than a fixed 8x8 cell. Use ASSETS\CHARSET\AD8x8.CHR instead, which is already a 2048-byte table."
        }
        'RAW' { return Read-FontRaw $bytes $path $first }
        'FON'  { return Read-FontFon $bytes $path $face }
        default {
            throw "fontconv: $path was detected as $(Get-FontFormat $bytes), which this build cannot read yet"
        }
    }
}
