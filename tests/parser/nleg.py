"""Play a command script on NextDAAD under ZEsarUX and record what
happened.

Two things this does that the Dracula zxplay.py did not:

  1. It POLLS for a definite "ready for the next command" state instead
     of sleeping. Sleeping is what made scripts containing SLEEP desync
     there - the ANYKEY pages swallowed subsequent keystrokes.
  2. It READS the tilemap rather than photographing the screen. ZEsarUX's
     get-ocr is ULA-based and cannot see the Next tilemap at all.

FIX ROUND 1 (moreLock+wrapLock discriminator): the first version of this
module polled moreLock alone and inferred "done" from its absence. That
was wrong - moreLock is the SAME byte for two different waits. It is set
across the interpreter's ENTIRE "More..." page (src/print.asm
prn_more_check) AND across the interpreter's ENTIRE input-line edit
(src/overlay1.asm inp_edit, "locks BEFORE any echo"), and turn processing
is fast enough against a ~100ms poll that settle() would typically observe
moreLock=1 because inp_edit had ALREADY re-entered for the next command,
misread that as an undismissed MORE page, and fire a spurious Enter into
it. See task-9-report.md's original writeup for the live evidence.

wrapLock (src/nextdaad.map symbol WRAPLOCK) is the discriminator:

    state                  moreLock   wrapLock
    running (mid-turn)        0          0
    MORE page waiting         1          0
    input editor ready        1          1

inp_edit (overlay1.asm:626-628) sets BOTH moreLock and wrapLock at entry
and holds both across its whole wait, clearing both together only when
editing ends (the timeout path at line 695, or the normal-submit path at
line 757). prn_more_check (print.asm:250-258) also sets both at first, but
explicitly clears wrapLock ("restore buffering for the outer word") BEFORE
calling wait_key_timeout - so by the time it is actually parked waiting
for the dismiss keypress, wrapLock reads 0. moreLock==1 AND wrapLock==1
together, then, is a positive "the interpreter is genuinely ready, do not
press anything" signal - not an absence-of-signal inference.

A third wait state remains invisible to both locks: ANYKEY-style prompts
(src/overlay0.asm h_anykey calls wait_key_timeout directly, setting
neither lock - wait_key_timeout itself only polls the keyboard port and
stores no marker of its own). There is no memory signal for this state at
all, so it is handled by a HEURISTIC, not a positive read: if the tilemap
is unchanged for ANYKEY_STATIC_POLLS consecutive polls while the
interpreter is still not READY, that is treated as a blocked ANYKEY-style
wait. Turns where this heuristic fires are marked anykey_heuristic=True in
the jsonl output so a later divergence on that turn can be judged in that
light (see nleg.play).

KNOWN RESIDUAL - a "More..." page can be missed entirely, and this is NOT
closed. wait_key (src/print.asm) is press-then-release: if a key is
ALREADY down when it runs, it falls straight through to its release wait
and returns. The Enter that submitted the command is held for
KEY_DELAY_MS (150ms, zrcp.py), and a turn's output can reach the pager
well inside that window - so the page is dismissed by the harness's own
still-held keystroke, and with SETTLE_POLL_S at 100ms moreLock can go
1 -> 0 between two polls with nothing observed. When that happens the page
is never appended to `pages` and everything on it scrolls away
uncaptured, which is a LARGER text loss than the prompt row the SM32
filter deals with. It was seen live on tests/condacts.dsf turn 11 (two
runs captured the page, a third did not, with identical interpreter
state), and Dracula pages too, so this is not theoretical.

What has been done about it: the SM32 filter (see load_more_prompt) and
blank_prompt_rows remove the PROMPT ROW from both the emitted text and
the ambiguity verdict, so the common case - page captured vs page
dismissed, differing only by that one row - no longer perturbs
findings.json at all. That is what made the reliability triples
byte-identical. It does NOT cover a page whose OTHER content is lost.

What would actually close it: capture pages from a breakpoint on
prn_more_check rather than by polling two lock bytes, which needs the
turn loop restructured around cpu-step/run instead of free-running
execution. That is an architecture change, not a repair, and is
deliberately not attempted here. Until then, treat a text divergence on a
turn where the two legs' output lengths differ wildly as suspect, and
re-run before promoting it.

Script entry forms - each is a LOGICAL instruction; each leg (this file
and jleg.js) realises it the way its own input model requires:
  "COMMAND"  a normal command line: typed, Enter, then settled.
  "!X"       raw keys with NO Enter - for prompts the line reader never
             sees (e.g. a genuine ANYKEY-style "Press any key" pause).
  "?X"       answer a confirmation prompt (e.g. QUIT's "Are you sure?")
             with X. Sends X and then Enter - i.e. exactly what a plain
             command does - and is kept as a separate spelling only so a
             script says out loud that the turn is answering a
             confirmation rather than issuing an order.

             HISTORY, because this directive used to do something
             different and the difference is now settled. It existed
             because the two legs collected the confirmation
             differently: NextDAAD's `confirm` (src/overlay0.asm, from
             h_quit) took ONE raw keypress, so this leg sent the key
             alone, while jDAAD's _QUIT calls getPlayerOrders() - the
             same full-line reader its main loop uses - so jleg.js sent
             key + Enter. docs/parser-bugs.md entry 4 recorded that and
             flagged it as unsettled. SP16 Task 5 ran the tie-breaker
             against the ORIGINAL ZX interpreter under ZEsarUX
             (.superpowers/sdd/sp16-adjudications/): a bare Y at the
             SM12 prompt is ECHOED into a line and nothing happens until
             ENTER. NextDAAD was the outlier and now reads a line too,
             so the per-leg split is gone and both legs send key+Enter.
"""
import json
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
# a race in the emulator itself). QUIT's "Are you sure?" (the fixture's
# first genuine keypress wait) does not resolve on its own no matter how
# long boot-settle waits - only the script's own "?" answer, sent
# afterward as the first scripted turn, resolves it - so ANY threshold
# comfortably above the longest plausible timed-condact gap will always
# eventually and correctly land there. 3 seconds (30 polls) was chosen
# with a wide safety margin over the ~0.1-0.3s condact delays actually
# present in this fixture, while staying well under SETTLE_TIMEOUT_S.
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
# How long the RNG-seed breakpoint's run() may take to fire. Generous:
# confirmed live this normally fires in well under 2s (smartload plus the
# handful of instructions from NextDAAD's entry point to eng_init_game's
# seed write), but this is real wall-clock work, not instant.
#
# Root-cause note (Rabenstein 60s-timeout investigation): the breakpoint
# mechanism itself - arming order, PC=<addr> condition syntax, and the
# SEEDOK address from build/nextdaad.map - was never the fault, and this
# deadline was never the fault either. Confirmed live: when `workdir` (and
# therefore `sd`, below) is a RELATIVE path - exactly what argparse's
# --out gives when a caller passes a relative directory, e.g.
# `--out tests/parser/work/rabenstein-probe` - launch() passes that same
# relative string as both `--esxdos-root-dir`/`--smartloadpath` AND as
# the subprocess's own `cwd`. ZEsarUX's process cwd ends up correctly at
# .../sd (Popen resolves its own `cwd=` argument correctly), but ZEsarUX
# then resolves ITS OWN `--esxdos-root-dir`/`--smartloadpath` arguments,
# and later the ZRCP `smartload <path>` command's argument (also built
# from the same relative `sd`), AGAINST that same cwd - doubling the path
# (".../sd/tests/parser/work/rabenstein-probe/sd/...", which does not
# exist) and silently failing to load anything. get-registers confirmed
# this live: PC after "smartload" stayed inside NextZXOS's own boot ROM
# (0x1baf -> 0x1bac) instead of jumping to the loaded program's entry
# (0x8000, the always-correct behaviour confirmed separately whenever
# `workdir` was absolute) - the interpreter never started running at all,
# so the breakpoint could never fire no matter how long this deadline is.
# Not a size/timing issue, not flakiness: a real, 100%-reproducible
# relative-vs-absolute path bug. Fixed by resolving `workdir` to absolute
# in stage_sd() below, once, at the source, rather than raising this
# number (which was tried first and correctly did not help).
SEED_RUN_DEADLINE_S = 60.0


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

    eng_init_game (src/engine.asm) seeds rngState from the Z80 refresh
    register R plus frameCounter, falling back to $A5C3 only if both are
    zero - real entropy, correct behaviour for a shipped game (owner
    ruling: this stays as-is in src/, the harness works around it). The
    problem is timing, not logic: a plain write-memory to RNGSTATE issued
    after the game is already running loses the race every time -
    confirmed live, RNGSTATE already held its post-seed entropy value on
    the very FIRST read after wait_for_port() returned a connection, well
    before this function or anything else in Python got a chance to run.
    Boot, under ZEsarUX's smartload, is simply faster than one socket
    connect.

    The only reliable fix is to control the load ourselves. launch() no
    longer passes the .nex on ZEsarUX's command line, so nothing runs
    until this function explicitly smartloads it - with a breakpoint on
    ENG_INIT_GAME@SEEDOK (confirmed live: the exact `ld (rngState),hl`
    instruction) already armed:

      1. enter-cpu-step (pause wherever the CPU currently sits - reliably
         very early, since nothing has been loaded yet).
      2. set the PC breakpoint at SEEDOK and enable breakpoints.
      3. smartload the game via ZRCP itself - confirmed live: since the
         CPU is already in cpu-step mode, smartload leaves it there
         afterwards (its own help text: "if it was already on cpu-step
         mode, it will be on cpu-step mode after loading"), so nothing
         auto-runs before we tell it to.
      4. run() - executes until the breakpoint fires, PC = SEEDOK, the
         `ld` has NOT executed yet.
      5. override the HL register to RNG_SEED, then cpu-step once so the
         CPU's OWN `ld (rngState),hl` performs the write. A plain
         write-memory to RNGSTATE at this exact point does not reliably
         stick (confirmed live: reads back as zero, or some later
         unrelated value) - routing the write through the CPU's normal
         execution path instead does.
      6. disable the breakpoint and exit cpu-step, handing control back
         to the emulator's own free-running loop.

    Symbol addresses are always loaded from the map (see symbols.py),
    never hardcoded.
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
    def __init__(self, z, syms, obj_count, obj_size):
        self.z = z
        self.syms = syms
        self.obj_count = obj_count
        self.obj_size = obj_size

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
        SAME logical point or the difference is the harness's own
        (docs/parser-bugs.md entry 5's flag-48 retraction) - so flag 48's
        write stays where jleg.js makes its matching one, at the top of
        each turn, and flag 49 is never written at all. inpTOFrames is an
        internal interpreter variable that appears in no capture and is
        compared against nothing, so it can be cleared as early and as
        often as needed. jDAAD has no counterpart to any of these
        timeouts: jleg.js's sandbox stubs setTimeout to a no-op, so the
        reference leg simply cannot time out, and forcing the Next leg to
        match is what keeps the pair honest.
        """
        self.z.write_memory(self.syms["INPTOFRAMES"], bytes([0, 0]))

    def settle(self, pages, boot=False):
        """Advance through MORE pages, capturing each one before it
        scrolls away, until the interpreter is genuinely ready for the
        next command - a POSITIVE stop condition (moreLock==1 AND
        wrapLock==1), never inferred from the mere absence of a signal.
        See the module docstring for why the earlier moreLock-only design
        was wrong and how the pair fixes it.

        Returns True if the ANYKEY heuristic (see module docstring) fired
        at least once while settling this turn, so the caller can record
        it against the turn.

        `boot`: True only for the ONE-TIME settle before the first
        scripted command (see nleg.play). During boot, the ANYKEY-style
        static-screen heuristic is NOT auto-dismissed by pressing Enter -
        it is treated as the boot-settle's own stopping point instead.
        This matters for a confirmed, genuine architectural difference
        between the two interpreters: NextDAAD's QUIT confirmation
        (src/overlay0.asm `confirm`, via `key_wait_char`) sets neither
        lock - exactly like an ordinary "Press any key" pause - but
        jDAAD's equivalent (jdaad.js `_QUIT`, via `getPlayerOrders()`) is
        a full LINE read, the SAME mechanism as its main command loop.
        jleg.js's own boot settle (`waiting()`, which checks only
        inANYKEY/inMORE) therefore does NOT auto-dismiss jDAAD's QUIT
        prompt either - it stops there, leaving it for the script's first
        real command to answer. Auto-dismissing NextDAAD's side of that
        SAME prompt during boot (confirmed live) has NextDAAD consume it
        with a blank keypress while jDAAD leaves it open - a genuine
        turn-0 misalignment, not a bug in either interpreter. Per-turn
        settling (boot=False, the default) is unaffected: MID-TURN
        "Press any key"/"More..." pauses are still auto-dismissed exactly
        as before, matching jDAAD's own per-turn settle(), which also
        auto-dismisses those (both `inMORE` and `inANYKEY` there DO stop
        `waiting()`'s loop and get a key pressed).

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
        while time.time() < deadline:
            # Stop whatever timeout the interpreter may have just armed,
            # on EVERY poll and before anything else. Three waits arm it
            # from two different code paths - the command line, the
            # "More..." pager and ANYKEY - and only the first announces
            # itself through the locks, so there is no state to test here:
            # unconditionally clearing it once per poll is both cheaper
            # and more complete than trying to work out which wait (if
            # any) is currently running. See disarm_input_timeout.
            self.disarm_input_timeout()
            more, wrap = self.more_state()
            last_more, last_wrap = more, wrap
            if more and wrap:
                return anykey_heuristic         # READY - press nothing.
            cur = self.grid_rows()
            if more:
                # moreLock set, wrapLock clear: a genuine MORE page.
                # Capture it BEFORE advancing, or the text scrolls away
                # and is lost forever.
                pages.append(cur)
                self.z.enter(wait=0.4)
                last_grid = None
                static_polls = 0
                continue
            # Neither lock set: either still mid-execution, or parked on
            # an ANYKEY-style wait that sets no lock at all (heuristic -
            # see module docstring).
            if cur == last_grid:
                static_polls += 1
            else:
                static_polls = 0
                last_grid = cur
            threshold = BOOT_ANYKEY_STATIC_POLLS if boot else ANYKEY_STATIC_POLLS
            if static_polls >= threshold:
                if boot:
                    # Boot-settle stops HERE rather than dismissing it -
                    # see the boot= docstring above and
                    # BOOT_ANYKEY_STATIC_POLLS's own comment for why this
                    # threshold is much larger than the per-turn one.
                    return False
                pages.append(cur)
                self.z.enter(wait=0.4)
                anykey_heuristic = True
                last_grid = None
                static_polls = 0
                continue
            time.sleep(SETTLE_POLL_S)
        raise TimeoutError(
            "interpreter did not settle within %.0fs - last observed "
            "moreLock=%s wrapLock=%s, screen %s across the last %d poll(s)"
            % (SETTLE_TIMEOUT_S, last_more, last_wrap,
               "static" if static_polls > 0 else "changing", static_polls))


def load_more_prompt(workdir):
    """This game's SM32 (the "More..." pager prompt), or None if the game
    genuinely has no SM32.

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
            "%s is missing - the jDAAD leg must write it before the Next "
            "leg runs. Without it the pager prompt cannot be filtered and "
            "the run would be nondeterministic; this is a harness failure, "
            "not a game divergence." % meta)
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


def play(workdir, script_path, out_path, nex_path, port=10000):
    workdir = Path(workdir)
    commands = json.loads(Path(script_path).read_text(encoding="utf-8"))
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
            leg = NextLeg(z, syms, obj_count, obj_size)

            # Pin the random stream to the same seed the jDAAD mirror uses -
            # via a boot-time breakpoint, not a plain write (see
            # _seed_rng_via_breakpoint's docstring for why a post-boot write
            # loses the race every time).
            _seed_rng_via_breakpoint(z, syms, sd / "nextdaad.nex")

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
                for i, cmd in enumerate(commands):
                    # Disable the input timeout for this turn. jleg.js
                    # writes the same flag (48) to the same value with the
                    # same per-turn cadence, so both legs run with
                    # identical timeout state rather than the mismatch
                    # being a harness-manufactured "divergence" of its own.
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
                    # discipline as flag 48's own retraction in
                    # docs/parser-bugs.md entry 5: force it on both legs
                    # or mask it, never on one leg only.
                    #
                    # settle() already cleared this the moment the editor
                    # became ready; repeated here so a turn reached by any
                    # other path (the boot settle's own stopping point,
                    # for one) still starts with the clock stopped.
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
                    if cmd.startswith("!"):
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
                    anykey_heuristic = leg.settle(pages)

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
                    }) + "\n")
        finally:
            z.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
