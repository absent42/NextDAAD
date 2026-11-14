import re
import subprocess
from pathlib import Path

import parse
from tags import TAGS

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
BENCH = HERE / "bench"
NEX = ROOT / "build" / "core303" / "CORE303.NEX"
ROW_TAG = re.compile(r'ROW\s+"(\w{4})"')
DB_STR = re.compile(r'^(\w+):\s+db\s+"([^"]*)",\s*0\s*(?:;.*)?$', re.M)
D_ROW = re.compile(r'^\s*(\w*ROW)\s+"(D\w{3})"\s*,([^;\n]*)', re.M)
DMAINIT_DEF = re.compile(r'^(dmainit_\w+):\s*(?:;.*)?$')


def build():
    return subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(BENCH / "build.ps1"), "-AllowDirty"],
        capture_output=True, text=True, timeout=180)


def test_bench_assembles():
    res = build()
    out = res.stdout + res.stderr
    assert res.returncode == 0, out
    assert NEX.is_file(), out
    assert "error" not in out.lower(), out
    m = re.search(r"^stamp: (\S+)$", out, re.M)
    assert m, out
    assert m.group(1).encode("ascii") in NEX.read_bytes()


def test_tags_known():
    found = []
    for p in sorted(BENCH.glob("*.asm")):
        found += ROW_TAG.findall(p.read_text(encoding="ascii"))
    assert {"CAL0", "CAL1"} <= set(found)
    for tag in found:
        assert tag in TAGS, tag


def _first_instr(lines, k):
    """First instruction after the label on line k: comments and blanks skipped."""
    for line in lines[k + 1:]:
        code = line.split(";")[0].strip()
        if code:
            return " ".join(code.lower().split())
    return None


def test_dma_rows_reset():
    """Every D row is a plain ROW whose init (7th param) is a dmainit_ label, and
    every dmainit_ routine starts with call dma_reset."""
    srcs = {p.name: p.read_text(encoding="ascii") for p in sorted(BENCH.glob("*.asm"))}
    rows = [m for text in srcs.values() for m in D_ROW.findall(text)]
    assert {"D0DT", "D0CP"} <= {tag for _, tag, _ in rows}
    used = set()
    for mac, tag, rest in rows:
        assert mac == "ROW", "%s: D rows must use ROW, not %s" % (tag, mac)
        params = [p.strip() for p in rest.split(",")]
        assert len(params) == 8, (tag, params)
        assert re.fullmatch(r"dmainit_\w+", params[5]), (tag, params[5])
        used.add(params[5])
    defs = {}
    for text in srcs.values():
        lines = text.splitlines()
        for k, line in enumerate(lines):
            m = DMAINIT_DEF.match(line)
            if m:
                assert m.group(1) not in defs, m.group(1)
                defs[m.group(1)] = _first_instr(lines, k)
    assert used <= set(defs), sorted(used - set(defs))
    for name, first in defs.items():
        assert first == "call dma_reset", (name, first)


def _strings():
    out = {}
    for name in ("log.asm", "dma.asm"):
        p = BENCH / name
        if p.is_file():
            out.update(DB_STR.findall(p.read_text(encoding="ascii")))
    return out


def test_log_format_parses(tmp_path):
    """A log built from log.asm's own strings, in run_table's field order."""
    s = _strings()
    nr = [(0x01, 0x03), (0x0E, 0x00), (0x0F, 0x03), (0x03, 0x30), (0x05, 0x00), (0x07, 0x33)]

    def row(tag, sp, r, f, d, n, ck=None, q=None, lat=None):
        out = tag + s["logTxtCW"] + str(sp)
        out += s["logTxtR"] + "%04X" % r + s["logTxtF"] + "%04X" % f
        out += s["logTxtD"] + "%04X" % (d & 0xFFFF) + s["logTxtN"] + "%04X" % n
        if q is not None:
            out += s["logTxtQ"] + "%d%d%d" % q
        if ck is not None:
            out += s["logTxtCK"] + "%04X" % ck[0] + (s["logTxtOK"] if ck[1] else s["logTxtBAD"])
        if lat is not None:
            out += s["logTxtL"] + "%02X" % lat
        return out + "\n"

    text = s["logTxtHdr"] + "abc1234" + "\n"
    text += s["logTxtNr"] + "".join(" %02X=%02X" % kv for kv in nr) + "\n"
    text += s["logTxtSram"] + s["logTxtKb2"] + "\n"
    text += row("CAL0", 3, 0xFFFF, 0x31, -0x2A, 1)
    text += row("CAL1", 2, 0xFFFF, 0x50, 0x10, 1, ck=(0x1234, True))
    text += row("P1NP", 3, 0x0100, 0x40, 0, 0x1000, ck=(0xBEEF, False))
    text += s["logTxtSkip"] + "P1RD" + " " + "SRAM" + "\n"
    text += row("D0CP", 3, 0x5B15, 0x41, 7, 0x100, ck=(0x8A3C, True), q=(0, 0, 2))
    text += row("D0CP", 3, 0x5B15, 0x45, 9, 0x100, ck=(0x8A3C, False), q=(2, 1, 3), lat=0x1C)
    text += s["logTxtSkip"] + "D0DT" + " " + s["dmaTxtAbsent"] + "\n"
    text += s["logTxtEnd"] + "%04X" % 5 + "\n"
    p = tmp_path / "CORE303.LOG"
    p.write_bytes(text.encode("ascii"))
    log = parse.parse_log(p)
    assert (log.bench, log.stamp, log.sram_kb) == ("STANDALONE", "abc1234", 2048)
    assert log.nr == {"%02X" % k: v for k, v in nr}
    assert parse.timing(log.nr) == (311, 228)
    a, b, c, d, e = log.rows
    assert (a.tag, a.clock, a.speed, a.r, a.f, a.d, a.n) == ("CAL0", "W", 3, 0xFFFF, 0x31, -0x2A, 1)
    assert a.ck is None and b.ck_ok is True and c.ck_ok is False
    assert (b.speed, b.ck, c.ck, c.n) == (2, 0x1234, 0xBEEF, 0x1000)
    assert a.q is None and a.lat is None
    assert (d.q, d.ck, d.ck_ok, d.lat) == ((0, 0, 2), 0x8A3C, True, None)
    assert (e.q, e.ck_ok, e.lat) == ((2, 1, 3), False, 0x1C)
    assert log.skips == [("P1RD", "SRAM"), ("D0DT", "ABSENT")]
    assert s["logTxtKb1"] == "1024"
    assert s["logName"] == "CORE303.LOG"


BENCH_ASM = ROOT / "src" / "bench.asm"


def _routine_strings(text, label):
    """logTxt* labels loaded by ld hl, in order, from label to its next blank line."""
    body = text[text.index("\n%s:\n" % label):]
    body = body[:body.index("\n\n")]
    return re.findall(r"^\s*ld hl, (logTxt\w+)", body, re.M)


def test_bench_log_format_parses(tmp_path):
    """A BENCH303.LOG built from src/bench.asm's own strings, in br_log's field order."""
    text = BENCH_ASM.read_text(encoding="ascii")
    s = dict(DB_STR.findall(text))
    assert s["logTxtHdr"] == "#CORE303 BENCH "
    assert s["logTxtCL"] == " C=L S=" and s["logTxtE"] == " E="
    assert s["logTxtEnd"] == "#END "
    assert s["logName"] == "BENCH303.LOG"
    assert _routine_strings(text, "br_log") == \
        ["logTxtCL", "logTxtR", "logTxtF", "logTxtD", "logTxtN", "logTxtE"]
    assert _routine_strings(text, "log_header") == \
        ["logTxtHdr", "logTxtStamp", "logTxtNr", "logTxtSram", "logTxtKb1", "logTxtKb2"]
    assert _routine_strings(text, "log_flush")[0] == "logTxtEnd"
    nr = [(0x01, 0x03), (0x0E, 0x00), (0x0F, 0x03), (0x03, 0x30), (0x05, 0x00), (0x07, 0x33)]

    def row(tag, sp, r, f, d, n, e=None):
        out = tag + s["logTxtCL"] + str(sp) + s["logTxtR"] + "%04X" % r
        out += s["logTxtF"] + "%04X" % f + s["logTxtD"] + "%04X" % (d & 0xFFFF)
        out += s["logTxtN"] + "%04X" % n
        if e is not None:
            out += s["logTxtE"] + "%04X" % e
        return out + "\n"

    log = s["logTxtHdr"] + "5e4b8b5" + "\n"
    log += s["logTxtNr"] + "".join(" %02X=%02X" % kv for kv in nr) + "\n"
    log += s["logTxtSram"] + s["logTxtKb1"] + "\n"
    log += row("BRHD", 3, 0x0100, 0x20, 0x11, 1, e=0x1234)
    log += row("B2HD", 3, 0x0100, 0x60, -0x05, 114, e=0x1234)
    log += s["logTxtSkip"] + "B2IM" + " " + s["txtState"] + "\n"
    log += row("BRI0", 3, 0x0300, 0x50, 0, 1)
    log += s["logTxtEnd"] + "%04X" % 3 + "\n"
    p = tmp_path / s["logName"]
    p.write_bytes(log.encode("ascii"))
    got = parse.parse_log(p)
    assert (got.bench, got.stamp, got.sram_kb) == ("BENCH", "5e4b8b5", 1024)
    a, b, c = got.rows
    assert (a.tag, a.clock, a.speed, a.r, a.f, a.d, a.n, a.end) == \
        ("BRHD", "L", 3, 0x100, 0x20, 0x11, 1, 0x1234)
    assert (b.d, b.n, b.end) == (-5, 114, 0x1234)
    assert c.end is None and c.ck is None and c.q is None
    assert got.skips == [("B2IM", "STATE")]
