# Header rules of tests\audit-externs.ps1 against crafted GAME.XBN files,
# mirroring the interpreter loader (src/overlay0.asm, xbn validation).
# Run by tests\build-tests.ps1 and standalone:
#   pwsh -NoProfile -File tests\audit-externs-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$sj   = "$root\tools\sjasmplus\sjasmplus.exe"
$work = "$root\tests\out\audit-selftest"
$checks = 0

# 14-byte header + padding to $len; entries are absolute addresses.
function New-Xbn([string]$name, [int]$ver, [int]$ext, [int]$int, [int]$line, [int]$out, [int]$len = 64) {
    $b = New-Object byte[] $len
    [Text.Encoding]::ASCII.GetBytes('XBN').CopyTo($b, 0)
    $b[3] = $ver
    $i = 4
    foreach ($w in $ext, $int, $len, $line, $out) { $b[$i] = $w -band 0xFF; $b[$i + 1] = ($w -shr 8) -band 0xFF; $i += 2 }
    New-Item -ItemType Directory -Force "$work\$name" | Out-Null
    [IO.File]::WriteAllBytes("$work\$name\GAME.XBN", $b)
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Xbn 'v2ok'      2 0xC00E 0xC010 0 0
New-Xbn 'v2rsv'     2 0xC00E 0xC010 0xC012 0
New-Xbn 'v3line'    3 0xC00E 0xC010 0xC012 0
New-Xbn 'v3out'     3 0xC00E 0xC010 0 0xC012
New-Xbn 'v3linebad' 3 0xC00E 0xC010 0xC040 0
New-Xbn 'v3outlow'  3 0xC00E 0xC010 0 0xBFFF
New-Xbn 'v3hookonly' 3 0 0 0xC012 0
New-Xbn 'v3none'    3 0 0 0 0
New-Xbn 'v4'        4 0xC00E 0xC010 0 0
New-Xbn 'full'      3 0xC00E 0xC010 0 0xFFFF 16384

$text = (& powershell -NoProfile -File "$root\tests\audit-externs.ps1" -SjasmPlus $sj -ExternsDir $work 2>&1 | ForEach-Object { "$_" }) -join "`n"
$found = @{}
$cur = $null
foreach ($l in $text -split "`n") {
    if ($l -match '^(FAIL|OK)\s+(\S+)') { $cur = $Matches[2]; $found[$cur] = @() }
    elseif ($cur -and $l -match '^\s+- (.*)$') { $found[$cur] += $Matches[1] }
}
# Header findings only: the crafted folders have no source, README or build.ps1.
function Header-Findings([string]$name) {
    @($found[$name] | Where-Object { $_ -match 'header|Entry|entry points|bytes 10-13' })
}
function Assert-Header([string]$name, [string[]]$expected) {
    $script:checks++
    if (-not $found.ContainsKey($name)) { throw "audit-externs-selftest: $name not audited:`n$text" }
    $got = Header-Findings $name
    if (($got -join '|') -ne ($expected -join '|')) {
        throw "audit-externs-selftest: $name - header findings '$($got -join ' | ')', expected '$($expected -join ' | ')'"
    }
}

Assert-Header 'v2ok' @()
Assert-Header 'v2rsv' @('format 2 reserved header bytes 10-13 must be zero')
Assert-Header 'v3line' @()
Assert-Header 'v3out' @()
Assert-Header 'v3linebad' @('lineEntry $C040 is outside the binary''s extent')
Assert-Header 'v3outlow' @('outEntry $BFFF is outside the binary''s extent')
Assert-Header 'v3hookonly' @()
Assert-Header 'v3none' @('every entry point is 0 - the extern can never be reached')
Assert-Header 'v4' @('header version is 4, expected 2 or 3')
Assert-Header 'full' @('outEntry $FFFF is outside the binary''s extent')

Write-Output "audit-externs-selftest: $checks checks passed"
