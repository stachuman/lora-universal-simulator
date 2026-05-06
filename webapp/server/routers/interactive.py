"""Router for interactive lus simulation sessions (WebSocket-based)."""

import json
import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from server.config import validate_safe_id
from server.services.config_validator import validate as validate_lus_config
from server.services.event_index import EventIndex

logger = logging.getLogger(__name__)

router = APIRouter(tags=["interactive"])


class CreateInteractiveRequest(BaseModel):
    config_json: dict


# ------------------------------------------------------------------
# REST endpoints
# ------------------------------------------------------------------


@router.post("/")
async def create_session(body: CreateInteractiveRequest, request: Request):
    """Create a new interactive session."""
    manager = request.app.state.interactive_manager

    parsed, errors = validate_lus_config(body.config_json)
    if errors:
        raise HTTPException(status_code=400, detail={"errors": errors})

    config = body.config_json

    try:
        session = await manager.create_session(config)
    except RuntimeError as e:
        status = 429 if "Maximum" in str(e) else 500
        raise HTTPException(status, str(e))

    return {"id": session.id, "status": session.status}


@router.get("/")
async def list_sessions(request: Request):
    """List all interactive sessions."""
    manager = request.app.state.interactive_manager
    sessions = manager.list_sessions()
    return [
        {
            "id": s.id,
            "status": s.status,
            "created_at": s.created_at,
            "time_ms": s.time_ms,
            "node_count": len(s.nodes),
        }
        for s in sessions
    ]


@router.get("/{sid}")
async def get_session(sid: str, request: Request):
    """Get details of a specific interactive session."""
    manager = request.app.state.interactive_manager
    session = manager.get_session(sid)
    if not session:
        raise HTTPException(404, "Session not found")
    return {
        "id": session.id,
        "status": session.status,
        "created_at": session.created_at,
        "time_ms": session.time_ms,
        "step_ms": session.step_ms,
        "nodes": session.nodes,
        "error": session.error,
    }


@router.get("/{sid}/config")
async def get_session_config(sid: str, request: Request):
    """Return the full simulation config for an interactive session."""
    manager = request.app.state.interactive_manager
    session = manager.get_session(sid)
    if not session:
        raise HTTPException(404, "Session not found")
    return session.config


@router.delete("/{sid}")
async def delete_session(sid: str, request: Request):
    """Close and delete an interactive session."""
    manager = request.app.state.interactive_manager
    ok = await manager.delete_session(sid)
    if not ok:
        raise HTTPException(404, "Session not found")
    return {"deleted": True}


@router.post("/{sid}/export")
async def export_session(sid: str, request: Request):
    """Export session events to simulations directory for visualization."""
    manager = request.app.state.interactive_manager
    sim_id = await manager.export_session(sid)
    if not sim_id:
        raise HTTPException(404, "Session not found or no events")

    # Register the exported sim in sim_manager so it appears in listings
    sim_manager = request.app.state.sim_manager
    sim_manager._scan_existing()

    return {"sim_id": sim_id}


# ------------------------------------------------------------------
# Event query endpoints (mirrors simulations.py for visualize.html)
# ------------------------------------------------------------------


def _get_events_path(sid: str, request: Request):
    """Return (events_path, session) for an interactive session, or raise 404."""
    manager = request.app.state.interactive_manager
    session = manager.get_session(sid)
    if not session:
        raise HTTPException(404, "Session not found")
    events_path = manager._session_dir(sid) / "events.ndjson"
    return events_path, session


@router.get("/{sid}/meta")
async def session_meta(sid: str, request: Request):
    """Return node list, time range, event count for swim-lane visualization."""
    events_path, session = _get_events_path(sid, request)
    if not events_path.exists():
        # No events yet — return skeleton from session state
        nodes = []
        for n in session.nodes:
            name = n.get("name", n) if isinstance(n, dict) else n
            role = n.get("role", "repeater") if isinstance(n, dict) else "repeater"
            nodes.append({"name": name, "role": role})
        return {
            "nodes": nodes,
            "time_min": 0,
            "time_max": session.time_ms,
            "event_count": 0,
            "sim": {},
            "stats": [],
            "repeater_stats": [],
            "summary": {},
        }
    # Flush event file before reading
    manager = request.app.state.interactive_manager
    ef = manager._event_files.get(sid)
    if ef:
        try:
            ef.flush()
        except OSError:
            pass
    index = EventIndex(str(events_path))
    meta = index.get_meta()
    # Override time_max with session's current time (events file may lag)
    if session.time_ms > meta["time_max"]:
        meta["time_max"] = session.time_ms
    return meta


@router.get("/{sid}/events")
async def session_events(
    sid: str,
    request: Request,
    from_ms: int = Query(alias="from", default=0),
    to_ms: int = Query(alias="to", default=2**31),
):
    """Return events in a time window [from, to] (milliseconds)."""
    events_path, session = _get_events_path(sid, request)
    if not events_path.exists():
        return {"events": [], "count": 0}
    manager = request.app.state.interactive_manager
    ef = manager._event_files.get(sid)
    if ef:
        try:
            ef.flush()
        except OSError:
            pass
    index = EventIndex(str(events_path))
    events = index.query_time_range(from_ms, to_ms)
    return {"events": events, "count": len(events)}


@router.get("/{sid}/density")
async def session_density(
    sid: str,
    request: Request,
    from_ms: int = Query(alias="from", default=0),
    to_ms: int = Query(alias="to", default=2**31),
    bucket_ms: int = Query(alias="bucket", default=1000),
):
    """Return per-node event density heatmap in time buckets."""
    events_path, session = _get_events_path(sid, request)
    if not events_path.exists():
        return {"buckets": [], "nodes": []}
    manager = request.app.state.interactive_manager
    ef = manager._event_files.get(sid)
    if ef:
        try:
            ef.flush()
        except OSError:
            pass
    index = EventIndex(str(events_path))
    return index.density(from_ms, to_ms, bucket_ms)


# ------------------------------------------------------------------
# WebSocket endpoint
# ------------------------------------------------------------------

# lus REPL commands use colon-prefix (`:step`, `:nodes`, etc.)
# The WS API accepts clean JSON command names and translates to lus wire format.
# Commands that produce multi-line non-parseable output are blocked.
_BLOCKED_CMDS = {"help"}  # Multi-line, not useful over WS


def _translate_command(msg: dict) -> Optional[str]:
    """Translate a WS command message to a raw lus REPL command string.

    lus REPL uses colon-prefix: ``:step``, ``:nodes``, ``:quit``, etc.
    Returns None for blocked or unrecognised commands.
    """
    cmd = msg.get("cmd", "")

    if cmd in _BLOCKED_CMDS:
        return None

    if cmd == "step":
        ms = msg.get("ms", "")
        return f":step {ms}" if ms else ":step"
    elif cmd == "run":
        ms = msg.get("ms", "")
        return f":run {ms}" if ms else ":run"
    elif cmd == "next":
        return ":next"
    elif cmd == "nodes":
        return ":nodes"
    elif cmd == "time":
        return ":time"
    elif cmd == "status":
        # lus has no :status — map to :time as the closest equivalent
        return ":time"
    elif cmd == "cmd":
        node = msg.get("node", "")
        command = msg.get("command", "")
        if not node or not command:
            return None
        return f":cmd {node} {command}"
    elif cmd == "events":
        n = msg.get("n", 10)
        return f":events {n}"
    elif cmd == "lua":
        code = msg.get("code", "")
        return f":lua {code}" if code else None
    elif cmd == "quit":
        return ":quit"
    else:
        return None


@router.websocket("/{sid}/ws")
async def websocket_endpoint(websocket: WebSocket, sid: str):
    """WebSocket endpoint for interactive session control."""
    manager = websocket.app.state.interactive_manager
    session = manager.get_session(sid)

    if not session:
        await websocket.close(code=4004, reason="Session not found")
        return

    await websocket.accept()
    await manager.register_ws(sid, websocket)

    # Send current state on connect
    if session.status == "starting":
        await websocket.send_json({
            "type": "starting",
            "message": "Initializing lus (waiting for :nodes probe)...",
        })
    elif session.status == "ready":
        await websocket.send_json({
            "type": "ready",
            "nodes": session.nodes,
            "time_ms": session.time_ms,
            "step_ms": session.step_ms,
        })
    elif session.status == "closed":
        await websocket.send_json({
            "type": "closed",
            "reason": session.error or "already_closed",
        })

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_json({
                    "type": "error",
                    "message": "Invalid JSON",
                })
                continue

            cmd_name = msg.get("cmd", "")

            if cmd_name in _BLOCKED_CMDS:
                await websocket.send_json({
                    "type": "error",
                    "message": f"Command '{cmd_name}' is not supported via WebSocket",
                })
                continue

            raw_cmd = _translate_command(msg)
            if raw_cmd is None:
                await websocket.send_json({
                    "type": "error",
                    "message": f"Unknown or invalid command: {cmd_name}",
                })
                continue

            # Handle quit specially
            if cmd_name == "quit":
                await manager.close_session(sid, reason="user_quit")
                break

            # Send command and wait for response
            response = await manager.send_command(sid, raw_cmd)
            await websocket.send_json({
                "type": "response",
                "cmd": cmd_name,
                "data": response,
            })

    except WebSocketDisconnect:
        pass
    except Exception:
        logger.exception("WebSocket error for session %s", sid)
    finally:
        await manager.unregister_ws(sid, websocket)
