#!/usr/bin/env python3
"""ZX 48K leg for OBJVERIF: play walk.txt on the original DS48IE3.BIN TAP
under ZEsarUX 13 (headless, ZRCP) and dump screen PNG + decoded text per
step; --compare diffs a test run against a control run.

    python -I drive_zx48.py run <tap> <walk.txt> <out_dir> [--dsf DSF]
    python -I drive_zx48.py compare <test_dir> <ctl_dir> <results.md>

Text comes from tests/parser/zscreen.py (AD8x6.CHR 6-pixel cells, phase
search); turn text and prompt trimming reuse tests/parser/zleg.py. The
emulator is killed at the end of a run (ZRCP quit only closes the socket).
"""
import argparse
import json
import re
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp      # noqa: E402
import zscreen   # noqa: E402
import zleg      # noqa: E402

ZESARUX = Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
PORT = 10778
CONNECT_S = 120.0
POLL_S = 0.25
STABLE_POLLS = 4          # about 1 s unchanged
PAUSE_POLLS = 8           # settled, no cursor, no More...: dismiss anyway
TURN_TIMEOUT_S = 60.0
BOOT_TIMEOUT_S = 120.0
MAX_PAGES = 20
MORE = "More..."


# ---- PNG ----------------------------------------------------------------

PAL = [(0, 0, 0), (0, 0, 0xD7), (0xD7, 0, 0), (0xD7, 0, 0xD7),
       (0, 0xD7, 0), (0, 0xD7, 0xD7), (0xD7, 0xD7, 0), (0xD7, 0xD7, 0xD7),
       (0, 0, 0), (0, 0, 0xFF), (0xFF, 0, 0), (0xFF, 0, 0xFF),
       (0, 0xFF, 0), (0, 0xFF, 0xFF), (0xFF, 0xFF, 0), (0xFF, 0xFF, 0xFF)]


def write_png(path, scr):
    """6912-byte ULA dump to a 256x192 RGB PNG (FLASH ignored)."""
    bits = zscreen.screen_bits(scr[:6144])
    attrs = scr[6144:6912]
    raw = bytearray()
    for y in range(192):
        raw.append(0)
        row = bits[y]
        for x in range(256):
            a = attrs[(y // 8) * 32 + x // 8]
            br = 8 if a & 0x40 else 0
            on = (row >> (255 - x)) & 1
            raw.extend(PAL[(a & 7) + br] if on else PAL[((a >> 3) & 7) + br])

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 192, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


# ---- fixture system messages --------------------------------------------

def load_stx(dsf):
    """/STX texts by number, '#n' as a newline (zleg prompt trimming)."""
    out, on = {}, False
    for line in Path(dsf).read_text(encoding="latin-1").splitlines():
        if line.startswith("/STX"):
            on = True
            continue
        if on and re.match(r"^/[A-Z]", line):
            break
        m = re.match(r'^/(\d+)\s+"(.*)"\s*$', line)
        if on and m:
            out[int(m.group(1))] = m.group(2).replace("#n", "\n")
    return out


# ---- run ----------------------------------------------------------------

class Run:
    def __init__(self, z, table, out):
        self.z, self.table, self.out = z, table, out

    def scr(self):
        return self.z.read_memory(16384, 6912)

    def settle(self, baseline, limit, tag):
        """Wait until the line editor cursor shows; dismiss More... pages.

        Returns (final 6912-byte screen, [paged screens]). A page is
        captured before its key goes out.
        """
        deadline = time.time() + limit
        last, static, moved, pages = None, 0, baseline is None, []
        while time.time() < deadline:
            px = self.scr()
            if px == last:
                static += 1
            else:
                static, last = 0, px
            if baseline is not None and px[:6144] != baseline[:6144]:
                moved = True
            if moved and static >= STABLE_POLLS:
                lines = zscreen.decode(px[:6144], self.table)
                if zleg.has_cursor(lines):
                    return px, pages
                more = bool(lines) and MORE in lines[-1]
                if more or static >= PAUSE_POLLS:
                    if len(pages) >= MAX_PAGES:
                        raise TimeoutError("%s: %d pages without a prompt"
                                           % (tag, len(pages)))
                    pages.append((px, "more" if more else "nocursor"))
                    self.z.cmd("send-keys-ascii %d 32" % zrcp.KEY_DELAY_MS,
                               wait=0.6)
                    static, last = 0, None
                    continue
            time.sleep(POLL_S)
        raise TimeoutError("%s: no prompt within %.0fs, last lines %r"
                           % (tag, limit, zscreen.decode(last[:6144],
                                                         self.table)[-3:]
                              if last else []))


def emit_text(pre, caps, kinds, final, prompts):
    """zleg._emit_text, plus: between two More... pages every row is new.

    The pager pauses after a full window of rows, so scroll matching there
    would merge a repeated text (a duplicate pair) into one copy.
    """
    prev, out, redraw, prev_more = zleg.strip_cursor(pre), [], False, False
    for cap, kind in zip(caps + [final], kinds + ["final"]):
        cur = zleg.strip_cursor(cap)
        if prev_more and kind == "more":
            lines, r = list(cur), False
        else:
            lines, r = zscreen.new_text(prev, cur)
        out.extend(lines)
        redraw = redraw or r
        prev, prev_more = cur, kind == "more"
    if zleg.has_cursor(final):
        if out and prev and out[-1] == prev[-1]:
            out.pop()
        out = zleg._drop_pending_prompt(out, prompts)
    return out, redraw


def run(args):
    tap = Path(args.tap).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    walk = [l.strip() for l in Path(args.walk).read_text().splitlines()
            if l.strip()]
    table = zscreen.load_font(args.charset)
    stx = load_stx(args.dsf) if args.dsf else {}
    prompts = zleg.prompt_set(stx)
    log = open(out / "run.log", "w", encoding="utf-8")

    def say(msg):
        print(msg, flush=True)
        log.write(msg + "\n")
        log.flush()

    if zleg.port_already_listening(args.port):
        raise SystemExit("port %d already listening - stale emulator"
                         % args.port)
    cmdline = [str(ZESARUX), "--noconfigfile", "--machine", "48k",
               "--vo", "null", "--ao", "null",
               "--enable-remoteprotocol", "--remoteprotocol-port",
               str(args.port), "--realloadfast", "--nosplash",
               "--nowelcomemessage"]
    say("launch: %s (cwd %s)" % (" ".join(cmdline), out))
    proc = subprocess.Popen(cmdline, cwd=str(out), stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    t0 = time.time()
    try:
        z = None
        while time.time() - t0 < CONNECT_S:
            if proc.poll() is not None:
                raise SystemExit("zesarux exited rc=%s before ZRCP"
                                 % proc.returncode)
            try:
                z = zrcp.Zrcp(port=args.port)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise SystemExit("ZRCP did not connect within %.0fs" % CONNECT_S)
        say("connected after %.1fs" % (time.time() - t0))
        z.cmd("smartload %s" % str(tap).replace("\\", "/"), deadline=30.0)
        r = Run(z, table, out)
        boot, bpages = r.settle(None, BOOT_TIMEOUT_S, "boot")
        write_png(out / "step00_boot.png", boot)
        say("booted after %.1fs, %d page(s)" % (time.time() - t0, len(bpages)))
        steps = [{"step": 0, "command": "(boot)",
                  "screen": zscreen.decode(boot[:6144], table),
                  "pages": len(bpages)}]
        for i, cmd in enumerate(walk, 1):
            z.send_keys(cmd)
            pre_raw = r.scr()
            z.enter(wait=0.3)
            post, pages = r.settle(pre_raw, TURN_TIMEOUT_S,
                                   "step %d %s" % (i, cmd))
            pre = zscreen.decode(pre_raw[:6144], table)
            caps = []
            for k, (px, kind) in enumerate(pages, 1):
                write_png(out / ("step%02d_page%d.png" % (i, k)), px)
                caps.append(zleg.drop_pager_prompt(
                    zscreen.decode(px[:6144], table), MORE))
            final = zscreen.decode(post[:6144], table)
            text, redraw = emit_text(pre, caps, [k for _, k in pages],
                                     final, prompts)
            write_png(out / ("step%02d.png" % i), post)
            steps.append({"step": i, "command": cmd, "text": text,
                          "redraw": redraw,
                          "pages": [kind for _, kind in pages],
                          "page_screens": caps, "screen": final})
            say("step %02d %-16s %d line(s) %d page(s)%s"
                % (i, cmd, len(text), len(pages),
                   " [redraw]" if redraw else ""))
        with open(out / "transcript.jsonl", "w", encoding="utf-8") as fh:
            for s in steps:
                fh.write(json.dumps(s) + "\n")
        with open(out / "transcript.txt", "w", encoding="utf-8") as fh:
            for s in steps[1:]:
                fh.write("== %02d %s\n" % (s["step"], s["command"]))
                for l in s["text"]:
                    fh.write(l + "\n")
        z.close()
    finally:
        proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        say("emulator killed, rc=%s" % proc.poll())
        log.close()


# ---- compare ------------------------------------------------------------

def load_steps(d):
    return [json.loads(l) for l in
            (Path(d) / "transcript.jsonl").read_text(encoding="utf-8")
            .splitlines() if l.strip()]


def compare(args):
    t, c = load_steps(args.test), load_steps(args.ctl)
    rows, fails = [], 0
    for a, b in zip(t[1:], c[1:]):
        n = a["step"]
        text_ok = a["command"] == b["command"] and a["text"] == b["text"]
        pa = Path(args.test) / ("step%02d.png" % n)
        pb = Path(args.ctl) / ("step%02d.png" % n)
        same_scr = pa.read_bytes() == pb.read_bytes()
        pages = "%d/%d" % (len(a["pages"]), len(b["pages"]))
        verdict = "PASS" if text_ok and a["pages"] == b["pages"] else "FAIL"
        fails += verdict == "FAIL"
        ctl_text = " / ".join(b["text"]) or "(nothing)"
        test_text = " / ".join(a["text"]) or "(nothing)"
        rows.append((n, a["command"], verdict, "yes" if same_scr else "no",
                     pages, ctl_text,
                     "same" if test_text == ctl_text else test_text))
    if len(t) != len(c):
        fails += 1
    md = ["| Step | Command | Result | PNG identical | More... pages "
          "(test/ctl) | Control text | Test text |",
          "|---:|---|---|---|---|---|---|"]
    for r in rows:
        md.append("| %d | %s | %s | %s | %s | %s | %s |"
                  % (r[:5] + tuple(x.replace("|", "\\|") for x in r[5:])))
    md.append("")
    md.append("%d step(s), %d FAIL; boot screen identical: %s"
              % (len(rows), fails,
                 "yes" if t[0]["screen"] == c[0]["screen"] else "no"))
    Path(args.md).write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[-1:]))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("run")
    r.add_argument("tap")
    r.add_argument("walk")
    r.add_argument("out")
    r.add_argument("--dsf", default=str(HERE.parent / "OBJVERIF.DSF"))
    r.add_argument("--charset", default=str(zscreen.DEFAULT_CHARSET))
    r.add_argument("--port", type=int, default=PORT)
    c = sub.add_parser("compare")
    c.add_argument("test")
    c.add_argument("ctl")
    c.add_argument("md")
    args = ap.parse_args()
    if args.mode == "run":
        run(args)
        return 0
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
