#!/usr/bin/env python3
"""Generate s18: a dedicated SINGLE-LAYER dense test bed (reusable).

Purpose: a no-gateway / no-cross-layer scenario for copy-suppression and
contention work, where same-layer frames are cleanly identifiable — the wire
`dst` of a same-layer DM is its varied final target (not a funnel gateway), so
the forward-RTS frame-alive identity does NOT alias (unlike cross-layer, which
collapses every frame to a handful of gateway dsts).

Derived from the s04_seattle_dense topology (a dense single-layer mesh) with two
changes that make it usable + realistic:
  - static `node_id` (1..N): dm_delivery_breakdown.py / --copies require explicit
    node_id (they map event slot -> node_id); the Seattle scenarios used OTAA
    auto-addressing, which the tools can't follow.
  - production RF config: BW125 + 10% duty cycle (matches the band plan,
    PROTOCOL §band). The source used BW250 + 1% duty, which throttled delivery
    to ~26% — a duty-cycle artifact, not a routing result.

Usage:
    python3 tools/gen_s18_singlelayer.py            # writes scenarios/s18_singlelayer_dense.json
    python3 tools/gen_s18_singlelayer.py --src ... --out ...
"""
import argparse
import json


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="scenarios/s04_seattle_dense.json",
                   help="single-layer topology source (dense, no gateways)")
    p.add_argument("--out", default="scenarios/s18_singlelayer_dense.json")
    p.add_argument("--bw", type=int, default=125)
    p.add_argument("--duty-cycle", type=float, default=0.1)
    p.add_argument("--pairs", type=int, default=30,
                   help="concurrent far-W<->far-E multi-hop DM pairs per wave "
                        "(0 = keep the source's original commands)")
    p.add_argument("--waves", type=int, default=3,
                   help="number of concurrent send waves")
    # Scenario rules (as in s15): NO artificial start-period (warmup_ms=0), and
    # NO traffic for the first 10 min so the network stabilizes itself first.
    p.add_argument("--warmup-ms", type=int, default=0)
    p.add_argument("--jitter-ms", type=int, default=5000,
                   help="node_startup_jitter_ms (realistic power-on stagger, as s15)")
    p.add_argument("--first-wave-ms", type=int, default=600000,
                   help="first send (>=10 min, after stabilization)")
    p.add_argument("--wave-gap-ms", type=int, default=120000)
    p.add_argument("--duration-ms", type=int, default=1500000,
                   help="total sim (10 min stabilize + waves + settle)")
    p.add_argument("--routing-sf", type=int, default=8,
                   help="routing SF for all nodes. The s04 source uses SF10, which "
                        "violates the routing-SF range (6-9; SF10+ is long-range DATA "
                        "only) and collision-collapses a dense mesh at BW125. SF8 "
                        "matches the production band plan.")
    args = p.parse_args()

    c = json.load(open(args.src))
    # static addresses so the analysis tools can map event slots -> ids
    for i, n in enumerate(c["nodes"]):
        n["node_id"] = i + 1
        # fix the outdated SF10 routing (violates the 6-9 routing-SF rule)
        n.setdefault("config", {})["routing_sf"] = args.routing_sf
    radio = c["simulation"].setdefault("radio", {})
    radio["bw"] = args.bw
    radio["duty_cycle"] = args.duty_cycle
    # Scenario rules (s15): no artificial relaxed-physics warmup; let the network
    # stabilize for the first 10 min (traffic starts >= first_wave_ms).
    c["simulation"]["warmup_ms"] = args.warmup_ms
    c["simulation"]["node_startup_jitter_ms"] = args.jitter_ms
    c["simulation"]["duration_ms"] = args.duration_ms

    # Heavy CONCURRENT multi-hop traffic so contention actually generates copies
    # (the source's ~50 spread sends among a few named nodes barely contend).
    # Pair far-west with far-east nodes by longitude -> long multi-hop paths;
    # fire all pairs at once in a few waves -> network-wide contention.
    if args.pairs > 0:
        xy = sorted(((n["name"], n.get("lon", i)) for i, n in enumerate(c["nodes"])),
                    key=lambda t: t[1])
        half = len(xy) // 2
        west = [nm for nm, _ in xy[:half]]
        east = [nm for nm, _ in xy[half:]][::-1]   # farthest-east first
        npairs = min(args.pairs, len(west), len(east))
        cmds = []
        for w in range(args.waves):
            t = args.first_wave_ms + w * args.wave_gap_ms
            for k in range(npairs):
                a, b = west[k], east[k]
                cmds.append({"at_ms": t, "node": a,
                             "command": f"send {b} sl-w{w}-{a}-{b}-the-quick-brown-fox"})
        c["commands"] = cmds
    c["_name"] = "s18_singlelayer_dense"
    c["_desc"] = (
        "Single-layer dense mesh (no gateways/cross-layer), reusable copy-"
        "suppression / contention test bed. Derived from s04_seattle_dense "
        "topology with static node_id (for dm_delivery_breakdown / --copies) and "
        "the production RF config (BW125, 10% duty); the source's BW250+1% duty "
        "throttled delivery to ~26% (a duty-cycle artifact). Same-layer DM has a "
        "varied wire dst (the final target), so the forward-RTS frame-alive "
        "identity is clean — unlike cross-layer, which funnels to gateway dsts."
    )
    json.dump(c, open(args.out, "w"), indent=2)
    print(f"wrote {args.out}: nodes={len(c['nodes'])} cmds={len(c['commands'])} "
          f"radio={radio}")


if __name__ == "__main__":
    main()
