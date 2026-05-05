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
