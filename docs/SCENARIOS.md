# Protocol scenarios — operational walk-throughs

Time-ordered swimlanes for every critical interaction in the protocol —
beacon, data-plane (happy + failure modes), routing/control, and join.
Each scenario shows who emits what, in what order, with what state
mutations and telemetry events.

Authoritative behaviour comes from `scenarios/dv_dual_sf.lua` (the
firmware-equivalent script). Wire formats are specified in
`docs/PROTOCOL.md`. Future / planned work lives in `docs/ROADMAP.md`.
This document is the **operational view** — how the pieces interact in
practice. Where current Lua diverges from the design, the **Status:**
note calls it out.

## Conventions

- Time markers (`t=Nms`) are scenario-relative, not wall-clock.
- Swimlane columns are nodes; arrows in the middle show wire frames; SF
  annotations on the right edge show which spreading factor the receiver
  is currently on (most frames ride `routing_sf`; DATA rides `data_sf`).
- State annotations appear on the side performing the change, inline
  with the time axis.
- `id_bind[N]` is the local (per-node) table mapping observed `node_id N`
  to the `key_hash32` currently believed to own it, with confidence
  (`weak` | `claimed` | `authenticated`).
- Frame tags: `B` = Beacon, `R` = RTS, `C` = CTS, `D` = DATA, `K` = ACK,
  `N` = NACK, `Q` = Query, `J` = Join.
- Emitted events are referenced by name; see PROTOCOL.md §13 for the
  payload of each.

## Index

| § | Scenario | One-liner |
|---|---|---|
| 1.1 | BCN periodic emit + receive | Normal beacon cycle and how listeners merge it into rt[] and id_bind[] |
| 1.2 | BCN throttle gate | Adaptive suppression of beacons when the channel is busy |
| 1.3 | BCN triggered (route-change cascade) | Routing-table mutation triggers immediate BCN; receivers may cascade |
| 1.4 | Stale-route aging | Per-candidate TTL eviction and the silent "delete" cascade |
| 2.1 | RTS-CTS-DATA-ACK single hop | The happy-path data flight (PROTOCOL.md §7.1 mirror) |
| 2.2 | Multi-hop forward | Forwarder issues second hop after acking inbound |
| 2.3 | E2E ACK round-trip | Opt-in end-to-end confirmation via return DATA frame |
| 3.1 | RTS hits busy receiver → NACK BUSY_RX | Receiver mid-flight for someone else NACKs the new RTS |
| 3.2 | RTS already acked → CTS already_received | ACK-loss recovery via cache + short-circuit |
| 3.3 | Duplicate RTS while mid-flight as receiver | CTS-loss recovery: re-emit CTS with same chosen SF |
| 3.4 | F1 passive CTS overhearing → blind_until | Peers learn a relay is deaf before wasting RTS attempts |
| 3.5 | RTS-timeout cascade | No CTS → exponential backoff → K=3 alt walk → give up |
| 4.1 | Q ROUTE_QUERY / REQ_SYNC | Active route request; BCN is the response |
| 4.2 | Cascade-requeue lifecycle | Stuck flight requeued with backoff so other items can drain |
| 5.1 | Join — happy path | Autonomous LISTEN → DISCOVER → OFFER → CLAIM → ADOPT |
| 5.2 | Join — no neighbours → exhaustion | Re-discover with backoff; `join_discover_exhausted` |
| 5.3 | Join — simultaneous-claim race | Two real joiners pick same id; deterministic tie-break |
| 5.4 | Join — DENY response | Existing owner defends; joiner retries with new id |
| 5.5 | Join — GUARD-window late conflict | Defense-in-depth check before adopting |
| 5.6 | Join — cold-boot storm | 8-node mass-boot; jitter layers explained |
| 5.7 | Join — silent node returns with reused ID | Detection + recovery (defense → tie-break → forced rejoin) both implemented; t60 |
| 5.8 | Join — partition merge | Mechanisms implemented (claim_epoch NV, lease_age, recovery); pair-wise tie-break generalizes to N-node merge |
| 6.1 | Gateway — two-layer scheduled smoke | s09: JOIN learners, different layer SFs, gateway schedule, cross-layer delivery |
| 6.2 | Gateway — full layer separation workbench | s10: route/bind state scoped by `(layer_id,node_id)` |
| 6.3 | Gateway — three-layer stress | s11 (moved to `scenarios/deprecated/`): gateway-picker filtering + schedule-defer across three layers |
| 6.4 | Gateway sweep cycle (mechanism) | offset → activate upper-layer → emit BCN there → return after duration → re-arm |
| 6.5 | Cross-layer envelope handoff (mechanism) | sender packs envelope → gateway resolves binding (or defers and emits `Q:HASH_QUERY` if unknown) → retunes via `tx_layer_id` → forwards in target layer |
| 6.6 | Layer-15 active-avoidance (mechanism) | non-gateway peer defers RTS while a direct gateway is scheduled away |
| 7.1 | Channel gossip — pull cycle (mechanism) | BCN digest → Q_CHANNEL_PULL → DATA(PAYLOAD_TYPE_M) at routing SF → promiscuous overhear by all in-range peers (§3.4.1) |
| 7.2 | Channel gossip — pull-storm dedupe (mechanism) | peer-Q overhear cancels pending pulls; K=3 BCN ads then dirty bit retires the holder. See ROADMAP §3.3 for the full pathology+fix table |
| 7.3 | Channel gossip — Principle 11 gateway guard (mechanism) | gateway addressed as forwarder for M-payload: ACK upstream, DROP forward (cascade rule fills missed delivery). Emits `channel_gateway_drop` |

---

# 1. Beacon plane

## 1.1 BCN periodic emit + receive

Periodic beacons advertise the emitter's `key_hash32`, its `rt[]`
entries (or a dirty subset; see §6.4 of PROTOCOL.md), and optional
extensions. Listeners merge entries into `rt[]`, update `id_bind` from
the BCN's `key_hash32`, and refresh per-neighbour timestamps.

```
Emitter (G)                                Listener (H, direct neighbor)
                                                                  SF
on_beacon_fire (periodic timer):
  if pending_tx or pending_rx:
    emit "beacon_skipped_busy"; skip
  §1.2 throttle gate (see scenario below):
    if since_busy < quiet_threshold_ms:  skip
    else schedule deferred fire with jitter
  §6.4 differential emit:
    pages = build_dirty_pages(rt)  if any dirty
    else full rt[] dump
  pack_bcn:
    byte 0..1: 'B', leaf_id|has_schedule|self_gateway|is_mobile
    byte 2:    src = G.id
    byte 3:    n_entries, has_ext, seen_bitmap_present
    byte 4..7: key_hash32                       (mandatory in every BCN)
    [schedule_records(4×L)]?
    n × route_entry(3 B) = {dest, next, score|hops|is_gateway}
    [seen_bitmap(32B)]?
    [ext TLVs]?
  last_beacon_tx_ms = now
  clear page-dirty flags (differential)
  tx_flood 'B' on routing_sf            routing_sf
                          ─B──>
                                on_recv "B", leaf_id == self.leaf_id
                                else drop ("bcn_drop_foreign_leaf")
                                ↓
                                last_bcn_rx_ms[G] = now
                                last_rx_routing_sf_ms = now   (§1.2 input)
                                id_bind_set(b.src, b.key_hash32,
                                            source="bcn", confidence="claimed")
                                  (if prev.key_hash32 != b.key_hash32:
                                   emit "addr_conflict_observed";
                                   binding NOT overwritten — see §5.7)
                                if seen_bitmap.bit(self.id):
                                  direct_neighbor[G].confirmed = now
                                for entry e in B.entries:
                                  cand = {next=G, score=e.score,
                                          hops=min(e.hops+1, 8),
                                          is_gateway=e.is_gateway,
                                          src_advertiser=G, t=now}
                                  rt_merge(e.dest, cand)
                                if B.has_schedule:
                                  for s in B.schedule_records:
                                    schedule_cache[(G, s.layer)] = s
                                emit "bcn_received"
                                (no reply — BCN is flood-broadcast,
                                 no per-listener ACK)
```

**Status.** Implemented. `key_hash32` is now part of every BCN (8-byte
header; not optional, not Nth-beacon). This makes per-BCN identity
verification automatic and is the load-bearing mechanism for scenario 5.7.

## 1.2 BCN throttle gate

In dense networks, periodic beacons must self-suppress when the
channel is recently active. The gate uses `last_rx_routing_sf_ms`
(updated by every `on_recv` and by the SX1262 PreambleDetected IRQ
equivalent, so SNR variance doesn't defeat the throttle). A max-idle
override + composite B+C filter prevents synchronized bursts and
avoids choking the network with no-information beacons.

```
Throttle gate at G                         Channel inputs (any peer, any frame)
                                                                              SF
                                           on_recv (any frame, routing_sf):
                                             last_rx_routing_sf_ms = now
                                           on_preamble_detected (routing_sf):
                                             last_rx_routing_sf_ms = now
                                             (fires even when SNR variance
                                              defeats full decode)
                                           on_recv 'B' specifically:
                                             last_rx_bcn_ms = now

on_beacon_fire (periodic timer):
  since_busy   = now - last_rx_routing_sf_ms
  since_bcn_rx = now - last_rx_bcn_ms
  since_my_bcn = now - last_beacon_tx_ms
  max_idle_eligible = (since_my_bcn >= beacon_max_idle_ms)

  PRE-JITTER GATE:
    if max_idle_eligible:
      if dirty_n == 0 AND
         since_bcn_rx < (beacon_max_idle_ms / 3):
        emit "beacon_max_idle_skip_clean"; SKIP
      else:
        emit "beacon_max_idle_force"; FIRE
        → send_beacon_page("periodic")          (continues into §1.1 wire arrow)
    elif since_busy < quiet_threshold_ms:
      emit "beacon_skipped_busy"(pre_jitter)
      SKIP
    else:
      delay = rand(0, beacon_silence_jitter_ms)
      schedule deferred fire at now + delay

at deferred-fire time:
  POST-JITTER GATE (same composite filter):
    re-evaluate since_busy, since_bcn_rx, dirty_n,
    max_idle_eligible against fresh now
    apply pre-jitter logic again
    on FIRE → send_beacon_page("periodic")     (→ §1.1 wire arrow)
    on SKIP → emit "beacon_skipped_busy"(post_jitter)
```

**Status.** Implemented. The composite B+C filter is the post-`246cb8a`
refinement that prevents 138-node bursts from re-saturating the channel
at ~300% capacity.

## 1.3 BCN triggered (route-change cascade)

Any routing-table mutation (`new`, `promote`, `primary_refresh` in
`rt_merge`; or `rt_prune_cycle` removing a primary; or
`age_out_stale_routes` evicting) schedules a one-shot BCN within
`[beacon_trigger_jitter_min_ms, beacon_trigger_jitter_max_ms]` (default
2–10 s). Triggered beacons bypass the §1.2 throttle gate because
routing changes must propagate urgently.

```
Emitter (G)                                Listener (H, direct neighbor)
                                                                              SF
some action mutates rt[]:
  rt_merge returns action in
    {"new","promote","primary_refresh"}
  OR rt_prune_cycle removes primary
  OR age_out_stale_routes evicts entry
  → schedule_triggered_beacon()

schedule_triggered_beacon:
  if triggered_beacon_pending: no-op (coalesced)
  triggered_beacon_pending = true
  base_delay = rand(beacon_trigger_jitter_min_ms,
                    beacon_trigger_jitter_max_ms)   (default 2–10 s)
  if past discovery+boot_grace AND
     (since_my_bcn < beacon_trigger_min_interval_ms):
    base_delay = (trigger_min_interval - since_my_bcn)
                 + rand(2s, 10s)
    emit "beacon_trigger_deferred"
  schedule fire at now + base_delay

at fire-time:
  triggered_beacon_pending = false
  if pending_tx or pending_rx: skip (half-duplex)
  (NO §1.2 throttle gate — triggered BYPASSES throttle)
  send_beacon_page("triggered")
  last_beacon_tx_ms = now
  tx_flood 'B' on routing_sf            routing_sf
                          ─B──>
                                on_recv "B": same handling as §1.1
                                ↓
                                if H's own rt_merge produces
                                {"new","promote","primary_refresh"}:
                                  H schedules its OWN triggered BCN
                                  → cascade propagates the route change
                                    across the network within a few
                                    jitter windows
```

**Status.** Implemented. Coalesced via `triggered_beacon_pending`;
deferred for `beacon_trigger_min_interval_ms` outside discovery/boot
grace.

## 1.4 Stale-route aging

`rt[]` candidates expire if not refreshed within their hop-class TTL
(`rt_aging_ttl_neighbor_ms` = 45 min for 1-hop; `rt_aging_ttl_remote_ms`
= 3 h for multi-hop). A periodic aging loop scans every
`rt_aging_check_period_ms` (default 60 s). There is no explicit
"delete" wire frame — the loss propagates by absence in subsequent
BCN advertisements, so neighbours eventually evict the same destination
via the same aging mechanism.

`id_bind[]` ages on a separate, much longer TTL (`id_bind_ttl_ms`,
default 48 h) because identity ownership outlives any single route
candidate.

```
Aging tick on G                            Listener H (sees consequence later)
                                                                              SF
on_aging_tick (every rt_aging_check_period_ms, default 60 s):
  ttl_n = rt_aging_ttl_neighbor_ms        (45 min)
  ttl_r = rt_aging_ttl_remote_ms          (3 h)
  any_evicted = false
  any_primary_evicted = false

  for each rt[dest]:
    keep = []
    for each candidate c in rt[dest].candidates:
      ttl = (c.hops == 1) ? ttl_n : ttl_r
      if (now - c.last_seen_ms) < ttl:
        keep.append(c)
    if #keep == 0:
      rt[dest] = nil                       (no "delete" wire frame —
      any_evicted = true                    listener's own aging loop
                                            evicts via cascade)
    elif primary slot was evicted:
      rt[dest].candidates = keep
      rt[dest].dirty = true                 → next BCN ships new primary
      any_primary_evicted = true
      any_evicted = true
    else:
      rt[dest].candidates = keep            (alts only — no broadcast)

  if any_evicted:
    emit "rt_aged"
    schedule_triggered_beacon()             → see §1.3 for fire path
                                              and the cascade behaviour
                          ─B──>           routing_sf
                                            on_recv "B": G's table arrives
                                            WITHOUT the gone destination.
                                            H's rt_merge does NOT add the
                                            missing dest. H's own
                                            last_seen_ms for that dest
                                            stops being refreshed; H's
                                            own aging loop evicts it on
                                            a future tick.
                                            Cascade time across N hops:
                                            roughly N × ttl.

Last-seen refresh inputs (prevent eviction):
  - on_recv "B" containing route (dest, next, ...):
      refreshes rt[dest].candidates[c where c.next == B.src].last_seen_ms
  - on_recv ANY frame from neighbour B (RTS/CTS/DATA/ACK/BCN):
      refreshes rt[B].candidates[direct-1-hop].last_seen_ms only
      (multi-hop entries still age via beacon advertisements)
  - seen_bitmap from B containing self.id bit:
      refreshes rt[dest].candidates[c where c.next == B].last_seen_ms
      for each dest in B's table
```

**Status.** Implemented. `id_bind` aging also implemented with separate
48 h default TTL.

---

# 2. Data plane — happy paths

## 2.1 RTS-CTS-DATA-ACK (single hop)

The atomic data-plane exchange: 4 frames, ~hundreds of milliseconds.
Sender's RX SF stays on `routing_sf` throughout (only TX SF changes
per-frame). The receiver retunes RX twice (routing → data after CTS-tx,
data → routing after DATA-rx).

```
Originator (alice)              Next-hop (bob)
                                                                  SF
on_command "send bob hello"
  enqueue {origin=alice, dst=bob, payload=hello}
  become_free →
  issue_send →
    pack_rts → pending_tx
    start_rts_timeout
    tx_initiating 'R' on routing_sf       routing_sf
    (sender's RX stays on routing_sf —
     CTS and ACK and NACK all ride on routing_sf;
     TX SF varies per frame but does not change
     the modem's RX SF, see lua:4108, lua:6064)
                          ─R──>
                                on_recv "R", leaf_id ok, next == self.id
                                ↓
                                pending_rx = {from=alice, ctr_lo,
                                              chosen_data_sf, ...}
                                start_pending_rx_expiry
                                pack_cts(ctr_lo, chosen_data_sf)
                                tx_with_retry 'C' on routing_sf
                                (CTS on routing_sf so the sender
                                 — still on routing_sf — hears it)
                          <─C──                              routing_sf
on_recv "C", matches pending_tx.ctr_lo
  pending_tx.chosen_data_sf = c.chosen_data_sf
  cancel rts_timeout
                                set_rx_sf(chosen_data_sf)        data_sf
                                (receiver retunes RX to data_sf
                                 to receive DATA on the chosen SF)
after cts_to_data_gap_ms:
  pack_data → tx_with_retry 'D' on chosen_data_sf
  (sender's TX SF override = data_sf for this frame;
   sender's RX SF unchanged, still routing_sf)
  start_ack_timeout
                          ─D──>
                                on_recv "D" at data_sf,
                                matches pending_rx.ctr_lo
                                ↓
                                cancel pending_rx_expiry
                                set_rx_sf(routing_sf)           routing_sf
                                pending_rx = nil
                                last_acked_from[alice] = {ctr_lo, t_ms}
                                pack_ack(ctr_lo, meta.snr,
                                         budget_hint)
                                tx_with_retry 'K' on routing_sf
                          <─K──                             routing_sf
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

**Status.** Implemented. SF flow is the one Lua actually does (`tx_*`
sites at lua:4101, 5899, 6053, 6739).

## 2.2 Multi-hop forward (alice → F → bob)

Forwarder F receives DATA addressed to bob, ACKs alice, and then
re-issues its own RTS for the next hop with the **same `ctr_lo`** so
the end-to-end flight is identifiable hop-by-hop.

```
Originator (alice)         Forwarder (F)              Destination (bob)
                                                                       SF
on_command send bob hello:
  next_hop = rt[bob].primary.next  (= F)
  pack_rts(dst=bob, next=F,
           ctr_lo = ctr & 0xF)
  pending_tx; start rts_timeout
  tx_initiating 'R' on routing_sf       routing_sf
                          ─R──>
                            on_recv "R", next == self.id,
                            dst != self.id  (forward request)
                            ↓
                            pending_rx = {from=alice,
                                          dst=bob, ctr_lo,
                                          chosen_data_sf}
                            pack_cts(ctr_lo, chosen_data_sf)
                            tx_with_retry 'C' on routing_sf
                          <─C──                       routing_sf
on_recv "C", matches pending_tx.ctr_lo
cancel rts_timeout
                            set_rx_sf(chosen_data_sf)   data_sf
                            (F retunes RX to receive DATA)
after cts_to_data_gap_ms:
  pack_data(origin=alice, dst=bob,
            ctr, payload)
  tx_with_retry 'D' on chosen_data_sf
  (TX SF only; alice's RX stays on routing_sf)
                          ─D──>
                            on_recv "D" at data_sf,
                            matches pending_rx
                            ↓
                            cancel pending_rx_expiry
                            set_rx_sf(routing_sf)      routing_sf
                            last_acked_from[alice] = {ctr_lo, now}
                            pack_ack(ctr_lo, meta.snr,
                                     budget_hint)
                            tx_with_retry 'K' on routing_sf
                          <─K──                        routing_sf
on_recv "K"
pending_tx = nil; become_free
                            dst != self.id → forwarder branch:
                            after ack_air_ms + 1 ms:
                              enqueue {origin=alice, dst=bob,
                                       ctr, payload}
                              become_free → issue_send

                            issue_send (forward leg):
                              next_hop = rt[bob].primary.next (= bob)
                              pack_rts(dst=bob, next=bob,
                                       ctr_lo = ctr & 0xF)
                              (ctr_lo = ORIGIN's ctr nibble,
                               same value as the inbound DATA;
                               end-to-end identification of the flight)
                              pending_tx; tx_initiating 'R'
                                          on routing_sf       routing_sf
                                                          ─R──>
                                                            on_recv "R",
                                                            next == self.id,
                                                            dst == self.id
                                                            ↓ (local deliver)
                                                            pending_rx = {...,
                                                              chosen_data_sf}
                                                            pack_cts
                                                            tx 'C' on routing_sf
                                                          <─C──            routing_sf
                            on_recv "C", matches pending_tx.ctr_lo
                                                            set_rx_sf(chosen_data_sf)
                                                                              data_sf
                            after cts_to_data_gap_ms:
                              tx 'D' on chosen_data_sf
                                                          ─D──>
                                                            on_recv "D" at data_sf,
                                                            matches pending_rx
                                                            ↓
                                                            set_rx_sf(routing_sf)
                                                                              routing_sf
                                                            dst == self.id:
                                                              emit "delivered"
                                                              payload → app
                                                            pack_ack →
                                                            tx 'K' on routing_sf
                                                          <─K──            routing_sf
                            on_recv "K"
                            pending_tx = nil; become_free
```

**Note.** Alice's hop-level K-ack only confirms F received the DATA. If F
drops the message after the K-ack (disk full, app crash, route change),
alice has no way to know. See §2.3 for opt-in E2E ACK.

**Status.** Implemented.

## 2.3 E2E ACK round-trip (alice → bob → alice)

Opt-in per-message end-to-end confirmation. Originator sets `E2E_ACK_REQ`
in DATA byte 1. Destination, on `delivered`, builds a return DATA with
`E2E_IS_ACK` set and `body = [acked_ctr_lo, acked_ctr_hi]`. The return
travels via normal data-plane machinery — no new frame type, no new
forwarding logic. Forwarders see ordinary DATA.

```
Originator (alice)                         Destination (bob)
                                                                  SF
send_e2e bob "hello":
  ctr = self:next_ctr(bob.id)
  pending_e2e[(bob.id, ctr)] = {sent_at=now, text="hello"}
  emit "e2e_ack_pending"
  enqueue {flags = DATA_FLAG_E2E_ACK_REQ,
           ctr, dst=bob, payload="hello"}

  → normal data-plane flight (may be multi-hop; see §2.1/2.2
    per hop). Wire byte 1 bit 3 carries E2E_ACK_REQ end-to-end;
    forwarders pass it through without acting on it.

  ─R/C/D/K─ ... ─R/C/D/K─→
                                on_recv "D" at final hop, dst == self.id
                                ↓ (delivery branch)
                                parse_data sets:
                                  d.e2e_ack_req = true
                                  d.ctr         = alice's ctr (LE)
                                  d.origin      = alice.id
                                  d.body        = "hello"
                                emit "delivered" payload="hello"
                                  (user app sees the message)

                                if d.e2e_ack_req:
                                  return_ctr = self:next_ctr(alice.id)
                                  return_body = [d.ctr & 0xff,
                                                 (d.ctr >> 8) & 0xff]
                                  inner       = src_addr_len(0)
                                                | src_addr(bob.id)
                                                | return_body
                                  enqueue {flags = DATA_FLAG_E2E_IS_ACK,
                                           ctr   = return_ctr,
                                           dst   = alice.id,
                                           payload = inner}
                                  emit "e2e_ack_tx_enqueued"
                                  (return frame does NOT set
                                   E2E_ACK_REQ — no recursion)

                                  → normal data-plane flight back
                                    (forwarders see ordinary DATA;
                                     E2E_IS_ACK flag is opaque to them)

                          <─R/C/D/K─ ... ─R/C/D/K─

on_recv "D" at alice (final hop of the return flight):
  parse_data sets:
    d.e2e_is_ack = true
    d.origin     = bob.id
    d.body       = [acked_ctr_lo, acked_ctr_hi]
  acked_ctr = d.body:byte(1) | (d.body:byte(2) << 8)

  if pending_e2e[(bob.id, acked_ctr)] exists:
    emit "delivered_confirmed" payload = stored .text
    clear pending_e2e[(bob.id, acked_ctr)]
  else:
    emit "e2e_ack_unmatched"  (duplicate or already timed out)

  DO NOT emit a normal "delivered" — this IS the ACK, not user content
  DO NOT enqueue another E2E ACK — E2E_IS_ACK on inbound prevents it

(Meanwhile, the 1 s drain loop sweeps pending_e2e:)
  for each pending_e2e[(dst, ctr)]:
    if (now - sent_at) > e2e_ack_ttl_ms (default 60 s):
      emit "e2e_ack_timeout" {dst, ctr}
      clear entry
      (app layer decides whether to retry or surface
       "no answer received" to the user)
```

**Status.** Implemented. Doubles airtime per message (return flight is a
full RTS/CTS/DATA/ACK) — hence opt-in.

---

# 3. Data plane — failure modes

## 3.1 RTS hits busy receiver → NACK BUSY_RX

NACK fires ONLY for the `pending_rx` busy case. The historical
`pending_tx` (busy-as-sender) trigger was removed because the
`busy_for_ms` estimate lied in the failure case — silent drop with
`rts_drop_pending_tx` is preferred; senders rely on `rts_timeout` +
cascade. We **never path-switch on a NACK** (transient busy signal).

```
Originator (alice)              Receiver (R, busy with pending_rx for other sender X)
                                                                  SF
issue_send → tx RTS to R:
  pack_rts(dst, next=R, ctr_lo,
           sf_bitmap, payload_len)
  pending_tx; tx_initiating 'R'
              on routing_sf       routing_sf
                          ─R──>
                                on_recv "R" at R, next == self.id
                                ↓
                                pending_rx ~= nil AND
                                  (pending_rx.from   != r.src OR
                                   pending_rx.ctr_lo != r.ctr_lo OR
                                   pending_rx.payload_len != r.payload_len)
                                  → R is busy with a DIFFERENT flight (from X)
                                busy_for     = pending_rx_expires_in_ms
                                busy_payload = ceil(busy_for / 16)
                                               (max 255 → 4080 ms ceiling)
                                emit "nack_tx" {reason=pending_rx}
                                pack_nack(ctr_lo = r.ctr_lo,
                                          reason  = NACK_REASON_BUSY_RX,
                                          payload = busy_payload)
                                tx_initiating 'N' on routing_sf
                          <─N──                              routing_sf
on_recv "N", matches pending_tx.ctr_lo
  busy_for_ms = nack.payload × 16
  cancel rts_timeout
  blind_until[R] = now + busy_for_ms

  if busy_for_ms <= NACK_WAIT_THRESHOLD_MS (2 s):
    schedule tx_rts_retry("nack_wait") at
      now + busy_for_ms + 1 + rand(0, retry_jitter_ms)
    (SAME next-hop — we never path-switch on NACK)
  else:
    push pending_tx back into tx_queue
    pending_tx = nil
    become_free
    (DV may converge while we wait; other queued
     work may surface first; eventual re-issue uses
     fresh routing decisions)
```

**Status.** Implemented.

## 3.2 RTS already acked → CTS already_received

Sender's previous K-ack was lost; they retried the RTS. Receiver
answers with CTS `already_received=1`, so the sender clears
`pending_tx` without retransmitting DATA and without the receiver
reprocessing or forwarding the message twice.

The cache key includes `(src, dst, ctr_lo, payload_len)` — the wider
key prevents cross-packet false positives during normal retry traffic
(the 4-bit `ctr_lo` is too small alone).

```
Originator (alice)              Receiver (R, already delivered/forwarded earlier)
                                                                  SF
(Earlier flight (alice → R, ctr_lo=N, payload_len=L)
 completed at R: R sent K-ack, but K-ack was lost.
 alice's ack_timeout fired; the work item is still
 in alice's queue. tx_rts_retry now retries:)

tx_rts_retry("ack_timeout"):
  pack_rts(dst, next=R, ctr_lo=N,
           sf_bitmap, payload_len=L)
  pending_tx; tx_initiating 'R'
              on routing_sf       routing_sf
                          ─R──>
                                on_recv "R" at R, next == self.id
                                ↓
                                ack_key = (r.src, r.dst,
                                           r.ctr_lo, r.payload_len)
                                if last_acked_from[ack_key] exists
                                AND (now - last_acked_from[ack_key].t_ms)
                                    < last_acked_ttl_ms (10 s):
                                  emit "rts_already_acked"
                                  pack_cts(r.ctr_lo,
                                           chosen_data_sf,
                                           already_received=1)
                                  tx_with_retry 'C' on routing_sf
                                  return
                                  (no pending_rx created,
                                   no DATA processing repeats,
                                   no forwarding duplicated)
                          <─C── (already_received=1)        routing_sf
on_recv "C", c.already_received == true
matches pending_tx.ctr_lo:
  cancel rts_timeout
  emit "cts_already_received_rx"
  treat as success — no DATA-tx, no ACK expected:
    if origin == self.id:
      clear app-pending entry (delivered confirmation)
    if forwarder:
      skip DATA-tx and DATA forwarding (peer already has it)
  pending_tx = nil; become_free
```

**Status.** Implemented.

## 3.3 Duplicate RTS while we're mid-flight as receiver

Sender's previous CTS was lost. They retried RTS while the receiver
is still in `pending_rx` for the same flight. Receiver re-sends CTS
with the SAME `chosen_data_sf` so the sender can re-attempt DATA on
the originally negotiated SF.

```
Originator (alice)              Receiver (R, mid-flight RX for alice's current flight)
                                                                  SF
(R received an earlier RTS from alice with ctr_lo=N,
 sent CTS — but CTS was lost. R set pending_rx and
 retuned to data_sf to await DATA. R's pending_rx_expiry
 hasn't fired yet. alice's rts_timeout fires; tx_rts_retry:)

tx_rts_retry("cts_timeout"):
  pack_rts(dst, next=R, ctr_lo=N,
           sf_bitmap, payload_len=L)
  pending_tx; tx_initiating 'R'
              on routing_sf       routing_sf
                          ─R──>
                                on_recv "R" at R, next == self.id
                                (R is on routing_sf only between
                                 pending_rx_expiry windows — see §2.1)
                                ↓
                                pending_rx ~= nil AND
                                  pending_rx.from        == r.src AND
                                  pending_rx.dst         == r.dst AND
                                  pending_rx.ctr_lo      == r.ctr_lo AND
                                  pending_rx.payload_len == r.payload_len
                                  → SAME flight; previous CTS lost
                                emit "rts_rx_dup"
                                pack_cts(r.ctr_lo,
                                         pending_rx.chosen_data_sf,
                                         already_received=0)
                                tx_with_retry 'C' on routing_sf
                                  (label = "CTS-dup")
                                restart pending_rx_expiry
                                set_rx_sf(chosen_data_sf)   data_sf
                                (R re-arms for the upcoming DATA)
                          <─C──                              routing_sf
on_recv "C" matches pending_tx.ctr_lo:
  pending_tx.chosen_data_sf = c.chosen_data_sf
  cancel rts_timeout
  → resume normal DATA-tx flow per §2.1 (cts_to_data_gap
    then tx 'D' on chosen_data_sf, etc.)
```

**Status.** Implemented.

## 3.4 F1 passive CTS overhearing → blind_until

When relay R has just sent CTS and retuned to `data_sf` to receive
DATA, R is deaf on `routing_sf` for `cts_to_data_gap + data_airtime`.
Concurrent RTSes to R during that window land as silent
`drop_sf_mismatch` (no NACK).

Mitigation: every node populates `blind_until[node_id]` by overhearing
every CTS on `routing_sf` (whether addressed to it or not). Before any
RTS, the sender checks `classify_blind` and switches to an alt
next-hop, defers, or proceeds.

```
Peer N (overhearer)             Forwarder R (just sent CTS, entering blind window)
                                                                  SF
                                ... R completed RX of RTS from some sender S ...
                                ... R built pending_rx and packed CTS ...
                                tx_with_retry 'C' on routing_sf       routing_sf
                                set_rx_sf(chosen_data_sf)             data_sf
                                  (R is now deaf on routing_sf for
                                   cts_to_data_gap_ms +
                                   airtime(chosen_data_sf, max DATA)
                                   — concurrent RTSes to R on routing_sf
                                   land at the runtime as drop_sf_mismatch,
                                   silently; no NACK)

(N is on routing_sf for its own reasons — beacon listening,
 awaiting its own CTS for an unrelated flight, idle RX, etc.
 The CTS R just sent reaches every node within R's routing_sf
 decode range, regardless of c.to_id.)

on_recv "C", any source, any to_id, at routing_sf:
  cts_sender = meta.src                  (= R)
  blind_window = cts_to_data_gap_ms +
                 airtime(c.chosen_data_sf,
                         bw_hz, cr,
                         RTS_LEN + max_payload_len)
  blind_until[cts_sender] = max(blind_until[cts_sender],
                                now + blind_window)
  (N stores R's blind window even though the CTS
   wasn't addressed to N — that's the whole point)

(Later, when N tries to RTS some destination via next_hop == R:)

issue_send / tx_rts_retry / rts_timeout_fire — pre-check:
  classify_blind(self, dst, current_next_hop = R, alts_tried, prev_hop):
    if R is in blind_until and now < blind_until[R]:
      walk rt[dst].candidates:
        first non-tried, non-blind, non-previous_hop alt
          → return ("alt", alt_next)
      no qualifying alt → return ("defer", remaining_blind_ms)
    else:
      return "ok"

  case ("alt", alt):
    emit "tx_blind_alt"
    switch next_hop = alt; reset retries
    tx_rts_retry("blind_alt")
  case ("defer", delay):
    emit "tx_blind_defer"
    self:after(delay, function() tx_rts_retry(self, reason) end)
  case "ok":
    proceed with tx_initiating 'R'

(Fallback when the CTS itself was lost at N — overhearing never
 fired, blind_until[R] not set — exponential backoff on rts_timeout_ms
 (×2 per attempt, capped at RTS_TIMEOUT_BACKOFF_CAP = 4) ensures
 the retry budget still covers a full receiver blind window.)
```

**Status.** Implemented.

## 3.5 RTS-timeout cascade

No CTS arrives within `rts_timeout_ms`. Reasons: RTS lost, CTS lost,
or next-hop is in another flight's blind window. The retry path uses
exponential backoff on `rts_timeout_ms` (×2 per attempt, capped at
`RTS_TIMEOUT_BACKOFF_CAP = 4`); after `retries_left == 0` the K=3
cascade walks alt next-hops; final exhaustion fires
`path_cascade_exhausted`.

```
Originator (alice)              Next-hop (silent — RTS lost, or CTS lost, or R blind)
                                                                  SF
tx_initiating 'R' on routing_sf       routing_sf
start_rts_timeout
  (timeout = rts_timeout_ms × 2^min(attempts, BACKOFF_CAP))
                          ─R──>
                                          (no CTS arrives — possible reasons:
                                           - next-hop never received RTS
                                             (collision, weak SNR)
                                           - next-hop received but CTS was lost
                                             (collision on the return path)
                                           - next-hop is on data_sf in another
                                             flight's blind window
                                             — see §3.4)

at rts_timeout_fire:
  if pending_rx ~= nil:
    (we became RX-busy for some other flight between
     our RTS-tx and now; can't TX yet)
    self:after(rts_busy_retry_ms, fn) → re-fire this timeout
    return

  elif retries_left > 0:
    classify_blind(self, dst, current_next, alts_tried, prev_hop):
      case ("alt", new_next):
        emit "tx_blind_alt"
        switch next_hop = new_next; reset retries; rts_timeout_ms /= backoff
        tx_rts_retry("cts_timeout")
      case ("defer", delay):
        emit "tx_blind_defer"
        self:after(delay, fn) → recheck
      case "ok":
        retries_left -= 1
        rts_timeout_ms = min(rts_timeout_ms × 2,
                             base × RTS_TIMEOUT_BACKOFF_CAP)
        self:after(rand(0, retry_jitter_ms), fn):
          tx_rts_retry("cts_timeout")  → same next-hop, larger window

  else (retries_left == 0):
    K=3 cascade — try the next non-tried alt in rt[dst].candidates:
      if next-best alt exists AND not blind AND not previous_hop:
        emit "tx_silent_alt" or "cascade_rts" depending on path
        switch next_hop = alt; reset retries
        tx_rts_retry("cascade_rts")
      else:
        emit "rts_giveup"
        emit "path_cascade_exhausted"
        pending_tx = nil
        become_free
        (originator's queue keeps the item only if §4.2
         cascade-requeue is enabled — otherwise the flight
         is dropped and the originator's app layer must
         decide whether to re-send)
```

**Status.** Implemented. ACK-timeout (DATA lost or ACK lost) reuses the
same cascade (`data_ack_giveup` is the legacy giveup event).

---

# 4. Routing / control

## 4.1 Q ROUTE_QUERY / REQ_SYNC

`Q` is a one-hop control frame (receivers do NOT forward it). Two
opcodes:

- **ROUTE_QUERY** — sender lacks a route for `q.dest`; asks neighbours
  to advertise it.
- **REQ_SYNC** — joiner with poor `rt[]` (in DISCOVERY) asks eligible
  neighbours to send a full sync BCN.

The "response" in both cases is a BCN (not a direct reply frame).

```
Requester (alice)                          Responder (neighbour N)
                                                                  SF
Case A — ROUTE_QUERY (alice missing rt[bob]):

issue_send → rt[bob] is nil:
  defer_send_for_route() — push send to defer queue
  if q_queried[bob.id] is absent or expired (5 s TTL):
    pack_q(leaf_id, src=self.id, dest=bob.id,
           opcode = Q_OP_ROUTE_QUERY,
           requester_is_mobile = self.is_mobile)
    q_queried[bob.id] = now + 5 s
    tx_initiating 'Q' on routing_sf       routing_sf
                          ─Q──>
                                on_recv "Q", leaf_id == self.leaf_id
                                ↓
                                if q.src == self.id: drop (loop guard)
                                elif q.dest == self.id:
                                  schedule_triggered_beacon()
                                  (someone is asking for ME;
                                   next BCN announces self via src)
                                  return
                                elif q.opcode == Q_OP_ROUTE_QUERY:
                                  key = ("ROUTE_QUERY", q.src, q.dest)
                                  if q_responded_to[key] not expired:
                                    drop (per-key dedup, 10 s TTL)
                                  elif rt[q.dest] does not exist:
                                    drop silently (let other neighbour
                                    answer; suppresses Q-storm)
                                  else:
                                    q_responded_to[key] = now + 10 s
                                    schedule_triggered_beacon()
                                    (jitter 50-500 ms; the BCN
                                     IS the response — it contains
                                     the rt[bob] entry alice needs)
                                                     ... after jitter ...
                                tx_flood 'B' on routing_sf
                                  (§6.4 differential: bob is dirty
                                   if newly-merged here, else rotates
                                   into a stable page)
                          <─B──                                  routing_sf
on_recv "B": rt_merge inserts/updates rt[bob].
The deferred send for bob now finds rt[bob].primary
and proceeds via §2.1 swimlane.

──────────────────────────────────────────────────────────────────

Case B — REQ_SYNC (joiner with poor rt[] in DISCOVERY):

after node-local listen window, alice still lacks neighbours:
  pack_q(leaf_id, src=self.id, dest=0xff,
         opcode = Q_OP_REQ_SYNC,
         requester_is_mobile = self.is_mobile)
  tx_initiating 'Q' on routing_sf       routing_sf
                          ─Q──>
                                on_recv "Q", leaf_id == self.leaf_id
                                ↓ q.opcode == Q_OP_REQ_SYNC, q.dest == 0xff
                                if eligible (rt[] non-empty):
                                  base = rand(req_sync_backoff_min,
                                              req_sync_backoff_max)
                                  if q.requester_is_mobile: base += extra
                                  if self.is_mobile:        base += extra
                                  schedule pending_sync_bcn at
                                    now + base
                                  pending_sync_bcn.kind = "sync"

                                (Suppression rule: if N hears ANY
                                 useful BCN before its timer fires,
                                 N cancels its own pending sync BCN
                                 — one good neighbour's answer is
                                 enough; avoids all-respond storm.)
                                                     ... at fire ...
                                send_beacon_page("sync")
                                  (full rt[] dump in one BCN, kind=sync)
                          <─B──                                  routing_sf
on_recv "B" (sync): rt_merge picks up many entries at once;
alice's rt[] passes its discovery threshold and DISCOVERY ends.

(Q frames are one-hop only — receivers do NOT forward them.)
```

**Status.** Implemented.

## 4.2 Cascade-requeue lifecycle

A single stuck destination must not block deliverable items behind it
in `tx_queue`. When `pending_tx` exhausts all K alts, the item is
pushed back into `tx_queue` with exponential backoff so other queued
items can rotate through the dispatch. Subsequent attempts get
shrinking per-cycle RTS retry budgets so zombie messages consume less
channel time. The `tx_queue` priority puts fresh sends ahead of
zombies. Total wallclock cap (60 s by default) is enforced on EVERY
requeue attempt.

```
Originator (alice) — flight to bob via stuck routes
                                                                  SF
enqueue {origin=alice, dst=bob, payload="hello"}
  enqueue_time_ms  = T_0
  requeue_count    = 0
  next_attempt_ms  = T_0
become_free → pop earliest-ready item → issue_send

╔═══════════════════════════════════════════════════════════════╗
║ Attempt cycle 0  (requeue_count=0,                            ║
║   effective_rts_max_retries = rts_max_retries - 0 = 3)        ║
╠═══════════════════════════════════════════════════════════════╣
║ K=3 alt walk through rt[bob].candidates:                      ║
║   alt 0: tx_initiating 'R' → rts/ack timeouts → exhaust       ║
║   alt 1: switch + reset retries → tx 'R' → exhaust            ║
║   alt 2: switch + reset retries → tx 'R' → exhaust            ║
║   no more alts → emit "path_cascade_exhausted"                ║
╚═══════════════════════════════════════════════════════════════╝
                                ↓
try_cascade_requeue("path_cascade_exhausted"):
  next_count   = 0 + 1 = 1
  total_age_ms = now - T_0
  if next_count > cascade_requeue_max (3):         drop
  if total_age_ms >= cascade_requeue_total_max_ms: drop
  (Phase D3 load-adaptive) if tx_queue depth >
    cascade_requeue_load_threshold, subtract excess from
    effective budget; if budget <= 0 → emit
    "cascade_load_skip"; drop
  else:
    backoff_ms = min(5000 × 2^0, 30000) = 5000
    push back to tx_queue:
      next_attempt_ms = now + 5000
      requeue_count   = 1
      enqueue_time_ms = T_0  (preserved across requeues)
    emit "cascade_requeue" {requeue_count=1, backoff_ms,
                            total_age_ms, trigger}
  pending_tx = nil; become_free
  (other queued items can dispatch during the 5 s backoff)

... 5 s later ...
queue_wakeup_handle fires → become_free → pop earliest-ready:
  PRIORITY: smallest requeue_count first
            (tie-break: smallest next_attempt_ms, then FIFO)
  So fresh sends (requeue_count=0) jump ahead of zombies —
  fresh sends have the best chance of clean delivery.

╔═══════════════════════════════════════════════════════════════╗
║ Attempt cycle 1  (requeue_count=1,                            ║
║   effective_rts_max_retries = 3 - 1 = 2 — Phase D4)           ║
╠═══════════════════════════════════════════════════════════════╣
║ Same K=3 alt walk, but each alt has 2 RTS retries (not 3).    ║
║ Zombie messages spend less channel time per cycle.            ║
║ If exhausts → try_cascade_requeue → backoff = 5000 × 2 = 10s  ║
╚═══════════════════════════════════════════════════════════════╝
                                ↓
... 10 s later ... cycle 2 (effective_rts_max_retries = 1)
... 20 s later ... cycle 3 (effective_rts_max_retries = 0)

After cycle 3 exhausts:
  next_count = 4 > cascade_requeue_max (3)
  try_cascade_requeue returns false
  → flight is DROPPED:
      emit "rts_giveup"
      emit "path_cascade_exhausted_final"
      (originator's app layer must decide whether to re-send
       fresh or surface "delivery failed" to the user)

Total-wallclock guard applies on EVERY requeue attempt:
  if (now - enqueue_time_ms) >= 60 s:
    drop immediately, regardless of remaining requeue budget
  (Tightened from 120 s after measuring s04 successful-delivery
   max ~115 s — 60 s preserves most legitimate slow paths while
   killing 3-13 minute zombie cascades that pollute the channel.)
```

**Status.** Implemented.

---

# 5. Join plane

The join state machine runs only when `config.join_required=true`. An
unjoined node starts with temporary `self.id = 255` (`JOIN_UNJOINED_ID`,
reserved for unjoined/broadcast-special use), and does NOT emit
BCN/RTS/DATA until `join_adopted` fires.

## 5.1 Join — happy path (autonomous)

**Setup.**

| Node | id | key_hash32 | joined | data_sfs |
|---|---|---|---|---|
| alpha | 10 | 0x10101010 | yes | {7, 9} |
| bravo | 11 | 0x11111111 | yes | {7, 9} |
| charlie | 12 | 0x12121212 | yes | {7, 9} |
| delta | null | 0x44444444 | no — `join_required=true` | {12} (overridden) |

Tunables: `join_listen_ms=2000`, `join_discover_jitter_ms=0`,
`join_claim_guard_ms=3000`, `join_offer_backoff_min/max_ms` staggered
per responder.

```
Joiner (delta)                          Network (alpha / bravo / charlie)
                                                                  state
t=0    on_init:
         self.id = 255 (JOIN_UNJOINED_ID)
         self.joined = false
         set_protocol_id(255)
         → emit join_listen_start {key_hash32=0x44444444, listen_ms=2000}
                                        (no traffic from delta yet — passive)

t=2000 listen_ms elapsed:
         → emit join_listen_end {known_bindings=0}
         delay = rand(0, join_discover_jitter_ms+1) = 0
         join_send_discover("listen_done"):
           join_discover_attempts = 1
           pack_j_discover(leaf_id, key=0x44444444)
           → emit join_discover_sent {attempt=1, reason="listen_done"}
           tx_initiating 'J' on routing_sf
                          ─J(DISCOVER, key=0x44444444)──>
                                        alpha: → emit join_discover_received
                                        schedule J_OFFER at rand(100,301) — picks 220
                                        (bravo: 500-700 ms; charlie: 900-1100 ms)

t=2220 (alpha's offer fires):
                                        alpha: pack_j_offer(self.id=10,
                                          self.key=0x10101010, data_sf_bitmap=0x05)
                                        → emit join_offer_sent
                                        tx_initiating 'J' on routing_sf
                          <─J(OFFER, responder=10, key=0x10101010, sfs=0x05)──
delta: on_recv "J" opcode=OFFER
       → emit join_offer_received
       id_bind_set(10, 0x10101010, source="j_offer", confidence="claimed")
       → emit id_bind_set {node=10, key_hash32=0x10101010}
       (joiner branch — adopt SF policy:)
       self.allowed_sf_bitmap = 0x05
       → emit join_data_sfs_adopted
       (joiner branch — trigger CLAIM:)
       join_start_claim("offer"):
         proposed = join_choose_candidate_id(self)
           free = [0..254] \ {10}   # already in id_bind
           pick = free[rand(...)] — with seed=48 picks 143 (per t48)
         join_claim_epoch += 1     # → 1
         nonce = rand(0, 256)
         join_claim_pending = {proposed=143, key=0x44444444,
                               claim_epoch=1, nonce, started_ms=now}
         pack_j_claim(key=0x44444444, proposed=143, lease_age=0, ...)
         → emit join_claim_sent {proposed_node_id=143, reason="offer"}
         tx_initiating 'J' on routing_sf
         arm GUARD timer at now + 3000 ms

                          ─J(CLAIM, proposed=143, key=0x44444444, epoch=1)──>
                                        all three: → emit join_claim_received
                                        conflict check:
                                          self.id != 143; existing=nil;
                                          self.join_claim_pending=nil
                                          → conflict=false
                                        id_bind_set(143, 0x44444444,
                                                    source="j_claim", confidence="claimed")
                                        → emit id_bind_set {node=143}
                                        (no DENY sent)

(later: bravo's & charlie's offers also arrive — refresh id_bind for 11, 12;
 don't re-trigger CLAIM because join_claim_pending is set)

t=5240 GUARD fires:
       p = self.join_claim_pending     # still set, proposed=143
       existing = self.id_bind[143] = nil  (joiner doesn't pre-set on send)
       → no conflict path
       self.join_claim_pending = nil
       bound = id_bind_set(143, 0x44444444, source="join_adopted",
                           confidence="authenticated")  → true
       self.joined = true; self.id = 143
       set_protocol_id(143)
       → emit join_adopted {node=143, key=0x44444444, claim_epoch=1, nonce}
       send_beacon_page("sync")
       send_req_sync_q("join_adopted")
                          ─B(sync, src=143, key=0x44444444, [routes])──>
                                        all three: on_recv "B"
                                        id_bind_set(143, 0x44444444, "bcn", "claimed")
                                          (already matches — refresh only)
                                        rt_merge for delta=143
```

**Status.** Implemented; `test/t48_join_autonomous_fourth_node.json`.

## 5.2 Join — no neighbours → exhaustion

**Setup.** Solo joiner, no network. Tunables: `join_listen_ms=1000`,
`join_discover_wait_ms=1000`, `join_discover_max_attempts=2`,
`join_retry_backoff_ms=1000`.

```
Joiner (solo_joiner)               Network (empty)
                                                              state
t=0    on_init: self.id = 255; → emit join_listen_start

t=1000 listen_end → emit join_listen_end
       join_send_discover("listen_done"):
         join_discover_attempts = 1
         → emit join_discover_sent {attempt=1}
         tx_initiating 'J'(DISCOVER)
                          ─J(DISCOVER)──>
                                      (no responders)
         arm offer-wait timer at +1000 ms

t=2000 offer-wait elapsed:
       no offer → attempts (1) < max (2) → schedule retry
       backoff = rand(0, 1001)
       → emit join_discover_retry_scheduled {attempts=1, backoff_ms}

t=2000+BACKOFF:
       join_send_discover("offer_timeout"):
         join_discover_attempts = 2
         → emit join_discover_sent {attempt=2, reason="offer_timeout"}
                          ─J(DISCOVER)──>
                                      (still nobody)
         arm offer-wait timer at +1000

t≈3000+BACKOFF:
       no offer → attempts (2) >= max (2)
       → emit join_discover_exhausted {attempts=2, wait_ms=1000}
       (joiner remains unjoined; no further automatic action)
```

**Status.** Implemented; `test/t49_join_no_offer_retry.json`.

**Notes.**
- `join_discover_max_attempts=0` means "unlimited" — magic-value
  semantics; document if production firmware wants a hard cap.
- `join_discover_attempts` resets to 0 on `join_adopted`, so future rejoin
  paths start fresh instead of inheriting the original discovery count.

## 5.3 Join — simultaneous-claim race (deterministic tie-break)

**Setup.** Two real unjoined joiners that happen to draw the same id
from the random picker (rare but possible when `id_bind` is sparse —
early in network life).

```
delta (key=0x44444444)              echo (key=0x11111111)
                                                              state
(both have done LISTEN; received OFFERs from alpha; passed CLAIM trigger)

t=2000 delta: join_start_claim("offer"):
         proposed = 50    # random pick collision
         join_claim_epoch = 1; nonce_delta = D_N
         join_claim_pending = {proposed=50, key=0x44444444, epoch=1, nonce=D_N}
         tx 'J'(CLAIM, proposed=50, key=0x44444444, nonce=D_N)
         arm GUARD timer at +3000

t=2000+ε                            echo: join_start_claim("offer"):
                                      proposed = 50; nonce_echo = E_N
                                      join_claim_pending = {proposed=50,
                                        key=0x11111111, epoch=1, nonce=E_N}
                                      tx 'J'(CLAIM, proposed=50, ...)
                                      arm GUARD at +3000

t≈2050 delta: on_recv echo's J(CLAIM, proposed=50, key=0x11111111)
         → emit join_claim_received
         conflict check:
           existing = id_bind[50] = nil
           join_claim_pending.proposed (50) == j.proposed (50)
             AND keys differ
           → run tie-break:
             join_claim_compare(0x44444444, D_N, 0x11111111, E_N)
               hash_a (0x44...) < hash_b (0x11...) → FALSE
             self_pending_wins = false
           delta loses:
             self.join_claim_pending = nil
             self.join_denied_ids[50] = true
             → emit join_claim_denied
                {reason="simultaneous_claim_lost"}
           schedule: self:after(join_retry_backoff_ms,
                       join_start_claim("simultaneous_claim_lost"))

t≈2050                              echo: on_recv delta's J(CLAIM, proposed=50, key=0x44444444)
                                      → emit join_claim_received
                                      conflict check:
                                        existing = nil
                                        pending.proposed (50) == 50; keys differ
                                        → tie-break:
                                          join_claim_compare(0x11111111, E_N,
                                                             0x44444444, D_N)
                                          hash_a < hash_b → TRUE
                                        self_pending_wins = true → conflict = true
                                      DENY (winner branch):
                                        owner_key = pending.key = 0x11111111
                                        pack_j_deny(denied=50, owner=0x11111111,
                                                    claimant=0x44444444)
                                        → emit join_deny_sent
                                        tx 'J'(DENY)
                                                              <─J(DENY, denied=50,
                                                                  owner=0x11111111,
                                                                  claimant=0x44444444)──

t≈2070 delta: on_recv echo's J(DENY)
         → emit join_deny_received
         id_bind_set(50, 0x11111111, source="j_deny", confidence="claimed")
         (delta.join_claim_pending is already nil — no-op for clear)

t=5000 echo's GUARD fires:
                                      p = pending (still set, proposed=50)
                                      existing = id_bind[50] = nil
                                      → no conflict → adopt
                                      self.joined = true; self.id = 50
                                      → emit join_adopted

t=5000+BACKOFF (delta's retry):
       join_start_claim("simultaneous_claim_lost"):
         proposed = pick excluding {10, 50}
         tx 'J'(CLAIM, proposed=87, ...)
         ... eventually delta adopts a different id ...
```

**Status.** Implemented; loser side covered by
`test/t50_join_simultaneous_claim_race.json` (winner side could be
covered by a t51 with two real joiners).

**Edge case.** If two joiners share `key_hash32` (birthday collision)
AND draw the same random `nonce`, both see "I lose" and back off. Both
re-pick from `free` set; convergence is virtually certain because the
nonce regenerates per retry.

## 5.4 Join — already-claimed ID (DENY response)

**Setup.** Joiner picks an id that an existing-and-joined neighbour
already owns. The owner replies J_DENY; the joiner retries.

```
Joiner (delta)                          Network (alpha id=10, bravo id=50)
                                                              state
(delta heard alpha's OFFER but not bravo's — id_bind only has 10)

t=2000 join_start_claim("offer"):
         free = [0..254] \ {10}
         proposed = 50  (random pick collision with bravo)
         tx 'J'(CLAIM, proposed=50, key=0x44444444)
         arm GUARD at +3000

                          ─J(CLAIM, proposed=50)──>
                                        bravo: on_recv "J" opcode=CLAIM
                                        conflict: self.id (50) == proposed AND self.joined
                                        DENY: owner_key = 0x50505050
                                        → emit join_deny_sent
                                        tx 'J'(DENY)

                                        alpha: on_recv same J(CLAIM)
                                        conflict: existing.key (bravo's) != j.key
                                        also fires DENY (redundant refresh)
                          <─J(DENY, denied=50, owner=0x50505050,
                              claimant=0x44444444)──
t≈2020 delta: on_recv "J" opcode=DENY
         id_bind_set(50, 0x50505050, source="j_deny", confidence="claimed")
         → emit id_bind_set {node=50, key_hash32=0x50505050}
         (claimant_key (0x44444444) == self.key → DENY targets me)
         self.join_denied_ids[50] = true
         self.join_claim_pending = nil
         → emit join_claim_denied {reason=CONFLICT}
         schedule retry at now + join_retry_backoff_ms

t≈12000 (after backoff):
       join_start_claim("deny_backoff"):
         free = [0..254] \ {10, 50}
         proposed = random pick from updated free set
         (proceed with normal CLAIM → GUARD → ADOPT)
```

**Status.** Implemented; not yet covered by a dedicated test (t48/t50
cover happy and race; a focused DENY-retry test would close the gap).

## 5.5 Join — GUARD-window late conflict (defense-in-depth)

Hardest scenario to trigger naturally — most conflict paths clear
`join_claim_pending` directly in J_CLAIM or J_DENY handlers. The
realistic trigger: a `J_OFFER` from a previously-unheard node has
`responder_node_id == delta.proposed_node_id`.

**Setup.** `alpha` and `romeo` (id=50) joined; `delta` and `mike` are
joiners. `delta` did not hear `romeo`'s OFFER during LISTEN. `delta`'s
random picker chooses 50. During `delta`'s GUARD, `mike`'s DISCOVER
prompts `romeo` to OFFER, and `delta` overhears it.

```
delta (key=0x44444444)              mike (key=0x99999999)             romeo (id=50, key=0x50505050)
                                                                                                    state
t=2000 delta: join_start_claim:
         proposed = 50 (delta's id_bind only has alpha=10)
         join_claim_pending = {proposed=50, key=0x44444444}
         tx 'J'(CLAIM, proposed=50)
         arm GUARD at +3000
                                              (no nodes between delta and romeo
                                                receive delta's CLAIM —
                                                e.g. romeo is out of range)

t=3000                              mike: post-LISTEN
                                      tx 'J'(DISCOVER, key=0x99999999)
                                                                          ─J(DISCOVER, key=0x99999999)──>
                                                                          romeo: schedule J_OFFER at rand(100, 1001)

t=3300                                                                    romeo: tx 'J'(OFFER, responder=50, ...)
                                                            <─J(OFFER, responder=50, key=0x50505050)──
delta also receives romeo's OFFER (broadcast on routing_sf):
       → emit join_offer_received
       id_bind_set(50, 0x50505050, source="j_offer", confidence="claimed")
       → emit id_bind_set {node=50, key_hash32=0x50505050}
       (delta is in join_claim_pending state — does NOT re-trigger
        join_start_claim because pending is already set)

t=5000 delta's GUARD fires:
         p = self.join_claim_pending  # still {proposed=50, key=0x44444444}
         existing = self.id_bind[50] = {key=0x50505050}   # set by OFFER above
         existing.key (0x50505050) != self.key (0x44444444)
         → CLAIM_GUARD_CONFLICT branch:
           self.join_claim_pending = nil
           self.join_denied_ids[50] = true
           → emit join_claim_denied {reason="claim_guard_conflict"}
           schedule retry: self:after(join_retry_backoff_ms,
                              join_start_claim("claim_guard_conflict"))
         (delta does NOT adopt id=50)

t=15000+ (after backoff): delta restarts claim with different id
```

**Status.** Defense-in-depth implemented at lua:4985-4998. Not currently
covered by a dedicated test (the exact ordering is hard to provoke
reproducibly without `join_test` injection at controlled times).

## 5.6 Join — cold-boot storm

**Setup.** 8 nodes boot together with `join_required=true` and no
pre-existing joined nodes. Tunables: `join_listen_ms=2000`,
`join_discover_jitter_ms=5000`, `join_offer_backoff_min/max=100/1000`.

```
t=0    all 8 nodes: on_init, self.id=255, emit join_listen_start
       (no traffic — all passive)

t=2000 all 8 nodes pass listen_ms simultaneously
       each draws delay = rand(0, 5001) ms (join_discover_jitter_ms)
       → DISCOVER emissions spread across [t=2000, t=7000]
       (without this jitter all 8 would TX at the same tick → collision)

t∈[2000, 7000] each DISCOVER causes other 7 to schedule J_OFFER
       (Note: unjoined nodes also enter the OFFER path because the handler
        doesn't gate on self.joined. They send OFFER with responder_node_id=255
        — recipients call id_bind_set(255, offerer.key) which sets a binding
        for the broadcast/special slot. Functionally harmless because the
        picker skips 255, but conceptually leaky.)
       Each responder draws backoff = rand(100, 1001) ms

t∈[3000, 8000] each joiner receives some OFFER → triggers CLAIM
       Each joiner picks a random id via join_choose_candidate_id
       The picker draws from a large free set (256 ids minus a few already
         in id_bind from OFFER observation)
       Probability of two joiners picking the same id ~= 8 × 7 / 256 ≈ 22%
       Collisions that DO occur are resolved via §5.3 tie-break

t∈[6000, 11000] GUARD timers fire (each 3000 ms after CLAIM)
       Winners adopt; losers retry with new ids
       Network gradually stabilizes
```

**Status.** Mechanisms implemented; not stress-tested under explicit
cold-boot scenarios. The `join_discover_jitter_ms` first-slice default
is 3000 (production target per ROADMAP §2a: 5000..30000); the 30 s
upper bound is what keeps a 100+ node boot from saturating routing_sf.

## 5.7 Join — silent node returns with reused ID

**This is the load-bearing scenario for identity-aware BCN.** Since
every BCN now carries `key_hash32` and the BCN receive path calls
`id_bind_set`, conflict **detection** works automatically. Recovery
when a node observes its own id taken over by a different key is now
implemented via own-id defense → deterministic tie-break →
`forced_rejoin`; see §5.7c and t60.

### 7a — Silent node returns, observers still remember the binding

`alice` (id=5, key=0xAAAA0000) joins; goes silent at t=60000.
`charlie` (key=0xCCCC0000) boots later and runs join. Observers' `id_bind[5]`
is still fresh (`id_bind_ttl_ms` default = 48 h; alice's binding has not
aged out).

```
charlie (joining)                       bob (still up; id_bind[5]=alice still valid)
                                                                  state
charlie: LISTEN → DISCOVER → OFFER from bob → id_bind[6]=bob.key → CLAIM
  picker: free = [0..254] \ {6, 5, ...}  ← 5 already in id_bind from BCN reception
  → picker won't even propose 5

  But suppose charlie's id_bind doesn't have 5 (charlie just rebooted,
   never heard alice). Then:
  proposed = 5 (random pick)
  tx 'J'(CLAIM, proposed=5, key=0xCCCC0000)
                          ─J(CLAIM, proposed=5)──>
                                          bob: existing = id_bind[5] = 0xAAAA0000
                                          existing.key != j.key → conflict
                                          tx 'J'(DENY, owner=0xAAAA0000, claimant=0xCCCC0000)
                          <─J(DENY)──
charlie: id_bind_set(5, 0xAAAA0000, "j_deny", "claimed")
         → emit join_claim_denied
         → retries with different id (random pick excluding 5)
```

**Outcome (7a).** alice's id=5 is defended in absentia by bob's
persistent `id_bind[5]`. charlie picks a different id. No collision when
alice returns.

**Status.** Works correctly today. Note that `id_bind` does age (48 h
default); silence longer than that exposes case 7b.

### 7b — Silent node returns; observers' binding aged out (or observers rebooted)

```
charlie (joining)                       bob (id_bind[5] aged out / rebooted)
                                                                  state
charlie: pick = 5; tx 'J'(CLAIM, proposed=5, key=0xCCCC0000)
                          ─J(CLAIM, proposed=5)──>
                                          bob: existing = id_bind[5] = nil
                                          self.id (6) != 5; pending=nil → no conflict
                                          id_bind_set(5, 0xCCCC0000,
                                                      source="j_claim",
                                                      confidence="claimed")
                                          (NO DENY sent)

t+3000 charlie's GUARD fires:
         existing at charlie = nil → no conflict → adopt
         self.joined = true; self.id = 5
         → emit join_adopted

t=200000 (much later) alice's device powers back on (RAM-persisted id=5):
         alice's first periodic BCN: src=5, key_hash32=0xAAAA0000
                          ─B(src=5, key_hash32=0xAAAA0000, ...)──>
                                          bob: on_recv "B"
                                          id_bind_set(5, 0xAAAA0000, "bcn", "claimed")
                                          existing.key (0xCCCC0000) != b.key (0xAAAA0000)
                                          → return false; emit "addr_conflict_observed"
                                             {known_key=0xCCCC0000,
                                              observed_key=0xAAAA0000,
                                              source="bcn"}
                                          (prev.conflict_hash32 = 0xAAAA0000,
                                           prev.last_seen_ms = now,
                                           but binding NOT overwritten)
                                          BCN handler continues:
                                          rt_merge(...)  → updates rt[] for alice's entries
                                          (alice's frames are still routed
                                           as if id=5 = charlie; alice's
                                           local rt[5] also points to herself)

         charlie also receives alice's BCN:
         id_bind[5] = 0xCCCC0000 (his own); b.key = 0xAAAA0000 differs
         → emit "addr_conflict_observed"
            {known_key=0xCCCC0000, observed_key=0xAAAA0000, source="bcn"}
         (charlie sees that "someone else is claiming MY id" but takes no
          automatic action — no force-rejoin, no DENY response,
          no escalation to app layer)
```

**Outcome (7b, today).** The conflict is **detected** (via
`addr_conflict_observed` events at all observers within range of
alice's BCN, including charlie himself). It is **not** recovered:
- Bindings are not overwritten on plain conflict (the `addr_conflict_observed`
  event fires but `id_bind_set` returns false).
- The conflict is **detected** via `addr_conflict_observed` at both
  alice and charlie (and at any third-party observer in range).
- Recovery is now **automatic** via the own-id defense + tie-break +
  forced-rejoin loop (see §5.9 below). When alice returns and her BCN
  reaches charlie, charlie's `id_bind_set` fires the
  `addr_conflict_defense` hook → charlie emits J_DENY carrying
  charlie's lease_age + claim_epoch. alice's J_DENY handler runs the
  tie-break: typically alice (older deployment, longer lease) wins,
  charlie loses and triggers `forced_rejoin`, yielding the id.

**Implemented mechanisms (all verified in t59 / t60):**

1. **Recovery action on `addr_conflict_observed`** — `id_bind_set` now
   fires `addr_conflict_recovery_send_deny` when the conflict involves
   `self.id` with `prev.key == self.key`. The defensive J_DENY carries
   `reason=J_DENY_REASON_OWN_ID_DEFENSE`, the defender's
   `lease_age_seconds`, and `claim_epoch`. The duplicate's J_DENY
   handler runs `addr_conflict_tie_break` and, on loss, calls
   `forced_rejoin`. Test: **t60**.
2. **`claim_epoch` NV persistence** — via the `self.nv` shim
   (`nv_get`/`nv_set`). `on_init` loads the previously-saved epoch;
   `join_start_claim` increments and persists. Tests seed via
   `config.nv = {"claim_epoch": N}`. The 8-bit wire field wraps after
   256 boots; consumers must still handle wraparound. Test: **t59**.
3. **`lease_age_seconds` populated with real value** — computed as
   `floor((self:now() - self.adopted_at_ms) / 1000)`, saturating to
   16 bits. `adopted_at_ms` is set on `join_adopted` for unjoined
   nodes and at `on_init` for pre-joined nodes. Both `J_CLAIM` (own
   lease) and `J_DENY` (defender's lease) wire fields carry the real
   value. Test: **t59**.

**Remaining open** — a dedicated test for the "alice goes silent,
charlie joins as id=5, alice returns" scenario (uses t60's mechanism
but in a less synthetic setup). t60 already proves the underlying
machinery works end-to-end.

### 7c — Recovery action (IMPLEMENTED)

When `id_bind_set` observes a conflict for a node_id we currently own
(`node_id == self.id` and `prev.key_hash32 == self.key_hash32`), we
fire `addr_conflict_recovery_send_deny`: a defensive `J_DENY` with
reason `J_DENY_REASON_OWN_ID_DEFENSE`. The impostor's `J_DENY` handler
runs `addr_conflict_tie_break` (older lease wins → higher epoch wins →
lower key wins), and the loser triggers `forced_rejoin`, releasing its
short ID and re-running `join_start_claim`. Total ordering prevents
thrashing. Within ~one beacon period both nodes converge to unique
short IDs. Test: **t60**.

## 5.8 Join — partition merge (mechanisms implemented)

**Setup.** Two partitions, P1 and P2, each with a node owning id=5
independently. The partitions merge after a long RF outage. Both
nodes' BCNs reach each other.

**Required mechanisms (current status):**

1. Identity-aware BCN: implemented (every BCN carries `key_hash32`).
2. NV-persistent `claim_epoch`: **implemented** via `self.nv` shim
   (`nv_get`/`nv_set`); incrementing claims save before TX. Wire field
   is 8-bit so consumers must handle 256-boot wraparound.
3. Lease-age advertisement: **implemented** — `lease_age_seconds` is
   `floor((now - adopted_at_ms) / 1000)`, saturating at 16 bits.
   Verified by t59.
4. Recovery action on `addr_conflict_observed`: **implemented** via
   defensive J_DENY + tie-break + forced_rejoin (`addr_conflict_defense`
   → `addr_conflict_tie_break` → `addr_conflict_forced_rejoin`).
   Verified by t60. Partition-merge resolution is now functionally
   covered for the simple two-node collision case; the same mechanism
   generalizes to N-node partition merge because each pair-wise
   collision resolves independently via the tie-break.

**Outline of intended exchange (once mechanisms exist).**

```
t=2000000 merge:
  alice's next BCN: src=5, key=0xAAAA0000, lease_age=2000s, claim_epoch=K1
  zelda's next BCN: src=5, key=0xZZZZ0000, lease_age=1500s, claim_epoch=K2

  zelda receives alice's BCN:
    existing = id_bind[5] = 0xZZZZ0000  (her own)
    b.key (0xAAAA0000) != existing.key
    → addr_conflict_observed
    tie-break: compare(alice.lease_age vs zelda.lease_age)
      alice older → alice wins
    zelda triggers forced rejoin → emit join_forced_rejoin {reason="partition_merge_lost"}
    runs full join state machine, picks new id

  alice receives zelda's BCN:
    same comparison from alice's POV → alice wins
    continues as id=5
```

**Status.** Design-only. Track each of the three pending mechanisms
(items 2-4) before writing tests against this scenario.

---

# 6. Gateway / inter-layer plane

## 6.1 Gateway — two-layer scheduled smoke

**Status.** Implemented and passing in
`scenarios/s09_two_layer_gateway_debug.json`.

**Purpose.** This is the current gateway v1 acceptance scenario. It proves
that a single-radio gateway can retune between two layers, advertise its
schedule, answer JOIN on the active layer, learn remote bindings from real
BCN/JOIN traffic, and forward cross-layer DATA to joined nodes without
simulator-seeded foreign bindings.

**Setup.**

- Layer 4: control SF7, DATA SF10 (`data_sf_bitmap=0x20`).
- Layer 5: control SF8, DATA SF11 (`data_sf_bitmap=0x40`).
- `gw_4` is pinned in layer 4 and listens to layer 5 on a schedule.
- `gw_5` is pinned in layer 5 and listens to layer 4 on a schedule.
- Six `_j*` nodes have `node_id=null` and `join_required=true`.
  They only know their layer and control SF from JSON. They do **not**
  configure `allowed_data_sfs`; they learn DATA SF policy from `J_OFFER`.

```
Layer 4 joiner                         Layer 4 responders
t=start_at_ms
  self.id = 255
  emit join_listen_start
  listen on routing_sf=7

t=start+listen+jitter
  J_DISCOVER(key_hash32, leaf=4)  ─────> seed/gateway on active layer 4
                                      responder emits J_OFFER(data_sf_bitmap=0x20)
  receive J_OFFER
  emit join_data_sfs_adopted {data_sf_bitmap=32}
  J_CLAIM(proposed_id, key_hash32)
  guard window
  emit join_adopted
```

Layer 5 is identical except control SF8 and DATA bitmap `0x40`.

**Gateway schedule semantics in this scenario.**

- Gateways emit BCN with `has_schedule=1`.
- `gateway_schedule_change` marks local radio context switches:
  primary layer at init/return, secondary layer during the scheduled window,
  and target-layer TX when a gateway handoff forces an immediate retune.
- Direct peers cache schedule records from BCN and emit
  `tx_gateway_schedule_defer` instead of wasting RTS while the gateway is
  away on another layer.

**Cross-layer delivery flow.**

```
l4_seed send_layer(layer=5, dst_key_hash32=l5_j1)
  → queues gateway envelope to gw_5
  → local layer-4 RTS/CTS/DATA uses SF7 control + SF10 DATA
  → gw_5 consumes envelope, resolves key_hash32 in layer 5
  → gw_5 activates primary/target layer 5 context
  → layer-5 RTS/CTS/DATA uses SF8 control + SF11 DATA
  → l5_j1 delivered
```

The reverse path from `l5_seed` to `l4_j1` proves the symmetric case.

**Known v1 limitation exposed by s09.** Gateway radio context and runtime
route/identity state are layer-aware, but gateways still use their primary
short ID while sweeping a bridged layer. Scenarios therefore keep gateway
short IDs distinct in every layer they participate in until per-layer gateway
leases are implemented.

## 6.2 Gateway — full layer separation workbench

**Status.** Implemented in
`scenarios/s10_two_layer_gateway_separation.json`. It reuses ordinary short
IDs across layers (`l4_seed` and `l5_seed` both use node ID 1) to prove that
route and identity state are isolated by layer.

**Current state.**

- Runtime state is represented as `layer_state[layer_id]` and the firmware's
  legacy `self.rt`, `self.id_bind`, and `self.dest_seen_ms` names are active
  layer pointers.
- Candidate selection for explicit target-layer sends only considers routes
  learned in that target layer.
- Gateway remote binding remains keyed by `target_layer_id + key_hash32`.
- Events that explain routing decisions include `active_layer_id`,
  `tx_layer_id`, and `dst_layer_id` where relevant.

**Remaining limitation.** Gateway nodes do not yet have independent per-layer
leases. A gateway still uses its primary short ID while sweeping a bridged
layer, so two gateways that participate in the same layer must not share that
short ID.

## 6.3 Gateway — three-layer stress

**Status.** Mechanism implemented; stress scenario moved to
`scenarios/deprecated/s11_three_layer_gateway_stress.json` after the
realism pass. The scenario's `sim_end` is clean but early cross-layer
flight assertions don't hold under realistic simultaneous-join +
gateway-discovery transient timing. Mechanisms exercised here (gateway
picker filtering, schedule defer across three layers) remain active
and are covered by `s09_two_layer_gateway_debug` (acceptance gate) and
`s10_two_layer_gateway_separation` (workbench).

**Purpose.** This scenario keeps the normal JOIN flow for all non-seed nodes
while making gateway selection harder than s09/s10. Layer 4 has two gateways:
one bridges to layer 5 and one bridges to layer 6. Layers 4 and 6 both use
control SF7, so foreign traffic can be physically visible while still being
filtered by leaf/layer. Layer 5 uses control SF8. Each layer has different
DATA SF policy and joiners learn that policy from `J_OFFER`.

**Setup.**

- Layer 4: control SF7, DATA SF10. Seed `l4_seed`; gateways `gw_45` and
  `gw_46`.
- Layer 5: control SF8, DATA SF11. Seed `l5_seed`; gateway `gw_54`.
- Layer 6: control SF7, DATA SF9. Seed `l6_seed`; gateway `gw_64`.
- Only seeds/gateways have fixed short IDs. `l4_j*`, `l5_j*`, and `l6_j*`
  start later with `node_id=null` and `join_required=true`.

**Checks covered.**

- JOIN adoption on all three layers without artificial route/ID seeding.
- DATA SF adoption from JOIN offers: layer 4 -> `0x20`, layer 5 -> `0x40`,
  layer 6 -> `0x10`.
- Gateway schedule advertisement and `gateway_layer_active` transitions.
- Gateway picker filtering by advertised bridged layer: layer-4 sends to
  layer 5 should use `gw_45`, while layer-4 sends to layer 6 should use
  `gw_46`.
- Retry-path schedule avoidance: `tx_gateway_schedule_defer` can fire from
  initial send or retry when a peer gateway is scheduled away.
- Forward cross-layer deliveries from layer 4 into layer 5 and layer 6.

**Known v1 limitation deliberately exposed.** Reverse sends from layer 5/6
to layer-4 joiners can hit `gateway_no_binding` when the reverse gateway has
not yet learned the target joiner's `(layer_id,key_hash32)->node_id` binding.
That is the parked C3 gateway-reachability problem, not a scenario failure.
Future work should either advertise reachable remote hashes, add a query path,
or retry through alternate gateways before dropping the envelope.

## 6.4 Gateway sweep cycle (mechanism)

The single-radio gateway alternates between its primary layer and one (or
more) configured secondary layers using a TDM schedule. Each
`gateway_layers[i]` record produces an independent sweep loop:
offset → activate → emit BCN on the new layer → optionally serve traffic →
return to primary after `duration_ms` → re-arm after `period_ms`.

```
Gateway G (primary layer L_p)              Channel / layer-L_s neighbours
                                                                  SF
t=0    on_init:
         activate_primary_layer("init"):
           active_layer_id = L_p
           active_leaf_id  = L_p & 0x0f
           active_routing_sf = primary routing_sf
           set_rx_sf(primary routing_sf)
         → emit gateway_layer_active
            {layer_id=L_p, reason="init"}
         → emit gateway_schedule_change
            {active_layer_id=L_p, reason="init"}
         for each gateway_layers[i] (rec):
           schedule_gateway_layer_window(rec):
             self:after(rec.offset_ms, fire)

t=offset_ms        fire():
         if pending_tx ~= nil or pending_rx ~= nil:
           → emit gateway_layer_window_deferred
              {layer_id, leaf_id, retry_ms}
           self:after(retry_ms, fire); return
         activate_gateway_layer(rec, "schedule"):
           active_layer_id = rec.layer_id (= L_s)
           active_leaf_id  = rec.leaf_id
           active_routing_sf = rec.routing_sf
           set_rx_sf(rec.routing_sf)              data_sf or routing_sf of L_s
         → emit gateway_layer_active
            {layer_id=L_s, duration_ms, reason="schedule"}
         → emit gateway_schedule_change
            {active_layer_id=L_s, listen_sf=rec.routing_sf, ...}
         send_beacon_page("gateway_sweep"):
           pack_bcn with active_leaf_id=L_s &
             has_schedule=1 (schedule records still advertised)
           tx_flood 'B' on rec.routing_sf
                          ─B(leaf=L_s, schedule)──>
                                                  layer-L_s neighbours:
                                                  on_recv "B"
                                                    leaf_id matches our active leaf
                                                    id_bind_set(b.src, b.key_hash32)
                                                    remember_gateway_schedule(b.src, b)
                                                    gateway_note_remote_binding(...)
                                                    (G learns L_s peers; L_s peers
                                                     learn G is a gateway bridging
                                                     to their layer)

         self:after(rec.duration_ms, return_fn):
           if pending_tx == nil and pending_rx == nil:
             activate_primary_layer("schedule_return"):
               active_layer_id = L_p (back to primary)
               set_rx_sf(primary routing_sf)
             → emit gateway_layer_active
                {layer_id=L_p, reason="schedule_return"}
             → emit gateway_schedule_change
                {active_layer_id=L_p, reason="schedule_return"}
           (if a transaction is in flight, return is skipped this cycle;
            next sweep fire will handle the return implicitly)

         self:after(rec.period_ms, fire)        # re-arm next sweep

(loop continues — sweep, BCN, optional traffic, return, wait period)
```

**Notes.**
- TX from the gateway during the sweep retunes layer per-flight via
  `tx_layer_id` (see §6.5). The sweep is for RX visibility on L_s, not
  for forcing all gateway TX onto L_s.
- Half-duplex skip (pending_tx/pending_rx defer) emits
  `gateway_layer_window_deferred` so the analyzer can spot starved
  sweeps. The retry uses `gateway_layer_busy_retry_ms` (defaults to
  `max(rts_busy_retry_ms, 1000)`).
- The schedule record on the wire advertises this exact cadence so
  layer-L_p neighbours can predict G's absence (see §6.6).

## 6.5 Cross-layer envelope handoff (mechanism)

An app-layer `send_layer L_target dst_key_hash32 body` enqueues a
gateway envelope addressed to a chosen gateway. The gateway resolves the
target by `key_hash32`, retunes to the target layer on TX via
`tx_layer_id`, and re-emits the body as a fresh DATA flight inside the
target layer.

```
Sender (S, layer L_s)        Gateway (G, primary L_s, bridges L_t)    Target (T, layer L_t)
                                                                                                SF
on_command "send_layer L_t dst_key text":
  target_layer_id = L_t
  select_gateway_for_layer(L_t):
    walk rt[]:
      c is gateway candidate AND
      gateway_neighbor_schedules[c.id].bridged_layers[L_t] == true
    pick best by hops/score → G (filter ensures G actually bridges L_t)
  pack_gateway_envelope(L_t, dst_key, text):
    "\x1fG1" + L_t(8) + dst_key(32 LE) + text
  → emit gateway_envelope_enqueued
    {gateway=G, target_layer_id=L_t, dst_key_hash32=dst_key}
  enqueue DATA flight to G with payload = envelope
  → emit tx_enqueue {via_gateway=true, target_layer_id=L_t}

  → normal data-plane flight on L_s (RTS/CTS/DATA/ACK per §2.1)
  ─R/C/D/K─→
                                G: on_recv "D", dst==self.id
                                parse_data → d_user_text begins with envelope magic
                                parse_gateway_envelope(d_user_text):
                                  gw_env = {target_layer_id=L_t, dst_key_hash32, body}
                                
                                if self.self_gateway and gw_env != nil:
                                  if gw_env.target_layer_id == self.layer_id:
                                    target = local id_bind lookup
                                    # This local-layer envelope path is intentional
                                    # for symmetric send_layer handling at a
                                    # gateway. The gateway re-originates the DATA
                                    # with itself as origin and a fresh per-peer ctr.
                                  else:
                                    target = gateway_remote_bind_find(L_t, dst_key)
                                  
                                  if target == nil or not gateway_layer_enabled(L_t):
                                    → emit gateway_no_binding
                                       {origin=S, via_gateway=G, target_layer_id, dst_key_hash32}
                                    drop (envelope consumed)
                                  else:
                                    forward_ctr = self:next_ctr(target.node_id)
                                    enqueue {
                                      origin     = self.id (= G — original sender is lost in v1)
                                      dst_id     = target.node_id
                                      payload    = inner(body)
                                      tx_layer_id = L_t       ← retune marker
                                    }
                                    → emit gateway_handoff_enqueued
                                       {via_gateway=G, target_layer_id=L_t,
                                        dst=target.node_id, binding_source=target.source}

                                ... when G dispatches the handoff flight (issue_send):
                                tx_layer_rec = gateway_layer_record(L_t)
                                tx_on_primary_layer = false
                                activate_gateway_layer(rec, "tx"):
                                  active_layer_id = L_t
                                  set_rx_sf(rec.routing_sf)         data_sf of L_t
                                → emit gateway_layer_active {layer_id=L_t, reason="tx"}
                                pack_rts(leaf_id=L_t, ...)
                                tx_initiating 'R' on L_t routing_sf
                                                            ─R/C/D/K─→
                                                                     T: on_recv "D", dst==self.id
                                                                     parse_data:
                                                                       origin = G (NOT S)
                                                                       body = "text"
                                                                     → emit delivered
                                                                        {origin=G, payload="text"}
                                                                        (original origin S not
                                                                         propagated through the
                                                                         handoff in v1)
```

**Non-gateway protection** (lua:8166). If a non-gateway node ever becomes
the final destination of a DATA frame whose body begins with the envelope
magic (routing misconvergence), it drops with
`gateway_envelope_at_non_gateway` rather than delivering the binary
prefix as user text.

**Envelope replay protection.** Envelopes ride on standard DATA. The
existing `seen_origins[(d.origin, d.dst, d.ctr)]` dedup runs **before** the
gateway-envelope branch in `on_recv "D"`, so a replayed envelope (same
prev-hop, same origin/dst/ctr) is dup-dropped at the standard-DATA layer
and the handoff code never re-executes.

**Deferred-handoff branch (gateway lacks binding for the target key).**
When the gateway resolves the envelope but `gateway_remote_bind_find`
returns `nil` (or `"ambiguous"`), the gateway does NOT drop. Instead it
parks the envelope in `gateway_deferred_handoffs` and emits a
`Q:HASH_QUERY` on the target layer to ask upper-layer peers to advertise
the binding. The deferred entry drains when the binding appears, or is
given up after `gateway_handoff_defer_ttl_ms`.

```
Gateway G (envelope target unknown)        Upper-layer peers
                                                                  state
G: on_recv "D", dst==self.id, gw_env != nil
   gateway_binding_for_env(self, gw_env):
     gateway_remote_bind_find(target_layer, key_hash) returns
       nil OR (nil, "ambiguous")
   defer_gateway_handoff(self, gw_env, d_origin, reason="not_found"):
     insert into gateway_deferred_handoffs {
       gw_env, origin=d_origin, queued_at_ms=now,
       q_sent_at_ms, reason
     }
     emit_hash_route_query(target_layer_id, dst_key_hash32, reason):
       activate_gateway_layer(rec, "q_hash")    ← retune to upper layer
       pack_q(opcode=Q_OP_HASH_QUERY, dest=255,
              key_hash32=dst_key_hash32)
       tx_initiating 'Q' on target layer routing_sf
     → emit gateway_handoff_deferred
        {origin, via_gateway=self.id, target_layer_id, dst_key_hash32,
         payload, reason, q_sent, ttl_ms, depth}

                          ─Q(HASH_QUERY, key_hash32, leaf=L_target)──>
                                                  some peer P with binding
                                                  for (L_target, key_hash):
                                                    pack_q(opcode=HASH_QUERY,
                                                           dest=resolved_node_id,
                                                           key_hash32=...)
                                                    → emit q_hash_binding_tx
                                                      {to, node, key_hash32,
                                                       tx_layer_id, tx_leaf_id,
                                                       tx_routing_sf}
                                                    tx_initiating 'Q' response
                          <─Q(HASH_QUERY response, dest=resolved_id)──
G: on_recv "Q" opcode=HASH_QUERY, dest != 255:
   gateway_note_remote_binding(L_target, resolved_id, key_hash32,
                               source="q_hash_response")
     → emit gateway_remote_bind_set {layer, node, key_hash32, source}
   
   try_drain_gateway_handoffs (periodic / on binding update):
     for each deferred d:
       binding = gateway_binding_for_env(d.gw_env)
       if binding != nil and gateway_layer_enabled(layer):
         enqueue_gateway_handoff(d.gw_env, d.origin, binding):
           queue new flight with tx_layer_id = target_layer
         → emit gateway_handoff_drained
            {origin, via_gateway, target_layer_id, dst_key_hash32,
             waited_ms, dst=binding.node_id, binding_source}
       elif (now - d.queued_at_ms) >= gateway_handoff_defer_ttl_ms:
         → emit gateway_handoff_giveup
            {origin, via_gateway, target_layer_id, dst_key_hash32,
             payload, waited_ms, reason}
         drop deferred entry

   ... once drained, the normal §6.5 handoff continues — gateway
   activates target layer via tx_layer_id and emits the in-target-layer
   DATA flight that reaches the destination.
```

**Pending refinements (see §6.2 workbench).**
- Original origin is not propagated through the handoff — destination's
  `delivered.origin` shows the gateway, not the original sender. Needs
  either an inner-payload convention or +5 B envelope extension.
- The Q HASH_QUERY storm question — there's per-key dedup via
  `q_queried[(layer,key)]` (TTL ≈ 5 s) but no aggregate rate cap. An
  adversary could force HASH_QUERY-spam by sending envelopes to many
  fictitious keys. Defense-in-depth; not a current correctness issue.

## 6.6 Layer-15 active-avoidance (mechanism)

When a non-gateway peer wants to RTS to a direct gateway that is
currently in its upper-layer sweep window, the peer would otherwise
waste an RTS-timeout cycle on a deaf receiver. The gateway's BCN
advertises its sweep schedule; the peer's `gateway_schedule_defer_ms`
computes the time until the gateway returns to the peer's layer, and
the flight is requeued with that delay.

```
Peer (P, layer L_p)                          Gateway (G, currently on L_s sweep window)
                                                                  state
(G's prior BCN carried has_schedule=1 with a record
 advertising {layer=L_s, sf, duration, offset, period}.
 P stored it via remember_gateway_schedule.)

on_command "send G hello":  /* P decides to RTS to G */
  issue_send → primary_next = G

  gateway_schedule_defer_ms(self, primary_next=G):
    if self.self_gateway: return 0   # gateways don't defer themselves
    sched = self.gateway_neighbor_schedules[G]
    our_leaf = active_leaf_id(self)   (= L_p & 0x0f)
    best_delay = 0
    for each rec in sched.records:
      if rec.leaf_id != our_leaf and rec.period_ms > 0:
        phase = (now - rec.offset_ms) % rec.period_ms
        if phase < rec.duration_ms:
          # G is currently INSIDE its L_s window — deaf on L_p
          delay = rec.duration_ms - phase + gateway_schedule_guard_ms
          if delay > best_delay: best_delay = delay
    return best_delay

  if delay > 0:
    → emit tx_gateway_schedule_defer
       {origin=self, dst, next_hop=G, delay_ms=delay,
        active_leaf_id=our_leaf}
    push to head of tx_queue with next_attempt_ms = now + delay
    self:after(delay, become_free)
    return  (no RTS transmitted yet)
                                                  (G is on rec.routing_sf, deaf on L_p)

... `delay` ms later (G should have returned to primary by now) ...

queue_wakeup → become_free → pop item → issue_send again
  gateway_schedule_defer_ms returns 0 (G's window has closed)
  → normal RTS flight proceeds
                          ─R──>
                                                  G now on L_p routing_sf
                                                  on_recv "R" → normal §2.1 flow
```

**Configurable knobs.**
- `gateway_schedule_guard_ms` (default 100 ms): extra margin added to the
  defer so we don't race the gateway's `activate_primary_layer` event.

**Retry paths.** `gateway_schedule_defer_ms` is consulted from both
`issue_send` and `tx_rts_retry`; `rts_timeout_fire` reaches the check
transitively because it dispatches every retry through `tx_rts_retry`.
A retry that would land inside the sweep window gets deferred with
`source="tx_rts_retry"` instead of wasting an RTS attempt.

---

# 7. Channel plane (gossip)

ROADMAP §3 lays out the full design rationale and §3.3 documents the
pull-storm hardening fix chain. This section captures the at-a-glance
walk-throughs for cross-reference.

## 7.1 Channel gossip — pull cycle (mechanism)

```
holder       puller       overhearer (in radio range of holder)
  │ ┐ self_originate channel msg X → buffer[X].dirty=true
  │ ┤
  │ ┘
  │ B ──────────────────────────────► (BCN with CHANNEL_DIGEST{X})
  │                  │ process_channel_digest(B):
  │                  │  buffer[X] absent → schedule pull
  │                  │  in [0, channel_pull_jitter_ms]
  │                  │
  │ ◄──────── R ──── │  (Q_CHANNEL_PULL RTS at routing_sf)
  │ ── C ──────────► │  (CTS, chosen_data_sf = routing_sf;
  │                  │   sf_bitmap was restricted to {routing_sf}
  │                  │   because flags & PAYLOAD_TYPE_M)
  │ ◄──────── Q ──── │  (Q frame: requested IDs)
  │ ── K ──────────► │  (hop ACK at routing_sf)
  │
  │ Q-handler: have buffer[X] → enqueue M-payload DATA frame
  │  with dst=puller, flags |= PAYLOAD_TYPE_M
  │
  │ ── R ──────────► │  (RTS for M-payload at routing_sf)
  │ ◄──────── C ──── │  (CTS, chosen_data_sf = routing_sf)
  │ ── D ──────────► │  (DATA at routing_sf — the key change in
  │ ── D ───────────────► overhearer
  │                  │   commit f6b5164. Pre-fix this went on
  │                  │   data_sf and overhearers dropped with
  │                  │   drop_sf_mismatch.)
  │                                    │ on_recv 'D' + payload_type_m:
  │                                    │  buffer[X] absent → add, source=overheard
  │                                    │  emit channel_msg_overheard
  │                                    │  channel_pull_pending[X] = nil
  │                                    │  emit channel_pull_suppressed
  │                                    │  if d.next != self.id then return
  │                  │ on_recv 'D':
  │                  │   buffer[X] absent → add, source=pull_target
  │                  │   ACK back to holder
  │ ◄──────── K ──── │
```

t65/t66/t67/t68/t69 are the dedicated regression tests.

## 7.2 Channel gossip — pull-storm dedupe (mechanism)

Three layered dedupe paths fire on different timescales:

| Path | When it fires | Effect |
|---|---|---|
| **peer-Q overhear** (commit `30cc9d9`) | Within ~30 ms of seeing a peer's Q_CHANNEL_PULL for an ID I have pending | Cancel my pending, emit `channel_pull_suppressed{overheard_from="peer_q"}`. Earliest dedupe — fires before most peer jitters expire. |
| **M-payload promiscuous overhear** (commit `f6b5164`, requires M at routing SF) | When the holder responds with the M-frame; any in-range peer with a pending pull cancels it | Cancel my pending, emit `channel_pull_suppressed{overheard_from=<holder>}`. Catches anyone who missed the peer-Q (decode collision, etc.). |
| **`channel_pull_recent` window** (always was there) | After I send a Q, won't pull the same ID for `channel_pull_window_ms` (5 s) | Prevents pull retries when my own Q is in flight |

Holder side: after `channel_dirty_max_advertisements` (K=3) BCN cycles
including the entry, the dirty bit retires (commit `f3971ac`). Other
holders that acquired the msg in that window have their own dirty bit
and carry the gossip forward — a wave of advertisers, not a permanent
few. See ROADMAP §3.3 pathology #2 for the failure mode this prevents.

## 7.3 Channel gossip — Principle 11 gateway guard (mechanism)

```
L1_holder         gateway (multi-layer)         L1_other_node       L2_other_node
  │
  │ DATA-M(dst=L2_puller, next=gateway) ────►│   (gateway is on the route to L2_puller)
  │                                            │
  │ ◄──────── K (ACK) ─────────────────────────│   (gateway ACKs — upstream done)
  │                                            │
  │                                            │  Gateway's M-handler:
  │                                            │   d.payload_type_m + self.self_gateway
  │                                            │   AND d.next == self.id:
  │                                            │   → emit channel_gateway_drop
  │                                            │   → become_free, NO forward
  │                                            │
  │                                            │  Result: no cross-layer TX from
  │                                            │  gateway. L1 nodes don't overhear
  │                                            │  an L2 message; L2 nodes do not
  │                                            │  receive this delivery via the
  │                                            │  gateway path. The pull-requester
  │                                            │  (L2_puller) re-pulls in the next
  │                                            │  BCN cycle (eventually-consistent
  │                                            │  by design).
```

The drop only applies when `self.self_gateway` AND the inbound frame is
PAYLOAD_TYPE_M. Same-layer M-payload from L1 holder to L1 puller never
hits this branch because non-gateway forwarders aren't subject to it.
Cross-layer DM (the actual purpose of gateways) is unaffected — DM
frames don't carry PAYLOAD_TYPE_M and use the gateway envelope path
(§6.5).

---

# Implementation status reference

Cross-reference of mechanisms each scenario depends on:

| Mechanism | Status (2026-05-20) | Used by |
|---|---|---|
| BCN periodic / triggered emission, throttle gate, aging loop | Implemented | 1.1, 1.2, 1.3, 1.4 |
| BCN `key_hash32` mandatory in every header (bytes 4-7) | **Implemented** (newly) | 1.1, 5.7 (detection mechanism) |
| `id_bind_set` called on BCN receive | Implemented | 1.1, 5.7 |
| `addr_conflict_observed` emitted on key mismatch | Implemented | 5.7 |
| `id_bind` TTL aging (default 48 h) | Implemented | 5.7 |
| RTS/CTS/DATA/ACK with sender-RX-stays-on-routing_sf | Implemented | 2.1, 2.2 |
| Multi-hop forwarder dance | Implemented | 2.2 |
| E2E ACK via return DATA | Implemented | 2.3 |
| BUSY_RX NACK + sender wait/requeue | Implemented | 3.1 |
| `last_acked_from` cache + CTS `already_received` | Implemented | 3.2 |
| Duplicate RTS → re-emit CTS with same SF | Implemented | 3.3 |
| Passive CTS overhearing → `blind_until` | Implemented | 3.4 |
| RTS-timeout exponential backoff + K=3 cascade | Implemented | 3.5 |
| Q ROUTE_QUERY + REQ_SYNC (BCN as response) | Implemented | 4.1 |
| Cascade-requeue lifecycle (Phases C/D3/D4) | Implemented | 4.2 |
| `J_DISCOVER`/`J_OFFER`/`J_CLAIM`/`J_DENY` wire | Implemented | 5.1-5.6 |
| Random `join_choose_candidate_id` | Implemented | 5.1-5.6 |
| `join_claim_compare` tie-break | Implemented | 5.3 |
| GUARD-window defense-in-depth | Implemented | 5.5 |
| Re-discover with backoff + max_attempts | Implemented | 5.2 |
| Joiner adopts DATA SF policy from OFFER (first valid offer wins) | Implemented | 5.1 |
| `claim_epoch` NV persistence (via `self.nv` shim, seedable by `config.nv`) | Implemented | 5.7c, 5.8, t59 |
| `lease_age_seconds` populated with real value (`now - adopted_at_ms`, floor seconds, saturating to 16 bits) | Implemented | 5.7c, 5.8, t59 |
| Recovery action on `addr_conflict_observed` from plain traffic (defensive DENY → tie-break → forced_rejoin) | Implemented | 5.7b, 5.7c, 5.8, t60 |
| J-frame anti-spam rate-limiting | Implemented for `J_DISCOVER`/`J_CLAIM` by `(opcode,key_hash32)` | 5.6 |
| Reset `join_discover_attempts` on `join_adopted` | Implemented | 5.2 |
| Gateway BCN schedule records + `gateway_schedule_change` | Implemented | 6.1, 6.4 |
| Gateway radio retune (`set_rx_sf` on activate) + `gateway_layer_active` | Implemented | 6.4 |
| Sweep half-duplex defer (`gateway_layer_window_deferred`) | Implemented | 6.4 |
| Schedule wire format with 5-second period override (P5 bit) | Implemented | 6.4 |
| JOIN offer DATA-SF learning per active layer | Implemented | 5.1, 6.1 |
| Cross-layer gateway envelope and handoff (`tx_layer_id` per-flight retune) | Implemented (v1) | 6.1, 6.5 |
| Gateway remote binding from observed BCN/JOIN traffic | Implemented | 6.1, 6.5 |
| Direct peer defer while gateway is scheduled away | Implemented | 6.1, 6.6 |
| Gateway picker filters by observed bridged-layer set | Implemented | 6.3, 6.5 |
| Non-gateway envelope-at-delivery drop (`gateway_envelope_at_non_gateway`) | Implemented | 6.5 |
| Schedule-defer consulted on retry paths (not only initial RTS) | Implemented | 6.6 |
| Q HASH_QUERY + deferred gateway handoff with TTL (`gateway_handoff_deferred`/`drained`/`giveup`) | Implemented | 6.5 |
| Full layer-scoped route state (`layer_state[layer_id].rt`) | Implemented | 6.2 |
| Full layer-scoped identity binding (`layer_state[layer_id].id_bind`) | Implemented | 6.2 |
| Independent per-layer gateway leases | **Not implemented** | 6.2 |
| Original-origin propagation through gateway handoff | **Not implemented** | 6.5 |
| Envelope dedup at gateway (replay protection) | Implemented via standard DATA dedup before envelope handling | 6.5 |
| Retry across alternate gateways on `gateway_no_binding` | **Not implemented** | 6.3, 6.5 |
| BCN_EXT_TYPE_CHANNEL_DIGEST emit + parse | Implemented | 7.1, 7.2 |
| Q_OP_CHANNEL_PULL + scheduled-pull-with-jitter | Implemented | 7.1 |
| PAYLOAD_TYPE_M DATA frame + promiscuous overhear | Implemented (working since `f6b5164`: M-payload forced to routing SF) | 7.1, 7.2 |
| peer-Q pull cancellation | Implemented (`30cc9d9`) | 7.2 |
| K=3 dirty-advertisement cap | Implemented (`f3971ac`) | 7.2 |
| Defer-TTL fires regardless of route presence | Implemented (`23b8978`) | drain loop (affects DM + channel) |
| Gateway no-forward of PAYLOAD_TYPE_M | Implemented (`f6b5164`, Principle 11 guard under 2A) | 7.3 |
| Group/private channel crypto (PSK+MAC, Ed25519 sig) | **Not implemented** | — |
| Cross-leaf channel bridging at gateways | **Not implemented** (parked, ROADMAP §3.1) | — |

# Pointers

- **Authoritative behaviour:** `scenarios/dv_dual_sf.lua`.
- **Wire format:** `docs/PROTOCOL.md` §3 (frame layouts), §13 (event
  catalogue).
- **Design and known gaps:** `docs/ROADMAP.md`.
- **Tests:**
  - Data plane: `test/t42_seen_bitmap_wire.json`,
    `test/t45_mobile_path_loss_overrides_static_links.json` (regression
    frontier — t46+ is the gold standard). Earlier data-plane tests
    (t11/t15/t26/t31/t33/t39–t44, plus `s11`) live under
    `test/deprecated/` and `scenarios/deprecated/`; their assertions
    pre-date the realism pass and are not regressions — see
    `test/deprecated/README.md`.
  - Node id / join wire: `test/t46_node_id_split.json`,
    `test/t47_j_frame_wire.json`.
  - Join autonomous: `test/t48_join_autonomous_fourth_node.json`.
  - Join no-offer: `test/t49_join_no_offer_retry.json`.
  - Join simultaneous claim: `test/t50_join_simultaneous_claim_race.json`.
