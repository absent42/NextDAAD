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
if ($Seed -lt 0) { $Seed = Get-Random -Minimum 1 -Maximum 256 }

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
    foreach ($level in $topics[$t]) {
        $bytes = $enc.GetBytes($level)
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
