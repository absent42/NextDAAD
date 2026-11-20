"""Owns the harness CSpect process: private copy (source install fallback), port, mutex held
for the Instance's life, kill-on-close job, kill by PID on close(), MCP readiness.
Never touches a CSpect it did not start."""
import ctypes
import os
import shutil
import socket
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
                  "evaluate", "read_next_registers", "port_in", "port_out", "screenshot",
                  "press_keys", "type_text")
# DeZogPlugin.dll opens port 11000; card images are GBs and a NEX run needs none
COPY_EXCLUDE = frozenset({"zxnext.mmc", "dezogplugin.dll"})
IMAGE_SUFFIXES = frozenset({".mmc", ".img", ".hdf"})
NO_ANSWER_CAUSES = ("Causes: CSpect older than 4.3 (no MCP server), MCP.dll missing from the CSpect "
                    "folder, or the MCP tier (Builder-level Patreon since 4.5.0) not enabled.")
SW_SHOWMINNOACTIVE = 7
_TEST_COMMAND = None         # test-only: replaces the CSpect command line


class LaunchError(Exception):
    pass


# -- Win32 ----------------------------------------------------------------------------------------

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_ver = ctypes.WinDLL("version", use_last_error=True)


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


class Mutex:
    """MUTEX_NAME, owned by the thread that acquired it; one harness CSpect per machine."""
    _held = False            # this process's own hold (a Win32 mutex is recursive per thread)

    def __init__(self, handle):
        self._handle = handle

    @classmethod
    def acquire(cls, wait: float | None = None) -> "Mutex":
        if wait is None:
            wait = float(os.environ.get("NEXTDAAD_CSPECT_WAIT") or 120)
        if cls._held:
            raise LaunchError(f"this process already holds {MUTEX_NAME}: one harness CSpect at a time")
        h = _k32.CreateMutexW(None, False, MUTEX_NAME)
        if not h:
            raise _win_error(f"CreateMutexW {MUTEX_NAME}")
        deadline = time.monotonic() + wait
        while True:
            r = _k32.WaitForSingleObject(h, 200)             # short slices keep Ctrl+C live
            if r in (0, 0x80):                               # WAIT_OBJECT_0, WAIT_ABANDONED
                cls._held = True
                return cls(h)
            if r != 0x102:                                   # WAIT_TIMEOUT
                err = _win_error(f"WaitForSingleObject {MUTEX_NAME}")
                _k32.CloseHandle(h)
                raise err
            if time.monotonic() >= deadline:
                _k32.CloseHandle(h)
                raise LaunchError(f"another harness CSpect holds {MUTEX_NAME}; waited {wait:g} s "
                                  f"(NEXTDAAD_CSPECT_WAIT)")

    def release(self) -> None:
        if self._handle:
            _k32.ReleaseMutex(self._handle)
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
    """Refresh PRIVATE_DIR from the source's top-level files; a file is re-copied only when its
    size or timestamp differs. Excluded files never appear in the copy."""
    src = Path(src) if src is not None else source_dir()
    dest = PRIVATE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if not f.is_file() or not _copied(f.name):
            continue
        d, s = dest / f.name, f.stat()
        if d.is_file():
            t = d.stat()
            if t.st_size == s.st_size and t.st_mtime_ns == s.st_mtime_ns:
                continue
        shutil.copy2(f, d)
    for f in dest.iterdir():
        if f.is_file() and not _copied(f.name):
            f.unlink()
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
        try:
            if self.proc is not None:
                if self.proc.poll() is None:
                    self.proc.kill()
                self.proc.wait(10)
                self.proc = None
        finally:
            if self._job:
                _k32.CloseHandle(self._job)
                self._job = None
            self._mutex.release()


class _NoAnswer(Exception):
    pass


def _args(card, nex, map_file, freerun, extra, port):
    args = ["-zxnext", "-w1", "-esc", "-sound", "-mouse", "-nodelay"]
    if freerun:
        args.append("-freerun")
    args.append("-mmc=" + str(card).rstrip("\\") + "\\")    # CSpect needs the trailing backslash
    if map_file is not None:
        args.append(f"-map={map_file}")
    return args + [f"-mcp={port}", *extra, str(nex)]


def _start(cmd, cwd, port, start_timeout, log_path, append):
    """Start cmd in a kill-on-close job; return (proc, job, mcp) once MCP answers."""
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
                return proc, job, mcp
            except CSpectError:
                pass
            if time.monotonic() >= deadline:
                raise _NoAnswer(f"PID {proc.pid} did not answer MCP on port {port} in "
                                f"{start_timeout:g} s")
            time.sleep(0.2)                                  # poll interval against the deadline
    except BaseException:
        try:
            if proc.poll() is None:
                proc.kill()
            proc.wait(10)
        finally:
            if job:
                _k32.CloseHandle(job)
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
        if _TEST_COMMAND is not None:
            attempts = [(HARNESS_DIR, list(_TEST_COMMAND))]
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
    except BaseException:
        mutex.release()
        raise
