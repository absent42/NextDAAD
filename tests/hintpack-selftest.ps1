# Self-contained assertions over authoring-kit\lib\hintpack.ps1. Run
# unconditionally by tests\build-tests.ps1, and standalone during development:
#   pwsh -NoProfile -File tests\hintpack-selftest.ps1
# Fixtures are generated here from known bytes, so there is no corpus to
# install and nothing to keep in sync.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$pack = "$root\authoring-kit\lib\hintpack.ps1"
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("hintpack-selftest-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
$checks = 0

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "$what : got '$actual', expected '$expected'" }
}

# The keystream the extern must reproduce byte for byte. If this changes,
# hints.asm changes with it or every hint decodes to noise.
function Key([int]$offset, [int]$seed) {
    $s = ((($offset -band 255) * 167) + 89) -band 255
    return $s -bxor (($offset -shr 8) -band 255) -bxor $seed
}

Assert-Eq (Key 0 0)    89  'keystream at offset 0, seed 0'
Assert-Eq (Key 1 0)    ((167 + 89) -band 255) 'keystream at offset 1, seed 0'
Assert-Eq (Key 256 0)  (89 -bxor 1) 'keystream at offset 256 flips the high byte in'
Assert-Eq (Key 0 255)  (89 -bxor 255) 'keystream mixes the seed'

# S must be a permutation, or distinct plaintext bytes could collide.
$seen = New-Object bool[] 256
for ($i = 0; $i -lt 256; $i++) {
    $v = (($i * 167) + 89) -band 255
    if ($seen[$v]) { throw "S is not a permutation: value $v repeats at i=$i" }
    $seen[$v] = $true
}
$checks++

# Round trip: author a file, pack it, unpack it by hand, compare.
# Written as raw Latin-1 bytes, not a here-string, so the .ps1 file's own
# encoding can never be the reason the accented text on disk is right or
# wrong - the test controls the bytes, not the editor.
$srcEnc = [Text.Encoding]::GetEncoding(28591)
$aAcute = [char]0xE1
$eAcute = [char]0xE9
$iAcute = [char]0xED
$nTilde = [char]0xF1
$aGrave = [char]0xE0
$yDieresis = [char]0xFF   # not in the compiler's accent table - passes raw
$accented = "El beb$eAcute est$aAcute aqu$iAcute, junto al mu$($nTilde)eco peque$($nTilde)o. Voil$($aGrave)."
$srcText = @"
This line is a comment, before any topic marker.

[0] The first puzzle

Nudge one.

Nudge two is longer, and
spans an authored line break.

[7] The locked gate

Only one level here.

[9] Foreign accents

$accented

[11] Unsupported character

Stray y-diaeresis: $yDieresis here.
"@
$src = "$tmp\HINTS.TXT"
[IO.File]::WriteAllBytes($src, $srcEnc.GetBytes($srcText))

$out = "$tmp\GAME.HNT"
$packWarnings = $null
& $pack -In $src -Out $out -WarningVariable packWarnings -WarningAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "hintpack exited $LASTEXITCODE" }

# Convert-Accents legitimately emits $0E/$0F triples for topic 9's accents -
# the control-byte-below-$20 check must inspect the AUTHOR'S SOURCE, not
# that packed output, so topic 9 (clean source, no bytes below $20) must
# raise NO control-byte warning of its own.
if ($packWarnings | Where-Object { $_ -match 'topic 9.*control byte' }) {
    throw "control-byte warning fired for topic 9 - it must inspect source bytes, not the packer's own $0E/$0F output"
}
$checks++

# A character the compiler's table does not convert (y-diaeresis, 0xFF) must
# warn, naming the character, topic and level, rather than inventing a
# mapping - it passes through raw and a real compile would reject it.
if (-not ($packWarnings | Where-Object { $_ -match 'topic 11 level 1.*0xFF' })) {
    throw "no warning for the unsupported character (0xFF) in topic 11 level 1"
}
$checks++

$b = [IO.File]::ReadAllBytes($out)
Assert-Eq ([Text.Encoding]::ASCII.GetString($b[0..2])) 'HNT' 'magic'
Assert-Eq $b[3] 1 'version'
Assert-Eq $b[5] 11 'maxTopic is the highest topic NUMBER'
$seed = $b[4]

# Deobfuscate everything from offset 6 on.
$p = $b.Clone()
for ($o = 6; $o -lt $p.Length; $o++) { $p[$o] = $p[$o] -bxor (Key $o $seed) }

function DirEntry([int]$topic) {
    $o = 6 + 3 * $topic
    return @{ Off = $p[$o] + 256 * $p[$o + 1]; Count = $p[$o + 2] }
}
function LevelBytes([int]$topic, [int]$level) {
    $d = DirEntry $topic
    if ($d.Count -eq 0) { return $null }
    $e = $d.Off + 4 * $level
    $to = $p[$e] + 256 * $p[$e + 1]
    $tl = $p[$e + 2] + 256 * $p[$e + 3]
    return $p[$to..($to + $tl - 1)]
}
# Same 28591 encoding the packer reads and writes with - ASCII here would
# hide a regression to ASCII in hintpack.ps1 itself.
function LevelText([int]$topic, [int]$level) {
    $bytes = LevelBytes $topic $level
    if ($null -eq $bytes) { return $null }
    return $srcEnc.GetString($bytes)
}

Assert-Eq (DirEntry 0).Count 2 'topic 0 has two levels'
Assert-Eq (DirEntry 7).Count 1 'topic 7 has one level'
Assert-Eq (DirEntry 9).Count 1 'topic 9 has one level'
foreach ($t in (@(1..6) + 8)) { Assert-Eq (DirEntry $t).Count 0 "absent topic $t reports zero levels" }
Assert-Eq (LevelText 0 0) 'Nudge one.' 'topic 0 level 0 text'
Assert-Eq (LevelText 0 1) 'Nudge two is longer, and spans an authored line break.' 'a single newline becomes a space'
Assert-Eq (LevelText 7 0) 'Only one level here.' 'topic 7 level 0 text'

# Accented text is no longer stored as raw Latin-1 - hintpack.ps1 now
# converts it the way the DDB compiler does (tests\hintpack-accent-oracle.ps1
# proves that conversion matches ndrc.exe byte for byte), so it does not
# round-trip through LevelText's plain Latin-1 decode. Assert the specific
# converted bytes instead: this REPOINTS the old assertion, which wrongly
# expected the raw Latin-1 byte 0xF1 (n-tilde) to survive packing - the
# compiler never emits that byte, it emits CC_DIRECT $1A.
$accentedBytes = LevelBytes 9 0
if ($accentedBytes -contains 0xF1) {
    throw 'raw Latin-1 byte 0xF1 (n-tilde) found in packed hint text - accent conversion did not run'
}
function ContainsRun([byte[]]$hay, [byte[]]$needle) {
    for ($i = 0; $i -le $hay.Length - $needle.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}
# Encoding 1 (direct, single byte): n-tilde -> $1A, inside "mu" + n-tilde + "eco".
if (-not (ContainsRun $accentedBytes ([byte[]]@(0x6D, 0x75, 0x1A, 0x65, 0x63, 0x6F)))) {
    throw 'packed hint bytes missing the compiler direct encoding ($1A) for n-tilde'
}
$checks++
# Encoding 2 (triple): a-grave -> $0E $10 $0F, inside "Voil" + a-grave + ".".
if (-not (ContainsRun $accentedBytes ([byte[]]@(0x56, 0x6F, 0x69, 0x6C, 0x0E, 0x10, 0x0F, 0x2E)))) {
    throw 'packed hint bytes missing the compiler triple encoding ($0E $10 $0F) for a-grave'
}
$checks++

# The obfuscation must actually obscure: the plaintext must not appear.
$raw = [Text.Encoding]::ASCII.GetString($b)
if ($raw.Contains('Nudge one.')) { throw 'plaintext is visible in the packed file' }
$checks++

Remove-Item $tmp -Recurse -Force
Write-Output "hintpack selftest: $checks checks passed"
