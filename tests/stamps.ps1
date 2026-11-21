# stamps.ps1 - dot-source. Thin PowerShell wrapper over tests\stamps.py, the one stamp
# implementation (format, fingerprint and stamp files live there only).
$script:StampsPy = Join-Path $PSScriptRoot 'stamps.py'

# Checks every step in $Steps (name -> spec hashtable, see tests\stamps.py) in one python
# call. Returns name -> @{ Fresh; State; Info }; a stale step gets a pending stamp for
# Complete-Stamp. -Plan writes nothing and adds the RESTORE and PENDING states.
function Invoke-StampCheck([string]$Root, [System.Collections.IDictionary]$Steps, [switch]$Full, [switch]$Plan) {
    $dir = Join-Path $Root 'tests\out\stamps'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir "spec-$PID.json"
    $json = @{ root = $Root; steps = $Steps } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($file, $json)
    $pyArgs = @($script:StampsPy, 'check', $file)
    if ($Full) { $pyArgs += '--full' }
    if ($Plan) { $pyArgs += '--plan' }
    $lines = & python @pyArgs
    $rc = $LASTEXITCODE
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    if ($rc -ne 0) { throw "tests\stamps.py check failed (exit $rc)" }
    $res = @{}
    foreach ($l in @($lines)) {
        $p = "$l" -split "`t", 3
        if ($p.Count -eq 3) { $res[$p[1]] = @{ Fresh = ($p[0] -in 'FRESH', 'RESTORE'); State = $p[0]; Info = $p[2] } }
    }
    foreach ($n in $Steps.Keys) { if (-not $res.ContainsKey($n)) { throw "tests\stamps.py check gave no answer for $n" } }
    return $res
}

# Records the named steps as passed (after they ran clean).
function Complete-Stamp([string]$Root, [string[]]$Names) {
    & python $script:StampsPy pass --root $Root @Names
    if ($LASTEXITCODE -ne 0) { throw "tests\stamps.py pass $($Names -join ' ') failed (exit $LASTEXITCODE)" }
}
