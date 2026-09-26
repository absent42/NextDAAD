r"""TRANS.TXT (NextDAAD transcript module) -> harness per-turn JSONL.
Usage: python tests\parser\transcript2jsonl.py TRANS.TXT out.jsonl
    [--prompt TEXT]
Lines end in $0D. ">>cmd" starts a turn, "##" lines are labels (dropped),
the flag 49 echo of the command is dropped when it is the turn's first
line. --prompt strips TEXT from the end of each turn's last line,
dropping the line if nothing remains (default: no strip - pass it when
the source was captured with the next prompt glued to the last response
line). Bytes 16-31 are DAAD's accent glyphs; the order below matches
DRF's ConvertChars codes 16-31."""
import argparse, json, sys

ACCENTS = "ª¡¿«»áéíóúñÑçÇüÜ"


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


def strip_prompt(lines, prompt):
    r"""Remove `prompt` from the end of the last line, dropping the line
    if nothing remains. Same logic tests\xbn\transcheck.py applies to a
    tilemap capture, shared from here so both comparisons treat a prompt
    suffix the same way."""
    if prompt and lines:
        last = lines[-1].rstrip()
        if last.endswith(prompt):
            last = last[:-len(prompt)].rstrip()
            lines = lines[:-1] + ([last] if last else [])
    return lines


def parse(text, prompt=None):
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
        lines = strip_prompt(lines, prompt)
        out.append({"command": t["command"],
                    "text": "\n".join(lines).strip()})
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--prompt", default=None,
                     help="strip this suffix from each turn's last line (default: no strip)")
    args = ap.parse_args(argv[1:])
    with open(args.src, "rb") as fh:
        turns = parse(decode(fh.read()), args.prompt)
    with open(args.dst, "w", encoding="utf-8") as fh:
        for t in turns:
            fh.write(json.dumps(t) + "\n")
    print("%d turns -> %s" % (len(turns), args.dst))


if __name__ == "__main__":
    main(sys.argv)
