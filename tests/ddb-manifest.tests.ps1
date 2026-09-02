# Self-test for ddb-manifest.ps1. Uses a scratch tests\out to avoid
# depending on whatever the last harness run left behind.
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path
$tool = Join-Path $here 'ddb-manifest.ps1'
$work = Join-Path $here 'out\manifest-selftest'
$fail = 0

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; "  ok   $Name" }
    catch { $script:fail++; "  FAIL $Name - $_" }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
[System.IO.File]::WriteAllBytes("$work\a.ddb", [byte[]](1, 2, 3))
[System.IO.File]::WriteAllBytes("$work\b.ddb", [byte[]](4, 5, 6))
$man = Join-Path $work 'manifest.txt'

Check 'capture then compare is clean' {
    & $tool -Capture $man -Root $work -All
    if ($LASTEXITCODE -ne 0) { throw "capture exit $LASTEXITCODE" }
    & $tool -Compare $man -Root $work -All
    if ($LASTEXITCODE -ne 0) { throw "compare exit $LASTEXITCODE on unchanged files" }
}

Check 'changed byte is detected' {
    [System.IO.File]::WriteAllBytes("$work\a.ddb", [byte[]](1, 2, 4))
    & $tool -Compare $man -Root $work -All 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "compare passed on a changed file" }
    [System.IO.File]::WriteAllBytes("$work\a.ddb", [byte[]](1, 2, 3))
}

Check 'removed file is detected' {
    Remove-Item "$work\b.ddb"
    & $tool -Compare $man -Root $work -All 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "compare passed on a removed file" }
    [System.IO.File]::WriteAllBytes("$work\b.ddb", [byte[]](4, 5, 6))
}

Check 'added file is detected' {
    [System.IO.File]::WriteAllBytes("$work\c.ddb", [byte[]](7))
    & $tool -Compare $man -Root $work -All 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "compare passed on an added file" }
}

if ($fail) { throw "$fail manifest self-test failure(s)" }
"ddb-manifest self-test: all checks passed"
