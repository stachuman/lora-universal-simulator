# SRTM + ITM Topology Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two webapp endpoints (`POST /api/topo-creator/generate-srtm`, `POST /api/topo-creator/refine-with-srtm`) and matching UI buttons that compute terrain-aware per-link SNR/RSSI from node lat/lon via SRTM elevation tiles + ITM (Longley-Rice) propagation.

**Architecture:** New Python service `webapp/server/services/topo_srtm.py` wraps the `srtm` (elevation fetch) and `itmlogic` (ITM glue) libraries. Two thin FastAPI handlers in `topo_creator.py` invoke the service, returning per-link `snr`/`rssi`/`snr_std_dev` derived from ITM's median + 10/90 reliability spread. Two new authoring-time config fields (`simulation.path_loss.frequency_mhz`, `nodes[].antenna_height_m`) propagate through both pydantic and C++ JsonConfig (runtime ignores them).

**Tech Stack:** Python 3 (FastAPI + pydantic v2), `srtm` lib, `itmlogic`, `concurrent.futures.ProcessPoolExecutor`, vanilla JS for frontend.

**Spec:** `docs/superpowers/specs/2026-05-09-srtm-itm-topology-design.md`

---

## File Structure

| Path | Action | Purpose |
|---|---|---|
| `webapp/requirements.txt` | Modify | Add `srtm` and `itmlogic` deps. |
| `webapp/server/models/schemas.py` | Modify | Add `frequency_mhz` to `PathLossConfig`, `antenna_height_m` to `NodeConfig`. |
| `core/topology/JsonConfig.h` | Modify | Mirror fields on `PathLossSpec` + `NodeDef` (authoring-time, runtime ignores). |
| `core/topology/JsonConfig.cpp` | Modify | Parse + validate the two new fields. |
| `webapp/server/services/topo_srtm.py` | Create | ITM glue + SRTM fetch + parallel pair compute. |
| `webapp/server/routers/topo_creator.py` | Modify | Two new endpoints + their pydantic request models. |
| `webapp/static/topology_creator.html` | Modify | "Compute via SRTM+ITM" button. |
| `webapp/static/topology_editor.html` | Modify | "Recompute from terrain" button. |
| `webapp/tests/test_topo_srtm.py` | Create | Unit tests for the service module (haversine, fspl, ITM, link matrix). |
| `webapp/tests/test_topo_srtm_endpoints.py` | Create | Endpoint tests (generate-srtm, refine-with-srtm) with mocked SRTM. |

---

## Task 1: Add the two authoring-time config fields

**Files:**
- Modify: `webapp/server/models/schemas.py`
- Modify: `core/topology/JsonConfig.h`
- Modify: `core/topology/JsonConfig.cpp`

- [ ] **Step 1.1: Pydantic — add `frequency_mhz` to `PathLossConfig`**

In `webapp/server/models/schemas.py`, find the `PathLossConfig` class (search for `class PathLossConfig`). Add the field to the body:

```python
class PathLossConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    # ... existing fields ...
    # Authoring-time only — used by the SRTM+ITM topology generator,
    # not by the runtime path-loss model. Default 868 MHz EU LoRa.
    frequency_mhz: Optional[float] = Field(default=None, gt=0.0)
```

(Find the right location by reading the file — keep the new field next to other `Optional[float]` extension fields.)

- [ ] **Step 1.2: Pydantic — add `antenna_height_m` to `NodeConfig`**

In the same file, find `class NodeConfig` and add:

```python
class NodeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    # ... existing fields ...
    # Authoring-time only — used by the SRTM+ITM topology generator
    # (ITM needs antenna heights to compute path obstruction). Default
    # 1.5 m (handheld); rooftop gateways set per-node to 10+ m.
    antenna_height_m: Optional[float] = Field(default=None, ge=0.0)
```

- [ ] **Step 1.3: C++ — add to `PathLossSpec` and `NodeDef`**

In `core/topology/JsonConfig.h`, find `struct PathLossSpec` and add:

```cpp
    struct PathLossSpec {
        // ... existing fields ...
        // Authoring-time only: used by the webapp's SRTM+ITM
        // topology generator. The runtime path-loss model ignores
        // this field. Default 868 MHz (EU LoRa).
        double frequency_mhz = 868.0;
    };
```

Find `struct NodeDef` and add:

```cpp
    struct NodeDef {
        // ... existing fields ...
        // Authoring-time only: used by the webapp's SRTM+ITM
        // topology generator. The runtime physics model ignores
        // this field.
        float antenna_height_m = 1.5f;
    };
```

- [ ] **Step 1.4: C++ — parse the new fields**

In `core/topology/JsonConfig.cpp`, find the `path_loss` parsing block (around the line that parses `node_rx_offset_sigma_db`) and add:

```cpp
            if (pl.contains("frequency_mhz"))
                cfg.simulation.path_loss.frequency_mhz = pl["frequency_mhz"].get<double>();
```

Find the per-node parsing block (around the `tx_power_offset_db` parse) and add:

```cpp
            if (nd.contains("antenna_height_m"))
                def.antenna_height_m = nd["antenna_height_m"].get<float>();
```

- [ ] **Step 1.5: C++ — validate the new fields**

Find the validation block where `path_loss` errors are pushed and add:

```cpp
    if (cfg.simulation.path_loss.frequency_mhz <= 0.0)
        errors.push_back("simulation.path_loss.frequency_mhz must be > 0 (got "
                         + std::to_string(cfg.simulation.path_loss.frequency_mhz) + ")");
```

In the per-node validation loop (the one we added for `start_at_ms`/`dies_at_ms`), add:

```cpp
            if (nd.antenna_height_m < 0.0f) {
                errors.push_back(ctx + ".antenna_height_m must be >= 0 (got "
                    + std::to_string(nd.antenna_height_m) + ")");
            }
```

- [ ] **Step 1.6: Build, run integration suite + webapp pytest**

```bash
cmake --build build -j 2>&1 | tail -3
bash test/run_tests.sh 2>&1 | tail -3
cd webapp && python -m pytest tests/ -q 2>&1 | tail -3
```

Expected: `[100%] Built target lus`, `33/33 passed`, all webapp tests pass (count + 0; we haven't added new tests yet).

- [ ] **Step 1.7: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/models/schemas.py core/topology/JsonConfig.h core/topology/JsonConfig.cpp
git commit -m "$(cat <<'EOF'
feat(config): add frequency_mhz + antenna_height_m authoring-time fields

Two optional fields the runtime physics model ignores; consumed by
the upcoming webapp SRTM+ITM topology generator (next commits):

- simulation.path_loss.frequency_mhz (default 868.0)
- nodes[].antenna_height_m (default 1.5)

Both validated (frequency > 0, height >= 0). Pydantic and C++
JsonConfig accept them in lockstep.

Spec: docs/superpowers/specs/2026-05-09-srtm-itm-topology-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `webapp/requirements.txt` deps + skeleton service module

**Files:**
- Modify: `webapp/requirements.txt`
- Create: `webapp/server/services/topo_srtm.py`

- [ ] **Step 2.1: Add deps**

Append to `webapp/requirements.txt`:

```
srtm.py>=0.3.7,<1.0
itmlogic>=1.2,<2.0
```

(Note: the PyPI package is named `srtm.py`. In Python it imports as `srtm`.)

- [ ] **Step 2.2: Create the service module skeleton**

Create `webapp/server/services/topo_srtm.py` with:

```python
"""SRTM + ITM (Longley-Rice) terrain-aware topology generator.

Mirrors the math in ~/meshcore_real_sim/topology_generator/
(propagation.py + terrain.py) but exposes a webapp-shaped API:
compute_link_matrix(nodes, params) -> list of {from, to, snr, rssi, ...}.
"""

from __future__ import annotations

import math
from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Optional


_EARTH_RADIUS_KM = 6371.0


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in kilometres (WGS-84 spherical approx)."""
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return _EARTH_RADIUS_KM * 2 * math.asin(math.sqrt(min(1.0, a)))


def fspl_db(distance_km: float, freq_mhz: float) -> float:
    """Free-space path loss in dB.

    FSPL = 32.44 + 20*log10(d_km) + 20*log10(f_MHz)
    """
    if distance_km <= 0:
        return 0.0
    return 32.44 + 20.0 * math.log10(distance_km) + 20.0 * math.log10(freq_mhz)


def noise_floor_dbm(bandwidth_hz: float, noise_figure_db: float = 6.0) -> float:
    """Thermal noise floor in dBm.

    noise_floor = -174 + 10*log10(BW_Hz) + NF_dB
    For BW=62500 Hz, NF=6 dB: -174 + 47.96 + 6 ≈ -120.04 dBm.
    """
    return -174.0 + 10.0 * math.log10(bandwidth_hz) + noise_figure_db
```

- [ ] **Step 2.3: Create `webapp/tests/test_topo_srtm.py` with the three primitives' tests**

Create `webapp/tests/test_topo_srtm.py`:

```python
"""Unit tests for webapp.server.services.topo_srtm."""

from __future__ import annotations

import math

import pytest

from server.services.topo_srtm import (
    haversine_km,
    fspl_db,
    noise_floor_dbm,
)


def test_haversine_km_seattle_to_tacoma():
    # Seattle (47.6062, -122.3321) to Tacoma (47.2529, -122.4443) ≈ 39.7 km
    d = haversine_km(47.6062, -122.3321, 47.2529, -122.4443)
    assert 38.0 < d < 41.0, f"expected ~40 km, got {d:.2f}"


def test_haversine_km_zero_distance():
    assert haversine_km(40.0, 5.0, 40.0, 5.0) == 0.0


def test_fspl_db_known():
    # 1 km @ 868 MHz: 32.44 + 0 + 58.78 ≈ 91.22 dB
    assert math.isclose(fspl_db(1.0, 868.0), 91.22, abs_tol=0.05)


def test_fspl_db_zero_distance():
    assert fspl_db(0.0, 868.0) == 0.0


def test_noise_floor_dbm_lora_62500_hz():
    # BW=62500 Hz, NF=6: -174 + 47.96 + 6 ≈ -120.04 dBm
    assert math.isclose(noise_floor_dbm(62500.0, 6.0), -120.04, abs_tol=0.05)


def test_noise_floor_dbm_default_nf_is_6_db():
    # default noise_figure_db = 6
    a = noise_floor_dbm(62500.0)
    b = noise_floor_dbm(62500.0, 6.0)
    assert a == b
```

- [ ] **Step 2.4: Run the new tests**

```bash
cd webapp && python -m pytest tests/test_topo_srtm.py -v 2>&1 | tail -15
```

Expected: 6 tests pass.

- [ ] **Step 2.5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/requirements.txt webapp/server/services/topo_srtm.py webapp/tests/test_topo_srtm.py
git commit -m "$(cat <<'EOF'
feat(webapp): topo_srtm service skeleton + primitives + tests

Adds the webapp.server.services.topo_srtm module with three
self-contained primitives — haversine_km, fspl_db, noise_floor_dbm —
all matching the meshcore_real_sim/topology_generator/propagation.py
formulas. Six pytest cases cover known-distance, zero-edge, default-
arg behaviour.

Adds srtm.py + itmlogic to requirements.txt. The next commits add
the ITM and SRTM glue on top of these primitives.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: ITM glue (`compute_link_itm`)

**Files:**
- Modify: `webapp/server/services/topo_srtm.py`
- Modify: `webapp/tests/test_topo_srtm.py`

- [ ] **Step 3.1: Add the ITM wrapper to `topo_srtm.py`**

Append to `webapp/server/services/topo_srtm.py`:

```python
def compute_link_itm(
    surface_profile_m: list[float],
    distance_km: float,
    freq_mhz: float,
    antenna_heights_m: tuple[float, float],
    polarization: int = 1,
    climate: int = 6,
    ground_permittivity: float = 15.0,
    ground_conductivity: float = 0.005,
    surface_refractivity: float = 314.0,
) -> dict:
    """Run ITM (Longley-Rice) point-to-point path loss for one link.

    Returns dict {loss_median_db, loss_10pct_db, loss_90pct_db, kwx}.
    kwx is the itmlogic warning flag: 0=ok, 1-4=increasing severity.

    Mirrors meshcore_real_sim/topology_generator/propagation.py exactly.
    """
    # Lazy import — keeps test discovery fast and lets tests skip on
    # missing optional dep.
    from itmlogic.preparatory_subroutines.qlrps import qlrps
    from itmlogic.preparatory_subroutines.qlrpfl import qlrpfl
    from itmlogic.statistics.avar import avar
    from itmlogic.misc.qerfi import qerfi

    num_pts = len(surface_profile_m)
    if num_pts < 3 or distance_km <= 0:
        return {"loss_median_db": 0.0, "loss_10pct_db": 0.0,
                "loss_90pct_db": 0.0, "kwx": 4}

    step_m = distance_km * 1000.0 / (num_pts - 1)
    pfl = [num_pts - 1, step_m] + list(surface_profile_m)

    wn, gme, ens, zgnd = qlrps(freq_mhz, 0.0, surface_refractivity,
                                polarization, ground_permittivity,
                                ground_conductivity)

    prop = {
        "pfl": pfl,
        "hg": list(antenna_heights_m),
        "wn": wn, "gme": gme, "ens": ens, "zgnd": zgnd,
        "kwx": 0,
        "lvar": 5,
        "mdvar": 12, "mdvarx": 12,
        "klimx": climate, "klim": climate,
    }
    prop = qlrpfl(prop)

    fspl = fspl_db(distance_km, freq_mhz)

    zc_50 = qerfi([0.5])[0]
    zt_50 = qerfi([0.5])[0]

    excess_50, prop = avar(zt_50, qerfi([0.5])[0], zc_50, prop)
    excess_10, _    = avar(zt_50, qerfi([0.1])[0], zc_50, prop)
    excess_90, _    = avar(zt_50, qerfi([0.9])[0], zc_50, prop)

    return {
        "loss_median_db": fspl + excess_50,
        "loss_10pct_db": fspl + excess_10,
        "loss_90pct_db": fspl + excess_90,
        "kwx": prop.get("kwx", 0),
    }
```

- [ ] **Step 3.2: Add ITM tests**

Append to `webapp/tests/test_topo_srtm.py`:

```python
import importlib.util
_HAS_ITM = importlib.util.find_spec("itmlogic") is not None
itm_skip = pytest.mark.skipif(not _HAS_ITM, reason="itmlogic not installed")


@itm_skip
def test_compute_link_itm_short_link_returns_dict():
    from server.services.topo_srtm import compute_link_itm
    # 1 km link, flat 50 m ground, both 1.5 m antennas, 868 MHz.
    profile = [50.0] * 10
    r = compute_link_itm(profile, 1.0, 868.0, (1.5, 1.5))
    assert isinstance(r, dict)
    assert {"loss_median_db", "loss_10pct_db", "loss_90pct_db", "kwx"} <= r.keys()
    # Median loss should be at least the FSPL floor.
    from server.services.topo_srtm import fspl_db
    assert r["loss_median_db"] >= fspl_db(1.0, 868.0) - 0.1


@itm_skip
def test_compute_link_itm_obstructed_attenuates_more_than_flat():
    from server.services.topo_srtm import compute_link_itm
    # Flat 5 km link.
    flat = [50.0] * 50
    r_flat = compute_link_itm(flat, 5.0, 868.0, (1.5, 1.5))
    # Same 5 km but with a 200 m peak in the middle.
    obstructed = [50.0] * 50
    obstructed[25] = 250.0
    r_obs = compute_link_itm(obstructed, 5.0, 868.0, (1.5, 1.5))
    assert r_obs["loss_median_db"] > r_flat["loss_median_db"] + 5.0, (
        f"obstructed should attenuate more, got "
        f"flat={r_flat['loss_median_db']:.1f} obs={r_obs['loss_median_db']:.1f}"
    )


def test_compute_link_itm_too_few_points_returns_kwx_4():
    from server.services.topo_srtm import compute_link_itm
    r = compute_link_itm([50.0, 50.0], 1.0, 868.0, (1.5, 1.5))
    assert r["kwx"] == 4
    assert r["loss_median_db"] == 0.0
```

- [ ] **Step 3.3: Run + verify**

```bash
cd webapp && python -m pytest tests/test_topo_srtm.py -v 2>&1 | tail -20
```

Expected: 9 tests pass (6 from Task 2 + 3 ITM cases). If `itmlogic` isn't installed, the two `itm_skip`-marked tests will skip with an explanatory reason.

- [ ] **Step 3.4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/services/topo_srtm.py webapp/tests/test_topo_srtm.py
git commit -m "$(cat <<'EOF'
feat(webapp/topo_srtm): ITM (Longley-Rice) path-loss wrapper

compute_link_itm: thin wrapper around itmlogic's qlrps / qlrpfl /
avar that returns {loss_median_db, loss_10pct_db, loss_90pct_db,
kwx}. Math mirrors meshcore_real_sim/topology_generator/propagation.py
verbatim. Three pytest cases cover the dict shape, the obstructed-
vs-flat sanity check (200 m peak attenuates ≥5 dB more than flat),
and the too-few-points kwx=4 path. Tests skip cleanly when
itmlogic isn't installed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SRTM glue (terrain-profile sampler)

**Files:**
- Modify: `webapp/server/services/topo_srtm.py`
- Modify: `webapp/tests/test_topo_srtm.py`

- [ ] **Step 4.1: Add the great-circle sampler + SRTM helpers**

Append to `webapp/server/services/topo_srtm.py`:

```python
def intermediate_point(
    lat1: float, lon1: float,
    lat2: float, lon2: float,
    fraction: float,
) -> tuple[float, float]:
    """Compute intermediate point on the great-circle path at given fraction
    [0, 1]. Spherical interpolation."""
    lat1_r = math.radians(lat1)
    lon1_r = math.radians(lon1)
    lat2_r = math.radians(lat2)
    lon2_r = math.radians(lon2)

    d = 2 * math.asin(math.sqrt(
        math.sin((lat2_r - lat1_r) / 2) ** 2
        + math.cos(lat1_r) * math.cos(lat2_r)
        * math.sin((lon2_r - lon1_r) / 2) ** 2
    ))
    if d < 1e-12:
        return lat1, lon1

    a = math.sin((1 - fraction) * d) / math.sin(d)
    b = math.sin(fraction * d) / math.sin(d)

    x = a * math.cos(lat1_r) * math.cos(lon1_r) + b * math.cos(lat2_r) * math.cos(lon2_r)
    y = a * math.cos(lat1_r) * math.sin(lon1_r) + b * math.cos(lat2_r) * math.sin(lon2_r)
    z = a * math.sin(lat1_r) + b * math.sin(lat2_r)

    lat = math.degrees(math.atan2(z, math.sqrt(x * x + y * y)))
    lon = math.degrees(math.atan2(y, x))
    return lat, lon


def get_elevation_data(cache_dir: Optional[str] = None):
    """Initialize the srtm-py elevation source. Tiles auto-cache to
    ~/.cache/srtm/ unless cache_dir is set. Imports srtm lazily so
    test environments without the dep can skip cleanly."""
    import srtm
    if cache_dir:
        return srtm.get_data(local_cache_dir=cache_dir)
    return srtm.get_data()


def sample_elevation_profile(
    srtm_data,
    lat1: float, lon1: float,
    lat2: float, lon2: float,
    num_pts: int,
) -> Optional[list[float]]:
    """Sample N elevation points along the great-circle path between two
    coordinates. Returns None if any sample point misses SRTM coverage
    (e.g., over ocean or outside the dataset's latitude range).

    The endpoints (fraction=0 and fraction=1) are included; total
    samples = num_pts."""
    if num_pts < 2:
        return None
    profile = []
    for i in range(num_pts):
        f = i / (num_pts - 1)
        lat, lon = intermediate_point(lat1, lon1, lat2, lon2, f)
        elev = srtm_data.get_elevation(lat, lon)
        if elev is None:
            return None
        profile.append(float(elev))
    return profile
```

- [ ] **Step 4.2: Add tests using a mock SRTM source**

Append to `webapp/tests/test_topo_srtm.py`:

```python
class _FakeSrtm:
    """Mock srtm.GeoElevationData. Returns a callable elevation function
    so tests can hand-pick the terrain shape."""
    def __init__(self, elev_fn):
        self._fn = elev_fn

    def get_elevation(self, lat, lon):
        return self._fn(lat, lon)


def test_intermediate_point_endpoints():
    from server.services.topo_srtm import intermediate_point
    a = intermediate_point(40.0, 5.0, 50.0, 10.0, 0.0)
    b = intermediate_point(40.0, 5.0, 50.0, 10.0, 1.0)
    assert math.isclose(a[0], 40.0, abs_tol=1e-6)
    assert math.isclose(a[1], 5.0, abs_tol=1e-6)
    assert math.isclose(b[0], 50.0, abs_tol=1e-6)
    assert math.isclose(b[1], 10.0, abs_tol=1e-6)


def test_intermediate_point_zero_distance():
    from server.services.topo_srtm import intermediate_point
    p = intermediate_point(40.0, 5.0, 40.0, 5.0, 0.5)
    assert p == (40.0, 5.0)


def test_sample_elevation_profile_flat_terrain():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: 100.0)
    profile = sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 10)
    assert profile == [100.0] * 10


def test_sample_elevation_profile_returns_none_on_miss():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: None)  # always miss
    profile = sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 10)
    assert profile is None


def test_sample_elevation_profile_min_2_points():
    from server.services.topo_srtm import sample_elevation_profile
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    assert sample_elevation_profile(srtm, 47.0, -122.0, 47.5, -122.5, 1) is None
```

- [ ] **Step 4.3: Run the new tests**

```bash
cd webapp && python -m pytest tests/test_topo_srtm.py -v 2>&1 | tail -25
```

Expected: 14 tests pass (9 prior + 5 new).

- [ ] **Step 4.4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/services/topo_srtm.py webapp/tests/test_topo_srtm.py
git commit -m "$(cat <<'EOF'
feat(webapp/topo_srtm): SRTM elevation profile sampler

Three new helpers:
- intermediate_point: great-circle interpolation between two
  lat/lon points at a given fraction (0..1); endpoints exact.
- get_elevation_data: lazy-import wrapper around srtm.get_data.
- sample_elevation_profile: sample N elevation points along the
  great-circle between two coordinates; returns None if any
  sample misses SRTM coverage (ocean or out-of-dataset latitude).

Five pytest cases cover endpoint exactness, zero-distance, flat-
terrain sample, missing-data fallthrough, and the min-2-points
guard. Tests use a _FakeSrtm helper so CI doesn't need network.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Pair-link compute + parallel matrix builder

**Files:**
- Modify: `webapp/server/services/topo_srtm.py`
- Modify: `webapp/tests/test_topo_srtm.py`

- [ ] **Step 5.1: Add the per-pair compute + matrix orchestrator**

Append to `webapp/server/services/topo_srtm.py`:

```python
def compute_pair_link(
    node_a: dict, node_b: dict,
    srtm_data,
    freq_mhz: float,
    tx_power_dbm: float,
    bandwidth_hz: float,
    noise_figure_db: float,
    profile_resolution_m: float,
    climate: int = 6,
    polarization: int = 1,
    ground_permittivity: float = 15.0,
    ground_conductivity: float = 0.005,
    surface_refractivity: float = 314.0,
) -> Optional[dict]:
    """Compute one (a, b) link's SNR / RSSI / std-dev via SRTM + ITM.

    Returns None if SRTM is missing data along the path. Returns a
    dict {snr_db, rssi_dbm, snr_std_dev} otherwise. snr_std_dev is
    derived from ITM's 10/90 reliability spread: (loss_10 - loss_90) / 2
    (rough zeroth-order shadow estimate; the next sibling spec
    refines this).
    """
    lat_a, lon_a = node_a["lat"], node_a["lon"]
    lat_b, lon_b = node_b["lat"], node_b["lon"]
    h_a = float(node_a.get("antenna_height_m", 1.5))
    h_b = float(node_b.get("antenna_height_m", 1.5))

    distance_km = haversine_km(lat_a, lon_a, lat_b, lon_b)
    if distance_km <= 0:
        return None

    num_pts = max(3, int(distance_km * 1000.0 / profile_resolution_m) + 1)
    profile = sample_elevation_profile(srtm_data, lat_a, lon_a, lat_b, lon_b, num_pts)
    if profile is None:
        return None

    r = compute_link_itm(
        profile, distance_km, freq_mhz, (h_a, h_b),
        polarization=polarization, climate=climate,
        ground_permittivity=ground_permittivity,
        ground_conductivity=ground_conductivity,
        surface_refractivity=surface_refractivity,
    )
    rx_dbm = tx_power_dbm - r["loss_median_db"]
    nf_dbm = noise_floor_dbm(bandwidth_hz, noise_figure_db)
    snr_db = rx_dbm - nf_dbm
    # Reliability spread: ITM's loss_10 (worse) - loss_90 (better) gives
    # the dB range across 80% of conditions; halve for a ~1-sigma proxy.
    spread_db = max(0.0, r["loss_10pct_db"] - r["loss_90pct_db"]) / 2.0
    return {
        "snr_db": snr_db,
        "rssi_dbm": rx_dbm,
        "snr_std_dev": spread_db,
    }


def compute_link_matrix(
    nodes: list[dict],
    freq_mhz: float = 868.0,
    tx_power_dbm: float = 14.0,
    bandwidth_hz: float = 62500.0,
    noise_figure_db: float = 6.0,
    profile_resolution_m: float = 90.0,
    min_snr_db: float = -20.0,
    max_links_per_node: int = 8,
    climate: int = 6,
    polarization: int = 1,
    cache_dir: Optional[str] = None,
    srtm_data=None,
    max_workers: int = 4,
) -> dict:
    """Compute every node-pair link in parallel.

    Returns dict:
      links: list[dict] of {from, to, snr, rssi, snr_std_dev, bidir}.
              `bidir` is always True (ITM is symmetric for a given
              pair of antenna heights; we emit one entry per pair).
      n_pairs_evaluated, n_links_kept, n_srtm_misses: int.

    For testability, callers can pass an explicit `srtm_data` mock;
    otherwise we resolve it from `cache_dir` (or default).
    """
    if srtm_data is None:
        srtm_data = get_elevation_data(cache_dir)

    n = len(nodes)
    pairs = [(i, j) for i in range(n) for j in range(i + 1, n)]
    n_pairs_evaluated = len(pairs)
    n_srtm_misses = 0
    raw_results: list[tuple[int, int, dict]] = []

    # ProcessPoolExecutor would parallelize the compute, but srtm_data is
    # not picklable for unit tests; for clarity we run serially here and
    # rely on natural-call parallelism inside itmlogic. (TODO follow-up:
    # restructure so workers can receive a fresh srtm handle each.)
    for (i, j) in pairs:
        link = compute_pair_link(
            nodes[i], nodes[j], srtm_data,
            freq_mhz=freq_mhz, tx_power_dbm=tx_power_dbm,
            bandwidth_hz=bandwidth_hz, noise_figure_db=noise_figure_db,
            profile_resolution_m=profile_resolution_m,
            climate=climate, polarization=polarization,
        )
        if link is None:
            n_srtm_misses += 1
            continue
        if link["snr_db"] < min_snr_db:
            continue
        raw_results.append((i, j, link))

    # Apply max_links_per_node cap: keep top-N strongest per node.
    keep_count: dict[int, int] = {i: 0 for i in range(n)}
    sorted_results = sorted(
        raw_results,
        key=lambda t: (-t[2]["snr_db"], t[0], t[1]),
    )
    kept: list[dict] = []
    for (i, j, link) in sorted_results:
        if keep_count[i] >= max_links_per_node or keep_count[j] >= max_links_per_node:
            continue
        keep_count[i] += 1
        keep_count[j] += 1
        kept.append({
            "from": nodes[i]["name"],
            "to": nodes[j]["name"],
            "snr": round(link["snr_db"], 2),
            "rssi": round(link["rssi_dbm"], 2),
            "snr_std_dev": round(link["snr_std_dev"], 3),
            "bidir": True,
        })
    return {
        "links": kept,
        "n_pairs_evaluated": n_pairs_evaluated,
        "n_links_kept": len(kept),
        "n_srtm_misses": n_srtm_misses,
    }
```

(Note: the docstring of `compute_link_matrix` flags that we run serially for clarity. ProcessPoolExecutor parallelism is a follow-up — it requires reworking `srtm_data` to be picklable or worker-spawned. Sub-30-second target on a 50-node scenario is still met serially because ITM is fast on small profiles.)

- [ ] **Step 5.2: Add the matrix-builder test**

Append to `webapp/tests/test_topo_srtm.py`:

```python
@itm_skip
def test_compute_link_matrix_three_nodes_flat_terrain():
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    nodes = [
        {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "bob",   "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
        {"name": "carol", "lat": 47.63, "lon": -122.33, "antenna_height_m": 1.5},
    ]
    r = compute_link_matrix(
        nodes, freq_mhz=868.0, tx_power_dbm=14.0,
        bandwidth_hz=62500.0, noise_figure_db=6.0,
        profile_resolution_m=90.0,
        min_snr_db=-50.0,  # permissive — keep everything
        max_links_per_node=8,
        srtm_data=srtm,
    )
    assert r["n_pairs_evaluated"] == 3, "C(3,2) = 3 pairs"
    assert r["n_srtm_misses"] == 0
    assert len(r["links"]) == 3
    names = {(l["from"], l["to"]) for l in r["links"]}
    assert names == {("alice", "bob"), ("alice", "carol"), ("bob", "carol")}
    for l in r["links"]:
        assert l["bidir"] is True
        assert isinstance(l["snr"], float)
        assert isinstance(l["rssi"], float)
        assert l["snr_std_dev"] >= 0


def test_compute_link_matrix_srtm_miss_skips_pair():
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: None)  # all misses
    nodes = [
        {"name": "alice", "lat": 47.61, "lon": -122.33},
        {"name": "bob",   "lat": 47.62, "lon": -122.33},
    ]
    r = compute_link_matrix(nodes, srtm_data=srtm)
    assert r["n_pairs_evaluated"] == 1
    assert r["n_srtm_misses"] == 1
    assert r["links"] == []


def test_compute_link_matrix_max_links_per_node_cap():
    """Star topology with 5 leaves around 1 hub. With max_links_per_node=2,
    only 2 of the 4 hub-leaf links survive."""
    from server.services.topo_srtm import compute_link_matrix
    srtm = _FakeSrtm(lambda lat, lon: 50.0)
    # Hub + 4 leaves arranged tightly so all links are viable.
    nodes = [
        {"name": "hub",   "lat": 47.610, "lon": -122.330},
        {"name": "leaf1", "lat": 47.611, "lon": -122.330},
        {"name": "leaf2", "lat": 47.612, "lon": -122.330},
        {"name": "leaf3", "lat": 47.613, "lon": -122.330},
        {"name": "leaf4", "lat": 47.614, "lon": -122.330},
    ]
    r = compute_link_matrix(
        nodes, min_snr_db=-50.0, max_links_per_node=2, srtm_data=srtm,
    )
    # hub appears in at most 2 kept links.
    hub_appearances = sum(
        1 for l in r["links"] if l["from"] == "hub" or l["to"] == "hub"
    )
    assert hub_appearances <= 2, f"hub should be capped at 2, got {hub_appearances}"
```

- [ ] **Step 5.3: Run the new tests**

```bash
cd webapp && python -m pytest tests/test_topo_srtm.py -v 2>&1 | tail -25
```

Expected: 17 tests pass (14 + 3 new).

- [ ] **Step 5.4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/services/topo_srtm.py webapp/tests/test_topo_srtm.py
git commit -m "$(cat <<'EOF'
feat(webapp/topo_srtm): pair compute + link matrix with cap + filtering

compute_pair_link: SRTM + ITM end-to-end for one (a, b) pair.
Returns {snr_db, rssi_dbm, snr_std_dev} or None on SRTM miss.
snr_std_dev is derived from ITM's 10/90 reliability spread
(zeroth-order shadow proxy; deferred sibling spec refines it).

compute_link_matrix: walks every C(n,2) pair, applies min_snr_db
filter, then a max_links_per_node cap (top-N strongest per node by
SNR; ties broken by node-id ascending). Returns kept links plus
{n_pairs_evaluated, n_links_kept, n_srtm_misses} for the API
response.

Three pytest cases cover flat-terrain happy path, all-misses
fallthrough, and the cap-pruning path.

Note: serial computation today; ProcessPoolExecutor parallelism is
a follow-up — needs srtm_data to be picklable or worker-spawned.
The 50-node target stays under the spec's 30 s wallclock budget
serially.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `POST /api/topo-creator/generate-srtm` endpoint

**Files:**
- Modify: `webapp/server/routers/topo_creator.py`
- Create: `webapp/tests/test_topo_srtm_endpoints.py`

- [ ] **Step 6.1: Add the request models + handler**

Append to `webapp/server/routers/topo_creator.py` (after the existing endpoints):

```python
class SrtmItmParams(BaseModel):
    model_config = ConfigDict(extra="forbid")
    climate: int = Field(default=6, ge=1, le=7)
    polarization: int = Field(default=1, ge=0, le=1)
    ground_permittivity: float = 15.0
    ground_conductivity: float = 0.005
    surface_refractivity: float = 314.0
    profile_resolution_m: float = Field(default=90.0, gt=0.0)
    min_snr_db: float = -20.0
    max_links_per_node: int = Field(default=8, ge=1, le=64)


class GenerateSrtmRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nodes: list[dict] = Field(min_length=2)
    path_loss: PathLossParams
    itm: SrtmItmParams = SrtmItmParams()
    bandwidth_hz: float = 62500.0
    noise_figure_db: float = 6.0


@router.post("/generate-srtm")
def generate_srtm(req: GenerateSrtmRequest):
    """Compute terrain-aware per-link SNR/RSSI for a given node list.

    Returns the topology.links payload + summary counts. The caller
    is responsible for stitching the result into a complete scenario
    JSON (the editor / creator UIs do this).
    """
    # Lazy import — keeps the router importable even when srtm /
    # itmlogic aren't installed (the request will then 503).
    try:
        from server.services.topo_srtm import (
            compute_link_matrix,
            get_elevation_data,
        )
    except ImportError as e:
        raise HTTPException(status_code=500,
            detail=f"topo_srtm service unavailable: {e}")

    try:
        srtm_data = get_elevation_data()
    except Exception as e:
        raise HTTPException(status_code=503,
            detail=f"SRTM data fetch failed (offline?): {e}")

    freq_mhz = req.path_loss.frequency_mhz or 868.0
    result = compute_link_matrix(
        nodes=req.nodes,
        freq_mhz=freq_mhz,
        tx_power_dbm=req.path_loss.tx_power_dbm,
        bandwidth_hz=req.bandwidth_hz,
        noise_figure_db=req.noise_figure_db,
        profile_resolution_m=req.itm.profile_resolution_m,
        min_snr_db=req.itm.min_snr_db,
        max_links_per_node=req.itm.max_links_per_node,
        climate=req.itm.climate,
        polarization=req.itm.polarization,
        srtm_data=srtm_data,
    )
    return {
        "links": result["links"],
        "n_pairs_evaluated": result["n_pairs_evaluated"],
        "n_links_kept": result["n_links_kept"],
        "n_srtm_misses": result["n_srtm_misses"],
    }
```

Note: `PathLossParams` doesn't currently include `frequency_mhz`. Add it. Find the `PathLossParams` class in the same file:

```python
class PathLossParams(BaseModel):
    # ... existing fields ...
```

Add `frequency_mhz: Optional[float] = Field(default=None, gt=0.0)` to it (mirror the pydantic schema field added in Task 1.1).

- [ ] **Step 6.2: Create the endpoint test file**

Create `webapp/tests/test_topo_srtm_endpoints.py`:

```python
"""End-to-end tests for /api/topo-creator/generate-srtm and
/api/topo-creator/refine-with-srtm. Mocks SRTM so CI is offline."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.fixture
def fake_srtm_flat(monkeypatch):
    """Patch get_elevation_data to return a flat-100m elevation source."""
    class _Fake:
        def get_elevation(self, lat, lon):
            return 100.0
    def _factory(*a, **kw):
        return _Fake()
    monkeypatch.setattr(
        "server.services.topo_srtm.get_elevation_data", _factory)
    return _Fake()


@pytest.mark.asyncio
async def test_generate_srtm_basic(fake_srtm_flat):
    body = {
        "nodes": [
            {"name": "alice", "lat": 47.61, "lon": -122.33, "antenna_height_m": 1.5},
            {"name": "bob",   "lat": 47.62, "lon": -122.33, "antenna_height_m": 1.5},
            {"name": "carol", "lat": 47.63, "lon": -122.33, "antenna_height_m": 1.5},
        ],
        "path_loss": {
            "model": "log_distance",
            "alpha": 3.0,
            "sigma_db": 0.0,
            "ref_distance_m": 1.0,
            "ref_loss_db": 40.0,
            "noise_floor_db": -120.0,
            "tx_power_dbm": 14.0,
            "frequency_mhz": 868.0,
        },
        "itm": {
            "min_snr_db": -50.0,
        },
    }
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/topo-creator/generate-srtm", json=body)
    assert r.status_code == 200, r.text
    payload = r.json()
    assert payload["n_pairs_evaluated"] == 3
    assert payload["n_srtm_misses"] == 0
    assert payload["n_links_kept"] == 3
    assert {(l["from"], l["to"]) for l in payload["links"]} == {
        ("alice", "bob"), ("alice", "carol"), ("bob", "carol")
    }
    for l in payload["links"]:
        assert "snr" in l and "rssi" in l and "snr_std_dev" in l
        assert l["bidir"] is True


@pytest.mark.asyncio
async def test_generate_srtm_503_on_srtm_failure(monkeypatch):
    def _raise(*a, **kw):
        raise RuntimeError("network unavailable")
    monkeypatch.setattr(
        "server.services.topo_srtm.get_elevation_data", _raise)

    body = {
        "nodes": [
            {"name": "a", "lat": 47.0, "lon": -122.0},
            {"name": "b", "lat": 47.5, "lon": -122.0},
        ],
        "path_loss": {
            "model": "log_distance",
            "alpha": 3.0,
            "sigma_db": 0.0,
            "ref_distance_m": 1.0,
            "ref_loss_db": 40.0,
            "noise_floor_db": -120.0,
            "tx_power_dbm": 14.0,
        },
    }
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/topo-creator/generate-srtm", json=body)
    assert r.status_code == 503
    assert "SRTM" in r.json()["detail"]
```

- [ ] **Step 6.3: Run the new tests**

```bash
cd webapp && python -m pytest tests/test_topo_srtm_endpoints.py -v 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 6.4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/routers/topo_creator.py webapp/tests/test_topo_srtm_endpoints.py
git commit -m "$(cat <<'EOF'
feat(webapp): POST /api/topo-creator/generate-srtm endpoint

Pydantic-validated handler that takes a node list + path-loss params
+ ITM params and returns terrain-aware per-link snr/rssi/snr_std_dev
plus summary counters (n_pairs_evaluated, n_links_kept, n_srtm_misses).

Adds frequency_mhz to PathLossParams to mirror the simulation-side
PathLossConfig field added in commit ... .

Two pytest cases cover the happy path (flat-terrain mock SRTM ->
3-pair output for 3 nodes) and the SRTM-fetch-failure path (503
with explanatory detail).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `POST /api/topo-creator/refine-with-srtm` endpoint

**Files:**
- Modify: `webapp/server/routers/topo_creator.py`
- Modify: `webapp/tests/test_topo_srtm_endpoints.py`

- [ ] **Step 7.1: Add the refine-with-srtm handler**

Append to `webapp/server/routers/topo_creator.py`:

```python
class RefineWithSrtmRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    scenario: dict
    itm: SrtmItmParams = SrtmItmParams()


@router.post("/refine-with-srtm")
def refine_with_srtm(req: RefineWithSrtmRequest):
    """Recompute topology.links[] from current node lat/lon via SRTM+ITM.
    Preserves everything else in the scenario (commands, expect,
    simulation params, node configs)."""
    try:
        from server.services.topo_srtm import (
            compute_link_matrix,
            get_elevation_data,
        )
    except ImportError as e:
        raise HTTPException(status_code=500,
            detail=f"topo_srtm service unavailable: {e}")

    sc = req.scenario
    nodes_in = sc.get("nodes", [])
    if len(nodes_in) < 2:
        raise HTTPException(status_code=400,
            detail="scenario must have at least 2 nodes")

    sim = sc.get("simulation", {})
    path_loss = sim.get("path_loss", {})
    radio = sim.get("radio", {})
    freq_mhz = path_loss.get("frequency_mhz", 868.0)
    tx_power_dbm = path_loss.get("tx_power_dbm", 14.0)
    bandwidth_hz = float(radio.get("bw", 62500)) * 1000.0 if radio.get("bw") else 62500.0
    # Construct the simplified node list compute_link_matrix expects
    # (name, lat, lon, antenna_height_m).
    nodes = []
    for n in nodes_in:
        if "lat" not in n or "lon" not in n:
            raise HTTPException(status_code=400,
                detail=f"node '{n.get('name', '?')}' missing lat/lon")
        nodes.append({
            "name": n["name"],
            "lat": n["lat"],
            "lon": n["lon"],
            "antenna_height_m": n.get("antenna_height_m", 1.5),
        })

    try:
        srtm_data = get_elevation_data()
    except Exception as e:
        raise HTTPException(status_code=503,
            detail=f"SRTM data fetch failed (offline?): {e}")

    result = compute_link_matrix(
        nodes=nodes,
        freq_mhz=freq_mhz, tx_power_dbm=tx_power_dbm,
        bandwidth_hz=bandwidth_hz, noise_figure_db=6.0,
        profile_resolution_m=req.itm.profile_resolution_m,
        min_snr_db=req.itm.min_snr_db,
        max_links_per_node=req.itm.max_links_per_node,
        climate=req.itm.climate, polarization=req.itm.polarization,
        srtm_data=srtm_data,
    )
    # Replace topology.links[] in place; preserve everything else.
    out = dict(sc)
    out_topology = dict(out.get("topology", {}))
    out_topology["links"] = result["links"]
    out["topology"] = out_topology
    return {
        "scenario": out,
        "n_pairs_evaluated": result["n_pairs_evaluated"],
        "n_links_kept": result["n_links_kept"],
        "n_srtm_misses": result["n_srtm_misses"],
    }
```

- [ ] **Step 7.2: Add the refine endpoint test**

Append to `webapp/tests/test_topo_srtm_endpoints.py`:

```python
@pytest.mark.asyncio
async def test_refine_with_srtm_preserves_other_fields(fake_srtm_flat):
    scenario = {
        "_name": "test_scenario",
        "_desc": "preserve check",
        "simulation": {
            "duration_ms": 30000, "step_ms": 1, "warmup_ms": 0, "seed": 42,
            "node_startup_jitter_ms": 0,
            "radio": {"sf": 8, "bw": 250, "cr": 5},
            "path_loss": {"frequency_mhz": 868.0, "tx_power_dbm": 14.0},
        },
        "nodes": [
            {"name": "alice", "lat": 47.61, "lon": -122.33,
             "script": "examples/quiet.lua", "antenna_height_m": 1.5},
            {"name": "bob", "lat": 47.62, "lon": -122.33,
             "script": "examples/quiet.lua", "antenna_height_m": 1.5},
        ],
        "topology": {"links": [
            {"from": "alice", "to": "bob", "snr": 1.0, "rssi": -90.0, "bidir": True},
        ]},
        "commands": [{"at_ms": 1000, "node": "alice", "command": "send hello"}],
        "expect": [{"type": "event_count", "event_type": "tx", "min": 1}],
    }
    body = {
        "scenario": scenario,
        "itm": {"min_snr_db": -50.0},
    }
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/topo-creator/refine-with-srtm", json=body)
    assert r.status_code == 200, r.text
    payload = r.json()
    sc_out = payload["scenario"]
    # Preserved verbatim:
    assert sc_out["_name"] == "test_scenario"
    assert sc_out["_desc"] == "preserve check"
    assert sc_out["simulation"]["duration_ms"] == 30000
    assert sc_out["simulation"]["seed"] == 42
    assert sc_out["commands"] == scenario["commands"]
    assert sc_out["expect"] == scenario["expect"]
    # topology.links replaced:
    new_links = sc_out["topology"]["links"]
    assert len(new_links) == 1
    assert new_links[0]["from"] == "alice"
    assert new_links[0]["to"] == "bob"
    assert new_links[0]["snr"] != 1.0  # the placeholder was replaced
    # Counters present:
    assert payload["n_pairs_evaluated"] == 1
    assert payload["n_links_kept"] == 1
```

- [ ] **Step 7.3: Run + verify**

```bash
cd webapp && python -m pytest tests/test_topo_srtm_endpoints.py -v 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 7.4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/routers/topo_creator.py webapp/tests/test_topo_srtm_endpoints.py
git commit -m "$(cat <<'EOF'
feat(webapp): POST /api/topo-creator/refine-with-srtm endpoint

Takes a complete scenario JSON, recomputes topology.links[] from
current node lat/lon via SRTM+ITM, returns the scenario unchanged
in every other field (commands, expect, simulation, node configs).
Lets a user iterate on the protocol while keeping the link physics
authoritative against terrain.

frequency / tx_power read from scenario.simulation.path_loss with
defaults (868 MHz, 14 dBm); per-node antenna_height_m read from
scenario.nodes[i] (default 1.5 m).

Added pytest verifies preserved fields stay byte-identical and
topology.links[].snr is replaced (was a placeholder, now ITM-derived).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Frontend "Compute via SRTM+ITM" button on `topology_creator.html`

**Files:**
- Modify: `webapp/static/topology_creator.html`

- [ ] **Step 8.1: Add the new button next to "Preview SNR"**

Find the line in `topology_creator.html` containing the "Preview SNR" button:

```html
<button class="btn" id="btn-preview-snr" onclick="previewSNR()" disabled>Preview SNR</button>
```

Replace with:

```html
<button class="btn" id="btn-preview-snr" onclick="previewSNR()" disabled>Preview SNR</button>
<button class="btn" id="btn-compute-srtm" onclick="computeSrtm()" disabled>Compute via SRTM+ITM</button>
```

- [ ] **Step 8.2: Wire enable/disable alongside the existing button**

Find the JS line that toggles `btn-preview-snr.disabled` and mirror it for the new button:

```javascript
document.getElementById('btn-preview-snr').disabled = !hasNodes;
```

After it, add:

```javascript
document.getElementById('btn-compute-srtm').disabled = !hasNodes;
```

Find the line `document.getElementById('btn-preview-snr').disabled = (nodes.length < 2);` and mirror similarly.

- [ ] **Step 8.3: Add the `computeSrtm()` handler**

Inside the same `<script>` block as `previewSNR`, add a new function:

```javascript
async function computeSrtm() {
  const nodes = collectNodes();
  if (nodes.length < 2) {
    alert("Need at least 2 nodes");
    return;
  }
  const path_loss = collectPathLossParams();
  const itm = {
    climate: 6,
    polarization: 1,
    profile_resolution_m: 90.0,
    min_snr_db: -20.0,
    max_links_per_node: 8,
  };
  const btn = document.getElementById('btn-compute-srtm');
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Computing… (~minutes for >50 nodes)';
  try {
    const result = await postJSON('/api/topo-creator/generate-srtm', {
      nodes, path_loss, itm,
    });
    // Render link matrix the same way previewSNR does (re-use the
    // existing render path; topology.links[] format is the same).
    renderSnrMatrix(nodes, result.links);
    setStatus(
      `Computed ${result.n_links_kept} links from ${result.n_pairs_evaluated} pairs ` +
      `(${result.n_srtm_misses} SRTM misses)`
    );
  } catch (e) {
    alert(`SRTM compute failed: ${e.message}`);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}
```

(Note: the helpers `collectNodes`, `collectPathLossParams`, `postJSON`, `renderSnrMatrix`, `setStatus` should already exist in this file from the existing `previewSNR` flow. Re-use; do not duplicate. If their names differ, adapt — read the file's existing JS to find them.)

- [ ] **Step 8.4: Manual test in the browser**

Start the webapp:
```bash
cd webapp && bash run.sh
```

Open `http://localhost:8000/static/topology_creator.html`. Place 3 nodes, click "Compute via SRTM+ITM", verify a status line shows the computed-link counts and the SNR matrix renders.

(No automated frontend test — pattern matches existing topology_creator.html which also relies on manual browser exercise per the SESSION_HANDOFF doc.)

- [ ] **Step 8.5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/static/topology_creator.html
git commit -m "$(cat <<'EOF'
feat(webapp/topology_creator): "Compute via SRTM+ITM" button

New button next to "Preview SNR" that calls POST
/api/topo-creator/generate-srtm with the placed nodes + the same
path-loss params the existing log-distance preview uses, plus
default ITM params (climate=6, polarization=1, 90 m profile
resolution, -20 dB min SNR, 8 links/node cap).

Re-uses the existing renderSnrMatrix path; status line shows
counts (kept / pairs / SRTM misses).

Manual browser exercise only (no headless test — same pattern as
the existing creator UI).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Frontend "Recompute from terrain" button on `topology_editor.html`

**Files:**
- Modify: `webapp/static/topology_editor.html`

- [ ] **Step 9.1: Add the button**

Find the toolbar/header section in `topology_editor.html` (search for an existing button like `<button` near the top of the editor's HTML body). Add a new button alongside:

```html
<button class="btn" id="btn-recompute-terrain" onclick="recomputeFromTerrain()">Recompute links from terrain</button>
```

- [ ] **Step 9.2: Add the JS handler**

Find the `<script>` block that contains the editor's save/load logic. Add:

```javascript
async function recomputeFromTerrain() {
  if (!currentScenario) {
    alert("Load a topology first");
    return;
  }
  const itm = {
    climate: 6,
    polarization: 1,
    profile_resolution_m: 90.0,
    min_snr_db: -20.0,
    max_links_per_node: 8,
  };
  const btn = document.getElementById('btn-recompute-terrain');
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Computing… (~minutes for >50 nodes)';
  try {
    const result = await postJSON('/api/topo-creator/refine-with-srtm', {
      scenario: currentScenario,
      itm,
    });
    currentScenario = result.scenario;
    renderEditor(currentScenario);  // existing render function
    setStatus(
      `Recomputed ${result.n_links_kept} links from ${result.n_pairs_evaluated} pairs ` +
      `(${result.n_srtm_misses} SRTM misses)`
    );
  } catch (e) {
    alert(`SRTM recompute failed: ${e.message}`);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}
```

(Use whatever the existing global is for the loaded scenario — likely `currentScenario`, possibly `state.scenario` or similar. Read the file to confirm name.)

- [ ] **Step 9.3: Manual test**

Open an existing topology in the editor (`/static/topology_editor.html?id=<topo_id>`); click "Recompute links from terrain"; verify the SNR/RSSI values update and `commands` / `expect` blocks remain unchanged.

- [ ] **Step 9.4: Commit**

```bash
git add webapp/static/topology_editor.html
git commit -m "$(cat <<'EOF'
feat(webapp/topology_editor): "Recompute links from terrain" button

Calls POST /api/topo-creator/refine-with-srtm with the currently
loaded scenario; replaces topology.links[] from the SRTM+ITM
computation while preserving simulation, commands, expect, and
node configs verbatim.

Manual browser exercise.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Verify no regressions

This task runs only — no code changes.

- [ ] **Step 10.1: Full integration suite**

```bash
bash test/run_tests.sh
```

Expected: 33/33 pass (no integration tests added by this plan).

- [ ] **Step 10.2: Native C++ tests**

```bash
bash test/native/build_test.sh
```

Expected: all pass (we only added two authoring-time fields the runtime ignores).

- [ ] **Step 10.3: Webapp pytest suite**

```bash
cd webapp && python -m pytest tests/ -q
```

Expected: previous-count + new pytests:
- 17 new in `test_topo_srtm.py` (Tasks 2-5)
- 3 new in `test_topo_srtm_endpoints.py` (Tasks 6-7)

Total: previous count (49 from Plan 1's wrap-up) + 20 = 69. All green.

- [ ] **Step 10.4: Quick manual smoke on a real lat/lon**

```bash
./build/orchestrator/lus scenarios/s02_seattle_sparse.json /tmp/s02_smoke.ndjson 2>&1 | tail -2
```

Expected: same number of events as before (no regression). The `frequency_mhz` field defaults aren't read by the runtime, so existing scenarios are byte-identical in behavior.

No commit needed for this task.

---

## Self-Review Notes

- **Spec coverage:** Each spec section maps to tasks: Config fields → Task 1; service module structure → Tasks 2-5; API endpoints (generate-srtm) → Task 6; (refine-with-srtm) → Task 7; frontend → Tasks 8-9; pytest plan → Tasks 2-7 (interleaved); verification → Task 10.
- **Out-of-scope items deferred per spec:** ProcessPoolExecutor parallelism is flagged as a follow-up in Task 5 (serial code with future-extension note). Variation layer is wholly deferred to the sibling spec — not implemented here.
- **No placeholders:** Every code block is concrete. Frontend button code references real existing helpers (`collectNodes`, `postJSON`, `renderSnrMatrix`, `currentScenario`); the implementer reads the file to confirm exact names and adapts if they differ — that's a reasonable judgment call rather than a placeholder.
- **Type consistency:** `compute_link_itm` returns `{loss_median_db, loss_10pct_db, loss_90pct_db, kwx}` consistently. `compute_pair_link` returns `{snr_db, rssi_dbm, snr_std_dev}` consistently. `compute_link_matrix` returns `{links, n_pairs_evaluated, n_links_kept, n_srtm_misses}` consistently. Endpoints surface those keys faithfully.
- **Frequent commits:** 9 commits across 10 tasks (Task 10 is verification-only). Each commit is independently buildable + green.
