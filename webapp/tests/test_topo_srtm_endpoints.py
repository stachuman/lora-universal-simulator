"""End-to-end tests for /api/topo-creator/generate-srtm and
/api/topo-creator/refine-with-srtm. Mocks SRTM so CI is offline."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.fixture
def fake_srtm_flat(monkeypatch):
    """Patch get_elevation_data to return a flat-100m elevation source."""
    class _Fake:
        def get_elevation(self, lat, lon):
            return 100.0
    def _factory(*a, **kw):
        return _Fake()
    monkeypatch.setattr(
        "server.services.topo_srtm.get_elevation_data", _factory)
    return _Fake()


@pytest.mark.asyncio
async def test_generate_srtm_basic(fake_srtm_flat):
    body = {
        "nodes": [
            {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
            {"name": "bob",   "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
            {"name": "carol", "lat": 47.63, "lon": -122.33, "antenna_height_m": 1.5},
        ],
        "path_loss": {
            "model": "log_distance",
            "alpha": 3.0,
            "sigma_db": 0.0,
            "ref_distance_m": 1.0,
            "ref_loss_db": 40.0,
            "noise_floor_db": -120.0,
            "tx_power_dbm": 14.0,
            "frequency_mhz": 868.0,
        },
        "itm": {
            "min_snr_db": -50.0,
        },
    }
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/topo-creator/generate-srtm", json=body)
    assert r.status_code == 200, r.text
    payload = r.json()
    assert payload["n_pairs_evaluated"] == 3
    assert payload["n_srtm_misses"] == 0
    assert payload["n_links_kept"] == 3
    assert {(l["from"], l["to"]) for l in payload["links"]} == {
        ("alice", "bob"), ("alice", "carol"), ("bob", "carol")
    }
    for l in payload["links"]:
        assert "snr" in l and "rssi" in l and "snr_std_dev" in l
        assert l["bidir"] is True


@pytest.mark.asyncio
async def test_generate_srtm_503_on_srtm_failure(monkeypatch):
    def _raise(*a, **kw):
        raise RuntimeError("network unavailable")
    monkeypatch.setattr(
        "server.services.topo_srtm.get_elevation_data", _raise)

    body = {
        "nodes": [
            {"name": "a", "lat": 47.0, "lon": -122.0},
            {"name": "b", "lat": 47.5, "lon": -122.0},
        ],
        "path_loss": {
            "model": "log_distance",
            "alpha": 3.0,
            "sigma_db": 0.0,
            "ref_distance_m": 1.0,
            "ref_loss_db": 40.0,
            "noise_floor_db": -120.0,
            "tx_power_dbm": 14.0,
        },
    }
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/topo-creator/generate-srtm", json=body)
    assert r.status_code == 503
    assert "SRTM" in r.json()["detail"]
