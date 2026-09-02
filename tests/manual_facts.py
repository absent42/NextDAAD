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
    (r"all\s+256\s+(?:\w+\s+)?(?:slots|colours|colors|entries|indices)"
     r"(?!.{0,80}\b255\b)",
     "255 slots are usable for art - index 255 is reserved"),
    (r"one\s+blue\s+LSB",
     "the collision nudge does not touch blue at all now; it moves green "
     "ONE step up the 0-7 scale, $E3 -> $E7"),
    (r"two\s+steps\s+down\s+the\s+blue\s+scale",
     "superseded manual wording for the collision nudge; it moves green "
     "one step UP the 0-7 scale now, $E3 -> $E7, and never touches blue"),
    # Sprites have a transparent COLOUR, never a transparent attribute -
    # the only thing that ever had a "transparent attribute" was the
    # deleted tilemap mechanism. A hit here is either describing that
    # deleted mechanism (a real catch) or misdescribing sprites (also
    # worth fixing, by saying "colour" instead). Do not loosen this on
    # the assumption it is over-broad; it isn't.
    (r"transparent\s+attribute",
     "the tilemap has no transparency; that attribute was deleted"),
    (r"TM_TRANSP_ATTR|TM_TRANSP_PAIR",
     "both constants were deleted on 2026-08-06"),
    # The GFX n 17 layer order used to be documented as transient, with a
    # reset list. Owner rulings 2026-08-18 made it game-owned: boot leaves
    # it at picture on top and NOTHING in the interpreter changes it after
    # that, so a restored save keeps the order the game chose. (?s) is
    # local DOTALL - the claim always straddles a wrapped line.
    (r"(?s)resets?\s+to\s+picture[-\s]?on[-\s]?top(?=.{0,140}"
     r"(?:RESTART|RAMLOAD|LOAD))|"
     r"(?:RESTART|RAMLOAD|LOAD).{0,140}"
     r"resets?\s+to\s+picture[-\s]?on[-\s]?top",
     "the layer order is game-owned and the interpreter never resets it "
     "after boot - not on RESTART, LOAD, RAMLOAD, game start or a part "
     "switch (owner rulings 2026-08-18)"),
    # XBN v1 retired facts. XBN format 2 (SP19) moved and grew the header
    # and the service table; a page still describing format 1 is stale.
    (r"\$C00A",
     "the CALL slot table moved to $C00E in XBN format 2"),
    (r"\bten (small routines|three-byte|services)\b",
     "the service table has fifteen rows since format 2"),
    (r"version byte reads .\b1\b.",
     "the format 2 header is fourteen bytes, version 2"),
    (r"Ten bytes at the start",
     "the format 2 header is fourteen bytes, version 2"),
    # Spec 3.1 edge: the CF-fail clears a stamp a failed built-in
    # condition never touches. \s+ - the claim wraps across lines.
    (r"done\s+stat(e|us)[^.]{0,40}same\s+as\s+a\s+failed",
     "a CF-failed EXTERN clears the done state, which a failed built-in "
     "condition never does - do not equate them"),
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

    # --- text-over-picture reservation (colours.md) ----------------
    # TXT_TRANSP_COLOUR does not carry its own hex literal - it resolves
    # through L2_TRANSP_COLOUR - so follow the chain rather than
    # hardcoding 227. The point of this guard is that the manual
    # follows the source, not a number typed into the checker.
    custom_doc = MANUAL / "colours.md"
    custom_text = custom_doc.read_text(encoding="utf-8")
    txt_transp_ref = parse("src/nextdaad.inc",
                           r"(?m)^\s*TXT_TRANSP_COLOUR\s+equ\s+(\w+)",
                           "TXT_TRANSP_COLOUR")
    if txt_transp_ref != "L2_TRANSP_COLOUR":
        failures.append(
            f"TXT_TRANSP_COLOUR now resolves through {txt_transp_ref}, "
            f"not L2_TRANSP_COLOUR - update this checker's resolution "
            f"chain")
    else:
        transp_decimal = int(colour, 16)
        if not re.search(
                rf"transparent.{{0,60}}\b{transp_decimal}\b|"
                rf"\b{transp_decimal}\b.{{0,60}}transparent",
                custom_text, re.IGNORECASE | re.DOTALL):
            failures.append(
                f"colours.md never states {transp_decimal} "
                f"(TXT_TRANSP_COLOUR, via L2_TRANSP_COLOUR = ${colour}) "
                f"next to the word 'transparent'")

    if not re.search(r"previews\s+colour\s+`?n`?\s+at\s+index\s+`?n`?",
                     custom_text, re.IGNORECASE):
        failures.append(
            "colours.md: the 'previews colour n at index n' "
            "sentence is gone - if it was reworded, update this checker "
            "to match")
    elif not re.search(
            r"one\s+value\s+is\s+reserved.{0,600}PAPER\s+227.{0,600}"
            r"BORDER\s+227",
            custom_text, re.IGNORECASE | re.DOTALL):
        failures.append(
            "colours.md: the previews-colour-n-at-index-n promise "
            "has lost its 227 carve-out (PAPER 227 transparent paper, "
            "INK 227 transparent glyphs, BORDER 227 stays magenta, "
            "colour 11 shift) - a paint tool does not preview 227 "
            "correctly and readers need to be told")

    # --- videnc flags vs argparse ---------------------------------
    # vidtune-maintenance.md records this drifting silently for FOUR
    # options because nothing ever ran the diff.
    enc = (ROOT / "authoring-kit/lib/videnc.py").read_text(
        encoding="utf-8", errors="replace")
    real = set(re.findall(r"add_argument\(\s*['\"](--[a-z0-9-]+)", enc))
    # argparse ADDS -h/--help itself, so it is accepted without ever
    # appearing in an add_argument call - scanning only those calls made
    # a documented `--help` look undocumented. The flag is real unless
    # the parser opts out with add_help=False, so read that rather than
    # whitelisting the name unconditionally: a parser built with
    # add_help=False really would reject `--help` and the manual really
    # would be wrong to document it.
    if not re.search(r"ArgumentParser\((?:[^()]|\([^()]*\))*add_help\s*=\s*False",
                     enc, re.DOTALL):
        real.update({"--help"})
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
