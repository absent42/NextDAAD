# Steady-tone WAV generator for the sampled-SFX DI-exposure ear test
# (tests\sfxdi.dsf).
#
# Produces the two stimulus files tests\build-tests.ps1 -SfxDi stages
# into sd\SFXDI\ as
# 001.WAV (16 kHz, the only rate this project has ever shipped) and
# 002.WAV (20 kHz, AUD_RATE_MAX - what manualudio.md publishes as the
# supported ceiling and what a DAAD-DOS SOUNDS set drops in at).
#
# WHY A TONE AND NOT REAL MATERIAL: the defect holds each DAC byte one
# extra period (LONG AND FLAT); PITCH is the only observable, so noise,
# speech and transients would show nothing.
#
# THE FORMAT IS THE PLAYED FORMAT: nothing in the pipeline resamples, so
# the header rate here is the rate the CTC is programmed for (8-bit
# unsigned mono, 3500..20000 Hz, the only shape aud_load_wav accepts).
#
# THE THREE DELIBERATE CHOICES:
#   - 48000 bytes: sized to the SMP_FLOOR bank reservation, so the load
#     always succeeds and can't be mistaken for a staging failure.
#   - Whole cycles: 1320 at 16000 Hz, 1056 at 20000 Hz, so the loop seam
#     is phase-exact with no click to mistake for an artifact.
#   - Centred on 128 (DAC_SILENCE), amplitude 127: starts/ends/loops at
#     the DAC's parked level, full scale with no wraparound risk.
#
# Deterministic and reproducible from stdlib alone (no dither/fade/
# window), which is why the WAVs are generated here, not committed.
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
