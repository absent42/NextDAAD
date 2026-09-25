# Assertions over authoring-kit\lib\xbnbuild.ps1 (EXTERNS.BAT's builder)
# and xbnmod.inc's claim macros. Run by tests\build-tests.ps1 and
# standalone:
#   pwsh -NoProfile -File tests\xbnbuild-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit  = "$root\authoring-kit"
$xb   = "$kit\lib\xbnbuild.ps1"
$sj   = "$root\tools\sjasmplus\sjasmplus.exe"
$fix  = "$root\tests\xbn\usermods"
$work = "$root\tests\out\xbnbuild"
$checks = 0
if (-not (Test-Path $sj)) { throw "xbnbuild-selftest: sjasmplus not found at $sj" }

# Collection claims end here (xbnmod.inc): XBN_SCRATCH_FREE = 768 +
# TRANSCRIPT_RING (2048), XBN_STATE_FREE = 10. Re-pin if either moves.
$scrBase = 2816
$stBase = 10

function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ($actual -ne $expected) { throw "xbnbuild-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Match([string]$text, [string]$pattern, $what) {
    $script:checks++
    if ($text -notmatch $pattern) { throw "xbnbuild-selftest: $what - output did not match '$pattern':`n$text" }
}
# Native tools write to stderr; keep that from terminating under Stop.
# "$_" per record: Out-String wraps 5.1's stderr records at console width.
function Invoke-Native([scriptblock]$sb) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $sb 2>&1 | ForEach-Object { "$_" }) -join "`n") } finally { $ErrorActionPreference = $old }
}
function Header([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    [pscustomobject]@{
        Format = [int]$b[3]
        Line   = [int]$b[10] -bor ([int]$b[11] -shl 8)
        Out    = [int]$b[12] -bor ([int]$b[13] -shl 8)
    }
}
# Assembles one fixture on its own (its IFNDEF XBN_MODULE branch).
function Build-Standalone([string]$module) {
    $dir = "$work\standalone\$module"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try { $text = Invoke-Native { & $sj --msg=war -I "$kit" "$fix\$module\$module.asm" } }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "xbnbuild-selftest: standalone $module failed:`n$text" }
    $script:checks++
    [pscustomobject]@{ Text = $text; Header = (Header "$dir\GAME.XBN") }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

# Standalone: XBN_CLAIMS starts a module's claims where the collection's end.
$ua = Build-Standalone 'ua'
Assert-Match $ua.Text "standalone ua scratch \+$scrBase state \+$stBase" 'standalone ua claim offsets'
Assert-Eq $ua.Header.Format 3 'standalone ua header format'
Assert-Eq ($ua.Header.Line -ne 0) $true 'standalone ua lineEntry'
Assert-Eq $ua.Header.Out 0 'standalone ua outEntry'
$ub = Build-Standalone 'ub'
Assert-Eq $ub.Header.Format 2 'standalone ub header format'
$uo = Build-Standalone 'uo'
Assert-Eq $uo.Header.Format 3 'standalone uo header format'
Assert-Eq $uo.Header.Line 0 'standalone uo lineEntry'
Assert-Eq ($uo.Header.Out -ne 0) $true 'standalone uo outEntry'

# ---- Generated builds (xbnbuild.ps1) ----
# Runs the builder in a child Windows PowerShell, as EXTERNS.BAT does.
function Invoke-Build([string[]]$argv) {
    $text = Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $xb @argv -SjasmPlus $sj }
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function Build-Ok([string]$what, [string[]]$argv) {
    $r = Invoke-Build $argv
    $script:checks++
    if ($r.Code -ne 0) { throw "xbnbuild-selftest: $what - exit $($r.Code):`n$($r.Text)" }
    $r.Text
}
function Build-Fails([string]$what, [string[]]$argv, [string]$pattern) {
    $r = Invoke-Build $argv
    $script:checks++
    if ($r.Code -eq 0) { throw "xbnbuild-selftest: $what - built, expected a failure" }
    Assert-Match $r.Text $pattern $what
}
function New-Module([string]$parent, [string]$name, [string]$body) {
    New-Item -ItemType Directory -Force "$parent\$name" | Out-Null
    [IO.File]::WriteAllText("$parent\$name\$name.asm", $body, [Text.Encoding]::ASCII)
}
function Same-Bytes([string]$a, [string]$b) {
    [System.Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($a), [IO.File]::ReadAllBytes($b))
}
$o = "$work\gen"
$neg = "$work\mods"
New-Item -ItemType Directory -Force $o, $neg | Out-Null

# Header shapes: line only, none, out only. Both-set is the drift guard's.
$t = Build-Ok 'toolkit + ua' @('toolkit', "$fix\ua", '-Out', "$o\a.xbn")
$h = Header "$o\a.xbn"
Assert-Eq $h.Format 3 'toolkit+ua format'
Assert-Eq ($h.Line -ne 0) $true 'toolkit+ua lineEntry'
Assert-Eq $h.Out 0 'toolkit+ua outEntry'
Assert-Match $t "claim ua scratch \+$scrBase \(300\), state \+$stBase \(4\)" 'toolkit+ua claims'
Build-Ok 'ub alone' @("$fix\ub", '-Out', "$o\b.xbn") | Out-Null
Assert-Eq (Header "$o\b.xbn").Format 2 'ub format'
Build-Ok 'uo alone' @("$fix\uo", '-Out', "$o\o.xbn") | Out-Null
$h = Header "$o\o.xbn"
Assert-Eq $h.Format 3 'uo format'
Assert-Eq $h.Line 0 'uo lineEntry'
Assert-Eq ($h.Out -ne 0) $true 'uo outEntry'

# Claim chain follows argument order.
$t = Build-Ok 'ua ub' @("$fix\ua", "$fix\ub", '-Out', "$o\ab.xbn")
Assert-Match $t "claim ub scratch \+$($scrBase + 300) \(0\), state \+$($stBase + 4) \(2\)" 'ua ub: ub placed after ua'
$t = Build-Ok 'ub ua' @("$fix\ub", "$fix\ua", '-Out', "$o\ba.xbn")
Assert-Match $t "claim ub scratch \+$scrBase \(0\), state \+$stBase \(2\)" 'ub ua: ub first'
Assert-Match $t "claim ua scratch \+$scrBase \(300\), state \+$($stBase + 2) \(4\)" 'ub ua: ua after ub'

# Relative paths resolve against -BaseDir, not the kit root.
$t = Build-Ok 'relative path' @('xbn\usermods\ua', '-BaseDir', "$root\tests", '-Out', "$o\rel.xbn")
Assert-Match $t 'claim ua scratch' 'relative path build'

# Review focus: a space in the path, a trailing separator, a bare name in
# another case, a path to the kit's own module folder.
New-Item -ItemType Directory -Force "$work\with space" | Out-Null
Copy-Item "$fix\ua" "$work\with space\ua" -Recurse
Build-Ok 'space in path' @("$work\with space\ua", '-Out', "$o\sp.xbn") | Out-Null
Build-Ok 'trailing separator' @("$fix\ua\", '-Out', "$o\ts.xbn") | Out-Null
Assert-Eq (Same-Bytes "$o\ts.xbn" "$o\sp.xbn") $true 'trailing separator builds ua'
Build-Ok 'bare fade' @('fade', '-Out', "$o\fbare.xbn") | Out-Null
Build-Ok 'bare name, other case' @('Fade', '-Out', "$o\fcase.xbn") | Out-Null
Assert-Eq (Same-Bytes "$o\fcase.xbn" "$o\fbare.xbn") $true 'Fade builds the shipped fade'
Build-Ok 'kit folder by path' @("$kit\externs\fade", '-Out', "$o\fpath.xbn") | Out-Null
Assert-Eq (Same-Bytes "$o\fpath.xbn" "$o\fbare.xbn") $true 'externs\fade by path builds the shipped fade'

# The MODULE line names the module; the folder, or the path as typed,
# may differ in case.
New-Module $neg 'Mixed' "    MODULE mixed`nSTATE_SIZE equ 1`next:`n    or a`n    ret`nint:`n    ret`n    ENDMODULE`n"
$t = Build-Ok 'path case differs from MODULE' @("$neg\MIXED", '-Out', "$o\mixed.xbn")
Assert-Match $t 'claim mixed scratch' 'MODULE spelling used for the module name'

# The scan accepts what sjasmplus accepts: colon-less column-0 labels,
# '=' equates, a comment on the MODULE line.
New-Module $neg 'spell' "    MODULE spell ; a trailing comment`nSCRATCH_SIZE = 8`next`n    or a`n    ret`nint ret`nline`n    or a`n    ret`n    ENDMODULE`n"
$t = Build-Ok 'colon-less labels, = equate' @("$neg\spell", '-Out', "$o\spell.xbn")
Assert-Eq ((Header "$o\spell.xbn").Line -ne 0) $true 'colon-less line label wired'
Assert-Match $t 'claim spell scratch \+\d+ \(8\)' '= equate claimed'

# Refusals: one xbnbuild: line, exit 1, nothing assembled.
New-Module $neg 'noint' "    MODULE noint`next:`n    or a`n    ret`n    ENDMODULE`n"
New-Module $neg 'nomod' "ext:`n    ret`nint:`n    ret`n"
New-Module $neg 'indent' "    MODULE indent`next:`n    ret`nint:`n    ret`n`tline:`n    ret`n    ENDMODULE`n"
New-Module $neg 'toolkit' "    MODULE toolkit`next:`n    ret`nint:`n    ret`n    ENDMODULE`n"
New-Module $neg 'bad-name' "    MODULE x`n"
New-Module $neg 'bigst' "    MODULE bigst`nSTATE_SIZE equ 200`next:`n    ret`nint:`n    ret`n    ENDMODULE`n"
New-Module $neg 'bigscr' "    MODULE bigscr`nSCRATCH_SIZE equ 14000`next:`n    ret`nint:`n    ret`n    ENDMODULE`n"
$x = "$o\neg.xbn"
Build-Fails 'no int label' @("$neg\noint", '-Out', $x) "xbnbuild: module 'noint': no 'int:' label"
Build-Fails 'no MODULE block' @("$neg\nomod", '-Out', $x) 'has no MODULE nomod block'
Build-Fails 'indented entry label' @("$neg\indent", '-Out', $x) "entry label 'line' must start at column 0"
Build-Fails 'shipped name by path' @("$neg\toolkit", '-Out', $x) 'taken by externs\\toolkit'
Build-Fails 'invalid name' @("$neg\bad-name", '-Out', $x) 'a name is a letter'
Build-Fails 'bare all' @('all', '-Out', $x) "'all' is the prebuilt collection"
Build-Fails 'unknown bare name' @('nosuch', '-Out', $x) "unknown module 'nosuch' - known: .*toolkit"
Build-Fails 'missing path' @("$neg\nothere", '-Out', $x) 'no nothere\.asm in'
Build-Fails 'duplicate by path' @("$fix\ua", "$fix\UA", '-Out', $x) 'is named twice'
Build-Fails 'duplicate bare' @('fade', 'FADE', '-Out', $x) 'is named twice'
Build-Fails 'state overflow' @("$neg\bigst", '-Out', $x) 'extern state claim runs past XBN_STATE_LEN'
Build-Fails 'scratch overflow' @("$neg\bigscr", '-Out', $x) 'scratch claim runs past the mapped 16K bank'
Build-Fails 'usage' @() 'Usage: EXTERNS\.BAT(?s:.*)Modules: .*fade'

Write-Output "xbnbuild-selftest: $checks checks passed"
