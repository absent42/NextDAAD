# NextDAAD authoring kit - video cutscene encode pass (NXV v2, SP15).
# Called by lib\video.bat (cwd = kit root) BEFORE its staging pass.
# Encodes VIDEO\NNN.mp4 -> VIDEO\NNN.vid via lib\videnc whenever the
# .vid is stale: missing, older than its .mp4, or its cached ARGUMENT
# VECTOR (shape/fps/options - see below) no longer matches the current
# CONFIG.BAT. The .vid beside the source is the encode cache - BUILD.BAT
# wipes RELEASE\, not VIDEO\, so a slow encode runs once per source/
# config change, not once per build. Cache identity is a sidecar file,
# VIDEO\NNN.vid.args, holding an 8-hex-char hash of the exact videnc
# argument list used for that video's last successful encode; changing
# VIDASPECT/VIDFPS/VIDOPTS/VIDOPTS_NNN changes the hash and forces a
# re-encode automatically - nothing to delete by hand. Shape and options
# come from CONFIG.BAT:
#   VIDASPECT   - shape for every encode: a preset (full 16:9 scope
#                 classic classic-wide), an explicit WIDTHxHEIGHT
#                 (width 256 or 320), or a bare display-aspect number
#                 (e.g. 2.35, or 2,35 in a comma-decimal locale) for a
#                 derived free height at 320 wide. Blank = full (320x256).
#   VIDFPS      - frames per second. Blank = 25 (the encoder default).
#   VIDOPTS     - extra videnc options for every encode. --retime lives
#                 here: the Next composites at 50 Hz so 25 fps is the
#                 only cadence-clean rate, and any source that is not
#                 already at VIDFPS is BLENDED to it automatically (SP17
#                 T0). VIDOPTS=--retime drop restores the old nearest-
#                 frame behaviour; --retime mci opts into motion-
#                 compensated interpolation for slow pans/zooms. Like
#                 every option here it is part of the hashed argument
#                 vector below, so changing it re-encodes that title.
#                 --tile-slack (SP17, opt-in, default off) also lives
#                 here, and is the clearest case for VIDOPTS_NNN rather
#                 than VIDOPTS: it lets the budget-bound tile schedule
#                 take a one-row/one-column rung instead of the
#                 four-line band when that costs a little more streaming
#                 supply, which measurably helps 320-wide pans and zooms
#                 and does nothing for quiet material. Try
#                 VIDOPTS_NNN=--tile-slack 0.15 on a moving title and
#                 read the encoder's 'tile-slack:' line for what it
#                 cost. Same hashing rule as everything else - setting
#                 or changing it re-encodes that title and nothing else.
#   VIDOPTS_NNN - extra options for video NNN only (3-digit number),
#                 appended AFTER VIDOPTS. For most repeated options
#                 videnc takes the last occurrence, so VIDOPTS_NNN wins
#                 over VIDOPTS - EXCEPT --aspect, which videnc always
#                 takes over --shape regardless of argument order,
#                 breaking that rule for the shape/aspect pair. This
#                 script works around it: a VIDOPTS_NNN that itself sets
#                 --shape/--width/--aspect suppresses VIDASPECT's own
#                 shape/aspect args for that video, so per-video config
#                 always wins for shape.
#   VIDPROFILE  - DEPRECATED v1 name, honored one release: n0-n4 map
#                 to the nearest v2 shape (and, when VIDFPS is blank,
#                 the nearest legal fps for that v1 profile's own baked
#                 rate) when VIDASPECT is blank.
# The streaming --stream-budget is DERIVED per clip by videnc itself
# (SP17 T1) - nothing here sets one, and a VIDOPTS/VIDOPTS_NNN that does
# overrides that search. An encode no budget can make feasible is still
# REFUSED by videnc's supply gates with a message naming the remedies
# that remain (smaller shape, lower fps, --mono) - fix the config and
# rebuild. Requires ffmpeg
# (tools\ffmpeg\bin\ffmpeg.exe - see tools\README.txt); nothing here
# is needed unless numeric-named .mp4 files exist in VIDEO\.

$sources = @(Get-ChildItem 'VIDEO\*.mp4' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^\d+$' })
if (-not $sources) { exit 0 }

# Encoder GENERATION stamp, salted into the sidecar hash below. The
# arg-vector hash alone cannot see encoder-INTERNAL output changes (the
# gap115 lesson: a re-tuned constant re-shapes the bytes with an
# identical CLI), so bump this string whenever nxv2enc.py changes what
# it emits for unchanged args - same discipline as build-tests.ps1's
# $vidLegSettlementTag. 'pal9' = the 2026-07-27 palette-collapse fix
# (display-lattice palettes + true 9th blue bit + ordered dither);
# 'pal9b' = the palette-lattice review fix-wave (2026-07-27): nearest-
# level lattice snap (was truncating) + corrected DITHER_AMP (was ~12%
# narrow); 'pal9c' = the 2026-07-28 blue-noise dither wave: 32x32
# void-and-cluster threshold tile replaces 8x8 Bayer AND the default
# dither amplitude drops to 0.5 of a quantization step (videnc
# --dither sets it per encode; a --dither in VIDOPTS/VIDOPTS_NNN is
# part of the hashed arg list below, so per-title overrides re-encode
# on change - this stamp covers the DEFAULT-args output change);
# 'pal9d' = the 2026-07-28 transparency-collision exclusion: palette
# entries whose RRRGGGBB byte packs to $FE (the player's NR $14 global
# transparency colour) punched transparent holes on real hardware -
# the two colliding lattice points are now unrepresentable.
# the two colliding lattice points are now unrepresentable;
# 'pal9e' = SP17 T1 auto-budget (2026-07-28): --stream-budget now
# DEFAULTS to a derived value instead of 1.0, so an encode with an
# unchanged argument vector and no explicit budget can emit different
# bytes than it did before (any streaming clip whose utilization at the
# full budget sat between the 0.90 target and the 1.00 refusal line now
# re-derives down to the target). Resident-sized clips are unaffected -
# the search returns the ceiling on its first probe.
# 'pal9f' = the SP17 copy-DMA T-model restoration: _cost_copy_chunk now
# prices a copy body as min(LDI, mem-to-mem DMA) using the task-2
# settlement's 1091.8 T/chunk + 5.31 T/B, gated on the player's own
# NXV2_COPY_DMA_MIN (90 B) kernel-select rule. Copy was previously
# priced entirely as LDI (~2.1x over-price at 256 B) on the dominant op
# class, so the per-frame decode-T cap admits more work per frame and
# streamed encodes emit different bytes.
# 'pal9g' = the 2026-07-28 DMA threshold derivation: both PLAYER kernel
# thresholds were re-derived from the task-2 coefficients and moved
# (NXV2_RUN_DMA_MIN 64 -> 71, NXV2_COPY_DMA_MIN 90 -> 74), and the
# encoder mirrors moved with them (copy_dma_min 90 -> 74, new
# run_dma_min, _fill_t now chunk-and-gates like _copy_t instead of
# taking a whole-length min). Copies in the 74-89 B band and every
# multi-chunk fill re-price, so the per-frame T budget admits a
# different amount of work and encodes emit different bytes.
# NO BUMP for the SP17 Yliluoma wave (2026-07-28), deliberately: that
# wave ADDED an opt-in dither (videnc --dither-mode mixture, plus the
# gamma-correct mixing and luminance-weighted colour metric it needs)
# and changed NOTHING on the default path. Verified, not assumed: the
# leg fixtures re-encode SHA256-identical to the pre-wave encoder for
# the same arguments. --dither-mode is part of the hashed argument list
# below, so a title that opts in re-encodes on that alone. Bumping here
# would have forced every cached title to re-encode for no byte change.
# BUMP pal9g -> pal9h (Card #8 silicon re-fit, 2026-07-28): the
# composition factors moved on measured silicon (flat 1.00 -> 1.14,
# gapped 1.15 -> 1.41) and the streaming supply gate's busy term was
# corrected to true decode wall time with the omitted AUDIO phase
# added. Both change the per-frame T cap and the operating point a
# streamed encode is admitted at, so every cached encode re-prices.
# BUMP pal9h -> pal9i (SP17 T0 source retiming, 2026-07-30): a source
# whose own frame rate differs from the target is now BLENDED to the
# target rate instead of having frames dropped/duplicated by nearest-
# frame selection. Default-path change with no CLI argument in sight, so
# every cached encode of a 23.976/24/29.97/30 source re-encodes. Titles
# whose sources are already 25p are NOT affected - the retiming filter
# is skipped entirely at the target rate and those encodes are
# byte-identical (verified: tools\demo-files\1920x1080-25p.mp4 at
# --shape classic re-encodes to the same SHA256 as the pre-wave
# encoder). --retime drop restores the old behaviour per title.
# BUMP pal9i -> pal9j (SP17 adaptive tile ladder, 2026-07-30): the
# budget-bound delta schedule no longer spends on a FIXED tile. It walks
# {32,64,128,256,band} per bound frame and keeps the finest rung that
# still spends >= 99% of the best rung's bytes (nxv2enc TILE_LADDER /
# TILE_SPEND_FRAC), and band importance is raw err2 instead of
# sqrt(err2). Owner-approved on a hardware A/B (both arms clean
# transport, zero underruns; boat pan and church zoom both better than
# the fixed schedule). Default-path change with no CLI argument, so
# every cached encode with a budget-bound frame re-encodes.
# BUMP pal9j -> pal9k (adaptive tile ladder RE-CUT, 2026-07-30): owner
# silicon on the next sitting called fixture 007 (classic 256x192, mode-0)
# "lots of displacement and tearing" on a completely clean transport - the
# pal9j ladder took rungs FINER THAN ONE PAINT-ORDER LINE, which fragments
# a row into independently-aged pieces, and the decode-T that fragmentation
# costs was charged by the supply gate, so the auto-budget search cut 007
# from 0.64 to 0.47 and 19% of its wire with it. Two rules replace the one:
# the ladder now walks WHOLE LINES only (1/2/4 of them = quarter/half/whole
# band, so (256,512,1024) on the 256-line shapes, (192,384,768) on 16:9,
# (144,288,576) on scope), and a finer rung must preserve the frame's
# modelled SUPPLY COST - the gate's own busy+wire prices - not just its
# bytes. Default-path change with no CLI argument, so every cached encode
# with a budget-bound frame re-encodes.
# NO BUMP for the SP17 supply-slack knob (2026-07-30), deliberately -
# same discipline as the Yliluoma wave above. It ADDED an opt-in option
# (videnc --tile-slack, default 0.0 = off) and changed NOTHING on the
# default path: the default resolves to a supply allowance of exactly
# 0.0, so the ladder's ceiling arithmetic is bit-for-bit what it was.
# Verified, not assumed - all 11 leg/long fixtures re-encode
# SHA256-identical to the pre-knob encoder for the same arguments.
# --tile-slack is part of the hashed argument list below, so a title
# that opts in re-encodes on that alone; bumping here would have forced
# every cached title to re-encode for no byte change.
# BUMP pal9k -> pal9l (SP17 T8 wave copy-DMA threshold correction,
# 2026-08-01): the PLAYER's NXV2_COPY_DMA_MIN moved 74 -> 81 (NXBC
# C073/C074 silicon: the kernel-only derivation missed the +128 T/op
# fast-handler -> slow-body path difference; measured break-even 81.4)
# and the encoder mirror moved with it (copy_dma_min 74 -> 81 plus the
# new copy_dma_path_t term in _copy_t), so copies in the 74-80 B band
# re-price as LDI and every DMA-path copy op carries the path term -
# the per-frame decode-T budget admits a different amount of work and
# streamed encodes emit different bytes for unchanged args.
$encoderGeneration = 'pal9l'

function Get-ArgHash([string[]]$argList) {
    $joined = ((@($encoderGeneration) + $argList) -join ' ')
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
    } finally {
        $md5.Dispose()
    }
    return (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
}

# Shape resolution: VIDASPECT wins; a set-but-unmapped VIDPROFILE is a
# deprecation shim (v1 kit name, one release). Blank = the encoder's
# default shape (full, 320x256).
$shapeArgs = @()          # --shape or --aspect (global, VIDASPECT-derived)
$profileFpsArg = $null    # VIDPROFILE's own mapped fps, used only if VIDFPS is blank
$aspect = $env:VIDASPECT
if (-not $aspect -and $env:VIDPROFILE) {
    $map = @{ n0 = 'full'; n1 = 'classic'; n2 = 'classic-wide';
              n3 = '16:9'; n4 = 'scope'; auto = '' }
    # v1's own baked fps per profile (CHANGELOG.md: N0 12.5, N1 20,
    # N2 25, N3 16.67, N4 20) - respected here so an old VIDPROFILE
    # config does not silently jump to v2's 25fps default and risk a
    # gate refusal from a now-illegal fps.
    $profileFps = @{ n0 = 12.5; n1 = 20; n2 = 25; n3 = 16.67; n4 = 20 }
    $prof = $env:VIDPROFILE.ToLower()
    if ($map.ContainsKey($prof)) {
        $aspect = $map[$prof]
        $shapeNote = "shape '$(if ($aspect) { $aspect } else { 'full' })'"
        if (-not $env:VIDFPS -and $profileFps.ContainsKey($prof)) {
            # Channel count is only known globally at this point (VIDOPTS,
            # not any per-video VIDOPTS_NNN) - good enough for a one-release
            # deprecation shim; set VIDFPS explicitly if a per-video --mono
            # override needs a different floor than this global guess.
            $mono = $env:VIDOPTS -match '(^|\s)--mono(\s|$)'
            # SP17 T10 circular-feed floors (nxv2enc.min_fps_for):
            # stereo 12.28, mono 9.17 (were 24.40 / 18.22 with the old
            # double-buffer halves). Every v1 profile rate (12.5-25)
            # now sits above both floors, so the raise below is a
            # no-op shim kept for safety against future floor moves.
            $floor = if ($mono) { 9.17 } else { 12.28 }
            $orig = $profileFps[$prof]
            $profileFpsArg = if ($orig -lt $floor) { $floor } else { $orig }
            $fpsNote = if ($orig -lt $floor) {
                "fps $profileFpsArg (v1 $prof was ${orig}fps, below the $(if ($mono) { 'mono' } else { 'stereo' }) floor $floor - raised to it)"
            } else {
                "fps $profileFpsArg (v1 $prof's own rate)"
            }
            Write-Host "  note: VIDPROFILE is deprecated (v1 profiles are gone) - using $shapeNote and $fpsNote; set VIDASPECT/VIDFPS instead"
        } else {
            Write-Host "  note: VIDPROFILE is deprecated (v1 profiles are gone) - using $shapeNote; set VIDASPECT instead"
        }
    } else {
        Write-Host "ERROR: VIDPROFILE '$($env:VIDPROFILE)' unknown (and deprecated) - set VIDASPECT instead (see CONFIG.BAT)"
        exit 1
    }
}
if ($aspect) {
    if ($aspect -match '^(full|16:9|scope|classic|classic-wide)$') {
        $shapeArgs = @('--shape', $aspect)             # preset name
    } elseif ($aspect -match '^\d{2,4}x\d{1,4}$') {
        $shapeArgs = @('--shape', $aspect)             # WIDTHxHEIGHT
    } elseif ($aspect -match '^\d+([.,]\d+)?$') {
        # bare number = display aspect, free height at 320 wide; comma
        # (comma-decimal locales) normalized to dot for the encoder
        $shapeArgs = @('--aspect', ($aspect -replace ',', '.'))
    } else {
        Write-Host "ERROR: VIDASPECT '$aspect' not understood - accepted forms: a preset (full, 16:9, scope, classic, classic-wide), an explicit WIDTHxHEIGHT (e.g. 320x150), or a decimal aspect ratio (e.g. 2.35 or 2,35)"
        exit 1
    }
}
$fpsArgs = @()
if ($env:VIDFPS) {
    $fpsArgs = @('--fps', $env:VIDFPS)
} elseif ($profileFpsArg) {
    # Invariant-culture string: $profileFpsArg is a computed [double]
    # (9.17/12.28 or a v1 profile rate) - on a comma-decimal system its
    # default ToString would emit "24,4" and break videnc's own --fps
    # parsing, the same locale pitfall VIDASPECT's comma form works
    # around above.
    $fpsArgs = @('--fps', $profileFpsArg.ToString([System.Globalization.CultureInfo]::InvariantCulture))
}

# Extra options: VIDOPTS (every encode) then VIDOPTS_NNN (that video
# only) - appended after the shape args, below, per video.
$globalOpts = @()
if ($env:VIDOPTS) { $globalOpts = @($env:VIDOPTS -split '\s+' | Where-Object { $_ }) }

# Build each source's effective argument vector (used both to decide
# whether the cache is stale and, unchanged, to invoke the encoder) and
# check it against the mtime + sidecar-hash cache.
$plan = @()
foreach ($src in $sources) {
    $vid = [IO.Path]::ChangeExtension($src.FullName, 'vid')
    $sidecar = "$vid.args"
    $num3 = '{0:D3}' -f [int]$src.BaseName
    $perOpts = @()
    $perRaw = [Environment]::GetEnvironmentVariable("VIDOPTS_$num3")
    if ($perRaw) { $perOpts = @($perRaw -split '\s+' | Where-Object { $_ }) }

    # A per-video --shape/--width/--aspect must win outright over
    # VIDASPECT - videnc's own "later wins" rule does not hold for the
    # shape/aspect pair (see header comment), so suppress the global
    # shape args here rather than relying on argument order.
    $perHasShape = ($perOpts -contains '--shape') -or ($perOpts -contains '--width') -or ($perOpts -contains '--aspect')
    $effShapeArgs = if ($perHasShape) { @() } else { $shapeArgs }
    $videoArgs = @($effShapeArgs + $fpsArgs + $globalOpts + $perOpts)
    $hash = Get-ArgHash $videoArgs

    $stale = $false
    if (-not (Test-Path $vid)) {
        $stale = $true
    } elseif ((Get-Item $vid).LastWriteTime -lt $src.LastWriteTime) {
        $stale = $true
    } elseif (-not (Test-Path $sidecar)) {
        $stale = $true
    } else {
        $prevHash = (Get-Content -Raw -ErrorAction SilentlyContinue $sidecar)
        if (-not $prevHash -or $prevHash.Trim() -ne $hash) { $stale = $true }
    }
    if ($stale) {
        $plan += [PSCustomObject]@{
            Src = $src; Vid = $vid; Sidecar = $sidecar
            Args = $videoArgs; Hash = $hash; PerRaw = $perRaw; Num3 = $num3
        }
    }
}
if (-not $plan) { exit 0 }

$ffmpeg = Join-Path $env:TOOLSDIR 'ffmpeg\bin\ffmpeg.exe'
if (-not (Test-Path $ffmpeg)) {
    Write-Host "ERROR: ffmpeg not found at $ffmpeg (needed to encode VIDEO\*.mp4)"
    Write-Host "       Download it - see tools\README.txt - or pre-encode to .vid"
    exit 1
}

# Encoder resolution: the standalone videnc.exe (SHIPPED with the kit -
# no Python needed, the normal authoring path) is preferred; the
# lib\videnc.py script (Python 3 + Pillow + numpy) is the fallback for
# anyone who has Python anyway or wants to modify the encoder.
# videnc.exe is probed in BOTH tool locations: the configured TOOLSDIR
# and the kit's own tools\ (a TOOLSDIR override - e.g. the maintainer's
# CONFIG.local.BAT pointing at the repo toolchain - must not hide the
# kit-slot exe). Python candidates are probed for BOTH Pillow and numpy
# (both are hard dependencies of nxv2enc.py - see videnc-README.md), not
# mere presence: py -3 and python can be different installs, and picking
# one missing either package fails mid-encode.
$kitRoot = Split-Path -Parent $PSScriptRoot
$enc = $null
$exeCandidates = @(
    (Join-Path $env:TOOLSDIR 'videnc\videnc.exe'),
    (Join-Path $kitRoot 'tools\videnc\videnc.exe')
)
foreach ($exe in $exeCandidates) {
    # >1MB check: a clone made without git-lfs leaves a tiny text
    # POINTER file at this path, not the real (26MB) binary - skip it
    # and fall through to the Python script rather than "running" text.
    if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 1MB) { $enc = @($exe); break }
}
if (-not $enc) {
    foreach ($cand in @(@('py', '-3'), @('python'))) {
        try {
            & $cand[0] $cand[1..($cand.Length)] -c 'import PIL, numpy' *> $null
            if ($LASTEXITCODE -eq 0) { $enc = $cand + 'lib\videnc.py'; break }
        } catch {}
    }
}
if (-not $enc) {
    Write-Host 'ERROR: no encoder for VIDEO\*.mp4 - videnc.exe not found and no Python 3 with Pillow + numpy'
    Write-Host "       Easiest: download videnc.exe into $($exeCandidates[-1]) (see tools\README.txt)"
    Write-Host '       Or install Python 3 (https://www.python.org/) plus: pip install Pillow numpy'
    exit 1
}

foreach ($item in $plan) {
    $src = $item.Src
    $vid = $item.Vid
    $desc = ($item.Args -join ' ')
    if (-not $desc) { $desc = 'defaults: full 320x256 @25' }
    if ($item.PerRaw) {
        Write-Host "  $($item.Num3): applying VIDOPTS_$($item.Num3)=$($item.PerRaw)"
    }
    Write-Host "  encoding $($src.Name) -> $([IO.Path]::GetFileName($vid)) ($desc)"
    $encArgs = $item.Args
    & $enc[0] $enc[1..($enc.Length)] $src.FullName $vid --ffmpeg $ffmpeg @encArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: videnc failed on $($src.Name)"
        if (Test-Path $vid) { Remove-Item $vid -Force }
        if (Test-Path $item.Sidecar) { Remove-Item $item.Sidecar -Force }
        exit 1
    }
    Set-Content -Path $item.Sidecar -Value $item.Hash -NoNewline
}
exit 0
