"""Simulations router -- full CRUD + event query endpoints for simulations.

Connects the frontend to SimManager (subprocess lifecycle) and EventIndex
(event queries over NDJSON output files).
"""

import json
import logging
import os

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel

from server.services.config_validator import validate as validate_lus_config
from server.services.event_index import EventIndex, EventIndexCache
from server.services.sim_manager import SimManager

logger = logging.getLogger(__name__)

router = APIRouter(tags=["sims"])


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class CreateSimRequest(BaseModel):
    config_json: dict


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_sim_or_404(sim_id: str, request: Request):
    """Return the SimRecord for *sim_id*, or raise 404."""
    sim_manager: SimManager = request.app.state.sim_manager
    sim = sim_manager.get_sim(sim_id)
    if sim is None:
        raise HTTPException(status_code=404, detail="Simulation not found")
    return sim


def _events_etag(events_path) -> str:
    """Compute a lightweight ETag from file mtime and size."""
    st = os.stat(str(events_path))
    return f'"{st.st_mtime_ns:x}-{st.st_size:x}"'


def _check_not_modified(request: Request, etag: str) -> bool:
    """Return True if the client's If-None-Match header matches our ETag."""
    client_etag = request.headers.get("if-none-match", "")
    return client_etag == etag


def _get_index(sim_id: str, request: Request) -> EventIndex:
    """Load (or retrieve from cache) the EventIndex for a completed sim.

    Raises 404 if the simulation doesn't exist, or 409 if it hasn't
    completed yet (no events file).
    """
    sim = _get_sim_or_404(sim_id, request)
    sim_manager: SimManager = request.app.state.sim_manager
    event_cache: EventIndexCache = request.app.state.event_cache

    events_path = sim_manager.get_events_path(sim_id)
    if events_path is None:
        if sim.status in ("pending", "running"):
            raise HTTPException(
                status_code=409,
                detail=f"Simulation is still {sim.status}; events not available yet",
            )
        raise HTTPException(
            status_code=404, detail="Events file not found for this simulation"
        )

    return event_cache.get(sim_id, str(events_path))


def _cached_json_response(request: Request, sim_id: str, data) -> JSONResponse:
    """Return a JSONResponse with ETag / 304 Not Modified support.

    For completed simulations, event data never changes, so aggressive
    caching is safe.
    """
    sim_manager: SimManager = request.app.state.sim_manager
    events_path = sim_manager.get_events_path(sim_id)
    if events_path:
        etag = _events_etag(events_path)
        if _check_not_modified(request, etag):
            return Response(status_code=304, headers={"ETag": etag})
        return JSONResponse(content=data,
                            headers={"ETag": etag, "Cache-Control": "private, max-age=3600"})
    return JSONResponse(content=data)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("", include_in_schema=True)
async def create_sim(body: CreateSimRequest, request: Request):
    """Start a new simulation from a config JSON dict."""
    parsed, errors = validate_lus_config(body.config_json)
    if errors:
        raise HTTPException(status_code=400, detail={"errors": errors})

    sim_manager: SimManager = request.app.state.sim_manager
    sim_id = await sim_manager.create_sim(body.config_json)
    return {"id": sim_id, "status": "pending"}


@router.get("", include_in_schema=True)
async def list_sims(request: Request):
    """List all simulations, newest first."""
    sim_manager: SimManager = request.app.state.sim_manager
    sims = sim_manager.list_sims()
    result = []
    for s in sims:
        node_count = len(s.config.get("nodes", []))
        result.append(
            {
                "id": s.id,
                "status": s.status,
                "created_at": s.created_at,
                "completed_at": s.completed_at,
                "node_count": node_count,
                "error": s.error,
            }
        )
    return result


@router.get("/{sim_id}")
async def get_sim(sim_id: str, request: Request):
    """Get simulation status and config summary."""
    sim = _get_sim_or_404(sim_id, request)
    config = sim.config
    node_count = len(config.get("nodes", []))
    duration_ms = config.get("simulation", {}).get("duration_ms")
    return {
        "id": sim.id,
        "status": sim.status,
        "created_at": sim.created_at,
        "completed_at": sim.completed_at,
        "error": sim.error,
        "progress": sim.progress_pct,
        "config_summary": {
            "node_count": node_count,
            "duration_ms": duration_ms,
        },
    }


@router.delete("/{sim_id}")
async def delete_sim(sim_id: str, request: Request):
    """Cancel and delete a simulation and all its data."""
    sim_manager: SimManager = request.app.state.sim_manager
    event_cache: EventIndexCache = request.app.state.event_cache

    existed = await sim_manager.delete_sim(sim_id)
    if not existed:
        raise HTTPException(status_code=404, detail="Simulation not found")

    event_cache.evict(sim_id)
    return {"id": sim_id, "deleted": True}


@router.get("/{sim_id}/meta")
async def sim_meta(sim_id: str, request: Request):
    """Return node list, time range, event count, and stats."""
    index = _get_index(sim_id, request)
    return _cached_json_response(request, sim_id, index.get_meta())


@router.get("/{sim_id}/events")
async def sim_events(
    sim_id: str,
    request: Request,
    from_ms: int = Query(alias="from", default=0),
    to_ms: int = Query(alias="to", default=2**31),
    max_events: int = Query(alias="max", default=20000),
):
    """Return events in a time window [from, to] (milliseconds)."""
    index = _get_index(sim_id, request)
    events = index.query_time_range(from_ms, to_ms, max_events)
    return _cached_json_response(request, sim_id,
                                 {"events": events, "count": len(events)})


@router.get("/{sim_id}/density")
async def sim_density(
    sim_id: str,
    request: Request,
    from_ms: int = Query(alias="from", default=0),
    to_ms: int = Query(alias="to", default=2**31),
    bucket_ms: int = Query(alias="bucket", default=1000),
):
    """Return per-node event density heatmap in time buckets."""
    index = _get_index(sim_id, request)
    return _cached_json_response(request, sim_id,
                                 index.density(from_ms, to_ms, bucket_ms))


@router.get("/{sim_id}/node_events/{node}")
async def sim_node_events(
    sim_id: str,
    node: str,
    request: Request,
    from_ms: int = Query(alias="from", default=0),
    to_ms: int = Query(alias="to", default=2**31),
):
    """Return events involving a specific node in a time range."""
    index = _get_index(sim_id, request)
    events = index.query_node_range(node, from_ms, to_ms)
    return {"node": node, "events": events}


@router.get("/{sim_id}/progress")
async def sim_progress(sim_id: str, request: Request):
    """SSE endpoint streaming simulation progress updates."""
    sim_manager: SimManager = request.app.state.sim_manager
    sim = sim_manager.get_sim(sim_id)
    if not sim:
        raise HTTPException(status_code=404, detail="Simulation not found")

    q = sim_manager.subscribe_progress(sim_id)

    async def event_stream():
        try:
            while True:
                data = await q.get()
                if data is None:
                    yield f"data: {json.dumps({'done': True})}\n\n"
                    break
                yield f"data: {json.dumps(data)}\n\n"
        finally:
            sim_manager.unsubscribe_progress(sim_id, q)

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
