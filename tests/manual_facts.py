"""Guard the manual against drift.

Two kinds of check, because they fail differently:

NEGATIVE - superseded values that must never reappear. These are the ones
that actually caught things during the Layer 2 transparency work: the root
README sat wrong for a day because nothing looked for the old value.

POSITIVE - values parsed from source and compared against what the manual
says. Same mechanism as build-tests.ps1's Assert-TranspConstantsInSync,
extended to prose.

Line-number citations (overlay2.asm:1773) are deliberately NOT validated:
brittle, would fail on unrelated edits, and the churn trains everyone to
ignore the checker.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANUAL = ROOT / "manual"

# (regex, why it is wrong now). Case-insensitive, searched across every
# manual document. When a value changes, its predecessor joins this list.
FORBIDDEN = [
    (r"\$FE\b.{0,40}transparen|transparen.{0,40}\$FE",
     "$FE was the transparency colour before 2026-08-06; it is $E3 now"),
    (r"index\s+254|entry\s+254",
     "the reserved palette index is 255, not 254"),
    (r"all\s+256\s+(slots|colours|colors)",
     "255 slots are usable for art - index 255 is reserved"),
    (r"one\s+blue\s+LSB",
     "the collision nudge moves blue TWO steps of the 0-7 scale, not one"),
    (r"transparent\s+attribute",
     "the tilemap has no transparency; that attribute was deleted"),
    (r"TM_TRANSP_ATTR|TM_TRANSP_PAIR",
     "both constants were deleted on 2026-08-06"),
]

def parse(path, pattern, label):
    text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
    m = re.search(pattern, text)
    if not m:
        sys.exit(f"ERROR: cannot find {label} in {path} - the checker is "
                 f"out of date with the source, fix the checker")
    return m.group(1)

def main():
    if not MANUAL.is_dir():
        print("no manual/ yet - nothing to check")
        return 0

    docs = sorted(MANUAL.rglob("*.md"))
    failures = []

    # --- negative -------------------------------------------------
    for doc in docs:
        text = doc.read_text(encoding="utf-8")
        for pattern, why in FORBIDDEN:
            for m in re.finditer(pattern, text, re.IGNORECASE):
                line = text[: m.start()].count("\n") + 1
                failures.append(
                    f"{doc.relative_to(ROOT)}:{line}: forbidden "
                    f"'{m.group(0).strip()}' - {why}")

    # --- positive -------------------------------------------------
    colour = parse("src/nextdaad.inc",
                   r"(?m)^\s*L2_TRANSP_COLOUR\s+equ\s+\$([0-9A-Fa-f]+)",
                   "L2_TRANSP_COLOUR")
    index = parse("src/nextdaad.inc",
                  r"(?m)^\s*L2_TRANSP_INDEX\s+equ\s+(\d+)",
                  "L2_TRANSP_INDEX")

    joined = "\n".join(d.read_text(encoding="utf-8") for d in docs)
    if re.search(r"#E000C0", joined, re.IGNORECASE) and colour.upper() != "E3":
        failures.append(
            f"manual states #E000C0 but L2_TRANSP_COLOUR is ${colour} - "
            f"the paint-program value and the register value disagree")
    if re.search(r"\breserved\b.{0,40}\bindex\b", joined, re.IGNORECASE):
        if index != "255":
            failures.append(
                f"manual describes a reserved index but L2_TRANSP_INDEX "
                f"is {index}")

    # --- videnc flags vs argparse ---------------------------------
    # vidtune-maintenance.md records this drifting silently for FOUR
    # options because nothing ever ran the diff.
    enc = (ROOT / "authoring-kit/lib/videnc.py").read_text(
        encoding="utf-8", errors="replace")
    real = set(re.findall(r"add_argument\(\s*['\"](--[a-z0-9-]+)", enc))
    documented = set(re.findall(r"`(--[a-z0-9-]+)`", joined))
    for flag in sorted(documented - real):
        failures.append(
            f"manual documents {flag}, which videnc.py does not accept")

    if failures:
        print("MANUAL FACT CHECK FAILED\n")
        for f in failures:
            print("  " + f)
        print(f"\n{len(failures)} problem(s)")
        return 1

    print(f"manual fact check: {len(docs)} document(s) clean")
    return 0

if __name__ == "__main__":
    sys.exit(main())
