"""Smoke tests for sim_manager — spawn lus on a real config, observe lifecycle."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest

from server.services.sim_manager import SimManager


REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_sim_lifecycle_spawn_to_completion(tmp_path):
    if not LUS.exists():
        pytest.skip(f"lus binary not built at {LUS}")
    if not SCENARIO.exists():
        pytest.skip(f"scenario fixture not found at {SCENARIO}")

    mgr = SimManager(data_dir=tmp_path, orchestrator_path=str(LUS), max_concurrent=1, cwd=REPO_ROOT)

    cfg = json.loads(SCENARIO.read_text())
    sim_id = await mgr.create_sim(cfg)
    assert sim_id

    # Poll for completion (max 60 s).
    for _ in range(120):
        s = mgr.get_sim(sim_id)
        if s and s.status in ("completed", "failed"):
            break
        await asyncio.sleep(0.5)

    s = mgr.get_sim(sim_id)
    assert s is not None, "simulation record vanished"
    assert s.status == "completed", (
        f"expected completed, got {s.status}; stderr={getattr(s, 'last_stderr', '<none>')}"
    )

    events_file = tmp_path / "simulations" / sim_id / "events.ndjson"
    assert events_file.exists()
    types = {json.loads(line)["type"] for line in events_file.open()}
    assert "sim_start" in types
    assert "sim_end" in types
