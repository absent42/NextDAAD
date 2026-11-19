import errno
import sys
import types

import pytest

import bundle
import link
import parse
import pi303_probe
import pi303_smoke
import sim

BUNDLE = "0123456789ab"
REAL = bundle.bundle_hash(pi303_probe.HERE)
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
    rc = pi303_probe.cli(lambda: lk, ["--out", str(tmp_path), "--bundle", REAL],
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


def test_bundle_mismatch_skips_before_spi(tmp_path):
    """A --bundle other than the files' own hash: #SKIP <tag> BUNDLE, rc 1, link never made."""
    import pi303_prep
    import pi303_spi
    import pi303_video

    def never():
        raise AssertionError("no link before the bundle check")
    cases = [(lambda o: pi303_probe.cli(never, ["--out", o, "--bundle", BUNDLE]),
              "PROBE.LOG", "P0VR"),
             (lambda o: pi303_smoke.cli(never, ["--out", o, "--bundle", BUNDLE]),
              "SMOKE.LOG", "P2PY"),
             (lambda o: pi303_spi.cli(["--map", "none", "--out", o, "--bundle", BUNDLE],
                                      link_factory=never), "SPI.LOG", "P3FR"),
             (lambda o: pi303_video.cli(["--map", "none", "--spi-log", "x", "--frames", "y",
                                         "--out", o, "--bundle", BUNDLE], link_factory=never),
              "VIDEO.LOG", "P4MB"),
             (lambda o: pi303_prep.cli(["--frames", "none", "--out", o, "--bundle", BUNDLE]),
              "PREP.LOG", "P2JD")]
    for i, (fn, name, tag) in enumerate(cases):
        out = tmp_path / str(i)
        out.mkdir()
        assert fn(str(out)) == 1, name
        log = parse.parse_pilog(out / name)
        assert log.bundle == REAL and log.skips == [(tag, "BUNDLE")] and log.rows == [], name


def test_bundle_given_and_matching_runs(tmp_path):
    seen = []

    class L(sim.SimLink):
        def open(self, clock=None):
            seen.append("open")

        def close(self):
            pass
    rc = pi303_probe.cli(L, ["--out", str(tmp_path), "--bundle", REAL], **fake_env())
    assert seen == ["open"] and rc == 0
    assert parse.parse_pilog(tmp_path / "PROBE.LOG").bundle == REAL


def test_spidev_restore_logged_before_end(tmp_path):
    order = []

    class Restoring(sim.SimLink):
        spi_max_restored = None

        def restore(self):
            order.append("restore")
            self.spi_max_restored = 2_000_000
    rc, log, _ = run_probe(tmp_path, Restoring())
    assert rc == 0 and order == ["restore"] and log.spi["spi_max_restored"] == "2000000"
    lines = (tmp_path / "PROBE.LOG").read_text().splitlines()
    assert lines[-2:] == ["#SPI spi_max_restored=2000000", "#END %04X" % len(log.rows)]
    rc, log, _ = run_probe(tmp_path, sim.SimLink())        # no spidev: no line
    assert "spi_max_restored" not in log.spi


PIENV_KEYS = {"model", "governor", "arm_khz", "kernel", "py", "numpy", "pil", "gcc", "bufsiz"}


def test_pienv_reads_and_tokens(tmp_path, monkeypatch):
    cpu = tmp_path / "cpufreq"
    cpu.mkdir()
    (tmp_path / "model").write_bytes(b"Raspberry Pi Zero Rev 1.3\0")
    (cpu / "scaling_governor").write_text("ondemand\n")
    (cpu / "scaling_cur_freq").write_text("700000\n")
    (tmp_path / "bufsiz").write_text("4096\n")
    monkeypatch.setattr(pi303_probe, "MODEL", str(tmp_path / "model"))
    monkeypatch.setattr(pi303_probe, "CPUFREQ", str(cpu))
    monkeypatch.setattr(pi303_probe, "BUFSIZ", str(tmp_path / "bufsiz"))
    monkeypatch.setattr(pi303_probe, "_gcc_version", lambda: "12.2.1")
    e = pi303_probe.pienv()
    assert set(e) == PIENV_KEYS
    assert e["model"] == "Raspberry_Pi_Zero_Rev_1.3" and e["governor"] == "ondemand"
    assert e["arm_khz"] == 700000 and e["bufsiz"] == 4096 and e["gcc"] == "12.2.1"
    assert e["py"] == pi303_probe.platform.python_version()
    # every read fails safe: missing files give na
    for k in ("MODEL", "CPUFREQ", "BUFSIZ"):
        monkeypatch.setattr(pi303_probe, k, str(tmp_path / "missing"))
    e = pi303_probe.pienv()
    assert (e["model"], e["governor"], e["arm_khz"], e["bufsiz"]) == ("na",) * 4
    p = tmp_path / "E.LOG"
    w = pi303_probe.PiLogWriter(str(p), "t", BUNDLE)
    w.env(**e)
    w.close()
    env = parse.parse_pilog(p).env
    assert set(env) == PIENV_KEYS and all(v and " " not in v for v in env.values())


def test_pienv_version_from_importable_package(tmp_path, monkeypatch):
    import importlib
    from importlib import metadata
    pkg = tmp_path / "PIL"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("raise RuntimeError('imported')\n")
    (pkg / "_version.py").write_text('__version__ = "11.3.0"\n')
    monkeypatch.delitem(sys.modules, "PIL", raising=False)
    monkeypatch.syspath_prepend(str(tmp_path))
    importlib.invalidate_caches()
    stale = lambda dist: "12.1.1" if dist == "Pillow" else "9.9.9"
    monkeypatch.setattr(metadata, "version", stale)
    assert pi303_probe.pienv()["pil"] == "11.3.0"
    assert "PIL" not in sys.modules
    (pkg / "_version.py").unlink()                    # unreadable: metadata fallback
    assert pi303_probe.pienv()["pil"] == "12.1.1"


def test_gcc_version_absent(monkeypatch):
    def boom(*a, **k):
        raise FileNotFoundError("gcc")
    monkeypatch.setattr(pi303_probe.subprocess, "run", boom)
    assert pi303_probe._gcc_version() == "none"


def test_open_log_writes_pienv(tmp_path):
    rc, log, _ = run_probe(tmp_path)
    assert PIENV_KEYS | {"spi_max_saved", "spi_max_stale", "spi_open"} <= set(log.env)


def test_pienv_imports_no_pil():
    import subprocess
    code = ("import sys; sys.path.insert(0, %r); import pi303_probe; pi303_probe.pienv(); "
            "print(int('PIL' in sys.modules))" % str(pi303_probe.HERE))
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert out.stdout.strip() == "0", out.stderr


def test_tools_in_bundle():
    from pathlib import Path
    names = (Path(pi303_probe.__file__).parent / "BUNDLE.txt").read_text().split()
    assert "pi303_probe.py" in names and "pi303_smoke.py" in names
