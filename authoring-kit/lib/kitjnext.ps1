# kitjnext.ps1 - dot-source after kitplatform.ps1. jNext card helpers: AUTOEXEC.BAS writer and 8.3 names.
if ($null -eq (Get-Variable OnWindows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'kitplatform.ps1') }

# +3DOS BASIC file: 128-byte header then plain-text lines, no tokeniser.
# NextZXOS +3DOS file header, as in the distribution's own .bas files.
function New-AutoexecBas([string]$CardDir, [string]$Nex) {
    $prog = New-Object System.Collections.Generic.List[byte]
    $n = 10
    foreach ($text in ".cd /$CardDir", ".nexload $Nex") {
        $t = [Text.Encoding]::ASCII.GetBytes($text)
        $len = $t.Length + 1
        $prog.Add([byte]($n -shr 8)); $prog.Add([byte]($n -band 255))
        $prog.Add([byte]($len -band 255)); $prog.Add([byte]($len -shr 8))
        $prog.AddRange($t); $prog.Add([byte]13)
        $n += 10
    }
    $plen = $prog.Count
    $total = 128 + $plen
    $h = New-Object byte[] 128
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('PLUS3DOS'), $h, 8)
    $h[8] = 0x1A; $h[9] = 1; $h[10] = 0
    for ($i = 0; $i -lt 4; $i++) { $h[11 + $i] = [byte](($total -shr (8 * $i)) -band 255) }
    $h[15] = 0
    $h[16] = [byte]($plen -band 255); $h[17] = [byte]($plen -shr 8)
    $h[18] = 10; $h[19] = 0
    $h[20] = $h[16]; $h[21] = $h[17]
    $sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $h[$i] }
    $h[127] = [byte]($sum % 256)
    return [byte[]]($h + $prog.ToArray())
}

# 8.3-safe card folder name: upper-case, other chars become X, max 8, never empty.
function Get-JNextCardName([string]$Game) {
    $s = ([regex]::Replace($Game.ToUpperInvariant(), '[^A-Z0-9_-]', 'X'))
    if ($s.Length -gt 8) { $s = $s.Substring(0, 8) }
    if ($s.Length -eq 0) { return 'GAME' }
    return $s
}

# NEX file name .nexload can take from an 8.3 card folder; anything else is staged as RUN.NEX.
function Get-JNextLaunchNex([string]$NexFile) {
    if ($NexFile -match '^[A-Za-z0-9_-]{1,8}\.[Nn][Ee][Xx]$') { return $NexFile.ToUpperInvariant() }
    return 'RUN.NEX'
}
