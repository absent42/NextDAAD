#!/usr/bin/env python3
"""PC leg for OBJVERIF: play walk.txt on the DAAD-READY PCDAAD.EXE (VGA256)
tree under DOSBox 0.74-3 (debug build, headless: SDL dummy video and audio,
no console window); screen text per step decoded from mode 13h against
DAAD.FNT (proportional); compare diffs a test run against a control.

    python -I drive_pc.py run <tree> <walk.txt> <out_dir> --work <scratch>
    python -I drive_pc.py compare <test_dir> <ctl_dir> <results.md>

<tree> is a DAAD-READY PC tree (dosbox.conf, GAME\\PCDAAD.EXE, DAAD.DDB,
DAAD.FNT). Its GAME folder is copied to <scratch>; KBTSR.COM (pc_kbtsr.s,
assembled with mingw-w64 as) is loaded before PCDAAD and serves keys and
screen dumps from the game's own INT 16h polls through CMD.TXT, ACK.TXT
and SCR.BIN in the mounted folder.
"""
import argparse
import ctypes
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import classic_leg   # noqa: E402
import cscreen       # noqa: E402
import drive_zx48    # noqa: E402
import zleg          # noqa: E402

DOSBOX = Path(r"C:\Program Files (x86)\DOSBox-0.74-3\dosbox-74-3-debug.exe")
BINUTILS = Path(r"C:\ProgramData\mingw64\mingw64\bin")
TSR_SRC = HERE / "pc_kbtsr.s"
W, H = 320, 200
ACK_TIMEOUT_S = 30.0
# set 1 make codes for AH; AL carries the character
SCAN = dict(zip("1234567890", range(0x02, 0x0C)))
SCAN.update(zip("qwertyuiop", range(0x10, 0x1A)))
SCAN.update(zip("asdfghjkl", range(0x1E, 0x27)))
SCAN.update(zip("zxcvbnm", range(0x2C, 0x33)))
SCAN.update({" ": 0x39, "\r": 0x1C, "\b": 0x0E})


def build_tsr(dst):
    """pc_kbtsr.s -> KBTSR.COM; 'x+O' is written out as 'x-base+0x100'."""
    src = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\+O\b", r"(\1-base+0x100)",
                 TSR_SRC.read_text())
    pp, obj = dst.with_suffix(".s"), dst.with_suffix(".o")
    pp.write_text(src)
    subprocess.run([str(BINUTILS / "as.exe"), "--32", str(pp), "-o",
                    str(obj)], check=True)
    subprocess.run([str(BINUTILS / "objcopy.exe"), "-O", "binary", "-j",
                    ".text", str(obj), str(dst)], check=True)
    pp.unlink()
    obj.unlink()


def write_conf(staged, path, game):
    """The staged dosbox.conf with output, sound and autoexec replaced."""
    out, sect = [], None
    for line in Path(staged).read_text(encoding="latin-1").splitlines():
        s = line.strip()
        if s.startswith("["):
            sect = s.lower()
            out.append(line)
            if sect == "[autoexec]":
                out += ["@echo off", 'mount c "%s"' % game, "c:",
                        "KBTSR", "PCDAAD"]
            continue
        if sect == "[autoexec]":
            continue
        key = s.split("=", 1)[0].strip().lower() if "=" in s else ""
        if sect == "[sdl]" and key == "output":
            line = "output=surface"
        elif sect == "[mixer]" and key == "nosound":
            line = "nosound=true"
        elif sect == "[speaker]" and key == "pcspeaker":
            line = "pcspeaker=false"
        out.append(line)
    Path(path).write_text("\r\n".join(out) + "\r\n", encoding="latin-1")


# ---- no visible window ----------------------------------------------------

user32 = ctypes.WinDLL("user32", use_last_error=True)
ENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def visible_windows(pid):
    found = []

    def cb(hwnd, _):
        p = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True
    user32.EnumWindows(ENUMPROC(cb), 0)
    return found


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
CREATE_UNICODE_ENVIRONMENT = 0x00000400
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR),
                ("lpDesktop", wintypes.LPWSTR), ("lpTitle", wintypes.LPWSTR),
                ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD),
                ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD),
                ("dwFillAttribute", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD),
                ("cbReserved2", wintypes.WORD),
                ("lpReserved2", ctypes.c_void_p),
                ("hStdInput", wintypes.HANDLE),
                ("hStdOutput", wintypes.HANDLE),
                ("hStdError", wintypes.HANDLE),
                ("lpAttributeList", ctypes.c_void_p)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                ("dwProcessId", wintypes.DWORD),
                ("dwThreadId", wintypes.DWORD)]


class Headless:
    """DOSBox inside a pseudo console (no console window).

    The debug build's PDCurses debugger UI needs a real console buffer:
    under CREATE_NO_WINDOW initscr() fails and the process exits 8.
    SDL video and audio are the dummy drivers.
    """

    def __init__(self, args, cwd, env):
        k = kernel32
        k.CreatePseudoConsole.argtypes = [wintypes.DWORD, wintypes.HANDLE,
                                          wintypes.HANDLE, wintypes.DWORD,
                                          ctypes.POINTER(wintypes.HANDLE)]
        k.ClosePseudoConsole.argtypes = [wintypes.HANDLE]
        k.UpdateProcThreadAttribute.argtypes = [
            ctypes.c_void_p, wintypes.DWORD, ctypes.c_size_t,
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
            ctypes.c_void_p]
        k.InitializeProcThreadAttributeList.argtypes = [
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
            ctypes.POINTER(ctypes.c_size_t)]
        in_r, in_w = wintypes.HANDLE(), wintypes.HANDLE()
        out_r, out_w = wintypes.HANDLE(), wintypes.HANDLE()
        k.CreatePipe(ctypes.byref(in_r), ctypes.byref(in_w), None, 0)
        k.CreatePipe(ctypes.byref(out_r), ctypes.byref(out_w), None, 0)
        self.hpc = wintypes.HANDLE()
        hr = k.CreatePseudoConsole(80 | (50 << 16), in_r, out_w, 0,
                                   ctypes.byref(self.hpc))
        if hr:
            raise OSError("CreatePseudoConsole hr=0x%08X" % (hr & 0xFFFFFFFF))
        k.CloseHandle(in_r)
        k.CloseHandle(out_w)
        self.in_w, self.out_r = in_w, out_r
        threading.Thread(target=self._drain, daemon=True).start()
        size = ctypes.c_size_t()
        k.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        self.attrs = ctypes.create_string_buffer(size.value)
        if not k.InitializeProcThreadAttributeList(self.attrs, 1, 0,
                                                   ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        if not k.UpdateProcThreadAttribute(
                self.attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                self.hpc, ctypes.sizeof(wintypes.HANDLE), None, None):
            raise ctypes.WinError(ctypes.get_last_error())
        si = STARTUPINFOEXW()
        si.cb = ctypes.sizeof(STARTUPINFOEXW)
        si.dwFlags = 0x1                        # STARTF_USESHOWWINDOW
        si.wShowWindow = 0                      # SW_HIDE
        si.lpAttributeList = ctypes.cast(self.attrs, ctypes.c_void_p)
        block = "".join("%s=%s\0" % kv for kv in env.items()) + "\0"
        envbuf = ctypes.create_unicode_buffer(block, len(block))
        pi = PROCESS_INFORMATION()
        cmdline = ctypes.create_unicode_buffer(subprocess.list2cmdline(args))
        if not k.CreateProcessW(None, cmdline, None, None, False,
                                EXTENDED_STARTUPINFO_PRESENT
                                | CREATE_UNICODE_ENVIRONMENT, envbuf,
                                str(cwd), ctypes.byref(si),
                                ctypes.byref(pi)):
            raise ctypes.WinError(ctypes.get_last_error())
        k.CloseHandle(pi.hThread)
        self.hproc, self.pid = pi.hProcess, pi.dwProcessId
        self.returncode = None

    def _drain(self):
        buf = ctypes.create_string_buffer(4096)
        n = wintypes.DWORD()
        while kernel32.ReadFile(self.out_r, buf, 4096, ctypes.byref(n),
                                None) and n.value:
            pass

    def poll(self):
        if self.returncode is None and (
                kernel32.WaitForSingleObject(self.hproc, 0) == 0):
            code = wintypes.DWORD()
            kernel32.GetExitCodeProcess(self.hproc, ctypes.byref(code))
            self.returncode = code.value
        return self.returncode

    def kill(self):
        if self.poll() is None:
            kernel32.TerminateProcess(self.hproc, 1)

    def wait(self, timeout=None):
        kernel32.WaitForSingleObject(
            self.hproc, 0xFFFFFFFF if timeout is None else int(timeout * 1000))
        if self.poll() is None:
            raise subprocess.TimeoutExpired("dosbox", timeout)
        kernel32.ClosePseudoConsole(self.hpc)
        return self.returncode


def launch(conf, cwd):
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    return Headless([str(DOSBOX), "-conf", str(conf)], cwd, env)


# ---- DAAD.FNT, proportional ---------------------------------------------

def load_fnt(path):
    """DAAD.FNT tail: 256 widths, 256 x 8 scanlines (charset.pas:30-31).

    WriteChar (ibmpc.pas:575-592) plots column j of a width-w glyph from
    bit 8-j of the scanline, so column 0 is always paper. Returns
    [(char, columns)], columns = row bitmasks, bit i = scanline i.
    """
    d = Path(path).read_bytes()[-256 * 9:]
    widths, data = d[:256], d[256:]
    glyphs, seen = [], {}
    for code in range(32, 127):
        w = widths[code]
        if not w:
            continue
        cols = tuple(sum(((data[code * 8 + i] >> (8 - j)) & 1) << i
                         for i in range(8)) for j in range(w))
        if cols in seen:
            continue
        seen[cols] = chr(code)
        glyphs.append((chr(code), cols))
    return glyphs


class Fnt:
    def __init__(self, path):
        self.glyphs = load_fnt(path)
        self.by = {}
        for ch, cols in self.glyphs:
            k = cols[1] if len(cols) > 1 else None
            self.by.setdefault(k, []).append((ch, cols))

    def row(self, cols):
        """Cheapest exact cover of one 8-pixel band by glyphs.

        Cost 1 per glyph, 50 per unexplained paper column (margins), 1000
        per unexplained ink column (decoded '?').
        """
        n = len(cols)
        last = max((x for x in range(n) if cols[x]), default=-1)
        if last < 0:
            return ""
        inf = float("inf")
        best = [inf] * (n + 1)
        back = [None] * (n + 1)
        best[0] = 0
        for x in range(n):
            c0 = best[x]
            if c0 == inf:
                continue
            cands = self.by.get(None, [])
            if x + 1 < n:
                cands = cands + self.by.get(cols[x + 1], [])
            for ch, g in cands:
                w = len(g)
                if x + w <= n and cols[x] == g[0] and \
                        tuple(cols[x:x + w]) == g:
                    if c0 + 1 < best[x + w]:
                        best[x + w], back[x + w] = c0 + 1, (x, ch)
            pen, ch = (50, "") if cols[x] == 0 else (1000, "?")
            if c0 + pen < best[x + 1]:
                best[x + 1], back[x + 1] = c0 + pen, (x, ch)
        end = min(range(last + 1, n + 1), key=lambda e: best[e])
        out, x = [], end
        while x:
            px, ch = back[x]
            out.append(ch)
            x = px
        return "".join(reversed(out)).rstrip()

    def decode(self, ink):
        """ink: 200 rows of 320 booleans -> lines, blank lines dropped."""
        best = best_s = None
        for dy in range(8):
            lines = []
            for r in range((H - dy) // 8):
                band = ink[dy + r * 8:dy + r * 8 + 8]
                cols = [sum(band[i][x] << i for i in range(8))
                        for x in range(W)]
                lines.append(self.row(cols))
            s = cscreen.score(lines)
            if best_s is None or s < best_s:
                best, best_s = lines, s
        return [l for l in best if l.strip()]


# ---- the machine ---------------------------------------------------------

class Pc:
    def __init__(self, proc, game, fnt, say):
        self.proc, self.game, self.fnt, self.say = proc, game, fnt, say
        self.seq = 0
        self.cache = {}

    def check(self):
        if self.proc.poll() is not None:
            raise SystemExit("dosbox exited rc=%s" % self.proc.returncode)
        if visible_windows(self.proc.pid):
            self.proc.kill()
            raise SystemExit("dosbox opened a visible window - killed")

    def _send(self, op, data=b""):
        self.seq += 1
        tag = b"%04d" % self.seq
        tmp = self.game / "CMD.NEW"
        tmp.write_bytes(tag + op + data)
        deadline = time.time() + ACK_TIMEOUT_S
        while True:
            try:
                os.replace(tmp, self.game / "CMD.TXT")
                break
            except PermissionError:
                if time.time() > deadline:
                    raise
                time.sleep(0.02)
        while time.time() < deadline:
            self.check()
            try:
                if (self.game / "ACK.TXT").read_bytes() == tag:
                    return
            except OSError:
                pass
            time.sleep(0.03)
        raise TimeoutError("no ACK for %s %r" % (tag, op))

    def keys(self, text):
        data = b"".join(bytes([ord(c), SCAN.get(c, 0)]) for c in text)
        self._send(b"K", data)

    def read(self):
        self._send(b"D")
        raw = (self.game / "SCR.BIN").read_bytes()
        if len(raw) != W * H + 768:
            raise SystemExit("SCR.BIN is %d bytes" % len(raw))
        return raw

    def decode(self, raw):
        if raw not in self.cache:
            scr = raw[:W * H]
            counts = [0] * 256
            for b in scr:
                counts[b] += 1
            paper = counts.index(max(counts))
            ink = [[scr[y * W + x] != paper for x in range(W)]
                   for y in range(H)]
            self.cache[raw] = self.fnt.decode(ink)
        return self.cache[raw]

    def png(self, raw, path):
        pal = raw[W * H:]
        rgb = [tuple(min(255, v * 4 + v // 16) for v in pal[i:i + 3])
               for i in range(0, 768, 3)]
        cscreen.write_png(path, [[rgb[raw[y * W + x]] for x in range(W)]
                                 for y in range(H)])

    def type(self, cmd):
        self.keys(cmd.lower())

    def enter(self):
        self.keys("\r")

    def space(self):
        self.keys(" ")


def run(args):
    tree = Path(args.tree).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = Path(args.work).resolve()
    if work.exists():
        shutil.rmtree(work)
    game = work / "GAME"
    shutil.copytree(tree / "GAME", game)
    build_tsr(game / "KBTSR.COM")
    (game / "CMD.TXT").write_bytes(b"0000N")
    conf = work / "run.conf"
    write_conf(tree / "dosbox.conf", conf, game)
    fnt = Fnt(game / "DAAD.FNT")
    prompts = zleg.prompt_set(drive_zx48.load_stx(args.dsf))
    log = open(out / "run.log", "w", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log.write(msg + "\n")
        log.flush()

    say("font: %d glyphs; launch: %s -conf %s (SDL dummy video/audio, "
        "no window)" % (len(fnt.glyphs), DOSBOX, conf))
    proc = launch(conf, work)
    try:
        pc = Pc(proc, game, fnt, say)
        time.sleep(1.0)
        pc.check()
        classic_leg.walk(pc, args.walk, out, say, prompts)
    finally:
        proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        say("emulator killed, rc=%s" % proc.poll())
        log.close()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("run")
    r.add_argument("tree")
    r.add_argument("walk")
    r.add_argument("out")
    r.add_argument("--work", required=True,
                   help="scratch folder for the GAME copy, TSR and conf")
    r.add_argument("--dsf", default=str(HERE.parent / "OBJVERIF.DSF"))
    c = sub.add_parser("compare")
    c.add_argument("test")
    c.add_argument("ctl")
    c.add_argument("md")
    args = ap.parse_args()
    if args.mode == "run":
        run(args)
        return 0
    return classic_leg.compare(args.test, args.ctl, args.md)


if __name__ == "__main__":
    sys.exit(main())
