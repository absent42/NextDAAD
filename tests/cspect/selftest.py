"""python tests/cspect/selftest.py --host [name ...]   no emulator
python tests/cspect/selftest.py --live [name ...]   CSpect through the launcher
Prints PASS name / FAIL name: why; exit 1 on any FAIL."""
import ctypes
import http.server
import json
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


def live_launch(**kw):
    for p in (CARD / "GAME.DDB", NEX, MAP):
        need(p.is_file(), f"{p} missing: run .\\build.ps1 and tests\\build-tests.ps1 -Suite")
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


HOST = [t_parse_dump_ok, t_dump_rejects_gap, t_read_map, t_reply_sse_and_plain, t_tools_reply_checked,
        t_garbage_listener, t_status_without_pc_raises, t_required_tools_checked, t_version_gate,
        t_port_choice, t_private_copy_excludes, t_job_kills_child, t_mutex_serialises,
        t_mutex_release_checked, t_close_keeps_mutex, t_listener_owner, t_no_answer_names_causes,
        t_fallback_runs, t_guard_parser]
LIVE = [l_launch_tools_close, l_private_copy_mcp, l_no_port_11000, l_window_minimised,
        l_parent_killed, l_exception_closes, l_foreign_untouched, l_guard_narrowed]


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
