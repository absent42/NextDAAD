"""In-memory model of the Pi debug slave, including its lost-byte fault.

The slave has no flow control: at an over-rate payload a byte can be dropped, and
the rest of that transaction lands one address early. The next transaction
reloads its address and is unaffected.
"""
from collections import namedtuple

import link
from link import HDR_HZ

SRAM_SIZE = 0x200000

Txn = namedtuple("Txn", "cmd addr n header_hz payload_hz")


class SimFault(Exception):
    pass


class SimLink(link.Link):
    VERSION = 0x11
    CAPS = 0xFF

    def __init__(self, loss=None, header_hz_check=True, raster=None):
        self.loss = loss
        self.header_hz_check = header_hz_check
        self.raster = raster or (lambda: 0)
        self.sram = bytearray(SRAM_SIZE)
        self.bram5 = bytearray(0x4000)
        self.bram7 = bytearray(0x2000)
        self.nrs = {}
        self.log = []
        self._tx = 0

    def _kept(self, n):
        """Payload byte indices that survive this transaction."""
        tx = self._tx
        self._tx += 1
        if self.loss is None:
            return range(n)
        return [i for i in range(n) if not self.loss(tx, i)]

    @staticmethod
    def _need(header, n, what):
        if len(header) != n:
            raise SimFault("%s header is %d bytes, expected %d" % (what, len(header), n))

    def xfer(self, header, payload, n_rx, hz, header_hz=HDR_HZ):
        if self.header_hz_check and header_hz > HDR_HZ:
            raise SimFault("header at %d Hz" % header_hz)
        cmd = header[0]
        if cmd == link.CMD_VERSION:
            self._need(header, 2, "VERSION")
            self.log.append(Txn(cmd, 0, 2, header_hz, hz))
            return bytes([self.VERSION, self.CAPS])[:n_rx]
        if cmd in (link.CMD_NR_R, link.CMD_NR_W):
            return self._nr(header, header_hz, hz)
        if cmd in (link.CMD_SRAM_R, link.CMD_SRAM_W):
            sram_r = cmd == link.CMD_SRAM_R
            self._need(header, 7 if sram_r else 6, "SRAM")
            addr = ((header[1] & 0x1F) << 16) | (header[2] << 8) | header[3]
            n = (header[4] << 8) | header[5]
            mem, size, base = self.sram, SRAM_SIZE, addr
        elif cmd in (link.CMD_BRAM_R, link.CMD_BRAM_W):
            bram_r = cmd == link.CMD_BRAM_R
            self._need(header, 6 if bram_r else 5, "BRAM")
            addr = (header[1] << 8) | header[2]
            n = (header[3] << 8) | header[4]
            mem = self.bram7 if addr & 0x8000 else self.bram5
            size, base = len(mem), addr & 0x7FFF
        else:
            raise SimFault("bad command %02X" % cmd)
        self.log.append(Txn(cmd, addr, n, header_hz, hz))
        kept = self._kept(n)
        if cmd in link.READ_CMDS:
            data = bytes(mem[(base + i) % size] for i in range(n))
            out = bytes(data[i] for i in kept)
            return out + bytes(n - len(out))
        if len(payload) != n:
            raise SimFault("payload %d bytes, header says %d" % (len(payload), n))
        for pos, i in enumerate(kept):
            mem[(base + pos) % size] = payload[i]
        return b""

    def _nr(self, header, header_hz, hz):
        reg = header[1]
        if header[0] == link.CMD_NR_R:
            self._need(header, 3, "NR_R")
            self.log.append(Txn(header[0], reg, 1, header_hz, hz))
            if reg == 0x1E:
                return bytes([(self.raster() >> 8) & 1])
            if reg == 0x1F:
                return bytes([self.raster() & 0xFF])
            return bytes([self.nrs.get(reg, 0)])
        self._need(header, 4, "NR_W")
        self.log.append(Txn(header[0], reg, 1, header_hz, hz))
        self.nrs[reg] = header[2]
        return b""
