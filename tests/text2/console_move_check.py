"""One CSpect launch on sd\\ERR4 (boots straight into err_raise E4, whose
DEBUG row-30 readout now runs from overlay0): screenshot + tilemap text
with the new DEBUG nex, then load_nex the previous DEBUG nex (T6_OLD_NEX)
and repeat. Writes tests/text2/reader/console_move/.
"""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drive_cspect as d

out = os.path.join(d.OUT, 'console_move')
os.makedirs(out, exist_ok=True)
L = d.Leg('ERR4')
res = {}
try:
    for tag, nex in (('new', d.NEX), ('old', os.environ['T6_OLD_NEX'])):
        if tag == 'old':
            L.m.text('load_nex', {'path': nex})
            time.sleep(6)
        r, _ = L.settle(more_ok=False, limit=20)
        L.m.shot(os.path.join(out, 'err4_%s.png' % tag))
        res[tag] = r
finally:
    L.close()
json.dump(res, open(os.path.join(out, 'screens.json'), 'w'), indent=0)
same = res['new'] == res['old']
pa = open(os.path.join(out, 'err4_new.png'), 'rb').read()
pb = open(os.path.join(out, 'err4_old.png'), 'rb').read()
print('tilemap equal:', same, '| png bytes equal:', pa == pb)
print('\n'.join(x for x in res['new'] if x))
