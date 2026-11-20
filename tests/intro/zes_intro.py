"""Intro launcher driver on CSpect (tests/cspect): <card dir> --launch NAME.NEX.

Boots the launcher stopped at its entry with build/intro.map (the staged launcher
must equal build/intro.nex), then reads the DEBUG mirror at $5400 once per launcher
frame, stopped at main_loop (dbg_mirror has just mapped bank 5), until chain_run
(the hand-off) or --seconds. Seconds are emulated: launcher frames / 50 (60 when
the mirror's hz60 is set). --interval sets how often a sample line is printed;
every check sees every frame.

--space-at S / --space-at-frame F hold SPACE for PRESS_FRAMES launcher frames at
the first sample at or past the anchor. --assert S:field=v checks the sample
nearest S; --assert-frame F:field=v the first sample whose frame >= F.
--surface-at-frame F:<picture file> needs that sample in a hold (state 2, or 3 for
KEY), runs to that hold's step (SHOW_STEP@HOLD / SHOW_STEP@KEY) and byte-compares
the front Layer 2 surface (10 pages at 320x256, 6 at 256x192) with the compiled
NXC/NXI after its 512-byte palette. --skip-surface-at-frame F:PC:<picture file>
queues SPACE, runs to PC (e.g. chain_run's address from build/intro.map) and
compares the front surface there, before any hand-off code can overwrite it.
--text-at-frame F (repeatable) decodes the launcher's own tilemap at $4000 (--cols
40|80, its COLS setting); --expect-caption "s" (repeatable) needs each substring in
some collected row. --expect-handoff / --expect-text "s": once chain_run has run,
the interpreter's 80-column tilemap at $6000 must show text / s; s must be seen on
two consecutive polls, since $6000 holds launcher data until the interpreter clears
it. A frame anchor whose first sample is more than 32 frames late fails (only a SPACE
hold runs unsampled). An input edge the harness did not send (the mirror's keys count
moving with no press) fails the run: CSpect passes host mouse clicks to the guest even
minimised. --port is the harness MCP port (tests/cspect/launcher.py PORT_RANGE, default
the first free)."""
import argparse, pathlib, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
sys.path.insert(0, str(ROOT / "tests"))
import tilemap                                          # noqa: E402
from cspect import Session                              # noqa: E402
from cspect.client import CSpectError, read_map         # noqa: E402

MIRROR = 0x5400
MIRROR_PAGE, MIRROR_OFFSET = 10, 0x1400                 # bank 5 low page (src/intro/intro.inc)
FIELDS = {"seq": 2, "state": 3, "slide": 4, "load": 5, "trans": 6, "code": 7,
          "front": 16, "mode": 17, "music": 18, "keys": 19, "hz60": 20, "fadek": 21,
          "loadpage": 24, "fading": 25, "slides": 26, "skip": 27, "akytick": 28,
          "ayspage": 29}
WORDS = {"frame": 8, "hold": 10, "tf": 12, "scroll": 14, "pcmwr": 22, "pcmrd": 30}
# stub: di / ld sp,$7FE0 (chain.asm) - if $6000 still starts with this, the
# stub never handed off and any decoded "text" there is its own opcodes.
STUB_PROLOGUE = bytes.fromhex("f331e07f")
INTRO_MAP = ROOT / "build" / "intro.map"
INTRO_NEX = ROOT / "build" / "intro.nex"
HOLD_PC_SYMBOL = {2: "SHOW_STEP@HOLD", 3: "SHOW_STEP@KEY"}
NEEDED = ("MAIN_LOOP", "CHAIN_RUN", "FRAMECOUNTER", *HOLD_PC_SYMBOL.values())
PAGE_SIZE = 8192
PRESS_FRAMES = 4
FRAME_OVERSHOOT_MARGIN = 32
STEP_S = 10.0                  # host deadline for one launcher frame
SKIP_RUN_S = 30.0              # host deadline for a skip press to reach its PC
HANDOFF_S = 30.0               # host deadline for the interpreter's text after chain_run
HANDOFF_POLL_S = 0.25
HANDOFF_STABLE_POLLS = 3       # identical non-empty reads that end an --expect-handoff wait


def decode(m):
    d = {k: m[o] for k, o in FIELDS.items()}
    for k, o in WORDS.items():
        d[k] = m[o] | (m[o + 1] << 8)
    d["sig"] = bytes(m[0:2]).decode("ascii", "replace")
    return d


def frame_overshot(anchor, actual):
    return actual > anchor + FRAME_OVERSHOOT_MARGIN


def read_surface(s, front, mode):
    """The front Layer 2 surface: 10 pages from page front*2 at 320x256, 6 at 256x192."""
    npages = 10 if mode else 6
    return bytearray(b"".join(s.read_page(front * 2 + i, 0, PAGE_SIZE) for i in range(npages)))


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
    diffs = [i for i in range(len(expect)) if got[i] != expect[i]]
    return not diffs, len(diffs), diffs[0] if diffs else -1, None


def surface_at(s, picfile):
    """Front surface vs picfile with the CPU stopped; the mirror front/mode are read there
    through read_page, which checks bank 5 is mapped. (ok, mism, first, detail, frame)."""
    m = s.read_page(MIRROR_PAGE, MIRROR_OFFSET, 32)
    d = decode(m)
    got = read_surface(s, d["front"], d["mode"])
    return (*compare_picture(got, picfile, 10 if d["mode"] else 6), d["frame"])


def check_staged_launcher(staged):
    """The breakpoint addresses come from build/intro.map, so the staged
    launcher must be that same build."""
    if not INTRO_NEX.exists():
        raise SystemExit("%s is missing - build the launcher first" % INTRO_NEX)
    if not staged.exists():
        raise SystemExit("%s is missing - stage the card first" % staged)
    if staged.read_bytes() != INTRO_NEX.read_bytes():
        raise SystemExit("staged launcher %s differs from build\\intro.nex - restage" % staged)
    if not INTRO_MAP.exists():
        raise SystemExit("%s is missing - build the launcher first" % INTRO_MAP)
    missing = [n for n in NEEDED if n not in read_map(INTRO_MAP)]
    if missing:
        raise SystemExit("symbols %s not found in %s" % (", ".join(missing), INTRO_MAP))


def press_space(s, chain):
    """Hold SPACE PRESS_FRAMES frames from a stop; press_keys' frame count, or None if
    chain_run stopped the CPU inside the hold (the press stalls, its reply is not 'done')."""
    s.resume()
    try:
        return s.press("SPACE", PRESS_FRAMES)
    except CSpectError:
        if s.stopped_at() == chain:
            return None
        raise


def queue_space(s):
    """Queue SPACE with the CPU stopped; CSpect presses it once the CPU runs (Session.press
    refuses a stopped CPU)."""
    t = s.mcp.text(s.mcp.call("press_keys", keys="SPACE", hold_frames=PRESS_FRAMES))
    if not t.startswith("Keys queued"):
        raise RuntimeError("press_keys with the CPU stopped: %r" % t[:200])


def read_text(s, cols):
    """The launcher's own tilemap at $4000; the 40-column map packs its live cells into
    the first cols*32*2 bytes of the same buffer."""
    rows, _ = tilemap.decode(s.read(0x4000, cols * tilemap.ROWS * 2), cols=cols)
    return rows


def handoff_rows(s):
    """Interpreter rows at $6000, [] while it still holds the stub's own prologue."""
    if s.read(0x6000, 4) == STUB_PROLOGUE:
        return []
    rows, _ = tilemap.decode(s.read(0x6000, tilemap.GRID_BYTES))
    return [r.rstrip() for r in rows if r.strip()]


def wait_handoff_text(s, expect_text):
    """After chain_run: poll $6000 until expect_text shows on two consecutive polls, or
    (no expect_text) HANDOFF_STABLE_POLLS identical non-empty reads; rows as they stand."""
    seen = []

    def settled():
        rows = handoff_rows(s)
        seen.append(rows)
        tail = seen[-2:] if expect_text else seen[-HANDOFF_STABLE_POLLS:]
        if expect_text:
            return len(tail) == 2 and all(any(expect_text in r for r in t) for t in tail)
        return len(tail) == HANDOFF_STABLE_POLLS and tail[0] and all(t == tail[0] for t in tail)
    try:
        s.wait_until(settled, HANDOFF_S, HANDOFF_POLL_S, "the interpreter's text at $6000")
    except TimeoutError as e:
        print("hand-off text wait: %s" % e)
    return seen[-1] if seen else []


def main():
    # A sig can hold non-ASCII bytes; print them under any console encoding.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    except AttributeError:
        pass
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
    ap.add_argument("--port", type=int, default=None)
    a = ap.parse_args()
    card = pathlib.Path(a.card).resolve()
    check_staged_launcher(card / a.launch)
    ok = True
    pending_space = sorted(a.space_at)
    pending_space_frame = sorted(a.space_at_frame)
    pending_surface = sorted(
        (int(spec.split(":", 1)[0]), spec.split(":", 1)[1]) for spec in a.surface_asserts)
    pending_skip_surface = None
    if a.skip_surface:
        when_s, pc_s, pic_s = a.skip_surface.split(":", 2)
        pending_skip_surface = (int(when_s), int(pc_s, 0), pic_s)
    pending_text_frame = sorted(a.text_at_frame)
    collected_text = []
    samples = []
    no_mirror = 0
    handed_off = False
    t0 = time.time()
    with Session.boot(card, card / a.launch, INTRO_MAP, paused=True, port=a.port) as s:
        print("CSpect PID %d on MCP port %d" % (s.pid, s.inst.port), flush=True)
        main_loop, chain = s.sym("MAIN_LOOP"), s.sym("CHAIN_RUN")
        hold_pcs = {st: s.sym(name) for st, name in HOLD_PC_SYMBOL.items()}
        s.set_breakpoint(chain)
        next_print, last_key, sent = 0.0, None, False
        while True:
            try:
                pc = s.run_to(main_loop, STEP_S)
            except TimeoutError as e:
                print("ASSERT FAILED: the launcher stopped looping: %s" % e)
                ok = False
                break
            if pc == chain:
                handed_off = True
                print("hand-off: chain_run reached after frame %s"
                      % (samples[-1][1]["frame"] if samples else "-"))
                break
            if pc != main_loop:
                raise CSpectError("stopped at $%04X, not main_loop $%04X" % (pc, main_loop))
            d = decode(s.read(MIRROR, 32))
            if d["sig"] != "IN":
                no_mirror += 1
                d["frame"], d["hz60"] = s.frame(), 0
            t = d["frame"] / (60.0 if d["hz60"] else 50.0)
            if d["sig"] == "IN":
                # CSpect passes host mouse clicks to the guest even minimised (input_scan reads $FADF)
                if samples and d["keys"] != samples[-1][1]["keys"] and not sent:
                    print("ASSERT FAILED: input edge the harness did not send by frame %d (keys %d -> %d): "
                          "host mouse click?" % (d["frame"], samples[-1][1]["keys"], d["keys"]))
                    ok = False
                sent = False
                samples.append((t, d))
                key = (d["state"], d["slide"], d["trans"], d["front"], d["mode"], d["fading"])
                if t >= next_print or key != last_key:
                    next_print, last_key = t + a.interval, key
                    print("t=%.2f sig=%s state=%d slide=%d load=%d trans=%d code=%02X frame=%d hold=%d tf=%d scroll=%d front=%d mode=%d music=%d keys=%d hz60=%d fadek=%d pcmwr=%04X pcmrd=%04X loadpage=%d fading=%d akytick=%d ayspage=%d"
                          % (t, d["sig"], d["state"], d["slide"], d["load"], d["trans"], d["code"], d["frame"], d["hold"], d["tf"], d["scroll"], d["front"], d["mode"], d["music"], d["keys"], d["hz60"], d["fadek"], d["pcmwr"], d["pcmrd"], d["loadpage"], d["fading"], d["akytick"], d["ayspage"]))
            if pending_text_frame and d["frame"] >= pending_text_frame[0]:
                when = pending_text_frame.pop(0)
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: text anchor frame %d overshot to frame %d (>%d past anchor)"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN))
                    ok = False
                else:
                    text = [r.rstrip() for r in read_text(s, a.cols) if r.strip()]
                    for r in text:
                        print("text: " + r)
                    collected_text.extend(text)
                    print("text read frame>=%d (t=%.2f, actual frame=%d)" % (when, t, d["frame"]))
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
                    got_pc = s.run_to(pc, STEP_S)
                    if got_pc != pc:
                        print("ASSERT FAILED: surface check frame>=%d stopped at $%04X, not the hold step $%04X"
                              % (when, got_pc, pc))
                        ok = False
                        handed_off = got_pc == chain
                        if handed_off:
                            break
                    else:
                        s_ok, mism, first, detail, mf = surface_at(s, picfile)
                        if detail:
                            print("ASSERT FAILED: surface check frame>=%d vs %s: %s" % (when, picfile, detail))
                            ok = False
                        elif s_ok:
                            print("surface ok frame>=%d (t=%.2f, actual frame=%d, stopped at PC=%d, mirror frame %d) vs %s"
                                  % (when, t, d["frame"], pc, mf, picfile))
                        else:
                            print("ASSERT FAILED: surface mismatch frame>=%d (t=%.2f, actual frame=%d, stopped at PC=%d, "
                                  "mirror frame %d) vs %s: %d bytes differ, first at offset %d"
                                  % (when, t, d["frame"], pc, mf, picfile, mism, first))
                            ok = False
            if pending_skip_surface and d["frame"] >= pending_skip_surface[0]:
                when, pc, picfile = pending_skip_surface
                pending_skip_surface = None
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: skip-surface anchor frame %d overshot to frame %d (>%d past anchor) vs %s"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN, picfile))
                    ok = False
                else:
                    queue_space(s)
                    sent = True
                    got_pc = s.run_to(pc, SKIP_RUN_S)
                    if got_pc != pc:
                        print("ASSERT FAILED: skip-surface run stopped at $%04X before PC=%d" % (got_pc, pc))
                        ok = False
                    else:
                        s_ok, mism, first, detail, _ = surface_at(s, picfile)
                        if detail:
                            print("ASSERT FAILED: skip-surface check frame>=%d pc=%d vs %s: %s" % (when, pc, picfile, detail))
                            ok = False
                        elif s_ok:
                            print("skip-surface ok frame>=%d (t=%.2f, actual frame=%d) pc=%d vs %s" % (when, t, d["frame"], pc, picfile))
                        else:
                            print("ASSERT FAILED: skip-surface mismatch frame>=%d (t=%.2f, actual frame=%d) pc=%d vs %s: "
                                  "%d bytes differ, first at offset %d" % (when, t, d["frame"], pc, picfile, mism, first))
                            ok = False
                    if got_pc == chain:
                        handed_off = True
                        print("hand-off: chain_run reached under the skip press")
                        break
            press = None
            if pending_space and t >= pending_space[0]:
                pending_space.pop(0)
                press = "t"
            elif pending_space_frame and d["frame"] >= pending_space_frame[0]:
                when = pending_space_frame.pop(0)
                press = "frame"
                if frame_overshot(when, d["frame"]):
                    print("ASSERT FAILED: space anchor frame %d overshot to frame %d (>%d past anchor)"
                          % (when, d["frame"], FRAME_OVERSHOOT_MARGIN))
                    ok = False
                    press = None
            if press:
                sent = True
                held = press_space(s, chain)
                if held is None:
                    handed_off = True
                    print("hand-off: chain_run reached inside the SPACE hold at frame %d" % d["frame"])
                    break
                print("t=%.2f space (frame=%d, press_keys %d frames)" % (t, d["frame"], held))
            if t >= a.seconds:
                break
        print("sample summary: %d samples with the mirror (frames %s), %d without; %.1f s host"
              % (len(samples), "%d..%d" % (samples[0][1]["frame"], samples[-1][1]["frame"])
                 if samples else "-", no_mirror, time.time() - t0))
        if (a.asserts or a.frame_asserts or a.surface_asserts or a.skip_surface or a.text_at_frame) and not samples:
            print("ASSERT FAILED: no sample ever showed sig=IN - dbg_init never ran "
                  "(expected for a Release build, which has no mirror) or chain_run came first")
            ok = False
        if a.asserts and not samples:
            print("ASSERT FAILED: no samples were taken - cannot evaluate --assert conditions")
            ok = False
        else:
            gaps = sorted(samples[i][0] - samples[i - 1][0] for i in range(1, len(samples)))
            assert_tol = 2 * gaps[len(gaps) // 2] if gaps else 0.0
            for spec in a.asserts:
                when, cond = spec.split(":", 1)
                field, value = cond.split("=")
                when = float(when)
                t, d = min(samples, key=lambda smp: abs(smp[0] - when))
                if abs(t - when) > assert_tol:
                    print("ASSERT FAILED: nearest sample to t=%.1f is at t=%.2f (more than %.2fs "
                          "away - truncated sample list?)" % (when, t, assert_tol))
                    ok = False
                    continue
                got = d[field]
                if got != int(value, 0):
                    print("ASSERT FAILED at t=%.2f: %s=%d, expected %s" % (t, field, got, value))
                    ok = False
                else:
                    print("assert ok t=%.2f %s=%s" % (t, field, value))
        for spec in a.frame_asserts:
            when, cond = spec.split(":", 1)
            field, value = cond.split("=")
            when = int(when)
            match = next((smp for smp in samples if smp[1]["frame"] >= when), None)
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
                print("ASSERT FAILED at frame>=%d (t=%.2f, actual frame=%d): %s=%d, expected %s"
                      % (when, t, d["frame"], field, got, value))
                ok = False
            else:
                print("assert ok frame>=%d (t=%.2f, actual frame=%d) %s=%s" % (when, t, d["frame"], field, value))
        for when in pending_space:
            print("ASSERT FAILED: space at t=%.1f never fired" % when)
            ok = False
        for when in pending_space_frame:
            print("ASSERT FAILED: frame %d never reached for space press" % when)
            ok = False
        for when, picfile in pending_surface:
            print("ASSERT FAILED: frame %d never reached for surface check vs %s" % (when, picfile))
            ok = False
        if pending_skip_surface:
            print("ASSERT FAILED: frame %d never reached for skip-surface check vs %s"
                  % (pending_skip_surface[0], pending_skip_surface[2]))
            ok = False
        for when in pending_text_frame:
            print("ASSERT FAILED: frame %d never reached for text check" % when)
            ok = False
        for expect in a.expect_captions:
            if not any(expect in r for r in collected_text):
                print("ASSERT FAILED: text %r not seen" % expect)
                ok = False
        if a.expect_handoff or a.expect_text:
            if not handed_off:
                end = samples[-1][1] if samples else None
                print("ASSERT FAILED: launcher still showing (state %s, frame %s): "
                      "the hand-off never happened" % (end and end["state"], end and end["frame"]))
                ok = False
            else:
                s.clear_breakpoint(chain)
                if not s.running():
                    s.resume()
                text = wait_handoff_text(s, a.expect_text)
                if s.read(0x6000, 4) == STUB_PROLOGUE:
                    print("ASSERT FAILED: $6000 still holds the stub's own prologue - the hand-off never happened")
                    ok = False
                for r in text:
                    print("game: " + r)
                if a.expect_handoff and not text:
                    print("ASSERT FAILED: no interpreter text at $6000 - the hand-off did not reach the game")
                    ok = False
                if a.expect_text and not any(a.expect_text in r for r in text):
                    print("ASSERT FAILED: expected text %r not found at $6000" % a.expect_text)
                    ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
