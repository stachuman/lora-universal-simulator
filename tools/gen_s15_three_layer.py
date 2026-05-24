#!/usr/bin/env python3
"""Generate scenarios/s15_three_layer.json.

Three-layer scenario for exercising gateway functionality. 33 nodes
(10 L1 + 10 L2 + 10 L3 + 3 bridges), 45 min total: 10 min quiet +
35 min active. Per-layer routing-SF separation. THREE separate
gateways, one per layer-pair:

  bridge_12: home L1, visits L2  (routing 8 <-> 9)
  bridge_13: home L1, visits L3  (routing 8 <-> 10)
  bridge_23: home L2, visits L3  (routing 9 <-> 10)

Tests multi-gateway TLV propagation (PROTOCOL §3.1 type 4): an L1
node picking a gateway for a cross-layer DM must distinguish "gw
to L2" vs "gw to L3". The gateway_layer TLV's (gw_id, dest_layer)
pairs make this work.

Cross-layer DM pairs that exercise each bridge:
  dave(L1)  <-> peter(L2)   via bridge_12
  frank(L1) <-> wendy(L3)   via bridge_13
  mia(L2)   <-> zoey(L3)    via bridge_23

Plus same-layer pairs and 6 channel posters (2 per layer).

Run:
  python3 tools/gen_s15_three_layer.py
  build/orchestrator/lus scenarios/s15_three_layer.json \\
      /tmp/s15.ndjson
  python3 tools/dm_delivery_breakdown.py scenarios/s15_three_layer.json
"""
import json
import os

# ---------- Top-level constants ----------

DURATION_MS = 45 * 60 * 1000     # 45 min (10 quiet + 35 active)
WARMUP_MS = 0
SEED = 1522

BCN_PERIOD_MS = 30_000
DISCOVERY_BCN_PERIOD_MS = 4_000
STATE_SNAPSHOT_PERIOD_MS = 60_000

RADIO = {
    "sf": 8, "bw": 62.5, "cr": 5,
    "max_packet_bytes": 255, "snr_coherence_ms": 0,
    "duty_cycle": 0.1,
}

# Per-layer SF separation. Routing/control SFs MUST be in SF6..SF9
# range (long-range SF10..SF12 is data-plane only — using them as
# routing_sf blows through duty-cycle on small frequent control
# frames). L3 routing is at SF7, well-spaced from L1=SF8 and
# L2=SF9 while staying inside the routing-SF budget. L3 data SFs
# [10, 11] overlap with L2 data (SF10) for a realistic cross-layer
# airtime-contention pattern the scenario tests.
L1_ROUTING_SF, L1_DATA_SFS = 8,  [7, 9]
L2_ROUTING_SF, L2_DATA_SFS = 9,  [6, 10]
L3_ROUTING_SF, L3_DATA_SFS = 7,  [10, 11]

# Per-node key_hash32: 0x14<layer><0000><index>. Each node unique.
# Bridges use 0xF0 marker since they're not "layer N nodes" in the
# leaf sense.
KEY_HASH_PREFIX = 0x14000000
BRIDGE_LAYER_MARKER = 0xF0    # reserved layer byte for bridge hashes

def key_hash32_int(layer_byte: int, idx: int) -> int:
    return KEY_HASH_PREFIX | (layer_byte << 16) | idx

def key_hash32_hex(layer_byte: int, idx: int) -> str:
    return f"0x{key_hash32_int(layer_byte, idx):08X}"

# Bridge time-share. With 3 layers participating (1 home + 2 visits)
# we can't time-share all three out of one bridge — we use SEPARATE
# bridges per layer-pair instead. Each bridge has one visit layer.
# 15s/7.5s (50/50) switching: a 24-seed sweep showed cross-layer delivery
# 56%->68% vs the old 30s/15s split. The gateway duty-cycle SPLIT is zero-sum
# (doorstep<->visit loss trade off), but FREQUENCY is a real lever -- shorter
# periods cut the wait for the gateway to be on the right layer. 10s over-shoots
# (visit window too short). Stays well within the 10% radio duty budget (peak
# duty-budget use ~51%, zero beacon_skipped_budget).
BRIDGE_VISIT_PERIOD_MS   = 15_000
BRIDGE_VISIT_DURATION_MS = 7_500
BRIDGE_VISIT_OFFSET_MS   = 7_500

# Names (in node_id order)
L1_NAMES = ["alice", "bob", "carol", "dave", "eve",
            "frank", "grace", "heidi", "ivan", "judy"]
L2_NAMES = ["kate", "leo", "mia", "ned", "olga",
            "peter", "quinn", "rosa", "sam", "tina"]
L3_NAMES = ["ursula", "viktor", "wendy", "xena", "yves",
            "zoey", "abel", "bea", "clio", "drew"]
BRIDGE_NAMES = ["bridge_12", "bridge_13", "bridge_23"]
ALL_NAMES = L1_NAMES + L2_NAMES + L3_NAMES + BRIDGE_NAMES

# Cross-layer DM endpoints (resolved key_hash32 decimal for send_layer).
# L1 layer-index follows node_id; L2 layer-index = node_id-10; L3
# layer-index = node_id-20.
DAVE_HASH  = key_hash32_int(0x01, 4)    # dave  (L1 node_id 4)
PETER_HASH = key_hash32_int(0x02, 6)    # peter (L2 node_id 16, layer-idx 6)
FRANK_HASH = key_hash32_int(0x01, 6)    # frank (L1 node_id 6)
WENDY_HASH = key_hash32_int(0x03, 3)    # wendy (L3 node_id 23, layer-idx 3)
MIA_HASH   = key_hash32_int(0x02, 3)    # mia   (L2 node_id 13, layer-idx 3)
ZOEY_HASH  = key_hash32_int(0x03, 6)    # zoey  (L3 node_id 26, layer-idx 6)

OUT_PATH = "scenarios/s15_three_layer.json"


# ---------- Node builders ----------

def _common_node(name: str, node_id: int, layer_byte: int,
                 layer_index: int, layer_id: int, routing_sf: int,
                 data_sfs: list) -> dict:
    return {
        "name":       name,
        "node_id":    node_id,
        "key_hash32": key_hash32_hex(layer_byte, layer_index),
        "script":     "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":                   layer_id,
            "routing_sf":                 routing_sf,
            "allowed_data_sfs":           list(data_sfs),
            "beacon_period_ms":           BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms":   STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms":         0,
        },
    }


def make_l1_node(name, node_id):
    return _common_node(name, node_id, 0x01, node_id, 1,
                        L1_ROUTING_SF, L1_DATA_SFS)


def make_l2_node(name, node_id):
    return _common_node(name, node_id, 0x02, node_id - 10, 2,
                        L2_ROUTING_SF, L2_DATA_SFS)


def make_l3_node(name, node_id):
    return _common_node(name, node_id, 0x03, node_id - 20, 3,
                        L3_ROUTING_SF, L3_DATA_SFS)


def _make_bridge(name, node_id, hash_idx, home_layer_id,
                 home_routing_sf, home_data_sfs,
                 visit_layer_id, visit_routing_sf, visit_data_sfs):
    return {
        "name":       name,
        "node_id":    node_id,
        "key_hash32": key_hash32_hex(BRIDGE_LAYER_MARKER, hash_idx),
        "script":     "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":         home_layer_id,
            "is_gateway":       True,
            "routing_sf":       home_routing_sf,
            "allowed_data_sfs": list(home_data_sfs),
            "gateway_layers": [
                {
                    "layer_id":         visit_layer_id,
                    "routing_sf":       visit_routing_sf,
                    "allowed_data_sfs": list(visit_data_sfs),
                    "period_ms":        BRIDGE_VISIT_PERIOD_MS,
                    "duration_ms":      BRIDGE_VISIT_DURATION_MS,
                    "offset_ms":        BRIDGE_VISIT_OFFSET_MS,
                },
            ],
            "beacon_period_ms":           BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms":   STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms":         0,
        },
    }


def make_bridge_12(name, node_id):
    return _make_bridge(name, node_id, 1,
                        1, L1_ROUTING_SF, L1_DATA_SFS,
                        2, L2_ROUTING_SF, L2_DATA_SFS)


def make_bridge_13(name, node_id):
    return _make_bridge(name, node_id, 2,
                        1, L1_ROUTING_SF, L1_DATA_SFS,
                        3, L3_ROUTING_SF, L3_DATA_SFS)


def make_bridge_23(name, node_id):
    return _make_bridge(name, node_id, 3,
                        2, L2_ROUTING_SF, L2_DATA_SFS,
                        3, L3_ROUTING_SF, L3_DATA_SFS)


def build_nodes():
    nodes = []
    nid = 1
    for n in L1_NAMES:
        nodes.append(make_l1_node(n, nid)); nid += 1
    for n in L2_NAMES:
        nodes.append(make_l2_node(n, nid)); nid += 1
    for n in L3_NAMES:
        nodes.append(make_l3_node(n, nid)); nid += 1
    nodes.append(make_bridge_12(BRIDGE_NAMES[0], nid)); nid += 1
    nodes.append(make_bridge_13(BRIDGE_NAMES[1], nid)); nid += 1
    nodes.append(make_bridge_23(BRIDGE_NAMES[2], nid)); nid += 1
    return nodes


# ---------- Link plan ----------
#
# L1 mirrors s14 exactly (alice..judy). L2 mirrors s14 (kate..tina).
# L3 mirrors the same structural shape with ursula..drew.
# Bridges connect to two nodes each per layer they participate in
# (4 directed links per bridge in each layer they reach).

L1_LINKS = [
    ("alice",  "bob",    18, 18),
    ("alice",  "carol",  16, 16),
    ("alice",  "dave",   13, 13),
    ("bob",    "dave",   17, 17),
    ("carol",  "dave",   15, 15),
    ("carol",  "frank",  14,  6),   # asymmetric
    ("dave",   "eve",    16,  7),   # asymmetric
    ("dave",   "grace",  18, 18),
    ("eve",    "heidi",  14, 14),
    ("frank",  "grace",  15, 15),
    ("grace",  "heidi",  17, 17),
    ("grace",  "ivan",   16,  8),   # asymmetric
    ("grace",  "judy",   18, 18),
    ("heidi",  "judy",   14, 14),
    ("ivan",   "judy",   15, 15),
]

L2_LINKS = [
    ("kate",   "leo",    18, 18),
    ("kate",   "mia",    16, 16),
    ("kate",   "ned",    13, 13),
    ("leo",    "ned",    17, 17),
    ("mia",    "ned",    15, 15),
    ("mia",    "peter",  14,  6),   # asymmetric
    ("ned",    "olga",   16,  7),   # asymmetric
    ("ned",    "quinn",  18, 18),
    ("olga",   "rosa",   14, 14),
    ("peter",  "quinn",  15, 15),
    ("quinn",  "rosa",   17, 17),
    ("quinn",  "sam",    16,  8),   # asymmetric
    ("quinn",  "tina",   18, 18),
    ("rosa",   "tina",   14, 14),
    ("sam",    "tina",   15, 15),
]

L3_LINKS = [
    ("ursula", "viktor", 18, 18),
    ("ursula", "wendy",  16, 16),
    ("ursula", "xena",   13, 13),
    ("viktor", "xena",   17, 17),
    ("wendy",  "xena",   15, 15),
    ("wendy",  "zoey",   14,  6),   # asymmetric
    ("xena",   "yves",   16,  7),   # asymmetric
    ("xena",   "abel",   18, 18),
    ("yves",   "bea",    14, 14),
    ("zoey",   "abel",   15, 15),
    ("abel",   "bea",    17, 17),
    ("abel",   "clio",   16,  8),   # asymmetric
    ("abel",   "drew",   18, 18),
    ("bea",    "drew",   14, 14),
    ("clio",   "drew",   15, 15),
]

# Bridges connect to two leaves each per participating layer.
# bridge_12: grace+ivan (L1), quinn+sam (L2)   ← same as s14
# bridge_13: dave+heidi (L1), abel+bea  (L3)
# bridge_23: ned+olga   (L2), xena+yves (L3)
BRIDGE_LINKS = [
    ("bridge_12", "grace",  16, 16),
    ("bridge_12", "ivan",   14, 14),
    ("bridge_12", "quinn",  16, 16),
    ("bridge_12", "sam",    14, 14),
    ("bridge_13", "dave",   16, 16),
    ("bridge_13", "heidi",  14, 14),
    ("bridge_13", "abel",   16, 16),
    ("bridge_13", "bea",    14, 14),
    ("bridge_23", "ned",    16, 16),
    ("bridge_23", "olga",   14, 14),
    ("bridge_23", "xena",   16, 16),
    ("bridge_23", "yves",   14, 14),
]


def _expand_directed(pairs):
    out = []
    for a, b, snr_ab, snr_ba in pairs:
        out.append({"from": a, "to": b, "snr": float(snr_ab), "bidir": False})
        out.append({"from": b, "to": a, "snr": float(snr_ba), "bidir": False})
    return out


def build_links():
    return (_expand_directed(L1_LINKS)
            + _expand_directed(L2_LINKS)
            + _expand_directed(L3_LINKS)
            + _expand_directed(BRIDGE_LINKS))


# ---------- Inject schedule ----------

def _inject(at_ms, node, command):
    return {"at_ms": at_ms, "node": node, "command": command}


# Phase 1 — DM-only (t=600s -> 1500s, 15 min). 7 burst pairs,
# staggered ~120s apart. Each pair is a back-and-forth burst.
PHASE1_INJECTS = [
    # alice <-> bob (L1 1-hop)
    _inject(600_000,  "alice", "send bob hi"),
    _inject(612_000,  "bob",   "send alice hey"),
    _inject(628_000,  "alice", "send bob any-updates"),
    _inject(645_000,  "bob",   "send alice all-green"),
    _inject(665_000,  "alice", "send bob good"),
    _inject(685_000,  "bob",   "send alice ttyl"),

    # carol <-> heidi (L1 3-hop)
    _inject(720_000,  "carol", "send heidi ping"),
    _inject(738_000,  "heidi", "send carol pong"),
    _inject(765_000,  "carol", "send heidi howsignal"),
    _inject(792_000,  "heidi", "send carol weak-north"),
    _inject(820_000,  "carol", "send heidi ack"),
    _inject(845_000,  "heidi", "send carol 73"),

    # leo <-> rosa (L2 3-hop)
    _inject(840_000,  "leo",   "send rosa yo"),
    _inject(860_000,  "rosa",  "send leo yo-back"),
    _inject(890_000,  "leo",   "send rosa test-test"),
    _inject(920_000,  "rosa",  "send leo 5of5"),
    _inject(950_000,  "leo",   "send rosa out"),
    _inject(975_000,  "rosa",  "send leo 73"),

    # ursula <-> yves (L3 3-hop)
    _inject(960_000,  "ursula", "send yves greetings"),
    _inject(978_000,  "yves",   "send ursula hi-back"),
    _inject(1005_000, "ursula", "send yves status"),
    _inject(1032_000, "yves",   "send ursula nominal"),
    _inject(1060_000, "ursula", "send yves out"),
    _inject(1085_000, "yves",   "send ursula 73"),

    # dave <-> peter (L1<->L2 cross-layer via bridge_12)
    _inject(1080_000, "dave",  f"send_layer 2 {PETER_HASH} bridge-12-test"),
    _inject(1115_000, "peter", f"send_layer 1 {DAVE_HASH} got-it"),
    _inject(1150_000, "dave",  f"send_layer 2 {PETER_HASH} round-trip-ok"),
    _inject(1180_000, "peter", f"send_layer 1 {DAVE_HASH} confirmed"),

    # frank <-> wendy (L1<->L3 cross-layer via bridge_13)
    _inject(1200_000, "frank", f"send_layer 3 {WENDY_HASH} bridge-13-test"),
    _inject(1235_000, "wendy", f"send_layer 1 {FRANK_HASH} got-it"),
    _inject(1270_000, "frank", f"send_layer 3 {WENDY_HASH} round-trip-ok"),
    _inject(1300_000, "wendy", f"send_layer 1 {FRANK_HASH} confirmed"),

    # mia <-> zoey (L2<->L3 cross-layer via bridge_23)
    _inject(1320_000, "mia",   f"send_layer 3 {ZOEY_HASH} bridge-23-test"),
    _inject(1355_000, "zoey",  f"send_layer 2 {MIA_HASH} got-it"),
    _inject(1390_000, "mia",   f"send_layer 3 {ZOEY_HASH} round-trip-ok"),
    _inject(1420_000, "zoey",  f"send_layer 2 {MIA_HASH} confirmed"),
]

# Phase 2 — Channel-only (t=1500s -> 2100s, 10 min). 6 posters
# (2 per layer), 3 waves at ~3 min spacing.
PHASE2_INJECTS = []
_p2_t = 1_500_000
_posters = [
    ("eve",    7, "L1-news"),
    ("grace",  7, "L1-event"),
    ("mia",    7, "L2-news"),
    ("quinn",  7, "L2-event"),
    ("viktor", 7, "L3-news"),
    ("drew",   7, "L3-event"),
]
for wave in range(1, 4):     # 3 waves
    t = _p2_t + (wave - 1) * 180_000
    for i, (name, ch, prefix) in enumerate(_posters):
        PHASE2_INJECTS.append(
            _inject(t + i * 30_000, name, f"send_channel {ch} {prefix}-{wave}")
        )

# Phase 3 — Mixed (t=2100s -> 2700s, 10 min). Replay DM pairs +
# scatter a few channel posts. Mirrors s14 Phase 3.
PHASE3_INJECTS = [
    _inject(2_100_000, "alice", "send bob round-2"),
    _inject(2_115_000, "mia",   "send_channel 7 L2-news-5"),
    _inject(2_135_000, "bob",   "send alice ack"),
    _inject(2_160_000, "carol", "send heidi hey-again"),
    _inject(2_185_000, "viktor", "send_channel 7 L3-news-5"),
    _inject(2_200_000, "heidi", "send carol still-here"),
    _inject(2_220_000, "leo",   "send rosa second-pass"),
    _inject(2_250_000, "rosa",  "send leo yep"),
    _inject(2_270_000, "ursula", "send yves second-pass"),
    _inject(2_300_000, "drew",  "send_channel 7 L3-event-5"),
    _inject(2_320_000, "yves",  "send ursula yep"),
    _inject(2_350_000, "dave",  f"send_layer 2 {PETER_HASH} stress-test"),
    _inject(2_390_000, "eve",   "send_channel 7 L1-news-5"),
    _inject(2_420_000, "peter", f"send_layer 1 {DAVE_HASH} loud-and-clear"),
    _inject(2_450_000, "frank", f"send_layer 3 {WENDY_HASH} stress-test"),
    _inject(2_490_000, "grace", "send_channel 7 L1-event-5"),
    _inject(2_520_000, "wendy", f"send_layer 1 {FRANK_HASH} loud-and-clear"),
    _inject(2_550_000, "mia",   f"send_layer 3 {ZOEY_HASH} stress-test"),
    _inject(2_590_000, "quinn", "send_channel 7 L2-event-5"),
    _inject(2_620_000, "zoey",  f"send_layer 2 {MIA_HASH} loud-and-clear"),
    _inject(2_650_000, "alice", "send bob final"),
    _inject(2_675_000, "bob",   "send alice 73-all"),
]


# ---------- Assembly + validation + main ----------

DESC = (
    "Three-layer scenario for testing gateway functionality. 33 nodes "
    "(10 L1 alice..judy + 10 L2 kate..tina + 10 L3 ursula..drew + "
    "3 bridges). Each bridge serves one layer-pair: bridge_12 (L1<->L2), "
    "bridge_13 (L1<->L3), bridge_23 (L2<->L3). Per-layer routing SF: "
    "L1=SF8, L2=SF9, L3=SF10. 45 min: 10 min quiet warmup + 35 min "
    "active traffic (Phase 1 DM-only 15 min, Phase 2 channel-only 10 min, "
    "Phase 3 mixed 10 min). 7 DM pairs: alice<->bob (L1 1-hop), "
    "carol<->heidi (L1 3-hop), leo<->rosa (L2 3-hop), ursula<->yves "
    "(L3 3-hop), dave<->peter (cross via bridge_12), frank<->wendy "
    "(cross via bridge_13), mia<->zoey (cross via bridge_23). 6 channel "
    "posters (2 per layer). Tests multi-gateway TLV propagation "
    "(PROTOCOL §3.1 type 4) — each cross-layer DM must pick the right "
    "bridge from the propagated (gw_id, dest_layer) pairs."
)


def build_scenario():
    return {
        "_name": "s15_three_layer",
        "_desc": DESC,
        "simulation": {
            "duration_ms":            DURATION_MS,
            "step_ms":                1,
            "warmup_ms":              WARMUP_MS,
            "seed":                   SEED,
            "node_startup_jitter_ms": 5_000,
            "radio":                  dict(RADIO),
        },
        "config": {
            "debug_start_ms": 0,
            "debug_end_ms":   DURATION_MS,
        },
        "nodes": build_nodes(),
        "topology": {
            "links": build_links(),
        },
        "commands": (PHASE1_INJECTS + PHASE2_INJECTS + PHASE3_INJECTS),
    }


def validate(scen):
    nodes = scen["nodes"]
    assert len(nodes) == 33, f"expected 33 nodes, got {len(nodes)}"
    names = [n["name"] for n in nodes]
    assert sorted(names) == sorted(ALL_NAMES), \
        f"node name set mismatch:\n  got: {sorted(names)}\n  want: {sorted(ALL_NAMES)}"

    l1 = [n for n in nodes if n["config"]["layer_id"] == 1 and not n["config"].get("is_gateway")]
    l2 = [n for n in nodes if n["config"]["layer_id"] == 2 and not n["config"].get("is_gateway")]
    l3 = [n for n in nodes if n["config"]["layer_id"] == 3 and not n["config"].get("is_gateway")]
    bridges = [n for n in nodes if n["config"].get("is_gateway")]
    assert (len(l1), len(l2), len(l3), len(bridges)) == (10, 10, 10, 3), \
        f"layer counts: {(len(l1), len(l2), len(l3), len(bridges))}"

    for n in l1:
        assert n["config"]["routing_sf"] == L1_ROUTING_SF
        assert n["config"]["allowed_data_sfs"] == L1_DATA_SFS
    for n in l2:
        assert n["config"]["routing_sf"] == L2_ROUTING_SF
        assert n["config"]["allowed_data_sfs"] == L2_DATA_SFS
    for n in l3:
        assert n["config"]["routing_sf"] == L3_ROUTING_SF
        assert n["config"]["allowed_data_sfs"] == L3_DATA_SFS

    # Bridge layer-pair coverage check.
    by_name = {n["name"]: n for n in bridges}
    pairs_seen = set()
    for bn in BRIDGE_NAMES:
        b = by_name[bn]
        home = b["config"]["layer_id"]
        visits = [g["layer_id"] for g in b["config"]["gateway_layers"]]
        assert len(visits) == 1, \
            f"bridge {bn}: expected 1 visit layer, got {visits}"
        pair = tuple(sorted([home, visits[0]]))
        pairs_seen.add(pair)
    expected_pairs = {(1, 2), (1, 3), (2, 3)}
    assert pairs_seen == expected_pairs, \
        f"bridge layer-pair coverage: {pairs_seen} vs {expected_pairs}"

    hashes = [n["key_hash32"] for n in nodes]
    assert len(set(hashes)) == 33, \
        f"key_hash32 not unique: {len(set(hashes))} of 33"

    n_links = len(scen["topology"]["links"])
    expected = 2 * (len(L1_LINKS) + len(L2_LINKS) + len(L3_LINKS)
                    + len(BRIDGE_LINKS))
    assert n_links == expected, f"links: {n_links} vs {expected}"

    asym = sum(1 for a, b, f, r in (L1_LINKS + L2_LINKS + L3_LINKS) if f != r)
    assert asym == 9, f"asymmetric pairs across 3 layers: {asym} vs 9"

    name_set = set(names)
    for l in scen["topology"]["links"]:
        assert l["from"] in name_set and l["to"] in name_set, l

    n_cmd = len(scen["commands"])
    assert n_cmd == (len(PHASE1_INJECTS) + len(PHASE2_INJECTS)
                     + len(PHASE3_INJECTS)), \
        f"command count mismatch: {n_cmd}"

    # Phase ordering.
    p1_max = max(c["at_ms"] for c in PHASE1_INJECTS)
    p2_min = min(c["at_ms"] for c in PHASE2_INJECTS)
    p3_min = min(c["at_ms"] for c in PHASE3_INJECTS)
    assert p1_max < 1_500_000 <= p2_min, (p1_max, p2_min)
    assert p2_min < 2_100_000 <= p3_min, (p2_min, p3_min)


def main():
    scen = build_scenario()
    validate(scen)
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(scen, f, indent=2)
        f.write("\n")
    n_dm = sum(1 for c in scen["commands"] if c["command"].startswith("send "))
    n_xlayer = sum(1 for c in scen["commands"] if c["command"].startswith("send_layer "))
    n_chan = sum(1 for c in scen["commands"] if c["command"].startswith("send_channel "))
    print(f"wrote {OUT_PATH}:")
    print(f"  nodes:    {len(scen['nodes'])}")
    print(f"  links:    {len(scen['topology']['links'])} directed")
    print(f"  commands: {len(scen['commands'])} "
          f"({n_dm} DM + {n_xlayer} cross-layer + {n_chan} channel)")


if __name__ == "__main__":
    main()
