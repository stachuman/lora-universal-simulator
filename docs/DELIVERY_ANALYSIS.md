# Delivery Analysis — s15 / s17 cross-layer DM + channels

Living analysis doc. **Read this before re-investigating delivery.** Update it
when a root cause, lever, or measurement changes — don't re-derive from scratch.

> **STATUS (2026-05-28).** s17 4-seed delivery by class: same-layer **89%** · XL 1-gw
> **63%** · XL 2-gw **60%** · ALL **73%** (was 59% pre-work). Same-layer resolved
> (anti-loop package). 2-gw transit copy-storm fixed (retry-same-hop on ACK-timeout).
> **Vector reassessment (2026-05-28, see "Copy prevention reassessed" below):** further
> copy-suppression attempts (dedup-on-overhear prototype) were tried on s18 realistic
> traffic and **reverted** — copies are 2–6% of airtime and uncorrelated with the
> airtime total. Right vectors, ranked: **(1) hop-count reduction, (2) retry reduction,
> (3) decode-overhead surface (fanout × handshake), (4) copy prevention (last).** Use
> `dm_delivery_breakdown.py --failures` + `--airtime` + `--copies` before guessing.
> Measure-gate: sweep ≥4 seeds, s17/s15 XL is single-seed-noisy.

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
- **Copy count: `--copies`** — counts copy-creating switches (a forward that
  abandoned a next-hop which had already `data_rx`'d the frame and switched to a
  different node → a 2nd live copy), broken down by trigger
  (`blind_alt`/`silent_alt`/`stale_next`/`ack_giveup`/`silent_next`/`loop_duplicate`/
  `rts_giveup`) vs legit reroutes (abandoned hop never decoded), plus per-message
  fan-out (distinct decoders per `origin,ctr`). **Decouples copy-count (robust)
  from delivery (noisy)** — use it to judge copy/contention levers on their own
  merits. NB on s17 the dominant copy source is `blind_alt` (cts-timeout), NOT the
  `ack_giveup` cascade the reverted grace targeted.

## Design constraint: control vs data SF — handshake is the bottleneck (READ FIRST)

The collision model is **SF-orthogonal** (`SimController.cpp:1429`) — only same-SF
frames collide. The protocol uses two SF tiers:

- **Routing / control SF** (SF8 on L1): `RTS`, `CTS`, `ACK`, `NACK`, `BCN`, `F`, `Q`,
  channel-M `RTS` (announcement only). This is the contended SF.
- **Data SF** (`chosen_data_sf` per link, e.g. SF7/SF9): unicast `DATA` payloads
  and `DATA-M` (channel-M payload). Carries one frame type, much lighter.

**Empirical claim that should constrain every future design (validated on s18
seed 42 baseline 2026-05-28):** once the RTS-CTS handshake completes, the rest
of the hop succeeds ~90% of the time, and the 9% gap is **ACK-on-routing-SF
loss**, not DATA-on-data-SF loss:

| stage | rate | what's on routing SF | what's on data SF |
|---|---|---|---|
| CTS reaches sender | 883/920 = **96%** | RTS, CTS | — |
| handshake → DATA TX | 870/883 = **98.5%** | — | — |
| DATA → ACK round-trip | 793/870 = **91%** | ACK | DATA |

The DATA layer is essentially solving its own problem; the bottleneck is the
handshake on the contended routing SF.

**This eliminates several design directions:**
- ✗ Improving DATA-layer reliability (DATA-level dedup, FEC, retransmits, larger
  margins) — solving a problem that isn't there.
- ✗ Moving control frames to data SF — disproven by CTS-on-data-SF revert
  (−8pp delivery on 4-seed sweep; sender deafness on routing SF dwarfed any
  savings). Don't re-try this without a fundamentally different design.
- ✗ Tools that improve "DATA reliability" or "data SF coding" — same trap.

**The remaining lever space is inside the handshake itself, on routing SF:**
1. **Each handshake more likely to succeed** — RTS or CTS surviving routing-SF
   contention. Mechanisms: shorter RTS/CTS frames, smarter LBT, capture-effect
   tuning, better blind_until prediction.
2. **Fewer handshakes** — per-hop RTSes multiply by hop count. Mechanisms that
   touch this: forwarder-skip-RTS (use cached route), batched / source-routed
   DATA, per-flow setup.

Note: ACK loss is also a real ~9% pool but it lives in the same SF/contention
class, so anything that lifts handshake reliability tends to lift ACK too.

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
| ACK-exhaustion grace (hold-then-cascade) | **REVERTED — refuted** | on `retries_left<=0` in `ack_timeout_fire`, wait a calculated quiet window (~677ms, for the next-hop's LBT-delayed forward = implicit ACK) + one more same-hop try BEFORE cascading to a fresh node. **Kills the residual ack-exhaustion copy** (s17 seed-1700 `ack_giveup` 22→1; reliably 0–1 across seeds) — but **4-seed delivery −5pp** (1700 +13 / 1701 −27 / 1702 −9 / 1703 +3). Traced to ground: the regression is **all cross-layer** (where the grace exclusively fires; same-layer −2 only), the **hold strands XL messages** (seed-1701 in-flight 5→14, giveup 0→4, XL 33→14/48). The cascade is **load-bearing recovery** to intermittent gateways; delaying it misses windows / runs out of runway. **Same family as RERR + short-TTL: suppressing a recovery mechanism trades copies for strands.** Grace tuning is chaotic (g340 best for 1701/worst for 1700, `auto` opposite — no universal value) and the hold is intrinsic (must wait to learn if the next-hop has the frame), so it can't be cheaply salvaged. **Do not re-add without a non-blocking copy/recovery distinction.** Copy-prevention ≠ delivery on s17 (XL is structural, not contention — consistent with the airtime levers). |

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

### Delivery by traffic class — NEXT: local (same-layer) first
Breaking the post-fix s17 run down by what the traffic actually is — **4-seed sweep
(1700–1703), mean + range:**

| class | mean | range | (seed-1700) |
|---|---|---|---|
| Channels (broadcast gossip) | ~96% | — | — |
| Same-layer DM (within a layer) | **82%** (99/120) | 70–93% | 73% |
| XL **1-gw** (suburb↔center) | **51%** (73/144) | 42–61% | 61% |
| XL **2-gw** (suburb↔suburb) | **25%** (12/48) | 17–33% | 33% |
| ALL DM | 59% (184/312) | 49–65% | 62% |

**Decision (2026-05-26): work LOCAL/same-layer delivery FIRST, then return to
gateway traffic.** Same-layer is foundational — every cross-layer leg rides on
same-layer hops, so lifting it lifts 1-gw and 2-gw too.

**Same-layer is NOT at a multi-hop ceiling (do not assume it is).** Two pieces of
evidence: (a) the rate **swings 70→93% across seeds** — a physics ceiling wouldn't
move 23pp on traffic/collision timing alone, so the bad seeds are losing to
contention/routing, and 93% is demonstrably achievable; (b) a **directional routing
asymmetry** — same node pair, *symmetric* bidir links, yet `c040→c120` = **0/3**
while `c120→c040` = **3/3** at mean **3.3 hops** (seed 1700). A 3-hop pair at 0%
one-way / 100% the other is a routing failure (one direction gets a clean route, the
reverse loops/gives up), not PHY attrition. Failure modes are `next-hop-silent` /
`giveup` (routing/contention), not PHY drops. **Headroom = closing the bad-seed gap.**
Start the local investigation by tracing a working direction vs its failing reverse
(`c040→c120` vs `c120→c040`) to find why one side loops.

**2-gw is robustly the worst** (25% mean, 17–33% *every* seed — confirmed bottleneck,
not noise); it's the eventual gateway target (Stage-2 inter-gateway transit).

### Same-layer anti-loop package — shipped (net +5pp); refinement pending
Built in `dv_dual_sf.lua`: **origin-drop** (a node never re-forwards a frame it
originated — kills the return-to-origin loop seen in `c040→c120`), a **soft
hop-gradient** (`gradient_max_uphill_hops`, default 1: the alternate-route search in
`next_hop_selectable` — shared by the cascade picker, `classify_blind`, and the
`loop_duplicate` retry — prefers routes within `cap` hops of the best, with a 2-pass
fallback that allows uphill rather than strand), and the pre-existing prev-hop
split-horizon. (`prev-hop` already existed; storm/loop-feed are subsumed because all
alt-pickers flow through the gated `next_hop_selectable`.)

**4-seed sweep vs doorstep-only baseline:** ALL **59%→64%**, XL 1-gw **51%→65%**,
XL 2-gw **25%→31%**, same-layer **82%→77%**. So it's a net win — but it helped
**cross-layer**, not the same-layer it targeted, and slightly *regressed* same-layer.

**Why same-layer regressed (the next thing to fix).** Clean within-seed evidence
(seed 1700): the **hard** gradient gave same-layer **93%**, the **soft** gave **70%**.
The soft pass-2 uphill fallback **re-allows the same-layer loops the hard gradient
killed** — and it fires exactly when it shouldn't: under dense-center contention,
pass-1 exhausts the (merely *busy*) near alternates, so pass-2 hands the message a
far/loopy path. That same fallback is what *rescues* cross-layer (sparse/gateway legs
genuinely need the longer path). So: **hard** → same-layer loops die / cross-layer
strands; **soft** → cross-layer recovers / same-layer loops return.

**Refinement — SHIPPED: visited-set loop guard on the DATA frame.** Rather than the
"no short path exists" gate (which fails — the *best* route is non-uphill by
definition, so that gate disables the fallback entirely), the fix carries a **6-byte
visited window** (last 6 carrier short-ids) in the DATA header: the originator seeds
it with [self], each forwarder appends itself (sliding), and `next_hop_selectable`
**refuses to forward to any node already in the window** (prev-hop split-horizon
generalized 1→6, independent of the gradient — an uphill fallback still can't pick a
visited node). This makes the soft gradient's fallback **loop-safe at the source**:
loops can't form, so recovering same-layer doesn't require stranding cross-layer.
Frame budget: `DATA_HDR_LEN` 8→14, so `payload_hard_max` 241→235 (the 6 bytes come
out of the payload, keeping total ≤ the 255 LoRa cap). Config `visited_check_depth`
(1–6) tunes coverage without a wire change.

**4-seed sweep (vs the doorstep-only baseline, and the soft-gradient-only step):**

| class | base | soft only | **+visited-set** |
|---|---|---|---|
| same-layer | 82% | 77% | **92%** |
| XL 1-gw | 51% | 65% | 59% |
| XL 2-gw | 25% | 31% | **42%** |
| ALL | 59% | 64% | **69%** |

Same-layer **recovered + exceeded** (77→92%, the goal — loops killed; variance also
tightened to 87–97% from the old 70–93% swings), 2-gw **+11pp** (31→42), ALL **+5pp**
(64→69). Only 1-gw dipped (65→59, still +8 over base) — the window occasionally
over-constrains a cross-layer first leg; minor, net hugely positive. `origin_loop_drop`
fires 3–12×/seed (real loops caught). Guarded by **t81** (window accumulates
`[1]→[1,2]→[1,2,3]` along a chain + delivers); suite 99/99 (t62 clamp updated 241→235).

### 2-gw Stage-2 transit — root cause: COPY CREATION under ACK loss (NEXT TARGET)
Post-anti-loop, the worst class is 2-gw suburb↔suburb (~42%). Funnel pins it to the
**inter-gateway transit**, not the legs: `12 sent · 11 reached gw1 · 6 transited to gw2
· 6 delivered` — first leg now fine (11/12), final leg perfect (6/6), but only **~45%
transit** the center. (Trace `w015→e020`: clean 4-hop first leg → `gateway_envelope_transit`
→ the gw_w1→gw_e0 forward across the diam-11 center.)

**Mechanism (this is the thing to fix — distinct from the loop class):** the transit
is a long forward across the dense, contended center. A hop ACK gets lost
(contention on the return); the sender can't tell DATA-loss from ACK-loss; the retry
logic **switches to a *different* next-hop**; that fresh node has **never seen the
message → it forwards it → a 2nd live copy**. The visited-set stops *loops* (revisits)
but NOT *fan-out to fresh nodes*. This happens at **every forwarder**, so copies
multiply (trace: `c060` spawned branches to `c173`, `c091`, `c164`) and self-congest
→ more ACK loss → more switches. A positive-feedback **copy storm**, worst on the
longest/most-contended forward (the transit).

**Two complementary fixes:**
1. **Passive (implicit) ACK — ALREADY EXISTED** (`implicit_ack_from_forward`, fires
   ~168×/run): A overhears next-hop B's forwarding RTS (`src==next && dst && ctr_lo &&
   payload_len`) and treats it as the hop ACK. **But it's not enough** — under center
   contention B's forward RTS is LBT-blocked (`rts_tx_blocked channel_busy`) and goes
   out *after* A's ACK-timeout, so A retries before it can fire. (Confirmed in trace:
   `c060` ack-timed-out while `c173`'s forward was still channel-busy-deferred.)
2. **Retry-same-next-hop on ACK-timeout — SHIPPED (the fix).** In `tx_rts_retry`, when
   `reason=="ack_timeout"` the blind-alt switch-to-fresh-node is suppressed (emits
   `ack_retry_same_hop`): we already got a CTS + sent DATA, so the receiver decoded it
   — a missing ACK is a *lost ACK*, not a blind receiver. Retry the SAME hop (its
   `last_acked_from` re-ACKs via CTS-already-received, no re-forward, no copy). Genuine
   unreachability still cascades once `retries_left` hits 0.

**4-seed sweep (vs visited-set baseline):** XL **2-gw 42→60%** (the target, +18pp),
ALL **69→73%**, XL 1-gw 59→63%, same-layer 92→89% (−3, noise-range). The transit is
near-lossless on good seeds (reached-gw1 ≈ transited). `ack_retry_same_hop` ~350×/run
(copies prevented). Suite 100/100. **Residual 2-gw loss** (transit still lossy on some
seeds, e.g. 1703 4/9) is the inherent long-crossing reliability (~0.95^11) + center
contention — the copy-storm itself is fixed; further gains need a shorter transit
(closest-gateway-pair selection) or less center contention.

**Residual ack-exhaustion copy — attempted & REVERTED (see levers table).** After
`ack_retry_same_hop` exhausts (`retries_left<=0`), `ack_timeout_fire` cascades the copy
to a *fresh* next-hop (`path_cascade trigger=ack_giveup`) even when the next-hop already
decoded+forwarded the frame — validated on s17 seed-1700 as **13/22 true duplicates**
(next-hop decoded AND forwarded; cascade target also did) + 4 fizzled attempts, 5 genuine
reroutes. A *hold-then-cascade grace* (wait ~677ms for the next-hop's LBT-delayed forward /
re-ACK, then one more same-hop try, then cascade) **eliminated the copies** (`ack_giveup`
22→1) but **regressed cross-layer delivery −5pp/4-seed** — the hold strands XL messages
bound for intermittent gateways (the cascade is load-bearing recovery). Reverted; it's the
RERR/short-TTL pattern. **The copies are the price of fast cascade-recovery on s17; XL is
structural, so removing copy-contention doesn't raise delivery here.**

**Copy sources — measured (`dm_delivery_breakdown.py --copies`).** The copy population is
NOT dominated by the `ack_giveup` cascade (~10/run) the grace targeted — it's **`blind_alt`
(~176/run, the cts-timeout blind switch)**, then `loop_duplicate` (~76). Characterising the
176 blind_alt copies (s17_metro fixture): **95% cross-layer** (168/176); **108/176 the
abandoned next-hop had already FORWARDED the frame** (decoded + relaying), only **65 were
genuine dead-ends** (decoded, never forwarded); gap decode→blind_alt **median 3.4 s / p90
48 s / max 34 min** — long-tail re-attempts kept alive by cascade-requeue, NOT tight cascades.

**Mechanism (traced: gw_e0 ctr=2, c163→c139).** The next-hop decodes our frame and
*immediately forwards it* (`data_rx`+`ack_tx`+`rts_tx next=…` within ~80 ms), but (a) its ACK
collides at the sender, (b) the sender misses the implicit-ACK because it is **mid-retransmit
(half-duplex)** when the forward goes out, and (c) the next-hop is now **busy forwarding our
own frame** → unresponsive to the retry (`cts_timeout`) → `classify_blind` marks it blind →
the sender fans a copy to a fresh node. **The next-hop's success is misread as failure.** Same
root as `ack_giveup` (lost hop-confirmation on a contended XL leg); blind_alt is the dominant
path and operates over **seconds-to-minutes**, which is exactly why the ~677 ms grace couldn't
touch it.

**Lever implication.** A short grace is the wrong tool. Real levers: (1) **don't re-attempt a
frame whose next-hop is actively forwarding it** (the 108 cases — needs longer-horizon
"delivered-to-next-hop" memory); (2) **better implicit-ACK capture** (the sender blinds itself
by retransmitting over the next-hop's forward). BUT **65/176 were genuine dead-ends** needing a
reroute — blanket suppression strands those (the grace lesson). Any fix must distinguish
"forwarding" from "dead-end" with evidence the sender cheaply has — and, since XL is structural
on s17, **gate copy-reduction on the `--copies` metric + a dense scenario (s16), not s17
delivery.**

### Copy prevention reassessed (2026-05-28) — dedup-on-overhear attempted & REVERTED

**Prototype.** In-tree only, never committed. Each node overheard forward-RTSes on
the routing SF and recorded `(dst, ctr_lo, payload_len) → ts` in a 60 s sliding
table (`seen_fwd`). Two suppression triggers:
- **STEP 2 (drop-held):** on each new overhear, drop any matching `pending_tx` /
  `tx_queue` entry already held for forwarding (target: blind_alt parallel copies).
- **STEP 3 (drop-incoming):** on DATA receive, if the frame's key is in `seen_fwd`,
  send ACK then suppress the forward (target: "frame already propagating elsewhere").

**Why STEP 3 broke chains (correctness bug, user-identified).** In a linear chain
`A→B→C→D`, RTS travels on long-range routing SF so C overhears `A→B`'s forward-RTS
before C is even the intended forwarder. C records `(D, ctr_lo, len)`. Then DATA
arrives from B; STEP 3 fires; C ACKs B and silently drops. D never receives. The
key `(dst, ctr_lo, len)` cannot distinguish "I'm next in line" from "parallel
chain". Empirical signature on s18 seed 42: first-hop **ACKs up +2** while
**deliveries down −15** (68→55%) — exactly silent-drop-after-ACK.

**Vector check via `--copies` + `--airtime`.** 4-seed s18 realistic (STEP 3 removed,
STEP 2 retained but never fired):

| seed | delivered | copies | RTS+CTS | DATA | ACK | total airtime |
|---|---|---|---|---|---|---|
| 42  | 68% | 21 (8 blind / 12 loop / 1 giveup) | 52% | 26% | 21% | 308,642 ms |
| 17  | 87% | 3  | 51% | 27% | 21% | 346,348 ms |
| 91  | 81% | 3  | 52% | 25% | 21% | 293,807 ms |
| 123 | 90% | 3  | 51% | 26% | 21% | 324,731 ms |

Copy count spans 7× (3↔21), total airtime spans only 1.2× — **uncorrelated**. Seed
17 has the *most* airtime with only 3 copies; seed 42 has 7× more copies but
mid-pack airtime. A single copy ≈ one extra handshake at SF8 ≈ 250–600 ms; the 18
surplus copies on seed 42 ≈ ~2–3% of that run's airtime. STEP 2 fired 0× on all 4
seeds — the conditions (hold AND overhear a *parallel* forward of the same key) are
narrow on realistic traffic; the OFF baseline's `blind_alt` copies are mostly
genuine reroutes after a real failure, not parallel-copy storms.

**Airtime composition is invariant: RTS+CTS 51–52% / DATA 25–27% / ACK 21%** across
*all* seeds despite delivery ranging 68→90%. The structural cost is fanout
(mean 8.5 decoders per message) × hop count × retry count, dominated by the
RTS/CTS exchange every neighbour decodes. Copies live in the noise.

**Decision.** Removed all copy-suppression code (in-tree changes only, file
reverted to `8e4c54b` HEAD). Future copy work would need (a) a copy-cost scenario
where copies actually correlate with airtime/delivery delta (i.e. dense XL like
s16/s17), and (b) a chain-safe discriminator — at minimum extra wire info in RTS
(e.g. hops-from-origin) since cached `(src, next)` alone breaks on >2-hop chains.

**Next vector (right lever).** Pivot from copy prevention to:
1. **Hop-count reduction** — the airtime table is dominated by long-haul messages
   (e.g. `dave→First_Hill_Skyline` = 14.5 s on a single message). If those paths
   are geographically inflated, route audit + better next-hop selection is the
   biggest pool.
2. **Retry reduction** — RTS+CTS is 52% of airtime; every CTS-timeout retry
   doubles that slice. LBT tuning, longer `rts_timeout` on dense regimes, CTS
   reliability.
3. **Decode-overhead surface** — fanout 8.5 means every RTS occupies airtime at
   8 neighbours. Range tuning, RTS shortening, or selective listen would move
   the floor more than any per-message lever.
4. **Copy prevention** — last, only if (a) and (b) above are addressed and the
   chain-safe discriminator question is solved.

### Copy prevention — second attempt (2026-05-28): HALT cancellation-on-retry, REVERTED

**Prototype.** A retry-cancellation protocol designed to prevent copy creation
*at the source* rather than dropping in-flight duplicates. RTS gained
`RTS_FLAG_IS_RETRY` (0x04) set on every `tx_rts_retry`. A new 2-byte HALT frame
(`'X' + target`) was sent by any node holding `(origin, ctr_lo)` when it
overheard an RTS-rty for that message. The RTS-rty receiver deferred CTS by
`airtime(routing_sf, HALT_LEN) + slack` (~54 ms @ SF8/BW250, ~90 ms @ SF8/BW125).
On HALT, the would-be CTS-er dropped the CTS and the retry sender cancelled its
pending TX (treated as a confirmed delivery). Gateway cross-layer forwards
(`gw_relay`) were exempt to preserve visit-schedule timing.

**Why it didn't work — three nested measurement findings on s18 seed 42:**

1. **`(dst, ctr_lo, payload_len)` aliases catastrophically.** First run gave
   **39/42 (93 %) false cancellations, −14 pp delivery (54 % vs 68 %).** The
   4-bit `ctr_lo` cycles every 16 messages per sender; same-dst messages with
   similar payload sizes collide constantly within the 60 s holder TTL — the
   problem is structurally identical to the dedup-on-overhear key issue.
2. **Adding origin to the wire (1 B IS_RETRY-only RTS extension) didn't fix
   the cancellation problem.** With precise `(origin, ctr_lo)` keying the
   false-cancel rate was unchanged: **39/42 cancellations still hit messages
   that didn't deliver.** The real cause: **mid-chain `fwd_confirmed` holders
   are unsafe.** A forwarder's `ack_rx` ("I passed it one hop") doesn't mean
   delivered — the next-hop can still drop it, and the cancelled retry was the
   salvage path.
3. **Restricting holder predicate to `delivered_set` only** (final-dst
   confirmed delivery is the only unambiguous signal) is safe — delivery
   76/113 vs baseline 77/113 — but **the mechanism barely engages: 3 halt_tx
   on the whole s18 run, 0 successful cancellations, `tx_blind_alt` count 13
   vs baseline ~12.** The final dst is usually out of range of the retry
   sender on multi-hop paths, so safe-HALT can't actually prevent copies.

| variant | delivery | halt_tx | cancellations (true / false) | tx_blind_alt |
|---|---:|---:|---:|---:|
| no HALT (baseline) | 77/113 (68 %) | — | — | ~12 |
| HALT raw — keyed (dst,ctr_lo,len) | 61/113 (54 %) | 54 | 2 / 38 | 4 |
| HALT origin-keyed (`fwd_confirmed` on) | 66/113 (58 %) | 87 | 3 / 39 | 7 |
| HALT origin-keyed (`delivered_set` only) | **76/113 (67 %)** | **3** | **0 / 0** | **13** |

**Costs the mechanism added during the experiment.** Every RTS-rty receiver
deferred CTS by T_delay (~54–90 ms depending on routing SF / BW) — pure
latency on every retry with no benefit. 4 t-suite tests regressed initially
(t72/t73/t74 from gateway visit-schedule timing, t78 long-chain) until gateway
forwards were exempted via `gw_relay`-skip and `pending_rx_expiry` was moved
inside the deferred-CTS closure. The originator marking `fwd_confirmed` on her
own first-hop ACK caused her to HALT her own next-hop's forward (t37 plain-msg
regression) until an `origin == self.id` guard was added.

**Why the design can't be patched into working.** The fundamental tension:
- Mid-chain holders are unsafe (can't confirm delivery from one hop ACK).
- Stronger evidence than `delivered_set` doesn't exist short of e2e ACK.
- But by the time the originator gets e2e ACK she already knows delivery
  succeeded — HALT isn't needed for that case.
- The safe variant (`delivered_set` only) fires only when dst is in range of
  retry sender, which is the easy 1-hop case where copies don't form anyway.

The asymmetry kills it: the cases where HALT could help (mid-chain copy
storms) are exactly where the holder signal is too weak; the cases where the
holder signal is strong (e2e-confirmed delivery) are where copies are not the
problem.

**Decision.** Reverted in-tree, never committed. `scenarios/dv_dual_sf.lua`
restored to `43c45a9`; 75/75 t-tests pass; s18 delivery 77/113 = 68 %.

**Next vector (NOT HALT v2).** Don't reattempt with more holders or stronger
signals — the issue is intrinsic. The next lever for *copy reduction* (not
prevention via cancellation) is **next-hop-liveness defer** — gate
`tx_blind_alt` creation when the abandoned hop showed recent activity
(`cts_tx` within ~1 s ≈ "busy, not dead"). Measured on s18 to be preventable
for **4/5 (80 %) flag-ON / 8/12 (67 %) flag-OFF blind_alts**, with evidence
always being a recent `cts_tx` from the abandoned hop. No wire-format change,
no holder signal needed — purely a sender-side decision. That work is the
right next attempt.

### Retry pool — cts_timeout dominates; airtime tail is retries × hops, not inflated routes (2026-05-28)

After copy-prevention reassessment (above), the **retry pool** turned out to be the
actual airtime lever. On s18 seed 42: **178 rts_retry events for 113 sends ≈ 1.6
retries/msg**, and **52% of run airtime is RTS+CTS** with the split invariant
(51–52% / 25–27% / 21%) across seeds 17/42/91/123.

**Hop-count tail profile (added `dm_delivery_breakdown --tail`).** Top-10 messages
= 29.7% of total run airtime. Across those 10 messages, **chain length is at or
below the 2 km/hop geographic minimum** (`Fremont01→CH_RPTR` 21.8 km in 10 hops =
2.2 km/hop; `dave→First_Hill_Skyline` 10.4 km in 5 hops = 2.1 km/hop). Routing is
near-optimal on s18's explicit-link topology. **Top-10 airtime per chain-hop =
1453 ms vs nominal RTS+CTS+DATA+ACK ≈ 500–700 ms → ~2–3× tax per hop, paid in
retries not extra hops.** Top-10 retries / total retries = 19 / 178 = 10.7% — retry
tax is **uniform, not tail-concentrated**. Reducing per-message retry rate ~50%
would save ~25% of total airtime.

Single routing outlier worth a separate look (not in top-10 but flagged): on seed
42, `Martin_Room→alice (2)` took 13 hops for 6.7 km (~0.5 km/hop) and did not
deliver. A routing bug, not a normal long-haul.

**cts_timeout breakdown (instrumented; 110 of 178 retries on seed 42).** Categorized
by inspecting the next-hop's events in `[t_rts, t_retry]`:

| category | count | % | meaning |
|---|---|---|---|
| `silent_no_rx` | 56 | **51%** | RTS never decoded at receiver — routing-SF collision direction A→R. |
| `cts_sent_but_lost` | 35 | **32%** | Receiver decoded RTS, emitted CTS; CTS lost on routing-SF return. |
| `busy_pending_tx` | 10 | 9% | Receiver had its own pending_tx, silent-dropped our RTS. |
| `next_hop_changed` | 7 | 6% | Sender's retry switched next-hop — not same-hop cts_timeout. |
| `busy_other_tx` / `busy_other_rts` | 1+1 | 2% | Receiver was TXing / RXing other traffic. |
| `silent_blind_§8.4` | 0 | 0% | No detected case where receiver was in CTS→data_sf deaf window. The existing `blind_until` mitigation catches §8.4 cases before they become cts_timeout. |

**Implication:** 83% of cts_timeouts are **routing-SF collision** in one direction or
the other (RTS or CTS), not receiver-busy and not §8.4 deaf window. The lever is
the routing-SF contention itself. CTS-on-data-SF targets the 32% `cts_sent_but_lost`
class directly (≈6% total airtime). The 51% `silent_no_rx` class is bigger but
needs a different fix — sender-side awareness of receiver-availability before TX,
RTS shortening, or fanout reduction.

### NACK_BUSY_TX (re-add, with safeguards) — attempted & REVERTED (2026-05-28)

Targeted the 9% `busy_pending_tx` class. Mechanism: when a receiver has its own
pending_tx and an inbound RTS arrives, instead of the historic silent drop, send
a NACK with `NACK_REASON_BUSY_TX` carrying an airtime-derived `busy_for_ms`
estimate. Sender's existing busy_rx handler (line 10535) treats both reason codes
identically (cancel rts_timeout, set `blind_until`, wait-or-requeue per
`NACK_WAIT_THRESHOLD_MS`).

**Chesterton's fence the diff inherited.** The exact behavior existed historically
and was removed (line 9889 comment): on s03 a stuck ACK-loss-loop node predicted
busy_for_ms = 5 s but was actually busy 60+ s → 28 s of NACK chain per stuck node.
After `8e4c54b` (ack_retry_same_hop) the stuck-loop pathology should be less severe;
re-attempted with safeguards (fresh-pending_tx only: `requeue_count==0 AND
last_rts_attempt_seq<=1`, estimate capped at 2 s == `NACK_WAIT_THRESHOLD_MS`).

**4-seed s18 sweep (ON vs OFF override per node):**

| seed | mode | delivered | airtime (ms) | nack_busy_tx | silent_drop | retries |
|---|---|---|---|---|---|---|
| 42  | ON  | 77 (68%) | 308,642 | 0 | 13 | 178 |
| 42  | OFF | 77 (68%) | 308,642 | 0 | 13 | 178 |
| 17  | ON  | 98 (87%) | 348,276 | **1** | 19 | 217 |
| 17  | OFF | 98 (87%) | 346,348 | 0 | 13 | 194 |
| 91  | ON  | 89 (79%) | 286,118 | 0 | 9 | 164 |
| 91  | OFF | 89 (79%) | 286,118 | 0 | 9 | 164 |
| 123 | ON  | 101 (89%) | 322,355 | 0 | 4 | 186 |
| 123 | OFF | 101 (89%) | 322,355 | 0 | 4 | 186 |

**Result.** The safeguards correctly identified that all 13 pending_tx-drop events
on seed 42 (and the equivalents on other seeds) involve receivers whose pending_tx
is on **attempt_seq 5–52** — deeply mid-retry, not fresh. NACK_BUSY_TX fired **1×
across 4 runs** (seed 17 only). That single fire produced **+23 retries, +6 silent
drops, +1,928 ms airtime (+0.5%)** — a small regression, not an improvement.
Delivery unchanged. **Confirms the original silent-drop decision was correct for
the stuck-receiver case.** Reverted; no commit.

**Lever decision.** Pivot to CTS-on-data-SF (the 32% `cts_sent_but_lost` class — see
next section for scope).

### CTS-on-data-SF — attempted & REVERTED (2026-05-28)

Targeted the `cts_sent_but_lost` class (32% of cts_timeouts = ~6% airtime
budget). Design: move the RTS→CTS response off the contended routing SF onto a
"rendezvous SF" = min(sender's RTS bitmap) (the lowest data SF — shortest CTS
airtime, link guaranteed to support it). Both sides compute the rendezvous SF
from the bitmap already in the RTS — no wire-format change. After RTS TX,
sender retunes RX to rendezvous_sf; on CTS RX, restore RX to routing_sf for
ACK. Existing `blind_until` mitigation (overheard CTS on routing_sf bumps the
deafness window of every neighbor) broke under this change — CTS lives on
rendezvous_sf, so routing_sf overhearers don't see it. Rebuilt as a
**prediction-from-overheard-RTS** path: every node that overhears an RTS to
some other receiver bumps `blind_until[receiver]` for `airtime(rendezvous_sf,
CTS) + cts_to_data_gap + airtime(max_data_sf, max DATA)`.

**4-seed s18 sweep:**

| seed | ON | OFF | Δ |
|---|---|---|---|
| 42  | 79 (70%) | 79 (70%) | 0 |
| 17  | 79 (**70%**) | 97 (**86%**) | **−16pp** |
| 91  | 85 (75%) | 87 (77%) | −2 |
| 123 | 82 (**73%**) | 101 (**89%**) | **−16pp** |
| mean | **72%** | **80%** | **−8pp** |

Retries 195 → 447 mean (+128%). Airtime −6% mean — but the savings came from
messages *failing to deliver*, not from being more efficient.

**Root cause of the regression — sender deafness on routing_sf during CTS
wait.** With fanout 8.5, every sender retuned to rendezvous_sf for the
CTS-wait window (~50 ms at SF7 CTS + DATA airtime) drops every neighbor's
RTS that arrives in that window as `drop_sf_mismatch`. cts_timeout breakdown
on seed 42 (ON, with RTS-prediction blind_until): `silent_no_rx` 56 → 217
(+161 cases). We attacked the 32% `cts_sent_but_lost` bucket and converted
it (plus more) into the larger `silent_no_rx` bucket via sender deafness —
net negative.

**Structural finding worth keeping (the reason this isn't fixable by Option A
either).** Frame distribution on s18 seed 42:
- Routing SF (SF8): 178 RTS + 422 RTS-rty + 622 RTS-fwd + 920 CTS + ~750 ACK = ~2900 frames
- Data SF7 (DATA): 837 frames (~96% of all DATA on the min SF)
- Data SF9: 33 DATA + 0 channel-M on s18 (other scenarios have channel-M here)

There's **no SF that's clearly less busy than routing SF** by frame count, and
no matter which we pick we trade the cts_sent_but_lost class for a new
sender-deafness class. The "routing SF is the bottleneck" framing was right
about the 32% pool living there but wrong about there being a cheaper place
to put CTS.

**Lever implication.** Of the 110 cts_timeouts on seed 42:
- 51% `silent_no_rx` (RTS direction) — needs receiver-availability signal *before* RTS, not SF migration.
- 32% `cts_sent_but_lost` (CTS direction) — moving SF doesn't help; needs collision-avoidance for CTS itself (e.g., schedule-aware CTS, capture-effect tuning, or a fundamentally different MAC).
- 9% `busy_pending_tx` — silent-drop is correct (validated by NACK_BUSY_TX revert).

The cheapest remaining lever is probably **NOT in the cts_timeout pool**.
Total cts_timeout retries cost ~55 s/run (18% airtime); the rest of the
retry tax (the other 80%+) and the multi-hop forwarding overhead dominate.
Re-examine the airtime tail (already in `--tail`) with fresh eyes:
hop-count was already optimal on s18 explicit-link, but the *per-hop
retry tax* on intermediate hops is uniform across all messages. The next
lever may be **inside the forwarder cascade**, not the originator's first
hop. Concrete candidate: read the airtime composition of the forwarder
half of multi-hop messages — does the cts_timeout tax fall harder on
forwarders than originators? If yes, the lever is there.

### Peer-busy prediction (`rts_sender_busy` blind_until extension) — attempted & REVERTED (2026-05-28)

Targeted the 51% `silent_no_rx` cts_timeout class. Mechanism: every overheard
RTS on routing SF tells us its SENDER is now mid-handshake; mark
`blind_until[r.src] = now + rts_timeout_base_ms` so classify_blind defers /
alts our own RTSes addressed to that sender. Used the existing blind_until
table (no new state machinery) and the existing three consult sites
(issue_send / tx_rts_retry / rts_timeout_fire).

**Two attempts, both reverted:**

1. **Wide window** (full handshake = rts_timeout + cts_to_data_gap + DATA + ACK
   ≈ 800 ms): seed 42 −2pp delivery, `tx_blind_alt` +317% (excess copy
   creation from over-aggressive alt-switching).
2. **Narrow window** (just rts_timeout ≈ 250 ms — confident CTS-wait lower
   bound): mean across 4 seeds **−7pp delivery** with one seed (17) dropping
   **−28pp** (87% → 59%). Mechanism causes a **defer-cascade**: a node's
   neighbor is overheard active → marked busy → node defers → defer expires →
   retries → neighbor still active → marked busy again → loop. Without the
   prediction the node would have hit `silent_no_rx` then `blind_alt`-switched
   to a fresh next-hop after `rts_max_retries`, eventually delivering. With
   the prediction, the message stays in pending_tx until the simulation ends
   ("in-flight at end" failure category). 25 of 46 failures on seed 17 hit
   this pattern; every one of dave(138)'s 14 messages failed.

**Meta-pattern across the four reverted attempts in this session.** Each
attempt added either a PROACTIVE PREDICTION (peer_busy, predicted_from_rts) or
a NEW RESPONSE (NACK_BUSY_TX) that disrupted the existing reactive recovery
chain (cts_timeout → retry → blind_alt → cascade). The existing protocol is
tuned around "fail fast, recover via the cascade machinery." Predictive
interventions that try to *prevent* the cts_timeout end up preventing the
recovery too, and messages get stuck.

**Implication for future handshake-reliability levers.** Stick to changes that
improve raw handshake success WITHOUT touching the reactive recovery path.
That rules out anything in the blind_until / classify_blind family. Concrete
remaining candidates:
- **Shorter RTS / CTS frames** (fewer routing-SF bytes = less collision
  window). RTS is already 8 B and CTS 3 B — limited shrink room.
- **Tighter LBT before RTS TX** (PHY-level sense, not a state-machine
  prediction; doesn't enter classify_blind).
- **Capture-effect tuning** (SimController parameter, not firmware).
- **Volume reduction** (forwarder route-cached fast handshake — fewer
  handshakes period; biggest pool but biggest design surface). Option A from
  the scope discussion.

### Wire-format compaction — what's actually possible (2026-05-28)

**Goal evaluated:** shrink RTS from 8 B to save air. At SF8/BW125/CR5,
airtime is symbol-quantized: 7 B and 8 B both fall in `pay_sym=23` bucket
(88.6 ms); the bucket boundary is at L=6 (78.4 ms, saves ~10.2 ms/RTS ≈ ~4%
total air on s18 seed 42). So byte savings only register when RTS hits ≤6 B.

**What landed (committed):**
- **Step 2 — `sf_bitmap` (8 b) → `sf_index` (2 b).** `allowed_data_sfs` is a
  leaf-wide config invariant, so the bitmap is unnecessary on the wire. 4-seed
  s18 sweep: byte-for-byte identical to HEAD (delivery, airtime, every event).
  Frees 6 bits in byte 6 for future packing. (Commit: `11320bd`.)

**What didn't ship (rejected with data):**
- **Dropping `payload_len` entirely** (step 1): −2.5pp delivery. Forwarder-keyed
  `(src, dst, ctr_lo)` collides across distinct originators in the implicit-ACK
  match → wrongly cleared pending_tx → "in-flight at end" failures.
- **CRC8(origin, ctr) replaces payload_len** (step 1'): −4pp delivery. CRC8
  fixes implicit-ACK uniqueness BUT receiver-side `pending_rx_expiry` now
  falls back to worst-case `max_payload_bytes=230` (was actual). Receivers
  hold pending_rx ~2× longer → `drop_pending_tx` 4-6× more → other senders'
  RTSes silently dropped. The `start_pending_rx_expiry` comment (line ~6747)
  explicitly flags this trap.
- **CRC4 + payload_len_q4 packed in 1 byte** (step 1'' compromise): −1pp,
  closer but still net negative. 16-byte quantization over-estimates s18's
  19-byte median payload → expiry still inflated, `drop_pending_tx` still
  elevated (especially seed 17: 62 vs HEAD's 13).

**Load-bearing finding:** `payload_len` in RTS serves *two* concurrent purposes
that can't both be cheapened. Match-key discrimination (CRC works) AND
receiver-expiry sizing (needs real bytes, not buckets) both need 1 byte's
worth of information. The current `payload_len` byte already efficiently
serves both — replacing it with anything ≤1 byte loses one function.

**Remaining preparation work that could land:**
- **§10 cmd-nibble pack (step 3).** Reshapes byte 0 to `cmd(4)|leaf_id(4)`.
  RTS goes 8 → 7 B. No airtime savings at SF8 (same symbol bucket). Worth it
  only for code clarity + extension headroom, not air.

**Conclusion.** The realistic ceiling on s18 RTS air via field-level compaction
on the current protocol design is roughly the step 2 result — zero air saved
but bits freed for future packing. Reaching 6 B / 10 ms-per-RTS savings would
need a deeper protocol change (e.g. encoding payload_len's two roles into
side-channel state, or a different MAC entirely). Not pursued.

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
