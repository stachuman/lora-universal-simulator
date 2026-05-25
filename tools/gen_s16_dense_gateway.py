#!/usr/bin/env python3
"""Generate s16: a DENSE single-gateway scenario to exercise the gateway-
contention optimizations (herd-jitter, reserved RX window, second gateway per
pair) that s15's sparse 2-node herds and 99%-idle windows structurally cannot
show. Reuses gen_s15_three_layer's node/bridge/hash/payload helpers.

Topology: 2 layers (L1, L2), N nodes each, ALL 1-hop to the gateway(s) — a star.
This gives each gateway an N-node herd per layer (vs s15's 2) and isolates
gateway contention from multi-hop routing. Cross-layer traffic is BURSTY: at
each burst every L1 node sends to a distinct L2 node and every L2 node to a
distinct L1 node, all within ~1s. So per burst the gateway faces ~N inbound RTS
(reserved-window / herd-jitter) AND must forward ~2N exchanges — ~10s of airtime
against a 7.5s window, i.e. a genuinely overloaded window (vs s15's ~0.5%).

  --gateways 1   one gateway (default): shows the contention/overload.
  --gateways 2   two phase-offset gateways (one on each layer at all times):
                 the structural fix — does redundancy beat the single-gw ceiling?
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_s15_three_layer as g

N = 10                              # nodes per layer (herd size)
QUIET_MS = 10 * 60 * 1000           # stabilization (beacons + schedule learn)
DURATION_MS = 22 * 60 * 1000        # 22 min
N_BURSTS = 4
BURST_GAP_MS = 180_000              # a burst every 3 min after the quiet window
BURST_SPREAD_MS = 1000              # all 2N sends packed into ~1s (max concurrency)
SEED = 1601

L1 = [f"a{i:02d}" for i in range(N)]
L2 = [f"b{i:02d}" for i in range(N)]


def build_nodes(n_gw, no_jitter=False):
    nodes = []
    nid = 1
    for nm in L1:
        nodes.append(g.make_l1_node(nm, nid)); nid += 1
    for nm in L2:                                   # node_id 11..20 -> layer-idx 1..10
        nodes.append(g.make_l2_node(nm, nid)); nid += 1
    gws = []
    for k in range(n_gw):
        gw = g.make_bridge_12(f"gw{k}", nid)
        if no_jitter:
            gw["config"]["gateway_herd_min"] = 999    # disable herd-jitter (A/B baseline)
        if n_gw > 1:
            # Phase-offset the L2 visits so the k gateways tile the period: at any
            # instant one gateway is home on L1 and another is visiting L2, giving
            # ~100% presence on BOTH layers instead of 50%.
            gw["config"]["gateway_layers"][0]["offset_ms"] = \
                (k * g.BRIDGE_VISIT_DURATION_MS) % g.BRIDGE_VISIT_PERIOD_MS
        nodes.append(gw); gws.append(f"gw{k}"); nid += 1
    return nodes, gws


def build_links(gws):
    # Star: every layer node is a direct 1-hop neighbour of every gateway.
    links = []
    for nm in L1 + L2:
        for gw in gws:
            links.append({"from": nm, "to": gw, "snr": 11.0, "rssi": -92.0, "bidir": True})
    return links


def l1_hash(i):  # a{i}: node_id i+1, layer-idx i+1
    return g.key_hash32_int(0x01, i + 1)


def l2_hash(i):  # b{i}: node_id i+11, layer-idx i+1
    return g.key_hash32_int(0x02, i + 1)


def build_commands(senders=N):
    cmds = []
    step = BURST_SPREAD_MS // N
    for b in range(N_BURSTS):
        t0 = QUIET_MS + b * BURST_GAP_MS
        for i in range(senders):
            dt = i * step
            cmds.append(g._inject(t0 + dt,      L1[i], f"send_layer 2 {l2_hash(i)} d{b}-from-{L1[i]}"))
            cmds.append(g._inject(t0 + dt + 40, L2[i], f"send_layer 1 {l1_hash(i)} d{b}-from-{L2[i]}"))
    return cmds


def build_scenario(n_gw, senders=N, no_jitter=False):
    nodes, gws = build_nodes(n_gw, no_jitter)
    return {
        "_name": f"s16_dense_gateway_{n_gw}gw",
        "_desc": (f"Dense star: {N} L1 + {N} L2 nodes, all 1-hop to {n_gw} "
                  f"gateway(s) (L1<->L2). {N_BURSTS} bursts of {2*N} cross-layer "
                  f"sends in ~1s each — overloads the gateway window to exercise "
                  f"herd-jitter / reserved-window / second-gateway."),
        "simulation": {
            "duration_ms": DURATION_MS, "step_ms": 1, "warmup_ms": 0,
            "seed": SEED, "node_startup_jitter_ms": 200, "radio": g.RADIO,
        },
        "nodes": nodes,
        "topology": {"links": build_links(gws)},
        "commands": g._expand_payloads(build_commands(senders)),
    }


def validate(scen, n_gw, senders=N):
    nodes = scen["nodes"]
    assert len(nodes) == 2 * N + n_gw, f"nodes {len(nodes)} != {2*N+n_gw}"
    gw_names = {f"gw{k}" for k in range(n_gw)}
    # Each gateway must be a direct neighbour of all 2N layer nodes.
    nbr = {gw: set() for gw in gw_names}
    for l in scen["topology"]["links"]:
        if l["to"] in nbr:
            nbr[l["to"]].add(l["from"])
    for gw, s in nbr.items():
        assert len(s) == 2 * N, f"{gw} herd {len(s)} != {2*N}"
    assert len(scen["commands"]) == N_BURSTS * 2 * senders, "command count"
    print(f"OK: {len(nodes)} nodes ({2*N} layer + {n_gw} gw), herd={2*N}/gw, "
          f"{senders}/layer send per burst, {len(scen['commands'])} sends in "
          f"{N_BURSTS} bursts")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateways", type=int, default=1, choices=(1, 2))
    ap.add_argument("--senders", type=int, default=N,
                    help=f"nodes per layer that send each burst (<= {N}); fewer "
                         f"= lighter per-window load (jitter's collide-but-fits regime)")
    ap.add_argument("--no-jitter", action="store_true",
                    help="set gateway_herd_min=999 to disable herd-jitter (A/B baseline)")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    scen = build_scenario(args.gateways, args.senders, args.no_jitter)
    validate(scen, args.gateways, args.senders)
    if args.out:
        out = args.out
    else:
        out = (f"scenarios/s16_dense_gateway"
               f"{'_2gw' if args.gateways == 2 else ''}"
               f"{f'_s{args.senders}' if args.senders != N else ''}"
               f"{'_nojitter' if args.no_jitter else ''}.json")
    with open(out, "w") as f:
        json.dump(scen, f, indent=2)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
