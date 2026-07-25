"""Pydantic schemas for lus scenario JSON.

These describe the lus config fields the webapp currently understands.
Unknown fields are allowed so newer scenario JSON can pass through to lus,
which is the source of truth for runtime validation.
"""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field, ConfigDict


LUS_MODEL_CONFIG = ConfigDict(extra="allow")


class PathLossModel(BaseModel):
    model_config = LUS_MODEL_CONFIG

    # "none" opts out of the log-distance baseline at orchestrator startup
    # so explicit topology.links[] entries are used verbatim. The other
    # fields are unused in that case but remain accepted so the editor
    # can round-trip the user's last-set values when toggling back.
    model: Literal["log_distance", "none"]
    alpha: Optional[float] = Field(default=None, ge=1.0, le=6.0)
    sigma_db: Optional[float] = Field(default=None, ge=0.0, le=20.0)
    ref_distance_m: Optional[float] = Field(default=None, gt=0.0)
    ref_loss_db: Optional[float] = None
    noise_floor_db: Optional[float] = None
    tx_power_dbm: Optional[float] = None
    # Per-node TX/RX gain offsets (Gaussian, drawn once per node).
    # Models hardware variation between units. C++ accepts any double;
    # we constrain to non-negative since these are stddevs.
    node_tx_offset_sigma_db: Optional[float] = Field(default=None, ge=0.0)
    node_rx_offset_sigma_db: Optional[float] = Field(default=None, ge=0.0)
    # Coherence time for the link asymmetry process (ms).
    asymmetry_coherence_ms: Optional[int] = Field(default=None, ge=0)
    # Authoring-time only — used by the SRTM+ITM topology generator,
    # not by the runtime path-loss model. Default 868 MHz EU LoRa.
    frequency_mhz: Optional[float] = Field(default=None, gt=0.0)


class RadioHardware(BaseModel):
    """Per-radio hardware turnaround delays + decode-quality knobs."""
    model_config = LUS_MODEL_CONFIG

    rx_to_tx_delay_ms: Optional[int] = Field(default=None, ge=0)
    tx_to_rx_delay_ms: Optional[int] = Field(default=None, ge=0)
    # SF re-tune latency between successive frames at different SFs.
    sf_switch_delay_ms: Optional[float] = Field(default=None, ge=0.0)
    # Per-dB steepness of the soft decode-margin curve at threshold.
    decode_margin_steepness_db: Optional[float] = Field(default=None, ge=0.0)
    # Probability the modem misses a preamble even with adequate SNR.
    rx_preamble_miss_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)


class RadioConfig(BaseModel):
    model_config = LUS_MODEL_CONFIG

    sf: int = Field(ge=5, le=12)
    # bw: kHz, accepts fractional values (LoRa supports narrow-band
    # rates 7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5 alongside the
    # standard 125 / 250 / 500). C++ historically used int; per-tx
    # event field bw_hz keeps full precision.
    bw: float = Field(gt=0.0)
    # cr: lus accepts any positive integer (universal sanity check only;
    # see core/topology/JsonConfig.cpp validator). Different sources use
    # different encodings (Semtech 1..4 for CR4/5..CR4/8, or 5..8).
    cr: int = Field(ge=1)
    cad_miss_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    cad_reliable_snr: Optional[float] = None
    cad_marginal_snr: Optional[float] = None
    capture_locked_db: Optional[float] = Field(default=None, ge=0.0)
    capture_unlocked_db: Optional[float] = Field(default=None, ge=0.0)
    snr_coherence_ms: Optional[float] = Field(default=None, ge=0.0)
    # max_packet_bytes: PHY frame-size cap. C++ validator demands [1, 65535].
    max_packet_bytes: Optional[int] = Field(default=None, ge=1, le=65535)
    # Duty-cycle limit per node (0–1) over a rolling window.
    # C++ validator demands duty_cycle in (0, 1] and window_ms > 0.
    duty_cycle: Optional[float] = Field(default=None, gt=0.0, le=1.0)
    duty_cycle_window_ms: Optional[int] = Field(default=None, gt=0)
    hardware: Optional[RadioHardware] = None


class SimulationConfig(BaseModel):
    model_config = LUS_MODEL_CONFIG

    duration_ms: int = Field(gt=0)
    step_ms: int = Field(default=1, ge=1)
    warmup_ms: int = Field(default=0, ge=0)
    seed: Optional[int] = Field(default=None, ge=0)
    epoch_start: Optional[int] = Field(default=None, ge=0)
    # Per-node startup-time jitter: each node delays its on_init by a
    # random offset in [0, node_startup_jitter_ms] from the seeded RNG.
    # Parsed in core/topology/JsonConfig.cpp; see SimController::start.
    node_startup_jitter_ms: int = Field(default=0, ge=0)
    # Per-node clock-drift Gaussian (ppm). Drawn once per node from
    # N(0, sigma) and applied as a constant skew throughout the run.
    clock_drift_ppm_sigma: Optional[float] = Field(default=None, ge=0.0)
    # Scenario-level default beacon period. Some authoring flows surface
    # this at the simulation level; the C++ runtime currently doesn't
    # consume it directly (per-node `config.beacon_period_ms` is the
    # actual source for dv_dual_sf and friends), but we accept it so
    # the webapp doesn't reject scenarios that include it for tooling
    # / metadata purposes.
    beacon_period_ms: Optional[int] = Field(default=None, ge=0)
    radio: RadioConfig
    path_loss: Optional[PathLossModel] = None


class NodeRadioOverride(BaseModel):
    """Per-node nested radio override (subset of RadioConfig). Flat
    sf/bw/cr at the node level take precedence over the values here;
    see core/topology/JsonConfig.cpp:134-142."""
    model_config = LUS_MODEL_CONFIG

    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[float] = Field(default=None, gt=0.0)  # kHz, fractional OK
    cr: Optional[int] = Field(default=None, ge=1)


class NodeConfig(BaseModel):
    model_config = LUS_MODEL_CONFIG

    name: str = Field(min_length=1, max_length=64)
    # script is required for the "lua" engine and unused for "meshroute" (the
    # in-loop C++ FirmwareNode), which is the DEFAULT when `engine` is omitted.
    # Cross-field enforcement lives in lus (core/topology/JsonConfig.cpp), per
    # schema docstring.
    script: Optional[str] = Field(default=None, min_length=1)
    # core/topology/JsonConfig.cpp allowlist. ★ "lua" is DEPRECATED + UNSUPPORTED
    # (2026-07-25 ruling) — kept only as the frozen parity reference, and lus
    # REFUSES it unless the scenario sets simulation.allow_deprecated_lua (or lus
    # is given --allow-deprecated-lua). Still accepted here: the webapp's job is
    # to model the file format, and lus owns the policy.
    engine: Optional[Literal["lua", "meshroute"]] = None
    # Optional explicit short_id assignment; otherwise allocated by lus.
    node_id: Optional[int] = Field(default=None, ge=0, le=255)
    config: dict = Field(default_factory=dict)
    lat: Optional[float] = Field(default=None, ge=-90.0, le=90.0)
    lon: Optional[float] = Field(default=None, ge=-180.0, le=180.0)
    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[float] = Field(default=None, gt=0.0)  # kHz, fractional OK
    cr: Optional[int] = Field(default=None, ge=1)  # see RadioConfig.cr note
    sf_rx_set: Optional[List[int]] = None
    # Per-node radio override (alternative to flat sf/bw/cr).
    radio: Optional[NodeRadioOverride] = None
    # Stochastic per-TX failure probability ([0, 1]).
    tx_fail_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    # Lifecycle scheduling. start_at_ms: node fully off until this
    # sim-time. dies_at_ms: node fully off after this sim-time. Both
    # validated by the C++ runtime against simulation.duration_ms.
    start_at_ms: Optional[int] = Field(default=None, ge=1)
    dies_at_ms: Optional[int] = Field(default=None, ge=1)
    # Authoring-time only — used by the SRTM+ITM topology generator
    # (ITM needs antenna heights to compute path obstruction). Default
    # 1.5 m (handheld); rooftop gateways set per-node to 10+ m. Must
    # be > 0 — ITM's qlrpfl divides by antenna height, so 0 m
    # produces ZeroDivisionError. A buried sensor can use 0.1 m.
    antenna_height_m: Optional[float] = Field(default=None, gt=0.0)
    # Per-node TX power offset (dB). Adds to simulation.path_loss.tx_power_dbm.
    tx_power_offset_db: Optional[float] = None
    # Per-node RX gain offset (dB). Adds to receiver-side path-loss budget.
    rx_offset_db: Optional[float] = None
    # Per-node clock drift in ppm. Constant across the run; if absent
    # and clock_drift_ppm_sigma is set, drawn from the Gaussian.
    clock_drift_ppm: Optional[float] = None
    # Mobility — constant velocity vector for nodes on the move.
    velocity_mps: Optional[float] = Field(default=None, ge=0.0)
    direction_deg: Optional[float] = Field(default=None, ge=0.0, lt=360.0)


class TopologyLink(BaseModel):
    model_config = LUS_MODEL_CONFIG

    from_: str = Field(alias="from")
    to: str
    snr: float
    rssi: Optional[float] = None
    bidir: bool = True
    snr_std_dev: Optional[float] = None
    snr_coherence_ms: Optional[int] = None
    loss: Optional[float] = None


class Topology(BaseModel):
    model_config = LUS_MODEL_CONFIG

    links: List[TopologyLink] = Field(default_factory=list)


class CommandEntry(BaseModel):
    """Either {at_ms, node, command} (dispatch to a node's on_command) or
    {at_ms, lua} (run a Lua snippet — see core/topology/JsonConfig.cpp).
    Validator below enforces that exactly one of the two pairings is used."""
    model_config = LUS_MODEL_CONFIG

    at_ms: int = Field(ge=0)
    node: Optional[str] = None
    command: Optional[str] = None
    lua: Optional[str] = None


class ExpectEntry(BaseModel):
    model_config = LUS_MODEL_CONFIG

    type: str


class LusConfig(BaseModel):
    """Top-level lus scenario config."""
    model_config = LUS_MODEL_CONFIG

    name: Optional[str] = Field(default=None, alias="_name")
    desc: Optional[str] = Field(default=None, alias="_desc")
    simulation: SimulationConfig
    nodes: List[NodeConfig]
    topology: Topology = Field(default_factory=Topology)
    commands: List[CommandEntry] = Field(default_factory=list)
    expect: List[ExpectEntry] = Field(default_factory=list)
