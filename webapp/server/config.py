"""Settings singleton sourced from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar


@dataclass(frozen=True)
class Settings:
    DATA_DIR: Path
    ORCHESTRATOR_PATH: Path
    MAX_CONCURRENT_SIMS: int
    MAX_INTERACTIVE_SESSIONS: int
    INTERACTIVE_IDLE_TIMEOUT_S: int

    _instance: ClassVar["Settings | None"] = None

    @classmethod
    def get(cls) -> "Settings":
        if cls._instance is None:
            here = Path(__file__).resolve().parent.parent  # .../webapp
            data_dir = Path(os.environ.get("DATA_DIR", here / "data")).resolve()
            orch = Path(os.environ.get(
                "ORCHESTRATOR_PATH",
                here.parent / "build" / "orchestrator" / "lus",
            )).resolve()
            cls._instance = cls(
                DATA_DIR=data_dir,
                ORCHESTRATOR_PATH=orch,
                MAX_CONCURRENT_SIMS=int(os.environ.get("MAX_CONCURRENT_SIMS", os.cpu_count() or 4)),
                MAX_INTERACTIVE_SESSIONS=int(os.environ.get("MAX_INTERACTIVE_SESSIONS", 4)),
                INTERACTIVE_IDLE_TIMEOUT_S=int(os.environ.get("INTERACTIVE_IDLE_TIMEOUT_S", 300)),
            )
        return cls._instance


def validate_safe_id(value: str, label: str = "id") -> str:
    """Reject path-traversal / unsafe characters in user-supplied identifiers."""
    if not value or len(value) > 64:
        raise ValueError(f"{label} must be 1..64 characters")
    if not all(c.isalnum() or c in "-_" for c in value):
        raise ValueError(f"{label} may only contain [A-Za-z0-9_-]")
    return value
