# Packs a sprite sheet into NNN.ANI for GFX n 19/20/21.
# -Png given: -Spr is gfx2next -sprites -pal-none output (PLTE indices).
# -Png absent: -Spr is a ready-made gfx2next -sprites -pal-std file (final bytes).
param(
    [Parameter(Mandatory=$true)][string]$Spr,
    [Parameter(Mandatory=$true)][string]$Txt,
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$Png
)
$ErrorActionPreference = 'Stop'

# Transparency constants: mirrored from src\nextdaad.inc, held in sync by
# Assert-TranspConstantsInSync in tests\build-tests.ps1.
$TRANSP = 0xE3
$DODGE  = 0xE7
$HIDDEN = 255
$TABLE_MAX = 1024

if (-not (Test-Path $Spr)) { throw "anipack: $Spr not found" }
if (-not (Test-Path $Txt)) { throw "anipack: sidecar $Txt not found" }
if ($Spr -match '\.zx0$') { throw "anipack: $Spr is compressed - sprite sheets must not be built with -zx0" }

# ---- sidecar
$keys = @{}
foreach ($line in Get-Content $Txt) {
    $l = ($line -replace ';.*$', '').Trim()
    if ($l -eq '') { continue }
    if ($l -notmatch '^(\w+)\s*=\s*(.+)$') { throw "anipack: $Txt - cannot parse '$line'" }
    $keys[$Matches[1].ToLower()] = $Matches[2].Trim()
}
function Key([string]$k, $default) { if ($keys.ContainsKey($k)) { return $keys[$k] } else { return $default } }
foreach ($req in 'w', 'h') { if (-not $keys.ContainsKey($req)) { throw "anipack: $Txt - '$req' is required" } }
$w = [int]$keys['w']; $h = [int]$keys['h']
if ($w % 16 -or $h % 16 -or $w -lt 16 -or $h -lt 16 -or $w -gt 128 -or $h -gt 128) { throw "anipack: $Txt - w and h must be multiples of 16 from 16 to 128 (got ${w}x${h})" }
$x = [int](Key 'x' 0); $y = [int](Key 'y' 0)
if ($x -lt 0 -or $x -gt 319 -or $y -lt 0 -or $y -gt 255) { throw "anipack: $Txt - x must be 0-319 and y 0-255" }
$loop = [int](Key 'loop' 1)
$bitsKey = Key 'bits' $null
if ($bitsKey -and $bitsKey -ne '8' -and $bitsKey -ne '4') { throw "anipack: $Txt - bits must be 8 or 4" }

# ---- source bytes
# Named $sprBytes, not $spr: PowerShell variables are case-insensitive, so
# $spr would alias the [string]$Spr parameter slot and silently coerce this
# byte array back to a string on assignment.
$sprBytes = [IO.File]::ReadAllBytes($Spr)
if ($sprBytes.Length -eq 0 -or $sprBytes.Length % 256) { throw "anipack: $Spr is $($sprBytes.Length) bytes, not a multiple of 256 - not an 8-bit gfx2next sprite file" }
$cellCount = $sprBytes.Length / 256
$plte = $null
if ($Png) {
    # PLTE chunk read as plain bytes; gfx2next has already rejected non-paletted input.
    $b = [IO.File]::ReadAllBytes($Png)
    $p = 8; $ihdr = $null
    while ($p + 8 -le $b.Length) {
        $len = ([int]$b[$p] -shl 24) -bor ([int]$b[$p+1] -shl 16) -bor ([int]$b[$p+2] -shl 8) -bor [int]$b[$p+3]
        $type = [Text.Encoding]::ASCII.GetString($b, $p + 4, 4)
        if ($type -eq 'IHDR') { $ihdr = $b[($p+8)..($p+20)] }
        if ($type -eq 'PLTE') { $plte = $b[($p+8)..($p+8+$len-1)] }
        if ($type -eq 'IEND') { break }
        $p += 12 + $len
    }
    if (-not $ihdr -or -not $plte) { throw "anipack: $Png - no IHDR/PLTE chunk (not a paletted PNG)" }
    if ($ihdr[9] -ne 3) { throw "anipack: $Png - colour type $($ihdr[9]), expected 3 (paletted)" }
    $imgW = ([int]$ihdr[0] -shl 24) -bor ([int]$ihdr[1] -shl 16) -bor ([int]$ihdr[2] -shl 8) -bor [int]$ihdr[3]
    $imgH = ([int]$ihdr[4] -shl 24) -bor ([int]$ihdr[5] -shl 16) -bor ([int]$ihdr[6] -shl 8) -bor [int]$ihdr[7]
    if ($imgW % 16 -or $imgH % 16) { throw "anipack: $Png is ${imgW}x${imgH} - sheet width and height must be multiples of 16" }
    $sheetW = [int](Key 'sheetw' $imgW)
} else {
    if ($bitsKey -eq '4') { throw "anipack: $Spr - a ready-made .spr is 8-bit only (bits=4 needs a PNG sheet)" }
    $sheetW = [int](Key 'sheetw' $w)
}
if ($sheetW % $w) { throw "anipack: sheetw $sheetW is not a multiple of w $w" }
$cellsPerRow = $sheetW / 16
$framesPerRow = $sheetW / $w
$cw = $w / 16; $ch = $h / 16; $cells = $cw * $ch
$sheetRows = [math]::Floor($cellCount / $cellsPerRow)
$frameRows = [math]::Floor($sheetRows / $ch)
$frameCount = [int](Key 'frames' ($framesPerRow * $frameRows))
if ($frameCount -lt 1 -or $frameCount -gt 255 -or $frameCount -gt $framesPerRow * $frameRows) { throw "anipack: frames=$frameCount but the sheet holds $($framesPerRow * $frameRows)" }
$delays = @((Key 'delay' 5) -split ',' | ForEach-Object { [int]$_ })
if ($delays.Count -eq 1) { $delays = @($delays[0]) * $frameCount }
if ($delays.Count -ne $frameCount) { throw "anipack: delay lists $($delays.Count) values for $frameCount frames" }
foreach ($d in $delays) { if ($d -lt 1 -or $d -gt 255) { throw "anipack: delay $d out of range 1-255" } }

# ---- colour tables (PNG path). $col9[i] = 9-bit RGB333 or -1 for transparent.
$col9 = $null; $col8 = $null
if ($Png) {
    $n = [math]::Floor($plte.Length / 3)
    $col9 = New-Object int[] 256; $col8 = New-Object int[] 256
    for ($i = 0; $i -lt 256; $i++) {
        if ($i -ge $n) { $col9[$i] = -1; $col8[$i] = $TRANSP; continue }
        $r = $plte[$i*3]; $g = $plte[$i*3+1]; $bl = $plte[$i*3+2]
        if ($r -eq 255 -and $g -eq 0 -and $bl -eq 255) { $col9[$i] = -1; $col8[$i] = $TRANSP; continue }
        # truncate each channel to its top 3 bits, as the picture encoder does.
        # cast to int first: -shl on a Byte operand wraps within 8 bits.
        $c9 = (([int]$r -shr 5) -shl 6) -bor (([int]$g -shr 5) -shl 3) -bor ([int]$bl -shr 5)
        $col9[$i] = $c9
        $c8 = $c9 -shr 1
        if ($c8 -eq $TRANSP) { $c8 = $DODGE }
        $col8[$i] = $c8
    }
}

# ---- unpack cells per frame: cellsRaw[f][c] = 256 index bytes (PNG) or final bytes (.spr)
function CellBytes([int]$sheetCol, [int]$sheetRow) {
    $k = $sheetRow * $cellsPerRow + $sheetCol
    if ($k -ge $cellCount) { throw "anipack: frame layout reaches cell $k but the sheet has $cellCount cells" }
    return $sprBytes[($k*256)..($k*256+255)]
}
$frames = @()
for ($f = 0; $f -lt $frameCount; $f++) {
    $fx = $f % $framesPerRow; $fy = [math]::Floor($f / $framesPerRow)
    $cellsOfFrame = @()
    for ($cy = 0; $cy -lt $ch; $cy++) { for ($cx = 0; $cx -lt $cw; $cx++) {
        $cellsOfFrame += , (CellBytes ($fx * $cw + $cx) ($fy * $ch + $cy))
    } }
    $frames += , $cellsOfFrame
}

# ---- 4-bit path
function Get-Partition4($frames, $col9) {
    # Greedy, deterministic: cells sorted by opaque colour count descending,
    # each joins the first block whose colour union stays at or under 15.
    $cellSets = @()
    for ($f = 0; $f -lt $frames.Count; $f++) {
        for ($c = 0; $c -lt $frames[$f].Count; $c++) {
            $set = @{}
            foreach ($idx in $frames[$f][$c]) { if ($col9[$idx] -ge 0) { $set[$col9[$idx]] = $true } }
            if ($set.Count -gt 15) { return @{ ok = $false; why = "frame $f cell $c needs $($set.Count) opaque colours, a 4-bit cell holds 15" } }
            $cellSets += , @{ f = $f; c = $c; colours = @($set.Keys) }
        }
    }
    $blocks = New-Object System.Collections.ArrayList
    $cellBlock = @{}
    foreach ($cs in ($cellSets | Sort-Object { -$_.colours.Count }, { $_.f }, { $_.c })) {
        $placed = -1
        for ($b = 0; $b -lt $blocks.Count; $b++) {
            $union = @{}
            foreach ($k in $blocks[$b]) { $union[$k] = $true }
            foreach ($k in $cs.colours) { $union[$k] = $true }
            if ($union.Count -le 15) { $blocks[$b] = @($union.Keys | Sort-Object); $placed = $b; break }
        }
        if ($placed -lt 0) {
            if ($blocks.Count -ge 15) { return @{ ok = $false; why = 'the art needs more than 15 palette blocks' } }
            [void]$blocks.Add(@($cs.colours | Sort-Object)); $placed = $blocks.Count - 1
        }
        $cellBlock["$($cs.f)/$($cs.c)"] = $placed
    }
    return @{ ok = $true; why = ''; blocks = $blocks; cellBlock = $cellBlock }
}

function Get-BlockEntry($blk, $partition) {
    # entry n of a block: 0,1,2,4..15 hold colours in sorted order, 3 is transparent
    $map = @{}
    $slot = 0
    foreach ($k in $partition.blocks[$blk]) { if ($slot -eq 3) { $slot++ }; $map[$k] = $slot; $slot++ }
    return $map
}

function Convert-Cell4($raw, $col9, $partition) {
    $f = $script:curF; $c = $script:curC
    $blk = $partition.cellBlock["$f/$c"]
    $map = Get-BlockEntry $blk $partition
    $bytes = New-Object byte[] 128
    $transparent = $true
    for ($i = 0; $i -lt 256; $i++) {
        $k = $col9[$raw[$i]]
        $n = if ($k -lt 0) { 3 } else { $transparent = $false; $map[$k] }
        if ($i % 2 -eq 0) { $bytes[$i / 2] = $n -shl 4 } else { $bytes[($i - 1) / 2] = $bytes[($i - 1) / 2] -bor $n }
    }
    return @{ bytes = $bytes; block = $blk; transparent = $transparent }
}

function Get-BlockPalette($blk) {
    $out = New-Object byte[] 32
    for ($e = 0; $e -lt 16; $e++) { $out[$e*2] = $TRANSP; $out[$e*2+1] = 1 }
    $map = Get-BlockEntry $blk $partition
    foreach ($k in $map.Keys) {
        $e = $map[$k]
        $out[$e*2] = $k -shr 1
        $out[$e*2+1] = $k -band 1
    }
    return $out
}

# ---- kind decision. 4-bit partition lives in Get-Partition4 (Task 3); 8-bit here.
$is4 = $false
$partition = $null
if ($Png -and $bitsKey -ne '8') {
    $partition = Get-Partition4 $frames $col9
    if ($partition.ok) { $is4 = $true }
    elseif ($bitsKey -eq '4') { throw "anipack: bits=4 but $($partition.why)" }
}

# ---- dedupe: pattern key is the final byte image (8-bit) or the nibble image (4-bit)
$patterns = New-Object System.Collections.ArrayList
$patIndex = @{}
$table = New-Object System.Collections.ArrayList
$blockOf = New-Object System.Collections.ArrayList   # per pattern, 4-bit only
for ($f = 0; $f -lt $frameCount; $f++) {
    [void]$table.Add([byte]$delays[$f])
    for ($c = 0; $c -lt $cells; $c++) {
        $raw = $frames[$f][$c]
        $script:curF = $f; $script:curC = $c
        if ($is4) { $img = Convert-Cell4 $raw $col9 $partition; $blk = $img.block; $bytes = $img.bytes; $transparent = $img.transparent }
        else {
            $bytes = New-Object byte[] 256
            $transparent = $true
            for ($i = 0; $i -lt 256; $i++) {
                $v = if ($Png) { $col8[$raw[$i]] } else { [int]$raw[$i] }
                $bytes[$i] = $v
                if ($v -ne $TRANSP) { $transparent = $false }
            }
            $blk = 0
        }
        if ($transparent -and $c -ne 0) { [void]$table.Add([byte]$HIDDEN); continue }
        $key = [Convert]::ToBase64String($bytes) + "/$blk"
        if (-not $patIndex.ContainsKey($key)) {
            $patIndex[$key] = $patterns.Count
            [void]$patterns.Add($bytes)
            [void]$blockOf.Add($blk)
        }
        [void]$table.Add([byte]$patIndex[$key])
    }
}
# 4-bit: the FILE format allows 127 patterns but the runtime can only ever
# allocate 126 half-slots (0 and 1 belong to the mouse pointer), so a
# 127-pattern set would be refused at load. Reject it here instead.
$maxPat = if ($is4) { 126 } else { 63 }
if ($patterns.Count -gt $maxPat) {
    $why = if ($is4) { '126 - pattern half-slots 0 and 1 are the mouse pointer''s, so a 127-pattern 4-bit set could never be loaded' } else { '63' }
    throw "anipack: $($patterns.Count) unique cells, the limit is $why for $(if ($is4) {'4-bit'} else {'8-bit'}) sets"
}
if ($table.Count -gt $TABLE_MAX) { throw "anipack: frame table is $($table.Count) bytes, the limit is $TABLE_MAX ($frameCount frames of $cells cells)" }

# ---- 8-bit block mask
$mask = 0
if (-not $is4) { foreach ($pat in $patterns) { foreach ($v in $pat) { if ($v -ne $TRANSP) { $mask = $mask -bor (1 -shl ($v -shr 4)) } } } }

# ---- emit
$o = New-Object System.Collections.ArrayList
[void]$o.AddRange([byte[]](0x4E, 0x41, 1, (($loop -band 1) -bor ($(if ($is4) { 2 } else { 0 })))))
[void]$o.AddRange([byte[]]($cw, $ch, ($x -band 255), ($x -shr 8), $y, $frameCount, $patterns.Count))
[void]$o.Add([byte]$(if ($is4) { $partition.blocks.Count } else { 0 }))
[void]$o.AddRange([byte[]](($mask -band 255), ($mask -shr 8), ($table.Count -band 255), ($table.Count -shr 8)))
[void]$o.AddRange([byte[]]$table)
if ($is4) {
    [void]$o.AddRange([byte[]]$blockOf)
    for ($b = 0; $b -lt $partition.blocks.Count; $b++) { [void]$o.AddRange([byte[]](Get-BlockPalette $b)) }
}
foreach ($pat in $patterns) { [void]$o.AddRange([byte[]]$pat) }
[IO.File]::WriteAllBytes($Out, [byte[]]$o)
$kind = if ($is4) { "4-bit, $($partition.blocks.Count) block(s)" } else { "8-bit, blocks " + ('{0:X4}' -f $mask) }
"  sprite $([IO.Path]::GetFileName($Out)): ${w}x${h}, $frameCount frame(s), $($patterns.Count) cell(s), $kind, $($o.Count) bytes"
exit 0
