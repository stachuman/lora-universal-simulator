#!/usr/bin/env python3
"""Generate a manageable Seattle mobile-endpoint realism scenario.

The scenario starts from the existing lifecycle cold-start baseline and adds
three mobile endpoints. Static-static links remain from the explicit topology;
links touching mobile nodes are computed by the path-loss model.

Run:
    python3 tools/gen_mobile_realistic.py
    tools/analyze.py scenarios/s07_seattle_mobile_realistic.json --run
"""

from __future__ import annotations

import argparse
import copy
import json
from collections import Counter
from pathlib import Path


PATH_LOSS_MOBILE_ONLY = {
    "model": "log_distance",
    "mobile_only": True,
    "alpha": 3.0,
    "sigma_db": 1.0,
    "ref_distance_m": 1.0,
    "ref_loss_db": 40.0,
    "noise_floor_db": -120.0,
    "tx_power_dbm": 14.0,
    "node_tx_offset_sigma_db": 1.0,
    "node_rx_offset_sigma_db": 1.0,
    "asymmetry_coherence_ms": 60000,
}


MOBILE_NODE_CONFIG = {
    "beacon_period_ms": 900000,
    "routing_sf": 8,
    "allowed_data_sfs": [7, 9, 10],
    "is_mobile": True,
    "discovery_min_routes": 2,
    "req_sync_min_routes": 2,
    "sync_response_requester_mobile_penalty_ms": 2500,
}


MOBILE_NODES = [
    {
        "name": "mobile_walk_central",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.590000,
        "lon": -122.302000,
        "config": MOBILE_NODE_CONFIG,
        "velocity_mps": 1.35,
        "direction_deg": 35.0,
    },
    {
        "name": "mobile_bike_west_east",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.631000,
        "lon": -122.337000,
        "config": MOBILE_NODE_CONFIG,
        "velocity_mps": 3.4,
        "direction_deg": 90.0,
    },
    {
        "name": "mobile_courier_south_north",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.519000,
        "lon": -122.268000,
        "config": MOBILE_NODE_CONFIG,
        "start_at_ms": 900000,
        "velocity_mps": 5.0,
        "direction_deg": 0.0,
    },
]


def make_command(at_ms: int, origin: str, dst: str, seq: int) -> dict:
    return {
        "at_ms": at_ms,
        "node": origin,
        "command": f"send_e2e {dst} m{seq} {origin}->{dst}",
    }


def add_mobile_workload(cfg: dict, duration_ms: int) -> None:
    stable_peers = [
        "dmatestbednode0",
        "University_District",
        "Capitol_Hill_Prime",
        "CrossNet_Room",
        "devhackchat",
        "Central_District",
        "Fremont01_KF7EGZ_Sol",
        "RavennaEckstein_CC",
        "N7GRN5_Portage_Bay_r",
        "bob",
        "dave",
    ]
    present = {n["name"] for n in cfg["nodes"]}
    stable_peers = [p for p in stable_peers if p in present]
    if len(stable_peers) < 4:
        raise SystemExit("source scenario does not contain enough stable peers")

    seq = 0
    commands = list(cfg.get("commands", []))
    mobile_names = [n["name"] for n in MOBILE_NODES]

    # Regular mobile telemetry uplinks plus occasional downlinks. Commands are
    # intentionally sparse enough that mobility/discovery, not user load, is the
    # dominant variable.
    for at_ms in range(600000, duration_ms - 120000, 300000):
        for idx, mobile in enumerate(mobile_names):
            start = int(MOBILE_NODES[idx].get("start_at_ms", 0) or 0)
            if at_ms < start + 90000:
                continue
            peer = stable_peers[(at_ms // 300000 + idx * 3) % len(stable_peers)]
            seq += 1
            commands.append(make_command(at_ms + idx * 12000, mobile, peer, seq))

            # Downlink after the uplink has had time to refresh discovery.
            down_at = at_ms + 90000 + idx * 12000
            if down_at < duration_ms - 60000:
                seq += 1
                commands.append(make_command(down_at, peer, mobile, seq))

    # A few direct mobile-to-mobile probes; these should work only when the
    # moving endpoints happen to be mutually reachable.
    pair_probes = [
        (1500000, "mobile_walk_central", "mobile_bike_west_east"),
        (2100000, "mobile_bike_west_east", "mobile_courier_south_north"),
        (2700000, "mobile_courier_south_north", "mobile_walk_central"),
    ]
    for at_ms, origin, dst in pair_probes:
        if at_ms < duration_ms - 60000:
            seq += 1
            commands.append(make_command(at_ms, origin, dst, seq))

    commands.sort(key=lambda c: (c["at_ms"], c["node"], c["command"]))
    cfg["commands"] = commands


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="scenarios/s06_seattle_bcn_lifecycle_mid.json")
    p.add_argument("--out", default="scenarios/s07_seattle_mobile_realistic.json")
    p.add_argument("--duration-ms", type=int, default=3_600_000)
    p.add_argument("--seed", type=int, default=107)
    args = p.parse_args()

    src_path = Path(args.src)
    with src_path.open() as f:
        cfg = json.load(f)

    out_cfg = copy.deepcopy(cfg)
    out_path = Path(args.out)
    out_cfg["_name"] = out_path.stem
    out_cfg["_desc"] = (
        "Seattle realistic mobile-endpoint scenario derived from "
        f"{src_path.name}. Cold-start static lifecycle remains enabled. "
        "Adds walking, bike/cross-town, and late-start courier mobile endpoints. "
        "Mobiles discover with Q/REQ_SYNC, do not emit normal periodic BCN, and "
        "must not be used as mesh transit nodes. Static-static links stay from "
        "the explicit topology; links touching mobile nodes use path loss."
    )
    out_cfg["simulation"]["duration_ms"] = args.duration_ms
    out_cfg["simulation"]["warmup_ms"] = 0
    out_cfg["simulation"]["seed"] = args.seed
    out_cfg["simulation"]["path_loss"] = PATH_LOSS_MOBILE_ONLY

    existing = {n["name"] for n in out_cfg["nodes"]}
    duplicate = existing & {n["name"] for n in MOBILE_NODES}
    if duplicate:
        raise SystemExit("mobile node name collision: " + ", ".join(sorted(duplicate)))
    out_cfg["nodes"] = list(out_cfg["nodes"]) + copy.deepcopy(MOBILE_NODES)

    add_mobile_workload(out_cfg, args.duration_ms)
    out_cfg["expect"] = []

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(out_cfg, f, indent=2)
        f.write("\n")

    verbs = Counter(c["command"].split()[0] for c in out_cfg["commands"])
    mobile_commands = [
        c for c in out_cfg["commands"]
        if c["node"].startswith("mobile_") or " mobile_" in c["command"]
    ]
    print(f"# wrote {out_path}")
    print(f"# nodes: static={len(out_cfg['nodes']) - len(MOBILE_NODES)} mobile={len(MOBILE_NODES)} total={len(out_cfg['nodes'])}")
    print(f"# duration: {args.duration_ms} ms ({args.duration_ms // 60000} min)")
    print(f"# commands: {len(out_cfg['commands'])} mobile_related={len(mobile_commands)} verbs={dict(verbs)}")
    print("# mobile nodes: " + ", ".join(n["name"] for n in MOBILE_NODES))


if __name__ == "__main__":
    main()
