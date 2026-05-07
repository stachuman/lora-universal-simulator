# Session Handoff — lora-universal-simulator

Last updated: 2026-05-07

This document captures session state for continuity. The previous session
approached its context budget; this is a tight summary of what's done,
what's verified, and what's open.

## Where work happens

The simulator lives at `/home/staszek/lora-universal-simulator/`. The
`MeshCore-stachuman` repo (current shell cwd) is unrelated to this
project — historical artifact of how the session began.

Build: `cmake -S . -B build && cmake --build build -j`. Binary at
`build/orchestrator/lus`.

## Tests

| Suite | Status | Command |
|---|---|---|
| Native C++ | all passing | `bash test/native/build_test.sh` |
| Integration (JSON scenarios) | 14/14 PASS | `bash test/run_tests.sh` |
| Webapp Python | 36/36 PASS | `cd webapp && python -m pytest tests/` |
| End-to-end (CLI vs webapp event parity for s01) | passing | included in webapp pytest |

`s01_dv_dual_sf` is the canonical end-to-end scenario — exercises path-loss,
DV routing, dual-SF data delivery, retries, half-duplex enforcement.

## Recent simulation-quality fixes (in order, most recent first)

These closed real gaps users hit while inspecting timelines:

1. **RTS retry on CTS timeout** (`9776be7`, `52f0dbb`)
   - `rts_timeout_ms` default 500 ms (was 100; needed to cover SF12 DATA airtime ~888 ms during which receiver is busy)
   - `rts_busy_retry_ms` 30 ms — short retry when our retry timer fires while we're mid-RX
   - `rts_max_retries` 3 — total attempts before `rts_giveup`
   - Receiver detects duplicate RTS (same `from`+`msg_id` against pending_rx) and re-sends CTS instead of rejecting
   - New events: `rts_retry`, `rts_retry_deferred`, `rts_giveup`, `rts_rx_dup`; TX labels `RTS-rty` / `CTS-dup`

2. **CTS moved to routing_sf** (`6020efb`) — 446 ms → 18 ms airtime, 35% faster per hop. Originator never retunes RX.

3. **5 ms inter-frame gap** (`6020efb`) — `cts_to_data_gap_ms` config field, originator waits before TX'ing DATA after CTS RX. Defensive against real-hardware retune latency (simulator is sub-µs but real SX1262 is a few hundred µs).

4. **LBT enabled in s01** (`092be88`) — dropped `cad_miss_prob: 1.0` workaround. Real LoRa LBT now active; deferrals visible in events.

5. **Half-duplex enforcement** (`cf1d418`, `e5344d5`)
   - Receiver-side: `drop_halfduplex` if rcv has any in-flight TX overlapping incoming packet airtime
   - Sender-side: `tx_deferred reason=self_tx_in_flight` if same node has in-flight TX when registering a new one
   - `SimRadio::notifyRxStart` now wired from the loop (defense in depth — the in-flight ground-truth check is the actual enforcement)

6. **Visualize timing** (commits earlier in session) — receivers light up at TX-start (signal propagation is essentially instantaneous), not at packet-end. Both `visualize.html` swim-lane and `map_live.html` animation use `time_ms - airtime_ms` for rx-like events.

7. **Script-side packet annotations** (`7da0ea8`, earlier session)
   - `self:tx(bytes, {label="RTS", info="dst=dave next=bob msg=1"})` — runtime stamps `label`/`info` on the `tx` event
   - Visualizer shows label on the tx block; rx bars inherit via `pkt`-keyed lookup
   - `dv_dual_sf.lua` annotates every TX (BCN, RTS, CTS, DATA, RTS-fwd, RTS-rty, CTS-dup)

## Webapp — DONE

Two phases complete:

### Phase 1 (WT1–WT11): tracking + REPL
6 pages — `index`, `simulations`, `simulation`, `visualize`, `map_live`, `interactive` — all wired to backend (FastAPI + 4 services + 2 routers + WebSocket REPL). 26/26 backend tests pass including a CLI-vs-webapp event-type-parity smoke test.

### Phase 2: topology authoring (`3c2170b` + `9b3fcb7`)
- Backend: `topo_generator.py` (pure-Python log-distance + haversine, formula matches C++ within 0.1 dB), `topo_tools.py`, `routers/topologies.py`, `routers/topo_creator.py`. CRUD + preview-snr + generate-grid + generate-random.
- Frontend: `topologies.html`, `topology_creator.html` (Leaflet placement, SNR preview with green/yellow/amber/red coloring), `topology_editor.html` (drag markers, edit path-loss). 10 new backend tests; 36/36 total now.
- `simulation.html` accepts loading from a saved topology.

### Webapp run

```bash
cmake -S . -B build && cmake --build build --target lus
cd webapp
pip install -r requirements.txt
bash run.sh   # uvicorn on :8000
```

Or via Docker (see `webapp/ARCHITECTURE.md`).

### Webapp directory layout

```
webapp/
├── ARCHITECTURE.md
├── Dockerfile, docker-compose.yml
├── requirements.txt, run.sh
├── server/
│   ├── main.py            FastAPI app + lifespan (sim_manager, interactive_manager, event_cache)
│   ├── config.py          Settings (DATA_DIR, ORCHESTRATOR_PATH, LUS_CWD, ...)
│   ├── routers/           simulations, interactive, topologies, topo_creator
│   ├── services/          sim_manager, event_index, interactive_manager,
│   │                      config_validator, topo_generator, topo_tools
│   └── models/schemas.py  pydantic v2 lus schema (matches CONFIG_FORMAT.md)
├── static/
│   ├── index.html, simulations.html, simulation.html, visualize.html,
│   │   map_live.html, interactive.html, topologies.html,
│   │   topology_creator.html, topology_editor.html
│   ├── css/common.css
│   └── js/api.js
└── tests/                 36 pytest tests
```

## Documentation

- `docs/CONFIG_FORMAT.md` — comprehensive JSON scenario reference (authored 2026-05-06)
- `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md` — Y1 design
- `docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md` — s01 scenario design (note: spec still says 100 ms timeout, current code defaults 500 ms — minor staleness)
- `docs/superpowers/specs/2026-05-06-webapp-adaptation-design.md` — webapp design
- `docs/Y2-todos.md` — deferred follow-ups (most items now closed; see "Outstanding" below)
- `webapp/ARCHITECTURE.md` — webapp architecture overview

## Outstanding / Future work

User explicitly flagged for next session: **"porting webapp"** and **"verification of simulation quality"**. Status of each:

### Webapp porting — what's left?

The webapp is feature-complete relative to the original spec + topology
authoring next-phase. Possible polish work:
- The map_live.html bottom-strip iframe is functional but could be tighter — e.g., synchronize cursor between map animation and visualize.html iframe scrubber
- Sweep page (parameter sweeps) is dropped per spec; could be revived if needed
- No headless browser tests — only manual exercise
- Performance under heavy traffic (large topologies) has not been profiled

If "porting webapp" means more pages or features, the natural next batch is:
- A "Scenarios" library page (drop scenarios from `scenarios/` directory and let user browse/run them in one click)
- A "Compare runs" page (overlay two sims' events for diff analysis)
- Live event streaming during a running sim (currently `/api/sims/{id}/stream` only carries progress, not raw events — would need sim_manager to broadcast every NDJSON line; significant)

### Simulation-quality verification — what's left?

Recent fixes closed the user-visible gaps; these remain as known limits:

- **Sub-millisecond clock** — `step_ms=1` is the hard minimum. Sub-symbol collision precision (two SF7 TXes overlapping by 0.3 ms rounding to "no overlap") needs a µs-clock refactor. **Substantial** (~30 files); see CONFIG_FORMAT.md `simulation.step_ms` note. Not blocking current scenarios.
- **Per-link fading** (`snr_std_dev` / `snr_coherence_ms`) — wired in delivery but not heavily exercised by current scenarios.
- **`tx_fail_prob`** plumbing — Y2-todos #4. Field is parsed but never consulted at TX-time.
- **`node_stats`** event — Y2-todos #6. EventLog has the entry point but Loop never calls it at sim-end.
- **Hardware turnaround delays** (`rx_to_tx_delay_ms`, `tx_to_rx_delay_ms`) — sub-ms; below `step_ms=1` resolution. Field accepted but ignored.
- **Concurrent flights** (multi-source data, rare in s01) — the busy-receiver `rts_rejected_busy` path exists; needs scenario B or C to exercise it under load.

### Scenarios

- `scenarios/s01_dv_dual_sf.json` — only authored scenario; user has been iterating on it. Note user added a second `send dave hello-world` command at t=38000ms; both deliveries succeed.
- Scenario B (small mesh, 6-10 nodes) — design referenced in s01 spec but not started.
- R.3 (Centelles paper reproduction) — explicitly deferred.

### dv_dual_sf.lua protocol gaps

Things the protocol doesn't yet do (visible as TODOs in the code):
- `start_dance` factoring — `on_command` and forward branch share ~16 lines; flagged for refactor when scenario B forces a signature change for retry semantics.
- DATA retry — currently if DATA is lost (vs CTS), there's no recovery. Receiver's `pending_rx` stays set forever. Out of scope per the original spec; needs a pending_rx expiry timer.
- End-to-end ack — destination sends nothing back to originator. Out of scope.

## Recent open files / locations the next session likely needs

- `scenarios/dv_dual_sf.lua` — currently being iterated on (user just bumped `rts_timeout_ms` to 500)
- `scenarios/s01_dv_dual_sf.json` — user added a second send command
- `webapp/static/visualize.html` and `map_live.html` — recent UI polish
- `core/events/EventLog.{h,cpp}` — `tx` now takes optional `label` and `info` chars
- `orchestrator/runtime/SimController.cpp` — half-duplex check at line ~530 (rcv_was_tx), self_tx_in_flight check at line ~660, notifyRxStart in TX-register loop ~785

## How to resume

1. Cwd to `/home/staszek/lora-universal-simulator/`. The MeshCore-stachuman directory is unrelated.
2. Verify the world is sane: `cmake --build build -j && bash test/run_tests.sh && cd webapp && python -m pytest tests/` — all green = nothing regressed since handoff.
3. Read this file + `docs/CONFIG_FORMAT.md` + the most recent commit messages (`git log --oneline | head -25`) for context.
4. The user's likely next ask: scenario B, or webapp polish, or a sub-ms clock refactor — they will say.
