"""Topology Creator router — synchronous log-distance helpers.

POST   /api/topo-creator/preview-snr     NxN SNR matrix for a node list
POST   /api/topo-creator/generate-grid   rectangular grid of nodes
POST   /api/topo-creator/generate-random random nodes inside a bounding box
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

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
