# Limits

## DDB size: the 64K ceiling

Your whole compiled database - vocabulary, messages, objects, locations,
connections, processes, everything DRC writes into `GAME.DDB` - must fit
in 65535 bytes. NextDAAD refuses a larger one at boot with
`NextDAAD: DDB oversize - E2`.

The number is a property of the format rather than a budget someone
chose: a DDB pointer is 16 bits, so 65536 is every distinct position one
can name. Nothing beyond that could be reached even if it loaded.

**This used to be 31744 bytes.** Databases for the classic ZX targets
carry pointers counted from $8400, the address a Spectrum loads them at,
which leaves only the 31744 bytes between there and the top of a 64K
address space. NextDAAD compiles for its own target instead, whose
pointers are plain offsets into the file, so the whole 64K is usable.
See [Getting started](../getting-started.md) for what that means for
which tools you install.

The relief valve is XMESSAGE, below: moving text out of the DDB and into
`0.XMB` frees the same bytes inside the 64K budget, at the cost of the
separate external-text budget instead. A game approaching the ceiling
should move its largest or least-frequently-seen text (long room
descriptions, help text, endgame text) to XMESSAGE first.

## XMESSAGE / XMES

XMESSAGE (adds a trailing newline) and XMES (does not) print text
stored externally in `0.XMB`, a file DRC writes during compilation
whenever your DSF uses either condact (staged into `RELEASE\`
automatically - see below). Two limits to know:

- **No per-call length limit on this target.** The DAAD manual gives
  511 characters per call. That figure belongs to the +3 and 128K
  interpreters, which swap each message through a 512-byte buffer, and
  the compiler applies it only when you build for one of those targets.
  Building for the Next, a single call is bounded only by the 64K total
  below. Keep to 511 anyway if the same source may also be built for a
  +3 or 128K release. For readability rather than for any limit, long
  passages still read better chained - use XMES (no added newline) for
  the earlier calls so the text runs as one continuous block, and
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

## GAME.XBN

An [extern](../externs.md) binary is capped at **16384 bytes (16K)**,
header included - a size larger than that on disk is rejected at boot
and the game plays with externs off. **One `GAME.XBN` per game**: there
is no per-part extern file, and the same binary stays loaded across
every part switch. A single `SVC_GETMSG` call is capped at **256
bytes**; a longer database message is truncated, not rejected, and the
returned length always matches what actually landed in the buffer. See
[XBN format](xbn-format.md) for the full header and validation rules.
