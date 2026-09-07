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
Assert-Eq $tl[0] 0x55 'probe: glyph 0 is all magenta index 5 (55 per byte)'
Assert-Eq $tl[65 * 32] 0x66 'probe: glyph 65 is colour 6 in both nibbles (65 mod 15 = 5, plus 1, not the magenta index)'
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
Write-Script 'e-assets' "SLIDE p320a.png IN CUT HOLD 1.0`nEND CUT"
Assert-Throws { Compile 'e-assets' @() } 'run with -NoAssets' 'assets not yet available in this task'

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

Write-Host "intro-selftest: $checks checks passed"
