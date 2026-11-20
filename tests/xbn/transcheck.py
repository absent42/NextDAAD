r"""Transcript single-turn diff: tilemap capture vs TRANS.TXT's LAST
surviving write, for one recorded turn. Multi-turn file diffs need
silicon.

On CSpect the file leg is silicon-only: a write through a mode $03
handle (existing file opened read/write, as the transcript module does)
reports success and never reaches the host file, so TRANS.TXT stays
empty. When it is empty the file diff prints SILICON-ONLY (neither PASS
nor FAIL); the screen capture and the error code still run.

Usage: python tests\xbn\transcheck.py sd\XBN ARM CONTENT STOP
Needs the leg staged by tests\build-tests.ps1 -Xbn -XbnTrans, which
carries the toolkit+transcript subset instead of the plain fixture.
Exactly three verbs. ARM arms recording (its own line is typed before
fn 90 arms, so it never reaches the file); CONTENT is the turn under
test; STOP's line hook is what flushes CONTENT's queued output, and
that is the LAST flush of the run, so it is the one that survives.
Exit 1 on divergence, 2 on a usage error."""
import argparse, pathlib, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "parser"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import tilemap, normalise, transcript2jsonl, xbnrun  # noqa: E402

WIN_TOP, WIN_ROWS = 12, 16

PROMPT = "What now?>"   # SM2 (flag 42 pinned to 2) then SM33, appended to
                        # the response row with no newline of its own


def screen_turn(s, cols):
    # Both sides end with the NEXT turn's prompt on the last response line;
    # strip_prompt removes the suffix, dropping the line only if nothing remains.
    rows, _ = tilemap.decode(s.read(xbnrun.TM_MAP, cols * tilemap.ROWS * 2), cols=cols)
    body = [r.rstrip() for r in rows[WIN_TOP:WIN_TOP + WIN_ROWS] if r.strip()]
    return "\n".join(transcript2jsonl.strip_prompt(body, PROMPT))


def extract_content(raw, content_verb):
    """raw = TRANS.TXT bytes; the text after the last NUL (if any) is the
    surviving write. Returns the CONTENT turn's text (before the final
    ">>"-marker line, command echo and prompt suffix stripped), or None
    if no ">>" marker is found."""
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
    ap.add_argument("--wait", type=float, default=3.0,
                    help="emulated seconds to wait after each verb's ENTER")
    ap.add_argument("--cols", type=int, default=80)
    args = ap.parse_args()
    if len(args.verbs) != 3:
        ap.error("expects exactly three verbs: ARM CONTENT STOP")
    arm, content, stop = args.verbs
    leg = (ROOT / args.leg).resolve()
    work, card = xbnrun.stage_card(leg)
    wait_frames = max(1, round(args.wait * 50))
    rc = 1
    try:
        screen = {}
        with xbnrun.boot(card) as s:
            xbnrun.wait_ready(s)
            xbnrun.disarm_input_timeout(s)
            for verb in args.verbs:
                s.type_text(verb)
                s.wait_frames(2, xbnrun.FRAME_TIMEOUT_S)
                s.enter()
                s.wait_frames(wait_frames, max(xbnrun.FRAME_TIMEOUT_S, args.wait * 20))
                xbnrun.wait_ready(s)
                screen[verb] = screen_turn(s, args.cols)
            err = s.read(s.sym("ERRCODE"), 1)[0]
        ok_screen = bool(screen[content]) and not err
        print("%s content turn on screen (%d chars), ERRCODE %d"
              % ("PASS" if ok_screen else "FAIL", len(screen[content]), err))
        src = card / "TRANS.TXT"
        raw = src.read_bytes() if src.exists() else b""
        if not raw.strip(b"\x00"):
            print("SILICON-ONLY transcript file diff: TRANS.TXT empty (%d bytes); "
                  "CSpect drops mode $03 writes" % len(raw))
            return 0 if ok_screen else 1
        shutil.copyfile(src, ROOT / "tests" / "out" / "xbn" / "TRANS.TXT")
        rtext = extract_content(raw, content)
        if rtext is None:
            raise SystemExit("no >> marker found in the surviving flush region")
        bad = 0
        if normalise.tokens(screen[content]) != normalise.tokens(rtext):
            bad = 1
            print("DIVERGE %s\n  screen: %r\n  file:   %r" % (content, screen[content], rtext))
        print("1 turn compared, %d divergent" % bad)
        rc = 1 if bad or not ok_screen else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
