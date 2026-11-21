# Positioned-picture (NX3) fixture art, and the expected Layer 2 FRONT
# surface after every step of the fixture walk (tests/l2pos.dsf).
#
#   mkl2pos.py <outdir> [--mode 0|1]   001/008/010.NXI|NX2, 002-007, 009,
#                                      011.NX3, expect_<id>.bin,
#                                      l2pos_tags.txt, l2pos_walk.json
#   mkl2pos.py <outdir> --png [--mode 0|1]
#                                      indexed PNGs + sidecars 001-006
#
# WALK is the single step list: the fixture runs each step's condacts
# verbatim, the model below replays the same strings, the checker reads
# the json. Steps 10/10a reach the fallback stream through the DEBUG-only
# GFX n 28 (pool reported dry); steps 12-12b scroll text windows and are
# also compared against tests/l2pos_tm/tm_<id>.bin (tilemap rows 0-27,
# captured once with l2pos_check.py --capture).
#
# Model (overlay2 gfx_blit / gfx_blit_pos / h_display / h_gfx): two raw
# 10-page surfaces; mode 0 row-major y*256+x, mode 1 column-major x*256+y;
# clears and copies size by l2Mode (6 or 10 pages); bytes never written
# are UNKNOWN and an expect file may not contain one.

import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkl2holes as H          # FONT, pack0
import mkanisheets as A        # write_png, write_txt

TRANSP = 255
PAGE = 8192
SURF_BYTES = 10 * PAGE

# --- glyphs: mkl2holes FONT plus the letters the labels need -------
FONT = dict(H.FONT)
FONT.update({
    'C': ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    '1': ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    'U': ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    'D': ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    'F': ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    'B': ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
})
PLAIN = (1, 8, 10)             # .NXI/.NX2 files; the rest are NX3
RAW_ONLY = (10, 11)            # fallback-stream pictures: never ZX0

# --- palette (RGB333) ----------------------------------------------
RANGES = {'loc': (0, 100), 'hud': (101, 150), 'tilea': (151, 200), 'tileb': (201, 250)}


def palette_full():
    pal = {}
    for i in range(0, 101):
        pal[i] = (i * 7 // 100, i * 7 // 100, min(7, 2 + i * 5 // 100))
    for i in range(101, 151):
        pal[i] = (7, 7 - (i - 101) * 7 // 50, 0)
    for i in range(151, 201):
        pal[i] = (7, (i - 151) * 3 // 50, (i - 151) * 3 // 50)
    for i in range(201, 251):
        pal[i] = ((i - 201) * 3 // 50, 7, (i - 201) * 3 // 50)
    pal[TRANSP] = (7, 0, 7)
    return pal


def palette_loc2():
    # sepia location set so applying 002's range is visible; entry 0
    # matches 001's (the kit selftest compares palette byte 0)
    full = palette_full()
    pal = {0: full[0]}
    for i in range(1, 101):
        pal[i] = (min(7, 1 + i * 6 // 100), i * 5 // 100, i * 2 // 100)
    return pal


def file_palette(n):
    """Per-file palette: the declared range coloured, the rest black."""
    full = palette_full()
    pf, pl = PICS[n]['pal']
    src = palette_loc2() if n == 2 else full
    pal = {i: (0, 0, 0) for i in range(256)}
    for i in range(pf, pl + 1):
        pal[i] = src.get(i, (0, 0, 0))
    pal[TRANSP] = full[TRANSP]
    return pal


def pal_bytes(pal):
    out = bytearray()
    for i in range(256):
        r, g, b = pal[i]
        first = H.pack0((r, g, b))
        assert first != 0xE3 or i == TRANSP, "entry %d packs to $E3 (dodge case)" % i
        out += bytes([first, b & 1])
    return bytes(out)


def rgb888(pal):
    ex = lambda c: (c << 5) | (c << 2) | (c >> 1)
    return [tuple(ex(c) for c in pal[i]) for i in range(256)]


# --- pictures --------------------------------------------------------
# w None = surface width. ink = the index range the pixels use (005 has
# palette none and borrows 006's greens). hole = 2x2 index-255 notch:
# transparent source pixels overwrite whatever is under them.
PICS = {
    1: dict(w=None, h=96, fl=False, x=0, y=0, pal=(0, 255), ink=(0, 100),
            fill=(40, 30), frame=90, lab=95, text='LOC1', scale=3, hole=None),
    2: dict(w=None, h=96, fl=False, x=0, y=0, pal=(0, 100), ink=(0, 100),
            fill=(60, 70), frame=90, lab=10, text='LOC2', scale=3, hole=None),
    3: dict(w=64, h=32, fl=False, x=192, y=160, pal=(151, 200), ink=(151, 200),
            fill=(160, 170), frame=195, lab=199, text='TA', scale=3, hole=(59, 2)),
    4: dict(w=None, h=32, fl=False, x=0, y=96, pal=(101, 150), ink=(101, 150),
            fill=(120, 130), frame=145, lab=101, text='HUD', scale=3, hole=None),
    5: dict(w=64, h=32, fl=True, x=0, y=0, pal=(1, 0), ink=(201, 250),
            fill=(220, 230), frame=245, lab=249, text='FLT', scale=3, hole=None),
    6: dict(w=32, h=32, fl=False, x=8, y=160, pal=(201, 250), ink=(201, 250),
            fill=(210, 215), frame=240, lab=250, text='TB', scale=2, hole=(28, 2)),
    # h None = surface height (320x256: height byte 0; rows 224+ are
    # index 255 so the text window below stays visible on a real screen)
    8: dict(w=None, h=None, fl=False, x=0, y=0, pal=(0, 255), ink=(0, 100),
            fill=(10, 80), frame=100, lab=0, text='FULL', scale=3, hole=None),
    # 100 bytes wide: row 158 straddles the first cache bank
    9: dict(w=100, h=180, fl=False, x=40, y=8, pal=(101, 150), ink=(101, 150),
            fill=(105, 140), frame=150, lab=101, text='TALL', scale=3, hole=None),
    10: dict(w=None, h=96, fl=False, x=0, y=0, pal=(0, 255), ink=(0, 100),
             fill=(25, 75), frame=5, lab=99, text='FB1', scale=3, hole=None),
    11: dict(w=64, h=32, fl=False, x=100, y=100, pal=(151, 200), ink=(151, 200),
             fill=(155, 185), frame=200, lab=151, text='FB2', scale=2, hole=(59, 2)),
}
TEXT_TOP = 224                 # pixel row of text window 0 on the 320x256 surface


def draw_label(px, text, idx, scale):
    gw, gap = 5 * scale, scale
    tw, th = len(text) * (gw + gap) - gap, 7 * scale
    w, h = len(px[0]), len(px)
    left, top = (w - tw) // 2, (h - th) // 2
    # one clear pixel between label and frame on every side
    assert left >= 2 and top >= 2 and left + tw <= w - 2 and top + th <= h - 2, \
        "label %r (%dx%d) does not fit inside a %dx%d frame" % (text, tw, th, w, h)
    x = left
    for ch in text:
        g = FONT[ch]
        for gy in range(7):
            for gx in range(5):
                if g[gy][gx] == '1':
                    for sy in range(scale):
                        for sx in range(scale):
                            px[top + gy * scale + sy][x + gx * scale + sx] = idx
        x += gw + gap
    return (left, top, left + tw - 1, top + th - 1)


def pic_h(n, sw):
    return PICS[n]['h'] or (256 if sw == 320 else 192)


def picture(n, sw):
    p = PICS[n]
    w, h = p['w'] or sw, pic_h(n, sw)
    f0, f1 = p['fill']
    # 8x8 checker: any one-pixel shift breaks a block edge
    px = [[f0 if ((x >> 3) + (y >> 3)) & 1 == 0 else f1 for x in range(w)] for y in range(h)]
    for x in range(w):
        px[0][x] = px[h - 1][x] = p['frame']
    for y in range(h):
        px[y][0] = px[y][w - 1] = p['frame']
    box = draw_label(px, p['text'], p['lab'], p['scale'])
    if p['hole']:
        hx, hy = p['hole']
        assert hx + 1 < box[0] or hx > box[2] or hy + 1 < box[1] or hy > box[3], "hole on the label"
        assert 1 <= hx and hx + 1 <= w - 2 and 1 <= hy and hy + 1 <= h - 2, "hole on the frame"
        for yy in (hy, hy + 1):
            for xx in (hx, hx + 1):
                px[yy][xx] = TRANSP
    if p['h'] is None and h > TEXT_TOP:
        for yy in range(TEXT_TOP, h):
            px[yy] = [TRANSP] * w
    lo, hi = p['ink']
    for row in px:
        for v in row:
            assert v == TRANSP or lo <= v <= hi, "picture %d pixel %d outside %d-%d" % (n, v, lo, hi)
    return px


def flat(px):
    return bytes(b for row in px for b in row)


def nx3_header(mode, floating, x, y, w, h, pf, pl):
    return (b'NX3' + bytes([1, mode, 1 if floating else 0]) + struct.pack('<H', x)
            + bytes([y]) + struct.pack('<H', w) + bytes([h & 255, pf, pl, 0, 0]))


def plain_name(mode, n=1):
    return '%03d.' % n + ('NX2' if mode else 'NXI')


def build(mode):
    sw = 320 if mode else 256
    files, pics = {}, {}
    for n, p in PICS.items():
        px = picture(n, sw)
        pics[n] = px
        body = pal_bytes(file_palette(n)) + flat(px)
        if n in PLAIN:
            files[plain_name(mode, n)] = body
        else:
            w = p['w'] or sw
            files['%03d.NX3' % n] = nx3_header(mode, p['fl'], p['x'], p['y'], w, p['h'], *p['pal']) + body
    # 007: 006's bytes with the other mode byte (R3 mode switch)
    p = PICS[6]
    files['007.NX3'] = nx3_header(1 - mode, False, p['x'], p['y'], p['w'], p['h'], *p['pal']) + files['006.NX3'][16:]
    pics[7] = pics[6]
    return files, pics


def decode_back(files, mode):
    """Re-read every file from its bytes: header, length, pixel ranges."""
    sw, sh = (320, 256) if mode else (256, 192)
    for name, data in sorted(files.items()):
        if not name.endswith('.NX3'):
            pn = int(name[:3])
            assert (len(data) - 512) % sw == 0 and (len(data) - 512) // sw == pic_h(pn, sw), name
            pix, (lo, hi), pmode = data[512:], PICS[pn]['ink'], mode
        else:
            n = int(name[:3])
            p = PICS[6 if n == 7 else n]
            pmode = 1 - mode if n == 7 else mode
            assert data[:4] == b'NX3\x01', name
            assert data[4] == pmode, name
            assert data[5] == (1 if p['fl'] else 0), name
            x, y = struct.unpack('<H', data[6:8])[0], data[8]
            w, h = struct.unpack('<H', data[9:11])[0], data[11] or 256
            assert (x, y) == (p['x'], p['y']) and h == p['h'], name
            assert w == (p['w'] or sw), name
            assert (data[12], data[13]) == p['pal'] and data[14:16] == b'\0\0', name
            assert len(data) == 16 + 512 + w * h, "%s length %d" % (name, len(data))
            psw, psh = (320, 256) if pmode else (256, 192)
            if not p['fl']:
                assert x + w <= psw and y + h <= psh, "%s does not fit its screen" % name
            pix, (lo, hi) = data[528:], p['ink']
        bad = [v for v in set(pix) if v != TRANSP and not lo <= v <= hi]
        assert not bad, "%s pixels %r outside %d-%d" % (name, bad, lo, hi)
        print("  %-8s %6d bytes  mode %d" % (name, len(data), pmode))


# --- the walk ------------------------------------------------------
# Condacts are run verbatim by the fixture and replayed by Model.run.
# The fixture adds only text condacts (MES, CLS, MODE, INK, PAPER) and
# its step counter; it must not CLS or touch Layer 2 otherwise.
WALK = [
    ('1', 'STEP 1 LOC1+TA ',
     ['PICTURE 1', 'DISPLAY 0', 'PICTURE 1', 'DISPLAY 0', 'PICTURE 3', 'DISPLAY 0'],
     'plain LOC1 twice (both surfaces known), TA at 192,160'),
    ('1b', 'STEP 1B TB ', ['PICTURE 6', 'DISPLAY 0'],
     'TB at 8,160'),
    ('2', 'STEP 2 LOC2 ', ['PICTURE 2', 'DISPLAY 0'],
     'NX3 LOC2 over rows 0-95, TA and TB kept'),
    ('2b', 'STEP 2B HUD ', ['PICTURE 4', 'DISPLAY 0'],
     'HUD rows 96-127'),
    ('3', 'STEP 3 WINDOW ',
     ['WINDOW 1', 'WINAT 20 16', 'WINSIZE 4 16', 'PICTURE 5', 'DISPLAY 0', 'WINDOW 0'],
     'FLT at window 1: mode 0 32,128; mode 1 64,160'),
    ('3b', 'STEP 3B ORIGIN ',
     ['WINDOW 2', 'WINAT 0 0', 'WINSIZE 4 16', 'PICTURE 5', 'DISPLAY 0', 'WINDOW 0'],
     'FLT at window 2: mode 0 -32,-32 nothing; mode 1 0,0'),
    ('3c', 'STEP 3C PART CLIP ',
     ['WINDOW 2', 'WINAT 2 4', 'WINSIZE 4 16', 'PICTURE 5', 'DISPLAY 0', 'WINDOW 0'],
     'FLT at window 2: mode 0 -16,-16 (source cols 16-63 rows 16-31 at 0,0, cuts the F); mode 1 16,16'),
    ('4', 'STEP 4 OVERRIDE ', ['GFX 20 8', 'GFX 64 15', 'PICTURE 6', 'DISPLAY 0'],
     'TB at 160,64 (its notch overwrites LOC2)'),
    ('4b', 'STEP 4B PLAIN AT ', ['GFX 8 8', 'GFX 0 15', 'PICTURE 1', 'DISPLAY 0'],
     'plain LOC1 at 64,0, right edge clipped'),
    ('4c', 'STEP 4C OFF EDGE ', ['GFX 39 8', 'PICTURE 6', 'DISPLAY 0'],
     'X 312: mode 0 nothing; mode 1 8 columns at 312,0'),
    ('4d', 'STEP 4D CANCEL ', ['GFX 20 8', 'GFX 0 27', 'PICTURE 6', 'DISPLAY 0'],
     'cancelled: TB at 8,160 again (no change)'),
    ('5', 'STEP 5 BUFFER ', ['GFX 0 4', 'GFX 16 8', 'GFX 128 15', 'PICTURE 3', 'DISPLAY 0'],
     'TA into the back at 128,128: front unchanged'),
    ('5a', 'STEP 5A SHOW ', ['GFX 0 0'],
     'back copied to front: TA at 128,128'),
    ('5b', 'STEP 5B SWAP ', ['GFX 4 8', 'GFX 64 15', 'PICTURE 6', 'DISPLAY 0', 'GFX 0 2', 'GFX 0 3'],
     'TB into the back at 32,64, swap shows it; screen mode again'),
    ('6', 'STEP 6 CLEAR ', ['GFX 0 7', 'DISPLAY 1'],
     'both surfaces transparent'),
    ('7', 'STEP 7 MODE ', ['PICTURE 7', 'DISPLAY 0'],
     'other-mode NX3: both cleared, mode switched, TB at 8,160'),
    ('8', 'STEP 8 FULL ', ['PICTURE 8', 'DISPLAY 0'],
     'plain full-surface FULL, back in the set mode'),
    ('8a', 'STEP 8A SHORT ', ['PICTURE 1', 'DISPLAY 0'],
     'plain LOC1 after a full picture: clear below row 95'),
    ('8b', 'STEP 8B FRONT TO BACK ', ['GFX 0 1', 'GFX 0 2'],
     'front copied to back, then swapped: no visible change'),
    ('9', 'STEP 9 TALL ', ['PICTURE 9', 'DISPLAY 0'],
     'NX3 TALL 100x180 at 40,8'),
    ('10', 'STEP 10 FALLBACK ', ['GFX 1 28', 'PICTURE 10', 'GFX 0 28'],
     'no bank free: plain FB1 streamed from the card, rest clear'),
    ('10a', 'STEP 10A FALLBACK POS ', ['GFX 1 28', 'PICTURE 11', 'GFX 0 28'],
     'no bank free: NX3 FB2 streamed to 100,100'),
    ('11', 'STEP 11 CLEAR ', ['GFX 0 7', 'DISPLAY 1'],
     'both surfaces transparent'),
    ('12', 'STEP 12 SCROLL WIDE ', ['PROCESS 5'],
     'window rows 0-7 x 80 columns scrolled 3 times'),
    ('12a', 'STEP 12A SCROLL NARROW ', ['PROCESS 6'],
     'window rows 10-17, columns 30-49 scrolled 3 times'),
    ('12b', 'STEP 12B SCROLL ROW ', ['PROCESS 7'],
     'one-row window at row 20: blanked by its scroll'),
]
TM_STEPS = ('12', '12a', '12b')


class Model:
    def __init__(self, pics, set_mode):
        self.pics, self.set_mode = pics, set_mode
        self.surf = [bytearray(SURF_BYTES), bytearray(SURF_BYTES)]
        self.known = [bytearray(SURF_BYTES), bytearray(SURF_BYTES)]
        self.front = 0
        self.l2mode = 0                  # boot l2Mode
        self.target = 0                  # GFX 0 3 / 0 4
        self.ovr = None                  # [x, y] while armed
        self.staged = None
        self.wins = {0: [28, 0, 4, 80]}  # row, col, height, width
        self.cur = 0
        self.nobank = 0                  # GFX n 28 (DEBUG)
        self.cached = set()

    def pmode(self, n):
        return 1 - self.set_mode if n == 7 else self.set_mode

    def clear(self, s):
        n = (10 if self.l2mode else 6) * PAGE
        self.surf[s][:n] = bytes([TRANSP]) * n
        self.known[s][:n] = b'\1' * n

    def put(self, s, x, y, v):
        o = x * 256 + y if self.l2mode else y * 256 + x
        self.surf[s][o] = v
        self.known[s][o] = 1

    def paint(self, surfaces, n, x, y, w, h):
        sw, sh = (320, 256) if self.l2mode else (256, 192)
        px = self.pics[n]
        for r in range(h):
            for c in range(w):
                dx, dy = x + c, y + r
                if 0 <= dx < sw and 0 <= dy < sh:
                    for s in surfaces:
                        self.put(s, dx, dy, px[r][c])

    def back(self):
        return 1 - self.front

    def display0(self):
        n = self.staged
        assert n is not None, "DISPLAY 0 with nothing staged"
        p = PICS[6 if n == 7 else n]
        sw = 320 if self.pmode(n) else 256
        w, h = p['w'] or sw, p['h'] or (256 if sw == 320 else 192)
        if n in PLAIN and self.ovr is None:
            # gfx_blit: mode commit, clear a short back, render, flip
            self.l2mode = self.pmode(n)
            if h < (256 if self.l2mode else 192):
                self.clear(self.back())
            self.paint([self.back()], n, 0, 0, w, h)
            if self.target == 0:
                self.front = self.back()
            return
        # gfx_blit_pos: R3 mode check, resolve, clip, write, consume
        if self.pmode(n) != self.l2mode:
            assert self.target == 0, "buffer-mode mismatch is not in the walk"
            self.l2mode = self.pmode(n)
            self.clear(0)
            self.clear(1)
        if n in PLAIN:
            x, y = 0, 0                  # plain under override: full size
        else:
            x, y = p['x'], p['y']
        if self.ovr is not None:
            x, y = self.ovr
        elif p['fl']:
            cw = 4                       # 80-column text (8 in 40-column)
            row, col, wh, ww = self.wins[self.cur]
            x, y = col * cw, row * 8
            w, h = min(w, ww * cw), min(h, wh * 8)
            if self.l2mode == 0:
                x, y = x - 32, y - 32
        surfaces = [self.back()] if self.target else [0, 1]
        self.paint(surfaces, n, x, y, w, h)
        self.ovr = None

    def run(self, condact):
        op, *a = condact.split()
        a = [int(v) for v in a]
        if op == 'PICTURE':
            n = a[0]
            if self.nobank and n not in self.cached:
                # gfx_load's fallback: drawn at once, nothing cached or staged
                assert self.target == 0 and self.ovr is None, "fallback outside the walk's shape"
                self.staged = None
                p = PICS[n]
                sw = 320 if self.pmode(n) else 256
                w, h = p['w'] or sw, p['h'] or (256 if sw == 320 else 192)
                if n in PLAIN:           # gfx_direct_stream: clear back, rows, flip
                    self.l2mode = self.pmode(n)
                    self.clear(self.back())
                    self.paint([self.back()], n, 0, 0, w, h)
                    self.front = self.back()
                else:                    # gfx_direct_stream_pos: both surfaces
                    assert self.pmode(n) == self.l2mode
                    self.paint([0, 1], n, p['x'], p['y'], w, h)
                return
            self.staged = n
            self.cached.add(n)
        elif op == 'PROCESS':
            pass                         # text only (the scroll steps)
        elif op == 'DISPLAY':
            if a[0] == 0:
                self.display0()
            else:
                self.clear(self.back())
                self.ovr = None
                if self.target == 0:
                    self.front = self.back()
        elif op == 'WINDOW':
            self.cur = a[0]
            self.wins.setdefault(a[0], [0, 0, 32, 80])
        elif op == 'WINAT':
            self.wins[self.cur][0:2] = a
        elif op == 'WINSIZE':
            self.wins[self.cur][2:4] = a
        elif op == 'GFX':
            p1, sub = a
            if sub == 0:
                n = (10 if self.l2mode else 6) * PAGE
                self.surf[self.front][:n] = self.surf[self.back()][:n]
                self.known[self.front][:n] = self.known[self.back()][:n]
            elif sub == 1:
                n = (10 if self.l2mode else 6) * PAGE
                self.surf[self.back()][:n] = self.surf[self.front][:n]
                self.known[self.back()][:n] = self.known[self.front][:n]
            elif sub == 28:
                self.nobank = p1
            elif sub == 2:
                self.front = self.back()
            elif sub in (3, 4):
                self.target = sub - 3
            elif sub == 5:
                self.clear(self.front)
            elif sub == 6:
                self.clear(self.back())
            elif sub == 7:
                self.clear(0)
                self.clear(1)
            elif sub == 8:
                self.ovr = [p1 * 8, self.ovr[1] if self.ovr else 0]
            elif sub == 15:
                self.ovr = [self.ovr[0] if self.ovr else 0, p1]
            elif sub == 27:
                self.ovr = None
            else:
                raise AssertionError("GFX sub %d not modelled" % sub)
        else:
            raise AssertionError("condact %r not modelled" % condact)

    def front_bytes(self, sid):
        n = (10 if self.l2mode else 6) * PAGE
        assert all(self.known[self.front][:n]), "step %s: front holds unknown bytes" % sid
        return bytes(self.surf[self.front][:n])


WALK_IDS = [w[0] for w in WALK]


def surface_bytes(mode, rects):
    """Independent painter: (x, y, px) rects onto a transparent surface."""
    sw, sh = (320, 256) if mode else (256, 192)
    surf = [[TRANSP] * sw for _ in range(sh)]
    for x, y, px in rects:
        for yy, row in enumerate(px):
            for xx, v in enumerate(row):
                if 0 <= x + xx < sw and 0 <= y + yy < sh:
                    surf[y + yy][x + xx] = v
    if mode == 0:
        return b''.join(bytes(r) for r in surf)
    return bytes(surf[y][x] for x in range(sw) for y in range(sh))


def replay(pics, mode):
    m = Model(pics, mode)
    out = []
    for i, (sid, text, condacts, shows) in enumerate(WALK):
        for c in condacts:
            m.run(c)
        out.append(dict(id=sid, fstep=None if i == 0 else i - 1, text=text,
                        condacts=condacts, shows=shows, mode=m.l2mode,
                        expect='expect_%s.bin' % sid, data=m.front_bytes(sid)))
    by = {s['id']: s['data'] for s in out}
    # independent replay: hand-placed cumulative rects per step, no model
    m0 = mode == 0
    adds = {
        '1': [(0, 0, 1), (192, 160, 3)], '1b': [(8, 160, 6)], '2': [(0, 0, 2)],
        '2b': [(0, 96, 4)], '3': [(32, 128, 5) if m0 else (64, 160, 5)],
        '3b': [] if m0 else [(0, 0, 5)], '3c': [(-16, -16, 5) if m0 else (16, 16, 5)],
        '4': [(160, 64, 6)], '4b': [(64, 0, 1)], '4c': [] if m0 else [(312, 0, 6)],
        '4d': [(8, 160, 6)], '5': [], '5a': [(128, 128, 3)], '5b': [(32, 64, 6)],
    }
    rects = []
    for s in out[:WALK_IDS.index('6')]:
        rects += [(x, y, pics[n]) for x, y, n in adds[s['id']]]
        assert by[s['id']] == surface_bytes(mode, rects), "step %s differs from the independent replay" % s['id']
    # the walk's claims
    assert by['1b'] != by['1'] and by['2'] != by['1b'] and by['2b'] != by['2']
    assert by['3'] != by['2b'] and by['3c'] != by['3b']
    assert (by['3b'] == by['3']) == m0, "3b: mode 0 draws nothing, mode 1 draws at 0,0"
    assert (by['4c'] == by['4b']) == m0, "4c: mode 0 off-surface, mode 1 eight columns"
    assert by['4d'] == by['4c'] and by['5'] == by['4d']
    assert by['5a'] != by['5'] and by['5b'] != by['5a']
    md = {s['id']: s['mode'] for s in out}
    assert by['6'] == bytes([TRANSP]) * len(by['6'])
    assert md['7'] == 1 - mode
    assert by['7'] == surface_bytes(1 - mode, [(8, 160, pics[6])])
    assert all(md[i] == mode for i in WALK_IDS[WALK_IDS.index('8'):])
    assert by['8'] == surface_bytes(mode, [(0, 0, pics[8])])
    assert by['8a'] == surface_bytes(mode, [(0, 0, pics[1])]) and by['8b'] == by['8a']
    assert by['9'] == surface_bytes(mode, [(0, 0, pics[1]), (40, 8, pics[9])])
    assert by['10'] == surface_bytes(mode, [(0, 0, pics[10])])
    assert by['10a'] == surface_bytes(mode, [(0, 0, pics[10]), (100, 100, pics[11])])
    for i in ('11',) + TM_STEPS:
        assert by[i] == bytes([TRANSP]) * len(by[i])
    for s in out:
        if s['id'] in TM_STEPS:
            s['tm'] = 'tm_%s.bin' % s['id']
    return out


def files_nx3():
    return ['%03d.NX3' % n for n in list(PICS) + [7] if n not in PLAIN]


def write_expect(outdir, mode, pics):
    steps = replay(pics, mode)
    tags = []
    for s in steps:
        with open(os.path.join(outdir, s['expect']), 'wb') as f:
            f.write(s['data'])
        tags.append("%s\t%d\t%s\t%s" % (s['id'], s['mode'], s['expect'], s['shows']))
        del s['data']
    with open(os.path.join(outdir, 'l2pos_tags.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(tags) + '\n')
    with open(os.path.join(outdir, 'l2pos_walk.json'), 'w', newline='\n') as f:
        json.dump(dict(set_mode=mode, plain=[plain_name(mode, n) for n in PLAIN],
                       nx3=sorted(n for n in files_nx3()), raw_only=['%03d' % n for n in RAW_ONLY],
                       steps=steps), f, indent=1)
    return steps


def write_png_set(outdir, mode, pics):
    sw = 320 if mode else 256
    for n in range(1, 7):
        p, px = PICS[n], pics[n]
        path = os.path.join(outdir, '%03d.png' % n)
        A.write_png(path, p['w'] or sw, p['h'], rgb888(file_palette(n)), px)
        print("  %s %dx%d" % (os.path.basename(path), p['w'] or sw, p['h']))
        if n == 1:
            continue
        pf, pl = p['pal']
        A.write_txt(os.path.join(outdir, '%03d.txt' % n),
                    at='window' if p['fl'] else '%d,%d' % (p['x'], p['y']),
                    palette='none' if (pf, pl) == (1, 0) else '%d-%d' % (pf, pl))


def main(argv):
    args = list(argv)
    png = '--png' in args
    if png:
        args.remove('--png')
    mode = 0
    if '--mode' in args:
        i = args.index('--mode')
        mode = int(args[i + 1])
        del args[i:i + 2]
    assert mode in (0, 1) and len(args) == 1, "usage: mkl2pos.py <outdir> [--png] [--mode 0|1]"
    outdir = args[0]
    os.makedirs(outdir, exist_ok=True)
    files, pics = build(mode)
    if png:
        write_png_set(outdir, mode, pics)
        return 0
    decode_back(files, mode)
    for name, data in files.items():
        with open(os.path.join(outdir, name), 'wb') as f:
            f.write(data)
    for s in write_expect(outdir, mode, pics):
        print("  step %-3s mode %d  %-20s %s" % (s['id'], s['mode'], ' / '.join(s['condacts'])[:60], s['shows']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
