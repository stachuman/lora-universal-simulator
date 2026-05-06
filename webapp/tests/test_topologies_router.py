"""Integration tests for /api/topologies via httpx + asgi_lifespan."""

from __future__ import annotations
import json
import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient
from server.main import app


SAMPLE_TOPO = {
    "name": "test-mesh",
    "path_loss": {
        "model": "log_distance",
        "alpha": 3.0, "sigma_db": 0.0,
        "ref_distance_m": 1.0, "ref_loss_db": 40.0,
        "noise_floor_db": -120.0, "tx_power_dbm": 14.0,
    },
    "nodes": [
        {"name": "alice", "lat": 41.39, "lon": 2.16},
        {"name": "bob",   "lat": 41.40, "lon": 2.16},
    ],
}


@pytest.mark.asyncio
async def test_topology_crud(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            r = await c.post("/api/topologies", json=SAMPLE_TOPO)
            assert r.status_code in (200, 201), r.text
            tid = r.json()["id"]

            r = await c.get("/api/topologies")
            assert r.status_code == 200
            ids = [t["id"] for t in r.json()]
            assert tid in ids

            r = await c.get(f"/api/topologies/{tid}")
            assert r.status_code == 200
            t = r.json()
            assert t["name"] == "test-mesh"
            assert len(t["nodes"]) == 2

            r = await c.delete(f"/api/topologies/{tid}")
            assert r.status_code == 200

            r = await c.get(f"/api/topologies/{tid}")
            assert r.status_code == 404


@pytest.mark.asyncio
async def test_preview_snr(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            r = await c.post("/api/topo-creator/preview-snr", json={
                "nodes": SAMPLE_TOPO["nodes"],
                "path_loss": SAMPLE_TOPO["path_loss"],
            })
            assert r.status_code == 200, r.text
            m = r.json()["matrix"]
            assert len(m) == 2
            # Adjacent ~1.1 km — SNR should be in the [-3, +3] range for these params
            assert -3.0 < m[0][1] < 3.0
