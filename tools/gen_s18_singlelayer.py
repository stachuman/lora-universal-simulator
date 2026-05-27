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

Traffic is REALISTIC session-based chatter (reusing gen_s04_realistic's model:
2-party conversations with exp-distributed gaps, pings, groups, telemetry,
bursts) — NOT synthetic all-at-once waves. Follows the scenario rules (as s15):
no artificial relaxed-physics warmup (sim warmup_ms=0) and no traffic for the
first 10 min so the network stabilizes itself (traffic_start_ms >= 600000).

Usage:
    python3 tools/gen_s18_singlelayer.py            # writes scenarios/s18_singlelayer_dense.json
    python3 tools/gen_s18_singlelayer.py --src ... --out ...
"""
import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_s04_realistic as g04   # noqa: E402  (reuse the realistic-traffic model)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="scenarios/s03_seattle_medium.json",
                   help="single-layer topology source. s03 has EXPLICIT links "
                        "(s04/s05 use path-loss with 0 explicit links + SF10 routing, "
                        "which collision-collapses at BW125).")
    p.add_argument("--out", default="scenarios/s18_singlelayer_dense.json")
    p.add_argument("--bw", type=int, default=125)
    p.add_argument("--duty-cycle", type=float, default=0.1)
    # Realistic session-based traffic (reuses gen_s04_realistic): conversations,
    # pings, groups, telemetry, bursts — sent with proper inter-message gaps.
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--mean-session-gap-ms", type=int, default=60000,
                   help="mean Poisson gap between sessions (gen_s04_realistic)")
    p.add_argument("--repeater-senders", type=int, default=12,
                   help="named repeaters added to the active sender pool (+4 corners)")
    # Scenario rules (as in s15): NO artificial start-period (sim warmup_ms=0), and
    # NO traffic for the first 10 min so the network stabilizes itself first.
    p.add_argument("--warmup-ms", type=int, default=0,
                   help="sim relaxed-physics warmup (rule: 0)")
    p.add_argument("--jitter-ms", type=int, default=5000,
                   help="node_startup_jitter_ms (realistic power-on stagger, as s15)")
    p.add_argument("--traffic-start-ms", type=int, default=600000,
                   help="first session (>=10 min, after natural stabilization)")
    p.add_argument("--duration-ms", type=int, default=2700000,
                   help="total sim (10 min stabilize + ~35 min traffic, as s15)")
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

    # REALISTIC session-based traffic — reuse gen_s04_realistic's model
    # (conversations with exp-distributed gaps, pings, groups, telemetry, bursts),
    # NOT synthetic all-at-once waves. gen_s04 conflates warmup_ms as both the sim
    # warmup AND the session-start, so we drive build_commands with traffic_start_ms
    # as the session-start while leaving the sim warmup_ms at 0 (set above) — that
    # satisfies both rules (no relaxed-physics warmup; no traffic for first 10 min).
    rng = random.Random(args.seed)
    reps = g04.sample_repeaters(c["nodes"], args.repeater_senders, rng)
    identities = sorted(set(reps) | set(g04.CORNER_NAMES))
    non_corner = [r for r in reps if r not in g04.CORNER_NAMES]
    rng.shuffle(non_corner)
    telemetry_specs = [(non_corner[i], rng.choice(g04.CORNER_NAMES), 360000)
                       for i in range(min(2, len(non_corner)))]
    bursts = []
    tb = args.traffic_start_ms
    while tb < args.duration_ms - 90000:
        bursts.append((tb, rng.randint(4, 6), 5000))
        tb += 30 * 60000
    c["commands"] = g04.build_commands(
        identities, rng,
        warmup_ms=args.traffic_start_ms,        # session-start (>=10 min); sim warmup stays 0
        duration_ms=args.duration_ms,
        mean_session_gap_ms=args.mean_session_gap_ms,
        conv_share=32, ping_share=64, group_share=4,
        telemetry_specs=telemetry_specs, bursts=bursts)
    c["_name"] = "s18_singlelayer_dense"
    c["_desc"] = (
        "Single-layer dense mesh (no gateways/cross-layer), reusable routing / "
        "contention test bed. Derived from the s03_seattle_medium explicit-link "
        "topology with static node_id (for dm_delivery_breakdown / --copies) and "
        "the production RF config (BW125, 10% duty, routing_sf=8). Traffic is "
        "REALISTIC session-based chatter (gen_s04_realistic model: conversations "
        "with inter-message gaps, pings, groups, telemetry, bursts) — NOT synthetic "
        "all-at-once waves. Follows the scenario rules (as s15): sim warmup_ms=0 (no "
        "artificial relaxed-physics start) and no traffic for the first 10 min so "
        "the network stabilizes itself (first session at traffic_start_ms)."
    )
    json.dump(c, open(args.out, "w"), indent=2)
    ts = sorted(cmd["at_ms"] for cmd in c["commands"])
    from collections import Counter
    verbs = Counter(cmd["command"].split()[0] for cmd in c["commands"])
    print(f"wrote {args.out}: nodes={len(c['nodes'])} cmds={len(c['commands'])} "
          f"dur={args.duration_ms//60000}min radio={radio}")
    print(f"  first send {ts[0]//1000}s ({ts[0]//60000}min), last {ts[-1]//60000}min; "
          f"warmup={c['simulation']['warmup_ms']}; verbs={dict(verbs)}")


if __name__ == "__main__":
    main()
