#!/usr/bin/env python3
"""The ZX leg: play a command script on the ORIGINAL DAAD ZX interpreter.

This is the harness's THIRD leg, and it is deliberately not shaped like
the other two. jleg.js and nleg.py form the two-leg differential that is
this project's day-to-day instrument: same DSF, both interpreters, STATE
and TEXT compared byte-exactly every turn. The ZX leg cannot join that
comparison as an equal - it has no state channel at all (see "WHAT THIS
LEG CANNOT DO" below) - so it exists for two narrower jobs:

  (a) shipped-game TEXT coverage. Run a corpus game on NextDAAD and on
      the original interpreter it reimplements, and compare what the two
      print. That is lineage evidence no amount of jDAAD agreement can
      give, because jDAAD is itself a reimplementation.
  (b) adjudication. When NextDAAD, jDAAD and msx2daad disagree about
      what DAAD does, the original settles it. SP16 Task 5 settled five
      register entries this way; this module is that rig, made
      repeatable.

WHAT THIS LEG CANNOT DO - state, and why.

No flags. No object locations. Not "not yet": there is nothing to read
them from. The other two legs know where the interpreter keeps its state
because they have symbols - nleg reads build/nextdaad.map (FLAGS =
0xA200, OBJTABLE, ...), jleg reaches into jDAAD's own JS objects. For the
original there is no map file, no source and no debug symbols: the
interpreter is a 6944-byte assembled blob
(tools/DAAD-READY/ASSETS/ZX/ZXSPECTRUM/DS48IE3.BIN) shipped by DAAD Ready
as a binary. Nor is one address good for all of them: DAAD Ready ships
SIX ZX variants (ZXSPECTRUM/48K, 128K, PLUS3, ESXDOS, ZXUNO, ZXNEXT),
each in an English and a Spanish build, all different sizes - 6944 bytes
for DS48IE3 up to 8231 for DSZXUNOS3 - so any flags address found by
inspection would be a per-binary constant with nothing to validate it
against, silently wrong the moment the variant or language changed. The
SP16 rig did NOT locate the flags block, and this module does not guess
at one. The CONSERVATIVE SUBSET is therefore: NOTHING. No state is
captured, the jsonl carries no "flags"/"objloc" keys at all (so feeding
it to compare.compare_runs raises loudly rather than comparing empty
arrays against real ones), and the only channel is TEXT.

The supported way to observe original-interpreter STATE is the one SP16
used: write a FIXTURE that prints the flags you care about, and read them
off the screen as text. zxadj.dsf's "V=33 N=34 ..." status line is
exactly that, and it is how D2, B21 and E4 were settled. Slower to author
than a memory read, but it is measuring the interpreter through its own
documented behaviour instead of through an address nobody can verify.

Two more things the leg cannot pin, both consequences of the same
missing symbols, both handled rather than ignored:

  * the RANDOM PROMPT. The original picks its input prompt from SM2..SM5
    (the SP16 transcript shows "What next?>" and "What now?>" on
    successive turns of the same run; Dracula showed three different
    ones in eight turns). nleg and jleg both force flag 42 to a fixed
    prompt; this leg cannot write flags, so instead the pending prompt
    MESSAGE and input ROW are excluded from the emitted text - neither is
    turn output anyway (see _emit_text, and trim_prompt_tail for the
    matching trim applied to the Next side of a ZX comparison).
  * the INPUT TIMEOUT. nleg zeroes inpTOFrames every poll; here there is
    nothing to zero. Scripts for this leg must not rely on a turn sitting
    at a prompt indefinitely if the game arms TIME.

HOW A TURN IS READ - screen decoding and settling.

Text comes from zscreen.py, which decodes the ULA bitmap directly
because ZEsarUX's get-ocr reads NOTHING from a DAAD ZX screen (measured
in SP16 T5; see zscreen's docstring). Readiness is a POSITIVE signal, not
a sleep: the DAAD ZX line editor draws its cursor "_" into the BITMAP
(not as a flashing attribute - confirmed live: 12 consecutive captures at
an idle prompt are byte-identical), so "the screen has stopped changing
AND the last line ends in the cursor" means the editor is waiting for a
line. Static with NO cursor is a pause the game is holding - a "More..."
page or an ANYKEY wait - which is captured and then dismissed with a
keypress, the same discipline nleg.settle uses.

A turn is additionally required to have CHANGED the screen at least once
before READY is accepted. Without that, settle() would return
immediately on the still-unprocessed pre-Enter screen (which also ends in
a cursor) and every turn would capture nothing.

Script format is the SHARED one - the same JSON array of strings jleg.js
and nleg.py consume, with the same three entry forms ("COMMAND", "!X",
"?X") and the same `pre`-anchoring rules, so one script file drives all
three legs.

BUILD CHAIN. build_tap() is the SP16 chain in code: DRF zx 48k (with
-force-normal-messages, which a 48K tape requires - it has nowhere to put
an XMB) + DRB + pager48k + daadmaker /48, all run by absolute path with
cwd in a work directory. Nothing is ever written into tools/. A prebuilt
TAP is accepted instead (--tap), so a shipped game with no source can
still be played.

CAVEAT worth stating once: the ZX leg compiles the 48K SUBTARGET while
the Next leg compiles `zx next`. DRF defines COLS from the subtarget, so
a game whose DSF branches on COLS (or on the target symbol) genuinely
runs different code on the two legs. That is a property of the game, not
a divergence - but read any COLS-conditional game's text differences with
it in mind.
"""
import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import zrcp
import zscreen

ROOT = Path(__file__).resolve().parent.parent.parent
DR = ROOT / "tools" / "DAAD-READY"
DRF = DR / "TOOLS" / "DRC" / "drf.exe"
DRB = DR / "TOOLS" / "DRC" / "drb.php"
PHP = DR / "PHP" / "PHP.exe"
PAGER48K = DR / "TOOLS" / "DRC" / "pager48k.php"
DAADMAKER = DR / "TOOLS" / "DRC" / "daadmaker.exe"
SDG = DR / "ASSETS" / "ZX" / "DAAD.SDG"
ZESARUX = DR / "TOOLS" / "zesarux" / "zesarux.exe"

# Only the 48K tape variant is implemented. The other five ZX variants
# DAAD Ready ships need a different packager (pager128k.php, a patched
# DAAD.SDG, a disk image for PLUS3) and a different ZEsarUX machine, and
# none of them would give a different ANSWER to the questions this leg is
# asked - the parser and condact code is the same DAAD source built for a
# different loader. Adding one is a day's work with no measurement behind
# it, so the map records what would be needed rather than guessing.
INTERPRETERS = {
    "48k": {
        "EN": DR / "ASSETS" / "ZX" / "ZXSPECTRUM" / "DS48IE3.BIN",
        "ES": DR / "ASSETS" / "ZX" / "ZXSPECTRUM" / "DS48IS3.BIN",
    },
}
MACHINE = "48k"

# ZRCP port for this leg. Deliberately NOT nleg's 10000: the --zx runner
# mode starts the ZX emulator after the Next one has exited, but a
# stale process from an interrupted run must not be silently adopted.
DEFAULT_PORT = 10010

SCREEN_ADDR = zscreen.SCREEN_ADDR
BITMAP_BYTES = zscreen.BITMAP_BYTES

SETTLE_POLL_S = 0.25
SETTLE_TIMEOUT_S = 45.0
BOOT_TIMEOUT_S = 90.0
# Consecutive identical captures before the screen counts as settled.
# At 0.25s + ~0.12s per 6144-byte read this is about 1.1s. Measured
# against Dracula's boot, which repaints every ~0.35s while printing.
READY_STATIC_POLLS = 3
# ...and how many before a settled screen with NO cursor is treated as a
# pause to dismiss. Larger than READY_STATIC_POLLS so a slow printer is
# never mistaken for a pause; larger again during boot, where a game can
# sit mid-intro for a while (nleg's BOOT_ANYKEY_STATIC_POLLS exists for
# the same reason).
PAUSE_STATIC_POLLS = 6
BOOT_PAUSE_STATIC_POLLS = 16
# Runaway guard: a game that reprints the same pause forever (or a
# keypress that never dismisses it) must fail loudly, not spin.
MAX_PAUSES_PER_TURN = 40

# Set true (zleg.DEBUG = True, or ZLEG_DEBUG=1 in the environment) to
# have settle() report every pause it dismisses. A dismissal is the one
# place this leg presses a key the script did not ask for, so it is the
# first thing to look at when a run desynchronises.
DEBUG = bool(os.environ.get("ZLEG_DEBUG"))

# The system messages DAAD picks its input prompt from when flag 42 is 0:
# SM2..SM5, chosen by frameCounter AND 3 (src/overlay1.asm:1597-1602 -
# "SM2..SM5 (animated cursor prompt)"). nleg and jleg both PIN this by
# writing flag 42; the ZX leg cannot write flags, so it recognises the
# four instead and drops the pending one from the turn's text. Measured
# on Dracula: three different prompts across eight turns of one run
# ("I await your command.", "Tell me what to do.", "I'm ready for your
# instructions.") - left in, that alone would diverge on most turns.
PROMPT_SM = (2, 3, 4, 5)
# SM32 is the "More..." pager prompt, SM33 the input row - "\r>" in
# Dracula, a bare ">" in the SP16 fixture, "#n>" in Rabenstein. Whatever
# leads it is a line break; what survives is the row the player types on.
MORE_SM = 32
INPUT_SM = 33


# ---- build ---------------------------------------------------------------

def _run(args, cwd):
    res = subprocess.run([str(a) for a in args], cwd=str(cwd),
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("%s failed (%d):\n%s\n%s"
                           % (args[0], res.returncode, res.stdout, res.stderr))
    return res.stdout


def tap_stem(dsf_path):
    """8.3-safe program name, derived from the source so a rebuild of the
    same fixture produces the same TAP bytes as the archived one."""
    return Path(dsf_path).stem[:8].upper()


def load_sysmess(json_path):
    """System messages, by index, out of DRF's own compiler output.

    DRF writes every message as plain text in the .json it hands to DRB,
    so the game's SM2..SM5 (prompts) and SM32 (pager) can be read
    straight from the build with no DDB text decompression and no second
    interpreter loaded to ask - which is what nleg has to do for the same
    string (see nleg.load_more_prompt's precondition that jleg.js ran
    first). Returns {} rather than raising if the file is not there: a
    prebuilt TAP legitimately has no json, and the caller can pass the
    strings itself.
    """
    p = Path(json_path)
    if not p.exists():
        return {}
    data = json.loads(p.read_text(encoding="utf-8", errors="replace"))
    out = {}
    for entry in data.get("sysmess") or ():
        try:
            out[int(entry["Value"])] = entry["Text"]
        except (KeyError, TypeError, ValueError):
            continue
    return out


def build_tap(dsf_path, workdir, lang="EN", variant="48k", charset=None):
    """Build a classic ZX TAP from a DSF - the SP16 chain, in a work dir.

    Returns {"tap", "ddb", "charset", "stem", "sysmess"}. Reproduces the
    archived SP16 artefacts byte for byte from the same DSF (verified:
    TAP sha256 7ef6e65a..., DDB 33cc27c8...), which is what makes the
    zxadj replay a regression test rather than a re-measurement.
    """
    workdir = Path(workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    if variant not in INTERPRETERS:
        raise ValueError("unsupported ZX variant %r - implemented: %s"
                         % (variant, ", ".join(sorted(INTERPRETERS))))
    interp = INTERPRETERS[variant].get(lang.upper())
    if interp is None:
        raise ValueError("no %s interpreter for language %r" % (variant, lang))

    stem = tap_stem(dsf_path)
    src = workdir / (stem + ".DSF")
    if Path(dsf_path).resolve() != src:
        shutil.copyfile(dsf_path, src)
    chrfile = zscreen.resolve_charset(dsf_path, charset)

    for stale in (stem + ".TAP", stem + ".DDB", stem + ".json",
                  "INDEX.BIN", "PAGE0.TMP"):
        p = workdir / stale
        if p.exists():
            p.unlink()

    # -force-normal-messages: a 48K TAP has nowhere to put an XMB file,
    # and the DRC chain refuses the build if one is produced (ZX48.BAT
    # makes the same check). No -v3: the whole harness compares DAAD
    # version 2 databases (see prepare.py).
    _run([DRF, "zx", "48k", src.name, stem + ".json",
          "-force-normal-messages"], workdir)
    _run([PHP, DRB, "zx", "48k", lang.upper(), stem + ".json",
          stem + ".DDB"], workdir)
    ddb = workdir / (stem + ".DDB")
    if not ddb.exists():
        raise RuntimeError("DRB did not produce %s" % ddb)

    images = workdir / "IMAGES"
    images.mkdir(exist_ok=True)
    _run([PHP, PAGER48K, ddb], images)
    for name in ("INDEX.BIN", "PAGE0.TMP"):
        produced = images / name
        if produced.exists():
            shutil.move(str(produced), str(workdir / name))
    index = workdir / "INDEX.BIN"
    if not index.exists():
        raise RuntimeError("pager48k did not produce %s" % index)

    shutil.copyfile(SDG, workdir / "DAAD.SDG")
    _run([DAADMAKER, stem + ".TAP", interp, stem + ".DDB", chrfile,
          "INDEX.BIN", "DAAD.SDG", "/48"], workdir)
    tap = workdir / (stem + ".TAP")
    if not tap.exists():
        raise RuntimeError("daadmaker did not produce %s" % tap)
    return {"tap": tap, "ddb": ddb, "charset": chrfile, "stem": stem,
            "sysmess": load_sysmess(workdir / (stem + ".json"))}


# ---- emulator ------------------------------------------------------------

def launch(tap, port):
    args = [str(ZESARUX), "--noconfigfile", "--machine", MACHINE,
            "--realvideo", "--fastautoload", "--vo", "null", "--ao", "null",
            "--nosplash", "--nowelcomemessage", "--quickexit",
            "--forceconfirmyes", "--enable-remoteprotocol",
            "--remoteprotocol-port", str(port), str(Path(tap).resolve())]
    return subprocess.Popen(args, cwd=str(Path(tap).resolve().parent),
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def port_already_listening(port):
    s = socket.socket()
    s.settimeout(0.4)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def wait_for_port(proc, port, attempts=80, delay=0.5):
    for _ in range(attempts):
        if proc.poll() is not None:
            raise RuntimeError("zesarux exited rc=%s before opening ZRCP"
                               % proc.returncode)
        try:
            return zrcp.Zrcp(port=port)
        except OSError:
            time.sleep(delay)
    raise RuntimeError("ZRCP port %d never opened" % port)


# ---- the leg -------------------------------------------------------------

class ZxLeg:
    def __init__(self, z, table):
        self.z = z
        self.table = table

    def raw_screen(self):
        return self.z.read_memory(SCREEN_ADDR, BITMAP_BYTES)

    def screen(self, px=None):
        return zscreen.decode(px if px is not None else self.raw_screen(),
                              self.table)

    def settle(self, pages, baseline=None, boot=False):
        """Poll until the line editor is ready, dismissing pauses.

        `baseline` is the raw screen as it stood when the turn's keys
        went out. NOTHING is believed until the screen has left it: a
        capture identical to the baseline is the turn not having landed
        yet, whatever it looks like. That distinction is not academic -
        it was a real, measured desynchronisation. The first version of
        this loop tracked "has any poll differed from the previous poll",
        which is False for a turn whose output is complete before the
        FIRST poll (fast Z80 work against a 0.25s poll: Dracula's
        "LOOK DESK" does it). The ready screen then failed the change
        test, fell through to the pause branch, and the leg pressed Enter
        at an idle prompt - submitting an empty command into the game and
        shifting every later turn's response by one. Three of eight turns
        of the Dracula demo diverged, from nothing but that.

        Returns True if at least one no-cursor pause was dismissed this
        turn (the caller records it against the turn, exactly as nleg
        records its anykey_heuristic - a page dismissed by the harness is
        a turn whose text capture deserves a second look).

        Raises TimeoutError naming what it last saw, including whether
        the screen ever moved off the baseline at all - a turn whose keys
        never reached the interpreter and a turn stuck mid-print are
        different failures and must not report the same way. A quiet
        give-up here would hand the comparison a truncated capture that
        reads as a game divergence instead of a harness failure.
        """
        limit = BOOT_TIMEOUT_S if boot else SETTLE_TIMEOUT_S
        pause_polls = BOOT_PAUSE_STATIC_POLLS if boot else PAUSE_STATIC_POLLS
        deadline = time.time() + limit
        last = None
        static = 0
        moved = False
        dismissed = False
        pauses = 0
        while time.time() < deadline:
            px = self.raw_screen()
            if px == last:
                static += 1
            else:
                static = 0
                last = px
            if baseline is None or px != baseline:
                moved = True
            if moved and static >= READY_STATIC_POLLS:
                lines = zscreen.decode(px, self.table)
                if has_cursor(lines):
                    return dismissed            # READY - press nothing.
                if static >= pause_polls:
                    # Settled with no cursor: a "More..." page or an
                    # ANYKEY hold. Capture it BEFORE dismissing or the
                    # text scrolls away and is lost forever.
                    pauses += 1
                    if DEBUG:
                        print("zleg: pause %d, dismissing - %r"
                              % (pauses, lines[-3:]))
                    if pauses > MAX_PAUSES_PER_TURN:
                        raise TimeoutError(
                            "dismissed %d pauses on one turn without "
                            "reaching a prompt - last screen: %r"
                            % (pauses - 1, lines[-3:]))
                    pages.append(lines)
                    self.z.enter(wait=0.3)
                    dismissed = True
                    static = 0
                    last = None
                    continue
            time.sleep(SETTLE_POLL_S)
        raise TimeoutError(
            "ZX interpreter did not reach a ready prompt within %.0fs - "
            "%s, screen %s for the last %d poll(s), last lines %r"
            % (limit,
               "the screen never changed from what it was when the keys "
               "went out (did they reach the interpreter?)" if not moved
               else "the screen did change after the keys went out",
               "static" if static else "changing", static,
               (zscreen.decode(last, self.table)[-3:] if last else [])))


def has_cursor(lines):
    """True when the decoded screen's last line ends in the editor cursor.

    The DAAD ZX line editor draws "_" into the bitmap at the caret. It
    does not blink there (the ULA FLASH bit lives in the attribute file,
    which this leg never reads), so an idle prompt is a bit-identical
    screen with a cursor on the end - a positive "waiting for a line"
    read rather than an inference from silence.

    The converse is a HEURISTIC and has a cost worth naming: a game that
    legitimately holds a cursorless screen for longer than
    PAUSE_STATIC_POLLS x SETTLE_POLL_S (about 2.2s) mid-turn will be
    treated as paused and receive a keypress the script did not ask for.
    Turns where that happened are marked pages_dismissed in the jsonl,
    and ZLEG_DEBUG=1 prints each one.
    """
    return bool(lines) and lines[-1].endswith(zscreen.CURSOR)


def strip_cursor(lines):
    """Drop the trailing cursor character from the last line, if any."""
    if has_cursor(lines):
        return list(lines[:-1]) + [lines[-1][:-len(zscreen.CURSOR)]]
    return list(lines)


def drop_pager_prompt(lines, prompt):
    """Remove the game's own SM32 pager prompt row from a captured page.

    REMOVED, not blanked - the opposite of nleg.blank_prompt_rows, and
    for the same underlying reason. nleg compares fixed-index tilemap
    rows, where deleting a row would shift everything below it and turn a
    clean scroll into an unexplainable transition. zscreen's captures are
    variable-length line LISTS matched by scrolling (zscreen.scroll_shift),
    and the pager prompt is a row the interpreter erases itself the moment
    the page is dismissed - so leaving it in is what breaks the match:
    the next capture does not contain it, no shift explains the
    transition, and the whole screen gets re-emitted as new text.
    """
    if not prompt:
        return list(lines)
    return [l for l in lines if l.strip() != prompt.strip()]


def _norm(text):
    return " ".join(text.split())


def _drop_pending_prompt(out, prompts):
    """Drop the prompt MESSAGE the interpreter just printed for the next
    turn, from the tail of this turn's text.

    Two trailing lines are considered, not one, because a prompt message
    longer than the 42-column window wraps. Nothing else in the turn is
    searched: a prompt message can only be the LAST thing printed before
    the input row, so a line matching one anywhere earlier is the game's
    own prose and stays.
    """
    if not prompts:
        return out
    for take in (1, 2):
        if len(out) >= take and _norm(" ".join(out[-take:])) in prompts:
            return out[:-take]
    return out


def command_plan(cmd):
    """How one script entry is realised on this leg: (anchor, keys, enter).

    The script format is SHARED with jleg.js and nleg.py - a JSON array
    of strings, three entry forms - and this is the ZX leg's half of that
    contract, kept as a pure function so parser_selftest can pin it
    without an emulator.

      "COMMAND"  type it, anchor `pre` AFTER the echo, press Enter.
      "!X"       type each character separately, NO Enter, anchor BEFORE
                 (a raw key read echoes nothing).
      "?X"       answer a confirmation: the reply plus Enter, anchored
                 BEFORE, so the one echoed character lands inside the
                 turn's text.

    The anchors match nleg.play's exactly - see the long comment there
    for why each one is where it is. A script that means one thing on the
    Next leg must mean the same thing here or the two are not comparable.
    """
    if cmd.startswith("!"):
        return "before", list(cmd[1:]), False
    if cmd.startswith("?"):
        return "before", [cmd[1:]], True
    return "after", [cmd], True


def play_charset(explicit=None, built=None, tap=None):
    """Which .CHR to DECODE with: explicit > as-built > beside the TAP.

    The as-built charset is the one that matters and it is why this
    function exists. build_tap resolves the font against the DSF's own
    directory and hands it to daadmaker, so a game shipping its own
    6-pixel font is BUILT with it - but the TAP it produces lands in a
    work directory that contains no .CHR at all, so re-resolving against
    the TAP would silently fall back to the stock AD8x6.CHR and decode
    every redefined glyph wrongly. That is a silent mis-read surfacing as
    text divergences, precisely the failure zscreen.resolve_charset
    exists to prevent, and the first version of this leg had it: play()
    re-resolved and the caller's built["charset"] was dropped on the
    floor. Both call sites now go through here.
    """
    if explicit:
        return Path(explicit)
    if built:
        return Path(built)
    return zscreen.resolve_charset(tap)


def prompt_set(sysmess):
    """The game's SM2..SM5 prompt texts, whitespace-normalised."""
    sysmess = sysmess or {}
    return {_norm(sysmess[i]) for i in PROMPT_SM
            if sysmess.get(i) and sysmess[i].strip()}


def input_row_text(sysmess):
    """The printable part of SM33 - the row the player types on."""
    raw = (sysmess or {}).get(INPUT_SM) or ""
    for brk in ("\r", "\n", "#n", "#N"):
        raw = raw.replace(brk, "\x00")
    return _norm(raw.split("\x00")[-1])


def trim_prompt_tail(text, sysmess):
    """Remove a leg's pending input row and prompt message from its text.

    Applied to the NEXTDAAD side of a ZX comparison, and ONLY there. The
    ZX leg drops both from its own captures because it cannot pin which
    prompt the original will pick (PROMPT_SM); NextDAAD's tilemap capture
    keeps them, since flag 42 makes its choice deterministic and the
    jDAAD differential wants every printed row compared. Trimming the
    Next side here puts the two on the same footing for this one
    comparison without touching what either leg recorded, and without
    going anywhere near the two-leg path.
    """
    lines = text.splitlines()
    row = input_row_text(sysmess)
    if row and lines and _norm(lines[-1]) == row:
        lines.pop()
    lines = _drop_pending_prompt(lines, prompt_set(sysmess))
    return "\n".join(lines)


def _emit_text(pre, captures, had_cursor, prompts=()):
    """New text across a turn: (lines, redraw_flag).

    `pre` and each capture are cursor-stripped first, so the row the
    player typed into matches whatever the interpreter leaves on screen
    afterwards. Two things are then dropped from the TAIL of the result,
    and only from the tail:

      * the PENDING INPUT ROW (DAAD's SM33, "#n>"), which is the next
        turn's input line rather than this turn's output;
      * the PENDING PROMPT MESSAGE (one of SM2..SM5), which the original
        picks at random per turn and this leg cannot pin the way the
        other two legs do - see PROMPT_SM.

    Neither is dropped from `pre`, deliberately. Both stay on screen as
    history and reappear in the next capture, so removing them from the
    "before" picture would make the scroll match fail and re-emit them as
    new text - the exact opposite of the intent.
    """
    prev = strip_cursor(pre)
    out = []
    redraw = False
    for cap in captures:
        cur = strip_cursor(cap)
        lines, r = zscreen.new_text(prev, cur)
        out.extend(lines)
        redraw = redraw or r
        prev = cur
    if had_cursor and out and prev and out[-1] == prev[-1]:
        out.pop()
    if had_cursor:
        out = _drop_pending_prompt(out, prompts)
    return out, redraw


def play(script_path, out_path, tap=None, port=DEFAULT_PORT,
         charset=None, more_prompt=None, sysmess=None, verbose=False):
    """Play `script_path` on the original interpreter, write jsonl.

    `tap` is the TAP to boot - build_tap's output, or a prebuilt one for
    a shipped game with no source. Required, and there is deliberately no
    "find one in the work directory" fallback: picking a TAP up by
    guesswork is how a run ends up playing the previous game's build.

    `charset` is the .CHR to DECODE with, and callers holding a
    build_tap result must pass its "charset" through (via play_charset,
    which both call sites use) - see that function for what goes wrong
    otherwise.

    `sysmess` is the game's system-message table (build_tap returns one;
    load_sysmess reads one from a DRF json). It supplies the prompt
    messages and, unless `more_prompt` says otherwise, the pager prompt.
    Without it the leg still runs - it just emits the random prompt line
    on every turn and leaves "More..." on captured pages.

    The jsonl carries NO flags/objloc keys - see the module docstring.
    compare.compare_runs_text() is the comparison built for it.

    THE JSONL IS NOT HASH-STABLE, and it is not meant to be. "screen"
    and "screen_sha" record the final screen verbatim, which includes
    whichever of SM2..SM5 the original picked for the next prompt - a
    per-turn coin toss this leg cannot pin (PROMPT_SM). Two correct runs
    of the same script routinely differ there. The "text" field is the
    comparable channel: the pending prompt is trimmed out of it, and it
    is what compare_runs_text reads. Do not gate anything on a hash of
    this file; compare texts, or the screen of a fixture that prints its
    own state.
    """
    commands = json.loads(Path(script_path).read_text(encoding="utf-8"))
    if not tap:
        raise ValueError("zleg.play needs a TAP - build one with build_tap()")
    tap = Path(tap).resolve()
    table = zscreen.load_font(play_charset(charset, tap=tap))
    sysmess = sysmess or {}
    prompts = prompt_set(sysmess)
    if more_prompt is None:
        more_prompt = sysmess.get(MORE_SM)

    if port_already_listening(port):
        raise RuntimeError(
            "port %d is already accepting connections BEFORE we launched "
            "anything - a stale ZEsarUX is probably still bound to it. "
            "Kill it, or pass a free --port; attaching to the wrong "
            "emulator would make every result garbage." % port)

    proc = launch(tap, port)
    try:
        z = wait_for_port(proc, port)
        try:
            leg = ZxLeg(z, table)
            boot_pages = []
            leg.settle(boot_pages, boot=True)
            post = leg.screen()
            if verbose:
                print("zleg: booted, %d line(s) on screen" % len(post))

            with open(out_path, "w", encoding="utf-8") as fh:
                for i, cmd in enumerate(commands):
                    pages = []
                    anchor, keys, press_enter = command_plan(cmd)
                    pre_raw = leg.raw_screen() if anchor == "before" else None
                    for k in keys:
                        z.send_keys(k)
                    if anchor == "after":
                        pre_raw = leg.raw_screen()
                    if press_enter:
                        z.enter()
                    pre = zscreen.decode(pre_raw, table)
                    # `pre_raw` is also the settle baseline: the turn has
                    # not landed until the screen leaves it. See settle().
                    dismissed = leg.settle(pages, baseline=pre_raw)
                    raw_post = leg.raw_screen()
                    post = zscreen.decode(raw_post, table)

                    pages = [drop_pager_prompt(p, more_prompt) for p in pages]
                    text, redraw = _emit_text(pre, pages + [post],
                                              has_cursor(post), prompts)
                    fh.write(json.dumps({
                        "turn": i,
                        "command": cmd,
                        "text": "\n".join(text),
                        "leg": "zx",
                        "state_capture": False,
                        "text_redraw": redraw,
                        "pages_dismissed": dismissed,
                        "screen": post,
                        "screen_sha": hashlib.sha256(raw_post).hexdigest()[:16],
                    }) + "\n")
                    if verbose:
                        print("zleg turn %-3d %-24s %d line(s)%s"
                              % (i, cmd, len(text),
                                 " [redraw]" if redraw else ""))
        finally:
            z.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


# ---- text differential reporting ----------------------------------------

def write_text_report(divergences, ref_name, cmp_name, md_path, json_path,
                      turns=0):
    """Write the ZX text differential's own report.

    Deliberately NOT routed through report.py. That module's findings are
    built around a STATE channel - condact suspects narrowed by flag
    diffs, handler pointers from the symbol table - and none of it applies
    to a leg with no state. A short, honest markdown table beats a report
    whose empty flag columns imply the leg looked and found nothing.
    """
    md = ["# ZX text differential", "",
          "%s (reference) vs %s" % (ref_name, cmp_name), "",
          "TEXT channel only - the ZX leg captures no flags or object",
          "locations (tests/parser/zleg.py explains why).", "",
          "%d turn(s) compared, %d divergence(s)."
          % (turns, len(divergences)), ""]
    for d in divergences:
        md.append("## turn %d - `%s` (%s)"
                  % (d["turn"], d["command"], d.get("text_rank") or d["class"]))
        md.append("")
        md.append("%s:" % ref_name)
        md.append("```")
        md.append(d["text_ref"] or "(nothing)")
        md.append("```")
        md.append("%s:" % cmp_name)
        md.append("```")
        md.append(d["text_nd"] or "(nothing)")
        md.append("```")
        md.append("")
    Path(md_path).write_text("\n".join(md), encoding="utf-8")
    Path(json_path).write_text(json.dumps(divergences, indent=1),
                               encoding="utf-8")


# ---- CLI -----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Play a command script on the original DAAD ZX "
                    "interpreter under ZEsarUX (headless) and write a "
                    "per-turn jsonl transcript.")
    ap.add_argument("script", help="path to a JSON command script")
    ap.add_argument("out", help="path to write the jsonl transcript to")
    ap.add_argument("--dsf", help="game source to build a TAP from")
    ap.add_argument("--tap", help="prebuilt TAP to play instead")
    ap.add_argument("--work", default=None,
                    help="work directory (default work/zx-<script stem>)")
    ap.add_argument("--charset", default=None,
                    help="AD8x6-format .CHR to decode with (default: the "
                         "game's own, else the DAAD Ready stock font)")
    ap.add_argument("--lang", default="EN")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--more-prompt", default=None,
                    help="the game's SM32 pager prompt, dropped from "
                         "captured pages")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not args.dsf and not args.tap:
        ap.error("one of --dsf or --tap is required")
    work = Path(args.work) if args.work else (
        ROOT / "tests" / "parser" / "work"
        / ("zx-" + Path(args.script).stem))
    work.mkdir(parents=True, exist_ok=True)

    tap = args.tap
    built_charset = None
    if not tap:
        built = build_tap(args.dsf, work, lang=args.lang,
                          charset=args.charset)
        tap = built["tap"]
        sysmess = built["sysmess"]
        # The font the TAP was BUILT with decodes it - never re-resolve
        # against the work directory, which holds no .CHR. See
        # play_charset.
        built_charset = built["charset"]
        if not args.quiet:
            print("zleg: built %s (%d bytes) with %s"
                  % (tap.name, tap.stat().st_size, built["charset"].name))
    else:
        # A prebuilt TAP has no compiler output to read the system
        # messages from unless the DRF json happens to sit beside it.
        sysmess = load_sysmess(Path(tap).with_suffix(".json"))
        if not sysmess and not args.quiet:
            print("zleg: no sysmess for %s - the random prompt line will "
                  "be left in the text" % Path(tap).name)
    play(args.script, args.out, tap=tap, port=args.port,
         charset=play_charset(args.charset, built_charset, tap),
         more_prompt=args.more_prompt,
         sysmess=sysmess, verbose=not args.quiet)
    if not args.quiet:
        print("zleg: wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
