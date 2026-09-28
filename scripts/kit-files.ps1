# Lists the kit files for one zip from lib\kitfiles.txt, or checks that
# every tracked kit file matches exactly one line. Exit 0/1.
param([ValidateSet('windows', 'linux', '')][string]$Platform = '', [switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$kit = Join-Path $root 'authoring-kit'
function To-Regex([string]$pat) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $pat.Length) {
        $c = $pat[$i]
        if ($c -eq '*' -and $i + 1 -lt $pat.Length -and $pat[$i + 1] -eq '*') { [void]$sb.Append('.*'); $i += 2; continue }
        if ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}
$rules = @()
$lines = [IO.File]::ReadAllLines((Join-Path $kit 'lib/kitfiles.txt'), [Text.Encoding]::ASCII)
for ($n = 0; $n -lt $lines.Count; $n++) {
    $line = $lines[$n]
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    $set, $pat = $line.Trim() -split '\s+', 2
    if (@('both', 'windows', 'linux', 'none') -cnotcontains $set) {
        Write-Host "kit-files: authoring-kit/lib/kitfiles.txt:$($n + 1): unknown set '$set'"; exit 1
    }
    $rules += [pscustomobject]@{ Set = $set; Pattern = $pat; Regex = (To-Regex $pat) }
}
$tracked = @(& git -C $kit ls-files)
$problems = @()
$out = New-Object System.Collections.Generic.List[string]
foreach ($f in $tracked) {
    $hits = @($rules | Where-Object { $f -cmatch $_.Regex })
    if ($hits.Count -ne 1) { $problems += "$f matches $($hits.Count) line(s): $(($hits | ForEach-Object { $_.Pattern }) -join ', ')"; continue }
    if ($Platform -and ($hits[0].Set -eq 'both' -or $hits[0].Set -eq $Platform)) { $out.Add($f) }
}
if ($Check) {
    if ($problems) { $problems | ForEach-Object { Write-Host "kit-files: $_" }; exit 1 }
    Write-Host "kit-files: $($tracked.Count) files classified"; exit 0
}
if (-not $Platform) { Write-Host 'kit-files: -Platform windows|linux or -Check'; exit 1 }
$out.Sort([StringComparer]::Ordinal)
[Console]::Out.Write((($out -join "`n") + "`n"))
exit 0
