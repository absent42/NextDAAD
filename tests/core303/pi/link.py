"""SPI link to the Next Pi debug slave: header at 2 MHz, payload at the test rate, CE held.
The serve child must never flock the bus lock itself; the parent holds it for the run.
"""
import struct
import time

HDR_HZ = 2_000_000
MAX_CHUNK = 4000
SRAM_SIZE = 0x200000
BRAM_SIZE = {5: 0x4000, 7: 0x2000}
RASTER_RETRIES = 8
LOCK_PATH = "/run/nextspi.lock"
LOCK_TIMEOUT_S = 30
SPI_IOC_MAGIC = 0x6B
SPI_IOC_TRANSFER_SIZE = 32

CMD_VERSION = 0xA1
CMD_SRAM_R = 0xA7
CMD_SRAM_W = 0xA8
CMD_BRAM_R = 0xA9
CMD_BRAM_W = 0xAA
CMD_NR_R = 0xAB
CMD_NR_W = 0xAC
READ_CMDS = (CMD_VERSION, CMD_SRAM_R, CMD_BRAM_R, CMD_NR_R)

OP_WRITE = 1
OP_READ = 2
OP_PUSH = 3
OP_PUSHSPANS = 4
PUSH_VERIFY = 1
PUSH_REPLY = 16


class LinkError(Exception):
    pass


class BusBusy(LinkError):
    pass


class RealClock:
    def time(self):
        return time.monotonic()

    def sleep(self, s):
        time.sleep(s)


def pattern(seed, n):
    """xorshift32 bytes: state starts at seed or 1, one step per byte."""
    x = (seed or 1) & 0xFFFFFFFF
    out = bytearray()
    for _ in range(n):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(x & 0xFF)
    return bytes(out)


def build_header(cmd, addr, n, val=0):
    """Readme header incl. junk byte: SRAM_R L68, SRAM_W L71, BRAM_R L60, BRAM_W L64,
    NR_R L74, NR_W L77 (all in header), VERSION L42."""
    l1, l0 = (n >> 8) & 0xFF, n & 0xFF
    if cmd == CMD_SRAM_R:
        return bytes([cmd, (addr >> 16) & 0x1F, (addr >> 8) & 0xFF, addr & 0xFF, l1, l0, 0])
    if cmd == CMD_SRAM_W:
        return bytes([cmd, (addr >> 16) & 0x1F, (addr >> 8) & 0xFF, addr & 0xFF, l1, l0])
    if cmd == CMD_BRAM_R:
        return bytes([cmd, (addr >> 8) & 0xFF, addr & 0xFF, l1, l0, 0])
    if cmd == CMD_BRAM_W:
        return bytes([cmd, (addr >> 8) & 0xFF, addr & 0xFF, l1, l0])
    if cmd == CMD_NR_R:
        return bytes([cmd, addr & 0xFF, 0])
    if cmd == CMD_NR_W:
        return bytes([cmd, addr & 0xFF, val & 0xFF, 0])
    if cmd == CMD_VERSION:
        return bytes([cmd, 0])
    raise LinkError("unknown command %02X" % cmd)


def pack_spi_transfer(tx_buf, rx_buf, length, speed_hz, delay_usecs=0,
                      bits_per_word=8, cs_change=0):
    """struct spi_ioc_transfer: 32 bytes, len at 16, speed_hz at 20."""
    return struct.pack("<QQIIHBBBBBB", tx_buf, rx_buf, length, speed_hz, delay_usecs,
                       bits_per_word, cs_change, 0, 0, 0, 0)


def plan_split(header, body, hz):
    """Two descriptors (len, speed_hz, cs_change): header always 2 MHz, payload at hz, CE held."""
    return (len(header), HDR_HZ, 0), (len(body), hz, 0)


def spi_ioc_message(n):
    """_IOW('k', 0, char[32*n]): write direction 1 at bit 30, size at 16, type at 8."""
    return (1 << 30) | ((SPI_IOC_TRANSFER_SIZE * n) << 16) | (SPI_IOC_MAGIC << 8) | 0


class LockProvider:
    """Subclasses supply try_lock and release; acquire polls until the timeout."""

    POLL_S = 0.05

    def try_lock(self):
        raise NotImplementedError

    def release(self):
        raise NotImplementedError

    def acquire(self, timeout_s, clock):
        end = clock.time() + timeout_s
        while True:
            if self.try_lock():
                return True
            now = clock.time()
            if now >= end:
                return False
            clock.sleep(min(self.POLL_S, end - now))


class FlockProvider(LockProvider):
    def __init__(self, path=LOCK_PATH):
        self.path = path
        self._fd = None

    def try_lock(self):
        import fcntl
        import os
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        self._fd = fd
        return True

    def release(self):
        if self._fd is None:
            return
        import fcntl
        import os
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
            self._fd = None


class Link:
    """Abstract link. Subclasses implement xfer; _transact may be overridden."""

    def xfer(self, header, payload, n_rx, hz, header_hz=HDR_HZ):
        """Header at header_hz then payload at hz; returns the n_rx payload bytes read."""
        raise NotImplementedError

    def _transact(self, cmd, addr, n, payload, hz):
        hdr = build_header(cmd, addr, n)
        if cmd in READ_CMDS:
            return self.xfer(hdr, b"", n, hz)
        self.xfer(hdr, payload, 0, hz)
        return b""

    def version(self):
        v = self._transact(CMD_VERSION, 0, 2, b"", HDR_HZ)
        return v[0], v[1]

    @staticmethod
    def _check(base, n, limit, what):
        if base < 0 or n < 0 or base + n > limit:
            raise LinkError("%s range %#x+%d outside %#x" % (what, base, n, limit))

    def _write(self, cmd, base, data, hz, limit, flag=0):
        data = bytes(data)
        self._check(base, len(data), limit, "write")
        for off in range(0, len(data), MAX_CHUNK):
            chunk = data[off:off + MAX_CHUNK]
            self._transact(cmd, flag | (base + off), len(chunk), chunk, hz)

    def _read(self, cmd, base, n, hz, limit, flag=0):
        self._check(base, n, limit, "read")
        out = bytearray()
        for off in range(0, n, MAX_CHUNK):
            out += self._transact(cmd, flag | (base + off), min(MAX_CHUNK, n - off), b"", hz)
        return bytes(out)

    def write_mem(self, phys, data, hz):
        self._write(CMD_SRAM_W, phys, data, hz, SRAM_SIZE)

    def read_mem(self, phys, n, hz=HDR_HZ):
        return self._read(CMD_SRAM_R, phys, n, hz, SRAM_SIZE)

    @staticmethod
    def _bram(bank):
        if bank not in BRAM_SIZE:
            raise LinkError("bank %r is not 5 or 7" % (bank,))
        return BRAM_SIZE[bank], (0x8000 if bank == 7 else 0)

    def bram_write(self, bank, off, data, hz):
        size, flag = self._bram(bank)
        self._write(CMD_BRAM_W, off, data, hz, size, flag)

    def bram_read(self, bank, off, n, hz=HDR_HZ):
        size, flag = self._bram(bank)
        return self._read(CMD_BRAM_R, off, n, hz, size, flag)

    def nr_read(self, reg):
        return self._transact(CMD_NR_R, reg, 1, b"", HDR_HZ)[0]

    def nr_write(self, reg, val):
        self.xfer(build_header(CMD_NR_W, reg, 1, val=val), b"", 0, HDR_HZ)

    def raster_line(self):
        """NR $1E, $1F, $1E; retry while the two MSB reads differ."""
        for _ in range(1 + RASTER_RETRIES):
            m1 = self.nr_read(0x1E) & 1
            lsb = self.nr_read(0x1F)
            m2 = self.nr_read(0x1E) & 1
            if m1 == m2:
                return (m1 << 8) | lsb
        raise LinkError("raster MSB unstable")


class ServeHelper:
    """Client for one persistent `spi303 serve` process.

    Request: [op u8][cmd u8][addr u24][len u16][hz u32][payload], little-endian.
    Reply: [status u8][len u16][data]. op 1 = write, 2 = read; status 0 = ok.
    op 3 push: len = chunk, then [total u32][flags u8][hb u32][frame].
    op 4 pushspans: addr = base, len = count, then [flags u8][hb u32],
    count x [off u24][len u16], then the span bytes in order.
    flags bit 0 = read back each transaction's last 16 bytes at 2 MHz; hb = mailbox
    phys whose hb_pi is bumped every 100 ms, 0 = none. Reply: [ntx u32][bad u32][ns u64].
    """

    def __init__(self, proc):
        self.proc = proc

    @classmethod
    def spawn(cls, argv):
        import subprocess
        return cls(subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    bufsize=0))

    def _call(self, op, cmd, addr, n, hz, payload, want=None):
        req = bytes([op, cmd]) + addr.to_bytes(3, "little") + struct.pack("<HI", n, hz) + payload
        try:
            self.proc.stdin.write(req)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as e:
            raise LinkError("serve pipe write failed: %s" % e)
        status, ln = struct.unpack("<BH", self._take(3))
        data = self._take(ln)
        if status != 0:
            raise LinkError("serve status %d" % status)
        if want is None:
            want = n if op == OP_READ else 0
        if ln != want:
            raise LinkError("serve reply %d bytes, expected %d" % (ln, want))
        return data

    def _take(self, n):
        buf = b""
        while len(buf) < n:
            try:
                part = self.proc.stdout.read(n - len(buf))
            except (BrokenPipeError, OSError, ValueError) as e:
                raise LinkError("serve pipe read failed: %s" % e)
            if not part:
                raise LinkError("serve pipe closed")
            buf += part
        return buf

    def write(self, cmd, addr, data, hz):
        self._call(OP_WRITE, cmd, addr, len(data), hz, bytes(data))

    def read(self, cmd, addr, n, hz):
        return self._call(OP_READ, cmd, addr, n, hz, b"")

    def push(self, cmd, addr, data, hz, chunk=MAX_CHUNK, verify=False, hb=0):
        """Whole frame in one exchange; returns (ntx, bad, ns)."""
        if not 1 <= chunk <= MAX_CHUNK:
            raise LinkError("chunk %d outside 1..%d" % (chunk, MAX_CHUNK))
        ext = struct.pack("<IBI", len(data), PUSH_VERIFY if verify else 0, hb)
        rep = self._call(OP_PUSH, cmd, addr, chunk, hz, ext + bytes(data), want=PUSH_REPLY)
        return struct.unpack("<IIQ", rep)

    def pushspans(self, cmd, base, spans, hz, verify=False, hb=0):
        """spans: [(offset, bytes)]; each span is split into 4000-byte transactions."""
        if len(spans) > 0xFFFF or any(not 1 <= len(d) <= 0xFFFF for _, d in spans):
            raise LinkError("span list outside the u16 count/length fields")
        table = b"".join(off.to_bytes(3, "little") + struct.pack("<H", len(d))
                         for off, d in spans)
        ext = struct.pack("<BI", PUSH_VERIFY if verify else 0, hb)
        body = ext + table + b"".join(bytes(d) for _, d in spans)
        rep = self._call(OP_PUSHSPANS, cmd, base, len(spans), hz, body, want=PUSH_REPLY)
        return struct.unpack("<IIQ", rep)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        wait = getattr(self.proc, "wait", None)
        if wait is not None:
            wait(timeout=5)


class SpidevLink(Link):
    """Real link. 2 MHz single-speed goes through spidev; split-rate through the
    serve helper, or through a hand-built two-transfer ioctl when py_ioctl is set."""

    def __init__(self, bus=0, dev=0, lock=None, helper=None, py_ioctl=False):
        self.bus, self.dev = bus, dev
        self.lock = lock if lock is not None else FlockProvider()
        self.helper = helper
        self.py_ioctl = py_ioctl
        self._spi = None
        self._locked = False

    def open(self, clock=None):
        clock = clock or RealClock()
        if not self.lock.acquire(LOCK_TIMEOUT_S, clock):
            raise BusBusy("SPI bus lock busy after %d s" % LOCK_TIMEOUT_S)
        self._locked = True
        try:
            import spidev
            self._spi = spidev.SpiDev()
            self._spi.open(self.bus, self.dev)
            self._spi.mode = 0
            self._spi.max_speed_hz = HDR_HZ
        except BaseException:
            self.close()
            raise
        return self

    def close(self):
        try:
            if self.helper is not None:
                self.helper.close()     # reap the serve child before dropping the lock
            if self._spi is not None:
                self._spi.close()
                self._spi = None
        finally:
            if self._locked:
                self.lock.release()
                self._locked = False

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()

    def _transact(self, cmd, addr, n, payload, hz):
        if hz > HDR_HZ and self.helper is not None:
            if cmd in READ_CMDS:
                return self.helper.read(cmd, addr, n, hz)
            self.helper.write(cmd, addr, payload, hz)
            return b""
        return super()._transact(cmd, addr, n, payload, hz)

    def xfer(self, header, payload, n_rx, hz, header_hz=HDR_HZ):
        if hz <= HDR_HZ or (not payload and not n_rx):
            tx = header + payload + bytes(n_rx)
            rx = self._spi.xfer2(list(tx), HDR_HZ)
            return bytes(rx[len(header) + len(payload):])
        if not self.py_ioctl:
            raise LinkError("split-rate transfer needs a serve helper or py_ioctl")
        return self._ioctl_split(header, payload, n_rx, hz, header_hz)

    def _ioctl_split(self, header, payload, n_rx, hz, header_hz):
        import ctypes
        import fcntl
        body = payload if payload else bytes(n_rx)
        tx1 = ctypes.create_string_buffer(header, len(header))
        rx1 = ctypes.create_string_buffer(len(header))
        tx2 = ctypes.create_string_buffer(body, len(body))
        rx2 = ctypes.create_string_buffer(len(body))
        (l0, s0, c0), (l1, s1, c1) = plan_split(header, body, hz)
        msg = (pack_spi_transfer(ctypes.addressof(tx1), ctypes.addressof(rx1), l0, s0,
                                 cs_change=c0)
               + pack_spi_transfer(ctypes.addressof(tx2), ctypes.addressof(rx2), l1, s1,
                                   cs_change=c1))
        fcntl.ioctl(self._spi.fileno(), spi_ioc_message(2), msg)
        return bytes(rx2.raw[:n_rx]) if n_rx else b""
