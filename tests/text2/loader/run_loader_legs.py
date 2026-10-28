"""Task 5 loader legs on CSpect 4.3 over MCP: boot each staged card, read the
format 2 cells and tables, compare with tests/text2/t2model.py, screenshot.

python tests/text2/loader/run_loader_legs.py [card ...]   (default: all)
Cards: TEXT2, TEXT2W, TEXT2C, TEXT2BAD/<name>. One CSpect at a time, killed by PID.
Writes results.md and the screenshots beside this file.
"""
import json, os, re, subprocess, sys, time, urllib.request, base64

ROOT = r'D:\NextDAAD'
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, 'tests', 'text2'))
import t2model  # noqa: E402

CSPECT = r'D:\ZXNextDev\cspect\CSpect.exe'
NEX = ROOT + r'\build\nextdaad.nex'
URL = 'http://127.0.0.1:23456/mcp'
TAG = os.environ.get('T5_TAG', '')     # e.g. _release: separate shots/results
BAD = ['MAGIC', 'FLAGS', 'NTOK', 'FP', 'EOM', 'SYM', 'KRAFT']


class Mcp:
    def __init__(self):
        self.id, self.sess = 0, None

    def rpc(self, method, params=None):
        self.id += 1
        body = json.dumps({'jsonrpc': '2.0', 'id': self.id, 'method': method,
                           'params': params or {}}).encode()
        hdr = {'Content-Type': 'application/json',
               'Accept': 'application/json, text/event-stream'}
        if self.sess:
            hdr['Mcp-Session-Id'] = self.sess
        with urllib.request.urlopen(urllib.request.Request(URL, body, hdr), timeout=60) as r:
            self.sess = r.headers.get('Mcp-Session-Id') or self.sess
            txt = r.read().decode('utf-8', 'replace')
        for line in txt.splitlines():
            if line.startswith('data:'):
                txt = line[5:].strip()
        return json.loads(txt) if txt.strip() else {}

    def call(self, tool, args=None):
        return self.rpc('tools/call', {'name': tool, 'arguments': args or {}})

    def text(self, tool, args=None):
        r = self.call(tool, args)
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
    for line in open(ROOT + r'\build\nextdaad.map'):
        p = line.split()
        if len(p) == 4:
            sym[p[3]] = int(p[0], 16)
    return sym


def tm_rows(m, n=32):
    b = m.mem(0x6000, 160 * n)
    return [''.join(chr(c) if 32 <= c < 127 else '.' for c in b[r * 160:(r + 1) * 160:2]).rstrip()
            for r in range(n)]


def words(b, off, n):
    return [b[off + 2 * i] | b[off + 2 * i + 1] << 8 for i in range(n)]


def run_card(card, sym, log):
    folder = os.path.join(ROOT, 'sd', card)
    ddb = open(os.path.join(folder, 'GAME.DDB'), 'rb').read()
    fmt2 = bool(ddb[0] & 0x80)
    model = t2model.t2_model(ddb) if fmt2 else None
    args = [CSPECT, '-w2', '-zxnext', '-esc', '-mcp=23456', '-mmc=%s\\' % folder, NEX]
    p = subprocess.Popen(args, cwd=os.path.dirname(CSPECT))
    log.append('- launch `%s` PID %d' % (' '.join(args), p.pid))
    res = {'card': card}
    try:
        m = Mcp()
        for _ in range(60):
            try:
                m.rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                     'clientInfo': {'name': 'task5', 'version': '1'}})
                break
            except Exception:
                time.sleep(0.5)
        time.sleep(6)
        shot = 'shot%s_%s.png' % (TAG, card.replace('/', '_').replace('\\', '_'))
        m.shot(os.path.join(HERE, shot))
        res['shot'] = shot
        m.call('pause')
        base = sym['TEXTFORMAT']
        n = sym['HFSYM'] + 511 - base          # HF_SYM_MAX
        cells = m.mem(base, n)

        def at(name, k=1):
            o = sym[name] - base
            return cells[o] if k == 1 else cells[o] | cells[o + 1] << 8
        got = {'textFormat': at('TEXTFORMAT'), 'text2Err': at('TEXT2ERR')}
        rows = tm_rows(m, 2)
        res['row0'] = rows[0]
        if not fmt2:
            res['expect'] = 'textFormat 0, no E-code, game screen'
            ok = got['textFormat'] == 0 and 'NextDAAD:' not in rows[0]
            res['got'] = 'textFormat %d text2Err %d row0 %r' % (got['textFormat'], got['text2Err'], rows[0][:40])
        elif model['err']:
            res['expect'] = 'E5 screen, text2Err %d' % model['err']
            ok = got['text2Err'] == model['err'] and rows[0].startswith('NextDAAD: DDB text format - E5')
            res['got'] = 'text2Err %d row0 %r' % (got['text2Err'], rows[0])
        else:
            got.update(text2Alpha=at('TEXT2ALPHA'), text2Ntok=at('TEXT2NTOK', 2),
                       text2Block=at('TEXT2BLOCK', 2), text2Index=at('TEXT2INDEX', 2),
                       text2Fp=at('TEXT2FP', 2),
                       hfLimit=words(cells, sym['HFLIMIT'] - base, 15),
                       hfOffs=words(cells, sym['HFOFFS'] - base, 15),
                       hfHi=words(cells, sym['HFHI'] - base, 15),
                       hfSym=cells[sym['HFSYM'] - base:sym['HFSYM'] - base + model['used']])
            bad = [k for k in got if k in model and got[k] != model[k]]
            res['expect'] = 'textFormat 1, tables = t2model (%d symbols), no E-code' % model['used']
            ok = not bad and 'NextDAAD:' not in rows[0]
            res['got'] = ('all %d fields match' % len(got)) if not bad else 'MISMATCH ' + ', '.join(
                '%s got %s want %s' % (k, got[k], model[k]) for k in bad)
            res['got'] += '; ntok %d alpha %d block $%04X index $%04X' % (
                got['text2Ntok'], got['text2Alpha'], got['text2Block'], got['text2Index'])
            json.dump(got, open(os.path.join(HERE, 'tables%s_%s.json' % (TAG, card)), 'w'), indent=1)
        res['result'] = 'PASS' if ok else 'FAIL'
    finally:
        subprocess.run(['taskkill', '/PID', str(p.pid), '/F'], capture_output=True)
        log.append('  killed PID %d' % p.pid)
        time.sleep(1)
    return res


def main():
    cards = sys.argv[1:] or ['TEXT2', 'TEXT2W', 'TEXT2C'] + ['TEXT2BAD\\' + b for b in BAD]
    sym = symbols()
    log, results = [], []
    for c in cards:
        r = run_card(c, sym, log)
        print(r)
        results.append(r)
    with open(os.path.join(HERE, 'results%s.md' % TAG), 'w', newline='\n') as f:
        f.write('# Task 5 loader legs (CSpect 4.3 MCP)\n\n')
        f.write('| card | expect | got | result | screenshot |\n|---|---|---|---|---|\n')
        for r in results:
            f.write('| %s | %s | %s | %s | %s |\n' % (r['card'], r['expect'], r['got'].replace('|', '/'),
                                                     r['result'], r['shot']))
        f.write('\nLaunches:\n\n' + '\n'.join(log) + '\n')


if __name__ == '__main__':
    main()
