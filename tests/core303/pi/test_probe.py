import errno
import sys
import types

import pytest

import link
import parse
import pi303_probe
import pi303_smoke
import sim

BUNDLE = "0123456789ab"
PROBES = {"gcc": 1, "numpy": 0, "pil": 1, "jpeghdr": 0, "lock": 1, "bufsiz": 4096, "clk": 0}


def fake_env():
    return dict(probes=lambda: dict(PROBES), core_clk=lambda: (0, "none"), spi_open=lambda: [])


def run_probe(tmp_path, s=None, **kw):
    s = s or sim.SimLink()
    rc = pi303_probe.main(s, str(tmp_path), BUNDLE, **{**fake_env(), **kw})
    return rc, parse.parse_pilog(tmp_path / "PROBE.LOG"), s


def row(log, tag):
    return next(r for r in log.rows if r.tag == tag)


def test_probe_pass(tmp_path):
    rc, log, _ = run_probe(tmp_path)
    assert rc == 0
    assert log.tool == "pi303_probe" and log.bundle == BUNDLE
    assert row(log, "P0VR").fields == {"ver": sim.SimLink.VERSION, "caps": 0xFF}
    assert set(row(log, "P0NR").fields) == {"nr01", "nr0e", "nr0f"}
    assert row(log, "P0RW").fields == {"ok": 1}
    assert row(log, "P0IM").fields == {"gcc": 1, "numpy": 0, "pil": 1, "jpeghdr": 0,
                                   "lock": 1, "bufsiz": 4096, "clk": 0}
    assert log.skips == []
    assert log.spi["caps"] == "FF" or int(log.spi["caps"], 16) == 0xFF
    assert log.spi["core_clk_src"] == "none"
    assert {"spi_max_saved", "spi_max_stale", "spi_open"} <= set(log.env)


def test_probe_caps_missing(tmp_path):
    for bit in (1, 2, 3, 5):
        class S(sim.SimLink):
            CAPS = 0xFF & ~(1 << bit)
        rc, log, _ = run_probe(tmp_path, S())
        assert rc != 0
        assert ("P3P4", "CAPS") in [tuple(x) for x in log.skips]
        assert row(log, "P0VR").fields["caps"] == S.CAPS


def test_probe_nr7f_restored(tmp_path):
    s = sim.SimLink()
    s.nrs[0x7F] = 0x33
    rc, log, _ = run_probe(tmp_path, s)
    assert rc == 0 and row(log, "P0RW").fields["ok"] == 1
    assert s.nrs[0x7F] == 0x33
    writes = [t for t in s.log if t.cmd == link.CMD_NR_W and t.addr == 0x7F]
    assert len(writes) == 2


def test_probe_nr7f_stuck_fails(tmp_path):
    class Stuck(sim.SimLink):
        def _nr(self, header, header_hz, hz):
            if header[0] == link.CMD_NR_W:
                self._need(header, 4, "NR_W")
                return b""
            return super()._nr(header, header_hz, hz)
    rc, log, _ = run_probe(tmp_path, Stuck())
    assert rc != 0 and row(log, "P0RW").fields["ok"] == 0


def test_probe_lock_busy(tmp_path):
    class Never(link.LockProvider):
        def try_lock(self):
            return False

        def release(self):
            pass

    class Clock:
        t = 0.0

        def time(self):
            return self.t

        def sleep(self, s):
            self.t += s

    lk = link.SpidevLink(lock=Never())
    rc = pi303_probe.cli(lambda: lk, ["--out", str(tmp_path), "--bundle", BUNDLE],
                         clock=Clock())
    assert rc != 0
    log = parse.parse_pilog(tmp_path / "PROBE.LOG")
    assert log.skips == [("BUSY", "LOCK")] and log.rows == []


class FakeSpi:
    max_speed_hz = 2_000_000
    mode = 0

    def fileno(self):
        return 3


def fake_fcntl(monkeypatch, fn):
    monkeypatch.setitem(sys.modules, "fcntl", types.SimpleNamespace(ioctl=fn))


def smoke_link():
    lk = link.SpidevLink(py_ioctl=True)
    lk._spi = FakeSpi()
    return lk


def real_like(total, calls=None, ret=None):
    """Like fcntl.ioctl: bytes in gives bytes back; a mutable buffer with mutate gives the int."""
    def f(fd, req, msg, mutate=False):
        if calls is not None:
            calls.append((req, len(msg)))
        if isinstance(msg, bytes) or not mutate:
            return bytes(msg)
        return total if ret is None else ret
    return f


def test_smoke_logs_row(tmp_path, monkeypatch):
    calls = []
    fake_fcntl(monkeypatch, real_like(7 + 64, calls))
    rc = pi303_smoke.main(smoke_link(), str(tmp_path), BUNDLE, **fake_env())
    assert rc == 0
    assert calls == [(link.spi_ioc_message(2), 64)]
    r = parse.parse_pilog(tmp_path / "SMOKE.LOG").rows
    assert [(x.tag, x.fields) for x in r] == [("P2PY", {"ok": 1, "ret": 0})]


def test_smoke_einval(tmp_path, monkeypatch):
    def bad(fd, req, msg, mutate=False):
        raise OSError(errno.EINVAL, "invalid")

    fake_fcntl(monkeypatch, bad)
    rc = pi303_smoke.main(smoke_link(), str(tmp_path), BUNDLE, **fake_env())
    assert rc != 0
    r = parse.parse_pilog(tmp_path / "SMOKE.LOG").rows
    assert r[0].fields == {"ok": 0, "ret": -errno.EINVAL}


def test_smoke_short_return(tmp_path, monkeypatch):
    fake_fcntl(monkeypatch, real_like(71, ret=5))
    rc = pi303_smoke.main(smoke_link(), str(tmp_path), BUNDLE, **fake_env())
    assert rc != 0
    log = parse.parse_pilog(tmp_path / "SMOKE.LOG")
    assert log.rows[0].fields == {"ok": 0, "ret": 5} and log.skips == []


def test_smoke_link_error_logged(tmp_path, monkeypatch):
    lk = smoke_link()
    lk.xfer = lambda *a, **k: (_ for _ in ()).throw(link.LinkError("no helper"))
    fake_fcntl(monkeypatch, real_like(71))
    rc = pi303_smoke.main(lk, str(tmp_path), BUNDLE, **fake_env())
    assert rc != 0
    log = parse.parse_pilog(tmp_path / "SMOKE.LOG")
    assert log.rows[0].fields == {"ok": 0, "ret": -1}
    assert log.skips == [("P2PY", "LINK")] and log.spi == {}


def test_link_split_checks_count(monkeypatch):
    fake_fcntl(monkeypatch, real_like(71, ret=70))
    h = link.build_header(link.CMD_SRAM_R, 0, 64)
    with pytest.raises(link.LinkError):
        smoke_link().xfer(h, b"", 64, 4_000_000)
    fake_fcntl(monkeypatch, real_like(len(h) + 64))
    assert smoke_link().xfer(h, b"", 64, 4_000_000) == bytes(64)


def test_probe_nr7f_restored_on_readback_error(tmp_path):
    class Boom(sim.SimLink):
        def _nr(self, header, header_hz, hz):
            if header[0] == link.CMD_NR_R and header[1] == 0x7F and self.nrs.get(0x7F) == 0x5A:
                raise link.LinkError("read-back failed")
            return super()._nr(header, header_hz, hz)
    s = Boom()
    s.nrs[0x7F] = 0x33
    rc, log, _ = run_probe(tmp_path, s)
    assert rc != 0 and s.nrs[0x7F] == 0x33
    assert ("P0RW", "LINK") in [tuple(x) for x in log.skips]


def test_probe_version_failure_leaves_log(tmp_path):
    class Dead(sim.SimLink):
        def version(self):
            raise link.LinkError("dead")
    rc, log, _ = run_probe(tmp_path, Dead())
    assert rc != 0 and log.rows == [] and ("P0VR", "LINK") in [tuple(x) for x in log.skips]


def test_tools_in_bundle():
    from pathlib import Path
    names = (Path(pi303_probe.__file__).parent / "BUNDLE.txt").read_text().split()
    assert "pi303_probe.py" in names and "pi303_smoke.py" in names
