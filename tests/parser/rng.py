"""Python reference of NextDAAD's rng_next (src/overlay0.asm).

Transcribed from the Z80 (SP16 Task 5 - the xorshift replacement; the
old rotate-based routine and its mod-200/mod-100 reduction are gone,
see docs/parser-bugs.md entry 3):

    ld hl,(rngState)
    ; x ^= x << 7
    ld d,h : ld e,l
    xor a : srl h : rr l : rra : ld h,l : ld l,a
    ld a,h : xor d : ld h,a
    ld a,l : xor e : ld l,a
    ; x ^= x >> 9        (high byte of x>>9 is always 0)
    ld a,h : srl a : xor l : ld l,a
    ; x ^= x << 8        (low byte of x<<8 is always 0)
    ld a,h : xor l : ld h,a
    ld (rngState),hl
    ; A = (x * 100) >> 16, +1
    ld d,100 : ld e,h : mul d,e : ld b,d : ld c,e
    ld d,100 : ld e,l : mul d,e
    ld a,d : add a,c : ld a,b : adc a,0
    inc a                      ; result is 1..100

These are SHIFTS, not rotates. Period is 65535 - the orbit is every
non-zero 16-bit state exactly once. Output scaling uses the whole
16-bit state so each of the 100 outcomes gets 655 or 656 states per
period; CHANCE 50 measures 50.00% over a full period.

This mirror exists so the jDAAD leg (tests/parser/rngmirror.js) and the
Z80 draw the SAME stream from the same pinned seed. Faithfulness to the
Z80 beats elegance here: if src/overlay0.asm's rng_next changes, this
file, rngmirror.js and the t4_rng_* selftest pins must change in the
SAME commit.
"""


def step(x):
    """One xorshift state advance. In/out: 16-bit state."""
    x ^= (x << 7) & 0xFFFF
    x ^= x >> 9
    x ^= (x << 8) & 0xFFFF
    return x & 0xFFFF


def scale_to_1_100(x):
    """Scale a 16-bit state to 1..100, per the Z80's two MUL D,E.

    A = (x * 100) >> 16, then +1. Exactly the integer arithmetic the
    Z80 performs; called separately so the scaling can be tested on its
    own domain.
    """
    return ((x * 100) >> 16) + 1


class RNG:
    def __init__(self, seed=0xA5C3):
        self.state = seed & 0xFFFF

    def next(self):
        self.state = step(self.state)
        return scale_to_1_100(self.state)
