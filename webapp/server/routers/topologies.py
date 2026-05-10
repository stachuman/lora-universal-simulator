"""Topology CRUD router.

POST   /api/topologies           save topology; returns {id}
GET    /api/topologies           list summaries
GET    /api/topologies/{id}      full topology JSON
PUT    /api/topologies/{id}      replace
DELETE /api/topologies/{id}
"""

from __future__ import annotations

import time
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from server.config import Settings, validate_safe_id
from server.services.topo_tools import (
    delete_topology,
    list_topologies,
    load_topology,
    save_topology,
    validate_topology_dict,
)

router = APIRouter()


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class TopologyIn(BaseModel):
    """Body for POST and PUT.  id / created_at are ignored on input."""
    name: str
    path_loss: dict = Field(default_factory=dict)
    nodes: list[dict] = Field(default_factory=list)
    # Optional: per-link snr/rssi/snr_std_dev/bidir computed by the
    # SRTM+ITM endpoint. Round-tripped verbatim so a saved topology
    # remembers its terrain-aware link quality without re-running
    # the (slow) ITM compute on every load.
    links: list[dict] = Field(default_factory=list)


class TopologySummary(BaseModel):
    id: str
    name: str
    created_at: float
    node_count: int
    has_path_loss: bool


class TopologyCreatedResponse(BaseModel):
    id: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _settings():
    return Settings.get()


def _require_topology(topo_id: str) -> dict:
    validate_safe_id(topo_id, "topology ID")
    topo = load_topology(_settings().DATA_DIR, topo_id)
    if topo is None:
        raise HTTPException(status_code=404, detail=f"Topology '{topo_id}' not found")
    return topo


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("", status_code=201)
async def create_topology(body: TopologyIn) -> TopologyCreatedResponse:
    topo = {
        "name": body.name,
        "created_at": time.time(),
        "path_loss": body.path_loss,
        "nodes": body.nodes,
        "links": body.links,
    }
    try:
        validate_topology_dict(topo)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    topo_id = uuid.uuid4().hex[:12]
    topo["id"] = topo_id
    save_topology(_settings().DATA_DIR, topo)
    return TopologyCreatedResponse(id=topo_id)


@router.get("")
async def list_topologies_endpoint() -> list[TopologySummary]:
    summaries = list_topologies(_settings().DATA_DIR)
    return [TopologySummary(**s) for s in summaries]


@router.get("/{topo_id}")
async def get_topology(topo_id: str) -> dict:
    return _require_topology(topo_id)


@router.put("/{topo_id}")
async def update_topology(topo_id: str, body: TopologyIn) -> dict:
    existing = _require_topology(topo_id)

    updated = dict(existing)
    updated["name"] = body.name
    updated["path_loss"] = body.path_loss
    updated["nodes"] = body.nodes
    updated["links"] = body.links

    try:
        validate_topology_dict(updated)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    save_topology(_settings().DATA_DIR, updated)
    return updated


@router.delete("/{topo_id}")
async def delete_topology_endpoint(topo_id: str) -> dict:
    validate_safe_id(topo_id, "topology ID")
    existed = delete_topology(_settings().DATA_DIR, topo_id)
    if not existed:
        raise HTTPException(status_code=404, detail=f"Topology '{topo_id}' not found")
    return {"id": topo_id, "deleted": True}
