"""Unit test for SimManager.import_sim — registers a completed sim from an
existing config dict + events file, without running lus."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from server.services.sim_manager import SimManager

REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.asyncio
async def test_import_sim_creates_completed_sim(tmp_path):
    # A minimal events file and config — content correctness is not import_sim's
    # job; it only copies + registers.
    src_events = tmp_path / "src.ndjson"
    src_events.write_text(
        '{"type":"sim_start","time_ms":0}\n'
        '{"type":"tx","time_ms":10,"node":"a"}\n'
        '{"type":"sim_end","time_ms":20}\n'
    )
    cfg = {"simulation": {"duration_ms": 20}, "nodes": [], "topology": {"links": []}}

    mgr = SimManager(data_dir=tmp_path, orchestrator_path="/nonexistent/lus",
                     max_concurrent=1)
    sim_id = await mgr.import_sim(cfg, str(src_events))

    assert sim_id
    rec = mgr.get_sim(sim_id)
    assert rec is not None and rec.status == "completed"
    assert rec.completed_at is not None

    sim_dir = tmp_path / "simulations" / sim_id
    assert (sim_dir / "config.json").exists()
    assert (sim_dir / "events.ndjson").exists()
    # config round-trips
    assert json.loads((sim_dir / "config.json").read_text()) == cfg
    # events copied verbatim
    assert (sim_dir / "events.ndjson").read_text() == src_events.read_text()
    # path helpers resolve
    assert mgr.get_events_path(sim_id) == sim_dir / "events.ndjson"
    assert mgr.get_config_path(sim_id) == sim_dir / "config.json"
