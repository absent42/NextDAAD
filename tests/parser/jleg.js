// tests/parser/jleg.js - headless jDAAD harness: the REFERENCE leg.
//
// Descends from D:\dracula\build\play.js (read-only reference from another
// project - not modified). Loads jDAAD in a `vm` sandbox behind DOM stubs
// and a jQuery shim, feeds it a scripted list of commands, and emits one
// jsonl line per turn with the schema tests/parser/compare.py expects:
// {turn, command, text, flags, objloc, frame}. frame is always 0 here -
// only the NextDAAD leg has a real frame counter.
//
// Usage: node jleg.js <workdir> <script.json> <out.jsonl>
//
// workdir must already contain (via prepare.prepare_from_dsf, which stages
// this): daad.jddb, jdaad.js, images.js, extern.js.
//
// Script entry forms - each is a LOGICAL instruction; each leg (this file
// and nleg.py) realises it the way its own input model requires:
//   "COMMAND"  a normal command line: typed with echo suppressed, then
//              Enter (echoed), then settled.
//   "!X"       raw keys with NO Enter - for prompts the line reader never
//              sees (e.g. an ANYKEY-style "Press any key" pause).
//   "?X"       answer a confirmation prompt (e.g. QUIT's "Are you
//              sure?") with X. Sends X and then Enter, i.e. the same
//              thing a plain command does; kept as its own spelling so a
//              script says out loud that the turn answers a
//              confirmation. It used to differ per leg: NextDAAD's
//              `confirm` (src/overlay0.asm) took ONE raw keypress while
//              jDAAD's _QUIT calls getPlayerOrders(), the same full-line
//              reader its main loop uses, so nleg.py sent the key alone
//              and this leg sent key+Enter. SP16 Task 5 settled
//              docs/parser-bugs.md entry 4 against the ORIGINAL ZX
//              interpreter (.superpowers/sdd/sp16-adjudications/): a
//              bare Y at the SM12 prompt is echoed into a line and
//              nothing acts until ENTER. NextDAAD was the outlier, it
//              now reads a line, and both legs are driven identically.
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const { makeRng } = require('./rngmirror.js');

const DIR = path.resolve(process.argv[2]);
const scriptPath = process.argv[3];
const outPath = process.argv[4];
const commands = JSON.parse(fs.readFileSync(scriptPath, 'utf8'));

let out = '';
const handlers = {};

function makeCtx2d() {
  return {
    canvas: { width: 320, height: 200, getBoundingClientRect: () => ({ left: 0, top: 0, width: 320, height: 200 }) },
    fillStyle: '', font: '', textBaseline: '',
    fillRect() {}, clearRect() {}, drawImage() {}, fillText() {}, save() {}, restore() {},
    scale() {}, translate() {}, putImageData() {},
    getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(4 * Math.max(1, w) * Math.max(1, h)) }),
    createImageData: (w, h) => ({ data: new Uint8ClampedArray(4 * Math.max(1, w) * Math.max(1, h)) }),
  };
}
function makeEl(id) {
  return {
    id, style: {}, innerHTML: '', value: '',
    classList: { add() {}, remove() {}, contains: () => false },
    focus() {}, blur() {}, appendChild() {}, removeChild() {}, setAttribute() {},
    addEventListener() {}, getContext: () => makeCtx2d(),
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 320, height: 200 }),
  };
}

const EVENTS = new Set(['ready', 'keydown', 'keyup', 'click', 'mousedown', 'mouseup', 'mousemove', 'resize']);
function $(sel) {
  const api = {};
  const chain = () => api;
  for (const n of ['css', 'show', 'hide', 'attr', 'addClass', 'removeClass', 'html', 'text', 'on', 'off', 'focus', 'append'])
    api[n] = chain;
  for (const ev of EVENTS) api[ev] = (fn) => { if (typeof fn === 'function') handlers[ev] = fn; return api; };
  return api;
}
$.each = (o, f) => { for (const k in o) f(k, o[k]); };

const documentStub = {
  getElementById: makeEl, createElement: makeEl, querySelector: makeEl, querySelectorAll: () => [],
  getElementsByClassName: (c) => [makeEl(c)], getElementsByTagName: (t) => [makeEl(t)],
  documentElement: {}, body: makeEl('body'), addEventListener() {}, cookie: '',
};
const store = {};
const localStorageStub = {
  getItem: (k) => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: (k) => { delete store[k]; },
};

const quietConsole = { log() {}, warn() {}, info() {}, debug() {}, error: (...a) => console.error(...a) };
const sandbox = {
  console: quietConsole, document: documentStub, localStorage: localStorageStub,
  navigator: { userAgent: 'node', language: 'en' },
  location: { href: '', search: '' },
  setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0, clearInterval: () => {},
  requestAnimationFrame: () => 0,
  Audio: function () { return { play() {}, pause() {}, addEventListener() {} }; },
  Image: function () { return { addEventListener() {}, set src(v) {} }; },
  // Known, deliberately left alone: jdaad.js's Sound() (reached via the BEEP
  // condact) calls basedelay(seconds), which busy-waits on a real
  // Date.now() loop for the tone's duration - it is not routed through
  // setTimeout, so the stub above does not touch it. This never touches
  // captured text or state (BEEP produces no output this harness records),
  // so it is not a correctness bug - but a BEEP-heavy fixture will make the
  // harness genuinely pause for real wall-clock seconds, once per beep.
  // Not stubbed here because Sound()/basedelay() are ordinary jdaad.js
  // functions (not sandbox globals) - patching them would mean reaching
  // into jdaad.js's internals same as the condactTable fix below, which is
  // more invasive than this harness currently needs. Revisit if a fixture
  // ever makes this slow enough to matter.
  AudioContext: function () {
    return {
      destination: {},
      createOscillator() {
        return { type: '', frequency: { value: 0 }, connect() {}, start() {}, stop() {} };
      },
    };
  },
  alert: () => {}, $, jQuery: $,
  Uint8Array, Uint8ClampedArray, Date, JSON, parseInt, parseFloat, String, Number, Array, Object, Boolean, isNaN,
};

// The rng_next mirror. RANDOM (95) and CHANCE (10) must draw the SAME stream
// as the Z80, so __rng100 is exposed into the sandbox and the two condact
// handlers are patched below to call it instead of Math.random. See
// tests/parser/rngmirror.js and tests/parser/rng.py for the transcription.
const rng = makeRng(0xA5C3);
sandbox.__rng100 = () => rng.next();

// jdaad.js reads the character bitmap out of a global `font` array (normally
// supplied by font.js, generated alongside the game's DDB). This harness
// never draws pixels - writeChar is patched below to tee characters into
// __out and pixel()/pixelRGB() are stubbed to no-ops - so the font's actual
// content is irrelevant; it only needs to exist so the lookup does not throw.
sandbox.font = new Array(256 * 8).fill(0);

// jdaad.js's _PICTURE() (condact 84) falls through to a global `jDAADSounds`
// array whenever the `images` slot for the requested picture number is null
// - which is every slot, since prepare.py stages DAAD-READY's generic
// images.js stub (`images[i] = null` for all 256 i; no game ships real
// picture assets through this harness). In a real jDAAD deployment
// jDAADSounds is a THIRD staged file (sounds.js, built by the separate
// jDAADImager/jDAADMultimedia.php tool - see its output at
// tools/DAAD-READY/TOOLS/jDAADImager/jDAADMultimedia.php: `var jDAADSounds =
// [...]`) that prepare.py never stages, because this harness ships no real
// sound assets either. Without this stub, any game that calls PICTURE
// (Rabenstein does, during boot) throws `ReferenceError: jDAADSounds is not
// defined` and the whole jDAAD leg crashes before turn 0.
//
// Fixed the same way as images.js: a 256-null array, not an empty one.
// jDAADSounds[Parameter1] must come back exactly `null` (not `undefined`)
// for every slot, matching the pattern _PICTURE checks with `!== null` - an
// empty array would make jDAADSounds[Parameter1] read back `undefined`,
// which also satisfies `!== null` and would make PICTURE wrongly report
// condactResult = true (a real, harness-caused state divergence) for a game
// that has no sound assets, instead of correctly reporting false. PlaySound
// (jdaad.js) later calls jDAADSounds.indexOf(sfxno) on this same array; an
// all-null 256-slot array is inert there too (indexOf always returns -1, so
// PlaySound's Audio() call is never reached).
sandbox.jDAADSounds = new Array(256).fill(null);

sandbox.window = sandbox;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

function load(f) {
  const p = path.join(DIR, f);
  if (!fs.existsSync(p)) return;
  vm.runInContext(fs.readFileSync(p, 'utf8'), sandbox, { filename: f });
}

// Order matters: the DDB and the font are plain data scripts.
for (const f of ['daad.jddb', 'images.js', 'font.js', 'jdaad.js']) load(f);

// --- capture text instead of drawing pixels -------------------------------
// Keep the real routines so all the wrap / pager / cursor bookkeeping still
// runs; only suppress the pixel pushing and tee the characters into __out.
vm.runInContext(`
  var __origWC = writeChar, __origCR = carriageReturn, __origCW = clearCurrentWindow;
  var __inWC = false;
  // True only while readText() is drawing the input line. jDAAD's text
  // cursor is a literal '_' GLYPH appended to the prompt
  // (jdaad.js readText: writeText(readTextStr + '_')), so without this it
  // is teed into the capture and every single turn ends '>_' while the
  // Next leg ends '>'. NextDAAD's cursor is not a glyph at all - it is an
  // ATTRIBUTE inversion of the cell under it (src/overlay1.asm
  // inp_cursor_put renders the char already there with the inverted
  // pair), and tilemap.decode reads glyphs, not attributes, so the Next
  // leg can never produce a matching character. The two interpreters are
  // NOT disagreeing here; only the two capture models are, so the marker
  // is dropped from the reference capture rather than faked on the Next
  // side. Scoped to readText so a '_' printed by the GAME (message text,
  // an object name) is still captured and still compared.
  //
  // DEPTH COUNTER, not a boolean: if readText ever re-enters (directly,
  // or via anything it calls that reaches the input line again), a
  // boolean would be cleared by the INNER call's exit and leave the
  // outer draw's cursor teed into the capture. Zero means "not drawing
  // the input line"; anything above zero means at least one draw is in
  // progress.
  var __cursorDraw = 0;
  // Only the LAST glyph of an input-line draw is the cursor - the string
  // is (readTextStr + '_'), so every underscore before it belongs to the
  // player's own typed text. Suppressing all of them (which this used to
  // do) silently ate an underscore the user typed. Instead they are HELD
  // here and released the moment any other character follows, so exactly
  // one trailing underscore per draw is ever dropped.
  var __pendingUnderscores = 0;
  function __flushUnderscores() {
    while (__pendingUnderscores > 0) { __pendingUnderscores--; __out('_'); }
  }
  pixel = function () {};
  pixelRGB = function () {};
  writeChar = function (c) {
    var top = !__inWC; __inWC = true;
    if (top && c >= 32 && c < 256) {
      if (__cursorDraw && c === 95) {
        __pendingUnderscores++;         // might be the cursor - decide later
      } else {
        __flushUnderscores();           // something followed: they were text
        __out(String.fromCharCode(c));
      }
    }
    try { return __origWC.call(this, c); } finally { if (top) __inWC = false; }
  };
  // Both flush first: anything held back that is followed by a newline
  // or a clear was not the trailing cursor, and must not be reordered
  // after the thing that followed it. (The cursor itself cannot reach
  // these - a wrap emits its newline BEFORE the overflowing character,
  // never after the last one.)
  carriageReturn = function () { __flushUnderscores(); __out('\\n'); return __origCR.apply(this, arguments); };
  clearCurrentWindow = function () { __flushUnderscores(); __out('\\n---[CLS]---\\n'); return __origCW.apply(this, arguments); };

  // readText() is jdaad.js's input-line draw (called from
  // getPlayerOrders, and from _QUIT via the same path). It is called by
  // its global name at the one call site (jdaad.js:1209), so reassigning
  // the global here does reach it - unlike condactTable's entries below,
  // which captured their handler by value at load time and need the table
  // itself repointed. Everything the original prints is still captured;
  // only the trailing cursor glyph is suppressed - see __cursorDraw.
  var __origRT = readText;
  readText = function () {
    __cursorDraw++;
    try {
      return __origRT.apply(this, arguments);
    } finally {
      __cursorDraw--;
      if (__cursorDraw === 0) {
        // The outermost draw is done, so whatever is still held back is
        // this line's trailing run. Exactly ONE of them is the cursor
        // glyph; the rest were typed and must still be captured.
        if (__pendingUnderscores > 0) __pendingUnderscores--;
        __flushUnderscores();
      }
    }
  };

  // RANDOM (95) and CHANCE (10) must draw the SAME stream as the Z80
  // rng_next, which has exactly two callers: h_random and h_chance.
  // Overriding Math.random alone is NOT sufficient - jDAAD scales a 0..1
  // float, which does not reproduce rng_next's modulo-100 reduction.
  _RANDOM = function () { flags.setFlag(Parameter1, __rng100()); done = true; };
  _CHANCE = function () {
    condactResult = (Parameter1 > 100) ? false : (__rng100() <= Parameter1);
  };
  // condactTable is built as 'const condactTable = [{..., condactRoutine:
  // _RANDOM, ...}, ...]' at jdaad.js load time, so each entry already holds
  // the OLD function object by value - reassigning the bare _RANDOM/_CHANCE
  // globals above does not reach the dispatcher at run()'s
  // condactTable[opcode].condactRoutine() call site. The table entries
  // themselves must be repointed too, or the patch silently never fires.
  condactTable[95].condactRoutine = _RANDOM;
  condactTable[10].condactRoutine = _CHANCE;
  if (condactTable[95].condactName.trim() !== 'RANDOM' || condactTable[10].condactName.trim() !== 'CHANCE')
    throw new Error('condact table index assumption broke: ' + condactTable[95].condactName + '/' + condactTable[10].condactName);
`, sandbox);
sandbox.__mute = false;
sandbox.__out = (s) => { if (!sandbox.__mute) out += s; };

// --- boot ------------------------------------------------------------------
handlers.ready();

// --- feed the scripted commands -------------------------------------------
function key(k, echo = true) {
  if (!handlers.keydown) throw new Error('no keydown handler registered');
  if (!echo) sandbox.__mute = true;                 // don't transcribe the typed characters
  try { handlers.keydown({ key: k, preventDefault() {}, stopPropagation() {}, which: k.charCodeAt(0) }); }
  finally { sandbox.__mute = false; }
}
// Only press a key while the interpreter is actually blocked on ANYKEY or the
// "More..." pager - pressing Enter at the command prompt would burn a turn and
// advance the game's timers, corrupting the test.
const waiting = () => vm.runInContext('(typeof inANYKEY!=="undefined" && inANYKEY) || (typeof inMORE!=="undefined" && inMORE)', sandbox);
function settle(cap = 400) { let n = 0; while (waiting() && n++ < cap) key('Enter'); return n; }

function stateVector() {
  return vm.runInContext(`
    (function () {
      const f = [];
      for (let i = 0; i < 256; i++) f.push(flags.getFlag(i) & 0xFF);
      const o = [];
      const n = DDBDATA[3];
      for (let i = 0; i < n; i++) o.push(objects.getObjectLocation(i) & 0xFF);
      return { flags: f, objloc: o };
    })()
  `, sandbox);
}

// Hand the Next leg this game's own SM32 - the "More..." pager prompt.
// NextDAAD PRINTS SM32 when it pages (src/print.asm prn_more_check) and
// erases it again once the page is dismissed; jDAAD prints nothing at all
// for the same event (it only sets inMORE - grep the flag in jdaad.js:
// there is no writeText anywhere near it). So that row exists on one leg
// and can never exist on the other, and worse, whether NextDAAD's copy
// gets CAPTURED is a race: the Enter that submitted the command is still
// physically down for KEY_DELAY_MS, and if the page happens to fire
// inside that window, wait_key takes the held key as the dismissal and
// the prompt is gone before the Next leg's next poll. Same row, same
// interpreter state, present or absent depending on timing - which is
// exactly what must not reach findings.json.
//
// Read out of the DDB rather than hardcoded, because SM32's text belongs
// to the game: a fixture is free to redefine it (tests/condacts.dsf sets
// /32 "More...", another game need not).
// This is a HARD requirement, not best-effort. A silent fallback here
// would put the Next leg straight back on the flaky path - the pager
// prompt captured or not depending on timing - and nothing downstream
// could tell that apart from "this game never paged". Either meta.json
// says what the filter is, or the run does not happen. The only
// non-error way to have no prompt is a DDB that genuinely declares fewer
// than 33 system messages, and that is recorded explicitly rather than
// inferred from a missing file.
{
  const numSys = vm.runInContext('DDB.header.numSys', sandbox);
  let meta;
  // A malformed header must FAIL, not quietly become "this game has no
  // pager prompt". The old test was `!(numSys > 32)`, which is true for
  // undefined and for NaN as well as for a genuine small count, so a
  // renamed or unparsed header field routed straight into the absent
  // branch and the run continued with no filter at all - the one outcome
  // the SM32 hard-fail work existed to rule out. Same treatment as the
  // non-string sm32 read below.
  if (typeof numSys !== 'number' || !Number.isInteger(numSys) || numSys < 0)
    throw new Error('DDB.header.numSys read back as ' + typeof numSys + ' '
      + String(numSys) + ', not a non-negative integer - the header is not '
      + 'what this leg expects, and treating that as "no pager prompt" '
      + 'would silently reintroduce a nondeterministic text divergence');
  if (numSys <= 32) {
    meta = { sm32: null,
             sm32_status: 'absent: DDB declares ' + numSys + ' system messages' };
  } else {
    const sm32 = vm.runInContext(
      'getMessage(DDB.header.sysmessPos, SM32)', sandbox);
    if (typeof sm32 !== 'string')
      throw new Error('SM32 read back as ' + typeof sm32 + ', not a string - '
        + 'the Next leg cannot filter the pager prompt without it, and '
        + 'running on would silently reintroduce a nondeterministic '
        + 'text divergence');
    meta = { sm32: sm32, sm32_status: 'read from DDB' };
  }
  fs.writeFileSync(path.join(DIR, 'meta.json'), JSON.stringify(meta), 'utf8');
}

const lines = [];
function emit(turn, command, text) {
  const { flags, objloc } = stateVector();
  lines.push(JSON.stringify({ turn, command, text, flags, objloc, frame: 0 }));
}

settle();
let turn = 0;
for (const cmd of commands) {
  // fPrompt = 2 (SM2). Must not exceed the DDB's system message count or
  // NextDAAD falls through to SM33. The Next leg writes the same value, so
  // both legs take the fixed-prompt path instead of jDAAD's Math.random
  // pick among SM2-SM5 (which cannot be mirrored - NextDAAD's choice comes
  // from frameCounter AND 3, a wall-clock source unrelated to any rng).
  vm.runInContext('flags.setFlag(42, 2)', sandbox);
  // Disable the input timeout for this turn, mirroring nleg.py's identical
  // per-turn write to the Next leg (FLAG_TIME = flag 48). jdaad.js uses
  // the SAME flag index for its own timeout (FTIMEOUT = 48, confirmed at
  // jdaad.js's own const declaration), so without this write the two legs
  // ran with different timeout state: NextDAAD zeroed flag 48 every turn,
  // jDAAD left whatever condacts.dsf's own boot self-test set it to (its
  // check 58 arms it with `TIME 2 0`). That mismatch was a pure harness
  // artefact, not a real interpreter divergence - it used to show up as
  // flag 48 in every finding until this fix (see parser_selftest.py's
  // KNOWN_DIVERGENT_FLAGS, shrunk once this landed).
  vm.runInContext('flags.setFlag(48, 0)', sandbox);

  out = '';
  // "!X" sends raw keys with no Enter - for prompts the line reader never
  // sees (e.g. a genuine ANYKEY-style "Press any key" pause). NOT for
  // QUIT's "Are you sure?" - see "?X" below and this file's header
  // comment for why that specifically needs the full-line form instead.
  if (cmd.startsWith('!')) {
    for (const ch of cmd.slice(1)) key(ch);
    settle();
  } else if (cmd.startsWith('?')) {
    // "?X" answers a confirmation prompt - see header comment. Both
    // interpreters read a LINE there (entry 4, settled), so this sends
    // the key AND Enter, unlike "!", which sends no Enter. The typed
    // character's echo is suppressed, exactly as for a plain command:
    // both interpreters really do echo the reply now, but they draw
    // different cursors behind it (jDAAD writes a "_" glyph, NextDAAD
    // uses an inverted attribute the tilemap read cannot see), so
    // comparing the echo compares cursor styling. nleg.py drops its
    // own echo by anchoring after it.
    for (const ch of cmd.slice(1)) key(ch, false);  // suppress echo of the key
    key('Enter');                                   // ...but not the result
    settle();
  } else {
    for (const ch of cmd) key(ch, false);   // suppress the typed-character echo
    key('Enter');                           // ...but not the turn's output
    settle();
  }
  emit(turn, cmd, out.replace(/\n{3,}/g, '\n\n'));
  turn++;
}

fs.writeFileSync(outPath, lines.map((l) => l + '\n').join(''), 'utf8');
