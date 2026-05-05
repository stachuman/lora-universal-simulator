# lora-universal-simulator

Host-side network simulator for LoRa-mesh protocol research. Each node's
behavior is defined in Lua; the simulator provides radio physics, topology,
and an event stream.

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
bash test/run_tests.sh test/t01_flooder.json   # JSON regression test
bash test/native/build_test.sh                 # C++ unit tests
```

## Performance benchmark

200-node x 1 h smoke test (no script work, just runtime overhead):

```bash
python3 tools/gen_grid.py > test/t99_perf_smoke.json
time ./build/orchestrator/lus test/t99_perf_smoke.json /dev/null
```

Last measured: real 0m5.9s (user 5.9s / sys 0.0s) on AMD EPYC 7402P
24-Core (Linux 6.8, Release build, vanilla Lua 5.4). Comfortably
under the 5-minute Y1 target.
