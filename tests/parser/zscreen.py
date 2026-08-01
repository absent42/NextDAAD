"""Read text off an ORIGINAL DAAD ZX screen by decoding the ULA bitmap.

Promoted verbatim (algorithm unchanged) from the SP16 adjudication rig,
.superpowers/sdd/sp16-adjudications/zxadj_run.py, which used it to settle
five register entries against the original interpreter. Kept as a pure,
emulator-free module so it can be unit-tested against a saved screen dump
- see parser_selftest.py's z-cases.

WHY THIS EXISTS AT ALL. ZEsarUX's own `get-ocr` returns the EMPTY STRING
on every frame of a running DAAD ZX game. That is measured, not assumed:
SP16 Task 5 polled it twelve consecutive times against a game that was
demonstrably alive and got nothing back every time (task-5-report.md
section 5; also recorded in docs/hardware-test-checklist.md). ZEsarUX's
OCR is built around the ZX ROM's 8-pixel-wide charset, and DAAD installs
AD8x6.CHR - 6 pixels wide, 42 columns per line - whose glyph columns do
not line up with the ULA's 8-pixel character cells at all. So there is no
OCR path to fall back on; the bitmap has to be decoded directly.

Three things the decoder has to get right, all of them load-bearing:

  1. DE-INTERLEAVE. The ZX display file is not linear. Address bits split
     into third (2 bits), pixel line within a character row (3 bits) and
     character row (3 bits), so consecutive addresses are eight pixel rows
     apart. screen_bits() undoes that into 192 straight scanlines.

  2. SIX-PIXEL COLUMNS. Each AD8x6.CHR glyph is stored as 8 bytes, but
     only the TOP SIX BITS of each byte are the glyph; the low two bits
     are padding. Columns therefore start every 6 pixels, not every 8,
     and glyph N starts at pixel 6*N with no relation to the byte
     boundaries the screen is stored in.

  3. VERTICAL PHASE. The interpreter scrolls its text window by PIXEL
     rows, not character rows, so a capture taken mid-game can have its
     text sitting at any of eight vertical offsets. decode() tries all
     eight and keeps the one that decodes cleanest (fewest unmatched
     cells, tie-broken towards the phase that finds the most ink). Skip
     the phase search and a scrolled screen decodes to solid '?'.

The glyph table is keyed on the 8-row 6-bit tuple and built with
setdefault, so when two character codes share a bitmap the LOWER code
wins - deterministic, and it keeps space (32) ahead of any other blank
glyph a charset may carry.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CHARSET = (ROOT / "tools" / "DAAD-READY" / "ASSETS" / "CHARSET"
                   / "AD8x6.CHR")

# DAAD's ZX text window: 42 columns of 6 pixels across a 256-pixel screen.
COLS = 42
# ULA display file: 6144 bitmap bytes at 0x4000, then 768 attribute bytes.
SCREEN_ADDR = 0x4000
BITMAP_BYTES = 6144
PHASES = 8
# The character the DAAD ZX line editor draws at the caret. Drawn into
# the BITMAP, so it shows up in a decode; it does not blink there,
# because the ULA's FLASH bit lives in the attribute file which this
# decoder never reads. zleg uses it as its positive "editor is waiting
# for a line" signal - see zleg.has_cursor.
CURSOR = "_"


def load_font(path=None):
    """Build the glyph -> character table from a DAAD .CHR charset.

    Codes 32..127 only: a DAAD charset file is 8 bytes per code from code
    0, but codes below 32 are control/graphics slots that never appear as
    text and would only add spurious matches.
    """
    data = Path(path or DEFAULT_CHARSET).read_bytes()
    table = {}
    for code in range(32, 128):
        glyph = data[code * 8:code * 8 + 8]
        if len(glyph) < 8:
            break
        table.setdefault(tuple((b >> 2) & 0x3F for b in glyph), chr(code))
    return table


def resolve_charset(game_path=None, explicit=None):
    """Pick the charset to decode with: the game's own if it ships one.

    Order, most specific first:
      1. `explicit` - whatever the caller passed on the command line.
      2. a .CHR sitting in the same directory as the game source/TAP.
         daadmaker takes the charset as an argument, so a game that ships
         its own font has it beside its source; decoding that game with
         the stock font would mis-read every glyph it redefined. AD8x6.CHR
         is preferred among several only because that is the name the DRC
         chain uses by default; otherwise the first in sorted order, so
         the choice is at least deterministic and reported by the caller.
      3. the stock tools/DAAD-READY/ASSETS/CHARSET/AD8x6.CHR.
    """
    if explicit:
        return Path(explicit)
    if game_path:
        d = Path(game_path).resolve().parent
        chrs = sorted(p for p in d.glob("*") if p.suffix.upper() == ".CHR")
        if chrs:
            for p in chrs:
                if p.name.upper() == "AD8X6.CHR":
                    return p
            return chrs[0]
    return DEFAULT_CHARSET


def screen_bits(px):
    """De-interleave 6144 display-file bytes into 192 scanline integers.

    Each returned integer holds one 256-pixel scanline, leftmost pixel in
    the most significant bit position (bit 255).
    """
    if len(px) != BITMAP_BYTES:
        raise ValueError("screen_bits wants %d display-file bytes, got %d"
                         % (BITMAP_BYTES, len(px)))
    rows = [0] * 192
    for addr in range(BITMAP_BYTES):
        third = (addr >> 11) & 0x03
        line = (addr >> 8) & 0x07
        charrow = (addr >> 5) & 0x07
        x = addr & 0x1F
        rows[third * 64 + charrow * 8 + line] |= px[addr] << ((31 - x) * 8)
    return rows


def decode_at(bits, table, dy):
    """Decode every full 8-pixel text row starting at scanline `dy`."""
    out = []
    for r in range((192 - dy) // 8):
        line = []
        for c in range(COLS):
            x0 = c * 6
            cell = tuple((bits[dy + r * 8 + i] >> (256 - x0 - 6)) & 0x3F
                         for i in range(8))
            line.append(' ' if cell == (0,) * 8 else table.get(cell, '?'))
        out.append(''.join(line).rstrip())
    return out


def phase_score(lines):
    """Lower is better: fewest unmatched cells, then most ink.

    Unmatched cells dominate because a wrong phase slices glyphs in half
    and matches almost nothing; the ink tie-break then picks the phase
    that actually found text over one that found a blank band.
    """
    text = ''.join(lines)
    return (text.count('?'), -sum(1 for ch in text if ch != ' '))


def decode(px, table, keep_blank=False):
    """Decode a display-file capture to text lines, best phase wins.

    Blank lines are dropped by default: the interpreter's text window
    sits at an arbitrary pixel offset inside a screen that is mostly
    empty, so the blank rows carry no information and their COUNT changes
    with the phase, which would make two otherwise identical captures
    compare unequal.
    """
    bits = screen_bits(px)
    best = best_score = None
    for dy in range(PHASES):
        lines = decode_at(bits, table, dy)
        score = phase_score(lines)
        if best_score is None or score < best_score:
            best, best_score = lines, score
    if keep_blank:
        return best
    return [l for l in best if l.strip()]


def scroll_shift(prev, cur):
    """Smallest s >= 0 with a NON-EMPTY prev[s:] as a prefix of cur.

    The ZX text window scrolls: after a turn, `cur` is usually `prev`
    with its first s lines gone and new lines appended. Finding s tells
    the caller exactly which lines are new. None means no shift explains
    the transition - a window clear, a full redraw, or a scroll so long
    that nothing of `prev` is left to anchor on - and the caller must
    treat the whole screen as new text AND say the capture is a redraw.

    The search deliberately stops BEFORE s == len(prev). That case
    matches every possible `cur` (an empty tail is a prefix of anything),
    so including it made this function total, made None unreachable, and
    made every redraw silently report as a clean scroll. The emitted
    lines were right either way - all of `cur` is new in both readings -
    but the caveat that says "no overlap, this capture may be showing you
    older text" was never raised. Found by parser_selftest's
    zb4_new_text_reports_scrolls_and_redraws.

    An empty `prev` is the one honest zero-overlap case: a first capture
    has nothing to anchor to and everything on it is new, with no
    ambiguity to flag.
    """
    if not prev:
        return 0
    for s in range(len(prev)):
        tail = prev[s:]
        if cur[:len(tail)] == tail:
            return s
    return None


def new_text(prev, cur):
    """(lines that are new in `cur`, redraw_flag).

    redraw_flag is True when no scroll explains the transition, i.e. the
    lines returned are the WHOLE screen and some of them may be older
    text that merely survived a clear. It is the ZX leg's equivalent of
    tilemap.transition()'s `ambiguous`: not a failure, a caveat the
    reader needs in order to judge a text difference on that turn.
    """
    s = scroll_shift(prev, cur)
    if s is None:
        return list(cur), True
    return list(cur[len(prev) - s:]), False
