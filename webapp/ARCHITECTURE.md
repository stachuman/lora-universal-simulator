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
| `LUS_CWD` | repo root | cwd for the lus subprocess (must contain Lua scripts referenced by configs) |
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
   +---> events file (path passed as 2nd argv to lus)
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
| simulation | `/static/simulation.html` | Launch a new sim, see status, link to viz |
| visualize | `/static/visualize.html?id=...` | Swim-lane replay |
| map_live | `/static/map_live.html?id=...` | Animated map (replay mode) |
| interactive | `/static/interactive.html` | WebSocket-driven REPL session |

Topology authoring (creator/editor) is deferred to a later phase; for now,
scenario JSON is authored in a text editor and pasted/uploaded.

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

## REST API summary

```
POST   /api/sims                         create a sim from {config_json}
GET    /api/sims                         list past runs
GET    /api/sims/{id}                    sim status + config_summary
DELETE /api/sims/{id}                    cancel + delete
GET    /api/sims/{id}/events?from=&to=   event slice
GET    /api/sims/{id}/meta               metadata (sim_info, nodes, summary)
GET    /api/sims/{id}/density?from=&to=&bucket=
GET    /api/sims/{id}/node_events/{node}
GET    /api/sims/{id}/stream             SSE: progress + status updates
POST   /api/interactive/                 create a REPL session from {config_json}
GET    /api/interactive/{id}             session status
GET    /api/interactive/{id}/config      session's config
GET    /api/interactive/{id}/meta        session metadata
GET    /api/interactive/{id}/events?from=&to=
DELETE /api/interactive/{id}             close session
WS     /api/interactive/{id}/ws          REPL command/response stream
```

## Out of scope (this phase)

- Topology creator / editor / list UI and their backend services
- Parameter sweeps
- MeshCore-specific machinery (firmware, role, plugins, ITM)
- Authentication
