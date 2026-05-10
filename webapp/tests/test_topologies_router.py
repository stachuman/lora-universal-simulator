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


@pytest.mark.asyncio
async def test_topology_round_trips_links_and_per_node_fields(tmp_path, monkeypatch):
    """A topology saved with computed links + per-node lifecycle fields
    (antenna_height_m / start_at_ms / dies_at_ms) round-trips byte-faithfully
    so the editor can restore both the heatmap AND the operator-set knobs."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    body = {
        "name": "test-with-links",
        "path_loss": SAMPLE_TOPO["path_loss"],
        "nodes": [
            {"name": "alice", "lat": 41.39, "lon": 2.16,
             "antenna_height_m": 10.0},
            {"name": "bob", "lat": 41.40, "lon": 2.16,
             "start_at_ms": 5000, "dies_at_ms": 25000},
        ],
        "links": [
            {"from": "alice", "to": "bob",
             "snr": 7.5, "rssi": -82.3, "snr_std_dev": 1.2, "bidir": True},
        ],
    }

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            r = await c.post("/api/topologies", json=body)
            assert r.status_code in (200, 201), r.text
            tid = r.json()["id"]

            r = await c.get(f"/api/topologies/{tid}")
            assert r.status_code == 200
            t = r.json()

    # Round-trip checks.
    assert len(t["links"]) == 1
    link = t["links"][0]
    assert link["from"] == "alice" and link["to"] == "bob"
    assert link["snr"] == 7.5
    assert link["rssi"] == -82.3
    assert link["snr_std_dev"] == 1.2
    assert link["bidir"] is True

    # Per-node fields round-trip too.
    nodes_by_name = {n["name"]: n for n in t["nodes"]}
    assert nodes_by_name["alice"]["antenna_height_m"] == 10.0
    assert nodes_by_name["bob"]["start_at_ms"] == 5000
    assert nodes_by_name["bob"]["dies_at_ms"] == 25000


@pytest.mark.asyncio
async def test_topology_links_default_to_empty_list(tmp_path, monkeypatch):
    """A POST without `links` succeeds and the GET returns []."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            r = await c.post("/api/topologies", json=SAMPLE_TOPO)
            assert r.status_code in (200, 201)
            tid = r.json()["id"]
            r = await c.get(f"/api/topologies/{tid}")
            assert r.status_code == 200
            assert r.json().get("links", []) == []
