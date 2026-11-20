"""Loader legs on CSpect (tests/cspect Session): boot each staged card, read the
format 2 cells, tables and the pool C claim (bankTable 20-23), compare with
tests/text2/t2model.py, screenshot.

python tests/text2/loader/run_loader_legs.py [card ...]   (default: all)
Cards: TEXT2, TEXT2W, TEXT2C, TEXT2BAD/<name>, TEXT2REG, TEXT2REGC,
TEXT2REGBAD/<name>. Stage them with tests/text2/stage_legs.py loader.
One harness CSpect at a time, closed after each card.
Writes results.md and the screenshots beside this file.
"""
import json, os, sys
from pathlib import Path

ROOT = str(Path(__file__).resolve().parents[3])
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, 'tests', 'text2'))
import t2model  # noqa: E402
import drive_cspect  # noqa: E402

TAG = os.environ.get('T5_TAG', '')     # e.g. _release: separate shots/results
BAD = ['MAGIC', 'FLAGS', 'NTOK', 'FP', 'EOM', 'SYM', 'KRAFT']
REGBAD = ['A59', 'REGOVER', 'BLK2', 'F1BIG', 'F1EQ', 'F1P1']
POOL_C = 20


def pool_c_claim(ddb):
    """Banks 20.. text2_load marks BT_RESERVED: format 2 past the region checks."""
    n = len(ddb)
    if not ddb[0] & 0x80:
        return 0
    a = t2model.region_base(ddb)
    blk = ddb[8] | ddb[9] << 8
    if a < t2model.REGION_MIN_A or n - a < t2model.REGION_MIN_BLOCK or n - a > 65535 or blk:
        return 0
    return 0 if n <= 65536 else min(4, (n - 65536 + 16383) // 16384)


def words(b, off, n):
    return [b[off + 2 * i] | b[off + 2 * i + 1] << 8 for i in range(n)]


def run_card(card, log):
    folder = os.path.join(ROOT, 'sd', card)
    ddb = open(os.path.join(folder, 'GAME.DDB'), 'rb').read()
    fmt2 = bool(ddb[0] & 0x80)
    model = t2model.t2_model(ddb) if fmt2 else None
    res = {'card': card}
    L = drive_cspect.Leg(card, log=None)
    log.append('- launch %s PID %d' % (card, L.s.pid))
    try:
        s = L.s
        sym = s.sym
        L.settle(more_ok=False)
        shot = 'shot%s_%s.png' % (TAG, card.replace('/', '_').replace('\\', '_'))
        L.shot(os.path.join(HERE, shot))
        res['shot'] = shot
        s.pause()
        base = sym('TEXTFORMAT')
        n = sym('HFSYM') + 511 - base          # HF_SYM_MAX
        cells = list(s.read(base, n))

        def at(name, k=1):
            o = sym(name) - base
            return cells[o] if k == 1 else cells[o] | cells[o + 1] << 8
        got = {'textFormat': at('TEXTFORMAT'), 'text2Err': at('TEXT2ERR')}
        rows = L.rows(2)
        res['row0'] = rows[0]
        bt = list(s.read(sym('BANKTABLE'), 112))
        claim = pool_c_claim(ddb)
        want_c = [0] * claim + [1] * (4 - claim)
        res['poolc'] = 'bankTable[20..23] %s want %s, free %d' % (
            bt[POOL_C:POOL_C + 4], want_c, bt.count(1))
        if len(ddb) > 65536 and not fmt2:
            res['expect'] = 'E2 oversize screen, pool C free'
            ok = rows[0].startswith('NextDAAD: DDB oversize - E2')
            res['got'] = 'row0 %r' % rows[0]
        elif not fmt2:
            res['expect'] = 'textFormat 0, no E-code, game screen'
            ok = got['textFormat'] == 0 and 'NextDAAD:' not in rows[0]
            res['got'] = 'textFormat %d text2Err %d row0 %r' % (got['textFormat'], got['text2Err'], rows[0][:40])
        elif model['err']:
            res['expect'] = 'E5 screen, text2Err %d' % model['err']
            ok = got['text2Err'] == model['err'] and rows[0].startswith('NextDAAD: DDB text format - E5')
            res['got'] = 'text2Err %d row0 %r' % (got['text2Err'], rows[0])
        else:
            got.update(regionPage=at('REGIONPAGE'), regionOff=at('REGIONOFF', 2),
                       text2Alpha=at('TEXT2ALPHA'), text2Ntok=at('TEXT2NTOK', 2),
                       text2Block=at('TEXT2BLOCK', 2), text2Index=at('TEXT2INDEX', 2),
                       text2Fp=at('TEXT2FP', 2),
                       hfLimit=words(cells, sym('HFLIMIT') - base, 15),
                       hfOffs=words(cells, sym('HFOFFS') - base, 15),
                       hfHi=words(cells, sym('HFHI') - base, 15),
                       hfSym=cells[sym('HFSYM') - base:sym('HFSYM') - base + model['used']])
            bad = [k for k in got if k in model and got[k] != model[k]]
            res['expect'] = 'textFormat 1, tables = t2model (%d symbols), no E-code' % model['used']
            ok = not bad and 'NextDAAD:' not in rows[0]
            res['got'] = ('all %d fields match' % len(got)) if not bad else 'MISMATCH ' + ', '.join(
                '%s got %s want %s' % (k, got[k], model[k]) for k in bad)
            res['got'] += '; ntok %d alpha %d block $%04X index $%04X' % (
                got['text2Ntok'], got['text2Alpha'], got['text2Block'], got['text2Index'])
            json.dump(got, open(os.path.join(HERE, 'tables%s_%s.json' % (TAG, card)), 'w'), indent=1)
        ok = ok and bt[POOL_C:POOL_C + 4] == want_c
        res['got'] += '; ' + res['poolc']
        res['result'] = 'PASS' if ok else 'FAIL'
    finally:
        pid = L.s.pid
        L.close()
        log.append('  closed PID %d' % pid)
    return res


def main():
    cards = sys.argv[1:] or (['TEXT2', 'TEXT2W', 'TEXT2C'] + ['TEXT2BAD\\' + b for b in BAD] +
                             ['TEXT2REG', 'TEXT2REGC'] + ['TEXT2REGBAD\\' + b for b in REGBAD])
    log, results = [], []
    for c in cards:
        r = run_card(c, log)
        print(r)
        print('%s %s' % (r['result'], r['card']), flush=True)
        results.append(r)
    with open(os.path.join(HERE, 'results%s.md' % TAG), 'w', newline='\n') as f:
        f.write('# Loader legs (CSpect MCP)\n\n')
        f.write('| card | expect | got | result | screenshot |\n|---|---|---|---|---|\n')
        for r in results:
            f.write('| %s | %s | %s | %s | %s |\n' % (r['card'], r['expect'], r['got'].replace('|', '/'),
                                                     r['result'], r['shot']))
        f.write('\nLaunches:\n\n' + '\n'.join(log) + '\n')


if __name__ == '__main__':
    main()
