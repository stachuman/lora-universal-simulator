# F1: Receiver-Blind-Window Mitigation via CTS Overhearing — Design

Status: design (awaiting plan)
Author: 2026-05-07 session

## Goal

Eliminate `rts_giveup` failures in `s01_dv_dual_sf` caused by F1 — the
finding documented at `scenarios/dv_dual_sf.lua:215-222`:

> When the first flight (e.g. n05→n13) is mid-flight and an intermediate
> node (e.g. n02) is on data_sf RX expecting CTS/DATA, a second flight
> (e.g. n06→n15) routed via the same intermediate will keep losing its
> RTS to drop_sf_mismatch — the busy node simply isn't listening on
> routing_sf. Result: rts_giveup at the second originator after
> rts_max_retries.

**Success bar:** s01's two concurrent sends (n05→n13 at t=45000ms,
n06→n15 at t=46000ms) both reliably emit `delivered`, with zero
`rts_giveup` events anywhere in the run.

This is the minimum bar agreed in brainstorming. Higher-concurrency
stress (4-6 simultaneous sends) is explicitly out of scope for this
iteration.

## Mechanism overview

A per-node table `blind_until[node_id] → absolute_ms` tracks when each
1-hop neighbor will be deaf on `routing_sf` — i.e., in its `data_sf` RX
window between sending its CTS and receiving the DATA that follows.

The table is populated by **passively overhearing CTS frames**. CTS
goes out on `routing_sf` and is broadcast (LoRa is a broadcast medium).
Every node that has the CTS-sender as a viable next-hop is, by routing
construction, a 1-hop neighbor and overhears the CTS. Coverage matches
exactly the set of would-be senders that could otherwise hit F1.

The table is consulted at three points where we'd otherwise blindly RTS
a now-known-blind node (the fourth potential point — `become_free` queue
drain — gets the check transitively, since it calls `issue_send`). When
the chosen next-hop is blind:

1. **Alt-switch**: if `rt[dst].alt` exists and `pending_tx.alt_tried` is
   false, re-target the RTS to `alt.next_hop` immediately. Reuses the
   existing NACK alt-path branch.
2. **Defer**: schedule the issue/retry to fire `blind_until - now + 1`
   ms in the future. The blind window is short (~250 ms worst case at
   SF9 data) so deferring is acceptable.

A modest exponential backoff is layered onto `rts_timeout_ms` so the
existing retry budget covers a full receiver blind window even in the
edge case where the CTS is lost end-to-end and the overhearing
mechanism never fires.

**Zero new wire frames. CTS frame format unchanged.** One small runtime
primitive added: `meta.src` exposed in `on_recv`.

## Components

### Runtime (C++) — minimal plumbing

`meta.src` exposes the sender's node id to the receiving script. Currently
`meta` carries `{snr, rssi, link_id, recv_ms}` but `link_id` is hardcoded
to 0 (`SimController.cpp:649,741`).

Files touched:
- `orchestrator/runtime/LuaHost.h` — add `int src_id` parameter to
  `callOnRecv`.
- `orchestrator/runtime/LuaHost.cpp` — set `meta["src"] = src_id` in the
  body around `:254-258`.
- `orchestrator/runtime/ScriptedNode.{h,cpp}` — pass-through the new
  parameter.
- `orchestrator/runtime/SimController.cpp` — both `_nodes[rcv]->onRecv(...)`
  call sites already have `tx.sender_id` in scope; pass it through.

**Backward compatibility:** Lua scripts that don't read `meta.src` are
unaffected (Lua tables tolerate extra fields). No existing scenarios
break; no events change schema.

**Native test harness impact:** native C++ tests that synthesize
`onRecv` calls directly need the new parameter. Trivial addition; one
fixed value per test (e.g., `-1` for "no source" or the actual sender
where the test cares).

### Lua (`scenarios/dv_dual_sf.lua`) — main logic

#### State (added in `on_init`)

```lua
self.blind_until = {}    -- {node_id → absolute_ms}
-- per-pending_tx attempt counter is read off pending_tx.retries_left
-- combined with rts_max_retries; no separate field needed.
```

#### Constants

```lua
-- Backoff cap: timeout doubles per retry but caps at 4× base. With
-- s01's default base ≈ 122 ms (SF8 RTS+CTS airtime), the timeouts walk
-- 122, 244, 488, 488, 488, 488, 488, 488 — total wallclock budget
-- across rts_max_retries=8 attempts ≈ 3.3 s, comfortably past the
-- ~250 ms blind window for SF9 data and the ~1.5 s worst case for
-- SF12 data with max payload.
local RTS_TIMEOUT_BACKOFF_CAP = 4
```

#### Helpers

```lua
local function is_blind(self, node_id)
  local until_ms = self.blind_until[node_id]
  if until_ms == nil then return false, 0 end
  local now = self:now()
  if until_ms <= now then
    self.blind_until[node_id] = nil    -- opportunistic prune
    return false, 0
  end
  return true, until_ms - now
end

-- Decision: returns one of:
--   "ok"                   — proceed normally
--   "alt", new_next_hop    — switch to alt route (caller updates pending_tx)
--   "defer", delay_ms      — schedule retry/issue after delay_ms
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

#### Overhearing prelude in `on_recv 'C'`

Insert before the existing `pending_tx`-matching check (around
`dv_dual_sf.lua:1363`):

```lua
if tag == "C" then
  local c = parse_cts(frame)
  if not c then return end

  -- Overhearing: every CTS — addressed to us or not — tells us its
  -- sender will be deaf on routing_sf for one DATA-RX window. Record
  -- the upper-bound end time so future RTS attempts toward this
  -- sender either alt-switch or defer.
  if meta.src then
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
        node = meta.src,
        until_ms = end_ms,
        chosen_data_sf = c.chosen_data_sf,
      })
    end
  end

  -- ... existing pending_tx-matching logic unchanged
```

#### Integration call sites

**`issue_send` (proactive, before generating msg_id):**

```lua
local primary_next = entry.primary.next_hop
local action, val = classify_blind(self, dst_id, primary_next, false)
if action == "defer" then
  self:emit("tx_blind_defer", {
    origin = origin, dst = dst_id, next_hop = primary_next, delay_ms = val,
  })
  -- Re-queue and schedule a re-drain. Item is re-inserted at the head so
  -- ordering is preserved.
  table.insert(self.tx_queue, 1, {
    origin = origin, dst_id = dst_id, dst_name = dst_name,
    payload = payload, user_text = user_text, origin_seq = origin_seq,
  })
  self:after(val, function() become_free(self) end)
  return
elseif action == "alt" then
  self:emit("tx_blind_alt", {
    origin = origin, dst = dst_id,
    from_next = primary_next, to_next = val,
  })
  primary_next = val
  -- pending_tx.alt_tried set below to true once we set up pending_tx
end

local mid = gen_msg_id(self)
self.pending_tx = {
  ...,
  next         = primary_next,
  alt_tried    = (action == "alt"),
  ...
}
```

**`tx_rts_retry` (proactive, before re-tx):**

```lua
local px = self.pending_tx
local action, val = classify_blind(self, px.dst, px.next, px.alt_tried)
if action == "defer" then
  self:emit("tx_blind_defer", { msg_id = px.msg_id, delay_ms = val,
    next_hop = px.next })
  self:after(val, function() tx_rts_retry(self, reason) end)
  return
elseif action == "alt" then
  self:emit("tx_blind_alt", {
    msg_id = px.msg_id, from_next = px.next, to_next = val,
  })
  px.next = val
  px.alt_tried = true
  px.retries_left = self.rts_max_retries  -- fresh budget on alt switch
end
-- ... existing rts retransmit
```

**`rts_timeout_fire` (reactive, when timer fires):**

Insert immediately after the `pending_rx ~= nil` defer guard (around
`:710`) and before the `retries_left <= 0` giveup check:

```lua
if self.pending_rx ~= nil then ... return end

-- New: receiver may have just become blind (we overheard a CTS for them
-- to a different sender between our RTS-tx and now). Defer rather than
-- waste a retry attempt against a deaf hop.
local action, val = classify_blind(self, self.pending_tx.dst,
                                    self.pending_tx.next,
                                    self.pending_tx.alt_tried)
if action == "defer" then
  self:emit("tx_blind_defer", { msg_id = captured_msg_id, delay_ms = val,
    next_hop = self.pending_tx.next, source = "rts_timeout" })
  self:after(val, function() rts_timeout_fire(self, captured_msg_id) end)
  return
elseif action == "alt" then
  self:emit("tx_blind_alt", { msg_id = captured_msg_id,
    from_next = self.pending_tx.next, to_next = val })
  self.pending_tx.next = val
  self.pending_tx.alt_tried = true
  self.pending_tx.retries_left = self.rts_max_retries
  tx_rts_retry(self, "blind_alt")
  return
end

-- existing retries_left check + tx_rts_retry call
```

**`become_free` (queue drain):**

No new check needed — `become_free` calls `issue_send` which now has the
guard. The queue head simply waits; no need to rotate to other items.

#### Backoff in `start_rts_timeout`

Replace the fixed timeout with a per-attempt computed value. The
attempt index = `rts_max_retries - pending_tx.retries_left`:

```lua
start_rts_timeout = function(self)
  if not self.pending_tx then return end
  if self.rts_timeout_handle then ... end
  local captured_msg_id = self.pending_tx.msg_id
  local attempt = self.rts_max_retries - self.pending_tx.retries_left
  local timeout_ms = rts_timeout_for_attempt(self.rts_timeout_ms, attempt)
  self.rts_timeout_handle = self:after(timeout_ms, function()
    self.rts_timeout_handle = nil
    rts_timeout_fire(self, captured_msg_id)
  end)
end
```

Note: NACK alt-switch (`on_recv 'N'` branch) already resets
`retries_left = rts_max_retries`. The blind alt-switch above does the
same. Both reset attempt index to 0 → fresh `base_ms` timeout on the
new path. Correct semantics.

#### New emit types

| Emit | Source | Fields | Purpose |
|---|---|---|---|
| `blind_observed` | every CTS overheard | `node, until_ms, chosen_data_sf` | telemetry; proves the mechanism is hearing CTS |
| `tx_blind_defer` | `issue_send`/`tx_rts_retry`/`rts_timeout_fire` | `msg_id, delay_ms, next_hop, [source]` | proves a defer fired |
| `tx_blind_alt` | same | `msg_id, from_next, to_next` | proves an alt-switch was triggered by blind state (distinct from NACK-driven `path_switch`) |

### Lua documentation updates

The header comment block at the top of `dv_dual_sf.lua` and the F1–I4
findings list need updates:

1. **Top-of-file header**: a new `Blind window awareness` subsection
   describing the `blind_until` table, when it's populated, and how
   it's consulted. Add to the existing summary alongside the routing /
   NACK / dedup blocks.
2. **F1**: append `STATUS: addressed via passive CTS overhearing — see
   blind_until table; residual case is CTS-loss in flight, partially
   covered by exponential rts_timeout backoff.`
3. **F2/F3**: update to note that the backoff change partially
   addresses F3 (timeout no longer one-shot-sized) but I1 (separate
   retry budgets) remains future work.
4. **I3 (NACK / busy-feedback)**: mark as superseded by both NACK
   (already implemented) and now blind_until passive overhearing.
5. **I4 (drop rts_rejected_busy in favor of queue)**: unchanged;
   already superseded by NACK.

## Data flow

```
   sender S1                relay R                  potential sender S2
   ────────                 ───────                  ──────────────────
   RTS────────────────────→ on_recv 'R'              (silent)
                            pending_rx = S1
                            CTS────────────────→ ... overheard ...
                            set_rx_sf(data_sf)        on_recv 'C'
                            (R now BLIND on             meta.src = R
                             routing_sf)                blind_until[R] = now + 250ms
                                                       emit blind_observed

   ... cts_to_data_gap ...                           (queued send to R)

   DATA──────────────→ on_recv 'D'                    issue_send(dst, R)
                       set_rx_sf(routing_sf)            classify_blind → "alt" or "defer"
                       ACK──────→ ...                   emit tx_blind_defer or tx_blind_alt
                                                        defer or switch to alt path
                                                        — AVOIDS the F1 trap entirely
```

## Edge cases / error handling

1. **Stale `blind_until` entries**: pruned opportunistically on access
   (`is_blind` deletes expired entries before returning). Bounded set
   (≤ peer count). No periodic sweep needed.

2. **CTS-dup overheard** (when receiver re-sends CTS via the
   `rts_rx_dup` path): the same overhearing prelude fires.
   `blind_until[R]` is updated to the new (later) end time via the
   `end_ms > prev` check. Correct: the receiver's window genuinely
   extended.

3. **CTS lost in flight**: blind_until not updated → no defer/alt
   triggered → fall back to current F1 behavior. Exponential rts_timeout
   backoff gives the originator more wallclock budget before
   `rts_giveup`. The receiver's `pending_rx_expiry_fire` eventually
   clears its state (after ~`gap + max_data_air`), at which point a
   late retry succeeds. Strict improvement over today.

4. **Self-blind detection**: irrelevant. We never RTS ourselves
   (next_hop is always a peer in `rt`).

5. **In-flight RTS toward a now-known-blind hop**: covered by the
   `rts_timeout_fire` blind check. When our RTS landed pre-blind and
   the receiver was free, it answers normally — no defer triggered.
   When our RTS landed during blind (drop_sf_mismatch silently), the
   timer fires; we now have blind_until populated (we overheard the
   triggering CTS during our wait); defer or alt-switch.

6. **Concurrent blind windows from same node**: blind_until is
   single-valued. If R sends two CTSes back-to-back (forwarder
   finishes one flight, starts the next), the later end-time wins via
   `end_ms > prev`. Correct.

7. **Scenarios with `allowed_data_sfs = [12]` only**: the worst-case
   blind window is ~1.5 s at SF12 max payload. Backoff cap at 4× base
   ≈ 488 ms × 8 retries ≈ 3.9 s — covers it. Defer mechanism handles
   the queue properly: it just waits.

8. **Routing convergence races**: a node may consult `blind_until` for
   a neighbor before any CTS has been overheard. `is_blind` returns
   false; behavior unchanged. The mechanism only kicks in once the
   blind state has been observed.

## Testing

### New scenario `t15_concurrent_relay`

Files: `test/t15_concurrent_relay.json`, `test/t15_concurrent_relay.lua`.

**Topology**: 5 nodes A, R, B, C, D. Explicit `topology.links` (no path
loss randomness):
- A↔R, R↔B, R↔D, C↔R, A↔C
- A and C cannot reach each other for the data path; both must go via R
- B and D are leaves at R

**Lua flow header** (per memory feedback — every scenarios/*.lua gets a
flow block at top):

```lua
-- t15_concurrent_relay flow:
--   t=0..1500: DV converges; R has all peers, A/C/B/D learn rt
--   t=2000:    A → B via R    (forces R into pending_rx; CTS broadcast)
--   t=2050:    C → D via R    (would-be F1 victim)
--   t=2050+ε:  C overhears R's CTS → blind_until[R] populated
--              C's send either defers ~250ms or alt-switches
--              (no alt route exists in this topology → defers)
--   t=~2300:   R completes A→B flight, returns to routing_sf
--   t=~2350:   C's RTS to R now succeeds → C→D delivers
```

**Expectations**:
- `delivered hello-AtoB` at B
- `delivered hello-CtoD` at D
- `blind_observed` emit at C (proves overhearing fired)
- `tx_blind_defer` emit at C (proves the defer fired)
- Zero `rts_giveup` events
- Zero `drop_sf_mismatch` runtime events

### Update `s01_dv_dual_sf.json`

Current expectations check beacon convergence + first send delivery.
Extend:
- `delivered hello-second` at n15
- At least one `blind_observed` event somewhere in the run
- Zero `rts_giveup` events globally

### Regression coverage

- **Native suite** (`bash test/native/build_test.sh`): callers of
  `LuaHost::callOnRecv` updated; native tests get the new param.
  Existing test_multi_sf_reception adapted.
- **Integration** (`bash test/run_tests.sh`): t01–t14 must continue to
  pass. Older scenarios that don't trigger concurrent flights should
  see new `blind_observed` events whenever a CTS is overheard, but no
  `tx_blind_defer` or `tx_blind_alt` events. Event counts otherwise
  unchanged.
- **Webapp pytest** (`cd webapp && python -m pytest tests/`):
  unaffected — schemas unchanged, just new emit_type strings.

### Telemetry verification post-implementation

Inspect events.ndjson for s01 before/after the change:

| Metric | Before | After |
|---|---|---|
| `rts_giveup` count | ≥ 1 (n06) | 0 |
| `drop_sf_mismatch` runtime events | several | 0 (or near-zero — only residual CTS-loss cases) |
| `blind_observed` count | 0 (event didn't exist) | > 0 at n06 and other neighbors of mid-flight relays |
| `tx_blind_defer` ∪ `tx_blind_alt` count | 0 | ≥ 1 at n06 |
| `delivered` count | 1 (hello-world only) | 2 (hello-world + hello-second) |

## Out of scope

- **Higher concurrency** (4-6 simultaneous sends with stricter PDR
  bar). Future iteration; may need K=3 routing + airtime scheduling.
- **CTS-loss-injection deterministic test**. The simulator doesn't
  currently support targeted frame-drop injection. Reasonable
  follow-up if F1's residual case becomes important.
- **F2/I1 (separate retry budgets for CTS-loss vs LBT-deferral)**.
  Independent improvement, not blocking F1 fix.
- **Alt freshness expiry**. Independent improvement to routing.
- **busy_for_ms cap on sender side** (NACK robustness). Independent.
- **Receiver-side proactive BSY broadcast frame** (Approach A2 in
  brainstorming). Rejected as more expensive (extra airtime per hop)
  with no real coverage benefit over passive overhearing — both are
  broadcast on routing_sf, so reach is identical.

## Risks

1. **Over-eager defer when blind_until is conservative**: the
   blind window estimate uses `max_payload_bytes` upper bound, not the
   actual DATA size. Real-world flights with short payloads (~10
   bytes) finish faster than budgeted; the sender waits longer than
   necessary. Tolerable: payload sizes in current scenarios are small
   so the over-estimate is small (~50 ms at SF9). Not on the success
   bar.

2. **Backoff lengthens worst-case `rts_giveup` time**: with
   exponential timeout, the giveup deadline shifts from
   `8 × 122 ms ≈ 1 s` to `~3.3 s` (at the SF8/SF9 s01 settings). For
   applications expecting fast failure, this is a regression.
   Mitigation: the giveup is still the end-of-the-line failure;
   deliveries that succeed do so on the first or second attempt either
   way. Not believed to be a problem.

3. **Lua hot-path cost**: `is_blind` is called on every issue_send
   and every retry. Constant-time table lookup; negligible.

4. **`meta.src` being added but not consumed by other scenarios**:
   benign — Lua tables tolerate extra fields.

## Implementation ordering

1. Runtime: add `meta.src` to `LuaHost`, thread through
   `SimController`, update native test harnesses. Run native + run_tests
   to confirm no regression.
2. Lua: add `is_blind` / `classify_blind` / `rts_timeout_for_attempt`
   helpers + `blind_until` state; wire into the four call sites; add
   new emit types. Update header documentation block. Run integration
   tests.
3. New `t15_concurrent_relay` scenario + expectations. Run.
4. Update `s01_dv_dual_sf.json` expectations. Run.
5. Smoke s01 events.ndjson manually to verify telemetry expectations.
