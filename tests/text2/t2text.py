"""Decode every text of a DDB in either text format; compare two DDBs.

python tests/text2/t2text.py A.DDB [B.DDB] [--cross N] [--keep-msgs N] [--xmb A.XMB [B.XMB]] [--offs N,...]
  One DDB: print a coverage summary (tokens, nested references, texts
  that use nested entries). Format 2: lookup words are region offsets,
  the region starts at file offset word 32. --cross N: print the file
  size, word 32 and every text whose bytes span file offset N; exit 1
  unless one does. Two DDBs: exit 1 unless every text decodes
  identically (format 2 vs its format 1 control); --keep-msgs N
  compares messages below N only (a control with later messages
  trimmed). --xmb also decodes the
  XMESSAGE texts at the given offsets (format 2 offsets include the
  4-byte header; --offs lists the format 1 offsets, +4 is applied).
Format 2 per src/huffdec.asm and tests/text2/t2model.py; format 1 per
src/ddbtext.asm txt_next_decoded (XOR $FF, bit-7-terminated tokens).
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import t2model  # noqa: E402

KINDS = ('sysmess', 'messages', 'locations', 'objects')


def counts_ptrs(d):
    out = []
    for k in range(4):
        n = d[6 - k]
        tab = struct.unpack_from('<H', d, 0x12 - 2 * k)[0]
        out.append((n, tab))
    return out


class F1:
    def __init__(self, d):
        self.d = d
        tok = struct.unpack_from('<H', d, 8)[0]
        self.tokens, cur, p = [], [], tok
        while len(self.tokens) < 129:
            b = d[p]; p += 1
            cur.append(b & 0x7F)
            if b & 0x80:
                self.tokens.append(''.join(map(chr, cur))); cur = []
        self.tokens = self.tokens[1:]   # first entry unused

    def addr(self, word):
        return word

    def text(self, p, data=None):
        data = self.d if data is None else data
        s, used = '', set()
        while True:
            b = data[p] ^ 0xFF; p += 1
            if b == 10:
                self.end = p
                return s, used
            if b >= 128:
                s += self.tokens[b - 128]; used.add(b - 128)
            else:
                s += chr(b)


class F2:
    def __init__(self, d):
        self.d = d
        self.m = t2model.t2_model(d)
        assert self.m['err'] == 0, self.m
        self.base = self.m['regionBase']
        self.blk = self.m['blockFile']
        self.idx = self.base + self.m['text2Index']
        self.ntok = self.m['text2Ntok']
        self.entries = []
        for k in range(self.ntok):
            off = struct.unpack_from('<H', d, self.idx + 2 * k)[0]
            p = self.blk + off
            n = d[p]
            self.entries.append(list(d[p + 1:p + 1 + n]))

    def expand(self, k, depth=0):
        out, nested = '', set()
        for b in self.entries[k]:
            if b >= 128:
                assert depth == 0, 'reference inside a nested entry'
                t = b - 128
                assert not any(x >= 128 for x in self.entries[t]), 'target has references'
                out += self.expand(t, 1)[0]; nested.add(t)
            else:
                out += chr(b)
        return out, nested

    def sym(self, bits):
        m = self.m
        v = 0
        for L in range(1, 16):
            v = (v << 1) | next(bits)
            if v < m['hfLimit'][L - 1]:
                i = (v + m['hfOffs'][L - 1]) & 0xFFFF
                return m['hfSym'][i] | (256 if i >= m['hfHi'][L - 1] else 0)
        return 10

    def addr(self, word):
        return self.base + word

    def text(self, p, data=None):
        data = self.d if data is None else data
        pos = [p]

        def bits():
            while True:
                b = data[pos[0]]; pos[0] += 1
                for i in range(7, -1, -1):
                    yield (b >> i) & 1
        g = bits()
        s, used = '', set()
        while True:
            c = self.sym(g)
            if c == 10:
                self.end = pos[0]
                return s, used
            if c < 128:
                s += chr(c)
            else:
                t, n = self.expand(c - 128)
                s += t; used.add(c - 128); used |= {('n', x) for x in n}


def reader(d):
    return F2(d) if d[0] & 0x80 else F1(d)


def all_texts(d):
    r = reader(d)
    out, spans = {}, {}
    for k, (n, tab) in enumerate(counts_ptrs(d)):
        for i in range(n):
            p = r.addr(struct.unpack_from('<H', d, tab + 2 * i)[0])
            out[(KINDS[k], i)] = r.text(p)
            spans[(KINDS[k], i)] = (p, r.end)
    return r, out, spans


def main(a):
    xmb, cross, keep = None, None, None
    if '--keep-msgs' in a:
        j = a.index('--keep-msgs'); keep = int(a[j + 1]); a = a[:j] + a[j + 2:]
    if '--cross' in a:
        j = a.index('--cross'); cross = int(a[j + 1], 0); a = a[:j] + a[j + 2:]
    if '--xmb' in a:
        j = a.index('--xmb'); xmb = a[j + 1:]; a = a[:j]
    offs = []
    if xmb and '--offs' in xmb:
        j = xmb.index('--offs'); offs = [int(x) for x in xmb[j + 1].split(',')]; xmb = xmb[:j]
    ds = [open(f, 'rb').read() for f in a]
    res = [all_texts(d) for d in ds]
    r0, t0, sp0 = res[0]
    if isinstance(r0, F2):
        print('format 2: file %d bytes, word 32 (part A) %d, region %d bytes' % (
            len(ds[0]), r0.base, len(ds[0]) - r0.base))
        refs = [k for k, e in enumerate(r0.entries) if any(b >= 128 for b in e)]
        nested_texts = [key for key, (s, u) in t0.items() if any(isinstance(x, tuple) for x in u)]
        print('format 2: ntok %d alpha %d, entries with references %d' % (r0.ntok, r0.m['text2Alpha'], len(refs)))
        print('texts using a nested entry: %d' % len(nested_texts))
        for key in sorted(nested_texts):
            print('  %s %d: %r' % (key[0], key[1], t0[key][0][:70]))
    ok = True
    if cross is not None:
        hits = [k for k, (p, e) in sp0.items() if p < cross < e]
        for k in sorted(hits, key=lambda k: sp0[k]):
            p, e = sp0[k]
            print('crosses %d: %s %d, file offsets %d..%d (%d bytes), %r' % (
                cross, k[0], k[1], p, e - 1, e - p, t0[k][0][:60]))
        if not hits:
            print('no text crosses file offset %d' % cross)
            ok = False
    if len(ds) == 2:
        _, t1, _ = res[1]
        for key in sorted(set(t0) | set(t1)):
            if keep is not None and key[0] == 'messages' and key[1] >= keep:
                continue
            if t0.get(key, ('?',))[0] != t1.get(key, ('?',))[0]:
                ok = False
                print('DIFF %s %d: %r vs %r' % (key[0], key[1], t0.get(key), t1.get(key)))
        n = sum(1 for k in t0 if keep is None or k[0] != 'messages' or k[1] < keep)
        print('texts compared: %d, %s' % (n, 'identical' if ok else 'DIFFERENT'))
    if xmb:
        xs = [open(f, 'rb').read() for f in xmb]
        for o in offs:
            got = []
            for d, x, (r, _, _) in zip(ds, xs, res):
                if isinstance(r, F2):
                    assert x[:2] == b'X2' and struct.unpack_from('<H', x, 2)[0] == r.m['text2Fp']
                    got.append(r.text(o + 4, x)[0])
                else:
                    got.append(r.text(o, x)[0])
            same = len(set(got)) == 1
            ok = ok and same
            print('XMB offset %d: %s %r' % (o, 'same' if same else 'DIFF', got))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
