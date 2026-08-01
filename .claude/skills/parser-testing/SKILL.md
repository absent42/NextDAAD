---
name: parser-testing
description: Use when testing the NextDAAD interpreter against a reference DAAD interpreter - differential play-testing of a game through both jDAAD and NextDAAD to find condact, parser and display faults. Use for "test the parser", "check NextDAAD against jDAAD", "why does this game behave differently on Next", or when a game misbehaves and you need to know whether the interpreter or the game is at fault.
---

# NextDAAD parser testing

Differential testing: play one game through jDAAD and NextDAAD, compare
every turn, report where NextDAAD diverges.

Design: `docs/superpowers/specs/2026-07-26-parser-testing-design.md`

## THE TEXT CHANNEL IS NOW SURFACED, NOT ADJUDICATED - read the transcript

Until 2026-07-26, `compare.py` discarded a text difference outright
whenever the Next leg's screen transition that turn was ambiguous
(`tilemap` could not tell a scroll from an in-place edit), and every
finding after the FIRST divergence of any kind was labelled
`downstream` - which the triage guidance below then told a reader to
ignore. Together this meant a real, visible NextDAAD text bug (missing
SM36/SM39 output on GET/DROP, found live against Dracula) got captured
correctly on both legs but reported as nothing at all: all 21 turns
came back `state-only`/`downstream`, because flag 29 diverged on every
turn of every game at the time and the ambiguity override silently ate
the text side. (Flag 29 itself was fixed in SP16 Task 1 - the shape of
the failure is what matters here, not that particular flag.)

Both mechanisms are gone now:

- A text difference is ALWAYS reported when the normalised token
  streams differ. Ambiguity (`tilemap` could not tell a scroll from an
  in-place edit that turn) is attached as a `text_ambiguous` CAVEAT on
  the finding instead of being grounds to suppress it - a reader can
  tell "text differs, capture trustworthy" from "text differs, but this
  turn's capture may include stale rows" by checking for that caveat,
  rather than the harness deciding for them by hiding the difference.
- `state_rank`/`text_rank` are tracked per CHANNEL, not globally. A flag
  that diverges every turn - flag 29 used to, flag 50 still can on any
  game that nests PROCESS around a DOALL - no longer drags
  every later, unrelated text divergence down to `downstream` just
  because it happened after some earlier flag divergence - a text
  finding's rank depends on whether it is the first TEXT divergence.

`report.md` also gets a `## Transcript` section: every divergent turn's
command plus both legs' RAW captured text, verbatim and unnormalised,
side by side. This is what actually lets an agent do what the original
Dracula-bug discovery did - read both transcripts and notice a missing
line - without reconstructing it from `findings.json` by hand.

The two structural capture mismatches that used to sit underneath all
of this are REPAIRED, as of SP16 Task 0 (2026-07-31). They were: jDAAD's
captured text ending every turn with a trailing `_` cursor glyph that
NextDAAD's capture can never carry (NextDAAD's cursor is an attribute
inversion, not a glyph), and NextDAAD's capture including the typed
command echo that jDAAD suppressed. `jleg.js` now drops the trailing
cursor glyph for the duration of `readText` only, and `nleg.py` anchors
each turn's `pre` grid AFTER the echo lands and BEFORE Enter. On
`tests/condacts.dsf` that took the trailing cursor from 13/13 turns to
0/13, the echo to 0, and `text_ambiguous` from 12/13 to 0/13.

`tests/parser/parser_selftest.py`'s `t11_text_channel_known_limitation_pin`
is now a CAPTURE-SYMMETRY pin holding those numbers at zero rather than
recording a limitation. Read it if you want the current figures, but
the practical consequence is the point: **a class label is trustworthy
evidence again.** `both`/`text-only` on a turn means the two
interpreters really did print different things, not that the two
capture models disagree with each other on every turn alike.

One known artefact survives, and it is narrow: on a `"?"` turn (a
confirmation prompt) the Next leg's capture carries the single echoed
reply character and jDAAD's does not, so that one turn can come back
`both` for a one-character reason. The selftest pins it to `"?"` turns
only. Everywhere else, still READ THE TRANSCRIPT before promoting a
finding - not because the class might be an artefact, but because the
transcript is what tells you WHICH line differs.

## The tool

The harness is TRACKED. `tests/parser/` - the runner and leg modules
plus `tests/parser/scripts/` - was adopted onto `main` on 2026-08-01
after the SP16 Task 0 repairs; run it straight out of the checkout. Only
`tests/parser/work/` (every run's output) and `__pycache__/` are
gitignored. It is deliberately NOT wired into `build.ps1` and never runs
automatically - it needs ZEsarUX, node, PHP and DAAD-READY, all of which
live in the untracked `tools/`.

    python tests/parser/parsertest.py <game.dsf> <script.json> [--out DIR] [--port PORT] [--nex PATH] [--stop-on-first]

Before changing anything under `tests/parser/`, run its own selftest and
expect a clean sweep:

    python tests/parser/parser_selftest.py

It is plain python, no pytest, and it exercises the whole harness
including an end-to-end clean run and a negative control that fails if
the harness stops detecting a deliberately injected fault.

`--port` (default 10000) is the ZRCP port ZEsarUX listens on - see
Prerequisites below for why a stale emulator on it silently poisons a
run. `--nex` (default `build/nextdaad.nex`) overrides which built
interpreter image the Next leg boots.

Exits 0 when the interpreters agreed, 1 when they did not. Writes
`findings.json` (primary, agent-actionable) and `report.md` into the
output directory. Nothing it WRITES is ever committed - the harness
sources are tracked, its output is not.

`NLEG_DEBUG=1` makes the Next leg report every page it captured, every
key it sent and where each settle stopped. Those are the only places the
leg does anything the script did not ask for, so it is the first thing to
look at when a replay stops reproducing.

### How the Next leg captures a "More..." page

Not by polling. A ZEsarUX breakpoint on `WAIT_KEY_TIMEOUT` - the pager's
park point, reached only from `prn_more_check` and `h_anykey` - carries a
`save-binary` action, so THE EMULATOR writes the tilemap to
`<out>/nleg-page.bin` at the instruction where the page is finished and
about to block, and a second breakpoint at the same address counts the
fires into a user variable the harness polls. The page is therefore
recorded before anything can dismiss it, including the harness's own
still-held keystroke, which is what used to lose whole pages.

Two consequences worth knowing:

- A breakpoint CANNOT stop this emulator. Confirmed live against ZEsarUX
  13.0 with `--vo null`: a breakpoint whose action is the default
  menu/break answers "Can not open menu: this video driver does not
  support menu" on every hit and execution CONTINUES. Only `run` inside
  cpu-step mode stops on one. That is why the capture is done by an
  action rather than by breaking, capturing and resuming.
- `(moreLock, wrapLock) == (1, 1)` is READ TWICE before a turn is called
  ready. That pair is the input editor's signature, but `prn_more_check`
  passes through it too - it holds both locks while the SM32 prompt is
  printing - so a single read can end a turn on a page that has not
  finished drawing. The second read, a poll later, separates them: the
  pager has either dropped `wrapLock` or moved the page counter by then.
- **Any capture taken before commit `303abea` is not above suspicion if
  its turn was page-heavy.** Until that commit the harness read
  `(moreLock, wrapLock) == (1, 1)` once and called it READY, and
  `prn_more_check` wears that same signature while SM32 prints - so a
  poll landing there ended the turn on a half-drawn page. The race was
  latent through SP16 and Waves A and B, at a rate set by how many pages
  a turn fires (measured ~1 run in 5 on a four-page turn; effectively
  never on a no-page turn). The four protected baselines all reproduce
  post-fix, so none of them was affected in practice; anything else
  captured before that commit from a turn that pages should be re-run
  rather than cited.
- Pauses are dismissed with SYMBOL SHIFT, driven straight onto the
  emulated keyboard matrix (`set-ui-io-ports`), NOT with Enter. A bare
  SYMBOL SHIFT satisfies `wait_key` but maps to 0 in every one of
  `kb_char`'s tables, so the input editor cannot see it. Dismissing with
  Enter handed the same keypress to two readers - the pause took it,
  and the next input read, still inside the 150ms hold, took it AGAIN as
  a submitted empty line. Also measured, in case another key is ever
  wanted: BIT 0 of a matrix row does not take through
  `set-ui-io-ports` (ENTER and SPACE both did nothing); pick a non-bit-0
  key.

## The third leg - the ORIGINAL ZX interpreter (`--zx`)

`tests/parser/zleg.py` plays a script on the real DAAD ZX 48K
interpreter (`tools/DAAD-READY/ASSETS/ZX/ZXSPECTRUM/DS48IE3.BIN`) under
ZEsarUX, headless. It is the SP16 Task 5 adjudication rig, promoted.
It is NOT a third simultaneous comparand: the jDAAD/NextDAAD pair is the
instrument, and `--zx` is off by default.

**When to use it.** Two jobs, both ones the two-leg differential cannot
do:

1. **Adjudication.** NextDAAD, jDAAD and msx2daad disagree about what
   DAAD does. The original settles it. This is how the convertible-noun
   threshold (39/40), the QUIT confirmation input model and PARSE 1's
   noun conversion were settled - three reference interpreters, one
   measurement each.
2. **Lineage coverage.** Run a shipped game on NextDAAD and on the
   interpreter it reimplements and compare the TEXT. jDAAD agreeing
   proves two reimplementations agree; this proves NextDAAD matches the
   original.

**Invocation.** Either through the runner, alongside a normal run:

    python tests/parser/parsertest.py <game.dsf> <script.json> --out DIR --zx [--zx-tap TAP] [--zx-port 10010]

which writes `zx.jsonl`, `zx-report.md` and `zx-findings.json` beside the
usual output and leaves the two-leg findings and exit code untouched; or
standalone, for an adjudication replay with no NextDAAD build involved:

    python tests/parser/zleg.py <script.json> <out.jsonl> --dsf FIXTURE.DSF [--work DIR] [--port 10010]
    python tests/parser/zleg.py <script.json> <out.jsonl> --tap PREBUILT.TAP

Scripts are the SAME shared JSON format - the three entry forms
`"COMMAND"`, `"!X"`, `"?X"` mean the same thing on all three legs.

The regression that proves the leg still measures what the SP16 rig
measured (15 transcript lines, pinned):

    python tests/parser/scripts/zxadj/run.py

**Limits - read these before trusting a ZX result.**

- **NO STATE.** No flags, no object locations, ever. There is no map
  file, no source and no symbols for the original, and DAAD Ready ships
  SIX ZX variants in two languages at six different sizes, so no address
  found by inspection could be validated. The conservative subset is
  nothing. To observe original-interpreter state, do what SP16 did:
  write a fixture that PRINTS the flags you care about and read them off
  the screen (`.superpowers/sdd/sp16-adjudications/zxadj.dsf` is the
  worked example). Feeding a ZX transcript to `compare.compare_runs`
  raises - by design; `compare.compare_runs_text` is its comparison.
- **Falling off the end of process 0 ENDS THE GAME on the original.**
  `tests/condacts.dsf`'s loop shape (PRO 0 runs out and the interpreter
  re-pushes it) drops the 48K machine back to BASIC on every typed
  command. NextDAAD and jDAAD both re-push; the original does not. Write
  ZX fixtures in `tests/test.dsf`'s shape - PRO 1, every path ending in
  `REDO`.
- **The prompt is random** (SM2..SM5, unpinnable without flag 42), so the
  pending prompt message and input row are dropped from BOTH sides of a
  ZX comparison. That is the only normalisation applied.
- **The ZX leg builds the 48K subtarget**, the Next leg builds `zx next`.
  A game that branches on `COLS` or the target symbol genuinely runs
  different code on the two legs.
- Only the 48K tape variant is implemented. 128K/PLUS3/ESXDOS/UNO/NEXT
  need a different packager and machine and would answer no question
  differently.
- `ZLEG_DEBUG=1` makes the leg report every pause it dismisses. A
  dismissal is the one place it presses a key the script did not ask
  for, so it is the first thing to check if a run desynchronises.

**ZEsarUX's `get-ocr` reads NOTHING off a DAAD ZX screen** - measured,
twelve consecutive polls of a live game, all empty. Its OCR assumes the
ROM's 8-pixel charset and DAAD installs a 6-pixel one. `zscreen.py`
decodes the bitmap at 0x4000 itself: de-interleave, 6-pixel columns
matched against the game's own `.CHR`, and an 8-way vertical phase
search because the text window scrolls by pixel rows. Do not "simplify"
that back to `get-ocr`.

## Prerequisites - these fail late and confusingly if skipped

- `./build.ps1` must have already been run: BOTH `build/nextdaad.nex`
  (the emulator image the Next leg boots) AND `build/nextdaad.map`
  (symbol addresses - see `symbols.py`) must exist. `parsertest.py` also
  reads `src/engine.asm` directly, to build the condact-number-to-handler
  table for `findings.json`'s `suspect_condacts`.
- `node` must be on PATH - the jDAAD reference leg (`jleg.js`) runs under
  it, headless.
- **ZEsarUX 13.0 or later** (`tools/DAAD-READY/TOOLS/zesarux`). 13.0
  changed breakpoint semantics: `enable-breakpoints` must come BEFORE
  `set-breakpoint`, and no index ships pre-populated. ZEsarUX 12.1
  accepted either order, so when the toolchain was upgraded the harness
  silently stopped arming any breakpoint at all and every run blocked to
  its deadline - undetected for four days, because nothing tracked ran
  it. `zrcp.py` now issues enable-before-set and error-checks every
  reply whose failure would leave a run mis-armed. If you see a run hang
  with nothing armed, check the emulator version first.
- ZEsarUX needs port 10000 (or whatever `--port` you pass) FREE before
  you start. A stale emulator left over from an interrupted previous run
  silently poisons the next one: the new instance fails to bind, the
  harness attaches to the OLD process instead, and plays the current
  script against a reference leg paired with a DIFFERENT, previous game.
  `nleg.py` now guards against this (raises loudly if the port is
  already accepting connections before launch, or if the launched
  process dies before ZRCP ever comes up) - but killing any leftover
  ZEsarUX yourself before a run is still the fastest fix.
- `suspect_condacts` will be the ENTIRE game's condact set (88 entries on
  `tests/condacts.dsf`) whenever `suspects_narrowed` is `false` - which
  happens on any wildcard-heavy source or an empty/unmatched command.
  Check that flag before treating the list as a narrowed shortlist; when
  it is `false`, the list is not evidence about which condact is guilty,
  only a reminder of which condacts exist.
- RANDOM and CHANCE are made deterministic by MIRRORING NextDAAD's
  generator, not by stubbing it. `rng.py` is a transcription of
  `rng_next` (`src/overlay0.asm`) - the SP16 Task 5 XORSHIFT, with the
  `(x*100)>>16` scaling, NOT the old rotate-and-modulo routine - and
  `rngmirror.js` repoints jDAAD's `condactTable[95]`/`[10]` at the same
  stream from the same pinned seed. If the Z80 generator changes, both
  mirrors must change with it or every RANDOM/CHANCE turn diverges for a
  reason that has nothing to do with the game.
- Non-English games will show phantom text divergences: `tilemap.decode`
  maps every glyph outside the 32..126 ASCII range to a plain space,
  while the jDAAD leg captures characters up to 255. Any accented or
  extended character will look like a difference that is not one.
- `--mutate-next-only` exists (its help text is suppressed from
  `--help`, but the flag works) and is how the harness verifies it can
  still detect divergences at all - see
  `parser_selftest.py`'s `t11_negative_control_is_detected`. It rebuilds
  ONLY the Next leg's DDB from a deliberately mutated copy of the
  source, so the two legs are made to genuinely, deliberately disagree.
  Not for normal use.

## Your job

The tool makes no judgements. You do five things it cannot.

### 1. Prepare the game

Source-available games need nothing: pass the `.dsf` straight in through
`prepare.prepare_from_dsf`. The five tracked fixtures are
`tests/condacts.dsf`, `tests/test.dsf`, `tests/doallnest.dsf`,
`tests/NDPARTA.DSF`, `tests/NDPARTB.DSF`.

**Rabenstein and Urban Upstart are the real-game targets, and they need
no decompiler at all** - both ship DSF source directly:
- `tools/Rabenstein-master/nextdaad/rabenstein.dsf` - THIS is the one the
  tracked `scripts/rabenstein/d1.json` replay is baselined against: the
  next-only conversion, with the other platforms' `#ifdef` blocks and the
  MALUVA EXTERN dependency stripped. The sibling
  `tools/Rabenstein-master/rabenstein.dsf` is the multi-platform original
  and is a different game to the harness - do not swap them.
- `tools/urban-upstart/URBAN-UPSTART.DSF` (plus `-DEMO` and `0.1` variants)

Binary-only corpus games go through `prepare.prepare_from_binary`, which
decompiles with unDRC and gates on whether the result rebuilds. If it
does not rebuild the game is out of corpus - say so and move on. Do not
try to patch unDRC: it lives in `tools/`, which is read-only.

Use a **unique work directory per game** (`--out`). Every build produces
a hard-named `next.ddb`, so reusing one directory across two games could
leave a prior game's DDB in place after a failed rebuild. The API raises
rather than returning on failure, so this is safe today, but nothing
enforces directory uniqueness - don't rely on that safety net by choice.

### 2. Turn a prose solution into a command script

Corpus solutions are prose, not command lists - bracketed section
headers, parentheticals, commands comma-joined across wrapped lines, and
instructions like `R (if necessary; repeat until the drunk offers you a
bottle of wine for your colt)`.

Interpret them into a JSON array of turns. A turn is either a command
STRING (three forms) or an OBJECT carrying a per-turn directive:

| Form | Meaning |
| --- | --- |
| `"LOOK"` | a normal command - characters then Enter. |
| `"!X"` | raw keys, NO Enter, for prompts the line reader never sees. |
| `"?X"` | answer a confirmation prompt. |
| `{"cmd": "LOOK", "allow_timeout": true}` | as `"LOOK"`, but let the interpreter's own TIME countdown run for this turn. |
| `{"cmd": "", "allow_timeout": true}` | type NOTHING and let an input read time out. |

`allow_timeout` is opt-in per turn and off everywhere else on purpose.
Both legs normally run with the DAAD input timeout stopped dead - the
Next leg zeroes `inpTOFrames` on every settle poll, the reference leg
gates `jdaad.js`'s `inputTimeoutHandler` shut - because a timeout that
can only fire on ONE leg is a harness-manufactured divergence
(`docs/parser-bugs.md` entry 5). A turn that is ABOUT the timeout
(`tests/condacts.dsf` check 58 arms `TIME 2 0` and asserts flag 49 =
128; check 104 arms `TIME 1 2` and lets a "More..." page expire) says so,
and then BOTH legs let their own interpreter's own timeout run and
whatever they then disagree about is a finding, not something papered
over. An empty `cmd` is only legal with the directive - nothing else
could ever end that turn's wait. `nleg.load_script` is the normative
reader and validator; `jleg.js` re-implements the same normalisation,
and `zleg.py` rejects the directive by name (the ZX leg has no way to
read or force the original's timeout state).

`"?X"` is now the SAME input model on both legs - key, then Enter. It
used to be per-leg (NextDAAD the raw key only, jDAAD key plus Enter)
because the two interpreters really did collect confirmation input
differently, but SP16 Task 5 settled `docs/parser-bugs.md` entry 4
against the original ZX interpreter: the confirmation is a LINE read,
jDAAD was right, and `confirm` in `src/overlay0.asm` was changed to
match. The directive survives because the two legs still anchor their
capture differently around it (see the `"?"` branch in `nleg.play`) and
because it marks a turn that answers a prompt rather than issuing a
command. Do not conflate `"!X"` (raw keys, no Enter, for prompts the
line reader never sees) with `"?X"`.

**Save the script and reuse it.** Resolve the ambiguities once, record
how you resolved them in a comment alongside, and replay that file
thereafter. This is what makes the harness a regression gate rather than
a fresh guess every run.

Scripts live in `tests/parser/scripts/<game>/`, which is TRACKED - and
that includes scripts for games whose source lives in `tools/`
(`scripts/dracula/`, `scripts/rabenstein/`). A script is a list of
commands, not game content, and it is the thing that makes a replay
reproducible, so it belongs in git even when the game it drives does
not. What still never gets committed is run OUTPUT: everything under
`tests/parser/work/`.

### 3. Generate stress scripts from the vocabulary

The decompiled or authored `/VOC` section lists every word the game
defines. Solutions are written to succeed, so they avoid exactly the
input that breaks parsers. Generate scripts covering: unknown words,
adjective-noun pairs, conjunctions and THEN chains, IT and pronoun
resolution, GET ALL / DROP ALL and the AUTO* fallbacks, ambiguous nouns,
verb-only and noun-only input.

### 4. Triage the findings

`findings.json` classifies each divergence for you:

- `state-only` - a condact computed the wrong thing, and the text
  channel agreed this turn. The dangerous class. Start here.
- `text-only` - a print, message, window or wrap fault, game state
  agrees. Can carry a `text_ambiguous` caveat - see below before
  trusting it at face value.
- `both` - a condact fault with a visible consequence.
- `truncated` - one leg stopped early.

(`text-unclassifiable` no longer exists - it used to mark a
state-agrees/text-differs turn whose screen transition was itself
ambiguous; that case is now just `text-only` plus a `text_ambiguous`
caveat, since ambiguity is surfaced as a caveat everywhere, not as a
separate class reachable only from one combination.)

Each finding carries a `state_rank` and a `text_rank` independently
(`"primary"`, `"downstream"`, or `null` if that channel did not diverge
on this turn at all) - NOT one global `rank`. Only a `"primary"` value
is trustworthy for THAT channel: once a channel has diverged, later
divergences on the SAME channel are probably a cascade of the first, not
an independent fault. But the two channels cascade independently - a
flag that diverges every turn does not make a later, unrelated text
divergence `downstream` just because it happened afterward; check each
channel's rank on its own terms. Fix the state-primary finding, re-run,
look again - never record a downstream-on-that-channel finding as its
own divergence.

Each finding carries `suspect_condacts` with the NextDAAD handler symbol
for each, and a `repro` command prefix. The fix loop is: read
`findings.json`, edit the named handler in `src/`, rebuild with
`./build.ps1`, re-run the identical script, confirm the finding is gone
and no new ones appeared.

`report.md` also has a `## Transcript` section: every divergent turn's
command and both legs' raw, verbatim, unnormalised text, side by side.
Read it on any turn you intend to act on - the class label tells you
THAT the two legs differed, the transcript tells you WHICH line did.

Use the `daad-system` skill for condact and flag semantics.

Weaker evidence, worth checking before you trust a finding: a turn
carrying the caveat `text_ambiguous`, `anykey_heuristic`, or
`timing_sensitive` in `findings.json` is less reliable than an
uncaveated turn (screen transition was ambiguous, ANYKEY has no memory
signal so the wait was a heuristic guess, or the game re-armed a timeout
so behaviour can depend on wall-clock timing, respectively). Don't
promote a finding resting only on one of these without narrowing the
repro first.

### 5. Record what you confirm - this is not optional

`findings.json` and `report.md` land in a gitignored work directory and
get wiped. They are a run's output, not the project's memory. **Any
divergence you CONFIRM must be promoted into `docs/parser-bugs.md`**,
following the recording convention at the top of that file. This is the
owner's explicit standing instruction, not a suggestion.

This is not limited to parser behaviour despite the file's name. Record
any divergence between NextDAAD and a reference interpreter: condact
semantics, system and user message output, object handling, display and
layout, window behaviour, timing, save/load - anything where the two
disagree.

Three rules that matter more than the format:

- Promote only what you have CONFIRMED. A finding on a turn carrying a
  caveat (see above) is weaker evidence - either strengthen it with a
  narrower repro first, or record it with its uncertainty stated
  plainly. An entry that overstates its confidence is worse than no
  entry.
- Record NOT-A-BUG findings too, with the reasoning. Entry 3's tail is
  the model: the interpreter seeds its RNG from entropy, which LOOKS like
  a determinism bug and is in fact correct behaviour. Writing that down
  is what stops someone "fixing" correct code later.
- Only a channel's primary finding is trustworthy in a cascade. Do not
  record a finding that is `downstream` on the relevant channel
  (`state_rank`/`text_rank`) as a separate divergence - it is almost
  always the same fault seen again, on that channel.

## When a finding is contested

jDAAD is a JavaScript reimplementation, so it can be wrong too - but do
not treat "the reference is probably wrong" as a default. It is a
hypothesis to test, and the one time it was actually tested it lost.

`docs/parser-bugs.md` entry 4 is the SETTLED worked example, and it is
worth reading in that light. NextDAAD's QUIT/END confirmation read a
single keypress (matching the classic DAAD manual, per `h_end`'s own
comment) while jDAAD read a full line, so NextDAAD looked correct and
jDAAD looked like the deviation. SP16 Task 5 ran the tie-breaker below
against the original ZX interpreter: jDAAD was right, NextDAAD's
single-key read was the deviation, and NextDAAD was changed to a line
read. The adjudication is in
`.superpowers/sdd/sp16-adjudications/`.

When a finding looks like it might be a jDAAD artefact rather than a
NextDAAD bug, build the same DSF a third time for the ZX 48/128 target
and run it under ZEsarUX with the DAAD-READY interpreter. That one
renders through the ULA, so `get-ocr` reads it directly.

Three-way verdict at the divergent turn: if jDAAD and the Z80 build agree
and NextDAAD differs, the finding stands. If jDAAD stands alone, it is a
jDAAD artefact - discard it and note why.

Use the minimal repro, not the full script, so this stays cheap.

## The clean-run test is a baseline, not "zero findings"

`tests/condacts.dsf` contains real, known divergences (see
`docs/parser-bugs.md` entry 5), present before the script's own commands
run, originating in the fixture's boot self-test. Running the harness
against it does not, and should not, come back clean.

The baseline has shrunk to ONE flag. It was flags 29/50/53 plus objects
1/2; flag 48 and the objects were RETRACTED as harness-manufactured
artefacts (see entry 5's retraction note and `nleg.py`'s `objloc` - the
object table is a 6-byte struct array, not a flat location array, and
the old reader mis-strided it), flag 29 was fixed in SP16 Task 1 and
flag 53 in Task 4. **Flag 50 remains, and it is not yet adjudicated:**
jDAAD saves and restores flag 50 (FDOALL) per process-stack level
(`jdaad.js` `stackPush`/`stackPop`), while NextDAAD keeps it global -
and so does msx2daad. Which is correct is an open owner ruling, so the
selftest pins it as a known divergence rather than anyone "fixing" it in
either direction.

The end-to-end selftest case (`t11_clean_run_matches_known_divergence_baseline`
in `tests/parser/parser_selftest.py`) therefore asserts the run matches a
recorded **baseline** of known divergent flags/objects, and fails in
BOTH directions:

- a **new** divergence appears (a flag/object outside the baseline, or a
  purely textual finding with no flag/object cause at all) - investigate
  before treating it as expected;
- a **baselined** divergence disappears - this means either NextDAAD was
  genuinely fixed (shrink the baseline to match) or the harness went
  blind to something real (a regression in the harness itself, not in
  NextDAAD).

Shrinking the baseline over time, as candidate faults get confirmed,
fixed, or disproven as NOT-A-BUG, is the goal. A silently growing or
silently shrinking baseline both indicate a problem.

### Every replay baseline pin, in one place

Re-run any of these and expect the same hash -
`sha256(findings.json)[:16]`. A change is either a real regression or
something the changer must explain; neither is allowed to pass quietly.

| replay | game + script | turns / findings | hash |
| --- | --- | --- | --- |
| condacts smoke | `tests/condacts.dsf` + `scripts/condacts/smoke.json` | 13 / 13 | `928a594e261f644b` |
| condacts full | `tests/condacts.dsf` + `scripts/condacts/full.json` | 18 / 18 | `9b71ceb94559d564` (non-DEBUG build) |
| " | " | " | `30980ccd254d6295` (DEBUG build - see the build-variant note below) |
| dracula lamp | `tools/test-games/Dracula Part 1/dracula1.dsf` + `scripts/dracula/lamp.json` | 21 / 7 | `752950ee121abf2a` |
| dracula compound | same game + `scripts/dracula/compound.json` | 17 / 4 | `2f403989f005cfc2` |
| rabenstein d1 | `tools/Rabenstein-master/nextdaad/rabenstein.dsf` + `scripts/rabenstein/d1.json` | 6 / 6 | `6ed0e38dfc7e88eb` |

Rabenstein's pin is NEW as of commit `303abea` and supersedes the older
"not hash-stable, compare the fields instead" instruction - that
instruction was correct advice for the code as it stood and is now
historical. The two things that made it unstable, breakpoint page
capture and the boot settle parking on an ANYKEY, are both closed.

### Two condacts scripts, and which one to use

`scripts/condacts/smoke.json` (13 turns) is the REGRESSION PIN. It is a
generic script that reaches checks 50-60 and stops; its value is that its
`findings.json` has hashed to `928a594e261f644b` across every harness
change since SP16. Do not edit it.

`scripts/condacts/full.json` (18 turns) is the COVERAGE script. It answers
the fixture's own "TYPE:" prompts word for word and drives it end to end:
checks 51-101 and the appended 103-104 all report OK on the NextDAAD leg
(check 50 is F by design - the automated leg answers N to QUIT, since Y
would quit the game), and the run finishes on the fixture's deliberate
`PROCESS 5..14` nesting overflow, which raises NextDAAD runtime error 3.
That halt is detected (`ERRCODE`) and ends the run cleanly; a script with
turns after it is refused, because err_raise halts with interrupts off
and everything after would be played to a dead machine.

`full.json`'s hash is BUILD-VARIANT DEPENDENT and the other scripts' are
not. It is the only script that drives handlers carrying `IFDEF DEBUG`
diagnostics (SFX, XMESSAGE, GFX, and the E03 tail), and on a DEBUG build
those land on the screen the harness captures - "65 OK  SFX? 12",
"E03 P0C V64 N38 C4B" and so on - so the transcript, and the hash,
change. Compare against `9b71ceb94559d564` only with a non-DEBUG
`build/nextdaad.nex`, or it will "fail" for a reason that has nothing to
do with the harness. Related: `build/nextdaad.map` and
`build/nextdaad.nex` must come from the SAME build - pointing `--nex` at
an archived variant while the map belongs to a newer one makes the
RNG-seed breakpoint miss and the run dies at boot.

Checks 1-49 have no verdict in either transcript: they run during the
BOOT settle, before turn 0, and that output belongs to no turn. Check 102
(`EXIT 1`) stays owner-only - it is gated on a typed XEXIT verb, which
can only be reached by sacrificing check 60 (the last PARSE in the suite)
and whose pass condition is a full restart.

## Corpus status

Every binary-only corpus game is currently OUT of corpus, each for a
distinct named reason - this is the ingestion gate working correctly,
not evidence that testing doesn't work:

| Game | Reason |
| --- | --- |
| Dragnet Case | 255-wildcard round-trips as a raw literal |
| Murder Release | same 255-wildcard failure |
| Case of Murder | same 255-wildcard failure |
| Mystery City ZX Next | XNEXTRESET EXTERN mis-rendered |
| Die Ragus | XPICTURE deprecated |
| Golden Seas | XPICTURE deprecated |
| Kings Ransom | XPICTURE deprecated |
| From Out of the Snow | unDRC cannot find DDB data even with -a |

The 255-wildcard failure across three games (Dragnet Case, Murder
Release, Case of Murder) is one defect class, not three unrelated bugs -
it sits in the same family as the already-known unDRC MOUSE
parameter-count bug. unDRC lives in `tools/` and is read-only, so none of
these can be fixed from this repo.

**This does not mean there is nothing to test with real games.**
Rabenstein and Urban Upstart (see Step 1 above) ship DSF source and go
straight through `prepare_from_dsf` - no unDRC involved, no gate to clear.
They are the real-game targets for this harness today.

## Constraints

- Never write anything into `tools/`.
- Never commit tool output.
- No emojis or icons. Use `-`, not an em dash.
