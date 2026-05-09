# Node-Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `nodes[].start_at_ms` and `nodes[].dies_at_ms` JSON config fields plus paired `node_started` / `node_died` NDJSON events, allowing scenarios to schedule when each node powers on and off.

**Architecture:** Two unsigned-int fields on `NodeDef` (default 0 = "not scheduled"). A new `_node_alive` bool vector on `SimController` is the runtime gate. A new `processLifecycleAtStep()` runs at the top of `step()` (parallel to the existing `warmup_end` emit) to flip the bool and emit the matching event. Every per-step helper (`deliverReceptions`, `registerTransmissions`, `tickTimers`, `processCommands`) checks `_node_alive[i]` to skip dead/unborn nodes.

**Tech Stack:** C++17 (orchestrator + EventLog + JsonConfig), Python 3 + pytest (event-stream assertions), JSON (test scenarios), Pydantic v2 (webapp schema).

**Spec:** `docs/superpowers/specs/2026-05-09-node-lifecycle-orchestrator-design.md`

---

## File Structure

| Path | Action | Purpose |
|---|---|---|
| `core/topology/JsonConfig.h` | Modify | Add `start_at_ms`, `dies_at_ms` (uint, default 0) to `NodeDef`. |
| `core/topology/JsonConfig.cpp` | Modify | Parse the two fields; validate `< duration_ms` and `start < die` if both set. |
| `core/events/EventLog.h` | Modify | Declare `nodeStarted` and `nodeDied`. |
| `core/events/EventLog.cpp` | Modify | Implement both — same pattern as `warmupEnd` / `nodeReady`. |
| `orchestrator/runtime/SimController.h` | Modify | Add `_node_alive` member, declare `processLifecycleAtStep()`. |
| `orchestrator/runtime/SimController.cpp` | Modify | Initialize `_node_alive`, override `_node_init_at_ms` for deferred-start nodes, implement `processLifecycleAtStep`, gate the four per-step helpers. |
| `test/t24_node_dies.json` | Create | Integration scenario: relay dies at t=5000, alice's first ping delivers, second doesn't. |
| `test/t25_node_starts.json` | Create | Integration scenario: relay born at t=5000, alice's first ping fails, second delivers. |
| `webapp/server/models/schemas.py` | Modify | Add `start_at_ms`, `dies_at_ms` fields to `NodeConfig` Pydantic model. |
| `webapp/server/services/event_index.py` | Modify | Add `node_started`, `node_died` to `_METADATA_TYPES`. |
| `webapp/tests/test_node_lifecycle_events.py` | Create | Pytest covering time_ms, count, and silence-after-death / invisibility-before-birth. |

---

## Task 1: Add JSON config fields and validation (no runtime use yet)

**Files:**
- Modify: `core/topology/JsonConfig.h` (NodeDef struct around line 199-256)
- Modify: `core/topology/JsonConfig.cpp` (NodeDef parsing around line 130-220, validation around line 320-365)

- [ ] **Step 1.1: Add fields to `NodeDef`**

In `core/topology/JsonConfig.h`, find the `velocity_mps` / `direction_deg` block at the end of `NodeDef` (around lines 254-255):

```cpp
        float velocity_mps         = 0.0f;
        float direction_deg        = 0.0f;
    };
```

Insert two fields just before the closing `};`:

```cpp
        float velocity_mps         = 0.0f;
        float direction_deg        = 0.0f;
        // Lifecycle scheduling. 0 = "not scheduled" sentinels (today's
        // behavior). When start_at_ms > 0, the orchestrator keeps the
        // node fully off (no rx, tx, scripts, on_init) until that
        // sim-time. When dies_at_ms > 0, the orchestrator stops the
        // node fully at that sim-time. Each is enforced by
        // SimController via _node_alive + processLifecycleAtStep().
        unsigned long start_at_ms = 0;
        unsigned long dies_at_ms  = 0;
    };
```

- [ ] **Step 1.2: Parse the two fields**

In `core/topology/JsonConfig.cpp`, find the `tx_fail_prob` block (around line 195):

```cpp
            if (nd.contains("tx_fail_prob"))
                def.tx_fail_prob = nd["tx_fail_prob"].get<float>();
```

Insert after it:

```cpp
            if (nd.contains("tx_fail_prob"))
                def.tx_fail_prob = nd["tx_fail_prob"].get<float>();

            if (nd.contains("start_at_ms"))
                def.start_at_ms = nd["start_at_ms"].get<unsigned long>();
            if (nd.contains("dies_at_ms"))
                def.dies_at_ms  = nd["dies_at_ms"].get<unsigned long>();
```

- [ ] **Step 1.3: Validate the two fields**

In `core/topology/JsonConfig.cpp`, find the `cfg.simulation.warmup_ms` validation (around line 328-331):

```cpp
    if (cfg.simulation.warmup_ms >= cfg.simulation.duration_ms && cfg.simulation.warmup_ms > 0)
        errors.push_back("simulation.warmup_ms (" + std::to_string(cfg.simulation.warmup_ms)
                         + ") must be < duration_ms ("
                         + std::to_string(cfg.simulation.duration_ms) + ")");
```

Walk further down to the per-node validation loop (search for `for (const auto& nd : cfg.nodes)`). If it doesn't exist yet for these checks, add a fresh loop after the simulation-level checks. Insert this block at the appropriate place (after the simulation parameters validation, before any node-name uniqueness checks):

```cpp
    // Per-node lifecycle constraint validation. start/die at 0 means
    // "not scheduled"; if scheduled, must be in (0, duration_ms) and
    // start < die when both are set.
    {
        size_t i = 0;
        for (const auto& nd : cfg.nodes) {
            const std::string ctx = "nodes[" + std::to_string(i++) + "]";
            if (nd.start_at_ms > 0
                && nd.start_at_ms >= cfg.simulation.duration_ms) {
                errors.push_back(ctx + ".start_at_ms ("
                    + std::to_string(nd.start_at_ms)
                    + ") must be < duration_ms ("
                    + std::to_string(cfg.simulation.duration_ms) + ")");
            }
            if (nd.dies_at_ms > 0
                && nd.dies_at_ms >= cfg.simulation.duration_ms) {
                errors.push_back(ctx + ".dies_at_ms ("
                    + std::to_string(nd.dies_at_ms)
                    + ") must be < duration_ms ("
                    + std::to_string(cfg.simulation.duration_ms) + ")");
            }
            if (nd.start_at_ms > 0 && nd.dies_at_ms > 0
                && nd.start_at_ms >= nd.dies_at_ms) {
                errors.push_back(ctx + ".start_at_ms ("
                    + std::to_string(nd.start_at_ms)
                    + ") must be < dies_at_ms ("
                    + std::to_string(nd.dies_at_ms) + ")");
            }
        }
    }
```

- [ ] **Step 1.4: Build, verify nothing regressed**

```bash
cmake --build build -j 2>&1 | tail -5
```

Expected: `[100%] Built target lus`. (No tests added/changed yet — schemas-only commit. The behavior is still "fields parsed but unused".)

- [ ] **Step 1.5: Commit**

```bash
git add core/topology/JsonConfig.h core/topology/JsonConfig.cpp
git commit -m "$(cat <<'EOF'
feat(config): parse + validate nodes[].start_at_ms and dies_at_ms

Two new optional unsigned-int fields on NodeDef, both default to 0
(meaning "not scheduled"). Validation: each must be < duration_ms
when set, and start_at_ms < dies_at_ms when both are set.

Runtime use lands in the next commit (orchestrator gates).

Spec: docs/superpowers/specs/2026-05-09-node-lifecycle-orchestrator-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add EventLog methods

**Files:**
- Modify: `core/events/EventLog.h` (after `warmupEnd` declaration around line 41)
- Modify: `core/events/EventLog.cpp` (after `warmupEnd` definition, near where `nodeReady` is)

- [ ] **Step 2.1: Add the declarations**

In `core/events/EventLog.h`, find the `warmupEnd` line:

```cpp
// Boundary marker — fires once at sim_time == warmup_ms when warmup_ms > 0.
void warmupEnd(unsigned long time_ms);
```

Insert after it:

```cpp
// Boundary marker — fires once at sim_time == warmup_ms when warmup_ms > 0.
void warmupEnd(unsigned long time_ms);

// Lifecycle markers. nodeStarted fires once when a deferred-start
// node (nodes[].start_at_ms > 0) initializes. nodeDied fires once
// when a node with nodes[].dies_at_ms > 0 reaches that sim-time.
void nodeStarted(unsigned long time_ms, const char* node);
void nodeDied(unsigned long time_ms, const char* node);
```

- [ ] **Step 2.2: Add the implementations**

In `core/events/EventLog.cpp`, find the `warmupEnd` definition:

```cpp
void warmupEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"warmup_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}
```

Insert after it:

```cpp
void warmupEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"warmup_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}

void nodeStarted(unsigned long time_ms, const char* node) {
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"node_started\",\"time_ms\":%lu,\"node\":\"%s\"}\n",
        time_ms, node ? node : "");
    emitLine(buf);
}

void nodeDied(unsigned long time_ms, const char* node) {
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"node_died\",\"time_ms\":%lu,\"node\":\"%s\"}\n",
        time_ms, node ? node : "");
    emitLine(buf);
}
```

- [ ] **Step 2.3: Build, verify it compiles**

```bash
cmake --build build -j 2>&1 | tail -5
```

Expected: `[100%] Built target lus`. Still no callers; this commit is the EventLog shim only.

- [ ] **Step 2.4: Commit**

```bash
git add core/events/EventLog.h core/events/EventLog.cpp
git commit -m "$(cat <<'EOF'
feat(events): add nodeStarted + nodeDied event helpers

Two trivial NDJSON emitters parallel to nodeReady / warmupEnd.
Wired up to SimController in the next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire SimController lifecycle gating

**Files:**
- Modify: `orchestrator/runtime/SimController.h` (member declarations + processLifecycleAtStep)
- Modify: `orchestrator/runtime/SimController.cpp` (init, processLifecycleAtStep, gating in deliverReceptions / registerTransmissions / tickTimers / processCommands, override _node_init_at_ms)

This is the largest task. Five sub-changes within the same logical commit.

- [ ] **Step 3.1: Declare the member + helper in `SimController.h`**

Find this block (around line 100-108):

```cpp
    // Called at the top of each step before processCommandsAtStep so that
    // a node initialized this tick is fully alive before any of its
    // commands or rx deliveries are processed in the same step.
    void processStartupAtStep();

    void processCommandsAtStep();
    void deliverReceptionsForStep();
    void tickTimersForStep();
    void registerTransmissionsForStep();
```

Insert one line above `processStartupAtStep`:

```cpp
    // Lifecycle: handle scheduled deferred starts (start_at_ms) and
    // scheduled deaths (dies_at_ms). Runs at the top of step() before
    // any per-step work; toggles _node_alive and emits node_started /
    // node_died.
    void processLifecycleAtStep();

    // Called at the top of each step before processCommandsAtStep so that
    // a node initialized this tick is fully alive before any of its
    // commands or rx deliveries are processed in the same step.
    void processStartupAtStep();
```

Find this block (around line 197):

```cpp
    bool     _warmup_end_emitted = false;
```

Insert right after:

```cpp
    bool     _warmup_end_emitted = false;

    // Per-node lifecycle "is currently alive" flag. Initialized in
    // initialize(): true if start_at_ms == 0 (alive from t=0) else
    // false. Flipped to true at start_at_ms (node_started emitted) and
    // back to false at dies_at_ms (node_died emitted). Each per-step
    // helper consults this to skip dead / unborn nodes.
    std::vector<bool> _node_alive;
```

- [ ] **Step 3.2: Initialize `_node_alive` and override `_node_init_at_ms` for deferred starts**

In `core/topology/JsonConfig.cpp`'s `initialize()` (around lines 369-380), find this block:

WAIT — this is `SimController::initialize()` in `orchestrator/runtime/SimController.cpp`, not `JsonConfig.cpp`. Find the per-node-startup-jitter block:

```cpp
    _node_init_at_ms.assign(static_cast<size_t>(n), 0);
    if (_cfg.simulation.node_startup_jitter_ms > 0) {
        std::uniform_int_distribution<int> jdist(
            0, _cfg.simulation.node_startup_jitter_ms);
        for (int i = 0; i < n; ++i) {
            _node_init_at_ms[i] = static_cast<uint64_t>(jdist(_rng));
        }
    }
```

Replace with:

```cpp
    _node_init_at_ms.assign(static_cast<size_t>(n), 0);
    if (_cfg.simulation.node_startup_jitter_ms > 0) {
        std::uniform_int_distribution<int> jdist(
            0, _cfg.simulation.node_startup_jitter_ms);
        for (int i = 0; i < n; ++i) {
            _node_init_at_ms[i] = static_cast<uint64_t>(jdist(_rng));
        }
    }

    // Per-node lifecycle. _node_alive[i] is the runtime gate: false
    // until start_at_ms fires (then node_started + on_init), false
    // again after dies_at_ms (then node_died). For nodes with
    // start_at_ms > 0 we override the jitter assignment so on_init
    // fires precisely at the configured time (jitter doesn't apply).
    _node_alive.assign(static_cast<size_t>(n), true);
    for (int i = 0; i < n; ++i) {
        if (_cfg.nodes[i].start_at_ms > 0) {
            _node_alive[i] = false;
            _node_init_at_ms[i] =
                static_cast<uint64_t>(_cfg.nodes[i].start_at_ms);
        }
    }
```

- [ ] **Step 3.3: Implement `processLifecycleAtStep`**

In `orchestrator/runtime/SimController.cpp`, find the `processStartupAtStep` definition (around line 465):

```cpp
void SimController::processStartupAtStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_nodes.size());
```

Insert a new function right BEFORE it:

```cpp
void SimController::processLifecycleAtStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_nodes.size());

    // Births: for each not-yet-alive node whose start_at_ms has been
    // reached, flip _node_alive and emit node_started. The matching
    // on_init runs in processStartupAtStep (called after this).
    for (int i = 0; i < n; ++i) {
        const uint64_t start_at =
            static_cast<uint64_t>(_cfg.nodes[i].start_at_ms);
        if (!_node_alive[i] && start_at > 0 && now >= start_at) {
            _node_alive[i] = true;
            EventLog::nodeStarted(static_cast<unsigned long>(now),
                                  _cfg.nodes[i].name.c_str());
        }
    }

    // Deaths: for each currently-alive node whose dies_at_ms has been
    // reached, flip _node_alive, emit node_died, and drop any in-flight
    // TX from that sender so receivers don't see ghost deliveries.
    for (int i = 0; i < n; ++i) {
        const uint64_t dies_at =
            static_cast<uint64_t>(_cfg.nodes[i].dies_at_ms);
        if (_node_alive[i] && dies_at > 0 && now >= dies_at) {
            _node_alive[i] = false;
            EventLog::nodeDied(static_cast<unsigned long>(now),
                               _cfg.nodes[i].name.c_str());
            _in_flight.erase(
                std::remove_if(_in_flight.begin(), _in_flight.end(),
                               [i](const InFlight& f) { return f.sender_id == i; }),
                _in_flight.end());
        }
    }
}
```

- [ ] **Step 3.4: Call `processLifecycleAtStep` at the top of `step()`**

In `orchestrator/runtime/SimController.cpp`, find the `step()` body (around lines 1281-1310). The `warmup_end` emit block is at lines 1283-1295; the per-step helpers start at line 1306. Find:

```cpp
    {
        const uint64_t warmup_ms =
            static_cast<uint64_t>(_cfg.simulation.warmup_ms);
        if (!_warmup_end_emitted && warmup_ms > 0 && _now_ms >= warmup_ms) {
            EventLog::warmupEnd(static_cast<unsigned long>(warmup_ms));
            _warmup_end_emitted = true;
        }
    }

    // Drive the asymmetry-coherence-driven re-sample of per-pair shadows.
```

Insert a call to `processLifecycleAtStep()` between the warmup block and the path-loss-resample block:

```cpp
    {
        const uint64_t warmup_ms =
            static_cast<uint64_t>(_cfg.simulation.warmup_ms);
        if (!_warmup_end_emitted && warmup_ms > 0 && _now_ms >= warmup_ms) {
            EventLog::warmupEnd(static_cast<unsigned long>(warmup_ms));
            _warmup_end_emitted = true;
        }
    }

    // Lifecycle: node_started / node_died transitions. Runs before the
    // path-loss / startup / commands / receptions / timers / TX register
    // pipeline so the rest of the step sees the correct _node_alive state.
    processLifecycleAtStep();

    // Drive the asymmetry-coherence-driven re-sample of per-pair shadows.
```

- [ ] **Step 3.5: Gate `deliverReceptionsForStep` on `_node_alive`**

Find the function (around line 537). The relevant logic loops over receivers (`for (int rcv = 0; rcv < n; ++rcv)`). Currently the only sender skip is `if (rcv == tx.sender_id) continue;`.

Find this block:

```cpp
        for (int rcv = 0; rcv < n; ++rcv) {
            if (rcv == tx.sender_id) continue;

            LinkParams lp;
            if (!_links->getLink(tx.sender_id, rcv, lp)) continue;  // no link
```

Replace with:

```cpp
        // If the SENDER died after starting this in-flight TX,
        // processLifecycleAtStep already removed its _in_flight
        // entries, so we shouldn't see this branch — defensive guard
        // only.
        if (!_node_alive[tx.sender_id]) continue;

        for (int rcv = 0; rcv < n; ++rcv) {
            if (rcv == tx.sender_id) continue;
            // Skip dead / unborn receivers — no rx event, no drops.
            if (!_node_alive[rcv]) continue;

            LinkParams lp;
            if (!_links->getLink(tx.sender_id, rcv, lp)) continue;  // no link
```

- [ ] **Step 3.6: Gate `registerTransmissionsForStep` on `_node_alive`**

Find the function (around line 836). It has TWO sender loops — the warmup instant-route branch (around line 849) and the post-warmup branch (around line 899).

Find the warmup branch:

```cpp
    if (in_warmup) {
        for (int i = 0; i < n; ++i) {
            for (auto& p : _nodes[i]->drainPendingTxs()) {
```

Replace with:

```cpp
    if (in_warmup) {
        for (int i = 0; i < n; ++i) {
            if (!_node_alive[i]) continue;
            for (auto& p : _nodes[i]->drainPendingTxs()) {
```

Find the post-warmup branch (around line 899):

```cpp
    for (int i = 0; i < n; ++i) {
        for (auto& p : _nodes[i]->drainPendingTxs()) {
            const int sf    = (p.sf    >= 0) ? p.sf    : _radios[i]->getSF();
```

Replace with:

```cpp
    for (int i = 0; i < n; ++i) {
        if (!_node_alive[i]) continue;
        for (auto& p : _nodes[i]->drainPendingTxs()) {
            const int sf    = (p.sf    >= 0) ? p.sf    : _radios[i]->getSF();
```

Same in the warmup branch's inner receiver loop (around line 873):

```cpp
                for (int r = 0; r < n; ++r) {
                    if (r == i) continue;
                    LinkParams lp;
                    if (!_links->getLink(i, r, lp)) continue;
                    _nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
```

Replace with:

```cpp
                for (int r = 0; r < n; ++r) {
                    if (r == i) continue;
                    if (!_node_alive[r]) continue;
                    LinkParams lp;
                    if (!_links->getLink(i, r, lp)) continue;
                    _nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
```

- [ ] **Step 3.7: Gate `tickTimersForStep` on `_node_alive`**

Find the function (around line 828):

```cpp
void SimController::tickTimersForStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_cfg.nodes.size());
    for (int i = 0; i < n; ++i) {
        _nodes[i]->tickTimers(now);
    }
}
```

Replace with:

```cpp
void SimController::tickTimersForStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_cfg.nodes.size());
    for (int i = 0; i < n; ++i) {
        if (!_node_alive[i]) continue;
        _nodes[i]->tickTimers(now);
    }
}
```

- [ ] **Step 3.8: Gate `processCommandsAtStep` on `_node_alive`**

Find the function (around line 505) — the loop that iterates `_cfg.commands`. The command struct has a `node` name. Find the dispatch after the at_ms gate and before the `cmd_reply` emit:

Look for the lookup of the target node (search for `_name_to_id`):

```bash
grep -n "name_to_id\|node_idx\|cmd.node" orchestrator/runtime/SimController.cpp | head -10
```

Inside `processCommandsAtStep`, find where the command is dispatched to a node (the line that calls a method on `_nodes[idx]`). Just before that call, insert:

```cpp
        if (!_node_alive[idx]) continue;  // dead/unborn node — skip
```

The exact insertion point: find the line that resolves the node id from the command's node name (something like `auto it = _name_to_id.find(cmd.node);`), and add the guard right after the lookup succeeded. Refer to the existing `_command_fired[k]` guard for the right place.

- [ ] **Step 3.9: Build**

```bash
cmake --build build -j 2>&1 | tail -5
```

Expected: `[100%] Built target lus`. No warnings, no errors.

- [ ] **Step 3.10: Smoke-run an existing scenario to confirm no regression yet**

Run:
```bash
bash test/run_tests.sh test/t01_flooder.json
```

Expected: `t01_flooder ... PASS`. (No `start_at_ms` / `dies_at_ms` set on any node, so the lifecycle path is dormant — full-suite run later in Task 6.)

- [ ] **Step 3.11: Commit**

```bash
git add orchestrator/runtime/SimController.h orchestrator/runtime/SimController.cpp
git commit -m "$(cat <<'EOF'
feat(runtime): wire start_at_ms + dies_at_ms lifecycle gating

Adds _node_alive bool vector and processLifecycleAtStep() that runs
at the top of each step. Births: flip alive + emit node_started.
Deaths: flip dead + emit node_died + drop pending in-flight TXes
from the dying sender. Every per-step helper (deliverReceptions,
registerTransmissions, tickTimers, processCommands) skips
dead/unborn nodes via the _node_alive[i] guard.

For nodes with start_at_ms > 0, _node_init_at_ms is overridden
to start_at_ms so the existing processStartupAtStep fires on_init
at the same instant as the node_started event.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Integration test — node dies

**Files:**
- Create: `test/t24_node_dies.json`

- [ ] **Step 4.1: Create the scenario**

Create `test/t24_node_dies.json`:

```json
{
  "_name": "t24_node_dies",
  "_desc": "relay dies at t=5000. ping1 (sent at t=2000) delivers via relay; ping2 (sent at t=10000) cannot reach bob since relay is dead, so alice rts_giveup eventually fires.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "relay", "script": "examples/flooder.lua", "config": { "role": "forwarder" }, "dies_at_ms": 5000 },
    { "name": "bob",   "script": "examples/flooder.lua", "config": { "role": "forwarder" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "relay", "snr": 8.0, "rssi": -80.0, "bidir": true },
      { "from": "relay", "to": "bob",   "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 2000,  "node": "alice", "command": "send ping1" },
    { "at_ms": 10000, "node": "alice", "command": "send ping2" }
  ],
  "expect": [
    { "type": "event_count",         "event_type": "node_died", "count": 1 },
    { "type": "script_emit_contains","node": "bob",   "emit_type": "recv", "value": "ping1" }
  ]
}
```

- [ ] **Step 4.2: Build + run**

```bash
cmake --build build -j 2>&1 | tail -3
bash test/run_tests.sh test/t24_node_dies.json
```

Expected: `t24_node_dies ... PASS`. The two assertions match: exactly one `node_died` (relay) and bob received ping1 before relay died. ping2 silently fails because alice's flooder script likely has no protocol-level retry — the absence of `ping2` delivery is the implicit signal.

- [ ] **Step 4.3: Commit**

```bash
git add test/t24_node_dies.json
git commit -m "$(cat <<'EOF'
test(t24): node-dies integration scenario for lifecycle feature

3-node line alice→relay→bob with dies_at_ms=5000 on relay.
ping1 at t=2000 delivers; ping2 at t=10000 has no path because
relay is dead. Asserts node_died fires once and ping1 was
delivered.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Integration test — node starts late

**Files:**
- Create: `test/t25_node_starts.json`

- [ ] **Step 5.1: Create the scenario**

Create `test/t25_node_starts.json`:

```json
{
  "_name": "t25_node_starts",
  "_desc": "relay born at t=5000. ping1 (sent at t=2000) cannot reach bob since relay isn't born yet; ping2 (sent at t=10000) delivers via relay.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "relay", "script": "examples/flooder.lua", "config": { "role": "forwarder" }, "start_at_ms": 5000 },
    { "name": "bob",   "script": "examples/flooder.lua", "config": { "role": "forwarder" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "relay", "snr": 8.0, "rssi": -80.0, "bidir": true },
      { "from": "relay", "to": "bob",   "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 2000,  "node": "alice", "command": "send ping1" },
    { "at_ms": 10000, "node": "alice", "command": "send ping2" }
  ],
  "expect": [
    { "type": "event_count",         "event_type": "node_started", "count": 1 },
    { "type": "event_count_min",     "event_type": "node_ready",   "min": 3 },
    { "type": "script_emit_contains","node": "bob", "emit_type": "recv", "value": "ping2" }
  ]
}
```

- [ ] **Step 5.2: Run**

```bash
bash test/run_tests.sh test/t25_node_starts.json
```

Expected: `t25_node_starts ... PASS`.

- [ ] **Step 5.3: Commit**

```bash
git add test/t25_node_starts.json
git commit -m "$(cat <<'EOF'
test(t25): node-starts integration scenario for lifecycle feature

3-node line alice→relay→bob with start_at_ms=5000 on relay.
ping1 at t=2000 cannot reach bob (relay not yet born); ping2 at
t=10000 delivers. Asserts node_started fires once, all three
node_ready events fire (deferred relay's included).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update webapp pydantic schema

**Files:**
- Modify: `webapp/server/models/schemas.py` (NodeConfig around line 92-107)

- [ ] **Step 6.1: Add the fields to `NodeConfig`**

In `webapp/server/models/schemas.py`, find:

```python
class NodeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=64)
    script: str = Field(min_length=1)
    config: dict = Field(default_factory=dict)
    lat: Optional[float] = Field(default=None, ge=-90.0, le=90.0)
    lon: Optional[float] = Field(default=None, ge=-180.0, le=180.0)
    sf: Optional[int] = Field(default=None, ge=5, le=12)
    bw: Optional[int] = None  # kHz
    cr: Optional[int] = Field(default=None, ge=1)  # see RadioConfig.cr note
    sf_rx_set: Optional[List[int]] = None
    # Per-node radio override (alternative to flat sf/bw/cr).
    radio: Optional[NodeRadioOverride] = None
    # Stochastic per-TX failure probability ([0, 1]).
    tx_fail_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
```

Add two fields just before the closing of the class (after `tx_fail_prob`):

```python
    # Stochastic per-TX failure probability ([0, 1]).
    tx_fail_prob: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    # Lifecycle scheduling. start_at_ms: node fully off until this
    # sim-time. dies_at_ms: node fully off after this sim-time. Both
    # validated by the C++ runtime against simulation.duration_ms.
    start_at_ms: Optional[int] = Field(default=None, ge=1)
    dies_at_ms: Optional[int] = Field(default=None, ge=1)
```

- [ ] **Step 6.2: Run webapp pytest to confirm no regression**

```bash
cd webapp && python -m pytest tests/ -q
```

Expected: previous count, all green. (No new tests yet — added in Task 8.)

- [ ] **Step 6.3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/models/schemas.py
git commit -m "$(cat <<'EOF'
feat(webapp/schemas): add nodes[].start_at_ms + dies_at_ms

Pydantic NodeConfig now accepts the two lifecycle fields the C++
JsonConfig already validates. Both must be >= 1 if set
(0 is the not-scheduled sentinel handled C++-side); cross-field
constraints (vs duration_ms, vs each other) live in the C++
validator and surface to the user as scenario-load errors.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update webapp event_index metadata set

**Files:**
- Modify: `webapp/server/services/event_index.py` (line ~237 in `_METADATA_TYPES`)

- [ ] **Step 7.1: Add the new event types**

Find the frozenset:

```python
    _METADATA_TYPES = frozenset((
        "sim_start", "sim_end", "warmup_end", "node_ready",
        "sim_summary", "assertions", "node_stats",
    ))
```

Replace with:

```python
    _METADATA_TYPES = frozenset((
        "sim_start", "sim_end", "warmup_end", "node_ready",
        "node_started", "node_died",
        "sim_summary", "assertions", "node_stats",
    ))
```

- [ ] **Step 7.2: Run webapp pytest**

```bash
cd webapp && python -m pytest tests/ -q
```

Expected: all green (previous count).

- [ ] **Step 7.3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/server/services/event_index.py
git commit -m "$(cat <<'EOF'
feat(webapp/event_index): treat node_started + node_died as metadata

These are lifecycle markers, not packet-level events. Adding them
to _METADATA_TYPES keeps them out of the contiguous indexed event
range — same pattern as warmup_end (962fa7d).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Webapp pytest for lifecycle events

**Files:**
- Create: `webapp/tests/test_node_lifecycle_events.py`

- [ ] **Step 8.1: Create the test file**

Create `webapp/tests/test_node_lifecycle_events.py`:

```python
"""Asserts that node_started and node_died NDJSON events fire at the
configured times and that the node is fully invisible / silent
outside its [start_at_ms, dies_at_ms] window.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
T24 = REPO_ROOT / "test" / "t24_node_dies.json"
T25 = REPO_ROOT / "test" / "t25_node_starts.json"


def _run_lus(tmp_path, scenario: Path) -> list[dict]:
    if not LUS.exists():
        pytest.skip("lus binary missing: build with `cmake --build build -j`")
    if not scenario.exists():
        pytest.skip(f"scenario missing: {scenario}")
    out = tmp_path / f"{scenario.stem}_events.ndjson"
    subprocess.run(
        [str(LUS), str(scenario), str(out)],
        check=True, capture_output=True, cwd=REPO_ROOT,
    )
    return [json.loads(line) for line in out.open() if line.strip()]


def test_node_died_event_fires_at_configured_time(tmp_path):
    events = _run_lus(tmp_path, T24)
    deaths = [e for e in events if e.get("type") == "node_died"]
    assert len(deaths) == 1, f"expected one node_died, got {len(deaths)}"
    assert deaths[0]["time_ms"] == 5000
    assert deaths[0]["node"] == "relay"


def test_relay_is_silent_after_death(tmp_path):
    events = _run_lus(tmp_path, T24)
    # No tx/rx events with relay as from or to after t=5000.
    after = [
        e for e in events
        if e.get("time_ms", 0) > 5000
        and e.get("type") in ("tx", "rx")
        and (e.get("from") == "relay" or e.get("to") == "relay")
    ]
    assert after == [], f"relay should be silent after t=5000; found {after[:3]}"


def test_node_started_event_fires_at_configured_time(tmp_path):
    events = _run_lus(tmp_path, T25)
    births = [e for e in events if e.get("type") == "node_started"]
    assert len(births) == 1, f"expected one node_started, got {len(births)}"
    assert births[0]["time_ms"] == 5000
    assert births[0]["node"] == "relay"


def test_relay_is_invisible_before_birth(tmp_path):
    events = _run_lus(tmp_path, T25)
    # No tx/rx events with relay as from or to before t=5000.
    before = [
        e for e in events
        if e.get("time_ms", 0) < 5000
        and e.get("type") in ("tx", "rx")
        and (e.get("from") == "relay" or e.get("to") == "relay")
    ]
    assert before == [], f"relay should be invisible before t=5000; found {before[:3]}"


def test_relay_node_ready_fires_at_birth(tmp_path):
    events = _run_lus(tmp_path, T25)
    relay_ready = [
        e for e in events
        if e.get("type") == "node_ready" and e.get("node") == "relay"
    ]
    assert len(relay_ready) == 1, f"expected one node_ready for relay, got {len(relay_ready)}"
    assert relay_ready[0]["time_ms"] == 5000
```

- [ ] **Step 8.2: Run the new tests**

```bash
cd webapp && python -m pytest tests/test_node_lifecycle_events.py -v
```

Expected: 5 tests pass.

- [ ] **Step 8.3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/tests/test_node_lifecycle_events.py
git commit -m "$(cat <<'EOF'
test(webapp): pytest cases for node_started + node_died events

Five pytest cases covering: time_ms exactness, relay-silent-after-
death, time_ms exactness for births, relay-invisible-before-birth,
and node_ready firing at birth-time for deferred-start nodes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Verify no regressions

This task runs only — no code changes.

- [ ] **Step 9.1: Full integration suite**

```bash
bash test/run_tests.sh
```

Expected: 32/32 passed (was 30 + t24 + t25 = 32). Including:
- t24_node_dies, t25_node_starts (new)
- All previous 30 still PASS

- [ ] **Step 9.2: Native C++ tests**

```bash
bash test/native/build_test.sh
```

Expected: all pass (no native test changes; sanity check only).

- [ ] **Step 9.3: Webapp pytest suite**

```bash
cd webapp && python -m pytest tests/ -q
```

Expected: previous count + 5 (the new pytest file's cases). All green.

If any step fails, root-cause and fix in a follow-up commit. Do NOT proceed to the K=3 plan with regressions outstanding.

No commit needed for this task.

---

## Self-Review Notes

- **Spec coverage:** The plan implements every section of the spec — NodeDef fields (Task 1), validation (Task 1), EventLog methods (Task 2), `_node_alive` + `processLifecycleAtStep` + step-helper gating (Task 3), both integration test scenarios (Tasks 4 + 5), webapp pydantic schema (Task 6), webapp event_index metadata (Task 7), pytest coverage (Task 8), regression checks (Task 9).
- **Out of scope items deferred per spec:** resurrection, MTBF stochastic models, battery drain, Lua-side death notification — none of these appear in this plan, matching the spec's "Out of scope" list.
- **No placeholders:** All commands, code blocks, file paths, and expected outputs are concrete.
- **Type consistency:** `_node_alive` is declared in Task 3.1, initialized in 3.2, consulted in 3.5/3.6/3.7/3.8, and toggled in 3.3. `processLifecycleAtStep` declared in 3.1 and defined in 3.3. `nodeStarted` / `nodeDied` declared/defined in Task 2 and called in 3.3.
- **Frequent commits:** 8 commits across 9 tasks (Task 9 is verification-only). Each commit is independently buildable + green.
