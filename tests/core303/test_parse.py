from fractions import Fraction
from pathlib import Path

import pytest

import parse
from parse import LogError, NxbRun

BASE = Path(__file__).parent / "results" / "baseline-old-core-2026-09-17"
NR_OK = "#NR 01=00 0E=00 0F=00 03=30 05=00 07=03"


def mk(tmp_path, rows, nr=NR_OK, end=None, name="L.TXT", skips=()):
    lines = ["#CORE303 STANDALONE abc1234", nr, "#SRAM 2048"]
    lines += rows
    lines += ["#SKIP %s %s" % s for s in skips]
    n = len(rows) if end is None else end
    if end != -1:
        lines.append("#END %04X" % n)
    p = tmp_path / name
    p.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    return p


def row(tag, c="W", s=3, r=0x40, f=0x40, d=0, n=1, extra=""):
    return "%s C=%s S=%d R=%04X F=%04X D=%04X N=%04X%s" % (
        tag, c, s, r, f, d & 0xFFFF, n, extra)


def one(tmp_path, line):
    return parse.parse_log(mk(tmp_path, [line])).rows[0]


def test_t_formula(tmp_path):
    r = one(tmp_path, "P1NP C=W S=3 R=0040 F=000A D=FF3F N=0001")
    assert parse.row_t(r, 311, 228) == (10 * 311 - 193) * 1824


def test_speed_scales_tpl(tmp_path):
    r = one(tmp_path, "P1NP C=W S=2 R=0040 F=000A D=FF3F N=0001")
    assert parse.row_t(r, 311, 228) == (10 * 311 - 193) * 912


def test_refuses_unverified_timing(tmp_path):
    assert parse.timing({"03": 0x30, "05": 0x00}) == (311, 228)
    for nr in ("#NR 01=00 0E=00 0F=00 03=10 05=00 07=03",
               "#NR 01=00 0E=00 0F=00 03=30 05=04 07=03"):
        log = parse.parse_log(mk(tmp_path, [row("CAL0")], nr=nr))
        with pytest.raises(LogError):
            parse.timing(log.nr)
        with pytest.raises(LogError):
            parse.report([log], None, None)


def test_truncated_log(tmp_path):
    with pytest.raises(LogError):
        parse.parse_log(mk(tmp_path, [row("CAL0")], end=-1))
    with pytest.raises(LogError):
        parse.parse_log(mk(tmp_path, [row("CAL0"), row("CAL1", s=2)], end=3))


def test_bad_lines(tmp_path):
    with pytest.raises(LogError):
        parse.parse_log(mk(tmp_path, ["WHAT IS THIS"]))
    with pytest.raises(LogError):
        parse.parse_log(mk(tmp_path, ["CAL0 C=W S=3 R=ZZZZ F=0001 D=0000 N=0001"]))


def test_parse_fields(tmp_path):
    log = parse.parse_log(mk(
        tmp_path, [row("CAL0", extra=" Q=213 CK=1234 OK L=0A E=00FF")],
        skips=[("P1RD", "BOUND")]))
    r = log.rows[0]
    assert (log.bench, log.stamp, log.sram_kb) == ("STANDALONE", "abc1234", 2048)
    assert log.nr["03"] == 0x30
    assert log.skips == [("P1RD", "BOUND")]
    assert (r.ck, r.ck_ok, r.lat, r.end) == (0x1234, True, 10, 0xFF)
    assert r.q == (2, 1, 3)


def test_clock_flag(tmp_path):
    # per-rep ticks 39 > 311/8 = 38.875, so T per rep > 311*1824/8
    f, d = divmod(39 * 0x40, 311)
    w = row("P1NP", c="W", f=f, d=d)
    l = row("P1NP", c="L", f=f, d=d)
    text = parse.report([parse.parse_log(mk(tmp_path, [w], name="w.TXT"))], None, None)
    assert "CLOCK?" in text
    text = parse.report([parse.parse_log(mk(tmp_path, [l], name="l.TXT"))], None, None)
    assert "CLOCK?" not in text


def test_bad_checksum_unusable(tmp_path):
    rows = [row("P1NP", extra=" CK=1234 BAD")]
    text = parse.report([parse.parse_log(mk(tmp_path, rows))], None, None)
    assert "UNUSABLE" in text


def test_nxb_row(tmp_path):
    p = tmp_path / "n.TXT"
    p.write_bytes(b"#NXB 0001\r\n>nxbc\r\nC001 O=FF R=0040 F=000A D=FF3F\r\nLOG OK\r\n")
    (run,) = parse.parse_nxb(p)
    assert (run.tag, run.size, run.o, run.r, run.f, run.d) == ("C001", 1, 255, 0x40, 10, -193)
    assert run.kind == "table"


def test_nxb_baseline_files():
    for n in ("D", "Q", "Q6", "SMOKE"):
        parse.parse_nxb(BASE / ("NXBENCH-%s.TXT" % n))
    runs = parse.parse_nxb(BASE / "NXBENCH-Q.TXT")
    by = {}
    for r in runs:
        by.setdefault(r.tag, []).append(r)
    l48, d48 = by["L048"][0], by["D048"][0]
    assert (l48.o, l48.r, l48.f, l48.d, l48.size, l48.kind) == (0x9D, 0x40, 0x16, 0x1C, 48, "table")
    assert (d48.f, d48.d, d48.size, d48.kind) == (0x17, 0xCA, 48, "table")
    sk = by["SK00"][0]
    assert (sk.o, sk.r, sk.f, sk.d, sk.size, sk.kind) == (0xFF, 0x40, 4, 0x19, None, "table")
    iden, a065 = by["IDEN"][0], by["A065"][0]
    assert (iden.o, iden.r, iden.f, iden.kind) == (0, 0x22, 0x140, "session")
    assert (a065.o, a065.r, a065.f, a065.d, a065.kind) == (0x22, 1, 0x30, -6, "session")
    assert len(by["L048"]) == 1
    keys = [(r.tag, r.o, r.r, r.f, r.d, r.section) for r in runs]
    for k in keys:
        assert (k[0], k[1], k[2], k[3], k[4], k[5] - 1) not in keys


RW1_PRINTED = ("IDEN RFR0 RSWP ARSW RSEC RCOL RHST SPN0 ARSE ARCO AHST ASPN OSPN").split()


def test_parse_rw1(tmp_path):
    # the RW1 table's 19 rows print 13 (ARM1/ARM2/ARMO and three DSRM are silent)
    import tags
    assert tuple(tags.NXB_RW1) == tuple(RW1_PRINTED)
    rows = ["%s O=%02X R=%04X F=%04X D=%04X" % (t, 2 if t == "IDEN" else 0, 16 + i, 3 * i, i)
            for i, t in enumerate(RW1_PRINTED)]
    hist = {"RHST": [2041, 5, 2] + [0] * 13 + [0], "AHST": [0] * 16 + [7]}
    lines = ["#NXB 0A10", "> pick 71", "> nxbw"] + rows
    lines += ["#HIST %s%s" % (t, "".join(" %04X" % n for n in b)) for t, b in hist.items()]
    p = tmp_path / "w.TXT"
    p.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    runs = parse.parse_nxb(p)
    assert [r.tag for r in runs] == RW1_PRINTED
    assert all(r.kind == "session" for r in runs)
    assert (runs[0].o, runs[1].r, runs[5].f, runs[12].d) == (2, 17, 15, 12)
    assert parse.parse_hist(p) == [(1, t, b) for t, b in hist.items()]
    assert all(len(b) == tags.NXB_HIST_BINS == 17 for _s, _t, b in parse.parse_hist(p))
    assert parse.rw1_walked(runs) == []
    # a second capture: #HIST lines belong to it; a walked card row (O=01) is flagged
    second = ["#NXB 0B20", "> nxbw", "RSEC O=01 R=0080 F=0002 D=0010",
              "SPN0 O=01 R=0200 F=0010 D=0000", "#HIST AHST" + " 0001" * 17]
    p.write_bytes(("\r\n".join(lines + second) + "\r\n").encode("ascii"))
    assert [s for s, _t, _b in parse.parse_hist(p)] == [1, 1, 2]
    runs = parse.parse_nxb(p)
    assert [(r.tag, r.section) for r in parse.rw1_walked(runs)] == [("RSEC", 2)]
    assert "WALK RSEC (section 2)" in parse.report([], runs, None, timing=(311, 228))
    for bad in ("#HIST XXXX" + " 0000" * 17, "#HIST RHST" + " 0000" * 16, "#HIST RHST 00G0"):
        p.write_bytes(("\r\n".join(lines[:3] + [bad]) + "\r\n").encode("ascii"))
        with pytest.raises(LogError):
            parse.parse_hist(p)
        with pytest.raises(LogError):
            parse.parse_nxb(p)


def test_nxb_o_line_guard(tmp_path):
    p = tmp_path / "n.TXT"
    p.write_bytes(b"#NXB 0001\n>nxbc\nXXXX O=05 R=0008\nLOG OK\n")
    with pytest.raises(LogError):
        parse.parse_nxb(p)


def test_session_no_per_op(tmp_path):
    p = tmp_path / "n.TXT"
    p.write_bytes(b"#NXB 0001\n>nxbr\nIDEN O=00 R=0022 F=0140 D=0000\nLOG OK\n")
    nxb = parse.parse_nxb(p)
    text = parse.report([], nxb, None, timing=(311, 228))
    assert "IDEN" in text and "0022" in text


def runs(tag_pairs):
    out = []
    for tag, val in tag_pairs:
        out.append(NxbRun(tag, int(tag[1:]), 1, 1, 0, val, 1, "table"))
    return out


def xover(sizes, cpu, dma):
    rs = runs([("L%03d" % s, c) for s, c in zip(sizes, cpu)]
              + [("D%03d" % s, d) for s, d in zip(sizes, dma)])
    return parse.crossover(rs, "L", "D", 1, 1)


def test_crossover_non_monotonic():
    got = xover([48, 56, 64, 72], [100] * 4, [110, 90, 90, 110])
    assert got == "52 NON-MONOTONIC"


def test_crossover_interpolates():
    # diff +20 at 48, -10 at 56: 48 + 8*20/30 = 53.33, rounded up
    assert xover([48, 56], [100, 100], [120, 90]) == "54"
    assert xover([48, 56], [100, 100], [90, 80]) == "below 48"
    assert xover([48, 64, 81], [100] * 3, [110, 120, 130]) == "above 81"


def test_nxb_truncated(tmp_path):
    raw = (BASE / "NXBENCH-Q.TXT").read_bytes()
    assert raw.endswith(b"\n")
    p = tmp_path / "t.TXT"
    p.write_bytes(raw[:-1])
    with pytest.raises(LogError):
        parse.parse_nxb(p)
    p.write_bytes(b"#NXB 0001\n>nxbc\nC001 O=FF R=0040 F=000A D=FF3F\nLOG ERR 05\n")
    with pytest.raises(LogError):
        parse.parse_nxb(p)


def test_nxb_not_short(tmp_path):
    p = tmp_path / "n.TXT"
    p.write_bytes(b"#NXB 0001\n>nxbc\nC001 O=FF R=0040 F=000A D=FF3F\nLOG OK\n")
    text = parse.report([], parse.parse_nxb(p), None, timing=(311, 228))
    assert "C001" in text and "SHORT" not in text


def per_unit(tmp_path, rows):
    log = parse.parse_log(mk(tmp_path, rows))
    return {(r.tag, r.speed): parse.per_unit(log, r, 311, 228) for r in log.rows}


def test_cal_subtraction(tmp_path):
    # R=1824: per-rep T = ticks * TPL / 1824, so S=3 per rep = ticks, S=2 = ticks/2
    cal0 = row("CAL0", r=1824, f=0, d=16)
    nop = row("P1NP", r=1824, f=0, d=80, n=16)
    cal1 = row("CAL1", s=2, r=1824, f=0, d=40)
    n14 = row("P1C1", s=2, r=1824, f=0, d=64, n=4)
    pu = per_unit(tmp_path, [cal0, nop, cal1, n14])
    assert pu[("P1NP", 3)] == Fraction(80 - 16, 16)
    assert pu[("P1C1", 2)] == Fraction(32 - 20, 4)


@pytest.fixture
def named_cal(monkeypatch):
    """A workload tag naming companion BXHD, and BXHD itself (part 0)."""
    monkeypatch.setitem(parse.TAGS, "BXHD", parse.tagtab.Tag("0", "restore", "CPU",
                                                              None, "rep"))
    monkeypatch.setitem(parse.TAGS, "B9HD", parse.tagtab.Tag("2", "decode", "CPU",
                                                              None, "char", cal="BXHD"))


def test_named_cal_subtraction(tmp_path, named_cal):
    # R=1824: per-rep T at S=3 = the tick count
    b0 = row("B0CL", c="L", r=1824, f=0, d=10)
    bx = row("BXHD", c="L", r=1824, f=0, d=50)
    wk = row("B9HD", c="L", r=1824, f=0, d=250, n=20)
    pu = per_unit(tmp_path, [b0, bx, wk])
    assert pu[("B9HD", 3)] == Fraction(250 - 50, 20)
    assert pu[("BXHD", 3)] == Fraction(50 - 10, 1)


def test_missing_cal_flagged(tmp_path, named_cal):
    rows = [row("B0CL", c="L", r=1824, f=0, d=10),
            row("B9HD", c="L", r=1824, f=0x40, d=250, n=20)]
    log = parse.parse_log(mk(tmp_path, rows))
    assert parse.per_unit(log, log.rows[1], 311, 228) is None
    text = parse.report([log], None, None)
    line = next(l for l in text.splitlines() if l.startswith("| B9HD"))
    assert "NOCAL" in line
    assert line.split(" | ")[5] == "-"
    b0 = next(l for l in text.splitlines() if l.startswith("| B0CL"))
    assert "NOCAL" not in b0


def test_unknown_tag_rejected(tmp_path):
    with pytest.raises(LogError):
        parse.parse_log(mk(tmp_path, [row("ZZZZ")]))


def test_short_row_flag(tmp_path):
    text = parse.report([parse.parse_log(mk(tmp_path, [row("P1NP", f=49)]))], None, None)
    assert "SHORT" in text
    text = parse.report([parse.parse_log(mk(tmp_path, [row("P1NP", f=50)], name="b.TXT"))],
                        None, None)
    assert "SHORT" not in text


def test_cal_short_exempt(tmp_path):
    def text(line, name):
        return parse.report([parse.parse_log(mk(tmp_path, [line], name=name))], None, None)
    assert "SHORT" not in text(row("CAL0", f=0x0F), "a.TXT")
    assert "SHORT" in text(row("CAL0", f=0x0E), "b.TXT")
    assert "SHORT" in text(row("P1NP", f=0x2F), "c.TXT")


def test_companion_cal_short_exempt(tmp_path, named_cal):
    # BXHD is part 0, so Tag.calibration holds without any name pattern
    def text(line, name):
        return parse.report([parse.parse_log(mk(tmp_path, [line], name=name))], None, None)
    assert parse.TAGS["BXHD"].calibration and not parse.TAGS["B9HD"].calibration
    assert "SHORT" not in text(row("BXHD", c="L", f=0x0F), "a.TXT")
    assert "SHORT" in text(row("B9HD", c="L", f=0x0F), "c.TXT")


def test_companion_never_short(tmp_path, named_cal):
    # BXHD is some Tag's cal (B9HD's): exempt at any F; plain calibration keeps the floor
    def text(line, name):
        return parse.report([parse.parse_log(mk(tmp_path, [line], name=name))], None, None)
    assert "SHORT" not in text(row("BXHD", c="L", f=0x0E), "a.TXT")
    assert "SHORT" not in text(row("BXHD", c="L", f=0, d=5), "b.TXT")
    assert "SHORT" in text(row("B0CL", c="L", f=0x0E), "c.TXT")
    assert "SHORT" in text(row("CAL0", f=0x0E), "d.TXT")


def test_isr_per_frame(tmp_path):
    # B2I0 F=80 D=20, its DI twin BRI0 F=80 D=0, S=3: (20 lines x 1824 T) / 80 frames = 456
    rows = [row("BRI0", c="L", r=0x300, f=80, d=0), row("B2I0", c="L", r=0x300, f=80, d=20)]
    log = parse.parse_log(mk(tmp_path, rows))
    wk = log.rows[1]
    assert parse.TAGS["B2I0"].per_frame and not parse.TAGS["B2HD"].per_frame
    assert parse.isr_per_frame(log, wk, 311, 228) == Fraction(456)
    text = parse.report([log], None, None)
    line = next(l for l in text.splitlines() if l.startswith("| B2I0 "))
    assert "| 456.00 |" in line and "T/frame" in line, line
    assert "SHORT" not in next(l for l in text.splitlines() if l.startswith("| BRI0 "))


def test_dma_clock_flag(tmp_path):
    # Non-CPU C=W rows flag CLOCK? at 0.9 frame per rep (311 x 0.9 = 279.9 lines),
    # CPU rows at 1/8 frame
    def line(tag, d):
        text = parse.report([parse.parse_log(mk(tmp_path, [row(tag, r=1, f=0, d=d)],
                                                name="%s%d.TXT" % (tag, d)))], None, None)
        return next(l for l in text.splitlines() if l.startswith("| %s " % tag))
    assert parse.TAGS["DFZ1"].method == parse.tagtab.DMA
    assert "CLOCK?" not in line("DFZ1", 279)
    assert "CLOCK?" in line("DFZ1", 280)
    assert "CLOCK?" in line("DFC1", 279)
    l = row("DFZ1", c="L", r=1, f=0, d=300)
    assert "CLOCK?" not in parse.report([parse.parse_log(mk(tmp_path, [l], name="l.TXT"))],
                                        None, None)


# R=1824 at S=3: per-rep T = lines. B2I0 vs BRI0: 20 lines x 1824 / 80 frames = 456 T/frame.
ISR_ROWS = [row("BRI0", c="L", r=1, f=80, d=0), row("B2I0", c="L", r=1, f=80, d=20)]
# BRHD 622 lines/rep, 2 frames; B2HD 1244 lines/rep, 4 frames, N=10: raw (1244-622)/10.
HD28 = [row("BRHD", c="L", r=1824, f=2, d=0),
        row("B2HD", c="L", r=1824, f=4, d=0, n=10, extra=" E=00FF")]
# S=2: per-rep T = lines/2; same per-rep T as S=3 in twice the frames.
HD14 = [row("BRHD", c="L", s=2, r=1824, f=4, d=0),
        row("B3HD", c="L", s=2, r=1824, f=8, d=0, n=10, extra=" E=00FF")]


def _p2_line(text, tag):
    return next(l for l in text.splitlines() if l.startswith("| %s " % tag)).split(" | ")


def test_part2_ex_isr(tmp_path):
    log = parse.parse_log(mk(tmp_path, ISR_ROWS + HD28))
    assert parse.isr_idle(log, 311, 228) == Fraction(456)
    # ex-ISR: row 1244 - 4 x 456 / 1824 = 1243, companion 622 - 0.5 = 621.5; / N=10
    assert parse.per_unit_ex_isr(log, log.rows[3], 311, 228, Fraction(456)) == \
        Fraction(6215, 100)
    text = parse.report([log], None, None)
    hd = _p2_line(text, "B2HD")
    assert (hd[5], hd[6]) == ("62.20", "62.15"), hd
    assert _p2_line(text, "B2I0")[6] == "-"
    assert "ISR share: row F x B2I0 T/frame" in text and "456.00 T/frame" in text
    assert "| T/unit ex-ISR |" in text
    assert "T/unit ex-ISR" not in text.split("### Part 2")[0]


def test_part2_no_isr_figure(tmp_path):
    text = parse.report([parse.parse_log(mk(tmp_path, HD28))], None, None)
    hd = _p2_line(text, "B2HD")
    assert (hd[5], hd[6]) == ("62.20", "no ISR figure"), hd
    assert "(no ISR figure)" in text


def test_cross_check(tmp_path):
    text = parse.report([parse.parse_log(mk(tmp_path, ISR_ROWS + HD28 + HD14))], None, None)
    xc = [l for l in text.splitlines() if l.startswith("B2/B3 ")]
    # B3 ex-ISR: row 1244 - 8 x 456 / 1824 = 1242, companion 622 - 1 = 621
    assert xc == ["B2/B3 HD: 28MHz 62.20 14MHz 62.20 T/char, ex-ISR 62.15 / 62.10; "
                  "E 00FF EQUAL"], xc


def test_cross_check_differ_missing(tmp_path):
    rows = HD28 + [HD14[0], HD14[1].replace("E=00FF", "E=0100"),
                   row("BRSC", c="L", r=1824, f=2, d=0), row("B2SC", c="L", r=1824, f=4, d=0)]
    text = parse.report([parse.parse_log(mk(tmp_path, rows))], None, None)
    xc = [l for l in text.splitlines() if l.startswith("B2/B3 ")]
    assert xc == ["B2/B3 HD: 28MHz 62.20 14MHz 62.20 T/char, no ISR figure; "
                  "E DIFFER B2=00FF B3=0100",
                  "B2/B3 SC: B3 missing"], xc


def control(tmp_path, units, name="c.TXT"):
    # CAL1 S=2, R=1824: per-rep T = lines/2 = 20; N=100 resolves 0.01 T
    rows = [row("CAL1", s=2, r=1824, f=0, d=40)]
    for tag, u in units:
        rows.append(row(tag, s=2, r=1824, f=0, d=2 * (20 + round(u * 100)), n=100))
    text = parse.report([parse.parse_log(mk(tmp_path, rows, name=name))], None, None)
    return [l for l in text.splitlines() if l.startswith("14 MHZ CONTROL")]


def test_control_line(tmp_path):
    assert control(tmp_path, [("P1C1", 4.0), ("P1C2", 21.02)]) == [
        "14 MHZ CONTROL P1C1: 4.00 T vs documented 4.00: OK",
        "14 MHZ CONTROL P1C2: 21.02 T vs documented 21.02: OK"]
    assert control(tmp_path, [("P1C1", 4.05), ("P1C2", 21.10)], "m.TXT") == [
        "14 MHZ CONTROL P1C1: 4.05 T vs documented 4.00: OK",
        "14 MHZ CONTROL P1C2: 21.10 T vs documented 21.02: MISMATCH"]
    assert control(tmp_path, [("P1C1", 4.0)], "n.TXT")[1] == \
        "14 MHZ CONTROL P1C2: NOT MEASURED"
    assert control(tmp_path, [], "e.TXT") == []


def test_b2is_note_names_ctc():
    note = parse.TAGS["B2IS"].note
    assert "15.6 kHz CTC DAC ISR" in note and "312" in note and "SD burst refill" in note


def two_runs(tmp_path, first, second):
    p = tmp_path / "R.TXT"
    raw = mk(tmp_path, *first, name="a.TXT").read_bytes() + \
        mk(tmp_path, *second, name="b.TXT").read_bytes()
    p.write_bytes(raw)
    return p


def test_multi_run_core_log(tmp_path):
    p = two_runs(tmp_path, ([row("CAL0", f=0x40)],), ([row("CAL0", f=0x41), row("CAL1", s=2)],))
    log = parse.parse_log(p)
    assert log.runs == 2 and log.ignored == []
    assert [(r.tag, r.f) for r in log.rows] == [("CAL0", 0x41), ("CAL1", 0x40)]
    text = parse.report([log], None, None)
    assert "RUNS: 2 (last used)" in text and "TRUNCATED" not in text


def test_truncated_earlier_run(tmp_path):
    p = two_runs(tmp_path, ([row("CAL0", f=0x40)], NR_OK, -1),
                 ([row("CAL0", f=0x41)],))
    log = parse.parse_log(p)
    assert log.runs == 2 and log.ignored == [1]
    assert [r.f for r in log.rows] == [0x41]
    text = parse.report([log], None, None)
    assert "RUNS: 2 (last used)" in text and "TRUNCATED RUN 1 ignored" in text
    single = parse.report([parse.parse_log(mk(tmp_path, [row("CAL0")], name="s.TXT"))],
                          None, None)
    assert "RUNS:" not in single


def test_truncated_last_run(tmp_path):
    p = two_runs(tmp_path, ([row("CAL0")],), ([row("CAL0")], NR_OK, -1))
    with pytest.raises(LogError, match="no #END"):
        parse.parse_log(p)


def test_q_field(tmp_path):
    rows = [row("P1NP", extra=" Q=213"), row("P1NP", extra=" Q=002")]
    log = parse.parse_log(mk(tmp_path, rows))
    assert log.rows[0].q == (2, 1, 3)
    text = parse.report([log], None, None)
    assert "Q=213" in text and "Q=002" in text


def verdict(tmp_path, nop_t, rd_t):
    # R=1824 so per-rep T equals the tick count; CAL per rep = 16; N=100 resolves 0.01 T
    rows = [row("CAL0", r=1824, f=0, d=16),
            row("P1NP", r=1824, f=0, d=16 + round(nop_t * 100), n=100),
            row("P1RD", r=1824, f=0, d=16 + round(rd_t * 100), n=100)]
    text = parse.report([parse.parse_log(mk(tmp_path, rows))], None, None)
    return [l for l in text.splitlines() if l.startswith("WAIT STATES")][0]


def test_wait_verdict(tmp_path):
    assert verdict(tmp_path, 4.0, 7.0) == "WAIT STATES: ABSENT"
    assert verdict(tmp_path, 5.0, 9.01) == "WAIT STATES: PRESENT"
    v = verdict(tmp_path, 6.0, 8.0)
    assert v.startswith("WAIT STATES: UNEXPLAINED") and "6.00" in v and "8.00" in v


def test_crossover_multi_run():
    rs = runs([("L048", 100), ("D048", 120), ("L056", 100), ("D056", 90)])
    assert parse.crossover(rs, "L", "D", 1, 1) == "54"
    rs.append(NxbRun("D056", 56, 1, 1, 0, 150, 2, "table"))
    # last D056 run (150) wins: DMA never beats CPU
    assert parse.crossover(rs, "L", "D", 1, 1) == "above 56 MULTI-RUN"
    text = parse.report([], rs, None, timing=(311, 228))
    assert "MULTI-RUN D056: 2" in text


def test_breakeven_pairs_cpu_baseline(tmp_path):
    # CAL0 = 0 T, R = 1: T/unit = D x 1824 / N. CPU 71.25 T/B at both sizes; the
    # blitter (Q=213) is 142.5 at 256 and 35.625 at 1024, so they cross at 768.
    rows = [row("CAL0", r=1, f=0, d=0),
            row("DFC1", r=1, f=0, d=10, n=256), row("DFC2", r=1, f=0, d=40, n=1024),
            row("DFB1", r=1, f=0, d=20, n=256, extra=" Q=213"),
            row("DFB2", r=1, f=0, d=20, n=1024, extra=" Q=213")]
    text = parse.report([parse.parse_log(mk(tmp_path, rows))], None, None)
    lines = [l for l in text.splitlines() if l.startswith("BREAK-EVEN")]
    assert lines == ["BREAK-EVEN part 1b fill BLT Q=213: 768"], lines


def test_multi_run_baseline():
    r = parse.parse_nxb(BASE / "NXBENCH-Q.TXT")
    multi = parse.multi_run_tags(r)
    for cpu, dma in (("L", "D"), ("FC", "FD")):
        hit = any(t.startswith((cpu, dma)) and t[len(cpu if t.startswith(cpu) else dma):].isdigit()
                  for t in multi)
        got = parse.crossover(r, cpu, dma, 311, 228)
        assert got.endswith(" MULTI-RUN") == hit
    assert "FC60" in multi


ISR_NOTE = ("Ratios include a small frame-ISR change since the baseline (im2_isr gained call kb_tick); "
            "NXB puts the live frame ISR under 1% of a row.")


def test_nxb_ratio_isr_note():
    runs = parse.parse_nxb(BASE / "NXBENCH-Q.TXT")
    tag = next(r.tag for r in runs if r.kind == "table")
    shown = parse.report([], runs, runs, timing=(311, 228), ratio_tags=[tag])
    assert "RATIO %s" % tag in shown
    assert shown.splitlines().count(ISR_NOTE) == 1
    quiet = parse.report([], runs, None, timing=(311, 228))
    assert ISR_NOTE not in quiet
