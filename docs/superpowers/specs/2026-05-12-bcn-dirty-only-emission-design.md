# BCN Dirty-Only Emission with Solicited Sync — Design

**Date:** 2026-05-12

**Goal:** Reduce BCN airtime from 39% of total network airtime to ~7% by emitting only changed routes in periodic + triggered BCNs and serving full state on demand via solicited sync responses.

**Status:** Spec — ready for implementation planning.

---

## 1. Problem

Measured baseline on a 3-hour run of `s04_seattle_realistic.json` (138 nodes, EU868):

- BCN class consumed **2482 s** of channel time = **39.0 %** of total airtime (largest class by far).
- `rt_update / beacon_rx = 0.40` — **60 % of every BCN re-broadcasts routes the receiver already knows.**

The redundancy comes from `pack_beacon`'s two-phase fill:
- Phase 1 — dirty entries (information-bearing).
- Phase 2 — sliding-offset rotation page (re-affirms steady-state routes).

After convergence, phase 1 is empty most periods, so phase 2 carries the whole BCN body. It's "always-on insurance" against silent BCN loss — every periodic emission acts as a partial state sync.

The insurance is too expensive. We want to pay for it only when somebody actually needs the sync.

## 2. Design summary

Three BCN emission contexts with three content profiles:

| Context | Trigger | Content | Typical wire size |
|---|---|---|---|
| **Periodic** | every `beacon_period_ms` (default 5 min) | dirty entries only (often empty) | 4 B (empty) to ~15 B (a few dirty) |
| **Triggered** | rand(50, 500) ms after any rt mutation | dirty entries only | ~10-40 B |
| **Sync-response** | requested or detected first-contact | dirty + full rotation page (today's behaviour) | ~151 B (today's full BCN) |

Periodic + triggered are the new common case; sync-response is the bulk-recovery path that fires rarely.

Sync triggers are **both** sender-requested AND receiver-detected (belt-and-suspenders):

- **Sender-requested:** new joiners (and other thin-rt nodes) set a `REQ_SYNC` flag bit in their next BCN. Neighbours react.
- **Receiver-detected:** `rt_merge` recognising a first-contact src schedules its own sync-response.

Storm prevention: jittered emission + suppression-on-overhear. SNR-weighted jitter biases the strongest-link neighbour to respond first.

Expected wire impact:

```
Today           : 39% × 100% × 100% = 39% network airtime in BCN
+ dirty-only    : 39% × 100% × 25%  = ~10%
+ §4.1 compress : 39% × 75%  × 25%  = ~7%
```

Implementing this design alone drops BCN airtime from 39 % → ~10 %, freeing **~29 % of network duty-cycle budget** for data traffic and downstream knock-on effects (less channel pressure → fewer drop_sf_mismatch → fewer retries → fewer cascades).

## 3. Wire format

Reuses today's BCN frame as locked in ROADMAP §7.0.2. One of byte 1's two reserved bits is claimed for `REQ_SYNC`:

```
byte 0: 'B'
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | REQ_SYNC(1 lo)
byte 2: src(8)
byte 3: n_entries(8)
... (rest unchanged: optional schedule records when has_schedule=1, then route entries × n_entries × 3 B)
```

The other reserved bit stays reserved for future use.

**Why bit 0 for `REQ_SYNC`:** the only remaining reserved bit in byte 1. No new field, no new tag.

**Detection of "is this a sync-response BCN?":** does NOT use a wire flag. Distinguishable by `n_entries >= ROTATION_SYNC_THRESHOLD` (default 8). Periodic/triggered emissions in the new model have ≤ a handful of dirty entries; sync-responses always carry the full rotation page. Clear daylight on both sides of the threshold.

## 4. Periodic BCN behaviour (the new common case)

```
beacon_fire (periodic):
  re-arm timer for next period (±20% jitter, as today)
  if pending_tx or pending_rx: skip emission, return (as today)
  if adaptive_throttle_should_skip(): skip emission, return (as today)
  payload = pack_beacon_dirty_only(self.rt)
    # Phase 1 only — dirty entries sorted by dest_id, deterministic order
    # NO Phase 2 rotation fill
  if self.req_sync_pending:
    set REQ_SYNC bit in byte 1
    # bit stays set on at most one BCN emission; clear after first emit
  tx 'B' with the assembled payload
  clear .dirty on every entry emitted (as today)
  clear self.req_sync_pending
```

Even when `payload` is just the 4-byte header (no dirty entries), the BCN is emitted. This is the **liveness heartbeat** that keeps `last_seen_ms` fresh at neighbours so `rt_aging_ttl_neighbor_ms = 30 min` doesn't evict me. With a 5-min period, neighbours see ~6 refreshes per aging window — comfortable margin.

## 5. Triggered BCN behaviour

Today's mechanism stays: any `rt_merge` mutation (new / promote / 3cycle-prune / age-out) schedules a one-shot beacon within rand(50, 500) ms, coalesced into a single armed trigger. **Triggered BCNs bypass the adaptive throttle** (they exist to propagate route changes urgently).

The only change: `pack_beacon` for triggered emission also does dirty-only — no rotation fill.

Because triggered BCN is the propagation vehicle for the mutation that armed it, the dirty entry set will naturally include the trigger's cause. After triggered emission, dirty flags are cleared, so a following periodic BCN at the next period would emit an empty header.

## 6. Sync-response BCN (request side)

A node sets `self.req_sync_pending = true` when:

- It just booted (`on_init` sets `self.req_sync_pending = true`).
- It came out of mobility migration (future hook — out of scope today, but the state-machine slot is ready).
- (Optional, future) Its rt[] becomes "thin" — fewer than `rt_thin_threshold` direct-neighbour entries. Not in v1 to keep semantics simple.

The flag rides on the next outgoing BCN (periodic or triggered, whichever comes first). After that emission, the flag is cleared. So a single REQ_SYNC bit is broadcast at most once per "need" trigger.

## 7. Sync-response BCN (responder side)

```
on_recv 'B' (after the parse + rt_merge work):
  needs_sync_response = false

  # Sender-requested path:
  if parsed.req_sync_flag:
    needs_sync_response = true

  # Receiver-detected path:
  if rt_merge_outcome was "new" AND parsed.src is now a direct neighbour
     AND rt[parsed.src].candidates[1].is_first_contact (= was empty before this BCN):
    needs_sync_response = true

  if needs_sync_response:
    schedule_sync_response_with_suppression(parsed.src, parsed.rx_snr)

schedule_sync_response_with_suppression(joiner_id, rx_snr):
  if sync_response_satisfied_for(joiner_id):
    return  # already handled within sync_satisfied_ttl_ms (default 30 s)

  jitter = sync_response_jitter_ms × (1 - normalize(rx_snr))
    # rx_snr ∈ [-20 dB, +10 dB] → normalize to [0..1]
    # higher SNR → smaller jitter → fire sooner (responder closest to joiner wins)

  after(jitter, fire_sync_response, joiner_id)

fire_sync_response(joiner_id):
  if sync_response_satisfied_for(joiner_id):
    emit("sync_response_suppressed", joiner_id, reason="already_synced")
    return  # somebody already responded
  if self.budget_tier >= EXHAUSTED:
    emit("sync_response_suppressed", joiner_id, reason="budget_exhausted")
    return  # let a healthier neighbour handle it
  if pending_tx or pending_rx:
    after(rts_busy_retry_ms, fire_sync_response, joiner_id)
    return
  payload = pack_beacon_with_rotation_fill(self.rt)
    # Today's pack_beacon: dirty first, then rotation page up to max_entries
  tx 'B' with the assembled payload
  mark_sync_satisfied(joiner_id, ttl=sync_satisfied_ttl_ms)

sync_response_satisfied_for(joiner_id):
  return (now - self.sync_satisfied[joiner_id]) < sync_satisfied_ttl_ms
        OR observed_recent_sync_response(joiner_id)

observed_recent_sync_response(joiner_id):
  # Any BCN we've received in the last sync_response_jitter_ms with
  # n_entries >= ROTATION_SYNC_THRESHOLD counts as someone else's sync response
  return self.last_observed_sync_response_ms > now - sync_response_jitter_ms
```

Tracking `last_observed_sync_response_ms` is a single timestamp updated whenever a BCN with `n_entries >= ROTATION_SYNC_THRESHOLD` is received. Suppression is then a single comparison — no per-joiner tracking needed.

`sync_satisfied[joiner_id]` is a small TTL'd dict (one entry per recently-handled joiner). Bounded by network neighbour count.

## 8. Dirty-bit lifecycle

Unchanged from today. The bit means "advertise at next emission, then forget":

- Set by `rt_merge` on `new` / `promote` / `primary_refresh`.
- Set by `rt_prune_cycle` when a primary is pruned.
- Cleared by `pack_beacon` for every entry it emits in the current frame.

The only subtle change: sync-response BCN packs `(dirty ∪ rotation)` and clears dirty for every entry it included, identical to today's pack_beacon behaviour. Periodic/triggered packs `(dirty only)` and clears dirty for those.

## 9. Liveness & aging

Two invariants to preserve:

1. **Neighbours don't age me out.** `rt_aging_ttl_neighbor_ms = 30 min` means I need to emit something detectable within every 30-min window. Periodic BCN every 5 min × 6 = 6 refreshes per window. Even with adaptive-throttle skip rates (today ~10%), worst-case 5 emissions per window. Margin is fine.

2. **`rt_merge` updates `last_seen_ms` even on empty BCN.** This is the action item — confirm today's code does this. If `rt_merge` early-returns on `n_entries == 0`, fix it. The 4-byte header alone is the heartbeat; reception updates last_seen regardless of content.

If the simulator measures a regression in `rt_aged` events post-implementation, that's the signal that liveness isn't propagating correctly and the fix is in `rt_merge`.

## 10. Composition with other features

| Feature | Interaction |
|---|---|
| **§4.1 BCN run-length compression** | Independent and additive. Compression makes sync-response BCNs ~22-28 % smaller; doesn't change request/detect logic. Combined effect: 39 % → ~7 % BCN airtime. |
| **Adaptive throttle (`quiet_threshold_ms`)** | Periodic BCN still subject to throttle. Triggered + sync-response bypass it. No change. |
| **Triggered BCN coalescing** | Unchanged. Multiple mutations within trigger window still collapse to one BCN. |
| **§7.2 schedule records (gateways)** | Sync-response BCN includes schedule records when `has_schedule=1`. Periodic/triggered also include them on every emission (small fixed cost for gateways). |
| **§1 anti-spam** | Anti-spam already keys on `meta.src` (radio physical). Sync-response BCNs don't change observation counts in a meaningful way (count-based metric absorbs single events). |
| **Budget tiers** | Sync-response respects EXHAUSTED tier — defers to healthier neighbours. STRAINED / CRITICAL still respond (they're the ones with routes worth syncing). |
| **§2 mobility (is_mobile)** | Mobile nodes are exactly the use-case for REQ_SYNC. They set the flag when their leaf changes (future hook). Receiver-detection also catches this. |
| **Cold-start UX** | Joiner emits a BCN at on_init (already does); sets REQ_SYNC. Neighbours respond within ~`sync_response_jitter_ms` (default 2 s). Routes appear FAST — much faster than today's "wait for next rotation slot". |

## 11. Tunables

| Knob | Default | Purpose |
|---|---|---|
| `sync_response_jitter_ms` | 2000 ms | Max jitter window for responder scheduling. Should cover 1-2 full RTS-CTS-DATA-ACK cycles so suppression has time to fire. |
| `sync_satisfied_ttl_ms` | 30000 ms | TTL on per-joiner "I already synced this peer" memory. Prevents re-syncing for repeat sightings. |
| `rotation_sync_threshold` | 8 | n_entries threshold above which a received BCN is treated as a sync-response (for suppression detection). |
| `req_sync_on_boot` | true | Whether `on_init` sets `req_sync_pending = true`. Disable for tests that exercise quiet-start behaviour. |

No new wire-format knob is needed — REQ_SYNC reuses the existing reserved bit. ROTATION_SYNC_THRESHOLD is a receiver-side heuristic.

## 12. What this design deliberately doesn't solve

- **Silent BCN loss after first-contact.** If A converged with B's network, then B's later-triggered BCN announcing a route change reached everyone except A (single-packet drop), A will have a stale view until either (a) A tries to use that route and triggers a Q query (out of scope this round), (b) the route ages out naturally, (c) someone else mutates the route and re-triggers a BCN. Acceptable: the duty-cycle savings buy us tolerance for occasional staleness.
- **Joiner identifies itself reliably.** Receiver-detection uses "rt[src] was previously empty as direct neighbour." Edge case: a node that was a multi-hop entry (rt[src] existed but not as direct) and now appears as direct — is that "first contact"? Treat as YES (the link itself is new, even if the identity wasn't).
- **Two simultaneous joiners.** Two nodes booting within sync_response_jitter_ms of each other each trigger separate sync-response cascades. Per-joiner suppression handles each independently; some cross-contamination but bounded.
- **Per-receiver tailoring of BCN content.** BCN remains broadcast; we can't tailor what to advertise to each neighbour. Receiver-detection chooses sync source based on link quality, not content matching.

## 13. Open questions

1. **Should `sync_response_jitter_ms` be SNR-weighted multiplicatively (proposed) or rank-based among observed neighbours?** Multiplicative is simpler; rank-based requires tracking neighbour set. Recommend multiplicative for v1.
2. **Should EXHAUSTED-tier nodes set REQ_SYNC themselves when their rt[] thins out?** Argues for: stranded nodes need help most. Argues against: they shouldn't be adding to network load. Recommend SET (they're already starved; the request itself is one tiny BCN).
3. **Liveness threshold:** at what point would an unusually long throttle-skip streak break liveness? Worst-case math says 5 emissions per 30 min aging window. If real-world throttle skips 50 % of beacons during high-load periods, that's 3 refreshes per window — still safe but tighter. Worth monitoring in measurement.

## 14. Measurement plan

After implementation, re-run the s04_seattle_realistic 3-hour baseline. Expected deltas:

| Metric | Today | Expected | Lever |
|---|---|---|---|
| BCN airtime (% of total) | 39.0 % | ~10 % | dirty-only periodic + triggered |
| `rt_update / beacon_rx` ratio | 0.40 | > 0.80 | smaller, denser BCNs |
| Delivered messages (count) | 188 | substantially higher | freed budget → less retry → fewer cascades |
| `drop_sf_mismatch` | 20189 | lower | less routing_sf channel pressure |
| Cold-start delivery first window | 60 % | similar (new joiners get sync faster) | REQ_SYNC immediate response |

The `rt_update / beacon_rx` ratio is the cleanest single signal that this design is doing what it claims — every BCN should now mostly teach the receiver something.

## 15. Cross-references

- Locked BCN wire format: ROADMAP §7.0.2
- Run-length compression (Axis 1): ROADMAP §4.1
- Cold-start UX: scenarios/dv_dual_sf.lua "Bootstrap UX" doc block
- Adaptive throttle: scenarios/dv_dual_sf.lua beacon_fire path
