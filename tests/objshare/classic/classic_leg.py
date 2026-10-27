"""Walk loop and compare shared by drive_cpc.py and drive_msx1.py.

A machine adaptor supplies: read() -> raw screen bytes, decode(raw) ->
lines, png(raw, path), type(cmd), enter(), space(). Turn text, More...
handling and prompt trimming follow drive_zx48.py (emit_text, load_stx)
and tests/parser/zleg.py.
"""
import hashlib
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(ROOT / "tests" / "parser"))
sys.path.insert(0, str(HERE))
import zleg          # noqa: E402
import drive_zx48    # noqa: E402

POLL_S = 0.25
STABLE_POLLS = 4
PAUSE_POLLS = 8
TURN_TIMEOUT_S = 60.0
BOOT_TIMEOUT_S = 180.0
MAX_PAGES = 20
MORE = "More..."


def settle(m, baseline, limit, tag, poll=POLL_S):
    """Wait for the line editor caret; dismiss More... pages with SPACE.

    Returns (final raw, final lines, [(raw, lines, kind)]).
    """
    deadline = time.time() + limit
    last, static, moved, pages = None, 0, baseline is None, []
    while time.time() < deadline:
        raw = m.read()
        if raw == last:
            static += 1
        else:
            static, last = 0, raw
        if baseline is not None and raw != baseline:
            moved = True
        if moved and static >= STABLE_POLLS:
            lines = m.decode(raw)
            if zleg.has_cursor(lines):
                return raw, lines, pages
            more = bool(lines) and MORE in lines[-1]
            if more or static >= PAUSE_POLLS:
                if len(pages) >= MAX_PAGES:
                    raise TimeoutError("%s: %d pages without a prompt"
                                       % (tag, len(pages)))
                pages.append((raw, lines, "more" if more else "nocursor"))
                m.space()
                static, last = 0, None
                continue
        time.sleep(poll)
    raise TimeoutError("%s: no prompt within %.0fs, last lines %r"
                       % (tag, limit, m.decode(last)[-3:] if last else []))


def sha(raw):
    return hashlib.sha1(raw).hexdigest()


def walk(m, walk_path, out, say, prompts):
    """Boot settle plus every walk.txt line; writes transcript files."""
    t0 = time.time()
    cmds = [l.strip() for l in Path(walk_path).read_text().splitlines()
            if l.strip()]
    boot, blines, bpages = settle(m, None, BOOT_TIMEOUT_S, "boot")
    m.png(boot, out / "step00_boot.png")
    say("booted after %.1fs, %d page(s)" % (time.time() - t0, len(bpages)))
    steps = [{"step": 0, "command": "(boot)", "screen": blines,
              "pages": len(bpages), "sha1": sha(boot)}]
    for i, cmd in enumerate(cmds, 1):
        m.type(cmd)
        pre_raw = m.read()
        m.enter()
        post, final, pages = settle(m, pre_raw, TURN_TIMEOUT_S,
                                    "step %d %s" % (i, cmd))
        pre = m.decode(pre_raw)
        caps = []
        for k, (raw, lines, kind) in enumerate(pages, 1):
            m.png(raw, out / ("step%02d_page%d.png" % (i, k)))
            caps.append(zleg.drop_pager_prompt(lines, MORE))
        text, redraw = drive_zx48.emit_text(pre, caps,
                                            [k for _, _, k in pages],
                                            final, prompts)
        m.png(post, out / ("step%02d.png" % i))
        steps.append({"step": i, "command": cmd, "text": text,
                      "redraw": redraw, "pages": [k for _, _, k in pages],
                      "page_screens": caps, "screen": final,
                      "sha1": sha(post),
                      "page_sha1": [sha(r) for r, _, _ in pages]})
        say("step %02d %-16s %d line(s) %d page(s)%s"
            % (i, cmd, len(text), len(pages), " [redraw]" if redraw else ""))
    with open(out / "transcript.jsonl", "w", encoding="utf-8") as fh:
        for s in steps:
            fh.write(json.dumps(s) + "\n")
    with open(out / "transcript.txt", "w", encoding="utf-8") as fh:
        for s in steps[1:]:
            fh.write("== %02d %s\n" % (s["step"], s["command"]))
            for l in s["text"]:
                fh.write(l + "\n")


def load_steps(d):
    return [json.loads(l) for l in
            (Path(d) / "transcript.jsonl").read_text(encoding="utf-8")
            .splitlines() if l.strip()]


def no_prompts(lines, prompts):
    return [l for l in lines if zleg._norm(l) not in prompts]


def compare(test_dir, ctl_dir, md_path, dsf=None):
    """Per-step table; verdict = decoded text and More... pauses equal.

    Also reported: raw screen memory equal, and the decoded final and paged
    screens equal once the random SM2-SM5 prompt rows are removed.
    """
    prompts = zleg.prompt_set(drive_zx48.load_stx(
        dsf or HERE.parent / "OBJVERIF.DSF"))
    t, c = load_steps(test_dir), load_steps(ctl_dir)
    rows, fails = [], 0
    for a, b in zip(t[1:], c[1:]):
        text_ok = a["command"] == b["command"] and a["text"] == b["text"]
        verdict = "PASS" if text_ok and a["pages"] == b["pages"] else "FAIL"
        fails += verdict == "FAIL"
        same = a["sha1"] == b["sha1"] and a["page_sha1"] == b["page_sha1"]
        scr_eq = all(no_prompts(x, prompts) == no_prompts(y, prompts)
                     for x, y in zip([a["screen"]] + a["page_screens"],
                                     [b["screen"]] + b["page_screens"]))
        ctl_text = " / ".join(b["text"]) or "(nothing)"
        test_text = " / ".join(a["text"]) or "(nothing)"
        rows.append((a["step"], a["command"], verdict,
                     "yes" if same else "no", "yes" if scr_eq else "no",
                     "%d/%d" % (len(a["pages"]), len(b["pages"])), ctl_text,
                     "same" if test_text == ctl_text else test_text))
    if len(t) != len(c):
        fails += 1
    md = ["| Step | Command | Result | Screen memory identical | Screen "
          "text identical, prompts removed | More... pages (test/ctl) | "
          "Control text | Test text |",
          "|---:|---|---|---|---|---|---|---|"]
    for r in rows:
        md.append("| %d | %s | %s | %s | %s | %s | %s | %s |"
                  % (r[:6] + tuple(x.replace("|", "\\|") for x in r[6:])))
    md.append("")
    nsame = sum(1 for r in rows if r[3] == "yes")
    neq = sum(1 for r in rows if r[4] == "yes")
    md.append("%d step(s), %d FAIL; screen memory identical on %d, screen "
              "text identical with prompts removed on %d of %d steps (final "
              "and paged screens); boot screen memory identical: %s, boot "
              "text identical with prompts removed: %s"
              % (len(rows), fails, nsame, neq, len(rows),
                 "yes" if t[0]["sha1"] == c[0]["sha1"] else "no",
                 "yes" if no_prompts(t[0]["screen"], prompts)
                 == no_prompts(c[0]["screen"], prompts) else "no"))
    Path(md_path).write_text("\n".join(md) + "\n", encoding="utf-8")
    print(md[-1])
    return 1 if fails else 0
