# F1 Blind-Window Mitigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate F1 (concurrent multi-hop flight collisions at shared relays) in `scenarios/dv_dual_sf.lua` so `s01_dv_dual_sf` reliably delivers both concurrent sends. Spec: `docs/superpowers/specs/2026-05-07-f1-blind-window-mitigation-design.md`.

**Architecture:** Per-node `blind_until[node_id]` table populated by passively overhearing every CTS frame. The table is consulted at three call sites in dv_dual_sf.lua (`issue_send`, `tx_rts_retry`, `rts_timeout_fire`) to either alt-switch or defer when the chosen next-hop is in its `data_sf` RX window. Plus exponential `rts_timeout` backoff (cap 4× base) as a CTS-loss safety net. One small runtime primitive added: `meta.src` exposed in `on_recv`.

**Tech Stack:** C++ (sol2 / Lua bindings, SimController), Lua 5.x (sandboxed, no `bit` library — use `<<`, `>>`, `&`, `|` operators which are Lua 5.3+), JSON scenarios.

---

## Pre-Execution Notes

**Working tree state:** the repo currently has substantial uncommitted work from a parallel `rf-params-and-sf-bw-sublanes` initiative (modified files in `core/`, `orchestrator/`, `scenarios/`, `webapp/`, etc.). Do **not** bundle that work into this plan's commits.

**Recommended workflow:** create an isolated git worktree before starting:
```
git worktree add ../lus-f1 main
cd ../lus-f1
```
The plan assumes a clean checkout from `main`. Run a baseline build + test pass first to confirm a green starting state:
```
cmake -S . -B build && cmake --build build -j 4
bash test/native/build_test.sh && bash test/run_tests.sh
```

**File path conventions:** all paths in this plan are relative to the repo root.

---

## File Structure

| File | Change | Purpose |
|---|---|---|
| `orchestrator/runtime/LuaHost.h` | Modify | Add `int src_id` parameter to `callOnRecv` |
| `orchestrator/runtime/LuaHost.cpp` | Modify | Set `meta["src"] = src_id` in `callOnRecv` body |
| `orchestrator/runtime/ScriptedNode.h` | Modify | Add `int src_id` to `onRecv` signature |
| `orchestrator/runtime/ScriptedNode.cpp` | Modify | Pass `src_id` through to `callOnRecv` |
| `orchestrator/runtime/SimController.cpp` | Modify | Pass `tx.sender_id` to two `_nodes[rcv]->onRecv(...)` call sites |
| `scenarios/dv_dual_sf.lua` | Modify | Add `blind_until` state, helpers, integration at 3 call sites, exponential backoff, header docs update |
| `scenarios/s01_dv_dual_sf.json` | Modify | Extend `expect[]` to require both deliveries + `blind_observed` |
| `test/t14b_meta_src.json` | Create | Tiny scenario verifying `meta.src` is exposed |
| `test/t14b_meta_src.lua` | Create | Companion script for t14b |
| `test/t15_concurrent_relay.json` | Create | F1 reproducer scenario (5 nodes, deterministic) |

No new files needed in `core/`, `webapp/`, or `docs/` (spec is already committed).

---

## Task 1: Runtime — `meta.src` plumbing

**Files:**
- Create: `test/t14b_meta_src.lua`
- Create: `test/t14b_meta_src.json`
- Modify: `orchestrator/runtime/LuaHost.h:56-57`
- Modify: `orchestrator/runtime/LuaHost.cpp:248-264`
- Modify: `orchestrator/runtime/ScriptedNode.h:76-77`
- Modify: `orchestrator/runtime/ScriptedNode.cpp:112-116`
- Modify: `orchestrator/runtime/SimController.cpp:648-650, 740-742`

- [ ] **Step 1.1: Create the failing test scenario script**

Create `test/t14b_meta_src.lua`:
```lua
-- test/t14b_meta_src.lua
-- Verifies meta.src is exposed to on_recv with the sender's node id.
-- Flow: alice tx's a single byte to bob. bob emits "src_observed" carrying
-- meta.src, the test asserts that emit data contains alice's id (which is 0
-- in the order alice/bob in the JSON — first node = id 0).

function on_init(self, config)
  self.id_to_name = {}
  for _, n in ipairs(sim:nodes()) do
    self.id_to_name[n.id] = n.name
  end
end

function on_command(self, cmd)
  if cmd == "ping" then
    self:tx("X", { label = "PING" })
    return "ok"
  end
  return "ERROR: unknown cmd"
end

function on_recv(self, frame, meta)
  self:emit("src_observed", {
    src     = meta.src,
    src_name = self.id_to_name[meta.src] or "?",
    snr     = meta.snr,
    bytes   = #frame,
  })
end
```

- [ ] **Step 1.2: Create the test scenario JSON**

Create `test/t14b_meta_src.json`:
```json
{
  "_name": "t14b_meta_src",
  "_desc": "Verify meta.src is exposed to on_recv. alice tx's; bob's on_recv emits the observed src id.",
  "simulation": {
    "duration_ms": 3000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 100,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "test/t14b_meta_src.lua" },
    { "name": "bob",   "script": "test/t14b_meta_src.lua" }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 1000, "node": "alice", "command": "ping" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "bob", "emit_type": "src_observed", "value": "\"src\":0" },
    { "type": "script_emit_contains", "node": "bob", "emit_type": "src_observed", "value": "\"src_name\":\"alice\"" }
  ]
}
```

- [ ] **Step 1.3: Build and run t14b — expect FAIL**

```
cmake --build build -j 4
bash test/run_tests.sh test/t14b_meta_src.json
```
Expected: `t14b_meta_src ... FAIL` because `meta.src` is `nil` today (so `src_name` lookup yields `"?"` and `"src":0` substring never appears).

Inspect the failing output:
```
cat test/t14b_meta_src_events.ndjson | grep src_observed
```
You should see emits with `"src":null` (or missing `src` key) — confirming the gap we're filling.

- [ ] **Step 1.4: Modify `orchestrator/runtime/LuaHost.h` — add `src_id` parameter**

Edit `LuaHost.h:56-57`. Replace:
```cpp
    void callOnRecv(int node_id, std::string_view bytes,
                    float snr, float rssi, int link_id, uint64_t sim_ms);
```
with:
```cpp
    void callOnRecv(int node_id, std::string_view bytes,
                    float snr, float rssi, int link_id, int src_id,
                    uint64_t sim_ms);
```

- [ ] **Step 1.5: Modify `orchestrator/runtime/LuaHost.cpp` — set `meta.src`**

Edit `LuaHost.cpp:248-264`. Replace the entire `callOnRecv` body:
```cpp
void LuaHost::callOnRecv(int node_id, std::string_view bytes,
                         float snr, float rssi, int link_id, uint64_t sim_ms) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_recv"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table meta = _lua.create_table();
    meta["snr"]     = snr;
    meta["rssi"]    = rssi;
    meta["link_id"] = link_id;
    meta["recv_ms"] = sim_ms;
    sol::protected_function_result r = fn.call(self, std::string(bytes), meta);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_recv: ") + err.what());
    }
}
```
with:
```cpp
void LuaHost::callOnRecv(int node_id, std::string_view bytes,
                         float snr, float rssi, int link_id, int src_id,
                         uint64_t sim_ms) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_recv"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table meta = _lua.create_table();
    meta["snr"]     = snr;
    meta["rssi"]    = rssi;
    meta["link_id"] = link_id;
    meta["src"]     = src_id;
    meta["recv_ms"] = sim_ms;
    sol::protected_function_result r = fn.call(self, std::string(bytes), meta);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_recv: ") + err.what());
    }
}
```

- [ ] **Step 1.6: Modify `orchestrator/runtime/ScriptedNode.h` — extend `onRecv` signature**

Edit `ScriptedNode.h:76-77`. Replace:
```cpp
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, uint64_t sim_ms);
```
with:
```cpp
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, int src_id, uint64_t sim_ms);
```

- [ ] **Step 1.7: Modify `orchestrator/runtime/ScriptedNode.cpp` — pass-through**

Edit `ScriptedNode.cpp:112-116`. Replace:
```cpp
void ScriptedNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, uint64_t sim_ms) {
    if (!_initialized) return;   // radio off until on_init has fired
    _host.callOnRecv(_id, bytes, snr, rssi, link_id, sim_ms);
}
```
with:
```cpp
void ScriptedNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, int src_id, uint64_t sim_ms) {
    if (!_initialized) return;   // radio off until on_init has fired
    _host.callOnRecv(_id, bytes, snr, rssi, link_id, src_id, sim_ms);
}
```

- [ ] **Step 1.8: Modify `orchestrator/runtime/SimController.cpp` — pass sender_id at both call sites**

There are two `_nodes[rcv]->onRecv(...)` call sites: one around `:648` (warmup-mode delivery branch) and one around `:740` (normal-mode delivery branch). Both call sites already have `tx.sender_id` (a `Tx`-like struct member with the sender's node id) in scope.

Edit `SimController.cpp` around `:648`. Replace:
```cpp
            _nodes[rcv]->onRecv(tx.bytes, snr_at_rcv, lp.rssi,
                                /*link_id=*/0,
                                /*sim_ms=*/now);
```
with:
```cpp
            _nodes[rcv]->onRecv(tx.bytes, snr_at_rcv, lp.rssi,
                                /*link_id=*/0,
                                /*src_id=*/tx.sender_id,
                                /*sim_ms=*/now);
```

Edit `SimController.cpp` around `:740`. Replace:
```cpp
                    _nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
                                      /*link_id=*/0,
                                      /*sim_ms=*/now);
```
with:
```cpp
                    _nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
                                      /*link_id=*/0,
                                      /*src_id=*/i,
                                      /*sim_ms=*/now);
```
Note: in this second branch the sender's id is the loop variable `i`, not `p.sender_id` (this branch iterates pending txs that haven't been pushed to the in-flight queue yet — confirm by reading the surrounding context, which uses `_nodes[i]->name()` for log lines).

- [ ] **Step 1.9: Rebuild and rerun t14b — expect PASS**

```
cmake --build build -j 4
bash test/run_tests.sh test/t14b_meta_src.json
```
Expected: `t14b_meta_src ... PASS`.

Inspect the events to confirm:
```
grep src_observed test/t14b_meta_src_events.ndjson
```
The `"src":0,"src_name":"alice"` substring should appear at least once.

- [ ] **Step 1.10: Run native suite — expect all pass**

```
bash test/native/build_test.sh
```
All native tests should still pass. The native suite does not call `onRecv` directly; the change is confined to `SimController` and the runtime call chain. If any native test fails, do not proceed — investigate first.

- [ ] **Step 1.11: Run full integration suite — expect all pass**

```
bash test/run_tests.sh
```
All `t*.json` and `s*.json` should pass. The behavior of dv_dual_sf.lua hasn't changed yet — `meta.src` is exposed but the script doesn't read it.

- [ ] **Step 1.12: Commit**

```
git add test/t14b_meta_src.json test/t14b_meta_src.lua \
        orchestrator/runtime/LuaHost.h orchestrator/runtime/LuaHost.cpp \
        orchestrator/runtime/ScriptedNode.h orchestrator/runtime/ScriptedNode.cpp \
        orchestrator/runtime/SimController.cpp
git commit -m "$(cat <<'EOF'
feat(runtime): expose meta.src in on_recv

Adds the sender's node id to the meta table passed to Lua's on_recv,
unblocking protocol features that need to know who sent each frame
(e.g., the F1 blind-window mitigation that overhears CTS to track
which neighbour is busy on data_sf). Existing Lua scripts that don't
read meta.src are unaffected.
EOF
)"
```

---

## Task 2: Lua helpers + state (no behavior change)

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (around `:465-560` for helpers, around `:1076-1097` for on_init state)

This task adds dormant infrastructure. After this task, integration suite must still produce identical events to before — no behavior change yet.

- [ ] **Step 2.1: Add `RTS_TIMEOUT_BACKOFF_CAP` constant + `rts_timeout_for_attempt` helper**

In `scenarios/dv_dual_sf.lua`, locate the existing constants block around `:559` (`local TX_DEFER_MAX_RETRIES = 3`). Add immediately after:
```lua
-- Exponential backoff cap on rts_timeout. The timeout doubles per retry
-- attempt and saturates at this multiple of the base. With s01's
-- SF8 base (~122 ms) the timeouts walk 122, 244, 488, 488, ... covering
-- ~3.3 s across rts_max_retries=8 — well past the ~250 ms blind window
-- for SF9 data and the ~1.5 s worst case for SF12 data.
local RTS_TIMEOUT_BACKOFF_CAP = 4

local function rts_timeout_for_attempt(base_ms, attempt_idx)
  local mult = 1
  for _ = 1, attempt_idx do
    mult = mult * 2
    if mult >= RTS_TIMEOUT_BACKOFF_CAP then
      mult = RTS_TIMEOUT_BACKOFF_CAP
      break
    end
  end
  return base_ms * mult
end
```

- [ ] **Step 2.2: Add `is_blind` helper**

Continue in the same constants/helpers block. After `rts_timeout_for_attempt`:
```lua
-- F1 mitigation: blind_until tracks when each 1-hop neighbour will
-- finish its data_sf RX window (deaf on routing_sf). Populated by
-- overhearing CTS frames; consulted before issuing or retrying RTS.
-- Returns (is_blind: bool, remaining_ms: int). Opportunistically prunes
-- expired entries so the table stays bounded.
local function is_blind(self, node_id)
  local until_ms = self.blind_until[node_id]
  if until_ms == nil then return false, 0 end
  local now = self:now()
  if until_ms <= now then
    self.blind_until[node_id] = nil
    return false, 0
  end
  return true, until_ms - now
end
```

- [ ] **Step 2.3: Add `classify_blind` helper**

Continue:
```lua
-- Decision helper used at issue_send / tx_rts_retry / rts_timeout_fire.
-- Returns one of:
--   "ok"                -- proceed with current next_hop
--   "alt", new_next_hop -- caller should switch to alt route + re-tx
--   "defer", delay_ms   -- caller should re-schedule after delay_ms
local function classify_blind(self, dst_id, current_next_hop, alt_already_tried)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  local entry = self.rt[dst_id]
  local alt = entry and entry.alt or nil
  if alt and (not alt_already_tried) and (not is_blind(self, alt.next_hop)) then
    return "alt", alt.next_hop
  end
  return "defer", remaining + 1
end
```

- [ ] **Step 2.4: Add `blind_until` to on_init state initialization**

Locate `on_init` around `:1076-1097` (the block initializing `self.rt`, `self.next_msg_id`, `self.pending_tx`, etc.). Find the line:
```lua
  self.tx_stash         = {}    -- label → {bytes, opts, retries_left} for on_radio_busy
```
Add a new line immediately after it:
```lua
  self.blind_until      = {}    -- {node_id → absolute_ms} for F1 mitigation
```

- [ ] **Step 2.5: Build + run integration suite — expect all pass with no event change**

```
cmake --build build -j 4
bash test/run_tests.sh
```
All tests should pass. No `blind_observed` emit fires yet (we haven't added the prelude). No behavior change.

- [ ] **Step 2.6: Commit**

```
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): add F1 blind_until state + helpers (dormant)

Adds RTS_TIMEOUT_BACKOFF_CAP + rts_timeout_for_attempt + is_blind +
classify_blind helpers, and self.blind_until table in on_init. Not
yet wired into any call site — no behavior change. Subsequent commits
add the CTS overhearing prelude and the issue/retry/timeout integrations.
EOF
)"
```

---

## Task 3: CTS overhearing prelude

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (`on_recv 'C'` branch around `:1363`)

- [ ] **Step 3.1: Add overhearing prelude before existing pending_tx-match check**

Locate the `if tag == "C" then` branch (around `:1363`). It currently starts:
```lua
  if tag == "C" then
    local c = parse_cts(frame)
    if not c then return end
    if self.pending_tx == nil then return end
    if c.msg_id ~= self.pending_tx.msg_id then return end
```

Replace that opening block with:
```lua
  if tag == "C" then
    local c = parse_cts(frame)
    if not c then return end

    -- F1 mitigation: every CTS — addressed to us or not — tells us its
    -- sender will be deaf on routing_sf for one DATA-RX window
    -- (cts_to_data_gap + airtime of the chosen data_sf, max payload).
    -- Stash that absolute end-time so future RTS attempts toward this
    -- sender either alt-switch or defer instead of hitting drop_sf_mismatch.
    if meta.src ~= nil then
      local now = self:now()
      local blind_window = self.cts_to_data_gap_ms +
        airtime_ms(c.chosen_data_sf, self.bw_hz, self.cr,
                   self.preamble_sym,
                   DATA_HDR_LEN + self.max_payload_bytes)
      local end_ms = now + blind_window
      local prev = self.blind_until[meta.src]
      if prev == nil or end_ms > prev then
        self.blind_until[meta.src] = end_ms
        self:emit("blind_observed", {
          node           = meta.src,
          until_ms       = end_ms,
          chosen_data_sf = c.chosen_data_sf,
        })
      end
    end

    if self.pending_tx == nil then return end
    if c.msg_id ~= self.pending_tx.msg_id then return end
```

The remainder of the `tag == "C"` branch (cts_invalid_sf check, cts_rx emit, cts-to-data-gap callback, etc.) stays unchanged.

- [ ] **Step 3.2: Run t12_dv_single_hop — expect PASS + blind_observed in events**

```
bash test/run_tests.sh test/t12_dv_single_hop.json
grep blind_observed test/t12_dv_single_hop_events.ndjson
```
Expected: PASS. The grep should return at least one line (alice overhears bob's CTS, or vice versa, depending on which side originated).

- [ ] **Step 3.3: Run full integration — expect all pass**

```
bash test/run_tests.sh
```
All tests pass. New `blind_observed` emits appear in events.ndjson files for any scenario that triggers a CTS, but none of the existing assertions are affected (none assert event counts that exclude `blind_observed`).

- [ ] **Step 3.4: Commit**

```
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): F1 mitigation — overhear CTS, populate blind_until

Every CTS — addressed to us or not — implies the CTS-sender will be
deaf on routing_sf for one DATA-RX window. Record that absolute
end-time in self.blind_until[sender]. Adds a blind_observed emit per
update for telemetry. The table is dormant — read sites land in the
next commit.
EOF
)"
```

---

## Task 4: Wire the three integration call sites + exponential backoff

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (`issue_send` around `:888`, `tx_rts_retry` around `:682`, `rts_timeout_fire` around `:706`, `start_rts_timeout` around `:787`)

This is the behavior-changing task. After this, s01 will likely deliver both flights (and may break s01's existing assertion shape — that's OK; s01 expectations get updated in Task 7).

- [ ] **Step 4.1: Wire `issue_send` blind check**

Locate `issue_send` around `:888`. The function starts:
```lua
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, origin_seq)
  local entry = self.rt[dst_id]
  if not entry then
    self:emit("send_no_route", { ... })
    self:log(string.format("send_no_route dst=%s ...", dst_name))
    return
  end
  local primary_next = entry.primary.next_hop
  local mid = gen_msg_id(self)
  self.pending_tx = {
    origin       = origin,
    dst          = dst_id,
    next         = primary_next,
    ...
  }
```

Insert the blind check immediately before `local mid = gen_msg_id(self)`. The new block:
```lua
  -- F1 mitigation: if the chosen next-hop is currently blind on
  -- routing_sf (we overheard its CTS), either alt-switch or defer
  -- the issue. Defer re-queues at the head so ordering is preserved.
  local action_b, val_b = classify_blind(self, dst_id, primary_next, false)
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = origin, payload = user_text, origin_seq = origin_seq,
      dst = dst_id, next_hop = primary_next, delay_ms = val_b,
      source = "issue_send",
    })
    self:log(string.format("tx_blind_defer (issue_send) -> %s deferred %dms",
      name_of(self, primary_next), val_b))
    table.insert(self.tx_queue, 1, {
      origin = origin, dst_id = dst_id, dst_name = dst_name,
      payload = payload, user_text = user_text, origin_seq = origin_seq,
    })
    self:after(val_b, function() become_free(self) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = origin, payload = user_text, origin_seq = origin_seq,
      dst = dst_id, from_next = primary_next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (issue_send) dst=%s %s -> %s",
      dst_name, name_of(self, primary_next), name_of(self, val_b)))
    primary_next = val_b
  end
  local mid = gen_msg_id(self)
```

Then update the `self.pending_tx = { ... }` block to set `alt_tried` based on whether we took the alt branch. Find:
```lua
    alt_tried    = false,        -- on_recv "N" flips this when we move to alt
```
Replace with:
```lua
    alt_tried    = (action_b == "alt"),  -- pre-set if F1 blind-alt fired
```

- [ ] **Step 4.2: Wire `tx_rts_retry` blind check**

Locate `tx_rts_retry` (around `:682`). Replace the entire function body — old:
```lua
local function tx_rts_retry(self, reason)
  local px = self.pending_tx
  local rts = pack_rts(px.origin, self.id, px.dst, px.next, px.msg_id,
                       self.allowed_sf_bitmap)
  self:emit("rts_retry", {
    origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
    dst = px.dst, next = px.next,
    msg_id = px.msg_id, retries_left = px.retries_left, reason = reason,
  })
  self:log(string.format("rts_retry -> %s msg_id=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.msg_id, px.retries_left, reason))
  self:tx(rts, {
    sf    = self.routing_sf,
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s",
      name_of(self, px.next), px.msg_id, px.retries_left, reason),
  })
  -- RX stays on routing_sf — both CTS and NACK are control-plane responses
  -- on routing_sf now, no retune needed until DATA is about to TX.
  start_rts_timeout(self)
end
```
new:
```lua
local function tx_rts_retry(self, reason)
  local px = self.pending_tx

  -- F1 mitigation: if next-hop is now known-blind, defer the retry or
  -- switch to alt. Reset retries budget on alt-switch (fresh path).
  local action_b, val_b = classify_blind(self, px.dst, px.next, px.alt_tried)
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
      msg_id = px.msg_id, next_hop = px.next, delay_ms = val_b,
      source = "tx_rts_retry", reason = reason,
    })
    self:log(string.format("tx_blind_defer (tx_rts_retry) msg=%d -> %s deferred %dms",
      px.msg_id, name_of(self, px.next), val_b))
    self:after(val_b, function() tx_rts_retry(self, reason) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
      msg_id = px.msg_id, from_next = px.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (tx_rts_retry) msg=%d %s -> %s",
      px.msg_id, name_of(self, px.next), name_of(self, val_b)))
    px.next = val_b
    px.alt_tried = true
    px.retries_left = self.rts_max_retries
  end

  local rts = pack_rts(px.origin, self.id, px.dst, px.next, px.msg_id,
                       self.allowed_sf_bitmap)
  self:emit("rts_retry", {
    origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
    dst = px.dst, next = px.next,
    msg_id = px.msg_id, retries_left = px.retries_left, reason = reason,
  })
  self:log(string.format("rts_retry -> %s msg_id=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.msg_id, px.retries_left, reason))
  self:tx(rts, {
    sf    = self.routing_sf,
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s",
      name_of(self, px.next), px.msg_id, px.retries_left, reason),
  })
  -- RX stays on routing_sf — both CTS and NACK are control-plane responses
  -- on routing_sf now, no retune needed until DATA is about to TX.
  start_rts_timeout(self)
end
```

- [ ] **Step 4.3: Wire `rts_timeout_fire` blind check**

Locate `rts_timeout_fire` (around `:706`). Replace the entire function — old:
```lua
local function rts_timeout_fire(self, captured_msg_id)
  if self.pending_tx == nil then return end
  if self.pending_tx.msg_id ~= captured_msg_id then return end

  if self.pending_rx ~= nil then
    self:log(string.format("rts_retry_deferred (busy as receiver) msg=%d",
      captured_msg_id))
    self:after(self.rts_busy_retry_ms, function()
      rts_timeout_fire(self, captured_msg_id)
    end)
    return
  end

  if self.pending_tx.retries_left <= 0 then
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("rts_giveup msg=%d (max retries exhausted, dst=%s)",
      captured_msg_id, name_of(self, self.pending_tx.dst)))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  tx_rts_retry(self, "cts_timeout")
  -- (rts_retry emit happens inside tx_rts_retry — adds origin/payload there)
end
```
new:
```lua
local function rts_timeout_fire(self, captured_msg_id)
  if self.pending_tx == nil then return end
  if self.pending_tx.msg_id ~= captured_msg_id then return end

  if self.pending_rx ~= nil then
    self:log(string.format("rts_retry_deferred (busy as receiver) msg=%d",
      captured_msg_id))
    self:after(self.rts_busy_retry_ms, function()
      rts_timeout_fire(self, captured_msg_id)
    end)
    return
  end

  -- F1 mitigation: receiver may have just become blind (we overheard a
  -- CTS to a different sender after our RTS-tx and before the timeout).
  -- Defer or alt-switch instead of wasting a retry attempt against a
  -- deaf hop.
  local action_b, val_b = classify_blind(self,
                                          self.pending_tx.dst,
                                          self.pending_tx.next,
                                          self.pending_tx.alt_tried)
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      msg_id = captured_msg_id, next_hop = self.pending_tx.next,
      delay_ms = val_b, source = "rts_timeout",
    })
    self:log(string.format("tx_blind_defer (rts_timeout) msg=%d -> %s deferred %dms",
      captured_msg_id, name_of(self, self.pending_tx.next), val_b))
    self:after(val_b, function()
      rts_timeout_fire(self, captured_msg_id)
    end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      msg_id = captured_msg_id,
      from_next = self.pending_tx.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (rts_timeout) msg=%d %s -> %s",
      captured_msg_id, name_of(self, self.pending_tx.next), name_of(self, val_b)))
    self.pending_tx.next = val_b
    self.pending_tx.alt_tried = true
    self.pending_tx.retries_left = self.rts_max_retries
    tx_rts_retry(self, "blind_alt")
    return
  end

  if self.pending_tx.retries_left <= 0 then
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("rts_giveup msg=%d (max retries exhausted, dst=%s)",
      captured_msg_id, name_of(self, self.pending_tx.dst)))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  tx_rts_retry(self, "cts_timeout")
  -- (rts_retry emit happens inside tx_rts_retry — adds origin/payload there)
end
```

- [ ] **Step 4.4: Replace fixed timeout in `start_rts_timeout` with attempt-indexed backoff**

Locate `start_rts_timeout` around `:787`. Replace the entire function:
```lua
start_rts_timeout = function(self)
  if not self.pending_tx then return end
  if self.rts_timeout_handle then
    self:cancel(self.rts_timeout_handle)
    self.rts_timeout_handle = nil
  end
  local captured_msg_id = self.pending_tx.msg_id
  self.rts_timeout_handle = self:after(self.rts_timeout_ms, function()
    self.rts_timeout_handle = nil
    rts_timeout_fire(self, captured_msg_id)
  end)
end
```
with:
```lua
start_rts_timeout = function(self)
  if not self.pending_tx then return end
  if self.rts_timeout_handle then
    self:cancel(self.rts_timeout_handle)
    self.rts_timeout_handle = nil
  end
  -- F1 mitigation safety net: exponential backoff per retry attempt.
  -- attempt_idx = how many retries we've already burned on this msg_id.
  -- Fresh budget (issue_send / NACK alt / blind alt) → attempt_idx = 0
  -- → base timeout. Each subsequent retry doubles up to RTS_TIMEOUT_BACKOFF_CAP.
  local attempt_idx = self.rts_max_retries - self.pending_tx.retries_left
  local timeout_ms = rts_timeout_for_attempt(self.rts_timeout_ms, attempt_idx)
  local captured_msg_id = self.pending_tx.msg_id
  self.rts_timeout_handle = self:after(timeout_ms, function()
    self.rts_timeout_handle = nil
    rts_timeout_fire(self, captured_msg_id)
  end)
end
```

- [ ] **Step 4.5: Build + run integration — expect all pass except possibly s01**

```
cmake --build build -j 4
bash test/run_tests.sh
```
Expected:
- t01–t14, t14b, t10–t12 PASS (no concurrent flights → no behavior change)
- s01_dv_dual_sf may now PASS (if its existing one-delivery assertion still matches) or may produce different events that still satisfy the existing assertions

If s01 fails with the existing assertions, do **not** modify s01 yet — Task 7 handles that. Skip s01 by running the suite without it:
```
bash test/run_tests.sh test/t01_flooder.json test/t02_asymmetric_collision.json test/t03_drop_weak.json test/t05_lbt.json test/t06_sf_mismatch.json test/t06b_sf_rx_set.json test/t07_path_loss.json test/t08_dynamic_sf.json test/t09_link_snr.json test/t10_dv_beacons.json test/t11_dv_convergence.json test/t12_dv_single_hop.json test/t13_radio_busy_info.json test/t14_startup_jitter.json test/t14b_meta_src.json test/t99_perf_smoke.json
```
All should PASS.

- [ ] **Step 4.6: Commit**

```
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): wire F1 blind_until into issue/retry/timeout paths

Three call-site checks plus exponential rts_timeout backoff:

- issue_send: pre-RTS blind check; defer or alt-switch
- tx_rts_retry: per-retry blind check; defer or alt-switch with fresh budget
- rts_timeout_fire: post-timeout blind check before retry/giveup decision
- start_rts_timeout: timeout doubles per attempt up to RTS_TIMEOUT_BACKOFF_CAP

Closes the F1 finding (concurrent multi-hop flights at shared relays):
the second originator now learns the relay is busy from overheard CTS
and either alt-switches or defers, instead of grinding rts_timeout
retries against a deaf hop and emitting rts_giveup.
EOF
)"
```

---

## Task 5: Update `scenarios/dv_dual_sf.lua` header documentation

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (header block lines 1-280)

Documentation-only commit. No behavior change.

- [ ] **Step 5.1: Add "Blind window awareness" subsection**

In the header block at the top of `scenarios/dv_dual_sf.lua`, the structure flows:
```
-- ============================================================================
-- Routing (K=2 with alt) + busy NACK    <-- ~line 134
-- ============================================================================
... (Routing/NACK content, ending around :210) ...
--
-- ============================================================================
-- Findings & open improvements (notes for future work)    <-- ~line 211
-- ============================================================================
```
Insert the new subsection between the end of the Routing/NACK content (around `:210`) and the `Findings` divider (around `:211`). Place it as its own `==========`-bracketed block:
```lua
--
-- ============================================================================
-- F1 mitigation: receiver-blind-window awareness via passive CTS overhearing
-- ============================================================================
--
-- The data plane has an asymmetry: when relay R post-CTS-tx retunes to
-- data_sf to receive DATA, R is deaf on routing_sf for the duration of
-- (cts_to_data_gap + DATA airtime). Concurrent senders RTSing R during
-- this window land as drop_sf_mismatch — silent at runtime, no NACK, so
-- the sender wastes rts_max_retries before rts_giveup.
--
-- Mitigation: every node maintains self.blind_until[node_id] →
-- absolute_ms, populated by overhearing every CTS frame on routing_sf
-- (whether addressed to us or not). meta.src on the on_recv callback
-- gives us the CTS-sender's id; the CTS payload carries chosen_data_sf
-- so we can compute the upper-bound blind window:
--   blind_window = cts_to_data_gap_ms
--                + airtime(chosen_data_sf, max DATA frame)
--
-- Three call sites consult the table before TX'ing an RTS:
--   • issue_send       (proactive — first attempt)
--   • tx_rts_retry     (proactive — every retry)
--   • rts_timeout_fire (reactive — when timeout fires, re-check)
--
-- When the next-hop is blind, the decision is:
--   • have alt route + alt not yet tried   → switch to alt (free budget)
--   • else                                  → defer until blind window ends
--
-- Plus exponential backoff on rts_timeout_ms (×2 per attempt, capped at
-- ×RTS_TIMEOUT_BACKOFF_CAP) so the existing retry budget covers a full
-- receiver blind window even when the CTS itself is lost in flight and
-- the overhearing mechanism never fires.
--
-- New emits: blind_observed (every CTS overheard), tx_blind_defer
-- (every defer fired), tx_blind_alt (every alt-switch from blind state,
-- distinct from NACK-driven path_switch).
--
```

- [ ] **Step 5.2: Update F1 status**

Locate the `-- F1. Concurrent multi-hop flights collide at shared relay nodes` block (around `:215-222`). Add a `STATUS:` line at the end:
```lua
-- F1. Concurrent multi-hop flights collide at shared relay nodes
--     ... existing description ...
--
--     STATUS: addressed via passive CTS overhearing — see "F1 mitigation"
--     section above. Residual case: CTS lost in flight (overhearing
--     mechanism never fires). Partially covered by exponential
--     rts_timeout backoff (I-section), giving the receiver's
--     pending_rx_expiry time to fire and clear, after which a late
--     retry succeeds.
```

- [ ] **Step 5.3: Update F2 / F3 status**

For F2 (around `:223-231`), append:
```lua
--     STATUS: I1 (separate retry budgets) still future work.
```

For F3 (around `:232-238`), append:
```lua
--     STATUS: partially addressed by the exponential rts_timeout
--     backoff added with the F1 mitigation. Cumulative wait now
--     scales (122 → 244 → 488ms cap) instead of staying flat.
```

- [ ] **Step 5.4: Update I3 / I4 status**

For I3 (around `:255-266`), append:
```lua
--     STATUS: superseded by both NACK (already implemented) and the
--     F1 mitigation's passive blind_until table.
```

For I4 (around `:267-277`), append (if not already noted):
```lua
--     STATUS: superseded by NACK; the queue-extension path is no
--     longer needed because NACK already gives senders a busy-feedback
--     signal and the F1 blind_until lets them avoid the deaf-hop
--     entirely.
```

- [ ] **Step 5.5: Verify the file still parses (smoke build)**

```
cmake --build build -j 4
bash test/run_tests.sh test/t10_dv_beacons.json
```
Lua doesn't compile-fail on comment changes, but a fresh integration run confirms no accidental edit broke the file.

- [ ] **Step 5.6: Commit**

```
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
docs(dv_dual_sf): document F1 mitigation in header + update findings

Adds a "F1 mitigation" section describing the blind_until table, when
it's populated, and how it's consulted. Updates F1/F2/F3/I3/I4 status
notes to reflect what's been addressed.
EOF
)"
```

---

## Task 6: F1 reproducer test scenario `t15_concurrent_relay`

**Files:**
- Create: `test/t15_concurrent_relay.json`

Reuses `scenarios/dv_dual_sf.lua` directly — no new Lua file. Topology is a 5-node deterministic mesh with explicit links: two senders (s1, s2) both must traverse a single relay (rly) to reach their respective destinations (d1, d2).

- [ ] **Step 6.1: Create the test scenario JSON**

Create `test/t15_concurrent_relay.json`:
```json
{
  "_name": "t15_concurrent_relay",
  "_desc": "F1 reproducer: two senders share a single relay; second sender's RTS would land in the relay's data_sf RX window. With the blind_until mitigation, the second sender either alt-switches or defers (no alt here → defers); both flights deliver. Verifies blind_observed + tx_blind_defer + both delivered.",
  "simulation": {
    "duration_ms": 20000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 200,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "s1",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9], "beacon_period_ms": 1000 } },
    { "name": "rly", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9], "beacon_period_ms": 1000 } },
    { "name": "d1",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9], "beacon_period_ms": 1000 } },
    { "name": "s2",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9], "beacon_period_ms": 1000 } },
    { "name": "d2",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9], "beacon_period_ms": 1000 } }
  ],
  "topology": {
    "links": [
      { "from": "s1",  "to": "rly", "snr": 10.0, "rssi": -75.0, "bidir": true },
      { "from": "rly", "to": "d1",  "snr": 10.0, "rssi": -75.0, "bidir": true },
      { "from": "s2",  "to": "rly", "snr": 10.0, "rssi": -75.0, "bidir": true },
      { "from": "rly", "to": "d2",  "snr": 10.0, "rssi": -75.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 6000, "node": "s1", "command": "send d1 first-flight"  },
    { "at_ms": 6030, "node": "s2", "command": "send d2 second-flight" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "d1", "emit_type": "delivered", "value": "first-flight"  },
    { "type": "script_emit_contains", "node": "d2", "emit_type": "delivered", "value": "second-flight" },
    { "type": "script_emit_contains", "node": "s2", "emit_type": "blind_observed", "value": "" },
    { "type": "script_emit_contains", "node": "s2", "emit_type": "tx_blind_defer", "value": "" }
  ]
}
```

Notes on the design:
- 6000 ms gives DV ~6 beacon rounds at 1000 ms period — every node has full rt before commands fire.
- `beacon_period_ms: 1000` and `allowed_data_sfs: [9]` keep durations short.
- s2's command at 6030 ms is timed to land during rly's CTS-tx → DATA-rx window: rly's CTS tx-end is roughly `6000 + RTS_air(SF8) + processing ≈ 6000 + 22 + few ms ≈ 6025 ms`, then rly is blind for ~80 ms (SF9 max-payload airtime) until ~6105 ms. s2's send at 6030 ms hits issue_send while blind_until[rly] is set → defers ~75 ms → succeeds.
- No alt route exists in this topology (rly is the only path to d2 from s2), so the defer branch is exercised. To exercise the alt-switch branch, add a redundant path in a follow-up test.

- [ ] **Step 6.2: Run t15 — expect PASS**

```
bash test/run_tests.sh test/t15_concurrent_relay.json
```
Expected: PASS.

- [ ] **Step 6.3: Inspect events to confirm the mechanism fired**

```
echo "=== blind_observed at s2 ==="
grep '"node":3.*blind_observed' test/t15_concurrent_relay_events.ndjson
echo "=== tx_blind_defer at s2 ==="
grep '"node":3.*tx_blind_defer' test/t15_concurrent_relay_events.ndjson
echo "=== delivered count ==="
grep '"emit_type":"delivered"' test/t15_concurrent_relay_events.ndjson | wc -l
echo "=== rts_giveup count (should be 0) ==="
grep '"emit_type":"rts_giveup"' test/t15_concurrent_relay_events.ndjson | wc -l
```
Expected:
- `blind_observed` lines from s2 (node id 3) ≥ 1
- `tx_blind_defer` lines from s2 ≥ 1
- `delivered` count = 2
- `rts_giveup` count = 0

If any of these don't match, investigate before proceeding. Common issues:
- DV not converged by 6000 ms → bump command time to 8000 ms or increase warmup.
- s2's send timing missed the blind window (e.g., issued just-before vs just-after CTS) → adjust the 30 ms offset.

- [ ] **Step 6.4: Commit**

```
git add test/t15_concurrent_relay.json
git commit -m "$(cat <<'EOF'
test(t15): add F1 reproducer — concurrent relay scenario

5-node deterministic topology with two senders sharing one relay.
Second sender's command lands during the relay's data_sf RX window;
asserts blind_observed, tx_blind_defer, and that both flights deliver.
The minimal end-to-end test for the F1 blind_until mitigation.
EOF
)"
```

---

## Task 7: Update `s01_dv_dual_sf.json` expectations

**Files:**
- Modify: `scenarios/s01_dv_dual_sf.json` (`expect[]` block at end)

- [ ] **Step 7.1: Add the new expectations**

Locate the `"expect": [ ... ]` block at the end of `scenarios/s01_dv_dual_sf.json`. The current last entries are:
```json
    { "type": "script_emit_contains", "node": "n05", "emit_type": "rts_tx",  "value": "\"origin\":4" },
    { "type": "script_emit_contains", "node": "n13", "emit_type": "delivered", "value": "hello-world" }
  ]
}
```

Replace those last two lines (and the closing `]` / `}`) with:
```json
    { "type": "script_emit_contains", "node": "n05", "emit_type": "rts_tx",  "value": "\"origin\":4" },
    { "type": "script_emit_contains", "node": "n13", "emit_type": "delivered", "value": "hello-world"  },
    { "type": "script_emit_contains", "node": "n15", "emit_type": "delivered", "value": "hello-second" },
    { "type": "script_emit_contains", "node": "n06", "emit_type": "blind_observed", "value": "" }
  ]
}
```

Note: `"value": ""` for `blind_observed` matches any data — we just need at least one such emit at n06 (proves the mitigation fired during s01).

- [ ] **Step 7.2: Run s01 — expect PASS**

```
bash test/run_tests.sh scenarios/s01_dv_dual_sf.json
```
Expected: PASS.

- [ ] **Step 7.3: Inspect telemetry**

```
echo "=== rts_giveup count globally ==="
grep '"emit_type":"rts_giveup"' scenarios/s01_dv_dual_sf_events.ndjson | wc -l
echo "=== delivered count ==="
grep '"emit_type":"delivered"' scenarios/s01_dv_dual_sf_events.ndjson | wc -l
echo "=== blind_observed count ==="
grep '"emit_type":"blind_observed"' scenarios/s01_dv_dual_sf_events.ndjson | wc -l
echo "=== tx_blind_defer + tx_blind_alt count ==="
grep -E '"emit_type":"(tx_blind_defer|tx_blind_alt)"' scenarios/s01_dv_dual_sf_events.ndjson | wc -l
```
Expected:
- `rts_giveup` = 0
- `delivered` = 2 (hello-world + hello-second)
- `blind_observed` ≥ 1
- `tx_blind_defer` + `tx_blind_alt` combined ≥ 1

If `rts_giveup` is non-zero or `delivered` < 2, investigate before committing.

- [ ] **Step 7.4: Commit**

```
git add scenarios/s01_dv_dual_sf.json
git commit -m "$(cat <<'EOF'
test(s01): require both concurrent sends deliver + blind_observed

Updates expect[] to reflect the F1 mitigation: hello-second now
delivers at n15 (previously tolerated as 'known failure'), and at
least one blind_observed emit must fire at n06 (proves the
overhearing mechanism is exercised by this scenario).
EOF
)"
```

---

## Task 8: Final regression sweep

This task verifies the full set is green and produces no surprises.

- [ ] **Step 8.1: Run native suite — expect all pass**

```
bash test/native/build_test.sh
```

- [ ] **Step 8.2: Run full integration suite — expect all pass**

```
bash test/run_tests.sh
```
All `t*.json` (t01–t14, t14b, t15, t99) and all `s*.json` (s01–s05 if they exist; s02–s05 may need full run time but should not have changed behavior since they don't have concurrent sends) should pass.

- [ ] **Step 8.3: Run webapp pytest — expect all pass**

```
cd webapp && python -m pytest tests/ && cd ..
```
The webapp doesn't depend on protocol behavior — this is a regression check that nothing in the runtime ABI broke schema parsing.

- [ ] **Step 8.4: Compare s01 events.ndjson before vs after**

If you saved a baseline before starting (recommended), diff key counts:
```
# Baseline expectations (from spec):
# rts_giveup: ≥ 1 → 0
# drop_sf_mismatch (runtime event, type=drop_sf_mismatch): several → much fewer
# blind_observed: 0 (didn't exist) → > 0
# tx_blind_defer ∪ tx_blind_alt: 0 → ≥ 1
# delivered: 1 → 2

grep -c '"type":"drop_sf_mismatch"' scenarios/s01_dv_dual_sf_events.ndjson
grep -c '"emit_type":"rts_giveup"'  scenarios/s01_dv_dual_sf_events.ndjson
grep -c '"emit_type":"blind_observed"' scenarios/s01_dv_dual_sf_events.ndjson
grep -cE '"emit_type":"(tx_blind_defer|tx_blind_alt)"' scenarios/s01_dv_dual_sf_events.ndjson
grep -c '"emit_type":"delivered"' scenarios/s01_dv_dual_sf_events.ndjson
```
Expected: drop_sf_mismatch reduced (not necessarily zero — beacons still trigger it on data_sf-tuned receivers), rts_giveup = 0, blind_observed > 0, tx_blind_defer + tx_blind_alt ≥ 1, delivered = 2.

- [ ] **Step 8.5: No final commit needed**

All work was committed task-by-task. Verify a clean tree:
```
git status
```
Should show no uncommitted changes.

---

## Spec-Coverage Self-Review (post-write checklist)

This is filled in by the plan author, not the executor:

- [x] **Spec § Mechanism overview** → Tasks 2/3/4 (state, prelude, three call sites) + Task 4 (backoff)
- [x] **Spec § Components — Runtime** → Task 1
- [x] **Spec § Components — Lua state** → Task 2.4
- [x] **Spec § Components — Helpers** → Tasks 2.1–2.3
- [x] **Spec § Overhearing prelude** → Task 3
- [x] **Spec § Integration call sites** → Tasks 4.1–4.3
- [x] **Spec § Backoff in start_rts_timeout** → Task 4.4
- [x] **Spec § New emit types** → fire from Tasks 3 (blind_observed) and 4 (tx_blind_defer / tx_blind_alt)
- [x] **Spec § Lua documentation updates** → Task 5
- [x] **Spec § Testing — t15_concurrent_relay** → Task 6
- [x] **Spec § Testing — s01 expectations** → Task 7
- [x] **Spec § Testing — Regression coverage** → Task 8
- [x] **Spec § Implementation ordering** → matches task order 1→8
