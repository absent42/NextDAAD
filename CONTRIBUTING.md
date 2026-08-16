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
be useful beyond a single game. The two shipped externs (`ticker`,
`fade`) are the reference for tone, size and documentation.

### What your folder must contain

Exactly these four files:

| File | Requirement |
|------|-------------|
| `<name>.asm` | One source file, assembling with sjasmplus against the kit's `xbn.inc` alone (`-I` the kit root; no other includes, no interpreter internals). `DEVICE ZXSPECTRUMNEXT`, `ORG XBN_ORG`, `XBN_HEADER`, `xbn_end`, `SAVEBIN "GAME.XBN"` - the shape the manual's externs chapter documents |
| `GAME.XBN` | The prebuilt binary, byte-identical to a fresh assembly of the source. The audit rebuilds and compares, so commit both together every time |
| `README.md` | What it does, the exact DSF lines that drive it, every fn code and flag it uses, anything it deliberately does not do |
| `build.ps1` | Rebuild script - copy one from a shipped extern and change the file name |

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
