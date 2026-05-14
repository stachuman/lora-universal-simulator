# BCN Dirty-Only Emission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch periodic and triggered BCNs to emit only dirty (changed) routes, with full state delivered on demand via solicited sync-response BCNs. Cuts BCN airtime from 39 % → ~10 % of total network airtime on the s04_seattle_realistic baseline.

**Architecture:** Five sequential tasks. Tasks 1-3 are no-op preparation (wire bit, pack-mode refactor, observation state). Task 4 wires the sync-response state machine behind `sync_response_enabled=false`, so it is behavior-neutral. Task 5 flips the activation — `on_init` sets `req_sync_pending=true`, `sync_response_enabled=true`, and periodic + triggered switch to `dirty_only` mode. Each task ends with all 49 existing integration tests + the suite's webapp pytests passing.

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
self.req_sync_pending             = true    -- cleared once a BCN carrying REQ_SYNC is accepted/scheduled
self.sync_satisfied               = {}      -- joiner_id → expiry_ms
self.last_observed_sync_response_ms = -1    -- timestamp of most recent observed n_entries ≥ rotation_sync_threshold
self.sync_response_enabled        = true    -- activation switch flipped in Task 5
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

- [ ] **Step 5: Keep `req_sync_pending` out of `pack_beacon` side effects**

Do **not** clear `req_sync_pending` inside `pack_beacon`. `pack_beacon` only constructs bytes; the frame can still be skipped by half-duplex, duty-cycle, LBT, or runtime TX policy. The flag must remain pending until a BCN carrying the bit is accepted by the beacon/flood TX path.

Implementation note for Task 1: this means Step 4 is the only encoder change in `pack_beacon_byte1`. The actual clear is added in Task 2 when `send_beacon_page` has enough context to know whether TX was accepted/scheduled.

- [ ] **Step 6: Update `parse_beacon` to expose the bit**

In `parse_beacon`, find where the byte-1 decode constructs `out`. Add to that table:

```lua
req_sync_flag = (b1 & BCN_FLAG_REQ_SYNC) ~= 0,
```

After reading byte 4 into local `n`, also expose the raw count:

```lua
out.n_entries = n
```

The existing code can keep using `#out.entries`, but the sync-response suppression path needs the raw field name to be stable and obvious.

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
    { "type": "script_emit_contains", "node": "bob", "emit_type": "bcn_req_sync_observed", "value": "" }
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
emission and is cleared by the beacon TX path once that BCN is accepted
for TX. Receivers expose the bit via
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
- Modify: `scenarios/dv_dual_sf.lua` — `pack_beacon` (~line 796), `send_beacon_page`, all callers of `pack_beacon` / `send_beacon_page`

**Rationale:** Add a `mode` parameter so the function can either emit "today's behavior" (dirty + rotation fill, called `sync_full`) or "future behavior" (dirty entries only, called `dirty_only`). Also plumb that mode through `send_beacon_page`, because sync-response must use the normal beacon/flood TX policy instead of direct `self:tx`. All current callers pass `sync_full`, so behavior is unchanged except that `req_sync_pending` is now cleared only after a BCN carrying it is accepted by the TX path.

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

Also guard dirty-flag clearing so only `PACK_BEACON_MODE_DIRTY_ONLY`
consumes dirty entries. `SYNC_FULL` is a solicited snapshot for one joiner
and may not be heard by every neighbour that still needs the mutation.

- [ ] **Step 4: Add `mode` to `send_beacon_page` and pass it to `pack_beacon`**

Change:

```lua
local function send_beacon_page(self, kind)
```

to:

```lua
local function send_beacon_page(self, kind, mode, opts)
  mode = mode or PACK_BEACON_MODE_SYNC_FULL
  opts = opts or {}
```

Then change its `pack_beacon` call to pass `mode`:

```lua
local frame, new_offset, diff = pack_beacon(self,
                                            self.beacon_max_entries,
                                            self.beacon_offset,
                                            mode)
```

Track whether this frame actually carries REQ_SYNC before TX:

```lua
local carried_req_sync = (frame:byte(2) & BCN_FLAG_REQ_SYNC) ~= 0
```

Call `tx_flood` into a local result, then clear `req_sync_pending` only when the frame was accepted/scheduled:

```lua
local accepted = tx_flood(self, frame, {
  sf    = self.routing_sf,
  label = "BCN",
  info  = string.format("rt=%d/%d off=%d dirty=%d kind=%s",
    page_n, total, self.beacon_offset, diff.dirty_n, kind),
})
if accepted and carried_req_sync then
  self.req_sync_pending = false
end
return accepted
```

Update the existing budget-tier skip inside `send_beacon_page` so sync-response can bypass the coarse CRITICAL-tier beacon gate while still retaining `tx_flood`'s hard duty-cycle legality check:

```lua
if (not opts.bypass_budget_tier_gate)
   and compute_budget_tier(self) >= BUDGET_TIER_CRITICAL then
  ...
end
```

This deliberately does not clear the flag when `send_beacon_page` returns before packing due to pending TX/RX or budget, or when `tx_flood` rejects the frame due to duty-cycle/LBT skip.

- [ ] **Step 5: Update every `send_beacon_page` caller to pass `PACK_BEACON_MODE_SYNC_FULL` explicitly**

For each caller located in Step 2, prefer updating the higher-level `send_beacon_page` call. Change:
```lua
send_beacon_page(self, "periodic")
```
to:
```lua
send_beacon_page(self, "periodic", PACK_BEACON_MODE_SYNC_FULL)
```

Do the same for triggered calls. This makes the intent explicit even though `sync_full` is the default. Future callers (Task 5) will pass `dirty_only` deliberately.

- [ ] **Step 6: Run tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS. No behavior change — refactor only.

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
refactor(beacon): pack_beacon gains mode parameter

Splits pack_beacon's two phases via a mode argument:
- PACK_BEACON_MODE_SYNC_FULL: dirty + rotation fill (today's behavior)
- PACK_BEACON_MODE_DIRTY_ONLY: dirty entries only, no rotation fill

Plumbs the mode through send_beacon_page so sync-response can reuse the
normal beacon/flood TX policy in a later task. send_beacon_page also gains
an opts table so sync-response can bypass the coarse CRITICAL-tier beacon
gate while retaining tx_flood's hard duty-cycle check. REQ_SYNC clearing
moves to send_beacon_page after a BCN carrying the bit is accepted/scheduled,
so local pre-TX skips do not lose the sync request.

All current beacon callers pass SYNC_FULL explicitly, so emission content
is unchanged this task. DIRTY_ONLY mode is plumbed for Task 5 activation.

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

Note: `parsed.n_entries` is added in Task 1 Step 6. Use that exact field name.

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

### Task 4: Sync-response handler + first-contact detection (wired behind disabled switch)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `rt_merge` (to surface first-contact), `on_recv` 'B' (to call the new scheduler), new helpers (scheduler + fire function)

**Rationale:** Land the complete sync-response state machine without changing behavior. The triggers (REQ_SYNC flag from parsed BCN, first-contact from rt_merge) are wired, but `self.sync_response_enabled=false` makes the scheduler a no-op until Task 5. This avoids a boot-time burst of full sync BCNs in existing scenarios before periodic/triggered BCNs have been shrunk.

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

- [ ] **Step 3: Add disabled activation state in `on_init`**

Near the Task 3 sync-response state:

```lua
self.sync_response_enabled = (config.sync_response_enabled == true) -- Task 5 flips default to true
```

Task 4 must remain behavior-neutral. Tests or ad-hoc scenarios can opt in by setting `sync_response_enabled=true`, but no existing scenario changes behavior yet.

- [ ] **Step 4: Add the scheduler helper**

Add this function (near other helper definitions; placement matches the convention used by `try_cascade_requeue` and similar helpers):

```lua
local fire_sync_response  -- forward declaration for scheduler callback

local function schedule_sync_response_with_suppression(self, joiner_id, rx_snr)
  if not self.sync_response_enabled then
    return
  end

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

- [ ] **Step 5: Add the fire helper**

```lua
fire_sync_response = function(self, joiner_id)
  if not self.sync_response_enabled then
    return
  end

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
    -- Do not mark the joiner satisfied. We observed another large BCN,
    -- but hidden/asymmetric topology means we cannot prove the joiner
    -- heard it. Reschedule after the suppression window and re-check.
    self:after(self.sync_response_jitter_ms, fire_sync_response, joiner_id)
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

  -- Emit the sync-response BCN through the normal beacon/flood TX path.
  -- It bypasses adaptive throttle because this helper is called directly,
  -- but it still receives half-duplex, hard duty-cycle legality,
  -- LBT/flood, telemetry, last_beacon_tx_ms, and REQ_SYNC clearing
  -- behavior from send_beacon_page. The coarse CRITICAL-tier beacon gate
  -- is bypassed so STRAINED/CRITICAL nodes can still answer sync; truly
  -- exhausted nodes are filtered above and tx_flood still enforces budget.
  local accepted = send_beacon_page(self, "sync", PACK_BEACON_MODE_SYNC_FULL,
                                    { bypass_budget_tier_gate = true })
  if not accepted then
    self:after(self.rts_busy_retry_ms, fire_sync_response, joiner_id)
    return
  end

  self:emit("sync_response_tx", { joiner = name_of(self, joiner_id) })

  -- Mark this joiner satisfied so we don't re-respond within the TTL.
  self.sync_satisfied[joiner_id] = self:now() + self.sync_satisfied_ttl_ms
end
```

The `sync_response_tx` event intentionally does not duplicate `beacon_tx.n_entries`; `send_beacon_page` already emits `beacon_tx` and `beacon_diff_breakdown` with the exact count and kind.

- [ ] **Step 6: Wire the scheduler into `on_recv` 'B'**

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

- [ ] **Step 7: Run tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS. Because `sync_response_enabled` defaults false in Task 4, first-contact detection does not emit extra BCNs yet.

- [ ] **Step 8: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(beacon): sync-response handler behind disabled switch

Implements the sync-response state machine from the BCN dirty-only
design (§7 of the spec):
- schedule_sync_response_with_suppression: disabled unless
  sync_response_enabled=true; SNR-weighted jitter; per-joiner
  sync_satisfied TTL dedup.
- fire_sync_response: re-checks per-joiner suppression on fire,
  delays if last_observed_sync_response_ms is within the jitter window
  without marking the joiner satisfied, defers under EXHAUSTED budget
  or pending_tx/pending_rx state, then emits via send_beacon_page in
  SYNC_FULL mode so normal flood TX policy and telemetry still apply;
  sync bypasses only the coarse CRITICAL-tier beacon gate.
- on_recv 'B' triggers schedule on req_sync_flag OR receiver-detected
  first-contact (rt[src] was empty before this BCN).

Activation: sync_response_enabled defaults false in this task, so the
new code is behavior-neutral. Task 5 flips the default to true while
also shrinking periodic/triggered BCNs to DIRTY_ONLY.

Task 4 of 5 in the BCN dirty-only implementation plan.

Tests: 50/50 PASS.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Activate dirty-only emission + on_init REQ_SYNC

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `on_init` (set `req_sync_pending = true`, `sync_response_enabled = true`), `beacon_fire` (periodic — use `DIRTY_ONLY`), trigger-BCN path (use `DIRTY_ONLY`)
- Modify: `docs/PROTOCOL.md` — add §6.6 documenting the new emission modes, expand §12.1 state table
- Add: `test/t40_dirty_only_cold_start.json` — verifies joiner gets routes via REQ_SYNC → sync-response
- Add: `test/t41_first_contact_sync.json` — verifies receiver-detected first-contact triggers sync

**Rationale:** Flip the activation. Periodic and triggered BCNs become dirty-only (often empty); joiners set REQ_SYNC at boot; neighbours respond with sync (wired but disabled in Task 4). The full feature is live; measurement validates the airtime drop.

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

- [ ] **Step 3: Enable sync-response by default**

Modify the line added in Task 4:

```lua
self.sync_response_enabled = (config.sync_response_enabled ~= false) -- default: true; tests can opt out
```

- [ ] **Step 4: Switch periodic BCN to `DIRTY_ONLY`**

Find `beacon_fire` / `send_beacon_page` callers. Change periodic calls from:

```lua
send_beacon_page(self, "periodic", PACK_BEACON_MODE_SYNC_FULL)
```

to:

```lua
send_beacon_page(self, "periodic", PACK_BEACON_MODE_DIRTY_ONLY)
```

Note: in `DIRTY_ONLY` mode the `beacon_offset` does NOT advance (rotation is skipped). So `new_offset == self.beacon_offset` always.

Before packing a dirty-only page, call `mark_remote_refresh_dirty(self)`.
That helper re-marks stable multi-hop primary routes dirty after
`rt_refresh_remote_ms` when it is configured. The default is `0`
(disabled), because s04 measurements showed aggressive remote refresh
restores too much BCN airtime. When a dirty route is actually emitted,
store `entry.last_advertised_ms = self:now()` while clearing its dirty flag.

- [ ] **Step 5: Switch triggered BCN to `DIRTY_ONLY`**

Find the triggered-beacon emission path. Change:

```lua
send_beacon_page(self, "triggered", PACK_BEACON_MODE_SYNC_FULL)
```

to:

```lua
send_beacon_page(self, "triggered", PACK_BEACON_MODE_DIRTY_ONLY)
```

- [ ] **Step 6: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 50/50 PASS.

Most likely failure mode: a scenario whose expectations assumed today's BCN size (e.g., bandwidth estimation). The vast majority of tests check event presence / delivery, which is unaffected. If a test fails, investigate whether it's an actual behavior regression or a brittle assumption that should be loosened.

- [ ] **Step 7: Add `test/t40_dirty_only_cold_start.json`**

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
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "sync_response_tx", "value": "" },
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered",        "value": "hello-from-alice" }
  ]
}
```

- [ ] **Step 8: Add `test/t41_first_contact_sync.json`**

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
      "start_at_ms": 15000 }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "expect": [
    { "type": "script_emit_contains", "node": "bob", "emit_type": "sync_response_tx", "value": "" }
  ]
}
```

The scenario format supports `start_at_ms` per node; use that exact field name. The assertion checks that bob fires a sync_response_tx, which only happens via first-contact since carol has `req_sync_on_boot=false`.

- [ ] **Step 9: Run new tests**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't40|t41|FAIL' | head -20
```
Expected: t40_dirty_only_cold_start PASS, t41_first_contact_sync PASS.

- [ ] **Step 10: Final full-suite verification**

```bash
cmake --build build -j
bash test/run_tests.sh
cd webapp && python -m pytest tests/ && cd ..
```
Expected: 52 Lua (50 prior + t40 + t41) + 78 webapp = 130 PASS.

- [ ] **Step 11: Run the s04_seattle_realistic measurement**

```bash
./tools/analyze.py ./scenarios/s04_seattle_realistic.json --run 2>&1 | head -200
```
Inspect the output and confirm:
- Section (3) control-plane overhead: BCN airtime as a fraction of total drops materially (target: from ~39 % → < 15 %; threshold is "noticeably better", not a hard cutoff)
- Section (13) BCN effectiveness: `rt_update / beacon_rx` ratio rises (target: from ~0.40 → > 0.60)
- Section (8) delivery breakdown: delivered count rises vs baseline (target: > 188)

If any of these don't move, something in the implementation is preventing the airtime reduction. Investigate before committing.

- [ ] **Step 12: Update PROTOCOL.md**

Two edits:

(a) Find §3.1 Beacon. After the existing entry-format description, add a new subsection (likely §6.6 or extension to §6.4):

```markdown
### 6.6 Emission modes

`pack_beacon` operates in one of two modes per emission:

| Mode | Used by | Content |
|---|---|---|
| `DIRTY_ONLY` | periodic, triggered | dirty entries only; rotation offset NOT advanced; multi-hop entries may be re-marked dirty by `rt_refresh_remote_ms` |
| `SYNC_FULL` | sync-response | dirty + rotation fill up to `beacon_max_entries`; rotation offset advances; dirty flags are not cleared |

Periodic emissions normally emit only the 4-byte header (no dirty
entries in steady state) — the heartbeat keeps neighbours' `last_seen_ms`
fresh against `rt_aging_ttl_neighbor_ms`. Multi-hop route refresh is an
explicit deployment lever via `rt_refresh_remote_ms` and is disabled by
default. Sync-responses are reserved for solicited recovery via `REQ_SYNC`
flag or receiver-detected first-contact (§3.1 byte 1, bit 0).

Storm prevention: SNR-weighted jitter + per-joiner `sync_satisfied`
TTL + observed-other-sync suppression (the receiver inspects whether
any BCN with `n_entries ≥ rotation_sync_threshold` arrived within
the jitter window; if yes, skips its own emission).
```

(b) Find §12.1 state table. Add the new rows:

```markdown
| `req_sync_pending` | bool | Set when this node wants its next BCN to carry REQ_SYNC; cleared after a BCN carrying it is accepted/scheduled by the beacon TX path |
| `sync_response_enabled` | bool | Enables REQ_SYNC / first-contact sync-response handling; default true after activation |
| `sync_satisfied` | table | joiner_id → expiry_ms (per-joiner TTL on "already synced") |
| `last_observed_sync_response_ms` | int | Timestamp of the most recent observed BCN with n_entries ≥ rotation_sync_threshold |
```

- [ ] **Step 13: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t40_dirty_only_cold_start.json test/t41_first_contact_sync.json
git commit -m "$(cat <<'EOF'
feat(beacon): activate BCN dirty-only emission

Flips the activation switches from Tasks 1-4:
- on_init: req_sync_pending = true (joiners broadcast the request on
  their first BCN; tests can opt out via config.req_sync_on_boot=false)
- on_init: sync_response_enabled defaults true (tests can opt out via
  config.sync_response_enabled=false)
- beacon_fire (periodic): send_beacon_page now uses PACK_BEACON_MODE_DIRTY_ONLY
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
| §8 dirty bit lifecycle | Task 2 mode split preserves clearing for DIRTY_ONLY and keeps dirty set on SYNC_FULL |
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
| `parsed.req_sync_flag` | Task 1 Step 6 | Task 4 Step 6 |
| `parsed.n_entries` | Task 1 Step 6 | Task 3 Step 4 |
| `PACK_BEACON_MODE_SYNC_FULL` / `_DIRTY_ONLY` | Task 2 Step 3 | Tasks 2 Step 4, 4 Step 5, 5 Steps 4-5 |
| `sync_response_enabled` | Task 4 Step 3 | Task 4 scheduler/fire guards, Task 5 activation |
| `sync_response_jitter_ms` | Task 3 Step 2 | Task 4 Steps 4-5 |
| `sync_satisfied_ttl_ms` | Task 3 Step 2 | Task 4 Step 5 |
| `rotation_sync_threshold` | Task 3 Step 2 | Task 3 Step 4, Task 4 Step 5 |
| `sync_satisfied` (dict) | Task 3 Step 3 | Task 4 Steps 4-5 |
| `last_observed_sync_response_ms` | Task 3 Step 3 | Task 3 Step 4, Task 4 Step 5 |
| `schedule_sync_response_with_suppression` | Task 4 Step 4 | Task 4 Step 6 |
| `fire_sync_response` | Task 4 Step 5 | Task 4 Step 4 (forward-declared) |
| `was_empty` (local) | Task 4 Step 2 | Task 4 Step 6 |
| `meta.snr` | (existing radio metadata) | Task 4 Step 6 |
| Event names (`sync_response_tx`, `sync_response_suppressed`, `bcn_req_sync_observed`, `req_sync_pending_set`) | Defined where emitted | Asserted in t39, t40, t41 |

Consistent across tasks.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-12-bcn-dirty-only-emission.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
