#!/usr/bin/env python3
"""R3 dm_delivery differential — run a base scenario under the Lua engine
(REFERENCE) and the meshroute engine, and compare message DELIVERY.

The R3 gate (decision Q2) is per-message ARRIVED parity: the set of delivered
(dst, payload) must MATCH lua-vs-meshroute, on a scenario where the deferred MAC
features (LBT/NACK/cascade) don't fire (idle + lossless). It also shells out to
the canonical tools/dm_delivery_breakdown.py for the human-readable funnel.

Usage:
    tools/dm_diff.py scenarios/r3_data_diff.json [--build build]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import defaultdict


def make_variant(base, engine):
    s = json.loads(json.dumps(base))
    for node in s["nodes"]:
        node.pop("engine", None)
        node.pop("script", None)
        if engine == "lua":
            node["script"] = "scenarios/dv_dual_sf.lua"
        else:
            node["engine"] = "meshroute"
    return s


def run_lus(lus, scenario_path, ndjson_path):
    subprocess.run([lus, scenario_path, ndjson_path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def delivered_set(ndjson_path):
    """{(dst, payload): count} from `delivered` events — the headline metric."""
    out = defaultdict(int)
    with open(ndjson_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "script_emit" and ev.get("emit_type") == "delivered":
                d = ev.get("data", {}) or {}
                out[(d.get("dst"), d.get("payload"))] += 1
    return out


def funnel(ndjson_path):
    c = defaultdict(int)
    with open(ndjson_path) as f:
        for line in f:
            try:
                ev = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if ev.get("type") == "script_emit":
                et = ev.get("emit_type")
                if et in ("tx_enqueue", "rts_tx", "cts_rx", "data_tx", "data_rx", "ack_rx", "delivered"):
                    c[et] += 1
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--build", default="build")
    args = ap.parse_args()
    lus = os.path.join(args.build, "orchestrator", "lus")
    if not os.path.exists(lus):
        print(f"ERROR: lus not found at {lus}", file=sys.stderr); sys.exit(2)
    with open(args.scenario) as f:
        base = json.load(f)

    res = {}
    with tempfile.TemporaryDirectory() as td:
        for engine in ("lua", "meshroute"):
            sp = os.path.join(td, f"{engine}.json")
            np = os.path.join(td, f"{engine}.ndjson")
            with open(sp, "w") as f:
                json.dump(make_variant(base, engine), f)
            run_lus(lus, sp, np)
            res[engine] = {"delivered": delivered_set(np), "funnel": funnel(np)}

    lua, mr = res["lua"], res["meshroute"]
    print(f"{'event':>11}  {'lua':>4} {'meshroute':>9}")
    print("-" * 28)
    for et in ("tx_enqueue", "rts_tx", "cts_rx", "data_tx", "data_rx", "ack_rx", "delivered"):
        print(f"{et:>11}  {lua['funnel'].get(et,0):>4} {mr['funnel'].get(et,0):>9}")
    print()
    lset, mset = lua["delivered"], mr["delivered"]
    all_keys = sorted(set(lset) | set(mset), key=lambda k: (str(k[0]), str(k[1])))
    ok = True
    for k in all_keys:
        match = lset.get(k, 0) == mset.get(k, 0) and lset.get(k, 0) > 0
        ok = ok and match
        print(f"  delivered dst={k[0]} payload={k[1]!r}: lua={lset.get(k,0)} meshroute={mset.get(k,0)}  "
              f"{'OK' if match else 'DIFF'}")
    if not all_keys:
        ok = False
        print("  (no delivered messages on either engine)")
    print()
    if ok:
        print("R3 dm_delivery DIFFERENTIAL: PASS — delivered (dst,payload) set matches the Lua reference.")
        sys.exit(0)
    print("R3 dm_delivery DIFFERENTIAL: REGRESSION vs the Lua reference — investigate.")
    sys.exit(1)


if __name__ == "__main__":
    main()
