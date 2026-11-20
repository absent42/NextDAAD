"""ZEsarUX helpers for the 3.03.03-only interpreter: the reported core
version and the harness stack-canary reader.

ZEsarUX 13.0 has no option, ZRCP command or config entry that sets the
TBBlue core version (tbblue-set-register on NR $01/$0E is ignored). The
version lives in three static bytes of the 32-bit, non-ASLR zesarux.exe
(symbols tbblue_core_current_version_*), so patch() writes them in the
launched process before the guest runs. Both shipped binaries are identical.
"""
import ctypes
import pathlib
import subprocess
import sys
import time

# tbblue_core_current_version_subminor / minor / major, consecutive bytes.
VERSION_ADDR = 0x735528
STOCK = (3, 2, 1)                    # (major, minor, subminor) of ZEsarUX 13.0
DEFAULT = (3, 3, 3)                  # what popen() writes; patch() may rewrite it
NRS_CANARY = 0xA5                    # src/hardware.asm NRS_CANARY
CANARY_MARGIN = 64                   # fail inside this many bytes of NRS_END
CANARY_TAIL = 16                     # main.asm leaves these bytes under STACK_TOP

_PROCESS_RIGHTS = 0x0008 | 0x0010 | 0x0020 | 0x0400   # VM_OPERATION READ WRITE QUERY


def popen(argv, **kw):
    """subprocess.Popen for a ZEsarUX command line, then patch()."""
    proc = subprocess.Popen(argv, **kw)
    try:
        patch(proc)
    except BaseException:
        proc.kill()
        raise
    return proc


def patch(proc, version=(3, 3, 3), deadline=10.0):
    """Make the ZEsarUX process proc report core version (major, minor, sub)."""
    if sys.platform != "win32":
        raise OSError("zes_core.patch: Windows zesarux.exe only")
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = ctypes.c_void_p
    k32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    k32.ReadProcessMemory.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                      ctypes.c_size_t, ctypes.c_void_p]
    k32.WriteProcessMemory.argtypes = k32.ReadProcessMemory.argtypes
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k32.OpenProcess(_PROCESS_RIGHTS, False, proc.pid)
    if not h:
        raise OSError("OpenProcess failed: %d" % ctypes.get_last_error())
    try:
        buf = ctypes.create_string_buffer(3)
        n = ctypes.c_size_t()
        end = time.monotonic() + deadline
        while not k32.ReadProcessMemory(h, VERSION_ADDR, buf, 3, ctypes.byref(n)):
            if time.monotonic() > end:
                raise OSError("zes_core: cannot read the ZEsarUX version bytes")
            time.sleep(0.05)
        sub, minor, major = buf.raw
        if (major, minor, sub) not in (STOCK, DEFAULT, tuple(version)):
            raise OSError("zes_core: version bytes %d.%d.%d at 0x%X, expected stock %d.%d.%d "
                          "(different zesarux.exe?)" % ((major, minor, sub, VERSION_ADDR) + STOCK))
        # Static data, not re-initialised after start: the patched version survived
        # hard-reset-cpu and smartload when probed, and the gate read it (refuse_check).
        want = ctypes.create_string_buffer(bytes([version[2], version[1], version[0]]))
        if not k32.WriteProcessMemory(h, VERSION_ADDR, want, 3, ctypes.byref(n)) or n.value != 3:
            raise OSError("zes_core: WriteProcessMemory failed: %d" % ctypes.get_last_error())
    finally:
        k32.CloseHandle(h)


def stack_zone(syms):
    """(start, end) of the canary-filled stack zone from a map symbol table."""
    return syms["NRS_END"], syms["STACK_TOP"] - CANARY_TAIL


def stack_headroom(z, syms):
    """Bytes of stack zone still holding the canary below the deepest stack use.

    z is a Zrcp; syms comes from symbols.load_symbols on a -Harness build's map.
    Returns (deepest_address_or_None, headroom_bytes).
    """
    start, end = stack_zone(syms)
    data = z.read_memory(start, end - start)
    for i, b in enumerate(data):
        if b != NRS_CANARY:
            return start + i, i
    return None, len(data)


def check_stack(z, syms, label=""):
    """Raise AssertionError when the stack came within CANARY_MARGIN bytes of NRS_END."""
    deepest, room = stack_headroom(z, syms)
    start, _ = stack_zone(syms)
    where = "intact" if deepest is None else "deepest $%04X" % deepest
    print("stack canary%s: %s, %d bytes clear above NRS_END $%04X"
          % (" " + label if label else "", where, room, start))
    if room < CANARY_MARGIN:
        raise AssertionError("harness stack reached $%04X, within %d bytes of NRS_END $%04X"
                             % (deepest, CANARY_MARGIN, start))
    return deepest, room


def check_stack_harness(z, label=""):
    """check_stack against the build map when build/harness.txt marks a -Harness
    build; a no-op otherwise. Call while the interpreter is still alive."""
    root = pathlib.Path(__file__).resolve().parent.parent
    if not (root / "build" / "harness.txt").exists():
        return None
    sys.path.insert(0, str(root / "tests" / "parser"))
    import symbols
    return check_stack(z, symbols.load_symbols(root / "build" / "nextdaad.map"), label)
