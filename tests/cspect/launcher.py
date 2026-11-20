"""Owns the harness CSpect process: private copy (source install fallback), port, mutex held
for the Instance's life, kill-on-close job, kill by PID on close(), MCP readiness confirmed
against the listener's owning PID. Never touches a CSpect it did not start."""
import ctypes
import os
import shutil
import socket
import struct
import subprocess
import time
from ctypes import wintypes
from pathlib import Path

from .client import CSpectError, Mcp

ROOT = Path(__file__).resolve().parents[2]
HARNESS_DIR = ROOT / "build" / "cspect-harness"
PRIVATE_DIR = HARNESS_DIR / "cspect"
DEFAULT_SOURCE = Path(r"D:\ZXNextDev\cspect")
MIN_VERSION = (4, 5, 9, 0)
PORT_RANGE = range(23460, 23500)
MUTEX_NAME = r"Local\NextDAADCSpectHarness"
REQUIRED_TOOLS = ("read_memory", "write_memory", "get_status", "set_registers", "pause", "run",
                  "step", "run_to", "wait_for_stop", "set_breakpoint", "clear_breakpoint",
                  "evaluate", "read_next_registers", "port_in", "debug_command", "screenshot",
                  "press_keys", "type_text")
# DeZogPlugin.dll opens port 11000; card images are GBs and a NEX run needs none
COPY_EXCLUDE = frozenset({"zxnext.mmc", "dezogplugin.dll"})
IMAGE_SUFFIXES = frozenset({".mmc", ".img", ".hdf"})
NO_ANSWER_CAUSES = ("Causes: CSpect older than 4.3 (no MCP server), MCP.dll missing from the CSpect "
                    "folder, or the MCP tier (Builder-level Patreon since 4.5.0) not enabled.")
SW_SHOWMINNOACTIVE = 7
_TEST_COMMANDS = None        # test-only: one command per attempt replaces CSpect; "{port}" filled in


class LaunchError(Exception):
    pass


# -- Win32 ----------------------------------------------------------------------------------------

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_ver = ctypes.WinDLL("version", use_last_error=True)
_ip = ctypes.WinDLL("iphlpapi", use_last_error=True)


def _proto(fn, restype, *argtypes):
    fn.restype, fn.argtypes = restype, argtypes


_proto(_k32.CreateMutexW, wintypes.HANDLE, wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
_proto(_k32.WaitForSingleObject, wintypes.DWORD, wintypes.HANDLE, wintypes.DWORD)
_proto(_k32.ReleaseMutex, wintypes.BOOL, wintypes.HANDLE)
_proto(_k32.CloseHandle, wintypes.BOOL, wintypes.HANDLE)
_proto(_k32.CreateJobObjectW, wintypes.HANDLE, wintypes.LPVOID, wintypes.LPCWSTR)
_proto(_k32.SetInformationJobObject, wintypes.BOOL, wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
       wintypes.DWORD)
_proto(_k32.AssignProcessToJobObject, wintypes.BOOL, wintypes.HANDLE, wintypes.HANDLE)
_proto(_k32.OpenProcess, wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
_proto(_k32.GetExitCodeProcess, wintypes.BOOL, wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
_proto(_ver.GetFileVersionInfoSizeW, wintypes.DWORD, wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD))
_proto(_ver.GetFileVersionInfoW, wintypes.BOOL, wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
       wintypes.LPVOID)
_proto(_ver.VerQueryValueW, wintypes.BOOL, wintypes.LPCVOID, wintypes.LPCWSTR,
       ctypes.POINTER(wintypes.LPVOID), ctypes.POINTER(wintypes.UINT))
_proto(_ip.GetExtendedTcpTable, wintypes.DWORD, wintypes.LPVOID, ctypes.POINTER(wintypes.DWORD),
       wintypes.BOOL, wintypes.ULONG, ctypes.c_int, wintypes.ULONG)


class _BasicLimits(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD)]


class _ExtendedLimits(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", _BasicLimits), ("IoInfo", ctypes.c_uint64 * 6),
                ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


class _FixedFileInfo(ctypes.Structure):
    _fields_ = [(n, wintypes.DWORD) for n in (
        "dwSignature", "dwStrucVersion", "dwFileVersionMS", "dwFileVersionLS", "dwProductVersionMS",
        "dwProductVersionLS", "dwFileFlagsMask", "dwFileFlags", "dwFileOS", "dwFileType",
        "dwFileSubtype", "dwFileDateMS", "dwFileDateLS")]


def _win_error(what):
    return LaunchError(f"{what}: {ctypes.FormatError(ctypes.get_last_error())}")


def kill_on_close_job(pid: int) -> int:
    """A job handle holding pid with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; closing it (or this
    process dying) kills the process."""
    job = _k32.CreateJobObjectW(None, None)
    if not job:
        raise _win_error("CreateJobObjectW")
    info = _ExtendedLimits()
    info.BasicLimitInformation.LimitFlags = 0x2000          # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    proc = None
    try:
        if not _k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            raise _win_error("SetInformationJobObject")
        proc = _k32.OpenProcess(0x0101, False, pid)          # PROCESS_SET_QUOTA | PROCESS_TERMINATE
        if not proc:
            raise _win_error(f"OpenProcess {pid}")
        if not _k32.AssignProcessToJobObject(job, proc):
            raise _win_error(f"AssignProcessToJobObject {pid}")
    except BaseException:
        _k32.CloseHandle(job)
        raise
    finally:
        if proc:
            _k32.CloseHandle(proc)
    return job


def pid_alive(pid: int) -> bool:
    h = _k32.OpenProcess(0x1000, False, pid)                 # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ctypes.get_last_error() == 5                  # access denied: it exists
    try:
        code = wintypes.DWORD()
        return bool(_k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259
    finally:
        _k32.CloseHandle(h)


def _tcp_listeners(family: int) -> list[tuple[bytes, int, int]]:
    """[(local address, port, owning PID)] from GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)."""
    size = wintypes.DWORD(0)
    while True:
        buf = ctypes.create_string_buffer(max(size.value, 4))
        r = _ip.GetExtendedTcpTable(buf, ctypes.byref(size), False, family, 3, 0)
        if r == 0:
            break
        if r != 122:                                         # ERROR_INSUFFICIENT_BUFFER: retry
            raise LaunchError(f"GetExtendedTcpTable: {ctypes.FormatError(r)}")
    raw, out = buf.raw, []
    n = struct.unpack_from("<I", raw)[0]
    for i in range(n):
        if family == socket.AF_INET:                         # MIB_TCPROW_OWNER_PID, 24 bytes
            _, addr, port, _, _, pid = struct.unpack_from("<6I", raw, 4 + 24 * i)
            out.append((struct.pack("<I", addr), socket.ntohs(port & 0xFFFF), pid))
        else:                                                # MIB_TCP6ROW_OWNER_PID, 56 bytes
            off = 4 + 56 * i
            (port,), (pid,) = struct.unpack_from("<I", raw, off + 20), struct.unpack_from("<I", raw, off + 52)
            out.append((raw[off:off + 16], socket.ntohs(port & 0xFFFF), pid))
    return out


def listener_pids(port: int) -> set[int]:
    """PIDs listening on port where a 127.0.0.1 client could reach them."""
    v4 = {pid for a, p, pid in _tcp_listeners(socket.AF_INET)
          if p == port and a in (b"\x7f\0\0\1", bytes(4))}
    v6 = {pid for a, p, pid in _tcp_listeners(socket.AF_INET6) if p == port and a == bytes(16)}
    return v4 | v6


def _check_owner(port: int, pid: int) -> None:
    pids = listener_pids(port)
    if pids != {pid}:
        raise LaunchError(f"port {port} answered MCP but its listener is PID {sorted(pids) or 'none'}, "
                          f"not the launched PID {pid}")


class Mutex:
    """MUTEX_NAME, owned by the thread that acquired it; one harness CSpect per machine."""
    _held = False            # this process's own hold (a Win32 mutex is recursive per thread)

    def __init__(self, handle, name):
        self._handle, self.name = handle, name

    @classmethod
    def acquire(cls, wait: float | None = None) -> "Mutex":
        name = MUTEX_NAME
        if wait is None:
            wait = float(os.environ.get("NEXTDAAD_CSPECT_WAIT") or 120)
        if cls._held:
            raise LaunchError(f"this process already holds {name}: one harness CSpect at a time")
        h = _k32.CreateMutexW(None, False, name)
        if not h:
            raise _win_error(f"CreateMutexW {name}")
        deadline = time.monotonic() + wait
        while True:
            r = _k32.WaitForSingleObject(h, 200)             # short slices keep Ctrl+C live
            if r in (0, 0x80):                               # WAIT_OBJECT_0, WAIT_ABANDONED
                Mutex._held = True
                return cls(h, name)
            if r != 0x102:                                   # WAIT_TIMEOUT
                err = _win_error(f"WaitForSingleObject {name}")
                _k32.CloseHandle(h)
                raise err
            if time.monotonic() >= deadline:
                _k32.CloseHandle(h)
                raise LaunchError(f"another harness CSpect holds {name}; waited {wait:g} s "
                                  f"(NEXTDAAD_CSPECT_WAIT)")

    def release(self) -> None:
        """Must run on the acquiring thread; otherwise raises and the hold stays as it was."""
        if self._handle:
            if not _k32.ReleaseMutex(self._handle):
                raise _win_error(f"ReleaseMutex {self.name} (not the acquiring thread?)")
            _k32.CloseHandle(self._handle)
            self._handle = None
            Mutex._held = False


# -- source, version, copy ------------------------------------------------------------------------

def exe_version(path) -> tuple[int, int, int, int]:
    """File version from the exe's VS_FIXEDFILEINFO."""
    path = str(path)
    size = _ver.GetFileVersionInfoSizeW(path, None)
    if not size:
        raise _win_error(f"no version info in {path}")
    buf = ctypes.create_string_buffer(size)
    if not _ver.GetFileVersionInfoW(path, 0, size, buf):
        raise _win_error(f"GetFileVersionInfoW {path}")
    ptr, n = wintypes.LPVOID(), wintypes.UINT()
    if not _ver.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(n)) or not n.value:
        raise _win_error(f"VerQueryValueW {path}")
    ffi = ctypes.cast(ptr, ctypes.POINTER(_FixedFileInfo)).contents
    return (ffi.dwFileVersionMS >> 16, ffi.dwFileVersionMS & 0xFFFF,
            ffi.dwFileVersionLS >> 16, ffi.dwFileVersionLS & 0xFFFF)


def check_version(version, exe="CSpect") -> None:
    if tuple(version) < MIN_VERSION:
        raise LaunchError(f"{exe} is version {'.'.join(map(str, version))}; the harness needs "
                          f"{'.'.join(map(str, MIN_VERSION))} or later (set CSPECT_DIR)")


def check_tools(tools: list[dict]) -> None:
    names = {t["name"] for t in tools}
    missing = [t for t in REQUIRED_TOOLS if t not in names]
    if missing:
        raise LaunchError(f"CSpect MCP lacks required tools: {', '.join(missing)}")


def source_dir() -> Path:
    """$CSPECT_DIR (default D:\\ZXNextDev\\cspect), version-checked; never tools\\."""
    d = Path(os.environ.get("CSPECT_DIR") or DEFAULT_SOURCE).resolve()
    tools = (ROOT / "tools").resolve()
    if d == tools or tools in d.parents:
        raise LaunchError(f"{d} is under tools\\ (read-only toolchain copy); set CSPECT_DIR")
    exe = d / "CSpect.exe"
    if not exe.is_file():
        raise LaunchError(f"{exe} not found (set CSPECT_DIR)")
    check_version(exe_version(exe), exe)
    if not (d / "MCP.dll").is_file():
        raise LaunchError(f"MCP.dll missing from {d}")
    return d


def _copied(name: str) -> bool:
    return name.lower() not in COPY_EXCLUDE and Path(name).suffix.lower() not in IMAGE_SUFFIXES


def private_copy(src=None) -> Path:
    """Mirror the source's top-level files into PRIVATE_DIR: a file is re-copied only when its
    size or timestamp differs; files gone from the source, and excluded files, are deleted."""
    src = Path(src) if src is not None else source_dir()
    dest = PRIVATE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    wanted = {f.name.lower(): f for f in src.iterdir() if f.is_file() and _copied(f.name)}
    for f in dest.iterdir():
        if f.is_file() and f.name.lower() not in wanted:
            f.unlink()
    for f in wanted.values():
        d, s = dest / f.name, f.stat()
        if d.is_file():
            t = d.stat()
            if t.st_size == s.st_size and t.st_mtime_ns == s.st_mtime_ns:
                continue
        shutil.copy2(f, d)
    return dest


# -- ports ----------------------------------------------------------------------------------------

def _port_busy(port: int) -> str | None:
    """Why the port cannot be used, or None when nothing listens on it."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            pass
    except OSError:
        return None
    try:
        Mcp(port).initialize(timeout=2)
        return "already answers MCP initialize (a CSpect the harness did not start?)"
    except CSpectError:
        return "has a listener that is not an MCP server"


def choose_port(port: int | None = None) -> int:
    """port if free (else LaunchError), or the first free port in PORT_RANGE."""
    span = f"{PORT_RANGE.start}-{PORT_RANGE.stop - 1}"
    if port is not None:
        if port not in PORT_RANGE:
            raise LaunchError(f"port {port} is outside the harness range {span}")
        busy = _port_busy(port)
        if busy:
            raise LaunchError(f"port {port} {busy}")
        return port
    for p in PORT_RANGE:
        if not _port_busy(p):
            return p
    raise LaunchError(f"no free port in {span}")


# -- launch ---------------------------------------------------------------------------------------

class Instance:
    """One running harness CSpect. close() kills it by PID and releases the mutex."""

    def __init__(self, proc, job, mcp, port, exe_dir, mutex, log_path):
        self.proc, self.pid, self.mcp, self.port = proc, proc.pid, mcp, port
        self.exe_dir, self.log_path = exe_dir, log_path
        self._job, self._mutex = job, mutex

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self) -> None:
        """Safe to call again; the mutex is released only once the process is gone."""
        if self.proc is not None:
            job, self._job = self._job, None
            _stop(self.proc, job)
            self.proc = None
        self._mutex.release()


class _NoAnswer(Exception):
    pass


class _Stuck(LaunchError):
    """The process outlived TerminateProcess: the mutex stays held."""


def _stop(proc, job) -> None:
    """Kill proc and close its job; raise _Stuck if it has not exited 10 s later."""
    try:
        if proc.poll() is None:
            proc.kill()
    finally:
        if job:
            _k32.CloseHandle(job)
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        raise _Stuck(f"CSpect PID {proc.pid} still running 10 s after TerminateProcess; "
                     f"{MUTEX_NAME} kept until this process exits") from None


def _args(card, nex, map_file, freerun, extra, port):
    args = ["-zxnext", "-w1", "-esc", "-sound", "-mouse", "-nodelay"]
    if freerun:
        args.append("-freerun")
    args.append("-mmc=" + str(card).rstrip("\\") + "\\")    # CSpect needs the trailing backslash
    if map_file is not None:
        args.append(f"-map={map_file}")
    return args + [f"-mcp={port}", *extra, str(nex)]


def _start(cmd, cwd, port, start_timeout, log_path, append):
    """Start cmd in a kill-on-close job; return (proc, job, mcp) once MCP answers from proc."""
    with open(log_path, "a" if append else "w", encoding="utf-8") as log:
        log.write(f"launch: {subprocess.list2cmdline(cmd)}\n")
        log.flush()
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = SW_SHOWMINNOACTIVE
        env = dict(os.environ)
        env.pop("NEXTDAAD_DEBUG", None)
        proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, env=env, startupinfo=si,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        log.write(f"pid: {proc.pid}\n")
        log.flush()
    job = None
    try:
        job = kill_on_close_job(proc.pid)
        mcp = Mcp(port)
        deadline = time.monotonic() + start_timeout
        while True:
            if proc.poll() is not None:
                raise _NoAnswer(f"PID {proc.pid} exited with {proc.returncode} before MCP answered "
                                f"on port {port}")
            try:
                mcp.initialize(timeout=2)
                break
            except CSpectError:
                pass
            if time.monotonic() >= deadline:
                raise _NoAnswer(f"PID {proc.pid} did not answer MCP on port {port} in "
                                f"{start_timeout:g} s")
            time.sleep(0.2)                                  # poll interval against the deadline
        _check_owner(port, proc.pid)
        return proc, job, mcp
    except BaseException:
        _stop(proc, job)
        raise


def launch(card, nex, map_file=None, *, freerun=True, extra=(), port=None,
           start_timeout=30.0) -> Instance:
    """Start a harness CSpect on nex with card as the esxDOS root; wait for MCP and the tools."""
    card, nex = Path(card).resolve(), Path(nex).resolve()
    map_file = Path(map_file).resolve() if map_file is not None else None
    if not card.is_dir():
        raise LaunchError(f"card folder {card} not found")
    if not nex.is_file():
        raise LaunchError(f"{nex} not found")
    if map_file is not None and not map_file.is_file():
        raise LaunchError(f"{map_file} not found")
    mutex = Mutex.acquire()
    try:
        port = choose_port(port)
        HARNESS_DIR.mkdir(parents=True, exist_ok=True)
        log_path = HARNESS_DIR / f"console-{port}.log"
        if _TEST_COMMANDS is not None:
            attempts = [(HARNESS_DIR, [a.replace("{port}", str(port)) for a in cmd])
                        for cmd in _TEST_COMMANDS]
        else:
            src = source_dir()
            copy = private_copy(src)
            args = _args(card, nex, map_file, freerun, extra, port)
            attempts = [(d, [str(d / "CSpect.exe"), *args]) for d in (copy, src)]
        failures = []
        for i, (exe_dir, cmd) in enumerate(attempts):
            try:
                proc, job, mcp = _start(cmd, exe_dir, port, start_timeout, log_path, append=i > 0)
            except _NoAnswer as e:
                failures.append(f"{exe_dir}: {e}")
                continue
            inst = Instance(proc, job, mcp, port, exe_dir, mutex, log_path)
            try:
                check_tools(mcp.tools())
            except BaseException:
                inst.close()
                raise
            return inst
        raise LaunchError(f"CSpect MCP never answered. {'; '.join(failures)}. {NO_ANSWER_CAUSES} "
                          f"Console: {log_path}")
    except BaseException as e:
        if not isinstance(e, _Stuck):
            mutex.release()
        raise
