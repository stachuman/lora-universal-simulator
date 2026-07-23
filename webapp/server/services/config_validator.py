"""Config validator for lus scenario JSON — DELIBERATELY A NO-OP (2026-07-22).

The webapp does NO config validation: lus validates fail-loud at load
(JsonConfig::validateConfig + NodeRuntimeWrapper::onInit), so a second schema
here only drifted from it and produced false rejections (e.g. the stale
duty_cycle 0..1 fraction bound vs lus's percent unit). ``validate()`` always
returns ``(None, [])``. Kept as a seam so callers + tests stay unchanged; the
original checks live in git history if per-webapp validation is ever wanted.
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
    # DELIBERATE PASS-THROUGH — the webapp validates nothing; lus validates
    # fail-loud at load. All callers use only the (now always-empty) error list;
    # `parsed` is unused. See the module docstring. (cfg is intentionally ignored.)
    return None, []
