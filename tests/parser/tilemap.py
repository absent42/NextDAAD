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


def decode(grid):
    """grid: GRID_BYTES raw bytes. Returns (rows, attrs)."""
    if len(grid) != GRID_BYTES:
        raise ValueError("expected %d bytes, got %d" % (GRID_BYTES, len(grid)))
    rows, attrs = [], []
    for r in range(ROWS):
        base = r * COLS * 2
        chars, a = [], []
        for c in range(COLS):
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
    run (every row from there to the bottom of the grid is also blank -
    the screen simply had not filled that far yet) is a wildcard: it
    holds no real content to preserve, so new text landing there must
    not block detecting the shift that genuinely happened to the rows
    that DID carry content.

    Diagnosed live (tests/parser/work/e2e-clean, turn 0, condacts.dsf's
    QUIT confirmation): `pre` had exactly one trailing blank row (the
    screen was one line short of full); the interpreter then printed
    three new lines - the first fills that formerly-blank row, and only
    the other two actually push content off the top, a genuine 2-row
    scroll. A strict whole-window compare rejected k=2 anyway, because
    it required `pre`'s blank last row to equal `post`'s new last row
    verbatim - the ONE position where "nothing was there before"
    legitimately does not match "something is there now". That single
    rejected position was enough to make every k fail, so the caller
    (new_text/transition) fell back to treating a clean scroll as a
    full screen redraw and returned nearly the whole screen as "new".
    """
    trailing_blank_from = _trailing_blank_from(pre)

    for k in range(ROWS):
        ok = True
        genuine_match = False   # at least one position actually verified
                                 # against REAL content, not merely excused
                                 # by the wildcard, and not a blank-vs-blank
                                 # coincidence - see below for why both
                                 # exclusions are required.
        for i in range(ROWS - k):
            if pre[k + i] == post[i]:
                if pre[k + i].strip():
                    genuine_match = True
                # Two rows that are EQUAL because both are blank prove
                # nothing about k: a blank row carries no content, so it
                # matches any other blank row regardless of whether a
                # shift by k is what actually happened. Diagnosed live
                # (tests/parser/work/rabenstein-probe, turns 1-4): `pre`
                # had a long trailing blank run (rows past its own last
                # printed line) and `post` independently had its OWN
                # leading blank run (unrelated screen real estate never
                # used by this game's layout) - large k values land the
                # entire compared window on blank-vs-blank pairs, which
                # satisfied the old bare-equality check at EVERY position,
                # wrongly "confirming" a scroll by k = trailing_blank_from
                # (or higher) even when zero real content moved. That
                # bogus k then made new_text() re-emit almost the whole
                # screen as "new" on every turn, accumulating turn over
                # turn - the reported "text offset by one turn" symptom.
                # Requiring the matched content to be non-blank closes
                # this without weakening the genuine wildcard case above
                # (t11_scroll_delta_wildcards_pres_trailing_blank_run's
                # k=2 match is confirmed by real, non-blank row content,
                # not by this coincidence).
                continue
            if k + i >= trailing_blank_from:
                continue          # pre's row here was never filled - wildcard
            ok = False
            break
        # Large k shrinks the compared window down to almost nothing, and
        # for k close to ROWS that shrunken window can fall ENTIRELY
        # inside pre's wildcarded tail - every position "matches" only
        # because nothing real was being compared at all, not because a
        # shift by k genuinely explains anything. Confirmed live: without
        # requiring at least one real (non-wildcarded), non-blank match, a
        # completely unrelated post could still spuriously "succeed" at
        # k = trailing_blank_from or higher.
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

    # Rule 2: Check if any non-blank row has moved - i.e. its content
    # survives somewhere in `pre`, just not at the SAME index.
    #
    # This must run unconditionally, not only when some OTHER row
    # happens to survive at its own index. Diagnosed live
    # (tests/parser/work/e2e-clean, turn 11): a transition can be a
    # near-perfect scroll (25+ rows individually confirmed to have moved
    # by an identical shift) that nonetheless has ZERO rows surviving at
    # their own index - every row shifted, so none happened to land back
    # where it started. A prior "no row survived at its own index -> not
    # ambiguous, full redraw" early-exit ran BEFORE this check and
    # therefore never saw that overwhelming moved-row evidence, wrongly
    # reporting an ordinary (if scroll_delta-defeating) scroll as an
    # unambiguous full redraw. Whether some row happens to also survive
    # at its own index is neither necessary for a screen to have moved
    # rows, nor sufficient to rule it out - it says nothing one way or
    # the other, so it must not gate this loop from running at all.
    for i in range(ROWS):
        if not post[i].strip() or pre[i] == post[i]:
            continue
        if post[i] in pre:
            return {"shift": None, "ambiguous": True}

    # No rows moved, this is unambiguous - a genuine full redraw.
    return {"shift": None, "ambiguous": False}
