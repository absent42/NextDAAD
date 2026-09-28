# Runs each native tool alone on the fixture inputs with the kit's exact
# command lines and records a sha256 per output. Task 7 diffs Windows vs Linux.
param([string]$ToolsDir = '', [string]$FfmpegDir = '', [Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'authoring-kit/lib/kitplatform.ps1')
. (Join-Path $root 'authoring-kit/lib/kitconfig.ps1')
. (Join-Path $root 'authoring-kit/lib/kittools.ps1')
$kit = Join-Path $root 'tests/out/kit parity/kit'
$prep = @{ PrepareOnly = $true }
if ($ToolsDir) { $prep.ToolsDir = $ToolsDir }
if ($FfmpegDir) { $prep.FfmpegDir = $FfmpegDir }
& (Join-Path $PSScriptRoot 'parity.ps1') @prep | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$t = Resolve-KitTools (Read-KitConfig $kit) $kit
$work = Join-Path $kit 'ab'
New-Item -ItemType Directory -Force $work | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Sha([string]$p) { $h = [Security.Cryptography.SHA256]::Create(); try { return (-join ($h.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('x2') })) } finally { $h.Dispose() } }
function Abs([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p } else { return Join-Path $kit $p } }
# Runs in $Cwd (gfx2next writes beside the cwd; ndrc resolves #include from it).
function Run([string]$Tool, [string]$Case, [string]$Exe, [string[]]$ToolArgs, [string]$Cwd, [string]$Produced) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { Push-Location $Cwd; & $Exe @ToolArgs *> $null } finally { Pop-Location; $ErrorActionPreference = $eap }
    $p = Join-Path $Cwd $Produced
    if (Test-Path -LiteralPath $p) { $lines.Add("$Tool $Case $(Sha $p)") } else { $lines.Add("$Tool $Case MISSING") }
}
$gfx = Abs $t.GFX; $s2a = Abs $t.S2A; $s2e = Abs $t.S2E; $s2y = Abs $t.S2Y; $ndrc = Abs $t.NDRC
$missing = @(@($gfx, $s2a, $s2e, $s2y, $ndrc) | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    foreach ($p in $missing) { Write-Host "tools-ab: tool missing: $p" }
    exit 2
}
Run 'gfx2next' 'bitmap' $gfx @('-bitmap', '-pal-embed', (Join-Path $kit 'IMAGES/001.png')) $work '001.nxi'
Run 'gfx2next' 'bitmap-zx0' $gfx @('-bitmap', '-pal-embed', '-zx0', (Join-Path $kit 'IMAGES/002.png')) $work '002.nxi.zx0'
Run 'gfx2next' 'pointer' $gfx @('-sprites', '-pal-std', '-pal-none', (Join-Path $kit 'IMAGES/POINTER.png')) $work 'POINTER.spr'
Run 'gfx2next' 'sheet' $gfx @('-sprites', '-pal-none', (Join-Path $kit 'IMAGES/SPRITES/002.png')) $work '002.spr'
Run 'gfx2next' 'font-tiles' $gfx @('-colors-4bit', '-tile-size=8x8', '-pal-none', (Join-Path $kit 'IMAGES/001.png')) $work '001.nxt'
Run 'SongToAky' 'd800' $s2a @('-bin', '--encodingAddress', '0xD800', (Join-Path $kit 'AUDIO/PARITY.aks'), (Join-Path $work 'song.aky')) $work 'song.aky'
Run 'SongToAky' 'c000' $s2a @('-bin', '--encodingAddress', '0xC000', (Join-Path $kit 'AUDIO/PARITY.aks'), (Join-Path $work 'intro.aky')) $work 'intro.aky'
Run 'SongToSoundEffects' 'd000' $s2e @('-bin', '--encodingAddress', '0xD000', (Join-Path $kit 'AUDIO/PARITY_FX.aks'), (Join-Path $work 'fx.sfb')) $work 'fx.sfb'
Run 'SongToYm' 'p1' $s2y @('--forcedPsgFrequency', 'specNext', '-p', '1', '-n', (Join-Path $kit 'AUDIO/STREAM_001.aks'), (Join-Path $work 'stream.ym')) $work 'stream.ym'
Run 'ndrc' 'parity' $ndrc @('nextdaad', 'EN', 'PARITY.DSF', (Join-Path $work 'PARITY.DDB'), '-v3', '-auto-tokens') $kit 'ab/PARITY.DDB'
[IO.File]::WriteAllText($Out, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Write-Host "tools-ab: $($lines.Count) lines -> $Out"
exit 0
