# Webapp Adaptation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `~/meshcore_real_sim/webapp/` into `lora-universal-simulator/webapp/`, adapt to lus's event vocabulary and config schema, drop MeshCore-specific machinery (firmware/role/plugins/ITM), and stop short of topology authoring (deferred to next phase).

**Architecture:** FastAPI backend + vanilla-JS frontend (no build step). Backend spawns `build/orchestrator/lus` as a subprocess and pipes stdout NDJSON to the browser via SSE (live) or via indexed slicing (replay). Six pages: `index`, `simulations`, `simulation`, `visualize`, `map_live`, `interactive`. No database — all state under `webapp/data/`.

**Tech Stack:** Python 3.10+, FastAPI, uvicorn, pydantic v2; vanilla JS / HTML / CSS frontend (Leaflet only on map_live for the base map).

---

## File Structure

To create:

```
webapp/
├── ARCHITECTURE.md                              # high-level doc
├── docker-compose.yml                           # docker workflow
├── Dockerfile                                   # docker workflow
├── requirements.txt                             # FastAPI, uvicorn, pydantic, aiofiles, python-multipart
├── run.sh                                       # uvicorn helper
├── data/                                        # gitignored (sims, interactive sessions)
├── server/
│   ├── __init__.py
│   ├── main.py                                  # FastAPI app, lifespan, static mount
│   ├── config.py                                # Settings (env vars)
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── simulations.py                       # /api/sims/*
│   │   └── interactive.py                       # /api/interactive/*
│   ├── services/
│   │   ├── __init__.py
│   │   ├── sim_manager.py                       # subprocess + SSE for lus
│   │   ├── event_index.py                       # NDJSON time-range slicing
│   │   ├── interactive_manager.py               # WebSocket + lus -i
│   │   └── config_validator.py                  # lus schema validator
│   └── models/
│       ├── __init__.py
│       └── schemas.py                           # pydantic models for lus configs
├── static/
│   ├── css/common.css                           # shared styles (port verbatim)
│   ├── js/api.js                                # shared API helper (port verbatim)
│   ├── index.html                               # landing
│   ├── simulations.html                         # list of past runs
│   ├── simulation.html                          # single-run launcher + status
│   ├── visualize.html                           # swim-lane replay
│   ├── map_live.html                            # live SSE map
│   └── interactive.html                         # WebSocket REPL
└── tests/
    ├── __init__.py
    ├── conftest.py
    ├── test_config_validator.py
    ├── test_sim_manager.py
    ├── test_event_index.py
    └── test_smoke_e2e.py
```

To modify:
- `.gitignore` — add `webapp/data/`, `webapp/__pycache__/`, `webapp/server/__pycache__/`, etc.
- `README.md` — add a "Webapp" section with run instructions

The frontend HTML files are large (200–2200 lines). The engineer ports each by **copying the source** from `~/meshcore_real_sim/webapp/static/<file>` and applying mechanical search-and-replace + targeted DOM edits. The plan's HTML tasks list each search-and-replace pattern explicitly.

---

## Conventions used throughout this plan

- All shell commands assume cwd `/home/staszek/lora-universal-simulator`. Webapp commands are issued from `webapp/` where noted.
- Source webapp is at `/home/staszek/meshcore_real_sim/webapp/` — port verbatim by default, then adapt.
- The simulator binary is at `build/orchestrator/lus`. The webapp's `ORCHESTRATOR_PATH` env var points to it (default in `config.py`).
- Python target: 3.10+ (FastAPI's modern asyncio APIs).
- Tests: `cd webapp && python -m pytest -xvs tests/<name>.py` (or `tests/` for all).
- Run dev server: `cd webapp && bash run.sh` (uvicorn on port 8000).

---

## Task 1: Webapp skeleton + FastAPI bootstrap

**Files:**
- Create: `webapp/requirements.txt`
- Create: `webapp/run.sh`
- Create: `webapp/server/__init__.py`, `webapp/server/main.py`, `webapp/server/config.py`
- Create: `webapp/static/index.html` (placeholder)
- Modify: `.gitignore`

This task lays the dirt-simple FastAPI app — no routers, no static logic — just enough that `bash webapp/run.sh` starts a uvicorn server, serves a static `index.html`, and exits cleanly on Ctrl-C.

- [ ] **Step 1: Create directory tree**

```bash
mkdir -p webapp/server/routers webapp/server/services webapp/server/models \
         webapp/static/css webapp/static/js webapp/data webapp/tests
```

- [ ] **Step 2: Write `webapp/requirements.txt`**

```
fastapi>=0.100,<1.0
pydantic>=2.0,<3.0
uvicorn[standard]>=0.20,<1.0
python-multipart>=0.0.5,<1.0
aiofiles>=23.0,<25.0
pytest>=7.0,<9.0
httpx>=0.24,<1.0
```

- [ ] **Step 3: Write `webapp/run.sh`**

```bash
#!/usr/bin/bash
cd "$(dirname "$0")"
exec uvicorn server.main:app --port 8000 --host 0.0.0.0 --reload
```

```bash
chmod +x webapp/run.sh
```

- [ ] **Step 4: Write `webapp/server/config.py`**

```python
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
```

- [ ] **Step 5: Write `webapp/server/main.py`**

```python
"""FastAPI app entry point.

Mounts static files, registers routers (added in later tasks), and creates
the data directories on startup.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from server.config import Settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings.get()
    for sub in ("simulations", "interactive"):
        (settings.DATA_DIR / sub).mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="lora-universal-simulator", lifespan=lifespan)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# Static mount — served from webapp/static/.
import pathlib
_static = pathlib.Path(__file__).resolve().parent.parent / "static"
app.mount("/static", StaticFiles(directory=_static), name="static")


@app.get("/", include_in_schema=False)
def root():
    return FileResponse(_static / "index.html")


@app.get("/health", include_in_schema=False)
def health():
    return {"status": "ok"}
```

- [ ] **Step 6: Write `webapp/server/__init__.py` (empty)**

```bash
touch webapp/server/__init__.py
touch webapp/server/routers/__init__.py
touch webapp/server/services/__init__.py
touch webapp/server/models/__init__.py
```

- [ ] **Step 7: Write `webapp/static/index.html` (placeholder)**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>lora-universal-simulator</title>
<style>body{font-family:sans-serif;max-width:600px;margin:40px auto;padding:0 20px;}</style>
</head>
<body>
<h1>lora-universal-simulator</h1>
<p>Webapp is up. Routers and pages will be added in subsequent tasks.</p>
<p><a href="/health">/health</a></p>
</body>
</html>
```

- [ ] **Step 8: Update `.gitignore`**

Read current `.gitignore`:
```bash
cat .gitignore
```

Add the following lines (append; don't replace):
```
webapp/data/
webapp/__pycache__/
webapp/server/__pycache__/
webapp/server/routers/__pycache__/
webapp/server/services/__pycache__/
webapp/server/models/__pycache__/
webapp/tests/__pycache__/
.pytest_cache/
```

- [ ] **Step 9: Install dependencies and start server**

```bash
cd webapp && pip install -r requirements.txt
```

Expected: pip installs FastAPI etc. without error.

```bash
cd webapp && bash run.sh
```

In another terminal:
```bash
curl -s http://localhost:8000/health
curl -s http://localhost:8000/ | head -3
```

Expected: `{"status":"ok"}` and the placeholder HTML's first lines.

Stop the server with Ctrl-C.

- [ ] **Step 10: Commit**

```bash
git add webapp/ .gitignore
git commit -m "feat(webapp): FastAPI skeleton — placeholder index, /health, lifespan"
```

---

## Task 2: Config validator + pydantic schemas

**Files:**
- Create: `webapp/server/models/schemas.py`
- Create: `webapp/server/services/config_validator.py`
- Create: `webapp/tests/conftest.py`
- Create: `webapp/tests/test_config_validator.py`

This is a from-scratch rewrite (the meshcore_real_sim version is firmware/role-aware). The validator parses a config dict and returns either the parsed pydantic model or a list of explicit error messages. MeshCore-only fields produce a single specific error each.

- [ ] **Step 1: Write `webapp/server/models/schemas.py`**

```python
"""Pydantic schemas for lus scenario JSON.

These describe the *full* lus config schema — the validator may reject
extra fields, but the model itself only knows lus-specific shape.
"""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field, ConfigDict


class PathLossModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

    model: Literal["log_distance"]
    alpha: float = Field(ge=1.0, le=6.0)
    sigma_db: float = Field(ge=0.0, le=20.0)
    ref_distance_m: float = Field(gt=0.0)
    ref_loss_db: float
    noise_floor_db: float
    tx_power_dbm: float


class RadioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sf: int = Field(ge=5, le=12)
    bw: int  # kHz
    cr: int = Field(ge=5, le=8)
    cad_miss_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    cad_reliable_snr: Optional[float] = None
    cad_marginal_snr: Optional[float] = None
    rx_to_tx_delay_ms: Optional[int] = Field(default=None, ge=0)
    tx_to_rx_delay_ms: Optional[int] = Field(default=None, ge=0)


class SimulationConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    duration_ms: int = Field(gt=0)
    step_ms: int = Field(default=1)
    warmup_ms: int = Field(default=0, ge=0)
    radio: RadioConfig
    path_loss: Optional[PathLossModel] = None


class NodeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=64)
    script: str = Field(min_length=1)
    config: dict = Field(default_factory=dict)
    lat: Optional[float] = Field(default=None, ge=-90.0, le=90.0)
    lon: Optional[float] = Field(default=None, ge=-180.0, le=180.0)
    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[int] = None  # kHz
    cr: Optional[int] = Field(default=None, ge=5, le=8)
    sf_rx_set: Optional[List[int]] = None


class TopologyLink(BaseModel):
    model_config = ConfigDict(extra="forbid")

    from_: str = Field(alias="from")
    to: str
    snr: float
    rssi: float
    bidir: bool = True
    snr_std_dev: Optional[float] = None
    snr_coherence_ms: Optional[int] = None
    loss: Optional[float] = None


class Topology(BaseModel):
    model_config = ConfigDict(extra="forbid")

    links: List[TopologyLink] = Field(default_factory=list)


class CommandEntry(BaseModel):
    model_config = ConfigDict(extra="forbid")

    at_ms: int = Field(ge=0)
    node: str
    command: str


class ExpectEntry(BaseModel):
    model_config = ConfigDict(extra="allow")  # expect[] vocabulary varies; allow extra keys

    type: str


class LusConfig(BaseModel):
    """Top-level lus scenario config."""
    model_config = ConfigDict(extra="forbid")

    name: Optional[str] = Field(default=None, alias="_name")
    desc: Optional[str] = Field(default=None, alias="_desc")
    simulation: SimulationConfig
    nodes: List[NodeConfig]
    topology: Topology = Field(default_factory=Topology)
    commands: List[CommandEntry] = Field(default_factory=list)
    expect: List[ExpectEntry] = Field(default_factory=list)
```

- [ ] **Step 2: Write `webapp/server/services/config_validator.py`**

```python
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
```

- [ ] **Step 3: Write `webapp/tests/conftest.py`**

```python
"""Shared pytest fixtures for the webapp test suite."""

from __future__ import annotations

import sys
from pathlib import Path

# Make `server.*` importable when running pytest from webapp/.
_HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_HERE))


import pytest


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
```

- [ ] **Step 4: Write `webapp/tests/test_config_validator.py`**

```python
"""Unit tests for config validator."""

from __future__ import annotations

from server.services.config_validator import validate


def test_minimal_valid(minimal_lus_config):
    parsed, errors = validate(minimal_lus_config)
    assert errors == []
    assert parsed is not None
    assert parsed.simulation.duration_ms == 1000
    assert parsed.nodes[0].name == "alice"


def test_meshcore_top_level_firmware_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["firmware"] = {"default": "x"}
    parsed, errors = validate(cfg)
    assert parsed is None
    assert any("firmware" in e and "MeshCore-specific" in e for e in errors)


def test_meshcore_node_role_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], role="originator")]
    parsed, errors = validate(cfg)
    assert parsed is None
    assert any("'role'" in e and "MeshCore-specific" in e for e in errors)


def test_path_loss_block_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["simulation"] = dict(cfg["simulation"])
    cfg["simulation"]["path_loss"] = {
        "model": "log_distance",
        "alpha": 3.0,
        "sigma_db": 0.0,
        "ref_distance_m": 1.0,
        "ref_loss_db": 40.0,
        "noise_floor_db": -120.0,
        "tx_power_dbm": 14.0,
    }
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.simulation.path_loss.alpha == 3.0


def test_lat_lon_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], lat=41.39, lon=2.16)]
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.nodes[0].lat == 41.39


def test_sf_rx_set_accepted(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["nodes"] = [dict(cfg["nodes"][0], sf_rx_set=[7, 8, 9])]
    parsed, errors = validate(cfg)
    assert errors == []
    assert parsed.nodes[0].sf_rx_set == [7, 8, 9]


def test_unknown_top_level_rejected(minimal_lus_config):
    cfg = dict(minimal_lus_config)
    cfg["unknown_field"] = 42
    parsed, errors = validate(cfg)
    assert parsed is None  # extra="forbid" rejects
```

- [ ] **Step 5: Run tests; confirm PASS**

```bash
cd webapp && python -m pytest -xvs tests/test_config_validator.py
```

Expected: 7 passed.

- [ ] **Step 6: Commit**

```bash
git add webapp/server/models webapp/server/services/config_validator.py \
        webapp/tests/conftest.py webapp/tests/test_config_validator.py
git commit -m "feat(webapp): config validator + pydantic schemas for lus"
```

---

## Task 3: Event index (port from meshcore_real_sim)

**Files:**
- Copy: `~/meshcore_real_sim/webapp/server/services/event_index.py` → `webapp/server/services/event_index.py`
- Create: `webapp/tests/test_event_index.py`

The meshcore_real_sim event_index is already protocol-agnostic — it indexes any NDJSON file by line offsets and time, then slices `[from_ms, to_ms]` on demand. Port verbatim, then add tests against a fixture lus events file.

- [ ] **Step 1: Copy the source file**

```bash
cp /home/staszek/meshcore_real_sim/webapp/server/services/event_index.py \
   /home/staszek/lora-universal-simulator/webapp/server/services/event_index.py
```

Open `webapp/server/services/event_index.py` and verify there are NO MeshCore-specific imports (`from server.models.firmware...`) or hard-coded event types. If there are, surface as DONE_WITH_CONCERNS in the report.

- [ ] **Step 2: Write `webapp/tests/test_event_index.py`**

```python
"""Tests for event_index — fast NDJSON time-range slicing."""

from __future__ import annotations

import json
from pathlib import Path

from server.services.event_index import EventIndex


def _make_events(tmp_path: Path) -> Path:
    p = tmp_path / "events.ndjson"
    lines = [
        {"type": "sim_start", "time_ms": 0},
        {"type": "tx", "time_ms": 1000, "node": "alice"},
        {"type": "rx", "time_ms": 1023, "from": "alice", "to": "bob"},
        {"type": "script_log", "time_ms": 5000, "node": 0, "msg": "hello"},
        {"type": "sim_end", "time_ms": 60000},
    ]
    p.write_text("\n".join(json.dumps(e) for e in lines) + "\n")
    return p


def test_index_full_range(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(p)
    events = idx.range(0, 60_000)
    assert len(events) == 5
    assert events[0]["type"] == "sim_start"
    assert events[-1]["type"] == "sim_end"


def test_index_partial_range(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(p)
    events = idx.range(500, 4000)
    types = [e["type"] for e in events]
    assert types == ["tx", "rx"]


def test_index_empty_range(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(p)
    events = idx.range(2000, 4000)
    assert events == []
```

(NOTE: The exact `EventIndex` API is `EventIndex(path).range(t0, t1)` per the source. If method names differ in the source, adjust the test calls to match what the ported file actually exposes — but do NOT rename the source file's method.)

- [ ] **Step 3: Run tests; confirm PASS**

```bash
cd webapp && python -m pytest -xvs tests/test_event_index.py
```

Expected: 3 passed. If FAIL because method names differ, fix the test imports to match the source.

- [ ] **Step 4: Commit**

```bash
git add webapp/server/services/event_index.py webapp/tests/test_event_index.py
git commit -m "feat(webapp): port event_index NDJSON slicer"
```

---

## Task 4: Sim manager (port + adapt for lus)

**Files:**
- Copy: `~/meshcore_real_sim/webapp/server/services/sim_manager.py` → `webapp/server/services/sim_manager.py`
- Create: `webapp/tests/test_sim_manager.py`

Adapt the ported file: subprocess invocation `lus <config> <events>` instead of `orchestrator <args>`, drop MeshCore-specific stderr progress parsing.

- [ ] **Step 1: Copy the source file**

```bash
cp /home/staszek/meshcore_real_sim/webapp/server/services/sim_manager.py \
   /home/staszek/lora-universal-simulator/webapp/server/services/sim_manager.py
```

- [ ] **Step 2: Adapt the subprocess call**

Open `webapp/server/services/sim_manager.py`. Find the subprocess construction. The MeshCore version typically reads:

```python
proc = await asyncio.create_subprocess_exec(
    str(self.orchestrator_path),
    *<MeshCore arg list e.g. config_path, --output, events_path>,
    stdout=asyncio.subprocess.PIPE,
    stderr=asyncio.subprocess.PIPE,
)
```

Replace the arg list with the lus calling convention: `lus <config_path> <events_path>` (positional, no flags). The lus binary writes NDJSON events to `events_path` and prints a one-line summary to stderr.

```python
proc = await asyncio.create_subprocess_exec(
    str(self.orchestrator_path),
    str(config_path),
    str(events_path),
    stdout=asyncio.subprocess.PIPE,
    stderr=asyncio.subprocess.PIPE,
)
```

- [ ] **Step 3: Strip MeshCore-specific progress parsing**

Search the file for any function that reads stderr and parses progress messages of the form `"event_count=..."` or `"hot_start: ..."` etc. Replace with a much simpler parser that just captures stderr lines into a `last_stderr` field for diagnostic surfacing. Don't try to extract progress percentages — lus doesn't emit them in the same format.

The simplification target body:

```python
async def _read_stderr(self, proc, sim_id: str):
    """Drain stderr; capture last 50 lines for diagnostics."""
    buf: list[str] = []
    if proc.stderr is None:
        return
    async for line in proc.stderr:
        text = line.decode(errors="replace").rstrip()
        buf.append(text)
        if len(buf) > 50:
            buf.pop(0)
        # Update session record so the UI can show progress.
        sess = self._sessions.get(sim_id)
        if sess is not None:
            sess.last_stderr = "\n".join(buf)
```

(Place this in the same class the original `_read_stderr` lived in. Adjust the field name `last_stderr` to whatever the data model expects; if the dataclass doesn't have such a field yet, add it.)

- [ ] **Step 4: Verify the file compiles + imports**

```bash
cd webapp && python -c "from server.services.sim_manager import SimManager; print('OK')"
```

Expected: `OK`. If ImportError, fix the missing imports in the ported file.

- [ ] **Step 5: Write `webapp/tests/test_sim_manager.py`**

```python
"""Smoke tests for sim_manager — spawn lus on a real config, observe lifecycle."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

import pytest

from server.services.sim_manager import SimManager


REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_sim_lifecycle_spawn_to_completion(tmp_path):
    if not LUS.exists():
        pytest.skip(f"lus binary not built at {LUS}")
    if not SCENARIO.exists():
        pytest.skip(f"scenario fixture not found at {SCENARIO}")

    mgr = SimManager(data_dir=tmp_path, orchestrator_path=str(LUS), max_concurrent=1)

    cfg = json.loads(SCENARIO.read_text())
    sim_id = await mgr.create_simulation(cfg)
    assert sim_id

    # Poll for completion (max 60 s).
    for _ in range(120):
        s = mgr.get_simulation(sim_id)
        if s and s.status in ("completed", "failed"):
            break
        await asyncio.sleep(0.5)

    s = mgr.get_simulation(sim_id)
    assert s is not None, "simulation record vanished"
    assert s.status == "completed", f"expected completed, got {s.status}; stderr={getattr(s,'last_stderr','<none>')}"

    events_file = tmp_path / "simulations" / sim_id / "events.ndjson"
    assert events_file.exists()
    # At minimum sim_start + sim_end should be present.
    types = {json.loads(line)["type"] for line in events_file.open()}
    assert "sim_start" in types
    assert "sim_end" in types
```

(NOTE: the `SimManager` API surface — `create_simulation`, `get_simulation`, `.status` field — must match the ported file. If they differ, adjust the test calls accordingly. Add `pytest-asyncio` to `webapp/requirements.txt` if not already present.)

- [ ] **Step 6: Add `pytest-asyncio` to requirements**

Append to `webapp/requirements.txt`:
```
pytest-asyncio>=0.21,<1.0
```

Re-install:
```bash
cd webapp && pip install -r requirements.txt
```

- [ ] **Step 7: Build lus and run tests**

```bash
cmake --build build -j
cd webapp && python -m pytest -xvs tests/test_sim_manager.py
```

Expected: 1 passed (or skipped if `lus` is missing — investigate then).

- [ ] **Step 8: Commit**

```bash
git add webapp/server/services/sim_manager.py webapp/tests/test_sim_manager.py webapp/requirements.txt
git commit -m "feat(webapp): port sim_manager; adapt subprocess invocation for lus"
```

---

## Task 5: Simulations router

**Files:**
- Copy: `~/meshcore_real_sim/webapp/server/routers/simulations.py` → `webapp/server/routers/simulations.py`
- Modify: `webapp/server/main.py` — register the router
- Create: `webapp/tests/test_simulations_router.py`

The router exposes `/api/sims/*` endpoints. Port verbatim, then adapt it to call `validate()` from `config_validator` instead of any MeshCore-specific validator, and to surface MeshCore-rejection errors clearly in the POST response.

- [ ] **Step 1: Copy the source file**

```bash
cp /home/staszek/meshcore_real_sim/webapp/server/routers/simulations.py \
   /home/staszek/lora-universal-simulator/webapp/server/routers/simulations.py
```

- [ ] **Step 2: Adapt validator import**

In `webapp/server/routers/simulations.py`, change the validator import. Find:

```python
from server.services.config_validator import <whatever_was_meshcore>
```

Replace with:

```python
from server.services.config_validator import validate as validate_lus_config
```

In the POST handler, find the call site (something like `validate_config(body.config_json)`) and adapt it to:

```python
parsed, errors = validate_lus_config(body.config_json)
if errors:
    raise HTTPException(status_code=400, detail={"errors": errors})
```

- [ ] **Step 3: Strip MeshCore-specific topology merge**

Search the router for `merge_topology_and_scenario` or any helper that joins firmware/scenario configs. Drop those calls — for lus, the config_json is the complete scenario.

If the search reveals an import like `from server.services.config_merger import ...`, remove the import and remove the corresponding code path. The lus equivalent is the identity function (the user passes a complete config).

- [ ] **Step 4: Register the router in `webapp/server/main.py`**

In `webapp/server/main.py`, add an import and `include_router` call. Open the file and add to the imports near the top:

```python
from server.routers import simulations
from server.services.sim_manager import SimManager
```

Inside the `lifespan` function, after the directory creation, add:

```python
    app.state.sim_manager = SimManager(
        data_dir=settings.DATA_DIR,
        orchestrator_path=str(settings.ORCHESTRATOR_PATH),
        max_concurrent=settings.MAX_CONCURRENT_SIMS,
    )
```

After `app = FastAPI(...)`, before the static mount, add:

```python
app.include_router(simulations.router, prefix="/api/sims", tags=["sims"])
```

- [ ] **Step 5: Write `webapp/tests/test_simulations_router.py`**

```python
"""Integration tests for the /api/sims router via httpx test client."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from server.main import app


REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_post_sim_then_poll_to_completion(tmp_path, monkeypatch):
    if not LUS.exists():
        pytest.skip("lus binary not built")

    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    cfg = json.loads(SCENARIO.read_text())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # Trigger lifespan via a request.
        await client.get("/health")

        r = await client.post("/api/sims", json={"config_json": cfg})
        assert r.status_code in (200, 201), r.text
        sim_id = r.json()["id"]
        assert sim_id

        # Poll until completed.
        for _ in range(120):
            s = await client.get(f"/api/sims/{sim_id}")
            if s.json().get("status") in ("completed", "failed"):
                break
            await asyncio.sleep(0.5)

        s = await client.get(f"/api/sims/{sim_id}")
        assert s.json()["status"] == "completed"

        ev = await client.get(f"/api/sims/{sim_id}/events", params={"from": 0, "to": 60_000_000})
        events = ev.json()
        types = {e["type"] for e in events}
        assert "sim_start" in types
        assert "sim_end" in types


@pytest.mark.asyncio
async def test_post_sim_rejects_meshcore_field():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        bad = {
            "simulation": {"duration_ms": 100, "radio": {"sf": 7, "bw": 250, "cr": 5}},
            "nodes": [{"name": "a", "script": "x.lua", "config": {}, "role": "originator"}],
            "topology": {"links": []},
        }
        r = await client.post("/api/sims", json={"config_json": bad})
        assert r.status_code == 400
        assert "role" in r.text and "MeshCore" in r.text
```

(Adjust the endpoint paths and request body shape if the ported router uses different names — e.g., `/api/sims/` vs `/api/sims`. Match what the file actually exposes.)

- [ ] **Step 6: Run tests; confirm PASS**

```bash
cd webapp && python -m pytest -xvs tests/test_simulations_router.py
```

Expected: 2 passed.

- [ ] **Step 7: Commit**

```bash
git add webapp/server/routers/simulations.py webapp/server/main.py webapp/tests/test_simulations_router.py
git commit -m "feat(webapp): port simulations router; wire to lus config validator"
```

---

## Task 6: Three base pages — index, simulations, simulation

**Files:**
- Copy: `~/meshcore_real_sim/webapp/static/css/common.css` → `webapp/static/css/common.css` (verbatim)
- Copy: `~/meshcore_real_sim/webapp/static/js/api.js` → `webapp/static/js/api.js` (verbatim)
- Replace: `webapp/static/index.html` (overwrite the placeholder from Task 1)
- Copy: `~/meshcore_real_sim/webapp/static/simulations.html` → `webapp/static/simulations.html`
- Copy: `~/meshcore_real_sim/webapp/static/simulation.html` → `webapp/static/simulation.html`

These are the three lightweight pages. Apply the search-and-replace patterns below to each, then load the three pages in a browser and verify they render and navigate correctly.

- [ ] **Step 1: Copy css + api.js verbatim**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/css/common.css \
   /home/staszek/lora-universal-simulator/webapp/static/css/common.css
cp /home/staszek/meshcore_real_sim/webapp/static/js/api.js \
   /home/staszek/lora-universal-simulator/webapp/static/js/api.js
```

- [ ] **Step 2: Port + adapt `index.html`**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/index.html \
   /home/staszek/lora-universal-simulator/webapp/static/index.html
```

Open `webapp/static/index.html`. Apply these search-and-replace operations exactly:

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `MeshCore` (in user-visible text) | `LoRa Universal Simulator` |

Then DELETE the navigation cards (links) for any pages NOT in this phase: configs, scenarios, scenario_editor, sweep, topologies, topology_creator, topology_editor, map_view, firmware. Keep cards / links only for: simulations, simulation, visualize, map_live, interactive.

Each "card" is typically a `<a class="card">...</a>` block — find them by searching for `href="/static/<page>.html"` and remove the block (the whole `<a>...</a>` element including its inner `<h3>`/`<p>`).

- [ ] **Step 3: Port + adapt `simulations.html`**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/simulations.html \
   /home/staszek/lora-universal-simulator/webapp/static/simulations.html
```

In `webapp/static/simulations.html`:

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `<title>...MeshCore...</title>` | `<title>Simulations — lora-universal-simulator</title>` |

Search the page for any UI element that displays MeshCore-specific fields (firmware name, role badge, plugin list). Remove the corresponding `<th>`, `<td>`, or rendering helper functions. The list should display only: `id`, `name (from config._name if present)`, `status`, `created_at`, `duration_ms`.

Search the JS code for `firmware`, `role`, `plugin` references — delete or convert to no-ops.

- [ ] **Step 4: Port + adapt `simulation.html`**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/simulation.html \
   /home/staszek/lora-universal-simulator/webapp/static/simulation.html
```

In `webapp/static/simulation.html`:

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `MeshCore` (user-visible) | `lus` |

Find the form for "New Simulation". Replace any "Pick firmware" / "Pick role" dropdowns with a single textarea labeled "Scenario JSON" (or a file upload input — whichever the ported page already supports). The textarea should accept a complete lus scenario JSON. After the textarea, add a "Load from file" button that wires `<input type=file>` to read a JSON file into the textarea.

The form's submit handler should POST `{config_json: <parsed JSON>}` to `/api/sims`. If the ported page uses a different request shape, adapt it.

After successful POST (status 200/201), redirect:
- if `config.nodes[*].lat` is present in any node → `/static/map_live.html?id=<id>`
- otherwise → `/static/visualize.html?id=<id>` (after sim completes — show a "running" panel until then)

- [ ] **Step 5: Restart the server and manually verify**

```bash
cd webapp && bash run.sh
```

In a browser:
1. Open http://localhost:8000/ — sees the index with cards for simulations + visualize + map_live + interactive only.
2. Click "Simulations" — list loads (empty initially).
3. Click "New Simulation" → simulation.html — paste the contents of `scenarios/s01_dv_dual_sf.json` into the textarea, click "Start".
4. Browser redirects to map_live (s01 has lat/lon) — verify the redirect URL has `?id=<sim_id>`. (The actual map will not render until Task 8.)
5. Open simulations.html again — the new run appears in the list with status `running` then `completed`.

If any of these steps fails, capture the error text and adjust the page accordingly. The most common port issues are:
- API endpoint path mismatch (e.g., `/api/sims` vs `/api/sims/`)
- Field name mismatch in the request/response JSON
- Stale references to the deleted MeshCore-specific elements

Stop the server (Ctrl-C).

- [ ] **Step 6: Commit**

```bash
git add webapp/static/index.html webapp/static/simulations.html webapp/static/simulation.html \
        webapp/static/css/common.css webapp/static/js/api.js
git commit -m "feat(webapp): port index/simulations/simulation pages; strip MeshCore UI"
```

---

## Task 7: visualize.html — swim-lane replay (port + adapt event vocabulary)

**Files:**
- Copy: `~/meshcore_real_sim/webapp/static/visualize.html` → `webapp/static/visualize.html`

Visualize is 2170 lines. The bulk is rendering the swim-lane and side panel — protocol-agnostic and ports cleanly. The adaptation surface is the **event-rendering switch**: the part of the JS that decides "what does an event of type X look like in the swim lane?". MeshCore has its own event types (e.g., `advert`, `path_request`, `path_response`); lus has the generic vocabulary in spec §6.

- [ ] **Step 1: Copy the source**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/visualize.html \
   /home/staszek/lora-universal-simulator/webapp/static/visualize.html
```

- [ ] **Step 2: Title + branding rewrites**

In `webapp/static/visualize.html`:

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `<title>...</title>` | `<title>Visualize — lora-universal-simulator</title>` |

- [ ] **Step 3: Replace MeshCore packet decoder with generic event renderer**

Search the file for a function that decodes MeshCore packet types based on their first byte (`PACKET_TYPE_ADVERT`, `PACKET_TYPE_PATH_REQ`, etc.). Find it by searching for `decodePacket` or `packetType` or `MC_PACKET_*` constants.

Replace the decoder body with a passthrough that returns the raw `pkt` hex string and the `type` field of the event verbatim. The renderer doesn't decode payloads anymore — it just shows what lus emits.

If the file has a constants block like:

```js
const MC_PKT_TYPE_NAMES = { 0x00: "advert", 0x01: "...", ... };
```

Delete the entire block.

Find every usage of those constants (search for `MC_PKT_TYPE_NAMES`) and replace with a simple inline that uses the event type directly.

- [ ] **Step 4: Update the event-type→swim-lane-color mapping**

Find the function/object that maps event types to colors (likely a `colorByType` table or a switch inside the renderer). Replace it with the lus event vocabulary from spec §6. Use this concrete table:

```js
const COLORS = {
  sim_start:        '#aaaaff',
  sim_end:          '#aaaaff',
  node_ready:       '#88aa88',
  tx:               '#88ddff',
  rx:               '#88ff88',
  drop_weak:        '#ff8888',
  drop_sf_mismatch: '#ff6688',
  drop_halfduplex:  '#ff4488',
  collision:        '#ff4444',
  tx_deferred:      '#ffcc44',
  cmd_reply:        '#cccccc',
  script_log:       '#ffffaa',
  script_emit:      '#aaffff',
  node_stats:       '#cccccc',
};
```

Find the renderer's color lookup call site and replace it with `COLORS[evt.type] || '#888'`.

- [ ] **Step 5: Update the side-panel field-display order**

Find the side panel template (search for `'sidebar'` or `renderSidebar`). MeshCore-specific fields like `firmware_name`, `role`, `plugin_list` should be removed from the display. Replace the field whitelist with this lus-friendly order:

```
type, time_ms, node, from, to, snr, rssi, packet_sf, rx_sf, pkt, hex,
emit_type, msg, data
```

The side panel renders these in order; everything else falls into a "raw JSON" footer.

- [ ] **Step 6: Restart server and manually verify**

```bash
cd webapp && bash run.sh
```

Run a sim from the simulations page (the pasting flow added in Task 6), wait for completion, then open `/static/visualize.html?id=<sim_id>` directly. Verify:
1. Swim lanes appear, one per node.
2. `tx` events on alice show as cyan blocks.
3. `rx` events show as green blocks at the corresponding receiver.
4. `drop_*` events show in red on the receiver.
5. Side panel shows the right fields when an event is clicked.
6. Time scrubber works.

Common issues when porting visualize.html:
- The event-loading endpoint path differs — check the JS for `/api/sims/.../events` or similar; align with what the ported router uses.
- The events array shape is `[event, event, ...]` for lus (no envelope object).

Stop the server.

- [ ] **Step 7: Commit**

```bash
git add webapp/static/visualize.html
git commit -m "feat(webapp): port visualize.html swim-lane viewer; rewire event vocabulary for lus"
```

---

## Task 8: map_live.html — live SSE map (port + adapt)

**Files:**
- Copy: `~/meshcore_real_sim/webapp/static/map_live.html` → `webapp/static/map_live.html`

Map_live is 1885 lines. It uses Leaflet for the map. The structure: open an SSE connection to the simulations router's event stream endpoint, render nodes from the config's lat/lon, animate `tx` (pulse on sender) and `rx` (arrow sender→receiver) events.

- [ ] **Step 1: Copy the source**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/map_live.html \
   /home/staszek/lora-universal-simulator/webapp/static/map_live.html
```

- [ ] **Step 2: Title + branding**

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `<title>...</title>` | `<title>Live Map — lora-universal-simulator</title>` |

- [ ] **Step 3: Replace MeshCore packet decoder with passthrough**

Search the file for a function that decodes MeshCore packet types based on their first byte (`PACKET_TYPE_ADVERT`, `PACKET_TYPE_PATH_REQ`, etc.) — typically named `decodePacket`/`packetType` or referencing `MC_PKT_TYPE_*` constants. Find by grep for `decodePacket`, `MC_PKT_TYPE`, or `packetType`.

Delete the entire decoder body and any `MC_PKT_TYPE_NAMES` constants block. Find every callsite (search for `MC_PKT_TYPE_NAMES` or `decodePacket`) and replace with the event's raw `type` field directly:

```js
// before:  const t = MC_PKT_TYPE_NAMES[decodePacket(evt.pkt)];
// after:   const t = evt.type;
```

The map shows traffic by event type, not by decoded packet payload type.

- [ ] **Step 4: Update animation table for lus event vocabulary**

Find the SSE message handler — it's typically `eventSource.onmessage = (e) => { ... }`. Inside, there's a switch over `evt.type` that triggers different visual effects. Replace with:

```js
switch (evt.type) {
  case 'tx':
    pulseNode(evt.node, '#88ddff');                          // cyan pulse
    break;
  case 'rx':
    drawArrow(evt.from, evt.to, '#88ff88', evt.snr);         // green arrow
    break;
  case 'drop_weak':
  case 'drop_sf_mismatch':
  case 'drop_halfduplex':
    flashNode(evt.to, '#ff6688');                            // red flash on receiver
    break;
  case 'collision':
    flashNode(evt.to, '#ff4444');                            // dark-red flash
    break;
  case 'tx_deferred':
    flashNode(evt.node, '#ffcc44');                          // yellow flash on sender
    break;
  case 'script_log':
  case 'script_emit':
    appendLog(evt);                                          // side panel scroll
    break;
  // sim_start, sim_end, node_ready: handled outside the switch (state changes)
  default:
    appendLog(evt);                                          // unknown types still visible
}
```

If `pulseNode`, `drawArrow`, `flashNode`, `appendLog` already exist in the source file (with possibly different names), use the existing ones. The structure of the switch is what matters.

- [ ] **Step 5: Replace SSE endpoint URL**

Search for the SSE endpoint in the JS — typically `new EventSource("/api/...")`. Replace with `new EventSource(\`/api/sims/${simId}/stream\`)` if not already. Keep the `simId` extraction from the `?id=` query string.

- [ ] **Step 6: Drop firmware-badge rendering on node markers**

Search for `firmware` in the file. Each node-marker creation function probably reads a firmware name and renders it as a badge. Remove those reads + the badge HTML.

The node marker tooltip should display: `name`, `id`, `lat`, `lon`, and (if available from the config) the script path.

- [ ] **Step 7: Verify in browser**

```bash
cd webapp && bash run.sh
```

In another tab, run a sim from simulations.html (the s01 scenario which has lat/lon). The page should redirect to map_live. Verify:
1. Four nodes appear on the map at the s01 lat/lon.
2. As beacons fly, sender pulses cyan and receivers draw green arrows.
3. As DATA frames travel SF12, you see the sender→receiver arrow and the bystander red drops.
4. Side panel scrolls `script_log` lines (the human-readable trace from `dv_dual_sf.lua`).

Stop the server.

- [ ] **Step 8: Commit**

```bash
git add webapp/static/map_live.html
git commit -m "feat(webapp): port map_live.html; rewire SSE handlers for lus event vocabulary"
```

---

## Task 9: Interactive manager + router

**Files:**
- Copy: `~/meshcore_real_sim/webapp/server/services/interactive_manager.py` → `webapp/server/services/interactive_manager.py`
- Copy: `~/meshcore_real_sim/webapp/server/routers/interactive.py` → `webapp/server/routers/interactive.py`
- Modify: `webapp/server/main.py` — register interactive router + manager
- Create: `webapp/tests/test_interactive_manager.py`

The interactive manager spawns `lus -i <config>` and routes WebSocket traffic to/from the subprocess. Adapt: subprocess command, drop MeshCore-specific REPL command parsing.

- [ ] **Step 1: Copy the manager**

```bash
cp /home/staszek/meshcore_real_sim/webapp/server/services/interactive_manager.py \
   /home/staszek/lora-universal-simulator/webapp/server/services/interactive_manager.py
```

- [ ] **Step 2: Adapt subprocess command in interactive_manager.py**

Find the subprocess construction in `start_session` (or similar method). MeshCore uses something like `<orchestrator> -i <config>` with potentially extra flags. Replace with the lus equivalent:

```python
proc = await asyncio.create_subprocess_exec(
    str(self.orchestrator_path),
    "-i",
    str(config_path),
    stdin=asyncio.subprocess.PIPE,
    stdout=asyncio.subprocess.PIPE,
    stderr=asyncio.subprocess.PIPE,
)
```

If the file has a "build args" helper that includes MeshCore-specific flags (like `--firmware`, `--scenario`), strip those and reduce the call to just `-i <config>`.

- [ ] **Step 3: Drop MeshCore-specific stdout classification (if any)**

The classifier already in the source ("> " prefix = response, JSON = event) is generic and works for lus's REPL. Verify by reading the classifier — if there's a specific MeshCore packet-decode hook in the event branch, remove it (events flow through verbatim).

- [ ] **Step 4: Copy the router**

```bash
cp /home/staszek/meshcore_real_sim/webapp/server/routers/interactive.py \
   /home/staszek/lora-universal-simulator/webapp/server/routers/interactive.py
```

- [ ] **Step 5: Adapt validator import in interactive.py**

In `webapp/server/routers/interactive.py`, find the existing config-validation import (the MeshCore version typically imports a function from `server.services.config_validator` with a name like `validate_meshcore_config`). Replace with:

```python
from server.services.config_validator import validate as validate_lus_config
```

In the create-session handler:

```python
parsed, errors = validate_lus_config(body.config_json)
if errors:
    raise HTTPException(status_code=400, detail={"errors": errors})
```

Drop any `merge_topology_and_scenario` calls.

- [ ] **Step 6: Register the router and manager in `webapp/server/main.py`**

In `webapp/server/main.py`, add to the imports:

```python
from server.routers import interactive
from server.services.interactive_manager import InteractiveSessionManager
```

Inside the `lifespan` function (after the existing `app.state.sim_manager = ...`), add:

```python
    app.state.interactive_manager = InteractiveSessionManager(
        data_dir=settings.DATA_DIR,
        orchestrator_path=str(settings.ORCHESTRATOR_PATH),
        max_sessions=settings.MAX_INTERACTIVE_SESSIONS,
        idle_timeout_s=settings.INTERACTIVE_IDLE_TIMEOUT_S,
    )
    app.state.interactive_manager.start_cleanup_loop()
```

After the `yield`:

```python
    await app.state.interactive_manager.shutdown()
```

After `app.include_router(simulations.router, ...)`:

```python
app.include_router(interactive.router, prefix="/api/interactive", tags=["interactive"])
```

- [ ] **Step 7: Write `webapp/tests/test_interactive_manager.py`**

```python
"""Smoke test for interactive_manager — spawn lus -i, send a step, see output."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest

from server.services.interactive_manager import InteractiveSessionManager


REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"


@pytest.mark.asyncio
async def test_create_step_close(tmp_path):
    if not LUS.exists():
        pytest.skip("lus binary not built")

    mgr = InteractiveSessionManager(
        data_dir=tmp_path,
        orchestrator_path=str(LUS),
        max_sessions=1,
        idle_timeout_s=30,
    )

    # Minimal viable lus config (no path-loss, one node, one second).
    cfg = {
        "_name": "interactive-smoke",
        "simulation": {
            "duration_ms": 5000,
            "step_ms": 1,
            "warmup_ms": 0,
            "radio": {"sf": 7, "bw": 250, "cr": 5},
        },
        "nodes": [{"name": "n1", "script": "examples/quiet.lua", "config": {}}],
        "topology": {"links": []},
        "commands": [],
        "expect": [],
    }

    sess_id = await mgr.create_session(cfg)
    assert sess_id

    # Send "step 1" via stdin — wait for the "> " response line.
    response = await mgr.send_command(sess_id, "step 1")
    assert response is not None  # exact format depends on REPL output

    await mgr.close_session(sess_id)
```

(NOTE: examples/quiet.lua exists and is a no-op script — perfect for this smoke test. The `create_session` / `send_command` / `close_session` API names must match the ported manager. Adjust if the ported file uses different method names.)

- [ ] **Step 8: Run tests; confirm PASS**

```bash
cd webapp && python -m pytest -xvs tests/test_interactive_manager.py
```

Expected: 1 passed.

- [ ] **Step 9: Commit**

```bash
git add webapp/server/services/interactive_manager.py \
        webapp/server/routers/interactive.py \
        webapp/server/main.py \
        webapp/tests/test_interactive_manager.py
git commit -m "feat(webapp): port interactive manager + router; spawn lus -i"
```

---

## Task 10: interactive.html (port + adapt)

**Files:**
- Copy: `~/meshcore_real_sim/webapp/static/interactive.html` → `webapp/static/interactive.html`

The interactive page is 1417 lines. UI structure: command box at the bottom, response panel above it, optional embedded map and event-stream side panel.

- [ ] **Step 1: Copy the source**

```bash
cp /home/staszek/meshcore_real_sim/webapp/static/interactive.html \
   /home/staszek/lora-universal-simulator/webapp/static/interactive.html
```

- [ ] **Step 2: Title + branding**

| Find | Replace |
|---|---|
| `MeshCore Simulator` | `lora-universal-simulator` |
| `<title>...</title>` | `<title>Interactive — lora-universal-simulator</title>` |

- [ ] **Step 3: Replace MeshCore command list with lus REPL commands**

Search for a "command help" block — typically a `<details>` or sidebar listing commands like `/send`, `/route`, `/path`. Replace the documented commands with lus's REPL command set:

```
help                          show this help
status                        sim time, node count, ended?
step [ms]                     advance one tick (or ms ms)
run [ms]                      run for ms (or to end)
next                          run until next event lands
cmd <node> <text>             dispatch a command to a node's on_command
nodes                         list nodes
events [n]                    last n events (default 10)
quit                          end session
```

(If the underlying lus REPL exposes additional commands not listed here, add them. Read `orchestrator/runtime/InteractiveRepl.cpp` for the canonical list.)

- [ ] **Step 4: Replace MeshCore packet decoder calls (if any)**

Search the file for `decodePacket` / `MC_PKT_TYPE_*` constants. If present, delete the decoder body and constants block, and replace callsites with `evt.type` directly. The interactive page typically uses the same decoder helpers as visualize/map_live, so the same removal pattern applies.

- [ ] **Step 5: Drop firmware/role/plugin UI selectors**

Search for any form that picks "firmware" or "role" before starting a session. Replace with the same scenario JSON paste/upload pattern from Task 6 — paste textarea + load-from-file button.

- [ ] **Step 6: Verify in browser**

```bash
cd webapp && bash run.sh
```

Open http://localhost:8000/static/interactive.html — paste a minimal config (the one from `test_interactive_manager.py` will do), click "Start Session". Type `step 1` and press Enter — verify the response panel shows the step result. Type `nodes` — verify the node list appears. Type `quit`.

Stop the server.

- [ ] **Step 7: Commit**

```bash
git add webapp/static/interactive.html
git commit -m "feat(webapp): port interactive.html; replace MeshCore command set with lus REPL"
```

---

## Task 11: ARCHITECTURE.md + Dockerfile + docker-compose + README hook

**Files:**
- Create: `webapp/ARCHITECTURE.md`
- Copy + adapt: `~/meshcore_real_sim/webapp/Dockerfile` → `webapp/Dockerfile`
- Copy + adapt: `~/meshcore_real_sim/webapp/docker-compose.yml` → `webapp/docker-compose.yml`
- Modify: `README.md` — add a "Webapp" section
- Create: `webapp/tests/test_smoke_e2e.py`

This task wraps the project: docker workflow for someone who wants to run the webapp without setting up Python locally, an architecture doc summarizing what we built, a smoke test that runs the s01 scenario through the webapp end-to-end and verifies the SSE stream produces the same events as the CLI does, and a README pointer.

- [ ] **Step 1: Write `webapp/ARCHITECTURE.md`**

```markdown
# lora-universal-simulator webapp — architecture

## Quick Start

```bash
cmake -S . -B build && cmake --build build --target lus
cd webapp
pip install -r requirements.txt
bash run.sh
# Open http://localhost:8000
```

Or via Docker (requires the `lus` binary built first):
```bash
cmake -S . -B build && cmake --build build --target lus
cd webapp
docker compose up
```

## Environment

| Variable | Default | Description |
|---|---|---|
| `DATA_DIR` | `webapp/data` | Filesystem state for sims and sessions |
| `ORCHESTRATOR_PATH` | `../build/orchestrator/lus` | Path to compiled lus binary |
| `MAX_CONCURRENT_SIMS` | CPU count | Cap on parallel simulations |
| `MAX_INTERACTIVE_SESSIONS` | 4 | Cap on concurrent REPL sessions |
| `INTERACTIVE_IDLE_TIMEOUT_S` | 300 | Auto-close idle interactive sessions |

## Architecture

```
Browser (vanilla JS, no build)
   |
   |  HTTP / SSE / WebSocket
   v
FastAPI backend
   |
   |  asyncio subprocess
   v
build/orchestrator/lus
   |
   +---> stdout: events.ndjson  (NDJSON event stream)
   +---> stderr: progress / summary
```

All state on disk:

```
webapp/data/
  simulations/{id}/
    config.json
    events.ndjson
    status.json   {status, created_at, completed_at, error, pid}
  interactive/{id}/
    config.json
    events.ndjson
    session.json
```

## Pages

| Page | Path | Purpose |
|---|---|---|
| index | `/` | Landing page |
| simulations | `/static/simulations.html` | List past runs |
| simulation | `/static/simulation.html` | Launch a new sim |
| visualize | `/static/visualize.html?id=...` | Swim-lane replay |
| map_live | `/static/map_live.html?id=...` | Live SSE map |
| interactive | `/static/interactive.html` | WebSocket REPL |

Topology authoring (creator/editor) is deferred to a later phase; for
now, scenario JSON is authored in a text editor and pasted/uploaded.

## Backend

```
webapp/server/
  main.py                       # FastAPI app + lifespan
  config.py                     # Settings (env vars)
  routers/
    simulations.py              # /api/sims/*  — REST + SSE
    interactive.py              # /api/interactive/*  — REST + WebSocket
  services/
    sim_manager.py              # Subprocess lifecycle for `lus`
    event_index.py              # NDJSON time-range slicer
    interactive_manager.py      # Subprocess lifecycle for `lus -i`
    config_validator.py         # lus schema validator
  models/
    schemas.py                  # pydantic v2 models for lus configs
```

## Out of scope (this phase)

- Topology creator / editor / list UI and their backend services
- Parameter sweeps
- MeshCore-specific machinery (firmware, role, plugins, ITM)
- Authentication
```

- [ ] **Step 2: Port + adapt `Dockerfile`**

```bash
cp /home/staszek/meshcore_real_sim/webapp/Dockerfile \
   /home/staszek/lora-universal-simulator/webapp/Dockerfile
```

Open the file. Make these adaptations:

1. Drop the ITM/SRTM-related installations (any `itmlogic`, `SRTM`, `numpy` if it was only there for itmlogic). Keep only what `requirements.txt` lists.
2. Update the binary path: the Dockerfile likely copies `<repo>/build/orchestrator/orchestrator` to a known location inside the image. Change to copy `<repo>/build/orchestrator/lus` instead.
3. Update the `CMD`/`ENTRYPOINT` to start uvicorn from the right path: `uvicorn server.main:app --host 0.0.0.0 --port 8000`.

- [ ] **Step 3: Port + adapt `docker-compose.yml`**

```bash
cp /home/staszek/meshcore_real_sim/webapp/docker-compose.yml \
   /home/staszek/lora-universal-simulator/webapp/docker-compose.yml
```

Open the file. Adaptations:
1. Service name → `webapp` (or whatever feels natural).
2. Volume mount for `webapp/data:/app/data` — preserved.
3. Drop any `MeshCore` or itm-specific environment variables.
4. The bind-mount for the lus binary: `../build/orchestrator/lus:/app/lus:ro`.

Set `ORCHESTRATOR_PATH=/app/lus` in the `environment` block.

- [ ] **Step 4: Add Webapp section to `README.md`**

Open `README.md`. Find the bottom of the file and append:

```markdown

## Webapp (live tracking + REPL)

The `webapp/` directory contains an optional FastAPI + vanilla-JS frontend
for live simulation tracking, swim-lane replay, and a browser-driven
interactive REPL. After building the `lus` binary, run:

```bash
cd webapp
pip install -r requirements.txt
bash run.sh
```

Open http://localhost:8000. See `webapp/ARCHITECTURE.md` for details.
```

- [ ] **Step 5: Write `webapp/tests/test_smoke_e2e.py`**

```python
"""End-to-end smoke test: run the s01 scenario through the webapp and
verify the events the SSE/REST surface produces match what the CLI
produces directly.
"""

from __future__ import annotations

import asyncio
import json
import subprocess
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s01_dv_dual_sf.json"


@pytest.mark.asyncio
async def test_webapp_matches_cli_events(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s01 scenario missing")

    # Run via CLI for ground truth.
    cli_events = tmp_path / "cli_events.ndjson"
    subprocess.run(
        [str(LUS), str(SCENARIO), str(cli_events)],
        check=True, capture_output=True,
    )
    cli_types = sorted(
        json.loads(line)["type"] for line in cli_events.open()
    )

    # Run via webapp.
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "webapp_data"))
    cfg = json.loads(SCENARIO.read_text())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        await client.get("/health")
        r = await client.post("/api/sims", json={"config_json": cfg})
        sim_id = r.json()["id"]
        for _ in range(180):
            s = await client.get(f"/api/sims/{sim_id}")
            if s.json().get("status") in ("completed", "failed"):
                break
            await asyncio.sleep(0.5)

        ev = await client.get(f"/api/sims/{sim_id}/events", params={"from": 0, "to": 60_000_000})
        web_events = ev.json()
        web_types = sorted(e["type"] for e in web_events)

    # Both runs are deterministic; type-multisets must match.
    assert cli_types == web_types, (
        f"CLI vs webapp event types differ: cli has {set(cli_types)-set(web_types)}, "
        f"webapp has {set(web_types)-set(cli_types)}"
    )
```

- [ ] **Step 6: Run all tests**

```bash
cd webapp && python -m pytest -xvs tests/
```

Expected: every test passes. If `test_smoke_e2e.py` fails because the event-types multiset differs, inspect the events files and fix whatever is dropping or duplicating events.

- [ ] **Step 7: Commit**

```bash
git add webapp/ARCHITECTURE.md webapp/Dockerfile webapp/docker-compose.yml \
        webapp/tests/test_smoke_e2e.py README.md
git commit -m "docs+infra(webapp): ARCHITECTURE, Docker, README hook, e2e smoke test"
```

---

## Acceptance for the webapp implementation

After all 11 tasks:

- [ ] `cd webapp && python -m pytest tests/` — all tests pass
- [ ] `cd webapp && bash run.sh` starts uvicorn on port 8000
- [ ] http://localhost:8000/ shows the index with cards: simulations, simulation, visualize, map_live, interactive
- [ ] Pasting `scenarios/s01_dv_dual_sf.json` into simulation.html and clicking Start runs the scenario and redirects to map_live
- [ ] During the run, map_live shows nodes pulsing on tx, arrows on rx, and the side panel scrolls `script_log` lines
- [ ] After the run completes, visualize.html replays the swim lanes
- [ ] interactive.html can spawn a `lus -i` session, accept REPL commands (`step`, `run`, `cmd`, `nodes`, `events`), and tear down on idle timeout
- [ ] No MeshCore-specific text or controls remain in any page
- [ ] Topology creator / topology editor / topologies list pages and their backends are NOT present (deferred to next phase)
