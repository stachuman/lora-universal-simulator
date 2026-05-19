# dv_dual_sf protocol roadmap

Topics flagged during analysis sessions that we want to address but aren't
the immediate next step. Each entry is short on purpose — capture the
shape of the problem, not the solution. Linked-to-from
`scenarios/dv_dual_sf.lua` and `tools/analyze.py` where relevant.

---

## 1. Anti-spam: rate-limit at the 1st-hop neighbour (IMPLEMENTED)

**Status — IMPLEMENTED** as silent-drop + originator self-monitoring.
See `scenarios/dv_dual_sf.lua` header doc block "Anti-spam: 1st-hop
statistical rate-limit" for full design. Verification scenario
`t33_anti_spam_rate_limit` was moved to `test/deprecated/` after the
realism pass shifted exact threshold counts; the mechanism itself
remains active. Mechanism summary:

- Per-direct-sender RTS/CTS observation counts over sliding 5-min
  window (`originator_window_ms`), deduplicated by msg_id within
  a 10-s retry window (`originator_retry_dedup_ms`) so retries
  don't inflate counts.
- `apparent_origination[X] = max(0, distinct_RTS_msgs[X] - distinct_CTS_msgs[X])`.
- Enforcement: **silent drop** of inbound RTS when over threshold
  (`originator_max_per_window = 6`, ≈ 72/hr) OR airtime backstop
  exceeded (`originator_airtime_share = 25%` of N's own duty cycle).
  No NACK — preserves N's airtime budget. Diagnostic emit
  `rts_drop_originator_throttle` for the analyzer.
- Originator UX feedback: spammer can't be told explicitly because
  no NACK, so each originator self-monitors. On terminal failure
  (path_cascade_exhausted / rts_giveup), if own origination count
  exceeds `originator_self_warn_fraction × max_per_window` (default
  half of inbound threshold = 3) OR own duty-cycle tier is STRAINED+,
  emit `originator_self_over_budget` with a UX-friendly hint string.

Measured impact on s04 (60-min, 360 sends, 16 active originators):
delivery unchanged at ~52%; 141 silent drops total (down from 3505
in a pre-dedup measurement); 94 self-over-budget emits caught
legitimate "over fair-share but not necessarily malicious" senders.

The original problem statement and design rationale (preserved for
context) follows.

---

**Problem.** A single chatty originator can monopolise network capacity.

**Problem.** A single chatty originator can monopolise network capacity.
At ~1% per-node duty cycle, every forwarder along the originator's
multi-hop path also burns its own budget relaying that traffic — so one
node sending 50 messages/min effectively consumes airtime across N
forwarders × 1 hop each. Origin A's traffic crowds out everyone else
even though A only has its own 1% local budget.

**Design constraint.** Enforcement must happen at the **1st-hop
neighbour**, NOT at the originator (a malicious modified firmware
can't be trusted to self-limit) and NOT at deeper forwarders (they see
aggregated traffic from many origins and would over-trigger on the
heaviest-loaded forwarders, which are doing the right thing).

The 1st-hop invariant: a node N is entitled to track/police origin X
**only when N hears a frame directly from X's radio with `sender == X
== origin`**. Forwarded frames (where the on-wire sender is not the
origin) are skipped — N has no way to distinguish legitimate
forwarding from origin-fingerprint there.

This has two structural properties:
1. **Attack-resistant**: a malicious firmware can lie about its own
   rate but can't hide its TX from physical neighbours. The neighbours
   measure what's on the wire.
2. **Distributed enforcement at the right scope**: every 1st-hop
   neighbour of X polices independently. X's traffic is bounded by the
   *most strict* of its direct neighbours.

**Plain-origin variant (compatible with current header).**
- State: per-direct-neighbour sliding-window airtime counter, populated
  only on RX where `sender == origin == X`.
- Detection: opportunistic check on receive; if window sum exceeds
  `self.duty_cycle_budget_ms × fair_share_fraction` (default 1/16 =
  ~6% of N's own budget), mark X as rate-limited.
- Enforcement: on subsequent RTS with `sender == origin == X` and X in
  rate-limited set, emit NACK with `reason = originator_throttle`.
- Recovery: window naturally decays; if X stops, X drops below
  threshold and is unmarked. Self-healing.

**Privacy-compatible variant (composes with §9 — origin encrypted).**
The plain variant requires plaintext `origin` to identify the spammer.
If origin moves into the encrypted payload (§9 T2), we lose direct
attribution. But we can preserve anti-spam via **statistical
behavioral fingerprinting** without reading origin.

Observation: a legitimate forwarder always emits one CTS-tx per
inbound flight (responding to RTS-rx from upstream) AND one RTS-tx per
outbound forward. Over any window, a true forwarder's
`CTS-tx ≈ RTS-tx`. An originator emits RTS-tx with no inbound RTS to
respond to, so `CTS-tx ≈ 0`. This is a **count-based metric over a
sliding window**, NOT a per-RTS deterministic check.

Why count-based, not per-RTS: a per-RTS rule like "look back 300 ms
for CTS+ACK from this sender" is broken by collisions. If N misses
the forwarder's ACK due to a collision (we measured ~5,500 collisions
out of ~7,000 drops on s04 — non-trivial rate), N would classify the
subsequent forwarder RTS as origination and false-positive. The
count-based rule absorbs single-observation misses statistically: a
missed CTS shifts one of R[X] or C[X] by 1, threshold is set to
tolerate this.

**Mechanism.**
- Per direct sender X, sliding window (default 5 min):
  - `R[X]` = total RTS-tx observed from X
  - `C[X]` = total CTS-tx observed from X
  - `apparent_origination[X] = max(0, R[X] - C[X])`
- Detection: if `apparent_origination[X] / window > orig_rate_threshold`
  (default 1 origination/min = 6 per 5-min window), mark X
  rate-limited.
- Enforcement: on subsequent RTS-tx from X with no CTS-tx from X in
  the recent ~5 s (= almost certainly originating *now*), NACK with
  `reason = originator_throttle`. The longer-window count drives the
  rate-limit decision; the short-window check just gates which
  specific RTS to NACK (so we don't NACK X's forwarder RTSes when X is
  rate-limited as an originator).
- Plus a per-X total-airtime backstop (e.g., 1/4 of N's duty cycle
  budget) catching any node — forwarder OR originator — pushing
  absurd volumes.

Evasion arithmetic stays positive: a spammer dodging the classifier
by emitting fake CTS-tx before each spam RTS pays **2× the airtime**
per attack (CTS ~50 ms + RTS ~50 ms vs RTS alone). The total-airtime
backstop catches the evader sooner than they'd hit by cooperating.
The evade ratio shrunk from 3× (CTS+ACK fakery) to 2× (CTS-only
fakery) when we relaxed the per-RTS rule, but stays sub-economic.

**Known limitations of the behavioral variant.**
- Statistical false-positives: a legitimate forwarder hit by a
  collision burst can briefly exceed the origination-rate threshold.
  Recovery is automatic — window decays, ratio recovers, rate-limit
  lifts. Not catastrophic but visible.
- Statistical false-negatives: a clever low-rate spammer with good
  timing can evade indefinitely. The total-airtime backstop catches
  extreme volumes; low-volume spam is harder to detect this way.
- A cryptographically-authenticated origin (§8 frame-auth MAC) would
  eliminate both error classes at the cost of per-frame MAC verify.
  The behavioral variant is what works *before* §8 lands.

**Possible direction (not committed).**
- Default to plain-origin variant; switch to behavioral variant
  conditionally on §9 T2 deployment.
- NACK reason 2 = `originator_throttle`; payload byte 0 = observed
  fraction × 16 (so the origin's app can show "rate limited by network
  — X/16 of fair share consumed").
- Sliding window default: 5 min. Fair share default: 1/16 of N's
  duty-cycle budget.

**Open questions.**
- Sliding-window length: 5 min responsive; 1 h (matching duty cycle)
  smoother but evade-by-move is easier.
- Per-1st-hop tracking can be reset by the origin moving between
  neighbour clusters. Mitigations (gossip, cross-1st-hop sharing) cost
  airtime and add collusion surface — flagged as a known limitation.
- Forwarder identification under T2 privacy without behavioral
  fingerprint: would require cryptographic proof of origination
  (signed frames, §8), much heavier.

**Cross-references.** Composes with §8 cryptography (signed frames
would make origin-attribution authoritative even with encryption) and
§9 privacy (the behavioral variant is the answer to "does T2 break
anti-spam?" — answer: no, but it changes the granularity from
per-origin to per-sender behaviorally classified).

---

## 2. Mobile nodes (layered endpoint model) (IMPLEMENTED)

**Status — IMPLEMENTED.** `is_mobile` flag, per-layer `routing_sf` /
`allowed_data_sfs`, mobile-as-transit penalty, gateway scheduling
(§7.3), and cross-layer DATA handoff all live in
`scenarios/dv_dual_sf.lua` and are exercised by `t21_mobility`,
`t45_mobile_path_loss_*`, `t52_mobile_identity_beacon`, plus
`scenarios/s07_seattle_mobile_realistic.json` and
`scenarios/s08_seattle_mobile_lifecycle_2h.json`. The text below
preserves the original design rationale.

**Problem.** Mobile nodes (handhelds moving between coverage zones) cause
routing-table churn because their direct neighbours change faster than static
routes age. Treating them as ordinary relays makes the static mesh route
through moving endpoints and wastes RTS attempts when the device leaves.

Routing-table churn compounded by mobility is one of the worst failure modes
observed in the mobile scenarios. The design goal is to model real firmware:
mobiles are endpoints in a radio layer with their own control/data SF policy,
not a special simulator-only mode.

**Architecture.**
- Every node has a `layer_id` in config. The on-wire `leaf_id` is derived as
  `layer_id & 0x0f`; it is the compact layer nibble carried in BCN/RTS.
- A layer owns normal radio policy: `routing_sf`, `allowed_data_sfs`, beacon
  period, and route aging. There is no `mobile_control_sf` shortcut.
- `is_mobile` is orthogonal to layer. It describes endpoint behavior:
  mobile nodes do not forward third-party traffic and should be penalized as
  transit next-hops, but their SFs come from their layer config.
- Mobile fleets can therefore live in layer 2 while the city/static mesh lives
  in layer 1. Layer 2 may also contain stationary nodes when useful, for
  example a fixed layer-2 access point.
- Gateways are the bridge between layers. A gateway has a primary layer and
  optional secondary layers; it retunes between them using the §7.3 schedule
  mechanism and shares one physical duty-cycle budget across all layers.

Example mobile endpoint:

```json
{
  "id": "mobile_bike_west_east",
  "config": {
    "layer_id": 2,
    "routing_sf": 9,
    "allowed_data_sfs": [8, 9, 10],
    "is_mobile": true
  }
}
```

Example static layer bridge:

```json
{
  "id": "Capitol_Hill_Prime",
  "config": {
    "layer_id": 1,
    "routing_sf": 8,
    "allowed_data_sfs": [7, 9, 10],
    "is_gateway": true,
    "gateway_layers": [
      {
        "layer_id": 2,
        "routing_sf": 9,
        "allowed_data_sfs": [8, 9, 10],
        "period_ms": 300000,
        "duration_ms": 20000
      }
    ]
  }
}
```

**Mobile and gateway are mutually exclusive by design.** `is_mobile=1` and
`is_gateway=1` cannot both be set on the same node. Gateway schedules and
cross-layer route maintenance require stable radio presence and stable BCN
neighbour sets; a moving bridge would force schedule re-anchoring at every
peer on every motion event, plus the per-layer `rt[]` would churn with the
gateway's own movement. This is a deliberate v1+ design constraint, not a
temporary limitation — vehicle-mounted nodes that need both roles must use
two separate radios with two distinct node IDs. Stationary layer-2 nodes
(e.g., a fixed layer-2 access point serving a mobile fleet) are allowed
and expected.

### Tier 1 — Intra-layer mobility

The user moves within one configured layer. Their `(layer_id, node_id)` stays
the same; only physical position and direct-neighbour set shift.

**Mechanism.**
- Per-node `is_mobile` config flag (default false).
- BCN carries the `is_mobile` bit alongside `self_gateway_flag` from §7.2 and
  always carries `key_hash32`. Mobile nodes emit identity-only BCNs
  (`n_entries=0`, no seen bitmap, no route extension) so neighbours can bind
  `node_id -> key_hash32` without learning mobile transit routes.
- Mobile nodes silently drop inbound RTS where `dst != self.id` AND
  `origin != self.id` (= forwarding request from someone else for a third
  party). Diagnostic emit: `rts_drop_mobile_no_forward`.
- `route_strictly_better`: candidates whose `next_hop` is mobile AND whose
  route's `dest != next_hop` get a heavy score penalty
  (`mobile_route_penalty_db`, default 20). Effectively excludes mobiles from
  being selected as relay hops for third-party traffic.
- `route_strictly_better` (gateway variant): candidates whose `next_hop` is a
  gateway AND whose route's `dest != next_hop` get a milder score penalty
  (`gateway_transit_penalty_db`, default 8). Gateways stay selectable when
  they're the only path, but in-leaf traffic prefers non-gateway routes —
  protecting the gateway's shared duty-cycle budget for actual cross-layer
  forwarding. Smaller than the mobile penalty because gateways are stable
  and may legitimately sit at topology choke points.
- Mobile route changes do not schedule triggered DV beacons. Periodic
  identity-only BCN plus Q/REQ_SYNC handle endpoint discovery while avoiding
  route churn as the mobile moves.
- Route entries where the destination or next hop is mobile may use shorter
  aging than static routes, but this should be tuned per scenario. Earlier
  experiments with overly aggressive mobile TTLs caused `send_no_route`
  churn, so the default stays conservative until the layer/gateway model is
  implemented and measured.

**Composes with §1 anti-spam** without changes: per-1st-hop counters reset
naturally as a mobile's set of direct neighbours shifts; each new neighbour
starts fresh observation counts.

### Tier 2 — Cross-layer reachability through gateways

When a static layer-1 node wants to reach a mobile in layer 2:

1. The origin routes normally inside layer 1 toward a gateway candidate.
2. The gateway retunes to layer 2 during its advertised schedule window.
3. The gateway forwards the DATA into layer 2 using the layer-2 route table.
4. The mobile receives as an endpoint. It is not advertised as a third-party
   relay for layer-1 traffic.

This is intentionally the same mechanism needed for future multi-layer
networks. Mobiles do not get a special transport; they are the first practical
test case for §7.3.

Current implementation state:
1. `layer_id` in JSON and `leaf_id = layer_id & 0x0f` derivation are implemented.
2. Layer-specific `routing_sf` and `allowed_data_sfs` are implemented in scenarios.
3. Gateway secondary-layer config, BCN schedule emission, and schedule telemetry are implemented:
   `gateway_schedule_change`, `gateway_schedule_observed`, and `tx_gateway_schedule_defer`.
4. Single-gateway cross-layer DATA handoff is implemented for known
   `target_layer_id + dst_key_hash32` bindings; unknown bindings are resolved
   lazily with target-layer `Q:HASH_QUERY`.
5. Runtime route/identity state is layer-scoped via `layer_state[layer_id]`.
6. Remaining work: per-layer gateway leases, multi-gateway reachability policy,
   multi-gateway overlap search, and adaptive schedule-offset tuning.

### Composition with other roadmap items

| Subsystem | Mobility impact | Action needed |
|---|---|---|
| **§7.1 hierarchical DATA** | cross-layer reachability needs a layer path | Use existing `addr_len + dst` model once gateway handoff lands |
| **§7.2 BCN** | `is_mobile` bit marks endpoint behavior; `leaf_id` is `layer_id & 0x0f` | +0 wire bytes; update semantics only |
| **§7.3 inter-layer TDM** | mobiles in layer 2 become the first gateway use case | Implement gateway layer schedule and layer-local route tables |
| **§1 anti-spam** | per-1st-hop counters reset naturally as neighbour sets shift | No protocol change; works as-is |
| **§5 E2E ACK** | reverse path may fail while a mobile moves | ACK timeout surfaces to app; no special soft state |
| **§8.1 crypto** | `session_key` is identity-derived; `ctr` per-pair persisted in NV | Crypto survives moves; routing has to find the endpoint |

### What this design deliberately doesn't solve

- **Global identity/address book movement.** A long-term user identity that
  roams between unrelated administrative deployments remains an app-layer
  problem.
- **Seamless mid-flight handoff.** A DATA flight already in progress may fail
  if the mobile leaves layer coverage. Normal retry/discovery handles later
  sends.
- **Group/channel membership when mobile.** Group chats (§6) where members move
  are an open question; deferred to §6 design.
- **HLR-style permanent home address.** Cellular-network-style "always
  reachable at your home address" is NOT in this design.
- **Auto-detection of mobile vs static.** Explicit `is_mobile` config flag
  only.

### Tunables (as implemented)

Final implementation uses the generic peer-liveness penalty system
(`peer_{suspect,silent,dead}_penalty_q4` in PROTOCOL) rather than
the dedicated mobile/gateway-transit penalty knobs originally
proposed. Mobile-as-transit refusal is handled directly in
`next_hop_selectable` (silent skip).

| Key | Default | Purpose |
|---|---|---|
| `layer_id` | 0 | Logical radio/routing layer; on-wire `leaf_id = layer_id & 0x0f` |
| `is_mobile` | false | Per-node endpoint flag; mutually exclusive with `is_gateway` |
| `is_gateway` | false | Per-node gateway flag |
| `gateway_layers` | `{}` | Per-gateway secondary-layer schedule records (period/duration/offset per record) |

The originally-proposed `mobile_neighbor_change_threshold` /
`mobile_change_window_ms` / `mobile_route_penalty_db` /
`gateway_transit_penalty_db` knobs are superseded: the
periodic-identity BCN mechanism replaces the change-detection
trigger, and the generic peer-penalty machinery covers transit
disincentive.

### Implementation cost estimate

- `layer_id` config + `leaf_id` derivation/backward compatibility: ~30 lines
- Mobile forwarding refusal + mobile transit penalty: already live / small
- Gateway transit penalty in `route_strictly_better`: ~10 lines
- Layer-specific scenario defaults for routing/data SFs: ~30 lines
- Gateway secondary-layer config parser: ~50 lines
- Gateway layer schedule state machine + telemetry: ~150 lines
- Hold-at-gateway-neighbor in forwarder TX path (schedule cache lookup +
  outbound-queue defer when `next` gateway is in upper-layer window): ~50 lines
- Cross-layer route table context + DATA handoff: ~150-250 lines
- Tests: layer filter, layer-2 mobile visibility, gateway schedule, static→mobile
  cross-layer DATA, mobile-not-forwarding, gateway-transit penalty prefers
  non-gateway path when available, hold-at-gateway-neighbor defers correctly
  during upper-layer window: ~260 lines

**Cross-references.** §7.1 (hierarchical DATA carries cross-layer path),
§7.2 (`is_mobile`, `self_gateway`, and schedule bits live in BCN), §7.3
(gateway TDM is the mobility access mechanism), §1 (anti-spam unaffected),
§5 (E2E ACK during movement can time out), §8.1 (crypto identity is
mobility-stable).

---

## 2a. Lightweight node join and short-address leasing (IMPLEMENTED)

**Status — IMPLEMENTED (model-side).** Full state machine LISTEN →
DISCOVER → OFFER → CLAIM → GUARD → ADOPT lives in
`scenarios/dv_dual_sf.lua` with NV-persisted `claim_epoch`,
real `lease_age_seconds`, addr-conflict recovery (defense +
tie-break + forced rejoin), and per-observer J-frame rate-limiting.
Covered by `t46_node_id_split` through `t60_addr_conflict_forced_rejoin`.
NV semantics, `(layer_id, key_hash32) → node_id` bindings, partition-
merge recovery, and gateway cross-layer leasing are all functional;
the C++ port will inherit the same wire formats and state machine.
The text below preserves the original design rationale.

**Problem.** Scenario JSON currently gives each node its 8-bit mesh address.
That is useful for simulation control, but unrealistic for firmware. Real
devices have a long-term cryptographic identity and must acquire a compact
layer-local routing address after boot.

**Design principle.** The 8-bit `node_id` is a lease, not identity. The real
identity is the node's crypto public key from §8.1. BCN now carries a fixed
`key_hash32` beside `src`, so every periodic identity assertion is checkable.
DATA remains privacy-preserving and does not expose original sender identity in
clear.

### Identity model

- **Permanent identity:** node public key from §8.1. This is the stable device
  identity and later proves ownership of encrypted DATA/session keys.
- **Compact identity marker:** `key_hash32` or `key_hash64`, derived from the
  public key. This is enough for join conflict detection and local binding
  tables. Full public key exchange stays pull-based via the identity-card
  mechanism from §8.1.
- **Layer-local address:** `node_id` in range `0..254`, unique only inside one
  `layer_id`. `0xff` is reserved as the temporary unjoined sender id and
  broadcast/special marker.
- **Human name:** app-layer metadata. A node may answer a DATA/name query, but
  names are not part of routing, join, or BCN control.

Simulator schema should separate these concerns:

```json
{
  "name": "Capitol_Hill_Prime",
  "public_key": "sim-generated-or-fixed",
  "node_id": null,
  "config": {
    "layer_id": 1,
    "join_required": true
  }
}
```

For deterministic tests, scenarios may still pin `node_id`, but firmware-mode
scenarios should start with `node_id = null` and force join.

### Local binding table

Every node keeps a small observation table:

```text
id_bind[node_id] = {
  key_hash,
  first_seen_ms,
  last_seen_ms,
  last_key_seen_ms,
  source,       -- bcn, j_claim, j_deny, identity_reply, data_auth, self
  confidence,   -- weak, claimed, authenticated
  conflict_hash -- optional last different hash seen for same node_id
}
```

Rules:
- Same `node_id`, same `key_hash`: refresh `last_seen_ms`.
- Same `node_id`, different `key_hash`: mark conflict and emit
  `addr_conflict_observed`.
- BCN always carries `key_hash32`. Same `src`, same hash refreshes both
  `last_seen_ms` and `last_key_seen_ms`; no binding creates one with
  `source=bcn`, `confidence=claimed`.
- Plain non-identity traffic with `src=node_id` and no key hash may refresh
  `last_seen_ms` if the binding exists. It does not create a binding and does
  not upgrade confidence.
- Any identity-carrying frame with a matching key hash refreshes both
  `last_seen_ms` and `last_key_seen_ms`.
- Authenticated DATA or identity-card proof upgrades confidence to
  `authenticated`.
- Bindings expire after a long absent timeout; exact value is deployment
  policy, not the route-aging TTL.

The binding table is not part of route selection. Routing still uses compact
8-bit IDs. The binding table answers "is this still the same device?".

### Join frame family

`Q` is intentionally not reused for first join because Q assumes the sender
already owns a normal short address. An unjoined device transmits `J` frames
with temporary source id `255` until adoption. The implemented first slice is a
compact tag-byte `J` control family on the control SF:

```text
J_DISCOVER:
  tag='J'
  op=discover
  leaf_id
  key_hash32
  flags: mobile, stationary, gateway-capable

J_OFFER:
  tag='J'
  op=offer
  leaf_id
  responder_node_id
  responder_key_hash32
  data_sf_bitmap
  flags

J_CLAIM:
  tag='J'
  op=claim
  leaf_id
  proposed_node_id
  key_hash32
  lease_age_seconds
  claim_epoch
  nonce
  flags

J_DENY:
  tag='J'
  op=deny
  leaf_id
  denied_node_id
  owner_key_hash32
  claimant_key_hash32
  owner_lease_age_seconds
  owner_claim_epoch
  reason
```

`key_hash32` is the first version because it is cheap. If false conflicts show
up in larger tests, move to `key_hash64` or make `J_DENY` request the full
identity card before forcing a rejoin.

`lease_age_seconds` is saturating and local-clock relative. It is not used for
absolute ordering across independent clocks; it only says "this binding has
been continuously held for roughly this long". `claim_epoch` is a small
monotonic-per-boot counter incremented on every new claim attempt. Together
they make conflicts observable on wire, but the final deterministic fallback is
still key-hash ordering because partitions have no shared clock.

### Join state machine

**Implemented status (2026-05-17).** The simulator/Lua firmware now supports a
minimal autonomous happy path:

- `config.join_required=true` starts the node as unjoined `id=255`.
- The node emits `join_listen_start/end`, then `J_DISCOVER`; if no offer is
  received it retries with backoff and can optionally emit
  `join_discover_exhausted` after a configured attempt cap.
- Joined neighbours answer with jittered `J_OFFER`, carrying `data_sf_bitmap`.
- Only unjoined/join-required nodes adopt DATA SF policy from `J_OFFER`.
- The joiner chooses a random locally-free id, emits `J_CLAIM`, waits
  `join_claim_guard_ms`, then adopts via the runtime `set_protocol_id` hook.
- Existing nodes add observed claims to `id_bind`; conflicting owned/bound IDs
  trigger `J_DENY`.
- Pending simultaneous claims for the same id are compared deterministically
  by `(key_hash32, nonce)`; the losing pending claim backs off instead of
  adopting.
- A focused test covers a stable 3-node network plus a 4th unjoined node:
  `test/t48_join_autonomous_fourth_node.json`.

Known deviations/gaps versus the full design:

- J-frame anti-spam is implemented for untrusted joiner-originated
  `J_DISCOVER`/`J_CLAIM` frames by `(opcode,key_hash32)` sliding window.
  `J_OFFER`/`J_DENY` are not rate-limited in this first slice to avoid
  suppressing legitimate responder traffic during cold boot.
- Fixed BCN `key_hash32` is implemented. Mobile BCNs carry the same identity
  hash but no route entries.
- Partition-merge resolution is functionally implemented via the
  addr_conflict recovery action: when `id_bind_set` detects a key
  mismatch on `self.id` for an adopted owner, it emits a defensive
  J_DENY (new reason code `J_DENY_REASON_OWN_ID_DEFENSE = 3`) carrying
  the defender's `lease_age_seconds` and `claim_epoch`. The duplicate's
  J_DENY handler runs `addr_conflict_tie_break` (older lease wins;
  equal → higher epoch; equal → lower key) and, on loss, calls
  `forced_rejoin` to yield the id and re-run the join state machine.
  Telemetry: `addr_conflict_defense`, `addr_conflict_tie_break`,
  `addr_conflict_forced_rejoin`. Verified by t60. A dedicated
  `J_CONFLICT` opcode is no longer needed — the existing J_DENY frame
  carries everything required.
- `lease_age_seconds` is populated with a real local-clock value:
  `floor((now - adopted_at_ms) / 1000)`, saturating at 65535. `adopted_at_ms`
  is set on `join_adopted` for unjoined nodes and at `on_init` for pre-joined
  (pinned-id) nodes. Both `J_CLAIM` (own lease) and `J_DENY` (defender's
  lease) wire fields now carry the real value.
- `claim_epoch` is NV-backed via a thin `self.nv` shim (`nv_get`/`nv_set`).
  On init the node loads the previously-saved epoch; every increment is
  immediately persisted. The wire field is still 8-bit and wraps after 256
  boots — partition-merge tie-break consumers should handle wraparound
  explicitly. Tests seed the initial NV with `config.nv = {"claim_epoch":N}`.

1. **LISTEN.** Node starts without `node_id`. It listens on its layer control
   SF for `join_listen_ms`, collecting BCN `src`, destination-seen bitmaps,
   optional identity extensions, overheard traffic IDs, and existing `J`
   claims/denies.
2. **DISCOVER.** If passive knowledge is weak or the channel is quiet, the
   node waits an additional randomized `join_discover_jitter_ms` and then emits
   `J_DISCOVER`. The extra jitter is required for power-outage cold starts,
   where many nodes finish LISTEN at the same time and there may be no BCN to
   anchor on. Neighbours answer with `J_OFFER`, carrying the layer DATA SF
   bitmap, and may also schedule existing full/sync BCN responses with jitter,
   reusing the REQ_SYNC collision-avoidance pattern.
3. **CLAIM.** Node chooses an apparently free `node_id` and emits
   `J_CLAIM(proposed_node_id, key_hash, nonce)`.
4. **GUARD.** Node waits `join_claim_guard_ms`. This is deliberately seconds
   to tens of seconds, not an RTS/CTS-scale timeout, because LoRa duty cycle
   and jitter can delay objections.
5. **ADOPT.** If no `J_DENY` arrives, node adopts the ID, creates
   `id_bind[self.id]`, emits a full/sync BCN, then runs normal `Q:REQ_SYNC`.
6. **BACKOFF.** If `J_DENY` arrives, node clears the candidate, waits
   randomized `join_retry_backoff_ms`, and chooses a different ID.

### Claim-and-defend behavior

Existing nodes defend only IDs they believe are owned:
- If `id_bind[proposed_node_id]` exists with a different key hash and has not
  expired, emit `J_DENY`.
- If the node itself owns `proposed_node_id`, emit `J_DENY`.
- If two unjoined nodes claim the same ID, deterministic tie-break by
  `key_hash` avoids endless oscillation. Loser backs off.
- New joiners should select randomly from the apparently-free ID set, not
  first-free. Random selection lowers race probability when several nodes join
  after the same listen window. If a race still happens, `J_DENY` plus the
  deterministic tie-break resolves it.

This protocol does not require perfect first-try consensus. Lost DENY frames
or partition merges can create temporary duplicates; the binding table and
later conflict handling converge them.

### Conflict handling after adoption

If a node later observes the same `node_id` with a different `key_hash`:

1. Emit `addr_conflict_observed`.
2. Send `J_DENY` toward the observed claimant if possible. A future
   `J_CONFLICT` frame may carry third-party conflict evidence after the basic
   join path is stable.
3. If the conflict involves `self.id`, apply deterministic tie-break:
   authenticated binding beats claimed binding; larger advertised lease age
   beats a fresh claim when confidence is equal and the difference is above a
   configured hysteresis; final tie-break by `key_hash`.
4. Loser re-enters JOIN and claims a new ID.

Partition merge is handled by the same mechanism. The design intentionally
keeps this local and slow; forcing immediate global agreement would cost too
much airtime.

There is no assumption that both sides agree who is "older" by wall clock.
Lease age is advisory and saturating; if ages are close or untrusted, the hash
tie-break gives every observer the same answer.

### Duplicate-ID scenarios to cover

1. **Forgotten local ID.** Node retains its permanent key but not its short
   lease. It boots as `255`, sends `J_DISCOVER`, receives `J_OFFER`, and should
   prefer any previously-known ID associated with its `key_hash32` before
   selecting a random free ID. This likely requires adding `suggested_node_id`
   to `J_OFFER` (`255` = no suggestion).
2. **Stale node resumes with recycled ID.** Node believes it still owns short
   ID `X`, but the network has rebound `X` to another key while it was silent.
   When it emits BCN `src=X,key_hash=old`, receivers compare against
   `id_bind[X]=new`, emit `addr_conflict_observed`, and start the conflict
   path. The node receiving a valid `J_DENY` for its active ID and own hash
   must stop normal BCN/DATA, switch to unjoined `255`, and rejoin.
3. **Race join.** Two unjoined nodes select the same free ID after similar
   listen windows. Random ID selection lowers probability; if it still occurs,
   neighbours observe two `J_CLAIM`s or later conflicting BCN hashes and send
   `J_DENY`. The deterministic tie-break prevents endless oscillation.

### Gateway and multi-layer leases

A gateway owns a separate short address lease in each layer where it
participates. The primary layer lease is acquired at boot. Secondary-layer
leases are acquired during the first scheduled sweep for that layer, before the
gateway advertises itself as reachable there.

State shape:

```text
layer_state[layer_id] = {
  node_id,
  join_state,
  id_bind,
  rt,
  routing_sf,
  allowed_data_sfs
}
```

Gateway schedule records should not be advertised for a secondary layer until
that layer has either a pinned `node_id` or an adopted lease. A failed
secondary-layer join does not invalidate the primary-layer lease; it only means
the gateway is not yet usable as a bridge to that layer.

Future cross-layer mobile re-association follows the same model: the mobile
claims a separate short ID in the new layer, then app/identity state maps the
same public key to the new layer-local address.

### BCN and identity hash policy

BCN carries `key_hash32` as a fixed field. This adds 4 bytes to every BCN, but
it turns duplicate short-id detection from RF heuristics into deterministic
identity evidence:

```text
BCN src=X key_hash=A, id_bind[X]=A  → refresh binding
BCN src=X key_hash=B, id_bind[X]=A  → addr_conflict_observed
```

Rationale:

- Every BCN already asserts "I am short id X"; the hash makes that assertion
  checkable.
- Nodes that forgot their short ID can rediscover their previous lease by
  key hash.
- Nodes that were silent long enough for the network to recycle their ID are
  detected when their BCN hash no longer matches `id_bind[X]`.
- New joiners learn identity bindings passively without waiting for J traffic.

Privacy tradeoff: passive observers can link the same long-term key hash across
short-id changes. If this becomes unacceptable, the future privacy mode can
replace `key_hash32` with `trunc32(HMAC(network_psk, public_key || epoch))`,
rotated by network epoch. The first implementation uses plain `key_hash32`.

Other identity paths remain useful:

- `J_DISCOVER` / `J_CLAIM` / `J_DENY` / `J_OFFER` carry hashes for join and
  conflict handling.
- A node may request a full identity card on demand via the §8.1 pull path.
- Authenticated DATA can upgrade `id_bind` confidence without revealing sender
  identity to relays.

### Tunables

Post-audit (`docs/CONFIG_AUDIT.md`), all `join_*` knobs except
`join_required` are **PROTOCOL constants** in the C++ port — Lua
tests can override them as an escape hatch, but production firmware
hardcodes them.

| Key | Default | Purpose |
|---|---|---|
| `join_required` | false in legacy scenarios, true in firmware-mode scenarios | Boot without a short node_id and run join |
| `join_listen_ms` | 3000 implemented first-slice default; production target 30000 | Passive listen before discovery/claim |
| `join_discover_jitter_ms` | 3000 implemented first-slice default; production target 5000..30000 randomized | Spread cold-start `J_DISCOVER` bursts |
| `join_discover_wait_ms` | 10000 | Wait after `J_DISCOVER` for an offer before retrying |
| `join_discover_max_attempts` | 0 | Optional cap before `join_discover_exhausted`; `0` means unlimited retry |
| `join_offer_backoff_min_ms` / `join_offer_backoff_max_ms` | 100 / 1000 | Jitter neighbour `J_OFFER` responses |
| `join_claim_guard_ms` | 3000 implemented first-slice default; production target 30000 | Objection window after `J_CLAIM` |
| `join_retry_backoff_ms` | 10000 implemented first-slice default; production target 10000..60000 randomized | Delay before retrying after conflict |
| `id_bind_ttl_ms` | 172800000 implemented first-slice default (48 h); deployment policy may choose longer | Recycle absent short IDs only after identity lease expiry |
| `join_hash_bits` | 32 | Compact key hash size used in first implementation |
| `join_j_rate_limit_window_ms` | 300000 | Per-key-hash J-frame rate-limit window |
| `join_j_max_per_window` | 6 | Max accepted J frames per key hash per observer window |

### Join anti-spam

Unjoined nodes do not yet have a trusted 8-bit `src`, so normal §1 anti-spam
does not apply. Observers therefore rate-limit `J` frames by `key_hash32`:

```text
join_j_seen[key_hash32] = sliding window of J_DISCOVER/J_OFFER/J_CLAIM/J_DENY
if count > join_j_max_per_window:
  ignore J frame and emit join_j_rate_limited
```

This is not cryptographic security: an attacker can rotate hashes. It is still
useful against buggy firmware and naive spam, and it keeps legitimate join
traffic rare. A later authenticated join can MAC/sign the J nonce under the
device key or install PSK.

### Telemetry

The analyzer should be able to distinguish "join is slow but converging" from
"join is thrashing". The implementation should emit:

- `join_listen_start`
- `join_listen_end`
- `join_discover_sent`
- `join_discover_received`
- `join_discover_retry_scheduled`
- `join_discover_exhausted`
- `join_offer_sent`
- `join_offer_received`
- `join_data_sfs_adopted`
- `join_claim_sent`
- `join_claim_received`
- `join_deny_sent`
- `join_deny_received`
- `join_claim_denied`
- `join_adopted`
- `addr_conflict_observed`
- `partition_merge_resolved` (future; not emitted by the first slice)
- `join_j_rate_limited`

Each event should include `layer_id`, `leaf_id`, candidate/adopted `node_id`
when known, `key_hash32`, and reason.

### Implementation phases

1. **Done.** Split simulator `name` from protocol `node_id`; allow
   `node_id = null`.
2. **Done.** Add `public_key`/`key_hash32` simulation identity generation.
3. **Done.** Unjoined node state using temporary id `255`; normal beacon
   emission suppressed while unjoined.
4. **Done.** `J_DISCOVER`, `J_OFFER`, `J_CLAIM`, `J_DENY` encode/decode,
   discover jitter, claim epoch (NV-persisted), real `lease_age_seconds`,
   J-frame rate limiting (`join_j_rate_limited`).
5. **Done.** `id_bind`, plain-frame refresh policy, BCN `key_hash32`,
   conflict detection (`addr_conflict_observed`), and post-adoption
   recovery (defense + deterministic tie-break + forced rejoin).
6. **Done.** Gateway per-layer join uses active layer context; cross-
   layer DATA handoff (§7.3) with `gateway_remote_bind` is functional
   including the `Q:HASH_QUERY` deferred-binding-resolution path.
7. **Done.** `t46`–`t60` cover quiet network, dense network, duplicate
   claim, prior-id preference, simultaneous-claim race, partition merge.
8. **Done.** s07/s08 connect join to mobile/gateway scenarios.

**Cross-references.** §2 uses `layer_id` and mobile endpoint behavior; §7.3
uses the same layer model for gateways; §8.1 provides the cryptographic
identity and identity-card request path; PROTOCOL §11a already provides the
REQ_SYNC/sync-BCN pattern reused by `J_DISCOVER`.

---

## 3. Channels (unified primitive — public, group, private)

**Problem.** Mesh networks need multi-recipient communication beyond per-pair DM (§7.1, §8.1): public alerts, friend group chats, family/team private discussions. Pure flood is not viable (saturates duty cycle in dense meshes); per-recipient unicast doesn't scale beyond ~5 members. We need ONE multi-recipient primitive with policy variations for the three flavors.

**Design principle.** A SINGLE wire-level delivery mechanism — **the multicast DATA frame defined in §7.5** — serves all three channel flavors. The two modes of §7.5 cover the spectrum:

- `dst_count > 0` (explicit-list multicast) → group / private channels
- `dst_count == 0` (multicast-to-all) → public channels

**Public / group / private differ ONLY in (a) crypto choice, (b) admission policy, and (c) which §7.5 mode they use** — all of these are app-layer / config concerns layered on top of the same wire primitive.

This consolidates what was previously sketched in §3 (public broadcast) and §6 (ad-hoc channels) into one coherent design built on §7.5.

### The three flavors

| Flavor | §7.5 mode | Membership | Crypto | Discovery | Use case |
|---|---|---|---|---|---|
| **Public** | `dst_count = 0` (multicast-to-all) | Open (anyone listens / posts) | None — plaintext | Channel ID published openly (well-known list, app config) | System alerts, weather, emergency, public announcements |
| **Group** | `dst_count > 0` (explicit list) | Anyone with the channel PSK | Symmetric channel PSK (ChaCha20+MAC) | Channel ID + PSK distributed at invitation (QR code, in-app share); recipient list known to originator | Friend group chat, team coordination, neighborhood watch |
| **Private** | `dst_count > 0` (explicit list) | Strict member-list, signed by admin | Group PSK + per-message author signature (Ed25519) | Member-list managed by admin, distributed via signed announcement | Family chat, sensitive discussion |

### Channel ID (1 byte)

Channel ID is **not on the wire** as a separate field — it's encoded INSIDE the encrypted payload (group/private) or inside the plaintext payload (public). The wire-level multicast frame (§7.5) doesn't need to know the channel ID — it just needs to know who to deliver to (explicit list) or "everyone" (multicast-to-all).

**Reason this works:**
- Recipients (whether explicit list or "all") decrypt/parse the payload to discover the channel ID
- App layer routes to the appropriate channel handler based on the channel ID
- Non-recipients in multicast-to-all mode simply ignore channel-IDs they don't subscribe to (app-layer filter)

This keeps the wire format minimal — no special channel-frame-type at the protocol layer.

### Encrypted body structure

The body inside the §7.5 multicast frame:

| Flavor | Inner payload structure |
|---|---|
| **Public** | `channel_id(1B) | user_text(N)` — plaintext; no encryption needed (anyone receiving multicast-to-all sees it; app-layer filter by channel ID) |
| **Group** | `ChaCha20(channel_psk, derive_nonce(ctr, channel_id), [channel_id(1B) | user_text(N)]) + MAC(4B)` — symmetric group key |
| **Private** | `ChaCha20(channel_psk, ...) + Ed25519_sig(author_id_key, ciphertext truncated to 16 B)` — sig replaces MAC; verifies author identity against channel's known member-list |

For private channels, the author identity is in the encrypted body:
```
inner = author_pubkey_hash(2B) | channel_id(1B) | user_text(N) | author_signature(16B truncated)
```

Author's pubkey is one of the channel's known member identities. Verifier checks signature against each known member's pubkey; first match identifies author. 16-byte truncated Ed25519 sig gives 2⁻¹²⁸ forgery probability — strong enough.

### Delivery via §7.5 multicast

All channel messages are sent as §7.5 multicast frames. The mode chosen depends on the channel flavor:

**Public channel send:**
```
Sender encodes: channel_id + user_text (plaintext)
Sender issues §7.5 multicast with dst_count = 0 (multicast-to-all)
Mesh delivers to every reachable node via loose-tree-on-all-rt[] forwarding
Every receiving node: app-layer checks if it subscribes to channel_id;
  if yes, deliver to app; if no, drop silently
```

**Group / private channel send:**
```
Sender knows the channel's current member list (from QR-share or app-layer manifest)
Sender encrypts payload with channel PSK (group) or PSK+sig (private)
Sender issues §7.5 multicast with dst_count = N, dst_list = current members
Mesh delivers via explicit-list loose-tree forwarding to those specific members
Receiving members trial-verify MAC/sig and decrypt
```

**This means forwarders need ZERO channel-specific state.** They just route §7.5 multicast frames. The channel layer is purely at the endpoints (senders + recipients). 

### Open problem: subscriber discovery for group/private channels

The §7.5 explicit-list mode REQUIRES the originator to know the recipient list. For group/private channels with stable membership (QR-share at invite time), this is fine — the app maintains the list locally.

But three scenarios need design attention:
- **New member joins**: how do other members learn the new member is now a recipient?
- **Member leaves / is removed**: how do other members stop including them in their dst_list?
- **Member-list sync across the group**: what happens when alice's local member-list disagrees with bob's?

This is the still-open subscriber-discovery problem. Options to be discussed:
- App-layer "membership manifest" distributed at join, refreshed on changes (each member maintains own list; updates via signed broadcast)
- Server-registry (per §3 server discussion) — single source of truth
- Bloom filter in BCN — approximate; useful only for hint-based discovery
- Pull-based query when sender doesn't know membership

**For now, this is parked as a separate design item — see "Open problems" below.**

### Cross-leaf channel bridging (configured gateway)

Channels are intra-leaf by design. Cross-leaf bridging requires explicit operator configuration at gateways. The gateway receives the §7.5 multicast frame in one leaf, translates encryption if needed, and re-emits as a multicast frame in the destination leaf.

**Gateway configuration:**
```
bridge_channels = [
  { src_leaf=33, src_ch=3, dst_leaf=27, dst_ch=7, src_psk=..., dst_psk=... },
  { src_leaf=27, src_ch=7, dst_leaf=33, dst_ch=3, src_psk=..., dst_psk=... },  -- reverse direction
]
```

**Gateway behavior** on receiving a channel-3 multicast in leaf 33:
1. Decrypt using leaf-33 channel-3 PSK (or skip if public)
2. Read out channel_id from decrypted payload
3. Re-encrypt using leaf-27 channel-7 PSK (or skip if public)
4. Emit §7.5 multicast in leaf 27 with the destination list translated to leaf-27 member IDs (for group/private; or `dst_count=0` for public-channel-bridging)

**The gateway is a TRUSTED INTERMEDIARY** for channels — it sees plaintext during translation. Different from §7.1 DM where end-to-end confidentiality means gateways can't read user content. **For channels, bridge-by-trust is the design** (real-world IRC/Discord bridges work this way).

For PUBLIC channels: bridging is trivial — gateway just relays plaintext between configured (src_leaf, src_ch) ↔ (dst_leaf, dst_ch) pairs, possibly with channel_id remapping. Uses `dst_count=0` multicast-to-all on both sides.

### Open problems (parked for separate discussion)

The unified §7.5-based delivery is settled, but **subscriber discovery for group/private channels** is still open:

1. **New-member onboarding** — how does an existing member learn that bob just joined channel X?
2. **Member-list sync** — what happens when alice's local member-list for channel X differs from carol's?
3. **Member removal** — how does the group propagate "bob is out" + new PSK to remaining members securely?
4. **Stale-member handling** — if alice sends to {bob, carol, dave} but dave has left and rotated keys, dave still gets the frame but can't decrypt; no harm done, but he sees "garbage from alice"

Possible directions (TBD):
- App-layer "membership manifest" — each member maintains the list locally; updates via signed broadcast from admin
- Server-registry (per the §3 server discussion) — single source of truth queried before send
- Bloom filter in BCN — approximate; useful as a hint but not authoritative
- Pull-based query — sender asks "members of channel X?" before send, caches the answer

These belong to a follow-up design pass; the §7.5 delivery mechanism is independent of whichever discovery method we choose.

### Composition with other roadmap items

| Subsystem | Channel impact |
|---|---|
| **§7.1 DATA** | Channel messages don't use unicast DATA — they always go through §7.5 multicast |
| **§7.2 BCN** | **No mandatory subscription extension needed** for the multicast-based design. Optional BCN subscription advertisement remains useful if a discovery-by-BCN approach is later chosen, but it's not baseline. |
| **§7.3 inter-layer** | Channels are intra-leaf; cross-leaf bridging is via configured gateway re-encryption — NOT via TDM scheduling. Channel messages stay at leaf SF. |
| **§7.5 multicast** | **The delivery mechanism**. All three flavors use §7.5; differ only in `dst_count` and crypto. |
| **§1 anti-spam** | Per-1st-hop counters apply unchanged — the originator of a channel message counts toward their own quota. Future: optional per-channel rate cap at forwarders. |
| **§2 mobile** | Channel subscriptions are app-layer state carried with the user across moves; member-list sync needed (see open problems). |
| **§5 E2E ACK** | Channel messages skip E2E ACK (no single recipient). `E2E_ACK_REQ` MUST be 0 for channel multicast. |
| **§7.4 RTS / CTS / ACK** | Channel multicast still uses standard hop-level RTS-CTS-DATA-ACK chain at each split point. |
| **§8.1 crypto** | Channel uses LEAF-LOCAL group PSK (not §8.1's per-pair X25519 keys). Distribution is operational (QR code at channel join). Forward secrecy not provided. |
| **§9 T2 privacy** | dst_list (when present) is plaintext on wire (forwarders need it for routing). Channel ID lives INSIDE encrypted payload — observers don't learn which channel is being used. Sender identity within encrypted body is hidden. |

### What this design deliberately doesn't solve

- **Reliability guarantees** for channel messages. Best-effort, no per-subscriber ACK. Lost messages stay lost. Apps that need reliability must use unicast DM (§7.1) instead.
- **Cross-leaf channels without operator setup.** Bridging requires manual gateway configuration. No auto-discovery.
- **Per-channel rate limiting beyond §1 anti-spam.** Future enhancement.
- **Forward secrecy** for channel messages. Same trade as §8.1 — channel PSK is reused; rotation requires re-distribution.
- **Member removal in private channels.** Hard problem (removed member still has old PSK). Requires PSK rotation + redistribution to remaining members. App-layer concern; protocol provides the wire to deliver the new key.
- **Subscriber discovery for group/private channels** — parked, see "Open problems" above.
- **Channel discovery primitive** — no "list nearby active channels" mechanism. Channel IDs are well-known (public) or invitation-distributed (group/private).
- **Coverage of newly-joined nodes for public channels.** Public channels use multicast-to-all (§7.5 `dst_count=0`) which only reaches nodes in `rt[]`. New joiners not yet in `rt[]` miss public broadcasts until BCN propagation completes (~5 min).

### Tunables

(Most tunables live at §7.5 multicast. Channel-specific tunables:)

| Key | Default | Purpose |
|---|---|---|
| `channel_rate_cap_per_min` | 10 | (Future) per-channel rate limit at forwarders; prevents single channel saturating |
| `channel_member_list_max` | 64 | App-layer cap on members per channel (depends on member-list-sync mechanism chosen) |

### Implementation cost estimate

- Channel encoding/decoding inside §7.5 payload (channel_id field + flavor-specific crypto): ~80 lines
- Group PSK + per-message Ed25519 signing for private channels: ~100 lines (depends on chosen ed25519 implementation)
- App-layer dispatch on incoming multicast based on channel_id: ~30 lines
- Gateway cross-leaf bridge config + re-encryption: ~80 lines
- Subscriber-discovery mechanism (TBD which approach): ~150-300 lines depending on choice
- Tests: public/group/private message flow, cross-leaf bridge, member-list verification, stale-member behavior: ~200 lines

**Cross-references.** §6 (consolidated into this section), §7.5 (THE delivery mechanism — all flavors use multicast), §7.1 (multicast frame is a §7.1 DATA variant), §7.2 (BCN unchanged for channels), §7.3 (intra-leaf only), §1 (per-1st-hop anti-spam unchanged), §2 (mobile subscriptions need member-list sync), §8.1 (channel PSK independent of per-pair session keys), §9 (channel ID hidden in encrypted body; only dst_list visible).

---

## 4. Compression (BCN + data payload)

**Problem.** LoRa frames cap at 255 bytes and airtime is per-symbol — every byte saved is real channel time recovered. BCN payloads carry repetitive structured data (route entries: dest_id, score, hops, n2_hop, repeated up to ~50 times per beacon). User DATA payloads may carry redundancy (chat text, status messages with common phrases). The 3 B/entry bit-pack work (commit `c0ff7bb`) took the easy wins; further reduction needs algorithmic compression.

**What we want.** Smaller on-wire bytes for BCN and DATA without breaking legacy parsers and without exceeding LoRa CPU budget for decode.

**Constraints.**
- Per-frame overhead (codec dictionary, framing) must amortize on small (< 200 B) frames.
- Decompression cheap enough for SX1262-class hardware (no per-frame Huffman tree rebuild).
- Must coexist with non-compressed legacy frames during rollout.

**Possible directions (none committed).**
- **BCN — run-length on `next_hop`**: nodes typically advertise many destinations via a small set of dominant next-hops; group consecutive entries sharing a next-hop and encode the next-hop once per group. Concrete proposal worked through in §4.1 below.
- **BCN — differential page encoding**: each BCN-page emits only entries whose (dest_id, score, hops) tuple changed since the same node's last advertisement of that dest. Already partly done via the dirty-flag mechanism for advertisement priority; extending to actual on-wire delta would require per-receiver dictionary state.
- **BCN — variable-length node IDs**: small node IDs (frequent neighbours) get 1-byte encoding, distant IDs get 2-byte (varint or escape-byte trick). Trade-off: parser complexity vs ~25% byte reduction in dense neighbourhoods.
- **DATA — app-layer dictionaries**: known message types (status, beacons-on-channel, alerts) compress against a pre-shared dictionary. Generic chat-text compression is marginal at <100 B payload — fixed dictionary overhead dominates LZ77 or Huffman wins.
- **DATA — bit-pack the application protocol** (similar to what we did for the wire protocol): if the application has structured fields with small value ranges, encode them in bits rather than bytes.

**Why not LZW / gzip / zstd on small frames?** Generic compressors need ~100+ bytes before their own header overhead breaks even — our control frames (BCN 4+3n, RTS 8 B, CTS/ACK 2 B) are well under that floor. Even zstd's shared-dictionary mode targets 50-200 B inputs. LZW specifically inflates: its initial 9-bit-over-256-alphabet code width adds ~12% on every symbol, and the dictionary never gets populated enough on a 19 B beacon to amortize that. Worse, LZW operates on byte boundaries; our bit-packed entries cross byte boundaries differently each time, so a repeated 10-bit `next_hop` lands in different bit-positions and byte-LZW literally doesn't see it as repetition. **Domain-specific encoding (the bullets above) is the only thing that wins at this size.** Generic compression is a candidate ONLY for DATA frames carrying ≥ 200 B of natural-language-ish content.

**Open questions.**
- Is the gain worth the codec complexity for the simulator's purposes? The runtime models airtime exactly; compression would just reduce bytes. Maybe just measure achievable compression ratios offline (run zstd over captured payloads) and document the headroom without implementing in-protocol.
- Should we add a `compressed` bit in the frame header to gate the path?
- Per-link compression (negotiated) vs global protocol decision?

**Recommendation.** Defer in-protocol compression. Measure achievable ratios on real payloads offline first; in-protocol codec only if measurements show >20% savings AND the failure mode is byte-limited (not symbol-limited). The §4.1 BCN run-length proposal is the most concrete and lowest-complexity candidate — implement first if the s04 BCN airtime fraction stays high after other optimisations land.

### 4.1 BCN run-length on `next_hop` (concrete proposal)

**Status.** This is a deferred compression proposal from before the fixed BCN
identity hash decision. Current BCN has an 8-byte base header
(`'B'`, flags, `src`, entry flags/count, `key_hash32`) and 3-byte route
entries. A 151-byte cap now fits 47 uncompressed entries.

**Observation.** A node's BCN entries cluster around a small set of dominant next-hops. In a star topology, nearly all entries share `next_hop = gateway`. In typical mesh, a full page is usually distributed across 3-5 distinct next-hops. The current 3 B/entry encoding repeats the 8-bit `next_hop` field for every entry — a clear redundancy.

**Wire format.** Adds a `compressed` flag in byte 1's reserved low nibble. Flag=0 keeps existing 3 B/entry layout (no inflation when compression doesn't help). Flag=1 switches to grouped encoding:

```
Header (size unchanged from current BCN base, 8 B):
byte 0: 'B'
byte 1: layer/BCN flags, with one reserved bit reused as flag_compressed
byte 2: src (8)
byte 3: bitmap/extension flags + n (6) -- semantic entry count, regardless of encoding
bytes 4..7: key_hash32

flag_compressed = 1 body — sequence of groups, each:
  byte g+0: next_hop (8)
  byte g+1: group_count (8)            -- entries sharing this next_hop
  bytes g+2..: group_count × 2 bytes   -- per entry: dest(8) | score_bucket(4 hi) | hops(4 lo)
```

**Encoder logic.**
1. Build the entries list dirty-first (existing differential semantics, capped at `max_entries`).
2. Sort the SELECTED entries by `next_hop` — preserves dirty-first selection; within the selection, sorting maximizes group runs.
3. Compute uncompressed size (`8 + 3n`) and compressed size (`8 + 2g + 2n`, where g = distinct next_hops).
4. Emit whichever is smaller; set `flag_compressed` accordingly. Break-even: compressed wins when `g < n/2` (i.e., average group size > 2).

**Decoder logic.** `parse_beacon` reads `flag_compressed` from byte 1. Flag=0 → existing 3-byte loop. Flag=1 → walk groups, expanding each to (dest, group's next_hop, score, hops). Receivers downstream of `parse_beacon` (`rt_merge`, route scoring) see no difference.

**Illustrative savings (47-entry BCN, 151-byte cap).**

| Distinct next_hops | Uncompressed | Compressed | Saving |
|---|---|---|---|
| 1 (star/gateway) | 149 B | 8 + 2 + 94 = **104 B** | −30% |
| 3 (typical mesh) | 149 B | 8 + 6 + 94 = **108 B** | −28% |
| 8 (well-connected) | 149 B | 8 + 16 + 94 = **118 B** | −21% |
| 24 (sparse uniform) | 149 B | 8 + 48 + 94 = 150 B | flag=0, **0%** |

Worst-case auto-detected and flagged uncompressed (no inflation cost, only the 1-byte tax of always carrying the flag — and that's a free reused reserved bit).

**Open design question.** What to do with the saved bytes:
- (A) **Shrink BCN airtime**: keep `beacon_max_entries=47`; compressed BCN goes ~149 B → ~110 B average. Direct ~25-30% airtime reduction. Simplest.
- (B) **Pack more entries per BCN**: replace entries cap with byte-budget cap (~151 B). Same airtime, but ~65 entries per page when compression helps → faster RT propagation, faster differential drain. Bigger refactor.
- (C) **Hybrid**: byte-budget cap; encoder packs until budget hit. Combines both. Most code change.

A is the obvious starting point — directly delivers the airtime saving the proposal exists to capture.

**Composability.**
- With **§5.6 cascade-requeue** / **§11.5 budget tiers**: smaller BCNs free duty-cycle budget for forwards, so budget tiers stay in HEALTHY longer. Pure win.
- With **§6.2 max-idle override + B+C composite**: composite filter still applies — compression doesn't change WHEN we send BCNs, only how big they are.
- With **§6.4 differential beacons**: dirty-first selection unchanged (sort happens AFTER selection). No semantic change.
- With **legacy/uncompressed peers**: incompatible at the wire layer. The `flag_compressed` bit is in the existing reserved nibble; old parsers that ignore the nibble would parse the body as flat entries → garbage routes. Rollout requires synchronized network-wide upgrade. For the simulator (single codebase, all nodes) this is a non-issue. For real deployment, gate behind a network-wide config flag.

**Implementation cost estimate.** ~80 lines in `pack_beacon`/`parse_beacon` plus ~30 lines of test coverage (round-trip identity, all-same-next, all-distinct-next, mixed). One test scenario needed for the airtime measurement on s04.

---

## 5. End-to-end delivery ACK (optional, per-message) (IMPLEMENTED)

**Status — IMPLEMENTED**. See `scenarios/dv_dual_sf.lua` header doc block
"End-to-end delivery ACK (per-message opt-in)" for the full design.
Verification in `test/t34_e2e_ack.json`.

Mechanism summary:
- Payload header extended from 2 bytes to 3 bytes: `[flags][seq_lo][seq_hi]`.
- Flag bits: `E2E_FLAG_ACK_REQUESTED` (0x01), `E2E_FLAG_IS_ACK` (0x02).
- New send variant `send_e2e <dst> <text>` sets the request bit.
- Originator records `pending_e2e[seq] = {sent_at, dst, text}` on send.
- Destination, on delivered with request bit set, enqueues a tiny return
  DATA frame back to origin with `IS_ACK` flag + body = `[acked_seq_lo,
  acked_seq_hi]`. Forwarders carry it transparently as normal DATA.
- Origin, on receiving DATA with `IS_ACK` flag, matches `acked_seq` against
  `pending_e2e`: emit `delivered_confirmed` (success) or `e2e_ack_unmatched`
  (duplicate / late). 1-s drain loop prunes pending_e2e past
  `e2e_ack_ttl_ms` (default 60 s) → emit `e2e_ack_timeout`.

E2E ACK total wire cost: ~10 B payload per hop × full RTS-CTS-DATA-ACK
chain ≈ 600 ms round-trip airtime on a 3-hop route. Opt-in per-message
so bulk traffic doesn't pay it.

The original problem statement (preserved for context) follows.

---

**Problem.** The hop-by-hop K-frame ACK tells the originator only that the immediately-next forwarder received the DATA. If a forwarder mid-path drops the message, the originator's K-ack still succeeded — the loss is silent. Important user messages (payments, status confirmations) have no way to verify actual delivery.

**What we want.** Optional end-to-end ACK from the *destination* back to the *originator*, requestable per-message via a flag in the DATA frame. Bulk chat doesn't pay the round-trip; explicitly-marked important messages do.

**Constraints.**
- Cost of an E2E ACK is N hops × ~50 ms airtime per direction = significant on routes >3 hops.
- Must not be the default — flooding every message with E2E ACK defeats the duty-cycle budget recovery we just spent weeks fixing.
- E2E ACK can itself be lost; originator needs a timeout + (optional) retry policy.
- **Must compose with §9 T2** — under T2, origin is encrypted and forwarders never see it. The ACK return path can't address `origin` directly. The privacy variant (below) solves this with reverse-path soft state.

**Plain-origin variant (compatible with current header).**
- 1-bit `e2e_ack_requested` flag in the DATA frame's payload header (already has 2 bytes for origin-seq; spare 1 bit there).
- Destination, on accepting DATA (after current hop-by-hop K-ack), additionally sends a new frame `E` (end-to-end ACK) routed back to the originator using normal data-plane mechanics. The `E` frame is tiny: `'E' | dst-of-original (= the responder, 8) | origin-of-original (= the recipient of E, 8) | msg_id (4) | status (4)` ≈ 4 bytes.
- Originator maintains `pending_e2e[(origin, origin_seq)] = { sent_at, ttl }`. On `E` rx → emit `delivered_confirmed`. On TTL expiry → emit `e2e_ack_timeout`. App layer decides retry / surface "not confirmed" to user.
- Forwarders route `E` exactly like a normal RTS-DATA flight from dst to origin (uses existing rt[origin]). No special case.

**Privacy-compatible variant (composes with §9 — origin encrypted).**
The plain variant requires plaintext `origin` in the `E` frame header so forwarders can address the return route via `rt[origin]`. Under §9 T2 the originator's identity is encrypted and forwarders don't see it — so we need a return-routing mechanism that **doesn't carry origin on the wire**.

**Mechanism — reverse-path soft state at forwarders.**
- During the DATA forward leg, each forwarder F passively caches `(msg_id, dst, prev_hop)` with a short TTL (default 30 s — covers typical 3-5 hop round-trip with retries). Cache populated on RTS-rx (when F is the chosen next-hop), confirmed on DATA-rx, evicted at TTL or LRU pressure.
- Destination Z, on accepting DATA with `e2e_ack_requested=1`, generates an `E` frame: `'E' | msg_id (4) | dst-of-original (= Z, 8) | status (4) | reserved` ≈ 3 bytes. **No origin field.** Z transmits to the prev_hop it received the DATA from (Z knows its own prev_hop from the RTS leg).
- Forwarder F receives `E(msg_id, Z, status)` from next-hop direction. F looks up `(msg_id, Z)` in its reverse-path cache. **Cache hit** → forward `E` to cached `prev_hop`. **Cache miss** → silently drop (E2E ACK is best-effort by design; originator's timeout handles it).
- Walks hop by hop back along the original forward path. At originator: `(msg_id, dst-of-original)` matches `pending_e2e[(msg_id, dst-of-original)]` → emit `delivered_confirmed`.

**Why this works under T2.**
- Origin name never appears in any header. Reverse routing is derived entirely from forward-path soft state — not address lookup.
- Forwarder cache key `(msg_id, dst)` references values that were ALREADY visible on the forward DATA leg (both stay plaintext under T2 because forwarders need `dst` for next-hop selection). No new metadata exposed.
- Soft state ages out automatically; no permanent identity-linking residue at any forwarder.

**Cost.**
- Per-forwarder cache: ~10-100 rows depending on traffic. Each row ≈ 4-bit `msg_id` + 8-bit `dst` + 8-bit `prev_hop` + 8-bit `ttl_word` = 28 bits + table overhead. Negligible vs `rt[]`.
- `E`-frame airtime: 1 frame per return hop. Same as plain variant.

**Known limitations of the privacy-compatible variant.**
- `(msg_id, dst)` collisions: msg_id is 4 bits → 16 values. Two flights with the same `(msg_id, dst)` traversing the same forwarder F within TTL → collision. Most-recent-wins eviction means at most one originator gets the correct E; the other times out and (optionally) retries. Mitigation: when DATA carries `e2e_ack_requested=1`, originator could pick a less-collision-prone msg_id (e.g., from a separate 8-bit space gated by the flag). Not catastrophic at typical traffic densities.
- Reverse-path TTL tuning: too short → cache miss on slow paths → ACK lost; too long → cache bloat + collision risk grows. 30 s default sized for 3-5 hop typical paths.
- Forwarder restart loses cache → all in-flight E-acks for that forwarder's downstream traffic time out. One-time cost on forwarder reboot.
- Path asymmetry: if the return path goes through different forwarders than the forward (asymmetric link quality, or forward-path forwarder went silent), the E-frame can't follow because cache only exists on the original forward path. Limitation by design — privacy-compatible E2E ACK is **path-coupled**.

**Possible direction (not committed).**
- Both variants share the wire flag (`e2e_ack_requested`) and the originator's `pending_e2e` state machine. They differ only in how forwarders route the `E` reply.
- Plain variant first (deployable today against current headers). Behavioural switch to privacy-compatible variant when §9 T2 lands.
- Default TTL: 30 s. Default retry policy: app-layer (originator stack surfaces `delivered_confirmed` / `e2e_ack_timeout` events, doesn't auto-retry).
- Reverse-path cache: 64-row LRU per forwarder; eviction = LRU + TTL-driven sweep on `become_free`.

**Open questions.**
- Does the `E` frame use full RTS-CTS-DATA-ACK or a fast-path single-frame? Single-frame ~5% loss probability per hop; full-path doubles airtime. **Recommendation: fast-path** — E2E ACK is already best-effort, and the originator's timeout+retry handles loss. Halves return-path airtime cost.
- Should originators auto-retry on E2E timeout, or always surface to the app layer? **Recommendation: surface only.** Auto-retry compounds airtime under bad conditions (the very condition that caused the original loss). App-layer can decide.
- Reverse-path cache populated on RTS-rx (more time, slight over-caching for flights F doesn't end up forwarding) or on DATA-rx (more accurate, less coverage)? RTS-rx populate, DATA-rx confirm — un-confirmed entries evicted at half TTL.
- Composability with the existing `delivered` script_emit: `delivered` fires at the destination (always), `delivered_confirmed` fires at the originator (only when `e2e_ack_requested=1` AND the E-frame returned). Two distinct events, no conflict.

**Cross-references.** §1 anti-spam (E2E ACK is rate-limited like any other origination), §8 cryptography (E-frame can carry a short MAC under network-PSK auth — prevents spoofed acks-of-success), §9 privacy (the privacy-compatible variant is the answer to "does T2 break E2E ACK?" — answer: no, but it requires reverse-path soft state at forwarders).

---

## 6. ~~On-demand (ad-hoc) channels~~ — consolidated into §3

This section was originally drafted as a separate "ad-hoc channels" concept. It has been **consolidated into §3 (Channels — unified primitive)** as part of the redesign that unified public, group, and private channels under a single protocol mechanism.

The original §6 distinction (public = always-on system-wide; ad-hoc = temporary group) was an artifact of treating them as separate protocols. Under the unified §3 design, both cases are the same primitive — they differ only in (a) how the channel ID is distributed (public = well-known; ad-hoc = QR/invitation), (b) whether the channel has a PSK, and (c) whether the operator has configured cross-leaf bridging for it.

See §3 for the full unified design. Specific concerns originally raised here are addressed in §3 as follows:

- **Channel-ID collision resistance:** channels are leaf-scoped per §3 design, so 1-byte channel IDs are sufficient (256 channels per leaf). For globally-unique ad-hoc channel naming, app-layer can hash a longer name to a 1-byte ID with local-scope collision detection.
- **Subscription state TTL:** §3 specifies "subscriptions persist while node is BCN-visible; aged out when rt[] entry ages out." No separate TTL knob needed.
- **No flooding:** §3 uses subscriber-driven forwarding via `sub_table` populated from neighbor BCNs.
- **Channel rate limits:** §3 reserves `channel_rate_cap_per_min` as a future tunable; for now, §1 anti-spam's per-1st-hop counters apply unchanged.

---

## 7. Multi-network communication

**Problem.** The on-wire filter is only 4 bits. It is too small to be a
globally meaningful administrative network identifier, but it is enough to
separate local radio/routing layers on the same channel.

**Current architecture.** `leaf_id` is the lower 4 bits of `layer_id`:
`leaf_id = layer_id & 0x0f`. JSON keeps the readable `layer_id`; frames carry
only the compact nibble. A deployment that needs administrative separation
should add policy/keys/mesh IDs above this layer rather than overloading the
4-bit field.

**What we want.** Inter-layer gateway functionality. Selected nodes
participate in multiple layers and bridge traffic between them when explicitly
configured. The first practical use case is mobile endpoints in a separate
layer with different control/data SFs; the same mechanism later supports
larger hierarchy.

**Constraints.**
- Gateway nodes carry traffic for >= 2 layers; their 1% duty cycle is shared
  across all of them. Need to prevent one layer from starving another.
- Cross-layer routing must not flood; no automatic advertisement of every
  layer-2/mobile endpoint inside layer 1.
- Security boundary: bridging needs explicit operator policy. A node should
  not accidentally forward sensitive layer-1 traffic into layer 2.

**V1 decision.**
- `leaf_id` is **not an address component**. It remains only the compact
  receiver-side radio filter: `leaf_id = layer_id & 0x0f`.
- `node_id` is layer-local. The routable local address is
  `(layer_id, node_id)`, not bare `node_id`.
- `key_hash32` / public key is the global application identity.
- Cross-layer send uses a loose source route:
  `layer_path[] + dst_key_hash32`. For V1 this is restricted to one boundary:
  `[target_layer_id, dst_key_hash32]`.
- A sender routes locally to a gateway. The gateway resolves
  `dst_key_hash32` inside the target layer and then forwards using the
  target layer's local `node_id`.
- Gateways must not flood every remote/mobile endpoint into ordinary layer-1
  DV beacons. They advertise gateway capability and schedule/policy; remote
  endpoint bindings stay in gateway-local caches.

**V1 implementation slice.**
- Config:
  - ordinary nodes: `layer_id`
  - gateways: `is_gateway=true`, `gateway_layers=[{layer_id=...}]`
- Source command/API: send to `(target_layer_id, dst_key_hash32, body)`.
- Source behavior:
  - if `dst_key_hash32` resolves locally, use normal in-layer DATA;
  - otherwise choose best known gateway candidate and send a gateway envelope
    to that gateway using normal DATA.
- Gateway behavior:
  - unwrap the gateway envelope after local delivery to the gateway;
  - resolve `dst_key_hash32` in its target-layer binding cache;
  - enqueue a normal send to that target layer's local `node_id`.
- Initial Lua slice may use an inner DATA envelope rather than full
  `addr_len>0` DATA. Full hierarchical DATA/RTS remains the wire-final
  format once retune/TDM and per-layer route tables are active.

**Still open after V1.**
- Retune/TDM state machine and per-layer route tables at the gateway.
- Gateway lookup/reply frame versus opportunistic gateway DATA envelope.
- Gateway schedule propagation and hold-at-gateway-neighbor.
- Operator bridge policy: open gateway, layer whitelist, or identity
  whitelist.
- Compose with §8 cryptography: gateways should see routing headers and target
  identity, but not user plaintext once encryption lands.

### 7.0 Wire-format decisions (LOCKED 2026-05-12)

The §7.1 DATA, §7.2 BCN, and §7.4 control-plane (RTS/CTS/ACK/NACK) layouts
below are finalized at bit level. §7.5 multicast wire bits are reserved in
DATA byte 1 (`IS_MULTICAST`) and the dst_count/dst_list field positions
are claimed, but the forwarding algorithm + dedup tables stay TBD until
multicast functionality is reviewed as a whole.

`'Q'`, `'I'`, and `'?'` frames are out of scope for this round.

Locked changes summarize as:

| Frame | Today | Locked | Delta |
|---|---|---|---|
| BCN (47-entry, plain leaf with `key_hash32`) | 149 B | 149 B | 0 (re-pack only) |
| BCN (gateway, 1 upper layer) | n/a | 156 B | +5 B (schedule record) |
| RTS (in-leaf, `addr_len=0`) | 8 B | 8 B | 0 (re-pack) |
| RTS (cross-region, `addr_len=1`) | n/a | 9 B | +1 B per hierarchy hop |
| CTS | 2 B | 2 B | 0 (rename only) |
| ACK | 2 B | 2 B | 0 (rename only) |
| NACK | 4 B | **3 B** | **−1 B** (quantized busy_for_ms) |
| DATA (in-leaf) | 8 B + n | 10 B + n | +2 B (crypto + privacy stubs) |

Wide-spread renames:
- `network_id` (4 bits, in BCN+RTS) → `leaf_id` (4 bits, same role)
- `msg_id` (4 bits, in BCN+RTS+CTS+ACK+NACK+DATA) → `ctr_lo` (4 bits, low nibble of DATA's 16-bit `ctr`)

#### 7.0.1 DATA — locked layout

```
byte 0: 'D'
byte 1: addr_len(3 hi) | rsv(1) | E2E_ACK_REQ(1) | E2E_IS_ACK(1) | IS_MULTICAST(1) | rsv(1)
byte 2: next(8)

if IS_MULTICAST == 0:
  bytes 3..(3+addr_len): dst (addr_len + 1 bytes; front=highest layer, peeled at gateway)

if IS_MULTICAST == 1 (MUST have addr_len == 0):
  byte 3: dst_count(8)
  bytes 4..(3 + dst_count): dst_list (dst_count bytes; OMITTED when dst_count==0)

(then for both variants:)
next 2: ctr (16 bits, little-endian)
next n: ciphertext (plaintext payload until §8 crypto lands)
last 4: MAC (zeros until §8 crypto lands)
```

Byte-1 bit positions (high→low):
- bits 7-5: `addr_len` (3 bits, range 0..7 — covers all realistic hierarchy depths)
- bit 4: reserved (gained from shrinking `addr_len` from 4 bits)
- bit 3 (0x08): `E2E_ACK_REQ`
- bit 2 (0x04): `E2E_IS_ACK`
- bit 1 (0x02): `IS_MULTICAST`
- bit 0 (0x01): reserved

Encrypted inner payload structure (once §8 lands; for now treat as plaintext after the wire `ctr`):
```
inner = src_address_len(1) | src_address(src_address_len + 1) | body
body  = user_text                       -- normal DATA
      | [acked_ctr_lo, acked_ctr_hi]    -- if E2E_FLAG_IS_ACK
```

`ctr` semantics:
- Per-(origin, dst) sender-maintained counter, 16-bit LE, NV-persisted both sides
- Triple duty: crypto-nonce entropy + replay protection + app-layer dedup + source of `ctr_lo` for hop-level matching
- Wrap at 65,536 → forced re-key (~18 years at 10 msg/day; not a practical concern)
- Replay check at destination: strict monotonic — `ctr > last_seen_counter[peer]`
- Hop-level echo: `ctr_lo = ctr & 0xF`, flows into CTS/ACK/NACK

Local-delivery rule: when forwarder receives DATA with `addr_len==0` AND `IS_MULTICAST==0` AND `dst[0]==self.id` → deliver locally.

E2E ACK return-path: destination decrypts payload, reads originator's full hierarchical address from inner `src_address`, constructs a return DATA frame addressed back via that address (`E2E_IS_ACK=1`, body=`[acked_ctr_lo, acked_ctr_hi]`). Forwarders route the return frame via standard `rt[]` lookups — **no special soft-state cache needed**. Composes with §9 T2 because origin's wire address is reconstructed at the destination post-decrypt, never traveling in plaintext on the forward leg.

MAC coverage (implementation-deferred to §8 phase): end-to-end MAC covers `dst_at_origination` + `addr_len_at_origination` + other plaintext fields, NOT the gateway-peeled per-hop values. Gateways peel `dst[0]` but don't re-MAC.

#### 7.0.2 BCN — locked layout

Status update: this section now tracks the implemented Lua wire format, not
the original 2026-05-12 pre-identity layout. BCN has a mandatory `key_hash32`
after byte 3, and gateway schedule records include explicit period encoding.

```
byte 0: 'B'
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
byte 2: src(8)
byte 3: has_seen_bitmap(1 hi) | has_ext(1) | n_entries(6 lo)
bytes 4..7: key_hash32(32 LE)

if has_schedule == 1:
  byte 8: layer_count(8)
  bytes 9..(8 + 4 × layer_count): schedule records (4 B each)

(then n_entries route entries × 3 bytes each, contiguous)
```

Schedule record (4 bytes):
```
byte 0: layer(4 hi) | (sf - 5)(3) | period_unit_5s(1)
byte 1: duration_100ms(8)         -- 0..25.5 s
byte 2: offset_100ms(8)           -- 0..25.5 s from receiver's bcn_rx_time
byte 3: period_units(8)           -- seconds if unit=0, 5-second units if unit=1
```

Route entry (3 bytes):
```
byte 0: dest(8)
byte 1: next(8)
byte 2: score_bucket(4 hi) | (hops - 1)(3) | is_gateway(1 lo)
```

`hops` encoding: wire stores `hops - 1` (range 0..7), in-memory `rt[]` stores `hops` (range 1..8). Preserves today's 8-hop cap exactly. All range checks against `rt[].hops` remain on the 1..8 scale; only `pack_beacon`/`parse_beacon` shift.

`is_gateway` propagation: rides on each rt[] candidate alongside score/hops. Per-candidate storage (since different advertisers can disagree). Tied to existing rt-aging TTLs — no separate lifecycle.

`n_entries` is 6-bit in the implemented packed byte 3. The practical default
page cap is 47 entries to keep normal BCN airtime around the old 151-byte cap
after adding the fixed `key_hash32`.

#### 7.0.3 RTS — locked layout

```
byte 0: 'R'
byte 1: src(8)                                           -- prev-hop (kept; first hop-level frame)
byte 2: next(8)
byte 3: addr_len(3 hi) | rsv(1) | leaf_id(4 lo)          -- same pattern as DATA byte 1
bytes 4..(4 + addr_len): dst (addr_len + 1 bytes)
next 1: ctr_lo(4 hi) | rsv(4 lo)
next 1: sf_bitmap(8)
last 1: payload_len(8)
```

In-leaf size: 8 B (same as today). Each hierarchy hop adds 1 B.

Field changes:
- `origin` (1 B): **REMOVED** (§9 T2 privacy — destination identifies origin via MAC trial-verify + decrypted inner payload)
- `src`: kept — first hop-level frame, receiver has no pending_rx yet
- `dst`: variable, `addr_len + 1` bytes
- `network_id` (4 bits): renamed to `leaf_id`, moved to byte 3 low nibble
- `msg_id` (4 bits): renamed to `ctr_lo`, now in its own byte's high nibble (low nibble reserved)

#### 7.0.4 CTS / ACK — locked layout (rename only)

CTS (2 B, unchanged size):
```
byte 0: 'C'
byte 1: ctr_lo(4 hi) | (sf - 5)(3) | rsv(1)
```

ACK (2 B, unchanged size):
```
byte 0: 'K'
byte 1: ctr_lo(4 hi) | snr_bucket(4 lo)
```

Bit positions and matching semantics identical to today; only the 4-bit `msg_id` slot is renamed `ctr_lo`.

#### 7.0.5 NACK — locked layout (3 B, shrunk from 4 B)

```
byte 0: 'N'
byte 1: reason(4 hi) | ctr_lo(4 lo)
byte 2: payload(8)                       -- reason-specific
```

Payload encoding by reason:

| Reason | Code | Payload meaning | Range / units |
|---|---|---|---|
| `BUSY_RX` | 0 | `busy_for_ms / 16` | 0..4080 ms (16 ms quantum) |
| `BUDGET` | 1 | `tier(4 hi) | headroom_buckets(4 lo)` | tier 0..15, headroom 0..15 (mapped to 0..100%) |
| reserved | 2..15 | future | — |

16 ms quantization on `busy_for_ms` is well below natural retry-jitter floor (~50 ms `retry_jitter_ms`), invisible in practice. 4080 ms ceiling has 4× headroom over realistic SF12 worst-case (~1 s).

#### 7.0.6 Implementation phases

Recommended sequencing to minimize blast radius:

1. **Renames** — `network_id` → `leaf_id`, `msg_id` → `ctr_lo`. Pure internal; no wire-format change. Smallest blast radius, validates the codepath.
2. **NACK 4→3 B** — encoder/decoder change + sender-side wait-time conversion (apply `× 16` on RX, `÷ 16` on TX). Independent.
3. **BCN re-pack** — new byte 1 flags, hops-1 encoding, is_gateway bit, schedule-record path. Gateways with `gateway_layers` now emit schedule records; non-gateways omit them. Touches `pack_beacon`/`parse_beacon` and route entry storage.
4. **RTS re-pack** — new byte 3 packing, dst stays 1 B (addr_len=0 only), ctr_lo gets own byte. Touches `pack_rts`/`parse_rts`. In-leaf size unchanged (8 B).
5. **DATA re-pack** — new flags byte, `ctr` field (replaces today's `origin_seq` payload header), ciphertext = plaintext placeholder, MAC = 4 zero bytes placeholder, E2E flags promoted from payload header to wire byte 1. Touches `pack_data`/`parse_data` and the entire E2E ACK code path. **Biggest single phase.**
6. **Hierarchy support** (deferred until needed) — `addr_len > 0`, dst byte-array, gateway peeling, schedule-record emission. Not blocking other work.

Tests in `test/run_tests.sh` (38 scenarios) and `webapp/tests/` (36 pytests) must stay green after each phase.

---

### 7.1 Concrete encrypted hierarchical DATA frame (synthesis of §7 + §8.1 + §9 T2)

**Status — Wire format IMPLEMENTED** (Phases 4-5 of the 5-phase wire-format
refactor, landed 2026-05-12). The locked layout is captured in §7.0.1 above;
the in-leaf path (addr_len=0) is live with ciphertext+MAC bytes acting as
plaintext placeholders until §8 crypto lands. `addr_len > 0` hierarchy
support is deferred. The original design discussion follows for context.

---

**Problem statement.** Combine multi-network routing (§7), end-to-end encryption (§8.1), and originator anonymity (§9 T2) into a single concrete DATA frame that supports:
1. Hierarchical routing across nested networks (leaf → city → region → country → global)
2. End-to-end confidentiality + authenticity with no on-wire key/session identifier
3. Originator anonymity from forwarders (no `origin` on wire)
4. No clock dependency (counter-based crypto nonces)
5. Backward extensibility for E2E ACK (§5) and future flags

**Addressing model.**

- Node IDs stay 1 byte (current spec, 256 nodes per leaf network)
- 4-bit `addr_len` field (currently called `network_id`) indicates how many hierarchy boundaries the destination is above the leaf:
  - `addr_len=0`: destination is local-leaf → 1-byte `dst`
  - `addr_len=1`: cross-region (one layer up + down) → 2-byte `dst = [region_net, dst_leaf_local]`
  - `addr_len=2`: two-layer crossing → 3-byte `dst`
  - …each layer adds 1 byte
- Layer naming convention (reserved values of an as-yet-unnamed hierarchy register; precise level labels still subject to revision):
  - layer 15 = leaf (end-user devices)
  - layer 14 = city / regional cluster
  - layer 13 = inter-region
  - layer 12 = inter-country (etc.; values 0-12 reserved for future hierarchy)
- Layer-14 (and above) network IDs are **globally unique within their layer** — each city has a single 1-byte identifier (e.g., Gdansk=33, Elblag=35), valid across the whole hierarchy. 256 layer-14 networks max.
- Each gateway peels the front byte of `dst` on cross-layer transition and decrements `addr_len`. Final hop receives `addr_len=0` + 1-byte `dst`.

**Wire format.**
```
byte:  0   1                       2      3..(3+addr_len)        (4+addr_len)..(5+addr_len)    rest
       ┌───┬──────────────────────┬──────┬──────────────────────┬──────────────────────────────┬──────────────────┐
       │'D'│ addr_len      (4 hi) │ next │ dst                  │ ctr (2 B, little-endian)     │ ciphertext + MAC │
       │   │ E2E_ACK_REQ   (1)    │      │ (addr_len + 1 bytes, │                              │ (n + 4 bytes)    │
       │   │ E2E_IS_ACK    (1)    │      │  hierarchical path)  │                              │                  │
       │   │ reserved      (2)    │      │                      │                              │                  │
       └───┴──────────────────────┴──────┴──────────────────────┴──────────────────────────────┴──────────────────┘
```

**Field semantics.**

| Field | Bytes | Plaintext? | Purpose |
|---|---|---|---|
| `'D'` tag | 1 | yes | Frame-type dispatch (kept full byte for now; bit-pack candidate later) |
| `addr_len` (4 hi) + E2E flags (2) + reserved (2) | 1 | yes | Hierarchy boundary count + E2E ACK flags |
| `next` | 1 | yes | Immediate next-hop receiver (LoRa has no PHY addressing — frame is broadcast on channel) |
| `dst` (variable) | addr_len + 1 | yes | Hierarchical destination path; gateways peel front byte + decrement addr_len |
| `ctr` | 2 (LE) | yes | Per-(origin, destination) counter — triple duty: crypto nonce entropy, replay protection, hop-level match (low nibble echoed by CTS/ACK as today's msg_id slot) |
| ciphertext | n | **encrypted** | Inner plaintext = `(src_full_address, body)`; ChaCha20(session_key, nonce, inner) |
| MAC | 4 | yes | Poly1305-truncated-4B; receiver trial-verifies against each peer session_key (LRU) |

**Implicit nonce derivation** (no on-wire nonce field):
```
nonce = HKDF-Expand(session_key, "nonce" || ctr || dst || addr_len, 12 B)
```

**Encrypted inner-payload structure:**
```
src_address_len (1 byte) | src_address (src_address_len + 1 bytes) | body
```
Where `body` is `user_text` for normal DATA, or `[acked_ctr_lo, acked_ctr_hi]` if `E2E_IS_ACK=1`.

**Wire-cost vs today's plaintext DATA.**

| Scenario | Today | Proposed |
|---|---|---|
| In-leaf (`addr_len=0`) | 6 B header + 2 B origin_seq + n | **10 B + n** (+2 B for full crypto + privacy) |
| Cross-region (`addr_len=1`) | n/a | **11 B + n** |
| Two-hop hierarchy (`addr_len=2`) | n/a | **12 B + n** |
| Each additional hierarchy hop | n/a | +1 B |

**What's removed from today's DATA wire.**

- `orig` (1 B) — moved inside encrypted payload (§9 T2 privacy)
- `src` (1 B previous-hop) — derivable from `pending_rx.from` set during RTS-CTS handshake (composes with §5 E2E ACK reverse-path soft state via the same `pending_rx` info)
- `msg_id` field (1 B byte slot) — replaced by `ctr`; CTS/ACK echo `ctr & 0xF` for hop-level match (same 1/16 collision space as today's 4-bit msg_id)
- `origin_seq` (2 B plaintext) — replaced by `ctr` which does triple duty (crypto nonce, replay protection, app dedup)

**Worked example: Alice (Gdansk #33, local 12) → Bob (Elblag #35, local 101).**

```
Step 1 — Alice TX in Gdansk leaf:
  D | 0x10 (addr_len=1, no E2E flags) | next=G_out | dst=[35, 101] | ctr=0x1234 | ciphertext + MAC
                                                       ↑                ↑
                                            target: Elblag(35) / Bob(101)  Alice's counter to Bob

Step 2 — Gdansk-leaf forwarders see addr_len=1, dst[0]=35:
  Route toward G_out (= Alice's leaf-to-layer14 bridging neighbor).

Step 3 — G_out (Gdansk-leaf + layer-14 gateway) peels dst[0]=35, decrements
  addr_len 1→0, re-emits in layer-14 network:
  D | 0x00 (addr_len=0) | next=G_in | dst=[101] | ctr=0x1234 | (unchanged ciphertext + MAC)

Step 4 — Layer-14 routes to G_in (= Elblag's layer-14+leaf gateway).

Step 5 — G_in switches into Elblag leaf:
  D | 0x00 | next=Bob's-leaf-prev-hop | dst=[101] | ctr=0x1234 | ...

Step 6 — Elblag-leaf routes to local 101 = Bob.

Step 7 — Bob receives:
  - trial-verify MAC against his peer session_keys (LRU)
  - first key that verifies → that's Alice's session_key → that's the originator
  - reconstruct implicit nonce, decrypt ciphertext
  - inner payload: src_address_len=1, src_address=[33, 12], body="hello bob"
  - display "Message from Alice (Gdansk #33, local 12)"
  - if E2E_ACK_REQ flag: build return frame
      D | 0x11 (addr_len=1, IS_ACK=1) | next=... | dst=[33, 12] | ctr=Bob's-counter-to-Alice
      ciphertext = (src_address_len=1, src_address=[35, 101], body=[acked_ctr_lo, acked_ctr_hi])
```

**Privacy properties.**

| Observation | Visible to passive observer? |
|---|---|
| Frame is DATA (vs RTS/CTS/etc) | yes |
| Frame is going to/from `next` (next hop) | yes (radio fact) |
| Destination's hierarchical position (`addr_len + dst`) | yes |
| Sender wants E2E ACK | yes (E2E_ACK_REQ flag in plaintext) |
| Message is an E2E ACK | yes (E2E_IS_ACK flag in plaintext) |
| Originator identity | **NO** (inside encrypted payload) |
| Message content | **NO** (encrypted) |
| Which (origin, destination) pair (the relationship) | **NO** (no session_id on wire) |
| Long-term linkability across days/sessions | **NO** (session_key derived once, but ciphertext is opaque; no per-pair tag) |

**Compositions.**

- **§5 E2E ACK** (privacy-compatible variant) — uses `pending_rx.from` + `(ctr, dst)` reverse-path soft state at forwarders. No source-on-wire needed.
- **§8.1 crypto** — provides the per-pair session_key + identity card mechanism. `ctr` is the per-pair message counter derived in §8.1.
- **§9 T2 privacy** — `src` and `orig` both removed from DATA wire; only `next` and `dst` are addressing-related plaintext.
- **§1 anti-spam** — RTS/CTS observation counts work unchanged because msg_id (= `ctr & 0xF` echo) is still present at the hop-level RTS-CTS handshake.
- **§7 multi-layer** — `addr_len + dst` IS the multi-layer addressing.
  Gateways are nodes whose BCN advertises bridging capability.

**What's NOT yet decided / open work.**

- **BCN re-engineering** is the next major design item. Current BCN advertises self + routes within a single layer. With hierarchical routing it needs to:
  - Advertise bridging capability ("I'm a layer gateway, reachable from this layer")
  - Cross-layer route advertisement OR pull-based route discovery via `?` queries
  - Avoid foreign-layer pollution (`leaf_id = layer_id & 0x0f` filters the
    active layer; admin boundaries need policy/keys)
  - Anti-flooding: gateways MUST NOT advertise every foreign destination; only "I can reach layer-N network X"
- **Gateway policy** — automatic (any node with multi-network PSKs becomes bridge) vs explicit operator config. Deferred to implementation.
- **Layer naming finalization** — values 0-13 reserved; precise role labels still TBD.
- **Layer-14 ID allocation** — globally unique 1-byte IDs across all layer-14 networks. Allocation mechanism (registry, claim-and-defend, etc.) is operational/social, not protocol.

**Implementation cost estimate.**
- Wire format change: substantial (DATA layout, RTS/CTS update for ctr echo). Touches `pack_data`/`parse_data`, `pack_rts`/`parse_rts`, `pack_cts`/`parse_cts`, `pack_ack`/`parse_ack`.
- Crypto primitives: ChaCha20 + Poly1305 + HKDF + X25519. ~300-500 lines pulling from an existing library (libsodium / monocypher) or compact in-Lua reference.
- Gateway logic: peel-and-re-emit at network boundary. ~100 lines.
- Identity card / `?` query frame: ~80 lines (mirrors Q frame mechanics).
- Tests: per-message round-trip, multi-hop traversal, dup-MAC dedup, replay rejection, peer-key rotation, gateway boundary. ~200 lines test scenarios.

### 7.2 BCN re-engineering for hierarchical routing

**Status — Wire format IMPLEMENTED** (Phase 3 of the wire-format refactor,
landed 2026-05-12). The locked layout is captured in §7.0.2 above. New
flag bits (`has_schedule`, `self_gateway`, `is_mobile`) and the route-entry
`is_gateway` bit are emitted; the schedule-record path is reserved on the
wire and skipped at parse time pending §7.3 inter-layer TDM. The original
design discussion follows for context.

---

**Problem statement.** Today's BCN advertises `(src, [dest, next, score, hops])` entries — all 1-byte node IDs within a single layer. Under §7.1's hierarchical model, BCN needs to:
1. Indicate which layer the emitter belongs to (`leaf_id = layer_id & 0x0f`)
2. Mark which destinations in the BCN are gateways (members of higher layers)
3. Advertise the emitter's own gateway capability and its per-layer activity schedule (for single-radio TDM, see §7.3)
4. Stay wire-cost-neutral vs today for non-gateway leaf BCNs

**Wire format.**

```
byte:  0   1                          2                                    3      4..(end)
       ┌───┬──────────────────────────┬────────────────────────────────────┬─────┬────────────────────────────────┐
       │'B'│ has_schedule  (1 hi)     │ leaf_id           (4 hi)           │ src │ if has_schedule:               │
       │   │ reserved      (3)        │ self_gateway_flag (1)              │     │   layer_count (1 B)            │
       │   │ n_entries     (4 lo)     │ reserved          (3 lo)           │     │   schedule_record × layer_count│
       │   │ (0xF = extended n)       │                                    │     │ [n_extended if n_entries==0xF] │
       │   │                          │                                    │     │ route entry × n (3 B each)     │
       └───┴──────────────────────────┴────────────────────────────────────┴─────┴────────────────────────────────┘

Route entry (3 bytes — same size as today):
       ┌──────┬──────┬─────────────────────────────────────────────────────────┐
       │ dest │ next │ score_bucket(4 hi) | hops(3) | is_gateway(1 lo)         │
       │ (8)  │ (8)  │                                                         │
       └──────┴──────┴─────────────────────────────────────────────────────────┘

Schedule record (4 bytes — per upper layer this gateway bridges to):
       ┌─────────────────────────────┬──────────────────┬──────────────────┬──────────────────┐
       │ layer(4)|(sf-5)(3)|P5(1)    │ duration_100ms   │ offset_100ms     │ period_units     │
       │                             │ (8 bits)         │ (8 bits)         │ (8 bits)         │
       └─────────────────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

**Field semantics.**

| Field | Bits | Purpose |
|---|---|---|
| `'B'` tag | 8 | unchanged |
| `has_schedule` | 1 | if 1, schedule records follow byte 3 (gateway emitter with TDM schedule for upper layers) |
| `n_entries` | 4 | route entry count; sentinel 0xF means "read 1-byte n_extended after schedule (if any)" |
| `leaf_id` | 4 | emitter's active layer nibble (`layer_id & 0x0f`); receivers drop foreign-layer BCNs |
| `self_gateway_flag` | 1 | emitter is a gateway (= member of some upper layer); fast bootstrap before others advertise me |
| `src` | 8 | emitter's layer-local node ID (unchanged from today) |
| route `dest`, `next` | 8+8 | unchanged from today |
| route `score_bucket` | 4 | unchanged: SNR bucket, 2 dB resolution |
| route `hops` | 3 | reduced from 4 bits (protocol caps at 8 hops anyway → 3 bits = 0-7 is fine) |
| route `is_gateway` | 1 | this destination is a gateway (member of some upper layer); propagates transitively via `rt_merge` |
| schedule `layer` | 4 | layer nibble this record describes (`layer_id & 0x0f`) |
| schedule `sf-5` | 3 | SF used on that layer, encoded as `sf - 5` |
| schedule `P5` | 1 | period unit selector: 0 = seconds, 1 = 5-second units |
| schedule `duration_100ms` | 8 | how long the gateway is active on this layer per visit (0.1 - 25.5 s) |
| schedule `offset_100ms` | 8 | 100 ms units from THIS BCN's reception to the next layer-window opening (0-25.5 s); receiver anchors on its local `bcn_rx_time` |
| schedule `period_units` | 8 | repetition period in selected units; range is 1-255 s with `P5=0`, or 5-1275 s with `P5=1` |

**Schedule record interpretation (clock-sync-free).**

Each receiver R notes the local time `bcn_rx_time` when it received this BCN. For each schedule record:
- Next window opens at `R's local time = bcn_rx_time + offset_100ms × 100 ms`
- Window duration: `duration_100ms × 100 ms`
- Repetition period: `period_units × (P5 ? 5 s : 1 s)`

R re-anchors at every BCN reception. Drift between BCNs is bounded by clock-drift over typical 5-min BCN periods (sub-second drift), negligible for window-sizing in 1-25 s range.

**Wire-cost comparison.**

| Scenario | Today | New |
|---|---|---|
| Plain leaf, 5 routes | 8 + 15 = **23 B** | 8 + 15 = **23 B** (same) |
| Plain leaf, 47 routes | 8 + 141 = **149 B** | 8 + 1 + 141 = **150 B** (+1 B for n_extended marker) |
| Gateway leaf with no schedule (= permanent on this layer, no TDM), 5 routes, 3 gateway destinations | n/a | **23 B** (gateway info is bits — zero wire cost beyond the fixed BCN hash header) |
| Gateway with TDM schedule, 1 upper layer, 5 routes | n/a | 8 + 1 + 4 + 15 = **28 B** (+5 B for layer_count + schedule record) |
| Multi-layer gateway (2 upper layers via TDM), 8 routes | n/a | 8 + 1 + 8 + 24 = **41 B** |

**Gateway capability is effectively free for non-TDM gateways.** Only nodes that need to advertise their layer-switching schedule pay the 4 B/layer overhead. A node that is permanently on a single layer (e.g., a dedicated layer-14 hub with no leaf participation) has `has_schedule=0` and pays nothing extra.

**How a leaf node consumes the information.**

1. **rt_merge** processes each entry: `rt[dest]` candidate stores `is_gateway` flag alongside score/hops/next_hop.
2. **Schedule cache**: when a BCN from a direct neighbor has `has_schedule=1`, receiver stores the schedule records keyed by `(src_id, layer)`. On each BCN re-reception, re-anchor against current `bcn_rx_time`. Stale schedules (no BCN heard in 2× period) → drop.
3. **Cross-network send (alice → bob in another network):** current v1
   `send_layer` addresses the destination by `(target_layer_id,
   dst_key_hash32)`. The local routing layer selects only gateways whose
   observed BCN schedule advertises that `target_layer_id`, then routes
   normally toward that gateway.
4. **Gateway handoff:** the chosen gateway resolves `dst_key_hash32` from
   its local layer binding cache (`id_bind` for its primary layer,
   `gateway_remote_bind` for bridged layers). Remote gateway bindings are
   keyed by `(layer_id,key_hash32)`, refresh on observed BCN/JOIN traffic,
   and age after `gateway_remote_bind_ttl_ms` of silence. If no binding
   exists, the gateway emits `gateway_no_binding`, defers the envelope, and
   emits `Q:HASH_QUERY` on the target layer. If the binding appears before
   `gateway_handoff_defer_ttl_ms`, the handoff drains into normal target-layer
   DATA forwarding. Ambiguous bindings still fail closed.
5. **Reachability discovery is open.** A production design still needs a
   policy for "which gateway can currently reach this remote hash." Options
   under consideration are:
   - gateway BCN extension advertising reachable remote-node summaries;
   - sender retry across multiple eligible gateways when one returns/no-ops
     with `gateway_no_binding`;
   - explicit app/control query such as `gateway_lookup`.

No decision is made yet because the reachable-set extension can become
expensive, while retry-across-gateways has simpler wire cost but weaker
latency/delivery guarantees.

**Cross-references.** §7.1 (DATA frame uses `addr_len + dst` whose routing is driven by `is_gateway` markers from this BCN), §7.3 (inter-layer TDM mechanics consume the schedule records), §6.5 (stale-route aging applies to gateway entries like any other route).

**Open questions (deferred).**
- Self-update of schedule records (when a gateway changes its TDM cadence, peers learn from the next BCN — no explicit "schedule changed" mechanism; just continuous refresh).
- Layer-14 (and higher) BCNs use the SAME format with semantics shifted (src = layer-14 ID, is_gateway = "member of layer-13", etc.). Recursive design.
- Remote-node reachability advertisement vs retry-across-gateways remains
  undecided; current v1 only filters gateways by bridged layer and lets the
  gateway resolve the final `key_hash32` from its observed binding cache.

### 7.3 Inter-layer routing protocol (single-radio TDM)

**Current implementation status (2026-05-17).**

Implemented first-slice gateway v1:

- `gateway_layers` config creates secondary layer records with layer id,
  leaf id, control SF, DATA-SF bitmap, period, duration, and offset.
- Gateways emit BCN schedule records (`has_schedule=1`) and
  `gateway_schedule_change` telemetry when the active radio context changes.
- Direct peers cache gateway schedules from BCN and defer RTS while a gateway
  is scheduled away from their layer. The defer pre-check fires from both
  `issue_send` and `tx_rts_retry`, so retry paths after `rts_timeout_fire`
  also avoid re-emitting RTS into a gateway's sweep window.
- `send_layer` gateway selection filters candidates by observed bridged-layer
  set from gateway BCN schedule records; gateways that do not advertise the
  target layer are not eligible.
- Gateway-side lazy binding resolution: when a gateway consumes a cross-layer
  envelope but lacks `gateway_remote_bind[(layer,key_hash32)]`, it emits a
  `Q:HASH_QUERY` on the target layer and parks the envelope in
  `gateway_deferred_handoffs`. The deferred entry drains when the binding
  appears (via Q response, BCN, or J observation) or gives up after
  `gateway_handoff_defer_ttl_ms`. Events: `gateway_handoff_deferred`,
  `gateway_handoff_drained`, `gateway_handoff_giveup`, `q_hash_binding_tx`.
- JOIN uses the active layer context: a new node only needs frequency/control
  SF out of band and learns DATA SF policy from `J_OFFER`.
- Cross-layer `send_layer` queues a gateway envelope addressed by
  `target_layer_id + dst_key_hash32`.
- Gateways learn remote-layer key bindings from observed BCN/JOIN traffic
  (`gateway_remote_bind_set`), not by walking simulator node lists.
- Gateway handoff restores the correct target/primary layer control SF and
  DATA-SF bitmap before forwarding.
- Route/identity runtime state is layer-scoped by `layer_state[layer_id]`;
  `rt[]`, `id_bind[]`, `dest_seen_ms`, and beacon paging are active-layer
  views. Direct route learning is gated behind per-frame leaf validation.
- JSON validation now treats `node_id` uniqueness as per-layer, not global.
- Passing acceptance scenario: `scenarios/s09_two_layer_gateway_debug.json`.
  It uses layer 4 control SF7/DATA SF10 and layer 5 control SF8/DATA SF11,
  with six join-required nodes learning DATA SFs from JOIN offers.
- Passing separation scenario: `scenarios/s10_two_layer_gateway_separation.json`.
  It reuses ordinary short IDs across layers to catch route/id-bind pollution.

Not yet implemented:

- Independent per-layer gateway leases: a gateway still uses its primary
  short ID when sweeping a bridged layer. Therefore two gateway nodes that
  bridge into the same layer must not share the same short ID in that layer.
  Proper per-layer gateway JOIN/lease assignment remains open.
- Adaptive schedule-offset convergence between multiple gateways.
- Multi-hop upper-layer gateway paths with overlap search.
- Remote destination reachability across multiple eligible gateways:
  partially addressed by gateway-local `Q:HASH_QUERY` when a selected gateway
  lacks a binding. Broader reachable-node advertisement and retry across
  alternate gateways are still parked for measurement/design.
- Original-origin propagation through cross-layer envelope handoff: today
  the destination's `delivered` event carries the gateway as origin, not
  the original sender.
- Envelope-level replay/dedup at gateways: a retransmitted envelope
  generates a second handoff with a fresh ctr.

Workbench scenarios:
- `scenarios/s09_two_layer_gateway_debug.json` — acceptance gate.
- `scenarios/s10_two_layer_gateway_separation.json` — drive
  `(layer_id,node_id)` scoping.
- `scenarios/deprecated/s11_three_layer_gateway_stress.json` —
  exercises gateway picker filtering and schedule defer across three
  layers. Moved to `deprecated/` because early-flight delivery
  assertions don't hold under realistic protocol timing
  (simultaneous join + gateway discovery transient).

**Problem statement.** A gateway node participates in two or more layers (e.g., leaf SF7 + layer-14 SF11). A single LoRa radio can only be tuned to ONE (SF, frequency) at any instant. To support multi-layer gateway participation on consumer-grade hardware (no dual-radio), the protocol needs a time-division scheme — the gateway alternates between layers on a known schedule, and peers consult that schedule to time their interactions.

**Layer identity.** Config uses full `layer_id`; the wire carries only
`leaf_id = layer_id & 0x0f` in BCN/RTS. A gateway retune switches the active
layer context: `leaf_id`, `routing_sf`, `allowed_data_sfs`, and BCN schedule
belong to the currently active layer. Route-table and identity-binding views
are implemented as layer-scoped active-state pointers.

**Mobility use case.** Mobiles are not special-cased in the radio stack. A
mobile fleet can be assigned to layer 2 with control SF9 while the static city
mesh remains layer 1 with control SF8. Stationary gateways bridge between the
two layers; stationary layer-2 nodes are allowed. This lets mobile support test
the real gateway architecture instead of adding a mobile-only SF override.

**Hybrid scheduling (the chosen mechanism).**

- **Primary layer:** the gateway's default state (typically the leaf layer where most of its traffic lives, e.g., SF7).
- **Periodic upper-layer sweep:** every `T_period` seconds, the gateway retunes to upper-layer SF for `duration` seconds. During the sweep:
  - Receives upper-layer BCNs (maintains its upper-layer `rt[]`)
  - Emits its own upper-layer BCN if scheduled
  - Available for inbound RTS from upper-layer peers
- **On-demand retune for outbound TX:** if the gateway has a queued frame for upper-layer forwarding AND is currently on its primary layer, it can opportunistically retune to upper layer to transmit, then return. This is in addition to the periodic sweep.

**Schedule announcement (via gateway's BCN, §7.2).**

The gateway's BCN includes schedule records — one per upper layer it participates in. Receivers anchor schedules against `bcn_rx_time` (no clock sync). Example: a gateway with schedule `{layer=14, sf=11, duration_ms=20000, offset_ms=3000, period_ms=120000}` is on layer-14 SF11 from `bcn_rx_time + 3 s` for 20 seconds, repeating every 120 seconds.

**Listen-on-overlap (intra-upper-layer hops).**

When two gateways G_a and G_b in the same upper layer need to communicate, both must be on that layer simultaneously. There is no clock-sync or central coordinator — each gateway picks its own offset — but the offset is NOT static: each gateway continuously adjusts to align with the peers it actually exchanges L14 traffic with (see **Adaptive offset** below).

Mechanism:
- G_a's BCN announces its layer-14 schedule
- G_b receives G_a's BCN, computes G_a's L14 window (relative to G_b's local time)
- G_b similarly knows its own layer-14 schedule
- For G_b to TX to G_a on layer 14: G_b waits for a time when BOTH are on layer 14 (= intersection of their windows)
- If windows don't currently overlap: G_b queues the frame; the adaptive-offset mechanism (next paragraph) causes both gateways to converge their offsets toward overlap within a few BCN periods
- Cascade-requeue total-wallclock cap applies (§5.6); frames that can't find overlap within ~minutes drop with `cross_layer_giveup`

**Adaptive offset (required mechanism, not an optional optimization).**

Without offset adjustment, two gateways with 20 s windows on a 300 s period have ~6.7 % random overlap per cycle; a 3-hop L14 path drops to ~0.03 % per cycle of synchronous-overlap delivery. Multi-hop L14 routing would be effectively unusable. Adaptive offset converges the gateway-cluster to overlapping windows over a small number of BCN periods, making multi-hop L14 practical.

Algorithm (each gateway runs it independently, on its own BCN emission tick):
- G maintains `peer_traffic_weight[peer_id]` from observed recent L14 forwarding activity to/from that peer (rolling window, e.g. last 10 min).
- For each candidate offset Δ in `[0, period - duration]` (search granularity = 1 s is plenty), G computes
  `score(Δ) = Σ over L14 peers p ( peer_traffic_weight[p] × overlap_seconds(G's window at Δ, p's last-known window) )`.
- G picks `Δ* = argmax score(Δ)`, subject to a per-period drift cap `max_offset_drift_per_period_s` so the offset moves smoothly instead of jumping (prevents oscillation when peers are also adjusting).
- A gateway with no L14 peer traffic yet keeps its boot-time offset (e.g. derived from `node_id`); no penalty for being un-aligned with strangers.

Convergence: clusters of gateways that frequently communicate with each other converge to mutually overlapping offsets within ~3-5 BCN cycles (≈15-25 min at default 5 min BCN period). Two clusters that never exchange L14 traffic remain independent — there is no forced global alignment.

Concentration safeguard: full alignment of ALL gateways onto the same window would simultaneously blank all leaf-15 service across the network. Two mitigations:
- `max_offset_drift_per_period_s` caps step size; cluster formation is favoured over global collapse.
- A gateway whose top-traffic peer's window is already crowded with other gateways may prefer a bridging offset (partial overlap with two clusters) over full alignment with one — implementation is local, no extra wire.

**Layer-15 peer active avoidance.**

A non-gateway leaf node N that wants to RTS to G (gateway) consults G's schedule. If `self.now()` is inside G's upper-layer window:
- G is currently on upper-layer SF, NOT on G's leaf SF
- An RTS to G on leaf SF will not get a CTS (G is deaf)
- N **defers** TX until G's leaf-active period resumes
- Avoids wasted RTS airtime

Implementation: pre-check in `tx_initiating` for `next == gateway`:
```
if next is a known gateway with schedule AND self.now() is inside gateway's upper-layer window:
  defer until window closes + small jitter
```

This composes with existing LBT defer and duty-cycle pre-check.

**Multi-hop case: hold-at-gateway-neighbor (no schedule propagation needed).**

A node N+ that is 2+ hops from gateway G does NOT need G's schedule. It RTSes
normally toward G via its next-hop forwarder F. The active-avoidance rule
applies at F (which IS a direct neighbour of G and therefore receives G's
BCN): when F has a pending DATA whose `next == G` AND `self.now()` falls
inside G's upper-layer window, F holds the DATA in its outbound queue until
G's leaf window resumes (bounded by the schedule's `duration_100ms`).

This pushes the timing logic to where the schedule knowledge naturally lives
(one hop from G) and keeps wire cost zero — no need to propagate schedules
transitively through `rt_merge` or BCN aggregation. The route entry's
`is_gateway` bit is what tells F "this next-hop has a schedule worth
consulting"; F looks up the cached schedule keyed by `next_hop_id`.

Composes with cascade-requeue (§5.6): the hold counts against the same
wallclock budget as any other forwarder-queue wait. Frames whose total
wait would exceed the cascade cap drop with `gateway_window_giveup`.

**Single shared duty-cycle budget.**

A gateway's 1% duty cycle applies to its radio TX regardless of which layer it's on. Heavy upper-layer TX consumes the same budget that intra-leaf TX would. This is the physical reality of a shared radio — no virtualization. Composes with §11.5 budget tiers naturally: a gateway running near its budget cap signals STRAINED/CRITICAL on the per-message-NACK path, regardless of which layer the inbound RTS came in on.

**Worked example (full end-to-end).**

```
Alice (Gdansk leaf, 3 hops from G_out) → Bob (Elblag, via G_out → G_in):

Step 1 — Alice TX at her local time T0 (Gdansk leaf, SF7):
  D | addr_len=1 | next=neighbor-X | dst=[35, 101] | ctr | ciphertext + MAC
  
Step 2 — Local Gdansk-leaf hops forward toward G_out (~200-500 ms).
  Frame arrives at N (G_out's direct leaf neighbor) at N's local time T_N.

Step 3 — N has G_out's schedule. N consults:
  G_out is on L14 SF11 from T_N + 25 s to T_N + 45 s (relative to N's clock).
  
  Sub-case (a) — T_N is BEFORE the window:
    N queues the frame. At T_N + 25 s, N retunes to SF11.
    N RTS-CTS-DATA-ACKs to G_out on SF11. ~1-2 s.
    Returns to leaf SF7.
  
  Sub-case (b) — T_N is INSIDE the window (lucky timing):
    N immediately retunes to SF11, RTSes to G_out. As above.
  
  Sub-case (c) — T_N is AFTER the window:
    N queues; next BCN refresh from G_out re-anchors the schedule for ~5 min later.

Step 4 — G_out has the frame on layer 14. G_out's L14 rt[] tells it:
  "Next hop toward net 35 = some L14 peer P." 
  G_out is currently in its OWN L14 window. P is also a layer-14 node with its own L14 schedule advertised in P's L14 BCN.
  G_out checks P's L14 schedule for overlap with G_out's current window.
  If overlap: G_out RTS-CTS-DATAs to P on layer 14.
  If no overlap: G_out queues the frame for the next overlapping window.

Step 5 — Frame eventually reaches G_in (= layer-14 node bridging to Elblag leaf).
  G_in's payload-peel logic: addr_len 1→0, dst = [101].
  G_in retunes to its own primary (Elblag leaf SF7) at next L15 window.

Step 6 — G_in RTS-CTS-DATAs to Bob's neighbor in Elblag leaf.
  Local Elblag-leaf hops to Bob (~200-500 ms).

Step 7 — Bob receives. Decrypts. Done.

Latency budget:
  - Intra-leaf hops: ~500 ms (typical)
  - Wait for L14 window: 0 - T_period (worst case ~5 min)
  - Layer-14 traversal: depends on gateway-density; ~10 s per hop at SF11
  - Wait for L15 window at G_in: 0 - T_period
  - Intra-Elblag-leaf hops: ~500 ms
  Total: ~10 s best case, ~10 min worst case for one-shot delivery.
```

Acceptable for non-realtime use cases (chat, status, alerts). Not for sub-second-latency needs (which LoRa generally isn't suited for anyway).

**Cost / capacity considerations.**

| Concern | Impact | Mitigation |
|---|---|---|
| Layer-14 traffic crowds L15 capacity at gateway | Shared duty-cycle budget; heavy cross-layer use reduces local L15 throughput | §11.5 budget tiers signal saturation; senders learn via NACK and re-route. The §2 `gateway_transit_penalty_db` keeps non-cross-layer traffic off gateways, so most of the budget stays available for actual cross-layer forwarding. Shared single-radio budget is intentional — no per-layer fairness virtualization. |
| L15 peers wait for gateway's L15-active windows | Up to `duration` of dead time per cycle | Active avoidance keeps peers from wasting airtime; queue-and-retry handles the wait |
| Schedule drift between gateways | Two gateways' schedules drift apart, breaking established overlap | BCN refresh re-anchors on each reception; adaptive offset (required mechanism — see **Adaptive offset** above) continuously realigns each gateway with the peers it has active L14 traffic with, keeping cluster overlap stable as topology changes |
| Lost upper-layer BCNs (heard outside our sweep) | Stale upper-layer rt[] | Standard rt_aging applies; gateway's L14 rt[] has slightly higher staleness floor (proportional to sweep gap) |
| Multi-hop L14 with non-overlapping schedules | Each hop pays its own wait-for-overlap | Cascade-requeue total wallclock cap (§5.6) kills truly impassable paths; works as backpressure |

**Cross-references.** §7.1 (DATA frame consumes hierarchical `dst` that drives this routing), §7.2 (BCN carries schedule records that this protocol consumes), §5.6 cascade-requeue (handles bounded waits for cross-layer overlap), §11.5 budget tiers (gateway's shared duty cycle naturally signals saturation under load).

**Open questions (deferred to implementation).**
- Layer-14 (and higher) using completely separate frequency sub-bands? Out of scope for the base proposal — we assume shared frequency, different SFs.
- Dual-radio hardware support: out of scope; future "professional" deployments could parallelise. Protocol design works either way.
- Tuning of `max_offset_drift_per_period_s` and the per-peer-traffic-weight decay window. Initial defaults are placeholders; measurement under simulated multi-gateway scenarios will tune them.

**Implementation status / remaining cost.**

Done in v1:
- BCN parse/pack extension for schedule records.
- Schedule cache at receivers.
- Basic TDM scheduling state machine at gateway: sweep timer, retune,
  return-to-primary.
- Direct-neighbour active avoidance: `tx_gateway_schedule_defer`.
- Gateway picker filters by observed bridged-layer set from BCN schedule
  records.
- Single-gateway cross-layer queue/handoff for `send_layer`.
- Smoke scenario with assertions: `s09_two_layer_gateway_debug.json`.

Remaining:
- Independent per-layer gateway leases: gateways still use their primary short
  ID when sweeping a bridged layer.
- Remote-node reachability policy for multi-gateway deployments: parked.
- Overlap detection for gateway-to-gateway paths.
- Adaptive offset: peer-traffic-weight tracking + overlap-maximizing offset
  picker + drift-capped update.
- Tests still needed: per-layer gateway lease collision, schedule drift, overlap
  windows, missed sweep recovery, adaptive offset convergence on 1-hop and
  3-hop upper-layer paths.

### 7.4 Control-plane frame updates (RTS / CTS / ACK / NACK)

**Status — IMPLEMENTED** (Phases 1, 2, 5 of the wire-format refactor,
landed 2026-05-12). RTS dropped `origin` and repacked byte 3 (§7.0.3);
NACK shrunk 4→3 bytes with quantized busy_for_ms (§7.0.5); CTS/ACK kept
2-byte sizes via the `msg_id`→`ctr_lo` rename. The original design
discussion follows for context.

---

**Problem statement.** With §7.1 (encrypted hierarchical DATA), §7.2 (BCN re-engineering), and §7.3 (inter-layer TDM) in place, the supporting control-plane frames need adjustment: RTS must carry the variable hierarchical `dst`, and the matching-ID slot in CTS/ACK/NACK needs to align with the new `ctr` field that replaces `msg_id`.

#### RTS — substantial change

**Today (8 bytes):**
```
'R' | origin(1) | src(1) | dst(1) | next(1) | network_id(4)+msg_id(4) | sf_bitmap(1) | payload_len(1)
```

**Proposed:**
```
byte:  0   1     2      3                          4..(4+addr_len)         (5+addr_len)       (6+addr_len)    (7+addr_len)
       ┌───┬─────┬─────┬──────────────────────────┬───────────────────────┬───────────────────┬──────────────┬──────────────┐
       │'R'│ src │ next│ addr_len    (4 hi)       │ dst                   │ ctr_lo (4 hi)     │ sf_bitmap    │ payload_len  │
       │   │     │     │ leaf_id     (4 lo)       │ (addr_len + 1 bytes)  │ reserved (4 lo)   │ (8)          │ (8)          │
       └───┴─────┴─────┴──────────────────────────┴───────────────────────┴───────────────────┴──────────────┴──────────────┘
```

**Field-by-field changes:**

| Field | Today | New | Why |
|---|---|---|---|
| `origin` | 1 B plaintext | **REMOVED** | §9 T2 — originator anonymity; the receiver of the eventual DATA learns origin from encrypted payload via MAC trial-verify |
| `src` (prev-hop) | 1 B | **kept 1 B** | RTS is the FIRST hop-level frame; receiver has no `pending_rx` yet, MUST know who's asking |
| `dst` | 1 B | **variable, `addr_len + 1` B** | Hierarchical destination per §7.1 |
| `next` | 1 B | **kept 1 B** | Radio-level addressing (unchanged) |
| `network_id` (4 bits) | 4 bits | **renamed `leaf_id`, kept 4 bits** | Active layer nibble; drop foreign-layer RTS before CTS work |
| `msg_id` (4 bits) | 4 bits | **replaced by `ctr_lo` (4 bits)** | Low nibble of the full 16-bit `ctr` carried in DATA; hop-level match identifier |
| `sf_bitmap` | 1 B | **kept 1 B** | unchanged |
| `payload_len` | 1 B | **kept 1 B** | unchanged |

**Size:**
- `addr_len=0` (in-leaf): **8 B** — same as today, despite gaining hierarchical capability
- `addr_len=1` (cross-region): **9 B**
- `addr_len=2`: **10 B**
- Each additional hierarchy hop: **+1 B**

We dropped `origin` (1 B) and absorbed it into the variable `dst` field. In-leaf RTS size unchanged; cross-network adds 1 B per hierarchy hop.

**Why `ctr_lo` (4 bits) in RTS and not full ctr?** Hop-level matching only needs 4 bits — at any moment a single `pending_tx` / `pending_rx` per peer (1/16 stale-collision is acceptable, same as today's `msg_id`). The full 16-bit `ctr` ships with DATA where the destination needs it for nonce reconstruction. No wire redundancy.

#### CTS — relabel only (size unchanged)

**Today (2 bytes):**
```
'C' | msg_id(4hi) | chosen_data_sf-5(3) | reserved(1)
```

**Proposed (2 bytes):**
```
'C' | ctr_lo(4hi) | chosen_data_sf-5(3) | reserved(1)
```

Pure semantic rename. Forwarder's / originator's `pending_tx` is keyed on the same 4-bit value, derived from the outbound DATA's `ctr` instead of an independent `msg_id` counter.

#### ACK — relabel only (size unchanged)

**Today (2 bytes):**
```
'K' | msg_id(4hi) | snr_bucket(4lo)
```

**Proposed (2 bytes):**
```
'K' | ctr_lo(4hi) | snr_bucket(4lo)
```

Same rename. SNR-bucket piggyback for `snr_ewma_out` (§4 of PROTOCOL.md) works identically.

#### NACK — relabel only (size unchanged)

**Today (4 bytes):**
```
'N' | reason(4hi)+msg_id(4lo) | payload_lo | payload_hi
```

**Proposed (4 bytes):**
```
'N' | reason(4hi)+ctr_lo(4lo) | payload_lo | payload_hi
```

Reason byte interpretation unchanged (`BUSY_RX=0`, `BUDGET=1`, future reasons reserved). Payload semantics depend on reason, as today.

#### Summary

| Frame | Today size | New size (addr_len=0) | Change |
|---|---|---|---|
| RTS | 8 B | **8 B** | `origin` dropped; `dst` made variable; `msg_id` → `ctr_lo` |
| CTS | 2 B | **2 B** | `msg_id` → `ctr_lo` (rename) |
| ACK | 2 B | **2 B** | `msg_id` → `ctr_lo` (rename) |
| NACK | 4 B | **4 B** | `msg_id` → `ctr_lo` (rename) |
| DATA (§7.1) | 8 B + n | **10 B + n** | Crypto + MAC + ctr; hierarchical dst (+1 B per hop) |

**The whole control plane stays wire-compact.** In-leaf control overhead is unchanged from today; hierarchy hops cost 1 B per layer in DATA + RTS only. CTS/ACK/NACK are flow-bound (match against `pending_tx`/`pending_rx`) and don't need to carry the hierarchical path.

**Pending state at hops.**

- Sender's `pending_tx` (outbound flight): keyed on full `ctr` (or `(next, ctr_lo)` is enough at hop-level since only one pending_tx exists at a time per next-hop)
- Receiver's `pending_rx` (inbound flight): keyed on `(src, ctr_lo)`. Set on RTS-rx, cleared on DATA-rx or expiry
- `last_acked_from` cache: keyed on `(src, ctr_lo)`; TTL same as today (10 s default)

All hop-level matching uses 4 bits, same collision space as today's `msg_id`. No behavioral change.

**Composition with §1 anti-spam.**

The behavioral classifier (`R[X]` and `C[X]` distinct-msg_id counts per direct sender) continues to work — it observes RTS and CTS observations and dedups by the 4-bit slot, which is still present (just renamed `ctr_lo`). No change to anti-spam mechanics.

**Cross-references.** §7.1 (DATA carries the full `ctr` whose low nibble flows back through CTS/ACK), §7.2 (BCN format unchanged by control-plane updates), §7.3 (inter-layer RTS use the same format, just at different SF), §1 anti-spam (RTS/CTS observation counts unchanged), §3.6 in PROTOCOL.md (NACK reason byte semantics preserved).

**Implementation cost estimate.**
- `pack_rts` / `parse_rts` variable-length dst handling: ~50 lines
- `pack_cts` / `parse_cts`, `pack_ack`, `pack_nack` semantic rename: ~10 lines each
- Pending state keying migration (`msg_id` → `ctr_lo`): ~30 lines across the matching helpers
- Tests: RTS round-trip for each `addr_len` value (0, 1, 2), CTS/ACK matching with new ctr semantics, cross-layer RTS with hierarchical dst: ~80 lines

### 7.5 Multicast DATA frame (two modes: explicit-list AND multicast-to-all)

**Problem statement.** Multi-recipient delivery (group DMs, channel messages, public broadcasts) needs an efficient wire-level primitive. Two unsatisfying defaults:

1. **N-unicast** — originator sends N separate per-pair-encrypted frames. Body duplicated N times. Wasteful.
2. **Naive flood** — every node rebroadcasts. Collision storms. Probabilistic suppression heuristics needed. ~N TXs but with high collision risk and tuning complexity.

**The unified solution: multicast with explicit OR implicit destination list.** A single wire format and forwarding algorithm covers both small-group and broadcast cases via the value of `dst_count`:

- **`dst_count > 0` (explicit-list mode)**: dst_list carries specific recipients. Each forwarder groups them by next-hop direction using `rt[]`, splits and forwards. Loose-tree.
- **`dst_count == 0` (multicast-to-all mode)**: no dst_list. Means "every node reachable via my `rt[]`". Each forwarder groups its ENTIRE `rt[]` by next-hop direction, splits and forwards. Loose-tree-to-all. This IS the public-broadcast mechanism.

**Forwarders need no per-channel or per-group state — just `rt[]`.** The frame's `dst_count` and (if present) `dst_list` are the only routing signals.

**Wire format (in-leaf only; `addr_len = 0`).** Cross-leaf multicast falls back to per-destination unicast at gateway boundaries.

```
byte:  0   1                       2     3            4..(3+dst_count)         (4+dst_count)..(end)
       ┌───┬──────────────────────┬─────┬────────────┬────────────────────────┬──────────────────┐
       │'D'│ addr_len = 0  (4 hi) │ next│ dst_count  │ dst_list               │ ctr (2 B) +      │
       │   │ E2E_ACK_REQ   (1)    │     │ (8 bits)   │ (omitted if            │ ciphertext + MAC │
       │   │ E2E_IS_ACK    (1)    │     │            │  dst_count==0;         │ (n + 4 B)        │
       │   │ IS_MULTICAST  (1)    │     │ 0 = "all"  │  else 1 B/dst)         │                  │
       │   │ reserved      (1)    │     │ N = list   │                        │                  │
       └───┴──────────────────────┴─────┴────────────┴────────────────────────┴──────────────────┘
```

**Two modes:**

| `dst_count` | Semantic | Use case |
|---|---|---|
| **0** | Multicast-to-all (every node in forwarder's `rt[]`) | Public channels, system-wide broadcasts |
| **1..N** | Multicast-to-explicit-list | Group DMs, channel messages with known members |

**Frame-budget math (255 B LoRa max).**

```
fixed_overhead = 'D'(1) + flags(1) + next(1) + dst_count(1) + ctr(2) + MAC(4) = 10 B
body_budget    = 255 - 10 - dst_count - body_size
```

**Explicit-list mode practical limits:**

| Body size | Max `dst_count` per frame at fast SF |
|---|---|
| 50 B | ~195 |
| 100 B | ~145 |
| 150 B | ~95 |
| 200 B | ~45 |

At slower SFs (SF11/SF12) the practical max can drop to ~50-100 B per frame, severely restricting explicit-list mode. Use multicast-to-all (`dst_count=0`) for large recipient sets to sidestep this entirely — no dst_list bytes, same frame size as a unicast DATA.

**For lists larger than per-frame budget:** the originator splits at SEND time, issuing multiple multicast frames each with a subset of `dst_list` (possibly all to the same first-hop direction). Each downstream split happens naturally via the forwarding algorithm.

**Constraints:**
- `addr_len` MUST be 0 — multicast is intra-leaf
- `dst_count == 0` means "all reachable nodes"; dst_list field is omitted
- `E2E_ACK_REQ` MUST be 0 (no single recipient → no E2E ACK)
- `E2E_IS_ACK` MUST be 0 (multicast frames are never themselves ACKs)

**Forwarding algorithm (handles both modes uniformly).**

```
At forwarder F, on receiving multicast DATA:

1. Local delivery (if recipient):
     if dst_count == 0:
       am_recipient = true (we're in "all")
     else:
       am_recipient = (self.id is in dst_list)
     if am_recipient AND (origin, ctr) NOT in delivered_multicast:
       deliver locally; record in delivered_multicast

2. Forward-side per-destination dedup:
     forwarded_set = forwarded_by_multicast[(origin, ctr)] or empty set
     if dst_count == 0:
       working_set = { entry.dest for entry in rt[] } - {self.id} - forwarded_set
     else:
       working_set = dst_list - {self.id} - forwarded_set
   if working_set is empty: done.

3. Group by next-hop direction:
     by_next = {}
     for d in working_set:
       if rt[d] is missing: skip d (no route; drop silently)
       hop = rt[d].next_hop
       by_next[hop].append(d)

4. For each (next_hop, subset) in by_next:
     if next_hop != frame.previous_hop:    -- prevent echoes
       if dst_count == 0:
         send multicast-to-all frame (dst_count=0, no dst_list) to next_hop
       else:
         send multicast frame with dst_list=subset to next_hop

5. Update forwarded-set state:
     forwarded_by_multicast[(origin, ctr)] += working_set
     touch_ttl(forwarded_by_multicast[(origin, ctr)], multicast_dedup_ttl_ms)
```

The "all" mode doesn't even carry the list — each forwarder reconstructs it from local `rt[]` on the fly. Saves wire bytes; relies on `rt[]` being current.

**Per-destination forwarding dedup — why mesh requires it.** Standard `seen_origins` (§10) dedup is **insufficient for multicast in mesh topologies**. The same multicast operation legitimately splits into multiple frames carrying DIFFERENT destination subsets, all sharing `(origin, ctr)`. A naive `seen_origins` check would drop all but the first split arriving at each forwarder, losing destinations carried by the others.

**Diamond example (showing why):**

```
       A (originator, wants to reach D and E)
      / \
     B   C
      \ /
       D (also forwards to E)
       |
       E

A's rt[D] = via B; A's rt[E] = via C (C → D → E)

Naive seen_origins (BROKEN):
  A → B with dst_list=[D]      → B → D delivers, marks (A,ctr)
  A → C with dst_list=[E]      → C → D
  D sees (A,ctr) seen → drops  → E LOST

With per-destination forwarding dedup (CORRECT):
  A → B with dst_list=[D]      → D delivers, forwarded={D}
  A → C with dst_list=[E]      → C → D
  D: working_set = [E] - {D forwarded} = [E]
  D forwards to E, forwarded={D, E}
  E receives ✓
```

**Two distinct dedup tables at each forwarder:**

| Table | Keyed on | Purpose | TTL |
|---|---|---|---|
| `delivered_multicast[(origin, ctr)]` | (origin, ctr) | Prevent double-delivery to local app when frame arrives via multiple paths | `seen_origin_ttl_ms` (existing default 30 s) |
| `forwarded_by_multicast[(origin, ctr)]` | (origin, ctr) → set of destinations | Prevent re-forwarding same destinations on re-arriving multicast splits | `multicast_dedup_ttl_ms` (default 300 s = 5 min — covers mesh propagation timescales) |

**State cost.** Per active multicast: ~24 bytes overhead + ~1 byte per destination already forwarded. For a forwarder seeing 10 active multicasts each with average 10 destinations: ~340 bytes total. Negligible.

The two tables are functionally separate but small and bounded.

**Why `multicast_dedup_ttl_ms` is longer than `seen_origin_ttl_ms`:** local delivery dedup just needs to cover human-perception timescales (don't deliver the same chat message twice in quick succession). Forwarding dedup needs to cover the time for a multicast to fully propagate through the mesh (multi-hop, possibly with retries) — a few minutes is appropriate.

**Worked example — explicit list (30 recipients, body ≈ 50 B).**

```
P's rt[]:
  {s1..s10} reachable via next_hop A
  {s11..s20} reachable via next_hop B
  {s21..s30} reachable via next_hop C

P sends 3 multicast frames (dst_count > 0):
  → A: dst_list = [s1..s10], ctr=X, ciphertext
  → B: dst_list = [s11..s20], same ctr, same ciphertext
  → C: dst_list = [s21..s30], same ctr, same ciphertext

(...continues recursively, splitting at each hop.)
```

**Worked example — multicast-to-all (public broadcast).**

```
P's rt[] has 99 reachable nodes, grouped by first-hop direction:
  {25 dests} via A, {30 dests} via B, {25 dests} via C, {19 dests} via D

P sends 4 multicast-to-all frames (dst_count = 0):
  → A: no dst_list, ctr=X, ciphertext
  → B: same
  → C: same
  → D: same

Each first-hop forwarder receives, computes ITS rt[]-grouped subset
(naturally excluding the direction it came from), and continues.

Total frames: ~N-1 = ~99 (one per spanning-tree edge).
Frame size: same as unicast DATA (no dst_list overhead).
```

**Wire-cost comparison (100-node leaf, multicast-to-all vs flood).**

| Mechanism | Total TXs | Frame size | Collision risk |
|---|---|---|---|
| Naive flood | ~N = ~100 | small (no dst_list) | **High** — many nodes try to rebroadcast same frame around the same time |
| Multicast-to-all (`dst_count=0`) | ~N-1 = ~99 | same (no dst_list) | **Low** — only specific nodes per direction forward at each tree level |
| Pure flood with probabilistic suppression | < ~N (some skip) | small | Medium (suppression heuristics tune the trade-off) |

**Multicast-to-all beats naive flood on every axis except: nodes NOT in current `rt[]` (newly joined). Flood catches them via radio reach; multicast-to-all doesn't. Mitigation: new joiner's BCN propagates within ~5 min, then subsequent public broadcasts reach them.**

**Wire-cost comparison (explicit-list mode, 30 recipients, body ≈ 50 B).**

| Strategy | Originator-side frames | Total network airtime (rough) |
|---|---|---|
| N-unicast (30 separate DM flights) | 30 frames | ~1920 B at originator + downstream forwards |
| Subscriber-driven loose-tree (BCN sub_table) | 3 frames (one per direction) | ~30-40 hops total airtime |
| **Multicast explicit-list (§7.5)** | **3 frames** | **~30-40 hops total airtime** (comparable to loose-tree) |
| Pure flood | N/A (everyone rebroadcasts) | ~100+ hops, collision risk |

Explicit-list multicast achieves loose-tree's airtime efficiency **without forwarders tracking subscriptions.**

**Crypto compatibility.**

Multicast assumes a SINGLE ciphertext that all recipients can decrypt. Compatible with:
- **Plaintext** (no encryption — public-channel messages)
- **Group PSK** (channel/group key shared by all recipients)
- **Pre-shared group session_key** (small fixed groups with negotiated common key)

NOT compatible with §8.1 per-pair `session_keys` (different recipients have different keys). For per-pair encryption to multiple recipients, fall back to N-unicast.

This means multicast naturally pairs with **§3 channel mechanics** (group PSK for group/private; plaintext for public).

**Where multicast wins.**

| Use case | Why multicast helps |
|---|---|
| Public channel (multicast-to-all mode) | One frame per direction at each hop; same airtime as flood but with deterministic spanning-tree delivery and no collision storms |
| Group DM (3-15 friends, originator sends to all) | Body shared across recipients in same direction; no group-state at forwarders |
| Channel delivery when subscribers are known (explicit-list) | Sender includes member list; mesh delivers via loose-tree |
| App-defined groups (ad-hoc subset of contacts) | Originator picks recipients per send; no standing channel state needed |

**Where multicast loses.**

| Use case | Why multicast doesn't help |
|---|---|
| Very large explicit lists (100+ recipients with non-trivial body) | dst_list eats the per-frame budget; use multicast-to-all instead OR subscriber-driven |
| §8.1 per-pair DM to multiple | Different `session_keys`; can't share ciphertext; falls back to N-unicast |
| Recipient list unknown at originator (explicit-list case) | Discovery problem unsolved by multicast (must come from elsewhere — server, Bloom, pull query) |
| Reaching nodes not in any rt[] (newly joined, off-grid) | Multicast-to-all misses them until BCN propagation. Naive flood would catch them. |

**Composition with the rest of the protocol.**

| Subsystem | Composition |
|---|---|
| **§7.1 DATA** | Multicast is a flag-variant; same `ctr`, MAC, encryption mechanics; same per-hop RTS/CTS/DATA/ACK chain |
| **§7.2 BCN** | No BCN change — multicast uses existing `rt[]` for direction-grouping |
| **§7.3 inter-layer** | Cross-leaf multicast falls back to per-destination unicast at gateway, OR operator-configured channel-bridge per §3 |
| **§7.4 RTS/CTS/ACK** | Standard hop-level handshake at each splitter (RTS carries `IS_MULTICAST` flag) |
| **§3 channels** | Multicast IS the unified delivery mechanism for all three channel flavors (public via `dst_count=0`; group/private via explicit list). |
| **§5 E2E ACK** | Skipped for multicast (no single recipient — same rule as channels) |
| **§9 T2 privacy** | dst_list (when present) is plaintext on wire (forwarders need it for routing). Originator identity in encrypted body. Same trade as unicast `dst`. |
| **§1 anti-spam** | Each multicast frame counts as one origination at the 1st-hop neighbour (same as any DATA). Sending a multicast to N recipients = ONE origination, not N. Natural rate-amortization. |

**What this design deliberately doesn't solve.**

- **Recipient discovery** for explicit-list mode. Multicast assumes the originator already knows the list. Discovery is a separate concern (still open for group/private channels — see §3).
- **Per-pair-encrypted DM to multiple recipients.** Falls back to N-unicast.
- **Member-set changes mid-flight.** If a recipient is removed from the group between when the originator picks the list and when delivery completes, that recipient still receives the frame (and may be unable to decrypt if their key was rotated out).
- **Reaching nodes not in `rt[]`** under multicast-to-all (newly joined; gap until next BCN cycle).

**Tunables.**

| Key | Default | Purpose |
|---|---|---|
| `multicast_max_dst_count` | computed from SF + body | Per-SF cap on destinations per multicast frame (frame-budget guardrail); originator splits if needed |
| `multicast_drop_unroutable` | true | If `rt[d]` is missing at a forwarder, silently drop `d` from the subset (vs. flooding all neighbors) |
| `multicast_dedup_ttl_ms` | 300000 (5 min) | TTL for `forwarded_by_multicast[(origin, ctr)]` entries. Sized to cover mesh propagation including retries. After expiry, a re-arriving frame with same (origin, ctr) is treated as a fresh multicast (rare in practice). |
| `multicast_forwarded_table_max` | 64 | Soft cap on simultaneously-tracked multicasts per forwarder; LRU eviction beyond this. Protects memory under burst load. |

**Implementation cost estimate.**

- `pack_data` / `parse_data` multicast variant (both modes): ~60 lines
- Forwarding algorithm (group-by-next-hop, fan-out, dst_count=0 specialization): ~70 lines
- Local-delivery branch (when self is recipient in either mode): ~25 lines
- `delivered_multicast` + `forwarded_by_multicast` tables with TTL aging + LRU cap: ~80 lines
- Diamond / multi-path dedup tests (the cases naive seen_origins would break): ~50 lines
- Group-PSK crypto integration (for channel use case): ~50 lines
- Tests: explicit-list multicast round-trip, multicast-to-all coverage, fan-out at splitter, **mesh diamond delivery (the case proving per-dest dedup works)**, drop-unroutable, gateway boundary fallback, TTL expiry of forwarded-set, LRU eviction under burst: ~250 lines

**Cross-references.** §7.1 (unicast DATA shares the encryption + MAC structure), §3 (channels are the primary use case for multicast; both modes used), §10 in PROTOCOL.md (origin-level dedup via `seen_origins` is for unicast — multicast has its own per-destination forwarding dedup), §1 (each multicast frame = one origination at 1st-hop counters), §9 (originator identity in encrypted body; dst_list visible to forwarders for routing).

### 7.6 DATA hop budget + opportunistic rt-learning (per-flight TTL + route-info propagation) (IMPLEMENTED)

**Status — IMPLEMENTED.** Per-flight `hop_budget` (originator initializes
to `rt[dst].hops + hop_budget_slack`, default 3) and forwarder-side
`rt_learn_from_data` both live in `scenarios/dv_dual_sf.lua`. Hop-budget
exhaustion emits `hop_budget_exceeded` and a `NACK_REASON_HOP_BUDGET`
to the upstream sender; covered by `test/t36_hop_budget_exceeded.json`.

**Problem statement.** The 8-hop rt-merge filter ("Routes with hops > 8 rejected") bounds the rt[]-entry hops field but does NOT enforce an end-to-end ceiling on actual DATA-flight path length. AND: rt[] views drift out of sync between forwarders because BCN propagation is throttled to save airtime — so each forwarder uses a slightly different (often stale) view, and the locally-optimal choices don't compose into the globally-shortest path.

**Measured on s04_seattle_realistic** (138 nodes, 60 min, 181 delivered flights):

- 5.5% of deliveries had actual path > 8 hops (max 12 hops, vs 5-hop shortest)
- 24% of flights' actual path was LONGER than originator's rt[dst].hops said
- Median rt entry age at send: 14.7 minutes (rt entries are stale by ~15 min on average)
- For the worst-wandering flights: each forwarder's rt[dst].hops advertised values were INCONSISTENT (5/6/7 for the same dst)

This is fundamentally a DV-routing limitation. Without global topology knowledge AND without enough BCN bandwidth to keep rt[] fresh, forwarders' local choices accumulate non-trivially.

**Proposal.** Add 2 bytes to the DATA frame that serve a dual purpose:

1. **Hop budget** (byte X) — enforces a per-flight cap on path length; bounds the wandering.
2. **Previous-forwarder rt[dst] claim** (byte Y) — turns every DATA frame into a tiny BCN entry for its destination. **Every receiver — addressed forwarder OR overhearing neighbor — can do an opportunistic `rt_merge` for `dst` based on the carried claim + measured SNR.** This propagates routing info via DATA flow, much faster than BCN-only.

The two pieces work together: hop_budget catches the worst-wandering flights; rt-learning prevents future flights from making the same wandering choices.

**Wire format addition.**
```
DATA gains 2 bytes immediately before the encrypted body:

byte X: hop_budget byte
  bits 7-4 (hi nibble): hops_remaining  (decremented per forwarder; drop at 0)
  bits 3-0 (lo nibble): committed_hops  (incremented per forwarder; informational)

byte Y: prev_fwd_rt_hops (1B)
  The previous forwarder's rt[dst].hops at the moment they transmitted.
  Initially set by originator to rt[dst].hops at send time.
  OVERWRITTEN at each addressed forwarder before re-transmission.
  Read by addressed forwarder AND by overhearing neighbors for rt-learning.
```

Both nibbles in byte X capped at 15 (4-bit max). For protocols with 8-hop primary limit + slack of 3, max budget = 11.

**Originator initialization.**
```
issue_send(dst):
  budget_remaining   = min(15, rt[dst].hops + slack)   -- slack default 3
  budget_committed   = 0
  prev_fwd_rt_hops   = rt[dst].hops
  emit_data_with_hop_budget(...)
```

**Forwarder logic (the addressed `next`-hop).**
```
on_recv DATA (self.id == frame.next):
  -- (A) hop budget enforcement
  hop_budget.committed += 1
  hop_budget.remaining -= 1
  if hop_budget.remaining < 0 AND self.id != dst:
    emit "hop_budget_exceeded"
    send NACK(reason=hop_budget) back to upstream prev_hop
    drop (do not forward, do not deliver)

  -- (B) opportunistic rt-learning from carried claim
  rt_learn_from_carried(meta.src, dst, frame.prev_fwd_rt_hops, meta.snr)

  -- (C) before re-transmitting downstream:
  outbound_frame.prev_fwd_rt_hops = self.rt[dst].hops
  ... existing forwarding logic ...
```

**Overhearing neighbor logic (= radio-range neighbor receiving DATA addressed to someone else).**
```
on_recv DATA (self.id != frame.next):
  -- Standard: ignore for routing/forwarding (frame is not for us)
  -- NEW: opportunistic rt-learning for the carried destination
  rt_learn_from_carried(meta.src, dst, frame.prev_fwd_rt_hops, meta.snr)
  return  (no forwarding; just the learning side-effect)
```

**The rt-learning helper.**
```
rt_learn_from_carried(carrier_id, dst, carrier_rt_hops, our_snr_to_carrier):
  -- Carrier (= meta.src = the node that just transmitted) claims to
  -- reach dst in carrier_rt_hops hops. From our perspective, dst is
  -- reachable via carrier in (carrier_rt_hops + 1) hops, with quality
  -- gated by our SNR to carrier.
  derived_hops  = carrier_rt_hops + 1
  derived_score = our_snr_to_carrier
  if derived_hops > MAX_HOP_LIMIT (= 8): return  -- same rt_merge guard as BCN
  candidate = { next = carrier_id, hops = derived_hops, score = derived_score }
  rt_merge_one(self.rt, dst, candidate)   -- existing rt_merge logic
  -- rt_merge applies route_strictly_better, 3-cycle prune, K=3 alts cap, etc.
```

**Why this matters.** Existing protocol updates `snr_ewma_in[meta.src]` on every successful decode (any frame type). It does NOT propagate routing info beyond the immediate hop. With this addition, every successful DATA decode also propagates rt[dst]-cost info to the receiver. The same way snr_ewma works automatically per-link, **rt[dst] now updates automatically per-flight-overheard.** No extra airtime; just 1 byte per DATA frame.

**Trust and loop concerns (and how the existing protocol handles them).**

- **Stale claim**: a forwarder might claim "dst 4 hops" but be wrong. Same problem as BCN. `route_strictly_better` only updates rt if the new candidate is genuinely better. SNR weighting penalizes weak-SNR claims.
- **Loop creation**: a learned candidate could create a 2-hop or 3-hop cycle. Existing `3-cycle prune` (§5.3) already handles this for BCN-derived entries; identical mechanism applies.
- **Malicious claim**: a node could lie about rt_hops. Same trust assumption as BCN. No new attack surface beyond what BCN already exposes.

**Penalty-aware behavior (composes with §5.7 tier-aware routing).**

The tier-aware penalty system (§5.7) — `TIER_SCORE_PENALTY_DB = {HEALTHY=0, STRAINED=2, CRITICAL=5, EXHAUSTED=20}` — must be honored at three points in this design:

**1. What gets written to `prev_fwd_rt_hops`.** Forwarder writes `self.rt[dst].hops` where `rt[dst].primary` has already been selected via `route_strictly_better` with tier-penalty consideration. If the "shortest path" runs through a peer the forwarder knows is SATURATED, the alt has already been promoted to primary, and the alt's hops are what get written. **Carried value reflects the path the forwarder would actually use under current tier conditions** — not an idealised cost.

**2. How a receiver learns the candidate.** When a receiver applies `rt_merge_one` for the learned candidate `{ next = meta.src, hops = N+1, score = meta.snr }`, the existing `route_strictly_better` computes `effective_score = candidate.score - TIER_PENALTY[meta.src's known tier]`. If the receiver has observed `meta.src` as STRAINED via a prior `budget_low` NACK reception, the learned candidate's effective score is automatically penalized. The receiver's existing `neighbor_budget_tier[]` table feeds into this comparison without any new wiring.

**3. Forwarding decisions on the same flight.** The forwarder selecting which next-hop to send DATA to also uses `route_strictly_better` with tier penalty — already implemented, unchanged. If the primary candidate's next-hop is currently CRITICAL or EXHAUSTED, the forwarder picks the alt with better effective_score.

**Corner case — stale tier info at overhearing nodes.** An overhearing neighbor may not have heard a `budget_low` NACK from the carrier recently, so it doesn't know the carrier's current tier. Receiver assumes HEALTHY (= no penalty applied to learned candidate). The learned candidate may be slightly too-optimistic relative to reality. Mitigations already in protocol:

- `neighbor_budget_tier_ttl_ms` (5 min default) ages stale tier info — overhearing node will re-default to HEALTHY if no fresh NACK observed
- The next time the overhearing node TRIES to use the learned candidate and the carrier is actually saturated, a fresh `budget_low` NACK propagates the tier info
- Same robustness as the existing tier-aware routing under stale info

**Net result:** the §7.6 rt-learning composes cleanly with §5.7 tier penalty without any new wire fields. Penalty is applied automatically wherever `route_strictly_better` runs, which is everywhere `rt_merge_one` or forwarding decisions happen.

**NACK reason extension.** NACK reason field gains a new value: `hop_budget`. Three-byte NACK frame layout unchanged from §3.6:

```
reason 0: busy_rx (pending_rx active)
reason 1: budget_low (duty-cycle saturated)
reason 2: hop_budget (NEW — flight exceeded its hop budget)
```

NACK payload for reason=hop_budget: 2 bytes carrying `original_budget` + `actual_committed` so originator can learn how far the wandering went.

**Originator's NACK handling for reason=hop_budget.**
1. Surface `flight_hop_exceeded` event to app layer (failure indication)
2. Increment originator's `rt[dst].hops` by 1 (= rt was under-estimating; raise estimate)
3. If `rt[dst].hops` now > some threshold (e.g., 8): consider the route stale; trigger Q-frame re-discovery (§3.7)
4. App may retry with larger slack if it needs to push through

**Slack tuning (calibrated against s04 data).**

| `slack` | Currently-delivered flights that would drop | Wasted-airtime saved |
|---|---|---|
| 0 (strict) | ~24% | maximum |
| 1 | ~13% | high |
| 2 | ~8% | medium-high |
| **3 (recommended)** | **~4%** | **medium** |
| 5 | ~2% | low |
| ∞ (no enforcement) | 0% | none |

`slack = 3` catches the worst-wandering flights while preserving most moderate detours. The drops are mitigated over time by the rt-learning piece — repeated flights to the same dst should converge to shorter paths.

**Convergence dynamic (the "vote" effect through DATA flow).**

Without rt-learning (BCN-only):
- Flight 1 to dst: forwarders use stale rt; path wanders
- Flight 2 to dst (5 minutes later): forwarders' rt is still stale; same wandering
- BCN refresh takes minutes; convergence is slow

With rt-learning via carried claim:
- Flight 1 to dst: forwarders along the path AND overhearing neighbors update rt[dst] from carried claims
- Flight 2 to dst (5 minutes later): forwarders' rt[dst] reflects evidence from flight 1 — likely shorter path chosen
- Each successful flight teaches all participating + nearby nodes
- Convergence in a few flight-rounds rather than tens of minutes

**Scope of learning.** Only destinations being actively communicated to get rt-updates from this mechanism. Cold destinations still rely on BCN. **Hot destinations (= the ones that matter for routing decisions) converge fast.**

**Wire-cost summary.**

| Frame | Today | Proposed | Δ |
|---|---|---|---|
| DATA (regular) | 6 B header + n payload | 8 B header + n payload | **+2 B** |
| DATA with E2E_IS_ACK=1 (return ACK) | 6 B header + 4 B ACK body | 8 B header + 5 B ACK body | **+3 B (ACK only)** |
| NACK | 4 B (with reason byte) | 4 B (new reason value, no size change) | 0 |
| RTS / CTS / ACK / BCN / Q | unchanged | unchanged | 0 |

For a 50-byte payload: +4% per DATA frame. E2E ACK frames are small (~10 B on wire); +1 byte for `actual_hops_used` is ~10% on the ACK only — but ACKs are rare (only opt-in flights), so network-wide cost is negligible.

**What this design deliberately does.**

- **Bounds wandering** via hop_budget enforcement (per-flight TTL)
- **Propagates rt[dst] info via DATA flow** to addressed forwarders + overhearing neighbors
- **Reuses existing rt_merge logic** (route_strictly_better, 3-cycle prune, K=3 alts cap) — no new merge semantics
- **Costs 1 extra byte per DATA frame** for the carried claim (vs the original §7.6 design that used the same byte for `expected_first_hop`)

**What this design deliberately does NOT do.**

- **Does NOT carry the full source-route.** Only the previous forwarder's rt-claim — no path enumeration.
- **Does NOT implement inter-forwarder consensus or voting.** Each forwarder still makes independent local decisions; the carried claim just adds another input to rt_merge.
- **Does NOT propagate info about cold destinations** (dsts that aren't currently being communicated to). BCN remains the only mechanism for those.
- **Does NOT carry SNR-along-the-path summary** (Variant C from design discussion). Could be added later if needed.

**E2E ACK return-path learning (§5 extension).**

Because the §5 E2E ACK is itself a DATA-class frame (with `E2E_IS_ACK=1`), the same §7.6 mechanism applies automatically on the return trip:

- ACK's `prev_fwd_rt_hops` carries forwarder claims for `dst-of-ACK` = the originator
- All forwarders + overhearing neighbors on the return path learn rt[originator].hops
- ACK's `hop_budget` enforces a per-flight cap on the return route too

**This means the FORWARD flight teaches the network about routes to the destination, AND the RETURN ACK teaches the network about routes to the originator. Both directions propagate routing info through DATA flow.**

**Plus an explicit additional field on E2E ACK only.** The E2E ACK body extends by 1 byte to carry `actual_hops_used` — the count of hops the ORIGINAL forward-direction DATA traveled to reach the destination. The destination derives this directly from the received DATA's `hop_budget.committed_hops` field (= the field §7.6 already increments at each forwarder).

```
E2E ACK frame body (was: acked_seq(2B); now: acked_seq(2B) + actual_hops_used(1B))

byte 0-1: acked_seq      (the original (origin, seq) being ACK'd, unchanged)
byte 2:   actual_hops_used (4 hi: hops the forward DATA traveled to dst,
                            4 lo: reserved)
```

Originator, on receiving the E2E ACK with `actual_hops_used`:
1. Compare with self.rt[dst].hops:
   - If `actual_hops_used < self.rt[dst].hops`: rt was over-estimating; update down
   - If `actual_hops_used > self.rt[dst].hops`: rt was under-estimating; update up (may push to alt)
   - If equal: no change
2. Update rt[dst].hops with empirical evidence

This closes a third learning loop: the originator gets DEFINITIVE truth about the forward path's actual length, on top of the en-route rt-learning that §7.6 already provides.

**Composition with other roadmap items.**

| Subsystem | Composition |
|---|---|
| **§5 E2E ACK** | E2E ACK gains `actual_hops_used` field (+1B on ACK body only). Plus inherits §7.6 hop_budget + prev_fwd_rt_hops on the return trip — every node along the return path learns rt[originator]. |
| **§7.1 hierarchical DATA** | Adds 2 bytes to DATA header. Combined with privacy + crypto, total overhead ≈ +5 B (T2/crypto) +2 B (hop budget + rt-learning) = +7 B vs today. |
| **§7.5 multicast** | Multicast carries one hop_budget per frame; rt-learning piggyback applies to each multicast destination. |
| **§5.6 cascade-requeue** | `hop_budget_exceeded` failure feeds into cascade-requeue same as other rts_giveup events |
| **§1 anti-spam** | No interaction; one frame, one origination |
| **§3 channels** | Channel-mode multicast inherits same hop_budget mechanism; rt-learning applies per channel destination |
| **PROTOCOL.md §4 SNR EWMA** | Existing per-link SNR EWMA update on every decode (already covers this exact pattern for SNR); rt-learning is a parallel mechanism for hops field |
| **PROTOCOL.md §5.7 tier-aware routing** | **Penalty system applies automatically** — `prev_fwd_rt_hops` value reflects the forwarder's penalty-influenced primary choice; learned candidates go through `route_strictly_better` with tier penalty. No new wire fields needed. See "Penalty-aware behavior" subsection. |

**Open questions / future variants.**

- **Slack-per-traffic-class**: maybe E2E-ACK-requested flights get higher slack. Defer.
- **Variant C (cumulative path quality)**: carry weakest_link_snr + hops_walked instead of prev_fwd_rt_hops. More info per byte, more complex semantics. Deferred.
- **Variant B (last-2-forwarder IDs)**: carry the last 2 forwarder IDs to learn about FORWARDERS rather than DESTINATIONS. Different learning target; can be added as a separate proposal if needed.
- **rt-learning for destinations beyond limit**: current design rejects derived_hops > 8 (same as BCN rt_merge). Could allow up to higher limit if hop_budget is also raised. Tied together.

**Tunables.**

| Key | Default | Purpose |
|---|---|---|
| `hop_budget_slack` | 3 | Extra hops above rt[dst].hops the originator grants |
| `hop_budget_max_initial` | 15 | Hard cap on initial budget (= 4-bit field max) |
| `rt_learn_from_data` | true | Whether to apply rt_merge from carried `prev_fwd_rt_hops` (overhear + addressed) |
| `e2e_ack_carries_actual_hops` | true | Whether E2E ACK body includes `actual_hops_used` (+1B on ACK only) |

**Implementation cost estimate.**

- DATA pack/parse extension for hop_budget + prev_fwd_rt_hops bytes: ~30 lines
- Forwarder decrement + drop + NACK emit on exhaustion: ~30 lines
- `rt_learn_from_carried` helper (calls existing rt_merge_one): ~25 lines
- Wire-up at addressed-forwarder path AND overhearing-neighbor path in on_recv: ~20 lines
- NACK reason extension (new reason `hop_budget`): ~20 lines
- Originator's NACK-rx handler for hop_budget: ~30 lines
- E2E ACK pack/parse extension for `actual_hops_used` (+1B on ACK body): ~15 lines
- Originator's E2E-ACK-rx handler for rt-cost learning from `actual_hops_used`: ~25 lines
- Analyzer §19 extension: tally hop_budget_exceeded drops + measure rt-learning effects (rt-update events triggered by DATA vs BCN vs E2E-ACK feedback): ~60 lines
- Tests: hop_budget exhaustion drop + NACK return + rt-learning convergence (multi-flight scenario) + E2E ACK actual_hops feedback: ~180 lines

**Cross-references.** §3.6 PROTOCOL.md (NACK reason byte extends with new value), §4 PROTOCOL.md (existing per-link SNR EWMA pattern is the inspiration), §5.2 PROTOCOL.md (`rt_merge` is reused for the carried-claim learning), §5 (E2E ACK body gains `actual_hops_used` field), §7.1 (DATA gains 2 bytes), §7.5 (multicast inherits same hop_budget), §11.5 (budget tiers — orthogonal, hop_budget is per-flight not per-node), §13 events (new `hop_budget_exceeded` event; existing `rt_update` events will fire more frequently from DATA-driven learning + E2E-ACK feedback).

---

## 8. Cryptography

**Problem.** All frames are plaintext today. Any node within radio range reads all traffic. There's no authentication — a malicious node can spoof source addresses, inject fake routing info, or replay captured frames.

**What we want.** Three layered concerns:

1. **E2E confidentiality** for user data (DATA payload encrypted between origin and dst; forwarders see ciphertext only).
2. **Frame-level authenticity** for the control plane (RTS/CTS/ACK/BCN auth-only, no encryption — forwarders verify before relaying).
3. **Key management** practical for embedded LoRa hardware (no per-frame public-key crypto; offline-friendly bootstrap).

**Constraints.**
- Frame budget: 255 bytes max. Crypto overhead (IV, MAC) must fit alongside payload.
- LoRa CPU is tight — no per-frame ECDH or RSA. Symmetric primitives (ChaCha20, AES, BLAKE2/HMAC) only.
- Mesh is offline-friendly — no assumption of centralized PKI or always-on internet.
- Forwarders should be able to route without holding decryption keys (privacy from the routing layer).

**Possible directions (none committed).**
- **E2E layer (LoRa-tuned, see §8.1 for full design)**: ChaCha20 with **4-byte truncated Poly1305 MAC**, **2-byte per-peer message counter on wire**, and **implicit nonce derived from (counter ∥ dst ∥ msg_id)**. Net wire cost = +3 B per DATA frame (was +28 B with standard ChaCha20-Poly1305). No on-wire session identifier — MAC trial-verify at the destination IS the key-selection step. The traditional 128-bit MAC is overkill at LoRa's PHY rate — see §8 "MAC sizing under LoRa rate limit" below.
- **Frame auth**: 4 B truncated MAC on RTS and BCN using a network-wide PSK. CTS/ACK skip explicit MAC — they're stateful replies matched against an already-authenticated RTS, so a spoofed CTS/ACK without that prior state gets dropped at the matching layer.
- **Key bootstrap**: per-network PSK distributed out-of-band (real Meshtastic does this — QR code at deployment time). Per-pair E2E keys via X25519 ECDH at first contact (~50 ms on Cortex-M0, **once per peer ever**, NOT per-message).
- **Forward secrecy**: **deliberately not provided** in this design. `session_key` is derived once via X25519+HKDF at first contact and reused until peers re-key (e.g., counter wrap at 65,536 messages, or explicit user action). Rationale: on a handheld LoRa device, the message archive is stored locally in plaintext — an attacker who compromises the device gets the message history directly, so daily-rotated forward secrecy provides marginal real-world value and would require time-sync we want to avoid. If forward secrecy becomes required for a specific deployment, layer in an epoch counter via NTP/GPS time or peer-clock-gossip — out of scope for the base proposal.
- **Replay protection**: per-peer message counter on the wire (2 bytes) does triple duty — nonce uniqueness for crypto, replay protection (strict monotonic check), and application-level dedup (replaces today's `origin_seq`). Composes with our existing `last_acked_from` dedup machinery.

**MAC sizing under LoRa rate limit.** Standard internet-protocol advice (128-bit MAC) assumes adversaries doing ~10⁹ attempts/sec. LoRa SF8 caps attempts at ~20/sec per channel (50 ms airtime per frame). A 32-bit MAC gives 2⁻³² forgery probability per attempt → ~3 years to find a single forgery. A 64-bit MAC → ~30,000 years. **4-byte MAC is genuinely defensible for LoRa control + data plane** and is what §8.1 builds on. Cipher keys remain 128-256 bits — they sit in memory, costing zero on-wire bytes.

**Open questions.**
- Per-pair E2E keys (requires N storage at each node, not N² — symmetric session_key is derived deterministically from the X25519 secret) vs per-channel (smaller storage, weaker guarantees). §8.1 takes the per-pair path; channels (§6) need separate group-key story.
- Should the routing layer be cryptographically authenticated, or rely on physical-layer trust? Meshtastic doesn't auth routing; we could be more conservative — frame-auth on RTS + BCN, skip CTS/ACK as above.
- Counter persistence across reboots — sender's `peer_send_counter[B]` MUST survive power-off (NV storage, ~2 B per peer). If the counter resets to 0 after reboot, B's strict-monotonic check would reject all subsequent messages until manual re-sync. Flash write-cycle budget is ample for typical traffic.
- Counter wrap recovery — at 65,536 messages to a single peer (~18 years at 10 msg/day), peers must re-derive `session_key` via fresh X25519 ECDH against current pubkeys. Detection: sender approaching wrap emits a "re-key now" app-layer event; user accepts; both sides regenerate.
- Hardware crypto acceleration availability — SX1262 doesn't have it, so all crypto runs on the host MCU. ChaCha20+Poly1305 is fast on M0/M4 (~2 µs/byte); X25519 ECDH is ~50 ms — acceptable once per peer first-contact, but we avoid it per-message.
- Interaction with §6 channels and §7 multi-net (distinct key sets per channel and per network).

### 8.1 Concrete per-pair DM crypto proposal

> **See also §7.1** for the synthesis of this crypto proposal with hierarchical routing (§7) and originator anonymity (§9 T2) into a single concrete DATA frame.

**Problem statement.** A user on node A wants to send a confidential, authenticated message to node B. Forwarders along the route must not be able to read the payload, and (composing with §9 T2) must not be able to identify A as the originator. What does A need from B in practice, and what's on the wire?

**What A needs from B (the practical answer).** B's long-term public key — 32 bytes, X25519. Acquired one of two ways:

1. **Out-of-band, once at first contact.** B shows a QR code (or NFC tags); A scans. Contains B's pubkey + nickname + signature over the pair. Same UX pattern Signal/WhatsApp use for safety numbers.
2. **In-mesh identity-card request.** A issues a `'?'` query frame (analogous to our Q-frame for routes) asking "anyone have B's identity card?". A neighbor with B's `'I'` (Identity) frame cached replies. A caches B's pubkey. First contact done — no per-message public-key crypto ever after this.

**Per-peer setup (one-time, both sides compute independently).**
```
shared_secret = X25519(self_private, peer_public)      -- ~50 ms on Cortex-M0
session_key   = HKDF(shared_secret, "msg", 32 bytes)   -- derived once, no time input
```
Both A and B arrive at the **same** `session_key` for this peer. Persisted to NV storage; reused until counter wrap or explicit re-key. **No clock or epoch needed** — the protocol does not require time sync between nodes, which matches MeshCore's operational model.

**Per-message nonce uniqueness via on-wire counter.** Stream-cipher security requires every `(session_key, nonce)` pair to be used at most once. Without a clock to derive nonces from, we use a **2-byte per-peer message counter** sent on the wire: sender increments `peer_send_counter[B]` for each message; the counter feeds the nonce derivation AND serves as replay protection (strict monotonic at receiver) AND replaces today's `origin_seq` for app-layer dedup. Triple-duty primitive.

**No on-wire session identifier.** Earlier drafts considered a 4-byte `session_id` to let B index directly into its key table. We don't need it — see "Why no session_id?" below. The 2-byte counter is the only crypto metadata on the wire.

**Per-message flow (A sends "hello bob" to B).**
```
At A:
  ctr         = ++peer_send_counter[B]                              -- NV-persisted
  nonce       = derive(ctr || dst || msg_id)                        -- IMPLICIT (NOT on wire as a separate nonce field)
  ciphertext  = ChaCha20(session_key, nonce, user_text)
  mac         = Poly1305-truncated-4B(session_key, ciphertext || header_fields || ctr)
  send: 'D' | src | dst | next | msg_id | ctr(2B) | ciphertext || mac(4B)

Forwarders:
  - route by `dst` as today; cache (msg_id, dst, prev_hop) for §5 reverse-path
  - cannot decrypt (no session_key), cannot identify A (no `origin` on wire,
    no per-pair tracking handle — ciphertext is fully opaque; ctr is per-peer
    state visible only to someone who already knows the (A,B) relationship)

At B (only when dst == self.id):
  - read `ctr` from wire
  - trial-verify MAC against each peer session_key (LRU sorted; usually first hit)
  - first key that MAC-verifies → that's the peer → that's the originator
  - check ctr > last_seen_counter[peer]; if not → drop as replay
  - reconstruct implicit nonce from (ctr || self.id || msg_id), decrypt → get user_text
  - update last_seen_counter[peer] = ctr; display "Message from A: hello bob"
  - if no key verifies → drop silently (not for me, or corrupted)
```

**Why no session_id (the design call).** A previous draft added a 4-byte `session_id` to let B index directly into its key table. We removed it because:

- **MAC verify IS the key-selection check.** Poly1305-truncated-4B verify is ~2 µs/byte on Cortex-M0. For a 100-byte payload: ~200 µs per peer. For 100 peers: 20 ms worst-case, ~100 µs typical (LRU sorted, first-match average). And this cost is paid **only at the destination** — forwarders route by `dst` and never trial-decrypt.
- **No session_id is strictly more private.** A stable per-(A,B) tag on every frame gives passive observers a tracking handle. Without it, ciphertext is fully opaque — no linkability surface at the wire level. The 2-byte `ctr` we DO carry is per-peer state that varies every message; observers can see "two messages on this counter sequence" but not link sequences across peer pairs.
- **Saves 4 bytes per DATA frame.** Combined with origin removal under §9 T2 and the 2-byte counter, net wire cost is +3 B over today's plaintext for confidentiality + authenticity + originator privacy.

This matches the MeshCore approach more closely (no explicit per-pair tag on every frame; no clock requirement).

**Wire-format diff vs current plaintext DATA.**

| Field | Today | Proposed (§8.1 + §9 T2) |
|---|---|---|
| `'D'` tag | 1 B | 1 B |
| `origin` | 1 B | **removed** (privacy §9) |
| `src` | 1 B | 1 B |
| `dst` | 1 B | 1 B |
| `next` | 1 B | 1 B |
| `msg_id` + reserved | 1 B | 1 B |
| `origin_seq` (plaintext) | 2 B | **replaced by `ctr`** (2 B, same wire footprint, does crypto duty too) |
| user_text | n B | n B (encrypted) |
| MAC | — | **+4 B** |
| **header total** | 6 B + 2 B origin_seq | 5 B + 2 B ctr + 4 B MAC |

**Net per-message airtime cost: +3 bytes** for confidentiality + authenticity + originator privacy. (5 B header replaces 6 B; counter occupies the same 2 B that origin_seq did; +4 B MAC is the only true addition.)

**Identity card frame (`'I'`) sketch.**
```
'I' | subject_id(1B) | subject_pubkey(32B) | timestamp(4B) | subject_sig(16B truncated)
~ 54 bytes
```
Pull-based only (response to `'?'` query); NEVER pushed in BCN — would bloat. Receivers verify the embedded signature against the subject's known long-term key. Chicken-and-egg solved at the QR-code first-contact step.

**Storage cost per node.**
```
self: 32 B identity_private + 32 B identity_public                        = 64 B
per peer: 32 B peer_pubkey + 32 B session_key
          + 2 B peer_send_counter + 2 B last_seen_counter (both NV)
          + ~30 B bookkeeping                                              ≈ 98 B
```
100 peers → ~9.8 KB. Fits in typical microcontroller flash. The two 2-byte counters MUST be in NV storage (not just RAM) — counter persistence across power-off is what makes the protocol robust without a clock.

**Per-message compute cost.** ChaCha20+Poly1305: ~2 µs/byte on M0/M4 → ~0.5 ms for a 200-byte frame. Negligible vs LoRa airtime (50 ms). X25519 ECDH happens **once per peer ever**, not per-message.

**What this proposal deliberately does NOT do.**
- No per-message public-key crypto. ECDH is first-contact only.
- No identity-card flooding. `'I'` is pull-only via `'?'` query.
- No 128-bit MAC. 32 bits is LoRa-appropriate (~3 years to forge one frame at PHY rate).
- No explicit nonce on wire. Derived from the 2-byte counter + dst + msg_id.
- **No clock or time-sync dependency.** Counter-based nonce uniqueness is what makes this possible — matches MeshCore's operational model where nodes work fine without time set.
- **No forward secrecy** (deliberately — see honest limits below).
- No long-term identity rotation. Pubkey IS identity; rotating pubkeys is a separate (more complex) story — out of scope here, can be layered on later.

**Honest limits.**
- DM-only. Multi-recipient channels (§6) need a separate group-key story.
- Trust on first contact: stronger trust models (mutual attestation, web-of-trust) are app-layer.
- Pubkey leak = identity exposure. Same property as Signal/WhatsApp. Mitigated by user-side device-security practices.
- **No forward secrecy.** `session_key` is reused for the lifetime of the (A, B) relationship (until counter wrap or explicit re-key). If A's device is compromised and `session_key` is extracted, an attacker who archived past A↔B ciphertext can decrypt it. **Mitigation reasoning:** handheld LoRa devices store the plaintext message archive locally anyway — compromise of the device gives the attacker the archive directly, so daily-rotated forward secrecy provides marginal real-world benefit at the cost of requiring time-sync (which we don't want). If a specific deployment NEEDS forward secrecy, layer in an epoch counter from NTP/GPS/peer-gossip time — but it's not the base proposal.
- Counter wrap at 65,536 messages → forced re-key via fresh X25519 ECDH against current pubkeys. At 10 msg/day per peer, that's ~18 years; longer than the device's hardware lifetime. Not a practical concern.
- Counter persistence: requires NV storage at both sender and receiver. Flash write-cycle budget (~100k cycles on typical embedded flash) is ample for typical traffic.
- Trial-MAC at destination: O(N) in peer count. For 100 peers ~20 ms worst-case, ~100 µs typical (LRU). For 1000+ peers consider a small bloom-filter pre-check keyed on `truncate(HMAC(session_key, ctr || dst))` — adds ~2 B/frame but reduces verification to ~O(1). Not needed for typical handset use (~tens of contacts).

**Cross-references.** §9 T2 (origin removal — §8.1 makes it possible by using MAC verify itself as the implicit originator-identification step, no on-wire identifier needed), §5 E2E ACK privacy-compatible variant (reverse-path soft state ties back to msg_id+dst, which remain visible — composes cleanly with encrypted payload), §1 anti-spam behavioral variant (count-based fingerprinting still works because RTS/CTS counts don't depend on payload content).

---

## 9. Privacy / originator anonymity (T2)

> **See also §7.1** for the concrete DATA frame realizing T2 in combination with hierarchical routing and crypto.

**Problem.** Every RTS and DATA frame today carries `origin` as a
plaintext 1-byte field at byte 1 (see `pack_rts`, `pack_data` in
`scenarios/dv_dual_sf.lua`). BCN exposes `src` at byte 2. Any node in
radio range can build a transcript of who-talked-to-whom. Even with
§8 cryptography (encrypted payload), the metadata leaks identity and
traffic patterns to passive observers and to forwarders.

**What we want.** MeshCore-equivalent originator anonymity: forwarders
and observers see frames moving through the network but can't link
them to a specific origin without the destination's private key.
Three privacy tiers exist conceptually:

| Tier | What | Cost | Gives | Doesn't give |
|---|---|---|---|---|
| T1 — payload-only encryption (Meshtastic-equivalent) | ChaCha20-Poly1305 origin↔dst with PSK; headers plaintext | ~28 B/frame | Message-content confidentiality | Origin metadata public; traffic analysis trivial |
| **T2 — origin moved into encrypted payload** | Strip origin from RTS/DATA headers; place inside encrypted blob. Forwarders see only (prev_hop, dst, next_hop, msg_id). | T1 cost + small refactor (dedup re-keyed) | Origin invisible to passive observers AND forwarders. MeshCore-style. | BCN src still exposes node membership; timing patterns still leak (alice's daily rhythm visible) |
| T3 — onion-routed source paths | Origin computes full path; encrypts each hop's instructions per-hop key | ~20-30 B header per hop → 5-hop = 100-150 B header. Breaks LoRa frame budget. Requires global topology at origin. | Full origin anonymity from forwarders + observers | Collapses our current distance-vector model entirely |

**Constraints.**
- LoRa frame budget. T3 doesn't fit — period.
- Routing must keep working without forwarders knowing origin. Today,
  forwarders use origin only for the `forward_queued` event metadata —
  it's not actually load-bearing. Dedup re-keys cleanly to
  `(prev_hop, msg_id)` (the `last_acked_from` machinery is already
  there).
- Must compose with §1 anti-spam (see analysis there — behavioral
  fingerprint preserves anti-spam under T2 without reading origin).
- Cover-traffic to defeat timing analysis is incompatible with our
  duty cycle. Not achievable within this protocol family.

**Possible direction — T2 (not committed, recommended as the
realistic ceiling).**
- Drop `origin` from RTS byte 1 and DATA byte 1; recover those bytes
  (RTS goes 8 B → 7 B, DATA header 6 B → 5 B — small airtime
  win as bonus).
- Encrypt user payload with ChaCha20-Poly1305; place
  `(origin, origin_seq, user_text)` in the encrypted blob.
- Re-key forwarder dedup to `(prev_hop, msg_id)` instead of
  `(origin, msg_id)`. Mostly already there via `last_acked_from`.
- Q frame: replace `src` with an ephemeral cookie that the receiver
  returns in its triggered BCN (requester matches without persistent
  identity).
- E2E ACK (§5): use **reverse-path soft state at forwarders** so the
  return `E` frame walks back along the original path without naming
  the origin (see §5 privacy-compatible variant for the full
  mechanism).

**What T2 structurally can't fix.**
- BCN exposes node existence. Every node BCNs its own `src`. Anyone
  in range knows you exist on this network. Pseudonym rotation could
  mask long-term identity but the act of advertising "I'm reachable
  for routes" can't be hidden if routing stays passive.
  Anonymity-of-existence is a different protocol entirely
  (gossip-only with no advertising — incompatible with our routing).
- Traffic-flow timing leaks. If alice's BCNs go quiet at the moment a
  DATA flight starts hopping toward bob, an observer infers alice→bob
  without ever reading the origin field. Mitigation requires cover
  traffic, which duty cycle won't afford.

**Open questions.**
- Pseudonym rotation cadence for BCN `src` (daily? hourly? per-
  cluster-discovery cycle?). Too short → routing tables can't follow
  the rotation. Too long → static identifier defeats the rotation
  goal.
- How does T2 compose with §6 (channels) and §7 (multi-network)?
  Channel subscription, network bridging — both currently rely on
  identity. Need explicit design for each.
- Should the routing-table dedup re-keying to `(prev_hop, msg_id)`
  apply universally, or only when T2 is active per a config flag?

**Cross-references.** §1 anti-spam (behavioral fingerprint variant
preserves rate-limiting under T2), §5 E2E ACK (return-cookie design),
§8 cryptography (T2 is one layer of §8's confidentiality story).

---

## 10. Wire-format refactor v2 — 4-bit command + flag nibble (proposal)

**Status — proposal.** Supersedes the §7.0 LOCKED 2026-05-12 layout.
Backwards-incompatible; requires a coordinated v2 protocol bump (no
mixed-version coexistence is possible — see §10.5 Migration).

**Goal.** Reshape byte 0 of every frame so it always carries
`cmd(4 hi) | flag_nibble(4 lo)` — uniform across primary AND extended
commands. When `cmd == 0xF` (extension escape), byte 0's flag nibble
is still flags (`leaf_id` for J family, per the consistency rule), and
the 8-bit sub-command code lives in **byte 1**. This:

1. Gives a single byte that tells the receiver frame type **and** the
   most important flag for that frame (e.g., `leaf_id` for
   layer-aware frames, `reason` for NACK, `ctr_lo` for matching
   stateful responses).
2. Adds 256 extra command codes via the escape (8-bit sub-code in
   byte 1) for future protocol growth. The §2a `J` join family fits
   here cleanly without burning a primary command slot, with room
   for hundreds of future control frames before the second-level
   escape (`0xFF`) is ever needed.
3. Tidies per-frame flag layout that today is scattered across
   bytes 1-3 in inconsistent positions per frame.
4. Saves 1 byte per RTS (8 → 7 B) — meaningful because RTS is the
   most-emitted frame in the system. Other frames mostly stay the
   same size; the saving is in clarity and extension headroom, not
   raw bytes.

**Consistency rule.** `leaf_id` is always in the **low nibble** of
whichever byte holds it. Single-byte layer-filter dispatch wherever
`leaf_id` exists.

### 10.1 Command code allocation

| Code | Tag | Frame | Status |
|---|---|---|---|
| `0x0` | B | Beacon | implemented |
| `0x1` | R | RTS | implemented |
| `0x2` | C | CTS | implemented |
| `0x3` | D | DATA | implemented |
| `0x4` | K | ACK | implemented |
| `0x5` | N | NACK | implemented |
| `0x6` | Q | Query | implemented |
| `0x7` – `0xE` | — | reserved (8 free primary slots) | future |
| `0xF` | EXT | extended command escape (8-bit sub-code in byte 1; byte 0 low nibble remains a flag nibble) | new |

### 10.2 Extended sub-command allocation (byte 1 when byte 0 high nibble = `0xF`)

Status note: this EXT/sub-code allocation is retained as future extension
space. The implemented join first slice does **not** use EXT; it uses literal
tag byte `'J'` plus an opcode in byte 1, as described in §2a and
`docs/PROTOCOL.md`.

When the cmd nibble is `0xF`, the **next byte** (byte 1) carries the
8-bit sub-command code. Byte 0's low nibble is NOT the sub-code —
it remains a flag nibble like any primary command, and for layer-aware
J frames it carries `leaf_id` (low nibble, per the §10 consistency
rule). This makes the byte-0 layout fully uniform across primary and
extended commands.

| Sub-code | Name | Status |
|---|---|---|
| `0x00` – `0xFE` | reserved | future EXT users; join does not consume this space |
| `0xFF` | second-level escape | reserved (would enable a 16-bit sub-code space via a third byte if 256 ever runs out) |

**Cost.** Extended commands pay +1 B for the sub-code byte vs a
primary command. J frames are rare events (one per node-boot/rejoin),
so the byte is amortized to near-zero per-flight overhead.

### 10.3 Per-frame layouts — deferred/superseded proposal

**Status.** This section is historical design material for a future
command-nibble compaction. It is **not** the implemented wire format. The
current implementation still uses literal ASCII tag bytes (`'B'`, `'R'`,
`'C'`, ...), and the authoritative current frame layouts are in
`docs/PROTOCOL.md` plus §7.0 above. In particular, implemented BCN uses an
8-byte fixed header with mandatory `key_hash32`; the 4-byte "New" BCN layout
below was never adopted.

#### B — Beacon

Current implemented reality:
```
byte 0: 'B'
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
byte 2: src(8)
byte 3: has_seen_bitmap(1) | has_ext(1) | n_entries(6)
bytes 4..7: key_hash32(32 LE)
[has_schedule] layer_count(1) + 4×L schedule records
n_entries × 3 B route entries
[has_seen_bitmap] 32 B bitmap
[has_ext] ext_len(1) + TLVs
```

Historical pre-identity layout:
```
byte 0: 'B' (0x42)
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
byte 2: src(8)
byte 3: seen_bm(1) | has_ext(1) | n_entries(6)
[has_schedule] layer_count(1) + 4×L schedule records
n_entries × 3 B route entries
[seen_bm] 32 B bitmap
[has_ext] ext_len(1) + TLVs
```

Deferred nibble-command proposal (not implemented):
```
byte 0: cmd=0x0(4 hi) | leaf_id(4 lo)
byte 1: src(8)
byte 2: has_schedule(1) | self_gateway(1) | is_mobile(1)
        | has_seen_bm(1) | has_ext(1) | rsv(3)
byte 3: n_entries(7 hi) | rsv(1 lo)
[has_schedule] layer_count(1) + 4×L schedule records
n_entries × 3 B route entries
[has_seen_bm] 32 B bitmap
[has_ext] ext_len(1) + TLVs
```

The deferred proposal would make layer filter 1-byte and recover some flag
bits, but it is parked until current gateway/JOIN behavior stabilizes.

#### R — RTS

Old (8 B in-leaf):
```
byte 0: 'R' (0x52)
byte 1: src(8)
byte 2: next(8)
byte 3: addr_len(3 hi) | rsv(1) | leaf_id(4 lo)
byte 4: dst(8)  [longer when addr_len>0]
byte 5: ctr_lo(4 hi) | rsv(4 lo)
byte 6: sf_bitmap(8)
byte 7: payload_len(8)
```

New (**7 B** in-leaf):
```
byte 0: cmd=0x1(4 hi) | leaf_id(4 lo)
byte 1: src(8)
byte 2: next(8)
byte 3: ctr_lo(4 hi) | addr_len(3) | rsv(1 lo)
byte 4: dst(8)  [longer when addr_len>0]
byte 5: sf_bitmap(8)
byte 6: payload_len(8)
```

Δ: **−1 B**. Layer filter is 1-byte. Each hierarchy level still costs +1 B.

#### C — CTS

Old (3 B):
```
byte 0: 'C' (0x43)
byte 1: ctr_lo(4 hi) | (sf-5)(3) | already_received(1 lo)
byte 2: to(8)
```

New (3 B):
```
byte 0: cmd=0x2(4 hi) | ctr_lo(4 lo)
byte 1: (sf-5)(3 hi) | already_received(1) | rsv(4 lo)
byte 2: to(8)
```

Δ: 0 B. `ctr_lo` in cmd-byte for fast match against `pending_tx.ctr_lo`.
Byte 1 has 4 spare bits.

#### D — DATA

Old (12 + n B in-leaf, addr_len=0):
```
byte 0: 'D' (0x44)
byte 1: addr_len(3) | rsv(1) | E2E_ACK_REQ(1) | E2E_IS_ACK(1) | IS_MULTICAST(1) | rsv(1)
byte 2: next(8)
byte 3: dst(8)  [longer when addr_len>0]
byte 4: hops_remaining(4) | committed_hops(4)
byte 5: prev_fwd_rt_hops(8)
bytes 6-7: ctr(16, LE)
bytes 8..(7+n): ciphertext(n)
bytes (8+n)..(11+n): MAC(4)
```

New (12 + n B in-leaf):
```
byte 0: cmd=0x3(4 hi) | addr_len(3) | rsv(1 lo)
byte 1: E2E_ACK_REQ(1) | E2E_IS_ACK(1) | IS_MULTICAST(1) | rsv(5)
byte 2: next(8)
byte 3: dst(8)  [longer when addr_len>0]
byte 4: hops_remaining(4) | committed_hops(4)
byte 5: prev_fwd_rt_hops(8)
bytes 6-7: ctr(16, LE)
bytes 8..(7+n): ciphertext(n)
bytes (8+n)..(11+n): MAC(4)
```

Δ: 0 B. `addr_len` moves to cmd-byte flags (parser-dispatch first byte);
byte 1 still holds the semantic flags with 5 spare bits.

#### K — ACK

Old (3 B):
```
byte 0: 'K' (0x4B)
byte 1: ctr_lo(4 hi) | budget_hint(2) | snr_bucket(2 lo)
byte 2: to(8)
```

New (3 B):
```
byte 0: cmd=0x4(4 hi) | ctr_lo(4 lo)
byte 1: budget_hint(2 hi) | snr_bucket(2) | rsv(4 lo)
byte 2: to(8)
```

Δ: 0 B. `ctr_lo` in cmd-byte (same reasoning as CTS). 4 reserved bits in byte 1.

#### N — NACK

Old (4 B):
```
byte 0: 'N' (0x4E)
byte 1: reason(4 hi) | ctr_lo(4 lo)
byte 2: payload(8)
byte 3: to(8)
```

New (4 B):
```
byte 0: cmd=0x5(4 hi) | reason(4 lo)
byte 1: ctr_lo(4 hi) | rsv(4 lo)
byte 2: payload(8)
byte 3: to(8)
```

Δ: 0 B. `reason` in cmd-byte enables first-byte reason-dispatch (BUDGET vs
BUSY_RX vs HOP_BUDGET vs LOOP_DUP branch immediately).

#### Q — Query

Old (4 B):
```
byte 0: 'Q' (0x51)
byte 1: src(8)
byte 2: dest(8)
byte 3: leaf_id(4 hi) | opcode(2) | mobile(1) | rsv(1 lo)
```

New (4 B):
```
byte 0: cmd=0x6(4 hi) | leaf_id(4 lo)
byte 1: src(8)
byte 2: dest(8)
byte 3: opcode(2 hi) | mobile(1) | rsv(5 lo)
```

Δ: 0 B. Layer filter is 1-byte. 5 reserved bits in byte 3.

#### J family

Superseded by the implemented tag-byte `J` family in §2a and
`docs/PROTOCOL.md`.

Earlier drafts placed join under the future `EXT` escape with sub-codes
`J_DISCOVER/J_CLAIM/J_DENY/J_CONFLICT`. The implemented first slice instead
uses byte 0 as literal tag `'J'` and byte 1 as:

```text
leaf_id(4 hi) | gateway_capable(1) | is_mobile(1) | opcode(2 lo)
```

Implemented opcodes:

- `0 = J_DISCOVER` (6 B)
- `1 = J_CLAIM` (11 B)
- `2 = J_DENY` (15 B)
- `3 = J_OFFER` (8 B)

`J_CONFLICT` remains a future post-adoption conflict concept but has no
on-wire opcode in the current protocol.

### 10.4 Net wire-cost summary

| Frame | Old size | New size | Δ |
|---|---|---|---|
| B header | 4 + var | 4 + var | 0 |
| R (in-leaf, addr_len=0) | 8 | **7** | **−1** |
| R (addr_len=1) | 9 | 8 | −1 |
| C | 3 | 3 | 0 |
| D (in-leaf) | 12 + n | 12 + n | 0 |
| K | 3 | 3 | 0 |
| N | 4 | 4 | 0 |
| Q | 4 | 4 | 0 |
| J_DISCOVER | n/a | 6 | implemented tag-byte J |
| J_OFFER | n/a | 8 | implemented tag-byte J |
| J_CLAIM | n/a | 11 | implemented tag-byte J |
| J_DENY | n/a | 15 | implemented tag-byte J |
| J_CONFLICT | n/a | n/a | future concept, no current opcode |

Per-flight typical RTS savings: a 1-RTS clean send saves 1 B; a failed
3-retry × 3-alt cascade saves up to 9 B of channel air per flight.
Aggregate at dense-mesh scale where RTSes dominate routing-SF airtime.

### 10.5 Migration

This is a backwards-incompatible wire change — there is no clean
mixed-version mode. Byte 0 = `0x42` (old `'B'`) parses as v2
`cmd=0x4` (= K, ACK) with garbage flag bits and a foreign body; every
old frame would be misparsed as a different frame type.

Three viable paths:

1. **Big-bang flag day.** Coordinate the upgrade across the whole
   deployment. Easiest in single-operator meshes.
2. **Skip this refactor entirely.** ASCII-letter tags work today;
   the 1 B/RTS saving and clean-extension benefits may not justify
   the disruption. Tracked here as a documented option, not lost.
3. **Bundle with another major wire bump.** The §2a join landing
   AND §8.1 crypto integration both already require coordinated
   upgrades. Bundling the byte-0 refactor with either spreads the
   coordination cost.

**Recommendation: option 3.** Defer until either §2a or §8.1 is
ready to land, then refactor in one coordinated bump. Spreading the
disruption across one v2 break is better than two.

### 10.6 Open questions

- Should the J_CLAIM `nonce` be 8 B (per typical crypto-nonce width)
  or 4 B (compact)? Decided at §8.1 lock-in.
- Is it worth allocating one of the 8 reserved primary command codes
  (`0x7`–`0xE`) to a future *identity card* frame, or should that
  live behind the EXT escape like J? Identity-card use is rare
  (during join + on demand); EXT is appropriate.
- More aggressive optimization for BCN: eliminate `n_entries`
  entirely by reordering optional sections to come BEFORE route
  entries, so the entry count is derivable from frame length /
  3. Would save another 1 B per BCN at the cost of reordering
  wire fields. Tracked as a follow-up.

---

## 11. Pre-port hardening (Lua → C++ on Cortex-M)

The Lua script is the **firmware model**. Items in this section don't
add protocol features — they tighten the model so the C++ port doesn't
hit MCU-specific walls (flash/RAM budget, fixed-point arithmetic,
deterministic RNG). Each item below is independently shippable.

### 11.1 Bounded-state caps + cap-hit telemetry (IMPLEMENTED 2026-05-19)

Every state-table that scales with mesh size, traffic, or churn now has
an explicit `cap_*` knob (defaults sized for ~50-node mesh). When the
cap is reached the offending insert is **refused** and a `table_cap_hit`
event fires with `{table, size, cap, action, key|origin/dst/ctr}`. This
surfaces pathological growth as run telemetry instead of an MCU OOM.

Capped tables (default in parentheses):

- `q_queried` (128) — recently-queried route/hash destinations
- `q_responded_to` (128) — distinct Q-source keys we've answered
- `seen_origins` (256) — `(origin,dst,ctr)` dedup; existing TTL prune
  keeps it well below cap in healthy traffic
- `deferred_sends` (32) — sends waiting for a route
- `gateway_deferred_handoffs` (32) — cross-layer envelopes held for
  binding resolution
- `id_bind` (256) — `(node_id → key_hash32)` bindings; `id_bind_ttl_ms`
  ages stale entries out separately

Skipped (already structurally bounded): `tx_stash` (keyed by static
`RETRY_ELIGIBLE` label set), `gateway_layer_*` (bounded by configured
layer count), per-peer `peer_*`/`snr_ewma_*` maps (bounded by neighbor
count and naturally pruned), `rt` (bounded by destinations).

Test coverage: `test/t61_table_cap_hit_q_queried.json` (cap=2, three
distinct destinations, refuses the third). Healthy runs (s09/s10/s11)
emit zero `table_cap_hit` events at defaults.

### 11.2 Fixed-point dB conversion (IMPLEMENTED 2026-05-19)

All internal SNR/RSSI/score/EWMA storage and arithmetic is `int16_t`
Q4 — 1 unit = 1/16 dB, range -2048.0 .. +2047.9375 dB. The C++ port
maps this directly to `int16_t` with no FPU on Cortex-M.

- **Helpers** (`Q4_SCALE = 16`): `db_to_q4`, `q4_to_db`, `q4_ewma`.
- **Storage in Q4**: `snr_ewma_in[id]`, `snr_ewma_out[id]`, `c.score`
  on route candidates, beacon `e.score`, `SF_DEMOD_THRESHOLD[sf]`,
  `TIER_SCORE_PENALTY_BY_ALTS_DB[tier][alts]`, `self.sf_margin_q4`,
  `self.routing_snr_floor_q4`, `self.snr_ewma_alpha_q4`,
  `self.route_snr_conservatism_q4`, `self.peer_{suspect,silent,dead}_penalty_q4`.
- **Wire-bucket helpers** (`bucket_of_snr_4b/2b`, `snr_of_bucket_4b/2b`)
  operate in Q4; the wire bucket index is unchanged.
- **I/O boundaries**: `meta.snr` (runtime float dB) → `db_to_q4` at
  ingress; all telemetry events / log messages convert back via
  `q4_to_db` so NDJSON stays human-readable dB.
- **PROTOCOL constants store Q4 directly** (e.g.
  `peer_dead_penalty_q4 = 1280` = 80.0 dB × 16). The `_db` config
  knobs were removed in §11 step C (audit) — these values are no
  longer scenario-tunable; see `docs/CONFIG_AUDIT.md`.

Quantization noise: alpha = 0.3 → Q4 5 (=0.3125), a 4% relative
error in EWMA weight. Penalty / threshold constants are integer dB,
so they convert exactly.

Regression: all 16 t46-t61 tests pass; s09/s10/s11 sim-end cleanly
with no observable behavior change beyond ≤1/16 dB rounding.

### 11.3 RNG-seed contract (IMPLEMENTED 2026-05-19, Lua side)

**Lua side — done.** Audit confirms 0 `math.random` calls, 0
`math.randomseed`, 0 `os.time` / `os.clock`. Every random decision
flows through `self:rand(lo, hi)` (20 callsites), provided by the
runtime as a draw from a simulation-wide `std::mt19937` PRNG seeded
by `simulation.seed`. The contract is documented in a comment block
at the top of `scenarios/dv_dual_sf.lua` (just above the PROTOCOL
table) with a per-callsite intent audit so the C++ port maintainer
has a checklist for one-to-one stream alignment.

**Pending — C++ port side.** The port must:

- Use `std::mt19937` seeded by the same `simulation.seed`.
- Use `std::uniform_int_distribution<int>` with bounds `(lo, hi - 1)`
  to match the Lua model's `[lo, hi)` semantics.
- Issue draws in the same call-site order. The runtime steps events
  deterministically, so this falls out of a one-to-one state-machine
  port — but is brittle if event ordering shifts.

**Related determinism gotcha — iteration order.** The Lua model uses
`pairs()` over `self.rt`, `self.id_bind`, `self.gateway_remote_bind`,
`self.seen_origins`, `self.pending_e2e`, etc. in ~17 sites. Lua's
`pairs()` order is implementation-defined but deterministic for a
fixed (Lua version, table contents) — it's NOT portable across
implementations. The C++ port must use ordered containers
(`std::map`) OR sort keys before iterating wherever the iteration
has observable effects (event emission order, decision sequencing).
This is a port-time concern; the Lua side does not need changes.

### 11.4 Cryptography

Tracked in §8. Pre-port classification: the wire format already reserves
nonce/AEAD-tag bytes; what's missing is the keying material and the
state-machine integration. Multi-week effort; tackle after 11.2/11.3
land so the SNR/RNG plumbing is stable.

---

## Not on this list, but worth flagging

These came up in analysis but are smaller or already partly addressed:

- **Multi-channel / sub-band capacity** (8 sub-bands × 1% duty each
  = 8× capacity in real EU868). Out of scope for the script — needs
  runtime + scenario format changes.
- **Asymmetric K per hop class** (K=3 for 1-hop direct, K=5 for
  multi-hop). The diversity analysis (section 16) shows the cap is
  binding only for the 13% multi-cycle group; conditional K is a
  cheap-effort follow-up if that group becomes the bottleneck.
- **BCN payload further-shrinking** (faster SF + smaller per-entry
  encoding). Most of the easy wins are taken (SF flip, bit-packed
  entries). Further gains require either dropping rotation entries or
  going to SF7 for in-cluster, which has its own trade-offs.
