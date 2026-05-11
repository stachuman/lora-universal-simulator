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
