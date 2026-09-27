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
            if ($LASTEXITCODE -eq 0) { return [string[]]$cand }
        } catch {}
    }
    return $null
}

function Join-KitPath([string[]]$Parts) {
    $p = $Parts[0]
    for ($i = 1; $i -lt $Parts.Length; $i++) { $p = Join-Path $p $Parts[$i] }
    return $p
}
