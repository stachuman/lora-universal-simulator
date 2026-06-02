#!/usr/bin/env python3
"""S3 differential gate (R1) — run a base scenario under the Lua engine
(REFERENCE) and the meshroute engine, and compare beacon-plane behaviour.

Metric-level, NOT timestamp-exact (beacon ±20% jitter makes exact timing
fragile). Per node it compares:
  * converged route SET  — {dest} seen in rt_update  (MUST match)
  * rt_full peers        — convergence signal         (MUST match, or both absent)
  * beacon_tx count      — emission cadence            (within --tol)

A node that DIFFs is a measured regression of the C++ port vs the Lua reference
and is the trigger to investigate. This is the R1 "S3 differential" secondary
gate; the primary gate is the t84 t-test (self-contained, no diff tool).

Usage:
    tools/s3_diff.py scenarios/r1_beacon_diff.json [--build build] [--tol 2]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import defaultdict


def make_variant(base, engine):
    s = json.loads(json.dumps(base))  # deep copy
    for node in s["nodes"]:
        node.pop("engine", None)
        node.pop("script", None)
        if engine == "lua":
            node["script"] = "scenarios/dv_dual_sf.lua"   # script => Lua engine
        else:
            node["engine"] = "meshroute"
    return s


def run_lus(lus, scenario_path, ndjson_path):
    subprocess.run([lus, scenario_path, ndjson_path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _fresh():
    return {"beacon_tx": 0, "dests": set(), "rt_full_peers": None,
            "rt_aged": set(), "rt_prune": set(), "discovery_exits": 0,
            "dirty_sum": 0, "stable_sum": 0}


def parse_metrics(ndjson_path):
    m = defaultdict(_fresh)
    with open(ndjson_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") != "script_emit":
                continue
            node = ev.get("node")
            et = ev.get("emit_type")
            data = ev.get("data", {}) or {}
            if et == "beacon_tx":
                m[node]["beacon_tx"] += 1
            elif et == "rt_update" and "dest" in data:
                m[node]["dests"].add(data["dest"])
            elif et == "rt_full":
                m[node]["rt_full_peers"] = data.get("peers")
            elif et == "rt_aged" and "dest" in data:                # R2
                m[node]["rt_aged"].add(data["dest"])
            elif et == "rt_prune" and "dest" in data:               # R2
                m[node]["rt_prune"].add(data["dest"])
            elif et == "bcn_discovery_exit":                        # R2
                m[node]["discovery_exits"] += 1
            elif et == "beacon_diff_breakdown":                     # R2
                m[node]["dirty_sum"] += data.get("dirty_n", 0)
                m[node]["stable_sum"] += data.get("stable_n", 0)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--build", default="build")
    ap.add_argument("--tol", type=int, default=2,
                    help="allowed |beacon_tx| delta per node (jitter tolerance)")
    args = ap.parse_args()

    lus = os.path.join(args.build, "orchestrator", "lus")
    if not os.path.exists(lus):
        print(f"ERROR: lus not found at {lus}", file=sys.stderr)
        sys.exit(2)

    with open(args.scenario) as f:
        base = json.load(f)

    results = {}
    with tempfile.TemporaryDirectory() as td:
        for engine in ("lua", "meshroute"):
            variant = make_variant(base, engine)
            spath = os.path.join(td, f"{engine}.json")
            npath = os.path.join(td, f"{engine}.ndjson")
            with open(spath, "w") as f:
                json.dump(variant, f)
            run_lus(lus, spath, npath)
            results[engine] = parse_metrics(npath)

    lua, mr = results["lua"], results["meshroute"]
    nodes = sorted(set(lua) | set(mr))
    ok = True
    # MUST-match = deterministic events (route SET, eviction/prune SET, convergence,
    # discovery-exit count). Within-tol = jitter/cadence (beacon_tx, dirty/stable
    # sums). Per-beacon n_entries is NOT compared — dirty-only changes it by design.
    print(f"{'node':>4}  beacon_tx   dests        rt_aged   rt_prune  disc  rt_full   verdict")
    print("-" * 84)
    for n in nodes:
        l, m = lua.get(n, _fresh()), mr.get(n, _fresh())
        checks = [
            ("dests",      set(l["dests"])    == set(m["dests"])),
            ("rt_aged",    set(l["rt_aged"])  == set(m["rt_aged"])),
            ("rt_prune",   set(l["rt_prune"]) == set(m["rt_prune"])),
            ("rt_full",    l["rt_full_peers"] == m["rt_full_peers"]),
            ("disc_exit",  l["discovery_exits"] == m["discovery_exits"]),
            ("beacon_tx",  abs(l["beacon_tx"]  - m["beacon_tx"])  <= args.tol),
            ("dirty_sum",  abs(l["dirty_sum"]  - m["dirty_sum"])  <= args.tol),
            ("stable_sum", abs(l["stable_sum"] - m["stable_sum"]) <= args.tol),
        ]
        node_ok = all(v for _, v in checks)
        ok = ok and node_ok
        fails = ",".join(k for k, v in checks if not v)
        verdict = "OK" if node_ok else f"DIFF[{fails}]"
        print(f"{n:>4}  {l['beacon_tx']:>3}/{m['beacon_tx']:<3}  "
              f"{str(sorted(l['dests'])):>11}  {str(sorted(l['rt_aged'])):>8}  "
              f"{str(sorted(l['rt_prune'])):>8}  {l['discovery_exits']}/{m['discovery_exits']}   "
              f"{str(l['rt_full_peers'])}/{str(m['rt_full_peers']):<4}  {verdict}")

    print()
    if ok:
        print("S3 DIFFERENTIAL: PASS — route/aged/prune SETs + rt_full + discovery-exit "
              f"match the Lua reference; beacon_tx/dirty/stable within tol={args.tol}.")
        sys.exit(0)
    print("S3 DIFFERENTIAL: REGRESSION vs the Lua reference — investigate.")
    sys.exit(1)


if __name__ == "__main__":
    main()
