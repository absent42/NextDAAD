# Assertions over authoring-kit\lib\introc.ps1 and the gfx2next behaviours
# it relies on. Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\intro-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$gfx  = "$root\tools\gfx2next\gfx2next.exe"
$comp = "$root\authoring-kit\lib\introc.ps1"
$work = "$root\tests\out\intro"
$checks = 0
if (-not (Test-Path $gfx)) { throw "intro-selftest: gfx2next not found at $gfx" }

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "intro-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    $threw = $false
    try { & $sb | Out-Null } catch { $threw = $true; if ($_.Exception.Message -notmatch $pattern) { throw "intro-selftest: $what - wrong message: $($_.Exception.Message)" } }
    if (-not $threw) { throw "intro-selftest: $what - did not fail" }
}
function U16([byte[]]$b, [int]$o) { return [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8) }
function Hex([byte[]]$b) { return ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
# 4-bit tile layout: 32 bytes/tile, 4 bytes/row, high nibble = left pixel.
# font.chr: 2048 bytes, 256 glyphs x 8 rows, 1 bit/pixel, MSB = left pixel.
# ink is a four-band stripe by glyph row: rows 0-1=1, 2-3=2, 4-5=3, 6-7=4.
function Expected-Tile([byte[]]$chr, [int]$code) {
    $t = New-Object byte[] 32
    for ($row = 0; $row -lt 8; $row++) {
        $ink = 1 + ($row -shr 1)
        $b = $chr[$code * 8 + $row]
        for ($pair = 0; $pair -lt 4; $pair++) {
            $hi = if ($b -band (0x80 -shr ($pair * 2))) { $ink } else { 0 }
            $lo = if ($b -band (0x80 -shr ($pair * 2 + 1))) { $ink } else { 0 }
            $t[$row * 4 + $pair] = [byte](($hi -shl 4) -bor $lo)
        }
    }
    return $t
}
$fontChr = [IO.File]::ReadAllBytes("$root\src\font.chr")
function Compile([string]$name, [string[]]$extra, [string]$suffix = '') {
    $out = "$work\out-$name$suffix"
    Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    # array splatting binds positionally, not by name: turn -Name [value]
    # pairs into a hashtable, which splats by parameter name.
    $named = @{}
    $i = 0
    while ($i -lt $extra.Count) {
        $key = $extra[$i].TrimStart('-')
        if ($i + 1 -lt $extra.Count -and -not $extra[$i + 1].StartsWith('-')) { $named[$key] = $extra[$i + 1]; $i += 2 }
        else { $named[$key] = $true; $i += 1 }
    }
    & $comp -Script "$work\$name.txt" -Root $work -Out $out @named | Out-Null
    return [IO.File]::ReadAllBytes("$out\INTRO.DAT")
}
function Write-Script([string]$name, [string]$text) { [IO.File]::WriteAllText("$work\$name.txt", $text, [Text.Encoding]::GetEncoding(28591)) }

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
& python "$root\tests\art\mkintro.py" $work
if ($LASTEXITCODE -ne 0) { throw "intro-selftest: mkintro.py failed" }
Copy-Item "$PSScriptRoot\intro\fixtures\*.txt" $work
[IO.File]::WriteAllBytes("$work\theme.aks", [byte[]](1..32))     # existence only in this task

# ---- Probe 1: -bitmap-y -pal-embed is column-major with the palette first.
Push-Location $work
try { & $gfx -bitmap-y -pal-embed p320a.png | Out-Null } finally { Pop-Location }
$nx = [IO.File]::ReadAllBytes("$work\p320a.nxi")
Assert-Eq $nx.Length 82432 'probe: 320x256 -bitmap-y is 512 + 81920 bytes'
Assert-Eq $nx[512 + 5 * 256 + 7] ((5 + 7) -band 255) 'probe: pixel (5,7) at 512 + x*256 + y'
Assert-Eq $nx[512 + 319 * 256 + 255] ((319 + 255) -band 255) 'probe: last pixel column-major'
# ---- Probe 2: default tile mode, 4-bit, 8x8: 8192 bytes, scan order, left pixel high nibble.
Push-Location $work
try { & $gfx -colors-4bit -tile-size=8x8 -pal-none font.png | Out-Null } finally { Pop-Location }
$tl = [IO.File]::ReadAllBytes("$work\font.nxt")
Assert-Eq $tl.Length 8192 'probe: 256 tiles of 32 bytes'
Assert-Eq (Hex $tl[(0)..(31)]) (Hex (Expected-Tile $fontChr 0)) 'probe: glyph 0 (NUL, blank in font.chr) is all zero'
Assert-Eq (Hex $tl[(65 * 32)..(65 * 32 + 31)]) (Hex (Expected-Tile $fontChr 65)) 'probe: glyph 65 (A) matches font.chr under the row-striped 4-bit layout'
Assert-Eq (Test-Path "$work\font.nxm") $true 'probe: a .nxm map is written beside the tiles (discarded by the compiler)'

# ---- 001 minimal: one CUT slide, no music, no items.
$d = Compile '001-min' @('-NoAssets')
Assert-Eq ([Text.Encoding]::ASCII.GetString($d, 0, 4)) 'NDIN' '001 magic'
Assert-Eq $d[4] 1 '001 version'
Assert-Eq $d[5] 0 '001 flags: no loop, skip ANY, 80 cols, 1-bit font'
Assert-Eq $d[6] 0 '001 music none'
Assert-Eq $d[7] 50 '001 skip window default 1.0 s = 50 frames'
Assert-Eq $d[8] 0 '001 END CUT'
Assert-Eq $d[12] 1 '001 one slide'
Assert-Eq $d[13] 0 '001 no items'
Assert-Eq (U16 $d 14) 4628 '001 string pool offset'
Assert-Eq (U16 $d 16) 0 '001 empty pool'
Assert-Eq $d.Length 4628 '001 file ends at the pool'
Assert-Eq $d[544] 1 '001 slide 0 picture 001'
Assert-Eq $d[545] 1 '001 slide 0 mode 320'
Assert-Eq $d[546] 0 '001 slide 0 CUT'
Assert-Eq (U16 $d 548) 0 '001 CUT has no frames'
Assert-Eq (U16 $d 550) 100 '001 HOLD 2.0 = 100 frames'
Assert-Eq $d[32] 0xE3 '001 pair 0 paper is transparent'
Assert-Eq $d[33] 1 '001 pair 0 paper blue LSB'
Assert-Eq $d[34] 255 '001 pair 0 ink white'
Assert-Eq $d[35] 1 '001 pair 0 ink blue LSB'

# ---- 002 header statements and three slides.
$d = Compile '002-header' @('-NoAssets')
Assert-Eq $d[5] (1 -bor 8) '002 flags: LOOP + COLS 40'
Assert-Eq $d[6] 1 '002 music AKY'
Assert-Eq $d[7] 100 '002 skip window 2.0 s'
Assert-Eq $d[8] 1 '002 END FADE'
Assert-Eq $d[9] 224 '002 END FADE colour'
Assert-Eq (U16 $d 10) 75 '002 END FADE 1.5 s'
Assert-Eq $d[18] 7 '002 border'
Assert-Eq $d[12] 3 '002 three slides'
Assert-Eq $d[546] 1 '002 slide 0 FADE'
Assert-Eq $d[547] 0 '002 slide 0 fade colour black'
Assert-Eq (U16 $d 548) 50 '002 slide 0 fade 1.0 s'
Assert-Eq (U16 $d 550) 175 '002 slide 0 hold 3.5 s'
Assert-Eq $d[560] 2 '002 slide 1 is picture 002'
Assert-Eq $d[561] 0 '002 slide 1 mode 256'
Assert-Eq $d[563] 255 '002 slide 1 fade colour white'
Assert-Eq (U16 $d 566) 0xFFFF '002 slide 1 HOLD KEY'
Assert-Eq $d[576] 1 '002 slide 2 reuses picture 001'
Assert-Eq (U16 $d 582) 5 '002 slide 2 HOLD 0.1 = 5 frames'

# ---- 003 text items: pairs, centre, AT, TYPE, doubled quotes.
$d = Compile '003-text' @('-NoAssets')
Assert-Eq $d[13] 3 '003 three items'
Assert-Eq $d[552] 0 '003 slide 0 first item 0'
Assert-Eq $d[553] 3 '003 slide 0 item count'
Assert-Eq $d[1568] 0 '003 item 0 TEXT'
Assert-Eq $d[1569] 2 '003 item 0 row'
Assert-Eq $d[1570] 255 '003 item 0 CENTRE'
Assert-Eq $d[1571] 0 '003 item 0 default pair 0 -> attribute 0'
Assert-Eq $d[1572] 1 '003 item 0 TYPE flag'
Assert-Eq (U16 $d 1573) 50 '003 item 0 AT 1.0 s'
Assert-Eq (U16 $d 1575) 0 '003 item 0 string at pool offset 0'
Assert-Eq ([Text.Encoding]::GetEncoding(28591).GetString($d, 4628, 14)) 'Hello, "world"' '003 doubled quotes collapse'
Assert-Eq $d[1580 + 3] 2 '003 item 1 INK 224 PAPER 0 is pair 1 -> attribute 2'
Assert-Eq $d[1592 + 3] 2 '003 item 2 same colours share pair 1'
Assert-Eq $d[1582] 5 '003 item 1 column 5'
Assert-Eq $d[36] 0 '003 pair 1 paper 0'
Assert-Eq $d[38] 224 '003 pair 1 ink 224'
Assert-Eq $d[39] 0 '003 pair 1 ink 224 has blue LSB 0'

# ---- 004 scroll: hold marker, speed, attribute on every LINE, empty spacer.
$d = Compile '004-scroll' @('-NoAssets')
Assert-Eq (U16 $d 550) 0xFFFE '004 HOLD marker SCROLL'
Assert-Eq $d[554] 2 '004 speed 2'
Assert-Eq $d[555] 2 '004 scroll attribute = pair 1 (INK 252, transparent)'
Assert-Eq $d[13] 3 '004 three lines'
Assert-Eq $d[1568] 1 '004 item 0 is a LINE'
Assert-Eq $d[1570] 255 '004 lines are centred'
Assert-Eq $d[1571] 2 '004 line carries the scroll attribute'
Assert-Eq $d[1580 + 7] 6 '004 second line string offset after TITLE and NUL'
Assert-Eq $d[4628 + 6] 0 '004 the spacer is an empty string'

# ---- forwarding: extra args reach introc.ps1 by name (Compile hashtable-splats),
# ---- not by position, so -Cols 40 here must set the COLS 40 flag bit.
$d = Compile '001-min' @('-NoAssets', '-Cols', '40') '-fwd'
Assert-Eq $d[5] 8 'forwarding: -Cols 40 reaches introc as COLS 40 (flags bit 3)'

# ---- errors, each naming its line.
Write-Script 'e-unknown' "SLIDE p320a.png IN CUT HOLD 1.0`nFOO`nEND CUT"
Assert-Throws { Compile 'e-unknown' @('-NoAssets') } 'line 2: unknown statement' 'unknown statement names the line'
Write-Script 'e-width' "SLIDE p320a.png IN CUT HOLD 1.0`nSLIDE p256a.png IN WIPE LEFT 1.0 HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-width' @('-NoAssets') } 'line 2: a width change' 'width change refuses WIPE'
Write-Script 'e-loop' "LOOP`nSKIP SLIDE`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-loop' @('-NoAssets') } 'LOOP needs SKIP ANY' 'LOOP without SKIP ANY'
Write-Script 'e-mix' "SLIDE p320a.png IN CUT`n TEXT 1 1 `"x`"`n SCROLL SPEED 1`n LINE `"a`"`nEND CUT"
Assert-Throws { Compile 'e-mix' @('-NoAssets') } 'TEXT and SCROLL' 'TEXT and SCROLL on one slide'
Write-Script 'e-noend' "SLIDE p320a.png IN CUT HOLD 1.0"
Assert-Throws { Compile 'e-noend' @('-NoAssets') } 'END is missing' 'missing END'
Write-Script 'e-time' "SLIDE p320a.png IN FADE 11.0 HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-time' @('-NoAssets') } 'line 1: FADE time must be 0.1 to 10' 'transition time range'
Write-Script 'e-colour' "FONT font.png`nSLIDE p320a.png IN CUT HOLD 1.0`n TEXT 1 1 `"x`" INK 3`nEND CUT"
Assert-Throws { Compile 'e-colour' @('-NoAssets') } 'INK and PAPER are for the 1-bit font' 'colour word mismatch'
Write-Script 'e-fit' "COLS 40`nSLIDE p320a.png IN CUT HOLD 1.0`n TEXT 1 30 `"twelve chars`"`nEND CUT"
Assert-Throws { Compile 'e-fit' @('-NoAssets') } 'does not fit the 40-column grid' 'text off the grid'
Write-Script 'e-col40' "COLS 40`nSLIDE p320a.png IN CUT HOLD 1.0`n TEXT 0 40 `"`"`nEND CUT"
Assert-Throws { Compile 'e-col40' @('-NoAssets') } 'TEXT column must be 0 to 39' '40-column TEXT column 40 is rejected'
Write-Script '013-col40' "COLS 40`nSLIDE p320a.png IN CUT HOLD 1.0`n TEXT 0 39 `"x`"`nEND CUT"
$d = Compile '013-col40' @('-NoAssets')
Assert-Eq $d[1568 + 2] 39 '013 40-column TEXT column 39 compiles'
Write-Script 'e-bad' "SLIDE bad300.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-bad' @('-NoAssets') } 'is 300x256' 'wrong picture size'
$many = (1..65 | ForEach-Object { "SLIDE p320a.png IN CUT HOLD 1.0" }) -join "`n"
Write-Script 'e-many' "$many`nEND CUT"
Assert-Throws { Compile 'e-many' @('-NoAssets') } 'more than 64 slides' '65 slides'
$big = "SLIDE p320a.png IN CUT`n SCROLL SPEED 1`n" + ((1..60 | ForEach-Object { ' LINE "' + ('x' * 60) + '"' }) -join "`n") + "`nEND CUT"
Write-Script 'e-pool' $big
Assert-Throws { Compile 'e-pool' @('-NoAssets') } 'string pool is' 'string pool overflow'
Write-Script 'e-first' "SLIDE p320a.png IN WIPE LEFT 1.0 HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-first' @('-NoAssets') } 'the first slide arrives from nothing' 'first slide needs CUT or FADE'
Write-Script 'e-music2' "MUSIC AKY theme.aks`nMUSIC AKY theme.aks`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-music2' @('-NoAssets') } 'only one MUSIC statement' 'a second MUSIC statement is rejected'
$scroll225 = "SLIDE p320a.png IN CUT`n SCROLL SPEED 1`n" + ((1..225 | ForEach-Object { ' LINE "x"' }) -join "`n") + "`nEND CUT"
Write-Script 'e-scroll225' $scroll225
Assert-Throws { Compile 'e-scroll225' @('-NoAssets') } 'a SCROLL may have at most 224 LINE statements' 'SCROLL with 225 LINEs is rejected'
$scroll224 = "SLIDE p320a.png IN CUT`n SCROLL SPEED 1`n" + ((1..224 | ForEach-Object { ' LINE "x"' }) -join "`n") + "`nEND CUT"
Write-Script 'e-scroll224' $scroll224
$d = Compile 'e-scroll224' @('-NoAssets')
Assert-Eq $d[553] 224 'a SCROLL with exactly 224 LINEs compiles (NITEM byte)'
# ---- 005 assets: pictures numbered by first use, NXC column-major, NX2 transposed, FONT.TIL remapped, blocks.
$gfxArgs = @('-Gfx', $gfx)
$gfxNamed = @{ Gfx = $gfx }    # array splatting binds @gfxArgs positionally: direct calls need a hashtable to pass -Gfx by name
$d = Compile '005-assets' $gfxArgs
$o = "$work\out-005-assets"
Assert-Eq (Test-Path "$o\001.NXC") $true '005 picture 001 is NXC'
Assert-Eq (Test-Path "$o\004.NXC") $true '005 ready-made NX2 became 004.NXC'
Assert-Eq (Test-Path "$o\005.NXI") $true '005 the 256-wide picture is 005.NXI'
Assert-Eq ([IO.File]::ReadAllBytes("$o\001.NXC")).Length 82432 '005 NXC length'
$c1 = [IO.File]::ReadAllBytes("$o\001.NXC"); $c4 = [IO.File]::ReadAllBytes("$o\004.NXC")
Assert-Eq $c4[512 + 10 * 256 + 20] ((10 + 20) -band 255) '005 transposed NX2 pixel (10,20)'
Assert-Eq $c1[512 + 10 * 256 + 20] $c4[512 + 10 * 256 + 20] '005 PNG and NX2 of the same art agree after conversion'
$til = [IO.File]::ReadAllBytes("$o\FONT.TIL")
Assert-Eq $til.Length 8192 '005 FONT.TIL length'
Assert-Eq (Hex $til[(0)..(31)]) (Hex (Expected-Tile $fontChr 0)) '005 tile 0 (glyph NUL, blank in font.chr) is all zero'
Assert-Eq (Hex $til[(65 * 32)..(65 * 32 + 31)]) (Hex (Expected-Tile $fontChr 65)) "005 tile 65 ('A') matches font.chr under the row-striped 4-bit layout"
$expT72 = Expected-Tile $fontChr 72
Assert-Eq (Hex $til[(72 * 32)..(72 * 32 + 31)]) (Hex $expT72) "005 tile 72 ('H') matches font.chr under the row-striped 4-bit layout"
Assert-Eq (Hex $til[(32 * 32)..(32 * 32 + 31)]) ('00' * 32) '005 tile 32 (space) is entirely zero'
Assert-Eq $d[5] 16 '005 flags: colour font'
Assert-Eq $d[32] 0xE3 '005 block 0 entry 0 is the magenta colour (RGB332 E3)'
Assert-Eq $d[33] 1 '005 block 0 entry 0 blue LSB'
Assert-Eq $d[32 + 5 * 2] 0x00 '005 block 0 entry 5 is the sheet filler colour, black'
Assert-Eq $d[32 + 16 * 2] 255 '005 block 1 entry 0 is 255 from PALETTE'
Assert-Eq $d[32 + 17 * 2] 224 '005 block 1 entry 1 is 224'
Assert-Eq $d[32 + 32 * 2] 0xE3 '005 block 2 unset copies block 0'
Assert-Eq $d[1571] 16 '005 TEXT BLOCK 1 -> attribute $10'
# ---- 006 palette warning fires for p320a -> p320b (WIPE) and p320b -> p320c (DISSOLVE): different palettes each time.
$outText = & $comp -Script "$work\005-assets.txt" -Root $work -Out "$work\out-006" @gfxNamed *>&1 | Out-String
$script:checks++
if ($outText -notmatch 'WARNING: slides at lines 3 and 5 differ') { throw "intro-selftest: 006 expected a palette warning for the WIPE between p320a and p320b, got: $outText" }
if ($outText -notmatch 'WARNING: slides at lines 5 and 6 differ') { throw 'intro-selftest: 006 expected a warning for the DISSOLVE between p320b and p320c' }
# ---- 007 no warning when palettes are shared: p320a -> p320c under WIPE.
Write-Script '007-shared' "SLIDE p320a.png IN CUT HOLD 1.0`nSLIDE p320c.png IN WIPE RIGHT 0.5 HOLD 1.0`nEND CUT"
$outText = & $comp -Script "$work\007-shared.txt" -Root $work -Out "$work\out-007" @gfxNamed *>&1 | Out-String
$script:checks++
if ($outText -match 'WARNING') { throw "intro-selftest: 007 shared palette must not warn: $outText" }
# ---- 008 font sheet without magenta is refused.
& python -c "import sys; sys.path.insert(0, r'$root\tests\art'); import mkanisheets as m; m.write_png(r'$work\nomag.png', 128, 128, [(i,i,i) for i in range(16)], [[1]*128 for _ in range(128)])"
Write-Script '008-nomag' "FONT nomag.png`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile '008-nomag' $gfxArgs } 'has no magenta' '008 font sheet needs magenta'

# ---- 009 PCM through ffmpeg when present; skipped (not failed) without it.
$ff = "$root\tools\ffmpeg\bin\ffmpeg.exe"
if (Test-Path $ff) {
    Write-Script '009-pcm' "MUSIC PCM tone.wav`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
    $d = Compile '009-pcm' ($gfxArgs + @('-Ffmpeg', $ff))
    $pcm = [IO.File]::ReadAllBytes("$work\out-009-pcm\MUSIC.PCM")
    Assert-Eq $pcm.Length 62500 '009 two seconds of stereo 15625 Hz = 62500 bytes'
    Assert-Eq $d[6] 3 '009 music kind PCM'
    Assert-Eq ($pcm[0] -ge 96 -and $pcm[0] -le 160) $true '009 unsigned samples centre near 128'
} else { Write-Host "intro-selftest: ffmpeg absent, 009 skipped" }
# ---- 010 AKY through SongToAky when present.
$s2a = "$root\tools\ArkosTracker3\tools\SongToAky.exe"
if (Test-Path $s2a) {
    Copy-Item "$root\authoring-kit\AUDIO\STARTER.aks" "$work\theme.aks" -Force
    Write-Script '010-aky' "MUSIC AKY theme.aks`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
    $d = Compile '010-aky' ($gfxArgs + @('-S2A', $s2a))
    $aky = [IO.File]::ReadAllBytes("$work\out-010-aky\MUSIC.AKY")
    Assert-Eq $aky[1] 9 '010 nine-channel export'
    Assert-Eq ($aky.Length -le 16384) $true '010 within the 16K slot'
} else { Write-Host "intro-selftest: SongToAky absent, 010 skipped" }
# ---- 011 NDR stages the player and the song when tools\NextDAW is present.
$ndaw = "$root\tools\NextDAW\RuntimePlayer\NextDAW_RuntimePlayer_E000.bin"
$ndr = "$root\tools\NextDAW\DemoCode\z88dk_asm\Silver-Surfer.NDR"
if ((Test-Path $ndaw) -and (Test-Path $ndr)) {
    Copy-Item $ndr "$work\song.ndr" -Force
    Write-Script '011-ndr' "MUSIC NDR song.ndr`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
    $d = Compile '011-ndr' ($gfxArgs + @('-NdawBin', $ndaw))
    Assert-Eq ([IO.File]::ReadAllBytes("$work\out-011-ndr\NDAW.BIN")).Length 7519 '011 player copied'
    Assert-Eq (Test-Path "$work\out-011-ndr\MUSIC.NDR") $true '011 song copied'
    Assert-Eq $d[6] 4 '011 music kind NDR'
    Remove-Item "$work\out-011-ndr\NDAW.BIN", "$work\song.ndr" -Force
} else { Write-Host "intro-selftest: tools\NextDAW absent, 011 skipped" }
# ---- 011c a player build with the wrong load address (JP table not into
# ---- $E000+) is rejected with a named error. Synthetic bytes - no real
# ---- NextDAW file needed, so this runs unconditionally.
$badPlayer = "$work\bad-player.bin"
$badBytes = [byte[]]::new(39)
for ($bi = 0; $bi -lt 13; $bi++) { $badBytes[$bi * 3] = 0xC3; $badBytes[$bi * 3 + 2] = 0xC0 }
[IO.File]::WriteAllBytes($badPlayer, $badBytes)
[IO.File]::WriteAllBytes("$work\stub.ndr", [byte[]](1..4))     # existence only; never read
Write-Script '011c-badplayer' "MUSIC NDR stub.ndr`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile '011c-badplayer' ($gfxArgs + @('-NdawBin', $badPlayer)) } 'JP table entry' '011c wrong-address player rejected'
Remove-Item $badPlayer, "$work\stub.ndr" -Force
# ---- a relative -Gfx path resolves through introc.ps1's own absolute-path
# fix, the same as an absolute one: identical INTRO.DAT bytes either way.
$dAbs = Compile '005-assets' $gfxArgs '-abs2'
Push-Location $root
try { $dRel = Compile '005-assets' @('-Gfx', 'tools\gfx2next\gfx2next.exe') '-relgfx' }
finally { Pop-Location }
Assert-Eq ([Convert]::ToBase64String($dRel)) ([Convert]::ToBase64String($dAbs)) 'relative -Gfx matches absolute -Gfx'
# ---- a relative -Root and -Out resolve the same way (the Push-Location
# ---- bug this closes: a relative source path broke once Invoke-Gfx2Next
# ---- changed directory for gfx2next).
$dAbsRoot = Compile '001-min' @('-NoAssets')
Push-Location $root
try {
    $relOut = 'tests\out\intro\out-001-min-relroot'
    & $comp -Script 'tests\out\intro\001-min.txt' -Root 'tests\out\intro' -Out $relOut -NoAssets | Out-Null
    $dRelRoot = [IO.File]::ReadAllBytes("$root\$relOut\INTRO.DAT")
}
finally { Pop-Location }
Assert-Eq ([Convert]::ToBase64String($dRelRoot)) ([Convert]::ToBase64String($dAbsRoot)) 'relative -Root/-Out matches absolute -Root/-Out'
# ---- 011b MUSIC STREAM through SongToYm and aysconv when present; skipped
# (not failed) without it. Task 12 uses case number 012.
$s2y = "$root\tools\ArkosTracker3\tools\SongToYm.exe"
if (Test-Path $s2y) {
    Copy-Item "$root\authoring-kit\AUDIO\STARTER.aks" "$work\stream.aks" -Force
    Write-Script '011b-stream' "MUSIC STREAM stream.aks`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
    $aysconv = "$root\authoring-kit\lib\aysconv.ps1"
    $d = Compile '011b-stream' ($gfxArgs + @('-S2Y', $s2y, '-Aysconv', $aysconv))
    $ays = [IO.File]::ReadAllBytes("$work\out-011b-stream\MUSIC.AYS")
    Assert-Eq ($ays.Length -gt 0) $true '011b AYS stream non-empty'
    Assert-Eq ($ays.Length -le 393216) $true '011b AYS within the 393216 (48 page) ceiling'
    Assert-Eq ([Text.Encoding]::ASCII.GetString($ays, 0, 4)) 'AYS1' '011b AYS magic'
    Assert-Eq ($ays[4] -ge 1 -and $ays[4] -le 3) $true '011b AYS psgCount is 1-3'
    Assert-Eq $ays[5] 0 '011b AYS flags byte reserved 0'
    Assert-Eq $ays[14] 0 '011b AYS header pad byte 14'
    Assert-Eq $ays[15] 0 '011b AYS header pad byte 15'
    Assert-Eq $d[6] 2 '011b music kind STREAM'
} else { Write-Host "intro-selftest: SongToYm absent, 011b skipped" }

# ---- Windows PowerShell 5.1 is what BUILD.BAT runs: the same script must
# ---- produce the same bytes there.
$ps5 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path $ps5) {
    $out5 = "$work\out-001-ps5"
    & $ps5 -NoProfile -ExecutionPolicy Bypass -File $comp -Script "$work\001-min.txt" -Root $work -Out $out5 -NoAssets | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'intro-selftest: introc.ps1 failed under Windows PowerShell 5.1' }
    $d5 = [IO.File]::ReadAllBytes("$out5\INTRO.DAT")
    $d7 = [IO.File]::ReadAllBytes("$work\out-001-min\INTRO.DAT")
    Assert-Eq ([Convert]::ToBase64String($d5)) ([Convert]::ToBase64String($d7)) 'ps5: identical INTRO.DAT under Windows PowerShell 5.1'
} else { Write-Host "intro-selftest: Windows PowerShell 5.1 absent, ps5 probe skipped" }

# ---- 012 font sheet with an opaque space cell is refused.
& python -c "import sys; sys.path.insert(0, r'$root\tests\art'); import mkanisheets as m; m.write_png(r'$work\nospace.png', 128, 128, [(255,0,255)] + [(i*16,i*16,i*16) for i in range(1,16)], [[1]*128 for _ in range(128)])"
Write-Script '012-nospace' "FONT nospace.png`nSLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile '012-nospace' $gfxArgs } 'cell 32' '012 space cell must be transparent'

# ---- 014 40-column colour-font show shape: header flags bit, CENTRE resolves to column 13.
Write-Script '014-col40show' "COLS 40`nFONT font.png`nPALETTE 1 255 224 28 3 0 0 0 0 0 0 0 0 0 0 0 0`nSLIDE p320a.png IN FADE 1.0 HOLD 4.0`n TEXT 2 CENTRE `"FORTY COLUMNS`" BLOCK 1`nEND CUT"
$d = Compile '014-col40show' @('-NoAssets')
Assert-Eq ($d[5] -band 8) 8 '014 FL_COLS40 set in header flags'
Assert-Eq ($d[5] -band 16) 16 '014 FL_COLFONT set alongside it'
Assert-Eq $d[1568 + 2] 255 '014 item 0 CENTRE marker byte'
$strOff = U16 $d 1575
$e = $strOff
while ($d[4628 + $e] -ne 0) { $e++ }
$len = $e - $strOff
Assert-Eq $len 13 '014 FORTY COLUMNS is 13 characters, read from the pool via the item record string offset'
$cols40 = if ($d[5] -band 8) { 40 } else { 80 }
Assert-Eq ([math]::Floor(($cols40 - $len) / 2)) 13 '014 CENTRE resolves to column 13 at 40 columns (text.asm caption_one formula)'

Write-Host "intro-selftest: $checks checks passed"
