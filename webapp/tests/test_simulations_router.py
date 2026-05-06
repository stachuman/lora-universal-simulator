"""Integration tests for the /api/sims router via httpx test client."""

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
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_post_sim_then_poll_to_completion(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s01 scenario missing")

    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/api/sims", json={"config_json": cfg})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]
            assert sim_id

            for _ in range(120):
                s = await client.get(f"/api/sims/{sim_id}")
                if s.json().get("status") in ("completed", "failed"):
                    break
                await asyncio.sleep(0.5)

            s = await client.get(f"/api/sims/{sim_id}")
            assert s.json()["status"] == "completed", s.text

            ev = await client.get(
                f"/api/sims/{sim_id}/events", params={"from": 0, "to": 60_000_000}
            )
            events = ev.json()
            types = {e["type"] for e in events["events"]}
            # sim_start/sim_end are metadata — they live in /meta, not /events
            # tx and rx from the actual sim should be present in the event stream.
            assert "tx" in types or "script_log" in types  # at least some events landed


@pytest.mark.asyncio
async def test_post_sim_rejects_meshcore_field(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            bad = {
                "simulation": {"duration_ms": 100, "radio": {"sf": 7, "bw": 250, "cr": 5}},
                "nodes": [{"name": "a", "script": "x.lua", "config": {}, "role": "originator"}],
                "topology": {"links": []},
            }
            r = await client.post("/api/sims", json={"config_json": bad})
            assert r.status_code == 400
            assert "role" in r.text and "MeshCore" in r.text


@pytest.mark.asyncio
async def test_meta_endpoint_returns_sim_info(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s01 scenario missing")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    cfg = json.loads(SCENARIO.read_text())
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/api/sims", json={"config_json": cfg})
            sim_id = r.json()["id"]
            for _ in range(120):
                s = await client.get(f"/api/sims/{sim_id}")
                if s.json().get("status") == "completed":
                    break
                await asyncio.sleep(0.5)
            meta = await client.get(f"/api/sims/{sim_id}/meta")
            assert meta.status_code == 200
            # /meta should expose sim_info / nodes (the metadata-only events)
            body = meta.json()
            assert "nodes" in body or "sim_info" in body
