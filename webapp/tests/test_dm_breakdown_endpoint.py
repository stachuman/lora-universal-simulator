"""Integration test for GET /api/sims/{sim_id}/dm_breakdown."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


@pytest.mark.asyncio
async def test_dm_breakdown_after_completion(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s13 scenario missing")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims", json={"config_json": cfg})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]

            for _ in range(120):
                s = await client.get(f"/api/sims/{sim_id}")
                if s.json().get("status") in ("completed", "failed"):
                    break
                await asyncio.sleep(0.5)
            assert (await client.get(f"/api/sims/{sim_id}")).json()["status"] == "completed"

            b = await client.get(f"/api/sims/{sim_id}/dm_breakdown")
            assert b.status_code == 200, b.text
            data = b.json()
            assert "summary" in data and "channels" in data
            assert isinstance(data["summary"], list)
            assert isinstance(data["channels"], list)


@pytest.mark.asyncio
async def test_dm_breakdown_unknown_sim_404(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.get("/api/sims/does-not-exist/dm_breakdown")
            assert r.status_code == 404, r.text
