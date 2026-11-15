"""Host build and tests of the Pi C core (mingw gcc), plus Python/C contract checks."""
import re
import shutil
import struct
import subprocess
from pathlib import Path

import pytest

import link
import parse
import tags

HERE = Path(__file__).parent
CDIR = HERE / "pi" / "c"
ROOT = HERE.parent.parent
OUT = ROOT / "build" / "core303" / "host"
GCC = Path(r"C:\ProgramData\mingw64\mingw64\bin\gcc.exe")
FAST = 8_000_000


@pytest.fixture(scope="module")
def host():
    if not GCC.exists():
        pytest.skip("mingw gcc not installed")
    shell = shutil.which("pwsh") or shutil.which("powershell")
    r = subprocess.run([shell, "-NoProfile", "-File", str(CDIR / "build_host.ps1")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "warning" not in (r.stdout + r.stderr).lower(), r.stdout + r.stderr
    return OUT


def run(exe, *args, stdin=None):
    return subprocess.run([str(exe)] + [str(a) for a in args], capture_output=True,
                          input=stdin, cwd=str(OUT))


def pilog_rows(tmp_path, text):
    rows = [ln for ln in text.splitlines() if ln]
    p = tmp_path / "S.LOG"
    p.write_bytes(("#PI303 spi303 0123456789ab\n" + "".join(r + "\n" for r in rows)
                   + "#END %04X\n" % len(rows)).encode("ascii"))
    return parse.parse_pilog(p).rows


def test_c_unit_tests(host):
    r = run(host / "test_core303pi.exe")
    out = r.stdout.decode()
    assert r.returncode == 0, out
    assert "ALL PASS" in out


def test_pattern_matches_python(host):
    for seed, n in ((7, 4096), (0, 64), (0xFFFFFFFF, 300)):
        r = run(host / "test_core303pi.exe", "--dump", seed, n)
        assert r.returncode == 0
        assert r.stdout.decode().strip() == link.pattern(seed, n).hex()


def test_headers_match_python(host):
    cases = []
    for cmd in (link.CMD_SRAM_R, link.CMD_SRAM_W):
        for addr, n in ((0, 1), (0x1F2345, 0x0102), (0x1FFFFF, 4000), (0x040000, 0xFFFF)):
            cases.append((cmd, addr, n, link.build_header(cmd, addr, n)))
    for cmd in (link.CMD_BRAM_R, link.CMD_BRAM_W):
        for addr, n in ((0x0010, 3), (0x8010, 3), (0x9FFF, 1), (0x3FFF, 4000)):
            cases.append((cmd, addr, n, link.build_header(cmd, addr, n)))
    for reg in (0x00, 0x1E, 0x7F, 0xFF):
        cases.append((link.CMD_NR_R, reg, 1, link.build_header(link.CMD_NR_R, reg, 1)))
        for val in (0x00, 0x55):        # C build_cmd carries the NR_W value in len
            cases.append((link.CMD_NR_W, reg, val,
                          link.build_header(link.CMD_NR_W, reg, 1, val=val)))
    cases.append((link.CMD_VERSION, 0, 2, link.build_header(link.CMD_VERSION, 0, 2)))
    args = [x for c in cases for x in c[:3]]
    r = run(host / "test_core303pi.exe", "--hdr", *args)
    assert r.returncode == 0
    got = r.stdout.decode().split()
    assert got == [c[3].hex() for c in cases]


def test_spi303_sim_rows_parse(host, tmp_path):
    exe = host / "spi303.exe"
    r = run(exe, "--sim", "--sim-loss", "1:100", "write", "0x1000", "9000", FAST, "4000", "5",
            "--passes", "2")
    assert r.returncode == 0, r.stdout + r.stderr
    rows = pilog_rows(tmp_path, r.stdout.decode("ascii"))
    wp = [x.fields for x in rows if x.tag == "C3WP"]
    assert [f["seed"] for f in wp] == [5, 6]
    assert (wp[0]["bad_tx"], wp[0]["first_tx"], wp[0]["first"], wp[0]["shift"]) == (1, 1, 100, 1)
    assert wp[1]["mis"] == 0 and wp[1]["first_tx"] == -1
    assert rows[-1].tag == "C3EN" and rows[-1].fields["passes"] == 2

    r = run(exe, "--sim", "bram", "7", FAST, "3", "11")
    assert r.returncode == 0
    rows = pilog_rows(tmp_path, r.stdout.decode("ascii"))
    assert [x.fields["base"] for x in rows if x.tag == "C3BP"] == [0x8000] * 3
    assert all(x.fields["bytes"] == 8192 and x.fields["mis"] == 0
               for x in rows if x.tag == "C3BP")

    r = run(exe, "--sim", "read", "0x1000", "8000", FAST, "4000")
    assert r.returncode == 0
    rows = pilog_rows(tmp_path, r.stdout.decode("ascii"))
    assert rows[0].tag == "C3RP" and rows[0].fields["ref"] == 0

    r = run(exe, "--sim", "selftest", "0x30000")
    assert r.returncode == 0
    assert pilog_rows(tmp_path, r.stdout.decode("ascii"))[0].fields["ok"] == 1
    r = run(exe, "--sim", "--sim-loss", "0:3", "selftest", "0x30000")
    assert r.returncode == 1


def test_spi303_bounds_rejected(host, tmp_path):
    exe = host / "spi303.exe"
    for args in (("write", "0x1FFFFF", "2", FAST, "4000", "1"),
                 ("read", "0x200000", "1", FAST, "4000"),
                 ("bram", "6", FAST, "1", "1"),
                 ("bram", "5", FAST, "1", "1", "--hb", "0x1FFFF0"),
                 ("write", "0x1000", "100", FAST, "4001", "1"),
                 ("write", "0x1000", "100", "0", "100", "1"),
                 ("write", "0x1000", "100", FAST, "100", "1", "--seed", "3"),
                 ("bram", "7", FAST, "1", "1", "--passes", "2"),
                 ("selftest", "0x1FFF80")):
        r = run(exe, "--sim", *args)
        assert r.returncode not in (0, 1), args
        rows = pilog_rows(tmp_path, r.stdout.decode("ascii"))
        assert [x.tag for x in rows] == ["C3ER"], args


def test_serve_sim_matches_servehelper(host):
    h = link.ServeHelper.spawn([str(host / "spi303.exe"), "--sim", "serve"])
    try:
        data = link.pattern(4, 9000)
        h.write(link.CMD_SRAM_W, 0x4000, data[:3000], FAST)
        assert h.read(link.CMD_SRAM_R, 0x4000, 3000, FAST) == data[:3000]
        h.write(link.CMD_BRAM_W, 0x8000 | 0x100, b"wxyz", FAST)
        assert h.read(link.CMD_BRAM_R, 0x8000 | 0x100, 4, FAST) == b"wxyz"
        ntx, bad, ns = h.push(link.CMD_SRAM_W, 0x10000, data, FAST, verify=True)
        assert (ntx, bad) == (3, 0) and ns >= 0
        assert h.read(link.CMD_SRAM_R, 0x10000 + 4000, 4000, FAST) == data[4000:8000]
        spans = [(0x10, data[:5]), (0x2000, data[5:4505])]
        assert h.pushspans(link.CMD_SRAM_W, 0x20000, spans, FAST)[:2] == (3, 0)
        assert h.read(link.CMD_SRAM_R, 0x22000, 4000, FAST) == data[5:4005]
        with pytest.raises(link.LinkError):
            h.write(link.CMD_SRAM_W, 0x1FFFFF, b"xy", FAST)
        with pytest.raises(link.LinkError):
            h.push(link.CMD_SRAM_W, 0x1FC000, data * 2, FAST)
        assert h.read(link.CMD_SRAM_R, 0x10, 2, FAST) == b"\0\0"   # still in step
    finally:
        h.close()
    assert h.proc.returncode == 0


def test_spi303_never_locks():
    src = (CDIR / "spi303.c").read_text() + (CDIR / "core303pi.c").read_text()
    for word in ("flock", "lockf", "F_SETLK"):
        assert word not in src
    assert not re.search(r'"[^"\n]*nextspi\.lock', src)


def test_tags_registered():
    src = "".join((CDIR / f).read_text() for f in ("spi303.c", "core303pi.c"))
    emitted = set(re.findall(r'"((?:C3|P2)[A-Z0-9]{2})[ "]', src))
    assert {"C3WP", "C3BP", "C3RP", "C3TX", "C3EN", "C3HB", "C3SM", "C3ST", "C3ER",
            "P2SM"} <= emitted
    assert emitted <= set(tags.PI_TAGS)


def test_bundle_lists_c_sources():
    listed = (HERE / "pi" / "BUNDLE.txt").read_text().split()
    for f in ("c/core303pi.h", "c/core303pi.c", "c/spi303.c"):
        assert f in listed
    assert not [f for f in listed if "test" in f or f.endswith(".ps1")]


def test_spidev_struct_offsets_pinned():
    src = (CDIR / "spi303.c").read_text()
    for frag in ("sizeof(struct spi_ioc_transfer) == 32",
                 "offsetof(struct spi_ioc_transfer, len) == 16",
                 "offsetof(struct spi_ioc_transfer, speed_hz) == 20"):
        assert frag in src
    assert len(link.pack_spi_transfer(0, 0, 0, 0)) == 32
    assert struct.unpack_from("<I", link.pack_spi_transfer(0, 0, 7, 9), 20)[0] == 9
