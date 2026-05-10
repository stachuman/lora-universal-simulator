# Path-Loss "none" + Asymmetric-Link Orchestrator Adoption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the orchestrator runtime to honour `simulation.path_loss.model = "none"` (no log-distance baseline; only explicit `topology.links[]` populate the link matrix), and add two integration scenarios proving the asymmetric-directional + sparse-explicit-link behaviour works end-to-end.

**Architecture:** Two small C++ changes — JsonConfig accepts/validates `"none"` as a recognized model value; SimController gates `PathLossModel` construction + the per-pair baseline loop on `model != "none"`. Two new integration scenarios under `test/`. One paragraph in `docs/CONFIG_FORMAT.md`.

**Tech Stack:** C++17 (orchestrator), JSON (test scenarios), Markdown (docs). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-10-path-loss-none-asymmetric-orchestrator-design.md`

---

## File Structure

| Path | Action | Purpose |
|---|---|---|
| `core/topology/JsonConfig.cpp` | Modify | Replace the parse-time `throw` on non-`log_distance` model with acceptance of both `log_distance` and `none`. Add validator entry that rejects other strings. |
| `orchestrator/runtime/SimController.cpp` | Modify | Gate `PathLossModel` construction + the per-pair baseline `setLink` loop on `model != "none"`. |
| `test/t27_asymmetric_link.json` | Create | 2-node scenario with explicit asymmetric directional links; one direction below SF12 floor. |
| `test/t28_path_loss_none_sparse.json` | Create | 3-node line with `model: "none"` and sparse explicit links; multi-hop must work, no `drop_weak` (proves baseline didn't leak). |
| `docs/CONFIG_FORMAT.md` | Modify | One paragraph documenting `model: "none"` + `bidir: false`. |

No new files in C++ (everything fits in existing JsonConfig.cpp / SimController.cpp). No new headers.

---

## Task 1: Accept `model: "none"` in JsonConfig

**Files:**
- Modify: `core/topology/JsonConfig.cpp` (parse block around line 121-127, validate block around the existing path-loss validation)

The existing parser throws on any model string ≠ `"log_distance"`. Relax to allow `"none"` too. Add a validate-time check that rejects any other string with a clean error message (matches the pattern used for other validation errors).

- [ ] **Step 1.1: Relax the parser**

In `core/topology/JsonConfig.cpp`, find the throw inside the `path_loss` parse block (around line 121-126):

```cpp
            if (cfg.simulation.path_loss.model != "log_distance") {
                throw std::runtime_error(
                    "config error at simulation.path_loss: model must be "
                    "\"log_distance\" for v1 (got \""
                    + cfg.simulation.path_loss.model + "\")");
            }
```

Replace with:

```cpp
            // model is validated downstream in validate(); accept any
            // string at parse time so the validator's error message is
            // the canonical one.
```

(i.e., delete the throw — the field is already parsed; the new validate() check below produces the cleaner error.)

- [ ] **Step 1.2: Add the model validation**

In the same file, find the simulation-level path-loss validation block (search for `errors.push_back("simulation.path_loss.frequency_mhz must be > 0`). Insert right before it:

```cpp
    {
        const auto& m = cfg.simulation.path_loss.model;
        if (cfg.simulation.path_loss.present
            && m != "log_distance" && m != "none") {
            errors.push_back(
                "simulation.path_loss.model must be \"log_distance\" or "
                "\"none\" (got \"" + m + "\")");
        }
    }
```

The `present` guard means the validator only kicks in when the operator wrote a `path_loss` block; scenarios that omit it entirely keep working as before.

- [ ] **Step 1.3: Build + smoke-test against existing scenarios**

```bash
cd /home/staszek/lora-universal-simulator
cmake --build build -j 2>&1 | tail -3
bash test/run_tests.sh 2>&1 | tail -3
```

Expected: `[100%] Built target lus`; `33/33 passed`. No existing scenario uses an unrecognized model value, so all should pass.

Test the new error path manually:

```bash
# Sanity: should error with "must be log_distance or none"
echo '{"simulation":{"duration_ms":1000,"step_ms":1,"warmup_ms":0,"seed":1,"radio":{"sf":7,"bw":250,"cr":5},"path_loss":{"model":"garbage"}},"nodes":[{"name":"a","script":"examples/quiet.lua"}]}' > /tmp/bad_model.json
./build/orchestrator/lus /tmp/bad_model.json /tmp/bad_model.ndjson 2>&1 | head -3
rm /tmp/bad_model.json /tmp/bad_model.ndjson
```

Expected: error mentions `simulation.path_loss.model must be "log_distance" or "none"`.

- [ ] **Step 1.4: Commit**

```bash
git add core/topology/JsonConfig.cpp
git commit -m "$(cat <<'EOF'
feat(config): accept simulation.path_loss.model = "none" + validate

Today JsonConfig throws at parse time on any model value ≠
"log_distance". Replace that with acceptance of both
"log_distance" and "none", and add a validate-time check that
rejects everything else with a clean error message (matches the
pattern of other simulation.path_loss.* validators).

Runtime use of model="none" lands in the next commit (SimController
gates the PathLossModel construction).

Spec: docs/superpowers/specs/2026-05-10-path-loss-none-asymmetric-orchestrator-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Gate `PathLossModel` baseline on `model != "none"`

**Files:**
- Modify: `orchestrator/runtime/SimController.cpp` (around lines 176-240, the `if (_cfg.simulation.path_loss.present) { ... }` block + the explicit-links loop after it)

When `model == "none"`, skip `PathLossModel` construction entirely; `_path_loss` stays nullptr. The per-pair baseline `setLink` loop also doesn't run (it's inside the same `if (present)` block). Explicit `topology.links[]` entries still apply normally — that loop is independent of the path-loss block. The asymmetry-coherence resample path (`rebuildLinksFromPathLoss`) already null-guards on `_path_loss`, so no further changes needed there.

- [ ] **Step 2.1: Wrap the baseline construction**

In `orchestrator/runtime/SimController.cpp`, find the start of the path-loss block (around line 176):

```cpp
    if (_cfg.simulation.path_loss.present) {
        PathLossConfig plc;
        plc.model                   = _cfg.simulation.path_loss.model;
```

Change the guard to also require model != "none":

```cpp
    // Gate the path-loss baseline on both `present` (operator wrote a
    // path_loss block at all) and model != "none" (the operator
    // explicitly wants no log-distance baseline — only pairs in
    // topology.links[] populate the link matrix). When skipped,
    // _path_loss stays nullptr; downstream code that consults it is
    // already null-guarded.
    if (_cfg.simulation.path_loss.present
        && _cfg.simulation.path_loss.model != "none") {
        PathLossConfig plc;
        plc.model                   = _cfg.simulation.path_loss.model;
```

- [ ] **Step 2.2: Build + run integration suite**

```bash
cmake --build build -j 2>&1 | tail -3
bash test/run_tests.sh 2>&1 | tail -3
```

Expected: `[100%] Built target lus`; `33/33 passed`. No scenario today uses `model: "none"` so behaviour is byte-identical for all existing tests.

- [ ] **Step 2.3: Commit**

```bash
git add orchestrator/runtime/SimController.cpp
git commit -m "$(cat <<'EOF'
feat(runtime): honour simulation.path_loss.model = "none"

When the operator sets model="none", skip PathLossModel construction
entirely so no log-distance baseline runs and no per-pair setLink
fires from the path-loss path. Only explicit topology.links[]
entries populate the link matrix; pairs not listed there return
getLink → false and the runtime treats them as "no link" via the
existing if (!_links->getLink(...)) continue; guard.

The asymmetry-coherence resample path (rebuildLinksFromPathLoss)
already null-guards on _path_loss; no further changes needed.

Existing 33 integration tests pass byte-identically (no scenario
uses model="none" yet — the next two commits add t27 and t28).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Integration test t27 — asymmetric directional link

**Files:**
- Create: `test/t27_asymmetric_link.json`

Two-node scenario with two explicit `bidir: false` entries forming an asymmetric pair: alice→bob at +10 dB SNR (decodes fine on any SF); bob→alice at -25 dB SNR (below the SF12 floor of -20). Both nodes use `examples/flooder.lua` as originators. alice sends "from-alice" at t=2000, bob sends "from-bob" at t=4000.

Expected behaviour:
- alice's TX → bob receives → bob emits `recv` + forwards. Forward bob→alice is below SF12 floor → `drop_weak` event.
- bob's TX → alice doesn't receive (B→A below floor) → `drop_weak`.
- bob's `recv` for "from-alice" emit fires.
- alice's `recv` for "from-bob" never fires.

The expect runner can assert presence of `recv` at bob (via `script_emit_contains`) and `drop_weak` events somewhere (via `event_count_min`). It can't assert absence of a specific script_emit at alice — but the positive `script_emit_contains` and the `drop_weak` minimum together make the asymmetry behaviour observable.

- [ ] **Step 3.1: Create the scenario**

Create `test/t27_asymmetric_link.json` with this content:

```json
{
  "_name": "t27_asymmetric_link",
  "_desc": "Two-node asymmetric link. alice→bob is +10 dB SNR (good); bob→alice is -25 dB (below SF12 floor). Both flood. bob receives alice's broadcast; alice never receives bob's. Asserts the explicit-asymmetric path lands directional values in the link matrix and the runtime drops below-floor frames per direction.",
  "simulation": {
    "duration_ms": 10000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua",
      "config": { "role": "originator" } },
    { "name": "bob",   "script": "examples/flooder.lua",
      "config": { "role": "originator" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr":  10.0, "rssi":  -78.0, "bidir": false },
      { "from": "bob",   "to": "alice", "snr": -25.0, "rssi": -120.0, "bidir": false }
    ]
  },
  "commands": [
    { "at_ms": 2000, "node": "alice", "command": "send from-alice" },
    { "at_ms": 4000, "node": "bob",   "command": "send from-bob"   }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "recv", "value": "from-alice" },
    { "type": "event_count_min",      "event_type": "drop_weak", "min": 1 }
  ]
}
```

- [ ] **Step 3.2: Run + verify**

```bash
bash test/run_tests.sh test/t27_asymmetric_link.json 2>&1 | tail -3
```

Expected: `t27_asymmetric_link ... PASS` and `1/1 passed`.

- [ ] **Step 3.3: Manual sanity check on the events**

```bash
./build/orchestrator/lus test/t27_asymmetric_link.json /tmp/t27.ndjson 2>&1 | tail -1
echo "--- recv at bob ---"
grep '"emit_type":"recv"' /tmp/t27.ndjson | grep '"node":1'
echo "--- recv at alice (must be empty) ---"
grep '"emit_type":"recv"' /tmp/t27.ndjson | grep '"node":0'
echo "--- drop_weak events ---"
grep -c '"type":"drop_weak"' /tmp/t27.ndjson
```

Expected:
- One line under "recv at bob" containing "from-alice".
- The "recv at alice (must be empty)" section produces zero lines.
- drop_weak count ≥ 1.

- [ ] **Step 3.4: Commit**

```bash
git add test/t27_asymmetric_link.json
git commit -m "$(cat <<'EOF'
test(t27): asymmetric directional link end-to-end

Two-node scenario with two explicit bidir:false topology.links[]
entries — alice→bob at +10 dB SNR (decodes fine), bob→alice at -25 dB
(below SF12 floor of -20). Both nodes flood; alice's broadcast
reaches bob, bob's broadcast never reaches alice (drop_weak).

Asserts:
- bob emits "recv" containing "from-alice" (A→B link works)
- ≥1 drop_weak event (proves below-floor drops are firing on B→A)

Exercises the orchestrator's per-directed-link path that's been
present for some time but never had end-to-end coverage. Now that
the SRTM+ITM topology generator produces directional links by
default, this test guards against future regressions in
MatrixLinkModel::setLink directionality, deliverReceptionsForStep
threshold gating per direction, and the LinkFadingState per-direction
keying.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Integration test t28 — `path_loss.model = "none"` + sparse explicit links

**Files:**
- Create: `test/t28_path_loss_none_sparse.json`

Three-node line `alice` ↔ `bob` ↔ `carol` with `simulation.path_loss.model = "none"`. Explicit `topology.links[]` lists ONLY `alice↔bob` and `bob↔carol` (both `bidir: true`); the `alice↔carol` direct pair is unlisted. alice sends "ping" via flooder; carol must receive it via the multi-hop path through bob.

The "model=none did its job" signal is the absence of any `drop_weak` events — under `log_distance` defaults, alice's broadcast would reach carol directly at low SNR (below SF7 floor at this distance) and produce a `drop_weak` event for the alice→carol direct path. Under `model=none`, no link exists for alice↔carol, so no rx attempt fires, so no `drop_weak`. `event_count(drop_weak, count=0)` differentiates the two.

- [ ] **Step 4.1: Create the scenario**

Create `test/t28_path_loss_none_sparse.json` with this content:

```json
{
  "_name": "t28_path_loss_none_sparse",
  "_desc": "Three-node line alice ↔ bob ↔ carol with simulation.path_loss.model=\"none\". Explicit topology.links[] lists ONLY alice↔bob and bob↔carol. alice→carol direct pair is unlisted ⇒ no link ⇒ no rx, no drop_weak. Multi-hop through bob delivers; the absence of drop_weak proves the baseline didn't silently fall back.",
  "simulation": {
    "duration_ms": 10000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": { "model": "none" }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua",
      "config": { "role": "originator" } },
    { "name": "bob",   "script": "examples/flooder.lua",
      "config": { "role": "forwarder"  } },
    { "name": "carol", "script": "examples/flooder.lua",
      "config": { "role": "forwarder"  } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 8.0, "rssi": -80.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 2000, "node": "alice", "command": "send ping-via-multihop" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "carol", "emit_type": "recv", "value": "ping-via-multihop" },
    { "type": "event_count",          "event_type": "drop_weak", "count": 0 }
  ]
}
```

- [ ] **Step 4.2: Run + verify**

```bash
bash test/run_tests.sh test/t28_path_loss_none_sparse.json 2>&1 | tail -3
```

Expected: `t28_path_loss_none_sparse ... PASS` and `1/1 passed`.

- [ ] **Step 4.3: Sanity check the multi-hop path**

```bash
./build/orchestrator/lus test/t28_path_loss_none_sparse.json /tmp/t28.ndjson 2>&1 | tail -1
echo "--- carol's recv ---"
grep '"emit_type":"recv"' /tmp/t28.ndjson | grep '"node":2'
echo "--- drop_weak count (must be 0) ---"
grep -c '"type":"drop_weak"' /tmp/t28.ndjson
echo "--- rx events between alice (id 0) and carol (id 2): expect zero ---"
grep '"type":"rx"' /tmp/t28.ndjson | grep -E '"from":"alice".*"to":"carol"|"from":"carol".*"to":"alice"' | wc -l
```

Expected:
- `carol's recv` shows one line with "ping-via-multihop".
- `drop_weak count` is 0.
- `rx events between alice and carol` is 0 (proves the unlisted pair is silent).

- [ ] **Step 4.4: Commit**

```bash
git add test/t28_path_loss_none_sparse.json
git commit -m "$(cat <<'EOF'
test(t28): path_loss.model="none" + sparse explicit links

Three-node line alice ↔ bob ↔ carol with model="none". Explicit
topology.links[] lists alice↔bob and bob↔carol only. alice sends
"ping-via-multihop"; the message must hop through bob to reach
carol. Asserts:

- carol receives "ping-via-multihop" via flooder forwarding
  (proves the explicit links + model="none" combo functions
  correctly for the listed pairs)
- event_count for drop_weak == 0 (proves no log-distance baseline
  silently filled in alice↔carol direct — under the default
  baseline this would fire because the direct distance puts it
  below the SF7 floor)

Together the assertions prove that model="none" cleanly opts out
of the per-pair baseline without breaking the explicit-link path.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Documentation update — `CONFIG_FORMAT.md`

**Files:**
- Modify: `docs/CONFIG_FORMAT.md` (path_loss.model row + a paragraph on bidir)

- [ ] **Step 5.1: Find the relevant section**

```bash
grep -n "path_loss\|bidir" docs/CONFIG_FORMAT.md | head -10
```

The doc has a table-style listing of `simulation.path_loss.*` fields and a separate `topology.links[]` section. Find the row documenting `path_loss.model` and the link-shape description.

- [ ] **Step 5.2: Update the `path_loss.model` row**

In `docs/CONFIG_FORMAT.md`, locate the `path_loss.model` description (a row that currently mentions `"log_distance"` only). Update it so the value column reads:

```
| `model` | string | `"log_distance"` | One of `"log_distance"` (compute baseline SNR/RSSI per pair from haversine distance) or `"none"` (skip baseline; only explicit `topology.links[]` populate the link matrix; pairs not listed return `getLink → false` and the runtime treats them as out of range). Use `"none"` when the operator has authored a complete topology (e.g., from the SRTM+ITM generator) and doesn't want log-distance fallback for unlisted pairs. |
```

(Adapt to the exact column widths of the existing table; the prose content is what matters.)

- [ ] **Step 5.3: Update the topology.links section**

Find the `topology.links[]` section (search for `"bidir"` in the doc). Update the `bidir` field's description to:

```
`bidir` (bool, default `true`) — when `true`, the entry's
snr/rssi/snr_std_dev applies to BOTH directions of the pair (`from→to`
AND `to→from`). When `false`, ONLY the `from→to` direction is set;
the reverse direction is unaffected. Asymmetric topologies (e.g., the
SRTM+ITM generator's default output) emit two `bidir: false` entries
per pair, one for each direction, with potentially different SNR/RSSI.
```

- [ ] **Step 5.4: Commit**

```bash
git add docs/CONFIG_FORMAT.md
git commit -m "$(cat <<'EOF'
docs(CONFIG_FORMAT): path_loss.model="none" + bidir:false semantics

Document the new "none" value of simulation.path_loss.model
(skip log-distance baseline; explicit links are the only source
of link configuration) and clarify topology.links[].bidir
semantics (two bidir:false entries per pair = asymmetric directional
output, used by the SRTM+ITM generator).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Verify no regressions

This task runs only — no code changes.

- [ ] **Step 6.1: Full integration suite**

```bash
bash test/run_tests.sh 2>&1 | tail -5
```

Expected: `35/35 passed` (was 33 + t27 + t28). All previous tests still PASS.

- [ ] **Step 6.2: Native C++ tests**

```bash
bash test/native/build_test.sh 2>&1 | tail -3
```

Expected: all pass.

- [ ] **Step 6.3: Webapp pytest suite**

```bash
cd webapp && python -m pytest tests/ -q 2>&1 | tail -3
```

Expected: 75 passed (no webapp tests added by this plan).

- [ ] **Step 6.4: Smoke a model="none" scenario via the SRTM-derived round-trip**

```bash
cd "$(git rev-parse --show-toplevel)"
python3 -c "
import json
sc = json.load(open('test/t28_path_loss_none_sparse.json'))
# Re-shape to match what the webapp's refine-with-srtm endpoint
# would emit: directional pairs with bidir:false. Just simulating
# the wire format here, no webapp call.
sc['topology']['links'] = [
    {'from': 'alice', 'to': 'bob',   'snr': 8.0, 'rssi': -80.0, 'snr_std_dev': 1.5, 'bidir': False},
    {'from': 'bob',   'to': 'alice', 'snr': 7.7, 'rssi': -80.3, 'snr_std_dev': 1.5, 'bidir': False},
    {'from': 'bob',   'to': 'carol', 'snr': 8.0, 'rssi': -80.0, 'snr_std_dev': 1.5, 'bidir': False},
    {'from': 'carol', 'to': 'bob',   'snr': 8.2, 'rssi': -79.8, 'snr_std_dev': 1.5, 'bidir': False},
]
sc['_name'] = 'smoke_directional'
json.dump(sc, open('/tmp/smoke_directional.json', 'w'), indent=2)
"
./build/orchestrator/lus /tmp/smoke_directional.json /tmp/smoke_directional.ndjson 2>&1 | tail -1
grep '"emit_type":"recv"' /tmp/smoke_directional.ndjson | grep '"node":2' | head -1
```

Expected: ndjson finishes with `events emitted, ... assertion failure(s)` (the original test's assertions still pass even on the directional-pair shape) and carol's `recv` line for "ping-via-multihop" appears.

No commit needed for this task.

---

## Self-Review Notes

- **Spec coverage:** Schema change (Task 1), runtime gating (Task 2), t27 asymmetric scenario (Task 3), t28 model=none scenario (Task 4), CONFIG_FORMAT doc (Task 5), regression verify (Task 6). All sections of the spec map to a task.
- **No placeholders:** Every step has concrete code/commands/expected output. The spec mentioned a possible Python pytest for absence-of-events; that didn't make this plan because (a) the existing `event_count(drop_weak, count=0)` assertion in t28 covers the negative case adequately and (b) the spec listed it as "if needed; can come later."
- **Type consistency:** Task 1 introduces the `"none"` string sentinel; Task 2 reads it via `_cfg.simulation.path_loss.model != "none"`; Tasks 3 and 4 reference the same string in their JSON. No drift.
- **Frequent commits:** 5 commits across 6 tasks (Task 6 is verification-only). Each commit is independently buildable + green; running tests at each stage detects breakage early.
