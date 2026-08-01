"""Normalise interpreter text so an 80-column NextDAAD screen can be
compared against jDAAD's differently-wrapped output.

What is deliberately NOT normalised: case and punctuation. A wrong
capital or a missing full stop in a system message is a real bug and must
stay visible.
"""

# jleg.js annotates every clearCurrentWindow() with this marker line. It
# is the HARNESS talking, not jDAAD - no character of it comes from the
# game - and the Next leg emits no counterpart, because a tilemap capture
# sees a cleared window only as a full redraw, with no marker to match.
# Left in the compared stream it therefore diverges on EVERY window-clear
# turn no matter what either interpreter did, which is not a signal at
# all: it fires identically whether NextDAAD cleared the window correctly
# or not. Five of the twenty-one Dracula baseline findings were nothing
# but this. Dropped for COMPARISON only - report.py's transcript prints
# the raw captured text, so a reader still sees exactly where the
# reference cleared its window.
#
# The real CLS comparison this does not attempt: detecting a window clear
# on the Next side (tilemap.transition already distinguishes a genuine
# full redraw) and comparing that against the marker. That would be a new
# capability, not a repair, and is left for a later wave.
CLS_MARKER = "---[CLS]---"


def normalise(text):
    """Return logical paragraphs. A blank line separates paragraphs;
    within a paragraph, wrapped lines are rejoined and whitespace runs
    collapse to a single space. The jleg.js CLS marker (see CLS_MARKER)
    contributes no words - it is harness annotation, not content - but it
    DOES break the paragraph, because a window clear is the strongest
    separator there is: the text after it was never on screen with the
    text before it. Skipping the line outright (which this used to do)
    ran the two together into one paragraph and could join the last
    sentence of a cleared screen to the first sentence of the next.
    """
    paras, current = [], []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.strip() == CLS_MARKER:
            if current:
                paras.append(" ".join(current))
                current = []
            continue
        if line.strip():
            # Strip leading indentation: DAAD centres menu text with leading
            # spaces, and that indentation is width-driven whitespace we
            # intend to normalise away, not content.
            current.append(line.strip())
        elif current:
            paras.append(" ".join(current))
            current = []
    if current:
        paras.append(" ".join(current))
    return [" ".join(p.split()) for p in paras]


def tokens(text):
    """Flat token sequence for comparison."""
    out = []
    for para in normalise(text):
        out.extend(para.split())
    return out
