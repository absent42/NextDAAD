"""python tests/cspect/selftest.py --host [name ...]   no emulator
python tests/cspect/selftest.py --live [name ...]   CSpect through the launcher
Prints PASS name / FAIL name: why; exit 1 on any FAIL."""
import http.server
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
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


def ok_json(req, result):
    return json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": result})


def text_result(text):
    return {"content": [{"type": "text", "text": text}]}


def wait_gone(pid, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not launcher.pid_alive(pid):
            return True
        time.sleep(0.1)
    return not launcher.pid_alive(pid)


def kill_pid(pid):
    """Clean-up for a PID this check started (directly or through its helper)."""
    if pid and launcher.pid_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


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


def t_read_map():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.map"
        p.write_text("0000A200 0000A200 00 flags\n"
                     "0000C010 0005C010 00 ovlEntry\n"
                     "00000008 00000008 01 AKY_RET_GUARD\n", encoding="ascii")
        got = client.read_map(p)
    want = {"FLAGS": (0xA200, 0xA200, 0), "OVLENTRY": (0xC010, 0x5C010, 0),
            "AKY_RET_GUARD": (8, 8, 1)}
    need(got == want, f"got {got}")


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
    first = launcher.PORT_RANGE[0]
    with FakeMcp(lambda req: ({}, ok_json(req, {"protocolVersion": "2025-03-26"})), port=first):
        got = launcher.choose_port()
        need(got == first + 1, f"automatic choice gave {got}, wanted {first + 1}")
        e = raises(launcher.LaunchError, launcher.choose_port, first)
        need(str(first) in str(e), f"error does not name the port: {e}")
    raises(launcher.LaunchError, launcher.choose_port, 23456)


def t_private_copy_excludes():
    saved = launcher.PRIVATE_DIR
    with tempfile.TemporaryDirectory() as d:
        src, dest = Path(d) / "src", Path(d) / "copy"
        src.mkdir()
        for name in ("CSpect.exe", "zxnext.mmc", "DeZogPlugin.dll", "MCP.dll"):
            (src / name).write_bytes(name.encode())
        launcher.PRIVATE_DIR = dest
        try:
            got = launcher.private_copy(src)
            need(got == dest, f"returned {got}")
            names = sorted(p.name for p in dest.iterdir())
            need(names == ["CSpect.exe", "MCP.dll"], f"copy holds {names}")

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
        child = int(helper.stdout.readline())
        need(launcher.pid_alive(child), "child not running before the helper was killed")
        helper.kill()
        helper.wait(10)
        need(wait_gone(child, 5), f"child PID {child} still alive 5 s after its helper was killed")
    finally:
        helper.kill()
        kill_pid(child)


MUTEX_HOLDER = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from cspect import launcher
m = launcher.Mutex.acquire(wait=5)
print("held", flush=True)
time.sleep(60)
"""

MUTEX_WAITER = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
from cspect import launcher
t = time.monotonic()
try:
    launcher.launch(sys.argv[2], sys.argv[3])
    print("LAUNCHED")
except launcher.LaunchError as e:
    print("ERR %.2f %s" % (time.monotonic() - t, e))
"""


def t_mutex_serialises():
    holder = subprocess.Popen([sys.executable, "-c", MUTEX_HOLDER, str(TESTS)],
                              stdout=subprocess.PIPE, text=True)
    try:
        need(holder.stdout.readline().strip() == "held", "holder did not take the mutex")
        env = dict(os.environ, NEXTDAAD_CSPECT_WAIT="2")
        out = subprocess.run([sys.executable, "-c", MUTEX_WAITER, str(TESTS), str(HERE), __file__],
                             env=env, capture_output=True, text=True, timeout=30).stdout.strip()
        m = re.match(r"ERR (\d+\.\d+) (.*)", out)
        need(m, f"waiter output {out!r}")
        need(launcher.MUTEX_NAME in m.group(2), f"error does not name the mutex: {m.group(2)}")
        need(2.0 <= float(m.group(1)) <= 4.0, f"waited {m.group(1)} s, wanted 2-4")
    finally:
        holder.kill()
        holder.wait(10)


def t_no_answer_names_causes():
    saved = launcher._TEST_COMMAND
    launcher._TEST_COMMAND = [sys.executable, "-c", "import time; time.sleep(60)"]
    try:
        e = raises(launcher.LaunchError, launcher.launch, HERE, __file__, start_timeout=2)
    finally:
        launcher._TEST_COMMAND = saved
    text = str(e)
    for want in ("older than 4.3", "MCP.dll", "MCP tier"):
        need(want in text, f"error does not name {want!r}: {text}")
    pids = [int(p) for p in re.findall(r"PID (\d+)", text)]
    need(pids, f"error names no PID: {text}")
    need(not any(launcher.pid_alive(p) for p in pids), f"stand-in still alive: {pids}")


# -- live checks (DEBUG build\nextdaad.nex from build.ps1, card sd\SUITE from build-tests -Suite) --

CARD = ROOT / "sd" / "SUITE"
NEX = ROOT / "build" / "nextdaad.nex"
MAP = ROOT / "build" / "nextdaad.map"
STARTED = []                 # every CSpect PID the live checks started


def live_launch(**kw):
    for p in (CARD / "GAME.DDB", NEX, MAP):
        need(p.is_file(), f"{p} missing: run .\\build.ps1 and tests\\build-tests.ps1 -Suite")
    inst = launcher.launch(CARD, NEX, MAP, **kw)
    STARTED.append(inst.pid)
    return inst


def _user32():
    import ctypes
    from ctypes import wintypes as w
    u32 = ctypes.WinDLL("user32")
    for name, res, args in (("GetWindowThreadProcessId", w.DWORD, (w.HWND, ctypes.POINTER(w.DWORD))),
                            ("IsWindowVisible", w.BOOL, (w.HWND,)), ("IsIconic", w.BOOL, (w.HWND,)),
                            ("GetWindow", w.HWND, (w.HWND, w.UINT)),
                            ("GetWindowTextW", ctypes.c_int, (w.HWND, w.LPWSTR, ctypes.c_int)),
                            ("GetForegroundWindow", w.HWND, ())):
        getattr(u32, name).restype, getattr(u32, name).argtypes = res, args
    return ctypes, w, u32


def top_windows(pid):
    """[(hwnd, title, iconic)] for pid's visible unowned top-level windows."""
    ctypes, w, u32 = _user32()
    found = []

    def each(hwnd, _):
        owner = w.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and u32.IsWindowVisible(hwnd) and not u32.GetWindow(hwnd, 4):  # GW_OWNER
            title = ctypes.create_unicode_buffer(256)
            u32.GetWindowTextW(hwnd, title, 256)
            found.append((hwnd, title.value, bool(u32.IsIconic(hwnd))))
        return True

    u32.EnumWindows(ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)(each), 0)
    return found


def foreground_window():
    return _user32()[2].GetForegroundWindow()


def listening_ports(pid):
    cmd = (f"Get-NetTCPConnection -OwningProcess {pid} -State Listen -ErrorAction SilentlyContinue"
           " | Select-Object -ExpandProperty LocalPort")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", cmd], capture_output=True, text=True,
                         timeout=60).stdout
    return {int(p) for p in out.split()}


def l_launch_tools_close():
    with live_launch() as inst:
        pid = inst.pid
        names = {t["name"] for t in inst.mcp.tools()}
    missing = [t for t in launcher.REQUIRED_TOOLS if t not in names]
    need(not missing, f"tools/list lacks {missing}")
    need(not launcher.pid_alive(pid), f"PID {pid} alive after close")
    return f"PID {pid}, {len(names)} tools"


def l_private_copy_mcp():
    with live_launch() as inst:
        pid, where = inst.pid, Path(inst.exe_dir)
    copy = launcher.PRIVATE_DIR
    for name in ("DeZogPlugin.dll", "zxnext.mmc"):
        need(not (copy / name).exists(), f"private copy holds {name}")
    which = "the private copy" if where == copy else "the source install (fallback)"
    return f"MCP answered from {which} {where} (PID {pid})"


def l_no_port_11000():
    with live_launch() as inst:
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
    with live_launch() as inst:
        time.sleep(3)                       # sampling point: 3 s after the MCP answers
        wins, fg = top_windows(inst.pid), foreground_window()
        seen = (f"PID {inst.pid} windows "
                + (", ".join(f"{h:#x} {t!r} {'iconic' if i else 'NOT iconic'}"
                             f"{' FOREGROUND' if h == fg else ''}" for h, t, i in wins) or "none")
                + f"; foreground {fg or 0:#x}")
        need(wins, f"no visible top-level window: {seen}")
        need(all(i for _, _, i in wins) and fg not in [h for h, _, _ in wins], seen)
    return seen


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
    STARTED.append(int(line))
    return helper, int(line)


def l_parent_killed():
    helper, pid = spawn_helper()
    try:
        need(launcher.pid_alive(pid), f"helper's CSpect PID {pid} not running")
        helper.kill()
        helper.wait(10)
        need(wait_gone(pid, 5), f"CSpect PID {pid} alive 5 s after its parent was killed")
    finally:
        helper.kill()
        kill_pid(pid)
    return f"PID {pid} gone after parent kill"


def l_exception_closes():
    pid = None
    try:
        with live_launch() as inst:
            pid = inst.pid
            raise RuntimeError("raised inside with")
    except RuntimeError:
        pass
    need(pid is not None, "launch did not return")
    need(not launcher.pid_alive(pid), f"PID {pid} alive after the exception")
    return f"PID {pid} closed"


def l_foreign_untouched():
    helper, pid = spawn_helper()
    saved = os.environ.get("NEXTDAAD_CSPECT_WAIT")
    try:
        os.environ["NEXTDAAD_CSPECT_WAIT"] = "3"
        e = raises(launcher.LaunchError, live_launch)
        need(launcher.MUTEX_NAME in str(e), f"error does not name the mutex: {e}")
        need(launcher.pid_alive(pid), f"helper's CSpect PID {pid} was killed")
        helper.stdin.write("\n")
        helper.stdin.flush()
        need(helper.stdout.readline().strip() == "closed", "helper did not close its CSpect")
        helper.wait(10)
        need(not launcher.pid_alive(pid), f"helper's CSpect PID {pid} alive after the helper closed it")
    finally:
        if saved is None:
            os.environ.pop("NEXTDAAD_CSPECT_WAIT", None)
        else:
            os.environ["NEXTDAAD_CSPECT_WAIT"] = saved
        helper.kill()
        kill_pid(pid)
    return f"helper PID {pid} survived the refused launch"


HOST = [t_parse_dump_ok, t_dump_rejects_gap, t_read_map, t_reply_sse_and_plain,
        t_status_without_pc_raises, t_required_tools_checked, t_version_gate, t_port_choice,
        t_private_copy_excludes, t_job_kills_child, t_mutex_serialises, t_no_answer_names_causes]
LIVE = [l_launch_tools_close, l_private_copy_mcp, l_no_port_11000, l_window_minimised,
        l_parent_killed, l_exception_closes, l_foreign_untouched]


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
            print(f"FAIL {check.__name__}: {type(e).__name__ + ': ' if not isinstance(e, CheckFailed) else ''}{e}",
                  flush=True)
        else:
            print(f"PASS {check.__name__}" + (f" - {note}" if note else ""), flush=True)
    if STARTED:
        left = [p for p in STARTED if launcher.pid_alive(p)]
        print(f"CSpect PIDs started: {STARTED}; still alive: {left or 'none'}")
        fails += bool(left)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
