#!/usr/bin/env python3
"""Translate the s15_three_layer gateways from the Lua schema (is_gateway + gateway_layers) to ALSO carry the
C++ FirmwareNode dual-layer schema (n_layers:2 + layers[]), so engine:"meshroute" gateways boot on the GATEWAY
lib (FirmwareNode::onInit routes n_layers>=2 -> makeNodeRuntimeGw). The Lua keys are KEPT, so the same scenario
still runs on the Lua engine — it's a dual-schema config (the two engines read disjoint keys).

The Lua gateway_layers[0] gives the GUEST leaf (layer_id/routing_sf/allowed_data_sfs + period/duration/offset);
the HOME leaf comes from the node's top-level layer_id/routing_sf/allowed_data_sfs. Per-leaf node_ids: the home
keeps the node's id; each guest leaf gets a fresh id above the used range (no per-layer collision).
"""
import json, sys

SRC = "/home/staszek/MeshRoute/simulator/s15_three_layer.json"
DST = "/home/staszek/lora-universal-simulator/scenarios/s15_three_layer_meshroute.json"

d = json.load(open(SRC))

# Pick guest-leaf node_ids above every used id (1..34 here) so they never collide on any leaf.
used = {n.get("node_id") for n in d["nodes"] if n.get("node_id") is not None}
next_id = max(used) + 1

def layer_cfg(layer_id, node_id, routing_sf, sfs, beacon_ms, period_ms, window_ms, offset_ms):
    return {"layer_id": layer_id, "node_id": node_id, "routing_sf": routing_sf,
            "allowed_data_sfs": sfs, "beacon_period_ms": beacon_ms,
            "window_period_ms": period_ms, "window_ms": window_ms, "window_offset_ms": offset_ms}

n_gw = 0
for n in d["nodes"]:
    c = n.get("config", {})
    if not c.get("is_gateway") or not c.get("gateway_layers"):
        continue
    g = c["gateway_layers"][0]
    period = g.get("period_ms", 15000)
    guest_win = g.get("duration_ms", period // 2)
    guest_off = g.get("offset_ms", period - guest_win)
    home_win = period - guest_win            # home fills the complement of the cycle
    home_off = 0
    beacon = c.get("beacon_period_ms", 30000)
    home_id = n["node_id"]
    guest_id = next_id; next_id += 1
    c["n_layers"] = 2
    c["layers"] = [
        layer_cfg(c["layer_id"], home_id, c["routing_sf"], c["allowed_data_sfs"], beacon, period, home_win, home_off),
        layer_cfg(g["layer_id"], guest_id, g["routing_sf"], g["allowed_data_sfs"], beacon, period, guest_win, guest_off),
    ]
    n_gw += 1

d["_name"] = "s15_three_layer_meshroute"
d["_desc"] = ("3-layer / 3-gateway cross-layer delivery on the C++ MeshRoute FirmwareNode. Gateways carry BOTH the "
              "Lua (is_gateway/gateway_layers) and the C++ (n_layers:2/layers[]) schema so the scenario runs on "
              "either engine; on engine:meshroute the n_layers:2 gateways bind the gateway lib (makeNodeRuntimeGw). "
              "All send_layer DMs are single-hop (layer A<->B via one 2-layer gateway) = v1 scope.")
json.dump(d, open(DST, "w"), indent=2)
print(f"translated {n_gw} gateways -> {DST}")
