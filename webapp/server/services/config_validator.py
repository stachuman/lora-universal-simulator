"""Config validator for lus scenario JSON.

Returns ``(parsed_config, [])`` on success, ``(None, [errors])`` on failure.
Rejects MeshCore-only fields with explicit messages so users porting from
MeshCore configs get clear guidance.
"""

from __future__ import annotations

from typing import Optional

from pydantic import ValidationError

from server.models.schemas import LusConfig

# Fields that signal a MeshCore config was passed by mistake.
_MESHCORE_TOP_LEVEL = {"firmware", "_requires_plugins"}
_MESHCORE_SIMULATION = {"firmware", "hot_start"}
_MESHCORE_NODE = {"firmware", "role"}


def validate(cfg: dict) -> tuple[Optional[LusConfig], list[str]]:
    errors: list[str] = []

    # Pre-flight: catch MeshCore fields with friendly messages.
    for k in _MESHCORE_TOP_LEVEL:
        if k in cfg:
            errors.append(
                f"top-level field {k!r} is MeshCore-specific and not accepted by lus"
            )

    sim = cfg.get("simulation") or {}
    if isinstance(sim, dict):
        for k in _MESHCORE_SIMULATION:
            if k in sim:
                errors.append(
                    f"simulation.{k!r} is MeshCore-specific and not accepted by lus"
                )

    nodes = cfg.get("nodes") or []
    if isinstance(nodes, list):
        for i, node in enumerate(nodes):
            if not isinstance(node, dict):
                continue
            for k in _MESHCORE_NODE:
                if k in node:
                    errors.append(
                        f"nodes[{i}].{k!r} is MeshCore-specific; use 'script' + 'config' instead"
                    )

    if errors:
        return None, errors

    # Pydantic structural validation.
    try:
        parsed = LusConfig.model_validate(cfg)
    except ValidationError as exc:
        return None, [f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in exc.errors()]

    return parsed, []
