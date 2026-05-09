"""Pydantic schemas for lus scenario JSON.

These describe the *full* lus config schema — the validator may reject
extra fields, but the model itself only knows lus-specific shape.
"""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field, ConfigDict


class PathLossModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

    model: Literal["log_distance"]
    alpha: float = Field(ge=1.0, le=6.0)
    sigma_db: float = Field(ge=0.0, le=20.0)
    ref_distance_m: float = Field(gt=0.0)
    ref_loss_db: float
    noise_floor_db: float
    tx_power_dbm: float
    # Per-node TX/RX gain offsets (Gaussian, drawn once per node).
    # Models hardware variation between units. C++ accepts any double;
    # we constrain to non-negative since these are stddevs.
    node_tx_offset_sigma_db: Optional[float] = Field(default=None, ge=0.0)
    node_rx_offset_sigma_db: Optional[float] = Field(default=None, ge=0.0)
    # Coherence time for the link asymmetry process (ms).
    asymmetry_coherence_ms: Optional[int] = Field(default=None, ge=0)


class RadioHardware(BaseModel):
    """Per-radio hardware turnaround delays (rx<->tx mode switching)."""
    model_config = ConfigDict(extra="forbid")

    rx_to_tx_delay_ms: Optional[int] = Field(default=None, ge=0)
    tx_to_rx_delay_ms: Optional[int] = Field(default=None, ge=0)


class RadioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

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
    model_config = ConfigDict(extra="forbid")

    duration_ms: int = Field(gt=0)
    step_ms: int = Field(default=1, ge=1)
    warmup_ms: int = Field(default=0, ge=0)
    seed: Optional[int] = Field(default=None, ge=0)
    epoch_start: Optional[int] = Field(default=None, ge=0)
    # Per-node startup-time jitter: each node delays its on_init by a
    # random offset in [0, node_startup_jitter_ms] from the seeded RNG.
    # Parsed in core/topology/JsonConfig.cpp; see SimController::start.
    node_startup_jitter_ms: int = Field(default=0, ge=0)
    radio: RadioConfig
    path_loss: Optional[PathLossModel] = None


class NodeRadioOverride(BaseModel):
    """Per-node nested radio override (subset of RadioConfig). Flat
    sf/bw/cr at the node level take precedence over the values here;
    see core/topology/JsonConfig.cpp:134-142."""
    model_config = ConfigDict(extra="forbid")

    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[float] = Field(default=None, gt=0.0)  # kHz, fractional OK
    cr: Optional[int] = Field(default=None, ge=1)


class NodeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=64)
    script: str = Field(min_length=1)
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


class TopologyLink(BaseModel):
    model_config = ConfigDict(extra="forbid")

    from_: str = Field(alias="from")
    to: str
    snr: float
    rssi: float
    bidir: bool = True
    snr_std_dev: Optional[float] = None
    snr_coherence_ms: Optional[int] = None
    loss: Optional[float] = None


class Topology(BaseModel):
    model_config = ConfigDict(extra="forbid")

    links: List[TopologyLink] = Field(default_factory=list)


class CommandEntry(BaseModel):
    """Either {at_ms, node, command} (dispatch to a node's on_command) or
    {at_ms, lua} (run a Lua snippet — see core/topology/JsonConfig.cpp).
    Validator below enforces that exactly one of the two pairings is used."""
    model_config = ConfigDict(extra="forbid")

    at_ms: int = Field(ge=0)
    node: Optional[str] = None
    command: Optional[str] = None
    lua: Optional[str] = None


class ExpectEntry(BaseModel):
    model_config = ConfigDict(extra="allow")  # expect[] vocabulary varies; allow extra keys

    type: str


class LusConfig(BaseModel):
    """Top-level lus scenario config."""
    model_config = ConfigDict(extra="forbid")

    name: Optional[str] = Field(default=None, alias="_name")
    desc: Optional[str] = Field(default=None, alias="_desc")
    simulation: SimulationConfig
    nodes: List[NodeConfig]
    topology: Topology = Field(default_factory=Topology)
    commands: List[CommandEntry] = Field(default_factory=list)
    expect: List[ExpectEntry] = Field(default_factory=list)
