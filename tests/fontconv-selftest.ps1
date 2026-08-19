# Self-contained assertions over authoring-kit\lib\fontconv.ps1 and
# lib\fontfmt.ps1. Run unconditionally by tests\build-tests.ps1, and
# standalone during development:
#   pwsh -NoProfile -File tests\fontconv-selftest.ps1
# Fixtures are either generated here from known bytes or read from
# files present on every machine this builds on, so there is no
# external corpus to install and nothing to keep in sync. Two checks
# read an optional font pack as a BONUS on top of a synthesised twin
# that proves the same rule; both say so loudly when they skip, and
# neither is the only proof of anything.
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

    # --- G6 a 768-byte classic ZX charset keeps its OWN glyphs 96 and
    #     127 ---
    # That shape self-identifies as chars 32-127 of the ZX charset, so
    # its 96 is already a pound sterling and its 127 a copyright, drawn
    # in the source's own face. Substituting the base font's there would
    # swap two correct glyphs for a visibly different face on the
    # commonest input the kit has. Patterns are deliberately unlike the
    # base font's bytes at those codes, so an accidental substitution
    # cannot pass this check.
    $ch96  = [byte[]](0x3C,0x66,0x60,0xF8,0x60,0x66,0xFC,0x00)
    $ch127 = [byte[]](0x3C,0x42,0x99,0xA1,0xA1,0x99,0x42,0x3C)
    $zx = New-Object byte[] 768
    [System.Array]::Copy($ch96,  0, $zx, (96-32)*8,  8)
    [System.Array]::Copy($ch127, 0, $zx, (127-32)*8, 8)
    $inZx = "$tmp\g6.ch8"
    [System.IO.File]::WriteAllBytes($inZx, $zx)
    $g6msg = & $conv -In $inZx -Out "$tmp\g6.CHR" | Out-String
    $g6 = [System.IO.File]::ReadAllBytes("$tmp\g6.CHR")
    Assert-Bytes $g6[768..775]   $ch96  'G6 glyph 96 kept from the source, not the base font'
    Assert-Bytes $g6[1016..1023] $ch127 'G6 glyph 127 kept from the source, not the base font'
    Assert-Bytes $g6[1792..1799] $ch96  'G6 glyph 224 mirrors the source pound'
    $script:checks++
    if ($g6msg -notmatch 'kept from the source') { throw "G6 : expected the classic-charset note, got: $g6msg" }

    # --- G7 the exemption is that ONE shape, not RAW in general ---
    # G3's 896-byte dump again, placed with -First 16, so glyph 96 comes
    # from the source. It has no declared charset ordering, so the
    # substitution must still fire and glyph 96 must be the BASE font's
    # pound - not the marker the fixture puts there. Without this check
    # G6's exemption could silently widen to every raw input.
    $raw7 = New-Object byte[] 896
    [System.Array]::Copy($ch96, 0, $raw7, (96-16)*8, 8)
    $inRaw7 = "$tmp\g7.fnt"
    [System.IO.File]::WriteAllBytes($inRaw7, $raw7)
    $g7msg = & $conv -In $inRaw7 -Out "$tmp\g7.CHR" -First 16 | Out-String
    $g7 = [System.IO.File]::ReadAllBytes("$tmp\g7.CHR")
    Assert-Bytes $g7[768..775]   $baseBytes[768..775]   'G7 a raw dump at another length still takes glyph 96 from the base font'
    Assert-Bytes $g7[1016..1023] $baseBytes[1016..1023] 'G7 the same for glyph 127'
    $script:checks++
    if ($g7msg -notmatch 'pound sterling') { throw "G7 : expected the substitution note, got: $g7msg" }

    # --- G8 -Slots Source keeps the PC glyphs at 96 and 127 ---
    # The escape hatch, on the shape that is NOT exempt: same fixture as
    # G7, so the only difference from it is the switch.
    $g8msg = & $conv -In $inRaw7 -Out "$tmp\g8.CHR" -First 16 -Slots Source | Out-String
    $g8 = [System.IO.File]::ReadAllBytes("$tmp\g8.CHR")
    Assert-Bytes $g8[768..775] $ch96 'G8 -Slots Source keeps the source glyph 96'
    # The script's own header and the manual both promise the output line
    # names which slot path ran. The ZX path always said so; this asserts
    # the Source path does too, so the promise cannot quietly lapse.
    $script:checks++
    if ($g8msg -notmatch '-Slots Source') { throw "G8 : expected the -Slots Source note, got: $g8msg" }

    # --- FON fixtures, built here from known bytes ---
    # A minimal 16-bit NE wrapper around one or more FNT faces, so every
    # FON check below is self-contained. Each face is a hashtable:
    #   Height   dfPixHeight
    #   Charset  dfCharSet (0x00 ANSI, 0xFF OEM)
    #   First    dfFirstChar
    #   Last     dfLastChar
    #   Rows     character code -> byte[] of Height rows. A code with no
    #            entry gets a zero-width character-table entry, which is
    #            how a real FNT says it holds no glyph there.
    # Resource alignment shift is 0 so every offset written here is
    # byte-exact, and each face gets a fixed 4096-byte slot from 1024.
    function Set-U16([byte[]]$a, [int]$o, [int]$v) {
        $a[$o] = [byte]($v -band 0xFF); $a[$o + 1] = [byte](($v -shr 8) -band 0xFF)
    }
    function New-FonBytes([hashtable[]]$faces) {
        $slot = 4096
        $bb = New-Object byte[] (1024 + $faces.Count * $slot)
        $bb[0] = 0x4D; $bb[1] = 0x5A                    # 'MZ'
        $bb[60] = 64                                     # e_lfanew -> NE header at 64
        $bb[64] = 0x4E; $bb[65] = 0x45                  # 'NE'
        Set-U16 $bb 100 64                               # rsrcRel -> resource table at 128
        Set-U16 $bb 128 0                                # rscAlignShift 0
        Set-U16 $bb 130 0x8008                           # rtTypeID RT_FONT (0x8007 is the FONTDIR decoy)
        Set-U16 $bb 132 $faces.Count                     # rtResourceCount
        for ($n = 0; $n -lt $faces.Count; $n++) {
            $f = 1024 + $n * $slot
            Set-U16 $bb (138 + $n * 12) $f               # rnOffset
            Set-U16 $bb (140 + $n * 12) $slot            # rnLength
            $fc = [int]$faces[$n].First
            $lc = [int]$faces[$n].Last
            $h  = [int]$faces[$n].Height
            Set-U16 $bb $f 0x0200                        # dfVersion
            $bb[$f + 85] = [byte]$faces[$n].Charset      # dfCharSet
            Set-U16 $bb ($f + 86) 8                      # dfPixWidth
            Set-U16 $bb ($f + 88) $h                     # dfPixHeight
            $bb[$f + 95] = [byte]$fc                     # dfFirstChar
            $bb[$f + 96] = [byte]$lc                     # dfLastChar
            $ctab = $f + 118                             # v2 character table
            $data = $ctab + 4 * ($lc - $fc + 1) + 16
            for ($c = $fc; $c -le $lc; $c++) {
                $e = $ctab + ($c - $fc) * 4
                $rows = $faces[$n].Rows[$c]
                if ($null -eq $rows) { Set-U16 $bb $e 0; continue }
                Set-U16 $bb $e 8                         # geWidth
                Set-U16 $bb ($e + 2) ($data - $f)        # geOffset, relative to the face
                [System.Array]::Copy($rows, 0, $bb, $data, $h)
                $data += $h
            }
        }
        # Comma-wrapped: a bare return unrolls the array, and the caller
        # would get an Object[] that every [byte[]] parameter silently
        # COPIES on binding, so a later patch to the bytes would be made
        # to a throwaway.
        return ,$bb
    }
    # Rows 0-7 of a recognisable 'A', padded to $h rows; $low sets row 8,
    # which is what decides whether a taller face's ink fits the cell.
    $fonPat = [byte[]](0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00)
    function New-FonGlyph([int]$h, [byte]$low) {
        $g = New-Object byte[] $h
        [System.Array]::Copy($fonPat, 0, $g, 0, 8)
        if ($h -gt 8) { $g[8] = $low }
        return ,$g
    }
    function New-FonTextRows([int]$h, [byte]$low) {
        $r = @{}
        # code 32 is left out, so the base font's blank space stands
        for ($c = 33; $c -le 127; $c++) { $r[$c] = (New-FonGlyph $h $low) }
        return $r
    }

    # --- F1 a real FON converts, with the bytes CGA actually has ---
    # cga80woa.fon is the CGA 80-column 8x8 CP437 font and ships with
    # Windows, so this needs nothing installed. The expected bytes were
    # read out of the file itself, not recalled.
    $cga = "$env:WINDIR\Fonts\cga80woa.fon"
    if (Test-Path $cga) {
        $outF = "$tmp\f1.CHR"
        & $conv -In $cga -Out $outF | Out-Null
        $f1 = [System.IO.File]::ReadAllBytes($outF)
        Assert-Eq $f1.Length 2048 'F1 output size'
        Assert-Bytes $f1[520..527]   ([byte[]](0x30,0x78,0xCC,0xCC,0xFC,0xCC,0xCC,0x00)) 'F1 glyph 65 A'
        Assert-Bytes $f1[824..831]   ([byte[]](0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0xF8)) 'F1 glyph 103 g, descender intact'
        Assert-Bytes $f1[384..391]   ([byte[]](0x78,0xCC,0xDC,0xFC,0xEC,0xCC,0x78,0x00)) 'F1 glyph 48 zero'
        Assert-Bytes $f1[256..263]   ([byte[]](0,0,0,0,0,0,0,0))                          'F1 glyph 32 blank'
        # The in-face pound rule: dfCharSet is 0xFF (OEM), so glyph 96
        # must be CP437 slot 156, NOT the base font's pound.
        Assert-Bytes $f1[768..775]   ([byte[]](0x38,0x6C,0x64,0xF0,0x60,0xE6,0xFC,0x00)) 'F1 glyph 96 pound lifted in face from CP437 156'
        # Copyright has no CP437 source, so 127 must come from the base.
        Assert-Bytes $f1[1016..1023] $baseBytes[1016..1023] 'F1 glyph 127 copyright from the base font'
        # And the mirror.
        Assert-Bytes $f1[1544..1551] ([byte[]](0x30,0x78,0xCC,0xCC,0xFC,0xCC,0xCC,0x00)) 'F1 glyph 193 mirrors A'
    }
    else {
        Write-Warning "F1 skipped: $cga not present"
    }

    # --- F2 an over-tall face is refused, not cropped ---
    # An 8x14 face with ink on row 8, built here so the branch's marquee
    # negative case is proved on every machine rather than on one. The
    # taller-than-8 declaration alone is not what refuses it - F6 below
    # is its twin, the same over-height declaration with the ink kept
    # inside 8 rows, and that one must convert.
    $inTall = "$tmp\f2.fon"
    [System.IO.File]::WriteAllBytes($inTall, (New-FonBytes @(
        @{ Height = 14; Charset = 0x00; First = 33; Last = 127; Rows = (New-FonTextRows 14 0xFF) })))
    Assert-Throws { & $conv -In $inTall -Out "$tmp\f2.CHR" } 'ink that fits an 8x8 cell' `
        'F2 a 14-row face whose ink overruns the cell is refused'
    Assert-Throws { & $conv -In $inTall -Out "$tmp\f2.CHR" } '8x14' `
        'F2 the refusal lists the declared cell of every face'

    # The Ultimate Oldschool PC Font Pack, if this machine happens to
    # have it, as a bonus over the synthesised twin above. Never the only
    # proof of anything, and never a silent skip.
    $pack = "D:\Urban Upstart\fonts\oldschool_pc_font_pack_v2.2_FULL\fon - Bm (windows bitmap)"
    $tall = Join-Path $pack 'Bm437_IBM_EGA_8x14.FON'
    if (Test-Path $tall) {
        Assert-Throws { & $conv -In $tall -Out "$tmp\f2pack.CHR" } 'does not fit|8x8' `
            'F2 a real 14-row face is refused'
    }
    else {
        Write-Warning "F2 pack bonus skipped: $tall not present (the synthesised twin above still ran)"
    }

    # --- F3 a truncated FON is refused with a fontconv: message, not a
    #     raw .NET exception ---
    # Minimal hand-built MZ/NE stub whose resource table offset (0xFFFF)
    # points past the end of the buffer. Exercises the bounds guard on
    # $rsrc in Read-FontFon.
    function New-TruncatedFonBytes {
        $bb = New-Object byte[] 128
        $bb[0] = 0x4D; $bb[1] = 0x5A                    # 'MZ'
        $bb[60] = 64                                     # e_lfanew -> NE header at 64
        $bb[64] = 0x4E; $bb[65] = 0x45                  # 'NE'
        $bb[100] = 0xFF; $bb[101] = 0xFF                # rsrcRel: resource table way past EOF
        return $bb
    }
    $inTrunc = "$tmp\f3.fon"
    [System.IO.File]::WriteAllBytes($inTrunc, (New-TruncatedFonBytes))
    Assert-Throws { & $conv -In $inTrunc -Out "$tmp\f3.CHR" } 'fontconv:' `
        'F3 a truncated FON is refused, not an unhandled exception'

    # --- F4/F5 a glyph the source declares wider than 8px: refused
    #     inside the text range, dropped-and-counted outside it ---
    # Minimal hand-built FON/FNT: one 8x8 face (so it is auto-picked,
    # no -Face needed), one character code whose FNT character-table
    # entry declares width 9. Every other header byte is zero; the
    # parser never dereferences bytes it does not need for this shape.
    function New-OverWideFonBytes([int]$code) {
        $bb = New-Object byte[] 300
        $bb[0] = 0x4D; $bb[1] = 0x5A                    # 'MZ'
        $bb[60] = 64                                     # e_lfanew -> NE header at 64
        $bb[64] = 0x4E; $bb[65] = 0x45                  # 'NE'
        $bb[100] = 64                                    # rsrcRel -> resource table at 128
        $bb[128] = 0                                      # rscAlignShift 0: rnOffset/rnLength are byte-exact
        $bb[130] = 0x08; $bb[131] = 0x80                # rtTypeID 0x8008 (RT_FONT; 0x8007 would be the FONTDIR decoy)
        $bb[132] = 1                                      # rtResourceCount
        $bb[138] = 160                                    # rnOffset -> FNT resource at file offset 160
        $bb[140] = 128                                    # rnLength
        # FNT header at 160: dfVersion 0x0200, dfCharSet ANSI, 8x8 cell
        $bb[160] = 0x00; $bb[161] = 0x02                # dfVersion
        $bb[160 + 85] = 0x00                              # dfCharSet
        $bb[160 + 86] = 8                                 # dfPixWidth
        $bb[160 + 88] = 8                                 # dfPixHeight
        $bb[160 + 95] = $code                             # dfFirstChar
        $bb[160 + 96] = $code                             # dfLastChar
        # character table at 160+118=278: one v2 entry, width 9 (over the cell)
        $bb[278] = 9
        return $bb
    }

    $inWide = "$tmp\f4.fon"
    [System.IO.File]::WriteAllBytes($inWide, (New-OverWideFonBytes 65))
    Assert-Throws { & $conv -In $inWide -Out "$tmp\f4.CHR" } '65' `
        'F4 an over-width glyph inside 32-127 is refused, naming the code'

    $inWideDeco = "$tmp\f5.fon"
    [System.IO.File]::WriteAllBytes($inWideDeco, (New-OverWideFonBytes 200))
    $f5msg = & $conv -In $inWideDeco -Out "$tmp\f5.CHR" | Out-String
    Assert-Eq ((Get-Item "$tmp\f5.CHR").Length) 2048 'F5 an over-width glyph outside 32-127 still converts'
    $script:checks++
    if ($f5msg -notmatch 'decorative glyph') { throw "F5 : expected a dropped-glyph note, got: $f5msg" }

    # --- F6 face selection measures ink, it does not read the declared
    #     cell ---
    # F2's twin, and the half that proves the rule: the same over-height
    # declaration - 9 rows, not 8 - with the ink stopping at row 7. A
    # selector reading the header refuses this outright; a selector
    # measuring ink must accept it and convert every glyph intact. These
    # two together are the FON side of the spec's "measured, not
    # declared" requirement, the same pairing P3/P4 make for PSF2.
    $inFits = "$tmp\f6.fon"
    [System.IO.File]::WriteAllBytes($inFits, (New-FonBytes @(
        @{ Height = 9; Charset = 0x00; First = 33; Last = 127; Rows = (New-FonTextRows 9 0x00) })))
    $f6msg = & $conv -In $inFits -Out "$tmp\f6.CHR" | Out-String
    $f6 = [System.IO.File]::ReadAllBytes("$tmp\f6.CHR")
    Assert-Eq $f6.Length 2048 'F6 a 9-row face whose ink fits 8 rows is accepted'
    Assert-Bytes $f6[520..527]   $fonPat 'F6 glyph 65 taken from the top 8 rows'
    Assert-Bytes $f6[1544..1551] $fonPat 'F6 glyph 193 mirrored'
    $script:checks++
    if ($f6msg -notmatch 'cell=8x9') { throw "F6 : expected the 8x9 face to be named, got: $f6msg" }

    # --- F7 -Face picks a face by index and by cell size ---
    # Two faces: 0 is 8x14 with ink on row 8 and cannot be used, 1 is 8x9
    # with ink inside 8 rows and can. Left to itself the converter must
    # find face 1, which is what makes each -Face check below meaningful:
    # a form that did nothing would land on face 1 too and look like a
    # pass, so the negative forms have to select the face that FAILS.
    $inTwo = "$tmp\f7.fon"
    [System.IO.File]::WriteAllBytes($inTwo, (New-FonBytes @(
        @{ Height = 14; Charset = 0x00; First = 33; Last = 127; Rows = (New-FonTextRows 14 0xFF) },
        @{ Height =  9; Charset = 0x00; First = 33; Last = 127; Rows = (New-FonTextRows 9 0x00) })))
    $f7msg = & $conv -In $inTwo -Out "$tmp\f7.CHR" | Out-String
    Assert-Bytes ([System.IO.File]::ReadAllBytes("$tmp\f7.CHR"))[520..527] $fonPat `
        'F7 with no -Face the usable face is found even though the taller one is declared first'
    $script:checks++
    if ($f7msg -notmatch 'cell=8x9') { throw "F7 : expected face 1 to be chosen, got: $f7msg" }

    # The index form, on the face that works.
    & $conv -In $inTwo -Out "$tmp\f7i.CHR" -Face 1 | Out-Null
    Assert-Bytes ([System.IO.File]::ReadAllBytes("$tmp\f7i.CHR"))[520..527] $fonPat `
        'F7 -Face 1 selects face 1 by index'
    # The index form and the WxH form, each on the face that does NOT
    # work: the refusal is the proof the form reached that face at all.
    Assert-Throws { & $conv -In $inTwo -Out "$tmp\f7x.CHR" -Face 0 } 'does not fit' `
        'F7 -Face 0 selects the unusable face by index rather than falling back'
    Assert-Throws { & $conv -In $inTwo -Out "$tmp\f7x.CHR" -Face 8x14 } 'does not fit' `
        'F7 -Face 8x14 selects the unusable face by cell size'
    # A -Face matching nothing lists what was on offer.
    Assert-Throws { & $conv -In $inTwo -Out "$tmp\f7x.CHR" -Face 9x9 } 'matches nothing' `
        'F7 -Face 9x9 matches nothing and says so'
    Assert-Throws { & $conv -In $inTwo -Out "$tmp\f7x.CHR" -Face 9x9 } '0: 8x14; 1: 8x9' `
        'F7 the -Face refusal lists every face with its index'
    # A face index too large for Int32 is a fontconv: refusal, not a raw
    # .NET conversion exception - the same treatment BDF header numbers
    # already get.
    Assert-Throws { & $conv -In $inTwo -Out "$tmp\f7x.CHR" -Face 99999999999999 } 'fontconv:' `
        'F7 an out-of-range -Face index is refused with a fontconv: message'

    # --- F8 a FON whose glyph data runs past the end of the file ---
    # Inside 32-127 that must be a refusal naming the code: a skipped
    # glyph leaves the base font's in its slot, which is a silent
    # half-converted alphabet under a clean success line. Built by
    # pointing one character-table entry's offset near the end of the
    # file, so only that glyph is unreadable and everything else parses.
    $truncBytes = New-FonBytes @(
        @{ Height = 9; Charset = 0x00; First = 65; Last = 66; Rows = @{ 65 = (New-FonGlyph 9 0x00); 66 = (New-FonGlyph 9 0x00) } })
    Set-U16 $truncBytes (1024 + 118 + 2) (4090)          # code 65's geOffset, 9 rows from there run off the end
    $inTrunc2 = "$tmp\f8.fon"
    [System.IO.File]::WriteAllBytes($inTrunc2, $truncBytes)
    Assert-Throws { & $conv -In $inTrunc2 -Out "$tmp\f8.CHR" } 'truncated' `
        'F8 a FON glyph running past the end of the file is refused, not silently left as the base font'
    Assert-Throws { & $conv -In $inTrunc2 -Out "$tmp\f8.CHR" } '65' `
        'F8 the truncation refusal names the code'

    # Outside 32-127 the same truncation is decorative: dropped, counted
    # and reported, like anything else that cannot be used.
    $truncDeco = New-FonBytes @(
        @{ Height = 9; Charset = 0x00; First = 200; Last = 201; Rows = @{ 200 = (New-FonGlyph 9 0x00); 201 = (New-FonGlyph 9 0x00) } })
    Set-U16 $truncDeco (1024 + 118 + 2) (4090)
    $inTruncDeco = "$tmp\f9.fon"
    [System.IO.File]::WriteAllBytes($inTruncDeco, $truncDeco)
    $f9msg = & $conv -In $inTruncDeco -Out "$tmp\f9.CHR" | Out-String
    Assert-Eq ((Get-Item "$tmp\f9.CHR").Length) 2048 'F9 a truncated glyph outside 32-127 still converts'
    $script:checks++
    if ($f9msg -notmatch 'dropped') { throw "F9 : expected a dropped-glyph note, got: $f9msg" }

    # --- F10 the in-face pound lift obeys the same fits check as every
    #     other lifted glyph ---
    # An OEM face declaring 9 rows whose slot 156 has ink on row 8. The
    # lift would clip it to 8 rows and ship it, in the same output line
    # that reports a glyph dropped for not fitting the cell. Glyph 96
    # must come from the base font instead.
    $lift = @{}
    $lift[156] = (New-FonGlyph 9 0xFF)
    $inPound = "$tmp\f10.fon"
    [System.IO.File]::WriteAllBytes($inPound, (New-FonBytes @(
        @{ Height = 9; Charset = 0xFF; First = 156; Last = 156; Rows = $lift })))
    $f10msg = & $conv -In $inPound -Out "$tmp\f10.CHR" | Out-String
    $f10 = [System.IO.File]::ReadAllBytes("$tmp\f10.CHR")
    Assert-Bytes $f10[768..775] $baseBytes[768..775] `
        'F10 a slot 156 whose ink overruns the cell is not lifted, clipped, into glyph 96'
    $script:checks++
    if ($f10msg -notmatch 'pound sterling \(96\) from base') { throw "F10 : expected the base-font pound note, got: $f10msg" }
    $script:checks++
    if ($f10msg -notmatch 'dropped') { throw "F10 : expected the dropped-glyph note alongside it, got: $f10msg" }

    # --- F11 a JSJ SINTAC font is recognised and refused by name ---
    # DAAD Ready's PC.FNT and PCDAAD's DAAD.FNT. It stores per-character
    # width tables rather than a fixed cell, so there is nothing to copy
    # across - the point of detecting it is to say that rather than let
    # it fall through to the raw reader and convert into nonsense.
    $inSintac = "$tmp\f11.fnt"
    [System.IO.File]::WriteAllBytes($inSintac, [System.Text.Encoding]::ASCII.GetBytes('JSJ SINTAC'))
    Assert-Throws { & $conv -In $inSintac -Out "$tmp\f11.CHR" } 'SINTAC' `
        'F11 a JSJ SINTAC font is refused by name'
    Assert-Throws { & $conv -In $inSintac -Out "$tmp\f11.CHR" } 'AD8x8' `
        'F11 the SINTAC refusal names the ready-made table to use instead'

    # --- R1 a raw dump placed where the table draws nothing from it ---
    # -First 300 on G3's 896-byte dump puts all 112 glyphs at 300-411, so
    # no source glyph reaches any of the three ranges the slot map takes
    # from a source and the converter would report a clean success over a
    # table with nothing of the source in it.
    Assert-Throws { & $conv -In $inRaw -Out "$tmp\r1.CHR" -First 300 } '16-31, 32-127 and 128-159' `
        'R1 a -First that lands no glyph in 16-159 is refused, not a silent no-op'

    # R1's other half: 32-127 is NOT the whole of what an assembled table
    # takes from a source. The slot map draws 16-31 and 128-159 from it
    # as well, and a raw dump is the only way to bring an author's UDGs
    # or decorative glyphs in from a headerless file, so a dump landing
    # wholly in either range must convert - guarding on 32-127 alone
    # would refuse two first-class cases.
    $r16 = New-Object byte[] 128                          # 16 glyphs
    $rmk = [byte[]](0x7E,0x81,0xA5,0x81,0xBD,0x99,0x81,0x7E)
    [System.Array]::Copy($rmk, 0, $r16, 0, 8)             # the first glyph
    [System.Array]::Copy($rmk, 0, $r16, 15 * 8, 8)        # and the last
    $inR16 = "$tmp\r1b.fnt"
    [System.IO.File]::WriteAllBytes($inR16, $r16)
    & $conv -In $inR16 -Out "$tmp\r1b.CHR" -First 16 | Out-Null
    $rb16 = [System.IO.File]::ReadAllBytes("$tmp\r1b.CHR")
    Assert-Bytes $rb16[128..135] $rmk 'R1 -First 16 places the first glyph at code 16'
    Assert-Bytes $rb16[248..255] $rmk 'R1 -First 16 places the last glyph at code 31'
    & $conv -In $inR16 -Out "$tmp\r1c.CHR" -First 128 | Out-Null
    $rb128 = [System.IO.File]::ReadAllBytes("$tmp\r1c.CHR")
    Assert-Bytes $rb128[1024..1031] $rmk 'R1 -First 128 places the first glyph at code 128'
    Assert-Bytes $rb128[1144..1151] $rmk 'R1 -First 128 places the last glyph at code 143'

    # --- R2 a length that is not a multiple of 8 is diagnosed first ---
    # 901 bytes can never be a glyph table. Being told to supply -First
    # and only then being told the length is wrong is two errors for one
    # file, so the multiple-of-8 check runs first.
    $in901 = "$tmp\r2.fnt"
    [System.IO.File]::WriteAllBytes($in901, (New-Object byte[] 901))
    Assert-Throws { & $conv -In $in901 -Out "$tmp\r2.CHR" } 'multiple of 8' `
        'R2 a 901-byte raw file is refused for its length, not sent away for -First'
    # And the glyph count in the -First message is whole, not 112.625.
    Assert-Throws { & $conv -In $inRaw -Out "$tmp\r2.CHR" } '\(112 glyphs\)' `
        'R2 the -First message counts whole glyphs'

    # --- P1 PSF1, generated here from known bytes ---
    # 256 glyphs of 8 rows. Character 65 carries a marker; the converter
    # must place it at glyph 65 and mirror it to 193.
    $mk = [byte[]](0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00)
    $p1 = New-Object byte[] (4 + 256*8)
    $p1[0] = 0x36; $p1[1] = 0x04; $p1[2] = 0x00; $p1[3] = 0x08
    [System.Array]::Copy($mk, 0, $p1, 4 + 65*8, 8)
    $inP1 = "$tmp\p1.psf"
    [System.IO.File]::WriteAllBytes($inP1, $p1)
    & $conv -In $inP1 -Out "$tmp\p1.CHR" | Out-Null
    $rp1 = [System.IO.File]::ReadAllBytes("$tmp\p1.CHR")
    Assert-Bytes $rp1[520..527]   $mk 'P1 PSF1 glyph 65'
    Assert-Bytes $rp1[1544..1551] $mk 'P1 PSF1 glyph 193 mirrored'

    # --- P2 PSF2, generated here, 8 wide by 8 high ---
    $p2 = New-Object byte[] (32 + 256*8)
    $p2[0]=0x72; $p2[1]=0xB5; $p2[2]=0x4A; $p2[3]=0x86
    [System.Array]::Copy([BitConverter]::GetBytes([int]0),   0, $p2,  4, 4)  # version
    [System.Array]::Copy([BitConverter]::GetBytes([int]32),  0, $p2,  8, 4)  # headersize
    [System.Array]::Copy([BitConverter]::GetBytes([int]0),   0, $p2, 12, 4)  # flags
    [System.Array]::Copy([BitConverter]::GetBytes([int]256), 0, $p2, 16, 4)  # length
    [System.Array]::Copy([BitConverter]::GetBytes([int]8),   0, $p2, 20, 4)  # charsize
    [System.Array]::Copy([BitConverter]::GetBytes([int]8),   0, $p2, 24, 4)  # height
    [System.Array]::Copy([BitConverter]::GetBytes([int]8),   0, $p2, 28, 4)  # width
    [System.Array]::Copy($mk, 0, $p2, 32 + 65*8, 8)
    $inP2 = "$tmp\p2.psfu"
    [System.IO.File]::WriteAllBytes($inP2, $p2)
    & $conv -In $inP2 -Out "$tmp\p2.CHR" | Out-Null
    $rp2 = [System.IO.File]::ReadAllBytes("$tmp\p2.CHR")
    Assert-Bytes $rp2[520..527]   $mk 'P2 PSF2 glyph 65'
    Assert-Bytes $rp2[1544..1551] $mk 'P2 PSF2 glyph 193 mirrored'

    # --- P3 a 16-row PSF2 is refused ---
    $p3 = New-Object byte[] (32 + 256*16)
    [System.Array]::Copy($p2, 0, $p3, 0, 32)
    [System.Array]::Copy([BitConverter]::GetBytes([int]16), 0, $p3, 20, 4)
    [System.Array]::Copy([BitConverter]::GetBytes([int]16), 0, $p3, 24, 4)
    for ($c = 32; $c -lt 128; $c++) { $p3[32 + $c*16 + 12] = 0xFF }   # ink on row 12
    $inP3 = "$tmp\p3.psfu"
    [System.IO.File]::WriteAllBytes($inP3, $p3)
    Assert-Throws { & $conv -In $inP3 -Out "$tmp\p3.CHR" } 'does not fit' 'P3 a 16-row PSF2 is refused'

    # --- P4 the gate measures ink, it does not read the header ---
    # P3's twin, and the half that proves the rule: the SAME 16-row
    # declaration, but with the ink stopping at row 7. A gate reading the
    # header would refuse this; a gate measuring ink must accept it.
    # These two checks together are the spec's "measured, not declared"
    # requirement - neither one proves it alone.
    $p4 = New-Object byte[] (32 + 256*16)
    [System.Array]::Copy($p3, 0, $p4, 0, 32)
    for ($c = 32; $c -lt 128; $c++) {
        if ($c -eq 32) { continue }                       # glyph 32 stays blank
        [System.Array]::Copy($mk, 0, $p4, 32 + $c*16, 8)  # ink in rows 0-7 only
    }
    $inP4 = "$tmp\p4.psfu"
    [System.IO.File]::WriteAllBytes($inP4, $p4)
    & $conv -In $inP4 -Out "$tmp\p4.CHR" | Out-Null
    $rp4 = [System.IO.File]::ReadAllBytes("$tmp\p4.CHR")
    Assert-Eq $rp4.Length 2048 'P4 a 16-row declaration whose ink fits 8 rows is accepted'
    Assert-Bytes $rp4[520..527]   $mk 'P4 glyph 65 taken from the top 8 rows'
    Assert-Bytes $rp4[1544..1551] $mk 'P4 glyph 193 mirrored'

    # --- P5 a PSF2 declaring a cell wider than 8px is refused, not
    #     cropped ---
    # width 16 with charsize sized consistently (2 bytes/row * 8 rows),
    # so the file is otherwise perfectly valid and the only thing that
    # can make it fail is the width check itself.
    $p5 = New-Object byte[] (32 + 256*16)
    $p5[0]=0x72; $p5[1]=0xB5; $p5[2]=0x4A; $p5[3]=0x86
    [System.Array]::Copy([BitConverter]::GetBytes([int]0),   0, $p5,  4, 4)  # version
    [System.Array]::Copy([BitConverter]::GetBytes([int]32),  0, $p5,  8, 4)  # headersize
    [System.Array]::Copy([BitConverter]::GetBytes([int]0),   0, $p5, 12, 4)  # flags
    [System.Array]::Copy([BitConverter]::GetBytes([int]256), 0, $p5, 16, 4)  # length
    [System.Array]::Copy([BitConverter]::GetBytes([int]16),  0, $p5, 20, 4)  # charsize
    [System.Array]::Copy([BitConverter]::GetBytes([int]8),   0, $p5, 24, 4)  # height
    [System.Array]::Copy([BitConverter]::GetBytes([int]16),  0, $p5, 28, 4)  # width
    $inP5 = "$tmp\p5.psfu"
    [System.IO.File]::WriteAllBytes($inP5, $p5)
    Assert-Throws { & $conv -In $inP5 -Out "$tmp\p5.CHR" } 'declares a cell 16 pixels wide' `
        'P5 a PSF2 wider than 8px is refused, not cropped'
    # P2 above already proves width 8 still converts - not duplicated here.

    # --- P6 PSF1 mode bit 0 selects the 512-glyph table ---
    # P6a: a file sized for the 256-glyph table, with bit 0 set. If bit 0
    # were ignored this would pass as an ordinary 256-glyph PSF1; honoured,
    # it demands 512 glyphs and the file is short, so it must be refused,
    # naming 512.
    $p6short = New-Object byte[] (4 + 256*8)
    $p6short[0] = 0x36; $p6short[1] = 0x04; $p6short[2] = 0x01; $p6short[3] = 0x08
    $inP6s = "$tmp\p6short.psf"
    [System.IO.File]::WriteAllBytes($inP6s, $p6short)
    Assert-Throws { & $conv -In $inP6s -Out "$tmp\p6short.CHR" } '512' `
        'P6a mode bit 0 requires 512 glyphs; a 256-glyph file is refused'

    # P6b: the full-size twin, 512 glyphs, mode bit 0 set, same marker at
    # glyph 65 used throughout this suite - must convert exactly as P1 did.
    $p6 = New-Object byte[] (4 + 512*8)
    $p6[0] = 0x36; $p6[1] = 0x04; $p6[2] = 0x01; $p6[3] = 0x08
    [System.Array]::Copy($mk, 0, $p6, 4 + 65*8, 8)
    $inP6 = "$tmp\p6.psf"
    [System.IO.File]::WriteAllBytes($inP6, $p6)
    & $conv -In $inP6 -Out "$tmp\p6.CHR" | Out-Null
    $rp6 = [System.IO.File]::ReadAllBytes("$tmp\p6.CHR")
    Assert-Bytes $rp6[520..527]   $mk 'P6b 512-glyph PSF1 glyph 65'
    Assert-Bytes $rp6[1544..1551] $mk 'P6b 512-glyph PSF1 glyph 193 mirrored'

    # --- B1 BDF placement puts the descender below the baseline ---
    # An 8x8 cell with FONT_ASCENT 7. 'A' is a 7-row box sitting on the
    # baseline (BBX yoff 0) and must land at cell rows 0-6. 'g' is a
    # 7-row box dropped one row below the baseline (BBX yoff -1) and
    # must land at cell rows 1-7.
    $bdf = @'
STARTFONT 2.1
FONT -test-fixed-medium-r-normal--8-80-75-75-c-80-iso10646-1
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 -1
STARTPROPERTIES 2
FONT_ASCENT 7
FONT_DESCENT 1
ENDPROPERTIES
CHARS 2
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 7 0 0
BITMAP
FF
81
81
81
81
81
FF
ENDCHAR
STARTCHAR g
ENCODING 103
SWIDTH 500 0
DWIDTH 8 0
BBX 8 7 0 -1
BITMAP
3C
42
42
3C
02
02
3C
ENDCHAR
ENDFONT
'@
    $inB = "$tmp\b1.bdf"
    Set-Content -LiteralPath $inB -Value $bdf -Encoding ascii
    & $conv -In $inB -Out "$tmp\b1.CHR" | Out-Null
    $rb = [System.IO.File]::ReadAllBytes("$tmp\b1.CHR")
    Assert-Bytes $rb[520..527] ([byte[]](0xFF,0x81,0x81,0x81,0x81,0x81,0xFF,0x00)) 'B1 A on the baseline, rows 0-6'
    Assert-Bytes $rb[824..831] ([byte[]](0x00,0x3C,0x42,0x42,0x3C,0x02,0x02,0x3C)) 'B1 g dropped one row, rows 1-7'
    Assert-Bytes $rb[1544..1551] ([byte[]](0xFF,0x81,0x81,0x81,0x81,0x81,0xFF,0x00)) 'B1 glyph 193 mirrors A'

    # --- B2/B3 a BBX wider than the cell is refused inside the text
    # range and merely dropped outside it ---
    # The pair is what proves the OverWide route was used rather than a
    # blanket refusal: same font, same 12-wide glyph, different code.
    function New-WideBdf([int]$code) {
@"
STARTFONT 2.1
FONT -test-wide
SIZE 8 75 75
FONTBOUNDINGBOX 12 8 0 0
STARTPROPERTIES 2
FONT_ASCENT 7
FONT_DESCENT 1
ENDPROPERTIES
CHARS 1
STARTCHAR wide
ENCODING $code
SWIDTH 500 0
DWIDTH 12 0
BBX 12 7 0 0
BITMAP
FFF0
8010
8010
8010
8010
8010
FFF0
ENDCHAR
ENDFONT
"@
    }
    $inB2 = "$tmp\b2.bdf"
    Set-Content -LiteralPath $inB2 -Value (New-WideBdf 65) -Encoding ascii
    Assert-Throws { & $conv -In $inB2 -Out "$tmp\b2.CHR" } '65' `
        'B2 a 12-wide glyph at code 65 is refused, naming the code'
    $inB3 = "$tmp\b3.bdf"
    Set-Content -LiteralPath $inB3 -Value (New-WideBdf 200) -Encoding ascii
    $b3out = & $conv -In $inB3 -Out "$tmp\b3.CHR" | Out-String
    Assert-Eq ((Get-Item "$tmp\b3.CHR").Length) 2048 'B3 a 12-wide glyph at code 200 still converts'
    $script:checks++
    if ($b3out -notmatch 'dropped') { throw "B3 : expected the dropped-glyph note, got: $b3out" }

    # --- B4 a glyph whose STARTCHAR block omits BBX must not inherit
    #     the previous glyph's box ---
    # Two glyphs: 'A' has a normal BBX, 'B' has none at all. A parser
    # that lets bbxW/bbxH/bbxYoff carry over between glyphs would parse
    # 'B' silently, using 'A's box; the correct behaviour is to refuse
    # the file, naming the glyph that is missing its declaration.
    $bdfNoBbx = @'
STARTFONT 2.1
FONT -test-nobbx
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 -1
STARTPROPERTIES 2
FONT_ASCENT 7
FONT_DESCENT 1
ENDPROPERTIES
CHARS 2
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 7 0 0
BITMAP
FF
81
81
81
81
81
FF
ENDCHAR
STARTCHAR B
ENCODING 66
SWIDTH 500 0
DWIDTH 8 0
BITMAP
FF
81
81
81
81
81
FF
ENDCHAR
ENDFONT
'@
    $inB4 = "$tmp\b4.bdf"
    Set-Content -LiteralPath $inB4 -Value $bdfNoBbx -Encoding ascii
    Assert-Throws { & $conv -In $inB4 -Out "$tmp\b4.CHR" } '66' `
        'B4 a glyph missing its own BBX is refused, naming the code, not inherited from the previous glyph'

    # --- B5 an implausible FONT_ASCENT is refused with a fontconv:
    #     message, not left to a raw .NET conversion/allocation
    #     exception ---
    # 14 nines overflows Int32 outright - a plain [int] cast throws
    # "Value was either too large or too small for an Int32" with no
    # fontconv: prefix. This is the deterministic failure mode: it does
    # not depend on how much memory a huge-but-valid Int32 allocation
    # happens to succeed with on a given machine.
    $bdfBigAscent = @'
STARTFONT 2.1
FONT -test-bigascent
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 -1
STARTPROPERTIES 2
FONT_ASCENT 99999999999999
FONT_DESCENT 1
ENDPROPERTIES
CHARS 1
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 7 0 0
BITMAP
FF
81
81
81
81
81
FF
ENDCHAR
ENDFONT
'@
    $inB5 = "$tmp\b5.bdf"
    Set-Content -LiteralPath $inB5 -Value $bdfBigAscent -Encoding ascii
    Assert-Throws { & $conv -In $inB5 -Out "$tmp\b5.CHR" } 'fontconv:' `
        'B5 an implausible FONT_ASCENT is refused with a fontconv: message'

    # --- B6 a malformed BITMAP row is refused rather than silently
    #     read as a blank row ---
    $bdfBadRow = @'
STARTFONT 2.1
FONT -test-badrow
SIZE 8 75 75
FONTBOUNDINGBOX 8 8 0 -1
STARTPROPERTIES 2
FONT_ASCENT 7
FONT_DESCENT 1
ENDPROPERTIES
CHARS 1
STARTCHAR A
ENCODING 65
SWIDTH 500 0
DWIDTH 8 0
BBX 8 7 0 0
BITMAP
FF
ZZ
81
81
81
81
FF
ENDCHAR
ENDFONT
'@
    $inB6 = "$tmp\b6.bdf"
    Set-Content -LiteralPath $inB6 -Value $bdfBadRow -Encoding ascii
    Assert-Throws { & $conv -In $inB6 -Out "$tmp\b6.CHR" } 'fontconv:.*malformed BITMAP row' `
        'B6 a malformed BITMAP row is refused, not read as a blank row'

    "fontconv-selftest: $checks checks passed"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
