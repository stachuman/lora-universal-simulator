"""Asserts that node_started and node_died NDJSON events fire at the
configured times and that the node is fully invisible / silent
outside its [start_at_ms, dies_at_ms] window.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
T24 = REPO_ROOT / "test" / "t24_node_dies.json"
T25 = REPO_ROOT / "test" / "t25_node_starts.json"


def _run_lus(tmp_path, scenario: Path) -> list[dict]:
    if not LUS.exists():
        pytest.skip("lus binary missing: build with `cmake --build build -j`")
    if not scenario.exists():
        pytest.skip(f"scenario missing: {scenario}")
    out = tmp_path / f"{scenario.stem}_events.ndjson"
    subprocess.run(
        [str(LUS), str(scenario), str(out)],
        check=True, capture_output=True, cwd=REPO_ROOT,
    )
    return [json.loads(line) for line in out.open() if line.strip()]


def test_node_died_event_fires_at_configured_time(tmp_path):
    events = _run_lus(tmp_path, T24)
    deaths = [e for e in events if e.get("type") == "node_died"]
    assert len(deaths) == 1, f"expected one node_died, got {len(deaths)}"
    assert deaths[0]["time_ms"] == 5000
    assert deaths[0]["node"] == "relay"


def test_relay_is_silent_after_death(tmp_path):
    events = _run_lus(tmp_path, T24)
    # No tx/rx events with relay as from or to after t=5000.
    after = [
        e for e in events
        if e.get("time_ms", 0) > 5000
        and e.get("type") in ("tx", "rx")
        and (e.get("from") == "relay" or e.get("to") == "relay")
    ]
    assert after == [], f"relay should be silent after t=5000; found {after[:3]}"


def test_node_started_event_fires_at_configured_time(tmp_path):
    events = _run_lus(tmp_path, T25)
    births = [e for e in events if e.get("type") == "node_started"]
    assert len(births) == 1, f"expected one node_started, got {len(births)}"
    assert births[0]["time_ms"] == 5000
    assert births[0]["node"] == "relay"


def test_relay_is_invisible_before_birth(tmp_path):
    events = _run_lus(tmp_path, T25)
    # No tx/rx events with relay as from or to before t=5000.
    before = [
        e for e in events
        if e.get("time_ms", 0) < 5000
        and e.get("type") in ("tx", "rx")
        and (e.get("from") == "relay" or e.get("to") == "relay")
    ]
    assert before == [], f"relay should be invisible before t=5000; found {before[:3]}"


def test_relay_node_ready_fires_at_birth(tmp_path):
    events = _run_lus(tmp_path, T25)
    relay_ready = [
        e for e in events
        if e.get("type") == "node_ready" and e.get("node") == "relay"
    ]
    assert len(relay_ready) == 1, f"expected one node_ready for relay, got {len(relay_ready)}"
    assert relay_ready[0]["time_ms"] == 5000
