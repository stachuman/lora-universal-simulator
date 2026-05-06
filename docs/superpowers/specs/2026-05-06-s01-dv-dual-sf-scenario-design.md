# Scenario s01_dv_dual_sf — design

## 1. Background and goal

The simulator now ships R.1.7 (single-SF reception default), R.1.8 (dynamic
`self:set_rx_sf` retune), R.2 (path-loss + lat/lon), and `sim:link_snr`. We
need a single, end-to-end scenario that exercises all of these against a
realistic-ish protocol shape, both as a smoke test and as a foundation for
larger scenarios (B: small mesh, C: 15-25 nodes geographic) later.

**Primary purpose:** test that the simulator's existing capabilities cooperate
correctly when a non-trivial Lua protocol drives them.

**Secondary purpose:** seed a reusable Lua protocol module — the same script
will run on B's denser mesh with no protocol-level changes; only topology and
expectations differ.

## 2. Non-goals (explicit YAGNI list)

The first scenario is deliberately minimal. The following are out of scope
and **must not** be added in this spec's implementation:

- **Timeouts, retries, retransmissions.** The simulator is deterministic on
  scenario A; happy path only.
- **End-to-end ack** from destination back to source. Test verifies delivery
  at the destination, not at the source.
- **Availability scoring** (less-busy-route preference). Deferred to a later
  scenario.
- **SF negotiation.** `routing_sf` and `data_sf` are fixed in config.
- **Split-horizon, poisoned reverse, route expiry.** A bounded hop count
  (max 8) plus best-score-wins is sufficient for a 4-node line.
- **Payload fragmentation.** A user message is one packet.
- **Beacon authentication, replay protection, sequence numbers.**

## 3. Topology

**Four nodes in a line:** `alice` → `bob` → `charlie` → `dave`, deployed on
a meridian (constant longitude) with ~1.5 km adjacent spacing. The 1.5 km
spacing is chosen so adjacent links comfortably pass SF7 reception while
2-apart links fall below the SF7 threshold (see SNR table below).

**Path-loss configuration:**
```json
"path_loss": {
  "model": "log_distance",
  "alpha": 3.0,
  "sigma_db": 0.0,
  "ref_distance_m": 1.0,
  "ref_loss_db": 40.0,
  "noise_floor_db": -120.0,
  "tx_power_dbm": 14.0
}
```

With `alpha=3`, ref_loss=40@1m, tx_power=14 dBm, noise_floor=-120 dBm,
SNR(d) = 94 − 30·log10(d_m):

| Distance | SNR    | SF7 (thr −7.5) | SF12 (thr −20) |
|---|---|---|---|
| 1.5 km (adjacent)  | −1.3 dB  | decode (6.2 dB margin)  | decode |
| 3.0 km (2-apart)   | −10.3 dB | drop (2.8 dB below)     | decode |
| 4.5 km (3-apart)   | −15.6 dB | drop                    | decode |

So on SF7, only adjacent links decode; 2-apart and 3-apart are dropped
(`drop_weak`). On SF12, all pairs decode physically — but the protocol
addresses next-hop only, so non-next-hop receivers simply discard at the
script level after parsing the `next` field.

`sigma_db=0` keeps the test deterministic.

## 4. Protocol — control plane

Every node runs the same script. State (per node):

```lua
self.rt = {}                  -- routing table: rt[dest_id] = entry
self.routing_sf = 7
self.data_sf = 12
self.beacon_period_ms = 5000
self.next_msg_id = 1
self.pending_tx = nil         -- in-flight user message during dual-SF dance
self.name_to_id = {}          -- built at on_init from sim:nodes()
self.peer_count = N - 1       -- for `rt_full` detection
```

**Routing table entry shape:**
```lua
rt[dest_id] = { next_hop = id, score = number, hops = int, last_seen_ms = uint64 }
```

`score` is link quality in dB along the path (bottleneck SNR, see merge
below). Higher is better.

### 4.1 Beacon scheduling

At `on_init`:
- Build `name_to_id` from `sim:nodes()` (all node names → ids, including self)
- Schedule first beacon at `self:after(self.id * 100, beacon_fire)` —
  deterministic ID-based stagger, no collisions on first round
- Inside `beacon_fire`: emit beacon, then `self:after(self.beacon_period_ms,
  beacon_fire)` (re-arm)

Using `self:after` (re-armed) instead of `self:every` so the period can be
randomized later if needed without rewriting scheduling.

### 4.2 Beacon contents

```
BEACON = 'B' | src(1) | n_entries(1) | repeat n_entries times: dest(1), next(1), score_i8(1), hops(1)
```

Wire-format helper functions in the script:
```lua
local function pack_beacon(self) ... end   -- returns Lua string
local function parse_beacon(frame) ... end -- returns {src, entries=[...]}
```

`score_i8` is the score rounded to the nearest dB, clamped to [-128, +127],
encoded as a signed byte. dB precision is plenty for routing decisions.

### 4.3 Beacon merge logic

When `on_recv` fires with a beacon from node `N` at SNR `rx_snr`:

```
1. Direct entry (always update):
     rt[N] := { next_hop=N, score=rx_snr, hops=1, last_seen=now }

2. For each entry e in beacon.entries where e.dest != self.id:
     combined_score := min(rx_snr, e.score)
     combined_hops  := e.hops + 1
     if combined_hops > 8: skip            (loop bound)
     if e.next == self.id: skip            (poison-reverse-lite — don't accept
                                            routes that point back through us)
     if rt[e.dest] is absent
        OR combined_score > rt[e.dest].score
        OR (combined_score == rt[e.dest].score AND combined_hops < rt[e.dest].hops):
            rt[e.dest] := { next_hop=N, score=combined_score, hops=combined_hops, last_seen=now }
            self:emit("rt_update", { dest=e.dest, next=N, score=combined_score, hops=combined_hops })

3. After merge: if for every other node d in name_to_id, rt[d] is non-empty,
   AND we have not yet emitted rt_full this run:
     self:emit("rt_full", { peers = peer_count })
     self.rt_full_emitted = true
```

`rt_full` is the assertion target for "DV converged at this node".

## 5. Protocol — data plane

Triggered by command `send <dst_name> <text>`. The script looks up `dst_id
= self.name_to_id[dst_name]`, then `next_hop = self.rt[dst_id].next_hop`,
then enters the dual-SF dance towards `next_hop` carrying the user payload.

**Pre-conditions:** `pending_tx == nil`. If a user message is already in
flight, the new command is rejected (`return "ERROR: busy"`).

### 5.1 Per-hop sequence

Sender `S` (already on `routing_sf` for RX), next-hop `N`, final dst `D`,
originator `O`. At the originator hop `O == S`; at every forwarder hop `O`
is carried over from the received DATA frame.

```
1. S: tx({origin=O, src=S.id, dst=D, next=N.id, msg_id, data_sf}, sf=routing_sf)
      msg type = 'R' (RTS)
      self:emit("rts_tx", {origin=O, dst=D, next=N.id, msg_id})
   S: set_rx_sf(data_sf)
      self:emit("retune_for_cts", {sf=data_sf})

2. N: receives 'R' on routing_sf with next == self.id
      self:emit("rts_rx", {from=S.id, origin=O, dst=D, msg_id})
      set_rx_sf(data_sf)
      self:emit("retune_for_data", {sf=data_sf})
      tx({msg_id}, sf=data_sf)
        msg type = 'C' (CTS)
      self:emit("cts_tx", {to=S.id, msg_id})
   (N's RX is now on data_sf; N waits for the DATA frame. N also remembers
    the RTS context: msg_id, origin, dst, payload-pending.)

3. S: receives 'C' on data_sf, msg_id matches pending_tx.msg_id
      self:emit("cts_rx", {from=N.id, msg_id})
      tx({origin=O, src=S.id, dst=D, next=N.id, msg_id, payload}, sf=data_sf)
        msg type = 'D' (DATA)
      self:emit("data_tx", {origin=O, dst=D, next=N.id, msg_id, len=#payload})
      set_rx_sf(routing_sf)
      pending_tx := nil

4. N: receives 'D' on data_sf, msg_id matches the RTS it accepted, next == self.id
      self:emit("data_rx", {from=S.id, origin=O, dst=D, msg_id, len=#payload})
      set_rx_sf(routing_sf)
      if D == self.id:
          self:emit("delivered", {origin=O, payload=payload})
      else:
          let nh = rt[D].next_hop
          if nh is nil:
              self:emit("forward_fail", {dst=D, reason="no_route"})
          else:
              pending_tx := { origin=O, dst=D, next=nh,
                              msg_id=N.gen_msg_id(), payload=payload }
              ... go to step 1 with S=N, O carried over from received DATA
```

Each forwarder generates its own `msg_id` for its own RTS so concurrent
flights (when scenario expands) don't collide. `msg_id` is `(self.id << 8) |
self.next_msg_id`, then `next_msg_id := next_msg_id + 1`. Truncated to 16
bits in the wire format. For scenario A there's only one in-flight message
at a time, so collision is impossible.

The `origin` field is set by the originator and copied unchanged by every
forwarder. `src` is the immediate transmitter and is set fresh per hop. The
destination uses `origin` (not `src`) in its `delivered` event so the test
can assert end-to-end provenance.

### 5.2 Filtering at receivers

Every received frame is parsed first. The script discards (silently, no
event) any frame whose:
- `next` field doesn't match `self.id` (RTS/DATA addressed elsewhere)
- `msg_id` doesn't match `pending_tx.msg_id` (CTS for someone else's
  flight — only relevant when the CTS receiver is the originator)

This is essential because on `data_sf` other nodes may still hear the
frame physically (e.g., when SF12 reaches 2-3 hops away). Without
next-hop filtering the protocol would loop or duplicate.

### 5.3 No timeouts (scenario A)

If a CTS doesn't arrive (e.g., the simulator dropped the RTS), the
sender's `pending_tx` stays set and `set_rx_sf(data_sf)` is never reverted.
This is fine in scenario A because the deterministic path-loss + line
topology guarantees adjacent reception. Scenario B will need a timeout +
retry that resets `pending_tx` and `set_rx_sf` back to `routing_sf`; that
is explicitly out of scope for this spec.

## 6. Wire format (summary)

All frames start with a 1-byte type tag:

| Tag | Frame | Layout |
|---|---|---|
| `'B'` | Beacon | `B`, src(1), n(1), entries × n × {dest(1), next(1), score_i8(1), hops(1)} |
| `'R'` | RTS    | `R`, origin(1), src(1), dst(1), next(1), msg_id_lo(1), msg_id_hi(1), data_sf(1) |
| `'C'` | CTS    | `C`, src(1), msg_id_lo(1), msg_id_hi(1) |
| `'D'` | DATA   | `D`, origin(1), src(1), dst(1), next(1), msg_id_lo(1), msg_id_hi(1), payload(n) |

`origin` is the originating node id (carried unchanged by forwarders).
`src` is the immediate transmitter (set fresh per hop).

`src` is included on every frame for diagnostics even when redundant with
`from` in `on_recv` meta — keeps frames self-describing in NDJSON dumps.

`score_i8`: signed byte representation of dB. Clamp range [-128, +127].

`msg_id`: 16-bit little-endian. Per-sender monotonic; uniqueness across
the network is not required (scenario A has only one in-flight message).

## 7. Configuration schema

```json
{
  "_name": "s01_dv_dual_sf",
  "_desc": "Distance-vector routing on SF7; data delivery on SF12 via per-hop dual-SF handshake. Tests R.1.7/R.1.8/R.2 + sim:link_snr cooperatively. 4-node line, deterministic path-loss.",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 },
    "path_loss": {
      "model": "log_distance",
      "alpha": 3.0,
      "sigma_db": 0.0,
      "ref_distance_m": 1.0,
      "ref_loss_db": 40.0,
      "noise_floor_db": -120.0,
      "tx_power_dbm": 14.0
    }
  },
  "nodes": [
    { "name": "alice",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.3900, "lon": 2.1600 },
    { "name": "bob",     "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4035, "lon": 2.1600 },
    { "name": "charlie", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4170, "lon": 2.1600 },
    { "name": "dave",    "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 7, "data_sf": 12, "beacon_period_ms": 5000 },
      "lat": 41.4305, "lon": 2.1600 }
  ],
  "topology": { "links": [] },
  "commands": [
    { "at_ms": 30000, "node": "alice", "command": "send dave hello-world" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "alice",   "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "bob",     "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "charlie", "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "dave",    "emit_type": "rt_full",   "value": "" },
    { "type": "script_emit_contains", "node": "dave",    "emit_type": "delivered", "value": "hello-world" },
    { "type": "event_count", "event_type": "drop_sf_mismatch", "min": 0, "max": 0 }
  ]
}
```

The latitudes were chosen so adjacent pairs are ~1.5 km (delta ≈ 0.0135°
along the meridian). Geographic precision will be verified during the
implementation step using `sim:link_snr` from inside the script — if the
adjacent SNR isn't in the [−4, +1] dB band that gives clean SF7 adjacency,
the lat values get nudged.

`sf_rx_set` is omitted from each node, so the default `[node.sf]` = `[7]`
applies. The dynamic `set_rx_sf` calls then exercise the runtime retune.

## 8. Files

- `scenarios/dv_dual_sf.lua` — the protocol (one file, ~200 lines)
- `scenarios/s01_dv_dual_sf.json` — the scenario config

The `scenarios/` directory is for end-to-end protocol scenarios.
`examples/` retains its role for tiny per-feature demos
(`flooder.lua`, `sf_picker.lua`, etc.).

## 9. Testing strategy

The scenario itself is the test: `bash test/run_tests.sh
scenarios/s01_dv_dual_sf.json` (after teaching the runner to look in
`scenarios/`, or by running `lus` directly).

Key assertions covered by `expect[]`:

1. **Convergence:** every node emits `rt_full` — proves DV reached every
   peer through beacon overhearing alone.
2. **End-to-end delivery:** dave emits `delivered` carrying `hello-world` —
   proves the dual-SF dance worked at every hop.
3. **No SF gating violation:** zero `drop_sf_mismatch` events — proves the
   `set_rx_sf` calls happen at the right moments. If the script forgot to
   retune before sending DATA, the receiver's RX would still be on SF7 and
   the SF12 DATA would be dropped with `drop_sf_mismatch`.

Manual / inspection-only checks (verified during implementation, not
automated):
- Per-hop event ordering (rts_tx → cts_rx → data_tx for sender, rts_rx →
  cts_tx → data_rx for receiver).
- Three sets of these per send (one per hop on the line).

## 10. Visibility — script `self:emit` events

Beacon plane: `beacon_tx`, `beacon_rx`, `rt_update`, `rt_full`.

Data plane: `rts_tx`, `rts_rx`, `cts_tx`, `cts_rx`, `data_tx`, `data_rx`,
`delivered`, `forward_fail`.

Retune visibility: `retune_for_cts` (emitted alongside `set_rx_sf` on the
sender side) and `retune_for_data` (on receiver). These are diagnostic —
they make the dual-SF dance legible in the NDJSON dump without having to
correlate with internal state.

## 11. Operating outside `test/` — runner integration

The existing `test/run_tests.sh` only globs `test/t*.json`. For this spec,
two options:

A. **Add `scenarios/s*.json` glob** to the runner — minimal one-line
   change to the script.

B. **Just invoke `lus` directly** during development:
   `./build/orchestrator/lus scenarios/s01_dv_dual_sf.json
   scenarios/s01_dv_dual_sf_events.ndjson`.

The implementation plan should include option A so scenario tests participate
in the regression suite.

## 12. References

- `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md` —
  parent simulator design (this scenario uses §7.2 runtime/sim namespaces
  and §11 path_loss tunables).
- `docs/superpowers/plans/2026-05-06-phase-R1-radio-physics-parity.md` —
  R.1.7/R.1.8 plans.
- `docs/superpowers/plans/2026-05-06-phase-R2-path-loss-model.md` —
  R.2 plan.
