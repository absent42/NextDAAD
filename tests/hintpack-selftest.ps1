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
$accented = "El beb$eAcute est$aAcute aqu$iAcute, junto al mu$($nTilde)eco peque$($nTilde)o."
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
"@
$src = "$tmp\HINTS.TXT"
[IO.File]::WriteAllBytes($src, $srcEnc.GetBytes($srcText))

$out = "$tmp\GAME.HNT"
& $pack -In $src -Out $out
if ($LASTEXITCODE -ne 0) { throw "hintpack exited $LASTEXITCODE" }

$b = [IO.File]::ReadAllBytes($out)
Assert-Eq ([Text.Encoding]::ASCII.GetString($b[0..2])) 'HNT' 'magic'
Assert-Eq $b[3] 1 'version'
Assert-Eq $b[5] 9 'maxTopic is the highest topic NUMBER'
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
Assert-Eq (LevelText 9 0) $accented 'accented Latin-1 text survives the round trip'

# The specific high byte, not just the round-tripped string, so an
# ASCII regression (which would have written 0x3F for n-tilde) is caught
# even if some other bug in the comparison above let a wrong string equal
# a wrong expectation.
$accentedBytes = LevelBytes 9 0
if ($accentedBytes -notcontains 0xF1) {
    throw 'expected Latin-1 byte 0xF1 (n-tilde) missing from deobfuscated accented text'
}
$checks++

# The obfuscation must actually obscure: the plaintext must not appear.
$raw = [Text.Encoding]::ASCII.GetString($b)
if ($raw.Contains('Nudge one.')) { throw 'plaintext is visible in the packed file' }
$checks++

Remove-Item $tmp -Recurse -Force
Write-Output "hintpack selftest: $checks checks passed"
