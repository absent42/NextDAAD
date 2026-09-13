"""Decode NextDAAD's 80x32 tilemap into text, and recover what is new on
screen after a turn.

The tilemap is 80x32 cells of two bytes at TM_MAP. Even byte = glyph
index, which IS the ASCII code because GLYPH_SPACE equ $20. Odd byte =
the paper/ink attribute pair. ZEsarUX's get-ocr is ULA-based and cannot
read any of this, which is why the Dracula prior art fell back to
screenshots.
"""

COLS = 80
ROWS = 32
GRID_BYTES = COLS * ROWS * 2


def decode(grid, cols=COLS):
    """grid: cols * ROWS * 2 raw bytes (default 80 columns, unchanged
    behaviour for every existing caller). Returns (rows, attrs)."""
    expected = cols * ROWS * 2
    if len(grid) != expected:
        raise ValueError("expected %d bytes, got %d" % (expected, len(grid)))
    rows, attrs = [], []
    for r in range(ROWS):
        base = r * cols * 2
        chars, a = [], []
        for c in range(cols):
            g = grid[base + c * 2]
            a.append(grid[base + c * 2 + 1])
            chars.append(chr(g) if 32 <= g < 127 else " ")
        rows.append("".join(chars))
        attrs.append(a)
    return rows, attrs


def _trailing_blank_from(rows):
    """Index from which every row to the bottom of the grid is blank -
    i.e. how far the screen has NOT yet been filled with anything. ROWS
    itself means "no trailing blank run at all" (the screen is full)."""
    i = ROWS
    while i > 0 and not rows[i - 1].strip():
        i -= 1
    return i


def scroll_delta(pre, post):
    """Return the number of rows the screen scrolled up, or None if no
    shift explains the transition (a full redraw or a window clear).

    A row of `pre` that is blank AND part of `pre`'s trailing all-blank
    run is a wildcard: a trailing blank row holds no real content to
    preserve, so it must not block detecting a genuine scroll of the
    rows that DID carry content (a strict whole-window compare rejects
    any k where `pre`'s blank last row wouldn't equal `post`'s new one).
    """
    trailing_blank_from = _trailing_blank_from(pre)

    for k in range(ROWS):
        ok = True
        genuine_match = False   # True once a real (non-blank, non-wildcard)
                                 # row confirms this k - see docstring.
        for i in range(ROWS - k):
            if pre[k + i] == post[i]:
                if pre[k + i].strip():
                    genuine_match = True
                # Blank-vs-blank equality proves nothing about k (a blank
                # row matches any other blank row regardless of shift) -
                # excluded from genuine_match; see docstring.
                continue
            if k + i >= trailing_blank_from:
                continue          # pre's row here was never filled - wildcard
            ok = False
            break
        # Reject k with no genuine (non-wildcard, non-blank) match - a
        # large k can shrink the window entirely inside the wildcarded
        # tail, where every position "matches" without comparing anything.
        if ok and genuine_match:
            return k
    return None


def new_text(pre, post):
    """Rows that appeared this turn, in screen order, stripped of the
    tilemap's trailing space padding and with blank rows dropped.
    """
    k = scroll_delta(pre, post)
    if k is None:
        # Check if any rows stayed the same to distinguish rows-changed-in-place
        # from a true full redraw.
        if any(pre[i] == post[i] for i in range(ROWS)):
            # Rows changed in place
            out = []
            for i in range(ROWS):
                if pre[i] != post[i] and post[i].strip():
                    out.append(post[i].rstrip())
            return out
        else:
            # Full redraw or CLS: everything visible is new.
            return [r.rstrip() for r in post if r.strip()]
    if k == 0:
        # No scroll - report rows that changed in place.
        out = []
        for i in range(ROWS):
            if pre[i] != post[i] and post[i].strip():
                out.append(post[i].rstrip())
        return out
    # A clean k-row scroll normally means only the last k rows of `post`
    # are new (everything else is `pre` shifted up by k). But if `pre`
    # had its OWN trailing blank run, some of the "new" text may have
    # landed THERE instead of pushing anything off the top - scroll_delta
    # accepted those positions as wildcards, so new_text must include
    # them too, or the first line(s) that filled previously-blank space
    # go missing (confirmed live: without this, "50 F" was dropped while
    # "51 TYPE: get lamp" / "What now?>" - the two lines that genuinely
    # DID scroll - were kept). `_trailing_blank_from(pre) - k` is exactly
    # where that absorbed region starts in `post`'s coordinates.
    start = max(0, _trailing_blank_from(pre) - k)
    return [r.rstrip() for r in post[start:] if r.strip()]


def transition(pre, post):
    """Explain a screen transition. Returns
    {"shift": int or None, "ambiguous": bool}.

    ambiguous=True means no single whole-screen shift explains the
    transition AND at least one non-blank row appears to have MOVED -
    i.e. the screen both scrolled and changed in place, so new_text's
    row set cannot be trusted for this turn.
    """
    # Rule 1: Check if a clean shift explains everything
    k = scroll_delta(pre, post)
    if k is not None:
        return {"shift": k, "ambiguous": False}

    # Rule 2: a non-blank row whose content survives elsewhere in `pre`
    # counts as moved, even if no row survives at its own index - a
    # scroll can shift every row, so that is neither required nor
    # sufficient evidence either way. Must run unconditionally (same
    # wildcard/guard reasoning as scroll_delta, above).
    for i in range(ROWS):
        if not post[i].strip() or pre[i] == post[i]:
            continue
        if post[i] in pre:
            return {"shift": None, "ambiguous": True}

    # No rows moved, this is unambiguous - a genuine full redraw.
    return {"shift": None, "ambiguous": False}
