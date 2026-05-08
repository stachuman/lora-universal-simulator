"""Asserts the warmup_end NDJSON event fires at the right time and is
absent when warmup_ms == 0. Subprocess-runs lus directly so the test
doesn't depend on the FastAPI surface.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
T23 = REPO_ROOT / "test" / "t23_warmup_end.json"           # warmup_ms=100
T01 = REPO_ROOT / "test" / "t01_flooder.json"              # warmup_ms=0


def _run_lus(tmp_path, scenario: Path) -> list[dict]:
    if not LUS.exists():
        pytest.skip(f"lus binary missing: build with `cmake --build build -j`")
    if not scenario.exists():
        pytest.skip(f"scenario missing: {scenario}")
    out = tmp_path / f"{scenario.stem}_events.ndjson"
    subprocess.run(
        [str(LUS), str(scenario), str(out)],
        check=True, capture_output=True, cwd=REPO_ROOT,
    )
    return [json.loads(line) for line in out.open() if line.strip()]


def test_warmup_end_fires_at_boundary(tmp_path):
    events = _run_lus(tmp_path, T23)

    warmup_ends = [e for e in events if e.get("type") == "warmup_end"]
    assert len(warmup_ends) == 1, (
        f"expected exactly one warmup_end, got {len(warmup_ends)}"
    )

    # t23 has warmup_ms=100.
    assert warmup_ends[0]["time_ms"] == 100, (
        f"warmup_end time_ms should be 100, got {warmup_ends[0]['time_ms']}"
    )


def test_warmup_end_ordering(tmp_path):
    events = _run_lus(tmp_path, T23)

    types = [e.get("type") for e in events]
    sim_start_idx = types.index("sim_start")
    warmup_end_idx = types.index("warmup_end")
    sim_end_idx = types.index("sim_end")

    assert sim_start_idx < warmup_end_idx < sim_end_idx, (
        f"ordering wrong: sim_start@{sim_start_idx}, "
        f"warmup_end@{warmup_end_idx}, sim_end@{sim_end_idx}"
    )


def test_no_warmup_end_when_warmup_zero(tmp_path):
    events = _run_lus(tmp_path, T01)

    warmup_ends = [e for e in events if e.get("type") == "warmup_end"]
    assert warmup_ends == [], (
        f"warmup_ms=0 should suppress the event entirely, got {warmup_ends}"
    )
