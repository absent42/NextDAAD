r"""Transcript single-turn diff: tilemap capture vs TRANS.TXT's LAST
surviving write, for one recorded turn. Multi-turn file diffs need
silicon: ZEsarUX's F_WRITE only persists the last open-seek-write-close
cycle of a session to the host file, zero-filling every earlier
flush's region - a known emulator divergence, not a module fault.

Usage: python tests\xbn\transcheck.py sd\XBN ARM CONTENT STOP
Needs the leg staged by tests\build-tests.ps1 -Xbn -XbnTrans, which
carries the toolkit+transcript subset instead of the plain fixture.
Exactly three verbs. ARM arms recording (its own line is typed before
fn 90 arms, so it never reaches the file); CONTENT is the turn under
test; STOP's line hook is what flushes CONTENT's queued output, and
that is the LAST flush of the run, so it is the one that survives.
Exit 1 on divergence, 2 on a usage error."""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
import zrcp, tilemap, nleg, normalise, transcript2jsonl  # noqa: E402

ZESARUX = pathlib.Path(r"D:\ZXNextDev\ZEsarUX\zesarux.exe")
PORT = 10032
TM_MAP = 0x6000
WIN_TOP, WIN_ROWS = 12, 16


PROMPT = "What now?>"   # SM2 (flag 42 pinned to 2) then SM33, appended to
                        # the response row with no newline of its own


def screen_turn(z, cols):
    # both sides end with the NEXT turn's prompt appended to the last
    # response line ("restoredWhat now?>"); transcript2jsonl.strip_prompt
    # removes the suffix, dropping the line only if nothing remains. The
    # cursor cell is a space or an attribute change, so rstrip leaves the
    # row ending in ">".
    grid = z.read_memory(TM_MAP, cols * tilemap.ROWS * 2)
    rows, _ = tilemap.decode(grid, cols=cols)
    body = [r.rstrip() for r in rows[WIN_TOP:WIN_TOP + WIN_ROWS] if r.strip()]
    return "\n".join(transcript2jsonl.strip_prompt(body, PROMPT))


def extract_content(raw, content_verb):
    """raw = TRANS.TXT bytes. ZEsarUX zero-fills every flush region
    except the last, so the last NUL byte (if any) marks where the
    surviving write begins. Returns the CONTENT turn's text (the part
    before the final ">>"-marker line, with a matching command echo
    and the prompt suffix stripped), or None if no ">>" marker is
    found in that region."""
    last_nul = raw.rfind(b"\x00")
    region = raw[last_nul + 1:] if last_nul != -1 else raw
    text = transcript2jsonl.decode(region)
    lines = text.split("\n")
    stop_idx = None
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith(">>"):
            stop_idx = i
            break
    if stop_idx is None:
        return None
    content_lines = lines[:stop_idx]
    if content_lines and content_lines[0].strip().upper() == content_verb.strip().upper():
        content_lines = content_lines[1:]
    content_lines = transcript2jsonl.strip_prompt(content_lines, PROMPT)
    return "\n".join(content_lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("leg")
    ap.add_argument("verbs", nargs="+")
    ap.add_argument("--wait", type=float, default=3.0)
    ap.add_argument("--cols", type=int, default=80)
    args = ap.parse_args()
    if len(args.verbs) != 3:
        ap.error("expects exactly three verbs: ARM CONTENT STOP")
    arm, content, stop = args.verbs
    leg = (ROOT / args.leg).resolve()
    if nleg.port_already_listening(PORT):
        raise SystemExit("port %d taken - close the stale ZEsarUX" % PORT)
    work = pathlib.Path(tempfile.mkdtemp(prefix="transcheck-"))
    sd = work / "sd"
    shutil.copytree(leg, sd)
    shutil.copyfile(ROOT / "build" / "nextdaad.nex", sd / "nextdaad.nex")
    proc = subprocess.Popen([
        str(ZESARUX), "--machine", "tbblue", "--realvideo",
        "--enable-esxdos-handler", "--esxdos-root-dir", str(sd),
        "--vo", "null", "--ao", "null",
        "--enable-remoteprotocol", "--remoteprotocol-port", str(PORT),
        "--smartloadpath", str(sd),
    ], cwd=str(sd))
    rc = 1
    try:
        z = None
        for _ in range(60):
            if proc.poll() is not None:
                raise SystemExit("ZEsarUX died before ZRCP came up")
            try:
                z = zrcp.Zrcp(port=PORT)
                break
            except OSError:
                time.sleep(0.5)
        if z is None:
            raise SystemExit("ZRCP never came up")
        z.cmd("smartload %s" % (sd / "nextdaad.nex"), deadline=30.0)
        time.sleep(6.0)
        screen = {}
        for verb in args.verbs:
            z.send_keys(verb)
            z.enter(wait=args.wait)
            screen[verb] = screen_turn(z, args.cols)
        z.close()
        src = sd / "TRANS.TXT"
        if not src.exists():
            raise SystemExit("TRANS.TXT was not written")
        shutil.copyfile(src, ROOT / "tests" / "out" / "xbn" / "TRANS.TXT")
        raw = src.read_bytes()
        rtext = extract_content(raw, content)
        if rtext is None:
            raise SystemExit("no >> marker found in the surviving flush region")
        stext = screen[content]
        bad = 0
        if normalise.tokens(stext) != normalise.tokens(rtext):
            bad = 1
            print("DIVERGE %s\n  screen: %r\n  file:   %r" % (content, stext, rtext))
        print("1 turn compared, %d divergent" % bad)
        rc = 1 if bad else 0
    finally:
        proc.kill()
        proc.wait(timeout=10)
        shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
