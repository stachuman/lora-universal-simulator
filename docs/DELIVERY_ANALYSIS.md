# Delivery Analysis — s15 cross-layer DM + channels

Living analysis doc. **Read this before re-investigating delivery.** Update it
when a root cause, lever, or measurement changes — don't re-derive from scratch.

## Measurement protocol (use consistently)
- **s15 is noise-dominated (±~2.4pp); sweep 8–16 seeds**, never judge from one run.
- **Exclude the first 10 min (600 s)** for any beacon / steady-state airtime
  analysis — that window is network *stabilization* (boot discovery beaconing,
  `discovery_beacon_period_ms`, bounded by `discovery_until_ms`). It is expected,
  not overhead to optimize.
- Canonical tool: `tools/dm_delivery_breakdown.py --failures` (DM + channel; the
  cross-layer "reached-gateway-lost" bucket is sub-classified into
  no-route-to-target / first-hop-stalled / lost-downstream / resolve-bound, with a
  HOME/VISIT target-location tally). Requires explicit `node_id` in config (runs on
  `scenarios/s*.json` + t74/t75, not older node_id-less t-tests).

## Current state (after commit f467346)
8–16 seed s15: aggregate DM ~**90%**, same-layer ~**97%**, cross-layer ~**77–78%**,
channel reach ~**94%** (0 cross-layer leaks). The gap is almost entirely
cross-layer DM.

## Cross-layer failure taxonomy (the ~22% gap)
- **First leg, never reached the gateway (~46%):** cascade/dead-end + routing LOOP
  + doorstep (gateway busy/away).
- **Second leg, reached gw but lost (~26%):** lost-downstream + no-route-to-target.
- Resolve give-up + same-layer stragglers (~rest).

## Root causes

### 1. Route discovery not gateway-aware — FIXED (commit f467346)
RREQ requery flooded the gateway's *current* layer not the forward's target layer;
RREP rode `tx_initiating` with no schedule-defer/jitter so simultaneous repliers
collided at a present gateway. Fix: layer-gated requery (`send_defer_requery_offlayer`)
+ schedule-aware/jittered RREP (`route_reply_jitter_ms`, `rrep_gateway_schedule_defer`)
+ duty-cycle-scaled defer TTL. **s15 85% → 90%.** See PROTOCOL.md §3.7b.

### 2. Beacon airtime — an EFFICIENCY lever, NOT the cross-layer bottleneck

**SF aspect (collision model is SF-orthogonal — only same-SF frames collide,
SimController.cpp:1429).** Frame→SF mapping (verified at tx sites):
- **Routing / control SF** (L1 SF8, L2 SF9, L3 SF7): `BCN`, `RTS`, `CTS`, `ACK`,
  `NACK`, `F`, `H`, `Q`, `J`, and channel `DATA-M`. (CTS/ACK are on the routing
  SF — logs say "on routing SF"; an old "CTS on data_sf" comment is stale.)
- **Data SF** (6/10/11): unicast `DATA` only.
So **BCN collides with the RTS/CTS/ACK handshake + DATA-M, NOT unicast DATA.** On
the control SFs, BCN is ~**73% of airtime** (handshake only ~21%).

**The dominant beacon cost is the gateway per-visit `gateway_sweep`** (was at
`schedule_gateway_layer_window`): a beacon fired on EVERY visit-window entry
(~15s), 171 of them at L2's SF9 ≈ ~700 ms each ≈ ~120 s of bridge_12's ~134 s.
**Cross-check correction:** that sweep is *dirty-only* and carries **zero route
entries** (137/140) — its 728 ms is the fixed **32-byte seen-bitmap** (channel
gossip / cross-layer-seen state) + schedule (1 tiny record), NOT routes. So the
sweep's real job is **propagating channel/seen state to the visit layer**, not
routes, and the schedule re-announce is waste (a node computes the static
schedule from one hearing; clock drift ~±20-50 ppm ≈ 100-200 ms over 30-60 min
is negligible vs the multi-second window).

**FIX (implemented, uncommitted): differential `gateway_sweep`.** Fire the
visit-entry beacon only when the gateway has NEW state to push to that layer —
dirty routes (active-layer `rt`) or dirty channel messages (`channel_buffer`);
skip when quiet. New nodes still pull the schedule reactively via **Q REQ_SYNC**
(response jittered 0.5–6 s, `sync_response_backoff_*`); the periodic beacon
carries it on the slow path. Sweeps 140 → 11; bridge_12 beacon airtime
**134 s → 39 s (−71%)**.

**Measured (8-seed A/B, differential vs baseline-with-sweep):**
| | ALL | SAME | XL | CHAN |
|---|---|---|---|---|
| baseline (sweep) | 89.8% | 96.7% | 78.6% | 93.5% |
| differential | 88.9% | 97.4% | 75.0% | **93.9%** |
| full removal | 90.0% | 99.3% | 75.0% | 91.6% |

The differential **recovers channel reach** (93.9% vs full-removal's 91.6%) while
keeping the airtime win — confirming the sweep's value was the **seen-bitmap /
channel gossip**, gated correctly. **Cross-layer is flat-within-noise** (75.0%;
the ~−2 to −3.6pp dip vs baseline persists in *all* no-full-sweep variants and is
borderline-noise on 168 XL msgs).

**KEY META-LESSON: beacon airtime is NOT the cross-layer bottleneck.** Two
airtime/contention levers — RERR and the beacon sweep — both came out
**flat-on-XL**. Cutting beacons helps **efficiency** (−71% gateway airtime) and
**same-layer** slightly, and the differential preserves channels, but it does
**not** raise cross-layer. **The cross-layer gap is structural** (visit-layer
route propagation / gateway presence / multi-hop quality), not airtime — stop
chasing airtime/contention for XL.

## Levers — tried & status
| lever | status | result |
|---|---|---|
| Gateway herd-jitter | validated | +24.6pp on dense s16; suppressed on sparse s15 (`gateway_herd_min`) |
| Route discovery gateway-aware | **shipped** (f467346) | s15 +5pp |
| Route-error (RERR / no-route NACK) | **REVERTED — refuted** | failed gate (89.8→86.6%). Dead-ends are *congestion* artifacts (transiently-blinded routes), not dead routes; invalidating them removes recoverable paths + adds airtime. **Do not retry without solving congestion first.** |
| Differential `gateway_sweep` | **implemented (uncommitted)** | sweep only when dirty routes/channels for the layer. −71% gateway beacon airtime (134→39s), channel reach preserved (93.9%), same-layer flat-up; **XL flat-within-noise** (efficiency win, not an XL fix). |
| Beacon-overhead → cross-layer | **refuted as an XL lever** | cutting beacon airtime is flat-on-XL (same as RERR). XL is structural, not airtime. |

## Open problem & next lever
**Cross-layer (~77%) is the remaining gap, and it is STRUCTURAL — not airtime.**
Two airtime/contention levers (RERR, beacon sweep) both came out flat-on-XL, so
stop chasing airtime/contention for cross-layer. The likely structural levers,
in rough priority:
- **Visit-layer route propagation / freshness** — the gateway's routes to/from
  the visit layer, and visit-layer nodes' routes to the gateway. (The sweep
  *didn't* carry routes — 0 entries — so this isn't fixed by it.)
- **Gateway presence / second-leg forwarding** — the 2nd-leg "lost downstream"
  and first-leg "never reached gateway" buckets are multi-hop route-quality on a
  part-time gateway, not contention.
- Re-confirm the cross-layer failure taxonomy with `dm_delivery_breakdown
  --failures` after any change; measure 8–16 seeds (XL is noise-dominated).

## Tooling gotchas (so they aren't rediscovered)
- `script_emit` `node` field = **0-based array index**; data `origin`/`dst`/`next`
  = config `node_id`.
- `(gw, ctr)` collides across targets — disambiguate by `dst` + `payload` + time.
- `gateway_handoff_drained` carries `ctr=None`; use `gateway_handoff_enqueued` for
  the forward ctr.
- 200-locals-per-Lua-chunk limit: new chunk-level helpers/constants must be
  **global** (no `local`), else compile fails ("too many local variables").
- **PHY event-type names** (don't reintroduce the blindness bug): collisions are
  emitted as type `collision` (NOT `drop_collision`); off-SF drops as
  `drop_sf_mismatch` (NOT `drop_off_sf`); plus `drop_preamble_miss`,
  `drop_rx_blind`, `drop_halfduplex`, `tx_deferred`, `tx`, `rx`. The SF-orthogonal
  collision model only collides same-SF frames (SimController.cpp:1429).
