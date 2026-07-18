# authoring-kit/lib/aysconv.ps1
#
# Converts an Arkos Tracker 3 song (.aks) into a NextDAAD AYS stream: a
# flat per-frame AY-register-diff stream, played back by DMA-streaming
# frames from SD card rather than holding the whole song resident in a
# fixed RAM bank the way lib/audio.bat's AKY songs are. AYS exists for
# songs too big for the AKY song slot (10208 bytes at $D800 - see
# SongToAky's own cap in lib/audio.bat): most real multi-PSG tunes don't
# fit that slot at all. Trades cheap/unbounded SD-card space for the
# fixed RAM ceiling - AYS files are routinely LARGER than an AKY encoding
# of the same song would have been; that is the point, not a regression
# (a tune AKY cannot encode at all has no AKY size to be smaller than).
#
# ---------------------------------------------------------------------
# AYS format v1 - this comment is the format's authoritative spec (Task 3's
# player source matches it exactly):
#
#   Header (16 bytes):
#     db "AYS1"          ; magic
#     db psgCount         ; 1..3
#     db 0                ; flags (reserved, 0)
#     dw frameCount        ; total frames (16-bit: 21.8 min at 50Hz)
#     d24 loopOffset        ; 3 bytes LE: stream byte offset of the loop
#                           ; frame (from stream start, i.e. after header)
#     d24 streamLength       ; 3 bytes LE: total stream bytes
#     db 0,0               ; pad to 16
#   Stream, per frame:
#     per PSG (0..psgCount-1):
#       dw mask           ; 14-bit register change mask (bit r = write
#                          ; register r this frame); bit 15 reserved 0
#                          ; (bit 14 likewise always 0 - AYS only carries
#                          ; registers 0-13; the two AY I/O ports are out
#                          ; of scope)
#       db values[popcount(mask)]  ; register values in ascending r order
#     ; R13 (envelope shape) is IN the mask only on retrigger frames -
#     ; YM's $FF "no write" convention maps to mask bit 13 clear
#   Frame terminator: none needed (masks are self-sizing); frame boundary
#   is implicit after psgCount PSG blocks.
#
#   Reconciliation note: the originating plan text specified the pad as
#   "db 0,0,0" (3 bytes) under a "Header (16 bytes)" label. Every other
#   field width is stated twice (mnemonic + explicit byte count) and those
#   agree with each other; summed with a 3-byte pad the header is 17
#   bytes, not 16. The 2-byte-pad reading is the only one under which
#   every other stated number holds AND the header is the declared 16
#   bytes, so that is what this converter emits (pad = offsets 14-15).
# ---------------------------------------------------------------------
#
# Feedstock: SongToYm.exe (Arkos Tracker 3), run once per PSG:
#   SongToYm --forcedPsgFrequency specNext -p <1|2|3> -n <song.aks> <out.ym>
# Asking for a PSG the song does not have makes SongToYm fail ("There are
# only N PSGs in this subsong.", nonzero exit, no file written) - that
# failure IS how this script detects psgCount, so "run it three times" is
# three ATTEMPTS, not three guaranteed successes: -p 1 is mandatory
# (fatal if it fails - every song has at least one PSG); -p 2 and -p 3
# are tried opportunistically and a failure just caps psgCount at what
# already succeeded.
#
# YM6 layout, as actually observed (Format-Hex on real SongToYm 1.7.x
# output - tools/audio_assets/src/testtune.aks and an Arkos Tracker 3
# bundled song - not transcribed from a spec):
#   0x00  "YM6!"                magic
#   0x04  "LeOnArD!"            check string
#   0x0C  nbFrames              u32 BIG-ENDIAN (YM6 is Atari-ST-derived;
#                                every multi-byte YM header field is BE -
#                                AYS's own fields are Z80-native LE)
#   0x10  attributes            u32 BE - bit0 set = the DEFAULT (no -n)
#                                export; clear = the -n export. Does NOT
#                                mean what the flag names suggest - see
#                                "Interleaving" below.
#   0x14  nbDigidrums           u16 BE (0 for plain PSG songs)
#   0x16  masterClock           u32 BE - observed 1773400 (the standard
#                                Spectrum AY clock) with
#                                --forcedPsgFrequency specNext
#   0x1A  playerFrequency       u16 BE - observed 50 (matches the DAAD/
#                                AYS 50Hz frame rate; comes from the
#                                source song, not forced by any flag used
#                                here - not re-validated per song beyond
#                                the frame-count-agreement check below)
#   0x1C  loopFrame             u32 BE - frame index to loop to. Observed
#                                0 in both songs this script was checked
#                                against (a short test tune and a real
#                                composed multi-minute song) - never seen
#                                nonzero, but the field is unconditionally
#                                present (not an optional/flagged block),
#                                so it is always read and used as-is; 0
#                                already IS "else frame 0", so the "if
#                                present, else frame 0" rule collapses to
#                                one code path in practice.
#   0x20  extraDataSize         u16 BE (0 - no YM6 extension block)
#   0x22  songName,author,comment  three NUL-terminated strings back to
#                                back (variable length) - the register
#                                stream starts right after the third NUL
#   ...   register stream       16*nbFrames bytes
#   last 4 bytes                "End!" trailer
#
# Interleaving (-n): the flag name is backwards from what it implies.
# Confirmed by scanning every candidate byte-plane/byte-slot of both a
# -n and a non--n export of the same song for the R13 signature (a real
# R13 plane is $FF on every frame with no envelope write - $FF is not a
# valid 4-bit envelope shape, so that signature cannot arise by chance).
# Exactly one candidate per file hit it, and cross-checking against
# SongToVgm output on the same song confirmed which register it was:
#   default (no -n, attrib bit0 = 1): PLANE-MAJOR ("de-interleaved") -
#     register r's whole nbFrames-byte run is contiguous:
#       byte at streamStart + r*nbFrames + frame
#   -n (attrib bit0 = 0): FRAME-MAJOR (chronological) - all 16 registers
#     for one frame are contiguous:
#       byte at streamStart + frame*16 + r
# -n's FRAME-MAJOR layout is also what the merge loop wants directly (it
# needs every register of "this frame" together to diff against "last
# frame"), so -n was kept rather than switched to the default.
#
# Merge: per frame, per PSG, each of registers 0-12 is written (mask bit
# set + value emitted) iff its absolute YM byte differs from that
# register's last-written value for that PSG (initial "last-written"
# baseline: all zero except R7=$3F - the silence state audio_init
# leaves). Register 13 is different: it is written iff the YM byte this
# frame is not $FF, regardless of whether the shape value differs from
# before (rewriting the SAME envelope shape still audibly retriggers the
# envelope, so presence, not diffing, is the rule - this is exactly YM's
# own $FF sentinel convention, just carried through unchanged).
#
# Usage: aysconv.ps1 -Song <path to .aks> -Out <path to .AYS>
#                     -SongToYm <path to SongToYm.exe> [-Ceiling <bytes>]
param(
    [Parameter(Mandatory=$true)][string]$Song,
    [Parameter(Mandatory=$true)][string]$Out,
    [Parameter(Mandatory=$true)][string]$SongToYm,
    [int]$Ceiling = 512KB
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Song)) { throw "song not found: $Song" }
if (-not (Test-Path $SongToYm)) { throw "SongToYm not found at $SongToYm - install Arkos Tracker 3 or fix the tool path" }

# Reads one SongToYm -n export and returns its header fields plus the raw
# bytes, ready for FRAME-MAJOR indexing (streamStart + frame*16 + reg).
function Read-AysYm([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 34 -or [System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'YM6!') {
        throw "not a YM6 file (unexpected SongToYm output): $Path"
    }
    $nbFrames = ([int]$b[12] -shl 24) -bor ([int]$b[13] -shl 16) -bor ([int]$b[14] -shl 8) -bor [int]$b[15]
    $loopFrame = ([int]$b[28] -shl 24) -bor ([int]$b[29] -shl 16) -bor ([int]$b[30] -shl 8) -bor [int]$b[31]
    $pos = 34
    for ($i = 0; $i -lt 3; $i++) { while ($b[$pos] -ne 0) { $pos++ }; $pos++ }
    $streamStart = $pos
    $expectedLen = $streamStart + 16 * $nbFrames + 4
    if ($b.Length -ne $expectedLen) {
        throw "unexpected YM6 length in '$Path': $($b.Length) bytes, expected $expectedLen (streamStart=$streamStart nbFrames=$nbFrames) - SongToYm output shape may have changed"
    }
    return [PSCustomObject]@{ Bytes = $b; StreamStart = $streamStart; NbFrames = $nbFrames; LoopFrame = $loopFrame }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aysconv_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    # SongToYm's own stdout/stderr is deliberately left unredirected (not
    # 2>&1-merged) and just prints straight through, same as audio.bat's
    # other tool calls (SongToAky/SongToSoundEffects) - merging stderr
    # into the pipeline while $ErrorActionPreference='Stop' is active
    # turns every stderr line into a terminating NativeCommandError,
    # which pre-empts the clearer throw messages below with a raw
    # exception dump. $LASTEXITCODE alone drives control flow here.

    # -p 1 is mandatory - every song has at least one PSG.
    $ym1 = Join-Path $tmp 'p1.ym'
    & $SongToYm --forcedPsgFrequency specNext -p 1 -n $Song $ym1
    if ($LASTEXITCODE -ne 0) { throw "SongToYm failed for PSG 1 (mandatory) on '$Song' (see output above)" }
    $ymFiles = @( (Read-AysYm $ym1) )
    $psgCount = 1

    # -p 2 / -p 3 are opportunistic: SongToYm fails cleanly when a song
    # does not have that many PSGs, and that failure is how psgCount
    # (1..3) is detected rather than being asked for up front.
    $ym2 = Join-Path $tmp 'p2.ym'
    & $SongToYm --forcedPsgFrequency specNext -p 2 -n $Song $ym2
    if ($LASTEXITCODE -eq 0) {
        $ymFiles += Read-AysYm $ym2
        $psgCount = 2
        $ym3 = Join-Path $tmp 'p3.ym'
        & $SongToYm --forcedPsgFrequency specNext -p 3 -n $Song $ym3
        if ($LASTEXITCODE -eq 0) {
            $ymFiles += Read-AysYm $ym3
            $psgCount = 3
        }
    }

    $counts = @($ymFiles | ForEach-Object { $_.NbFrames })
    if (@($counts | Select-Object -Unique).Count -ne 1) {
        throw "YM frame counts disagree across PSGs for '$Song': $($counts -join ', ') - cannot merge (a per-PSG export desync in the source song)"
    }
    $nbFrames = $counts[0]
    if ($nbFrames -gt 65535) {
        throw "'$Song' is $nbFrames frames (~$([Math]::Round($nbFrames/50/60,1)) min at 50Hz), exceeds the AYS 16-bit frameCount limit (65535 frames, ~21.8 min) - trim the song"
    }

    $loopFrameIdx = $ymFiles[0].LoopFrame
    $loopSource = "YM loop-frame attribute (frame $loopFrameIdx)"
    if ($loopFrameIdx -lt 0 -or $loopFrameIdx -ge $nbFrames) {
        $loopSource = "YM loop-frame attribute out of range ($loopFrameIdx) - fell back to frame 0"
        $loopFrameIdx = 0
    }

    # Merge: per frame, per PSG, diff registers 0-12 against that PSG's
    # last-written value (baseline: all zero, R7=$3F); R13 is written iff
    # the YM byte this frame is not $FF (see header comment). Stream is
    # self-sizing (mask bytes carry their own value count), so a single
    # growable list built in one frame-major pass is enough.
    $maxSize = 16 * $nbFrames * $psgCount
    $stream = New-Object 'System.Collections.Generic.List[byte]' ($maxSize)
    $prev = New-Object 'byte[,]' $psgCount, 13
    for ($ps = 0; $ps -lt $psgCount; $ps++) { $prev[$ps, 7] = 0x3F }
    $loopOffset = 0

    for ($f = 0; $f -lt $nbFrames; $f++) {
        if ($f -eq $loopFrameIdx) { $loopOffset = $stream.Count }
        for ($ps = 0; $ps -lt $psgCount; $ps++) {
            $bytes = $ymFiles[$ps].Bytes
            $base = $ymFiles[$ps].StreamStart + $f * 16
            $mask = 0
            for ($r = 0; $r -le 12; $r++) {
                $cur = $bytes[$base + $r]
                if ($cur -ne $prev[$ps, $r]) {
                    $mask = $mask -bor (1 -shl $r)
                    $prev[$ps, $r] = $cur
                }
            }
            $r13 = $bytes[$base + 13]
            if ($r13 -ne 0xFF) { $mask = $mask -bor (1 -shl 13) }
            $stream.Add([byte]($mask -band 0xFF))
            $stream.Add([byte](($mask -shr 8) -band 0xFF))
            for ($r = 0; $r -le 12; $r++) {
                if (($mask -band (1 -shl $r)) -ne 0) { $stream.Add($bytes[$base + $r]) }
            }
            if (($mask -band (1 -shl 13)) -ne 0) { $stream.Add($r13) }
        }
    }

    if ($loopOffset -gt 0xFFFFFF -or $stream.Count -gt 0xFFFFFF) {
        throw "'$Song' merged stream is too large for a 24-bit offset ($($stream.Count) bytes) - trim the song"
    }
    $streamLength = $stream.Count

    $header = New-Object byte[] 16
    [System.Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('AYS1'), 0, $header, 0, 4)
    $header[4] = [byte]$psgCount
    $header[5] = 0
    $header[6] = [byte]($nbFrames -band 0xFF)
    $header[7] = [byte](($nbFrames -shr 8) -band 0xFF)
    $header[8] = [byte]($loopOffset -band 0xFF)
    $header[9] = [byte](($loopOffset -shr 8) -band 0xFF)
    $header[10] = [byte](($loopOffset -shr 16) -band 0xFF)
    $header[11] = [byte]($streamLength -band 0xFF)
    $header[12] = [byte](($streamLength -shr 8) -band 0xFF)
    $header[13] = [byte](($streamLength -shr 16) -band 0xFF)
    $header[14] = 0
    $header[15] = 0

    $outBytes = New-Object byte[] (16 + $streamLength)
    [System.Array]::Copy($header, 0, $outBytes, 0, 16)
    $stream.CopyTo(0, $outBytes, 16, $streamLength)
    $outDir = Split-Path $Out
    if ($outDir) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    [System.IO.File]::WriteAllBytes($Out, $outBytes)

    $totalBytes = 16 + $streamLength
    if ($totalBytes -gt $Ceiling) {
        Write-Warning "$Out is $totalBytes bytes, exceeds the ceiling ($Ceiling) - the runtime clamps via allocation anyway"
    }
    $seconds = [Math]::Round($nbFrames / 50.0, 2)
    "$Out : psgCount=$psgCount frames=$nbFrames seconds=$seconds streamBytes=$streamLength totalBytes=$totalBytes loop=$loopSource offset=$loopOffset"
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
