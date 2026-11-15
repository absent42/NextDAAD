"""P2 frames generator and preparation bench (host: numpy/PIL path plus the mingw C tool)."""
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

import frames
import parse
import pi303_prep

HERE = Path(__file__).parent
CDIR = HERE / "c"
ROOT = HERE.parent.parent.parent
EXE = ROOT / "build" / "core303" / "host" / "prep303.exe"
GCC = Path(r"C:\ProgramData\mingw64\mingw64\bin\gcc.exe")
BUNDLE = "0123456789ab"
HIST = ("b1", "b2", "b4", "b8", "b16", "b64", "b256")


@pytest.fixture(scope="module")
def host_exe():
    if not GCC.exists():
        pytest.skip("mingw gcc not installed")
    shell = shutil.which("pwsh") or shutil.which("powershell")
    r = subprocess.run([shell, "-NoProfile", "-File", str(CDIR / "build_host.ps1")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "warning" not in (r.stdout + r.stderr).lower(), r.stdout + r.stderr
    return EXE


def rows_of(log, tag):
    return [r.fields for r in log.rows if r.tag == tag]


def test_frames_deterministic(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    frames.make(a, n=3)
    frames.make(b, n=3)
    names = sorted(p.name for p in a.iterdir())
    assert names == ["F000.jpg", "F000.png", "F000.raw", "F001.jpg", "F001.png", "F001.raw",
                     "F002.jpg", "F002.png", "F002.raw", "SOURCE.txt"]
    assert names == sorted(p.name for p in b.iterdir())
    for n in names:
        assert (a / n).read_bytes() == (b / n).read_bytes(), n
    assert all((a / ("F00%d.raw" % i)).stat().st_size == 49152 for i in range(3))
    assert (a / "SOURCE.txt").read_text().startswith("synthetic seed=")


def test_numpy_conversion_matches_formula():
    rgb = np.random.default_rng(1).integers(0, 256, (192, 256, 3), dtype=np.uint8)
    out = frames.to_rrrgggbb(rgb)
    r, g, b = (rgb[..., i].astype(int) for i in range(3))
    assert out.tobytes() == bytes(((r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6)).astype(np.uint8)
                                  .ravel())


def test_c_conversion_matches_numpy(host_exe, tmp_path):
    rgb = np.random.default_rng(2).integers(0, 256, (192, 256, 3), dtype=np.uint8)
    (tmp_path / "in.rgb").write_bytes(rgb.tobytes())
    r = subprocess.run([str(host_exe), "--cv", str(tmp_path / "in.rgb"),
                        str(tmp_path / "out.raw")], capture_output=True)
    assert r.returncode == 0, r.stderr
    assert (tmp_path / "out.raw").read_bytes() == frames.to_rrrgggbb(rgb).tobytes()


def run_prep(host_exe, tmp_path, n=3):
    fdir, out = tmp_path / "frames", tmp_path / "out"
    out.mkdir()
    frames.make(fdir, n=n)
    rc = pi303_prep.main(str(fdir), str(out), BUNDLE, c_prep=str(host_exe))
    return rc, parse.parse_pilog(out / "PREP.LOG")


def test_prep_rows_on_sample(host_exe, tmp_path):
    rc, log = run_prep(host_exe, tmp_path)
    assert rc == 0
    assert log.tool == "pi303_prep" and log.bundle == BUNDLE
    jd = rows_of(log, "P2JD")
    assert [f["impl"] for f in jd] == [0] and jd[0]["frames"] == 3 and jd[0]["ns"] > 0
    cv = rows_of(log, "P2CV")
    assert [f["impl"] for f in cv] == [0, 1] and all(f["frames"] == 3 for f in cv)
    sp = rows_of(log, "P2SP")
    assert [f["impl"] for f in sp] == [0, 1]
    assert all(f["frames"] == 2 and f["spans"] > 0 for f in sp)
    assert sp[0]["spans"] == sp[1]["spans"]
    rd = rows_of(log, "P2RD")
    assert len(rd) == 1 and rd[0]["frames"] == 3 and rd[0]["ns"] > 0
    sh = rows_of(log, "P2SH")
    assert len(sh) == 1 and tuple(sh[0]) == HIST
    assert sum(sh[0].values()) == sp[0]["spans"]


def test_prep_no_jpeg_header_skips(host_exe, tmp_path):
    rc, log = run_prep(host_exe, tmp_path)      # mingw has no jpeglib.h
    assert ("P2JD", "NOHDR") in [tuple(s) for s in log.skips]
    assert [f["impl"] for f in rows_of(log, "P2JD")] == [0]
    assert rc == 0


def test_jpeg_file_read_outside_timer(tmp_path, monkeypatch):
    fdir, out = tmp_path / "frames", tmp_path / "out"
    out.mkdir()
    frames.make(fdir, n=3)
    events = []
    real = pi303_prep._read
    monkeypatch.setattr(pi303_prep, "_read", lambda p: (events.append("read"), real(p))[1])

    def clock():
        events.append("clk")
        return len(events)
    pi303_prep.main(str(fdir), str(out), BUNDLE, c_prep="", clock=clock)
    assert events[:9] == ["read", "clk", "clk"] * 3


def test_prep_failed_c_tool_logs_cfail(tmp_path):
    fdir, out = tmp_path / "frames", tmp_path / "out"
    out.mkdir()
    frames.make(fdir, n=2)
    pi303_prep.main(str(fdir), str(out), BUNDLE, c_prep=str(tmp_path / "missing.exe"))
    log = parse.parse_pilog(out / "PREP.LOG")
    assert ("P2JD", "CFAIL") in [tuple(s) for s in log.skips]
    assert ("P2CV", "CFAIL") in [tuple(s) for s in log.skips]


def test_build_c_link_fallback_marks_nolink(tmp_path, monkeypatch):
    """jpeglib.h present but -ljpeg fails: the NO_JPEG retry carries JPEG_NOLINK."""
    hdr = tmp_path / "jpeglib.h"
    hdr.write_text("")
    cmds = []

    class R:
        def __init__(self, rc):
            self.returncode = rc
    monkeypatch.setattr(pi303_prep, "JPEGLIB", str(hdr))
    monkeypatch.setattr(pi303_prep.shutil, "which", lambda n: "gcc")
    monkeypatch.setattr(pi303_prep.subprocess, "run",
                        lambda cmd, **kw: (cmds.append(cmd), R(1 if "-ljpeg" in cmd else 0))[1])
    assert pi303_prep.build_c(str(tmp_path))
    assert "-ljpeg" in cmds[0] and {"-DNO_JPEG", "-DJPEG_NOLINK"} <= set(cmds[1])
    cmds.clear()
    hdr.unlink()
    assert pi303_prep.build_c(str(tmp_path))
    assert len(cmds) == 1 and "-DNO_JPEG" in cmds[0] and "-DJPEG_NOLINK" not in cmds[0]


def test_prep_without_c_tool(tmp_path):
    fdir, out = tmp_path / "frames", tmp_path / "out"
    out.mkdir()
    frames.make(fdir, n=2)
    rc = pi303_prep.main(str(fdir), str(out), BUNDLE, c_prep="")
    log = parse.parse_pilog(out / "PREP.LOG")
    assert rc == 0
    assert ("P2CV", "NOCC") in [tuple(s) for s in log.skips]
    assert [f["impl"] for f in rows_of(log, "P2CV")] == [0]
