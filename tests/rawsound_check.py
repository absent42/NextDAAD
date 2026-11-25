#!/usr/bin/env python3
"""tests/rawsound_check.py - walk a raw NXV clip and assert on its real sound bytes.

python tests\\rawsound_check.py <clip.vid> --expect <mode>
python tests\\rawsound_check.py --selftest

Every mode walks the whole file: flags $13, each frame's sound section
(padded = (real // 512 + 1) * 512), pad bytes $80, tag 0 or 1, the palette
sector when the tag is 1, cap - 1 pixel sectors, and the walk ends at EOF.
RMS is taken about $80 over the real bytes only (pad and tag excluded):
  sound      whole-clip RMS >= 4
  lr         stereo; first half left >= 20 and right <= 2, second half the
             reverse; the loud side's peak is 440 Hz then 880 Hz (+-5 percent)
  monotones  mono; RMS >= 10 in each half; peak 440 Hz then 880 Hz
  silent     every real byte is $80
  beeps      stereo; in each whole second a 1 kHz beep in its first 0.1 s on
             the left (even seconds, from second 0) or the right (odd), the
             beep RMS >= 5 there and <= 1 on the other side, the rest of the
             second <= 1 on both sides
  monobeeps  mono; the same beep each second, RMS >= 2.5, the rest <= 1
Prints the measured values; exit 1 when an assertion fails.
"""
import argparse
import sys
import tempfile
from pathlib import Path

import numpy as np

RATE = 15625
HDR = 512
SILENCE = 0x80


class Clip:
    def __init__(self, path):
        data = Path(path).read_bytes()
        if len(data) < HDR or data[0:5] != b"NXVID":
            raise ValueError("not an NXV file")
        self.flags = data[12]
        if self.flags != 0x13:
            raise ValueError(f"flags {self.flags:#04x}: not a raw clip ($13)")
        self.channels = data[9]
        self.frames = int.from_bytes(data[14:17], "little")
        self.real = int.from_bytes(data[17:19], "little")
        self.cap = int.from_bytes(data[21:23], "little")
        if self.channels not in (1, 2) or not self.real or self.cap < 2:
            raise ValueError(f"channels {self.channels}, sound {self.real}, cap {self.cap}")
        self.section = (self.real // 512 + 1) * 512
        pix = (self.cap - 1) * 512
        pos, snd, self.palettes = HDR, bytearray(), 0
        for f in range(self.frames):
            sec = data[pos:pos + self.section]
            if len(sec) != self.section:
                raise ValueError(f"frame {f}: sound section past EOF")
            pad = sec[self.real:self.section - 1]
            if pad.count(SILENCE) != len(pad):
                raise ValueError(f"frame {f}: pad byte not $80")
            tag = sec[-1]
            if tag not in (0, 1):
                raise ValueError(f"frame {f}: tag {tag}")
            snd += sec[:self.real]
            pos += self.section + tag * 512 + pix
            self.palettes += tag
        if pos != len(data):
            raise ValueError(f"walk ends at {pos}, file is {len(data)} B")
        self.size = len(data)
        s = np.frombuffer(bytes(snd), dtype=np.uint8).astype(np.float64) - SILENCE
        self.sound = s.reshape(-1, self.channels)


def rms(x):
    return float(np.sqrt(np.mean(x * x))) if len(x) else 0.0


def peak_hz(x):
    if len(x) < 64:
        return 0.0
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float(np.fft.rfftfreq(len(x), 1.0 / RATE)[int(np.argmax(spec[1:])) + 1])


def near(hz, want):
    return abs(hz - want) <= 0.05 * want


def check(path, expect):
    """-> (ok, lines)."""
    c = Clip(path)
    out = [f"{Path(path).name}: frames={c.frames} channels={c.channels} sound={c.real} "
           f"section={c.section} palettes={c.palettes} bytes={c.size}"]
    if expect == "layout":
        return True, out
    s = c.sound
    half = (c.frames // 2) * (c.real // c.channels)
    a, b = s[:half], s[half:]
    if expect == "sound":
        v = rms(s)
        out.append(f"  rms={v:.2f} (need >= 4)")
        return v >= 4, out
    if expect == "lr":
        if c.channels != 2:
            out.append("  lr needs a stereo clip")
            return False, out
        al, ar, bl, br = rms(a[:, 0]), rms(a[:, 1]), rms(b[:, 0]), rms(b[:, 1])
        fa, fb = peak_hz(a[:, 0]), peak_hz(b[:, 1])
        out.append(f"  first half: left rms={al:.2f} right rms={ar:.2f} left peak={fa:.0f} Hz")
        out.append(f"  second half: left rms={bl:.2f} right rms={br:.2f} right peak={fb:.0f} Hz")
        ok = al >= 20 and ar <= 2 and br >= 20 and bl <= 2 and near(fa, 440) and near(fb, 880)
        return ok, out
    if expect == "monotones":
        if c.channels != 1:
            out.append("  monotones needs a mono clip")
            return False, out
        va, vb = rms(a[:, 0]), rms(b[:, 0])
        fa, fb = peak_hz(a[:, 0]), peak_hz(b[:, 0])
        out.append(f"  first half rms={va:.2f} peak={fa:.0f} Hz; second half rms={vb:.2f} peak={fb:.0f} Hz")
        return va >= 10 and vb >= 10 and near(fa, 440) and near(fb, 880), out
    if expect == "silent":
        loud = int(np.count_nonzero(s))
        out.append(f"  bytes off $80: {loud}")
        return loud == 0, out
    if expect in ("beeps", "monobeeps"):
        want = 2 if expect == "beeps" else 1
        if c.channels != want:
            out.append(f"  {expect} needs {want} channel(s)")
            return False, out
        return beeps(s, out)
    raise ValueError(f"unknown --expect {expect}")


def beeps(s, out):
    """One 1 kHz beep in the first 0.1 s of every whole second: stereo starts left
    and alternates, mono is the beep on its one channel."""
    stereo = s.shape[1] == 2
    secs, head = len(s) // RATE, RATE // 10
    ok, sides, on_min, off_max, quiet_max, hz = secs >= 2, "", 1e9, 0.0, 0.0, []
    for k in range(secs):
        w = s[k * RATE:(k + 1) * RATE]
        r, q = w[:head], w[head:]
        lv = [rms(r[:, ch]) for ch in range(s.shape[1])]
        side = int(np.argmax(lv))
        sides += ("LR"[side] if stereo else "M")
        on_min = min(on_min, lv[side])
        if stereo:
            off_max = max(off_max, lv[1 - side])
            ok &= side == k % 2
        quiet_max = max(quiet_max, max(rms(q[:, ch]) for ch in range(s.shape[1])))
        hz.append(peak_hz(r[:, side]))
    need = 5 if stereo else 2.5
    ok &= on_min >= need and off_max <= 1 and quiet_max <= 1 and all(near(f, 1000) for f in hz)
    out.append(f"  seconds={secs} sides={sides} beep rms min={on_min:.2f} (need >= {need})"
               + (f" other side max={off_max:.2f}" if stereo else "")
               + f" rest max={quiet_max:.2f} peaks {min(hz):.0f}-{max(hz):.0f} Hz")
    return ok, out


def synth(path, channels, frames, gen):
    """Write a tiny raw clip (256x2, 25 fps) whose real sound is gen(frame, n, channels)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"))
    import nxv2enc
    _rate, samples, real, padded = nxv2enc.audio_layout(25, channels, raw=True)
    hdr = nxv2enc.pack_header(width=256, height=2, fps=25, channels=channels, arate=RATE,
                              frame_count=frames, audio_bytes_per_frame=real,
                              ring_start_margin_blocks=2, per_frame_cap_blocks=2,
                              flags=0x13, raw_width=256)
    body = bytearray(hdr)
    for f in range(frames):
        body += nxv2enc.emit_raw_frame(gen(f, samples, channels), padded, bytes(512),
                                       bytes(512) if f == 0 else None)
    Path(path).write_bytes(bytes(body))


def tone(hz, f, n):
    t = (np.arange(n) + f * n) / RATE
    return np.round(SILENCE + 64 * np.sin(2 * np.pi * hz * t)).astype(np.uint8)


def selftest():
    frames = 50
    silent = lambda f, n, ch: bytes([SILENCE]) * (n * ch)

    def lr(f, n, ch, swap=False):
        z = np.full(n, SILENCE, np.uint8)
        left, right = (tone(440, f, n), z) if f < frames // 2 else (z, tone(880, f, n))
        if swap:
            left, right = right, left
        return np.stack([left, right], axis=1).tobytes()

    mono = lambda f, n, ch: tone(440 if f < frames // 2 else 880, f, n).tobytes()

    def beep(f, n, ch, first=0):
        # 40 ms of 1 kHz at amplitude 23 from 21 ms into each second
        t = np.arange(f * n, (f + 1) * n)
        sec, ofs = t // RATE, t % RATE
        on = (ofs >= 333) & (ofs < 958)
        v = np.where(on, np.round(SILENCE + 23 * np.sin(2 * np.pi * 1000 * t / RATE)), SILENCE)
        v = v.astype(np.uint8)
        if ch == 1:
            return v.tobytes()
        z = np.full(n, SILENCE, np.uint8)
        left = np.where((sec + first) % 2 == 0, v, z)
        right = np.where((sec + first) % 2 == 1, v, z)
        return np.stack([left, right], axis=1).tobytes()

    cases = [("silent clip fails sound", 2, silent, "sound", False),
             ("left-then-right passes lr", 2, lr, "lr", True),
             ("swapped channels fail lr", 2, lambda f, n, ch: lr(f, n, ch, True), "lr", False),
             ("mono tones pass monotones", 1, mono, "monotones", True),
             ("silent mono fails monotones", 1, silent, "monotones", False),
             ("silent clip passes silent", 2, silent, "silent", True),
             ("tone clip fails silent", 2, lr, "silent", False),
             ("beeps starting left pass beeps", 2, beep, "beeps", True),
             ("beeps starting right fail beeps", 2, lambda f, n, ch: beep(f, n, ch, 1), "beeps", False),
             ("mono beeps pass monobeeps", 1, beep, "monobeeps", True),
             ("silent mono fails monobeeps", 1, silent, "monobeeps", False)]
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        for name, ch, gen, expect, want in cases:
            p = Path(d) / "s.vid"
            synth(p, ch, frames, gen)
            ok, _ = check(p, expect)
            good = ok == want
            fails += not good
            print(f"{'PASS' if good else 'FAIL'} {name}")
        p = Path(d) / "s.vid"
        synth(p, 2, 4, silent)
        b = bytearray(p.read_bytes())
        b[HDR + 1300] = 0x7F                     # a pad byte of frame 0
        p.write_bytes(bytes(b))
        try:
            Clip(p)
            print("FAIL bad pad byte refused")
            fails += 1
        except ValueError:
            print("PASS bad pad byte refused")
    total = len(cases) + 1
    print(f"rawsound_check selftest: {total - fails}/{total} passed")
    return 1 if fails else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("clip", nargs="?")
    ap.add_argument("--expect", choices=("layout", "sound", "lr", "monotones", "silent",
                                         "beeps", "monobeeps"))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.clip or not a.expect:
        ap.error("a clip and --expect are required")
    try:
        ok, lines = check(a.clip, a.expect)
    except ValueError as e:
        print(f"{a.clip}: {e}")
        return 1
    print("\n".join(lines))
    print("OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
