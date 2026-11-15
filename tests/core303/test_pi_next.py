"""PI303.NEX (P3 Next side): build, MAP sidecar, banks, tags and exit discipline."""
import re
import subprocess
from pathlib import Path

import pytest

import parse
from tags import TAGS

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
NEXT = HERE / "pi" / "next"
ASM = NEXT / "pi303.asm"
BUILD = NEXT / "build.ps1"
TEST_OUT = ROOT / "build" / "core303" / "test"
STAGED_NEX = ROOT / "build" / "core303" / "PI303.NEX"
PHYS_RAM = 0x40000
PHYS_LIMIT = 0x200000
ROW_CODES = {"ROW_NP": "NP", "ROW_RS": "RS", "ROW_R5": "R5", "ROW_LR": "LR", "ROW_BF": "BF"}
TGT_LETTER = {"TGT_U": "U", "TGT_S": "S", "TGT_B": "B"}
MAP_KEYS = ("mbox_phys scratch_phys scratch_len sled_phys sled_len rs_phys rs_len r5_off "
            "r5_len lr_src_phys lr_len bf_dst_phys bf_len fill_val u_phys bank7_save_phys "
            "result_phys_region result_len_max row_np row_rs row_r5 row_lr row_bf").split()


def _build(*extra):
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(BUILD), *extra],
                          capture_output=True, text=True, timeout=300)


@pytest.fixture(scope="module")
def built():
    res = _build("-Stamp", "TEST", "-AllowDirty")
    assert res.returncode == 0, res.stdout + res.stderr
    return TEST_OUT


def _sym(out):
    syms = {}
    for line in (out / "PI303.sym").read_text(encoding="ascii").splitlines():
        m = re.fullmatch(r"([\w.]+): EQU 0x([0-9A-F]+)", line.strip())
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def _map(out):
    kv = {}
    for line in (out / "PI303.MAP").read_text(encoding="ascii").splitlines():
        k, eq, v = line.partition("=")
        assert eq and re.fullmatch(r"[a-z][a-z0-9_]*", k) and re.fullmatch(r"[0-9A-F]{6}", v), line
        assert k not in kv, k
        kv[k] = int(v, 16)
    return kv


def _nex_banks(out):
    d = (out / "PI303.NEX").read_bytes()
    assert d[:8] == b"NextV1.2"
    banks = [b for b in range(112) if d[18 + b]]
    assert d[9] == len(banks)
    return d, banks


# ---- source parsing: (label, instruction) per line, comments stripped ----

def _lines():
    out = []
    for raw in ASM.read_text(encoding="ascii").splitlines():
        code = raw.split(";", 1)[0].rstrip()
        label, ins = None, code.strip()
        if code and not code[0].isspace():
            tok = code.split(None, 1)
            label = tok[0].rstrip(":")
            ins = tok[1].strip() if len(tok) > 1 else ""
        out.append((label, re.sub(r"\s+", " ", ins).lower()))
    return out


def _is_global(label):
    return label is not None and not label.startswith(".")


def _index(lines, label):
    hits = [i for i, (lb, _) in enumerate(lines) if lb == label]
    assert len(hits) == 1, "%s defined %d times" % (label, len(hits))
    return hits[0]


def _block(lines, label):
    """Instructions from a global label up to the next global label (equ lines excluded)."""
    i = _index(lines, label)
    out = []
    for lb, ins in lines[i + 1:]:
        if _is_global(lb) and not re.match(r"(equ|=|defl)\b", ins):
            break
        if ins:
            out.append(ins)
    return [lines[i][1]] + out if lines[i][1] else out


def _region(lines, start, stop_ins):
    """Instructions from label start to the first instruction equal to stop_ins."""
    i = _index(lines, start)
    out = []
    for _, ins in lines[i:]:
        if ins:
            out.append(ins)
        if ins == stop_ins:
            return out
    raise AssertionError("%s not reached from %s" % (stop_ins, start))


def _find(seq, pred, start=0):
    for i in range(start, len(seq)):
        if pred(seq[i]):
            return i
    raise AssertionError("not found after %d" % start)


def _lead_rows():
    """(cmd, row, target, flags, tag, init, check) of every LEAD line."""
    rows = []
    for _, ins in _lines():
        if ins.startswith("lead "):
            args = [a.strip() for a in ins[5:].split(",")]
            assert len(args) == 12, ins
            rows.append((args[0].upper(), args[1].upper(), args[2].upper(), args[3].upper(),
                         args[4].strip('"').upper(), args[9], args[11]))
    return rows


def _asm_tags():
    tags = []
    for _, ins in _lines():
        if re.match(r"(lead|row) ", ins):
            tags += [t.upper() for t in re.findall(r'"([a-z0-9]{4})"', ins)]
    return tags


def _strings():
    out = {}
    for lb, ins in _lines():
        m = re.fullmatch(r'db "([^"]*)", 0', ins)
        if lb and m:
            out[lb] = m.group(1).upper()
    return out


# ---- tests ----

def test_pi303_assembles(built):
    nex = built / "PI303.NEX"
    assert nex.is_file() and (built / "PI303.MAP").is_file()
    assert b"TEST" in nex.read_bytes()


def test_pi303_stamp_never_writes_staged_path(built):
    before = STAGED_NEX.read_bytes() if STAGED_NEX.is_file() else None
    res = _build("-Stamp", "TEST", "-AllowDirty")
    assert res.returncode == 0, res.stdout + res.stderr
    after = STAGED_NEX.read_bytes() if STAGED_NEX.is_file() else None
    assert before == after


def test_pi303_map_keys(built):
    kv, syms = _map(built), _sym(built)
    assert set(MAP_KEYS) <= set(kv), set(MAP_KEYS) - set(kv)
    assert kv["mbox_phys"] == PHYS_RAM + syms["MBOX_PAGE"] * 0x2000
    assert kv["sled_phys"] == PHYS_RAM + syms["SLED_PAGE"] * 0x2000
    assert kv["result_phys_region"] == PHYS_RAM + syms["LOG_PAGE"] * 0x2000
    assert kv["scratch_len"] == 256 * 1024
    assert kv["u_phys"] == kv["scratch_phys"]
    assert [kv[k] for k in ("row_np", "row_rs", "row_r5", "row_lr", "row_bf")] == [0, 1, 2, 3, 4]
    for k, v in kv.items():
        assert syms["MAP_" + k] == v, k


def test_pi303_banks_below_2mb(built):
    d, banks = _nex_banks(built)
    kv = _map(built)
    for b in banks:
        assert b <= 111 and PHYS_RAM + (b + 1) * 0x4000 <= PHYS_LIMIT, b
    present = {PHYS_RAM + b * 0x4000 for b in banks}

    def inside(phys, n):
        return all((PHYS_RAM + ((a - PHYS_RAM) // 0x4000) * 0x4000) in present
                   for a in range(phys, phys + n, 0x2000)) and \
            (PHYS_RAM + ((phys + n - 1 - PHYS_RAM) // 0x4000) * 0x4000) in present
    for base, n in (("mbox_phys", 25), ("scratch_phys", kv["scratch_len"]),
                    ("sled_phys", kv["sled_len"]), ("rs_phys", kv["rs_len"]),
                    ("lr_src_phys", kv["lr_len"]), ("bf_dst_phys", kv["bf_len"]),
                    ("bank7_save_phys", 0x2000),
                    ("result_phys_region", kv["result_len_max"])):
        assert kv[base] + n <= PHYS_LIMIT, base
        assert inside(kv[base], n), base


def test_pi303_sled_own_page(built):
    syms = _sym(built)
    page = syms["SLED_PAGE"]
    assert syms["SLED_BANK"] * 2 == page
    sld = (built / "PI303.sld").read_text(encoding="ascii", errors="replace").splitlines()
    by_page = {}   # SLD: file|line|def file|def line|page|value|type|data
    for line in sld[1:]:
        f = line.split("|", 7)
        if len(f) == 8 and f[6] == "F":
            by_page.setdefault(int(f[4]), set()).add(f[7])
    assert by_page.get(page) == {"p3_sled"}, by_page.get(page)
    assert page + 1 not in by_page
    # The streamed range is the NOPs only; the closing ret sits just past it.
    d, banks = _nex_banks(built)
    kv = _map(built)
    at = 512 + banks.index(syms["SLED_BANK"]) * 0x4000
    assert kv["sled_phys"] == PHYS_RAM + page * 0x2000
    assert d[at:at + kv["sled_len"]] == bytes(kv["sled_len"])
    assert d[at + kv["sled_len"]] == 0xC9
    assert not any(d[at + kv["sled_len"] + 1:at + 0x4000])


def test_pi303_tags_known():
    tags = _asm_tags()
    for t in tags:
        assert t in TAGS, t
    p3 = {t for t in TAGS if re.fullmatch(r"[PUSB]3(NP|RS|R5|LR|BF)|P3B7", t)}
    assert p3 == set(tags) - {"CAL0"}
    assert "P3B7" in tags and "CAL0" in tags


def test_pi303_loaded_tags_unique():
    rows = _lead_rows()
    tags = [r[4] for r in rows]
    assert len(tags) == len(set(tags))
    loaded = set()
    for cmd, row, tgt, flags, tag, init, check in rows:
        if cmd == "CMD_STREAM":
            assert tag == TGT_LETTER[tgt] + "3" + ROW_CODES[row], tag
            loaded.add(tag)
            assert (flags == "PRECOPY") == (tgt == "TGT_S" and row in ("ROW_NP", "ROW_RS", "ROW_LR"))
            assert (check != "0") == (flags == "PRECOPY"), tag
        else:
            assert cmd == "CMD_QUIET" and check == "0", tag
            assert tag == "CAL0" or tag == "P3" + ROW_CODES[row], tag
    assert loaded == {t + "3" + c for t in "USB" for c in ROW_CODES.values()}
    assert {r[4] for r in rows if r[0] == "CMD_QUIET"} == {"CAL0"} | {"P3" + c for c in ROW_CODES.values()}


def test_pi303_single_exit_restores():
    lines = _lines()
    ra = _index(lines, "restore_all")
    halts = [i for i, (_, ins) in enumerate(lines) if ins == "halt"]
    assert len(halts) == 1 and halts[0] > ra
    # restore_all falls straight through to the halt: no unconditional transfer between.
    body = _region(lines, "restore_all", "halt")
    for ins in body:
        assert not re.fullmatch(r"(jp|jr) [\w.]+|ret|reti", ins), ins
    assert sum(1 for ins in body if ins == "call log_flush") == 1
    assert sum(1 for _, ins in lines if ins == "call log_flush") == 1   # log_fail unwinds here
    assert not any(re.search(r"\bcall restore_all\b", ins) for _, ins in lines)

    def reaches(label, seen=()):
        assert label not in seen, label
        i = _index(lines, label)
        for _, ins in lines[i:]:
            if not ins:
                continue
            if ins == "jp restore_all":
                return True
            m = re.fullmatch(r"(?:jp|jr) ([\w.]+)", ins)
            if m:
                return reaches(m.group(1), seen + (label,))
            assert not re.fullmatch(r"ret|reti|halt|jp \(hl\)", ins), (label, ins)
        return False
    exits = ("exit_end", "exit_timeout", "exit_key")
    for lb in exits:
        assert reaches(lb), lb
    targets = [ins for _, ins in lines if re.search(r"\bjp (?:\w+, )?restore_all\b", ins)]
    assert targets and all(t == "jp restore_all" for t in targets)
    # The local exits are wired: END in follow, timeout and key in watch.
    assert "jp exit_end" in _block(lines, "follow")
    w = _block(lines, "watch")
    assert "jp nc, exit_timeout" in w and "jp nc, exit_key" in w
    # Only restore_all's tail and the EI frame waits use the halt.
    users = [i for i, (_, ins) in enumerate(lines) if re.search(r"\bpi_halt\b", ins)]
    for i in users:
        owner = next(lb for lb, _ in reversed(lines[:i + 1]) if _is_global(lb))
        assert owner in ("restore_all", "load_step", "pi_settle", "lead"), owner


def test_pi303_result_set_after_flush():
    body = _region(_lines(), "restore_all", "halt")
    flush = body.index("call log_flush")
    res = body.index("call mb_result")
    last_state = max(i for i, ins in enumerate(body) if ins == "call mb_state")
    assert flush < res < last_state
    mr = _block(_lines(), "mb_result")
    assert any("mb_res_len" in ins for ins in mr) and any("logptr" in ins for ins in mr)


def test_pi303_exiting_before_restore():
    body = _region(_lines(), "restore_all", "halt")
    st4 = _find(body, lambda s: s == "ld a, st_exiting")
    assert body[st4 + 1] == "call mb_state"
    assert body.index("call mb_state") == st4 + 1
    settle = body.index("call pi_settle")
    b7 = body.index("ld hl, b7table")
    assert body[b7 + 1] == "call run_table"
    assert st4 < settle < b7
    ps = _block(_lines(), "pi_settle")
    assert any("bound_fr" in s for s in ps) and any("settle_fr" in s for s in ps)
    assert "call mb_hb_pi" in ps


def test_pi303_timeout_watches_hb_pi():
    lines = _lines()
    i = _index(lines, "watch")
    cmp_part = []           # watch up to .mark: each field read, then compared
    for lb, ins in lines[i + 1:]:
        if lb == ".mark":
            break
        if ins:
            cmp_part.append(ins)
    for field in ("mb_hb_pi", "mb_seq", "mb_ack"):
        k = _find(cmp_part, lambda s: re.search(r"\(mbsh \+ %s\)" % field, s))
        c = _find(cmp_part, lambda s: re.fullmatch(r"sbc hl, de|cp \(hl\)", s), k)
        assert c - k <= 3, field
        assert re.fullmatch(r"jr (nz, \.mark|z, \.still)", cmp_part[c + 1]), field
    w = _block(lines, "watch")
    assert "ld (wframe), hl" in w
    moved = w.index("ld (wframe), hl")
    assert any("timeout_fr" in s for s in w[moved:])


def test_pi303_dma_rows_reset():
    lines = _lines()
    for cmd, row, tgt, flags, tag, init, check in _lead_rows():
        if row == "ROW_BF":
            assert init.startswith("dmainit_"), tag
    for lb, _ in lines:
        if lb and lb.startswith("dmainit_"):
            assert _block(lines, lb)[0] == "call dma_reset", lb


def test_pi303_checks_end_ck_cmp():
    lines = _lines()
    checks = {r[6] for r in _lead_rows() if r[6] != "0"} | {"b7_check"}
    for c in checks:
        assert _block(lines, c)[-1] == "jp ck_cmp", c


def test_pi303_own_asserts():
    ins = [i for _, i in _lines()]
    assert "assert $ <= code_limit" in ins
    assert any(i.startswith("assert") and "log_cap" in i and "row_total" in i for i in ins)
    core = (HERE / "bench" / "core303.asm").read_text(encoding="ascii")
    assert "ASSERT LOG_PAGE > OPS_LAST_PAGE" in core


def test_pi303_log_parses(tmp_path):
    s = _strings()
    rows = _lead_rows()
    lines = ["#CORE303 PI TEST", "#NR 01=03 0E=00 0F=03 03=B2 05=00 07=03",
             "#SRAM 2048", s["txtNrA0"] + "02"]
    n = 0
    for cmd, row, tgt, flags, tag, init, check in rows:
        if tag == "U3RS":
            lines.append("#SKIP %s %s" % (tag, s["txtNoStream"]))
            continue
        q = " Q=002" if row == "ROW_BF" else ""
        ck = " CK=0000 OK" if check != "0" else ""
        lines.append("%s C=W S=3 R=0800 F=0040 D=0012 N=1000%s%s" % (tag, q, ck))
        n += 1
    lines.append("#SKIP PI3X %s" % s["txtTimeout"])
    lines.append("#SKIP PI3X %s" % s["txtPiBusy"])
    lines.append("P3B7 C=W S=3 R=0008 F=0000 D=0010 N=0400 CK=1234 OK")
    lines.append("#END %04X" % (n + 1))
    p = tmp_path / "PI303.LOG"
    p.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    log = parse.parse_log(p)
    assert log.bench == "PI" and log.nr["A0"] == 0x02
    assert ("PI3X", "TIMEOUT") in log.skips and ("U3RS", "NOSTREAM") in log.skips
    assert "P3NP" in parse.report([log], None, None)
