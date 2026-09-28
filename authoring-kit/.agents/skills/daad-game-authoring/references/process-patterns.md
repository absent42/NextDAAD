# Process patterns

How the standard tables fit together, and idiomatic entries for the things
every game needs. All examples use STARTER.DSF's symbols and layout; a new
game starts from that file and keeps its processes 0, 1 and 2 intact.

## How a table runs

1. Entries are scanned top to bottom. An entry matches when its verb and
   noun equal flags 33 and 34; `_` matches anything.
2. Inside an entry, condacts run in order. A false condition abandons the
   entry and the scan continues with the next matching entry. An action
   runs and the entry continues.
3. An entry that reaches its end without `DONE`, `NOTDONE`, `OK`, `SKIP`,
   `REDO`, `RESTART`, `END` or `EXIT` falls through: the scan carries on
   and later matching entries also fire. This is the source of doubled
   messages.
4. Falling off the end of a table returns to whoever called it.

So: put specific entries above general ones, end each response with
`DONE`, and order multi-state entries so exactly one can match.

## The standard tables

| Process | Role | Touch it? |
|---|---|---|
| 0 | Location loop: darkness test, picture, description, then `PROCESS 3`, then `PROCESS 1` | Leave alone |
| 1 | Turn loop: `PROCESS 4`, `PARSE 0`, turn counter, `PROCESS 5`, `ISDONE`, `MOVE`, "can't go" / "can't do that" | Leave alone |
| 2 | Called when PARSE fails: timeout message or "I did not understand" | Leave alone |
| 3 | Runs after every location description | Add location extras here |
| 4 | Runs every turn before input | Timed events, NPCs, counters |
| 5 | The command table | Most of the game lives here |
| 6 | Initialisation, run once from process 0 when the player is at location 0 | Append your setup |
| 7+ | Yours | Sub-tables called with `PROCESS n` |

Process 1 decides whether the player's command was handled by calling
process 5 and testing `ISDONE`. The table counts as done the moment any
action runs in it: `SET`, `LET`, `MESSAGE`, `PLACE`, all of them, with or
without a `DONE` afterwards (only `SKIP` and `REDO` do not count). The
table counts as not done only when no entry got past its conditions, or
when the last thing it did was `NOTDONE`. So an entry that should merely
prepare something and then let the engine carry on to `MOVE` must end with
`NOTDONE`; leaving the terminator off does not do that, it just lets later
entries fire as well and still blocks the move.

## Initialisation (append to process 6)

```
> _ _   LET  fStrength 10        ; carry limits start at 0 on NextDAAD
        LET  fMaxCarr  4
        CLEAR fDoorOpen          ; your flags (RESTART does not zero them)
        GOTO 1
```

STARTER already clears every flag from 255 down, resets objects, sets the
limits and does `GOTO 1`. Insert your flag setup before its `GOTO 1`, or set
your flags with `LET` in the same block.

## Get, drop, inventory (already in STARTER's process 5)

```
> GET   ALL   DOALL HERE
> GET   _     AUTOG
              DONE
> DROP  ALL   DOALL CARRIED
> DROP  _     AUTOD
              DONE
```

Special cases go above the generic entries:

```
> GET   ANCHO AT lJetty
              MESSAGE "It is far too heavy."
              DONE
```

Note `ANCHO`: only five letters of a word count, and the header must use
the word exactly as `/VOC` spells it.

## Examine

```
> EXAMI LAMP  PRESENT oLamp
              ZERO fLampLit
              MESSAGE "An old brass lamp, unlit."
              DONE
> EXAMI LAMP  PRESENT oLamp
              MESSAGE "The lamp burns steadily."
              DONE
> EXAMI _     MESSAGE "You see nothing special."
              DONE
```

The second entry needs no `NOTZERO`: if the first entry's `ZERO` failed,
the lamp is lit. The catch-all `EXAMI _` must come last.

## Doors and keys

```
> UNLOC DOOR  AT lTowerBase
              NOTCARR oKey
              MESSAGE "You have nothing to unlock it with."
              DONE
> UNLOC DOOR  AT lTowerBase
              NOTZERO fDoorOpen
              MESSAGE "It is already unlocked."
              DONE
> UNLOC DOOR  AT lTowerBase
              SET fDoorOpen
              MESSAGE "The key turns with a screech."
              DONE
```

Gate the exit with a movement entry in process 5, which runs before
process 1 reaches `MOVE`:

```
> N     _     AT lTowerBase
              ZERO fDoorOpen
              MESSAGE "The door is locked."
              DONE
```

With `fDoorOpen` set the entry fails at `ZERO`, process 5 ends with nothing
done, and `MOVE` uses the `/CON` exit as normal. The exit stays in `/CON`;
only the refusal lives in code.

## Doing something just before the engine moves the player

Sometimes a move should go ahead but a flag must change first, for example
darkness for the room the player is walking into. End the entry with
`NOTDONE` so process 1 still runs `MOVE`:

```
> D     _     AT lTowerBase       ; going down into the dark cellar
              SET fDark
              NOTDONE
> U     _     AT lCellar
              CLEAR fDark
              NOTDONE
```

Without the `NOTDONE` the `SET` marks the table done, process 1 sees
`ISDONE` and re-prompts, and the player never moves. The other correct
form does the move itself: `GOTO lCellar`, `CLS`, `RESTART`.

## Rooms with extra text (process 3)

```
> _ _   AT lLampRoom
        ZERO fLampLit
        MESSAGE "The great lamp stands cold and dark."
```

No `DONE` needed in process 3 unless you want to stop later entries.

## Darkness and light

Object 0 is the light source and flag 0 non-zero means "dark". Process 0
tests both before it describes the room, so flag 0 must already be set
when the player arrives. Set it in the pre-move entries shown above
(`SET fDark` / `NOTDONE` on the way in, `CLEAR fDark` / `NOTDONE` on the
way out), or in an entry that moves the player itself with `GOTO` and
`RESTART`. Setting it in process 3 or 4 is too late: the room has already
been described as lit.

With flag 0 set and object 0 absent, process 0 prints SM0 instead of the
description and `LISTOBJ` shows nothing.

A light that can be lit and put out needs two objects so that object 0
only exists while the light is burning: the unlit lamp is some other
object number, the lit lamp is object 0 starting at `NOT_CREATED`, and
lighting it is `SWAP oLampUnlit 0` (which exchanges their positions, so the
lit lamp appears wherever the unlit one was). Putting it out is the same
`SWAP` again. STARTER ships a torch as object 0 that is carried and lit from
the start; remove or renumber it when the game has its own light source,
or no room will ever be dark.

## Timed events and counters (process 4)

```
> _ _   NOTZERO fCandleTurns     ; counting down while lit
        MINUS   fCandleTurns 1
> _ _   NOTZERO fCandleLit
        ZERO    fCandleTurns
        CLEAR   fCandleLit
        PLACE   oCandleLit NOT_CREATED
        CREATE  oCandleOut
        MESSAGE "The candle gutters and goes out."
```

Process 4 runs before the player types, and again after every `RESTART`
(LOOK, R, LOAD, any response that redescribes the room), so a countdown
kept there ticks more than once on those commands. When exact turn counts
matter, tick only when the engine's turn counter has moved:

```
> _ _   SAME fTurns fLastTurn      ; process 4: already counted this turn
        DONE
> _ _   COPYFF fTurns fLastTurn
        ... the once-per-turn work follows in later entries ...
```

The most advanced state should be tested first when several stages exist:

```
> _ _   AT lCave
        EQ fTroll 2
        MESSAGE "The troll swings his club. You are dead."
        END
> _ _   AT lCave
        EQ fTroll 1
        LET fTroll 2
        MESSAGE "The troll raises his club."
> _ _   AT lCave
        ZERO fTroll
        LET fTroll 1
        MESSAGE "A troll glowers at you."
```

## Characters that move

Keep the character's location in a flag and its object at that location:

```
> _ _   CHANCE 30                 ; process 4
        COPYFF fVerb 200          ; save the player's verb
        LET    fVerb 2            ; north
        MOVE   fGuardLoc          ; fails the entry when there is no exit
> _ _   COPYFF 200 fVerb          ; always restore the verb
        COPYFO fGuardLoc oGuard
> _ _   SAME fGuardLoc fPlayer
        MESSAGE "The guard is here."
```

`MOVE` on a flag other than 38 walks any object through the map using the
`/CON` table, which is why the verb is set and restored around it.

## Containers

```
> PUT   _     PREP IN
              NOUN2 CHEST
              PRESENT oChest
              NOTZERO fChestOpen
              AUTOP 3             ; 3 = the chest's object number and its location
              DONE
> GET   _     PRESENT oChest
              NOTZERO fChestOpen
              AUTOT 3             ; tries the chest first, then here
              DONE
> GET   _     AUTOG               ; the generic entry stays below
              DONE
> EXAMI CHEST NOTZERO fChestOpen
              MES "Inside the chest you see: "
              LISTAT 3
              DONE
```

## Score and turns

```
> SCORE _     MES "You have scored "
              PRINT fScore
              MES " points in "
              DPRINT fTurns
              MESSAGE " turns."
              DONE
```

Award points once by guarding with a flag:

```
> _ _   ZERO fGotKeyScore          ; process 4, or in the GET entry itself
        CARRIED oKey
        SET  fGotKeyScore
        PLUS fScore 10
```

## Winning and dying

```
> LIGHT LAMP  AT lLampRoom
              CARRIED oMatches
              MESSAGE "The great lamp blazes out across the bay. Ships will be safe tonight."
              END
```

`END` prints SM13 (play again?) and either restarts or leaves. For a
narrower "restart" without the question, `EXIT 1`.

## Save, load, quit (already in STARTER)

`SAVE 0`, `LOAD 0`, `RAMSAVE` and `RAMLOAD 255` are each followed by
`CLS` and `RESTART`. `QUIT` is a condition; STARTER's second `> Q _ DONE`
entry catches the "no" answer.

## Talking to characters

```
> SAY   _     PARSE 1               ; re-parse the quoted text
              PROCESS 8             ; a table keyed on the quoted words
              ISDONE
              DONE
> SAY   _     MESSAGE "Nobody answers."
              DONE
```

Player types `SAY "HELLO"` or `KEEPER, HELLO`; process 8 has entries
like `> HELLO _ AT lCottage PRESENT oKeeper MESSAGE "..." DONE`.

## Sub-tables and REDO

Long verbs are easier to read as their own process:

```
> LOOK  _     PROCESS 9        ; LOOK AT things
              ISDONE
              DONE
```

Inside process 9, entries end with `DONE` when they handled it. If none
matched, `ISDONE` fails, the outer entry falls through, and a later
`> LOOK _ CLS RESTART` redescribes the room.
