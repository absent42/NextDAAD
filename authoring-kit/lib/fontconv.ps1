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
    [string]$Base,
    [int]$First = -1,
    [string]$Face,
    [ValidateSet('ZX','Source')][string]$Slots = 'ZX'
)
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\fontfmt.ps1"

$script:AssemblyNote = ''

function Test-GlyphBlank([byte[]]$table, [int]$offset) {
    for ($i = 0; $i -lt 8; $i++) { if ($table[$offset + $i] -ne 0) { return $false } }
    return $true
}

function Write-GlyphSpaceWarning([string]$src) {
    Write-Warning "$src : glyph 32 (space) is not all-zero - the tilemap driver relies on it staying blank, or blanked cells show ink-coloured specks instead of clean black paper (see src/tilemap.asm's tm_clear_blank comment); the font will still install as given"
}

# Actual ink extent over a set of character codes. Returns the topmost
# and bottom-most rows and the rightmost column that carry any set
# pixel, plus the codes that reach outside an 8x8 cell. Measured rather
# than read from the header because declarations are routinely
# pessimistic: a 9-row source whose last row is always blank loses
# nothing at 8 rows, and refusing it on the header alone would turn away
# fonts that convert perfectly.
function Measure-FontInk($glyphs, [int[]]$codes) {
    $top = 999; $bottom = -1; $right = -1; $over = @()
    foreach ($c in $codes) {
        if (-not $glyphs.ContainsKey($c)) { continue }
        $rows = $glyphs[$c]
        $gBottom = -1
        for ($r = 0; $r -lt $rows.Length; $r++) {
            if ($rows[$r] -eq 0) { continue }
            if ($r -lt $top) { $top = $r }
            if ($r -gt $bottom) { $bottom = $r }
            $gBottom = $r
            for ($b = 0; $b -lt 8; $b++) {
                if ($rows[$r] -band (1 -shl (7 - $b))) { if ($b -gt $right) { $right = $b } }
            }
        }
        if ($gBottom -ge 8) { $over += $c }
    }
    if ($bottom -lt 0) { $top = 0; $bottom = 0; $right = 0 }   # entirely blank
    [PSCustomObject]@{ Top = $top; Bottom = $bottom; Right = $right; Over = $over }
}

# Assemble the 2048-byte table. Slot map, from the design:
#   0-15     base font (no print path reaches these)
#   16-31    source where supplied, else base
#   32-127   source, with the ZX slot substitutions
#   128-159  source where supplied, else base
#   160-255  mirror of the assembled 32-127
# Glyphs 160-255 are what the engine prints ordinary characters through
# under an upper-charset window or the GFX ON escape (glyph = char +
# 128). Leaving them as the base font makes such a game print half a
# sentence in the author's face and half in the built-in one, so the
# mirror is a fix, not a preference.
function Build-GlyphTable($font, [byte[]]$baseBytes, [string]$slots, [string]$src) {
    $text = 32..127

    $ink = Measure-FontInk $font.Glyphs $text
    if ($ink.Over.Count -gt 0) {
        $names = ($ink.Over | Select-Object -First 8) -join ', '
        $faces = ($font.Faces | ForEach-Object { "$($_.Width)x$($_.Height) '$($_.Name)'" }) -join '; '
        throw "fontconv: $src does not fit an 8x8 cell - ink reaches row $($ink.Bottom) (rows are numbered from 0, so that is $($ink.Bottom + 1) rows) on character code(s) $names. NextDAAD tiles are 8 rows and this converter will not drop or merge a row to make a source fit. Faces in this file: $faces"
    }
    # This cannot currently fire: every Read-Font* parser stores exactly
    # one byte per row in the intermediate, so $ink.Right can never exceed
    # 7 no matter what a source declares. It is left in place as the
    # documented intent - width enforcement itself lives elsewhere: a
    # uniform-cell format such as PSF refuses a declared width above 8 in
    # its own parser, before the font ever reaches this function, while a
    # per-glyph format such as FON reports the offending codes through
    # OverWide instead, handled a few lines below.
    if ($ink.Right -gt 7) {
        throw "fontconv: $src does not fit an 8x8 cell - ink reaches column $($ink.Right) (columns are numbered from 0). NextDAAD tiles are 8 pixels wide."
    }

    # A source that DECLARES a glyph wider than 8px (rather than merely
    # having ink that reaches column 8) never had that glyph's data read
    # at all - see fontfmt.ps1's OverWide. Inside the text range that is
    # the same refusal as ink overrunning the cell: keeping the base
    # font's glyph there would be a silent degrade, not a refuse.
    # Outside the text range it is decorative and folds into the same
    # drop-and-count path as any other glyph that does not fit.
    $overWide = @()
    if ($font.PSObject.Properties['OverWide'] -and $font.OverWide) { $overWide = @($font.OverWide) }
    $overWideText = $overWide | Where-Object { $_ -ge 32 -and $_ -le 127 }
    if ($overWideText.Count -gt 0) {
        $names = ($overWideText | Select-Object -First 8) -join ', '
        $faces = ($font.Faces | ForEach-Object { "$($_.Width)x$($_.Height) '$($_.Name)'" }) -join '; '
        throw "fontconv: $src does not fit an 8x8 cell - character code(s) $names are wider than 8 pixels per the source's own declaration. NextDAAD tiles are 8 pixels wide and this converter will not crop or scale a glyph to fit. Faces in this file: $faces"
    }
    $overWideDecorative = @($overWide | Where-Object { $_ -lt 32 -or $_ -gt 127 })

    $table = [byte[]]$baseBytes.Clone()
    $notes = @()

    # 16-31, 32-127 and 128-159 straight from the source where it has
    # them. A source glyph outside the text range that would not fit the
    # cell is DROPPED, keeping the base font's glyph, rather than
    # clipped - half a box-drawing character appearing in a game with no
    # explanation is worse than not getting it at all.
    $dropped = $overWideDecorative.Count
    foreach ($c in @(16..31) + @(32..127) + @(128..159)) {
        if (-not $font.Glyphs.ContainsKey($c)) { continue }
        $rows = $font.Glyphs[$c]
        $fits = $true
        for ($r = 8; $r -lt $rows.Length; $r++) { if ($rows[$r] -ne 0) { $fits = $false } }
        if (-not $fits) { $dropped++; continue }
        for ($r = 0; $r -lt 8; $r++) {
            $table[$c * 8 + $r] = if ($r -lt $rows.Length) { $rows[$r] } else { [byte]0 }
        }
    }
    if ($dropped -gt 0) { $notes += "$dropped decorative glyph(s) outside 32-127 dropped for not fitting the cell" }

    # ZX slot substitutions. CP437 and the ZX charset disagree at exactly
    # two printable codes: 96 is a grave accent on a PC and a pound
    # sterling here, 127 is a house on a PC and a copyright sign here.
    # Left alone a game printing a price prints a backtick.
    if ($slots -eq 'ZX') {
        $poundFrom = 'base'
        if ($font.Charset -eq 'OEM' -and $font.Glyphs.ContainsKey(156)) {
            $src156 = $font.Glyphs[156]
            $blank = $true
            foreach ($r in $src156) { if ($r -ne 0) { $blank = $false } }
            if (-not $blank) {
                for ($r = 0; $r -lt 8; $r++) {
                    $table[96 * 8 + $r] = if ($r -lt $src156.Length) { $src156[$r] } else { [byte]0 }
                }
                $poundFrom = 'source slot 156, in face'
            }
        }
        if ($poundFrom -eq 'base') {
            [System.Array]::Copy($baseBytes, 96 * 8, $table, 96 * 8, 8)
        }
        [System.Array]::Copy($baseBytes, 127 * 8, $table, 127 * 8, 8)
        $notes += "pound sterling (96) from $poundFrom; copyright (127) from the base font"
    }

    # 160-255 mirror the assembled 32-127.
    [System.Array]::Copy($table, 32 * 8, $table, 160 * 8, 96 * 8)

    if ($notes.Count -gt 0) { $script:AssemblyNote = ' - ' + ($notes -join '; ') }
    return $table
}

if (-not (Test-Path $In)) { throw "font not found: $In" }

# The padding source. Resolved and validated unconditionally, so a bad
# -Base is caught even on a passthrough input that never reads it.
$baseFile = if ($Base) { $Base } else { Join-Path $scriptDir 'default.chr' }
if (-not (Test-Path $baseFile)) { throw "fontconv: base font not found: $baseFile" }
$baseBytes = [System.IO.File]::ReadAllBytes($baseFile)
if ($baseBytes.Length -ne 2048) {
    throw "fontconv: base font $baseFile is $($baseBytes.Length) bytes, expected 2048 - a base must be a full glyph table"
}

$inBytes = [System.IO.File]::ReadAllBytes($In)

# A full table is the author's finished word on all 256 glyphs. It is
# copied out untouched: no gate, no mirror, no slot substitution. This
# is deliberate and is NOT covered by the mirroring rule below, whose
# subject is tables this script assembles itself.
if ($inBytes.Length -eq 2048 -and (Get-FontFormat $inBytes) -eq 'RAW') {
    if (-not (Test-GlyphBlank $inBytes (32 * 8))) { Write-GlyphSpaceWarning $In }
    [System.IO.File]::WriteAllBytes($Out, $inBytes)
    "$Out : source=$In shape=2048 (full table, passthrough) bytes=2048"
    exit 0
}

# A 768-byte raw file keeps its historic meaning: chars 32-127.
$firstChar = $First
if ($firstChar -lt 0) {
    if ($inBytes.Length -eq 768 -and (Get-FontFormat $inBytes) -eq 'RAW') { $firstChar = 32 }
    elseif ((Get-FontFormat $inBytes) -eq 'RAW') {
        throw "fontconv: $In is a raw glyph table of $($inBytes.Length) bytes ($($inBytes.Length / 8) glyphs). Only 2048 (a full table) and 768 (chars 32-127) are recognised on their own - pass -First <code> naming the character code of the first glyph, for example -First 16 for a 112-glyph table covering characters 16-127."
    }
    else { $firstChar = 0 }
}

$font  = Read-FontFile $inBytes $In $firstChar $Face
$table = Build-GlyphTable $font $baseBytes $Slots $In

if (-not (Test-GlyphBlank $table (32 * 8))) { Write-GlyphSpaceWarning $In }
[System.IO.File]::WriteAllBytes($Out, $table)
"$Out : source=$In format=$($font.Format) face='$($font.FaceName)' cell=$($font.Width)x$($font.Height) bytes=2048$script:AssemblyNote"
exit 0
