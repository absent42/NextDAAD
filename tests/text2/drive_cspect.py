"""Task 6 reader legs on CSpect 4.3 over MCP (port 23456).

python tests/text2/drive_cspect.py TEST [...]
Tests: objverif_walk, nest4_walk, xmb_walk, xmb_mismatch_refused, timing,
tools (print the MCP tool list). Each leg is one CSpect launch, killed by
PID. Walk screens (tilemap text per step, PNG at the end of each step)
go to tests/text2/reader/<LEG>/; results.md is rewritten from all
results gathered so far (results.json).
"""
import base64, json, os, subprocess, sys, time, urllib.request

ROOT = r'D:\NextDAAD'
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'reader')
CSPECT = r'D:\ZXNextDev\cspect\CSpect.exe'
NEX = os.environ.get('T6_NEX', ROOT + r'\build\nextdaad.nex')
MAP = os.environ.get('T6_MAP', ROOT + r'\build\nextdaad.map')
TAG = os.environ.get('T6_TAG', '')
URL = 'http://127.0.0.1:23456/mcp'
LAUNCHES = os.path.join(OUT, 'launches%s.log' % TAG)


class Mcp:
    def __init__(self):
        self.id, self.sess = 0, None

    def rpc(self, method, params=None, timeout=60):
        self.id += 1
        body = json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method,
                           'params': params or {}}).encode()
        hdr = {'Content-Type': 'application/json',
               'Accept': 'application/json, text/event-stream'}
        if self.sess:
            hdr['Mcp-Session-Id'] = self.sess
        with urllib.request.urlopen(urllib.request.Request(URL, body, hdr), timeout=timeout) as r:
            self.sess = r.headers.get('Mcp-Session-Id') or self.sess
            txt = r.read().decode('utf-8', 'replace')
        for line in txt.splitlines():
            if line.startswith('data:'):
                txt = line[5:].strip()
        return json.loads(txt) if txt.strip() else {}

    def call(self, tool, args=None, timeout=60):
        return self.rpc('tools/call', {'name': tool, 'arguments': args or {}}, timeout)

    def text(self, tool, args=None, timeout=60):
        r = self.call(tool, args, timeout)
        return '\n'.join(c['text'] for c in r.get('result', {}).get('content', [])
                         if c.get('type') == 'text')

    def mem(self, addr, n):
        out = []
        while n > 0:
            k = min(n, 4096)
            for line in self.text('read_memory', {'address': '$%04X' % addr, 'length': k}).splitlines():
                if line.startswith('$'):
                    out += [int(x, 16) for x in line[6:6 + 49].split()]
            addr += k
            n -= k
        return out

    def shot(self, path):
        r = self.call('screenshot', {'scale': 1})
        for c in r.get('result', {}).get('content', []):
            if c.get('type') == 'image':
                open(path, 'wb').write(base64.b64decode(c['data']))
                return True
        return False


def symbols():
    sym = {}
    for line in open(MAP):
        p = line.split()
        if len(p) == 4:
            sym[p[3]] = int(p[0], 16)
    return sym


def rows(m, n=32):
    b = m.mem(0x6000, 160 * n)
    return [''.join(chr(c) if 32 <= c < 127 else '.' for c in b[r * 160:(r + 1) * 160:2]).rstrip()
            for r in range(n)]


class Leg:
    def __init__(self, leg):
        self.leg = leg
        folder = os.path.join(ROOT, 'sd', leg)
        args = [CSPECT, '-w2', '-zxnext', '-esc', '-mcp=23456', '-mmc=%s\\' % folder,
                '-map=%s' % MAP, NEX]
        self.p = subprocess.Popen(args, cwd=os.path.dirname(CSPECT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(LAUNCHES, 'a') as f:
            f.write('%s launch `%s` PID %d\n' % (time.strftime('%H:%M:%S'), ' '.join(args), self.p.pid))
        self.m = Mcp()
        for _ in range(60):
            try:
                self.m.rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                          'clientInfo': {'name': 'task6', 'version': '1'}})
                break
            except Exception:
                time.sleep(0.5)
        else:
            self.close()
            raise SystemExit('MCP never came up')
        time.sleep(6)

    def close(self):
        subprocess.run(['taskkill', '/PID', str(self.p.pid), '/F'], capture_output=True)
        with open(LAUNCHES, 'a') as f:
            f.write('%s killed PID %d\n' % (time.strftime('%H:%M:%S'), self.p.pid))
        time.sleep(1.5)

    def settle(self, more_ok=True, limit=60):
        """Poll the tilemap until it holds still; answer More... with SPACE."""
        last, same, mores = None, 0, 0
        t0 = time.time()
        while time.time() - t0 < limit:
            time.sleep(0.4)
            r = rows(self.m)
            if more_ok and any('More...' in x for x in r):
                time.sleep(0.3)
                self.m.call('press_keys', {'keys': 'SPACE'})
                mores += 1
                last, same = None, 0
                time.sleep(0.6)
                continue
            if r == last:
                same += 1
                if same >= 3:
                    return r, mores
            else:
                same = 0
            last = r
        return last, mores

    def walk(self, lines, sub):
        d = os.path.join(OUT, sub)
        os.makedirs(d, exist_ok=True)
        steps = []
        r, mo = self.settle()
        steps.append({'cmd': '(boot)', 'rows': r, 'more': mo})
        for i, cmd in enumerate(lines, 1):
            self.m.call('type_text', {'text': cmd + '\n'})
            r, mo = self.settle()
            steps.append({'cmd': cmd, 'rows': r, 'more': mo})
            self.m.shot(os.path.join(d, 'step%02d.png' % i))
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
    sym = symbols()
    L = Leg('TEXT2X')
    try:
        st = L.walk(['LOOK', 'READ'], 'TEXT2X' + TAG)
        L.m.call('pause')
        err = L.m.mem(sym['TEXT2ERR'], 1)[0]
        r = rows(L.m, 2)
    finally:
        L.close()
    ok = st[1]['rows'] and 'NextDAAD' not in st[1]['rows'][0] and \
        r[0].startswith('NextDAAD: DDB text format - E5') and err == 8
    return [{'test': 'xmb_mismatch_refused TEXT2X', 'expect': 'LOOK plays; READ -> E5 screen, text2Err 8',
             'got': 'row0 %r text2Err %d' % (r[0], err), 'result': 'PASS' if ok else 'FAIL',
             'evidence': 'reader/TEXT2X%s/' % TAG}]


def regs_of(g):
    import re
    r = {k: int(v, 16) for k, v in re.findall(r"\b(AF|BC|DE|HL|SP|PC) \$([0-9A-F]{4})", g)}
    r['A'], r['E'] = r['AF'] >> 8, r['DE'] & 0xFF
    return r


def raster(m, sym):
    """(frameCounter, raster line) - NR $1E/$1F active video line."""
    t = m.text('read_next_registers', {'registers': '$1E,$1F'})
    import re
    v = [int(x, 16) for x in re.findall(r'\$1[EF]\D+\$?([0-9A-Fa-f]{2})', t)]
    return m.mem(sym['FRAMECOUNTER'], 1)[0], ((v[0] & 1) << 8 | v[1]) if len(v) == 2 else None, t


def timing_leg(leg, sym, runs=3):
    """print_msg for STORY (MESSAGE 48): frames and raster lines, entry to return."""
    L = Leg(leg)
    out = {'leg': leg, 'runs': []}
    try:
        m = L.m
        L.settle()
        for _ in range(runs):
            m.call('set_breakpoint', {'address': 'print_msg'})
            m.call('type_text', {'text': 'STORY\n'})
            for _ in range(20):
                m.text('wait_for_stop', {'timeout_ms': 15000})
                r = regs_of(m.text('get_status'))
                if r['A'] == 1 and r['E'] == 48:
                    break
                m.call('run')
            m.call('clear_breakpoint', {'address': 'print_msg'})
            sp = m.mem(r['SP'], 2)
            ret = sp[0] | sp[1] << 8
            f0, l0, t0 = raster(m, sym)
            m.call('set_breakpoint', {'address': '$%04X' % ret})
            m.call('run')
            m.text('wait_for_stop', {'timeout_ms': 15000})
            r2 = regs_of(m.text('get_status'))
            f1, l1, t1 = raster(m, sym)
            m.call('clear_breakpoint', {'address': '$%04X' % ret})
            m.call('run')
            lines = ((f1 - f0) & 0xFF) * 311 + (l1 - l0)
            out['runs'].append({'ret': '$%04X' % ret, 'pc_after': '$%04X' % r2['PC'],
                                'frames': (f1 - f0) & 0xFF, 'line0': l0, 'line1': l1,
                                'lines': lines, 'ms': round(lines * 64e-3, 2), 'nr': t0})
            L.settle()
        return out
    finally:
        L.close()


def t_timing():
    sym = symbols()
    r = [timing_leg('TEXT2N', sym), timing_leg('TEXT2NC', sym)]
    json.dump(r, open(os.path.join(OUT, 'timing%s.json' % TAG), 'w'), indent=1)
    return [{'test': 'timing STORY (MESSAGE 48) print_msg', 'expect': 'recorded, format 2 vs format 1 (311 lines x 64 us per frame)',
             'got': '; '.join('%s %s ms' % (x['leg'], [y['ms'] for y in x['runs']]) for x in r),
             'result': 'RECORDED', 'evidence': 'reader/timing%s.json' % TAG}]


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
        print(json.dumps(L.m.rpc('tools/list'), indent=1))
    finally:
        L.close()
    return []


TESTS = {'objverif_walk': t_objverif, 'nest4_walk': t_nest4, 'xmb_walk': t_xmb,
         'xmb_mismatch_refused': t_mismatch, 'timing': t_timing, 'f1_walks': t_f1_walks,
         'f1_identity': t_f1_identity, 'tools': t_tools}


def main():
    os.makedirs(OUT, exist_ok=True)
    rj = os.path.join(OUT, 'results%s.json' % TAG)
    allr = json.load(open(rj)) if os.path.exists(rj) else {}
    for t in sys.argv[1:]:
        res = TESTS[t]()
        for r in res:
            print(r)
        if res:
            allr[t] = res
    json.dump(allr, open(rj, 'w'), indent=1)
    with open(os.path.join(OUT, 'results%s.md' % TAG), 'w', newline='\n') as f:
        f.write('# Task 6 reader legs (CSpect 4.3 MCP)%s\n\n' % (' ' + TAG if TAG else ''))
        f.write('Interpreter: %s\n\n' % NEX)
        f.write('| test | expect | got | result | evidence |\n|---|---|---|---|---|\n')
        for t in TESTS:
            for r in allr.get(t, []):
                f.write('| %s | %s | %s | %s | %s |\n' % (r['test'], r['expect'],
                        r['got'].replace('|', '/'), r['result'], r['evidence']))


if __name__ == '__main__':
    main()
