"""Host model for the pi303_video tests (not in the bundle).

VLink: sim_pi303's WorldLink with a raster clock (311 lines at the bench's 49.36 Hz) and a
forced-loss switch. NextV: a PI303V follower (LOAD 0/6, STOP, END, restore_all settle).
WorldServe: spi303 serve's pipe framing, running the C push loops over the same link.
"""
import os
import struct

import numpy as np

import link
import mailbox as mbx
import pi303_video as pv
import sim_pi303 as sp
from link import HDR_HZ, build_header
from pilog import PiLogWriter

MB = sp.MB
RESULT = sp.RESULT
BUNDLE = sp.BUNDLE
FRONT_BANK, BACK_BANK = 19, 22
L2_LEN = 0xC000
PERIOD = 1 / 49.36
LINES = 311

MAP = dict(mbox_phys=MB, l2_front_phys=(FRONT_BANK + 16) * 0x4000,
           l2_back_phys=(BACK_BANK + 16) * 0x4000, l2_front_bank=FRONT_BANK,
           l2_back_bank=BACK_BANK, l2_len=L2_LEN, l2_fill=2, mix_src_phys=0x84000,
           mix_dst_phys=0x86000, mix_len=0x2000, bank5_save_phys=0x88000, b5_off=0x2000,
           b5_len=0x100, result_phys_region=RESULT, result_len_max=0xBF00, prof_halt=0,
           prof_mix=6)

PLAN = pv.Plan(soak_bytes=3 * L2_LEN, period_wraps=10)
CEILINGS = {0: 7_500_000, 1: 7_500_000}


def raster_line(t):
    return int((t % PERIOD) / PERIOD * LINES)


class VLink(sp.WorldLink):
    def __init__(self, world, **kw):
        super().__init__(world, **kw)
        self.force = False                  # lose byte 100 of every transaction while set
        self.raster = lambda: raster_line(world.t)
        self.nr_log = []                    # (t, reg, value) per NextReg write

    def xfer(self, header, payload, n_rx, hz, header_hz=HDR_HZ):
        if header[0] == link.CMD_NR_W:
            self.nr_log.append((self.world.t, header[1], header[2]))
        return super().xfer(header, payload, n_rx, hz, header_hz)

    def _lose(self, tx, i):
        if self.force and i == 100:
            return True
        return super()._lose(tx, i)


class NextV(sp.NextModel):
    """PI303V follower: hb_next every frame (stalled under a load when asked)."""

    def __init__(self, world, lk, stall_load=False, **kw):
        self.stall_load = stall_load
        self.active = False
        self.bad = 0
        super().__init__(world, lk, script=[], **kw)
        lk.nrs[0x12], lk.nrs[0x13] = FRONT_BANK, BACK_BANK     # PI303V l2_setup

    def _init_regions(self):
        pass

    def _follow(self):
        if not (self.stall_load and self.active):
            struct.pack_into("<H", self.lk.sram, MB + 14, (self.r16(14) + 1) & 0xFFFF)
        if self.b(13) != 1:
            return
        seq = self.b(4)
        if seq == self.b(12):
            return
        cmd, a0 = self.b(5), self.b(6)
        self.events.append(("cmd", self.w.t, cmd, a0, self.b(18)))
        if self.state_on_cmd and cmd == self.state_on_cmd[0]:
            self.setb(13, self.state_on_cmd[1])
            self.mode, self.due = "done", None
            return
        if cmd == mbx.CMD_LOAD and a0 in (0, 6):
            self.load, self.active = a0, True
        elif cmd in (mbx.CMD_STOP, mbx.CMD_END):
            self.load, self.active = 0, False
        else:
            self.bad += 1
        self.setb(12, seq)
        if cmd == mbx.CMD_END:
            self.mode, self._gen = "exit", self._exit()
            next(self._gen)             # state 4 in the same step as the END ack (restore_all)


class WorldServe:
    """One spi303 serve process: requests timed in world time, C hb state kept per process."""

    def __init__(self, world, lk, argv):
        self.w, self.lk, self.argv = world, lk, argv
        self.stdin = self.stdout = self
        self.reply = bytearray()
        self.requests = []
        self.chb = {}
        self.closed = False
        self.loss_req = set()               # request indices whose transactions all lose a byte

    def write(self, buf):
        op, cmd = buf[0], buf[1]
        addr = int.from_bytes(buf[2:5], "little")
        n, hz = struct.unpack_from("<HI", buf, 5)
        body = bytes(buf[11:])
        req = dict(op=op, cmd=cmd, base=addr, hz=hz, t=self.w.t, i=len(self.requests))
        if op == link.OP_PUSH:
            total, flags, hb = struct.unpack_from("<IBI", body)
            frame = body[9:]
            assert len(frame) == total
            spans = [(off, frame[off:off + n]) for off in range(0, total, n)]
        elif op == link.OP_PUSHSPANS:
            flags, hb = struct.unpack_from("<BI", body)
            spans, pos = [], 5 + 5 * n
            for i in range(n):
                off = int.from_bytes(body[5 + 5 * i:8 + 5 * i], "little")
                ln = struct.unpack_from("<H", body, 8 + 5 * i)[0]
                for k in range(0, ln, link.MAX_CHUNK):
                    spans.append((off + k, body[pos + k:pos + min(ln, k + link.MAX_CHUNK)]))
                pos += ln
            assert pos == len(body)
        else:
            raise AssertionError("pi303_video sends only push and pushspans, got op %d" % op)
        req.update(verify=flags & link.PUSH_VERIFY, hb=hb,
                   spans=[(o, len(d)) for o, d in spans], data=spans)
        self.requests.append(req)
        t0 = self.w.t
        bad = 0
        c = self.chb.setdefault(hb, sp.CHb(self.w, self.lk, hb))
        for off, part in spans:
            if addr + off + len(part) > link.SRAM_SIZE:
                self.reply += struct.pack("<BH", 2, 0)
                return
        for off, part in spans:
            self.w.phase = "push"
            self.lk.force = req["i"] in self.loss_req
            try:
                self.lk.xfer(build_header(cmd, addr + off, len(part)), part, 0, hz)
            finally:
                self.lk.force = False
            if req["verify"]:
                t = min(16, len(part))
                self.w.phase = "verify"
                got = self.lk.xfer(build_header(cmd - 1, addr + off + len(part) - t, t), b"",
                                   t, HDR_HZ)
                bad += got != part[-t:]
            self.w.phase = "chb"
            c.tick()
        self.w.phase = None
        req.update(end=self.w.t, ntx=len(spans), bad=bad)
        ns = int(round((self.w.t - t0) * 1e9))
        self.reply += struct.pack("<BH", 0, 16) + struct.pack("<IIQ", len(spans), bad, ns)

    def flush(self):
        pass

    def read(self, n):
        out = bytes(self.reply[:n])
        del self.reply[:n]
        return out

    def close(self):
        self.closed = True

    def wait(self, timeout=None):
        return 0


class Spawner:
    def __init__(self, world, lk):
        self.w, self.lk = world, lk
        self.calls = []
        self.serves = []
        self.loss_req = set()

    def __call__(self, argv):
        self.calls.append(list(argv))
        s = WorldServe(self.w, self.lk, argv)
        s.loss_req = self.loss_req
        self.serves.append(s)
        return link.ServeHelper(s)


def make_frames(n, seed=404):
    """A random first frame, then 3 small changed blocks a frame (so N-1 and N-2 differ)."""
    rng = np.random.default_rng(seed)
    cur = rng.integers(0, 256, L2_LEN, dtype=np.uint8)
    out = [cur.tobytes()]
    for _ in range(1, n):
        cur = cur.copy()
        for _ in range(3):
            o = int(rng.integers(0, L2_LEN - 600))
            ln = int(rng.integers(1, 600))
            cur[o:o + ln] = rng.integers(0, 256, ln, dtype=np.uint8)
        out.append(cur.tobytes())
    return out


def write_frames(d, frames):
    os.makedirs(d, exist_ok=True)
    for i, f in enumerate(frames):
        with open(os.path.join(d, "F%03d.raw" % i), "wb") as fh:
            fh.write(f)
        with open(os.path.join(d, "F%03d.jpg" % i), "wb") as fh:
            fh.write(b"not used by P4")


def write_spi_log(path, ceilings, merged=()):
    log = PiLogWriter(str(path), "pi303_spi", BUNDLE)
    for h in pv.LADDER:
        log.row("P3EF", req_hz=h, eff_hz=h, t512=1, t4000=2, merged=int(h in merged))
    for p, c in sorted(ceilings.items()):
        log.row("P3SC", prof=p, ceiling_hz=c)
    log.close()


class Bench:
    def __init__(self, tmp, loss_above=None, ceilings=CEILINGS, merged=(), n_frames=6,
                 **next_kw):
        self.w = sp.World()
        self.lk = VLink(self.w, loss_above=loss_above)
        self.nx = NextV(self.w, self.lk, **next_kw)
        self.spawn = Spawner(self.w, self.lk)
        self.tmp = tmp
        self.frames = make_frames(n_frames)
        self.frames_dir = os.path.join(str(tmp), "frames")
        write_frames(self.frames_dir, self.frames)
        self.spi_log = os.path.join(str(tmp), "SPI.LOG")
        write_spi_log(self.spi_log, ceilings, merged)
        self.out = os.path.join(str(tmp), "out")
        os.makedirs(self.out, exist_ok=True)

    def run(self, plan=PLAN, addrs=MAP):
        return pv.main(self.lk, MB, self.frames_dir, self.spi_log, self.out, BUNDLE,
                       tool="spi303", addrs=addrs, clock=self.w, plan=plan,
                       core_clk=lambda: (0, "none"), spi_open=lambda: [], spawn=self.spawn)

    @property
    def serve(self):
        return self.spawn.serves[0]


def expected_gap(t1, l1, t2, l2):
    """Vertical blank starts between two flips from the model's own clock."""
    k = round((t2 - t1) / PERIOD - (l2 - l1) / LINES)
    return k + (l2 >= 192) - (l1 >= 192)


def bank_phys(bank):
    return (bank + 16) * 0x4000
