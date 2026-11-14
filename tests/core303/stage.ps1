# Build and stage the CORE303 silicon legs: sd\LEG303A\ (standalone bench), sd\LEG303B\
# (BENCH interpreter + fixture), sd\LEG303C\ (NXB video bench), indexed by sd\LEG303.TXT.

# Legs are assembled under tests\out\core303-stage\ and copied into sd\ only after every
# gate and stamp passed (build-tests.ps1 -NxBench regenerates sd\NXBENCH\ itself).

# -WhatIf lists the plan and builds nothing. -SdRoot replaces sd\ as the leg root (tests).
param([switch]$WhatIf, [string]$SdRoot)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$sdReal = Join-Path $root 'sd'
$sd = if ($SdRoot) { (Resolve-Path -LiteralPath $SdRoot).Path } else { $sdReal }
$work = Join-Path $root 'tests\out\core303-stage'
$legs = 'LEG303A', 'LEG303B', 'LEG303C'

# Raw logs copied back from the card would be emptied by step 7.
$raw = @(Get-ChildItem -Path (Join-Path $sd 'LEG303*') -Directory -ErrorAction SilentlyContinue |
    Get-ChildItem -File | Where-Object { $_.Name -like '*.LOG' -or $_.Name -like 'NXBENCH*.TXT' })
if ($raw) { throw "ingest first: $(($raw | ForEach-Object { "$($_.Directory.Name)\$($_.Name)" }) -join ', ')" }

if ($WhatIf) {
    "STEP 0: refuse (ingest first) if a LEG303 folder holds a .LOG or NXBENCH*.TXT"
    "STEP 1: tests\core303\bench\build.ps1 (no -AllowDirty), copy CORE303.NEX to LEG303A"
    "STEP 2: python tests\check_quiet_decode.py"
    "STEP 2: python tests\check_quiet_decode.py --bench"
    "STEP 3: build.ps1 -Bench, copy nextdaad.nex to LEG303B, compile fixture, stage fixture assets"
    "STEP 4: tests\build-tests.ps1 -NxBench (regenerates sd\NXBENCH\ itself), copy all but nextdaad.nex to LEG303C"
    "STEP 5: build.ps1 -BenchQuiet, copy nextdaad.nex to LEG303C"
    "STEP 6: write GATES.TXT per leg"
    "STEP 7: refuse if any gate failed or any stamp is dirty"
    "WRITE sd\LEG303A\"
    "WRITE sd\LEG303B\"
    "WRITE sd\LEG303C\"
    "WRITE sd\LEG303.TXT"
    "STEP 8: build.ps1 -Release"
    return
}

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    $out = & $cmd *>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE): $($out | Select-Object -Last 5 | Out-String)" }
    $out
}

function Get-Gate([string]$what, [string[]]$checkArgs) {
    $out = & python "$root\tests\check_quiet_decode.py" @checkArgs *>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $line = $out | Where-Object { $_ -match '^(OK|FAIL)\b' } | Select-Object -Last 1
    if ($code -ne 0 -or -not $line -or $line -notmatch '^OK') {
        throw "gate '$what' failed (exit $code): $line"
    }
    $line
}

function Get-SrcStamp {
    $h = git -C $root log -1 --format=%h -- src
    if ($LASTEXITCODE -ne 0 -or -not $h) { throw "no commit touches src\" }
    if (git -C $root status --porcelain -- src) { return "$h-dirty" }
    $h
}

function Test-Stamp([string]$leg, [string]$stamp) {
    if (-not $stamp -or $stamp -match 'dirty|none') { throw "$leg stamp unusable: '$stamp'" }
}

$tracked = 'src', 'tests/core303/bench', 'tests/core303/fixture', 'tests/core303/stage.ps1',
    'tests/check_quiet_decode.py'
if (git -C $root status --porcelain -- @tracked) {
    throw "uncommitted changes under $($tracked -join ', '): commit them first"
}
if (Get-Process CSpect -ErrorAction SilentlyContinue) { throw "CSpect is running - close it first" }

# Scratch assembly area: an exact path under tests\out.
if ((Split-Path -Parent $work) -ne (Join-Path $root 'tests\out')) { throw "bad scratch path $work" }
if (Test-Path -LiteralPath $work) { Get-ChildItem -LiteralPath $work -Force | Remove-Item -Recurse -Force }
foreach ($l in $legs) { New-Item -ItemType Directory -Force (Join-Path $work $l) | Out-Null }
$nexBuild = Join-Path $root 'build\nextdaad.nex'

# 1. standalone bench
$o1 = Invoke-Checked 'standalone bench build' { & "$root\tests\core303\bench\build.ps1" }
$o1
$stampA = ($o1 | Where-Object { $_ -match '^stamp: (\S+)$' } | Select-Object -First 1) -replace '^stamp: ', ''
Test-Stamp 'LEG303A' $stampA
Copy-Item "$root\build\core303\CORE303.NEX" "$work\LEG303A\CORE303.NEX" -Force

# 2. gates
$quiet = Get-Gate 'quiet decode' @()
$bench = Get-Gate 'bench decode' @('--bench')
"quiet_check: $quiet"
"bench_check: $bench"

# 3. BENCH interpreter + fixture
$stampB = Get-SrcStamp
Test-Stamp 'LEG303B' $stampB
Invoke-Checked 'build.ps1 -Bench' { & "$root\build.ps1" -Bench } | Select-Object -Last 3
Copy-Item $nexBuild "$work\LEG303B\NEXTDAAD.NEX" -Force

$ndrc = if ($env:NEXTDAAD_NDRC) { $env:NEXTDAAD_NDRC } else { Join-Path $root 'authoring-kit\lib\ndrc.exe' }
if (-not (Test-Path -LiteralPath $ndrc)) { throw "no ndrc at $ndrc" }
$fix = Join-Path $work 'fixture-build'
New-Item -ItemType Directory -Force $fix | Out-Null
Copy-Item "$PSScriptRoot\fixture\bench.dsf" "$fix\BENCH.DSF" -Force
Push-Location $fix
try {
    Invoke-Checked 'ndrc fixture' { & $ndrc nextdaad EN BENCH.DSF BENCH.DDB -v3 -nxtext } | Select-Object -Last 3
}
finally { Pop-Location }
Copy-Item "$fix\BENCH.DDB" "$work\LEG303B\GAME.DDB" -Force
if (Test-Path "$fix\0.XMB") { Copy-Item "$fix\0.XMB" "$work\LEG303B\0.XMB" -Force }
foreach ($line in Get-Content "$PSScriptRoot\fixture\SOURCES.txt") {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    $p = $line -split '\s+'
    if ($p.Count -ne 3 -or $p[1] -ne '<-') { throw "bad SOURCES.txt line: $line" }
    $src = Join-Path $root ($p[2] -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) { throw "fixture source missing: $($p[2])" }
    Copy-Item $src "$work\LEG303B\$($p[0])" -Force
}
if (Get-ChildItem "$work\LEG303B" | Where-Object { $_.Name -match '^GAME\.(AKY|AYS|SFB)$' }) {
    throw "LEG303B holds GAME.AKY/AYS/SFB"
}

# 4. NXB payloads
Invoke-Checked 'build-tests.ps1 -NxBench' { & "$root\tests\build-tests.ps1" -NxBench } | Select-Object -Last 3
Get-ChildItem -LiteralPath "$sdReal\NXBENCH" -File | Where-Object { $_.Name -ne 'NEXTDAAD.NEX' } |
    ForEach-Object { Copy-Item $_.FullName "$work\LEG303C\$($_.Name)" -Force }

# 5. quiet interpreter
$stampC = Get-SrcStamp
Test-Stamp 'LEG303C' $stampC
Invoke-Checked 'build.ps1 -BenchQuiet' { & "$root\build.ps1" -BenchQuiet } | Select-Object -Last 3
Copy-Item $nexBuild "$work\LEG303C\NEXTDAAD.NEX" -Force

# 6. GATES.TXT from the staged NEX files
$stamps = @{ LEG303A = $stampA; LEG303B = $stampB; LEG303C = $stampC }
$nexName = @{ LEG303A = 'CORE303.NEX'; LEG303B = 'NEXTDAAD.NEX'; LEG303C = 'NEXTDAAD.NEX' }
$built = Get-Date -Format 'yyyy-MM-dd'
foreach ($l in $legs) {
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath "$work\$l\$($nexName[$l])").Hash.ToLower()
    $g = @("stamp: $($stamps[$l])", "built: $built", "quiet_check: $quiet", "bench_check: $bench", "nex_sha256: $sha")
    if ($l -eq 'LEG303B') {
        $g += "ddb_sha256: $((Get-FileHash -Algorithm SHA256 -LiteralPath "$work\$l\GAME.DDB").Hash.ToLower())"
    }
    [IO.File]::WriteAllText("$work\$l\GATES.TXT", (($g -join "`n") + "`n"))
}
$idx = @(
    'LEG303A  CORE303.NEX     standalone bench; writes CORE303.LOG beside itself',
    'LEG303B  NEXTDAAD.NEX    BENCH interpreter, fixture GAME.DDB; writes BENCH303.LOG',
    'LEG303C  NEXTDAAD.NEX    NXB video bench, NXB0-9.BIN payloads',
    'Each folder is complete: copy it to the card root and launch its NEX from inside it.'
)
[IO.File]::WriteAllText("$work\LEG303.TXT", (($idx -join "`n") + "`n"))

# 7. every gate and stamp passed: only now write sd\
foreach ($l in $legs) {
    $dest = Join-Path $sd $l
    if ((Split-Path -Parent $dest) -ne $sd) { throw "bad leg path $dest" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem -LiteralPath $dest -Force | Remove-Item -Recurse -Force
    Copy-Item "$work\$l\*" $dest -Recurse -Force
    "staged sd\$l\ ($((Get-ChildItem $dest | Measure-Object).Count) files)"
}
Copy-Item "$work\LEG303.TXT" "$sd\LEG303.TXT" -Force
"staged sd\LEG303.TXT"

# 8. leave a Release build behind
Invoke-Checked 'build.ps1 -Release' { & "$root\build.ps1" -Release } | Select-Object -Last 2
