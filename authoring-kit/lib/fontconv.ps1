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
#     a base font - default.chr (below) unless -Base names a different
#     one - and overwriting bytes 32*8..127*8+7 (256..1023) with the
#     input - every other glyph (0-31, 128-255: the engine's "upper/
#     graphics charset" mirror at char+128 and the low extended-glyph
#     block, see src/print.asm prn_char_raw) keeps the base font's
#     originals.
# Any other size is an error naming both accepted shapes and what each
# range covers.
#
# -Base <file> (SP18): overrides the padding source for 768-byte input.
# A game that switches between several fonts (GFX n 16) can define UDGs,
# accented characters or a graphics set in glyphs 0-31/128-255 of its
# FIRST font and then lose them when converting a SECOND 768-byte classic
# charset, because the padding would otherwise always come from
# default.chr regardless of what the first font defined. Pass -Base
# <the first font's own 2048-byte FONT.CHR> so the second conversion
# pads from the author's own table instead of the interpreter's embedded
# one - same ranges (0-31, 128-255), different source. -Base must itself
# be a full 2048-byte table - validated the same way as any full-table
# input (existence and exact length; content is not inspected, see the
# glyph 32 note below for why) - and defaults to default.chr when
# omitted, so callers that never pass -Base are unaffected.
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
# This check runs against the INPUT, never against a -Base file. Glyph 32
# sits inside the 32-127 range a 768-byte charset supplies directly (input
# offset 0 becomes output offset 32*8), so the shipped glyph 32 is always
# the classic-charset input's own byte - the base's glyph 32 slot is
# unconditionally overwritten and never reaches the interpreter either
# way, so there is nothing to warn about there.
#
# Usage: fontconv.ps1 -In <path to 2048 or 768 byte font file>
#          [-Out FONT.CHR] [-Base <2048-byte font to pad 768-byte input
#          against, default default.chr>]
param(
    [Parameter(Mandatory=$true)][string]$In,
    [string]$Out = 'FONT.CHR',
    [string]$Base
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $In)) { throw "font not found: $In" }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Padding source for 768-byte input (see the -Base note above): the
# author's own full table when given, default.chr otherwise. Resolved
# and validated unconditionally, same as the old default.chr-only check
# this replaces, so a bad -Base is caught even for a 2048-byte passthrough
# input that will never actually read it.
$baseFile = if ($Base) { $Base } else { Join-Path $scriptDir 'default.chr' }
if (-not (Test-Path $baseFile)) { throw "fontconv: base font not found: $baseFile" }
$baseBytes = [System.IO.File]::ReadAllBytes($baseFile)
if ($baseBytes.Length -ne 2048) {
    throw "fontconv: base font $baseFile is $($baseBytes.Length) bytes, expected 2048 - a base must be a full glyph table"
}

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
        $outBytes = [byte[]]$baseBytes.Clone()
        [System.Array]::Copy($inBytes, 0, $outBytes, 32 * 8, 768)
        [System.IO.File]::WriteAllBytes($Out, $outBytes)
        "$Out : source=$In shape=768 (classic ZX charset, chars 32-127) padded from $baseFile over bytes 256-1023 (glyphs 32-127); glyphs 0-31 and 128-255 kept from $baseFile; bytes=$($outBytes.Length)"
    }
    default {
        throw "$In is $($inBytes.Length) bytes - fontconv.ps1 only accepts 2048 bytes (a full 256-glyph FONT.CHR table) or 768 bytes (a classic ZX charset, chars 32-127 only, padded from a base font - default.chr unless -Base overrides it)"
    }
}
exit 0
