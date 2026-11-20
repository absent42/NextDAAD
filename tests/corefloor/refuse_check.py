"""Core-floor refusal on ZEsarUX: boots the -Harness build with the reported
core set to each version and reads the tilemap and the border.

    ./build.ps1 -Harness
    python tests/corefloor/refuse_check.py [--port N]

Below 3.03.03 row 0 must read the refusal text and the border must be
ERR_BORDER_CORE; at or above it the refusal must be absent and the
interpreter must have printed something else. Exit 1 on a failed case.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
sys.path.insert(0, str(ROOT / "tests"))
import nleg                                          # noqa: E402
import tilemap                                       # noqa: E402
import zes_core                                      # noqa: E402

MESSAGE = "NextDAAD needs core 3.03.03 or later"
SETTLE_S = 10.0

# (reported core, refused)
CASES = [
    ((3, 2, 1), True),
    ((3, 3, 2), True),
    ((3, 3, 3), False),
    ((3, 4, 0), False),
]


def err_border():
    m = re.search(r"^ERR_BORDER_CORE\s+equ\s+(\d+)", (ROOT / "src" / "nextdaad.inc").read_text(
        encoding="utf-8"), re.M)
    if not m:
        raise SystemExit("refuse_check: ERR_BORDER_CORE not found in src/nextdaad.inc")
    return int(m.group(1))


def run_case(version, port, work):
    sd = work / ("%d.%d.%d" % version)
    sd.mkdir(parents=True)
    nex = sd / "NEXTDAAD.NEX"
    shutil.copyfile(ROOT / "build" / "nextdaad.nex", nex)
    if nleg.port_already_listening(port):
        raise SystemExit("port %d already in use - a stale ZEsarUX is running" % port)
    proc = nleg.launch(sd, port)
    try:
        z = nleg.wait_for_port(proc, port)
        zes_core.patch(proc, version)
        z.cmd("smartload %s" % nex, wait=1.0, deadline=60.0)
        time.sleep(SETTLE_S)
        rows, _ = tilemap.decode(z.read_memory(nleg.TM_MAP, nleg.GRID_BYTES))
        ports = z.cmd("get-io-ports")
        z.close()
    finally:
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/F", "/T"], capture_output=True)
    # get-io-ports prints the last value written to port $FE as "Spectrum FE port: nn";
    # bits 0-2 are the border (cases below read 1 refused, 2 booting to E1).
    m = re.search(r"Spectrum FE port:\s*([0-9A-Fa-f]{2})", ports)
    border = int(m.group(1), 16) & 7 if m else None
    return rows, border


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10091)
    port = ap.parse_args().port
    if not (ROOT / "build" / "harness.txt").exists():
        raise SystemExit("build/nextdaad.nex is not a -Harness build: run ./build.ps1 -Harness")
    want = err_border()
    work = ROOT / "tests" / "out" / "corefloor" / "refuse"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    failed = 0
    for version, refused in CASES:
        rows, border = run_case(version, port, work)
        shown = rows[0].strip() == MESSAGE
        other = any(r.strip() and r.strip() != MESSAGE for r in rows)
        if refused:
            ok = shown and border == want and not any(r.strip() for r in rows[1:])
        else:
            ok = not any(MESSAGE in r for r in rows) and other and border != want
        print("%s core %d.%02d.%02d %s: row0=%r border=%s"
              % ("PASS" if ok else "FAIL", version[0], version[1], version[2],
                 "refused" if refused else "boots", rows[0].strip()[:40], border))
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
