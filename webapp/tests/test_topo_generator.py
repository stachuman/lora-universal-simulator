"""Tests for topo_generator — path-loss formula must match the C++ side."""

import math
import pytest
from server.services.topo_generator import (
    haversine_m, compute_snr, compute_snr_matrix,
    generate_grid, generate_random,
)


def test_haversine_zero():
    assert haversine_m(0, 0, 0, 0) == pytest.approx(0.0, abs=1e-9)


def test_haversine_known_distance():
    # ~1.5 km along a meridian (matches s01 spacing)
    d = haversine_m(41.3900, 2.1600, 41.4035, 2.1600)
    assert 1490 < d < 1510


def test_compute_snr_matches_cpp_at_1500m():
    # C++ ground truth from PathLossModel.cpp at d=1500, alpha=3, ref=40@1m,
    # noise=-120, tx=14:
    # PL = 40 + 30*log10(1500) ~= 135.282
    # rx = 14 - 135.282 = -121.282
    # snr = -121.282 - (-120) = -1.282
    snr = compute_snr(1500, alpha=3.0, sigma_db=0.0, ref_distance_m=1.0,
                      ref_loss_db=40.0, noise_floor_db=-120.0, tx_power_dbm=14.0)
    assert -1.5 < snr < -1.0


def test_compute_snr_matches_cpp_at_3000m():
    snr = compute_snr(3000, alpha=3.0, sigma_db=0.0, ref_distance_m=1.0,
                      ref_loss_db=40.0, noise_floor_db=-120.0, tx_power_dbm=14.0)
    # PL = 40 + 30*log10(3000) ~= 144.314
    # snr ~= -10.314
    assert -10.5 < snr < -10.0


def test_compute_snr_clamps_below_ref_distance():
    # d < ref_distance_m clamps to ref_distance_m
    snr_at_05 = compute_snr(0.5, alpha=3.0, sigma_db=0.0, ref_distance_m=1.0,
                            ref_loss_db=40.0, noise_floor_db=-120.0, tx_power_dbm=14.0)
    snr_at_1 = compute_snr(1.0, alpha=3.0, sigma_db=0.0, ref_distance_m=1.0,
                           ref_loss_db=40.0, noise_floor_db=-120.0, tx_power_dbm=14.0)
    assert snr_at_05 == pytest.approx(snr_at_1)


def test_snr_matrix_shape_and_self_sentinel():
    nodes = [{"lat": 41.39, "lon": 2.16},
             {"lat": 41.40, "lon": 2.16},
             {"lat": 41.41, "lon": 2.16}]
    pl = {"alpha": 3.0, "sigma_db": 0.0, "ref_distance_m": 1.0,
          "ref_loss_db": 40.0, "noise_floor_db": -120.0, "tx_power_dbm": 14.0}
    m = compute_snr_matrix(nodes, pl)
    assert len(m) == 3 and len(m[0]) == 3
    # Diagonal = self (no link); whatever sentinel value is fine, just must not be a normal SNR
    for i in range(3):
        assert m[i][i] > 100 or math.isinf(m[i][i])
    # Symmetry
    for i in range(3):
        for j in range(3):
            if i != j:
                assert abs(m[i][j] - m[j][i]) < 0.01


def test_generate_grid_returns_correct_count():
    nodes = generate_grid(center_lat=52.52, center_lon=13.40, n_x=3, n_y=3,
                          spacing_m=200, name_prefix="n")
    assert len(nodes) == 9
    assert all("lat" in n and "lon" in n and "name" in n for n in nodes)


def test_generate_random_respects_seed():
    bbox = [52.0, 13.0, 53.0, 14.0]
    a = generate_random(bbox, count=10, name_prefix="r", seed=42)
    b = generate_random(bbox, count=10, name_prefix="r", seed=42)
    assert a == b
