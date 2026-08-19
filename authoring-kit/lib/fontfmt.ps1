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

function Read-FontFile([byte[]]$bytes, [string]$path, [int]$first, [string]$face) {
    switch (Get-FontFormat $bytes) {
        'SINTAC' {
            throw "fontconv: $path is a JSJ SINTAC font (the format DAAD Ready's PC.FNT and PCDAAD's DAAD.FNT use). That format is not supported - it stores per-character width tables rather than a fixed 8x8 cell. Use ASSETS\CHARSET\AD8x8.CHR instead, which is already a 2048-byte table."
        }
        'RAW' { return Read-FontRaw $bytes $path $first }
        default {
            throw "fontconv: $path was detected as $(Get-FontFormat $bytes), which this build cannot read yet"
        }
    }
}
