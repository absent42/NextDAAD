"""Compare two interpreter runs turn by turn.

Two channels. STATE compares flags and object locations byte-exactly.
TEXT compares whitespace-normalised token sequences, because NextDAAD
wraps at 80 columns and jDAAD does not. Together they classify the fault:

    state differs, text matches  -> condact computed the wrong thing silently
    state matches, text differs  -> print/message/window/wrap fault
    both differ                  -> condact fault with a visible consequence
"""
import json

import normalise

# Flags that legitimately differ between interpreters. Keep this tiny -
# every exempted flag is a class of bug we can no longer see.
MASK = {
    61: "fKey2 - extended key code, IBM only",
    62: "fScMode - screen mode, documented platform-dependent",
}


def _flag_diffs(ref, nd, turn=None):
    # Flags and object tables are fixed-size per compiled game. Unequal lengths
    # are a capture bug (truncated dump, partial read), not a game divergence.
    # Fail loudly so the harness does not hide a corrupted capture.
    if len(ref) != len(nd):
        msg = "flag array length mismatch: ref=%d, nd=%d" % (len(ref), len(nd))
        if turn is not None:
            msg += " (turn %d)" % turn
        raise ValueError(msg)

    out = []
    for i in range(len(ref)):
        if i in MASK:
            continue
        if ref[i] != nd[i]:
            out.append({"flag": i, "ref": ref[i], "nd": nd[i]})
    return out


def _objloc_diffs(ref, nd, turn=None):
    # Object locations are fixed-size per compiled game. Unequal lengths
    # are a capture bug (truncated dump, partial read), not a game divergence.
    # Fail loudly so the harness does not hide a corrupted capture.
    if len(ref) != len(nd):
        msg = "objloc array length mismatch: ref=%d, nd=%d" % (len(ref), len(nd))
        if turn is not None:
            msg += " (turn %d)" % turn
        raise ValueError(msg)

    out = []
    for i in range(len(ref)):
        if ref[i] != nd[i]:
            out.append({"obj": i, "ref": ref[i], "nd": nd[i]})
    return out


def compare_turns(ref, nd):
    """Return a divergence dict, or None when the turn agrees.

    Both channels are reported unconditionally: a text difference is
    NEVER discarded because the Next leg's screen transition this turn
    was ambiguous (tilemap could not tell a scroll from an in-place
    edit). That ambiguity is real evidence of a different kind - it says
    the CAPTURE may be untrustworthy, not that the DIFFERENCE isn't
    there - so it is surfaced as a caveat instead (report.build_findings
    reads the Next leg's own text_ambiguous/anykey_heuristic/
    timing_sensitive markers and attaches them to the finding). A reader
    must be able to tell "the text differs and the capture is
    trustworthy" from "the text differs but this turn's capture may
    include stale rows" - suppressing the difference outright made that
    distinction impossible to see at all.
    """
    turn_num = ref["turn"]
    fd = _flag_diffs(ref["flags"], nd["flags"], turn=turn_num)
    od = _objloc_diffs(ref["objloc"], nd["objloc"], turn=turn_num)
    state_differs = bool(fd or od)
    text_differs = normalise.tokens(ref["text"]) != normalise.tokens(nd["text"])

    if not state_differs and not text_differs:
        return None
    elif state_differs and text_differs:
        cls = "both"
    elif state_differs:
        cls = "state-only"
    else:
        cls = "text-only"

    return {
        "class": cls,
        "turn": ref["turn"],
        "command": ref["command"],
        "flag_diffs": fd,
        "objloc_diffs": od,
        "text_ref": ref["text"],
        "text_nd": nd["text"],
        "state_differs": state_differs,
        "text_differs": text_differs,
    }


def compare_runs(ref_lines, nd_lines):
    """Compare two lists of turn dicts.

    Primary/downstream is tracked PER CHANNEL, not globally. A single
    global cascade rule meant one flag that diverges on every turn (flag
    29/fGFlags does exactly this - see docs/parser-bugs.md) made every
    later TEXT divergence look like a downstream cascade of that flag,
    even though the two are unrelated - and the triage rule ("only the
    primary finding is trustworthy") then told a reader to ignore it.
    Each finding here instead carries state_rank and text_rank
    independently: "primary" only on the first turn THAT channel
    diverges, "downstream" on every later turn it diverges, and None on
    a turn where that channel did not diverge at all (a state-only
    finding has no text_rank; a text-only finding has no state_rank).
    The cascade concept itself is sound and kept - just scoped to one
    channel at a time instead of applied globally.
    """
    divergences = []
    n = min(len(ref_lines), len(nd_lines))
    for i in range(n):
        d = compare_turns(ref_lines[i], nd_lines[i])
        if d is not None:
            divergences.append(d)

    first_state_turn = next(
        (d["turn"] for d in divergences if d["state_differs"]), None)
    first_text_turn = next(
        (d["turn"] for d in divergences if d["text_differs"]), None)

    for d in divergences:
        if d["state_differs"]:
            d["state_rank"] = ("primary" if d["turn"] == first_state_turn
                               else "downstream")
        else:
            d["state_rank"] = None
        if d["text_differs"]:
            d["text_rank"] = ("primary" if d["turn"] == first_text_turn
                              else "downstream")
        else:
            d["text_rank"] = None

    primary = divergences[0]["turn"] if divergences else None

    if len(ref_lines) != len(nd_lines):
        # A truncated run is neither a pure state nor a pure text
        # divergence - it means one leg stopped producing turns at all.
        # It gets the same rank on both channels: primary only if
        # nothing on either channel had already diverged first.
        trunc_rank = "primary" if (first_state_turn is None
                                   and first_text_turn is None) else "downstream"
        divergences.append({
            "class": "truncated",
            "state_rank": trunc_rank,
            "text_rank": trunc_rank,
            "turn": n,
            "command": "",
            "flag_diffs": [],
            "objloc_diffs": [],
            "text_ref": "%d turns" % len(ref_lines),
            "text_nd": "%d turns" % len(nd_lines),
        })
        if primary is None:
            primary = n

    return {"divergences": divergences, "primary": primary, "turns_compared": n}


def load_jsonl(path):
    with open(path, "r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]
