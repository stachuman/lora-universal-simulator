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

## 5. End-to-end delivery ACK (optional, per-message)

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
- **E2E layer**: ChaCha20-Poly1305 with pre-shared key per (origin, dst) pair. 12 B nonce + 16 B MAC = 28 B overhead per frame. Acceptable for a 50-150 B payload, marginal for tiny status messages.
- **Frame auth**: short truncated MAC (4-8 B) on RTS/CTS/ACK/BCN using a network-wide pre-shared key. Forwarders verify before relaying; spoofed frames silently drop. Per-frame cost: 4-8 B + small CPU.
- **Key bootstrap**: per-network PSK distributed out-of-band (real Meshtastic does this — QR code at deployment time). Per-pair E2E keys via Diffie-Hellman over the mesh (first contact cost is high but amortized over the relationship).
- **Forward secrecy**: rotate the network-wide PSK periodically (e.g., daily) via key-derivation from a master + epoch counter. Each node holds the master and computes current key.
- **Replay protection**: per-pair sequence number window (we already have `origin_seq` for dedup — could extend the window check to also reject "old" sequences as replay attempts).

**Open questions.**
- Per-pair E2E keys (requires N² storage at large N) vs per-channel (smaller storage, weaker guarantees)?
- Should the routing layer be cryptographically authenticated, or rely on physical-layer trust? Meshtastic doesn't auth routing; we could be more conservative.
- Key rotation synchronization across the mesh — what happens during the rotation window when some nodes have updated and some haven't?
- Hardware crypto acceleration availability — SX1262 doesn't have it, so all crypto runs on the host MCU.
- Interaction with §6 channels and §7 multi-net (probably distinct key sets per channel and per network).

---

## 9. Privacy / originator anonymity (T2)

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
