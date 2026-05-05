# tools/gen_grid.py -- generate a NxM grid topology for the perf smoke test.
import json, sys

cols, rows = 20, 10                      # 200 nodes
duration_ms = 3_600_000                  # 1 hour
nodes, links = [], []
for r in range(rows):
    for c in range(cols):
        nodes.append({"name": f"n{r}_{c}", "script": "examples/quiet.lua"})
for r in range(rows):
    for c in range(cols):
        if c + 1 < cols:
            links.append({"from": f"n{r}_{c}", "to": f"n{r}_{c+1}",
                          "snr": 8.0, "rssi": -80.0, "bidir": True})
        if r + 1 < rows:
            links.append({"from": f"n{r}_{c}", "to": f"n{r+1}_{c}",
                          "snr": 8.0, "rssi": -80.0, "bidir": True})
cfg = {
    "_name": "t99_perf_smoke",
    "simulation": {
        "duration_ms": duration_ms,
        "step_ms": 1,
        "warmup_ms": 0,
        "radio": {"sf": 11, "bw": 250, "cr": 5}
    },
    "nodes": nodes,
    "topology": {"links": links},
    "commands": [],
    "expect": []
}
print(json.dumps(cfg, indent=2))

# usage: python3 tools/gen_grid.py > test/t99_perf_smoke.json
