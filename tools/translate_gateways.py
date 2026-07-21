#!/usr/bin/env python3
"""Translate a Lua gateway scenario to a DUAL-SCHEMA file: it ADDS the C++ FirmwareNode dual-layer schema
(n_layers:2 + layers[]) to each gateway WITHOUT removing the Lua keys (is_gateway + gateway_layers). The
same file then runs on BOTH engines via `lus --engine lua|meshroute` (the two engines read disjoint keys),
which is exactly the semantic-parity setup. Generalized from the coder's translate_s15_gateways.py.

Usage: translate_gateways.py <src.json> <dst.json> [new_name]

Per gateway: home leaf = the node's top-level layer_id/routing_sf/allowed_data_sfs; guest leaf =
gateway_layers[0]. Each guest leaf gets a fresh node_id above every used id (no per-leaf collision).
"""
import json, sys

if len(sys.argv) < 3:
    sys.exit("usage: translate_gateways.py <src.json> <dst.json> [new_name]")
SRC, DST = sys.argv[1], sys.argv[2]
NAME = sys.argv[3] if len(sys.argv) > 3 else None

d = json.load(open(SRC))
used = {n.get("node_id") for n in d["nodes"] if n.get("node_id") is not None}
next_id = (max(used) + 1) if used else 1

def layer_cfg(layer_id, node_id, routing_sf, sfs, beacon_ms, period_ms, window_ms, offset_ms):
    return {"layer_id": layer_id, "node_id": node_id, "routing_sf": routing_sf,
            "allowed_data_sfs": sfs, "beacon_period_ms": beacon_ms,
            "window_period_ms": period_ms, "window_ms": window_ms, "window_offset_ms": offset_ms}

n_gw = 0
for n in d["nodes"]:
    c = n.get("config", {})
    if not c.get("is_gateway") or not c.get("gateway_layers"):
        continue
    if len(c["gateway_layers"]) != 1:
        sys.exit(f"node {n.get('name')} has {len(c['gateway_layers'])} gateway_layers; the 2-layer translator "
                 f"handles exactly 1 guest leaf (a gateway = exactly 2 layers).")
    g = c["gateway_layers"][0]
    period = g.get("period_ms", 15000)
    beacon = c.get("beacon_period_ms", 30000)
    home_id, guest_id = n["node_id"], next_id
    next_id += 1
    # window_ms=0 / window_offset_ms=0 => the C++ DERIVES a non-overlapping anti-phase split (gateway design §4).
    # We deliberately do NOT copy the Lua's home/visit windows: the Lua "home" is the complement AROUND the visit,
    # which maps to OVERLAPPING C++ windows — and C++ on_init REFUSES overlap (§3.2, fail-loud; the Lua silently
    # arms it). Parity here is SEMANTIC (does the cross-layer DM deliver), so each engine runs its own scheduler
    # with the SAME period; we don't force the Lua's (overlapping) schedule onto the C++.
    c["n_layers"] = 2
    c["layers"] = [
        layer_cfg(c["layer_id"], home_id, c["routing_sf"], c["allowed_data_sfs"], beacon, period, 0, 0),
        layer_cfg(g["layer_id"], guest_id, g["routing_sf"], g["allowed_data_sfs"], beacon, period, 0, 0),
    ]
    n_gw += 1

# (a) Statically provision JOIN-only nodes. The Lua joiners adopt, via JOIN/DAD, BOTH (i) a short node_id and
# (ii) the layer's data-SF list (`join_data_sfs_adopted`) — and the C++ DEFERS join (static cfg/NV). Supply both
# statically so the node boots FULLY ACTIVE:
#   - node_id: any unique id (the cross-layer DM addresses by HASH; the gateway resolves hash->id via id_bind from
#     the node's beacons — we don't need the Lua's randomly-adopted id);
#   - allowed_data_sfs: the layer's SF list. CRITICAL — an EMPTY sf bitmap makes a node REFUSE to send AND IGNORE
#     data RTS ([[data-sf-removed]]: sf_list mandatory, no default), so without it the node hears beacons but never
#     answers an RTS and is undeliverable. We mirror the join offer by copying the layer's SF list (below).
layer_sfs = {}                                               # layer_id -> allowed_data_sfs (from whoever carries it)
for n in d["nodes"]:
    c = n.get("config", {})
    if c.get("layer_id") is not None and c.get("allowed_data_sfs"): layer_sfs.setdefault(c["layer_id"], c["allowed_data_sfs"])
    for L in c.get("layers", []):
        if L.get("allowed_data_sfs"): layer_sfs.setdefault(L["layer_id"], L["allowed_data_sfs"])
n_prov = 0
for n in d["nodes"]:
    c = n.setdefault("config", {}); prov = False
    if n.get("node_id") is None:
        n["node_id"] = next_id; next_id += 1; prov = True
        if n.get("key_hash32") is None:                      # scenario didn't pin a hash -> synthesize a leaf-tagged one
            leaf = c.get("layer_id", 0) & 0xff
            n["key_hash32"] = "0x%08x" % ((leaf << 24) | (n["node_id"] & 0xff))
    if not c.get("n_layers") and not c.get("allowed_data_sfs") and c.get("layer_id") in layer_sfs:
        c["allowed_data_sfs"] = list(layer_sfs[c["layer_id"]]); prov = True   # the join-distributed SF list, supplied statically
    if prov: n_prov += 1

if NAME:
    d["_name"] = NAME
d["_desc"] = (d.get("_desc", "") + " [DUAL-SCHEMA: also carries C++ n_layers:2/layers[] on "
              f"{n_gw} gateways; run on both engines via `lus --engine lua|meshroute`.]")
json.dump(d, open(DST, "w"), indent=1)
print(f"translated {n_gw} gateways -> {DST}")
