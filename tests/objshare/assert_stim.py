# Byte-assert the OBJVERIF stimuli in a test DDB (-auto-tokens) and their
# absence in the control DDB (builtin table). Exit 0 only when every test
# check passes and the control is clean.
#
# usage: python -I assert_stim.py test.ddb ctl.ddb [--base N] [--classic|--nextdaad]
#
# Header: counts at byte 6-kind, lookup words at 0x12-2*kind (kind 0
# sysmess, 1 messages, 2 locations, 3 objects), token table word at 0x08,
# end address word at 0x20. Pointers are absolute; base = end - length
# unless --base is given. Text bytes are stored XOR 0xFF, decoded 0x0A
# ends a text, a decoded byte >= 128 is token reference c - 127 (entry 0
# of the table is a dummy).
#
# Target from the high nibble of header byte 1 (0x0C NEXTDAAD) unless
# --classic or --nextdaad is given. Classic builds add the article-strip
# rule (first word and its space run literal, no-space text and '.' tokens
# unreferenced) in place of the starts-with and single-reference checks.
import sys

KINDS = ('sysmess', 'messages', 'locations', 'objects')
SYS, MSG, LOC, OBJ = 0, 1, 2, 3
TOKMAX = 12
NEXTDAAD_ID = 0x0C

# Fixture duplicate pairs: (kind, a, b).
PAIRS = (
    (OBJ, 0, 7, 'OTX 0/7 identical objects'),
    (SYS, 63, 64, 'STX 63/64 identical sysmess'),
    (MSG, 23, 24, 'MTX 23/24 identical messages'),
    (LOC, 1, 2, 'LTX 1/2 identical locations'),
    (MSG, 25, 26, 'MTX 25/26 empty messages'),
)


class Ddb:
    def __init__(self, path, base=None):
        self.path = path
        self.b = open(path, 'rb').read()
        b = self.b
        if len(b) < 0x22 or b[2] != 0x5F:
            raise SystemExit('%s: not a DDB' % path)
        self.base = (self.u16(0x20) - len(b)) & 0xFFFF if base is None else base
        self.machine = b[1] >> 4
        self.count = {k: b[6 - k] for k in range(4)}
        self.lookup = {k: self.u16(0x12 - 2 * k) - self.base for k in range(4)}
        self.tokens = self.read_tokens()

    def u16(self, o):
        return self.b[o] | (self.b[o + 1] << 8)

    def read_tokens(self):
        b, p, toks = self.b, self.u16(8) - self.base, []
        for _ in range(129):
            t = bytearray()
            while p < len(b):
                v = b[p]
                p += 1
                t.append(v & 0x7F)
                if v & 0x80:
                    break
            toks.append(bytes(t))
        return toks

    def word(self, kind, i):
        return self.u16(self.lookup[kind] + 2 * i)

    def raw(self, kind, i):
        b, p, s = self.b, self.word(kind, i) - self.base, bytearray()
        while True:
            c = b[p] ^ 0xFF
            p += 1
            if c == 0x0A:
                return bytes(s)
            s.append(c)

    def expand(self, s):
        out = bytearray()
        for c in s:
            if c >= 128:
                out += self.tokens[c - 127]
            else:
                out.append(c)
        return bytes(out)

    def texts(self, kind):
        return [self.raw(kind, i) for i in range(self.count[kind])]


def refs(s):
    return [c for c in s if c >= 128]


def strip_ok(s, tokens):
    # Literal first byte; no reference before the end of the space run
    # after the first word; no reference at all without a stored space.
    if s and s[0] >= 128:
        return False
    if 0x20 not in s:
        return not refs(s)
    p = s.index(0x20)
    while p < len(s) and s[p] == 0x20:
        p += 1
    return not refs(s[:p]) and not any(b'.' in tokens[c - 127] for c in refs(s))


def shared_groups(d, kind):
    seen = {}
    for i in range(d.count[kind]):
        seen.setdefault(d.word(kind, i), []).append(i)
    return [v for v in seen.values() if len(v) > 1]


def main(argv):
    base = None
    classic = None
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--base':
            base = int(argv[i + 1], 0)
            i += 2
        elif argv[i] in ('--classic', '--nextdaad'):
            classic = argv[i] == '--classic'
            i += 1
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 2:
        print('usage: assert_stim.py test.ddb ctl.ddb [--base N] [--classic|--nextdaad]')
        return 2
    t, c = Ddb(args[0], base), Ddb(args[1], base)
    if classic is None:
        classic = t.machine != NEXTDAAD_ID
    print('mode: %s (machine id 0x%X)' % ('classic' if classic else 'NEXTDAAD', t.machine))

    for d in (t, c):
        print('%s: %d bytes, version %d, base 0x%04X, counts obj %d loc %d '
              'msg %d sys %d' % (d.path, len(d.b), d.b[0], d.base,
                                 d.count[OBJ], d.count[LOC], d.count[MSG],
                                 d.count[SYS]))

    otx = t.texts(OBJ)
    print('test object texts (raw bytes, [n] = token reference):')
    for i, s in enumerate(otx):
        shown = ''.join('[%d]' % (ch - 127) if ch >= 128 else chr(ch) for ch in s)
        print('  %d: %3d bytes  %s' % (i, len(s), shown))
    used = sorted(set(ch for s in otx for ch in refs(s)))
    print('tokens referenced by object texts:')
    for ch in used:
        tok = t.tokens[ch - 127]
        print('  [%d] len %2d %r' % (ch - 127, len(tok), tok.decode('latin1')))
    for k in range(4):
        g = shared_groups(t, k)
        print('test %s shared lookup groups: %s' % (KINDS[k], g))

    checks = [
        ('an object text holds a token reference', any(refs(s) for s in otx)),
    ]
    if classic:
        for i, s in enumerate(otx):
            checks.append(('classic: OTX %d article strip literal, no dot token' % i,
                           strip_ok(s, t.tokens)))
    else:
        checks += [
            ('an object text starts with a reference', any(s and s[0] >= 128 for s in otx)),
            ('an object text is a single reference', any(len(s) == 1 and s[0] >= 128 for s in otx)),
        ]
    checks += [
        ('an object text ends with a reference', any(s and s[-1] >= 128 for s in otx)),
        ('a %d-byte token lands in an object text' % TOKMAX,
         any(len(t.tokens[ch - 127]) >= TOKMAX for s in otx for ch in refs(s))),
    ]
    for kind, a, b, name in PAIRS:
        checks.append((name + ' share a lookup word', t.word(kind, a) == t.word(kind, b)))
    same = all(t.count[k] == c.count[k] for k in range(4))
    for k in range(4):
        if not same:
            break
        for n in range(t.count[k]):
            if t.expand(t.raw(k, n)) != c.expand(c.raw(k, n)):
                same = False
                print('expand mismatch: %s %d' % (KINDS[k], n))
    checks.append(('every test text expands to the control text', same))

    cotx = c.texts(OBJ)
    clean = [
        ('control: no object text holds a reference', not any(refs(s) for s in cotx)),
    ]
    for kind, a, b, name in PAIRS:
        clean.append(('control: ' + name + ' separate', c.word(kind, a) != c.word(kind, b)))

    bad = 0
    for name, ok in checks + clean:
        print('%-56s %s' % (name, 'OK' if ok else 'FAIL'))
        bad += not ok
    print('control clean' if all(ok for _, ok in clean) else 'control NOT clean')
    print('PASS' if not bad else 'FAIL (%d)' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
