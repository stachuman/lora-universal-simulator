# S1 — `engine` config field + `FirmwareNode` skeleton (design proposal)

**Date:** 2026-05-29  **Status:** PROPOSAL — awaiting review, no code written.
**Builds on:** S0 (`INode` extracted, committed `caae8f6`). Sim-integration
track, see `~/MeshRoute/docs/PORT_PLAN.md` §2.1 / §4.

S0 made `SimController::_nodes` polymorphic over `INode`. S1 proves a **second,
non-Lua `INode` implementation** works end-to-end through the per-step pipeline,
and adds the per-node `engine` switch that selects it.

---

## 1. Goal & non-goals

**Goal (S1):** add a per-node `engine` config field (`"lua"` default vs
`"meshroute"`), and a `FirmwareNode : public INode` **skeleton** that:
- constructs and plugs into the pipeline beside `ScriptedNode`,
- draws time/timers from the host (the sim `VirtualClock` + a `TimerWheel`,
  drift-scaled exactly like `ScriptedNode`),
- emits events through the existing `EventLog` path,
- proves the seam: a scenario mixing `lua` and `meshroute` nodes runs to
  completion, and the `lua` nodes stay **bit-identical**.

**Non-goals (deferred):**
- **No `MeshRoute/lib/core` dependency yet, no `meshroute::Hal` interface, no
  cross-repo build.** The skeleton's behaviour is a tiny built-in stub. Wiring
  the real `lib/core` node through a `meshroute::Hal` is **S2**.
- **No TX/RX through `SimRadio`** (drainPendingTxs returns empty; onRecv no-op).
  That's **S2**.
- **No `NodeRuntime` shared-base extraction** (see §5 — deferred; `ScriptedNode`
  is left untouched so the Lua path is trivially bit-identical).
- No real protocol logic (that's the behaviour track, R1+).

This keeps S1 entirely inside `lora-universal-simulator`, additive, and small.

---

## 2. The `engine` field

`core/topology/JsonConfig.h` — add to `NodeDef` (next to `script_path`):
```cpp
// Node engine: "lua" (default) -> ScriptedNode (runs script_path);
// "meshroute" -> FirmwareNode (the C++ port, run in-loop). S1: skeleton.
std::string engine = "lua";
```
`core/topology/JsonConfig.cpp` — parse next to the `script` block (~line 222):
```cpp
if (nd.contains("engine")) {
    if (!nd["engine"].is_string())
        throw std::runtime_error("config error at " + ctx + ": \"engine\" must be a string");
    def.engine = nd["engine"].get<std::string>();
    if (def.engine != "lua" && def.engine != "meshroute")
        throw std::runtime_error("config error at " + ctx + ": unknown engine \"" + def.engine + "\"");
}
```
Default `"lua"` ⇒ every existing scenario is unchanged (no `engine` key →
ScriptedNode, exactly as today).

---

## 3. `FirmwareNode` skeleton (new: `orchestrator/runtime/FirmwareNode.{h,cpp}`)

`class FirmwareNode : public INode`. Owns the host refs + its own minimal
machinery (composition — see §5):
- refs: `int _id; int _protocol_id; std::string _name; VirtualClock& _clock;
  std::mt19937& _sim_rng; std::ostream& _events_out;`
- machinery: `TimerWheel _timers;` + `std::unordered_map<TimerHandle,
  std::function<void()>> _timer_cbs;` (the C++ analog of ScriptedNode's
  Lua-side closure storage), `std::vector<PendingTx> _pending_txs;` (empty in
  S1), the same `_tx_airtime_log` + attach-slots + `_clock_drift_ppm` /
  `_sf_switch_delay_ms` / `_rx_blind_until_ms` fields as ScriptedNode.

**INode methods:**
- `onInit(config)` → emit `firmware_node_boot` (`EventLog::logScriptEmit`,
  the same path `ScriptedNode::api_emit` uses); schedule one drift-scaled timer
  (e.g. 1000 ms) whose callback emits `firmware_node_tick`. (This is the
  observable proof that host time/timer/emit wiring works.)
- `onRecv / onCommand / onRadioBusy / onPreambleDetected` → no-op (onCommand
  returns `""`). Optionally emit a debug event behind a flag.
- `tickTimers(now)` → `popDue` loop, invoke stored `std::function` callbacks
  (drift handled at schedule time, matching ScriptedNode).
- `drainPendingTxs()` → returns/clears `_pending_txs` (empty in S1).
- lifecycle / identity / attach* / airtime / rxBlindUntilMs → same trivial
  bodies as ScriptedNode (own the same fields).

`now()`/scheduling apply the same `(1 + drift_ppm·1e-6)` scaling as
`ScriptedNode::api_now`/`api_after`, so the HAL contract is honoured when real
logic lands in S2/R1.

Register `runtime/FirmwareNode.cpp` in `orchestrator/CMakeLists.txt` (sources
are listed explicitly, not globbed).

---

## 4. `SimController::initialize()` — the two branch points

Only **two** of the existing init loops need to know the engine; the rest are
INode calls that already work polymorphically.

1. **Construction loop (~382).** Branch on `_cfg.nodes[i].engine`:
   ```cpp
   if (_cfg.nodes[i].engine == "meshroute")
       _nodes.emplace_back(std::make_unique<FirmwareNode>(i, _cfg.nodes[i].name,
           *_radios[i], _events_out, _clock, _rng));
   else
       _nodes.emplace_back(std::make_unique<ScriptedNode>(i, _cfg.nodes[i].name,
           _host, *_radios[i], _events_out, _clock, _rng));
   _nodes[i]->attachSfRxSet(...); _nodes[i]->attachTxInFlightSlot(...);   // both
   ```
2. **Register+load-script loop (~421-431).** Gate the Lua-only work — this also
   removes the transitional `static_cast` worry from S0:
   ```cpp
   _nodes[i]->setProtocolId(protocol_node_id);                 // INode, both
   if (_cfg.nodes[i].engine == "lua") {
       _host.registerNode(i, static_cast<ScriptedNode*>(_nodes[i].get()),
                          protocol_node_id, _cfg.nodes[i].key_hash32);
       _host.loadScript(i, resolveScriptPath(...));
   }
   ```

Everything else — drift/sf-switch (~410), `onInit` (~519/655), `markInitialized`,
`attachLbtModel` (~565) — stays as-is (INode calls, uniform across node types).
`nodeReady` can pass `engine.c_str()` in its existing `firmware` param so the
NDJSON marks the node's engine.

---

## 5. Design choice for your call: shared machinery

When `FirmwareNode` needs the same host-side machinery `ScriptedNode` has
(timer wheel, airtime log, attach-slots, drift), there are two routes:

- **C — Composition / own machinery (recommended for S1).** `FirmwareNode`
  holds its own `TimerWheel` + airtime-log fields (reusing the `TimerWheel`
  *class* and copying the ~30 lines of airtime/drift glue). **`ScriptedNode` is
  untouched** → the Lua path is trivially bit-identical, and the new code is
  purely additive. The duplication is small and the two impls' needs aren't
  fully known until S2/R1 add real TX/RX + logic.
- **A — Extract a `NodeRuntime` base now.** Move the mechanical state + method
  impls into a base both inherit. Cleaner long-term, **but** it touches
  `ScriptedNode` — including its deliberate Lua-side timer-callback storage
  (`tickTimers` dispatches through `LuaHost`, not C++ closures) — so it risks
  the bit-identical guarantee and pre-designs a base before we know
  `FirmwareNode`'s real shape.

**Recommendation: C now, consolidate to a `NodeRuntime` base post-S2**, once
both implementations are fleshed out and the genuinely-shared surface is
obvious. (Same "defer the base until justified" reasoning as S0 §6.)

---

## 6. Verification & test

- **New test `test/t82_firmware_node_skeleton.json`:** one `engine:"meshroute"`
  node (+ one `lua` no-op node via `examples/quiet.lua`), short duration.
  Assertions (existing `expect` format):
  ```json
  "expect": [
    { "type": "event_count", "event_type": "firmware_node_boot", "count": 1 },
    { "type": "event_count", "event_type": "firmware_node_tick", "count": 1 }
  ]
  ```
- **Existing suite bit-identical:** every current config omits `engine` → defaults
  to `"lua"` → zero behaviour change. Re-run the S0 baseline set (75 t + 6 s)
  and `diff` NDJSON against `/tmp/baseline_s0` → **expect zero diff** (the
  refactor adds a branch that no existing config takes).
- **Suite:** expect **82/82** (81 prior + the new t82).
- Clean build.

---

## 7. Files touched (S1)

| File | Change |
|---|---|
| `core/topology/JsonConfig.h` | + `std::string engine = "lua";` on `NodeDef` |
| `core/topology/JsonConfig.cpp` | parse + validate `nd["engine"]` |
| `orchestrator/runtime/FirmwareNode.h` | NEW — `FirmwareNode : public INode` skeleton |
| `orchestrator/runtime/FirmwareNode.cpp` | NEW — skeleton impl |
| `orchestrator/runtime/SimController.cpp` | branch construction; gate registerNode+loadScript on `engine=="lua"` |
| `orchestrator/CMakeLists.txt` | + `runtime/FirmwareNode.cpp` |
| `test/t82_firmware_node_skeleton.json` | NEW — exercises the meshroute path |

One commit on `main`, e.g. `feat(orchestrator): add engine field + FirmwareNode
skeleton (S1)`, gated on 82/82 + zero diff on the existing baseline set.

---

## 8. Open questions

1. **S1 scope** = prove the seam with an orchestrator-only skeleton (no
   `lib/core` / no `meshroute::Hal` yet, deferred to S2)? (My rec: yes — keeps
   S1 one-repo, additive, low-risk.)
2. **Shared machinery** = composition now (C) vs `NodeRuntime` base now (A)?
   (My rec: C; consolidate post-S2.)
3. **Field name / values:** `engine` ∈ {`"lua"`,`"meshroute"`}? (vs reusing the
   old `firmware` name from meshcore_real_sim, or `node_type`.)
4. **Skeleton behaviour** (`firmware_node_boot` + a 1 s `firmware_node_tick`)
   acceptable as the S1 milestone, or do you want it to stay totally silent
   (then the test asserts "ran, didn't crash, lua peers unchanged")?
5. **Test number `t82`** + commit boundary OK?
