"""One NextDAAD run on a harness CSpect: boot, symbols, memory, screen, keys, debugger and
timing primitives over MCP. Waits poll a condition or FRAMECOUNTER against a deadline."""
import base64
import importlib.util
import io
import re
import time
from collections import Counter
from pathlib import Path

from . import launcher
from .client import CSpectError, read_map

TESTS = Path(__file__).resolve().parents[1]
TM_MAP = 0x6000              # tilemap grid, bank 5 in MMU slot 3
PAGE_SIZE = 0x2000
BANK5_SLOT = {10: 2, 11: 3}  # CSpect's physical view lacks 16K bank 5: read it through slots 2/3
STOP_S = 30.0                # a breakpoint stop on the boot path or in time_between
RUN_TO_MAX_MS = 120000       # run_to / wait_for_stop timeout_ms ceiling
LINES_PER_FRAME = 311        # +3 timing
FRAME_TICK_LINE = 248        # NR $1E/$1F line of the frame interrupt (FRAMECOUNTER tick)
SCREEN = (320, 256)
PAPER_BOX = (32, 32, 288, 224)   # the 256x192 inside the border band
AY_SELECTS = (0xFF, 0xFE, 0xFD)  # Turbo Sound PSG 1-3 on $FFFD
AY_FRAME_END = (2, 13)       # PSG 3 R13: the select aud_dbg_snap leaves every DEBUG frame
ULA_DEFAULT = (0x00, 0x02, 0xA0, 0xA2, 0x14, 0x16, 0xB4, 0xB6)   # ULA 0-7, RRRGGGBB
REG_NAMES = frozenset({"A", "F", "B", "C", "D", "E", "H", "L", "I", "R", "AF", "BC", "DE", "HL",
                       "IX", "IY", "IXH", "IXL", "IYH", "IYL", "SP", "PC", "AF'", "BC'", "DE'",
                       "HL'", "IM", "IFF1", "IFF2"})


def _load_tilemap():
    spec = importlib.util.spec_from_file_location("nextdaad_tilemap", TESTS / "parser" / "tilemap.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tilemap = _load_tilemap()

_STATE = re.compile(r"^CPU: (stopped|running)\b", re.M)
_FIELDS = (("PC", r"(?<![\w'])PC\s+\$([0-9A-Fa-f]{4})\b"), ("SP", r"(?<![\w'])SP\s+\$([0-9A-Fa-f]{4})\b"),
           *((n, rf"(?<![\w']){n}\s+\$([0-9A-Fa-f]{{4}})\b") for n in ("AF", "BC", "DE", "HL", "IX", "IY")),
           *((n + "'", rf"\b{n}'\s*\$([0-9A-Fa-f]{{4}})\b") for n in ("AF", "BC", "DE", "HL")),
           ("I", r"(?<![\w'])I\s+\$([0-9A-Fa-f]{2})\b"), ("R", r"(?<![\w'])R\s+\$([0-9A-Fa-f]{2})\b"),
           ("IM", r"\bIM\s+([0-2])\b"), ("IFF1", r"\bIFF1\s+([01])\b"), ("IFF2", r"\bIFF2\s+([01])\b"))


def parse_status(text: str, tool: str = "get_status") -> tuple[str, dict[str, int]]:
    """('stopped' | 'running', registers) from a get_status-shaped reply; any gap raises."""
    start = text.find("CPU:")
    block = text[start:].split("\n\n")[0] if start >= 0 else ""
    state = _STATE.search(block)
    regs, missing = {}, []
    for name, pat in _FIELDS:
        hits = re.findall(pat, block)
        if len(hits) != 1:
            missing.append(name)
            continue
        regs[name] = int(hits[0], 16 if name not in ("IM", "IFF1", "IFF2") else 10)
    if not state or missing:
        raise CSpectError(f"{tool} reply lacks {'CPU state' if not state else ', '.join(missing)}: "
                          f"{text[:240]!r}")
    for pair, hi, lo in (("AF", "A", "F"), ("BC", "B", "C"), ("DE", "D", "E"), ("HL", "H", "L"),
                         ("IX", "IXH", "IXL"), ("IY", "IYH", "IYL")):
        regs[hi], regs[lo] = regs[pair] >> 8, regs[pair] & 0xFF
    return state.group(1), regs


def boot_args(paused=False, brk_addr=None, major=None, minor=None) -> list[str]:
    """CSpect extras for boot(). -major=/-minor= take decimal only: '$32' and '0x32' are ignored."""
    args = []
    for flag, v in (("major", major), ("minor", minor)):
        if v is not None:
            if not 0 <= v <= 255:
                raise ValueError(f"{flag} {v} is not a byte")
            args.append(f"-{flag}={v}")
    if paused:
        args.append("-debug")                                # stopped at the NEX entry
    if brk_addr is not None:
        args.append(f"+brk=${brk_addr:04X}")
    return args


def raster_elapsed(f0: int, l0: int, f1: int, l1: int) -> tuple[int, int]:
    """(frames, lines) between two (FRAMECOUNTER, raster line) stops, lines in 0..310; the
    counter ticks at FRAME_TICK_LINE, so a stop at or past it counts one frame early."""
    frames = ((f1 - f0) & 0xFFFF) - (l1 >= FRAME_TICK_LINE) + (l0 >= FRAME_TICK_LINE)
    total = frames * LINES_PER_FRAME + l1 - l0
    if total < 0:
        raise CSpectError(f"FRAMECOUNTER ${f0:04X} -> ${f1:04X} missed a tick between lines {l0} and "
                          f"{l1} (interrupts off?)")
    return divmod(total, LINES_PER_FRAME)


def _expand3(c: int) -> int:
    return (c << 5) | (c << 2) | (c >> 1)


def _rgb(rrrgggbb: int) -> tuple[int, int, int]:
    """9-bit colour of an 8-bit palette value: the low blue bit is blue bit 1 OR bit 0 (NR $41)."""
    b = (rrrgggbb & 3) << 1 | (1 if rrrgggbb & 3 else 0)
    return _expand3(rrrgggbb >> 5), _expand3(rrrgggbb >> 2 & 7), _expand3(b)


ULA_RGB = tuple(_rgb(v) for v in ULA_DEFAULT)


def ula_border_index(img) -> int:
    """The border band's most common colour as a default-palette ULA index 0-7; raises otherwise."""
    if img.size != SCREEN:
        raise ValueError(f"screenshot is {img.size}, not {SCREEN}")
    x0, y0, x1, y1 = PAPER_BOX
    seen = Counter()
    for box in ((0, 0, 320, y0), (0, y1, 320, 256), (0, y0, x0, y1), (x1, y0, 320, y1)):
        seen.update(img.crop(box).getdata())
    rgb = seen.most_common(1)[0][0]
    for i, want in enumerate(ULA_RGB):
        if all(abs(a - b) <= 16 for a, b in zip(rgb, want)):
            return i
    raise CSpectError(f"border colour {rgb} is not a default ULA colour 0-7")


def _num(text: str, pattern: str, tool: str) -> re.Match:
    m = re.search(pattern, text)
    if not m:
        raise CSpectError(f"{tool} reply not understood: {text[:200]!r}")
    return m


class Session:
    """A context manager over one harness CSpect (or, for host checks, any Mcp)."""

    def __init__(self, mcp, symbols, inst=None, map_file=None):
        self.mcp, self.inst, self.map_file = mcp, inst, map_file
        self._syms = symbols

    @classmethod
    def boot(cls, card, nex, map_file, *, freerun=True, paused=False, brk=None, major=None,
             minor=None, extra=()) -> "Session":
        """Launch nex on card. paused: stopped at the NEX entry (-debug). brk (label or address):
        +brk=, and unless paused, returns stopped there. major/minor set NR $01/$0E, checked."""
        syms = read_map(map_file)
        brk_addr = None if brk is None else cls(None, syms, map_file=map_file)._addr(brk)
        args = boot_args(paused, brk_addr, major, minor)
        inst = launcher.launch(card, nex, map_file, freerun=freerun, extra=(*args, *extra))
        s = cls(inst.mcp, syms, inst, map_file)
        try:
            want = {n: v for n, v in ((0x01, major), (0x0E, minor)) if v is not None}
            if want:
                got = s.next_regs(list(want))
                if got != want:
                    raise CSpectError(f"-major/-minor not applied: NR {got}, wanted {want}")
            if brk_addr is not None and not paused:
                pc = s._wait_stop(STOP_S, f"the boot breakpoint {brk!r}")
                if pc != brk_addr:
                    raise CSpectError(f"boot stopped at ${pc:04X}, not at {brk!r} ${brk_addr:04X}")
        except BaseException:
            s.close()
            raise
        return s

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self) -> None:
        if self.inst is not None:
            self.inst.close()

    @property
    def pid(self) -> int:
        return self.inst.pid

    # -- symbols and memory -----------------------------------------------------------------------

    def sym(self, name: str) -> int:
        try:
            return self._syms[name.upper()][0]
        except KeyError:
            raise KeyError(f"symbol {name!r} not in {self.map_file}") from None

    def _addr(self, target) -> int:
        a = self.sym(target) if isinstance(target, str) else int(target)
        if not 0 <= a <= 0xFFFF:
            raise ValueError(f"{target!r} is not a 16-bit address")
        return a

    def read(self, addr: int, n: int) -> bytes:
        if not (0 <= addr and n >= 0 and addr + n <= 0x10000):
            raise ValueError(f"${addr:X}+{n} is outside the 64K view")
        return self.mcp.read(addr, n)

    def _write(self, addr: int, data: bytes, physical: bool) -> None:
        for i in range(0, len(data), 4096):
            chunk = bytes(data[i:i + 4096])
            t = self.mcp.text(self.mcp.call("write_memory", address=f"${addr + i:X}", data=chunk.hex(),
                                            physical=physical))
            if not t.startswith(f"Wrote {len(chunk)} bytes"):
                raise CSpectError(f"write_memory ${addr + i:X} {len(chunk)} bytes: {t[:200]!r}")

    def write(self, addr: int, data: bytes) -> None:
        if not (0 <= addr and addr + len(data) <= 0x10000):
            raise ValueError(f"${addr:X}+{len(data)} is outside the 64K view")
        self._write(addr, data, False)

    def _page(self, page: int, offset: int, n: int) -> tuple[int, bool]:
        """(address, physical) for n bytes at page:offset."""
        if not 0 <= page <= 0xFF or not (0 <= offset and n >= 0 and offset + n <= PAGE_SIZE):
            raise ValueError(f"page {page} offset ${offset:X} +{n} is outside one 8K page")
        if page not in BANK5_SLOT:
            return page * PAGE_SIZE + offset, True
        slot = BANK5_SLOT[page]
        nr = 0x50 + slot
        held = self.next_regs([nr])[nr]
        if held != page:
            raise CSpectError(f"page {page} is 16K bank 5, absent from CSpect's physical view; its "
                              f"64K route needs NR ${nr:02X} = {page}, which holds {held}")
        return slot * PAGE_SIZE + offset, False

    def read_page(self, page: int, offset: int, n: int) -> bytes:
        addr, physical = self._page(page, offset, n)
        return self.mcp.read(addr, n, physical=physical)

    def write_page(self, page: int, offset: int, data: bytes) -> None:
        addr, physical = self._page(page, offset, len(data))
        self._write(addr, data, physical)

    def grid(self) -> bytes:
        return self.read(TM_MAP, tilemap.GRID_BYTES)

    def rows(self) -> list[str]:
        return tilemap.decode(self.grid())[0]

    def flags(self) -> bytes:
        return self.read(self.sym("FLAGS"), 256)

    def frame(self) -> int:
        return int.from_bytes(self.read(self.sym("FRAMECOUNTER"), 2), "little")

    # -- waits ------------------------------------------------------------------------------------

    @staticmethod
    def wait_until(pred, timeout: float, poll: float = 0.05, what: str = ""):
        """pred()'s first truthy value; TimeoutError naming what after timeout seconds."""
        deadline = time.monotonic() + timeout
        while True:
            v = pred()
            if v:
                return v
            if time.monotonic() >= deadline:
                raise TimeoutError(f"timed out after {timeout:g} s waiting for "
                                   f"{what or getattr(pred, '__name__', 'the condition')}")
            time.sleep(poll)

    def wait_frames(self, n: int, timeout: float) -> int:
        """Return once FRAMECOUNTER has advanced at least n frames; the count seen."""
        last, seen = self.frame(), 0
        deadline = time.monotonic() + timeout
        while seen < n:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"FRAMECOUNTER advanced {seen} of {n} frames in {timeout:g} s")
            time.sleep(0.005)
            f = self.frame()
            seen += (f - last) & 0xFFFF
            last = f
        return seen

    # -- keys -------------------------------------------------------------------------------------

    def _need_running(self, what: str) -> None:
        if self._status()[0] != "running":
            raise CSpectError(f"{what} needs the CPU running: resume() first")

    def _keys(self, tool: str, **args) -> int:
        t = self.mcp.text(self.mcp.call(tool, **args))
        return int(_num(t, r"^(?:Keys|Text) done \((\d+) frames\)", tool).group(1))

    def type_text(self, text: str) -> int:
        """Types text (newline = ENTER); returns the frames it took."""
        self._need_running("type_text")
        return self._keys("type_text", text=text)

    def enter(self) -> int:
        return self.press("ENTER")

    def press(self, keys: str, frames: int | None = None) -> int:
        """press_keys items ('A+B' held together, spaced or comma separated), each held frames."""
        self._need_running("press")
        args = {"keys": keys}
        if frames is not None:
            args["hold_frames"] = int(frames)
        return self._keys("press_keys", **args)

    # -- debugger ---------------------------------------------------------------------------------

    def _status(self, text: str | None = None, tool: str = "get_status") -> tuple[str, dict[str, int]]:
        return parse_status(self.mcp.status() if text is None else text, tool)

    def _wait_stop(self, timeout: float, what: str) -> int:
        """PC once the CPU stops; TimeoutError naming what."""
        deadline = time.monotonic() + timeout
        while True:
            ms = max(1, min(RUN_TO_MAX_MS, int((deadline - time.monotonic()) * 1000)))
            t = self.mcp.text(self.mcp.call("wait_for_stop", timeout_ms=ms))
            if not t.startswith("Still running"):
                state, regs = self._status(t, "wait_for_stop")
                if state == "stopped":
                    return regs["PC"]
            if time.monotonic() >= deadline:
                raise TimeoutError(f"CPU did not stop within {timeout:g} s waiting for {what}")

    def pause(self) -> int:
        """Stops the CPU; returns PC."""
        return self._status(self.mcp.text(self.mcp.call("pause")), "pause")[1]["PC"]

    def resume(self) -> None:
        t = self.mcp.text(self.mcp.call("run"))
        if not t.startswith("Running"):
            raise CSpectError(f"run reply not understood: {t[:200]!r}")

    def step(self, n: int = 1) -> int:
        """Steps n instructions (CPU stopped); returns PC."""
        t = self.mcp.text(self.mcp.call("step", count=n))
        m = re.match(r"Stepped (\d+) instruction", t)          # absent when n is 1
        if (int(m.group(1)) if m else 1) != n:
            raise CSpectError(f"step {n}: {t[:200]!r}")
        state, regs = self._status(t, "step")
        if state != "stopped":
            raise CSpectError(f"step {n} left the CPU {state}")
        return regs["PC"]

    def run_to(self, target, timeout: float) -> int:
        """Runs until PC reaches target or another breakpoint stops it; returns the stop PC."""
        addr = self._addr(target)
        deadline = time.monotonic() + timeout
        ms = max(1, min(RUN_TO_MAX_MS, int(timeout * 1000)))
        t = self.mcp.text(self.mcp.call("run_to", address=f"${addr:04X}", timeout_ms=ms))
        if not t.startswith("Still running"):
            state, regs = self._status(t, "run_to")
            if state == "stopped":
                return regs["PC"]
        try:
            return self._wait_stop(max(0.0, deadline - time.monotonic()), f"{target!r} ${addr:04X}")
        except TimeoutError:
            # run_to's temporary breakpoint stays until the next stop
            if self.pause() == addr:
                return addr
            self.resume()
            raise

    def stopped_at(self) -> int | None:
        """PC while the CPU is stopped (breakpoint, run_to, pause, step), else None."""
        state, regs = self._status()
        return regs["PC"] if state == "stopped" else None

    def set_breakpoint(self, target) -> None:
        addr = self._addr(target)
        t = self.mcp.text(self.mcp.call("set_breakpoint", address=f"${addr:04X}"))
        _num(t, rf"^Set execute breakpoint at \${addr:04X}\b", "set_breakpoint")

    def clear_breakpoint(self, target) -> None:
        addr = self._addr(target)
        t = self.mcp.text(self.mcp.call("clear_breakpoint", address=f"${addr:04X}"))
        _num(t, rf"^Cleared execute breakpoint at \${addr:04X}\b", "clear_breakpoint")

    def regs(self) -> dict[str, int]:
        return self._status()[1]

    def set_regs(self, **values) -> None:
        """set_regs(HL=0x1234, PC=...) while stopped; names as CSpect's (AF' via **{"AF'": n})."""
        bad = sorted(set(values) - REG_NAMES)
        if bad:
            raise ValueError(f"unknown registers {bad}")
        if self._status()[0] != "stopped":
            raise CSpectError("set_regs needs the CPU stopped: pause() first")
        t = self.mcp.text(self.mcp.call("set_registers",
                                        registers={k: f"${int(v):X}" for k, v in values.items()}))
        got = self._status(t, "set_registers")[1]
        wrong = {k: f"${got[k]:X} not ${int(v):X}" for k, v in values.items() if got[k] != int(v)}
        if wrong:
            raise CSpectError(f"set_registers did not take: {wrong}")

    def next_regs(self, numbers) -> dict[int, int]:
        nums = [int(n) for n in numbers]
        if not nums or not all(0 <= n <= 0xFF for n in nums):
            raise ValueError(f"next register numbers {numbers!r}")
        t = self.mcp.text(self.mcp.call("read_next_registers",
                                        registers=",".join(f"${n:02X}" for n in nums)))
        found = {int(a, 16): int(b, 16) for a, b in
                 re.findall(r"NextReg \$([0-9A-Fa-f]{2}) = \$([0-9A-Fa-f]{2})\b", t)}
        missing = [f"${n:02X}" for n in nums if n not in found]
        if missing:
            raise CSpectError(f"read_next_registers reply lacks {missing}: {t[:200]!r}")
        return {n: found[n] for n in nums}

    def port_in(self, port: int) -> int:
        t = self.mcp.text(self.mcp.call("port_in", port=f"${port:04X}"))
        m = _num(t, r"^IN \$([0-9A-Fa-f]{4}) = \$([0-9A-Fa-f]{2})\b", "port_in")
        if int(m.group(1), 16) != port:
            raise CSpectError(f"port_in ${port:04X} answered for ${m.group(1)}")
        return int(m.group(2), 16)

    def port_out(self, port: int, value: int) -> None:
        # CSpect 4.5.9.0: MCP port_out has no effect on any port; the debugger's OUT does
        t = self.mcp.text(self.mcp.call("debug_command", command=f"OUT ${port:04X},${value:02X}"))
        if t.strip() != "OK":
            raise CSpectError(f"debug_command OUT ${port:04X},${value:02X}: {t[:200]!r}")

    def ay_regs(self, chip: int = 0, *, restore=AY_FRAME_END) -> bytes:
        """R0-R13 of Turbo Sound PSG chip (0-2), read paused; leaves PSG restore[0] register
        restore[1] selected and the CPU as it found it."""
        if chip not in (0, 1, 2):
            raise ValueError(f"chip {chip} is not 0-2")
        was_running = self._status()[0] == "running"
        if was_running:
            self.pause()
        try:
            self.port_out(0xFFFD, AY_SELECTS[chip])
            out = bytearray()
            for r in range(14):
                self.port_out(0xFFFD, r)
                out.append(self.port_in(0xFFFD))
        finally:
            self.port_out(0xFFFD, AY_SELECTS[restore[0]])
            self.port_out(0xFFFD, restore[1])
            if was_running:
                self.resume()
        return bytes(out)

    # -- screen and comparisons -------------------------------------------------------------------

    def screenshot(self):
        """The 320x256 display (border included) as an RGB PIL image."""
        from PIL import Image
        res = self.mcp.call("screenshot", scale=1)
        for c in res.get("content", []):
            if c.get("type") == "image":
                img = Image.open(io.BytesIO(base64.b64decode(c["data"]))).convert("RGB")
                if img.size != SCREEN:
                    raise CSpectError(f"screenshot scale 1 is {img.size}, not {SCREEN}")
                return img
        raise CSpectError(f"screenshot reply has no image: {self.mcp.text(res)[:200]!r}")

    def border_index(self) -> int:
        return ula_border_index(self.screenshot())

    def diff_bytes(self, expected: bytes, *, addr=None, page=None, offset=0) -> list[tuple[int, int, int]]:
        """(index into expected, got, want) for each differing byte at addr (64K) or page:offset."""
        if (addr is None) == (page is None):
            raise ValueError("diff_bytes needs addr or page, not both")
        if addr is not None and offset:
            raise ValueError("offset belongs to page")
        got = self.read(addr, len(expected)) if addr is not None else self.read_page(page, offset, len(expected))
        return [(i, g, w) for i, (g, w) in enumerate(zip(got, expected)) if g != w]

    def diff_image(self, expected, box) -> int:
        """Differing pixels between a screenshot's box and expected (box-sized or full-screen)."""
        from PIL import ImageChops
        shot = self.screenshot().crop(box)
        want = expected.convert("RGB")
        if want.size == SCREEN and shot.size != SCREEN:
            want = want.crop(box)
        if want.size != shot.size:
            raise ValueError(f"expected is {want.size}, box {box} is {shot.size}")
        return sum(1 for p in ImageChops.difference(shot, want).getdata() if p != (0, 0, 0))

    # -- timing -----------------------------------------------------------------------------------

    def _clock_at(self, target) -> tuple[int, int]:
        """(FRAMECOUNTER, raster line) at the next execution of target."""
        addr = self._addr(target)
        self.set_breakpoint(addr)
        try:
            if self._status()[0] == "stopped":
                self.resume()
            pc = self._wait_stop(STOP_S, f"{target!r} ${addr:04X}")
        finally:
            self.clear_breakpoint(addr)
        if pc != addr:
            raise CSpectError(f"stopped at ${pc:04X} waiting for {target!r} ${addr:04X}")
        nr = self.next_regs([0x1E, 0x1F])
        return self.frame(), (nr[0x1E] & 1) << 8 | nr[0x1F]

    def time_between(self, start, end, runs: int = 1) -> list[tuple[int, int]]:
        """Per run (frames, lines) from start's next execution to end's, lines in 0..310; clears
        breakpoints at both and leaves the CPU running."""
        out = []
        for _ in range(runs):
            f0, l0 = self._clock_at(start)
            f1, l1 = self._clock_at(end)
            out.append(raster_elapsed(f0, l0, f1, l1))
        self.resume()
        return out
