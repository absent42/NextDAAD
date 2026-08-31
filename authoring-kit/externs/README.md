# Externs

Ready-to-use XBN externs for NextDAAD games. Every folder here is
self-contained: the assembly source, a prebuilt `GAME.XBN` you can copy
straight to your card, a `README.md` with the DSF lines that drive it,
and a `build.ps1` to rebuild after editing.

To use one: copy its `GAME.XBN` next to your `GAME.DDB` and add the DSF
lines from its README. No assembler needed unless you change the source.

| Extern | What it does | fn codes | Flags used |
|--------|--------------|----------|------------|
| `ticker/` | Types a database message across the screen one character per frame, news-ticker style | 30 arm, 31 disarm | - |
| `fade/` | Fades the Layer 2 picture to any RRRGGGBB colour and back - fade to black for a scene change, change the picture, fade up again. Transparent regions stay transparent; a completed fade-in restores the palette bit for bit | 40 fade out, 41 fade in, 42 re-snapshot after a picture change, 43 wait for the fade | 240 done, 241 speed |
| `hints/` | Prints hint text served from an SD card file (`GAME.HNT`), so a game can ship a large hint book without spending DAAD message slots or interpreter RAM | 50 print hint, 51 level count, 52 preflight, 53 clear progress | 242 level override, 243 status/count |
| `clock/` | An in-game clock advanced from the frame hook, with hour carry and an author-driven advance for sleeping or travelling | 60 arm and start, 61 stop, 62 advance p minutes | 224 hours, 225 minutes, 226 running, 227/228 rate, 244 days |
| `timer/` | Three independent countdown timers, counting real seconds or in-game minutes, that expire into a flag your process table can test | 63 arm, 64 stop all three, 65 arm slot p as an in-game-minute deadline | 229-234 remaining (3 pairs), 235-237 state; an armed in-game-minute slot also READS the clock's 224, 225 and 244 |
| `all/` | every extern in this collection in one binary | all of the above | all of the above |

A game uses ONE `GAME.XBN`. You do not have to merge anything by hand: the
`all/` folder ships every extern here built into one binary, so copy that
`GAME.XBN` and use whatever functions you want. Function codes and flags are
disjoint across the collection, and a module is dormant until you arm it, so an
unused module costs you neither.

If you want a smaller binary with only the modules you use, run `EXTERNS.BAT`
from the kit root:

    EXTERNS.BAT ticker fade

This writes `GAME.XBN` to the kit root, beside `BUILD.BAT`. Copy it next to
your `GAME.DDB` the same as any other extern binary. That needs a Z80
assembler. Download sjasmplus from
https://github.com/z00m128/sjasmplus and extract it into `tools\sjasmplus\`, or
point `SJASMPLUSDIR` in `CONFIG.BAT` at an install you already have. You do not
need it otherwise: every extern here ships a prebuilt `GAME.XBN`, and `all/`
ships one containing the lot.

`CALL` targets are slots in a fixed jump table at `$C00A` - slot n is at
`$C00A + 3n` - never routine addresses, which differ between the standalone,
combined and subset builds.

## Want yours here?

Community externs are welcome. The submission requirements and process
are in [CONTRIBUTING.md](../../CONTRIBUTING.md) at the repository root -
in short: the four files above, fn codes 16+ documented in your README,
the extern rules from the manual's externs chapter obeyed, and
`tests\audit-externs.ps1` passing locally before you open the PR.
