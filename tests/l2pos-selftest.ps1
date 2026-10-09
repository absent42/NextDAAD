# Assertions over the NXP positioned-picture path of authoring-kit\lib\assets.ps1
# and palcheck.ps1. Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\l2pos-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'tests/testtools.ps1')
$gfx  = Get-RepoTool 'gfx2next'
$work = "$root/tests/out/l2pos"
$checks = 0
if (-not (Test-Path $gfx)) { throw "l2pos-selftest: gfx2next not found at $gfx" }
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "l2pos-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    $threw = $false
    try { & $sb | Out-Null } catch { $threw = $true; if ($_.Exception.Message -notmatch $pattern) { throw "l2pos-selftest: $what - wrong message: $($_.Exception.Message)" } }
    if (-not $threw) { throw "l2pos-selftest: $what - did not fail" }
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$work/kit/IMAGES", "$work/kit/RELEASE" | Out-Null

# ---- Part 1: pure functions, loaded out of assets.ps1 without running its stage switch
$src = Get-Content "$root/authoring-kit/lib/assets.ps1" -Raw
$fnText = [regex]::Match($src, '(?s)function Get-PngHeight.*?(?=\n# ---- pictures ----)').Value
if (-not $fnText) { throw 'l2pos-selftest: Get-PngHeight..New-NxpHeader block not found in assets.ps1' }
function Fail([string]$Message) { throw $Message }
Invoke-Expression $fnText

Set-Content "$work/a.txt" "at=8,16`npalette=128-255"
$p = Read-PosSidecar "$work/a.txt"
Assert-Eq $p.Float $false 'a: fixed'; Assert-Eq $p.X 8 'a: X'; Assert-Eq $p.Y 16 'a: Y'
Assert-Eq $p.PalFirst 128 'a: first'; Assert-Eq $p.PalLast 255 'a: last'; Assert-Eq $p.Mode $null 'a: mode unset'
Set-Content "$work/b.txt" "; comment`nat=window`npalette=none`nmode=320"
$p = Read-PosSidecar "$work/b.txt"
Assert-Eq $p.Float $true 'b: floating'; Assert-Eq $p.PalFirst 1 'b: none first'; Assert-Eq $p.PalLast 0 'b: none last'; Assert-Eq $p.Mode 320 'b: mode'
Set-Content "$work/c.txt" "palette=0-10"
Assert-Throws { Read-PosSidecar "$work/c.txt" } "'at' is required" 'c: missing at'
Set-Content "$work/d.txt" "at=8,16`npalette=300-10"
Assert-Throws { Read-PosSidecar "$work/d.txt" } 'palette' 'd: palette out of range'
Set-Content "$work/e.txt" "at=8;16"
Assert-Throws { Read-PosSidecar "$work/e.txt" } 'at=' 'e: bad at syntax'

$h = New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 64 32
Assert-Eq ([Text.Encoding]::ASCII.GetString($h, 0, 3)) 'NXP' 'hdr magic'
Assert-Eq $h[3] 1 'hdr version'; Assert-Eq $h[4] 0 'hdr mode'; Assert-Eq $h[5] 0 'hdr flags fixed'
Assert-Eq $h[6] 8 'hdr X lo'; Assert-Eq $h[7] 0 'hdr X hi'; Assert-Eq $h[8] 16 'hdr Y'
Assert-Eq $h[9] 64 'hdr W lo'; Assert-Eq $h[10] 0 'hdr W hi'; Assert-Eq $h[11] 32 'hdr H'
Assert-Eq $h[12] 128 'hdr pal first'; Assert-Eq $h[13] 255 'hdr pal last'; Assert-Eq $h[14] 0 'hdr rsv0'; Assert-Eq $h[15] 0 'hdr rsv1'
$h = New-NxpHeader (Read-PosSidecar "$work/b.txt") 1 320 256
Assert-Eq $h[5] 1 'hdr flags floating'; Assert-Eq $h[9] 64 'hdr W 320 lo'; Assert-Eq $h[10] 1 'hdr W 320 hi'; Assert-Eq $h[11] 0 'hdr H 256 -> 0'
Assert-Throws { New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 256 192 } 'does not fit' 'hdr: 8,16 + 256x192 off screen'
Assert-Throws { New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 64 200 } 'does not fit' 'hdr: 200 rows in 256 mode'
Assert-Throws { New-NxpHeader (Read-PosSidecar "$work/a.txt") 0 64 200 'x.png + x.txt' } 'x\.png \+ x\.txt - 64x200 does not fit' 'hdr: names the files'

# folded review cases
Set-Content "$work/f.txt" "at=300,0"
$h = New-NxpHeader (Read-PosSidecar "$work/f.txt") 1 20 10
Assert-Eq $h[6] 44 'f: X 300 lo'; Assert-Eq $h[7] 1 'f: X 300 hi'
Set-Content "$work/g.txt" "at=320,0"
Assert-Throws { Read-PosSidecar "$work/g.txt" } 'X must be' 'g: X > 319'
Set-Content "$work/g.txt" "at=0,256"
Assert-Throws { Read-PosSidecar "$work/g.txt" } 'Y 0-255' 'g: Y > 255'
Set-Content "$work/g.txt" "at=0,0`nmode=512"
Assert-Throws { Read-PosSidecar "$work/g.txt" } 'mode=' 'g: bad mode'
Set-Content "$work/g.txt" "at=0,0`npalete=none"
Assert-Throws { Read-PosSidecar "$work/g.txt" } "unknown key 'palete'" 'g: unknown key'
Set-Content "$work/g.txt" "at=0,99999999999999999999"
Assert-Throws { Read-PosSidecar "$work/g.txt" } 'at=' 'g: huge number'
Set-Content "$work/g.txt" "at=0,0`npalette=0-99999999999999999999"
Assert-Throws { Read-PosSidecar "$work/g.txt" } 'palette=' 'g: huge palette'

# ---- Part 2: end-to-end staging through assets.ps1
& python "$root/tests/art/mkl2pos.py" "$work/kit/IMAGES" --png *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'l2pos-selftest: mkl2pos.py --png failed' }
function Stage([string]$compress) {
    Push-Location "$work/kit"
    try { & pwsh -NoProfile -File "$root/authoring-kit/lib/assets.ps1" -Stage Pictures -Gfx $gfx -Compress $compress *>&1 | Out-Null; return $LASTEXITCODE }
    finally { Pop-Location }
}
Assert-Eq (Stage '0') 0 'stage raw exit code'
Assert-Eq (Test-Path "$work/kit/RELEASE/001.NXI") $true '001 plain stays NXI'
Assert-Eq (Test-Path "$work/kit/RELEASE/002.NXP") $true '002 positioned -> NXP'
$b = [IO.File]::ReadAllBytes("$work/kit/RELEASE/002.NXP")
Assert-Eq $b.Length (16 + 512 + 256 * 96) '002 length'
Assert-Eq ([Text.Encoding]::ASCII.GetString($b, 0, 3)) 'NXP' '002 magic'
Assert-Eq $b[4] 0 '002 mode inferred 256'; Assert-Eq $b[12] 0 '002 pal first'; Assert-Eq $b[13] 100 '002 pal last'
$nxi = [IO.File]::ReadAllBytes("$work/kit/RELEASE/001.NXI")
Assert-Eq $b[16] $nxi[0] '002 palette byte 0 follows the header'
$b = [IO.File]::ReadAllBytes("$work/kit/RELEASE/005.NXP")
Assert-Eq $b[5] 1 '005 floating flag'; Assert-Eq $b[9] 64 '005 W'; Assert-Eq $b[11] 32 '005 H'; Assert-Eq $b[12] 1 '005 none first'; Assert-Eq $b[13] 0 '005 none last'
$b = [IO.File]::ReadAllBytes("$work/kit/RELEASE/006.NXP")
Assert-Eq $b[6] 8 '006 X'; Assert-Eq $b[8] 160 '006 Y'; Assert-Eq $b[9] 32 '006 W'
# compressed: header stays raw, payload is ZX0
Assert-Eq (Stage '1') 0 'stage zx0 exit code'
Assert-Eq (Test-Path "$work/kit/RELEASE/002.NXP.ZX0") $true '002 zx0 name'
Assert-Eq (Test-Path "$work/kit/RELEASE/002.NXP") $false '002 raw removed as orphan'
$b = [IO.File]::ReadAllBytes("$work/kit/RELEASE/002.NXP.ZX0")
Assert-Eq ([Text.Encoding]::ASCII.GetString($b, 0, 3)) 'NXP' '002.zx0 header raw'
Assert-Eq ($b.Length -lt (16 + 512 + 256 * 96)) $true '002.zx0 smaller than raw'
# ready-made NXP staged as-is; bad header refused
Stage '0' | Out-Null
Copy-Item "$work/kit/RELEASE/006.NXP" "$work/kit/IMAGES/007.NXP"
Assert-Eq (Stage '0') 0 'ready-made stage'
Assert-Eq (Test-Path "$work/kit/RELEASE/007.NXP") $true '007 ready-made staged'
$bad = [IO.File]::ReadAllBytes("$work/kit/IMAGES/007.NXP"); $bad[3] = 2
[IO.File]::WriteAllBytes("$work/kit/IMAGES/008.NXP", $bad)
Assert-Eq (Stage '0') 1 'bad version refused'
Remove-Item "$work/kit/IMAGES/008.NXP"
$bad = [IO.File]::ReadAllBytes("$work/kit/IMAGES/007.NXP"); $bad[4] = 1
[IO.File]::WriteAllBytes("$work/kit/IMAGES/008.NXP", $bad)
Assert-Eq (Stage '0') 1 'mode conflict with the 256-wide set refused'
Remove-Item "$work/kit/IMAGES/008.NXP"
# stray picture-number sidecar without a PNG fails; a notes file is ignored
Set-Content "$work/kit/IMAGES/009.txt" "palette=0-5"
Assert-Eq (Stage '0') 1 'sidecar without PNG refused'
Remove-Item "$work/kit/IMAGES/009.txt"
Set-Content "$work/kit/IMAGES/notes.txt" "author notes"
Assert-Eq (Stage '0') 0 'notes.txt ignored'
Remove-Item "$work/kit/IMAGES/notes.txt"

# a game-mode change must rebuild a sidecar picture that has no mode= key
New-Item -ItemType Directory -Force "$work/kit2/IMAGES", "$work/kit2/RELEASE" | Out-Null
Copy-Item "$work/kit/IMAGES/003.png", "$work/kit/IMAGES/003.txt" "$work/kit2/IMAGES"
function Stage2([string]$compress) {
    Push-Location "$work/kit2"
    try { & pwsh -NoProfile -File "$root/authoring-kit/lib/assets.ps1" -Stage Pictures -Gfx $gfx -Compress $compress *>&1 | Out-Null; return $LASTEXITCODE }
    finally { Pop-Location }
}
Assert-Eq (Stage2 '0') 0 'kit2 stage 256 default'
Assert-Eq ([IO.File]::ReadAllBytes("$work/kit2/RELEASE/003.NXP")[4]) 0 'kit2 003 mode 0'
& python -c "import sys,struct,zlib
w,h=320,8
def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
raw=b''.join(b'\0'+bytes(w) for _ in range(h))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,3,0,0,0))+ch(b'PLTE',bytes(768))+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b''))" "$work/kit2/IMAGES/010.png"
Assert-Eq (Stage2 '0') 0 'kit2 stage after 320 plain added'
Assert-Eq ([IO.File]::ReadAllBytes("$work/kit2/RELEASE/003.NXP")[4]) 1 'kit2 003 rebuilt with mode 1'
Remove-Item "$work/kit2/IMAGES/010.png"

# R29/R30: the title never votes; mode logic runs only for positioned games
Remove-Item "$work/kit2/RELEASE/*" -Force
Remove-Item "$work/kit2/IMAGES/*" -Force
Copy-Item "$work/kit/IMAGES/001.png" "$work/kit2/IMAGES"
Copy-Item "$work/kit/RELEASE/001.NXI" "$work/kit2/DAAD.NX2"
Assert-Eq (Stage2 '0') 0 'plain 256 art with a 320 title stages'
Assert-Eq (Test-Path "$work/kit2/RELEASE/001.NXI") $true 'plain 256 art converted'
Copy-Item "$work/kit/IMAGES/003.png", "$work/kit/IMAGES/003.txt" "$work/kit2/IMAGES"
Assert-Eq (Stage2 '0') 0 'positioned 256 game with a 320 kit-root title stages'
Assert-Eq ([IO.File]::ReadAllBytes("$work/kit2/RELEASE/003.NXP")[4]) 0 '003 mode 0 despite the title'
Remove-Item "$work/kit2/DAAD.NX2"
# ready-made NXP files decide the mode
Remove-Item "$work/kit2/RELEASE/*", "$work/kit2/IMAGES/*" -Force
$m1 = [IO.File]::ReadAllBytes("$work/kit/RELEASE/006.NXP"); $m1[4] = 1
[IO.File]::WriteAllBytes("$work/kit2/IMAGES/007.NXP", $m1)
Assert-Eq (Stage2 '0') 0 'ready-made mode-1 NXP only stages'
Assert-Eq (Test-Path "$work/kit2/RELEASE/007.NXP") $true '007 staged'
Copy-Item "$work/kit/IMAGES/001.png" "$work/kit2/IMAGES"
Assert-Eq (Stage2 '0') 1 'mode-1 NXP plus 256 plain art refused'
Remove-Item "$work/kit2/IMAGES/001.png"
Copy-Item "$work/kit/RELEASE/006.NXP" "$work/kit2/IMAGES/007.NXP"
& python -c "import sys,struct,zlib
w,h=320,8
def ch(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
raw=b''.join(b'\0'+bytes(w) for _ in range(h))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,3,0,0,0))+ch(b'PLTE',bytes(768))+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b''))" "$work/kit2/IMAGES/010.png"
$errTxt = (& { Push-Location "$work/kit2"; try { & "$root/authoring-kit/lib/assets.ps1" -Stage Pictures -Gfx $gfx -Compress 0 6>&1 | Out-String } finally { Pop-Location } })
Assert-Eq ($errTxt -match '007\.NXP' -and $errTxt -match '010\.png') $true 'mode conflict error names both files'
Assert-Eq (Stage2 '0') 1 'mode-0 NXP plus 320 plain art refused'
# a lone mistyped sidecar in a plain game fails naming it
Remove-Item "$work/kit2/IMAGES/*", "$work/kit2/RELEASE/*" -Force
Copy-Item "$work/kit/IMAGES/001.png" "$work/kit2/IMAGES"
Assert-Eq (Stage2 '0') 0 'plain-only game stages'
Set-Content "$work/kit2/IMAGES/009.txt" "at=0,0"
Assert-Eq (Stage2 '0') 1 'plain game with a lone 009.txt refused'
$errTxt = (& { Push-Location "$work/kit2"; try { & "$root/authoring-kit/lib/assets.ps1" -Stage Pictures -Gfx $gfx -Compress 0 6>&1 | Out-String } finally { Pop-Location } })
Assert-Eq ($errTxt -match '009\.txt') $true 'lone sidecar error names it'

"l2pos-selftest: $checks checks passed"
