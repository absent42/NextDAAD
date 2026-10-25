# Staging helpers for the autopilot runner (dot-sourced). Same rules as
# stage-legs.ps1: marker before any delete, no reparse points, no *.mmc/*.sd,
# Unblock-File on the copy only. Source CSpect folders are only read.
$StageMarker = '.cspect-autopilot-stage'
$AutopilotMarker = 'NEXTDAAD-AUTOPILOT-BUILD'

function Assert-UnderRoot([string]$path, [string]$root) {
    $sep = [string][IO.Path]::DirectorySeparatorChar
    $r = [IO.Path]::GetFullPath($root).TrimEnd($sep) + $sep
    $f = [IO.Path]::GetFullPath($path).TrimEnd($sep) + $sep
    if ($f -eq $r -or -not $f.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { throw "refusing: $path is not under $root" }
}

# Recursive delete of $path under $root; refuses if $path or anything inside it is a reparse point.
function Remove-StagedTree([string]$path, [string]$root) {
    Assert-UnderRoot $path $root
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "refusing: $path is a reparse point" }
    $rp = Get-ChildItem -LiteralPath $path -Recurse -Force -Attributes ReparsePoint | Select-Object -First 1
    if ($rp) { throw "refusing: $($rp.FullName) is a reparse point inside $path" }
    Remove-Item -LiteralPath $path -Recurse -Force
}

# Empties $dir for staging; only a folder this runner marked is ever deleted.
function Reset-StageFolder([string]$dir, [string]$root) {
    Assert-UnderRoot $dir $root
    if (Test-Path -LiteralPath $dir) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $StageMarker))) { throw "refusing: $dir exists and was not staged by the autopilot runner (no $StageMarker)" }
        Remove-StagedTree $dir $root
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir $StageMarker) -Value 'staged by cspect-plugin\autopilot\run-autopilot.ps1'
}

function Copy-CSpect([string]$src, [string]$dest) {
    if (-not (Test-Path -LiteralPath (Join-Path $src 'CSpect.exe'))) { throw "no CSpect.exe in $src" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    # A plugin a kit DEBUG run installed in the source is left out: each leg stages its own.
    & robocopy $src $dest /E /XJ /XF *.mmc *.sd NextDAADDebug.dll /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
    # The copy inherits Zone.Identifier from a downloaded CSpect; unattended launches would stop at a hidden prompt.
    Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File
}

# Copies relative paths $files from $src into $dest; refuses any target outside $dest.
function Copy-ListedFiles([string]$src, [string]$dest, [string[]]$files) {
    foreach ($f in $files) {
        $to = Join-Path $dest $f
        Assert-UnderRoot $to $dest
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Copy-Item -LiteralPath (Join-Path $src $f) $to
    }
}

function Test-BytesContain([byte[]]$hay, [byte[]]$needle) {
    $first = $needle[0]
    $i = [Array]::IndexOf($hay, $first)
    while ($i -ge 0 -and $i -le $hay.Length - $needle.Length) {
        $j = 1
        while ($j -lt $needle.Length -and $hay[$i + $j] -eq $needle[$j]) { $j++ }
        if ($j -eq $needle.Length) { return $true }
        $i = [Array]::IndexOf($hay, $first, $i + 1)
    }
    return $false
}

# AutopilotInfo.Marker is a const string: UTF-16 in the #US heap, ASCII checked too.
function Assert-AutopilotDll([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    foreach ($enc in [Text.Encoding]::Unicode, [Text.Encoding]::ASCII) {
        if (Test-BytesContain $b $enc.GetBytes($AutopilotMarker)) { return }
    }
    throw "staged DLL is not an autopilot build: $path"
}
