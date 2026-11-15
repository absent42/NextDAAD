"""Pi side of the Next mailbox page (little-endian, offsets within the page).

Every write is a single owned field at 2 MHz, read back and compared with up to 3
retries. A write never spans another side's field.
"""
import struct
from collections import namedtuple

from link import HDR_HZ, RealClock

MAGIC = b"M303"
OFF_SEQ, OFF_CMD, OFF_ARG0, OFF_ARG1, OFF_ARG32 = 4, 5, 6, 7, 8
OFF_ACK, OFF_STATE, OFF_HB_NEXT, OFF_HB_PI, OFF_LEADER = 12, 13, 14, 16, 18
HEAD_LEN = 19

STATE_BOOT, STATE_READY, STATE_DONE, STATE_FAILED, STATE_EXITING = 0, 1, 2, 3, 4
CMD_QUIET, CMD_STREAM, CMD_STOP, CMD_LOAD, CMD_END, CMD_HANDOVER, CMD_YIELD = 1, 2, 3, 4, 5, 6, 7

WRITE_RETRIES = 3
POLL_S = 0.002

Cmd = namedtuple("Cmd", "seq cmd arg0 arg1 arg32")


class MailboxError(Exception):
    pass


class MailboxTimeout(MailboxError):
    pass


class Mailbox:
    def __init__(self, link, phys, clock=None):
        self.link = link
        self.phys = phys
        self.clock = clock or RealClock()
        self._hb = 0
        self._acked = None

    def _read(self, off, n):
        return self.link.read_mem(self.phys + off, n, HDR_HZ)

    def _write(self, off, data):
        data = bytes(data)
        for _ in range(1 + WRITE_RETRIES):
            self.link.write_mem(self.phys + off, data, HDR_HZ)
            if self._read(off, len(data)) == data:
                return
        raise MailboxError("write at +%d failed read-back" % off)

    def state(self):
        return self._read(OFF_STATE, 1)[0]

    def leader(self):
        return self._read(OFF_LEADER, 1)[0]

    def read_hb_next(self):
        return struct.unpack("<H", self._read(OFF_HB_NEXT, 2))[0]

    def bump_hb_pi(self):
        self._hb = (self._hb + 1) & 0xFFFF
        self._write(OFF_HB_PI, struct.pack("<H", self._hb))

    def send(self, cmd, arg0=0, arg1=0, arg32=0, timeout_s=1.0):
        """Leader only: write the command, bump cmd_seq last, wait for ack_seq."""
        if self.leader() != 0:
            raise MailboxError("Pi is not the leader")
        if self.state() != STATE_READY:
            raise MailboxError("Next not ready")
        seq = (self._read(OFF_SEQ, 1)[0] + 1) & 0xFF
        self._write(OFF_ARG0, [arg0 & 0xFF])
        self._write(OFF_ARG1, [arg1 & 0xFF])
        self._write(OFF_ARG32, struct.pack("<I", arg32 & 0xFFFFFFFF))
        self._write(OFF_CMD, [cmd])
        self._write(OFF_SEQ, [seq])
        end = self.clock.time() + timeout_s
        while self._read(OFF_ACK, 1)[0] != seq:
            if self.clock.time() >= end:
                raise MailboxTimeout("no ack for command %d seq %d" % (cmd, seq))
            self.clock.sleep(POLL_S)
        return seq

    def poll(self):
        """Follower only: the pending command, or None. Stale pages are ignored."""
        head = self._read(0, HEAD_LEN)
        if head[0:4] != MAGIC or head[OFF_STATE] != STATE_READY or head[OFF_LEADER] != 1:
            return None
        seq = head[OFF_SEQ]
        if seq == head[OFF_ACK] or seq == self._acked:
            return None
        return Cmd(seq, head[OFF_CMD], head[OFF_ARG0], head[OFF_ARG1],
                   struct.unpack_from("<I", head, OFF_ARG32)[0])

    def ack(self, cmd):
        self._write(OFF_ACK, [cmd.seq])
        self._acked = cmd.seq


class Heartbeat:
    """Bumps hb_pi every period_s; suspended inside a QUIET window (zero SPI)."""

    def __init__(self, mailbox, clock, period_s=0.1):
        self.mailbox = mailbox
        self.clock = clock
        self.period_s = period_s
        self._last = None
        self._suspended = False

    def tick(self):
        if self._suspended:
            return False
        now = self.clock.time()
        if self._last is not None and now - self._last < self.period_s:
            return False
        self.mailbox.bump_hb_pi()
        self._last = now
        return True

    def suspend(self):
        self._suspended = True

    def resume(self):
        self._suspended = False
