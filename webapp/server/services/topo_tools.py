"""Topology tools — file I/O and helpers for the lus topology format.

The lus topology format is a "partial scenario":
  {id, name, created_at, path_loss, nodes: [{name, lat, lon}]}

No ITM, no firmware/role fields, no MeshCore packet decoders.
"""

from __future__ import annotations

import json
import shutil
import time
import uuid
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

def make_node_name(prefix: str, idx: int) -> str:
    """Return a zero-padded node name, e.g. make_node_name('n', 3) -> 'n04'."""
    return f"{prefix}{idx + 1:02d}"


# ---------------------------------------------------------------------------
# Topology directory helpers
# ---------------------------------------------------------------------------

def _topo_dir(data_dir: Path, topo_id: str) -> Path:
    return data_dir / "topologies" / topo_id


def _topo_file(data_dir: Path, topo_id: str) -> Path:
    return _topo_dir(data_dir, topo_id) / "topology.json"


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_topology_dict(data: dict) -> None:
    """Raise ValueError if *data* is not a valid lus topology.

    Required: name (str), nodes (list with name/lat/lon).
    Rejected: firmware, role fields (MeshCore artefacts).
    """
    if not isinstance(data.get("name"), str) or not data["name"].strip():
        raise ValueError("topology must have a non-empty 'name' string")

    nodes = data.get("nodes")
    if not isinstance(nodes, list):
        raise ValueError("topology must have a 'nodes' list")

    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise ValueError(f"nodes[{i}] must be an object")
        for required in ("name", "lat", "lon"):
            if required not in node:
                raise ValueError(f"nodes[{i}] missing required field '{required}'")
        for forbidden in ("firmware", "role", "plugin"):
            if forbidden in node:
                raise ValueError(
                    f"nodes[{i}] contains MeshCore-specific field '{forbidden}'; "
                    "remove it before saving a lus topology"
                )


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

def save_topology(data_dir: Path, topo: dict) -> str:
    """Persist *topo* to disk.  Generates id/created_at if absent.  Returns id."""
    if "id" not in topo or not topo["id"]:
        topo = dict(topo)
        topo["id"] = uuid.uuid4().hex[:12]
    if "created_at" not in topo:
        topo = dict(topo)
        topo["created_at"] = time.time()

    topo_id = topo["id"]
    path = _topo_file(data_dir, topo_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(topo, indent=2), encoding="utf-8")
    return topo_id


def load_topology(data_dir: Path, topo_id: str) -> dict | None:
    """Return parsed topology dict, or None if not found."""
    path = _topo_file(data_dir, topo_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def list_topologies(data_dir: Path) -> list[dict]:
    """Return summary dicts for all stored topologies, newest first."""
    topo_root = data_dir / "topologies"
    if not topo_root.exists():
        return []

    summaries: list[dict] = []
    for entry in topo_root.iterdir():
        if not entry.is_dir():
            continue
        topo_file = entry / "topology.json"
        if not topo_file.exists():
            continue
        try:
            topo = json.loads(topo_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        summaries.append({
            "id": topo.get("id", entry.name),
            "name": topo.get("name", ""),
            "created_at": topo.get("created_at", 0.0),
            "node_count": len(topo.get("nodes", [])),
            "has_path_loss": "path_loss" in topo,
        })

    summaries.sort(key=lambda s: s["created_at"], reverse=True)
    return summaries


def delete_topology(data_dir: Path, topo_id: str) -> bool:
    """Delete a topology directory.  Returns True if it existed."""
    topo_dir = _topo_dir(data_dir, topo_id)
    if not topo_dir.exists():
        return False
    shutil.rmtree(topo_dir)
    return True
