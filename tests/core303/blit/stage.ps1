# Build BLT303 and stage its silicon leg: sd\LEGBLT6\ (BLT303.NEX, GATES.TXT), indexed
# in sd\LEGBLT.TXT. The bench writes BLT303.LOG beside itself.
# Ingest after the sitting, with the log left in the folder:
#   python tests\core303\ingest.py sd\LEGBLT6 --board <board> --leg legBLT --date <yyyy-mm-dd>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$leg = Join-Path $root 'sd\LEGBLT6'
$index = Join-Path $root 'sd\LEGBLT.TXT'

if ((Test-Path $leg) -and (Get-ChildItem $leg -Filter *.LOG)) {
    throw 'sd\LEGBLT6 holds a log: ingest it first'
}
$out = & pwsh -NoProfile -File "$PSScriptRoot\build.ps1"
if ($LASTEXITCODE -ne 0) { throw "build.ps1 failed: $($out | Select-Object -Last 6 | Out-String)" }
$stamp = ($out | Select-String '^stamp: (\S+)$').Matches[0].Groups[1].Value
if (-not $stamp -or $stamp.EndsWith('-dirty')) { throw "unusable stamp '$stamp'" }

$nex = Join-Path $root 'build\blt303\BLT303.NEX'
New-Item -ItemType Directory -Force $leg | Out-Null
Copy-Item $nex (Join-Path $leg 'BLT303.NEX') -Force
$sha = (Get-FileHash $nex -Algorithm SHA256).Hash.ToLower()
@(
    "stamp: $stamp"
    "built: $(Get-Date -Format yyyy-MM-dd)"
    'quiet_check: n/a: standalone bench, no interpreter image'
    'bench_check: n/a: standalone bench, no interpreter image'
    "nex_sha256: $sha"
) | Set-Content (Join-Path $leg 'GATES.TXT') -Encoding ascii

$line = 'LEGBLT6  bench    BLT303.NEX: blit timing and pad proof rows; writes BLT303.LOG beside itself'
$text = if (Test-Path $index) { Get-Content $index } else { @() }
$keep = @($text | Where-Object { $_ -notmatch '^LEGBLT6 ' -and $_ -notmatch '^Copy each folder' })
($keep + $line + 'Copy each folder whole to the card and launch the NEX inside it.') |
    Set-Content $index -Encoding ascii
"staged: sd\LEGBLT6 (stamp $stamp), index sd\LEGBLT.TXT"
