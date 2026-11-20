"""python tests/cspect/selftest.py --host [name ...]   no emulator
python tests/cspect/selftest.py --live [name ...]   CSpect through the launcher
Prints PASS name / FAIL name: why; exit 1 on any FAIL."""
import ctypes
import http.server
import json
import operator
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from ctypes import wintypes
from pathlib import Path

HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))

try:
    from cspect import client, launcher
    IMPORT_ERROR = None
except ImportError as e:
    client = launcher = None
    IMPORT_ERROR = e

try:
    from cspect import Session, session
    SESSION_ERROR = None
except ImportError as e:
    Session = session = None
    SESSION_ERROR = e

SLEEPER = [sys.executable, "-c", "import time; time.sleep(60)"]


class CheckFailed(Exception):
    pass


def need(cond, why):
    if not cond:
        raise CheckFailed(why)


def raises(exc, fn, *args, **kw):
    """Call fn; return the exception of type exc it raised, else fail."""
    try:
        fn(*args, **kw)
    except exc as e:
        return e
    raise CheckFailed(f"{getattr(fn, '__name__', fn)} did not raise {exc.__name__}")


_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.OpenProcess.restype, _k32.OpenProcess.argtypes = wintypes.HANDLE, (wintypes.DWORD, wintypes.BOOL,
                                                                       wintypes.DWORD)
_k32.WaitForSingleObject.restype = wintypes.DWORD
_k32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
_k32.TerminateProcess.restype, _k32.TerminateProcess.argtypes = wintypes.BOOL, (wintypes.HANDLE, wintypes.UINT)
_k32.CloseHandle.restype, _k32.CloseHandle.argtypes = wintypes.BOOL, (wintypes.HANDLE,)


class Held:
    """A handle opened while the process is known alive: a reused PID can never be hit through it."""

    def __init__(self, pid):
        self.pid = pid
        self.h = _k32.OpenProcess(0x00101001, False, pid)   # SYNCHRONIZE | QUERY_LIMITED | TERMINATE
        if not self.h:
            raise CheckFailed(f"cannot open PID {pid}: {ctypes.FormatError(ctypes.get_last_error())}")

    def alive(self):
        return _k32.WaitForSingleObject(self.h, 0) == 0x102  # WAIT_TIMEOUT

    def wait_gone(self, seconds):
        return _k32.WaitForSingleObject(self.h, int(seconds * 1000)) == 0

    def kill(self):
        if self.alive():
            _k32.TerminateProcess(self.h, 1)
            self.wait_gone(10)

    def close(self):
        if self.h:
            _k32.CloseHandle(self.h)
            self.h = None


class FakeMcp:
    """Local HTTP server on 127.0.0.1:port; reply(request) -> (headers, body)."""

    def __init__(self, reply, port=0):
        outer = self
        self.reply = reply
        self.seen = []                      # (request, Mcp-Session-Id header)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                outer.seen.append((req, self.headers.get("Mcp-Session-Id")))
                headers, body = outer.reply(req)
                data = body.encode()
                self.send_response(200)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


class Garbage:
    """127.0.0.1:port listener that answers every connection with non-HTTP bytes."""

    def __init__(self, port):
        self.sock = socket.create_server(("127.0.0.1", port))
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                try:
                    conn.recv(65536)
                    conn.sendall(b"\x00\x01garbage, not HTTP\r\n\r\n")
                except OSError:
                    pass

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.sock.close()


def ok_json(req, result):
    return json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": result})


def text_result(text):
    return {"content": [{"type": "text", "text": text}]}


def free_ports(n):
    """The first n ports of PORT_RANGE with nothing listening."""
    out = [p for p in launcher.PORT_RANGE if not launcher._port_busy(p)][:n]
    need(len(out) == n, f"fewer than {n} free ports in the harness range")
    return out


def logged_pids(log_path):
    return [int(p) for p in re.findall(r"^pid: (\d+)$", Path(log_path).read_text(), re.M)]


class hook:
    """Temporarily replace the launcher's per-attempt commands."""

    def __init__(self, *commands):
        self.commands = [list(c) for c in commands]

    def __enter__(self):
        self.saved = launcher._TEST_COMMANDS
        launcher._TEST_COMMANDS = self.commands

    def __exit__(self, *exc):
        launcher._TEST_COMMANDS = self.saved


# -- host checks ----------------------------------------------------------------------------------

DUMP = ("$6000  41 42 43 44 45 46 47 48  49 4A 4B 4C 4D 4E 4F 50  ABCDEFGHIJKLMNOP\r\n"
        "$6010  00 01 FE FF                                       ....")


def t_parse_dump_ok():
    got = client.parse_dump(DUMP, 0x6000, 20)
    need(got == bytes(range(0x41, 0x51)) + bytes([0, 1, 0xFE, 0xFF]), f"got {got.hex()}")


def t_dump_rejects_gap():
    gap = DUMP.replace("$6010", "$6020")
    e = raises(client.CSpectError, client.parse_dump, gap, 0x6000, 20)
    need("6020" in str(e), f"gap error does not name the line: {e}")
    raises(client.CSpectError, client.parse_dump, DUMP, 0x6000, 24)
    raises(client.CSpectError, client.parse_dump, DUMP.splitlines()[0], 0x6000, 20)
    raises(client.CSpectError, client.parse_dump, DUMP.replace("$6010", "$60G0"), 0x6000, 20)


def t_read_map():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.map"
        p.write_text("0000A200 0000A200 00 flags\n"
                     "0000C010 0005C010 00 ovlEntry\n"
                     "\n"
                     "00000008 00000008 01 AKY_RET_GUARD\n", encoding="ascii")
        got = client.read_map(p)
        p.write_text("00009465 00009465 00 win_attr\n0000000A 0000000A 01 WIN_ATTR\n", encoding="ascii")
        twin = client.read_map(p)["WIN_ATTR"]
        need(twin == (0x9465, 0x9465, 0), f"twin with the EQU line last resolved to {twin}, not the label")
        p.write_text("0000A200 0000A200 00 flags\n0000C010 00 ovlEntry\n", encoding="ascii")
        e = raises(client.CSpectError, client.read_map, p)
        need("ovlEntry" in str(e), f"malformed-line error does not name the line: {e}")
        p.write_text("0000A200 0000A2ZZ 00 flags\n", encoding="ascii")
        raises(client.CSpectError, client.read_map, p)
        p.write_text("\n", encoding="ascii")
        raises(client.CSpectError, client.read_map, p)
    want = {"FLAGS": (0xA200, 0xA200, 0), "OVLENTRY": (0xC010, 0x5C010, 0),
            "AKY_RET_GUARD": (8, 8, 1)}
    need(got == want, f"got {got}")
    real = ROOT / "build" / "nextdaad.map"
    if real.is_file():
        lines = [ln.split() for ln in real.read_text(encoding="ascii").splitlines() if ln.strip()]
        names = [p[3].upper() for p in lines]
        twins = sorted({n for n in names if names.count(n) > 1})
        got = client.read_map(real)
        need(set(got) == set(names), f"{real}: {len(got)} symbols, {len(set(names))} names in the file")
        labels = {p[3].upper(): (int(p[0], 16), int(p[1], 16), 0) for p in lines if int(p[2], 16) == 0}
        need("WIN_ATTR" in labels, f"{real} has no WIN_ATTR label")
        for name in sorted(set(twins) | {"WIN_ATTR"}):
            need(name not in labels or got[name] == labels[name], f"{name} resolved to {got[name]}, not its label")
        return f"{real.name}: {len(lines)} lines parsed, {len(got)} names; case twins resolve to labels: {twins}"
    return "no build\\nextdaad.map to cross-check"


def t_reply_sse_and_plain():
    resp = '{"jsonrpc":"2.0","id":7,"result":{"ok":1}}'
    sse = 'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress"}\n\ndata: ' + resp + "\n\n"
    need(client.decode_reply(resp) == json.loads(resp), "plain body not decoded")
    need(client.decode_reply(sse) == json.loads(resp), "SSE body: last data: line not used")
    raises(client.CSpectError, client.decode_reply, "")
    turn = iter([({"Mcp-Session-Id": "s-1"}, None), ({"Content-Type": "text/event-stream"}, "sse"),
                 ({}, None)])

    def reply(req):
        headers, kind = next(turn)
        body = ok_json(req, {"n": req["id"]})
        return headers, ("event: message\ndata: " + body + "\n\n") if kind == "sse" else body

    with FakeMcp(reply) as srv:
        m = client.Mcp(srv.port)
        need(m.rpc("ping") == {"n": 1}, "plain reply result")
        need(m.rpc("ping") == {"n": 2}, "SSE reply result")
        m.rpc("ping")
    sessions = [s for _, s in srv.seen]
    need(sessions == [None, "s-1", "s-1"], f"Mcp-Session-Id not kept: {sessions}")
    need(m.session == "s-1", f"session {m.session}")


def t_tools_reply_checked():
    replies = iter([{}, {"tools": [{"inputSchema": {}}]}])
    with FakeMcp(lambda req: ({}, ok_json(req, next(replies)))) as srv:
        m = client.Mcp(srv.port)
        e = raises(client.CSpectError, m.tools)
        need("'tools'" in str(e), f"error does not name the missing key: {e}")
        e = raises(client.CSpectError, m.tools)
        need("'name'" in str(e), f"error does not name the missing key: {e}")


def t_garbage_listener():
    port, nxt = free_ports(2)
    with Garbage(port):
        e = raises(client.CSpectError, client.Mcp(port).initialize, timeout=2)
        need("initialize" in str(e), f"error does not name the method: {e}")
        got = launcher.choose_port()
        need(got == nxt, f"automatic choice gave {got}, wanted {nxt} (garbage on {port})")
        e = raises(launcher.LaunchError, launcher.choose_port, port)
        need("not an MCP server" in str(e), f"explicit port error: {e}")


def t_status_without_pc_raises():
    texts = iter(["AF $0044 BC $0000 SP $FF00", "AF $0044 PC $8123 SP $FF00"])
    with FakeMcp(lambda req: ({}, ok_json(req, text_result(next(texts))))) as srv:
        m = client.Mcp(srv.port)
        e = raises(client.CSpectError, m.pc)
        need("PC" in str(e), f"error does not name PC: {e}")
        need(m.pc() == 0x8123, "PC not parsed from a good status")
    need(srv.seen[0][0]["params"]["name"] == "get_status", "pc() did not call get_status")


def t_required_tools_checked():
    tools = [{"name": n, "inputSchema": {}} for n in launcher.REQUIRED_TOOLS if n != "run_to"]
    e = raises(launcher.LaunchError, launcher.check_tools, tools)
    need("run_to" in str(e), f"error does not name run_to: {e}")
    launcher.check_tools(tools + [{"name": "run_to", "inputSchema": {}}])


def t_version_gate():
    e = raises(launcher.LaunchError, launcher.check_version, (4, 5, 8, 0))
    need("4.5.9.0" in str(e), f"error does not name the minimum: {e}")
    launcher.check_version((4, 5, 9, 0))
    launcher.check_version((4, 6, 0, 0))


def t_port_choice():
    port, nxt = free_ports(2)
    with FakeMcp(lambda req: ({}, ok_json(req, {"protocolVersion": "2025-03-26"})), port=port):
        got = launcher.choose_port()
        need(got == nxt, f"automatic choice gave {got}, wanted {nxt} (MCP on {port})")
        e = raises(launcher.LaunchError, launcher.choose_port, port)
        need(str(port) in str(e) and "MCP" in str(e), f"explicit port error: {e}")
    raises(launcher.LaunchError, launcher.choose_port, 23456)


def t_private_copy_excludes():
    saved = launcher.PRIVATE_DIR
    with tempfile.TemporaryDirectory() as d:
        src, dest = Path(d) / "src", Path(d) / "copy"
        src.mkdir()
        for name in ("CSpect.exe", "zxnext.mmc", "DeZogPlugin.dll", "MCP.dll", "Old.dll"):
            (src / name).write_bytes(name.encode())
        launcher.PRIVATE_DIR = dest
        try:
            got = launcher.private_copy(src)
            need(got == dest, f"returned {got}")
            names = sorted(p.name for p in dest.iterdir())
            need(names == ["CSpect.exe", "MCP.dll", "Old.dll"], f"copy holds {names}")

            # a marker kept at the source's size and timestamp shows whether a file was re-copied
            def mark(name):
                p, s = dest / name, (src / name).stat()
                p.write_bytes(b"#" * s.st_size)
                os.utime(p, ns=(s.st_atime_ns, s.st_mtime_ns))

            mark("CSpect.exe")
            mark("MCP.dll")
            launcher.private_copy(src)
            need((dest / "CSpect.exe").read_bytes().startswith(b"#")
                 and (dest / "MCP.dll").read_bytes().startswith(b"#"), "unchanged source re-copied")

            s = (src / "MCP.dll").stat()
            os.utime(src / "MCP.dll", ns=(s.st_atime_ns, s.st_mtime_ns + 10_000_000_000))
            launcher.private_copy(src)
            need((dest / "MCP.dll").read_bytes() == b"MCP.dll", "MCP.dll timestamp change not refreshed")
            need((dest / "CSpect.exe").read_bytes().startswith(b"#"), "exe re-copied on an MCP.dll change")

            (src / "CSpect.exe").write_bytes(b"CSpect.exe v2")
            launcher.private_copy(src)
            need((dest / "CSpect.exe").read_bytes() == b"CSpect.exe v2", "exe size change not refreshed")

            (src / "Old.dll").unlink()
            (dest / "DeZogPlugin.dll").write_bytes(b"stale")
            launcher.private_copy(src)
            names = sorted(p.name for p in dest.iterdir())
            need(names == ["CSpect.exe", "MCP.dll"], f"stale or excluded files kept: {names}")
        finally:
            launcher.PRIVATE_DIR = saved


JOB_HELPER = r"""
import subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from cspect import launcher
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
job = launcher.kill_on_close_job(child.pid)
print(child.pid, flush=True)
time.sleep(60)
"""


def t_job_kills_child():
    helper = subprocess.Popen([sys.executable, "-c", JOB_HELPER, str(TESTS)],
                              stdout=subprocess.PIPE, text=True)
    child = None
    try:
        child = Held(int(helper.stdout.readline()))
        need(child.alive(), "child not running before the helper was killed")
        helper.kill()
        helper.wait(10)
        need(child.wait_gone(5), f"child PID {child.pid} still alive 5 s after its helper was killed")
    finally:
        helper.kill()
        if child:
            child.kill()
            child.close()


MUTEX_HOLDER = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from cspect import launcher
launcher.MUTEX_NAME = sys.argv[2]
m = launcher.Mutex.acquire(wait=5)
print("held", flush=True)
time.sleep(60)
"""

MUTEX_WAITER = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from cspect import launcher
launcher.MUTEX_NAME = sys.argv[2]
t = time.monotonic()
try:
    launcher.launch(sys.argv[3], sys.argv[4])
    print("LAUNCHED")
except launcher.LaunchError as e:
    print("ERR %.2f %s" % (time.monotonic() - t, e))
"""


def t_mutex_serialises():
    name = launcher.MUTEX_NAME
    holder = subprocess.Popen([sys.executable, "-c", MUTEX_HOLDER, str(TESTS), name],
                              stdout=subprocess.PIPE, text=True)
    try:
        need(holder.stdout.readline().strip() == "held", "holder did not take the mutex")
        env = dict(os.environ, NEXTDAAD_CSPECT_WAIT="2")
        out = subprocess.run([sys.executable, "-c", MUTEX_WAITER, str(TESTS), name, str(HERE), __file__],
                             env=env, capture_output=True, text=True, timeout=30).stdout.strip()
        m = re.match(r"ERR (\d+\.\d+) (.*)", out)
        need(m, f"waiter output {out!r}")
        need(name in m.group(2), f"error does not name the mutex: {m.group(2)}")
        need(2.0 <= float(m.group(1)) <= 4.0, f"waited {m.group(1)} s, wanted 2-4")
    finally:
        holder.kill()
        holder.wait(10)


def t_mutex_release_checked():
    m = launcher.Mutex.acquire(wait=1)
    errors = []

    def other_thread():
        try:
            m.release()
        except launcher.LaunchError as e:
            errors.append(e)

    t = threading.Thread(target=other_thread)
    t.start()
    t.join()
    try:
        need(errors and "ReleaseMutex" in str(errors[0]), f"release from another thread: {errors}")
        need(launcher.Mutex._held, "held flag cleared although the OS mutex is still owned")
    finally:
        m.release()
    need(not launcher.Mutex._held, "release from the owning thread did not clear the hold")


class _StuckProc:
    pid = 999999

    def poll(self):
        return None

    def kill(self):
        pass

    def wait(self, timeout=None):
        raise subprocess.TimeoutExpired("cspect", timeout)


def t_close_keeps_mutex():
    m = launcher.Mutex.acquire(wait=1)
    inst = launcher.Instance(_StuckProc(), None, None, 0, HERE, m, None)
    try:
        e = raises(launcher.LaunchError, inst.close)
        need("999999" in str(e), f"error does not name the PID: {e}")
        need(launcher.Mutex._held and m._handle, "mutex released while the process may still run")
    finally:
        m.release()


def t_listener_owner():
    with FakeMcp(lambda req: ({}, ok_json(req, {}))) as srv:
        got = launcher.listener_pids(srv.port)
        need(got == {os.getpid()}, f"listener_pids({srv.port}) = {got}, wanted {{{os.getpid()}}}")
    port = free_ports(1)[0]
    saved = launcher._port_busy
    srv = FakeMcp(lambda req: ({}, ok_json(req, {"protocolVersion": "2025-03-26"})), port=port)
    with srv, hook(SLEEPER):
        launcher._port_busy = lambda p: None        # the port is taken after choose_port looked
        try:
            e = raises(launcher.LaunchError, launcher.launch, HERE, __file__, port=port, start_timeout=5)
        finally:
            launcher._port_busy = saved
        need(str(os.getpid()) in str(e) and "not the launched PID" in str(e), f"owner error: {e}")
        pids = logged_pids(launcher.HARNESS_DIR / f"console-{port}.log")
        need(len(pids) == 1 and not launcher.pid_alive(pids[0]), f"stand-in left running: {pids}")
        need(client.Mcp(port).initialize(timeout=2) is not None, "foreign server disturbed")
    return f"own listener PID {os.getpid()} found; foreign listener refused"


def t_no_answer_names_causes():
    with hook(SLEEPER, SLEEPER):
        e = raises(launcher.LaunchError, launcher.launch, HERE, __file__, start_timeout=2)
    text = str(e)
    for want in ("older than 4.3", "MCP.dll", "MCP tier"):
        need(want in text, f"error does not name {want!r}: {text}")
    pids = [int(p) for p in re.findall(r"PID (\d+)", text)]
    need(len(pids) == 2, f"error does not name both attempts' PIDs: {text}")
    need(not any(launcher.pid_alive(p) for p in pids), f"stand-in still alive: {pids}")


STUB_MCP = r"""
import http.server, json, sys
sys.path.insert(0, sys.argv[1])
from cspect import launcher
tools = [{"name": n, "inputSchema": {}} for n in launcher.REQUIRED_TOOLS]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        res = {"tools": tools} if req["method"] == "tools/list" else {}
        body = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": res}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
"""


def t_fallback_runs():
    with hook(SLEEPER, [sys.executable, "-c", STUB_MCP, str(TESTS), "{port}"]):
        inst = launcher.launch(HERE, __file__, start_timeout=2)
    held = Held(inst.pid)
    try:
        pids = logged_pids(inst.log_path)
        need(len(pids) == 2 and pids[1] == inst.pid, f"attempt PIDs {pids}, instance PID {inst.pid}")
        need(not launcher.pid_alive(pids[0]), f"hanging first attempt PID {pids[0]} still alive")
        need(len(inst.mcp.tools()) == len(launcher.REQUIRED_TOOLS), "stub tools not served")
        inst.close()
        need(not held.alive(), f"fallback PID {inst.pid} alive after close")
    finally:
        inst.close()
        held.kill()
        held.close()
    return f"first attempt PID {pids[0]} gone, fallback PID {pids[1]} answered"


# -- live checks (DEBUG build\nextdaad.nex from build.ps1, card sd\SUITE from build-tests -Suite) --

CARD = ROOT / "sd" / "SUITE"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
STARTED = []                 # Held handle for every CSpect the live checks started


def need_staged():
    for p in (CARD / "GAME.DDB", NEX, MAP):
        need(p.is_file(), f"{p} missing: run .\\build.ps1 and tests\\build-tests.ps1 -Suite")


def live_launch(**kw):
    need_staged()
    inst = launcher.launch(CARD, NEX, MAP, **kw)
    held = Held(inst.pid)
    STARTED.append(held)
    return inst, held


def _user32():
    w = wintypes
    u32 = ctypes.WinDLL("user32")
    for name, res, args in (("GetWindowThreadProcessId", w.DWORD, (w.HWND, ctypes.POINTER(w.DWORD))),
                            ("IsWindowVisible", w.BOOL, (w.HWND,)), ("IsIconic", w.BOOL, (w.HWND,)),
                            ("GetWindow", w.HWND, (w.HWND, w.UINT)),
                            ("GetWindowTextW", ctypes.c_int, (w.HWND, w.LPWSTR, ctypes.c_int)),
                            ("GetForegroundWindow", w.HWND, ())):
        getattr(u32, name).restype, getattr(u32, name).argtypes = res, args
    return u32


def top_windows(pid):
    """[(hwnd, title, iconic)] for pid's visible unowned top-level windows."""
    u32 = _user32()
    found = []

    def each(hwnd, _):
        owner = wintypes.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and u32.IsWindowVisible(hwnd) and not u32.GetWindow(hwnd, 4):  # GW_OWNER
            title = ctypes.create_unicode_buffer(256)
            u32.GetWindowTextW(hwnd, title, 256)
            found.append((hwnd, title.value, bool(u32.IsIconic(hwnd))))
        return True

    u32.EnumWindows(ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)(each), 0)
    return found


def listening_ports(pid):
    cmd = (f"Get-NetTCPConnection -OwningProcess {pid} -State Listen -ErrorAction SilentlyContinue"
           " | Select-Object -ExpandProperty LocalPort")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", cmd], capture_output=True, text=True,
                         timeout=60).stdout
    return {int(p) for p in out.split()}


def l_launch_tools_close():
    inst, held = live_launch()
    with inst:
        names = {t["name"] for t in inst.mcp.tools()}
    missing = [t for t in launcher.REQUIRED_TOOLS if t not in names]
    need(not missing, f"tools/list lacks {missing}")
    need(not held.alive(), f"PID {held.pid} alive after close")
    return f"PID {held.pid}, {len(names)} tools"


def l_private_copy_mcp():
    inst, held = live_launch()
    with inst:
        where = Path(inst.exe_dir)
    copy = launcher.PRIVATE_DIR
    for name in ("DeZogPlugin.dll", "zxnext.mmc"):
        need(not (copy / name).exists(), f"private copy holds {name}")
    which = "the private copy" if where == copy else "the source install (fallback)"
    return f"MCP answered from {which} {where} (PID {held.pid})"


def l_no_port_11000():
    inst, held = live_launch()
    with inst:
        if Path(inst.exe_dir) != launcher.PRIVATE_DIR:
            return f"n/a: the source install ran (PID {inst.pid})"
        deadline = time.monotonic() + 3
        while True:
            ports = listening_ports(inst.pid)
            need(inst.port in ports, f"MCP port {inst.port} not seen owned by PID {inst.pid}: {ports}")
            need(11000 not in ports, f"PID {inst.pid} listens on 11000: {sorted(ports)}")
            if time.monotonic() >= deadline:
                return f"PID {inst.pid} listens on {sorted(ports)} only"
            time.sleep(0.5)


def l_window_minimised():
    inst, held = live_launch()
    with inst:
        deadline = time.monotonic() + 20
        while not top_windows(inst.pid):
            need(time.monotonic() < deadline, f"PID {inst.pid} showed no visible top-level window in 20 s")
            time.sleep(0.2)
        end = time.monotonic() + 3          # observe 3 s: a late restore or focus grab FAILs
        while True:
            wins, fg = top_windows(inst.pid), _user32().GetForegroundWindow()
            seen = (f"PID {inst.pid} windows "
                    + (", ".join(f"{h:#x} {t!r} {'iconic' if i else 'NOT iconic'}"
                                 f"{' FOREGROUND' if h == fg else ''}" for h, t, i in wins) or "none")
                    + f"; foreground {fg or 0:#x}")
            need(wins and all(i for _, _, i in wins) and fg not in [h for h, _, _ in wins], seen)
            if time.monotonic() >= end:
                return seen
            time.sleep(0.25)


HELPER = r"""
import sys
sys.path.insert(0, sys.argv[1])
from cspect import launcher
inst = launcher.launch(*sys.argv[2:5])
print(inst.pid, flush=True)
sys.stdin.readline()
inst.close()
print("closed", flush=True)
"""


def spawn_helper():
    env = dict(os.environ, NEXTDAAD_CSPECT_WAIT="10")
    helper = subprocess.Popen([sys.executable, "-c", HELPER, str(TESTS), str(CARD), str(NEX), str(MAP)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, env=env)
    line = helper.stdout.readline().strip()
    if not line.isdigit():
        helper.kill()
        raise CheckFailed(f"helper did not launch: {line!r} {helper.stderr.read()[-500:]!r}")
    held = Held(int(line))
    STARTED.append(held)
    return helper, held


def l_parent_killed():
    helper, held = spawn_helper()
    try:
        need(held.alive(), f"helper's CSpect PID {held.pid} not running")
        helper.kill()
        helper.wait(10)
        need(held.wait_gone(5), f"CSpect PID {held.pid} alive 5 s after its parent was killed")
    finally:
        helper.kill()
    return f"PID {held.pid} gone after parent kill"


def l_exception_closes():
    held = None
    try:
        inst, held = live_launch()
        with inst:
            raise RuntimeError("raised inside with")
    except RuntimeError:
        pass
    need(held is not None, "launch did not return")
    need(not held.alive(), f"PID {held.pid} alive after the exception")
    return f"PID {held.pid} closed"


def l_foreign_untouched():
    helper, held = spawn_helper()
    saved = os.environ.get("NEXTDAAD_CSPECT_WAIT")
    try:
        os.environ["NEXTDAAD_CSPECT_WAIT"] = "3"
        e = raises(launcher.LaunchError, live_launch)
        need(launcher.MUTEX_NAME in str(e), f"error does not name the mutex: {e}")
        need(held.alive(), f"helper's CSpect PID {held.pid} was killed")
        helper.stdin.write("\n")
        helper.stdin.flush()
        need(helper.stdout.readline().strip() == "closed", "helper did not close its CSpect")
        helper.wait(10)
        need(not held.alive(), f"helper's CSpect PID {held.pid} alive after the helper closed it")
    finally:
        if saved is None:
            os.environ.pop("NEXTDAAD_CSPECT_WAIT", None)
        else:
            os.environ["NEXTDAAD_CSPECT_WAIT"] = saved
        helper.kill()
    return f"helper PID {held.pid} survived the refused launch"


def t_guard_parser():
    src = (TESTS / "build-tests.ps1").read_text(encoding="utf-8-sig")
    m = re.search(r"^function Test-MmcMountsSd.*?^}", src, re.S | re.M)
    need(m, "Test-MmcMountsSd not found in build-tests.ps1")
    sd = r"D:\NextDAAD\sd"
    cases = [  # (command line, expected)
        (r"CSpect.exe -zxnext -mcp=1 x.nex", False),
        (r"CSpect.exe -mmc=D:\NextDAAD\sd\SUITE\ -map=a x.nex", True),
        (r'CSpect.exe -mmc="D:\NextDAAD\sd\LEG A\" x.nex', True),
        (r"CSpect.exe -mmc=d:/nextdaad/SD/suite x.nex", True),
        (r"CSpect.exe -mmc=D:\NextDAAD\sd x.nex", True),
        (r'CSpect.exe "-mmc=D:\NextDAAD\sd\S\" x.nex', True),
        (r"CSpect.exe -mmc=D:\NextDAAD\tests\out\cspect-guard\card\ x.nex", False),
        (r'CSpect.exe -mmc="D:\Next DAAD\sd\" x.nex', False),
        (r"CSpect.exe -mmc=D:\NextDAAD\sdx\ x.nex", False),
        (r"CSpect.exe -mmc=D:\NextDAAD\sd\..\build\ x.nex", False),
        (r"CSpect.exe -mmc=./ x.nex", True),
        (r"CSpect.exe -mmc= x.nex", True),
        ("", True),
    ]
    lines = [m.group(0), f"$sd = '{sd}'", "$bad = @()"]
    for i, (cmd, want) in enumerate(cases):
        lines.append(f"if ((Test-MmcMountsSd '{cmd}' $sd) -ne ${str(want).lower()}) {{ $bad += {i} }}")
    lines.append("if ((Test-MmcMountsSd $null $sd) -ne $true) { $bad += 99 }")
    lines.append("Write-Output ('BAD=' + ($bad -join ','))")
    r = subprocess.run(["pwsh", "-NoProfile", "-Command", "\n".join(lines)], capture_output=True,
                       text=True, timeout=60)
    need("BAD=" in r.stdout, f"pwsh failed: {r.stderr[-300:]}")
    bad = r.stdout.split("BAD=")[1].strip()
    need(not bad, f"wrong verdict for case indexes {bad}")
    return f"{len(cases) + 1} command lines"


def stage_suite():
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(TESTS / "build-tests.ps1"), "-Suite"],
                          capture_output=True, text=True, timeout=600)


def l_guard_narrowed():
    side = ROOT / "tests" / "out" / "cspect-guard" / "card"
    side.mkdir(parents=True, exist_ok=True)
    need(CARD.joinpath("GAME.DDB").is_file(), f"{CARD}\\GAME.DDB missing: run tests\\build-tests.ps1 -Suite")
    (side / "GAME.DDB").write_bytes((CARD / "GAME.DDB").read_bytes())
    inst = launcher.launch(side, NEX, MAP)
    held = Held(inst.pid)
    STARTED.append(held)
    with inst:
        r = stage_suite()
        need(r.returncode == 0, f"staging refused with a CSpect off sd\\ (exit {r.returncode}): {r.stderr[-300:]}")
    need(not held.alive(), f"PID {held.pid} alive after close")
    inst, held = live_launch()
    with inst:
        r = stage_suite()
        need(r.returncode != 0, "staging did not refuse with a CSpect on sd\\SUITE")
        need("CSpect is running - close it before staging" in r.stdout + r.stderr,
             f"refusal text missing: {(r.stdout + r.stderr)[-300:]}")
    need(not held.alive(), f"PID {held.pid} alive after close")
    return "card under tests\\out passes, sd\\SUITE refuses"


# -- session host checks --------------------------------------------------------------------------

def need_session():
    need(Session is not None, f"cspect.Session missing: {SESSION_ERROR}")


STATUS = ("CPU: stopped (in the debugger)\r\nPC $9CB2 (ENG_INIT_GAME@SEEDOK)   SP $BCFE\r\n"
          "AF $0304  BC $0000  DE $0000  HL $0102\r\nAF'$0000  BC'$1111  DE'$0000  HL'$0000\r\n"
          "IX $A354  IY $0000  I $BD  R $08  IM 2  IFF1 1  IFF2 0\r\n"
          "Flags: - - - P/V - -   (NZ, NC, PE, P)\r\n"
          "MMU:  0:ROM  1:ROM  2:$0A  3:$0B  4:$04  5:$05  6:$00  7:$38\n\n"
          "                     ENG_INIT_GAME@SEEDOK:\r\n"
          ">*$9CB2  22 4D A9     LD (RNGSTATE),HL         ; 16T\r\n  $9CB5  C9           RET")


def t_session_status():
    need_session()
    state, r = session.parse_status("Reached $9CB2\n" + STATUS, "run_to")
    want = {"PC": 0x9CB2, "SP": 0xBCFE, "AF": 0x0304, "HL": 0x0102, "BC'": 0x1111, "IX": 0xA354,
            "I": 0xBD, "R": 8, "IM": 2, "IFF1": 1, "IFF2": 0, "A": 3, "F": 4, "IXH": 0xA3, "L": 2}
    need(state == "stopped" and all(r[k] == v for k, v in want.items()),
         f"parsed {state} {[(k, r.get(k)) for k in want if r.get(k) != want[k]]}")
    need(session.parse_status(STATUS.replace("stopped (in the debugger)", "running"))[0] == "running",
         "running state not parsed")
    e = raises(client.CSpectError, session.parse_status, STATUS.replace("PC $9CB2", "PQ $9CB2"))
    need("get_status" in str(e) and "PC" in str(e), f"gap error does not name the tool and PC: {e}")
    e = raises(client.CSpectError, session.parse_status, "Still running after 200ms", "wait_for_stop")
    need("wait_for_stop" in str(e), f"error does not name the tool: {e}")


def dump_text(addr, n):
    """read_memory's hex dump of n zero bytes at addr."""
    return "\r\n".join(f"${a:04X}  " + " ".join("00" for _ in range(min(16, addr + n - a)))
                       for a in range(addr, addr + n, 16))


def t_session_fake_mcp():
    need_session()
    calls, nr = [], {0x52: 0x0A, 0x53: 0x0E}

    def rnr(a):
        regs = [int(x[1:], 16) for x in a["registers"].split(",")]
        return "\r\n".join(f"NextReg ${n:02X} = ${nr.get(n, 0):02X}  %00000000" for n in regs if n != 0x99)

    tools = {
        "read_next_registers": rnr,
        "read_memory": lambda a: calls.append(("read", a["address"], a["physical"]))
        or dump_text(int(a["address"][1:], 16), a["length"]),
        "write_memory": lambda a: calls.append(("write", a["address"], a["data"], a["physical"]))
        or f"Wrote {len(a['data']) // 2} bytes at {a['address']}",
        "port_in": lambda a: f"IN {a['port']} = $3F (63, %00111111)",
        "debug_command": lambda a: calls.append(("debug", a["command"])) or "OK",
        "get_status": lambda a: STATUS,
    }

    def reply(req):
        if req["method"] != "tools/call":
            return {}, ok_json(req, {})
        return {}, ok_json(req, text_result(tools[req["params"]["name"]](req["params"]["arguments"])))

    with FakeMcp(reply) as srv:
        s = Session(client.Mcp(srv.port), {}, map_file="fake.map")
        need(s.next_regs([0x52, 0x53]) == {0x52: 0x0A, 0x53: 0x0E}, "next_regs parse")
        e = raises(client.CSpectError, s.next_regs, [0x52, 0x99])
        need("$99" in str(e) and "read_next_registers" in str(e), f"missing NR error: {e}")
        e = raises(client.CSpectError, s.read_page, 11, 0, 16)
        need("bank 5" in str(e) and "NR $53" in str(e), f"bank 5 gap error: {e}")
        need(s.read_page(10, 0x100, 16) == bytes(16), "page 10 read")
        s.read_page(95, 0x1F00, 16)
        s.write_page(95, 0, b"\x01\x02")
        s.write_page(10, 0x1700, b"\x03")
        need(s.port_in(0xFFFD) == 0x3F, "port_in parse")
        s.port_out(0x243B, 0)
        s.port_out(0xFFFD, 0x0D)
        raises(ValueError, s.read_page, 95, 0x1FF0, 32)
        raises(ValueError, s.diff_bytes, b"\0", addr=0, page=1)
    want = [("read", "$4100", False), ("read", "$BFF00", True), ("write", "$BE000", "0102", True),
            ("write", "$5700", "03", False), ("debug", "OUT $243B,$00"), ("debug", "OUT $FFFD,$0D")]
    need(calls == want, f"MCP calls {calls}")


def t_session_boot_args():
    need_session()
    got = session.boot_args(True, 0x9CB2, 0x33, 3)
    need(got == ["-major=51", "-minor=3", "-debug", "+brk=$9CB2"], f"boot args {got}")
    need(session.boot_args() == [], "default boot adds extras")
    raises(ValueError, session.boot_args, major=256)
    s = Session(None, {"FLAGS": (0xA200, 0xA200, 0)}, map_file="x.map")
    need(s.sym("flags") == 0xA200, "sym is not case-insensitive")
    e = raises(KeyError, s.sym, "NO_SUCH")
    need("NO_SUCH" in str(e), f"KeyError does not name the symbol: {e}")


def t_session_raster():
    need_session()
    cases = [((10, 100, 10, 200), (0, 100)), ((10, 248, 11, 248), (1, 0)), ((10, 300, 11, 10), (1, 21)),
             ((10, 10, 12, 300), (1, 290)), ((0xFFFF, 5, 0x0001, 5), (2, 0))]
    for args, want in cases:
        got = session.raster_elapsed(*args)
        need(got == want, f"raster_elapsed{args} = {got}, wanted {want}")
    e = raises(client.CSpectError, session.raster_elapsed, 10, 100, 10, 250)
    need("missed a tick" in str(e), f"no-tick error: {e}")


def t_session_border_index():
    need_session()
    from PIL import Image
    need(session.ULA_RGB[1] == (0, 0, 182) and session.ULA_RGB[7] == (182, 182, 182),
         f"default ULA palette expanded as {session.ULA_RGB}")
    for i, rgb in enumerate(session.ULA_RGB):
        img = Image.new("RGB", (320, 256), rgb)
        img.paste((219, 219, 219), (0, 0, 40, 8))        # text in the band
        img.paste((1, 200, 3), (32, 32, 288, 224))       # the paper area is not border
        got = session.ula_border_index(img)
        need(got == i, f"border {rgb} read as index {got}, wanted {i}")
    e = raises(client.CSpectError, session.ula_border_index, Image.new("RGB", (320, 256), (219, 219, 219)))
    need("219" in str(e), f"non-ULA colour error: {e}")
    raises(ValueError, session.ula_border_index, Image.new("RGB", (640, 512)))


def t_session_wait_until():
    need_session()
    s = Session(None, {})
    seq = iter([0, None, 7])
    need(s.wait_until(lambda: next(seq), 5, poll=0.01) == 7, "first truthy value not returned")
    e = raises(TimeoutError, s.wait_until, lambda: 0, 0.1, poll=0.01, what="the moon")
    need("the moon" in str(e), f"TimeoutError does not name what: {e}")


class FakeCpu:
    """Scripted CSpect run state for host checks. hit_on_arm: a breakpoint armed while running
    is hit before the next call (MCP is served at the frame interrupt). hit_before_pause: armed
    address a running CPU stops at before a pause lands. log: tool names called."""
    FRAME_ADDR = 0x828E

    def __init__(self, running=True, pc=0x99C6, bps=(), hit_on_arm=False, hit_before_pause=None):
        self.running, self.pc, self.bps = running, pc, set(bps)
        self.hit_on_arm, self.hit_before_pause = hit_on_arm, hit_before_pause
        self.log, self.frame = [], 100
        self.keys, self.keys_reply = [], None      # press_keys arguments; stopped-CPU reply override

    def stop(self, pc):
        self.running, self.pc = False, pc
        self.frame += 1

    def status(self):
        return STATUS.replace("stopped (in the debugger)", "running" if self.running else "stopped "
                              "(in the debugger)").replace("PC $9CB2", f"PC ${self.pc:04X}")

    def call(self, name, a):
        self.log.append(name)
        addr = int(a["address"][1:], 16) if "address" in a else None
        if name == "get_status":
            return self.status()
        if name == "set_breakpoint":
            self.bps.add(addr)
            if self.running and self.hit_on_arm:
                self.stop(addr)
            return f"Set execute breakpoint at ${addr:04X}"
        if name == "clear_breakpoint":
            self.bps.discard(addr)
            return f"Cleared execute breakpoint at ${addr:04X}"
        if name == "list_breakpoints":
            armed = ", ".join(f"${b:04X}" for b in sorted(self.bps)) or "none"
            return f"Execute (64K): {armed}\r\nExecute (physical): none\r\nRead: none"
        if name == "run":
            self.running = True
            return "Running"
        if name == "wait_for_stop":
            if self.running and self.bps:
                self.stop(min(self.bps))
            return "Still running after 10ms" if self.running else self.status()
        if name == "pause":
            if self.running:
                self.stop(self.hit_before_pause if self.hit_before_pause in self.bps else 0xBEBE)
            return self.status()
        if name == "read_next_registers":
            vals = {0x1E: 0, 0x1F: 100, 0x52: 0x0A, 0x53: 0x0B}
            return "\r\n".join(f"NextReg ${n:02X} = ${vals.get(n, 0):02X}  %0" for n in
                               (int(x[1:], 16) for x in a["registers"].split(",")))
        if name == "read_memory":
            data = (self.frame.to_bytes(2, "little") if addr == self.FRAME_ADDR else b"") + bytes(a["length"])
            return "\r\n".join(f"${addr + i:04X}  " + " ".join(f"{b:02X}" for b in data[i:i + 16])
                               for i in range(0, a["length"], 16))
        if name == "debug_command":
            return "OK"
        if name == "port_in":
            return f"IN {a['port']} = $00 (0, %00000000)"
        if name == "press_keys":
            self.keys.append(dict(a))
            if self.running:
                n = len(a["keys"].replace(",", " ").split())
                return f"Keys done ({n * a.get('hold_frames', 3) + n * a.get('gap_frames', 3)} frames)"
            return self.keys_reply or "Keys queued - the CPU is stopped, so they'll be pressed when it runs"
        raise KeyError(name)

    def session(self, srv):
        return Session(client.Mcp(srv.port), {"FRAMECOUNTER": (self.FRAME_ADDR, self.FRAME_ADDR, 0)})


def fake_cpu_server(cpu):
    def reply(req):
        if req["method"] != "tools/call":
            return {}, ok_json(req, {})
        return {}, ok_json(req, text_result(cpu.call(req["params"]["name"], req["params"]["arguments"])))
    return FakeMcp(reply)


def t_session_symbols():
    need_session()
    need(isinstance(getattr(Session, "symbols", None), property), "Session.symbols is not a property")
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.map"
        p.write_text("0000A200 0000A200 00 flags\n00009CB2 00009CB2 00 eng_init_game@seedok\n"
                     "00000008 00000008 01 AKY_RET_GUARD\n", encoding="ascii")
        syms = client.read_map(p)
        s = Session(None, syms, map_file=p)
        need(dict(s.symbols) == syms, f"symbols {dict(s.symbols)} != read_map {syms}")
        raises(TypeError, operator.setitem, s.symbols, "FLAGS", (0, 0, 0))   # read-only
        for name in ("flags", "ENG_INIT_GAME@SEEDOK", "aky_ret_guard"):
            need(s.sym(name) == s.symbols[name.upper()][0], f"sym({name!r}) disagrees with symbols")
        twin = Session(None, s.symbols, map_file=p)            # how nleg.key_session builds one
        need(twin.sym("flags") == 0xA200, "a Session built on symbols resolves differently")
    if MAP.is_file():
        s = Session(None, client.read_map(MAP), map_file=MAP)
        bad = [n for n, v in s.symbols.items() if s.sym(n) != v[0]]
        need(not bad, f"{len(bad)} names where sym() and symbols disagree, e.g. {bad[:3]}")
        return f"{len(s.symbols)} names in {MAP.name} agree with sym()"
    return "synthetic map only (build/nextdaad.map absent)"


def t_session_stop_races():
    need_session()
    # I1: time_between on a running CPU whose start breakpoint hits as soon as it is armed
    cpu = FakeCpu(hit_on_arm=True)
    with fake_cpu_server(cpu) as srv:
        got = cpu.session(srv).time_between(0x81AE, 0x81AE)
    first = cpu.log.index("wait_for_stop")
    need("run" not in cpu.log[:first], f"start stop dropped: run before the first wait: {cpu.log[:first + 1]}")
    need(got == [(1, 0)], f"time_between {got}")
    # M3 / M4: a breakpoint hit before the pause lands stays stopped; a plain pause is undone
    for hit, want_run in ((0x9000, False), (None, True)):
        for what, act in (("ay_regs", lambda s: s.ay_regs(0)), ("read_page 11", lambda s: s.read_page(11, 0, 16))):
            cpu = FakeCpu(bps=[0x9000] if hit else [], hit_before_pause=hit)
            with fake_cpu_server(cpu) as srv:
                act(cpu.session(srv))
            ran = "run" in cpu.log[cpu.log.index("pause"):]
            need(ran == want_run, f"{what}, breakpoint hit before the pause {hit}: resumed {ran}: {cpu.log}")
            need(cpu.running == want_run, f"{what}: CPU left {'running' if cpu.running else 'stopped'}")
    cpu = FakeCpu()
    with fake_cpu_server(cpu) as srv:
        cpu.session(srv).read_page(11, 0, 16)
    order = [cpu.log.index(n) for n in ("pause", "read_next_registers", "read_memory", "run")]
    need(order == sorted(order), f"bank 5 check and read not inside one pause: {cpu.log}")
    # R1: stopped_at only at an armed breakpoint; M2: no stale screenshot while stopped
    for cpu, want in ((FakeCpu(running=False, pc=0x9CB2, bps=[0x9CB2]), 0x9CB2),
                      (FakeCpu(running=False, pc=0x8000), None), (FakeCpu(), None)):
        with fake_cpu_server(cpu) as srv:
            s = cpu.session(srv)
            got = s.stopped_at()
            if not cpu.running:
                e = raises(client.CSpectError, s.screenshot)
                need("advance" in str(e), f"stopped screenshot error: {e}")
        need(got == want, f"stopped_at at ${cpu.pc:04X} (armed {cpu.bps}) = {got}, wanted {want}")


class FakeMemCpu(FakeCpu):
    """FakeCpu with a physical memory image for read_memory / write_memory physical=true."""

    def __init__(self, image, **kw):
        super().__init__(**kw)
        self.mem, self.writes = dict(image), []

    def call(self, name, a):
        if name not in ("read_memory", "write_memory") or not a.get("physical"):
            return super().call(name, a)
        self.log.append(name)
        addr = int(a["address"][1:], 16)
        if name == "write_memory":
            data = bytes.fromhex(a["data"])
            self.writes.append((addr, data))
            self.mem.update((addr + i, b) for i, b in enumerate(data))
            return f"Wrote {len(data)} bytes"
        data = bytes(self.mem.get(addr + i, 0) for i in range(a["length"]))
        return "\r\n".join(f"${addr + i:05X}  " + " ".join(f"{b:02X}" for b in data[i:i + 16])
                           for i in range(0, len(data), 16))


# mouse_poll, h_mouse.reset and input_scan as assembled (build/nextdaad.nex, build/intro.nex)
MOUSE_CODE = {"MOUSE_POLL": (0xF311, 0x71311, "01dffaed7832eef301dffbed784f3af1f3b7280b7921eff396"
                                              "71cd57f3180479" "32eff301dfffed784f"),
              "H_MOUSE@RESET": (0xF1E3, 0x711E3, "21a00022e9f33e8032ebf3af32eef332ecf332edf301dffbed"
                                                 "7832eff301dfffed7832f0f33e0132f1f3c9"),
              "INPUT_SCAN": (0x82A6, 0x82A6, "01fe00ed782fe61f5fdb1fe610b35f01dffaed782fe603b3c9")}


def mouse_image(names, change=None):
    """(symbol table, physical image) for MOUSE_CODE entries; change=(name, index, byte)."""
    syms, image = {}, {}
    for n in names:
        v, p, code = MOUSE_CODE[n]
        data = bytearray(bytes.fromhex(code))
        if change and change[0] == n:
            data[change[1]] = change[2]
        syms[n] = (v, p, 0)
        image.update((p + i, b) for i, b in enumerate(data))
    return syms, image


def t_session_mouse_pins():
    need_session()
    names = list(MOUSE_CODE)
    syms, image = mouse_image(names)
    cpu = FakeMemCpu(image, running=False)
    with fake_cpu_server(cpu) as srv:
        pins = Session(client.Mcp(srv.port), syms).pin_mouse()
    want = {("MOUSE_POLL", 0xFADF, 0x71311 + 3), ("MOUSE_POLL", 0xFBDF, 0x71311 + 11),
            ("MOUSE_POLL", 0xFFDF, 0x71311 + 38), ("H_MOUSE@RESET", 0xFBDF, 0x711E3 + 24),
            ("H_MOUSE@RESET", 0xFFDF, 0x711E3 + 32), ("INPUT_SCAN", 0xFADF, 0x82A6 + 18)}
    need(set(pins) == want and len(pins) == 6, f"pins {pins}")
    for _, port, at in pins:
        got = bytes((cpu.mem[at], cpu.mem[at + 1]))
        need(got == bytes((0x3E, session.MOUSE_PORTS[port])), f"${at:05X} holds {got.hex()} for ${port:04X}")
    changed = {a for a, _ in image.items() if cpu.mem[a] != image[a]}
    need(changed == {at + k for _, _, at in pins for k in (0, 1)}, f"bytes changed outside the pins: {sorted(changed)}")
    need(session.MOUSE_PORTS == {0xFADF: 0xFF, 0xFBDF: 0x00, 0xFFDF: 0x00}, f"pin values {session.MOUSE_PORTS}")
    cpu = FakeMemCpu({}, running=False)
    with fake_cpu_server(cpu) as srv:
        none = Session(client.Mcp(srv.port), {"FRAMECOUNTER": (0xA0, 0xA0, 0)}).pin_mouse()
    need(none == [] and "read_memory" not in cpu.log, f"map without mouse reads: {none}, calls {cpu.log}")
    syms, image = mouse_image(["MOUSE_POLL"], change=("MOUSE_POLL", 9, 0xDE))       # ld bc,$FADE
    cpu = FakeMemCpu(image, running=False)
    with fake_cpu_server(cpu) as srv:
        e = raises(client.CSpectError, Session(client.Mcp(srv.port), syms).pin_mouse)
    need("MOUSE_POLL" in str(e) and "$FBDF" in str(e) and not any(
        a == 0x71311 + 11 for a, _ in cpu.writes), f"changed image: {e}; writes {cpu.writes}")
    # boot: pinned at the -debug entry before anything runs, then resumed unless paused
    orig = launcher.launch
    try:
        with tempfile.TemporaryDirectory() as d:
            mp = Path(d) / "x.map"
            mp.write_text("".join(f"{v:08X} {p:08X} 00 {n}\n" for n, (v, p, _) in MOUSE_CODE.items()),
                          encoding="ascii")
            for kw, debug, ran in (({}, True, True), ({"paused": True}, True, False),
                                   ({"pin_mouse": False}, False, False)):
                syms, image = mouse_image(names)
                cpu = FakeMemCpu(image, running=False)
                with fake_cpu_server(cpu) as srv:
                    seen = {}

                    class Inst:
                        mcp, pid = client.Mcp(srv.port), 0

                        def close(self):
                            pass
                    launcher.launch = lambda *a, **k: (seen.update(k), Inst())[1]
                    s = Session.boot(d, mp, mp, **kw)
                need(("-debug" in seen["extra"]) == debug, f"boot {kw}: extra {seen['extra']}")
                need(len(s.mouse_pins) == (6 if debug else 0), f"boot {kw}: {len(s.mouse_pins)} pins")
                need(("run" in cpu.log) == ran, f"boot {kw}: calls {cpu.log}")
                if ran:
                    need(cpu.log.index("run") > max(i for i, n in enumerate(cpu.log) if n == "write_memory"),
                         f"boot resumed before pinning: {cpu.log}")
    finally:
        launcher.launch = orig
    return "6 reads pinned (overlay0 page 56, intro page 4), nothing else written; changed bytes refused; boot pins at the entry"


def t_session_keys():
    need_session()
    cpu = FakeCpu()
    with fake_cpu_server(cpu) as srv:
        s = cpu.session(srv)
        got = s.press("O O+K O", 8, gap=0)
        s.press("SPACE", 4)
        e = raises(client.CSpectError, s.queue_press, "ENTER")
        need("stopped" in str(e), f"queue_press while running: {e}")
    need(cpu.keys[:1] == [{"keys": "O O+K O", "hold_frames": 8, "gap_frames": 0}], f"press gap=0 sent {cpu.keys[:1]}")
    need(cpu.keys[1:] == [{"keys": "SPACE", "hold_frames": 4}], f"press without gap sent {cpu.keys[1:]}")
    need(got == 24, f"press returned {got}, wanted the reply's 24 frames")
    cpu = FakeCpu(running=False)
    with fake_cpu_server(cpu) as srv:
        s = cpu.session(srv)
        raises(client.CSpectError, s.press, "SPACE")
        need(s.queue_press("SPACE", 4) is None, "queue_press returned a value")
        cpu.keys_reply = "Keys done (7 frames)"
        e = raises(client.CSpectError, s.queue_press, "ENTER", gap=0)
        need("press_keys" in str(e) and "Keys done" in str(e), f"unqueued reply error: {e}")
    need(cpu.keys == [{"keys": "SPACE", "hold_frames": 4}, {"keys": "ENTER", "gap_frames": 0}],
         f"stopped-CPU press_keys calls {cpu.keys}")
    return "press passes hold/gap as asked; queue_press refuses a running CPU and needs 'Keys queued'"


# -- session live checks (DEBUG build, sd\SUITE) --------------------------------------------------

SCRATCH = 0x5710              # dead ULA pixels between CYC_DBG_SNAP's 16 bytes at $5600 and $5800
SCRATCH_PAGE = 95             # upper 8K of bank 47: DEBUG reserves the bank and uses page 94 only


def live_session(**kw):
    need_session()
    need_staged()
    s = Session.boot(CARD, NEX, MAP, **kw)
    try:
        STARTED.append(Held(s.pid))
    except BaseException:
        s.close()
        raise
    return s


SUITE_TITLE = "NEXTDAAD CONDACT SUITE"


def booted(s, seconds=30):
    """Non-blank rows once the SUITE title is up (bank 5 holds junk before txt_init)."""
    return s.wait_until(lambda: (lambda r: [x.rstrip() for x in r if x.strip()]
                                 if any(SUITE_TITLE in x for x in r) else None)(s.rows()),
                        seconds, what=f"{SUITE_TITLE!r} on the tilemap")


def at_prompt(rows):
    lines = [r.rstrip() for r in rows if r.strip()]
    return bool(lines) and lines[-1].endswith(">")


def settle(s, frames=10, seconds=20):
    """Tilemap rows once two reads frames apart agree."""
    prev, deadline = s.rows(), time.monotonic() + seconds
    while True:
        s.wait_frames(frames, seconds)
        cur = s.rows()
        if cur == prev:
            return cur
        need(time.monotonic() < deadline, f"screen still changing after {seconds} s")
        prev = cur


def suite_to_prompt(s):
    """From boot to check 51's prompt: SYM dismisses More..., QUIT gets Y + ENTER."""
    quit_done, deadline = False, time.monotonic() + 120
    while True:
        need(time.monotonic() < deadline, "never reached check 51's prompt")
        rows = s.rows()
        if any("More..." in r for r in rows):
            s.press("SYM")
            s.wait_until(lambda: s.rows() != rows, 5, what="the More... page to change after SYM")
            continue
        text = "\n".join(rows)
        if not quit_done and "Are you sure?" in text:
            s.type_text("Y")
            s.enter()
            quit_done = True
            continue
        if "51 TYPE: get lamp" in text and "52 TYPE" not in text and at_prompt(rows):
            rows = settle(s)
            if at_prompt(rows):
                return rows
        s.wait_frames(2, 10)


def l_boot_rows():
    with live_session() as s:
        rows = booted(s)
    return f"{len(rows)} rows, first {rows[0].strip()!r}"


def l_mouse_pins():
    with live_session() as s:
        pins, running = list(s.mouse_pins), s.running()
        held = [s.read_page(p >> 13, p & 0x1FFF, 2) for _, _, p in pins]
    with live_session(pin_mouse=False) as s:
        raw = [s.read_page(p >> 13, p & 0x1FFF, 2) for _, _, p in pins]
    need(len(pins) == 5 and {n for n, _, _ in pins} == {"MOUSE_POLL", "H_MOUSE@RESET"}, f"pins {pins}")
    need(held == [bytes((0x3E, session.MOUSE_PORTS[port])) for _, port, _ in pins], f"pinned bytes {held}")
    need(raw == [b"\xed\x78"] * 5, f"pin_mouse=False boot holds {raw}, wanted in a,(c) at each")
    need(running, "boot left the CPU stopped after pinning")
    return f"{len(pins)} reads pinned at physical {', '.join(f'${p:05X}' for _, _, p in pins)}; opt-out leaves in a,(c)"


def l_symbols():
    want = client.read_map(MAP)["FLAGS"][0]
    with live_session() as s:
        got, low = s.sym("FLAGS"), s.sym("flags")
        e = raises(KeyError, s.sym, "NO_SUCH_SYMBOL")
        ev = s.mcp.text(s.mcp.call("evaluate", expression="FLAGS"))
    need(got == low == want, f"sym FLAGS ${got:04X} / flags ${low:04X}, map ${want:04X}")
    need("NO_SUCH_SYMBOL" in str(e), f"KeyError does not name the symbol: {e}")
    need(f"${want:04X}" in ev, f"CSpect's own map has FLAGS elsewhere: {ev!r}")
    return f"FLAGS ${got:04X} (CSpect evaluate agrees)"


def l_mem_roundtrip():
    pat = bytes(range(0xA0, 0xB0))
    with live_session() as s:
        booted(s)
        old = s.read(SCRATCH, 16)
        s.write(SCRATCH, pat)
        got64 = s.read(SCRATCH, 16)
        s.write(SCRATCH, old)
        oldp = s.read_page(SCRATCH_PAGE, 0x1F00, 16)
        s.write_page(SCRATCH_PAGE, 0x1F00, pat[::-1])
        gotp = s.read_page(SCRATCH_PAGE, 0x1F00, 16)
        s.write_page(SCRATCH_PAGE, 0x1F00, oldp)
        s.write_page(10, SCRATCH - 0x4000, pat)          # bank 5 page 10 through the 64K view
        got5 = s.read(SCRATCH, 16)
        back5 = s.read_page(10, SCRATCH - 0x4000, 16)
        s.write(SCRATCH, old)
        s.pause()
        p7 = s.next_regs([0x57])[0x57]
        slot7 = (s.read_page(p7, 0, 512), s.read(0xE000, 512))
        tm = (s.read_page(11, 0, 320), s.read(0x6000, 320))
        s.resume()
    need(got64 == pat, f"64K ${SCRATCH:04X}: wrote {pat.hex()}, read {got64.hex()}")
    need(gotp == pat[::-1], f"page {SCRATCH_PAGE}: wrote {pat[::-1].hex()}, read {gotp.hex()}")
    need(got5 == back5 == pat, f"page 10 write read back {got5.hex()} / {back5.hex()}")
    need(slot7[0] == slot7[1], f"physical page {p7} differs from the 64K view of slot 7")
    need(tm[0] == tm[1], "read_page(11) differs from the tilemap at $6000")
    return f"64K ${SCRATCH:04X}, page {SCRATCH_PAGE}, bank 5 page 10, physical page {p7} = slot 7"


def l_flags_frame():
    with live_session() as s:
        booted(s)
        fl = s.flags()
        need(len(fl) == 256, f"flags() gave {len(fl)} bytes")
        f0 = s.frame()
        f1 = s.wait_until(lambda: (lambda f: f if f != f0 else None)(s.frame()), 5,
                          what="FRAMECOUNTER to move")
    return f"FRAMECOUNTER {f0} -> {f1}"


def l_wait_frames_both_speeds():
    notes = []
    for freerun in (True, False):
        with live_session(freerun=freerun) as s:
            booted(s)
            f0, t0 = s.frame(), time.monotonic()
            seen = s.wait_frames(50, 30)
            moved, dt = (s.frame() - f0) & 0xFFFF, time.monotonic() - t0
        need(seen >= 50 and moved >= 50, f"freerun={freerun}: wait_frames saw {seen}, counter moved {moved}")
        notes.append(f"freerun={freerun}: {moved} frames in {dt:.2f} s")
    return "; ".join(notes)


def l_paused_boot_brk():
    seed = client.read_map(MAP)["ENG_INIT_GAME@SEEDOK"][0]
    with live_session(paused=True) as s:
        entry, at0, run0 = s.regs()["PC"], s.stopped_at(), s.running()
        pc = s.run_to("ENG_INIT_GAME@SEEDOK", 20)
        at1 = s.stopped_at()
        main = s.sym("MAIN")
        s.resume()
        booted(s)
    need(entry == main and not run0, f"paused boot at PC ${entry:04X} running {run0}, not stopped at MAIN")
    need(at0 is None, f"stopped_at() at the -debug entry (no breakpoint) = {at0}, wanted None")
    need(pc == at1 == seed, f"run_to returned {pc}, stopped_at {at1}, wanted ${seed:04X}")
    with live_session(brk="ENG_INIT_GAME@SEEDOK") as s:
        at2 = s.stopped_at()
        s.step()
        at3 = s.stopped_at()
        s.resume()
        booted(s)
        s.pause()
        at4 = s.stopped_at()
        s.resume()
    need(at2 == seed, f"brk boot stopped_at {at2}, wanted ${seed:04X}")
    need(at3 is None and at4 is None, f"stopped_at after a step {at3}, after a pause {at4}, wanted None")
    return (f"-debug entry PC ${main:04X} (stopped_at None), run_to and +brk at SEEDOK ${seed:04X}; "
            f"step and pause give None")


def l_regs_step():
    with live_session(brk="ENG_INIT_GAME@SEEDOK") as s:
        seed, rng = s.sym("ENG_INIT_GAME@SEEDOK"), s.sym("RNGSTATE")
        s.write(rng, b"\0\0")
        s.set_regs(HL=0x1234)
        hl = s.regs()["HL"]
        s.set_regs(**{"BC'": 0xBEEF})
        alt = s.regs()["BC'"]
        pc = s.step()
        stored = int.from_bytes(s.read(rng, 2), "little")
        s.resume()
        e = raises(client.CSpectError, s.set_regs, HL=1)
    need(hl == 0x1234 and alt == 0xBEEF, f"HL ${hl:04X}, BC' ${alt:04X}")
    need(pc == seed + 3 and stored == 0x1234, f"step -> PC ${pc:04X}, RNGSTATE ${stored:04X}")
    need("pause" in str(e), f"set_regs while running: {e}")
    return "HL := $1234, step stored it at RNGSTATE"


def l_next_regs():
    with live_session() as s:
        got = s.next_regs([0x00, 0x01])
    need(got == {0: 8, 1: 0x40}, f"next_regs([0, 1]) = {got}")
    with live_session(major=0x33, minor=3) as s:
        core = s.next_regs([0x01, 0x0E])
        rows = booted(s)
    need(core == {0x01: 0x33, 0x0E: 3}, f"major/minor boot NR {core}")
    return f"{got}; -major=51 -minor=3 boots core 3.03.03 ({rows[0].strip()[:30]!r})"


AY_PROBE_REGS = (0, 2, 4, 11)     # 8-bit tone fine A-C and envelope period: silent with R8-R10 at 0


AY_MARKS = {(c, r): 0x41 + 0x10 * c + r for c in range(3) for r in AY_PROBE_REGS}


def ay_rw(s, chip, r, value=None):
    """Select PSG chip register r through $FFFD; write value to $BFFD if given; read it back."""
    s.port_out(0xFFFD, session.AY_SELECTS[chip])
    s.port_out(0xFFFD, r)
    if value is not None:
        s.port_out(0xBFFD, value)
    return s.port_in(0xFFFD)


def ay_write(s, values):
    """{(chip, reg): value} written, then the frame-end select (PSG 3 R13) restored."""
    for (c, r), v in values.items():
        ay_rw(s, c, r, v)
    s.port_out(0xFFFD, session.AY_SELECTS[session.AY_FRAME_END[0]])
    s.port_out(0xFFFD, session.AY_FRAME_END[1])


def l_port_io():
    with live_session() as s:
        booted(s)
        s.pause()
        old = {k: ay_rw(s, *k) for k in (*AY_MARKS, *((c, r) for c in range(3) for r in (7, 8)))}
        ay_write(s, AY_MARKS)
        got = {k: ay_rw(s, *k) for k in AY_MARKS}
        ay_write(s, {k: old[k] for k in AY_MARKS})
        back = {k: ay_rw(s, *k) for k in AY_MARKS}
        ay_write(s, {})
        s.resume()
        booted(s)
    bad = [f"PSG{c + 1} R{r} {v:02X}" for (c, r), v in got.items() if v != AY_MARKS[(c, r)]]
    need(not bad, "written values not read back: " + ", ".join(bad))
    need(all(back[k] == old[k] for k in back), f"restore failed: {back} vs {old}")
    idle = [old[(c, 7)] == 0x3F and old[(c, 8)] == 0 for c in range(3)]
    need(all(idle), f"PSG R7/R8 {[(old[(c, 7)], old[(c, 8)]) for c in range(3)]}, wanted audio_init's $3F/0")
    return (f"{len(got)} registers written by OUT $BFFD read back by IN $FFFD on 3 PSGs; "
            f"R7 $3F / R8 0 (audio_init) on each; old values restored")


def l_ay_regs():
    with live_session() as s:
        booted(s)
        s.pause()
        base = [s.ay_regs(c) for c in range(3)]
        ay_write(s, AY_MARKS)
        marked = [s.ay_regs(c) for c in range(3)]
        ay_write(s, {(c, r): base[c][r] for c, r in AY_MARKS})
        kept = not s.running()
        s.resume()
        live = [s.ay_regs(c) for c in range(3)]
        running = s.running()
    for c in range(3):
        want = bytearray(base[c])
        for r in AY_PROBE_REGS:
            want[r] = AY_MARKS[(c, r)]
        need(marked[c] == want, f"PSG{c + 1} {marked[c].hex()} after writes, wanted {want.hex()}")
        need(base[c][7] == 0x3F, f"PSG{c + 1} R7 ${base[c][7]:02X}, wanted audio_init's $3F")
    need(kept and running, f"CPU state not kept: paused stays paused {kept}, running stays running {running}")
    need(live == base, f"running reads {[x.hex() for x in live]} vs paused {[x.hex() for x in base]}")
    return "PSG 1-3 R0-R13 show the values written; paused and running states kept"


def l_type_enter():
    with live_session() as s:
        suite_to_prompt(s)
        s.type_text("LOOK")
        s.enter()
        rows = s.wait_until(lambda: (lambda r: r if any("52 TYPE" in x for x in r) else None)(s.rows()), 15,
                            what="the answer to LOOK")
    text = [r.rstrip() for r in rows if r.strip()]
    i = next((n for n, r in enumerate(text) if "LOOK" in r.upper()), None)
    need(i is not None, "typed LOOK not echoed: " + " | ".join(text[-6:]))
    need(any("51 F" in r for r in text[i:]), "no '51 F' after LOOK: " + " | ".join(text[-6:]))
    return " | ".join(text[i:i + 3])


def set_next_regs(s, values):
    """{NR: value} written while paused, each read back by next_regs."""
    s.pause()
    for n, v in values.items():
        s.set_next_reg(n, v)
    s.resume()
    got = s.next_regs(list(values))
    need(got == values, f"next_regs after set_next_reg {got}, wanted {values}")


def l_screenshot_border():
    with live_session() as s:
        booted(s)
        img = s.screenshot()
        fixture = s.border_index()
        nr = s.next_regs([0x68, 0x6B])
        set_next_regs(s, {0x68: 0x00, 0x6B: nr[0x6B] & 0x7F})         # ULA on, tilemap off
        s.port_out(0x00FE, 2)
        s.wait_frames(3, 10)
        red = s.border_index()
        set_next_regs(s, nr)
        s.port_out(0x00FE, 0)
        s.wait_frames(3, 10)
        back = s.border_index()
    need(img.size == (320, 256), f"screenshot {img.size}")
    need(fixture == 0, f"SUITE border band read as index {fixture}, wanted 0 (black tilemap paper)")
    need(red == 2, f"ULA border 2 read as index {red}")
    need(back == 0, f"border band {back} after NR $68/$6B restored")
    return "SUITE border 0; ULA border 2 (tilemap off, ULA on) read as 2; registers restored"


def l_screenshot_paused():
    with live_session() as s:
        s.wait_until(lambda: any("More..." in r for r in s.rows()), 30, what="the first More... page")
        settle(s)
        before = s.screenshot()
        row1, attr = s.read(0x6000 + 160, 160), s.read(0x6000, 2)[1]    # the title's visible attribute
        s.pause()
        s.write(0x6000 + 160, bytes(b for ch in b"PAUSED SHOT " * 7 for b in (ch, attr))[:160])
        e = raises(client.CSpectError, s.screenshot)
        shot = s.screenshot(advance=True)
        stopped = not s.running()
        s.write(0x6000 + 160, row1)
        s.resume()
    from PIL import ImageChops
    changed = [r for r in range(32) if ImageChops.difference(before, shot).crop((0, 8 * r, 320, 8 * r + 8)).getbbox()]
    need("advance" in str(e), f"stopped screenshot error: {e}")
    need(changed == [1], f"advance=True screenshot changed rows {changed}, wanted [1]")
    need(stopped, "CPU not stopped again after screenshot(advance=True)")
    return "stopped screenshot refused; advance=True shows the row written while paused, CPU stopped after"


def l_diff_bytes_image():
    with live_session() as s:
        s.wait_until(lambda: any("More..." in r for r in s.rows()), 30, what="the first More... page")
        settle(s)
        row0 = s.read(0x6000, 160)
        same = s.diff_bytes(row0, addr=0x6000)
        alt = bytearray(row0)
        alt[7] ^= 0x5A
        one = s.diff_bytes(bytes(alt), addr=0x6000)
        paged = s.diff_bytes(row0, page=11, offset=0)
        box = (0, 0, 160, 8)
        img = s.screenshot().crop(box)
        zero = s.diff_image(img, box)
        px = img.copy()
        px.putpixel((3, 3), tuple(255 - c for c in img.getpixel((3, 3))))
        onepx = s.diff_image(px, box)
    need(same == [] and paged == [], f"diff against its own read: {same[:4]} / page 11 {paged[:4]}")
    need(one == [(7, row0[7], alt[7])], f"one changed byte gave {one}")
    need(zero == 0 and onepx == 1, f"image box diff {zero} then {onepx} after one pixel")
    return "bytes (64K and page 11) and image box"


def raster_walk(s):
    """From a stop at the frame interrupt, step until the raster wraps: (lines seen, max line)."""
    lines = [s.raster_line()]
    for _ in range(400):
        s.step(500 if lines[-1] < session.LINES_PER_FRAME - 12 else 40)   # fine steps near the wrap
        lines.append(s.raster_line())
        if lines[-1] < lines[-2]:
            return lines, lines[-2]
    raise CheckFailed(f"raster never wrapped: {lines[-8:]}")


def l_time_between():
    with live_session(paused=True) as s:
        boot = s.time_between("RAM_DETECT", "ENG_INIT_GAME")
        s.wait_until(lambda: any("More..." in r for r in s.rows()), 30, what="the first More... page")
        tick = (s.run_to("IM2_ISR", 5), s.raster_line())     # mainline idles in a key poll loop
        lines, top = raster_walk(s)
        s.resume()
        resumes, plain = [], s.resume
        s.resume = lambda: (resumes.append(s.frame()), plain())[1]
        isr = s.time_between("IM2_ISR", "IM2_ISR", runs=2)
        running = s.running()
    tick_line = session.FRAME_TICK_LINE
    need(len(boot) == 1 and boot[0][0] >= 0 and 0 <= boot[0][1] <= 311, f"boot path {boot}")
    need(tick[1] == tick_line, f"stop at IM2_ISR ${tick[0]:04X} reads raster line {tick[1]}, wanted {tick_line}")
    steps = [b - a for a, b in zip(lines, lines[1:-1])]
    need(all(0 <= d <= 8 for d in steps) and any(steps), f"raster while stepping {lines}")
    need(any(256 <= x for x in lines) and top == session.LINES_PER_FRAME - 1 and lines[-1] <= 1,
         f"raster walk {lines[0]}..{top} then {lines[-1]}: wanted lines past 255, last {session.LINES_PER_FRAME - 1}, wrap to 0")
    need(isr == [(1, 0), (1, 0)], f"frame interrupt to frame interrupt {isr}, wanted one frame each")
    need(len(resumes) == 4, f"{len(resumes)} resumes for two runs from a running CPU (frames {resumes}), wanted 4")
    need(running, "CPU not running after time_between")
    return (f"RAM_DETECT -> ENG_INIT_GAME {boot[0]}; IM2_ISR stop at line {tick[1]}; stepping "
            f"{lines[0]}..{top} -> {lines[-1]} in {len(lines)} samples; IM2_ISR -> IM2_ISR {isr}, {len(resumes)} resumes")


HOST = [t_parse_dump_ok, t_dump_rejects_gap, t_read_map, t_reply_sse_and_plain, t_tools_reply_checked,
        t_garbage_listener, t_status_without_pc_raises, t_required_tools_checked, t_version_gate,
        t_port_choice, t_private_copy_excludes, t_job_kills_child, t_mutex_serialises,
        t_mutex_release_checked, t_close_keeps_mutex, t_listener_owner, t_no_answer_names_causes,
        t_fallback_runs, t_guard_parser, t_session_status, t_session_fake_mcp, t_session_boot_args,
        t_session_raster, t_session_border_index, t_session_wait_until, t_session_symbols,
        t_session_stop_races, t_session_keys, t_session_mouse_pins]
LIVE = [l_launch_tools_close, l_private_copy_mcp, l_no_port_11000, l_window_minimised,
        l_parent_killed, l_exception_closes, l_foreign_untouched, l_guard_narrowed, l_boot_rows,
        l_mouse_pins, l_symbols, l_mem_roundtrip, l_flags_frame, l_wait_frames_both_speeds, l_paused_boot_brk,
        l_regs_step, l_next_regs, l_port_io, l_ay_regs, l_type_enter, l_screenshot_border,
        l_screenshot_paused, l_diff_bytes_image, l_time_between]


def run(checks, names):
    fails = 0
    for check in checks:
        if names and check.__name__ not in names:
            continue
        try:
            if IMPORT_ERROR is not None:
                raise CheckFailed(f"cspect modules missing: {IMPORT_ERROR}")
            note = check()
        except Exception as e:
            fails += 1
            kind = "" if isinstance(e, CheckFailed) else type(e).__name__ + ": "
            print(f"FAIL {check.__name__}: {kind}{e}", flush=True)
        else:
            print(f"PASS {check.__name__}" + (f" - {note}" if note else ""), flush=True)
    return fails


def main(argv):
    if not argv or argv[0] not in ("--host", "--live"):
        print(__doc__)
        return 2
    checks = HOST if argv[0] == "--host" else LIVE
    names = set(argv[1:])
    unknown = names - {c.__name__ for c in checks}
    if unknown:
        print(f"unknown checks: {sorted(unknown)}")
        return 2
    if checks is LIVE or launcher is None:
        fails = run(checks, names)
    else:
        # host checks never share the real mutex, console logs or a live harness's state
        with tempfile.TemporaryDirectory(prefix="cspect-selftest-") as d:
            launcher.MUTEX_NAME = rf"Local\NextDAADCSpectSelftest{os.getpid()}"
            launcher.HARNESS_DIR = Path(d)
            fails = run(checks, names)
    if STARTED:
        left = [h.pid for h in STARTED if h.alive()]
        for h in STARTED:
            h.kill()
            h.close()
        print(f"CSpect PIDs started: {[h.pid for h in STARTED]}; still alive: {left or 'none'}")
        fails += bool(left)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
