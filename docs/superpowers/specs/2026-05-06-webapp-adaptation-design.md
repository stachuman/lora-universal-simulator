# Webapp adaptation — design

## 1. Background and goal

The simulator currently exposes only a CLI (`lus`) and a static swim-lane
viewer (`tools/visualize.html`). For larger or longer-running scenarios, the
user needs better real-time visibility: which packets are flying, what
script-emitted events fire, where nodes are on a map, how routing tables
converge. The user also needs a low-friction way to author topologies that
exercise the path-loss model (R.2).

`~/meshcore_real_sim/webapp/` already implements all of this for the
MeshCore project: FastAPI backend, vanilla-JS frontend, ~10 pages, no
database. We adapt that webapp into `lora-universal-simulator/webapp/`,
strip the MeshCore-specific machinery, and rewrite the topology
generator's link engine to use lus's `PathLossModel`.

**Primary purpose**: live tracking of a running simulation in a browser
(node positions, packet animation, event timeline, script logs).

**Phase scope**: this spec covers the tracking/replay/REPL phase only.
Topology creation (placing nodes on a map, computing path-loss preview,
saving topology files) is **deferred to a separate next-phase spec**.
For now, scenario JSON files are authored in a text editor and either
uploaded via the simulation runner page or read from `scenarios/` on
disk.

## 2. Non-goals

The following are explicitly out of scope and **must not** be added:

- **Parameter sweeps** (the `sweep.html` page and `sweep_runner` service).
  Deferred — user can script `lus` invocations manually.
- **Scenario/config editor pages** (`scenarios.html`, `scenario_editor.html`,
  `configs.html`). User authors scenario JSON in their text editor.
- **MeshCore packet decoders, role/firmware concepts, ITM terrain model,
  MeshCore map API integration**. Replace ITM with the simulator's
  log-distance `PathLossModel`.
- **Database**. Filesystem state only — `data/simulations/{id}/`,
  `data/topologies/{id}/`, `data/interactive/{id}/`.
- **Authentication / multi-user**. Single-user dev tool.
- **Sub-millisecond streaming**. SSE at ~10 Hz is plenty for human visual
  tracking of LoRa-scale traffic.

## 3. Architecture

```
Browser (vanilla JS, no build step, served from FastAPI static mount)
  │
  │  HTTP / SSE / WebSocket
  ▼
FastAPI backend (Python, single process)
  │
  │  asyncio subprocess
  ▼
build/orchestrator/lus (compiled C++ binary)
  │
  ├── stdout: events.ndjson
  └── stderr: progress / summary
```

Same shape as `meshcore_real_sim`. All state on disk:

```
webapp/data/
  simulations/{id}/
    config.json
    events.ndjson
    status.json   {status, created_at, completed_at, error, pid}
  topologies/{id}/
    topology.json
    metadata.json
  interactive/{id}/
    config.json
    events.ndjson
    session.json
```

The webapp lives at `lora-universal-simulator/webapp/`. The lus binary
lives at `lora-universal-simulator/build/orchestrator/lus` — the webapp
launches it via `ORCHESTRATOR_PATH` env var (default
`../build/orchestrator/lus`).

## 4. Pages

### 4.1 Pages we port (this phase)

| Page | Source line count | Adaptation effort | Purpose |
|---|---|---|---|
| `index.html` | 241 | trivial | landing, links to other pages |
| `simulations.html` | 502 | small | list past runs, filter by status |
| `simulation.html` | 789 | medium | launch a sim (paste/upload scenario JSON), see status, link to viz |
| `visualize.html` | 2170 | medium | swim-lane replay (supersedes `tools/visualize.html`) |
| `map_live.html` | 1885 | medium | live SSE-streamed map view |
| `interactive.html` | 1417 | small | WebSocket-driven REPL session |

### 4.2 Pages we drop (this phase)

`scenarios.html`, `scenario_editor.html`, `configs.html`, `sweep.html`,
`map_view.html` (duplicates map_live's renderer), `editor.html` (stub).

### 4.3 Pages deferred to next phase

`topology_creator.html`, `topologies.html`, `topology_editor.html` — all
topology-authoring UI. Will be addressed in a separate spec; the
backend services they depend on (`topo_generator`, `topo_tools`,
`topologies` router) are also deferred to that phase.

### 4.4 Adaptation rules common to all pages

- Replace MeshCore-specific text (titles, labels) with simulator-agnostic
  wording. Title format: `"<Page name> — lora-universal-simulator"`.
- Drop UI controls for firmware, role, plugin selection.
- Replace MeshCore packet decoder calls in event handlers with lus's
  generic event vocabulary (see §6).
- Map view nodes carry `{name, lat, lon}` only — no firmware badge.

## 5. Backend

### 5.1 Routers (this phase)

| Router | Status | Endpoints (selected) |
|---|---|---|
| `simulations` | port + adapt | `POST /api/sims`, `GET /api/sims`, `GET /api/sims/{id}`, `GET /api/sims/{id}/events?from=&to=`, `GET /api/sims/{id}/stream` (SSE) |
| `interactive` | port + adapt | `POST /api/interactive/`, `GET /api/interactive/{id}`, `WS /api/interactive/{id}/ws` |

**Dropped**: `firmware`, `sweeps`, `configs`.

**Deferred to next phase**: `topologies`, `topo_creator`.

### 5.2 Services (this phase)

| Service | Status | Notes |
|---|---|---|
| `sim_manager` | port + adapt | Spawns `lus <config> <events>` subprocess. Streams stdout via asyncio.subprocess. Strips MeshCore-specific progress parsing. |
| `event_index` | port verbatim | Already protocol-agnostic — indexes NDJSON for fast `from..to` slicing. |
| `interactive_manager` | port + adapt | Spawns `lus -i <config>`. Same WebSocket relay shape, same session lifecycle. |
| `config_validator` | **rewrite** | New schema: `simulation` (with `path_loss` block), `nodes[i]` with `script` + `config` + optional `lat`/`lon`/`sf_rx_set`, `topology.links` (optional). Reject MeshCore-only fields with clear error messages. |

**Deferred to next phase**: `topo_generator`, `topo_tools`.

### 5.3 Config schema (lus-flavored)

The validator accepts:

```
simulation:
  duration_ms: int (required)
  step_ms: int (default 1, must be 1)
  warmup_ms: int (default 0)
  radio: { sf, bw, cr, cad_miss_prob?, cad_reliable_snr?, cad_marginal_snr? }
  path_loss?:
    model: "log_distance"
    alpha: float
    sigma_db: float
    ref_distance_m: float
    ref_loss_db: float
    noise_floor_db: float
    tx_power_dbm: float

nodes[]:
  name: str (required, unique)
  script: str (required, path)
  config: object (per-node config passed to on_init)
  lat?: float
  lon?: float
  sf?: int
  bw?: int (kHz)
  cr?: int
  sf_rx_set?: int[]

topology:
  links?: [{from, to, snr, rssi, bidir, snr_std_dev?, snr_coherence_ms?, loss?}]

commands?: [{at_ms, node, command}]

expect?: [...]
```

The validator rejects (with explicit error messages):
`firmware`, `role`, `_requires_plugins`, `simulation.firmware`,
`simulation.hot_start`, `nodes[i].firmware`, `nodes[i].role`.

## 6. Event vocabulary the frontend renders

All frontend pages parse the lus NDJSON event types listed below. The
visualize and map_live pages must render or filter on each.

| Type | Renderer treatment |
|---|---|
| `sim_start` / `sim_end` | timeline bookends; map shows "running" / "ended" state |
| `node_ready` | first time a node appears on the map; place at `lat/lon` from config |
| `tx` | swim-lane block on sender (visualize); animated pulse on map (map_live) |
| `rx` | swim-lane arrow sender→receiver (visualize); arrow on map (map_live) |
| `drop_weak` / `drop_sf_mismatch` / `drop_halfduplex` | red marker on receiver |
| `collision` | red marker; correlated to interferer if present |
| `tx_deferred` | yellow marker on sender |
| `cmd_reply` | inline log line in side panel |
| `script_log` | inline log line on sender (newest scrolls to top) |
| `script_emit` | inline log line; users can filter by `emit_type` |
| `node_stats` | per-node summary table at end of run |

Events not on this list pass through to the side panel as raw JSON
(future-proof — protocols may emit new types).

## 7. Topology creator — deferred to next phase

The topology creator page (Leaflet-based node placement, lus path-loss SNR
preview, save-as-scenario flow) is deferred to a separate next-phase
spec. Until then, scenario JSON files are authored in a text editor and
either uploaded directly via `simulation.html` (paste box / file
upload) or read from `scenarios/` on disk.

When the next-phase spec lands, it will cover: Leaflet UI, region
presets, node-placement modes (manual/grid/random), path-loss preset
picker, live SNR preview backed by a pure-Python log-distance + haversine
that exactly matches `core/link/PathLossModel.cpp`, and the save-as-
scenario flow that emits a complete scenario JSON with `topology.links`
empty (path-loss drives).

## 8. Live tracking flow (the primary use case)

1. User opens `simulations.html`, clicks "New Simulation"
2. Form: paste a scenario JSON (or upload a `.json` file), click Start
3. Backend POSTs to `/api/sims`, spawns `lus <config> <events_path>`
4. User is redirected to `simulation.html?id={id}` which auto-redirects
   to `map_live.html?id={id}` if a topology with lat/lon is in the config
5. `map_live.html` opens an SSE connection to `/api/sims/{id}/stream`
6. As `lus` writes events, sim_manager pipes lines through SSE
7. Page renders: nodes pulse on TX, arrows on RX, red on drops, yellow
   on tx_deferred. Side panel scrolls a stream of `script_log` and
   `script_emit` entries (the same human-readable trace we just added to
   `dv_dual_sf.lua` flows here)
8. Sim ends → `sim_end` event → page locks and shows "Replay" link to
   `visualize.html?id={id}`

## 9. Interactive mode

`interactive.html` is a thin browser layer on top of `lus -i`:

1. User pastes a scenario JSON or uploads a config file
2. Page POSTs to `/api/interactive/`, receives a session id
3. Page opens a WebSocket on `/api/interactive/{id}/ws`
4. User types REPL commands; backend writes to lus's stdin
5. lus stdout (a mix of "> " responses and NDJSON events) is split by
   `interactive_manager`: responses go back to the user's command box,
   events are persisted to `events.ndjson` AND broadcast to a
   subscribers list (so a separate map_live tab can mirror the same
   session live)
6. Idle timeout closes the session after N seconds of no command + no
   step

Same UX as meshcore_real_sim's interactive page; the only adaptation is
the command-set documentation panel — replace MeshCore commands with
lus's REPL commands (`step`, `run`, `cmd <node> <text>`, etc.).

## 10. Project structure (this phase)

```
lora-universal-simulator/
├── webapp/                       <-- new
│   ├── ARCHITECTURE.md
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── run.sh                    <-- start-uvicorn helper
│   ├── data/                     <-- gitignored
│   ├── server/
│   │   ├── main.py               (~80 lines, FastAPI app + lifespan)
│   │   ├── config.py             (~50 lines, settings)
│   │   ├── routers/
│   │   │   ├── simulations.py
│   │   │   └── interactive.py
│   │   ├── services/
│   │   │   ├── sim_manager.py
│   │   │   ├── event_index.py
│   │   │   ├── interactive_manager.py
│   │   │   └── config_validator.py   (rewritten)
│   │   └── models/
│   │       └── schemas.py            (pydantic models for lus schema)
│   └── static/
│       ├── css/common.css
│       ├── js/                       (per-page scripts)
│       ├── index.html
│       ├── simulations.html
│       ├── simulation.html
│       ├── visualize.html
│       ├── map_live.html
│       └── interactive.html
└── ... (existing dirs)
```

Topology-related files (`topologies.html`, `topology_editor.html`,
`topology_creator.html`, `routers/topologies.py`,
`routers/topo_creator.py`, `services/topo_generator.py`,
`services/topo_tools.py`) are not present in this phase. Their slots are
reserved by the next-phase spec.

## 11. Testing strategy

- **Backend unit tests** (Python pytest): config_validator (accepts lus
  schema, rejects MeshCore fields with clear messages), sim_manager
  (spawn → SSE → reap), event_index (slice by time range)
- **Integration test**: spawn the FastAPI app via httpx test client, POST
  a config, GET status until completed, fetch events, verify shape
- **Smoke test**: run the existing scenario `s01_dv_dual_sf.json` through
  the webapp; verify the SSE stream produces the same events the CLI
  produces, and the swim-lane replay renders without error

Frontend testing is by manual exercise — no headless browser tests
(YAGNI).

## 11.1 Existing CLI tools we preserve

The current `tools/visualize.py` + `tools/visualize.html` (offline,
no-server, NDJSON-embedded HTML viewer) **are kept as-is**. They remain
useful for sharing a one-shot run as a single self-contained file, and
they don't require a Python venv or running server. The webapp's
`visualize.html` is the more capable successor — but both coexist.

Likewise `lus` continues to work standalone from the CLI. The webapp is
an additive tool, not a replacement.

## 12. Out of scope (explicit YAGNI list)

- Parameter sweeps (drop the entire `sweep_runner` service and `sweep.html`
  page)
- Scenario editor / config editor pages
- MeshCore packet decoder, firmware roles, plugin system
- ITM terrain heightmap, MeshCore map API
- Authentication, multi-user, role-based access
- Real-time collaborative editing
- Mobile-responsive layout (desktop-only is fine)
- Headless browser tests

## 13. References

- `~/meshcore_real_sim/webapp/ARCHITECTURE.md` — source webapp shape
- `~/meshcore_real_sim/webapp/server/services/interactive_manager.py` —
  reference WebSocket/REPL plumbing
- `core/link/PathLossModel.cpp` — formula the Python topo_generator must
  replicate exactly
- `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md`
  — parent simulator design (event vocabulary in §10, runtime API in §7)
- `docs/Y2-todos.md` item 9 — original webapp port note
