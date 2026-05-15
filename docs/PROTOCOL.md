# LoRa Mesh Protocol — `dv_dual_sf` Reference

Implementation-grade reference for the protocol implemented in
`scenarios/dv_dual_sf.lua`. Everything in this document traces to
specific lines of that script as of git `HEAD`.

The protocol is **distance-vector routing on a control SF + per-hop
unicast handshake on an adaptive data SF**. Hop-level reliability is
achieved through an explicit RTS/CTS/DATA/ACK exchange. Routing is
maintained through periodic + triggered beacons. Two networks can
coexist on the same channel via a 4-bit `leaf_id` filter.

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
9. [Cross-network filtering (`leaf_id`)](#9-cross-network-filtering-leaf_id)
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

### 3.1 Beacon (`'B'`) — 4 + [1+4L]? + 3n + [32]? + [1+ext]? bytes

Wire format (see ROADMAP §7.0.2 for the full bit-assignment rationale):

```
byte:  0      1                                        2     3
       ┌───┬──────────────────────────────────────────┬─────┬──────────────┐
       │'B'│ leaf_id(4) │ has_schedule(1) │           │ src │S│E│n_entries │
       │   │ self_gateway(1) │ is_mobile(1) │ rsv(1)  │     │ │ │ (6b)     │
       └───┴──────────────────────────────────────────┴─────┴──────────────┘

if has_schedule == 1 (optional schedule block):
  byte 4:       layer_count(8)
  bytes 5..(4 + 4×layer_count):
                schedule records (4 B each — parser SKIPS; no node sets
                has_schedule=1 yet; reserved for future §7.3 TDM)

  schedule record (4 bytes):
       ┌─────────────────────────────┬──────────────────┬──────────────────┬──────────┐
       │ layer(4) │ (sf-5)(3) │ rsv(1)│ duration_100ms(8)│ offset_from_bcn(8)│ rsv(8) │
       └─────────────────────────────┴──────────────────┴──────────────────┴──────────┘

route entries × n_entries (3 bytes each, start after optional schedule block):
       ┌──────┬──────┬────────────────────────────────────────┐
       │ dest │ next │ score_bucket(4) │ (hops-1)(3) │ is_gw(1) │
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
```

**Byte-1 flag bits:**
- `leaf_id` (4 bits, 7:4): admin-managed mesh identifier. Receivers
  reject foreign-network beacons before any rt_merge work.
- `has_schedule` (1 bit, 3): when 1, a schedule block follows immediately
  after `n_entries`. Currently always 0; reserved for §7.3 inter-layer TDM.
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
  `beacon_max_entries`, default 49 for a 151-byte frame).

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

**Route entry byte 2 bit fields:**
- `score_bucket` (4 bits, 7:4): chain-min SNR quantized to a 4-bit bucket
  via `bucket_of_snr_4b` (16 buckets, 2 dB resolution, range −20..+10 dB).
  Decoded via `snr_of_bucket_4b`. ACK uses a separate 2-bit coarse SNR
  encoding so it can also carry budget back-pressure plus an addressed
  recipient byte.
- `(hops-1)` (3 bits, 3:1): wire carries `hops − 1` (range 0..7). In-memory
  `rt[]` candidates store decoded `hops` (range 1..8). The 8-hop cap is
  preserved: `combined_hops > 8` routes are rejected at the receiver.
- `is_gateway` (1 bit, 0): the advertised path's terminal node is a gateway.
  Per-candidate storage in `rt[]`; the data plane reads it from the primary
  candidate. Different advertisers may disagree; route-selection picks
  among candidates by score, and the chosen candidate's `is_gateway` is
  authoritative.

**Frame size:** default route-entry page is 151 bytes = 4-byte header +
49 × 3-byte entries (no schedule block). If `S=1`, add 32 bytes after the
route-entry block. A gateway BCN with L upper layers adds 1 + 4L bytes.

**Pre-bit-pack history:** before Phase 1-2 entries were 4 bytes
(`dest + next + score_i8(8) + hops(8)`) and the default was 200 bytes.
Phase 2 packed entries to 3 bytes (−24.5% airtime). Phase 3 (this spec)
repacked byte 1 to add flag bits and repacked entry byte 2 to add the
`is_gateway` bit and use the `hops-1` encoding.

### 3.2 RTS (`'R'`) — 8 bytes (in-leaf)

Per ROADMAP §7.0.3. `origin` removed from wire — destination identifies the
originator from the inner DATA payload (Phase 4). Forwarders never needed origin
on the RTS wire. Future cross-layer hops add +1 byte per boundary; addr_len
encodes depth.

```
byte:  0   1    2    3                        4    5                   6           7
       ┌───┬────┬────┬────────────────────────┬────┬───────────────────┬───────────┬─────────────┐
       │'R'│ src│next│ addr_len (3 hi)        │dst │ ctr_lo (4 hi)     │ sf_bitmap │ payload_len │
       │   │    │    │ rsv (1)                │    │ rsv (4 lo)        │           │             │
       │   │    │    │ leaf_id (4 lo)         │    │                   │           │             │
       └───┴────┴────┴────────────────────────┴────┴───────────────────┴───────────┴─────────────┘
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
- `leaf_id` (4 bits, lo of byte 3): mesh identifier. Receivers reject
  foreign-network RTSes before any CTS work. Pattern-matches DATA byte 1
  (both have `addr_len` in top 3 bits).
- `dst` (8 bits): end-to-end destination; single byte when `addr_len=0`.
- `ctr_lo` (4 bits, hi nibble of byte 5): per-flight counter, wraps at 16.
  Combined with `last_acked_from`'s 10s TTL gives correct hop-level
  retry dedup at any realistic send rate. Low nibble of byte 5 is reserved.
- `sf_bitmap` (8 bits): bit `i` set means SF `i+5` is acceptable for
  the data leg. e.g., `0b00001110` = {SF6, SF7, SF8}.
- `payload_len` (8 bits): byte count of the upcoming DATA inner bytes
  plus MAC (= `#inner + MAC_LEN`). Lets the receiver size
  `pending_rx_expiry` to actual airtime instead of worst-case.

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

### 3.4 DATA (`'D'`) — 10 + n bytes (in-leaf, addr_len=0)

Per ROADMAP §7.0.1. E2E flags moved from inner payload header to wire byte 1.
16-bit `ctr` replaces the 3-byte inner origin-header. 4-byte zero MAC placeholder
added (crypto stub, will carry Poly1305-truncated under §8).

```
byte:  0    1                        2     3    4    5     6...(5+n)  last 4
       ┌────┬────────────────────────┬─────┬────┬────┬──── ┬──────────┬───────┐
       │'D' │ addr_len (3 hi)        │ next│ dst│ctr │ ctr │ciphertext│  MAC  │
       │    │ rsv (1)                │     │    │ lo │ hi  │ (n+2 B)  │ (4 B) │
       │    │ E2E_ACK_REQ (1)        │     │    │    │     │          │ zeros │
       │    │ E2E_IS_ACK (1)         │     │    │    │     │          │       │
       │    │ IS_MULTICAST (1)       │     │    │    │     │          │       │
       │    │ rsv (1)                │     │    │    │     │          │       │
       └────┴────────────────────────┴─────┴────┴────┴─────┴──────────┴───────┘

Total: 10 + n bytes for in-leaf (addr_len=0). n = body bytes.

ciphertext slot (= plaintext today):
  byte 6  : src_addr_len (= 0 for in-leaf / flat addresses this phase)
  byte 7  : src_addr     (origin's 8-bit mesh id; 1 byte when src_addr_len=0)
  bytes 8+: body         (user text for normal DATA; [acked_ctr_lo, acked_ctr_hi] for E2E ACK)

byte 1 flag bits (low to high):
  bit 0 (0x01): reserved
  bit 1 (0x02): IS_MULTICAST  (always 0 this phase — multicast deferred)
  bit 2 (0x04): E2E_IS_ACK    (this DATA IS an E2E ACK; body = [acked_ctr_lo, acked_ctr_hi])
  bit 3 (0x08): E2E_ACK_REQ   (origin requests end-to-end confirmation)
  bit 4 (0x10): reserved      (gained from shrinking addr_len from 4 to 3 bits)
  bits 5-7:     addr_len       (always 0 this phase — hierarchy deferred)

hop-level ctr_lo: low nibble of ctr (ctr & 0xf), used for pending_rx matching.
```

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
- `MAC` (4 bytes, all-zero placeholder): will carry Poly1305-truncated tag
  once §8 crypto lands. Receiver ignores MAC bytes today.
- In-leaf size: 10 + n bytes (vs 8 + n before §7.0.1). The +2 B overhead
  is the crypto/privacy stub cost; wire layout is identical once §8 lands.

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

### 3.7 Q (`'Q'`) — 4 bytes (query/control)

```
byte:  0   1     2      3
       ┌───┬─────┬──────┬───────────────────────────────────┐
       │'Q'│ src │ dest │ leaf_id (4 hi)                    │
       │   │     │      │ opcode/mobile flags (4 lo)        │
       └───┴─────┴──────┴───────────────────────────────────┘
```

- `src` (8 bits): the requester's node id.
- `dest` (8 bits): destination for `ROUTE_QUERY`; `0xff` for `REQ_SYNC`.
- `leaf_id` (4 bits): mesh identifier. Receivers reject foreign-
  network Q frames.
- low nibble:
  - bits 0-1: opcode (`0=ROUTE_QUERY`, `1=REQ_SYNC`)
  - bit 2: requester is mobile
  - bit 3: reserved

One-hop only — receivers don't forward Q frames.

**ROUTE_QUERY sender behaviour:** in `issue_send` for an originator, when
`rt[dst]` is missing, alongside the defer-queue push (§11a.2) we
also fire a Q to actively request the route from neighbours.
Whichever brings the route in faster (passive defer wait or active
Q response) wins. Dedup at sender via `q_queried[dest]` (default
TTL 5 s) prevents Q-spam for repeated sends to the same unknown.

**ROUTE_QUERY receiver behaviour:** dedup via `q_responded_to[opcode,src,dest]` (default
TTL 10 s) prevents responding to the same query multiple times — if
multiple neighbours hear the same Q, the existing triggered-beacon
jitter (50-500 ms) spreads their responses naturally. Receivers
without the requested route silent-drop (someone else may respond).

Special cases:
- `q.src == self.id`: loop guard, drop.
- `q.dest == self.id`: someone's asking for ME; schedule triggered
  beacon (receivers learn us via the BCN src field, not entries).

**REQ_SYNC behaviour:** during node-local DISCOVERY, a node whose route
table is still poor may send `Q{opcode=REQ_SYNC,dest=0xff}` after a
listen window. The request carries whether the requester is mobile.
Eligible neighbours schedule a full `kind=sync` BCN response with
randomized backoff. Mobile responders add extra backoff, and any
responder suppresses its pending sync response if it hears another
useful BCN before its timer fires. This lets one good neighbour satisfy
a joiner without all nearby nodes transmitting full BCNs at once.

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

### 3.8 Frame-size summary

| Frame | Bytes | Notes |
|---|---|---|
| BCN | 4 + 3n (plain leaf); 4 + [1 + 4L] + 3n (gateway w/ L upper-layer schedule records) | n entries (3 B each, bit-packed); default cap 49 → max ~151 B for plain leaf |
| Q   | 4      | RREQ-route (one-hop) |
| RTS | 8 | fixed |
| CTS | 3 | fixed; addressed response |
| DATA | 10 + n | in-leaf (addr_len=0): 6 B hdr + 2 B inner-hdr + n B body + 4 B MAC |
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
silent, the sender defers the packet and emits `Q:ROUTE_QUERY` instead of
burning more RTS attempts. BCN/DV route entries whose advertised second hop
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
busy. Routes learned during discovery then age out (~10-30 min later)
with no fresh advertisements arriving, and the network can collapse
into a stable 0%-delivery state.

The override: if a node hasn't BCN'd in `beacon_max_idle_ms`
(default **900 s = 15 min**, comfortably below the 30 min default
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
  (default **30 min**)
- `hops >= 2` (remote multi-hop) → `rt_aging_ttl_remote_ms`
  (default **90 min**)

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
| `rt_aging_ttl_neighbor_ms` | 1800000 (30 min) | Direct-neighbour candidate expires if not refreshed within this window |
| `rt_aging_ttl_remote_ms` | 5400000 (90 min) | Multi-hop candidate expires if not refreshed within this window |
| `rt_aging_check_period_ms` | 60000 (1 min) | How often the aging scan runs |

Set both TTLs to 0 to disable aging (memory leak risk in long-lived
deployments; useful for tests).

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
                                on_recv "R", leaf_id ok, next == self.id
                                ↓
                                set_rx_sf(data_sf)              data_sf
                                pending_rx = {from=alice, ctr_lo, ...}
                                start_pending_rx_expiry
                                pack_cts(ctr_lo, chosen_sf)
                                tx 'C' on data_sf
                          <─C──
on_recv "C", matches pending_tx.ctr_lo              data_sf
cancel rts_timeout
after cts_to_data_gap_ms:
  pack_data → tx 'D' on data_sf
  set_rx_sf(routing_sf)        routing_sf
  start_ack_timeout
                          ─D──>
                                on_recv "D", matches pending_rx.ctr_lo
                                ↓
                                cancel pending_rx_expiry
                                set_rx_sf(routing_sf)           routing_sf
                                pending_rx = nil
                                last_acked_from[alice] = {ctr_lo, t_ms}
                                pack_ack(ctr_lo, meta.snr, budget_hint) →
                                tx 'K' on routing_sf
                          <─K──
on_recv "K", matches pending_tx.ctr_lo
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
    tx 'N' on data_sf
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
| ACK lost | ack_timeout at sender + last_acked_from at receiver | Retry RTS; receiver short-circuits with CTS `already_received=1` (`rts_already_acked`) |
| Routing-table mismatch | rts_giveup after K alts | path_cascade_exhausted; flight dropped, sender app-layer aware |

---

## 9. Cross-network filtering (`leaf_id`)

A 4-bit network identifier in BCN and RTS lets multiple LoRa meshes
coexist on the same channel. Receivers reject foreign-network frames
**before any other work**:

```
on_recv 'B':
  if b.leaf_id ~= self.leaf_id: return  (silent drop)
  ... rt_merge ...

on_recv 'R':
  if r.leaf_id ~= self.leaf_id: return  (silent drop)
  ... CTS / forwarding logic ...
```

Without this filter, two networks merging during enhanced RF
propagation events (30-40 km tropo ducting) would:

1. Attempt CTSes for foreign RTSes (wasted airtime + collisions).
2. Pollute routing tables with foreign nodes (decisions to route via
   non-existent neighbors → flights fail with `rts_giveup`).

`leaf_id` is **externally managed** (admin sets `config.leaf_id`
per node). 4 bits = 16 distinct meshes — sufficient for any 30-40 km
propagation circle in practice.

CTS/DATA/ACK/NACK don't carry `leaf_id` because they're matched
against `pending_tx`/`pending_rx` state set by an already-validated
RTS — the check is implicit.

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

Same-ctr_lo retries within `originator_retry_dedup_ms` (default 10 s)
count once each — a legitimate originator's `rts_max_retries × K`
alts don't inflate R[X].

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

**Privacy-compatible.** The classifier observes physical-layer
`meta.src`, not the wire `origin` field. Composes with §9 T2
(origin-in-encrypted-payload) without changes.

**Measured impact** (s04 60-min, 360 sends, 16 active originators):
delivery unchanged at ~52%; 141 silent drops total (down from 3505 in
a pre-dedup measurement — the ctr_lo dedup cut false positives by
96%); 94 self-over-budget emits caught legitimate "over fair-share
but not necessarily malicious" senders.

**Configuration knobs** — see §14.4a.

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
plus throughput counters since last snapshot.

```
state_snapshot_period_ms (default 60000 = 1 min)
  → emit node_state_snapshot { ... } and reschedule
```

Set `state_snapshot_period_ms = 0` to disable.

---

## 11a. Bootstrap UX (cold-start joiners)

The "new user installs the app, opens it, immediately taps send" case
needs explicit handling — without it, the user sees a silent drop and
abandons the app. Two mechanisms:

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

If the deferred send was waiting on an active `Q:ROUTE_QUERY`, draining
does not immediately RTS. The send is moved to `tx_queue` with
`next_attempt_ms = now + settle`, where settle lasts until
`q_sent_at_ms + q_response_settle_ms` plus small jitter. This lets most
nearby Q-response BCNs finish before the first DATA RTS, avoiding the
hidden-terminal pattern where a requester hears the first useful BCN,
immediately RTSes, and collides at the chosen next-hop with a late BCN
from another responder.

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
| `q_response_settle_ms` | trigger jitter max + max BCN airtime + LBT backoff | Hold a Q-drained send until most Q-response BCNs have finished |
| `q_response_settle_jitter_ms` | `lbt_backoff_ms` | Extra random spread before first RTS after Q discovery |

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
| `leaf_id` | int | 4-bit mesh identifier |
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
| `beacon_rx` | Beacon decoded | `src`, `n_entries`, `seen_bits`, `suspect_nodes` |
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
| `rts_attempt_detail` | Sender-side focused RTS attempt telemetry | `attempt_seq`, `origin`, `dst`, `next`, `ctr_lo`, `candidate_rank`, `candidate_count`, `route_score`, `route_score_eff`, `budget_penalty_db`, `suspect_penalty_db`, `viable_alts`, `route_hops`, `route_age_ms`, `next_tier`, `next_suspect_level`, `next_seen_fresh`, `next_seen_age_ms`, `next_blind` |
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
| `q_tx` | Q (RREQ-route) emitted by sender (§3.7) | `dst`, `dst_name` |
| `q_rx` | Q decoded; receiver matches leaf_id | `from`, `dest` |
| `forward_fail` | Forwarder dropped (no route, no budget, etc.) | `origin`, `dst`, `reason` |
| `retune_for_data` | RX retuned for DATA reception | `from`, `ctr_lo`, `chosen_data_sf` |
| `e2e_ack_pending` | Originator registered a `send_e2e` and is waiting for E2E ACK (§7.4) | `dst`, `ctr`, `ttl_ms` |
| `e2e_ack_tx_enqueued` | Destination enqueued the return E2E ACK frame (§7.4) | `to`, `acked_ctr` |
| `delivered_confirmed` | Originator received the E2E ACK matching a pending send (§7.4) | `dst`, `acked_ctr`, `rtt_ms` |
| `e2e_ack_unmatched` | E2E ACK arrived but no matching `pending_e2e` entry (§7.4) | `from`, `acked_ctr`, `reason` (`duplicate` / `already_timed_out`) |
| `e2e_ack_timeout` | Pending E2E ACK exceeded `e2e_ack_ttl_ms` (§7.4) | `dst`, `ctr`, `waited_ms` |

### 13.3 Failure / cascade

| Event | Trigger | Key data |
|---|---|---|
| `rts_giveup` | RTS exhausted retries | `origin`, `dst`, `ctr_lo`, `last_next_hop` |
| `data_ack_giveup` | ACK timeout exhausted | `origin`, `dst`, `ctr_lo` |
| `path_cascade` | Switching to next alt after K=3 cascade fired | `from_next`, `to_next`, `attempt`, `trigger` |
| `path_cascade_exhausted` | All K alts tried AND requeue caps hit (§5.6) | `dst`, `tried`, `trigger` |
| `cascade_requeue` | All K alts tried; pushed back to tx_queue with backoff (§5.6) | `dst`, `ctr_lo`, `requeue_count`, `backoff_ms`, `total_age_ms`, `trigger` |
| `cascade_load_skip` | Cascade-requeue dropped early due to local load (§5.6 Phase D3) | `dst`, `ctr_lo`, `queue_depth`, `load_threshold`, `effective_max` |

### 13.4 F1 blind-window mitigation

| Event | Trigger | Key data |
|---|---|---|
| `blind_observed` | CTS overheard, blind_until extended | `for_node`, `until_ms`, `chosen_data_sf` |
| `tx_blind_defer` | Deferring TX because next-hop is blind | `dst`, `next_hop`, `delay_ms`, `source` |
| `tx_blind_alt` | Switching to alt because primary is blind | `dst`, `from_next`, `to_next` |

### 13.4a Anti-spam (1st-hop rate-limit, §10a)

| Event | Trigger | Key data |
|---|---|---|
| `rts_drop_originator_throttle` | RTS silently dropped because direct sender exceeded fair-share quota | `from`, `ctr_lo`, `apparent_origination`, `airtime_share` |
| `originator_self_over_budget` | On terminal failure, originator's own send count is over half-threshold OR own duty tier ≥ STRAINED — UX hint emitted | `origin_count`, `threshold`, `tier`, `hint` |

### 13.5 LBT / duty cycle / runtime

| Event | Trigger | Key data |
|---|---|---|
| `tx_lbt_defer` | tx_initiating / tx_flood deferred for LBT | `label`, `defer_ms`, `busy_until_ms` |
| `tx_flood_skipped` | Flood dropped past max-defer | `label`, `busy_for_ms` |
| `duty_cycle_blocked` | Pre-check denied a TX | `label`, `airtime_ms`, `used_ms`, `wait_ms` |
| `radio_busy` | Runtime fired on_radio_busy | `reason`, `label`, `busy_until_ms` |
| `tx_giveup` | tx_stash retries exhausted | `label`, `reason` |
| `node_state_snapshot` | Periodic accumulator-diagnostics dump (§11.6) | `tx_queue_depth`, `deferred_sends_depth`, `pending_tx`, `pending_rx`, `rt_size`, `budget_tier`, `pct_used`, plus throughput counters |

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
| `discovery_beacon_period_ms` | 5000 | Fast beacon period while node-local DISCOVERY is active |
| `beacon_period_warmup_ms` | 5000 | Legacy alias for `discovery_beacon_period_ms` |
| `beacon_period_ms` | 900000 | Operational period (15 min) |
| `discovery_ms` | 60000 | Max node-local discovery duration after boot |
| `beacon_boot_grace_ms` | 120000 | After boot, allow fast triggered BCNs despite the steady-state minimum interval |
| `discovery_min_bcn_rx` | 3 | Exit discovery after this many BCN receptions |
| `discovery_min_routes` | 8 | Exit discovery after this many route-table destinations |
| `beacon_max_bytes` | 151 | Max beacon frame size — 4-byte header + 49 × 3-byte entries (post-bit-pack default; was 200 with 4-byte entries) |
| `beacon_trigger_jitter_min_ms` | 2000 | Triggered beacon coalescing delay min |
| `beacon_trigger_jitter_max_ms` | 10000 | Triggered beacon coalescing delay max |
| `beacon_trigger_min_interval_ms` | 120000 | Steady-state minimum interval between this node's successful BCN TX and a triggered BCN |
| `quiet_threshold_ms` | 30000 | Adaptive throttle silence requirement |
| `beacon_silence_jitter_ms` | 10000 | Defer-jitter after silence detected |
| `beacon_max_idle_ms` | 900000 (15 min) | Max idle before busy throttle is bypassed (§6.2). Set to 0 to disable. |
| `peer_suspect_bcn_max` | 8 | Max suspected node ids carried in one BCN extension TLV. Wire TLV caps this at 15. |

### 14.3 Data plane

| Key | Default | Description |
|---|---|---|
| `cts_to_data_gap_ms` | 5 | Originator pause between CTS-rx and DATA-tx |
| `rts_timeout_ms` | computed | airtime(routing_sf, RTS) + airtime(data_sf, CTS) |
| `rts_busy_retry_ms` | 30 | Retry delay when our retry timer fires while we're mid-RX |
| `rts_max_retries` | 3 | RTS retry budget. Was 8 before fix `7ba772c` (drop pending_tx NACK + cap retries). With base ~5 s `rts_timeout` under load, 8 retries = ~30+ s per next-hop before alt-switching; 3 retries = ~12 s per next-hop, ~36 s across K=3 alts. Bounds wallclock pending_tx time so a stuck flight clears faster. |
| `route_snr_conservatism_db` | 3.0 | SNR subtracted before storing route candidate score, so marginal control-plane samples do not over-promote DATA paths. |
| `next_hop_live_ttl_ms` | 1200000 | Hard route-selection freshness TTL for immediate next-hop liveness. Shorter than destination route TTL. |
| `peer_suspect_rts_timeouts` | 2 | Consecutive RTS timeouts before a next-hop is marked suspect. |
| `peer_silent_rts_timeouts` | 3 | Consecutive RTS timeouts before a next-hop is marked silent. |
| `peer_dead_rts_timeouts` | 6 | RTS timeouts before a next-hop can be promoted to explicit dead, subject to the evidence window. |
| `peer_suspect_ttl_ms` | 300000 | Suspect mark TTL. |
| `peer_silent_ttl_ms` | 900000 | Silent mark TTL. |
| `peer_dead_ttl_ms` | 3600000 | Dead mark TTL; cleared immediately by any valid frame from that node. |
| `peer_dead_evidence_window_ms` | 900000 | Minimum elapsed time from first RTS timeout before dead promotion. |
| `peer_suspect_penalty_db` | 12.0 | Effective route-score penalty for suspect next-hops. |
| `peer_silent_penalty_db` | 40.0 | Effective route-score penalty for silent next-hops. |
| `peer_dead_penalty_db` | 80.0 | Effective route-score penalty for dead next-hops. |
| `max_payload_bytes` | 50 | Receiver's pending_rx_expiry budget cap |
| `last_acked_ttl_ms` | 10000 | last_acked_from cache TTL |
| `seen_origin_ttl_ms` | 30000 | End-to-end dedup TTL |
| `send_defer_ttl_ms` | 30000 | Deferred originator-send hold window — see §11a |
| `q_query_ttl_ms` | 5000 | Sender Q dedup window — don't re-fire for same dest (§3.7) |
| `q_respond_ttl_ms` | 10000 | Responder Q dedup window — don't re-respond to same (opcode,src,dest) (§3.7) |
| `q_response_settle_ms` | trigger jitter max + max BCN airtime + LBT backoff | Hold first RTS after `Q:ROUTE_QUERY` until most response BCNs finish (§11a.2) |
| `q_response_settle_jitter_ms` | `lbt_backoff_ms` | Extra random spread for Q-drained sends |
| `req_sync_on_boot` | true | During DISCOVERY, send `Q:REQ_SYNC` if route table remains poor |
| `req_sync_listen_ms` | 8000 | Listen before first boot-time `REQ_SYNC` |
| `req_sync_retry_ms` | 30000 | Retry interval for boot-time `REQ_SYNC` while still in DISCOVERY |
| `req_sync_min_routes` | `discovery_min_routes` | Suppress boot-time `REQ_SYNC` once this many routes are known |
| `sync_response_enabled` | true | Allow node to answer `Q:REQ_SYNC` with full sync BCN |
| `sync_response_min_routes` | 1 | Minimum route count before answering `REQ_SYNC` |
| `sync_response_backoff_min_ms` | 500 | Min randomized sync-response delay |
| `sync_response_backoff_max_ms` | 6000 | Max randomized sync-response delay |
| `sync_response_mobile_penalty_ms` | 8000 | Extra delay when responder is mobile |
| `sync_response_requester_mobile_penalty_ms` | 2000 | Extra delay when requester is mobile |
| `sync_response_suppress_window_ms` | 12000 | Suppress pending response after hearing another useful BCN |
| `rt_aging_ttl_neighbor_ms` | 1800000 (30 min) | Direct-neighbour candidate TTL — see §6.5 |
| `rt_aging_ttl_remote_ms` | 5400000 (90 min) | Multi-hop candidate TTL — see §6.5 |
| `rt_aging_check_period_ms` | 60000 | Aging-scan period — see §6.5 |
| `cascade_requeue_max` | 3 | Phase C — max cascade-exhaust requeues before drop (§5.6) |
| `cascade_requeue_base_ms` | 5000 | Phase C — base backoff (exponential: base × 2^(count-1)) |
| `cascade_requeue_backoff_cap_ms` | 30000 | Phase C — backoff caps at this value |
| `cascade_requeue_total_max_ms` | 60000 | Phase C — total wallclock cap; older items drop (was 120000 pre-D3) |
| `cascade_requeue_load_threshold` | 0 | Phase D3 — local tx_queue depth above which the effective requeue budget shrinks (§5.6) |
| `state_snapshot_period_ms` | 60000 | Period for `node_state_snapshot` event (§11.6); 0 = disable |
| `e2e_ack_ttl_ms` | 60000 | E2E delivery ACK pending-entry TTL at originator (§7.4) — after this, emit `e2e_ack_timeout` |

### 14.4 Channel access

| Key | Default | Description |
|---|---|---|
| `lbt_enabled` | true | Pre-check `channel_busy_until` before initiating/flood TX |
| `lbt_backoff_ms` | half RTS-airtime | Random slack added after `busy_until` for LBT defers |
| `retry_jitter_ms` | one RTS-airtime | RTS retry randomization width |
| `flood_lbt_max_defer_ms` | one beacon-airtime | LBT defer cap for FLOOD |
| `duty_cycle` | 0.01 | ETSI EN 300 220 default |
| `duty_cycle_window_ms` | 3600000 | 1-hour rolling window |
| `budget_strained_pct` | 50 | ≤ this % used → HEALTHY tier; > → STRAINED (§11.5) |
| `budget_critical_pct` | 80 | > this → CRITICAL (budget-NACK + own-beacon-skip kick in) |
| `budget_exhausted_pct` | 95 | > this → EXHAUSTED |
| `budget_blind_strained_ms` | 60000 (1 min) | Sender-side blind window after STRAINED budget-NACK |
| `budget_blind_critical_ms` | 180000 (3 min) | Same, for CRITICAL |
| `budget_blind_exhausted_ms` | 300000 (5 min) | Same, for EXHAUSTED |
| `neighbor_budget_tier_ttl_ms` | 300000 (5 min) | Tier-aware routing — last-known peer tier expires after this; saturated peers return to primary pool when no fresh NACK |

### 14.4a Anti-spam (1st-hop rate-limit)

Reactive count-based originator throttle at every 1st-hop neighbour.
Works under §9 T2 privacy (observes physical-layer `meta.src`, not the
wire `origin`).

| Key | Default | Description |
|---|---|---|
| `originator_window_ms` | 300000 (5 min) | Sliding window for per-direct-sender RTS/CTS observation counts |
| `originator_max_per_window` | 6 | Apparent-origination threshold per window (≈72/hr); over → silent-drop inbound RTS |
| `originator_airtime_share` | 0.25 | Per-sender airtime backstop; > this fraction of N's own duty cycle → silent-drop regardless of count |
| `originator_retry_dedup_ms` | 10000 | Same-ctr_lo retries within this window count as ONE origination (don't inflate `R[X]` with retries) |
| `originator_self_warn_fraction` | 0.5 | Originator's self-monitor threshold = this × `originator_max_per_window`; on terminal failure, emit `originator_self_over_budget` |

### 14.5 Mesh / network

| Key | Default | Description |
|---|---|---|
| `leaf_id` | 0 | 4-bit mesh identifier; receivers reject foreign |

### 14.6 Runtime-injected (don't override unless you know why)

| Key | Source | Description |
|---|---|---|
| `_sim_bw_hz` | runtime | Resolved BW in Hz from radio block |
| `_sim_cr` | runtime | Resolved CR from radio block |
| `_sim_duty_cycle` | runtime | Resolved duty_cycle from radio block |
| `_sim_duty_cycle_window_ms` | runtime | Resolved window from radio block |

---

## 15. Known limitations

### 15.1 Address-assignment story unresolved

8-bit short node IDs are a **simulator-only convenience**. In a real
deployment with hardware-derived IDs, two networks would routinely
have overlapping short IDs. `leaf_id` filters at the mesh layer
prevent the immediate failures, but doesn't solve the underlying
"how does a new node get a unique short ID at boot" question.

The intended path: two-tier addressing (LoRaWAN OTAA-style):

- Long EUI (e.g., 32-bit hardware-hash) for join handshake.
- Short address (8-bit) assigned by the network on join.
- Conflict resolution on partition merge.
- Address recycling after long node-absent timeout.

This is its own design phase — see
`memory/project_address_assignment_unfinished.md`.

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
use `rt_aging_ttl_neighbor_ms` (default 30 min), multi-hop entries
use `rt_aging_ttl_remote_ms` (default 90 min). Direct-neighbour
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
