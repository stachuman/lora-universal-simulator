# dv_dual_sf protocol roadmap

Topics flagged during analysis sessions that we want to address but aren't
the immediate next step. Each entry is short on purpose — capture the
shape of the problem, not the solution. Linked-to-from
`scenarios/dv_dual_sf.lua` and `tools/analyze.py` where relevant.

---

## 1. Per-originator airtime budget (anti-spam)

**Problem.** A single chatty originator can monopolise network capacity.
At ~1% per-node duty cycle, every forwarder along the originator's
multi-hop path also burns its own budget relaying that traffic — so one
node sending 50 messages/min effectively consumes airtime across N
forwarders × 1 hop each. Origin A's traffic crowds out everyone else
even though A only has its own 1% local budget.

**What we want.** Per-originator fair-share enforcement, applied at
forwarders: the share of my own budget I'm willing to spend forwarding
A's traffic is bounded.

**Constraints.**
- Per-origin state at each forwarder must be cheap (no per-flight
  history; sliding-window airtime counter at most).
- Reaction has to be informative — the originator needs feedback that
  it's being throttled so it can back off (or the user-facing app can
  show the rate-limit signal).
- Must compose with the existing budget NACK (don't conflict).

**Possible direction (not committed).**
- Forwarders track per-origin airtime spent forwarding over the last N
  minutes (sliding window).
- Threshold: `forwarded[origin] > my_budget × fair_share` (fair_share ≈
  1/known_originators, or some pessimistic 1/8 if we don't track
  population).
- Over threshold → NACK with new `reason=originator_throttle` + origin
  airtime fraction.
- Originator interprets the NACK as backpressure on that destination
  via this path; rate-limit at the application layer.

**Open questions.**
- TTL on the per-origin counter? Match the 1 h duty-cycle window?
- Should originators also self-limit, or rely on network feedback?
- Do we need a separate NACK reason or extend `reason=budget_low` with
  an origin field?

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
- **BCN — differential page encoding**: each BCN-page emits only entries whose (dest_id, score, hops) tuple changed since the same node's last advertisement of that dest. Already partly done via the dirty-flag mechanism for advertisement priority; extending to actual on-wire delta would require per-receiver dictionary state.
- **BCN — variable-length node IDs**: small node IDs (frequent neighbours) get 1-byte encoding, distant IDs get 2-byte (varint or escape-byte trick). Trade-off: parser complexity vs ~25% byte reduction in dense neighbourhoods.
- **DATA — app-layer dictionaries**: known message types (status, beacons-on-channel, alerts) compress against a pre-shared dictionary. Generic chat-text compression is marginal at <100 B payload — fixed dictionary overhead dominates LZ77 or Huffman wins.
- **DATA — bit-pack the application protocol** (similar to what we did for the wire protocol): if the application has structured fields with small value ranges, encode them in bits rather than bytes.

**Open questions.**
- Is the gain worth the codec complexity for the simulator's purposes? The runtime models airtime exactly; compression would just reduce bytes. Maybe just measure achievable compression ratios offline (run zstd over captured payloads) and document the headroom without implementing in-protocol.
- Should we add a `compressed` bit in the frame header to gate the path?
- Per-link compression (negotiated) vs global protocol decision?

**Recommendation.** Defer in-protocol compression. Measure achievable ratios on real payloads offline first; in-protocol codec only if measurements show >20% savings AND the failure mode is byte-limited (not symbol-limited).

---

## 5. End-to-end delivery ACK (optional, per-message)

**Problem.** The hop-by-hop K-frame ACK tells the originator only that the immediately-next forwarder received the DATA. If a forwarder mid-path drops the message, the originator's K-ack still succeeded — the loss is silent. Important user messages (payments, status confirmations) have no way to verify actual delivery.

**What we want.** Optional end-to-end ACK from the *destination* back to the *originator*, requestable per-message via a flag in the DATA frame. Bulk chat doesn't pay the round-trip; explicitly-marked important messages do.

**Constraints.**
- Cost of an E2E ACK is N hops × ~50 ms airtime per direction = significant on routes >3 hops.
- Must not be the default — flooding every message with E2E ACK defeats the duty-cycle budget recovery we just spent weeks fixing.
- E2E ACK can itself be lost; originator needs a timeout + (optional) retry policy.

**Possible direction (not committed).**
- 1-bit `e2e_ack_requested` flag in the DATA frame's payload header (already has 2 bytes for origin-seq; could spare 1 bit there).
- Destination, on accepting DATA (after current hop-by-hop K-ack), additionally sends a new frame `E` (end-to-end ACK) routed back to the originator using normal data-plane mechanics. The `E` frame is tiny (just origin + origin_seq + 1 byte status).
- Originator maintains `pending_e2e[(origin, origin_seq)] = { sent_at, ttl }`. On `E` rx → emit `delivered_confirmed`. On TTL expiry → emit `e2e_ack_timeout`. App layer decides retry / surface "not confirmed" to user.

**Open questions.**
- Does the `E` frame use full RTS-CTS-DATA-ACK or a fast-path single-frame? Single-frame is cheaper but less reliable (no CTS = ~5% loss); full-path doubles the cost of the original message.
- Default TTL? 30 s for typical 3-hop routes, longer for known-deep meshes.
- Retry policy: should the originator's stack auto-retry the original message on E2E timeout, or always surface to app?
- Composability with the existing `delivered` script_emit — that fires at the destination, which already implies the DATA reached. The E2E ACK is for the *originator's* knowledge.

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
