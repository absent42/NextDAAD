"""Play a command script on NextDAAD under CSpect (tests/cspect) and record each turn.

It polls for a definite "ready for the next command" state instead of sleeping, and
reads the tilemap at $6000 rather than the screen. Two locks tell the interpreter's
wait states apart (map symbols MORELOCK/WRAPLOCK):

    state                  moreLock   wrapLock
    running (mid-turn)        0          0
    MORE page waiting         1          0
    input editor ready        1          1

inp_edit (src/overlay1.asm) sets and holds both; prn_more_check (src/print.asm) sets
both, prints SM32, then drops wrapLock before it waits, so (1, 1) still set a few
frames later is the editor.

Page capture: a breakpoint at WAIT_KEY_TIMEOUT holds the CPU at the pager's park point; settle()
reads the tilemap and E ($02 prn_more_check, $04 h_anykey), resumes, dismisses. Lockless waits
that never stop there (wait_key_reset's $0C, GETKEY's key_wait_char) fall to a static backstop.

jleg.js needs no capture: jDAAD keeps every character a turn prints.

Script entry forms - each is a LOGICAL instruction; each leg (this file
and jleg.js) realises it the way its own input model requires:
  "COMMAND"  a normal command line: typed, Enter, then settled.
  "!X"       raw keys with NO Enter - for prompts the line reader never
             sees (e.g. a genuine ANYKEY-style "Press any key" pause).
  "?X"       answer a confirmation prompt (e.g. QUIT's "Are you sure?")
             with X then Enter - the same keys as a plain command, spelt
             apart so a script says it answers a confirmation. The original
             ZX interpreter also reads a line here: a bare Y at the SM12
             prompt is echoed and nothing happens until ENTER.
"""
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

import symbols
import tilemap

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from cspect import Session  # noqa: E402
from cspect.client import CHUNK, Mcp  # noqa: E402

TM_MAP = 0x6000
GRID_BYTES = tilemap.GRID_BYTES
RNG_SEED = 0xA5C3
SEED_SYMBOL = "ENG_INIT_GAME@SEEDOK"      # eng_init_game's 3-byte ld (rngState),hl
FLAG_TIME = 48
FLAG_PROMPT = 42
# Fixed prompt (SM2): with flag 42 zero NextDAAD picks by frameCounter AND 3 and jDAAD by
# Math.random, so both legs force it. Must not exceed the DDB system message count.
PROMPT_SM = 2
PAGE_BP_SYMBOL = "WAIT_KEY_TIMEOUT"
MORE_E = 0x02                 # E from prn_more_check (src/print.asm)
ANYKEY_E = 0x04               # E from h_anykey (src/overlay0.asm)
# Bare SYMBOL SHIFT: kb_char maps it to 0 in every table, so the line editor ignores it,
# while wait_key takes any key (src/print.asm, src/overlay1.asm); it dismisses on release.
DISMISS_KEY = "SYM"
DISMISS_HOLD_FRAMES = 6
SETTLE_POLL_S = 0.05
SETTLE_TIMEOUT_S = 20.0
SEED_STOP_S = 30.0            # boot to the SEEDOK breakpoint
ECHO_TIMEOUT_S = 5.0
PLAY_POLL_S = 0.01
# (1, 1) inside prn_more_check lasts one SM32 print; CONFIRM_TIMEOUT_S bounds a halted CPU.
CONFIRM_FRAMES = 5
CONFIRM_TIMEOUT_S = 2.0
# Static-screen backstop in NextDAAD frames, so host speed under -freerun cannot move it.
# condacts.dsf check 65's three sounding BEEPs hold the screen ~12 frames (DRC scales each to
# 6 cs, h_beep makes that 4 frames); the boot self-test chains several, hence the boot threshold.
ANYKEY_STATIC_FRAMES = 50
BOOT_ANYKEY_STATIC_FRAMES = 250

# NLEG_DEBUG=1 (or nleg.DEBUG = True): settle() reports pages captured, keys pressed and
# where it stopped - the only places this leg acts on its own.
DEBUG = bool(os.environ.get("NLEG_DEBUG"))


def _dbg(fmt, *args):
    if DEBUG:
        print("nleg: " + (fmt % args if args else fmt), flush=True)


def stage_sd(workdir, nex_path):
    """Build the minimal SD card <workdir>/sd: the interpreter plus GAME.DDB."""
    workdir = Path(workdir).resolve()
    sd = workdir / "sd"
    sd.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(workdir / "next.ddb", sd / "GAME.DDB")
    shutil.copyfile(nex_path, sd / "nextdaad.nex")
    return sd


def seed_rng(s):
    """At the SEEDOK stop: poison RNGSTATE (the image already holds RNG_SEED), HL :=
    RNG_SEED, step the interpreter's own store, check RNGSTATE and PC, drop the stop."""
    seed_ok, rng = s.sym(SEED_SYMBOL), s.sym("RNGSTATE")
    pc = s.wait_until(s.stopped_at, SEED_STOP_S, what="the %s breakpoint" % SEED_SYMBOL)
    if pc != seed_ok:
        raise RuntimeError("boot stopped at $%04X, not at %s $%04X" % (pc, SEED_SYMBOL, seed_ok))
    s.write(rng, b"\x00\x00")
    s.set_regs(HL=RNG_SEED)
    pc = s.step()
    got = s.read(rng, 2)
    want = RNG_SEED.to_bytes(2, "little")
    if got != want or pc != seed_ok + 3:
        raise RuntimeError(
            "RNG seed did not take: HL=$%04X stepped at %s, RNGSTATE now %s (wanted %s), "
            "PC $%04X (wanted $%04X)" % (RNG_SEED, SEED_SYMBOL, got.hex(), want.hex(), pc,
                                         seed_ok + 3))
    s.clear_breakpoint(seed_ok)


def launch(sd, nex_path, map_file, port=None):
    """A Session on nex_path with sd as the card, stopped just after eng_init_game's seed
    store with RNGSTATE = RNG_SEED. port: an MCP port in launcher.PORT_RANGE, else the
    first free one."""
    s = Session.boot(sd, nex_path, map_file, brk=SEED_SYMBOL, port=port)
    try:
        seed_rng(s)
    except BaseException:
        s.close()
        raise
    return s


def key_session(s):
    """A second Session on s's CSpect for key plays. press_keys/type_text stall while the
    CPU is stopped (measured: 'Keys still being pressed' about 20 s later), so s must stay
    free to service the page stops a play causes."""
    m = Mcp(s.mcp.port)
    m.initialize()
    return Session(m, s._syms, map_file=s.map_file)


class NextLeg:
    def __init__(self, s, syms, obj_count, obj_size, keys=None):
        """s: a cspect Session; syms: symbols.load_symbols(). keys: a second Session for
        key plays (key_session); without one, plays run on s and no stop can be serviced
        until they return."""
        self.s = s
        self.syms = syms
        self.obj_count = obj_count
        self.obj_size = obj_size
        self.keys = keys
        self.pending = []           # (rows, E) of stops serviced, not yet settled
        self.dismissed = None       # screen of the last wait this settle dismissed

    def _read(self, name, n):
        return self.s.read(self.syms[name], n)

    # ---- stop-read-resume page capture (see the module docstring) --------

    def arm_page_capture(self):
        """Breakpoint at the pager's park point, then run from the seed stop."""
        self.s.set_breakpoint(self.syms[PAGE_BP_SYMBOL])
        self.s.resume()

    def _service_stop(self):
        """At a WAIT_KEY_TIMEOUT stop: queue (screen, E) and resume. True if stopped."""
        pc = self.s.stopped_at()
        if pc is None:
            return False
        if pc != self.syms[PAGE_BP_SYMBOL]:
            raise RuntimeError("CPU stopped at breakpoint $%04X, not at %s $%04X"
                               % (pc, PAGE_BP_SYMBOL, self.syms[PAGE_BP_SYMBOL]))
        rows, _attrs = tilemap.decode(self.s.grid())
        e = self.s.regs()["E"]
        if e not in (MORE_E, ANYKEY_E):
            raise RuntimeError("%s reached with E=$%02X; its callers pass $02 (prn_more_check) "
                               "and $04 (h_anykey)" % (PAGE_BP_SYMBOL, e))
        self.pending.append((rows, e))
        _dbg("stop at %s E=$%02X captured", PAGE_BP_SYMBOL, e)
        self.s.resume()
        return True

    def _play(self, name, *args, **kw):
        """keys.<name>(*args) on its own thread while page stops it causes are serviced here."""
        if self.keys is None:
            return getattr(self.s, name)(*args, **kw)
        out = {}

        def run():
            try:
                out["frames"] = getattr(self.keys, name)(*args, **kw)
            except BaseException as exc:            # re-raised on this thread below
                out["error"] = exc

        t = threading.Thread(target=run, daemon=True)
        t.start()
        while t.is_alive():
            self._service_stop()
            t.join(PLAY_POLL_S)
        if "error" in out:
            raise out["error"]
        return out["frames"]

    def dismiss(self, screen):
        """One tap of DISMISS_KEY; screen is the wait's, so the backstop cannot re-take it."""
        _dbg("dismiss (%s)", DISMISS_KEY)
        self._play("press", DISMISS_KEY, frames=DISMISS_HOLD_FRAMES)
        self.dismissed = screen

    # ---- reads -------------------------------------------------------------

    def grid_rows(self):
        rows, _attrs = tilemap.decode(self.s.grid())
        return rows

    def flags(self):
        return list(self._read("FLAGS", 256))       # flags: ds 256, one byte per flag

    def objloc(self):
        # objTable (src/engine.asm) is OBJ_SIZE-byte records; location is offset 0
        raw = self._read("OBJTABLE", self.obj_count * self.obj_size)
        return [raw[i * self.obj_size] for i in range(self.obj_count)]

    def frame(self):
        return int.from_bytes(self._read("FRAMECOUNTER", 2), "little")

    def more_state(self):
        """(moreLock, wrapLock) as booleans, from one read_memory call when they are within
        one CHUNK: MCP requests run at the frame interrupt, so one call is one moment."""
        a, b = self.syms["MORELOCK"], self.syms["WRAPLOCK"]
        lo = min(a, b)
        if abs(a - b) < CHUNK:
            span = self.s.read(lo, abs(a - b) + 1)
            return span[a - lo] != 0, span[b - lo] != 0
        return self.s.read(a, 1)[0] != 0, self.s.read(b, 1)[0] != 0

    def _wait_frames(self, n, timeout=SETTLE_TIMEOUT_S):
        f0 = self.frame()
        deadline = time.monotonic() + timeout
        while (self.frame() - f0) & 0xFFFF < n:
            if time.monotonic() >= deadline:
                raise TimeoutError("FRAMECOUNTER did not advance %d frame(s) in %g s" % (n, timeout))
            time.sleep(PLAY_POLL_S)

    def _ready_confirmed(self):
        """A second look at (1, 1): CONFIRM_FRAMES pass with no page stop and both locks
        still set. prn_more_check holds (1, 1) only while SM32 prints."""
        f0 = self.frame()
        deadline = time.monotonic() + CONFIRM_TIMEOUT_S
        while True:
            if self.s.stopped_at() is not None:
                return False                        # the pager parked: it was SM32
            if (self.frame() - f0) & 0xFFFF >= CONFIRM_FRAMES:
                break
            if time.monotonic() >= deadline:
                return False                        # frames stalled: the next poll looks again
            time.sleep(PLAY_POLL_S)
        more, wrap = self.more_state()
        return more and wrap

    # ---- input timeout ------------------------------------------------------

    def disarm_input_timeout(self):
        """Zero inpTOFrames, the countdown inp_edit and wait_key_timeout share. inp_edit
        reads zero as disarmed; wait_key_timeout decrements first, so zero runs $FFFF frames.
        Flags 48/49 are compared and stay untouched (jDAAD cannot time out)."""
        self.s.write(self.syms["INPTOFRAMES"], b"\x00\x00")

    def fatal_error(self):
        """ERRCODE: err_raise (src/errors.asm) paints the error, does di and spins forever.
        condacts.dsf's PROCESS 5..14 chain raises E03 on purpose."""
        return self._read("ERRCODE", 1)[0]

    PAGER_TIMEOUT_BIT = 0x02

    def pager_timeout_armed(self):
        """wait_key_timeout's own test for a More... page: flag 48 non-zero and flag 49 bit 1."""
        pair = self.s.read(self.syms["FLAGS"] + FLAG_TIME, 2)
        return bool(pair[0]) and bool(pair[1] & self.PAGER_TIMEOUT_BIT)

    def armed_timeout_frames(self):
        """flag48 * 50, inp_to_load's arithmetic; read before the turn's flag 48 write."""
        return self.s.read(self.syms["FLAGS"] + FLAG_TIME, 1)[0] * 50

    def wait_for_input_wait_to_end(self, pre, arm_frames=0):
        """A wait-turn (no keys): re-arm the countdown the harness zeroed EXACTLY ONCE, then
        return when the screen moves. Re-arming on every zero read cascades into the next
        read, and the locks never visibly drop between two reads (condacts.dsf check 58)."""
        deadline = time.monotonic() + SETTLE_TIMEOUT_S
        armed_once = not arm_frames
        while time.monotonic() < deadline:
            if self.grid_rows() != pre:
                return                          # the read ended: output moved
            if not armed_once and self._read("INPTOFRAMES", 2) == b"\x00\x00":
                self.s.write(self.syms["INPTOFRAMES"], arm_frames.to_bytes(2, "little"))
                armed_once = True
                _dbg("re-armed the input timeout to %d frames", arm_frames)
            time.sleep(SETTLE_POLL_S)
        raise TimeoutError(
            "a wait-turn's input timeout never fired: nothing had been "
            "printed %.0fs later, with %d frame(s) armed. Either the "
            "fixture did not arm TIME before this turn's read, or the "
            "check it belongs to prints nothing when it expires"
            % (SETTLE_TIMEOUT_S, arm_frames))

    # ---- one turn ------------------------------------------------------------

    def _wait_echo(self, cmd):
        """The editor's line holds cmd, then one frame for the redraw (inp_insert stores the
        char before it redraws). A key the editor did not take raises."""
        want = cmd.encode("ascii") + b"\x00"
        deadline = time.monotonic() + ECHO_TIMEOUT_S
        while True:
            line = self._read("INPLINE", len(want))
            if line == want:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("typed %r but the input line holds %r"
                                   % (cmd, line.split(b"\x00")[0].decode("ascii", "replace")))
            time.sleep(PLAY_POLL_S)
        self._wait_frames(1)

    def send(self, cmd):
        """Send one non-empty script entry; returns `pre`, the screen its new text is measured
        against: after the echo for a command (jleg.js suppresses jDAAD's), before the keys for
        "!" (no echo) and "?" (its one echoed character is known text divergence)."""
        if cmd.startswith("!"):
            pre = self.grid_rows()
            self._play("type_text", cmd[1:])
        elif cmd.startswith("?"):
            pre = self.grid_rows()
            self._play("type_text", cmd[1:] + "\n")
        else:
            self._play("type_text", cmd)
            self._wait_echo(cmd)
            pre = self.grid_rows()
            self._play("enter")
        return pre

    def settle(self, pages, boot=False, allow_timeout=False):
        """Run on to the confirmed input editor, appending and dismissing every page waited on;
        True if the static-screen backstop found a wait. allow_timeout: leave inpTOFrames alone
        (a TIME-expiry turn); boot: raises the backstop threshold only. Times out loudly."""
        deadline = time.monotonic() + SETTLE_TIMEOUT_S
        heuristic = False
        self.dismissed = None
        last_grid, static_from, static = None, 0, 0
        more = wrap = None
        threshold = BOOT_ANYKEY_STATIC_FRAMES if boot else ANYKEY_STATIC_FRAMES
        while time.monotonic() < deadline:
            # every wait shares inpTOFrames and may arm it from flag 48 at any time
            if not allow_timeout:
                self.disarm_input_timeout()
            err = self.fatal_error()
            if err:
                pages.extend(rows for rows, _e in self.pending)
                self.pending.clear()
                _dbg("interpreter raised runtime error %d - halted", err)
                return heuristic
            self._service_stop()
            if self.pending:
                rows, e = self.pending.pop(0)
                pages.append(rows)
                if e == MORE_E and allow_timeout and self.pager_timeout_armed():
                    _dbg("leaving the page to its own timeout")
                else:
                    self.dismiss(rows)
                last_grid = None
                continue
            more, wrap = self.more_state()
            if more and wrap:
                if not self._ready_confirmed():
                    continue
                if not allow_timeout:
                    self.disarm_input_timeout()     # the editor armed it after this poll's disarm
                _dbg("settle READY after %d page(s)%s", len(pages), " [boot]" if boot else "")
                return heuristic
            if more:
                # past SM32 and short of the stop, or a page left to its own timeout
                time.sleep(SETTLE_POLL_S)
                continue
            cur, now = self.grid_rows(), self.frame()
            if cur != last_grid or cur == self.dismissed:
                last_grid, static_from, static = cur, now, 0
            else:
                static = (now - static_from) & 0xFFFF
                if static >= threshold:
                    pages.append(cur)
                    _dbg("static-screen backstop dismissed a lockless wait")
                    self.dismiss(cur)
                    heuristic = True
                    last_grid = None
                    continue
            time.sleep(SETTLE_POLL_S)
        rows = self.grid_rows()
        tail = [r.rstrip() for r in rows if r.strip()][-3:]
        raise TimeoutError(
            "interpreter did not settle within %.0fs - last observed moreLock=%s wrapLock=%s, "
            "screen %s, %d page(s) this turn. Last text on screen: %r"
            % (SETTLE_TIMEOUT_S, more, wrap,
               "unchanged since a wait was dismissed (the key did not end it?)"
               if rows == self.dismissed else "static for %d frame(s)" % static,
               len(pages), tail))


def load_more_prompt(workdir):
    """This game's SM32 (the "More..." pager prompt), or None if the game
    genuinely has no SM32.

    PRECONDITION - THE TWO LEGS ARE ORDERED: jleg.js MUST have already
    run against this same workdir. It is the only thing that reads SM32,
    because reading it means loading the DDB through jDAAD's own
    getMessage inside jleg's vm sandbox; nothing on the Next side, and
    nothing in prepare.py, has that machinery. prepare.py was considered
    as the earlier home for this read and rejected: it would have to
    spawn node and stand up a second jDAAD sandbox purely to fetch one
    string, duplicating jleg's DDB load - a much larger change than
    stating the order and failing clearly when it is not kept, which is
    what the missing-file branch below does. Any new driver that calls
    nleg.play() directly must run the jDAAD leg first; parsertest.py and
    scripts/v3probe/run.py both do.

    jleg.js writes <workdir>/meta.json straight out of the DDB - see the
    comment there for why the prompt row must be dropped, and why the text
    comes from the game rather than a hardcoded literal.

    Every failure to read it RAISES. There is deliberately no quiet
    fallback: running without the filter is not a degraded mode, it is the
    old flaky behaviour where the prompt is captured or not depending on
    whether a held keystroke dismissed the page first, and a None returned
    for "something went wrong" is indistinguishable downstream from a None
    returned for "this game has no pager prompt". Only the second is a
    real state, and only jleg.js can establish it - which it does
    explicitly, with the reason recorded in sm32_status.
    """
    meta = Path(workdir) / "meta.json"
    if not meta.exists():
        raise RuntimeError(
            "%s is missing. THE LEGS ARE ORDERED: tests/parser/jleg.js "
            "must run against this workdir BEFORE nleg.play() is called - "
            "it is the only leg that can read SM32 out of the DDB, and it "
            "writes meta.json as it goes. If you are driving nleg.play() "
            "yourself, run the jDAAD leg first (parsertest.py does: jleg, "
            "then nleg). Without the prompt the pager row cannot be "
            "filtered and the run would be nondeterministic; this is a "
            "harness failure, not a game divergence." % meta)
    try:
        data = json.loads(meta.read_text(encoding="utf-8"))
    except (ValueError, OSError) as exc:
        raise RuntimeError(
            "%s could not be read as JSON (%s) - the jDAAD leg wrote "
            "something unusable and the run cannot be trusted." % (meta, exc))
    if not isinstance(data, dict) or "sm32" not in data:
        raise RuntimeError(
            "%s has no 'sm32' key (got %r) - the jDAAD leg's meta.json "
            "format changed and the two legs no longer agree." % (meta, data))

    sm32, status = data["sm32"], data.get("sm32_status", "no status recorded")
    if sm32 is None:
        print("nleg: no pager prompt to filter (%s)" % status)
        return None
    if not isinstance(sm32, str):
        raise RuntimeError(
            "%s records sm32 as %r, which is neither a string nor null"
            % (meta, sm32))
    sm32 = sm32.strip()
    if not sm32:
        print("nleg: pager prompt is empty, nothing to filter (%s)" % status)
        return None
    return sm32


def blank_prompt_rows(rows, prompt):
    """Return `rows` with any row that is exactly `prompt` blanked out.

    Applied to a captured MORE page's GRID, before tilemap.transition and
    tilemap.new_text ever see it, rather than filtering the prompt out of
    new_text's result afterwards. Filtering afterwards left the ambiguity
    check running on the raw grid, so whether the prompt happened to be on
    screen could still flip text_ambiguous - and that reaches
    findings.json as a caveat, which is exactly the kind of run-to-run
    wobble the prompt filter exists to remove. Blanking the grid instead
    makes both the emitted rows AND the ambiguity verdict independent of
    the prompt.

    Blanked rather than deleted, because scroll_delta compares rows by
    INDEX - dropping a row would shift every row below it and turn a
    clean scroll into an unexplainable transition. A blank row at the
    prompt's position is also exactly what the screen holds a moment
    later: prn_more_check erases that line itself once the page is
    dismissed.
    """
    if not prompt:
        return rows
    return [(" " * len(r) if r.strip() == prompt else r) for r in rows]


def load_script(script_path):
    """Read a command script and return one normalised dict per turn.

    A script is a JSON list whose entries are EITHER a plain string (the
    original form, and still the right one for almost every turn - see
    the module docstring for "COMMAND"/"!X"/"?X") OR an object:

        {"cmd": "GET LAMP"}                 same as the plain string
        {"cmd": "", "allow_timeout": true}  type nothing, let the
                                            interpreter's own input
                                            timeout expire

    An empty (or null) `cmd` is a turn that sends NO keys at all. It only
    makes sense together with allow_timeout: something other than a
    keystroke has to end the wait, and the interpreter's TIME countdown
    is the only other thing that can.

    `allow_timeout` is opt-in per turn and BOTH legs honour it - jleg.js
    reads the same field. It exists for fixture checks that are ABOUT the
    timeout (tests/condacts.dsf check 58 arms `TIME 2 0` and asserts flag
    49 = 128); everywhere else the harness must keep stopping the clock,
    because jDAAD cannot time out at all and a one-sided expiry is a
    harness-manufactured divergence.
    """
    raw = json.loads(Path(script_path).read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("%s is not a JSON list of turns" % script_path)
    out = []
    for i, entry in enumerate(raw):
        if isinstance(entry, str):
            out.append({"cmd": entry, "allow_timeout": False})
            continue
        if not isinstance(entry, dict):
            raise ValueError(
                "%s turn %d is %r - a script entry must be a string or an "
                "object" % (script_path, i, entry))
        unknown = set(entry) - {"cmd", "allow_timeout"}
        if unknown:
            raise ValueError(
                "%s turn %d carries unknown key(s) %s. A misspelled "
                "directive that is silently ignored is worse than a broken "
                "script: the turn runs with the DEFAULT behaviour and the "
                "run looks valid" % (script_path, i, sorted(unknown)))
        cmd = entry.get("cmd") or ""
        if not isinstance(cmd, str):
            raise ValueError("%s turn %d: cmd must be a string or null"
                             % (script_path, i))
        allow = bool(entry.get("allow_timeout"))
        if cmd == "" and not allow:
            raise ValueError(
                "%s turn %d sends no keys and does not allow a timeout - "
                "nothing would ever end the wait" % (script_path, i))
        out.append({"cmd": cmd, "allow_timeout": allow})
    return out


def script_commands(entries):
    """The command strings of a loaded script, for callers that only want
    the text (report.build_findings' verb narrowing, for one)."""
    return [e["cmd"] for e in entries]


def play(workdir, script_path, out_path, nex_path, port=None):
    workdir = Path(workdir)
    script = load_script(script_path)
    more_prompt = load_more_prompt(workdir)
    map_file = ROOT / "build" / "nextdaad.map"
    syms = symbols.load_symbols(map_file)
    obj_size = symbols.load_obj_size(ROOT / "src" / "nextdaad.inc")
    obj_count = (workdir / "next.ddb").read_bytes()[3]

    sd = stage_sd(workdir, nex_path)
    s = launch(sd, sd / "nextdaad.nex", map_file, port=port)
    print("nleg: CSpect PID %d on MCP port %d" % (s.pid, s.inst.port), flush=True)
    try:
        leg = NextLeg(s, syms, obj_count, obj_size, keys=key_session(s))
        leg.arm_page_capture()
        # The boot output belongs to no turn (jleg.js settles after handlers.ready() the
        # same way); flag 42 writes stick only after eng_init_game's flag clear.
        leg.settle([], boot=True)

        with open(out_path, "w", encoding="utf-8") as fh:
            for i, entry in enumerate(script):
                cmd = entry["cmd"]
                allow_timeout = entry["allow_timeout"]
                # read before the flag 48 write erases it: a wait-turn re-arms this duration
                arm_frames = leg.armed_timeout_frames() if allow_timeout else 0
                # Flag 48 = 0 at the same point jleg.js writes it. inp_edit already loaded
                # inpTOFrames from flag 48 at entry, so only clearing that stops its clock.
                s.write(syms["FLAGS"] + FLAG_TIME, b"\x00")
                if not allow_timeout:
                    leg.disarm_input_timeout()
                s.write(syms["FLAGS"] + FLAG_PROMPT, bytes([PROMPT_SM]))

                pages = []
                if cmd == "":
                    # a wait-turn (allow_timeout only): the interpreter's countdown ends it
                    pre = leg.grid_rows()
                    leg.wait_for_input_wait_to_end(pre, arm_frames=arm_frames)
                else:
                    pre = leg.send(cmd)
                anykey_heuristic = leg.settle(pages, allow_timeout=allow_timeout)

                post = leg.grid_rows()
                text_rows = []
                ambiguous = False
                prev = pre
                # Blank the pager prompt in captured pages only (see blank_prompt_rows):
                # prn_more_check erases it before the turn goes on, and a game's prose
                # that matches SM32 on the final screen must still compare.
                if more_prompt is not None:
                    pages = [blank_prompt_rows(p, more_prompt) for p in pages]
                for page in pages + [post]:
                    # a scroll plus an in-place redraw has no single shift: flag it
                    if tilemap.transition(prev, page)["ambiguous"]:
                        ambiguous = True
                    text_rows.extend(tilemap.new_text(prev, page))
                    prev = page

                timed = leg.flags()[FLAG_TIME] != 0
                err = leg.fatal_error()
                fh.write(json.dumps({
                    "turn": i,
                    "command": cmd,
                    "text": "\n".join(text_rows),
                    "flags": leg.flags(),
                    "objloc": leg.objloc(),
                    "frame": leg.frame(),
                    "timing_sensitive": timed,
                    "text_ambiguous": ambiguous,
                    "anykey_heuristic": anykey_heuristic,
                    "fatal_error": err,
                }) + "\n")
                if err:
                    # err_raise halts with interrupts off: this turn is written, nothing more
                    # can run (for condacts.dsf the error IS the check)
                    remaining = len(script) - (i + 1)
                    if remaining:
                        raise RuntimeError(
                            "NextDAAD raised runtime error %d on turn %d "
                            "(%r) and halted, but the script has %d more "
                            "turn(s). A raised error must be the LAST "
                            "thing a script drives - the machine is dead "
                            "from here on." % (err, i, cmd, remaining))
                    print("nleg: NextDAAD raised runtime error %d on the "
                          "last turn and halted" % err)
                    break
    finally:
        s.close()
