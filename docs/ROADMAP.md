# dv_dual_sf protocol roadmap

Topics flagged during analysis sessions that we want to address but aren't
the immediate next step. Each entry is short on purpose — capture the
shape of the problem, not the solution. Linked-to-from
`scenarios/dv_dual_sf.lua` and `tools/analyze.py` where relevant.

---

## 1. Anti-spam: rate-limit at the 1st-hop neighbour (IMPLEMENTED)

**Status — IMPLEMENTED** as silent-drop + originator self-monitoring.
See `scenarios/dv_dual_sf.lua` header doc block "Anti-spam: 1st-hop
statistical rate-limit" for full design, and `test/t33_anti_spam_rate_limit.json`
for the verification scenario. Mechanism summary:

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

## 2. Mobile nodes (source/destination only)

**Problem.** Today every node is a potential forwarder. Mobile nodes
(handhelds moving between coverage zones) cause routing-table churn:
their direct routes age in and out as they move, and if they ALSO
forward, every other node has to track moving topology in real time.
Routing-table thrash is the worst failure mode we've seen on s04 (60
min, 138 nodes — but compounded by mobility).

**What we want.** A `mobile` flag on nodes that:
- Excludes the node from forwarding (it appears as src/dst only).
- Marks routes through them in neighbours' rt[] so the routing layer
  knows not to route OTHER traffic via a mobile node.
- Triggers a beacon when the mobile node detects its neighbour set has
  shifted (so neighbours' rt entries don't lag the actual topology).

**Constraints.**
- Mobile flag must be on the wire (or derived from on-wire signal) so
  neighbours can mark routes accordingly.
- Mobile beacon-on-change must not become a beacon storm (deduplicate /
  rate-limit).
- Must compose with rt_aging_ttl_neighbor_ms — mobile direct entries
  probably need shorter neighbor TTL.

**Possible direction (not committed).**
- Per-node `is_mobile` config flag (defaults to false).
- BCN frame gains an `is_mobile` bit (currently 3 reserved bits left
  in nid_byte after the budget-tier work).
- Mobile nodes silently drop inbound RTS where `origin != self.id` and
  `dst != self.id` (= forward request) — same pattern as the
  pending_tx silent drop.
- rt_merge: when receiving a beacon with `is_mobile=true`, set
  `entry.candidates[i].is_mobile_next_hop = true`.
- route_strictly_better: if a candidate's `next_hop` is marked mobile
  AND the route's destination is NOT that mobile node, apply a
  heavy score penalty (effectively "don't relay through mobiles").
- Mobile node detects neighbour-set change by tracking its own
  `rt[]` direct entries: when a 1-hop entry ages out OR a new one is
  added, schedule a triggered beacon (with the existing
  beacon_trigger_jitter machinery).

**Open questions.**
- Auto-detect mobility (frequent neighbour changes → flag as mobile)
  vs. explicit config flag? Explicit is simpler.
- What's the right neighbour-change threshold for the triggered
  beacon? One change every N minutes vs. instantaneous?
- Should mobile nodes ALSO downgrade their own BCN cadence (they're
  burning battery)?

---

## 3. Public channel (broadcast alternative)

**Problem.** Traditional mesh "public channel" = flood. Every message
reaches every node. In a dense network at ~1% duty cycle, a single
flood saturates the entire network's airtime budget for tens of
seconds. Pure flood is not a serious option at the densities we
simulate.

**What we want.** A broadcast-style capability for "this message is
intended for many recipients" use cases (chat-rooms, status broadcasts,
alerts) that does NOT consume the entire network's airtime budget.

**Constraints.**
- Must reach interested receivers (subscribers to the channel /
  topic).
- Must NOT consume disproportionate airtime — duty cycle is hard.
- Must respect per-node duty cycle.
- No assumption of central coordinator.

**Possible directions (none committed; all viable).**

| Approach | Idea | Trade-off |
|---|---|---|
| **Hop-limited controlled flood** | TTL on the broadcast frame; nodes suppress re-broadcast probabilistically | Simple; bounds but doesn't eliminate the flood cost |
| **Topic-based subscription** | Subscribers advertise interest in topics via beacon. Originators send only along paths to known subscribers. | Best scaling; adds substantial protocol surface (topic ID, subscription state, sub-tree construction) |
| **Recipient-list multicast** | Originator picks N specific destinations and sends N unicasts in parallel. No actual broadcast on the wire. | Trivial; degrades to flood when N is large |
| **Shared-tree multicast** | Build a per-topic spanning tree; broadcast follows tree edges only. | Mid-complexity; tree maintenance overhead |

**Recommendation.** Avoid pure flood. Lean toward topic-based with
selective forwarding for the chat-room use case; recipient-list for
small-N (≤ 5) status broadcasts.

**Open questions.**
- Where does subscription state live? Bit-vector in beacon (limited
  topic space), or separate subscription frame?
- Forwarder behaviour when topic state is stale: forward conservatively
  or drop?
- Delivery guarantees: best-effort with no ACKs (cheap), or per-subscriber
  ACK (expensive at scale)?
- How does this compose with the budget NACK?

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

**Observation.** A node's BCN entries cluster around a small set of dominant next-hops. In a star topology, nearly all entries share `next_hop = gateway`. In typical mesh, 49 entries are usually distributed across 3-5 distinct next-hops. The current 3 B/entry encoding repeats the 8-bit `next_hop` field for every entry — a clear redundancy.

**Wire format.** Adds a `compressed` flag in byte 1's reserved low nibble. Flag=0 keeps existing 3 B/entry layout (no inflation when compression doesn't help). Flag=1 switches to grouped encoding:

```
Header (size unchanged, 4 B):
byte 0: 'B'
byte 1: network_id (4 hi) | flag_compressed (1) | reserved (3 lo)
byte 2: src (8)
byte 3: n (8)            -- semantic entry count, regardless of encoding

flag_compressed = 1 body — sequence of groups, each:
  byte g+0: next_hop (8)
  byte g+1: group_count (8)            -- entries sharing this next_hop
  bytes g+2..: group_count × 2 bytes   -- per entry: dest(8) | score_bucket(4 hi) | hops(4 lo)
```

**Encoder logic.**
1. Build the entries list dirty-first (existing differential semantics, capped at `max_entries`).
2. Sort the SELECTED entries by `next_hop` — preserves dirty-first selection; within the selection, sorting maximizes group runs.
3. Compute uncompressed size (`4 + 3n`) and compressed size (`4 + 2g + 2n`, where g = distinct next_hops).
4. Emit whichever is smaller; set `flag_compressed` accordingly. Break-even: compressed wins when `g < n/2` (i.e., average group size > 2).

**Decoder logic.** `parse_beacon` reads `flag_compressed` from byte 1. Flag=0 → existing 3-byte loop. Flag=1 → walk groups, expanding each to (dest, group's next_hop, score, hops). Receivers downstream of `parse_beacon` (`rt_merge`, route scoring) see no difference.

**Savings (49-entry BCN, default cap).**

| Distinct next_hops | Uncompressed | Compressed | Saving |
|---|---|---|---|
| 1 (star/gateway) | 151 B | 4 + 2 + 98 = **104 B** | −31% |
| 3 (typical mesh) | 151 B | 4 + 6 + 98 = **108 B** | −28% |
| 8 (well-connected) | 151 B | 4 + 16 + 98 = **118 B** | −22% |
| 25 (sparse uniform) | 151 B | 4 + 50 + 98 = 152 B | flag=0, **0%** |

Worst-case auto-detected and flagged uncompressed (no inflation cost, only the 1-byte tax of always carrying the flag — and that's a free reused reserved bit).

**Open design question.** What to do with the saved bytes:
- (A) **Shrink BCN airtime**: keep `beacon_max_entries=49`; compressed BCN goes 151 B → ~110 B average. Direct ~27% airtime reduction. Simplest.
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

## 6. On-demand (ad-hoc) channels

(Complements §3 — public channel covers always-on system-wide topics; this section covers ad-hoc dynamic subscriptions.)

**Problem.** Real-world use cases need temporary group communication: a chat thread that lasts a few hours, an emergency-alert channel that activates during incidents, a coordination channel for a specific event. Pre-configuring all possible channels into every node is impractical and burns memory; we need a way to spin up a channel dynamically and tear it down when done.

**What we want.** A small group of nodes can subscribe to an ad-hoc channel by ID, exchange messages within the channel, and disband by letting state age out — without central coordinator or pre-distributed configuration.

**Constraints.**
- Channel-ID format must be collision-resistant (collision = unrelated traffic crosses).
- Subscription state must have a TTL — abandoned channels can't accumulate forever.
- No flooding: a message to channel X should reach only subscribers, not the whole mesh.

**Possible direction (not committed).**
- **Channel ID** = 32-bit random (24-bit topic + 8-bit creator id) — collision-resistant under reasonable load.
- **Subscribe frame** `S` — node announces "I subscribe to channel X". Neighbours add `sub_table[X] += {self.id}` with TTL (e.g., 5 min, refreshed by periodic re-subscribe).
- **Send-to-channel**: originator emits `T` (topic-data) frame addressed to channel X. Forwarders consult their `sub_table[X]` — if ≥ 1 subscribed neighbour, forward; else drop. Multiple subscribers → forwarder unicasts to each (no broadcast at wire layer).
- **Unsubscribe**: explicit leave frame, OR let TTL handle it.

**Open questions.**
- Memory bound: how many simultaneous channels can a node carry in `sub_table`? Probably 16-32 reasonable for handheld hardware.
- Channel discovery: how does a new node find an active channel? In-band advertisement (channels in beacon?) or external bootstrap (QR code, app-layer)?
- Per-channel rate limits to prevent a single channel from monopolising airtime?
- How does this interact with §1 anti-spam? Probably channel-aware: per-(origin, channel) budget instead of just per-origin.

---

## 7. Multi-network communication

**Problem.** `network_id` is a 4-bit field — nodes drop packets with foreign network IDs at the routing layer. There's no way for nodes on network A to communicate with nodes on network B even when they're geographically co-located and within radio range. Each network is an island.

**What we want.** Inter-network gateway functionality. Selected nodes participate in multiple networks simultaneously and bridge traffic between them when explicitly requested.

**Constraints.**
- Gateway nodes carry traffic for ≥ 2 networks — their 1% duty cycle is shared across all of them. Need to prevent one network from starving another.
- Cross-network routing must not flood — no automatic advertisement of network B's nodes inside network A.
- Security boundary: cross-network bridging needs explicit policy. A node shouldn't accidentally forward sensitive intra-A traffic into B.

**Possible direction (not committed).**
- Per-node config: `participating_networks = [1, 5, 7]` (list, not single).
- Frame format gains a `dst_network_id` field (currently we only have implicit "this network" via the nid_byte). Forwarders relay cross-network only if they participate in both src and dst networks.
- Gateway nodes advertise themselves with a `is_bridge_to = [networks]` field in their beacon. Senders aiming at a cross-network destination route via the nearest known bridge.
- Network-aware duty cycle: each gateway tracks per-network airtime fraction separately; refuses cross-net forwards when the bridging share exceeds its policy.

**Open questions.**
- How does a node in network A *learn* network B exists, and discover the gateway? In-band beacons (gateway advertises in BOTH networks) or external bootstrap?
- Address spaces: shared 8-bit address space across all participating networks (collisions possible), or per-network address space with translation at gateway?
- Should the bridging policy be operator-configured (whitelist) or dynamic (route quality)?
- Compose with §8 cryptography — cross-network traffic probably needs different key material.

### 7.1 Concrete encrypted hierarchical DATA frame (synthesis of §7 + §8.1 + §9 T2)

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
- **§7 multi-network** — `addr_len + dst` IS the multi-network addressing. Gateways are nodes whose BCN advertises bridging capability (gateway-discovery design pending in **BCN re-engineering**, separate work item).

**What's NOT yet decided / open work.**

- **BCN re-engineering** is the next major design item. Current BCN advertises self + routes within a single network. With hierarchical routing it needs to:
  - Advertise bridging capability ("I'm a layer-14 gateway, reachable from this leaf")
  - Cross-layer route advertisement OR pull-based route discovery via `?` queries
  - Avoid foreign-network pollution (today's `network_id` filter dropped foreign frames; the new model needs cryptographic/structural equivalent)
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

**Problem statement.** Today's BCN advertises `(src, [dest, next, score, hops])` entries — all 1-byte node IDs within a single network. Under §7.1's hierarchical model, BCN needs to:
1. Indicate which leaf network the emitter belongs to (replacement for today's `network_id` filter role, which was repurposed in DATA as `addr_len`)
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
       ┌───────────────────────┬─────────┬──────────────────┬──────────────────┐
       │ layer (4 hi)          │ sf (8)  │ duration_100ms   │ offset_from_bcn  │
       │ + reserved (4 lo)     │         │ (8 bits)         │ (8 bits, sec)    │
       └───────────────────────┴─────────┴──────────────────┴──────────────────┘
```

**Field semantics.**

| Field | Bits | Purpose |
|---|---|---|
| `'B'` tag | 8 | unchanged |
| `has_schedule` | 1 | if 1, schedule records follow byte 3 (gateway emitter with TDM schedule for upper layers) |
| `n_entries` | 4 | route entry count; sentinel 0xF means "read 1-byte n_extended after schedule (if any)" |
| `leaf_id` | 4 | emitter's leaf-network ID (replaces today's `network_id` filter role); receivers drop foreign-leaf BCNs |
| `self_gateway_flag` | 1 | emitter is a gateway (= member of some upper layer); fast bootstrap before others advertise me |
| `src` | 8 | emitter's leaf-local node ID (unchanged from today) |
| route `dest`, `next` | 8+8 | unchanged from today |
| route `score_bucket` | 4 | unchanged: SNR bucket, 2 dB resolution |
| route `hops` | 3 | reduced from 4 bits (protocol caps at 8 hops anyway → 3 bits = 0-7 is fine) |
| route `is_gateway` | 1 | this destination is a gateway (member of some upper layer); propagates transitively via `rt_merge` |
| schedule `layer` | 4 | upper layer this record describes (14, 13, 12, etc.) |
| schedule `sf` | 8 | SF used on that layer (could shrink to 4 bits later) |
| schedule `duration_100ms` | 8 | how long the gateway is active on this layer per visit (0.1 - 25.5 s) |
| schedule `offset_from_bcn` | 8 | seconds from THIS BCN's reception to the next layer-window opening (0-255 s); receiver anchors on its local `bcn_rx_time` |

**Schedule record interpretation (clock-sync-free).**

Each receiver R notes the local time `bcn_rx_time` when it received this BCN. For each schedule record:
- Next window opens at `R's local time = bcn_rx_time + offset_from_bcn × 1 s`
- Window duration: `duration_100ms × 100 ms`
- Repetition period: implicit — refreshed on each subsequent BCN (no explicit period field needed)

R re-anchors at every BCN reception. Drift between BCNs is bounded by clock-drift over typical 5-min BCN periods (sub-second drift), negligible for window-sizing in 1-25 s range.

**Wire-cost comparison.**

| Scenario | Today | New |
|---|---|---|
| Plain leaf, 5 routes | 4 + 15 = **19 B** | 4 + 15 = **19 B** (same) |
| Plain leaf, 49 routes | 4 + 147 = **151 B** | 4 + 1 + 147 = **152 B** (+1 B for n_extended marker) |
| Gateway leaf with no schedule (= permanent on this layer, no TDM), 5 routes, 3 gateway destinations | n/a | **19 B** (gateway info is bits — zero wire cost) |
| Gateway with TDM schedule, 1 upper layer, 5 routes | n/a | 4 + 1 + 4 + 15 = **24 B** (+5 B for layer_count + schedule record) |
| Multi-layer gateway (2 upper layers via TDM), 8 routes | n/a | 4 + 1 + 8 + 24 = **37 B** |

**Gateway capability is effectively free for non-TDM gateways.** Only nodes that need to advertise their layer-switching schedule pay the 4 B/layer overhead. A node that is permanently on a single layer (e.g., a dedicated layer-14 hub with no leaf participation) has `has_schedule=0` and pays nothing extra.

**How a leaf node consumes the information.**

1. **rt_merge** processes each entry: `rt[dest]` candidate stores `is_gateway` flag alongside score/hops/next_hop.
2. **Schedule cache**: when a BCN from a direct neighbor has `has_schedule=1`, receiver stores the schedule records keyed by `(src_id, layer)`. On each BCN re-reception, re-anchor against current `bcn_rx_time`. Stale schedules (no BCN heard in 2× period) → drop.
3. **Cross-network send (alice → bob in another network):** alice's app constructs `addr_len = N, dst = [...]` (see §7.1). The local routing layer treats the frame as "destined for any gateway":
   - Pick an `rt[]` candidate with `is_gateway=1`, best score
   - Standard local routing toward that gateway
   - The chosen gateway takes over at the network boundary
4. **Detail discovery (rare).** If multiple gateways are present and alice needs to know which specific one bridges to a particular upper-layer network, she sends an app-layer DATA query (encrypted, normal mechanics) — `{type: "gateway_lookup", layer: 14, net: 35}`. Gateway responds with `{answer: yes/no/via X}`. This is RARE because most deployments have static topology config OR a single gateway per leaf.

**Cross-references.** §7.1 (DATA frame uses `addr_len + dst` whose routing is driven by `is_gateway` markers from this BCN), §7.3 (inter-layer TDM mechanics consume the schedule records), §6.5 (stale-route aging applies to gateway entries like any other route).

**Open questions (deferred).**
- Self-update of schedule records (when a gateway changes its TDM cadence, peers learn from the next BCN — no explicit "schedule changed" mechanism; just continuous refresh).
- Layer-14 (and higher) BCNs use the SAME format with semantics shifted (src = layer-14 ID, is_gateway = "member of layer-13", etc.). Recursive design.

### 7.3 Inter-layer routing protocol (single-radio TDM)

**Problem statement.** A gateway node participates in two or more layers (e.g., leaf SF7 + layer-14 SF11). A single LoRa radio can only be tuned to ONE (SF, frequency) at any instant. To support multi-layer gateway participation on consumer-grade hardware (no dual-radio), the protocol needs a time-division scheme — the gateway alternates between layers on a known schedule, and peers consult that schedule to time their interactions.

**Hybrid scheduling (the chosen mechanism).**

- **Primary layer:** the gateway's default state (typically the leaf layer where most of its traffic lives, e.g., SF7).
- **Periodic upper-layer sweep:** every `T_period` seconds, the gateway retunes to upper-layer SF for `duration` seconds. During the sweep:
  - Receives upper-layer BCNs (maintains its upper-layer `rt[]`)
  - Emits its own upper-layer BCN if scheduled
  - Available for inbound RTS from upper-layer peers
- **On-demand retune for outbound TX:** if the gateway has a queued frame for upper-layer forwarding AND is currently on its primary layer, it can opportunistically retune to upper layer to transmit, then return. This is in addition to the periodic sweep.

**Schedule announcement (via gateway's BCN, §7.2).**

The gateway's BCN includes schedule records — one per upper layer it participates in. Receivers anchor schedules against `bcn_rx_time` (no clock sync). Example: a gateway with schedule `{layer=14, sf=11, duration=200, offset=30}` is on layer-14 SF11 from `bcn_rx_time + 30 s` for 20 seconds, repeating from each subsequent BCN.

**Listen-on-overlap (intra-upper-layer hops).**

When two gateways G_a and G_b in the same upper layer need to communicate, both must be on that layer simultaneously. Their schedules are independent (each picks its own offset, no coordination).

Mechanism:
- G_a's BCN announces its layer-14 schedule
- G_b receives G_a's BCN, computes G_a's L14 window (relative to G_b's local time)
- G_b similarly knows its own layer-14 schedule
- For G_b to TX to G_a on layer 14: G_b waits for a time when BOTH are on layer 14 (= intersection of their windows)
- If windows don't currently overlap: G_b queues the frame; over a few BCN cycles, schedule drift OR adaptive offset shifting (gateway picks offset to align with observed peer schedules) creates overlap
- Cascade-requeue total-wallclock cap applies (§5.6); frames that can't find overlap within ~minutes drop with `cross_layer_giveup`

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
| Layer-14 traffic crowds L15 capacity at gateway | Shared duty-cycle budget; heavy cross-layer use reduces local L15 throughput | §11.5 budget tiers signal saturation; senders learn via NACK and re-route |
| L15 peers wait for gateway's L15-active windows | Up to `duration` of dead time per cycle | Active avoidance keeps peers from wasting airtime; queue-and-retry handles the wait |
| Schedule drift between gateways | Two gateways' schedules drift apart, breaking established overlap | BCN refresh re-anchors on each reception; adaptive offset (gateway shifts to align with observed peer activity) is optional optimization |
| Lost upper-layer BCNs (heard outside our sweep) | Stale upper-layer rt[] | Standard rt_aging applies; gateway's L14 rt[] has slightly higher staleness floor (proportional to sweep gap) |
| Multi-hop L14 with non-overlapping schedules | Each hop pays its own wait-for-overlap | Cascade-requeue total wallclock cap (§5.6) kills truly impassable paths; works as backpressure |

**Cross-references.** §7.1 (DATA frame consumes hierarchical `dst` that drives this routing), §7.2 (BCN carries schedule records that this protocol consumes), §5.6 cascade-requeue (handles bounded waits for cross-layer overlap), §11.5 budget tiers (gateway's shared duty cycle naturally signals saturation under load).

**Open questions (deferred to implementation).**
- Adaptive schedule offset: should gateways auto-shift to align with observed peer schedules? Pure local optimization; no protocol-level coordination needed.
- Layer-14 (and higher) using completely separate frequency sub-bands? Out of scope for the base proposal — we assume shared frequency, different SFs.
- Dual-radio hardware support: out of scope; future "professional" deployments could parallelise. Protocol design works either way.

**Implementation cost estimate.**
- BCN parse/pack extension for schedule records: ~30 lines
- Schedule cache + drift tracking at receivers: ~80 lines
- TDM scheduling state machine at gateway (sweep timer, retune logic, return-to-primary): ~150 lines
- L15 active-avoidance pre-check in `tx_initiating`: ~30 lines
- Inter-layer queue + overlap detection: ~100 lines
- Tests: schedule drift, overlap windows, missed sweep recovery, cross-layer delivery, schedule advertisement: ~150 lines

### 7.4 Control-plane frame updates (RTS / CTS / ACK / NACK)

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
| `network_id` (4 bits) | 4 bits | **renamed `leaf_id`, kept 4 bits** | Same role: drop foreign-leaf RTS before CTS work |
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
