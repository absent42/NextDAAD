# playername

Asks for the player's name and keeps it with the game. DAAD cannot store free text, so the game reads a line with `PARSE 0` as usual and this extern copies it out of the interpreter's recall buffer with `SVC_GETLINE`. The name lives in the extern state area, so `SAVE`, `LOAD`, `RAMSAVE` and `RAMLOAD` keep it with the game, and `RESTART` leaves it alone.

Needs an interpreter with API version 3 (the input services). On an older interpreter, or with no `GAME.XBN` at all, the game still plays: no name is stored, nothing is printed, and every condition passes.

## Functions

| fn | Kind | What it does |
|---|---|---|
| `EXTERN 0 20` | Condition | Takes the last typed line as the name: leading and trailing blanks dropped, cut to 16 characters, first letter capitalised. Fails (carry set) when nothing was typed - an empty ENTER, a timeout or only blanks - and leaves no name. |
| `EXTERN 0 21` | Action | Prints the name through the current window, or nothing when there is none. |
| `EXTERN 0 22` | Condition | Passes when no name is stored, fails when one is. |
| `EXTERN m 23` | Condition | Fails when the name equals message `m`, in any case. Passes when it differs, when there is no name, or when message `m` does not exist. Use it to catch a keyword typed at the name prompt. |

No flags are used. The name takes the last 17 bytes of the extern state area (offsets 111-127), a fixed claim in `xbnmod.inc`; modules of your own claim below it.

## DSF lines

Ask until something is typed, let a keyword skip the introduction, then greet the player by name:

```
/MTX
/40 "SKIP"

$askName
> _       _     MESSAGE "What is your first name?"
> _       _     PARSE   0                       ; the next entry runs whether or not the name parses
> _       _     EXTERN  0 20                    ; fails only when nothing was typed
                SKIP    $named
> _       _     SKIP    $askName
$named
> _       _     EXTERN  40 23                   ; fails when the name is SKIP
                SKIP    $intro
> _       _     PROCESS proNEWGAME              ; SKIP: straight into the game
                DONE
$intro
...
> _       _     MES     "May luck be with you"
> _       _     EXTERN  0 22                    ; passes when there is no name
                SKIP    $luck
> _       _     MES     ", "
                EXTERN  0 21
$luck
> _       _     MES     "."
```

## Building

Run `build.ps1` in this folder to rebuild `GAME.XBN` after editing the source. It is also part of `externs\all\GAME.XBN`, and `EXTERNS.BAT playername` builds it into a subset with whichever other modules you name.
