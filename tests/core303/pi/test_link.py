import itertools
import struct

import pytest

import bundle
import link
import mailbox
import parse
import pilog
import sim

MB = 0x1F0000          # mailbox page in the simulated SRAM
FAST = 8_000_000


class FakeClock:
    def __init__(self, on_sleep=None):
        self.t = 0.0
        self.on_sleep = on_sleep

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s
        if self.on_sleep:
            self.on_sleep()


def prep_mailbox(s, state=1, leader=0, cmd_seq=0, ack_seq=0):
    page = bytearray(32)
    page[0:4] = b"M303"
    page[4] = cmd_seq
    page[12] = ack_seq
    page[13] = state
    page[18] = leader
    s.sram[MB:MB + 32] = page


def test_pattern_known_prefix():
    assert link.pattern(7, 8) == bytes([231, 7, 67, 69, 255, 148, 186, 87])
    assert link.pattern(0, 4) == link.pattern(1, 4)
    assert len(link.pattern(5, 100)) == 100


def test_sim_roundtrip():
    s = sim.SimLink()
    data = bytes(range(256)) * 3
    s.write_mem(0x12345, data, 2_000_000)
    assert s.read_mem(0x12345, len(data)) == data
    assert s.version() == (s.VERSION, s.CAPS)
    s.nr_write(0x7F, 0x5A)
    assert s.nr_read(0x7F) == 0x5A


def test_sim_bram_wraps():
    s = sim.SimLink()
    # Link rejects out-of-range; drive the slave model raw to check its modulo addressing
    s._transact(link.CMD_BRAM_W, 0x9FFE, 4, b"\x01\x02\x03\x04", 2_000_000)
    assert s._transact(link.CMD_BRAM_R, 0x9FFE, 4, b"", 2_000_000) == b"\x01\x02\x03\x04"
    assert s.bram7[0x1FFE:0x2000] == b"\x01\x02" and s.bram7[0:2] == b"\x03\x04"
    s._transact(link.CMD_BRAM_W, 0x3FFF, 2, b"\xAA\xBB", 2_000_000)
    assert s.bram5[0x3FFF] == 0xAA and s.bram5[0] == 0xBB


def test_sim_loss_within_transaction():
    s = sim.SimLink(loss=lambda tx, i: tx == 0 and i == 100)
    data = link.pattern(3, 8000)
    s.write_mem(0x1000, data, FAST)
    got = bytes(s.sram[0x1000:0x1000 + 8000])
    assert got[:100] == data[:100]
    assert got[100:3999] == data[101:4000]
    assert got[3999] == 0
    assert got[4000:] == data[4000:]


def test_sim_rejects_fast_header():
    s = sim.SimLink()
    hdr = link.build_header(link.CMD_SRAM_W, 0x1000, 4)
    with pytest.raises(sim.SimFault):
        s.xfer(hdr, b"abcd", 0, FAST, header_hz=FAST)
    s2 = sim.SimLink(header_hz_check=False)
    s2.xfer(hdr, b"abcd", 0, FAST, header_hz=FAST)
    assert bytes(s2.sram[0x1000:0x1004]) == b"abcd"


def test_header_framing():
    h = link.build_header
    assert h(link.CMD_SRAM_R, 0x1F2345, 0x0102) == bytes([0xA7, 0x1F, 0x23, 0x45, 1, 2, 0])
    assert h(link.CMD_SRAM_W, 0x012345, 0x0102) == bytes([0xA8, 0x01, 0x23, 0x45, 1, 2])
    assert h(link.CMD_BRAM_R, 0x8010, 3) == bytes([0xA9, 0x80, 0x10, 0, 3, 0])
    assert h(link.CMD_BRAM_W, 0x0010, 3) == bytes([0xAA, 0x00, 0x10, 0, 3])
    assert h(link.CMD_NR_R, 0x1E, 1) == bytes([0xAB, 0x1E, 0])
    assert h(link.CMD_NR_W, 0x1E, 1, val=0x55) == bytes([0xAC, 0x1E, 0x55, 0])
    assert h(link.CMD_VERSION, 0, 2) == bytes([0xA1, 0])


def test_split_4000():
    s = sim.SimLink()
    data = link.pattern(9, 9000)
    s.write_mem(0x2000, data, 2_000_000)
    writes = [t for t in s.log if t.cmd == link.CMD_SRAM_W]
    assert [(t.addr, t.n) for t in writes] == [(0x2000, 4000), (0x2000 + 4000, 4000),
                                               (0x2000 + 8000, 1000)]
    assert s.read_mem(0x2000, 9000) == data
    reads = [t for t in s.log if t.cmd == link.CMD_SRAM_R]
    assert [t.n for t in reads] == [4000, 4000, 1000]
    assert all(t.header_hz == 2_000_000 for t in s.log)
    assert all(t.payload_hz == 2_000_000 for t in s.log)


def test_split_rate_header_slow_payload_fast():
    s = sim.SimLink()
    s.write_mem(0x10, b"xyz", FAST)
    t = s.log[-1]
    assert (t.header_hz, t.payload_hz) == (2_000_000, FAST)


def test_raster_retry():
    seq = iter([0x0FF, 0x100, 0x101,      # MSB 0, LSB 0, MSB 1: retry
                0x1AB, 0x1AB, 0x1AB])     # stable
    s = sim.SimLink(raster=lambda: next(seq))
    assert s.raster_line() == 0x1AB
    bad = itertools.cycle([0x000, 0x000, 0x100])    # MSB reads always differ
    s2 = sim.SimLink(raster=lambda: next(bad))
    with pytest.raises(link.LinkError):
        s2.raster_line()
    reads = [t for t in s2.log if t.cmd == link.CMD_NR_R]
    assert len(reads) == 3 * (1 + 8)


def test_mailbox_handshake():
    s = sim.SimLink()
    prep_mailbox(s)

    def next_acks():
        s.sram[MB + 12] = s.sram[MB + 4]
    clock = FakeClock(on_sleep=next_acks)
    m = mailbox.Mailbox(s, MB, clock=clock)
    m.send(mailbox.CMD_QUIET, 3, 0, 5000, timeout_s=1.0)
    assert s.sram[MB + 4] == 1 and s.sram[MB + 5] == 1 and s.sram[MB + 6] == 3
    assert struct.unpack_from("<I", s.sram, MB + 8)[0] == 5000
    m.send(mailbox.CMD_STOP, timeout_s=1.0)
    assert s.sram[MB + 4] == 2 and s.sram[MB + 5] == 3
    # no ack: times out
    m2 = mailbox.Mailbox(s, MB, clock=FakeClock())
    with pytest.raises(mailbox.MailboxTimeout):
        m2.send(mailbox.CMD_STOP, timeout_s=0.5)
    # follower must not send
    s.sram[MB + 18] = 1
    with pytest.raises(mailbox.MailboxError):
        m.send(mailbox.CMD_STOP, timeout_s=0.5)


def test_mailbox_ignores_stale():
    s = sim.SimLink()
    m = mailbox.Mailbox(s, MB, clock=FakeClock())
    # no magic
    assert m.poll() is None
    # stale: state 0 (boot) with a command left from an earlier run
    prep_mailbox(s, state=0, leader=1, cmd_seq=3, ack_seq=2)
    s.sram[MB + 5] = mailbox.CMD_YIELD
    assert m.poll() is None
    # state ready but already acked
    prep_mailbox(s, state=1, leader=1, cmd_seq=3, ack_seq=3)
    assert m.poll() is None
    # state ready, Pi is leader: nothing to follow
    prep_mailbox(s, state=1, leader=0, cmd_seq=4, ack_seq=3)
    assert m.poll() is None
    # a fresh command
    prep_mailbox(s, state=1, leader=1, cmd_seq=4, ack_seq=3)
    s.sram[MB + 5] = mailbox.CMD_YIELD
    s.sram[MB + 6] = 7
    c = m.poll()
    assert (c.seq, c.cmd, c.arg0) == (4, mailbox.CMD_YIELD, 7)
    m.ack(c)
    assert s.sram[MB + 12] == 4
    assert m.poll() is None


def test_seq_wrap_not_skipped():
    s = sim.SimLink()
    m = mailbox.Mailbox(s, MB, clock=FakeClock())
    prep_mailbox(s, state=1, leader=1, cmd_seq=3, ack_seq=2)
    m.ack(m.poll())
    # 256 commands later the 8-bit seq is 3 again with ack_seq at 2
    prep_mailbox(s, state=1, leader=1, cmd_seq=3, ack_seq=2)
    assert m.poll().seq == 3


def test_mailbox_magic_and_role_checks():
    s = sim.SimLink()
    m = mailbox.Mailbox(s, MB, clock=FakeClock())
    with pytest.raises(mailbox.MailboxError):
        m.send(mailbox.CMD_STOP, timeout_s=0.1)
    prep_mailbox(s, state=1, leader=1, cmd_seq=4, ack_seq=3)
    c = m.poll()
    s.sram[MB + 18] = 0
    with pytest.raises(mailbox.MailboxError):
        m.ack(c)
    assert s.sram[MB + 12] == 3


def test_sram_bound_rejected():
    s = sim.SimLink()
    for fn in (lambda: s.write_mem(-1, b"x", 2_000_000),
               lambda: s.write_mem(0x1FFFFF, b"xy", 2_000_000),
               lambda: s.read_mem(0x1FFFFF, 2),
               lambda: s.read_mem(0x200000, 1)):
        with pytest.raises(link.LinkError):
            fn()
    s.write_mem(0x1FFFFF, b"x", 2_000_000)
    assert s.read_mem(0x1FFFFF, 1) == b"x"
    assert s.log[-2:] and all(t.addr < 0x200000 for t in s.log)


def test_bram_bank_rejected():
    s = sim.SimLink()
    for bank in (0, 6, 8, None):
        with pytest.raises(link.LinkError):
            s.bram_write(bank, 0, b"x", 2_000_000)
        with pytest.raises(link.LinkError):
            s.bram_read(bank, 0, 1)
    assert s.log == []


def test_bram_range_rejected():
    s = sim.SimLink()
    for fn in (lambda: s.bram_write(5, 0x3FFF, b"xy", 2_000_000),
               lambda: s.bram_read(7, 0x1FFF, 2),
               lambda: s.bram_read(7, -1, 1),
               lambda: s.bram_write(7, 0, bytes(0x2001), 2_000_000)):
        with pytest.raises(link.LinkError):
            fn()
    assert s.log == []
    s.bram_write(7, 0, bytes(range(256)) * 32, 2_000_000)
    assert all(t.addr & 0x8000 for t in s.log)      # chunks never carry out of bit 15


def test_plan_split_header_slow_payload_fast():
    hdr = link.build_header(link.CMD_SRAM_W, 0x1000, 4000)
    (l0, s0, c0), (l1, s1, c1) = link.plan_split(hdr, bytes(4000), FAST)
    assert (l0, s0, c0) == (len(hdr), 2_000_000, 0)
    assert (l1, s1) == (4000, FAST) and c1 == 0


def test_serve_reply_length_and_pipe_errors():
    backend = sim.SimLink()
    proc = FakeServe(backend)
    h = link.ServeHelper(proc)
    orig = proc.write

    def short(buf):
        orig(buf)
        proc.reply[:] = struct.pack("<BH", 0, 1) + b"x"
    proc.write = short
    with pytest.raises(link.LinkError):
        h.read(link.CMD_SRAM_R, 0, 4, FAST)

    class Dead:
        def write(self, b):
            raise BrokenPipeError()

        def flush(self):
            pass
    d = FakeServe(backend)
    d.stdin = Dead()
    with pytest.raises(link.LinkError):
        link.ServeHelper(d).read(link.CMD_SRAM_R, 0, 4, FAST)

    class Eof:
        def read(self, n):
            return b""
    e = FakeServe(backend)
    e.stdout = Eof()
    with pytest.raises(link.LinkError):
        link.ServeHelper(e).read(link.CMD_SRAM_R, 0, 4, FAST)


def test_spidev_close_waits_helper_before_unlock():
    order = []

    class Proc:
        class stdin:
            @staticmethod
            def close():
                order.append("stdin")

        def wait(self, timeout):
            order.append("wait")

    class Lock(NeverLock):
        def release(self):
            order.append("release")
    lk = link.SpidevLink(lock=Lock(), helper=link.ServeHelper(Proc()))
    lk._locked = True
    lk.close()
    assert order == ["stdin", "wait", "release"]


def test_mailbox_write_readback_retry():
    s = sim.SimLink(loss=lambda tx, i: tx == 0)
    prep_mailbox(s)
    m = mailbox.Mailbox(s, MB, clock=FakeClock())
    m.bump_hb_pi()
    assert struct.unpack_from("<H", s.sram, MB + 16)[0] == 1
    writes = [t for t in s.log if t.cmd == link.CMD_SRAM_W]
    assert len(writes) == 2          # first dropped, retry landed
    s2 = sim.SimLink(loss=lambda tx, i: True)
    prep_mailbox(s2)
    m2 = mailbox.Mailbox(s2, MB, clock=FakeClock())
    with pytest.raises(mailbox.MailboxError):
        m2.bump_hb_pi()
    assert len([t for t in s2.log if t.cmd == link.CMD_SRAM_W]) == 1 + 3


def test_mailbox_single_field_writes():
    fields = [(4, 5), (5, 6), (6, 7), (7, 8), (8, 12), (12, 13), (16, 18)]
    s = sim.SimLink()
    prep_mailbox(s)
    clock = FakeClock(on_sleep=lambda: s.sram.__setitem__(MB + 12, s.sram[MB + 4]))
    m = mailbox.Mailbox(s, MB, clock=clock)
    m.send(mailbox.CMD_QUIET, 1, 2, 3, timeout_s=1.0)
    m.send(mailbox.CMD_HANDOVER, timeout_s=1.0)
    m.bump_hb_pi()
    s.sram[MB + 18] = 1
    s.sram[MB + 13] = 1
    s.sram[MB + 4] = 9
    m.ack(m.poll())
    writes = [t for t in s.log if t.cmd == link.CMD_SRAM_W]
    assert len(writes) >= 9
    for t in writes:
        lo, hi = t.addr - MB, t.addr - MB + t.n
        assert any(f0 <= lo and hi <= f1 for f0, f1 in fields), (lo, hi)
        assert t.payload_hz == 2_000_000


def test_mailbox_readers():
    s = sim.SimLink()
    prep_mailbox(s, state=2, leader=1)
    s.sram[MB + 14:MB + 16] = struct.pack("<H", 0x1234)
    m = mailbox.Mailbox(s, MB, clock=FakeClock())
    assert m.state() == 2 and m.leader() == 1 and m.read_hb_next() == 0x1234


def test_hb_pi_timer():
    s = sim.SimLink()
    prep_mailbox(s)
    clock = FakeClock()
    m = mailbox.Mailbox(s, MB, clock=clock)
    hb = mailbox.Heartbeat(m, clock)
    assert hb.tick() is True                  # first tick bumps
    clock.t = 0.05
    assert hb.tick() is False
    clock.t = 0.10
    assert hb.tick() is True
    clock.t = 0.15
    assert hb.tick() is False
    clock.t = 0.20
    assert hb.tick() is True
    assert struct.unpack_from("<H", s.sram, MB + 16)[0] == 3
    # QUIET window: no transfers at all
    hb.suspend()
    n = len(s.log)
    clock.t = 5.0
    assert hb.tick() is False
    assert len(s.log) == n
    hb.resume()
    assert hb.tick() is True


def test_spi_ioc_transfer_pack():
    b = link.pack_spi_transfer(tx_buf=0x1122334455667788, rx_buf=0x99AABBCCDDEEFF00,
                               length=4000, speed_hz=8_000_000)
    assert len(b) == 32
    assert struct.unpack_from("<Q", b, 0)[0] == 0x1122334455667788
    assert struct.unpack_from("<Q", b, 8)[0] == 0x99AABBCCDDEEFF00
    assert struct.unpack_from("<I", b, 16)[0] == 4000
    assert struct.unpack_from("<I", b, 20)[0] == 8_000_000
    assert struct.unpack_from("<H", b, 24)[0] == 0          # delay_usecs
    assert b[26] == 8                                       # bits_per_word
    assert b[27] == 0                                       # cs_change
    assert b[28:32] == bytes(4)
    c = link.pack_spi_transfer(1, 2, 3, 4, delay_usecs=0x0102, bits_per_word=0, cs_change=1)
    assert struct.unpack_from("<H", c, 24)[0] == 0x0102 and c[26] == 0 and c[27] == 1
    assert link.spi_ioc_message(1) == 0x40206B00
    assert link.spi_ioc_message(2) == 0x40406B00


class FakeServe:
    """Speaks the spi303 serve pipe framing against a SimLink."""

    def __init__(self, backend):
        self.backend = backend
        self.reply = bytearray()
        self.requests = []
        self.stdin = self
        self.stdout = self

    def write(self, buf):
        op, cmd = buf[0], buf[1]
        addr = int.from_bytes(buf[2:5], "little")
        n, hz = struct.unpack_from("<HI", buf, 5)
        payload = bytes(buf[11:])
        self.requests.append((op, cmd, addr, n, hz, payload))
        try:
            if op == link.OP_WRITE:
                assert len(payload) == n
                self.backend._transact(cmd, addr, n, payload, hz)
                data = b""
            else:
                data = self.backend._transact(cmd, addr, n, b"", hz)
            self.reply += struct.pack("<BH", 0, len(data)) + data
        except link.LinkError:
            self.reply += struct.pack("<BH", 1, 0)

    def flush(self):
        pass

    def read(self, n):
        out = bytes(self.reply[:n])
        del self.reply[:n]
        return out

    def close(self):
        pass


def test_serve_protocol_roundtrip():
    backend = sim.SimLink()
    proc = FakeServe(backend)
    h = link.ServeHelper(proc)
    data = link.pattern(4, 3000)
    h.write(link.CMD_SRAM_W, 0x4000, data, FAST)
    assert proc.requests[0] == (link.OP_WRITE, 0xA8, 0x4000, 3000, FAST, data)
    assert bytes(backend.sram[0x4000:0x4000 + 3000]) == data
    assert h.read(link.CMD_SRAM_R, 0x4000, 3000, FAST) == data
    assert proc.requests[1][0] == link.OP_READ and proc.requests[1][5] == b""
    proc.backend = sim.SimLink(header_hz_check=True)
    # error status surfaces as LinkError
    proc.backend._transact = lambda *a, **k: (_ for _ in ()).throw(link.LinkError("x"))
    with pytest.raises(link.LinkError):
        h.read(link.CMD_SRAM_R, 0, 4, FAST)


def test_spidev_link_split_rate_via_helper():
    backend = sim.SimLink()
    h = link.ServeHelper(FakeServe(backend))
    lk = link.SpidevLink(helper=h, lock=NeverLock())
    data = link.pattern(2, 4500)
    lk.write_mem(0x8000, data, FAST)
    assert bytes(backend.sram[0x8000:0x8000 + 4500]) == data
    assert [t.n for t in backend.log] == [4000, 500]
    assert lk.read_mem(0x8000, 4500, FAST) == data
    with pytest.raises(link.LinkError):
        link.SpidevLink(lock=NeverLock()).write_mem(0, b"x", FAST)


class NeverLock(link.LockProvider):
    def try_lock(self):
        return False

    def release(self):
        pass


def test_lock_busy_skips():
    clock = FakeClock()
    lk = link.SpidevLink(lock=NeverLock())
    with pytest.raises(link.BusBusy):
        lk.open(clock=clock)
    assert 30.0 <= clock.t < 31.0

    class OnceLock(NeverLock):
        calls = 0

        def try_lock(self):
            self.calls += 1
            return self.calls == 3
    p = OnceLock()
    assert p.acquire(30, FakeClock()) is True


def test_pilog_grammar_roundtrip(tmp_path):
    p = tmp_path / "PI.LOG"
    w = pilog.PiLogWriter(p, "spisweep", "0123456789ab")
    w.env(model="zero1.3", spi_open="", arm=700)
    w.spi(version=0x01, caps=0xFF, core_clk=0, core_clk_src="none")
    w.row("P3WS", rate=2000000, n=5)
    w.row("P3RS", rate=2500000, n=-1)
    w.skip("P3FR", "FRAMING")
    w.close()
    w.close()
    text = p.read_bytes().decode("ascii")
    assert "\r" not in text and text.endswith("#END 0002\n")
    assert "#SPI version=01 caps=FF core_clk=0 core_clk_src=none" in text
    pl = parse.parse_pilog(p)
    assert (pl.tool, pl.bundle) == ("spisweep", "0123456789ab")
    assert [r.tag for r in pl.rows] == ["P3WS", "P3RS"]
    assert pl.rows[1].fields["n"] == -1
    assert pl.env["spi_open"] == "" and pl.spi["caps"] == "FF"
    assert pl.skips == [("P3FR", "FRAMING")]
    with pytest.raises(ValueError):
        w2 = pilog.PiLogWriter(tmp_path / "x.log", "t", "0123456789ab")
        w2.row("bad", x=1)
    with pytest.raises(ValueError):
        pilog.PiLogWriter(tmp_path / "y.log", "t", "XYZ")


def test_pilog_busy_lock(tmp_path):
    p = tmp_path / "B.LOG"
    w = pilog.PiLogWriter(p, "spisweep", "0123456789ab")
    w.skip("BUSY", "LOCK")
    w.close()
    pl = parse.parse_pilog(p)
    assert pl.skips == [("BUSY", "LOCK")] and pl.rows == []
    assert p.read_text().endswith("#SKIP BUSY LOCK\n#END 0000\n")


def test_bundle_hash_allowlist(tmp_path):
    (tmp_path / "sub").mkdir()
    (tmp_path / "b.py").write_bytes(b"bbb")
    (tmp_path / "sub" / "a.py").write_bytes(b"aaa")
    (tmp_path / "BUNDLE.txt").write_text("sub/a.py\nb.py\n")
    h0 = bundle.bundle_hash(tmp_path)
    assert len(h0) == 12 and int(h0, 16) >= 0
    (tmp_path / "__pycache__").mkdir()
    (tmp_path / "__pycache__" / "x.pyc").write_bytes(b"junk")
    assert bundle.bundle_hash(tmp_path) == h0
    (tmp_path / "b.py").write_bytes(b"bbc")
    assert bundle.bundle_hash(tmp_path) != h0
    (tmp_path / "BUNDLE.txt").write_text("sub/a.py\nb.py\nmissing.py\n")
    with pytest.raises(bundle.BundleError):
        bundle.bundle_hash(tmp_path)
    (tmp_path / "BUNDLE.txt").write_text("b.py\nsub/a.py\n")
    (tmp_path / "b.py").write_bytes(b"bbb")
    assert bundle.bundle_hash(tmp_path) == h0       # order-independent


def test_dir_hash(tmp_path):
    (tmp_path / "f1.bin").write_bytes(b"1")
    (tmp_path / "f2.bin").write_bytes(b"2")
    h = bundle.dir_hash(tmp_path)
    assert len(h) == 12
    (tmp_path / "f2.bin").write_bytes(b"3")
    assert bundle.dir_hash(tmp_path) != h


def test_real_bundle_lists_existing_files():
    from pathlib import Path
    root = Path(__file__).parent
    assert len(bundle.bundle_hash(root)) == 12
