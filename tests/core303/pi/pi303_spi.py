"""P3 SPI throughput and contention (Pi side). Writes SPI.LOG and fetches PI_PI303.LOG.

Steps: framing self-test, SRAM and bank 7 write sweeps, read sweep, chunk sizes, Python
path, HANDOVER (Next-led QUIET/STREAM/STOP until YIELD), Pi-led LOAD profiles, END.
Bulk traffic goes through spi303; headers, reads and mailbox writes run at 2 MHz.
"""
import argparse
import math
import os
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass

import link as lk
import mailbox as mbx
from bundle import bundle_hash
from pi303_probe import _nr_test, default_core_clk, default_spi_open, open_log, write_busy

TOOL = "pi303_spi"
HERE = os.path.dirname(os.path.abspath(__file__))
LOG_NAME = "SPI.LOG"
RESULT_NAME = "PI_PI303.LOG"

LADDER = tuple(2_000_000 + 500_000 * i for i in range(21))     # 2.0 to 12.0 MHz
EFF_SHORT, EFF_LONG = 512, 4000
MERGE_TOL = 0.01            # requests within 1% of the previous effective rate merge
STOP_PAST = 2               # rates tested past the first failing one
SEED_BASE = 0x30300001
B7_LEN = 0x2000
QUIET_MAX_US = 10_000_000   # PI303 asserts arg32 below this
STATE_CONFIRM = 3           # non-1 state reads in a row before state != 1 counts
RESULT_LEN_MAX = 0xBF00

HB_NEXT_WAIT_S = 2.0
ACK_TIMEOUT_S = 2.0
LEADER_WAIT_S = 2.0
FOLLOW_IDLE_S = 30.0
STREAM_START_S = 2.0
DONE_TIMEOUT_S = 150.0      # covers PI303's own 120 s exit when the Pi lost the lead
POLL_S = 0.002
STREAM_POLL_S = 0.05
STATE_POLL_S = 0.05
LOAD_SETTLE_S = 0.2

# P3TE model: per-transaction and per-process overheads, Python path costs, handover time
TX_OVH_S = 150e-6
CALL_S = 0.05
PY_TX_S = 500e-6
PY_PAT_BPS = 60_000         # pure-Python xorshift on a 700 MHz ARMv6
HANDOVER_S = 90

MAP_KEYS = ("mbox_phys", "scratch_phys", "scratch_len", "u_phys", "sled_phys", "sled_len",
            "rs_phys", "rs_len", "r5_off", "r5_len", "lr_src_phys", "lr_len", "bf_dst_phys",
            "bf_len", "fill_val", "result_len_max", "row_np", "row_rs", "row_r5", "row_lr",
            "row_bf")


@dataclass(frozen=True)
class Plan:
    ladder: tuple = LADDER
    pass_bytes: int = 0x40000       # one pass rewrites the whole 256 KB scratch
    passes: int = 4                 # 1 MB a run
    clean_runs: int = 3
    chunk: int = lk.MAX_CHUNK
    b7_passes: int = 128
    chunks: tuple = (64, 256, 1024, 4000)
    chunk_bytes: int = 0x40000
    eff_reps: int = 5
    u_len: int = 0x4000
    profiles: tuple = (0, 1, 2, 3, 4)
    starve_hz: tuple = (4_000_000, 2_000_000)
    ready_timeout_s: float = 120.0


class ToolError(Exception):
    def __init__(self, rows, rc=2):
        super().__init__("spi303 exit %d" % rc)
        self.rows, self.rc = rows, rc


class StateChanged(Exception):
    pass


class Lost(Exception):
    def __init__(self, tag, reason):
        super().__init__("%s %s" % (tag, reason))
        self.tag, self.reason = tag, reason


def read_map(path, keys=MAP_KEYS):
    """PI303.MAP: key=hex lines from the build's MAP_ symbols."""
    out = {}
    with open(path, encoding="ascii") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            k, eq, v = ln.partition("=")
            if not eq or not re.fullmatch(r"[a-z][a-z0-9_]*", k) \
                    or not re.fullmatch(r"[0-9A-Fa-f]{1,8}", v):
                raise ValueError("bad MAP line %r" % ln)
            out[k] = int(v, 16)
    missing = [k for k in keys if k not in out]
    if missing:
        raise ValueError("MAP lacks " + " ".join(missing))
    return out


def cmp_tx(want, got):
    """As core303pi.c cmp_tx: (mismatches, first, shift); shift k in 1-8 when
    got[i] == want[i+k] for every i from first to n-k-1."""
    if want == got:
        return 0, -1, 0
    n = len(want)
    diff = [i for i in range(n) if want[i] != got[i]]
    f = diff[0]
    for k in range(1, 9):
        if f + k >= n:
            break
        if got[f:n - k] == want[f + k:n]:
            return len(diff), f, k
    return len(diff), f, 0


def eff_rate(t_short_ns, t_long_ns):
    d = t_long_ns - t_short_ns
    return int(round((EFF_LONG - EFF_SHORT) * 8 * 1e9 / d)) if d > 0 else 0


def estimate_s(plan):
    """Upper bound: every sweep walks the whole ladder; ceiling-bound steps at 2 MHz."""
    hdr = lk.HDR_HZ

    def wr(hz, n, chunk):
        return n * 8 / hz + n * 8 / hdr + 2 * math.ceil(n / chunk) * TX_OVH_S

    run_b = plan.pass_bytes * plan.passes
    L = plan.ladder
    eff = sum(2 * CALL_S + plan.eff_reps * (wr(h, EFF_SHORT, EFF_SHORT) + wr(h, EFF_LONG, EFF_LONG))
              for h in L)
    ws = sum(plan.clean_runs * (CALL_S + wr(h, run_b, plan.chunk)) for h in L)
    wb = sum(CALL_S + plan.b7_passes * wr(h, B7_LEN, lk.MAX_CHUNK) for h in L)
    rd = wr(hdr, plan.pass_bytes, plan.chunk) + sum(
        CALL_S + run_b * 8 / h + math.ceil(run_b / plan.chunk) * TX_OVH_S for h in L)
    ch = sum(CALL_S + wr(hdr, plan.chunk_bytes, c) for c in plan.chunks)
    py_run = lambda h, n, c: wr(h, n, c) + math.ceil(n / c) * PY_TX_S + n / PY_PAT_BPS
    py = sum(py_run(h, run_b, plan.chunk) for h in L) + sum(
        py_run(hdr, plan.chunk_bytes, c) for c in plan.chunks)
    starve = len(plan.profiles) * (LOAD_SETTLE_S + ws + (1 + len(plan.starve_hz)) * (
        CALL_S + wr(hdr, run_b, plan.chunk)))
    return int(math.ceil(eff + ws + wb + rd + ch + py + HANDOVER_S + starve))


def parse_rows(text):
    rows = []
    for ln in text.splitlines():
        tok = ln.split()
        if not tok or not re.fullmatch(r"[A-Z0-9]{4}", tok[0]):
            continue
        kv = {}
        for t in tok[1:]:
            k, eq, v = t.partition("=")
            if not eq or not re.fullmatch(r"-?[0-9]+", v):
                break
            kv[k] = int(v)
        else:
            rows.append((tok[0], kv))
    return rows


class StreamProc:
    """One `spi303 stream`; it stops when its stdin is closed."""

    def __init__(self, proc):
        self.proc = proc

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.terminate()       # its SIGTERM handler restores the spidev settings
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        out = self.proc.stdout.read()
        return parse_rows(out.decode("ascii", "replace") if isinstance(out, bytes) else out)


class SpiTool:
    """spi303 subcommands (looping in C); rows parsed from stdout. Never flocks."""

    def __init__(self, exe, extra=(), dev=None, timeout_s=900):
        self.argv0 = [exe] + list(extra) + (["--dev", dev] if dev else [])
        self.timeout_s = timeout_s

    @staticmethod
    def _hb(hb):
        return ["--hb", "0x%X" % hb] if hb else []

    def _run(self, *args, ok_rc=(0,)):
        argv = self.argv0 + [str(a) for a in args]
        try:
            r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                               timeout=self.timeout_s, start_new_session=True)
        except subprocess.TimeoutExpired:
            raise ToolError([], -1)
        rows = parse_rows(r.stdout.decode("ascii", "replace"))
        if r.returncode not in ok_rc:
            raise ToolError(rows, r.returncode)
        return rows

    def selftest(self, phys):
        return self._run("selftest", "0x%X" % phys, ok_rc=(0, 1))

    def write(self, phys, nbytes, hz, chunk, seed0, passes=1, hb=None):
        return self._run("write", "0x%X" % phys, nbytes, hz, chunk, seed0, "--passes", passes,
                         *self._hb(hb))

    def read(self, phys, nbytes, hz, chunk, seed, passes=1, hb=None):
        return self._run("read", "0x%X" % phys, nbytes, hz, chunk, "--seed", seed,
                         "--passes", passes, *self._hb(hb))

    def bram(self, bank, hz, passes, seed0, hb=None):
        return self._run("bram", bank, hz, passes, seed0, *self._hb(hb))

    def stream(self, target, length, hz, src, hb):
        argv = self.argv0 + ["stream", target, str(length), str(hz), src] + self._hb(hb)
        return StreamProc(subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True))


class PiMailbox(mbx.Mailbox):
    def head(self):
        return self._read(0, mbx.HEAD_LEN)

    def hb_pi(self):
        return struct.unpack("<H", self._read(mbx.OFF_HB_PI, 2))[0]

    def not_ready(self, st):
        """True only when st and the next STATE_CONFIRM - 1 state reads all show state != 1:
        a 2 MHz read starved of the SRAM port can return a stale byte."""
        for _ in range(STATE_CONFIRM - 1):
            if st == mbx.STATE_READY:
                return False
            st = self.state()
        return st != mbx.STATE_READY

    def ready_head(self):
        """(head, ready); a head whose non-1 state was not confirmed is read again."""
        for _ in range(STATE_CONFIRM):
            head = self.head()
            if head[mbx.OFF_STATE] == mbx.STATE_READY:
                return head, True
            if self.not_ready(head[mbx.OFF_STATE]):
                return head, False
        return head, True

    def ack(self, cmd):
        """Follower ack; reads state with leader so no ack lands once state != 1."""
        head, ready = self.ready_head()
        if not ready:
            raise StateChanged()
        if head[mbx.OFF_LEADER] != 1:
            raise mbx.MailboxError("Pi is no longer the follower")
        self._write(mbx.OFF_ACK, [cmd.seq])

    def result(self):
        b = self._read(20, 5)
        return int.from_bytes(b[0:3], "little"), b[3] | (b[4] << 8)

    def send(self, cmd, arg0=0, arg1=0, arg32=0, timeout_s=ACK_TIMEOUT_S, idle=None):
        """Mailbox.send, with idle() (the heartbeat) run while waiting for the ack."""
        head, ready = self.ready_head()
        if not ready:
            raise StateChanged()
        if head[0:4] != mbx.MAGIC or head[mbx.OFF_LEADER] != 0:
            raise mbx.MailboxError("not the leader of a ready mailbox")
        seq = (head[mbx.OFF_SEQ] + 1) & 0xFF
        self._write(mbx.OFF_ARG0, [arg0 & 0xFF])
        self._write(mbx.OFF_ARG1, [arg1 & 0xFF])
        self._write(mbx.OFF_ARG32, struct.pack("<I", arg32 & 0xFFFFFFFF))
        self._write(mbx.OFF_CMD, [cmd])
        self._write(mbx.OFF_SEQ, [seq])
        end = self.clock.time() + timeout_s
        while True:
            head = self.head()          # state with the ack: no heartbeat once state != 1
            if head[mbx.OFF_ACK] == seq:
                break                   # acked: END's ack and state 4 land ~10 us apart
            if self.not_ready(head[mbx.OFF_STATE]):
                raise StateChanged()
            if self.clock.time() >= end:
                raise mbx.MailboxTimeout("no ack for command %d seq %d" % (cmd, seq))
            if idle:
                idle()
            self.clock.sleep(mbx.POLL_S)
        return seq


def pending(head):
    """The leader's unacked command in a head snapshot, or None."""
    if head[mbx.OFF_SEQ] == head[mbx.OFF_ACK]:
        return None
    return mbx.Cmd(head[mbx.OFF_SEQ], head[mbx.OFF_CMD], head[mbx.OFF_ARG0],
                   head[mbx.OFF_ARG1], struct.unpack_from("<I", head, mbx.OFF_ARG32)[0])


class PiRun:
    """Mailbox plumbing shared by the Pi-led tools: gate, ready wait, END, result fetch."""
    RF_TAG = "P3RF"             # result fetch row and skips; pi303_video overrides
    RESULT_NAME = RESULT_NAME

    def __init__(self, link, mbox_phys, out_dir, bundle, tool, addrs, clock, plan, core_clk,
                 spi_open, step):
        self.link, self.mbox = link, mbox_phys
        self.out_dir, self.bundle, self.tool = out_dir, bundle, tool
        self.addrs = dict(addrs or {})
        self.clock = clock or lk.RealClock()
        self.plan = plan
        self.core_clk, self.spi_open = core_clk, spi_open
        self.mb = PiMailbox(link, mbox_phys, self.clock)
        self.hb = mbx.Heartbeat(self.mb, self.clock)
        self.step = step
        self.ok = True
        self.streams = []
        self.log = None

    def gate(self):
        if self.mb.not_ready(self.mb.state()):
            self.hb.suspend()           # no hb_pi write once a read has shown state != 1
            raise StateChanged()

    def idle(self, s):
        end = self.clock.time() + s
        while self.clock.time() < end:
            self.hb.tick()
            self.clock.sleep(POLL_S * 5)

    def wait_ready(self):
        """Reads only until M303, state 1, leader 0 and a moving hb_next (a live PI303)."""
        end = self.clock.time() + self.plan.ready_timeout_s
        while self.clock.time() < end:
            head = self.mb.head()
            if head[0:4] == mbx.MAGIC and head[mbx.OFF_STATE] == mbx.STATE_READY \
                    and head[mbx.OFF_LEADER] == 0:
                hb0 = struct.unpack_from("<H", head, mbx.OFF_HB_NEXT)[0]
                t1 = self.clock.time() + HB_NEXT_WAIT_S
                while self.clock.time() < t1:
                    self.clock.sleep(0.05)
                    if self.mb.read_hb_next() != hb0:
                        return True
            self.clock.sleep(0.1)
        return False

    def wait_done(self):
        end = self.clock.time() + DONE_TIMEOUT_S
        while self.clock.time() < end:
            st = self.mb.state()
            if st in (mbx.STATE_DONE, mbx.STATE_FAILED):
                return st
            self.clock.sleep(STATE_POLL_S)
        return None

    def fetch(self, state):
        """Read only inside the MAP result region (result_phys_region + result_len_max)."""
        phys, n = self.mb.result()
        cap = self.addrs.get("result_len_max", RESULT_LEN_MAX)
        lo = self.addrs.get("result_phys_region")
        saved = 0
        if n == 0:
            self.log.skip(self.RF_TAG, "NORESULT")
        elif n > cap or phys + n > lk.SRAM_SIZE or (
                lo is not None and not (lo <= phys and phys + n <= lo + cap)):
            self.log.skip(self.RF_TAG, "RANGE")
        else:
            data = self.link.read_mem(phys, n, lk.HDR_HZ)
            with open(os.path.join(self.out_dir, self.RESULT_NAME), "wb") as f:
                f.write(data)
            saved = 1
        self.log.row(self.RF_TAG, state=state, phys=phys, len=n, saved=saved)

    def finish(self, aborted):
        """END when still the ready leader, then no writes: wait for 2/3 and fetch."""
        self.step = self.RF_TAG
        if not aborted:
            try:
                head, ready = self.mb.ready_head()
                if ready and head[mbx.OFF_LEADER] == 0:
                    self.mb.send(mbx.CMD_END, idle=self.hb.tick)
                else:
                    self.log.skip(self.RF_TAG, "NOEND")
                    self.ok = False
            except StateChanged:
                self.log.skip("PIST", "STATE")
                aborted = True
            except (lk.LinkError, mbx.MailboxError):
                self.log.skip(self.RF_TAG, "NOEND")
                self.ok = False
        self.hb.suspend()
        try:
            state = self.wait_done()
            if state is None:
                self.log.skip(self.RF_TAG, "TIMEOUT")
                return 1
            self.fetch(state)
        except (lk.LinkError, mbx.MailboxError, OSError):
            self.log.skip(self.RF_TAG, "LINK")
            return 1
        if state == mbx.STATE_FAILED:
            self.log.skip("PI3S", "STATE3")
        return 0 if state == mbx.STATE_DONE and self.ok and not aborted else 1


class Run(PiRun):
    def __init__(self, link, mbox_phys, scratch_phys, out_dir, bundle, tool, addrs, clock,
                 plan, core_clk, spi_open):
        super().__init__(link, mbox_phys, out_dir, bundle, tool, addrs, clock, plan or Plan(),
                         core_clk, spi_open, "P3FR")
        self.scratch = scratch_phys
        self.seed = SEED_BASE
        self.eff, self.merged = {}, {}
        self._last_eff = None
        self.pass_bytes = min(self.plan.pass_bytes, self.addrs.get("scratch_len", 1 << 30))
        self.chunk_bytes = min(self.plan.chunk_bytes, self.addrs.get("scratch_len", 1 << 30))
        self.ceil = None
        self.work = None

    # -- plumbing -------------------------------------------------------------------------

    def seeds(self, n):
        """Contiguous fresh seeds: a call with N passes uses seed0..seed0+N-1."""
        s = self.seed
        self.seed = (self.seed + n) & 0xFFFFFFFF
        return s

    def c(self, fn, *args, **kw):
        """One spi303 call: gate and heartbeat around it, its own stop=1 means state != 1."""
        self.gate()
        self.hb.tick()
        rows = fn(*args, **kw)
        if any(t in ("C3EN", "C3SM") and kv.get("stop") == 1 for t, kv in rows):
            raise StateChanged()
        self.hb.tick()
        return rows

    def pattern(self, seed, n):
        """link.pattern bytes, generated in 4000-byte steps with the heartbeat between."""
        x = (seed or 1) & 0xFFFFFFFF
        out = bytearray()
        while len(out) < n:
            for _ in range(min(lk.MAX_CHUNK, n - len(out))):
                x ^= (x << 13) & 0xFFFFFFFF
                x ^= x >> 17
                x ^= (x << 5) & 0xFFFFFFFF
                out.append(x & 0xFF)
            self.hb.tick()
        return bytes(out)

    def read_hb(self, phys, n, bram=None):
        """2 MHz read in 4000-byte transactions, heartbeat between them."""
        out = bytearray()
        for off in range(0, n, lk.MAX_CHUNK):
            k = min(lk.MAX_CHUNK, n - off)
            if bram is None:
                out += self.link.read_mem(phys + off, k, lk.HDR_HZ)
            else:
                out += self.link.bram_read(bram, phys + off, k, lk.HDR_HZ)
            self.hb.tick()
        return bytes(out)

    # -- rates ----------------------------------------------------------------------------

    def eff_of(self, req):
        """Effective rate from 512- and 4000-byte payload writes, median of eff_reps each."""
        if req in self.eff:
            return self.eff[req]
        reps = self.plan.eff_reps
        ts = []
        for n in (EFF_SHORT, EFF_LONG):
            rows = self.c(self.tool.write, self.scratch, n, req, n, self.seeds(reps), reps,
                          self.mbox)
            ns = [kv["ns"] for t, kv in rows if t == "C3WP"]
            if len(ns) != reps:
                raise ToolError(rows)
            ts.append(int(statistics.median(ns)))
        e = eff_rate(*ts)
        prev = self._last_eff
        merged = int(bool(prev and e and abs(e - prev) <= MERGE_TOL * prev))
        if not merged:
            self._last_eff = e
        self.eff[req], self.merged[req] = e, merged
        self.log.row("P3EF", req_hz=req, eff_hz=e, t512=ts[0], t4000=ts[1], merged=merged)
        return e

    def measure_ladder(self):
        """All effective rates up front: a lazy measurement would rewrite scratch[0:4000]
        under the read sweep's pattern."""
        self.step = "P3EF"
        for req in self.plan.ladder:
            self.eff_of(req)

    def sweep(self, measure, cap=None):
        """Slow to fast over the unmerged ladder, stopping two rates past the first failure;
        returns the fastest clean request below the first failure (0 when none)."""
        best, first_fail, past = 0, None, 0
        for req in self.plan.ladder:
            if cap is not None and req > cap:
                break
            self.gate()
            eff = self.eff[req]         # measured for the whole ladder before any sweep
            if self.merged[req]:
                continue
            clean = measure(req, eff)
            if clean and first_fail is None:    # a pass above a failure is a marginal link
                best = req
            if first_fail is not None:
                past += 1
                if past >= STOP_PAST:
                    break
            elif not clean:
                first_fail = req
        return best

    def run_write(self, hz, chunk=None, nbytes=None, passes=None, seed0=None):
        """One C write run: passes x nbytes, each pass verified at 2 MHz; summed row."""
        chunk = chunk or self.plan.chunk
        nbytes = nbytes or self.pass_bytes
        passes = passes or self.plan.passes
        seed0 = self.seeds(passes) if seed0 is None else seed0
        rows = self.c(self.tool.write, self.scratch, nbytes, hz, chunk, seed0, passes, self.mbox)
        ps = [kv for t, kv in rows if t == "C3WP"]
        if len(ps) != passes:
            raise ToolError(rows)
        return self._sum(ps)

    @staticmethod
    def _sum(ps):
        a = {"bytes": 0, "ns": 0, "mis": 0, "bad_tx": 0, "first_tx": -1, "first": -1, "shift": 0}
        for p in ps:
            if p["bad_tx"] and a["first_tx"] < 0:
                a.update(first_tx=p["pass"] * p["ntx"] + p["first_tx"], first=p["first"],
                         shift=p["shift"])
            for k in ("bytes", "ns", "mis", "bad_tx"):
                a[k] += p[k]
        return a

    def runs(self, req, eff, tag, **extra):
        """clean_runs 1 MB runs at req; a failing run ends the rate."""
        for rep in range(self.plan.clean_runs):
            a = self.run_write(req)
            if tag == "P3WS":
                self.log.row(tag, req_hz=req, eff_hz=eff, bytes=a["bytes"], ns=a["ns"],
                             mis=a["mis"], bad_tx=a["bad_tx"], first_tx=a["first_tx"],
                             first=a["first"], shift=a["shift"], rep=rep)
            else:
                self.log.row(tag, **extra, req_hz=req, eff_hz=eff, mis=a["mis"],
                             bad_tx=a["bad_tx"], shift=a["shift"], rep=rep)
            if a["mis"]:
                return False
        return True

    # -- steps ----------------------------------------------------------------------------

    def framing(self):
        try:
            st = [kv for t, kv in self.tool.selftest(self.scratch) if t == "C3ST"]
            self.hb.tick()
            nr = _nr_test(self.link)
            self.hb.tick()
        except ToolError as e:
            self.log_c3er(e.rows)
            return False
        except (lk.LinkError, mbx.MailboxError, OSError):
            return False
        return bool(st) and st[0].get("ok") == 1 and nr == 1

    def log_c3er(self, rows):
        for t, kv in rows:
            if t == "C3ER":
                self.log.row(t, **kv)

    def sram_sweep(self):
        self.step = "P3WS"
        return self.sweep(lambda req, eff: self.runs(req, eff, "P3WS"))

    def bank7_sweep(self):
        self.step = "P3WB"

        def measure(req, eff):
            n = self.plan.b7_passes
            rows = self.c(self.tool.bram, 7, req, n, self.seeds(n), self.mbox)
            ps = [kv for t, kv in rows if t == "C3BP"]
            if len(ps) != n:
                raise ToolError(rows)
            bad = [p["pass"] for p in ps if p["mis"]]
            self.log.row("P3WB", req_hz=req, eff_hz=eff, passes=len(ps), badpasses=len(bad),
                         first_pass=bad[0] if bad else -1)
            return not bad
        return self.sweep(measure)

    def read_sweep(self):
        """Pattern written once at 2 MHz (verified), then read with the payload at each rate."""
        self.step = "P3RD"
        seed = self.seeds(1)
        if self.run_write(lk.HDR_HZ, passes=1, seed0=seed)["mis"]:
            self.log.skip("P3RD", "PATTERN")
            self.ok = False
            return 0

        def measure(req, eff):
            p = self.plan.passes
            rows = self.c(self.tool.read, self.scratch, self.pass_bytes, req, self.plan.chunk,
                          seed, p, self.mbox)
            ps = [kv for t, kv in rows if t == "C3RP"]
            if len(ps) != p:
                raise ToolError(rows)
            a = self._sum(ps)
            self.log.row("P3RD", req_hz=req, eff_hz=eff, bytes=a["bytes"], mis=a["mis"],
                         ns=a["ns"], bad_tx=a["bad_tx"], shift=a["shift"])
            return not a["mis"]
        return self.sweep(measure)

    def chunk_sizes(self):
        self.step = "P3CH"
        for c in self.plan.chunks:
            a = self.run_write(self.ceil, chunk=c, nbytes=self.chunk_bytes, passes=1)
            self.log.row("P3CH", chunk=c, bytes=a["bytes"], ns=a["ns"], hz=self.ceil,
                         mis=a["mis"])

    def py_write(self, hz, chunk, nbytes, passes):
        """Script-level path: link.py's two-transfer ioctl per transaction, timed writes only."""
        ps = []
        base = self.scratch
        for p in range(passes):
            self.gate()
            want = self.pattern(self.seeds(1), nbytes)
            self.gate()                 # pattern() can take seconds on the Pi
            ns = ntx = 0
            for off in range(0, nbytes, chunk):
                t0 = self.clock.time()
                self.link.write_mem(base + off, want[off:off + chunk], hz)
                ns += self.clock.time() - t0
                ntx += 1
                self.hb.tick()
            got = self.read_hb(base, nbytes)
            a = {"pass": p, "ntx": ntx, "bytes": nbytes, "ns": int(round(ns * 1e9)), "mis": 0,
                 "bad_tx": 0, "first_tx": -1, "first": -1, "shift": 0}
            for tx, off in enumerate(range(0, nbytes, chunk)):
                m, f, s = cmp_tx(want[off:off + chunk], got[off:off + chunk])
                if m:
                    if not a["bad_tx"]:
                        a.update(first_tx=tx, first=f, shift=s)
                    a["mis"] += m
                    a["bad_tx"] += 1
            ps.append(a)
        return self._sum(ps)

    def python_path(self):
        self.step = "P3WP"

        def measure(req, eff):
            a = self.py_write(req, self.plan.chunk, self.pass_bytes, self.plan.passes)
            self.log.row("P3WP", req_hz=req, eff_hz=eff, bytes=a["bytes"], ns=a["ns"],
                         mis=a["mis"], bad_tx=a["bad_tx"], first_tx=a["first_tx"],
                         first=a["first"], shift=a["shift"])
            return not a["mis"]
        self.sweep(measure, cap=self.ceil)
        self.step = "P3CP"
        for c in self.plan.chunks:
            a = self.py_write(self.ceil, c, self.chunk_bytes, 1)
            self.log.row("P3CP", chunk=c, bytes=a["bytes"], ns=a["ns"], hz=self.ceil,
                         mis=a["mis"])

    # -- handover -------------------------------------------------------------------------

    def wait_leader(self, want):
        end = self.clock.time() + LEADER_WAIT_S
        while self.clock.time() < end:
            head, ready = self.mb.ready_head()
            if not ready:
                raise StateChanged()
            if head[mbx.OFF_LEADER] == want:
                return True
            self.hb.tick()
            self.clock.sleep(POLL_S)
        return False

    def handover(self):
        """Follow the Next's lead until YIELD and leader 0."""
        self.step = "P3HO"
        self.gate()
        self.mb.send(mbx.CMD_HANDOVER, idle=self.hb.tick)
        if not self.wait_leader(1):
            self.log.skip("P3HO", "NOLEAD")
            self.ok = False
            return
        last, nxt = self.clock.time(), None
        while True:
            cmd, nxt = nxt, None
            if cmd is None:
                head, ready = self.mb.ready_head()
                if not ready:
                    raise StateChanged()
                if head[mbx.OFF_LEADER] != 1:
                    raise Lost("P3HO", "LEADER")
                cmd = pending(head)
            if cmd is None:
                if self.clock.time() - last > FOLLOW_IDLE_S:
                    raise Lost("P3HO", "TIMEOUT")
                self.hb.tick()
                self.clock.sleep(POLL_S)
                continue
            if cmd.cmd == mbx.CMD_QUIET:
                self.quiet(cmd)
            elif cmd.cmd == mbx.CMD_STREAM:
                nxt = self.stream(cmd)
            elif cmd.cmd == mbx.CMD_YIELD:
                self.mb.ack(cmd)
                if not self.wait_leader(0):
                    raise Lost("P3HO", "NOYIELD")
                return
            else:
                self.mb.ack(cmd)
            last = self.clock.time()

    def quiet(self, cmd):
        """Ack (read-back included), then zero SPI transfers for arg32 us."""
        us = min(cmd.arg32, QUIET_MAX_US)
        self.mb.ack(cmd)
        self.hb.suspend()
        self.clock.sleep(us / 1e6)
        self.hb.resume()
        self.log.row("P3HQ", row=cmd.arg0, us=us)

    def target(self, row, tgt):
        """(spi303 target, bytes) for STREAM; S rewrites the row's own bytes unchanged."""
        a = self.addrs
        if tgt == 0:
            return "0x%X" % a.get("u_phys", self.scratch), self.pattern(self.seeds(1),
                                                                        self.plan.u_len)
        if tgt == 2:
            return "bram7", self.pattern(self.seeds(1), B7_LEN)
        if tgt != 1:
            return None
        sram = {"row_np": ("sled_phys", "sled_len"), "row_rs": ("rs_phys", "rs_len"),
                "row_lr": ("lr_src_phys", "lr_len")}
        for key, (p, n) in sram.items():
            if a.get(key) == row and p in a and n in a:
                return "0x%X" % a[p], self.read_hb(a[p], a[n])
        if a.get("row_r5") == row and "r5_off" in a and "r5_len" in a:
            return "bram5:0x%X" % a["r5_off"], self.read_hb(a["r5_off"], a["r5_len"], bram=5)
        if a.get("row_bf") == row and "bf_dst_phys" in a and "bf_len" in a:
            return "0x%X" % a["bf_dst_phys"], bytes([a.get("fill_val", 0) & 0xFF]) * a["bf_len"]
        return None

    def stream(self, cmd):
        """Stream from the ack to STOP; ack only once spi303 has bumped hb_pi (started).
        Returns a command that arrived instead of STOP, else None."""
        spec = self.target(cmd.arg0, cmd.arg1)
        proc, started = None, False
        hz = self.ceil or lk.HDR_HZ
        if spec is None:
            self.log.skip("P3HS", "BADTGT")
        else:
            tgt, data = spec
            src = os.path.join(self.work, "S%02X_%d.bin" % (cmd.arg0, cmd.arg1))
            with open(src, "wb") as f:
                f.write(data)
            hb0 = self.mb.hb_pi()
            self.hb.suspend()
            proc = self.tool.stream(tgt, len(data), hz, src, self.mbox)
            self.streams.append(proc)
            started = self.wait_started(proc, hb0)
            if not started:
                self.log.skip("P3HS", "NOSTART")
                self.ok = False
        self.hb.suspend()               # spi303 owns hb_pi until STOP; none if it never started
        end_cmd, gone = None, None
        try:
            self.mb.ack(cmd)
            end_cmd = self.await_stop()
        except StateChanged as e:
            gone = e
        rows = []
        if proc is not None:
            rows = proc.stop()
            self.streams.remove(proc)
            self.log_c3er(rows)
        sm =[kv for t, kv in rows if t == "C3SM"]
        if started and sm:
            s = sm[0]
            self.log.row("P3HS", row=cmd.arg0, tgt=cmd.arg1, hz=hz, bytes=s["bytes"],
                         passes=s["passes"], ntx=s["ntx"], ns=s["ns"], stop=s["stop"])
        elif started:
            self.log.skip("P3HS", "NOROW")
        if gone is None and sm and sm[0]["stop"] == 1:
            gone = StateChanged()       # spi303 read state != 1: no ack after that
        if gone is not None:
            raise gone
        self.hb.resume()
        if end_cmd.cmd == mbx.CMD_STOP:
            self.mb.ack(end_cmd)
            return None
        return end_cmd

    def stop_streams(self):
        while self.streams:
            self.streams.pop().stop()

    def wait_started(self, proc, hb0):
        end = self.clock.time() + STREAM_START_S
        while self.clock.time() < end:
            if self.mb.hb_pi() != hb0:
                return True
            if not proc.alive():
                return False
            self.clock.sleep(POLL_S)
        return False

    def await_stop(self):
        last = self.clock.time()
        while True:
            self.clock.sleep(STREAM_POLL_S)
            head, ready = self.mb.ready_head()
            if not ready:
                raise StateChanged()
            cmd = pending(head)
            if cmd is not None:
                return cmd
            if self.clock.time() - last > FOLLOW_IDLE_S:
                raise Lost("P3HO", "NOSTOP")

    # -- starvation -----------------------------------------------------------------------

    def starvation(self):
        for p in self.plan.profiles:
            self.step = "P3SV"
            self.gate()
            self.mb.send(mbx.CMD_LOAD, arg0=p, idle=self.hb.tick)
            self.idle(LOAD_SETTLE_S)
            hzs = []
            for hz in (self.ceil,) + tuple(self.plan.starve_hz):
                if hz and hz not in hzs:
                    hzs.append(hz)
            for hz in hzs:
                n0 = self.mb.read_hb_next()
                a = self.run_write(hz)
                if self.mb.read_hb_next() == n0:
                    self.log.skip("P3SV", "NOLOAD prof=%d hz=%d" % (p, hz))
                    continue
                self.log.row("P3SV", prof=p, hz=hz, bytes=a["bytes"], ns=a["ns"], mis=a["mis"],
                             bad_tx=a["bad_tx"], first_tx=a["first_tx"], shift=a["shift"])
            self.step = "P3SC"
            n0 = self.mb.read_hb_next()
            best = self.sweep(lambda req, eff: self.runs(req, eff, "P3SR", prof=p))
            if self.mb.read_hb_next() == n0:
                self.log.skip("P3SC", "NOLOAD prof=%d" % p)
            else:
                self.log.row("P3SC", prof=p, ceiling_hz=best)
            self.gate()
            self.mb.send(mbx.CMD_STOP, idle=self.hb.tick)

    # -- run ------------------------------------------------------------------------------

    def steps(self):
        self.measure_ladder()
        sram = self.sram_sweep()
        b7 = self.bank7_sweep()
        rd = self.read_sweep()
        self.log.row("P3CE", sram_hz=sram, b7_hz=b7, read_hz=rd)
        self.ceil = sram or None
        if self.ceil:
            self.chunk_sizes()
            self.python_path()
        else:
            for t in ("P3CH", "P3WP", "P3CP"):
                self.log.skip(t, "NOCEIL")
        self.handover()
        self.starvation()

    def go(self):
        self.log = open_log(os.path.join(self.out_dir, LOG_NAME), TOOL, self.bundle, self.link,
                            None, 0, None, self.spi_open())
        try:
            try:
                ver, caps = self.link.version()
            except (lk.LinkError, OSError):
                self.log.skip("P3FR", "LINK")
                return 1
            hz, src = self.core_clk()
            self.log.spi(ver, caps, hz, src)
            if not self.wait_ready():
                self.log.skip("P3MB", "NOMBOX")
                return 1
            self.hb.tick()
            if not self.framing():
                self.log.skip("P3FR", "FRAMING")
                return 1
            self.log.row("P3TE", est_s=estimate_s(self.plan), rates=len(self.plan.ladder))
            self.work = tempfile.mkdtemp(prefix="p303spi")
            aborted = False
            try:
                self.steps()
            except StateChanged:
                self.log.skip("PIST", "STATE")
                aborted = True
            except Lost as e:
                self.log.skip(e.tag, e.reason)
                self.ok = False
            except ToolError as e:
                for t, kv in e.rows:
                    if t == "C3ER":
                        self.log.row(t, **kv)
                self.log.skip(self.step, "TOOL")
                self.ok = False
            except (lk.LinkError, mbx.MailboxError, OSError):
                self.log.skip(self.step, "LINK")
                self.ok = False
            self.stop_streams()         # a live stream would keep hb_pi moving past the END
            return self.finish(aborted)
        finally:
            self.stop_streams()
            self.log.close()
            if self.work:
                shutil.rmtree(self.work, ignore_errors=True)


def main(link, mbox_phys, scratch_phys, out_dir, bundle, c_tool, addrs=None, clock=None,
         plan=None, core_clk=None, spi_open=None):
    """c_tool: an spi303 path or a tool object; addrs: the PI303.MAP keys."""
    tool = SpiTool(c_tool) if isinstance(c_tool, str) else c_tool
    return Run(link, mbox_phys, scratch_phys, out_dir, bundle, tool, addrs, clock, plan,
               core_clk or default_core_clk, spi_open or default_spi_open).go()


def cli(argv=None, link_factory=None):
    ap = argparse.ArgumentParser(prog=TOOL)
    ap.add_argument("--map", required=True, help="PI303.MAP from the staged build")
    ap.add_argument("--tool", default=os.path.join(HERE, "spi303"))
    ap.add_argument("--out", default=".")
    ap.add_argument("--bundle", default=None)
    a = ap.parse_args(argv)
    bundle = a.bundle or bundle_hash(HERE)
    addrs = read_map(a.map)
    link = (link_factory or (lambda: lk.SpidevLink(py_ioctl=True)))()
    try:
        link.open()
    except lk.BusBusy:
        write_busy(a.out, LOG_NAME, TOOL, bundle)
        return 2
    try:
        return main(link, addrs["mbox_phys"], addrs["scratch_phys"], a.out, bundle,
                    SpiTool(a.tool), addrs=addrs)
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(cli())
