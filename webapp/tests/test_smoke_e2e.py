"""End-to-end smoke test: run the s01 scenario through the webapp and
verify the events the SSE/REST surface produces match what the CLI
produces directly.
"""

from __future__ import annotations

import asyncio
import json
import subprocess
from pathlib import Path

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_webapp_matches_cli_events(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s01 scenario missing")

    # Run via CLI for ground truth.
    cli_events = tmp_path / "cli_events.ndjson"
    subprocess.run(
        [str(LUS), str(SCENARIO), str(cli_events)],
        check=True, capture_output=True, cwd=REPO_ROOT,
    )
    cli_types = sorted(json.loads(line)["type"] for line in cli_events.open())

    monkeypatch.setenv("DATA_DIR", str(tmp_path / "webapp_data"))
    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/api/sims", json={"config_json": cfg})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]
            for _ in range(180):
                s = await client.get(f"/api/sims/{sim_id}")
                if s.json().get("status") in ("completed", "failed"):
                    break
                await asyncio.sleep(0.5)

            ev = await client.get(f"/api/sims/{sim_id}/events", params={"from": 0, "to": 60_000_000})
            web_events = ev.json()["events"]
            web_types = sorted(e["type"] for e in web_events)

    # Both runs are deterministic; type-multisets must match (the events
    # endpoint excludes the metadata-only types like sim_start/sim_end/
    # node_ready, so filter them out of the CLI side too).
    METADATA_TYPES = {"sim_start", "sim_end", "node_ready", "sim_summary",
                     "assertions", "node_stats"}
    cli_filtered = sorted(t for t in cli_types if t not in METADATA_TYPES)
    assert cli_filtered == web_types, (
        f"CLI vs webapp event types differ:\n"
        f"  cli-only: {set(cli_filtered) - set(web_types)}\n"
        f"  web-only: {set(web_types) - set(cli_filtered)}"
    )
