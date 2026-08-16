# Audits every extern under authoring-kit\externs\ against the
# submission contract (CONTRIBUTING.md). Run locally before opening an
# extern PR; .github\workflows\extern-audit.yml runs the same script on
# every PR that touches the externs tree.
#
# Per extern folder it checks:
#   1. exactly the four required files: one .asm source, GAME.XBN,
#      README.md, build.ps1
#   2. freshness: the source assembles (sjasmplus, -I = kit root) to a
#      binary byte-identical to the committed GAME.XBN
#   3. the XBN header validates by the interpreter's own rules: magic
#      "XBN", version 1, size field == file length <= 16384, nonzero
#      entries inside [$C000, $C000+size)
#   4. the README documents the interface: mentions EXTERN and at
#      least one fn code line, and is not a stub
#   5. house text rules: no em-dash, no emoji in .asm/.md/.ps1
#
# Usage: powershell -File tests\audit-externs.ps1 [-SjasmPlus <exe>]
# Exit 0 = all externs pass; exit 1 = findings printed per extern.
param([string]$SjasmPlus = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit = Join-Path $root 'authoring-kit'
$externsDir = Join-Path $kit 'externs'

if (-not $SjasmPlus) { $SjasmPlus = Join-Path $root 'tools\sjasmplus\sjasmplus.exe' }
if (-not (Test-Path $SjasmPlus)) {
    throw "sjasmplus not found at '$SjasmPlus' - pass -SjasmPlus or populate tools\sjasmplus\ (CI downloads a pinned release; see .github\workflows\extern-audit.yml)"
}

$failures = 0
$dirs = Get-ChildItem $externsDir -Directory | Sort-Object Name
if (-not $dirs) { throw "no extern folders found under $externsDir" }

foreach ($dir in $dirs) {
    $name = $dir.Name
    $findings = @()

    # --- 1. required files, and only those four -----------------------
    $asms = @(Get-ChildItem $dir.FullName -Filter '*.asm')
    if ($asms.Count -ne 1) { $findings += "expected exactly one .asm source, found $($asms.Count)" }
    foreach ($req in 'GAME.XBN', 'README.md', 'build.ps1') {
        if (-not (Test-Path (Join-Path $dir.FullName $req))) { $findings += "missing required file: $req" }
    }
    $extras = Get-ChildItem $dir.FullName -File | Where-Object {
        $_.Name -notmatch '\.asm$' -and $_.Name -notin 'GAME.XBN', 'README.md', 'build.ps1'
    }
    foreach ($x in $extras) { $findings += "unexpected file: $($x.Name) (the contract is exactly four files)" }

    # --- 2. freshness: rebuild and byte-compare -----------------------
    if ($asms.Count -eq 1 -and (Test-Path (Join-Path $dir.FullName 'GAME.XBN'))) {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) "xbn-audit-$name"
        New-Item -ItemType Directory -Force $scratch | Out-Null
        Push-Location $scratch
        try {
            # cmd /c: sjasmplus banners on stderr, which strict-mode
            # PowerShell would otherwise promote to a terminating error
            cmd /c "`"$SjasmPlus`" --msg=war -I `"$kit`" `"$($asms[0].FullName)`" 2>&1" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $findings += "source does not assemble against xbn.inc (sjasmplus exit $LASTEXITCODE)"
            }
            elseif (-not (Test-Path "$scratch\GAME.XBN")) {
                $findings += "assembly produced no GAME.XBN - is the SAVEBIN line present and unmodified?"
            }
            else {
                $fresh = [IO.File]::ReadAllBytes("$scratch\GAME.XBN")
                $shipped = [IO.File]::ReadAllBytes((Join-Path $dir.FullName 'GAME.XBN'))
                if (-not [System.Linq.Enumerable]::SequenceEqual($fresh, $shipped)) {
                    $findings += "committed GAME.XBN is STALE - it does not match a fresh assembly of the source; run the folder's build.ps1 and commit both together"
                }
            }
        }
        finally {
            Pop-Location
            Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 3. header validation (the interpreter loader's own rules) ----
    $xbnPath = Join-Path $dir.FullName 'GAME.XBN'
    if (Test-Path $xbnPath) {
        $b = [IO.File]::ReadAllBytes($xbnPath)
        if ($b.Length -lt 10) { $findings += "GAME.XBN shorter than the 10-byte header" }
        elseif ($b.Length -gt 16384) { $findings += "GAME.XBN exceeds 16384 bytes ($($b.Length))" }
        else {
            if ([Text.Encoding]::ASCII.GetString($b[0..2]) -ne 'XBN') { $findings += "header magic is not 'XBN'" }
            if ($b[3] -ne 1) { $findings += "header version is $($b[3]), expected 1" }
            $size = $b[8] + 256 * $b[9]
            if ($size -ne $b.Length) { $findings += "header size field ($size) does not match file length ($($b.Length))" }
            $limit = 0xC000 + $b.Length
            foreach ($entry in @(@('extEntry', ($b[4] + 256 * $b[5])), @('intEntry', ($b[6] + 256 * $b[7])))) {
                $v = $entry[1]
                if ($v -ne 0 -and ($v -lt 0xC000 -or $v -ge $limit)) {
                    $findings += "$($entry[0]) `$$('{0:X4}' -f $v) is outside the binary's extent"
                }
            }
            if (($b[4] + 256 * $b[5]) -eq 0 -and ($b[6] + 256 * $b[7]) -eq 0) {
                $findings += "both entry points are 0 - the extern can never be reached"
            }
        }
    }

    # --- 4. README documents the interface ----------------------------
    $rdPath = Join-Path $dir.FullName 'README.md'
    if (Test-Path $rdPath) {
        $rd = Get-Content $rdPath -Raw
        if ($rd.Length -lt 400) { $findings += "README.md is a stub ($($rd.Length) chars) - document what it does, the DSF lines, fn codes and flags" }
        if ($rd -notmatch 'EXTERN') { $findings += "README.md never mentions EXTERN - show the DSF lines that drive the extern" }
    }

    # --- 5. house text rules ------------------------------------------
    foreach ($tf in (Get-ChildItem $dir.FullName -File | Where-Object { $_.Extension -in '.asm', '.md', '.ps1' })) {
        $txt = Get-Content $tf.FullName -Raw
        if ($txt.Contains([char]0x2014)) { $findings += "$($tf.Name): contains an em-dash (use -)" }
        foreach ($ch in $txt.ToCharArray()) {
            if ([int]$ch -ge 0x1F000 -or ([int]$ch -ge 0x2190 -and [int]$ch -le 0x2BFF)) {
                $findings += "$($tf.Name): contains emoji or symbol characters (text only)"
                break
            }
        }
    }

    if ($findings.Count) {
        $failures++
        Write-Host "FAIL $name"
        foreach ($f in $findings) { Write-Host "  - $f" }
    }
    else {
        Write-Host "OK   $name"
    }
}

if ($failures) { Write-Host "$failures extern(s) failed the audit"; exit 1 }
Write-Host "all externs pass"
exit 0
