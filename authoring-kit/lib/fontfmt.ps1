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
#   OverWide character codes the source declared wider than 8px, whose
#            glyph data was therefore not read at all. Defaults to an
#            empty array; only containers with a per-glyph declared
#            width (currently FON) populate it. The caller decides
#            whether an over-wide code is fatal - the range 32-127 is
#            fontconv.ps1's business, not this file's.
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

function New-FontResult($format, $faceName, $width, $height, $charset, $glyphs, $faces, $overWide = @()) {
    [PSCustomObject]@{
        Format   = $format
        FaceName = $faceName
        Width    = $width
        Height   = $height
        Charset  = $charset
        Glyphs   = $glyphs
        Faces    = $faces
        OverWide = $overWide
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
# resources. Every field offset below was confirmed against
# C:\Windows\Fonts\cga80woa.fon rather than recalled - in particular
# RT_FONT is type 8 (0x8008 with the high bit set), NOT 7. Type 7 is
# RT_FONTDIR, a small decoy resource that parses into a nonsense cell
# size.
function Read-FontFon([byte[]]$b, [string]$path, [string]$want) {
    $trunc = "fontconv: $path is truncated or malformed (resource table runs past the end of the file)"
    if ($b.Length -lt 0x40) { throw "fontconv: $path is too short to be a FON" }
    $ne = [BitConverter]::ToInt32($b, 0x3C)
    if ($ne -le 0 -or $ne + 0x26 -ge $b.Length) { throw "fontconv: $path has no usable NE header" }
    if ($b[$ne] -ne 0x4E -or $b[$ne+1] -ne 0x45) {
        throw "fontconv: $path is not a 16-bit NE font file (no 'NE' signature). PE-wrapped .fon files are not supported."
    }
    $rsrcRel = [BitConverter]::ToUInt16($b, $ne + 0x24)
    if ($rsrcRel -eq 0) { throw "fontconv: $path has no resource table" }
    $rsrc  = $ne + $rsrcRel
    if ($rsrc + 2 -gt $b.Length) { throw $trunc }
    $shift = [BitConverter]::ToUInt16($b, $rsrc)

    $entries = @()
    $o = $rsrc + 2
    while ($true) {
        if ($o + 8 -gt $b.Length) { break }
        $tid = [BitConverter]::ToUInt16($b, $o)
        if ($tid -eq 0) { break }
        $cnt = [BitConverter]::ToUInt16($b, $o + 2)
        $e = $o + 8
        $ranOff = $false
        for ($i = 0; $i -lt $cnt; $i++) {
            if ($e + 12 -gt $b.Length) { $ranOff = $true; break }
            if ($tid -eq 0x8008) {
                $entries += [PSCustomObject]@{
                    Offset = ([int][BitConverter]::ToUInt16($b, $e))     -shl $shift
                    Length = ([int][BitConverter]::ToUInt16($b, $e + 2)) -shl $shift
                }
            }
            $e += 12
        }
        if ($ranOff) { break }   # a corrupt rtResourceCount walked off the end
        $o = $e
    }
    if ($entries.Count -eq 0) { throw "fontconv: $path contains no RT_FONT resources" }

    # Describe every face first, so a refusal can list them.
    $faces = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $f = $entries[$i].Offset
        if ($f -lt 0 -or $f + 97 -gt $b.Length) { throw $trunc }
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
    if ($f -lt 0 -or $f + 97 -gt $b.Length) { throw $trunc }
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

    $glyphs   = @{}
    $overWide = @()
    for ($c = $fc; $c -le $lc; $c++) {
        $e  = $ctab + ($c - $fc) * $esz
        if ($e + $esz -gt $b.Length) { break }
        $gw = [int][BitConverter]::ToUInt16($b, $e)
        $go = if ($esz -eq 4) { [int][BitConverter]::ToUInt16($b, $e + 2) } else { [int][BitConverter]::ToInt32($b, $e + 2) }
        if ($gw -le 0) { continue }
        if ($gw -gt 8) { $overWide += $c; continue }   # wider than the cell; the caller decides whether that is fatal
        $start = $f + $go
        if ($start -lt 0 -or $start + $height -gt $b.Length) { continue }
        $rows = New-Object byte[] $height
        [System.Array]::Copy($b, $start, $rows, 0, $height)
        $glyphs[$c] = $rows
    }

    $charset = switch ($cset) { 0xFF { 'OEM' } 0x00 { 'ANSI' } default { 'UNKNOWN' } }
    $name    = [System.IO.Path]::GetFileNameWithoutExtension($path)
    New-FontResult 'FON' $name $width $height $charset $glyphs $faces $overWide
}

# PSF1: a 4-byte header and then glyph data. Width is 8 by definition of
# the format, so there is never a partial byte to mask.
function Read-FontPsf1([byte[]]$b, [string]$path) {
    if ($b.Length -lt 4) { throw "fontconv: $path is too short to be a PSF1" }
    $mode = $b[2]
    $size = [int]$b[3]
    if ($size -le 0) { throw "fontconv: $path declares a charsize of $size" }
    $count = if ($mode -band 1) { 512 } else { 256 }
    if ($b.Length -lt 4 + $count * $size) {
        throw "fontconv: $path declares $count glyphs of $size bytes but holds only $($b.Length - 4) bytes of glyph data"
    }
    $glyphs = @{}
    for ($c = 0; $c -lt $count; $c++) {
        $rows = New-Object byte[] $size
        [System.Array]::Copy($b, 4 + $c * $size, $rows, 0, $size)
        $glyphs[$c] = $rows
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
    New-FontResult 'PSF1' $name 8 $size 'UNKNOWN' $glyphs @(@{ Index = 0; Width = 8; Height = $size; Name = $name })
}

# PSF2: a 32-byte-or-longer header with explicit width and height. The
# Unicode table that may follow the glyph data is ignored on purpose -
# only codes 32-127 are read for text and every encoding this format
# carries agrees with ASCII across that range.
function Read-FontPsf2([byte[]]$b, [string]$path) {
    if ($b.Length -lt 32) { throw "fontconv: $path is too short to be a PSF2" }
    $headerSize = [BitConverter]::ToInt32($b, 8)
    $length     = [BitConverter]::ToInt32($b, 16)
    $charSize   = [BitConverter]::ToInt32($b, 20)
    $height     = [BitConverter]::ToInt32($b, 24)
    $width      = [BitConverter]::ToInt32($b, 28)
    if ($height -le 0 -or $width -le 0 -or $length -le 0 -or $charSize -le 0) {
        throw "fontconv: $path declares a $($width)x$($height) cell over $length glyphs of $charSize bytes, which is not usable"
    }
    if ($headerSize -lt 32 -or $headerSize -gt $b.Length) {
        throw "fontconv: $path declares a header of $headerSize bytes, which does not fit the file"
    }
    # The intermediate stores one byte per row, so a width above 8 cannot
    # be represented, let alone measured by the gate later - refuse here,
    # at the one place that knows the source declared it, rather than
    # silently keeping only the first 8 columns.
    if ($width -gt 8) {
        throw "fontconv: $path declares a cell $width pixels wide - NextDAAD tiles are 8 pixels wide and this converter will not crop a font to fit"
    }
    $rowBytes = [Math]::Ceiling($width / 8)
    if ($charSize -lt $rowBytes * $height) {
        throw "fontconv: $path declares glyphs of $charSize bytes, too small for its own $($width)x$($height) cell ($($rowBytes * $height) bytes needed)"
    }
    if ($b.Length -lt $headerSize + $length * $charSize) {
        throw "fontconv: $path declares $length glyphs of $charSize bytes from offset $headerSize but is only $($b.Length) bytes"
    }
    $glyphs = @{}
    for ($c = 0; $c -lt $length; $c++) {
        $g = $headerSize + $c * $charSize
        $rows = New-Object byte[] $height
        for ($r = 0; $r -lt $height; $r++) { $rows[$r] = $b[$g + $r * $rowBytes] }
        $glyphs[$c] = $rows
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
    New-FontResult 'PSF2' $name $width $height 'UNKNOWN' $glyphs @(@{ Index = 0; Width = $width; Height = $height; Name = $name })
}

function Read-FontFile([byte[]]$bytes, [string]$path, [int]$first, [string]$face) {
    switch (Get-FontFormat $bytes) {
        'SINTAC' {
            throw "fontconv: $path is a JSJ SINTAC font (the format DAAD Ready's PC.FNT and PCDAAD's DAAD.FNT use). That format is not supported - it stores per-character width tables rather than a fixed 8x8 cell. Use ASSETS\CHARSET\AD8x8.CHR instead, which is already a 2048-byte table."
        }
        'RAW' { return Read-FontRaw $bytes $path $first }
        'FON'  { return Read-FontFon $bytes $path $face }
        'PSF1' { return Read-FontPsf1 $bytes $path }
        'PSF2' { return Read-FontPsf2 $bytes $path }
        default {
            throw "fontconv: $path was detected as $(Get-FontFormat $bytes), which this build cannot read yet"
        }
    }
}
