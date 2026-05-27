"""Integration tests for POST /api/sims/import."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


@pytest.mark.asyncio
async def test_import_happy_path(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s13 scenario missing")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    # Produce a real events file out-of-band (the thing a user would import).
    events = tmp_path / "s13.ndjson"
    subprocess.run([str(LUS), str(SCENARIO), str(events)],
                   check=True, capture_output=True)
    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(events)})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]

            s = await client.get(f"/api/sims/{sim_id}")
            assert s.json()["status"] == "completed", s.text

            ev = await client.get(f"/api/sims/{sim_id}/events",
                                   params={"from": 0, "to": 60_000_000})
            assert ev.status_code == 200
            assert ev.json()["count"] > 0


@pytest.mark.asyncio
async def test_import_missing_events_path_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(tmp_path / "nope.ndjson")})
            assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_import_empty_events_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    empty = tmp_path / "empty.ndjson"
    empty.write_text("")
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(empty)})
            assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_import_non_json_events_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    bad = tmp_path / "bad.ndjson"
    bad.write_text("this is not json\n")
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(bad)})
            assert r.status_code == 400, r.text
