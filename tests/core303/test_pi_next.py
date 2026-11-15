"""PI303.NEX (P3) and PI303V.NEX (P4) Next sides: build, MAP sidecar, banks, tags and exit
discipline."""
import re
import subprocess
from pathlib import Path

import pytest

import parse
from tags import PI_TAGS, TAGS

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
NEXT = HERE / "pi" / "next"
ASM = NEXT / "pi303.asm"
ASM_V = NEXT / "pi303v.asm"
BUILD = NEXT / "build.ps1"
TEST_OUT = ROOT / "build" / "core303" / "test"
STAGED_NEX = ROOT / "build" / "core303" / "PI303.NEX"
PHYS_RAM = 0x40000
PHYS_LIMIT = 0x200000
ROW_CODES = {"ROW_NP": "NP", "ROW_RS": "RS", "ROW_R5": "R5", "ROW_LR": "LR", "ROW_BF": "BF"}
TGT_LETTER = {"TGT_U": "U", "TGT_S": "S", "TGT_B": "B"}
MAP_KEYS = ("mbox_phys scratch_phys scratch_len sled_phys sled_len rs_phys rs_len r5_off "
            "r5_len lr_src_phys lr_len bf_dst_phys bf_len fill_val u_phys bank7_save_phys "
            "bank5_save_phys "
            "result_phys_region result_len_max row_np row_rs row_r5 row_lr row_bf").split()


def _build(*extra):
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(BUILD), *extra],
                          capture_output=True, text=True, timeout=300)


@pytest.fixture(scope="module")
def built():
    res = _build("-Stamp", "TEST", "-AllowDirty")
    assert res.returncode == 0, res.stdout + res.stderr
    return TEST_OUT


def _sym(out, name="PI303"):
    syms = {}
    for line in (out / (name + ".sym")).read_text(encoding="ascii").splitlines():
        m = re.fullmatch(r"([\w.]+): EQU 0x([0-9A-F]+)", line.strip())
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def _map(out, name="PI303"):
    kv = {}
    for line in (out / (name + ".MAP")).read_text(encoding="ascii").splitlines():
        k, eq, v = line.partition("=")
        assert eq and re.fullmatch(r"[a-z][a-z0-9_]*", k) and re.fullmatch(r"[0-9A-F]{6}", v), line
        assert k not in kv, k
        kv[k] = int(v, 16)
    return kv


def _nex_banks(out, name="PI303"):
    d = (out / (name + ".NEX")).read_bytes()
    assert d[:8] == b"NextV1.2"
    banks = [b for b in range(112) if d[18 + b]]
    assert d[9] == len(banks)
    return d, banks


def _inside(banks, phys, n):
    """Every byte of phys..phys+n-1 lies in a declared 16K bank."""
    present = {PHYS_RAM + b * 0x4000 for b in banks}
    return all(PHYS_RAM + ((a - PHYS_RAM) // 0x4000) * 0x4000 in present
               for a in range(phys, phys + n, 0x2000)) and \
        PHYS_RAM + ((phys + n - 1 - PHYS_RAM) // 0x4000) * 0x4000 in present


# ---- source parsing: (label, instruction) per line, comments stripped ----

def _lines(asm=ASM):
    out = []
    for raw in asm.read_text(encoding="ascii").splitlines():
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


def _strings(asm=ASM):
    out = {}
    for lb, ins in _lines(asm):
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
                    ("bank7_save_phys", 0x2000), ("bank5_save_phys", kv["r5_len"]),
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
    p3 = {t for t in TAGS if re.fullmatch(r"[PUSB]3(NP|RS|R5|LR|BF)|P3B7|P3B5", t)}
    assert p3 == set(tags) - {"CAL0"}
    assert {"P3B7", "P3B5", "CAL0"} <= set(tags)


def test_pi_and_core_tags_disjoint():
    import tags as tagtab
    assert not set(tagtab.TAGS) & set(tagtab.PI_TAGS)


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
    b5 = body.index("ld hl, b5table")
    flush = body.index("call log_flush")
    assert body[b7 + 1] == "call run_table" and body[b5 + 1] == "call run_table"
    assert st4 < settle < b7 < b5 < flush
    # Either restore's CK verdict feeds the final state.
    for k in (b7, b5):
        assert body[k + 2] == "call blk_ck"
    last_state = max(i for i, s in enumerate(body) if s == "call mb_state")
    assert "ld a, (blkbad)" in body[flush:last_state]
    # A failed SD flush (logErr != 0, cleared just before) also gives state 3.
    assert body[flush - 2:flush] == ["xor a", "ld (logerr), a"]
    assert body[flush + 1:flush + 3] == ["ld a, (logerr)", "or a"]
    assert re.fullmatch(r"jr z, \.\w+", body[flush + 3])
    assert body[flush + 4] == "ld (blkbad), a"
    assert body.index("ld a, (blkbad)") > flush + 4
    k = body.index("ld a, (blkbad)")
    assert body[k + 1:k + 5] == ["or a", "ld a, st_done", "jr z, .st", "ld a, st_failed"]
    ps = _block(_lines(), "pi_settle")
    assert any("bound_fr" in s for s in ps) and any("settle_fr" in s for s in ps)
    assert "call mb_hb_pi" in ps


def test_pi303_block_ram_saved_before_ready():
    m = _block(_lines(), "main")
    a0 = _find(m, lambda s: s == "nextreg nr_pi_en, a")
    assert m.index("call data_init") < a0 < m.index("call b7_save") < \
        m.index("call b5_save") < m.index("call mb_init")
    s = _block(_lines(), "b5_save")
    assert "ld hl, r5_addr" in s and "ld de, b5save" in s and "ld (b5ck), hl" in s


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
    checks = {r[6] for r in _lead_rows() if r[6] != "0"} | {"b7_check", "b5_check"}
    for c in checks:
        assert _block(lines, c)[-1] == "jp ck_cmp", c


def test_pi303_own_asserts():
    ins = [i for _, i in _lines()]
    assert "assert $ <= code_limit" in ins
    assert any(i.startswith("assert") and "log_cap" in i and "row_total" in i for i in ins)
    assert any(re.match(r"assert lead_q < quiet_max_us\b", i) for i in ins)
    assert "quiet_max_us equ 10000000" in [re.sub(r"\s+", " ", (lb or "").lower() + " " + i)
                                           for lb, i in _lines()]
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
    lines.append("P3B5 C=W S=3 R=0002 F=0000 D=0004 N=0400 CK=5678 BAD")
    lines.append("#END %04X" % (n + 2))
    p = tmp_path / "PI303.LOG"
    p.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    log = parse.parse_log(p)
    assert log.bench == "PI" and log.nr["A0"] == 0x02
    assert ("PI3X", "TIMEOUT") in log.skips and ("U3RS", "NOSTREAM") in log.skips
    assert "P3NP" in parse.report([log], None, None)


# ---- PI303V (P4 Next side) ----

V_MAP_KEYS = ("mbox_phys l2_front_phys l2_back_phys l2_front_bank l2_back_bank l2_len l2_fill "
              "scratch_phys scratch_len mix_src_phys mix_dst_phys mix_len bank5_save_phys "
              "b5_off b5_len result_phys_region result_len_max prof_halt prof_mix").split()
V_ROW_TAGS = {"P4NX", "P4HB", "P4B5"}
L2_LEN = 256 * 192
L2_NRS = {"nr_l2_bank": 0x12, "nr_l2_shadow": 0x13, "nr_l2_xs": 0x16, "nr_l2_ys": 0x17,
          "nr_l2_ctrl": 0x70, "nr_disp1": 0x69}


def _vlines():
    return _lines(ASM_V)


def _owner(lines, i):
    return next(lb for lb, _ in reversed(lines[:i + 1]) if _is_global(lb))


def _reaches(lines, label, seen=()):
    """Straight-line control from label reaches jp restore_all (jumps followed)."""
    assert label not in seen, label
    i = _index(lines, label)
    for _, ins in lines[i:]:
        if not ins:
            continue
        if ins == "jp restore_all":
            return True
        m = re.fullmatch(r"(?:jp|jr) ([\w.]+)", ins)
        if m:
            return _reaches(lines, m.group(1), seen + (label,))
        assert not re.fullmatch(r"ret|reti|halt|jp \(hl\)", ins), (label, ins)
    return False


def test_pi303v_assembles(built):
    nex = built / "PI303V.NEX"
    assert nex.is_file() and (built / "PI303V.MAP").is_file()
    d = nex.read_bytes()
    assert b"TEST" in d and b"PI303V.LOG" in d


def test_pi303v_map_keys(built):
    kv, syms = _map(built, "PI303V"), _sym(built, "PI303V")
    assert set(V_MAP_KEYS) <= set(kv), set(V_MAP_KEYS) - set(kv)
    for k, v in kv.items():
        assert syms["MAP_" + k] == v, k
    assert kv["mbox_phys"] == PHYS_RAM + syms["MBOX_PAGE"] * 0x2000
    assert kv["result_phys_region"] == PHYS_RAM + syms["LOG_PAGE"] * 0x2000
    # NR $12 = b fetches from SRAM (b + 16) x 16K: the 30205 layer2.vhd:172 offset
    for side in ("front", "back"):
        assert kv["l2_%s_phys" % side] == PHYS_RAM + kv["l2_%s_bank" % side] * 0x4000
    assert kv["l2_len"] == L2_LEN
    assert kv["l2_fill"] != 0xE3            # NR $14 reset value: transparent
    assert kv["prof_halt"] == 0 and kv["prof_mix"] == 6
    assert kv["mix_src_phys"] + kv["mix_len"] <= kv["mix_dst_phys"]
    assert kv["scratch_phys"] <= kv["mix_src_phys"]
    assert kv["mix_dst_phys"] + kv["mix_len"] <= kv["scratch_phys"] + kv["scratch_len"]
    assert kv["b5_off"] + kv["b5_len"] <= 0x4000 and kv["b5_off"] >= 0x1B00   # off the screen
    assert syms["MIX_CHUNK"] * 256 == kv["mix_len"]     # 256 iterations a page
    for name, reg in L2_NRS.items():
        assert syms[name.upper()] == reg, name


def test_pi303v_banks_below_2mb(built):
    d, banks = _nex_banks(built, "PI303V")
    kv = _map(built, "PI303V")
    for b in banks:
        assert b <= 111 and PHYS_RAM + (b + 1) * 0x4000 <= PHYS_LIMIT, b
    regions = {"mbox": (kv["mbox_phys"], 0x2000),
               "front": (kv["l2_front_phys"], kv["l2_len"]),
               "back": (kv["l2_back_phys"], kv["l2_len"]),
               "scratch": (kv["scratch_phys"], kv["scratch_len"]),
               "save": (kv["bank5_save_phys"], kv["b5_len"]),
               "result": (kv["result_phys_region"], kv["result_len_max"])}
    for name, (base, n) in regions.items():
        assert base + n <= PHYS_LIMIT, name
        assert _inside(banks, base, n), name
    order = sorted(regions.items(), key=lambda r: r[1][0])
    for (a, (pa, na)), (b, (pb, nb)) in zip(order, order[1:]):
        assert pa + na <= pb, (a, b)
    for side in ("front", "back"):
        bank = kv["l2_%s_bank" % side]
        assert bank < 0x80 and PHYS_RAM + (bank + 3) * 0x4000 <= PHYS_LIMIT, side
        assert all(b in banks for b in range(bank, bank + 3)), side
    for k in ("mix_src_phys", "mix_dst_phys"):
        assert _inside(banks, kv[k], kv["mix_len"]), k


def test_pi303v_tags_known():
    lines = _vlines()
    tags = {t.upper() for _, ins in lines if ins.startswith("row ")
            for t in re.findall(r'"([a-z0-9]{4})"', ins)}
    for lb, ins in lines:
        m = re.fullmatch(r'db "([a-z0-9]{4})"', ins)
        if lb and lb.lower().startswith("tagp4") and m:
            tags.add(m.group(1).upper())
    assert tags == V_ROW_TAGS
    for t in tags:
        assert t in TAGS and t not in PI_TAGS, t
        assert TAGS[t].part == "P4", t
    assert not set(TAGS) & set(PI_TAGS)


def test_pi303v_single_exit_restores():
    lines = _vlines()
    ra = _index(lines, "restore_all")
    halts = [i for i, (_, ins) in enumerate(lines) if ins == "halt"]
    assert len(halts) == 1 and halts[0] > ra
    body = _region(lines, "restore_all", "halt")
    for ins in body:
        assert not re.fullmatch(r"(jp|jr) [\w.]+|ret|reti", ins), ins
    assert "call log_flush" in body
    assert sum(1 for _, ins in lines if ins == "call log_flush") == 1
    assert not any(re.search(r"\bcall restore_all\b", ins) for _, ins in lines)
    for lb in ("exit_end", "exit_timeout", "exit_key"):
        assert _reaches(lines, lb), lb
    targets = [ins for _, ins in lines if re.search(r"\bjp (?:\w+, )?restore_all\b", ins)]
    assert targets and all(t == "jp restore_all" for t in targets)
    assert "jp exit_end" in _block(lines, "follow")
    assert "jp exit_end" in _block(lines, "main")
    w = _block(lines, "watch")
    assert "jp nc, exit_timeout" in w and "jp nc, exit_key" in w
    for i, (_, ins) in enumerate(lines):
        if re.search(r"\bpi_halt\b", ins):
            assert _owner(lines, i) in ("restore_all", "load_step", "pi_settle"), ins


def test_pi303v_exiting_before_restore():
    lines = _vlines()
    body = _region(lines, "restore_all", "halt")
    st4 = body.index("ld a, st_exiting")
    assert body[st4 + 1] == "call mb_state"
    assert body.index("call mb_state") == st4 + 1
    assert not any(re.search(r"restore|run_table|nextreg|l2_", s) for s in body[:st4])
    settle = body.index("call pi_settle")
    di = body.index("call rt_restore")
    rows = body.index("call p4_rows")
    l2 = body.index("call l2_restore")
    b5 = body.index("ld hl, b5table")
    flush = body.index("call log_flush")
    assert body[b5 + 1:b5 + 3] == ["call run_table", "call blk_ck"]
    # frames_seen is final (DI, frame vector back on the stub) before P4NX is logged
    assert st4 < settle < di < rows < l2 < b5 < flush
    ps = _block(lines, "pi_settle")
    assert any("bound_fr" in s for s in ps) and any("settle_fr" in s for s in ps)
    assert "call mb_hb_pi" in ps


def test_pi303v_result_set_after_flush():
    lines = _vlines()
    body = _region(lines, "restore_all", "halt")
    flush, res = body.index("call log_flush"), body.index("call mb_result")
    last_state = max(i for i, ins in enumerate(body) if ins == "call mb_state")
    assert flush < res < last_state
    mr = _block(lines, "mb_result")
    assert any("mb_res_len" in s for s in mr) and any("logptr" in s for s in mr)
    assert any("log_phys" in s for s in mr)


def test_pi303v_flush_failure_state3():
    body = _region(_vlines(), "restore_all", "halt")
    flush = body.index("call log_flush")
    assert body[flush - 2:flush] == ["xor a", "ld (logerr), a"]
    assert body[flush + 1:flush + 3] == ["ld a, (logerr)", "or a"]
    assert re.fullmatch(r"jr z, \.\w+", body[flush + 3])
    assert body[flush + 4] == "ld (blkbad), a"
    k = body.index("ld a, (blkbad)")
    assert k > flush + 4
    assert body[k + 1:k + 7] == ["or a", "ld a, st_done", "jr z, .st", "ld a, st_failed",
                                 "ld (endstate), a", "call mb_state"]
    b5 = body.index("ld hl, b5table")
    assert body[b5 - 3:b5] == ["xor a", "ld (blkbad), a", "ld (rtckstate), a"]


def test_pi303v_l2_registers_restored():
    lines = _vlines()
    regs = set(re.findall(r"nr_\w+", _block(lines, "l2NrList")[0]))
    assert set(L2_NRS) <= regs
    m = _block(lines, "main")
    assert m.index("call l2_save") < m.index("call l2_setup") < m.index("call mb_init")
    sv = _block(lines, "l2_save")
    assert "ld hl, l2nrlist" in sv and "ld de, l2saved" in sv and "call nr_read" in sv
    rs = _block(lines, "l2_restore")
    assert "ld hl, l2nrlist" in rs and "ld de, l2saved" in rs
    assert any(re.fullmatch(r"out \(c\), a", s) for s in rs)
    assert any("l2_nr_count" in s for s in rs)
    # After set-up only the Pi writes NR $12/$13; the Next's other L2 writes are set-up only.
    writers = set()
    for i, (_, ins) in enumerate(lines):
        if re.fullmatch(r"nextreg (%s|\$1[2367]|\$69|\$70|18|19|22|23|105|112), .*"
                        % "|".join(L2_NRS), ins):
            writers.add(_owner(lines, i))
    assert writers == {"l2_setup"}
    st = _block(lines, "l2_setup")
    assert "nextreg nr_l2_bank, l2f_bank" in st and "nextreg nr_l2_shadow, l2b_bank" in st
    assert "nextreg nr_l2_ctrl, 0" in st


def test_pi303v_frames_seen_counts_nr12_changes():
    lines = _vlines()
    isr = _block(lines, "pi_frame_isr")
    k = isr.index("ld a, nr_l2_bank")
    assert isr.index("in l, (c)") < k                 # the main code's select kept
    assert "out (c), l" in isr[k:]
    assert any("l2last" in s for s in isr) and any("framesseen" in s for s in isr)
    assert isr[-2:] == ["ei", "reti"]
    st = _block(lines, "l2_setup")
    assert "ld (l2last), a" in st


def test_pi303v_follower_only():
    lines = _vlines()
    f = _block(lines, "follow")
    for c in ("cp cmd_load", "cp cmd_stop", "cp cmd_end", "cp prof_mix"):
        assert c in f, c
    assert not any("cmd_handover" in s or "cmd_yield" in s for s in f)
    assert any("badcmds" in s for s in f)
    assert f.index("call load_step") < f.index("call hbn_bump") < f.index("call watch")
    # leader stays 0; cmd, arg and cmd_seq are never written by the Next
    lead = [i for i, (_, ins) in enumerate(lines) if re.match(r"ld \(mb_win \+ mb_leader\)", ins)]
    assert [_owner(lines, i) for i in lead] == ["mb_init"]
    assert not any(re.match(r"ld \(mb_win \+ mb_(seq|cmd|arg)", ins) for _, ins in lines)


def test_pi303v_mix_load():
    lines = _vlines()
    ls = _block(lines, "load_step")
    assert "cp prof_mix" in ls and "jp z, mix_step" in ls and "jp pi_halt" in ls
    mx = _block(lines, "mix_step")
    assert mx[:2] == ["nextreg nr_mmu6, mix_src_page", "nextreg nr_mmu7, mix_dst_page"]
    assert "ldir" in mx and "ld a, (hl)" in mx and "ld (hl), a" in mx
    end = max(i for i, s in enumerate(mx) if re.match(r"(jr|jp) nz,", s))
    assert "nextreg nr_mmu6, mix_src_page" in mx[end + 1:]   # once each 256 iterations
    assert mx[-1] == "jp mmu_canon"


def test_pi303v_bank5_saved_before_ready():
    lines = _vlines()
    m = _block(lines, "main")
    assert m.index("nextreg nr_pi_en, a") < m.index("call b5_save") < m.index("call mb_init")
    s = _block(lines, "b5_save")
    assert "ld hl, b5_region" in s and "ld (b5ck), hl" in s
    assert _block(lines, "b5_check")[-1] == "jp ck_cmp"


def test_pi303v_timeout_watches_hb_pi():
    lines = _vlines()
    i = _index(lines, "watch")
    cmp_part = []
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
    moved = w.index("ld (wframe), hl")
    assert any("timeout_fr" in s for s in w[moved:])


def test_pi303v_own_asserts():
    ins = [i for _, i in _vlines()]
    assert "assert $ <= code_limit" in ins
    assert any(i.startswith("assert") and "log_cap" in i and "row_total" in i for i in ins)


def test_pi303v_log_parses(tmp_path):
    lines = _vlines()
    s = _strings(ASM_V)
    ph = _block(lines, "p4_head")
    seq = ["ld hl, logtxtcw", "ld hl, logtxtr", "ld hl, logtxtf", "ld hl, logtxtd",
           "ld hl, logtxtn"]
    assert [x for x in ph if x in seq] == seq
    log_lines = ["#CORE303 PI TEST", "#NR 01=03 0E=00 0F=03 03=B2 05=00 07=03", "#SRAM 2048",
                 s["txtNrA0"] + "02 69=00 12=09 13=0B 16=00 17=00 70=00",
                 "P4NX C=W S=3 R=0001 F=1F40 D=0000 N=0123 CK=0000 OK",
                 "P4HB C=W S=3 R=0001 F=1F40 D=0000 N=1E00",
                 "#SKIP PI4X %s" % s["txtTimeout"],
                 "#SKIP PI4X %s" % s["txtPiBusy"],
                 "P4B5 C=W S=3 R=0001 F=0000 D=0002 N=0100 CK=1234 OK",
                 "#END 0003"]
    p = tmp_path / "PI303V.LOG"
    p.write_bytes(("\n".join(log_lines) + "\n").encode("ascii"))
    log = parse.parse_log(p)
    assert log.bench == "PI" and log.nr["A0"] == 0x02 and log.nr["12"] == 0x09
    assert ("PI4X", "TIMEOUT") in log.skips
    assert [r.tag for r in log.rows] == ["P4NX", "P4HB", "P4B5"]
    assert "P4NX" in parse.report([log], None, None)
