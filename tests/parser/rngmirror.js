// Mirror of NextDAAD's rng_next (src/overlay0.asm), so the jDAAD leg draws
// the identical random stream to the Z80 interpreter. See tests/parser/rng.py
// for the transcription of the assembly. Kept in lockstep by the
// t4_rng_js_mirror_matches_python selftest case.
//
// SP16 Task 5: the Z80 routine became a real 16-bit xorshift
// (x ^= x<<7; x ^= x>>9; x ^= x<<8, period 65535) with a full-state
// scale to 1..100; this mirror moved with it in the same change.
'use strict';

// One xorshift state advance. In/out: 16-bit state.
function step(x) {
  x ^= (x << 7) & 0xFFFF;
  x ^= x >> 9;
  x ^= (x << 8) & 0xFFFF;
  return x & 0xFFFF;
}

// Scale a 16-bit state to 1..100 - the Z80's two MUL D,E, i.e.
// A = (x * 100) >> 16, then +1.
function scaleTo1_100(x) {
  return Math.floor((x * 100) / 65536) + 1;
}

function makeRng(seed = 0xA5C3) {
  let state = seed & 0xFFFF;
  return {
    next() {
      state = step(state);
      return scaleTo1_100(state);
    },
    state() { return state; },
  };
}

module.exports = { makeRng, step, scaleTo1_100 };
