# kitcspect.ps1 - dot-source. The CSpect checks and launch shared by run.ps1 and debug.ps1.
if ($null -eq (Get-Variable OnWindows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'kitplatform.ps1') }

# Prints why CSpect cannot start and returns $false, else $true.
function Test-KitCSpect($Tools) {
    if (-not (Test-Path -LiteralPath $Tools.CSPECT -PathType Leaf)) {
        Write-Host "ERROR: CSpect not found at $($Tools.CSPECT)"
        Write-Host '       Install CSpect there, or set CSPECTDIR in CONFIG.BAT to an'
        Write-Host '       existing install.'
        return $false
    }
    if (-not $OnWindows -and -not (Get-Command $Tools.CSPECTCMD -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: $($Tools.CSPECTCMD) not found - CSpect needs mono on Linux (sudo apt install mono-devel), or set CSPECTCMD in CONFIG.BAT"
        return $false
    }
    return $true
}

# Puts Source in Dir unless Dir holds a newer version or the same bytes; prints
# what it did and returns $false when it could not. -Replace is the swap (tests inject one).
function Install-KitPlugin {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Dir, [string]$Label = $Dir,
          [scriptblock]$Replace = { param($s, $d) [IO.File]::Replace($s, $d, [NullString]::Value) })
    $leaf = Split-Path -Leaf $Source
    $dst = Join-Path $Dir $leaf
    $dstLbl = Join-Path $Label $leaf
    $want = [Reflection.AssemblyName]::GetAssemblyName($Source).Version
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        $have = $null
        try { $have = [Reflection.AssemblyName]::GetAssemblyName($dst).Version } catch { $have = $null }
        if ($null -ne $have -and $have -gt $want) { Write-Host "  debugger plugin in $Label is newer ($have) - kept"; return $true }
        if ($null -ne $have -and $have -eq $want -and
            [Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($dst), [IO.File]::ReadAllBytes($Source))) { return $true }
    }
    # Copy beside it, then swap: a locked plugin is left whole. Not *.dll, so
    # CSpect never loads a leftover. [NullString]: a bare $null reaches .NET as ''.
    $tmp = "$dst.new"
    try {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $dst) { & $Replace $tmp $dst } else { [IO.File]::Move($tmp, $dst) }
    } catch {
        # ERROR_UNABLE_TO_MOVE_REPLACEMENT: the old file is gone, the new one
        # still has the temp name - finish the move so CSpect keeps a plugin.
        if (-not (Test-Path -LiteralPath $dst) -and (Test-Path -LiteralPath $tmp)) {
            try { [IO.File]::Move($tmp, $dst) } catch { }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "ERROR: cannot update $dstLbl - close CSpect and try again"
        return $false
    }
    Write-Host "  debugger plugin -> $dstLbl"
    return $true
}

# Runs CSpect on RELEASE\<GAME>\ and waits for it. -Env sets (or, for $null,
# removes) variables for the child only. -NoLaunch prints them and the line instead.
function Start-KitCSpect {
    param([Parameter(Mandatory = $true)]$Tools, [Parameter(Mandatory = $true)]$Game, [hashtable]$Env = @{}, [switch]$NoLaunch)
    # The card root is the game folder, as an author copies it.
    $sep = [IO.Path]::DirectorySeparatorChar
    $nexFile = Find-KitFile $Game.RelGame "$($Game.Name).NEX"
    $nexName = if ($nexFile) { $nexFile.Name } else { "$($Game.Name).NEX" }
    $mmc = "RELEASE$sep$($Game.Name)$sep"
    $launch = "$mmc$nexName"
    $mmcArg = "-mmc=$mmc"
    # Legacy argument passing (5.1, 7.0-7.2) quotes a spaced argument without
    # escaping its trailing \, which would swallow the closing quote: double it.
    $pass = "$(Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue)"
    if ($OnWindows -and ($pass -in @('', 'Legacy')) -and $mmcArg -match '\s') { $mmcArg += $sep }
    $argv = @('-w3', '-zxnext', '-esc', $mmcArg, $launch)
    if (-not $OnWindows) { $argv = @($Tools.CSPECT) + $argv }
    $program = if ($OnWindows) { $Tools.CSPECT } else { $Tools.CSPECTCMD }
    if ($NoLaunch) {
        [string[]]$keys = @($Env.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($k in $keys) { if ($Env[$k]) { Write-Host "$k=$($Env[$k])" } }
        Write-Host "launch: $program $($argv -join ' ')"
        return
    }
    # [NullString] removes a variable: a bare $null reaches .NET as ''.
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $(if ($Env[$k]) { [string]$Env[$k] } else { [NullString]::Value }))
    }
    # The call operator quotes each argument on both hosts (Start-Process
    # -ArgumentList does not); piping to Out-Null waits for CSpect to exit.
    try { & $program @argv | Out-Null }
    finally {
        foreach ($k in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($k, $(if ($null -ne $saved[$k]) { $saved[$k] } else { [NullString]::Value }))
        }
    }
}
