"""P4 Pi video tool against VLink, a PI303V follower model and a fake spi303 serve."""
import numpy as np
import pytest

import link
import mailbox as mbx
import parse
import pi303_prep
import pi303_video as pv
import sim_pi303v as sv
import tags
from sim_pi303v import MB, MAP, L2_LEN, FRONT_BANK, BACK_BANK

LOSS = 6_500_000            # loss above this actual rate: 6.5 (6.25) clean, 7.0 (6.94) not
NR_12, NR_13 = 0x12, 0x13


def rows(log, tag):
    return [r.fields for r in log.rows if r.tag == tag]


def go(tmp_path, plan=sv.PLAN, **kw):
    b = sv.Bench(tmp_path, **kw)
    rc = b.run(plan=plan)
    return rc, parse.parse_pilog(b.out + "/VIDEO.LOG"), b


@pytest.fixture(scope="module")
def full(tmp_path_factory):
    return go(tmp_path_factory.mktemp("full"))


def push_reqs(b, op=None, verify=None):
    return [r for r in b.serve.requests if (op is None or r["op"] == op)
            and (verify is None or r["verify"] == verify)]


def groups(b, pred):
    """Runs of consecutive serve requests matching pred."""
    out, cur = [], []
    for r in b.serve.requests:
        if pred(r):
            cur.append(r)
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def nr_writes(b):
    return [r for r in b.lk.trace if r.cmd == link.CMD_NR_W]


def flips(b):
    """(t, bank, other) per flip: NR $12 then NR $13."""
    ws = b.lk.nr_log
    assert len(ws) % 2 == 0 and len(ws) == len(nr_writes(b))
    out = []
    for (t, r12, bank), (_, r13, other) in zip(ws[0::2], ws[1::2]):
        assert (r12, r13) == (NR_12, NR_13)
        out.append((t, bank, other))
    return out


def test_rate_derates_one_step(tmp_path):
    rc, log, b = go(tmp_path, ceilings={0: 7_500_000, 1: 6_000_000})
    assert rc == 0
    assert [(r["prof"], r["hz"], r["mis"]) for r in rows(log, "P4SK")] == [
        (0, 7_000_000, 0), (6, 5_500_000, 0)]
    loads = [e[3] for e in b.nx.events if e[0] == "cmd" and e[2] == mbx.CMD_LOAD]
    assert loads == [0, 6]
    hz = [r["hz"] for r in b.serve.requests]
    n0 = len(hz) // 2
    assert set(hz[:n0]) == {7_000_000} and set(hz[n0:]) == {5_500_000}
    # merged requests repeat a slower rate: the step skips them
    out = tmp_path / "merged"
    out.mkdir()
    rc, log, b = go(out, ceilings={0: 7_500_000, 1: 7_500_000}, merged=(7_000_000,))
    assert [r["hz"] for r in rows(log, "P4SK")] == [6_500_000, 6_500_000]


def test_soak_steps_down_on_loss(tmp_path):
    rc, log, b = go(tmp_path, loss_above=LOSS)
    assert rc == 0
    sk = [(r["prof"], r["hz"], r["mis"] > 0) for r in rows(log, "P4SK")]
    assert sk == [(0, 7_000_000, True), (0, 6_500_000, False),
                  (6, 7_000_000, True), (6, 6_500_000, False)]
    first, clean = rows(log, "P4SK")[0:2]
    assert first["mis"] == 13 and first["bytes"] == L2_LEN      # stops after the first lossy push
    assert clean["mis"] == 0 and clean["bytes"] == sv.PLAN.soak_bytes
    assert [r["hz"] for r in b.serve.requests[:4]] == [7_000_000] + [6_500_000] * 3
    timed = push_reqs(b, verify=0)
    assert timed and {r["hz"] for r in timed} == {6_500_000}
    assert all(r["mis"] == 0 for r in rows(log, "P4SK") if r["hz"] == 6_500_000)
    assert all(r["bad"] == 0 for r in rows(log, "P4VF") + rows(log, "P4VS"))


def test_floor_skip(tmp_path):
    rc, log, b = go(tmp_path, loss_above=1_000_000,
                    ceilings={0: 3_000_000, 1: 2_000_000})
    assert rc != 0
    assert [(r["prof"], r["hz"]) for r in rows(log, "P4SK")] == [(0, 2_500_000), (0, 2_000_000)]
    assert ("P4SK", "FLOOR prof=0") in log.skips and ("P4SK", "FLOOR prof=6") in log.skips
    assert not rows(log, "P4TF") and not rows(log, "P4FR")
    cmds = [(e[2], e[3]) for e in b.nx.events if e[0] == "cmd"]
    assert cmds == [(mbx.CMD_LOAD, 0), (mbx.CMD_STOP, 0), (mbx.CMD_END, 0)]


def test_missing_p3sc_is_nop3(tmp_path):
    rc, log, b = go(tmp_path, ceilings={0: 7_500_000})
    assert rc != 0
    assert ("P4SK", "NOP3 prof=6") in log.skips
    assert [r["prof"] for r in rows(log, "P4SK")] == [0]
    assert {r["prof"] for r in rows(log, "P4FR")} == {0}
    loads = [e[3] for e in b.nx.events if e[0] == "cmd" and e[2] == mbx.CMD_LOAD]
    assert loads == [0]
    assert rows(log, "P4RF")[0]["saved"] == 1
    out = tmp_path / "nolog"
    out.mkdir()
    b = sv.Bench(out)
    b.spi_log = str(out / "missing.log")
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc != 0 and ("P4SK", "NOP3 prof=0") in log.skips and ("P4SK", "NOP3 prof=6") in log.skips
    assert not b.spawn.serves[0].requests
    assert [e[2] for e in b.nx.events if e[0] == "cmd"] == [mbx.CMD_END]


def test_timed_pass_has_no_readback(full):
    rc, log, b = full
    timed = groups(b, lambda r: r["verify"] == 0)
    assert len(timed) == 4                       # tf and ts, both profiles
    assert all(r["hb"] == 0 for g in timed for r in g)
    for g in timed:
        t0 = g[0]["t"]
        t1 = min(t for t, _, _ in flips(b) if t >= g[-1]["end"])
        for r in b.lk.trace:
            if not t0 <= r.t <= t1:
                continue
            if r.phase == "push":
                assert r.cmd == link.CMD_SRAM_W
                continue
            assert r.phase is None, r            # no verify reads, no C heartbeat
            if r.cmd == link.CMD_SRAM_R:
                assert (r.addr, r.n) in ((MB + mbx.OFF_STATE, 1), (MB + mbx.OFF_HB_PI, 2)), r
            elif r.cmd == link.CMD_SRAM_W:
                assert (r.addr, r.n) == (MB + mbx.OFF_HB_PI, 2), r
            else:
                assert r.cmd in (link.CMD_NR_R, link.CMD_NR_W), r
                assert r.addr in ((0x1E, 0x1F) if r.cmd == link.CMD_NR_R else (NR_12, NR_13))
            assert r.payload_hz == link.HDR_HZ


def test_one_pipe_exchange_per_frame(full):
    rc, log, b = full
    n = len(b.frames)
    s = sv.PLAN.soak_bytes // L2_LEN
    ops = [(r["op"], r["verify"]) for r in b.serve.requests]
    P, S = link.OP_PUSH, link.OP_PUSHSPANS
    one = ([(P, 1)] * s + [(P, 0)] * n + [(P, 1)] * 2 + [(S, 0)] * (n - 2)
           + [(P, 1)] * n + [(P, 1)] * 2 + [(S, 1)] * (n - 2))
    assert ops == one + one
    fr = rows(log, "P4FR")
    assert len(fr) == 2 * (2 * n + 2 * (n - 2))
    assert [r["pass"] for r in fr[:2 * (n + n - 2)]] == [0] * n + [1] * (n - 2) + [2] * n + \
        [3] * (n - 2)
    assert all(r["bytes"] == L2_LEN for r in fr if r["pass"] in (0, 2))
    spans = [r for r in b.serve.requests if r["op"] == S]
    assert [r["bytes"] for r in fr if r["pass"] in (1, 3)] == \
        [sum(ln for _, ln in q["spans"]) for q in spans]
    timed_full = [q for q in b.serve.requests if q["op"] == P and not q["verify"]]
    assert [r["ns"] for r in fr if r["pass"] == 0] == \
        [int(round((q["end"] - q["t"]) * 1e9)) for q in timed_full]


def test_tail_verify_catches_loss(tmp_path):
    b = sv.Bench(tmp_path)
    n = len(b.frames)
    s = sv.PLAN.soak_bytes // L2_LEN
    vf3 = s + n + 2 + (n - 2) + 3                 # profile 0, verified full, frame 3
    vs4 = vf3 - 3 + n + 2 + 2                     # profile 0, verified spans, frame 4
    tf1 = s + 1                                   # timed: no read-back, nothing seen
    b.spawn.loss_req = {vf3, vs4, tf1}
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc == 0
    req = b.spawn.serves[0].requests
    assert req[vf3]["verify"] and req[vf3]["bad"] == req[vf3]["ntx"] == 13
    assert req[vs4]["op"] == link.OP_PUSHSPANS and req[vs4]["bad"] >= 1
    vf = [r for r in rows(log, "P4VF") if r["prof"] == 0][0]
    vs = [r for r in rows(log, "P4VS") if r["prof"] == 0][0]
    assert vf == {"prof": 0, "frames": n, "bad": 1}
    assert vs == {"prof": 0, "frames": n - 2, "bad": 1}
    fr = [r for r in rows(log, "P4FR") if r["prof"] == 0]
    assert [r["idx"] for r in fr if r["pass"] == 2 and r["drop"]] == [3]
    assert [r["idx"] for r in fr if r["pass"] == 3 and r["drop"]] == [4]
    assert req[tf1]["bad"] == 0 and not [r for r in fr if r["pass"] == 0 and r["drop"]]
    assert all(r["bad"] == 0 for r in rows(log, "P4VF") + rows(log, "P4VS") if r["prof"] == 6)


def test_flip_gap_histogram(full):
    rc, log, b = full
    fl = flips(b)
    fr = rows(log, "P4FR")
    assert len(fl) == len(fr) + 8                 # 2 prime flips before each span pass
    timed = groups(b, lambda r: r["verify"] == 0)
    agg = [rows(log, "P4TF")[0], rows(log, "P4TS")[0], rows(log, "P4TF")[1],
           rows(log, "P4TS")[1]]
    for g, row in zip(timed, agg):
        ts = [f for f in fl if g[0]["t"] <= f[0]][:len(g)]
        lines = [sv.raster_line(t) for t, _, _ in ts]
        want = [0, 0, 0]
        for (t1, _, _), l1, (t2, _, _), l2 in zip(ts, lines, ts[1:], lines[1:]):
            want[min(sv.expected_gap(t1, l1, t2, l2), 3) - 1] += 1
        got = [row["gap1"], row["gap2"], row["gap3"]]
        assert got == want, (got, want)
        assert sum(got) == row["frames"] - 1
        assert abs(row["ns"] - (ts[-1][0] - g[0]["t"]) * 1e9) < 1000   # first push to last flip
    tf, ts_ = rows(log, "P4TF")[0], rows(log, "P4TS")[0]
    assert tf["gap3"] >= 1 and ts_["gap1"] >= 1   # full frames take ~3 frames, spans one
    p = sv.PERIOD
    assert pv.vblanks(0.0, 100, 0.001, 200, p) == 1
    assert pv.vblanks(0.0, 250, 0.004, 5, p) == 0
    assert pv.vblanks(0.0, 195, 3 * p, 195, p) == 3
    assert pv.vblanks(0.0, 300, (12 + 312 + 192) / 312 * p, 192, p) == 2


def test_flip_in_vblank_counted(tmp_path):
    b = sv.Bench(tmp_path)
    seen = [0]

    def hook(r):
        if r.cmd == link.CMD_NR_W and r.addr == NR_12:
            seen[0] += 1
            if seen[0] in (4, 6):               # profile 0 tf frames 3 and 5
                b.w.t += 0.009                  # the post-flip read lands in active display
            elif seen[0] == 5:                  # frame 4: the next frame's vblank, line >= 192
                b.w.t += sv.PERIOD
    b.w.hooks.append(hook)
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc == 0
    n = len(b.frames)
    tf = rows(log, "P4TF")
    assert tf[0]["flips_vbl"] == n - 3 and tf[1]["flips_vbl"] == n
    fr = [r for r in rows(log, "P4FR") if r["prof"] == 0 and r["pass"] == 0]
    assert [r["idx"] for r in fr if r["drop"]] == [3, 4, 5]
    assert all(r["l0"] >= 192 for r in fr)
    assert [r["idx"] for r in fr if r["l1"] < 192] == [3, 5]


class Clock:
    def __init__(self):
        self.t = 0.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


class StepTicks:
    """Heartbeat stand-in: each tick between polls moves the clock to the next poll time."""

    def __init__(self, clock, steps):
        self.clock, self.steps = clock, iter(steps)

    def tick(self):
        self.clock.t += next(self.steps, 0.0005)


class RasterStub:
    """312 lines at sv.PERIOD, line 200 at t = 0 (the previous flip)."""

    def __init__(self, clock):
        self.clock = clock
        self.writes = []

    def raster_line(self):
        p = sv.PERIOD
        return int(((self.clock.t + 200 / 312 * p) % p) / p * 312)

    def nr_write(self, reg, val):
        self.writes.append((reg, val))


@pytest.mark.parametrize("stall, late", [(False, False), (True, True)])
def test_flip_past_intended_vblank_dropped(stall, late):
    """A poll stalled across a whole frame misses the vblank the frame was ready for."""
    clk = Clock()
    stub = RasterStub(clk)
    r = pv.Run(stub, MB, ".", ".", ".", sv.BUNDLE, "spi303", None, MAP, clk, sv.PLAN,
               None, None)
    r.hb = StepTicks(clk, [sv.PERIOD] if stall else [])
    r.period, r.obs, r.since_flip = sv.PERIOD, (0.0, 200), 0
    clk.t = 0.057                               # a 57 ms push: first poll at line ~140
    l0, l1, in_vbl, gap, got_late, t = r.flip()
    assert l0 >= 192 and l1 >= 192 and in_vbl
    assert got_late is late and gap == (4 if stall else 3)
    assert stub.writes == [(NR_12, BACK_BANK), (NR_13, FRONT_BANK)]


def test_frames_via_serve_not_per_transaction(full):
    rc, log, b = full
    assert b.spawn.calls == [["spi303", "serve"]]
    assert all(r["op"] in (link.OP_PUSH, link.OP_PUSHSPANS) for r in b.serve.requests)
    fast = [r for r in b.lk.trace if r.payload_hz > link.HDR_HZ]
    assert fast and all(r.phase == "push" for r in fast)
    assert all(r.phase in ("push", "verify", "chb") or r.payload_hz == link.HDR_HZ
               for r in b.lk.trace)


def test_hb_pi_during_soak_and_passes(full):
    rc, log, b = full
    loads = [c[0] for c in b.nx.cmd_writes if c[2] == mbx.CMD_LOAD]
    end = [c[0] for c in b.nx.cmd_writes if c[2] == mbx.CMD_END][0]
    timed = [(r["t"], r["end"]) for r in b.serve.requests if not r["verify"]]
    bumps = [r.t for r in b.lk.trace if r.cmd == link.CMD_SRAM_W
             and r.addr == MB + mbx.OFF_HB_PI and loads[0] <= r.t <= end]
    marks = [loads[0]] + bumps + [end]
    worst = 0.0
    for a, c in zip(marks, marks[1:]):
        inside = sum(max(0.0, min(c, e) - max(a, s)) for s, e in timed)
        worst = max(worst, c - a - inside)
    assert len(bumps) > 20 and worst <= 0.13, (len(bumps), worst)
    soak = [r for r in b.serve.requests if r["verify"]]
    assert soak and all(r["hb"] == MB for r in soak)
    chb = [r for r in b.lk.trace if r.phase == "chb" and r.cmd == link.CMD_SRAM_W]
    s0 = b.serve.requests[0]
    assert [r for r in chb if s0["t"] <= r.t <= s0["end"]]       # C bumps inside the soak
    states = [e[2] for e in b.nx.events if e[0] == "state"]
    assert states == [4, 2] and b.nx.pibusy is False


def test_spans_diffed_against_n_minus_2(full):
    rc, log, b = full
    f = b.frames
    n = len(f)
    spans = [r for r in b.serve.requests if r["op"] == link.OP_PUSHSPANS][:n - 2]
    for i, r in zip(range(2, n), spans):
        img = bytearray(f[i - 2])
        for off, part in r["data"]:
            img[off:off + len(part)] = part
        assert bytes(img) == f[i]
        n1 = bytearray(f[i - 2])
        for off, part in pv.span_list(f[i - 1], f[i]):
            n1[off:off + len(part)] = part
        assert bytes(n1) != f[i]                  # an N-1 diff would leave stale bytes
    shown = b.lk.nrs[NR_12]
    hidden = FRONT_BANK if shown == BACK_BANK else BACK_BANK
    m = b.lk.sram
    assert bytes(m[sv.bank_phys(shown):sv.bank_phys(shown) + L2_LEN]) == f[-1]
    assert bytes(m[sv.bank_phys(hidden):sv.bank_phys(hidden) + L2_LEN]) == f[-2]


def test_video_imports_no_pil():
    import subprocess
    import sys
    code = ("import sys; sys.path.insert(0, %r); import pi303_video; "
            "print(int('PIL' in sys.modules))" % pv.HERE)
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert out.stdout.strip() == "0", out.stderr
    assert pi303_prep.GAP is pv.span_list.__globals__["GAP"]


def test_span_lens_match_prep():
    f = sv.make_frames(4)
    a, c = (np.frombuffer(x, np.uint8) for x in (f[0], f[2]))
    got = pv.span_list(f[0], f[2])
    assert [len(d) for _, d in got] == pi303_prep.span_lens(a, c).tolist()
    assert pv.span_list(f[1], f[1]) == []


def test_flip_banks_alternate_from_map(full):
    rc, log, b = full
    fl = flips(b)
    banks = [bk for _, bk, _ in fl]
    assert banks[0] == BACK_BANK
    assert all(x != y for x, y in zip(banks, banks[1:]))
    assert all(o == (FRONT_BANK if bk == BACK_BANK else BACK_BANK) for _, bk, o in fl)
    for t, bk, _ in fl:
        q = max((x for x in b.serve.requests if x["end"] <= t), key=lambda x: x["end"])
        assert q["base"] == sv.bank_phys(bk)
    assert {r.addr for r in nr_writes(b)} == {NR_12, NR_13}


def test_soak_never_writes_outside_back_buffer(full):
    rc, log, b = full
    s = sv.PLAN.soak_bytes // L2_LEN
    n = len(b.frames)
    per = s + n + 2 + (n - 2) + n + 2 + (n - 2)
    for soak in (b.serve.requests[:s], b.serve.requests[per:per + s]):
        bases = {r["base"] for r in soak}
        assert len(bases) == 1
        base = bases.pop()
        t0, t1 = soak[0]["t"], soak[-1]["end"]
        shown = [bk for t, bk, _ in flips(b) if t < t0]
        shown_bank = shown[-1] if shown else FRONT_BANK
        assert base == sv.bank_phys(BACK_BANK if shown_bank == FRONT_BANK else FRONT_BANK)
        ws = [r for r in b.lk.trace if t0 <= r.t <= t1 and r.cmd == link.CMD_SRAM_W
              and r.phase == "push"]
        assert ws and all(base <= r.addr and r.addr + r.n <= base + L2_LEN for r in ws)
        assert not [r for r in b.lk.trace if t0 <= r.t <= t1 and r.cmd == link.CMD_NR_W]
    for r in b.lk.trace:
        if r.phase == "push":
            assert any(p <= r.addr and r.addr + r.n <= p + L2_LEN
                       for p in (MAP["l2_front_phys"], MAP["l2_back_phys"])), r.addr


def first_state_change(trace):
    for i, r in enumerate(trace):
        if r.cmd != link.CMD_SRAM_R or not r.addr <= MB + 13 < r.addr + r.n:
            continue
        if r.data[MB + 13 - r.addr] != 1:
            return i
    return None


def test_stops_writes_when_state_changes(tmp_path):
    b = sv.Bench(tmp_path)

    def hook(r):
        if b.spawn.serves and len(b.serve.requests) == 6 and b.lk.sram[MB + 13] == 1:
            b.lk.sram[MB + 13] = 3
            b.nx.mode, b.nx.due = "done", None
    b.w.hooks.append(hook)
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc != 0
    assert ("PIST", "STATE") in log.skips and ("PI3S", "STATE3") in log.skips
    k = first_state_change(b.lk.trace)
    assert k is not None
    assert [r for r in b.lk.trace[k:] if r.cmd in (link.CMD_SRAM_W, link.CMD_BRAM_W,
                                                   link.CMD_NR_W)] == []
    assert len(b.serve.requests) == 6 and b.serve.closed


def test_noload_skip(tmp_path):
    rc, log, b = go(tmp_path, stall_load=True)
    assert rc != 0
    assert ("P4SK", "NOLOAD prof=0") in log.skips and ("P4SK", "NOLOAD prof=6") in log.skips
    assert not b.serve.requests
    cmds = [(e[2], e[3]) for e in b.nx.events if e[0] == "cmd"]
    assert cmds == [(mbx.CMD_LOAD, 0), (mbx.CMD_STOP, 0), (mbx.CMD_LOAD, 6), (mbx.CMD_STOP, 0),
                    (mbx.CMD_END, 0)]


def test_shown_bank_unknown_skips(tmp_path):
    b = sv.Bench(tmp_path)
    b.lk.nrs[NR_12] = BACK_BANK
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc != 0 and log.skips == [("P4SK", "SHOWN nr12=%d" % BACK_BANK)]
    assert not b.spawn.calls and not b.lk.nr_log
    assert not [r for r in b.lk.trace if r.cmd == link.CMD_SRAM_W
                and not MB <= r.addr < MB + 32]
    assert [e[2] for e in b.nx.events if e[0] == "cmd"] == [mbx.CMD_END]
    assert rows(log, "P4RF")[0]["saved"] == 1


def test_state_change_in_load_checks(tmp_path):
    """hb_next and period polls gate on state: no hb_pi bump once state != 1 is seen."""
    for when in ("load", "period"):
        out = tmp_path / when
        out.mkdir()
        b = sv.Bench(out)
        changed = []

        def hook(r, b=b, when=when, changed=changed):
            loaded = [e for e in b.nx.events if e[0] == "cmd" and e[2] == mbx.CMD_LOAD]
            hit = r.cmd == link.CMD_NR_R if when == "period" else r.cmd == link.CMD_SRAM_R
            if loaded and hit and b.lk.sram[MB + 13] == 1:
                b.lk.sram[MB + 13] = 3
                b.nx.mode, b.nx.due = "done", None
                changed.append(r.t)
        b.w.hooks.append(hook)
        rc = b.run(plan=pv.Plan(soak_bytes=sv.PLAN.soak_bytes, period_wraps=25))
        log = parse.parse_pilog(b.out + "/VIDEO.LOG")
        assert rc != 0 and ("PIST", "STATE") in log.skips, when
        k = first_state_change(b.lk.trace)
        assert [r for r in b.lk.trace[k:] if r.cmd in (link.CMD_SRAM_W, link.CMD_NR_W)] == []
        late = [r for r in b.lk.trace if r.t > changed[0] and r.cmd == link.CMD_SRAM_W]
        assert len(late) <= 1, (when, len(late))    # at most the bump already under way
        assert not b.serve.requests


def test_period_median_ignores_a_stall(tmp_path):
    b = sv.Bench(tmp_path)
    n = [0]

    def hook(r):
        if r.cmd == link.CMD_NR_R and b.nx.active:
            n[0] += 1
            if n[0] == 600:
                b.w.t += 2 * sv.PERIOD          # one wrap interval three frames long
    b.w.hooks.append(hook)
    assert b.run() == 0
    r = rows(parse.parse_pilog(b.out + "/VIDEO.LOG"), "P4SK")[0]
    assert abs(r["frame_ns"] - sv.PERIOD * 1e9) <= sv.PERIOD * 1e9 * 0.005, r


def test_frame_rows_written_after_pass(tmp_path, monkeypatch):
    import pilog
    b = sv.Bench(tmp_path)
    when = []
    real = pilog.PiLogWriter.row

    def row(self, tag, **kv):
        when.append((b.w.t, tag))
        return real(self, tag, **kv)
    monkeypatch.setattr(pilog.PiLogWriter, "row", row)
    assert b.run() == 0
    fl = flips(b)
    for g in groups(b, lambda r: r["verify"] == 0):
        t0 = g[0]["t"]
        t1 = min(t for t, _, _ in fl if t >= g[-1]["end"])
        assert not [w for w in when if t0 <= w[0] <= t1]
    assert sum(1 for _, tag in when if tag == "P4FR") == 4 * (2 * 6 - 2)


def test_period_measured_from_raster(full):
    rc, log, b = full
    for r in rows(log, "P4SK"):
        assert abs(r["frame_ns"] - sv.PERIOD * 1e9) <= sv.PERIOD * 1e9 * 0.005, r


def test_clean_run_end_ack_with_state4(full):
    rc, log, b = full
    seq, t = next((c[1], c[0]) for c in b.nx.cmd_writes if c[2] == mbx.CMD_END)
    head = next(r.data for r in b.lk.trace if r.t > t and r.cmd == link.CMD_SRAM_R
                and r.addr == MB and r.n == mbx.HEAD_LEN and r.data[mbx.OFF_ACK] == seq)
    assert head[mbx.OFF_STATE] == mbx.STATE_EXITING
    assert rc == 0 and ("PIST", "STATE") not in log.skips


def test_fetch_result_and_state3(tmp_path):
    text = b"#CORE303 PI ac7d65a\n#END 0000\n"
    rc, log, b = go(tmp_path, result=text)
    assert rc == 0 and (tmp_path / "out" / "PI_PI303V.LOG").read_bytes() == text
    assert rows(log, "P4RF") == [{"state": 2, "phys": sv.RESULT, "len": len(text), "saved": 1}]
    out = tmp_path / "s3"
    out.mkdir()
    rc, log, b = go(out, result=text, final_state=3)
    assert rc != 0 and ("PI3S", "STATE3") in log.skips
    assert (out / "out" / "PI_PI303V.LOG").read_bytes() == text
    out = tmp_path / "range"
    out.mkdir()
    rc, log, b = go(out, result=text, result_at=sv.RESULT + 0xC000)
    assert ("P4RF", "RANGE") in log.skips and not (out / "out" / "PI_PI303V.LOG").exists()


def test_p4fr_registered_and_parses(full):
    rc, log, b = full
    for t in ("P4FR", "P4RF", "P4MB", "P4SK", "P4TF", "P4TS", "P4VF", "P4VS"):
        assert t in tags.PI_TAGS, t
    assert not set(tags.TAGS) & set(tags.PI_TAGS)
    fr = rows(log, "P4FR")
    assert fr and all(list(r) == ["pass", "prof", "idx", "ns", "bytes", "l0", "l1", "drop"]
                      for r in fr)
    assert {r["pass"] for r in fr} == set(pv.PASSES.values()) == {0, 1, 2, 3}


def test_log_parses(full):
    rc, log, b = full
    assert rc == 0
    assert log.tool == "pi303_video" and log.bundle == sv.BUNDLE
    assert {"spi_max_saved", "spi_open", "frames", "frames_hash"} <= set(log.env)
    assert log.env["frames"] == str(len(b.frames))
    assert log.spi["core_clk_src"] == "none"
    assert {r.tag for r in log.rows} == {"P4SK", "P4TF", "P4TS", "P4VF", "P4VS", "P4FR",
                                         "P4RF"}
    assert log.skips == []
    assert list(rows(log, "P4TF")[0]) == ["prof", "frames", "ns", "flips_vbl", "gap1", "gap2",
                                          "gap3"]
    assert list(rows(log, "P4VS")[0]) == ["prof", "frames", "bad"]
    assert list(rows(log, "P4SK")[0]) == ["prof", "hz", "mis", "bytes", "frame_ns"]
    with open(b.out + "/VIDEO.LOG", "rb") as f:
        assert f.read().count(b"\r") == 0
    assert b.nx.bad == 0


def test_read_map(tmp_path):
    p = tmp_path / "PI303V.MAP"
    p.write_bytes("".join("%s=%06X\n" % kv for kv in MAP.items()).encode("ascii"))
    assert pv.read_map(str(p)) == MAP
    for k, v in (("l2_back_phys", MAP["mix_src_phys"]), ("l2_back_bank", 23),
                 ("l2_front_phys", 0x1F8000)):
        bad = dict(MAP, **{k: v})
        p.write_bytes("".join("%s=%06X\n" % kv for kv in bad.items()).encode("ascii"))
        with pytest.raises(ValueError):
            pv.read_map(str(p))
    p.write_bytes(b"mbox_phys=080000\n")
    with pytest.raises(ValueError):
        pv.read_map(str(p))


def test_frames_wrong_size_skips(tmp_path):
    b = sv.Bench(tmp_path)
    with open(b.frames_dir + "/F002.raw", "ab") as f:
        f.write(b"x")
    rc = b.run()
    log = parse.parse_pilog(b.out + "/VIDEO.LOG")
    assert rc != 0 and ("P4TF", "FRAMES") in log.skips and not b.spawn.calls
    assert not [r for r in b.lk.trace if r.cmd in (link.CMD_SRAM_W, link.CMD_NR_W)]


def test_cli_lock_busy(tmp_path):
    p = tmp_path / "PI303V.MAP"
    p.write_bytes("".join("%s=%06X\n" % kv for kv in MAP.items()).encode("ascii"))

    class Busy:
        def open(self, clock=None):
            raise link.BusBusy("busy")

        def close(self):
            raise AssertionError("never opened")
    rc = pv.cli(["--map", str(p), "--spi-log", "x", "--frames", "y", "--out", str(tmp_path),
                 "--bundle", sv.BUNDLE], link_factory=Busy)
    log = parse.parse_pilog(tmp_path / "VIDEO.LOG")
    assert rc == 2 and log.skips == [("BUSY", "LOCK")] and log.rows == []


def test_bundle_lists_video():
    names = (pv.HERE + "/BUNDLE.txt")
    with open(names, encoding="ascii") as f:
        listed = f.read().split()
    assert "pi303_video.py" in listed and "sim_pi303v.py" not in listed
