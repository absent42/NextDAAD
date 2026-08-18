# Audit a converted Layer 2 picture's transparency - one warning (a
# colour colliding with the reserved value) and one count (pixels on the
# reserved index).
# gfx2next -pal-embed writes a 512-byte palette (256 x 2-byte 9-bit
# entries, RRRGGGBB then blue LSB) followed by the pixel bytes, so both
# checks read the file the interpreter will actually load.
# Advisory only: always exits 0, never fails a build.
#
# SYNC-CHECKED VALUES - src/nextdaad.inc is canonical; if any value
# moves, all its copies move. tests/build-tests.ps1
# (Assert-TranspConstantsInSync) parses every site and fails on drift:
#   colour: nextdaad.inc L2_TRANSP_COLOUR / nxv2enc.py
#     L2_TRANSPARENT_BYTE0 / $TRANSP (here) / externs/fade/fade.asm TRANSP
#   index:  nextdaad.inc L2_TRANSP_INDEX / $RESERVED (here)
#   dodge:  nextdaad.inc L2_TRANSP_DODGE / fade.asm TRANSP_DODGE /
#     nxv2enc.py L2_DODGE_BYTE0 / $DODGE (here) /
#     tests/art/mkpalcard.py TRANSP_DODGE
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { exit 0 }
$b = [System.IO.File]::ReadAllBytes($Path)
if ($b.Length -lt 512) { exit 0 }        # compressed or not a raw picture

$TRANSP = 0xE3      # L2_TRANSP_COLOUR
$DODGE = 0xE7       # L2_TRANSP_DODGE - what the loader rewrites $E3 to
$RESERVED = 255     # L2_TRANSP_INDEX
$name = Split-Path $Path -Leaf

# 1. Any palette entry whose RRRGGGBB byte matches is shifted on load
#    (l2_palette_load writes $E7 instead - one green step up), so it
#    renders a slightly paler magenta than the author painted rather
#    than punching a hole. The compare ignores the 9th bit, so only
#    the even bytes matter.
$hits = @()
for ($i = 0; $i -lt 512; $i += 2) {
    if ($b[$i] -eq $TRANSP -and ($i / 2) -ne $RESERVED) { $hits += ($i / 2) }
}
if ($hits.Count -gt 0) {
    Write-Output "WARN: $name has a colour that converts to the reserved transparency value (byte 0 = `$E3) at palette index $($hits -join ', '). If you meant those pixels to be transparent, move that colour to palette slot $RESERVED - only that slot is transparent. If you did not, the interpreter shifts the entry one step up the green scale on load (`$E3 -> `$E7), so it renders as a very slightly paler magenta than you painted; move the colour out of near-saturated magenta (red 238 or above, green 18 or below, blue 201 or above) in your source art."
}

# 2. Pixels using the reserved index are transparency - the interpreter
#    stamps that entry on load so they show the text layer through.
#    Never warn: deliberate transparency is the feature working. But a
#    plain 256-colour export scatters pixels onto index 255 by accident,
#    and those are holes too, so the count names the remedy for an
#    author who did not intend any.
$transparent = 0
for ($i = 512; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq $RESERVED) { $transparent++ }
}
if ($transparent -gt 0) {
    Write-Output "$name has $transparent transparent pixel(s) at palette index $RESERVED. They show the text layer through. If you did not mean this picture to have holes, quantize your source art to 255 colours (indices 0-254) so index $RESERVED stays unused, and re-convert."
}
exit 0
