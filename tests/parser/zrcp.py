"""ZEsarUX remote protocol client.

Command set confirmed against the ZEsarUX source (src/zrcp/remote.c):

  read-memory [address] [length]   -> hexadecimal text
  write-memory address v v v ...   -> bytes SPACE-SEPARATED hex
  write-memory-raw address vvvv    -> bytes hex, NOT separated
  set-memory-zone / get-memory-zones / get-current-memory-zone
  hexdump pointer length           -> hex plus ascii (not used here)

There is no get-cpu-frames. For a per-turn tick we read NextDAAD's own
FRAMECOUNTER symbol instead, which is more useful anyway.

Argument base (Task 6 Step 1 result) - record verbatim:
  DECIMAL. Measured against a running ZEsarUX (tbblue, --vo null --ao null,
  ZRCP on port 10000) by writing a sentinel with the decimal spelling of
  address 40000 (= 0x9C40) and reading it back both ways:

    write   : 'command>'
    dec read: '01020304\ncommand>'
    hex read: 'EC052A2E\ncommand>'

  `read-memory 40000 4` returned the sentinel 01 02 03 04 written by
  `write-memory 40000 1 2 3 4`; `read-memory 9C40 4` returned unrelated
  bytes from a different location. Numeric address arguments are decimal.
  (Separately confirmed live: `read-memory 0 16` returned
  F3C3250145300642C3EC052A2E2AFF00, the standard ZX ROM boot bytes
  DI; JP $0125 ..., at address 0 - consistent with decimal addressing.)

  Fix round 1 note: the hex-spelled read (EC052A2E) is not arbitrary
  garbage - it is bytes 9-12 of the same ROM dump above. ZRCP parsed the
  string "9C40" as decimal, read the leading "9", and stopped at the
  non-digit "C". The decimal conclusion is therefore confirmed by the
  parser's actual mechanism, not just by elimination.

Every ZRCP reply is terminated with the literal prompt "command> ", and
ZEsarUX never closes the connection. Replies are drained by reading until
the accumulated buffer ends with that prompt (see _read_until_prompt),
not by waiting out a socket timeout - the latter cost a fixed ~2s on
every single call (Fix round 1, finding 1).

Error replies (Fix round 1, finding 2) - confirmed live against a running
ZEsarUX rather than assumed:
  set-memory-zone 999      -> 'ERROR. Unknown zone 999\ncommand> '
  <unrecognised command>   -> 'Unknown command\ncommand> '
Only the first form carries the documented "ERROR." prefix (all caps,
with a period); the second has no ERROR marker at all, so error detection
alone cannot be trusted to catch every failure mode - parse_bytes also
requires the entire post-prompt payload to be hex digits/whitespace and
raises on anything else, which catches "Unknown command" too.

CAUTION (discovered during fix-round verification, not exercised by any
code path here): sending `read-memory <addr> <negative length>` pegs
ZEsarUX at ~100% CPU and wedges its ZRCP command loop indefinitely - the
process stops answering even brand new connections until it is killed.
Never construct a negative or otherwise malformed length. This client
never does; `read_memory`/`write_memory` build lengths from `len(data)`
or a caller-supplied non-negative int.

Timing note inherited from the Dracula prior art: keys must be sent at
about 150ms apart or the emulated keyboard matrix drops characters. 40ms
is not reliable. Key-sending calls keep an explicit settle-time sleep for
this reason (real wall-clock time the emulator takes to work through the
keystrokes), independent of prompt-based draining.
"""
import re
import socket
import time

# "dec" or "hex" - set from the Step 1 measurement, do not guess.
ADDR_BASE = "dec"
KEY_DELAY_MS = 150

MEMORY_READ_CMD = "read-memory"

# The literal reply terminator ZEsarUX appends after every command, and
# the confirmed prefix of an explicit error reply (see header note above).
PROMPT = "command> "
ERROR_PREFIX = "ERROR."

# enter-cpu-step (Task 11 negative-control RNG fix) changes the prompt from
# the plain "command> " to "command@cpu-step> ", confirmed live - the
# original exact-suffix match on "command> " never matches that form, so
# _read_until_prompt hung until its deadline the first time this was tried.
# exit-cpu-step reverts to the plain prompt. Match either shape generically
# rather than hardcoding both literal strings.
_PROMPT_RE = re.compile(r"command(?:@\S+)?>\s*$")

# Default bounded backstop for a prompt-terminated read. A missing prompt
# (protocol desync, wedged emulator) raises instead of hanging forever.
DEFAULT_DEADLINE = 10.0
# Large reads (e.g. a 5120-byte tilemap capture) need more headroom.
READ_MEMORY_DEADLINE = 20.0


class ZrcpError(IOError):
    """Raised when a ZRCP reply is an explicit error, or contains anything
    other than hex digits/whitespace where hex bytes were expected."""


def _strip_prompt(text):
    """Remove the trailing ZRCP prompt (and surrounding whitespace), in
    either its plain ("command> ") or cpu-step ("command@cpu-step> ")
    form."""
    text = text.strip()
    return _PROMPT_RE.sub("", text).strip()


def check_error(payload):
    """Raise ZrcpError if a prompt-stripped reply is a ZEsarUX error."""
    if payload.lstrip().startswith(ERROR_PREFIX):
        raise ZrcpError("ZRCP error: %s" % payload.strip())


def parse_bytes(text):
    """Turn an emulator hex reply into bytes.

    Strips the trailing prompt, raises ZrcpError if the payload is an
    explicit ZEsarUX error, and raises ZrcpError if anything other than
    hex digits/whitespace survives. Extracting only the hex-looking
    substrings out of arbitrary text is how contamination happens: a
    diagnostic like "Breakpoint set at cafe" is entirely valid-looking
    hex-adjacent prose and must be rejected outright, not scraped for the
    bytes 0xCA 0xFE.
    """
    payload = _strip_prompt(text)
    check_error(payload)
    if payload == "":
        return b""
    if not re.match(r"^[0-9A-Fa-f\s]*$", payload):
        raise ZrcpError("unexpected non-hex content in reply: %r" % text[:200])
    hexes = re.findall(r"[0-9A-Fa-f]{2}", payload)
    return bytes(int(h, 16) for h in hexes)


def _fmt_addr(addr):
    """Spell an address the way this build's parser reads numbers."""
    if ADDR_BASE == "hex":
        return "%X" % addr
    return "%d" % addr


class Zrcp:
    def __init__(self, port=10000, timeout=20, connect_deadline=DEFAULT_DEADLINE):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self._read_until_prompt(deadline=connect_deadline)  # drain the welcome banner

    def _read_until_prompt(self, deadline=DEFAULT_DEADLINE, poll_timeout=0.2):
        """Read until the buffer ends with the ZRCP prompt, or raise if
        `deadline` seconds pass without seeing one. ZEsarUX never closes
        the connection, so the prompt is the only reliable end-of-reply
        signal - this replaces waiting out a fixed socket timeout on
        every call.
        """
        buf = b""
        start = time.monotonic()
        self.s.settimeout(poll_timeout)
        while not _PROMPT_RE.search(buf.decode("latin-1", "replace")):
            if time.monotonic() - start > deadline:
                raise ZrcpError(
                    "ZRCP reply did not terminate with a recognised prompt "
                    "within %.1fs - got %r" % (
                        deadline, buf[-200:].decode("latin-1", "replace")))
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                continue
            if chunk:
                buf += chunk
        return buf.decode("latin-1")

    def cmd(self, text, wait=0.0, deadline=DEFAULT_DEADLINE):
        """Send a command and return its reply with the prompt stripped.

        `wait` is real settle time to sleep BEFORE draining - only needed
        where the emulator keeps doing something (feeding keystrokes)
        after it has already acknowledged the command. Ordinary commands
        need no fixed sleep: draining stops as soon as the prompt shows
        up, whether that is near-instant or a large read taking longer.
        """
        self.s.sendall((text + "\n").encode("latin-1"))
        if wait:
            time.sleep(wait)
        reply = self._read_until_prompt(deadline=deadline)
        return _strip_prompt(reply)

    def read_memory(self, addr, length, deadline=READ_MEMORY_DEADLINE):
        if length < 0:
            raise ValueError(
                "read_memory: length must not be negative (got %r) - a "
                "negative read-memory length wedges ZEsarUX at 100%% CPU, "
                "unresponsive even to new connections, until killed" % (length,))
        reply = self.cmd("%s %s %d" % (MEMORY_READ_CMD, _fmt_addr(addr), length),
                          deadline=deadline)
        data = parse_bytes(reply)
        if len(data) != length:
            raise IOError("read %d bytes at 0x%04X, expected %d - reply was %r"
                          % (len(data), addr, length, reply[:200]))
        return data

    def write_memory(self, addr, data, deadline=DEFAULT_DEADLINE):
        # write-memory takes SPACE-SEPARATED hex bytes. The unseparated
        # form is a different command, write-memory-raw.
        values = " ".join("%02X" % b for b in data)
        reply = self.cmd("write-memory %s %s" % (_fmt_addr(addr), values),
                          deadline=deadline)
        check_error(reply)

    def send_keys(self, text):
        settle = (KEY_DELAY_MS / 1000.0) * len(text) + 0.8
        self.cmd("send-keys-string %d %s" % (KEY_DELAY_MS, text),
                 wait=settle, deadline=settle + DEFAULT_DEADLINE)

    def enter(self, wait=1.0):
        self.cmd("send-keys-ascii %d 13" % KEY_DELAY_MS,
                 wait=wait, deadline=wait + DEFAULT_DEADLINE)

    # Emulated keyboard matrix rows, in set-ui-io-ports order: row 0
    # first, then rows 1-7, then the joystick byte. A ZERO bit is a
    # PRESSED key. Every row below is written BIT 4 FIRST, ending at bit
    # 0 - the same order ZEsarUX's own `help set-ui-io-ports` prints them
    # in, and the same order the key nearest the outside of the physical
    # keyboard comes first:
    #   row 0  V  C  X  Z  CAPS      row 4  6 7 8 9 0
    #   row 1  G  F  D  S  A         row 5  Y U I O P
    #   row 2  T  R  E  W  Q         row 6  H J K L ENTER
    #   row 3  5  4  3  2  1         row 7  B N M SYM SPACE
    # so bit 0 is CAPS on row 0, A on row 1, Q on row 2, 1 on row 3, 0 on
    # row 4, P on row 5, ENTER on row 6 and SPACE on row 7.
    #
    # MEASURED CONSTRAINT, and it is not obvious: BIT 0 OF A ROW DOES NOT
    # TAKE through set-ui-io-ports. Confirmed live against ZEsarUX 13.0
    # in three separate probes - holding row 6 bit 0 (ENTER) or row 7 bit
    # 0 (SPACE) had NO effect on the running interpreter at all, while
    # `get-ui-io-ports` read the state back correctly the whole time, and
    # row 7 bit 1 (SYMBOL SHIFT) and row 7 bit 3 (N, which echoed into the
    # input line) both worked. Whatever the cause, anything driven from
    # here must use a NON-bit-0 key. That is why the dismissal key below
    # is SYMBOL SHIFT and not CAPS SHIFT, which is row 0 BIT 0 and would
    # otherwise have been the obvious choice.
    MATRIX_IDLE = "FFFFFFFFFFFFFFFF00"
    # SYMBOL SHIFT alone: row 7 (the eighth byte), bit 1.
    MATRIX_SYM_SHIFT = "FFFFFFFFFFFFFFFD00"

    def hold_matrix(self, rows):
        """Hold a keyboard matrix state until release_matrix() is called.

        Unlike send-keys-*, where the emulator decides how long the key
        stays down, this makes both edges the harness's own decision -
        which is the only way to guarantee a key is GONE before the
        interpreter's next input read starts - see tap_dismiss_key.
        """
        self.cmd("set-ui-io-ports %s" % rows)

    def release_matrix(self):
        self.cmd("set-ui-io-ports %s" % self.MATRIX_IDLE)

    def tap_dismiss_key(self, hold=0.12, settle=0.28):
        """Press and release SYMBOL SHIFT, driving the emulated keyboard
        matrix directly.

        This is the key the harness uses to release a "More..." page or a
        "press any key" pause, and it is SYMBOL SHIFT for two reasons,
        one about the interpreter and one about the emulator.

        The interpreter: NextDAAD's kb_char maps a bare SYMBOL SHIFT
        (matrix code 36) to 0 in ALL THREE of its tables - kbMapPlain,
        kbMapCaps and kbMapSym, src/overlay1.asm - so the input line
        editor ignores it completely, while wait_key (src/print.asm),
        which only tests the five key bits of port $FE, accepts it
        exactly like any other key.

        That difference is the whole point. Dismissing a pause with ENTER
        used to hand the SAME keypress to two different readers. wait_key
        polls the port directly and never touches kb_char's autorepeat
        state, so the key stays NEW as far as the input editor is
        concerned: the pause consumed it, the interpreter ran on to its
        next input read while the key was still physically down for
        KEY_DELAY_MS, kb_char saw a fresh press and inp_edit took it as a
        submitted EMPTY LINE. One turn's worth of script then answered
        the wrong prompt and every later turn was compared against the
        wrong one - measured live against tests/condacts.dsf's extended
        replay, where roughly one run in three desynchronised and ran the
        fixture to its end several turns early. A key the editor cannot
        see closes that off at the source rather than trying to out-time
        it. (A command's own ENTER cannot do this - it goes THROUGH
        kb_char, which then holds it off for 35 frames.)

        The emulator: CAPS SHIFT would do the interpreter half just as
        well - kb_char maps matrix code 0 to 0 too - but it is row 0 BIT
        0, and bit 0 of a row does not take through set-ui-io-ports. See
        the measured constraint recorded on MATRIX_IDLE above.

        set-ui-io-ports drives the matrix rows directly (a 0 bit is a
        pressed key), so both the press and the release are the harness's
        own decision - unlike send-keys-*, where the hold is whatever the
        emulator decides. Row 7 is `B N M SYM SPACE`, so 0xFD in the
        EIGHTH byte presses SYMBOL SHIFT alone; all-0xFF is every key up.
        The trailing 00 is the joystick byte, which must be sent and must
        stay 0.
        """
        self.hold_matrix(self.MATRIX_SYM_SHIFT)
        time.sleep(hold)
        self.release_matrix()
        if settle:
            time.sleep(settle)

    # ---- breakpoint / cpu-step control (Task 11 RNG-seed fix) -------------
    # Confirmed live against ZEsarUX 12.1 (`help set-breakpoint`, `help
    # run`, `help enter-cpu-step`): "run" only honours breakpoints and
    # blocks-until-fired when the CPU is already in cpu-step mode ("Run cpu
    # WHEN ON cpu step mode" - its own help text). The sequence a caller
    # needs is: enter_cpu_step() (pauses free execution wherever the CPU
    # currently is - also switches the prompt to "command@cpu-step> ", see
    # _PROMPT_RE above), set_breakpoint()+enable_breakpoints(), run() to
    # execute at full speed until that address is hit, cpu_step() to
    # actually execute the trapped instruction, then disable_breakpoints()
    # and exit_cpu_step() to hand control back to the emulator's own loop.

    def enter_cpu_step(self):
        return self.cmd("enter-cpu-step")

    def exit_cpu_step(self):
        return self.cmd("exit-cpu-step")

    def set_breakpoint(self, index, condition):
        """Set breakpoint `index`. Breakpoints must ALREADY be enabled -
        see enable_breakpoints below.

        The reply is error-checked. It previously was not, and that is how
        the ZEsarUX 13.0 ordering change (below) went unnoticed: the
        emulator answered "Error. You must enable breakpoints first", the
        harness discarded it, and the only symptom was run() blocking
        until its 60s deadline with no breakpoint armed at all - a failure
        that names nothing. Every command whose failure would leave the
        run silently mis-armed checks its reply.
        """
        reply = self.cmd("set-breakpoint %d %s" % (index, condition))
        check_error(reply)
        return reply

    def enable_breakpoints(self):
        """Enable the breakpoint system. MUST be called BEFORE
        set_breakpoint.

        Confirmed live against ZEsarUX 13.0 (2026-07-31): with
        breakpoints disabled, `set-breakpoint 1 PC=39914` is REJECTED with
        "Error. You must enable breakpoints first" and nothing is armed.
        ZEsarUX 12.1, which this harness was originally written against,
        accepted set-breakpoint in either order and additionally shipped
        index 1 pre-populated with a default condition; 13.0 starts with
        every index empty ("Disabled 1: None"). The old
        set-then-enable order therefore silently stopped arming anything
        when tools/DAAD-READY/TOOLS/zesarux was upgraded to 13.0.
        """
        reply = self.cmd("enable-breakpoints")
        check_error(reply)
        return reply

    def disable_breakpoints(self):
        return self.cmd("disable-breakpoints")

    def disable_breakpoint(self, index):
        """Disable ONE breakpoint index, leaving the breakpoint system
        itself on. Needed because `enable-breakpoints` is a global switch:
        turning it back on after a `disable-breakpoints` re-arms every
        index that still holds a condition, including ones a previous
        phase of the run set for its own purposes (nleg's RNG-seed trap at
        SEED_BP_INDEX is exactly that). Retiring the index is cheaper and
        clearer than overwriting its condition with something that can
        never match."""
        reply = self.cmd("disable-breakpoint %d" % index)
        check_error(reply)
        return reply

    def set_breakpoint_action(self, index, action):
        """Attach an ACTION to breakpoint `index` (the same index's
        condition fires it).

        Actions matter here for one blunt reason, confirmed live against
        ZEsarUX 13.0 with `--vo null`: the DEFAULT action ("menu"/"break")
        DOES NOT STOP a free-running emulator in this configuration. The
        emulator answers "Can not open menu: this video driver does not
        support menu." on every hit and keeps executing - the CPU never
        pauses, the ZRCP prompt never changes to "command@cpu-step> ", and
        nothing is observable. Only `run` inside cpu-step mode stops on a
        breakpoint (see run() above). A NON-menu action, however, does run
        on every hit while free-running - which is what makes an
        emulator-side capture (`save-binary`) possible without taking the
        turn loop into cpu-step. See nleg.NextLeg.arm_page_capture."""
        reply = self.cmd("set-breakpointaction %d %s" % (index, action))
        check_error(reply)
        return reply

    def evaluate(self, expr):
        """Evaluate a ZEsarUX debugger expression and return its reply.

        Used to read back a user variable (var0..var9) that a breakpoint
        action has been incrementing - ZRCP has no get-variable command,
        and get-breakpointspasscount is NOT a fire counter (confirmed
        live: it stays "0 0" across breakpoint hits, it reports the
        configured pass-count limit, not hits)."""
        return self.cmd("evaluate %s" % expr)

    def cpu_step(self):
        return self.cmd("cpu-step")

    def run(self, deadline=60.0):
        """Run at full (non-real-time) speed until an enabled breakpoint
        fires. Must only be called while in cpu-step mode (see
        enter_cpu_step); ZEsarUX's own help text is explicit that "run"
        does nothing useful outside that mode. `deadline` needs real
        headroom - full ZX Next boot plus NextZXOS's smartload of the game
        happens before NextDAAD's own code ever runs, all of which "run"
        now drives at full emulation speed rather than real time, but it
        is still real wall-clock work, not instant.
        """
        return self.cmd("run", deadline=deadline)

    def get_registers(self):
        return self.cmd("get-registers")

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def pc_breakpoint_condition(addr):
    """Format a ZRCP breakpoint condition matching an exact PC value. Pure
    string formatting, factored out so it can be pinned by a selftest that
    does not need a running emulator - see zrcp.help's own note that
    PC=XXXX conditions use ZEsarUX's fast breakpoint optimizer."""
    if addr < 0:
        raise ValueError("pc_breakpoint_condition: address must not be "
                         "negative (got %r)" % (addr,))
    return "PC=%d" % addr
