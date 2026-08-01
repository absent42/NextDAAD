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
