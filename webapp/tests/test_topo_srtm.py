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


@itm_skip
def test_compute_link_matrix_three_nodes_flat_terrain_symmetric_legacy():
    """asymmetry=False reproduces the legacy single-bidir-per-pair output."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "bob",   "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "carol", "lat": 47.63, "lon": -122.33, "antenna_height_m": 1.5},
    ]
    r = compute_link_matrix(
        nodes, freq_mhz=868.0, tx_power_dbm=14.0,
        bandwidth_hz=62500.0, noise_figure_db=6.0,
        profile_resolution_m=90.0,
        min_snr_db=-50.0,  # permissive — keep everything
        max_links_per_node=8,
        asymmetry=False,
        srtm_data=srtm,
    )
    assert r["n_pairs_evaluated"] == 3, "C(3,2) = 3 pairs"
    assert r["n_srtm_misses"] == 0
    assert len(r["links"]) == 3
    names = {(l["from"], l["to"]) for l in r["links"]}
    assert names == {("alice", "bob"), ("alice", "carol"), ("bob", "carol")}
    for l in r["links"]:
        assert l["bidir"] is True
        assert isinstance(l["snr"], float)
        assert isinstance(l["rssi"], float)
        assert l["snr_std_dev"] >= 0


@itm_skip
def test_compute_link_matrix_default_emits_directional_pairs():
    """Default (asymmetry=True): 3 pairs → 6 directional entries (bidir=False)."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "bob",   "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "carol", "lat": 47.63, "lon": -122.33, "antenna_height_m": 1.5},
    ]
    r = compute_link_matrix(
        nodes, freq_mhz=868.0,
        bandwidth_hz=62500.0, noise_figure_db=6.0,
        profile_resolution_m=90.0,
        min_snr_db=-50.0, max_links_per_node=8,
        srtm_data=srtm,
    )
    # Two directed entries per pair, both bidir=False.
    assert len(r["links"]) == 6
    pairs = {tuple(sorted([l["from"], l["to"]])) for l in r["links"]}
    assert pairs == {("alice", "bob"), ("alice", "carol"), ("bob", "carol")}
    for l in r["links"]:
        assert l["bidir"] is False


@itm_skip
def test_asymmetry_is_deterministic_across_runs():
    """Same nodes + freq + asymmetry_floor → identical SNR values on rerun."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "n1", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "n2", "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
    ]
    r1 = compute_link_matrix(nodes, min_snr_db=-50.0, srtm_data=srtm)
    r2 = compute_link_matrix(nodes, min_snr_db=-50.0, srtm_data=srtm)
    assert r1["links"] == r2["links"], (
        "asymmetric draws must be deterministic given same node names + freq"
    )


@itm_skip
def test_asymmetry_floor_keeps_strong_links_near_symmetric():
    """A strong (flat-terrain) link should have its two directions
    within ±asymmetry_floor_db of each other; the floor caps how far
    apart they can be when ITM's own spread is ~0."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "a", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "b", "lat": 47.611, "lon": -122.33, "antenna_height_m": 1.5},
    ]
    r = compute_link_matrix(
        nodes, min_snr_db=-50.0, asymmetry_floor_db=0.5,
        srtm_data=srtm,
    )
    by_dir = {(l["from"], l["to"]): l["snr"] for l in r["links"]}
    snr_ab = by_dir[("a", "b")]
    snr_ba = by_dir[("b", "a")]
    # With sigma=0.5 dB the per-direction draws are tightly bounded.
    # |Δ| should comfortably stay under 4σ (3.5 dB allows margin).
    assert abs(snr_ab - snr_ba) < 3.5, (
        f"strong-link asymmetry too wide: {snr_ab} vs {snr_ba}"
    )


def test_compute_link_matrix_srtm_miss_skips_pair():
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: None)  # all misses
    nodes = [
        {"name": "alice", "lat": 47.61, "lon": -122.33},
        {"name": "bob",   "lat": 47.62, "lon": -122.33},
    ]
    r = compute_link_matrix(nodes, srtm_data=srtm)
    assert r["n_pairs_evaluated"] == 1
    assert r["n_srtm_misses"] == 1
    assert r["links"] == []


@itm_skip
def test_compute_pair_link_zero_antenna_clamps_not_crashes():
    """ITM's qlrpfl divides by antenna height — 0 m would crash with
    ZeroDivisionError. The service clamps to a 0.1 m floor as a
    defensive last line; pydantic + C++ validators reject 0 at the
    schema layer in normal flows."""
    from server.services.topo_srtm import compute_pair_link
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    a = {"name": "a", "lat": 47.61, "lon": -122.33, "antenna_height_m": 0.0}
    b = {"name": "b", "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5}
    r = compute_pair_link(
        a, b, srtm,
        freq_mhz=868.0, tx_power_dbm=14.0,
        bandwidth_hz=62500.0, noise_figure_db=6.0,
        profile_resolution_m=90.0,
    )
    assert r is not None, "0 antenna height should clamp, not return None"
    assert isinstance(r["snr_db"], float)


def test_compute_link_matrix_max_links_per_node_cap():
    """Star topology with 5 leaves around 1 hub. With max_links_per_node=2,
    only 2 of the 4 hub-leaf pairs survive — counting PAIRS (canonical
    name-set), not directional entries (asymmetric mode emits 2 per
    pair)."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "hub",   "lat": 47.610, "lon": -122.330},
        {"name": "leaf1", "lat": 47.611, "lon": -122.330},
        {"name": "leaf2", "lat": 47.612, "lon": -122.330},
        {"name": "leaf3", "lat": 47.613, "lon": -122.330},
        {"name": "leaf4", "lat": 47.614, "lon": -122.330},
    ]
    r = compute_link_matrix(
        nodes, min_snr_db=-50.0, max_links_per_node=2, srtm_data=srtm,
    )
    hub_pairs = {
        tuple(sorted([l["from"], l["to"]]))
        for l in r["links"] if l["from"] == "hub" or l["to"] == "hub"
    }
    assert len(hub_pairs) <= 2, (
        f"hub should be capped at 2 pairs, got {len(hub_pairs)}: {hub_pairs}"
    )
