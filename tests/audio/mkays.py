# AYS register-loss stimulus generator (-AysReg leg).
#
# Writes two 3-PSG AYS1 streams plus a JSON sidecar of every authored
# register state, so a checker can compare chip readback against what
# the stream intends:
#
#   aysreg_steady.ays  nine sustained voices, all registers written once
#                      at frame 0 and never again, 3000 frames (60 s),
#                      loop at frame 0. Worst case for a change-only
#                      stream: nothing repairs a register another writer
#                      overwrote until the loop.
#   aysreg_wrap.ays    loop-wrap probe. States S0 (frames 0..49), S1
#                      (50..199, PSG 1 tone A changed) and S2 (200..299,
#                      PSG 1 tone A, PSG 2 tone A and PSG 1 envelope shape
#                      changed), loop at frame 50. On a wrap the loop
#                      frame's delta only re-sends PSG 1 tone A, so replay
#                      that does not restore the pre-loop state leaves PSG
#                      2 tone A and PSG 1 R13 at their S2 values - a hybrid
#                      matching no authored state.
#
# Encoding mirrors authoring-kit/lib/aysconv.ps1 exactly: per frame, per
# PSG, a 14-bit mask of R0-R12 that differ from the last value written
# (baseline all zero, R7 = $3F) plus R13 whenever its byte is not $FF,
# followed by the changed values in ascending register order.
#
# Every register value is nonzero so a stream (re)start rewrites all of
# them at frame 0, and channel C of each PSG runs on the hardware
# envelope (volume $10, R13 = $0E repeating triangle) so a clobbered
# envelope shape is observable.
#
# Usage: python tests/audio/mkays.py <outdir>

import json
import os
import sys

AY_CLOCK = 1773400


def period(hz):
    return int(round(AY_CLOCK / (16.0 * hz)))


# Nine distinct notes, all below 433 Hz so every coarse period byte is
# nonzero. Channel C of each PSG is the envelope voice.
NOTES = [
    [130.81, 164.81, 196.00],   # PSG 1: C3 E3 G3
    [261.63, 329.63, 392.00],   # PSG 2: C4 E4 G4
    [220.00, 246.94, 293.66],   # PSG 3: A3 B3 D4
]
ENV_PERIOD = [0x0310, 0x0248, 0x0184]    # triangle rate per PSG
NOISE = [5, 9, 13]                       # R6: unused by the mixer, but
                                         # nonzero so stale writes show


def base_state():
    """R0-R13 per PSG. R13 is the shape; whether it is WRITTEN in a
    frame is decided separately (the YM $FF convention)."""
    regs = []
    for p in range(3):
        r = [0] * 14
        for c in range(3):
            t = period(NOTES[p][c])
            r[2 * c] = t & 0xFF
            r[2 * c + 1] = (t >> 8) & 0x0F
        r[6] = NOISE[p]
        r[7] = 0x38                      # tone A/B/C on, noise off
        r[8] = 12
        r[9] = 10
        r[10] = 0x10                     # channel C: hardware envelope
        r[11] = ENV_PERIOD[p] & 0xFF
        r[12] = ENV_PERIOD[p] >> 8
        r[13] = 0x0E
        regs.append(r)
    return regs


def set_tone(regs, p, c, hz):
    t = period(hz)
    regs[p][2 * c] = t & 0xFF
    regs[p][2 * c + 1] = (t >> 8) & 0x0F


def encode(frames, loop_frame):
    """frames: list of (regs[3][14], r13_written[3]). Returns the file
    bytes, aysconv.ps1's merge loop line for line."""
    npsg = 3
    prev = [[0] * 13 for _ in range(npsg)]
    for p in range(npsg):
        prev[p][7] = 0x3F
    stream = bytearray()
    loop_off = 0
    for f, (regs, r13w) in enumerate(frames):
        if f == loop_frame:
            loop_off = len(stream)
        for p in range(npsg):
            mask = 0
            for r in range(13):
                if regs[p][r] != prev[p][r]:
                    mask |= 1 << r
                    prev[p][r] = regs[p][r]
            if r13w[p]:
                mask |= 1 << 13
            stream += bytes((mask & 0xFF, mask >> 8))
            for r in range(13):
                if mask & (1 << r):
                    stream.append(regs[p][r])
            if mask & (1 << 13):
                stream.append(regs[p][13])
    n = len(frames)
    hdr = bytearray(16)
    hdr[0:4] = b"AYS1"
    hdr[4] = npsg
    hdr[6] = n & 0xFF
    hdr[7] = n >> 8
    hdr[8:11] = loop_off.to_bytes(3, "little")
    hdr[11:14] = len(stream).to_bytes(3, "little")
    return bytes(hdr) + bytes(stream)


def copy_regs(regs):
    return [list(r) for r in regs]


def steady():
    s = base_state()
    frames = [(s, [True] * 3)] + [(s, [False] * 3)] * 2999
    return encode(frames, 0), {"S": s}


def wrap():
    s0 = base_state()
    s1 = copy_regs(s0)
    set_tone(s1, 0, 0, 146.83)           # PSG 1 A: C3 -> D3
    s2 = copy_regs(s1)
    set_tone(s2, 0, 0, 174.61)           # PSG 1 A: D3 -> F3
    set_tone(s2, 1, 0, 293.66)           # PSG 2 A: C4 -> D4
    s2[0][13] = 0x0A                     # PSG 1 envelope shape, so the wrap
                                         # must resend S1's shape too
    frames = [(s0, [True] * 3)] + [(s0, [False] * 3)] * 49
    frames += [(s1, [False] * 3)] * 150
    frames += [(s2, [True, False, False])] + [(s2, [False] * 3)] * 99
    return encode(frames, 50), {"S0": s0, "S1": s1, "S2": s2}


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    os.makedirs(out, exist_ok=True)
    states = {}
    for name, fn in (("steady", steady), ("wrap", wrap)):
        data, st = fn()
        for sname, regs in st.items():
            for p, r in enumerate(regs):
                if not all(r):
                    raise SystemExit("%s %s PSG %d has a zero register: %r" % (name, sname, p + 1, r))
        path = os.path.join(out, "aysreg_%s.ays" % name)
        with open(path, "wb") as fh:
            fh.write(data)
        states[name] = st
        print("wrote %s  %d bytes" % (path, len(data)))
    with open(os.path.join(out, "aysreg_states.json"), "w") as fh:
        json.dump(states, fh, indent=1)


if __name__ == "__main__":
    main()
