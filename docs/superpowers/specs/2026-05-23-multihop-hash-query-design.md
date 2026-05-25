# Multi-hop hash-locate query (`'H'` frame) — Design

(Replaces the 1-hop `Q:HASH_QUERY` opcode with a dedicated flooded
`'H'` frame + routed-DATA response. See cross-check for why a new
frame rather than extending `Q`.)

**Date:** 2026-05-23
**Status:** design (not yet implemented)

## Context — the problem

Cross-layer DM addressing works like this (PROTOCOL §15.1, §3.x):

1. Originator A on layer X addresses a message to `(target_layer, dst_key_hash32)`.
2. A finds a gateway that bridges to `target_layer` (via the `gateway_layer`
   TLV, type 4 — already propagates multi-hop) and routes the envelope to it.
3. The gateway must resolve `dst_key_hash32 → node_id` **on the target layer**
   before it can send the in-target-layer DATA leg (routing is by short id).

Step 3 is where it breaks for far destinations. The gateway resolves the hash
either from its own `gateway_remote_bind` table or, if absent, by broadcasting
`Q:HASH_QUERY` on the target layer. But:

- `id_bind` / `gateway_remote_bind` is **1-hop** — each BCN carries only the
  sender's own `(src, key_hash32)`. The gateway only ever learns the bindings
  of its **direct radio neighbours** on the target layer.
- `Q:HASH_QUERY` is **1-hop** — `dv_dual_sf.lua:10448` makes a node that
  doesn't know the hash go silent and return. The query never forwards.

So when the destination (and its binding-holding neighbours) are more than one
radio hop from the gateway, resolution fails: `gateway_no_binding` →
`gateway_handoff_deferred` → (30s) → `gateway_handoff_giveup`. Confirmed on s15:
`mia → zoey` via bridge_23 — envelope reaches bridge_23, but bridge_23's L3
neighbours (xena, yves) don't know zoey, the 1-hop query dies, handoff times out.

**Design constraint (from discussion):** we do NOT want to carry `key_hash32`
in route entries or fatten BCNs with everyone's bindings — that defeats the
purpose of short ids. Bindings stay local to each node (a node and its direct
neighbours know its hash). The gateway must *find* the binding, not accumulate
all of them.

## Design — flood the query, route the response

Two halves, only the first is new machinery:

### Query (NEW — dedicated `'H'` frame, TTL-bounded flood on the target layer)

Rather than overload `Q` (which is defined as strictly 1-hop, §3.7), the
flooded hash-locate query gets its **own frame type `'H'`**. This keeps `Q`
pure, isolates the forward/dedup logic in one handler, and lets us **remove
`Q_OP_HASH_QUERY` entirely** (freeing opcode 2 back to the 2-bit opcode space).

The gateway broadcasts an `'H'` frame carrying its own node_id (`origin`, so
the resolver can route the answer home), the target layer's leaf_id, the
`key_hash32` to resolve, and a TTL. Each receiving node on the target layer:

- **knows the hash** (own `key_hash32` matches, or local `id_bind` has it) →
  resolve to `node_id`, send the response (see below), and stop forwarding this
  branch.
- **doesn't know it** → if `(origin, key_hash32)` not already seen and
  `ttl > 0`: record it in the seen-query set, decrement TTL, rebroadcast.
  Otherwise drop.

The seen-query set prevents the flood from storming (each node forwards a given
`(origin, key_hash32)` exactly once). No wire `query_id` — see cross-check §3.

### Response (REUSE — normal routed unicast back to the gateway)

The resolver now has `(dst_key_hash32 → resolved_node_id)` AND the gateway's
node_id (from `query_origin`). It sends a normal **routed unicast** to the
gateway's node_id through the existing routing table (RTS/CTS/DATA, multi-hop).
No reverse-path breadcrumbs — routing already delivers any node_id → any
node_id within a layer. The payload carries the binding
`(resolved_node_id, key_hash32)`.

The gateway receives it, updates `gateway_remote_bind[(target_layer, hash)] =
node_id` (existing table, 48h TTL), and drains the held handoff
(`try_drain_gateway_handoffs`, already wired).

### Why this is affordable (AODV reactive-discovery economics)

- Flood is **single-layer**, TTL-bounded to the layer diameter (~4-5 hops).
- Query is a tiny Q frame, not the DATA payload.
- Binding is **cached 48h** → one query per (gateway, destination) per 48h.
- Cross-layer destinations are **few and stable** → first message pays
  discovery, all later messages are a local lookup.

## Cross-check against the existing Q-frame spec (§3.7) + firmware

Read `PROTOCOL.md §3.7` and `dv_dual_sf.lua` Q paths. Findings that
shaped the new-frame decision:

1. **`Q` is defined as strictly 1-hop** (§3.7 line 642: "One-hop only —
   receivers don't forward Q frames"). Rather than carve a forwardable
   exception into `Q`, we add a **dedicated `'H'` frame** for the flood.
   `Q` stays pure; the new frame owns the forward/dedup logic. Net code
   is about the same, but the separation is cleaner and ports better.

2. **Removing `Q_OP_HASH_QUERY` frees opcode 2.** `Q` opcode is 2 bits,
   currently fully used (`ROUTE_QUERY=0, REQ_SYNC=1, HASH_QUERY=2,
   CHANNEL_PULL=3`). HASH_QUERY's only use is gateway handoff discovery
   (`emit_hash_route_query`, the `q.opcode == Q_OP_HASH_QUERY` branch at
   line 10407, and `pack_q_hash` / `pack_q_hash_response`). Moving it to
   the `'H'` frame lets us delete all of that and reclaim opcode 2.
   (PROTOCOL.md §3.7 is also **stale** — it still lists `3=reserved for
   full-public-key query`; it's actually CHANNEL_PULL. Fix the doc as
   part of this work: opcode 2 becomes free/reserved, 3 = CHANNEL_PULL.)

3. **`src`/`origin` already exists.** `emit_hash_route_query` already
   sends with the gateway's own id; in the `'H'` frame that becomes the
   explicit `origin` field, preserved across forwards so the resolver
   can route the answer home.

4. **No `query_id` needed.** Forwarder dedup keys on `(origin,
   key_hash32)` — both in the frame — with a TTL. The gateway's existing
   sender-side dedup `q_queried["hash:layer:hash"]` (TTL `q_query_ttl_ms`,
   line 4928-4933) already prevents re-flooding the same hash within that
   window, so `(origin, key_hash32)` uniquely identifies a flood instance
   for its lifetime.

5. **The 1-hop Q response form is removed.** Today a HASH_QUERY frame
   with `dest != 0xFF` is the response (`pack_q_hash_response`, handled at
   line 10408 `if q.dest ~= 255`). With HASH_QUERY gone from `Q`, the
   answer rides routed DATA (below). Delete `pack_q_hash_response` and
   the `q.dest ~= 255` branch.

6. **Response-return timing interacts with the gateway time-share.** The
   routed-DATA response is addressed to the gateway's target-layer
   node_id, but the gateway only listens on the target layer during its
   visit window. The existing `gateway_schedule_defer_ms` (defer RTS
   toward a scheduled-away gateway) already handles this — the last-hop
   forwarder defers the response DATA until the gateway's window. No new
   mechanism; just rely on it (and verify it fires).

## Wire format

### New `'H'` frame (hash-locate flood query) — 8 bytes

```
byte:  0    1        2                    3..6              7
       ┌───┬────────┬────────────────────┬────────────────┬──────┐
       │'H'│ origin │ leaf_id(4) flags(4)│ key_hash32(4LE)│ ttl  │
       └───┴────────┴────────────────────┴────────────────┴──────┘
```

- **`origin`** (8) — querying gateway's node_id on the target layer.
  **Forwarders preserve it** (never overwrite). The resolver routes its
  answer here.
- **`leaf_id`** (4 hi of byte 2) — target layer nibble; receivers reject
  `'H'` frames whose leaf_id ≠ their active leaf (same foreign-layer
  filter every frame uses).
- **`flags`** (4 lo of byte 2) — reserved (0). Room for e.g. a future
  "requester mobile" bit if needed; not used in v1.
- **`key_hash32`** (4 LE) — identity hash to resolve.
- **`ttl`** (8) — initial = `hash_query_max_ttl` (default 6, ≥ layer
  diameter). Decremented per forward; dropped at `ttl == 0`.
- Forwarder dedup key = `(origin, key_hash32)`.

`pack_h_query` / `parse_h_query` mirror the existing per-frame
pack/parse helpers. Per project policy there is no backward-compat
concern; the wire changes freely.

### Binding response — routed DATA, body-magic prefix (NOT a new flag)

Cross-check finding: the DATA flag field is only **4 bits and all four are
taken** (`PAYLOAD_TYPE_M=0x01, PRIORITY=0x02, E2E_IS_ACK=0x04,
E2E_ACK_REQ=0x08`). There is no free flag bit for a new payload type. So
instead of a flag, the binding response reuses the **body-magic** pattern that
the cross-layer gateway envelope already uses (`GW_ENV_MAGIC = "\31G1"`,
`pack_gateway_envelope` / `parse_gateway_envelope`).

The resolver sends a normal unicast DATA to `origin` (the gateway) via the
existing send/`tx_queue`/`issue_send` path. The DATA inner body is:
```
HASH_BIND_MAGIC ("\31H1", 3 B) | target_layer(8) | resolved_node_id(8) | key_hash32(4 LE)
```
On receive, the gateway's DATA delivered-branch tries
`parse_hash_bind_response(body)` (alongside the existing
`parse_gateway_envelope(body)`). If it matches AND `self.self_gateway`, the
gateway updates `gateway_remote_bind`/`id_bind` for `target_layer`, calls
`try_drain_gateway_handoffs`, emits `q_hash_binding_rx`, and does NOT emit
`delivered` (it's control, not user data). A non-gateway that somehow receives
it drops it (mirrors `gateway_envelope_at_non_gateway`).

Rationale for routed-DATA over a routed-Q: DATA already has the full
RTS/CTS/ACK + routing machinery; Q frames are 1-hop control. Reusing DATA is
the "don't reinvent routing" path; the body magic avoids needing a flag bit
we don't have.

## New state + constants

- `self.hash_query_seen` — set keyed by `(src, key_hash32)`, TTL-aged
  (`hash_query_seen_ttl_ms`, ~aligned with the gateway's `q_query_ttl_ms`
  so a node forgets a flood about when the gateway is allowed to re-issue
  it). Bounded by `cap_hash_query_seen` (emit `table_cap_hit` on overflow,
  §13.6 pattern).
- PROTOCOL constants:
  - `hash_query_max_ttl` (default 6)
  - `hash_query_seen_ttl_ms` (default e.g. 10000, ≈ `q_query_ttl_ms` × 2)
  - `cap_hash_query_seen` (default e.g. 64)

## Forwarding rules (precise)

New `on_recv` branch `if tag == "H"` (target layer, leaf_id matches active):
```
origin, ttl, hash = parse_h_query(frame)
if origin == self.id: drop                    # our own query came back
local nid = (self.key_hash32 == hash) and self.id
            or id_bind_find_by_hash(self, hash)
if nid != nil:
    # Resolver: reply via routed unicast DATA to the gateway (origin).
    send_hash_binding_response(self, to=origin, layer=active, node=nid, hash=hash)
    mark_seen(origin, hash)                    # also suppress our own forward
    return
if seen(origin, hash): drop
mark_seen(origin, hash)
if ttl <= 0: drop
rebroadcast verbatim with ttl-1               # tx_initiating, label "H"
```

Notes:
- Dedup key is `(origin, key_hash32)`. The same flood arriving via
  different paths (different residual ttl) is dropped after the first —
  first arrival marks seen regardless of its ttl.
- Multiple branches may answer (several nodes know the hash). The gateway
  dedups on the binding it already has — first response wins, later ones
  are idempotent refreshes via `gateway_remote_bind_set`. Acceptable.
- A node that answers also marks the query seen so it won't separately
  forward it — saves one rebroadcast.
- The `'H'` frame is the **only** forwardable control frame; `Q`, BCN,
  RTS-class, etc. all stay 1-hop. Forwarding lives entirely in this
  branch, not sprinkled across the `Q` handler.

## Gateway side (mostly existing)

- `emit_hash_route_query` (line 4925): swap the `pack_q_hash(...)` +
  `tx_initiating(label="Q")` for `pack_h_query(origin=self.id, leaf_id,
  key_hash32, ttl=hash_query_max_ttl)` + `tx_initiating(label="H")`. The
  layer retune (`activate_gateway_layer`) and sender-side dedup
  (`q_queried["hash:layer:hash"]`) are unchanged.
- On binding-response DATA (new `PAYLOAD_TYPE_HASH_BINDING`): update
  `gateway_remote_bind`, call `try_drain_gateway_handoffs`. The deferred-
  handoff TTL (30s) and giveup path stay as-is — they're the backstop if
  the flood finds nothing (destination genuinely unreachable).
- Delete `pack_q_hash`, `pack_q_hash_response`, `Q_OP_HASH_QUERY`, and the
  `q.opcode == Q_OP_HASH_QUERY` branch in the `Q` handler (~line 10407).

## Verification

1. Smoke: `bash test/run_tests.sh test/t*.json` stays green (no regression).
2. s15: `mia → zoey` (L2→L3 via bridge_23) and `frank → wendy` (L1→L3 via
   bridge_13) go from 0% → delivering. Trace should show:
   - `gateway_no_binding` at the bridge (first message only)
   - `'H'`-frame flood forwarded across the target layer (multiple
     `h_rx`/`h_forward` events with decrementing ttl)
   - a binding-response DATA routed back to the bridge
   - `gateway_remote_bind_set source=h_query`
   - `gateway_handoff_drained` → in-target-layer DATA → destination `data_rx`
   - second+ messages to the same destination skip the query (cached binding)
3. Dedicated test (folds in Task #20): a line topology
   A(L1)–...–G(gateway)–...–Z(L2) where Z is several hops from G on L2;
   assert A→Z delivers and that the query was forwarded (ttl decrement visible)
   and the binding cached.

## Out of scope / explicitly NOT doing

- No `key_hash32` in route entries (airtime tax, rejected).
- No `id_bind` propagation TLV (would make every node accumulate all bindings).
- No reverse-path breadcrumb table for the response (routing handles return).
- Response flooding (routed unicast instead).
