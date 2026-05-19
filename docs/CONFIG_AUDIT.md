# Config audit — pre-C++-port classification

This is an **analysis document, not a code change**. It walks every
`config.X` knob the Lua firmware model accepts, classifies it for the
C++ port, and surfaces the candidates for elimination. Code changes
(deletion, hardcoding, refactor into compile-time constants) come in
follow-up sessions once classification is agreed.

Source: `scenarios/dv_dual_sf.lua` (the firmware model per
ROADMAP §11). 96 simple `self.X = config.X or default` knobs plus
~10 structural/derived ones — see section totals.

## Classification key

| Class | Meaning | C++ port disposition |
|---|---|---|
| **T** | **Tunable** — admin-set in deployment, per-network or per-node | Runtime config (NV-backed or JSON-loaded) |
| **P** | **Production-fixed** — single right answer, never tuned in the field | `constexpr` / `#define` constant; remove from runtime config |
| **F** | **Feature-flag** — on by default in production, can be disabled for tests | `#ifdef ENABLE_X` (compile out for tests/cert builds) |
| **D** | **Debug-only** — off in production, on for testing/diagnostics | `#ifdef DEBUG` instrumentation; never shipped enabled |

The audit's bias: when in doubt, prefer **P** over **T**. The user's
direction was "removing hundreds of configuration values"; every knob
left as **T** is a flash byte, an admin error surface, and a test
matrix axis the C++ port must carry forever.

## Summary

| Class | Count | % |
|---|---|---|
| T (Tunable)          |  20 | 17% |
| P (Production-fixed) |  82 | 68% |
| F (Feature-flag)     |   5 |  4% |
| D (Debug-only)       |   8 |  7% |
| R (Removed)          |   6 |  5% |
| **Total**            | **121** | |

Headline: **of 121 knobs, only 20 stay user-tunable in the C++ port.**

**Status (2026-05-19):**
- Step A (review revision) — **done**.
- Step B (delete R candidates) — **done**, 6 of original 8 deleted.
  Two reclassified out of R after discovery of legitimate usage:
  `gateway_remote_bind_ttl_ms` → **D** (t55 needs it for accelerated
  TTL aging) and `req_sync_min_routes` → **T** (s07/s08 set it to 2
  for low-route-density meshes).
- Step C (hardcode P + add F gates) — **done**. All 82 P-class knobs
  moved into a top-of-file `PROTOCOL = { ... }` table that the C++
  port can copy verbatim into a `protocol_constants.h` header. Lua
  `apply_protocol_constants(self, config)` honors per-scenario
  overrides as a test-only escape hatch (C++ port has no override
  path). `on_init`'s explicit `config.X` reads went from 96 → 35,
  a 64% drop. The remaining reads are 22 T + 5 F + 8 D + 3 derived-
  from-radio (the LBT timing trio: `retry_jitter_ms`,
  `lbt_backoff_ms`, `flood_lbt_max_defer_ms`).
- Step D (rewrite PROTOCOL.md §14) — **done**. §14 now shows only the
  20 T + 5 F + 8 D knobs in dedicated sub-sections (§14.1–§14.4),
  with §14.5 referencing the PROTOCOL block as the read-only source
  of truth for the 82 P-class constants. Section row count dropped
  from ~115 to ~56 (-51%). Scenario authors now see only what they
  can actually configure in deployment.

User decisions (2026-05-19) on the four judgment calls:
- `max_payload_bytes`: T, default raised to 230, hard-clamped to 241 (done).
- `originator_max_per_window`: T (chat fairness varies per network).
- `gateway_layer_period_ms` / `_duration_ms` / `_offset_ms`: **drop**
  the node-level fallback knobs; per-record values in `gateway_layers`
  are the only source, falling back to compile-time defaults if absent.
- `duty_cycle` / `duty_cycle_window_ms`: T (one firmware shipping
  multi-region beats region-specific builds).

Removal candidates (R) — to be **deleted rather than reclassified**:

- `beacon_period_warmup_ms` — legacy alias for `discovery_beacon_period_ms`.
- `q_response_settle_ms` and `q_response_settle_jitter_ms` — both default to derived values from `beacon_trigger_jitter_max_ms` + airtime; never overridden in any scenario. Inline the derivation.
- `req_sync_min_routes` — defaults to `discovery_min_routes`; no test sets it independently.
- `gateway_remote_bind_ttl_ms` — defaults to `id_bind_ttl_ms`; no test sets it.
- `gateway_layer_period_ms` / `_duration_ms` / `_offset_ms` — node-level fallback knobs; per-record `gateway_layers` entries already carry these (or fall back to compile-time defaults).

---

## §1 Identity & deployment role

| Key | Default | Class | Notes |
|---|---|---|---|
| `is_gateway` | `false` | **T** | Node role; admin-set. |
| `is_mobile` | `false` | **T** | Node role; admin-set. |
| `join_required` | `false` | **T** | Boot mode (LISTEN→DISCOVER) vs pinned id. Per-node. |
| `layer_id` / `leaf_id` | `0` | **T** | Network admin assignment. Wire field. |
| `key_hash32` | `nil` | **T** | Node identity; future NV-backed. |
| `nv` | `{}` | **D** | Test-only seed for NV-persisted state (claim_epoch). Real firmware reads NV directly. |

## §2 Radio / PHY

| Key | Default | Class | Notes |
|---|---|---|---|
| `routing_sf` | `7` | **T** | Network-wide convention; sometimes per-layer. |
| `allowed_data_sfs` | `{12}` | **T** | Per-node policy. |
| `bw_hz` | `250000` | **T** | Regulatory + per-network. |
| `cr` | `5` | **T** | Per-network. |
| `preamble_sym` | `16` | **P** | SX1262 default; varying it produces interop failures. |
| `duty_cycle` | `0.01` | **T** | Regulatory (EU 1%, US different). |
| `duty_cycle_window_ms` | `3600000` | **T** | Regulatory window. |
| `sf_margin_db` | `5.0` | **P** | Demod-threshold safety margin. Picked once, never tuned in field. |

## §3 MAC / Channel access

| Key | Default | Class | Notes |
|---|---|---|---|
| `cts_to_data_gap_ms` | `5` | **P** | Hardware SF-switch settle time. |
| `rts_timeout_ms` | (derived) | **P** | Override is debug; production uses derived value. |
| `rts_busy_retry_ms` | `30` | **P** | Tiny constant for receiver-busy reschedule. |
| `rts_max_retries` | `3` | **P** | Tuned per cascade analysis. |
| `max_payload_bytes` | `230` | **T** | Network-wide payload policy. Hard-clamped at init to LoRa PHY ceiling (`LORA_MAX_FRAME_BYTES - DATA_HDR_LEN - DATA_INNER_OVERHEAD` = 241). Originator emits `send_oversized` and rejects sends > cap; runtime `tx_oversized` is the radio-side backstop. |
| `lbt_enabled` | `true` | **F** | Always on in production; tests disable for collision tests. |
| `lbt_backoff_ms` | (derived) | **P** | Derived from `retry_jitter_ms / 2`. |
| `retry_jitter_ms` | (derived from RTS airtime) | **P** | Derived. |
| `flood_lbt_max_defer_ms` | (derived) | **P** | Derived from beacon airtime. |

## §4 Beacon plane

| Key | Default | Class | Notes |
|---|---|---|---|
| `beacon_period_ms` | `900000` | **T** | Deployment scale (15 min default; 2-30 min range). |
| `discovery_beacon_period_ms` | `5000` | **P** | Boot-time fast cadence. |
| `beacon_period_warmup_ms` | — | **R** | Legacy alias. **Delete.** |
| `beacon_max_bytes` | `151` | **P** | Frame-size constant (LoRa max ≈ 256). |
| `beacon_trigger_jitter_min_ms` | `2000` | **P** | Triggered-beacon coalescing window. |
| `beacon_trigger_jitter_max_ms` | `10000` | **P** | |
| `beacon_trigger_min_interval_ms` | `120000` | **P** | Rate-limits storm-prone triggers. |
| `beacon_max_idle_ms` | `900000` | **T** | Heartbeat cadence; deployment-scale. |
| `quiet_threshold_ms` | `30000` | **P** | Channel-busy throttle gate. |
| `beacon_silence_jitter_ms` | `10000` | **P** | Thundering-herd spread. |
| `seen_bitmap_enabled` | `true` | **F** | Always on in production; tests disable for isolation. |
| `seen_bitmap_ttl_ms` | `1800000` | **P** | Bitmap memory; derived from beacon period. |

## §5 Boot / Discovery

| Key | Default | Class | Notes |
|---|---|---|---|
| `discovery_ms` | `60000` | **P** | Boot-discovery window. |
| `discovery_min_bcn_rx` | `3` | **P** | Boot exit criterion. |
| `discovery_min_routes` | `8` | **P** | Boot exit criterion. |
| `beacon_boot_grace_ms` | `120000` | **P** | Suppresses trigger rate-limit during boot. |
| `req_sync_on_boot` | `true` | **F** | Always on in production; tests disable to isolate behavior. |
| `req_sync_listen_ms` | `8000` | **P** | Time-to-listen after REQ_SYNC. |
| `req_sync_retry_ms` | `30000` | **P** | Retry cadence. |
| `req_sync_min_routes` | (= `discovery_min_routes`) | **T** | s07/s08 set to 2 for sparse-route meshes. |

## §6 Routing (DV)

| Key | Default | Class | Notes |
|---|---|---|---|
| `rt_aging_ttl_neighbor_ms` | `2700000` (45 min) | **T** | Deployment scale; see TUNING block in code. |
| `rt_aging_ttl_remote_ms` | `10800000` (3 h) | **T** | Deployment scale. |
| `rt_aging_check_period_ms` | `60000` | **P** | Sweep cadence. |
| `next_hop_live_ttl_ms` | `1200000` | **P** | Direct-relay liveness. |
| `route_snr_conservatism_db` | `0` | **P** | Score offset; currently a no-op (default 0). |
| `rt_learn_from_data` | `true` | **F** | Always on in production. Could become unconditional. |

## §7 Peer liveness (suspect/silent/dead tiers)

| Key | Default | Class |
|---|---|---|
| `peer_suspect_rts_timeouts` | `2` | **P** |
| `peer_silent_rts_timeouts`  | `3` | **P** |
| `peer_dead_rts_timeouts`    | `6` | **P** |
| `peer_suspect_ttl_ms`       | `300000` | **P** |
| `peer_silent_ttl_ms`        | `900000` | **P** |
| `peer_dead_ttl_ms`          | `3600000` | **P** |
| `peer_dead_evidence_window_ms` | `900000` | **P** |
| `peer_suspect_penalty_db`   | `12.0` | **P** |
| `peer_silent_penalty_db`    | `40.0` | **P** |
| `peer_dead_penalty_db`      | `80.0` | **P** |
| `peer_suspect_bcn_max`      | `8` | **P** |

All 11 are **P**. None of these are network-policy choices; they
are tier-design constants. Folding into compile-time constants drops
the live config surface by 11.

## §8 Duty-cycle budget tiers

| Key | Default | Class |
|---|---|---|
| `budget_strained_pct`    | `50` | **P** |
| `budget_critical_pct`    | `80` | **P** |
| `budget_exhausted_pct`   | `95` | **P** |
| `budget_blind_strained_ms`  | `60000` | **P** |
| `budget_blind_critical_ms`  | `180000` | **P** |
| `budget_blind_exhausted_ms` | `300000` | **P** |
| `neighbor_budget_tier_ttl_ms` | `300000` | **P** |

All **P**. -7 from the live surface.

## §9 Anti-spam (originator rate-limit)

| Key | Default | Class | Notes |
|---|---|---|---|
| `originator_window_ms` | `300000` | **P** | Sliding window length. |
| `originator_max_per_window` | `6` | **T** | Per-network policy (chat fairness). |
| `originator_airtime_share` | `0.25` | **P** | Backstop. |
| `originator_self_warn_fraction` | `0.5` | **D** | Diagnostic hint emission; can be compiled out. |
| `originator_retry_dedup_ms` | `10000` | **P** | |

## §10 SNR EWMA

| Key | Default | Class |
|---|---|---|
| `snr_ewma_alpha` | `0.3` | **P** |

## §11 Cascade-requeue

| Key | Default | Class |
|---|---|---|
| `cascade_requeue_max`            | `3` | **P** |
| `cascade_requeue_base_ms`        | `5000` | **P** |
| `cascade_requeue_backoff_cap_ms` | `30000` | **P** |
| `cascade_requeue_total_max_ms`   | `60000` | **P** |
| `cascade_requeue_load_threshold` | `0` | **P** |

All **P**. -5.

## §12 Q frames

| Key | Default | Class | Notes |
|---|---|---|---|
| `q_query_ttl_ms` | `5000` | **P** | Sender-side Q dedup. |
| `q_respond_ttl_ms` | `10000` | **P** | Responder-side Q dedup. |
| `q_response_settle_ms` | (derived) | **R** | Derived from beacon jitter + airtime; **inline**. |
| `q_response_settle_jitter_ms` | (= `lbt_backoff_ms`) | **R** | Derived; **inline**. |

## §13 Sync response (REQ_SYNC)

| Key | Default | Class |
|---|---|---|
| `sync_response_enabled` | `true` | **F** |
| `sync_response_min_routes` | `1` | **P** |
| `sync_response_backoff_min_ms` | `500` | **P** |
| `sync_response_backoff_max_ms` | `6000` | **P** |
| `sync_response_mobile_penalty_ms` | `8000` | **P** |
| `sync_response_requester_mobile_penalty_ms` | `2000` | **P** |
| `sync_response_suppress_window_ms` | `12000` | **P** |

## §14 Defer queues

| Key | Default | Class |
|---|---|---|
| `send_defer_ttl_ms` | `30000` | **P** |
| `gateway_handoff_defer_ttl_ms` | (= `send_defer_ttl_ms`) | **P** |

## §15 Origin dedup / hop tracking

| Key | Default | Class |
|---|---|---|
| `seen_origin_ttl_ms` | `30000` | **P** |
| `last_acked_ttl_ms` | `10000` | **P** |
| `state_snapshot_period_ms` | `60000` | **D** |

## §16 End-to-end ACK

| Key | Default | Class |
|---|---|---|
| `e2e_ack_ttl_ms` | `60000` | **T** |

Per-message E2E ACK deadline; UI/client-tunable.

## §17 Hop budget (§7.6)

| Key | Default | Class |
|---|---|---|
| `hop_budget_slack` | `3` | **P** |
| `hop_budget_max_initial` | `15` | **P** |
| `rt_learn_from_data` | `true` | **F** (see §6) |

## §18 Bounded-state caps (§11.1, see ROADMAP)

| Key | Default | Class |
|---|---|---|
| `cap_seen_origins`              | `256` | **P** |
| `cap_q_queried`                 | `128` | **P** |
| `cap_q_responded_to`            | `128` | **P** |
| `cap_deferred_sends`            |  `32` | **P** |
| `cap_gateway_deferred_handoffs` |  `32` | **P** |
| `cap_id_bind`                   | `256` | **P** |

All **P**: sized at port time, not in the field.

## §19 Join state machine (§2a)

| Key | Default | Class |
|---|---|---|
| `join_listen_ms` | `3000` | **P** |
| `join_discover_jitter_ms` | `3000` | **P** |
| `join_discover_wait_ms` | `10000` | **P** |
| `join_discover_max_attempts` | `0` (∞) | **P** |
| `join_offer_backoff_min_ms` | `100` | **P** |
| `join_offer_backoff_max_ms` | `1000` | **P** |
| `join_claim_guard_ms` | `3000` | **P** |
| `join_retry_backoff_ms` | `10000` | **P** |
| `join_j_rate_limit_window_ms` | `300000` | **P** |
| `join_j_max_per_window` | `6` | **P** |

All **P**. -10.

## §20 Gateway / multi-layer

| Key | Default | Class | Notes |
|---|---|---|---|
| `gateway_layers` | `{}` | **T** | Per-gateway schedule list. Each record carries its own `period_ms`/`duration_ms`/`offset_ms`. |
| `gateway_layer_period_ms` | — | **R** | **Delete** — node-level fallback; per-record `gateway_layers[i].period_ms` (or compile-time default) replaces it. |
| `gateway_layer_duration_ms` | — | **R** | **Delete** — same as above. |
| `gateway_layer_offset_ms` | — | **R** | **Delete** — same as above. |
| `id_bind_ttl_ms` | `172800000` (48 h) | **P** | |
| `gateway_remote_bind_ttl_ms` | (= `id_bind_ttl_ms`) | **D** | Production = `#define = ID_BIND_TTL_MS`. t55 sets 8000 ms to verify aging-out path within test duration. |

## §21 Debug window

| Key | Default | Class |
|---|---|---|
| `debug_start_ms` | `nil` | **D** |
| `debug_end_ms` | `nil` | **D** |
| `debug_start` (alias) | `nil` | **D** |
| `debug_end` (alias) | `nil` | **D** |

---

## What survives the cut

After applying classifications:

**T (20 user-tunable knobs)** — the only config the C++ port's
runtime config layer needs to support:

- **Identity (5)**: `is_gateway`, `is_mobile`, `join_required`, `layer_id` (with `leaf_id` alias), `key_hash32`
- **Radio (6)**: `routing_sf`, `allowed_data_sfs`, `bw_hz`, `cr`, `duty_cycle`, `duty_cycle_window_ms`
- **MAC (1)**: `max_payload_bytes`
- **Beacon (2)**: `beacon_period_ms`, `beacon_max_idle_ms`
- **Boot (1)**: `req_sync_min_routes`
- **Routing (2)**: `rt_aging_ttl_neighbor_ms`, `rt_aging_ttl_remote_ms`
- **Anti-spam (1)**: `originator_max_per_window`
- **E2E ACK (1)**: `e2e_ack_ttl_ms`
- **Gateway (1)**: `gateway_layers` array (per-record `period_ms` / `duration_ms` / `offset_ms` live inside each entry)

**F (5 feature flags)** — `#ifdef`-style compile-time gates, on in production:

- `lbt_enabled`, `seen_bitmap_enabled`, `req_sync_on_boot`,
  `rt_learn_from_data`, `sync_response_enabled`

**P (82)** — fold into compile-time constants in the C++ port. No
runtime knob. This is the bulk of the savings: ~68% of the surface
becomes a single header of `constexpr` values.

**D (8)** — debug instrumentation, compiled out of production:
`nv`, `originator_self_warn_fraction`, `state_snapshot_period_ms`,
`debug_start_ms`, `debug_end_ms` (and `_ms`-less aliases),
`gateway_remote_bind_ttl_ms`.

**R (6)** — deleted in step B:
`beacon_period_warmup_ms`, `q_response_settle_ms`,
`q_response_settle_jitter_ms`, `gateway_layer_period_ms`,
`gateway_layer_duration_ms`, `gateway_layer_offset_ms`.

## Suggested follow-up sessions

1. **Confirm classification** (this doc) — user reviews, overrides
   any disagree-with calls. **Output: this doc, annotated.**
2. **Delete R candidates** — straight removals + inlining.
   Estimated 1 short session. **Output: ~50 LoC removed, config schema -4.**
3. **Hardcode P + add F gates** — move 72 P knobs to a single
   `PROTOCOL_CONSTANTS` block at top of file with `#ifdef`-style
   comments; introduce `feature.X` table for F knobs. The Lua file
   shrinks meaningfully and the C++ port's `protocol_constants.h`
   header writes itself. ~1-2 sessions.
4. **Document T schema** — rewrite PROTOCOL.md §14 to cover only
   the 17 T + 6 F knobs. Half a session.

## Judgment calls — resolved 2026-05-19

All four open calls settled:

- **`max_payload_bytes`** → **T**, default 230, hard-clamped to 241. Done in `feat(model): max_payload_bytes raised to production`.
- **`originator_max_per_window`** → **T**.
- **`gateway_layer_period_ms` / `_duration_ms` / `_offset_ms`** → **R** (delete the node-level fallback knobs; per-record `gateway_layers` entries are the only source). Pending in step B.
- **`duty_cycle` / `duty_cycle_window_ms`** → **T**.
