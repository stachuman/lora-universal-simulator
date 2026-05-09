"""Unit tests for webapp.server.services.topo_srtm."""

from __future__ import annotations

import math

import pytest

from server.services.topo_srtm import (
    haversine_km,
    fspl_db,
    noise_floor_dbm,
)


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
