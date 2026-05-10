# LoRa Mesh Protocol — `dv_dual_sf` Reference

Implementation-grade reference for the protocol implemented in
`scenarios/dv_dual_sf.lua`. Everything in this document traces to
specific lines of that script as of git `HEAD`.

The protocol is **distance-vector routing on a control SF + per-hop
unicast handshake on an adaptive data SF**. Hop-level reliability is
achieved through an explicit RTS/CTS/DATA/ACK exchange. Routing is
maintained through periodic + triggered beacons. Two networks can
coexist on the same channel via a 4-bit `network_id` filter.

---

## Table of contents

1. [Design philosophy](#1-design-philosophy)
2. [Architecture overview](#2-architecture-overview)
3. [Frame formats (bit-level)](#3-frame-formats-bit-level)
4. [Per-neighbor SNR EWMA + ACK piggyback](#4-per-neighbor-snr-ewma--ack-piggyback)
5. [Routing — distance-vector with K=3 alts](#5-routing--distance-vector-with-k3-alts)
6. [Beacon plane](#6-beacon-plane)
7. [Data plane — happy path](#7-data-plane--happy-path)
8. [Data plane — failure modes](#8-data-plane--failure-modes)
9. [Cross-network filtering (`network_id`)](#9-cross-network-filtering-network_id)
10. [Origin-level dedup](#10-origin-level-dedup)
11. [Half-duplex, LBT, duty cycle](#11-half-duplex-lbt-duty-cycle)
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
  application layer can layer dedup via `(origin, origin_seq)`.
- **Routing is decentralized DV.** No central controller. Each node
  announces its known routes via beacon; receivers merge into a local
  K=3 candidate list per destination, pick the best for forwarding.
- **Throttle-and-defer over admit-and-collide.** Beacons skip when
  channel is busy. RTS waits briefly before forcing onto a busy
  channel. Triggered beacons fire urgently for routing changes;
  periodic beacons are slow keep-alive.
- **Bit-tight wire format.** Routing fields are 4-8 bits as needed.
  Total control overhead per flight is ~12 bytes (RTS+CTS+ACK), down
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

### 3.1 Beacon (`'B'`) — 4 + 3n bytes

```
byte:  0      1                  2     3   4..(4+3n)
       ┌───┬─────────────────┬─────┬───┬───────────────────────────┐
       │'B'│ network_id(4hi) │ src │ n │ entries × n × 3 bytes     │
       │   │ reserved (4lo)  │     │   │                           │
       └───┴─────────────────┴─────┴───┴───────────────────────────┘

each entry (3 bytes, bit-packed):
       ┌──────┬──────┬─────────────────────────┐
       │ dest │ next │ score_bucket_4 │ hops_4 │
       └──────┴──────┴────────────────┴────────┘
```

- `network_id` (4 bits): admin-managed mesh identifier. Receivers
  reject foreign-network beacons before any rt_merge work.
- `src` (8 bits): beacon sender's node id.
- `n` (8 bits): entry count in this page (capped by
  `beacon_max_entries`, default 49 for a 151-byte cap).
- `entries[i].dest` (8 bits): destination this entry routes to.
- `entries[i].next` (8 bits): the sender's next-hop for `dest`. Used
  by receivers for **3-cycle prune** (see §5.2).
- `entries[i].score_bucket_4` (4 bits, hi nibble of byte 2): chain-min
  SNR quantized to a 4-bit bucket via `bucket_of_snr_4b` (16 buckets,
  2 dB resolution, range −20..+10 dB). Same encoding used for ACK
  piggyback SNR feedback for consistency. Decoded via
  `snr_of_bucket_4b` to bucket center.
- `entries[i].hops` (4 bits, lo nibble of byte 2): hop count along the
  advertised path. Routes with `hops > 8` rejected at the receiver.

**Pre-bit-pack:** entries were 4 bytes (`dest + next + score_i8(8) +
hops(8)`); default beacon was 200 bytes (49 × 4-byte entries). Bit-
packing entries to 3 bytes shrinks the default beacon to 151 bytes
(−24.5% airtime) while preserving the 49-entry-per-page count.
Scenarios that want denser pages can bump `beacon_max_bytes` to 200
(→ 65 entries/page) or 255 (→ ~83 entries/page, LoRa PHY max).
Score precision drops from 1 dB to 2 dB — fine for routing decisions
since per-packet LoRa SNR variance is typically 1-3 dB anyway.

### 3.2 RTS (`'R'`) — 8 bytes

```
byte:  0   1     2     3    4     5                    6           7
       ┌───┬─────┬─────┬───┬─────┬───────────────────┬───────────┬─────────────┐
       │'R'│ orig│ src │dst│ next│ network_id (4hi) │ sf_bitmap │ payload_len │
       │   │     │     │   │     │ msg_id (4 lo)    │           │             │
       └───┴─────┴─────┴───┴─────┴───────────────────┴───────────┴─────────────┘
```

- `origin` (8 bits): end-to-end source (the originator, not relays).
- `src` (8 bits): immediate sender of THIS RTS frame (the previous
  hop). For an originator's first hop, `src == origin`.
- `dst` (8 bits): end-to-end destination.
- `next` (8 bits): immediate next-hop receiver. Receivers other than
  `next` drop the RTS silently.
- `network_id` (4 bits): mesh identifier. Receivers reject foreign-
  network RTSes before any CTS work.
- `msg_id` (4 bits): per-(originator) flight counter, wraps at 16.
  Combined with `last_acked_from`'s 10s TTL gives correct hop-level
  retry dedup at any realistic send rate.
- `sf_bitmap` (8 bits): bit `i` set means SF `i+5` is acceptable for
  the data leg. e.g., `0b00001110` = {SF6, SF7, SF8}.
- `payload_len` (8 bits): exact byte count of the upcoming DATA
  payload (origin_seq header + user_text). Lets the receiver size
  `pending_rx_expiry` to actual airtime.

### 3.3 CTS (`'C'`) — 2 bytes

```
byte:  0   1
       ┌───┬───────────────────────────────────┐
       │'C'│ msg_id (4 hi)                     │
       │   │ chosen_data_sf - 5 (3)            │
       │   │ reserved (1)                      │
       └───┴───────────────────────────────────┘
```

- `msg_id` (4 bits): echoes the RTS's msg_id. Originator matches
  against `pending_tx.msg_id`.
- `chosen_data_sf` (3 bits, encoded as offset from 5): SF the
  receiver picked for the DATA leg. Range 5..12 → encoded 0..7.
- `reserved` (1 bit): set to 0.

No `network_id` — CTS is matched at the originator by
`pending_tx.msg_id`, which was set after the originator's already-
validated RTS.

### 3.4 DATA (`'D'`) — 6 bytes header + n bytes payload

```
byte:  0   1     2     3    4     5                    6..
       ┌───┬─────┬─────┬───┬─────┬───────────────────┬─────────────┐
       │'D'│ orig│ src │dst│ next│ reserved (4 hi)   │ payload     │
       │   │     │     │   │     │ msg_id (4 lo)     │             │
       └───┴─────┴─────┴───┴─────┴───────────────────┴─────────────┘

payload = [origin_seq_lo(1)] [origin_seq_hi(1)] [user_text(N)]
```

- Mesh header fields (origin, src, dst, next, msg_id) are sized as in
  RTS.
- `payload` is opaque to the mesh layer. Forwarders relay it byte-for-
  byte. The application layer at the originator prepends a 16-bit
  `origin_seq`; receivers parse this for dedup (see §10).

### 3.5 ACK (`'K'`) — 2 bytes

```
byte:  0   1
       ┌───┬───────────────────────────────────┐
       │'K'│ msg_id (4 hi)                     │
       │   │ snr_bucket (4 lo)                 │
       └───┴───────────────────────────────────┘
```

- `msg_id` (4 bits): echoes the DATA's msg_id.
- `snr_bucket` (4 bits): receiver's quantized DATA-leg SNR. 16
  buckets, 2 dB bins, range −20..+10 dB. Bucket `n` represents bin
  center `−19 + 2n` dB. Bucket 15 is the "no info" sentinel when
  the sender called `pack_ack(msg_id, nil)`.

The originator/forwarder feeds the decoded SNR into
`snr_ewma_out[next_hop]` — outbound link-quality estimate, separate
from `snr_ewma_in` (inbound).

### 3.6 NACK (`'N'`) — 4 bytes

```
byte:  0   1                       2                3
       ┌───┬───────────────────┬─────────────────┬─────────────────┐
       │'N'│ reserved (4 hi)   │ busy_for_ms_lo  │ busy_for_ms_hi  │
       │   │ msg_id (4 lo)     │                 │                 │
       └───┴───────────────────┴─────────────────┴─────────────────┘
```

- `msg_id` (4 bits): RTS's msg_id being NACKed.
- `busy_for_ms` (16 bits, little-endian): how long the receiver
  expects to be busy. Originator can either wait (if short) or push
  the send back into its queue (if long).

NACK rides on `data_sf`, not `routing_sf`, because the originator's
RX is already retuned to `data_sf` after sending RTS, awaiting CTS.
NACK and CTS are the two possible admissions; sharing the channel is
intentional.

### 3.7 Frame-size summary

| Frame | Bytes | Notes |
|---|---|---|
| BCN | 4 + 4n | n entries; default cap 49 → max ~200 B |
| RTS | 8 | fixed |
| CTS | 2 | fixed |
| DATA | 6 + n | n = payload bytes (≤ `max_payload_bytes`) |
| ACK | 2 | fixed |
| NACK | 4 | fixed |

Per-flight control overhead (RTS + CTS + ACK) = **12 bytes**.

---

## 4. Per-neighbor SNR EWMA + ACK piggyback

The protocol maintains two per-neighbor SNR estimates:

- `self.snr_ewma_in[nbr_id]` — fed by `meta.snr` of every successful
  RX from that neighbor. Used by `select_data_sf` to pick the data SF
  in a CTS based on smoothed signal estimate, not a single noisy
  snapshot.
- `self.snr_ewma_out[nbr_id]` — fed by the 4-bit ACK SNR bucket. The
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

### 5.2 DV merge (`rt_merge`)

For each candidate `cand` derived from a beacon entry:

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
  4. If exhausted:
     - Emit path_cascade_exhausted + the legacy giveup event
     - Clear pending_tx; become_free
```

This implements K=3 multi-alt routing without changing the wire
format.

---

## 6. Beacon plane

### 6.1 Periodic beacon

```
on_init schedules first beacon at rand(0, beacon_period_warmup_ms)
Every beacon_fire:
  1. If pending_tx ~= nil OR pending_rx ~= nil: log + skip emission
  2. Else: adaptive-throttle gate (see §6.2)
  3. Always: re-arm next periodic at rand(0.8×period, 1.2×period)
     - period = beacon_period_warmup_ms during warmup
     - period = beacon_period_ms after warmup
```

Defaults: warmup period 5 s, operational period 5 min. Real LoRa
deployments use 30+ min; the simulator compresses time.

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

### 6.3 Triggered beacon

Any `rt` mutation (new entry, primary promote, 3-cycle prune)
schedules a one-shot beacon within `[beacon_trigger_jitter_min_ms,
beacon_trigger_jitter_max_ms]` (default 50–500 ms).

```
schedule_triggered_beacon:
  if triggered_beacon_pending: no-op (coalesced)
  triggered_beacon_pending = true
  after rand(50, 500): triggered_beacon_pending = false
                       send_beacon_page("triggered")
```

**Triggered beacons bypass the adaptive throttle.** They exist to
propagate routing changes urgently; suppressing them on busy channels
defeats the purpose. Half-duplex skip still applies.

### 6.4 Differential beacons (dirty-first emission)

`pack_beacon` is two-tiered. When emitting:

1. **Phase 1 — dirty routes (priority):** every `rt[dest]` with
   `.dirty=true` is emitted first, sorted by `dest_id`. The flag is
   set by `rt_merge` on actions that change the route this node would
   advertise (`"new"`, `"promote"`, `"primary_refresh"`) and by
   `rt_prune_cycle` when the primary slot is removed. Cleared once the
   route is included in a beacon.

2. **Phase 2 — stable rotation (background):** existing sliding-offset
   walk fills any remaining slots up to `beacon_max_entries`, skipping
   destinations already in Phase 1 (dedup within a single beacon).

The stable offset only advances by the number of stable slots used.
When dirty fills the beacon, stable progress isn't lost.

**Steady state with no churn:** every route is clean → Phase 1 is
empty → only Phase 2 runs → byte-for-byte identical to the
pre-differential pack_beacon. No regression.

**Active state with churn:** route mutations land in the dirty set and
are guaranteed to ship in the next beacon. Convergence latency for a
new route change drops from `O(rotation_window × beacon_period)`
(could be minutes for large tables) to `O(beacon_period)` (single
round-trip).

Telemetry: `beacon_diff_breakdown` event fires per beacon with
`{dirty_n, stable_n, total_dirty, rt_total, kind}`. `total_dirty`
greater than `dirty_n` means some dirty entries overflowed the page
and will surface in the next beacon (no information loss).

Wire format unchanged. The receiver doesn't know whether a route was
dirty or stable — it just merges via existing rt_merge.

### 6.5 Stale-route aging

Per-candidate `last_seen_ms` is refreshed by `rt_merge` whenever a
beacon advertises that exact `(dest, next_hop)` combination. A periodic
aging loop walks `rt[]` every `rt_aging_check_period_ms` (default 60 s)
and evicts candidates older than `rt_aging_ttl_ms` (default 10 min,
= 2× default operational beacon period of 5 min).

```
age_out_stale_routes(self):
  for each rt[dest]:
    keep, primary_evicted = filter candidates by (now - last_seen) < ttl
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

**Direct-neighbour last_seen refresh on ANY RX:** the on_recv top hook
also refreshes `rt[meta.src].candidates[direct].last_seen_ms` for every
incoming frame, not just beacons. This prevents direct neighbours from
being falsely evicted when their periodic beacons are throttle-
suppressed under heavy traffic — RTS/CTS/DATA/ACK traffic from them
counts as proof they're alive. Multi-hop entries still age via beacon
advertisements only (the multi-hop info IS stale if no one is
re-advertising it).

**Why no explicit "delete" advertisement?** The wire format has no
"this route is gone" frame. When a node evicts a destination entirely,
the triggered beacon advertises the rest of the table without the
gone destination. Neighbours hearing that beacon refresh their other
routes via this node, and their own aging loop eventually evicts the
gone destination from their tables (when `last_seen` to it stops
refreshing). Cascade time across N hops: ~`N × rt_aging_ttl_ms`.

**Configurable behavior:**

| Key | Default | Description |
|---|---|---|
| `rt_aging_ttl_ms` | 600000 (10 min) | Candidate expires if not refreshed within this window |
| `rt_aging_check_period_ms` | 60000 (1 min) | How often the aging scan runs |

Set `rt_aging_ttl_ms = 0` to disable aging (memory leak risk in
long-lived deployments; useful for tests).

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

`beacon_offset` advances per fire. Default `beacon_max_bytes = 200`
→ `beacon_max_entries = floor((200 − 4) / 4) = 49`.

Receivers don't track pages — every entry heard gets merged via
`rt_merge` as before.

---

## 7. Data plane — happy path

End-to-end flight from originator to destination, no failures.

### 7.1 Sequence diagram (single-hop unicast)

```
Originator (alice)              Next-hop (bob)
                                                        SF
on_command "send bob hello"
  enqueue {origin=alice, dst=bob, payload=hello}
  become_free →
  issue_send →
    pack_rts → pending_tx
    set_rx_sf(data_sf)
    start_rts_timeout
    tx 'R' on routing_sf       routing_sf
                          ─R──>
                                on_recv "R", network_id ok, next == self.id
                                ↓
                                set_rx_sf(data_sf)              data_sf
                                pending_rx = {from=alice, msg_id, ...}
                                start_pending_rx_expiry
                                pack_cts(msg_id, chosen_sf)
                                tx 'C' on data_sf
                          <─C──
on_recv "C", matches pending_tx.msg_id              data_sf
cancel rts_timeout
after cts_to_data_gap_ms:
  pack_data → tx 'D' on data_sf
  set_rx_sf(routing_sf)        routing_sf
  start_ack_timeout
                          ─D──>
                                on_recv "D", matches pending_rx.msg_id
                                ↓
                                cancel pending_rx_expiry
                                set_rx_sf(routing_sf)           routing_sf
                                pending_rx = nil
                                last_acked_from[alice] = {msg_id, t_ms}
                                pack_ack(msg_id, meta.snr) →
                                tx 'K' on routing_sf
                          <─K──
on_recv "K", matches pending_tx.msg_id
cancel ack_timeout
update snr_ewma_out[bob] from k.snr_db
pending_tx = nil; become_free
                                if dst == self.id:
                                  emit "delivered"
                                else (forwarder):
                                  after ack_air_ms+1: enqueue forward
                                  become_free
```

### 7.2 SF retune timeline

The originator/forwarder retunes RX between `routing_sf` and
`data_sf` exactly twice per flight:

```
RX state at originator/forwarder:

t=0          t=after RTS-tx     t=after ACK-rx
routing_sf ─→ data_sf         ─→ routing_sf
              (awaiting CTS &
               then sending DATA)
```

The next-hop receiver retunes once, mirroring:

```
RX state at next-hop:

t=0          t=after RTS-rx     t=after DATA-rx
routing_sf ─→ data_sf         ─→ routing_sf
              (sending CTS &
               then awaiting DATA)
```

There's a brief window between RTS-rx and CTS-tx where the receiver
is on `data_sf` but hasn't sent CTS yet. Concurrent senders' RTSes
land as `drop_sf_mismatch` during this window — see §8.4 for the F1
blind-window mitigation.

### 7.3 Per-flight TX policy classes

Three categories, each with different LBT timing constraints:

| Class | Frames | Policy |
|---|---|---|
| **RESPONSE-DIRECTED** | CTS, DATA, ACK | Goes straight through `tx_with_retry`. Peer's timer is already running and was sized to the *minimum* round-trip airtime; any LBT defer here would burn a retry. |
| **INITIATING-DIRECTED** | RTS, NACK | Routed through `tx_initiating`. Pre-checks `channel_busy_until()` once (single politeness wait). If busy, schedules emit at busy_until + random jitter, then commits even if still busy. |
| **FLOOD** | BCN | Routed through `tx_flood`. LBT-defers up to `flood_lbt_max_defer_ms`, then drops the page (`tx_flood_skipped`). Stale routing info isn't worth queueing. |

All three set `pending_tx` (where applicable) BEFORE the actual emit,
so peer NACK / busy-replies match the right msg_id.

---

## 8. Data plane — failure modes

### 8.1 RTS reaches receiver but it's busy

```
on_recv 'R' at receiver, while pending_rx is set with a DIFFERENT
flight (different sender or different msg_id):
  emit nack_tx
  pack_nack(r.msg_id, busy_for = pending_rx_expires_in)
  tx 'N' on data_sf
```

Originator on receiving NACK:

```
on_recv 'N', matches pending_tx.msg_id:
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

### 8.2 RTS already acked (sender retried after losing previous ACK)

```
on_recv 'R' with last_acked_from[r.src].msg_id == r.msg_id
       AND (now − last_acked_from[r.src].t_ms) < last_acked_ttl_ms (10 s):
  emit rts_already_acked
  pack_ack(r.msg_id, meta.snr) → tx 'K' on routing_sf
  return  (skip CTS + DATA)
```

The sender's previous ACK was lost; they retried the RTS. We re-send
the ACK so they clear pending_tx without us reprocessing or
forwarding the message twice.

The 10s TTL is what makes 4-bit msg_id safe under wraparound: at any
plausible per-sender send rate, 16 sends take much longer than 10 s,
so the cache never false-positives on a wrapped id.

### 8.3 Duplicate RTS while we're mid-flight as receiver

```
on_recv 'R' with pending_rx ~= nil AND
            pending_rx.from == r.src AND
            pending_rx.msg_id == r.msg_id:
  emit rts_rx_dup
  pack_cts(r.msg_id, pending_rx.chosen_data_sf)
  tx 'C' on routing_sf  (CTS-dup label)
  restart pending_rx_expiry
```

Sender's previous CTS was lost. They retried RTS. We re-send CTS
with the same chosen_data_sf so they can re-attempt DATA.

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
| ACK lost | ack_timeout at sender + last_acked_from at receiver | Retry RTS; receiver short-circuits to re-ACK (rts_already_acked) |
| Routing-table mismatch | rts_giveup after K alts | path_cascade_exhausted; flight dropped, sender app-layer aware |

---

## 9. Cross-network filtering (`network_id`)

A 4-bit network identifier in BCN and RTS lets multiple LoRa meshes
coexist on the same channel. Receivers reject foreign-network frames
**before any other work**:

```
on_recv 'B':
  if b.network_id ~= self.network_id: return  (silent drop)
  ... rt_merge ...

on_recv 'R':
  if r.network_id ~= self.network_id: return  (silent drop)
  ... CTS / forwarding logic ...
```

Without this filter, two networks merging during enhanced RF
propagation events (30-40 km tropo ducting) would:

1. Attempt CTSes for foreign RTSes (wasted airtime + collisions).
2. Pollute routing tables with foreign nodes (decisions to route via
   non-existent neighbors → flights fail with `rts_giveup`).

`network_id` is **externally managed** (admin sets `config.network_id`
per node). 4 bits = 16 distinct meshes — sufficient for any 30-40 km
propagation circle in practice.

CTS/DATA/ACK/NACK don't carry `network_id` because they're matched
against `pending_tx`/`pending_rx` state set by an already-validated
RTS — the check is implicit.

---

## 10. Origin-level dedup

End-to-end uniqueness is provided by `(origin_node_id, origin_seq)`:

- `origin_node_id`: 8-bit field in DATA's mesh header.
- `origin_seq`: 16-bit application-layer sequence number, prepended
  to the DATA payload as `[seq_lo, seq_hi]`. Originator increments per
  send; never wraps in any realistic deployment lifetime (65k sends
  per node).

Receiving a DATA frame:

```
on_recv 'D' (matches pending_rx):
  parse origin_seq from first 2 payload bytes
  ack the frame regardless (sender clears pending_tx)
  if (d.origin, origin_seq) in seen_origins:
    emit dup_drop
    return  (don't deliver-twice or forward-twice)
  record (d.origin, origin_seq) in seen_origins with TTL
  if dst == self.id:
    emit delivered (payload = user_text)
  else (forwarder):
    after ack_air_ms+1: enqueue forward; become_free
```

Default TTL: `seen_origin_ttl_ms = 30 s`. Catches:

- DV routing loops (same payload returned via cycle).
- Legitimate same-payload retries via different paths (originator's
  retry queued through different next-hop).

The dedup acts BEFORE delivery / forwarding but AFTER the ACK is sent,
so the previous hop always clears its pending_tx.

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
`self:channel_busy_until()` and defer if busy. This avoids the round-
trip of TX → runtime defers → on_radio_busy → re-tx.

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

---

## 11a. Bootstrap UX (cold-start joiners)

The "new user installs the app, opens it, immediately taps send" case
needs explicit handling — without it, the user sees a silent drop and
abandons the app. Two mechanisms:

### 11a.1 Cold-start fast first beacon

In `on_init`:

```
boot_at = self:now()
if boot_at < warmup_ms or warmup_ms == 0:
  # Mass-boot scenario (everyone starts at t=0, or no warmup configured)
  # — must jitter to avoid beacon storm
  schedule first beacon at rand(0, beacon_period_warmup_ms)  # ~5 s
else:
  # Cold-start joiner past warmup — single new node, no storm risk
  # — fire ASAP so neighbours' triggered beacons populate our rt within
  # ~hundreds of ms instead of waiting up to a full operational period
  schedule first beacon at rand(1, 200)  # ~100 ms avg
```

The cold-start path cuts mean bootstrap latency from ~2.5 s (random
offset within warmup beacon period) to ~150 ms (immediate beacon +
neighbour's triggered beacon back to us). For real hardware, the
"detect we're a cold-start joiner vs. mass-boot" test falls back to
"always jitter" since `warmup_ms` is 0.

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

Forwarders (`previous_hop ~= nil`) never defer — a route gone
mid-flight is a real failure; the originator's app-layer retry is the
recovery path. They keep the legacy `send_no_route` emit.

### 11a.3 Bootstrap timeline (measured on t27)

5-node line `a-b-c-d-e`, eve boots at t=20000 (past warmup_ms=10000):

```
t = 20000 ms   eve.on_init runs
                schedules first beacon at t+150ms (cold-start path)
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
  schedule first beacon at rand(0, beacon_period_warmup_ms)
```

Per-node state populated:

| Field | Type | Purpose |
|---|---|---|
| `rt` | table | Routing table (dest → candidates list) |
| `pending_tx` / `pending_rx` | table or nil | In-flight unicast state |
| `tx_queue` | array | Queued sends, drained by become_free |
| `tx_stash` | table | label → frame for on_radio_busy retry |
| `blind_until` | table | nbr → absolute_ms (F1 mitigation) |
| `last_acked_from` | table | sender → {msg_id, t_ms} (RTS dedup) |
| `seen_origins` | table | (origin, seq) → t_ms (end-to-end dedup) |
| `snr_ewma_in` / `snr_ewma_out` | table | nbr → SNR estimate |
| `last_rx_routing_sf_ms` | int | Beacon throttle witness |
| `network_id` | int | 4-bit mesh identifier |
| `next_msg_id` | int | 4-bit per-flight counter |

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
| `beacon_tx` | Emitted right before sending a beacon page | `n_entries`, `rt_total`, `offset`, `next_offset`, `kind` |
| `beacon_rx` | Beacon decoded | `src`, `n_entries` |
| `beacon_skipped_busy` | Throttle suppressed beacon | `since_rx_ms`, `threshold_ms`, `stage` |
| `beacon_diff_breakdown` | Per-beacon dirty/stable split (§6.4) | `dirty_n`, `stable_n`, `total_dirty`, `rt_total`, `kind` |
| `rt_update` | Route added/promoted to a slot | `dest`, `next`, `score`, `hops`, `slot` |
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
| `send_drained` | Deferred send drained back to tx_queue (route appeared) | `origin`, `dst`, `waited_ms` |
| `send_giveup` | Defer TTL elapsed without route appearing | `origin`, `dst`, `waited_ms`, `reason` |
| `rts_tx` | RTS emitted | `origin`, `dst`, `next`, `msg_id`, `sf_bitmap` |
| `rts_retry` | tx_rts_retry fired | `reason`, `attempt` |
| `rts_rx` | RTS decoded, addressed to us | `from`, `dst`, `msg_id`, `chosen_data_sf`, `rx_snr`, `ewma_snr` |
| `rts_rx_dup` | Duplicate RTS while pending_rx active | `from`, `msg_id` |
| `rts_already_acked` | Cached ack short-circuit | `from`, `msg_id` |
| `rts_drop_no_sf` | RTS bitmap intersection empty | `from`, `msg_id`, `sf_bitmap` |
| `cts_tx` | CTS emitted | `to`, `msg_id`, `chosen_data_sf` |
| `cts_rx` | CTS decoded, matches pending_tx | `from`, `msg_id`, `chosen_data_sf` |
| `cts_invalid_sf` | Receiver picked an SF outside our bitmap | `from`, `msg_id`, `chosen_data_sf` |
| `data_tx` | DATA emitted | `dst`, `next`, `msg_id`, `payload` |
| `data_rx` | DATA decoded, matches pending_rx | `from`, `msg_id`, `len` |
| `data_rx_timeout` | pending_rx_expiry fired | `from`, `msg_id` |
| `ack_tx` | ACK emitted | `to`, `msg_id`, `data_snr` |
| `ack_rx` | ACK decoded, matches pending_tx | `from`, `msg_id`, `data_snr_db` |
| `ack_snr_feedback` | snr_ewma_out updated from ACK piggyback | `from`, `data_snr_db`, `snr_bucket`, `ewma_out` |
| `nack_tx` | NACK emitted | `to`, `msg_id`, `busy_for_ms`, `reason` |
| `nack_rx` | NACK decoded, matches pending_tx | `from`, `msg_id`, `busy_for_ms` |
| `delivered` | DATA arrived at end-to-end destination | `origin`, `payload`, `origin_seq` |
| `dup_drop` | Duplicate (origin, origin_seq) | `origin`, `origin_seq` |
| `forward_queued` | Forwarder enqueued the relay | `origin`, `dst` |
| `forward_fail` | Forwarder dropped (no route, no budget, etc.) | `origin`, `dst`, `reason` |
| `retune_for_data` | RX retuned for DATA reception | `from`, `msg_id`, `chosen_data_sf` |

### 13.3 Failure / cascade

| Event | Trigger | Key data |
|---|---|---|
| `rts_giveup` | RTS exhausted retries | `origin`, `dst`, `msg_id`, `last_next_hop` |
| `data_ack_giveup` | ACK timeout exhausted | `origin`, `dst`, `msg_id` |
| `path_cascade` | Switching to next alt after K=3 cascade fired | `from_next`, `to_next`, `attempt`, `trigger` |
| `path_cascade_exhausted` | All K alts tried | `dst`, `tried`, `trigger` |

### 13.4 F1 blind-window mitigation

| Event | Trigger | Key data |
|---|---|---|
| `blind_observed` | CTS overheard, blind_until extended | `for_node`, `until_ms`, `chosen_data_sf` |
| `tx_blind_defer` | Deferring TX because next-hop is blind | `dst`, `next_hop`, `delay_ms`, `source` |
| `tx_blind_alt` | Switching to alt because primary is blind | `dst`, `from_next`, `to_next` |

### 13.5 LBT / duty cycle / runtime

| Event | Trigger | Key data |
|---|---|---|
| `tx_lbt_defer` | tx_initiating / tx_flood deferred for LBT | `label`, `defer_ms`, `busy_until_ms` |
| `tx_flood_skipped` | Flood dropped past max-defer | `label`, `busy_for_ms` |
| `duty_cycle_blocked` | Pre-check denied a TX | `label`, `airtime_ms`, `used_ms`, `wait_ms` |
| `radio_busy` | Runtime fired on_radio_busy | `reason`, `label`, `busy_until_ms` |
| `tx_giveup` | tx_stash retries exhausted | `label`, `reason` |

---

## 14. Configuration reference

All knobs are read in `on_init` from `config` (the per-node table in
the JSON scenario). Defaults shown.

### 14.1 Radio

| Key | Default | Description |
|---|---|---|
| `routing_sf` | 7 | SF for BCN, RTS, ACK |
| `allowed_data_sfs` | `{12}` | SFs offered in RTS bitmap; receiver picks |
| `sf_margin_db` | 5.0 | Headroom required above demod threshold for SF pick |
| `bw_hz` | 250000 | LoRa BW in Hz (override of `_sim_bw_hz`) |
| `cr` | 5 | Coding rate (5..8 = CR4/5..CR4/8) |
| `preamble_sym` | 16 | LoRa preamble symbol count |

### 14.2 Beacon

| Key | Default | Description |
|---|---|---|
| `beacon_period_warmup_ms` | 5000 | Period during warmup_ms |
| `beacon_period_ms` | 300000 | Operational period (5 min) |
| `beacon_max_bytes` | 200 | Max beacon frame size |
| `beacon_trigger_jitter_min_ms` | 50 | Triggered beacon delay min |
| `beacon_trigger_jitter_max_ms` | 500 | Triggered beacon delay max |
| `quiet_threshold_ms` | 30000 | Adaptive throttle silence requirement |
| `beacon_silence_jitter_ms` | 10000 | Defer-jitter after silence detected |

### 14.3 Data plane

| Key | Default | Description |
|---|---|---|
| `cts_to_data_gap_ms` | 5 | Originator pause between CTS-rx and DATA-tx |
| `rts_timeout_ms` | computed | airtime(routing_sf, RTS) + airtime(data_sf, CTS) |
| `rts_busy_retry_ms` | 30 | Retry delay when our retry timer fires while we're mid-RX |
| `rts_max_retries` | 8 | RTS retry budget. Bumped from 3 to 8 with the F1 work so the exponential `rts_timeout` backoff (×2 capped at ×4) can cover a full receiver blind window even when the CTS we'd have overheard was lost in flight. |
| `max_payload_bytes` | 50 | Receiver's pending_rx_expiry budget cap |
| `last_acked_ttl_ms` | 10000 | last_acked_from cache TTL |
| `seen_origin_ttl_ms` | 30000 | End-to-end dedup TTL |
| `send_defer_ttl_ms` | 30000 | Deferred originator-send hold window — see §11a |
| `rt_aging_ttl_ms` | 600000 | Stale-route eviction threshold — see §6.5 |
| `rt_aging_check_period_ms` | 60000 | Aging-scan period — see §6.5 |

### 14.4 Channel access

| Key | Default | Description |
|---|---|---|
| `lbt_enabled` | false | Pre-check `channel_busy_until` before TX |
| `retry_jitter_ms` | one RTS-airtime | RTS retry randomization width |
| `flood_lbt_max_defer_ms` | one beacon-airtime | LBT defer cap for FLOOD |
| `duty_cycle` | 0.01 | ETSI EN 300 220 default |
| `duty_cycle_window_ms` | 3600000 | 1-hour rolling window |

### 14.5 Mesh / network

| Key | Default | Description |
|---|---|---|
| `network_id` | 0 | 4-bit mesh identifier; receivers reject foreign |

### 14.6 Runtime-injected (don't override unless you know why)

| Key | Source | Description |
|---|---|---|
| `_sim_warmup_ms` | runtime | Warmup window from simulation config |
| `_sim_bw_hz` | runtime | Resolved BW in Hz from radio block |
| `_sim_cr` | runtime | Resolved CR from radio block |
| `_sim_duty_cycle` | runtime | Resolved duty_cycle from radio block |
| `_sim_duty_cycle_window_ms` | runtime | Resolved window from radio block |

---

## 15. Known limitations

### 15.1 Address-assignment story unresolved

8-bit short node IDs are a **simulator-only convenience**. In a real
deployment with hardware-derived IDs, two networks would routinely
have overlapping short IDs. `network_id` filters at the mesh layer
prevent the immediate failures, but doesn't solve the underlying
"how does a new node get a unique short ID at boot" question.

The intended path: two-tier addressing (LoRaWAN OTAA-style):

- Long EUI (e.g., 32-bit hardware-hash) for join handshake.
- Short address (8-bit) assigned by the network on join.
- Conflict resolution on partition merge.
- Address recycling after long node-absent timeout.

This is its own design phase — see
`memory/project_address_assignment_unfinished.md`.

### 15.2 BCN msg_id dedup not protected by network_id alone

The network_id filter prevents foreign beacons from being merged into
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
`last_seen_ms` exceeds `rt_aging_ttl_ms` (default 10 min). Both
primary and alts are subject to the same TTL. Direct neighbours get
their last_seen refreshed on every on_recv (not just beacons) so
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

### 15.7 BCN doesn't yet bit-pack entries

BCN entries are 4 bytes each (dest + next + score_i8 + hops). At ~10
neighbors per node, this is ~40 bytes of advertised routing per
beacon. Bit-packing entries (e.g., dest 8 + next 8 + score 6 + hops
4 = 26 bits = 3.25 bytes) saves ~25% per beacon. Not done; deferred.

---

*This document is generated from `scenarios/dv_dual_sf.lua` at git
HEAD. When the protocol changes, regenerate by reading the lua and
updating each section. Every numeric value and behavioral claim
should grep to a specific line of the script.*
