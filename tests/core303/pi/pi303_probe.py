"""P0 board-gate probe: version, caps, NextReg read/write, Pi image contents. Writes PROBE.LOG.
Run on the Pi with the Next in the slave program; exits non-zero on any failure.
"""
import argparse
import os
import platform
import re
import shutil
import subprocess
import sys

import link as lk
from bundle import bundle_hash
from pilog import PiLogWriter

TOOL = "pi303_probe"
HERE = os.path.dirname(os.path.abspath(__file__))
CAPS_NEEDED = 0x2E      # bits 1 NR read, 2 NR write, 3 SRAM r/w, 5 BRAM r/w
NR_TEST = 0x7F
NR_VALUE = 0x5A
CLK_SUMMARY = "/sys/kernel/debug/clk/clk_summary"
BUFSIZ = "/sys/module/spidev/parameters/bufsiz"
JPEGLIB = "/usr/include/jpeglib.h"
MODEL = "/proc/device-tree/model"
CPUFREQ = "/sys/devices/system/cpu/cpu0/cpufreq"
GCC_TIMEOUT_S = 10


def _readable(path):
    try:
        with open(path, "rb") as f:
            f.read(1)
        return True
    except OSError:
        return False


def _has_module(name):
    import importlib.util
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _lock_dir_writable():
    return os.access(os.path.dirname(lk.LOCK_PATH) or "/", os.W_OK)


def _bufsiz():
    try:
        with open(BUFSIZ) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


def _text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("ascii", "replace")
    except OSError:
        return None


def _tok(s):
    """A #PIENV value: NULs dropped, any other non-printable or space as _, else na."""
    s = (s or "").replace("\0", "").strip()
    return re.sub(r"[^\x21-\x7E]", "_", s) or "na"


def _int(s):
    s = (s or "").strip()
    return int(s) if s.isdigit() else "na"


def _dist_version(dist, module):
    """Installed version without importing the package (pi303_video must stay PIL-free)."""
    mod = sys.modules.get(module)
    if getattr(mod, "__version__", None):
        return mod.__version__
    try:
        from importlib import metadata
        return metadata.version(dist)
    except Exception:
        return "none"


def _gcc_version():
    try:
        r = subprocess.run(["gcc", "-dumpversion"], capture_output=True,
                           timeout=GCC_TIMEOUT_S, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return "none"
    return _tok(r.stdout.decode("ascii", "replace")) if r.returncode == 0 else "none"


def pienv():
    """#PIENV context: board model, cpu0 governor and clock, kernel, Python, numpy, PIL,
    gcc and spidev bufsiz. Each read fails safe to na (missing) or none (not installed)."""
    return {"model": _tok(_text(MODEL)),
            "governor": _tok(_text(os.path.join(CPUFREQ, "scaling_governor"))),
            "arm_khz": _int(_text(os.path.join(CPUFREQ, "scaling_cur_freq"))),
            "kernel": _tok(platform.uname().release),
            "py": _tok(platform.python_version()),
            "numpy": _tok(_dist_version("numpy", "numpy")),
            "pil": _tok(_dist_version("Pillow", "PIL")),
            "gcc": _gcc_version(),
            "bufsiz": _int(_text(BUFSIZ))}


def default_probes():
    return {"gcc": int(shutil.which("gcc") is not None),
            "numpy": int(_has_module("numpy")),
            "pil": int(_has_module("PIL")),
            "jpeghdr": int(os.path.isfile(JPEGLIB)),
            "lock": int(_lock_dir_writable()),
            "bufsiz": _bufsiz(),
            "clk": int(_readable(CLK_SUMMARY))}


def default_core_clk():
    """(Hz, 'debugfs') from the first clk_summary row named core*, else (0, 'none')."""
    try:
        with open(CLK_SUMMARY) as f:
            for ln in f:
                t = ln.split()
                if len(t) >= 5 and t[0].startswith("core") and t[4].isdigit():
                    return int(t[4]), "debugfs"
    except OSError:
        pass
    return 0, "none"


def default_spi_open():
    """PIDs holding /dev/spidev0.0 open, from /proc/*/fd; empty off Linux."""
    pids = []
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                fds = os.listdir("/proc/%s/fd" % pid)
                for fd in fds:
                    if os.readlink("/proc/%s/fd/%s" % (pid, fd)) == "/dev/spidev0.0":
                        pids.append(int(pid))
                        break
            except OSError:
                continue
    except OSError:
        pass
    return sorted(pids)


def open_log(path, tool, bundle, link, version, caps, core_clk, spi_open):
    """Header and #PIENV context line; #SPI only when version is not None."""
    log = PiLogWriter(path, tool, bundle)
    log.env(**pienv(), spi_max_saved=getattr(link, "spi_max_saved", None) or 0,
            spi_max_stale=getattr(link, "spi_max_stale", None) or 0,
            spi_open=",".join(str(p) for p in spi_open))
    if version is not None:
        hz, src = core_clk
        log.spi(version, caps, hz, src)
    return log


def _nr_test(link):
    """Write $5A to NR $7F and read it back; the original is always written back."""
    orig = link.nr_read(NR_TEST)
    try:
        link.nr_write(NR_TEST, NR_VALUE)
        got = link.nr_read(NR_TEST)
    finally:
        link.nr_write(NR_TEST, orig)
    return int(got == NR_VALUE and link.nr_read(NR_TEST) == orig)


def main(link, out_dir, bundle, probes=None, core_clk=None, spi_open=None):
    probes = probes or default_probes
    core_clk = core_clk or default_core_clk
    spi_open = spi_open or default_spi_open
    log = open_log(os.path.join(out_dir, "PROBE.LOG"), TOOL, bundle, link, None, 0,
                   None, spi_open())
    try:
        try:
            ver, caps = link.version()
        except (lk.LinkError, OSError):
            log.skip("P0VR", "LINK")
            return 1
        hz, src = core_clk()
        log.spi(ver, caps, hz, src)
        log.row("P0VR", ver=ver, caps=caps)
        log.row("P0NR", nr01=link.nr_read(0x01), nr0e=link.nr_read(0x0E),
                nr0f=link.nr_read(0x0F))
        try:
            ok = _nr_test(link)
        except (lk.LinkError, OSError):
            log.skip("P0RW", "LINK")
            ok = 0
        else:
            log.row("P0RW", ok=ok)
        log.row("P0IM", **probes())
        rc = 0 if ok else 1
        if caps & CAPS_NEEDED != CAPS_NEEDED:
            log.skip("P3P4", "CAPS")
            rc = 1
        return rc
    finally:
        close_log(log, link)


def close_log(log, link):
    """Restore the spidev settings while the log is still open, log the result on #SPI,
    then #END; the link's own close() later finds them restored."""
    try:
        restore = getattr(link, "restore", None)
        if restore is not None:
            try:
                restore()
            except OSError:
                pass
        v = getattr(link, "spi_max_restored", None)
        if v is not None:
            log.spi_extra(spi_max_restored=v)
    finally:
        log.close()


def write_busy(out_dir, logname, tool, bundle):
    log = PiLogWriter(os.path.join(out_dir, logname), tool, bundle)
    log.skip("BUSY", "LOCK")
    log.close()


def check_bundle(given, out_dir, logname, tool, tag):
    """The bundle hash of the files themselves. A --bundle that differs writes
    #SKIP <tag> BUNDLE before any SPI traffic and returns None (the tool exits 1)."""
    actual = bundle_hash(HERE)
    if given is not None and given != actual:
        log = PiLogWriter(os.path.join(out_dir, logname), tool, actual)
        log.skip(tag, "BUNDLE")
        log.close()
        return None
    return actual


def run_cli(tool, logname, tag, body, link_factory, argv=None, clock=None, **kw):
    """Open the link (taking the bus lock); a lock timeout writes #SKIP BUSY LOCK."""
    ap = argparse.ArgumentParser(prog=tool)
    ap.add_argument("--out", default=".")
    ap.add_argument("--bundle", default=None)
    a = ap.parse_args(argv)
    bundle = check_bundle(a.bundle, a.out, logname, tool, tag)
    if bundle is None:
        return 1
    link = link_factory()
    try:
        link.open(clock)
    except lk.BusBusy:
        write_busy(a.out, logname, tool, bundle)
        return 2
    try:
        return body(link, a.out, bundle, **kw)
    finally:
        link.close()


def cli(link_factory, argv=None, clock=None, **kw):
    return run_cli(TOOL, "PROBE.LOG", "P0VR", main, link_factory, argv, clock, **kw)


if __name__ == "__main__":
    sys.exit(cli(lk.SpidevLink))
