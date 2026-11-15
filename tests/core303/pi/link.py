"""SPI link to the Next Pi debug slave (pi_debug_control readme framing).

Every command is a header transfer at 2 MHz followed by a payload transfer at the
rate under test, CE held between them. The slave has no flow control, so only the
payload may run above 2 MHz.
"""
import struct
import time

HDR_HZ = 2_000_000
MAX_CHUNK = 4000
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
    """Header bytes per the readme, including any junk byte before the data.

    SRAM_R: cmd a2 a1 a0 l1 l0 junk (readme L68)   payload: n read bytes
    SRAM_W: cmd a2 a1 a0 l1 l0      (readme L71)   payload: n write bytes
    BRAM_R: cmd a1 a0 l1 l0 junk    (readme L60)   payload: n read bytes
    BRAM_W: cmd a1 a0 l1 l0         (readme L64)   payload: n write bytes
    NR_R:   cmd reg junk            (readme L74)   payload: 1 read byte
    NR_W:   cmd reg val junk        (readme L77)   no payload
    VERSION: cmd junk               (readme L42)   payload: 2 read bytes
    """
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

    def _write(self, cmd, addr, data, hz):
        data = bytes(data)
        for off in range(0, len(data), MAX_CHUNK):
            chunk = data[off:off + MAX_CHUNK]
            self._transact(cmd, addr + off, len(chunk), chunk, hz)

    def _read(self, cmd, addr, n, hz):
        out = bytearray()
        for off in range(0, n, MAX_CHUNK):
            out += self._transact(cmd, addr + off, min(MAX_CHUNK, n - off), b"", hz)
        return bytes(out)

    def write_mem(self, phys, data, hz):
        self._write(CMD_SRAM_W, phys, data, hz)

    def read_mem(self, phys, n, hz=HDR_HZ):
        return self._read(CMD_SRAM_R, phys, n, hz)

    @staticmethod
    def _bram_addr(bank, off):
        return (off & 0x7FFF) | (0x8000 if bank == 7 else 0)

    def bram_write(self, bank, off, data, hz):
        self._write(CMD_BRAM_W, self._bram_addr(bank, off), data, hz)

    def bram_read(self, bank, off, n, hz=HDR_HZ):
        return self._read(CMD_BRAM_R, self._bram_addr(bank, off), n, hz)

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
    """

    def __init__(self, proc):
        self.proc = proc

    @classmethod
    def spawn(cls, argv):
        import subprocess
        return cls(subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    bufsize=0))

    def _call(self, op, cmd, addr, n, hz, payload):
        req = bytes([op, cmd]) + addr.to_bytes(3, "little") + struct.pack("<HI", n, hz) + payload
        self.proc.stdin.write(req)
        self.proc.stdin.flush()
        head = self._take(3)
        status, ln = struct.unpack("<BH", head)
        data = self._take(ln)
        if status != 0:
            raise LinkError("serve status %d" % status)
        return data

    def _take(self, n):
        buf = b""
        while len(buf) < n:
            part = self.proc.stdout.read(n - len(buf))
            if not part:
                raise LinkError("serve pipe closed")
            buf += part
        return buf

    def write(self, cmd, addr, data, hz):
        self._call(OP_WRITE, cmd, addr, len(data), hz, bytes(data))

    def read(self, cmd, addr, n, hz):
        return self._call(OP_READ, cmd, addr, n, hz, b"")

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass


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
        if self._spi is not None:
            self._spi.close()
            self._spi = None
        if self.helper is not None:
            self.helper.close()
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
        msg = (pack_spi_transfer(ctypes.addressof(tx1), ctypes.addressof(rx1), len(header),
                                 header_hz, cs_change=0)
               + pack_spi_transfer(ctypes.addressof(tx2), ctypes.addressof(rx2), len(body),
                                   hz, cs_change=0))
        fcntl.ioctl(self._spi.fileno(), spi_ioc_message(2), msg)
        return bytes(rx2.raw[:n_rx]) if n_rx else b""
