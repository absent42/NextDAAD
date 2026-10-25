# Debugger

The debugger lets you stop your game in the middle of a turn and look
inside it: which process and entry is running, which condact is next,
what every flag and object holds. You can step one condact at a time,
stop automatically when a flag changes or an object moves, and change
flags and objects while the game is stopped. It shows the lines of your
own `.DSF` as you step through them.

Use it when a game does something you did not write: a message that
never appears, a door that opens at the wrong time, a flag that is not
the value you expected. Instead of adding `PRINT` lines and rebuilding,
you stop the game at the spot and read the answer.

It runs inside the CSpect emulator, as a second window beside the game.

## What you need

- **CSpect 4.0 or later**, installed as described in
  [Getting started](getting-started.md#what-you-need). Older CSpect
  builds still run your game with `RUN.BAT`, but not the debugger.
- **`EMULATOR=cspect`**, which is what you get when `EMULATOR` is blank.
  The debugger does not run in jNext. If `CONFIG.local.BAT` sets
  `EMULATOR=jnext`, remove that line or change it to `cspect`;
  `RUN.BAT` keeps using whatever `EMULATOR` says.
- A mouse. The debugger window is driven by clicking, with a few
  keyboard shortcuts for stepping.

You do not need to change your game. Every part of the debugger except
the `DEBUG` marker breakpoint works on a game with no `DEBUG` lines in
it - see [DEBUG markers](#debug-markers).

## Starting the debugger

Double-click `DEBUG.BAT` (Linux: `./debug.sh`) instead of `BUILD.BAT`
and `RUN.BAT`. It builds the game selected by `GAME`, then starts CSpect
on it with the debugger attached, and waits until you close CSpect.

The build is the same compile `BUILD.BAT` does. Two things are added,
and both are for the debugger only:

- **Source maps** are written into your game's source folder, beside
  your `.DSF`: `GAME.DSM` for the main game and `GAME2.DSM`,
  `GAME3.DSM` and so on for each part of a
  [multi-part game](multi-part-games.md). A source map tells the
  debugger which `.DSF` line each condact came from.
- **`NEXTDAAD.SYM`**, which describes the interpreter the kit ships,
  is copied into the same folder.

`DEBUG.BAT` also puts the debugger plugin, `NextDAADDebug.dll`, in
CSpect's own folder the first time, and again when the kit ships a newer
one. The plugin does nothing when CSpect is started any other way, so
`RUN.BAT` and your normal builds are not affected by it being there.

`DEBUG.BAT` does not use the `RUN` setting: it always starts CSpect once
the build succeeds.

Where the files go:

| File | Where | What it is |
|---|---|---|
| `GAME.DSM`, `GAME2.DSM` ... | your game's source folder | source maps |
| `NEXTDAAD.SYM` | your game's source folder | interpreter symbols |
| `DEBUGGER.local.TXT` | your game's source folder | your breakpoints, watches and window position, see [Settings](#settings) |
| `debugger.log` | your game's source folder | a short log of the session, for bug reports |
| `NextDAADDebug.dll` | CSpect's folder | the debugger plugin |

`RELEASE\<GAME>\` comes out exactly as `BUILD.BAT` makes it. None of
the files above go to the SD card, and `CLEAN.BAT` leaves them alone.
They are safe to delete; the next `DEBUG.BAT` writes them again.

Run `DEBUG.BAT` again after you change the `.DSF`. A plain `BUILD.BAT`
does not write source maps, and the debugger refuses to show line
numbers from a map that does not match the database the game loaded - see
[Status messages](#status-messages).

## The window

The window is called "NextDAAD debugger" and opens as a second window
next to the game. It is one fixed layout:

- **Toolbar**, top row: `Run`, `Break`, `Step`, `Step entry`,
  `Step out` and `Run to PARSE`, with `Ctrl+Alt+A/B/N/R` written dimly
  at the right as a reminder of the [shortcuts](#shortcuts). A button
  that does not apply right now is dimmed: all but `Break` need the game
  to be stopped, and `Break` needs it to be running.
- **Status line**, second row: what the game is doing. Messages are
  listed under [Status messages](#status-messages). A problem is shown
  here in red.
- **Process stack**, top left: the processes running right now, newest
  at the top. Each line reads like `>1 PRO 1 GET LAMP :111`:
  - `1` is the level. Level 0 is the bottom of the stack, the process
    that called the others.
  - `PRO 1` is the process number.
  - `GET LAMP` is the verb and noun of the entry being run (`_` means
    any).
  - `:111` is the `.DSF` line the entry starts on.

  Click a line to look at that level; the `>` marks the one on show.
- **Condacts and Source tabs**, top right:
  - *Condacts* lists every condact of the entry on show, with its
    arguments spelled out - object and flag numbers followed by their
    names, message numbers followed by their text, the value a
    `@flag` indirection currently holds. The condact the game is about
    to run is marked with an arrow. The number at the left is the
    `.DSF` line, or the position in the database if there is no source
    map for it.
  - *Source* shows your `.DSF` file, with the current line marked. The
    file's name is written dimly to the right of the two tabs, so you can
    tell an `#include`d file or a part's file from the main one. The two
    columns at the left are the breakpoint margin - see
    [Breakpoints on source lines](#breakpoints-on-source-lines).
- **Bottom tabs**: `Watches`, `Flags`, `Objects`, `Parser`, `Database`
  and `Breakpoints`.

Scroll any list with the mouse wheel.

### The bottom tabs

- **Watches** - the flags and objects you picked to keep in view. The
  three buttons at the top, `+ Flag`, `+ Object` and `+ Symbol`, open a
  list to pick from. `+ Symbol` lists the names you `#define`d in your
  source; after you pick one it asks whether that number is a flag or
  an object. Click the `x` at the left of a row to remove it.
- **Flags** - all 256 flags with their values. The kit's system flags
  carry their names (`Player location`, `Score`, `Verb` and so on);
  flags you gave a `#define` name in your source carry that name. For the
  parser and location flags the word or place is shown after the value.
  Click the `+` at the left of a row to put the flag in Watches (it
  becomes `*`). `Go to #` jumps to a flag number.
- **Objects** - every object with its location and where that is, its
  weight, whether it is a container (`C`) or wearable (`W`), and its
  attribute bytes in hex. Locations 252 to 255 read `not created`,
  `worn`, `carried` and `here`. Same `+` column and `Go to #` button as
  Flags.
- **Parser** - the last sentence the parser understood: verb, noun,
  adjective, adverb, preposition, second noun and second adjective, each
  with its flag number, value and word.
- **Database** - the compiled game's text and tables, to look things up
  without leaving the debugger. Sub-tabs: `Messages`, `SysMess`,
  `Locations`, `Objects`, `Vocab`, `Tokens`, `Connections`. `Go to #`
  jumps to a row; the `Vocab` sub-tab also has an A to Z strip to jump to
  a letter.
- **Breakpoints** - see [Breakpoints](#breakpoints).

Values that have changed since the game last stopped are drawn in yellow,
so after a step you can see at a glance what that condact did.

## Stopping and stepping

While the game runs, use `Break` to stop it at the next condact. While
it is stopped, the other buttons move it on:

| Button | What it does |
|---|---|
| `Run` | Lets the game run until a breakpoint stops it, or you press `Break`. |
| `Step` | Runs one condact. A `PROCESS` condact steps into the process it calls. |
| `Step entry` | Runs until the next process entry starts, in this process or one it calls. |
| `Step out` | Runs until the current process has finished and the game is back in the one that called it. |
| `Run to PARSE` | Runs until a `PARSE` condact has finished, and stops on the condact after it. |
| `Break` | Stops the game at its next condact. |

The game must actually be running condacts for a stop to happen. While
it waits for you to type an order, nothing is running: press `Break`,
then type an order in the game, and it stops on the first condact that
follows.

When the game is stopped, the emulated Next is frozen and its screen
stops updating. The game picks up where it left off when you run or step
it.

### Shortcuts

Four shortcuts work from the keyboard. Click the CSpect window (the one
showing your game) first, because that is where the keys go:

| Keys | Same as |
|---|---|
| `Ctrl+Alt+A` | Show or hide the debugger window |
| `Ctrl+Alt+B` | `Break` |
| `Ctrl+Alt+N` | `Step` (N for next) |
| `Ctrl+Alt+R` | `Run` |

The shortcuts work whether or not the debugger window is on show.
Closing the window, with its close box or `Ctrl+Alt+A`, does not stop
the debugger: breakpoints still halt the game, and `Ctrl+Alt+A` brings
the window back. If the game stops and no window is showing, press
`Ctrl+Alt+A`.

## Breakpoints

A breakpoint stops the game automatically. The `Breakpoints` tab lists
them. `Add` builds a new one by asking a few questions; click the `[x]`
at the left of a row to switch it off and on without deleting it, or
`del` at the right to remove it.

A game with no saved settings starts with two: `DEBUG marker` and
`Runtime error`.

The kinds `Add` offers:

| Kind | Stops when | Asks for |
|---|---|---|
| `DEBUG marker` | the game reaches a `DEBUG` line in your source | nothing |
| `Process / entry` | a given process starts a given entry | the process, then the entry verb and noun; `(any)` matches every verb or noun |
| `Condact` | the game is about to run a given condact, anywhere | the condact name |
| `Flag changes` | a given flag gets a new value | the flag |
| `Flag compare` | a flag becomes equal to, different from, below or above a value | the flag, the comparison (`=`, `<>`, `<`, `>`), the value |
| `Object moves` | a given object gets a new location | the object |
| `Runtime error` | the interpreter raises a runtime error (`E1`, `E4` ...) | nothing |

`Flag changes`, `Flag compare` and `Object moves` stop on the condact
*after* the one that made the change, and the status line names the
condact that did it, for example `breakpoint: flag 100 changed 7 -> 8 (by
LET 100 8)`. A `Flag compare` stops when the test turns from false to true,
not on every condact while it stays true.

### Breakpoints on source lines

Open the `Source` tab. The two columns at the left of each line are the
breakpoint margin. Click a line's margin to put a breakpoint on it - a
red dot appears - and click again to remove it. Only lines that compile
to something can take one; clicking a comment or a blank line does
nothing.

A source-line breakpoint is kept by file name and line number, so it
follows the file through `#include`s and parts. If you edit the `.DSF`
and lines move, look the breakpoints over in the `Breakpoints` tab. They
appear there as `line 42 of MYGAME.DSF`.

### Which breakpoint is reported

When a stop has more than one possible cause, the status line names one:

1. A stepping command in progress (`Step`, `Step entry`, `Step out`,
   `Run to PARSE`, or `Break`) comes first. Its stop says `step`,
   `next entry`, `returned to level N` or `after PARSE`.
2. Otherwise, the first switched-on breakpoint in the `Breakpoints` list
   that matches names the stop. Breakpoints are listed in the order you
   added them.

A `Runtime error` breakpoint is separate: it stops at the error itself,
with the message `runtime error En`.

## Changing flags and objects

While the game is stopped you can change it, to test what happens next
without playing back to the spot:

- **A flag:** on the `Flags` tab click the value. A number pad opens.
  Or roll the mouse wheel over the value to change it by one.
- **An object's location:** on the `Objects` tab click its location. A
  list of locations opens; pick one. The special places
  252 to 255 are at the top.

The change goes straight into the running game. It is not written to your
`.DSF`, and a change you make here does not itself trigger a `Flag
changes`, `Flag compare` or `Object moves` breakpoint.

The edit controls are inactive while the game is running.

### Number pads and lists

Choosing a flag, object, process, condact or word opens a pop-up over the
window. Click an entry (or a digit and `OK`) to choose, `Cancel` or a
right-click to back out. The A to Z strip at the top of a long list jumps
to a letter.

If you would rather type: below the window picture is a text box that
wakes up while a pop-up is open, with the hint `type a number or name,
Enter = OK, Esc = cancel`. In a number pad, type the number. In a list,
type the first letters of the row and the first row that starts that way
is chosen. In the flag, object and location lists every row starts with
its number, so type the number there; a name is only matched in the
word, condact and symbol lists. If nothing fits, the hint changes to
`not accepted:` followed by what you typed, and the pop-up stays open.

## Settings

The debugger remembers your breakpoints, your watches and where you put
its window. They are saved for each game in `DEBUGGER.local.TXT` in the
game's source folder, which means every game keeps its own set and they
are back the next time you run `DEBUG.BAT`.

The file is written for you as soon as you add, switch or remove a
breakpoint or watch. The window position is saved when you close the window or
quit CSpect. The file is a plain text list; you do not need to edit it.
Delete it to go back to the two starting breakpoints. A file the debugger
cannot read is ignored in the same way.

The `local` in the name is a reminder that these are your own settings.
Leave the file out of anything you share.

## DEBUG markers

A `DEBUG` line in a process entry marks a spot in your code. It does
nothing in play. It exists so the debugger can stop there.

A `DEBUG` marker is only compiled into the game when the source contains
the directive `#debug`. Write it in lower case, on a line of its own.
The `DEBUG` marker breakpoint is the only part of the debugger that
needs it.

**Every build warns while `#debug` is present:**

    WARNING: MYGAME.DSF has #debug - DEBUG markers are compiled into the game; remove it before release (other DAAD interpreters read a marker as NEWTEXT)

The file named is the one holding the directive, which can be an
`#include`d file, and it is reported once per build. The warning appears
whether you build with `BUILD.BAT` or `DEBUG.BAT`, because the markers
end up in the game either way, including in `RELEASE\`.

NextDAAD steps over a marker when there is no debugger attached, so a
game built with `#debug` plays correctly here. Other DAAD interpreters
do not know the marker. They read it as `NEWTEXT`, which throws away the
rest of a multi-command order. Remove `#debug` before you release a game
that anyone might play anywhere else. See also
[Platform notes](platform-notes.md#debug-builds).

## Multi-part games

`DEBUG.BAT` writes a source map for every part: `GAME.DSM` for the main
game and `GAME2.DSM` to `GAME9.DSM` for parts 2 to 9, all in the game's
source folder (not inside the `PART<n>\` folders). Whenever the game
loads a database, the debugger picks the map that matches it, so the
`Source` tab, the line numbers and the source-line breakpoints follow you
as you switch parts. A source-line breakpoint in a file that the loaded
part does not use waits in the list and starts working again when its
part is back.

## Status messages

On the status line:

| Message | Meaning |
|---|---|
| `waiting for NextDAAD` | The interpreter has not started running your processes yet, for example while a loader intro is playing. |
| `running` | The game is running. It shows as soon as the interpreter runs its first condact, and again after each stop. |
| `HALTED - <reason>` | The game is stopped, for the reason given: `step`, `next entry`, `returned to level N`, `after PARSE`, `DEBUG marker`, `runtime error En`, or `breakpoint: ...` followed by what matched. |
| `HALTED - ... (N condacts ran past)` | The emulator ran N more condacts before it could stop. What the window shows is the state at the stop itself. |

Problems, shown in red on the status line:

| Message | What to do |
|---|---|
| `symbol file does not match this interpreter build` | The game is running an interpreter other than the kit's own `nextdaad.nex`, for example because `NEXFILE` names another one. Take that setting out while you debug. |
| `NEXTDAAD.SYM: ...` | The interpreter symbols in your game folder could not be read. Run `DEBUG.BAT` again; it copies a fresh one. |
| `debugger error, disarmed - see debugger.log: ...` | The debugger hit an unexpected fault and shut itself off so as not to disturb the game; if the game was stopped, it is let go. Quit CSpect, start `DEBUG.BAT` again, and if it comes back keep `debugger.log` for a bug report. |
| `init failed: ...` | The plugin could not start. Same advice. |

On the `Source` tab, when there are no lines to show:

| Message | What to do |
|---|---|
| `source map not checked yet - waiting for NextDAAD` | Normal before the game's first condact runs. |
| `no source map` | There is no source map file at all (`GAME.DSM`, or `GAME2.DSM` to `GAME9.DSM`) in the source folder. Run `DEBUG.BAT` (not `BUILD.BAT`), which writes them. |
| `GAME<n>.DSM: ...` | A map file could not be read, and no other map fits the database the game loaded. The name is the first file that failed (`GAME.DSM` for the main game) and the text after it says why. Run `DEBUG.BAT` again. |
| `source map is missing (<file>) - rebuild` | No map fits the database the game loaded, and the map file named in brackets (for example `GAME.DSM`) is missing while a later part's map is there. Run `DEBUG.BAT` again. |
| `source map is out of date - rebuild` | The database the game loaded is not the one the maps were made for: the database was built from changed source after the last `DEBUG.BAT`, so the maps describe older code (or this part's map has been deleted). Run `DEBUG.BAT` again, which rebuilds the database and the maps together. The `Condacts` tab shows plain positions in place of line numbers until you do. |
| `file N not in the source map` | The map names no file for this stop. Run `DEBUG.BAT` again. |

Other texts you will see: `Process stack` shows `(empty)` when no process
is running and `waiting for NextDAAD` before the game starts, and the
`Condacts` tab says `no process running` when there is nothing to list.

## Differences on Linux

`./debug.sh` works the same way, with these differences:

- **The window cannot be hidden.** The debugger cannot close its window
  under mono, so it stays on screen until you quit CSpect, and
  `Ctrl+Alt+A` does nothing while it is open. The other shortcuts work.
- **Starting CSpect yourself.** `./debug.sh` and `./run.sh` give CSpect
  the game folder as `-mmc=RELEASE/MYGAME//`. If you start CSpect by
  hand, end the `-mmc=` folder in `//` too: with a single `/`, CSpect on
  Linux does not find the game's `DATA/` folder and the game stops at
  `E1`.
- **File names keep their case.** A source-line breakpoint on
  `inc/rooms.dsf` is not one on `inc/ROOMS.DSF`. The Linux build already
  insists that every `#include` matches the file's case.
- It needs `pwsh` and mono, as `run.sh` does. See
  [Getting started](getting-started.md#linux-setup).

## When DEBUG.BAT stops

`DEBUG.BAT` stops with a message beginning `ERROR:` and, on Windows,
waits for a key before closing the window so you can read it.

| Message | What to do |
|---|---|
| (the game could not be chosen) | Same cause and fix as for `BUILD.BAT`: see [Choosing the game](getting-started.md#choosing-the-game). |
| `ERROR: the debugger runs in CSpect - set EMULATOR=cspect in CONFIG.local.BAT (RUN.BAT still runs jNext)` | `EMULATOR=jnext` is set. Change it, or remove the line. On Linux the message names `run.sh`. |
| `ERROR: EMULATOR=<name> - use cspect or jnext` | `EMULATOR` holds something else. Set it to `cspect`. |
| `ERROR: CSpect not found at <path>` | CSpect is not installed there. Install it in `tools\CSpect\`, or set `CSPECTDIR` in `CONFIG.local.BAT` to the folder you have it in. |
| `ERROR: <program> not found - CSpect needs mono on Linux (sudo apt install mono-devel), or set CSPECTCMD in CONFIG.BAT` | Linux only: mono is missing. |
| `ERROR: the debugger needs CSpect 4.0 or later - found <version> in <folder>` | Install CSpect 4.0 or later. Older builds still run with `RUN.BAT`. |
| `ERROR: could not read the CSpect version in <folder> - the debugger needs CSpect 4.0 or later` | The version of `CSpect.exe` could not be read, and the folder lacks the files CSpect 4.0 brings. Install CSpect 4.0 or later. |
| `note: could not read the CSpect version - assuming 4.0 or later` | Not an error. The version could not be read, but the folder has the files CSpect 4.0 brings. The debugger carries on. |
| `ERROR: <file> not found - the kit is incomplete` | `NEXTDAAD.SYM` or `lib\NextDAADDebug.dll` is missing from the kit folder. Unzip the kit again over the folder. |
| `ERROR: pwsh (PowerShell 7) not found - see docs/getting-started.html, Linux setup` | Linux only, printed by `./debug.sh` itself: install PowerShell 7 as described in [Getting started](getting-started.md#linux-setup). |
| any build error | Same as for `BUILD.BAT`: see [Getting started](getting-started.md#when-the-build-fails). |
| `ERROR: could not copy NEXTDAAD.SYM into <folder>` | The game's source folder is read-only or locked. |
| `ERROR: cannot update <path> - close CSpect and try again` | A CSpect that is still open has the plugin file locked. Quit it and run `DEBUG.BAT` again. |

When it installs the plugin, or finds a newer one already there, it
prints one of:

    debugger plugin -> tools\CSpect\NextDAADDebug.dll
    debugger plugin in tools\CSpect is newer (<version>) - kept

The second means CSpect's folder already holds a newer plugin than the
kit's. It is left alone and used. Nothing is printed when the plugin
there is already the kit's own.
