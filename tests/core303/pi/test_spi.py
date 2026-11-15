"""P3 Pi orchestrator against SimLink, a scripted PI303 mailbox model and a fake spi303."""
import shutil
import struct
import subprocess
from pathlib import Path

import pytest

import link
import mailbox as mbx
import parse
import pi303_spi
import sim_pi303 as sp
import tags
from sim_pi303 import MB, SCRATCH

HERE = Path(__file__).parent
ROOT = HERE.parent.parent.parent
HOST = ROOT / "build" / "core303" / "host"
GCC = Path(r"C:\ProgramData\mingw64\mingw64\bin\gcc.exe")
LOSS = 7_000_000            # loss above this actual rate: 7.0 MHz (6.94) clean, 7.5 (7.35) not


def rows(log, tag):
    return [r.fields for r in log.rows if r.tag == tag]


def go(tmp_path, plan=sp.PLAN, **kw):
    w, lk, nx, tool = sp.make(**kw)
    rc = sp.run_main(tmp_path, w, lk, tool, plan=plan)
    return rc, parse.parse_pilog(tmp_path / "SPI.LOG"), (w, lk, nx, tool)


@pytest.fixture(scope="module")
def full(tmp_path_factory):
    out = tmp_path_factory.mktemp("full")
    return go(out) + (out,)


@pytest.fixture(scope="module")
def lossy(tmp_path_factory):
    out = tmp_path_factory.mktemp("lossy")
    return go(out, loss_above=LOSS) + (out,)


def test_selftest_failure_skips(tmp_path):
    rc, log, (_, lk, _, tool) = go(tmp_path, selftest_ok=False)
    assert rc != 0
    assert ("P3FR", "FRAMING") in log.skips
    assert not rows(log, "P3WS") and not rows(log, "P3TE")
    assert [c[1] for c in tool.calls] == ["selftest"]
    out = tmp_path / "nr"
    out.mkdir()
    rc, log, _ = go(out, ignore_nr_writes=True)
    assert rc != 0 and ("P3FR", "FRAMING") in log.skips and not rows(log, "P3WS")


def test_sweep_stops_two_past_failure(lossy):
    rc, log, _, _ = lossy
    reqs = []
    for r in rows(log, "P3WS"):
        if r["req_hz"] not in reqs:
            reqs.append(r["req_hz"])
    assert reqs[-3:] == [7_500_000, 8_000_000, 8_500_000]
    assert reqs == [h for h in pi303_spi.LADDER if h <= 8_500_000]
    for h in (7_500_000, 8_000_000, 8_500_000):
        assert [r["rep"] for r in rows(log, "P3WS") if r["req_hz"] == h] == [0]
    assert [r["rep"] for r in rows(log, "P3WS") if r["req_hz"] == 7_000_000] == [0, 1, 2]
    for tag in ("P3WB", "P3RD", "P3WP"):
        assert max(r["req_hz"] for r in rows(log, tag)) <= 8_500_000, tag
    assert max(r["req_hz"] for r in rows(log, "P3WB")) == 8_500_000
    assert max(r["req_hz"] for r in rows(log, "P3RD")) == 8_500_000
    for p in sp.PLAN.profiles:
        assert max(r["req_hz"] for r in rows(log, "P3SR") if r["prof"] == p) == 8_500_000


def test_ceiling_with_injected_loss(lossy):
    rc, log, (_, lk, nx, tool), _ = lossy
    assert rc == 0
    assert rows(log, "P3CE") == [{"sram_hz": 7_000_000, "b7_hz": 7_000_000,
                                  "read_hz": 7_000_000}]
    bad = [r for r in rows(log, "P3WS") if r["req_hz"] == 7_500_000][0]
    assert bad["mis"] > 0 and bad["bad_tx"] == 8 and bad["first_tx"] == 0
    assert bad["first"] == 100 and bad["shift"] == 1
    assert all(r["mis"] == 0 for r in rows(log, "P3WS") if r["req_hz"] <= 7_000_000)
    assert [r["chunk"] for r in rows(log, "P3CH")] == [64, 256, 1024, 4000]
    assert all(r["hz"] == 7_000_000 and r["mis"] == 0 for r in rows(log, "P3CH"))
    assert [r["ceiling_hz"] for r in rows(log, "P3SC")] == [7_000_000, 7_000_000]
    for p in sp.PLAN.profiles:
        hz = [r["hz"] for r in rows(log, "P3SV") if r["prof"] == p]
        assert hz == [7_000_000, 4_000_000, 2_000_000]


def test_quiet_has_zero_transfers(full):
    rc, log, (w, lk, nx, tool), _ = full
    quiets = [s for s in nx.sends if s[1] == mbx.CMD_QUIET]
    assert len(quiets) == 3
    for seq, _, row, _, us in quiets:
        t, end, _ = next(a for a in nx.ack_writes if a[2] == seq)
        lo, hi = end + 0.001, t + us / 1e6
        inside = [r for r in lk.trace if lo < r.t < hi]
        assert inside == [], (row, inside[:3])
        assert [r for r in lk.trace if end < r.t <= lo
                and not (r.cmd == link.CMD_SRAM_R and r.addr == MB + mbx.OFF_ACK)] == []
    assert [r["row"] for r in rows(log, "P3HQ")] == [5, 0, 1]
    assert [r["us"] for r in rows(log, "P3HQ")] == [100_000, 100_000, 120_000]


def test_headers_always_2mhz(full):
    rc, log, (w, lk, nx, tool), _ = full
    assert lk.header_hz_check
    assert lk.trace and all(r.header_hz == link.HDR_HZ for r in lk.trace)
    fast_reads = [r for r in lk.trace if r.cmd in (link.CMD_SRAM_R, link.CMD_BRAM_R)
                  and r.payload_hz > link.HDR_HZ]
    assert fast_reads and all(r.phase == "read" for r in fast_reads)
    mb_writes = [r for r in lk.trace if r.cmd == link.CMD_SRAM_W and MB <= r.addr < MB + 32]
    assert mb_writes and all(r.payload_hz == link.HDR_HZ for r in mb_writes)
    assert all(r.n in (1, 2, 4) for r in mb_writes)


def test_starvation_skip_without_heartbeat(tmp_path):
    plan = pi303_spi.Plan(**{**sp.PLAN.__dict__, "profiles": (0, 1, 2)})
    rc, log, (w, lk, nx, tool) = go(tmp_path, plan=plan, stall_hb_next_on_load=True)
    assert sorted({r["prof"] for r in rows(log, "P3SV")}) == [0]
    assert [r["prof"] for r in rows(log, "P3SC")] == [0]
    reasons = [why for tg, why in log.skips if tg == "P3SV"]
    assert len(reasons) == 6 and all(why.startswith("NOLOAD") for why in reasons)
    assert sum(1 for tg, why in log.skips if tg == "P3SC" and why.startswith("NOLOAD")) == 2
    loads = [e[3] for e in nx.events if e[0] == "cmd" and e[2] == mbx.CMD_LOAD]
    assert loads == [0, 1, 2]


def test_handover_yield_sequence(full):
    rc, log, (w, lk, nx, tool), _ = full
    assert rc == 0
    cmds = [e[2] for e in nx.events if e[0] == "cmd"]
    assert cmds[0] == mbx.CMD_HANDOVER and cmds[-1] == mbx.CMD_END
    leader = [(e[1], e[2]) for e in nx.events if e[0] == "leader"]
    assert [v for _, v in leader] == [1, 0]
    t_back = leader[1][0]
    first_load = next(c for c in nx.cmd_writes if c[2] == mbx.CMD_LOAD)
    assert first_load[0] > t_back and first_load[3] == 0
    assert len(nx.streams) == 7 and len(tool.streams) == 7
    for st, fs in zip(nx.streams, tool.streams):
        ack = next(a for a in nx.ack_writes if a[2] == st["seq"])
        stop_ack = next(a for a in nx.ack_writes if a[2] == st["stop_seq"])
        assert fs.started_t is not None and ack[0] > fs.started_t
        assert fs.stop_t is not None and stop_ack[0] >= fs.stop_t
        assert fs.why == 0 and fs.ntx > 0
        assert not st["nostream"]
        if st["tgt"] == 1:
            assert st["ck"] == 0, st
    targets = [s.target for s in tool.streams]
    assert targets[0] == "0x%X" % sp.MAP["u_phys"] and targets[2] == "bram7"
    assert targets[1] == "0x%X" % sp.MAP["sled_phys"]
    assert targets[4] == "bram5:0x%X" % sp.MAP["r5_off"]
    lens = [len(s.data) for s in tool.streams]
    assert lens == [512, 0x100, 0x2000, 0x80, 0x80, 0x40, 0x100]
    assert tool.streams[6].data == bytes([0x3C]) * 0x100
    hs = rows(log, "P3HS")
    assert [(r["row"], r["tgt"]) for r in hs] == [(0, 0), (0, 1), (0, 2), (1, 1), (2, 1),
                                                   (3, 1), (4, 1)]
    ceil = rows(log, "P3CE")[0]["sram_hz"]
    assert all(r["hz"] == ceil and r["stop"] == 0 and r["ntx"] > 0 for r in hs)
    states = [e[2] for e in nx.events if e[0] == "state"]
    assert states == [4, 2] and nx.pibusy is False      # hb_pi settled after the END ack


def test_fetch_result_buffer(tmp_path):
    text = b"#CORE303 PI 56172de\n#NR 01=33\n#SRAM 2048\nCAL0 x\n#END 0001\n"
    rc, log, _ = go(tmp_path, result=text)
    assert rc == 0
    assert (tmp_path / "PI_PI303.LOG").read_bytes() == text
    assert rows(log, "P3RF") == [{"state": 2, "phys": sp.RESULT, "len": len(text), "saved": 1}]
    assert ("PI3S", "STATE3") not in log.skips
    out3 = tmp_path / "s3"
    out3.mkdir()
    rc, log, (w, lk, nx, tool) = go(out3, result=text, final_state=3)
    assert rc != 0
    assert (out3 / "PI_PI303.LOG").read_bytes() == text
    assert ("PI3S", "STATE3") in log.skips
    assert rows(log, "P3RF")[0]["state"] == 3
    assert nx.pibusy is False


def test_python_path_capped_at_c_ceiling(lossy):
    rc, log, (w, lk, nx, tool), _ = lossy
    ceil = rows(log, "P3CE")[0]["sram_hz"]
    wp = rows(log, "P3WP")
    assert wp and max(r["req_hz"] for r in wp) == ceil
    assert all(r["mis"] == 0 for r in wp)
    py = [r for r in lk.trace if r.phase is None and not r.actor
          and r.cmd == link.CMD_SRAM_W and r.payload_hz > link.HDR_HZ]
    assert py and max(r.payload_hz for r in py) <= ceil
    assert all(SCRATCH <= r.addr < SCRATCH + 0x40000 for r in py)
    cp = rows(log, "P3CP")
    assert [r["chunk"] for r in cp] == [64, 256, 1024, 4000]
    assert all(r["hz"] == ceil for r in cp)


def test_hb_pi_during_sweeps(full):
    rc, log, (w, lk, nx, tool), _ = full
    start = next(c[0] for c in tool.calls if c[1] == "write")
    end = next(c[0] for c in nx.cmd_writes if c[2] == mbx.CMD_HANDOVER)
    bumps = [r.t for r in lk.trace if r.cmd == link.CMD_SRAM_W and r.addr == MB + 16
             and start <= r.t <= end]
    marks = [start] + bumps + [end]
    gaps = [b - a for a, b in zip(marks, marks[1:])]
    assert len(bumps) > 100
    assert max(gaps) <= 0.13, max(gaps)


def test_hb_pi_long_passes(tmp_path):
    """32 KB passes: a 2 MHz read-back alone outlasts 100 ms, so ticks must be per transaction."""
    plan = pi303_spi.Plan(**{**sp.PLAN.__dict__, "ladder": pi303_spi.LADDER[:4],
                             "pass_bytes": 0x8000, "chunk_bytes": 0x8000, "clean_runs": 1,
                             "profiles": ()})
    rc, log, (w, lk, nx, tool) = go(tmp_path, plan=plan)
    assert rc == 0 and rows(log, "P3WP") and rows(log, "P3CP")
    start = next(c[0] for c in tool.calls if c[1] == "write")
    end = next(c[0] for c in nx.cmd_writes if c[2] == mbx.CMD_HANDOVER)
    marks = [start] + [r.t for r in lk.trace if r.cmd == link.CMD_SRAM_W
                       and r.addr == MB + 16 and start <= r.t <= end] + [end]
    assert max(b - a for a, b in zip(marks, marks[1:])) <= 0.13


def test_stops_writes_when_state_changes(tmp_path):
    w, lk, nx, tool = sp.make()
    seen = [0]

    def hook(r):
        if r.cmd == link.CMD_SRAM_W and r.payload_hz > link.HDR_HZ and r.addr >= SCRATCH:
            seen[0] += 1
            if seen[0] == 30:
                lk.sram[MB + 13] = 3
                nx.mode, nx.due = "done", None
    w.hooks.append(hook)
    rc = sp.run_main(tmp_path, w, lk, tool)
    log = parse.parse_pilog(tmp_path / "SPI.LOG")
    assert rc != 0
    assert ("PIST", "STATE") in log.skips and ("PI3S", "STATE3") in log.skips
    k = first_state_change(lk.trace)
    after =[r for r in lk.trace[k:] if r.cmd in (link.CMD_SRAM_W, link.CMD_BRAM_W)]
    assert after == []
    assert len(lk.trace) > k + 1          # state polls and the result read follow


def first_state_change(trace):
    """Index of the first transfer whose returned bytes showed state != 1."""
    for i, r in enumerate(trace):
        if r.cmd != link.CMD_SRAM_R or not r.addr <= MB + 13 < r.addr + r.n:
            continue
        if r.data[MB + 13 - r.addr] != 1:
            return i
    return None


def test_state_change_during_stream(tmp_path):
    w, lk, nx, tool = sp.make()

    def hook(r):
        if r.actor and r.cmd == link.CMD_SRAM_W and r.payload_hz > link.HDR_HZ \
                and lk.sram[MB + 13] == 1 and len(tool.streams) == 2:
            lk.sram[MB + 13] = 4
            nx.mode, nx.due = "done", None
    w.hooks.append(hook)
    rc = sp.run_main(tmp_path, w, lk, tool)
    log = parse.parse_pilog(tmp_path / "SPI.LOG")
    assert rc != 0 and ("PIST", "STATE") in log.skips
    assert ("P3RF", "TIMEOUT") in log.skips          # the model never leaves state 4
    k = first_state_change(lk.trace)
    assert k is not None
    assert [r for r in lk.trace[k:] if r.cmd in (link.CMD_SRAM_W, link.CMD_BRAM_W)] == []
    assert all(not s.alive() for s in tool.streams)
    first_poll = next(r.t for r in lk.trace[k:] if r.cmd == link.CMD_SRAM_R
                      and r.addr == MB + 13 and r.n == 1 and not r.actor)
    assert all(s.stop_t <= first_poll for s in tool.streams)   # stopped before the END wait


def test_pattern_matches_link():
    w, lk, nx, tool = sp.make()
    r = pi303_spi.Run(lk, MB, SCRATCH, ".", sp.BUNDLE, tool, sp.MAP, w, sp.PLAN, None, None)
    for seed, n in ((7, 9000), (0, 10), (0xFFFFFFFF, 4000)):
        assert r.pattern(seed, n) == link.pattern(seed, n)


def test_effective_rate_two_lengths(full):
    rc, log, _, _ = full
    ef = {r["req_hz"]: r for r in rows(log, "P3EF")}
    r7 = ef[7_000_000]
    true = sp.CORE_HZ / 36
    assert abs(r7["eff_hz"] - true) <= true * 0.001
    naive = 4000 * 8 * 1e9 / r7["t4000"]
    assert abs(naive - true) > true * 0.01
    assert r7["eff_hz"] == pi303_spi.eff_rate(r7["t512"], r7["t4000"])
    assert ef[9_500_000]["merged"] == 1 and ef[9_000_000]["merged"] == 0
    assert 9_500_000 not in {r["req_hz"] for r in rows(log, "P3WS")}
    ws7 = [r for r in rows(log, "P3WS") if r["req_hz"] == 7_000_000]
    assert ws7 and all(r["eff_hz"] == r7["eff_hz"] for r in ws7)
    assert sorted(ef) == list(pi303_spi.LADDER)


def test_log_parses(full):
    rc, log, (w, lk, nx, tool), out = full
    assert log.tool == "pi303_spi" and log.bundle == sp.BUNDLE
    assert {"spi_max_saved", "spi_max_stale", "spi_open"} <= set(log.env)
    assert log.spi["core_clk_src"] == "none"
    want = {"P3TE", "P3EF", "P3WS", "P3WB", "P3RD", "P3CE", "P3CH", "P3WP", "P3CP", "P3HQ",
            "P3HS", "P3SV", "P3SR", "P3SC", "P3RF"}
    assert want == {r.tag for r in log.rows}
    assert all(t in tags.PI_TAGS for t in want)
    te = rows(log, "P3TE")[0]
    assert te["est_s"] == pi303_spi.estimate_s(sp.PLAN) and te["rates"] == 21
    assert log.skips == []
    assert (out / "SPI.LOG").read_bytes().count(b"\r") == 0


def test_seeds_fresh_per_call(full):
    rc, log, (w, lk, nx, tool), _ = full
    used = []
    for t, sub, a in tool.calls:
        if sub == "write":
            used.append(range(a[4], a[4] + a[5]))
        elif sub == "bram":
            used.append(range(a[3], a[3] + a[2]))
    seen = set()
    for r in used:
        assert not seen & set(r)
        seen |= set(r)


def test_tags_registered_and_disjoint():
    for t in ("P3TE P3EF P3WS P3WB P3RD P3CE P3CH P3WP P3CP P3HQ P3HS P3HO P3SV P3SR "
              "P3SC P3FR P3MB P3RF PIST PI3S").split():
        assert t in tags.PI_TAGS, t
    assert not set(tags.TAGS) & set(tags.PI_TAGS)


def test_mailbox_bump_reads_current_value():
    w, lk, nx, tool = sp.make()
    m = mbx.Mailbox(lk, MB, clock=w)
    struct.pack_into("<H", lk.sram, MB + 16, 41)
    m.bump_hb_pi()
    struct.pack_into("<H", lk.sram, MB + 16, 90)     # a C bump in between
    m.bump_hb_pi()
    assert struct.unpack_from("<H", lk.sram, MB + 16)[0] == 91


def test_read_map(tmp_path):
    p = tmp_path / "PI303.MAP"
    p.write_bytes("".join("%s=%06X\n" % kv for kv in sp.MAP.items()).encode("ascii"))
    assert pi303_spi.read_map(p) == sp.MAP
    p.write_bytes(b"mbox_phys=080000\n")
    with pytest.raises(ValueError):
        pi303_spi.read_map(p)
    p.write_bytes(b"mbox_phys=08000G\n")
    with pytest.raises(ValueError):
        pi303_spi.read_map(p)


def test_cli_lock_busy(tmp_path):
    p = tmp_path / "PI303.MAP"
    p.write_bytes("".join("%s=%06X\n" % kv for kv in sp.MAP.items()).encode("ascii"))

    class Busy:
        def open(self, clock=None):
            raise link.BusBusy("busy")

        def close(self):
            raise AssertionError("never opened")
    rc = pi303_spi.cli(["--map", str(p), "--out", str(tmp_path), "--bundle", sp.BUNDLE],
                       link_factory=Busy)
    log = parse.parse_pilog(tmp_path / "SPI.LOG")
    assert rc == 2 and log.skips == [("BUSY", "LOCK")] and log.rows == []


def test_no_mailbox_skips(tmp_path):
    w, lk, nx, tool = sp.make()
    nx.due = None
    lk.sram[MB + 13] = 2                       # stale page from an earlier run
    plan = pi303_spi.Plan(**{**sp.PLAN.__dict__, "ready_timeout_s": 1.0})
    rc = sp.run_main(tmp_path, w, lk, tool, plan=plan)
    log = parse.parse_pilog(tmp_path / "SPI.LOG")
    assert rc != 0 and ("P3MB", "NOMBOX") in log.skips
    assert not [r for r in lk.trace if r.cmd in (link.CMD_SRAM_W, link.CMD_BRAM_W)]
    assert tool.calls == []


class FakeProc:
    def __init__(self, order, out=b"C3SM base=1 bytes=2 hz=3 passes=4 ntx=5 ns=6 stop=0 state=1\n"):
        self.order = order
        me = self

        class In:
            def close(self):
                order.append("close")

        class Out:
            def read(self):
                order.append("read")
                return out
        self.stdin, self.stdout = In(), Out()
        self.rc = None
        self.me = me

    def poll(self):
        return self.rc

    def wait(self, timeout=None):
        self.order.append("wait")
        self.rc = 0
        return 0


def test_stream_stopped_by_closing_stdin():
    order = []
    s = pi303_spi.StreamProc(FakeProc(order))
    assert s.alive()
    got = s.stop()
    assert order == ["close", "wait", "read"]
    assert got == [("C3SM", {"base": 1, "bytes": 2, "hz": 3, "passes": 4, "ntx": 5, "ns": 6,
                             "stop": 0, "state": 1})]


def test_spitool_stream_argv(monkeypatch):
    seen = {}

    def popen(argv, **kw):
        seen["argv"], seen["kw"] = argv, kw
        return FakeProc([])
    monkeypatch.setattr(pi303_spi.subprocess, "Popen", popen)
    pi303_spi.SpiTool("spi303").stream("bram5:0x2000", 128, 7_000_000, "/tmp/x", MB)
    assert seen["argv"] == ["spi303", "stream", "bram5:0x2000", "128", "7000000", "/tmp/x",
                            "--hb", "0x80000"]
    assert seen["kw"]["stdin"] == subprocess.PIPE and seen["kw"]["start_new_session"]


@pytest.fixture(scope="module")
def host_tool():
    if not GCC.exists():
        pytest.skip("mingw gcc not installed")
    shell = shutil.which("pwsh") or shutil.which("powershell")
    r = subprocess.run([shell, "-NoProfile", "-File", str(HERE / "c" / "build_host.ps1")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return pi303_spi.SpiTool(str(HOST / "spi303.exe"), extra=["--sim"])


def test_spitool_drives_c_sim(host_tool):
    st = host_tool.selftest(0x1000)
    assert st[0] == ("C3ST", {"ok": 1, "base": 0x1000, "mis": 0, "first": -1})
    w = host_tool.write(SCRATCH, 8000, 7_000_000, 4000, 21, passes=2)
    wp = [kv for t, kv in w if t == "C3WP"]
    assert [p["seed"] for p in wp] == [21, 22] and all(p["mis"] == 0 for p in wp)
    assert ("C3EN", {"passes": 2, "stop": 0, "state": -1}) in w
    r = host_tool.read(SCRATCH, 8000, 7_000_000, 4000, 5, passes=1)
    assert [t for t, _ in r if t == "C3RP"] == ["C3RP"]
    b = host_tool.bram(7, 7_000_000, 2, 30)
    assert [kv["seed"] for t, kv in b if t == "C3BP"] == [30, 31]
    with pytest.raises(pi303_spi.ToolError) as e:
        host_tool.write(0x1FFFFF, 8000, 7_000_000, 4000, 1, passes=1)
    assert e.value.rows and e.value.rows[0][0] == "C3ER"
