# Pins lib\debug.ps1 (DEBUG.BAT / debug.sh), lib\kitcspect.ps1 and the build's
# -SrcMap and #debug paths in a scratch kit. Debug runs use -NoLaunch; CSpect is a
# fake assembly, and the one launch is a script standing in for it.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root/authoring-kit/lib/kitplatform.ps1"
. "$root/authoring-kit/lib/kittools.ps1"
$sep = [IO.Path]::DirectorySeparatorChar
$checks = 0
function Assert-Eq($actual, $expected, $what) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "kitdebug-selftest: $what - got '$actual', expected '$expected'" }
}
function Assert-Has($r, [string]$line, $what) {
    $script:checks++
    if ($r.Lines -notcontains $line) { throw "kitdebug-selftest: $what - no line '$line' in:`n$($r.Out)" }
}
function Assert-Lacks($r, [string]$pattern, $what) {
    $script:checks++
    if ($r.Out -like $pattern) { throw "kitdebug-selftest: $what - '$pattern' found in:`n$($r.Out)" }
}
function Assert-Like($r, [string]$pattern, $what) {
    $script:checks++
    if ($r.Out -notlike $pattern) { throw "kitdebug-selftest: $what - '$pattern' not in:`n$($r.Out)" }
}
function Test-SameBytes([string]$a, [string]$b) {
    return [Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($a), [IO.File]::ReadAllBytes($b))
}

$kitSrc = Join-Path $root 'authoring-kit'
$base = [IO.Path]::GetFullPath((Join-Path $root 'tests/out/kitdebug'))
$kit = Join-Path $base 'kit dir'
if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
$g1 = Join-Path $kit 'G1'
New-Item -ItemType Directory -Path (Join-Path $kit 'lib'), (Join-Path $g1 'inc'), (Join-Path $g1 'PART2') -Force | Out-Null
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kitSrc 'lib') -File) {
    if ($f.Extension -eq '.ps1') { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $kit 'lib') }
}
foreach ($n in 'toolversions.txt', 'default.chr', 'NextDAADDebug.dll', "ndrc$ExeSuffix") {
    Copy-Item -LiteralPath (Join-KitPath @($kitSrc, 'lib', $n)) -Destination (Join-Path $kit 'lib')
}
if (-not $OnWindows) { & chmod +x (Join-KitPath @($kit, 'lib', 'ndrc')) }
foreach ($n in 'CONFIG.BAT', 'nextdaad.nex', 'NEXTDAAD.SYM', 'intro.nex') { Copy-Item -LiteralPath (Join-Path $kitSrc $n) -Destination $kit }
$fix = Join-Path $root 'tests/kit-parity/fixture'
Copy-Item -LiteralPath (Join-Path $fix 'PARITY.DSF') -Destination (Join-Path $g1 'G1.DSF')
Copy-Item -LiteralPath (Join-KitPath @($fix, 'inc', 'rooms.dsf')) -Destination (Join-Path $g1 'inc')
Copy-Item -LiteralPath (Join-KitPath @($fix, 'PART2', 'PART2.DSF')) -Destination (Join-Path $g1 'PART2')
$kitDll = Join-KitPath @($kit, 'lib', 'NextDAADDebug.dll')
$kitSym = Join-Path $kit 'NEXTDAAD.SYM'

# The file name the kit looks for in CSPECTDIR; Resolve-KitTools sets env as a side effect.
$envSaved = @{}; foreach ($k in 'TOOLSDIR', 'FFMPEG', 'VIDENC') { $envSaved[$k] = [Environment]::GetEnvironmentVariable($k) }
$cspName = Split-Path -Leaf (Resolve-KitTools @{} $kit).CSPECT
foreach ($k in $envSaved.Keys) { [Environment]::SetEnvironmentVariable($k, $envSaved[$k]) }

function New-FakeAssembly([string]$Path, [string]$Version) {
    # Main: Windows PowerShell 5.1 compiles a name ending in exe as a program.
    $cls = 'Fake' + [guid]::NewGuid().ToString('N')
    Add-Type -TypeDefinition "[assembly: System.Reflection.AssemblyVersion(`"$Version`")] public class $cls { public static void Main() {} }" -OutputAssembly $Path -OutputType Library
}
function New-CSpectDir([string]$Name, [string]$Version, [switch]$ImGui) {
    $d = Join-Path $base $Name
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    if ($Version) { New-FakeAssembly (Join-Path $d $cspName) $Version }
    else { [IO.File]::WriteAllBytes((Join-Path $d $cspName), [byte[]](1..64)) }
    if ($ImGui) { [IO.File]::WriteAllBytes((Join-Path $d 'ImGui.NET.dll'), [byte[]](1..4)) }
    return $d
}
$cs40 = New-CSpectDir 'cs40' '4.0.0.0'
$cs331 = New-CSpectDir 'cs331' '3.3.1.0'
$csBad = New-CSpectDir 'csbad' ''
$csBadImGui = New-CSpectDir 'csbadimgui' '' -ImGui
$fakeOld = Join-Path (Join-Path $base 'old') 'NextDAADDebug.dll'
$fakeNew = Join-Path (Join-Path $base 'new') 'NextDAADDebug.dll'
New-Item -ItemType Directory -Path (Split-Path $fakeOld), (Split-Path $fakeNew) -Force | Out-Null
New-FakeAssembly $fakeOld '0.1.0.0'
New-FakeAssembly $fakeNew '9.0.0.0'
$tools = Join-Path $base 'tools'
$hostExe = (Get-Process -Id $PID).Path

function Invoke-Kit([string]$Script, [string[]]$Local, [string[]]$ScriptArgs = @()) {
    $lines = @('SET RUN=0', "SET TOOLSDIR=$tools") + $Local
    if (-not $OnWindows) { $lines += 'SET CSPECTCMD=sh' }
    [IO.File]::WriteAllLines((Join-Path $kit 'CONFIG.local.BAT'), $lines, [Text.Encoding]::ASCII)
    Push-Location $kit
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File "lib/$Script" @ScriptArgs 2>&1 | ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap; Pop-Location }
    return @{ Rc = $rc; Out = ($out -join "`n"); Lines = $out }
}
function Invoke-Debug([string[]]$Local) { return (Invoke-Kit 'debug.ps1' $Local @('-NoLaunch')) }
function Invoke-Build([string[]]$Local) { return (Invoke-Kit 'build.ps1' $Local) }
function Get-Tree([string]$Dir) {
    $l = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in Get-ChildItem -LiteralPath $Dir -File -Recurse) { $l.Add($f.FullName.Substring($Dir.Length + 1)) }
    $l.Sort([StringComparer]::Ordinal)
    return ($l -join '|')
}
$useG1 = @('SET GAME=G1', "SET CSPECTDIR=$cs40")
$relG1 = Join-KitPath @($kit, 'RELEASE', 'G1')
$dst = Join-Path $cs40 'NextDAADDebug.dll'
$monoWarn = "WARNING: CSpect under mono does not change into the game's DATA folder yet (reported to its author) - the game will stop at E1 until a fixed CSpect is released"
function Get-DebugWarning([string]$File) { return "WARNING: $File has #debug - DEBUG markers are compiled into the game; remove it before release (other DAAD interpreters read a marker as NEWTEXT)" }

# ---- refusals before any build ----
$r = Invoke-Debug @('SET GAME=G1', 'SET EMULATOR=jnext', "SET CSPECTDIR=$cs40")
Assert-Eq $r.Rc 1 'jnext-refused exit'
$runName = if ($OnWindows) { 'RUN.BAT' } else { 'run.sh' }
Assert-Has $r "ERROR: the debugger runs in CSpect - set EMULATOR=cspect in CONFIG.local.BAT ($runName still runs jNext)" 'jnext-refused text'

$r = Invoke-Debug @('SET GAME=G1', 'SET CSPECTDIR=nosuch')
Assert-Eq $r.Rc 1 'cspect-missing exit'
Assert-Like $r '*ERROR: CSpect not found at*' 'cspect-missing text'
Assert-Like $r '*Install CSpect there, or set CSPECTDIR in CONFIG.BAT to an*' 'cspect-missing hint'

$r = Invoke-Debug @('SET GAME=G1', "SET CSPECTDIR=$cs331")
Assert-Eq $r.Rc 1 'cspect-3x-refused exit'
Assert-Has $r "ERROR: the debugger needs CSpect 4.0 or later - found 3.3.1.0 in $cs331" 'cspect-3x-refused text'

$r = Invoke-Debug @('SET GAME=G1', "SET CSPECTDIR=$csBad")
Assert-Eq $r.Rc 1 'cspect-version-unreadable exit (no ImGui.NET.dll)'
Assert-Has $r "ERROR: could not read the CSpect version in $csBad - the debugger needs CSpect 4.0 or later" 'cspect-version-unreadable text'
Assert-Eq (Test-Path -LiteralPath $relG1) $false 'refusals come before the build'

# ---- BUILD.BAT baseline: no maps ----
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'baseline build exit'
Assert-Eq (Test-Path -LiteralPath (Join-Path $g1 'GAME.DSM')) $false 'BUILD.BAT writes no GAME.DSM'
Assert-Eq (Test-Path -LiteralPath (Join-Path $g1 'GAME2.DSM')) $false 'BUILD.BAT writes no GAME2.DSM'
Assert-Lacks $r '*has #debug*' 'no #debug warning for a clean source'
$tree = Get-Tree $relG1
$ddbSave = Join-Path $base 'ddb'
New-Item -ItemType Directory -Path $ddbSave -Force | Out-Null
foreach ($n in 'GAME.DDB', 'GAME2.DDB') { Copy-Item -LiteralPath (Join-KitPath @($relG1, 'DATA', $n)) -Destination $ddbSave }

# ---- cspect-40-accepted, maps-in-source-folder, dll-installed, env-and-launch-line ----
$r = Invoke-Debug $useG1
Assert-Eq $r.Rc 0 'cspect-40-accepted exit'
foreach ($n in 'GAME.DSM', 'GAME2.DSM', 'NEXTDAAD.SYM') { Assert-Eq (Test-Path -LiteralPath (Join-Path $g1 $n)) $true "maps-in-source-folder: G1$sep$n" }
Assert-Eq (Test-SameBytes (Join-Path $g1 'NEXTDAAD.SYM') $kitSym) $true 'NEXTDAAD.SYM is the kit copy'
Assert-Eq (Get-Tree $relG1) $tree 'nothing new under RELEASE/G1 compared with BUILD.BAT'
foreach ($n in 'GAME.DDB', 'GAME2.DDB') { Assert-Eq (Test-SameBytes (Join-KitPath @($relG1, 'DATA', $n)) (Join-Path $ddbSave $n)) $true "$n byte-identical to the BUILD.BAT build" }
Assert-Like @{ Out = [IO.File]::ReadAllText((Join-Path $g1 'GAME2.DSM')) } "*`tPART2/PART2.DSF*" 'GAME2.DSM maps the part source'
Assert-Has $r "  debugger plugin -> $dst" 'dll-installed text'
Assert-Eq (Test-SameBytes $dst $kitDll) $true 'dll-installed bytes'
Assert-Has $r "NEXTDAAD_DEBUG=$g1" 'env-and-launch-line: NEXTDAAD_DEBUG is SrcRoot'
$mmc = "RELEASE${sep}G1${sep}"
$prog = if ($OnWindows) { Join-Path $cs40 $cspName } else { "sh $(Join-Path $cs40 $cspName)" }
Assert-Has $r "launch: $prog -w3 -zxnext -esc -mmc=$mmc ${mmc}G1.NEX" 'env-and-launch-line: run.ps1 launch line'
if ($OnWindows) { Assert-Lacks $r '*CSpect under mono*' 'no mono warning on Windows' } else { Assert-Has $r $monoWarn 'mono warning on Linux' }

# ---- build-leaves-maps ----
$dsm = Join-Path $g1 'GAME.DSM'
$dsmBytes = [IO.File]::ReadAllBytes($dsm); $dsmTime = (Get-Item -LiteralPath $dsm).LastWriteTimeUtc
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'build-leaves-maps build exit'
Assert-Eq ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($dsm), $dsmBytes)) $true 'build-leaves-maps bytes'
Assert-Eq (Get-Item -LiteralPath $dsm).LastWriteTimeUtc $dsmTime 'build-leaves-maps mtime'
Assert-Eq (Test-Path -LiteralPath (Join-Path $g1 'GAME2.DSM')) $true 'build-leaves-maps GAME2.DSM'

# ---- build.sh passes its arguments through: a prefix such as -s is not -SrcMap ----
Remove-Item -LiteralPath $dsm -Force
$r = Invoke-Kit 'build.ps1' $useG1 @('-s', '-n', 'extra')
Assert-Eq $r.Rc 0 'prefix-args build exit'
Assert-Eq (Test-Path -LiteralPath $dsm) $false 'prefix -s writes no GAME.DSM'
$r = Invoke-Kit 'build.ps1' $useG1 @('-SrcMap')
Assert-Eq $r.Rc 0 'whole-name -SrcMap build exit'
Assert-Eq (Test-Path -LiteralPath $dsm) $true 'whole-name -SrcMap writes GAME.DSM'

# ---- plugin DLL ----
$dllTime = (Get-Item -LiteralPath $dst).LastWriteTimeUtc
$r = Invoke-Debug $useG1
Assert-Eq $r.Rc 0 'dll-current exit'
Assert-Lacks $r '*debugger plugin*' 'dll-current says nothing'
Assert-Eq (Get-Item -LiteralPath $dst).LastWriteTimeUtc $dllTime 'dll-current left untouched'

[IO.File]::WriteAllBytes($dst, [byte[]]([IO.File]::ReadAllBytes($kitDll) + [byte[]](0)))
$r = Invoke-Debug $useG1
Assert-Has $r "  debugger plugin -> $dst" 'dll-same-version-different-bytes text'
Assert-Eq (Test-SameBytes $dst $kitDll) $true 'dll-same-version-different-bytes replaced'

Copy-Item -LiteralPath $fakeOld -Destination $dst -Force
$r = Invoke-Debug $useG1
Assert-Eq $r.Rc 0 'dll-older-replaced exit'
Assert-Has $r "  debugger plugin -> $dst" 'dll-older-replaced text'
Assert-Eq (Test-SameBytes $dst $kitDll) $true 'dll-older-replaced bytes'

Copy-Item -LiteralPath $fakeNew -Destination $dst -Force
$r = Invoke-Debug $useG1
Assert-Eq $r.Rc 0 'dll-newer-kept exit'
Assert-Has $r "  debugger plugin in $cs40 is newer (9.0.0.0) - kept" 'dll-newer-kept text'
Assert-Eq (Test-SameBytes $dst $fakeNew) $true 'dll-newer-kept bytes'

if ($OnWindows) {
    Copy-Item -LiteralPath $fakeOld -Destination $dst -Force
    # A loaded plugin: open for read, shared for read only, as CSpect holds it.
    $lock = [IO.File]::Open($dst, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $r = Invoke-Debug $useG1 } finally { $lock.Dispose() }
    Assert-Eq $r.Rc 1 'dll-locked-error exit'
    Assert-Has $r "ERROR: cannot update $dst - close CSpect and try again" 'dll-locked-error text'
    Assert-Eq (Test-SameBytes $dst $fakeOld) $true 'dll-locked-error leaves the installed file'
    Assert-Eq (@(Get-ChildItem -LiteralPath $cs40 -File | Where-Object { $_.Name -ne $cspName -and $_.Name -ne 'NextDAADDebug.dll' }).Count) 0 'dll-locked-error leaves no temp file'
} else {
    Write-Output 'skip: dll-locked-error (POSIX does not lock an open file)'
}

$r = Invoke-Debug @('SET GAME=G1', "SET CSPECTDIR=$csBadImGui")
Assert-Eq $r.Rc 0 'cspect-version-unreadable exit (ImGui.NET.dll present)'
Assert-Has $r 'note: could not read the CSpect version - assuming 4.0 or later' 'cspect-version-unreadable note'

# ---- legacy-root-game ----
Copy-Item -LiteralPath (Join-Path $g1 'G1.DSF') -Destination (Join-Path $kit 'L1.DSF')
Copy-Item -LiteralPath (Join-Path $g1 'inc') -Destination (Join-Path $kit 'inc') -Recurse
$r = Invoke-Debug @('SET GAME=L1', "SET CSPECTDIR=$cs40")
Assert-Eq $r.Rc 0 'legacy-root-game exit'
Assert-Eq (Test-Path -LiteralPath (Join-Path $kit 'GAME.DSM')) $true 'legacy-root-game GAME.DSM beside L1.DSF'
Assert-Eq (Test-SameBytes $kitSym (Join-Path $kitSrc 'NEXTDAAD.SYM')) $true 'legacy-root-game kit NEXTDAAD.SYM intact'
Assert-Has $r "NEXTDAAD_DEBUG=$kit" 'legacy-root-game NEXTDAAD_DEBUG is the kit root'
foreach ($p in 'L1.DSF', 'inc', 'GAME.DSM', (Join-Path 'RELEASE' 'L1')) { Remove-Item -LiteralPath (Join-Path $kit $p) -Recurse -Force }

# ---- debug-directive-warns ----
function Edit-Line([string]$Path, [int]$At, [string]$Line) {
    $l = [IO.File]::ReadAllLines($Path, [Text.Encoding]::GetEncoding(28591))
    $o = @($l[0..($At - 1)]) + $Line + @($l[$At..($l.Length - 1)])
    [IO.File]::WriteAllLines($Path, $o, [Text.Encoding]::GetEncoding(28591))
}
$g1Dsf = Join-Path $g1 'G1.DSF'; $p2Dsf = Join-KitPath @($g1, 'PART2', 'PART2.DSF'); $incDsf = Join-KitPath @($g1, 'inc', 'rooms.dsf')
$orig = @{}; foreach ($p in $g1Dsf, $p2Dsf, $incDsf) { $orig[$p] = [IO.File]::ReadAllBytes($p) }
function Restore-Sources { foreach ($p in $orig.Keys) { [IO.File]::WriteAllBytes($p, $orig[$p]) } }
$mainWarn = Get-DebugWarning 'G1.DSF'
Edit-Line $g1Dsf 5 '#debug'
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns main exit (BUILD)'
Assert-Has $r $mainWarn 'debug-directive-warns main (BUILD)'
Assert-Eq @($r.Lines | Where-Object { $_ -like '*has #debug*' }).Count 1 'one warning per file'
$r = Invoke-Debug $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns main exit (DEBUG)'
Assert-Has $r $mainWarn 'debug-directive-warns main (DEBUG)'
Restore-Sources
Edit-Line $g1Dsf 5 "`t #debug `t; switched on"
$r = Invoke-Build $useG1
Assert-Has $r $mainWarn 'debug-directive-warns leading blanks and a trailing comment'
Restore-Sources
# NDRC's lexer takes the directive in lower case only: #DEBUG is a syntax error, not debug mode.
Edit-Line $g1Dsf 5 '#DEBUG'
$r = Invoke-Build $useG1
Assert-Lacks $r '*has #debug*' 'debug-directive-warns #DEBUG is not the directive'
Assert-Like $r '*Unexpected character*' 'NDRC rejects #DEBUG'
Restore-Sources
Edit-Line $p2Dsf 5 '#debug'
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns part exit'
Assert-Has $r (Get-DebugWarning "PART2${sep}PART2.DSF") 'debug-directive-warns part'
Restore-Sources
Edit-Line $incDsf 1 '#debug'
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns include exit'
Assert-Has $r (Get-DebugWarning 'inc/rooms.dsf') 'debug-directive-warns include'
Restore-Sources
Edit-Line $g1Dsf 5 '; #debug'
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns comment exit'
Assert-Lacks $r '*has #debug*' 'debug-directive-warns comment gives none'
Restore-Sources
$t = [IO.File]::ReadAllText($g1Dsf, [Text.Encoding]::GetEncoding(28591))
$anchor = '                PROCESS 6                   ; Initialise'
if (-not $t.Contains($anchor)) { throw 'kitdebug-selftest: fixture anchor for the DEBUG condact moved' }
[IO.File]::WriteAllText($g1Dsf, $t.Replace($anchor, "$anchor`r`n                DEBUG"), [Text.Encoding]::GetEncoding(28591))
$r = Invoke-Build $useG1
Assert-Eq $r.Rc 0 'debug-directive-warns DEBUG condact exit'
Assert-Lacks $r '*has #debug*' 'debug-directive-warns DEBUG condact gives none'
Restore-Sources

# ---- intro-game-launch-line ----
function Get-Crc32([byte[]]$Bytes) {
    $c = 0xFFFFFFFFL
    foreach ($x in $Bytes) {
        $c = $c -bxor $x
        for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = ($c -shr 1) -bxor 0xEDB88320L } else { $c = $c -shr 1 } }
    }
    return ($c -bxor 0xFFFFFFFFL)
}
function Get-BE32([long]$v) { return [byte[]]@((($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)) }
# 320x256 8-bit paletted PNG, every pixel index 0.
function Write-TestPng([string]$Path) {
    $w = 320; $h = 256
    $raw = New-Object byte[] (($w + 1) * $h)
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress, $true)
    $ds.Write($raw, 0, $raw.Length); $ds.Dispose()
    # Adler-32 of all-zero data: a = 1, b = length mod 65521.
    $b = $raw.Length % 65521
    $idat = [byte[]](@(0x78, 0x01) + $ms.ToArray() + @((($b -shr 8) -band 255), ($b -band 255), 0, 1))
    $pal = New-Object byte[] 768
    for ($i = 0; $i -lt 256; $i++) { $pal[3 * $i] = $i; $pal[3 * $i + 1] = $i; $pal[3 * $i + 2] = $i }
    $out = New-Object IO.MemoryStream
    $out.Write([byte[]](137, 80, 78, 71, 13, 10, 26, 10), 0, 8)
    $ihdr = [byte[]]((Get-BE32 $w) + (Get-BE32 $h) + @(8, 3, 0, 0, 0))
    foreach ($ch in @(@('IHDR', $ihdr), @('PLTE', $pal), @('IDAT', $idat), @('IEND', [byte[]]@()))) {
        $body = [byte[]]([Text.Encoding]::ASCII.GetBytes($ch[0]) + $ch[1])
        $hdr = Get-BE32 $ch[1].Length; $out.Write($hdr, 0, 4)
        $out.Write($body, 0, $body.Length)
        $crc = Get-BE32 (Get-Crc32 $body); $out.Write($crc, 0, 4)
    }
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}
$i1 = Join-Path $kit 'I1'
New-Item -ItemType Directory -Path $i1 -Force | Out-Null
Copy-Item -LiteralPath $g1Dsf -Destination (Join-Path $i1 'I1.DSF')
Copy-Item -LiteralPath (Join-Path $g1 'inc') -Destination (Join-Path $i1 'inc') -Recurse
Write-TestPng (Join-Path $i1 'p.png')
[IO.File]::WriteAllText((Join-Path $i1 'INTRO.TXT'), "SLIDE p.png IN CUT HOLD 1.0`r`nEND CUT`r`n", [Text.Encoding]::ASCII)
$r = Invoke-Debug @('SET GAME=I1', "SET CSPECTDIR=$cs40", "SET GFXDIR=$(Join-KitPath @($kitSrc, 'tools', 'gfx2next'))")
Assert-Eq $r.Rc 0 'intro-game-launch-line exit'
$mmc = "RELEASE${sep}I1${sep}"
Assert-Has $r "launch: $prog -w3 -zxnext -esc -mmc=$mmc ${mmc}I1.NEX" 'intro-game-launch-line launches the intro launcher'
Assert-Eq (Test-Path -LiteralPath (Join-KitPath @($kit, 'RELEASE', 'I1', 'DATA', 'nextdaad.nex'))) $true 'intro game interpreter in DATA'
Assert-Eq (Test-Path -LiteralPath (Join-Path $i1 'GAME.DSM')) $true 'intro game map'

# ---- Start-KitCSpect: child env set and cleared, restored afterwards ----
. (Join-KitPath @($kit, 'lib', 'kitcspect.ps1'))
$log = Join-Path $base 'launch.log'
$env:FAKE_LAUNCH_LOG = $log
if ($OnWindows) {
    $fake = Join-Path $base 'fakecspect.cmd'
    [IO.File]::WriteAllText($fake, "@if defined NEXTDAAD_DEBUG_TRACE (echo TRACE set>`"%FAKE_LAUNCH_LOG%`") else (echo TRACE unset>`"%FAKE_LAUNCH_LOG%`")`r`n@echo DEBUG=%NEXTDAAD_DEBUG%>>`"%FAKE_LAUNCH_LOG%`"`r`n@echo ARGS=%*>>`"%FAKE_LAUNCH_LOG%`"`r`n", [Text.Encoding]::ASCII)
    $ft = @{ CSPECT = $fake; CSPECTCMD = '' }
} else {
    $fake = Join-Path $base 'fakecspect.sh'
    [IO.File]::WriteAllText($fake, "echo `"TRACE `${NEXTDAAD_DEBUG_TRACE-unset}`" > `"`$FAKE_LAUNCH_LOG`"`necho `"DEBUG=`$NEXTDAAD_DEBUG`" >> `"`$FAKE_LAUNCH_LOG`"`necho `"ARGS=`$*`" >> `"`$FAKE_LAUNCH_LOG`"`n")
    $ft = @{ CSPECT = $fake; CSPECTCMD = 'sh' }
}
$fg = [pscustomobject]@{ Name = 'G1'; RelGame = $relG1 }
$env:NEXTDAAD_DEBUG_TRACE = '1'
Remove-Item Env:NEXTDAAD_DEBUG -ErrorAction SilentlyContinue
Push-Location $kit
try { Start-KitCSpect -Tools $ft -Game $fg -Env @{ NEXTDAAD_DEBUG = $g1; NEXTDAAD_DEBUG_TRACE = $null } } finally { Pop-Location }
$got = @(Get-Content -LiteralPath $log -Encoding ASCII | ForEach-Object { $_.Trim() })
Assert-Eq ($got[0] -replace '[ :]', '') 'TRACEunset' 'child has NEXTDAAD_DEBUG_TRACE removed'
Assert-Eq $got[1] "DEBUG=$g1" 'child has NEXTDAAD_DEBUG'
$mmc = "RELEASE${sep}G1${sep}"
Assert-Eq $got[2] "ARGS=-w3 -zxnext -esc -mmc=$mmc ${mmc}G1.NEX" 'child arguments'
Assert-Eq $env:NEXTDAAD_DEBUG_TRACE '1' 'NEXTDAAD_DEBUG_TRACE restored'
Assert-Eq (Test-Path Env:NEXTDAAD_DEBUG) $false 'NEXTDAAD_DEBUG restored (unset)'
Remove-Item Env:NEXTDAAD_DEBUG_TRACE, Env:FAKE_LAUNCH_LOG

# ---- Install-KitPlugin: a failed swap, injected ----
$pd = Join-Path $base 'plug'
New-Item -ItemType Directory -Path $pd -Force | Out-Null
$pdst = Join-Path $pd 'NextDAADDebug.dll'
function Invoke-Install([scriptblock]$Replace) {
    $res = @(Install-KitPlugin -Source $kitDll -Dir $pd -Replace $Replace 6>&1)
    return @{ Ok = @($res | Where-Object { $_ -is [bool] })[0]; Lines = @($res | Where-Object { $_ -isnot [bool] } | ForEach-Object { "$_" }); Out = '' }
}
$lockedMsg = "ERROR: cannot update $pdst - close CSpect and try again"
# ERROR_UNABLE_TO_MOVE_REPLACEMENT: ReplaceFile removed the old file and left the new one under its temp name.
Copy-Item -LiteralPath $fakeOld -Destination $pdst -Force
$r = Invoke-Install { param($s, $d) Remove-Item -LiteralPath $d -Force; throw 'simulated ERROR_UNABLE_TO_MOVE_REPLACEMENT' }
Assert-Eq $r.Ok $false 'unable-to-move-replacement returns failure'
Assert-Has $r $lockedMsg 'unable-to-move-replacement text'
Assert-Eq (Test-SameBytes $pdst $kitDll) $true 'unable-to-move-replacement leaves the new plugin in place'
Assert-Eq (Test-Path -LiteralPath "$pdst.new") $false 'unable-to-move-replacement leaves no temp file'
# A swap refused outright (a locked file, on any host).
Copy-Item -LiteralPath $fakeOld -Destination $pdst -Force
$r = Invoke-Install { param($s, $d) throw 'simulated sharing violation' }
Assert-Eq $r.Ok $false 'refused swap returns failure'
Assert-Has $r $lockedMsg 'refused swap text'
Assert-Eq (Test-SameBytes $pdst $fakeOld) $true 'refused swap leaves the installed plugin'
Assert-Eq (Test-Path -LiteralPath "$pdst.new") $false 'refused swap leaves no temp file'
$r = Invoke-Install { param($s, $d) [IO.File]::Replace($s, $d, [NullString]::Value) }
Assert-Eq $r.Ok $true 'default swap returns success'
Assert-Has $r "  debugger plugin -> $pdst" 'default swap text'
Assert-Eq (Test-SameBytes $pdst $kitDll) $true 'default swap installs the plugin'

Remove-Item -LiteralPath $base -Recurse -Force
Write-Output "kitdebug-selftest: $checks checks passed"
