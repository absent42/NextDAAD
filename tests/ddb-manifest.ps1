# Byte-identity evidence for the NDRC transition. Captures a hash per
# compiled DDB, then re-checks it after a change that must not move any
# bytes. Passing assertions are not evidence: a fixture can pass on
# different bytes.
[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$Capture,
    [Parameter(Mandatory, ParameterSetName = 'Compare')][string]$Compare,
    [string]$Root,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
trap { "ERROR: $_"; exit 1 }
if (-not $Root) { $Root = Join-Path (Split-Path $PSScriptRoot) 'tests\out' }

# The 26 DDBs the 25 fixture compiles produce (debugflag makes two).
# An explicit list, NOT a *.ddb glob: tests\out also holds DDBs from
# other tooling (corrupt, max64k, max128k, oversize, baseline-036,
# condacts-036) which no build-tests run touches, and hashing those
# would report reassuring "identical" lines that mean nothing.
$FIXTURE_DDBS = @(
    'template.ddb', 'condacts.ddb', 'doallnest.ddb', 'bigddb.ddb',
    'gmodegate.ddb', 'audlad.ddb', 'sfxdi.ddb', 'sfxlong.ddb', 'sfx2.ddb',
    'debugflag.ddb', 'debugflag-debug.ddb', 'l2holes.ddb', 'tmover.ddb',
    'tileslack.ddb', 'fontsw.ddb', 'txt40.ddb', 'accents.ddb', 'palette.ddb',
    'v3probe.ddb', 'extern.ddb', 'rabenstein.ddb', 'urbanupstart.ddb',
    'utotest.ddb', 'utotest_v3.ddb', 'parta.ddb', 'partb.ddb'
)

function Get-Manifest([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { throw "no such directory: $Dir" }
    $names = if ($All) {
        (Get-ChildItem -LiteralPath $Dir -Filter *.ddb -File | ForEach-Object Name)
    }
    else { $FIXTURE_DDBS }
    $names | Sort-Object | ForEach-Object {
        $p = Join-Path $Dir $_
        if (Test-Path -LiteralPath $p) { '{0} {1}' -f (Get-FileHash $p -Algorithm SHA256).Hash, $_ }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Capture') {
    $lines = @(Get-Manifest $Root)
    if ($lines.Count -eq 0) { throw "no fixture DDBs in $Root - run the harness first" }
    $missing = @($FIXTURE_DDBS | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
    if (-not $All -and $missing) { "  note: $($missing.Count) fixture DDB(s) absent, not captured: $($missing -join ', ')" }
    Set-Content -LiteralPath $Capture -Value $lines -Encoding ascii
    "captured $($lines.Count) DDB hashes -> $Capture"
    exit 0
}

if (-not (Test-Path -LiteralPath $Compare)) { throw "no manifest at $Compare" }
$was = @{}
foreach ($l in Get-Content -LiteralPath $Compare) {
    if ($l -match '^(\S+)\s+(.+)$') { $was[$Matches[2]] = $Matches[1] }
}
$now = @{}
foreach ($l in Get-Manifest $Root) {
    if ($l -match '^(\S+)\s+(.+)$') { $now[$Matches[2]] = $Matches[1] }
}
$bad = 0
foreach ($n in ($was.Keys + $now.Keys | Sort-Object -Unique)) {
    if (-not $now.ContainsKey($n)) { "REMOVED $n"; $bad++ }
    elseif (-not $was.ContainsKey($n)) { "ADDED   $n"; $bad++ }
    elseif ($was[$n] -ne $now[$n]) { "CHANGED $n"; $bad++ }
}
if ($bad) { "$bad DDB(s) differ from $Compare"; exit 1 }
"all $($now.Count) DDBs identical to $Compare"
exit 0
