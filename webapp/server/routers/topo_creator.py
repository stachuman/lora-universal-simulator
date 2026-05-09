"""Topology Creator router — synchronous log-distance helpers.

POST   /api/topo-creator/preview-snr     NxN SNR matrix for a node list
POST   /api/topo-creator/generate-grid   rectangular grid of nodes
POST   /api/topo-creator/generate-random random nodes inside a bounding box
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from server.services.topo_generator import (
    compute_snr_matrix,
    generate_grid,
    generate_random,
)

router = APIRouter()


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------

class PathLossParams(BaseModel):
    model: str = "log_distance"
    alpha: float = 3.0
    sigma_db: float = 0.0
    ref_distance_m: float = 1.0
    ref_loss_db: float = 40.0
    noise_floor_db: float = -120.0
    tx_power_dbm: float = 14.0
    # Realistic-physics extensions (mirror SimulationConfig.path_loss).
    # compute_snr_matrix uses the deterministic core; these don't affect
    # the preview (they're random per-node/per-link draws), but accepting
    # them here keeps the round-trip lossless when the editor saves and
    # re-loads a topology.
    node_tx_offset_sigma_db: Optional[float] = 0.0
    node_rx_offset_sigma_db: Optional[float] = 0.0
    asymmetry_coherence_ms: Optional[int] = 0
    # Authoring-time only — used by the SRTM+ITM topology generator,
    # not by the runtime path-loss model. Default 868 MHz EU LoRa.
    frequency_mhz: Optional[float] = Field(default=None, gt=0.0)


class PreviewSNRRequest(BaseModel):
    nodes: list[dict] = Field(..., min_length=1)
    path_loss: PathLossParams


class GenerateGridRequest(BaseModel):
    center_lat: float
    center_lon: float
    n_x: int = Field(..., ge=1)
    n_y: int = Field(..., ge=1)
    spacing_m: float = Field(..., gt=0)
    name_prefix: str = "n"


class GenerateRandomRequest(BaseModel):
    bbox: list[float] = Field(..., min_length=4, max_length=4)
    count: int = Field(..., ge=1)
    name_prefix: str = "n"
    seed: Optional[int] = None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("/preview-snr")
async def preview_snr(body: PreviewSNRRequest) -> dict:
    """Return NxN SNR matrix (dB) for the supplied node list."""
    for i, node in enumerate(body.nodes):
        for field in ("lat", "lon"):
            if field not in node:
                raise HTTPException(
                    status_code=422, detail=f"nodes[{i}] missing '{field}'"
                )
    matrix = compute_snr_matrix(body.nodes, body.path_loss.model_dump())
    return {"matrix": matrix}


@router.post("/generate-grid")
async def generate_grid_endpoint(body: GenerateGridRequest) -> dict:
    """Return a rectangular grid of nodes."""
    nodes = generate_grid(
        center_lat=body.center_lat,
        center_lon=body.center_lon,
        n_x=body.n_x,
        n_y=body.n_y,
        spacing_m=body.spacing_m,
        name_prefix=body.name_prefix,
    )
    return {"nodes": nodes}


@router.post("/generate-random")
async def generate_random_endpoint(body: GenerateRandomRequest) -> dict:
    """Return randomly-placed nodes inside the bounding box."""
    bbox = body.bbox
    south, west, north, east = bbox
    if south >= north or west >= east:
        raise HTTPException(
            status_code=422,
            detail="bbox must be [south, west, north, east] with south < north and west < east",
        )
    nodes = generate_random(
        bbox=bbox,
        count=body.count,
        name_prefix=body.name_prefix,
        seed=body.seed,
    )
    return {"nodes": nodes}


# ---------------------------------------------------------------------------
# SRTM + ITM (Longley-Rice) terrain-aware endpoints
# ---------------------------------------------------------------------------

class SrtmItmParams(BaseModel):
    model_config = ConfigDict(extra="forbid")
    climate: int = Field(default=6, ge=1, le=7)
    polarization: int = Field(default=1, ge=0, le=1)
    ground_permittivity: float = 15.0
    ground_conductivity: float = 0.005
    surface_refractivity: float = 314.0
    profile_resolution_m: float = Field(default=90.0, gt=0.0)
    min_snr_db: float = -20.0
    max_links_per_node: int = Field(default=8, ge=1, le=64)


class GenerateSrtmRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nodes: list[dict] = Field(min_length=2)
    path_loss: PathLossParams
    itm: SrtmItmParams = SrtmItmParams()
    bandwidth_hz: float = 62500.0
    noise_figure_db: float = 6.0


@router.post("/generate-srtm")
def generate_srtm(req: GenerateSrtmRequest):
    """Compute terrain-aware per-link SNR/RSSI for a given node list.

    Returns the topology.links payload + summary counts. The caller
    is responsible for stitching the result into a complete scenario
    JSON (the editor / creator UIs do this).
    """
    # Lazy import — keeps the router importable even when srtm /
    # itmlogic aren't installed (the request will then 503).
    try:
        from server.services.topo_srtm import (
            compute_link_matrix,
            get_elevation_data,
        )
    except ImportError as e:
        raise HTTPException(status_code=500,
            detail=f"topo_srtm service unavailable: {e}")

    try:
        srtm_data = get_elevation_data()
    except Exception as e:
        raise HTTPException(status_code=503,
            detail=f"SRTM data fetch failed (offline?): {e}")

    freq_mhz = req.path_loss.frequency_mhz or 868.0
    result = compute_link_matrix(
        nodes=req.nodes,
        freq_mhz=freq_mhz,
        tx_power_dbm=req.path_loss.tx_power_dbm,
        bandwidth_hz=req.bandwidth_hz,
        noise_figure_db=req.noise_figure_db,
        profile_resolution_m=req.itm.profile_resolution_m,
        min_snr_db=req.itm.min_snr_db,
        max_links_per_node=req.itm.max_links_per_node,
        climate=req.itm.climate,
        polarization=req.itm.polarization,
        srtm_data=srtm_data,
    )
    return {
        "links": result["links"],
        "n_pairs_evaluated": result["n_pairs_evaluated"],
        "n_links_kept": result["n_links_kept"],
        "n_srtm_misses": result["n_srtm_misses"],
    }


class RefineWithSrtmRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    scenario: dict
    itm: SrtmItmParams = SrtmItmParams()


@router.post("/refine-with-srtm")
def refine_with_srtm(req: RefineWithSrtmRequest):
    """Recompute topology.links[] from current node lat/lon via SRTM+ITM.
    Preserves everything else in the scenario (commands, expect,
    simulation params, node configs)."""
    try:
        from server.services.topo_srtm import (
            compute_link_matrix,
            get_elevation_data,
        )
    except ImportError as e:
        raise HTTPException(status_code=500,
            detail=f"topo_srtm service unavailable: {e}")

    sc = req.scenario
    nodes_in = sc.get("nodes", [])
    if len(nodes_in) < 2:
        raise HTTPException(status_code=400,
            detail="scenario must have at least 2 nodes")

    sim = sc.get("simulation", {})
    path_loss = sim.get("path_loss", {})
    radio = sim.get("radio", {})
    freq_mhz = path_loss.get("frequency_mhz", 868.0)
    tx_power_dbm = path_loss.get("tx_power_dbm", 14.0)
    bandwidth_hz = float(radio.get("bw", 62500)) * 1000.0 if radio.get("bw") else 62500.0
    # Construct the simplified node list compute_link_matrix expects
    # (name, lat, lon, antenna_height_m).
    nodes = []
    for n in nodes_in:
        if "lat" not in n or "lon" not in n:
            raise HTTPException(status_code=400,
                detail=f"node '{n.get('name', '?')}' missing lat/lon")
        nodes.append({
            "name": n["name"],
            "lat": n["lat"],
            "lon": n["lon"],
            "antenna_height_m": n.get("antenna_height_m", 1.5),
        })

    try:
        srtm_data = get_elevation_data()
    except Exception as e:
        raise HTTPException(status_code=503,
            detail=f"SRTM data fetch failed (offline?): {e}")

    result = compute_link_matrix(
        nodes=nodes,
        freq_mhz=freq_mhz, tx_power_dbm=tx_power_dbm,
        bandwidth_hz=bandwidth_hz, noise_figure_db=6.0,
        profile_resolution_m=req.itm.profile_resolution_m,
        min_snr_db=req.itm.min_snr_db,
        max_links_per_node=req.itm.max_links_per_node,
        climate=req.itm.climate, polarization=req.itm.polarization,
        srtm_data=srtm_data,
    )
    # Replace topology.links[] in place; preserve everything else.
    out = dict(sc)
    out_topology = dict(out.get("topology", {}))
    out_topology["links"] = result["links"]
    out["topology"] = out_topology
    return {
        "scenario": out,
        "n_pairs_evaluated": result["n_pairs_evaluated"],
        "n_links_kept": result["n_links_kept"],
        "n_srtm_misses": result["n_srtm_misses"],
    }
