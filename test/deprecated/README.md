# Deprecated tests

These tests are kept in the tree for archeology. They were excluded from
the default `bash test/run_tests.sh` sweep (the runner only scanned
top-level `test/t*.json` and `scenarios/s*.json`) — and as of **2026-07-25
that runner and the whole legacy corpus are RETIRED** (owner ruling: the
configs stopped passing `JsonConfig` validation at the 2026-07-21 Wave-1
required-keys change; git history preserves them). These files were authored
against an earlier, less-realistic version of the protocol; their
timing assumptions or wire-format expectations no longer hold once
the model acquired BCN trigger rate-limiting, F1 blind windows,
gateway scheduling, mandatory `key_hash32`, layer-scoped state,
hop-budget enforcement, and Q4 fixed-point dB.

None of these failures are regressions. See
`docs/CONFIG_AUDIT.md` and the audit memory entry
`project_legacy_tests_realism` for context.

## Inventory (moved 2026-05-19)

| Test | Pre-realism intent | Why it no longer passes |
|---|---|---|
| `t11_dv_convergence` | 4-node full convergence within 30 s | BCN trigger rate-limit (`beacon_trigger_min_interval_ms = 120 s`) — multi-hop discovery doesn't complete in the window |
| `t15_concurrent_relay` | F1 concurrent-relay handling | `blind_observed` / `tx_blind_defer` event semantics evolved |
| `t26_k3_cascade` | K=3 cascade walks alternatives on relay death | `rts_timeout` is now derived per-flight from SF; cascade timing no longer matches the relay-death fixture |
| `t31_round_robin_queue` | tx_queue round-robin under cascade exhaustion | exact cascade_requeue counts and exhaustion sequence shifted |
| `t33_anti_spam_rate_limit` | 1st-hop silent-drop after threshold | exact origination thresholds drifted |
| `t39_req_sync_wire` | REQ_SYNC bit round-trips through pack/parse | bit position / parsing changed |
| `t40_dirty_only_cold_start` | Cold-start joiner gets SYNC_FULL response | realistic sync_response backoff misses the assertion window |
| `t41_first_contact_sync` | Receiver-side first-contact detection | bootstrap timing assumptions broken |
| `t43_seen_bitmap_no_candidate_refresh` | Bitmap refreshes candidates only via sender | candidate fresh-via-sender check evolved |
| `t44_rts_multi_next_visual` | Ordered multi-next-hop RTS slot behaviour | slot timing evolved |

## Deprecated scenarios (`scenarios/deprecated/`)

| Scenario | Why it's here |
|---|---|
| `scenarios/deprecated/s11_three_layer_gateway_stress.json` | `sim_end` reaches cleanly but assertions for early cross-layer flights fail; transient delivery loss during the simultaneous-join + gateway-discovery window is expected under realistic protocol timing |
| `scenarios/deprecated/s01_dv_dual_sf.json` | The original 4-node dual-SF Lua acceptance scenario (dynamic SF retune + path-loss + `sim:link_snr`). Moved here 2026-07-25 by owner ruling ("drop the s01 file, do not migrate") with the legacy-corpus retirement: it stopped passing `JsonConfig` validation at the 2026-07-21 Wave-1 required-keys change, and the Lua engine it targets is itself deprecated. **Deliberately NOT migrated** — kept only as the frozen reference. ⚠ `webapp/tests/test_sim_manager.py`, `test_simulations_router.py` and `test_smoke_e2e.py` still resolve `scenarios/s01_dv_dual_sf.json`; refixturing or removing them is the owner's call. |

## Running them anyway

`test/run_tests.sh` no longer exists (retired 2026-07-25). Drive one directly:

```bash
# Single test:
./build/orchestrator/lus test/deprecated/t26_k3_cascade.json /tmp/t26.ndjson
```

Expect a `Config validation failed` refusal until the file is migrated to the
current required keys (`simulation.radio.duty_cycle`, per-link `snr_std_dev`).

## Recovering a test

If you want to bring one back to the live suite, the cheapest wins are
likely `t39` (one-byte/bit wire fix), `t40` / `t41` (bump durations
or relax min-routes thresholds), and `s11` (relax the assertion to
"any one of l4j1-a/b/c delivered" since the stress is meant to
exercise persistence, not first-flight guarantees).
