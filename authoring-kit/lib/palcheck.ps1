# Audit a converted Layer 2 picture's transparency - one warning (a
# colour colliding with the reserved value) and one count (pixels on the
# reserved index).
# gfx2next -pal-embed writes a 512-byte palette (256 x 2-byte 9-bit
# entries, RRRGGGBB then blue LSB) followed by the pixel bytes, so both
# checks read the file the interpreter will actually load. A positioned
# picture (NXP) has a 16-byte header first; its declared palette range
# also gets an out-of-range pixel check.
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
if ($Path -match '\.(ZX0|NPZ)$') { exit 0 }     # compressed: the header is plain, the body is not
$b = [System.IO.File]::ReadAllBytes($Path)
$base = 0; $palFirst = 0; $palLast = 255; $isNxp = $false
if ($b.Length -ge 16 -and $b[0] -eq 0x4E -and $b[1] -eq 0x58 -and $b[2] -eq 0x50) {
    $isNxp = $true; $base = 16; $palFirst = $b[12]; $palLast = $b[13]
    $nh = if ($b[11] -eq 0) { 256 } else { $b[11] }
    if ($b.Length -ne 16 + 512 + ($b[9] + 256 * $b[10]) * $nh) { exit 0 }   # compressed or truncated
}
if ($b.Length -lt ($base + 512)) { exit 0 }   # compressed or not a raw picture

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
for ($i = $base; $i -lt $base + 512; $i += 2) {
    $idx = ($i - $base) / 2
    if ($b[$i] -eq $TRANSP -and $idx -ne $RESERVED) { $hits += $idx }
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
for ($i = $base + 512; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq $RESERVED) { $transparent++ }
}
if ($transparent -gt 0) {
    Write-Output "$name has $transparent transparent pixel(s) at palette index $RESERVED. They show the text layer through. If you did not mean this picture to have holes, quantize your source art to 255 colours (indices 0-254) so index $RESERVED stays unused, and re-convert."
}
# 3. NXP only: pixels outside the declared palette range draw with whatever
#    colour another picture left in that entry.
if ($isNxp -and $palFirst -le $palLast) {
    $outside = 0
    for ($i = $base + 512; $i -lt $b.Length; $i++) {
        $v = $b[$i]
        if ($v -ne $RESERVED -and ($v -lt $palFirst -or $v -gt $palLast)) { $outside++ }
    }
    if ($outside -gt 0) {
        Write-Output "$name declares palette $palFirst-$palLast but $outside pixel(s) use palette indices outside it. Those pixels take whatever colour the last picture left in that entry. Widen palette= in the sidecar, or re-quantise with a NextDither preset that blocks the other slots."
    }
}
exit 0
