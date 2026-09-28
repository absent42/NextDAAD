# kittools.ps1 - dot-source after kitplatform.ps1. Paths as v0.11.0 tools.bat:
# blank per-tool dir = under TOOLSDIR; Arkos tools\, ffmpeg bin\ and a nested
# sjasmplus folder are probed; values stay relative to the kit root.

function Read-ToolVersions([string]$LibDir) {
    $v = @{}
    $p = Join-Path $LibDir 'toolversions.txt'
    if (-not (Test-Path -LiteralPath $p)) { return $v }
    foreach ($line in [IO.File]::ReadAllLines($p, [Text.Encoding]::ASCII)) {
        if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $v[$Matches[1]] = $Matches[2].Trim() }
    }
    return $v
}

function Get-NdrcBanner([string]$Ndrc) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $Ndrc 2>$null | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $eap }
    if ($lines.Count -eq 0) { return '' }
    return $lines[0]
}

function Resolve-KitTools([hashtable]$Config, [string]$KitRoot) {
    $lib = $PSScriptRoot
    $x = $ExeSuffix
    function cfg([string]$k) { if ($Config.ContainsKey($k)) { return [string]$Config[$k] } else { return '' } }
    function or([string]$v, [string]$d) { if ($v) { return $v } else { return $d } }
    function abs([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p } else { return Join-Path $KitRoot $p } }
    $t = @{}
    $t.TOOLSDIR = or (cfg 'TOOLSDIR') 'tools'
    $t.GFXDIR = or (cfg 'GFXDIR') (Join-Path $t.TOOLSDIR 'gfx2next')
    $t.ARKOSDIR = or (cfg 'ARKOSDIR') (Join-Path $t.TOOLSDIR 'ArkosTracker3')
    $t.CSPECTDIR = or (cfg 'CSPECTDIR') (Join-Path $t.TOOLSDIR 'CSpect')
    $t.FFMPEGDIR = or (cfg 'FFMPEGDIR') (Join-Path $t.TOOLSDIR 'ffmpeg')
    $t.SJASMPLUSDIR = or (cfg 'SJASMPLUSDIR') (Join-Path $t.TOOLSDIR 'sjasmplus')
    $t.NEXTDAWDIR = or (cfg 'NEXTDAWDIR') (Join-Path $t.TOOLSDIR 'NextDAW')
    $t.VIDTOOLSDIR = or (cfg 'VIDTOOLSDIR') (Join-Path $t.TOOLSDIR 'vidtools')
    $pins = Read-ToolVersions $lib
    $t.NDRCVER = or (cfg 'NDRCVER') ([string]$pins['NDRCVER'])
    $t.NDRC = or (cfg 'NDRC') (Join-Path $lib "ndrc$x")
    $t.GFX = Join-Path $t.GFXDIR "gfx2next$x"
    $t.CSPECT = Join-Path $t.CSPECTDIR "CSpect.exe"
    $t.VIDENC = Join-Path $t.VIDTOOLSDIR "videnc$x"
    $t.VIDTUNE = Join-Path $t.VIDTOOLSDIR "vidtune$x"
    $t.ARKOSBIN = $t.ARKOSDIR
    if (-not (Test-Path -LiteralPath (abs (Join-Path $t.ARKOSBIN "SongToAky$x"))) -and
        (Test-Path -LiteralPath (abs (Join-Path (Join-Path $t.ARKOSDIR 'tools') "SongToAky$x")))) {
        $t.ARKOSBIN = Join-Path $t.ARKOSDIR 'tools'
    }
    $t.S2A = Join-Path $t.ARKOSBIN "SongToAky$x"
    $t.S2E = Join-Path $t.ARKOSBIN "SongToSoundEffects$x"
    $t.S2Y = Join-Path $t.ARKOSBIN "SongToYm$x"
    $t.FFMPEGBIN = $t.FFMPEGDIR
    if (-not (Test-Path -LiteralPath (abs (Join-Path $t.FFMPEGBIN "ffmpeg$x"))) -and
        (Test-Path -LiteralPath (abs (Join-Path (Join-Path $t.FFMPEGDIR 'bin') "ffmpeg$x")))) {
        $t.FFMPEGBIN = Join-Path $t.FFMPEGDIR 'bin'
    }
    $t.FFMPEG = Join-Path $t.FFMPEGBIN "ffmpeg$x"
    $t.NDAWBIN = Join-Path (Join-Path $t.NEXTDAWDIR 'RuntimePlayer') 'NextDAW_RuntimePlayer_E000.bin'
    $t.INTRONEX = or (cfg 'INTRONEX') 'intro.nex'
    $t.NEXFILE = cfg 'NEXFILE'
    $t.SJASMPLUSBIN = $t.SJASMPLUSDIR
    if (-not (Test-Path -LiteralPath (abs (Join-Path $t.SJASMPLUSBIN "sjasmplus$x")))) {
        # tools.bat:70's for /d has no early exit - it keeps the LAST match in
        # name order. Sort ordinally (not culture order) so ext4's hash-order
        # listing still picks the same folder NTFS would.
        $nested = @(Get-ChildItem -LiteralPath (abs $t.SJASMPLUSDIR) -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "sjasmplus$x") } |
            ForEach-Object { $_.Name })
        if ($nested.Count -gt 0) {
            $names = New-Object 'System.Collections.Generic.List[string]'
            foreach ($n in $nested) { $names.Add($n) }
            $names.Sort([StringComparer]::OrdinalIgnoreCase)
            $t.SJASMPLUSBIN = Join-Path $t.SJASMPLUSDIR $names[$names.Count - 1]
        }
    }
    $t.SJASMPLUS = Join-Path $t.SJASMPLUSBIN "sjasmplus$x"
    $env:TOOLSDIR = $t.TOOLSDIR
    $env:FFMPEG = $t.FFMPEG
    $env:VIDENC = $t.VIDENC
    return $t
}
