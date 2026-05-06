# s01_dv_dual_sf Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `dv_dual_sf` Lua protocol and the `s01_dv_dual_sf` scenario specified in `docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md`.

**Architecture:** One Lua script (`scenarios/dv_dual_sf.lua`) implements distance-vector beacons on routing_sf and per-hop dual-SF data delivery via RTS/CTS/DATA on data_sf. The end-to-end scenario `scenarios/s01_dv_dual_sf.json` is a 4-node line that exercises dynamic SF retune (R.1.8), single-SF default (R.1.7), path-loss + lat/lon (R.2), and `sim:link_snr` cooperatively. Intermediate `t10`–`t12` regression tests validate sub-behaviours (beacons, DV merge, single-hop dance) so failures in `s01` can be triaged quickly.

**Tech Stack:** Lua 5.4 (sol2 bindings), no new C++ dependencies. The runner is the existing `bash test/run_tests.sh`; one shell-script edit lets it pick up `scenarios/s*.json`.

---

## File Structure

To create:
- `scenarios/dv_dual_sf.lua` — protocol script (~200 lines, grows incrementally across tasks)
- `scenarios/s01_dv_dual_sf.json` — full 4-node scenario
- `test/t10_dv_beacons.json` — 2-node beacon transmission/reception (Task 2 verification)
- `test/t11_dv_convergence.json` — 4-node DV convergence (Task 3 verification)
- `test/t12_dv_single_hop.json` — 2-node end-to-end dual-SF dance (Task 4 verification)

To modify:
- `test/run_tests.sh` — extend the glob to include `scenarios/s*.json` (Task 6)

The Lua script is built up incrementally. Each task adds one chunk of protocol behaviour, gated by a focused intermediate test. The final scenario `s01` is added in Task 5 and exercises everything together.

---

## Conventions used throughout this plan

- All shell commands assume cwd `/home/staszek/lora-universal-simulator`. The test runner script is at `test/run_tests.sh`.
- The build target is `lus` at `build/orchestrator/lus`. Rebuild after each task even though no C++ changes — keeps the workflow muscle-memory consistent. Build command: `cmake --build build -j`.
- Run a single test: `bash test/run_tests.sh test/<name>.json`. Run all: `bash test/run_tests.sh`.
- Node ids are 0-indexed: `alice=0, bob=1, charlie=2, dave=3`.
- The simulator does not deliver a packet to its own sender. The script does not have to filter self-RX.

---

## Task 1: Skeleton script + wire format helpers

**Files:**
- Create: `scenarios/dv_dual_sf.lua`
- Create: `scenarios/s01_dv_dual_sf.json` (skeleton, no commands, no expects yet)

The script gets its callback shells, configuration parsing, name→id resolution from `sim:nodes()`, and the four pack/parse helpers. The skeleton scenario lets us run `lus` end-to-end and confirm nothing crashes; the helpers will be exercised the moment beacons go on air in Task 2.

- [ ] **Step 1: Create `scenarios/dv_dual_sf.lua` with the skeleton**

```lua
-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.

-- ---------- wire format helpers (private to this file) ----------------------

local function pack_beacon(node)
  local entries = {}
  for dest_id, e in pairs(node.rt) do
    table.insert(entries, { dest = dest_id, next = e.next_hop, score = e.score, hops = e.hops })
  end
  local out = "B" .. string.char(node.id) .. string.char(#entries)
  for _, e in ipairs(entries) do
    local s = math.floor(e.score + 0.5)
    if s < -128 then s = -128 end
    if s >  127 then s =  127 end
    if s < 0 then s = s + 256 end  -- two's-complement byte
    out = out .. string.char(e.dest) .. string.char(e.next) .. string.char(s) .. string.char(e.hops)
  end
  return out
end

local function parse_beacon(frame)
  if #frame < 3 or frame:sub(1,1) ~= "B" then return nil end
  local src = frame:byte(2)
  local n   = frame:byte(3)
  if #frame < 3 + 4*n then return nil end
  local entries = {}
  local pos = 4
  for _ = 1, n do
    local dest = frame:byte(pos)
    local nxt  = frame:byte(pos + 1)
    local sb   = frame:byte(pos + 2)
    local score = (sb >= 128) and (sb - 256) or sb
    local hops = frame:byte(pos + 3)
    table.insert(entries, { dest = dest, next = nxt, score = score, hops = hops })
    pos = pos + 4
  end
  return { src = src, entries = entries }
end

local function pack_rts(origin, src, dst, next_hop, msg_id, data_sf)
  return "R" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. string.char(data_sf)
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  return {
    origin  = frame:byte(2),
    src     = frame:byte(3),
    dst     = frame:byte(4),
    next    = frame:byte(5),
    msg_id  = frame:byte(6) + frame:byte(7) * 256,
    data_sf = frame:byte(8),
  }
end

local function pack_cts(src, msg_id)
  return "C" .. string.char(src)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
end

local function parse_cts(frame)
  if #frame < 4 or frame:sub(1,1) ~= "C" then return nil end
  return {
    src    = frame:byte(2),
    msg_id = frame:byte(3) + frame:byte(4) * 256,
  }
end

local function pack_data(origin, src, dst, next_hop, msg_id, payload)
  return "D" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. payload
end

local function parse_data(frame)
  if #frame < 7 or frame:sub(1,1) ~= "D" then return nil end
  return {
    origin  = frame:byte(2),
    src     = frame:byte(3),
    dst     = frame:byte(4),
    next    = frame:byte(5),
    msg_id  = frame:byte(6) + frame:byte(7) * 256,
    payload = frame:sub(8),
  }
end

-- ---------- script lifecycle ------------------------------------------------

function on_init(self, config)
  self.routing_sf      = config.routing_sf      or 7
  self.data_sf         = config.data_sf         or 12
  self.beacon_period_ms = config.beacon_period_ms or 5000

  self.rt              = {}     -- rt[dest_id] = { next_hop, score, hops, last_seen_ms }
  self.next_msg_id     = 1
  self.pending_tx      = nil    -- in-flight outbound user message (set in Task 4)
  self.pending_rx      = nil    -- accepted-RTS context awaiting DATA (set in Task 4)
  self.rt_full_emitted = false

  -- Build name_to_id and peer_count from sim:nodes().
  self.name_to_id = {}
  self.id_to_name = {}
  local nodes = sim:nodes()
  for _, n in ipairs(nodes) do
    self.name_to_id[n.name] = n.id
    self.id_to_name[n.id]   = n.name
  end
  self.peer_count = #nodes - 1
end

function on_recv(self, frame, meta)
  -- Filled in across Tasks 2-5.
end

function on_command(self, cmd_str)
  -- Filled in in Task 4.
  return "ERROR: protocol not yet wired"
end
```

- [ ] **Step 2: Create `scenarios/s01_dv_dual_sf.json` skeleton**

```json
{
  "_name": "s01_dv_dual_sf",
  "_desc": "Distance-vector routing on SF7; data on SF12 via per-hop dual-SF dance. 4-node line, deterministic path-loss. Skeleton — protocol fills in across Tasks 2-5.",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 0.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 14.0
    }
  },
  "nodes": [
    { "name": "alice",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.3900, "lon": 2.1600 },
    { "name": "bob",     "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4035, "lon": 2.1600 },
    { "name": "charlie", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4170, "lon": 2.1600 },
    { "name": "dave",    "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4305, "lon": 2.1600 }
  ],
  "topology": { "links": [] },
  "commands": [],
  "expect": []
}
```

- [ ] **Step 3: Build and run the skeleton**

```bash
cmake --build build -j
./build/orchestrator/lus scenarios/s01_dv_dual_sf.json scenarios/s01_dv_dual_sf_events.ndjson
```

Expected: command exits 0. The events file contains `sim_start`, `node_ready` × 4, `sim_end` markers — no `lua_error` events, no protocol traffic yet (script is empty).

- [ ] **Step 4: Spot-check the events file**

```bash
grep -E '"type":"(sim_start|node_ready|sim_end|lua_error)"' scenarios/s01_dv_dual_sf_events.ndjson | head -20
```

Expected output: 1 sim_start, 4 node_ready, 1 sim_end. Zero lua_error lines.

- [ ] **Step 5: Commit**

```bash
git add scenarios/dv_dual_sf.lua scenarios/s01_dv_dual_sf.json
git commit -m "feat(scenarios): dv_dual_sf skeleton — wire format helpers and lifecycle stubs"
```

---

## Task 2: Beacons (transmit + receive direct entries)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add beacon scheduling, beacon TX, beacon RX with direct-entry update only (no DV merge yet)
- Create: `test/t10_dv_beacons.json`

Beacons are scheduled with an `id * 100 ms` initial offset and re-armed via `self:after`. On reception of a beacon, the script records the sender as a 1-hop neighbour. Indirect entries (DV merge) are deferred to Task 3.

- [ ] **Step 1: Write the failing test `test/t10_dv_beacons.json`**

```json
{
  "_name": "t10_dv_beacons",
  "_desc": "Two adjacent nodes; beacons go out on routing SF and direct-entry rt updates fire on reception. Validates pack/parse helpers + scheduling.",
  "simulation": {
    "duration_ms": 12000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 5.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [],
  "expect": [
    { "type": "event_count_min", "event_type": "script_emit", "node": "alice", "min": 2 },
    { "type": "event_count_min", "event_type": "script_emit", "node": "bob",   "min": 2 },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "beacon_tx", "value": "" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "beacon_tx", "value": "" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "beacon_rx", "value": "\"src\":1" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "beacon_rx", "value": "\"src\":0" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "rt_update", "value": "\"dest\":1" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "rt_update", "value": "\"dest\":0" }
  ]
}
```

This config uses `topology.links` (no path-loss) so it's easy to reason about — alice and bob are connected at +5 dB regardless of geography.

- [ ] **Step 2: Run the test and verify it FAILS**

```bash
bash test/run_tests.sh test/t10_dv_beacons.json
```

Expected: FAIL — every assertion fails because the script emits no events yet.

- [ ] **Step 3: Add beacon scheduling and transmission**

Edit `scenarios/dv_dual_sf.lua`. Replace the `on_init` function with:

```lua
local function beacon_fire(self)
  local frame = pack_beacon(self)
  self:emit("beacon_tx", { n_entries = (function()
    local c = 0; for _ in pairs(self.rt) do c = c + 1 end; return c
  end)() })
  self:tx(frame, { sf = self.routing_sf })
  self:after(self.beacon_period_ms, function() beacon_fire(self) end)
end

function on_init(self, config)
  self.routing_sf       = config.routing_sf      or 7
  self.data_sf          = config.data_sf         or 12
  self.beacon_period_ms = config.beacon_period_ms or 5000

  self.rt              = {}
  self.next_msg_id     = 1
  self.pending_tx      = nil
  self.pending_rx      = nil
  self.rt_full_emitted = false

  self.name_to_id = {}
  self.id_to_name = {}
  local nodes = sim:nodes()
  for _, n in ipairs(nodes) do
    self.name_to_id[n.name] = n.id
    self.id_to_name[n.id]   = n.name
  end
  self.peer_count = #nodes - 1

  -- ID-staggered first beacon to avoid collisions on first round.
  self:after(self.id * 100, function() beacon_fire(self) end)
end
```

- [ ] **Step 4: Add beacon reception (direct entry only)**

In `scenarios/dv_dual_sf.lua`, replace the empty `on_recv` body:

```lua
function on_recv(self, frame, meta)
  if #frame == 0 then return end
  local tag = frame:sub(1, 1)

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    self:emit("beacon_rx", { src = b.src, n_entries = #b.entries })
    -- Direct entry: sender is a 1-hop neighbour at measured SNR.
    self.rt[b.src] = {
      next_hop = b.src,
      score    = meta.snr,
      hops     = 1,
      last_seen_ms = self:now(),
    }
    self:emit("rt_update", { dest = b.src, next = b.src, score = meta.snr, hops = 1 })
  end
end
```

- [ ] **Step 5: Run the test and verify it PASSES**

```bash
bash test/run_tests.sh test/t10_dv_beacons.json
```

Expected: `t10_dv_beacons  PASS`. If it fails, inspect `test/t10_dv_beacons_events.ndjson` to see what the script actually emitted.

- [ ] **Step 6: Re-run the existing suite to confirm no regressions**

```bash
bash test/run_tests.sh
```

Expected: all 11 tests pass (10 existing + t10).

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua test/t10_dv_beacons.json
git commit -m "feat(scenarios/dv_dual_sf): beacon TX/RX + direct routing entries"
```

---

## Task 3: DV merge + rt_full convergence

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — extend beacon RX with the merge loop and rt_full detection
- Create: `test/t11_dv_convergence.json`

The receiver now also processes each entry inside the beacon. With bounded hop count and best-score-wins, a 4-node line converges in 3 beacon rounds (~15 seconds simulated). `rt_full` is emitted once per node when its routing table covers every peer.

- [ ] **Step 1: Write the failing test `test/t11_dv_convergence.json`**

```json
{
  "_name": "t11_dv_convergence",
  "_desc": "4-node line on lat/lon path-loss. After ~3 beacon rounds every node should have a routing table covering all 3 peers and emit rt_full.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 0.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 14.0
    }
  },
  "nodes": [
    { "name": "alice",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.3900, "lon": 2.1600 },
    { "name": "bob",     "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4035, "lon": 2.1600 },
    { "name": "charlie", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4170, "lon": 2.1600 },
    { "name": "dave",    "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4305, "lon": 2.1600 }
  ],
  "topology": { "links": [] },
  "commands": [],
  "expect": [
    { "type": "script_emit_contains", "node": "alice",   "emit_type": "rt_full", "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "bob",     "emit_type": "rt_full", "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "charlie", "emit_type": "rt_full", "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "dave",    "emit_type": "rt_full", "value": "\"peers\":3" }
  ]
}
```

- [ ] **Step 2: Run the test and verify it FAILS**

```bash
bash test/run_tests.sh test/t11_dv_convergence.json
```

Expected: FAIL — only direct entries exist, never `rt_full`.

- [ ] **Step 3: Add the DV merge body**

In `scenarios/dv_dual_sf.lua`, add a helper above `on_recv`:

```lua
local function rt_count(rt)
  local c = 0
  for _ in pairs(rt) do c = c + 1 end
  return c
end

local function maybe_emit_rt_full(self)
  if self.rt_full_emitted then return end
  if rt_count(self.rt) >= self.peer_count then
    self:emit("rt_full", { peers = self.peer_count })
    self.rt_full_emitted = true
  end
end
```

Then replace the `if tag == "B"` branch in `on_recv` with:

```lua
  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    self:emit("beacon_rx", { src = b.src, n_entries = #b.entries })

    -- Direct entry first.
    self.rt[b.src] = {
      next_hop = b.src,
      score    = meta.snr,
      hops     = 1,
      last_seen_ms = self:now(),
    }
    self:emit("rt_update", { dest = b.src, next = b.src, score = meta.snr, hops = 1 })

    -- DV merge: each entry in the beacon (other than self) is a candidate
    -- route via the beacon's sender.
    for _, e in ipairs(b.entries) do
      if e.dest ~= self.id and e.next ~= self.id then
        local combined_score = math.min(meta.snr, e.score)
        local combined_hops  = e.hops + 1
        if combined_hops <= 8 then
          local cur = self.rt[e.dest]
          local better = (cur == nil)
            or (combined_score > cur.score)
            or (combined_score == cur.score and combined_hops < cur.hops)
          if better then
            self.rt[e.dest] = {
              next_hop = b.src,
              score    = combined_score,
              hops     = combined_hops,
              last_seen_ms = self:now(),
            }
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = combined_score, hops = combined_hops,
            })
          end
        end
      end
    end

    maybe_emit_rt_full(self)
    return
  end
```

- [ ] **Step 4: Run the convergence test and verify PASS**

```bash
bash test/run_tests.sh test/t11_dv_convergence.json
```

Expected: `t11_dv_convergence  PASS`. If FAIL, inspect `test/t11_dv_convergence_events.ndjson` and trace `rt_update` events per node.

- [ ] **Step 5: Re-run all tests**

```bash
bash test/run_tests.sh
```

Expected: 12/12 pass (existing 10 + t10 + t11).

- [ ] **Step 6: Commit**

```bash
git add scenarios/dv_dual_sf.lua test/t11_dv_convergence.json
git commit -m "feat(scenarios/dv_dual_sf): DV merge + rt_full convergence"
```

---

## Task 4: Single-hop dual-SF data plane (RTS+CTS+DATA+delivered, no forwarding)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — add command parsing, RTS/CTS/DATA handlers
- Create: `test/t12_dv_single_hop.json`

The full per-hop dance is implemented for the case where the next-hop equals the final destination. Forwarding is the next task. We use 2 nodes only so the dance is one hop end-to-end.

- [ ] **Step 1: Write the failing test `test/t12_dv_single_hop.json`**

```json
{
  "_name": "t12_dv_single_hop",
  "_desc": "Single-hop dual-SF dance. alice sends to bob (direct neighbour); RTS on SF7, CTS+DATA on SF12, both nodes return to SF7. Verifies the full 4-step state machine for the destination==next-hop case.",
  "simulation": {
    "duration_ms": 40000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 0.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 14.0
    }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.3900, "lon": 2.1600 },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4035, "lon": 2.1600 }
  ],
  "topology": { "links": [] },
  "commands": [
    { "at_ms": 20000, "node": "alice", "command": "send bob hello-bob" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "alice", "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "rts_tx",    "value": "\"dst\":1" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "rts_rx",    "value": "\"from\":0" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "cts_tx",    "value": "\"to\":0" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "cts_rx",    "value": "\"from\":1" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "data_tx",   "value": "\"dst\":1" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "data_rx",   "value": "\"from\":0" },
    { "type": "script_emit_contains", "node": "bob",   "emit_type": "delivered", "value": "hello-bob" },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "alice", "min": 0, "max": 0 },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "bob",   "min": 0, "max": 0 }
  ]
}
```

- [ ] **Step 2: Run the test and verify it FAILS**

```bash
bash test/run_tests.sh test/t12_dv_single_hop.json
```

Expected: FAIL — `on_command` returns the stub error and no data plane events fire.

- [ ] **Step 3: Add `gen_msg_id` helper and `on_command` body**

In `scenarios/dv_dual_sf.lua`, add a helper above `on_command`:

```lua
local function gen_msg_id(self)
  -- Pack node id into upper 8 bits to keep ids globally unique-ish for diagnostics.
  local mid = (self.id * 256 + self.next_msg_id) % 65536
  self.next_msg_id = self.next_msg_id + 1
  if self.next_msg_id > 255 then self.next_msg_id = 1 end
  return mid
end
```

Replace `on_command` with:

```lua
function on_command(self, cmd_str)
  local dst_name, text = cmd_str:match("^send (%S+) (.+)$")
  if not dst_name then return "ERROR: usage: send <dst_name> <text>" end
  local dst_id = self.name_to_id[dst_name]
  if dst_id == nil then return "ERROR: unknown dst: " .. dst_name end
  local route = self.rt[dst_id]
  if route == nil then return "ERROR: no route to " .. dst_name end
  if self.pending_tx ~= nil then return "ERROR: busy" end

  local mid = gen_msg_id(self)
  self.pending_tx = {
    origin   = self.id,
    dst      = dst_id,
    next     = route.next_hop,
    msg_id   = mid,
    payload  = text,
  }

  local frame = pack_rts(self.id, self.id, dst_id, route.next_hop, mid, self.data_sf)
  self:emit("rts_tx", { origin = self.id, dst = dst_id, next = route.next_hop, msg_id = mid })
  self:tx(frame, { sf = self.routing_sf })

  self:set_rx_sf(self.data_sf)
  self:emit("retune_for_cts", { sf = self.data_sf })

  return string.format("sent RTS msg_id=%d to %s via %d", mid, dst_name, route.next_hop)
end
```

- [ ] **Step 4: Add RTS, CTS, DATA branches to `on_recv`**

In `scenarios/dv_dual_sf.lua`, extend `on_recv` (after the `tag == "B"` block, before the closing `end`):

```lua
  if tag == "R" then
    local r = parse_rts(frame)
    if not r then return end
    if r.next ~= self.id then return end  -- not for us; silent discard

    self:emit("rts_rx", { from = r.src, origin = r.origin, dst = r.dst, msg_id = r.msg_id })
    -- Remember the RTS context so we can match the incoming DATA.
    self.pending_rx = {
      from    = r.src,
      origin  = r.origin,
      dst     = r.dst,
      msg_id  = r.msg_id,
    }
    self:set_rx_sf(self.data_sf)
    self:emit("retune_for_data", { sf = self.data_sf })

    local cts = pack_cts(self.id, r.msg_id)
    self:emit("cts_tx", { to = r.src, msg_id = r.msg_id })
    self:tx(cts, { sf = self.data_sf })
    return
  end

  if tag == "C" then
    local c = parse_cts(frame)
    if not c then return end
    if self.pending_tx == nil then return end
    if c.msg_id ~= self.pending_tx.msg_id then return end

    self:emit("cts_rx", { from = c.src, msg_id = c.msg_id })
    local d = pack_data(
      self.pending_tx.origin,
      self.id,
      self.pending_tx.dst,
      self.pending_tx.next,
      self.pending_tx.msg_id,
      self.pending_tx.payload
    )
    self:emit("data_tx", {
      origin = self.pending_tx.origin,
      dst    = self.pending_tx.dst,
      next   = self.pending_tx.next,
      msg_id = self.pending_tx.msg_id,
      len    = #self.pending_tx.payload,
    })
    self:tx(d, { sf = self.data_sf })
    self:set_rx_sf(self.routing_sf)
    self.pending_tx = nil
    return
  end

  if tag == "D" then
    local d = parse_data(frame)
    if not d then return end
    if d.next ~= self.id then return end
    if self.pending_rx == nil or d.msg_id ~= self.pending_rx.msg_id then return end

    self:emit("data_rx", {
      from   = d.src,
      origin = d.origin,
      dst    = d.dst,
      msg_id = d.msg_id,
      len    = #d.payload,
    })
    self:set_rx_sf(self.routing_sf)
    self.pending_rx = nil

    if d.dst == self.id then
      self:emit("delivered", { origin = d.origin, payload = d.payload })
    else
      -- Forwarding is added in Task 5. For now: log the gap.
      self:emit("forward_skipped", { dst = d.dst, reason = "not_implemented" })
    end
    return
  end
```

- [ ] **Step 5: Run the test and verify PASS**

```bash
bash test/run_tests.sh test/t12_dv_single_hop.json
```

Expected: `t12_dv_single_hop  PASS`. If FAIL, inspect `test/t12_dv_single_hop_events.ndjson` and trace events at the source order to find which step in the dance broke.

- [ ] **Step 6: Re-run all tests**

```bash
bash test/run_tests.sh
```

Expected: 13/13 pass.

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua test/t12_dv_single_hop.json
git commit -m "feat(scenarios/dv_dual_sf): single-hop RTS+CTS+DATA dual-SF dance with delivery"
```

---

## Task 5: Multi-hop forwarding (the s01 scenario)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — replace the `forward_skipped` stub with a real forward
- Modify: `scenarios/s01_dv_dual_sf.json` — add commands and expects

A forwarder, on receiving DATA where `dst != self.id`, looks up `next_hop_for(dst)` in its own routing table, mints a new `msg_id`, and starts a fresh RTS/CTS/DATA dance toward that next hop. The originator's `origin` byte is preserved so the destination's `delivered` event reports the source.

- [ ] **Step 1: Replace the skeleton expects in `scenarios/s01_dv_dual_sf.json`**

Update the bottom of the file (`commands` and `expect` arrays):

```json
  "commands": [
    { "at_ms": 30000, "node": "alice", "command": "send dave hello-world" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "alice",   "emit_type": "rt_full",   "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "bob",     "emit_type": "rt_full",   "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "charlie", "emit_type": "rt_full",   "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "dave",    "emit_type": "rt_full",   "value": "\"peers\":3" },
    { "type": "script_emit_contains", "node": "alice",   "emit_type": "rts_tx",    "value": "\"next\":1" },
    { "type": "script_emit_contains", "node": "bob",     "emit_type": "rts_tx",    "value": "\"next\":2" },
    { "type": "script_emit_contains", "node": "charlie", "emit_type": "rts_tx",    "value": "\"next\":3" },
    { "type": "script_emit_contains", "node": "dave",    "emit_type": "delivered", "value": "hello-world" },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "alice",   "min": 0, "max": 0 },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "bob",     "min": 0, "max": 0 },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "charlie", "min": 0, "max": 0 },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "node": "dave",    "min": 0, "max": 0 }
  ]
```

(Replace the existing `"commands": []` and `"expect": []` lines with the blocks above.)

- [ ] **Step 2: Run scenario s01 and verify it FAILS**

```bash
./build/orchestrator/lus scenarios/s01_dv_dual_sf.json scenarios/s01_dv_dual_sf_events.ndjson
echo "exit=$?"
```

Expected: non-zero exit (assertion failures). At minimum, `bob`/`charlie`'s `rts_tx` and `dave`'s `delivered` won't fire because forwarding is still stubbed as `forward_skipped`.

(We can't yet use `bash test/run_tests.sh scenarios/s01_dv_dual_sf.json` — the runner globs only `test/`. Direct invocation is the diagnostic path here.)

- [ ] **Step 3: Replace `forward_skipped` with a real forward**

In `scenarios/dv_dual_sf.lua`, locate the `if d.dst == self.id then ... else ... end` block in the DATA branch of `on_recv` and replace the `else` clause with:

```lua
    else
      local route = self.rt[d.dst]
      if route == nil then
        self:emit("forward_fail", { dst = d.dst, reason = "no_route" })
      else
        local mid = gen_msg_id(self)
        self.pending_tx = {
          origin  = d.origin,           -- preserve originator across hops
          dst     = d.dst,
          next    = route.next_hop,
          msg_id  = mid,
          payload = d.payload,
        }
        local rts = pack_rts(d.origin, self.id, d.dst, route.next_hop, mid, self.data_sf)
        self:emit("rts_tx", {
          origin = d.origin, dst = d.dst, next = route.next_hop, msg_id = mid,
        })
        self:tx(rts, { sf = self.routing_sf })
        self:set_rx_sf(self.data_sf)
        self:emit("retune_for_cts", { sf = self.data_sf })
      end
    end
```

- [ ] **Step 4: Run scenario s01 and verify PASS**

```bash
./build/orchestrator/lus scenarios/s01_dv_dual_sf.json scenarios/s01_dv_dual_sf_events.ndjson
echo "exit=$?"
```

Expected: exit 0; final stderr/stdout includes `expect: 0 failures`.

- [ ] **Step 5: Spot-check the event trace**

```bash
grep -E '"emit_type":"(rt_full|rts_tx|cts_tx|data_tx|delivered)"' scenarios/s01_dv_dual_sf_events.ndjson | sed -n '1,30p'
```

Expected (in order, abbreviated): `rt_full × 4`, then `rts_tx alice→bob`, `cts_tx bob`, `data_tx alice→bob`, `rts_tx bob→charlie`, `cts_tx charlie`, `data_tx bob→charlie`, `rts_tx charlie→dave`, `cts_tx dave`, `data_tx charlie→dave`, `delivered dave`.

- [ ] **Step 6: Re-run the existing suite to confirm no regressions**

```bash
bash test/run_tests.sh
```

Expected: 13/13 pass (existing 13; runner doesn't see `s01` yet — fixed in Task 6).

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua scenarios/s01_dv_dual_sf.json
git commit -m "feat(scenarios/dv_dual_sf): multi-hop forwarding; s01 alice→dave end-to-end"
```

---

## Task 6: Test runner integration

**Files:**
- Modify: `test/run_tests.sh` — add `scenarios/s*.json` to the default glob

This is the smallest possible change to make `s01` part of the regression suite without disrupting existing usage.

- [ ] **Step 1: Read the current default-glob block**

```bash
sed -n '30,45p' test/run_tests.sh
```

Expected output around lines 32-39 (line numbers may drift):

```bash
CONFIGS=("$@")
if [ ${#CONFIGS[@]} -eq 0 ]; then
    while IFS= read -r f; do
        CONFIGS+=("$f")
    done < <(ls "$SCRIPT_DIR"/t*.json 2>/dev/null | sort)
fi
```

- [ ] **Step 2: Extend the default-glob to also pick up `scenarios/s*.json`**

In `test/run_tests.sh`, replace the `while ... done < <(ls ...)` block with:

```bash
    while IFS= read -r f; do
        CONFIGS+=("$f")
    done < <( { ls "$SCRIPT_DIR"/t*.json 2>/dev/null; ls "$REPO_ROOT"/scenarios/s*.json 2>/dev/null; } | sort )
```

(The braces preserve the existing sort behaviour while merging the two globs into one stream.)

- [ ] **Step 3: Run the full suite — including s01 — and verify all pass**

```bash
bash test/run_tests.sh
```

Expected: 14/14 pass. `s01_dv_dual_sf` lands first in the output (lexicographic sort: `s` < `t`, so the scenarios glob comes before all `tNN`). The assertion is "PASS for every line".

- [ ] **Step 4: Verify a single-target invocation still works for both directories**

```bash
bash test/run_tests.sh test/t01_flooder.json
bash test/run_tests.sh scenarios/s01_dv_dual_sf.json
```

Expected: each invocation reports `1/1 passed`.

- [ ] **Step 5: Commit**

```bash
git add test/run_tests.sh
git commit -m "chore(test): runner picks up scenarios/s*.json alongside test/t*.json"
```

---

## Acceptance for s01 implementation

After all 6 tasks:

- [ ] `bash test/run_tests.sh` reports 14/14 pass
- [ ] `bash test/run_tests.sh scenarios/s01_dv_dual_sf.json` reports 1/1 pass
- [ ] No `lua_error`, no `drop_sf_mismatch`, no `forward_fail` events in `scenarios/s01_dv_dual_sf_events.ndjson`
- [ ] `dave` emits `delivered` carrying `hello-world` from `origin=0` (alice)
- [ ] All four nodes emit `rt_full` before t=20000 ms
- [ ] The Lua script is one file, ≤ 300 lines, with all helpers `local`
- [ ] Build clean with `cmake --build build -j`

This unblocks scenario B (small mesh) — same Lua script, larger topology, denser routing decisions.
