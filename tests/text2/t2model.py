"""Python model of the NextDAAD text format 2 loader (src/huffbuild.asm).

t2_model(ddb) -> dict of the resident cells and tables t2_build writes, or
{'err': T2E code} for a block the loader must refuse. Pure integer logic,
mirroring the check order of t2_build.
"""
import struct, sys

HF_MAXLEN = 15
HF_SYM_MAX = 256
T2E = dict(MAGIC=1, FLAGS=2, NTOK=3, FP=4, EOM=5, SYM=6, KRAFT=7, BUDGET=8)


def crc16_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


def t2_model(ddb):
    blk = struct.unpack_from('<H', ddb, 8)[0]
    b = ddb[blk:]
    if b[0:2] != b'H2':
        return {'err': T2E['MAGIC']}
    alpha = b[2]
    if alpha >= 2:
        return {'err': T2E['FLAGS']}
    ntok = struct.unpack_from('<H', b, 3)[0]
    if ntok == 0 or ntok > (383 if alpha else 128):
        return {'err': T2E['NTOK']}
    fp = struct.unpack_from('<H', b, 5)[0]
    nbytes = 256 if alpha else 128
    lens_raw = b[7:7 + nbytes]
    lens = []
    for x in lens_raw:
        lens += [x & 15, x >> 4]
    if crc16_ccitt(lens_raw) != fp:
        return {'err': T2E['FP']}
    if lens[10] == 0:
        return {'err': T2E['EOM']}
    last = max(i for i, n in enumerate(lens) if n)
    if last >= 128 + ntok:
        return {'err': T2E['SYM']}
    count = [0] * (HF_MAXLEN + 1)
    for n in lens:
        if n:
            count[n] += 1
    limit, offs = [], []
    first = base = 0
    for L in range(1, HF_MAXLEN + 1):
        offs.append((base - first) & 0xFFFF)
        lim = first + count[L]
        limit.append(lim & 0xFFFF)
        if lim > (1 << L):
            return {'err': T2E['KRAFT']}
        base += count[L]
        first = (lim << 1) & 0xFFFF
    if base > HF_SYM_MAX:
        return {'err': T2E['BUDGET'], 'used': base}
    syms, hi = [], [0xFFFF] * HF_MAXLEN
    for L in range(1, HF_MAXLEN + 1):
        for s, n in enumerate(lens):
            if n == L:
                if s >= 256 and hi[L - 1] == 0xFFFF:
                    hi[L - 1] = len(syms)
                syms.append(s)
    return {'err': 0, 'textFormat': 1, 'text2Alpha': alpha, 'text2Ntok': ntok,
            'text2Block': blk, 'text2Index': blk + 7 + nbytes, 'text2Fp': fp,
            'hfLimit': limit, 'hfOffs': offs, 'hfHi': hi,
            'hfSym': [s & 0xFF for s in syms], 'used': base, 'lens': lens}


def decode_check(m, ddb):
    """Decode every symbol code through the model tables (self-test)."""
    lens = m['lens']
    code, nxt = {}, 0
    for L in range(1, HF_MAXLEN + 1):
        for s, n in enumerate(lens):
            if n == L:
                code[s] = (nxt, L)
                nxt += 1
        nxt <<= 1
    for s, (c, L) in code.items():
        v = 0
        for k in range(1, HF_MAXLEN + 1):
            v = (v << 1) | ((c >> (L - k)) & 1)
            if v < m['hfLimit'][k - 1]:
                idx = (v + m['hfOffs'][k - 1]) & 0xFFFF
                got = m['hfSym'][idx] | (256 if idx >= m['hfHi'][k - 1] else 0)
                assert k == L and got == s, (s, c, L, k, got)
                break
        else:
            raise AssertionError('no decode for %d' % s)
    return len(code)


if __name__ == '__main__':
    if sys.argv[1] == '--err':          # --err N file: exit 1 unless the model refuses with N
        m = t2_model(open(sys.argv[3], 'rb').read())
        if m['err'] == 0:
            decode_check(m, None)
        print(sys.argv[3], 'err', m['err'])
        sys.exit(0 if m['err'] == int(sys.argv[2]) else 1)
    d = open(sys.argv[1], 'rb').read()
    m = t2_model(d)
    if m['err'] == 0:
        print('decoded', decode_check(m, d), 'codes')
    print({k: v for k, v in m.items() if k not in ('lens', 'hfSym')})
