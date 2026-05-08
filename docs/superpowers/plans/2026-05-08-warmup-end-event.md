# `warmup_end` Event Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit a single `warmup_end` NDJSON event at `time_ms == warmup_ms` to mark the boundary where physics turns on. Behavior of the warmup window itself is unchanged.

**Architecture:** One new `EventLog::warmupEnd` method, one boolean flag on `SimController`, and a top-of-step guard in `SimController::step` that fires the event exactly once per simulation. Skipped if `warmup_ms == 0`.

**Tech Stack:** C++17 (orchestrator + EventLog), Python 3 + pytest (time-ordering assertions), JSON (test scenario).

**Spec:** `docs/superpowers/specs/2026-05-08-warmup-end-event-design.md`

---

## File Structure

| Path | Action | Purpose |
|---|---|---|
| `core/events/EventLog.h` | Modify | Declare `warmupEnd(unsigned long time_ms)` next to `simEnd`. |
| `core/events/EventLog.cpp` | Modify | Implement `warmupEnd` — emit `{"type":"warmup_end","time_ms":<t>}`. |
| `orchestrator/runtime/SimController.h` | Modify | Add `bool _warmup_end_emitted = false;` near `_now_ms`. |
| `orchestrator/runtime/SimController.cpp` | Modify | Reset flag in `init()`; emit + flip flag at top of `step()`. |
| `test/t23_warmup_end.json` | Create | Integration scenario with `warmup_ms: 100`, asserts `event_count(warmup_end) == 1`. |
| `webapp/tests/test_warmup_end_event.py` | Create | pytest: subprocess `lus`, assert `time_ms`, ordering, and the `warmup_ms: 0` no-emit case. |

---

## Task 1: Write the failing integration test

**Files:**
- Create: `test/t23_warmup_end.json`

The scenario uses `examples/quiet.lua` (a no-op Lua script that already exists at the repo root) so the only events we'll see are lifecycle-related — making the `event_count` assertion robust.

- [ ] **Step 1.1: Create the scenario file**

Create `test/t23_warmup_end.json` with this content:

```json
{
  "_name": "t23_warmup_end",
  "_desc": "Asserts a single warmup_end event fires at the boundary. Two no-op nodes; warmup_ms=100, duration_ms=200.",
  "simulation": {
    "duration_ms": 200,
    "step_ms": 1,
    "warmup_ms": 100,
    "seed": 42,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/quiet.lua" },
    { "name": "bob",   "script": "examples/quiet.lua" }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [],
  "expect": [
    { "type": "event_count", "event_type": "warmup_end", "count": 1 }
  ]
}
```

- [ ] **Step 1.2: Run the test, expect FAIL**

Run:
```bash
cmake --build build -j 2>&1 | tail -5 && bash test/run_tests.sh test/t23_warmup_end.json
```

Expected: `t23_warmup_end ... FAIL`. The lus exit code is non-zero because `event_count(warmup_end)` is `0`, not `1`.

If you see `PASS`, something is wrong — abort and investigate (probably the warmup_end event already exists, in which case re-read the spec).

**Do not commit yet.**

---

## Task 2: Add `EventLog::warmupEnd`

**Files:**
- Modify: `core/events/EventLog.h:40` (insert after the `simEnd` line)
- Modify: `core/events/EventLog.cpp` (insert after the `simEnd` definition near line 133)

- [ ] **Step 2.1: Add the declaration in `core/events/EventLog.h`**

Find this block at lines 38-40:

```cpp
void simStart(unsigned long time_ms, int n_nodes, int step_ms,
              unsigned long warmup_ms = 0, bool hot_start = false);
void simEnd(unsigned long time_ms);
```

Insert one line after `simEnd`:

```cpp
void simStart(unsigned long time_ms, int n_nodes, int step_ms,
              unsigned long warmup_ms = 0, bool hot_start = false);
void simEnd(unsigned long time_ms);
// Boundary marker — fires once at sim_time == warmup_ms when warmup_ms > 0.
void warmupEnd(unsigned long time_ms);
```

- [ ] **Step 2.2: Add the implementation in `core/events/EventLog.cpp`**

Find this block at lines 129-133:

```cpp
void simEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"sim_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}
```

Insert after it:

```cpp
void simEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"sim_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}

void warmupEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"warmup_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}
```

- [ ] **Step 2.3: Build and verify it compiles**

Run:
```bash
cmake --build build -j 2>&1 | tail -10
```

Expected: `[100%] Built target lus` with no errors. The integration test will still FAIL — there's no caller of `warmupEnd` yet.

**Do not commit yet.**

---

## Task 3: Wire emission into `SimController`

**Files:**
- Modify: `orchestrator/runtime/SimController.h` near line 192 (where `_now_ms` and `_initialized` are declared)
- Modify: `orchestrator/runtime/SimController.cpp` near line 460 (`init()` — reset flag) and near line 1272 (top of `step()` — emit)

- [ ] **Step 3.1: Add the flag to `SimController.h`**

Find this block (around lines 192-193):

```cpp
    uint64_t _now_ms      = 0;
    bool     _initialized = false;
```

Replace with:

```cpp
    uint64_t _now_ms      = 0;
    bool     _initialized = false;
    // True once the warmup_end NDJSON event has been emitted for this
    // simulation. Flipped at the top of step() the first time _now_ms
    // crosses simulation.warmup_ms; reset to false in init() so re-runs
    // (interactive REPL :reset, fresh webapp runs) replay the boundary.
    bool     _warmup_end_emitted = false;
```

- [ ] **Step 3.2: Reset the flag in `SimController::init()`**

Find this block (around lines 460-461):

```cpp
    _now_ms = 0;
    _initialized = true;
}
```

Replace with:

```cpp
    _now_ms = 0;
    _warmup_end_emitted = false;
    _initialized = true;
}
```

- [ ] **Step 3.3: Emit at top of `step()`**

Find this block in `SimController::step` (around lines 1262-1273):

```cpp
    const int events_before = static_cast<int>(EventLog::events().size());

    // Drive the asymmetry-coherence-driven re-sample of per-pair shadows.
    // Per-node offsets stay fixed; only the pair shadow component drifts.
    if (_path_loss && _now_ms >= _next_pair_shadow_resample_ms) {
        _path_loss->resamplePairShadows();
        rebuildLinksFromPathLoss();
        _next_pair_shadow_resample_ms +=
            _cfg.simulation.path_loss.asymmetry_coherence_ms;
    }

    processStartupAtStep();
```

Replace with:

```cpp
    const int events_before = static_cast<int>(EventLog::events().size());

    // Boundary marker: emit warmup_end exactly once when _now_ms first
    // reaches simulation.warmup_ms. Skipped if warmup_ms == 0 (no
    // boundary). Position: ahead of every other per-step action so any
    // physics events generated during this same step are ordered after
    // the boundary marker, which is what readers expect.
    {
        const uint64_t warmup_ms =
            static_cast<uint64_t>(_cfg.simulation.warmup_ms);
        if (!_warmup_end_emitted && warmup_ms > 0 && _now_ms >= warmup_ms) {
            EventLog::warmupEnd(static_cast<unsigned long>(warmup_ms));
            _warmup_end_emitted = true;
        }
    }

    // Drive the asymmetry-coherence-driven re-sample of per-pair shadows.
    // Per-node offsets stay fixed; only the pair shadow component drifts.
    if (_path_loss && _now_ms >= _next_pair_shadow_resample_ms) {
        _path_loss->resamplePairShadows();
        rebuildLinksFromPathLoss();
        _next_pair_shadow_resample_ms +=
            _cfg.simulation.path_loss.asymmetry_coherence_ms;
    }

    processStartupAtStep();
```

- [ ] **Step 3.4: Build**

Run:
```bash
cmake --build build -j 2>&1 | tail -5
```

Expected: `[100%] Built target lus` — no warnings, no errors.

- [ ] **Step 3.5: Run the integration test, expect PASS**

Run:
```bash
bash test/run_tests.sh test/t23_warmup_end.json
```

Expected: `t23_warmup_end ... PASS` and `1/1 passed`.

- [ ] **Step 3.6: Manual sanity check on the timestamp**

Run:
```bash
grep '"warmup_end"' test/t23_warmup_end_events.ndjson
```

Expected output (exactly one line):
```
{"type":"warmup_end","time_ms":100}
```

If `time_ms` is something other than `100`, the guard fired at the wrong tick — re-read Step 3.3 and check the comparison `_now_ms >= warmup_ms`.

- [ ] **Step 3.7: Commit**

```bash
git add core/events/EventLog.h core/events/EventLog.cpp \
        orchestrator/runtime/SimController.h \
        orchestrator/runtime/SimController.cpp \
        test/t23_warmup_end.json
# (test/t23_warmup_end_events.ndjson is gitignored — see .gitignore)
git commit -m "$(cat <<'EOF'
feat(events): emit warmup_end NDJSON event at warmup boundary

Adds EventLog::warmupEnd plus a one-shot guard at the top of
SimController::step. Fires exactly once per simulation when _now_ms
first reaches simulation.warmup_ms; skipped entirely when
warmup_ms == 0. Behavior of the warmup window itself is unchanged.

Spec: docs/superpowers/specs/2026-05-08-warmup-end-event-design.md
Test: test/t23_warmup_end.json (event_count assertion).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Python pytest for time + ordering + zero-warmup case

**Files:**
- Create: `webapp/tests/test_warmup_end_event.py`

The integration `expect` runner doesn't support time-based assertions, so the `time_ms == warmup_ms` and ordering guarantees go in a Python test that parses the NDJSON directly. Same test also covers the `warmup_ms == 0 → no event` case using `test/t01_flooder.json` (an existing scenario with `warmup_ms: 0`).

- [ ] **Step 4.1: Create the test file**

Create `webapp/tests/test_warmup_end_event.py`:

```python
"""Asserts the warmup_end NDJSON event fires at the right time and is
absent when warmup_ms == 0. Subprocess-runs lus directly so the test
doesn't depend on the FastAPI surface.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
T23 = REPO_ROOT / "test" / "t23_warmup_end.json"           # warmup_ms=100
T01 = REPO_ROOT / "test" / "t01_flooder.json"              # warmup_ms=0


def _run_lus(tmp_path, scenario: Path) -> list[dict]:
    if not LUS.exists():
        pytest.skip(f"lus binary missing: build with `cmake --build build -j`")
    if not scenario.exists():
        pytest.skip(f"scenario missing: {scenario}")
    out = tmp_path / f"{scenario.stem}_events.ndjson"
    subprocess.run(
        [str(LUS), str(scenario), str(out)],
        check=True, capture_output=True, cwd=REPO_ROOT,
    )
    return [json.loads(line) for line in out.open() if line.strip()]


def test_warmup_end_fires_at_boundary(tmp_path):
    events = _run_lus(tmp_path, T23)

    warmup_ends = [e for e in events if e.get("type") == "warmup_end"]
    assert len(warmup_ends) == 1, (
        f"expected exactly one warmup_end, got {len(warmup_ends)}"
    )

    # t23 has warmup_ms=100.
    assert warmup_ends[0]["time_ms"] == 100, (
        f"warmup_end time_ms should be 100, got {warmup_ends[0]['time_ms']}"
    )


def test_warmup_end_ordering(tmp_path):
    events = _run_lus(tmp_path, T23)

    types = [e.get("type") for e in events]
    sim_start_idx = types.index("sim_start")
    warmup_end_idx = types.index("warmup_end")
    sim_end_idx = types.index("sim_end")

    assert sim_start_idx < warmup_end_idx < sim_end_idx, (
        f"ordering wrong: sim_start@{sim_start_idx}, "
        f"warmup_end@{warmup_end_idx}, sim_end@{sim_end_idx}"
    )


def test_no_warmup_end_when_warmup_zero(tmp_path):
    events = _run_lus(tmp_path, T01)

    warmup_ends = [e for e in events if e.get("type") == "warmup_end"]
    assert warmup_ends == [], (
        f"warmup_ms=0 should suppress the event entirely, got {warmup_ends}"
    )
```

- [ ] **Step 4.2: Run the new tests**

Run:
```bash
cd webapp && python -m pytest tests/test_warmup_end_event.py -v
```

Expected: 3 tests pass.

If a test fails:
- `test_warmup_end_fires_at_boundary` — re-check Step 3.6's manual grep; the time_ms is wrong.
- `test_warmup_end_ordering` — the emit point in `step()` is in the wrong place; re-read Step 3.3.
- `test_no_warmup_end_when_warmup_zero` — the `warmup_ms > 0` guard in Step 3.3 is missing or wrong.

- [ ] **Step 4.3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add webapp/tests/test_warmup_end_event.py
git commit -m "$(cat <<'EOF'
test(webapp): assert warmup_end event time, ordering, zero-warmup absence

Three pytest cases covering what the integration `expect` schema
can't: time_ms == warmup_ms, sim_start < warmup_end < sim_end
ordering, and the no-emit case when warmup_ms == 0.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Verify no regressions

This task runs only — no code changes. Confirms the broader suites stay green.

- [ ] **Step 5.1: Full integration suite**

Run:
```bash
bash test/run_tests.sh
```

Expected: all tests PASS, including `t23_warmup_end`. The line should read something like `N/N passed` with `N` matching the count before this work plus 1 (for t23).

- [ ] **Step 5.2: Native C++ tests**

Run:
```bash
bash test/native/build_test.sh
```

Expected: all tests pass.

- [ ] **Step 5.3: Webapp pytest suite**

Run:
```bash
cd webapp && python -m pytest tests/ -q
```

Expected: previous count + 3 (the new pytest cases). All green.

- [ ] **Step 5.4: Quick check on a scenario with non-zero warmup**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
./build/orchestrator/lus scenarios/s03_seattle_medium.json /tmp/s03_smoke.ndjson 2>&1 | tail -2
grep '"warmup_end"' /tmp/s03_smoke.ndjson
```

Expected:
- `lus: <N> events emitted, 0 assertion failure(s)` — note: s03 has no `expect` block; assertion count is always 0 here.
- Exactly one `{"type":"warmup_end","time_ms":30000}` line.

If the line is missing or the time_ms is off, something has regressed in the SimController emit path — re-run Task 3.

No commit needed for this verification task.

---

## Self-Review Notes

- **Spec coverage:** The plan implements every section of the spec — the event method (Task 2), the flag + emit point + reset (Task 3), the integration test (Task 1), the pytest with time/ordering/zero-warmup (Task 4). Out-of-scope items (visualizer rendering, Lua callback) are deferred per the spec.
- **No placeholders:** All file paths, code blocks, commands, and expected outputs are concrete.
- **Type consistency:** `EventLog::warmupEnd` is declared and called with the same signature `(unsigned long)`. The `_warmup_end_emitted` member is referenced consistently. `simulation.warmup_ms` is read the same way it's read at line 539 today (`static_cast<uint64_t>(_cfg.simulation.warmup_ms)`).
- **Frequent commits:** Three commits (impl + integration test, pytest, none for verification) — proportionate to the change size.
