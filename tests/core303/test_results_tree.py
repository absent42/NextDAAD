"""Checks the core303 results tree: baseline manifest and INDEX.md header."""

import hashlib
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"
BASELINE = RESULTS / "baseline-old-core-2026-09-17"
INDEX_HEADER = "| date | board | leg | verdict | folder |"
INDEX_SEPARATOR = "|---|---|---|---|---|"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_baseline_manifest():
    sums = BASELINE / "SHA256SUMS"
    lines = [ln for ln in sums.read_text(encoding="ascii").splitlines() if ln.strip()]
    assert lines, "SHA256SUMS has no entries"
    for line in lines:
        digest, name = line.split("  ", 1)
        target = BASELINE / name
        assert target.is_file(), f"missing {name}"
        assert _sha256(target) == digest, f"hash mismatch for {name}"

    sitting = (BASELINE / "sitting.txt").read_text(encoding="ascii")
    for key in ("date:", "board:", "core:", "source:"):
        assert any(ln.startswith(key) for ln in sitting.splitlines()), f"sitting.txt lacks {key}"


def test_index_header():
    index_lines = (RESULTS / "INDEX.md").read_text(encoding="ascii").splitlines()
    assert index_lines[0] == INDEX_HEADER
    assert index_lines[1] == INDEX_SEPARATOR
