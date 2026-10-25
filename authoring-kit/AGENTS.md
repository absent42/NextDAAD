# NextDAAD Authoring Kit

This folder builds DAAD text adventures for the ZX Spectrum Next. Each game
lives in its own game folder, `<GAME>\<GAME>.DSF` plus its `IMAGES\`,
`AUDIO\`, `VIDEO\` and other files. `SET GAME=<GAME>` in `CONFIG.local.BAT`
selects the game; `BUILD.BAT` (Windows) or `./build.sh` (Linux) compiles it
and stages it in `RELEASE\<GAME>\`: `<GAME>.NEX` to launch, everything else
in `DATA\`. `DEBUG.BAT` / `./debug.sh` builds the same way and starts CSpect
with a debugger window (stepping, breakpoints, flags and objects); it is
an interactive tool for the person at the keyboard, so do not run it from
an agent session.

`STARTER\` is the shipped starter game and every kit update replaces it.
Never write a game in it: copy it to a new game folder first (rename
`STARTER.DSF`, `STARTER.CFG`, `AUDIO\STARTER.aks` and
`AUDIO\STARTER_FX.aks` to match) and work on the copy.

Two skills in `.agents/skills/` cover the work. Load the one the task needs
before starting:

- `.agents/skills/daad-game-authoring/SKILL.md` - writing, changing or
  debugging a game: DSF source, vocabulary, objects, process tables,
  pictures, music, sound, the build and its errors.
- `.agents/skills/xbn-extern-authoring/SKILL.md` - writing Z80 machine code
  that the game calls with `EXTERN`, shipped as `GAME.XBN`.

The manual is `docs/index.html`. Do not change anything under `lib/` or
`tools/`, or `CONFIG.BAT`; they are the kit's own and an update replaces
them. A game's settings go in `<GAME>\<GAME>.CFG`, machine settings in
`CONFIG.local.BAT`.
