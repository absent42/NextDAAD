# Limits

## DDB size: the 31744-byte ceiling

The DDB format DRC compiles for this target (the classic ZX addressing
scheme) uses 16-bit pointers based at $8400, the classic ZX DAAD load
address. That caps the whole compiled DDB - vocabulary, messages,
objects, locations, connections, processes, everything DRC writes into
`GAME.DDB` - at 31744 bytes ($8400 to $FFFF). This is a DRC/compiler
format ceiling, not a NextDAAD interpreter limit (the interpreter
itself accepts a DDB up to 128K), but it is the ceiling a growing game
actually reaches first.

The relief valve is XMESSAGE, below: moving text out of the DDB and
into `0.XMB` frees the same bytes inside the 31744-byte budget, at the
cost of the separate external-text budget instead. A game approaching
the ceiling should move its largest or least-frequently-seen text
(long room descriptions, help text, endgame text) to XMESSAGE first.

## XMESSAGE / XMES

XMESSAGE (adds a trailing newline) and XMES (does not) print text
stored externally in `0.XMB`, a file DRC writes during compilation
whenever your DSF uses either condact (staged into `RELEASE\`
automatically - see below). Two limits to know:

- **511 characters per call, practical limit.** A single XMESSAGE/XMES
  call is not meant to hold a full page of text. For longer passages,
  chain several calls back to back - use XMES (no added newline) for
  the earlier calls so the text reads as one continuous block, and
  XMESSAGE (or a trailing newline token) only for the last one.
- **64K total, compiled.** `0.XMB` holds the compiled (token-compressed)
  bytes of every XMESSAGE/XMES call in your whole game, back to back,
  with no gap or padding between entries on this target. That 64K is a
  budget shared across the WHOLE game, not per call - a game that
  leans heavily on XMESSAGE should watch its total external-text
  volume, not just individual message length.

`0.XMB` is staged into `RELEASE\` automatically, right after `GAME.DDB`,
whenever your DSF uses XMESSAGE or XMES. DRC writes the file during the
DDB compile step into the DAAD-READY tool folder
(`%TOOLSDIR%\DAAD-READY\0.XMB`); the kit copies it from there to
`RELEASE\0.XMB`, where it must sit alongside `GAME.DDB` on the SD card -
without it, XMESSAGE/XMES would silently no-op at runtime rather than
failing loudly. A DSF with no XMESSAGE/XMES calls produces no `0.XMB`,
and the build stages none.
