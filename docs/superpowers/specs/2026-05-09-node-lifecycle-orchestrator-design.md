# Node-Lifecycle Orchestrator Feature — Design

Status: design (awaiting user review)
Author: 2026-05-09 session
Motivated by: K=3 multi-alt routing test scenarios (sibling spec
`2026-05-09-k3-multi-alt-routing-design.md`) plus general failure-
mode + new-node-join testing infrastructure.

## Background

To exercise lifecycle protocol logic — failure-mode (e.g. K=3
routing's cascade on `rts_giveup` when the primary next-hop
disappears) and join-mode (new node powering on into an established
mesh) — the orchestrator needs scheduled control over each node's
existence:

- **Death**: a node was running, then went away (powered off,
  crashed, moved out of range).
- **Late start**: a node didn't exist at t=0 but joined the mesh
  later.

Today the only way to make a node unavailable is to never configure
it; the only way to defer init is via `simulation.node_startup_jitter_ms`,
which is sim-wide, randomized, and bounded to small values (~500 ms).
Neither models the "node was off / now on" or "node was on / now off"
narrative cleanly.

This is reusable infrastructure: many future tests will want it
(e.g. "new node joins, does the protocol discover it?"; "primary
forwarder dies, does the protocol recover?"). Worth building once
in the orchestrator rather than re-deriving in each script.

## Goal

Add two paired optional JSON config fields:

- `nodes[].start_at_ms` — node is fully off (no rx, no tx, no
  scripts, no on_init) until this sim-time. At t=`start_at_ms` it
  initializes (on_init fires, `node_ready` emitted, beacons begin).
- `nodes[].dies_at_ms` — node stops fully at this sim-time.
  Modeling a powered-off radio: no rx, no tx, no script timers, no
  commands.

A new pair of NDJSON events marks the transitions:

- `node_started` — emitted when a deferred-start node initializes.
  The existing `node_ready` event still fires at the same instant
  (carrying role / location); `node_started` is its lifecycle-
  marker sibling for nodes whose start was deferred. For nodes
  with no `start_at_ms`, `node_ready` alone fires (today's behavior
  unchanged).
- `node_died` — emitted when a node dies.

A node may have either field, both (start, then die), or neither
(default — full-duration life from t=0, today's behavior).

## Scope

- C++ orchestrator changes only.
- Two paired JSON fields, two new event types, two lifecycle checks
  at the top of step.
- Two integration test scenarios (one per lifecycle event).
- One pytest covering both events.

## Out of scope

- Resurrection (dies_at_ms is one-shot — a real powered-off device
  doesn't come back without operator action). Multiple
  death/restart cycles are not supported.
- Rolling failures / mean-time-between-failures stochastic models.
- Battery drain or graceful shutdown (the device just stops; no
  in-flight TX is allowed to complete).
- Lua-side death notification — scripts have no API to detect they
  are about to die. (A real device doesn't gracefully shut down.)
- Per-node `start_at_ms` interaction with `node_startup_jitter_ms`
  is overridden: if `start_at_ms` is set, the per-node init time is
  exactly `start_at_ms`; jitter doesn't apply. Nodes without
  `start_at_ms` keep the existing jittered behavior.

## JSON config

`nodes[].start_at_ms`: optional unsigned integer. If present, must
satisfy `0 < start_at_ms < simulation.duration_ms`.

`nodes[].dies_at_ms`: optional unsigned integer. If present, must
satisfy `0 < dies_at_ms < simulation.duration_ms`. If both are
present, `start_at_ms < dies_at_ms` is required.

```json
{
  "nodes": [
    { "name": "alice",   "script": "...", "dies_at_ms": 30000 },
    { "name": "newcomer","script": "...", "start_at_ms": 20000 },
    { "name": "transient","script": "...","start_at_ms": 10000, "dies_at_ms": 40000 }
  ]
}
```

Default for either field is "absent" (no schedule). The webapp's
pydantic schema gets the same fields with the same constraints.

## Event shapes

```json
{"type":"node_started","time_ms":<actual_start_time>,"node":"<name>"}
{"type":"node_died","time_ms":<actual_kill_time>,"node":"<name>"}
```

Each emitted exactly once per node. The `time_ms` equals the
configured value (step-aligned). `node_ready` continues to fire
once per node alongside `node_started` for deferred-start nodes
(unchanged for default-start nodes).

## Implementation outline

`core/topology/JsonConfig.h` — add to `NodeConfig`:

```cpp
unsigned long start_at_ms = 0;  // 0 = default-start (t=0 + jitter)
unsigned long dies_at_ms  = 0;  // 0 = no death scheduled
```

`core/topology/JsonConfig.cpp` — parse + validate both fields. The
constraint `start_at_ms < dies_at_ms` is checked when both are set
(both > 0).

`core/events/EventLog.{h,cpp}` — `nodeStarted(time_ms, node)` and
`nodeDied(time_ms, node)`. Same trivial shape pattern as
`warmupEnd` and `nodeReady`.

`orchestrator/runtime/SimController.{h,cpp}`:

- Add `std::vector<bool> _node_alive` initialized in `initialize()`:
  - `true` for nodes with `start_at_ms == 0` (alive from t=0)
  - `false` for nodes with `start_at_ms > 0` (deferred)
- Override `_node_init_at_ms[i] = start_at_ms` for nodes with
  `start_at_ms > 0`. The jitter assignment for these nodes is
  skipped; `start_at_ms` is exact.
- Add `processLifecycleAtStep()` called at the top of `step()`
  (parallel to where `warmupEnd` was added). Two passes:
  1. **Births**: for each node `i` with `start_at_ms > 0` and
     `_now_ms >= start_at_ms` and `!_node_alive[i]`: set
     `_node_alive[i] = true`, emit `node_started`. (The existing
     `processStartupAtStep` then runs `on_init` and emits
     `node_ready` in the same step.)
  2. **Deaths**: for each node `i` with `dies_at_ms > 0` and
     `_now_ms >= dies_at_ms` and `_node_alive[i]`: set
     `_node_alive[i] = false`, emit `node_died`, and clear any
     in-flight transmission the node has (compact `_in_flight` to
     drop entries with `sender_id == i`).
- In `deliverReceptionsForStep`, skip senders `tx.sender_id` and
  receivers `rcv` where `_node_alive[*] == false` (no rx events to
  or from dead/unborn nodes).
- In `registerTransmissionsForStep`, skip senders where
  `_node_alive[i] == false`.
- In `tickTimersForStep`, skip nodes where `_node_alive[i] == false`.
- In `processCommandsAtStep`, skip commands targeting dead/unborn
  nodes.

The lifecycle checks run ONCE per node per transition (the
`_node_alive[i]` toggle prevents re-emission).

`processStartupAtStep` (the existing init-firing function) needs
no logic change — it already polls `_node_init_at_ms[i] >= now`
and fires `on_init` then. The lifecycle pass simply ensures the
`_node_alive[i]` flag is `true` before init runs.

## Test

**Integration scenario A** `test/t24_node_dies.json`:
- 3-node line: `alice ↔ relay ↔ bob`, both bidir links good SNR.
- `relay.dies_at_ms = 5000`.
- `commands`: alice sends "ping1" at t=2000 (delivered via relay),
  alice sends "ping2" at t=10000 (cannot reach bob — relay dead).
- `expect`:
  - `event_count` for `node_died` == 1.
  - `script_emit_contains` at `bob` with `emit_type=delivered` and
    `value="ping1"`.
  - `script_emit_contains` at `alice` with `emit_type=rts_giveup`
    (any value — proves alice gave up on ping2).

**Integration scenario B** `test/t25_node_starts.json`:
- 3-node line: `alice ↔ relay ↔ bob`, links present, but `relay`
  has `start_at_ms = 5000`.
- `commands`: alice sends "ping1" at t=2000 (FAILS — relay not
  born yet), alice sends "ping2" at t=10000 (delivered via relay).
- `expect`:
  - `event_count` for `node_started` == 1.
  - `event_count` for `node_ready` == 3 (all three nodes
    initialized at some point, including the deferred relay).
  - `script_emit_contains` at `bob` with `emit_type=delivered` and
    `value="ping2"`.
  - `script_emit_contains` at `alice` with `emit_type=rts_giveup`
    for ping1 (relay not yet born).

**Webapp pytest** `webapp/tests/test_node_lifecycle_events.py`:
- Subprocess-runs `lus` on each scenario.
- Asserts for `t24_node_dies`:
  - Exactly one `node_died` event, `time_ms == 5000`,
    `node == "relay"`.
  - No events with `from == "relay"` or `to == "relay"` after
    t=5000 (proves relay is fully silent).
- Asserts for `t25_node_starts`:
  - Exactly one `node_started` event, `time_ms == 5000`,
    `node == "relay"`.
  - No events with `from == "relay"` or `to == "relay"` BEFORE
    t=5000 (proves relay is fully invisible until birth).
  - The `node_ready` event for relay also fires at t=5000.

## Risks

- **Compatibility:** Older NDJSON consumers see two new event
  types (`node_started`, `node_died`). The webapp
  `EventIndex._METADATA_TYPES` should add both (parallel to the
  warmup_end pattern from `962fa7d`); no other consumer changes
  required.
- **In-flight TX cleanup on death:** clearing `_in_flight` entries
  with `sender_id == dying_node` is necessary so receivers don't
  see delayed deliveries from the dead sender. Behavior: any TX
  initiated before `dies_at_ms` but not yet delivered evaporates.
  Real hardware doesn't transmit RF after power-off.
- **Lua-side surprise on death:** scripts have no way to detect
  they are about to die; pending `after()` callbacks are silently
  stranded. Intentional.
- **`node_startup_jitter_ms` interaction:** for nodes with
  `start_at_ms > 0`, jitter doesn't apply (the operator wants
  exact birth time). For nodes without `start_at_ms`, jitter
  behaves exactly as today.

## Acceptance criteria

- `t24_node_dies.json` and `t25_node_starts.json` integration
  tests pass.
- `test_node_lifecycle_events.py` pytest cases pass.
- Existing 30 integration tests remain green.
- Webapp pytest suite still passes (with the new test file's
  cases added).
