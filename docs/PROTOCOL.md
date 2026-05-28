# LoRa Mesh Protocol — `dv_dual_sf` Reference

Implementation-grade reference for the protocol implemented in
`scenarios/dv_dual_sf.lua`. Everything in this document traces to
specific lines of that script as of git `HEAD`.

The protocol is **distance-vector routing on a control SF + per-hop
unicast handshake on an adaptive data SF**. Hop-level reliability is
achieved through an explicit RTS/CTS/DATA/ACK exchange. Routing is
maintained through periodic + triggered beacons. Two layers can coexist on
the same channel via a 4-bit `leaf_id` filter. In current architecture,
JSON config names the logical `layer_id`; the on-wire `leaf_id` is
`layer_id & 0x0f`.

---

## Table of contents

1. [Design philosophy](#1-design-philosophy)
2. [Architecture overview](#2-architecture-overview)
3. [Frame formats (bit-level)](#3-frame-formats-bit-level)
4. [Per-neighbor SNR EWMA + ACK piggyback](#4-per-neighbor-snr-ewma--ack-piggyback)
5. [Routing — distance-vector with K=3 alts](#5-routing--distance-vector-with-k3-alts)
6. [Beacon plane](#6-beacon-plane)
7. [Data plane — happy path](#7-data-plane--happy-path) — incl. **§7.4 End-to-end delivery ACK**
8. [Data plane — failure modes](#8-data-plane--failure-modes)
9. [Layer filtering (`leaf_id`)](#9-layer-filtering-leaf_id)
10. [Origin-level dedup](#10-origin-level-dedup)
10a. [Anti-spam — 1st-hop statistical rate-limit](#10a-anti-spam--1st-hop-statistical-rate-limit)
11. [Half-duplex, LBT, duty cycle](#11-half-duplex-lbt-duty-cycle) — incl. **§11.5 budget tiers**, **§11.6 node_state_snapshot**
11a. [Bootstrap UX (cold-start joiners)](#11a-bootstrap-ux-cold-start-joiners)
12. [Lifecycle: on_init + on_recv + on_radio_busy](#12-lifecycle-on_init--on_recv--on_radio_busy)
13. [Event vocabulary](#13-event-vocabulary)
14. [Configuration reference](#14-configuration-reference)
15. [Known limitations](#15-known-limitations)

---

## 1. Design philosophy

- **Real-LoRa-faithful.** Only model what real SX1262 / SX1276 hardware
  can do. Per-frame TX power is fixed (per-node config), CAD/RSSI gates
  TX (LBT), preamble detection drives the beacon throttle. Anything
  the radio can't physically do is forbidden in the protocol.
- **Two SFs per node.** A fast routing SF for control (BCN, RTS, ACK)
  and a per-flight chosen data SF for the heavy DATA payload. Receivers
  pick the data SF from a sender-supplied bitmap based on the inbound
  SNR EWMA.
- **Hop-level reliable, end-to-end best-effort.** Each hop is
  acknowledged. End-to-end delivery rides on per-hop reliability; the
  application layer can layer dedup via `(origin, dst, ctr)`.
- **Routing is decentralized DV.** No central controller. Each node
  announces its known routes via beacon; receivers merge into a local
  K=3 candidate list per destination, pick the best for forwarding.
- **Throttle-and-defer over admit-and-collide.** Beacons skip when
  channel is busy. RTS waits briefly before forcing onto a busy
  channel. Triggered beacons fire urgently for routing changes;
  periodic beacons are slow keep-alive.
- **Bit-tight wire format.** Routing fields are 4-8 bits as needed.
  Total control overhead per flight is ~14 bytes (RTS+CTS+ACK), down
  from 17 in the byte-aligned baseline.

---

## 2. Architecture overview

```
                        ┌────────────────────┐
                        │ Application layer  │
                        │  (your script)     │
                        └─────────┬──────────┘
                                  │ on_command "send X msg"
                                  ▼
            ┌──────────────────────────────────────────┐
            │ Mesh layer (this protocol)               │
            │                                          │
            │  ┌─────────────┐    ┌──────────────────┐ │
            │  │ Beacon plane│    │ Data plane       │ │
            │  │ (routing_sf)│    │ (RTS/CTS/DATA/   │ │
            │  │             │    │  ACK/NACK)       │ │
            │  │ - DV merge  │    │                  │ │
            │  │ - K=3 alts  │    │ - dual-SF dance  │ │
            │  │ - network_  │    │ - dedup          │ │
            │  │   id filter │    │ - blind-window   │ │
            │  │ - throttle  │    │   mitigation     │ │
            │  └─────────────┘    └──────────────────┘ │
            └────────────────────┬─────────────────────┘
                                 │ self:tx() / on_recv()
                                 ▼
            ┌──────────────────────────────────────────┐
            │ Runtime / radio (SX1262 model)           │
            │ - airtime, half-duplex, capture, CAD/LBT │
            │ - duty cycle, on_preamble_detected IRQ   │
            └──────────────────────────────────────────┘
```

**Three logical planes** that share one radio:

- **Beacon plane** — broadcasts of the local routing table on
  `routing_sf`. Every node listens on `routing_sf` by default. Throttled
  to suppress collisions in dense meshes.
- **Data plane** — unicast handshake. RTS+ACK ride on `routing_sf`;
  CTS+DATA+NACK ride on the chosen data SF. The originator/forwarder
  retunes RX between the two SFs across the handshake.
- **Routing plane** — local-only. The DV merge runs at the receiver,
  storing K=3 candidates per destination, used by data-plane
  forwarding decisions and by the F1 blind-window mitigation.

---

## 3. Frame formats (bit-level)

All frames begin with a 1-byte ASCII tag for cheap dispatch. Bit fields
within bytes are MSB-first within each byte. Multi-byte numeric fields
are little-endian (lo byte first) where applicable.

### 3.1 Beacon (`'B'`) — 8 + [1+4L]? + 3n + [32]? + [1+ext]? bytes

Wire format (see ROADMAP §7.0.2 for the full bit-assignment rationale):

```
byte:  0      1                                        2     3        4..7
       ┌───┬──────────────────────────────────────────┬─────┬────────┬────────────┐
       │'B'│ leaf_id(4) │ has_schedule(1) │           │ src │S│E│n  │ key_hash32 │
       │   │ self_gateway(1) │ is_mobile(1) │ rsv(1)  │     │ │ │6b │    (LE)    │
       └───┴──────────────────────────────────────────┴─────┴────────┴────────────┘

if has_schedule == 1 (optional schedule block):
  byte 8:       layer_count(8)
  bytes 9..(8 + 4×layer_count):
                schedule records (4 B each)

  schedule record (4 bytes):
       ┌─────────────────────────────┬──────────────────┬───────────────────┬──────────┐
       │ layer(4) │ (sf-5)(3) │ P5(1) │ duration_100ms(8)│ countdown_100ms(8) │ period_units(8) │
       └─────────────────────────────┴──────────────────┴───────────────────┴──────────┘
  (byte 2 is a live countdown to the next foreign-layer window, measured from
   this beacon's send time -- see "Gateway schedule records" below)

route entries × n_entries (3 bytes each, start after fixed key_hash32 and
optional schedule block):
       ┌──────┬──────┬────────────────────────────────────────┐
       │ dest │ next │ score_bucket(4) │ rsv(3) │ is_gw(1) │ hops(8) │
       └──────┴──────┴────────────────────────────────────────┘

if S == 1:
  trailing destination-seen bitmap: 32 bytes, bits for node ids 0..254

if E == 1:
  trailing extension block after the optional bitmap:
    ext_len(8), then TLVs totalling ext_len bytes

  TLV header byte:
       ┌─────────┬────────┐
       │ type(4) │ len(4) │
       └─────────┴────────┘

  type 1: suspect/silent node ids, payload = len × node_id(8)
  type 2: explicit liveness state, payload = repeated {node_id(8), state(8)}
          state: 1=suspect, 2=silent, 3=dead
  type 3: channel_digest (§3.4.1), payload = count(8) + count × channel_msg_id(32)
  type 4: gateway_layer (cross-layer routing propagation), split-list
          form. payload = N × gw_id(8) followed by N × dest_layer(4)
          packed two nibbles per byte:
            byte 0..N-1:           N × gw_id(8)
            byte N..N+ceil(N/2)-1: layer[i] in byte N + i/2;
                                   low nibble if i even, high nibble if i odd
                                   odd N: tail high nibble = 0 (unused)
          N is recovered from len as N = (2 * len) // 3
          valid len values: 2, 3, 5, 6, 8, 9, 11, 12, 14 (max 9 entries)
```

**Byte-1 flag bits:**
- `leaf_id` (4 bits, 7:4): active layer nibble, derived from
  `layer_id & 0x0f`. Receivers reject foreign-layer beacons before any
  rt_merge work.
- `has_schedule` (1 bit, 3): when 1, a schedule block follows immediately
  after `key_hash32`. Implemented for single-radio gateways; the block
  advertises when the gateway listens on secondary layers.
- `self_gateway` (1 bit, 2): sender is an internet/backbone gateway.
- `is_mobile` (1 bit, 1): sender is a mobile node.
- `rsv` (1 bit, 0): reserved, must be zero.

**Fixed header fields:**
- `src` (8 bits): beacon sender's node id.
- `S` (1 bit, bit 7 of byte 3): a 32-byte destination-seen bitmap follows
  the route-entry block.
- `E` (1 bit, bit 6 of byte 3): a compact extension block follows after the
  route-entry block and optional bitmap.
- `n_entries` (6 bits, bits 5:0): route-entry count in this page (capped by
  `beacon_max_entries`; a 151-byte frame cap fits 47 current 3-byte entries
  after the fixed 8-byte BCN header).
- `key_hash32` (32 bits, little-endian): compact hash of the sender's
  permanent public key. This makes every BCN assertion `src=X` checkable
  against `id_bind[X]`.

**BCN identity binding:** on every decoded BCN, receivers update
`id_bind[src]` from `key_hash32`. If no binding exists, create one with
`source="bcn"` and `confidence="claimed"`. If the existing binding has the
same hash, refresh `last_seen_ms` and `last_key_seen_ms`. If the existing
binding has a different hash, emit `addr_conflict_observed`; this is hard
evidence of duplicate/recycled short-id use.

**Own-id defense + forced-rejoin recovery.** When the conflict involves
*our own* short id (`node_id == self.id` and the stored `prev.key_hash32`
matches `self.key_hash32`), the adopted owner emits a defensive J_DENY
with `reason=OWN_ID_DEFENSE`, carrying its own `lease_age_seconds` and
`claim_epoch`. The duplicate (claimant) runs the tie-break in its J_DENY
handler: older lease wins; equal → higher epoch; equal → lower key_hash.
Loser triggers `forced_rejoin`: yields the contested id (adds it to
`join_denied_ids`), clears `joined`, drops self-binding, re-runs
`join_start_claim`, and emits `addr_conflict_forced_rejoin`. Winner
stays adopted unchanged. Telemetry: `addr_conflict_defense` (the DENY
emit) and `addr_conflict_tie_break` (winner-or-loser determination).
Verified by `test/t60_addr_conflict_forced_rejoin.json`.

**Mobile identity beacons:** mobile nodes emit BCN with `is_mobile=1`,
`key_hash32`, and `n_entries=0`. They omit route entries, destination-seen
bitmap, and liveness extensions. This keeps mobile endpoints visible and
identity-checkable without advertising them as transit routers.

**Gateway schedule records:** gateways with `gateway_layers` set emit
`has_schedule=1` and append one 4-byte schedule record per secondary layer.
The record's layer field is the on-wire layer nibble (`layer_id & 0x0f`),
not the full administrative layer id. `P5=0` means byte 3 is seconds;
`P5=1` means byte 3 is 5-second units, so v1 can encode periods up to
1275 s while keeping duration/countdown at 100 ms resolution. Byte 2 is a
**live countdown** (ms/100) from this beacon's send time until the gateway's
next foreign-layer window opens — recomputed for every beacon — not a static
boot offset. This is what makes "anchored to the BCN receive time" work: the
receiver records `heard_ms` when it decodes the beacon and treats
`visit_start = heard_ms + countdown` (then `+ k·period`) as the foreign-window
schedule. Because the figure is relative to a received beacon, the sender and
gateway never need a shared wall clock — node boot jitter (`node_startup_jitter_ms`)
no longer desyncs the sender's prediction from the gateway's actual visits.
Receivers cache schedules by direct gateway neighbour and layer nibble. If a
sender wants to RTS to a direct gateway while that gateway is scheduled away
from the sender's layer, it defers until the advertised foreign-layer window
closes plus a small guard. Gateways also emit `gateway_schedule_change` when
their own radio context switches.

**Differential visit-entry beacon.** Because a receiver computes every future
window from a single hearing (above) and realistic clock drift (~±20–50 ppm ≈
100–200 ms over 30–60 min) is negligible against the multi-second window, the
gateway does **not** re-broadcast on every visit-window entry. It emits the
visit-entry beacon (`gateway_sweep`) only when it has **new state to push to that
layer** — dirty routes (active-layer `rt`) or dirty channel messages
(`channel_buffer`); otherwise it skips. New nodes acquire the schedule reactively
via `Q REQ_SYNC` (response jittered by `sync_response_backoff_*`), and the slow
periodic beacon carries it otherwise. This cut a time-shared gateway's beacon
airtime ~70% with channel reach preserved (see DELIVERY_ANALYSIS.md §2). The
visit-entry beacon's airtime is dominated by the 32-byte seen-bitmap (channel
gossip), not routes — so gating it on dirty state preserves channel propagation
while dropping the redundant idle re-announcements.

**Tuning the visit schedule (cross-layer delivery).** A time-shared gateway can
only be on one layer at a time, so cross-layer traffic loses messages at three
points: the **doorstep** (a frame reaches a gateway neighbour but the final hop
fails because the gateway is away or contended), the **visit layer** (the
gateway forwarded onto its visit layer but the frame never reaches the target),
and the **originator** (the sender can't even complete its first hop). Two knobs
control the visit schedule, and only one moves total delivery:

- The **home/visit split is zero-sum.** Rebalancing `duration_ms` relative to
  `period_ms` (e.g. 50/50 → 75/25 → 33/67) does not raise total cross-layer
  delivery; loss merely migrates between the doorstep and visit legs. Keep ~50/50.
- **Switching frequency is the lever.** Shortening `period_ms` (at a fixed 50/50
  split) cuts the wait for the gateway to be on the right layer, reducing both
  doorstep and originator-stuck loss. On a 24-seed s15 sweep, **15 s / 7.5 s
  raised cross-layer delivery 56 % → 68 %** versus the older 30 s / 15 s. Going
  *too* short (≈10 s) over-shoots: the visit window becomes too brief to deliver
  onward, so visit-leg loss balloons. ~15 s is the sweet spot for s15-class
  topologies, and it stays within the 10 % radio duty budget (peak duty-budget
  use ~51 %, no `beacon_skipped_budget`). The firmware's per-record fallback
  defaults (`gateway_visit_period_ms` / `_duration_ms` / `_offset_ms`) encode
  15 s / 7.5 s / 7.5 s; an explicit `gateway_layers[i]` field always overrides.
  These figures are topology-specific — re-sweep before adopting elsewhere, and
  always measure with a multi-seed sweep (single s15 runs are noise-dominated).

**Destination-seen bitmap:** Set bits mean "the beacon sender has recently
observed this node id." The bitmap is a freshness hint, not a route
advertisement. Receiving it updates `dest_seen_ms[dest]`. If the receiver
already has a candidate for `dest` whose `next_hop` is the bitmap sender,
that candidate's `last_seen_ms` is refreshed. It never creates route
candidates, never refreshes candidates via other neighbours, and never
changes route score, hop count, gateway state, candidate order, or dirty
status.

**Extension TLVs:** BCN extensions are optional and bounded. The first byte
after the optional bitmap is `ext_len`; receivers then parse TLVs where the
high nibble is `type` and the low nibble is payload length. Unknown types are
skipped.

Type `1` carries the compact legacy suspect/silent list. Type `2` carries an
explicit liveness state. `suspect` is a soft penalty, `silent` is temporarily
ineligible for RTS selection, and `dead` is an explicit longer-lived claim
after repeated non-responsiveness. None of these delete route knowledge; they
gate candidate eligibility until TTL expiry or until any valid frame from that
node clears the mark.

Receivers apply remote liveness states locally, but do not re-gossip remote
reports. Only local RTS-timeout evidence is advertised, which keeps this from
becoming a beacon storm. If a node hears itself listed, it emits
`peer_suspect_self_heard` and schedules a corrective BCN only when its own
budget tier is below CRITICAL.

Type `4` (`gateway_layer`) propagates per-gateway cross-layer routing
hints so multi-hop nodes can pick the right gateway for a cross-layer
DM. The schedule block (`has_schedule=1`) is only emitted by gateways
themselves and is only parsed by direct radio neighbours; this TLV is
the multi-hop counterpart. Each entry binds one gateway short id to
one destination layer nibble (the "other" layer relative to the BCN's
own `leaf_id`). A gateway is constrained to two layers (home + one
visit target), so one entry per gateway per BCN is sufficient. The
split-list form (all gw_ids first, then all layer nibbles) is chosen
for parser simplicity and to keep the gw_id slice byte-aligned.

**Propagation:** unlike type 1/2 (no re-gossip of remote reports),
type 4 *is* re-gossiped. Every node that knows
`{gw_id, dest_layer}` SHOULD include it in its own BCN. Direct
neighbours of a gateway populate this from the schedule records they
already parse; multi-hop receivers learn from the TLV. This is the
same gossip pattern as the `is_gateway` bit on route entries.

**Self-advertisement:** a gateway includes itself in its own outbound
type-4 TLV. Direct neighbours can derive the same information from the
attached schedule block, but the uniform redistribution rule keeps
"who advertises what" simple — every node propagates its full
`bridged_layers` map.

**Aging:** each `(gw_id, dest_layer)` entry carries an implicit
`last_seen_ms` (set on receive). Entries older than
`gateway_bridged_layers_ttl_ms` are pruned on access — same lifetime
story as `dest_seen_ms` and other BCN-derived state. Pruned entries
are not re-advertised. Aging out lets gateways shed layers cleanly:
no positive "remove this entry" signal is needed.

**Conflict (most-recent wins):** if a TLV refreshes a known
`gw_id` with a *different* `dest_layer`, the new value replaces the
old, and `last_seen_ms` is bumped. OR-merge is explicitly **not**
used — a gateway that drops or changes its visit target must be
reflected truthfully in the table, not accumulated forever.

**Rotation when >9 known:** the 4-bit TLV `len` caps a single TLV at
9 entries. Nodes that know more than 9 gateways advertise the top-9
by `last_seen_ms` and rotate across BCN cycles (mirrors the dirty-
route-entry rotation pattern). 9 is generous for any realistic
deployment.

**Originator path:** `select_gateway_for_layer(target_layer)` consults
the propagated `bridged_layers` map (not only the direct-neighbour
schedule cache), so multi-hop nodes can pick a gateway for the right
target layer. The last-hop-before-gateway still uses schedule
knowledge to defer-time the gateway hop; the TLV is for discovery,
not for scheduling.

Selection has two passes. Pass 1 picks the best gateway it has a live
**routing-table route** to. Pass 2 (fallback, when no routed gateway exists)
returns a gateway known only from the TLV/schedule — *without* requiring a
route — and the envelope is enqueued toward it as an ordinary send, so the
normal no-route recovery (`defer_send_for_route` → `'F'` RREQ flood, §3.7b)
discovers the route. This matters because differential (`dirty-only`) beacons don't
re-advertise stable routes (only the seen-bitmap refreshes them, and the
seen-bitmap never creates a route candidate), so a node can persistently *know*
a gateway exists yet never receive a route entry to it; Pass 2 + reactive query
is the same recovery any same-layer destination already gets, instead of
silently dropping the cross-layer send. Pass 2 applies an **on-layer guard**:
the gateway must appear in the (layer-local) seen-bitmap recently, which
excludes cross-layer TLV leaks — e.g. an L2-home bridge whose `(gw→L2)` TLV
propagated into L1 via a dual-layer gateway is *not* reachable from L1 and must
not be addressed. Direct-neighbour gateways skip the guard (heard directly, so
on-layer by construction).

**Source-routed layer path (gateway chaining).** The cross-layer envelope (in the
DATA payload, magic `\31G2`) carries an ordered **layer-hop list**, not a single
target layer: `MAGIC | hop_count | hops… | dst_hash(4 LE) | body` (hop_count ≤
`GW_ENV_MAX_HOPS`=4). `send_layer <l1,l2,…> <hash> <text>` lists the hops to
traverse (last = destination's layer); a bare `<layer>` is a 1-hop path (the
common case, unchanged — a 1-element list). The originator runs
`select_gateway_for_layer(hops[1])` and envelopes the **full** path. Each gateway
pops the entered layer `hops[1]`: if the list is then empty it delivers to
`dst_hash` on that layer (the binding lookup above); otherwise it selects a
gateway bridging to the next hop and re-wraps the *remaining* envelope toward it
(emit `gateway_envelope_transit`; the binary re-wrapped envelope rides as that
forward's payload). This lets a message cross two layers with **no direct bridge**
— e.g. west(L2)→east(L3) via the hub as `1,3` — without per-layer cross-gateway
route discovery: the sender source-routes the transit (like loose source routing).
The finite, hop-by-hop-consumed list is the loop/TTL guard. Path *learning*
(auto-deriving hops from the `bridged_layers` TLVs) is a deferred follow-on; today
the sender supplies the path explicitly. Validated by test t77.

**Route entry (4 bytes): `dest(1) | next(1) | byte2 | hops(1)`.** byte 2 bit fields:
- `score_bucket` (4 bits, 7:4): chain-min SNR quantized to a 4-bit bucket
  via `bucket_of_snr_4b` (16 buckets, 2 dB resolution, range −20..+10 dB).
  Decoded via `snr_of_bucket_4b`. ACK uses a separate 2-bit coarse SNR
  encoding so it can also carry budget back-pressure plus an addressed
  recipient byte.
- `rsv` (3 bits, 3:1): reserved (formerly `hops-1`; hops moved to its own byte).
- `is_gateway` (1 bit, 0): the advertised path's terminal node is a gateway.
  Per-candidate storage in `rt[]`; the data plane reads it from the primary
  candidate. Different advertisers may disagree; route-selection picks
  among candidates by score, and the chosen candidate's `is_gateway` is
  authoritative.

**`hops` byte (byte 3):** full 8-bit hop count (range 1..255). The active **DV
routing cap is `dv_hop_cap` (default 16)** — `combined_hops > dv_hop_cap` routes
are rejected at the receiver, and the reactive `route_request_max_ttl` /
`hash_query_max_ttl` floods track it (all three move together). Because hops have
their own byte, raising the cap is a one-constant change with no wire change.
Per-message reach is bounded by the DATA `hop_budget` (`hops_remaining`, 5 bits →
0..31; see §7.6). Real-LoRa caveat: a path this long is slow and lossy
(~0.95^h per-hop), so a high cap *enables* long routes, it doesn't make them
reliable.

**Frame size:** route entries are now **4 bytes** (`dest + next + byte2 + hops`).
Fixed header is 8 bytes (`'B' + flags + src + n/flags + key_hash32`); `S=1` adds
32 bytes; a gateway BCN with L upper layers adds 1 + 4L bytes. (The +1 byte/entry
vs the old 3-byte packing is offset in a real implementation by reclaiming the
over-provisioned packet-code byte — a full char for <16 frame types.)

**Pre-bit-pack history:** before Phase 1-2 entries were 4 bytes
(`dest + next + score_i8(8) + hops(8)`) and the default was 200 bytes.
Phase 2 packed entries to 3 bytes (−24.5% airtime). Phase 3 (this spec)
repacked byte 1 to add flag bits and repacked entry byte 2 to add the
`is_gateway` bit and use the `hops-1` encoding.

### 3.1a Loop guards (forwarding-loop prevention)

DV without destination sequence numbers can form multi-node routing loops,
especially in the dense center and toward time-shared gateways (stale/loopy
routes). Four layered, complementary guards prevent/kill them — loop-freedom is a
**data-plane** property (so the alternate-route search can be liberal without
risking cycles):

1. **prev-hop split-horizon** — never forward back to the immediate predecessor.
2. **origin-drop** — a node that receives a frame it *originated* drops it (never
   re-forwards); kills the return-to-origin loop directly. (`origin_loop_drop`)
3. **visited-set window** (DATA §3.4): never forward to any node already on the
   message's recent path (last `VISITED_LEN`=6 carriers, `visited_check_depth`-deep).
   Generalizes guard 1 from 1 carrier to 6 — the main structural loop-killer.
4. **hop-gradient** (`gradient_max_uphill_hops`, default 1): the cascade / blind-alt
   / loop-dup alternate search prefers routes within N hops of the best, so it
   doesn't wander into longer cycles. **Soft** (2-pass): if no near route is usable
   it falls back to an uphill one rather than stranding (sparse suburbs / gateway
   legs need this) — safe because guards 1–3 make the fallback loop-free.

Reactive backstops: a returning duplicate from a *different* prev-hop triggers a
`loop_duplicate` NACK; the `hop_budget` bounds any residual loop. s17 4-seed result
of the full package: same-layer 82→92%, all-DM 59→69% (see DELIVERY_ANALYSIS.md).

**Gateway-doorstep hold** (cross-layer first leg): a node RTSing a known gateway
directly that gets no CTS does **not** fan out to sibling gateway-neighbours (that
loops); it holds the single copy and retries window-aware + jittered until
`gateway_send_giveup_ms` (150 s). See §3.4 `visited` reset on gateway re-issue.

**Copy-control on ACK-timeout (anti-duplication).** Two layers stop a lost *hop ACK*
from spawning a duplicate copy: (a) **passive ACK** — the sender overhears the
next-hop's *forwarding* RTS (matching `src==next && dst && ctr_lo && payload_len`) and
treats it as the ACK (`implicit_ack_from_forward`); (b) **retry-same-hop** — on
`ack_timeout` the retry does **not** blind-alt to a fresh next-hop (the receiver got a
CTS+DATA from us, so a missing ACK is a *lost ACK*, not a blind receiver; switching to
a fresh node makes it forward a 2nd copy). Instead it re-RTSes the *same* hop, whose
`last_acked_from` returns CTS-`already_received` with no re-forward (`ack_retry_same_hop`).
Genuine unreachability still cascades after `retries_left` exhausts. This is what tamed
the 2-gw inter-gateway-transit copy-storm (2-gw 42→60% on s17). passive-ACK alone is
insufficient because under contention the next-hop's forward RTS is LBT-deferred past
the sender's ack-timeout.

### 3.2 RTS (`'R'`) — 8 bytes (in-leaf)

Per ROADMAP §7.0.3. `origin` removed from wire — destination identifies the
originator from the inner DATA payload (Phase 4). Forwarders never needed origin
on the RTS wire. Future cross-layer hops add +1 byte per boundary; addr_len
encodes depth.

`sf_bitmap` was replaced by a 2-bit `sf_index` in `c20585b` (2026-05-28). The
index resolves against the receiver's active leaf's `allowed_data_sfs` list —
see `bitmap_to_sf_index` / `sf_index_to_bitmap` for the encoding, and the
"SF index — cross-leaf safety" note below for the gateway-active-layer rule.

```
byte:  0   1    2    3                        4    5                   6                            7
       ┌───┬────┬────┬────────────────────────┬────┬───────────────────┬─────────────────────────────┬─────────────┐
       │'R'│ src│next│ addr_len (3 hi)        │dst │ ctr_lo (4 hi)     │ sf_index (2 hi)             │ payload_len │
       │   │    │    │ rsv (1)                │    │ flags (4 lo)      │ rsv (6 lo)                  │             │
       │   │    │    │ leaf_id (4 lo)         │    │                   │                             │             │
       └───┴────┴────┴────────────────────────┴────┴───────────────────┴─────────────────────────────┴─────────────┘
```

- `src` (8 bits): immediate sender of THIS RTS frame (the previous hop).
  Kept because this is the first hop-level frame; the receiver has no
  `pending_rx` yet and needs to know who to CTS-reply to.
- `next` (8 bits): immediate next-hop receiver. Receivers other than
  `next` drop the RTS silently.
- `addr_len` (3 bits, hi of byte 3): number of extra hierarchy-level bytes
  that follow `dst`. Always `0` this phase (in-leaf only); hierarchy
  support deferred.
- `rsv` (1 bit, mid of byte 3): reserved, set to 0.
- `leaf_id` (4 bits, lo of byte 3): active layer nibble, derived from
  `layer_id & 0x0f`. Receivers reject foreign-layer RTSes before any CTS
  work. Pattern-matches DATA byte 1 (both have `addr_len` in top 3 bits).
- `dst` (8 bits): end-to-end destination; single byte when `addr_len=0`.
- `ctr_lo` (4 bits, hi nibble of byte 5): per-flight counter, wraps at 16.
  Combined with `last_acked_from`'s 10s TTL gives correct hop-level
  retry dedup at any realistic send rate.
- `flags` (4 bits, lo nibble of byte 5):
  - bit 0 `RTS_FLAG_M_BROADCAST` (0x01): the upcoming DATA is an M-payload
    channel broadcast (§3.4.1a); non-target receivers arm an overhear retune.
  - bit 1 `RTS_FLAG_RELAY` (0x02): this RTS is a **gateway cross-layer
    forward**. On the target layer a gateway re-injects with `origin=self`
    and no preceding CTS, which the §10a anti-spam metric would otherwise
    mis-read as a runaway origination. Set only by `enqueue_gateway_handoff`
    forwards; the addressed next-hop skips the originator throttle for it
    (§10a). A gateway's *own* originations carry no flag and are throttled
    normally. bits 2-3 reserved.
- `sf_index` (2 bits, top of byte 6): index into the **active leaf's
  `allowed_data_sfs`** list. Codes 0..2 = singleton bitmap of the SF at
  that index; code 3 ("ANY") = full allowed bitmap (receiver picks by SNR).
  See `bitmap_to_sf_index` for sender-side encoding; the cross-leaf
  correctness rule is that pack and parse both use
  `active_allowed_data_sfs(self)` (which the gateway switches per-flight
  via `activate_primary_layer` / `activate_gateway_layer`), NOT
  `self.allowed_data_sfs` (the static home-leaf config).
- byte 6 lo (6 bits): reserved, set to 0. Available for future packing
  (ROADMAP §10 cmd-nibble target uses 4 of these for `rts_flags`).
- `payload_len` (8 bits): byte count of the upcoming DATA inner bytes
  plus MAC (= `#inner + MAC_LEN`). Lets the receiver size
  `pending_rx_expiry` to actual airtime instead of worst-case. This byte
  is load-bearing — dropping it forces `pending_rx_expiry` to fall back
  to worst-case `max_payload_bytes`, which regresses throughput (see
  `DELIVERY_ANALYSIS.md` "Wire-format compaction" for the analysis).

### 3.3 CTS (`'C'`) — 3 bytes

```
byte:  0   1                                2
       ┌───┬───────────────────────────────┬────┐
       │'C'│ ctr_lo (4 hi)                 │ to │
       │   │ chosen_data_sf - 5 (3)        │    │
       │   │ already_received (1)          │    │
       └───┴───────────────────────────────┴────┘
```

- `ctr_lo` (4 bits): echoes the RTS's ctr_lo. Originator matches
  against `pending_tx.ctr_lo`.
- `chosen_data_sf` (3 bits, encoded as offset from 5): SF the
  receiver picked for the DATA leg. Range 5..12 → encoded 0..7.
- `already_received` (1 bit): set when the receiver has already decoded
  and ACKed this DATA, but the sender retried RTS because that ACK was
  lost. The sender treats this CTS as hop-complete and does not transmit
  DATA again.
- `to` (8 bits): intended requester id. Nodes can overhear CTS for
  passive blind-window marking, but only the addressed node may match it
  to `pending_tx`.

No `leaf_id` — CTS is matched at the originator by
`to`, responder source, and `pending_tx.ctr_lo`, which was set after the
originator's already-validated RTS.

### 3.4 DATA (`'D'`) — 20 + n bytes (in-leaf, addr_len=0)

Per ROADMAP §7.0.1. E2E flags moved from inner payload header to wire byte 1.
16-bit `ctr` replaces the 3-byte inner origin-header. 4-byte zero MAC placeholder
added (crypto stub, will carry Poly1305-truncated under §8).

```
byte:  0    1        2     3    4           5          6      7      8..13         14..(13+2+n)   last 4
       ┌────┬────────┬─────┬────┬───────────┬──────────┬──────┬──────┬─────────────┬──────────────┬───────┐
       │'D' │addr_len│ next│ dst│ hop_budget│ prev_fwd  │ctr_lo│ctr_hi│ visited[6]  │ ciphertext   │  MAC  │
       │    │(3 hi)  │     │    │ remaining │ _rt_hops  │      │      │ (loop win)  │ (n+2 B)      │ (4 B) │
       │    │+flags  │     │    │ (5)|cmtd(3)│ (8)       │      │      │ (6 B)       │              │ zeros │
       └────┴────────┴─────┴────┴───────────┴──────────┴──────┴──────┴─────────────┴──────────────┴───────┘

Total: DATA_HDR_LEN(14) + (n+2) inner + MAC_LEN(4) = 20 + n bytes for in-leaf
(addr_len=0). n = body bytes. DATA_HDR_LEN = 8 fixed header bytes + VISITED_LEN(6).

ciphertext slot for normal DATA (starts at byte 14):
  byte 14 : src_addr_len (= 0 for in-leaf / flat addresses this phase)
  byte 15 : src_addr     (origin's 8-bit mesh id; 1 byte when src_addr_len=0)
  bytes 16+: body        (user text for normal DATA; [acked_ctr_lo, acked_ctr_hi] for E2E ACK)

byte 1 flag bits (low to high):
  bit 0 (0x01): PAYLOAD_TYPE_M (channel gossip message; ciphertext slot
                                uses §3.4.1 layout — see below)
  bit 1 (0x02): PRIORITY        (urgency; queue precedence + separate
                                anti-spam ledger — see §3.4.2)
  bit 2 (0x04): E2E_IS_ACK      (this DATA IS an E2E ACK; body = [acked_ctr_lo, acked_ctr_hi])
  bit 3 (0x08): E2E_ACK_REQ     (origin requests end-to-end confirmation)
  bit 4 (0x10): reserved
  bits 5-7:     addr_len         (always 0 this phase — hierarchy deferred)

hop-level ctr_lo: low nibble of ctr (ctr & 0xf), used for pending_rx matching.
```

**Historical note.** Bit 0 was previously `reserved`; bit 1 was previously
`IS_MULTICAST` (for ROADMAP §7.5, now obsolete — see ROADMAP §3 for the
gossip-based channel design that replaced it). Combining `PAYLOAD_TYPE_M`
and `PRIORITY` on the same frame is undefined behaviour today — channel
gossip flows at lowest tx_queue priority and isn't expected to need urgency
elevation. Receivers MAY drop frames with both bits set.

- `ctr` (16-bit LE): per-(origin, dst) outbound counter, promoted to plaintext
  wire bytes 4-5. Replaces the 3-byte inner origin-header (flags + origin_seq).
- **E2E flag bits are on wire byte 1** (plaintext), not inside the ciphertext slot.
  This lets intermediate nodes apply QoS (e.g., priority forwarding of ACK_REQ
  frames) without needing to decrypt — an intentional design aligned with
  WireGuard/MLS envelope patterns. Under §8 crypto the flags stay on byte 1.
- `ciphertext` (inner payload) is carried as plaintext today. Forwarders relay it
  verbatim — the ciphertext slot is opaque to the mesh layer at intermediate hops.
  Origin and destination parse it: `src_addr_len | src_addr | body`.
- `body` interpretation:
  - `E2E_IS_ACK=0` (normal DATA): body is opaque user text.
  - `E2E_IS_ACK=1` (E2E ACK return frame): body is exactly 2 bytes —
    `[acked_ctr_lo, acked_ctr_hi]` — the 16-bit ctr being acked.
- `hop_budget` (byte 4): `hops_remaining` (5 bits, hi) `| committed_hops` (3 bits).
  Decremented each hop; `hops_remaining < 0` at a non-destination triggers a
  `HOP_BUDGET` NACK (§ NACK). 5 bits so the TTL reaches the 16-hop `dv_hop_cap`.
- `prev_fwd_rt_hops` (byte 5): the previous forwarder's claim of `dst`'s hop count
  (8 bits); used for the §7.6 forwarder rt-cost overwrite.
- `visited` (bytes 8..13, `VISITED_LEN`=6): **loop-guard window** — the most-recent
  carrier short-ids on this message's path (0 = empty slot). The originator seeds it
  with `[self]`; each forwarder appends its own id (sliding, keep last 6). A node
  **refuses to forward to any id in the window** (`next_hop_selectable`, up to
  `visited_check_depth`) — prev-hop split-horizon generalized 1→6, making the
  routing-loop class impossible at the data plane. Reset (restarts at `[gateway]`)
  on a cross-layer gateway re-issue (new path on the next layer). See § Loop guards.
- `MAC` (4 bytes, all-zero placeholder): will carry Poly1305-truncated tag
  once §8 crypto lands. Receiver ignores MAC bytes today.
- In-leaf size: **20 + n bytes** (DATA_HDR_LEN 14 = 8 fixed + 6 visited; + 2 B inner
  src-addr header + n body + 4 B MAC). `payload_hard_max = LORA_MAX_FRAME_BYTES(255)
  - DATA_HDR_LEN(14) - DATA_INNER_OVERHEAD(6) = 235`; `max_payload_bytes` (default
  230) is clamped to it (see `max_payload_clamped`).

#### 3.4.1 Channel-message payload (`PAYLOAD_TYPE_M`)

When byte-1 bit 0 (`PAYLOAD_TYPE_M`) is set, the DATA frame carries a
channel-gossip message (ROADMAP §3). The ciphertext-slot layout is
different from normal DATA — no `src_addr_len` / `src_addr` prefix:

```
ciphertext slot for PAYLOAD_TYPE_M:
  bytes 6-9   : id (4 B, BE)       global message ID
                                   = (origin_node_id << 24) |
                                     ((key_hash32 & 0xFFFF) << 8) |
                                     (ctr_lo8 & 0xFF)
  byte 10     : channel_id         8-bit; flavor-specific semantics
  byte 11     : flavor              0 = public (plaintext body)
                                    1 = group   (ChaCha20 + MAC)
                                    2 = private (ChaCha20 + Ed25519 sig)
  bytes 12+   : body (var)         flavor-specific content
  last 4      : MAC                placeholder; will carry per-flavor tag
                                   under §8 crypto
```

**Routing semantics (2B-broadcast, operational since 2026-05-21).**
PAYLOAD_TYPE_M frames are emitted as the response to a `Q_CHANNEL_PULL`
request (Q opcode in §3.7). The DATA frame's `next` and `dst` fields
point at the pull requester for diagnostic identification (the
"originally requested-by" tag), BUT the frame is a **broadcast**:

- The preceding RTS carries the `M_BROADCAST` flag bit (in the low
  nibble of the ctr_lo byte — see §3.4.2 below for the wire format
  extension) AND announces the receiver-picked `chosen_data_sf` in the
  `sf_bitmap` byte (exactly one bit set = the SF the DATA will use).
  Holder picks `max(allowed_data_sfs)` for the originator's layer —
  largest SF = most robust = most receivers can decode.
- **No CTS, no ACK.** Sender fires RTS, waits `cts_to_data_gap_ms`,
  then transmits DATA at the announced SF. No flow-control feedback
  loop; failures recover via the cascade BCN-digest re-advertisement
  on the next BCN cycle.
- Receivers (any in-range node that decodes the M_BROADCAST RTS —
  including the "addressed target" whose Q triggered this response)
  retune to chosen_data_sf, listen for DATA, retune back to routing_sf
  after the guard window. Gateways and busy nodes (pending_tx /
  pending_rx) silently skip — cascade fills in via other holders.
- Each in-range decoder merges the M-payload into its own
  `channel_buffer` regardless of `to=`. This is the gossip mechanism's
  core efficiency: one broadcast satisfies N hearers instead of N
  unicasts.

**id_lo16 RTS extension (operational since 2026-05-21).** The
M_BROADCAST RTS appends 2 bytes after `payload_len` carrying the low
16 bits of the channel msg id (BE). Receivers check their
`channel_buffer` for any entry whose `id & 0xFFFF` matches BEFORE
arming the retune. If found, they skip the arm entirely — no retune,
no ~2 s of routing-SF blindness, no decode of a duplicate. Emits
`channel_overhear_skipped_already_have`. Collision space is 65 k;
simultaneously-active msgs are far below that, so false-positive
skips are negligible. False-positive worst case: receiver wrongly
assumes it has the msg and skips a NEW msg; cascade recovers via
other holders. See ROADMAP §3.6.

**Gateways are not part of channel gossip.** Per Principle 11
(channels are local-by-design), gateways skip both the buffer-merge
on M-payload receive AND the overhear-arm on M_BROADCAST RTS. They're
transparent to channel traffic. Under 2B-broadcast no special
forwarder-drop code is needed — gateways simply don't participate in
the broadcast retune cycle. (Phase 1 / 2A had an Option A
gateway-drop path; removed in the 2B pivot since broadcast at data
SF doesn't structurally leak across layers like routing-SF broadcast
did.)

Forwarders carry M frames at the **lowest tx_queue priority** — they
yield to normal DM, hop-level control, and PRIORITY traffic. Channels
are eventually-consistent best-effort; if a frame is dropped at the
forwarder, the next BCN digest re-advertises the dirty ID and the
recipient pulls again.

#### 3.4.1a RTS wire format extension for M_BROADCAST

Standard RTS is 8 bytes (see §3 table). For M_BROADCAST it is **10
bytes**:

```
byte 0   : tag 'R'
byte 1   : src
byte 2   : next
byte 3   : [addr_len(3) | rsv(1) | leaf_id(4)]
byte 4   : dst
byte 5   : [ctr_lo(4) | rts_flags(4)]    ← rts_flags bit 0 = M_BROADCAST
byte 6   : sf_bitmap                     ← when M_BROADCAST: exactly one bit
                                            set = chosen_data_sf (encoded as
                                            1 << (sf - 5))
byte 7   : payload_len                   ← DATA-M ciphertext-slot length
byte 8-9 : id_lo16 (BE)                  ← present iff M_BROADCAST flag set;
                                            low 16 bits of channel msg id
                                            (see §3.4.1 id encoding)
```

`id_lo16` lets receivers do a pre-arm check against `channel_buffer`
without retuning to data SF. Wire airtime delta: +2 bytes vs standard
RTS (≈ +10 ms at SF8 / BW62.5 / CR5). See ROADMAP §3.6.

#### 3.4.2 PRIORITY flag

When byte-1 bit 1 (`PRIORITY`) is set, the originator is asserting
the frame carries urgent content (ICE, emergency, medical). Behaviour:

| Layer | Behaviour |
|---|---|
| Originator | Hard-capped at `originator_priority_max_per_window = 5` frames per `originator_priority_window_ms = 3600000` (1 h). Crossing → silent drop + `priority_send_capped` event |
| Forwarder `tx_queue` | PRIORITY items pop before normal traffic. Cascade-requeue preserves priority |
| 1st-hop neighbour anti-spam | Separate ledger from normal anti-spam: max 5 PRIORITY frames per hour per direct sender (keyed on `meta.src`, not claimed origin — persona-rotation defeat). Crossing → silent drop + `rts_drop_originator_priority_throttle` |
| Duty cycle | Unchanged. PRIORITY gets earlier airtime, not extra airtime. STRAINED/CRITICAL/EXHAUSTED tiers still apply |
| Retry dedup | Unchanged. `originator_retry_dedup_ms = 10000` rule applies — same ctr_lo within window counts as one origination |

Use cases: a small burst of unicast DMs to specific contacts ("send to
family + neighbour + medic" = 3 frames). For "warn everyone in an area",
that's a public channel (§3 gossip), not a flood of PRIORITY unicasts.

See ROADMAP §3a for the design rationale and budget arithmetic.

### 3.5 ACK (`'K'`) — 3 bytes

```
byte:  0   1                                2
       ┌───┬───────────────────────────────┬────┐
       │'K'│ ctr_lo (4 hi)                 │ to │
       │   │ budget_hint (2) | snr_coarse  │    │
       └───┴───────────────────────────────┴────┘
```

- `ctr_lo` (4 bits): echoes the DATA's ctr_lo.
- `budget_hint` (2 bits): receiver's local duty-budget warning.
  `0=OK`, `1=STRAINED`, `2=CRITICAL/EXHAUSTED`, `3=reserved`.
  This is a soft routing signal only: it does not fail the hop and it
  does not mark the receiver blind.
- `snr_coarse` (2 bits): receiver's coarse DATA-leg SNR. `0=poor`,
  `1=usable`, `2=good`, `3=no info`.
- `to` (8 bits): intended previous-hop id. Other nodes ignore the ACK
  even if `ctr_lo` and responder source appear to match a local flight.

The originator/forwarder feeds the decoded SNR into
`snr_ewma_out[next_hop]` — outbound link-quality estimate, separate
from `snr_ewma_in` (inbound).

On ACK reception, non-zero `budget_hint` updates the sender's temporary
`neighbor_budget_tier[next_hop]` mark and locally reranks route
candidates through that next-hop. Unlike a budget NACK, ACK warning
does not set `blind_until` and does not trigger a dirty route beacon;
it is early local back-pressure for the upstream router.

Lost ACK recovery has one additional passive path: if a sender is still
waiting for hop completion and overhears its selected next-hop emitting an
RTS/RTS-fwd for the same `(dst, ctr_lo, payload_len)`, it treats that
overheard forward RTS as an implicit hop ACK. The next-hop could not forward
the packet unless it had decoded the sender's DATA, so the sender cancels its
ACK/RTS retry timers and marks the hop complete. Any already-scheduled
LBT-deferred RTS retry for that stale `pending_tx` is cancelled before TX.

### 3.7 Q (`'Q'`) — query/control

```
byte:  0   1     2      3
       ┌───┬─────┬──────┬───────────────────────────────────┐
       │'Q'│ src │ dest │ leaf_id (4 hi)                    │
       │   │     │      │ opcode/mobile flags (4 lo)        │
       └───┴─────┴──────┴───────────────────────────────────┘
       CHANNEL_PULL appends a body after byte 3: count(1) + id(4 LE) × N
```

- `src` (8 bits): the requester's node id.
- `dest` (8 bits): the pull-target neighbour for `CHANNEL_PULL`; `0xff`
  for `REQ_SYNC`.
- `leaf_id` (4 bits): active layer nibble, derived from `layer_id & 0x0f`.
  Receivers reject foreign-layer Q frames.
- low nibble:
  - bits 0-1: opcode (`1=REQ_SYNC`, `3=CHANNEL_PULL`).
    Opcode `0` was `ROUTE_QUERY` (1-hop); it was replaced by the multi-hop
    `'F'` route-Find flood (§3.7b) and is now free/reserved. Opcode `2` was
    `HASH_QUERY` (1-hop); it was replaced by the multi-hop `'H'` flood frame
    (§3.7a) and is also free/reserved.
  - bit 2: requester is mobile
  - bit 3: reserved

One-hop only — receivers don't forward Q frames. (The two forwardable
control queries live in their own flood frames: hash-locate in `'H'`
(§3.7a) and route discovery in `'F'` (§3.7b), so `Q` keeps this invariant.)

`Q` now multiplexes only `REQ_SYNC` (discovery sync) and `CHANNEL_PULL`
(channel-gossip pull). Route discovery — the originator-side "I have no
route to `dst`" query that used to be `Q:ROUTE_QUERY` — moved to the `'F'`
RREQ/RREP flood (§3.7b), because a one-hop query cannot reach a route that
is known more than one hop away.

### 3.7a H (`'H'`) — multi-hop hash-locate flood

```
byte:  0   1        2                      3..6              7
       ┌───┬────────┬──────────────────────┬────────────────┬──────┐
       │'H'│ origin │ leaf_id(4) flags(4)  │ key_hash32(4LE)│ ttl  │
       └───┴────────┴──────────────────────┴────────────────┴──────┘
```

Replaces the old 1-hop `Q:HASH_QUERY`. When a gateway receives a cross-
layer envelope but lacks `(target_layer_id, key_hash32) -> node_id`, it
floods an `'H'` query on the target layer to find the one node that holds
the binding (the destination itself, or a direct neighbour of the
destination that learned it from the destination's BCN). The resolution
stays local to the destination — the gateway is NOT required to
accumulate every node's binding, and route entries do NOT carry hashes.

- `origin` (8): the querying gateway's node_id on the target layer.
  **Preserved across forwards** so the resolver can route its answer home.
- `leaf_id` (4): target layer nibble; receivers reject foreign-layer `'H'`
  frames (same filter every frame uses). `flags` (4): reserved.
- `key_hash32` (4 LE): identity hash to resolve.
- `ttl` (8): initial `hash_query_max_ttl` (default 16, matching `dv_hop_cap`
  so the flood can reach any routable node);
  decremented per forward; dropped at 0.

**Forwarding** (`'H'` is the one forwardable control frame):
- a node whose own `key_hash32` matches, or whose `id_bind` holds the hash
  → resolve to `node_id`, **reply** (below), and stop forwarding this branch
- otherwise → if `(origin, key_hash32)` not already seen (dedup set,
  `hash_query_seen_ttl_ms`, capped by `cap_hash_query_seen`) and `ttl > 0`:
  mark seen, decrement ttl, rebroadcast.

**Binding response — routed DATA, not a Q.** The DATA flag field is full
(4 bits), so the response is identified by a body magic, mirroring the
gateway-envelope pattern. The resolver sends a normal **routed unicast
DATA** to `origin` (reusing the existing routing/RTS/CTS/ACK path — the
return path is not reinvented) whose inner body is:
```
HASH_BIND_MAGIC ("\31H1", 3 B) | target_layer(8) | node_id(8) | key_hash32(4 LE)
```
The gateway's DATA delivered-branch parses this (alongside the gateway
envelope), updates `id_bind` + `gateway_remote_bind` for `target_layer`,
emits `q_hash_binding_rx{source="h_query"}`, calls
`try_drain_gateway_handoffs`, and does NOT deliver it as user data. A
non-gateway that receives it drops it (mirrors
`gateway_envelope_at_non_gateway`).

**Economics (AODV-style reactive discovery):** the flood is single-layer
and TTL-bounded; the query is a tiny frame (not the DATA payload); the
resolved binding is cached for `gateway_remote_bind_ttl_ms` (48 h); and
cross-layer destinations are few and stable. So the first message to a new
cross-layer peer pays a bounded one-time flood, and every later message is
a local lookup. The 30-s handoff-deferral backstop
(`gateway_handoff_giveup`) still fires when the flood genuinely finds
nothing (unreachable destination).

**REQ_SYNC behaviour:** during node-local DISCOVERY, a node whose route
table is still poor may send `Q{opcode=REQ_SYNC,dest=0xff}` after a
listen window. The request carries whether the requester is mobile.
Eligible neighbours schedule a full `kind=sync` BCN response with
randomized backoff. Mobile responders add extra backoff, and any
responder suppresses its pending sync response if it hears another
useful BCN before its timer fires. This lets one good neighbour satisfy
a joiner without all nearby nodes transmitting full BCNs at once.

**Swimlane:** see `docs/SCENARIOS.md` §4.1 (Q REQ_SYNC — BCN as response).

### 3.7b F (`'F'`) — multi-hop route-Find flood (RREQ/RREP)

```
byte:  0   1        2                      3       4              5
       ┌───┬────────┬──────────────────────┬───────┬─────────────┬──────┐
       │'F'│ origin │ leaf_id(4) flags(4)  │ dst   │ ttl|next_hop│ hops │
       └───┴────────┴──────────────────────┴───────┴─────────────┴──────┘
       flags bit0 = is_reply (0 = RREQ, 1 = RREP)
       byte 4 = ttl       (RREQ: decremented per forward, dropped at 0)
              = next_hop  (RREP: addressed forward target toward origin)
```

Wire tag is `'F'` (route-**F**ind), **not** `'R'` — `'R'` is the RTS frame.
The `RREQ`/`RREP`/`route_request` naming is the standard AODV vocabulary and
is kept in code and events; only the wire byte is `'F'`.

Replaces the old 1-hop `Q:ROUTE_QUERY`, which could not reach a route known
more than one hop away (the originator's neighbours were silent, even when a
2-hop node reliably held the route). `'F'` is the second forwardable control
frame (alongside `'H'`); it reuses the same flood/dedup machinery but the
reply path differs — see below.

- `origin` (8): the querying node's id. **Preserved across forwards** so the
  RREP can be routed home along the reverse path the RREQ laid down.
- `leaf_id` (4): active layer nibble; receivers reject foreign-layer `'F'`
  frames. `flags` (4): bit 0 = is_reply. Same-layer only — cross-layer
  discovery is the gateway/`'H'` path, not this.
- `dst` (8): the destination being sought.
- `ttl` / `next_hop` (8): RREQ carries `ttl`; RREP carries the addressed
  `next_hop` (only that node acts on the RREP).
- `hops` (8): RREQ counts hops-from-origin (increments per forward); RREP
  counts hops-to-dst (increments back toward origin).

**Why the reply cannot be opaque like `'H'`.** `'H'`'s resolver answers with
a routed unicast DATA to the querying *gateway*, which is by definition a
reachable, well-connected node. `'F'` seeks exactly the node nobody has a
route to, so there is no reachable address to send an opaque reply to.
Instead the discovery is two-directional:

- **RREQ (flood) lays the reverse path.** Every forwarder installs/refreshes
  `rt[origin] = via (immediate sender), hops+1` (an `rt_merge` with the RX
  SNR score) *before* the dedup check, so even duplicate copies keep the
  reverse route fresh. Dedup is keyed `(origin, dst)` in `route_request_seen`
  (`route_request_seen_ttl_ms`, capped by `cap_route_request_seen`).
- **RREP (routed hop-by-hop) lays the forward path.** The destination — or
  any intermediate node that already holds `rt[dst]` (AODV-style
  intermediate reply) — emits an RREP addressed to the next hop along the
  reverse path. Each relay installs `rt[dst] = via (immediate sender),
  hops+1` and forwards toward `origin` via `rt[origin]`. When the RREP
  reaches `origin`, the forward route is installed and the deferred send
  drains on the next route-check tick.

**Expanding ring.** The first probe (from `defer_send_for_route`'s no-route
path) uses `ttl=1` (radius 2 — cheap, and enough to catch the common "dst is
2 hops away via a node that already has the route" case). If that fails, the
deferred-send requery escalates to `route_request_max_ttl` (default 16,
matching `dv_hop_cap`). Per-dst origination is rate-limited/escalated via
`route_request_last` (capped by `cap_route_request_last`, the table that
replaced the old `q_queried` route-query table).

**Gateway-aware discovery (part-time relays).** A gateway time-shares layers
(home + visit windows), so a deferred forward to a node on a given layer is only
serviceable while the gateway is actually on that layer. Two corrections keep
route discovery from wasting effort or firing blind against such a part-time
endpoint:

- **Layer-gated requery.** A deferred send carries its target layer
  (`tx_layer_id`). The drain only floods the RREQ while the node is on that layer
  (`active_layer_id == tx_layer_id`); off-layer it emits
  `send_defer_requery_offlayer` and holds without flooding. Otherwise a gateway
  draining while visiting another layer floods the RREQ where the dst isn't —
  wasted airtime, and the per-dst `route_request_last` dedup gets stamped so the
  eventual on-layer flood is suppressed (the layer-gate is what keeps the
  dst-keyed dedup from being cross-layer-poisoned). A drain is kicked on every
  layer (re)activation so held items requery near window-open. The defer TTL for
  a gateway's layer-targeted send is the visit-period-scaled
  `gateway_handoff_defer_ttl_ms` (not the same-layer `send_defer_ttl_ms`), since
  it only gets ~half the wall-clock as serviceable on-layer windows.
- **Schedule-aware, jittered RREP.** The RREP rides `tx_initiating`, whose LBT
  only backs off when the channel is already busy — so several reverse-path
  holders answering one RREQ at the same instant all sense clear and collide at
  the receiver (a *present* gateway that decodes nothing). `send_route_reply`
  therefore (a) defers to the next-hop gateway's presence window when it is away
  (`gateway_schedule_defer_ms`, emitting `rrep_gateway_schedule_defer`),
  mirroring how `send_hash_bind_response` uses the coordinated queued path, and
  (b) always adds a small random backoff (`route_reply_jitter_ms`) so
  simultaneous repliers spread out and LBT serializes the residual.

**Events:** `r_tx` (RREQ originated), `rreq_rx` / `rreq_forward`,
`rreq_resolved_self` / `rreq_resolved_cached` (a reply was generated),
`rrep_tx` / `rrep_rx`, `rrep_arrived` (forward route installed at origin),
`rrep_drop_no_reverse` (RREP could not start/continue — no reverse route),
`rrep_gateway_schedule_defer` (RREP held for an away next-hop gateway's window),
`send_defer_requery_offlayer` (requery withheld — node not on the dst's layer),
`route_request_suppressed` (origination rate-limited).

### 3.8 J (`'J'`) — join/lease control

`J` is the first short-address join family. It is used before a node has a
trusted layer-local `node_id`, so the stable identity field is `key_hash32`,
a compact hash of the node's long public key. The full public key is fetched
later by identity-card request. BCN carries only `key_hash32`; normal
data-plane frames do not expose the long-term identity in clear.

Current implementation note: a `join_required` node starts as temporary
protocol id `255`, which is reserved for unjoined/broadcast-special use. After
`J_CLAIM` survives the guard window, Lua calls the runtime `set_protocol_id`
hook and subsequent RF metadata uses the adopted short id.

Common byte 1:

```
bit:   7 6 5 4   3              2          1 0
       ┌────────┬──────────────┬──────────┬────────┐
       │leaf_id │gateway_capable│ is_mobile│ opcode │
       └────────┴──────────────┴──────────┴────────┘
```

- `leaf_id`: active layer nibble, derived from `layer_id & 0x0f`.
- `opcode`: `0=DISCOVER`, `1=CLAIM`, `2=DENY`, `3=OFFER`.
- `is_mobile`: requester/mobile identity hint.
- `gateway_capable`: requester can participate in multiple layers.

`J_DISCOVER`:

```
byte:  0   1        2..5
       ┌───┬────────┬────────────┐
       │'J'│ header │ key_hash32 │
       └───┴────────┴────────────┘
```

`J_OFFER`:

```
byte:  0   1        2             3..6                 7
       ┌───┬────────┬─────────────┬────────────────────┬────────────┐
       │'J'│ header │ responder_id│ responder_key_hash │ data_sf_bm │
       └───┴────────┴─────────────┴────────────────────┴────────────┘
```

`J_OFFER` is the bootstrap configuration response. A new node only needs
frequency and control SF out-of-band; after it sends `J_DISCOVER`, any
joined neighbour may answer with the active layer's DATA SF bitmap. The
joiner adopts that bitmap before sending DATA or advertising RTS bitmaps.
The bitmap uses the RTS convention: bit `(sf - 5)` means DATA SF `sf` is
allowed by the layer. Already-joined nodes may observe `J_OFFER` but do not
change their DATA SF policy from it. An unjoined node adopts the first valid
non-zero DATA SF bitmap it receives and ignores later offers until it rejoins;
this avoids nondeterministic "last offer wins" configuration when several
neighbours answer one discovery.

`J_CLAIM`:

```
byte:  0   1        2..5        6                 7..8       9      10
       ┌───┬────────┬────────────┬────────────────┬──────────┬──────┬───────┐
       │'J'│ header │ key_hash32 │ proposed_node_id│ lease_age│epoch │ nonce │
       └───┴────────┴────────────┴────────────────┴──────────┴──────┴───────┘
```

`J_DENY`:

```
byte:  0   1        2          3..6             7..10              11..12     13     14
       ┌───┬────────┬──────────┬────────────────┬──────────────────┬──────────┬──────┬────────┐
       │'J'│ header │ denied_id│ owner_key_hash │ claimant_key_hash │owner_age │epoch │ reason │
       └───┴────────┴──────────┴────────────────┴──────────────────┴──────────┴──────┴────────┘
```

Current denial reasons:

- `1 = conflict`: sender owns or has an adopted/bound owner for `denied_id`.
- `2 = pending_claim`: sender is still inside its own claim guard window but
  wins the deterministic `(key_hash32, nonce)` tie-break against the received
  competing claim. Observers should treat this as lower confidence than an
  adopted-owner denial until a later `join_adopted`/BCN confirms the binding.

All multi-byte integer fields are little-endian. `lease_age` is saturating,
local-clock-relative seconds; it is only a deterministic tie-break input
during partition merge or simultaneous claims, not an absolute timestamp.
The Lua model computes `lease_age = floor((self:now() - self.adopted_at_ms)
/ 1000)` with 16-bit saturation. `self.adopted_at_ms` is set on
`join_adopted` for unjoined nodes and at `on_init` for pre-joined
(pinned-id) nodes. `claim_epoch` is NV-backed via `self.nv` (see
`nv_get`/`nv_set` helpers): on init the node loads the previously-saved
epoch; `join_start_claim` increments and re-persists before each
transmission. The 8-bit field wraps after 256 boots — tie-break consumers
must handle wraparound. Tests can seed initial NV with `config.nv = {
"claim_epoch": N }` at the node level.

### 3.6 NACK (`'N'`) — 4 bytes

```
byte:  0   1                       2                   3
       ┌───┬───────────────────┬───────────────────┬────┐
       │'N'│ reason   (4 hi)   │ payload           │ to │
       │   │ ctr_lo   (4 lo)   │ (reason-specific) │    │
       └───┴───────────────────┴───────────────────┴────┘
```

- `ctr_lo` (4 bits, lo nibble of byte 1): RTS's `ctr_lo` being NACKed.
- `reason` (4 bits, hi nibble of byte 1): which NACK variant this is.
  Currently defined:
  - **0 = `BUSY_RX`** — receiver is holding `pending_rx` for a
    different flight. Payload byte = `busy_for_ms / 16` (ceiling-divide
    so the reported window is never *shorter* than actual). Range:
    0..4080 ms at 16 ms granularity. The 16 ms quantum is well below the
    natural retry-jitter floor (~50 ms); SF12 worst-case airtime is
    ~1100 ms, giving 4× headroom before overflow.
  - **1 = `BUDGET`** — receiver's duty-cycle tier is CRITICAL or
    EXHAUSTED (§9.x). Payload byte = `tier(4 hi) | headroom_buckets(4 lo)`.
    `tier` 0..15 (current tiers: NORMAL=0, STRAINED=1, CRITICAL=2,
    EXHAUSTED=3); `headroom_buckets` 0..15 → 0–100% remaining budget
    (value/15 × 100%). Pass 0 for headroom when unknown.
  - **2 = `HOP_BUDGET`** — DATA flight exceeded its hop budget before
    reaching destination. Payload byte = `committed_hops(4 hi) | reserved`.
  - **3 = `LOOP_DUP`** — DATA decoded, but receiver has already seen the
    same `(origin,dst,ctr)` from a different previous hop. Payload byte =
    prior previous-hop id, or 255 if unknown.
  - 4..15 reserved.
- `to` (8 bits): intended requester/upstream id. Other nodes ignore it.

**Payload decoding summary:**

| reason | byte 2 encoding | decoded fields |
|--------|-----------------|----------------|
| BUSY_RX (0) | `busy_for_ms / 16` (uint8, ceiling) | `busy_for_ms = byte2 × 16` |
| BUDGET  (1) | `tier[7:4] \| headroom[3:0]`  | `budget_tier`, `budget_headroom_buckets` |
| HOP_BUDGET (2) | `committed_hops[7:4] \| reserved[3:0]` | `committed_hops` |
| LOOP_DUP (3) | prior previous-hop id, or 255 | `prior_from` |

NACK rides on `routing_sf` for all reason variants. The originator's
RX is already retuned to `data_sf` after its RTS-tx, but NACK is
distinguished from CTS by its tag byte ('N' vs 'C'), so the originator
hears it regardless of which SF it is listening on at that moment.

### 3.9 Frame-size summary

| Frame | Bytes | Notes |
|---|---|---|
| BCN | 8 + 3n (plain leaf); 8 + [1 + 4L] + 3n (gateway w/ L upper-layer schedule records) | n entries (3 B each, bit-packed) plus fixed `key_hash32`; default 151 B cap fits 47 entries |
| Q   | 4 (+ 1 + 4×N for CHANNEL_PULL body) | one-hop query/control: REQ_SYNC, CHANNEL_PULL |
| H   | 8      | hash-locate flood; multi-hop, forwardable (§3.7a) |
| F   | 6      | route-Find flood (RREQ/RREP); multi-hop, forwardable (§3.7b) |
| J_DISCOVER | 6 | join discovery; carries `key_hash32` |
| J_OFFER | 8 | join bootstrap response; carries DATA SF bitmap |
| J_CLAIM | 11 | short-address claim with lease age, epoch, nonce |
| J_DENY | 15 | conflict/lease denial with owner and claimant hashes |
| RTS | 8 | fixed; `sf_bitmap` byte replaced by `sf_index(2) + rsv(6)` in `c20585b` |
| CTS | 3 | fixed; addressed response |
| DATA | **20 + n** | in-leaf (addr_len=0): `DATA_HDR_LEN=14` (8 base + 6 visited) + 2 B inner-hdr + n B body + 4 B MAC. The 6-B visited-set loop guard shipped as `65f9c8a`. |
| ACK | 3 | fixed; addressed response |
| NACK | 4 | fixed; addressed response |

Per-flight control overhead (RTS + CTS + ACK) = **14 bytes**.

---

## 4. Per-neighbor SNR EWMA + ACK piggyback

The protocol maintains two per-neighbor SNR estimates:

- `self.snr_ewma_in[nbr_id]` — fed by `meta.snr` of every successful
  RX from that neighbor. Used by `select_data_sf` to pick the data SF
  in a CTS based on smoothed signal estimate, not a single noisy
  snapshot.
- `self.snr_ewma_out[nbr_id]` — fed by the 2-bit coarse ACK SNR bucket. The
  receiver of our DATA tells us via the ACK how strongly our DATA
  arrived. Used for: routing-cost weighting (future), per-link RTS
  bitmap trimming (future), link-asymmetry detection.

EWMA update (`update_snr_ewma`):

```
ewma = α · sample + (1 − α) · ewma_prev   if ewma_prev exists
ewma = sample                             on first sample
```

Default `α = 0.3` → ~10-sample effective window.

The `_in` and `_out` EWMAs are kept separate because asymmetric links
(e.g., directional antennas) would otherwise pollute per-direction
estimates. A real LoRa mesh sees ~3-5 dB asymmetry between (A→B) and
(B→A) routinely.

---

## 5. Routing — distance-vector with K=3 alts

### 5.1 Routing table structure

```lua
self.rt[dest_id] = {
  candidates = {
    { next_hop, score, hops, last_seen_ms, n2_hop },  -- primary (slot 1)
    { next_hop, score, hops, last_seen_ms, n2_hop },  -- alt 1
    { next_hop, score, hops, last_seen_ms, n2_hop },  -- alt 2
  },
}
```

- `#candidates` ∈ [1, `MAX_RT_CANDIDATES`] (=3).
- Candidates sorted descending by `route_strictly_better`.
- All `candidates[i].next_hop` distinct.
- `n2_hop`: the chosen neighbor's claimed next-hop for this dest
  (from the beacon entry). Used for 3-cycle detection.
- Mobile/stationary identity is not part of route candidates today.
  It is carried in Q/BCN frames for coordination policy, but route
  selection currently uses link score, hop count, freshness, budget
  tier penalties, and blind-neighbor state.

### 5.1a Direct-neighbor learning

Any valid in-leaf frame with `meta.src` and SNR is direct proof that the
sender is alive and reachable in one hop. Receivers therefore install or
refresh:

```lua
rt[src] = { next_hop=src, score=rx_snr, hops=1, last_seen_ms=now }
```

This applies to BCN, Q, RTS, CTS, DATA, ACK, and NACK. BCN still carries
the richer DV payload, but a node does not need to wait for a peer's BCN
before it can answer "I know that peer directly" in response to a route
query. If this direct observation creates or promotes the primary route,
the node marks the route dirty and schedules a normal triggered beacon;
it does not force a full BCN by itself.

### 5.2 DV merge (`rt_merge`)

For each candidate `cand` derived from a direct observation or beacon
entry:

```
1. Look up rt[dest]. If absent, install cand as primary; emit "rt_update".
2. Match-by-next_hop (any slot):
    - If cand strictly better: refresh in place; sort.
    - Else: refresh last_seen_ms + n2_hop; no-change.
3. New next_hop AND #candidates < K:
    - Insert; sort.
4. New next_hop AND #candidates == K:
    - If cand strictly beats worst: replace worst; sort.
    - Else: drop.
```

`route_strictly_better(a, b)`:

```
1. Viability tier: route's score ≥ routing_snr_floor_db means the
   path is end-to-end decodable on the control plane.
2. Viable beats non-viable (any hops).
3. Within tier:
    - Viable: fewer hops wins; score breaks ties.
    - Non-viable: better score wins; fewer hops breaks ties.
```

### 5.3 3-cycle prune

When a beacon entry says `(dest, next=self.id)` — meaning the beacon
sender routes `dest` via me — and any of my own candidates for `dest`
has `n2_hop == sender.id`, that candidate is part of a 3-cycle
(me→X→sender→me). The candidate is dropped; `rt_prune` event fires.

If all candidates loop, the entry is removed entirely.

### 5.4 Beacon advertises only primary

To keep beacon size proportional to network size (not K×network_size),
beacons advertise only `candidates[1]`. Alts are computed locally at
each receiver from their own per-neighbor candidate set — there's no
protocol-level negotiation about which path is "alt" anyway, that's a
per-receiver judgment.

### 5.5 Failure cascade through alts

When the primary next-hop's RTS budget exhausts (rts_timeout retries)
or its DATA-ACK round exhausts:

```
rts_timeout_fire / ack_timeout_fire — retries_left == 0 path:
  1. Mark current next_hop as tried (pending_tx.alts_tried[next] = true)
  2. pick_next_cascade_hop — walk rt[dst].candidates for first that:
     - is not in alts_tried
     - is not currently blind (F1 mitigation)
     - is not the previous_hop (loop guard for forwarders)
  3. If found:
     - Switch pending_tx.next; reset retries; tx_rts_retry("cascade_rts")
     - Emit path_cascade
  4. If exhausted (no more alts):
     - try_cascade_requeue (§5.6) — push back to tx_queue with backoff
       so other queued items can drain. Returns true if requeued.
     - If requeue caps hit: emit path_cascade_exhausted + the legacy
       giveup event (rts_giveup or data_ack_giveup); clear pending_tx.
```

### 5.6 Cascade-exhaustion requeue (Phase C)

A single stuck destination must not block deliverable items behind it
in `tx_queue`. When `pending_tx` exhausts all K alts (true
`path_cascade_exhausted`), instead of dropping immediately the item is
pushed back into `tx_queue` with **exponential backoff** so other
queued items can rotate through the dispatch.

```
try_cascade_requeue(self, trigger):
  next_count   = (px.requeue_count or 0) + 1
  total_age_ms = now − px.enqueue_time_ms
  if next_count > cascade_requeue_max:           return false  ← drop
  if total_age_ms >= cascade_requeue_total_max_ms: return false  ← drop
  backoff_ms = min(cascade_requeue_base_ms × 2^(next_count - 1),
                   cascade_requeue_backoff_cap_ms)
  push to tx_queue with:
    next_attempt_ms = now + backoff_ms       ← scheduled, not FIFO
    requeue_count   = next_count             ← bumped
    enqueue_time_ms = original                ← preserved
  emit cascade_requeue {requeue_count, backoff_ms, total_age_ms, trigger}
  return true                                ← caller skips legacy giveup
```

`tx_queue` is now a **scheduled queue** of items shaped
`{origin, dst_id, dst_name, body, ctr, flags,
previous_hop, next_attempt_ms, requeue_count, enqueue_time_ms}`.
`become_free` pops the earliest-ready item (smallest
`next_attempt_ms <= now`, FIFO tie-break) whenever the node becomes
idle. If no item is ready, `become_free` arms a single
`queue_wakeup_handle` and returns.

**Load-adaptive cap (Phase D3):** under sustained local pressure (deep
`tx_queue`), the effective `cascade_requeue_max` shrinks. Each item in
`tx_queue` beyond `cascade_requeue_load_threshold` (default 0)
subtracts 1 from the budget. When the effective budget reaches 0, new
cascade exhaustions drop immediately instead of being requeued — a
stressed node sheds retry load so it stops choking the channel with
retries that aren't going to succeed. The diagnostic emit
`cascade_load_skip` distinguishes load-induced drops from hard-cap
exhaustion.

**Per-message retry budget (Phase D4):** alongside the requeue cap,
the per-cycle RTS retry count *also* shrinks per requeue:
`effective_rts_max_retries(self, requeue_count) = max(0,
rts_max_retries - requeue_count)`. So a fresh send (requeue=0) gets
the full 3 RTS retries × 3 alts = 9 RTS attempts per cycle; a
3×-requeued zombie gets 0 × 3 = 3 (alt walk only, no per-hop
retry). Zombie messages spend less channel time per cycle.

**Requeue-aware queue priority:** `become_free` picks the ready item
with the LOWEST `requeue_count` first (tie-break by `next_attempt_ms`,
then FIFO). Fresh sends jump ahead of zombies in the queue — fresh
messages have the best chance of delivering quickly (route still
valid; channel not yet polluted by their retries), so the
channel-time investment goes where it pays off.

This implements K=3 multi-alt routing PLUS bounded-time stuck-flight
isolation PLUS load-adaptive shedding, all without changing the wire
format.

| Key | Default | Description |
|---|---|---|
| `cascade_requeue_max` | 3 | Max number of cascade-exhaust requeues before drop |
| `cascade_requeue_base_ms` | 5000 | Base backoff (exponential: base × 2^(count-1)) |
| `cascade_requeue_backoff_cap_ms` | 30000 | Backoff caps at this value |
| `cascade_requeue_total_max_ms` | **60000** | Total wallclock cap; older items drop. (Was 120000 pre-D3 — tightened after measuring s04 successful-delivery max ~115s; 60s keeps most legitimate slow paths alive while killing 3-13 minute zombie cascades.) |
| `cascade_requeue_load_threshold` | 0 | Local tx_queue depth above which the effective requeue budget starts shrinking (Phase D3) |

**Swimlane:** see `docs/SCENARIOS.md` §4.2 (cascade-requeue lifecycle).

### 5.7 Tier-aware routing (`route_strictly_better` penalty)

Composes §11.5 budget tiers with `rt_merge`'s candidate ordering. The
per-neighbour duty-cycle tier signal — set when a peer sends us a
budget-NACK (§3.6 reason=`budget_low`) — propagates from the
reactive blind-mark machinery into route comparison. Route candidates store a
conservative score: control/DATA RX SNR samples are reduced by
`route_snr_conservatism_db` before they enter `rt_merge`. This keeps marginal
links available, but makes route ordering prefer cleaner alternatives because
one successful SF8 control decode is not treated as a stable DATA-plane
margin guarantee. Temporary neighbour-health overlays then adjust the
effective score used while ordering and choosing candidates. Saturated
next-hops are demoted from the primary slot when there is a usable
alternative, not just temporarily skipped during `classify_blind`.

```
TIER_SCORE_PENALTY_BY_ALTS_DB:
  STRAINED:  no viable alt=1,  one alt=4,  two+ alts=7
  CRITICAL:  no viable alt=5,  one alt=10, two+ alts=15
  EXHAUSTED: no viable alt=8,  one alt=15, two+ alts=25

effective_score(c) =
  c.score
  - penalty[get_tier(c.next_hop)][viable_alt_count_for_dest(c)]
  - peer_suspect_penalty(c.next_hop)

route_strictly_better uses effective_score wherever it used raw score
```

**State.**
- `neighbor_budget_tier[X]` — last-known tier of peer X.
- `neighbor_budget_tier_set_at[X]` — when set.
- `neighbor_budget_tier_ttl_ms` — expiry (default 5 min). After this,
  `get_neighbor_tier(X)` returns HEALTHY → saturated peers return to
  the primary pool when no fresh NACKs arrive.
- `peer_rts_timeouts[X]` — consecutive sender-side RTS timeouts while
  targeting peer X.
- `peer_suspect_until[X]` / `peer_silent_until[X]` / `peer_dead_until[X]` —
  temporary peer-liveness overlays. They penalize or gate candidates via X;
  they do not delete routes.
- `peer_suspect_advertise_until[X]` — local-only advertisement window. Set
  only from this node's RTS timeouts, not from remote suspect TLVs.
- `peer_dead_advertise_until[X]` — local-only explicit dead advertisement
  window. Set only from local long-window RTS timeout evidence.

**Set on:** budget NACK reception (§3.6 reason=`budget_low`), alongside
the `blind_until` mark. On receipt, the node immediately re-sorts any
local route entries that use the penalized neighbour; if the advertised
primary changes, it marks the entry dirty and schedules a normal
triggered beacon. Repeated RTS silence sets `peer_suspect_until` after
`peer_suspect_rts_timeouts` attempts and `peer_silent_until` after
`peer_silent_rts_timeouts`; the next BCN can carry the suspect-node TLV from
§3.1. Route selection also refreshes candidate order before
issuing/cascading sends so expired penalties naturally allow recovered
peers back into the primary pool. A `suspect` peer is only penalized; a
`silent` peer is temporarily ineligible for new RTS selection.

Immediate next-hop liveness is gated separately from destination-route
freshness. Before any RTS is issued, the selected immediate next-hop must
have been directly heard within `next_hop_live_ttl_ms`; otherwise that
candidate is skipped even if the destination route entry has not aged out.
This prevents spending RTS attempts on routes whose destination knowledge is
still fresh but whose relay has disappeared. If all candidates are stale or
silent, the sender defers the packet and emits an `'F'` RREQ flood (§3.7b)
instead of burning more RTS attempts. BCN/DV route entries whose advertised second hop
is locally `silent` are skipped so a neighbour does not reintroduce a
proposal through a known-dead node.

Promotion to `dead` requires longer evidence: by default at least
`peer_dead_rts_timeouts` local RTS timeouts spread across
`peer_dead_evidence_window_ms` (15 min). Dead state is advertised in BCN TLV
type 2 and expires by `peer_dead_ttl_ms`, or immediately on any valid frame
from that node.

**Pays off when:** load is **asymmetrically distributed** — some hubs
have slack, others are saturated. The proactive demotion shifts
traffic to the slack. On a fully-saturated mesh (s04 60-min, every
active hub near its cap) the mechanism still fires (`rt_update` 148 →
821, 5.5× shuffle) but throughput is bounded by physics, not topology
diversity — delivery stays flat. The instrumentation is valuable as a
diagnostic for future scenarios with asymmetric load.

---

## 6. Beacon plane

### 6.1 Periodic beacon

```
on_init enters node-local DISCOVERY and schedules first beacon at
rand(0, discovery_beacon_period_ms)
Every beacon_fire:
  1. If pending_tx ~= nil OR pending_rx ~= nil: log + skip emission
  2. Else: adaptive-throttle gate (see §6.2)
  3. Always: re-arm next periodic at rand(0.8×period, 1.2×period)
     - period = discovery_beacon_period_ms during DISCOVERY
     - period = beacon_period_ms after DISCOVERY
```

Defaults: discovery period 5 s, operational period 15 min. Firmware
behavior does not depend on simulator `warmup_ms`; a node that boots
late gets the same local discovery window as a node present at t=0.

**Swimlane:** see `docs/SCENARIOS.md` §1.1 (BCN periodic emit + receive).

### 6.2 Adaptive throttle (heard-channel busy)

The throttle's job: in dense networks, suppress periodic beacons when
the channel is recently active. Uses `last_rx_routing_sf_ms`, updated
at the top of every `on_recv` AND by the runtime's PreambleDetected
callback (`on_preamble_detected`) for frames that don't fully decode
(fixes the cascade where SNR variance defeats the throttle).

```
beacon_fire emission gate:
  since_busy = now − last_rx_routing_sf_ms
  if since_busy < quiet_threshold_ms (default 30 s):
    emit("beacon_skipped_busy", stage="pre_jitter"); skip
  else:
    schedule deferred fire at now + rand(0, beacon_silence_jitter_ms)
    at deferred-fire time, re-check silence:
      if since_busy < quiet_threshold_ms: skip
      else: send_beacon_page("periodic")
```

The deferred fire prevents thundering-herd: when many nodes
simultaneously detect the same busy→quiet transition, they stagger
their TXes across the silence-jitter window (default 10 s).

`quiet_threshold_ms = 0` disables both the throttle and the silence-
jitter (used by unit tests).

**Max-idle override (`beacon_max_idle_ms`):** in dense meshes (100+
nodes), the channel never goes quiet for the 30 s threshold —
periodic beacons are suppressed indefinitely once the network is
busy. Routes learned during discovery then age out later
with no fresh advertisements arriving, and the network can collapse
into a stable 0%-delivery state.

The override: if a node hasn't BCN'd in `beacon_max_idle_ms`
(default **900 s = 15 min**, comfortably below the 45 min default
`rt_aging_ttl_neighbor_ms`), bypass the busy throttle on the next
periodic timer fire and emit anyway. Both gate-check sites (pre-
jitter and post-jitter) honour the override. Emit
`beacon_max_idle_force` makes the override visible in telemetry.

`last_beacon_tx_ms` is set inside `send_beacon_page`, so triggered
beacons also reset the staleness clock — periodic + triggered
combine as expected. Set `beacon_max_idle_ms = 0` to disable the
override entirely.

**B+C composite filter (post-`246cb8a`).** The pure max-idle override
recreates the synchronized-burst failure it was meant to fix: 138
nodes hit max_idle within seconds of each other (all warmed up around
the same time), forced through a 10s silence-jitter, producing
50-57 BCN/min bursts that re-saturate the channel at ~300% capacity.
The composite filter dampens this:

- **(B) Defer override on recent BCN-RX.** New tracker
  `last_rx_bcn_ms` (separate from `last_rx_routing_sf_ms` — only set
  on actual BCN reception, NOT on RTS/CTS/ACK). When override eligible
  AND a neighbour BCN'd within the last `beacon_max_idle_ms / 3`, defer
  our override. The first nodes to hit max_idle fire, their BCNs land
  at neighbours, neighbours see fresh `last_rx_bcn_ms` and defer their
  own overrides → naturally cascading the burst across `max_idle/3`
  (~5 min for the 15 min default) instead of compressing into the
  silence-jitter's 10 s window.

- **(C) Skip-if-clean.** When override eligible AND we have **zero
  dirty rt entries** (nothing new to advertise), AND a neighbour just
  beaconed (refresh load is being carried), **skip the override
  entirely**. Avoids burning channel time on no-information emissions.
  Heartbeat preserved: dirty=0 nodes whose neighbours have ALSO gone
  silent will still fire (both filter conditions fail). Emit
  `beacon_max_idle_skip_clean` makes this visible in telemetry.

Composite skip condition:
```
dirty_n == 0 AND since_bcn_rx < beacon_max_idle_ms / 3
```

Both pre-jitter and post-jitter override paths apply the same filter
so a neighbour BCN landing during our jitter window correctly defers
our emission.

Real-deployment tuning: keep `beacon_max_idle_ms` <
`rt_aging_ttl_neighbor_ms` so direct-link entries get refreshed
before they age out. Multi-hop entries
(`rt_aging_ttl_remote_ms`) survive longer rotation gaps.

**Swimlane:** see `docs/SCENARIOS.md` §1.2 (throttle gate decision + channel inputs).

### 6.3 Triggered beacon

Any `rt` mutation (new entry, primary promote, 3-cycle prune)
schedules a one-shot beacon within `[beacon_trigger_jitter_min_ms,
beacon_trigger_jitter_max_ms]` (default 2–10 s).

```
schedule_triggered_beacon:
  if triggered_beacon_pending: no-op (coalesced)
  triggered_beacon_pending = true
  delay = rand(2s, 10s)
  if outside discovery/boot grace and last BCN < trigger_min_interval:
      delay until last BCN + trigger_min_interval + rand(2s, 10s)
      emit beacon_trigger_deferred
  after delay: triggered_beacon_pending = false
               send_beacon_page("triggered")
```

**Triggered beacons bypass the adaptive throttle.** They exist to
propagate routing changes urgently; suppressing them on busy channels
defeats the purpose. Half-duplex skip still applies. The steady-state
minimum interval is the firmware realism guard: a burst of route
changes coalesces into at most one dirty BCN every
`beacon_trigger_min_interval_ms` per node. Node-local DISCOVERY and the
first `beacon_boot_grace_ms` after boot bypass the minimum interval so
joiners can converge quickly.

**Swimlane:** see `docs/SCENARIOS.md` §1.3 (route-change → triggered BCN → cascade).

### 6.4 Differential beacons (dirty-first emission)

`pack_beacon` is two-tiered. When emitting:

1. **Phase 1 — dirty routes (priority):** every `rt[dest]` with
   `.dirty=true` is emitted first, sorted by `dest_id`. The flag is
   set by `rt_merge` on actions that change the route this node would
   advertise (`"new"`, `"promote"`, `"primary_refresh"`) and by
   `rt_prune_cycle` when the primary slot is removed. Cleared once the
   route is included in a beacon.

2. **Phase 2 — stable rotation (discovery/background):** existing
   sliding-offset walk fills any remaining slots up to `beacon_max_entries`,
   skipping destinations already in Phase 1 (dedup within a single beacon).
   This phase runs during node-local DISCOVERY so a booting node can learn
   and advertise enough topology. After DISCOVERY, periodic and triggered
   BCNs skip Phase 2 and become dirty-only route updates plus the optional
   destination-seen bitmap.

The stable offset only advances by the number of stable slots used.
When dirty fills the beacon, stable progress isn't lost.

**Steady state with no churn after discovery:** every route is clean →
Phase 1 is empty → Phase 2 is skipped → BCN carries only the header, optional
destination-seen bitmap, and optional extension TLVs. Existing same-next-hop
candidates are kept fresh by bitmap refresh, not by re-advertising full route
pages. Suspect-node TLVs are a separate temporary liveness hint.

**Active state with churn:** route mutations land in the dirty set and
are guaranteed to ship in the next beacon. Convergence latency for a
new route change drops from `O(rotation_window × beacon_period)`
(could be minutes for large tables) to `O(beacon_period)` (single
round-trip).

Telemetry: `beacon_diff_breakdown` event fires per beacon with
`{dirty_n, stable_n, total_dirty, rt_total, kind, n_entries, seen_bits,
suspect_nodes, ext_len, dirty_only}`. `total_dirty` greater than `dirty_n`
means some dirty
entries overflowed the page and will surface in the next beacon (no
information loss).

The receiver doesn't know whether a route entry was dirty or stable — it
just merges via existing `rt_merge`. Bitmap presence is explicit in byte 3
and handled separately from route-entry merging.

### 6.5 Stale-route aging

Per-candidate `last_seen_ms` is refreshed by scoped evidence that the same
next hop can still reach the destination:

- `rt_merge` refreshes it when a beacon advertises that exact
  `(dest, next_hop)` combination.
- Any successfully received frame from a direct neighbour refreshes the
  direct one-hop candidate for that neighbour.
- A destination-seen bitmap from neighbour `B` refreshes only existing
  candidates whose `next_hop == B`.

A periodic aging loop walks `rt[]` every `rt_aging_check_period_ms`
(default 60 s) and evicts candidates older than a
**hop-class-specific TTL**:

- `hops == 1` (direct neighbour) → `rt_aging_ttl_neighbor_ms`
  (default **45 min**)
- `hops >= 2` (remote multi-hop) → `rt_aging_ttl_remote_ms`
  (default **3 h**)

```
age_out_stale_routes(self):
  ttl_n = rt_aging_ttl_neighbor_ms
  ttl_r = rt_aging_ttl_remote_ms
  for each rt[dest]:
    keep, primary_evicted = filter candidates by:
      (now - c.last_seen_ms) < (c.hops == 1 ? ttl_n : ttl_r)
    if #keep == 0:
      rt[dest] = nil
      schedule_triggered_beacon
    elif primary_evicted:
      entry.candidates = keep
      entry.dirty = true     ← differential beacon (§6.4) ships new primary
    else:
      entry.candidates = keep   ← only alts evicted, no broadcast needed
  if any evicted: emit rt_aged + schedule_triggered_beacon
```

**Two-tier TTL rationale.** Direct-neighbour entries refresh on every
received frame from that neighbour (RTS/CTS/DATA/ACK/BCN — see "any-RX
refresh" below). They tolerate a shorter TTL because death detection
for moving / dying neighbours stays responsive. Multi-hop entries
only refresh when their advertiser's beacon-rotation slot lands on
that destination — they need a much longer TTL to survive normal
rotation gaps without false-eviction (in a 100-node mesh with 49
entries/page, full rotation is ~3 beacon periods × success rate, easily
30+ minutes under throttling).

Identity ownership is aged separately from route freshness. `id_bind[]`
answers "which long-term key owns short id X?" and uses `id_bind_ttl_ms`,
default 48 h. Expiring a route candidate does not recycle the short ID.
Only an expired identity binding makes the ID available for future join.

**Direct-neighbour last_seen refresh on ANY RX:** the on_recv top hook
also refreshes `rt[meta.src].candidates[direct].last_seen_ms` for every
incoming frame, not just beacons. Prevents direct neighbours from
being falsely evicted when their periodic beacons are throttle-
suppressed under heavy traffic — RTS/CTS/DATA/ACK traffic from them
counts as proof they're alive. Multi-hop entries still age via beacon
advertisements only.

**Why no explicit "delete" advertisement?** The wire format has no
"this route is gone" frame. When a node evicts a destination entirely,
the triggered beacon advertises the rest of the table without the
gone destination. Neighbours hearing that beacon refresh their other
routes via this node, and their own aging loop eventually evicts the
gone destination from their tables (when `last_seen` to it stops
refreshing). Cascade time across N hops: ~`N × ttl`.

**Configurable behavior:**

| Key | Default | Description |
|---|---|---|
| `rt_aging_ttl_neighbor_ms` | 2700000 (45 min) | Direct-neighbour candidate expires if not refreshed within this window |
| `rt_aging_ttl_remote_ms` | 10800000 (3 h) | Multi-hop candidate expires if not refreshed within this window |
| `rt_aging_check_period_ms` | 60000 (1 min) | How often the aging scan runs |
| `id_bind_ttl_ms` | 172800000 (48 h) | Short-ID ownership binding expires if no key-confirming traffic refreshes it |

Set both TTLs to 0 to disable aging (memory leak risk in long-lived
deployments; useful for tests).

**Swimlane:** see `docs/SCENARIOS.md` §1.4 (stale-route aging — tick + cascade consequence).

### 6.6 Bounded beacons (paged emission)

A full routing table of 100+ destinations exceeds the 255-byte LoRa
frame limit. `pack_beacon` takes a `max_entries` cap and a sliding
`offset`. Successive beacons rotate through the table:

```
pack_beacon(node, max_entries, offset):
  all_dests = sort(rt.keys)
  page = all_dests[offset:offset+max_entries]  (wrapping)
  return frame, (offset + n) % total
```

`beacon_offset` advances per fire. Entry capacity is derived from the active
wire format. With the current fixed 8-byte BCN header and 3-byte entries:

```
beacon_max_entries = floor((beacon_max_bytes - 8) / 3)
```

For the default 151-byte airtime cap, this yields 47 entries. If a deployment
raises `beacon_max_bytes` to 200, the same format can carry 64 entries.

Receivers don't track pages — every entry heard gets merged via
`rt_merge` as before.

---

## 7. Data plane — happy path

End-to-end flight from originator to destination, no failures.

### 7.1 Sequence diagram (single-hop unicast)

**Swimlane:** see `docs/SCENARIOS.md` §2.1 (RTS-CTS-DATA-ACK single hop).

**Multi-hop swimlane:** see `docs/SCENARIOS.md` §2.2 (multi-hop forward: alice → F → bob).

### 7.2 SF retune timeline

The originator/forwarder's **RX SF stays on `routing_sf` for the
entire flight**. Only the receiver retunes. TX SF is set per-frame
(routing_sf for RTS/CTS/ACK/NACK, chosen `data_sf` for DATA) and is
independent of the modem's RX SF (lua:6064-6066).

```
RX state at originator/forwarder:

t=0          (no retunes)        t=after ACK-rx
routing_sf ──────────────────── routing_sf
              (CTS, NACK, and ACK all arrive on routing_sf;
               sender's DATA TX uses a per-frame SF override
               which does not change RX state)
```

The next-hop receiver retunes RX **twice**:

```
RX state at next-hop:

t=0          t=after CTS-tx     t=after DATA-rx
routing_sf ─→ data_sf         ─→ routing_sf
              (awaiting DATA      (ready to TX ACK on
               on chosen SF)       routing_sf and to
                                   receive next RTS)
```

There's a window between CTS-tx completing and ACK-tx where the
receiver is on `data_sf` to receive DATA. During that window
concurrent senders' RTSes on routing_sf land as `drop_sf_mismatch` —
the receiver is deaf on routing_sf for `cts_to_data_gap_ms +
airtime(chosen_data_sf, max DATA frame)`. See §8.4 for the F1
blind-window mitigation (passive CTS overhearing populates
`blind_until` at peers so they defer their RTSes).

### 7.3 Per-flight TX policy classes

Three categories, each with different LBT timing constraints:

| Class | Frames | Policy |
|---|---|---|
| **RESPONSE-DIRECTED** | CTS, DATA, ACK | Goes straight through `tx_with_retry`. Peer's timer is already running and was sized to the *minimum* round-trip airtime; any LBT defer here would burn a retry. |
| **INITIATING-DIRECTED** | RTS, NACK | Routed through `tx_initiating`. Pre-checks `channel_busy_until()` once (single politeness wait). If busy, schedules emit at `busy_until + rand(0, lbt_backoff_ms)`, then commits even if still busy. |
| **FLOOD** | BCN | Routed through `tx_flood`. LBT-defers up to `flood_lbt_max_defer_ms`, then drops the page (`tx_flood_skipped`). Stale routing info isn't worth queueing. |

All three set `pending_tx` (where applicable) BEFORE the actual emit,
so peer NACK / busy-replies match the right ctr_lo.

### 7.4 End-to-end delivery ACK (opt-in per-message)

The hop-by-hop K-frame ACK (§3.5) only confirms that the *immediate
next forwarder* received the DATA. If a forwarder mid-path drops the
message after sending its K-ack — disk full, app crash, queue
overrun, route change — the originator's K-ack still succeeded and
the loss is silent. For important user messages (payments, status
confirmations) the originator needs end-to-end confirmation.

**Design.** Opt-in per message. The originator sets the
`E2E_ACK_REQ` bit (bit 3) on **wire byte 1** of the DATA frame (§3.4).
The destination, on accepting delivery, sends a small return DATA frame
back to the originator with `E2E_IS_ACK` (bit 2) set on wire byte 1
and body = `[acked_ctr_lo, acked_ctr_hi]`. The return frame travels
via normal data-plane mechanics (RTS/CTS/DATA/ACK + routing) — no new
frame type, no new forwarding logic. Only origin and destination know
it is an ACK; intermediate forwarders see ordinary DATA (the flag bits
are visible on wire byte 1 but forwarders relay them verbatim without
acting on them).

**Originator flow.**
```
Originator calls send_e2e <dst> <text>:
  - allocate ctr = self:next_ctr(dst_id)   (per-(self,dst) 16-bit counter)
  - record pending_e2e[dst_id, ctr] = { sent_at, dst, ctr, text }
  - emit e2e_ack_pending
  - enqueue with E2E_ACK_REQ set on wire byte 1 (flags = DATA_FLAG_E2E_ACK_REQ)
```

**Destination flow (on `delivered` of a DATA with E2E_ACK_REQ set).**
```
parse_data gives: d.e2e_ack_req = true, d.ctr = originator's ctr, d.body = user text
Emit `delivered` (payload=d.body) — unchanged from user perspective
If e2e_ack_req:
  - return_ctr = self:next_ctr(d.origin)   (destination's own ctr for this pair)
  - return_body = [d.ctr & 0xff, (d.ctr >> 8) & 0xff]   (acked ctr, LE)
  - inner = src_addr_len(0) | src_addr(self.id) | return_body
  - enqueue with flags = DATA_FLAG_E2E_IS_ACK, ctr = return_ctr, payload = inner
  - emit e2e_ack_tx_enqueued (analyzer / diagnostic)
Note: the return frame never sets E2E_ACK_REQ — no recursion.
```

**Originator flow on receiving the E2E ACK.**
```
on_recv "D" → delivered branch (d.e2e_is_ack = true):
  - acked_ctr = d.body:byte(1) | (d.body:byte(2) << 8)
  - look up pending_e2e[d.origin, acked_ctr]:
      - present: emit delivered_confirmed (payload = info.user_text), clear entry
      - absent : emit e2e_ack_unmatched (duplicate or already timed out)
  - DO NOT emit a normal `delivered` (this is an ACK, not user content)
  - DO NOT trigger another E2E ACK (E2E_IS_ACK bit prevents recursion)
```

**Timeout.** The 1-s drain loop (existing) prunes `pending_e2e`
entries older than `e2e_ack_ttl_ms` (default 60 s) and emits
`e2e_ack_timeout`. The app layer decides whether to retry, surface
"no answer received", or fall back to assumed delivery.

**Cost.** E2E ACK return inner = 2 B src-addr-hdr + 2 B acked-ctr = 4 B
inner content. On wire: 10 + 2 = 12 B per hop (DATA framing at in-leaf).
At SF8 BW250 a 3-hop round-trip is roughly 600 ms total airtime. This is
**why it's opt-in** — at scale, ACKing every flight doubles the airtime budget
consumed per message.

**Composition.**
- **§1 anti-spam:** an E2E ACK is itself an origination from the
  destination's radio. It counts toward the destination's own
  fair-share quota — design feature, not bug (a heavy responder can't
  avoid its own rate cap).
- **§9 privacy T2:** when origin moves into the encrypted payload, the
  destination still has the origin's identity from decryption, so it
  can still construct the return ACK. Forwarders carrying the ACK
  don't need to know it's an ACK — they just see DATA.
- **§5.6 cascade-requeue:** an E2E ACK is a normal DATA send, so it
  participates in the full cascade-alt machinery. If the return path
  is congested, the ACK can fail like any other flight — `e2e_ack_timeout`
  surfaces this at the originator.

**Tuning knob.** `e2e_ack_ttl_ms` (default 60000 ms) — how long
`pending_e2e` entries live before timeout. Sized for typical 3-5 hop
round-trip with retries; longer for known-deep meshes.

**Swimlane:** see `docs/SCENARIOS.md` §2.3 (E2E ACK round-trip: alice → bob → alice).

---

## 8. Data plane — failure modes

### 8.1 RTS reaches receiver but it's busy

NACK fires ONLY for the `pending_rx` busy case. The `pending_tx`
(busy-as-sender) trigger was **removed** because the busy_for_ms
estimate lied in the failure case — a node stuck in an ACK-loss
retry loop predicts ~5 s but is actually busy 60+ s, causing
senders to make wrong decisions. Now silent-drop with
`rts_drop_pending_tx`; senders rely on `rts_timeout` + cascade.

```
on_recv 'R' at receiver:
  if pending_rx busy + DIFFERENT (sender or ctr_lo):
    emit nack_tx
    pack_nack(r.ctr_lo, busy_for = pending_rx_expires_in)
    tx_initiating 'N' on routing_sf
    (NACK on routing_sf — same as CTS/ACK — because the
     sender's RX is on routing_sf throughout, see §7.2)
  elif pending_tx busy:
    emit rts_drop_pending_tx          ← silent drop, no NACK
    return
  else: normal RTS handling
```

Originator on receiving NACK:

```
on_recv 'N', matches pending_tx.ctr_lo:
  cancel rts_timeout
  mark NACK sender blind for busy_for_ms (so retries defer)
  if busy_for ≤ NACK_WAIT_THRESHOLD_MS (2 s default):
    after busy_for + 1 + rand(0, retry_jitter_ms): tx_rts_retry("nack_wait")
    (same next-hop)
  else:
    push pending_tx back into tx_queue; pending_tx = nil
    become_free  (DV may converge or other queued work surfaces)
```

We **never path-switch on a NACK.** NACK carries only a transient
busy signal; the receiver freeing up is the natural event to wait
for. Path-switching on busy NACK is harmful when next == dst (the
busy node is the originator's only target).

**Swimlane:** see `docs/SCENARIOS.md` §3.1 (RTS hits busy receiver → NACK BUSY_RX).

(Note: the `pending_tx`-busy case at R is a silent drop with
`rts_drop_pending_tx`, no NACK — the busy_for_ms estimate from a node
stuck in an ACK-loss retry loop was unreliable, see commentary above.)

### 8.2 RTS already acked (sender retried after losing previous ACK)

```
ack_key = (r.src, r.dst, r.ctr_lo, r.payload_len)
on_recv 'R' with last_acked_from[ack_key]
       AND (now − last_acked_from[ack_key].t_ms) < last_acked_ttl_ms (10 s):
  emit rts_already_acked
  pack_cts(r.ctr_lo, chosen_data_sf, already_received=1) → tx 'C' on routing_sf
  return  (skip CTS + DATA)
```

The sender's previous ACK was lost; they retried the RTS. We answer
with CTS `already_received=1`, so they clear `pending_tx` without
retransmitting DATA and without us reprocessing or forwarding the
message twice.

The cache key includes destination and RTS `payload_len`, not only
`(sender, ctr_lo)`. The 4-bit `ctr_lo` is intentionally small, so a
sender can have different in-flight or recent packets with the same low
counter. The 10s TTL bounds wraparound exposure; the wider key prevents
cross-packet false positives during normal retry traffic.

**Swimlane:** see `docs/SCENARIOS.md` §3.2 (RTS retry after lost ACK → CTS `already_received=1`).

### 8.3 Duplicate RTS while we're mid-flight as receiver

```
on_recv 'R' with pending_rx ~= nil AND
            pending_rx.from == r.src AND
            pending_rx.dst == r.dst AND
            pending_rx.ctr_lo == r.ctr_lo AND
            pending_rx.payload_len == r.payload_len:
  emit rts_rx_dup
  pack_cts(r.ctr_lo, pending_rx.chosen_data_sf)
  tx 'C' on routing_sf  (CTS-dup label)
  restart pending_rx_expiry
```

Sender's previous CTS was lost. They retried RTS. We re-send CTS
with the same chosen_data_sf so they can re-attempt DATA.

**Swimlane:** see `docs/SCENARIOS.md` §3.3 (duplicate RTS while R is mid-flight → re-emit CTS).

### 8.4 F1 mitigation — passive CTS overhearing

**Problem:** when relay R has just sent CTS and retuned to data_sf
to receive DATA, R is **deaf** on routing_sf for
`cts_to_data_gap + data_airtime`. Concurrent senders' RTSes to R
during this window land as `drop_sf_mismatch` — silent at the
runtime, no NACK, so the sender wastes `rts_max_retries` before
`rts_giveup`.

**Mitigation:** every node maintains `self.blind_until[node_id] →
absolute_ms`, populated by overhearing every CTS frame on routing_sf
(whether addressed to us or not). The CTS payload carries
`chosen_data_sf` so we can compute the upper-bound blind window:

```
blind_window = cts_to_data_gap_ms + airtime(chosen_data_sf, max DATA frame)
```

Three call sites consult `blind_until` before TXing an RTS:

- `issue_send` — first attempt
- `tx_rts_retry` — every retry
- `rts_timeout_fire` — when timeout fires, re-check

Forwarder route selection also applies the `previous_hop` loop guard to
the initial primary candidate before RTS emission. If the best local
route points back to the node that just handed us the DATA, `issue_send`
uses the first fresh, non-blind, non-suspect alternate and emits
`tx_previous_hop_alt`; if none exists it emits `send_no_route` with
`reason=previous_hop_only`.

```
classify_blind(self, dst, current_next_hop, alts_tried, previous_hop):
  if current_next_hop is blind:
    walk rt[dst].candidates:
      first non-tried, non-blind, non-previous_hop alt → return "alt", alt
    no qualifying alt → return "defer", remaining_blind_ms
  else:
    return "ok"
```

Plus exponential backoff on `rts_timeout_ms` (×2 per attempt, capped
at `RTS_TIMEOUT_BACKOFF_CAP = 4`) so the existing retry budget covers
a full receiver blind window even when the CTS itself was lost in
flight (overhearing mechanism never fired).

**Swimlane:** see `docs/SCENARIOS.md` §3.4 (passive CTS overhearing populates blind_until at peers).

### 8.5 RTS-timeout (CTS lost)

```
rts_timeout_fire:
  if pending_rx set:
    after rts_busy_retry_ms: re-fire (we're mid-RX, can't TX yet)
  elif retries_left > 0:
    classify_blind for current next_hop
    if "alt", new_next: switch + reset retries; tx_rts_retry("cts_timeout")
    elif "defer", delay: defer; recheck on fire
    else: after rand(0, retry_jitter_ms): tx_rts_retry("cts_timeout")
  else (retries_left == 0):
    K=3 cascade: try next non-tried alt
    if none: emit rts_giveup + path_cascade_exhausted; clear pending_tx
```

**Swimlane:** see `docs/SCENARIOS.md` §3.5 (no CTS arrives → exponential backoff → K=3 alt cascade).

### 8.6 ACK-timeout (DATA lost or ACK lost)

Same cascade as rts_timeout. `data_ack_giveup` is the legacy giveup
event; `path_cascade_exhausted` fires alongside.

### 8.7 pending_rx_expiry (DATA never arrived)

```
pending_rx_expiry_fire:
  set_rx_sf(routing_sf)
  pending_rx = nil
  emit data_rx_timeout
  become_free  (we missed the DATA; sender will rts_retry if budget allows)
```

### 8.8 Failure-mode summary table

| Failure | Detection | Recovery |
|---|---|---|
| RTS lost | rts_timeout at sender | tx_rts_retry up to rts_max_retries; then K=3 cascade |
| CTS lost | rts_timeout at sender | Same as above |
| Receiver busy | NACK at sender | Wait or requeue based on busy_for |
| Receiver blind (post-CTS) | overheard CTS → blind_until | classify_blind switches to alt or defers |
| DATA lost | ack_timeout at sender | Retry from RTS; sender re-RTSes, receiver re-CTSes (rts_rx_dup path) |
| ACK lost | ack_timeout at sender + last_acked_from at receiver | Retry RTS; receiver short-circuits with CTS `already_received=1` (`rts_already_acked`) |
| Routing-table mismatch | rts_giveup after K alts | path_cascade_exhausted; flight dropped, sender app-layer aware |

---

## 9. Layer filtering (`leaf_id`)

A 4-bit layer identifier in BCN and RTS lets multiple radio/routing layers
coexist on the same channel. Config uses `layer_id`; the wire carries only
`leaf_id = layer_id & 0x0f`. Receivers reject foreign-layer frames **before
any other work**:

```
on_recv 'B':
  if b.leaf_id ~= self.leaf_id: return  (silent drop)
  ... rt_merge ...

on_recv 'R':
  if r.leaf_id ~= self.leaf_id: return  (silent drop)
  ... CTS / forwarding logic ...
```

Without this filter, two layers merging during enhanced RF
propagation events (30-40 km tropo ducting) would:

1. Attempt CTSes for foreign-layer RTSes (wasted airtime + collisions).
2. Pollute routing tables with foreign-layer nodes (decisions to route via
   non-existent neighbors → flights fail with `rts_giveup`).

`leaf_id` is **derived from config**. Prefer `config.layer_id`; legacy
`config.leaf_id` is accepted as shorthand for `layer_id` during migration.
Only the lower 4 bits are on wire, so this field is not a global
administrative mesh identifier. Administrative separation should be provided
by operator policy and cryptographic keys, not by this nibble.

CTS/DATA/ACK/NACK don't carry `leaf_id` because they're matched
against `pending_tx`/`pending_rx` state set by an already-validated
RTS — the check is implicit.

Gateway v1 extends this with an **active layer context**. A scheduled gateway
switches `active_layer_id`, `active_leaf_id`, control SF, and DATA-SF bitmap
while it listens on a secondary layer. JOIN offers, BCN, RTS, CTS, NACK and
DATA selection use the active/target layer context. When a gateway receives a
cross-layer envelope and forwards into its own primary layer, it explicitly
restores the primary context before RTS/DATA so the forwarded leg uses that
layer's control SF and DATA-SF bitmap.

Runtime route and identity state is layer-scoped. Firmware keeps
`layer_state[layer_id] = { rt, id_bind, dest_seen_ms, beacon_offset }`; the
legacy `self.rt`, `self.id_bind`, and `self.dest_seen_ms` names are active-layer
pointers swapped whenever a gateway retunes. This permits the same short
`node_id` to exist in two different layers without corrupting route selection or
identity binding. Direct route learning is applied only after a frame is known
to belong to the active leaf/layer. The `s10_two_layer_gateway_separation`
scenario exercises this by reusing short IDs across layers.

---

## 10. Origin-level dedup

End-to-end uniqueness is provided by `(origin_node_id, ctr)`:

- `origin_node_id`: 8-bit field carried inside DATA's inner payload
  (the "ciphertext" slot). Reconstructed at the destination by
  `parse_data` from `inner.src_addr`.
- `ctr`: 16-bit per-(origin, dst) counter on DATA wire bytes 4-5 (§3.4).
  Sender increments per outbound flight to that peer via
  `self:next_ctr(peer)`; wraps at 65,536 → forced re-key under §8
  (~18 years at 10 msg/day, not a practical concern).

Receiving a DATA frame:

```
on_recv 'D' (matches pending_rx):
  d = parse_data(frame)    -- yields flags, ctr, origin, body, e2e_ack_req, e2e_is_ack
  if (d.origin, d.dst, d.ctr) in seen_origins:
    if previous_hop is the same as first-seen previous_hop:
      ACK-only and emit dup_drop       -- lost-ACK recovery
    else:
      NACK LOOP_DUP and emit dup_drop  -- routing loop returned via another branch
    return  (don't deliver-twice or forward-twice)
  ACK the frame (sender clears pending_tx)
  record (d.origin, d.dst, d.ctr) in seen_origins with TTL
  if dst == self.id:
    if d.e2e_is_ack:
      handle E2E ACK arrival (see §7.4)
    else:
      emit delivered (payload = body = user_text)
      if d.e2e_ack_req: enqueue return E2E ACK (§7.4)
  else (forwarder):
    after ack_air_ms+1: enqueue forward; become_free
```

Default TTL: `seen_origin_ttl_ms = 30 s`. Catches:

- DV routing loops (same payload returned via cycle).
- Legitimate same-payload retries via different paths (originator's
  retry queued through different next-hop).

Same-previous-hop dedup acts before delivery / forwarding but still sends
ACK, so the previous hop clears its pending_tx. Different-previous-hop dedup
sends `NACK LOOP_DUP`; the upstream marks that next-hop branch tried and
cascades to another local candidate if one exists.

---

## 10a. Anti-spam — 1st-hop statistical rate-limit

Every node N tracks, per direct-radio sender X, two distinct-ctr_lo
sliding-window counts over `originator_window_ms` (default 5 min):

- `R[X]` = distinct RTS ctr_los from X.
- `C[X]` = distinct CTS ctr_los from X.

`compute_originator_metric` tallies **distinct ctr_lo over the whole
window**, so same-ctr_lo retries count once each *regardless of spacing*.
This matters because a node stuck retrying ONE message (e.g. a cross-layer
relay hammering a momentarily-busy next-hop on the second leg) must not look
like a flood of fresh originations — under a raw RTS count its retries would
push `R[X]` past threshold and the receiver would silently throttle a
legitimate relay, turning transient congestion into a sustained giveup. (The
track-side `originator_retry_dedup_ms`, default 10 s, only bounds *stored*
events; the metric dedups across the full window.) ctr_lo is 4-bit on the
wire, so distinct R caps at 16 — far above the default threshold of 6, so a
genuine spammer cycling distinct messages still trips it. Airtime
(`sender_airtime`, below) stays cumulative across retries, so the airtime
backstop still catches high-volume spam regardless of ctr_lo reuse.

```
apparent_origination[X] = max(0, R[X] - C[X])
```

A legitimate forwarder emits 1 CTS per inbound flight AND 1 RTS per
outbound forward → `R[X] ≈ C[X]` → `apparent_origination[X] ≈ 0`.
An originator emits RTS without ever responding to inbound RTS →
`C[X] ≈ 0` → `apparent_origination[X] = R[X]`.

**Enforcement.** On `on_recv 'R'` from direct sender X:

```
if apparent_origination[X] > originator_max_per_window
   OR sender_airtime[X] > originator_airtime_share × my_duty_cycle_budget:
  emit rts_drop_originator_throttle
  return  (SILENT DROP — no NACK; preserves N's own airtime budget)
```

No NACK because emitting one would consume our airtime budget on the
very condition we're trying to push back against. The spammer
experiences `rts_timeout` and cascades through alts; every 1st-hop
neighbour converges on the same rate-limit decision independently,
so the cap is effectively network-wide.

**Originator self-monitoring (UX feedback).** Since silent drop gives
no explicit signal, each originator tracks its own origination count.
On any terminal failure (`path_cascade_exhausted` or `rts_giveup`):

```
if own_origination_count > originator_self_warn_fraction × originator_max_per_window
   OR my_duty_cycle_tier >= STRAINED:
  emit originator_self_over_budget (UX hint: "your send may have failed
    because you're over fair-share budget")
```

**Why 1st-hop only.** A deeper forwarder sees aggregated traffic from
many origins and would over-trigger on the heaviest-loaded forwarders
(which are doing the right thing). The 1st-hop invariant says: a node
N can attribute X's traffic to X **only when N hears a frame directly
from X's radio with `sender == X == origin`**. Forwarded frames (where
on-wire sender ≠ origin) are skipped — N has no way to distinguish
legitimate forwarding from origin-fingerprint there.

**Gateway cross-layer exemption.** The `R[X] ≈ C[X]` balance assumes a
forwarder both receives (CTS out) and forwards (RTS out) *on the same
layer*. A gateway breaks this: it receives the envelope on the origin's
layer but re-injects on the *target* layer with `origin=self` and no
preceding CTS there, so on the target layer it looks like a pure originator
(`C ≈ 0`, `R` climbs with every distinct cross-layer message it relays) and
gets throttled — silently dropping legitimate cross-layer traffic. To fix
this, the gateway marks its forward RTS with `RTS_FLAG_RELAY` (§3.2); the
addressed next-hop neither records it in the §10a ledger nor throttles it,
and emits `rts_relay_exempt` for observability. The flag is set *only* by
`enqueue_gateway_handoff`, so a gateway's own-originated traffic (no flag)
is still throttled normally. This is the gateway analogue of the
forwarded-frame skip above: a relay role, not an origination.

**Privacy-compatible.** The classifier observes physical-layer
`meta.src`, not the wire `origin` field. Composes with §9 T2
(origin-in-encrypted-payload) without changes.

**Measured impact** (s04 60-min, 360 sends, 16 active originators):
delivery unchanged at ~52%; 141 silent drops total (down from 3505 in
a pre-dedup measurement — the ctr_lo dedup cut false positives by
96%); 94 self-over-budget emits caught legitimate "over fair-share
but not necessarily malicious" senders.

**Configuration knobs** — `originator_max_per_window` is the only
tunable in §14.1. Window/airtime-share/retry-dedup/self-warn are
PROTOCOL constants (§14.5).

**Cross-references.** §9 (privacy-compatible variant from the start),
§11.5 (budget tiers — feed into self-monitoring threshold), §7.4 (E2E
ACK counts toward destination's own quota — by design, a heavy
responder can't avoid its own cap).

---

## 11. Half-duplex, LBT, duty cycle

Three independent gates on TX:

### 11.1 Half-duplex (runtime + script)

The radio physically can't TX while RX is in progress (and vice versa).
Enforced by:

- Runtime: `notifyChannelBusy` / `tx_in_flight` slot. Any TX attempt
  while we're already mid-TX or mid-RX returns `on_radio_busy`
  reason="self_tx_in_flight" or "channel_busy".
- Script: `pending_tx ~= nil` blocks new sends; `pending_rx ~= nil`
  blocks new acceptances.

### 11.2 LBT (Listen-Before-Talk) via CAD

Models SX1262 CAD (Channel Activity Detection). When TX is about to
fire, the runtime samples the channel:

- `cad_miss_prob` (default 0.05): probability CAD misses a busy
  channel. Real hardware: 1-3%.
- `cad_reliable_snr` / `cad_marginal_snr`: linear interpolation of
  detection probability between these SNR thresholds.

Script-side `tx_initiating` / `tx_flood` pre-check
`self:channel_busy_until()` and defer if busy. Initiating-directed
frames wait until the observed busy window ends, then add a small
random LBT backoff. This avoids the round-trip of TX → runtime defers
→ on_radio_busy → re-tx.

### 11.3 PreambleDetected → throttle witness

Maps to SX1262's PreambleDetected IRQ. Fires when a TX would start
arriving at the receiver tuned to a matching SF AND the CAD
probability model decides the radio would have detected the preamble.
Independent of decode outcome — fires even on signals too weak to
fully decode, which is exactly when the throttle witness needs them.

```
on_preamble_detected(self, info):
  self.last_rx_routing_sf_ms = info.time_ms
```

This is the fix for the throttle's decode-failure cascade — see
commit history `94e949a`.

### 11.4 Duty cycle (regulatory)

Real LoRa is regulated at 1% duty cycle in EU 868 MHz (ETSI EN 300
220). Per-node `duty_cycle` × `duty_cycle_window_ms` defines the
budget.

```
check_duty_cycle(self, this_airtime_ms):
  used = self:airtime_used_ms(window_ms)
  if used + this_airtime_ms ≤ budget:
    return ok
  else:
    wait_ms = computed earliest moment a fresh TX could fit
    return not-ok, wait_ms
```

Script pre-checks via `tx_with_retry` / `tx_flood`. Runtime
hard-blocks via `on_radio_busy(reason="duty_cycle_exceeded")` as
safety net.

When over budget:
- RESPONSE-class (CTS/DATA/ACK): self:after to wait, then retry.
- INITIATING-class (RTS): defer + emit `duty_cycle_blocked`.
- FLOOD-class (BCN): drop the page; next periodic fire retries.

### 11.5 Duty-cycle budget tiers (advisory)

The hard-block above (over-budget at TX time) is reactive — it only
fires once we've already burned the budget. The **budget-tier
system** provides a forward-looking advisory: rather than waiting
until we're at 100%, the protocol classifies remaining budget into
4 tiers and reacts proactively at each.

```
compute_budget_tier(self):
  pct_used = 100 × airtime_used_ms(window) / duty_cycle_budget_ms
  if pct_used >= budget_exhausted_pct (default 95): return EXHAUSTED (3)
  if pct_used >= budget_critical_pct  (default 80): return CRITICAL  (2)
  if pct_used >= budget_strained_pct  (default 50): return STRAINED  (1)
  return HEALTHY (0)
```

| Tier | Pct used | Behaviour |
|---|---|---|
| **HEALTHY** (0) | ≤ 50% | Normal operation |
| **STRAINED** (1) | 50-80% | (currently informational only — emitted in `node_state_snapshot`) |
| **CRITICAL** (2) | 80-95% | Refuse forwards via budget-NACK; skip own beacons |
| **EXHAUSTED** (3) | > 95% | `duty_cycle_blocked` is imminent — same as CRITICAL |

The tier is consulted at three sites:

1. **At `on_recv 'R'`** (forwarder admission). If our tier ≥ CRITICAL,
   we likely can't carry this flight to completion (CTS + DATA-RX
   has no cost but ACK does, and we'd consume more budget on
   subsequent forwards if we accept). Reply with a **budget-NACK**
   (§3.6, `reason=BUDGET`) so the sender immediately reroutes via
   the existing `classify_blind` machinery instead of doing a full
   RTS-CTS-DATA-ACK cycle that stalls when we get
   `duty_cycle_blocked` partway through. Wire cost: a few ms NACK
   airtime; saves the much larger CTS+ACK round-trip.

2. **At `beacon_fire`** (own emission). If our tier ≥ CRITICAL, skip
   the beacon — preserve remaining budget for forwards already in our
   queue. Emit `beacon_skipped_budget` for telemetry.

3. **At `on_recv 'N'` (sender side, budget reason).** When we
   receive a budget-NACK from a peer, mark that peer **blind** for a
   tier-proportional window (`budget_blind_strained_ms`,
   `budget_blind_critical_ms`, `budget_blind_exhausted_ms`). The
   existing `classify_blind` machinery then naturally reroutes via
   alts. After the blind window expires we'll try the peer again; if
   they're still saturated they'll budget-NACK us again.

4. **At route selection.** The same budget-NACK also records a temporary
   neighbour tier. While that mark is live, candidates through that
   neighbour receive an effective-score penalty during route ordering.
   This is a local overlay; it does not overwrite the raw route score.

| Key | Default | Description |
|---|---|---|
| `budget_strained_pct` | 50 | ≤ this → HEALTHY; > this → STRAINED |
| `budget_critical_pct` | 80 | > this → CRITICAL (NACK + beacon-skip kick in) |
| `budget_exhausted_pct` | 95 | > this → EXHAUSTED |
| `budget_blind_strained_ms` | 60000 (1 min) | Sender-side blind window for STRAINED-NACKed peer |
| `budget_blind_critical_ms` | 180000 (3 min) | Same, for CRITICAL |
| `budget_blind_exhausted_ms` | 300000 (5 min) | Same, for EXHAUSTED |
| `neighbor_budget_tier_ttl_ms` | 300000 (5 min) | Temporary route-order penalty window after budget-NACK |

### 11.6 Periodic node state snapshot

For accumulator diagnostics (analyze.py + visualize), each node
periodically emits a `node_state_snapshot` event capturing
quasi-static counters: tx_queue depth, deferred_sends depth,
in-flight pending counts, current budget tier, current rt size,
the node's layer/leaf identity, gateway flags, plus throughput
counters since last snapshot.

At startup each node also emits one `node_layer_info` event. This is
intended for debug tooling and visualization: it records `node_id`,
`name`, `layer_id`, `leaf_id`, `key_hash32`, `is_gateway`,
`gateway_layers`, `is_mobile`, `joined`, `routing_sf`, and the encoded
allowed DATA-SF bitmap. The event is not a wire packet; it is simulator
telemetry only.

```
state_snapshot_period_ms (default 60000 = 1 min)
  → emit node_state_snapshot { ... } and reschedule
```

Set `state_snapshot_period_ms = 0` to disable.

Focused routing debug can be enabled per node with:

```text
debug_start / debug_end        -- ms window, aliases: debug_start_ms/debug_end_ms
```

In scenario JSON these are normally set once in the top-level `config` object,
which the runtime merges into every node's Lua config before node-specific
overrides. A node may still override the global window in its own
`nodes[i].config`.

If no debug window is configured, existing diagnostic telemetry keeps its
normal behavior. If either `debug_start` or `debug_end` is configured, noisy
diagnostic emits are suppressed outside the window. This gate applies to
`node_state_snapshot`, `rt_quality_snapshot`, `rts_attempt_detail`,
`route_decision_detail`, and `rt_debug_snapshot`. Core protocol events
(`rts_tx`, `cts_rx`, `data_tx`, `ack_rx`, `route_decision`, etc.) remain
always-on so the analyzer can still reconstruct normal traffic.

Inside the window, route-table mutations emit `rt_debug_snapshot` for the
affected destination only. This is event-driven, not periodic: it fires on new
route install, primary promotion, primary refresh, alternate install, 3-cycle
prune, or route aging. The payload contains the full candidate list for that
destination, including next hop, second hop, hops, raw/effective score,
age/TTL, gateway flag, budget tier, blind state, and suspect level.

---

## 11a. Bootstrap UX (cold-start joiners)

The "new user installs the app, opens it, immediately taps send" case
needs explicit handling — without it, the user sees a silent drop and
abandons the app. Two mechanisms:

For firmware-mode scenarios where `config.join_required=true`, the node first
runs short-address join. It starts with temporary protocol id `255`, listens,
sends `J_DISCOVER`, adopts DATA SF policy from `J_OFFER`, sends `J_CLAIM`, and
only after `join_adopted` participates as a normal node. While unjoined it does
not emit normal DV beacons.

Current focused test: `test/t48_join_autonomous_fourth_node.json` has three
pinned nodes and a fourth `node_id:null` joiner. The expected path is
`J_DISCOVER -> J_OFFER -> J_CLAIM -> join_adopted`.

### 11a.1 Node-local discovery

In `on_init`:

```
discovery_mode = true
discovery_until_ms = now + discovery_ms
schedule first beacon at rand(0, discovery_beacon_period_ms)

while discovery_mode:
  emit fast/full BCNs
  exit discovery when:
    - enough BCN traffic has been heard, or
    - enough routes are installed, or
    - discovery_until_ms expires

after discovery:
  emit normal dirty-only BCNs plus seen bitmap
```

This is firmware state, not simulator state. `warmup_ms` may still be
used by the orchestrator to create collision-free test windows, but Lua
protocol decisions must not depend on it.

### 11a.2 Defer queue for originator sends

`issue_send` for an originator (`previous_hop == nil`) with no `rt[dst]`:
instead of dropping with `send_no_route`, push onto `self.deferred_sends`
with timestamp + emit `send_deferred`. The application sees:

```
t = T          send_deferred  → UI: "Connecting to mesh..."
t = T+Δ        send_drained   → UI: "Sending..." (route appeared)
                              OR
t = T+TTL      send_giveup    → UI: "Couldn't reach destination"
```

Drain happens at:
- `on_recv 'B'` after rt mutations (fastest, ~hundreds of ms after boot)
- A periodic 1 s timer (fallback when no routing traffic flows)

If the deferred send was waiting on an active `'F'` RREQ flood (§3.7b),
draining does not immediately RTS. The send is moved to `tx_queue` with
`next_attempt_ms = now + settle`, where settle lasts until
`q_sent_at_ms + q_response_settle_ms` plus small jitter. This lets the RREP
(or any reverse-path control traffic the flood stirred up) finish before the
first DATA RTS, avoiding the hidden-terminal pattern where a requester
installs the forward route, immediately RTSes, and collides at the chosen
next-hop with a late frame from another responder.

Forwarders (`previous_hop ~= nil`) never defer — a route gone
mid-flight is a real failure; the originator's app-layer retry is the
recovery path. They keep the legacy `send_no_route` emit.

### 11a.3 Bootstrap timeline (measured on t27)

5-node line `a-b-c-d-e`, eve boots at t=20000:

```
t = 20000 ms   eve.on_init runs
                enters DISCOVERY
                schedules first beacon at rand(0, discovery_beacon_period_ms)
                schedules periodic drain at t+1000ms

t = 20100 ms   eve issues "send alice hello"
                rt[alice] missing → emit send_deferred (depth=1)

t = 20100..    eve fires first beacon (n=0, empty rt)
t = 20150       → dave receives, installs rt[eve], schedules
                  triggered beacon

t = 20200..    dave fires triggered beacon with full table
t = 20300       → eve receives, installs rt for everything
                  dave knew (alice, bob, carol)

t = 20388 ms   eve's on_recv 'B' calls try_drain_deferred
                rt[alice] now exists → emit send_drained (waited=288ms)
                push back to tx_queue → become_free → issue_send
                pack RTS → tx → handshake with dave...

t = 24510 ms   alice emits delivered (4-hop chain a←b←c←d←e)
```

Net: from "user taps send" to "delivered" = ~4.4 s, with 288 ms of that
being the bootstrap wait. The user sees `send_deferred` immediately
(UI shows "connecting"), `send_drained` at 288 ms (UI shows "sending"),
`delivered` at 4.4 s (UI confirms).

### 11a.4 Configuration

| Key | Default | Description |
|---|---|---|
| `send_defer_ttl_ms` | 30000 | How long deferred originator sends are held before `send_giveup` fires |

No new wire format. No additional state at neighbours. Pure script-side
addition that uses existing primitives.

---

## 12. Lifecycle: on_init + on_recv + on_radio_busy

### 12.1 on_init

```
on_init(self, config):
  parse all config fields with defaults
  build name↔id maps from sim:nodes()
  compute peer_count = #nodes - 1
  initialize all per-node state (rt, snr_ewma_in/out, blind_until,
                                 last_acked_from, seen_origins, ...)
  enter DISCOVERY
  schedule first beacon at rand(0, discovery_beacon_period_ms)
```

Per-node state populated:

| Field | Type | Purpose |
|---|---|---|
| `rt` | table | Routing table (dest → candidates list) |
| `pending_tx` / `pending_rx` | table or nil | In-flight unicast state |
| `tx_queue` | array | Queued sends, drained by become_free |
| `tx_stash` | table | label → frame for on_radio_busy retry |
| `blind_until` | table | nbr → absolute_ms (F1 mitigation) |
| `last_acked_from` | table | (sender, dst, ctr_lo, payload_len) → {t_ms, chosen_data_sf} (RTS dedup) |
| `seen_origins` | table | (origin, dst, ctr) → t_ms (end-to-end dedup) |
| `peer_send_counter` | table | peer_id → outbound 16-bit ctr (per-(self,peer)) |
| `peer_last_seen_ctr` | table | peer_id → highest inbound ctr seen (replay window) |
| `pending_e2e` | table | (dst, ctr) → {sent_at, dst, ctr, text} (E2E ACK pending state) |
| `snr_ewma_in` / `snr_ewma_out` | table | nbr → SNR estimate |
| `last_rx_routing_sf_ms` | int | Beacon throttle witness |
| `layer_id` | int | Logical layer id from config |
| `leaf_id` | int | 4-bit active layer nibble (`layer_id & 0x0f`) |
| `next_ctr_lo` | int | 4-bit per-flight counter |

### 12.2 on_recv

The dispatcher. Tag-byte switch into per-tag handlers.

```
on_recv(self, frame, meta):
  if #frame == 0: return
  self.last_rx_routing_sf_ms = self:now()  -- throttle witness update
  if meta.src and meta.snr:
    update_snr_ewma(self.snr_ewma_in, meta.src, meta.snr)
  tag = frame[0]
  if tag == 'B': handle_beacon
  elif tag == 'R': handle_rts
  elif tag == 'C': handle_cts
  elif tag == 'D': handle_data
  elif tag == 'K': handle_ack
  elif tag == 'N': handle_nack
```

### 12.3 on_radio_busy

Runtime fires this when LBT/half-duplex defers a TX:

```
on_radio_busy(self, info):
  emit "radio_busy"
  stash = self.tx_stash[info.label]
  if not stash or stash.retries_left == 0:
    emit tx_giveup; return
  stash.retries_left -= 1
  delay = info.busy_until_ms - now
  after delay: self:tx(stash.bytes, stash.opts)
```

Only RESPONSE-class labels (CTS, CTS-dup, DATA, ACK, K-dup, NACK)
are eligible for retry. BCN and RTS-class have their own retry
mechanisms (next periodic fire / rts_timeout) and don't need
on_radio_busy retries on top.

### 12.4 on_preamble_detected

Runtime IRQ fires when a TX would start arriving at our radio at
our current SF AND CAD detects the preamble:

```
on_preamble_detected(self, info):
  self.last_rx_routing_sf_ms = info.time_ms
```

Faithful to SX1262 PreambleDetected IRQ — fires regardless of
sync-word match or decode success.

---

## 13. Event vocabulary

44 distinct event types, grouped by purpose. Every emit takes a
`data` table; consumers (analyze.py, visualize.html, test
expectations) subscribe by event_type.

### 13.1 Beacon plane

| Event | Trigger | Key data |
|---|---|---|
| `beacon_tx` | Emitted right before sending a beacon page | `n_entries`, `rt_total`, `offset`, `next_offset`, `kind`, `seen_bits`, `suspect_nodes`, `ext_len`, `dirty_only` |
| `beacon_rx` | Beacon decoded | `src`, `key_hash32`, `n_entries`, `seen_bits`, `suspect_nodes` |
| `seen_bitmap_tx` / `seen_bitmap_rx` | Destination-seen bitmap emitted/decoded | `bits_set`, `ttl_ms` / `from`, `bits_set`, `applied`, `refreshed` |
| `peer_suspect_mark` | RTS silence or BCN suspect TLV applied a temporary peer penalty | `node`, `level`, `previous_level`, `source`, `remote_src`, `rts_timeouts`, `reranked` |
| `peer_suspect_clear` | A valid frame from a suspected peer cleared local suspicion | `node`, `source`, `reranked` |
| `peer_suspect_bcn_rx` | BCN suspect-node TLV decoded | `from`, `count`, `applied`, `self_marked` |
| `peer_liveness_bcn_rx` | BCN explicit liveness-state TLV decoded | `from`, `count`, `applied`, `dead`, `self_marked` |
| `peer_suspect_self_heard` | This node heard another peer list it as suspect | `from`, `budget_tier` |
| `tx_silent_alt` | Silent next-hop skipped in favor of another candidate | `origin`, `dst`, `from_next`, `to_next`, `source` |
| `tx_silent_defer` | All usable candidates were silent; packet deferred and Q requested | `origin`, `dst`, `next`, `source` |
| `rt_skip_stale_next` | Route candidate skipped because immediate next-hop was not directly heard within `next_hop_live_ttl_ms` | `dest`, `next`, `age_ms`, `ttl_ms`, `source` |
| `tx_stale_next_alt` | Stale immediate next-hop skipped in favor of another candidate | `origin`, `dst`, `from_next`, `to_next`, `source` |
| `tx_stale_next_defer` | All usable candidates had stale immediate next-hops; packet deferred and Q requested | `origin`, `dst`, `next`, `source` |
| `rt_skip_silent_n2` | BCN/DV route proposal skipped because its advertised next hop is locally silent | `dest`, `via`, `advertised_next`, `suspect_level` |
| `beacon_skipped_busy` | Throttle suppressed beacon | `since_rx_ms`, `threshold_ms`, `stage` |
| `beacon_diff_breakdown` | Per-beacon dirty/stable split (§6.4) | `dirty_n`, `stable_n`, `total_dirty`, `rt_total`, `kind`, `n_entries`, `seen_bits`, `suspect_nodes`, `ext_len`, `dirty_only` |
| `beacon_max_idle_force` | Max-idle override bypassed busy throttle (§6.2) | `since_tx_ms`, `max_idle_ms`, `since_rx_ms` |
| `beacon_max_idle_skip_clean` | B+C composite skipped override (no dirty + recent neighbour BCN) (§6.2) | `dirty_n`, `since_bcn_rx_ms`, `max_idle_ms` |
| `beacon_skipped_budget` | Beacon skipped because budget tier ≥ CRITICAL (§11.5) | `tier`, `pct_used` |
| `rt_update` | Route added/promoted to a slot | `dest`, `next`, `score`, `hops`, `slot` |
| `rt_penalty_rerank` | Temporary neighbour-health penalty changed candidate order | `dest`, `from_next`, `to_next`, `penalized`, `reason` |
| `neighbor_budget_mark` | Budget hint/NACK updated temporary neighbour tier | `node`, `tier`, `source`, `local_only`, `reranked`, `candidate_entries`, `primary_entries`, `primary_no_alt`, `primary_with_alt`, `primary_still_primary`, `primary_demoted`, `nonprimary_entries` |
| `rt_prune` | 3-cycle prune dropped a candidate | `dest`, `pruned_via` |
| `rt_aged` | Stale-route aging evicted a candidate (§6.5) | `dest`, `slot`, `next_hop`, `hops`, `age_ms`, `ttl_ms` |
| `rt_full` | Routing table covers all peers | `peers` |

### 13.2 Data plane — handshake

| Event | Trigger | Key data |
|---|---|---|
| `tx_enqueue` | New send queued | `origin`, `dst`, `payload` |
| `tx_dequeue` | Queued send picked up | `origin`, `dst` |
| `tx_requeued` | NACK with long busy_for; pending_tx pushed back | `origin`, `dst`, `busy_for_ms` |
| `send_no_route` | Forwarder has no rt[dst] mid-flight (route went stale) | `origin`, `dst` |
| `send_deferred` | Originator has no rt[dst] yet — held in defer queue | `origin`, `dst`, `dst_name`, `ttl_ms`, `depth` |
| `send_drained` | Deferred send drained back to tx_queue (route appeared) | `origin`, `dst`, `waited_ms`, `settle_ms`, `next_attempt_ms` |
| `send_giveup` | Defer TTL elapsed without route appearing | `origin`, `dst`, `waited_ms`, `reason` |
| `rts_tx` | RTS emitted | `attempt_seq`, `origin`, `dst`, `next`, `ctr_lo`, `sf_bitmap` |
| `rts_retry` | tx_rts_retry fired | `attempt_seq`, `reason`, `attempt` |
| `rts_attempt_detail` | Sender-side focused RTS attempt telemetry; debug-window gated when configured | `attempt_seq`, `origin`, `dst`, `next`, `ctr_lo`, `candidate_rank`, `candidate_count`, `route_score`, `route_score_eff`, `budget_penalty_db`, `suspect_penalty_db`, `viable_alts`, `route_hops`, `route_age_ms`, `next_tier`, `next_suspect_level`, `next_seen_fresh`, `next_seen_age_ms`, `next_blind` |
| `rts_attempt_timeout` | Sender-side RTS attempt reached CTS timeout | `attempt_seq`, `origin`, `dst`, `next`, `ctr_lo`, `reason` |
| `rts_tx_blocked` | Runtime LBT/half-duplex blocked an RTS-class TX after the sender entered pending state; CTS for this attempt is ignored until retry | `attempt_seq`, `origin`, `dst`, `next`, `ctr`, `ctr_lo`, `payload`, `label`, `reason`, `busy_until_ms` |
| `rts_receiver_state` | Intended receiver state immediately after RTS decode | `from`, `dst`, `ctr_lo`, `rx_snr`, `ewma_snr`, `has_pending_tx`, `has_pending_rx`, `budget_tier` |
| `rts_rx` | RTS decoded, addressed to us | `from`, `dst`, `ctr_lo`, `chosen_data_sf`, `rx_snr`, `ewma_snr` |
| `rts_rx_dup` | Duplicate RTS while pending_rx active | `from`, `dst`, `ctr_lo`, `payload_len` |
| `rts_already_acked` | Cached ACK short-circuit; receiver sends CTS `already_received=1` | `from`, `dst`, `ctr_lo`, `payload_len` |
| `rts_drop_no_sf` | RTS bitmap intersection empty | `from`, `ctr_lo`, `sf_bitmap` |
| `rts_drop_pending_tx` | Silent-drop RTS while we're busy as sender (§8.1) | `from`, `ctr_lo` |
| `cts_tx` | CTS emitted | `to`, `ctr_lo`, `chosen_data_sf`, `already_received` when set |
| `cts_rx` | CTS decoded, matches pending_tx | `from`, `ctr_lo`, `chosen_data_sf`, `already_received` |
| `cts_drop_no_active_rts` | CTS had matching `ctr_lo`, but this node's RTS attempt was blocked before it reached the radio | `from`, `ctr_lo`, `origin`, `dst`, `next`, `payload`, `attempt_seq` |
| `cts_drop_unexpected_src` | CTS had matching `ctr_lo` but came from a node other than selected next-hop | `expected`, `from`, `ctr_lo`, `origin`, `dst` |
| `cts_already_received_rx` | CTS says receiver already decoded this DATA from an earlier try; sender completes hop without DATA retransmit | `from`, `ctr_lo`, `chosen_data_sf`, `origin`, `dst`, `ctr` |
| `cts_invalid_sf` | Receiver picked an SF outside our bitmap | `from`, `ctr_lo`, `chosen_data_sf` |
| `data_tx` | DATA emitted | `dst`, `next`, `ctr_lo`, `payload` |
| `data_tx_blocked` | Runtime LBT/half-duplex blocked a DATA TX after CTS; ACK for this attempt is ignored until DATA is handed to the radio | `attempt_seq`, `origin`, `dst`, `next`, `ctr`, `ctr_lo`, `payload`, `label`, `reason`, `busy_until_ms` |
| `data_rx` | DATA decoded, matches pending_rx | `from`, `ctr_lo`, `len` |
| `data_rx_timeout` | pending_rx_expiry fired | `from`, `ctr_lo` |
| `ack_tx` | ACK emitted | `to`, `ctr_lo`, `data_snr`, `budget_tier`, `budget_hint` |
| `ack_rx` | ACK decoded, matches pending_tx | `from`, `ctr_lo`, `data_snr_db`, `snr_bucket_coarse`, `budget_hint`, `budget_reranked` |
| `implicit_ack_from_forward` | Sender overheard its selected next-hop forwarding the same DATA, so the hop is complete despite a lost ACK | `from`, `next`, `forward_next`, `origin`, `dst`, `ctr`, `ctr_lo`, `payload`, `attempt_seq` |
| `ack_drop_no_active_data` | ACK had matching `ctr_lo`, but this node's DATA attempt was blocked before it reached the radio | `from`, `ctr_lo`, `origin`, `dst`, `next`, `payload`, `attempt_seq` |
| `ack_drop_unexpected_src` | ACK had matching `ctr_lo` but came from a node other than selected next-hop | `expected`, `from`, `ctr_lo`, `origin`, `dst` |
| `ack_snr_feedback` | snr_ewma_out updated from ACK piggyback | `from`, `data_snr_db`, `snr_bucket`, `snr_bucket_coarse`, `ewma_out` |
| `rts_tx_cancelled_stale` | LBT-deferred RTS retry was about to fire, but its original `pending_tx` was already completed/replaced | `label`, `reason` |
| `nack_tx` | NACK emitted | `to`, `ctr_lo`, `reason` (`busy_rx` or `budget_low`), plus per-reason: `busy_for_ms` OR `tier` |
| `nack_rx` | NACK decoded, matches pending_tx | `from`, `ctr_lo`, `reason`, plus per-reason: `busy_for_ms` OR `tier`, `blind_ms` |
| `nack_drop_unexpected_src` | NACK had matching `ctr_lo` but came from a node other than selected next-hop | `expected`, `from`, `ctr_lo`, `origin`, `dst`, `reason` |
| `delivered` | DATA arrived at end-to-end destination | `origin`, `payload`, `ctr` |
| `dup_drop` | Duplicate `(origin, dst, ctr)` | `origin`, `dst`, `ctr` |
| `forward_queued` | Forwarder enqueued the relay | `origin`, `dst` |
| `q_tx` | Q control query emitted by sender — REQ_SYNC / CHANNEL_PULL (§3.7) | `opcode`, `dst`, `reason` |
| `q_rx` | Q decoded; receiver matches leaf_id | `from`, `dest`, `opcode` |
| `r_tx` | `'F'` RREQ route-Find flood originated (§3.7b) | `dst`, `dst_name`, `ttl`, `reason` |
| `rreq_rx` / `rreq_forward` | `'F'` RREQ received / re-flooded (reverse path laid) | `origin`, `dst`, `ttl`, `hops` |
| `rreq_resolved_self` / `rreq_resolved_cached` | RREQ reached the dst itself / an intermediate node holding `rt[dst]`; an RREP is generated | `origin`, (`dst`, `hops` for cached) |
| `rrep_tx` / `rrep_rx` | `'F'` RREP sent toward origin / received by the addressed next-hop (forward path laid). `defer_ms` = schedule-defer + jitter applied before tx | `origin`, `dst`, `next`, `hops`, `defer_ms` |
| `rrep_gateway_schedule_defer` | RREP held for an away next-hop gateway's presence window before tx (§3.7b) | `origin`, `dst`, `next_hop`, `sched_ms` |
| `rrep_arrived` | RREP reached origin; forward route to `dst` installed, deferred send drains | `dst`, `hops` |
| `rrep_drop_no_reverse` | RREP could not start/continue — no reverse route to origin | `origin`, `dst` |
| `route_request_suppressed` | `'F'` RREQ origination rate-limited (recent same-or-lower-TTL flood for this dst) | `dst`, `dst_name`, `reason`, `last_r_ms` |
| `send_defer_requery_offlayer` | Deferred-send requery withheld: node is not on the dst's layer (`tx_layer_id`), so the RREQ would flood the wrong layer (§3.7b) | `origin`, `dst`, `dst_name`, `ctr`, `tx_layer_id`, `active_layer` |
| `forward_fail` | Forwarder dropped (no route, no budget, etc.) | `origin`, `dst`, `reason` |
| `retune_for_data` | RX retuned for DATA reception | `from`, `ctr_lo`, `chosen_data_sf` |
| `e2e_ack_pending` | Originator registered a `send_e2e` and is waiting for E2E ACK (§7.4) | `dst`, `ctr`, `ttl_ms` |
| `e2e_ack_tx_enqueued` | Destination enqueued the return E2E ACK frame (§7.4) | `to`, `acked_ctr` |
| `delivered_confirmed` | Originator received the E2E ACK matching a pending send (§7.4) | `dst`, `acked_ctr`, `rtt_ms` |
| `e2e_ack_unmatched` | E2E ACK arrived but no matching `pending_e2e` entry (§7.4) | `from`, `acked_ctr`, `reason` (`duplicate` / `already_timed_out`) |
| `e2e_ack_timeout` | Pending E2E ACK exceeded `e2e_ack_ttl_ms` (§7.4) | `dst`, `ctr`, `waited_ms` |

### 13.3 Join plane

| Event | Trigger | Key data |
|---|---|---|
| `join_listen_start` / `join_listen_end` | `join_required` node starts/ends passive listen | `key_hash32`, `listen_ms`, `known_bindings` |
| `join_discover_sent` / `join_discover_received` | `J_DISCOVER` emitted/decoded | `key_hash32`, `from`, `requester_mobile`, `gateway_capable`, `reason` |
| `join_discover_retry_scheduled` | No `J_OFFER` arrived before the discover wait timer | `key_hash32`, `attempts`, `backoff_ms` |
| `join_discover_exhausted` | Optional max discover attempt cap reached | `key_hash32`, `attempts`, `wait_ms` |
| `join_offer_sent` / `join_offer_received` | Joined neighbour answers discovery with DATA SF policy | `responder_node_id`, `responder_key_hash32`, `data_sf_bitmap`, `to`, `from`, `delay_ms` |
| `join_data_sfs_adopted` | Unjoined node adopts its first valid DATA SF bitmap from offer | `from`, `data_sf_bitmap`, `count` |
| `join_data_sfs_offer_ignored` | Unjoined node ignored a later non-zero DATA SF offer because a previous offer already locked the policy | `from`, `data_sf_bitmap`, `adopted_data_sf_bitmap`, `reason` |
| `join_j_rate_limited` | Observer dropped an excessive untrusted joiner J frame in the per-key/opcode sliding window | `from`, `key_hash32`, `opcode`, `count`, `window_ms`, `max_per_window` |
| `join_claim_sent` / `join_claim_received` | `J_CLAIM` emitted/decoded | `proposed_node_id`, `key_hash32`, `lease_age_seconds`, `claim_epoch`, `nonce` |
| `join_deny_sent` / `join_deny_received` | `J_DENY` emitted/decoded | `denied_node_id`, `owner_key_hash32`, `claimant_key_hash32`, `reason` |
| `join_claim_denied` | Joiner received DENY for its pending claim | `denied_node_id`, `owner_key_hash32`, `reason` |
| `join_adopted` | Claim guard elapsed without denial; node adopted short ID | `node`, `key_hash32`, `claim_epoch`, `nonce` |
| `join_prefer_previous_id` | Joiner found an unexpired local binding for its own key and claims that ID first | `node`, `key_hash32` |
| `id_bind_set` | New local id-to-key binding created | `node`, `key_hash32`, `source`, `confidence` |
| `id_bind_aged` | Identity binding expired and the short ID became recyclable | `node`, `key_hash32`, `age_ms`, `ttl_ms`, `source`, `confidence` |
| `id_bind_reused` | Join candidate picker selected an ID whose expired binding was just recycled | `node`, `key_hash32` |
| `addr_conflict_observed` | Existing binding saw different key hash for same short id | `node`, `known_key_hash32`, `observed_key_hash32`, `source` |
| `addr_conflict_defense` | Adopted owner of `node` observed a competing key claiming the same id and emitted a defensive J_DENY (reason=OWN_ID_DEFENSE) carrying its own lease_age + claim_epoch | `node`, `own_key_hash32`, `claimant_key_hash32`, `own_lease_age_seconds`, `own_claim_epoch`, `source` |
| `addr_conflict_tie_break` | Adopted node received a J_DENY targeting its own id and ran the lease/epoch/key tie-break against the sender's claim | `node`, `i_win`, `my_lease_age_seconds`, `my_claim_epoch`, `my_key_hash32`, `their_lease_age_seconds`, `their_claim_epoch`, `their_key_hash32` |
| `addr_conflict_forced_rejoin` | Adopted node lost the tie-break: yielded its id, added the contested id to denied_ids, switched to unjoined, and re-entered the join state machine | `prior_node_id`, `reason`, `observed_owner_key_hash32`, `observed_owner_lease_age_seconds`, `observed_owner_claim_epoch` |

### 13.4 Failure / cascade

| Event | Trigger | Key data |
|---|---|---|
| `rts_giveup` | RTS exhausted retries | `origin`, `dst`, `ctr_lo`, `last_next_hop` |
| `data_ack_giveup` | ACK timeout exhausted | `origin`, `dst`, `ctr_lo` |
| `path_cascade` | Switching to next alt after K=3 cascade fired | `from_next`, `to_next`, `attempt`, `trigger` |
| `path_cascade_exhausted` | All K alts tried AND requeue caps hit (§5.6) | `dst`, `tried`, `trigger` |
| `cascade_requeue` | All K alts tried; pushed back to tx_queue with backoff (§5.6) | `dst`, `ctr_lo`, `requeue_count`, `backoff_ms`, `total_age_ms`, `trigger` |
| `cascade_load_skip` | Cascade-requeue dropped early due to local load (§5.6 Phase D3) | `dst`, `ctr_lo`, `queue_depth`, `load_threshold`, `effective_max` |

### 13.5 F1 blind-window mitigation

| Event | Trigger | Key data |
|---|---|---|
| `blind_observed` | CTS overheard, blind_until extended | `for_node`, `until_ms`, `chosen_data_sf` |
| `tx_blind_defer` | Deferring TX because next-hop is blind | `dst`, `next_hop`, `delay_ms`, `source` |
| `tx_blind_alt` | Switching to alt because primary is blind | `dst`, `from_next`, `to_next` |

### 13.5a Anti-spam (1st-hop rate-limit, §10a)

| Event | Trigger | Key data |
|---|---|---|
| `rts_drop_originator_throttle` | RTS silently dropped because direct sender exceeded fair-share quota | `from`, `ctr_lo`, `apparent_origination`, `airtime_share` |
| `rts_relay_exempt` | RTS carried `RTS_FLAG_RELAY` (gateway cross-layer forward, §3.2); skipped the §10a originator metric/throttle instead of counting it | `from`, `ctr_lo` |
| `originator_self_over_budget` | On terminal failure, originator's own send count is over half-threshold OR own duty tier ≥ STRAINED — UX hint emitted | `origin_count`, `threshold`, `tier`, `hint` |

### 13.6 LBT / duty cycle / runtime

| Event | Trigger | Key data |
|---|---|---|
| `tx_lbt_defer` | tx_initiating / tx_flood deferred for LBT | `label`, `defer_ms`, `busy_until_ms` |
| `tx_flood_skipped` | Flood dropped past max-defer | `label`, `busy_for_ms` |
| `duty_cycle_blocked` | Pre-check denied a TX | `label`, `airtime_ms`, `used_ms`, `wait_ms` |
| `radio_busy` | Runtime fired on_radio_busy | `reason`, `label`, `busy_until_ms` |
| `tx_giveup` | tx_stash retries exhausted | `label`, `reason` |
| `node_layer_info` | Startup layer/gateway identity marker (§11.6) | `node_id`, `name`, `layer_id`, `leaf_id`, `key_hash32`, `is_gateway`, `gateway_layers`, `is_mobile`, `joined`, `routing_sf`, `allowed_sf_bitmap` |
| `node_state_snapshot` | Periodic accumulator-diagnostics dump (§11.6); debug-window gated when configured | `node_id`, `layer_id`, `leaf_id`, `is_gateway`, `gateway_layers`, `is_mobile`, `tx_queue_depth`, `deferred_sends_depth`, `pending_tx`, `pending_rx`, `rt_size`, `budget_tier`, `pct_used`, plus throughput counters |
| `rt_debug_snapshot` | Debug-window route table mutation dump for one destination | `reason`, `node_id`, `layer_id`, `active_layer_id`, `dst`, `dirty`, `deleted`, `candidate_count`, `candidates[]` with `slot`, `next_hop`, `n2_hop`, `hops`, `score`, `score_eff`, `age_ms`, `ttl_ms`, `expires_in_ms`, `is_gateway`, `mobile_touched`, `next_tier`, `next_blind`, `suspect_level` |
| `gateway_layer_active` | Gateway successfully retuned to (or returned to) a layer's radio context — fires from `activate_gateway_layer` and `activate_primary_layer` | `layer_id`, `leaf_id`, `routing_sf`, `duration_ms` (when entering a sweep), `reason` (`init`, `schedule`, `schedule_return`, `tx`, `tx_retry`, `q_hash`, `primary`) |
| `gateway_layer_window_deferred` | Scheduled sweep fire was deferred because `pending_tx`/`pending_rx` was active (half-duplex skip) | `layer_id`, `leaf_id`, `routing_sf`, `active_layer_id`, `active_leaf_id`, `listen_sf`, `retry_ms` |
| `gateway_schedule_change` | Gateway radio context changed because of init, schedule window, schedule return, or target-layer TX | `active_layer_id`, `active_leaf_id`, `listen_sf`, `data_sf_bitmap`, `duration_ms`, `reason` |
| `gateway_schedule_observed` | Node decoded gateway BCN schedule records | `gateway`, `primary_leaf_id`, `records`, `schedule[]` entries with `layer_id`, `leaf_id`, `routing_sf`, `duration_ms`, `offset_ms`, `period_ms`, `period_unit_ms` |
| `tx_gateway_schedule_defer` | Sender deferred initial or retry RTS to a direct gateway because the gateway is scheduled away | `origin`, `dst`, `next_hop`, `active_leaf_id`, `delay_ms`, `payload`, optional `ctr`, `ctr_lo`, `source`, `reason` |
| `gateway_envelope_enqueued` | `send_layer` queued a cross-layer envelope toward a gateway | `origin`, `gateway`, `target_layer_id`, `dst_key_hash32`, `payload` |
| `gateway_envelope_dropped` | `send_layer` could not pick a gateway, so the message produced no envelope/DATA. `reason=no_gateway_known` (no gateway advertised for the layer) or `gateway_known_no_route` (a TLV names a gateway but there is no routing-table route to it — typically its route aged out during a visit absence) | `origin`, `target_layer_id`, `dst_key_hash32`, `reason` |
| `gateway_handoff_enqueued` | Gateway consumed a cross-layer envelope and queued an in-target-layer DATA send | `origin`, `via_gateway`, `target_layer_id`, `dst`, `dst_key_hash32`, `binding_source`, `payload` |
| `gateway_handoff_deferred` | Gateway consumed a cross-layer envelope but does not yet know the target hash binding; it held the handoff and optionally flooded an `'H'` hash-locate query on the target layer | `origin`, `via_gateway`, `target_layer_id`, `dst_key_hash32`, `payload`, `reason`, `q_sent`, `ttl_ms`, `depth` |
| `gateway_handoff_drained` | A deferred gateway handoff found a binding and was requeued for in-target-layer DATA send | `origin`, `via_gateway`, `target_layer_id`, `dst_key_hash32`, `dst`, `binding_source`, `waited_ms` |
| `gateway_handoff_giveup` | A deferred gateway handoff exceeded its discovery TTL without resolving the target binding | `origin`, `via_gateway`, `target_layer_id`, `dst_key_hash32`, `payload`, `reason`, `waited_ms` |
| `gateway_remote_bind_set` | Gateway learned `(layer_id,key_hash32) -> node_id` for a remote layer from BCN/JOIN traffic | `key_hash32`, `layer_id`, `node`, `source` |
| `gateway_remote_bind_conflict` | Gateway observed the same `(layer_id,key_hash32)` bound to a different remote node; binding is marked ambiguous and handoff refuses it | `key_hash32`, `layer_id`, `existing_node`, `conflicting_node`, `source` |
| `gateway_remote_bind_aged` | Gateway evicted a remote-layer binding after `gateway_remote_bind_ttl_ms` of silence | `key_hash32`, `layer_id`, `node`, `age_ms`, `ttl_ms`, `source`, `ambiguous` |
| `gateway_no_binding` | Gateway received an envelope but cannot resolve the target hash in that layer | `origin`, `via_gateway`, `target_layer_id`, `dst_key_hash32`, `payload`, `reason` (`not_found` / `ambiguous`) |
| `gateway_envelope_at_non_gateway` | Non-gateway received gateway envelope DATA; this is treated as routing/gateway misconvergence and dropped | `origin`, `dst`, `target_layer_id`, `dst_key_hash32`, `payload` |
| `bridged_layers_advertised` | Node included the gateway_layer TLV (type=4) in an outbound BCN | `count`, `entries[]` with `gw_id`, `dest_layer`, `age_ms` |
| `bridged_layers_observed` | Node parsed a gateway_layer TLV from a received BCN and updated its bridged_layers table | `from`, `count`, `entries[]` with `gw_id`, `dest_layer` |
| `bridged_layers_replaced` | Receiving TLV refreshed a known gw_id with a different dest_layer; last-write-wins replaces the old value | `gw_id`, `prev_layer`, `new_layer`, `from`, `age_ms` |
| `bridged_layers_aged` | Per-(gw_id, dest_layer) entry pruned after `gateway_bridged_layers_ttl_ms` of silence | `gw_id`, `dest_layer`, `age_ms`, `ttl_ms` |
| `h_tx` | Gateway flooded an `'H'` hash-locate query on the target layer (§3.7a) | `origin`, `key_hash32`, `ttl`, `reason`, `tx_layer_id`, `tx_leaf_id`, `tx_routing_sf` |
| `h_rx` | Node decoded an `'H'` query on its layer | `origin`, `key_hash32`, `ttl` |
| `h_forward` | Node did not know the hash and rebroadcast the `'H'` query with `ttl-1` | `origin`, `key_hash32`, `ttl` (post-decrement) |
| `h_resolved` | Node knew the hash (own or `id_bind`) and is replying with a routed-DATA binding response | `origin`, `key_hash32`, `node`, `target_layer_id` |
| `hash_bind_response_enqueued` | Resolver queued the routed-DATA binding response back to the querying gateway | `to`, `node`, `key_hash32`, `target_layer_id`, `ctr` |
| `q_hash_binding_rx` | Gateway received a binding response (routed DATA, `HASH_BIND_MAGIC` body) and updated `id_bind` + `gateway_remote_bind`, then drained handoffs | `from`, `node`, `key_hash32`, `layer_id`, `source` (`h_query`) |
| `table_cap_hit` | Bounded-state cap reached on a growing table. The current insert is refused; the event surfaces pathological growth so it's visible before the C++ port hits a flash/RAM wall. Capped tables: `q_queried`, `q_responded_to`, `route_request_seen`, `route_request_last`, `seen_origins`, `deferred_sends`, `gateway_deferred_handoffs`, `id_bind` | `table`, `size`, `cap`, `action` (`refuse`), plus a table-specific identifier (`key` for keyed maps; `origin`/`dst`/`ctr`/`reason` for arrays) |
| `max_payload_clamped` | Init-time guard. Configured `max_payload_bytes` exceeds the LoRa PHY 255-byte frame minus fixed overhead (`DATA_HDR_LEN(14) + DATA_INNER_OVERHEAD(6)` = 20); clamped to the hard cap (235) | `requested`, `clamped_to`, `lora_max_frame`, `fixed_overhead` |
| `send_oversized` | Originator-side rejection of a user payload exceeding `max_payload_bytes`. The send never enters `tx_queue`; runtime `tx_oversized` remains the radio-side backstop for frames built outside this path | `dst`, `dst_name`, `len`, `max`, optional `e2e`, optional `target_layer_id` / `dst_key_hash32` / `envelope_overhead` for `send_layer` |
| `channel_msg_received` | A `PAYLOAD_TYPE_M` DATA frame was merged into our `channel_buffer` (either because we were the `to=` target of a pull response, or via promiscuous overhearing of someone else's pull response) | `id`, `channel_id`, `flavor`, `source` (`pull_target` / `overheard`), `from` (immediate radio sender) |
| `channel_msg_pulled` | We responded to a `Q_CHANNEL_PULL` by emitting one or more PAYLOAD_TYPE_M DATA frames | `to`, `ids[]` (those we had), `missing[]` (requested but absent in our buffer) |
| `channel_msg_overheard` | We merged a PAYLOAD_TYPE_M frame we weren't the target of — the promiscuous-reception benefit | `id`, `channel_id`, `from`, `intended_to` |
| `channel_msg_evicted` | Channel buffer reached `cap_channel_buffer`; oldest entry was dropped | `id`, `channel_id`, `seen_by_all_neighbours` (bool) |
| `channel_pull_sent` | We emitted a `Q_CHANNEL_PULL` to a neighbour | `to`, `ids[]`, `trigger` (`new_dirty_in_bcn` / `digest_gap`) |
| `channel_pull_received` | Inbound `Q_CHANNEL_PULL`; will trigger one or more `channel_msg_pulled` responses | `from`, `ids[]` |
| `channel_pull_suppressed` | A scheduled pull was cancelled. Three trigger paths (distinguished by `overheard_from`): `promiscuous_receive` — the M-payload arrived via overhear before our jitter fired; `peer_q` — we decoded a peer's `Q_CHANNEL_PULL` for the same ID (ROADMAP §3.3, dedupe path that fires at peer-Q decode time instead of M-frame arrival time); `<src>` — early M-handler overhear from a specific neighbour | `ids[]`, `overheard_from`, optionally `peer` (when `overheard_from=peer_q`) |
| `channel_dirty_cleared` | Channel-buffer entry retired from advertising after `channel_dirty_max_advertisements` BCN inclusions. Entry stays in the buffer (still responds to pulls) but is no longer included in the dirty-page of outgoing BCN digests. Bounds per-holder M-frame load (ROADMAP §3.3) | `id`, `channel_id`, `ad_count`, `threshold` |
| `channel_overhear_armed` | Receiver decoded an `M_BROADCAST` RTS and retuned to the announced `chosen_data_sf` for the DATA-M window. ROADMAP §3.5 | `ctr_lo`, `sender`, `target`, `chosen_data_sf`, `guard_ms`, `addressed` (whether `r.next == self.id`) |
| `channel_overhear_skipped_already_have` | Receiver decoded an `M_BROADCAST` RTS, the announced `id_lo16` matched an entry in our `channel_buffer`, so we did NOT retune to data SF. Saves ~2 s of routing-SF blindness per duplicate decode. ROADMAP §3.6 | `ctr_lo`, `sender`, `id_lo16` |
| `channel_overhear_missed` | Armed receiver's retune window (`guard_ms`) expired without decoding the DATA-M frame (collision / half-duplex blind / RTS-DATA timing slipped). ROADMAP §3.5 | `sender`, `ctr_lo`, `chosen_data_sf`, `elapsed_ms` |
| `channel_msg_already_present` | DATA-M decoded but `channel_buffer` already contained this msg. Fires for the rare cases the `id_lo16` pre-arm check missed (e.g. RTS itself dropped at the radio layer but DATA-M arrived clean). Useful as cascade-overlap signal | `id`, `channel_id`, `from`, `intended_to` |
| `channel_broadcast_deduped` | Holder skipped enqueueing an M-payload for `id` because one is already in `pending_tx` or `tx_queue` (concurrent-pull dedup). ROADMAP §3.5 | `id`, `requester`, `reason` |
| `channel_digest_emitted` | Our outgoing BCN included a `BCN_EXT_TYPE_CHANNEL_DIGEST` extension with N dirty IDs | `dirty_ids[]`, `total_buffer_size` |
| `priority_send_capped` | Originator hit `originator_priority_max_per_window` — own PRIORITY send dropped silently. UX hint for "wait before next priority send" | `dst`, `dst_name`, `window_ms`, `cap`, `current_count` |
| `rts_drop_originator_priority_throttle` | 1st-hop neighbour detected a direct sender exceeding the per-hour priority cap; silently dropped the RTS | `from`, `ctr_lo`, `apparent_origination`, `window_ms`, `cap` |

---

## 14. Configuration reference

The scenario JSON's per-node `config` block exposes only the runtime-
tunable surface. The bulk of the protocol's parameter set is
production-fixed and lives in the `PROTOCOL = { ... }` table at the
top of `scenarios/dv_dual_sf.lua` — the C++ port maps that block
directly to a `protocol_constants.h` header. See `docs/CONFIG_AUDIT.md`
for the full classification (20 T / 82 P / 5 F / 8 D, post-audit).

In the Lua model, **`apply_protocol_constants(self, config)` honors
config overrides** as an escape hatch for dedicated tests (e.g. t55
shrinks `gateway_remote_bind_ttl_ms` from 48 h to 8 s, t61 shrinks
`cap_route_request_last` from 128 to 2). The C++ port has no such escape: P-
class values are `constexpr` and tests run against them with a longer
wallclock. Knobs documented below are the only ones intended to be
set in production scenario JSON.

### 14.1 Tunable — deployment configuration (20 keys)

The full T-class surface. Every other knob folds into PROTOCOL.

#### Identity

| Key | Default | Description |
|---|---|---|
| `is_gateway` | false | Node advertises gateway capability and bridges to `gateway_layers` |
| `is_mobile` | false | Node is mobile; relaxes route aging, never used as transit |
| `join_required` | false | Boot without a short ID; use temporary id 255 and run the J-frame join state machine |
| `layer_id` / `leaf_id` | 0 | Logical radio/routing layer; on-wire as 4-bit nibble (`layer_id & 0x0f`). `leaf_id` is the legacy alias |
| `key_hash32` | nil | This node's 32-bit identity hash; future NV-backed in real firmware |

#### Radio

| Key | Default | Description |
|---|---|---|
| `routing_sf` | 7 | SF for BCN, RTS, ACK |
| `allowed_data_sfs` | `{12}` | SFs offered in RTS bitmap; receiver picks |
| `bw_hz` | 250000 | LoRa BW in Hz (override of `_sim_bw_hz`) |
| `cr` | 5 | Coding rate (5..8 = CR4/5..CR4/8) |
| `duty_cycle` | 0.01 | ETSI EN 300 220 default; T because region-specific |
| `duty_cycle_window_ms` | 3600000 | 1-hour rolling regulatory window |

#### MAC

| Key | Default | Description |
|---|---|---|
| `max_payload_bytes` | 230 | Max user-payload byte length. Network-wide convention — all nodes must agree. Hard-clamped at init to LoRa PHY ceiling (`LORA_MAX_FRAME_BYTES - DATA_HDR_LEN - DATA_INNER_OVERHEAD` = 235, after the 6-byte visited window); see `max_payload_clamped` event. Originator emits `send_oversized` and rejects sends > cap. |
| `gradient_max_uphill_hops` | 1 | Loop guard: cap on how many hops "uphill" of the best route an alternate may be in `next_hop_selectable` (soft — 2-pass falls back to uphill rather than strand). nil disables. |
| `visited_check_depth` | 6 | Loop guard: how many of the DATA frame's `VISITED_LEN`(6)-deep carrier window to test (1..6). Tunes coverage without a wire change. |
| `gateway_send_giveup_ms` | 150000 | Gateway-doorstep hold: a cross-layer envelope that can't reach its egress gateway is held + retried window-aware until this, then a real `send_giveup` (instead of fanning out to sibling neighbours). |
| `gateway_doorstep_retry_jitter_ms` | 2000 | Burst-avoidance spread for in-window gateway-doorstep retries. |

#### Beacon / boot

| Key | Default | Description |
|---|---|---|
| `beacon_period_ms` | 900000 | Steady-state operational period (15 min) |
| `beacon_max_idle_ms` | 900000 | Max idle before busy throttle is bypassed (§6.2). 0 = disable |
| `req_sync_min_routes` | `PROTOCOL.discovery_min_routes` (8) | Suppress boot-time REQ_SYNC once this many routes are known. Override for sparse-route meshes (s07/s08 set 2) |

#### Routing

| Key | Default | Description |
|---|---|---|
| `rt_aging_ttl_neighbor_ms` | 2700000 (45 min) | Direct-neighbour candidate TTL — see §6.5 |
| `rt_aging_ttl_remote_ms` | 10800000 (3 h) | Multi-hop candidate TTL — see §6.5 |

#### Anti-spam / E2E

| Key | Default | Description |
|---|---|---|
| `originator_max_per_window` | 6 | Apparent-origination threshold per `PROTOCOL.originator_window_ms` (~72/hr at default). Per-network fairness policy |
| `e2e_ack_ttl_ms` | 60000 | E2E delivery ACK pending-entry TTL at originator (§7.4) |

#### Gateway

| Key | Default | Description |
|---|---|---|
| `gateway_layers` | `{}` | Secondary layer records (only meaningful when `is_gateway: true`). Each record may set `layer_id`, `routing_sf`/`sf`, `allowed_data_sfs`, `period_ms` (default 30000), `duration_ms` (default 5000), `offset_ms` (default 5000), and optional `leaf_id` override for tests. Per-record fields are the only source — no node-level fallbacks |

### 14.2 Feature flags (5 keys)

Always on in production. Test scenarios disable them to isolate
specific behaviors. The C++ port can wrap each in `#ifdef ENABLE_X`
to compile out for certification builds.

| Key | Default | Description |
|---|---|---|
| `lbt_enabled` | true | Pre-check `channel_busy_until` before initiating/flood TX |
| `seen_bitmap_enabled` | true | Append destination-freshness bitmap to BCN frames (§6.4) |
| `req_sync_on_boot` | true | During DISCOVERY, send `Q:REQ_SYNC` if route table remains poor |
| `rt_learn_from_data` | true | Opportunistically install route entries from carried DATA frames (§7.6) |
| `sync_response_enabled` | true | Allow this node to answer `Q:REQ_SYNC` with a full sync BCN |

### 14.3 Debug-only (8 keys)

Not used in production. The C++ port compiles them out (or
hardcodes the production value). The Lua model accepts them for
dedicated tests + run analysis.

| Key | Default | Description |
|---|---|---|
| `rts_timeout_ms` | computed per-flight | Override the per-flight RTS-timeout derivation (debug stress only) |
| `gateway_remote_bind_ttl_ms` | `id_bind_ttl_ms` (48 h) | Override the gateway remote-bind TTL. Production = `#define = ID_BIND_TTL_MS`. t55 sets 8000 ms to verify aging-out path |
| `state_snapshot_period_ms` | 60000 | Period for `node_state_snapshot` event (§11.6); 0 = disable |
| `originator_self_warn_fraction` | 0.5 | Self-warning trigger fraction (diagnostic hint emission) |
| `debug_start_ms` / `debug_start` | unset | Start of debug emit window (sim ms); suppresses noisy diagnostics before this time |
| `debug_end_ms` / `debug_end` | unset | End of debug emit window |
| `nv` | `{}` | Test seed for NV-persisted state (e.g. `nv = { claim_epoch = 42 }`). Real firmware reads NV directly |

### 14.4 Runtime-injected (don't override unless you know why)

| Key | Source | Description |
|---|---|---|
| `_sim_bw_hz` | runtime | Resolved BW in Hz from `simulation.radio` block |
| `_sim_cr` | runtime | Resolved CR |
| `_sim_duty_cycle` | runtime | Resolved duty_cycle |
| `_sim_duty_cycle_window_ms` | runtime | Resolved window |

### 14.5 PROTOCOL constants (read-only reference)

All 82 P-class knobs are pinned in the `PROTOCOL = { ... }` table at
the top of `scenarios/dv_dual_sf.lua`. They are protocol-design
parameters, not deployment parameters; changing one is a wire/behaviour
change and requires running the full suite. Categories (see the Lua
block for current values):

- Radio: `preamble_sym`, `sf_margin_q4`
- MAC: `cts_to_data_gap_ms`, `rts_busy_retry_ms`, `rts_max_retries`
- Beacon: `discovery_beacon_period_ms`, `beacon_max_bytes`,
  `beacon_trigger_jitter_*_ms`, `beacon_trigger_min_interval_ms`,
  `quiet_threshold_ms`, `beacon_silence_jitter_ms`, `seen_bitmap_ttl_ms`
- Boot: `discovery_ms`, `discovery_min_bcn_rx`, `discovery_min_routes`,
  `beacon_boot_grace_ms`, `req_sync_listen_ms`, `req_sync_retry_ms`
- Routing: `rt_aging_check_period_ms`, `next_hop_live_ttl_ms`,
  `route_snr_conservatism_q4`, `snr_ewma_alpha_q4`
- Peer liveness: `peer_suspect_rts_timeouts`, `peer_silent_rts_timeouts`,
  `peer_dead_rts_timeouts`, `peer_{suspect,silent,dead}_ttl_ms`,
  `peer_dead_evidence_window_ms`, `peer_{suspect,silent,dead}_penalty_q4`,
  `peer_suspect_bcn_max`
- Duty-cycle tiers: `budget_{strained,critical,exhausted}_pct`,
  `budget_blind_{strained,critical,exhausted}_ms`,
  `neighbor_budget_tier_ttl_ms`
- Anti-spam: `originator_window_ms`, `originator_airtime_share`,
  `originator_retry_dedup_ms`
- Cascade requeue: `cascade_requeue_max`, `cascade_requeue_base_ms`,
  `cascade_requeue_backoff_cap_ms`, `cascade_requeue_total_max_ms`,
  `cascade_requeue_load_threshold`
- Q frames: `q_query_ttl_ms`, `q_respond_ttl_ms`
- Route discovery (`'F'`, §3.7b): `route_request_max_ttl`,
  `route_request_seen_ttl_ms`, `route_reply_jitter_ms` (RREP de-storm backoff)
- Sync response: `sync_response_backoff_{min,max}_ms`,
  `sync_response_mobile_penalty_ms`,
  `sync_response_requester_mobile_penalty_ms`,
  `sync_response_suppress_window_ms`
- Defer/dedup: `send_defer_ttl_ms`, `last_acked_ttl_ms`, `seen_origin_ttl_ms`
- Hop budget: `hop_budget_slack`, `hop_budget_max_initial`
- Bounded state caps: `cap_seen_origins`, `cap_q_queried`,
  `cap_q_responded_to`, `cap_route_request_seen`, `cap_route_request_last`,
  `cap_deferred_sends`, `cap_gateway_deferred_handoffs`, `cap_id_bind`,
  `cap_channel_buffer` — emit `table_cap_hit` on overflow (§13.6)
- Identity / gateway: `id_bind_ttl_ms`, `gateway_schedule_guard_ms`,
  `gateway_bridged_layers_ttl_ms` (TLV type=4 entry lifetime; pruned
  on access if older), `gateway_bridged_layers_max_per_tlv` (cap on
  entries per TLV, default 9 per the 4-bit `len` field)
- Hash-locate `'H'` flood (§3.7a): `hash_query_max_ttl` (initial flood
  TTL, default 16 = `dv_hop_cap`), `hash_query_seen_ttl_ms` (forwarder
  dedup window, default 10 s), `cap_hash_query_seen` (dedup-set cap,
  default 64)
- Join: `join_{listen,discover_jitter,discover_wait}_ms`,
  `join_discover_max_attempts`, `join_offer_backoff_{min,max}_ms`,
  `join_claim_guard_ms`, `join_retry_backoff_ms`,
  `join_j_rate_limit_window_ms`, `join_j_max_per_window`
- **Channel gossip (ROADMAP §3, operational since 2026-05-20; broadcast-pivot 2026-05-21)**:
  `cap_channel_buffer = 128`,
  `channel_msg_max_payload_bytes = 200`,
  `channel_dirty_max_per_bcn = 3`,
  `channel_dirty_max_advertisements = 3` (after K BCN ads, retire
  the dirty entry — bounds per-holder load; see ROADMAP §3.3),
  `channel_pull_window_ms = 60000` (widened 5 s → 60 s with the
  2B-broadcast pivot; matches the natural BCN-cycle cadence —
  ROADMAP §3.5),
  `channel_pull_jitter_ms = 5000` (wide enough that the first puller's
  Q frame cancels peer pendings before they fire — see ROADMAP §3.3),
  `cap_channel_pulls_per_bcn_cycle = 3`
- **Priority unicast (ROADMAP §3a, deferred)**:
  `originator_priority_max_per_window = 5`,
  `originator_priority_window_ms = 3600000` (1 h)

### 14.6 Q4 fixed-point dB (internal)

All SNR/RSSI/score/EWMA storage and arithmetic is `int16_t` Q4
(1 unit = 1/16 dB). PROTOCOL stores Q4 values directly. Telemetry
events and logs convert back via `q4_to_db` for human readability.
The C++ port maps Q4 to `int16_t` with no FPU. See ROADMAP §11.2.

---

## 15. Known limitations

### 15.1 ~~Address-assignment story unresolved~~ — RESOLVED

**Resolved.** Two-tier OTAA-style addressing is implemented:

- Permanent identity: 32-bit `key_hash32` (future `public_key` hash
  from §8 crypto), carried in every BCN (§3.1).
- Short address: 8-bit `node_id`, assigned via the J-frame state
  machine (J_DISCOVER → J_OFFER → J_CLAIM → J_DENY → ADOPT, §3.5).
- Per-observer `id_bind[(layer_id) → node_id → key_hash32]` table,
  TTL-aged (`PROTOCOL.id_bind_ttl_ms` = 48 h).
- Partition-merge / address-conflict recovery: `id_bind_set` fires
  `addr_conflict_observed` on key mismatch; when the conflict
  involves our own adopted id, own-id defense sends `J_DENY` with
  reason `J_DENY_REASON_OWN_ID_DEFENSE`; the impostor's J_DENY
  handler runs `addr_conflict_tie_break` (older lease → higher
  epoch → lower key) and the loser triggers `forced_rejoin`.
  Total ordering prevents thrashing. NV-persisted `claim_epoch`
  provides a "newer boot wins" deterministic tie-break.

Coverage: t46-t60 exercise the full join wire + state machine +
conflict-recovery path. See SCENARIOS.md §5.1-§5.8.

### 15.2 BCN ctr_lo dedup not protected by leaf_id alone

The leaf_id filter prevents foreign beacons from being merged into
the routing table. But on-air collisions during enhanced propagation
events still happen — two networks' beacons collide, both fail to
decode, no rt damage but airtime is burned.

Mitigation already present: BCN throttle + adaptive jitter spread
beacons across time. No further work needed unless the collision rate
becomes a measured problem.

### 15.3 Dual-SF asymmetry — F1 residual

Even with the F1 blind-window mitigation, there's a narrow case where
the receiver is on data_sf RX and the CTS we'd have overheard was
itself lost in flight. The exponential rts_timeout backoff covers
most of it; rare residual cases manifest as `rts_giveup`.

### 15.4 NACK busy_for_ms unbounded at sender

The sender trusts the receiver's announced busy_for_ms. A buggy or
malicious receiver could announce 65 s (the 16-bit max) and stall the
sender. No cap today; acceptable in trusted-network settings.

### 15.5 ~~Alt freshness expiry not implemented~~ — RESOLVED

**Resolved.** §6.5 stale-route aging now evicts candidates whose
`last_seen_ms` exceeds a hop-class-specific TTL: direct neighbours
use `rt_aging_ttl_neighbor_ms` (default 45 min), multi-hop entries
use `rt_aging_ttl_remote_ms` (default 3 h). Direct-neighbour
last_seen also refreshes on every on_recv (not just beacons) so
heavy-traffic-throttled scenarios don't false-evict alive nodes.

The narrower follow-up is **explicit "deleted route" advertisement**
in the wire format. Today, a node that evicts a destination just
stops advertising it; neighbours' own aging eventually catches up
(N hops × ttl). A 1-bit "deleted" flag in beacon entries would
propagate eviction immediately, but adds wire complexity and isn't
yet justified by measured cost.

### 15.6 SF picks under static SNR

When `sigma_db = 0` in path-loss config, every link reports a single
constant SNR. The EWMA mechanism is correct but is a no-op. SF picks
in this regime are conservative (5 dB margin), causing observed SF
tax. Real fix is adaptive margin based on retry history — see
`memory/project_sf_tax_regression_after_bcn_throttle.md`.

### 15.7 BCN compression is still deferred

BCN route entries are already bit-packed to 3 bytes each
(`dest + next + score_bucket + hops`). The current remaining fixed cost is the
8-byte header, including `key_hash32`, plus optional bitmap/extension blocks.
Further compression, such as grouping entries by `next_hop`, remains deferred
until measurements show BCN airtime is still the limiting factor after join and
duplicate-ID handling are stable.

---

*This document is generated from `scenarios/dv_dual_sf.lua` at git
HEAD. When the protocol changes, regenerate by reading the lua and
updating each section. Every numeric value and behavioral claim
should grep to a specific line of the script.*
