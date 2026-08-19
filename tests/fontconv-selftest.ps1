# Self-contained assertions over authoring-kit\lib\fontconv.ps1 and
# lib\fontfmt.ps1. Run unconditionally by tests\build-tests.ps1, and
# standalone during development:
#   pwsh -NoProfile -File tests\fontconv-selftest.ps1
# Fixtures are either generated here from known bytes or read from
# files present on every machine this builds on, so there is no
# external corpus to install and nothing to keep in sync.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$conv = "$root\authoring-kit\lib\fontconv.ps1"
$base = "$root\authoring-kit\lib\default.chr"
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("fontconv-selftest-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
$checks = 0

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "$what : got '$actual', expected '$expected'" }
}
function Assert-Bytes([byte[]]$actual, [byte[]]$expected, $what) {
    $script:checks++
    if ($actual.Length -ne $expected.Length) {
        throw "$what : got $($actual.Length) bytes, expected $($expected.Length)"
    }
    for ($i = 0; $i -lt $expected.Length; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            $a = ($actual  | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $e = ($expected | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            throw "$what : byte $i differs. got [$a] expected [$e]"
        }
    }
}
function Assert-Throws([scriptblock]$sb, [string]$pattern, $what) {
    $script:checks++
    try { & $sb | Out-Null }
    catch {
        if ("$_" -notmatch $pattern) { throw "$what : threw, but message '$_' does not match /$pattern/" }
        return
    }
    throw "$what : expected a throw matching /$pattern/, but it succeeded"
}

try {
    $baseBytes = [System.IO.File]::ReadAllBytes($base)

    # --- G1 a 768-byte classic charset mirrors into glyphs 160-255 ---
    # Glyph 65 ('A') is given a recognisable pattern; after conversion
    # it must appear at BOTH 65*8 and 193*8 (65 + 128).
    $ch8 = New-Object byte[] 768
    $pat = [byte[]](0x18,0x24,0x42,0x7E,0x42,0x42,0x42,0x00)
    [System.Array]::Copy($pat, 0, $ch8, (65-32)*8, 8)
    $in768 = "$tmp\g1.ch8"; $out768 = "$tmp\g1.CHR"
    [System.IO.File]::WriteAllBytes($in768, $ch8)
    & $conv -In $in768 -Out $out768 | Out-Null
    $g1 = [System.IO.File]::ReadAllBytes($out768)
    Assert-Eq $g1.Length 2048 'G1 output size'
    Assert-Bytes $g1[520..527] $pat 'G1 glyph 65 from the source'
    Assert-Bytes $g1[1544..1551] $pat 'G1 glyph 193 mirrored from glyph 65'

    # --- G2 a 2048-byte full table is still an exact passthrough ---
    # Its glyph 193 must survive untouched, proving the mirror does not
    # reach the passthrough path.
    $full = New-Object byte[] 2048
    for ($i = 0; $i -lt 2048; $i++) { $full[$i] = [byte](($i * 7) % 251) }
    for ($i = 0; $i -lt 8; $i++) { $full[32*8 + $i] = 0 }   # keep glyph 32 blank
    $inFull = "$tmp\g2.chr"; $outFull = "$tmp\g2.CHR"
    [System.IO.File]::WriteAllBytes($inFull, $full)
    & $conv -In $inFull -Out $outFull | Out-Null
    Assert-Bytes ([System.IO.File]::ReadAllBytes($outFull)) $full 'G2 full table passthrough'

    # --- G3 a raw dump at another length needs -First, then converts ---
    # 112 glyphs of 8 rows starting at character 16: the shape of the
    # NextZXOS CP/M system font.
    $raw = New-Object byte[] 896
    $mark = [byte[]](0xFF,0x81,0x81,0x81,0x81,0x81,0x81,0xFF)
    [System.Array]::Copy($mark, 0, $raw, (65-16)*8, 8)
    $inRaw = "$tmp\g3.fnt"; $outRaw = "$tmp\g3.CHR"
    [System.IO.File]::WriteAllBytes($inRaw, $raw)
    Assert-Throws { & $conv -In $inRaw -Out $outRaw } 'First' 'G3 raw of unknown length demands -First'
    & $conv -In $inRaw -Out $outRaw -First 16 | Out-Null
    $g3 = [System.IO.File]::ReadAllBytes($outRaw)
    Assert-Bytes $g3[520..527] $mark 'G3 glyph 65 placed by -First 16'
    Assert-Bytes $g3[1544..1551] $mark 'G3 glyph 193 mirrored'

    # --- G4 the gate does not false-positive on a full 8x8 cell ---
    # Every row and every column set, on every character in the text
    # range: the tightest thing that must still be ACCEPTED.
    # The gate's refusal side cannot be tested here - a raw dump has no
    # header to declare a height with, so Read-FontRaw can only ever
    # produce 8-row glyphs. It is proved in Task 3 (checks P3 and P4),
    # where PSF2 can declare a 16-row cell.
    $solid = New-Object byte[] 768
    for ($i = 0; $i -lt 768; $i++) { $solid[$i] = 0xFF }
    for ($i = 0; $i -lt 8; $i++) { $solid[$i] = 0 }        # keep glyph 32 blank
    $inSolid = "$tmp\g4.ch8"
    [System.IO.File]::WriteAllBytes($inSolid, $solid)
    & $conv -In $inSolid -Out "$tmp\g4.CHR" | Out-Null
    Assert-Bytes ([System.IO.File]::ReadAllBytes("$tmp\g4.CHR"))[520..527] `
        ([byte[]](0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF)) 'G4 a full 8x8 cell is accepted intact'

    # --- G5 glyph 32 must still be warned about, not refused ---
    $spacey = New-Object byte[] 768
    $spacey[0] = 0x01
    $inSp = "$tmp\g5.ch8"
    [System.IO.File]::WriteAllBytes($inSp, $spacey)
    $warn = & $conv -In $inSp -Out "$tmp\g5.CHR" 3>&1 2>&1 | Out-String
    Assert-Eq ((Get-Item "$tmp\g5.CHR").Length) 2048 'G5 non-blank glyph 32 still converts'
    $script:checks++
    if ($warn -notmatch 'glyph 32') { throw "G5 : expected a glyph 32 warning, got: $warn" }

    "fontconv-selftest: $checks checks passed"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
