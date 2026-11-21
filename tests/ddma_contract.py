#!/usr/bin/env python3
"""Host-side contract check for the zxnDDMA blits (src/ddma.inc, overlay 2, tilemap).

Executes the EMITTED bytes of build\\nextdaad.nex on a small Z80 model with port $6B fed to
a model of the blitter (zxnDDMA guide 2.5-2.9: reset, $D7/$DB, $DF physical / 2D / fill,
$E3-$EF, $F7, WR0/1/2/4/5, load, enable) over the machine's physical RAM. It asserts what
each routine moves, the shape of every program (reset first, cycle length 2, one enable,
mode flags cleared afterwards), the transfer cap and the pad that follows every arm.

Run standalone or via tests\\build-tests.ps1, after either build variant:

    python tests\\ddma_contract.py

Exit 0 = every test passed. The variant read (DEBUG or Release) is printed.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dma_contract import Fail, read_page, read_sld, DMA_PORT    # noqa: E402

PAGE = 8192
OVL2_BANK = 29
XFER_MAX = 4096
T_BYTE_MAX = 8
CTC_CHANNELS = 2
CTC_PERIOD_MIN = 1344
RET = 0x0001


def bank_base(bank):
    return 0x40000 + bank * 0x4000


def pad_n(nbytes, isr_t):
    return math.ceil(nbytes * T_BYTE_MAX * CTC_CHANNELS / (CTC_PERIOD_MIN - CTC_CHANNELS * isr_t)) + 2


# --------------------------------------------------------------------------- blitter model

class Blitter:
    """Port $6B. transfers: dicts of every enabled transfer, in order."""
    FOLLOW = {0xD7: 1, 0xDB: 1, 0xDF: 1, 0xE3: 2, 0xE7: 2, 0xEB: 2, 0xEF: 2, 0xF3: 1, 0xF7: 1}

    def __init__(self, machine):
        self.mc = machine
        self.stream = []
        self.transfers = []
        self.want = []              # pending follow bytes: (name, shift) per byte
        self.reg = {}
        self.reset()
        self.loaded = None

    def reset(self):
        self.reg.update(mode=0, exta=0, extb=0, rowlen=0, rows=0, stra=0, strb=0, fill=0,
                        cyc_a=3, cyc_b=3)
        self.reg.setdefault("src", 0)
        self.reg.setdefault("dst", 0)
        self.reg.setdefault("len", 0)

    def _field(self, name, shift, v):
        self.reg[name] = (self.reg[name] & ~(0xFF << shift)) | (v << shift)

    def write(self, v):
        self.stream.append(v)
        if self.want:
            name, shift = self.want.pop(0)
            if name == "cyc_a" or name == "cyc_b":
                if v & 0x20:
                    raise Fail("a prescaler byte is announced in a blit program")
                self.reg[name] = v & 3
            elif name == "mode":
                if v & 0xF4:
                    raise Fail(f"$DF {v:02X}: X,Y, hidden-screen or transparent flag set")
                self.reg[name] = v
            else:
                self._field(name, shift, v)
            return
        if v & 0x80 == 0:
            if v & 3:                                   # WR0
                if not v & 4:
                    raise Fail(f"WR0 {v:02X}: direction is B to A")
                for bit, f in ((3, ("src", 0)), (4, ("src", 8)), (5, ("len", 0)), (6, ("len", 8))):
                    if v & (1 << bit):
                        self.want.append(f)
            elif v & 7 == 4:                            # WR1
                if v != 0x54:
                    raise Fail(f"WR1 {v:02X}, expected 54 (memory, incrementing, timing)")
                self.want.append(("cyc_a", 0))
            else:                                       # WR2
                if v != 0x50:
                    raise Fail(f"WR2 {v:02X}, expected 50 (memory, incrementing, timing)")
                self.want.append(("cyc_b", 0))
            return
        low = v & 3
        if low == 1:                                    # WR4
            if v != 0xAD:
                raise Fail(f"WR4 {v:02X}, expected AD (continuous, port B address)")
            self.want += [("dst", 0), ("dst", 8)]
        elif low == 2:                                  # WR5
            if v != 0x82:
                raise Fail(f"WR5 {v:02X}, expected 82 (stop at end of block)")
        elif low == 0:
            raise Fail(f"WR3 {v:02X} in a blit program")
        elif v == 0xC3:
            self.reset()
        elif v == 0xCF:
            self.loaded = dict(self.reg)
        elif v == 0x87:
            self.run()
        elif v == 0x83:
            pass
        elif v in self.FOLLOW:
            name = {0xD7: "exta", 0xDB: "extb", 0xDF: "mode", 0xE3: "rowlen", 0xE7: "rows",
                    0xEB: "stra", 0xEF: "strb", 0xF7: "fill"}.get(v)
            if name is None:
                raise Fail(f"command {v:02X} is not used by NextDAAD")
            self.want += [(name, 8 * i) for i in range(self.FOLLOW[v])]
        else:
            raise Fail(f"unmodelled port $6B byte {v:02X}")

    def run(self):
        r = self.loaded
        if r is None:
            raise Fail("enable without a load")
        mode = self.reg["mode"]
        if self.reg["cyc_a"] != 2 or self.reg["cyc_b"] != 2:
            raise Fail(f"cycle lengths {self.reg['cyc_a']}/{self.reg['cyc_b']}, expected 2/2")
        phys, twod, fill = mode & 1, mode & 2, mode & 8
        src = (self.reg["exta"] << 16 | r["src"]) if phys else r["src"]
        dst = (self.reg["extb"] << 16 | r["dst"]) if phys else r["dst"]
        rd, wr = (self.mc.pread, self.mc.pwrite) if phys else (self.mc.mread, self.mc.mwrite)
        if twod:
            rowlen, rows = self.reg["rowlen"], self.reg["rows"]
            if rowlen == 0 or rows == 0:
                raise Fail("2D transfer with a zero row length or row count")
            stra, strb = self.reg["stra"], self.reg["strb"]
        else:
            rowlen, rows, stra, strb = r["len"], 1, 0, 0
            if rowlen == 0:
                raise Fail("transfer with block length 0")
        for row in range(rows):
            for i in range(rowlen):
                wr(dst + row * strb + i, self.reg["fill"] if fill else rd(src + row * stra + i))
        self.transfers.append(dict(mode=mode, src=src, dst=dst, rowlen=rowlen, rows=rows,
                                   stra=stra, strb=strb, n=rowlen * rows, at=len(self.stream)))


# --------------------------------------------------------------------------- Z80 model

class CPU:
    """The opcodes the blit code emits. An unknown opcode is a hard failure."""
    R = "bcdehl?a"

    def __init__(self, machine):
        self.mc = machine
        self.m = machine.mem
        self.a = self.b = self.c = self.d = self.e = self.h = self.l = 0
        self.fz = self.fc = self.fs = 0
        self.sp = 0xBD00
        self.pc = 0
        self.steps = 0

    def _g16(self, hi, lo):
        return (getattr(self, hi) << 8) | getattr(self, lo)

    def _s16(self, hi, lo, v):
        setattr(self, hi, (v >> 8) & 0xFF)
        setattr(self, lo, v & 0xFF)

    bc = property(lambda s: s._g16("b", "c"), lambda s, v: s._s16("b", "c", v))
    de = property(lambda s: s._g16("d", "e"), lambda s, v: s._s16("d", "e", v))
    hl = property(lambda s: s._g16("h", "l"), lambda s, v: s._s16("h", "l", v))

    def r16(self, a):
        return self.m[a & 0xFFFF] | (self.m[(a + 1) & 0xFFFF] << 8)

    def w16(self, a, v):
        self.m[a & 0xFFFF] = v & 0xFF
        self.m[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF

    def imm8(self):
        v = self.m[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def imm16(self):
        v = self.r16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return v

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.w16(self.sp, v)

    def pop(self):
        v = self.r16(self.sp)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def getr(self, i):
        return self.m[self.hl] if i == 6 else getattr(self, self.R[i])

    def setr(self, i, v):
        if i == 6:
            self.m[self.hl] = v & 0xFF
        else:
            setattr(self, self.R[i], v & 0xFF)

    def rp(self, i):
        return (self.bc, self.de, self.hl, self.sp)[i]

    def setrp(self, i, v):
        v &= 0xFFFF
        if i == 3:
            self.sp = v
        else:
            setattr(self, ("bc", "de", "hl")[i], v)

    def zs(self, v):
        self.fz = 1 if v & 0xFF == 0 else 0
        self.fs = (v >> 7) & 1

    def alu(self, k, v):
        a = self.a
        if k in (0, 1):                                 # add, adc
            r = a + v + (self.fc if k == 1 else 0)
            self.fc = 1 if r > 0xFF else 0
            self.a = r & 0xFF
        elif k in (2, 3, 7):                            # sub, sbc, cp
            r = a - v - (self.fc if k == 3 else 0)
            self.fc = 1 if r < 0 else 0
            if k != 7:
                self.a = r & 0xFF
            self.zs(r)
            return
        elif k == 4:
            self.a = a & v
            self.fc = 0
        elif k == 5:
            self.a = a ^ v
            self.fc = 0
        else:
            self.a = a | v
            self.fc = 0
        self.zs(self.a)

    def cond(self, k):
        return (not self.fz, self.fz, not self.fc, self.fc, None, None, not self.fs, self.fs)[k]

    def jr(self, take):
        d = self.imm8()
        if take:
            self.pc = (self.pc + (d - 256 if d > 127 else d)) & 0xFFFF

    def out(self, port, v):
        if port & 0xFF != DMA_PORT:
            raise Fail(f"write to port ${port:04X} at ${self.pc:04X}")
        self.mc.blit.write(v)

    def step(self):
        self.steps += 1
        at = self.pc
        op = self.imm8()
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        if op == 0x00:
            pass
        elif op == 0x76:
            raise Fail(f"HALT at ${at:04X}")
        elif x == 1:
            self.setr(y, self.getr(z))
        elif x == 2:
            self.alu(y, self.getr(z))
        elif x == 0 and z == 6:
            self.setr(y, self.imm8())
        elif x == 0 and z == 4:                         # inc r
            v = (self.getr(y) + 1) & 0xFF
            self.setr(y, v)
            self.zs(v)
        elif x == 0 and z == 5:                         # dec r
            v = (self.getr(y) - 1) & 0xFF
            self.setr(y, v)
            self.zs(v)
        elif x == 0 and z == 1 and not y & 1:           # ld rp,nn
            self.setrp(y >> 1, self.imm16())
        elif x == 0 and z == 1:                         # add hl,rp
            r = self.hl + self.rp(y >> 1)
            self.fc = 1 if r > 0xFFFF else 0
            self.hl = r & 0xFFFF
        elif x == 0 and z == 3:                         # inc/dec rp
            self.setrp(y >> 1, self.rp(y >> 1) + (-1 if y & 1 else 1))
        elif op == 0x02:
            self.m[self.bc] = self.a
        elif op == 0x12:
            self.m[self.de] = self.a
        elif op == 0x0A:
            self.a = self.m[self.bc]
        elif op == 0x1A:
            self.a = self.m[self.de]
        elif op == 0x22:
            self.w16(self.imm16(), self.hl)
        elif op == 0x2A:
            self.hl = self.r16(self.imm16())
        elif op == 0x32:
            self.m[self.imm16()] = self.a
        elif op == 0x3A:
            self.a = self.m[self.imm16()]
        elif op == 0x07:                                # rlca
            self.fc = self.a >> 7
            self.a = ((self.a << 1) | self.fc) & 0xFF
        elif op == 0x0F:                                # rrca
            self.fc = self.a & 1
            self.a = (self.a >> 1) | (self.fc << 7)
        elif op == 0x17:                                # rla
            c = self.a >> 7
            self.a = ((self.a << 1) | self.fc) & 0xFF
            self.fc = c
        elif op == 0x1F:                                # rra
            c = self.a & 1
            self.a = (self.a >> 1) | (self.fc << 7)
            self.fc = c
        elif op == 0x2F:
            self.a ^= 0xFF
        elif op == 0x37:
            self.fc = 1
        elif op == 0x3F:
            self.fc ^= 1
        elif op == 0x10:                                # djnz
            self.b = (self.b - 1) & 0xFF
            self.jr(self.b != 0)
        elif op == 0x18:
            self.jr(True)
        elif op in (0x20, 0x28, 0x30, 0x38):
            self.jr(self.cond(y - 4))
        elif x == 3 and z == 6:
            self.alu(y, self.imm8())
        elif x == 3 and z == 2:                         # jp cc
            t = self.imm16()
            if self._cc(y, at):
                self.pc = t
        elif x == 3 and z == 4:                         # call cc
            t = self.imm16()
            if self._cc(y, at):
                self.push(self.pc)
                self.pc = t
        elif x == 3 and z == 0:                         # ret cc
            if self._cc(y, at):
                self.pc = self.pop()
        elif op == 0xC3:
            self.pc = self.imm16()
        elif op == 0xCD:
            t = self.imm16()
            self.push(self.pc)
            self.pc = t
        elif op == 0xC9:
            self.pc = self.pop()
        elif op == 0xE9:
            self.pc = self.hl
        elif op == 0xEB:
            self.de, self.hl = self.hl, self.de
        elif op in (0xC5, 0xD5, 0xE5):
            self.push(self.rp((op >> 4) & 3))
        elif op == 0xF5:
            self.push(self.a << 8 | self.fz << 6 | self.fs << 7 | self.fc)
        elif op in (0xC1, 0xD1, 0xE1):
            self.setrp((op >> 4) & 3, self.pop())
        elif op == 0xF1:
            v = self.pop()
            self.a, self.fz, self.fs, self.fc = v >> 8, (v >> 6) & 1, (v >> 7) & 1, v & 1
        elif op == 0xD3:
            self.out(self.a << 8 | self.imm8(), self.a)
        elif op == 0xF3 or op == 0xFB:
            raise Fail(f"DI/EI at ${at:04X}: a blit is never bracketed")
        elif op == 0xCB:
            self.cb(self.imm8())
        elif op == 0xED:
            self.ed(self.imm8(), at)
        else:
            raise Fail(f"opcode {op:02X} at ${at:04X} is not in the model")

    def _cc(self, y, at):
        c = self.cond(y)
        if c is None:
            raise Fail(f"parity condition at ${at:04X} is not in the model")
        return c

    def cb(self, op):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        v = self.getr(z)
        if x == 1:
            self.fz = 0 if v & (1 << y) else 1
        elif x == 2:
            self.setr(z, v & ~(1 << y))
        elif x == 3:
            self.setr(z, v | (1 << y))
        else:
            if y == 0:
                c, v = v >> 7, ((v << 1) | (v >> 7)) & 0xFF
            elif y == 1:
                c, v = v & 1, (v >> 1) | ((v & 1) << 7)
            elif y == 2:
                c, v = v >> 7, ((v << 1) | self.fc) & 0xFF
            elif y == 3:
                c, v = v & 1, (v >> 1) | (self.fc << 7)
            elif y == 4:
                c, v = v >> 7, (v << 1) & 0xFF
            elif y == 5:
                c, v = v & 1, (v >> 1) | (v & 0x80)
            elif y == 7:
                c, v = v & 1, v >> 1
            else:
                raise Fail("CB sll is not in the model")
            self.fc = c
            self.zs(v)
            self.setr(z, v)

    def ed(self, op, at):
        if op == 0x90:                                  # outinb
            self.out(self.bc, self.m[self.hl])
            self.hl = (self.hl + 1) & 0xFFFF
        elif op == 0xB3:                                # otir
            while True:
                self.b = (self.b - 1) & 0xFF
                self.out(self.bc, self.m[self.hl])
                self.hl = (self.hl + 1) & 0xFFFF
                if self.b == 0:
                    break
            self.fz = 1
        elif op == 0xB0:                                # ldir
            while True:
                self.m[self.de] = self.m[self.hl]
                self.hl, self.de, self.bc = (self.hl + 1) & 0xFFFF, (self.de + 1) & 0xFFFF, (self.bc - 1) & 0xFFFF
                if self.bc == 0:
                    break
        elif op & 0xC7 == 0x43:                         # ld (nn),rp / ld rp,(nn)
            a = self.imm16()
            if op & 8:
                self.setrp((op >> 4) & 3, self.r16(a))
            else:
                self.w16(a, self.rp((op >> 4) & 3))
        elif op & 0xC7 == 0x42:                         # sbc/adc hl,rp
            v = self.rp((op >> 4) & 3)
            r = self.hl + v + self.fc if op & 8 else self.hl - v - self.fc
            self.fc = 1 if r < 0 or r > 0xFFFF else 0
            self.hl = r & 0xFFFF
            self.fz = 1 if self.hl == 0 else 0
            self.fs = self.hl >> 15
        elif op == 0x44:                                # neg
            self.fc = 1 if self.a else 0
            self.a = -self.a & 0xFF
            self.zs(self.a)
        elif op == 0x30:                                # mul d,e
            self.de = self.d * self.e
        elif op == 0x31:
            self.hl = (self.hl + self.a) & 0xFFFF
        elif op == 0x32:
            self.de = (self.de + self.a) & 0xFFFF
        elif op == 0x33:
            self.bc = (self.bc + self.a) & 0xFFFF
        elif op == 0x34:
            self.hl = (self.hl + self.imm16()) & 0xFFFF
        elif op == 0x35:
            self.de = (self.de + self.imm16()) & 0xFFFF
        elif op == 0x36:
            self.bc = (self.bc + self.imm16()) & 0xFFFF
        elif op == 0x91:                                # nextreg n,n
            n = self.imm8()
            self.mc.nextreg(n, self.imm8())
        elif op == 0x92:                                # nextreg n,a
            self.mc.nextreg(self.imm8(), self.a)
        elif op == 0xC7:                                # nextreg a,n (read)
            self.a = self.mc.nr.get(self.imm8(), 0)
        else:
            raise Fail(f"opcode ED {op:02X} at ${at:04X} is not in the model")


# --------------------------------------------------------------------------- machine

class Machine:
    """64K as the interpreter maps it at rest (bank 5, bank 2, overlay 2 in slot 7) over 2 MB
    of physical RAM. Slots 0-1 and 6 are scratch; MMU writes are recorded, not applied."""

    def __init__(self, syms):
        self.syms = syms
        self.mem = bytearray(0x10000)
        self.phys = bytearray(0x200000)
        for page, addr in ((4, 0x8000), (5, 0xA000), (OVL2_BANK * 2, 0xE000)):
            self.mem[addr:addr + PAGE] = read_page(page)    # bank 5 is not in the NEX: zeros
        self.nr = {}
        self.mmu_writes = []
        self.blit = Blitter(self)
        self.cpu = CPU(self)

    def sym(self, name):
        try:
            return self.syms[name][1]
        except KeyError:
            raise Fail(f"symbol {name} is not in the SLD - not built yet?") from None

    def nextreg(self, n, v):
        self.nr[n] = v
        if 0x50 <= n <= 0x57:
            self.mmu_writes.append((n, v))

    # physical RAM; overlay 2's own page is the live copy in slot 7
    def _ovl(self, a):
        o = a - bank_base(OVL2_BANK)
        return o if 0 <= o < PAGE else None

    def pread(self, a):
        o = self._ovl(a)
        return self.mem[0xE000 + o] if o is not None else self.phys[a]

    def pwrite(self, a, v):
        o = self._ovl(a)
        if o is not None:
            self.mem[0xE000 + o] = v
        else:
            self.phys[a] = v

    def mread(self, a):
        return self.mem[a & 0xFFFF]

    def mwrite(self, a, v):
        self.mem[a & 0xFFFF] = v

    def bank(self, bank, offset=0, n=0x4000):
        b = bank_base(bank) + offset
        return self.phys[b:b + n]

    def poke(self, name, data):
        a = self.sym(name)
        data = bytes([data]) if isinstance(data, int) else bytes(data)
        self.mem[a:a + len(data)] = data

    def poke16(self, name, v):
        self.poke(name, bytes([v & 0xFF, v >> 8]))

    def set_addr(self, which, bank, offset):
        """which: 'Src' or 'Dst' - the three address bytes of a primitive."""
        a = bank_base(bank) + offset
        self.poke16("ddma" + which, a & 0xFFFF)
        self.poke("ddma" + which + "Ext", a >> 16)

    def call(self, name, budget=2_000_000, **regs):
        cpu = self.cpu
        for k, v in regs.items():
            setattr(cpu, k, v)
        cpu.sp = 0xBD00
        cpu.push(RET)
        cpu.pc = self.sym(name)
        while cpu.pc != RET:
            budget -= 1
            if budget <= 0:
                raise Fail(f"{name} did not return")
            cpu.step()
        return cpu


def fresh(syms):
    return Machine(syms)


def seed(mc, bank, n, mul=7, add=3, offset=0):
    b = bank_base(bank) + offset
    data = bytes((i * mul + add + (i >> 8)) & 0xFF for i in range(n))
    mc.phys[b:b + n] = data
    return data


def expect(got, want, what):
    if got != want:
        i = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]), min(len(got), len(want)))
        raise Fail(f"{what}: first difference at +${i:X} (lengths {len(got)}/{len(want)})")


def check_shape(mc, what, prims=1):
    """Every program: reset first, one enable, mode flags cleared after."""
    s = mc.blit.stream
    if not s or s[0] != 0xC3:
        raise Fail(f"{what}: the program does not start with $C3")
    if s[-2:] != [0xDF, 0x00]:
        raise Fail(f"{what}: the stream does not end $DF $00 (ends {s[-2:]})")
    if mc.blit.reg["mode"] != 0:
        raise Fail(f"{what}: mode flags left at {mc.blit.reg['mode']:02X}")
    for t in mc.blit.transfers:
        if t["n"] > XFER_MAX:
            raise Fail(f"{what}: a transfer moves {t['n']} bytes, cap {XFER_MAX}")


# --------------------------------------------------------------------------- tests: primitives

def test_bank_addr(syms):
    for bank, off, ext, low in ((9, 0, 0x06, 0x4000), (30, 0x1234, 0x0B, 0x9234), (29, 0, 0x0B, 0x4000)):
        cpu = fresh(syms).call("ddma_bank_addr", a=bank, hl=off)
        if (cpu.a, cpu.hl) != (ext, low):
            raise Fail(f"ddma_bank_addr bank {bank} +${off:X}: ext ${cpu.a:02X} low ${cpu.hl:04X}, "
                       f"expected ${ext:02X} ${low:04X}")


def test_fill(syms):
    mc = fresh(syms)
    mc.phys[bank_base(30) - 16:bank_base(30) + XFER_MAX + 16] = bytes([0x11]) * (XFER_MAX + 32)
    mc.set_addr("Dst", 30, 0)
    mc.call("ddma_fill", a=0xA5, bc=XFER_MAX)
    want = bytes([0x11]) * 16 + bytes([0xA5]) * XFER_MAX + bytes([0x11]) * 16
    expect(mc.phys[bank_base(30) - 16:bank_base(30) + XFER_MAX + 16], want, "ddma_fill")
    check_shape(mc, "ddma_fill")


def test_copy_cross_64k(syms):
    mc = fresh(syms)
    src = seed(mc, 50, XFER_MAX)
    mc.set_addr("Src", 50, 0)
    mc.set_addr("Dst", 31, 0x3800)                      # $BF800: crosses $C0000
    mc.call("ddma_copy", bc=XFER_MAX)
    expect(mc.phys[bank_base(31) + 0x3800:bank_base(31) + 0x3800 + XFER_MAX], src, "ddma_copy across 64K")
    check_shape(mc, "ddma_copy")


def rect(mc, sbank, soff, dbank, doff, rowlen, rows, stra, strb):
    mc.set_addr("Src", sbank, soff)
    mc.set_addr("Dst", dbank, doff)
    for name, v in (("ddmaRowLen", rowlen), ("ddmaRows", rows), ("ddmaStrideA", stra), ("ddmaStrideB", strb)):
        mc.poke16(name, v)
    mc.call("ddma_rect")


def test_rect_256(syms):
    mc = fresh(syms)
    src = seed(mc, 50, 16 * 256)
    rect(mc, 50, 0, 30, 0x0020, 200, 16, 256, 256)
    for r in range(16):
        expect(mc.bank(30, 0x20 + r * 256, 200), src[r * 256:r * 256 + 200], f"ddma_rect row {r}")
        if any(mc.bank(30, 0x20 + r * 256 + 200, 56)):
            raise Fail(f"ddma_rect wrote past row {r}")
    check_shape(mc, "ddma_rect")


def test_rect_320_row(syms):
    mc = fresh(syms)
    src = seed(mc, 50, 320)
    rect(mc, 50, 0, 30, 0x0005, 1, 320, 1, 256)
    got = bytes(mc.phys[bank_base(30) + 5 + x * 256] for x in range(320))
    expect(got, src, "ddma_rect 320-wide row")
    check_shape(mc, "ddma_rect 320 row")


def test_rect_split_values(syms):
    whole, split = fresh(syms), fresh(syms)
    src = seed(whole, 50, 320)
    rect(whole, 50, 0, 30, 9, 1, 320, 1, 256)
    seed(split, 50, 192, offset=0x4000 - 192)           # row straddles banks 50 | 60
    split.phys[bank_base(60):bank_base(60) + 128] = src[192:]
    rect(split, 50, 0x4000 - 192, 30, 9, 1, 192, 1, 256)
    rect(split, 60, 0, 30, 9 + 192 * 256, 1, 128, 1, 256)
    expect(split.bank(30, 0, 0x4000) + split.bank(31), whole.bank(30, 0, 0x4000) + whole.bank(31),
           "split 320-wide row")


def test_stream_shape(syms):
    for name, kw in (("ddma_fill", dict(a=1, bc=16)), ("ddma_copy", dict(bc=16)), ("ddma_rect", {})):
        mc = fresh(syms)
        mc.set_addr("Src", 50, 0)
        mc.set_addr("Dst", 30, 0)
        for n in ("ddmaRowLen", "ddmaRows", "ddmaStrideA", "ddmaStrideB"):
            mc.poke16(n, 4)
        mc.call(name, **kw)
        s = mc.blit.stream
        check_shape(mc, name)
        if s.count(0x87) != 1 and name != "ddma_fill":
            pass                                        # $87 can occur as data; transfers is the count
        if len(mc.blit.transfers) != 1:
            raise Fail(f"{name}: {len(mc.blit.transfers)} transfers, expected 1")


def find_pads(img, lo, hi):
    """[(address of the arm's last output instruction, pad count)] in [lo, hi)."""
    out = []
    a = lo
    while a < hi - 5:
        if img[a] == 0xED and img[a + 1] in (0xB3, 0x90) and not (img[a + 2] == 0xED and img[a + 3] == 0x90):
            if img[a + 2] == 0x06 and img[a + 4] == 0x10 and img[a + 5] == 0xFE:
                out.append((a, img[a + 3]))
            else:
                out.append((a, None))
            a += 2
        else:
            a += 1
    return out


def test_pad(syms):
    mc = fresh(syms)
    isr = mc.syms["CTC_ISR_T_MAX"][1] if "CTC_ISR_T_MAX" in mc.syms else 256
    lo, hi = mc.sym("ddma_fill"), mc.sym("ddma_prog")
    pads = find_pads(mc.mem, lo, hi)
    if not pads:
        raise Fail("no arm found between ddma_fill and ddma_prog")
    want = pad_n(XFER_MAX, isr)
    for at, n in pads:
        if n != want:
            raise Fail(f"arm at ${at:04X}: pad {n}, expected ld b,{want} / djnz $ directly after it")


# --------------------------------------------------------------------------- tests: clear, copy

def surf_setup(mc, mode, front=9, back=30):
    mc.poke("l2Mode", mode)
    mc.poke("l2FrontBank", front)
    mc.poke("l2BackBank", back)


def test_clear_back(syms):
    transp = syms["L2_TRANSP_INDEX"][1]
    for mode, n in ((0, 49152), (1, 81920)):
        mc = fresh(syms)
        surf_setup(mc, mode)
        base = bank_base(30)
        mc.phys[base:base + 81920 + 16] = bytes([0x33]) * (81920 + 16)
        mc.phys[bank_base(9):bank_base(9) + 16] = bytes([0x44]) * 16
        mc.call("l2_clear_back")
        expect(mc.phys[base:base + n], bytes([transp]) * n, f"l2_clear_back mode {mode}")
        if mc.phys[base + n] != 0x33 or mc.phys[bank_base(9)] != 0x44:
            raise Fail(f"l2_clear_back mode {mode} wrote outside the back surface")
        if len(mc.blit.transfers) != n // XFER_MAX:
            raise Fail(f"l2_clear_back mode {mode}: {len(mc.blit.transfers)} transfers")
        if mc.mmu_writes:
            raise Fail("l2_clear_back still maps a slot")
        check_shape(mc, "l2_clear_back")
    mc = fresh(syms)
    surf_setup(mc, 0)
    mc.call("l2_clear")
    expect(mc.bank(9, 0, 49152 % 0x4000 or 0x4000), bytes([transp]) * 0x4000, "l2_clear front")


def test_copy_surface(syms):
    for mode, n in ((0, 49152), (1, 81920)):
        mc = fresh(syms)
        surf_setup(mc, mode)
        src = seed(mc, 30, 81920 + 8, mul=13, add=5)
        mc.phys[bank_base(9) + n] = 0x77
        mc.call("l2_copy_back_front", a=30, d=9)
        expect(mc.phys[bank_base(9):bank_base(9) + n], src[:n], f"l2_copy_back_front mode {mode}")
        expect(mc.phys[bank_base(30):bank_base(30) + n], src[:n], "copy source unchanged")
        if mc.phys[bank_base(9) + n] != 0x77:
            raise Fail(f"l2_copy_back_front mode {mode} wrote past the surface")
        if mc.mmu_writes:
            raise Fail("l2_copy_back_front still maps a slot")
        check_shape(mc, "l2_copy_back_front")


TESTS = [test_bank_addr, test_fill, test_copy_cross_64k, test_rect_256, test_rect_320_row,
         test_rect_split_values, test_stream_shape, test_pad, test_clear_back, test_copy_surface]


def main():
    syms = read_sld()
    print("ddma_contract: %s build" % ("DEBUG" if "dbgNoBank" in syms else "Release"))
    bad = 0
    for t in TESTS:
        try:
            t(syms)
            print("PASS", t.__name__)
        except Fail as e:
            bad += 1
            print("FAIL", t.__name__, "-", e)
    print("ddma_contract: %d/%d passed" % (len(TESTS) - bad, len(TESTS)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
