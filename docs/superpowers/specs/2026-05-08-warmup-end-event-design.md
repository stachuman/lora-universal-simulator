# `warmup_end` Event — Design

Status: design-approved (awaiting plan)
Author: 2026-05-08 session

## Background

`simulation.warmup_ms` defines an initial window during which the
orchestrator delivers every drained TX instantly to all linked
receivers, bypassing collisions, duty-cycle, half-duplex, drop_weak,
drop_loss, SF-mismatch and LBT (`SimController.cpp:849-897`). Post-
warmup, the full physics pipeline takes over.

Today the NDJSON event stream contains no marker at the boundary. A
viewer scanning the log has to know `warmup_ms` from the `sim_start`
event and compare against every event's `time_ms`. Visualizers and
log analyzers can't render or filter "physics turns on here"
directly.

## Goal

Emit a single `warmup_end` event at `time_ms == warmup_ms` to
explicitly mark the transition, so downstream tools (the swim-lane
visualizer, map-live replay, log diffing, future test assertions)
have a stable anchor.

## Scope

- C++ runtime only: new `EventLog` method + a one-shot emission point
  in `SimController` step loop.
- One integration test scenario (`test/t23_warmup_end.json`) that
  asserts the event fires at the right time.

## Out of scope

- Visualizer / map_live UI rendering of the boundary line — separate
  follow-up.
- Any change to warmup *behavior*. The instant-delivery semantic
  stays as-is.
- Lua-side callback (`on_warmup_end`) or helpers (`self:in_warmup()`).
  Not requested; can come later.

## Event shape

```json
{"type":"warmup_end","time_ms":<warmup_ms>}
```

No additional fields. The `time_ms` is the configured `warmup_ms`,
i.e. the first sim-time at which `in_warmup` evaluates false. Mirrors
the minimalism of `sim_end`.

## Emission rules

1. Fires exactly once per simulation.
2. Skipped entirely if `warmup_ms == 0` (no boundary to mark — the
   simulation runs in post-warmup mode from t=0).
3. Naturally never fires if `warmup_ms >= duration_ms` (validator
   already rejects equality, but the guard is harmless).
4. Position in the step: at the **top** of the step that crosses the
   boundary, before `deliverReceptionsForStep` /
   `registerTransmissionsForStep` run. This ensures any post-warmup
   physics events emitted during that same step are ordered after
   `warmup_end`, which is the order a reader expects.

## Implementation outline

`core/events/EventLog.h` / `.cpp`:

```cpp
void warmupEnd(unsigned long time_ms);
// {"type":"warmup_end","time_ms":<t>}
```

`orchestrator/runtime/SimController.h`:

```cpp
bool _warmup_end_emitted = false;  // reset in init()
```

`orchestrator/runtime/SimController.cpp` — at the top of the per-step
work (in whichever method runs first per step; currently
`stepOnce` / `runUntil`'s loop body):

```cpp
const uint64_t warmup_ms = static_cast<uint64_t>(_cfg.simulation.warmup_ms);
if (!_warmup_end_emitted && warmup_ms > 0 && _now_ms >= warmup_ms) {
    EventLog::warmupEnd(static_cast<unsigned long>(warmup_ms));
    _warmup_end_emitted = true;
}
```

The flag must be reset in `init()` so a re-init (interactive REPL `:reset`,
fresh runs in the webapp) replays the boundary cleanly.

## Test

Two-layer coverage:

**Integration scenario** `test/t23_warmup_end.json`: 2-node scenario,
`warmup_ms: 100`, `duration_ms: 200`, minimal Lua (e.g. an existing
flooder or no-op script). Asserts via the `expect` schema's
`event_count`:

```json
{ "type": "event_count", "event_type": "warmup_end", "count": 1 }
```

This proves the event fires exactly once. The `expect` runner
doesn't currently support time-based assertions, so the
"`time_ms == warmup_ms`" guarantee is checked in:

**Webapp pytest** `webapp/tests/test_warmup_end_event.py`: subprocess
runs `lus` on `test/t23_warmup_end.json`, parses the NDJSON, and
asserts:

- Exactly one `warmup_end` event.
- That event's `time_ms` equals the configured `warmup_ms` (100).
- Event ordering: it appears after `sim_start` and before `sim_end`.
- A second case where the scenario's `warmup_ms == 0`: assert
  **zero** `warmup_end` events.

Native unit-test coverage is not warranted — the behavior is a
trivial guard plus an event emit.

## Risks

- None substantial. The change adds one event to the NDJSON; no
  schema field is removed or renamed.
- Webapp pydantic schema does not need an update — it only validates
  scenario JSON, not event JSON.
- `expect` runner already supports asserting on event types; no
  runner change.
