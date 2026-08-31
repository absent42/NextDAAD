# Contributing to NextDAAD

Bug reports and fixes are always welcome as issues and pull requests.
For interpreter changes, open an issue first - the interpreter carries
frozen contracts (the XBN service table, flag addresses, the DDB
format) and behaviour is pinned by a compliance suite, so a change that
looks small can be load-bearing.

The rest of this document is about submitting an extern for the authoring kit.

## Submitting an extern

Externs live in `authoring-kit\externs\`, one folder per extern. Yours
should do one thing well, be driveable from a handful of DSF lines, and
be useful beyond a single game. The shipped collection (`ticker`,
`fade`, `hints`, `clock`, `timer`, `toolkit`) is the reference for
tone, size and documentation, and every folder in it follows the
combinable module convention below.

### What your folder must contain

Exactly these four files:

| File | Requirement |
|------|-------------|
| `<name>.asm` | One source file in the combinable module shape below, assembling with sjasmplus against the kit's `xbn.inc` and `xbnmod.inc` alone (`-I` the kit root; no other includes, no interpreter internals) |
| `GAME.XBN` | The prebuilt binary, byte-identical to a fresh assembly of the source. The audit rebuilds and compares, so commit both together every time |
| `README.md` | What it does, the exact DSF lines that drive it, every fn code and flag it uses, anything it deliberately does not do |
| `build.ps1` | Rebuild script - copy one from a shipped extern and change the file name |

### The combinable module convention

Every collection extern builds two ways from one source: standalone
(its own `GAME.XBN`) and as one module among several in a combined
binary (`externs\all\`, or an `EXTERNS.BAT` subset). The shape that
makes that work:

```
; Standalone build emits its own header and call table; a combined
; build defines XBN_MODULE and supplies both.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN myext.ext, myext.int
    ENDIF

    MODULE myext
ext:
    ; EXTERN/CALL entry. Test C (the fn code) against your own range
    ; FIRST and return immediately on anything else - in a combined
    ; binary every module's ext sees every EXTERN call.
    ret
int:
    ; frame hook, or omit and pass 0 to XBN_BEGIN. In a combined
    ; binary this runs every frame regardless, so when idle it must
    ; be a load-and-test and nothing more.
    ret
    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
```

Rules that come with it:

- `XBN_BEGIN`, not `XBN_HEADER`: it emits the header plus the pinned
  `CALL` slot table at `$C00A`. Slots are frozen and append-only;
  document any slot you claim, and never publish a routine address as
  a `CALL` target - addresses move whenever any module is edited.
- Your fn codes and flags must be disjoint from every other collection
  module - check the table in `authoring-kit\externs\README.md` and
  add your row to it.
- Scratch RAM above the saved image is claimed through the
  `XBN_SCRATCH_FREE` chain in `xbnmod.inc` (see the comment there), so
  modules never collide.
- Wiring into the combined binary is three lines in
  `authoring-kit\externs\all\all.asm`: a `DEFINE XBN_HAS_<NAME>`, an
  `INCLUDE`, and your `.ext`/`.int` added to its chains. Maintainers
  do this at acceptance, but your module must be shaped so they can.

### Code rules

These come from the manual's externs chapter and are checked in review:

- fn codes 16 and up only, documented in your README. Codes 0-15
  belong to the interpreter, DEBUG probes and history. Stay clear of
  codes and flags other kit externs use (the table in
  `authoring-kit\externs\README.md`) so merged binaries coexist.
- Interrupt-hook discipline, if you use the `#int` hook: keep it well
  under a frame, no `EI`, no zxnDMA, no file IO, no service calls, and
  never install your own interrupt vector - your bank is only mapped
  while your code runs.
- Tilemap output that must be visible on every display stays in rows
  4-27. Rows 0-3 and 28-31 are border area and real display chains
  crop them (this cost the fade example a bench session to learn).
- Save and restore any shared indexed hardware register interface you
  touch - the palette index/value pair, the TBBlue register-select
  latch. The fade extern's bracket is the worked pattern.
- Durable state goes in flags: your bank is not part of save games.
- Parameters arrive in the two EXTERN bytes and in flags; there is no
  inline data after the condact on this interpreter.

### Before you open the PR

1. Run the audit locally and fix anything it reports:

       powershell -File tests\audit-externs.ps1

   It checks the four files are present, your binary matches a fresh
   assembly of your source, the XBN header validates, your README
   documents the interface, and the text rules hold. The same audit
   runs automatically on your pull request.

2. Test the prebuilt binary beside a real
   `GAME.DDB` - not just in your development layout. Say in the PR
   what you verified on CSpect and what on real hardware.

3. Fill in the extern section of the pull request template, and add
   your row to the table in `authoring-kit\externs\README.md`.

### What happens after acceptance

Maintainers wire your extern into the test harness (a staging switch
and the freshness guard), and may add a mention in the shipped manual.
You keep authorship in your folder's README. Interpreter-side changes
your extern would need - a new service, a contract change - are a
separate conversation first: open an issue, since services are frozen
and append-only.
