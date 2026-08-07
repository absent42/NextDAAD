#!/usr/bin/env python3
"""tests/parser/parser_selftest.py - plain-python selftest for the parser
test harness.

No pytest dependency: `python tests/parser/parser_selftest.py` runs every
case, prints a PASS/FAIL line per case plus a summary, and exits 0 if all
passed, 1 otherwise. Cases are grouped by the plan's task numbers.
"""
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

CASES = []


def case(fn):
    CASES.append(fn)
    return fn


# ---- Task 1: symbols -------------------------------------------------------

@case
def t1_symbols_known_addresses():
    import symbols
    syms = symbols.load_symbols(ROOT / "build" / "nextdaad.map")
    assert syms["FLAGS"] == 0xA200, hex(syms["FLAGS"])
    assert syms["OBJTABLE"] == 0xA300, hex(syms["OBJTABLE"])
    assert syms["RNGSTATE"] == 0xA94A, hex(syms["RNGSTATE"])


@case
def t1_condact_dispatch():
    import symbols
    cds = symbols.load_condacts(ROOT / "src" / "engine.asm")
    assert cds[95] == "h_random", cds.get(95)


@case
def t1_condact_dispatch_is_complete():
    import symbols
    cds = symbols.load_condacts(ROOT / "src" / "engine.asm")
    # Verify total count
    assert len(cds) == 128, len(cds)
    # Verify DC1 entry resolves (e.g., condact 73 PARSE -> h_parse)
    assert cds[73] == "h_parse", cds.get(73)
    # SP16 Task 6 - the three DAAD V3 opcodes. 120/122/124 were the
    # "unused" slots and this pin read cds[120] == "h_unimpl"; they are
    # now live handlers in a version 3 database (and raise E5 from
    # h_v3only in a version 2 one). Pinned by NAME so a future repoint
    # has to come through here deliberately.
    assert cds[120] == "h_xmes", cds.get(120)
    assert cds[122] == "h_indir", cds.get(122)
    assert cds[124] == "h_setat", cds.get(124)
    # Row 36 also changed in Task 6, but in cprops (action -> condition)
    # rather than here - the dispatch target is unchanged and must stay
    # unchanged, because h_synonym is now the thing that decides whether
    # to mark done. This table is cdisp only; the cprops typing bit is
    # pinned by t1_cprops_typing_bits below.
    assert cds[36] == "h_synonym", cds.get(36)


@case
def t1_cprops_typing_bits():
    """Pin engine.asm's cprops ACTION/CONDITION bit for the rows where a
    silent flip would change behaviour without failing anything else.

    Nothing else checks this bit. tests/check-cprops.ps1 validates argc
    (bits 0-1) against DRF.exe's parameter table and stops there, and
    t1_condact_dispatch_is_complete pins cdisp's handler targets, which
    a typing flip leaves untouched. So the only thing standing between a
    reverted typing bit and a shipped interpreter today is a full replay
    noticing the downstream behaviour change - late, expensive, and only
    if the fixture happens to exercise that condact.

    SP16 Task 6 is the concrete precedent: row 36 SYNONYM was flipped
    from ACTION to CONDITION so h_synonym could decide for itself whether
    to mark the level done (PRP019 V3-12: under V3 it must NOT). An
    action-typed row has the dispatcher stamp `done` BEFORE the handler
    runs, so reverting the bit silently reinstates the V2-only behaviour
    with no build, argc or dispatch failure anywhere.

    Rows pinned, and why each:
      36  SYNONYM - the Task 6 change itself (action -> condition).
      120 XMES / 122 INDIR / 124 SETAT - the DAAD V3 opcodes Task 6 made
          live; all three action-typed, matching msx2daad's condactList.
      20  QUIT, 73 PARSE, 84 PICTURE, 106 MOVE - deliberately
          condition-typed against intuition (see cprops' own header
          comment); exactly the rows a later reader is most likely to
          "correct" to actions.
      25  SAVE / 26 LOAD - condition-typed for the same reason, and
          documented inline in the table.
      0   AT and 21 END - ordinary control rows, one of each type, so a
          wholesale table shift shows up here rather than only in the
          interesting rows.
    """
    import symbols
    cp = symbols.load_cprops(ROOT / "src" / "engine.asm")

    ACTION, CONDITION = True, False
    expected = {
        0: (CONDITION, 1),      # AT
        20: (CONDITION, 0),     # QUIT
        21: (ACTION, 0),        # END
        25: (CONDITION, 1),     # SAVE
        26: (CONDITION, 1),     # LOAD
        36: (CONDITION, 2),     # SYNONYM - SP16 T6
        73: (CONDITION, 1),     # PARSE
        84: (CONDITION, 1),     # PICTURE
        106: (CONDITION, 1),    # MOVE
        120: (ACTION, 2),       # XMES - V3
        122: (ACTION, 1),       # INDIR - V3
        124: (ACTION, 2),       # SETAT - V3
    }
    for n, (want_action, want_argc) in sorted(expected.items()):
        got = cp[n]
        is_action = bool(got & symbols.CPROPS_ACTION)
        assert is_action == want_action, (
            "cprops row %d is %s-typed (byte $%02X), expected %s-typed - "
            "the typing bit decides whether the dispatcher stamps `done` "
            "before the handler runs; see this test's docstring for why "
            "this row is pinned"
            % (n, "action" if is_action else "condition", got,
               "action" if want_action else "condition"))
        assert (got & symbols.CPROPS_ARGC) == want_argc, (
            "cprops row %d has argc %d (byte $%02X), expected %d - "
            "tests/check-cprops.ps1 validates argc against DRF and should "
            "have caught this first; if it did not, the two readers "
            "disagree about the table"
            % (n, got & symbols.CPROPS_ARGC, got, want_argc))


# ---- Task 2: tilemap -------------------------------------------------------

def _grid(rows):
    """Build a 5120-byte tilemap image from a list of up to 32 strings."""
    out = bytearray()
    for r in range(32):
        text = rows[r] if r < len(rows) else ""
        text = (text + " " * 80)[:80]
        for ch in text:
            out.append(ord(ch))
            out.append(7 * 2)
    return bytes(out)


@case
def t2_decode_roundtrip():
    import tilemap
    rows, attrs = tilemap.decode(_grid(["HELLO", "WORLD"]))
    assert len(rows) == 32, len(rows)
    assert all(len(r) == 80 for r in rows)
    assert rows[0].rstrip() == "HELLO", repr(rows[0])
    assert rows[1].rstrip() == "WORLD", repr(rows[1])
    assert attrs[0][0] == 14, attrs[0][0]


@case
def t2_scroll_delta_detects_shift():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    post = pre[3:] + [("new%d" % i).ljust(80) for i in range(3)]
    assert tilemap.scroll_delta(pre, post) == 3


@case
def t2_scroll_delta_zero_when_unchanged():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    assert tilemap.scroll_delta(pre, list(pre)) == 0


@case
def t2_scroll_delta_none_on_full_redraw():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    post = [("other%d" % i).ljust(80) for i in range(32)]
    assert tilemap.scroll_delta(pre, post) is None


@case
def t2_new_text_returns_scrolled_in_rows():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    post = pre[2:] + ["alpha".ljust(80), "beta".ljust(80)]
    assert tilemap.new_text(pre, post) == ["alpha", "beta"]


@case
def t2_new_text_returns_changed_rows_in_place():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    post = list(pre)
    post[5] = "changed".ljust(80)
    assert tilemap.new_text(pre, post) == ["changed"]


@case
def t2_new_text_full_redraw_returns_all_nonblank():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    post = ["fresh".ljust(80)] + [" " * 80] * 31
    assert tilemap.new_text(pre, post) == ["fresh"]


@case
def t2_transition_flags_mixed_scroll_and_inplace():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    # Scroll up by 2 and append two new rows, then overwrite row 0 with status line
    post = pre[2:] + ["new0".ljust(80), "new1".ljust(80)]
    post[0] = "STATUS: 42".ljust(80)
    post[31] = pre[31]  # Keep last row unchanged to trigger rule 3
    result = tilemap.transition(pre, post)
    assert result["shift"] is None, result["shift"]
    assert result["ambiguous"] is True, result["ambiguous"]


@case
def t2_transition_unambiguous_cases():
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]

    # Case 1: exact scroll of 3
    post1 = pre[3:] + [("new%d" % i).ljust(80) for i in range(3)]
    r1 = tilemap.transition(pre, post1)
    assert r1["shift"] == 3, r1
    assert r1["ambiguous"] is False, r1

    # Case 2: unchanged screen
    post2 = list(pre)
    r2 = tilemap.transition(pre, post2)
    assert r2["shift"] == 0, r2
    assert r2["ambiguous"] is False, r2

    # Case 3: pure in-place edit of one row
    post3 = list(pre)
    post3[5] = "changed".ljust(80)
    r3 = tilemap.transition(pre, post3)
    assert r3["shift"] is None, r3
    assert r3["ambiguous"] is False, r3


# ---- Task 3: normalise ----------------------------------------------------

@case
def t3_collapses_wrapping():
    import normalise
    a = normalise.tokens("You are in a\ndark room.")
    b = normalise.tokens("You are in a dark room.")
    assert a == b, (a, b)


@case
def t3_preserves_case():
    import normalise
    assert normalise.tokens("The Lamp") != normalise.tokens("the lamp")
    assert normalise.tokens("The Lamp") == ["The", "Lamp"]


@case
def t3_preserves_punctuation():
    import normalise
    assert normalise.tokens("the lamp.") != normalise.tokens("the lamp")
    assert normalise.tokens("the lamp.") == ["the", "lamp."]


@case
def t3_blank_line_is_paragraph_break():
    import normalise
    paras = normalise.normalise("First para.\n\nSecond para.")
    assert paras == ["First para.", "Second para."], paras


@case
def t3_collapses_whitespace_runs():
    import normalise
    assert normalise.tokens("a    b\t\tc") == ["a", "b", "c"]


@case
def t3_empty_input_is_empty():
    import normalise
    assert normalise.normalise("   \n\n  ") == []
    assert normalise.tokens("") == []


@case
def t3_cls_marker_is_harness_annotation_not_content():
    """jleg.js annotates every clearCurrentWindow() with ---[CLS]---.
    That is the harness talking, not the game, and the Next leg emits no
    counterpart at all - so left in the compared stream it diverges on
    every window-clear turn regardless of what either interpreter did.
    Dropped for comparison; report.py's transcript still shows it raw.
    """
    import normalise
    ref = "You are in a hall.\n\n---[CLS]---\nYou are in a cave."
    nd = "You are in a hall.\nYou are in a cave."
    assert normalise.tokens(ref) == normalise.tokens(nd)
    # Only the exact marker line goes; text that merely mentions it stays.
    assert "---[CLS]---" in normalise.tokens("the sign reads ---[CLS]--- here")


@case
def t3_cls_marker_breaks_the_paragraph():
    """The marker contributes no WORDS, but it is still a separator - a
    window clear means the text after it was never on screen with the
    text before it, so running the two into one paragraph would be a
    claim the capture does not support. It used to `continue` straight
    past, which did exactly that.

    Also pins the reason this was safe to change: compare.py compares
    tokens(), which flattens paragraphs away, so no finding and no
    replay hash moves.
    """
    import normalise
    text = "You are in a hall.\n---[CLS]---\nYou are in a cave."
    assert normalise.normalise(text) == ["You are in a hall.",
                                         "You are in a cave."], \
        normalise.normalise(text)
    assert normalise.tokens(text) == normalise.tokens(
        "You are in a hall.\nYou are in a cave.")


# ---- Task 4: rng -----------------------------------------------------------

@case
def t4_rng_range_and_determinism():
    import rng
    a = rng.RNG(0xA5C3)
    b = rng.RNG(0xA5C3)
    va = [a.next() for _ in range(500)]
    vb = [b.next() for _ in range(500)]
    assert va == vb, "same seed must give same stream"
    assert all(1 <= v <= 100 for v in va), "out of range: %r" % (
        sorted({v for v in va if not 1 <= v <= 100})[:5],)


@case
def t4_rng_state_is_16_bit():
    import rng
    r = rng.RNG(0xA5C3)
    for _ in range(200):
        r.next()
        assert 0 <= r.state <= 0xFFFF, hex(r.state)


@case
def t4_rng_js_mirror_matches_python():
    import json
    import subprocess
    import rng
    here = Path(__file__).resolve().parent
    js = (
        "const {makeRng} = require('./rngmirror.js');"
        "const r = makeRng(0xA5C3);"
        "const out = []; for (let i = 0; i < 500; i++) out.push(r.next());"
        "process.stdout.write(JSON.stringify(out));"
    )
    res = subprocess.run(["node", "-e", js], cwd=str(here),
                         capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    got = json.loads(res.stdout)
    r = rng.RNG(0xA5C3)
    want = [r.next() for _ in range(500)]
    assert got == want, "JS mirror diverges at index %d" % next(
        i for i, (x, y) in enumerate(zip(got, want)) if x != y)


@case
def t4_scaling_boundaries():
    import rng
    # Scaling domain is the whole 16-bit state, not a folded byte.
    for x in (0, 1, 0x28F5, 0x28F6, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF):
        result = rng.scale_to_1_100(x)
        assert 1 <= result <= 100, \
            "scale_to_1_100(0x%04X) = %d, out of range 1..100" % (x, result)

    # Boundary cases against the Z80's (x*100)>>16 arithmetic.
    assert rng.scale_to_1_100(0x0000) == 1, "0x0000 should map to 1"
    assert rng.scale_to_1_100(0x028F) == 1, "0x028F (655) is the last 1"
    assert rng.scale_to_1_100(0x0290) == 2, "0x0290 (656) is the first 2"
    assert rng.scale_to_1_100(0x8000) == 51, "half scale is 51"
    assert rng.scale_to_1_100(0xFFFF) == 100, "0xFFFF should map to 100"

    # Every outcome 1..100 must be reachable, and the buckets must be
    # near-equal - this is what makes CHANCE fair (see rng.py's header).
    from collections import Counter
    c = Counter(rng.scale_to_1_100(x) for x in range(65536))
    assert sorted(c) == list(range(1, 101)), "not all 100 outcomes reachable"
    assert max(c.values()) - min(c.values()) <= 1, \
        "bucket sizes uneven: %d..%d" % (min(c.values()), max(c.values()))


@case
def t4_scaling_js_mirror_matches_python():
    import json
    import subprocess
    here = Path(__file__).resolve().parent
    js = (
        "const {scaleTo1_100} = require('./rngmirror.js');"
        "const out = []; for (let i = 0; i < 65536; i += 257) out.push(scaleTo1_100(i));"
        "process.stdout.write(JSON.stringify(out));"
    )
    res = subprocess.run(["node", "-e", js], cwd=str(here),
                         capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    got = json.loads(res.stdout)

    import rng
    want = [rng.scale_to_1_100(i) for i in range(0, 65536, 257)]
    assert got == want, "JS scaleTo1_100 diverges at index %d" % next(
        i for i, (x, y) in enumerate(zip(got, want)) if x != y)


@case
def t4_rng_pins_the_z80_xorshift_sequence():
    """Pin the Z80's xorshift stream, its period, and its fairness.

    SP16 Task 5 replaced rng_next (src/overlay0.asm) with a real 16-bit
    xorshift - x ^= x<<7; x ^= x>>9; x ^= x<<8 - scaled to 1..100 by
    (x*100)>>16 + 1. This case is the successor to
    t4_rng_reproduces_z80_period_defect, which pinned the old
    rotate-based routine's period-16 degeneracy (docs/parser-bugs.md
    entry 3). The defect is gone; what needs pinning now is that the
    mirror still tracks the Z80 exactly.

    If this case fails:
    - src/overlay0.asm rng_next has been changed, OR
    - rng.py / rngmirror.js have drifted from it.
    Fix the mirrors and this pin in the SAME change as the Z80. Do not
    "improve" the mirror alone - the two interpreter legs must draw the
    identical stream or every replay that touches RANDOM/CHANCE breaks.
    """
    import rng

    # 1. The first 16 outputs from the shipped seed, verbatim.
    r = rng.RNG(0xA5C3)
    got = [r.next() for _ in range(16)]
    want = [15, 25, 46, 60, 88, 26, 44, 43, 1, 43, 44, 51, 56, 65, 71, 58]
    assert got == want, "stream drift from seed 0xA5C3: %r != %r" % (got, want)

    # 2. Full-state period is 65535 - every non-zero state, exactly once.
    x = 0xA5C3
    n = 0
    while True:
        x = rng.step(x)
        n += 1
        if x == 0xA5C3:
            break
    assert n == 65535, "period is %d, expected 65535" % n

    seen = set()
    x = 1
    for _ in range(65535):
        seen.add(x)
        x = rng.step(x)
    assert len(seen) == 65535 and 0 not in seen, \
        "orbit is not the full non-zero state space (%d states)" % len(seen)

    # 3. Fairness: CHANCE 50 fires when the draw is <= 50 (h_chance,
    #    src/overlay0.asm). Over a full period that must be exactly half.
    x = 0xA5C3
    hits = 0
    for _ in range(65535):
        x = rng.step(x)
        if rng.scale_to_1_100(x) <= 50:
            hits += 1
    rate = 100.0 * hits / 65535
    assert 49.9 <= rate <= 50.1, "CHANCE 50 full-period rate %.3f%%" % rate

    # 4. The 200-draw empirical check the SP16 brief asks for, on the
    #    pinned seed the harness uses.
    r = rng.RNG(0xA5C3)
    hits = sum(1 for _ in range(200) if r.next() <= 50)
    assert 45 <= hits * 100 // 200 <= 55, \
        "CHANCE 50 over 200 draws: %d%%" % (hits * 100 // 200)


# ---- Task 5: compare -------------------------------------------------------

def _turn(n, cmd="LOOK", text="You are here.", flags=None, objloc=None):
    f = [0] * 256
    if flags:
        for k, v in flags.items():
            f[k] = v
    return {"turn": n, "command": cmd, "text": text,
            "flags": f, "objloc": objloc or [0, 0, 0], "frame": 0}


@case
def t5_identical_turns_have_no_divergence():
    import compare
    assert compare.compare_turns(_turn(1), _turn(1)) is None


@case
def t5_state_only_divergence():
    import compare
    d = compare.compare_turns(_turn(1), _turn(1, flags={12: 3}))
    assert d["class"] == "state-only", d["class"]
    assert d["flag_diffs"] == [{"flag": 12, "ref": 0, "nd": 3}], d["flag_diffs"]


@case
def t5_text_only_divergence():
    import compare
    d = compare.compare_turns(_turn(1), _turn(1, text="You are elsewhere."))
    assert d["class"] == "text-only", d["class"]


@case
def t5_both_divergence():
    import compare
    d = compare.compare_turns(_turn(1), _turn(1, text="Nope.", flags={12: 3}))
    assert d["class"] == "both", d["class"]


@case
def t5_masked_flags_are_ignored():
    import compare
    for flag in (61, 62):
        d = compare.compare_turns(_turn(1), _turn(1, flags={flag: 99}))
        assert d is None, "flag %d must be masked" % flag


@case
def t5_object_location_divergence():
    import compare
    d = compare.compare_turns(_turn(1), _turn(1, objloc=[0, 254, 0]))
    assert d["class"] == "state-only", d["class"]
    assert d["objloc_diffs"] == [{"obj": 1, "ref": 0, "nd": 254}]


@case
def t5_wrap_difference_is_not_a_divergence():
    import compare
    a = _turn(1, text="You are in a\ndark room.")
    b = _turn(1, text="You are in a dark room.")
    assert compare.compare_turns(a, b) is None


@case
def t5_first_divergence_is_primary_rest_downstream():
    import compare
    ref = [_turn(i) for i in range(5)]
    nd = [_turn(i) for i in range(5)]
    nd[2] = _turn(2, flags={12: 3})
    nd[3] = _turn(3, flags={12: 3})
    nd[4] = _turn(4, flags={12: 3})
    res = compare.compare_runs(ref, nd)
    assert res["primary"] == 2, res["primary"]
    state_ranks = [d["state_rank"] for d in res["divergences"]]
    assert state_ranks == ["primary", "downstream", "downstream"], state_ranks
    # None of these turns touched the text channel at all.
    text_ranks = [d["text_rank"] for d in res["divergences"]]
    assert text_ranks == [None, None, None], text_ranks


@case
def t5_unequal_run_lengths_are_reported():
    import compare
    res = compare.compare_runs([_turn(0), _turn(1)], [_turn(0)])
    assert res["turns_compared"] == 1
    assert any(d["class"] == "truncated" for d in res["divergences"])
    # When truncation is the only divergence, primary should be the common-prefix length
    assert res["primary"] == 1, res["primary"]


@case
def t5_ambiguous_text_is_no_longer_suppressed():
    """The old behaviour discarded a genuine text difference whenever the
    Next leg's screen transition that turn was ambiguous - exactly the
    mechanism that hid the real Dracula GET/DROP SM36/SM39 bug (see
    docs/parser-bugs.md). text_ambiguous must now be irrelevant to
    compare.py's own classification - it is surfaced later as a caveat
    (report.build_findings, from the Next leg's own per-turn markers),
    never as grounds to drop the finding here.
    """
    import compare
    a = _turn(1, text="You are here.")
    b = _turn(1, text="You are elsewhere.")
    b["text_ambiguous"] = True
    d = compare.compare_turns(a, b)
    assert d is not None, "divergence should be reported"
    assert d["class"] == "text-only", d["class"]
    assert d["text_differs"] is True


@case
def t5_ambiguous_marker_does_not_change_classification_when_both_differ():
    import compare
    a = _turn(1, text="You are here.", flags={12: 0})
    b = _turn(1, text="You are elsewhere.", flags={12: 3})
    b["text_ambiguous"] = True
    d = compare.compare_turns(a, b)
    assert d is not None, "divergence should be reported"
    # Both channels genuinely differ here - text_ambiguous must not
    # silently turn this into "state-only" by hiding the text side.
    assert d["class"] == "both", d["class"]
    assert d["state_differs"] and d["text_differs"]


@case
def t5_state_and_text_channels_ranked_independently():
    """A flag that diverges on every turn (flag 29/fGFlags does exactly
    this against every real game - see docs/parser-bugs.md) must not make
    a LATER, unrelated text divergence look like a downstream cascade of
    it. state_rank and text_rank are tracked on separate timelines.
    """
    import compare
    ref = [_turn(i) for i in range(4)]
    nd = [_turn(i, flags={29: 3}) for i in range(4)]
    # Text ALSO diverges, but only starting turn 2 - two turns after the
    # state channel already started diverging at turn 0.
    nd[2] = _turn(2, flags={29: 3}, text="Something else.")
    nd[3] = _turn(3, flags={29: 3}, text="Something else too.")
    res = compare.compare_runs(ref, nd)
    divs = {d["turn"]: d for d in res["divergences"]}

    assert divs[0]["state_rank"] == "primary", divs[0]
    assert divs[0]["text_rank"] is None, divs[0]

    assert divs[2]["class"] == "both", divs[2]
    assert divs[2]["state_rank"] == "downstream", (
        "turn 2's state divergence is a cascade of turn 0's - not primary")
    assert divs[2]["text_rank"] == "primary", (
        "turn 2 is the FIRST text divergence and must be ranked primary "
        "for the text channel, even though the state channel diverged "
        "earlier (turn 0) - the whole point of per-channel ranking")

    assert divs[3]["text_rank"] == "downstream", divs[3]


@case
def t5_mismatched_state_array_lengths_raise():
    import compare
    # Flag array length mismatch is a capture bug, must raise loudly
    a = _turn(1)
    b = _turn(1)
    b["flags"] = [0] * 100  # Truncated/corrupted flag array
    try:
        compare.compare_turns(a, b)
        # Fail if no exception was raised
        assert False, "should have raised ValueError for mismatched flag array length"
    except ValueError as e:
        # Verify the error message names both lengths
        msg = str(e)
        assert "100" in msg and "256" in msg, msg


# ---- Task 6: zrcp ----------------------------------------------------------

@case
def t6_parse_hex_dump():
    import zrcp
    # Whatever shape the spike found, the parser must turn the emulator's
    # textual reply into bytes. Adjust the sample to the real reply format
    # recorded in zrcp.py's header comment.
    assert zrcp.parse_bytes("48 45 4C 4C 4F") == b"HELLO"
    assert zrcp.parse_bytes("48454C4C4F") == b"HELLO"
    assert zrcp.parse_bytes("") == b""


@case
def t6_parse_bytes_raises_on_error_reply():
    import zrcp
    # Confirmed live against ZEsarUX: 'set-memory-zone 999' replies
    # 'ERROR. Unknown zone 999\ncommand> '. An explicit error reply must
    # raise, never be silently scraped for hex-looking bytes.
    try:
        zrcp.parse_bytes("ERROR. Unknown zone 999\ncommand> ")
        assert False, "expected ZrcpError"
    except zrcp.ZrcpError:
        pass


@case
def t6_read_memory_rejects_negative_length():
    # Carried over from Task 6: read-memory with a negative length wedges
    # ZEsarUX at ~100% CPU until killed. The guard must raise before
    # anything reaches the wire - no socket needed for this case, so the
    # guard is checked before Zrcp even tries to use self.s.
    import zrcp

    class _Dummy(zrcp.Zrcp):
        def __init__(self):
            pass  # skip the real socket connect entirely

    z = _Dummy()
    try:
        z.read_memory(0x8000, -1)
        assert False, "expected ValueError for a negative length"
    except ValueError as e:
        assert "negative" in str(e), e


@case
def t6_parse_bytes_raises_on_non_hex_contamination():
    import zrcp
    # A diagnostic reply can contain hex-looking substrings ("cafe") in
    # ordinary prose without being an ERROR reply at all. The parser must
    # reject anything where the whole payload isn't hex digits and
    # whitespace, not scrape out whichever adjacent pairs look hex-valid.
    try:
        zrcp.parse_bytes("Breakpoint set at cafe\ncommand> ")
        assert False, "expected ZrcpError"
    except zrcp.ZrcpError:
        pass


# ---- Task 7: prepare -------------------------------------------------------

@case
def t7_ddb_header_fields():
    import prepare
    import tempfile
    blob = bytes([2, 0x10, 95, 4, 2, 197, 61, 19] + [0] * 40)
    with tempfile.NamedTemporaryFile(suffix=".ddb", delete=False) as fh:
        fh.write(blob)
        p = fh.name
    h = prepare.ddb_header(p)
    assert h["version"] == 2 and h["objects"] == 4 and h["processes"] == 19, h


@case
def t7_assert_matched_accepts_target_difference():
    import prepare
    a = {"version": 2, "target": 0xD0, "objects": 4, "locations": 2,
         "user_messages": 197, "system_messages": 61, "processes": 19,
         "length": 5774}
    b = dict(a, target=0x10, length=5479)
    prepare.assert_matched(a, b)   # must not raise


@case
def t7_assert_matched_rejects_logic_difference():
    import prepare
    a = {"version": 2, "target": 0xD0, "objects": 4, "locations": 2,
         "user_messages": 197, "system_messages": 61, "processes": 19,
         "length": 5774}
    b = dict(a, processes=18)
    try:
        prepare.assert_matched(a, b)
    except ValueError:
        return
    raise AssertionError("mismatched process count must raise")


@case
def t7_ddb_header_rejects_too_short_file():
    import prepare
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".ddb", delete=False) as fh:
        fh.write(bytes([2, 0x10, 95, 4]))  # 4 bytes, shorter than the 8 required
        p = fh.name
    try:
        prepare.ddb_header(p)
    except ValueError as e:
        assert "short" in str(e), e
        return
    raise AssertionError("truncated DDB must raise ValueError")


@case
def t7_ddb_header_rejects_wrong_signature():
    import prepare
    import tempfile
    blob = bytes([2, 0x10, 99, 4, 2, 197, 61, 19] + [0] * 40)  # byte 2 wrong
    with tempfile.NamedTemporaryFile(suffix=".ddb", delete=False) as fh:
        fh.write(blob)
        p = fh.name
    try:
        prepare.ddb_header(p)
    except ValueError as e:
        assert "signature" in str(e), e
        return
    raise AssertionError("wrong signature byte must raise ValueError")


@case
def t7_build_condacts_fixture_end_to_end():
    import prepare
    work = ROOT / "tests" / "parser" / "work" / "selftest-condacts"
    res = prepare.prepare_from_dsf(ROOT / "tests" / "condacts.dsf", work)
    assert res["jddb"].exists(), res["jddb"]
    assert res["ddb"].exists(), res["ddb"]
    assert res["header"]["html"]["version"] == 2
    assert res["header"]["next"]["version"] == 2


# ---- Task 8: jleg ----------------------------------------------------------

@case
def t8_jleg_emits_schema_and_is_deterministic():
    import json
    import subprocess
    import prepare
    here = Path(__file__).resolve().parent
    work = ROOT / "tests" / "parser" / "work" / "selftest-condacts"
    prepare.prepare_from_dsf(ROOT / "tests" / "condacts.dsf", work)

    script = work / "smoke.json"
    script.write_text(json.dumps(["LOOK", "GET LAMP", "I"]), encoding="utf-8")

    def run(out):
        res = subprocess.run(
            ["node", str(here / "jleg.js"), str(work), str(script), str(out)],
            capture_output=True, text=True)
        assert res.returncode == 0, res.stderr
        return [json.loads(l) for l in
                Path(out).read_text(encoding="utf-8").splitlines() if l.strip()]

    a = run(work / "j1.jsonl")
    b = run(work / "j2.jsonl")

    assert len(a) == 3, len(a)
    for t in a:
        assert set(t) == {"turn", "command", "text", "flags", "objloc", "frame"}, set(t)
        assert len(t["flags"]) == 256, len(t["flags"])
    assert a[0]["command"] == "LOOK", a[0]["command"]
    assert a == b, "two runs of the same script must be identical"


@case
def t8_jleg_random_draws_from_the_rng_mirror_not_math_random():
    """Reproducibility (t8 above) is not correctness: two independent Node
    processes both calling the real unpatched Math.random() would still
    likely agree with each other on THIS fixture, because tests/condacts.dsf
    only ever draws RANDOM once (see below) - a ~1-in-100 coincidence, not
    a resounding pass. This case ties the captured value to the Python rng
    mirror directly, so if jleg.js's condactTable patch ever goes silently
    dead again (as it did during development - see task-8-report.md), this
    fails instead of quietly passing.

    tests/condacts.dsf line 160 is 'RANDOM 107' - flag 107 is the fixture's
    RANDOM target, not a magic number. It sits inside /PRO 0's first entry
    (CLS; MESSAGE 0; PROCESS 1, where PROCESS 1 contains the RANDOM 107
    call), which runs exactly once at boot before the second entry blocks
    in PARSE 0 for input; later turns resume past PARSE rather than
    re-entering the first entry. So this fixture draws RANDOM exactly once,
    and flag 107 holds that single draw for the rest of the run - it is
    expected to equal the mirror's FIRST value on every captured turn.
    """
    import json
    import subprocess
    import prepare
    import rng
    here = Path(__file__).resolve().parent
    work = ROOT / "tests" / "parser" / "work" / "selftest-condacts"
    prepare.prepare_from_dsf(ROOT / "tests" / "condacts.dsf", work)

    script = work / "smoke.json"
    script.write_text(json.dumps(["LOOK", "GET LAMP", "I"]), encoding="utf-8")

    out = work / "j3.jsonl"
    res = subprocess.run(
        ["node", str(here / "jleg.js"), str(work), str(script), str(out)],
        capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    turns = [json.loads(l) for l in
             Path(out).read_text(encoding="utf-8").splitlines() if l.strip()]

    expected = rng.RNG(0xA5C3).next()
    for t in turns:
        assert t["flags"][107] == expected, (
            "flag 107 (the fixture's RANDOM target) is %r, expected the "
            "rng mirror's first draw %r - jleg.js's RANDOM/CHANCE patch "
            "may not be reaching condactTable's dispatch path"
            % (t["flags"][107], expected))


# ---- Task 9: nleg ----------------------------------------------------------

@case
def t9_stage_sd_builds_minimal_card():
    import nleg
    import prepare
    work = ROOT / "tests" / "parser" / "work" / "selftest-condacts"
    prepare.prepare_from_dsf(ROOT / "tests" / "condacts.dsf", work)
    sd = nleg.stage_sd(work, ROOT / "build" / "nextdaad.nex")
    assert (sd / "GAME.DDB").exists(), list(sd.iterdir())
    assert (sd / "nextdaad.nex").exists(), list(sd.iterdir())


@case
def t9_more_prompt_read_from_meta_and_optional():
    """nleg drops NextDAAD's SM32 pager prompt row, whose text it gets
    from jleg.js's meta.json rather than from a hardcoded literal.

    Every way of FAILING to read it must raise. Running without the
    filter is not a degraded mode - it is the old timing-dependent
    behaviour - and a None meaning "something broke" would be
    indistinguishable downstream from a None meaning "this game has no
    pager prompt". Only jleg.js can establish the second, and it says so
    explicitly.
    """
    import nleg
    work = ROOT / "tests" / "parser" / "work" / "selftest-meta"
    work.mkdir(parents=True, exist_ok=True)
    meta = work / "meta.json"

    def must_raise(why):
        try:
            nleg.load_more_prompt(work)
        except RuntimeError:
            return
        raise AssertionError("expected RuntimeError: %s" % why)

    if meta.exists():
        meta.unlink()
    must_raise("meta.json absent - the jDAAD leg did not write it")
    meta.write_text("not json at all", encoding="utf-8")
    must_raise("meta.json is not JSON")
    meta.write_text('{"nothing": "useful"}', encoding="utf-8")
    must_raise("meta.json carries no sm32 key")
    meta.write_text('{"sm32": 32}', encoding="utf-8")
    must_raise("sm32 is neither a string nor null")

    # Real prompts, including a non-English one - the filter must never
    # assume the literal "More...".
    meta.write_text('{"sm32": "More...", "sm32_status": "read from DDB"}',
                    encoding="utf-8")
    assert nleg.load_more_prompt(work) == "More..."
    meta.write_text('{"sm32": "  \\u00a1Mas!  ", "sm32_status": "read from DDB"}',
                    encoding="utf-8")
    assert nleg.load_more_prompt(work) == "¡Mas!"

    # The two legitimate no-filter states, both explicitly recorded.
    meta.write_text('{"sm32": null, "sm32_status": "absent: DDB declares 20 '
                    'system messages"}', encoding="utf-8")
    assert nleg.load_more_prompt(work) is None
    meta.write_text('{"sm32": "", "sm32_status": "read from DDB"}',
                    encoding="utf-8")
    assert nleg.load_more_prompt(work) is None, (
        "an empty SM32 must disable the filter, not match every blank row")


@case
def t9_prompt_is_blanked_in_the_grid_not_filtered_after():
    """The pager prompt is removed from the captured GRID, before
    tilemap.transition or tilemap.new_text sees it.

    Filtering it out of new_text's result afterwards left the ambiguity
    check running on the raw grid, so the prompt appearing or vanishing
    could still flip text_ambiguous - which reaches findings.json as a
    caveat. Blanked, not deleted: scroll_delta compares rows by index, so
    dropping one would shift everything below it.
    """
    import nleg
    rows = ["a line", "More...", "", "another"]
    out = nleg.blank_prompt_rows(rows, "More...")
    assert len(out) == len(rows), "rows must be blanked in place, never dropped"
    assert out[1].strip() == "" and len(out[1]) == len("More..."), out
    assert out[0] == "a line" and out[3] == "another", out
    # A row that merely CONTAINS the prompt is game text, not the prompt.
    assert nleg.blank_prompt_rows(["say More... loudly"], "More...") == \
        ["say More... loudly"]
    # No prompt configured: identity.
    assert nleg.blank_prompt_rows(rows, None) == rows


_FAKE_SYMS = {"MORELOCK": 1, "WRAPLOCK": 2, "INPTOFRAMES": 3, "ERRCODE": 4,
              "FLAGS": 100}


class _FakeSettleZ:
    """Stand-in for zrcp.Zrcp, just enough for settle() cases.

    `states` is one (moreLock, wrapLock) pair per poll and `fires` the
    CUMULATIVE page-capture counter the emulator would report on that
    same poll (nleg's breakpoint-driven page capture - see its module
    docstring). Both advance together, driven by the ERRCODE read, which
    is the FIRST thing settle() does on every poll and the only thing it
    does exactly once per poll - the counter is deliberately read more
    than once when a page fires (captured_page re-checks it after
    reading the dump), so it cannot be the clock here.
    """

    def __init__(self, states, fires, grid=None, errcodes=None,
                 timeout_flags=(0, 0), toframes=b"\x00\x00",
                 confirms=None):
        assert len(states) == len(fires), "one fire count per poll"
        self.states = list(states)
        self.fires = list(fires)
        # What the SECOND (moreLock, wrapLock) read of a poll sees, if
        # it should differ from the first - i.e. what _ready_confirmed
        # gets. None means "the same as the first", the ordinary case.
        self.confirms = list(confirms) if confirms else None
        self.grid = grid                        # what the LIVE screen holds
        # Per-poll runtime-error code, so a case can make the interpreter
        # raise part-way through a settle.
        self.errcodes = list(errcodes) if errcodes else [0] * len(states)
        self.timeout_flags = bytes(timeout_flags)   # flags 48, 49
        self.toframes = bytes(toframes)             # inpTOFrames
        self.writes = []
        self.enters = 0
        self.dismissals = 0
        self.evaluates = 0
        self.polls = 0
        self.lock_reads = 0

    def read_memory(self, addr, length):
        if addr == _FAKE_SYMS["INPTOFRAMES"]:
            return self.toframes
        if addr == _FAKE_SYMS["FLAGS"] + 48:
            return self.timeout_flags[:length]
        if length == 1:
            if addr == _FAKE_SYMS["ERRCODE"]:
                if self.polls:                  # not the first poll
                    self.states.pop(0)
                    self.fires.pop(0)
                    if self.confirms and len(self.confirms) > 1:
                        self.confirms.pop(0)
                    if len(self.errcodes) > 1:
                        self.errcodes.pop(0)
                self.polls += 1
                self.lock_reads = 0
                return bytes([self.errcodes[0]])
            pair = self.states[0]
            if self.lock_reads >= 2 and self.confirms:
                pair = self.confirms[0]
            self.lock_reads += 1
            more, wrap = pair
            if addr == _FAKE_SYMS["MORELOCK"]:
                return bytes([1 if more else 0])
            return bytes([1 if wrap else 0])
        return self.grid if self.grid else bytes(length)   # the tilemap grid

    def tap_dismiss_key(self, hold=0.0, settle=0.0):
        self.dismissals += 1
        self.enters += 1                        # "a key was sent" either way

    def write_memory(self, addr, data):
        self.writes.append((addr, bytes(data)))

    def enter(self, wait=0.0):
        self.enters += 1

    def evaluate(self, expr):
        self.evaluates += 1
        return str(self.fires[0])


def _fake_settle_leg(z, dump):
    import nleg
    return nleg.NextLeg(z, _FAKE_SYMS, obj_count=1, obj_size=6, page_dump=dump)


def _dump_of(rows):
    """Encode text rows the way the tilemap holds them, so a fake page
    dump decodes back to those rows."""
    import tilemap
    out = bytearray(tilemap.GRID_BYTES)
    for r in range(tilemap.ROWS):
        text = rows[r] if r < len(rows) else ""
        for c in range(tilemap.COLS):
            out[(r * tilemap.COLS + c) * 2] = ord(text[c]) if c < len(text) else 0x20
    return bytes(out)


def _write_dump(data):
    import tempfile
    d = Path(tempfile.mkdtemp())
    p = d / "nleg-page.bin"
    p.write_bytes(data)
    return p


@case
def t9_page_capture_comes_from_the_emulator_dump_not_the_live_screen():
    """The MORE-page content in the transcript must be the emulator's own
    save-binary dump, taken at the pager's park point, NOT a read of the
    live screen at poll time.

    That is the whole point of the breakpoint: the page can already be
    gone by the time the harness polls (the Enter that submitted the
    command is still held for KEY_DELAY_MS and wait_key is
    press-then-release, so it dismisses the page itself). Here the fake
    emulator reports the counter moving while moreLock is ALREADY back
    down and the editor is ready again - the exact state the old polled
    design captured nothing at all in - and the page must still land in
    `pages`, with the dump's text, not the blank live grid.

    And NOTHING may be pressed: the interpreter is not waiting for a key,
    so an Enter here submits an empty command line and burns a turn.
    """
    page = ["a page that already scrolled away", "second line"]
    z = _FakeSettleZ([(True, True), (True, True)], fires=[1, 1])
    leg = _fake_settle_leg(z, _write_dump(_dump_of(page)))
    pages = []
    anykey = leg.settle(pages)

    assert len(pages) == 1, (
        "the page fired (counter moved) while moreLock was already down - "
        "it must still be captured, that is the race being closed")
    assert pages[0][0].rstrip() == page[0], pages[0][0]
    assert pages[0][1].rstrip() == page[1], pages[0][1]
    assert all(not r.strip() for r in pages[0][2:]), "rest of the grid blank"
    assert z.enters == 0, (
        "the interpreter had already moved on - pressing a key here "
        "submits an empty command line and burns a turn")
    assert anykey is False


@case
def t9_a_parked_page_is_captured_from_the_dump_and_dismissed_once():
    """The ordinary case: the counter moves and the interpreter is still
    parked (moreLock up, wrapLock down). The page comes from the dump and
    is dismissed with exactly one keypress."""
    page = ["page one", "page one line two"]
    z = _FakeSettleZ([(True, False), (True, True)], fires=[1, 1])
    leg = _fake_settle_leg(z, _write_dump(_dump_of(page)))
    pages = []
    leg.settle(pages)
    assert len(pages) == 1 and pages[0][0].rstrip() == page[0], pages
    assert z.enters == 1, z.enters


@case
def t9_anykey_backstop_does_not_append_the_same_screen_twice():
    """A wait that sets no lock still fires the pager breakpoint (h_anykey
    reaches the same routine), so its screen arrives from the dump. The
    static-screen backstop then dismisses it - and must NOT put the same
    screen into the transcript a second time."""
    screen = ["Press any key."]
    polls = [(False, False)] * 6 + [(True, True)]
    fires = [1] * 6 + [1]
    # The live screen still SHOWS the ANYKEY page - nothing has run since
    # the dump was taken, which is exactly why the backstop would
    # otherwise re-append it.
    z = _FakeSettleZ(polls, fires, grid=_dump_of(screen))
    leg = _fake_settle_leg(z, _write_dump(_dump_of(screen)))
    pages = []
    anykey = leg.settle(pages)
    assert len(pages) == 1, (
        "the ANYKEY screen was appended twice - once from the dump and "
        "once by the backstop: %d page(s)" % len(pages))
    assert z.enters == 1, "the backstop must still dismiss it"
    assert anykey is True, "and still mark the turn"


@case
def t9_page_capture_never_reads_a_half_drawn_page():
    """moreLock up, wrapLock down, counter NOT moved means prn_more_check
    has taken the lock but is still printing SM32 - the page is not
    finished. Nothing may be captured in that state; the old polled
    design captured exactly there."""
    z = _FakeSettleZ([(True, False), (True, False), (True, True)],
                     fires=[0, 0, 0])
    leg = _fake_settle_leg(z, _write_dump(_dump_of(["unfinished"])))
    pages = []
    leg.settle(pages)
    assert pages == [], (
        "captured a page the counter never announced - that grid is a "
        "half-drawn page, mid-SM32")
    assert z.enters == 0, "nothing to dismiss: the pager has not parked yet"


@case
def t9_two_pages_between_polls_raise_rather_than_truncate():
    """The dump file holds ONE page. If the counter moves by more than one
    between two polls, an earlier page's dump was overwritten before it
    could be read, and that is lost transcript text - it must be named,
    not silently dropped."""
    z = _FakeSettleZ([(True, False), (True, True)], fires=[2, 2])
    leg = _fake_settle_leg(z, _write_dump(_dump_of(["only the last one"])))
    try:
        leg.settle([])
    except RuntimeError as exc:
        assert "lost" in str(exc), exc
    else:
        raise AssertionError(
            "two pages between polls must raise, not quietly keep the last")


@case
def t9_both_locks_are_confirmed_before_a_turn_is_called_ready():
    """(moreLock, wrapLock) == (1, 1) is NOT only the input editor.

    prn_more_check sets BOTH locks together (src/print.asm:250-251) and
    only releases wrapLock again once the SM32 prompt has been printed
    (:257), so the pager passes through the editor's own signature on its
    way to parking. A poll landing in that window ends the turn on a page
    that has not finished drawing - seen live about one run in five once
    tests/condacts.dsf's checks 103/104 took the last turn from one page
    to four, with the transcript stopping dead at an unfiltered "More..."
    row and the fixture still inside check 103.

    Both ways out of that window are checked: wrapLock dropping, and the
    page counter moving because the pager reached its park point.
    """
    # wrapLock drops on the confirmation read -> it was the pager
    z = _FakeSettleZ([(True, True), (True, True)], fires=[0, 0],
                     confirms=[(True, False), (True, True)])
    leg = _fake_settle_leg(z, _write_dump(_dump_of([])))
    leg.settle([])
    assert z.polls == 2, (
        "settle called the SM32 window READY and ended the turn on a "
        "half-drawn page (stopped after %d poll(s))" % z.polls)

    # the counter moves instead -> also the pager, also not READY. The
    # page it announced is then picked up by the NEXT poll, exactly as a
    # page announced any other way is.
    z2 = _FakeSettleZ([(True, True)] * 3, fires=[0, 1, 1])
    leg2 = _fake_settle_leg(z2, _write_dump(_dump_of(["More..."])))
    real = z2.evaluate

    def _fires_on_confirm(expr):
        return "1" if z2.evaluates else real(expr)

    z2.evaluate = _fires_on_confirm
    leg2.settle([])
    assert z2.polls >= 2, (
        "a page parking during the confirmation read must not be READY")

    # and the genuine editor still returns on the FIRST poll it is seen
    z3 = _FakeSettleZ([(True, True)], fires=[0])
    leg3 = _fake_settle_leg(z3, _write_dump(_dump_of([])))
    leg3.settle([])
    assert z3.polls == 1, (
        "the confirmation must not cost an extra poll when the editor "
        "really is ready: %d" % z3.polls)


@case
def t9_a_page_firing_while_the_dump_is_read_raises():
    """Sampling the counter and reading the dump file are two separate
    ZRCP round trips. A page firing BETWEEN them overwrites the dump with
    a later page while the caller still believes it holds the one the
    counter named - and settle()'s >1-per-poll guard cannot see it,
    because the counter was already sampled. captured_page re-reads the
    counter after the file and refuses on a mismatch, so that last silent
    loss becomes a named failure."""
    z = _FakeSettleZ([(True, False)], fires=[1])
    leg = _fake_settle_leg(z, _write_dump(_dump_of(["page one"])))

    real_evaluate = z.evaluate

    def _racing_evaluate(expr):
        # the FIRST read is settle()'s (the counter says 1); the second is
        # captured_page's re-check, by which time another page has fired
        if z.evaluates:
            return "2"
        return real_evaluate(expr)

    z.evaluate = _racing_evaluate
    try:
        leg.settle([])
    except RuntimeError as exc:
        assert "gone" in str(exc), exc
    else:
        raise AssertionError(
            "a page overwritten between the counter read and the file read "
            "was accepted as if it were the page the counter named")

    # and the ordinary case, where nothing fires in that window, is
    # unaffected - the re-read must not become a second failure mode
    z2 = _FakeSettleZ([(True, False), (True, True)], fires=[1, 1])
    leg2 = _fake_settle_leg(z2, _write_dump(_dump_of(["page one"])))
    pages = []
    leg2.settle(pages)
    assert len(pages) == 1 and pages[0][0].rstrip() == "page one", pages


@case
def t9_boot_settle_advances_past_a_lockless_wait_to_ready():
    """The boot settle must run the interpreter out to the SAME positive
    READY state jleg.js's own boot settle reaches, dismissing an
    ANYKEY-class pause on the way rather than parking on it.

    It used to park, back when NextDAAD's QUIT confirmation was a single
    raw keypress and therefore indistinguishable from such a pause.
    confirm_read takes BOTH locks now (SP16 Task 5), so the QUIT prompt is
    a READY stop and cannot reach the backstop - while parking on a real
    ANYKEY left the first scripted command being typed INTO the pause,
    which is what made the Rabenstein replay's turn 0 vary run to run.

    Also pins the shortcut: a screen a pager fire has already announced,
    and that has not moved since, is a KNOWN wait, so the long
    boot-only threshold (which exists for fixtures whose timed condacts
    merely look static) does not apply to it.
    """
    screen = ["Press any key."]
    polls = [(False, False)] * 6 + [(True, True)]
    z = _FakeSettleZ(polls, [1] * len(polls), grid=_dump_of(screen))
    leg = _fake_settle_leg(z, _write_dump(_dump_of(screen)))
    assert leg.settle([], boot=True) is True
    assert z.enters == 1, (
        "boot must dismiss the pause and go on to READY, not park on it")
    assert z.polls <= 7, (
        "the announced-wait shortcut did not apply - boot waited out the "
        "long threshold on a wait the breakpoint had already named")


@case
def t9_allow_timeout_leaves_the_countdown_alone():
    """Every ordinary settle zeroes inpTOFrames on every poll so no wait
    can ever time out - jDAAD cannot time out at all and a one-sided
    expiry is a harness-manufactured divergence. A turn the script marks
    allow_timeout is the deliberate exception: the countdown is the only
    thing that can end its wait, so settle() must not touch it."""
    z = _FakeSettleZ([(False, False), (True, True)], fires=[0, 0])
    leg = _fake_settle_leg(z, _write_dump(_dump_of([])))
    leg.settle([], allow_timeout=True)
    assert not z.writes, (
        "allow_timeout must stop the disarm entirely, or the timeout the "
        "turn exists to observe can never fire: %s" % z.writes)

    z2 = _FakeSettleZ([(False, False), (True, True)], fires=[0, 0])
    leg2 = _fake_settle_leg(z2, _write_dump(_dump_of([])))
    leg2.settle([])
    assert z2.writes, "the DEFAULT must still disarm every poll"


@case
def t9_a_raised_runtime_error_ends_the_settle_at_once():
    """err_raise (src/errors.asm) halts with interrupts off and spins
    forever. No lock will change again and no page will ever fire, so a
    settle that keeps polling for them just burns its whole timeout and
    then blames the last lock pair - which says nothing about what
    happened. tests/condacts.dsf reaches this state ON PURPOSE: its tail
    chains PROCESS 5..14 to prove the PROC_DEPTH limit is enforced, and
    error 3 IS the pass."""
    polls = [(False, False)] * 4
    z = _FakeSettleZ(polls, [0] * 4, errcodes=[0, 0, 3, 3])
    leg = _fake_settle_leg(z, _write_dump(_dump_of([])))
    leg.settle([])
    assert z.polls <= 3, (
        "settle kept polling after the interpreter halted (%d poll(s))"
        % z.polls)
    assert leg.fatal_error() == 3


@case
def t9_a_pager_timeout_turn_lets_the_page_expire_instead_of_pressing():
    """When the FIXTURE has armed a pager timeout - flag 48 non-zero and
    flag 49 bit 1, the same test wait_key_timeout itself makes - and the
    script marked the turn allow_timeout, the harness must press NOTHING
    at a page. Pressing is precisely what would stop the thing the check
    measures (tests/condacts.dsf check 104). Without allow_timeout the
    same state must still be dismissed normally."""
    page = _dump_of(["104 PAGER TIMEOUT"])
    polls = [(True, False), (True, False), (True, True)]

    z = _FakeSettleZ(polls, [1, 1, 1], timeout_flags=(1, 0x02))
    leg = _fake_settle_leg(z, _write_dump(page))
    pages = []
    leg.settle(pages, allow_timeout=True)
    assert len(pages) == 1, pages
    assert z.enters == 0, (
        "a key was sent into a page the fixture armed a timeout for - the "
        "timeout can now never expire and the check can never pass")

    z2 = _FakeSettleZ(list(polls), [1, 1, 1], timeout_flags=(1, 0x02))
    leg2 = _fake_settle_leg(z2, _write_dump(page))
    leg2.settle([])                              # no directive
    assert z2.enters == 1, (
        "an ordinary turn must still dismiss the page: %d" % z2.enters)


@case
def t9_a_wait_turn_arms_the_countdown_once_and_ends_on_output():
    """The wait-turn re-arms the countdown the harness itself zeroed, and
    it must do so EXACTLY ONCE and stop on the screen moving.

    Both halves are regressions. "Re-arm whenever inpTOFrames reads zero"
    cascaded: the read that follows a timed-out one re-takes both locks
    within microseconds (check 58's PARSE is followed straight away by
    check 59's), so a poll never sees the gap, the re-arm fires again,
    and the fixture ran several checks past where the script expected it
    - one run in four, with every later turn then answering the wrong
    prompt. "Wait for the locks to drop" is unusable as the exit for the
    same reason; the screen moving is the event the turn is about.
    """
    import nleg

    before = _dump_of(["58 WAIT - DO NOT TYPE", "What now?>"])
    after = _dump_of(["58 WAIT - DO NOT TYPE", "What now?>", "58 OK"])
    pre_rows, _ = __import__("tilemap").decode(before)

    class _Z(_FakeSettleZ):
        """Parked in a line read throughout: the locks NEVER drop, exactly
        as they do not in the live case."""

        def __init__(self):
            super().__init__([(True, True)] * 40, [0] * 40, grid=before)
            self.polls = 0

        def read_memory(self, addr, length):
            if addr == 0x6000 or length > 2:     # the tilemap grid
                self.polls += 1
                # the timed-out check prints its verdict a few polls in,
                # but ONLY if the countdown was actually armed
                if self.polls > 3 and self.toframes != b"\x00\x00":
                    return after
                return before
            return super().read_memory(addr, length)

    z = _Z()

    def _write(addr, data):
        z.writes.append((addr, bytes(data)))
        if addr == _FAKE_SYMS["INPTOFRAMES"]:
            z.toframes = bytes(data)

    z.write_memory = _write
    leg = _fake_settle_leg(z, _write_dump(before))
    leg.wait_for_input_wait_to_end(pre_rows, arm_frames=100)

    arms = [w for w in z.writes if w[0] == _FAKE_SYMS["INPTOFRAMES"]]
    assert len(arms) == 1, (
        "the countdown was armed %d times - each extra one times out the "
        "NEXT read too and walks the fixture past the script" % len(arms))
    assert arms[0][1] == bytes([100, 0]), arms

    # And the duration comes from the fixture's own flag 48, converted the
    # way inp_edit converts it (flag48 * 50).
    z2 = _FakeSettleZ([(True, True)], [0], timeout_flags=(2, 0))
    assert _fake_settle_leg(z2, _write_dump(before)).armed_timeout_frames() \
        == 100


@case
def t9_script_directives_are_normalised_and_validated():
    """Both legs read the same script and must agree on what a turn means,
    so the shapes are validated rather than best-effort parsed. A
    misspelled directive that is silently ignored is worse than a broken
    script: the turn runs with the default behaviour and the whole run
    still looks valid."""
    import json
    import nleg
    import tempfile

    d = Path(tempfile.mkdtemp())

    def script(obj):
        p = d / ("s%d.json" % abs(hash(json.dumps(obj))))
        p.write_text(json.dumps(obj), encoding="utf-8")
        return p

    got = nleg.load_script(script(["LOOK", {"cmd": "GET LAMP"},
                                   {"cmd": "", "allow_timeout": True}]))
    assert got == [
        {"cmd": "LOOK", "allow_timeout": False},
        {"cmd": "GET LAMP", "allow_timeout": False},
        {"cmd": "", "allow_timeout": True},
    ], got
    assert nleg.script_commands(got) == ["LOOK", "GET LAMP", ""]

    for bad, why in (
            ([{"cmd": "LOOK", "allow_timout": True}], "misspelled directive"),
            ([{"cmd": ""}], "no keys and no timeout ends nothing"),
            ([{"cmd": 7}], "cmd is not a string"),
            ([["LOOK"]], "entry is not a string or object")):
        try:
            nleg.load_script(script(bad))
        except ValueError:
            pass
        else:
            raise AssertionError("load_script accepted %s (%s)" % (bad, why))


@case
def t9_settle_disarms_the_timeout_on_every_poll():
    """Every DAAD wait in NextDAAD counts down the SAME inpTOFrames, but
    only the command line announces itself through moreLock/wrapLock.
    wait_key_timeout (src/print.asm) re-arms it independently from
    prn_more_check (E=$02) and from ANYKEY (E=$04), reading flag 48 fresh
    at the moment the page fires - so a game that re-arms TIME mid-turn
    can time out on a page even though the harness zeroed flag 48 at the
    top of the turn. jDAAD has no counterpart timeout at all, so any such
    expiry is a one-sided, harness-manufactured divergence.

    settle() must therefore clear the countdown on EVERY poll, not only
    when the editor goes ready. Pinned by counting the writes across a
    settle that walks a MORE page before becoming ready.

    Plus ONE more on the way out. Each poll disarms BEFORE reading the
    locks, so on the poll that reports READY the interpreter had the
    whole read window to reach the command line and arm the countdown
    itself - which is precisely what READY means it just did. Nothing
    can expire in that gap (see disarm_input_timeout), but returning
    with a live clock for no reason is a gap worth not having.
    """
    import nleg

    z = _FakeSettleZ([(False, False), (False, False), (True, False), (True, True)],
                     fires=[0, 0, 1, 1])
    leg = _fake_settle_leg(z, _write_dump(_dump_of([])))
    pages = []
    leg.settle(pages)

    disarms = [w for w in z.writes if w[0] == _FAKE_SYMS["INPTOFRAMES"]]
    assert len(disarms) == 5, (
        "expected one disarm per poll (4 polls) plus one on the READY "
        "return, got %d - a wait the harness parks on can now time out "
        "unobserved" % len(disarms))
    assert all(d[1] == b"\x00\x00" for d in disarms), disarms
    assert len(pages) == 1 and z.enters == 1, (
        "the MORE page must still be captured and dismissed exactly once")
    # Flag writes are the caller's job and must not creep in here: flag 48
    # is COMPARED, and both legs must write it at the same logical point
    # (docs/parser-bugs.md entry 5's flag-48 retraction).
    assert not [w for w in z.writes if w[0] != _FAKE_SYMS["INPTOFRAMES"]], (
        "settle() must write nothing but inpTOFrames: %s" % z.writes)


# ---- Task 10: report -------------------------------------------------------

@case
def t10_finding_carries_handler_pointer():
    import report
    divs = [{"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 3,
             "command": "GET LAMP",
             "flag_diffs": [{"flag": 12, "ref": 0, "nd": 3}],
             "objloc_diffs": [], "text_ref": "Taken.", "text_nd": "Taken."}]
    dsf = "/PRO 0\n> _ _ GET 51\n              LET 12 0\n              RANDOM 12\n"
    findings = report.build_findings(divs, {95: "h_random", 38: "h_message"}, dsf)
    assert len(findings) == 1
    names = [c["name"] for c in findings[0]["suspect_condacts"]]
    assert "RANDOM" in names, names
    handlers = [c["handler"] for c in findings[0]["suspect_condacts"]]
    assert "h_random" in handlers, handlers


@case
def t10_repro_is_command_prefix():
    import report
    divs = [{"class": "both", "state_rank": "primary", "text_rank": "primary", "turn": 2, "command": "N",
             "flag_diffs": [], "objloc_diffs": [],
             "text_ref": "a", "text_nd": "b"}]
    findings = report.build_findings(divs, {}, "", commands=["LOOK", "S", "N", "E"])
    assert findings[0]["repro"] == ["LOOK", "S", "N"], findings[0]["repro"]


@case
def t10_writes_both_files():
    import json
    import report
    import tempfile
    divs = [{"class": "text-only", "state_rank": None, "text_rank": "primary", "turn": 0, "command": "LOOK",
             "flag_diffs": [], "objloc_diffs": [],
             "text_ref": "Here.", "text_nd": "There."}]
    findings = report.build_findings(divs, {}, "")
    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    assert (d / "report.md").exists()
    data = json.loads((d / "findings.json").read_text(encoding="utf-8"))
    assert data["findings"][0]["class"] == "text-only"


@case
def t10_caveats_from_nd_turns_reach_findings_and_report():
    import json
    import report
    import tempfile
    # Two divergences on different turns
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None,
         "turn": 2, "command": "GET LAMP",
         "flag_diffs": [{"flag": 5, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "Taken.", "text_nd": "Taken."},
        {"class": "text-only", "state_rank": None, "text_rank": "downstream",
         "turn": 5, "command": "LOOK",
         "flag_diffs": [], "objloc_diffs": [],
         "text_ref": "Dark room.", "text_nd": "Light room."}
    ]
    # nd_turns: turn 2 has caveats, turn 5 has no caveats
    nd_turns = [
        {"turn": 2, "text_ambiguous": True, "anykey_heuristic": False,
         "timing_sensitive": True},
        {"turn": 5, "text_ambiguous": False, "anykey_heuristic": False,
         "timing_sensitive": False}
    ]
    findings = report.build_findings(divs, {}, "", nd_turns=nd_turns)

    # Finding for turn 2 should have caveats
    assert len(findings[0]["caveats"]) == 2, findings[0]["caveats"]
    caveat_names = [c["name"] for c in findings[0]["caveats"]]
    assert "text_ambiguous" in caveat_names
    assert "timing_sensitive" in caveat_names
    # Caveats should have meanings
    for c in findings[0]["caveats"]:
        assert "meaning" in c and len(c["meaning"]) > 0, c

    # Finding for turn 5 should have no caveats
    assert len(findings[1]["caveats"]) == 0, findings[1]["caveats"]

    # Test graceful degradation when turn has no nd entry
    divs2 = [{"class": "text-only", "state_rank": None, "text_rank": "primary",
              "turn": 99, "command": "LOOK",
              "flag_diffs": [], "objloc_diffs": [],
              "text_ref": "a", "text_nd": "b"}]
    findings2 = report.build_findings(divs2, {}, "", nd_turns=nd_turns)
    assert len(findings2[0]["caveats"]) == 0, findings2[0]["caveats"]

    # Test that caveats reach report.md with their meanings
    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    md_content = (d / "report.md").read_text(encoding="utf-8")
    assert "text_ambiguous" in md_content
    assert "timing_sensitive" in md_content
    # Check that meanings are included (not just names)
    assert "screen both scrolled" in md_content or "stale rows" in md_content

    # Verify findings.json has caveats with meanings
    json_data = json.loads((d / "findings.json").read_text(encoding="utf-8"))
    f0_caveats = json_data["findings"][0]["caveats"]
    assert len(f0_caveats) == 2
    for c in f0_caveats:
        assert "name" in c and "meaning" in c


@case
def t10_suspects_narrowed_by_command_verb():
    import report
    # DSF with two different entries: one for GET, one for LOOK
    dsf = """/PRO 0
> GET _ GET 51
              LET 12 0
> LOOK _ PRINT 10
              LET 12 0
"""
    # Two divergences with different commands
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
         "command": "GET LAMP",
         "flag_diffs": [{"flag": 5, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "", "text_nd": ""},
        {"class": "state-only", "state_rank": "downstream", "text_rank": None, "turn": 1,
         "command": "LOOK",
         "flag_diffs": [{"flag": 5, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "", "text_nd": ""}
    ]
    condacts = {51: "h_get", 12: "h_let", 10: "h_print"}
    findings = report.build_findings(divs, condacts, dsf)

    # First finding (GET) should have GET and LET (same entry)
    names_0 = [c["name"] for c in findings[0]["suspect_condacts"]]
    assert "GET" in names_0, names_0
    assert "LET" in names_0, names_0
    assert "PRINT" not in names_0, "PRINT is in LOOK entry, not GET"
    assert findings[0]["suspects_narrowed"] is True

    # Second finding (LOOK) should have PRINT and LET (same entry)
    names_1 = [c["name"] for c in findings[1]["suspect_condacts"]]
    assert "PRINT" in names_1, names_1
    assert "LET" in names_1, names_1
    assert "GET" not in names_1, "GET is in GET entry, not LOOK"
    assert findings[1]["suspects_narrowed"] is True


@case
def t10_chained_headers_share_condact_body():
    import report
    # DSF with chained headers (consecutive > lines sharing one body)
    # Modeled on rabenstein.dsf lines 1325-1329
    dsf = """/PRO 0
> EX WARDROB
> OPEN WARDROB
AT 7
MESSAGE 0
DONE
"""
    condacts = {0: "h_at", 38: "h_message", 120: "h_done"}
    # Two divergences: one on EX, one on OPEN
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
         "command": "EX WARDROB",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""},
        {"class": "state-only", "state_rank": "downstream", "text_rank": None, "turn": 1,
         "command": "OPEN WARDROB",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""}
    ]
    findings = report.build_findings(divs, condacts, dsf)

    # Both EX and OPEN should get the SAME non-empty condact list
    ex_condacts = [c["name"] for c in findings[0]["suspect_condacts"]]
    open_condacts = [c["name"] for c in findings[1]["suspect_condacts"]]

    # Both should include the shared body condacts
    for name_list in [ex_condacts, open_condacts]:
        assert "AT" in name_list, "Both should have AT from shared body: %s" % name_list
        assert "MESSAGE" in name_list, "Both should have MESSAGE: %s" % name_list
        assert "DONE" in name_list, "Both should have DONE: %s" % name_list

    # The lists should be identical (same body, different verbs)
    assert sorted(ex_condacts) == sorted(open_condacts), \
        "Chained headers should share identical condact bodies"


@case
def t10_narrowed_flag_reflects_verb_match():
    import report
    # DSF with wildcard entries AND verb-specific entries
    dsf = """/PRO 0
> _ _ PARSE 0
              LET 12 0
> GET _ DESCRIBE 9
              MESSAGE 38 0
> LOOK _ PRINT 10
"""
    condacts = {0: "h_parse", 12: "h_let", 9: "h_describe",
                38: "h_message", 10: "h_print"}

    # Test 1: narrowed=False for empty command (only wildcards)
    divs1 = [{"class": "truncated", "state_rank": "primary", "text_rank": "primary", "turn": 0,
              "command": "",
              "flag_diffs": [], "objloc_diffs": [],
              "text_ref": "5 turns", "text_nd": "4 turns"}]
    findings1 = report.build_findings(divs1, condacts, dsf)
    assert findings1[0]["suspects_narrowed"] is False, \
        "Empty command should be narrowed=False (only wildcards)"
    # But should still include wildcard condacts
    names1 = [c["name"] for c in findings1[0]["suspect_condacts"]]
    assert "PARSE" in names1, "Wildcard entries should still be included"
    assert "LET" in names1, "Wildcard body should be included"

    # Test 2: narrowed=True for GET command (matches verb-specific entry)
    divs2 = [{"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
              "command": "GET LAMP",
              "flag_diffs": [], "objloc_diffs": [],
              "text_ref": "", "text_nd": ""}]
    findings2 = report.build_findings(divs2, condacts, dsf)
    assert findings2[0]["suspects_narrowed"] is True, \
        "GET command should be narrowed=True (verb-specific match)"
    names2 = [c["name"] for c in findings2[0]["suspect_condacts"]]
    assert "DESCRIBE" in names2, "GET entry should have DESCRIBE"
    assert "MESSAGE" in names2, "GET entry body should have MESSAGE"
    # Wildcards still included even when narrowed
    assert "PARSE" in names2, "Wildcard entries should be included even when narrowed"
    assert "PRINT" not in names2, "LOOK entry should NOT be included for GET command"

    # Test 3: narrowed=False for unknown verb (only wildcards)
    divs3 = [{"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
              "command": "UNKNOWN VERB",
              "flag_diffs": [], "objloc_diffs": [],
              "text_ref": "", "text_nd": ""}]
    findings3 = report.build_findings(divs3, condacts, dsf)
    assert findings3[0]["suspects_narrowed"] is False, \
        "Unknown verb should be narrowed=False (only wildcards)"
    names3 = [c["name"] for c in findings3[0]["suspect_condacts"]]
    assert "PARSE" in names3, "Wildcard entries should be included"


@case
def t10_blank_lines_between_chained_headers():
    import report
    # DSF with blank line between chained headers
    # Modeled on the reproduction case from the specification
    dsf = """/PRO 0
> EX WARDROB

> OPEN WARDROB
AT 7
MESSAGE 0
DONE
"""
    condacts = {0: "h_at", 38: "h_message", 120: "h_done"}
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
         "command": "EX WARDROB",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""},
        {"class": "state-only", "state_rank": "downstream", "text_rank": None, "turn": 1,
         "command": "OPEN WARDROB",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""}
    ]
    findings = report.build_findings(divs, condacts, dsf)

    # Both EX and OPEN should get the shared body (blank line should not break the run)
    ex_condacts = [c["name"] for c in findings[0]["suspect_condacts"]]
    open_condacts = [c["name"] for c in findings[1]["suspect_condacts"]]

    # Both should have non-empty condact lists from the shared body
    assert len(ex_condacts) > 0, "EX should have condacts from shared body"
    assert len(open_condacts) > 0, "OPEN should have condacts from shared body"
    assert sorted(ex_condacts) == sorted(open_condacts), \
        "Blank lines between headers should not break the run"


@case
def t10_no_backward_leakage_past_blank_line():
    import report
    # DSF with blank line after a completed entry body, then a new header
    # Ensures blank line doesn't cause the new entry to absorb the previous body
    dsf = """/PRO 0
> GET LAMP
TAKE 1
DONE

> LOOK _
PRINT 2
DONE
"""
    condacts = {1: "h_take", 120: "h_done", 10: "h_print"}
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None, "turn": 0,
         "command": "GET LAMP",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""},
        {"class": "state-only", "state_rank": "downstream", "text_rank": None, "turn": 1,
         "command": "LOOK",
         "flag_diffs": [], "objloc_diffs": [], "text_ref": "", "text_nd": ""}
    ]
    findings = report.build_findings(divs, condacts, dsf)

    # GET should have TAKE, LOOK should have PRINT (no leakage)
    get_condacts = [c["name"] for c in findings[0]["suspect_condacts"]]
    look_condacts = [c["name"] for c in findings[1]["suspect_condacts"]]

    assert "TAKE" in get_condacts, "GET should have TAKE"
    assert "PRINT" not in get_condacts, "GET should NOT have PRINT (no backward leakage)"
    assert "PRINT" in look_condacts, "LOOK should have PRINT"
    assert "TAKE" not in look_condacts, "LOOK should NOT have TAKE (no forward leakage)"


@case
def t10_state_and_text_rank_reach_findings_report_and_json():
    """The reframe's per-channel ranking (compare.py) must survive the
    whole pipeline: findings.json carries state_rank/text_rank
    independently, report.md's header shows both labelled clearly, and a
    "both" finding can legitimately show primary on one channel and
    downstream on the other - that combination is exactly the point.
    """
    import json
    import report
    import tempfile
    divs = [
        {"class": "both", "state_rank": "primary", "text_rank": "downstream",
         "turn": 1, "command": "GET LAMP",
         "flag_diffs": [{"flag": 5, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "A.", "text_nd": "B."},
        {"class": "text-only", "state_rank": None, "text_rank": "primary",
         "turn": 0, "command": "LOOK",
         "flag_diffs": [], "objloc_diffs": [],
         "text_ref": "Dark room.", "text_nd": "Light room."},
    ]
    findings = report.build_findings(divs, {}, "")
    assert findings[0]["state_rank"] == "primary", findings[0]
    assert findings[0]["text_rank"] == "downstream", findings[0]
    assert findings[1]["state_rank"] is None, findings[1]
    assert findings[1]["text_rank"] == "primary", findings[1]

    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    md = (d / "report.md").read_text(encoding="utf-8")
    assert "state: primary" in md, md
    assert "text: downstream" in md, md
    assert "text: primary" in md, md

    json_data = json.loads((d / "findings.json").read_text(encoding="utf-8"))
    assert json_data["findings"][0]["state_rank"] == "primary"
    assert json_data["findings"][0]["text_rank"] == "downstream"
    assert json_data["findings"][1]["state_rank"] is None
    assert json_data["findings"][1]["text_rank"] == "primary"


@case
def t10_primary_count_counts_either_channel_primary():
    """report.md's summary line ("N finding(s), M primary") must count a
    finding as primary if EITHER channel is primary for it, not just when
    a single global rank says so - otherwise a text-primary finding that
    happens to follow an earlier state divergence would be undercounted.
    """
    import report
    import tempfile
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None,
         "turn": 0, "command": "N", "flag_diffs": [{"flag": 1, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "a", "text_nd": "a"},
        {"class": "text-only", "state_rank": None, "text_rank": "primary",
         "turn": 1, "command": "LOOK", "flag_diffs": [], "objloc_diffs": [],
         "text_ref": "x", "text_nd": "y"},
        {"class": "state-only", "state_rank": "downstream", "text_rank": None,
         "turn": 2, "command": "S", "flag_diffs": [{"flag": 1, "ref": 0, "nd": 1}],
         "objloc_diffs": [], "text_ref": "a", "text_nd": "a"},
    ]
    findings = report.build_findings(divs, {}, "")
    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    md = (d / "report.md").read_text(encoding="utf-8")
    assert "3 finding(s), 2 primary." in md, md.splitlines()[2]


@case
def t10_transcript_section_carries_verbatim_unnormalised_text():
    """The new side-by-side transcript section must list every divergent
    turn's command and BOTH legs' raw captured text verbatim (including
    whitespace/wrapping the structured findings' normalisation would
    otherwise treat as equal) - this is the view that let the original
    Dracula agent spot a missing system message by just reading both
    transcripts, which is exactly what a filtered/classified findings
    list on its own does not give an agent.
    """
    import report
    import tempfile
    divs = [
        {"class": "state-only", "state_rank": "primary", "text_rank": None,
         "turn": 14, "command": "GET LAMP",
         "flag_diffs": [{"flag": 29, "ref": 129, "nd": 0}],
         "objloc_diffs": [],
         "text_ref": "I now have the quaint lamp, unlit.\nI pick up the quaint lamp..",
         "text_nd": "I pick up the quaint lamp.."},
    ]
    findings = report.build_findings(divs, {}, "")
    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    md = (d / "report.md").read_text(encoding="utf-8")
    assert "## Transcript" in md, md
    assert "### Turn 14 - `GET LAMP`" in md, md
    assert "I now have the quaint lamp, unlit." in md, md
    assert "I pick up the quaint lamp.." in md, md


@case
def t10_transcript_absent_when_no_findings():
    import report
    import tempfile
    findings = report.build_findings([], {}, "")
    d = Path(tempfile.mkdtemp())
    report.write_report(findings, d / "report.md", d / "findings.json")
    md = (d / "report.md").read_text(encoding="utf-8")
    assert "## Transcript" not in md, md


# ---- Task 11: end to end ---------------------------------------------------

# The clean run's actual job is narrower than "zero findings": prove the
# harness produces no FALSE positives and catches NEW divergences - not
# that tests/condacts.dsf is bug-free, which it demonstrably is not.
# tests/condacts.dsf's own automated self-test suite hits a small,
# reproducible set of NextDAAD-vs-jDAAD divergences before the smoke
# script's own scripted commands even finish - see docs/parser-bugs.md
# entry 5. These are UNCONFIRMED CANDIDATE NextDAAD faults, not proven
# root-caused bugs - jDAAD is this harness's reference leg by convention,
# not automatically "the correct" interpreter. That said, when entry 4's
# QUIT-confirmation question was finally put to the ORIGINAL ZX
# interpreter (SP16 Task 5, .superpowers/sdd/sp16-adjudications/), jDAAD
# turned out to be right and NextDAAD's single-key read was the
# deviation - so "the reference is probably wrong" is a hypothesis to
# test, not a default.
# This baseline records CURRENT REALITY, not desired behaviour -
# shrinking it (because a candidate fault gets fixed or disproven) is
# the goal; it should only grow if a genuinely new, confirmed divergence
# is deliberately added.
#
# Shrunk from {29, 50, 53} to {50} over SP16: flag 29 (fGFlags) was fixed
# in Task 1 and flag 53 (the DOALL "nothing found" bit) in Task 4, and a
# fresh clean run now sees neither. Flag 50 REMAINS, and it is not a
# NextDAAD fault so far as anyone has shown: jDAAD saves and restores
# flag 50 (FDOALL) per PROCESS-STACK LEVEL - stackPush stores
# flags.getFlag(FDOALL) into the stack element (jdaad.js:853) and
# stackPop writes it straight back (jdaad.js:841) - so a nested PROCESS
# cannot see or keep the caller's DOALL flag. NextDAAD keeps flag 50
# GLOBAL, and so does msx2daad, which is why the harness reports it on
# every turn that crosses a process boundary.
#
# RULED 2026-08-01: accept and document. NextDAAD keeps the msx2daad
# model and jDAAD's per-level save/restore is recorded as THE deviation,
# because msx2daad shares NextDAAD's operating environment (a memory-
# constrained 8-bit interpreter) where jDAAD is a browser interpreter
# that can afford a saved copy on every process-stack push. No code
# change was made and none will be: this is a PERMANENT documented
# reference-deviation of class NOT-A-BUG (docs/parser-bugs.md entry 5,
# manual/known-differences.md).
#
# The pin therefore STAYS at exactly {50}, permanently. Note what it is
# and is not: it is NOT a mask. The flag 50 rows keep appearing in every
# findings.json, which is deliberate - visibility beats masking. What
# the pin asserts is that flag 50 is the ONLY flag that ever diverges,
# so if a second one ever joins it the assertion fails and someone looks.
KNOWN_DIVERGENT_FLAGS = {50}
# Re-baselined (objtable-stride-fix): nleg.py's objloc() previously read
# obj_count CONSECUTIVE BYTES starting at OBJTABLE, but objTable
# (src/engine.asm) is a 6-byte-per-record STRUCT ARRAY (OBJ_SIZE in
# src/nextdaad.inc), not a flat location array - so every "object
# divergence" this harness ever reported, including this {1, 2} set, was
# reading record 0's attribute/extended-attribute/noun/adjective bytes as
# if they were objects 1-5. With the read corrected (see nleg.py's
# NextLeg.objloc), re-running this exact fixture/script three times
# straight shows ZERO object divergences on every turn - the object
# baseline was entirely a harness artifact, never a real one. Left empty
# rather than deleted so a future regression here is caught the same way
# a silently-shrunk flag baseline would be (see the module's own note on
# shrinking vs disappearing).
KNOWN_DIVERGENT_OBJECTS = set()


@case
def t11_clean_run_matches_known_divergence_baseline():
    import json
    import subprocess
    here = Path(__file__).resolve().parent
    out = ROOT / "tests" / "parser" / "work" / "e2e-clean"
    res = subprocess.run(
        ["python", str(here / "parsertest.py"),
         str(ROOT / "tests" / "condacts.dsf"),
         str(here / "scripts" / "condacts" / "smoke.json"),
         "--out", str(out)],
        capture_output=True, text=True)
    findings = json.loads(
        (out / "findings.json").read_text(encoding="utf-8"))["findings"]

    # The harness itself has no concept of a "baseline" - it exits 1
    # whenever ANY findings exist, full stop. A clean run against THIS
    # fixture is expected to keep reporting the known set, so exit 0 here
    # would itself be surprising (the harness silently stopped seeing
    # something real), not a pass condition.
    assert res.returncode == 1, (
        "expected the known-divergence set to still be reported (see "
        "docs/parser-bugs.md entry 5):\n%s\n%s"
        % (res.stdout, json.dumps(findings[:3], indent=2)))

    seen_flags, seen_objects = set(), set()
    for f in findings:
        flags_here = {fd["flag"] for fd in f["flag_diffs"]}
        objects_here = {od["obj"] for od in f["objloc_diffs"]}

        # No NEW divergence: everything this finding blames must already
        # be in the known baseline - a regression, or a newly-exposed
        # fault, shows up here as a flag/object outside the baseline set.
        assert flags_here <= KNOWN_DIVERGENT_FLAGS, (
            "turn %d diverges on flag(s) %s, outside the known baseline "
            "%s - this looks like a NEW divergence, not entry 5's set"
            % (f["turn"], sorted(flags_here - KNOWN_DIVERGENT_FLAGS),
               sorted(KNOWN_DIVERGENT_FLAGS)))
        assert objects_here <= KNOWN_DIVERGENT_OBJECTS, (
            "turn %d diverges on object(s) %s, outside the known baseline "
            "%s - this looks like a NEW divergence, not entry 5's set"
            % (f["turn"], sorted(objects_here - KNOWN_DIVERGENT_OBJECTS),
               sorted(KNOWN_DIVERGENT_OBJECTS)))
        # No new PURELY TEXTUAL divergence either: a finding with NEITHER
        # a flag nor an object cause means state matched perfectly yet a
        # divergence was still reported - a genuine new text-channel
        # fault the two checks above cannot see at all, since they only
        # look at what a finding blames, not whether one exists.
        assert flags_here or objects_here, (
            "turn %d has a divergence with no flag or object cause at "
            "all (a new, purely textual divergence) - not covered by the "
            "known baseline; investigate before adding to it: %s"
            % (f["turn"], f))
        seen_flags |= flags_here
        seen_objects |= objects_here

    # No DISAPPEARED divergence either: if the harness stops reporting
    # something in the baseline, that is either good news (NextDAAD was
    # fixed - shrink the baseline) or bad news (the harness broke) - it
    # must not pass silently either way.
    assert seen_flags == KNOWN_DIVERGENT_FLAGS, (
        "expected flags %s to diverge somewhere in this run, only saw %s "
        "- if NextDAAD was fixed, shrink KNOWN_DIVERGENT_FLAGS; if not, "
        "the harness stopped detecting a known-real divergence"
        % (sorted(KNOWN_DIVERGENT_FLAGS), sorted(seen_flags)))
    assert seen_objects == KNOWN_DIVERGENT_OBJECTS, (
        "expected objects %s to diverge somewhere in this run, only saw "
        "%s - if NextDAAD was fixed, shrink KNOWN_DIVERGENT_OBJECTS; if "
        "not, the harness stopped detecting a known-real divergence"
        % (sorted(KNOWN_DIVERGENT_OBJECTS), sorted(seen_objects)))


@case
def t11_text_channel_known_limitation_pin():
    """CAPTURE-SYMMETRY PIN. Was a known-LIMITATION pin; SP16 Task 0
    repaired what it used to record, and per its own instruction the
    numbers were TIGHTENED rather than the test deleted. Every number
    below is re-derived from tests/parser/work/e2e-clean's own
    jsonl/findings.json, not carried over.

    What it used to pin, and what each became:

      - jDAAD's capture ended EVERY turn with a trailing '_' cursor
        glyph (jdaad.js readText: writeText(readTextStr + '_')) while
        NextDAAD's never did, because NextDAAD's cursor is an ATTRIBUTE
        inversion (src/overlay1.asm inp_cursor_put) that a glyph-only
        tilemap capture cannot see. 13/13 -> 0/13: jleg.js now suppresses
        the cursor glyph for the duration of readText only.
      - NextDAAD's capture included the typed command echo ("What now?
        >LOOK") while jleg.js suppressed its own (key(ch, false)).
        >= 1 -> 0: nleg.py now anchors each turn's `pre` grid AFTER the
        echo lands and BEFORE Enter.
      - tilemap.scroll_delta misclassified most turns, so new_text
        re-emitted large stale regions and 12/13 turns carried
        text_ambiguous=True. 12/13 -> 0/13, and NOT by touching
        scroll_delta: the echo was itself an in-place row edit competing
        with the turn's scroll, which is exactly the transition no single
        shift explains. Removing the echo from the compared window made
        every turn in this fixture a clean scroll.

    The consequence worth stating plainly, because it is what the whole
    repair was for: this fixture's text channel now AGREES on all 13
    turns, so the findings are state-only apart from the one "?" turn
    described below. The only flag left in them is 50 - see
    KNOWN_DIVERGENT_FLAGS above; flags 29 and 53 were in this set when
    the pin was written and were fixed in SP16 Tasks 1 and 4. Any text
    finding that appears here from now on is pointed evidence about a
    specific turn, not the capture models disagreeing with each other on
    every turn alike.

    Depends on t11_clean_run_matches_known_divergence_baseline
    (immediately above) having just produced e2e-clean's jsonl and
    findings.json in this same run.
    """
    import json
    out = ROOT / "tests" / "parser" / "work" / "e2e-clean"
    nd_path = out / "next.jsonl"
    ref_path = out / "jdaad.jsonl"
    assert nd_path.exists() and ref_path.exists(), (
        "expected t11_clean_run_matches_known_divergence_baseline to have "
        "just produced %s and %s" % (nd_path, ref_path))
    nd_turns = [json.loads(l) for l in
                nd_path.read_text(encoding="utf-8").splitlines() if l.strip()]
    ref_turns = [json.loads(l) for l in
                 ref_path.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(nd_turns) == 13 and len(ref_turns) == 13, (
        "fixture turn count changed (%d nd, %d ref, expected 13 each) - "
        "re-derive every number below against the new run before touching "
        "this test" % (len(nd_turns), len(ref_turns)))

    # Cause 1: trailing cursor glyph - must now be absent from BOTH legs.
    ref_cursor = sum(1 for t in ref_turns if t["text"].endswith("_"))
    nd_cursor = sum(1 for t in nd_turns if t["text"].endswith("_"))
    assert ref_cursor == 0, (
        "jDAAD's capture ended %d/13 turns with the '_' cursor glyph "
        "(expected 0) - jleg.js's readText cursor suppression has "
        "regressed, or jdaad.js draws the cursor from somewhere else now"
        % ref_cursor)
    assert nd_cursor == 0, (
        "expected NextDAAD to end NO turn with '_' (got %d/13)" % nd_cursor)

    # Cause 2: the typed command must NOT appear echoed in the Next leg's
    # captured text. Matched as its own prompt-echo line rather than as a
    # bare substring - a one-letter command like "N" or "I" occurs inside
    # ordinary game prose constantly and would make a substring test
    # meaningless.
    echoed = sum(1 for t in nd_turns
                 if t["command"] and not t["command"].startswith(("!", "?"))
                 and any(line.rstrip().endswith(">" + t["command"])
                         for line in t["text"].splitlines()))
    assert echoed == 0, (
        "%d NextDAAD turn(s) still carry their own typed command echo "
        "(expected 0) - nleg.py's per-turn `pre` anchor has regressed; it "
        "must be captured AFTER the echo and BEFORE Enter" % echoed)

    # Cause 3: text_ambiguous rate. Must stay AT OR BELOW today's level -
    # a rise means the capture got less trustworthy again. This does not
    # suppress anything (see compare.py); it drives the text_ambiguous
    # CAVEAT attached to whatever finding lands on that turn, and zero
    # caveats means every finding here carries full-strength evidence.
    ambiguous = sum(1 for t in nd_turns if t.get("text_ambiguous"))
    assert ambiguous == 0, (
        "text_ambiguous rose to %d/13 (expected 0) - the screen-transition "
        "capture regressed; do not loosen this number, find what made a "
        "turn ambiguous again" % ambiguous)

    # The text channel agrees on every turn of this fixture EXCEPT the
    # one that answers a confirmation prompt, where it differs by exactly
    # the echoed reply character.
    #
    # That one exception is understood and is a harness artefact, not an
    # interpreter divergence. Since SP16 Task 5 settled parser-bugs entry
    # 4, NextDAAD reads the QUIT confirmation as a LINE and echoes the
    # reply - as the original ZX interpreter does ("Are you sure?>Y").
    # jleg.js suppresses jDAAD's own echo, because the two draw different
    # cursors behind it (jDAAD a "_" glyph, NextDAAD an inverted
    # attribute the tilemap read cannot see) and comparing the echo would
    # compare cursor styling. nleg.py cannot drop its side the way it
    # does for a plain command: a ONE-character echo races the grid read,
    # and anchoring on "the first change after the key" mis-fires because
    # the boot settle does not always stop AT the prompt. See the "?"
    # branch in nleg.play for the two measured attempts.
    #
    # So: state-only everywhere, plus at most one "both" and only on a
    # "?" turn. Anything else is news.
    findings = json.loads(
        (out / "findings.json").read_text(encoding="utf-8"))["findings"]
    classes = {f["class"] for f in findings}
    assert classes <= {"state-only", "both"}, (
        "expected every finding in this fixture to be state-only, or the "
        "confirmation turn's known echo difference - got %s. A text "
        "divergence appeared where the text channel previously agreed; "
        "investigate it before touching this assertion" % sorted(classes))
    texty = [f for f in findings if f["class"] != "state-only"]
    assert all(f["command"].startswith("?") for f in texty), (
        "a text divergence appeared on a turn that does NOT answer a "
        "confirmation prompt: %s. That is not the known echo artefact - "
        "investigate it before touching this assertion"
        % [(f["turn"], f["command"]) for f in texty
           if not f["command"].startswith("?")])
    assert "text-unclassifiable" not in classes, (
        "text-unclassifiable is no longer a class compare.py can produce")


@case
def t11_negative_control_is_detected():
    """Mutate the fixture on the STATE channel so the two legs MUST
    disagree, and confirm the harness says so - not merely that SOME
    findings exist (condacts.dsf's own boot self-test already produces
    13 of those with nothing mutated at all, byte-identical in count and
    (turn, class, flags, objects) shape to a clean run - a fully-blind
    harness would pass a bare non-empty check unchanged), but that a
    finding blames something OUTSIDE the known baseline - proof the
    mutation itself, not the fixture's pre-existing divergences, was
    what got detected.
    """
    import json
    import subprocess
    here = Path(__file__).resolve().parent
    work = ROOT / "tests" / "parser" / "work" / "e2e-mutant"
    work.mkdir(parents=True, exist_ok=True)

    src = (ROOT / "tests" / "condacts.dsf").read_text(encoding="utf-8",
                                                      errors="replace")
    # Plant the mutation on the STATE channel: flag 210 is not referenced
    # anywhere in tests/condacts.dsf (verified: no LET/EQ/PLUS/etc. or any
    # other numeric argument in the fixture names 210), so a distinctive
    # value appearing there can only be explained by this mutation - never
    # by a pre-existing divergence, and never invisible the way a mutated
    # SYSTEM MESSAGE string turned out to be (the mutated text never
    # appeared in either leg's captured text on any turn, because the
    # text channel cannot be trusted here - see
    # t11_text_channel_known_limitation_pin above). The LET is inserted
    # into PRO 0's boot entry, BEFORE "PROCESS 1" hands off to the huge
    # self-test suite, so it runs unconditionally and exactly once at
    # boot, then never again - flag 210 stays diverged on every captured
    # turn thereafter, the same "present before the script's own commands
    # run" shape as the real KNOWN_DIVERGENT_FLAGS baseline.
    marker = "        MESSAGE 0\n        PROCESS 1\n"
    mutated_marker = "        MESSAGE 0\n        LET 210 77\n        PROCESS 1\n"
    assert marker in src, (
        "PRO 0's boot entry no longer has the expected shape - update "
        "the mutation site before trusting this test")
    mutant = work / "mutant.dsf"
    mutant.write_text(src.replace(marker, mutated_marker, 1), encoding="utf-8")
    assert mutant.read_text(encoding="utf-8") != src, "mutation did not apply"

    res = subprocess.run(
        ["python", str(here / "parsertest.py"), str(mutant),
         str(here / "scripts" / "condacts" / "smoke.json"),
         "--out", str(work / "out"), "--mutate-next-only"],
        capture_output=True, text=True)
    findings = json.loads(
        (work / "out" / "findings.json").read_text(encoding="utf-8"))
    assert res.returncode == 1, "harness must report failure"
    assert findings["findings"], "negative control produced no findings"

    # The teeth: a SET DIFFERENCE against the SAME baseline the clean-run
    # test uses (KNOWN_DIVERGENT_FLAGS, above), not a bare non-empty
    # check. Every finding's flag_diffs is unioned and compared against
    # the baseline - the mutant run must blame at least one flag the
    # clean baseline never does, and it must specifically be flag 210,
    # the one this test planted.
    mutant_flags = set()
    for f in findings["findings"]:
        mutant_flags |= {fd["flag"] for fd in f["flag_diffs"]}
    new_flags = mutant_flags - KNOWN_DIVERGENT_FLAGS
    assert new_flags, (
        "mutant run's flag divergences (%s) are entirely within the known "
        "baseline (%s) - the harness re-reported only the fixture's "
        "PRE-EXISTING divergences, not the planted mutation. A harness "
        "that had gone completely blind to new state divergences would "
        "fail this exact way while still passing a bare non-empty check"
        % (sorted(mutant_flags), sorted(KNOWN_DIVERGENT_FLAGS)))
    assert 210 in new_flags, (
        "expected the planted flag 210 mutation among the new "
        "divergences (%s) - got a different new flag instead, which "
        "means something other than the intended mutation was detected"
        % sorted(new_flags))


# ---- Task 11: RNG-seed breakpoint fix (zrcp additions) - pure logic only --
# No running emulator needed for these - see nleg._seed_rng_via_breakpoint
# and zrcp.py's enter_cpu_step/set_breakpoint/run/cpu_step/exit_cpu_step
# additions for the live-verified sequence these support.

@case
def t11_pc_breakpoint_condition_formatting():
    import zrcp
    assert zrcp.pc_breakpoint_condition(39996) == "PC=39996", \
        zrcp.pc_breakpoint_condition(39996)
    assert zrcp.pc_breakpoint_condition(0) == "PC=0"
    try:
        zrcp.pc_breakpoint_condition(-1)
        assert False, "expected ValueError for a negative address"
    except ValueError as e:
        assert "negative" in str(e), e


@case
def t11_prompt_strip_handles_plain_and_cpu_step_forms():
    """enter-cpu-step changes ZRCP's prompt from "command> " to
    "command@cpu-step> " (confirmed live - the original exact-suffix
    match on "command> " never matched that form, so _read_until_prompt
    hung until its deadline the first time this was tried). Both forms
    must be recognised and stripped.
    """
    import zrcp
    assert zrcp._strip_prompt("some output\ncommand> ") == "some output"
    assert zrcp._strip_prompt("some output\ncommand@cpu-step> ") == "some output"
    assert zrcp._strip_prompt("command> ") == ""
    assert zrcp._strip_prompt("command@cpu-step> ") == ""


@case
def t11_breakpoint_control_command_formatting():
    """Pin the exact command strings the new Zrcp methods send - each
    confirmed live against a running ZEsarUX (12.1 originally, re-confirmed
    against 13.0 on 2026-07-31): breakpoint indices are 1-based,
    set-breakpoint takes "index condition" as separate tokens, and
    set-register takes "register=value" as ONE token (no space -
    "set-register HL A5C3" replies "Error changing register";
    "set-register HL=42435" - decimal, not "A5C3" - is what actually
    works).

    The ORDER is pinned too, and it is load-bearing: ZEsarUX 13.0 rejects
    set-breakpoint while breakpoints are disabled ("Error. You must enable
    breakpoints first"), so enable-breakpoints must come FIRST. 12.1
    accepted either order, which is why the harness shipped with the wrong
    one and only failed - silently, as a 60s run() timeout with nothing
    armed - once tools/DAAD-READY/TOOLS/zesarux was upgraded.
    """
    import zrcp

    class _Dummy(zrcp.Zrcp):
        def __init__(self):
            self.sent = []

        def cmd(self, text, wait=0.0, deadline=zrcp.DEFAULT_DEADLINE):
            self.sent.append(text)
            return ""

    z = _Dummy()
    z.enter_cpu_step()
    z.enable_breakpoints()
    z.set_breakpoint(1, zrcp.pc_breakpoint_condition(39996))
    z.run(deadline=5.0)
    z.cpu_step()
    z.disable_breakpoints()
    z.exit_cpu_step()
    assert z.sent == [
        "enter-cpu-step",
        "enable-breakpoints",
        "set-breakpoint 1 PC=39996",
        "run",
        "cpu-step",
        "disable-breakpoints",
        "exit-cpu-step",
    ], z.sent


@case
def t11_breakpoint_errors_are_not_swallowed():
    """A rejected set-breakpoint/enable-breakpoints must RAISE, not be
    discarded. Regression pin for the ZEsarUX 13.0 ordering break: the
    emulator answered "Error. You must enable breakpoints first" on every
    run, Zrcp.cmd's caller threw the reply away, and the only symptom was
    run() blocking for its full 60s deadline with no breakpoint armed -
    a failure that named nothing and pointed nowhere.
    """
    import zrcp

    class _Rejecting(zrcp.Zrcp):
        def __init__(self):
            pass

        def cmd(self, text, wait=0.0, deadline=zrcp.DEFAULT_DEADLINE):
            return "ERROR. You must enable breakpoints first"

    z = _Rejecting()
    for call in (lambda: z.set_breakpoint(1, "PC=1"), z.enable_breakpoints):
        try:
            call()
        except zrcp.ZrcpError:
            continue
        raise AssertionError(
            "a rejected breakpoint command returned quietly instead of "
            "raising ZrcpError")


# ---- Task 11 round 3: tilemap scroll-detection fix ------------------------
# Diagnosed live (tests/parser/work/e2e-clean, turn 0, condacts.dsf's QUIT
# confirmation): `pre` had exactly one trailing blank row (the screen was
# one line short of full). Processing "?N" then printed three new lines -
# the first fills that formerly-blank row, the other two genuinely scroll
# two rows off the top. A strict whole-window compare in the old
# scroll_delta rejected every k (the blank-vs-new-content mismatch at the
# tail broke all of them), so new_text fell back to "full redraw" and
# dumped nearly the whole screen instead of the three lines that actually
# changed. See tilemap.py's scroll_delta/new_text docstrings for the fix.

@case
def t11_scroll_delta_wildcards_pres_trailing_blank_run():
    import tilemap
    # pre: 31 content rows (row0..row30) then ONE blank row (index 31) -
    # the screen is one line short of full.
    pre = [("row%d" % i).ljust(80) for i in range(31)] + [" " * 80]
    # post: "new1" fills the formerly-blank row 31 (no scroll needed for
    # it); "new2" and "new3" each push one more row off the top - a
    # genuine 2-row scroll. See the module-level comment above for the
    # full derivation.
    post = pre[2:31] + ["new1".ljust(80), "new2".ljust(80), "new3".ljust(80)]
    assert len(post) == 32, len(post)
    assert tilemap.scroll_delta(pre, post) == 2, tilemap.scroll_delta(pre, post)


@case
def t11_new_text_includes_row_that_filled_a_trailing_blank():
    import tilemap
    pre = [("row%d" % i).ljust(80) for i in range(31)] + [" " * 80]
    post = pre[2:31] + ["new1".ljust(80), "new2".ljust(80), "new3".ljust(80)]
    # Before the fix this returned only ["new2", "new3"] - the last k=2
    # rows - silently dropping "new1", which landed in the absorbed
    # blank slot rather than being pushed on by the scroll itself.
    assert tilemap.new_text(pre, post) == ["new1", "new2", "new3"], \
        tilemap.new_text(pre, post)


@case
def t11_transition_reports_clean_shift_for_blank_absorbing_case():
    import tilemap
    pre = [("row%d" % i).ljust(80) for i in range(31)] + [" " * 80]
    post = pre[2:31] + ["new1".ljust(80), "new2".ljust(80), "new3".ljust(80)]
    result = tilemap.transition(pre, post)
    assert result == {"shift": 2, "ambiguous": False}, result


@case
def t11_scroll_delta_blank_wildcard_does_not_mask_a_genuine_full_redraw():
    """Guard against over-permissive wildcarding: a `pre` with a trailing
    blank run must NOT make an unrelated, genuine full redraw look like a
    scroll just because some positions happen to be wildcardable. Content
    that shares nothing with `pre` beyond the blank tail must still come
    back as no-shift / full redraw.
    """
    import tilemap
    pre = [("row%d" % i).ljust(80) for i in range(31)] + [" " * 80]
    post = [("totally-unrelated-%d" % i).ljust(80) for i in range(32)]
    assert tilemap.scroll_delta(pre, post) is None, tilemap.scroll_delta(pre, post)
    result = tilemap.transition(pre, post)
    assert result["shift"] is None, result
    assert tilemap.new_text(pre, post) == [
        ("totally-unrelated-%d" % i) for i in range(32)
    ], tilemap.new_text(pre, post)


@case
def t11_scroll_delta_rejects_blank_vs_blank_coincidence():
    """The "offset by one turn" text bug (tests/parser/work/rabenstein-
    probe, turns 1-4, confirmed live against real captured tilemap grids):
    `pre` has an ordinary trailing blank run (rows past its own last
    printed line, same shape the wildcard fix above is FOR), but `post`
    independently has its OWN leading blank run - unrelated screen real
    estate this game's layout never uses (rows 0-11 here, mirroring the
    real capture). A large k lands the ENTIRE compared window on
    blank-vs-blank pairs from these two unrelated regions; bare equality
    ("" == "") is true at every one of them, which the old code accepted
    as `genuine_match` even though nothing real was compared - so it
    confidently reported a k-row scroll that never happened, and
    new_text() dumped almost the whole (unchanged) screen as "new" text
    on top of the one row that actually changed. Confirmed live this
    compounds turn over turn: each turn's bogus "new" text becomes part
    of the next turn's `pre`, so the false content keeps growing.

    Only row 12 differs between pre/post here (a status-line update, the
    same shape as a turn counter) - the correct answer is "no shift, one
    row changed in place", not a whole-screen redraw.
    """
    import tilemap
    # INVENTED text, deliberately: this case reproduces the SHAPE of a
    # real capture (a status row, a wrapped description, a blank, an
    # object list, a blank, the prompt row, with blank runs above and
    # below), and the shape is the whole of what it tests. Game text
    # belongs to the game, not to this repository - the same rule the
    # Wave B review applied to the ZX cases.
    pre = [""] * 12 + [
        "Sunken Wharf".ljust(80),
        "Rotten planking runs out over water you cannot see".ljust(80),
        "the bottom of, and the pilings groan whenever".ljust(80),
        "anything at all shifts its weight out there".ljust(80),
        "",
        "You notice:".ljust(80),
        "a coil of rope, a bailing tin and the ferryman.".ljust(80),
        "",
        ">".ljust(80),
    ] + [""] * 11
    assert len(pre) == 32, len(pre)
    post = list(pre)
    post[12] = "Sunken Wharf - Turns: 1".ljust(80)    # only this row changed
    assert tilemap.scroll_delta(pre, post) is None, tilemap.scroll_delta(pre, post)
    assert tilemap.new_text(pre, post) == ["Sunken Wharf - Turns: 1"], \
        tilemap.new_text(pre, post)
    result = tilemap.transition(pre, post)
    assert result["shift"] is None, result
    assert result["ambiguous"] is False, result


@case
def t11_transition_ambiguous_case_unaffected_by_blank_run_fix():
    """The existing mixed-scroll-and-in-place ambiguity case (t2) must
    keep working when `pre` ALSO has a trailing blank run - the fix must
    not accidentally launder a genuine in-place jumble into a false
    "clean scroll" just because part of the screen was blank.
    """
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(28)] + [" " * 80] * 4
    # A fixed marker row, unchanged at the same index in both pre and
    # post - unrelated to any scroll, present alongside the genuine
    # jumble below purely so this case is not ALSO the zero-same-index-
    # matches shape covered by the next test.
    pre[5] = "FIXED-MARKER".ljust(80)
    post = list(pre)
    post[5] = "FIXED-MARKER".ljust(80)
    # Row 10's content "moves" to row 20 - a genuine in-place jumble, not
    # explainable by any single whole-screen shift.
    post[20] = pre[10]
    # Fill pre's trailing blank run with unrelated new content, same
    # shape as the real bug case, to confirm the wildcard fix does not
    # paper over this genuine ambiguity.
    post[28] = "new-a".ljust(80)
    post[29] = "new-b".ljust(80)
    post[30] = "new-c".ljust(80)
    post[31] = "new-d".ljust(80)
    result = tilemap.transition(pre, post)
    assert result["shift"] is None, result
    assert result["ambiguous"] is True, result


@case
def t11_transition_detects_moved_rows_with_zero_same_index_matches():
    """The second, more consequential misclassification found live
    (tests/parser/work/e2e-clean, turn 11): a near-clean scroll can have
    EVERY row move to a different index, so literally none of them
    happens to also survive at its own index. The old code's Rule 2
    ("if no row survived at its own index, call it an unambiguous full
    redraw") ran BEFORE Rule 3 ever got a chance to look for moved rows,
    so this genuine, heavily-evidenced scroll (confirmed live: 26 of 28
    compared rows individually match an identical shift) was wrongly
    reported as an ordinary full redraw with ambiguous=False - the ONE
    finding in the whole clean run that escaped the text_ambiguous
    caveat entirely, rather than being correctly discounted like every
    other turn's scroll-plus-edit transition.
    """
    import tilemap
    pre = [("line%d" % i).ljust(80) for i in range(32)]
    # A clean shift by 3, EXCEPT for one boundary row that was edited in
    # place before the scroll happened (mirroring a growing input-line
    # prompt) - this defeats scroll_delta, and no row of post happens to
    # equal pre AT THE SAME INDEX (since every row from index 0 either
    # moved by exactly 3 or is brand new).
    post = pre[3:] + ["new0".ljust(80), "new1".ljust(80), "new2".ljust(80)]
    post[28] = "line31-edited".ljust(80)
    assert not any(pre[i] == post[i] for i in range(32)), \
        "test setup must have zero same-index matches to reproduce the bug"
    result = tilemap.transition(pre, post)
    assert result["shift"] is None, result
    assert result["ambiguous"] is True, result


# ---- Task 12: corpus -------------------------------------------------------

@case
def t12_decompile_produces_dsf():
    import prepare
    work = ROOT / "tests" / "parser" / "work" / "selftest-corpus"
    work.mkdir(parents=True, exist_ok=True)
    built = prepare.prepare_from_dsf(
        ROOT / "tests" / "test.dsf",
        ROOT / "tests" / "parser" / "work" / "selftest-testdsf")
    dsf = prepare.decompile(built["ddb"], work)
    assert dsf.exists() and dsf.stat().st_size > 0, dsf


@case
def t12_mouse_defect_fails_loudly():
    """condacts.dsf uses MOUSE, which unDRC mis-decodes. The round trip
    must fail with the compiler's message, not silently produce a
    different game.
    """
    import prepare
    work = ROOT / "tests" / "parser" / "work" / "selftest-mouse"
    work.mkdir(parents=True, exist_ok=True)
    built = prepare.prepare_from_dsf(
        ROOT / "tests" / "condacts.dsf",
        ROOT / "tests" / "parser" / "work" / "selftest-condacts")
    try:
        prepare.prepare_from_binary(built["ddb"], work)
    except RuntimeError as exc:
        assert "MOUSE" in str(exc), str(exc)[:400]
        return
    raise AssertionError("expected the MOUSE round trip to fail")


# ---- Wave B: the ZX leg (zscreen decoder + zleg contracts) ----------------
#
# All pure functions: no emulator, no build. The end-to-end proof that the
# leg still measures what the SP16 rig measured lives in
# tests/parser/scripts/zxadj/run.py, which needs both.

# A REAL DAAD ZX display file, captured off the SP16 adjudication fixture
# booted on tools/DAAD-READY/ASSETS/ZX/ZXSPECTRUM/DS48IE3.BIN under
# ZEsarUX (zlib+base64 of the 6144 bytes at 0x4000 - 428 characters, so
# it lives in the test instead of as a binary fixture nobody can read).
# Pinning a real screen is the point: a synthetic one built by this file
# could only ever prove the decoder agrees with whatever this file
# thinks the format is.
ZX_BOOT_SCREEN_B64 = (
    "eNrtlDFLw0AUxy9XJKcEdHDMcB6SpiIozqKpIM76KRxDszg+i0N6dejgEJcMGSTN2Mmx"
    "dDD5HE6ldOmok0mEQopLsnjD+/HncfC44cfjPW9mtubgTaNVan6lgtTF14u4OulxU8sg"
    "f7iVviyrNiWKIi1BbJA88v2I+1F9/234jeQWtSFgEGz47+X16lBV/77g5JqU/oL7kyb+"
    "2dr/+A//j3eaik+hqr83Oyd98l34X3A/qf1/sIDxAvIq2wk9CuPdMK70h51Ry35xuqr6"
    "71Chba3n/1Z//gYEBsQGJPyMjiFjkFX6iT2iJ8x5VHb/qaAMpN10/2+XMFjCa56bCb0P"
    "MxZu+HdG1N53qKr+Pb24/8PUXKXioMH95+X9f8gDpjYHl0H1/t9Zz7QdnT5dEgRBEARB"
    "EARBEARBEOQ/+AEAj2vD")
ZX_BOOT_SCREEN_TEXT = [
    "SP16 ZX ADJUDICATION",
    "V=0 N=0 Q=0 QV=0 QN=0 A=0",
    "What next?>_",
]


def _zx_boot_screen():
    import base64
    import zlib
    return zlib.decompress(base64.b64decode(ZX_BOOT_SCREEN_B64))


def _zx_addr(x, y):
    """Display-file offset of byte column x on scanline y.

    The CANONICAL ZX formula, deliberately spelled the standard way
    rather than reusing zscreen.screen_bits' own bit decomposition -
    otherwise a mistake in the de-interleave would cancel itself out and
    the test would pass on a broken decoder.
    """
    return ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2) | x


def _render(text, table_path=None, dy=0, col0=0):
    """Draw `text` into a 6144-byte display file with a DAAD 6px font."""
    from pathlib import Path as _P
    import zscreen
    font = _P(table_path or zscreen.DEFAULT_CHARSET).read_bytes()
    px = bytearray(6144)
    for i, ch in enumerate(text):
        glyph = font[ord(ch) * 8:ord(ch) * 8 + 8]
        x0 = (col0 + i) * 6
        for row, byte in enumerate(glyph):
            six = (byte >> 2) & 0x3F
            y = dy + row
            for b in range(6):
                if (six >> (5 - b)) & 1:
                    x = x0 + b
                    px[_zx_addr(x >> 3, y)] |= 0x80 >> (x & 7)
    return bytes(px)


@case
def zb1_decoder_reads_a_real_daad_zx_screen():
    import zscreen
    lines = zscreen.decode(_zx_boot_screen(), zscreen.load_font())
    assert lines == ZX_BOOT_SCREEN_TEXT, lines


@case
def zb1_decoder_needs_the_six_pixel_font():
    """The 8-pixel ROM-style charset decodes the same screen to nothing.

    This is the measurement behind the whole module: DAAD's AD8x6.CHR
    glyphs do not line up with 8-pixel cells, which is why ZEsarUX's
    own get-ocr returns the empty string on these screens.
    """
    import zscreen
    from pathlib import Path as _P
    wide = _P(zscreen.DEFAULT_CHARSET).parent / "AD8x8.CHR"
    if not wide.exists():                      # tools/ layout changed
        return
    lines = zscreen.decode(_zx_boot_screen(), zscreen.load_font(wide))
    good = sum(1 for l in ZX_BOOT_SCREEN_TEXT if l in lines)
    assert good == 0, "8px font unexpectedly read %d line(s): %r" % (good, lines)


@case
def zb2_screen_bits_deinterleaves_the_display_file():
    import zscreen
    px = bytearray(6144)
    # Third 2, character row 3, pixel line 5 -> scanline 2*64+3*8+5 = 157.
    px[_zx_addr(4, 157)] = 0x81
    rows = zscreen.screen_bits(bytes(px))
    assert sum(1 for r in rows if r) == 1, "more than one scanline lit"
    row = rows[157]
    assert (row >> (256 - 33)) & 1 == 1, "leftmost pixel of byte 4 not set"
    assert (row >> (256 - 40)) & 1 == 1, "rightmost pixel of byte 4 not set"
    assert (row >> (256 - 34)) & 1 == 0


@case
def zb3_decode_finds_the_vertical_phase():
    """The text window scrolls by PIXEL rows - all eight phases decode."""
    import zscreen
    table = zscreen.load_font()
    for dy in range(8):
        lines = zscreen.decode(_render("HELLO WORLD", dy=dy), table)
        assert lines == ["HELLO WORLD"], (dy, lines)


@case
def zb3_decode_without_the_phase_search_would_fail():
    """Negative control for the case above: the WRONG phase is garbage."""
    import zscreen
    table = zscreen.load_font()
    bits = zscreen.screen_bits(_render("HELLO WORLD", dy=3))
    at_zero = "".join(zscreen.decode_at(bits, table, 0)).strip()
    assert "HELLO" not in at_zero, at_zero
    assert "?" in at_zero, at_zero


@case
def zb4_new_text_reports_scrolls_and_redraws():
    import zscreen
    prev = ["one", "two", "three"]
    # nothing scrolled off, two lines appended
    assert zscreen.new_text(prev, prev + ["four", "five"]) == (
        ["four", "five"], False)
    # scrolled by two
    assert zscreen.new_text(prev, ["three", "four"]) == (["four"], False)
    # unchanged
    assert zscreen.new_text(prev, prev) == ([], False)
    # window cleared: no shift explains it, whole screen is new AND the
    # caller is told the capture is a redraw
    assert zscreen.new_text(prev, ["alpha"]) == (["alpha"], True)
    # first capture of a run
    assert zscreen.new_text([], ["alpha"]) == (["alpha"], False)


@case
def zb5_zleg_script_contract_matches_the_other_legs():
    """The three shared script entry forms, and their `pre` anchors."""
    import zleg
    assert zleg.command_plan("LOOK") == ("after", ["LOOK"], True)
    assert zleg.command_plan("GET ALL") == ("after", ["GET ALL"], True)
    # "!X" - raw keys, one at a time, no Enter
    assert zleg.command_plan("!Y") == ("before", ["Y"], False)
    assert zleg.command_plan("!YN") == ("before", ["Y", "N"], False)
    # "?X" - a confirmation answer: one string plus Enter
    assert zleg.command_plan("?Y") == ("before", ["Y"], True)


@case
def zb5_tracked_scripts_are_the_shared_format():
    import nleg
    scripts = sorted((ROOT / "tests" / "parser" / "scripts").rglob("*.json"))
    assert scripts, "no tracked scripts found"
    for path in scripts:
        # load_script is the normative reader and validator - it raises on
        # anything the three legs do not all agree on, so running it over
        # every tracked script is the format check.
        script = nleg.load_script(path)
        assert script, path
        assert all(isinstance(e["cmd"], str) for e in script), path


@case
def zb6_pending_prompt_is_trimmed_from_both_sides():
    """The random SM2..SM5 prompt and the SM33 input row leave the text.

    The ZX leg cannot pin flag 42 (no symbols for the original), so it
    drops the pending prompt from its own captures; trim_prompt_tail
    does the same to the Next side for the ZX comparison only.

    The strings here are INVENTED, not lifted from any corpus game -
    these cases test the mechanics, and game text does not belong in the
    repository.
    """
    import zleg
    sysmess = {2: "Orders, captain?", 3: "Your move. ",
               4: "Well, what now then?", 5: "Speak.",
               32: "More...", 33: "\r>"}
    assert zleg.input_row_text(sysmess) == ">"
    assert zleg.input_row_text({33: "#n>"}) == ">"
    text = "A shut gate bars the way..\nOrders, captain?\n>"
    assert zleg.trim_prompt_tail(text, sysmess) == "A shut gate bars the way.."
    # a different draw of the same random prompt, same result
    text4 = "A shut gate bars the way..\nSpeak.\n>"
    assert zleg.trim_prompt_tail(text4, sysmess) == "A shut gate bars the way.."
    # the same words EARLIER in the turn are the game's own prose
    keep = "Orders, captain?\nThe sentry waits.\nSpeak.\n>"
    assert zleg.trim_prompt_tail(keep, sysmess) == \
        "Orders, captain?\nThe sentry waits."
    # with no system messages nothing is trimmed
    assert zleg.trim_prompt_tail(text, {}) == text


@case
def zb6_emit_text_drops_the_prompt_but_keeps_history():
    """`pre` keeps the prompt rows on purpose - see zleg._emit_text."""
    import zleg
    prompts = {"Orders, captain?"}
    pre = ["You are here.", "Orders, captain?", ">E_"]
    post = ["You are here.", "Orders, captain?", ">E",
            "You go east.", "Orders, captain?", ">_"]
    text, redraw = zleg._emit_text(pre, [post], True, prompts)
    assert text == ["You go east."], text
    assert redraw is False


@case
def zb6_play_decodes_with_the_font_the_tap_was_built_with():
    """A game's own .CHR must survive into the DECODER, not just the build.

    build_tap resolves the charset against the DSF's directory and hands
    it to daadmaker; the TAP then lands in a work directory containing no
    .CHR at all. Re-resolving there silently falls back to the stock
    AD8x6.CHR, and a game shipping a redefined 6-pixel font is then built
    with one font and read with another - a silent mis-decode that
    surfaces as text divergences. Both call sites go through
    play_charset for exactly this reason.
    """
    import tempfile
    import zleg
    import zscreen
    with tempfile.TemporaryDirectory() as tmp:
        gamedir = Path(tmp) / "game"
        workdir = Path(tmp) / "work"
        gamedir.mkdir()
        workdir.mkdir()
        own = gamedir / "AD8x6.CHR"
        own.write_bytes(Path(zscreen.DEFAULT_CHARSET).read_bytes())
        tap = workdir / "GAME.TAP"          # work dir holds no .CHR
        tap.write_bytes(b"")

        # what build_tap would have picked, from the game's own directory
        built = zscreen.resolve_charset(gamedir / "game.dsf")
        assert built == own, built
        # ...and it is what play must decode with, not the stock font
        assert zleg.play_charset(None, built, tap) == own
        assert zleg.play_charset(None, None, tap) == zscreen.DEFAULT_CHARSET
        # an explicit --charset still beats both
        other = gamedir / "OTHER.CHR"
        other.write_bytes(b"\0" * 1024)
        assert zleg.play_charset(other, built, tap) == other


@case
def zb7_pager_prompt_is_removed_from_a_captured_page():
    import zleg
    page = ["line one", "line two", "More..."]
    assert zleg.drop_pager_prompt(page, "More...") == ["line one", "line two"]
    assert zleg.drop_pager_prompt(page, None) == page


@case
def zb8_zx_turns_have_no_state_channel():
    """A ZX turn must NOT be comparable as if it had flags.

    compare.compare_runs is the two-leg differential and a state-less
    capture reaching it means a broken capture, so it has to fail loudly.
    compare_runs_text is the path built for this leg.
    """
    import compare
    zx = [{"turn": 0, "command": "LOOK", "text": "You are here."}]
    nd = [{"turn": 0, "command": "LOOK", "text": "You are here.",
           "flags": [0] * 256, "objloc": [0] * 8}]
    try:
        compare.compare_runs(zx, nd)
    except KeyError:
        pass
    else:
        raise AssertionError("a state-less turn compared as if it had state")
    assert compare.compare_runs_text(zx, nd)["divergences"] == []


@case
def zb8_text_only_comparison_ranks_and_truncates():
    import compare
    zx = [{"turn": 0, "command": "LOOK", "text": "You are here."},
          {"turn": 1, "command": "N", "text": "You go north."},
          {"turn": 2, "command": "S", "text": "You go south."}]
    nd = [{"turn": 0, "command": "LOOK", "text": "You  are\nhere."},
          {"turn": 1, "command": "N", "text": "You go NORTH."},
          {"turn": 2, "command": "S", "text": "You went south."}]
    res = compare.compare_runs_text(zx, nd)
    assert res["turns_compared"] == 3
    ranks = [(d["turn"], d["text_rank"], d["state_rank"])
             for d in res["divergences"]]
    assert ranks == [(1, "primary", None), (2, "downstream", None)], ranks
    # a short run is reported as truncated, not silently ignored
    res = compare.compare_runs_text(zx, nd[:1])
    assert res["divergences"][-1]["class"] == "truncated"
    assert res["divergences"][-1]["text_nd"] == "1 turns"


def main():
    failed = 0
    for fn in CASES:
        try:
            fn()
            print("PASS %s" % fn.__name__)
        except Exception:
            failed += 1
            print("FAIL %s" % fn.__name__)
            traceback.print_exc()
    print("---")
    print("%d/%d passed" % (len(CASES) - failed, len(CASES)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
