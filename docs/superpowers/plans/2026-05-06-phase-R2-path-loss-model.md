# Phase R.2 — Path-loss model + lat/lon-based topology

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Each task lands with a dedicated test that demonstrates the new behavior.

**Goal:** Allow the simulator to compute link SNR/RSSI from node geographic positions (lat/lon) using a log-distance + log-normal shadowing path-loss model, instead of requiring an explicit per-pair `topology.links` matrix. This is what Centelles et al. 2024 + FLoRa do; required before scaling to ≥30-node random topologies.

**Spec reference:** `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md` (path-loss is mentioned in the cross-check report as Phase R.2).

**Working repo:** `/home/staszek/lora-universal-simulator` on `main`.

---

## Conventions

- Plain commit messages, NO Co-Authored-By trailer
- Each task = ONE commit covering implementation + dedicated test
- All existing tests (13 native + 7 integration) must continue to pass

---

## Architecture

```
config:
  simulation.path_loss = {
    model: "log_distance",            // for now, only this model
    alpha: 3.0,                       // path-loss exponent (urban: 2.7-3.5)
    sigma_db: 4.0,                    // log-normal shadowing std dev (0 = deterministic)
    ref_distance_m: 1.0,              // reference distance d0
    ref_loss_db: 40.0,                // path loss at d0 (e.g., free-space at 868 MHz, 1m ≈ 31 dB; +9 for fudge)
    noise_floor_db: -120.0,           // receiver noise floor; SNR = RxPower - NoiseFloor
    tx_power_dbm: 20.0                // global default TX power; can be per-node override later
  }
  nodes[i].lat:  41.39                // signed decimal degrees
  nodes[i].lon:  2.16

topology.links can still be specified for explicit overrides (test cases),
but if path_loss is present and topology.links is empty, the runtime
computes the n*n directed link matrix from positions at sim init.
If lat/lon is missing on a node, that node is skipped from path-loss
computation and a warning is emitted; the node has no path-loss-derived
links (only any explicit topology.links entries to/from it apply).
```

Path-loss formula:
```
PL(d) = ref_loss_db + 10 * alpha * log10(d / ref_distance_m) + X_sigma
RxPower_dbm = TxPower_dbm - PL(d)
SNR_db = RxPower_dbm - NoiseFloor_db
```
`X_sigma ~ N(0, sigma_db^2)` is the log-normal shadowing component (sample once at sim init for static topology, OR the existing fading model handles per-step variation — for R.2 we sample once at init; per-step variation is already covered by R.1.5 fading).

Distance from lat/lon: haversine formula on a sphere with Earth radius 6371 km. Accuracy ~0.5% at LoRa link distances (km scale); good enough.

---

## Task R.2.1 — PathLossModel + Haversine helper + native tests

**Files:**
- Create: `core/link/PathLossModel.{h,cpp}`
- Create: `core/link/Geo.h` (header-only haversine)
- Create: `test/native/test_path_loss.cpp`
- Modify: `test/native/build_test.sh`
- Modify: `core/CMakeLists.txt` (add PathLossModel.cpp)

The math foundation, no integration with the sim yet. Just the modules + their unit tests.

- [ ] **Step 1: Geo.h (haversine distance)**

```cpp
// core/link/Geo.h
#pragma once
#include <cmath>

namespace lus {
inline double haversineDistanceMeters(double lat1, double lon1,
                                       double lat2, double lon2) {
    const double R = 6371000.0;   // Earth radius, meters
    const double pi = 3.14159265358979323846;
    const double phi1 = lat1 * pi / 180.0;
    const double phi2 = lat2 * pi / 180.0;
    const double dphi = (lat2 - lat1) * pi / 180.0;
    const double dlam = (lon2 - lon1) * pi / 180.0;
    const double a = std::sin(dphi/2)*std::sin(dphi/2)
                    + std::cos(phi1)*std::cos(phi2)
                    * std::sin(dlam/2)*std::sin(dlam/2);
    const double c = 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
    return R * c;
}
}
```

- [ ] **Step 2: PathLossModel.h**

```cpp
// core/link/PathLossModel.h
#pragma once
#include <random>
#include <string>

struct PathLossConfig {
    std::string model = "log_distance";
    double alpha = 3.0;
    double sigma_db = 0.0;
    double ref_distance_m = 1.0;
    double ref_loss_db = 40.0;
    double noise_floor_db = -120.0;
    double tx_power_dbm = 20.0;
};

class PathLossModel {
public:
    PathLossModel(const PathLossConfig& cfg, std::mt19937& rng);

    // Returns (snr_db, rssi_dbm) for a link of length distance_m.
    // Sigma_db is sampled once per call; persistent shadowing per directed
    // link is the caller's responsibility (sample once at init).
    struct LinkSignal { float snr_db; float rssi_dbm; };
    LinkSignal sample(double distance_m);

    // Deterministic version (sigma_db ignored) for analytic tests.
    LinkSignal sampleDeterministic(double distance_m) const;

private:
    PathLossConfig _cfg;
    std::mt19937& _rng;
    std::normal_distribution<double> _shadow;
};
```

- [ ] **Step 3: PathLossModel.cpp**

```cpp
#include "core/link/PathLossModel.h"
#include <cmath>

PathLossModel::PathLossModel(const PathLossConfig& cfg, std::mt19937& rng)
    : _cfg(cfg), _rng(rng), _shadow(0.0, cfg.sigma_db) {}

PathLossModel::LinkSignal PathLossModel::sampleDeterministic(double distance_m) const {
    if (distance_m < _cfg.ref_distance_m) distance_m = _cfg.ref_distance_m;
    double pl = _cfg.ref_loss_db + 10.0 * _cfg.alpha
                * std::log10(distance_m / _cfg.ref_distance_m);
    double rx_dbm = _cfg.tx_power_dbm - pl;
    double snr   = rx_dbm - _cfg.noise_floor_db;
    return { (float)snr, (float)rx_dbm };
}

PathLossModel::LinkSignal PathLossModel::sample(double distance_m) {
    auto base = sampleDeterministic(distance_m);
    double offset = (_cfg.sigma_db > 0.0) ? _shadow(_rng) : 0.0;
    return { (float)(base.snr_db + offset), (float)(base.rssi_dbm + offset) };
}
```

- [ ] **Step 4: Native test test_path_loss.cpp**

```cpp
#include "core/link/PathLossModel.h"
#include "core/link/Geo.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

int main() {
    // Haversine sanity (Barcelona to Madrid ≈ 506 km)
    double d_bcn_mad = lus::haversineDistanceMeters(41.39, 2.16, 40.42, -3.70);
    assert(d_bcn_mad > 500000.0 && d_bcn_mad < 510000.0);

    // Same point
    double d_zero = lus::haversineDistanceMeters(41.39, 2.16, 41.39, 2.16);
    assert(d_zero < 0.1);

    // Path-loss deterministic check
    PathLossConfig cfg;
    cfg.alpha = 3.0;
    cfg.sigma_db = 0.0;
    cfg.ref_distance_m = 1.0;
    cfg.ref_loss_db = 40.0;
    cfg.noise_floor_db = -120.0;
    cfg.tx_power_dbm = 20.0;
    std::mt19937 rng(42);
    PathLossModel pl(cfg, rng);

    auto at_1m = pl.sampleDeterministic(1.0);
    // PL(1m) = 40 dB; RxPower = 20 - 40 = -20; SNR = -20 - (-120) = 100
    assert(std::fabs(at_1m.snr_db - 100.0f) < 0.01f);

    auto at_100m = pl.sampleDeterministic(100.0);
    // PL(100m) = 40 + 10*3*log10(100) = 40 + 60 = 100 dB
    // RxPower = 20 - 100 = -80; SNR = -80 - (-120) = 40
    assert(std::fabs(at_100m.snr_db - 40.0f) < 0.01f);

    auto at_1km = pl.sampleDeterministic(1000.0);
    // PL(1000m) = 40 + 10*3*log10(1000) = 40 + 90 = 130 dB
    // RxPower = -110; SNR = -110 - (-120) = 10
    assert(std::fabs(at_1km.snr_db - 10.0f) < 0.01f);

    // Stochastic (sigma_db > 0): mean over many samples should be near deterministic
    cfg.sigma_db = 4.0;
    PathLossModel pls(cfg, rng);
    double sum_snr = 0;
    int N = 10000;
    for (int i = 0; i < N; i++) {
        sum_snr += pls.sample(100.0).snr_db;
    }
    double mean_snr = sum_snr / N;
    // Expected mean = 40 ± something small (4 dB sigma / sqrt(10000) ≈ 0.04 dB stderr)
    assert(std::fabs(mean_snr - 40.0) < 0.5);

    std::printf("test_path_loss: OK (1m=%.2f, 100m=%.2f, 1km=%.2f, MC mean(100m, sigma=4)=%.2f)\n",
                at_1m.snr_db, at_100m.snr_db, at_1km.snr_db, mean_snr);
    return 0;
}
```

- [ ] **Step 5: Wire into build_test.sh**

`run test_path_loss test_path_loss.cpp $REPO_ROOT/core/link/PathLossModel.cpp`

- [ ] **Step 6: Update core/CMakeLists.txt**

Add `link/PathLossModel.cpp` to the `lus_core` STATIC library sources.

- [ ] **Step 7: Build, run, verify, commit**

Commit message:
```
feat(core): PathLossModel + haversine geometry helper

Log-distance + log-normal shadowing path-loss model:
  PL(d) = ref_loss_db + 10*alpha*log10(d / ref_distance_m) + X_sigma
  RxPower = TxPower - PL
  SNR = RxPower - NoiseFloor

Defaults match the urban environment (alpha=3.0, sigma=4dB) typical
for Centelles et al. 2024 / FLoRa simulations. Two API entry points:
sampleDeterministic() (sigma ignored, exact analytic formula) for
tests; sample() draws X_sigma from N(0, sigma).

Geo.h provides a header-only haversine for great-circle distance
between (lat, lon) pairs on Earth (R=6371km, ~0.5% accuracy at LoRa
link distances).

Test: test_path_loss verifies
  - Barcelona-Madrid haversine ≈ 506 km
  - PL(1m)=40dB, PL(100m)=100dB, PL(1km)=130dB at alpha=3
  - Stochastic mean over 10000 samples within 0.5 dB of deterministic
```

---

## Task R.2.2 — JsonConfig parsing for path_loss + lat/lon

**Files:**
- Modify: `core/topology/JsonConfig.{h,cpp}`
- Create: `test/native/test_path_loss_config.cpp`
- Modify: `test/native/build_test.sh`

Parse the optional `simulation.path_loss` block + ensure `nodes[i].lat / lon` are exposed (existing fields).

- [ ] **Step 1: Add `path_loss` to SimulationConfig**

In `JsonConfig.h`:
```cpp
struct PathLossSpec {
    bool   present = false;
    std::string model = "log_distance";
    double alpha = 3.0;
    double sigma_db = 0.0;
    double ref_distance_m = 1.0;
    double ref_loss_db = 40.0;
    double noise_floor_db = -120.0;
    double tx_power_dbm = 20.0;
};

struct SimulationConfig {
    // ... existing fields ...
    PathLossSpec path_loss;
};
```

- [ ] **Step 2: Parse it in JsonConfig.cpp**

In the simulation block parser, after radio params:
```cpp
if (sim_obj.contains("path_loss")) {
    const auto& pl = sim_obj["path_loss"];
    cfg.simulation.path_loss.present = true;
    if (pl.contains("model"))         cfg.simulation.path_loss.model = pl["model"];
    if (pl.contains("alpha"))         cfg.simulation.path_loss.alpha = pl["alpha"];
    if (pl.contains("sigma_db"))      cfg.simulation.path_loss.sigma_db = pl["sigma_db"];
    if (pl.contains("ref_distance_m"))cfg.simulation.path_loss.ref_distance_m = pl["ref_distance_m"];
    if (pl.contains("ref_loss_db"))   cfg.simulation.path_loss.ref_loss_db = pl["ref_loss_db"];
    if (pl.contains("noise_floor_db"))cfg.simulation.path_loss.noise_floor_db = pl["noise_floor_db"];
    if (pl.contains("tx_power_dbm"))  cfg.simulation.path_loss.tx_power_dbm = pl["tx_power_dbm"];
    // Validate model
    if (cfg.simulation.path_loss.model != "log_distance") {
        throw std::runtime_error("path_loss.model must be 'log_distance' for v1");
    }
}
```

- [ ] **Step 3: Verify lat/lon parsing already works**

Existing JsonConfig already parses `nodes[i].lat` and `nodes[i].lon` (per the spec) into `NodeDef::lat / lon` with `has_location` flag. Verify this still works; no changes if it does.

- [ ] **Step 4: Native test**

`test/native/test_path_loss_config.cpp`:
```cpp
#include "core/topology/JsonConfig.h"
#include <cassert>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <config.json>\n", argv[0]); return 1; }
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);
    assert(cfg.simulation.path_loss.present);
    assert(cfg.simulation.path_loss.alpha == 3.0);
    assert(cfg.simulation.path_loss.sigma_db == 4.0);
    assert(cfg.simulation.path_loss.tx_power_dbm == 20.0);
    assert(cfg.nodes.size() == 2);
    assert(cfg.nodes[0].has_location);
    assert(cfg.nodes[1].has_location);
    std::printf("test_path_loss_config: OK\n");
    return 0;
}
```

Plus a sample config `test/native/sample_path_loss.json`:
```json
{
  "_name": "sample_path_loss",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 4.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 20.0
    }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "lat": 41.39, "lon":  2.16 },
    { "name": "bob",   "script": "examples/flooder.lua", "lat": 41.40, "lon":  2.17 }
  ],
  "topology": { "links": [] },
  "commands": [],
  "expect": []
}
```

- [ ] **Step 5: Commit**

```
feat(core): parse simulation.path_loss block (log-distance model)

JsonConfig now accepts an optional simulation.path_loss = { model,
alpha, sigma_db, ref_distance_m, ref_loss_db, noise_floor_db,
tx_power_dbm } block. v1 rejects any model other than 'log_distance';
defaults are urban-environment friendly (alpha=3.0, sigma=0 - i.e.
deterministic until the user opts in).

When path_loss.present is true, the runtime (R.2.3) computes the
link matrix from nodes[i].lat / lon at sim init instead of requiring
explicit topology.links entries.

Test: test_path_loss_config parses a sample config and asserts the
parsed values; nodes[i].has_location flag set when lat/lon present.
```

---

## Task R.2.3 — SimController integration: compute link matrix from positions

**Files:**
- Modify: `orchestrator/runtime/SimController.{h,cpp}`
- Create: `test/t07_path_loss.json`
- Modify: `examples/sf_picker.lua` if needed

When `cfg.simulation.path_loss.present`, allocate a PathLossModel + iterate all node pairs to populate the MatrixLinkModel from haversine distance.

- [ ] **Step 1: Decide on policy when both `path_loss` AND `topology.links` are present**

Policy: **path_loss is the base model; explicit topology.links override per-pair entries it specifies.** This lets users mix automated + manual link tuning.

If a node lacks lat/lon AND has no explicit links, emit a warning and treat it as having no links to anywhere.

- [ ] **Step 2: SimController init**

In `SimController::initialize`, after `_links` is constructed but before `topology.links` are applied:

```cpp
if (cfg.simulation.path_loss.present) {
    PathLossConfig plc;
    plc.model = cfg.simulation.path_loss.model;
    plc.alpha = cfg.simulation.path_loss.alpha;
    plc.sigma_db = cfg.simulation.path_loss.sigma_db;
    plc.ref_distance_m = cfg.simulation.path_loss.ref_distance_m;
    plc.ref_loss_db = cfg.simulation.path_loss.ref_loss_db;
    plc.noise_floor_db = cfg.simulation.path_loss.noise_floor_db;
    plc.tx_power_dbm = cfg.simulation.path_loss.tx_power_dbm;
    PathLossModel pl(plc, _rng);

    int missing_loc_count = 0;
    for (int i = 0; i < n; i++) {
        if (!cfg.nodes[i].has_location) { missing_loc_count++; continue; }
        for (int j = 0; j < n; j++) {
            if (i == j) continue;
            if (!cfg.nodes[j].has_location) continue;
            double d = lus::haversineDistanceMeters(
                cfg.nodes[i].lat, cfg.nodes[i].lon,
                cfg.nodes[j].lat, cfg.nodes[j].lon);
            auto sig = pl.sample(d);
            // Apply only if not already set by an explicit link (we pre-populate;
            // the topology.links loop later overrides per-pair).
            _links->setLink(i, j, sig.snr_db, sig.rssi_dbm,
                            /*snr_std_dev=*/(float)cfg.simulation.path_loss.sigma_db,
                            /*loss=*/0.0f);
        }
    }
    if (missing_loc_count > 0) {
        std::fprintf(stderr, "[lus] warning: %d node(s) missing lat/lon — no path-loss links computed for them\n",
                     missing_loc_count);
    }
}
// existing topology.links loop continues; explicit entries override path_loss baseline
```

- [ ] **Step 3: Integration test t07_path_loss.json**

```json
{
  "_name": "t07_path_loss",
  "_desc": "Three nodes deployed via lat/lon. Path-loss model determines link SNR. alice-bob @ 100m → strong link; alice-charlie @ 1.2km → too weak for SF7 (expect drop_weak). Same alice→charlie at SF12 → succeeds.",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 0.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 20.0
    }
  },
  "nodes": [
    { "name": "alice",   "script": "examples/sf_picker.lua", "config": {}, "lat": 41.3900, "lon": 2.1600, "sf_rx_set": [7, 12] },
    { "name": "bob",     "script": "examples/sf_picker.lua", "config": {}, "lat": 41.3909, "lon": 2.1600, "sf_rx_set": [7, 12] },
    { "name": "charlie", "script": "examples/sf_picker.lua", "config": {}, "lat": 41.4008, "lon": 2.1715, "sf_rx_set": [7, 12] }
  ],
  "topology": { "links": [] },
  "commands": [
    { "at_ms":  5000, "node": "alice", "command": "send_sf 7  short-link"  },
    { "at_ms": 15000, "node": "alice", "command": "send_sf 7  long-link"   },
    { "at_ms": 25000, "node": "alice", "command": "send_sf 12 long-link"   }
  ],
  "expect": [
    { "type": "event_count_min", "event_type": "rx",        "node": "bob",     "min": 1 },
    { "type": "event_count_min", "event_type": "drop_weak", "node": "charlie", "min": 1 },
    { "type": "event_count_min", "event_type": "rx",        "node": "charlie", "min": 1 }
  ]
}
```

(`sf_rx_set: [7, 12]` so charlie can receive both SF7 and SF12 packets — needed because we made single-SF the default in R.1.7. This is an explicit opt-in to multi-SF for this specific test.)

Distances:
- alice-bob: lat differs by 0.0009 (≈100m at this latitude)
- alice-charlie: lat differs by 0.0108, lon by 0.0115 (≈1.5km)

At 100m: PL = 40 + 30*log10(100) = 40 + 60 = 100 dB; RxPower = -80 dBm; SNR = 40 dB → well above any SF threshold → rx ✓
At 1.5km: PL = 40 + 30*log10(1500) ≈ 40 + 95 = 135 dB; RxPower = -115 dBm; SNR = 5 dB → above SF12 (-20) but below SF7 (-7.5) → SF7 drops, SF12 succeeds ✓

(Calibrate the actual coordinates by computing haversine first to make sure the distance hits the right band. The 100m and 1500m are approximate; adjust lat/lon if the test doesn't behave as expected.)

- [ ] **Step 4: Verify all tests pass + commit**

```
feat(loop): compute link matrix from path_loss + lat/lon at sim init

When simulation.path_loss.present, SimController allocates a
PathLossModel and pre-populates the MatrixLinkModel from haversine
distances between nodes' (lat, lon). Explicit topology.links entries
still apply afterward and override per-pair path-loss-derived values
(useful for tests that want surgical link tuning on top of automated
defaults).

Nodes lacking lat/lon are skipped from path-loss computation; a
single warning is emitted at startup with the count.

Test: t07_path_loss with three nodes deployed via lat/lon. Asserts
short-link delivery (rx at bob), long-link drop_weak at SF7
(threshold -7.5dB exceeded by computed SNR), and long-link rx at
SF12 (lower threshold tolerates the lower SNR). sf_rx_set explicitly
opts charlie in to multi-SF so the SF12 packet is decodable.
```

---

## Task R.2.4 — `sim:link_snr(from, to)` Lua query

**Files:**
- Modify: `orchestrator/runtime/LuaHost.{h,cpp}`
- Modify: `orchestrator/runtime/SimController.{h,cpp}` (add a public accessor for link snr)
- Create or extend: `test/t07_path_loss.json` to cover this OR add a Lua-driven smoke test

Useful for adaptive-routing protocols that want to inspect link quality.

- [ ] **Step 1: Add public accessor in SimController**

```cpp
class SimController {
public:
    // Returns NaN if no link configured.
    float linkSnrDb(int from, int to) const;
};
```

Implementation: looks up `_links->getLink(from, to)` and returns `lp.snr` (or NaN if absent).

- [ ] **Step 2: Add `sim:link_snr(from_name, to_name)` Lua binding**

In `LuaHost::bindSimGlobals`:
```cpp
sim.set_function("link_snr", [&ctrl](sol::object, std::string from, std::string to) -> sol::object {
    int fi = -1, ti = -1;
    for (size_t i = 0; i < ctrl.config().nodes.size(); i++) {
        if (ctrl.config().nodes[i].name == from) fi = (int)i;
        if (ctrl.config().nodes[i].name == to)   ti = (int)i;
    }
    if (fi < 0 || ti < 0) return sol::lua_nil;
    float s = ctrl.linkSnrDb(fi, ti);
    if (std::isnan(s)) return sol::lua_nil;
    return sol::make_object(ctrl.luaHost().lua(), s);
});
```

- [ ] **Step 3: Test via REPL or a small Lua script**

A simple smoke verification: load t07_path_loss.json, evaluate `sim:link_snr("alice", "bob")` at the REPL, expect a number in [30, 50] dB range.

OR add a small test that uses `sim:link_snr` from inside the script's `on_init`:

```lua
function on_init(self, config)
  local snr_to_bob = sim:link_snr(self.name, "bob")
  if snr_to_bob then
    self:log(string.format("link_snr(%s, bob) = %.2f dB", self.name, snr_to_bob))
  end
end
```

(Optional — wire if it doesn't bloat the test config.)

- [ ] **Step 4: Commit**

```
feat(lua): sim:link_snr(from, to) — query link SNR for adaptive routing

Returns the current link SNR in dB between two named nodes (after
path-loss + topology.links overrides). nil if either node name is
unknown or no link is configured (snr <= -100 sentinel).

Useful for scripts that want to inspect link quality at sim time —
e.g., a routing protocol that adapts its retransmit policy when
link quality changes (R.1.5 fading is per-step, so polled values
reflect current realisation).
```

---

## Task R.2.5 — Documentation pass

**Files:**
- Modify: `README.md` to mention path-loss + lat/lon support
- Modify: `docs/Y2-todos.md` (cross out the path-loss line; add any new follow-ups)
- Modify: `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md` § 11 to add the new tunables

Not strictly required for code, but the user's repo discipline expects it.

- [ ] One commit. Plain message: `docs: capture path-loss model in spec + README + Y2-todos`.

---

## Acceptance for Phase R.2

After all 5 tasks:

- [ ] All native tests pass (13 + 2 new = 15)
- [ ] All integration tests pass (7 + 1 new = 8)
- [ ] Build clean with `-Wall -Wextra -Wpedantic`
- [ ] Perf smoke t99 still under 5 minutes
- [ ] **Realistic LoRa topologies** (random uniform deployment in 1km² with lat/lon) can be specified declaratively with just `path_loss` + per-node `lat/lon`, no hand-tuned `topology.links` matrix
- [ ] `sim:link_snr` lets adaptive scripts poll link quality

This unblocks Phase R.3 (paper reproduction proper), where the random-uniform topology of 64 nodes over 1km² becomes a one-page JSON.
