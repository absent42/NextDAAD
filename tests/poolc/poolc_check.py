"""CSpect (tests/cspect) check for the pool C part switch cards. Controller only.

python tests/poolc/poolc_check.py <card> <map> <port> <case>
  control  sd\\LEGPCC + main's map: song pages include bank 20; bank 20
           BT_USED by the song right before JUMP, which prints P1 SWITCH F
  switch   sd\\LEGPC + branch map: partBanksMax 1, no song page in
           20..20+max-1, JUMP reaches P2 BOOT with the stream still live
  restore  sd\\LEGPC: the switch case, SAVE PCSAVE in part 2, relaunch,
           song again, LOAD PCSAVE from part 1 lands in part 2 (P2 ROOM)
  focus5   sd\\LEGPC: partBanksMax poked to 4; aysHdr and smpClaim* show
           the file opened and the claim ran, which fails with nothing held
<port> is the harness MCP port (tests/cspect/launcher.py PORT_RANGE), 0 for the first free.
Every case marks each BT_FREE bank outside pool C BT_USED at the P1 BOOT
pause. Runs on a scratch copy, tests/out/poolc/run-<case>/sd. Banked symbols
are read at their map physical address (Session.read_page); settles count FRAMECOUNTER.
"""
import os, shutil, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
sys.path.insert(0, os.path.join(ROOT, 'tests', 'parser'))
from cspect import Session  # noqa: E402
import nleg  # noqa: E402

SAVE_NAME = 'PCSAVE'
POLL_S = 0.1
FRAME_WAIT_S = 30.0             # host deadline for a frame-counted settle
SECOND = 50                     # frames
SAVE_WAIT_S = 10.0              # host deadline for PCSAVE.SAV on the card

results = []


def expect(name, ok, detail):
    results.append((name, ok))
    print('%s  %s: %s' % ('PASS' if ok else 'FAIL', name, detail), flush=True)


class Run:
    def __init__(self, mapf, port):
        self.mapf, self.port, self.s = mapf, port, None

    def launch(self, sd):
        self.nex = os.path.join(sd, 'NEXTDAAD.NEX')
        self.s = Session.boot(sd, self.nex, self.mapf, port=self.port)
        print('CSpect PID %d on MCP port %d' % (self.s.pid, self.s.inst.port), flush=True)
        self.k = {n: self.s.sym(n) for n in ('BT_FREE', 'BT_USED', 'BANK_POOL_C',
                                             'BANK_POOL_C_END', 'BANK_TABLE_SIZE')}

    def kill(self):
        if self.s is not None:
            self.s.close()
            self.s = None

    def rd(self, name, n=1):
        return self.s.read(self.s.sym(name), n)

    def rdz(self, name, n=1):
        # banked symbol: CSpect physical = page * $2000 + offset
        phys = self.s.symbols[name.upper()][1]
        return self.s.read_page(phys >> 13, phys & 0x1FFF, n)

    def wr(self, name, data):
        self.s.write(self.s.sym(name), data)
        if self.rd(name, len(data)) != data:
            raise SystemExit('write to %s did not read back' % name)

    def screen(self):
        return [r.rstrip() for r in self.s.rows()]

    def settle(self, frames):
        self.s.wait_frames(frames, FRAME_WAIT_S)

    def dismiss(self):
        self.s.press(nleg.DISMISS_KEY, nleg.DISMISS_HOLD_FRAMES)

    def wait_for(self, needles, deadline):
        taps = [0]

        def seen():
            rows = self.screen()
            text = '\n'.join(rows)
            hit = next((n for n in needles if n in text), None)
            if hit:
                return hit, rows
            if 'More...' in text and taps[0] < 5:
                taps[0] += 1
                self.dismiss()
            return None
        try:
            return self.s.wait_until(seen, deadline, POLL_S, ' or '.join(needles))
        except TimeoutError:
            return None, self.screen()

    def typed(self, line):
        self.s.type_text(line + '\n')

    def bank_table(self):
        return self.rd('BANKTABLE', self.k['BANK_TABLE_SIZE'])

    def zone_sanity(self):
        # resident bankTable sits in bank 2, so both views must agree
        if self.rdz('BANKTABLE', self.k['BANK_TABLE_SIZE']) != self.bank_table():
            raise SystemExit('physical view of bankTable disagrees with the 64K view')
        # page 48 code must match the NEX image's bank 24
        phys = self.s.symbols['AUD_AYS_RDB'][1]
        want = nex_bank(self.nex, phys // 16384)[phys % 16384:phys % 16384 + 16]
        got = self.rdz('AUD_AYS_RDB', 16)
        if got != want:
            raise SystemExit('physical page 48 read %s, NEX holds %s' % (got.hex(), want.hex()))
        print('physical view sanity: bankTable (bank 2) and aud_ays_rdb (page 48) match')

    def fill_pools(self):
        bt = bytearray(self.bank_table())
        c0, c1 = self.k['BANK_POOL_C'], self.k['BANK_POOL_C_END']
        n = 0
        for i, b in enumerate(bt):
            if not c0 <= i <= c1 and b == self.k['BT_FREE']:
                bt[i] = self.k['BT_USED']
                n += 1
        self.wr('BANKTABLE', bytes(bt))
        return n, bytes(bt)

    def song(self):
        cnt = self.rdz('AYSPAGECNT')[0]
        pages = self.rdz('AYSPAGETAB', cnt) if cnt else b''
        return {'cnt': cnt, 'banks': sorted(set(p // 2 for p in pages)),
                'flags': self.rdz('AYSFLAGS')[0], 'pos': self.pos()}

    def pos(self):
        return self.rdz('AYSTABIDX')[0], int.from_bytes(self.rdz('AYSOFF', 2), 'little')

    def pbm(self):
        return self.rd('PARTBANKSMAX')[0] if 'PARTBANKSMAX' in self.s.symbols else None

    def stream_live(self):
        a = self.pos()
        self.settle(SECOND)
        b = self.pos()
        return bool(self.rdz('AYSFLAGS')[0] & 1) and a != b, a, b

    def boot_to_song(self, pbm_poke=None, before_tap=None):
        hit, rows = self.wait_for(['P1 BOOT'], 40.0)
        if not hit:
            dump(rows)
            raise SystemExit('part 1 never printed P1 BOOT')
        self.zone_sanity()
        print('ramExpanded %d, partBanksMax %s' % (self.rd('RAMEXPANDED')[0], self.pbm()))
        if pbm_poke is not None:
            self.wr('PARTBANKSMAX', bytes([pbm_poke]))
            print('partBanksMax poked to %d' % pbm_poke)
        n, poked = self.fill_pools()
        print('marked %d free banks outside pool C BT_USED' % n)
        if before_tap:
            before_tap()
        self.dismiss()
        hit, rows = self.wait_for(['P1 SONG ON'], 30.0)
        if not hit:
            dump(rows)
            raise SystemExit('part 1 never printed P1 SONG ON')
        self.settle(SECOND)
        sg = self.song()
        bt = self.bank_table()
        c0, c1 = self.k['BANK_POOL_C'], self.k['BANK_POOL_C_END']
        print('song: %d pages, banks %s, aysFlags $%02X, pool C states %s'
              % (sg['cnt'], sg['banks'], sg['flags'], list(bt[c0:c1 + 1])))
        return sg, poked, bt


def nex_bank(nex, bank):
    # NEX v1.x: 512-byte header, banks stored 5,2,0,1,3,4,6.. when present
    with open(nex, 'rb') as f:
        d = f.read()
    if d[:4] != b'Next' or d[10] != 0:
        raise SystemExit('%s: not a screenless NEX' % nex)
    order = [5, 2, 0, 1, 3, 4] + list(range(6, 112))
    present = [b for b in order if d[18 + b]]
    if bank not in present:
        raise SystemExit('%s: bank %d absent' % (nex, bank))
    off = 512 + 16384 * present.index(bank)
    return d[off:off + 16384]


def dump(rows):
    for r in rows:
        if r.strip():
            print('  | ' + r)


def jump(r):
    r.typed('JUMP')
    hit, rows = r.wait_for(['P2 BOOT', 'P1 SWITCH F'], 40.0)
    print('screen after JUMP:')
    dump(rows)
    return hit


def case_control(r):
    sg, _, _ = r.boot_to_song()
    expect('partBanksMax absent', r.pbm() is None, 'symbol %s' % ('absent' if r.pbm() is None else 'present'))
    expect('song pages include bank 20', 20 in sg['banks'], 'banks %s' % sg['banks'])
    sg = r.song()                       # the cause, read right before JUMP
    b20 = r.bank_table()[20]
    hit = jump(r)
    expect('switch refused by the song holding bank 20',
           b20 == r.k['BT_USED'] and 20 in sg['banks'] and hit == 'P1 SWITCH F',
           'before JUMP bank 20 state %d, song banks %s; screen marker %s' % (b20, sg['banks'], hit))


def check_switch(r, sg):
    pbm = r.pbm()
    expect('partBanksMax 1', pbm == 1, 'read %s' % pbm)
    held = [b for b in sg['banks'] if 20 <= b < 20 + (pbm or 0)]
    expect('song loaded, no page in reserved pool C', sg['cnt'] > 0 and not held,
           '%d pages, banks %s, reserved 20..%d' % (sg['cnt'], sg['banks'], 19 + (pbm or 0)))
    hit = jump(r)
    part = r.rd('CURPART')[0]
    expect('switch reaches part 2', hit == 'P2 BOOT' and part == 2, 'marker %s, curPart %d' % (hit, part))
    live, a, b = r.stream_live()
    expect('stream live after switch', live, 'aysFlags bit 0 + position %s -> %s' % (a, b))
    return hit == 'P2 BOOT'


def case_switch(r):
    sg, _, _ = r.boot_to_song()
    check_switch(r, sg)


def saved_file(sd):
    """(name, size) of a non-empty SAVE_NAME.SAV on the card, else None."""
    for f in os.listdir(sd):
        if f.upper() == SAVE_NAME + '.SAV' and os.path.getsize(os.path.join(sd, f)):
            return f, os.path.getsize(os.path.join(sd, f))
    return None


def case_restore(r, sd):
    sg, _, _ = r.boot_to_song()
    if not check_switch(r, sg):
        return
    r.settle(2 * SECOND)
    r.typed('SAVE')
    hit, rows = r.wait_for(['Type in name'], 20.0)
    if not hit:
        dump(rows)
        expect('part 2 save written', False, 'no filename prompt')
        return
    r.typed(SAVE_NAME)
    try:
        saved = r.s.wait_until(lambda: saved_file(sd), SAVE_WAIT_S, POLL_S, SAVE_NAME + '.SAV')
    except TimeoutError:
        saved = None
    expect('part 2 save written', bool(saved),
           '%s %d B' % saved if saved else 'missing ' + SAVE_NAME + '.SAV')
    if not saved:
        return
    r.settle(SECOND)
    r.kill()
    print('relaunch: fresh boot on the same card')
    r.launch(sd)
    sg, _, _ = r.boot_to_song()
    pbm = r.pbm()
    held = [b for b in sg['banks'] if 20 <= b < 20 + (pbm or 0)]
    expect('fresh boot song avoids reserved pool C', sg['cnt'] > 0 and not held, 'banks %s' % sg['banks'])
    r.typed('LOAD')
    hit, rows = r.wait_for(['Type in name'], 20.0)
    if not hit:
        dump(rows)
        expect('LOAD lands in part 2', False, 'no filename prompt')
        return
    r.typed(SAVE_NAME)
    hit, rows = r.wait_for(['P2 ROOM', 'P1 LOAD F', 'I/O Error'], 40.0)
    print('screen after LOAD:')
    dump(rows)
    part = r.rd('CURPART')[0]
    expect('LOAD lands in part 2', hit == 'P2 ROOM' and part == 2, 'marker %s, curPart %d' % (hit, part))
    live, a, b = r.stream_live()
    print('info: stream live after LOAD %s (position %s -> %s)' % (live, a, b))


def claim_trace(r):
    return (r.rdz('AYSHDR', 16), int.from_bytes(r.rdz('SMPCLAIMTAB', 2), 'little'),
            r.rdz('SMPCLAIMBANKS')[0])


def case_focus5(r):
    pre = []
    sg, poked, bt = r.boot_to_song(pbm_poke=4, before_tap=lambda: pre.append(claim_trace(r)))
    c0, c1 = r.k['BANK_POOL_C'], r.k['BANK_POOL_C_END']
    with open(r.nex.replace('NEXTDAAD.NEX', '001.AYS'), 'rb') as f:
        hdr = f.read(16)
    tab = r.s.sym('AYSPAGETAB')
    post = claim_trace(r)
    fresh = pre[0][0] != hdr and pre[0][1] != tab
    expect('song opened and the claim ran',
           fresh and post[0] == hdr and post[1] == tab and post[2] == 2,
           'before: header %s, claim table $%04X; after: header %s, claim table $%04X, banks still owed %d'
           % (pre[0][0][:4], pre[0][1], post[0][:4], post[1], post[2]))
    expect('claim failed, no pages', sg['cnt'] == 0, 'aysPageCnt %d' % sg['cnt'])
    expect('stream not active', not sg['flags'] & 1, 'aysFlags $%02X' % sg['flags'])
    used = [c0 + i for i, b in enumerate(bt[c0:c1 + 1]) if b == r.k['BT_USED']]
    expect('no pool C bank BT_USED', not used, 'used %s' % used)
    diff = [i for i in range(len(bt)) if bt[i] != poked[i]]
    expect('bankTable unchanged by the failed claim', not diff, 'changed banks %s' % diff)


def main(card, mapf, port, case):
    run_dir = os.path.join(ROOT, 'tests', 'out', 'poolc', 'run-' + case)
    sd = os.path.join(run_dir, 'sd')
    if os.path.exists(sd):
        shutil.rmtree(sd)
    shutil.copytree(os.path.abspath(card), sd)
    print('case %s: card %s, map %s, port %s' % (case, os.path.abspath(card), mapf, port or 'first free'))
    r = Run(mapf, port or None)
    try:
        r.launch(sd)
        if case == 'control':
            case_control(r)
        elif case == 'switch':
            case_switch(r)
        elif case == 'restore':
            case_restore(r, sd)
        else:
            case_focus5(r)
    finally:
        r.kill()
    bad = [n for n, ok in results if not ok]
    print('%s: %d/%d expectations pass%s' % (case.upper(), len(results) - len(bad), len(results),
                                             '' if not bad else ' - FAIL ' + ', '.join(bad)))
    return 1 if bad or not results else 0


if __name__ == '__main__':
    if len(sys.argv) != 5 or sys.argv[4] not in ('control', 'switch', 'restore', 'focus5'):
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]))
