# kitplatform.ps1 - dot-source. Host facts every kit script shares.
# 5.1 has no $IsWindows: a non-Core edition is Windows.
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$ExeSuffix = if ($OnWindows) { '.exe' } else { '' }
$BuildLauncherName = if ($OnWindows) { 'BUILD.BAT' } else { 'build.sh' }

function Get-PythonCandidates {
    if ($OnWindows) { return @(, [string[]]@('py', '-3')) + @(, [string[]]@('python')) }
    return @(, [string[]]@('python3')) + @(, [string[]]@('python'))
}

# Returns the first candidate whose interpreter imports every module, or $null.
function Find-Python([string[]]$Imports) {
    $probe = 'import ' + ($Imports -join ', ')
    foreach ($cand in (Get-PythonCandidates)) {
        try {
            $exe = $cand[0]
            $rest = @()
            if ($cand.Length -gt 1) { $rest = $cand[1..($cand.Length - 1)] }
            & $exe @rest -c $probe *> $null
            # Unary comma: a one-element array would otherwise unroll to a string.
            if ($LASTEXITCODE -eq 0) { return ,([string[]]$cand) }
        } catch {}
    }
    return $null
}

function Join-KitPath([string[]]$Parts) {
    $p = $Parts[0]
    for ($i = 1; $i -lt $Parts.Length; $i++) { $p = Join-Path $p $Parts[$i] }
    return $p
}

# Case-insensitive extension match, ordinal-insensitive name order: the
# same list on NTFS and ext4. ExtRegex '*' means every file, extension or
# not (the PART<n> loop and the orphan pass stage extensionless files).
function Get-KitFiles([string]$Dir, [string]$ExtRegex) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($f in Get-ChildItem -LiteralPath $Dir -File) {
        if ($ExtRegex -eq '*' -or $f.Name -match "(?i)\.($ExtRegex)$") { $list.Add($f) }
    }
    $list.Sort([Comparison[System.IO.FileInfo]]{ param($a, $b) [StringComparer]::OrdinalIgnoreCase.Compare($a.Name, $b.Name) })
    return $list.ToArray()
}

# Case-insensitive exact-name lookup; returns the on-disk FileInfo or $null.
function Find-KitFile([string]$Dir, [string]$Name) {
    foreach ($f in Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue) {
        if ([string]::Equals($f.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $f }
    }
    return $null
}
