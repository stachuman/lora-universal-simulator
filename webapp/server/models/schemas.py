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


class RadioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sf: int = Field(ge=5, le=12)
    bw: int  # kHz
    cr: int = Field(ge=5, le=8)
    cad_miss_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    cad_reliable_snr: Optional[float] = None
    cad_marginal_snr: Optional[float] = None
    rx_to_tx_delay_ms: Optional[int] = Field(default=None, ge=0)
    tx_to_rx_delay_ms: Optional[int] = Field(default=None, ge=0)


class SimulationConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    duration_ms: int = Field(gt=0)
    step_ms: int = Field(default=1)
    warmup_ms: int = Field(default=0, ge=0)
    radio: RadioConfig
    path_loss: Optional[PathLossModel] = None


class NodeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=64)
    script: str = Field(min_length=1)
    config: dict = Field(default_factory=dict)
    lat: Optional[float] = Field(default=None, ge=-90.0, le=90.0)
    lon: Optional[float] = Field(default=None, ge=-180.0, le=180.0)
    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[int] = None  # kHz
    cr: Optional[int] = Field(default=None, ge=5, le=8)
    sf_rx_set: Optional[List[int]] = None


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
    model_config = ConfigDict(extra="forbid")

    at_ms: int = Field(ge=0)
    node: str
    command: str


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
