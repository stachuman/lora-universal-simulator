# Design principles

The protocol's design values, in priority order. Every mechanism in
`scenarios/dv_dual_sf.lua` traces to one or more of these. If a future
change would violate one, that's a load-bearing decision deserving
explicit discussion — not a quiet drift.

These aren't aspirational. They're the implicit contract that's been
guiding the work for months. Documenting them here so the firmware
model, the C++ port, and any third-party reviewer have one place to
point at.

---

## 1. Airtime is the scarce resource

EU868 sub-band g1 gives ~36 s of TX per hour per node (1% duty).
Sub-band g3 gives ~360 s (10%). Either way, **the cost of every
mechanism must be justified against this budget**, not against
"can we make it work in a few seconds of simulated time".

Prefer cheaper-at-higher-latency over louder-faster. Prefer
**eventually delivered** over **retry until done**. Prefer dropping
a non-essential beacon over crowding the channel.

**Visible in:** budget-tier throttle (HEALTHY/STRAINED/CRITICAL/EXHAUSTED),
originator rate-limit (`originator_max_per_window`), adaptive BCN
throttle, route aging that doesn't immediately re-advertise.

## 2. Never flood

No mechanism re-transmits the same payload from every node in the
mesh. **Flooding is the easy default that breaks at scale**, and the
proximate failure mode visible in MeshCore and Meshtastic when
network density grows.

All forwarding is targeted:
- **Unicast traffic**: routed via `rt[]` (distance-vector with K=3
  alternates), each hop deliberately chosen.
- **Multi-recipient (channels)**: lazy gossip with dirty bits
  (BCN extension + `Q_CHANNEL_PULL`), one airtime cost per message
  shared across the mesh rather than re-emitted by every forwarder.
- **Urgency**: priority bit on a unicast DM elevates queue order but
  not airtime; hard-capped per originator. Never a parallel "loud
  mode".

**Visible in:** DV routing with K=3 alts; the proposed `Q_CHANNEL_PULL`
gossip; the priority-flag-on-unicast design over a separate flood mode.

## 3. Deliberate routing

WHO forwards what is decided either by the originator's `rt[]` view
or by lazy-replication agreement between direct neighbours. Forwarders
never decide "this is interesting, everyone might want it" unilaterally.

- Originator sets `next_hop`, `hop_budget`, `dst`.
- Forwarder picks among that origin's intended candidates.
- Channel gossip propagates only via deliberate pull exchanges; even
  the pull responses are **promiscuously overheard**, not actively
  pushed.

**Visible in:** `route_strictly_better`, hop budget enforcement,
3-cycle prune, pull-rate-limit per BCN cycle.

## 4. Eventually-consistent beats force-delivered

Mesh networks partition. Nodes go offline. Routes age out. The
protocol assumes **intermittent connectivity is normal**: convergence
happens via repeated lightweight propagation, not via originator-side
retries that hammer the network.

- DV merge converges over many beacon cycles.
- BCN dirty-rotation: a changed route is advertised quickly but not
  flooded.
- Channel gossip: a missed message will be pulled later when the
  receiver's digest reveals the gap.
- Offline-then-online nodes catch up automatically; no "I missed
  messages while offline" out-of-band recovery is needed.

**Visible in:** `rt_aging_ttl_*`, BCN seen-bitmap freshness, the
channel `seen_by` bitmap + dirty propagation.

## 5. Realism: model only what hardware can do

No simulator-only crutches. If real LoRa firmware
(SX1262/SX1276/LR11xx) cannot observe, decide, or react to something
within its API, the protocol cannot rely on it. Behavioural quirks
that come from real radio hardware (preamble-detect IRQ timing,
LBT CAD cost, half-duplex blackout during TX) are first-class
constraints.

**Visible in:** `on_preamble_detected` IRQ wiring; mandatory
`key_hash32` in every BCN (real firmware reads from NV/hash, not
"sim says"); SF picks bounded by Semtech AN1200.22 demod thresholds.

## 6. Bounded state

Every growing table has a documented hard cap and emits
`table_cap_hit` telemetry when reached. No "grow forever" structures.
The C++ port is targeting nRF52840 with 256 KB SRAM — a lot, but
finite.

**Visible in:** `cap_seen_origins`, `cap_q_queried`, `cap_q_responded_to`,
`cap_deferred_sends`, `cap_gateway_deferred_handoffs`, `cap_id_bind`,
`cap_channel_buffer`.

## 7. Deterministic

Same `simulation.seed` × same scenario timeline = same NDJSON event
sequence, on the Lua model and on the C++ port. Cross-implementation
differential tests rely on this. Practically:

- All script-level randomness flows through `self:rand`
  (`std::mt19937` + `std::uniform_int_distribution` in C++).
- Iteration order over `self.rt`, `self.id_bind`, etc. must be stable
  — Lua's `pairs()` works for a given Lua version; the C++ port must
  use `std::map` or sort-before-iterate where the iteration order
  affects emitted events.

**Visible in:** the RNG-contract comment block at top of
`scenarios/dv_dual_sf.lua`; ROADMAP §11.3.

## 8. Compile-time constants over runtime knobs

If a value doesn't vary by deployment, it's a `constexpr`, not a
config field. Keeps the deployment surface small and the C++ port
mechanical. Per `docs/CONFIG_AUDIT.md`: 20 T-class tunables, 82
P-class compile-time constants, 5 F-class feature flags, 8 D-class
debug-only. The 82 P-class live in one `PROTOCOL = {...}` table at
the top of the Lua model and become a single
`protocol_constants.h` header in C++.

**Visible in:** `apply_protocol_constants(self, config)` at the top
of `on_init`; the `MeshRoute/lib/core/protocol_constants.h` mirror.

## 9. Single mechanism per concern

One unicast routing path (DV + K=3). One join state machine (LISTEN →
... → ADOPT). One channel propagation mechanism (gossip). One
priority elevation (DATA flag bit). No parallel "alternative"
mechanisms that might diverge.

When tempted to add a second mechanism: harder. Extend the existing
one, or accept the constraint.

**Visible in:** §3 channels using gossip-only (no parallel multicast);
priority being a flag bit not a new frame type; §2a join handling
both autonomous and gateway-context cases via the same state machine.

## 10. Urgency is bounded bandwidth, not a different mechanism

Priority messages use the unicast path with a queue-precedence flag.
Hard-capped per originator AND per direct-sender (separate from
normal anti-spam ledger). Urgency cannot escape into airtime abuse.

For "warn many people quickly": send to specific contacts as priority
unicasts (ICE-style, 2-5 recipients). For "everyone in the area":
that's a public channel via gossip — slower convergence, intentional.

**Visible in:** the `DATA_FLAG_PRIORITY` bit in §3.4 (no new frame
type); `originator_priority_max_per_window = 5` over a 1-hour window
(tight enough that abuse hurts the abuser).
