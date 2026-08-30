# hintpack.ps1 - pack HINTS.TXT into the obfuscated GAME.HNT the hints
# extern reads. Called by BUILD.BAT; the format and keystream are pinned by
# tests\hintpack-selftest.ps1 and by externs\hints\hints.asm.
param(
    [Parameter(Mandatory = $true)][string]$In,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Seed = -1
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $In)) { Write-Error "hint source not found: $In"; exit 1 }
# Fixed, not random: the seed is PLAINTEXT at GAME.HNT offset 4, so it adds
# no protection; random would churn GAME.HNT and, since GAME.HPR shares the
# key, break players' progress on every update. -Seed stays for the self-test.
if ($Seed -lt 0) { $Seed = 137 }

# Parse: [n] opens a topic, blank-line-separated paragraphs are its levels,
# single newlines inside a paragraph become spaces.
$topics = @{}
$current = -1
$para = New-Object Collections.Generic.List[string]
function Flush-Para {
    if ($script:current -lt 0) { $script:para.Clear(); return }
    if ($script:para.Count -eq 0) { return }
    $text = ($script:para -join ' ').Trim()
    if ($text) { $script:topics[$script:current].Add($text) }
    $script:para.Clear()
}
# ISO 8859-1 throughout: DSF sources are Latin-1 and DAAD's home territory
# is Spanish, so ASCII decoding would silently turn every accent into '?'.
$enc = [Text.Encoding]::GetEncoding(28591)

# DRC's own accent conversion (DRF ConvertChars, ported at NDRC's
# src\front\jsonexport.c CC_DIRECT/CC_WRAPPED), so packed hint bytes match
# what the compiler puts in a DDB message. Oracle-verified against
# authoring-kit\lib\ndrc.exe by tests\hintpack-accent-oracle.ps1.
# CC_DIRECT: Latin-1 byte -> one output byte (encoding 1, plus sharp-s).
$ccDirect = @{
    170=0x10; 161=0x11; 191=0x12; 171=0x13; 187=0x14; 225=0x15; 233=0x16;
    237=0x17; 243=0x18; 250=0x19; 241=0x1A; 209=0x1B; 231=0x1C; 199=0x1D;
    252=0x1E; 220=0x1F; 223=0x7F
}
# CC_WRAPPED: Latin-1 byte -> key byte, emitted as $0E key $0F (encoding 2,
# uppercase accents and acutes).
$ccWrapped = @{
    193=0x7B; 201=0x7C; 205=0x7D; 211=0x7E; 218=0x7F;
    224=0x10; 227=0x11; 228=0x12; 226=0x13; 232=0x14; 235=0x15; 234=0x16;
    236=0x17; 239=0x18; 238=0x19; 242=0x1A; 245=0x1B; 246=0x1C; 244=0x1D;
    249=0x1E; 251=0x1F;
    192=0x20; 195=0x21; 196=0x22; 194=0x23; 200=0x24; 203=0x25; 202=0x26;
    204=0x27; 207=0x28; 206=0x29; 210=0x2A; 213=0x2B; 214=0x2C; 212=0x2D;
    217=0x2E; 219=0x2F;
    253=0x3A; 221=0x3B; 254=0x3C; 222=0x3D; 229=0x3E; 197=0x3F;
    240=0x5B; 208=0x5C; 248=0x5D; 216=0x5E
}
# A byte the compiler's table does not convert passes through raw and is
# later fatally rejected by DRB's checkStrings - warn rather than invent a
# mapping, naming the character, topic and level so the author can fix it.
function Convert-Accents([string]$text, [string]$srcName, [int]$topic, [int]$level) {
    $out = New-Object Collections.Generic.List[byte]
    foreach ($ch in $enc.GetBytes($text)) {
        if ($ccDirect.ContainsKey([int]$ch)) { $out.Add([byte]$ccDirect[[int]$ch]); continue }
        if ($ccWrapped.ContainsKey([int]$ch)) {
            $out.Add([byte]0x0E); $out.Add([byte]$ccWrapped[[int]$ch]); $out.Add([byte]0x0F); continue
        }
        if ($ch -gt 127) {
            Write-Warning "$srcName topic $topic level $level : character 0x$($ch.ToString('X2')) is not in the compiler's accent table - prints as a raw byte, unlike a compiled message with the same character"
        }
        $out.Add($ch)
    }
    # Comma operator: without it PowerShell unrolls the byte[] into the
    # pipeline and $bytes = Convert-Accents ... ends up an Object[].
    return , $out.ToArray()
}

foreach ($line in ($enc.GetString([IO.File]::ReadAllBytes($In)) -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -match '^\[(\d+)\]') {
        Flush-Para
        $n = [int]$Matches[1]
        if ($n -lt 0 -or $n -gt 255) { Write-Error "topic $n out of range 0-255 in $In"; exit 1 }
        if (-not $topics.ContainsKey($n)) { $topics[$n] = New-Object Collections.Generic.List[string] }
        $current = $n
        continue
    }
    if ($t -eq '') { Flush-Para; continue }
    $para.Add($t)
}
Flush-Para

if ($topics.Count -eq 0) { Write-Error "no topics found in $In - a topic starts with a line like [0]"; exit 1 }
$maxTopic = ($topics.Keys | Measure-Object -Maximum).Maximum
foreach ($k in $topics.Keys) {
    if ($topics[$k].Count -gt 255) { Write-Error "topic $k has $($topics[$k].Count) levels, maximum is 255"; exit 1 }
}

# Lay out: header, directory, level tables, then text.
$dirBytes = 3 * ($maxTopic + 1)
$tableBytes = 0
foreach ($k in $topics.Keys) { $tableBytes += 4 * $topics[$k].Count }
$textStart = 6 + $dirBytes + $tableBytes

$text = New-Object Collections.Generic.List[byte]
$tableAt = @{}
$cursor = 6 + $dirBytes
foreach ($k in ($topics.Keys | Sort-Object)) { $tableAt[$k] = $cursor; $cursor += 4 * $topics[$k].Count }

# Named $buf, not $out: PowerShell variable names are case-insensitive, so
# a local $out here would alias the [string]$Out parameter and get coerced
# back to a string on assignment.
$buf = New-Object byte[] $textStart
[Text.Encoding]::ASCII.GetBytes('HNT').CopyTo($buf, 0)
$buf[3] = 1
$buf[4] = $Seed
$buf[5] = $maxTopic

for ($t = 0; $t -le $maxTopic; $t++) {
    $o = 6 + 3 * $t
    if (-not $topics.ContainsKey($t)) { continue }
    $buf[$o]     = $tableAt[$t] -band 255
    $buf[$o + 1] = ($tableAt[$t] -shr 8) -band 255
    $buf[$o + 2] = $topics[$t].Count
}

foreach ($t in ($topics.Keys | Sort-Object)) {
    $e = $tableAt[$t]
    $lvlNum = 0
    foreach ($level in $topics[$t]) {
        $lvlNum++
        # prn_decoded reads '_' as object-name substitution and bytes below
        # $20 as CLS/wait-key/graphics toggles. Warn, don't fail. Checked
        # against the AUTHOR'S SOURCE bytes, not the packed output -
        # Convert-Accents legitimately emits $0E/$0F triples below.
        if ($level.Contains('_')) {
            Write-Warning "$In topic $t level $lvlNum : contains '_' - prints as an object-name substitution, not a literal underscore"
        }
        foreach ($by in $enc.GetBytes($level)) {
            if ($by -lt 0x20) {
                Write-Warning "$In topic $t level $lvlNum : contains control byte 0x$($by.ToString('X2')) - SVC_PUTCHAR reads bytes below `$20 as CLS/wait-key/graphics toggles"
                break
            }
        }
        $bytes = Convert-Accents $level $In $t $lvlNum
        $at = $textStart + $text.Count
        $buf[$e]     = $at -band 255
        $buf[$e + 1] = ($at -shr 8) -band 255
        $buf[$e + 2] = $bytes.Length -band 255
        $buf[$e + 3] = ($bytes.Length -shr 8) -band 255
        $text.AddRange($bytes)
        $e += 4
    }
}

$all = New-Object byte[] ($buf.Length + $text.Count)
$buf.CopyTo($all, 0)
$text.CopyTo($all, $buf.Length)
if ($all.Length -gt 65535) { Write-Error "packed hint file is $($all.Length) bytes, maximum is 65535"; exit 1 }

# Obfuscate from offset 6 on. S(i) = (i*167+89) AND 255 is a permutation
# because 167 is coprime with 256; hints.asm walks it as a running +167.
for ($o = 6; $o -lt $all.Length; $o++) {
    $s = ((($o -band 255) * 167) + 89) -band 255
    $all[$o] = $all[$o] -bxor $s -bxor (($o -shr 8) -band 255) -bxor $Seed
}

[IO.File]::WriteAllBytes($Out, $all)
Write-Output "$Out written: $($all.Length) bytes, $($topics.Count) topics, seed $Seed"
# $LASTEXITCODE stays $null after a .ps1 that runs no native exe; callers
# checking it for success need an explicit 0.
exit 0
