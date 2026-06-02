# S0 — `INode` refactor of `SimController` (design proposal)

**Date:** 2026-05-29  **Status:** PROPOSAL — awaiting review, no code written yet.
**Context:** MeshRoute port, sim-integration track step S0 (see
`~/MeshRoute/docs/PORT_PLAN.md` §2.1, §4). Goal of the track: run the real
MeshRoute C++ firmware *in-loop inside this simulator* as a `FirmwareNode`
sitting beside the Lua `ScriptedNode`, reusing the existing PHY.

S0 is the **first, smallest** step toward that: extract the node abstraction
`SimController` drives into an interface, so a second node implementation can
be added later **without touching the per-step pipeline**.

---

## 1. Goal & non-goals

**Goal (S0):** introduce an abstract `INode` interface = *exactly the surface
`SimController` calls on `_nodes[i]`*. Make `ScriptedNode` implement it. Change
`_nodes` to `std::vector<std::unique_ptr<INode>>`. **The Lua node path stays
byte-for-byte identical.**

**Non-goals (deferred):**
- No `FirmwareNode` yet (that's S1).
- No `engine` config field / no per-node branching yet (S1).
- No `meshroute::Hal` interface yet (S2).
- No extraction of the shared host-side machinery into a base class yet
  (see §6 design choice — deferred to when `FirmwareNode` needs it).

This keeps S0 a pure, reviewable *structure-preserving* change.

---

## 2. The `INode` interface (derived from real call sites)

`INode` is defined as precisely the methods `SimController.cpp` invokes on
`_nodes[i]` today (verified by grep, line refs below). Nothing more — the
`self:*` runtime methods (`api_tx`/`api_after`/…) are **not** on `INode`; they
are Lua-binding-specific and stay private to `ScriptedNode`.

```cpp
// orchestrator/runtime/INode.h  (NEW)
#pragma once
#include "json/json.hpp"
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

class LbtModel;

// PendingTx and RadioBusyInfo MOVE here from ScriptedNode.h (they are part of
// the host<->node contract, not Lua-specific). ScriptedNode.h then #includes
// INode.h instead of defining them.
struct PendingTx     { /* …unchanged… */ };
struct RadioBusyInfo { /* …unchanged… */ };

class INode {
public:
    virtual ~INode() = default;

    // ---- dispatch (host -> node logic) ---------------------------------
    virtual void onInit(const nlohmann::json& config)                    = 0; // 519,655
    virtual void onRecv(std::string_view bytes, float snr, float rssi,
                        int link_id, int src_id, uint64_t sim_ms)        = 0; // 1024,1121
    virtual std::string onCommand(std::string_view cmd_str)              = 0; // 716,1718
    virtual void onRadioBusy(const RadioBusyInfo& info)                  = 0; // 1190,1217,1240,1297
    virtual void onPreambleDetected(uint64_t t_ms,int from,float snr_db) = 0; // 1435
    virtual void tickTimers(uint64_t sim_ms)                             = 0; // 1072
    virtual std::vector<PendingTx> drainPendingTxs()                     = 0; // 1093,1145

    // ---- lifecycle gate -------------------------------------------------
    virtual void markInitialized()                                       = 0; // 520,656
    virtual bool isInitialized() const                                   = 0; // 591,638

    // ---- identity -------------------------------------------------------
    virtual int  protocolId() const                                      = 0; // 206,1023,1120,1434
    virtual void setProtocolId(int protocol_id)                          = 0; // 425
    virtual const std::string& name() const                             = 0; // logging, many

    // ---- one-time wiring set by SimController::initialize() -------------
    virtual void attachSfRxSet(std::vector<int>* slot)                   = 0; // 390
    virtual void attachTxInFlightSlot(uint64_t* slot)                    = 0; // 391
    virtual void attachLbtModel(LbtModel* lbt)                           = 0; // 565
    virtual void setClockDriftPpm(float ppm)                             = 0; // 410
    virtual void setSfSwitchDelayMs(float ms)                            = 0; // 411

    // ---- radio-state / duty-cycle queried by the per-step pipeline -----
    virtual void     recordTxAirtime(uint64_t end_ms, uint32_t air_ms)   = 0; // 1392
    virtual uint64_t airtimeUsedInWindow(uint64_t now, uint64_t win_ms)  = 0; // 1267
    virtual uint64_t oldestTxEndMs() const                               = 0; // 1281
    virtual uint64_t rxBlindUntilMs() const                              = 0; // 975,980
};
```

(22 methods. All already exist on `ScriptedNode` with these exact signatures —
this is extraction, not new behaviour.)

---

## 3. Exact changes (blast radius = 4 files + 1 new)

Confirmed by grep: nothing outside the runtime trio depends on `ScriptedNode`
or `PendingTx`/`RadioBusyInfo` except comments. So:

**NEW `orchestrator/runtime/INode.h`** — the interface above + the moved
`PendingTx` / `RadioBusyInfo` structs.

**`orchestrator/runtime/ScriptedNode.h`**
- `#include "orchestrator/runtime/INode.h"`; delete the local `PendingTx` /
  `RadioBusyInfo` definitions (now in INode.h).
- `class ScriptedNode : public INode { … };`
- Add `override` to the 22 interface methods. `api_*`, the machinery, and the
  extra setters/getters stay as-is (non-virtual, ScriptedNode-only).

**`orchestrator/runtime/ScriptedNode.cpp`** — no body changes (signatures
unchanged).

**`orchestrator/runtime/SimController.h`**
- `std::vector<std::unique_ptr<ScriptedNode>> _nodes;`
  → `std::vector<std::unique_ptr<INode>> _nodes;`
- `#include "orchestrator/runtime/INode.h"` (kept alongside the existing
  ScriptedNode.h include, which S1 still needs for construction).

**`orchestrator/runtime/SimController.cpp`**
- Line 382: `_nodes.emplace_back(std::make_unique<ScriptedNode>(…))` — still
  constructs a `ScriptedNode`; the `unique_ptr<ScriptedNode>` upcasts to
  `unique_ptr<INode>` implicitly. No change needed.
- **Line 426 — the only site needing the concrete type.** `LuaHost::registerNode`
  binds Lua `self:*` lambdas to a `ScriptedNode*`, so it must stay
  `ScriptedNode`-typed. Change:
  ```cpp
  _host.registerNode(i, static_cast<ScriptedNode*>(_nodes[i].get()),
                     protocol_node_id, _cfg.nodes[i].key_hash32);
  // TODO(S1): guard with `if (engine == "lua")`; firmware nodes skip Lua binding.
  ```
  Safe in S0 because every node *is* a `ScriptedNode`.
- All other `_nodes[i]->…` sites are now INode virtual calls — no edits.

**`orchestrator/runtime/LuaHost.{h,cpp}`** — **no change.** `registerNode`
keeps its `ScriptedNode*` parameter.

---

## 4. Why this is bit-identical (the key claim)

The change is pure dispatch indirection. It does **not** touch:
- RNG draw order (`_rng` usage unchanged),
- iteration order of any container,
- timer scheduling (`TimerWheel` untouched),
- the per-step pipeline order (commands → receptions → timers → registrations),
- any emitted event or its payload.

Virtual dispatch resolves to the same `ScriptedNode` bodies that ran before.
Expected result: **identical NDJSON, byte-for-byte**, for any seed/scenario.

---

## 5. Regression plan

1. **Baseline (before touching code):** at clean HEAD `6d66a4f`, capture NDJSON
   for: the full `bash test/run_tests.sh` (expect 73/73 PASS), plus a fast,
   representative set — `s01_dv_dual_sf`, `s13_channel_pull_storm` (≈3 s
   cross-layer repro), and one `s15_three_layer` seed.
2. Apply the refactor; rebuild all CMake targets (clean build to catch any
   missed include).
3. **`bash test/run_tests.sh` → expect 73/73.**
4. Re-run the captured scenarios; `diff` NDJSON against the baseline. **Expect
   zero diff.** Any diff is a bug in the refactor (it must not exist).
5. Build the webapp/orchestrator entry points (`Loop.cpp`, `InteractiveRepl`)
   to confirm no other compile breakage.

---

## 6. Design choice for your call

**Wide `INode` (recommended) vs thin `INode` + shared `NodeRuntime` base.**

- **A — Wide `INode` (proposed above):** `INode` declares all 22 SimController-
  facing methods; `ScriptedNode` implements them (it already does). The shared
  host machinery (`TimerWheel`, the TX-airtime sliding log, the attach-slots,
  clock-drift/SF-blind state) stays *inside* `ScriptedNode` for now. When
  `FirmwareNode` arrives (S1), we extract that machinery into a `NodeRuntime`
  base (or a held member) so both impls reuse it — at which point we'll know
  its exact required shape. **Smallest, safest S0.**
- **B — Introduce `NodeRuntime` base now:** put the machinery in a base class
  immediately, `INode` is only the ~7 dispatch methods. More upfront churn and
  premature (we'd be guessing `FirmwareNode`'s needs before writing it).

Recommendation: **A.** It minimizes the S0 diff and defers the shared-base
extraction to the moment it's actually justified.

---

## 7. Open questions

1. **Interface name:** `INode` (per PORT_PLAN), or `Node` / `SimNode`? (I'll use
   `INode` unless you prefer otherwise.)
2. **The transitional `static_cast` at line 426** — acceptable for S0, given S1
   immediately wraps it in an `engine == "lua"` branch? (Alternative: thread a
   parallel `ScriptedNode*` through construction — more churn for no S0 benefit.)
3. **Spec hygiene:** leave this spec as a local working artifact under
   `docs/superpowers/specs/` (uncommitted, per convention), and commit only the
   code refactor when approved?
4. **Commit boundary:** S0 as one commit on `main` (`refactor(orchestrator):
   extract INode from ScriptedNode`), gated on 73/73 + zero NDJSON diff?
