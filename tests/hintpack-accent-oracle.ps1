# Oracle test: hintpack.ps1's accent conversion must produce byte-identical
# output to what authoring-kit\lib\ndrc.exe puts in a compiled DDB message
# for the same Latin-1 text. This is the real parity guarantee - it catches
# any future drift between the packer's ported table and the compiler,
# which a hand-copied table checked only against today's values cannot.
# Run unconditionally by tests\build-tests.ps1, and standalone:
#   pwsh -NoProfile -File tests\hintpack-accent-oracle.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$ndrc = "$root\authoring-kit\lib\ndrc.exe"
$pack = "$root\authoring-kit\lib\hintpack.ps1"
$enc  = [Text.Encoding]::GetEncoding(28591)
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("hintpack-oracle-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
$checks = 0

# ---- test cases: one MTX message / HINTS.TXT topic each, marker letters
# either side so a byte-run mismatch is easy to eyeball. Covers encoding 1
# (bare byte), encoding 2 (triple), the sharp-s direct $7F, the uppercase
# accent and acute triple ranges, and a mixed literal+accent string. ----
# Distinct names throughout - PowerShell variable names are case-
# insensitive, so a lower/upper pair like $nTilde/$NTilde would alias to
# ONE variable (the pitfall hintpack.ps1 itself warns about for $Out/$out).
$lowNTilde = [char]0xF1   # n-tilde,  241 -> CC_DIRECT  $1A
$lowAGrave = [char]0xE0   # a-grave,  224 -> CC_WRAPPED $10 (triple)
$sharpS    = [char]0xDF   # sharp-s,  223 -> CC_DIRECT  $7F
$capAGrave = [char]0xC0   # A-grave,  192 -> CC_WRAPPED $20 (uppercase accent)
$capAAcute = [char]0xC1   # A-acute,  193 -> CC_WRAPPED $7B (uppercase acute)
$capNTilde = [char]0xD1   # N-tilde,  209 -> CC_DIRECT  $1B
$lowEAcute = [char]0xE9   # e-acute,  233 -> CC_DIRECT  $16

$cases = @(
    @{ n = 'encoding1 direct (n-tilde)';         s = "N$($lowNTilde)Z" },
    @{ n = 'encoding2 triple (a-grave)';          s = "A$($lowAGrave)Z" },
    @{ n = 'sharp-s direct';                      s = "S$($sharpS)Z" },
    @{ n = 'uppercase accent triple (A-grave)';   s = "X$($capAGrave)Z" },
    @{ n = 'uppercase acute triple (A-acute)';    s = "X$($capAAcute)Z" },
    @{ n = 'uppercase N-tilde direct';            s = "X$($capNTilde)Z" },
    @{ n = 'mixed literal + accents';             s = "cafe$($lowEAcute) nino$($lowNTilde)o" }
)

# ---- build ORACLE.DSF: minimal 61-entry STX (required), one MTX message
# per case, one object, one location, one process. ----
$stx = 1..61 | ForEach-Object { ' ' }
$stx[8] = "I don't know that verb."
$sb = New-Object Text.StringBuilder
$sb.Append("/CTL`r`n_`r`n/VOC`r`nGO 1 verb`r`n/STX`r`n") | Out-Null
for ($i = 0; $i -lt $stx.Count; $i++) { $sb.Append("/$i `"$($stx[$i])`"`r`n") | Out-Null }
$sb.Append("/MTX`r`n") | Out-Null
for ($i = 0; $i -lt $cases.Count; $i++) { $sb.Append("/$i `"$($cases[$i].s)`"`r`n") | Out-Null }
$sb.Append("/OTX`r`n/0 `"a lamp`"`r`n") | Out-Null
$sb.Append("/LTX`r`n/0 `"`"`r`n/1 `"Start.`"`r`n") | Out-Null
$sb.Append("/CON`r`n/0`r`n/1`r`n") | Out-Null
$sb.Append("/OBJ`r`n/0    1   1   _ _  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _   _ _`r`n") | Out-Null
$sb.Append("/PRO 0`r`n> _ _   AT 0`r`n        MESSAGE 0`r`n        DONE`r`n") | Out-Null
$sb.Append("> _ _     PARSE 0`r`n          REDO`r`n/END`r`n") | Out-Null
[IO.File]::WriteAllBytes("$tmp\ORACLE.DSF", $enc.GetBytes($sb.ToString()))

# ---- build matching HINTS.TXT: topic i, single level = the same text. ----
$hb = New-Object Text.StringBuilder
for ($i = 0; $i -lt $cases.Count; $i++) { $hb.Append("[$i]`r`n$($cases[$i].s)`r`n`r`n") | Out-Null }
[IO.File]::WriteAllBytes("$tmp\HINTS.TXT", $enc.GetBytes($hb.ToString()))

# ---- compile the oracle DSF ----
Push-Location $tmp
try {
    & $ndrc nextdaad EN ORACLE.DSF ORACLE.DDB -v3 -auto-tokens | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ndrc.exe failed compiling the oracle DSF" }
}
finally { Pop-Location }

# ---- pack the matching hints ----
& $pack -In "$tmp\HINTS.TXT" -Out "$tmp\GAME.HNT" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "hintpack.ps1 failed packing the oracle hints" }

# ---- decode a DDB user message: NDRC's ndrc.exe emits FILE-RELATIVE
# pointers (base 0, not the Z80 runtime load address) - measured against
# ORACLE.DDB directly (tests\decode-ddb.ps1's 0x8400 base is for the
# upstream DRC/DRB toolchain's output, not ndrc.exe's). Message bytes are
# stored complemented (byte = 255 - char); bytes >=128 after complementing
# select a compression token, expanded from the token table at W(8). ----
function Get-DdbMessageBytes([byte[]]$b, [int]$number) {
    function W($o) { $b[$o] + 256 * $b[$o + 1] }
    $tableOff = 0x10   # user messages (MTX)
    $entries = @(); $p = (W 8)
    while ($entries.Count -lt 129) {
        $s = New-Object Collections.Generic.List[byte]
        while ($true) {
            $ch = $b[$p]; $p++
            $s.Add([byte]($ch -band 0x7F))
            if ($ch -band 0x80) { break }
        }
        $entries += , ([byte[]]$s.ToArray())
    }
    $msgPtr = W ((W $tableOff) + 2 * $number)
    $out = New-Object Collections.Generic.List[byte]
    $p = $msgPtr
    while ($true) {
        $c = 255 - $b[$p]; $p++
        if ($c -eq 0x0A) { break }
        if ($c -ge 128) { $out.AddRange([byte[]]$entries[($c -band 0x7F) + 1]); continue }
        $out.Add([byte]$c)
    }
    return , $out.ToArray()
}

# ---- decode a packed GAME.HNT topic/level: same deobfuscation as
# hintpack-selftest.ps1. ----
function Key([int]$offset, [int]$seed) {
    $s = ((($offset -band 255) * 167) + 89) -band 255
    return $s -bxor (($offset -shr 8) -band 255) -bxor $seed
}
function Get-HntLevelBytes([byte[]]$p, [int]$seed, [int]$topic, [int]$level) {
    $o = 6 + 3 * $topic
    $dirOff = $p[$o] + 256 * $p[$o + 1]
    $e = $dirOff + 4 * $level
    $to = $p[$e] + 256 * $p[$e + 1]
    $tl = $p[$e + 2] + 256 * $p[$e + 3]
    if ($tl -eq 0) { return , ([byte[]]@()) }
    return , $p[$to..($to + $tl - 1)]
}

$ddbBytes = [IO.File]::ReadAllBytes("$tmp\ORACLE.DDB")
$hntRaw = [IO.File]::ReadAllBytes("$tmp\GAME.HNT")
$seed = $hntRaw[4]
$hntPlain = $hntRaw.Clone()
for ($o = 6; $o -lt $hntPlain.Length; $o++) { $hntPlain[$o] = $hntPlain[$o] -bxor (Key $o $seed) }

for ($i = 0; $i -lt $cases.Count; $i++) {
    $fromDdb = Get-DdbMessageBytes $ddbBytes $i
    $fromHnt = Get-HntLevelBytes $hntPlain $seed $i 0
    $ddbHex = ($fromDdb | ForEach-Object { $_.ToString('X2') }) -join ' '
    $hntHex = ($fromHnt | ForEach-Object { $_.ToString('X2') }) -join ' '
    "$($cases[$i].n): ddb=[$ddbHex] hnt=[$hntHex]"
    if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$fromDdb, [byte[]]$fromHnt)) {
        throw "oracle mismatch: '$($cases[$i].n)' - hintpack produced [$hntHex], ndrc.exe compiled [$ddbHex]"
    }
    $checks++
}

Remove-Item $tmp -Recurse -Force
Write-Output "hintpack accent oracle: $checks checks passed, all byte-identical to ndrc.exe"
