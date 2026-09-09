"""Headless ZEsarUX driver for the launcher: <card dir> --launch NAME.NEX.
Samples the DEBUG mirror at $5400 every --interval; optional --space-at
(seconds) / --space-at-frame (mirror frame count) taps - a tap holds SPACE
until the launcher's own frame counter has advanced, never for a wall-clock
time, since the emulated machine runs at about 10 fps under this loop -
--assert (seconds) / --assert-frame (first sample whose frame >= F) checks,
--surface-at-frame F:<picture file> (stops the launcher at its hold-state
step with a PC breakpoint and byte-compares the front Layer 2 surface
against a compiled NXC/NXI), --skip-surface-at-frame
F:PC:<picture file> (presses skip at frame>=F, breakpoints at PC - e.g.
chain_run's address from the launcher's own .map - so the surface check
runs before any hand-off code can overwrite it, then resumes),
--expect-handoff/--expect-text at $6000 (the hand-off gate). When both are
given, the loop also stops early once two consecutive polls both find
--expect-text's exact string at $6000 (--seconds is then only an upper
bound; any frame-anchored check still pending at that point fails as
unreached) - a single hit is not enough: $6000 is live launcher memory for
the whole run (font data, and on the ndr leg sometimes song data) and can
decode as plausible garbage on any one poll.
--text-at-frame F (repeatable, at the first sample whose mirror frame >= F)
decodes the launcher's own tilemap at $4000 and prints/collects its
non-blank rows; --expect-caption "s" (repeatable) requires each substring
in some collected row. --cols 40|80 (default 80) selects the launcher's own
COLS setting for that $4000 decode; $6000 (--expect-text) is always the
interpreter's fixed 80-column window and is unaffected. Every frame-anchored check (assert-frame,
text-at-frame, surface-at-frame, skip-surface-at-frame, space-at-frame)
evaluates at the first accepted sample with frame >= F, but only if that
sample's frame is within 32 of F: a heavy check (surface/skip-surface)
freezes the CPU for real time ZEsarUX does not replay, so the very next
sample can land dozens of frames past F; an anchor that overshoots FAILS
loudly instead of silently evaluating the wrong frame, so place anchors
with at least 32 frames of margin after a preceding heavy check.
--surface-at-frame also requires that sample's state to be a hold (2, or
3 for KEY), else it fails as landing outside a hold - the capture stops
the CPU at that hold's own step (SHOW_STEP@HOLD / SHOW_STEP@KEY, resolved
from build/intro.map, which the harness stages as build/intro.nex so the
map matches the running launcher). ZEsarUX's frame rate
varies by host, so wall-clock anchors drift - prefer the frame-anchored
flags; --interval tightens to 0.1s automatically when any of them are
given."""
import argparse, pathlib, re, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp, tilemap, nleg, symbols

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
MIRROR = 0x5400
FIELDS = {"seq": 2, "state": 3, "slide": 4, "load": 5, "trans": 6, "code": 7,
          "front": 16, "mode": 17, "music": 18, "keys": 19, "hz60": 20, "fadek": 21,
          "loadpage": 24, "fading": 25, "slides": 26, "skip": 27, "akytick": 28,
          "ayspage": 29}
WORDS = {"frame": 8, "hold": 10, "tf": 12, "scroll": 14, "pcmwr": 22, "pcmrd": 30}
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

# Fix round 3: a surface capture stops the CPU at the launcher's own hold
# step instead of inside a bare enter-cpu-step, which does not hold the
# machine across a ten-page read (see read_surface_at_hold).
INTRO_MAP = ROOT / "build" / "intro.map"
INTRO_NEX = ROOT / "build" / "intro.nex"
HOLD_PC_SYMBOL = {2: "SHOW_STEP@HOLD", 3: "SHOW_STEP@KEY"}
SURFACE_BREAKPOINT = 2
SURFACE_RUN_DEADLINE = 10.0

# Fix round 3/4, measured: ZEsarUX refuses enter-cpu-step sporadically
# ("Can not enter cpu step mode", roughly 7% of attempts at any gap), and
# an unchecked refusal leaves the machine RUNNING under the reads after it.
CPU_STEP_RETRY_S = 0.1
CPU_STEP_ATTEMPTS = 20

def freeze(z):
    """enter-cpu-step, retried until the emulator accepts it. Raises
    rather than read a machine that was never stopped."""
    reply = ""
    for _ in range(CPU_STEP_ATTEMPTS):
        reply = z.enter_cpu_step()
        if not reply.lstrip().lower().startswith("error"):
            return
        time.sleep(CPU_STEP_RETRY_S)
    raise RuntimeError("enter-cpu-step refused %d times in a row: %r"
                        % (CPU_STEP_ATTEMPTS, reply))

def decode(m):
    d = {k: m[o] for k, o in FIELDS.items()}
    for k, o in WORDS.items():
        d[k] = m[o] | (m[o + 1] << 8)
    d["sig"] = bytes(m[0:2]).decode("ascii", "replace")
    return d

# Fix round 1: a leg that remaps NR $52/$53 mid-frame (the NDR leg) can make
# a live mirror read land on the wrong page - sig can even read "IN" by luck
# while later fields are torn (a real incident: frame jumped to 60138 while
# state/slide/trans stayed correct). Requiring a plausible frame on top of
# sig=="IN" catches that; real frame steps are at most a handful per poll.
def frames_agree(d, other):
    return abs(d["frame"] - other["frame"]) <= 64

# Fix round 1: not a torn read - a heavy check's freeze is dead time,
# so the next sample can overshoot an anchor by dozens of frames.
# Overshoot must fail loudly, not silently grade a wrong frame.
FRAME_OVERSHOOT_MARGIN = 32

def frame_overshot(anchor, actual):
    return actual > anchor + FRAME_OVERSHOOT_MARGIN

def sample_plausible(d, last):
    if d["sig"] != "IN":
        return False
    if last is None:
        return True
    delta = d["frame"] - last["frame"]
    return 0 <= delta <= 64

def read_surface(z, front, mode):
    """Assumes the CPU is already stopped (at a breakpoint, or in
    enter-cpu-step for skip_surface_check's own stop). Reads the front
    Layer 2 surface (10 pages at 320x256, 6 at 256x192) through zone 0 in
    ONE read (fix round 2: the pages are contiguous in zone-0 address
    space, and ten separate ZRCP round trips - each with its own
    prompt-wait latency - was most of the capture's real-time window,
    the very thing letting the emulator resume mid-read). Leaves the
    memory zone at 0; callers restore it (set-memory-zone -1) once done."""
    npages = 10 if mode else 6
    page0 = front * 2
    offset = (page0 + PAGE_ZONE_OFFSET) * PAGE_SIZE
    z.cmd("set-memory-zone %d" % ZONE_RAM)
    return bytearray(z.read_memory(offset, npages * PAGE_SIZE))

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

CAPTURE_ATTEMPTS = 3

def _mirror_frame(z):
    m = z.read_memory(MIRROR + 8, 2)
    return m[0] | (m[1] << 8)

# Fix round 4: a wall-clock hold is not a keypress. The emulated machine
# runs at roughly 10 fps inside this loop, so the old 0.15s hold spanned
# about 1.5 emulated frames and input_poll could miss the edge entirely.
PRESS_FRAMES = 4
PRESS_DEADLINE_S = 8.0
# A frame further ahead than a press can possibly last is a torn read;
# a mirror that reads settled non-IN this many polls has handed off.
PRESS_FRAME_WINDOW = 1000
PRESS_DEAD_POLLS = 3

def _mirror_stopped(z):
    """(sample, torn) read twice with the CPU stopped. torn means the two
    reads differed - the NDR leg can page the mirror out mid-frame, so
    even a stopped read lands wrong sometimes (frame 60138, seen live)."""
    freeze(z)
    try:
        m1 = z.read_memory(MIRROR, 32)
        m2 = z.read_memory(MIRROR, 32)
    finally:
        z.exit_cpu_step()
    if bytes(m1) != bytes(m2):
        return None, True
    return decode(m1), False

def press_base(z, last):
    """Frame to measure a press from: a fresh stopped read, cross-checked
    against the last accepted sample so a torn one cannot become the
    baseline."""
    for _ in range(10):
        d, torn = _mirror_stopped(z)
        if not torn and d["sig"] == "IN" and (last is None or frames_agree(d, last)):
            return d["frame"]
        time.sleep(0.05)
    raise RuntimeError("no trustworthy mirror sample to measure a key press from")

def press_space(z, base):
    """Hold SPACE until the launcher's own frame counter has advanced
    PRESS_FRAMES frames past base, then release. A press that ends the
    show hands off, and the mirror dies with it, so a settled non-IN
    mirror also ends the hold; torn reads are ignored, never counted.
    Raises if neither happens inside PRESS_DEADLINE_S - a press the
    machine never saw must fail loudly."""
    z.hold_matrix(SPACE_DOWN)
    try:
        dead = 0
        t0 = time.time()
        while time.time() - t0 < PRESS_DEADLINE_S:
            d, torn = _mirror_stopped(z)
            if not torn and d["sig"] != "IN":
                dead += 1
                if dead >= PRESS_DEAD_POLLS:
                    return
            elif not torn and 0 <= d["frame"] - base <= PRESS_FRAME_WINDOW:
                dead = 0
                if d["frame"] - base >= PRESS_FRAMES:
                    return
            time.sleep(0.05)
    finally:
        z.release_matrix()
    raise RuntimeError("SPACE held %.1fs from frame %d but the mirror never advanced "
                        "%d frames" % (PRESS_DEADLINE_S, base, PRESS_FRAMES))

def check_staged_launcher(staged):
    """The breakpoint addresses come from build/intro.map, so the staged
    launcher must be that same build - a stale .NEX would be breakpointed
    at addresses that are something else now, or never executed."""
    if not INTRO_NEX.exists():
        raise SystemExit("%s is missing - build the launcher before a breakpoint capture"
                          % INTRO_NEX)
    if not staged.exists():
        raise SystemExit("%s is missing - stage the card before a breakpoint capture" % staged)
    if staged.read_bytes() != INTRO_NEX.read_bytes():
        raise SystemExit("staged launcher %s differs from build\\intro.nex - restage "
                          "before using breakpoint captures" % staged)

def load_hold_pcs():
    """Resolve the launcher's hold-step addresses from its build map.
    The staged launcher is checked against build/intro.nex separately, so
    these addresses match the machine that runs."""
    if not INTRO_MAP.exists():
        raise SystemExit("%s is missing - build the launcher before a surface check"
                          % INTRO_MAP)
    syms = symbols.load_symbols(INTRO_MAP)
    pcs = {}
    for state, name in HOLD_PC_SYMBOL.items():
        if name not in syms:
            raise SystemExit("symbol %s not found in %s - a surface check cannot "
                              "stop the launcher at a known point" % (name, INTRO_MAP))
        pcs[state] = syms[name]
    return pcs

def _stopped_pc(z):
    """PC from get-registers, or None if the reply does not carry one."""
    reply = z.get_registers()
    m = re.search(r"\bPC=([0-9A-Fa-f]{1,4})", reply)
    return (int(m.group(1), 16), reply) if m else (None, reply)

def read_surface_at_hold(z, pc, picfile):
    """Stop the launcher at its hold step (pc) and capture the front
    surface there. A bare enter-cpu-step does not hold the emulated CPU
    across a ten-page read - measured: the mirror frame advanced inside
    one bracket and back-to-back captures differed by up to 81600 bytes -
    while a capture taken stopped at a breakpoint read back byte-exact.
    Returns (ok, mismatches, first_offset, detail, before, after); before
    and after are the mirror frame inside the stop, which cannot move
    while the CPU is stopped, so a move means the stop was not real."""
    freeze(z)
    try:
        z.enable_breakpoints()
        z.set_breakpoint(SURFACE_BREAKPOINT, zrcp.pc_breakpoint_condition(pc))
        reply = z.run(deadline=SURFACE_RUN_DEADLINE)
        got_pc, regs = _stopped_pc(z)
        if "Breakpoint fired" not in reply or got_pc != pc:
            return (False, -1, -1,
                    "breakpoint PC=%d did not stop the machine (run returned %r, "
                    "registers %r)" % (pc, reply[:120], regs[:120]), -1, -1)
        m = z.read_memory(MIRROR, 32)
        front, mode = m[16], m[17]
        before = m[8] | (m[9] << 8)
        got = read_surface(z, front, mode)
        z.cmd("set-memory-zone -1")
        after = _mirror_frame(z)
    finally:
        z.cmd("set-memory-zone -1")
        z.disable_breakpoint(SURFACE_BREAKPOINT)
        z.disable_breakpoints()
        z.exit_cpu_step()
    if before != after:
        return (False, -1, -1, "mirror frame moved %d->%d while stopped at PC=%d - "
                "the capture is not trustworthy" % (before, after, pc), before, after)
    npages = 10 if mode else 6
    ok, mism, first, detail = compare_picture(got, picfile, npages)
    return ok, mism, first, detail, before, after

# Breakpoint index reserved for skip_surface_check below; the surface
# capture above owns SURFACE_BREAKPOINT and retires it after each check,
# so an enable-breakpoints here never re-arms it.
SKIP_BREAKPOINT = 1

def read_handoff_text(z):
    """Freeze the CPU, decode the tilemap at $6000 (the post-hand-off
    interpreter window - NOT $4000, that is the launcher's own caption
    tilemap read by read_text below), always resuming before returning.
    Returns [] while $6000 still holds the stub's own prologue, whose
    opcodes would otherwise decode as meaningless rows."""
    freeze(z)
    try:
        head = z.read_memory(0x6000, 4)
        if bytes(head) == STUB_PROLOGUE:
            return []
        rows, _ = tilemap.decode(z.read_memory(0x6000, tilemap.GRID_BYTES))
    finally:
        z.exit_cpu_step()
    return rows

def read_text(z, cols=80):
    """Freeze the CPU, decode the tilemap at $4000, retried (fix round 2)
    if the mirror frame moves during the capture - a live read can
    otherwise tear a row mid-typewriter. Kept on enter-cpu-step rather
    than the breakpoint capture below: 5120 bytes is one short read, and a
    text anchor is not gated to a hold, so there is no one PC to stop at.
    cols selects the launcher's own COLS setting (40 or 80, --cols); the
    40-column map packs its live cells into the first cols*32*2 bytes of
    the same $4000 buffer (tmStride is halved, not the base address)."""
    grid_bytes = cols * tilemap.ROWS * 2
    tried = []
    for _ in range(CAPTURE_ATTEMPTS):
        freeze(z)
        try:
            before = _mirror_frame(z)
            rows, _ = tilemap.decode(z.read_memory(0x4000, grid_bytes), cols=cols)
            after = _mirror_frame(z)
        finally:
            z.exit_cpu_step()
        if before == after:
            return rows
        tried.append((before, after))
    raise RuntimeError("text capture unstable across %d attempts (frame %s)"
                        % (CAPTURE_ATTEMPTS, ", ".join("%d->%d" % t for t in tried)))

def skip_surface_check(z, pc, picfile):
    """Press skip, free-run under a breakpoint at pc (e.g. chain_run's
    address) so the CPU stops before any hand-off code can overwrite the
    launcher's Layer 2 surface banks, read the mirror for the current
    front/mode, compare against picfile, then resume. A plain frame+sig
    gated surface read races chain_run here - pressing skip mid-transition
    can reach hand-off within the same frame as trans_finish_now, and the
    interpreter's own boot can already be overwriting memory a poll
    interval later (measured live: a race read 13056/81920 bytes wrong
    where the breakpointed read showed zero)."""
    freeze(z)
    try:
        z.enable_breakpoints()
        z.set_breakpoint(SKIP_BREAKPOINT, zrcp.pc_breakpoint_condition(pc))
        # Exempt from press_space's emulated-frame hold: run() executes at
        # full speed until the breakpoint, so the key is down for however
        # many emulated frames it takes to get there, not for wall time.
        z.hold_matrix(SPACE_DOWN)
        try:
            reply = z.run(deadline=30.0)
        finally:
            z.release_matrix()          # never leave SPACE held on a run() deadline
        # A PC from an older build never fires: report it, do not read a
        # machine that was never stopped.
        if "Breakpoint fired" not in reply:
            raise RuntimeError("breakpoint PC=%d never fired (run returned %r) - "
                               "check the address against the current build map"
                               % (pc, reply[:160]))
        m = z.read_memory(MIRROR, 32)
        front, mode = m[16], m[17]
        got = read_surface(z, front, mode)
    finally:
        z.cmd("set-memory-zone -1")
        z.disable_breakpoint(SKIP_BREAKPOINT)
        z.disable_breakpoints()
        z.exit_cpu_step()
    npages = 10 if mode else 6
    return compare_picture(got, picfile, npages)

def main():
    # A torn sample's "sig" can hold non-ASCII garbage (NDR remaps NR
    # $52/$53 mid-frame); printing it via %r under Windows' cp1252 file
    # encoding crashes the run - reconfigure stdout instead.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    except AttributeError:
        pass          # older Python without TextIOWrapper.reconfigure
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
    ap.add_argument("--cols", type=int, default=80, choices=(40, 80),
                     help="launcher's own COLS setting, for --text-at-frame's $4000 decode")
    ap.add_argument("--port", type=int, default=10011)
    a = ap.parse_args()
    if (a.frame_asserts or a.space_at_frame or a.surface_asserts or a.skip_surface or a.text_at_frame) and a.interval > 0.1:
        a.interval = 0.1              # frame anchors need frequent sampling to land close to F
    card = pathlib.Path(a.card).resolve()
    # Resolved before the emulator starts: a stale card, a missing map or a
    # missing symbol must fail the run outright, not halfway through a check.
    if a.surface_asserts or a.skip_surface:
        check_staged_launcher(card / a.launch)
    hold_pcs = load_hold_pcs() if a.surface_asserts else {}
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
        last_accepted = None
        pending_candidate = None          # most recent sig=="IN" sample not (yet) accepted
        accepted_count = 0
        discarded_count = 0
        double_read_mismatch_count = 0
        handoff_hits = 0
        while time.time() - t0 < a.seconds:
            t = time.time() - t0
            if pending_space and t >= pending_space[0]:
                pending_space.pop(0)
                try:
                    press_space(z, press_base(z, last_accepted))
                except RuntimeError as e:
                    print("ASSERT FAILED: space at t=%.1f: %s" % (t, e))
                    ok = False
                else:
                    print("t=%.1f space" % t)
            # Runs every poll (the mirror goes permanently torn once
            # hand-off completes, so gating on it would never fire). Two
            # consecutive hits guard against $6000 (font/song data) garbage.
            if a.expect_handoff and a.expect_text:
                rows = read_handoff_text(z)
                if any(a.expect_text in r for r in rows):
                    handoff_hits += 1
                    if handoff_hits >= 2:
                        print("t=%.1f hand-off text %r observed twice - stopping early" % (t, a.expect_text))
                        break
                else:
                    handoff_hits = 0
            # enter/exit-cpu-step brackets the read; a frozen CPU does not by
            # itself make the 32 bytes atomic (fix round 2: a freeze can still
            # land mid-dbg_mirror, catching some fields already written for
            # this frame and others not yet) - read twice and require the
            # bytes identical, else discard as torn.
            freeze(z)
            try:
                m1 = z.read_memory(MIRROR, 32)
                m2 = z.read_memory(MIRROR, 32)
            finally:
                z.exit_cpu_step()
            if bytes(m1) != bytes(m2):
                double_read_mismatch_count += 1
                discarded_count += 1
                print("t=%.1f TORN sample discarded (double-read mismatch)" % t)
                pending_candidate = None
                time.sleep(a.interval)
                continue
            d = decode(m1)
            if d["sig"] != "IN":
                discarded_count += 1
                print("t=%.1f TORN sample discarded sig=%r" % (t, d["sig"]))
                pending_candidate = None
                time.sleep(a.interval)
                continue
            if sample_plausible(d, last_accepted):
                pass                       # accepted below
            elif pending_candidate is not None and frames_agree(d, pending_candidate):
                # two consecutive sig=="IN" samples agree with each other but
                # not with last_accepted: a real gap (host stall, or a free
                # run under skip_surface_check's breakpoint) - re-anchor
                # rather than rejecting every later sample forever.
                print("t=%.1f re-anchored frame=%d (gap from last accepted frame=%s)"
                      % (t, d["frame"], last_accepted["frame"] if last_accepted else "-"))
            else:
                discarded_count += 1
                print("t=%.1f TORN sample discarded sig=%r frame=%d (last accepted frame=%s)"
                      % (t, d["sig"], d["frame"], last_accepted["frame"] if last_accepted else "-"))
                pending_candidate = d
                time.sleep(a.interval)
                continue
            last_accepted = d
            pending_candidate = None
            accepted_count += 1
            samples.append((t, d))
            print("t=%.1f sig=%s state=%d slide=%d load=%d trans=%d code=%02X frame=%d hold=%d tf=%d scroll=%d front=%d mode=%d music=%d keys=%d hz60=%d fadek=%d pcmwr=%04X pcmrd=%04X loadpage=%d fading=%d akytick=%d ayspage=%d"
                  % (t, d["sig"], d["state"], d["slide"], d["load"], d["trans"], d["code"], d["frame"], d["hold"], d["tf"], d["scroll"], d["front"], d["mode"], d["music"], d["keys"], d["hz60"], d["fadek"], d["pcmwr"], d["pcmrd"], d["loadpage"], d["fading"], d["akytick"], d["ayspage"]))
            if pending_space_frame and d["frame"] >= pending_space_frame[0]:
                when = pending_space_frame.pop(0)
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: space anchor frame %d overshot to frame %d (>%d past anchor)"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN))
                    ok = False
                else:
                    try:
                        press_space(z, d["frame"])
                    except RuntimeError as e:
                        print("ASSERT FAILED: space at frame>=%d: %s" % (when, e))
                        ok = False
                    else:
                        print("t=%.1f space (frame=%d)" % (t, d["frame"]))
            if pending_surface and d["frame"] >= pending_surface[0][0]:
                when, picfile = pending_surface.pop(0)
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: surface anchor frame %d overshot to frame %d (>%d past anchor) vs %s"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN, picfile))
                    ok = False
                elif d["state"] not in (2, 3):
                    print("ASSERT FAILED: surface anchor frame>=%d landed outside a hold (state=%d) vs %s"
                          % (when, d["state"], picfile))
                    ok = False
                else:
                    pc = hold_pcs[d["state"]]
                    try:
                        s_ok, mism, first, detail, bf, af = read_surface_at_hold(z, pc, picfile)
                    except Exception as e:
                        s_ok, mism, first, detail, bf, af = False, -1, -1, "exception: %r" % (e,), -1, -1
                    if detail:
                        print("ASSERT FAILED: surface check frame>=%d vs %s: %s" % (when, picfile, detail))
                        ok = False
                    elif s_ok:
                        print("surface ok frame>=%d (t=%.1f, actual frame=%d, stopped at PC=%d, "
                              "mirror frame %d->%d) vs %s" % (when, t, d["frame"], pc, bf, af, picfile))
                    else:
                        print("ASSERT FAILED: surface mismatch frame>=%d (t=%.1f, actual frame=%d, "
                              "stopped at PC=%d, mirror frame %d->%d) vs %s: %d bytes differ, first at "
                              "offset %d" % (when, t, d["frame"], pc, bf, af, picfile, mism, first))
                        ok = False
            if pending_skip_surface and d["frame"] >= pending_skip_surface[0]:
                when, pc, picfile = pending_skip_surface
                pending_skip_surface = None
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: skip-surface anchor frame %d overshot to frame %d (>%d past anchor) vs %s"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN, picfile))
                    ok = False
                else:
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
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: text anchor frame %d overshot to frame %d (>%d past anchor)"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN))
                    ok = False
                else:
                    try:
                        rows = read_text(z, cols=a.cols)
                    except RuntimeError as e:
                        print("ASSERT FAILED: text check frame>=%d: %s" % (when, e))
                        ok = False
                    else:
                        text = [r.rstrip() for r in rows if r.strip()]
                        for r in text:
                            print("text: " + r)
                        collected_text.extend(text)
                        print("text read frame>=%d (t=%.1f, actual frame=%d)" % (when, t, d["frame"]))
            time.sleep(a.interval)
        print("sample summary: %d accepted, %d discarded (%d double-read mismatches)"
              % (accepted_count, discarded_count, double_read_mismatch_count))
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
            # Fix round 2: a.interval (0.1s, the loop's sleep) understates
            # the real sample period under frozen reads (~0.4-0.5s) - use
            # twice the observed median spacing between samples instead.
            gaps = sorted(samples[i][0] - samples[i - 1][0] for i in range(1, len(samples)))
            assert_tol = 2 * gaps[len(gaps) // 2] if gaps else a.interval
            for spec in a.asserts:
                when, cond = spec.split(":", 1)
                field, value = cond.split("=")
                when = float(when)
                t, d = min(samples, key=lambda s: abs(s[0] - when))
                if abs(t - when) > assert_tol:
                    # An early exit truncates the sample list; fail rather
                    # than grade a wall-clock anchor against a sample from
                    # the wrong moment.
                    print("ASSERT FAILED: nearest sample to t=%.1f is at t=%.1f (more than %.1fs "
                          "away - truncated sample list?)" % (when, t, assert_tol))
                    ok = False
                    continue
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
            if frame_overshot(when, d["frame"]):
                print("ASSERT FAILED: frame %d anchor overshot to frame %d (>%d past anchor) for %s"
                      % (when, d["frame"], FRAME_OVERSHOOT_MARGIN, cond))
                ok = False
                continue
            got = d[field]
            if got != int(value, 0):
                print("ASSERT FAILED at frame>=%d (t=%.1f, actual frame=%d): %s=%d, expected %s" % (when, t, d["frame"], field, got, value)); ok = False
            else:
                print("assert ok frame>=%d (t=%.1f, actual frame=%d) %s=%s" % (when, t, d["frame"], field, value))
        if pending_space:
            for when in pending_space:
                print("ASSERT FAILED: space at t=%.1f never fired" % when)
                ok = False
        if pending_space_frame:
            for when in pending_space_frame:
                print("ASSERT FAILED: frame %d never reached for space press" % when)
                ok = False
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
            # A live mirror at the end means the launcher never handed off,
            # which is a plainer fact than whatever $6000 decodes as.
            freeze(z)
            try:
                end = decode(z.read_memory(MIRROR, 32))
            finally:
                z.exit_cpu_step()
            if end["sig"] == "IN":
                print("ASSERT FAILED: launcher still showing (state %d, frame %d): "
                      "the hand-off never happened" % (end["state"], end["frame"]))
                ok = False
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
