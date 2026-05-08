# Reactive (AODV-flavored) Routing for LoRa Mesh — Design

Status: design (awaiting plan)
Author: 2026-05-08 session

## Goal

Replace the proactive distance-vector routing plane in `dv_dual_sf.lua`
with **on-demand reactive routing** so the protocol scales to dense
networks and narrow bandwidths without choking the duty-cycle budget on
beacon overhead.

**Forcing event:** `s03_seattle_medium` at BW=62.5 kHz, 138 nodes,
delivers 3/50 messages (6%). The same scenario at BW=250 kHz delivers
47/50 (94%) — same protocol, same routing, BW change alone. Capacity
analysis (`tools/capacity_summary.py`) shows 96% of all airtime at
BW=62.5 is consumed by DV beacons; per-node beacon utilization is ~8% of
the 1% duty-cycle budget. The data plane never gets a chance.

**Success bar:** `r03_seattle_medium.json` (clone of s03 using the new
protocol, BW=62.5, same commands) reaches **≥45 / 50 deliveries (≥90%)**,
matching s03's own performance at BW=250.

This is the same data plane (RTS/CTS/DATA/ACK + F1 mitigation +
duty-cycle pre-check) running over a fundamentally different routing
plane. The data plane is preserved verbatim.

## Strategy

**New file `scenarios/reactive_routing.lua`** (clone of `dv_dual_sf.lua`
with the routing plane swapped). Existing scenarios continue to use
`dv_dual_sf.lua` and are not modified. A separate set of test scenarios
(`r02–r05_seattle_*` plus targeted `t17/t18/t19_reactive_*`) exercises
the new protocol.

We do not unify the two protocols, do not add a config flag to switch,
do not migrate existing scenarios. If reactive proves itself in
production, deprecation of DV is a separate future decision.

## Wire format

Routing-plane frames added by reactive (data plane R/C/D/K/N is
unchanged). All multi-byte integers are little-endian.

```
J  JOIN              "J" + my_id(2) + boot_seq(1)                                  4 B
W  WELCOME           "W" + my_id(2) + dst_of_join(2) + snr_bucket_3b|res_5b        6 B
Q  RREQ              "Q" + originator(2) + target(2) + bcast_id(1)
                         + flags_4b|hop_count_4b + dst_seq(1)
                         + blacklist[0..3] × 2B                                    8..14 B
P  RREP              "P" + originator(2) + target(2) + next_hop(2)
                         + dst_seq(1) + hops_4b|snr_bucket_3b|res_1b               9 B
E  RERR              "E" + bad_dst(2) + bad_next_hop(2) + dst_seq_known(1)         6 B
```

### Field semantics

- **`my_id` is uint16 little-endian.** Sized for >256 nodes ahead of need.
- **`boot_seq`** uint8: incremented on every fresh boot of this node. Helps neighbors detect "this node restarted; flush my routes through it."
- **SNR bucket** is 3 bits, 8 quantized 5 dB bins:
  ```
  bucket = clamp(0..7, floor((snr_db + 20) / 5))
  bucket   range (dB)        SF demod context
  0        < −20             below SF12 floor
  1        −20 to −15        SF12 only
  2        −15 to −10        SF11/SF12
  3        −10 to −5         SF10
  4        −5 to 0           SF9
  5        0 to +5           SF8
  6        +5 to +10         SF7
  7        ≥ +10             SF5/SF6
  ```
- **`flags_4b|hop_count_4b`** RREQ control byte:
  - 4-bit `hop_count` (max 15). RREQ is dropped at next forward when `hop_count == 15`.
  - 4 flag bits. Currently used:
    - `BIT0_BLACKLIST_PRESENT` (1 = the next 0..6 bytes are 2-byte blacklist node ids; length implicit from frame length)
    - `BIT1_BOOT_DISCOVERY` (reserved — flag a freshly-booted RREQ if we add prioritization later)
    - bits 2–3 reserved
- **`dst_seq` in RREQ** is the originator's last-known dst_seq for the target (0 if never seen). Receivers (potential RREP responders from cache) only reply if their cached `dst_seq >= q.dst_seq`.
- **`hops_4b|snr_bucket_3b|res_1b` in RREP** packs path metadata in one byte: 4-bit hops on this path (max 15), 3-bit worst-link SNR bucket along the path, 1 reserved bit.
- **`dst_seq_known` in RERR** is the last `dst_seq` we'd seen for `bad_dst`. Receivers bump their own `routes[bad_dst].dst_seq = dst_seq_known + 1` so any subsequent RREP with stale `dst_seq` is rejected.

### Future tag-encoding optimization

The 1-byte ASCII tag is convenient for tooling but wastes airtime. In a
production protocol we'd pack the command into 4 bits (15 frame types
fit in 4 bits with room — current set is 11). **Deferred.** First
implementation keeps 1-byte tags for readability.

## Per-node state

```lua
-- Sequence numbers
self.dst_seq        = 1   -- my own monotonic destination seq, bumped on routing changes
self.next_bcast_id  = 1   -- my own RREQ broadcast id (8-bit, wraps)
self.boot_seq       = 1   -- bumped on every fresh boot of this node

-- 1-hop neighborhood. Populated by JOIN/WELCOME RX + passive overhear of
-- any frame carrying meta.src.
self.neighbors = {}
-- neighbors[node_id] = { snr_bucket, last_seen_ms, snr_db_raw (debug) }

-- Route cache — multi-hop destinations.
self.routes = {}
-- routes[dst_id] = {
--     next_hop, hops, dst_seq, snr_bucket,
--     installed_ms, last_used_ms, expires_at_ms,
-- }

-- RREQ dedup + reverse-path state.
self.seen_rreqs = {}
-- seen_rreqs["origin|bcast_id"] = {
--     reverse_next, hop_count, installed_ms, expires_at_ms,
-- }

-- Sends queued waiting for route discovery.
self.pending_sends = {}
-- pending_sends[dst] = list of {payload, user_text, origin_seq, queued_at_ms, attempt}

-- K=2 on-demand recovery state per dst.
self.route_recovery = {}
-- route_recovery[dst] = { attempts, blacklist, last_attempt_ms, expires_at_ms }

-- WELCOME suppression timers (per joining node we plan to welcome).
self.pending_welcomes = {}
-- pending_welcomes[joiner_id] = timer_handle
```

**Preserved verbatim from `dv_dual_sf.lua`** (no changes):

- `self.pending_tx`, `self.pending_rx` (data-plane half-duplex state)
- `self.tx_stash` (LBT/duty-cycle on-radio-busy retry)
- `self.tx_queue` (originator + forwarder queue with `previous_hop` for the F1 forward-loop guard)
- `self.last_acked_from` (RTS-retry dedup at receiver)
- `self.blind_until` (F1 mitigation — populated by overheard CTS or NACK)
- `self.seen_origins` (end-to-end origin-seq dedup at delivery)
- `self.duty_cycle*` and the `check_duty_cycle` helper

**Constants (config-driven, with sane defaults):**

| Constant | Default | Purpose |
|---|---|---|
| `routing_sf` | 8 | SF for all routing-plane frames (J/W/Q/P/E) AND data-plane control (R/C/K/N). DATA still uses negotiated `data_sf`. |
| `allowed_data_sfs` / `allowed_sf_bitmap` | unchanged | per-link adaptive SF for DATA, unchanged from dv_dual_sf |
| `rreq_timeout_ms` | 5000 | wait for first RREP before considering the round failed |
| `route_ttl_ms` | 300000 | route cache lifetime (5 min) |
| `seen_rreq_ttl_ms` | 30000 | bcast_id dedup window |
| `welcome_window_ms` | 1000 | how long after JOIN we wait for WELCOMEs before declaring boot complete |
| `welcome_backoff_min/max_ms` | 100 / 800 | jittered WELCOME reply delay (with overhear-suppression) |
| `max_recovery_attempts` | 3 | RREQ rounds before `route_giveup` |
| `recovery_backoff_min/max_ms` | 50 / 300 | jittered delay between recovery RREQ rounds |
| `route_recovery_reset_ms` | 10000 | how long after a `route_giveup` before fresh attempts to same dst start clean |

## Protocol mechanisms

### Send entry

```
on_command "send <dst> <text>":
  origin_seq = next_origin_seq++
  full_payload = pack_origin_seq(seq) || user_text
  if dst in self.neighbors:
      route = {next_hop=dst, hops=1, ...}                # 1-hop, no RREQ
  elif dst in self.routes and not_expired(routes[dst]):
      route = self.routes[dst]                           # cache hit
  else:
      enqueue (full_payload, origin_seq) into pending_sends[dst]
      issue_rreq(dst, blacklist=[])                      # discovery
      return queued
  if route:
      enqueue tx_queue with {origin=self.id, dst, payload, previous_hop=nil}
      become_free()                                      # drains via existing data plane
```

### RREQ flooding

`issue_rreq(target, blacklist)`:

1. `bid = self.next_bcast_id++`
2. Frame: `Q + my_id + target + bid + (flags|hop_count=0) + last_known_dst_seq[target] + blacklist`
3. Mark `self.seen_rreqs[my_id|bid] = {reverse_next = nil, ...}` so we don't reflect our own
4. `self:after(rreq_timeout_ms, function() rreq_timeout(target, bid) end)`
5. TX via `tx_flood(...)`. Drops on duty-cycle/LBT block; subsequent retry comes from `rreq_timeout`.

`on_recv 'Q'` (forwarding):

1. Parse. If `meta.src` not in earshot, drop (defensive).
2. **Dedup:** if `(originator, bcast_id)` is in `seen_rreqs`, drop silently.
3. **Hop limit:** if `hop_count == 15`, drop.
4. **Record reverse path:** `seen_rreqs[origin|bid] = {reverse_next = meta.src, hop_count, installed_ms, expires_at_ms}`.
5. **Decide reply or forward:**
   - If `q.target == self.id` → `issue_rrep(...)` (we're the destination, always reply, blacklist doesn't apply to self-reply).
   - Else if `intermediate_can_reply(self.routes[q.target], q)` returns true → `issue_rrep(...)` from cache.
   - Else → `q.hop_count++`, re-broadcast via `tx_flood` with randomized 0–50 ms jitter.

### RREP unicast (reverse path)

`issue_rrep(originator, target, hops, snr_bucket, dst_seq)`:

1. Frame: `P + originator + target + my_id_as_next_hop + dst_seq + hops|snr_bucket`
2. Look up `seen_rreqs[origin|bid]`. The `reverse_next` field is the next hop back. If absent, drop with `rrep_dropped_no_reverse` emit (rare: dedup entry expired before RREP).
3. TX via `tx_with_retry` with label `RREP` (added to `RETRY_ELIGIBLE`).

`on_recv 'P'`:

1. Parse. If `meta.src != recorded reverse_next`, drop (defensive).
2. **If `p.originator == self.id`:** we're the target.
   - Apply AODV freshness (see below). If accepted: install `self.routes[p.target]`, cancel `rreq_timeout` for this target, emit `route_install`, drain `pending_sends[p.target]` into `tx_queue`, trigger `become_free`. Clear `route_recovery[p.target]`.
3. **Else (forwarder):** look up reverse-path next hop. Update `p.hops++`, update `p.snr_bucket` if our incoming hop's bucket is lower than current, re-tx via `tx_with_retry`.

### AODV freshness

```
accept_route(new, existing):
    if existing == nil: return true
    if new.dst_seq > existing.dst_seq: return true
    if new.dst_seq == existing.dst_seq and new.hops < existing.hops: return true
    return false

intermediate_can_reply(routes[target], rreq):
    return routes[target] exists
       and not_expired(routes[target])
       and routes[target].dst_seq >= rreq.dst_seq
       and routes[target].next_hop not in rreq.blacklist
```

Strict monotonicity of `dst_seq` is the loop-prevention invariant: a
cycle would require two nodes each thinking they have a fresher route to
the same destination, which contradicts the invariant.

### RERR upstream invalidation

Triggered by `rts_giveup`, `data_ack_giveup`, or RERR-received-and-was-using-this-route.

`emit_rerr(bad_dst, bad_next_hop, dst_seq_known)`:

1. Frame: `E + bad_dst + bad_next_hop + dst_seq_known`
2. Sent on routing_sf to `pending_tx.previous_hop` (unicast, not flood).
3. TX via `tx_with_retry` (label `RERR`, retry-eligible).

`on_recv 'E'`:

1. If `self.routes[e.bad_dst]` exists with `next_hop == e.bad_next_hop`:
   - Bump local `routes[bad_dst].dst_seq = e.dst_seq_known + 1`
   - Mark `expires_at_ms = now`
   - Emit `route_invalidate`
   - If we have an in-flight or pending flow toward `e.bad_dst` (own `previous_hop` recorded), propagate RERR to OUR upstream

### K=2 on-demand recovery

State: `self.route_recovery[dst] = {attempts, blacklist, last_attempt_ms, expires_at_ms}`.

Lifecycle on failure (RERR for cached dst, RREQ-timeout, or own rts_giveup):

1. Init or update `route_recovery[dst]`: `attempts++`, append `failed_next_hop` to `blacklist` (cap 3).
2. If `attempts >= max_recovery_attempts (3)`:
   - Emit `route_giveup`
   - Clear `pending_sends[dst]`
   - `self:after(route_recovery_reset_ms, function() route_recovery[dst] = nil end)`
3. Else:
   - `delay = rand(recovery_backoff_min, recovery_backoff_max)`
   - `self:after(delay, function() issue_rreq(dst, blacklist=route_recovery[dst].blacklist) end)`
4. RREP arrives during recovery → install route, clear `route_recovery[dst]`, drain pending sends.

### Boot / new-node discovery

```
on_init finishes:
  self:after(rand(0, join_jitter_ms), function() send_join(self) end)
  self:after(welcome_window_ms, function() boot_complete(self) end)
```

`send_join`: TX `J + my_id + boot_seq` via `tx_flood`.

`on_recv 'J'`:

1. Parse `(joiner_id, boot_seq)`.
2. Update `self.neighbors[joiner_id]` with measured snr_bucket.
3. Refresh expiry on any `routes[]` whose `next_hop == joiner_id` (their boot_seq may have changed; conservatively trim to 60s instead of full TTL).
4. Schedule WELCOME with jittered backoff: `delay = rand(welcome_backoff_min, welcome_backoff_max)`.
5. Suppression: if before our timer fires we overhear another node's WELCOME for the same `joiner_id`, cancel ours.

`send_welcome(joiner_id, snr_bucket)`: TX `W + my_id + joiner_id + snr_bucket`.

`on_recv 'W'`:

1. Cancel any pending WELCOME for `joiner_id` (suppression).
2. If `joiner_id == self.id`: this is FOR us. Record `self.neighbors[welcomer_id]` including `their_view_of_us = snr_bucket_their_view`. Emit `welcome_rx`.
3. Else: just record `welcomer_id` as a 1-hop neighbor.

`boot_complete`: emit `boot_complete` with neighbor count.

**JOIN-loss handling:** if JOIN is lost in flight, the new node has no neighbors initially. First send → RREQ flood → broadcast is heard by neighbors (RREQ is also broadcast) → they record us as neighbor passively from `meta.src` on the RREQ. Reactive flow naturally repairs.

**Asymmetric-link caveat:** boot/JOIN flow assumes symmetric links. Will need a confirmation pass when the orchestrator adds asymmetric link simulation (see "Follow-up work" below).

## Test scenarios

### t17 — reactive basic flow

`test/t17_reactive_basic.json`: 4-node line `alice ↔ bob ↔ carol ↔ dave` with explicit links, deterministic. alice sends to dave at t=5000.

Expectations:
- `boot_complete` at all 4 nodes
- `welcome_rx` at every node
- `rreq_tx` at alice, `rrep_rx` at alice
- `route_install` at alice with `dst=dave hops=3`
- `delivered` at dave
- exactly one bcast_id from alice
- zero `route_giveup`

### t18 — runtime node activation

`test/t18_reactive_join.json`: 4 nodes, topology `alice↔carol↔dave` and `alice↔bob↔dave`. carol has `config.activate_at_ms = 10000`, stays silent until then.

Phase 1 (t=0–10s): alice sends "msg1" → routes via bob → 2 hops → delivered.

Phase 2 (t=10s): carol sends JOIN → alice + dave learn carol. alice sends "msg2" → RREQ → carol or bob both reply (1-hop to dave) → delivered.

Expectations:
- `delivered` at dave for both `payload="msg1"` and `payload="msg2"`
- `boot_complete` at carol after t=10000
- `neighbor_learned` events at alice + dave for carol after t=10000
- carol's JOIN timestamp > 10000

`config.activate_at_ms` is a script-side concept — `reactive_routing.lua` reads it and gates the JOIN scheduler. **No orchestrator change.**

### t19 — K=2 on-demand recovery

`test/t19_reactive_blacklist_retry.json`: 5 nodes (alice, relay1, relay2, dave, …) with two parallel relays from alice to dave. relay1 is "dead" (`config.tx_fail_prob = 1.0` if alive, else use a very-low-SNR link as a substitute failure mode).

Without recovery: first RREP wins, DATA fails on relay1, flight dies.

With recovery: rts_giveup at alice → recovery initialized with `blacklist=[relay1]` → second RREQ excludes relay1 → relay2 responds → DATA delivered.

Expectations:
- `route_giveup` does NOT fire
- `route_invalidate` for `dst=dave next_hop=relay1`
- second RREQ from alice has different `bcast_id`
- RREP from relay2
- `delivered` at dave

**Caveat:** if `tx_fail_prob` is not active in the runtime (Y2-todo), substitute with an SNR-based failure (link dead by physics).

### r02 / r03 / r04 / r05 — Seattle scenarios on reactive

Clones of `s02_seattle_sparse.json`, `s03_seattle_medium.json`,
`s04_seattle_dense.json`, `s05_seattle_very_dense.json` with every
`"script": "scenarios/dv_dual_sf.lua"` replaced by
`"script": "scenarios/reactive_routing.lua"`. Same topology, same
commands, same radio params (so r03 stays at BW=62.5).

**Headline assertion:**
`python3 tools/capacity_summary.py --compare scenarios/s03_seattle_medium.json EVENTS_DV scenarios/r03_seattle_medium.json EVENTS_REACTIVE`
shows reactive ≥ 45 / 50 deliveries (vs DV's 3 / 50) at BW=62.5.

In-JSON `expect[]` covers a subset of specific deliveries plus
event-count floors. The 90% threshold is verified manually via
`capacity_summary.py` since the test runner can't filter `script_emit`
by `emit_type`.

### Regression coverage

All existing tests stay on `dv_dual_sf.lua` and continue passing: t01–t16, s01–s05, t14b, t15. Reactive routing must:
- Not modify `dv_dual_sf.lua`
- Not require any runtime API change beyond what's already in place

## Risks

1. **First-flight latency at BW=62.5 is ~5 s for typical 5-hop paths**
   (full 15-hop worst case ~20 s). Subsequent flights to the same dst
   hit the cache and skip the RREQ — first-flight cost is a one-time
   penalty per (originator, target) pair within `route_ttl_ms`. App
   layer should expect this; not a regression vs current behavior at
   BW=62.5 where flights frequently die after similar wallclock time.

2. **RREQ flood storms in dense networks.** A 138-node mesh with
   simultaneous send commands could trigger overlapping RREQ floods.
   Mitigations: jittered re-broadcast (0–50 ms), `seen_rreqs` dedup,
   intermediate-node-replies-from-cache (the AODV optimization),
   duty-cycle pre-check on `tx_flood`.

3. **Stale routes after topology change.** Standard AODV failure mode.
   `route_ttl_ms = 300000` (5 min) bounds staleness. RERR propagation +
   sequence-number bumping prevent subtly stale routes from
   re-installing.

4. **Asymmetric links** (real-world common; see follow-up work below).
   Current orchestrator's symmetric path-loss masks this. Protocol
   design assumes symmetric — when orchestrator adds asymmetric, the
   boot/JOIN flow needs a confirmation pass (currently a `welcome_rx`
   at A from B implies A→B works; doesn't actually verify B→A).

5. **`tx_fail_prob` plumbing may not be active**, breaking the t19 test
   design. Implementation phase confirms; substitute with
   SNR-based-dead-link if needed.

## Out of scope (this iteration)

- Multi-channel operation (frequency hopping) — separate axis of
  capacity gain, orthogonal to routing.
- Asymmetric link simulation in orchestrator (tracked separately, see
  Follow-up work).
- Compressed wire format (4-bit tags, etc.) — deferred for readability.
- Cross-protocol interop (a node running DV can't talk to one running
  reactive in the same scenario).
- Local route repair at intermediate forwarders (AODV "expanding ring
  search"). Originator owns all retry policy; forwarders just RERR.
- K=3 routing (simultaneous primary + alt + alt2). K=2 on-demand is the
  agreed approach; K=3 would be a future evolution if K=2 proves
  insufficient.

## Follow-up work

1. **Orchestrator: asymmetric link simulation.** Real LoRa networks
   show A→B SNR ≠ B→A SNR (TX-power, antenna, environment). Current
   path-loss model is symmetric. Track separately in
   `core/topology/JsonConfig.h`'s `LinkDef`, the path-loss model, and
   `SimController` link lookup. Memory note saved at
   `memory/project_asymmetric_links.md`.

2. **Asymmetric-link confirmation pass in reactive_routing.lua.** Once
   the orchestrator supports asymmetric, extend the boot flow: after
   sending WELCOME, A expects ANY reverse-direction frame from B
   within a window. If absent, mark neighbor as "JOIN-heard but uplink
   unverified."

3. **Compressed tag encoding (4-bit command).** Collapse the 1-byte
   ASCII tag into 4 bits sharing a byte with other small fields. Saves
   a few bytes per RREQ flood; meaningful at large network sizes.

4. **Local route repair at intermediates.** AODV-style expanding ring
   search at the failed forwarder before propagating RERR. Could
   reduce recovery latency in some cases. Defer until measured need.

5. **Compare reactive vs DV side-by-side in webapp.** Extend
   `capacity_summary.py` into a webapp tab that diffs two events.ndjson
   runs (timeline overlay, per-flight breakdown, etc.).

## Implementation ordering hints

A sensible plan structure:

1. **Bootstrap `reactive_routing.lua`** as a verbatim copy of
   `dv_dual_sf.lua` with the routing plane stubbed out (no beacons, no
   `pack_beacon`, no `rt_*`). Verify the data plane still TXes correctly
   if a route is hand-installed.

2. **Per-node state + helpers.** Add `self.routes`, `self.neighbors`,
   `self.seen_rreqs`, `self.pending_sends`, `self.route_recovery`,
   `self.dst_seq`, `self.next_bcast_id`, `self.boot_seq`. Add
   `bucket_of_snr` and packing/parsing helpers for J/W/Q/P/E.

3. **Boot flow (J + W).** Implement JOIN broadcast, WELCOME with
   jittered suppression, neighbor table population. Test t17's
   `boot_complete` + `welcome_rx` assertions.

4. **Single-hop send.** `on_command` falls through to the data plane
   directly when target is in `self.neighbors`. Test on t17's smallest
   topology.

5. **RREQ flood + RREP unicast.** Multi-hop discovery. `on_recv 'Q'`
   forwarding logic, `on_recv 'P'` route installation, AODV freshness.
   Full t17 passes.

6. **Pending sends drain.** Couple `on_command` queueing to `on_recv 'P'`
   route installation. Sends issued before route discovery resolve when
   RREP arrives.

7. **RERR + recovery state machine.** `route_recovery[dst]`,
   blacklisted RREQ retries, bounded attempts, `route_giveup`. t19
   passes.

8. **Runtime node activation hook.** `config.activate_at_ms` script-side
   gate. t18 passes.

9. **Seattle clones.** Generate r02–r05 from s02–s05 (single sed-like
   transformation). Run r03 capacity benchmark. Iterate timing
   constants if 90% bar isn't met first try.

10. **Header pseudocode flow.** Per the recurring user-feedback
    convention, `reactive_routing.lua` gets a flow block at the top
    matching the style of `dv_dual_sf.lua`'s header.

## Spec author's notes for the planner

- The bulk of `reactive_routing.lua` (data plane) is a clone — don't
  re-derive RTS/CTS/DATA/ACK logic; copy verbatim from
  `dv_dual_sf.lua` and audit the diff.
- The `previous_hop` plumbing already in `dv_dual_sf.lua` is critical
  for RERR propagation upstream. Verify it's preserved in the clone.
- `tx_flood` already handles duty-cycle pre-check + LBT defer + flood
  skip. RREQ broadcasts use it as-is. RREP/RERR unicast use
  `tx_with_retry`.
- The `RETRY_ELIGIBLE` set needs `RREP` and `RERR` added (alongside
  CTS/CTS-dup/DATA/ACK/K-dup/NACK).
- New emit types: `boot_complete, neighbor_learned, welcome_rx,
  rreq_tx, rreq_rx, rreq_forward, rreq_drop_dedup, rreq_drop_hop_limit,
  rrep_tx, rrep_rx, rrep_forward, rrep_dropped_no_reverse,
  route_install, route_invalidate, route_giveup, rerr_tx, rerr_rx`.
- File size budget: target ≤ 1500 LOC for `reactive_routing.lua`. The
  data plane copy is ~1200 LOC of `dv_dual_sf.lua`; routing-plane
  rewrite is ~300–500 LOC net.
