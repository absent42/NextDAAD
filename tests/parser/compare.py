"""Compare two interpreter runs turn by turn.

Two channels. STATE compares flags and object locations byte-exactly.
TEXT compares whitespace-normalised token sequences, because NextDAAD
wraps at 80 columns and jDAAD does not. Together they classify the fault:

    state differs, text matches  -> condact computed the wrong thing silently
    state matches, text differs  -> print/message/window/wrap fault
    both differ                  -> condact fault with a visible consequence

A finding is never suppressed by a caveat: an ambiguous capture (tilemap
could not tell a scroll from an in-place edit) is reported alongside the
divergence, not instead of it, so a reader can judge trustworthiness
without the difference itself being hidden.
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

    Both channels always reported (see module header); report.build_findings
    attaches the Next leg's own text_ambiguous/anykey_heuristic/
    timing_sensitive markers as a caveat rather than discarding the diff.
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

    Primary/downstream is ranked per channel, not globally: a flag that
    diverges every turn (flag 29/fGFlags does) must not mask a later,
    unrelated TEXT divergence as its downstream cascade. Each finding
    carries state_rank/text_rank independently, None where that channel
    did not diverge (a state-only finding has no text_rank and vice versa).
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


def compare_turns_text(ref, cmp_):
    """TEXT-only comparison for a leg with no state channel (e.g. the ZX
    leg, tests/parser/zleg.py, has no symbols to read flags/objects from).
    compare_turns() raises on a missing state channel elsewhere - that
    means a broken capture there, not this deliberate text-only path.
    """
    if normalise.tokens(ref["text"]) == normalise.tokens(cmp_["text"]):
        return None
    return {
        "class": "text-only",
        "turn": ref["turn"],
        "command": ref["command"],
        "flag_diffs": [],
        "objloc_diffs": [],
        "text_ref": ref["text"],
        "text_nd": cmp_["text"],
        "state_differs": False,
        "text_differs": True,
    }


def compare_runs_text(ref_lines, cmp_lines):
    """compare_runs() restricted to the TEXT channel (see compare_turns_text).

    Alignment is positional (turn N vs turn N) with no second channel to
    catch a misalignment: a swallowed/gained turn reports as a long run
    of downstream divergences, not as "out of step" - suspect alignment
    first if a differential goes wrong from one turn on and stays wrong.
    """
    divergences = []
    n = min(len(ref_lines), len(cmp_lines))
    for i in range(n):
        d = compare_turns_text(ref_lines[i], cmp_lines[i])
        if d is not None:
            divergences.append(d)

    first = divergences[0]["turn"] if divergences else None
    for d in divergences:
        d["state_rank"] = None
        d["text_rank"] = "primary" if d["turn"] == first else "downstream"

    if len(ref_lines) != len(cmp_lines):
        divergences.append({
            "class": "truncated",
            "state_rank": None,
            "text_rank": "primary" if first is None else "downstream",
            "turn": n,
            "command": "",
            "flag_diffs": [],
            "objloc_diffs": [],
            "text_ref": "%d turns" % len(ref_lines),
            "text_nd": "%d turns" % len(cmp_lines),
            "state_differs": False,
            "text_differs": True,
        })
        if first is None:
            first = n

    return {"divergences": divergences, "primary": first, "turns_compared": n}


def load_jsonl(path):
    with open(path, "r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]
