# K=3 Multi-Alt Routing — Design

Status: design (awaiting user review)
Author: 2026-05-09 session
Depends on: `2026-05-09-kill-node-orchestrator-design.md` for the
test scenario's kill-node primitive.

## Background

`scenarios/dv_dual_sf.lua` today maintains exactly two routes per
destination: a `primary` and a single `alt`. The single-alt
structure handled two real cases:
1. **Blind-window mitigation** (`classify_blind`): when the primary
   next-hop is in a CTS-overheard "blind" period, divert via alt.
2. **NACK-driven path-switch** (just removed in commit `125fa13`):
   on a busy NACK, retry via alt. We removed this because busy NACKs
   are transient — the receiver freeing up is the natural recovery,
   path-switching to a different forwarder doesn't help when the
   destination itself is the busy one.

The remaining gap: **persistent next-hop failure**. If the primary
forwarder dies mid-traffic (powered off, crashed, moved out of
range), the protocol today retries the dead next-hop until
`rts_giveup` (max_retries × rts_timeout, ~1.5 s by default) or
`ack_giveup`, then drops the message. With a single alt, recovery
is limited; the alt may also have gone dark, leaving no fallback.

This spec generalizes the routing table to K candidates per
destination (K=3) and adds a sequential failure-cascade so the
sender walks through alternatives on persistent failure rather than
giving up after one alt.

## Goal

Increase delivery resilience under persistent next-hop failures
(e.g. a node powered off mid-flight) by maintaining and trying up
to K=3 routes per destination.

## Scope

- `scenarios/dv_dual_sf.lua` only. Single-file change.
- Routing table layout migration from `{primary, alt}` to `{candidates}`.
- Failure-cascade trigger on `rts_giveup` and `ack_giveup`.
- One integration test scenario (depends on the kill-node feature).
- No wire-format change. Beacons still advertise primary only.

## Out of scope

- Configurable K (hardcoded constant for now; promote to config
  later if needed).
- Parallel forwarding to multiple next-hops simultaneously
  (decided against in upstream brainstorm — sequential cascade only).
- Beacon-advertised alts (would inflate BCN airtime; alts continue
  to populate via local observation of multiple beacon-senders).
- Soft-giveup / requeue after K-exhaustion (decided "hard giveup"
  matches today's behavior; tracked separately if needed).

## Routing table layout (migration)

**Before:**
```lua
rt[dst] = {
  primary = { next_hop, score, hops, last_seen_ms, ... },
  alt     = { next_hop, score, hops, last_seen_ms, ... } | nil,
}
```

**After:**
```lua
rt[dst] = {
  candidates = {  -- sorted descending by score; len 1..K
    { next_hop, score, hops, last_seen_ms, ... },  -- primary
    { ... },                                          -- alt 1
    { ... },                                          -- alt 2
  },
}
```

`K = 3` (hardcoded constant `MAX_RT_CANDIDATES`). `candidates[1]`
is the current primary; readers convert from old `entry.primary` to
`entry.candidates[1]` and from `entry.alt` to `entry.candidates[2]`.

Invariants:
- `1 <= #candidates <= K`.
- All `candidates[i].next_hop` are distinct.
- `candidates` is sorted by descending score (ties broken by hops
  ascending, then last_seen_ms descending — same `route_strictly_better`
  comparator already used today).

## rt_merge changes

For each candidate `cand` arriving from a beacon:

1. If a candidate with `cand.next_hop == candidates[i].next_hop`
   exists: refresh in place if `cand` is strictly better, else just
   update `last_seen_ms` + `n2_hop`. After refresh, re-sort. (Today
   only the primary path does this; we extend to all K positions.)
2. Else (new next-hop):
   - If `#candidates < K`: insert and re-sort.
   - If `#candidates == K`: compare against the worst candidate
     (last in sorted list). If `cand` is strictly better, replace
     it; re-sort. Else drop.

The `route_strictly_better` comparator is unchanged (still requires
the `viab_db` margin to avoid flapping).

Return values from `rt_merge` (used by callers for emit decisions):
- `"new"` — first candidate for this dst
- `"primary_refresh"` — candidate at position 1 was refreshed
- `"promote"` — candidate moved to position 1 (was at 2..K, or new)
- `"alt_install"` — candidate moved to position 2..K (was lower or new)
- `"no_change"` — same as before

## Failure-cascade

Two new entry points in the existing failure paths:

**`rts_giveup`** (today: clear pending_tx, become_free):
- Add `pending_tx.alts_tried[next_hop] = true` for the just-failed
  next-hop.
- Look up `rt[pending_tx.dst].candidates`; find the first candidate
  whose `next_hop` is NOT in `alts_tried`, NOT equal to
  `pending_tx.previous_hop`, and not currently blind.
- If found: switch `pending_tx.next` to that candidate; reset
  `retries_left = rts_max_retries`; emit `path_cascade` with
  `from_next`, `to_next`, `attempt = #alts_tried + 1`; call
  `tx_rts_retry(self, "cascade")`. Return.
- If exhausted: emit `rts_giveup` (today's event) AND a new
  `path_cascade_exhausted` for trace clarity. Clear pending_tx,
  become_free. (Hard giveup.)

**`ack_giveup`** (today: clear pending_tx after re-RTS exhausts):
- Same logic as above, with the cascade fired after the existing
  ack-loss recovery (re-RTS) gives up.

**ACK arrives** (`on_recv "K"` matching pending_tx.msg_id):
- Existing happy-path logic unchanged.
- After clearing pending_tx, the `alts_tried` set is implicitly
  cleared too (it lives on pending_tx).

## classify_blind changes

Today returns `"alt"` (single alt) or `"defer"`. Now returns
`"alt"` with the first non-blind candidate, walking the candidates
list in order. Skip:
- Candidates already in `alts_tried` (caller-provided).
- The current next-hop (already known blind).
- The `previous_hop` (loop guard).

If no usable candidate: return `"defer"` with the shortest
remaining-blind time across the current next-hop set (today's
behavior).

## New events

- `path_cascade` — fired on each cascade step, fields:
  `origin`, `origin_seq`, `dst`, `msg_id`, `from_next`, `to_next`,
  `attempt` (1..K-1), `trigger` (`"rts_giveup"` or `"ack_giveup"`).
- `path_cascade_exhausted` — fired when all K candidates have been
  tried, fields: `origin`, `origin_seq`, `dst`, `msg_id`,
  `tried` (list of next_hops in attempt order).

`path_switch` (the existing event from blind-window mitigation)
remains, distinct from cascade — `tx_blind_alt` triggers it for
proactive blind-window switches.

## Test

Uses the kill-node feature from the sibling spec.

**Integration scenario** `test/t25_k3_cascade.json`:
- 5 nodes: `alice`, `relay1`, `relay2`, `relay3`, `dave`.
- Topology: alice has 1-hop links to relay1 (best), relay2, relay3;
  each relay has a 1-hop link to dave; relay-relay links absent.
  Result: alice's `rt[dave]` should populate with 3 candidates after
  beacon convergence: `via=relay1` (best), `via=relay2`, `via=relay3`.
- `relay1.dies_at_ms = 25000`; `relay2.dies_at_ms = 30000`.
- `commands`: alice sends "msg1" at t=27000 (relay1 dead, relay2
  alive — should cascade once to relay2, deliver). alice sends
  "msg2" at t=32000 (relay1 + relay2 both dead, relay3 alive —
  cascades twice, delivers).
- `expect`:
  - `event_count` for `node_died` == 2.
  - `script_emit_contains` at `dave` with `emit_type=delivered` and
    `value="msg1"`.
  - `script_emit_contains` at `dave` with `emit_type=delivered` and
    `value="msg2"`.
  - `script_emit_contains` at `alice` with `emit_type=path_cascade`
    (any value — proves the cascade fired at least once).
  - Absence: no `script_emit_contains` match for
    `emit_type=path_cascade_exhausted` at any node. (If the
    `expect` schema lacks an explicit absence assertion, the
    pytest layer covers it; integration test omits this check.)

**Webapp pytest** (optional follow-up): more granular per-message
cascade-attempt assertions. Not required for the integration test
to validate the design.

## Acceptance criteria

- `test/t25_k3_cascade.json` integration test passes.
- `bash test/run_tests.sh` reports 32/32 (was 30, +1 for kill-node
  test t24, +1 for cascade test t25).
- s04_seattle_dense delivery rate doesn't regress (currently 94%).
  Ideally improves further as cascades cover edge cases the busy-
  NACK fix didn't.
- No `path_cascade_exhausted` events in the standard scenarios
  (s01–s05) — meaning K=3 is enough headroom for the test corpus.

## Risks

- **Memory**: rt entries grow ~50% (3 candidates vs 2). For dense
  scenarios (s04 has 147 nodes), 147 peers × 3 candidates × ~30
  bytes = ~13 KB per node. Trivial.
- **Convergence**: in sparse networks where only 1-2 distinct paths
  exist to a destination, `#candidates < K` is normal and not a bug.
  The cascade just has fewer alternatives.
- **Beacon convergence speed**: alts populate via observation of
  multiple beacon-senders. In low-density areas, getting 3 distinct
  candidates may take several beacon rounds. The kill-node test
  scenario gives 25 s of warmup-then-traffic-then-kill which
  should be plenty.
- **Cascade thrash**: if the receiver ack-times-out then we cascade,
  but if the new candidate also fails, we cascade again. K rounds
  in the worst case, each at full rts_max_retries × rts_timeout.
  Total worst-case latency: K × max_retries × rts_timeout ≈
  3 × 3 × 500 = 4.5 s before giveup. Acceptable for test traffic.
