"""P4 end-to-end Pi video (Pi side): writes VIDEO.LOG, fetches PI_PI303V.LOG.
Per profile (LOAD 0, 6): frame period, 16 MB soak below P3's ceiling, tf/ts/vf/vs passes,
STOP; END last. Frames go through one spi303 serve; raster and NR $12/$13 at 2 MHz."""
import argparse
import os
import statistics
import sys
from dataclasses import dataclass

import numpy as np

import link as lk
import mailbox as mbx
import pi303_spi as spi
from bundle import dir_hash
from pi303_probe import (check_bundle, close_log, default_core_clk, default_spi_open, open_log,
                         write_busy)
from spans import span_list

TOOL = "pi303_video"
HERE = os.path.dirname(os.path.abspath(__file__))
LOG_NAME = "VIDEO.LOG"
RESULT_NAME = "PI_PI303V.LOG"

LADDER = spi.LADDER
VBL = 192                   # first vertical blank line (NR $1E/$1F)
LINES = 312                 # scales only the sub-frame term in vblanks(); 311 or 262 count alike
NR_L2_BANK, NR_L2_SHADOW = 0x12, 0x13
BANK_SIZE = 0x4000
MBOX_LEN = 0x2000
PASSES = {"tf": 0, "ts": 1, "vf": 2, "vs": 3}      # P4FR pass= codes
SOAK_SEED = 0x30400001
LOAD_WAIT_S = 2.0
FLIP_TIMEOUT_S = 0.5
PERIOD_TIMEOUT_S = 5.0

MAP_KEYS = ("mbox_phys", "l2_front_phys", "l2_back_phys", "l2_front_bank", "l2_back_bank",
            "l2_len", "l2_fill", "mix_src_phys", "mix_dst_phys", "mix_len", "bank5_save_phys",
            "b5_off", "b5_len", "result_phys_region", "result_len_max", "prof_halt", "prof_mix")

StateChanged, Lost = spi.StateChanged, spi.Lost


@dataclass(frozen=True)
class Plan:
    soak_bytes: int = 16 << 20
    period_wraps: int = 25
    ready_timeout_s: float = 120.0


def check_map(a):
    """Each buffer at its NR $12 bank's address ((bank + 16) x 16K, PI303V l2_setup), inside
    the Pi's 2 MB and clear of the other buffer, mailbox, LOAD 6 pages, save page and log."""
    n = a["l2_len"]
    bufs = [(a["l2_front_phys"], a["l2_front_bank"]), (a["l2_back_phys"], a["l2_back_bank"])]
    others = [(a["mbox_phys"], MBOX_LEN), (a["mix_src_phys"], a["mix_len"]),
              (a["mix_dst_phys"], a["mix_len"]), (a["bank5_save_phys"], MBOX_LEN),
              (a["result_phys_region"], a["result_len_max"])]
    for i, (phys, bank) in enumerate(bufs):
        if phys != (bank + 16) * BANK_SIZE or phys + n > lk.SRAM_SIZE:
            raise ValueError("Layer 2 buffer %#x bank %d" % (phys, bank))
        for p, m in others + [(bufs[1 - i][0], n)]:
            if phys < p + m and p < phys + n:
                raise ValueError("Layer 2 buffer %#x overlaps %#x+%#x" % (phys, p, m))


def read_map(path):
    """PI303V.MAP, checked: the buffers are the only memory frames and soaks write."""
    a = spi.read_map(path, MAP_KEYS)
    check_map(a)
    return a


def p3_ceilings(path):
    """P3SC ceiling_hz by P3 profile and the P3EF merged requests, from P3's SPI.LOG."""
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            text = f.read()
    except OSError:
        return {}, set()
    ceil, merged = {}, set()
    for tag, kv in spi.parse_rows(text):
        if tag == "P3SC" and "prof" in kv and "ceiling_hz" in kv:
            ceil[kv["prof"]] = kv["ceiling_hz"]
        elif tag == "P3EF" and kv.get("merged") == 1:
            merged.add(kv.get("req_hz"))
    return ceil, merged


def rates_below(ceiling, merged):
    """Ladder requests below the ceiling, fastest first; a merged request repeats a slower one."""
    return [h for h in reversed(LADDER) if h < ceiling and h not in merged]


def vblanks(t1, l1, t2, l2, period):
    """Vertical blank starts (line VBL) between raster reads (t1, l1) and (t2, l2)."""
    k = max(0, round((t2 - t1) / period - (l2 - l1) / LINES))
    return max(0, k + (l2 >= VBL) - (l1 >= VBL))


def soak_frame(seed, n):
    return np.random.default_rng(seed).integers(0, 256, n, dtype=np.uint8).tobytes()


def load_frames(d, n):
    """F*.raw from the P2 frame set, each one Layer 2 buffer long; at least 3 (two primes)."""
    names = sorted(f for f in os.listdir(d) if f.endswith(".raw"))
    frames = []
    for nm in names:
        with open(os.path.join(d, nm), "rb") as f:
            frames.append(f.read())
    if len(frames) < 3 or any(len(f) != n for f in frames):
        raise ValueError("frames: %d, sizes %s" % (len(frames), sorted({len(f) for f in frames})))
    return frames


class Run(spi.PiRun):
    """pi303_spi.PiRun gives gate, wait_ready, wait_done, fetch and finish."""
    RF_TAG = "P4RF"
    RESULT_NAME = RESULT_NAME

    def __init__(self, link, mbox_phys, frames_dir, spi_log, out_dir, bundle, tool, spawn,
                 addrs, clock, plan, core_clk, spi_open):
        super().__init__(link, mbox_phys, out_dir, bundle, tool, addrs, clock, plan or Plan(),
                         core_clk, spi_open, "P4SK")
        self.frames_dir, self.spi_log = frames_dir, spi_log
        self.spawn = spawn or lk.ServeHelper.spawn
        self.helper = None
        self.frames, self.full, self.spans = [], [], []
        self.ceil, self.merged = {}, set()
        self.shown = self.addrs["l2_front_bank"]    # PI303V starts with NR $12 = front
        self.obs = None                             # last raster read (t, line)
        self.since_flip = 1                         # vblank starts since the last flip
        self.period = None
        self.seed = SOAK_SEED

    # -- buffers and raster -----------------------------------------------------------------

    def hidden(self):
        """(bank, phys) of the buffer not in NR $12: the only one frames and soaks write."""
        a = self.addrs
        if self.shown == a["l2_front_bank"]:
            return a["l2_back_bank"], a["l2_back_phys"]
        return a["l2_front_bank"], a["l2_front_phys"]

    def push(self, item, hz, verify):
        """One serve exchange into the hidden buffer: a frame (bytes) or a span list.
        Timed passes give the C side no hb address; Python bumps between frames."""
        _, phys = self.hidden()
        hb = self.mbox if verify else 0
        if isinstance(item, bytes):
            return self.helper.push(lk.CMD_SRAM_W, phys, item, hz, verify=verify, hb=hb)[1:]
        return self.helper.pushspans(lk.CMD_SRAM_W, phys, item, hz, verify=verify, hb=hb)[1:]

    def raster(self):
        t0 = self.clock.time()
        line = self.link.raster_line()
        t = (t0 + self.clock.time()) / 2
        if self.obs is not None and self.period:
            self.since_flip += vblanks(*self.obs, t, line, self.period)
        self.obs = (t, line)
        return line

    def flip(self):
        """Poll (hb ticks between polls) to a vertical blank not yet flipped in, NR $12 = the
        bank just written, NR $13 = the other, read the raster again. Returns (l0, l1, in_vbl,
        gap, late, t); in_vbl needs both reads in the same vertical blank."""
        bank, _ = self.hidden()
        other = self.shown
        end = self.clock.time() + FLIP_TIMEOUT_S
        l0 = self.raster()
        c0 = self.since_flip
        while not (l0 >= VBL and self.since_flip >= 1):
            if self.clock.time() >= end:
                raise Lost(self.step, "RASTER")
            self.hb.tick()
            l0 = self.raster()
        gap, late = self.since_flip, self.since_flip - c0 > 1
        t = self.clock.time()
        self.link.nr_write(NR_L2_BANK, bank)
        self.link.nr_write(NR_L2_SHADOW, other)
        self.shown = bank
        self.since_flip = 0
        l1 = self.raster()
        in_vbl = l0 >= VBL and l1 >= VBL and self.since_flip == 0
        return l0, l1, in_vbl, gap, late, t

    def measure_period(self):
        """Median interval of period_wraps raster wraps (line falls); None if they never come."""
        wraps, prev = [], None
        end = self.clock.time() + PERIOD_TIMEOUT_S
        while len(wraps) <= self.plan.period_wraps:
            if self.clock.time() >= end:
                return None
            self.gate()
            t0 = self.clock.time()
            line = self.link.raster_line()
            t = (t0 + self.clock.time()) / 2
            if prev is not None and line < prev:
                wraps.append(t)
            prev = line
            self.hb.tick()
        return statistics.median([b - a for a, b in zip(wraps, wraps[1:])])

    # -- steps ----------------------------------------------------------------------------

    def load_frames(self):
        n = self.addrs["l2_len"]
        self.frames = load_frames(self.frames_dir, n)
        f = self.frames
        self.full = [(i, f[i], n) for i in range(len(f))]
        # PI303V double-buffers: the hidden buffer holds frame N-2 once 0 and 1 are primed
        self.spans = []
        for i in range(2, len(f)):
            s = span_list(f[i - 2], f[i])
            self.spans.append((i, s, sum(len(d) for _, d in s)))

    def load_moving(self):
        n0 = self.mb.read_hb_next()
        end = self.clock.time() + LOAD_WAIT_S
        while self.clock.time() < end:
            self.gate()
            self.hb.tick()
            self.clock.sleep(0.05)
            if self.mb.read_hb_next() != n0:
                return True
        return False

    def soak(self, prof, hz, frame_ns):
        """Up to soak_bytes of fresh data, l2_len a push, verified, into the hidden buffer
        only; stops after the push holding the first bad transaction (C runs whole pushes)."""
        n = self.addrs["l2_len"]
        count = -(-self.plan.soak_bytes // n)
        mis = done = 0
        while done < count and not mis:
            self.gate()
            self.hb.tick()
            data = soak_frame(self.seed, n)
            self.seed += 1
            self.hb.tick()
            mis += self.push(data, hz, True)[0]
            done += 1
        self.log.row("P4SK", prof=prof, hz=hz, mis=mis, bytes=done * n, frame_ns=frame_ns)
        return mis

    def prime(self, prof, hz, tag):
        """Untimed: full frames 0 and 1, one per buffer, verified; one retry, else skip."""
        self.step = tag
        for _ in range(2):
            bad = 0
            for i in (0, 1):
                self.gate()
                self.hb.tick()
                bad += self.push(self.frames[i], hz, True)[0]
                self.flip()
            if not bad:
                return True
        self.log.skip(tag, "PRIME prof=%d" % prof)
        self.ok = False
        return False

    def run_pass(self, prof, name, hz, items):
        """One serve exchange and one flip a frame. Timed: drop = flip outside vblank or
        past its intended one; verified: drop = any tail mismatch."""
        verify = name[0] == "v"
        tag = "P4" + name.upper()
        self.step = tag
        frames = vbl = dropped = 0
        gaps = [0, 0, 0]
        t0 = t = None
        fr = []                     # P4FR rows, written after the pass: no log I/O inside it
        try:
            for k, (idx, item, nbytes) in enumerate(items):
                self.gate()
                self.hb.tick()
                if t0 is None:
                    t0 = self.clock.time()
                bad, ns = self.push(item, hz, verify)
                l0, l1, in_vbl, gap, late, t = self.flip()
                self.hb.tick()
                drop = int(bad > 0) if verify else int(not in_vbl or late)
                frames += 1
                vbl += in_vbl
                dropped += drop
                if k:
                    gaps[min(max(gap, 1), 3) - 1] += 1
                fr.append({"pass": PASSES[name], "prof": prof, "idx": idx, "ns": ns,
                           "bytes": nbytes, "l0": l0, "l1": l1, "drop": drop})
        finally:
            for r in fr:
                self.log.row("P4FR", **r)
        if verify:
            self.log.row(tag, prof=prof, frames=frames, bad=dropped)
        else:
            self.log.row(tag, prof=prof, frames=frames,
                         ns=int(round((t - t0) * 1e9)) if frames else 0, flips_vbl=vbl,
                         gap1=gaps[0], gap2=gaps[1], gap3=gaps[2])

    def profile(self, prof, p3prof):
        self.step = "P4SK"
        if p3prof not in self.ceil:
            self.log.skip("P4SK", "NOP3 prof=%d" % prof)
            self.ok = False
            return
        rates = rates_below(self.ceil[p3prof], self.merged)
        if not rates:
            self.log.skip("P4SK", "FLOOR prof=%d" % prof)
            self.ok = False
            return
        self.gate()
        self.mb.send(mbx.CMD_LOAD, arg0=prof, idle=self.hb.tick)
        self.loaded(prof, rates)
        self.gate()
        self.mb.send(mbx.CMD_STOP, idle=self.hb.tick)

    def loaded(self, prof, rates):
        if not self.load_moving():
            self.log.skip("P4SK", "NOLOAD prof=%d" % prof)
            self.ok = False
            return
        period = self.measure_period()
        if not period:
            self.log.skip("P4SK", "RASTER prof=%d" % prof)
            self.ok = False
            return
        self.period = period
        frame_ns = int(round(period * 1e9))
        hz = next((r for r in rates if self.soak(prof, r, frame_ns) == 0), None)
        if hz is None:
            self.log.skip("P4SK", "FLOOR prof=%d" % prof)
            self.ok = False
            return
        self.run_pass(prof, "tf", hz, self.full)
        if self.prime(prof, hz, "P4TS"):
            self.run_pass(prof, "ts", hz, self.spans)
        self.run_pass(prof, "vf", hz, self.full)
        if self.prime(prof, hz, "P4VS"):
            self.run_pass(prof, "vs", hz, self.spans)

    def runs(self):
        """Both profiles, only once NR $12 shows the front bank: no buffer of unknown
        visibility is ever written."""
        shown = self.link.nr_read(NR_L2_BANK) & 0x7F
        if shown != self.addrs["l2_front_bank"]:
            self.log.skip("P4SK", "SHOWN nr12=%d" % shown)
            self.ok = False
            return
        self.helper = self.spawn([self.tool, "serve"])
        a = self.addrs
        for prof, p3prof in ((a["prof_halt"], 0), (a["prof_mix"], 1)):
            self.profile(prof, p3prof)

    def close_helper(self):
        """Reap the serve child, then log its stderr C3ER/C3MX rows (C3MX: spidev restore)."""
        if self.helper is not None:
            h, self.helper = self.helper, None
            try:
                h.close()
            finally:
                for t, kv in spi.parse_rows(h.err_text):
                    if t in ("C3ER", "C3MX"):
                        self.log.row(t, **kv)

    def go(self):
        self.log = open_log(os.path.join(self.out_dir, LOG_NAME), TOOL, self.bundle, self.link,
                            None, 0, None, self.spi_open())
        try:
            try:
                ver, caps = self.link.version()
            except (lk.LinkError, OSError):
                self.log.skip("P4MB", "LINK")
                return 1
            hz, src = self.core_clk()
            self.log.spi(ver, caps, hz, src)
            try:
                self.load_frames()
            except (OSError, ValueError):
                self.log.skip("P4TF", "FRAMES")
                return 1
            self.log.env(frames=len(self.frames), frames_hash=dir_hash(self.frames_dir))
            self.ceil, self.merged = p3_ceilings(self.spi_log)
            if not self.wait_ready():
                self.log.skip("P4MB", "NOMBOX")
                return 1
            self.hb.tick()
            aborted = False
            try:
                self.runs()
            except StateChanged:
                self.log.skip("PIST", "STATE")
                aborted = True
            except Lost as e:
                self.log.skip(e.tag, e.reason)
                self.ok = False
            except (lk.LinkError, mbx.MailboxError, OSError):
                self.log.skip(self.step, "LINK")
                self.ok = False
            self.close_helper()         # no C-side hb_pi bump once the END wait starts
            return self.finish(aborted)
        finally:
            self.close_helper()
            close_log(self.log, self.link)


def main(link, mbox_phys, frames_dir, spi_log, out_dir, bundle, tool=None, addrs=None,
         clock=None, plan=None, core_clk=None, spi_open=None, spawn=None):
    """tool: the spi303 path, spawned once as `spi303 serve`; addrs: the PI303V.MAP keys."""
    if addrs is None:
        raise ValueError("addrs (PI303V.MAP) required")
    return Run(link, mbox_phys, frames_dir, spi_log, out_dir, bundle,
               tool or os.path.join(HERE, "spi303"), spawn, addrs, clock, plan,
               core_clk or default_core_clk, spi_open or default_spi_open).go()


def cli(argv=None, link_factory=None):
    ap = argparse.ArgumentParser(prog=TOOL)
    ap.add_argument("--map", required=True, help="PI303V.MAP from the staged build")
    ap.add_argument("--spi-log", required=True, help="SPI.LOG from the P3 run (P3SC ceilings)")
    ap.add_argument("--frames", required=True, help="the P2 frame set (F*.raw)")
    ap.add_argument("--tool", default=os.path.join(HERE, "spi303"))
    ap.add_argument("--out", default=".")
    ap.add_argument("--bundle", default=None)
    a = ap.parse_args(argv)
    bundle = check_bundle(a.bundle, a.out, LOG_NAME, TOOL, "P4MB")
    if bundle is None:
        return 1
    addrs = read_map(a.map)
    link = (link_factory or lk.SpidevLink)()
    try:
        link.open()
    except lk.BusBusy:
        write_busy(a.out, LOG_NAME, TOOL, bundle)
        return 2
    try:
        return main(link, addrs["mbox_phys"], a.frames, a.spi_log, a.out, bundle, a.tool,
                    addrs=addrs)
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(cli())
