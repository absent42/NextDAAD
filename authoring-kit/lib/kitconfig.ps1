# kitconfig.ps1 - dot-source. Reads CONFIG.BAT, the game .CFG (game-folder mode)
# and CONFIG.local.BAT with cmd's semantics (last-wins). Grammar shared with lib\vidtune\kitmodel.py.
if ($null -eq (Get-Variable OnWindows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'kitplatform.ps1') }
$KitConfigLineRegex = '^\s*set\s+"?([A-Za-z0-9_]+)=(.*?)"?\s*$'
$KitConfigPathKeys = '^(TOOLSDIR|GFXDIR|ARKOSDIR|CSPECTDIR|FFMPEGDIR|SJASMPLUSDIR|NEXTDAWDIR|VIDTOOLSDIR|NDRC|NEXFILE|INTRONEX)$'

function Read-KitConfigFile([string]$Path, [hashtable]$Into) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::GetEncoding(28591))) {
        $m = [regex]::Match($line, $KitConfigLineRegex, 'IgnoreCase')
        if (-not $m.Success) { continue }
        $k = $m.Groups[1].Value.ToUpperInvariant(); $v = $m.Groups[2].Value
        # Non-Windows hosts: a CONFIG written on Windows keeps working (spec 4.2).
        if (-not $OnWindows -and $k -match $KitConfigPathKeys) { $v = $v -replace '\\', '/' }
        $Into[$k] = $v
    }
}

# Layers, last wins: CONFIG.BAT, the game's .CFG, CONFIG.local.BAT. GAME in the
# game .CFG is dropped: the selector lives in CONFIG.local.BAT.
function Read-KitConfig([string]$KitRoot, [string]$GameCfg = '') {
    $cfg = @{}
    Read-KitConfigFile (Join-Path $KitRoot 'CONFIG.BAT') $cfg
    if ($GameCfg -ne '') {
        $game = @{}
        Read-KitConfigFile $GameCfg $game
        if ($game.ContainsKey('GAME')) {
            $game.Remove('GAME')
            Write-Host "WARNING: GAME in $GameCfg is ignored - select the game in CONFIG.local.BAT"
        }
        foreach ($k in $game.Keys) { $cfg[$k] = $game[$k] }
    }
    Read-KitConfigFile (Join-Path $KitRoot 'CONFIG.local.BAT') $cfg
    return $cfg
}

# cmd's "SET NAME=" deletes the variable; an empty value does the same here.
function Export-KitConfig([hashtable]$Config) {
    foreach ($k in $Config.Keys) {
        $v = $Config[$k]
        if ([string]::IsNullOrEmpty($v)) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$k" -Value $v }
    }
}
