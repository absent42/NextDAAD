# Keystroke log decoder (DEBUG builds): walks the ring the frame ISR fills
# at $4800-$4FFF and classifies every key-down run. Library and command.
#   python tests\kblog_dump.py --selftest
#   python tests\kblog_dump.py --file ring.bin --ptr 0x4A10 [--video]
#   python tests\kblog_dump.py --port 10041
#   python tests\kblog_dump.py --boot sd\KBLOG --idle 6
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp                                          # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
BASE, END = 0x4800, 0x5000
SIZE = END - BASE
N = SIZE // 4
IDLE0, ENTERED, SETTLE, RECEIVED, ANYKEY, GETKEY, LEFT = range(7)
NAMES = {IDLE0: "idle", ENTERED: "entered", SETTLE: "settle",
         RECEIVED: "received", ANYKEY: "anykey", GETKEY: "getkey",
         LEFT: "left"}


def entries_from(raw, ptr):
    """Valid entries oldest first: walk back from the entry before ptr while
    each frame byte is the newer entry's minus one (spec 4)."""
    if len(raw) != SIZE:
        raise ValueError("ring is %d bytes, want %d" % (len(raw), SIZE))
    if not (BASE <= ptr < END) or (ptr - BASE) % 4:
        raise ValueError("pointer %04X outside the ring or unaligned" % ptr)
    i = ((ptr - BASE) // 4 - 1) % N
    out, newer = [], None
    for _ in range(N):
        e = tuple(raw[4 * i:4 * i + 4])
        if newer is not None and e[0] != (newer[0] - 1) & 0xFF:
            break
        out.append(e)
        newer = e
        i = (i - 1) % N
    out.reverse()
    return out


def key_runs(entries):
    runs, start = [], None
    for k, e in enumerate(entries):
        if e[1] and start is None:
            start = k
        elif not e[1] and start is not None:
            runs.append((start, k - 1))
            start = None
    if start is not None:
        runs.append((start, len(entries) - 1))
    return runs


def _st(e):
    return e[2] & 0x7F


def _idle(e):
    return _st(e) in (IDLE0, LEFT) and not e[2] & 0x80


def classify(entries, run):
    """Spec 4 order: EMITTED, C, D, B, A, else UNCLASSIFIED."""
    s, t = run
    last = entries[s - 1] if s else None
    for e in entries[s:min(len(entries), t + 3)]:
        into3 = _st(e) == RECEIVED and (last is None or _st(last) != RECEIVED or last[3] != e[3])
        into6 = _st(e) == LEFT and e[3] == 13 and (last is None or _st(last) != LEFT)
        if into3 or into6:
            return "EMITTED", e[3]
        last = e
    body = entries[s:t + 1]
    if any(_st(e) in (ANYKEY, GETKEY) or (_st(e) in (IDLE0, LEFT) and e[2] & 0x80) for e in body):
        return "C", None
    sts = [_st(e) for e in body]
    if _idle(body[0]) and ENTERED in sts and SETTLE not in sts:
        return "D", None
    if SETTLE in sts and sts.count(SETTLE) <= 2:
        return "B", None
    if all(_idle(e) for e in body):
        return "A", None
    return "UNCLASSIFIED", None


def report(entries, video=False, start=0):
    """Timeline and runs from entries[start] onwards; the walk line always
    describes the whole walk."""
    lines, prev = [], None
    for k, e in enumerate(entries):
        key = (e[1], e[2], e[3])
        if k >= start and (key != prev or k == start):
            if _st(e) == SETTLE:
                d = "m%d" % e[3]                 # matrix code, not a character
            else:
                d = chr(e[3]) if 32 <= e[3] < 127 else "%d" % e[3]
            lines.append("f%02X keys %s %-8s%s detail %s" % (
                e[0], format(e[1], "05b"), NAMES.get(_st(e), "?%d" % _st(e)),
                " more" if e[2] & 0x80 else "", d))
        prev = key
    lines.append("walk: %d entries (%.1f s at 50 Hz)%s" % (
        len(entries), len(entries) / 50.0,
        "" if len(entries) == N else
        (" - ends at a video gap" if video else " - ends at a break (history start, a gap, or damage)")))
    for r in key_runs(entries):
        if r[1] < start:
            continue
        v, d = classify(entries, r)
        label = "D (suspect kb_raw mapping)" if v == "D" else v
        extra = (" '%s'" % chr(d)) if d is not None and 32 <= d < 127 else ""
        lines.append("run f%02X..f%02X (%d frames): %s%s" % (
            entries[r[0]][0], entries[r[1]][0], r[1] - r[0] + 1, label, extra))
    return "\n".join(lines)


_MAP = {}


def sym(name):
    if name not in _MAP:
        for line in MAP.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[3] == name:
                _MAP[name] = int(parts[0], 16)
                break
        else:
            sys.exit("kblog_dump: %s not in %s - build DEBUG first" % (name, MAP))
    return _MAP[name]


def read_ring(z):
    """Freeze, confirm the freeze (frameCounter must not move), read the
    pointer and the ring, resume. ZEsarUX sporadically refuses the freeze;
    every path out still leaves the CPU running."""
    fc = sym("FRAMECOUNTER")
    reply = ""
    for _ in range(8):
        reply = z.enter_cpu_step()
        a = z.read_memory(fc, 2)
        time.sleep(0.15)
        b = z.read_memory(fc, 2)
        if a == b:
            break
        time.sleep(0.2)
    else:
        try:
            z.exit_cpu_step()
        except Exception:
            pass
        sys.exit("kblog_dump: could not freeze the CPU (enter-cpu-step refused 8 times, "
                  "last reply %r)" % (reply,))
    try:
        p = z.read_memory(sym("KBLOGPTR"), 2)
        ptr = p[0] | (p[1] << 8)
        raw = bytes(z.read_memory(BASE, SIZE))
    finally:
        z.exit_cpu_step()
    return raw, ptr


def launch(leg, port):
    """Boot a staged leg headless on port; returns (proc, zrcp)."""
    work = ROOT / "tests" / "out" / ("kblog-run-%d" % port)
    sd = work / "sd"
    if sd.exists():
        shutil.rmtree(sd)
    shutil.copytree(leg, sd)
    shutil.copyfile(NEX, sd / "nextdaad.nex")
    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(port),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))
    z = None
    for _ in range(60):
        if proc.poll() is not None:
            sys.exit("kblog_dump: ZEsarUX exited before ZRCP came up")
        try:
            z = zrcp.Zrcp(port=port)
            break
        except OSError:
            time.sleep(0.5)
    if z is None:
        proc.kill()
        sys.exit("kblog_dump: ZRCP never answered on port %d" % port)
    z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=60.0)
    return proc, z


_HEX2 = re.compile(r"^[0-9A-Fa-f]{2}$")
_HEXDIGITS = set("0123456789ABCDEFabcdef")


def parse_hex(text):
    """DeZog Memory-view hex text, line by line: drop a leading address
    token (hex digits, either ending in ':' or 4+ digits long), then take
    tokens from the rest while each is exactly two hex digits - stopping
    at the first token that is not (the ASCII sidebar, or anything else,
    starts there). Concatenates across lines."""
    out = bytearray()
    for line in text.splitlines():
        tokens = line.strip().split()
        if not tokens:
            continue
        first = tokens[0]
        core = first[:-1] if first.endswith(":") else first
        is_addr = bool(core) and all(c in _HEXDIGITS for c in core) and \
            (first.endswith(":") or len(first) >= 4)
        rest = tokens[1:] if is_addr else tokens
        for tok in rest:
            if _HEX2.match(tok):
                out.append(int(tok, 16))
            else:
                break
    return bytes(out)


def load_file(path):
    """A 2048-byte binary, or hex text copied from a DeZog Memory view."""
    data = pathlib.Path(path).read_bytes()
    if len(data) == SIZE:
        return data
    raw = parse_hex(data.decode("ascii", "replace"))
    if len(raw) < SIZE:
        sys.exit("kblog_dump: %s holds %d bytes, want %d" % (path, len(raw), SIZE))
    return raw[:SIZE]


def build_ring(entries, start_frame=0x30):
    """Self-test helper: lay (keys, state, detail) triples into a ring with
    consecutive frame bytes, oldest at BASE, and return (raw, ptr)."""
    raw = bytearray(SIZE)
    for k, (keys, state, detail) in enumerate(entries):
        o = 4 * k
        raw[o:o + 4] = bytes(((start_frame + k) & 0xFF, keys, state, detail))
    return bytes(raw), BASE + 4 * len(entries)


def selftest():
    L = ord("l")
    idle = [(0, ENTERED, 30)] * 5
    cases = {
        "EMITTED": idle + [(2, SETTLE, 26), (2, SETTLE, 26), (2, RECEIVED, L),
                           (2, RECEIVED, L), (0, RECEIVED, L)] + [(0, RECEIVED, L)] * 3,
        "A": [(0, LEFT, 13)] * 5 + [(2, LEFT, 13)] * 3 + [(0, LEFT, 13)] * 3
             + [(0, ENTERED, 30)] * 4,
        "B": idle + [(2, SETTLE, 26), (0, SETTLE, 26)] + [(0, SETTLE, 26)] * 4,
        "C": [(0, ANYKEY, 0)] * 3 + [(2, ANYKEY, 0)] * 3 + [(0, IDLE0, 0)] * 4,
        "C-more": [(0, LEFT | 0x80, 13)] * 3 + [(2, LEFT | 0x80, 13)] * 2
                  + [(0, LEFT, 13)] * 4,
        "D": [(0, LEFT, 13)] * 3 + [(2, LEFT, 13)] * 2 + [(2, ENTERED, 30)] * 4
             + [(0, ENTERED, 30)] * 3,
        "ENTER": idle + [(4, SETTLE, 30), (4, SETTLE, 30), (4, LEFT, 13),
                         (0, LEFT, 13), (0, LEFT, 13)],
    }
    want = {"EMITTED": "EMITTED", "A": "A", "B": "B", "C": "C",
            "C-more": "C", "D": "D", "ENTER": "EMITTED"}
    for name, seq in cases.items():
        raw, ptr = build_ring(seq)
        ents = entries_from(raw, ptr)
        assert len(ents) == len(seq), "%s: walk kept %d of %d" % (name, len(ents), len(seq))
        runs = key_runs(ents)
        assert len(runs) == 1, "%s: %d runs" % (name, len(runs))
        got = classify(ents, runs[0])[0]
        assert got == want[name], "%s: classified %s, want %s" % (name, got, want[name])
    # report: settle detail is a matrix code; start trims timeline and runs only
    raw, ptr = build_ring(cases["EMITTED"])
    ents = entries_from(raw, ptr)
    rep = report(ents)
    assert "settle   detail m26" in rep, "report: settle detail not m26"
    tail = report(ents, start=len(ents) - 2)
    assert "walk: %d entries" % len(ents) in tail and "run " not in tail \
        and tail.count("\n") == 1, "report start: %r" % tail
    # walk-back stops at a frame break: 4 stale entries, then 6 consecutive
    raw = bytearray(SIZE)
    for k in range(4):
        raw[4 * k:4 * k + 4] = bytes((0x90 + k, 0, IDLE0, 0))
    for k in range(6):
        raw[16 + 4 * k:20 + 4 * k] = bytes((0x10 + k, 0, ENTERED, 30))
    ents = entries_from(bytes(raw), BASE + 40)
    assert len(ents) == 6, "break: walk kept %d, want 6" % len(ents)
    # a full ring wraps: pointer mid-ring, all N entries consecutive
    raw = bytearray(SIZE)
    p = 100
    for k in range(N):
        i = (p + k) % N
        raw[4 * i:4 * i + 4] = bytes(((0x40 + k) & 0xFF, 0, ENTERED, 30))
    ents = entries_from(bytes(raw), BASE + 4 * p)
    assert len(ents) == N and ents[0][0] == 0x40, "wrap: %d entries, first %02X" % (len(ents), ents[0][0])
    # entries_from rejects a malformed ring or pointer
    try:
        entries_from(b"\x00" * (SIZE - 1), BASE)
        assert False, "wrong-length ring: no ValueError"
    except ValueError:
        pass
    try:
        entries_from(bytes(SIZE), BASE + 1)
        assert False, "misaligned pointer: no ValueError"
    except ValueError:
        pass
    # line-wise DeZog hex text: 16 bytes/line, "4800: " address, an ASCII
    # sidebar (no internal spaces) that includes letter pairs a-f - a
    # whole-blob regex would mistake sidebar substrings for data bytes
    raw = bytes(range(256)) * 8
    lines = []
    for o in range(0, SIZE, 16):
        row = raw[o:o + 16]
        hexpairs = " ".join("%02X" % b for b in row)
        sidebar = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        lines.append("%04X: %s  %s" % (BASE + o, hexpairs, sidebar))
    assert parse_hex("\n".join(lines)) == raw, "hex text: parse mismatch"
    print("kblog_dump selftest: PASS")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--file")
    ap.add_argument("--ptr", type=lambda s: int(s, 0))
    ap.add_argument("--port", type=int)
    ap.add_argument("--boot", help="staged leg to boot headless, e.g. sd\\KBLOG")
    ap.add_argument("--idle", type=float, default=6.0, help="seconds after boot before the read")
    ap.add_argument("--video", action="store_true", help="a clip or NXB run happened in the session")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return
    if a.file:
        if a.ptr is None:
            sys.exit("kblog_dump: --file needs --ptr")
        raw, ptr = load_file(a.file), a.ptr
    elif a.port:
        z = zrcp.Zrcp(port=a.port)
        raw, ptr = read_ring(z)
        z.close()
    elif a.boot:
        port = 10041
        proc, z = launch((ROOT / a.boot).resolve(), port)
        try:
            time.sleep(a.idle)
            raw, ptr = read_ring(z)
        finally:
            try:
                z.close()
            except Exception:
                pass
            proc.kill()
            proc.wait()
    else:
        ap.error("one of --selftest, --file, --port, --boot")
    print(report(entries_from(raw, ptr), video=a.video))


if __name__ == "__main__":
    main()
