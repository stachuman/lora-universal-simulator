#!/usr/bin/env python3
"""Generate a Seattle cold-start lifecycle scenario.

The default source is scenarios/s03_seattle_medium.json. The generator
keeps a connected-ish subset of the Seattle topology, starts it without
hot-start/warmup, then introduces node births and deaths around the
middle of the run.

Run:
    python3 tools/gen_lifecycle_coldstart.py
    build/orchestrator/lus scenarios/s06_seattle_lifecycle_coldstart.json
    tools/analyze.py scenarios/s06_seattle_lifecycle_coldstart.json --run
"""

from __future__ import annotations

import argparse
import copy
import json
import random
from collections import Counter, defaultdict
from pathlib import Path


CORNER_NAMES = ("alice", "bob", "carol", "dave")


def build_adjacency(links: list[dict]) -> dict[str, set[str]]:
    adj: dict[str, set[str]] = defaultdict(set)
    for link in links:
        a = link.get("from")
        b = link.get("to")
        if not a or not b:
            continue
        adj[a].add(b)
        adj[b].add(a)
    return adj


def connected_components(names: set[str], adj: dict[str, set[str]]) -> list[set[str]]:
    seen: set[str] = set()
    comps: list[set[str]] = []
    for name in sorted(names):
        if name in seen:
            continue
        stack = [name]
        seen.add(name)
        comp: set[str] = set()
        while stack:
            cur = stack.pop()
            comp.add(cur)
            for nxt in adj.get(cur, set()):
                if nxt in names and nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        comps.append(comp)
    comps.sort(key=lambda c: (len(c), sum(len(adj.get(n, ())) for n in c)), reverse=True)
    return comps


def largest_connected_component(names: set[str], adj: dict[str, set[str]]) -> set[str]:
    non_isolated = {n for n in names if len(adj.get(n, set()) & names) > 0}
    comps = connected_components(non_isolated or names, adj)
    return comps[0] if comps else set()


def choose_initial_nodes(
    names: set[str],
    adj: dict[str, set[str]],
    initial_count: int,
) -> list[str]:
    """Choose a compact high-connectivity working set.

    Start from the highest-degree node in the connected source set, then
    grow from the selected frontier. Every added node must touch the current
    selected set, so the induced scenario remains connected. This avoids
    "corner" identities with no links in the chosen Seattle slice.
    """
    degrees = {n: len(adj.get(n, ())) for n in names}
    if not names:
        return []
    selected: list[str] = [max(names, key=lambda n: (degrees.get(n, 0), n))]
    selected_set = set(selected)

    while len(selected) < initial_count and len(selected_set) < len(names):
        candidates = [
            n for n in names
            if n not in selected_set and (adj.get(n, set()) & selected_set)
        ]
        if not candidates:
            break
        best = max(
            candidates,
            key=lambda n: (
                len(adj.get(n, set()) & selected_set),
                degrees.get(n, 0),
                n,
            ),
        )
        selected.append(best)
        selected_set.add(best)

    return selected[:initial_count]


def choose_joiners(
    names: set[str],
    adj: dict[str, set[str]],
    initial: list[str],
    join_count: int,
) -> list[str]:
    selected_set = set(initial)
    out: list[str] = []
    while len(out) < join_count:
        candidates = [
            n for n in names
            if n not in selected_set and (adj.get(n, set()) & selected_set)
        ]
        if not candidates:
            break
        best = max(
            candidates,
            key=lambda n: (
                len(adj.get(n, set()) & selected_set),
                len(adj.get(n, set())),
                n,
            ),
        )
        out.append(best)
        selected_set.add(best)
    return out


def choose_dying_nodes(
    initial: list[str],
    adj: dict[str, set[str]],
    die_count: int,
    rng: random.Random,
) -> list[str]:
    protected = set(CORNER_NAMES)
    candidates = [n for n in initial if n not in protected]
    candidates.sort(key=lambda n: (len(adj.get(n, set())), n), reverse=True)

    # Removing only the absolute hubs can make the scenario too harsh for a
    # first lifecycle baseline. Sample from the top half: important enough to
    # perturb routes, not guaranteed to partition the whole subgraph.
    pool = candidates[: max(die_count, len(candidates) // 2)]
    rng.shuffle(pool)
    return pool[:die_count]


def spread_times(start_ms: int, window_ms: int, count: int, rng: random.Random) -> list[int]:
    if count <= 0:
        return []
    if count == 1:
        return [start_ms + window_ms // 2]
    step = window_ms / count
    times = []
    for i in range(count):
        base = start_ms + int(i * step)
        jitter = rng.randint(0, max(1, int(step * 0.65)))
        times.append(base + jitter)
    return sorted(times)


def alive_at(node: dict, at_ms: int) -> bool:
    start = int(node.get("start_at_ms", 0) or 0)
    dies = int(node.get("dies_at_ms", 0) or 0)
    return at_ms >= start and (dies == 0 or at_ms < dies)


def make_command(at_ms: int, origin: str, dst: str, verb: str, tag: str, seq: int) -> dict:
    return {
        "at_ms": at_ms,
        "node": origin,
        "command": f"{verb} {dst} {tag}{seq} {origin}->{dst}",
    }


def build_commands(
    nodes: list[dict],
    initial_names: list[str],
    join_names: list[str],
    dying_names: list[str],
    duration_ms: int,
    traffic_start_ms: int,
    mean_gap_ms: int,
    rng: random.Random,
) -> list[dict]:
    by_name = {n["name"]: n for n in nodes}
    seq_by_origin: Counter[str] = Counter()
    commands: list[dict] = []

    end_cap_ms = duration_ms - 60_000
    t = traffic_start_ms
    while t < end_cap_ms:
        active = [n["name"] for n in nodes if alive_at(n, t)]
        if len(active) >= 2:
            origin, dst = rng.sample(active, 2)
            verb = "send_e2e" if rng.random() < 0.68 else "send"
            seq_by_origin[origin] += 1
            commands.append(make_command(t, origin, dst, verb, "c", seq_by_origin[origin]))
        t += max(5_000, int(rng.expovariate(1.0 / mean_gap_ms)))

    # New-node registration probes: traffic from and to every joiner shortly
    # after boot. These are the flows we expect REQ_SYNC/full-BCN work to help.
    stable_initial = [n for n in initial_names if n not in dying_names]
    for joiner in join_names:
        start = int(by_name[joiner].get("start_at_ms", 0))
        if not stable_initial:
            continue
        peer1 = rng.choice(stable_initial)
        peer2 = rng.choice(stable_initial)
        for offset, origin, dst, tag in (
            (60_000, joiner, peer1, "j"),
            (140_000, peer2, joiner, "j"),
            (300_000, joiner, rng.choice(stable_initial), "j"),
        ):
            at_ms = start + offset
            if at_ms < end_cap_ms and alive_at(by_name[origin], at_ms):
                seq_by_origin[origin] += 1
                commands.append(make_command(at_ms, origin, dst, "send_e2e", tag, seq_by_origin[origin]))

    # Departure probes: shortly after a node dies, send toward it from an
    # alive node. This exposes stale-route and route-aging behavior without
    # issuing commands from a dead origin.
    for dead in dying_names:
        dies = int(by_name[dead].get("dies_at_ms", 0))
        active_after_death = [
            n["name"]
            for n in nodes
            if n["name"] != dead and alive_at(n, dies + 90_000)
        ]
        if not active_after_death:
            continue
        origin = rng.choice(active_after_death)
        at_ms = dies + 90_000
        if at_ms < end_cap_ms:
            seq_by_origin[origin] += 1
            commands.append(make_command(at_ms, origin, dead, "send_e2e", "d", seq_by_origin[origin]))

    commands.sort(key=lambda c: (c["at_ms"], c["node"], c["command"]))
    return commands


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="scenarios/s03_seattle_medium.json")
    p.add_argument("--out", default="scenarios/s06_seattle_lifecycle_coldstart.json")
    p.add_argument("--seed", type=int, default=77)
    p.add_argument("--duration-ms", type=int, default=7_200_000)
    p.add_argument("--initial-nodes", type=int, default=40)
    p.add_argument("--join-nodes", type=int, default=10)
    p.add_argument("--die-nodes", type=int, default=10)
    p.add_argument("--initial-start-window-ms", type=int, default=60_000)
    p.add_argument("--join-start-ms", type=int, default=3_600_000)
    p.add_argument("--join-window-ms", type=int, default=600_000)
    p.add_argument("--die-start-ms", type=int, default=4_500_000)
    p.add_argument("--die-window-ms", type=int, default=600_000)
    p.add_argument("--traffic-start-ms", type=int, default=30_000)
    p.add_argument("--mean-traffic-gap-ms", type=int, default=22_000)
    args = p.parse_args()

    rng = random.Random(args.seed)
    src_path = Path(args.src)
    with src_path.open() as f:
        cfg = json.load(f)

    all_nodes = {n["name"]: n for n in cfg["nodes"]}
    links = cfg.get("topology", {}).get("links", [])
    adj = build_adjacency(links)
    names = largest_connected_component(set(all_nodes), adj)
    if not names:
        raise SystemExit("source topology has no connected nodes")

    initial = choose_initial_nodes(names, adj, args.initial_nodes)
    joiners = choose_joiners(names, adj, initial, args.join_nodes)
    dying = choose_dying_nodes(initial, adj, args.die_nodes, rng)

    selected = set(initial) | set(joiners)
    join_times = dict(zip(joiners, spread_times(args.join_start_ms, args.join_window_ms, len(joiners), rng)))
    die_times = dict(zip(dying, spread_times(args.die_start_ms, args.die_window_ms, len(dying), rng)))
    initial_times = dict(zip(initial, spread_times(0, args.initial_start_window_ms, len(initial), rng)))

    out_nodes: list[dict] = []
    for name in cfg["nodes"]:
        node_name = name["name"]
        if node_name not in selected:
            continue
        node = copy.deepcopy(name)
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
    out_adj = build_adjacency(out_links)
    selected_comps = connected_components(selected, out_adj)
    if len(selected_comps) != 1:
        raise SystemExit(
            "generated scenario is disconnected: "
            + ", ".join(str(len(c)) for c in selected_comps)
        )

    out_cfg = copy.deepcopy(cfg)
    out_path = Path(args.out)
    out_cfg["_name"] = out_path.stem
    out_cfg["_desc"] = (
        "Seattle lifecycle cold-start baseline generated from s03. "
        f"No warmup/hot-start. {len(initial)} initial nodes boot over "
        f"{args.initial_start_window_ms // 1000}s, {len(joiners)} nodes join "
        f"from {args.join_start_ms // 60000}m, and {len(dying)} initial nodes "
        f"die from {args.die_start_ms // 60000}m. Purpose: observe fresh "
        "network formation, early message delivery, new-node registration, "
        "and stale-route behavior after node departure."
    )
    out_cfg["simulation"]["duration_ms"] = args.duration_ms
    out_cfg["simulation"]["warmup_ms"] = 0
    out_cfg["simulation"]["node_startup_jitter_ms"] = 0
    out_cfg["simulation"]["seed"] = args.seed
    out_cfg["nodes"] = out_nodes
    out_cfg["topology"]["links"] = out_links
    out_cfg["commands"] = build_commands(
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

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(out_cfg, f, indent=2)
        f.write("\n")

    starts = Counter(
        "initial" if n["name"] in initial else "joiner"
        for n in out_nodes
    )
    verbs = Counter(c["command"].split()[0] for c in out_cfg["commands"])
    tags = Counter(c["command"].split()[2][0] for c in out_cfg["commands"])
    print(f"# wrote {out_path}")
    print(f"# nodes: initial={starts['initial']} joiners={starts['joiner']} dying={len(dying)} total={len(out_nodes)}")
    print(f"# links: {len(out_links)}")
    print(f"# connected components: {len(selected_comps)} ({len(selected_comps[0])} nodes)")
    print(f"# duration: {args.duration_ms} ms ({args.duration_ms // 60000} min)")
    print(f"# warmup_ms: {out_cfg['simulation']['warmup_ms']}")
    print(f"# commands: {len(out_cfg['commands'])} verbs={dict(verbs)} tags={dict(tags)}")
    print(f"# joiners: {', '.join(joiners)}")
    print(f"# dying: {', '.join(dying)}")


if __name__ == "__main__":
    main()
