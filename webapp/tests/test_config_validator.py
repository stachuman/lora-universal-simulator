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


def test_meshcore_requires_plugins_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["_requires_plugins"] = ["fw_mc"]
    parsed, errors = validate(cfg)
    assert parsed is None
    assert any("_requires_plugins" in e and "MeshCore-specific" in e for e in errors)


def test_cr_low_values_accepted(minimal_lus_config):
    """C++ side accepts any cr > 0; schema must not reject Semtech 1..4 encoding."""
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"])
    cfg["simulation"]["radio"] = dict(cfg["simulation"]["radio"], cr=1)
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.radio.cr == 1


def test_radio_extra_fields_accepted(minimal_lus_config):
    """capture_locked_db, capture_unlocked_db, snr_coherence_ms are read by C++."""
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"])
    cfg["simulation"]["radio"] = dict(
        cfg["simulation"]["radio"],
        capture_locked_db=8.0,
        capture_unlocked_db=4.0,
        snr_coherence_ms=200.0,
    )
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.radio.capture_locked_db == 8.0


def test_radio_hardware_nested_block_accepted(minimal_lus_config):
    """C++ reads radio.hardware.{rx_to_tx_delay_ms, tx_to_rx_delay_ms} (nested)."""
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"])
    cfg["simulation"]["radio"] = dict(
        cfg["simulation"]["radio"],
        hardware={"rx_to_tx_delay_ms": 1, "tx_to_rx_delay_ms": 2},
    )
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.radio.hardware.rx_to_tx_delay_ms == 1


def test_simulation_seed_and_epoch_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"], seed=42, epoch_start=100)
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.seed == 42


def test_step_ms_zero_rejected(minimal_lus_config):
    """C++ rejects step_ms=0; Python schema must too."""
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"], step_ms=0)
    parsed, errors = validate(cfg)
    assert parsed is None


def test_command_lua_variant_accepted(minimal_lus_config):
    """C++ supports {at_ms, lua} commands; schema must accept them."""
    cfg = dict(minimal_lus_config)
    cfg["commands"] = [{"at_ms": 100, "lua": "print('hi')"}]
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.commands[0].lua == "print('hi')"
