# introc.ps1 - compile INTRO.TXT into RELEASE\INTRO\INTRO.DAT plus the show's
# assets, and stage the launcher. Called by lib\intro.bat; pinned by
# tests\intro-selftest.ps1. Paths in the script are relative to -Root.
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Cols = '',
    [string]$Gfx = '',
    [string]$S2A = '',
    [string]$S2Y = '',
    [string]$Ffmpeg = '',
    [string]$NdawBin = '',
    [string]$Palcheck = '',
    [string]$Aysconv = '',
    [string]$Launcher = '',
    [string]$LauncherOut = '',
    [switch]$NoAssets
)
$ErrorActionPreference = 'Stop'
# Tool paths arrive relative from the kit's own TOOLSDIR default; resolve
# each to absolute here so Invoke-Gfx2Next's Push-Location cannot break it.
# A value that names no existing file is left as-is so the caller's own
# text still shows in the "not found at '...'" errors below.
foreach ($p in 'Gfx', 'S2A', 'S2Y', 'Ffmpeg', 'NdawBin', 'Aysconv', 'Palcheck') {
    $v = Get-Variable -Name $p -ValueOnly
    if ($v -and (Test-Path -LiteralPath $v -PathType Leaf)) { Set-Variable -Name $p -Value (Resolve-Path -LiteralPath $v).Path }
}
# Script/Root must exist to resolve (left as-is otherwise, so the caller's own
# text still shows in the "not found" errors below); Out may not exist yet, so
# it is resolved against $PWD instead. All three are absolute before any
# Push-Location (Invoke-Gfx2Next) can make a relative one resolve wrong.
if (Test-Path -LiteralPath $Script) { $Script = (Resolve-Path -LiteralPath $Script).Path }
if (Test-Path -LiteralPath $Root) { $Root = (Resolve-Path -LiteralPath $Root).Path }
$Out = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.Path, $Out))
$enc = [Text.Encoding]::GetEncoding(28591)

function Fail([int]$line, [string]$msg) {
    if ($line -gt 0) { throw "INTRO.TXT line ${line}: $msg" }
    throw "INTRO.TXT: $msg"
}
function Warn([string]$msg) { Write-Host "  WARNING: $msg" }

# ---- tokeniser: words and "strings" ("" inside a string is one quote) ----
function Split-Tokens([string]$text, [int]$line) {
    $tokens = New-Object Collections.Generic.List[object]
    $i = 0; $n = $text.Length
    while ($i -lt $n) {
        $c = $text[$i]
        if ($c -eq ';') { break }
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '"') {
            $sb = New-Object Text.StringBuilder
            $i++
            $closed = $false
            while ($i -lt $n) {
                $c = $text[$i]
                if ($c -eq '"') {
                    if ($i + 1 -lt $n -and $text[$i + 1] -eq '"') { [void]$sb.Append('"'); $i += 2; continue }
                    $closed = $true; $i++; break
                }
                [void]$sb.Append($c); $i++
            }
            if (-not $closed) { Fail $line 'unterminated string' }
            $tokens.Add(@{ str = $true; v = $sb.ToString() })
            continue
        }
        $j = $i
        while ($j -lt $n -and -not [char]::IsWhiteSpace($text[$j]) -and $text[$j] -ne ';' -and $text[$j] -ne '"') { $j++ }
        $tokens.Add(@{ str = $false; v = $text.Substring($i, $j - $i) })
        $i = $j
    }
    return , $tokens
}
function Word($tok) { if ($tok.str) { return $null }; return $tok.v.ToUpperInvariant() }

# ---- value parsers ----
function Parse-Frames($tok, [int]$line, [double]$min, [double]$max, [string]$what) {
    if ($tok.str -or $tok.v -notmatch '^\d+(\.\d)?$') { Fail $line "$what must be seconds with at most one decimal, got '$($tok.v)'" }
    $s = [double]::Parse($tok.v, [Globalization.CultureInfo]::InvariantCulture)
    if ($s -lt $min -or $s -gt $max) { Fail $line "$what must be $min to $max seconds" }
    return [int][math]::Round($s * 50)
}
function Parse-Colour($tok, [int]$line, [string]$what) {
    if ($tok.str -or $tok.v -notmatch '^\d+$' -or [int]$tok.v -gt 255) { Fail $line "$what must be a colour number 0 to 255" }
    return [int]$tok.v
}
function Parse-Int($tok, [int]$line, [int]$min, [int]$max, [string]$what) {
    if ($tok.str -or $tok.v -notmatch '^\d+$' -or [int]$tok.v -lt $min -or [int]$tok.v -gt $max) { Fail $line "$what must be $min to $max" }
    return [int]$tok.v
}

# ---- PNG header and PLTE ----
function Read-PngInfo([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 33 -or $b[0] -ne 0x89 -or $b[1] -ne 0x50) { return $null }
    $w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
    $h = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
    $info = @{ width = $w; height = $h; depth = [int]$b[24]; ctype = [int]$b[25]; plte = @() }
    $p = 8
    while ($p + 8 -le $b.Length) {
        $len = ([int]$b[$p] -shl 24) -bor ([int]$b[$p + 1] -shl 16) -bor ([int]$b[$p + 2] -shl 8) -bor [int]$b[$p + 3]
        $type = [Text.Encoding]::ASCII.GetString($b, $p + 4, 4)
        if ($type -eq 'PLTE') {
            $plte = @()
            for ($k = 0; $k -lt $len; $k += 3) { $plte += , @([int]$b[$p + 8 + $k], [int]$b[$p + 9 + $k], [int]$b[$p + 10 + $k]) }
            $info.plte = $plte
        }
        if ($type -eq 'IEND') { break }
        $p += 12 + $len
    }
    return $info
}

# ---- picture identity: width from a PNG header or a ready-made file's size ----
function Get-PictureShape([string]$file, [int]$line) {
    $path = Join-Path $Root $file
    if (-not (Test-Path -LiteralPath $path)) { Fail $line "picture not found: $file" }
    $ext = [IO.Path]::GetExtension($file).ToUpperInvariant()
    if ($ext -eq '.PNG') {
        $i = Read-PngInfo $path
        if ($null -eq $i) { Fail $line "$file is not a PNG" }
        if ($i.depth -ne 8 -or $i.ctype -ne 3) { Fail $line "$file must be an 8-bit paletted PNG" }
        if ($i.width -eq 320 -and $i.height -eq 256) { return @{ mode = 1; kind = 'png' } }
        if ($i.width -eq 256 -and $i.height -eq 192) { return @{ mode = 0; kind = 'png' } }
        Fail $line "$file is $($i.width)x$($i.height); a slide is exactly 320x256 or 256x192"
    }
    $len = (Get-Item -LiteralPath $path).Length
    if ($ext -eq '.NX2' -and $len -eq 82432) { return @{ mode = 1; kind = 'nx2' } }
    if ($ext -eq '.NXI' -and $len -eq 49664) { return @{ mode = 0; kind = 'nxi' } }
    Fail $line "$file must be a PNG, a 320x256 NX2 (82432 bytes) or a 256x192 NXI (49664 bytes)"
}

# ---- colour helpers: 0-255 RGB332 -> 9-bit pair; RGB888 -> 9-bit pair ----
function Colour9([int]$c) { return @([byte]$c, [byte]$(if ($c -band 3) { 1 } else { 0 })) }
function Rgb9([int]$r, [int]$g, [int]$b) {
    return @([byte](($r -band 0xE0) -bor (($g -band 0xE0) -shr 3) -bor (($b -band 0xC0) -shr 6)), [byte](($b -shr 5) -band 1))
}
$TRANSP9 = @([byte]0xE3, [byte]1)

# ---- parse ----
if (-not (Test-Path -LiteralPath $Script)) { throw "script not found: $Script" }
$lines = [IO.File]::ReadAllLines($Script, $enc)
$show = @{
    music = @{ kind = 0; file = '' }; fontFile = ''; fontKind = 0; palettes = @{}
    cols = $(if ($Cols -eq '40') { 40 } else { 80 }); border = 0
    skipMode = 0; skipWin = 50; loop = $false
    slides = New-Object Collections.Generic.List[object]
    endSeen = $false; endTr = 0; endCol = 0; endFrames = 0
}
$cur = $null
$transitions = @{ CUT = 0; FADE = 1; DISSOLVE = 6; BLINDS = 7 }
$wipeDirs = @{ LEFT = 2; RIGHT = 3; UP = 4; DOWN = 5 }

function New-Item2([int]$line, [int]$type, [string]$str) {
    return @{ line = $line; type = $type; row = 0; col = 0; centre = $false; str = $str; at = 0; typew = $false; ink = -2; paper = -2; block = -1 }
}
function Parse-ColourWords($t, [int]$from, [int]$line, $item, [bool]$allowAtType) {
    $k = $from
    while ($k -lt $t.Count) {
        $w = Word $t[$k]
        switch ($w) {
            'AT'    { if (-not $allowAtType) { Fail $line 'AT is only valid on TEXT' }; if ($k + 1 -ge $t.Count) { Fail $line 'AT needs a time' }; $item.at = Parse-Frames $t[$k + 1] $line 0 600 'AT'; $k += 2 }
            'TYPE'  { if (-not $allowAtType) { Fail $line 'TYPE is only valid on TEXT' }; $item.typew = $true; $k++ }
            'INK'   { if ($k + 1 -ge $t.Count) { Fail $line 'INK needs a colour' }; $item.ink = Parse-Colour $t[$k + 1] $line 'INK'; $k += 2 }
            'PAPER' { if ($k + 1 -ge $t.Count) { Fail $line 'PAPER needs a colour' }; $item.paper = Parse-Colour $t[$k + 1] $line 'PAPER'; $k += 2 }
            'BLOCK' { if ($k + 1 -ge $t.Count) { Fail $line 'BLOCK needs a number' }; $item.block = Parse-Int $t[$k + 1] $line 0 15 'BLOCK'; $k += 2 }
            default { Fail $line "unexpected '$($t[$k].v)'" }
        }
    }
}

for ($ln = 0; $ln -lt $lines.Count; $ln++) {
    $line = $ln + 1
    $t = Split-Tokens $lines[$ln] $line
    if ($t.Count -eq 0) { continue }
    if ($t[0].str) { Fail $line 'a statement cannot start with a string' }
    if ($show.endSeen) { Fail $line 'nothing may follow END' }
    $kw = Word $t[0]
    $inHeader = ($show.slides.Count -eq 0)
    switch ($kw) {
        'MUSIC' {
            if (-not $inHeader) { Fail $line 'MUSIC must come before the first SLIDE' }
            if ($show.music.kind -ne 0) { Fail $line 'only one MUSIC statement is allowed' }
            if ($t.Count -ne 3) { Fail $line 'MUSIC <AKY|STREAM|PCM|NDR> <file>' }
            $kinds = @{ AKY = 1; STREAM = 2; PCM = 3; NDR = 4 }
            $k = Word $t[1]
            if ($null -eq $k -or -not $kinds.ContainsKey($k)) { Fail $line 'MUSIC kind must be AKY, STREAM, PCM or NDR' }
            $show.music = @{ kind = $kinds[$k]; file = $t[2].v }
            if (-not (Test-Path -LiteralPath (Join-Path $Root $t[2].v))) { Fail $line "music file not found: $($t[2].v)" }
        }
        'FONT' {
            if (-not $inHeader) { Fail $line 'FONT must come before the first SLIDE' }
            if ($t.Count -ne 2) { Fail $line 'FONT GAME or FONT <sheet.png>' }
            if ((Word $t[1]) -eq 'GAME') { $show.fontFile = ''; $show.fontKind = 0 }
            else {
                $show.fontFile = $t[1].v; $show.fontKind = 1
                $fp = Join-Path $Root $t[1].v
                if (-not (Test-Path -LiteralPath $fp)) { Fail $line "font sheet not found: $($t[1].v)" }
                $fi = Read-PngInfo $fp
                if ($null -eq $fi -or $fi.depth -ne 8 -or $fi.ctype -ne 3) { Fail $line 'a font sheet is an 8-bit paletted PNG' }
                if ($fi.width -ne 128 -or $fi.height -ne 128) { Fail $line 'a font sheet is 128x128: 16 by 16 cells of 8x8' }
                if ($fi.plte.Count -gt 16) { Fail $line "a font sheet has at most 16 palette entries, this one has $($fi.plte.Count)" }
                $show.fontPlte = $fi.plte
            }
        }
        'PALETTE' {
            if (-not $inHeader) { Fail $line 'PALETTE must come before the first SLIDE' }
            if ($t.Count -ne 18) { Fail $line 'PALETTE <block 1-15> then sixteen colours' }
            $n = Parse-Int $t[1] $line 1 15 'PALETTE block'
            $cols16 = @()
            for ($k = 2; $k -lt 18; $k++) { $cols16 += Parse-Colour $t[$k] $line 'PALETTE colour' }
            $show.palettes[$n] = $cols16
        }
        'COLS' {
            if (-not $inHeader) { Fail $line 'COLS must come before the first SLIDE' }
            if ($t.Count -ne 2 -or ($t[1].v -ne '40' -and $t[1].v -ne '80')) { Fail $line 'COLS 40 or COLS 80' }
            $show.cols = [int]$t[1].v
        }
        'BORDER' {
            if (-not $inHeader) { Fail $line 'BORDER must come before the first SLIDE' }
            if ($t.Count -ne 2) { Fail $line 'BORDER <colour>' }
            $show.border = Parse-Colour $t[1] $line 'BORDER'
        }
        'SKIP' {
            if (-not $inHeader) { Fail $line 'SKIP must come before the first SLIDE' }
            if ($t.Count -lt 2) { Fail $line 'SKIP ANY [seconds], SKIP SLIDE or SKIP NONE' }
            switch (Word $t[1]) {
                'ANY'   { $show.skipMode = 0; if ($t.Count -eq 3) { $show.skipWin = Parse-Frames $t[2] $line 0 5 'SKIP window' } elseif ($t.Count -ne 2) { Fail $line 'SKIP ANY [seconds]' } }
                'SLIDE' { if ($t.Count -ne 2) { Fail $line 'SKIP SLIDE takes no time' }; $show.skipMode = 1 }
                'NONE'  { if ($t.Count -ne 2) { Fail $line 'SKIP NONE takes no time' }; $show.skipMode = 2 }
                default { Fail $line 'SKIP ANY, SLIDE or NONE' }
            }
        }
        'LOOP' {
            if (-not $inHeader) { Fail $line 'LOOP must come before the first SLIDE' }
            if ($t.Count -ne 1) { Fail $line 'LOOP takes nothing' }
            $show.loop = $true
        }
        'SLIDE' {
            if ($t.Count -lt 4) { Fail $line 'SLIDE <picture> IN <transition> [time] [colour] HOLD <seconds>|KEY' }
            $cur = @{ line = $line; pic = $t[1].v; tr = -1; trFrames = 0; col = 0; hold = -1; holdKind = 'NONE'; items = New-Object Collections.Generic.List[object]; scroll = $null }
            $cur.shape = Get-PictureShape $cur.pic $line
            $k = 2
            while ($k -lt $t.Count) {
                switch (Word $t[$k]) {
                    'IN' {
                        if ($k + 1 -ge $t.Count) { Fail $line 'IN needs a transition' }
                        $tr = Word $t[$k + 1]
                        if ($tr -eq 'CUT') { $cur.tr = 0; $k += 2 }
                        elseif ($tr -eq 'FADE' -or $tr -eq 'DISSOLVE' -or $tr -eq 'BLINDS') {
                            if ($k + 2 -ge $t.Count) { Fail $line "$tr needs a time" }
                            $cur.tr = $transitions[$tr]; $cur.trFrames = Parse-Frames $t[$k + 2] $line 0.1 10 "$tr time"; $k += 3
                            if ($tr -eq 'FADE' -and $k -lt $t.Count -and -not $t[$k].str -and $t[$k].v -match '^\d+$') { $cur.col = Parse-Colour $t[$k] $line 'FADE colour'; $k++ }
                        }
                        elseif ($tr -eq 'WIPE') {
                            if ($k + 3 -ge $t.Count) { Fail $line 'WIPE LEFT|RIGHT|UP|DOWN <time>' }
                            $d = Word $t[$k + 2]
                            if ($null -eq $d -or -not $wipeDirs.ContainsKey($d)) { Fail $line 'WIPE direction is LEFT, RIGHT, UP or DOWN' }
                            $cur.tr = $wipeDirs[$d]; $cur.trFrames = Parse-Frames $t[$k + 3] $line 0.1 10 'WIPE time'; $k += 4
                        }
                        else { Fail $line "unknown transition '$($t[$k + 1].v)'" }
                    }
                    'HOLD' {
                        if ($k + 1 -ge $t.Count) { Fail $line 'HOLD <seconds> or HOLD KEY' }
                        if ((Word $t[$k + 1]) -eq 'KEY') { $cur.holdKind = 'KEY'; $cur.hold = 0xFFFF }
                        else { $cur.holdKind = 'TIME'; $cur.hold = Parse-Frames $t[$k + 1] $line 0.1 600 'HOLD' }
                        $k += 2
                    }
                    default { Fail $line "unexpected '$($t[$k].v)' on SLIDE" }
                }
            }
            if ($cur.tr -lt 0) { Fail $line 'SLIDE needs IN <transition>' }
            $show.slides.Add($cur)
        }
        'TEXT' {
            if ($null -eq $cur) { Fail $line 'TEXT must follow a SLIDE' }
            if ($t.Count -lt 4) { Fail $line 'TEXT <row> <col|CENTRE> "text" [AT t] [TYPE] [INK c] [PAPER c] [BLOCK n]' }
            if (-not $t[3].str) { Fail $line 'TEXT needs a quoted string as its third argument' }
            $it = New-Item2 $line 0 $t[3].v
            $it.row = Parse-Int $t[1] $line 0 31 'TEXT row'
            if ((Word $t[2]) -eq 'CENTRE') { $it.centre = $true } else { $it.col = Parse-Int $t[2] $line 0 79 'TEXT column' }
            Parse-ColourWords $t 4 $line $it $true
            $cur.items.Add($it)
        }
        'SCROLL' {
            if ($null -eq $cur) { Fail $line 'SCROLL must follow a SLIDE' }
            if ($null -ne $cur.scroll) { Fail $line 'one SCROLL per slide' }
            if ($t.Count -lt 3 -or (Word $t[1]) -ne 'SPEED') { Fail $line 'SCROLL SPEED <1-4> [INK c] [PAPER c] [BLOCK n]' }
            $sc = New-Item2 $line 1 ''
            $sc.speed = Parse-Int $t[2] $line 1 4 'SCROLL SPEED'
            Parse-ColourWords $t 3 $line $sc $false
            $cur.scroll = $sc
        }
        'LINE' {
            if ($null -eq $cur -or $null -eq $cur.scroll) { Fail $line 'LINE must follow a SCROLL' }
            if ($t.Count -ne 2 -or -not $t[1].str) { Fail $line 'LINE "text"' }
            $it = New-Item2 $line 1 $t[1].v
            $it.centre = $true
            $cur.items.Add($it)
        }
        'END' {
            if ($t.Count -lt 2) { Fail $line 'END CUT or END FADE <time> [colour]' }
            switch (Word $t[1]) {
                'CUT'  { if ($t.Count -ne 2) { Fail $line 'END CUT takes nothing' }; $show.endTr = 0 }
                'FADE' {
                    if ($t.Count -lt 3 -or $t.Count -gt 4) { Fail $line 'END FADE <time> [colour]' }
                    $show.endTr = 1; $show.endFrames = Parse-Frames $t[2] $line 0.1 10 'END FADE time'
                    if ($t.Count -eq 4) { $show.endCol = Parse-Colour $t[3] $line 'END FADE colour' }
                }
                default { Fail $line 'END CUT or END FADE' }
            }
            $show.endSeen = $true
        }
        default { Fail $line "unknown statement '$($t[0].v)'" }
    }
}

# ---- validate ----
if (-not $show.endSeen) { Fail 0 'END is missing' }
if ($show.slides.Count -lt 1) { Fail 0 'no SLIDE' }
if ($show.slides.Count -gt 64) { Fail $show.slides[64].line 'more than 64 slides' }
if ($show.loop -and $show.skipMode -ne 0) { Fail 0 'LOOP needs SKIP ANY' }
if ($show.palettes.Count -gt 0 -and $show.fontKind -ne 1) { Fail 0 'PALETTE needs a colour font (FONT <sheet.png>)' }
$itemsTotal = 0
foreach ($s in $show.slides) {
    if ($null -ne $s.scroll) {
        if ($s.holdKind -ne 'NONE') { Fail $s.line 'a slide with SCROLL has no HOLD' }
        if ($s.items.Count -eq 0) { Fail $s.scroll.line 'SCROLL needs at least one LINE' }
        foreach ($it in $s.items) { if ($it.type -eq 0) { Fail $it.line 'TEXT and SCROLL cannot share a slide' } }
        $s.hold = 0xFFFE
    }
    elseif ($s.holdKind -eq 'NONE') { Fail $s.line 'SLIDE needs HOLD <seconds> or HOLD KEY (or a SCROLL)' }
    $itemsTotal += $s.items.Count
    $all = $s.items.ToArray()
    if ($null -ne $s.scroll) { $all += $s.scroll }
    foreach ($it in $all) {
        if ($show.fontKind -eq 1) {
            if ($it.ink -ne -2 -or $it.paper -ne -2) { Fail $it.line 'INK and PAPER are for the 1-bit font; a colour font uses BLOCK' }
            if ($it.block -lt 0) { $it.block = 0 }
        }
        else {
            if ($it.block -ge 0) { Fail $it.line 'BLOCK is for a colour font; the 1-bit font uses INK and PAPER' }
            if ($it.ink -eq -2) { $it.ink = 255 }
            if ($it.paper -eq -2) { $it.paper = -1 }
        }
        if ($it.type -eq 0 -or $it.str.Length -gt 0) {
            $max = $show.cols
            if ($it.type -eq 0 -and -not $it.centre) { $max = $show.cols - $it.col }
            if ($it.str.Length -gt $max) { Fail $it.line "text of $($it.str.Length) characters does not fit the $($show.cols)-column grid from that column" }
        }
    }
}
if ($itemsTotal -gt 255) { Fail 0 'more than 255 TEXT and LINE items' }
if ($show.slides[0].tr -ge 2) { Fail $show.slides[0].line 'the first slide arrives from nothing: use IN CUT or IN FADE' }
for ($i = 1; $i -lt $show.slides.Count; $i++) {
    $a = $show.slides[$i - 1]; $b = $show.slides[$i]
    if ($a.shape.mode -ne $b.shape.mode -and $b.tr -ge 2) { Fail $b.line 'a width change between slides allows only CUT or FADE' }
}
if ($show.loop -and $show.slides.Count -gt 1) {
    $a = $show.slides[$show.slides.Count - 1]; $b = $show.slides[0]
    if ($a.shape.mode -ne $b.shape.mode -and $b.tr -ge 2) { Fail $b.line 'under LOOP the last and first slides change width, so slide 1 allows only CUT or FADE' }
}

# ---- picture numbers in first-use order ----
$picNums = [ordered]@{}
foreach ($s in $show.slides) { if (-not $picNums.Contains($s.pic)) { $picNums[$s.pic] = $picNums.Count + 1 } }

# ---- text colour resolution: pairs (1-bit) or blocks (colour) ----
$pairs = New-Object Collections.Generic.List[object]
$pairs.Add(@{ ink = 255; paper = -1 })
function Get-Pair([int]$ink, [int]$paper, [int]$line) {
    for ($p = 0; $p -lt $pairs.Count; $p++) { if ($pairs[$p].ink -eq $ink -and $pairs[$p].paper -eq $paper) { return $p } }
    if ($pairs.Count -ge 128) { Fail $line 'more than 128 distinct INK and PAPER combinations' }
    $pairs.Add(@{ ink = $ink; paper = $paper })
    return $pairs.Count - 1
}
function Get-Attr($it) {
    if ($show.fontKind -eq 1) { return ($it.block -shl 4) }
    return ((Get-Pair $it.ink $it.paper $it.line) -shl 1)
}
foreach ($s in $show.slides) {
    foreach ($it in $s.items) { $it.attr = Get-Attr $it }
    if ($null -ne $s.scroll) { $s.scroll.attr = Get-Attr $s.scroll; foreach ($it in $s.items) { $it.attr = $s.scroll.attr } }
}

# ---- INTRO.DAT ----
$dat = New-Object byte[] 8192
function W8([int]$o, [int]$v) { $dat[$o] = [byte]($v -band 255) }
function W16([int]$o, [int]$v) { $dat[$o] = [byte]($v -band 255); $dat[$o + 1] = [byte](($v -shr 8) -band 255) }
$dat[0] = 0x4E; $dat[1] = 0x44; $dat[2] = 0x49; $dat[3] = 0x4E     # NDIN
W8 4 1
$flags = 0
if ($show.loop) { $flags = $flags -bor 1 }
$flags = $flags -bor ($show.skipMode -shl 1)
if ($show.cols -eq 40) { $flags = $flags -bor 8 }
if ($show.fontKind -eq 1) { $flags = $flags -bor 16 }
W8 5 $flags
W8 6 $show.music.kind
W8 7 $show.skipWin
W8 8 $show.endTr
W8 9 $show.endCol
W16 10 $show.endFrames
W8 12 $show.slides.Count
W8 13 $itemsTotal
W8 18 $show.border
# palette, 512 bytes at 32
if ($show.fontKind -eq 1) {
    $plte = $show.fontPlte
    $m = -1
    for ($k = 0; $k -lt $plte.Count; $k++) { if ($plte[$k][0] -eq 255 -and $plte[$k][1] -eq 0 -and $plte[$k][2] -eq 255) { $m = $k; break } }
    if ($m -lt 0) { Fail 0 "font sheet $($show.fontFile) has no magenta (#FF00FF) entry for the transparent colour" }
    $show.fontMagenta = $m
    $block0 = @()
    for ($k = 0; $k -lt 16; $k++) {
        $src = $k
        if ($k -eq 0) { $src = $m } elseif ($k -eq $m) { $src = 0 }
        if ($src -lt $plte.Count) { $block0 += , (Rgb9 $plte[$src][0] $plte[$src][1] $plte[$src][2]) } else { $block0 += , (Colour9 0) }
    }
    for ($blk = 0; $blk -lt 16; $blk++) {
        for ($k = 0; $k -lt 16; $k++) {
            $pair = if ($blk -gt 0 -and $show.palettes.ContainsKey($blk)) { Colour9 $show.palettes[$blk][$k] } else { $block0[$k] }
            $dat[32 + ($blk * 16 + $k) * 2] = $pair[0]
            $dat[33 + ($blk * 16 + $k) * 2] = $pair[1]
        }
    }
}
else {
    for ($p = 0; $p -lt $pairs.Count; $p++) {
        $paper = if ($pairs[$p].paper -lt 0) { $TRANSP9 } else { Colour9 $pairs[$p].paper }
        $ink = Colour9 $pairs[$p].ink
        $dat[32 + $p * 4] = $paper[0]; $dat[33 + $p * 4] = $paper[1]
        $dat[34 + $p * 4] = $ink[0];   $dat[35 + $p * 4] = $ink[1]
    }
}
# strings pool, items and slides
$strOff = 0
$pool = New-Object Collections.Generic.List[byte]
$itemIdx = 0
$si = 0
foreach ($s in $show.slides) {
    $base = 544 + $si * 16
    W8 ($base + 0) $picNums[$s.pic]
    W8 ($base + 1) $s.shape.mode
    W8 ($base + 2) $s.tr
    W8 ($base + 3) $s.col
    W16 ($base + 4) $s.trFrames
    W16 ($base + 6) $s.hold
    W8 ($base + 8) $itemIdx
    W8 ($base + 9) $s.items.Count
    if ($null -ne $s.scroll) { W8 ($base + 10) $s.scroll.speed; W8 ($base + 11) $s.scroll.attr }
    foreach ($it in $s.items) {
        $ib = 1568 + $itemIdx * 12
        W8 ($ib + 0) $it.type
        W8 ($ib + 1) $it.row
        W8 ($ib + 2) $(if ($it.centre) { 255 } else { $it.col })
        W8 ($ib + 3) $it.attr
        W8 ($ib + 4) $(if ($it.typew) { 1 } else { 0 })
        W16 ($ib + 5) $it.at
        W16 ($ib + 7) $pool.Count
        foreach ($b in $enc.GetBytes($it.str)) { $pool.Add($b) }
        $pool.Add(0)
        $itemIdx++
    }
    $si++
}
if ($pool.Count -gt 3500) { Fail 0 "string pool is $($pool.Count) bytes, the limit is 3500" }
W16 14 4628
W16 16 $pool.Count
for ($k = 0; $k -lt $pool.Count; $k++) { $dat[4628 + $k] = $pool[$k] }
$datLen = 4628 + $pool.Count

# ---- assets and output ----
function Invoke-Gfx2Next([string[]]$cmdArgs, [string]$expect) {
    # gfx2next writes <base>.<ext> into the CWD; run it inside $Out and check
    # the file it should have produced exists, since its exit code is unreliable.
    # ($cmdArgs, not $args: $args is PowerShell's automatic variable.)
    Push-Location $Out
    try { & $Gfx @cmdArgs 2>&1 | Out-Null } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath (Join-Path $Out $expect))) { throw "gfx2next produced no $expect - is the source an 8-bit paletted PNG?" }
}
function Convert-Picture([string]$file, [int]$num, $shape) {
    $src = Join-Path $Root $file
    $base = [IO.Path]::GetFileNameWithoutExtension($file)
    $dst = Join-Path $Out ('{0:D3}.{1}' -f $num, $(if ($shape.mode -eq 1) { 'NXC' } else { 'NXI' }))
    switch ($shape.kind) {
        'png' {
            Remove-Item (Join-Path $Out "$base.nxi") -ErrorAction SilentlyContinue
            $mode = if ($shape.mode -eq 1) { '-bitmap-y' } else { '-bitmap' }
            Invoke-Gfx2Next @($mode, '-pal-embed', $src) "$base.nxi"
            Move-Item -LiteralPath (Join-Path $Out "$base.nxi") -Destination $dst -Force
        }
        'nxi' { Copy-Item -LiteralPath $src -Destination $dst -Force }
        'nx2' {
            # row-major NX2 -> column-major NXC: palette copied, pixel (x,y) to 512 + x*256 + y
            $in = [IO.File]::ReadAllBytes($src)
            $o = New-Object byte[] 82432
            [Array]::Copy($in, 0, $o, 0, 512)
            for ($y = 0; $y -lt 256; $y++) {
                $rowBase = 512 + $y * 320
                for ($x = 0; $x -lt 320; $x++) { $o[512 + $x * 256 + $y] = $in[$rowBase + $x] }
            }
            [IO.File]::WriteAllBytes($dst, $o)
        }
    }
    $len = (Get-Item -LiteralPath $dst).Length
    $want = if ($shape.mode -eq 1) { 82432 } else { 49664 }
    if ($len -ne $want) { throw "$file converted to $len bytes, expected $want" }
    if ($Palcheck -and (Test-Path -LiteralPath $Palcheck)) { & $Palcheck $dst }    # in-process: the kit has no pwsh
    Write-Host "  picture $file -> $([IO.Path]::GetFileName($dst))"
}
function Get-PicturePalette([int]$num, [int]$mode) {
    $p = Join-Path $Out ('{0:D3}.{1}' -f $num, $(if ($mode -eq 1) { 'NXC' } else { 'NXI' }))
    $b = [IO.File]::ReadAllBytes($p)
    return $b[0..511]
}
function Convert-Font {
    $src = Join-Path $Root $show.fontFile
    $base = [IO.Path]::GetFileNameWithoutExtension($show.fontFile)
    Remove-Item (Join-Path $Out "$base.nxt"), (Join-Path $Out "$base.nxm") -ErrorAction SilentlyContinue
    Invoke-Gfx2Next @('-colors-4bit', '-tile-size=8x8', '-pal-none', $src) "$base.nxt"
    Remove-Item (Join-Path $Out "$base.nxm") -ErrorAction SilentlyContinue
    $t = [IO.File]::ReadAllBytes((Join-Path $Out "$base.nxt"))
    Remove-Item (Join-Path $Out "$base.nxt") -Force
    if ($t.Length -ne 8192) { throw "font sheet $($show.fontFile) converted to $($t.Length) bytes, expected 8192 (256 tiles of 32)" }
    $m = $show.fontMagenta
    if ($m -ne 0) {
        # swap nibble values 0 and m so the transparent colour is index 0
        for ($k = 0; $k -lt 8192; $k++) {
            $hi = $t[$k] -shr 4; $lo = $t[$k] -band 15
            if ($hi -eq 0) { $hi = $m } elseif ($hi -eq $m) { $hi = 0 }
            if ($lo -eq 0) { $lo = $m } elseif ($lo -eq $m) { $lo = 0 }
            $t[$k] = [byte](($hi -shl 4) -bor $lo)
        }
    }
    [IO.File]::WriteAllBytes((Join-Path $Out 'FONT.TIL'), $t)
    Write-Host "  font $($show.fontFile) -> FONT.TIL"
}
function Invoke-Assets {
    if (-not $Gfx -or -not (Test-Path -LiteralPath $Gfx)) { throw "gfx2next not found at '$Gfx'" }
    foreach ($file in $picNums.Keys) {
        $shape = ($show.slides | Where-Object { $_.pic -eq $file } | Select-Object -First 1).shape
        Convert-Picture $file $picNums[$file] $shape
    }
    if ($show.fontKind -eq 1) { Convert-Font }
    # palette-difference warning for copy transitions
    $prev = $null
    $seq = $show.slides.ToArray()
    if ($show.loop -and $seq.Count -gt 1) { $seq += $seq[0] }
    for ($i = 0; $i -lt $seq.Count; $i++) {
        $s = $seq[$i]
        if ($i -gt 0 -and $s.tr -ge 2 -and $prev.shape.mode -eq $s.shape.mode) {
            $pa = Get-PicturePalette $picNums[$prev.pic] $prev.shape.mode
            $pb = Get-PicturePalette $picNums[$s.pic] $s.shape.mode
            $diff = 0
            for ($e = 0; $e -lt 256; $e++) { if ($pa[$e * 2] -ne $pb[$e * 2] -or $pa[$e * 2 + 1] -ne $pb[$e * 2 + 1]) { $diff++ } }
            if ($diff -gt 8) { Warn "slides at lines $($prev.line) and $($s.line) differ in $diff palette entries; a wipe, dissolve or blinds shows both pictures under the incoming palette - give the sequence one shared palette" }
        }
        $prev = $s
    }
}
function Convert-Music {
    $m = $show.music
    if ($m.kind -eq 0) { return }
    $src = Join-Path $Root $m.file
    switch ($m.kind) {
        1 {
            if (-not $S2A -or -not (Test-Path -LiteralPath $S2A)) { throw "SongToAky not found at '$S2A' (MUSIC AKY needs Arkos Tracker 3)" }
            $dst = Join-Path $Out 'MUSIC.AKY'
            & $S2A -bin --encodingAddress 0xC000 $src $dst | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dst)) { throw "SongToAky failed on $($m.file)" }
            $len = (Get-Item -LiteralPath $dst).Length
            if ($len -gt 16384) { throw "MUSIC.AKY is $len bytes, over the intro's 16384 limit - shorten the tune or use MUSIC STREAM" }
            $b = [IO.File]::ReadAllBytes($dst)
            if ($b.Length -lt 2 -or $b[1] -ne 9) { throw "$($m.file) exports $($b[1]) channels; the player needs a three-PSG (nine channel) song" }
            Write-Host "  music $($m.file) -> MUSIC.AKY ($len bytes)"
        }
        2 {
            if (-not $S2Y -or -not (Test-Path -LiteralPath $S2Y)) { throw "SongToYm not found at '$S2Y' (MUSIC STREAM needs Arkos Tracker 3)" }
            if (-not $Aysconv -or -not (Test-Path -LiteralPath $Aysconv)) { throw "aysconv.ps1 not found at '$Aysconv'" }
            $dst = Join-Path $Out 'MUSIC.AYS'
            & $Aysconv -Song $src -Out $dst -SongToYm $S2Y | Out-Null    # in-process: the kit has no pwsh
            if (-not (Test-Path -LiteralPath $dst)) { throw "aysconv failed on $($m.file)" }
            $len = (Get-Item -LiteralPath $dst).Length
            if ($len -gt 393216) { throw "MUSIC.AYS is $len bytes, over the 393216 (48 page) limit" }
            Write-Host "  music $($m.file) -> MUSIC.AYS ($len bytes)"
        }
        3 {
            if (-not $Ffmpeg -or -not (Test-Path -LiteralPath $Ffmpeg)) { throw "ffmpeg not found at '$Ffmpeg' (MUSIC PCM needs ffmpeg)" }
            $dst = Join-Path $Out 'MUSIC.PCM'
            & $Ffmpeg -y -loglevel error -i $src -ac 2 -ar 15625 -f u8 -acodec pcm_u8 $dst
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dst)) { throw "ffmpeg failed on $($m.file)" }
            $len = (Get-Item -LiteralPath $dst).Length
            if ($len -lt 8192 -or ($len -band 1) -ne 0) { throw "MUSIC.PCM is $len bytes; the stream needs at least 8192 bytes (about a quarter second) and an even length" }
            Write-Host "  music $($m.file) -> MUSIC.PCM ($len bytes, $([math]::Round($len / 31250, 1)) s)"
        }
        4 {
            if (-not $NdawBin -or -not (Test-Path -LiteralPath $NdawBin)) { throw "NextDAW runtime player not found at '$NdawBin' - set NEXTDAWDIR in CONFIG.BAT to your NextDAW install (RuntimePlayer\NextDAW_RuntimePlayer_E000.bin)" }
            $blen = (Get-Item -LiteralPath $NdawBin).Length
            if ($blen -lt 39 -or $blen -gt 8192) { throw "$NdawBin is $blen bytes; the E000 runtime player is expected between 39 and 8192" }
            $len = (Get-Item -LiteralPath $src).Length
            if ($len -gt 65536) { throw "$($m.file) is $len bytes, over the 65536 (eight page) limit" }
            Copy-Item -LiteralPath $NdawBin -Destination (Join-Path $Out 'NDAW.BIN') -Force
            Copy-Item -LiteralPath $src -Destination (Join-Path $Out 'MUSIC.NDR') -Force
            Write-Host "  music $($m.file) -> MUSIC.NDR ($len bytes) with NDAW.BIN from your NextDAW install"
        }
    }
}
New-Item -ItemType Directory -Force $Out | Out-Null
if (-not $NoAssets) {
    Invoke-Assets
    Convert-Music
    if ($Launcher -and $LauncherOut) {
        Copy-Item -LiteralPath $Launcher -Destination $LauncherOut -Force
        Write-Host "  launcher $([IO.Path]::GetFileName($Launcher)) -> $LauncherOut"
    }
}
[IO.File]::WriteAllBytes((Join-Path $Out 'INTRO.DAT'), $dat[0..($datLen - 1)])
Write-Host "  script $([IO.Path]::GetFileName($Script)) -> INTRO.DAT ($datLen bytes, $($show.slides.Count) slide(s), $itemsTotal item(s))"
