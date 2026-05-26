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
- **Lifecycle trace: `--trace SUBSTR`** — follows a message end-to-end through every
  event (origin → relays → gateway transit/handoff → H-query/resolve → delivery),
  auto-following the destination hash so the gateway-chain events come along. Use
  this to find *where* a cross-layer message dies instead of hand-rolling greps —
  the `--failures` buckets can mislabel (e.g. a chained message that dies in the
  inter-gateway transit shows as "binding-unresolved"; `--trace` shows the real
  `hop_budget_exceeded` / loop). e.g. `--trace xl-w015-e020`.

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
| TX-time schedule countdown (`apply_schedule_tx_fixup`) | **shipped** (eb3ec76) | re-stamp the visit-window countdown byte at the actual `self:tx` instant against `(tx_now + airtime)` instead of pack-time. Anchor error median **342→50ms**, p90 706→98, signed mean **+398→−17ms** (was systematically *late*). 16-seed s15: **CHAN +4.1pp** (89.6→93.7, consistent both batches), **XL +2.4pp = flat-within-noise**, ALL flat, SAME −1.3pp, 0 leaks. A **correctness + channel-reach** win, NOT an XL lever — reconfirms XL is structural. |
| Adaptive schedule guard (`gateway_schedule_guard_sparse_bonus_ms`) | **implemented (uncommitted)** | add the guard bonus only for SPARSE-herd gateways (advertised spread nibble 0 → 100+200=300ms); dense gateways (nibble>0) keep base 100. Captures the sparse-herd settle-margin win while protecting dense herds. 32-seed s15 **XL +3.1pp** (72.5→75.6); dense **s16 byte-identical** (10.0/10.9 both arms, 0 regression); 0 leaks. The **first timing-alignment lever to move XL** (airtime levers were all flat). Conservative vs flat-300 (+6.7pp on s15) because s15 also has nibble>0 gateways that the binary rule leaves at base — a graduated rule could capture more but risks s16. |

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
- **Adaptive schedule guard — IMPLEMENTED** (see levers table). The guard is the
  "how far into the window to aim" knob (the old +398ms-late anchor was an
  *accidental* such guard). Density-dependent: a 300ms flat guard gave s15 **+6.7pp**
  but dense s16 **−9pp** (a bigger guard bunches a dense herd → collisions). So the
  bonus is now added only for sparse-herd gateways (spread nibble 0): s15 **+3.1pp**,
  s16 untouched. This is the **first timing-alignment lever to move XL** (airtime
  levers were all flat) — refines the meta-lesson: XL is insensitive to airtime but
  sensitive to schedule-window alignment. **Remaining opportunity:** s15 also routes
  through nibble>0 gateways that the binary rule leaves at base (hence +3.1 not
  +6.7) — a *graduated* guard (bonus tapering with nibble) could capture more, but
  must be re-gated on s16 (mid-nibble is where the dense regression lives).
- Re-confirm the cross-layer failure taxonomy with `dm_delivery_breakdown
  --failures` after any change; measure 8–16 seeds (XL is noise-dominated).

### Debunked: "gateway countdown is stale by ~5.7s" (do NOT re-chase)
A prior session hypothesised neighbours fire into the away-gap because the
advertised schedule countdown was multi-second stale. **Refuted by measurement.**
The countdown is built at `pack_beacon` time and the beacon's only post-build
delay is the FLOOD LBT defer, **capped at one beacon airtime**
(`flood_lbt_max_defer_ms = airtime(routing_sf, beacon_max_bytes=151)` ≈ 780ms at
SF9) plus the airtime-to-RX. Measured anchor error (predicted window-open vs the
gateway's true `gateway_layer_active reason=schedule`): **median 342ms, p99
1135ms, max 1407ms, 0% > 3s.** Of 61 RTS aimed at a gateway, only **6 hit it
while away — all 6 with the sender *holding* the schedule** (0 no-schedule),
i.e. window-*close* edge cases from the +398ms-late anchor, not a stale cache.
The fix above addresses these; the residual XL gap is structural. **8-seed XL
flipped −2.4pp → +2.4pp at 16 seeds** — a live reminder to gate borderline XL
results at ≥16 seeds.

## s17_metro — large asymmetric metro (252 nodes, explicit links)
Production-fidelity companion to s15 (`tools/gen_s17_metro.py`, committed dba3163):
dense center L1 (180, SF8) + sparse west L2 (34, SF9) + sparse east L3 (34, SF7),
4 boundary gateways (2 L1↔L2 west, 2 L1↔L3 east). **Topology is EXPLICIT
individually-defined links**, NOT path-loss-derived — path-loss couples degree to
density (dense cluster → unicast saturation) and log-distance is a poor LoRa fit
(real Gdansk map fits alpha≈0.67; terrain dominates). Instead: degree-capped KNN
(center 9, suburbs 5) with per-direction shadowed SNR from the real Gdansk
regression (SNR = 2.45 − 6.69·log10(d_km), σ=6.7). 1 h, 10-min quiet, 3 traffic
waves (48 XL sends). Run: 0 assertions, 0 leaks, **SAME 63% / XL 38% / CHAN 98%**.
Path-loss vs explicit-links A/B was decisive: SAME 40→90 (small-N) , XL 12→38,
runtime 204→96s at the explicit/degree-capped model.

### Finding: west↔east XL needs GATEWAY CHAINING (dominant XL drop bucket)
The biggest XL failure (12 of 41 fails; `gateway_envelope_dropped` reason
`gateway_known_no_route`) is **entirely the west↔east (L2↔L3) pairs** (origins
w015/w031→L3, e010/e020→L2, 3 waves each). s17 has **no direct L2↔L3 gateway**
(the suburbs are geographically opposite — only L1↔L2 and L1↔L3 exist), and
`select_gateway_for_layer` (dv_dual_sf.lua ~4885) only envelopes to a SINGLE
gateway that *directly* bridges the target layer. Reaching east from west needs
L2→[gw_w]→center L1→[gw_e]→L3 — two cross-layer hops — which the protocol does
**not chain**. Evidence: w015 only ever learns `gw_w0 → L1` as a routable/on-layer
gateway; it "knows" gw_e→L3 only via a *leaked* TLV that the on-layer guard
correctly refuses to address (never seen on L2, no route). s15 hid this with a
direct bridge_23. Center↔suburb XL (which has a direct gateway) is unaffected —
that's where the other XL buckets live (2nd-leg loss, doorstep, cascade).

### Fix: source-routed layer-hop envelope (IMPLEMENTED — gateway chaining)
The cross-layer envelope (in the DATA *payload*, magic `\31G2`) now carries an
ordered **layer-hop path** instead of a single target layer:
`MAGIC | hop_count | hops… | dst_hash | body` (≤ `GW_ENV_MAX_HOPS`=4). The sender
gives the hops to traverse (last = dst layer), e.g. `send_layer 1,3 <hash> <text>`
for L2→L3 via the hub. Each gateway pops the entered layer (`hops[1]`); empty →
deliver to the hash there, else `select_gateway_for_layer(next)` and re-wrap the
remaining envelope toward that gateway (`gateway_envelope_transit`). The finite,
consumed hop list is the loop/TTL guard. A 1-element list == the old behaviour
(backward-compatible; all 72 t-tests pass). **Validated by t77** (L2↔L3 via L1,
separate L1↔L2 / L1↔L3 gateways, no direct bridge): 3/3 forward + 2/2 reverse
deliver. Path *learning* (auto-deriving hops from the bridged-layers TLVs) is the
deferred follow-on; for now the sender supplies the path explicitly.
**s17 west↔east, end-to-end status — ROOT CAUSE (via `--trace`).** The chaining
*mechanism* is complete: origin-drops 12→0 (envelopes start), and after a **transit
on-layer guard fix** (`select_gateway_for_layer(next, skip_seen_guard=true)` — the
transit's next gateway bridges the entered layer by definition, so reactive RREQ
can reach a non-adjacent same-layer gateway) `transit_drop` went 8→0. **But
delivery is still 0/12**, and `dm_delivery_breakdown --trace xl-w015-e020` shows
exactly why: the message reaches the first gateway fine, gw_w0 fires the transit
(`gateway_envelope_transit → gw_e1`) and forwards on L1 — but the **inter-gateway
forward `gw_w0 → gw_e1` dies crossing the center**:
`…→c046 NACK loop_duplicate → path_cascade →…→c021 hop_budget_exceeded → rts_giveup`.
The two gateways sit at **opposite boundaries, >8 hops apart** across the deg-9 /
diam-11 center, so the forward blows the **8-hop DV budget** (and loops). The far
gateway never receives the envelope.

This corrects earlier guesses in this section: it is **NOT** resolution / H-query /
visit-window. The `--failures` "binding-unresolved" label is *misleading for
chained messages* — the gateway never got far enough to even try resolving.
(2nd-leg / H-query resolution is fine where the gateway is actually reached:
intra-suburb same-layer delivery is 100%.)

**Reframe — the real root is the 8-hop DV budget vs the center diameter (11).** One
cause behind three failure buckets: (a) west↔east inter-gateway transit (>8 hops),
(b) the "routing LOOP / never reached gateway" bucket (those transit forwards
looping in the dense center), (c) long same-layer center pairs (`c000↔c090` = 19
hops). Any path > 8 hops hit `hop_budget_exceeded`.

**DONE: hop cap raised 8 → 16.** Route entry `hops` moved to its own full wire byte
(1..255; +1 B/entry, `beacon_max_entries` 47→35); DATA `hop_budget` `hops_remaining`
widened to 5 bits (0..31); the three caps moved together — `dv_hop_cap`=16 (beacon
adoption `combined_hops>cap`), `route_request_max_ttl`=16 (RREQ flood), and
`hash_query_max_ttl`=16 (H flood). Raising further is now a one-constant change (no
wire change). Guarded by **t78** (an 11-hop linear chain delivers only at cap≥11;
verified 0 delivered at all-caps=8). Suite 98/98. **Caveat (unchanged):** a 16-hop
unicast is ~0.95^16 ≈ 0.4 reliable + multi-second — the cap *enables* west↔east
(gw_w0→gw_e1 ≈ 9–11 hops) and the long center pairs to route, it doesn't make them
reliable; the 19-hop `c000↔c090` still exceeds 16.

**MEASURED (seed 17, single run).** Total DM 47%→**54%**; **west↔east 0/12 → 4/12**
(`e020→w015` **3/3, ~9 carriers**; `e010→w031` 1/3). Structural win is seed-
independent: `--trace e020-w015` shows a clean ~9-hop east-layer climb to gw_e1 then
gateway transit — a path categorically impossible under the old 8-hop cap. And
**`no_gw`=0 / `giveup`=0 across all 26 pairs** — the "route can't exist" wall is
gone. (Rate numbers are single-seed/noisy — 3 msgs/pair; trust the structural claim,
sweep ≥6–8 seeds before trusting +7pp.)

**NEW dominant bottleneck (the cap is no longer the wall).** `--failures` on the
cap-16 run: **33% of fails = "XL stall: routing LOOP, never reached gateway"**, 19%
= "doorstep: gateway PRESENT but no pickup (busy/collision)". All 17 in-flight
failures are downstream attrition, not no-route. `--trace w015-e020` (the 0%
direction) is the archetype: the first leg bounces through the **wrong** west gateway
(gw_w0) with `rts_tx_blocked: self_tx_in_flight` + repeated `cts_timeout`, reaching
the intended gw_w1 only at **+13.8s**, after which the cross-layer transit doesn't
complete.

### Root cause: stale visiting-gateway routes (NOT selection, NOT coverage)
Traced to ground (`w015→e020`, `w028→c060`): the first-leg loops/bounces are caused
by **stale routes to the time-shared gateways**, not by which gateway is chosen.
- gws are **home=center, ~50% duty** on each suburb. West nodes learn routes to them
  in the **t<200s convergence burst**, then those routes **freeze for the whole run**:
  the remote-route aging TTL is **3 h** but the sim is **1 h**, so they can't expire
  (`age_out_stale_routes` never evicts them — confirmed: **no `rt_aged`/`rt_prune`**
  for gw dests at w015; **no `route_query` at send** → Pass 1 used a stale *present*
  route; w005's route to gw_w1 was pinned t=46 s → t=2161 s).
- The frozen routes across nodes are **mutually inconsistent** (snapshots of a
  half-present gw taken at different times) → a 6-hop bounce *through the other gw*
  or an outright loop → `loop_duplicate` → `cascade_exhausted` → `giveup`.
- Selection/coverage are **fine**: `no_gw`/`giveup` = 0 everywhere; w015 held routes
  to **both** gws at equal (stale) 4 hops and picked gw_w1 on the score tiebreak.
  "Pick the nearer gw" can't help — the hop counts are fiction.

### Tried & REVERTED: short TTL for gateway routes
`rt_aging_ttl_gateway_ms` = 45 s for `is_gateway` routes (expire stale ones →
reactive RREQ rediscovers fresh). Mechanism worked in isolation (regression caught
it), but **s17 single-seed delivery did not improve**: DM 54%→50%, **cross-layer
20/48 → 12/48**, and failures shifted to the **predicted** weakness — "gateway gave
up (resolve/route)" jumped to 33%. Expiry forces reactive rediscovery that **can't
converge inside the ~7.5 s visit window**, trading loops for give-ups. Reverted to
the cap-16 state. **Lesson: reactive rediscovery is the wrong tool for an
intermittent-but-scheduled destination — go proactive / schedule-driven.** (Also:
one s17 seed can't settle a rate; the *failure-mode shift* is the seed-robust signal.)

## Cross-layer delivery pipeline (the model — read this before chasing XL drops)

A cross-layer DM carries a **layer-hop path** (e.g. `[1,3]` = enter L1, then L3).
suburb↔center = 1 gateway hop; suburb↔suburb = 2 gateway hops chained via center.
All 4 gws are **home=L1, visiting one suburb ~50% of the time**.

Hard case `w015→e020` (path `[1,3]`):
```
 STAGE 0        STAGE 1              STAGE 2                STAGE 3            STAGE 4
 select       first leg (L2)      inter-gw transit (L1)   final leg (L3)      deliver
 egress gw  origin ─hops▶ gw_w   gw_w ─hops▶ gw_e         gw_e ─hops▶ tgt     tgt decodes
   │            │                    │                        │                  │
 gw bridging  route to gw_w on L2  gw_w (now on L1/home)    gw_e (now on L3)   DATA
 L2→L1        while gw_w visits L2 forwards across center   resolve hash→id    arrives
                                   to gw_e (on L1)          then route to tgt
```
suburb↔center (path `[1]`) is the same but **stops after Stage 1** (gw is already
home on the target's layer; no transit, no 2nd gw).

| Stage | What | State it needs | Timing constraint | Failure buckets |
|---|---|---|---|---|
| **0 select** | `select_gateway_for_layer` picks egress gw | rt route to a gw (Pass1 lowest-hops / Pass2 arbitrary); `bridged_layers` | — | `no_gateway_known`, `gateway_known_no_route` (both 0 today) |
| **1 first leg** | DV forward origin→gw on origin's layer | **every hop's rt route to the gw** (stale/loopy hot-spot) | gw **present on this layer** | "routing LOOP / never reached gw" (33%), "cascade/dead-end", "doorstep present-no-pickup" (19%), "doorstep gw away" |
| **2 transit** | gw pops layer, re-wraps, forwards across center to next gw | **center routes to the next gw** (also intermittent) | both gws on center **at once**; crosses diam-11 center (cap≥~11) | inter-gw forward loops in center (`loop_duplicate`→`cascade`→`giveup`) |
| **3 final leg** | last gw resolves tgt `hash→id` (H-query) + routes to tgt | gw **binding table**; gw route to tgt on visit layer | gw **present on target's layer** | "gw gave up resolve/route", "2nd-leg lost downstream", "binding unresolved", "2nd-leg first-hop stalled" |
| **4 deliver** | tgt decodes DATA → `delivered` | — | — | (success) |

**Timing model (why XL is slow *and* fragile).** `w015→e020` needs a *sequence* of
window alignments, each adding buffering latency: (1) gw_w on L2 [recv first leg] →
(2) gw_w on L1 [transit] → (3) gw_e on L1 [recv transit; 2&3 must overlap] → (4) gw_e
on L3 [final leg]. Each gw is on each layer ~50% of the time, so the message buffers
at each gw until its window opens. **The schedules are deterministic and known
(`gateway_neighbor_schedules`) — the unexploited lever.**

**Funnel readout (`dm_delivery --failures`, cap-16 baseline, 48 XL msgs, 20 delivered):**
```
S0 enqueued                48
S1 reached egress gateway  26   ← lost 22: LOOP(12)  doorstep-busy(7)  doorstep-away(2)
S3 final-leg queued        23   ← lost 3
S4 delivered               20   ← lost 3 (2nd-leg downstream)
  2-gw suburb↔suburb: 12 sent · 6 reached gw1 · 4 transited · 4 delivered
```
**~79% of XL loss is the FIRST LEG (22/28).** Once a msg reaches the gw, **77%
deliver** (20/26). The window split is decisive: only **2** first-leg losses are
"gateway away" (window-miss) — the rest are **stale-route LOOPS (12)** + **doorstep
contention (7, gw present, no pickup)**. ⇒ the lever is **route consistency /
loop-prevention on the first leg** (+ doorstep contention), **NOT** window timing.
(`dm_delivery --failures` prints this funnel for every run — use it before guessing.)

**Structural diagnosis.** Every stage routes to / through an **intermittent**
destination using DV routing built for **stable** destinations. That mismatch is the
root of the stale/loopy routes at Stages 1–3. Reactive freshness (the reverted TTL
fix) can't converge in the 7.5 s window → the promising direction is **proactive,
schedule-driven**: establish/refresh routes to a gw exactly when its window opens,
and time sends to windows.

### First-leg loop mechanism + FIX (gateway_doorstep_hold)
Tracing the Stage-1 LOOP bucket (`w028→c060`, `w015→e020` wave-1): the loop is **not**
a stale-hop-count DV cycle — it's the generic multi-path recovery machinery
backfiring on a **single-funnel** gateway. A gateway-bound envelope's wire dst IS the
gateway; when a doorstep RTS gets no CTS (collision in the gw's narrow window, or the
gw mid-switch off-layer), `tx_blind_alt` / `pick_next_cascade_hop` re-route the copy
to a **sibling** gateway-neighbour — which also can't reach the gw — so copies bounce
(`loop_duplicate` → `cascade_exhausted` → `rts_giveup`) and self-contend. Confirmed by
the collision check: the gw receiver is a 1.7× collision hotspot, 30 collisions hit
gw_w1 during one 24 s attempt; the `cts_timeout`s are contention, not staleness.

**FIX (committed):** `gateway_doorstep_hold` in `dv_dual_sf.lua` (`rts_timeout_fire` /
`ack_timeout_fire`). When the silent next-hop IS a known gateway (`px.next==px.dst`,
`gateway_neighbor_schedules[dst]`), suppress the sibling fan-out: hold the **single**
copy and requeue it window-aware (`gateway_schedule_defer_ms`) + jittered
(`gateway_doorstep_retry_jitter_ms`, burst-avoidance) until a **real** giveup at
`gateway_send_giveup_ms` (150 s ≈ 10 windows), instead of the seconds-long
cascade-exhaust. Relay hops (`next≠dst`) and same-layer routing are untouched.
Guarded by **t80** (3 suburb nodes contend at one gw window → holds, 3/3 deliver, 0
`path_cascade`/`loop_duplicate`/`giveup`; fails when the giveup knob is neutered).

**Result (s17, seed 17, single run):** overall DM **54%→62%**, cross-layer **20/48→
26/48** (42%→54%). First-leg losses **22→13** (routing LOOP **12→7**, doorstep-busy
**7→2**); messages reaching the egress gw **26→35**. The targeted bucket shrank and
delivery rose — the *opposite* of the reverted TTL fix's failure-mode shift, so the
single-seed signal is trustworthy in *direction* (sweep for the rate). **Untouched:
the 2-gw suburb↔suburb path (4/12)** — its loss is now Stage-2 (inter-gateway transit
across the center), the next target.

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
