# Builds DBGFIX.DDB with ndrc -d, asserts the stimulus bytes, and writes
# DBGFIX.DSM by pairing each DDB condact with its DSF line (one per line).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path "$here\..\..\..").Path
$ndrc = if ($env:NEXTDAAD_NDRC) { $env:NEXTDAAD_NDRC } else { Join-Path $repo 'authoring-kit\lib\ndrc.exe' }
$work = Join-Path $repo 'tests\out\dbgfix'
$outRoot = [IO.Path]::GetFullPath((Join-Path $repo 'tests\out')).TrimEnd('\') + '\'
if (-not [IO.Path]::GetFullPath($work).StartsWith($outRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "refusing to clear $work" }
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item "$here\DBGFIX.DSF" $work
Push-Location $work
try { & $ndrc nextdaad EN DBGFIX.DSF DBGFIX.DDB -v3 -d; if ($LASTEXITCODE) { throw 'ndrc failed' } }
finally { Pop-Location }

$b = [IO.File]::ReadAllBytes("$work\DBGFIX.DDB")
function W([int]$o) { [int]$b[$o] + 256 * [int]$b[$o + 1] }
function Has([int[]]$seq) {
    for ($i = 0; $i -le $b.Length - $seq.Count; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $seq.Count; $j++) { if ($b[$i + $j] -ne $seq[$j]) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}
if ($b[0] -ne 3 -or ($b[1] -shr 4) -ne 0x0C -or $b[2] -ne 95) { throw 'DBGFIX.DDB is not a NextDAAD v3 database' }
if (-not (Has @(0x33, 100, 7))) { throw 'LET fCounter 7 did not compile to 33 64 07' }
if (-not (Has @(0xB3, 100, 3))) { throw 'LET @100 3 did not compile to B3 64 03' }
if (-not (Has @(0xDC, 0x4B, 1))) { throw 'DEBUG marker DC not kept before PROCESS 1 (4B 01) - was -d honoured?' }

# argc per condact = cprops bits 0-1 (src/engine.asm); fixture walker only
$argc = @(1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2, 1,1,2,1,0,0,0,0,0,1,1,1,1,0,0,0, 0,0,0,1,2,1,1,1,1,1,1,1,1,2,2,1, 1,2,2,2,0,1,1,2,1,0,1,1,0,2,0,1,
          2,1,1,1,1,1,1,2,2,1,1,1,2,1,1,2, 2,1,2,2,1,1,2,2,2,2,2,2,0,2,1,1, 2,0,0,2,0,2,1,0,1,1,1,2,0,0,1,0, 2,2,0,0,1,0,1,2,2,2,1,2,2,2,2,0)
if ($argc.Count -ne 128) { throw "argc table has $($argc.Count) rows" }
$term = @(22, 23, 103, 116, 117, 108)

# DSF: per process, per entry: header line and condact (line, col) list
$lines = [IO.File]::ReadAllLines("$here\DBGFIX.DSF")
$procs = @{}; $proc = -1; $entry = $null; $procLine = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    $t = $lines[$i]
    if ($t -match '^/PRO\s+(\d+)') { $proc = [int]$Matches[1]; $procs[$proc] = New-Object System.Collections.ArrayList; $procLine[$proc] = $i + 1; $entry = $null; continue }
    if ($t -match '^/') { $proc = -1; continue }
    if ($proc -lt 0) { continue }
    if ($t -match '^>\s*\S+\s+\S+\s+') {
        $entry = @{ Line = $i + 1; Conds = New-Object System.Collections.ArrayList }
        [void]$procs[$proc].Add($entry)
        [void]$entry.Conds.Add(@{ Line = $i + 1; Col = $Matches[0].Length + 1 })
        continue
    }
    if ($entry -and $t -match '^(\s+)\S' -and $t.Trim()[0] -ne ';') { [void]$entry.Conds.Add(@{ Line = $i + 1; Col = $Matches[1].Length + 1 }) }
}

Add-Type -TypeDefinition @'
public static class FixCrc {
    public static uint Compute(byte[] d) {
        uint c = 0xFFFFFFFFu;
        foreach (byte x in d) { c ^= x; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; }
        return ~c;
    }
}
'@

$out = New-Object Text.StringBuilder
[void]$out.Append("NDRC-DSM`t1`n")
[void]$out.Append(("ddb`t{0:X8}`t{1:X}`n" -f [FixCrc]::Compute($b), $b.Length))
[void]$out.Append("file`t0`tDBGFIX.DSF`n")
$procList = W 10
$seen = @{}
for ($p = 0; $p -lt $b[7]; $p++) {
    [void]$out.Append("proc`t$p`t0`t$($procLine[$p])`n")
    $e = W ($procList + 2 * $p); $k = 0
    while ($b[$e] -ne 0) {
        $src = $procs[$p][$k]
        [void]$out.Append(("entry`t{0:X4}`t0`t{1}`n" -f $e, $src.Line))
        $c = W ($e + 2); $n = 0
        while ($true) {
            $raw = $b[$c]
            if ($raw -eq 0xFF) { break }
            if ($n -ge $src.Conds.Count) { throw "PRO $p entry $k has more DDB condacts than DSF lines" }
            $sl = $src.Conds[$n]
            if ($seen.ContainsKey($c)) { throw ("DDB offset {0:X4} has two cond records: lines {1} and {2} (DRB tail sharing)" -f $c, $seen[$c], $sl.Line) }
            $seen[$c] = $sl.Line
            [void]$out.Append(("cond`t{0:X4}`t0`t{1}`t{2}`n" -f $c, $sl.Line, $sl.Col))
            $n++
            if ($raw -eq 0xDC) { $c++; continue }
            $c += 1 + $argc[$raw -band 0x7F]
            if ($term -contains [int]$raw) { break }
        }
        if ($n -ne $src.Conds.Count) { throw "PRO $p entry $k has $n DDB condacts, $($src.Conds.Count) DSF lines" }
        $e += 4; $k++
    }
}
[void]$out.Append("sym`tfCounter`t100`n")
Copy-Item "$work\DBGFIX.DDB" "$here\DBGFIX.DDB" -Force
[IO.File]::WriteAllText("$here\DBGFIX.DSM", $out.ToString(), (New-Object Text.UTF8Encoding $false))
"wrote DBGFIX.DDB ($($b.Length) bytes) and DBGFIX.DSM"
