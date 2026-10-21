# kitgame.ps1 - dot-source. Resolves GAME to a game folder or a legacy root .DSF.
if ($null -eq (Get-Variable OnWindows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'kitplatform.ps1') }

# Case-insensitive directory lookup; returns the on-disk DirectoryInfo or $null.
function Find-KitDir([string]$Dir, [string]$Name) {
    foreach ($d in Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue) {
        if ([string]::Equals($d.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $d }
    }
    return $null
}

# PART2..PART9 are multi-part folders, never game folders.
function Test-KitPartDir([string]$Name) { return ($Name -match '^(?i)PART[2-9]$') }

function Resolve-KitGame([hashtable]$Config, [string]$KitRoot) {
    $sep = [IO.Path]::DirectorySeparatorChar
    $kit = [IO.Path]::GetFullPath($KitRoot)
    $game = ''
    if ($Config.ContainsKey('GAME')) { $game = "$($Config['GAME'])".Trim() }
    $mode = ''; $name = ''; $src = ''
    if ($game -ne '') {
        $dir = $null
        if (-not (Test-KitPartDir $game)) { $dir = Find-KitDir $kit $game }
        if ($dir) {
            $dsf = Find-KitFile $dir.FullName "$game.DSF"
            if (-not $dsf) { throw "ERROR: $game$sep has no $game.DSF" }
            $mode = 'folder'; $name = [IO.Path]::GetFileNameWithoutExtension($dsf.Name); $src = $dir.FullName
        } else {
            $dsf = Find-KitFile $kit "$game.DSF"
            if (-not $dsf) { throw "ERROR: $game.DSF not found in $game$sep or this folder" }
            $mode = 'legacy'; $name = [IO.Path]::GetFileNameWithoutExtension($dsf.Name); $src = $kit
        }
    } else {
        $rootDsf = @(Get-KitFiles $kit 'dsf')
        $folders = @()
        foreach ($d in (Get-ChildItem -LiteralPath $kit -Directory | Sort-Object Name)) {
            if (Test-KitPartDir $d.Name) { continue }
            $f = Find-KitFile $d.FullName "$($d.Name).DSF"
            if ($f) { $folders += , @($d, $f) }
        }
        # Deliberate: one root .DSF plus game folders is legacy, so a v0.11 root
        # game keeps building beside the shipped STARTER folder. Do not "fix".
        if ($rootDsf.Count -eq 1) {
            $mode = 'legacy'; $name = [IO.Path]::GetFileNameWithoutExtension($rootDsf[0].Name); $src = $kit
        } elseif ($rootDsf.Count -eq 0 -and $folders.Count -eq 1) {
            $mode = 'folder'; $name = [IO.Path]::GetFileNameWithoutExtension($folders[0][1].Name); $src = $folders[0][0].FullName
        } else {
            throw "ERROR: set GAME in CONFIG.local.BAT (found $($rootDsf.Count) .DSF files and $($folders.Count) game folders here, need exactly one)"
        }
    }
    $cfgFile = ''
    if ($mode -eq 'folder') { $cfgFile = Join-Path $src "$name.CFG" }
    $rel = Join-Path (Join-Path $kit 'RELEASE') $name
    return [pscustomobject]@{
        Name      = $name
        Mode      = $mode
        SrcRoot   = $src
        CfgFile   = $cfgFile
        RelGame   = $rel
        DataDir   = Join-Path $rel 'DATA'
        IsStarter = ($mode -eq 'folder' -and $name -ieq 'STARTER')
    }
}
