"""Unit tests for config validator."""

from __future__ import annotations

from server.services.config_validator import validate


def test_minimal_valid(minimal_lus_config):
    parsed, errors = validate(minimal_lus_config)
    assert errors == []
    assert parsed is not None
    assert parsed.simulation.duration_ms == 1000
    assert parsed.nodes[0].name == "alice"


def test_meshcore_top_level_firmware_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["firmware"] = {"default": "x"}
    parsed, errors = validate(cfg)
    assert parsed is None
    assert any("firmware" in e and "MeshCore-specific" in e for e in errors)


def test_meshcore_node_role_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], role="originator")]
    parsed, errors = validate(cfg)
    assert parsed is None
    assert any("'role'" in e and "MeshCore-specific" in e for e in errors)


def test_path_loss_block_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"])
    cfg["simulation"]["path_loss"] = {
        "model": "log_distance",
        "alpha": 3.0,
        "sigma_db": 0.0,
        "ref_distance_m": 1.0,
        "ref_loss_db": 40.0,
        "noise_floor_db": -120.0,
        "tx_power_dbm": 14.0,
    }
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.path_loss.alpha == 3.0


def test_lat_lon_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], lat=41.39, lon=2.16)]
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.nodes[0].lat == 41.39


def test_sf_rx_set_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], sf_rx_set=[7, 8, 9])]
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.nodes[0].sf_rx_set == [7, 8, 9]


def test_unknown_top_level_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["unknown_field"] = 42
    parsed, errors = validate(cfg)
    assert parsed is None  # extra="forbid" rejects
