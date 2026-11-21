"""Task 6 reader legs on CSpect (tests/cspect Session).

python tests/text2/drive_cspect.py TEST [...]
Tests: objverif_walk, nest4_walk, xmb_walk, xmb_mismatch_refused,
xmb_fp_refused, xmb_part_fallback, timing, f1_walks, f1_identity,
tools (print the MCP tool list). Each leg is one harness CSpect launch, closed
after the leg. Stage the legs with tests/text2/stage_legs.py reader. Walk screens
(tilemap text per step, PNG at the end of each step) go to tests/text2/reader/<LEG>/;
results.md is rewritten from all results gathered so far (results.json).
Environment: T6_NEX, T6_MAP (build\\nextdaad.nex/.map), T6_TAG, F1_BASE.
"""
import json, os, sys, time
from pathlib import Path

ROOT = str(Path(__file__).resolve().parents[2])
sys.path.insert(0, os.path.join(ROOT, 'tests'))
from cspect import Session  # noqa: E402
from cspect.session import raster_elapsed  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'reader')
NEX = os.environ.get('T6_NEX', ROOT + r'\build\nextdaad.nex')
MAP = os.environ.get('T6_MAP', ROOT + r'\build\nextdaad.map')
TAG = os.environ.get('T6_TAG', '')
LAUNCHES = os.path.join(OUT, 'launches%s.log' % TAG)
BOOT_S = 30.0           # first tilemap text after boot
SETTLE_S = 60.0         # a screen that never holds still
POLL_FRAMES = 15        # settle samples the tilemap this many NextDAAD frames apart
STILL_POLLS = 3         # identical samples in a row = settled
FROZEN_S = 3.0          # no FRAMECOUNTER tick for this long = halted
STOP_S = 15.0          # a breakpoint stop in the timing leg


class Leg:
    """One harness CSpect on sd\\<leg>, booted to the first tilemap text."""

    def __init__(self, leg, log=LAUNCHES):
        self.leg, self.log = leg, log
        self.s = Session.boot(os.path.join(ROOT, 'sd', leg), NEX, MAP)
        self._note('launch %s PID %d' % (leg, self.s.pid))
        try:
            self.s.wait_until(lambda: any(self.rows()), BOOT_S, what='tilemap text from %s' % leg)
        except BaseException:
            self.close()
            raise

    def _note(self, msg):
        if self.log:
            with open(self.log, 'a') as f:
                f.write('%s %s\n' % (time.strftime('%H:%M:%S'), msg))

    def close(self):
        pid = self.s.pid
        self.s.close()
        self._note('closed PID %d' % pid)

    def rows(self, n=32):
        return [r.rstrip() for r in self.s.rows()[:n]]

    def settle(self, more_ok=True, limit=SETTLE_S):
        """Poll the tilemap until it holds still; answer More... with SPACE."""
        s = self.s
        last, same, mores = None, 0, 0
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                s.wait_frames(POLL_FRAMES, min(FROZEN_S, max(1.0, deadline - time.monotonic())))
            except TimeoutError:
                # a boot-error screen halts with interrupts off: no frame tick, nothing can change
                r = self.rows()
                if r == self.rows():
                    return r, mores
                continue
            r = self.rows()
            if more_ok and any('More...' in x for x in r):
                s.press('SPACE')
                mores += 1
                last, same = None, 0
                s.wait_frames(2 * POLL_FRAMES, 30)
                continue
            if r == last:
                same += 1
                if same >= STILL_POLLS:
                    return r, mores
            else:
                same = 0
            last = r
        return last, mores

    def shot(self, path):
        self.s.screenshot().save(path)

    def walk(self, lines, sub):
        d = os.path.join(OUT, sub)
        os.makedirs(d, exist_ok=True)
        steps = []
        r, mo = self.settle()
        steps.append({'cmd': '(boot)', 'rows': r, 'more': mo})
        for i, cmd in enumerate(lines, 1):
            self.s.type_text(cmd + '\n')
            r, mo = self.settle()
            steps.append({'cmd': cmd, 'rows': r, 'more': mo})
            self.shot(os.path.join(d, 'step%02d.png' % i))
        json.dump(steps, open(os.path.join(d, 'screens.json'), 'w'), indent=0)
        return steps


PROMPTS = ('What now?', 'What next?', 'What should I do now?', 'What should I do next?')


def norm(rows):
    """SM2-SM5 are DAAD's random prompt (flag 42 = 0): one placeholder."""
    return ['<prompt>' if r in PROMPTS else r for r in (rows or [])]


def compare(a, b):
    diffs = []
    for i, (x, y) in enumerate(zip(a, b)):
        if norm(x['rows']) != norm(y['rows']) or x['more'] != y['more']:
            diffs.append(i)
    if len(a) != len(b):
        diffs.append('length %d vs %d' % (len(a), len(b)))
    return diffs


def walk_pair(test, leg2, leg1, lines, sub=''):
    res = {}
    for leg in (leg2, leg1):
        L = Leg(leg)
        try:
            res[leg] = L.walk(lines, leg + sub + TAG)
        finally:
            L.close()
    diffs = compare(res[leg2], res[leg1])
    mores = sum(s['more'] for s in res[leg2])
    return {'test': '%s %s vs %s' % (test, leg2, leg1),
            'expect': '%d steps, screens equal per step' % len(lines),
            'got': ('equal (%d More... prompts answered)' % mores) if not diffs
            else 'DIFFER at steps %s' % diffs,
            'result': 'PASS' if not diffs else 'FAIL',
            'evidence': 'reader/%s%s%s/, reader/%s%s%s/' % (leg2, sub, TAG, leg1, sub, TAG)}


def read_walk(name):
    return [l.strip() for l in open(name) if l.strip()]


def t_objverif():
    walk = read_walk(os.path.join(ROOT, 'tests', 'objshare', 'walk.txt'))
    return [walk_pair('objverif_walk', 'TEXT2', 'TEXT2C', walk),
            walk_pair('objverif_walk', 'TEXT2W', 'TEXT2WC', walk)]


def t_nest4():
    return [walk_pair('nest4_walk', 'TEXT2N', 'TEXT2NC', read_walk(os.path.join(HERE, 'walk_nest4.txt')))]


def t_xmb():
    return [walk_pair('xmb_walk', 'TEXT2N', 'TEXT2NC', ['READ', 'HUM', 'LOOK'], '_xmb')]


def t_mismatch():
    L = Leg('TEXT2X')
    try:
        st = L.walk(['LOOK', 'READ'], 'TEXT2X' + TAG)
        L.s.pause()
        err = L.s.read(L.s.sym('TEXT2ERR'), 1)[0]
        r = L.rows(2)
    finally:
        L.close()
    ok = st[1]['rows'] and 'NextDAAD' not in st[1]['rows'][0] and \
        r[0].startswith('NextDAAD: DDB text format - E5') and err == 8
    return [{'test': 'xmb_mismatch_refused TEXT2X', 'expect': 'LOOK plays; READ -> E5 screen, text2Err 8',
             'got': 'row0 %r text2Err %d' % (r[0], err), 'result': 'PASS' if ok else 'FAIL',
             'evidence': 'reader/TEXT2X%s/' % TAG}]


def t_fp_mismatch():
    """Card sd\\TEXT2X3: NEST4 format 2 + its own 0.XMB, "X2" kept, fingerprint XORed."""
    L = Leg('TEXT2X3')
    try:
        st = L.walk(['READ'], 'TEXT2X3' + TAG)
        L.s.pause()
        err = L.s.read(L.s.sym('TEXT2ERR'), 1)[0]
        fp = list(L.s.read(L.s.sym('TEXT2FP'), 2))
        r = L.rows(2)
    finally:
        L.close()
    hdr = open(os.path.join(ROOT, 'sd', 'TEXT2X3', '0.XMB'), 'rb').read(4)
    booted = any('NEST4' in x for x in st[0]['rows'] or []) and 'NextDAAD' not in st[0]['rows'][0]
    ok = booted and hdr[:2] == b'X2' and list(hdr[2:]) != fp and (
        r[0].startswith('NextDAAD: DDB text format - E5') and err == 8)
    return [{'test': 'xmb_fp_refused TEXT2X3', 'expect': 'boots; READ -> E5 screen, text2Err 8',
             'got': 'boot %s, XMB fp %02X%02X vs text2Fp %02X%02X, row0 %r, text2Err %d' % (
                 'seen' if booted else 'MISSING', hdr[3], hdr[2], fp[1], fp[0], r[0], err),
             'result': 'PASS' if ok else 'FAIL', 'evidence': 'reader/TEXT2X3%s/' % TAG}]


def timing_leg(leg, runs=3):
    """print_msg for STORY (MESSAGE 48): frames and raster lines, entry to return."""
    L = Leg(leg)
    out = {'leg': leg, 'runs': []}
    try:
        s = L.s
        L.settle()
        for _ in range(runs):
            s.type_text('STORY')
            s.pause()
            s.set_breakpoint('PRINT_MSG')
            s.queue_press('ENTER')
            s.resume()
            for _ in range(20):
                s.wait_until(s.stopped_at, STOP_S, what='print_msg for STORY')
                r = s.regs()
                if r['A'] == 1 and r['E'] == 48:
                    break
                s.resume()
            else:
                raise TimeoutError('print_msg never ran with A=1 E=48 for STORY')
            s.clear_breakpoint('PRINT_MSG')
            ret = int.from_bytes(s.read(r['SP'], 2), 'little')
            f0, l0 = s.frame(), s.raster_line()
            pc = s.run_to(ret, STOP_S)
            if pc != ret:
                raise RuntimeError('stopped at $%04X, not at the return $%04X' % (pc, ret))
            f1, l1 = s.frame(), s.raster_line()
            frames, rest = raster_elapsed(f0, l0, f1, l1)
            lines = frames * 311 + rest
            out['runs'].append({'ret': '$%04X' % ret, 'pc_after': '$%04X' % pc, 'frames': frames,
                                'line0': l0, 'line1': l1, 'lines': lines,
                                'ms': round(lines * 64e-3, 2)})
            s.resume()
            L.settle()
        return out
    finally:
        L.close()


def t_timing():
    r = [timing_leg('TEXT2N'), timing_leg('TEXT2NC')]
    json.dump(r, open(os.path.join(OUT, 'timing%s.json' % TAG), 'w'), indent=1)
    return [{'test': 'timing STORY (MESSAGE 48) print_msg', 'expect': 'recorded, format 2 vs format 1 (311 lines x 64 us per frame)',
             'got': '; '.join('%s %s ms' % (x['leg'], [y['ms'] for y in x['runs']]) for x in r),
             'result': 'RECORDED', 'evidence': 'reader/timing%s.json' % TAG}]


def t_part_fallback():
    """Part 1 (format 1) switches to part 2 = NEST4 format 2; no PART2 folder, so READ
    reads the root format 1 0.XMB through ext_xmes's fallback: E5, text2Err 8."""
    L = Leg('TEXT2X2')
    try:
        st = L.walk(['READ'], 'TEXT2X2' + TAG)
        L.s.pause()
        err = L.s.read(L.s.sym('TEXT2ERR'), 1)[0]
        part = L.s.read(L.s.sym('CURPART'), 1)[0]
        fmt = L.s.read(L.s.sym('TEXTFORMAT'), 1)[0]
        r = L.rows(2)
    finally:
        L.close()
    booted = any('NEST4' in x for x in st[0]['rows'] or [])
    ok = booted and r[0].startswith('NextDAAD: DDB text format - E5') and err == 8 and part == 2 and fmt == 1
    return [{'test': 'xmb_part_fallback TEXT2X2', 'expect': 'part 2 (NEST4, format 2) boots; READ -> E5, text2Err 8',
             'got': 'part 2 screen %s, curPart %d, textFormat %d, row0 %r, text2Err %d' % (
                 'seen' if booted else 'MISSING', part, fmt, r[0], err),
             'result': 'PASS' if ok else 'FAIL', 'evidence': 'reader/TEXT2X2%s/' % TAG}]


def t_f1_walks():
    """Format 1 controls only, into <LEG>_f1<TAG>; f1_identity compares two tags."""
    ov = read_walk(os.path.join(ROOT, 'tests', 'objshare', 'walk.txt'))
    n4 = read_walk(os.path.join(HERE, 'walk_nest4.txt'))
    for leg, w in (('TEXT2C', ov), ('TEXT2WC', ov), ('TEXT2NC', n4 + ['READ', 'HUM'])):
        L = Leg(leg)
        try:
            L.walk(w, leg + '_f1' + TAG)
        finally:
            L.close()
    return []


def t_f1_identity():
    """F1_BASE (tag of the 84c43e3 run) vs TAG: format 1 screens equal per step."""
    base = os.environ['F1_BASE']
    out = []
    for leg in ('TEXT2C', 'TEXT2WC', 'TEXT2NC'):
        a = json.load(open(os.path.join(OUT, leg + '_f1' + base, 'screens.json')))
        b = json.load(open(os.path.join(OUT, leg + '_f1' + TAG, 'screens.json')))
        d = compare(a, b)
        out.append({'test': 'f1_identity %s %s vs %s' % (leg, base, TAG),
                    'expect': 'format 1 screens equal per step (%d steps)' % (len(a) - 1),
                    'got': 'equal' if not d else 'DIFFER at %s' % d, 'result': 'PASS' if not d else 'FAIL',
                    'evidence': 'reader/%s_f1%s/, reader/%s_f1%s/' % (leg, base, leg, TAG)})
    return out


def t_tools():
    L = Leg('TEXT2C')
    try:
        print(json.dumps(L.s.mcp.tools(), indent=1))
    finally:
        L.close()
    return []


TESTS = {'objverif_walk': t_objverif, 'nest4_walk': t_nest4, 'xmb_walk': t_xmb,
         'xmb_mismatch_refused': t_mismatch, 'xmb_fp_refused': t_fp_mismatch, 'xmb_part_fallback': t_part_fallback, 'timing': t_timing, 'f1_walks': t_f1_walks,
         'f1_identity': t_f1_identity, 'tools': t_tools}


def main():
    os.makedirs(OUT, exist_ok=True)
    rj = os.path.join(OUT, 'results%s.json' % TAG)
    allr = json.load(open(rj)) if os.path.exists(rj) else {}
    for t in sys.argv[1:]:
        res = TESTS[t]()
        for r in res:
            print(r)
            print('%s %s' % (r['result'], r['test']), flush=True)
        if res:
            allr[t] = res
    json.dump(allr, open(rj, 'w'), indent=1)
    with open(os.path.join(OUT, 'results%s.md' % TAG), 'w', newline='\n') as f:
        f.write('# Task 6 reader legs (CSpect MCP)%s\n\n' % (' ' + TAG if TAG else ''))
        f.write('Interpreter: %s\n\n' % os.environ.get('T6_NEX_NAME', 'DEBUG build (build.ps1)'))
        f.write('| test | expect | got | result | evidence |\n|---|---|---|---|---|\n')
        for t in TESTS:
            for r in allr.get(t, []):
                f.write('| %s | %s | %s | %s | %s |\n' % (r['test'], r['expect'],
                        r['got'].replace('|', '/'), r['result'], r['evidence']))
        notes = os.path.join(OUT, 'notes.md')
        if os.path.exists(notes):
            f.write('\n' + open(notes).read())


if __name__ == '__main__':
    main()
