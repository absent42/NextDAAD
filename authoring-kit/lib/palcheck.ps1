# Audit a converted Layer 2 picture's transparency - one warning (a
# colour colliding with the reserved value) and one count (pixels on the
# reserved index).
# gfx2next -pal-embed writes a 512-byte palette (256 x 2-byte 9-bit
# entries, RRRGGGBB then blue LSB) followed by the pixel bytes, so both
# checks read the file the interpreter will actually load.
# Advisory only: always exits 0, never fails a build.
#
# THREE FILES carry these values and must agree - src/nextdaad.inc is
# canonical:
#   src/nextdaad.inc          L2_TRANSP_COLOUR / L2_TRANSP_INDEX
#   authoring-kit/lib/nxv2enc.py    L2_TRANSPARENT_BYTE0
#   authoring-kit/lib/palcheck.ps1  $TRANSP / $RESERVED (here)
# If either value moves, all three move. tests/build-tests.ps1 parses all
# three and fails if they disagree.
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { exit 0 }
$b = [System.IO.File]::ReadAllBytes($Path)
if ($b.Length -lt 512) { exit 0 }        # compressed or not a raw picture

$TRANSP = 0xE3      # L2_TRANSP_COLOUR
$RESERVED = 255     # L2_TRANSP_INDEX
$name = Split-Path $Path -Leaf

# 1. Any palette entry whose RRRGGGBB byte matches is shifted on load
#    (l2_palette_load writes $E2 instead), so it renders a different
#    magenta than the author painted rather than punching a hole. The
#    compare ignores the 9th bit, so only the even bytes matter.
$hits = @()
for ($i = 0; $i -lt 512; $i += 2) {
    if ($b[$i] -eq $TRANSP -and ($i / 2) -ne $RESERVED) { $hits += ($i / 2) }
}
if ($hits.Count -gt 0) {
    Write-Output "WARN: $name has a colour that converts to the reserved transparency value (byte 0 = `$E3) at palette index $($hits -join ', '). If you meant those pixels to be transparent, move that colour to palette slot $RESERVED - only that slot is transparent. If you did not, the interpreter shifts the entry two steps down the blue scale on load, so it renders as a slightly different magenta than you painted; move the colour out of near-saturated magenta (red 238 or above, green 18 or below, blue 201 or above) in your source art."
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
