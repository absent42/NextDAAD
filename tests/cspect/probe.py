"""CSpect MCP capability probe: one launch per key (stages the sd\\ legs it names, runs each on
a copy under tests/out/cspect-probe/cards/); results to tests/out/cspect-probe/probe.json and
probe.md, one log per key. python tests/cspect/probe.py [--only KEY,...] [--no-stage]"""
import argparse
import base64
import ctypes
import io
import json
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from ctypes import wintypes
from pathlib import Path

HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))
sys.path.insert(0, str(TESTS / "parser"))

from cspect import client, launcher  # noqa: E402
import tilemap  # noqa: E402

OUT = ROOT / "tests" / "out" / "cspect-probe"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
SD = ROOT / "sd"
TM_MAP = 0x6000
KEYS = ("tools", "paused_start", "keys", "ay_readback", "esxdos", "type_text_freerun",
        "screenshot_freerun")
RNG_SEED = 0xA5C3            # tests/parser/nleg.py RNG_SEED
AY_SNAP = 0x4000             # AUD_STAGE0 EQU; the map's AUD_DBG_SNAP twin is the routine
AY_SNAP_LEN = 203            # AUD_DBG_LEN
AY_MASK = (0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F)

# card name -> (sd leg, staging command, staged-variant check or None)
STAGING = {
    "SUITE": ("SUITE", ["pwsh", "-NoProfile", "-File", "tests/build-tests.ps1", "-Suite"], None),
    "AYSREG": ("AYSREG", ["pwsh", "-NoProfile", "-File", "tests/build-tests.ps1", "-AysReg"], None),
    "LEGPC": ("LEGPC", [sys.executable, "tests/poolc/stage_poolc.py", str(NEX), str(NEX)], None),
    "XBNTRANS": ("XBN", ["pwsh", "-NoProfile", "-File", "tests/build-tests.ps1", "-Xbn", "-XbnTrans"],
                 ROOT / "tests" / "out" / "xbn" / "TRANS.XBN"),
    "XBNFIX": ("XBN", ["pwsh", "-NoProfile", "-File", "tests/build-tests.ps1", "-Xbn"],
               ROOT / "tests" / "out" / "xbn" / "GAME.XBN"),
    "TEMPLATE": ("TEMPLATE", None, None),       # not restaged: the default leg, read only
}
NO_STAGE = False
STAGED = set()

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.OpenProcess.restype = wintypes.HANDLE
_k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
_k32.WaitForSingleObject.restype = wintypes.DWORD
_k32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
_k32.TerminateProcess.restype = wintypes.BOOL
_k32.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
_k32.CloseHandle.restype = wintypes.BOOL
_k32.CloseHandle.argtypes = (wintypes.HANDLE,)

PIDS = []                    # (pid, process handle) for every CSpect this run started


class Fail(Exception):
    pass


class Log:
    """Per-key transcript: every MCP call with its arguments and reply text."""

    def __init__(self, key):
        OUT.mkdir(parents=True, exist_ok=True)
        self.path = OUT / f"{key}.log"
        self.f = open(self.path, "w", encoding="utf-8")
        self.t0 = time.monotonic()

    def __call__(self, msg):
        self.f.write(f"[{time.monotonic() - self.t0:8.3f}] {msg}\n")
        self.f.flush()

    def close(self):
        self.f.close()


class LMcp(client.Mcp):
    """Mcp that logs every tools/call; quiet() skips the log for polling."""

    def __init__(self, port, log, session=None):
        super().__init__(port)
        self.log, self.session = log, session

    def call(self, tool, **args):
        shown = {k: (v if not isinstance(v, str) or len(v) < 100 else v[:100] + "...")
                 for k, v in args.items()}
        try:
            res = super().call(tool, **args)
        except client.CSpectError as e:
            self.log(f"CALL {tool} {json.dumps(shown)} -> ERROR {e}")
            raise
        kinds = sorted({c.get("type") for c in res.get("content", [])})
        self.log(f"CALL {tool} {json.dumps(shown)} -> {kinds} {self.text(res)[:600]!r}")
        return res

    def quiet(self, tool, **args):
        return client.Mcp.call(self, tool, **args)


def card(log, name):
    """A fresh copy of the staged leg for card name, under OUT/cards (staged once per run)."""
    leg, cmd, variant = STAGING[name]
    src, dest = SD / leg, OUT / "cards" / name
    if cmd and not NO_STAGE and name not in STAGED:
        log(f"stage: {subprocess.list2cmdline(cmd)}")
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        log("stage output (tail):\n" + "\n".join((r.stdout + r.stderr).splitlines()[-12:]))
        if r.returncode != 0:
            raise Fail(f"staging {name} failed (exit {r.returncode}); see {rel(log.path)}")
        STAGED.add(name)
    elif variant is not None and not ((src / "GAME.XBN").is_file() and
                                      (src / "GAME.XBN").read_bytes() == variant.read_bytes()):
        if dest.is_dir():
            log(f"sd\\{leg} is not the {name} variant; reusing the earlier copy {dest}")
            for f in ("TRANS.TXT", "PROBE.SAV"):
                (dest / f).unlink(missing_ok=True)
            return dest
        raise Fail(f"sd\\{leg} does not hold the {name} variant and there is no earlier card copy")
    if not (src / "GAME.DDB").is_file():
        raise Fail(f"sd\\{leg}\\GAME.DDB missing - stage the leg first")
    if dest.is_dir():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)
    log(f"card {dest} <- {src}: {sorted(f.name for f in dest.iterdir())}")
    return dest


class Probe:
    """One launch: logged Mcp, symbols, screen and wait helpers. A context manager."""

    def __init__(self, key, cardpath, log, *, freerun=True, extra=()):
        self.key, self.card, self.freerun, self.extra = key, Path(cardpath), freerun, tuple(extra)
        self.log = log
        self.sym = client.read_map(MAP)
        self.inst = None

    def __enter__(self):
        self.log(f"launch card={self.card} freerun={self.freerun} extra={list(self.extra)}")
        self.inst = launcher.launch(self.card, NEX, MAP, freerun=self.freerun, extra=self.extra)
        h = _k32.OpenProcess(0x00101001, False, self.inst.pid)  # SYNCHRONIZE|QUERY_LIMITED|TERMINATE
        PIDS.append((self.inst.pid, h))
        self.log(f"pid {self.inst.pid} port {self.inst.port} exe_dir {self.inst.exe_dir}")
        self.m = LMcp(self.inst.port, self.log, self.inst.mcp.session)
        return self

    def __exit__(self, *exc):
        pid = self.inst.pid
        self.inst.close()
        self.log(f"closed pid {pid}")

    def conn(self):
        """A second MCP session to the same CSpect (calls on it run while another call blocks)."""
        m = client.Mcp(self.inst.port)
        m.initialize()
        return m

    def addr(self, name):
        return self.sym[name.upper()][0]

    def rd(self, addr, n, physical=False):
        out = bytearray()
        while len(out) < n:
            k = min(4096, n - len(out))
            a = addr + len(out)
            res = self.m.quiet("read_memory", address=f"${a:X}", length=k, physical=physical)
            out += client.parse_dump(self.m.text(res), a, k)
        return bytes(out)

    def flag(self, n):
        return self.rd(self.addr("FLAGS") + n, 1)[0]

    def rows(self):
        return tilemap.decode(self.rd(TM_MAP, tilemap.GRID_BYTES))[0]

    def screen(self, rows=None):
        return [f"{i:02d}|{r.rstrip()}" for i, r in enumerate(rows or self.rows()) if r.strip()]

    def frame(self):
        b = self.rd(self.addr("FRAMECOUNTER"), 2)
        return b[0] | b[1] << 8

    def port(self, port):
        t = self.m.text(self.m.call("port_in", port=port))
        mm = re.search(r"= \$([0-9A-Fa-f]{2})\b", t)
        if not mm:
            raise Fail(f"port_in {port} reply has no '= $xx': {t!r}")
        return int(mm.group(1), 16)

    def portq(self, port):
        t = self.m.text(self.m.quiet("port_in", port=port))
        return int(re.search(r"= \$([0-9A-Fa-f]{2})\b", t).group(1), 16)

    def wait(self, cond, seconds, what, poll=0.05):
        end = time.monotonic() + seconds
        while True:
            v = cond()
            if v:
                return v
            if time.monotonic() >= end:
                raise Fail(f"timed out after {seconds:g} s waiting for {what}")
            time.sleep(poll)

    def wait_text(self, text, seconds):
        return self.wait(lambda: (lambda r: r if any(text in x for x in r) else None)(self.rows()),
                         seconds, repr(text))

    def frames(self, n, seconds=30):
        """Return once NextDAAD's 16-bit frame counter has advanced n frames."""
        last, seen = self.frame(), 0
        end = time.monotonic() + seconds
        while seen < n:
            if time.monotonic() >= end:
                raise Fail(f"frame counter advanced {seen} of {n} frames in {seconds:g} s")
            time.sleep(0.005)
            f = self.frame()
            seen += (f - last) & 0xFFFF
            last = f

    def settle(self, frames=10, seconds=20):
        """Tilemap rows once two reads `frames` frames apart agree."""
        prev, end = self.rows(), time.monotonic() + seconds
        while True:
            self.frames(frames)
            cur = self.rows()
            if cur == prev:
                return cur
            if time.monotonic() >= end:
                raise Fail(f"screen still changing after {seconds:g} s")
            prev = cur

    def show(self, label, rows=None):
        self.log(f"screen {label}:\n" + "\n".join(self.screen(rows)))


def last_line(rows):
    lines = [r.rstrip() for r in rows if r.strip()]
    return lines[-1] if lines else ""


def at_prompt(rows):
    return last_line(rows).endswith(">")


def asciiz(b):
    return b.split(b"\0")[0]


def hold_sampled(p, keys, frames, sample):
    """press_keys(keys, hold_frames=frames) on a second session; sample() polled on the main
    session meanwhile. Returns (reply, seconds, samples during, sample after)."""
    m2, out = p.conn(), {}

    def run():
        t = time.monotonic()
        try:
            out["reply"] = m2.text(m2.call("press_keys", keys=keys, hold_frames=frames, gap_frames=1))
        except Exception as e:                                # noqa: BLE001 - reported, not hidden
            out["reply"] = f"ERROR {e}"
        out["dt"] = time.monotonic() - t

    th = threading.Thread(target=run)
    th.start()
    samples = []
    while th.is_alive():
        samples.append(sample())
    th.join()
    p.frames(3)
    after = sample()
    p.log(f"CALL press_keys {json.dumps({'keys': keys, 'hold_frames': frames, 'gap_frames': 1})} "
          f"(second session) -> {out.get('reply')!r} in {out.get('dt', 0):.2f} s; "
          f"{len(samples)} samples during, after={after}")
    return out.get("reply", ""), out.get("dt", 0.0), samples, after


def result(ok, how, evidence):
    return {"ok": bool(ok), "how": how, "evidence": evidence}


def rel(p):
    return str(Path(p).resolve().relative_to(ROOT)).replace("\\", "/")


def status_regs(text):
    m = re.search(r"PC \$([0-9A-F]{4})", text)
    regs = dict(re.findall(r"\b(AF|BC|DE|HL|IX|IY|SP) \$([0-9A-F]{4})", text))
    return (int(m.group(1), 16) if m else None), {k: int(v, 16) for k, v in regs.items()}


# -- tools -----------------------------------------------------------------------------------------

def p_tools(log):
    c = card(log, "TEMPLATE")
    with Probe("tools", c, log) as p:
        tools = p.m.tools()
        rpc = p.m.rpc("tools/list")
    path = OUT / "tools.json"
    path.write_text(json.dumps(rpc, indent=1), encoding="utf-8")
    names = [t["name"] for t in tools]
    missing = [t for t in launcher.REQUIRED_TOOLS if t not in names]
    props = {t["name"]: list(t["inputSchema"].get("properties", {})) for t in tools}
    how = (f"tools/list, one page, {len(names)} tools: {', '.join(names)}. Arguments: "
           + "; ".join(f"{n} {props[n]}" for n in ("press_keys", "type_text", "port_in", "port_out",
                                                   "debug_command", "set_registers", "screenshot"))
           + ". press_keys items are 'A+B' (held together) separated by spaces or commas; "
           "type_text newline = ENTER")
    if missing:
        how += f"; MISSING required: {missing}"
    return result(not missing, how, f"{rel(path)} (full reply with input schemas); {rel(log.path)}")


# -- paused_start ----------------------------------------------------------------------------------

def seed_at_stop(p, form):
    """Stopped at SEEDOK: RNGSTATE must not yet hold HL; poison it, HL := RNG_SEED, step once."""
    seed, rngs = p.addr("ENG_INIT_GAME@SEEDOK"), p.addr("RNGSTATE")
    st = p.m.text(p.m.call("get_status"))
    pc, regs = status_regs(st)
    if "stopped" not in st or pc != seed:
        raise Fail(f"{form}: not stopped at SEEDOK ${seed:04X}: {st.splitlines()[:2]}")
    pre = int.from_bytes(p.rd(rngs, 2), "little")
    hl = regs["HL"]
    if pre == hl:
        raise Fail(f"{form}: RNGSTATE ${pre:04X} already equals HL - cannot tell it is unwritten")
    p.m.call("write_memory", address=f"${rngs:X}", data="0000")
    p.m.call("set_registers", registers={"HL": f"${RNG_SEED:04X}"})
    stepped = p.m.text(p.m.call("step"))
    pc2, _ = status_regs(stepped)
    got = int.from_bytes(p.rd(rngs, 2), "little")
    ok = got == RNG_SEED and pc2 == seed + 3
    return ok, (f"stopped at PC ${pc:04X} with HL ${hl:04X} (entropy) and RNGSTATE ${pre:04X} (image "
                f"value, not HL: unwritten); poisoned RNGSTATE to $0000; HL := ${RNG_SEED:04X}; one "
                f"step -> PC ${pc2:04X}, RNGSTATE ${got:04X}")


def game_runs(p, text="01 OK"):
    p.m.call("clear_breakpoint", all=True)
    p.m.call("run")
    p.wait_text(text, 30)
    return f"after clear_breakpoint all + run, '{text}' appeared"


def p_paused_start(log):
    c = card(log, "SUITE")
    seed = client.read_map(MAP)["ENG_INIT_GAME@SEEDOK"][0]
    parts, oks = [], []
    try:
        with Probe("paused_start", c, log, extra=(f"+brk=${seed:04X}",)) as p:
            p.m.call("wait_for_stop", timeout_ms=10000)
            ok, msg = seed_at_stop(p, "+brk")
            msg += "; " + game_runs(p)
        parts.append(f"+brk=${seed:04X} (launch extra): {'WORKS' if ok else 'FAILS'} - {msg}")
        oks.append(ok)
    except Exception as e:                                    # noqa: BLE001 - recorded per form
        log("+brk form raised:\n" + traceback.format_exc())
        parts.append(f"+brk=${seed:04X}: FAILS - {type(e).__name__}: {e}")
        oks.append(False)
    try:
        with Probe("paused_start", c, log, extra=("-debug",)) as p:
            st = p.m.text(p.m.call("get_status"))
            pc0, _ = status_regs(st)
            if "stopped" not in st:
                raise Fail(f"-debug: CPU not stopped at start: {st.splitlines()[0]}")
            p.m.call("set_breakpoint", address=f"${seed:04X}")
            p.m.call("run")
            p.m.call("wait_for_stop", timeout_ms=20000)
            ok, msg = seed_at_stop(p, "-debug")
            msg = (f"starts stopped at PC ${pc0:04X} (NEX entry, image loaded); set_breakpoint "
                   f"{{address: '${seed:04X}'}}, run, wait_for_stop; " + msg + "; " + game_runs(p))
        parts.append(f"-debug (launch extra): {'WORKS' if ok else 'FAILS'} - {msg}")
        oks.append(ok)
    except Exception as e:                                    # noqa: BLE001
        log("-debug form raised:\n" + traceback.format_exc())
        parts.append(f"-debug: FAILS - {type(e).__name__}: {e}")
        oks.append(False)
    how = " | ".join(parts) + (" | MCP calls: get_status, write_memory {address, data hex}, "
                               "set_registers {registers: {HL: '$A5C3'}}, step {} (count default 1).")
    return result(any(oks), how, rel(log.path))


# -- keys ------------------------------------------------------------------------------------------

def inp_state(p):
    ln, cur = p.rd(p.addr("INPLEN"), 2)
    return ln, cur, asciiz(p.rd(p.addr("INPLINE"), 128)).decode("ascii", "replace")


def suite_to_prompt(p):
    """From any SUITE page to check 51's prompt: SYM dismisses More..., QUIT gets Y + ENTER."""
    mores, quit_done = 0, False
    end = time.monotonic() + 120
    while time.monotonic() < end:
        rows = p.rows()
        txt = "\n".join(rows)
        if any("More..." in r for r in rows):
            p.m.call("press_keys", keys="SYM")
            p.wait(lambda: p.rows() != rows, 5, "the More... page to change after SYM")
            mores += 1
            continue
        if not quit_done and "Are you sure?" in txt:
            p.m.call("type_text", text="Y\n")
            quit_done = True
            continue
        if "51 TYPE: get lamp" in txt and at_prompt(rows):
            rows = p.settle()
            if at_prompt(rows):
                return mores, quit_done
        time.sleep(0.05)
    raise Fail("never reached check 51's prompt")


def p_keys(log):
    c = card(log, "SUITE")
    with Probe("keys", c, log) as p:
        kbprev = p.addr("KBPREV")
        rows0 = p.wait_text("More...", 30)
        rows0 = p.settle()
        p.show("first More... page", rows0)
        # 1. SYM held 250 frames on a More... page: $7FFE bit 1 low while held, page kept until release
        reply, dt, smp, after = hold_sampled(
            p, "SYM", 250, lambda: (p.portq("$7FFE"), p.rows() == rows0))
        held = [s for s in smp if not s[0] & 0x02]
        kept = all(s[1] for s in held)
        p.wait(lambda: p.rows() != rows0, 5, "the page to advance after release")
        rows1 = p.settle()
        p.show("after SYM release", rows1)
        sym_ok = len(held) >= 3 and kept and after[0] & 0x02 and rows1 != rows0
        s1 = (f"press_keys {{keys:'SYM', hold_frames:250, gap_frames:1}} on a second MCP session "
              f"returned {reply!r} after {dt:.2f} s; meanwhile port_in $7FFE read bit 1 low in "
              f"{len(held)}/{len(smp)} samples with the More... page unchanged in all of them, "
              f"${after[0]:02X} after release; the page advanced only after release")
        # 2. walk to check 51's prompt
        mores, quit_done = suite_to_prompt(p)
        rows = p.rows()
        p.show("at check 51 prompt", rows)
        st0 = inp_state(p)
        p.m.call("press_keys", keys="A B")
        p.frames(10)
        st1 = inp_state(p)
        p.m.call("press_keys", keys="CAPS+5")
        p.frames(10)
        st2 = inp_state(p)
        caps5_ok = st0[:2] == (0, 0) and st1 == (2, 2, "ab") and st2 == (2, 1, "ab")
        # 3. CAPS alone held 100 frames: $FEFE bit 0 low while held, line untouched
        _, _, smp3, after3 = hold_sampled(p, "CAPS", 100, lambda: p.portq("$FEFE"))
        held3 = [v for v in smp3 if not v & 0x01]
        st3 = inp_state(p)
        caps_ok = len(held3) >= 3 and after3 & 0x01 and st3 == st2
        # 4. N held 50 then 100 frames: kbPrev row 7 bit 3 (1 = down) and autorepeat count scale
        kbprev = p.addr("KBPREV")

        def samp_n():
            return p.portq("$7FFE"), p.rd(kbprev + 7, 1)[0]
        _, _, smp4, _ = hold_sampled(p, "N", 50, samp_n)
        st4 = inp_state(p)
        _, _, smp5, after5 = hold_sampled(p, "N", 100, samp_n)
        st5 = inp_state(p)
        n50 = st4[2].count("n")
        n100 = st5[2].count("n") - n50
        held4 = [s for s in smp4 + smp5 if not s[0] & 0x08 and s[1] & 0x08]
        n_ok = (len(held4) >= 3 and after5[0] & 0x08 and not after5[1] & 0x08 and n100 > n50 >= 1
                and st5[2] == "a" + "n" * (n50 + n100) + "b" and st5[1] == 1 + n50 + n100)
        # 5. bare SYM at the prompt: ignored by the line editor
        p.m.call("press_keys", keys="SYM")
        p.frames(10)
        st6 = inp_state(p)
        p.show("end", None)
    sym_line_ok = st6 == st5
    ok = sym_ok and caps5_ok and caps_ok and n_ok and sym_line_ok
    how = (f"HOLD: {'yes' if sym_ok and caps_ok and n_ok else 'NO'} - hold_frames sets the hold in "
           f"emulated frames and works under -freerun; MCP calls are served concurrently, so a "
           f"second session samples while press_keys blocks. {s1}. press_keys {{keys:'CAPS', "
           f"hold_frames:100}}: $FEFE bit 0 low in {len(held3)}/{len(smp3)} samples, ${after3:02X} "
           f"after, line {'unchanged' if st3 == st2 else 'CHANGED to ' + repr(st3)}. press_keys "
           f"{{keys:'N'}} held 50 then 100 frames: $7FFE bit 3 low and NextDAAD kbPrev+7 bit 3 set "
           f"(down) together in {len(held4)} samples; after release $7FFE ${after5[0]:02X}, kbPrev+7 "
           f"${after5[1]:02X}; autorepeat inserted {n50} then {n100} n's (line {st5[2]!r}, INPCUR "
           f"{st5[1]}). CAPS+5: {'yes' if caps5_ok else 'NO'} - from {st0}, press_keys 'A B' gave "
           f"INPLEN/INPCUR/line {st1}, then press_keys 'CAPS+5' gave {st2}. SYM alone dismisses "
           f"More...: {'yes' if sym_ok else 'NO'} - the held page above plus {mores} more page(s) "
           f"dismissed by press_keys 'SYM' on the way to check 51 (QUIT answered with type_text "
           f"'Y\\n': {quit_done}); at the input line press_keys 'SYM' left {st6} "
           f"({'ignored by the editor' if sym_line_ok else 'CHANGED the line'}).")
    return result(ok, how, rel(log.path))


# -- ay_readback -----------------------------------------------------------------------------------

def snap_ok(d):
    return d[:4] == b"AYS1" and d[4] == d[AY_SNAP_LEN - 1]


def ay_regs(p, sel_out):
    """3 PSGs x R0-R13 read through port_in $FFFD after selecting with sel_out(port, value)."""
    out = []
    for sel in (0xFF, 0xFE, 0xFD):
        sel_out("$FFFD", f"${sel:02X}")
        regs = []
        for r in range(14):
            sel_out("$FFFD", f"${r:02X}")
            regs.append(p.port("$FFFD"))
        out.append(regs)
    return out


def ay_diff(chips, d):
    bad = []
    for i in range(3):
        for r in range(14):
            want = d[0x10 + 14 * i + r]
            if (chips[i][r] ^ want) & AY_MASK[r]:
                bad.append(f"PSG{i + 1} R{r}={chips[i][r]:02X} mirror {want:02X}")
    return bad


def p_ay_readback(log):
    c = card(log, "AYSREG")
    rem_phys = client.read_map(MAP)["AYSREMAIN"][1]
    with Probe("ay_readback", c, log) as p:
        p.wait_text("STEADY", 30)
        p.settle()
        p.m.call("type_text", text="STEADY\n")
        p.wait(lambda: p.rd(AY_SNAP, 16)[8] & 1, 20, "aysFlags bit 0 (stream live) in the mirror")
        p.frames(50)
        tries = []
        for _ in range(4):
            st = p.m.text(p.m.call("pause"))
            d = p.rd(AY_SNAP, AY_SNAP_LEN)
            pc, _ = status_regs(st)
            if snap_ok(d):
                break
            tries.append(f"pause at PC ${pc:04X}: mirror torn, resumed")
            p.m.call("run")
            p.frames(3)
        else:
            raise Fail("mirror torn at every pause: " + "; ".join(tries))
        mirror = [list(d[0x10 + 14 * i:0x10 + 14 * i + 14]) for i in range(3)]
        log(f"mirror PSG1-3: {[bytes(x).hex(' ') for x in mirror]}")
        via_port_out = ay_regs(p, lambda port, v: p.m.call("port_out", port=port, value=v))
        bad_po = ay_diff(via_port_out, d)
        via_out_cmd = ay_regs(p, lambda port, v: p.m.call("debug_command", command=f"OUT {port},{v}"))
        bad_oc = ay_diff(via_out_cmd, d)
        log(f"port_out path: {[bytes(x).hex(' ') for x in via_port_out]}; mismatches {bad_po}")
        log(f"debug_command OUT path: {[bytes(x).hex(' ') for x in via_out_cmd]}; mismatches {bad_oc}")
        # NR select through each path as a second witness of port_out's effect
        p.m.call("port_out", port="$243B", value="$00")
        nr_po = p.port("$253B")
        p.m.call("debug_command", command="OUT $243B,$00")
        nr_oc = p.port("$253B")
        # leave the selection as aud_dbg_snap does (PSG 3, R13); the ISR reselects every frame
        p.m.call("debug_command", command="OUT $FFFD,$FD")
        p.m.call("debug_command", command="OUT $FFFD,$0D")
        virt = p.rd(AY_SNAP, 16)
        phys = p.rd(0x14000, 16, physical=True)
        rem0 = int.from_bytes(p.rd(rem_phys, 3, physical=True), "little")
        seq0 = d[4]
        p.m.call("run")
        p.frames(100)
        d2 = p.rd(AY_SNAP, AY_SNAP_LEN)
        rem1 = int.from_bytes(p.rd(rem_phys, 3, physical=True), "little")
        live = bool(d2[8] & 1) and rem1 != rem0 and d2[4] != seq0
    ok = not bad_oc and live
    po_vals = sorted({f"${v:02X}" for x in via_port_out for v in x})
    how = (f"pause {{}} (mirror intact after {len(tries) + 1} pause(s)), then per PSG select "
           f"and R0-R13: port_out {{port:'$FFFD', value:'$xx'}} + port_in {{port:'$FFFD'}} "
           f"{'matches' if not bad_po else 'does NOT match'} the mirror ({len(bad_po)}/42 differ; "
           f"values read {po_vals}"
           + (", one value for all 42, so the select never took" if len(po_vals) == 1 else "")
           + f"; NR $00 via port_out $243B + port_in $253B read ${nr_po:02X}"
           + ("; MCP port_out had no observed effect on either port" if len(po_vals) == 1 and
              nr_po != nr_oc else "") + "); "
           f"debug_command {{command:'OUT $FFFD,$xx'}} + port_in $FFFD "
           f"{'matches all 42 registers' if not bad_oc else 'differs: ' + ', '.join(bad_oc[:6])} "
           f"(same path read NR $00 = ${nr_oc:02X}). Selection restored to PSG 3 R13 with "
           f"debug_command OUT. run {{}}: after 100 frames mirror seq {seq0} -> {d2[4]}, aysFlags "
           f"${d2[8]:02X}, aysRemain (physical ${rem_phys:X}) {rem0} -> {rem1}: playback "
           f"{'continues' if live else 'did NOT continue'}. Aside: virtual $4000 {virt[:8].hex(' ')} "
           f"vs physical $14000 {phys[:8].hex(' ')} "
           f"({'equal' if virt == phys else 'DIFFERENT'}; slot 2 holds page $0A).")
    return result(ok, how, rel(log.path))


# -- esxdos ----------------------------------------------------------------------------------------

def submit(p, text, seconds=20):
    """type_text text + ENTER, then wait for the next input prompt; returns the settled rows."""
    p.m.call("type_text", text=text + "\n")
    p.frames(5)
    return p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), seconds,
                  f"the prompt after {text!r}")


def esx_savload(log):
    c = card(log, "LEGPC")
    with Probe("esxdos", c, log) as p:
        fl = p.addr("FLAGS")
        p.wait_text("PRESS A KEY", 30)
        p.m.call("press_keys", keys="SYM")
        p.wait_text("TYPE JUMP", 20)
        p.settle()
        p.m.call("type_text", text="JUMP\n")
        p.wait_text("P2 ROOM", 30)
        rows = p.settle()
        p.show("part 2", rows)
        p.m.call("write_memory", address=f"${fl + 200:X}", data="5AA5")
        before = p.rd(fl, 256)
        p.m.call("type_text", text="SAVE\n")
        p.wait_text("Type in name of file", 20)
        rows = submit(p, "PROBE")
        p.show("after SAVE", rows)
        sav = c / "PROBE.SAV"
        size = sav.stat().st_size if sav.is_file() else None
        p.m.call("write_memory", address=f"${fl + 200:X}", data="0000")
        p.m.call("type_text", text="LOAD\n")
        p.wait_text("Type in name of file", 20)
        rows = submit(p, "PROBE")
        p.show("after LOAD", rows)
        after = p.rd(fl, 256)
    diff = [i for i in range(256) if before[i] != after[i]]
    ok = bool(size) and after[200] == 0x5A and after[201] == 0xA5
    return ok, (f"LEGPC part 2 (JUMP = EXTERN 2 4 loaded GAME2.DDB): flags 200/201 := $5A/$A5 by "
                f"write_memory, SAVE + type_text 'PROBE\\n' wrote PROBE.SAV ({size} bytes on the host "
                f"card), flags zeroed, LOAD + 'PROBE\\n' restored ${after[200]:02X}/${after[201]:02X}; "
                f"flags differing from the snapshot taken before typing SAVE: {diff or 'none'}"
                + (" (turn counter 31-32 and parsed-sentence flags 33-36, 43-45 only: SAVE's own "
                   "turn moved them)" if set(diff) <= {31, 32, 33, 34, 35, 36, 43, 44, 45} else ""))


def trace_esx(p, cmd):
    """Type cmd with execute breakpoints after each esxDOS rst $08 wrapper; list call results."""
    pts = {}
    for name, post in (("ESX_FOPEN", 5), ("ESX_FSEEK", 7), ("ESX_FWRITE", 5), ("ESX_FCLOSE", 5)):
        a = p.addr(name)
        pts[a], pts[a + post] = name.lower() + " in", name.lower() + " out"
    for a in pts:
        p.m.call("set_breakpoint", address=f"${a:X}")
    m2 = p.conn()
    th = threading.Thread(target=lambda: m2.call("type_text", text=cmd + "\n"))
    th.start()
    seen = []
    for _ in range(40):
        st = p.m.text(p.m.quiet("wait_for_stop", timeout_ms=3000))
        if "stopped" not in st:
            break
        pc, r = status_regs(st)
        seen.append(f"{pts.get(pc, hex(pc))} A=${r['AF'] >> 8:02X} CF={r['AF'] & 1} "
                    f"BC=${r['BC']:04X} DE=${r['DE']:04X} IX=${r['IX']:04X}")
        p.m.quiet("run")
    th.join(10)
    p.m.call("clear_breakpoint", all=True)
    p.log(f"esx trace for {cmd}:\n  " + "\n  ".join(seen))
    return seen


def esx_transcript(log):
    c = card(log, "XBNTRANS")
    tr = c / "TRANS.TXT"
    with Probe("esxdos", c, log) as p:
        p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), 30, "the XBN prompt")
        sizes = []
        for cmd in ("XTRS", "XTR1", "XTR2", "HELLO THERE", "XTRQ"):
            rows = submit(p, cmd)
            sizes.append((cmd, tr.stat().st_size if tr.is_file() else None))
        p.show("before XTRE", rows)
        tail = "".join(r.rstrip() for r in rows).rsplit("XTRQ", 1)[-1].lstrip()
        rec = "NOREC" if tail.startswith("NOREC") else "REC" if tail.startswith("REC") else tail[:8]
        trace = trace_esx(p, "XTRE")
        p.settle()
        size_run = tr.stat().st_size if tr.is_file() else None
    data = tr.read_bytes() if tr.is_file() else b""
    log(f"TRANS.TXT after close ({len(data)} bytes): {data[:600]!r}")
    want = [b"XTR1", b"XTR2", b"HELLO THERE", b"XTRQ", b"ONE TWO THREE", b"SECOND TURN"]
    missing = [w.decode() for w in want if w not in data]
    ok = not missing
    calls = "; ".join(t for t in trace if " out" in t)
    msg = (f"XBN -Xbn -XbnTrans: XTRS, XTR1, XTR2, 'HELLO THERE', XTRQ (answered {rec!r}: REC = "
           f"still armed, so the module saw no write error), XTRE; TRANS.TXT size after each: "
           f"{sizes}, after XTRE {size_run}, after close {len(data)} bytes; missing from the file: "
           f"{missing or 'none'}. esxDOS results during XTRE's flush (open mode $03 existing "
           f"read/write, breakpoints after each rst $08): {calls}")
    if not ok:
        msg += ". " + transcript_diag(log)
    return ok, msg


def transcript_diag(log):
    """Second launch (-exit): XTRS's header flush with F_SEEK skipped, then an EXIT-opcode
    exit, so the seek and exit-time flushing are ruled in or out."""
    c = OUT / "cards" / "XBNTRANS_DIAG"
    if c.is_dir():
        shutil.rmtree(c)
    shutil.copytree(OUT / "cards" / "XBNTRANS", c)
    (c / "TRANS.TXT").unlink(missing_ok=True)
    tr = c / "TRANS.TXT"
    seen = []
    with Probe("esxdos", c, log, extra=("-exit",)) as p:
        p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), 30, "the XBN prompt")
        fo, sk, fw = p.addr("ESX_FOPEN"), p.addr("ESX_FSEEK"), p.addr("ESX_FWRITE")
        for a in (fo, fo + 5, sk, fw + 5):
            p.m.call("set_breakpoint", address=f"${a:X}")
        m2 = p.conn()
        th = threading.Thread(target=lambda: m2.call("type_text", text="XTRS\n"))
        th.start()
        for _ in range(12):
            st = p.m.text(p.m.call("wait_for_stop", timeout_ms=3000))
            if "stopped" not in st:
                break
            pc, r = status_regs(st)
            if pc == fo:
                seen.append(f"fopen mode ${r['BC'] >> 8:02X}")
            elif pc == fo + 5:
                seen.append(f"-> A=${r['AF'] >> 8:02X} CF={r['AF'] & 1}")
            elif pc == sk:
                p.m.call("set_registers", registers={"PC": f"${sk + 7:X}", "F": "$00"})
                seen.append("fseek skipped")
            elif pc == fw + 5:
                seen.append(f"fwrite -> CF={r['AF'] & 1} BC=${r['BC']:04X}")
            p.m.call("run")
        th.join(10)
        p.m.call("clear_breakpoint", all=True)
        p.settle()
        run_size = tr.stat().st_size if tr.is_file() else None
        pc, _ = status_regs(p.m.text(p.m.call("pause")))
        p.m.call("write_memory", address=f"${pc:X}", data="DD00")   # CSpect -exit opcode
        p.m.call("run")
        p.wait(lambda: p.inst.proc.poll() is not None, 10, "CSpect to exit on DD 00")
        code = p.inst.proc.poll()
    size = tr.stat().st_size if tr.is_file() else None
    lost = run_size == 0 and size == 0 and "fseek skipped" in seen
    return (f"Diagnostic launch with -exit, XTRS traced: {', '.join(seen)}; TRANS.TXT {run_size} "
            f"bytes while running, {size} after CSpect exited (exit code {code}) on the DD 00 "
            f"opcode" + (" - so neither the seek nor exit-time flushing explains it: writes "
                         "through a mode $03 handle (existing file, read/write) report success and "
                         "never reach the host file, while create/truncate + write in one open "
                         "(SAVE above) does" if lost else ""))


def esx_getdate(log):
    c = card(log, "XBNFIX")
    with Probe("esxdos", c, log) as p:
        fl = p.addr("FLAGS")
        p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), 30, "the XBN prompt")
        rows = submit(p, "XDAT")
        p.show("after XDAT", rows)
        f = p.rd(fl + 223, 5)
        p.m.call("type_text", text="XTCO\n")
        p.frames(200)
        rows = p.settle()
        p.show("after XTCO", rows)
        f2 = p.rd(fl + 223, 5)
        p.m.call("write_memory", address=f"${fl + 200:X}", data="00")
        before = p.rows()
        p.m.call("type_text", text="XABS\n")
        p.wait(lambda: p.flag(200) == 9 and p.rows() != before, 20, "XABS to answer")
        rows = p.settle()
        p.show("after XABS", rows)
        pc = p.m.pc()
    bc, de = f[1] << 8 | f[2], f[3] << 8 | f[4]
    date = (f"{(bc >> 9) + 1980:04d}-{bc >> 5 & 15:02d}-{bc & 31:02d} "
            f"{de >> 11:02d}:{de >> 5 & 63:02d}:{(de & 31) * 2:02d}")
    ok = f[0] in (0, 1)
    return ok, (f"XBN -Xbn fixture: XDAT (LET 223 9, EXTERN 0 36 -> SVC_GETDATE / M_GETDATE) "
                f"returned, flag 223 = {f[0]} (poison 9 replaced; 1 = RTC present), date/time words "
                f"BC ${bc:04X} DE ${de:04X} = {date}; XTCO (EXTERN 1 36 among its calls) returned "
                f"(flags 223-227 then {f2.hex(' ')}); XABS then answered 9 (game continues, PC ${pc:04X})")


def p_esxdos(log):
    parts, oks = [], []
    for name, fn in (("SAVE/LOAD", esx_savload), ("transcript", esx_transcript),
                     ("getdate", esx_getdate)):
        try:
            ok, msg = fn(log)
        except Exception as e:                                # noqa: BLE001 - recorded per part
            log(f"{name} raised:\n" + traceback.format_exc())
            ok, msg = False, f"raised {type(e).__name__}: {e}"
        parts.append(f"{name}: {'yes' if ok else 'NO'} - {msg}")
        oks.append(ok)
    return result(all(oks), " | ".join(parts), f"{rel(log.path)}; cards under {rel(OUT / 'cards')}")


# -- type_text_freerun -----------------------------------------------------------------------------

def p_type_text_freerun(log):
    c = card(log, "TEMPLATE")
    turns, fails = [], []
    with Probe("type_text_freerun", c, log) as p:
        fl, last, qw = p.addr("FLAGS"), p.addr("INPLAST"), p.addr("KBQW")
        p.wait_text("Press any key", 30)
        p.m.call("press_keys", keys="SYM")
        p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), 30, "the first prompt")
        tw = lambda: int.from_bytes(p.rd(fl + 31, 2), "little")   # noqa: E731 - fTurns, fTurnsHi
        for i in range(1, 21):
            p.m.call("write_memory", address=f"${last:X}", data="00")
            t0, q0 = tw(), p.rd(qw, 1)[0]
            p.m.call("type_text", text="LOOK\n")
            p.wait(lambda: tw() != t0, 15, f"turn {i} to be counted")
            rows = p.wait(lambda: (lambda r: r if at_prompt(r) else None)(p.settle()), 15,
                          f"the prompt after turn {i}")
            line = asciiz(p.rd(last, 128)).decode("ascii", "replace")
            edges = (p.rd(qw, 1)[0] - q0) & 15
            dturn = tw() - t0
            turns.append((i, line, edges, dturn))
            if line != "LOOK" or edges != 5 or dturn != 1:
                fails.append((i, line, edges, dturn))
                p.show(f"turn {i} FAILED", rows)
        p.show("after turn 20", rows)
    ok = len(turns) == 20 and not fails
    how = (f"TEMPLATE under -freerun: 20 x type_text {{text:'LOOK\\n'}} (defaults hold 3 / gap 3 "
           f"frames), each waited to the next prompt by polling fTurns and the tilemap against frame "
           f"deadlines. Every turn: inpLast (the editor's submitted line, cleared before each type) "
           f"= 'LOOK', kbQw advanced by exactly 5 press edges (L O O K ENTER), fTurns +1 - "
           f"{'all 20 exact' if ok else 'FAILURES ' + str(fails)}. The on-screen echo is not read: "
           f"the template's LOOK is CLS + RESTART, which clears it.")
    return result(ok, how, rel(log.path))


# -- screenshot_freerun ----------------------------------------------------------------------------

def shot(p, name):
    from PIL import Image
    res = p.m.quiet("screenshot", scale=2)
    for c in res.get("content", []):
        if c.get("type") == "image":
            raw = base64.b64decode(c["data"])
            (OUT / name).write_bytes(raw)
            p.log(f"CALL screenshot {{'scale': 2}} -> image {len(raw)} bytes -> {name}")
            return Image.open(io.BytesIO(raw)).convert("RGB")
    raise Fail(f"screenshot returned no image: {p.m.text(res)!r}")


def band_diff(a, b):
    """Changed 16-pixel tilemap rows (scale 2: row r = y 16r..16r+15) and the diff bbox."""
    from PIL import ImageChops
    d = ImageChops.difference(a, b)
    return [r for r in range(32) if d.crop((0, 16 * r, 640, 16 * r + 16)).getbbox()], d.getbbox()


def p_screenshot_freerun(log):
    c = card(log, "SUITE")
    with Probe("screenshot_freerun", c, log) as p:
        p.wait_text("More...", 30)
        p.settle()
        attr = p.rd(TM_MAP, 2)[1]
        target = [1, 3, 5]                                    # overwritten: any known new content
        cells = lambda s: bytes(b for ch in (s * 10).encode()[:80] for b in (ch, attr)).hex()  # noqa: E731
        a = shot(p, "screenshot_freerun_0_before.png")
        if a.size != (640, 512):
            raise Fail(f"scale 2 screenshot is {a.size}, not 640x512")
        # 1. write a row, wait 2 frames, screenshot
        p.m.call("write_memory", address=f"${TM_MAP + 160 * target[0]:X}", data=cells("PROBE ONE "))
        p.frames(2)
        b = shot(p, "screenshot_freerun_1_after2frames.png")
        rows_b, bbox_b = band_diff(a, b)
        # 2. write a row and screenshot at once
        f0 = p.frame()
        p.m.call("write_memory", address=f"${TM_MAP + 160 * target[1]:X}", data=cells("PROBE TWO "))
        c2 = shot(p, "screenshot_freerun_2_immediate.png")
        el = (p.frame() - f0) & 0xFFFF
        rows_c, _ = band_diff(b, c2)
        # 3. paused: write a row, screenshot, run, 2 frames, screenshot
        p.m.call("pause")
        p.m.call("write_memory", address=f"${TM_MAP + 160 * target[2]:X}", data=cells("PROBE THREE "))
        d = shot(p, "screenshot_freerun_3_paused.png")
        rows_d, _ = band_diff(c2, d)
        p.m.call("run")
        p.frames(2)
        e = shot(p, "screenshot_freerun_4_resumed.png")
        rows_e, _ = band_diff(c2, e)
    ok = rows_b == [target[0]]
    how = (f"SUITE More... page (static) under -freerun; screenshot {{scale:2}} is 640x512 with "
           f"tilemap row r at y 16r..16r+15 (80 cols x 8 px). write_memory of tilemap row "
           f"{target[0]} then 2 frames (NextDAAD frame counter) -> changed rows {rows_b}, bbox "
           f"{bbox_b}: {'shows the change, nothing else' if ok else 'NOT as expected'}. Immediate "
           f"screenshot after writing row {target[1]} (no wait; {el} frames elapsed during the call): "
           f"changed rows {rows_c}. While paused, a write to row {target[2]} "
           + ("is NOT in the screenshot (the last rendered frame is returned)" if not rows_d else
              f"shows as changed rows {rows_d}")
           + f"; after run + 2 frames changed rows {rows_e}.")
    return result(ok, how, f"{rel(OUT)}/screenshot_freerun_*.png; {rel(log.path)}")


PROBES = {"tools": p_tools, "paused_start": p_paused_start, "keys": p_keys,
          "ay_readback": p_ay_readback, "esxdos": p_esxdos,
          "type_text_freerun": p_type_text_freerun, "screenshot_freerun": p_screenshot_freerun}


def write_md(data):
    cell = lambda s: str(s).replace("|", "/").replace("\n", " ")   # noqa: E731
    lines = ["# CSpect MCP capability probe", "",
             f"CSpect source {launcher.source_dir()}, NEX {rel(NEX)}, map {rel(MAP)}.", "",
             "| key | ok | how | evidence |", "|---|---|---|---|"]
    for k in KEYS:
        if k in data:
            r = data[k]
            lines.append(f"| {k} | {'yes' if r['ok'] else 'NO'} | {cell(r['how'])} | {cell(r['evidence'])} |")
        else:
            lines.append(f"| {k} | not run | | |")
    (OUT / "probe.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    global NO_STAGE
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None, help="comma-separated keys: " + ",".join(KEYS))
    ap.add_argument("--no-stage", action="store_true",
                    help="use the sd\\ legs as staged (XBN variants fall back to earlier card copies)")
    a = ap.parse_args()
    NO_STAGE = a.no_stage
    keys = KEYS if not a.only else [k.strip() for k in a.only.split(",") if k.strip()]
    bad = [k for k in keys if k not in KEYS]
    if bad:
        sys.exit(f"unknown key(s) {bad}; keys are {', '.join(KEYS)}")
    OUT.mkdir(parents=True, exist_ok=True)
    jpath = OUT / "probe.json"
    data = json.loads(jpath.read_text(encoding="utf-8")) if jpath.is_file() else {}
    for k in keys:
        log = Log(k)
        try:
            data[k] = PROBES[k](log)
        except Exception as e:                                # noqa: BLE001 - recorded as ok=false
            log("EXCEPTION\n" + traceback.format_exc())
            data[k] = result(False, f"probe raised {type(e).__name__}: {e}", rel(log.path))
        finally:
            log.close()
        print(f"{k}: ok={data[k]['ok']}")
        jpath.write_text(json.dumps({x: data[x] for x in KEYS if x in data}, indent=1),
                         encoding="utf-8")
    write_md(data)
    alive = []
    for pid, h in PIDS:
        if h and _k32.WaitForSingleObject(h, 10000) != 0:
            alive.append(pid)
            _k32.TerminateProcess(h, 1)
        if h:
            _k32.CloseHandle(h)
    print(f"CSpect PIDs started: {[p for p, _ in PIDS]}; still alive after close: {alive or 'none'}")
    return 1 if alive else 0


if __name__ == "__main__":
    sys.exit(main())
