# authoring-kit/lib/fontconv.ps1
#
# Builds a NextDAAD FONT.CHR: the interpreter installs this file by a
# plain byte-for-byte copy into the tilemap driver's glyph table
# (TM_DEFS, src/tilemap.asm tm_font_init / src/overlay2.asm font_load) -
# 256 glyphs x 8 rows, 1bpp, exactly 2048 bytes, no expansion or other
# conversion. That means this converter's output IS the installed bytes.
#
# Two accepted input shapes:
#   2048 bytes - already a full glyph table (this is what the whole DAAD/
#     ZX tool ecosystem emits for a full custom charset - CH82CHR,
#     jDAADFontMaker, GCS, and similar font editors all produce a raw
#     256-glyph 2048-byte table). Copied straight through, byte for byte.
#   768 bytes - a classic ZX Spectrum charset: characters 32-127 only
#     (96 glyphs x 8 rows), the shape every ZX font editor and font pack
#     exports as a raw charset (e.g. the ZX-Origins ".ch8" files under
#     tools\demo-files\fonts). This range covers ordinary printable text
#     only, so it is padded into a full 2048-byte table by starting from
#     default.chr (below) and overwriting bytes 32*8..127*8+7 (256..1023)
#     with the input - every other glyph (0-31, 128-255: the engine's
#     "upper/graphics charset" mirror at char+128 and the low extended-
#     glyph block, see src/print.asm prn_char_raw) keeps the embedded
#     font's originals.
# Any other size is an error naming both accepted shapes and what each
# range covers.
#
# default.chr (committed alongside this script) is a byte-for-byte copy
# of src/font.chr, the interpreter's embedded font - verified identical
# by SHA256 at the time this note was last updated (2026-07-22, the
# glyph 38/$26 (ampersand) and glyph 96/$60 (pound sterling) content
# fix - see .superpowers/sdd/keyboard-fix-report.md):
#   9de51ef5d66c06f2845eacede265c303ddbaa10b5e47583d1f7b077ed2802c64
# (src/font.chr is INCBIN'd at tilemap.asm:297, tracked in git, exactly
# 2048 bytes - see .superpowers/sdd/fonts-task-1-report.md). Re-verify
# and update this hash whenever either file changes - `sha256sum
# src/font.chr authoring-kit/lib/default.chr` must print the SAME
# digest for both.
#
# Glyph 32 (space) constraint: the tilemap driver relies on glyph 32
# having an all-zero bitmap (src/tilemap.asm's tm_clear_blank comment) -
# every cell the engine blanks is filled with glyph 32 at the ordinary
# default attribute (black paper, white ink), same as a printed cell. A
# custom font that redefines glyph 32 with non-zero pixels puts those
# pixels in the ink colour, so blanked cells show white specks instead
# of clean black paper. This is a WARNING, not a build failure - authors
# overriding glyph 32 deliberately are not blocked, just told.
#
# Usage: fontconv.ps1 -In <path to 2048 or 768 byte font file> [-Out FONT.CHR]
param(
    [Parameter(Mandatory=$true)][string]$In,
    [string]$Out = 'FONT.CHR'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $In)) { throw "font not found: $In" }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultChr = Join-Path $scriptDir 'default.chr'
if (-not (Test-Path $defaultChr)) { throw "default.chr not found beside fontconv.ps1 at $defaultChr - kit installation is incomplete" }

$inBytes = [System.IO.File]::ReadAllBytes($In)

function Test-GlyphSpace([byte[]]$table, [int]$offset) {
    for ($i = 0; $i -lt 8; $i++) {
        if ($table[$offset + $i] -ne 0) { return $false }
    }
    return $true
}

switch ($inBytes.Length) {
    2048 {
        if (-not (Test-GlyphSpace $inBytes (32 * 8))) {
            Write-Warning "$In : glyph 32 (space) is not all-zero - the tilemap driver relies on it staying blank, or blanked cells show ink-coloured specks instead of clean black paper (see src/tilemap.asm's tm_clear_blank comment); the font will still install as given"
        }
        [System.IO.File]::WriteAllBytes($Out, $inBytes)
        "$Out : source=$In shape=2048 (full table, passthrough) bytes=$($inBytes.Length)"
    }
    768 {
        if (-not (Test-GlyphSpace $inBytes 0)) {
            Write-Warning "$In : glyph 32 (space, the charset's first entry) is not all-zero - the tilemap driver relies on it staying blank, or blanked cells show ink-coloured specks instead of clean black paper (see src/tilemap.asm's tm_clear_blank comment); the font will still install as given"
        }
        $outBytes = [System.IO.File]::ReadAllBytes($defaultChr)
        [System.Array]::Copy($inBytes, 0, $outBytes, 32 * 8, 768)
        [System.IO.File]::WriteAllBytes($Out, $outBytes)
        "$Out : source=$In shape=768 (classic ZX charset, chars 32-127) padded from $defaultChr over bytes 256-1023 (glyphs 32-127); glyphs 0-31 and 128-255 kept from default.chr; bytes=$($outBytes.Length)"
    }
    default {
        throw "$In is $($inBytes.Length) bytes - fontconv.ps1 only accepts 2048 bytes (a full 256-glyph FONT.CHR table) or 768 bytes (a classic ZX charset, chars 32-127 only, padded from default.chr)"
    }
}
exit 0
