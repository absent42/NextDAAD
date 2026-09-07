"""Headless ZEsarUX driver for the launcher: <card dir> --launch NAME.NEX.
Samples the DEBUG mirror at $5400 every --interval; optional --space-at
taps and --assert checks; --expect-handoff needs text at $6000."""
import argparse, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp, tilemap, nleg

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
MIRROR = 0x5400
FIELDS = {"seq": 2, "state": 3, "slide": 4, "load": 5, "trans": 6, "code": 7,
          "front": 16, "mode": 17, "music": 18, "keys": 19, "hz60": 20, "fadek": 21,
          "loadpage": 24, "fading": 25, "slides": 26, "skip": 27}
WORDS = {"frame": 8, "hold": 10, "tf": 12, "scroll": 14, "pcmwr": 22}
SPACE_DOWN = "FFFFFFFFFFFFFFFE00"

def decode(m):
    d = {k: m[o] for k, o in FIELDS.items()}
    for k, o in WORDS.items():
        d[k] = m[o] | (m[o + 1] << 8)
    d["sig"] = bytes(m[0:2]).decode("ascii", "replace")
    return d

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("card")
    ap.add_argument("--launch", required=True)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--space-at", type=float, action="append", default=[])
    ap.add_argument("--assert", dest="asserts", action="append", default=[])
    ap.add_argument("--expect-handoff", action="store_true")
    ap.add_argument("--port", type=int, default=10011)
    a = ap.parse_args()
    card = pathlib.Path(a.card).resolve()
    if nleg.port_already_listening(a.port):
        raise SystemExit("port %d already in use - a stale emulator is running" % a.port)
    proc = subprocess.Popen([str(ZESARUX), "--machine", "tbblue", "--realvideo",
                             "--enable-esxdos-handler", "--esxdos-root-dir", str(card),
                             "--vo", "null", "--ao", "null",
                             "--enable-remoteprotocol", "--remoteprotocol-port", str(a.port),
                             "--smartloadpath", str(card)], cwd=str(card))
    ok = True
    try:
        z = None
        for _ in range(60):
            if proc.poll() is not None:
                raise SystemExit("ZEsarUX died before ZRCP came up")
            try:
                z = zrcp.Zrcp(port=a.port); break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise SystemExit("ZRCP never came up")
        z.cmd("smartload %s" % (card / a.launch), deadline=30.0)
        t0 = time.time()
        samples = []
        pending_space = sorted(a.space_at)
        while time.time() - t0 < a.seconds:
            t = time.time() - t0
            if pending_space and t >= pending_space[0]:
                pending_space.pop(0)
                z.hold_matrix(SPACE_DOWN); time.sleep(0.15); z.release_matrix()
                print("t=%.1f space" % t)
            m = z.read_memory(MIRROR, 32)
            d = decode(m)
            samples.append((t, d))
            print("t=%.1f sig=%s state=%d slide=%d load=%d trans=%d code=%02X frame=%d hold=%d tf=%d scroll=%d front=%d mode=%d music=%d keys=%d hz60=%d fadek=%d pcmwr=%04X loadpage=%d fading=%d"
                  % (t, d["sig"], d["state"], d["slide"], d["load"], d["trans"], d["code"], d["frame"], d["hold"], d["tf"], d["scroll"], d["front"], d["mode"], d["music"], d["keys"], d["hz60"], d["fadek"], d["pcmwr"], d["loadpage"], d["fading"]))
            time.sleep(a.interval)
        for spec in a.asserts:
            when, cond = spec.split(":", 1)
            field, value = cond.split("=")
            when = float(when)
            t, d = min(samples, key=lambda s: abs(s[0] - when))
            got = d[field]
            if got != int(value, 0):
                print("ASSERT FAILED at t=%.1f: %s=%d, expected %s" % (t, field, got, value)); ok = False
            else:
                print("assert ok t=%.1f %s=%s" % (t, field, value))
        if a.expect_handoff:
            rows, _ = tilemap.decode(z.read_memory(0x6000, tilemap.GRID_BYTES))
            text = [r.rstrip() for r in rows if r.strip()]
            for r in text:
                print("game: " + r)
            if not text:
                print("ASSERT FAILED: no interpreter text at $6000 - the hand-off did not reach the game"); ok = False
        z.close()
    finally:
        proc.kill(); proc.wait(timeout=10)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
