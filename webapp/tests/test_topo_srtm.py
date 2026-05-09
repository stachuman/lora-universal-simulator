"""Unit tests for webapp.server.services.topo_srtm."""

from __future__ import annotations

import importlib.util
import math

import pytest

from server.services.topo_srtm import (
    haversine_km,
    fspl_db,
    noise_floor_dbm,
)

_HAS_ITM = importlib.util.find_spec("itmlogic") is not None
itm_skip = pytest.mark.skipif(not _HAS_ITM, reason="itmlogic not installed")


def test_haversine_km_seattle_to_tacoma():
    # Seattle (47.6062, -122.3321) to Tacoma (47.2529, -122.4443) ≈ 39.7 km
    d = haversine_km(47.6062, -122.3321, 47.2529, -122.4443)
    assert 38.0 < d < 41.0, f"expected ~40 km, got {d:.2f}"


def test_haversine_km_zero_distance():
    assert haversine_km(40.0, 5.0, 40.0, 5.0) == 0.0


def test_fspl_db_known():
    # 1 km @ 868 MHz: 32.44 + 0 + 58.78 ≈ 91.22 dB
    assert math.isclose(fspl_db(1.0, 868.0), 91.22, abs_tol=0.05)


def test_fspl_db_zero_distance():
    assert fspl_db(0.0, 868.0) == 0.0


def test_noise_floor_dbm_lora_62500_hz():
    # BW=62500 Hz, NF=6: -174 + 47.96 + 6 ≈ -120.04 dBm
    assert math.isclose(noise_floor_dbm(62500.0, 6.0), -120.04, abs_tol=0.05)


def test_noise_floor_dbm_default_nf_is_6_db():
    # default noise_figure_db = 6
    a = noise_floor_dbm(62500.0)
    b = noise_floor_dbm(62500.0, 6.0)
    assert a == b


@itm_skip
def test_compute_link_itm_short_link_returns_dict():
    from server.services.topo_srtm import compute_link_itm
    # 1 km link, flat 50 m ground, both 1.5 m antennas, 868 MHz.
    profile = [50.0] * 10
    r = compute_link_itm(profile, 1.0, 868.0, (1.5, 1.5))
    assert isinstance(r, dict)
    assert {"loss_median_db", "loss_10pct_db", "loss_90pct_db", "kwx"} <= r.keys()
    # Median loss should be at least the FSPL floor.
    from server.services.topo_srtm import fspl_db
    assert r["loss_median_db"] >= fspl_db(1.0, 868.0) - 0.1


@itm_skip
def test_compute_link_itm_obstructed_attenuates_more_than_flat():
    from server.services.topo_srtm import compute_link_itm
    # Flat 5 km link.
    flat = [50.0] * 50
    r_flat = compute_link_itm(flat, 5.0, 868.0, (1.5, 1.5))
    # Same 5 km but with a 200 m peak in the middle.
    obstructed = [50.0] * 50
    obstructed[25] = 250.0
    r_obs = compute_link_itm(obstructed, 5.0, 868.0, (1.5, 1.5))
    assert r_obs["loss_median_db"] > r_flat["loss_median_db"] + 5.0, (
        f"obstructed should attenuate more, got "
        f"flat={r_flat['loss_median_db']:.1f} obs={r_obs['loss_median_db']:.1f}"
    )


def test_compute_link_itm_too_few_points_returns_kwx_4():
    from server.services.topo_srtm import compute_link_itm
    r = compute_link_itm([50.0, 50.0], 1.0, 868.0, (1.5, 1.5))
    assert r["kwx"] == 4
    assert r["loss_median_db"] == 0.0


class _FakeSrtm:
    """Mock srtm.GeoElevationData. Returns a callable elevation function
    so tests can hand-pick the terrain shape."""
    def __init__(self, elev_fn):
        self._fn = elev_fn

    def get_elevation(self, lat, lon):
        return self._fn(lat, lon)


def test_intermediate_point_endpoints():
    from server.services.topo_srtm import intermediate_point
    a = intermediate_point(40.0, 5.0, 50.0, 10.0, 0.0)
    b = intermediate_point(40.0, 5.0, 50.0, 10.0, 1.0)
    assert math.isclose(a[0], 40.0, abs_tol=1e-6)
    assert math.isclose(a[1], 5.0, abs_tol=1e-6)
    assert math.isclose(b[0], 50.0, abs_tol=1e-6)
    assert math.isclose(b[1], 10.0, abs_tol=1e-6)


def test_intermediate_point_zero_distance():
    from server.services.topo_srtm import intermediate_point
    p = intermediate_point(40.0, 5.0, 40.0, 5.0, 0.5)
    assert p == (40.0, 5.0)


def test_sample_elevation_profile_flat_terrain():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: 100.0)
    profile = sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 10)
    assert profile == [100.0] * 10


def test_sample_elevation_profile_returns_none_on_miss():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: None)  # always miss
    profile = sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 10)
    assert profile is None


def test_sample_elevation_profile_min_2_points():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    assert sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 1) is None
