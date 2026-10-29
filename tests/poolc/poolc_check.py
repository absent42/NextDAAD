"""ZEsarUX check for the pool C part switch cards. Controller only.

python tests/poolc/poolc_check.py <card> <map> <port> <case>
  control  sd\\LEGPCC + main's map: song pages include bank 20, JUMP prints
           P1 SWITCH F
  switch   sd\\LEGPC + branch map: partBanksMax 1, no song page in
           20..20+max-1, JUMP reaches P2 BOOT with the stream still live
  restore  sd\\LEGPC: the switch case, SAVE PCSAVE in part 2, relaunch,
           song again, LOAD PCSAVE from part 1 lands in part 2 (P2 ROOM)
  focus5   sd\\LEGPC: partBanksMax poked to 4, the song claim fails with
           nothing held
Every case marks each BT_FREE bank outside pool C BT_USED at the P1 BOOT
pause. Runs on a scratch copy, tests/out/poolc/run-<case>/sd.
"""
import os, re, shutil, socket, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tests', 'parser'))
import zrcp, tilemap  # noqa: E402

ZESARUX = r'D:\ZXNextDev\ZEsarUX\zesarux.exe'
TM_MAP = 0x6000
ZONE0_RAM = 0x40000             # zone 0 = 2MB SRAM, RAM page 0 at 0x40000
SAVE_NAME = 'PCSAVE'
_MAP = re.compile(r'^([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+\S+\s+(\S+)\s*$')

results = []


def expect(name, ok, detail):
    results.append((name, ok))
    print('%s  %s: %s' % ('PASS' if ok else 'FAIL', name, detail))


def load_map(path):
    syms = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = _MAP.match(line)
            if m:
                syms[m.group(3)] = (int(m.group(1), 16), int(m.group(2), 16))
    return syms


class Run:
    def __init__(self, syms, port):
        self.s, self.port = syms, port
        self.k = {n: syms[n][0] for n in ('BT_FREE', 'BT_USED', 'BANK_POOL_C',
                                          'BANK_POOL_C_END', 'BANK_TABLE_SIZE')}

    def launch(self, sd):
        try:
            socket.create_connection(('127.0.0.1', self.port), timeout=0.5).close()
            raise SystemExit('port %d already answers: a stale emulator holds it' % self.port)
        except OSError:
            pass
        self.proc = subprocess.Popen([
            ZESARUX, '--machine', 'tbblue', '--realvideo',
            '--enable-esxdos-handler', '--esxdos-root-dir', sd,
            '--vo', 'null', '--ao', 'null',
            '--enable-remoteprotocol', '--remoteprotocol-port', str(self.port),
            '--smartloadpath', sd], cwd=sd)
        self.z = None
        for _ in range(60):
            if self.proc.poll() is not None:
                raise SystemExit('ZEsarUX died before ZRCP came up')
            try:
                self.z = zrcp.Zrcp(port=self.port)
                break
            except OSError:
                time.sleep(0.5)
        if self.z is None:
            raise SystemExit('ZRCP never came up')
        self.z.cmd('smartload %s' % os.path.join(sd, 'NEXTDAAD.NEX'), deadline=30.0)

    def kill(self):
        if getattr(self, 'z', None):
            try:
                self.z.close()
            except Exception:
                pass
            self.z = None
        if getattr(self, 'proc', None):
            self.proc.kill()
            self.proc.wait(timeout=10)
            self.proc = None

    def rd(self, name, n=1):
        return self.z.read_memory(self.s[name][0], n)

    def rdz(self, name, n=1):
        # banked symbol: zone 0 at its physical address
        self.z.cmd('set-memory-zone 0')
        try:
            return self.z.read_memory(ZONE0_RAM + self.s[name][1], n)
        finally:
            self.z.cmd('set-memory-zone -1')

    def wr(self, name, data):
        reply = self.z.cmd('write-memory-raw %d %s' % (self.s[name][0], data.hex().upper()))
        zrcp.check_error(reply)
        if self.rd(name, len(data)) != data:
            raise SystemExit('write to %s did not read back' % name)

    def screen(self):
        rows, _ = tilemap.decode(self.z.read_memory(TM_MAP, tilemap.GRID_BYTES))
        return [r.rstrip() for r in rows]

    def wait_for(self, needles, deadline):
        end, taps = time.monotonic() + deadline, 0
        while True:
            rows = self.screen()
            text = '\n'.join(rows)
            for n in needles:
                if n in text:
                    return n, rows
            if time.monotonic() > end:
                return None, rows
            if 'More...' in text and taps < 5:
                taps += 1
                self.z.tap_dismiss_key()
            time.sleep(0.5)

    def typed(self, line):
        self.z.send_keys(line)
        self.z.enter()

    def bank_table(self):
        return self.rd('BANKTABLE', self.k['BANK_TABLE_SIZE'])

    def zone_sanity(self):
        # resident bankTable sits in bank 2, so both views must agree
        if self.rdz('BANKTABLE', self.k['BANK_TABLE_SIZE']) != self.bank_table():
            raise SystemExit('zone 0 view of bankTable disagrees: ZONE0_RAM offset wrong')

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
        return self.rd('PARTBANKSMAX')[0] if 'PARTBANKSMAX' in self.s else None

    def stream_live(self):
        a = self.pos()
        time.sleep(1.0)
        b = self.pos()
        return bool(self.rdz('AYSFLAGS')[0] & 1) and a != b, a, b

    def boot_to_song(self, pbm_poke=None):
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
        self.z.tap_dismiss_key()
        hit, rows = self.wait_for(['P1 SONG ON'], 30.0)
        if not hit:
            dump(rows)
            raise SystemExit('part 1 never printed P1 SONG ON')
        time.sleep(1.0)
        sg = self.song()
        bt = self.bank_table()
        c0, c1 = self.k['BANK_POOL_C'], self.k['BANK_POOL_C_END']
        print('song: %d pages, banks %s, aysFlags $%02X, pool C states %s'
              % (sg['cnt'], sg['banks'], sg['flags'], list(bt[c0:c1 + 1])))
        return sg, poked, bt


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
    hit = jump(r)
    expect('switch refused', hit == 'P1 SWITCH F', 'screen marker %s' % hit)


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


def case_restore(r, sd):
    sg, _, _ = r.boot_to_song()
    if not check_switch(r, sg):
        return
    time.sleep(2.0)
    r.typed('SAVE')
    hit, rows = r.wait_for(['Type in name'], 20.0)
    if not hit:
        dump(rows)
        expect('part 2 save written', False, 'no filename prompt')
        return
    r.typed(SAVE_NAME)
    path = os.path.join(sd, SAVE_NAME + '.SAV')
    end = time.monotonic() + 10.0
    while time.monotonic() < end and not any(f.upper() == SAVE_NAME + '.SAV' for f in os.listdir(sd)):
        time.sleep(0.5)
    saved = [f for f in os.listdir(sd) if f.upper() == SAVE_NAME + '.SAV']
    expect('part 2 save written', bool(saved),
           '%s %d B' % (saved[0], os.path.getsize(os.path.join(sd, saved[0]))) if saved else 'missing ' + path)
    if not saved:
        return
    time.sleep(1.0)
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


def case_focus5(r):
    sg, poked, bt = r.boot_to_song(pbm_poke=4)
    c0, c1 = r.k['BANK_POOL_C'], r.k['BANK_POOL_C_END']
    expect('claim failed, no pages', sg['cnt'] == 0, 'aysPageCnt %d' % sg['cnt'])
    expect('stream not active', not sg['flags'] & 1, 'aysFlags $%02X' % sg['flags'])
    used = [c0 + i for i, b in enumerate(bt[c0:c1 + 1]) if b == r.k['BT_USED']]
    expect('no pool C bank BT_USED', not used, 'used %s' % used)
    diff = [i for i in range(len(bt)) if bt[i] != poked[i]]
    expect('bankTable unchanged by the failed claim', not diff, 'changed banks %s' % diff)


def main(card, mapf, port, case):
    syms = load_map(mapf)
    run_dir = os.path.join(ROOT, 'tests', 'out', 'poolc', 'run-' + case)
    sd = os.path.join(run_dir, 'sd')
    if os.path.exists(sd):
        shutil.rmtree(sd)
    shutil.copytree(os.path.abspath(card), sd)
    print('case %s: card %s, map %s, port %d' % (case, os.path.abspath(card), mapf, port))
    r = Run(syms, port)
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
