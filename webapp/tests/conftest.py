"""Shared pytest fixtures for the webapp test suite."""

from __future__ import annotations

import sys
from pathlib import Path

# Make `server.*` importable when running pytest from webapp/.
_HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_HERE))


import pytest


@pytest.fixture(autouse=True)
def _reset_settings_singleton():
    """Reset the Settings singleton so env-var changes between tests take effect.
    Without this, the first test's DATA_DIR/ORCHESTRATOR_PATH gets cached for the
    whole pytest run and later monkeypatch.setenv calls have no effect.
    """
    from server.config import Settings
    Settings._instance = None
    yield
    Settings._instance = None


@pytest.fixture
def minimal_lus_config() -> dict:
    """A trivially-valid lus config with one node and no path-loss."""
    return {
        "_name": "test",
        "simulation": {
            "duration_ms": 1000,
            "step_ms": 1,
            "warmup_ms": 0,
            "radio": {"sf": 7, "bw": 250, "cr": 5},
        },
        "nodes": [
            {"name": "alice", "script": "examples/flooder.lua", "config": {}},
        ],
        "topology": {"links": []},
        "commands": [],
        "expect": [],
    }
