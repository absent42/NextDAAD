# Steady-tone WAV generator for the sampled-SFX DI-exposure ear test
# (tests\sfxdi.dsf, run sheet .superpowers\sdd\sfx-di-audible-test.md).
#
# Produces the two stimulus files tests\build-tests.ps1 -SfxDi stages
# into sd\SFXDI\ as
# 001.WAV (16 kHz, the only rate this project has ever shipped) and
# 002.WAV (20 kHz, AUD_RATE_MAX - what README/SETUP.md publish as the
# supported ceiling and what a DAAD-DOS SOUNDS set drops in at).
#
# WHY A TONE AND NOT REAL MATERIAL. The defect under test suppresses CTC
# ticks while dma_copy holds interrupts off, which does not drop, click
# or truncate anything - the DAC simply holds each byte one extra period
# and the effect plays LONG AND FLAT. The only observable is PITCH, so
# the stimulus has to be a steady tone with a pitch to lose. Noise,
# speech and transients carry the same error and show nothing.
#
# THE FORMAT IS THE PLAYED FORMAT. Nothing in the pipeline resamples -
# authoring-kit\lib\audio.bat copies AUDIO\NNN.wav to RELEASE\NNN.WAV
# verbatim, and aud_load_wav (src\overlay1.asm) takes the rate straight
# from the fmt chunk - so the header rate here IS the rate the CTC is
# programmed for. 8-bit unsigned mono is the only shape aud_load_wav
# accepts (PCM tag 1, 1 channel, 8 bits, rate 3500..20000).
#
# THE THREE DELIBERATE CHOICES
#   48000 bytes. SMP_FLOOR_FIRST..SMP_FLOOR_LAST (nextdaad.inc) reserve
#     banks 25-27 so a 48K load ALWAYS succeeds regardless of pool
#     pressure. Sizing the stimulus exactly to that floor means the ear
#     test cannot fail as a staging/allocation problem and be mistaken
#     for an audio result.
#   Whole cycles. 48000 samples at 440 Hz is 1320 whole cycles at
#     16000 Hz and 1056 whole cycles at 20000 Hz - both exact integers,
#     so the payload's last sample runs into its first with no phase
#     step. SFX n 2 (looped) rewinds the source mid-copy and the ring
#     never sees a seam (aud_smp_copy), so the tone is continuous for as
#     long as the leg needs, with no click to be mistaken for an
#     artifact.
#   Centred on 128. DAC_SILENCE is the unsigned midpoint $80 = 128, so
#     the waveform starts, ends and loops at exactly the level the DAC
#     is parked at - no step into or out of the effect. Amplitude 127
#     puts the peaks at 1 and 255: full scale to within 0.07 dB, with no
#     way for a rounding edge to wrap past 0 or 255.
#
# No dither, no fade, no window - deterministic, byte-for-byte
# reproducible from stdlib alone, which is why the WAVs are generated
# here rather than committed (tests\out\ is gitignored, exactly like
# build-tests.ps1's own badwav/truncwav fixtures).
#
# Usage:  python tests\audio\mktone.py <outdir>
#         (default outdir: tests\out)

import math
import os
import struct
import sys

TONE_HZ = 440.0          # A440 - the reference the whole run sheet quotes
PAYLOAD = 48000          # bytes = samples (8-bit mono); the 48K audio floor
CENTRE = 128             # DAC_SILENCE, unsigned midpoint
AMPLITUDE = 127          # peaks land on 1 and 255

# (rate, filename). 16000 is what ships; 20000 is AUD_RATE_MAX.
VARIANTS = [
    (16000, "tone440_16k.wav"),
    (20000, "tone440_20k.wav"),
]


def make_pcm(rate):
    """PAYLOAD bytes of 8-bit unsigned 440 Hz sine, whole cycles only."""
    cycles = TONE_HZ * PAYLOAD / rate
    if abs(cycles - round(cycles)) > 1e-9:
        raise SystemExit(
            "rate %d gives %.6f cycles over %d samples - not a whole "
            "number, the loop would click" % (rate, cycles, PAYLOAD)
        )
    cycles = int(round(cycles))
    # Phase written as cycles*n/N (not TONE_HZ*n/rate) so the period
    # alignment is exact by construction rather than by float luck.
    out = bytearray(PAYLOAD)
    for n in range(PAYLOAD):
        s = math.sin(2.0 * math.pi * cycles * n / PAYLOAD)
        v = int(math.floor(CENTRE + AMPLITUDE * s + 0.5))
        out[n] = 0 if v < 0 else (255 if v > 255 else v)
    return bytes(out), cycles


def make_wav(rate, pcm):
    """Canonical 44-byte RIFF/WAVE header + payload, PCM mono 8-bit."""
    fmt = struct.pack(
        "<4sIHHIIHH",
        b"fmt ", 16,
        1,          # wFormatTag: PCM
        1,          # nChannels: mono
        rate,       # nSamplesPerSec
        rate,       # nAvgBytesPerSec (rate * 1 byte * 1 channel)
        1,          # nBlockAlign
        8,          # wBitsPerSample
    )
    data = struct.pack("<4sI", b"data", len(pcm)) + pcm
    body = b"WAVE" + fmt + data
    return struct.pack("<4sI", b"RIFF", len(body)) + body


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("tests", "out")
    os.makedirs(outdir, exist_ok=True)
    for rate, name in VARIANTS:
        pcm, cycles = make_pcm(rate)
        wav = make_wav(rate, pcm)
        path = os.path.join(outdir, name)
        with open(path, "wb") as f:
            f.write(wav)
        print(
            "%s  %d Hz  %d bytes  %.3f s  %d whole cycles of %g Hz"
            % (name, rate, len(wav), PAYLOAD / float(rate), cycles, TONE_HZ)
        )


if __name__ == "__main__":
    main()
