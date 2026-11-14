"""Part 2 fixture (tests/core303/fixture/bench.dsf) against the BENCH driver (src/bench.asm):
the DSF compiles with ndrc, the compiled DDB carries every verb's condact bytes and
message 0 as bench.asm expects it, the assets are the copied sources, and every row tag
in bench.asm is in tags.TAGS."""
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

import pytest

from tags import TAGS

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
FIX = HERE / "fixture"
DSF = FIX / "bench.dsf"
BENCH_ASM = ROOT / "src" / "bench.asm"
WORK = ROOT / "tests" / "out" / "core303-fixture"
NDRC = Path(os.environ.get("NEXTDAAD_NDRC") or ROOT / "authoring-kit" / "lib" / "ndrc.exe")

sys.path.insert(0, str(ROOT / "tests" / "text2"))
import t2text  # noqa: E402

# Condact opcodes, src/engine.asm cprops: LET 51, EXTERN 61, SFX 18, PAUSE 35,
# PICTURE 84, DISPLAY 28.
LET, EXTERN, SFX, PAUSE, PICTURE, DISPLAY = 51, 61, 18, 35, 84, 28
BENCH_EXT = [EXTERN, 0, 13]
PAUSE_25 = 13                  # NDRC scales PAUSE durations (manual/audio.md)

# Each verb's compiled condact run, ending at its EXTERN 0 13.
VERB_BYTES = {
    "BTXT": [LET, 250, 1] + BENCH_EXT,
    "BPIC": [PICTURE, 1, DISPLAY, 0, LET, 250, 2] + BENCH_EXT,
    "BISR": [LET, 251, 0, LET, 250, 3] + BENCH_EXT,
    "BISM": [SFX, 1, 7, PAUSE, PAUSE_25, LET, 251, 1, LET, 250, 3] + BENCH_EXT,
    "BISS": [SFX, 0, 8, SFX, 1, 2, PAUSE, PAUSE_25, LET, 251, 2, LET, 250, 3] + BENCH_EXT,
    "BTRN": [LET, 250, 4] + BENCH_EXT,
    "BLOG": [LET, 250, 5] + BENCH_EXT,
}

# BTRN's turn (bench.asm gt_init/bench_turn): PARSE 73, MES 77, DONE 22.
PARSE, MES, DONE = 73, 77, 22
GT_RESPONSE = "The brass lamp is old and dented.\r"

SOURCES = FIX / "SOURCES.txt"
STAGED = {"001.NX3", "001.AKY", "001.WAV"}


def _sources():
    """SOURCES.txt: staged name -> tracked source path (repo root relative)."""
    out = {}
    for line in SOURCES.read_text(encoding="ascii").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, arrow, src = line.split()
        assert arrow == "<-", line
        out[name] = src
    return out


def _equ(name):
    m = re.search(r"^%s\s+equ\s+(\d+)\b" % name, BENCH_ASM.read_text(encoding="ascii"), re.M)
    assert m, name
    return int(m.group(1))


def _compile():
    assert NDRC.is_file(), NDRC
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "BENCH.DSF").write_bytes(DSF.read_bytes())
    ddb = WORK / "BENCH.DDB"
    if ddb.exists():
        ddb.unlink()
    r = subprocess.run([str(NDRC), "nextdaad", "EN", "BENCH.DSF", "BENCH.DDB", "-v3", "-nxtext"],
                       cwd=WORK, capture_output=True, text=True, timeout=120)
    return r, ddb


@pytest.fixture(scope="module")
def ddb():
    r, path = _compile()
    assert r.returncode == 0 and path.is_file(), (r.stdout + r.stderr)[-2000:]
    return path.read_bytes()


def test_fixture_compiles():
    r, path = _compile()
    assert r.returncode == 0, (r.stdout + r.stderr)[-2000:]
    assert path.is_file()


def test_fixture_bytes(ddb):
    assert ddb[0] == 0x83, "header byte 0 %02X: want V3 text format 2" % ddb[0]
    for verb, seq in VERB_BYTES.items():
        assert bytes(seq) in ddb, verb


def test_fixture_message(ddb):
    """Message BCH_MSG decodes to BCH_MSG_LEN plain characters (bench.asm hd_init)."""
    _, texts, _ = t2text.all_texts(ddb)
    msg = texts[("messages", _equ("BCH_MSG"))][0]
    assert len(msg) == _equ("BCH_MSG_LEN"), msg
    assert all(32 <= ord(c) < 127 and c not in "_@#" for c in msg), msg


def _vocab(word, wid, wtype):
    """Compiled vocabulary entry: 5 chars 255-complemented, space padded, id, type."""
    return bytes(255 - ord(c) for c in word[:5].ljust(5)) + bytes([wid, wtype])


def _proc_entries(ddb, proc):
    """(verb, noun, condact offset) of each entry of process table proc."""
    p = struct.unpack_from("<H", ddb, struct.unpack_from("<H", ddb, 10)[0] + 2 * proc)[0]
    out = []
    while ddb[p]:
        out.append((ddb[p], ddb[p + 1], struct.unpack_from("<H", ddb, p + 2)[0]))
        p += 4
    return out


def test_turn_fixture_bytes(ddb):
    """gtLine's words are in the vocabulary; PRO 5 answers them with MES BCH_GT_MSG and
    DONE only (no location change); BCH_GT_PRO starts with _ _ PARSE 0, where REDO
    returns and bench_turn stops; the response fits one window line (no scroll)."""
    m = re.search(r'^gtLine:\s+db\s+"([A-Z ]+)",\s*0', BENCH_ASM.read_text(encoding="ascii"), re.M)
    assert m, "no gtLine"
    verb, noun = m.group(1).split()
    vid, nid, msg = _equ("BCH_GT_VERB"), _equ("BCH_GT_NOUN"), _equ("BCH_GT_MSG")
    assert _vocab(verb, vid, 0) in ddb, verb
    assert _vocab(noun, nid, 2) in ddb, noun
    hits = [o for v, n, o in _proc_entries(ddb, 5) if (v, n) == (vid, nid)]
    assert len(hits) == 1, hits
    assert ddb[hits[0]:hits[0] + 3] == bytes([MES, msg, DONE])
    v, n, o = _proc_entries(ddb, _equ("BCH_GT_PRO"))[0]
    assert (v, n) == (255, 255) and ddb[o:o + 2] == bytes([PARSE, 0])
    _, texts, _ = t2text.all_texts(ddb)
    assert texts[("messages", msg)][0] == GT_RESPONSE
    assert len(GT_RESPONSE) - 1 < _equ("BCH_WIN_W")


def test_fixture_window():
    """Window 0 is BCH_WIN_H x BCH_WIN_W at column 0, below the picture, above row 31."""
    text = DSF.read_text(encoding="ascii")
    m = re.search(r"WINAT\s+(\d+)\s+(\d+)\s+WINSIZE\s+(\d+)\s+(\d+)", text)
    assert m, "no WINAT/WINSIZE"
    y, x, h, w = map(int, m.groups())
    assert (x, w, h) == (0, _equ("BCH_WIN_W"), _equ("BCH_WIN_H"))
    pic_last_row = (32 + 96 - 1) // 8           # Layer 2 mode 0 sits 32 px into the tilemap
    assert y > pic_last_row and y + h <= 31


def test_fixture_sources():
    """Every staged asset has a tracked source; fixture/ holds only those with no
    other tracked copy (no duplicate binaries)."""
    src = _sources()
    assert set(src) == STAGED
    for name, path in src.items():
        r = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", path],
                           capture_output=True, text=True)
        assert r.returncode == 0, (name, path)
    local = {p.name for p in FIX.iterdir()} - {"bench.dsf", "SOURCES.txt"}
    assert local == {n for n, p in src.items() if Path(p).parent.as_posix() == "tests/core303/fixture"}


def test_fixture_assets():
    src = {n: ROOT / p for n, p in _sources().items()}
    assert src["001.WAV"].read_bytes()[:4] == b"RIFF" and src["001.WAV"].stat().st_size > 24576
    assert src["001.AKY"].stat().st_size > 0
    nx3 = src["001.NX3"].read_bytes()
    assert nx3[:4] == b"NX3\x01" and nx3[4] == 0 and nx3[5] & 1 == 0
    x, y, w, h = struct.unpack_from("<H", nx3, 6)[0], nx3[8], struct.unpack_from("<H", nx3, 9)[0], nx3[11]
    assert (x, y, w, h) == (0, 0, 256, 96)
    assert len(nx3) == 16 + 512 + w * h
    assert h * 256 == _equ("BCH_PB_PAGES") * 8192
    assert _equ("BCH_PIC") == 1


def test_part2_tags_known():
    text = BENCH_ASM.read_text(encoding="ascii")
    rows = re.findall(r'^\s*BROW\s+"(\w{4})"', text, re.M)
    assert {"B2HD", "B2PR", "B2SC", "B2PB", "B2PL", "B2I0", "B2IM", "B2IS",
            "B3HD", "B3PR", "B3SC", "B3PB", "B2GT", "B3GT"} <= set(rows)
    for tag in rows:
        assert tag in TAGS, tag
    for tag in set(rows):
        cal = TAGS[tag].cal
        if cal:
            assert cal == tag[0] + "R" + tag[2:], tag
            assert cal in rows and TAGS[cal].calibration, tag
