# NextDAAD Authoring Kit

This folder builds DAAD text adventures for the ZX Spectrum Next. The game
is the one `.DSF` file in this folder; `BUILD.BAT` (Windows) or `./build.sh`
(Linux) compiles it and stages everything in `RELEASE\`.

Two skills in `.agents/skills/` cover the work. Load the one the task needs
before starting:

- `.agents/skills/daad-game-authoring/SKILL.md` - writing, changing or
  debugging a game: DSF source, vocabulary, objects, process tables,
  pictures, music, sound, the build and its errors.
- `.agents/skills/xbn-extern-authoring/SKILL.md` - writing Z80 machine code
  that the game calls with `EXTERN`, shipped as `GAME.XBN`.

The manual is `docs/index.html`. Do not change anything under `lib/` or
`tools/`; they are the kit's own build tools.
