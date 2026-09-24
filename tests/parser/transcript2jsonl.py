r"""TRANS.TXT (NextDAAD transcript module) -> harness per-turn JSONL.
Usage: python tests\parser\transcript2jsonl.py TRANS.TXT out.jsonl
Lines end in $0D. ">>cmd" starts a turn, "##" lines are labels (dropped),
the flag 49 echo of the command is dropped when it is the turn's first
line. Bytes 16-31 are DAAD's accent glyphs; the order below is DRC's
(verify against DRF's ConvertChars in D:\DRC before relying on it for an
accented game)."""
import json, sys

ACCENTS = "\u00aa\u00a1\u00bf\u00ab\u00bb\u00e1\u00e9\u00ed\u00f3\u00fa\u00f1\u00d1\u00e7\u00c7\u00fc\u00dc"


def decode(raw):
    out = []
    for b in raw:
        if 16 <= b <= 31:
            out.append(ACCENTS[b - 16])
        elif b == 0x0D:
            out.append("\n")
        else:
            out.append(chr(b))
    return "".join(out)


def parse(text):
    turns, cur = [], None
    for line in text.split("\n"):
        if line.startswith(">>"):
            if cur is not None:
                turns.append(cur)
            cur = {"command": line[2:], "lines": []}
        elif line.startswith("##"):
            continue
        elif cur is not None:
            cur["lines"].append(line)
    if cur is not None:
        turns.append(cur)
    out = []
    for t in turns:
        lines = t["lines"]
        if lines and lines[0].strip().upper() == t["command"].strip().upper():
            lines = lines[1:]
        out.append({"command": t["command"],
                    "text": "\n".join(lines).strip()})
    return out


def main(argv):
    src, dst = argv[1], argv[2]
    with open(src, "rb") as fh:
        turns = parse(decode(fh.read()))
    with open(dst, "w", encoding="utf-8") as fh:
        for t in turns:
            fh.write(json.dumps(t) + "\n")
    print("%d turns -> %s" % (len(turns), dst))


if __name__ == "__main__":
    main(sys.argv)
