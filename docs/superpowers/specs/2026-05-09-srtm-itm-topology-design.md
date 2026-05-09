# SRTM + ITM Terrain-Aware Topology — Design

Status: design (awaiting user review)
Author: 2026-05-09 session
Reference: `~/meshcore_real_sim/topology_generator/` (902-LOC Python
implementation we're porting parts of).

## Background

`scenarios/s02_seattle_*.json` and other lat/lon-based topologies
currently rely on `core/link/PathLossModel.cpp`'s log-distance model:
`loss_db = ref_loss + 10*alpha*log10(d/d_ref)`. This is statistical-
only and ignores terrain. Two real-world consequences:

- A 5 km link over flat ground and a 5 km link over a 200 m ridge
  get the same baseline SNR. The runtime sigma + coherence bolts
  shadow on top, but the median is wrong.
- Field-validated topologies (e.g., real Seattle nodes whose link
  budgets are obstructed by Capitol Hill) can't be reproduced
  faithfully from lat/lon alone.

`meshcore_real_sim/topology_generator/` solves this offline by
fetching SRTM elevation tiles, sampling the great-circle profile
between every node pair, and running ITM (Longley-Rice) via the
`itmlogic` Python package. The output is a static topology with
per-link SNR/RSSI accurate to the terrain.

This spec brings that capability to lus's webapp, layered with the
existing runtime statistical shadowing so users still see realistic
minute-to-minute variation on top of the terrain-aware median.

## Goal

Two webapp endpoints (and matching UI buttons) that compute terrain-
aware per-link SNR/RSSI from node lat/lon via SRTM + ITM:

1. **Generate** — `POST /api/topo-creator/generate-srtm`. Takes a
   bounding box (or explicit node list) plus ITM params; emits a
   complete topology JSON with `nodes[]` + `topology.links[]` where
   every reachable pair has a concrete `snr` and `rssi`. Same output
   shape as the existing `/generate-grid` and `/generate-random`
   endpoints, but the link values come from terrain rather than the
   log-distance formula.

2. **Refine** — `POST /api/topo-creator/refine-with-srtm`. Takes an
   existing scenario JSON (with `commands`, `expect`, `simulation`,
   `nodes` already authored). Recomputes `topology.links[]` from
   current `nodes[].lat`/`lon` via SRTM+ITM, preserving everything
   else verbatim. Lets a user iterate: tweak commands, then refresh
   the link physics from terrain without re-authoring the rest.

The runtime layered model is preserved: `simulation.path_loss.sigma_db`
and `asymmetry_coherence_ms` apply on top of the terrain-derived
`topology.links[].snr`/`rssi` baseline (existing PathLossModel
already does this — no orchestrator change required).

## Scope

- New webapp service: `webapp/server/services/topo_srtm.py`.
  ITM glue, SRTM fetch, terrain-profile sampler, parallel pair
  computation. Pure Python.
- Two new API endpoints in `webapp/server/routers/topo_creator.py`.
- New config fields propagated through both pydantic and C++
  validators (authoring-time only — runtime path-loss model
  ignores them).
- Frontend: one new button on `topology_creator.html`, one new
  button on `topology_editor.html`.
- Pytest coverage for the service module + endpoints (with mocked
  SRTM to keep CI offline).

## Out of scope

- Async / job-queue API. Sync only; documented N² cost (147-node
  Seattle ≈ 10 800 link computations ≈ minutes even parallelized).
  If a user hits it, they fall back to the offline
  `meshcore_real_sim/topology_generator` tool.
- Replacing the runtime log-distance model. ITM stays at config-
  time. The C++ `PathLossModel` still runs at simulation init for
  scenarios authored without explicit `topology.links` (or with the
  `model: "log_distance"` knob).
- Multi-frequency support. One frequency per topology; if the user
  needs to compare 433 MHz vs 868 MHz, they author two scenarios.
- Antenna pattern / polarization variation per node. Single
  polarization (vertical) for the whole computation.

## Config fields

`core/topology/JsonConfig.h` and `webapp/server/models/schemas.py`
both gain:

- `simulation.path_loss.frequency_mhz`: optional float, default
  `868.0`. Used by ITM. The runtime model ignores it (it's an
  authoring-time field). Validated `> 0`.
- `nodes[].antenna_height_m`: optional float, default `1.5`. Used by
  ITM. The runtime model ignores it. Validated `>= 0`.

Default values match meshcore_real_sim's defaults: 868 MHz EU LoRa,
1.5 m antenna typical for handheld nodes. Operators with rooftop
gateways set per-node values to e.g. `antenna_height_m: 10`.

Both fields are absent from existing topologies; defaults preserve
today's behavior. Round-tripping a saved-then-loaded topology
preserves any operator-set values.

## API endpoints

### `POST /api/topo-creator/generate-srtm`

Request body:

```json
{
  "nodes": [
    {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 10.0},
    ...
  ],
  "path_loss": {
    "frequency_mhz": 868.0,
    "tx_power_dbm": 14.0,
    "noise_floor_db": -120.0,
    "ref_distance_m": 1.0,
    "ref_loss_db": 40.0
  },
  "itm": {
    "climate": 6,
    "polarization": 1,
    "ground_permittivity": 15.0,
    "ground_conductivity": 0.005,
    "surface_refractivity": 314.0,
    "min_snr_db": -20.0,
    "max_links_per_node": 8,
    "profile_resolution_m": 90.0
  }
}
```

Response:

```json
{
  "nodes": [...],
  "topology": {
    "links": [
      {"from": "alice", "to": "bob", "snr": 8.3, "rssi": -78.4, "bidir": true},
      ...
    ]
  },
  "computed_at_ms": 12450,
  "n_pairs_evaluated": 1326,
  "n_links_kept": 387,
  "n_srtm_misses": 2
}
```

`min_snr_db` filters out below-threshold pairs (below the SF12 demod
floor with margin). `max_links_per_node` caps fan-out (8 matches
meshcore_real_sim default). `profile_resolution_m` is the
elevation-sample spacing along each link's great-circle path; 90 m
matches SRTM-3's native resolution.

`bidir: true` is emitted only when |snr_AB − snr_BA| ≤ 1 dB AND
both directions cleared `min_snr_db`. Asymmetric pairs emit two
directed entries with `bidir: false`.

### `POST /api/topo-creator/refine-with-srtm`

Request body (full scenario JSON — same shape `/api/topologies` POST
accepts):

```json
{
  "scenario": {
    "_name": "...",
    "simulation": {...},
    "nodes": [...],
    "topology": {"links": []},
    "commands": [...],
    "expect": [...]
  },
  "itm": { ... same fields as above ... }
}
```

Response: full scenario JSON with `topology.links[]` replaced by the
ITM-computed result. Other fields preserved verbatim. The same
summary stats (`n_pairs_evaluated`, etc.) are returned alongside
the scenario.

If the request scenario lacks `simulation.path_loss.frequency_mhz`
or any node's `antenna_height_m`, defaults from the spec's "Config
fields" section apply.

## Implementation outline

### `webapp/server/services/topo_srtm.py` (~250 LOC)

```python
def haversine_km(lat1, lon1, lat2, lon2) -> float: ...

def intermediate_point(lat1, lon1, lat2, lon2, fraction) -> (float, float):
    # Great-circle midpoint sampler (used for terrain profiles).

def get_elevation_data(cache_dir=None) -> srtm.GeoElevationData: ...

def sample_elevation_profile(srtm_data, lat1, lon1, lat2, lon2,
                              num_pts) -> list[float]:
    # Returns N elevation samples along the great-circle path.
    # Returns None if any point misses SRTM coverage.

def fspl_db(distance_km, freq_mhz) -> float: ...

def noise_floor_dbm(bandwidth_hz, noise_figure_db=6.0) -> float: ...

def compute_link_itm(profile_m, distance_km, freq_mhz,
                     antenna_heights_m, climate, polarization,
                     ...) -> dict:
    # Wraps itmlogic's qlrps + qlrpfl + avar; returns
    # {loss_median_db, loss_10pct_db, loss_90pct_db, kwx}.

def compute_pair_link(node_a, node_b, srtm_data, params) -> dict | None:
    # Sample profile + run ITM + convert loss to SNR/RSSI.
    # Returns None if SRTM miss or below min_snr.

def compute_link_matrix(nodes, params, max_workers=4) -> list[dict]:
    # ProcessPoolExecutor over pairs. Skips pairs below min_snr.
    # Caps to max_links_per_node by retaining top-N strongest.
    # Mirrors meshcore_real_sim/__main__.py:_compute_link_worker
    # pattern.
```

ITM glue mirrors `meshcore_real_sim/topology_generator/propagation.py`
verbatim (the math is the same; the only delta is endpoint shape).

### `webapp/server/routers/topo_creator.py` additions (~80 LOC)

Two new pydantic request models (`GenerateSrtmRequest`,
`RefineWithSrtmRequest`), two new handler functions calling into
`topo_srtm.compute_link_matrix`. Error responses on:
- SRTM data unavailable (offline / network) → 503
- All pairs below `min_snr_db` → 200 with empty `links[]` + warning
- `itmlogic` import failure (missing dep) → 500 with install hint

### Pydantic schema additions (~15 LOC)

```python
# webapp/server/models/schemas.py
class PathLossConfig(BaseModel):
    ...  # existing fields
    frequency_mhz: Optional[float] = Field(default=None, gt=0.0)

class NodeConfig(BaseModel):
    ...  # existing fields
    antenna_height_m: Optional[float] = Field(default=None, ge=0.0)
```

### C++ JsonConfig additions (~10 LOC)

`core/topology/JsonConfig.h`:
```cpp
struct PathLossSpec {
    ...
    double frequency_mhz = 868.0;  // authoring-time, runtime ignores
};

struct NodeDef {
    ...
    float antenna_height_m = 1.5f;  // authoring-time, runtime ignores
};
```

`core/topology/JsonConfig.cpp`: parse both, validate `> 0` for
frequency and `>= 0` for antenna height.

### Frontend (~60 LOC)

- `topology_creator.html`: new "Compute via SRTM+ITM" button next to
  the existing "Preview SNR". On click, shows a modal with ITM
  params (climate, antenna heights, etc., pre-filled from defaults),
  fires `POST /api/topo-creator/generate-srtm`, populates the link
  table with the result.
- `topology_editor.html`: new "Recompute links from terrain" button.
  Fires `POST /api/topo-creator/refine-with-srtm` with the current
  scenario JSON, replaces `topology.links[]` in the editor.
- Both show a spinner with "Computing N×N matrix…" while waiting.
  No progress bar (sync API).

## Tests

### Pytest — service module

`webapp/tests/test_topo_srtm.py`:

1. `test_haversine_km` — known-distance check (Seattle to Tacoma ≈
   45 km).
2. `test_fspl_db` — known-FSPL check (1 km @ 868 MHz ≈ 91.2 dB).
3. `test_compute_link_itm_flat_terrain` — feed a flat profile,
   expect ITM excess attenuation ≈ 0.
4. `test_compute_link_itm_obstructed` — feed a profile with a 200 m
   peak between two 1.5 m antennas at 5 km, expect ITM excess
   attenuation ≥ 30 dB.
5. `test_compute_link_matrix_3_nodes` — small 3-node case with a
   mock SRTM data source returning canned elevations; verify all
   three pair entries appear in the output.

### Pytest — endpoints

`webapp/tests/test_topo_srtm_endpoints.py`:

1. `test_generate_srtm_basic` — POST with 3 nodes, mock SRTM,
   assert response shape (nodes + topology.links + computed_at_ms).
2. `test_refine_with_srtm_preserves_other_fields` — POST a scenario
   with commands and expect block; assert only `topology.links` is
   different in the response.
3. `test_generate_srtm_missing_srtm_returns_503` — mock SRTM raise
   on fetch; assert 503 with install hint.
4. `test_refine_with_srtm_uses_path_loss_defaults` — POST without
   `frequency_mhz` set; assert it falls back to 868.0.

### Integration

No new C++ integration test — the schema additions are accepted
silently by the runtime (frequency_mhz / antenna_height_m read but
not used). Existing 33/33 should remain green.

## Risks

- **`itmlogic` external dep.** Already in the user's venv; pin
  exact version in `webapp/requirements.txt` so the test environment
  matches. If CI runs without it, pytest skips with an explanatory
  message (mirror the `pytest.skip` pattern used in
  `test_warmup_end_event.py` for the lus binary).
- **`srtm` data fetch is network-bound.** First request hits the
  internet; tiles cache to `~/.cache/srtm/`. Document in the spec
  that the first run on a fresh machine needs network. Mock in
  tests so CI is offline.
- **N² compute for dense scenarios.** 147-node Seattle = 10 731
  pair computations. With ITM ≈ 30 ms/pair on commodity hardware,
  serial = 5+ minutes. ProcessPoolExecutor with 8 workers brings
  it to ~40 s; tolerable for sync HTTP. For 500+ nodes, document
  the offline tools/topology_from_srtm.py path as the escape hatch.
- **`max_links_per_node` is a per-node cap, not a global pruning
  guarantee.** Meshcore_real_sim takes the strongest N edges per
  node by SNR. We mirror that. Two corner cases: (a) ties at the
  cap can produce slightly non-deterministic edge sets — document
  + sort by (snr desc, dest_id asc) as the tie-breaker. (b) an edge
  may be in node A's top-N but not in node B's; we still emit it
  (avoids dropping marginal-but-real links).

## Acceptance criteria

- `POST /api/topo-creator/generate-srtm` works on a 3-node example
  scenario, returns sane numbers (e.g., flat-terrain SNR within
  1 dB of FSPL-only baseline).
- `POST /api/topo-creator/refine-with-srtm` preserves
  `simulation.commands`, `simulation.warmup_ms`, `expect[]`, etc.,
  changing only `topology.links[]`.
- Pytest cases 1-9 above pass.
- Existing 33/33 integration tests stay green.
- Existing webapp pytest suite stays green.
- A 50-node test scenario completes in under 30 seconds wallclock
  (with default 4 workers).
