# lora-universal-simulator — design

**Status:** approved by user 2026-05-05
**Scope:** initial deliverable (Y1) — orchestrator-only, single-sim, no webapp.

---

## 1. Background

The MeshCore simulator at `~/meshcore_real_sim` is a mature host-side network simulator for the MeshCore firmware. Its radio physics, link-quality model, half-duplex enforcement, collision survival, fading, NDJSON event stream, JSON test framework, and HTML visualization are now stable and broadly applicable. Its application layer, however, is tightly coupled to MeshCore — wiring per-node MeshCore C++ instances through `MeshWrapper`, loading firmware plugin `.so` files, embedding MeshCore types in the test surface.

We want to use the same radio infrastructure to test **completely different mesh designs** — new routing protocols, named-data variants, opportunistic / DTN, store-and-forward, application-layer mesh experiments — without writing C++ for each one and without inheriting MeshCore's protocol assumptions.

This spec describes a new project, **`lora-universal-simulator`** (binary: `lus`), that reuses the radio physics layer and provides a Lua scripting host for entirely script-defined node behavior.

---

## 2. Goals

- **G1.** Run mesh-network simulations where each node's behavior is defined entirely by a Lua script. Scripts get raw bytes off the radio; everything above (framing, addressing, routing, retries, application semantics) is implemented in script.
- **G2.** Reuse the radio physics, link model, half-duplex, collision survival, LBT, fading, and event emitter from `meshcore_real_sim` rather than rewriting them.
- **G3.** Performance target: 200 nodes × 1 simulated hour completes in minutes, not hours, on a typical workstation. Architectural choice: sparse-tick (timer-wheel) API; no dense per-tick callbacks.
- **G4.** Single-process, single-sim-at-a-time runtime. No batch parallelism, no IPC.
- **G5.** Y1 ship target: a working orchestrator binary, one example script, one passing JSON test, a static HTML viewer, and a 200-node performance smoke test.

## 3. Non-goals (Y1)

- Hosting MeshCore firmware code (that's `meshcore_real_sim`'s job).
- FastAPI webapp, scenario editor, interactive REPL, sweep runner — deferred to Y2+.
- Scripting languages other than Lua (no Python, no WASM).
- Coroutine-style scripts (only pure callbacks in v1).
- Multi-language scripts in the same simulation.
- Per-node Lua VM isolation (single shared VM with `self`-isolation in v1; revisit in Y2 if needed).
- Persistence of node state across simulation runs.
- LuaJIT host (vanilla Lua 5.4 in v1, with a clean swap path).
- Heterogeneous simulations mixing `lus` scripted nodes with `meshcore_real_sim` firmware nodes.

## 4. Constraints

- **Step rate**: 1 ms simulator step. The same constraint as `meshcore_real_sim`'s minimum-symbol-time guarantee. Cannot be relaxed.
- **No dense ticks**: at 1 ms × 200 nodes × 1 h = 720 M per-node opportunities, dense `on_tick`-style callbacks crossing the C↔Lua boundary every step are infeasible. Sparse-tick (timer-wheel) is mandatory.
- **Lua 5.4 + sol2 v3.3.0** (already vendored in `~/meshcore_real_sim/orchestrator/third_party/sol/`). Reused.
- **C++17**, matching the existing simulator.
- **CMake** build, no PlatformIO needed (host-only — no firmware).
- **Existing radio physics is the source of truth.** We copy and strip; we do not rewrite.

---

## 5. Architecture

Three layers from bottom to top:

```
┌──────────────────────────────────────────────────────┐
│ Lua scripts (per-node behavior)                      │
│ - on_init / on_recv / on_command / on_radio_busy     │
│ - timer registration: after(), every(), cancel()     │
│ - emit packets: tx(), inspect time: now()            │
└──────────────────────────────────────────────────────┘
                       ▲ ▼  sol2 binding
┌──────────────────────────────────────────────────────┐
│ Node runtime (C++ — new code)                        │
│ - ScriptedNode: per-node container                   │
│ - Per-node Lua state (table inside shared VM)        │
│ - Timer min-heap; runtime advances and fires         │
│ - Radio bridge: tx() → SimRadio, RX → on_recv        │
│ - Command bridge: external string → on_command       │
└──────────────────────────────────────────────────────┘
                       ▲ ▼
┌──────────────────────────────────────────────────────┐
│ Core physics (ported from meshcore_real_sim)         │
│ - SimRadio + MatrixLinkModel                         │
│ - VirtualClock per node + stagger                    │
│ - Half-duplex / collision / fading / LBT             │
│ - NDJSON event emitter                               │
│ - Topology + test-config JSON loader                 │
└──────────────────────────────────────────────────────┘
```

The core physics layer is already byte-blind in `meshcore_real_sim` — `SimRadio::startSendRaw` takes `uint8_t* + len` and the link model has no MeshCore types in its API. Lifting it cleanly is a copy-and-strip job.

The node runtime is the only entirely new code. Scripts cannot accidentally couple to MeshCore types because there are none in scope.

---

## 6. Components

### 6.1 Core physics (ported)

Files copied verbatim from `meshcore_real_sim` (with headers/includes adjusted for the new project layout):

- `SimRadio` — radio shim with `startSendRaw`, `notifyRxStart`, `notifyChannelBusy`
- `MatrixLinkModel` — per-link SNR/RSSI/loss matrix
- `VirtualClock` — per-node clock with sim-controlled advancement and stagger
- Collision physics — 3-stage survival (capture / preamble grace / FEC tolerance)
- `LinkFadingState` — per-directed-link i.i.d. or O-U fading
- LBT machinery — `notifyChannelBusy` with 5×T_sym preamble detection delay, `cad_miss_prob`
- NDJSON event emitter — `tx`, `rx`, `collision`, `drop_halfduplex`, `drop_loss`, `tx_fail`
- Topology config loader — `nodes[]`, `topology.links[]`, `simulation` block
- Test config loader — `commands[]`, `expect[]` for the JSON test framework

Stripped: anything that references MeshCore types — `MeshWrapper`, `RepeaterNode.cpp`, `CompanionNode.cpp`, the firmware-plugin `.so` loader, `BaseChatMesh`, `ContactInfo`, the `msg`/`msga`/`cmd` CLI bridging, the multi-firmware CMake gymnastics.

The existing simulator's tests are not ported — they're MeshCore-protocol-level. We write new tests against the example scripts.

### 6.2 Node runtime (new code)

#### `ScriptedNode`

Per-node container that owns:
- A reference to the per-node Lua `self` table (in the shared VM, registered under `LUS.nodes[node_id]`)
- A timer min-heap: each entry is `{deadline_ms_uint64, lua_callback_ref, recurring_period_ms_or_zero}`
- A reference to the node's `SimRadio` instance
- Node identity: integer `id`, string `name`, the per-node `config` table from JSON

#### Lua host

- **One Lua VM per simulation** (not per node). Per-node state isolated by always passing `self` as first arg to every callback. Scripts that misuse globals risk cross-node leakage; documented as a foot-gun.
- Each node has a private registry table inside the VM holding its `self`, its registered timer callbacks (anchored as references so they're not GC'd), and a closure binding to the loaded script's `on_init` / `on_recv` / etc.
- Script files live in a per-sim configurable directory (default `examples/`); referenced by path from each node's JSON config.
- Same script file used by multiple nodes: parsed once, instantiated per-node with its own `self`.

#### Loop integration

The simulator main loop runs at 1 ms steps:

```
processCommands           // external commands → on_command(cmd_str)
deliverReceptions         // RX events → on_recv(frame, meta)
tickTimers                // timers due → fire registered callbacks
registerTransmissions     // any tx() calls during this step → SimRadio
advance(1ms)
```

The C++ side runs at full speed; Lua only fires when actually needed (a timer is due, a packet survived to a receiver, an external command is scheduled).

### 6.3 Test runner

`bash test/run_tests.sh test/foo.json` — same wrapper shape as `meshcore_real_sim`. Calls `lus`, captures NDJSON, runs assertions from `expect[]`.

Assertion types supported in v1:

| Type | Semantics |
|---|---|
| `cmd_reply_contains` | The reply from `on_command` for a given command starts/contains a value |
| `cmd_reply_not_contains` | Negation |
| `event_count` | Count events of `event_type` (optionally filtered by `node`); compare against `min`/`max` |
| `event_count_min` | Convenience for `event_count` with only a lower bound |
| `tx_airtime_between` | Total TX airtime in a time range is within bounds |
| `script_emit_contains` | A script emitted a custom event type with matching data (uses `self:emit()`) |

### 6.4 Visualization

Port `~/meshcore_real_sim/visualization/visualize.py` + `visualize.html` to `~/lora-universal-simulator/tools/visualize.py`. Static viewer — reads NDJSON, opens an HTML page with a swim-lane (one row per node, time on X axis, bars for tx/rx/collision/drop). No server. Adjustments needed:

- Strip MeshCore-specific event semantics from the JS rendering (e.g., named packet types).
- Keep tx/rx/collision/drop/drop_halfduplex/drop_loss colorings.
- Add rendering for `script_log` and `script_emit` events as small markers on the per-node row.

The map view is deferred — it needs lat/lon, which scripts don't necessarily have.

---

## 7. Script API specification

### 7.1 Callbacks

| Callback | When called | Signature |
|---|---|---|
| `on_init(self, config)` | Once at sim start, after node registered with the runtime | `config` is the per-node JSON `config` table (or `{}` if absent) |
| `on_recv(self, frame, meta)` | When a radio packet survives delivery to this node | `frame` is a Lua string of bytes; `meta` is `{snr=, rssi=, link_id=, recv_ms=}` |
| `on_command(self, cmd_str)` | When test framework / future interactive UI delivers a command | Returns a string reply (becomes the `reply` field in NDJSON `cmd_reply` event) |
| `on_radio_busy(self)` | Optional. `self:tx()` failed because channel was busy and the runtime didn't queue | No args |

All callbacks are optional except `on_init` (a script that doesn't define `on_init` is not useful, but it won't crash — runtime tolerates missing callbacks).

### 7.2 Runtime methods (`self:` namespace)

| Method | Behavior |
|---|---|
| `self:tx(bytes)` | Transmit `bytes` (Lua string) using default radio params |
| `self:tx(bytes, opts)` | With per-packet overrides: `{ sf=, bw=, cr=, power_dbm= }` |
| `self:after(ms, fn)` | Schedule one-shot timer: `fn(self)` invoked after `ms` simulated ms. Returns handle. |
| `self:every(ms, fn)` | Schedule recurring timer. Returns handle. |
| `self:cancel(handle)` | Cancel a scheduled timer |
| `self:now()` | Current simulated time, ms (uint64) |
| `self:rand(lo, hi)` | Deterministic per-sim PRNG draw (seeded from sim seed for reproducibility); `hi` exclusive |
| `self:log(...)` | Concatenate args and emit a `script_log` event on this node |
| `self:emit(type_str, data_table)` | Emit a custom NDJSON event (`type` field is `"script:" .. type_str`) |
| `self:peers()` | DEBUG ONLY. Returns a list of node ids physically reachable from this node. **Don't use in protocol logic** — a real radio can't see this. |

### 7.3 Initial state

When `on_init(self, config)` is called, `self` already contains:
- `self.id` — integer node id (assigned by runtime, unique per sim, stable across restarts of the same JSON config)
- `self.name` — string from topology JSON
- All runtime methods reachable as `self:method(args)`

The script may freely add fields (`self.seq = 0`, `self.routes = {}`, …). They persist across all subsequent callbacks for that node.

### 7.4 Lifecycle

1. Sim starts; orchestrator parses topology + simulation JSON.
2. For each node: load and parse script file (cached if reused), instantiate `self`, call `on_init(self, config)`. Any `tx()` or `after()` calls during init are queued for the post-init step.
3. Main loop advances at 1 ms steps.
4. At sim end: emit a final NDJSON marker; no `on_destroy` in v1 (scripts don't need cleanup hooks for a single-shot sim).

---

## 8. Configuration schema

> **Reuse note.** The schema and its loader are inherited largely unchanged from `meshcore_real_sim`. The structure under `simulation`, `topology.links`, and the per-link physics fields (snr, rssi, bidir, snr_std_dev, snr_coherence_ms, loss, ...) are preserved verbatim — see `~/meshcore_real_sim/docs/CONFIG_FORMAT.md` for the full reference of those parts. We only strip MeshCore-specific fields (firmware/role/hot_start/_requires_plugins) and replace `firmware`+`role` on each node with `script`+`config`. The loader code in `core/topology/` is a port from `meshcore_real_sim/orchestrator/`.

Top-level test JSON, derived from `meshcore_real_sim`'s pattern with the protocol-specific fields removed:

```json
{
  "_name": "t01_flooder",
  "_desc": "Simple flood-and-forward demo",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 5000,
    "radio": { "sf": 11, "bw": 250.0, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "relay", "script": "examples/flooder.lua", "config": { "role": "forwarder" } },
    { "name": "bob",   "script": "examples/flooder.lua", "config": { "role": "originator" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "relay", "snr": 8.0, "rssi": -80.0, "bidir": true },
      { "from": "relay", "to": "bob",   "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 10000, "node": "alice", "command": "send hello" }
  ],
  "expect": [
    { "type": "event_count_min", "event_type": "rx", "node": "bob", "min": 1 }
  ]
}
```

**Differences from `meshcore_real_sim`'s schema:**

- `nodes[i].role` and `nodes[i].firmware` removed; replaced by `nodes[i].script` (path) and `nodes[i].config` (per-node table passed to `on_init`).
- `simulation.firmware.default` removed.
- `simulation.hot_start` removed (no built-in advert protocol to populate).
- `_requires_plugins` removed (no firmware plugins).
- Everything else (`simulation.{duration_ms, step_ms, warmup_ms}`, `simulation.radio`, `topology.links`, `commands`, `expect`) is preserved.

---

## 9. Project structure

```
~/lora-universal-simulator/
├── CMakeLists.txt
├── README.md
├── core/                          # protocol-agnostic, extractable later
│   ├── radio/                     # SimRadio
│   ├── link/                      # MatrixLinkModel + LinkFadingState
│   ├── clock/                     # VirtualClock
│   ├── physics/                   # collision, fading, LBT
│   ├── topology/                  # JSON config parser
│   └── events/                    # NDJSON emitter
├── orchestrator/                  # the lus binary
│   ├── main.cpp
│   ├── lua_host/                  # sol2-based Lua wiring
│   ├── node_runtime/              # ScriptedNode, callbacks, timer wheel
│   ├── test_runner.cpp            # expect[] assertion logic
│   └── CMakeLists.txt
├── examples/                      # example Lua scripts
│   ├── flooder.lua                # initial example (Y1)
│   └── (more in Y2+)
├── test/                          # JSON test configs
│   ├── run_tests.sh
│   └── t01_flooder.json
├── tools/
│   └── visualize.py               # NDJSON → HTML viewer (ported)
├── docs/
│   ├── superpowers/specs/         # this design doc
│   ├── superpowers/plans/         # implementation plans
│   └── README.md
└── third_party/
    └── sol/                       # sol2, vendored from meshcore_real_sim
```

The `core/` subtree is organized so it could be extracted into its own library later if both simulators stay actively maintained and we find ourselves cherry-picking radio fixes between them. No sharing today.

---

## 10. Initial deliverable (Y1) acceptance

"v1 done" means all of:

1. `lus` orchestrator binary builds via `cmake -S . -B build && cmake --build build -j 4` on Linux.
2. One example script `examples/flooder.lua` (~80 lines): a node with `role: "originator"` reacts to `on_command("send <text>")` by transmitting a numbered packet; every node forwards once (deduped by packet hash) and logs receipt.
3. One JSON test `test/t01_flooder.json`: 3-node chain alice → relay → bob; `command: "send hello"` at t=10s; assertion `event_count_min{event_type=rx, node=bob, min=1}` passes.
4. `bash test/run_tests.sh test/t01_flooder.json` reports `t01_flooder PASS`.
5. `python3 tools/visualize.py events.ndjson` produces a working HTML swim-lane.
6. **Performance smoke test**: a 200-node × 1 h sim with the flooder script (or a simple no-op script) completes in under 5 minutes wall time on a typical Linux workstation.

If the smoke test fails (>5 minutes), the LuaJIT swap is the first remediation; only after that do we consider deeper changes.

---

## 11. Tunables and defaults

| Parameter | Default | Range | Notes |
|---|---|---|---|
| `simulation.duration_ms` | required | any | Total simulated time |
| `simulation.step_ms` | 1 | 1 (only) | Forced; cannot relax |
| `simulation.warmup_ms` | 0 | any | Pre-physics instant-delivery phase |
| `simulation.radio.sf` | 11 | 7..12 | LoRa spreading factor |
| `simulation.radio.bw` | 250.0 | 7.8..500.0 | LoRa bandwidth (kHz) |
| `simulation.radio.cr` | 5 | 5..8 | LoRa coding rate denominator (4/5..4/8) |
| `MAX_PENDING_TIMERS_PER_NODE` | 64 | compile-time | Bound on the per-node timer min-heap |

Per-link knobs (snr, rssi, bidir, snr_std_dev, snr_coherence_ms, loss) inherit from `meshcore_real_sim`'s schema unchanged.

Per-tx overrides via `self:tx(bytes, opts)`: `{sf, bw, cr, power_dbm}`.

---

## 12. Testing strategy for the simulator itself

- **Native unit tests** (Catch2 or similar): timer wheel correctness (insert / pop / cancel under load), Lua host callback dispatch (each callback fires with correct args), self-isolation (one node mutating `self` doesn't affect another).
- **JSON regression tests**: t01_flooder for Y1; additional regression configs added incrementally as new examples land.
- **Performance test**: 200-node × 1 h benchmark in CI; fails the build if it takes >5 minutes.

---

## 13. Open questions (deferred decisions)

1. **Per-node Lua VM isolation.** v1 uses a shared VM with `self`-isolation. If we hit a real bug from global-leak across nodes, switch to per-node VMs (cost: 5–10× memory; ~100 KB × 200 = 20 MB extra; acceptable). Decision deferred until a concrete failure case.
2. **Hot-start equivalent.** v1 **entirely skips** the hot-start concept. Scripts handle their own setup by emitting traffic during early simulated time. As a possible future addition (not Y1): a global "collision-free warmup" mode — for the first `warmup_ms` of simulated time, suppress collision physics so setup traffic delivers cleanly. That's effectively what `meshcore_real_sim`'s hot-start does internally (plus the MeshCore-specific advert injection, which doesn't apply here). Move to a later phase; not necessary at Y1.
3. **Default LoRa physics fixed.** Scripts override per-tx; they cannot redefine the underlying physics layer (e.g., custom SF tables). v1 keeps physics fixed.
4. **Binary naming.** `lus` is short and clear. Open to alternatives (`lus-sim`, `lora-sim`) if the user prefers.
5. **Random topology generators.** `meshcore_real_sim` has `tools/gen_grid_test.py`. Decide later whether to port; not blocking Y1.

---

## 14. Implementation roadmap (high level)

| Phase | Time | Deliverable |
|---|---|---|
| 1. Project bootstrap | ~1 day | New repo skeleton: CMakeLists.txt root + orchestrator/, third_party/sol/ vendored, README.md, basic CI shell |
| 2. Port core physics | ~2 days | `core/` populated with SimRadio, MatrixLinkModel, VirtualClock, NDJSON emitter, topology parser. Builds cleanly. |
| 3. Node runtime + Lua host | ~2 days | `ScriptedNode`, sol2 binding, callback dispatch, runtime methods, timer wheel. Smoke test: one Lua script logs once. |
| 4. Test runner + flooder example | ~1 day | `bash test/run_tests.sh test/t01_flooder.json` passes; expect[] assertions implemented. |
| 5. Visualization port + perf smoke | ~1 day | `tools/visualize.py` renders NDJSON to HTML; 200-node × 1h smoke test under 5 minutes. |

**Total Y1 estimate: ~7 days.**

The detailed plan (per-step instructions, file lists, commit boundaries) is the next document — `docs/superpowers/plans/YYYY-MM-DD-y1-implementation.md` — produced by the writing-plans skill once this design is approved.

---

## 15. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Performance falls short of 200×1h target | Medium | High | LuaJIT swap as drop-in escape hatch; API is host-agnostic |
| Lua-VM `self` isolation has subtle cross-node leaks | Medium | Medium | Per-node VMs as Y2 fallback; document foot-gun, lint scripts for `_G.`-style globals |
| Visualization port has subtle event-format mismatches | Low | Low | Iterative; fix as discovered |
| Code-duplication maintenance with `meshcore_real_sim` | Medium | Low | `core/` subtree is extractable; revisit if both simulators stay active |
| sol2 idiosyncrasies passing binary strings (NUL bytes) | Low | Medium | sol2 supports binary strings via `std::string` round-trip; verify in Phase 3 |
| Timer-wheel scaling with many timers per node | Low | Medium | Min-heap is O(log n) per op; bounded at `MAX_PENDING_TIMERS_PER_NODE` |

---

## 16. References

- `~/meshcore_real_sim/` — the source simulator we copy from
- `~/meshcore_real_sim/orchestrator/third_party/sol/` — sol2 vendored
- `~/meshcore_real_sim/visualization/visualize.{py,html}` — visualization to port
- `~/meshcore_real_sim/docs/RADIO_MODEL.md` — radio physics documentation (carries over)
- `~/meshcore_real_sim/docs/CONFIG_FORMAT.md` — pattern for the new schema doc
