import json

from vidtune.encoderun import (parse_progress_line, read_report,
                               resolve_encoder, summarize_report)


def test_resolve_prefers_big_exe(tmp_path):
    exe = tmp_path / "tools" / "videnc" / "videnc.exe"
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"\0" * (2 * 1024 * 1024))
    got = resolve_encoder(tmp_path, "tools")
    assert got == [str(exe)]


def test_resolve_skips_lfs_pointer(tmp_path):
    exe = tmp_path / "tools" / "videnc" / "videnc.exe"
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"version https://git-lfs...")     # tiny pointer file
    got = resolve_encoder(tmp_path, "tools")
    # falls through to a Python candidate (present on the dev box) or None
    assert got is None or got[-1].endswith("videnc.py")


def test_parse_auto_budget_line():
    d = parse_progress_line(
        "  auto-budget: --stream-budget 0.72 -> util 0.90 (target 0.90)"
        " - 3 probes, 41.2 s")
    assert d == {"kind": "auto-budget", "budget": 0.72, "util": 0.90}


def test_parse_delta_stats_line():
    d = parse_progress_line(
        "  delta stats: budget-bound 42.4% (106/250 frames), peak 12-frame"
        " window 100% @f88, delta-frame PSNR p10 23.37 dB")
    assert d["kind"] == "delta-stats"
    assert d["bound_pct"] == 42.4
    assert d["peak_frame"] == 88


def test_parse_unknown_line_is_none():
    assert parse_progress_line("encoding frame 12") is None


def test_read_report_missing(tmp_path):
    assert read_report(tmp_path / "nope.json") == {}


def test_summarize_report_tolerant(tmp_path):
    p = tmp_path / "r.json"
    p.write_text(json.dumps({"stream_budget": 0.72, "bound_fraction": 0.42, "mean_psnr": 26.7, "total_bytes": 1047552}))
    s = summarize_report(read_report(p))
    assert s.stream_budget == 0.72
    assert s.bound_fraction == 0.42
    assert s.psnr_mean == 26.7
    assert s.wire_bytes == 1047552
    assert s.auto_budget is None            # absent key -> None, no KeyError


def test_parse_auto_budget_malformed_numbers_does_not_raise():
    # Bare dot should not match due to strict regex
    d = parse_progress_line("  auto-budget: --stream-budget . -> util 0.90")
    assert d is None


def test_parse_delta_stats_malformed_numbers_does_not_raise():
    # Malformed bound percentage should not match
    d = parse_progress_line("  delta stats: budget-bound .% (106/250 frames), peak 12-frame window 100% @f88")
    assert d is None


def test_parse_tolerant_never_raises_on_edge_cases():
    # Ensure function never raises ValueError on malformed numeric input
    test_inputs = [
        "auto-budget: --stream-budget . -> util 0.90",
        "auto-budget: --stream-budget .. -> util ..",
        "delta stats: budget-bound .% peak @f.",
        "delta stats: budget-bound 100% peak @fabc",
        "",
    ]
    for inp in test_inputs:
        # Should never raise, should return None for unparseable
        result = parse_progress_line(inp)
        assert result is None or isinstance(result, dict)


import sys
import textwrap

from vidtune.encoderun import EncodeJob


def _fake_encoder(tmp_path, exit_code=0):
    """A stand-in 'videnc': prints one status line, writes its output and
    report args, exits with the given code."""
    script = tmp_path / "fake_videnc.py"
    script.write_text(textwrap.dedent(f"""
        import json, sys
        argv = sys.argv[1:]
        out = argv[1]
        rep = argv[argv.index("--report") + 1]
        print("  auto-budget: --stream-budget 0.72 -> util 0.90 (target 0.90) - 1 probes, 0.1 s")
        if {exit_code} == 0:
            open(out, "wb").write(b"VID")
            json.dump({{"stream_budget": 0.72}}, open(rep, "w"))
        sys.exit({exit_code})
    """))
    return [sys.executable, str(script)]


def test_encode_job_success(tmp_path, qtbot):
    out = tmp_path / "001.vid"
    out.write_bytes(b"OLD")
    job = EncodeJob(_fake_encoder(tmp_path), ffmpeg="ffmpeg-unused")
    events = []
    job.progress.connect(events.append)
    with qtbot.waitSignal(job.finished, timeout=15000) as blocker:
        job.start(tmp_path / "in.mp4", out, ["--shape", "classic"])
    code, report = blocker.args
    assert code == 0
    assert report["stream_budget"] == 0.72
    assert out.read_bytes() == b"VID"                  # moved into place
    assert not out.with_suffix(".vid.tmp").exists()
    assert {"kind": "auto-budget", "budget": 0.72, "util": 0.90} in events


def test_encode_job_failure_keeps_previous(tmp_path, qtbot):
    out = tmp_path / "001.vid"
    out.write_bytes(b"OLD")
    job = EncodeJob(_fake_encoder(tmp_path, exit_code=3), ffmpeg="x")
    with qtbot.waitSignal(job.finished, timeout=15000) as blocker:
        job.start(tmp_path / "in.mp4", out, [])
    code, report = blocker.args
    assert code == 3
    assert report == {}
    assert out.read_bytes() == b"OLD"                  # untouched
    assert not out.with_suffix(".vid.tmp").exists()


def test_encode_job_partial_line_buffering(qtbot):
    """Partial lines split across chunks must be buffered and emitted complete."""
    import pytest
    job = EncodeJob(["python"], ffmpeg="x")
    lines = []
    job.line.connect(lines.append)

    class MockProc:
        def __init__(self):
            self.data = b""
        def readAllStandardOutput(self):
            return self.data

    job._proc = MockProc()
    job._proc.data = b"  auto-budget: --stream"
    job._on_output()
    assert lines == []
    job._proc.data = b"-budget 0.72 -> util 0.90 (target 0.90) - 1 probes, 0.1 s\n"
    job._on_output()
    assert len(lines) == 1
    assert "auto-budget" in lines[0]


def test_encode_job_double_start_raises(tmp_path, qtbot):
    """Calling start() while a process is running must raise RuntimeError."""
    import pytest
    job = EncodeJob(_fake_encoder(tmp_path), ffmpeg="x")
    job.start(tmp_path / "in.mp4", tmp_path / "001.vid", [])
    with pytest.raises(RuntimeError, match="already running"):
        job.start(tmp_path / "in.mp4", tmp_path / "002.vid", [])
    with qtbot.waitSignal(job.finished, timeout=15000):
        pass


def test_encode_job_failed_to_start(tmp_path, qtbot):
    """Encoder that doesn't exist must emit finished(-1, {}) with error line
    and clean up any pre-existing tmp files."""
    out = tmp_path / "001.vid"
    tmp_out = out.with_suffix(".vid.tmp")
    tmp_rep = out.with_suffix(".report.tmp")
    tmp_out.write_bytes(b"STALE")
    tmp_rep.write_text("stale")
    job = EncodeJob(["Z:/definitely/missing.exe"], ffmpeg="x")
    lines = []
    job.line.connect(lines.append)
    with qtbot.waitSignal(job.finished, timeout=15000) as blocker:
        job.start(tmp_path / "in.mp4", out, [])
    code, report = blocker.args
    assert code == -1
    assert report == {}
    assert any("ERROR" in line and "failed to start" in line for line in lines)
    assert not tmp_out.exists()
    assert not tmp_rep.exists()
