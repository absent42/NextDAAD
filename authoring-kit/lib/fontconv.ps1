# authoring-kit/lib/fontconv.ps1
#
# Builds a NextDAAD FONT.CHR: the interpreter installs this file by a
# plain byte-for-byte copy into the tilemap driver's glyph table
# (TM_DEFS, src/tilemap.asm tm_font_init / src/overlay2.asm font_load) -
# 256 glyphs x 8 rows, 1bpp, exactly 2048 bytes. This converter's output
# IS the installed bytes.
#
# INPUT FORMATS, detected from the file's own signature, never from its
# extension (lib\fontfmt.ps1, Get-FontFormat):
#   FON    'MZ' - NE executable wrapping one or more FNT faces. -Face
#          picks one; without it an exact 8x8 face wins, else the
#          tallest face whose MEASURED ink fits the cell.
#   PSF1   0x36 0x04 - Linux console font, 8px wide, mode bit 0 selects
#          a 512-glyph table.
#   PSF2   0x72 0xB5 0x4A 0x86 - console font with a declared cell;
#          only 32-127 is read (any Unicode table is ignored).
#   BDF    'STARTFONT' - X11 bitmap font, glyphs positioned from the
#          baseline rather than stacked.
#   YAFF   text, a label line ('0x41:') followed by indented rows of
#          '.' paper and '@' ink - monobit's native format and the one
#          hoard-of-bitfonts ships. Codepoint labels name the slot;
#          u+XXXX and 'A' labels only below 128. shift-up places a
#          raster against the baseline, left-bearing shifts it right.
#          'encoding: zx-spectrum' gets the classic ZX slot exemption,
#          any 437 codepage counts as OEM.
#   DRAW   text, a bare hex label ('41:') with rows of '-' paper and
#          '#' ink on the label line or below it - monobit's hexdraw,
#          the hoard's other format. No metrics: rows stack.
#   SINTAC 'JSJ SINTAC' - DAAD Ready's PC.FNT / PCDAAD's DAAD.FNT -
#          refused by name (per-character width table, not a fixed cell).
#   RAW    anything else - headerless dump, 8 rows per glyph. 2048
#          bytes = full table, 768 bytes = chars 32-127; any other
#          length needs -First naming the first glyph's code.
#
# PASSTHROUGH: a 2048-byte RAW input is written out untouched - no gate,
# no slot substitution, no mirror. Everything below is about tables
# this script ASSEMBLES from a partial source.
#
# ACCEPTANCE GATE: measures the real ink extent over codes 32-127
# instead of trusting the source's declared cell (declarations are
# routinely pessimistic). Ink reaching row 8+ inside 32-127 is fatal
# and names the codes; outside that range the glyph is DROPPED (base
# font's glyph stays) and counted. Declared width above 8px is fatal
# inside 32-127, dropped and counted outside it. The same ink
# measurement picks the face for a multi-face FON. Nothing is ever
# cropped, scaled or squeezed to fit - a squeezed 9-row source was
# unusable on real hardware (descenders lose the row that reads them).
#
# SLOT MAP of an assembled table:
#   0-15     base font (no print path reaches these)
#   16-31    source where supplied, else base
#   32-127   source, with the ZX slot substitutions below
#   128-159  source where supplied, else base
#   160-255  mirror of the assembled 32-127
# The mirror is a fix, not a preference. Glyphs 160-255 are what the
# engine prints ordinary characters through under an upper-charset
# window or the GFX ON escape (glyph = char + 128), so leaving them as
# the base font makes such a game print half a sentence in the author's
# face and half in the built-in one.
#
# ZX SLOT SUBSTITUTIONS (-Slots ZX, the default). CP437 and the ZX
# charset disagree at exactly two printable codes: 96 is a grave accent
# on a PC and a pound sterling here, 127 is a house on a PC and a
# copyright sign here. Both come from the base font by default, except
# 96 lifts from the source's own slot 156 instead when the source
# declares itself OEM and that slot is non-blank. A 768-byte RAW input
# read at its historic first character is EXEMPT from both
# substitutions (that shape IS a classic ZX charset already), and so
# is a source that declares the ZX charset by name (YAFF 'encoding:
# zx-spectrum'). -Slots
# Source turns both substitutions off everywhere. The output line
# always says which path ran.
#
# -Base <file> (SP18): source for every glyph the input doesn't supply
# (0-15 always, plus 16-31/128-159 where the input has nothing) so a
# second font conversion doesn't silently lose UDGs/accents the first
# font defined. Must itself be a full 2048-byte table; validated
# unconditionally. Does not reach 160-255 (mirrored from 32-127).
#
# default.chr is a byte-for-byte copy of src/font.chr (SHA256
# 9de51ef5d66c06f2845eacede265c303ddbaa10b5e47583d1f7b077ed2802c64).
# Re-verify with `sha256sum src/font.chr authoring-kit/lib/default.chr`
# whenever either file changes.
#
# GLYPH 32 (space): the tilemap driver relies on it having an all-zero
# bitmap (src/tilemap.asm's tm_clear_blank comment) - every blanked cell
# is filled with glyph 32 at the default attribute, so a non-zero glyph
# 32 shows as ink-coloured specks instead of clean black paper. This is
# a WARNING, not a build failure. The check runs on the bytes about to
# be written (input or assembled table), never against a -Base file on
# its own.
#
# Usage: fontconv.ps1 -In <font file in any format listed above>
#          [-Out FONT.CHR] [-Base <2048-byte font supplying the glyphs
#          the input does not, default default.chr>]
#          [-First <character code of a raw dump's first glyph>]
#          [-Face <index|WxH>, FON only] [-Slots ZX|Source]
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

# Blank-glyph-32 warning: a 768-byte RAW source may be gfx2next's
# -font-y output (rows interleaved) misread as -font; the two are
# indistinguishable from the file, so this is usually the only signal.
function Write-GlyphSpaceWarning([string]$src, [bool]$classicShape) {
    $msg = "$src : glyph 32 (space) is not all-zero - the tilemap driver relies on it staying blank, or blanked cells show ink-coloured specks instead of clean black paper (see src/tilemap.asm's tm_clear_blank comment); the font will still install as given"
    if ($classicShape) {
        $msg += ". If this came from gfx2next, check you used -font and not -font-y: a -font-y file is the same size but has its rows interleaved, and it cannot be converted"
    }
    Write-Warning $msg
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

# Assemble the 2048-byte table (slot map: see header).
function Build-GlyphTable($font, [byte[]]$baseBytes, [string]$slots, [string]$src, [bool]$classicZx) {
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

    # A glyph whose bitmap ran past the end of the file was never read
    # either - see fontfmt.ps1's Truncated. Inside the text range that is
    # the same refusal again, and for the same reason: a missing glyph is
    # indistinguishable from a code the source never covered, so the base
    # font's glyph would stand there and the converter would print a
    # clean success line over half an alphabet in the built-in face.
    # Outside the text range it folds into the drop-and-count path.
    $truncated = @()
    if ($font.PSObject.Properties['Truncated'] -and $font.Truncated) { $truncated = @($font.Truncated) }
    $truncText = @($truncated | Where-Object { $_ -ge 32 -and $_ -le 127 })
    if ($truncText.Count -gt 0) {
        $names = ($truncText | Select-Object -First 8) -join ', '
        throw "fontconv: $src is truncated - the glyph data for character code(s) $names runs past the end of the file, so $($truncText.Count) glyph(s) inside 32-127 could not be read at all. Converting anyway would leave the base font's glyphs in those slots and say nothing about it."
    }
    $truncDecorative = @($truncated | Where-Object { $_ -lt 32 -or $_ -gt 127 })

    $table = [byte[]]$baseBytes.Clone()
    $notes = @()

    # 16-31, 32-127 and 128-159 straight from the source where it has
    # them. A source glyph outside the text range that would not fit the
    # cell is DROPPED, keeping the base font's glyph, rather than
    # clipped - half a box-drawing character appearing in a game with no
    # explanation is worse than not getting it at all.
    $dropped = $overWideDecorative.Count + $truncDecorative.Count
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
    if ($dropped -gt 0) { $notes += "$dropped decorative glyph(s) outside 32-127 dropped (not fitting the cell, or unreadable data)" }

    # ZX slot substitutions. CP437 and the ZX charset disagree at exactly
    # two printable codes: 96 is a grave accent on a PC and a pound
    # sterling here, 127 is a house on a PC and a copyright sign here.
    # Left alone a game printing a price prints a backtick.
    #
    # A 768-byte RAW source is EXEMPT. That shape self-identifies as
    # chars 32-127 of the ZX charset - it already carries a pound at 96
    # and usually a copyright at 127, drawn in its own face - so
    # substituting there would swap two correct glyphs for the base
    # font's, in a visibly different face, on the commonest input the
    # kit has. The exemption is that shape alone: a raw dump of any
    # other length placed with -First has no declared ordering and could
    # be either charset, so it keeps the substitution, with -Slots
    # Source as the escape hatch.
    if ($slots -eq 'ZX' -and $font.Charset -eq 'ZX') {
        $notes += 'source declares the ZX charset: glyphs 96 and 127 kept from the source'
    }
    elseif ($slots -eq 'ZX' -and $classicZx) {
        $notes += 'classic 768-byte ZX charset: glyphs 96 and 127 kept from the source'
    }
    elseif ($slots -eq 'ZX') {
        $poundFrom = 'base'
        if ($font.Charset -eq 'OEM' -and $font.Glyphs.ContainsKey(156)) {
            $src156 = $font.Glyphs[156]
            $blank = $true
            foreach ($r in $src156) { if ($r -ne 0) { $blank = $false } }
            # Slot 156 gets the same fits check every other lifted glyph
            # gets. Without it an oversized face ships a clipped pound in
            # the same breath as the line saying a glyph was dropped for
            # not fitting the cell.
            $fits156 = $true
            for ($r = 8; $r -lt $src156.Length; $r++) { if ($src156[$r] -ne 0) { $fits156 = $false } }
            if (-not $blank -and $fits156) {
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
    else {
        # -Slots Source. Nothing is substituted, and the output line says
        # so - the header above, and the manual, both promise that the
        # line names which path ran, and silence is not a name.
        $notes += 'no substitution (-Slots Source): glyphs 96 and 127 kept from the source'
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
    if (-not (Test-GlyphBlank $inBytes (32 * 8))) { Write-GlyphSpaceWarning $In $false }
    [System.IO.File]::WriteAllBytes($Out, $inBytes)
    "$Out : source=$In shape=2048 (full table, passthrough) bytes=2048"
    exit 0
}

$isRaw = (Get-FontFormat $inBytes) -eq 'RAW'

# A length that is not a multiple of 8 can never be a glyph table, with
# or without -First. Diagnose that FIRST, so a file that cannot work is
# refused once instead of being sent away for an option that will not
# save it.
if ($isRaw -and $inBytes.Length % 8 -ne 0) {
    throw "fontconv: $In is $($inBytes.Length) bytes, which is not a multiple of 8 - a raw glyph table is 8 rows per glyph, so its length must divide by 8. No value of -First can make this file readable."
}

# A 768-byte raw file keeps its historic meaning: chars 32-127.
$firstChar = $First
if ($firstChar -lt 0) {
    if ($inBytes.Length -eq 768 -and $isRaw) { $firstChar = 32 }
    elseif ($isRaw) {
        throw "fontconv: $In is a raw glyph table of $($inBytes.Length) bytes ($([int]($inBytes.Length / 8)) glyphs). Only 2048 (a full table) and 768 (chars 32-127) are recognised on their own - pass -First <code> naming the character code of the first glyph, for example -First 16 for a 112-glyph table covering characters 16-127."
    }
    else { $firstChar = 0 }
}

# -First placing every glyph outside the range an assembled table draws
# from is a silent no-op otherwise: nothing of the source reaches the
# output, and the line still reports a clean success. The range is
# 16-159, not 32-127 - the slot map takes 16-31 and 128-159 from the
# source as well, and a raw dump placed at either of those is a
# first-class case, the only way to bring an author's UDGs or decorative
# glyphs in from a headerless file.
if ($isRaw) {
    $lastChar = $firstChar + [int]($inBytes.Length / 8) - 1
    if ($firstChar -gt 159 -or $lastChar -lt 16) {
        throw "fontconv: -First $firstChar puts this $($inBytes.Length)-byte dump's $([int]($inBytes.Length / 8)) glyphs at character codes $firstChar-$lastChar. An assembled table takes the source's glyphs at 16-31, 32-127 and 128-159 only, and none of these lands in any of them, so no source glyph would reach the output at all."
    }
}

# The classic ZX charset shape, for the slot-substitution exemption in
# Build-GlyphTable: a RAW file of exactly 768 bytes read at its historic
# first character. A 768-byte dump handed a different -First is a raw
# dump of unknown ordering, not a ZX charset, and is not exempt.
$classicZx = ($inBytes.Length -eq 768 -and $isRaw -and $firstChar -eq 32)

$font  = Read-FontFile $inBytes $In $firstChar $Face
if ($font.Charset -eq 'ZX') { $classicZx = $true }   # declared, not inferred from shape
$table = Build-GlyphTable $font $baseBytes $Slots $In $classicZx

if (-not (Test-GlyphBlank $table (32 * 8))) { Write-GlyphSpaceWarning $In $isRaw }
[System.IO.File]::WriteAllBytes($Out, $table)
"$Out : source=$In format=$($font.Format) face='$($font.FaceName)' cell=$($font.Width)x$($font.Height) bytes=2048$script:AssemblyNote"
exit 0
