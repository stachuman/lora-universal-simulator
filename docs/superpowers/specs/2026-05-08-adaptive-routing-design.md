# Adaptive (Quiet/Busy-Throttled) DV Routing — Design

Status: design (awaiting plan)
Author: 2026-05-08 session

## Goal

Evolve `scenarios/dv_dual_sf.lua` — the proactive distance-vector protocol — into an adaptive hybrid that:

1. **Throttles beacons during channel-busy periods** so beacon overhead stops dominating airtime when traffic is heavy.
2. **Falls back to reactive RREQ for genuinely-unknown destinations** so newly-arrived nodes (or nodes whose routes never propagated) can still be reached without proactive flooding.
3. **Runs against realistic simulation conditions** — a long enough warmup that routes have actually converged before user traffic measurement begins, mimicking real-world deployments where networks operate for hours/days/weeks before any specific message.

This replaces the failed pure-reactive direction (see `2026-05-08-reactive-routing-design.md` and the `worktree-reactive-routing` branch's outcome: r03 at BW=62.5 still delivered 3/50 because RREQ flooding became the new bottleneck after eliminating beacon overhead). Real LoRa-mesh networks aren't either-extreme: they need proactive maintenance during quiet periods AND on-demand discovery for unknowns, with the channel-activity signal driving the choice.

**Success bar:** `a03_seattle_medium.json` (clone of s03 with longer warmup + adaptive protocol) reaches **≥45 / 50 deliveries (≥90%)** at BW=62.5, matching s03's 94% at BW=250.

**Forcing observation:** Real networks operate adaptively because of regulatory + physical constraints. ETSI 1% duty cycle + busy channel = no choice but to throttle. The design encodes what real LoRa firmware (Meshtastic, MeshCore) implicitly does already.

## Strategy

**Single file evolution: `scenarios/dv_dual_sf.lua` modified in-place.** All existing mechanisms preserved: K=2 alt routing, NACK, F1 mitigation (blind_until), duty cycle pre-check, viability-tier route_strictly_better, previous_hop loop guard, F1's classify_blind, the data plane (RTS/CTS/DATA/ACK).

Three additions:
- **Quiet/busy detector** for adaptive beacon throttling.
- **Reactive RREQ/RREP/RERR** for unknown-destination fallback.
- **AODV destination sequence numbers** on RREQ-installed routes (DV-installed routes get `dst_seq=0`).

The reactive_routing.lua artifact stays as a separate branch baseline (not merged); it serves as a known-failed-at-scale reference for what pure-reactive looks like under our duty cycle constraint.

**Out of scope (deferred):**
- Hot-state init (per-node pre-populated routes from JSON) — user chose long-warmup approach instead
- Multi-channel operation
- Compressed 4-bit tag encoding
- Local route repair at intermediate forwarders
- Adaptive `quiet_threshold_ms` (e.g., grows under sustained busy) — fixed-default for first iteration

## Wire format additions

The data-plane R/C/D/K/N frames stay verbatim. New:

```
Q  RREQ          "Q" + originator(2) + target(2) + bcast_id(1)
                     + flags_4b|hop_count_4b + dst_seq(1)
                     + blacklist[0..3] × 2B                                  8..14 B
P  RREP          "P" + originator(2) + target(2) + next_hop(2)
                     + dst_seq(1) + hops_4b|snr_bucket_3b|res_1b             9 B
E  RERR          "E" + bad_dst(2) + bad_next_hop(2) + dst_seq_known(1)       6 B
```

Same encoding as `reactive_routing.lua`. No `J`/`W` (JOIN/WELCOME) — DV beacons cover boot discovery: a beacon broadcast is implicitly "I'm here, here's my routing table."

`SF_DEMOD_THRESHOLD` already exists; `bucket_of_snr(snr_db) → 0..7` ported from reactive_routing.

## Per-node state additions

```lua
-- Quiet/busy detector for adaptive beacon throttling.
self.last_rx_routing_sf_ms = self:now()       -- updated at top of every on_recv
self.quiet_threshold_ms    = config.quiet_threshold_ms or 30000

-- Reactive RREQ fallback state (typically idle — only fires for genuinely
-- unknown destinations, e.g., new node arrivals post-warmup).
self.dst_seq        = 1                        -- own monotonic destination seq
self.next_bcast_id  = 1                        -- own RREQ broadcast id (8-bit)
self.boot_seq       = config.boot_seq or 1
self.seen_rreqs     = {}                       -- (origin|bcast_id) → reverse-path
self.pending_sends  = {}                       -- queued waiting for RREQ
self.route_recovery = {}                       -- per-dst attempt + blacklist

-- Reactive timing constants
self.rreq_timeout_ms          = config.rreq_timeout_ms          or 5000
self.rreq_max_hops            = config.rreq_max_hops            or 8
self.seen_rreq_ttl_ms         = config.seen_rreq_ttl_ms         or 30000
self.max_recovery_attempts    = config.max_recovery_attempts    or 3
self.recovery_backoff_min_ms  = config.recovery_backoff_min_ms  or 50
self.recovery_backoff_max_ms  = config.recovery_backoff_max_ms  or 300
self.route_recovery_reset_ms  = config.route_recovery_reset_ms  or 10000
```

`self.rt[]` shape extended: `rt[dst].primary` gains optional `dst_seq` field. DV-installed entries get `dst_seq = 0`. RREQ-installed entries get the seq from the RREP. AODV freshness comparison applies only when displacing an RREQ-installed entry; DV's existing `route_strictly_better` continues to govern beacon-derived updates.

## Protocol mechanisms

### Channel-activity detector

At the top of `on_recv`, before any tag dispatch:

```lua
function on_recv(self, frame, meta)
  if #frame == 0 then return end
  -- Update detector regardless of frame type or recipient. Any successful
  -- RX (broadcast or unicast) means the channel was just busy.
  self.last_rx_routing_sf_ms = self:now()
  -- existing tag dispatch follows...
end
```

Note: data-plane frames on `data_sf` don't fire `on_recv` while we're tuned to `routing_sf` (the runtime drops them as drop_sf_mismatch — they don't reach the script). That's fine — DATA on data_sf is bracketed by RTS/CTS/ACK on routing_sf, which DO update the detector.

### Beacon throttle (modifies `beacon_fire`)

```lua
local function beacon_fire(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    -- existing skip (this node mid-flight); reschedule below
    self:log("beacon_tx skipped (busy in data exchange)")
  else
    local since_rx = self:now() - self.last_rx_routing_sf_ms
    if since_rx < self.quiet_threshold_ms then
      self:emit("beacon_skipped_busy", {
        since_rx_ms = since_rx, threshold_ms = self.quiet_threshold_ms,
      })
      self:log(string.format("beacon_tx skipped (channel busy: last RX %dms ago)",
        since_rx))
    else
      -- existing beacon emission path: pack_beacon, emit beacon_tx,
      -- tx_flood, advance offset
      ...
    end
  end
  -- existing reschedule (jittered, warmup-vs-operational period)
  self:after(rand(period * 4 // 5, period * 6 // 5 + 1),
             function() beacon_fire(self) end)
end
```

The detector and existing pending_tx/pending_rx skip layer cleanly: the script's own in-flight state is checked separately from the channel-activity state.

### Reactive RREQ fallback (cache miss handling)

`issue_send` modification: when `rt[dst_id]` is nil and we're the originator, queue into `pending_sends[dst]` and `issue_rreq` instead of emitting `send_no_route`:

```lua
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, origin_seq, previous_hop)
  local entry = self.rt[dst_id]
  if not entry then
    if origin == self.id then
      self.pending_sends[dst_id] = self.pending_sends[dst_id] or {}
      table.insert(self.pending_sends[dst_id], { ... })
      self:emit("send_pending_route", { ... })
      issue_rreq(self, dst_id, {})
      return
    end
    -- Forwarder cache-miss: emit RERR upstream + drop.
    self:emit("send_no_route", { ... })
    if previous_hop ~= nil then
      emit_rerr_to_upstream(self, dst_id, 0)
    end
    return
  end
  -- existing happy path (entry exists, classify_blind, RTS, etc.)
  ...
end
```

`on_recv 'Q'` (RREQ flooding): same as `reactive_routing.lua` — dedup `(originator, bcast_id)`, hop-limit at `self.rreq_max_hops` (default 8), reverse-path recording, decide reply (target or intermediate-can-reply with cached `rt[].primary` + AODV freshness + blacklist) vs forward with hop_count++ + jitter.

`on_recv 'P'` (RREP): originator installs into `rt[].primary` via `accept_route` freshness gate; clears `route_recovery[target]`; drains `pending_sends[target]` into `tx_queue`. Forwarders install forward route locally too (so data plane can route through them) AND forward RREP toward originator via reverse-path lookup.

`on_recv 'E'` (RERR): if `rt[bad_dst].primary.next_hop == bad_next_hop`, bump local `dst_seq`, mark expired (set `last_seen_ms` such that `route_strictly_better` would reject from re-promoting). If we were forwarding to `bad_dst`, propagate RERR further upstream.

### AODV freshness (applies to RREQ-installed routes)

```lua
local function accept_route(new, existing)
  if existing == nil then return true end
  -- DV-installed routes (dst_seq == 0) always lose to RREQ-installed.
  -- This is intentional: an RREQ response is recent + authoritative.
  if (existing.dst_seq or 0) == 0 and new.dst_seq > 0 then return true end
  if new.dst_seq > (existing.dst_seq or 0) then return true end
  if new.dst_seq == (existing.dst_seq or 0) and new.hops < existing.hops then return true end
  return false
end

local function intermediate_can_reply(self, target, rreq)
  local entry = self.rt[target]
  if entry == nil then return false end
  local r = entry.primary
  -- Stale beacon-derived routes (dst_seq=0) shouldn't intermediate-respond
  -- to an RREQ — better to let the destination itself respond with a
  -- fresh dst_seq.
  if (r.dst_seq or 0) == 0 then return false end
  if r.dst_seq < rreq.dst_seq then return false end
  for _, b in ipairs(rreq.blacklist) do
    if r.next_hop == b then return false end
  end
  return true
end
```

This makes the protocol's behavior cleanly layered:
- DV beacons populate routes during warmup + quiet periods (`dst_seq = 0`)
- RREQ fallback runs only when DV hasn't reached us yet (`rt[dst] = nil`)
- RREQ-installed routes always trump DV-installed routes (when both are about the same destination)
- AODV freshness governs subsequent RREQ-vs-RREQ updates

**Route aging (RREQ-installed entries):** an RREQ-installed `rt[dst].primary` carries `expires_at_ms = installed_ms + route_ttl_ms` (default 5 min, same as reactive_routing). On TTL expiry, the entry's `dst_seq` resets to `0` (the route stays usable but is downgraded to "DV-equivalent" priority). Subsequent DV beacons can then refresh it via the existing `route_strictly_better` path. This prevents stale RREQ-installed routes from indefinitely blocking DV updates. DV-installed routes have no expiry — they're refreshed continuously by beacons in steady state and replaced by accept_route's RREQ-precedence rule when an RREQ comes in.

### Recovery state machine

When `rts_timeout_fire` or `ack_timeout_fire` exhausts retries at the originator: bump `route_recovery[dst].attempts`, blacklist the failed next-hop, re-queue the payload, schedule a backoff RREQ retry. Bounded at `max_recovery_attempts (3)` before final `route_giveup`. Identical structure to reactive_routing's recovery; carries over verbatim.

## Simulation realism

Capacity scenarios get longer `warmup_ms` so the network's beacons converge before user traffic fires. During warmup, beacons fire at the existing fast cadence (5s default). After warmup, beacons fire at slow cadence (5min default) AND get throttled by the quiet/busy detector.

Per-scenario warmup adjustments (capacity tests only — small unit tests stay short):

| Scenario | Current `warmup_ms` | New `warmup_ms` |
|---|---|---|
| s01–s05 (existing dv_dual_sf) | 30000 | unchanged |
| `a02_seattle_sparse.json` (new) | — | 300000 (5 min) |
| `a03_seattle_medium.json` (new) | — | 600000 (10 min) |
| `a04_seattle_dense.json` (new) | — | 600000 (10 min) |
| `a05_seattle_very_dense.json` (new) | — | 900000 (15 min) |

`a0X` files clone `s0X` with the longer `warmup_ms`, the same protocol script (`scenarios/dv_dual_sf.lua` after this evolution), explicit `quiet_threshold_ms = 30000` per node, and command timestamps shifted by `+warmup_ms` so user traffic fires AFTER warmup completes.

The system self-organizes to avoid beacon collisions during warmup: each node's quiet/busy detector throttles its own beacons when overhearing others. Result: beacon airtime ramps up gradually, the network converges, and we're testing realistic steady-state behavior — not cold-start stress.

## Test scenarios

### t23 — Adaptive beacon throttle unit test

`test/t23_quiet_throttle.json`: 3-node line `alice ↔ bob ↔ carol` with `warmup_ms = 10000` and `quiet_threshold_ms = 5000` (tight to make assertions deterministic).

```
Phase 1 (t=0–10s warmup): beacons fire at fast cadence; nodes learn each other.
Phase 2 (t=10s+): network is naturally quiet; beacons fire at slow cadence but unthrottled.
Phase 3 (t=15s): alice sends to carol — RTS/CTS/DATA/ACK fire, neighbors observe channel busy.
Phase 4 (t=20s+): bob's beacon timer fires during/after the data exchange.
                  If within quiet_threshold of recent RX, beacon_skipped_busy emit fires.
                  Once channel quiet again, next beacon round fires normally.
```

Assertions:
- `beacon_skipped_busy` at bob (during/after data exchange — at least one)
- `delivered` at carol with the test payload
- `beacon_tx` at bob fires both before AND after the data exchange (proves throttle is gating, not breaking)

### t24 — RREQ fallback for unknown destination

`test/t24_unknown_dst_rreq.json`: 3-node line `alice ↔ bob ↔ carol` with `warmup_ms = 5000`. carol has `activate_at_ms = 10000` — silent until t=10s.

```
Phase 1 (t=0–5s warmup): alice + bob exchange beacons; alice's rt has bob.
                         carol is silent — alice has no rt[carol] yet.
Phase 2 (t=10s): carol activates, broadcasts beacon → alice + bob learn carol.
Phase 3 (t=15s): alice sends to carol. By now alice's rt may already have carol
                 (from phase 2's beacon). If so, no RREQ fires — direct cache hit.
                 If not (timing-dependent), RREQ fires, carol RREPs, install + deliver.
```

Assertions:
- `delivered` at carol
- (Optional) Either `route_install` from RREQ flow, or normal beacon-driven delivery — both are acceptable; the test verifies the RREQ fallback exists and works under timing-dependent conditions.

A more deterministic RREQ-fallback test: clone `t18_reactive_join.json`'s structure (the one in the worktree, not the user's current uncommitted t18). Suppress phase-2's beacon arrival window with longer activate_at_ms relative to send timing.

### a03 — Adaptive Seattle medium (capacity headline)

`scenarios/a03_seattle_medium.json`: clone of `s03_seattle_medium.json` with:
- `warmup_ms = 600000` (10 min)
- `simulation.duration_ms = 1525000` (s03's 925000 + 600000 warmup extension)
- All command `at_ms` values shifted by +600000 (so first send is at t=635851 instead of t=35851)
- All node configs gain `"quiet_threshold_ms": 30000`

Manual capacity assertion via `tools/capacity_summary.py --compare scenarios/s03_seattle_medium.json EVENTS_DV scenarios/a03_seattle_medium.json EVENTS_ADAPTIVE` — expect a03 ≥45/50 delivered, vs s03's 3/50 baseline at BW=62.5.

### a02, a04, a05 — Adaptive Seattle other densities

Same script-and-warmup transform applied to s02/s04/s05. Run for sanity but headline is a03.

### Existing-test impact

- t01–t14, t14b, t15, t16, t99: PASS unchanged (small networks, low traffic, throttle rarely fires)
- s01: warmup unchanged at 30s; the throttle's effect is incidental (fewer beacons during the few-second concurrent send window). Expected PASS.
- s02–s05: warmup unchanged; throttle reduces beacon airtime during data periods (improvement); tests assert delivery, not beacon counts. Expected PASS or improvement.

Risk: any pre-existing test that asserts `beacon_tx count >= N` may regress under throttle. Pre-implementation step: scan test JSONs for such assertions and flag.

## Spec coverage / scope check

This spec covers:
- One file modification: `scenarios/dv_dual_sf.lua`
- 4 new scenario files: `a02–a05_seattle_*.json`
- 2 new test scenario files: `t23_quiet_throttle.json`, `t24_unknown_dst_rreq.json`
- No C++/orchestrator/Python changes

It does NOT cover:
- Hot-state init (deferred per user choice; long warmup instead)
- Asymmetric link simulation (recently added on main; orthogonal)
- Multi-channel operation
- Local route repair at intermediate forwarders
- Adaptive `quiet_threshold_ms`
- 4-bit tag compression

## Risks

1. **Warmup duration tuning.** If `a03`'s 10-min warmup isn't enough for 138-node convergence, capacity falls short. Mitigation: increase to 30 min and re-measure. The mechanism is sound; convergence-time is a fitting parameter.

2. **Quiet-threshold tuning.** If 30s is too aggressive (suppresses beacons even during rare data activity), routes age out → `rt_full` regresses. If 30s is too loose (beacons fire even during data), the throttle has no effect. Default fits the SF8/BW=62.5 round-trip times (~700ms per frame); tuning happens during a03 capacity benchmarks.

3. **DV-vs-RREQ route-shape interaction.** Addressed by the route-aging design above (RREQ-installed routes downgrade `dst_seq` to 0 at TTL expiry, allowing DV to re-take). Residual concern: in a network where RREQ fires often (very dynamic topology), the constant "RREQ-installed → age out → DV-overwritten → RREQ-installed → ..." cycle could oscillate routes for a single destination. Not expected to be a problem under steady-state operation.

4. **Test scenario number clashes.** The user is concurrently working on tests t17–t22 on main (uncommitted). This spec uses t23/t24 to avoid clash; verify before implementation.

5. **Existing dv_dual_sf.lua is being modified by the user concurrently.** The implementation will start from the current main HEAD's dv_dual_sf.lua, not the worktree's older copy. The added mechanisms must coexist with whatever recent changes are on main (asymmetric-link diagnostic state, etc.).

## Follow-up work

1. **Hot-state init runtime mechanism** — if warmup approach doesn't meet capacity targets even at 30+ minutes, fall back to runtime hook for pre-populated routes.
2. **Adaptive `quiet_threshold_ms`** — grow under sustained busy, shrink under long quiet. First iteration uses a fixed default.
3. **Local route repair at intermediate forwarders** — AODV-style expanding ring search before propagating RERR. Could reduce recovery latency in dense meshes.
4. **Asymmetric link interaction** — once orchestrator-side asymmetric simulation is fully landed (in progress on main), revisit the quiet/busy detector to make sure it handles "I think it's quiet but my downlink to neighbor X is broken" correctly.
5. **Re-running r02–r05 against the adaptive protocol** — the reactive_routing.lua artifact stays as a separate branch baseline; eventually we'd merge the adaptive protocol back into main and retire the reactive branch (or keep it as a research baseline).

## Implementation ordering hints

1. **Detector + state init** — `last_rx_routing_sf_ms`, `quiet_threshold_ms`, RREQ state tables. No behavior change.
2. **Top-of-on_recv detector update** — first behavior change; subsequent beacon throttle hooks into this.
3. **`beacon_fire` throttle** — emit `beacon_skipped_busy`; verify with t23.
4. **Wire format helpers + RREP/RERR additions to RETRY_ELIGIBLE.**
5. **`issue_send` cache-miss → RREQ fallback path.**
6. **`on_recv 'Q' / 'P' / 'E'` handlers + AODV freshness on `rt[].primary`.**
7. **Recovery state machine hooks in `rts_timeout_fire` / `ack_timeout_fire`.**
8. **a03 capacity benchmark + tune warmup.**
9. **Header pseudocode update (the existing dv_dual_sf header gets a new "Adaptive throttle + RREQ fallback" subsection).**
10. **Test scenarios t23, t24, a02-a05.**
