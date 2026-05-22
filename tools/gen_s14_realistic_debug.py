#!/usr/bin/env python3
"""Generate scenarios/s14_realistic_debug.json.

Realistic debug scenario for delivery-rate investigation. 21 nodes
(10 L1 + 10 L2 + 1 dual-layer bridge), 40 min total: 10 min quiet
warmup + 30 min active traffic across three phases. Per-layer
routing-SF separation (L1=SF8, L2=SF9). Explicit asymmetric link
plan. No priority, no abuse, no mobility.

Spec: docs/superpowers/specs/2026-05-22-s14-realistic-debug-scenario-design.md

Run:
  python3 tools/gen_s14_realistic_debug.py
  build/orchestrator/lus scenarios/s14_realistic_debug.json \\
      --events /tmp/s14.ndjson
  python3 tools/analyze.py scenarios/s14_realistic_debug.json /tmp/s14.ndjson
"""
import json
import os

# ---------- Top-level constants ----------

DURATION_MS = 40 * 60 * 1000      # 40 min total (10 quiet + 30 active)
WARMUP_MS = 0                      # full physics throughout
SEED = 1422

BCN_PERIOD_MS = 30_000
DISCOVERY_BCN_PERIOD_MS = 4_000
STATE_SNAPSHOT_PERIOD_MS = 60_000

RADIO = {
    "sf": 8, "bw": 62.5, "cr": 5,
    "max_packet_bytes": 255, "snr_coherence_ms": 0,
    "duty_cycle": 0.01,
}

# Per-layer SF separation
L1_ROUTING_SF       = 8
L1_DATA_SFS         = [7, 9]
L2_ROUTING_SF       = 9
L2_DATA_SFS         = [6, 10]

# Bridge time-share: 30 s window, 15 s home (L1) / 15 s visit (L2)
BRIDGE_VISIT_PERIOD_MS   = 30_000
BRIDGE_VISIT_DURATION_MS = 15_000
BRIDGE_VISIT_OFFSET_MS   = 15_000

# Names (in node_id order)
L1_NAMES = ["alice", "bob", "carol", "dave", "eve",
            "frank", "grace", "heidi", "ivan", "judy"]
L2_NAMES = ["kate", "leo", "mia", "ned", "olga",
            "peter", "quinn", "rosa", "sam", "tina"]
BRIDGE_NAME = "bridge"
ALL_NAMES = L1_NAMES + L2_NAMES + [BRIDGE_NAME]

OUT_PATH = "scenarios/s14_realistic_debug.json"

# ---------- Node builders ----------

def make_l1_node(name: str, node_id: int) -> dict:
    return {
        "name":       name,
        "node_id":    node_id,
        "key_hash32": "0xCAFE1422",
        "script":     "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":                   1,
            "routing_sf":                 L1_ROUTING_SF,
            "allowed_data_sfs":           list(L1_DATA_SFS),
            "beacon_period_ms":           BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms":   STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms":         0,
        },
    }

def make_l2_node(name: str, node_id: int) -> dict:
    return {
        "name":       name,
        "node_id":    node_id,
        "key_hash32": "0xCAFE1422",
        "script":     "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":                   2,
            "routing_sf":                 L2_ROUTING_SF,
            "allowed_data_sfs":           list(L2_DATA_SFS),
            "beacon_period_ms":           BCN_PERIOD_MS,
            "discovery_beacon_period_ms": DISCOVERY_BCN_PERIOD_MS,
            "state_snapshot_period_ms":   STATE_SNAPSHOT_PERIOD_MS,
            "quiet_threshold_ms":         0,
        },
    }

def make_bridge(name: str, node_id: int) -> dict:
    return {
        "name":       name,
        "node_id":    node_id,
        "key_hash32": "0xCAFE1422",
        "script":     "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":         1,
            "is_gateway":       True,
            "routing_sf":       L1_ROUTING_SF,
            "allowed_data_sfs": list(L1_DATA_SFS),
            "gateway_layers": [
                {
                    "layer_id":         2,
                    "routing_sf":       L2_ROUTING_SF,
                    "allowed_data_sfs": list(L2_DATA_SFS),
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

def build_nodes() -> list[dict]:
    nodes = []
    nid = 1
    for n in L1_NAMES:
        nodes.append(make_l1_node(n, nid)); nid += 1
    for n in L2_NAMES:
        nodes.append(make_l2_node(n, nid)); nid += 1
    nodes.append(make_bridge(BRIDGE_NAME, nid))
    return nodes

# ---------- Link plan ----------
#
# (from, to, snr_fwd, snr_rev). Asymmetric links have snr_fwd != snr_rev.
# Source of truth: spec Section 8.

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

BRIDGE_LINKS = [
    ("bridge", "grace",  16, 16),
    ("bridge", "ivan",   14, 14),
    ("bridge", "quinn",  16, 16),
    ("bridge", "sam",    14, 14),
]

def _expand_directed(pairs):
    out = []
    for a, b, snr_ab, snr_ba in pairs:
        out.append({"from": a, "to": b, "snr": float(snr_ab), "bidir": False})
        out.append({"from": b, "to": a, "snr": float(snr_ba), "bidir": False})
    return out

def build_links() -> list[dict]:
    return (_expand_directed(L1_LINKS)
            + _expand_directed(L2_LINKS)
            + _expand_directed(BRIDGE_LINKS))

# ---------- Inject schedule ----------

def _inject(at_ms: int, node: str, command: str) -> dict:
    return {"at_ms": at_ms, "node": node, "command": command}

# Phase 1: DM-only (t=600s -> 1080s), back-and-forth bursts
PHASE1_INJECTS = [
    _inject(600_000,  "alice", "send bob hi"),
    _inject(612_000,  "bob",   "send alice hey"),
    _inject(628_000,  "alice", "send bob any-updates"),
    _inject(645_000,  "bob",   "send alice all-green"),
    _inject(665_000,  "alice", "send bob good"),
    _inject(685_000,  "bob",   "send alice ttyl"),

    _inject(720_000,  "carol", "send heidi ping"),
    _inject(738_000,  "heidi", "send carol pong"),
    _inject(765_000,  "carol", "send heidi howsignal"),
    _inject(792_000,  "heidi", "send carol weak-north"),
    _inject(820_000,  "carol", "send heidi ack"),
    _inject(845_000,  "heidi", "send carol 73"),

    _inject(840_000,  "leo",   "send rosa yo"),
    _inject(860_000,  "rosa",  "send leo yo-back"),
    _inject(890_000,  "leo",   "send rosa test-test"),
    _inject(920_000,  "rosa",  "send leo 5of5"),
    _inject(950_000,  "leo",   "send rosa out"),
    _inject(975_000,  "rosa",  "send leo 73"),

    _inject(960_000,  "dave",  "send peter bridge-test"),
    _inject(995_000,  "peter", "send dave got-it"),
    _inject(1030_000, "dave",  "send peter round-trip-ok"),
    _inject(1060_000, "peter", "send dave confirmed"),
]

# Phase 2: Channel-only (t=1080s -> 1680s), 4 posters on channel 7
PHASE2_INJECTS = [
    _inject(1_080_000, "eve",   "send_channel 7 L1-news-1"),
    _inject(1_110_000, "grace", "send_channel 7 L1-event-1"),
    _inject(1_140_000, "mia",   "send_channel 7 L2-news-1"),
    _inject(1_170_000, "quinn", "send_channel 7 L2-event-1"),

    _inject(1_260_000, "eve",   "send_channel 7 L1-news-2"),
    _inject(1_290_000, "grace", "send_channel 7 L1-event-2"),
    _inject(1_320_000, "mia",   "send_channel 7 L2-news-2"),
    _inject(1_350_000, "quinn", "send_channel 7 L2-event-2"),

    _inject(1_440_000, "eve",   "send_channel 7 L1-news-3"),
    _inject(1_470_000, "grace", "send_channel 7 L1-event-3"),
    _inject(1_500_000, "mia",   "send_channel 7 L2-news-3"),
    _inject(1_530_000, "quinn", "send_channel 7 L2-event-3"),

    _inject(1_620_000, "eve",   "send_channel 7 L1-news-4"),
]

# Phase 3: Mixed (t=1680s -> 2400s), round-2 DMs interleaved with posts
PHASE3_INJECTS = [
    _inject(1_680_000, "alice", "send bob round-2"),
    _inject(1_690_000, "mia",   "send_channel 7 L2-news-5"),
    _inject(1_710_000, "bob",   "send alice ack"),
    _inject(1_730_000, "carol", "send heidi hey-again"),
    _inject(1_755_000, "grace", "send_channel 7 L1-event-5"),
    _inject(1_770_000, "heidi", "send carol still-here"),
    _inject(1_800_000, "leo",   "send rosa second-pass"),
    _inject(1_830_000, "rosa",  "send leo yep"),
    _inject(1_860_000, "dave",  "send peter stress-test"),
    _inject(1_890_000, "eve",   "send_channel 7 L1-news-6"),
    _inject(1_920_000, "peter", "send dave loud-and-clear"),
    _inject(1_950_000, "alice", "send bob burst-plus"),
    _inject(1_980_000, "quinn", "send_channel 7 L2-event-6"),
    _inject(2_010_000, "carol", "send heidi burst-plus"),
    _inject(2_050_000, "heidi", "send carol burst-plus"),
    _inject(2_100_000, "leo",   "send rosa final"),
    _inject(2_130_000, "mia",   "send_channel 7 L2-news-7"),
    _inject(2_160_000, "rosa",  "send leo 73"),
    _inject(2_200_000, "dave",  "send peter final"),
    _inject(2_230_000, "peter", "send dave out"),
    _inject(2_260_000, "grace", "send_channel 7 L1-event-7"),
    _inject(2_300_000, "alice", "send bob out"),
    _inject(2_330_000, "bob",   "send alice 73-all"),
]

# ---------- Assembly ----------

DESC = (
    "Realistic debug scenario for delivery-rate investigation. "
    "21 nodes (10 L1 alice..judy + 10 L2 kate..tina + 1 bridge), "
    "40 min: 10 min quiet warmup + 30 min active traffic across "
    "three phases (DM-only, channel-only, mixed). Per-layer routing "
    "SF separation: L1=SF8 routing / SF7,9 data; L2=SF9 routing / "
    "SF6,10 data. Bridge dual-layer with 50/50 time-share (30 s "
    "period, 15 s home L1 + 15 s visit L2). Explicit asymmetric "
    "link plan (6 of 30 intra-layer pairs asymmetric, 14-18 dB "
    "forward / 5-8 dB reverse). 40 DMs across 4 conversation pairs "
    "(alice<->bob 1-hop, carol<->heidi 3-hop, leo<->rosa 3-hop, "
    "dave<->peter cross-layer 4-hop). 19 channel-7 posts from "
    "4 posters (eve+grace on L1, mia+quinn on L2). Clean baseline "
    "- no priority, no abuse, no mobility. Spec: docs/superpowers/"
    "specs/2026-05-22-s14-realistic-debug-scenario-design.md. "
    "Note: SF9 is L1-data and L2-routing - cross-layer airtime "
    "collisions on SF9 are expected (Principle 11 semantic "
    "isolation still holds)."
)

def build_scenario() -> dict:
    return {
        "_name": "s14_realistic_debug",
        "_desc": DESC,
        "simulation": {
            "duration_ms":              DURATION_MS,
            "step_ms":                  1,
            "warmup_ms":                WARMUP_MS,
            "seed":                     SEED,
            "node_startup_jitter_ms":   5_000,
            "radio":                    dict(RADIO),
        },
        "config": {
            "debug_start_ms": 0,
            "debug_end_ms":   DURATION_MS,
        },
        "nodes": build_nodes(),
        "topology": {
            "type":  "static_static",
            "links": build_links(),
        },
        "inject": PHASE1_INJECTS + PHASE2_INJECTS + PHASE3_INJECTS,
    }

# ---------- Validation ----------

def validate(scen: dict) -> None:
    assert len(scen["nodes"]) == 21, f"expected 21 nodes, got {len(scen['nodes'])}"
    names = [n["name"] for n in scen["nodes"]]
    assert sorted(names) == sorted(ALL_NAMES), "node name set mismatch"

    l1 = [n for n in scen["nodes"] if n["config"]["layer_id"] == 1 and not n["config"].get("is_gateway")]
    l2 = [n for n in scen["nodes"] if n["config"]["layer_id"] == 2]
    br = [n for n in scen["nodes"] if n["config"].get("is_gateway")]
    assert len(l1) == 10 and len(l2) == 10 and len(br) == 1, (len(l1), len(l2), len(br))

    for n in l1:
        assert n["config"]["routing_sf"] == L1_ROUTING_SF
        assert n["config"]["allowed_data_sfs"] == L1_DATA_SFS
    for n in l2:
        assert n["config"]["routing_sf"] == L2_ROUTING_SF
        assert n["config"]["allowed_data_sfs"] == L2_DATA_SFS
    bridge = br[0]
    assert bridge["config"]["routing_sf"] == L1_ROUTING_SF
    visit = bridge["config"]["gateway_layers"][0]
    assert visit["routing_sf"] == L2_ROUTING_SF
    assert visit["allowed_data_sfs"] == L2_DATA_SFS
    assert visit["period_ms"] == BRIDGE_VISIT_PERIOD_MS
    assert visit["duration_ms"] == BRIDGE_VISIT_DURATION_MS

    n_links = len(scen["topology"]["links"])
    assert n_links == 68, f"expected 68 directed links, got {n_links}"

    # Every link endpoint must be a real node.
    name_set = set(names)
    for l in scen["topology"]["links"]:
        assert l["from"] in name_set and l["to"] in name_set, l

    n_inject = len(scen["inject"])
    assert n_inject == 58, f"expected 58 inject events, got {n_inject}"

    # Inject timeline: monotonically non-decreasing across the three phases.
    # (Within a phase, bursts can be out of order; across phases, strict.)
    phase1_max = max(x["at_ms"] for x in scen["inject"] if x["at_ms"] < 1_080_000)
    phase2_min = min(x["at_ms"] for x in scen["inject"] if 1_080_000 <= x["at_ms"] < 1_680_000)
    phase3_min = min(x["at_ms"] for x in scen["inject"] if x["at_ms"] >= 1_680_000)
    assert phase1_max < 1_080_000 <= phase2_min, (phase1_max, phase2_min)
    assert phase2_min < 1_680_000 <= phase3_min, (phase2_min, phase3_min)

# ---------- Main ----------

def main():
    scen = build_scenario()
    validate(scen)
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(scen, f, indent=2)
        f.write("\n")
    n = scen["nodes"]
    print(f"wrote {OUT_PATH}: {len(n)} nodes, "
          f"{len(scen['topology']['links'])} directed links, "
          f"{len(scen['inject'])} inject events")

if __name__ == "__main__":
    main()
