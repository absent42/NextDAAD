# Extracts an 8x16 bitmap font from a Windows .FON (NE resource, FNT 2.0/3.0)
# into a 256 x 16 byte table: rows top to bottom, bit 7 = leftmost pixel.
param([Parameter(Mandatory)][string]$Fon, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$d = [IO.File]::ReadAllBytes($Fon)
function U16([int]$o) { [int]$d[$o] + 256 * [int]$d[$o + 1] }
function U32([int]$o) { (U16 $o) + 65536 * (U16 ($o + 2)) }
if ((U16 0) -ne 0x5A4D) { throw 'not an MZ executable' }
$ne = U16 0x3C
if ((U16 $ne) -ne 0x454E) { throw 'not an NE executable' }
$rt = $ne + (U16 ($ne + 0x24))
$shift = U16 $rt
$p = $rt + 2
$fnt = -1
while ((U16 $p) -ne 0) {
    $type = U16 $p; $count = U16 ($p + 2); $p += 8
    for ($i = 0; $i -lt $count; $i++) {
        if ($type -eq 0x8008 -and $fnt -lt 0) { $fnt = (U16 $p) * [int][math]::Pow(2, $shift) }
        $p += 12
    }
}
if ($fnt -lt 0) { throw 'no RT_FONT resource' }
$ver = U16 $fnt
$height = U16 ($fnt + 88)
$first = [int]$d[$fnt + 95]; $last = [int]$d[$fnt + 96]
if ($height -ne 16) { throw "font height is $height, expected 16" }
$table = if ($ver -ge 0x300) { $fnt + 148 } else { $fnt + 118 }
$entry = if ($ver -ge 0x300) { 6 } else { 4 }
$o = New-Object byte[] 4096
for ($c = $first; $c -le $last; $c++) {
    $e = $table + ($c - $first) * $entry
    if ((U16 $e) -gt 8) { throw "glyph $c is wider than 8" }
    $off = if ($ver -ge 0x300) { U32 ($e + 2) } else { U16 ($e + 2) }
    for ($r = 0; $r -lt 16; $r++) { $o[$c * 16 + $r] = $d[$fnt + $off + $r] }
}
[IO.File]::WriteAllBytes($Out, $o)
"wrote $Out (chars $first-$last, FNT version $('{0:X}' -f $ver))"
