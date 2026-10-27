#!/usr/bin/env python3
"""MSX1 leg for OBJVERIF: play walk.txt on the DAAD-READY DMSXIEF3.BIN DSK
under openMSX 0.15 (Philips_NMS_8250 as MSX1.BAT, renderer none, -control
stdio); screen text per step decoded from VRAM (graphic II) against
AD8x6.CHR, the font baked into DAAD.MDG; compare diffs test against control.

    python -I drive_msx1.py run <dsk> <walk.txt> <out_dir>
    python -I drive_msx1.py compare <test_dir> <ctl_dir> <results.md>

ZEsarUX 13's MSX1 machine has no disk drive (cartridge and tape only), so
the DSK cannot boot there. The DSK is used from a copy: openMSX writes to
a disk image in place.
"""
import argparse
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import classic_leg   # noqa: E402
import cscreen       # noqa: E402
import drive_zx48    # noqa: E402
import omsx          # noqa: E402
import zleg          # noqa: E402

OPENMSX = classic_leg.ROOT / "tools" / "DAAD-READY" / "TOOLS" / "openmsx" \
    / "openmsx.exe"
MACHINE = "Philips_NMS_8250"
CHARSET = (classic_leg.ROOT / "tools" / "DAAD-READY" / "ASSETS" / "CHARSET"
           / "AD8x6.CHR")
KEY_S = 0.12


class Msx:
    def __init__(self, m, table):
        self.m, self.table = m, table
        self.bases = (0x1800, 0x0000, 0x2000)

    def read(self):
        h = self.m.cmd("binary scan [debug read_block VRAM 0 16384] H* h; "
                       "set h")
        return bytes.fromhex(h)

    def decode(self, raw):
        rows, _ = cscreen.msx_g2(raw, *self.bases)
        return cscreen.decode(rows, 6, self.table, 42, 256)

    def png(self, raw, path):
        cscreen.write_png(path, cscreen.msx_g2(raw, *self.bases)[1])

    def _type(self, text, n):
        self.m.cmd('type "%s"' % text)
        time.sleep(KEY_S * n + 0.4)

    def type(self, cmd):
        self._type(cmd.lower(), len(cmd))

    def enter(self):
        self._type("\\r", 1)

    def space(self):
        self._type(" ", 1)


def run(args):
    src = Path(args.dsk).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    dsk = work / ("run_" + src.name)
    shutil.copyfile(src, dsk)
    table = cscreen.load_font(args.charset, 6)
    prompts = zleg.prompt_set(drive_zx48.load_stx(args.dsf))
    log = open(out / "run.log", "w", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log.write(msg + "\n")
        log.flush()

    m = omsx.OpenMsx(OPENMSX, ["-machine", MACHINE, "-diska", str(dsk)],
                     work, work / "settings.xml")
    say("launch: %s (cwd %s)" % (" ".join(m.cmdline), work))
    try:
        say("openMSX renderer %s, machine %s"
            % (m.cmd("set renderer"), m.cmd("machine_info type")))
        m.cmd("set power on")
        msx = Msx(m, table)
        # wait for the interpreter's screen mode before taking the bases
        t0 = time.time()
        while True:
            r = [int(m.cmd("vdpreg %d" % i)) for i in range(8)]
            if r[0] & 0x02 and time.time() - t0 > 5:
                break
            if time.time() - t0 > 120:
                raise SystemExit("no graphic II mode, VDP regs %r" % r)
            time.sleep(0.5)
        msx.bases = (r[2] * 0x400, (r[4] & 4) * 0x800, (r[3] & 0x80) * 0x40)
        say("VDP regs %r; name %04X pattern %04X colour %04X"
            % ((r,) + msx.bases))
        classic_leg.walk(msx, args.walk, out, say, prompts)
    finally:
        rc = m.kill()
        say("emulator killed, rc=%s" % rc)
        log.close()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("run")
    r.add_argument("dsk")
    r.add_argument("walk")
    r.add_argument("out")
    r.add_argument("--work", required=True,
                   help="scratch folder for the DSK copy and settings")
    r.add_argument("--dsf", default=str(HERE.parent / "OBJVERIF.DSF"))
    r.add_argument("--charset", default=str(CHARSET))
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
