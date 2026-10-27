#!/usr/bin/env python3
"""CPC leg for OBJVERIF: play walk.txt on the DAAD-READY DCPCIEF3.BIN DSK
under ZEsarUX 13 (CPC 6128, headless, ZRCP); screen text per step decoded
from &C000 against AD8x8.CHR; compare diffs a test run against a control.

    python -I drive_cpc.py run <dsk> <walk.txt> <out_dir>
    python -I drive_cpc.py compare <test_dir> <ctl_dir> <results.md>

Boot: BASIC's send-keys mapping on the CPC has no '"', so `runxdaad` is
typed, the x in the BASIC edit buffer (&AC8A, BASIC 1.1) is overwritten
with &22 and ENTER sent: RUN"DAAD.
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import classic_leg   # noqa: E402
import cscreen       # noqa: E402
import drive_zx48    # noqa: E402
import zleg          # noqa: E402
import zrcp          # noqa: E402

ZESARUX = Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
PORT = 10779
CHARSET = (classic_leg.ROOT / "tools" / "DAAD-READY" / "ASSETS" / "CHARSET"
           / "AD8x8.CHR")
EDIT_BUF = 0xAC8A
SCREEN = 0xC000
KEY_MS = 150


class Cpc:
    def __init__(self, z, table, tmp):
        self.z, self.table, self.tmp = z, table, tmp

    def read(self):
        return self.z.read_memory(SCREEN, 0x4000)

    def decode(self, raw):
        return cscreen.decode(cscreen.ink_rows(cscreen.cpc_pixels(raw)), 8,
                              self.table, 40, 320, l1=True)

    def png(self, raw, path):
        # save-screen renders the live frame; raw is the settled screen
        bmp = self.tmp / "cap.bmp"
        self.z.cmd("save-screen %s" % str(bmp).replace("\\", "/"))
        cscreen.bmp_to_png(bmp, path)

    def type(self, cmd):
        self.z.cmd("send-keys-string %d %s" % (KEY_MS, cmd.lower()),
                   wait=KEY_MS / 1000.0 * len(cmd) + 0.8, deadline=30)

    def enter(self):
        self.z.cmd("send-keys-ascii %d 13" % KEY_MS, wait=0.3)

    def space(self):
        self.z.cmd("send-keys-ascii %d 32" % KEY_MS, wait=0.6)


def boot(z, say):
    deadline = time.time() + 60
    while "Ready" not in z.cmd("get-ocr"):
        if time.time() > deadline:
            raise SystemExit("no BASIC Ready prompt")
        time.sleep(0.5)
    z.cmd("send-keys-string %d runxdaad" % KEY_MS, wait=2.0)
    buf = z.read_memory(EDIT_BUF, 9)
    if buf != b"runxdaad\x00":
        raise SystemExit("edit buffer at &%04X holds %r" % (EDIT_BUF, buf))
    z.cmd("write-memory %d 34" % (EDIT_BUF + 3))
    say("edit buffer patched: %r" % z.read_memory(EDIT_BUF, 9))
    z.cmd("send-keys-ascii %d 13" % KEY_MS, wait=0.3)


def run(args):
    dsk = Path(args.dsk).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    table = cscreen.load_font(args.charset, 8)
    prompts = zleg.prompt_set(drive_zx48.load_stx(args.dsf))
    log = open(out / "run.log", "w", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log.write(msg + "\n")
        log.flush()

    if zleg.port_already_listening(args.port):
        raise SystemExit("port %d already listening" % args.port)
    cmdline = [str(ZESARUX), "--noconfigfile", "--machine", "CPC6128",
               "--vo", "null", "--ao", "null", "--enable-dsk", "--dsk-file",
               str(dsk), "--enable-remoteprotocol", "--remoteprotocol-port",
               str(args.port), "--nosplash", "--nowelcomemessage"]
    say("launch: %s" % " ".join(cmdline))
    proc = subprocess.Popen(cmdline, cwd=str(out), stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    t0 = time.time()
    try:
        z = None
        while time.time() - t0 < 120:
            if proc.poll() is not None:
                raise SystemExit("zesarux exited rc=%s" % proc.returncode)
            try:
                z = zrcp.Zrcp(port=args.port)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise SystemExit("ZRCP did not connect")
        say("connected after %.1fs; %s" % (time.time() - t0,
                                           z.cmd("get-current-machine")))
        z.cmd("set-memory-zone 0")   # 128K RAM; &C000 = bank 0 block 3
        boot(z, say)
        classic_leg.walk(Cpc(z, table, out), args.walk, out, say, prompts)
        (out / "cap.bmp").unlink(missing_ok=True)
        z.close()
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
    r.add_argument("dsk")
    r.add_argument("walk")
    r.add_argument("out")
    r.add_argument("--dsf", default=str(HERE.parent / "OBJVERIF.DSF"))
    r.add_argument("--charset", default=str(CHARSET))
    r.add_argument("--port", type=int, default=PORT)
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
