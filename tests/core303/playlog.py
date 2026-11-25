#!/usr/bin/env python3
"""Parse NXPLAY.TXT (the DEBUG log step's mode 16, after every GO or LOOP of the test game)
into one markdown row per capture.

Usage: python tests/core303/playlog.py NXPLAY.TXT [--out playback.md]

A capture is the header "#PLAY ccc pp ffff s v" (ccc = flag 140 in decimal, the clip PICK armed;
pp = vidPoolAtOpen, the free pool banks before that open, FF = no open ran; ffff =
frameCounter; s = the sound path, S stereo or non-raw, C mono from CTC 0, D mono from the
zxnDMA, - when no open staged a session; v = the raw reader, T column train, I inline, - on a
non-raw session) and the non-empty screen rows 23-27: the open-refusal row, then the timeline
report rows (FRM, RING, PLAY, LATE). A header without s and v (an older image) gives "-" for
both. The table's Step is the capture number; raw_fit.read_playback reads its Step, Clip, SND,
VAR, PLAY, FRM, LATE and URUN columns. Absent fields print "-".

A capture cut short (a line without its end, a field of the wrong width, a header cut, or the
next capture's header written onto a partial line by a short F_WRITE) is kept as a row whose
Row 23 starts TRUNCATED and whose report fields are all "-". Exit 0, or 2 when the file holds
no capture or does not start with one.
"""
import argparse
import re
import sys
from pathlib import Path

COLUMNS = ["Step", "Clip", "Pool", "SND", "VAR", "Row 23", "FRM", "ERR", "OP", "POS", "PASS",
           "RING", "FILL", "SNAP", "PLAY", "NOM", "CHK", "LATE", "MAXL", "URUN", "RUNS"]
FIELDS = COLUMNS[6:]
# hex digits per part, from vid_tl_report_body (src/video.asm)
WIDTHS = {"FRM": (4, 4), "ERR": (2,), "OP": (2,), "POS": (6,), "PASS": (2,),
          "RING": (4, 4, 2), "FILL": (4,), "SNAP": (2,), "PLAY": (4,), "NOM": (4,),
          "CHK": (8,), "LATE": (4,), "MAXL": (4,), "URUN": (4,), "RUNS": (2,)}
assert list(WIDTHS) == FIELDS
POOL_NONE = "FF"

HEADER = "#PLAY "
HEADER_RE = re.compile(r"#PLAY (\d{3}) ([0-9A-F]{2}) ([0-9A-F]{4})(?: ([SCD-]) ([TI-]))?")
REPORT_ROW = re.compile(r"\s*(FRM|RING|PLAY|LATE)\s*=")
PAIR = re.compile(r"([A-Z]+)\s*=([0-9A-F/]*)")


class PlayLogError(Exception):
    pass


def _unended(part):
    """A line that lost its end, split before a header cut to "#".."#PLAY" at its tail
    ("#" appears in the log only at a header)."""
    at = part.rfind("#")
    if at > 0 and HEADER.startswith(part[at:]):
        yield part[:at], False
        part = part[at:]
    yield part, False


def _lines(text):
    """(content, ended) per line; a #PLAY header inside a line starts a new one, and the
    part before it is a line that lost its end."""
    for piece in text.splitlines(keepends=True):
        body = piece.rstrip("\r\n")
        ended = body != piece
        parts, at = [], body.find(HEADER, 1)
        while at > 0:
            parts.append(body[:at])
            body = body[at:]
            at = body.find(HEADER, 1)
        for p in parts:
            yield from _unended(p)
        if ended:
            yield body, True
        else:
            yield from _unended(body)


def _is_header(line):
    return line.startswith(HEADER.rstrip()) or (line.startswith("#") and HEADER.startswith(line))


def _report_ok(line, cap):
    """Fill cap from a report row; False when the row is malformed."""
    pairs = PAIR.findall(line)
    if PAIR.sub("", line).strip() or not pairs:
        return False
    for key, value in pairs:
        parts = value.split("/")
        if key not in WIDTHS or cap[key] != "-" or [len(p) for p in parts] != list(WIDTHS[key]):
            return False
        cap[key] = value
    return True


def parse_playlog(path):
    """[{column: cell}] in COLUMNS order, one per capture."""
    caps, extra = [], []
    for n, (line, ended) in enumerate(_lines(Path(path).read_bytes().decode("latin-1")), 1):
        if not line.strip() and ended:
            continue
        if _is_header(line):
            cap = dict.fromkeys(COLUMNS, "-")
            cap["Step"] = str(len(caps) + 1)
            m = HEADER_RE.fullmatch(line)
            words = line[len(HEADER):].split(" ") if line.startswith(HEADER) else []
            if len(words) > 0 and re.fullmatch(r"\d{3}", words[0]):
                cap["Clip"] = words[0]
            if len(words) > 1 and re.fullmatch(r"[0-9A-F]{2}", words[1]):
                cap["Pool"] = "-" if words[1] == POOL_NONE else words[1]
            if m and m.group(4):
                cap["SND"], cap["VAR"] = m.group(4), m.group(5)
            caps.append(cap)
            extra.append({"row23": [], "cut": not (m and ended)})
        elif not caps:
            raise PlayLogError("line %d: %r before the first #PLAY header" % (n, line))
        elif REPORT_ROW.match(line):
            if not (ended and _report_ok(line, caps[-1])):
                extra[-1]["cut"] = True
        else:
            extra[-1]["row23"].append(line.strip())
            extra[-1]["cut"] |= not ended
    if not caps:
        raise PlayLogError("no #PLAY capture")
    for cap, x in zip(caps, extra):
        text = " / ".join(t for t in x["row23"] if t)
        if x["cut"]:
            cap.update(dict.fromkeys(FIELDS, "-"))
            text = "TRUNCATED" + (": " + text if text else "")
        cap["Row 23"] = text or "-"
    return caps


def markdown(caps, source):
    out = ["# Play log %s - %d captures" % (source, len(caps)), "",
           "| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS)]
    for cap in caps:
        out.append("| " + " | ".join(cap[k].replace("|", "&#124;") for k in COLUMNS) + " |")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="NXPLAY.TXT to a markdown table")
    ap.add_argument("log")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    try:
        caps = parse_playlog(a.log)
    except (OSError, PlayLogError) as exc:
        print("playlog: %s" % exc, file=sys.stderr)
        return 2
    text = markdown(caps, Path(a.log).name)
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
