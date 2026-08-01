"""Encoder resolution (video.ps1's order), stdout status parsing and
BuildReport reading. The QProcess job is added in a later task."""
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

_MB = 1024 * 1024

_AUTO_RE = re.compile(
    r"auto-budget:\s+--stream-budget\s+([\d.]+)\s+->\s+util\s+([\d.]+)")
_DELTA_RE = re.compile(
    r"delta stats:\s+budget-bound\s+([\d.]+)%.*@f(\d+)")
_RETIME_RE = re.compile(r"retime:\s+(.*)")
_SLACK_RE = re.compile(r"tile-slack:\s+(.*)")


def resolve_encoder(kit_root, toolsdir):
    kit_root = Path(kit_root)
    for exe in (Path(toolsdir, "videnc", "videnc.exe"),
                kit_root / "tools" / "videnc" / "videnc.exe"):
        if not exe.is_absolute():
            exe = kit_root / exe
        if exe.is_file() and exe.stat().st_size > _MB:
            return [str(exe)]
    for cand in (["py", "-3"], ["python"]):
        try:
            r = subprocess.run(cand + ["-c", "import PIL, numpy"],
                               capture_output=True, timeout=30)
            if r.returncode == 0:
                return cand + [str(kit_root / "lib" / "videnc.py")]
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def parse_progress_line(line):
    m = _AUTO_RE.search(line)
    if m:
        return {"kind": "auto-budget", "budget": float(m.group(1)),
                "util": float(m.group(2))}
    m = _DELTA_RE.search(line)
    if m:
        return {"kind": "delta-stats", "bound_pct": float(m.group(1)),
                "peak_frame": int(m.group(2))}
    m = _RETIME_RE.search(line)
    if m:
        return {"kind": "retime", "text": m.group(1)}
    m = _SLACK_RE.search(line)
    if m:
        return {"kind": "tile-slack", "text": m.group(1)}
    return None


def read_report(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


@dataclass
class MetricsSummary:
    psnr_mean: object = None
    bound_fraction: object = None
    burst_peak_frame: object = None
    stream_budget: object = None
    auto_budget: object = None
    util: object = None
    wire_bytes: object = None


def summarize_report(report):
    # Key names verified against real --report output (probe.json).
    return MetricsSummary(
        psnr_mean=report.get("mean_psnr"),
        bound_fraction=report.get("bound_fraction"),
        burst_peak_frame=report.get("burst_peak_frame"),
        stream_budget=report.get("stream_budget"),
        auto_budget=report.get("auto_budget"),
        util=report.get("stream_utilization"),
        wire_bytes=report.get("total_bytes"),
    )
