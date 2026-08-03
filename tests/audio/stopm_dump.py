# SP16 Task 7b - the STOPM three-point AY/player state dump.
#
# Headless, scripted, no ears involved: this reproduces
#     boot autoplay -> STOPM -> MUSIC restart
# under ZEsarUX and dumps the DEBUG build's per-frame AY mirror
# (src\audio\audiobank.asm aud_dbg_snap, at AUD_STAGE0 $7C00) at each
# point, then does the same on a fresh boot with NO stop/restart as the
# control. The two are compared at MATCHED SONG PHASE, so a difference
# in the tables is a difference in state, not in where the tune had got
# to.
#
# Run from the repo root, after
#     .\build.ps1                       (DEBUG - the mirror is DEBUG-only)
#     pwsh -File tests\build-tests.ps1 -AudLad
#
#     python tests/audio/stopm_dump.py --out <workdir>
#
# WHY PHASE MATCHING. Almost every interesting cell (track pointers,
# block pointers, wait counters, the tone periods themselves) advances
# with the tune. Comparing two dumps taken at arbitrary moments would
# report the tune's own motion as a difference. So each run COLLECTS a
# burst of samples keyed by (linker position, frames-left-in-pattern) -
# the AKY player's exact song phase - and the comparison is over phase
# keys the two runs have in common. GAME.AKY is a byte-identical copy
# of 006.AKY in sd\AUDLAD\ (build-tests.ps1 -AudLad), so at equal phase the two
# runs are playing literally the same bytes of the same song.
#
# WHICH MATERIAL. The default restart verb is LADR = 006.AKY = the kit's
# own 9-channel tune - the material BOTH parked SP14b sightings were
# actually heard on, and the one that uses noise, hardware envelopes and
# retrigs. `--restart LAD1` runs the same comparison against the
# synthetic single-channel rung instead: a much weaker stimulus, and NOT
# byte-identical to the autoplay, so its control is only a
# same-player-state control, not a same-material one.
#
# COLLECTION WINDOW. Both scenarios start collecting at their FIRST live
# frame, so the frames immediately after PLY_AKY_INIT - where a DECAYING
# residue would live, as opposed to a persistent one - are inside the
# compared set. Settling first would have sampled the control's early
# phases from its second pass and quietly dropped the transient.
#
# EMULATOR-MODEL CAVEAT. Everything here is ZEsarUX's model of the AY
# and of the Next's Turbo Sound, not silicon. The register-array half of
# the mirror is plain Z80 memory and is as trustworthy as any other
# memory read; the chip-readback half (offsets $10-$39) depends on
# ZEsarUX implementing AY register READ on $FFFD per selected chip. Any
# verdict from this script is emulator-model evidence and is written up
# as such - see docs\hardware-test-checklist.md, audio section, and EAR
# CARD #T7B.

import argparse
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ZESARUX = os.path.join(ROOT, "tools", "DAAD-READY", "TOOLS", "zesarux", "zesarux.exe")
NEX = os.path.join(ROOT, "build", "nextdaad.nex")
SD = os.path.join(ROOT, "sd")

COLLECT_S = 25.0                # collection window per scenario
SNAP = 0x7C00
OFF_SEQ = 0x04
OFF_AY = 0x10
OFF_ARR = 0x3A
OFF_CELL = 0x7A
OFF_SEQ2 = OFF_CELL + 2 * 40    # trailing copy of the sequence byte
SNAP_LEN = OFF_SEQ2 + 1         # header + AY + arrays + 40 words + tear byte

CELL_NAMES = (
    ["patternFrameCounter", "linkerPos", "sfxTable", "sfxStream"]
    + ["ch%d.ptTrack" % (i + 1) for i in range(9)]
    + ["ch%d.ptBlock" % (i + 1) for i in range(9)]
    + ["ch%d.wait" % (i + 1) for i in range(9)]
    + ["ch%d.lineState" % (i + 1) for i in range(9)]
)

PROMPT_RE = re.compile(r"command(@cpu-step)?>\s*$")


class Zrcp:
    """Minimal ZEsarUX remote-protocol client. Deliberately self-
    contained: tests\\parser\\zrcp.py is the fuller client, but this
    script must not depend on the parser harness being present.
    Addresses are DECIMAL (measured, see that file's header)."""

    def __init__(self, port, timeout=20):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self._drain()

    def _drain(self, deadline=20.0):
        buf = b""
        start = time.monotonic()
        self.s.settimeout(0.2)
        while not PROMPT_RE.search(buf.decode("latin-1", "replace")):
            if time.monotonic() - start > deadline:
                raise IOError("no ZRCP prompt in %.1fs: %r" % (deadline, buf[-200:]))
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                continue
            if chunk:
                buf += chunk
        return buf.decode("latin-1")

    def cmd(self, text, wait=0.0, deadline=20.0):
        self.s.sendall((text + "\n").encode("latin-1"))
        if wait:
            time.sleep(wait)
        reply = self._drain(deadline)
        return PROMPT_RE.sub("", reply).strip()

    def read(self, addr, length):
        reply = self.cmd("read-memory %d %d" % (addr, length))
        hexs = "".join(reply.split())
        if len(hexs) != length * 2 or not re.fullmatch(r"[0-9A-Fa-f]*", hexs):
            raise IOError("bad read-memory reply: %r" % reply[:200])
        return bytes.fromhex(hexs)

    def keys(self, text):
        settle = 0.15 * len(text) + 0.8
        self.cmd("send-keys-string 150 %s" % text, wait=settle, deadline=settle + 20)

    def enter(self, wait=1.0):
        self.cmd("send-keys-ascii 150 13", wait=wait, deadline=wait + 20)


def stage(workdir):
    sd = os.path.join(os.path.abspath(workdir), "sd")
    if os.path.isdir(sd):
        shutil.rmtree(sd)
    os.makedirs(sd)
    # Whatever -AudLad staged, verbatim: GAME.DDB, GAME.AKY, 001..005.AKY.
    for name in os.listdir(SD):
        src = os.path.join(SD, name)
        if os.path.isfile(src) and (name.upper().endswith(".AKY")
                                    or name.upper() == "GAME.DDB"):
            shutil.copyfile(src, os.path.join(sd, name))
    shutil.copyfile(NEX, os.path.join(sd, "nextdaad.nex"))
    return sd


def launch(sd, port):
    return subprocess.Popen([
        ZESARUX, "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", sd,
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(port),
        "--smartloadpath", sd,
    ], cwd=sd)


def connect(proc, port, attempts=60, delay=0.5):
    for _ in range(attempts):
        if proc.poll() is not None:
            raise RuntimeError("ZEsarUX exited early (%r)" % proc.returncode)
        try:
            return Zrcp(port)
        except OSError:
            time.sleep(delay)
    raise TimeoutError("ZRCP never answered on port %d" % port)


def intact(dump):
    """A sample is usable only if its signature is right AND the leading
    and trailing copies of the sequence byte agree - the emulator keeps
    running during the read, so a straddled frame splices two frames
    together and must be thrown away, not diffed."""
    return dump[0:4] == b"AYS1" and dump[OFF_SEQ] == dump[OFF_SEQ2]


def phase(dump):
    """The AKY player's song position: which linker entry it is on and
    how many frames are left in the current pattern."""
    counter = struct.unpack_from("<H", dump, OFF_CELL)[0]
    linker = struct.unpack_from("<H", dump, OFF_CELL + 2)[0]
    return (linker, counter)


def playing(dump):
    return bool(dump[0x05] & 1)


def collect(z, seconds, want_playing=True):
    """Sample the mirror for `seconds`, keyed by song phase. Returns
    {phase: dump}. Only frames whose signature is intact are kept."""
    out = {}
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        d = z.read(SNAP, SNAP_LEN)
        if not intact(d):
            continue
        if want_playing and not playing(d):
            continue
        out.setdefault(phase(d), d)
    return out


def wait_for(z, pred, seconds, what):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        d = z.read(SNAP, SNAP_LEN)
        if intact(d) and pred(d):
            return d
        time.sleep(0.05)
    raise TimeoutError("timed out waiting for %s" % what)


def fmt_ay(dump):
    lines = []
    for p in range(3):
        r = dump[OFF_AY + 14 * p: OFF_AY + 14 * p + 14]
        tones = [r[2 * c] | ((r[2 * c + 1] & 0x0F) << 8) for c in range(3)]
        lines.append("  PSG%d  tone %-5d %-5d %-5d  vol %2d %2d %2d  "
                     "R6=%02X R7=%02X env=%04X R13=%02X"
                     % (p + 1, tones[0], tones[1], tones[2],
                        r[8] & 0x1F, r[9] & 0x1F, r[10] & 0x1F,
                        r[6], r[7], r[11] | (r[12] << 8), r[13]))
    return "\n".join(lines)


def fmt_cells(dump):
    lines = []
    for i, name in enumerate(CELL_NAMES):
        v = struct.unpack_from("<H", dump, OFF_CELL + 2 * i)[0]
        lines.append("  %-22s %04X" % (name, v))
    return "\n".join(lines)


def fmt_header(dump):
    return ("  audFlags=%02X songNum=%02X playerUp=%02X aysFlags=%02X "
            "smpFlags=%02X req=%02X req2=%02X beepFrames=%d enable=%02X loop=%02X"
            % (dump[0x05], dump[0x06], dump[0x07], dump[0x08], dump[0x09],
               dump[0x0A], dump[0x0B],
               struct.unpack_from("<H", dump, 0x0C)[0], dump[0x0E], dump[0x0F]))


def dump_text(title, d):
    return "\n".join([title, fmt_header(d), fmt_ay(d), fmt_cells(d)])


def diff(a, b):
    """Byte offsets where two same-phase dumps differ, minus the two
    fields that are expected to differ (the free-running sequence byte
    and the transient request mailbox)."""
    skip = {OFF_SEQ, OFF_SEQ2, 0x0A, 0x0B}
    out = []
    for i in range(SNAP_LEN):
        if i in skip:
            continue
        if a[i] != b[i]:
            out.append(i)
    return out


def describe(off):
    if off < OFF_AY:
        return "header+%02X" % off
    if off < OFF_ARR:
        n = off - OFF_AY
        return "PSG%d R%d (chip)" % (n // 14 + 1, n % 14)
    if off < OFF_CELL:
        n = off - OFF_ARR
        which = ["PSG1", "PSG2", "PSG3", "SFX"][n // 16]
        return "%s array +%d" % (which, n % 16)
    n = off - OFF_CELL
    return "%s %s" % (CELL_NAMES[n // 2], "lo" if n % 2 == 0 else "hi")


def run_scenario(sd, port, do_stopm, log, restart="LADR"):
    proc = launch(sd, port)
    try:
        z = connect(proc, port)
        z.cmd("smartload %s" % os.path.join(sd, "nextdaad.nex"), wait=1.0,
              deadline=60)
        # Boot: the interpreter takes over, aud_boot_probe loads GAME.AKY
        # and files the start-music request. Wait for the mirror to show
        # the song actually running.
        d0 = wait_for(z, lambda d: playing(d), 60, "boot autoplay")
        log.append(dump_text("--- boot autoplay (first frame with music live)", d0))
        if not do_stopm:
            # Collect from the FIRST live frame, not after a settle: the
            # repro's collection starts at its own first live frame
            # after PLY_AKY_INIT, and the two sets must cover the same
            # part of the song - including the restart transient, where
            # a DECAYING residue would live. A settle here would leave
            # the control's early phases sampled from its second pass
            # and silently drop the transient out of the comparison.
            return collect(z, COLLECT_S), log
        time.sleep(2.0)                     # let the tune get past its first note
        pre = wait_for(z, playing, 10, "a clean pre-STOPM sample")
        log.append(dump_text("--- POINT 1: pre-STOPM", pre))
        z.keys("STOPM")
        z.enter()
        post = wait_for(z, lambda d: not playing(d), 15, "STOPM to take effect")
        log.append(dump_text("--- POINT 2: post-STOPM", post))
        time.sleep(1.0)
        post2 = wait_for(z, lambda d: not playing(d), 10, "a clean post-STOPM sample")
        log.append(dump_text("--- POINT 2b: post-STOPM, one second later", post2))
        z.keys(restart)
        z.enter()
        rst = wait_for(z, lambda d: playing(d), 20, "MUSIC restart")
        log.append(dump_text("--- POINT 3: post-restart MUSIC (first live frame)", rst))
        log.append("restart transient phase = %04X:%04X" % phase(rst))
        # No settle: collection starts HERE, on the frames immediately
        # after PLY_AKY_INIT, so the restart transient is inside the
        # compared set (see the control branch above).
        return collect(z, COLLECT_S), log
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
        proc.wait(timeout=20)


LADDER = [("LAD1", 1), ("LAD3", 3), ("LAD6", 6), ("LAD9", 9), ("LADQ", 9),
          ("LADR", None)]


def sounding(dump, only_psg=None):
    """How many AY channels are actually making a noise: non-zero
    volume, tone bit open in R7, and a non-zero period."""
    live = 0
    for p in range(3):
        if only_psg is not None and p != only_psg:
            continue
        r = dump[OFF_AY + 14 * p: OFF_AY + 14 * p + 14]
        for c in range(3):
            tone = r[2 * c] | ((r[2 * c + 1] & 0x0F) << 8)
            if (r[8 + c] & 0x1F) and not (r[7] & (1 << c)) and tone:
                live += 1
    return live


def run_ladder(sd, port, log):
    """Task 7a support leg: walk the ladder verbs and dump what actually
    reaches the three PSGs on each rung. This does NOT judge the sound -
    it answers the prior question the ear card depends on, namely
    whether rung k is driving exactly k channels with the intended
    periods and volumes, so a PASS/DISTORTED row is scoring real
    stimulus rather than a staging miss."""
    proc = launch(sd, port)
    try:
        z = connect(proc, port)
        z.cmd("smartload %s" % os.path.join(sd, "nextdaad.nex"), wait=1.0,
              deadline=60)
        wait_for(z, playing, 60, "boot autoplay")
        time.sleep(3.0)                 # let the fixture reach its prompt
        for verb, channels in LADDER:
            # No STOPM needed between rungs: aud_load_song stops whatever
            # is playing before it overwrites the song area (overlay1).
            z.keys(verb)
            z.enter()
            d = wait_for(z, playing, 20, verb)
            time.sleep(0.4)
            d = wait_for(z, playing, 5, verb + " settled")
            live = sounding(d)
            if channels is None:
                # Real material: one instant proves nothing about how
                # many voices the composer uses, so watch it for a while
                # and report the peak and the per-PSG reach.
                peak, psgs, best = 0, [False] * 3, d
                end = time.monotonic() + 25.0
                while time.monotonic() < end:
                    q = z.read(SNAP, SNAP_LEN)
                    if not intact(q) or not playing(q):
                        continue
                    n = sounding(q)
                    if n > peak:
                        peak, best = n, q
                    for pi in range(3):
                        if sounding(q, pi):
                            psgs[pi] = True
                log.append("--- rung %s: real material, %d channel(s) at "
                           "the first sample, PEAK %d over 25 s, PSGs "
                           "reached: %s" % (verb, live, peak,
                           ", ".join("PSG%d" % (i + 1)
                                     for i in range(3) if psgs[i]) or "none"))
                log.append(fmt_ay(best))
                continue
            log.append("--- rung %s: %d channel(s) expected, %d sounding"
                       % (verb, channels, live))
            log.append(fmt_ay(d))
            if live != channels:
                log.append("  MISMATCH - the rung is not driving what it should")
        return log
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
        proc.wait(timeout=20)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=10077)
    ap.add_argument("--restart", default="LADR",
                    help="verb that restarts the music after STOPM. "
                         "LADR (default) is the kit's real 9-channel tune "
                         "and is byte-identical to the boot autoplay; LAD1 "
                         "is the synthetic single-channel rung and is NOT")
    ap.add_argument("--ladder", action="store_true",
                    help="Task 7a: verify each ladder rung drives the "
                         "channels it claims, instead of the 7b STOPM dump")
    args = ap.parse_args()
    if not os.path.exists(ZESARUX):
        sys.exit("ZEsarUX not found at %s" % ZESARUX)
    if not os.path.exists(NEX):
        sys.exit("build/nextdaad.nex missing - run .\\build.ps1 (DEBUG)")
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    sd = stage(out)

    if args.ladder:
        log = ["=== LADDER RUNG VERIFICATION (emulator model, not a fidelity verdict) ==="]
        log = run_ladder(sd, args.port, log)
        text = "\n".join(log) + "\n"
        path = os.path.join(out, "ladder-check.txt")
        with open(path, "w") as f:
            f.write(text)
        print(text)
        print("written to %s" % path)
        return

    log = []
    log.append("=== CONTROL: fresh boot, autoplay only, no STOPM ===")
    ctrl, log = run_scenario(sd, args.port, False, log, args.restart)
    log.append("")
    log.append("=== REPRO: fresh boot, autoplay -> STOPM -> %s ===" % args.restart)
    repro, log = run_scenario(sd, args.port + 1, True, log, args.restart)

    common = sorted(set(ctrl) & set(repro))
    log.append("")
    log.append("=== PHASE-MATCHED COMPARISON ===")
    log.append("control samples %d, repro samples %d, phases in common %d"
               % (len(ctrl), len(repro), len(common)))
    # M2: prove the restart transient is inside the compared set rather
    # than asserting it. The line above only says how many phases match;
    # this one says whether the frames right after PLY_AKY_INIT - where
    # a DECAYING residue would live - are among them.
    for line in log:
        if line.startswith("restart transient phase = "):
            tp = line.split("= ")[1].split(":")
            tph = (int(tp[0], 16), int(tp[1], 16))
            if tph in common:
                d = diff(ctrl[tph], repro[tph])
                log.append("restart transient phase %04X:%04X IS in the "
                           "compared set - %s" % (tph[0], tph[1],
                           "differs at %d offset(s)" % len(d) if d
                           else "identical to the control"))
            else:
                log.append("WARNING: restart transient phase %04X:%04X is "
                           "NOT in the compared set - the transient was "
                           "not covered, widen COLLECT_S" % tph)
            break
    if not common:
        log.append("NO COMMON PHASE - comparison impossible, widen the collect window")
    bad = 0
    seen = {}
    for ph in common:
        d = diff(ctrl[ph], repro[ph])
        if d:
            bad += 1
            for off in d:
                seen.setdefault(describe(off), 0)
                seen[describe(off)] += 1
    log.append("phases whose dumps differ: %d of %d" % (bad, len(common)))
    if seen:
        log.append("differing fields (field: how many phases):")
        for k in sorted(seen):
            log.append("  %-24s %d" % (k, seen[k]))
        ph = next(p for p in common if diff(ctrl[p], repro[p]))
        log.append("")
        log.append(dump_text("--- first differing phase %04X:%04X - CONTROL"
                             % (ph[0], ph[1]), ctrl[ph]))
        log.append(dump_text("--- first differing phase %04X:%04X - REPRO"
                             % (ph[0], ph[1]), repro[ph]))
    else:
        log.append("NO DIFFERENCE at any matched phase - post-restart state is "
                   "byte-identical to the fresh-boot control")

    text = "\n".join(log) + "\n"
    path = os.path.join(out, "stopm-dump.txt")
    with open(path, "w") as f:
        f.write(text)
    print(text)
    print("written to %s" % path)


if __name__ == "__main__":
    main()
