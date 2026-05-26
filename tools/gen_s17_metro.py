#!/usr/bin/env python3
"""Generate scenarios/s17_metro.json — a production-fidelity metro scenario.

Asymmetric 3-layer deployment, geographic (lat/lon + log-distance path-loss),
on the production RF plan (BW125, 10% duty):

  L1 "center"  — DENSE city-center, ~180 nodes, routing SF8
  L2 "west"    — SPARSE suburb west of center, ~45 nodes, routing SF9
  L3 "east"    — SPARSE suburb east of center, ~45 nodes, routing SF7

Unlike s15's hand-authored uniform links, topology here is DERIVED from node
positions by simulation.path_loss (log-distance + log-normal shadowing) — so the
link graph has realistic variable degree + asymmetry, and the dense/sparse split
falls out of placement density. 4 gateways sit at the two center<->suburb
boundaries (2 west home-L1/visit-L2, 2 east home-L1/visit-L3). Each gateway has a
DENSE center-side herd and a SPARSE suburb-side herd, so a single run exercises
both regimes of the density-adaptive schedule guard. West<->east cross-layer
traffic routes through the center via two gateways.

Reuses gen_s15_three_layer.py's structure (node builders, per-layer SF
separation, bridge time-sharing, phased DM/channel injection, payload-length
realism, validation) but swaps the topology engine to geographic placement.

Run:
  python3 tools/gen_s17_metro.py            # prints geography/connectivity report
  build/orchestrator/lus scenarios/s17_metro.json /tmp/s17.ndjson
  python3 tools/dm_delivery_breakdown.py scenarios/s17_metro.json /tmp/s17.ndjson
"""
import json
import math
import os
import random
from collections import deque

OUT_PATH = "scenarios/s17_metro.json"
SEED = 1700

# ---- Scale (asymmetric: one big dense layer + two small sparse) ----
# HARD CAP: the orchestrator node_id is an 8-bit short address (0..254), so a
# single mesh is <=255 nodes total. 180 + 34 + 34 + 4 gateways = 252 fits with
# margin. (Real production fact: one MeshCore address space tops out at 255.)
CENTER_N = 180
WEST_N   = 34
EAST_N   = 34
GW_PER_BOUNDARY = 2          # 2 west (L1<->L2) + 2 east (L1<->L3)

# ---- Duration ----
DURATION_MS = 60 * 60 * 1000     # 1 hour
WARMUP_MS = 0
QUIET_MS = 600_000               # 10 min quiet: let beacons propagate / routes settle
TRAFFIC_WAVES = 3                # repeat the DM/XL/channel bursts in waves across
                                 # the 50-min active window (fills the hour + more samples)

BCN_PERIOD_MS = 30_000
DISCOVERY_BCN_PERIOD_MS = 4_000
STATE_SNAPSHOT_PERIOD_MS = 60_000

# ---- Production RF plan (band 869.4625 / BW125 / 10% duty) ----
RADIO = {
    "sf": 8, "bw": 125, "cr": 5,
    "max_packet_bytes": 255, "snr_coherence_ms": 0,
    "duty_cycle": 0.1,
}
# EXPLICIT individually-defined links (NOT path-loss-derived). A path-loss model
# couples degree to density (a dense cluster auto-over-connects -> unicast
# saturation) and log-distance is a poor LoRa fit anyway (the real Gdansk map fits
# alpha~0.67 -- terrain/LOS/antenna dominate, not distance). Instead we build the
# graph explicitly: each node links to its ~K nearest same-layer peers (degree
# capped), so "dense in node count" stays decoupled from "realistic neighbour
# count". Each directed link gets an SNR from the REAL-CALIBRATED Gdansk model
# (SNR = 2.45 - 6.69*log10(d_km), sigma 6.66 dB; meshcore_sim/topologies/gdansk.json
# via import_topology's regression) + INDEPENDENT per-direction shadowing -> real
# asymmetric link quality. No path_loss block is emitted (explicit links must be
# the ONLY links, else lus path-loss-fills the rest and the density returns).
# Per-layer degree: DENSE center (more neighbours -> shorter paths -> reliable
# multi-hop unicast), SPARSE suburbs. Degree 5 made the 184-node center stringy
# (diameter 15, mean 5 hops -> unicast dies over the long paths); ~9 shortens it
# without the deg-14 saturation the path-loss model produced.
LINK_K_BY_LAYER     = {1: 9, 2: 5, 3: 5}    # nearest-peer target per layer
LINK_MAXDEG_BY_LAYER = {1: 12, 2: 8, 3: 8}  # hard per-node-per-layer cap
LINK_MAX_KM = 8.0             # don't bind absurdly distant pairs
SNR_FIT_A, SNR_FIT_B = 2.45, -6.69   # Gdansk fit: SNR = A + B*log10(d_km)
SNR_SIGMA_DB = 6.7            # real-calibrated shadow fading (per direction)
SNR_FLOOR_DB = -12.0          # drop a pair if BOTH directions fall below this
# Planning-graph link threshold (mean SNR, no shadowing) used only for the
# connectivity report below; the sim applies per-link shadowing + its own demod.
PLAN_SNR_MIN_DB = -7.0

# ---- Per-layer routing/data SFs (routing in 6..9, clear of Meshtastic/MeshCore) ----
L1_ROUTING_SF, L1_DATA_SFS = 8, [10, 11]   # center
L2_ROUTING_SF, L2_DATA_SFS = 9, [10, 12]   # west
L3_ROUTING_SF, L3_DATA_SFS = 7, [11, 12]   # east

# ---- Geography (Barcelona-ish anchor; center + two offset suburbs) ----
LAT0, LON0 = 41.400, 2.160
KM_PER_DEG_LAT = 111.0
KM_PER_DEG_LON = 111.0 * math.cos(math.radians(LAT0))   # ~83.3 km/deg at 41.4N

def _off_deg(dx_km, dy_km):
    return (dy_km / KM_PER_DEG_LAT, dx_km / KM_PER_DEG_LON)  # (dlat, dlon)

# region = (center_lat, center_lon, radius_km). LoRa links here span only a few
# hundred m (alpha 3.8 -> ~450m usable), so regions must be CONTIGUOUS: the
# suburbs sit adjacent to the center with a small overlap, and gateways live in
# the overlap so they can hear both sides. (A km-scale empty gap would strand
# the gateways and partition the suburbs — the original mistake the geography
# report caught.) Density still differs: dense center, sparse suburbs.
CENTER_RADIUS_KM = 1.5
SUBURB_RADIUS_KM = 0.95      # smaller suburbs (34 nodes) — keep density ~ center's
SUBURB_DX_KM = 2.1           # near edge ~1.15km overlaps center edge 1.5km
BOUNDARY_DX_KM = 1.35        # gateways in the center<->suburb overlap zone
CENTER_REGION = (LAT0, LON0, CENTER_RADIUS_KM)
_dlat_w, _dlon_w = _off_deg(-SUBURB_DX_KM, 0)
_dlat_e, _dlon_e = _off_deg(+SUBURB_DX_KM, 0)
WEST_REGION = (LAT0 + _dlat_w, LON0 + _dlon_w, SUBURB_RADIUS_KM)
EAST_REGION = (LAT0 + _dlat_e, LON0 + _dlon_e, SUBURB_RADIUS_KM)

BRIDGE_VISIT_PERIOD_MS   = 15_000
BRIDGE_VISIT_DURATION_MS = 7_500
BRIDGE_VISIT_OFFSET_MS   = 7_500

KEY_HASH_PREFIX = 0x17000000
def key_hash32_int(layer_byte, idx): return KEY_HASH_PREFIX | (layer_byte << 16) | idx
def key_hash32_hex(layer_byte, idx): return f"0x{key_hash32_int(layer_byte, idx):08X}"


# ---------- Placement ----------

def _place_in_disk(rng, region, n):
    clat, clon, rkm = region
    out = []
    for _ in range(n):
        r = rkm * math.sqrt(rng.random())
        ang = 2 * math.pi * rng.random()
        dlat, dlon = _off_deg(r * math.cos(ang), r * math.sin(ang))
        out.append((round(clat + dlat, 6), round(clon + dlon, 6)))
    return out


# ---------- Node builders (reuse s15 shape + lat/lon) ----------

def _node(name, node_id, layer_byte, layer_index, layer_id, routing_sf,
          data_sfs, lat, lon):
    return {
        "name": name, "node_id": node_id,
        "key_hash32": key_hash32_hex(layer_byte, layer_index),
        "script": "scenarios/dv_dual_sf.lua",
        "lat": lat, "lon": lon,
        "config": {
            "layer_id": layer_id, "routing_sf": routing_sf,
            "allowed_data_sfs": list(data_sfs),
            "beacon_period_ms": BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms": STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms": 0,
        },
    }


def _gateway(name, node_id, hash_idx, lat, lon, visit_layer_id,
             visit_routing_sf, visit_data_sfs):
    return {
        "name": name, "node_id": node_id,
        "key_hash32": key_hash32_hex(0xF0, hash_idx),
        "script": "scenarios/dv_dual_sf.lua",
        "lat": lat, "lon": lon,
        "config": {
            "layer_id": 1, "is_gateway": True,
            "routing_sf": L1_ROUTING_SF, "allowed_data_sfs": list(L1_DATA_SFS),
            "gateway_layers": [{
                "layer_id": visit_layer_id, "routing_sf": visit_routing_sf,
                "allowed_data_sfs": list(visit_data_sfs),
                "period_ms": BRIDGE_VISIT_PERIOD_MS,
                "duration_ms": BRIDGE_VISIT_DURATION_MS,
                "offset_ms": BRIDGE_VISIT_OFFSET_MS,
            }],
            "beacon_period_ms": BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms": STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms": 0,
        },
    }


def build_nodes(rng):
    nodes = []
    nid = 1
    cpos = _place_in_disk(rng, CENTER_REGION, CENTER_N)
    for i, (lat, lon) in enumerate(cpos):
        nodes.append(_node(f"c{i:03d}", nid, 0x01, i, 1, L1_ROUTING_SF,
                           L1_DATA_SFS, lat, lon)); nid += 1
    wpos = _place_in_disk(rng, WEST_REGION, WEST_N)
    for i, (lat, lon) in enumerate(wpos):
        nodes.append(_node(f"w{i:03d}", nid, 0x02, i, 2, L2_ROUTING_SF,
                           L2_DATA_SFS, lat, lon)); nid += 1
    epos = _place_in_disk(rng, EAST_REGION, EAST_N)
    for i, (lat, lon) in enumerate(epos):
        nodes.append(_node(f"e{i:03d}", nid, 0x03, i, 3, L3_ROUTING_SF,
                           L3_DATA_SFS, lat, lon)); nid += 1
    # gateways at the boundaries (jittered around the boundary point)
    gwlat_w, gwlon_w = _off_deg(-BOUNDARY_DX_KM, 0)
    gwlat_e, gwlon_e = _off_deg(+BOUNDARY_DX_KM, 0)
    hidx = 1
    for k in range(GW_PER_BOUNDARY):
        jy = (rng.random() - 0.5) * 0.6
        lat, lon = _off_deg(-BOUNDARY_DX_KM, jy)
        nodes.append(_gateway(f"gw_w{k}", nid, hidx, round(LAT0+lat,6),
                     round(LON0+lon,6), 2, L2_ROUTING_SF, L2_DATA_SFS))
        nid += 1; hidx += 1
    for k in range(GW_PER_BOUNDARY):
        jy = (rng.random() - 0.5) * 0.6
        lat, lon = _off_deg(+BOUNDARY_DX_KM, jy)
        nodes.append(_gateway(f"gw_e{k}", nid, hidx, round(LAT0+lat,6),
                     round(LON0+lon,6), 3, L3_ROUTING_SF, L3_DATA_SFS))
        nid += 1; hidx += 1
    return nodes


# ---------- Geography validation (Python-side; no lus needed) ----------

def _haversine_m(a, b):
    R = 6371000.0
    lat1, lon1, lat2, lon2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(dlon/2)**2
    return 2 * R * math.asin(math.sqrt(h))


def build_planes(nodes):
    """layer_id -> sorted list of node names that transmit on that plane. A
    gateway is on BOTH its home (L1) and its visit plane."""
    planes = {1: [], 2: [], 3: []}
    for n in nodes:
        if n["config"].get("is_gateway"):
            planes[1].append(n["name"])
            planes[n["config"]["gateway_layers"][0]["layer_id"]].append(n["name"])
        else:
            planes[n["config"]["layer_id"]].append(n["name"])
    for L in planes:
        planes[L].sort()
    return planes


def _snr_mean_db(d_km):
    return SNR_FIT_A + SNR_FIT_B * math.log10(max(d_km, 0.01))


def build_links(nodes):
    """Explicit individually-defined links: connect each node to its K nearest
    same-plane peers (degree-capped), assigning each DIRECTED link an SNR from the
    real-calibrated Gdansk model + independent per-direction shadowing."""
    pos = {n["name"]: (n["lat"], n["lon"]) for n in nodes}
    planes = build_planes(nodes)
    rng = random.Random(SEED + 7)
    deg = {}          # (name, plane) -> degree
    pairseen = set()  # (plane, frozenset(a,b))
    links = []
    for L, members in planes.items():
        k_target = LINK_K_BY_LAYER.get(L, 5)
        maxdeg = LINK_MAXDEG_BY_LAYER.get(L, 8)
        for a in members:
            cand = sorted((_haversine_m(pos[a], pos[m]) / 1000.0, m)
                          for m in members if m != a)
            for dk, b in cand:
                if deg.get((a, L), 0) >= k_target:
                    break
                if dk > LINK_MAX_KM:
                    break
                key = (L, frozenset([a, b]))
                if key in pairseen:
                    continue
                if deg.get((b, L), 0) >= maxdeg:
                    continue
                mean = _snr_mean_db(dk)
                snr_ab = mean + rng.gauss(0.0, SNR_SIGMA_DB)
                snr_ba = mean + rng.gauss(0.0, SNR_SIGMA_DB)
                if max(snr_ab, snr_ba) < SNR_FLOOR_DB:
                    continue
                links.append({"from": a, "to": b, "snr": round(snr_ab, 1), "bidir": False})
                links.append({"from": b, "to": a, "snr": round(snr_ba, 1), "bidir": False})
                pairseen.add(key)
                deg[(a, L)] = deg.get((a, L), 0) + 1
                deg[(b, L)] = deg.get((b, L), 0) + 1
    return links


def link_report(nodes, links):
    """Connectivity + degree + approx diameter per plane, from the explicit links."""
    planes = build_planes(nodes)
    adj = {}  # (plane) -> {name: set(neighbors)}
    for L in planes:
        adj[L] = {m: set() for m in planes[L]}
    # map each undirected link to the plane(s) both endpoints share
    name_layer = {}
    for n in nodes:
        if n["config"].get("is_gateway"):
            name_layer[n["name"]] = {1, n["config"]["gateway_layers"][0]["layer_id"]}
        else:
            name_layer[n["name"]] = {n["config"]["layer_id"]}
    seen = set()
    for lk in links:
        a, b = lk["from"], lk["to"]
        if (a, b) in seen:
            continue
        seen.add((a, b)); seen.add((b, a))
        for L in name_layer[a] & name_layer[b]:
            adj[L][a].add(b); adj[L][b].add(a)
    stats = {}; warnings = []
    for L, members in planes.items():
        degs = sorted(len(adj[L][m]) for m in members) or [0]
        seenb = {members[0]}; q = deque([members[0]])
        while q:
            u = q.popleft()
            for v in adj[L][u]:
                if v not in seenb:
                    seenb.add(v); q.append(v)
        def bfs_far(src):
            dist = {src: 0}; q = deque([src]); far, fd = src, 0
            while q:
                u = q.popleft()
                for v in adj[L][u]:
                    if v not in dist:
                        dist[v] = dist[u] + 1
                        if dist[v] > fd: far, fd = v, dist[v]
                        q.append(v)
            return far, fd
        a0, _ = bfs_far(members[0]); _, diam = bfs_far(a0)
        iso = sum(1 for m in members if not adj[L][m])
        stats[L] = {"n": len(members), "deg_min": degs[0], "deg_med": degs[len(degs)//2],
                    "deg_max": degs[-1], "connected": len(seenb) == len(members),
                    "reachable": len(seenb), "approx_diam": diam, "isolated": iso}
        if len(seenb) != len(members):
            warnings.append(f"L{L} not fully connected: {len(seenb)}/{len(members)} (iso {iso})")
        if diam < 3:
            warnings.append(f"L{L} diameter {diam} — too shallow")
    gw_herds = {n["name"]: {L: len(adj[L][n["name"]])
                            for L in (1, n["config"]["gateway_layers"][0]["layer_id"])}
                for n in nodes if n["config"].get("is_gateway")}
    return stats, gw_herds, warnings


# ---------- Traffic (phased; modest for v1, scale later) ----------

_FILLER = ("the-quick-brown-fox-jumps-over-the-lazy-dog-" * 6)
_SAFE = {"send": 220, "send_layer": 210, "send_channel": 195}

def _tlen(rng):
    r = rng.random()
    if r < 0.30: return rng.randint(10, 20)
    if r < 0.80: return rng.randint(40, 80)
    return rng.randint(120, 200)

def _pad(verb, base, node, at):
    rng = random.Random(f"{node}|{at}|{base}")
    t = min(_tlen(rng), _SAFE[verb])
    return base if len(base) >= t else (base + "-" + _FILLER)[:t]

def _inj(at, node, cmd):
    verb = cmd.split(None, 1)[0]
    if verb == "send" and len(cmd.split(None, 2)) == 3:
        _, d, b = cmd.split(None, 2); cmd = f"send {d} {_pad('send', b, node, at)}"
    elif verb == "send_layer" and len(cmd.split(None, 3)) == 4:
        _, l, h, b = cmd.split(None, 3); cmd = f"send_layer {l} {h} {_pad('send_layer', b, node, at)}"
    elif verb == "send_channel" and len(cmd.split(None, 2)) == 3:
        _, c, b = cmd.split(None, 2); cmd = f"send_channel {c} {_pad('send_channel', b, node, at)}"
    return {"at_ms": at, "node": node, "command": cmd}


def build_commands(nodes):
    """Pick anchor nodes by index (clamped to layer size) and build intra +
    cross-layer DM bursts."""
    byname = {n["name"]: n for n in nodes}
    def hd(name):
        return int(byname[name]["key_hash32"], 16)
    def cn(i): return f"c{min(i, CENTER_N-1):03d}"
    def wn(i): return f"w{min(i, WEST_N-1):03d}"
    def en(i): return f"e{min(i, EAST_N-1):03d}"
    # intra-layer DM pairs (each layer, spread indices), cross-layer DM pairs
    # (center<->west, center<->east, west<->east via center), channel posters.
    intra = [(cn(10), cn(150)), (cn(40), cn(120)), (wn(5), wn(30)),
             (en(5), en(30)), (cn(0), cn(90))]
    xl = [(cn(20), wn(10), 2), (cn(60), wn(28), 2), (cn(100), wn(20), 2),
          (cn(30), en(15), 3), (cn(80), en(31), 3), (cn(140), en(25), 3),
          (wn(15), en(20), 3), (en(10), wn(31), 2)]
    posters = [cn(5), cn(75), wn(8), wn(30), en(8), en(30)]
    active = DURATION_MS - QUIET_MS
    cmds = []
    for w in range(TRAFFIC_WAVES):
        base = QUIET_MS + w * (active // TRAFFIC_WAVES)
        t = base
        for a, b in intra:
            cmds += [_inj(t, a, f"send {b} hi-w{w}"),
                     _inj(t+15000, b, f"send {a} hey-w{w}")]
            t += 40000
        for a, b, blayer in xl:
            cmds.append(_inj(t, a, f"send_layer {blayer} {hd(b)} xl-{a}-{b}-w{w}"))
            alayer = byname[a]["config"]["layer_id"]
            cmds.append(_inj(t+25000, b, f"send_layer {alayer} {hd(a)} xl-{b}-{a}-w{w}"))
            t += 45000
        for i, p in enumerate(posters):
            cmds.append(_inj(base + 60000 + i*20000, p, f"send_channel 7 ch-{p}-w{w}"))
    return cmds


# ---------- Assembly ----------

def build_scenario():
    rng = random.Random(SEED)
    nodes = build_nodes(rng)
    links = build_links(nodes)
    return {
        "_name": "s17_metro",
        "_desc": ("Production-fidelity metro: dense center L1 (~180, SF8) + sparse "
                  "west L2 (~45, SF9) + sparse east L3 (~45, SF7) suburbs. Geographic "
                  "lat/lon + log-distance path-loss on BW125/10%-duty. 4 boundary "
                  "gateways (2 L1<->L2 west, 2 L1<->L3 east), each with a dense "
                  "center-side + sparse suburb-side herd. West<->east routes through "
                  "the center."),
        "simulation": {
            "duration_ms": DURATION_MS, "step_ms": 1, "warmup_ms": WARMUP_MS,
            "seed": SEED, "node_startup_jitter_ms": 5_000,
            "radio": dict(RADIO),          # NO path_loss: explicit links are the only links
        },
        "config": {"debug_start_ms": 0, "debug_end_ms": DURATION_MS},
        "nodes": nodes,
        "topology": {"links": links},      # explicit, individually-defined, asymmetric
        "commands": build_commands(nodes),
    }


def main():
    scen = build_scenario()
    stats, gw_herds, warnings = link_report(scen["nodes"], scen["topology"]["links"])
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(scen, f, indent=2); f.write("\n")
    print(f"wrote {OUT_PATH}: {len(scen['nodes'])} nodes, "
          f"{len(scen['topology']['links'])} directed links, "
          f"{len(scen['commands'])} commands, duration {DURATION_MS//60000} min")
    print("layer planes (incl. serving gateways):")
    for L in (1, 2, 3):
        s = stats[L]
        print(f"  L{L}: n={s['n']:3d} deg(min/med/max)={s['deg_min']}/{s['deg_med']}/{s['deg_max']} "
              f"connected={s['connected']} (reach {s['reachable']}/{s['n']}) "
              f"approx_diam={s['approx_diam']} isolated={s['isolated']}")
    print("gateway herds (plane: direct neighbors):")
    for gn, h in gw_herds.items():
        print(f"  {gn}: {h}")
    if warnings:
        print("WARNINGS:")
        for w in warnings: print(f"  ! {w}")
    else:
        print("geography OK (all planes connected, multi-hop, no isolates)")


if __name__ == "__main__":
    main()
