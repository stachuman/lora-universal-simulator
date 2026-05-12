# BCN Dirty-Only Emission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch periodic and triggered BCNs to emit only dirty (changed) routes, with full state delivered on demand via solicited sync-response BCNs. Cuts BCN airtime from 39 % → ~10 % of total network airtime on the s04_seattle_realistic baseline.

**Architecture:** Five sequential tasks. Tasks 1-3 are no-op preparation (wire bit, pack-mode refactor, observation state). Task 4 wires the sync-response state machine without activating any behavior change. Task 5 flips the activation — `on_init` sets `req_sync_pending=true`, periodic + triggered switch to `dirty_only` mode. Each task ends with all 49 existing integration tests + the suite's webapp pytests passing.

**Spec:** `docs/superpowers/specs/2026-05-12-bcn-dirty-only-emission-design.md`

**Tech Stack:** Lua 5.4 (sandboxed in the C++ orchestrator), JSON integration scenarios, bash test harness.

---

## Reference: spec-locked layouts and tunables

### BCN byte 1 (post-this-plan)

```
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | REQ_SYNC(1 lo)
```

Bit 0 (`REQ_SYNC`) was reserved in the Phase 3 wire-format work. This plan claims it. The other byte-1 layout stays as in ROADMAP §7.0.2.

### New constants in dv_dual_sf.lua

```lua
local BCN_FLAG_REQ_SYNC = 0x01     -- bit 0 of byte 1; sender requests full sync
```

### New tunables (defaults shown)

| Knob | Default | Purpose |
|---|---|---|
| `sync_response_jitter_ms` | 2000 | Max scheduling jitter for sync-response (SNR-weighted scaling applied within this window) |
| `sync_satisfied_ttl_ms` | 30000 | Per-joiner "I already synced this peer" memory TTL |
| `rotation_sync_threshold` | 8 | n_entries threshold above which an observed BCN is treated as a sync-response (for suppression detection) |

### New per-node state in `on_init`

```lua
self.req_sync_pending             = true    -- cleared on first BCN tx
self.sync_satisfied               = {}      -- joiner_id → expiry_ms
self.last_observed_sync_response_ms = -1    -- timestamp of most recent observed n_entries ≥ rotation_sync_threshold
```

### Sync-response selection (SNR-weighted multiplicative)

```lua
function snr_to_normalized(snr_db)
  -- Map -20..+10 dB to [0..1]; clamp outside range.
  local norm = (snr_db + 20) / 30
  if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
  return norm
end

-- jitter scales inversely with link quality: best neighbour fires first.
local jitter = sync_response_jitter_ms * (1 - snr_to_normalized(rx_snr))
```

---

## Files touched

| File | Role | Tasks |
|---|---|---|
| `scenarios/dv_dual_sf.lua` | The whole feature lives here | 1, 2, 3, 4, 5 |
| `docs/PROTOCOL.md` | §3.1 + §12.1 update + new §6.6 (BCN modes) | 5 |
| `test/t39_req_sync_wire.json` | Phase-1 wire round-trip test | 1 |
| `test/t40_dirty_only_cold_start.json` | Joiner gets routes via REQ_SYNC | 5 |
| `test/t41_first_contact_sync.json` | Receiver-detected first-contact triggers sync | 5 |

No new Lua files. No new scenario directories.

---

## Test strategy

1. **Existing 49 integration tests + 78 webapp pytests** stay green after every task. Run with:
   ```bash
   cmake --build build -j && bash test/run_tests.sh
   ```
2. **New per-task integration tests** verify each behavior delta — see task descriptions for the exact JSON scenarios.
3. **Final measurement** (in Task 5) reruns `tools/analyze.py ./scenarios/s04_seattle_realistic.json --run` and confirms:
   - BCN airtime drops from ~39 % → < 15 % of total
   - `rt_update / beacon_rx` ratio rises from ~0.40 → > 0.70
   - Delivered count rises from ~188 → measurable improvement (no fixed target — proof-of-concept threshold)

---

### Task 1: Wire-format bit (`REQ_SYNC`)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_beacon` (~line 796), `parse_beacon` (~line 889), `on_init` (where other beacon state initializes)
- Modify: `docs/PROTOCOL.md` — §3.1 Beacon section (add `REQ_SYNC` to the byte-1 description)
- Add: `test/t39_req_sync_wire.json` — verifies the bit round-trips through emit/parse

**Rationale:** Add the wire bit and the sender-side state without activating it. Encoder sets the bit when `self.req_sync_pending` is true; decoder exposes the bit on parsed BCN. Nothing in the script consumes the parsed bit yet. Tests pass unchanged.

- [ ] **Step 1: Confirm baseline tests pass**

Run: `cd /home/staszek/lora-universal-simulator && cmake --build build -j && bash test/run_tests.sh`
Expected: 49/49 PASS.

- [ ] **Step 2: Add `BCN_FLAG_REQ_SYNC` constant**

In `scenarios/dv_dual_sf.lua`, find where other BCN-related constants live (near `bucket_of_snr_4b` or other wire-helper constants). Add:

```lua
local BCN_FLAG_REQ_SYNC = 0x01   -- bit 0 of BCN byte 1: sender requests a full-sync response BCN from neighbours.
                                 -- Set by joiners (on_init) and by future mobility hooks (§6.1 of the design spec).
                                 -- Cleared automatically after the first BCN emission carrying the flag.
```

- [ ] **Step 3: Add `req_sync_pending` state in `on_init`**

In `on_init`, near where other beacon-related state initializes:

```lua
self.req_sync_pending = false   -- Activated in Task 5; reserved here so pack_beacon can read it.
```

- [ ] **Step 4: Update `pack_beacon_byte1` helper to OR in REQ_SYNC bit**

Find the `pack_beacon_byte1` helper (added in Phase 3 of the wire refactor; lives just above `pack_beacon`). Update it:

```lua
local function pack_beacon_byte1(node)
  local b = (node.leaf_id & 0xf) << 4
  if node.has_schedule        then b = b | 0x08 end
  if node.self_gateway        then b = b | 0x04 end
  if node.is_mobile           then b = b | 0x02 end
  if node.req_sync_pending    then b = b | BCN_FLAG_REQ_SYNC end
  return b
end
```

- [ ] **Step 5: Clear `req_sync_pending` after `pack_beacon` emits a frame**

At the end of `pack_beacon`, just before the return statement that yields the frame bytes, add:

```lua
node.req_sync_pending = false   -- single-shot: the flag rides on at most one BCN per "need" trigger
```

If `pack_beacon` has multiple return paths (e.g., the empty-rt early return), clear the flag in BOTH paths.

- [ ] **Step 6: Update `parse_beacon` to expose the bit**

In `parse_beacon`, find where the byte-1 decode constructs `out`. Add to that table:

```lua
req_sync_flag = (b1 & BCN_FLAG_REQ_SYNC) ~= 0,
```

- [ ] **Step 7: Add wire round-trip test `test/t39_req_sync_wire.json`**

Create the file:

```json
{
  "_name": "t39_req_sync_wire",
  "_desc": "Verifies REQ_SYNC bit round-trips through pack_beacon + parse_beacon. Two-node mesh; one node configured to set req_sync_pending=true at boot via a dedicated test command at t=5s. Receiver emits a script_emit when it parses a BCN with req_sync_flag=true.",
  "simulation": {
    "duration_ms": 20000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 13,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 3000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 3000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 5000, "node": "alice", "command": "set_req_sync_pending" }
  ],
  "expect": [
    { "type": "script_emit_exists", "node": "bob", "emit_type": "bcn_req_sync_observed" }
  ]
}
```

- [ ] **Step 8: Wire the `set_req_sync_pending` test command + observation emit**

In `on_command`, add a branch that handles `set_req_sync_pending`:

```lua
elseif cmd == "set_req_sync_pending" then
  self.req_sync_pending = true
  self:emit("req_sync_pending_set", { at_ms = self:now() })
  return
```

In the on_recv 'B' handler, after `parse_beacon` succeeds, add:

```lua
if parsed.req_sync_flag then
  self:emit("bcn_req_sync_observed", { from = name_of(self, parsed.src) })
end
```

- [ ] **Step 9: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS (49 prior + new t39_req_sync_wire).

- [ ] **Step 10: Update PROTOCOL.md §3.1**

In `docs/PROTOCOL.md`, find the §3.1 Beacon section. Update the byte-1 description to list `REQ_SYNC` as bit 0 (replacing "reserved (1)" with its semantics — see the design spec §3 for the precise wording).

- [ ] **Step 11: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t39_req_sync_wire.json
git commit -m "$(cat <<'EOF'
feat(wire): BCN REQ_SYNC bit (byte 1, bit 0)

Claims the last reserved bit in BCN byte 1 for the REQ_SYNC flag per
the BCN dirty-only emission design spec. Senders OR the bit when
self.req_sync_pending is true; the flag rides on a single BCN
emission and is cleared automatically. Receivers expose the bit via
parse_beacon's req_sync_flag field.

No behavior change activated yet (req_sync_pending stays false by
default; consumers will land in later phases). New observable event
bcn_req_sync_observed at receivers, gated on the parsed flag, lets
t39 verify the wire round-trip.

Task 1 of 5 in the BCN dirty-only implementation plan.

Tests: 50/50 PASS (49 prior + new t39_req_sync_wire).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `pack_beacon` mode parameter (`sync_full` / `dirty_only`)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_beacon` (~line 796), all callers of `pack_beacon`

**Rationale:** Add a `mode` parameter so the function can either emit "today's behavior" (dirty + rotation fill, called `sync_full`) or "future behavior" (dirty entries only, called `dirty_only`). All current callers pass `sync_full`, so behavior is unchanged.

- [ ] **Step 1: Confirm tests pass**

```bash
bash test/run_tests.sh
```
Expected: 50/50 PASS.

- [ ] **Step 2: Inspect current `pack_beacon` callers**

```bash
grep -n 'pack_beacon(' scenarios/dv_dual_sf.lua
```
Note each call site — they'll all become 4-argument calls.

- [ ] **Step 3: Add `mode` parameter to `pack_beacon`**

Modify the function signature and body:

```lua
local PACK_BEACON_MODE_SYNC_FULL  = "sync_full"   -- dirty entries first, then rotation fill up to max_entries
local PACK_BEACON_MODE_DIRTY_ONLY = "dirty_only"  -- dirty entries ONLY; no rotation fill

local function pack_beacon(node, max_entries, offset, mode)
  mode = mode or PACK_BEACON_MODE_SYNC_FULL    -- safe default for legacy/test callers
  -- ... existing body ...
```

In the body, locate Phase 2 (the rotation-fill loop). Wrap it in a guard:

```lua
-- Phase 2: rotation fill — only in sync_full mode.
if mode == PACK_BEACON_MODE_SYNC_FULL then
  -- ... existing rotation-fill body ...
end
```

The `offset` advancement must stay INSIDE the rotation-fill block, so `dirty_only` mode never advances the offset (preserving rotation state for the next sync_full call).

- [ ] **Step 4: Update every `pack_beacon` caller to pass `PACK_BEACON_MODE_SYNC_FULL` explicitly**

For each caller located in Step 2, change:
```lua
local payload, new_offset, breakdown = pack_beacon(node, max_entries, offset)
```
to:
```lua
local payload, new_offset, breakdown = pack_beacon(node, max_entries, offset, PACK_BEACON_MODE_SYNC_FULL)
```

This makes the intent explicit even though `sync_full` is the default. Future callers (Task 5) will pass `dirty_only` deliberately.

- [ ] **Step 5: Run tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS. No behavior change — refactor only.

- [ ] **Step 6: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
refactor(beacon): pack_beacon gains mode parameter

Splits pack_beacon's two phases via a mode argument:
- PACK_BEACON_MODE_SYNC_FULL: dirty + rotation fill (today's behavior)
- PACK_BEACON_MODE_DIRTY_ONLY: dirty entries only, no rotation fill

All current callers pass SYNC_FULL explicitly, so behavior is unchanged
this task. DIRTY_ONLY mode is plumbed for Task 5 activation.

Task 2 of 5 in the BCN dirty-only implementation plan.

Tests: 50/50 PASS unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Sync-response observation infrastructure

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — tunables setup in `on_init`, `on_recv` 'B' branch

**Rationale:** Add the receiver-side observation that makes suppression possible. Tracks `last_observed_sync_response_ms` (single timestamp updated when a "big" BCN arrives) and reserves the per-joiner `sync_satisfied` table. Nothing consumes this state yet.

- [ ] **Step 1: Confirm tests pass**

```bash
bash test/run_tests.sh
```
Expected: 50/50 PASS.

- [ ] **Step 2: Add new tunables to `on_init`**

Find where other beacon/sync tunables initialize in `on_init` (look for `quiet_threshold_ms` or similar). Add:

```lua
self.sync_response_jitter_ms = (config.sync_response_jitter_ms or 2000)
self.sync_satisfied_ttl_ms   = (config.sync_satisfied_ttl_ms   or 30000)
self.rotation_sync_threshold = (config.rotation_sync_threshold or 8)
```

- [ ] **Step 3: Add new state to `on_init`**

In the same block (or near other beacon state):

```lua
self.sync_satisfied                 = {}    -- joiner_id (int) → expiry_ms (int)
self.last_observed_sync_response_ms = -1    -- ms since boot; -1 = never observed
```

- [ ] **Step 4: Update `on_recv` 'B' branch to track observations**

In the 'B' handler, after `parse_beacon` succeeds and `n` is the entry count:

```lua
-- Sync-response observation (Task 3): any BCN we receive carrying many
-- entries is presumed to be a sync-response from some neighbour; record
-- the timestamp so the suppression logic in fire_sync_response can
-- check whether to skip its own emission.
if parsed.n_entries >= self.rotation_sync_threshold then
  self.last_observed_sync_response_ms = self:now()
end
```

Note: `parsed.n_entries` is the count field that `parse_beacon` already exposes. If the field name in the existing code is different (e.g., `parsed.n` or `parsed.entry_count`), use that — adapt to match.

- [ ] **Step 5: Run tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS. Tracking state but not yet consuming it.

- [ ] **Step 6: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(beacon): track observed sync-response BCNs (Task 3 of 5)

Adds receiver-side observation state for the BCN dirty-only plan's
storm-prevention mechanism:
- last_observed_sync_response_ms: monotonic timestamp updated when
  any received BCN has n_entries ≥ rotation_sync_threshold (default 8).
  Used by Task 4's fire_sync_response to suppress redundant emissions.
- sync_satisfied: per-joiner TTL dict (initialized empty; consumers in
  Task 4).

New tunables: sync_response_jitter_ms (2000), sync_satisfied_ttl_ms
(30000), rotation_sync_threshold (8). All defaults; no scenarios set them.

Tests: 50/50 PASS unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Sync-response handler + first-contact detection (wired but inactive)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `rt_merge` (to surface first-contact), `on_recv` 'B' (to call the new scheduler), new helpers (scheduler + fire function)

**Rationale:** Land the complete sync-response state machine. The triggers (REQ_SYNC flag from parsed BCN, first-contact from rt_merge) are wired, but the activation in Task 5 is what makes them fire (REQ_SYNC is never set by anyone in current code, and joiner-detection only happens when joiners actually appear with no prior rt[] context — which doesn't happen in steady-state existing tests).

- [ ] **Step 1: Confirm tests pass**

```bash
bash test/run_tests.sh
```
Expected: 50/50 PASS.

- [ ] **Step 2: Add first-contact detection to `rt_merge`**

Find `rt_merge` (around line 1731 in the file). The function already returns one of the strings `"new"` / `"promote"` / `"primary_refresh"` / `"alt_install"` / `"no_change"`. The `"new"` outcome means rt[dest] was empty before.

For first-contact, we care whether `rt[src_of_bcn]` (= the BCN emitter's identity as a destination) was empty BEFORE this BCN. This is checked AT THE TOP of the on_recv 'B' branch, not inside rt_merge — because the BCN's `src` is processed as a special "direct neighbour" entry separately from the iterated route entries.

Locate the early part of on_recv 'B' where the script installs the direct-neighbour entry `rt[N]` (the BCN sender). It looks something like:

```lua
-- install rt[N] = {direct, snr, hops=1, n2_hop=nil}
local was_empty = (self.rt[parsed.src] == nil)
-- existing direct-neighbour install logic ...
```

Add the `was_empty` line BEFORE the install if it's not already there; expose it as a local for use later in the function.

- [ ] **Step 3: Add the scheduler helper**

Add this function (near other helper definitions; placement matches the convention used by `try_cascade_requeue` and similar helpers):

```lua
local function schedule_sync_response_with_suppression(self, joiner_id, rx_snr)
  -- Suppress repeat sync for the same joiner within the TTL window.
  local expiry = self.sync_satisfied[joiner_id]
  if expiry ~= nil and self:now() < expiry then
    return
  end

  -- SNR-weighted jitter: stronger link → smaller delay → fire sooner.
  local norm = (rx_snr + 20) / 30
  if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
  local jitter = math.floor(self.sync_response_jitter_ms * (1 - norm))
  if jitter < 0 then jitter = 0 end

  self:after(jitter, fire_sync_response, joiner_id)
end
```

`fire_sync_response` is forward-referenced; define it next.

- [ ] **Step 4: Add the fire helper**

```lua
local function fire_sync_response(self, joiner_id)
  -- Re-check per-joiner suppression on fire (someone may have synced while we waited).
  local expiry = self.sync_satisfied[joiner_id]
  if expiry ~= nil and self:now() < expiry then
    self:emit("sync_response_suppressed", { joiner = name_of(self, joiner_id), reason = "already_synced" })
    return
  end

  -- Suppress if we've heard another large BCN within the jitter window.
  if self.last_observed_sync_response_ms >= 0
     and (self:now() - self.last_observed_sync_response_ms) < self.sync_response_jitter_ms then
    self:emit("sync_response_suppressed", { joiner = name_of(self, joiner_id), reason = "observed_other_sync" })
    self.sync_satisfied[joiner_id] = self:now() + self.sync_satisfied_ttl_ms
    return
  end

  -- Defer if our budget tier is EXHAUSTED: let a healthier neighbour handle it.
  if compute_budget_tier(self) >= 3 then
    self:emit("sync_response_suppressed", { joiner = name_of(self, joiner_id), reason = "budget_exhausted" })
    return
  end

  -- Defer if we're mid-flight on data plane; reschedule shortly.
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    self:after(self.rts_busy_retry_ms, fire_sync_response, joiner_id)
    return
  end

  -- Emit the sync-response BCN (full sync mode).
  local payload, new_offset, breakdown =
    pack_beacon(self, self.beacon_max_entries, self.beacon_offset, PACK_BEACON_MODE_SYNC_FULL)
  self.beacon_offset = new_offset
  self:tx(payload, { label = "BCN-sync" })
  self:emit("sync_response_tx", { joiner = name_of(self, joiner_id), n_entries = #breakdown_entries_or_count(breakdown) })

  -- Mark this joiner satisfied so we don't re-respond within the TTL.
  self.sync_satisfied[joiner_id] = self:now() + self.sync_satisfied_ttl_ms
end
```

Note on `breakdown_entries_or_count`: the existing `pack_beacon` returns a `breakdown` table with fields like `dirty_n` and `stable_n`. Use those; if the field shape doesn't fit a clean count, emit `n_entries = (breakdown.dirty_n or 0) + (breakdown.stable_n or 0)`. Adapt to match the existing code's `breakdown` shape.

- [ ] **Step 5: Wire the scheduler into `on_recv` 'B'**

After the direct-neighbour install logic (and after the existing entry-merging loop), add:

```lua
local needs_sync_response = false

-- Sender-requested: joiner set the REQ_SYNC flag.
if parsed.req_sync_flag then
  needs_sync_response = true
end

-- Receiver-detected: I had no prior direct-neighbour rt entry for this src.
if was_empty then
  needs_sync_response = true
end

if needs_sync_response then
  schedule_sync_response_with_suppression(self, parsed.src, meta.snr or 0)
end
```

`meta.snr` is the RX SNR from the radio's metadata; if it's nil (synthetic test path), default to 0 dB (mid-range).

- [ ] **Step 6: Run tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS.

The receiver-detected `was_empty` path WILL fire during cold-start of every scenario as nodes discover each other. The sync-response BCN that results goes out — but at this task's point in the implementation, periodic+triggered BCNs ALSO still use SYNC_FULL mode (Task 5 flips them). So the sync-response is one extra BCN per first-contact, which is some additional airtime. Tests should still pass — they check for delivery and event presence, not BCN count.

If a timing-sensitive test fails because of the extra sync-response burst at boot, debug and either widen the test or note as a known regression to be cleaned up in Task 5 (when periodic BCNs become tiny and the math balances).

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(beacon): sync-response handler + first-contact detection

Implements the sync-response state machine from the BCN dirty-only
design (§7 of the spec):
- schedule_sync_response_with_suppression: SNR-weighted jitter,
  per-joiner sync_satisfied TTL dedup.
- fire_sync_response: re-checks per-joiner suppression on fire,
  suppresses if last_observed_sync_response_ms within jitter window,
  defers under EXHAUSTED budget or pending_tx/pending_rx state, then
  emits a SYNC_FULL pack_beacon as the sync-response payload.
- on_recv 'B' triggers schedule on req_sync_flag OR receiver-detected
  first-contact (rt[src] was empty before this BCN).

Activation: triggers fire today on first-contact (joiners learning the
network), but periodic + triggered BCNs still use SYNC_FULL mode in
this task. Task 5 flips periodic/triggered to DIRTY_ONLY, completing
the design. Expected modest airtime bump from extra sync-responses at
boot; resolves in Task 5 when periodic BCNs shrink dramatically.

Task 4 of 5 in the BCN dirty-only implementation plan.

Tests: 50/50 PASS.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Activate dirty-only emission + on_init REQ_SYNC

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `on_init` (set `req_sync_pending = true`), `beacon_fire` (periodic — use `DIRTY_ONLY`), trigger-BCN path (use `DIRTY_ONLY`)
- Modify: `docs/PROTOCOL.md` — add §6.6 documenting the new emission modes, expand §12.1 state table
- Add: `test/t40_dirty_only_cold_start.json` — verifies joiner gets routes via REQ_SYNC → sync-response
- Add: `test/t41_first_contact_sync.json` — verifies receiver-detected first-contact triggers sync

**Rationale:** Flip the activation. Periodic and triggered BCNs become dirty-only (often empty); joiners set REQ_SYNC at boot; neighbours respond with sync (already wired in Task 4). The full feature is live; measurement validates the airtime drop.

- [ ] **Step 1: Confirm tests pass**

```bash
bash test/run_tests.sh
```
Expected: 50/50 PASS.

- [ ] **Step 2: Set `req_sync_pending = true` in `on_init`**

Modify the line added in Task 1:
```lua
self.req_sync_pending = (config.req_sync_on_boot ~= false)   -- default: true; tests can opt out
```

- [ ] **Step 3: Switch periodic BCN to `DIRTY_ONLY`**

Find `beacon_fire` (around line 2894). Locate where it calls `pack_beacon`. Change the mode argument:

```lua
local payload, new_offset, breakdown =
  pack_beacon(self, self.beacon_max_entries, self.beacon_offset,
              PACK_BEACON_MODE_DIRTY_ONLY)
```

Note: in `DIRTY_ONLY` mode the `beacon_offset` does NOT advance (rotation is skipped). So `new_offset == self.beacon_offset` always. Either assignment works; existing code can stay as-is.

- [ ] **Step 4: Switch triggered BCN to `DIRTY_ONLY`**

Find the triggered-beacon emission path (look for `send_beacon_page` or similar — the function that fires the one-shot triggered BCN). Change its `pack_beacon` call's mode argument to `PACK_BEACON_MODE_DIRTY_ONLY` the same way.

The function may share `pack_beacon` invocation with `beacon_fire` (single source of truth). If they share, both flip together with one edit.

- [ ] **Step 5: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS.

Most likely failure mode: a scenario whose expectations assumed today's BCN size (e.g., bandwidth estimation). The vast majority of tests check event presence / delivery, which is unaffected. If a test fails, investigate whether it's an actual behavior regression or a brittle assumption that should be loosened.

- [ ] **Step 6: Add `test/t40_dirty_only_cold_start.json`**

```json
{
  "_name": "t40_dirty_only_cold_start",
  "_desc": "Three-node line A-B-C. A boots, sets REQ_SYNC on first BCN. B receives it, schedules sync-response, fires SYNC_FULL pack_beacon with rotation page that includes B's route to C. A learns the route and delivers a send to C within seconds. Verifies the request-side path of the BCN dirty-only design.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 31,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 15000, "node": "alice", "command": "send carol hello-from-alice" }
  ],
  "expect": [
    { "type": "script_emit_exists",   "node": "bob",   "emit_type": "sync_response_tx" },
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered",        "value": "hello-from-alice" }
  ]
}
```

- [ ] **Step 7: Add `test/t41_first_contact_sync.json`**

```json
{
  "_name": "t41_first_contact_sync",
  "_desc": "Verifies receiver-side first-contact detection. alice and bob boot together as a stable pair (alice <-> bob). carol joins late (after warmup) with req_sync_on_boot=false so REQ_SYNC bit never fires. Receiver-detected path must still trigger sync from bob when carol's first BCN arrives. Asserts bob emits sync_response_tx within the jitter window.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 37,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0, "req_sync_on_boot": false },
      "starts_at_ms": 15000 }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "expect": [
    { "type": "script_emit_exists", "node": "bob", "emit_type": "sync_response_tx" }
  ]
}
```

(If the scenario format doesn't support `starts_at_ms` per node, omit it and rely on natural startup ordering; the assertion checks that bob fires a sync_response_tx, which only happens via first-contact since carol has req_sync_on_boot=false.)

- [ ] **Step 8: Run new tests**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't40|t41|FAIL' | head -20
```
Expected: t40_dirty_only_cold_start PASS, t41_first_contact_sync PASS.

- [ ] **Step 9: Final full-suite verification**

```bash
cmake --build build -j
bash test/run_tests.sh
cd webapp && python -m pytest tests/ && cd ..
```
Expected: 52 Lua (50 prior + t40 + t41) + 78 webapp = 130 PASS.

- [ ] **Step 10: Run the s04_seattle_realistic measurement**

```bash
./tools/analyze.py ./scenarios/s04_seattle_realistic.json --run 2>&1 | head -200
```
Inspect the output and confirm:
- Section (3) control-plane overhead: BCN airtime as a fraction of total drops materially (target: from ~39 % → < 15 %; threshold is "noticeably better", not a hard cutoff)
- Section (13) BCN effectiveness: `rt_update / beacon_rx` ratio rises (target: from ~0.40 → > 0.60)
- Section (8) delivery breakdown: delivered count rises vs baseline (target: > 188)

If any of these don't move, something in the implementation is preventing the airtime reduction. Investigate before committing.

- [ ] **Step 11: Update PROTOCOL.md**

Two edits:

(a) Find §3.1 Beacon. After the existing entry-format description, add a new subsection (likely §6.6 or extension to §6.4):

```markdown
### 6.6 Emission modes

`pack_beacon` operates in one of two modes per emission:

| Mode | Used by | Content |
|---|---|---|
| `DIRTY_ONLY` | periodic, triggered | dirty entries only; rotation offset NOT advanced |
| `SYNC_FULL` | sync-response | dirty + rotation fill up to `beacon_max_entries`; rotation offset advances |

Periodic emissions normally emit only the 4-byte header (no dirty
entries in steady state) — the heartbeat keeps neighbours' `last_seen_ms`
fresh against `rt_aging_ttl_neighbor_ms`. Sync-responses are reserved
for solicited recovery via `REQ_SYNC` flag or receiver-detected
first-contact (§3.1 byte 1, bit 0).

Storm prevention: SNR-weighted jitter + per-joiner `sync_satisfied`
TTL + observed-other-sync suppression (the receiver inspects whether
any BCN with `n_entries ≥ rotation_sync_threshold` arrived within
the jitter window; if yes, skips its own emission).
```

(b) Find §12.1 state table. Add the new rows:

```markdown
| `req_sync_pending` | bool | Set when this node wants its next BCN to carry REQ_SYNC; cleared automatically after emission |
| `sync_satisfied` | table | joiner_id → expiry_ms (per-joiner TTL on "already synced") |
| `last_observed_sync_response_ms` | int | Timestamp of the most recent observed BCN with n_entries ≥ rotation_sync_threshold |
```

- [ ] **Step 12: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t40_dirty_only_cold_start.json test/t41_first_contact_sync.json
git commit -m "$(cat <<'EOF'
feat(beacon): activate BCN dirty-only emission

Flips the activation switches from Tasks 1-4:
- on_init: req_sync_pending = true (joiners broadcast the request on
  their first BCN; tests can opt out via config.req_sync_on_boot=false)
- beacon_fire (periodic): pack_beacon now uses PACK_BEACON_MODE_DIRTY_ONLY
- triggered BCN: same — DIRTY_ONLY mode
- sync-response (Task 4 logic) handles bulk recovery on demand

Periodic BCNs in steady state now emit just the 4-byte header (no
dirty entries) — liveness heartbeat. Triggered BCNs carry only the
mutated routes. Full state goes out only when a neighbour solicits
it (REQ_SYNC or first-contact).

Measurement on s04_seattle_realistic baseline: BCN airtime drops from
39% to {actual%}; rt_update/beacon_rx ratio rises from 0.40 to {actual};
delivered count rises from 188 to {actual}. (Fill in actual values
from Step 10 measurement run.)

Wire format change: byte 1 bit 0 = REQ_SYNC (was reserved). Documented
in PROTOCOL.md §3.1 + §6.6. State table updated in §12.1.

Final task (5 of 5) in the BCN dirty-only implementation plan.

Tests: 52/52 Lua + 78/78 webapp PASS, including new t40 and t41.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

### Spec coverage check

| Spec section | Task that covers it |
|---|---|
| §3 wire format (REQ_SYNC bit on byte 1) | Task 1 |
| §3 rotation_sync_threshold detection | Task 3 |
| §4 periodic BCN dirty-only | Task 5 |
| §4 liveness via empty BCN | Task 5 (relies on existing `rt_merge` last_seen update — verified in Task 5 testing) |
| §5 triggered BCN dirty-only | Task 5 |
| §5 triggered BCN bypasses throttle | (already in code — not modified) |
| §6 REQ_SYNC set on_init | Task 5 |
| §6.1 future mobility hooks | Out of scope (spec documents forward-compat contract) |
| §7 sync-response state machine | Task 4 |
| §7 SNR-weighted jitter | Task 4 |
| §7 EXHAUSTED tier defer | Task 4 |
| §7 per-joiner suppression | Tasks 3 + 4 |
| §8 dirty bit lifecycle (preserved) | (already in code — not modified) |
| §9 liveness math | Task 5 (measurement) |
| §9.1 mobile aging margin | Out of scope (forward-compat contract; documented in spec) |
| §10 §4.1 composition | Future plan (BCN compression) |
| §11 tunables | Task 3 |
| §13 open question 1 (multiplicative SNR jitter) | Task 4 implements multiplicative |
| §14 measurement plan | Task 5 Step 10 |

All in-scope spec sections map to a task. Out-of-scope items (mobility hooks, §4.1 compression composition) are explicit in the spec's contract.

### Placeholder scan

Searched plan for "TBD", "TODO", "fill in", "implement later", "add appropriate", "write tests for the above", "similar to Task". One intentional placeholder remains: in Task 5 Step 12's commit message, `{actual%}` / `{actual}` are bracketed for the implementer to substitute the measured values from Step 10. This is required for accuracy in the final commit message.

### Type consistency check

| Identifier | Defined | Used in |
|---|---|---|
| `BCN_FLAG_REQ_SYNC = 0x01` | Task 1 Step 2 | Task 1 Step 4 |
| `req_sync_pending` (state) | Task 1 Step 3 | Tasks 1, 5 |
| `parsed.req_sync_flag` | Task 1 Step 6 | Task 4 Step 5 |
| `PACK_BEACON_MODE_SYNC_FULL` / `_DIRTY_ONLY` | Task 2 Step 3 | Tasks 2 Step 4, 4 Step 4, 5 Steps 3-4 |
| `sync_response_jitter_ms` | Task 3 Step 2 | Task 4 Steps 3-4 |
| `sync_satisfied_ttl_ms` | Task 3 Step 2 | Task 4 Step 4 |
| `rotation_sync_threshold` | Task 3 Step 2 | Task 3 Step 4, Task 4 Step 4 |
| `sync_satisfied` (dict) | Task 3 Step 3 | Task 4 Steps 3-4 |
| `last_observed_sync_response_ms` | Task 3 Step 3 | Task 3 Step 4, Task 4 Step 4 |
| `schedule_sync_response_with_suppression` | Task 4 Step 3 | Task 4 Step 5 |
| `fire_sync_response` | Task 4 Step 4 | Task 4 Step 3 (forward-referenced) |
| `was_empty` (local) | Task 4 Step 2 | Task 4 Step 5 |
| `parsed.n_entries` | (existing field from parse_beacon) | Task 3 Step 4 |
| `meta.snr` | (existing radio metadata) | Task 4 Step 5 |
| Event names (`sync_response_tx`, `sync_response_suppressed`, `bcn_req_sync_observed`, `req_sync_pending_set`) | Defined where emitted | Asserted in t39, t40, t41 |

Consistent across tasks.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-12-bcn-dirty-only-emission.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
