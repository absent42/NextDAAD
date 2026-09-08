"""Headless ZEsarUX driver for the launcher: <card dir> --launch NAME.NEX.
Samples the DEBUG mirror at $5400 every --interval; optional --space-at
(seconds) / --space-at-frame (mirror frame count) taps, --assert
(seconds) / --assert-frame (first sample whose frame >= F) checks,
--surface-at-frame F:<picture file> (freezes the CPU and byte-compares the
front Layer 2 surface against a compiled NXC/NXI), --skip-surface-at-frame
F:PC:<picture file> (presses skip at frame>=F, breakpoints at PC - e.g.
chain_run's address from the launcher's own .map - so the surface check
runs before any hand-off code can overwrite it, then resumes),
--expect-handoff/--expect-text at $6000 (the hand-off gate). --text-at-frame
F (repeatable, at the first sample whose mirror frame >= F) decodes the
launcher's own tilemap at $4000 and prints/collects its non-blank rows;
--expect-caption "s" (repeatable) requires each substring in some
collected row. ZEsarUX's frame rate varies by host, so wall-clock anchors
drift - prefer the frame-anchored flags; --interval tightens to 0.1s
automatically when any of them are given."""
import argparse, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp, tilemap, nleg

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
MIRROR = 0x5400
FIELDS = {"seq": 2, "state": 3, "slide": 4, "load": 5, "trans": 6, "code": 7,
          "front": 16, "mode": 17, "music": 18, "keys": 19, "hz60": 20, "fadek": 21,
          "loadpage": 24, "fading": 25, "slides": 26, "skip": 27, "akytick": 28}
WORDS = {"frame": 8, "hold": 10, "tf": 12, "scroll": 14, "pcmwr": 22}
SPACE_DOWN = "FFFFFFFFFFFFFFFE00"
# stub: di / ld sp,$7FE0 (chain.asm) - if $6000 still starts with this, the
# stub never handed off and any decoded "text" there is its own opcodes.
STUB_PROLOGUE = bytes.fromhex("f331e07f")

# Surface readback (fix round 1): with the CPU frozen (enter-cpu-step),
# ZEsarUX memory zone 0 exposes the flat 2MB Next RAM regardless of the
# live MMU map; 8K page P sits at zone-0 byte offset (P+32)*8192. Verified
# live: page 28 (frontBank 14 * 2 + 0, a 320-wide picture's first page)
# read back the exact bytes staged in that slide's compiled NXC.
ZONE_RAM = 0
PAGE_ZONE_OFFSET = 32
PAGE_SIZE = 8192

def decode(m):
    d = {k: m[o] for k, o in FIELDS.items()}
    for k, o in WORDS.items():
        d[k] = m[o] | (m[o + 1] << 8)
    d["sig"] = bytes(m[0:2]).decode("ascii", "replace")
    return d

def read_surface(z, front, mode):
    """Assumes the CPU is already frozen (enter-cpu-step). Reads every 8K
    page of the front Layer 2 surface (10 pages at 320x256, 6 at 256x192)
    through zone 0 and returns the bytes. Leaves the memory zone at 0;
    callers restore it (set-memory-zone -1) once done."""
    npages = 10 if mode else 6
    got = bytearray()
    z.cmd("set-memory-zone %d" % ZONE_RAM)
    for i in range(npages):
        page = front * 2 + i
        offset = (page + PAGE_ZONE_OFFSET) * PAGE_SIZE
        got += z.read_memory(offset, PAGE_SIZE)
    return got

def compare_picture(got, picfile, npages):
    """got vs picfile's bytes after its 512-byte palette. Returns (ok,
    mismatches, first_offset, detail) - detail is a size-mismatch message,
    or None."""
    want = pathlib.Path(picfile).read_bytes()
    expect = want[512:512 + npages * PAGE_SIZE]
    if len(expect) != npages * PAGE_SIZE or len(got) != len(expect):
        return False, -1, -1, ("%s is %d bytes / read %d bytes, expected a %d-byte picture "
                                "(512 palette + %d pages)"
                                % (picfile, len(want), len(got), 512 + npages * PAGE_SIZE, npages))
    mismatches = 0
    first = -1
    for i in range(len(expect)):
        if got[i] != expect[i]:
            mismatches += 1
            if first < 0:
                first = i
    return mismatches == 0, mismatches, first, None

def surface_check(z, front, mode, picfile):
    """Freeze the CPU, compare the front surface against picfile, always
    restoring the CPU (exit-cpu-step) and the live memory zone (-1) before
    returning, even on a read error."""
    z.enter_cpu_step()
    try:
        got = read_surface(z, front, mode)
    finally:
        z.cmd("set-memory-zone -1")
        z.exit_cpu_step()
    npages = 10 if mode else 6
    return compare_picture(got, picfile, npages)

# Breakpoint index reserved for skip_surface_check below; each zes_intro.py
# run is a fresh emulator instance, so no other index is ever armed here.
SKIP_BREAKPOINT = 1

def read_text(z):
    """Freeze the CPU (fix round 1: a live read can tear a row mid-typewriter),
    decode the tilemap at $4000, always resuming (exit-cpu-step) before
    returning, even on a read error."""
    z.enter_cpu_step()
    try:
        rows, _ = tilemap.decode(z.read_memory(0x4000, tilemap.GRID_BYTES))
    finally:
        z.exit_cpu_step()
    return rows

def skip_surface_check(z, pc, picfile):
    """Press skip, free-run under a breakpoint at pc (e.g. chain_run's
    address) so the CPU stops before any hand-off code can overwrite the
    launcher's Layer 2 surface banks, read the mirror for the current
    front/mode, compare against picfile, then resume. A plain frame+sig
    gated surface_check races chain_run here - pressing skip mid-transition
    can reach hand-off within the same frame as trans_finish_now, and the
    interpreter's own boot can already be overwriting memory a poll
    interval later (measured live: a race read 13056/81920 bytes wrong
    where the breakpointed read showed zero)."""
    z.enter_cpu_step()
    try:
        z.enable_breakpoints()
        z.set_breakpoint(SKIP_BREAKPOINT, zrcp.pc_breakpoint_condition(pc))
        z.hold_matrix(SPACE_DOWN)
        try:
            z.run(deadline=30.0)
        finally:
            z.release_matrix()          # never leave SPACE held on a run() deadline
        m = z.read_memory(MIRROR, 32)
        front, mode = m[16], m[17]
        got = read_surface(z, front, mode)
    finally:
        z.cmd("set-memory-zone -1")
        z.disable_breakpoints()
        z.exit_cpu_step()
    npages = 10 if mode else 6
    return compare_picture(got, picfile, npages)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("card")
    ap.add_argument("--launch", required=True)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--space-at", type=float, action="append", default=[])
    ap.add_argument("--space-at-frame", type=int, action="append", default=[])
    ap.add_argument("--assert", dest="asserts", action="append", default=[])
    ap.add_argument("--assert-frame", dest="frame_asserts", action="append", default=[])
    ap.add_argument("--surface-at-frame", dest="surface_asserts", action="append", default=[])
    ap.add_argument("--skip-surface-at-frame", dest="skip_surface", default=None)
    ap.add_argument("--text-at-frame", dest="text_at_frame", type=int, action="append", default=[])
    ap.add_argument("--expect-caption", dest="expect_captions", action="append", default=[])
    ap.add_argument("--expect-handoff", action="store_true")
    ap.add_argument("--expect-text")
    ap.add_argument("--port", type=int, default=10011)
    a = ap.parse_args()
    if (a.frame_asserts or a.space_at_frame or a.surface_asserts or a.skip_surface or a.text_at_frame) and a.interval > 0.1:
        a.interval = 0.1              # frame anchors need frequent sampling to land close to F
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
        pending_space_frame = sorted(a.space_at_frame)
        pending_surface = sorted(
            (int(spec.split(":", 1)[0]), spec.split(":", 1)[1]) for spec in a.surface_asserts)
        pending_skip_surface = None
        if a.skip_surface:
            when_s, pc_s, pic_s = a.skip_surface.split(":", 2)
            pending_skip_surface = (int(when_s), int(pc_s), pic_s)
        pending_text_frame = sorted(a.text_at_frame)
        collected_text = []
        while time.time() - t0 < a.seconds:
            t = time.time() - t0
            if pending_space and t >= pending_space[0]:
                pending_space.pop(0)
                z.hold_matrix(SPACE_DOWN); time.sleep(0.15); z.release_matrix()
                print("t=%.1f space" % t)
            m = z.read_memory(MIRROR, 32)
            d = decode(m)
            samples.append((t, d))
            print("t=%.1f sig=%s state=%d slide=%d load=%d trans=%d code=%02X frame=%d hold=%d tf=%d scroll=%d front=%d mode=%d music=%d keys=%d hz60=%d fadek=%d pcmwr=%04X loadpage=%d fading=%d akytick=%d"
                  % (t, d["sig"], d["state"], d["slide"], d["load"], d["trans"], d["code"], d["frame"], d["hold"], d["tf"], d["scroll"], d["front"], d["mode"], d["music"], d["keys"], d["hz60"], d["fadek"], d["pcmwr"], d["loadpage"], d["fading"], d["akytick"]))
            if pending_space_frame and d["frame"] >= pending_space_frame[0]:
                pending_space_frame.pop(0)
                z.hold_matrix(SPACE_DOWN); time.sleep(0.15); z.release_matrix()
                print("t=%.1f space (frame=%d)" % (t, d["frame"]))
            if pending_surface and d["sig"] == "IN" and d["frame"] >= pending_surface[0][0]:
                when, picfile = pending_surface.pop(0)
                try:
                    s_ok, mism, first, detail = surface_check(z, d["front"], d["mode"], picfile)
                except Exception as e:
                    s_ok, mism, first, detail = False, -1, -1, "exception: %r" % (e,)
                if detail:
                    print("ASSERT FAILED: surface check frame>=%d vs %s: %s" % (when, picfile, detail))
                    ok = False
                elif s_ok:
                    print("surface ok frame>=%d (t=%.1f, actual frame=%d) vs %s" % (when, t, d["frame"], picfile))
                else:
                    print("ASSERT FAILED: surface mismatch frame>=%d (t=%.1f, actual frame=%d) vs %s: "
                          "%d bytes differ, first at offset %d" % (when, t, d["frame"], picfile, mism, first))
                    ok = False
            if pending_skip_surface and d["frame"] >= pending_skip_surface[0]:
                when, pc, picfile = pending_skip_surface
                pending_skip_surface = None
                try:
                    s_ok, mism, first, detail = skip_surface_check(z, pc, picfile)
                except Exception as e:
                    s_ok, mism, first, detail = False, -1, -1, "exception: %r" % (e,)
                if detail:
                    print("ASSERT FAILED: skip-surface check frame>=%d pc=%d vs %s: %s" % (when, pc, picfile, detail))
                    ok = False
                elif s_ok:
                    print("skip-surface ok frame>=%d (t=%.1f, actual frame=%d) pc=%d vs %s" % (when, t, d["frame"], pc, picfile))
                else:
                    print("ASSERT FAILED: skip-surface mismatch frame>=%d (t=%.1f, actual frame=%d) pc=%d vs %s: "
                          "%d bytes differ, first at offset %d" % (when, t, d["frame"], pc, picfile, mism, first))
                    ok = False
            if pending_text_frame and d["frame"] >= pending_text_frame[0]:
                when = pending_text_frame.pop(0)
                rows = read_text(z)
                text = [r.rstrip() for r in rows if r.strip()]
                for r in text:
                    print("text: " + r)
                collected_text.extend(text)
                print("text read frame>=%d (t=%.1f, actual frame=%d)" % (when, t, d["frame"]))
            time.sleep(a.interval)
        have_mirror = any(d["sig"] == "IN" for _, d in samples)
        if (a.asserts or a.frame_asserts or a.surface_asserts or a.skip_surface or a.text_at_frame) and not have_mirror:
            print("ASSERT FAILED: no sample ever showed sig=IN - dbg_init never ran "
                  "(expected for a Release build, which has no mirror) or the mirror "
                  "was never reached before the hand-off window closed")
            ok = False
        if a.asserts and not samples:
            print("ASSERT FAILED: no samples were taken (--seconds too small) - cannot evaluate --assert conditions")
            ok = False
        else:
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
        for spec in a.frame_asserts:
            when, cond = spec.split(":", 1)
            field, value = cond.split("=")
            when = int(when)
            match = next((s for s in samples if s[1]["frame"] >= when), None)
            if match is None:
                last = samples[-1][1]["frame"] if samples else -1
                print("ASSERT FAILED: frame %d never reached (last frame seen=%d)" % (when, last))
                ok = False
                continue
            t, d = match
            got = d[field]
            if got != int(value, 0):
                print("ASSERT FAILED at frame>=%d (t=%.1f, actual frame=%d): %s=%d, expected %s" % (when, t, d["frame"], field, got, value)); ok = False
            else:
                print("assert ok frame>=%d (t=%.1f, actual frame=%d) %s=%s" % (when, t, d["frame"], field, value))
        if pending_surface:
            for when, picfile in pending_surface:
                print("ASSERT FAILED: frame %d never reached for surface check vs %s" % (when, picfile))
                ok = False
        if pending_skip_surface:
            when, pc, picfile = pending_skip_surface
            print("ASSERT FAILED: frame %d never reached for skip-surface check vs %s" % (when, picfile))
            ok = False
        if pending_text_frame:
            for when in pending_text_frame:
                print("ASSERT FAILED: frame %d never reached for text check" % when)
                ok = False
        for expect in a.expect_captions:
            if not any(expect in r for r in collected_text):
                print("ASSERT FAILED: text %r not seen" % expect)
                ok = False
        if a.expect_handoff or a.expect_text:
            head = z.read_memory(0x6000, 4)
            if head == STUB_PROLOGUE:
                print("ASSERT FAILED: $6000 still holds the stub's own prologue - the hand-off never happened")
                ok = False
            else:
                rows, _ = tilemap.decode(z.read_memory(0x6000, tilemap.GRID_BYTES))
                text = [r.rstrip() for r in rows if r.strip()]
                for r in text:
                    print("game: " + r)
                if a.expect_handoff and not text:
                    print("ASSERT FAILED: no interpreter text at $6000 - the hand-off did not reach the game")
                    ok = False
                if a.expect_text and not any(a.expect_text in r for r in text):
                    print("ASSERT FAILED: expected text %r not found at $6000" % a.expect_text)
                    ok = False
        z.close()
    finally:
        proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
