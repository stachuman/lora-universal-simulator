# lora-universal-simulator

The purpose of this simulator is to enable testing different scenarios of LoRa
mesh network protocols - to be able to quickly change parameters (even on the fly),
test implementations before putting effort into real low level implementations.

Each node is managed by Lua script - ensuring realistic LoRa radio simulation.



Host-side network simulator for LoRa-mesh protocol research. Each node's
behavior is defined in Lua; the simulator provides radio physics, topology,
and an event stream.


Topology can be specified declaratively two ways:
- **Static link matrix**: `topology.links[]` with explicit SNR/RSSI per pair
- **Geographic deployment**: per-node `lat`/`lon` plus a `simulation.path_loss`
  block (log-distance + log-normal shadowing). Link SNR/RSSI is computed from
  positions at sim init and exposed to scripts via `sim:link_snr(from, to)`.

Single-SF reception is the default (matches real Semtech hardware). Configs
opt into idealized multi-SF reception per node via `nodes[i].sf_rx_set`.
Scripts can retune at runtime with `self:set_rx_sf(sf)` for announce-and-tune
protocols.

See `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md`
for the design.

## Build

```bash
cmake -S . -B build
cmake --build build -j 4
```

## Run

```bash
./build/orchestrator/lus path/to/config.json > events.ndjson
python3 tools/visualize.py events.ndjson
```

## Test

```bash
bash test/native/build_test.sh                 # C++ unit tests (also runs test/t01_flooder.json)
```

The legacy JSON regression corpus (`test/t*.json`, `scenarios/s*.json`) and its
runner `test/run_tests.sh` were **retired 2026-07-25**: the configs stopped
passing `JsonConfig` validation at the 2026-07-21 required-keys change and
nothing gated on them. Delivery/behaviour gating lives in the MeshRoute repo —
`simulation/BASELINE.md` — driven with `lus -e meshroute simulation/<s>.json`.

## Performance benchmark

200-node x 1 h smoke test (no script work, just runtime overhead) — retired
2026-07-25 with the legacy corpus (its generator `tools/gen_grid.py` and the
generated `test/t99_perf_smoke.json` are gone; the generator emitted links
without the now-required `snr_std_dev`).

Last measured: real 0m5.9s (user 5.9s / sys 0.0s) on AMD EPYC 7402P
24-Core (Linux 6.8, Release build, vanilla Lua 5.4). Comfortably
under the 5-minute Y1 target.

## Webapp (live tracking + REPL)

The `webapp/` directory contains an optional FastAPI + vanilla-JS frontend
for live simulation tracking, swim-lane replay, and a browser-driven
interactive REPL. After building the `lus` binary, run:

```bash
cd webapp
pip install -r requirements.txt
bash run.sh
```

Open http://localhost:8000. See `webapp/ARCHITECTURE.md` for details.
