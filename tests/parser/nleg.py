"""Play a command script on NextDAAD under ZEsarUX and record what
happened.

Two things this does that the Dracula zxplay.py did not:

  1. It POLLS for a definite "ready for the next command" state instead
     of sleeping. Sleeping is what made scripts containing SLEEP desync
     there - the ANYKEY pages swallowed subsequent keystrokes.
  2. It READS the tilemap rather than photographing the screen. ZEsarUX's
     get-ocr is ULA-based and cannot see the Next tilemap at all.

Two locks distinguish the interpreter's wait states (see src/nextdaad.map
symbols MORELOCK/WRAPLOCK):

    state                  moreLock   wrapLock
    running (mid-turn)        0          0
    MORE page waiting         1          0
    input editor ready        1          1

inp_edit (overlay1.asm:626-628) sets and holds both together; only ENTER or
timeout clears them together. prn_more_check (print.asm:250-258) sets both
but clears wrapLock before waiting on the dismiss key, so moreLock==1 AND
wrapLock==1 together means "input editor ready" - not merely "moreLock is
set", which both states share.

ANYKEY-style prompts (overlay0.asm h_anykey) set neither lock, so they are
inferred: if the tilemap is unchanged for ANYKEY_STATIC_POLLS consecutive
polls while not READY, treat it as a blocked ANYKEY wait and send a key.
Turns handled this way are marked anykey_heuristic=True in the jsonl output.

Page capture is breakpoint-driven, not polled (see PAGE_BP_INDEX and
arm_page_capture): the pager's park point, WAIT_KEY_TIMEOUT, is captured
by the emulator itself before anything can dismiss it, so the poll
interval never decides what the transcript contains.

jleg.js needs no equivalent capture: jDAAD is a synchronous interpreter
and every character it prints accumulates in a string for the whole turn,
so nothing can scroll away between observations.

Script entry forms - each is a LOGICAL instruction; each leg (this file
and jleg.js) realises it the way its own input model requires:
  "COMMAND"  a normal command line: typed, Enter, then settled.
  "!X"       raw keys with NO Enter - for prompts the line reader never
             sees (e.g. a genuine ANYKEY-style "Press any key" pause).
  "?X"       answer a confirmation prompt (e.g. QUIT's "Are you sure?")
             with X. Sends X and then Enter - i.e. exactly what a plain
             command does - and is kept as a separate spelling only so a
             script says out loud that the turn is answering a
             confirmation rather than issuing an order. Both legs read a
             full line here: confirmed against the original ZX
             interpreter under ZEsarUX, where a bare Y at the SM12
             prompt is echoed into a line and nothing happens until
             ENTER.
"""
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import symbols
import tilemap
import zrcp

ROOT = Path(__file__).resolve().parent.parent.parent
ZESARUX = ROOT / "tools" / "DAAD-READY" / "TOOLS" / "zesarux" / "zesarux.exe"

TM_MAP = 0x6000
GRID_BYTES = tilemap.GRID_BYTES
RNG_SEED = 0xA5C3
FLAG_TIME = 48
FLAG_PROMPT = 42
# Fixed prompt (SM2). NextDAAD picks the prompt with frameCounter AND 3 when
# flag 42 is zero (src/overlay1.asm) - wall-clock dependent, so not even
# stable across two runs of the same script. jDAAD uses Math.random for the
# same choice, so no shared PRNG could reconcile them. Both legs force the
# fixed-prompt path instead. Must not exceed the DDB system message count.
PROMPT_SM = 2
SETTLE_POLL_S = 0.1
SETTLE_TIMEOUT_S = 20.0
# How many consecutive unchanged-screen polls, while still not READY,
# before an ANYKEY-style wait (invisible to moreLock/wrapLock - see module
# docstring) is inferred. At SETTLE_POLL_S=0.1 this is ~0.4s total. Normal
# mid-turn execution between two observably different screens takes on
# the order of microseconds of real Z80 time against this poll interval,
# so a genuinely still-running turn will not trip this; only a real
# hold-with-no-lock-set will.
ANYKEY_STATIC_POLLS = 4

# Boot-settle's OWN static-poll threshold (see settle()'s `boot=` doc).
# Confirmed live this must be well ABOVE ANYKEY_STATIC_POLLS: tests/
# condacts.dsf's automated suite makes several real, timed BEEP/PAUSE/SFX
# calls before ever reaching a genuine keypress wait (e.g. check 65's
# three BEEPs back to back), and a brief real gap between two "More..."
# dismissals with no visible change can look "static" for the SAME ~0.4s
# window as a genuine ANYKEY-style prompt - confirmed live: an isolated
# run reliably stopped boot-settle at "Are you sure?" every time, but
# inside the full test suite's timing it sometimes stopped many checks
# earlier instead, at one of those transient gaps (a false positive, not
# a race in the emulator itself). 3 seconds (30 polls) was chosen with a
# wide safety margin over the ~0.1-0.3s condact delays actually present
# in this fixture, while staying well under SETTLE_TIMEOUT_S.
#
# It applies to a screen NO pager fire has accounted for. Once the
# emulator's page-capture breakpoint has announced a wait and the screen
# has not moved since, the wait is known to be real and settle() uses the
# ordinary ANYKEY_STATIC_POLLS instead - a false positive is impossible
# there, and Rabenstein's intro would otherwise cost 3 seconds per pause.
BOOT_ANYKEY_STATIC_POLLS = 30

# ZRCP breakpoint index used to trap eng_init_game's RNG seed write (see
# _seed_rng_via_breakpoint). ZEsarUX indexes breakpoints from 1, not 0
# (confirmed live: index 0 replies "Error. Index out of range").
# Under 12.1 index 1 arrived pre-populated with a ZEsarUX/tbblue-profile
# default ("PC=EAB5H", enabled); under 13.0 every index starts empty
# ("Disabled 1: None"). Either way set_breakpoint() overwrites whatever is
# there, which is exactly what set-breakpoint is for - but it must run
# AFTER enable_breakpoints under 13.0, see _seed_rng_via_breakpoint.
SEED_BP_INDEX = 1
# Generous ceiling for run() to reach the RNG-seed breakpoint: real
# wall-clock work (smartload plus boot to eng_init_game), not instant.
# Only reachable at all if `workdir` resolves to an absolute path (see
# stage_sd) - a relative one makes ZEsarUX double the smartload path and
# silently load nothing, so the breakpoint never fires regardless of
# this deadline.
SEED_RUN_DEADLINE_S = 60.0

# Breakpoint-driven page capture (see the module docstring). Two indices
# share ONE condition, PC=WAIT_KEY_TIMEOUT; the lower one writes the dump
# so the file is on disk before the counter that announces it moves.
PAGE_BP_INDEX = 2
PAGE_COUNT_BP_INDEX = 3
# ZEsarUX user variable the counting breakpoint increments. var0..var9
# exist for exactly this; nothing else in this harness uses any of them.
PAGE_COUNT_VAR = "var0"
# Written by the emulator itself, inside the work directory, once per
# page. Not a temp file: when a run is being diagnosed it is the last
# page verbatim, and it is in the same place as every other artefact.
PAGE_DUMP_NAME = "nleg-page.bin"
# The interpreter's pager park point. Both call sites of this routine are
# genuine "the screen is finished and we are about to block" states -
# prn_more_check (E=$02) and h_anykey (E=$04).
PAGE_BP_SYMBOL = "WAIT_KEY_TIMEOUT"

# Set NLEG_DEBUG=1 (or nleg.DEBUG = True) to have settle() report every
# decision it takes: pages captured, keys pressed, and where a settle
# stopped. Those are the only places this leg does anything the script
# did not ask for, so they are the first thing to look at when a replay
# stops reproducing. Same switch as the ZX leg's ZLEG_DEBUG.
DEBUG = bool(os.environ.get("NLEG_DEBUG"))


def _dbg(fmt, *args):
    if DEBUG:
        print("nleg: " + (fmt % args if args else fmt), flush=True)


def stage_sd(workdir, nex_path):
    """Build the minimal SD card: the interpreter plus GAME.DDB.

    `workdir` is resolved to an ABSOLUTE path here, once, at the source -
    see SEED_RUN_DEADLINE_S's root-cause note above. `sd` (derived from
    it) is passed to launch() as both the subprocess's `cwd` AND the value
    of `--esxdos-root-dir`/`--smartloadpath`, and later reused to build
    the ZRCP `smartload <path>` command's argument - if any of those stay
    relative, ZEsarUX resolves the argument against a cwd that is already
    that same directory, doubling the path and silently failing to load
    anything (confirmed live via get-registers: PC never left NextZXOS's
    boot ROM). A caller passing a relative `--out` on the command line is
    the ordinary case that triggered this, not an edge case worth a
    docstring caveat instead of a fix.
    """
    workdir = Path(workdir).resolve()
    sd = workdir / "sd"
    sd.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(workdir / "next.ddb", sd / "GAME.DDB")
    shutil.copyfile(nex_path, sd / "nextdaad.nex")
    return sd


def launch(sd, port):
    """Boot ZEsarUX with the SD card mounted, but do NOT pass the .nex on
    the command line - that would auto-load and start running it before
    we ever get a chance to connect. Task 11's RNG-seed fix (see
    _seed_rng_via_breakpoint) needs the machine to sit idle after boot
    until we explicitly smartload the game ourselves, with a breakpoint
    already armed. --smartloadpath still sets the esxdos search root so
    the later ZRCP `smartload` command can find the file.
    """
    return subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(port),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))


def port_already_listening(port):
    """Cheap pre-launch probe: True if something is ALREADY accepting
    connections on `port` before we start our own ZEsarUX. A stale
    emulator left over from an interrupted prior run holds the port open
    silently; without this check, our new instance fails to bind, and
    wait_for_port's retry loop below happily connects to the OLD process
    instead - the harness then plays the CURRENT script against a
    reference leg paired with a DIFFERENT, previous game. Every finding
    from a run like that is garbage with nothing to indicate it. Caught
    here, before launch(), so the failure is loud and names the cause
    rather than surfacing as a wall of confusing divergences later.
    """
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
    except OSError:
        return False
    s.close()
    return True


def wait_for_port(proc, port, attempts=60, delay=0.5):
    """Poll for ZRCP readiness with a bounded number of attempts, rather
    than sleeping blind for a fixed boot delay. Returns a connected Zrcp,
    or raises if the wait cannot succeed.

    Also checks `proc.poll()` on every attempt: if the ZEsarUX process we
    ourselves launched has already exited, retrying the connect is
    pointless - it would either time out uninformatively, or (worse) an
    unrelated process could still be squatting on the port and the retry
    would silently attach to THAT instead. See port_already_listening()
    for the complementary pre-launch check.
    """
    last_err = None
    for _ in range(attempts):
        if proc.poll() is not None:
            raise RuntimeError(
                "the ZEsarUX process we launched exited early (returncode "
                "%r) before ZRCP ever accepted a connection on port %d - "
                "check ZEsarUX's own output for a startup error"
                % (proc.returncode, port))
        try:
            return zrcp.Zrcp(port)
        except OSError as e:
            last_err = e
            time.sleep(delay)
    raise TimeoutError("ZRCP never accepted a connection on port %d after "
                       "%d attempts (%.1fs total): %r"
                       % (port, attempts, attempts * delay, last_err))


def _seed_rng_via_breakpoint(z, syms, nex_path):
    """Force NextDAAD's RNG seed to RNG_SEED, matching the jDAAD mirror.

    eng_init_game seeds rngState from R/frameCounter entropy so fast that
    a post-boot write always loses the race, even on the first read after
    connecting. A breakpoint at ENG_INIT_GAME@SEEDOK, HL overridden to
    RNG_SEED, then a single cpu-step so the interpreter's own
    `ld (rngState),hl` performs the write, is the only way to land it
    before that entropy takes hold - a plain write-memory at that point
    does not reliably stick.
    """
    seed_ok = syms["ENG_INIT_GAME@SEEDOK"]
    rngstate = syms["RNGSTATE"]

    z.enter_cpu_step()
    # enable BEFORE set - ZEsarUX 13.0 rejects set-breakpoint outright
    # while breakpoints are disabled ("Error. You must enable breakpoints
    # first"). See Zrcp.enable_breakpoints for the confirmed evidence and
    # what changed from 12.1.
    z.enable_breakpoints()
    z.set_breakpoint(SEED_BP_INDEX, zrcp.pc_breakpoint_condition(seed_ok))
    z.cmd("smartload %s" % str(nex_path), deadline=30.0)
    reply = z.run(deadline=SEED_RUN_DEADLINE_S)
    if "Breakpoint fired" not in reply:
        raise RuntimeError(
            "RNG seed breakpoint (PC=%d) never fired - run() returned %r"
            % (seed_ok, reply))

    z.cmd("set-register HL=%d" % RNG_SEED)
    z.cpu_step()

    got = z.read_memory(rngstate, 2)
    want = bytes([RNG_SEED & 0xFF, (RNG_SEED >> 8) & 0xFF])
    if got != want:
        raise RuntimeError(
            "RNG seed did not take: forced HL=%d before stepping the seed "
            "write, but rngState now reads %r (expected %r)"
            % (RNG_SEED, got, want))

    z.disable_breakpoints()
    z.exit_cpu_step()


class NextLeg:
    def __init__(self, z, syms, obj_count, obj_size, page_dump=None):
        self.z = z
        self.syms = syms
        self.obj_count = obj_count
        self.obj_size = obj_size
        # Where the emulator writes each captured page, and how many
        # pages it has written so far. Both belong to the SESSION, not to
        # a turn: the counter is cumulative, so a page that fires late in
        # turn N and is only observed on turn N+1's first poll is still
        # counted exactly once.
        self.page_dump = Path(page_dump) if page_dump is not None else None
        self.seen_fires = 0

    # ---- breakpoint-driven page capture (see the module docstring) --------

    def arm_page_capture(self):
        """Arm the two pager breakpoints and take the counter baseline.

        Called ONCE, straight after _seed_rng_via_breakpoint, with the
        machine put briefly back into cpu-step: arming takes a few ZRCP
        round trips, and the condacts fixture reaches its first MORE page
        within a few hundred milliseconds of boot, so arming while the
        interpreter free-runs would race the very first page.

        The RNG-seed trap is retired by INDEX. enable_breakpoints() is a
        global switch and _seed_rng_via_breakpoint leaves that switch off
        with its own index still holding PC=SEEDOK; turning the switch
        back on for the pager would re-arm it, and eng_init_game runs
        again on a restart (EXIT n).
        """
        if self.page_dump is None:
            raise RuntimeError(
                "arm_page_capture needs a page_dump path - without it there "
                "is nowhere for the emulator to write the captured page and "
                "the whole point of the breakpoint is lost")
        dump = self.page_dump.resolve()
        if any(ch.isspace() for ch in str(dump)):
            raise RuntimeError(
                "the page dump path %r contains whitespace. ZRCP splits "
                "save-binary's arguments on spaces, so the emulator would "
                "write to a truncated path (or refuse) and every page would "
                "be captured as whatever stale bytes were there before. "
                "Use a work directory with no spaces in its path." % str(dump))
        if dump.exists():
            # A dump left by an earlier run must never be mistaken for
            # this run's first page.
            dump.unlink()

        self.z.enter_cpu_step()
        try:
            self.z.enable_breakpoints()
            self.z.disable_breakpoint(SEED_BP_INDEX)
            cond = zrcp.pc_breakpoint_condition(self.syms[PAGE_BP_SYMBOL])
            self.z.set_breakpoint(PAGE_BP_INDEX, cond)
            self.z.set_breakpoint_action(
                PAGE_BP_INDEX,
                "save-binary %s %d %d" % (dump, TM_MAP, GRID_BYTES))
            self.z.set_breakpoint(PAGE_COUNT_BP_INDEX, cond)
            self.z.set_breakpoint_action(
                PAGE_COUNT_BP_INDEX,
                "let %s=%s+1" % (PAGE_COUNT_VAR, PAGE_COUNT_VAR))
            # Baseline rather than reset: ZRCP has no "set variable"
            # command outside a breakpoint action, and a baseline is
            # equivalent - only the DELTA is ever used.
            self.seen_fires = self.page_fires()
        finally:
            self.z.exit_cpu_step()

    def page_fires(self):
        """Cumulative number of times the pager park point has been
        reached, as counted by the emulator itself.

        A non-numeric reply means the counting breakpoint is not doing
        what this module thinks it is, and settle() would then sit out its
        whole timeout on every page instead of capturing it - so this
        raises rather than defaulting to zero.
        """
        reply = self.z.evaluate(PAGE_COUNT_VAR).strip()
        try:
            return int(reply, 0)
        except ValueError:
            raise RuntimeError(
                "`evaluate %s` answered %r, not a number - the page-capture "
                "breakpoint (%s) is not counting, so MORE pages would be "
                "waited out instead of captured"
                % (PAGE_COUNT_VAR, reply, PAGE_BP_SYMBOL))

    def captured_page(self, fires):
        """Decode the page the emulator dumped at the park point.

        `fires` is the counter value that announced this page. It is
        re-read AFTER the dump and must not have moved: reading the
        counter and reading the file are two separate round trips, and a
        page firing between them overwrites the dump with a LATER page
        while the caller still believes it holds the one the counter
        named. The delta>1 guard in settle() cannot see that - the
        counter was already sampled - so this is the only place that
        window can be closed. Raising loses nothing: it is the same
        "a page's text went missing" condition, named at the point it
        happens instead of appearing as an unexplained gap in the
        transcript.
        """
        try:
            data = self.page_dump.read_bytes()
        except OSError as exc:
            raise RuntimeError(
                "the page counter moved but %s could not be read (%s) - the "
                "save-binary breakpoint action did not produce a dump"
                % (self.page_dump, exc))
        if len(data) != GRID_BYTES:
            raise RuntimeError(
                "%s holds %d bytes, expected %d - a partial or stale page "
                "dump would be decoded as screen content"
                % (self.page_dump, len(data), GRID_BYTES))
        now = self.page_fires()
        if now != fires:
            raise RuntimeError(
                "a pager wait fired while page %d's dump was being read "
                "(counter %d -> %d), so the dump on disk is a LATER page and "
                "page %d's text is gone. Same loss the >1-per-poll guard "
                "exists for, in the window between sampling the counter and "
                "reading the file" % (fires, fires, now, fires))
        rows, _attrs = tilemap.decode(data)
        return rows

    def grid_rows(self):
        raw = self.z.read_memory(TM_MAP, GRID_BYTES)
        rows, _attrs = tilemap.decode(raw)
        return rows

    def flags(self):
        # flags (src/engine.asm: "flags: ds 256") is a genuinely FLAT
        # array - confirmed by reading every "ld (flags+FLAG_x),a" site
        # across src/*.asm: each flag is addressed as a single byte at
        # flags+N with no per-flag stride or interleaving, unlike
        # objTable below. A flat 256-byte read is correct as-is.
        return list(self.z.read_memory(self.syms["FLAGS"], 256))

    def objloc(self):
        # objTable (src/engine.asm: "objTable: ds 256*OBJ_SIZE") is a
        # STRUCT ARRAY, not a flat array of locations - each OBJ_SIZE-byte
        # record (populated by eng_load_objects in src/engine.asm) holds:
        #   +0  location            +3  extended attribute high
        #   +1  attributes           +4  noun id
        #   +2  extended attribute low +5  adjective id
        # Read every record, then take offset 0 (location) of each - do
        # NOT read obj_count consecutive bytes from OBJTABLE, that reads
        # record 0's six fields as "objects" 0-5, record 1's as 6-11, etc.
        raw = self.z.read_memory(self.syms["OBJTABLE"],
                                  self.obj_count * self.obj_size)
        return [raw[i * self.obj_size] for i in range(self.obj_count)]

    def frame(self):
        # ZRCP has no get-cpu-frames (confirmed against src/zrcp/remote.c -
        # only get-tstates and get-tstates-partial exist). NextDAAD's own
        # FRAMECOUNTER is better for our purpose anyway: it is the tick the
        # interpreter actually runs on, read through the same path as the
        # flags. It is also what the prompt picker uses when flag 42 is 0,
        # which is exactly the nondeterminism we force away.
        return int.from_bytes(self.z.read_memory(self.syms["FRAMECOUNTER"], 2),
                              "little")

    def more_state(self):
        """Read (moreLock, wrapLock) as booleans. Together they
        discriminate the three states settle() cares about - see the
        module docstring for the full evidence:
            (False, False) -> running (mid-turn execution)
            (True,  False) -> parked on a genuine MORE page
            (True,  True)  -> input editor ready for the next command
        These are two independent byte reads (moreLock and wrapLock are
        not adjacent), so there is a theoretical tearing window between
        them; at real Z80 transition speed against ZRCP's ~0.6ms call
        cost this is not a practical concern.
        """
        more = self.z.read_memory(self.syms["MORELOCK"], 1)[0] != 0
        wrap = self.z.read_memory(self.syms["WRAPLOCK"], 1)[0] != 0
        return more, wrap

    def _ready_confirmed(self, fires):
        """Second opinion on a (moreLock, wrapLock) == (1, 1) reading.

        That pair also holds briefly inside prn_more_check on its way to
        parking a MORE page (src/print.asm:250-257), before it releases
        wrapLock - so a single observation cannot tell that transient
        state from the input editor genuinely being ready. Re-reading
        after a full poll interval separates them: the pager leaves
        within microseconds (wrapLock drops, or the page counter moves),
        the editor sits until a key arrives; only "still both locks,
        counter unmoved" confirms the editor. Costs one extra
        SETTLE_POLL_S at every turn end, never an extra loop iteration
        when the editor really is ready (pinned by
        t9_both_locks_are_confirmed_before_a_turn_is_called_ready, which
        asserts polls == 1 on a genuine editor).
        """
        time.sleep(SETTLE_POLL_S)
        if self.page_fires() != fires:
            return False                        # a page parked: it was SM32
        more, wrap = self.more_state()
        return more and wrap

    def disarm_input_timeout(self):
        """Zero inpTOFrames, the countdown EVERY DAAD wait in NextDAAD is
        driven by, so no wait this harness parks on can ever time out.

        Three different waits load and count down this one variable, and
        all three had to be covered:

          inp_edit (src/overlay1.asm) - the command line. Reads flag 48
            ONCE at entry, converts it to a frame count, then re-reads
            inpTOFrames every poll and treats ZERO as disarmed.
          wait_key_timeout (src/print.asm) - reached from prn_more_check
            with E=$02 (a "More..." page) and from h_anykey with E=$04.
            INDEPENDENTLY recomputes flag48*50 into the same variable and
            counts it down, setting flag 49 bit 7 on expiry.

        Writing flag 48 = 0 at the top of a turn does not cover either
        case, because the game is free to re-arm flag 48 with TIME
        part-way through a turn, and the pager/ANYKEY path then reads it
        fresh at the moment the page fires. That is why this is called on
        EVERY settle() poll rather than only when the editor goes ready:
        whatever the interpreter is parked on, the clock is stopped again
        within one poll interval of it starting.

        Two different disarm mechanics, both confirmed against the source:
        inp_edit tests for zero BEFORE decrementing, so zero disarms it
        outright. wait_key_timeout decrements BEFORE testing, so zero
        underflows to 0xFFFF - 65535 frames, about 22 minutes at 50Hz,
        against a SETTLE_TIMEOUT_S of 20 seconds, and re-zeroed every poll
        besides. Neither can reach the expiry branch, so flag 49 bit 7 is
        never set by a harness-induced timeout.

        Deliberately does NOT touch flag 48 or flag 49. Both are DAAD
        flags the comparison reads, and both legs must write them at the
        SAME logical point or the difference is the harness's own - so
        flag 48's write stays where jleg.js makes its matching one, at
        the top of each turn, and flag 49 is never written at all.
        inpTOFrames is an internal interpreter variable that appears in
        no capture and is compared against nothing, so it can be cleared
        as early and as often as needed. jDAAD has no counterpart to any
        of these timeouts: jleg.js's sandbox stubs setTimeout to a no-op,
        so the reference leg simply cannot time out, and forcing the Next
        leg to match is what keeps the pair honest.
        """
        self.z.write_memory(self.syms["INPTOFRAMES"], bytes([0, 0]))

    def fatal_error(self):
        """The interpreter's runtime-error code, or 0 if it has not raised.

        err_raise (src/errors.asm) paints "Runtime error N" across row 0,
        silences the AY, does `di` and then spins in `jr .halt` forever.
        The machine is dead: no lock will ever change again, no page will
        ever fire, and nothing the harness sends can be seen. Without this
        read, settle() sits out its full SETTLE_TIMEOUT_S and then blames
        the last (moreLock, wrapLock) pair, which says nothing at all
        about what actually happened.

        It is a real state the fixture reaches on purpose:
        tests/condacts.dsf's tail chains PROCESS 5..14 to prove the
        PROC_DEPTH limit is enforced, and error 3 IS the pass.
        """
        return self.z.read_memory(self.syms["ERRCODE"], 1)[0]

    PAGER_TIMEOUT_BIT = 0x02

    def pager_timeout_armed(self):
        """True when the interpreter's OWN pager timeout would fire on a
        page: a non-zero duration in flag 48 and bit 1 set in flag 49.

        Exactly wait_key_timeout's test (src/print.asm: `and e` against
        E=$02 from prn_more_check), read from the same two flags, so the
        harness agrees with the interpreter about what is armed instead
        of guessing from the script.
        """
        pair = self.z.read_memory(self.syms["FLAGS"] + FLAG_TIME, 2)
        return bool(pair[0]) and bool(pair[1] & self.PAGER_TIMEOUT_BIT)

    def armed_timeout_frames(self):
        """flag 48 expressed the way inp_edit expresses it: frame count.

        flag48*50 is inp_to_load's own arithmetic (src/overlay1.asm), so
        a harness re-arm restores the value the interpreter itself would
        have computed rather than inventing one. Must be read BEFORE the
        turn's flag-48 write clears it.
        """
        return self.z.read_memory(self.syms["FLAGS"] + FLAG_TIME, 1)[0] * 50

    def wait_for_input_wait_to_end(self, pre, arm_frames=0):
        """Let ONE input read time out, and return when it has.

        Only used by a turn that sends NO keys (the allow_timeout
        wait-turn, see load_script). Every other turn reaches settle()
        having just pushed Enter through zrcp.enter()'s own real settle
        sleep, so the editor has demonstrably moved on before the first
        poll. A wait-turn pushes nothing, so settle() would find the
        editor still parked - which is its READY condition - and return
        instantly, ending the turn before the timeout it exists to
        observe ever fires, and feeding the NEXT turn's keys into this
        turn's prompt.

        The re-arm undoes pure harness interference. tests/condacts.dsf's
        check 58 runs `TIME 2 0` and then `PARSE 0` in the MIDDLE of the
        PREVIOUS turn's settle, so inp_edit reads flag 48, loads
        inpTOFrames and parks - and that settle's own per-poll disarm then
        zeroes the countdown before the turn even ends. inp_edit reads
        flag 48 once at entry and treats a zero inpTOFrames as disarmed,
        so nothing inside the interpreter can start the clock again.

        EXACTLY ONCE, and the exit condition is the SCREEN, not the locks.
        Both of those were learned the hard way. "The locks dropped" is
        not a usable end-of-wait signal here, because the read that
        follows re-takes them within microseconds - check 58's timeout is
        followed immediately by check 59's own PARSE - so a poll can
        never see the gap, and a re-arm that fires "whenever the
        countdown reads zero" then arms THAT read too, and the next, and
        the next. Measured live: one run in four ran the fixture four
        checks past where the script expected it, and every later turn
        answered the wrong prompt. Arming once and watching for the
        screen to move (the timed-out check prints its verdict) ends the
        turn on the event it is actually about.
        """
        deadline = time.time() + SETTLE_TIMEOUT_S
        armed_once = not arm_frames
        while time.time() < deadline:
            if self.grid_rows() != pre:
                return                          # the read ended: output moved
            if not armed_once and self.z.read_memory(
                    self.syms["INPTOFRAMES"], 2) == b"\x00\x00":
                self.z.write_memory(
                    self.syms["INPTOFRAMES"],
                    bytes([arm_frames & 0xFF, (arm_frames >> 8) & 0xFF]))
                armed_once = True
                _dbg("re-armed the input timeout to %d frames", arm_frames)
            time.sleep(SETTLE_POLL_S)
        raise TimeoutError(
            "a wait-turn's input timeout never fired: nothing had been "
            "printed %.0fs later, with %d frame(s) armed. Either the "
            "fixture did not arm TIME before this turn's read, or the "
            "check it belongs to prints nothing when it expires"
            % (SETTLE_TIMEOUT_S, arm_frames))

    def settle(self, pages, boot=False, allow_timeout=False):
        """Advance through MORE pages, each one already captured by the
        emulator at the instruction where the pager parked, until the
        interpreter is genuinely ready for the next command - a POSITIVE
        stop condition (moreLock==1 AND wrapLock==1), never inferred from
        the mere absence of a signal. See the module docstring for why the
        earlier moreLock-only design was wrong and how the pair fixes it,
        and for why pages are read from the emulator's own dump rather
        than off the live screen.

        Returns True if a keypress wait that sets NEITHER lock (ANYKEY and
        friends) was walked through while settling this turn, so the
        caller can record it against the turn.

        `allow_timeout`: leave the interpreter's input-timeout countdown
        alone for this settle instead of zeroing it on every poll, so a
        fixture that ARMS a timeout (TIME n m) can have it actually
        expire. Off by default and must stay off for every ordinary turn -
        jDAAD cannot time out at all (jleg.js's sandbox stubs setTimeout
        to a no-op), so an expiry on this leg alone is a
        harness-manufactured divergence unless the script says out loud
        that this turn is about the timeout and the reference leg is
        given matching treatment. See play()'s handling of the
        "allow_timeout" directive.

        `boot`: True only for the ONE-TIME settle before the first
        scripted command (see nleg.play). Its ONLY effect now is a larger
        static-screen threshold (BOOT_ANYKEY_STATIC_POLLS) for the
        backstop, because a fixture's timed condacts can make the screen
        look static for the ordinary threshold's worth of time during a
        boot-time self-test.

        Raises TimeoutError naming the last observed (moreLock, wrapLock)
        pair and whether the screen was static, rather than returning
        quietly - a silent give-up here would hand the comparison stage a
        truncated capture that reads as a game divergence instead of a
        harness failure.
        """
        deadline = time.time() + SETTLE_TIMEOUT_S
        anykey_heuristic = False
        last_grid = None
        static_polls = 0
        last_more, last_wrap = None, None
        # The screen of the most recent pager fire this settle could not
        # attribute to a parked MORE page - see the fire branch below.
        captured_wait = None
        while time.time() < deadline:
            # Stop whatever timeout the interpreter may have just armed,
            # on EVERY poll and before anything else. Three waits arm it
            # from two different code paths - the command line, the
            # "More..." pager and ANYKEY - and only the first announces
            # itself through the locks, so there is no state to test here:
            # unconditionally clearing it once per poll is both cheaper
            # and more complete than trying to work out which wait (if
            # any) is currently running. See disarm_input_timeout.
            if not allow_timeout:
                self.disarm_input_timeout()
            # A raised runtime error ends the turn - and the session. The
            # interpreter is halted with interrupts off and will never
            # reach another lock, page or keypress, so every other signal
            # below is frozen from here on. See fatal_error().
            #
            # ORDERING CAVEAT, deliberate and currently unreachable: this
            # returns WITHOUT reading the page counter, so a page that
            # fired, was auto-dismissed, and was followed by a runtime
            # error all inside one poll window would be dropped unread -
            # its dump is on disk but nothing appends it. Unreachable in
            # the fixture that produces the only runtime error the
            # harness drives: condacts.dsf's E03 is raised from a
            # PROCESS chain that runs AFTER an ANYKEY the harness has to
            # dismiss itself, so a poll always lands between the last
            # page and the error. If a game is ever driven that can
            # raise mid-page, read the counter first and drain it before
            # returning.
            err = self.fatal_error()
            if err:
                _dbg("interpreter raised runtime error %d - halted", err)
                return anykey_heuristic
            # The page counter FIRST, ahead of the locks. A page fires,
            # and is captured by the emulator, before either lock can say
            # anything useful: moreLock is already up while SM32 is still
            # being printed, and it can be down again by the next poll if
            # a still-held harness key dismissed the page. The counter is
            # the only signal that is true exactly once per page.
            fires = self.page_fires()
            if fires > self.seen_fires:
                delta = fires - self.seen_fires
                self.seen_fires = fires
                if delta > 1:
                    raise RuntimeError(
                        "%d pager waits fired between two polls, but the "
                        "emulator's dump only holds the last one - %d page(s) "
                        "of text were lost. A page can normally only be "
                        "auto-dismissed by a harness key that is still held "
                        "(wait_key needs a FRESH press for the page after "
                        "it), so more than one per poll means either a "
                        "timeout is expiring unattended or the poll interval "
                        "has grown past a whole page's worth of output"
                        % (delta, delta - 1))
                page = self.captured_page(fires)
                more, wrap = self.more_state()
                last_more, last_wrap = more, wrap
                pages.append(page)
                _dbg("page %d captured (moreLock=%d wrapLock=%d)%s",
                     fires, more, wrap, "" if (more and not wrap)
                     else " - already dismissed or lockless wait")
                if more and not wrap:
                    if allow_timeout and self.pager_timeout_armed():
                        # The fixture armed a pager timeout and this turn
                        # is about it (see load_script). Pressing a key
                        # here is exactly what would stop the thing being
                        # measured, so the page is left to expire on its
                        # own; the polls below just wait for moreLock to
                        # drop.
                        _dbg("leaving the page to its own timeout")
                    else:
                        # Still parked on the page: dismiss it ourselves.
                        # NOT Enter - see zrcp.tap_dismiss_key.
                        self.z.tap_dismiss_key()
                    last_grid = None
                    static_polls = 0
                    captured_wait = None
                else:
                    # Press NOTHING. Either the page was already
                    # dismissed by a harness key that was still held (the
                    # interpreter has moved on and a key now would submit
                    # an empty command line and burn a turn), or this
                    # fire is h_anykey's, which sets no lock at all.
                    # Those two are indistinguishable from here: the
                    # register that tells them apart (E, $02 vs $04) is
                    # readable only when the CPU is stopped, and a
                    # free-running breakpoint cannot stop it - see the
                    # module docstring. A genuine ANYKEY-class wait is
                    # still found, and dismissed, by the static-screen
                    # backstop below, exactly as it was before pages were
                    # captured this way; remembering the page here just
                    # stops that backstop appending the same screen a
                    # second time.
                    captured_wait = page
                continue
            more, wrap = self.more_state()
            last_more, last_wrap = more, wrap
            if more and wrap and not self._ready_confirmed(fires):
                # Both locks set is not only the input editor - see
                # _ready_confirmed's docstring for the transient
                # prn_more_check window this rules out.
                #
                # Second sleep on this path (_ready_confirmed already
                # slept one interval): kept because removing it changes
                # the settle loop's live timing and reopens the replay's
                # reliability evidence for re-validation. Drop only if
                # the loop is restructured for other reasons.
                time.sleep(SETTLE_POLL_S)
                continue
            if more and wrap:
                # Disarm once more on the way out. The disarm at the top
                # of this poll happened BEFORE the lock read, so the
                # interpreter had the whole read window to reach the
                # command line and arm inpTOFrames itself - and READY is
                # exactly the state in which it just did. Nothing depends
                # on the ordering being airtight (the clock cannot expire
                # between polls - see disarm_input_timeout), but leaving
                # the turn with a live countdown for no reason is the
                # kind of gap that only shows up later, so close it.
                if not allow_timeout:
                    self.disarm_input_timeout()
                _dbg("settle READY after %d page(s)%s", len(pages),
                     " [boot]" if boot else "")
                return anykey_heuristic         # READY - press nothing.
            if more:
                # moreLock up, wrapLock down, and the counter has not
                # moved: prn_more_check has taken the lock but has not
                # reached the park point yet - SM32 is still going onto
                # the screen. Deliberately capture NOTHING here. This is
                # the exact state the old polled design mistook for "a
                # complete page", and reading the screen now would put a
                # half-drawn page into the transcript.
                time.sleep(SETTLE_POLL_S)
                continue
            # Neither lock set, and no page fired: either still
            # mid-execution, or parked on a wait that reaches neither the
            # locks nor WAIT_KEY_TIMEOUT. Only two such waits exist
            # (wait_key_reset's $0C escape and overlay2's direct wait_key
            # call), and neither announces itself, so they keep the
            # static-screen heuristic as a backstop.
            cur = self.grid_rows()
            if cur == last_grid:
                static_polls += 1
            else:
                static_polls = 0
                last_grid = cur
            if captured_wait is not None and cur == captured_wait:
                # A pager fire ALREADY announced this exact screen and
                # nothing has moved since, so this is a real parked wait,
                # not a fixture's timed condact looking static. The long
                # boot threshold exists only for the latter, so it does
                # not apply here.
                threshold = ANYKEY_STATIC_POLLS
            else:
                threshold = (BOOT_ANYKEY_STATIC_POLLS if boot
                             else ANYKEY_STATIC_POLLS)
            if static_polls >= threshold:
                if cur != captured_wait:
                    # Not the screen an unattributed pager fire already
                    # put into `pages` (see the fire branch) - so it is a
                    # wait that reached neither the locks nor
                    # WAIT_KEY_TIMEOUT, and its screen is only available
                    # from here.
                    pages.append(cur)
                captured_wait = None
                _dbg("static-screen backstop dismissed a lockless wait")
                self.z.tap_dismiss_key()
                anykey_heuristic = True
                last_grid = None
                static_polls = 0
                continue
            time.sleep(SETTLE_POLL_S)
        tail = [r.rstrip() for r in self.grid_rows() if r.strip()][-3:]
        raise TimeoutError(
            "interpreter did not settle within %.0fs - last observed "
            "moreLock=%s wrapLock=%s, screen %s across the last %d poll(s), "
            "%d page(s) this turn. Last text on screen: %r"
            % (SETTLE_TIMEOUT_S, last_more, last_wrap,
               "static" if static_polls > 0 else "changing", static_polls,
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


def play(workdir, script_path, out_path, nex_path, port=10000):
    workdir = Path(workdir)
    script = load_script(script_path)
    more_prompt = load_more_prompt(workdir)
    syms = symbols.load_symbols(ROOT / "build" / "nextdaad.map")
    obj_size = symbols.load_obj_size(ROOT / "src" / "nextdaad.inc")
    obj_count = (workdir / "next.ddb").read_bytes()[3]

    if port_already_listening(port):
        raise RuntimeError(
            "port %d is already accepting connections BEFORE we launched "
            "anything - a previous ZEsarUX (or something else) is likely "
            "still bound to it from an earlier interrupted run. Kill the "
            "stale process, or pass --port with a free one, and retry - "
            "otherwise this run would silently attach to the wrong "
            "emulator and every finding it produces would be garbage."
            % port)

    sd = stage_sd(workdir, nex_path)
    proc = launch(sd, port)
    try:
        z = wait_for_port(proc, port)
        try:
            leg = NextLeg(z, syms, obj_count, obj_size,
                          page_dump=workdir / PAGE_DUMP_NAME)

            # Pin the random stream to the same seed the jDAAD mirror uses -
            # via a boot-time breakpoint, not a plain write (see
            # _seed_rng_via_breakpoint's docstring for why a post-boot write
            # loses the race every time).
            _seed_rng_via_breakpoint(z, syms, sd / "nextdaad.nex")

            # Hand page capture to the emulator before ANY of the game's
            # output can page - see the module docstring's page-capture
            # section and arm_page_capture itself.
            leg.arm_page_capture()

            # Settle away everything the interpreter prints before its
            # first genuine input-wait (condacts.dsf's fixture runs a whole
            # self-test flood at boot) - this belongs to no scripted turn,
            # exactly mirroring jleg.js's own settle() call right after
            # handlers.ready() and before its command loop. This also
            # fixes FLAG_PROMPT (flag 42): writing it before eng_init_game's
            # unconditional "clear flags 0-255" loop has run gets silently
            # wiped by that clear; by the time settle() returns, that loop
            # has long since run, so every write from here on sticks.
            leg.settle([], boot=True)

            with open(out_path, "w", encoding="utf-8") as fh:
                for i, entry in enumerate(script):
                    cmd = entry["cmd"]
                    allow_timeout = entry["allow_timeout"]
                    # Disable the input timeout for this turn. jleg.js
                    # writes the same flag (48) to the same value with the
                    # same per-turn cadence, so both legs run with
                    # identical timeout state rather than the mismatch
                    # being a harness-manufactured "divergence" of its own.
                    #
                    # Read BEFORE it is cleared: a wait-turn re-arms the
                    # countdown the harness itself zeroed, and needs the
                    # duration the FIXTURE armed, which this write is
                    # about to erase. See wait_for_input_wait_to_end.
                    arm_frames = (leg.armed_timeout_frames()
                                  if allow_timeout else 0)
                    z.write_memory(syms["FLAGS"] + FLAG_TIME, bytes([0]))
                    # ...and disarm the countdown inp_edit ALREADY loaded.
                    # Writing flag 48 alone does not stop a timeout that
                    # is already running: inp_edit (src/overlay1.asm)
                    # reads flag 48 ONCE at entry and converts it to a
                    # frame count in inpTOFrames, and by the time the
                    # harness gets to write anything the editor is already
                    # parked in that wait - which is precisely the state
                    # settle() stops on. Its .wait loop re-reads
                    # inpTOFrames every iteration and treats zero as
                    # disarmed, so zeroing it here stops the clock for
                    # real.
                    #
                    # Confirmed live, and it is not theoretical: against
                    # tests/condacts.dsf, whose check 58 arms `TIME 2 0`,
                    # the 2-second timeout fired mid-command and NextDAAD
                    # came back with flag 49 = 64 (bit 6, "partial line
                    # preserved for recall" - set only on inp_edit's
                    # timeout path), desynchronising every later turn and
                    # producing flag/object divergences that were entirely
                    # the harness's own doing. The reference leg cannot
                    # ever match that, because jleg.js's sandbox stubs
                    # setTimeout to a no-op, so jDAAD's readText timeout
                    # never fires at all - both legs are meant to run with
                    # NO input timeout, and now both actually do. Same
                    # discipline as flag 48's own retraction: force it on
                    # both legs or mask it, never on one leg only.
                    #
                    # settle() already cleared this the moment the editor
                    # became ready; repeated here so a turn reached by any
                    # other path (the boot settle's own stopping point,
                    # for one) still starts with the clock stopped.
                    #
                    # ...unless this turn is explicitly ABOUT the timeout
                    # (see load_script). Flag 48 above is still written,
                    # and deliberately: inp_edit reads flag 48 ONCE at
                    # entry and is already parked by now, so zeroing the
                    # flag does not stop a countdown that is already
                    # running - only inpTOFrames does - while leaving the
                    # write in place keeps flag 48 itself, which IS
                    # compared, written at the same logical point on both
                    # legs.
                    if not allow_timeout:
                        leg.disarm_input_timeout()
                    # Force the fixed prompt - see PROMPT_SM above. The
                    # jDAAD leg writes the same value before each command.
                    z.write_memory(syms["FLAGS"] + FLAG_PROMPT,
                                   bytes([PROMPT_SM]))

                    # `pre` - the screen this turn's new text is measured
                    # against - is captured INSIDE the turn, positioned
                    # per directive so that neither leg's capture contains
                    # the other's input echo:
                    #
                    #   normal command: AFTER the characters are typed and
                    #     echoed, BEFORE Enter. NextDAAD's input editor
                    #     echoes what is typed onto the prompt row
                    #     (src/overlay1.asm inp_edit -> inp_insert), so a
                    #     `pre` taken before typing makes that row a
                    #     CHANGED row ("What now?>" -> "What now?>LOOK")
                    #     and new_text emits the echo as if the
                    #     interpreter had printed it. jleg.js deliberately
                    #     suppresses its own echo (key(ch, false)), so the
                    #     echo was a guaranteed text divergence on every
                    #     turn that types anything. Worse, that in-place
                    #     row edit combines with the turn's scroll into a
                    #     transition no single shift explains, which is
                    #     exactly tilemap.transition's ambiguous case - so
                    #     the echo also manufactured a text_ambiguous
                    #     caveat on nearly every turn AND defeated
                    #     scroll_delta, making new_text re-emit large stale
                    #     regions. Anchoring `pre` after the echo removes
                    #     all three at the source rather than filtering the
                    #     echo back out downstream.
                    #
                    #   "!" directive: BEFORE the keys go out. That one is
                    #     a raw key read (h_anykey) with no echo at all,
                    #     and jleg.js suppresses the corresponding key
                    #     echo on its side too. "?" used to be in this
                    #     group; since entry 4 was settled it echoes like
                    #     any other line and anchors like one.
                    #
                    # Deliberately NOT carried over from the previous
                    # turn's `post` any more: `post` is taken at
                    # input-editor-ready, i.e. before this turn's echo, so
                    # carrying it forward would reintroduce exactly the
                    # defect above.
                    pages = []
                    if cmd == "":
                        # A turn that types NOTHING: only reachable with
                        # allow_timeout (load_script refuses it
                        # otherwise), and the interpreter's own countdown
                        # is what ends the wait. `pre` anchors before the
                        # wait, and there is no echo to anchor after.
                        pre = leg.grid_rows()
                        leg.wait_for_input_wait_to_end(pre, arm_frames=arm_frames)
                    elif cmd.startswith("!"):
                        pre = leg.grid_rows()
                        for ch in cmd[1:]:
                            z.send_keys(ch)
                    elif cmd.startswith("?"):
                        # Confirmation prompt (e.g. QUIT's "Are you
                        # sure?") - see module docstring. Since SP16 Task
                        # 5 settled entry 4 against the original ZX
                        # interpreter, `confirm` reads a LINE, so this is
                        # the plain-command path: keys, anchor `pre`
                        # AFTER the echo (the reply is echoed now, it
                        # was not when this was a raw key read), Enter.
                        #
                        # `pre` is anchored BEFORE the keys, unlike the
                        # plain-command path, so the single echoed
                        # character lands inside the turn's text while
                        # jleg.js suppresses its own. That costs one
                        # character of known, stable text divergence on
                        # the turn that answers the prompt, and it is the
                        # option that does not add flakiness. Two others
                        # were tried and measured, both worse:
                        #  - anchor after a fixed wait: raced. 0.4s did
                        #    not reliably beat a ONE-character echo onto
                        #    the screen (a whole typed command does).
                        #  - anchor after polling for the first grid
                        #    change: wrong signal. The boot settle does
                        #    not always stop AT the confirmation prompt
                        #    (see BOOT_ANYKEY_STATIC_POLLS), so the first
                        #    change can be the fixture's own self-test
                        #    still running, and the anchor jumped a dozen
                        #    checks forward.
                        pre = leg.grid_rows()
                        z.send_keys(cmd[1:])
                        z.enter()
                    else:
                        z.send_keys(cmd)
                        pre = leg.grid_rows()
                        z.enter()
                    anykey_heuristic = leg.settle(
                        pages, allow_timeout=allow_timeout)

                    post = leg.grid_rows()
                    text_rows = []
                    ambiguous = False
                    prev = pre
                    # Blank the pager prompt out of every captured MORE
                    # page BEFORE any of it is interpreted - see
                    # blank_prompt_rows and load_more_prompt. Only the
                    # pages are touched, never the final post-turn screen:
                    # prn_more_check erases the prompt itself before the
                    # turn continues, so it cannot legitimately be there -
                    # but a game whose SM32 text also appears in its own
                    # prose could be, and that prose must still compare.
                    if more_prompt is not None:
                        pages = [blank_prompt_rows(p, more_prompt)
                                 for p in pages]
                    for page in pages + [post]:
                        # A turn that both scrolls and redraws a row in
                        # place (a status line) cannot be explained by one
                        # shift, so new_text's row set is untrustworthy.
                        # Mark it rather than silently emitting stale rows
                        # as new text.
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
                        # err_raise halts with interrupts off (see
                        # fatal_error). Anything after this would be
                        # played to a dead machine and silently recorded
                        # as "the game printed nothing and changed
                        # nothing" on every remaining turn - a wall of
                        # divergences with no cause attached. This turn
                        # IS written out first: whatever it captured up
                        # to the error is real evidence, and for
                        # tests/condacts.dsf the error IS the check.
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
            z.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
