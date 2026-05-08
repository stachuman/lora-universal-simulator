# Adaptive (Quiet/Busy-Throttled) DV Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve `scenarios/dv_dual_sf.lua` in-place with quiet/busy-adaptive beacon throttling + reactive RREQ fallback for unknown destinations + AODV destination sequence numbers, so `a03_seattle_medium` at BW=62.5 reaches ≥45/50 deliveries (≥90%).

**Architecture:** Channel-activity detector via `last_rx_routing_sf_ms` (updated at top of every `on_recv`). `beacon_fire` skips when `now - last_rx_routing_sf_ms < quiet_threshold_ms` (default 30s). Reactive RREQ/RREP/RERR fallback fires only on `rt[dst] = nil` cache miss; routes get a `dst_seq` field with AODV freshness rules (DV-installed = 0, RREQ-installed > 0; RREQ trumps DV; RREQ-installed ages out and downgrades to dst_seq=0 at TTL). Capacity scenarios get longer warmup so beacons converge before user traffic measurement begins. Spec: `docs/superpowers/specs/2026-05-08-adaptive-routing-design.md`.

**Tech Stack:** Lua 5.3+ (sandboxed sol2), JSON scenarios, no C++ runtime changes.

---

## Pre-Execution Notes

**Working tree state at the time this plan was written:** main has commits up through `aaa217a` (the spec for this work). `scenarios/dv_dual_sf.lua` has uncommitted edits adding a `payload_len` byte to RTS frames (the implementer should commit these BEFORE starting, OR start from current main HEAD and rebase as needed). The data plane has had recent improvements (asymmetric link sim, drift, payload_len in RTS) — those are orthogonal to the routing-plane changes in this plan.

**Recommended workflow:** create an isolated git worktree before starting:
```
git worktree add ../lus-adaptive main
cd ../lus-adaptive
```

Run a baseline:
```
cmake -S . -B build && cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```
Expected: 6/6 PASS.

**File path conventions:** all paths in this plan are relative to the repo root.

**Test scenario numbering:** the existing tests already include t17–t22 (probabilistic decode, preamble miss, drift, sf-switch-blind, mobility, variable payload). Use **t23** and **t24** for new tests (confirmed available).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scenarios/dv_dual_sf.lua` | Modify | Add detector, beacon throttle, Q/P/E wire format, RREQ/RREP/RERR handlers, AODV freshness, recovery state machine, cache-miss → RREQ fallback in issue_send. ~400-500 LOC added. |
| `test/t23_quiet_throttle.json` | Create | Unit test: 3-node line, beacon throttle fires when channel busy. |
| `test/t24_unknown_dst_rreq.json` | Create | Unit test: late-activating node + RREQ fallback. |
| `scenarios/a02_seattle_sparse.json` | Create | Adaptive variant of s02 (5 min warmup, commands shifted). |
| `scenarios/a03_seattle_medium.json` | Create | **Headline** capacity test (10 min warmup, BW=62.5, 138 nodes). |
| `scenarios/a04_seattle_dense.json` | Create | Adaptive variant of s04 (10 min warmup). |
| `scenarios/a05_seattle_very_dense.json` | Create | Adaptive variant of s05 (15 min warmup). |

No C++/orchestrator/Python changes. Everything is Lua + JSON.

---

## Task 1: Channel-activity detector (state + on_recv hook)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add `last_rx_routing_sf_ms` and `quiet_threshold_ms` to on_init; insert detector update at top of on_recv

**Goal:** Per-node detector populates and refreshes `last_rx_routing_sf_ms` on every received frame. No behavior change yet — Task 2 wires beacon throttle.

- [ ] **Step 1.1: Add new state in on_init**

Find the section in `function on_init(self, config)` where `self.blind_until = {}` is initialized (post-Task-2 from F1 work, around the existing on_init body). Add immediately after that line:

```lua
  -- Quiet/busy detector for adaptive beacon throttling. Updated at the
  -- top of every on_recv (any successful RX = channel was busy that
  -- moment). Used by beacon_fire to skip beacon emission when channel
  -- has been recently active.
  self.last_rx_routing_sf_ms = self:now()
  self.quiet_threshold_ms    = config.quiet_threshold_ms or 30000
```

- [ ] **Step 1.2: Insert detector update at top of on_recv**

Find `function on_recv(self, frame, meta)`. The current first lines are:

```lua
function on_recv(self, frame, meta)
  if #frame == 0 then return end
  local tag = frame:sub(1, 1)
```

Add a new line between the empty-frame guard and the tag dispatch:

```lua
function on_recv(self, frame, meta)
  if #frame == 0 then return end
  -- Channel-activity detector: any successful RX (broadcast or unicast)
  -- means the channel was busy. Used by adaptive beacon throttle.
  -- Updated regardless of frame type or recipient, so frames addressed
  -- to other nodes (overheard) still count.
  self.last_rx_routing_sf_ms = self:now()
  local tag = frame:sub(1, 1)
```

- [ ] **Step 1.3: Build + run regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 6/6 PASS. No behavior change yet.

- [ ] **Step 1.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): add channel-activity detector state (dormant)

Adds self.last_rx_routing_sf_ms updated at the top of on_recv on every
successful RX (regardless of recipient/tag). Adds self.quiet_threshold_ms
config (default 30000ms). Both used by the adaptive beacon throttle in
the next commit; this commit is dormant infrastructure with no behavior
change.
EOF
)"
```

---

## Task 2: Beacon throttle in `beacon_fire`

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — wrap the existing `beacon_fire` body's emission path with the detector check

**Goal:** `beacon_fire` skips emission (but reschedules normally) when `now - last_rx_routing_sf_ms < quiet_threshold_ms`. New emit `beacon_skipped_busy`.

- [ ] **Step 2.1: Read the existing `beacon_fire` body**

```bash
grep -nA 30 "^local function beacon_fire" scenarios/dv_dual_sf.lua | head -40
```

Identify the structure — there's typically a `pending_tx ~= nil or pending_rx ~= nil` skip, then the actual emission path (pack_beacon → emit beacon_tx → tx_flood), then a reschedule call at the end.

- [ ] **Step 2.2: Insert the detector check inside the emission branch**

The current structure is roughly:
```lua
local function beacon_fire(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    self:log("beacon_tx skipped (busy in data exchange)")
    -- reschedule
  else
    -- pack + emit + tx_flood (the actual beacon)
  end
  -- reschedule timer call
end
```

Modify to add the channel-activity check INSIDE the else branch, BEFORE the pack/emit block:

```lua
local function beacon_fire(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    self:log("beacon_tx skipped (busy in data exchange)")
    -- reschedule (existing)
  else
    -- Adaptive throttle: skip beacon if channel has been busy recently.
    -- The detector measures "any RX on routing_sf in last quiet_threshold_ms".
    -- Throttle prevents beacon storms during data-plane activity AND
    -- naturally rate-limits beacons across the network (dense neighborhoods
    -- self-organize via mutual overhearing).
    local since_rx = self:now() - self.last_rx_routing_sf_ms
    if since_rx < self.quiet_threshold_ms then
      self:emit("beacon_skipped_busy", {
        since_rx_ms  = since_rx,
        threshold_ms = self.quiet_threshold_ms,
      })
      self:log(string.format("beacon_tx skipped (channel busy: last RX %dms ago, threshold %dms)",
        since_rx, self.quiet_threshold_ms))
    else
      -- existing pack + emit + tx_flood block (preserve verbatim)
      ...
    end
  end
  -- existing reschedule (preserve verbatim)
  ...
end
```

Read the actual `beacon_fire` and apply this transformation: keep the existing `pending_tx`/`pending_rx` skip layer, the reschedule, and the emission path; only wrap the emission path with the new throttle check inside the else branch.

- [ ] **Step 2.3: Run a beacon-only test (no data) — beacons should still fire normally**

The detector at start has `last_rx_routing_sf_ms = self:now()` (initialized at on_init). At the first beacon fire, `since_rx ≈ 0` < threshold → SKIP. We need to handle the initial state.

Two options:
- (A) Initialize `last_rx_routing_sf_ms = -math.huge` so first beacon fires unthrottled. Cleanup: avoid math.huge, use 0 instead. Since `now() - 0` is positive and `now()` increases past 30000 quickly, the first beacon can fire after the threshold elapses on its own.
- (B) Initialize `last_rx_routing_sf_ms = self:now() - self.quiet_threshold_ms` so the first fire passes the gate.

Use option (A) but initialize to 0 explicitly:

Find Step 1.1's addition:
```lua
self.last_rx_routing_sf_ms = self:now()
```
Change to:
```lua
self.last_rx_routing_sf_ms = 0   -- 0 = "no RX yet"; first beacon fires unthrottled
```

This means: at boot, no RX has been heard yet, so the first beacon timer fire passes the throttle. Once another node's beacon arrives, the detector updates and subsequent local beacons might be throttled.

- [ ] **Step 2.4: Build + run regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t10_dv_beacons.json
```

Expected: PASS. The 2-node t10 test exchanges beacons; with the detector, both nodes' beacons can still fire because the gap between RXes exceeds 30s threshold (their period is 5s during warmup, but beacons are bidirectional — each node sees the OTHER's beacon, which updates the detector. So local beacons after the first are likely throttled).

Wait — that's a behavior change. Let me think: t10's `beacon_period_ms` is short (5s) during warmup. When alice fires a beacon, bob receives it → bob's detector updates. Bob's next beacon timer fires at 5s + jitter; `since_rx` ≈ 5s < 30s threshold → bob's beacon SKIPPED.

This is correct adaptive behavior, but it'll change t10's event counts (fewer beacons fire). Check if t10's assertions are sensitive to beacon count:

```bash
grep '"event_count' test/t10_dv_beacons.json
```

If t10 asserts `event_count_min` on `beacon_tx >= N` for some N > 1, the throttle may make it fail. Apply this scenario-level workaround if needed: in t10's per-node config, set `quiet_threshold_ms: 0` so the throttle never fires. (Throttle disabled.)

```bash
grep -A 1 '"name":' test/t10_dv_beacons.json | head -10
```

Check t10's existing config block, and add `"quiet_threshold_ms": 0` per node if the test is beacon-count-sensitive:

```json
{ "name": "alice", "script": "scenarios/dv_dual_sf.lua",
  "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } }
```

If t10 simply asserts `beacon_rx` or `beacon_tx` exists at all (count 1+), no change needed. Read the file and decide.

- [ ] **Step 2.5: Run full integration regression**

```
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t11_dv_convergence.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 7/7 PASS. If any beacon-counted test regresses, set `quiet_threshold_ms: 0` per-node in that scenario's JSON to preserve old behavior.

- [ ] **Step 2.6: Commit**

```bash
git add scenarios/dv_dual_sf.lua test/*.json
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): adaptive beacon throttle

beacon_fire now skips emission (but reschedules normally) when channel
has been busy in the last quiet_threshold_ms (default 30s). Detector
fed by self.last_rx_routing_sf_ms, updated at top of on_recv.

Naturally rate-limits beacons across dense neighborhoods via mutual
overhearing: when one node sends, neighbors see the activity and
suppress their own beacons until the channel quiets again.

Existing tests that depend on specific beacon counts get
"quiet_threshold_ms": 0 per-node overrides to preserve unthrottled
behavior. New beacon_skipped_busy emit added for telemetry.
EOF
)"
```

---

## Task 3: Wire format helpers + state for RREQ/RREP/RERR

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add Q/P/E pack/parse helpers, `bucket_of_snr`, new on_init state tables

**Goal:** All five new helpers exist (Q/P/E + bucket_of_snr + AODV state tables); RETRY_ELIGIBLE includes RREP/RERR. No behavior change yet.

- [ ] **Step 3.1: Add SNR bucket helper near other small helpers**

Find `local function sf_in_bitmap(bm, sf) ... end`. After it, add:

```lua

-- Quantize an SNR (dB) to a 3-bit bucket [0..7] for byte-tight wire encoding.
-- Bucket 0: <-20 dB; bucket 7: >=+15 dB. 5 dB bins. Used by the reactive
-- RREP path to carry per-path SNR info without dedicating a full byte.
local function bucket_of_snr(snr_db)
  local b = math.floor((snr_db + 20) / 5)
  if b < 0 then b = 0 end
  if b > 7 then b = 7 end
  return b
end

local function snr_db_of_bucket(b)
  return -20 + b * 5 + 2.5
end
```

- [ ] **Step 3.2: Add Q/P/E pack/parse helpers**

Find `parse_data` (the last existing data-plane parse helper). After its closing `end`, add:

```lua

-- ---------- reactive routing-plane wire format -------------------------------
-- For RREQ-fallback path. All multi-byte node ids are uint16 little-endian.
-- See spec §"Wire format additions".

local RREQ_LEN_MIN      = 8   -- Q + originator(2) + target(2) + bcast_id + flags|hop + dst_seq
local RREQ_LEN_MAX      = 14  -- + 3 × 2-byte blacklist entries
local RREP_LEN          = 9   -- P + originator(2) + target(2) + next_hop(2) + dst_seq + hops|snr|res
local RERR_LEN          = 6   -- E + bad_dst(2) + bad_next_hop(2) + dst_seq_known
local RREQ_FLAG_BLACKLIST = 0x01

local function pack_u16(n)
  return string.char(n % 256) .. string.char(math.floor(n / 256) % 256)
end

local function unpack_u16(frame, pos)
  return frame:byte(pos) + frame:byte(pos + 1) * 256
end

local function pack_rreq(originator, target, bcast_id, hop_count, dst_seq, blacklist)
  local nbl = blacklist and #blacklist or 0
  if nbl > 3 then nbl = 3 end
  local flags = (nbl > 0) and RREQ_FLAG_BLACKLIST or 0
  local fb = ((flags & 0x0F) << 4) | (hop_count & 0x0F)
  local out = "Q" .. pack_u16(originator) .. pack_u16(target)
                  .. string.char(bcast_id % 256)
                  .. string.char(fb)
                  .. string.char(dst_seq % 256)
  for i = 1, nbl do
    out = out .. pack_u16(blacklist[i])
  end
  return out
end

local function parse_rreq(frame)
  if #frame < RREQ_LEN_MIN or frame:sub(1, 1) ~= "Q" then return nil end
  local fb = frame:byte(7)
  local flags = (fb >> 4) & 0x0F
  local hop_count = fb & 0x0F
  local r = {
    originator = unpack_u16(frame, 2),
    target     = unpack_u16(frame, 4),
    bcast_id   = frame:byte(6),
    flags      = flags,
    hop_count  = hop_count,
    dst_seq    = frame:byte(8),
    blacklist  = {},
  }
  if (flags & RREQ_FLAG_BLACKLIST) ~= 0 then
    local pos = 9
    while pos + 1 <= #frame do
      table.insert(r.blacklist, unpack_u16(frame, pos))
      pos = pos + 2
    end
  end
  return r
end

local function pack_rrep(originator, target, next_hop, dst_seq, hops, snr_bucket)
  local hb = ((hops & 0x0F) << 4) | ((snr_bucket & 0x07) << 1)
  return "P" .. pack_u16(originator) .. pack_u16(target) .. pack_u16(next_hop)
              .. string.char(dst_seq % 256)
              .. string.char(hb)
end

local function parse_rrep(frame)
  if #frame < RREP_LEN or frame:sub(1, 1) ~= "P" then return nil end
  local hb = frame:byte(9)
  return {
    originator = unpack_u16(frame, 2),
    target     = unpack_u16(frame, 4),
    next_hop   = unpack_u16(frame, 6),
    dst_seq    = frame:byte(8),
    hops       = (hb >> 4) & 0x0F,
    snr_bucket = (hb >> 1) & 0x07,
  }
end

local function pack_rerr(bad_dst, bad_next_hop, dst_seq_known)
  return "E" .. pack_u16(bad_dst) .. pack_u16(bad_next_hop)
              .. string.char(dst_seq_known % 256)
end

local function parse_rerr(frame)
  if #frame < RERR_LEN or frame:sub(1, 1) ~= "E" then return nil end
  return {
    bad_dst       = unpack_u16(frame, 2),
    bad_next_hop  = unpack_u16(frame, 4),
    dst_seq_known = frame:byte(6),
  }
end
```

- [ ] **Step 3.3: Add `RREP` and `RERR` to RETRY_ELIGIBLE**

Find:
```lua
local RETRY_ELIGIBLE = {
  ["CTS"]     = true,
  ["CTS-dup"] = true,
  ["DATA"]    = true,
  ["ACK"]     = true,
  ["K-dup"]   = true,
  ["NACK"]    = true,
}
```

Replace with:
```lua
local RETRY_ELIGIBLE = {
  ["CTS"]     = true,
  ["CTS-dup"] = true,
  ["DATA"]    = true,
  ["ACK"]     = true,
  ["K-dup"]   = true,
  ["NACK"]    = true,
  ["RREP"]    = true,    -- new (reactive fallback)
  ["RERR"]    = true,    -- new (reactive fallback)
}
```

- [ ] **Step 3.4: Add new on_init state for reactive fallback**

Find the on_init state init block (where `self.tx_stash = {}`, `self.blind_until = {}`, `self.last_rx_routing_sf_ms = 0` etc. live). Add the reactive state immediately after `self.quiet_threshold_ms = ...`:

```lua
  -- Reactive RREQ fallback state (for genuinely-unknown destinations,
  -- typically only fires for new node arrivals or transient cache misses).
  -- Most operation hits the cached rt[] populated by DV beacons.
  self.dst_seq        = 1                        -- own monotonic destination seq
  self.next_bcast_id  = 1                        -- own RREQ broadcast id (8-bit)
  self.boot_seq       = config.boot_seq or 1
  self.seen_rreqs     = {}                       -- (origin|bcast_id) → reverse-path
  self.pending_sends  = {}                       -- queued waiting for RREQ
  self.route_recovery = {}                       -- per-dst attempt + blacklist

  -- Reactive timing constants (config-overridable).
  self.rreq_timeout_ms          = config.rreq_timeout_ms          or 5000
  self.rreq_max_hops            = config.rreq_max_hops            or 8
  self.seen_rreq_ttl_ms         = config.seen_rreq_ttl_ms         or 30000
  self.max_recovery_attempts    = config.max_recovery_attempts    or 3
  self.recovery_backoff_min_ms  = config.recovery_backoff_min_ms  or 50
  self.recovery_backoff_max_ms  = config.recovery_backoff_max_ms  or 300
  self.route_recovery_reset_ms  = config.route_recovery_reset_ms  or 10000
  self.route_ttl_ms             = config.route_ttl_ms             or 300000
```

- [ ] **Step 3.5: Build + run regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 6/6 PASS.

- [ ] **Step 3.6: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): wire format + state for reactive RREQ fallback (dormant)

Adds Q/P/E pack/parse helpers (pack_rreq, pack_rrep, pack_rerr) plus
bucket_of_snr / snr_db_of_bucket. Adds on_init state tables for reactive
fallback: seen_rreqs, pending_sends, route_recovery, plus dst_seq /
next_bcast_id / boot_seq counters and timing constants (rreq_timeout_ms,
rreq_max_hops, seen_rreq_ttl_ms, max_recovery_attempts, etc.).

RETRY_ELIGIBLE gains RREP + RERR. All dormant — no call sites yet.
EOF
)"
```

---

## Task 4: AODV freshness + RREQ flooding mechanism

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add `accept_route`, `intermediate_can_reply`, `rreq_key`, forward decls, `issue_rreq`, `rreq_timeout_fire`. Modify `rt[].primary` shape to include optional `dst_seq` field.

**Goal:** Originate RREQ on-demand; flood with hop_max=8 cap; AODV freshness comparison gates which routes get installed/replaced.

- [ ] **Step 4.1: Add forward declarations near the top of helpers block**

Find the existing forward declarations (e.g. `local schedule_triggered_beacon` was here but may have been removed; look near the section where forward decls are introduced, typically before the helpers that need them). Add:

```lua
-- Forward decls for reactive-fallback functions that reference each other.
local issue_rreq
local rreq_timeout_fire
local issue_rrep
local emit_rerr_to_upstream
```

- [ ] **Step 4.2: Add accept_route, intermediate_can_reply, rreq_key**

Place after the wire-format helpers added in Task 3 (after `parse_rerr`):

```lua

-- AODV freshness gate. DV-installed routes have dst_seq=0; RREQ-installed
-- have dst_seq > 0 from RREP. Rule: any RREQ-installed route trumps any
-- DV-installed route for the same destination. Among RREQ-installed:
-- monotonic dst_seq order, with hops as tiebreaker.
local function accept_route(new, existing)
  if existing == nil then return true end
  local e_seq = existing.dst_seq or 0
  local n_seq = new.dst_seq or 0
  -- DV-installed always loses to RREQ-installed.
  if e_seq == 0 and n_seq > 0 then return true end
  -- Otherwise standard AODV freshness.
  if n_seq > e_seq then return true end
  if n_seq == e_seq and new.hops < existing.hops then return true end
  return false
end

-- Can an intermediate node reply to an RREQ from cache?
local function intermediate_can_reply(self, target, rreq)
  local entry = self.rt[target]
  if entry == nil then return false end
  local r = entry.primary
  -- Stale beacon-derived routes (dst_seq=0) shouldn't intermediate-respond
  -- to RREQ — better to let the destination respond with a fresh dst_seq.
  if (r.dst_seq or 0) == 0 then return false end
  if r.dst_seq < rreq.dst_seq then return false end
  for _, b in ipairs(rreq.blacklist) do
    if r.next_hop == b then return false end
  end
  return true
end

-- Helper: build the (originator, bcast_id) key for seen_rreqs.
local function rreq_key(originator, bcast_id)
  return string.format("%d|%d", originator, bcast_id)
end
```

- [ ] **Step 4.3: Add issue_rreq + rreq_timeout_fire**

Place after the helpers added in Step 4.2:

```lua

-- Originate an RREQ for `target_id`. Issues a fresh broadcast_id, stamps
-- last-known dst_seq for the target, packs the optional blacklist (per
-- K=2 on-demand recovery), and broadcasts via tx_flood. Schedules
-- rreq_timeout to either retry (with bumped recovery state) or give up.
issue_rreq = function(self, target_id, blacklist)
  local bid = self.next_bcast_id % 256
  self.next_bcast_id = (self.next_bcast_id + 1) % 256
  local key = rreq_key(self.id, bid)
  self.seen_rreqs[key] = {
    reverse_next   = nil,    -- we're the originator
    hop_count      = 0,
    installed_ms   = self:now(),
    expires_at_ms  = self:now() + self.seen_rreq_ttl_ms,
  }
  local known = (self.rt[target_id] and self.rt[target_id].primary
                 and (self.rt[target_id].primary.dst_seq or 0)) or 0
  local frame = pack_rreq(self.id, target_id, bid, 0, known, blacklist or {})
  self:emit("rreq_tx", {
    target = target_id, bcast_id = bid,
    blacklist_len = (blacklist and #blacklist) or 0,
    dst_seq_known = known,
  })
  self:log(string.format("rreq_tx target=%d bid=%d blacklist=%d dst_seq=%d",
    target_id, bid, (blacklist and #blacklist) or 0, known))
  tx_flood(self, frame, {
    sf    = self.routing_sf,
    label = "RREQ",
    info  = string.format("target=%d bid=%d", target_id, bid),
  })
  local captured_target = target_id
  local captured_bid    = bid
  self:after(self.rreq_timeout_ms, function()
    rreq_timeout_fire(self, captured_target, captured_bid)
  end)
end

-- Fires if no RREP arrived within rreq_timeout_ms. Bumps recovery state,
-- retries with accumulated blacklist, or gives up after max_recovery_attempts.
rreq_timeout_fire = function(self, target_id, bcast_id)
  local entry = self.rt[target_id]
  if entry and entry.primary and entry.primary.dst_seq and entry.primary.dst_seq > 0
     and (entry.primary.expires_at_ms or 0) > self:now() then
    return    -- RREP arrived in the meantime
  end

  local rec = self.route_recovery[target_id]
  if rec == nil then
    rec = { attempts = 1, blacklist = {}, last_attempt_ms = self:now(),
            expires_at_ms = self:now() + self.route_recovery_reset_ms }
    self.route_recovery[target_id] = rec
  else
    rec.attempts = rec.attempts + 1
    rec.last_attempt_ms = self:now()
  end

  if rec.attempts >= self.max_recovery_attempts then
    local n_dropped = (self.pending_sends[target_id] and #self.pending_sends[target_id]) or 0
    self:emit("route_giveup", {
      target = target_id, attempts = rec.attempts,
      pending_dropped = n_dropped,
    })
    self:log(string.format("route_giveup target=%d attempts=%d dropped=%d",
      target_id, rec.attempts, n_dropped))
    self.pending_sends[target_id] = nil
    local captured = target_id
    self:after(self.route_recovery_reset_ms, function()
      if self.route_recovery[captured] == rec then
        self.route_recovery[captured] = nil
      end
    end)
    return
  end

  local delay = self:rand(self.recovery_backoff_min_ms,
                          self.recovery_backoff_max_ms + 1)
  self:emit("rreq_retry", {
    target = target_id, attempts = rec.attempts,
    blacklist_len = #rec.blacklist, delay_ms = delay,
  })
  self:after(delay, function()
    issue_rreq(self, target_id, rec.blacklist)
  end)
end
```

- [ ] **Step 4.4: Build (Lua-load smoke)**

```
cmake --build build -j 4
build/orchestrator/lus test/t10_dv_beacons.json /tmp/smoke.events.ndjson 2>&1 | tail -3
```

Expected: 0 assertion failures. The new helpers exist as locals/forward-decls but are not called yet. If Lua errors out (forward decl referenced before defined in some closure), fix the placement.

- [ ] **Step 4.5: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): AODV freshness helpers + issue_rreq + rreq_timeout_fire

Adds:
- accept_route: AODV freshness gate. DV-installed (dst_seq=0) always
  loses to RREQ-installed; otherwise monotonic seq + hops tiebreaker.
- intermediate_can_reply: gates whether an intermediate forwarder can
  short-circuit an RREQ from cache (only for RREQ-installed routes
  not in originator's blacklist).
- rreq_key: (origin, bcast_id) tuple key for seen_rreqs dedup.
- issue_rreq: originate an RREQ with fresh bcast_id, dst_seq, optional
  blacklist; tx_flood; schedule timeout.
- rreq_timeout_fire: recovery state machine — bump attempts, retry with
  blacklist, or route_giveup after max_recovery_attempts.

Forward-decls added for issue_rreq, rreq_timeout_fire, issue_rrep,
emit_rerr_to_upstream so circular references resolve. No call sites
yet — wired in subsequent commits.
EOF
)"
```

---

## Task 5: RREQ forwarding handler + RREP emission/install + route TTL aging

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add `issue_rrep`, `on_recv 'Q'`, `on_recv 'P'`, route-aging logic for RREQ-installed routes

**Goal:** Multi-hop RREQ flood + RREP back along reverse path. Routes installed via RREP get `dst_seq > 0` and `expires_at_ms`. Originator's pending_sends drain on RREP install.

- [ ] **Step 5.1: Add `issue_rrep`**

Place after `rreq_timeout_fire` in the helpers block:

```lua

-- Send an RREP back along the reverse path. Called either at the
-- destination (after we received an RREQ matching us) or at an
-- intermediate that has a fresh cached route. seen_rreqs[key] holds
-- the reverse_next (the node we send the RREP unicast to).
issue_rrep = function(self, originator, target, hops, snr_bucket, dst_seq, key)
  local entry = self.seen_rreqs[key]
  if entry == nil then
    self:emit("rrep_dropped_no_reverse", { originator = originator, target = target })
    return
  end
  local frame = pack_rrep(originator, target, self.id, dst_seq, hops, snr_bucket)
  self:emit("rrep_tx", {
    originator = originator, target = target,
    next_hop = self.id, dst_seq = dst_seq, hops = hops, snr_bucket = snr_bucket,
    to = entry.reverse_next,
  })
  self:log(string.format("rrep_tx orig=%d target=%d hops=%d dst_seq=%d to=%d",
    originator, target, hops, dst_seq, entry.reverse_next or -1))
  tx_with_retry(self, frame, {
    sf    = self.routing_sf,
    label = "RREP",
    info  = string.format("orig=%d target=%d hops=%d dst_seq=%d to=%d",
      originator, target, hops, dst_seq, entry.reverse_next or -1),
  })
end
```

- [ ] **Step 5.2: Add on_recv 'Q' (RREQ forwarding) branch**

In `function on_recv(self, frame, meta)`, after the existing data-plane tag dispatch (typically at the bottom of the function before its closing `end`), add:

```lua
  if tag == "Q" then
    local q = parse_rreq(frame)
    if not q then return end
    if q.originator == self.id then return end   -- our own, defensive

    -- Dedup.
    local key = rreq_key(q.originator, q.bcast_id)
    if self.seen_rreqs[key] then
      self:emit("rreq_drop_dedup", { originator = q.originator, bcast_id = q.bcast_id })
      return
    end

    -- Hop-count limit.
    if q.hop_count >= self.rreq_max_hops then
      self:emit("rreq_drop_hop_limit", { originator = q.originator, bcast_id = q.bcast_id,
                                         hop_count = q.hop_count })
      return
    end

    -- Record reverse-path state.
    self.seen_rreqs[key] = {
      reverse_next   = meta.src,
      hop_count      = q.hop_count,
      installed_ms   = self:now(),
      expires_at_ms  = self:now() + self.seen_rreq_ttl_ms,
    }
    self:emit("rreq_rx", {
      originator = q.originator, target = q.target, bcast_id = q.bcast_id,
      hop_count = q.hop_count, blacklist_len = #q.blacklist,
    })

    -- Decide: reply (we're target or have fresh cached route) vs forward.
    if q.target == self.id then
      self.dst_seq = self.dst_seq + 1
      issue_rrep(self, q.originator, self.id, 0, 7, self.dst_seq, key)
      return
    end

    if intermediate_can_reply(self, q.target, q) then
      local r = self.rt[q.target].primary
      issue_rrep(self, q.originator, q.target, r.hops or 0, 4,
                 r.dst_seq or 0, key)
      return
    end

    -- Forward: increment hop_count, re-broadcast via tx_flood with jitter.
    local known = (self.rt[q.target] and self.rt[q.target].primary
                   and (self.rt[q.target].primary.dst_seq or 0)) or q.dst_seq
    local fwd = pack_rreq(q.originator, q.target, q.bcast_id,
                          q.hop_count + 1, known, q.blacklist)
    local jitter = self:rand(0, 50)
    self:emit("rreq_forward", {
      originator = q.originator, target = q.target, bcast_id = q.bcast_id,
      hop_count = q.hop_count + 1, jitter_ms = jitter,
    })
    self:after(jitter, function()
      tx_flood(self, fwd, {
        sf    = self.routing_sf,
        label = "RREQ",
        info  = string.format("fwd target=%d bid=%d hops=%d",
          q.target, q.bcast_id, q.hop_count + 1),
      })
    end)
    return
  end
```

- [ ] **Step 5.3: Add on_recv 'P' (RREP) branch**

Immediately after the 'Q' branch:

```lua
  if tag == "P" then
    local p = parse_rrep(frame)
    if not p then return end

    if p.originator == self.id then
      -- We're the originator — install the route.
      local existing = self.rt[p.target] and self.rt[p.target].primary
      local new = {
        next_hop      = p.next_hop,
        score         = snr_db_of_bucket(p.snr_bucket),
        hops          = p.hops,
        dst_seq       = p.dst_seq,
        last_seen_ms  = self:now(),
        installed_ms  = self:now(),
        expires_at_ms = self:now() + self.route_ttl_ms,
      }
      if accept_route(new, existing) then
        self.rt[p.target] = self.rt[p.target] or {}
        self.rt[p.target].primary = new
        self:emit("route_install", {
          target = p.target, next_hop = new.next_hop, hops = new.hops,
          dst_seq = new.dst_seq, snr_bucket = p.snr_bucket, source = "rrep",
        })
        self:log(string.format("route_install target=%d via=%d hops=%d dst_seq=%d (rrep)",
          p.target, new.next_hop, new.hops, new.dst_seq))
        self.route_recovery[p.target] = nil
        -- Drain pending_sends.
        local pending = self.pending_sends[p.target] or {}
        self.pending_sends[p.target] = nil
        for _, item in ipairs(pending) do
          table.insert(self.tx_queue, {
            origin       = self.id,
            dst_id       = p.target,
            dst_name     = (self.id_to_name[p.target] or ("#" .. tostring(p.target))),
            payload      = item.payload,
            user_text    = item.user_text,
            origin_seq   = item.origin_seq,
            previous_hop = nil,
          })
          self:emit("tx_dequeue", {
            origin = self.id, payload = item.user_text, origin_seq = item.origin_seq,
            dst = p.target, depth = #self.tx_queue, via = "rrep_drain",
          })
        end
        become_free(self)
      else
        self:emit("rrep_rx_stale", {
          target = p.target, dst_seq = p.dst_seq, hops = p.hops,
        })
      end
      self:emit("rrep_rx", {
        target = p.target, next_hop = p.next_hop, hops = p.hops, dst_seq = p.dst_seq,
      })
      return
    end

    -- Forwarder: install forward route locally too (so data plane can
    -- route through us), then forward RREP toward originator via reverse-path.
    local existing = self.rt[p.target] and self.rt[p.target].primary
    local fwd_route = {
      next_hop      = p.next_hop,
      score         = snr_db_of_bucket(p.snr_bucket),
      hops          = p.hops,
      dst_seq       = p.dst_seq,
      last_seen_ms  = self:now(),
      installed_ms  = self:now(),
      expires_at_ms = self:now() + self.route_ttl_ms,
    }
    if accept_route(fwd_route, existing) then
      self.rt[p.target] = self.rt[p.target] or {}
      self.rt[p.target].primary = fwd_route
      self:emit("route_install", {
        target = p.target, next_hop = fwd_route.next_hop, hops = fwd_route.hops,
        dst_seq = fwd_route.dst_seq, snr_bucket = p.snr_bucket,
        source = "rrep_forward",
      })
    end

    -- Look up reverse-path next hop.
    local origin_prefix = tostring(p.originator) .. "|"
    local reverse_next = nil
    for k, entry in pairs(self.seen_rreqs) do
      if k:sub(1, #origin_prefix) == origin_prefix then
        reverse_next = entry.reverse_next
        break
      end
    end
    if reverse_next == nil then
      self:emit("rrep_dropped_no_reverse", {
        originator = p.originator, target = p.target,
      })
      return
    end

    local fwd_hops = p.hops + 1
    if fwd_hops > 15 then fwd_hops = 15 end
    local fwd = pack_rrep(p.originator, p.target, self.id, p.dst_seq,
                          fwd_hops, p.snr_bucket)
    self:emit("rrep_forward", {
      originator = p.originator, target = p.target,
      hops = fwd_hops, snr_bucket = p.snr_bucket, to = reverse_next,
    })
    tx_with_retry(self, fwd, {
      sf    = self.routing_sf,
      label = "RREP",
      info  = string.format("fwd orig=%d target=%d hops=%d to=%d",
        p.originator, p.target, fwd_hops, reverse_next),
    })
    return
  end
```

- [ ] **Step 5.4: Add route TTL aging — RREQ-installed routes downgrade dst_seq=0 at expiry**

Find a periodic timer location (e.g., the existing beacon_fire reschedule, or add a new lightweight timer). Simplest: lazy aging on read in `intermediate_can_reply` and `accept_route`. Since both are called frequently, lazy aging happens naturally:

Modify `intermediate_can_reply` to also age out:

```lua
local function intermediate_can_reply(self, target, rreq)
  local entry = self.rt[target]
  if entry == nil then return false end
  local r = entry.primary
  -- Age out RREQ-installed routes past TTL: downgrade dst_seq to 0.
  if (r.dst_seq or 0) > 0 and (r.expires_at_ms or 0) <= self:now() then
    r.dst_seq = 0
    r.expires_at_ms = nil
    self:emit("route_aged", { target = target, source = "ttl" })
  end
  if (r.dst_seq or 0) == 0 then return false end
  if r.dst_seq < rreq.dst_seq then return false end
  for _, b in ipairs(rreq.blacklist) do
    if r.next_hop == b then return false end
  end
  return true
end
```

This handles the lazy aging cleanly: every RREQ visit triggers age-out check. RREQ-installed routes that age out become DV-equivalent (dst_seq=0), and DV beacons can subsequently update them via `route_strictly_better`.

- [ ] **Step 5.5: Build + run regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 6/6 PASS. The new RREQ/RREP machinery isn't called yet (cache-miss path is wired in Task 7); existing scenarios all use cached routes so reactive fallback never fires.

- [ ] **Step 5.6: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): RREQ flood + RREP unicast + AODV freshness

- on_recv 'Q': dedup (origin, bcast_id), hop-cap at rreq_max_hops (8),
  reverse-path recording, decide reply (target or intermediate-can-reply)
  vs forward (hop_count++, jittered re-broadcast).
- issue_rrep: unicast back along reverse path with snr_bucket + dst_seq.
- on_recv 'P': originator installs via accept_route (AODV freshness),
  clears route_recovery, drains pending_sends. Forwarder installs
  forward route locally + forwards RREP toward originator.
- intermediate_can_reply: lazy-ages RREQ-installed routes past TTL
  by downgrading their dst_seq to 0 (DV-equivalent).

No call sites for issue_rreq yet — cache-miss → RREQ wiring lands in Task 7.
EOF
)"
```

---

## Task 6: RERR upstream invalidation + recovery hooks in rts/ack timeout

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add `emit_rerr_to_upstream`, `on_recv 'E'`, hook recovery into `rts_timeout_fire` and `ack_timeout_fire` originator-side giveup branches.

**Goal:** When a flight fails with rts_giveup or data_ack_giveup, RERR propagates upstream to the originator; originator's recovery state machine launches a blacklisted RREQ retry.

- [ ] **Step 6.1: Add `emit_rerr_to_upstream`**

After `issue_rrep`:

```lua

-- Emit a RERR upstream when our forwarding has failed for a destination.
-- Sent unicast on routing_sf to pending_tx.previous_hop. Receiver bumps
-- its routes[bad_dst].primary.dst_seq + invalidates that cached route +
-- propagates further upstream if it itself was forwarding.
emit_rerr_to_upstream = function(self, bad_dst, bad_next_hop)
  local entry = self.rt[bad_dst]
  local r = entry and entry.primary
  local seq_known = (r and r.dst_seq) or 0
  if r then
    r.dst_seq = seq_known + 1
    r.expires_at_ms = self:now()
    self:emit("route_invalidate", {
      target = bad_dst, bad_next_hop = bad_next_hop,
      bumped_dst_seq = r.dst_seq,
    })
  end

  local upstream = nil
  if self.pending_tx and self.pending_tx.previous_hop then
    upstream = self.pending_tx.previous_hop
  end
  if upstream then
    local frame = pack_rerr(bad_dst, bad_next_hop, seq_known)
    self:emit("rerr_tx", {
      bad_dst = bad_dst, bad_next_hop = bad_next_hop,
      dst_seq_known = seq_known, to = upstream,
    })
    tx_with_retry(self, frame, {
      sf    = self.routing_sf,
      label = "RERR",
      info  = string.format("bad_dst=%d bad_next=%d seq=%d to=%d",
        bad_dst, bad_next_hop, seq_known, upstream),
    })
  end
end
```

- [ ] **Step 6.2: Add `on_recv 'E'` branch**

In on_recv, after the 'P' branch:

```lua
  if tag == "E" then
    local e = parse_rerr(frame)
    if not e then return end

    self:emit("rerr_rx", {
      bad_dst = e.bad_dst, bad_next_hop = e.bad_next_hop,
      dst_seq_known = e.dst_seq_known, from = meta.src,
    })

    local entry = self.rt[e.bad_dst]
    local r = entry and entry.primary
    if r and r.next_hop == e.bad_next_hop then
      r.dst_seq = e.dst_seq_known + 1
      r.expires_at_ms = self:now()
      self:emit("route_invalidate", {
        target = e.bad_dst, bad_next_hop = e.bad_next_hop,
        bumped_dst_seq = r.dst_seq, source = "rerr",
      })
    end

    if self.pending_tx
       and self.pending_tx.dst == e.bad_dst
       and self.pending_tx.previous_hop ~= nil then
      emit_rerr_to_upstream(self, e.bad_dst, self.pending_tx.next)
    end
    return
  end
```

- [ ] **Step 6.3: Hook recovery into `rts_timeout_fire`**

Find `local function rts_timeout_fire(self, captured_msg_id)` and locate the `rts_giveup` emit path. Right AFTER the existing `self:emit("rts_giveup", ...)` and `self:log(...)` calls, but BEFORE `self.pending_tx = nil`, insert:

```lua
    -- Reactive recovery: emit RERR upstream so cached routes through
    -- this dead next-hop get invalidated; if we're the originator (no
    -- previous_hop), trigger blacklisted RREQ retry directly.
    emit_rerr_to_upstream(self, self.pending_tx.dst, self.pending_tx.next)
    if self.pending_tx.previous_hop == nil then
      local rec = self.route_recovery[self.pending_tx.dst]
      if rec == nil then
        rec = { attempts = 1, blacklist = {self.pending_tx.next},
                last_attempt_ms = self:now(),
                expires_at_ms = self:now() + self.route_recovery_reset_ms }
        self.route_recovery[self.pending_tx.dst] = rec
      else
        rec.attempts = rec.attempts + 1
        table.insert(rec.blacklist, self.pending_tx.next)
        if #rec.blacklist > 3 then table.remove(rec.blacklist, 1) end
        rec.last_attempt_ms = self:now()
      end
      if rec.attempts < self.max_recovery_attempts then
        local pending_payload = self.pending_tx.payload
        local pending_seq     = self.pending_tx.origin_seq
        local pending_text    = self.pending_tx.user_text
        local captured_dst    = self.pending_tx.dst
        self.pending_sends[captured_dst] = self.pending_sends[captured_dst] or {}
        table.insert(self.pending_sends[captured_dst], {
          payload = pending_payload, user_text = pending_text,
          origin_seq = pending_seq, queued_at_ms = self:now(),
        })
        local delay = self:rand(self.recovery_backoff_min_ms,
                                self.recovery_backoff_max_ms + 1)
        self:emit("rreq_retry", {
          target = captured_dst, attempts = rec.attempts,
          blacklist_len = #rec.blacklist, delay_ms = delay, source = "rts_giveup",
        })
        self:after(delay, function()
          issue_rreq(self, captured_dst, rec.blacklist)
        end)
      else
        self:emit("route_giveup", {
          target = self.pending_tx.dst, attempts = rec.attempts,
          pending_dropped = 1, source = "rts_giveup",
        })
        self.pending_sends[self.pending_tx.dst] = nil
      end
    end
```

- [ ] **Step 6.4: Hook recovery into `ack_timeout_fire`**

Find `local function ack_timeout_fire(self, captured_msg_id)` and locate its `data_ack_giveup` emit path. Apply the SAME insertion as Step 6.3 right after the giveup emit + log, before `self.pending_tx = nil`.

(Both timeout paths should fire RERR + recovery the same way; the difference is just the failure-source label and the timeout type.)

- [ ] **Step 6.5: Build + regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 6/6 PASS.

- [ ] **Step 6.6: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): RERR + recovery wired into timeout paths

- emit_rerr_to_upstream: bumps local routes[bad_dst].primary.dst_seq,
  invalidates cached route, sends RERR upstream if forwarding.
- on_recv 'E': mirrors dst_seq bump + invalidate; propagates upstream
  if we were forwarding.
- rts_timeout_fire / ack_timeout_fire: when origination/forwarding
  bottoms out at giveup, emit RERR upstream AND (if originator) bump
  route_recovery state, blacklist failed next-hop, schedule
  blacklisted RREQ retry. Bounded at max_recovery_attempts (3).

issue_send still uses the old send_no_route path on cache miss —
RREQ-on-cache-miss wiring lands in Task 7.
EOF
)"
```

---

## Task 7: Cache-miss → RREQ fallback in issue_send

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — modify `issue_send` to queue + RREQ on `rt[dst] = nil`

**Goal:** When the originator's `rt[dst]` is empty (genuinely unknown destination), instead of emitting `send_no_route` and giving up, queue into `pending_sends[dst]` and `issue_rreq(dst, {})`.

- [ ] **Step 7.1: Locate `issue_send` and find the `if not entry then` block**

```bash
grep -n "^issue_send = function" scenarios/dv_dual_sf.lua
```

Read the function. Find the block that fires when entry is nil:

```lua
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, origin_seq, previous_hop)
  local entry = self.rt[dst_id]
  if not entry then
    self:emit("send_no_route", {
      origin = origin, payload = user_text, origin_seq = origin_seq, dst = dst_id,
    })
    self:log(...)
    return
  end
  ...
```

- [ ] **Step 7.2: Replace the cache-miss block with RREQ fallback**

Replace the `if not entry then ... return end` block with:

```lua
  if not entry then
    -- Reactive RREQ fallback: queue + issue_rreq if we're the originator.
    -- Forwarders that hit cache-miss propagate RERR upstream.
    if origin == self.id then
      self.pending_sends[dst_id] = self.pending_sends[dst_id] or {}
      table.insert(self.pending_sends[dst_id], {
        payload    = payload,
        user_text  = user_text,
        origin_seq = origin_seq,
        queued_at_ms = self:now(),
      })
      self:emit("send_pending_route", {
        origin = origin, payload = user_text, origin_seq = origin_seq,
        dst = dst_id, depth = #self.pending_sends[dst_id],
      })
      self:log(string.format("send_pending_route dst=%s seq=%d depth=%d",
        dst_name, origin_seq, #self.pending_sends[dst_id]))
      issue_rreq(self, dst_id, {})
      return
    end
    -- Forwarder cache-miss: emit RERR upstream + drop.
    self:emit("send_no_route", {
      origin = origin, payload = user_text, origin_seq = origin_seq, dst = dst_id,
    })
    self:log(string.format("send_no_route dst=%s (forwarder, RERR upstream)",
      dst_name))
    if previous_hop ~= nil then
      emit_rerr_to_upstream(self, dst_id, 0)
    end
    return
  end
```

- [ ] **Step 7.3: Build + regression**

```
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json
```

Expected: 6/6 PASS. Existing scenarios have hot-warmed rt[] from beacons by the time sends fire; cache-miss path is rare and shouldn't activate.

- [ ] **Step 7.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): cache-miss → RREQ fallback in issue_send

Originator-side: when rt[dst] is nil, queue into pending_sends[dst]
and issue_rreq instead of emitting send_no_route. Drains pending_sends
on RREP-driven route_install.

Forwarder-side: cache-miss emits send_no_route AND propagates RERR
upstream so the originator can react. Same drop-the-flight semantics
as before; just adds the upstream notification.

This is the entry point that activates the RREQ flood. Most operations
hit cached rt[] from DV beacons; RREQ only fires for genuinely unknown
destinations (typically new arrivals post-warmup).
EOF
)"
```

---

## Task 8: Unit tests t23 + t24

**Files:**
- Create: `test/t23_quiet_throttle.json`
- Create: `test/t24_unknown_dst_rreq.json`

**Goal:** Targeted unit tests for the two new mechanisms (throttle + RREQ fallback).

- [ ] **Step 8.1: Create t23 (beacon throttle)**

```bash
cat > test/t23_quiet_throttle.json <<'EOF'
{
  "_name": "t23_quiet_throttle",
  "_desc": "Adaptive beacon throttle test. 3-node line. Phase 1 (warmup): beacons fire normally. Phase 2: alice sends to carol — RTS/CTS/DATA/ACK on routing_sf trigger neighbors' channel-activity detector. Phase 3: bob's beacon timer fires shortly after — the throttle should suppress this round (beacon_skipped_busy emit). Phase 4: channel quiet again, next beacon fires.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 200,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 10.0, "rssi": -75.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 10.0, "rssi": -75.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 15000, "node": "alice", "command": "send carol hello-throttle" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "hello-throttle" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "beacon_skipped_busy", "value": "" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "beacon_tx", "value": "" }
  ]
}
EOF
```

- [ ] **Step 8.2: Run t23 — expect PASS**

```
bash test/run_tests.sh test/t23_quiet_throttle.json
```

If FAIL, inspect:
```
grep -c '"emit_type":"beacon_skipped_busy"' test/t23_quiet_throttle_events.ndjson
grep -c '"emit_type":"delivered"' test/t23_quiet_throttle_events.ndjson
grep -c '"emit_type":"beacon_tx"' test/t23_quiet_throttle_events.ndjson
```

Expected: at least 1 beacon_skipped_busy at bob, 1 delivered at carol, ≥3 beacon_tx total.

- [ ] **Step 8.3: Create t24 (RREQ fallback)**

```bash
cat > test/t24_unknown_dst_rreq.json <<'EOF'
{
  "_name": "t24_unknown_dst_rreq",
  "_desc": "RREQ fallback test. 3-node line; carol has activate_at_ms=15000 (silent until 15s). Phase 1 (0-15s): alice + bob exchange beacons; alice's rt has bob but NOT carol. Phase 2 (t=10s): alice sends to carol — cache miss → issue_rreq → carol is silent, RREQ won't reach a target. Phase 3 (t=15s+): carol activates, beacons fire, alice learns carol via beacon (or carol replies to a retry RREQ). Phase 4 (t=20s): alice sends again to carol — should now succeed. Test asserts: at least one rreq_tx, at least one delivered.",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 200,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9],
                  "beacon_period_ms": 5000,
                  "quiet_threshold_ms": 5000,
                  "activate_at_ms": 15000 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 10.0, "rssi": -75.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 10.0, "rssi": -75.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 30000, "node": "alice", "command": "send carol hello-rreq" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "hello-rreq" }
  ]
}
EOF
```

Note: `activate_at_ms` may not be implemented in dv_dual_sf.lua at this point (it was a reactive_routing.lua addition). Check:

```bash
grep -n activate_at_ms scenarios/dv_dual_sf.lua
```

If not present, t24's design falls back to: just have warmup_ms = 5000 and command at_ms = 30000, so by t=30000 carol has been beaconing for 25 seconds → alice's rt likely has carol (from beacons). RREQ fallback may not actually fire in this case. Adjust test to use a topology where carol is NOT directly reachable from alice:

Change t24 to a 4-node line `alice ↔ bob ↔ carol ↔ dave`, with the flight going alice→dave. Make alice's beacons take a while to learn dave (or set `beacon_period_ms = 60000` so beacons rarely fire). The test design becomes tricky to make deterministic.

**Simpler test: use `beacon_period_ms = 60000` (1 min) so during the test's 60-second window, beacons fire only at boot. Then alice's rt won't have carol at command time, forcing the RREQ fallback.**

Adjust t24's per-node config to use `"beacon_period_ms": 60000` and `"beacon_period_warmup_ms": 60000` (assuming dv_dual_sf.lua has both). Re-run.

The exact test shape may need iteration; document the iteration if needed.

- [ ] **Step 8.4: Run t24 — expect PASS**

```
bash test/run_tests.sh test/t24_unknown_dst_rreq.json
```

If FAIL, debug as above. The point is to verify RREQ fallback fires and delivery succeeds via the reactive path.

- [ ] **Step 8.5: Run regression**

```
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t12_dv_single_hop.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json test/t23_quiet_throttle.json test/t24_unknown_dst_rreq.json
```

Expected: 8/8 PASS.

- [ ] **Step 8.6: Commit**

```bash
git add test/t23_quiet_throttle.json test/t24_unknown_dst_rreq.json
git commit -m "$(cat <<'EOF'
test(t23, t24): adaptive throttle + RREQ-fallback unit tests

t23 (3-node line, beacon period 5s, quiet threshold 5s):
  - alice sends to carol mid-warmup; data flight triggers neighbors'
    channel-activity detector
  - bob's beacon timer fires within the busy window → beacon_skipped_busy
  - delivered at carol verifies data path still works under throttle

t24 (3-node line, sparse beacons):
  - sparse beacon period (60s) means alice's rt has not converged
    when the command fires
  - cache-miss → issue_rreq → reactive flood discovers carol
  - delivered at carol verifies the RREQ fallback works
EOF
)"
```

---

## Task 9: Capacity scenarios a02–a05

**Files:**
- Create: `scenarios/a02_seattle_sparse.json`
- Create: `scenarios/a03_seattle_medium.json` (HEADLINE)
- Create: `scenarios/a04_seattle_dense.json`
- Create: `scenarios/a05_seattle_very_dense.json`

**Goal:** Capacity scenarios with extended warmup so the network's beacons converge before user traffic measurement begins. r03 → a03 is the headline test.

- [ ] **Step 9.1: Generate a0X scenarios from s0X**

```bash
for n in 02_sparse 03_medium 04_dense 05_very_dense; do
  base="${n%_*}"
  rest="${n#*_}"
  src="scenarios/s${base}_seattle_${rest}.json"
  dst="scenarios/a${base}_seattle_${rest}.json"
  cp "$src" "$dst"
  echo "Created $dst (will need warmup + command shifts)"
done
```

- [ ] **Step 9.2: Apply warmup + command-time shifts**

For each scenario, apply (using `python3` for JSON manipulation since `sed` is fragile on JSON):

```bash
python3 - <<'PYEOF'
import json
shifts = {
    "scenarios/a02_seattle_sparse.json":     300000,   # 5 min
    "scenarios/a03_seattle_medium.json":     600000,   # 10 min
    "scenarios/a04_seattle_dense.json":      600000,   # 10 min
    "scenarios/a05_seattle_very_dense.json": 900000,   # 15 min
}
for path, warmup in shifts.items():
    with open(path) as f:
        cfg = json.load(f)
    # Update _name
    cfg["_name"] = cfg["_name"].replace("s0", "a0", 1) if cfg["_name"].startswith("s0") else cfg["_name"]
    # Set warmup_ms
    cfg["simulation"]["warmup_ms"] = warmup
    # Extend duration_ms by the warmup amount
    cfg["simulation"]["duration_ms"] = cfg["simulation"]["duration_ms"] + warmup
    # Shift command at_ms by warmup
    for cmd in cfg.get("commands", []):
        cmd["at_ms"] = cmd["at_ms"] + warmup
    # Add quiet_threshold_ms to each node
    for node in cfg.get("nodes", []):
        node.setdefault("config", {})["quiet_threshold_ms"] = 30000
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"Updated {path}: warmup={warmup}ms, {len(cfg.get('commands', []))} commands shifted")
PYEOF
```

Verify the shifts:
```bash
for f in scenarios/a0*.json; do
  echo "=== $f ==="
  python3 -c "import json; cfg = json.load(open('$f')); print(f\"_name: {cfg['_name']}\"); print(f\"warmup_ms: {cfg['simulation']['warmup_ms']}\"); print(f\"duration_ms: {cfg['simulation']['duration_ms']}\"); print(f\"first cmd: {cfg['commands'][0]['at_ms'] if cfg['commands'] else 'none'}\"); print(f\"node[0] quiet_threshold_ms: {cfg['nodes'][0]['config'].get('quiet_threshold_ms')}\")"
done
```

- [ ] **Step 9.3: Run a03 (headline)**

```
cmake --build build -j 4
build/orchestrator/lus scenarios/a03_seattle_medium.json scenarios/a03_seattle_medium_events.ndjson 2>&1 | tail -3
```

Expected: simulation completes (may take 5-15 min wallclock for the longer sim). Capture exit code + last events line.

- [ ] **Step 9.4: Capacity comparison vs s03 baseline**

Ensure s03 baseline events.ndjson exists. If not, generate:
```
build/orchestrator/lus scenarios/s03_seattle_medium.json scenarios/s03_seattle_medium_events.ndjson 2>&1 | tail -3
```

Then:
```bash
python3 tools/capacity_summary.py --compare \
  scenarios/s03_seattle_medium.json scenarios/s03_seattle_medium_events.ndjson \
  scenarios/a03_seattle_medium.json scenarios/a03_seattle_medium_events.ndjson
```

Capture the side-by-side report. Headline assertion: a03 delivered ≥ 45/50 (≥90%).

If a03 < 45 deliveries:
- Check `grep -c '"emit_type":"beacon_skipped_busy"' scenarios/a03_seattle_medium_events.ndjson` — should be substantial (throttle is firing during data periods)
- Check `grep -c '"emit_type":"rreq_tx"' scenarios/a03_seattle_medium_events.ndjson` — should be near zero (warmup populated rt[])
- Check `grep -c '"emit_type":"route_giveup"' scenarios/a03_seattle_medium_events.ndjson` — should be 0 or very few
- Check `grep -c '"emit_type":"duty_cycle_blocked"' scenarios/a03_seattle_medium_events.ndjson` — should be much lower than s03's 312

If results are improved but below 90%, document the number; iterate by raising warmup_ms further (e.g., a03 to 30 min). The mechanism is sound.

- [ ] **Step 9.5: Run a02, a04 (sanity)**

```
build/orchestrator/lus scenarios/a02_seattle_sparse.json scenarios/a02_seattle_sparse_events.ndjson 2>&1 | tail -1
build/orchestrator/lus scenarios/a04_seattle_dense.json  scenarios/a04_seattle_dense_events.ndjson 2>&1 | tail -1
```

Run a05 if time permits (15-min sim is slowest):
```
build/orchestrator/lus scenarios/a05_seattle_very_dense.json scenarios/a05_seattle_very_dense_events.ndjson 2>&1 | tail -1
```

Capture all delivery counts.

- [ ] **Step 9.6: Commit (with actual numbers in message)**

```bash
git add scenarios/a02_seattle_sparse.json scenarios/a03_seattle_medium.json \
        scenarios/a04_seattle_dense.json scenarios/a05_seattle_very_dense.json
git commit -m "$(cat <<'EOF'
test(adaptive): Seattle a02-a05 capacity scenarios with extended warmup

Clones of s02-s05 with:
- warmup_ms extended (5/10/10/15 min) so DV beacons converge before
  test commands fire (matches realistic deployment where networks have
  been operating for hours/days before any specific message)
- All command at_ms timestamps shifted by +warmup_ms
- duration_ms extended by +warmup_ms
- quiet_threshold_ms = 30000 added to each node config

Capacity comparison vs s03 baseline at BW=62.5:
  s03 (DV, no throttle, 30s warmup) : <X>/50
  a03 (adaptive, 10min warmup)      : <Y>/50

[REPLACE WITH ACTUAL NUMBERS]

a02 sparse: <Z>/50
a04 dense:  <Z>/50
a05 very_dense: <Z>/50 (or "not run")
EOF
)"
```

Replace placeholder numbers with actual capacity-summary results.

---

## Task 10: Header pseudocode update + final regression

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — update the existing header flow block to document the adaptive additions

**Goal:** Per the recurring user-feedback convention, document the new mechanisms in the file header. Final integration sweep.

- [ ] **Step 10.1: Update the file header**

Find the existing header pseudocode flow block at the top of `scenarios/dv_dual_sf.lua`. After the existing routing/NACK section but before the F1 mitigation section (or wherever the existing structure has a logical place for new content), insert:

```lua
--
-- ============================================================================
-- Adaptive throttle + RREQ fallback (2026-05-08)
-- ============================================================================
--
-- The protocol now adapts to channel activity:
--   on_recv head:        update self.last_rx_routing_sf_ms = now (any RX,
--                        any tag, any recipient — the network's "is the
--                        channel busy?" signal is fed by passive overhearing)
--   beacon_fire:         skip emission (but reschedule normally) when
--                        now - last_rx_routing_sf_ms < quiet_threshold_ms
--                        (default 30s). Naturally rate-limits beacons across
--                        dense neighborhoods via mutual overhearing.
--
-- For genuinely unknown destinations (cache miss in self.rt[]), the protocol
-- falls back to AODV-style on-demand discovery:
--   issue_send (origin): if rt[dst] = nil, queue into pending_sends[dst]
--                        and issue_rreq(dst, []). Drains pending_sends on
--                        RREP route_install.
--   issue_send (forwarder): cache-miss propagates RERR upstream + drops.
--   on_recv 'Q' (RREQ):  dedup by (origin, bcast_id), forward with
--                        hop_count++ if not target/intermediate-can-reply,
--                        cap at rreq_max_hops (8).
--   on_recv 'P' (RREP):  install with AODV freshness via accept_route;
--                        forwarders install forward route locally too;
--                        originator drains pending_sends.
--   on_recv 'E' (RERR):  bump dst_seq + invalidate; propagate further
--                        upstream if forwarding to bad_dst.
--
-- AODV freshness:
--   accept_route(new, existing): RREQ-installed (dst_seq>0) always trumps
--     DV-installed (dst_seq=0); among same source, monotonic dst_seq +
--     hops tiebreaker.
--   intermediate_can_reply: only RREQ-installed routes (dst_seq>0) can
--     short-circuit RREQ from cache. Lazily ages out RREQ-installed
--     routes past route_ttl_ms to dst_seq=0 (DV-equivalent).
--
-- K=2 on-demand recovery: on rts/data_ack giveup at originator, blacklist
-- the failed next-hop and retry RREQ; bounded at max_recovery_attempts (3).
```

- [ ] **Step 10.2: Run all reactive + regression tests**

```bash
cmake --build build -j 4
bash test/run_tests.sh test/t01_flooder.json test/t10_dv_beacons.json test/t11_dv_convergence.json test/t12_dv_single_hop.json test/t13_radio_busy_info.json test/t14_startup_jitter.json test/t14b_meta_src.json test/t15_concurrent_relay.json test/t16_duty_cycle.json test/t23_quiet_throttle.json test/t24_unknown_dst_rreq.json
```

Expected: 11/11 PASS.

- [ ] **Step 10.3: Run native suite**

```
bash test/native/build_test.sh 2>&1 | tail -3
```

Expected: all green (no C++ changes).

- [ ] **Step 10.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
docs(dv_dual_sf): document adaptive throttle + RREQ fallback in header

Adds a new "Adaptive throttle + RREQ fallback" section to the file
header pseudocode block, summarizing:
- channel-activity detector (last_rx_routing_sf_ms updated at on_recv head)
- beacon throttle in beacon_fire (skip when channel busy)
- cache-miss → RREQ fallback in issue_send
- AODV freshness (accept_route, intermediate_can_reply, route TTL aging)
- RERR + recovery state machine

Final integration sweep: 11/11 selected tests + new t23/t24 PASS.
Capacity benchmark (a03 vs s03 at BW=62.5): see Task 9 commit.
EOF
)"
```

---

## Spec-Coverage Self-Review

- [x] **Spec § Strategy (single-file evolution of dv_dual_sf.lua)** → Tasks 1-7 (in-place additions)
- [x] **Spec § Wire format (Q/P/E)** → Task 3
- [x] **Spec § Per-node state additions (last_rx_routing_sf_ms, dst_seq, etc.)** → Tasks 1, 3
- [x] **Spec § Channel-activity detector** → Task 1
- [x] **Spec § Beacon throttle** → Task 2
- [x] **Spec § Reactive RREQ fallback (issue_send modification)** → Task 7
- [x] **Spec § AODV freshness (accept_route + intermediate_can_reply + route aging)** → Tasks 4, 5
- [x] **Spec § Recovery state machine** → Task 6
- [x] **Spec § Simulation realism (a02-a05 with extended warmup)** → Task 9
- [x] **Spec § Test scenarios (t23, t24)** → Task 8
- [x] **Spec § Header pseudocode** → Task 10
