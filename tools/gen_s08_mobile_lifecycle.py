#!/usr/bin/env python3
"""Generate the s08 Seattle mobile+lifecycle policy scenario.

This scenario is intended to sit between the quick s07 mobile run and the
large s04 realistic baseline:

* 2 h duration, no warmup/hot-start.
* 45 initial static nodes, 8 static joiners, 8 static departures.
* 4 endpoint-only mobile nodes crossing the map on different axes.
* Moderate traffic so late budget collapse is visible without s04-scale
  analysis cost.

Run:
    python3 tools/gen_s08_mobile_lifecycle.py
    tools/multiseed_summary.py scenarios/s08_seattle_mobile_lifecycle_2h.json --runs 5 --seed-start 107
"""

from __future__ import annotations

import argparse
import copy
import json
import random
from collections import Counter
from pathlib import Path

import gen_lifecycle_coldstart as lifecycle


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
        "lat": 47.596000,
        "lon": -122.334000,
        "config": MOBILE_NODE_CONFIG,
        "velocity_mps": 1.2,
        "direction_deg": 35.0,
    },
    {
        "name": "mobile_bike_west_east",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.625000,
        "lon": -122.386000,
        "config": MOBILE_NODE_CONFIG,
        "velocity_mps": 2.0,
        "direction_deg": 88.0,
    },
    {
        "name": "mobile_courier_south_north",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.515000,
        "lon": -122.300000,
        "config": MOBILE_NODE_CONFIG,
        "start_at_ms": 1200000,
        "velocity_mps": 1.7,
        "direction_deg": 2.0,
    },
    {
        "name": "mobile_diag_ne_sw",
        "script": "scenarios/dv_dual_sf.lua",
        "lat": 47.692000,
        "lon": -122.246000,
        "config": MOBILE_NODE_CONFIG,
        "start_at_ms": 2400000,
        "velocity_mps": 1.9,
        "direction_deg": 224.0,
    },
]


STABLE_PEER_HINTS = [
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
    "The_Winchester_Repea",
    "WedgBreadMesh",
    "Crow_Repeater",
]


def make_command(at_ms: int, origin: str, dst: str, verb: str, tag: str, seq: int) -> dict:
    return {
        "at_ms": at_ms,
        "node": origin,
        "command": f"{verb} {dst} {tag}{seq} {origin}->{dst}",
    }


def alive_at_by_name(nodes_by_name: dict[str, dict], name: str, at_ms: int) -> bool:
    node = nodes_by_name.get(name)
    if node is None:
        return False
    return lifecycle.alive_at(node, at_ms)


def build_static_base(args: argparse.Namespace) -> tuple[dict, list[str], list[str], list[str]]:
    rng = random.Random(args.seed)
    src_path = Path(args.src)
    with src_path.open() as f:
        cfg = json.load(f)

    all_nodes = {n["name"]: n for n in cfg["nodes"]}
    links = cfg.get("topology", {}).get("links", [])
    adj = lifecycle.build_adjacency(links)
    names = lifecycle.largest_connected_component(set(all_nodes), adj)
    if not names:
        raise SystemExit("source topology has no connected nodes")

    initial = lifecycle.choose_initial_nodes(names, adj, args.initial_nodes)
    joiners = lifecycle.choose_joiners(names, adj, initial, args.join_nodes)
    dying = lifecycle.choose_dying_nodes(initial, adj, args.die_nodes, rng)

    selected = set(initial) | set(joiners)
    join_times = dict(zip(
        joiners,
        lifecycle.spread_times(args.join_start_ms, args.join_window_ms, len(joiners), rng),
    ))
    die_times = dict(zip(
        dying,
        lifecycle.spread_times(args.die_start_ms, args.die_window_ms, len(dying), rng),
    ))
    initial_times = dict(zip(
        initial,
        lifecycle.spread_times(0, args.initial_start_window_ms, len(initial), rng),
    ))

    out_nodes: list[dict] = []
    for src_node in cfg["nodes"]:
        node_name = src_node["name"]
        if node_name not in selected:
            continue
        node = copy.deepcopy(src_node)
        if node_name in initial_times and initial_times[node_name] > 0:
            node["start_at_ms"] = initial_times[node_name]
        if node_name in join_times:
            node["start_at_ms"] = join_times[node_name]
        if node_name in die_times:
            node["dies_at_ms"] = die_times[node_name]
        out_nodes.append(node)

    out_links = [
        copy.deepcopy(link)
        for link in links
        if link.get("from") in selected and link.get("to") in selected
    ]
    selected_comps = lifecycle.connected_components(
        selected, lifecycle.build_adjacency(out_links))
    if len(selected_comps) != 1:
        raise SystemExit(
            "generated static scenario is disconnected: "
            + ", ".join(str(len(c)) for c in selected_comps)
        )

    out_cfg = copy.deepcopy(cfg)
    out_cfg["simulation"]["duration_ms"] = args.duration_ms
    out_cfg["simulation"]["warmup_ms"] = 0
    out_cfg["simulation"]["node_startup_jitter_ms"] = 0
    out_cfg["simulation"]["seed"] = args.seed
    out_cfg["nodes"] = out_nodes
    out_cfg["topology"]["links"] = out_links
    out_cfg["commands"] = lifecycle.build_commands(
        out_nodes,
        initial,
        joiners,
        dying,
        args.duration_ms,
        args.traffic_start_ms,
        args.mean_traffic_gap_ms,
        rng,
    )
    out_cfg["expect"] = []
    return out_cfg, initial, joiners, dying


def add_mobile_workload(cfg: dict, duration_ms: int, seed: int) -> None:
    rng = random.Random(seed + 1701)
    nodes_by_name = {n["name"]: n for n in cfg["nodes"]}
    stable_peers = [
        name for name in STABLE_PEER_HINTS
        if name in nodes_by_name and not nodes_by_name[name].get("dies_at_ms")
    ]
    if len(stable_peers) < 6:
        stable_peers = [
            n["name"] for n in cfg["nodes"]
            if not n["name"].startswith("mobile_") and not n.get("dies_at_ms")
        ][:10]
    if len(stable_peers) < 4:
        raise SystemExit("not enough stable peers for mobile workload")

    commands = list(cfg.get("commands", []))
    seq_by_origin: Counter[str] = Counter()
    for cmd in commands:
        parts = cmd.get("command", "").split()
        if len(parts) >= 3:
            seq_by_origin[cmd.get("node", "")] += 1

    mobile_names = [n["name"] for n in MOBILE_NODES]
    end_cap_ms = duration_ms - 90000

    # Regular mobile uplinks/downlinks. Keep the interval broad enough that
    # mobile reachability and network budget, not raw load, dominate the result.
    for at_ms in range(900000, end_cap_ms, 360000):
        for idx, mobile in enumerate(mobile_names):
            mobile_node = nodes_by_name[mobile]
            start = int(mobile_node.get("start_at_ms", 0) or 0)
            if at_ms < start + 120000:
                continue
            peer = stable_peers[(at_ms // 360000 + idx * 3) % len(stable_peers)]
            if not alive_at_by_name(nodes_by_name, peer, at_ms):
                continue
            seq_by_origin[mobile] += 1
            commands.append(make_command(
                at_ms + idx * 15000, mobile, peer, "send_e2e", "m", seq_by_origin[mobile]))

            down_at = at_ms + 120000 + idx * 15000
            if down_at < end_cap_ms and alive_at_by_name(nodes_by_name, peer, down_at):
                seq_by_origin[peer] += 1
                commands.append(make_command(
                    down_at, peer, mobile, "send_e2e", "m", seq_by_origin[peer]))

    # Mobile-to-mobile probes are sparse and intentionally opportunistic.
    probes = [
        (1800000, "mobile_walk_central", "mobile_bike_west_east"),
        (3000000, "mobile_bike_west_east", "mobile_courier_south_north"),
        (4200000, "mobile_courier_south_north", "mobile_diag_ne_sw"),
        (5400000, "mobile_diag_ne_sw", "mobile_walk_central"),
        (6300000, "mobile_walk_central", "mobile_courier_south_north"),
    ]
    for at_ms, origin, dst in probes:
        if at_ms < end_cap_ms and alive_at_by_name(nodes_by_name, origin, at_ms):
            seq_by_origin[origin] += 1
            commands.append(make_command(at_ms, origin, dst, "send_e2e", "x", seq_by_origin[origin]))

    # Join/death pressure with mobiles as endpoints, to expose discovery gaps
    # without letting mobiles become transit.
    static_names = [n["name"] for n in cfg["nodes"] if not n["name"].startswith("mobile_")]
    joiners = [n for n in static_names if int(nodes_by_name[n].get("start_at_ms", 0) or 0) >= 600000]
    for joiner in joiners[:5]:
        start = int(nodes_by_name[joiner].get("start_at_ms", 0) or 0)
        mobile = rng.choice(mobile_names)
        if alive_at_by_name(nodes_by_name, mobile, start + 240000):
            seq_by_origin[joiner] += 1
            commands.append(make_command(
                start + 240000, joiner, mobile, "send_e2e", "jm", seq_by_origin[joiner]))

    commands.sort(key=lambda c: (c["at_ms"], c["node"], c["command"]))
    cfg["commands"] = commands


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="scenarios/s03_seattle_medium.json")
    p.add_argument("--out", default="scenarios/s08_seattle_mobile_lifecycle_2h.json")
    p.add_argument("--seed", type=int, default=808)
    p.add_argument("--duration-ms", type=int, default=7200000)
    p.add_argument("--initial-nodes", type=int, default=45)
    p.add_argument("--join-nodes", type=int, default=8)
    p.add_argument("--die-nodes", type=int, default=8)
    p.add_argument("--initial-start-window-ms", type=int, default=60000)
    p.add_argument("--join-start-ms", type=int, default=1800000)
    p.add_argument("--join-window-ms", type=int, default=1200000)
    p.add_argument("--die-start-ms", type=int, default=3300000)
    p.add_argument("--die-window-ms", type=int, default=1800000)
    p.add_argument("--traffic-start-ms", type=int, default=30000)
    p.add_argument("--mean-traffic-gap-ms", type=int, default=28000)
    args = p.parse_args()

    cfg, initial, joiners, dying = build_static_base(args)
    existing = {n["name"] for n in cfg["nodes"]}
    duplicates = existing & {n["name"] for n in MOBILE_NODES}
    if duplicates:
        raise SystemExit("mobile node name collision: " + ", ".join(sorted(duplicates)))
    cfg["nodes"] = list(cfg["nodes"]) + copy.deepcopy(MOBILE_NODES)
    cfg["simulation"]["path_loss"] = PATH_LOSS_MOBILE_ONLY
    cfg["_name"] = Path(args.out).stem
    cfg["_desc"] = (
        "Seattle s08 mobile+lifecycle policy scenario. No warmup/hot-start. "
        f"{len(initial)} initial static nodes, {len(joiners)} static joiners, "
        f"{len(dying)} static departures, and {len(MOBILE_NODES)} endpoint-only "
        "mobiles crossing the map. Static-static links stay explicit; links "
        "touching mobiles use path loss. Purpose: compare routing/budget "
        "policy changes over longer late-run pressure without s04-scale cost."
    )
    add_mobile_workload(cfg, args.duration_ms, args.seed)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")

    verbs = Counter(c["command"].split()[0] for c in cfg["commands"])
    tags = Counter(c["command"].split()[2][0] for c in cfg["commands"])
    mobile_commands = [
        c for c in cfg["commands"]
        if c["node"].startswith("mobile_") or " mobile_" in c["command"]
    ]
    print(f"# wrote {out_path}")
    print(
        f"# nodes: initial={len(initial)} joiners={len(joiners)} "
        f"dying={len(dying)} mobile={len(MOBILE_NODES)} total={len(cfg['nodes'])}")
    print(f"# links: {len(cfg['topology']['links'])}")
    print(f"# duration: {args.duration_ms} ms ({args.duration_ms // 60000} min)")
    print(f"# commands: {len(cfg['commands'])} mobile_related={len(mobile_commands)} verbs={dict(verbs)} tags={dict(tags)}")
    print("# joiners: " + ", ".join(joiners))
    print("# dying: " + ", ".join(dying))
    print("# mobiles: " + ", ".join(n["name"] for n in MOBILE_NODES))


if __name__ == "__main__":
    main()
