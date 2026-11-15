"""Host model for the pi303_spi tests (not in the bundle).

World: a fake clock whose sleeps and transfers run background actors. WorldLink: SimLink
with an even-divisor rate model, a timed trace and loss above a rate. NextModel: a scripted
PI303 mailbox (follower-first, HANDOVER, QUIET, STREAM/STOP, YIELD, LOAD, END, state 4
then 2/3). FakeTool: spi303's write/read/bram/selftest/stream loops over the same link.
"""
import math
import struct
from collections import namedtuple

import link
import mailbox as mbx
import pi303_spi
import sim
from link import HDR_HZ, build_header

CORE_HZ = 250_000_000
TX_OVH_S = 50e-6
FRAME_S = 0.02
SPAWN_S = 0.005             # process start before spi303 stream's first hb_pi bump
MB = 0x80000
SCRATCH = 0xA0000
RESULT = 0xE4000
BUNDLE = "0123456789ab"

MAP = dict(mbox_phys=MB, scratch_phys=SCRATCH, scratch_len=0x40000, u_phys=SCRATCH,
           sled_phys=0x88000, sled_len=0x100, rs_phys=0x90000, rs_len=0x80,
           r5_off=0x2000, r5_len=0x80, lr_src_phys=0x90800, lr_len=0x40,
           bf_dst_phys=0x91000, bf_len=0x100, fill_val=0x3C, bank7_save_phys=0x94000,
           bank5_save_phys=0x97000, result_phys_region=RESULT, result_len_max=0xBF00,
           row_np=0, row_rs=1, row_r5=2, row_lr=3, row_bf=4, row_cal=5)

PLAN = pi303_spi.Plan(pass_bytes=8000, passes=4, clean_runs=3, b7_passes=2,
                      chunk_bytes=4096, u_len=512, eff_reps=5, profiles=(0, 1))

Q, S, STOP = mbx.CMD_QUIET, mbx.CMD_STREAM, mbx.CMD_STOP
# (cmd, row, target, quiet us, row seconds): CAL0, P3NP, U3NP, S3NP, B3NP, P3RS, S3RS..S3BF
SCRIPT = [(Q, 5, 0, 100_000, 0.05), (Q, 0, 0, 100_000, 0.05),
          (S, 0, 0, 0, 0.25), (S, 0, 1, 0, 0.25), (S, 0, 2, 0, 0.25),
          (Q, 1, 0, 120_000, 0.05), (S, 1, 1, 0, 0.25), (S, 2, 1, 0, 0.25),
          (S, 3, 1, 0, 0.25), (S, 4, 1, 0, 0.25)]

Rec = namedtuple("Rec", "t end cmd addr n header_hz payload_hz data actor phase")


def actual_hz(hz):
    d = math.ceil(CORE_HZ / hz)
    if d % 2:
        d += 1
    return CORE_HZ / d


class World:
    def __init__(self):
        self.t = 0.0
        self.actors = []
        self.hooks = []
        self.in_actor = False
        self.phase = None

    def time(self):
        return self.t

    def sleep(self, s):
        self.advance(s)

    def advance(self, dt):
        end = self.t + dt
        while True:
            live = [a for a in self.actors if a.due is not None]
            if not live:
                break
            a = min(live, key=lambda x: x.due)
            if a.due > end:
                break
            self.t = max(self.t, a.due)
            self.in_actor = True
            try:
                a.run()
            finally:
                self.in_actor = False
        self.t = max(self.t, end)


class WorldLink(sim.SimLink):
    def __init__(self, world, loss_above=None, ignore_nr_writes=False, read_loss_above=None,
                 loss_band=None):
        super().__init__(loss=self._lose)
        self.world = world
        self.loss_above = loss_above            # writes; reads too unless read_loss_above
        self.read_loss_above = read_loss_above
        self.loss_band = loss_band              # (lo, hi]: lose only inside this actual band
        self.ignore_nr_writes = ignore_nr_writes
        self.trace = []
        self._hz = HDR_HZ
        self._rd = False

    def _lose(self, tx, i):
        if i != 100:
            return False
        a = actual_hz(self._hz)
        if self.loss_band is not None:
            return self.loss_band[0] < a <= self.loss_band[1]
        lim = self.read_loss_above if self._rd and self.read_loss_above else self.loss_above
        return lim is not None and a > lim

    def xfer(self, header, payload, n_rx, hz, header_hz=HDR_HZ):
        self._hz = hz
        self._rd = header[0] in link.READ_CMDS
        if self.ignore_nr_writes and header[0] == link.CMD_NR_W:
            out = b""
            self.log.append(sim.Txn(header[0], header[1], 1, header_hz, hz))
        else:
            out = super().xfer(header, payload, n_rx, hz, header_hz)
        txn = self.log[-1]
        w = self.world
        dur = (len(header) * 8 / header_hz + max(len(payload), n_rx) * 8 / actual_hz(hz)
               + TX_OVH_S)
        rec = Rec(w.t, w.t + dur, txn.cmd, txn.addr, txn.n, header_hz, hz,
                  bytes(payload) if payload else bytes(out), w.in_actor, w.phase)
        self.trace.append(rec)
        for h in list(w.hooks):
            h(rec)
        if w.in_actor:
            w.t += dur
        else:
            w.advance(dur)
        return out

    def rd(self, addr, n):
        return self.xfer(build_header(link.CMD_SRAM_R, addr, n), b"", n, HDR_HZ)

    def wr(self, addr, data):
        self.xfer(build_header(link.CMD_SRAM_W, addr, len(data)), bytes(data), 0, HDR_HZ)


class NextModel:
    """Scripted PI303 mailbox side, stepped once a frame."""

    def __init__(self, world, lk, script=SCRIPT, final_state=2, result=None,
                 stall_hb_next_on_load=False, result_at=RESULT, state_on_cmd=None):
        self.w, self.lk = world, lk
        self.script = script
        self.final_state = final_state
        self.result_at = result_at
        self.state_on_cmd = state_on_cmd        # (cmd, state): set state instead of acking
        self.result = result if result is not None else (
            b"#CORE303 PI 56172de\n#NR 01=33\n#SRAM 2048\n#END 0000\n")
        self.stall = stall_hb_next_on_load
        m = lk.sram
        m[MB:MB + 32] = bytes(32)
        m[MB:MB + 4] = b"M303"
        m[MB + 4] = m[MB + 12] = 7
        m[MB + 13] = 1
        self.due = 0.0
        self.mode = "follow"
        self.load = 0
        self.handed = False
        self.pibusy = None
        self.events = []
        self.sends = []          # (seq, cmd, arg0, arg1, us)
        self.streams = []
        self.ack_writes = []     # Pi ack_seq writes (t, end, value)
        self.cmd_writes = []     # Pi cmd_seq writes (t, seq, cmd, leader)
        self._gen = None
        self._init_regions()
        world.actors.append(self)
        world.hooks.append(self._hook)

    def _init_regions(self):
        m = self.lk.sram
        m[MAP["rs_phys"]:MAP["rs_phys"] + MAP["rs_len"]] = link.pattern(11, MAP["rs_len"])
        m[MAP["lr_src_phys"]:MAP["lr_src_phys"] + MAP["lr_len"]] = link.pattern(12, MAP["lr_len"])
        m[MAP["bf_dst_phys"]:MAP["bf_dst_phys"] + MAP["bf_len"]] = \
            bytes([MAP["fill_val"]]) * MAP["bf_len"]
        o = MAP["r5_off"]
        self.lk.bram5[o:o + MAP["r5_len"]] = link.pattern(13, MAP["r5_len"])

    def b(self, off):
        return self.lk.sram[MB + off]

    def setb(self, off, v):
        self.lk.sram[MB + off] = v & 0xFF

    def r16(self, off):
        return struct.unpack_from("<H", self.lk.sram, MB + off)[0]

    def _hook(self, rec):
        if rec.cmd == link.CMD_SRAM_W and rec.addr == MB + mbx.OFF_ACK:
            self.ack_writes.append((rec.t, rec.end, rec.data[0]))
        if rec.cmd == link.CMD_SRAM_W and rec.addr == MB + mbx.OFF_SEQ:
            self.cmd_writes.append((rec.t, rec.data[0], self.b(mbx.OFF_CMD), self.b(18)))

    def run(self):
        self.due = self.w.t + FRAME_S
        if self.mode == "follow":
            self._follow()
        elif self.mode in ("lead", "exit"):
            next(self._gen, None)
        else:
            self.due = None

    def _follow(self):
        if not (self.stall and self.load):
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
        if cmd == mbx.CMD_LOAD and a0 < 5:
            self.load = a0
        elif cmd in (mbx.CMD_STOP, mbx.CMD_END, mbx.CMD_HANDOVER):
            self.load = 0
        self.setb(12, seq)
        if cmd == mbx.CMD_END:
            self.mode, self._gen = "exit", self._exit()
        elif cmd == mbx.CMD_HANDOVER and not self.handed:
            self.handed = True
            self.mode, self._gen = "lead", self._lead()

    def _send(self, cmd, a0=0, a1=0, us=0):
        self.setb(6, a0)
        self.setb(7, a1)
        struct.pack_into("<I", self.lk.sram, MB + 8, us)
        self.setb(5, cmd)
        seq = (self.b(4) + 1) & 0xFF
        self.setb(4, seq)
        self.sends.append((seq, cmd, a0, a1, us))
        return seq

    def region(self, row):
        """(memory, offset, length) of a row's S-target bytes."""
        if row == 2:
            return self.lk.bram5, MAP["r5_off"], MAP["r5_len"]
        key = {0: ("sled_phys", "sled_len"), 1: ("rs_phys", "rs_len"),
               3: ("lr_src_phys", "lr_len"), 4: ("bf_dst_phys", "bf_len")}[row]
        return self.lk.sram, MAP[key[0]], MAP[key[1]]

    def _lead(self):
        yield
        self.setb(18, 1)
        self.events.append(("leader", self.w.t, 1))
        for cmd, row, tgt, us, row_s in self.script:
            snap = None
            if cmd == S and tgt == 1:
                mem, o, n = self.region(row)
                snap = bytes(mem[o:o + n])
            seq = self._send(cmd, row, tgt, us)
            while self.b(12) != seq:
                yield
            t_ack = self.w.t
            if cmd == Q:
                yield
                end = self.w.t + row_s
                while self.w.t < end:
                    yield
                continue
            hb0 = self.r16(16)
            end = self.w.t + row_s
            while self.w.t < end:
                yield
            hb1 = self.r16(16)
            sseq = self._send(STOP)
            while self.b(12) != sseq:
                yield
            ck = None
            if snap is not None:
                mem, o, n = self.region(row)
                ck = sum(1 for a, b in zip(snap, mem[o:o + n]) if a != b)
            self.streams.append(dict(row=row, tgt=tgt, seq=seq, stop_seq=sseq, t_ack=t_ack,
                                     nostream=hb0 == hb1, ck=ck))
        seq = self._send(mbx.CMD_YIELD)
        while self.b(12) != seq:
            yield
        self.setb(18, 0)
        self.events.append(("leader", self.w.t, 0))
        self.mode = "follow"

    def _exit(self):
        """restore_all: state 4, wait for hb_pi to settle (100 frames, bound 500), result, state."""
        self.setb(13, 4)
        self.events.append(("state", self.w.t, 4))
        last, still, frames = self.r16(16), 0, 0
        while still < 100 and frames < 500:
            yield
            frames += 1
            cur = self.r16(16)
            still, last = (still + 1, last) if cur == last else (0, cur)
        self.pibusy = frames >= 500
        n, at = len(self.result), self.result_at
        self.lk.sram[at:at + n] = self.result
        self.lk.sram[MB + 20:MB + 23] = at.to_bytes(3, "little")
        struct.pack_into("<H", self.lk.sram, MB + 23, n)
        self.setb(13, self.final_state)
        self.events.append(("state", self.w.t, self.final_state))
        self.mode = "done"
        self.due = None


class CHb:
    """spi303 link303 heartbeat and pass gate: read-increment hb_pi every 100 ms, state read."""

    def __init__(self, w, lk, mbox):
        self.w, self.lk, self.mbox = w, lk, mbox
        self.started = False
        self.last = 0.0
        self.bumps = 0
        self.last_state = -1

    def tick(self):
        if not self.mbox:
            return
        if self.started and self.w.t - self.last < 0.1:
            return
        self.started, self.last = True, self.w.t
        a = self.mbox + 16
        want = struct.pack("<H", (struct.unpack("<H", self.lk.rd(a, 2))[0] + 1) & 0xFFFF)
        for _ in range(4):
            self.lk.wr(a, want)
            if self.lk.rd(a, 2) == want:
                self.bumps += 1
                return
        raise pi303_spi.ToolError([("C3ER", {"code": 4, "errno": 0, "arg": 0})], 2)

    def ready(self):
        if not self.mbox:
            return True
        self.last_state = self.lk.rd(self.mbox + 13, 1)[0]
        return self.last_state == 1


class FakeStream:
    def __init__(self, tool, target, length, hz, data, hb):
        self.w, self.lk = tool.w, tool.lk
        if target.startswith("bram"):
            off = int(target.split(":")[1], 0) if ":" in target else 0
            self.cmd, self.base = link.CMD_BRAM_W, off | (0x8000 if target[4] == "7" else 0)
        else:
            self.cmd, self.base = link.CMD_SRAM_W, int(target, 0)
        self.target, self.data, self.hz = target, data[:length], hz
        self.c = CHb(self.w, self.lk, hb)
        self.off = self.passes = self.ntx = 0
        self.ns = 0.0
        self.why = -1
        self.done = False
        self.started_t = self.stop_t = None
        self.due = self.w.t + SPAWN_S
        self.w.actors.append(self)

    def run(self):
        if self.started_t is None:
            self.c.tick()
            self.started_t = self.w.t
        elif self.off == 0 and not self.c.ready():
            self._finish(1)
            return
        else:
            n = min(link.MAX_CHUNK, len(self.data) - self.off)
            t0 = self.w.t
            self.lk.xfer(build_header(self.cmd, self.base + self.off, n),
                         self.data[self.off:self.off + n], 0, self.hz)
            self.ns += self.w.t - t0
            self.ntx += 1
            self.off += n
            if self.off >= len(self.data):
                self.off = 0
                self.passes += 1
            self.c.tick()
        self.due = self.w.t + 1e-4

    def _finish(self, why):
        self.why, self.done, self.due, self.stop_t = why, True, None, self.w.t
        if self in self.w.actors:
            self.w.actors.remove(self)

    def alive(self):
        return not self.done

    def stop(self):
        if not self.done:
            self._finish(0)
        return [("C3SM", {"base": self.base, "bytes": len(self.data), "hz": self.hz,
                          "passes": self.passes, "ntx": self.ntx, "ns": int(self.ns * 1e9),
                          "stop": self.why, "state": self.c.last_state}),
                ("C3HB", {"bumps": self.c.bumps})]


class FakeTool:
    """spi303 subcommands emulated over the world link, with the C rows they print."""

    def __init__(self, world, lk, selftest_ok=True):
        self.w, self.lk = world, lk
        self.selftest_ok = selftest_ok
        self.calls = []          # (t, sub, args)
        self.streams = []

    def _call(self, sub, *args):
        self.calls.append((self.w.t, sub, args))
        self.w.phase = sub

    def selftest(self, phys):
        self._call("selftest", phys)
        want = link.pattern(0x303, 256)
        self.lk.wr(phys, want if self.selftest_ok else bytes(256))
        got = self.lk.rd(phys, 256)
        mis, first, _ = pi303_spi.cmp_tx(want, got)
        self.w.phase = None
        return [("C3ST", {"ok": int(mis == 0), "base": phys, "mis": mis, "first": first})]

    def write(self, phys, nbytes, hz, chunk, seed0, passes=1, hb=None):
        self._call("write", phys, nbytes, hz, chunk, seed0, passes, hb)
        return self._loop("C3WP", link.CMD_SRAM_W, phys, nbytes, hz, chunk, seed0, passes, hb)

    def bram(self, bank, hz, passes, seed0, hb=None):
        self._call("bram", bank, hz, passes, seed0, hb)
        flag, size = (0x8000, 0x2000) if bank == 7 else (0, 0x4000)
        return self._loop("C3BP", link.CMD_BRAM_W, flag, size, hz, link.MAX_CHUNK, seed0,
                          passes, hb)

    def _loop(self, tag, wcmd, base, nbytes, hz, chunk, seed0, passes, hb):
        c = CHb(self.w, self.lk, hb)
        rows, stop, p = [], 0, 0
        c.tick()
        for p in range(passes):
            if not c.ready():
                stop = 1
                break
            want = link.pattern(seed0 + p, nbytes)
            ns, ntx = 0.0, 0
            for off in range(0, nbytes, chunk):
                part = want[off:off + chunk]
                t0 = self.w.t
                self.lk.xfer(build_header(wcmd, base + off, len(part)), part, 0, hz)
                ns += self.w.t - t0
                ntx += 1
                c.tick()
            acc = self._verify(wcmd - 1, base, want, chunk, HDR_HZ, c)
            rows.append((tag, dict({"pass": p, "seed": seed0 + p, "hz": hz, "base": base,
                                    "bytes": nbytes, "chunk": chunk, "ntx": ntx,
                                    "ns": int(ns * 1e9)}, **acc)))
        else:
            p = passes
        self.w.phase = None
        return rows + self._end(c, p, stop, hb)

    def _verify(self, rcmd, base, want, chunk, hz, c, timed=None):
        acc = {"mis": 0, "bad_tx": 0, "first_tx": -1, "first": -1, "shift": 0}
        for tx, off in enumerate(range(0, len(want), chunk)):
            k = min(chunk, len(want) - off)
            t0 = self.w.t
            got = self.lk.xfer(build_header(rcmd, base + off, k), b"", k, hz)
            if timed is not None:
                timed[0] += self.w.t - t0
            c.tick()
            m, f, s = pi303_spi.cmp_tx(want[off:off + k], got)
            if m:
                if not acc["bad_tx"]:
                    acc.update(first_tx=tx, first=f, shift=s)
                acc["mis"] += m
                acc["bad_tx"] += 1
        return acc

    @staticmethod
    def _end(c, p, stop, hb):
        rows = [("C3EN", {"passes": p, "stop": stop, "state": c.last_state})]
        if hb:
            rows.append(("C3HB", {"bumps": c.bumps}))
        return rows

    def read(self, phys, nbytes, hz, chunk, seed, passes=1, hb=None):
        self._call("read", phys, nbytes, hz, chunk, seed, passes, hb)
        c = CHb(self.w, self.lk, hb)
        rows, stop, p = [], 0, 0
        want = link.pattern(seed, nbytes)
        c.tick()
        for p in range(passes):
            if not c.ready():
                stop = 1
                break
            ns = [0.0]
            acc = self._verify(link.CMD_SRAM_R, phys, want, chunk, hz, c, timed=ns)
            rows.append(("C3RP", dict({"pass": p, "hz": hz, "base": phys, "bytes": nbytes,
                                       "chunk": chunk, "ntx": -(-nbytes // chunk),
                                       "ns": int(ns[0] * 1e9), "ref": 1}, **acc)))
        else:
            p = passes
        self.w.phase = None
        return rows + self._end(c, p, stop, hb)

    def stream(self, target, length, hz, src, hb):
        self._call("stream", target, length, hz, src, hb)
        self.w.phase = None
        with open(src, "rb") as f:
            data = f.read()
        s = FakeStream(self, target, length, hz, data, hb)
        self.streams.append(s)
        return s


def make(loss_above=None, script=SCRIPT, selftest_ok=True, ignore_nr_writes=False,
         read_loss_above=None, loss_band=None, **next_kw):
    w = World()
    lk = WorldLink(w, loss_above=loss_above, ignore_nr_writes=ignore_nr_writes,
                   read_loss_above=read_loss_above, loss_band=loss_band)
    nx = NextModel(w, lk, script=script, **next_kw)
    tool = FakeTool(w, lk, selftest_ok=selftest_ok)
    return w, lk, nx, tool


def run_main(out, w, lk, tool, plan=PLAN, addrs=MAP):
    return pi303_spi.main(lk, MB, SCRATCH, str(out), BUNDLE, tool, addrs=addrs, clock=w,
                          plan=plan, core_clk=lambda: (0, "none"), spi_open=lambda: [])
