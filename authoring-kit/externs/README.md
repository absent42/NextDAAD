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
| `all/` | every extern in this collection in one binary | all of the above | all of the above |

A game uses ONE `GAME.XBN`. You do not have to merge anything by hand: the
`all/` folder ships every extern here built into one binary, so copy that
`GAME.XBN` and use whatever functions you want. Function codes and flags are
disjoint across the collection, and a module is dormant until you arm it, so an
unused module costs you neither.

If you want a smaller binary with only the modules you use, and you have
sjasmplus, build a subset:

    ..\lib\xbnbuild.ps1 ticker fade

`CALL` targets are slots in a fixed jump table at `$C00A` - slot n is at
`$C00A + 3n` - never routine addresses, which differ between the standalone,
combined and subset builds.

## Want yours here?

Community externs are welcome. The submission requirements and process
are in [CONTRIBUTING.md](../../CONTRIBUTING.md) at the repository root -
in short: the four files above, fn codes 16+ documented in your README,
the extern rules from the manual's externs chapter obeyed, and
`tests\audit-externs.ps1` passing locally before you open the PR.
