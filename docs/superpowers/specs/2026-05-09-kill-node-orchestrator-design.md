# Kill-Node Orchestrator Feature — Design

Status: design (awaiting user review)
Author: 2026-05-09 session
Motivated by: K=3 multi-alt routing test scenarios (sibling spec
`2026-05-09-k3-multi-alt-routing-design.md`).

## Background

To exercise failure-mode protocol logic (e.g. K=3 routing's cascade
on `rts_giveup` when the primary next-hop disappears mid-flight), the
orchestrator needs a way to "switch off" a node at a scheduled
sim-time. Today the only way to make a node unavailable is to never
configure it, or to configure links with poor SNR — neither models
"node was working, then died" the way a real network failure would.

This is reusable infrastructure: many future failure-mode tests will
want it (e.g. "primary dies, does the protocol recover?"). Worth
building once in the orchestrator rather than re-deriving in each
script.

## Goal

Add a `nodes[].dies_at_ms` JSON config field. When set, the
orchestrator stops all activity for that node at the specified
sim-time, modeling a powered-off radio. The node:

- Receives no further packets (skipped in `deliverReceptionsForStep`).
- Sends no further packets (any pending TX cleared; new TXes from
  pending Lua timers are dropped).
- Runs no further script timers (skipped in `tickTimersForStep`).
- Receives no further commands (skipped in `processCommandsAtStep`).

A new `node_died` NDJSON event marks the transition. After death,
the node is silent; no events are emitted from it.

## Scope

- C++ orchestrator changes only.
- One JSON field, one event type, one death-check at the top of step.
- One integration test scenario proving the kill works.
- One pytest case for the event emission.

## Out of scope

- Resurrection (dies_at_ms is one-shot — a real powered-off device
  doesn't come back without operator action).
- Rolling failures / mean-time-between-failures stochastic models.
- Battery drain or graceful shutdown (the device just stops; no
  in-flight TX is allowed to complete).

## JSON config

`nodes[].dies_at_ms`: optional unsigned integer. If present, must be
strictly greater than 0 and strictly less than `simulation.duration_ms`.

```json
{
  "nodes": [
    { "name": "alice", "script": "...", "dies_at_ms": 30000 }
  ]
}
```

If absent, the node lives the full duration (today's behavior).
Default for the field is "absent" (no death scheduled).

The webapp's pydantic schema gets the same field with the same
constraints.

## Event shape

```json
{"type":"node_died","time_ms":<actual_kill_time>,"node":"<name>"}
```

Emitted exactly once per dead node. The `time_ms` is the actual
sim-time the kill fired (which equals `dies_at_ms` due to step-by-
step semantics).

## Implementation outline

`core/topology/JsonConfig.h` — add `unsigned long dies_at_ms = 0;`
to `NodeConfig`. 0 means "no death scheduled" (sentinel — same
convention `warmup_ms` uses).

`core/topology/JsonConfig.cpp` — parse the field, validate
`dies_at_ms < duration_ms` (zero is allowed = no death).

`core/events/EventLog.{h,cpp}` — `nodeDied(time_ms, node)`. Same
trivial shape as `warmupEnd` and `nodeReady`.

`orchestrator/runtime/SimController.{h,cpp}`:

- Add `std::vector<bool> _node_alive` initialized to `true` for all
  nodes in `initialize()`.
- Add helper `processDeathsAtStep()` called at the top of `step()`
  before any other per-step work (analogous to where `warmupEnd` was
  added). For each node `i` with `_cfg.nodes[i].dies_at_ms > 0` and
  `_now_ms >= dies_at_ms` and `_node_alive[i]`: emit `node_died`,
  set `_node_alive[i] = false`, and clear any in-flight transmission
  the node has (compact `_in_flight` to drop entries with
  `sender_id == i`).
- In `deliverReceptionsForStep`, skip receivers where
  `_node_alive[r] == false` (no rx events emitted to dead nodes).
- In `registerTransmissionsForStep`, skip senders where
  `_node_alive[i] == false` (drainPendingTxs returns nothing usable;
  any queued TX is silently lost — matches a real radio losing its
  TX queue on power-off).
- In `tickTimersForStep`, skip nodes where `_node_alive[i] == false`
  (no Lua timer callbacks fire after death — pending after() calls
  are stranded).
- In `processCommandsAtStep`, skip commands targeting dead nodes.

The death check in `processDeathsAtStep` runs ONCE per node (the
`_node_alive[i]` guard prevents re-emission), parallel to the
`_warmup_end_emitted` flag pattern.

## Test

**Integration scenario** `test/t24_kill_node.json`:
- 3-node line: `alice ↔ relay ↔ bob`, both bidir links good SNR.
- `relay` has `dies_at_ms: 5000`.
- `commands`: alice sends "ping1" at t=2000 (delivered via relay),
  alice sends "ping2" at t=10000 (cannot reach bob — relay dead).
- `expect`:
  - `event_count` for `node_died` == 1 (top-level event).
  - `script_emit_contains` at `bob` with `emit_type=delivered` and
    `value="ping1"`.
  - `script_emit_contains` at `alice` with `emit_type=rts_giveup`
    (any value — proves alice gave up on ping2 since relay is silent).
  - The `expect` runner doesn't have time-bound checks for
    individual events; the count + content assertions cover behavior.

**Webapp pytest** `webapp/tests/test_node_died_event.py`:
- Subprocess-runs `lus` on `t24_kill_node.json`.
- Asserts: exactly one `node_died` event, its `time_ms == 5000`,
  its `node == "relay"`.
- Asserts: no events with `from == "relay"` or `to == "relay"`
  after t=5000 (proves relay is fully silent after death).

## Risks

- **Compatibility:** Older NDJSON consumers see a new event type.
  The webapp `EventIndex._METADATA_TYPES` should add `node_died`
  (parallel to the warmup_end pattern from `962fa7d`); no other
  consumer changes required.
- **In-flight TX cleanup:** clearing `_in_flight` entries with
  `sender_id == dying_node` is necessary so receivers don't see
  delayed deliveries from the dead sender. Behavior: any TX
  initiated before `dies_at_ms` but not yet delivered to the
  receiver evaporates. This matches "radio dies mid-burst" — real
  hardware doesn't transmit RF after power-off.
- **Lua-side surprise:** scripts have no way to detect they are
  about to die; pending `after()` callbacks are silently stranded.
  This is intentional — a real device doesn't gracefully shut down.

## Acceptance criteria

- `t24_kill_node.json` integration test passes.
- `test_node_died_event.py` pytest cases pass (count, time_ms,
  silence-after-death).
- Existing 30 integration tests remain green.
- Webapp pytest suite still passes (with `+1` for the new test
  file's cases).
