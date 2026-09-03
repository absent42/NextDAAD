# Assertions over authoring-kit\lib\anipack.ps1 and the gfx2next
# behaviours it relies on. Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\anipack-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$gfx  = "$root\tools\gfx2next\gfx2next.exe"
$pack = "$root\authoring-kit\lib\anipack.ps1"
$work = "$root\tests\out\anipack"
$checks = 0
if (-not (Test-Path $gfx)) { throw "anipack-selftest: gfx2next not found at $gfx" }

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "anipack-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    $threw = $false
    try { & $sb | Out-Null } catch { $threw = $true; if ($_.Exception.Message -notmatch $pattern) { throw "anipack-selftest: $what - wrong message: $($_.Exception.Message)" } }
    if (-not $threw) { throw "anipack-selftest: $what - did not fail" }
}
function Convert-Sheet([string]$png, [string[]]$extra) {
    # gfx2next writes <base>.spr into the CWD, exactly as lib\gfx.bat runs it.
    $base = [IO.Path]::GetFileNameWithoutExtension($png)
    Remove-Item "$work\$base.spr", "$work\$base.spr.zx0" -ErrorAction SilentlyContinue
    Push-Location $work
    try { & $gfx -sprites -pal-none @extra $png | Out-Null; $code = $LASTEXITCODE } finally { Pop-Location }
    return $code
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
& python "$root\tests\art\mkanisheets.py" $work
if ($LASTEXITCODE -ne 0) { throw "anipack-selftest: mkanisheets.py failed" }

# ---- Probe 1: raw index mode emits PLTE indices, cells row-major across the sheet.
Assert-Eq (Convert-Sheet "$work\001.png" @()) 0 'probe: gfx2next exit code'
$spr = [IO.File]::ReadAllBytes("$work\001.spr")
Assert-Eq $spr.Length 1536 'probe: six cells of 256 bytes'
for ($k = 0; $k -lt 6; $k++) {
    Assert-Eq $spr[$k * 256] ($k + 1) "probe: cell $k first byte is PLTE index $($k + 1) (row-major order)"
    Assert-Eq $spr[$k * 256 + 255] ($k + 1) "probe: cell $k last byte"
}
# ---- Probe 2: -zx0 names the output .spr.zx0 (the packer rejects that name).
Assert-Eq (Convert-Sheet "$work\001.png" @('-zx0')) 0 'probe: -zx0 exit code'
Assert-Eq (Test-Path "$work\001.spr.zx0") $true 'probe: -zx0 writes 001.spr.zx0'
Assert-Eq (Test-Path "$work\001.spr") $false 'probe: -zx0 leaves no plain .spr'
# ---- Probe 3: a sheet that is not a multiple of 16 drops the partial cells silently.
& python -c "import sys; sys.path.insert(0, r'$root\tests\art'); import mkanisheets as m; m.write_png(r'$work\odd.png', 24, 16, [m.MAGENTA] + [(0,0,0)]*255, m.fill(24, 16, 0))"
Assert-Eq (Convert-Sheet "$work\odd.png" @()) 0 'probe: 24-wide sheet exit code'
Assert-Eq ([IO.File]::ReadAllBytes("$work\odd.spr")).Length 256 'probe: 24-wide sheet yields one cell, the partial column is dropped'

function Pack([string]$n, [string[]]$extra) {
    & $pack -Spr "$work\$n.spr" -Txt "$work\$n.txt" -Out "$work\$n.ANI" -Png "$work\$n.png" @extra | Out-Null
    return [IO.File]::ReadAllBytes("$work\$n.ANI")
}
function U16([byte[]]$b, [int]$o) { return [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8) }

# ---- 002 torch: two 8-bit patterns, baked position, per-frame delays, loop.
Convert-Sheet "$work\002.png" @() | Out-Null
$a = Pack '002' @()
Assert-Eq ([Text.Encoding]::ASCII.GetString($a, 0, 2)) 'NA' '002 magic'
Assert-Eq $a[2] 1 '002 version'
Assert-Eq $a[3] 1 '002 flags: loop, 8-bit'
Assert-Eq $a[4] 1 '002 W'; Assert-Eq $a[5] 1 '002 H'
Assert-Eq (U16 $a 6) 24 '002 X'; Assert-Eq $a[8] 180 '002 Y'
Assert-Eq $a[9] 2 '002 frames'; Assert-Eq $a[10] 2 '002 patterns'
Assert-Eq $a[11] 0 '002 blockCount'
# (255,128,0) -> $F0 top nibble F; (255,255,0) -> $FC top nibble F: mask bit 15 only.
Assert-Eq (U16 $a 12) 0x8000 '002 blockMask'
Assert-Eq (U16 $a 14) 4 '002 tableLen'
Assert-Eq $a[16] 6 '002 frame 0 delay'; Assert-Eq $a[17] 0 '002 frame 0 cell'
Assert-Eq $a[18] 12 '002 frame 1 delay'; Assert-Eq $a[19] 1 '002 frame 1 cell'
Assert-Eq $a.Length (20 + 512) '002 length'
Assert-Eq $a[20] 0xE3 '002 pattern 0 pixel 0 is transparent'
Assert-Eq $a[21] 0xF0 '002 pattern 0 pixel 1 is (255,128,0) as RGB332'
Assert-Eq $a[20 + 256] 0xFC '002 pattern 1 pixel 0'

# ---- 003 dedupe, hidden cell, one-shot. Cells: p0=green, p1=blue, p2=white.
Convert-Sheet "$work\003.png" @() | Out-Null
$a = Pack '003' @()
Assert-Eq $a[3] 0 '003 flags: one-shot, 8-bit'
Assert-Eq $a[4] 2 '003 W'; Assert-Eq $a[5] 2 '003 H'
Assert-Eq $a[9] 2 '003 frames'; Assert-Eq $a[10] 3 '003 patterns (dupe folded)'
Assert-Eq (U16 $a 14) 10 '003 tableLen'
$t = $a[16..25]
Assert-Eq ($t -join ',') '5,0,1,255,0,5,0,1,255,2' '003 frame table'
Assert-Eq $a.Length (26 + 768) '003 length'

# ---- 004 blank anchor: an all-transparent cell 0 becomes a blank pattern, never 255.
Convert-Sheet "$work\004.png" @() | Out-Null
$a = Pack '004' @()
Assert-Eq $a[10] 1 '004 one blank pattern'
Assert-Eq $a[17] 0 '004 cell 0 is pattern 0, not hidden'
Assert-Eq $a[16 + 2] 0xE3 '004 blank pattern is all transparent'

# ---- 005 dodge: opaque (224,0,192) lands on $E3 and is written as $E7.
Convert-Sheet "$work\005.png" @() | Out-Null
$a = Pack '005' @()
Assert-Eq $a[18] 0xE7 '005 dodge to $E7'
Assert-Eq (U16 $a 12) 0x4000 '005 blockMask is block 14 ($E7 top nibble E)'

# ---- 009 sheetw: four frames two per row, cell k = index k+1 -> RGB332 of the palette.
Convert-Sheet "$work\009.png" @() | Out-Null
$a = Pack '009' @()
Assert-Eq $a[9] 4 '009 frames'; Assert-Eq $a[10] 4 '009 patterns'
Assert-Eq $a[16 + 8 + 256 * 2] 0x03 '009 pattern 2 is (0,0,255) -> $03 (frame 2 is row 1, col 0)'

# ---- 006 4-bit auto: two frames of 10 colours each -> two blocks.
Convert-Sheet "$work\006.png" @() | Out-Null
$a = Pack '006' @()
Assert-Eq $a[3] 3 '006 flags: loop, 4-bit'
Assert-Eq $a[10] 2 '006 patterns'; Assert-Eq $a[11] 2 '006 blockCount'
Assert-Eq (U16 $a 12) 0 '006 blockMask is 0 for 4-bit'
Assert-Eq (U16 $a 14) 4 '006 tableLen'
# body: table(4) + block table(2) + palettes(64) + patterns(2*128)
Assert-Eq $a.Length (16 + 4 + 2 + 64 + 256) '006 length'
Assert-Eq $a[20] 0 '006 pattern 0 block'; Assert-Eq $a[21] 1 '006 pattern 1 block'
$pal0 = $a[22..53]
Assert-Eq $pal0[6] 0xE3 '006 block 0 entry 3 byte0 is $E3 (transparent slot)'
Assert-Eq $pal0[7] 1 '006 block 0 entry 3 byte1'
# frame 0 pixel (0,0) is PLTE 1 = (32,0,64): r=1,g=0,b=2 -> RGB333 0x42 -> byte0 $21, byte1 0
$found = $false
for ($e = 0; $e -lt 16; $e++) { if ($e -ne 3 -and $pal0[$e*2] -eq 0x21 -and $pal0[$e*2+1] -eq 0) { $found = $true } }
Assert-Eq $found $true '006 block 0 holds (32,0,64) as byte0 $21, byte1 0'
$pat0 = $a[86..213]
# every nibble of pattern 0 must be an entry other than 3 (cell has no transparent pixel)
$bad = 0
foreach ($v in $pat0) { if ((($v -shr 4) -eq 3) -or (($v -band 15) -eq 3)) { $bad++ } }
Assert-Eq $bad 0 '006 pattern 0 never uses the transparent nibble'

# ---- 007 auto falls back to 8-bit when a cell needs 16 opaque colours.
Convert-Sheet "$work\007.png" @() | Out-Null
$a = Pack '007' @()
Assert-Eq $a[3] 1 '007 flags: fell back to 8-bit'
Assert-Eq $a.Length (16 + 2 + 256) '007 length'

# ---- 008 bits=4 explicit with the same art must fail naming the cell.
Convert-Sheet "$work\008.png" @() | Out-Null
Assert-Throws { Pack '008' @() } 'frame 0 cell 0 .* 16 opaque colours' '008 bits=4 refuses a 16-colour cell'

# ---- ready-made 8-bit .spr from a real gfx2next -pal-std file: proves the bytes
# gfx2next wrote pass through unmodified (the -pal-std snap for (224,0,192) is
# $C2, not the raw RGB332 truncation $E3 - observed; either way anipack must not
# touch it). The dodge-avoidance property itself is pinned by case 016 below,
# with a synthetic $E3 cell that bypasses gfx2next's palette snapping entirely.
Push-Location $work
try { & $gfx -sprites -pal-std -pal-none "$work\005.png" | Out-Null } finally { Pop-Location }
Copy-Item "$work\005.spr" "$work\010.spr" -Force
Copy-Item "$work\005.txt" "$work\010.txt" -Force
& $pack -Spr "$work\010.spr" -Txt "$work\010.txt" -Out "$work\010.ANI" | Out-Null
$a = [IO.File]::ReadAllBytes("$work\010.ANI")
Assert-Eq $a[18] 0xC2 '010 ready-made -pal-std bytes pass through unchanged ($C2 stays $C2)'
Assert-Eq $a[3] 1 '010 flags: 8-bit, loop default'
# ---- rejections
[IO.File]::WriteAllBytes("$work\011.spr", (New-Object byte[] 300))
Copy-Item "$work\002.txt" "$work\011.txt" -Force
Assert-Throws { & $pack -Spr "$work\011.spr" -Txt "$work\011.txt" -Out "$work\011.ANI" } 'not a multiple of 256' '011 wrong length'
Assert-Throws { & $pack -Spr "$work\001.spr.zx0" -Txt "$work\001.txt" -Out "$work\012.ANI" } 'compressed' '012 .spr.zx0 rejected'
Set-Content "$work\013.txt" "w=16`nh=16`nbits=4"
Copy-Item "$work\010.spr" "$work\013.spr" -Force
Assert-Throws { & $pack -Spr "$work\013.spr" -Txt "$work\013.txt" -Out "$work\013.ANI" } '8-bit only' '013 ready-made with bits=4'
Set-Content "$work\014.txt" "h=16"
Assert-Throws { & $pack -Spr "$work\010.spr" -Txt "$work\014.txt" -Out "$work\014.ANI" } "'w' is required" '014 missing w'

# ---- 019 a 4-bit set with 127 unique patterns: a legal file the runtime can
# never load (half-slots 0 and 1 are the pointer's, leaving 126), so the packer
# refuses it. 017 with its 126 patterns is the accepted case, packed by the
# -Sprites leg of tests\build-tests.ps1.
Convert-Sheet "$work\019.png" @() | Out-Null
Assert-Throws { Pack '019' @() } 'the limit is 126' '019 127 unique 4-bit cells refused'

# ---- 016 synthetic $E3 cell: a hand-built .spr, not gfx2next output, so the
# byte values are exact and known - proves a byte that WOULD be dodged on the
# PNG path ($E3) survives untouched on the no-Png ready-made path.
$spr016 = New-Object byte[] 256
for ($i = 0; $i -lt 256; $i++) { $spr016[$i] = 0xE3 }
$spr016[1] = 0x00
$spr016[2] = 0xE7
[IO.File]::WriteAllBytes("$work\016.spr", $spr016)
Set-Content "$work\016.txt" "w=16`nh=16`nbits=8"
& $pack -Spr "$work\016.spr" -Txt "$work\016.txt" -Out "$work\016.ANI" | Out-Null
$a = [IO.File]::ReadAllBytes("$work\016.ANI")
Assert-Eq $a[18] 0xE3 '016 pattern pixel 0 stays $E3, not dodged to $E7'
Assert-Eq $a[19] 0x00 '016 pattern pixel 1'
Assert-Eq $a[20] 0xE7 '016 pattern pixel 2'
Assert-Eq (U16 $a 12) 0x4001 '016 blockMask blocks 0 and 14 ($E3 bytes never counted)'

"anipack-selftest: $checks checks passed"
