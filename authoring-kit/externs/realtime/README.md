# realtime

Wall-clock date and time from the Next's real-time clock, and a two-byte day
stamp on the card so a game can tell how many days have passed since the
player last played. Everything runs inside the `EXTERN` that calls it: there
is no frame hook and no arming call.

The date and time are taken as one snapshot and then served a field at a time
into flag 238, so an ordinary DSF condition can test the hour, the weekday or
the month. One snapshot also means the hour and the minute you test in the
same turn cannot come from either side of a tick.

## EXTERN codes

- `EXTERN 0 66` - refresh the snapshot from the RTC. A CONDITION: CF clear and
  the entry continues on success; CF set and the entry FAILS when there is no
  RTC or the reading is invalid. Flag 239 carries the same verdict for testing
  later in the turn: 1 = snapshot taken, 0 = no reading. A failed refresh
  leaves the previous snapshot as it was.
- `EXTERN f 67` - copy field f of the snapshot into flag 238. An ACTION: it
  cannot fail, so CF is always clear and the entry always continues. The
  fields are 0 second, 1 minute, 2 hour, 3 day of the month, 4 month, 5 year,
  6 weekday. A field above 6, or any call before a successful `EXTERN 0 66`,
  writes flag 238 = 0.
- `EXTERN 0 68` - stamp today's date into `GAME.HST` beside your `GAME.DDB`,
  two bytes. A CONDITION: CF set if there is no RTC, or the file could not be
  created or written.
- `EXTERN 0 69` - the number of days from that stamp to today, into flag 238.
  A CONDITION: CF set if there is no RTC, or there is no readable stamp file;
  flag 238 is left alone on those paths.

fns 68 and 69 read the clock for themselves, so neither needs `EXTERN 0 66`
first. The snapshot serves fn 67 only.

## Flags

- 238 - the answer: fn 67's field, or fn 69's day count. Nothing else writes
  it, so read it in the same entry that produced it if another call follows.
- 239 - fn 66's availability verdict, 1 or 0. fns 68 and 69 do not touch it.

## With no RTC

A card or a machine with no working clock is the normal failure, not an error:
`EXTERN 0 66` fails its entry and sets flag 239 = 0, and `EXTERN f 67` then
writes flag 238 = 0 for every field, because there is no snapshot to serve.
fns 68 and 69 fail their entries the same way. Write the game so the
date-dependent path hangs off a successful fn 66 (or a test of flag 239) and
the game plays normally without one.

## Fields

Field 5, the year, is a 2000-2099 offset: 2026 reads 26. The packed date the
clock returns starts in 1980, so a clock still reading 1980-1999 clamps this
field to 0 rather than wrapping into a misleading year.

Field 6 is the weekday, 0 Sunday through 6 Saturday. It is computed from the
date rather than read from the clock: the module counts days since 1980-01-01,

    days = 365*Y + ((Y+3) >> 2) + (days before the month) + leap + (D-1)

with Y the years since 1980, D the day of the month, and leap = 1 in a leap
year from March onwards. The weekday is `(days + 2) mod 7`, since 1980-01-01
was a Tuesday. That same day count is what fn 69 differences, so both answers
come from one routine. Dates from 1980-01-01 to 2099-12-31 are exact - every
fourth year in that span is a leap year, 2000 included.

## The day stamp

`GAME.HST` is two bytes, the packed date, written beside your game on the
card. fn 68 creates or overwrites it; fn 69 reads it and reports the
difference:

    EXTERN 0 69    ; days since the stamp, into flag 238
    ...
    EXTERN 0 68    ; stamp today, so the next session counts from here

A clock set back to before the stamp reads 0, and more than 255 days reads
255, since the flag is a byte. With no `GAME.HST` at all fn 69 FAILS rather
than reporting 0 - that is the difference between "has never played" and
"played today", and it is the entry's condition, not a flag value.

## Worked example

Greet the player by time of day, but only when the clock answered:

    > _  _    EXTERN 0 66      ; the entry fails if there is no RTC
              EXTERN 2 67      ; hour into flag 238
              LT   238 12
              MES  10          ; "Good morning."
              DONE

A weekend-only event is the same shape with field 6:

    > _  _    EXTERN 0 66
              EXTERN 6 67      ; weekday into flag 238
              EQ   238 0       ; 0 Sunday
              ...

## Real time and flag 48

A flag that changes while the player sits at the prompt is invisible until a
turn runs, so a wall-clock event only fires when the player happens to type.
DAAD's input timeout is the other half of real time: flag 48 arms it, in
seconds, and flag 49 bit 7 reports that it fired. With flag 48 armed a turn
happens on a timer, your process table runs, and the events you hang off this
module fire while the player is still thinking. The manual's externs chapter
(`manual/externs.md`) covers the pairing.

## Notes

The date service is part of XBN API 2, so this module needs an interpreter of
that version or later. It never writes the clock, only reads it, and it holds
no state across a `LOAD` or a `RESTART` beyond the snapshot itself - the day
stamp lives on the card, so it survives both, and a save file carries only
whatever your own flags copied out of flag 238.
