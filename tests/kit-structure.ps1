# Static rules that keep the kit's platform-specific surface small. Each
# rule greps tracked files; the allow file lists accepted exceptions as
# <rule>|<relative path>|<substring>.
param([string[]]$Rules = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit = Join-Path $root 'authoring-kit'
$DefaultRules = @('launchers', 'python-candidates', 'exe-literals', 'backslash-literals', 'encodings', 'sort-ordinal')
if (-not $Rules) { $Rules = $DefaultRules }
$allow = @{}
foreach ($l in Get-Content -LiteralPath (Join-Path $PSScriptRoot 'kit-structure-allow.txt') -Encoding ASCII) {
    if (-not $l -or $l.StartsWith('#')) { continue }
    $r, $p, $s = $l.Split('|', 3)
    $allow["$r|$p|$s"] = $true
}
$failures = New-Object System.Collections.Generic.List[string]
function Allowed([string]$rule, [string]$path, [string]$line) {
    foreach ($k in $allow.Keys) {
        $r, $p, $s = $k.Split('|', 3)
        if ($r -eq $rule -and $p -eq $path -and $line.Contains($s)) { return $true }
    }
    return $false
}
function Scan([string]$rule, [string[]]$files, [string]$pattern, [string]$why) {
    foreach ($f in $files) {
        $rel = $f.Substring($kit.Length + 1) -replace '\\', '/'
        $n = 0
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            $n++
            if ($line -match $pattern -and -not (Allowed $rule $rel $line)) { $failures.Add("${rule}: ${rel}:$n $why`n    $line") }
        }
    }
}
$libPs = @(Get-ChildItem -LiteralPath (Join-Path $kit 'lib') -Filter *.ps1 -File | ForEach-Object { $_.FullName })
$libPy = @(Get-ChildItem -LiteralPath (Join-Path $kit 'lib') -Filter *.py -File -Recurse | ForEach-Object { $_.FullName })
$externPs = @(Get-ChildItem -LiteralPath (Join-Path $kit 'externs') -Filter build.ps1 -File -Recurse | ForEach-Object { $_.FullName })

if ($Rules -contains 'launchers') {
    foreach ($name in 'BUILD.BAT', 'RUN.BAT', 'CLEAN.BAT', 'EXTERNS.BAT', 'VIDTUNE.BAT', 'build.sh', 'run.sh', 'clean.sh', 'externs.sh', 'vidtune.sh') {
        $p = Join-Path $kit $name
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $lines = @([IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(REM\b|@REM\b|::|#)' })
        if ($lines.Count -gt 20) { $failures.Add("launchers: $name has $($lines.Count) code lines (max 20)") }
        $calls = @($lines | Where-Object { $_ -match 'lib[\\/]\w+\.ps1' }).Count
        if ($calls -ne 1) { $failures.Add("launchers: $name invokes lib/<verb>.ps1 $calls times (want 1)") }
    }
    $page = [IO.File]::ReadAllText((Join-Path $root 'manual/getting-started.md'))
    foreach ($m in [regex]::Matches($page, '`\./(\w+\.sh)`')) {
        if ('build.sh', 'run.sh', 'clean.sh', 'externs.sh', 'vidtune.sh' -notcontains $m.Groups[1].Value) { $failures.Add("launchers: getting-started.md names unknown launcher $($m.Groups[1].Value)") }
    }
}
if ($Rules -contains 'python-candidates') {
    # kitplatform.ps1 (shared by video.ps1 and vidtune.ps1) and encoderun.py
    # must list the same interpreter probe order.
    $ps = [IO.File]::ReadAllText((Join-Path $kit 'lib/kitplatform.ps1'))
    $py = [IO.File]::ReadAllText((Join-Path $kit 'lib/vidtune/encoderun.py'))
    foreach ($tok in "'py', '-3'", "'python3'", "'python'") {
        $pyTok = $tok -replace "'", '"'
        if (-not $ps.Contains($tok)) { $failures.Add("python-candidates: kitplatform.ps1 lacks $tok") }
        if (-not $py.Contains($pyTok)) { $failures.Add("python-candidates: encoderun.py lacks $pyTok") }
    }
}
# Comment lines and message lines are not code paths: skipped by every rule.
# The skip is a negative lookahead, so each pattern that uses it starts with ^;
# unanchored, the engine would retry at column 1 where ^ cannot match and the
# lookahead would pass.
$skipLine = '^\s*(#|REM\b|Write-(Host|Output|Error|Warning)\b|throw\b|Fail\b)'
if ($Rules -contains 'exe-literals') {
    # Platform conditionals in Python ("ffmpeg.exe" if os.name == "nt") are the
    # one legitimate .exe literal: allow-listed by the substring os.name or sys.platform.
    Scan 'exe-literals' ($libPs + $libPy + $externPs | Where-Object { $_ -notmatch 'kitplatform\.ps1$' }) "^(?!$skipLine).*\.exe\b" 'hardcoded .exe suffix'
}
if ($Rules -contains 'backslash-literals') {
    # A backslash between path-like characters inside a quoted string on a
    # line that is not a regex operation; '\d', '[\\/]' and '\\' are not matched.
    Scan 'backslash-literals' ($libPs + $externPs) ('^(?!' + $skipLine + ')(?!.*(-c?(not)?match|-replace|\[regex\]|-split)).*["''][^"'']*[A-Za-z0-9_.$}]\\[A-Za-z0-9_$*{][^"'']*["'']') 'backslash inside a path literal'
}
if ($Rules -contains 'encodings') {
    Scan 'encodings' $libPs ("^(?!$skipLine).*" + '\b(Get-Content|Set-Content|Out-File|Add-Content)\b(?!.*-Encoding)') 'text cmdlet without -Encoding'
    Scan 'encodings' $libPs ("^(?!$skipLine).*" + '-Encoding\s+(Byte|utf8NoBOM)\b') 'encoding name that only one host accepts'
}
if ($Rules -contains 'sort-ordinal') {
    # Anchored like the other rules: unanchored, the skip's ^ lookahead never
    # matches when the engine retries mid-line, so the skip silently fails.
    Scan 'sort-ordinal' $libPs ("^(?!$skipLine).*" + 'Sort-Object(?!.*(Ordinal|-Property\s+\{))') 'Sort-Object without an ordinal comparer'
}
if ($failures.Count) {
    $failures | ForEach-Object { Write-Host $_ }
    Write-Host "kit-structure: $($failures.Count) failure(s)"
    exit 1
}
Write-Host "kit-structure: rules $($Rules -join ',') pass"
exit 0
