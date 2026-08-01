"""Turn raw divergences into something an agent can act on.

findings.json is the primary output. Each finding names the condacts that
could have produced it and the NextDAAD handler symbol for each, so the
fix loop is: read findings.json, edit the named handler, rebuild, re-run
the identical script, confirm the finding is gone.
"""
import json
import re
from pathlib import Path

# A condact mnemonic at the head of a DSF process line.
_CONDACT_LINE = re.compile(r"^\s*(?:>\s*\S+\s+\S+\s+)?([A-Z][A-Z0-9_]{1,11})\b")

# Entry header line: > verb noun (and possibly more)
_ENTRY_HEADER = re.compile(r"^\s*>\s+(\S+)")


def _parse_dsf_entries(dsf_text):
    """Parse DSF source into entries. Consecutive header lines (starting with '>')
    share one condact body (a documented DAAD idiom for chained verbs/nouns).
    Entry body continues until the next header or EOF.
    Returns list of {"verb": verb_str, "condacts": [mnemonic_list]}
    """
    entries = []
    lines = dsf_text.splitlines()
    i = 0

    while i < len(lines):
        line = lines[i]
        header_match = _ENTRY_HEADER.match(line)

        if header_match:
            # Start of a header run - collect all consecutive headers
            verbs = []
            condacts = []

            # Collect all consecutive header lines (skip blank lines between them)
            while i < len(lines):
                line = lines[i]
                m = _ENTRY_HEADER.match(line)
                if m:
                    # Found a header
                    verbs.append(m.group(1))

                    # Extract condacts from this header line
                    cm = _CONDACT_LINE.match(line)
                    if cm:
                        condacts.append(cm.group(1))

                    i += 1
                elif line.strip():
                    # Non-blank, non-header line - end of header run
                    break
                else:
                    # Blank line - skip it and continue looking for more headers
                    i += 1

            # Now collect the body (until next header or EOF)
            while i < len(lines):
                line = lines[i]
                if _ENTRY_HEADER.match(line):
                    # Next header - don't consume it, break
                    break

                # Parse condacts from body line
                cm = _CONDACT_LINE.match(line)
                if cm:
                    condacts.append(cm.group(1))

                i += 1

            # Create entry for each verb with the full condact list
            for verb in verbs:
                entries.append({"verb": verb, "condacts": list(condacts)})
        else:
            # Skip non-header lines at top level
            i += 1

    return entries


def _condacts_in_dsf(dsf_text):
    """Mnemonics that appear anywhere in the process source. Coarse on
    purpose - it narrows the search for a human or agent, it does not
    claim to identify the single guilty line.
    """
    found = []
    for line in dsf_text.splitlines():
        m = _CONDACT_LINE.match(line)
        if m:
            found.append(m.group(1))
    return found


def _narrow_suspects(dsf_text, command):
    """Narrow suspect condacts by command verb. Parse DSF entries and select
    those matching the command's first word (verb), plus any with wildcard
    verb '_'. Returns (condacts_set, narrowed_bool) where narrowed=True only if
    a verb-specific entry matched (not just wildcards).
    """
    entries = _parse_dsf_entries(dsf_text or "")
    if not entries:
        # No entries parsed - fall back to all
        return set(_condacts_in_dsf(dsf_text)), False

    # Extract verb from command (first word, case-insensitive)
    verb = command.split()[0].upper() if command and command.strip() else ""

    # Collect condacts separately: verb-specific and wildcards
    verb_matched = set()
    wildcard_matched = set()
    for entry in entries:
        entry_verb = entry["verb"].upper()
        if entry_verb == "_":
            wildcard_matched.update(entry["condacts"])
        elif verb and entry_verb == verb:
            verb_matched.update(entry["condacts"])

    # narrowed=True only if we matched a verb-specific entry
    narrowed = bool(verb_matched)

    # Result is union of verb matches and wildcard matches
    matched = verb_matched | wildcard_matched

    # If we matched nothing at all, fall back to all condacts
    if not matched:
        return set(_condacts_in_dsf(dsf_text)), False

    return matched, narrowed


def build_findings(divergences, condacts, dsf_text, commands=None,
                   nd_turns=None):
    """condacts: {number: handler_symbol} from symbols.load_condacts.
    dsf_text: the decompiled or authored source, used to narrow suspects.
    commands: the full command script, used to build the repro prefix.
    nd_turns: the NextDAAD leg's parsed jsonl. The Next leg records three
        per-turn caveats that change how much a finding can be trusted -
        text_ambiguous (the screen both scrolled and changed in place, so
        the captured text is unreliable), anykey_heuristic (a key was sent
        on a screen-static guess because ANYKEY leaves no memory signal),
        and timing_sensitive (the game re-armed the input timeout). These
        must reach the report: a finding on a turn carrying any of them is
        weaker evidence than one on a clean turn, and an agent triaging it
        needs to know that without going back to the raw jsonl.
    """
    by_name = {}
    for num, handler in (condacts or {}).items():
        name = handler[2:].upper() if handler.startswith("h_") else handler.upper()
        by_name[name] = {"number": num, "name": name, "handler": handler}

    by_turn = {t["turn"]: t for t in (nd_turns or [])}

    findings = []
    for i, d in enumerate(divergences):
        repro = None
        if commands is not None:
            repro = list(commands[:d["turn"] + 1])
        nd = by_turn.get(d["turn"], {})

        # Extract caveats with their meanings
        caveat_names = [name for name in
                        ("text_ambiguous", "anykey_heuristic", "timing_sensitive")
                        if nd.get(name)]
        caveats = [{"name": name, "meaning": _CAVEAT_MEANING[name]}
                   for name in caveat_names]

        # Narrow suspects by command verb
        narrowed_set, suspects_narrowed = _narrow_suspects(dsf_text or "",
                                                           d["command"])
        suspects = [by_name[n] for n in sorted(narrowed_set) if n in by_name]

        findings.append({
            "id": "F%03d" % (i + 1),
            "class": d["class"],
            "state_rank": d.get("state_rank"),
            "text_rank": d.get("text_rank"),
            "turn": d["turn"],
            "command": d["command"],
            "expected": d.get("text_ref", ""),
            "actual": d.get("text_nd", ""),
            "flag_diffs": d.get("flag_diffs", []),
            "objloc_diffs": d.get("objloc_diffs", []),
            "suspect_condacts": suspects,
            "suspects_narrowed": suspects_narrowed,
            "repro": repro,
            "caveats": caveats,
        })
    return findings


_CAVEAT_MEANING = {
    "text_ambiguous": "The screen both scrolled and changed in place this "
                      "turn, so the captured text may include stale rows. "
                      "Treat a text difference here as unproven.",
    "anykey_heuristic": "A key was sent on a screen-static guess - ANYKEY "
                        "leaves no memory signal. The turn may have been "
                        "advanced at the wrong moment.",
    "timing_sensitive": "The game re-armed the input timeout on this turn, "
                        "so behaviour here can depend on wall-clock timing.",
}


_CLASS_MEANING = {
    "state-only": "Condact computed the wrong thing - game state diverged. "
                  "The text channel agreed on this turn (see the "
                  "Transcript section below to confirm, or check for a "
                  "text_ambiguous caveat if it looks like it shouldn't "
                  "have).",
    "text-only": "Print, message, window or wrap fault - game state agrees. "
                 "If this finding carries a text_ambiguous caveat, treat "
                 "the difference as weaker evidence - the Next leg's "
                 "screen transition this turn could not be trusted to "
                 "capture cleanly.",
    "both": "Condact fault with a visible consequence.",
    "truncated": "One leg stopped early - the runs are not the same length.",
}


def _rank_label(f):
    """Render a finding's per-channel rank(s) for the report header.

    truncated has no state/text meaning of its own (see compare.py) so it
    gets a single bare word; every other class shows whichever of
    state_rank/text_rank actually applies to it (a state-only finding has
    no text_rank and vice versa; a "both" finding shows both, and they can
    legitimately disagree - primary on one channel, downstream on the
    other - that is the whole point of ranking channels independently).
    """
    if f["class"] == "truncated":
        return f.get("state_rank") or f.get("text_rank") or "unknown"
    parts = []
    if f.get("state_rank"):
        parts.append("state: %s" % f["state_rank"])
    if f.get("text_rank"):
        parts.append("text: %s" % f["text_rank"])
    return ", ".join(parts) if parts else "unknown"


def _transcript_lines(findings):
    """A side-by-side transcript of every divergent turn, verbatim and
    unnormalised (no wrap/whitespace collapsing, no ambiguity filtering).

    The structured findings above this section can bury a real text
    difference under caveats, cascade ranking and pages of candidate
    handlers - the ORIGINAL discovery of a NextDAAD bug like this (see
    docs/parser-bugs.md) worked because an agent just read both legs'
    transcripts side by side and noticed a missing line. This section
    exists so that reading is possible again without reconstructing it
    from findings.json by hand.
    """
    if not findings:
        return []
    lines = ["## Transcript", "",
             "Every divergent turn: the command, then each leg's raw "
             "captured text exactly as captured (unnormalised - wrapping "
             "and whitespace differences are NOT collapsed here the way "
             "they are for comparison purposes).", ""]
    for f in findings:
        lines += [
            "### Turn %d - `%s`" % (f["turn"], f["command"]),
            "",
            "Reference:",
            "",
            "```",
            f["expected"],
            "```",
            "",
            "NextDAAD:",
            "",
            "```",
            f["actual"],
            "```",
            "",
        ]
    return lines


def write_report(findings, md_path, json_path):
    Path(json_path).write_text(
        json.dumps({"findings": findings}, indent=2), encoding="utf-8")

    lines = ["# NextDAAD parser test report", ""]
    if not findings:
        lines += ["No divergences. The two interpreters agreed on every turn.", ""]
    else:
        primary = [f for f in findings
                  if f.get("state_rank") == "primary"
                  or f.get("text_rank") == "primary"]
        lines += ["%d finding(s), %d primary." % (len(findings), len(primary)), ""]
        for f in findings:
            lines += [
                "## %s - %s (%s)" % (f["id"], f["class"], _rank_label(f)),
                "",
                "Turn %d, command `%s`." % (f["turn"], f["command"]),
                "",
                _CLASS_MEANING.get(f["class"], ""),
                "",
            ]
            if f["flag_diffs"]:
                lines.append("Flags:")
                lines += ["- flag %d: reference %d, NextDAAD %d"
                          % (x["flag"], x["ref"], x["nd"]) for x in f["flag_diffs"]]
                lines.append("")
            if f["objloc_diffs"]:
                lines.append("Object locations:")
                lines += ["- object %d: reference %d, NextDAAD %d"
                          % (x["obj"], x["ref"], x["nd"]) for x in f["objloc_diffs"]]
                lines.append("")
            if f["expected"] != f["actual"]:
                lines += ["Expected text:", "", "```", f["expected"], "```", "",
                          "NextDAAD text:", "", "```", f["actual"], "```", ""]
            if f.get("caveats"):
                lines.append("Caveats - this finding is weaker evidence:")
                lines += ["- %s: %s" % (c["name"], c["meaning"])
                          for c in f["caveats"]]
                lines.append("")
            if f["suspect_condacts"]:
                narrowed = f.get("suspects_narrowed", False)
                if narrowed:
                    lines.append("Candidate handlers (narrowed by command verb):")
                else:
                    lines.append("Candidate handlers (not narrowed - includes wildcard entries):")
                lines += ["- %s (condact %d) -> `%s`"
                          % (c["name"], c["number"], c["handler"])
                          for c in f["suspect_condacts"]]
                lines.append("")
            if f.get("repro") is not None:
                lines.append("Reproduction:")
                lines.append("> " + " > ".join(f["repro"]))
                lines.append("")
        lines += _transcript_lines(findings)
    Path(md_path).write_text("\n".join(lines), encoding="utf-8")
