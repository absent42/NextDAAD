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
#                 --kf-cadence SECONDS (SP17 W4) also lives here: the
#                 keyframe cadence window, default 5 s (a forced full
#                 keyframe when no natural one occurred within it -
#                 measured free in bytes at the default), 0 disables.
#                 --prefilter [FILTER] (SP17 W4, opt-in, default off):
#                 temporal denoise before scaling - source grain is
#                 delta demand the wire pays for every frame; the bare
#                 flag is a conservative hqdn3d. A measured per-title
#                 option, not a default. Both hashed like every other
#                 option.
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
# that remain (smaller shape, lower fps) - fix the config and
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
# NO BUMP for the SP17 T5a offset-copy wave (2026-08-01) - it was an
# opt-in flag that changed NOTHING on the default path - and NO BUMP for
# its REMOVAL (2026-08-02, owner ruling): the flag, the pan detector and
# the pan-span emitter are gone, the default path is unmoved, and the
# retired capability bit is now refused at open by the player.
# BUMP pal9l -> pal9m (SP17 W4 encoder wave, 2026-08-02), ONE bump
# covering every default-path change of the wave:
# - keyframe-span peak pacing (charter E5): span chunks re-priced at
#   the chunked-DMA copy rate and bounded per frame to 0.95 of the
#   frame period at the supply gate's own prices; the delta byte cap
#   is wire-capped the same way - keyframe peaks no longer exceed the
#   wire period at any budget, spans get more/smaller chunks
# - keyframe cadence: a forced keyframe when no natural one occurred
#   within 5 s (videnc --kf-cadence, measured free at the default)
# - drift/staleness triggers re-based on 4x4 local-mean PSNR
#   (corpus-derived STALE_LM_DB 15.0, DRIFT_LM_T 1.5/3.0)
# - the NXBO/NXBC two-key dispatch split (t_op_run 487.2 / t_op_copy
#   336.3, t_skip 141.6/210.7, fill_cpu 16.70, fetch_short 19.80,
#   copy_dma_per_b 5.08), the silicon_r density re-key and the
#   re-derived composition factors (flat 1.19, gapped 1.46)
# Every streamed fixture re-derives its budget (~2-4% tighter);
# resident fixtures re-encode for the trigger/cadence/pacing changes.
# NO bump component for --prefilter (opt-in, default off, byte-
# identical absent - selftest-asserted); it is part of the hashed
# argument list, so a title that opts in re-encodes on that alone (it
# lives in VIDOPTS/VIDOPTS_NNN like --tile-slack). --approx-cuts was
# the wave's other opt-in and was REMOVED on 2026-08-02 (owner ruling,
# A/B verdicts inside the noise floor) - its removal moves no default
# bytes either.
# BUMP pal9m -> pal9n (direct-gate silicon re-fit, 2026-08-02): the
# direct-serve wire gate was re-fitted from the NXBD re-run + the
# 056/057 whole-frame playback pair on the rebuilt T8 transport -
# DIRECT_TRANSPORT_FACTOR 1.20 -> 1.00 (per-byte) plus the new fixed
# DIRECT_FRAME_OVERHEAD_MS 2.2. Delta/streamed encodes and the shipped
# direct fixtures (010/011-class shapes) re-encode byte-identical -
# the gate shapes ADMISSION, not emitted bytes - but the admission
# envelope moved (25 fps stereo 256x133 -> 256x153; 320x256@12.5 now
# admitted), so the era marks which gate an encode was admitted under.
# BUMP pal9n -> pal9o (SP17 W5 cadence rolling refresh, 2026-08-02):
# the cadence path no longer emits a forced keyframe SPAN - owner
# silicon read the span's paced repaint as "a paused frame in the
# middle" of every ~10 s clip (the visible surface HOLDS for the whole
# span until KFLIP; the transport was clean: exact rate, zero
# underruns). It now schedules a ROLLING REFRESH: forced-clean
# coverage of the surface spread across ordinary delta frames inside
# the normal per-frame caps, with carry-over under contention (nxv2enc
# ROLLING REFRESH block). Trigger-forced keyframes (cut/dissolve/
# staleness/drift) are unchanged. Default-path change: any streamed
# clip whose cadence fired (a quiet stretch >= 5 s) emits different
# bytes; clips shorter than the window or cut-dense re-encode
# byte-identical but re-encode anyway because the tag is in their
# cache name.
# BUMP pal9o -> pal9p (SP17 low-fps supply + roll guards, 2026-08-02),
# ONE bump covering both default-path changes of this sitting:
# - LOW-FPS PACE CONTENTION priced in the streamed supply gate. The gate
#   was exactly fps-invariant by construction and its whole silicon
#   calibration is at 25 fps; three 12.5 fps silicon rows ran over rate
#   with ring underruns while it read them 0.89-0.90. Below ~24.6 fps
#   the player's T10 audio feed is room-limited and
#   trickles from the .pace spin, so every produced 512 B block also
#   pays a full vid_aud_pump - unpriced until now (nxv2enc LOW-FPS PACE
#   CONTENTION block). EXACTLY zero at 25 fps, so no 25 fps encode moves
#   by a rounding tick; low-fps STREAMED clips re-derive a lower budget
#   and emit different bytes. Direct-serve is untouched (its own gate,
#   no ring producer - row 057 is silicon-clean at 320x256@12.5).
# - ROLLING REFRESH GUARDS from the corpus sweep (ROLL-SWEEP.md, GO
#   WITH CAVEAT): the roll is now STRICTLY OPPORTUNISTIC - each armed
#   frame is scheduled without it first, and the roll gets only the byte
#   budget motion did not want, so a saturated clip emits the
#   motion-only frame byte for byte (the sweep's three regressions all
#   sit at byte-util p95 0.998-0.999) while the big winners, which
#   refresh out of genuine slack, are unchanged. And a forced position
#   now discharges on "was PAINTED this frame" instead of on exact value
#   equality - the old test stranded any position repainted to a
#   different value and, because roll_pending gates re-arming, one
#   stranded position disabled every later refresh (6 of 47 sweep rows;
#   fixture 009 stranded 12 positions for 124 frames).
#   Default-path change: any clip whose cadence fires emits different
#   bytes; 008/009 are the only shipping fixtures affected.
# BUMP pal9p -> pal9q (SP17 audio ring = the whole audio bank,
# 2026-08-02). The player's circular audio feed ring goes 2560 -> 8192
# bytes - the session audio bank was ALWAYS an exclusive 8 KB page and
# 5632 bytes of it were allocated and idle. That removes the low-fps
# pace contention pal9p had just priced: the next frame's feed now
# completes in the single post-present pump at every legal fps, so
# pace_trickle_frac is identically zero and the gate term it feeds is
# a guard rather than a charge. The declarable per-frame audio bound
# moves 2544 -> 3072 (pinned by the player's 8-bit block arithmetic,
# not by the ring - see nxv2enc's derivation), lowering the fps floors
# to stereo 10.17 / mono 7.60.
# Default-path change: 25 fps encodes are BYTE-IDENTICAL (the term was
# already exactly zero there); STREAMED clips below ~24.6 fps stereo /
# ~18.3 mono re-derive a HIGHER budget - the 7.4-8.9% of the frame the
# contention was charging is handed back to the picture - and emit
# different bytes. AUDIO IS UNCHANGED in every case: same rates, same
# samples/frame, same real and padded sizes, bit-identical payload.
$encoderGeneration = 'pal9q'

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
            # SP17 T10 circular-feed floor (nxv2enc.min_fps_for):
            # 10.17 (2544-byte bound: 12.28; pre-T10 double-buffer
            # halves: 24.40). Every v1 profile rate (12.5-25) sits
            # above it, so the raise below is a no-op shim kept for
            # safety against future floor moves.
            $floor = 10.17
            $orig = $profileFps[$prof]
            $profileFpsArg = if ($orig -lt $floor) { $floor } else { $orig }
            $fpsNote = if ($orig -lt $floor) {
                "fps $profileFpsArg (v1 $prof was ${orig}fps, below the audio floor $floor - raised to it)"
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
    # (7.60/10.17 or a v1 profile rate) - on a comma-decimal system its
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
