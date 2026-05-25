# s14 Realistic Debug Scenario — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate `scenarios/s14_realistic_debug.json` — a 21-node / 40-min two-layer scenario with per-layer routing SFs, explicit asymmetric link plan, and a 3-phase realistic chat traffic schedule — and validate it via smoke + full run.

**Architecture:** Follow the existing `tools/gen_*.py` pattern (see `gen_s13_pull_storm.py`). Write a single deterministic Python script that emits the full scenario JSON in one shot from in-script constants. The scenario JSON is the artifact; the generator is checked in so the design stays reproducible. Validation is done by running the scenario through `lus` (smoke + full) and checking analyzer output, not by Python unit tests (matches project convention).

**Tech Stack:** Python 3 (stdlib only — `json`, `os`), bash, `build/orchestrator/lus`, `tools/analyze.py`. Source of truth for design: `docs/superpowers/specs/2026-05-22-s14-realistic-debug-scenario-design.md`.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tools/gen_s14_realistic_debug.py` | Create | Python generator. Pure data → JSON, no args, idempotent. Splits into: constants, node builders, link builders, inject builders, assembly, validation, write. |
| `scenarios/s14_realistic_debug.json` | Create | Generated artifact. Checked in. Picked up by `test/run_tests.sh` from the `scenarios/s*.json` sweep. |
| `docs/SCENARIOS.md` | Modify | Add s14 to the scenario catalog with goal + key facts. |

No changes to `dv_dual_sf.lua` or the orchestrator. No new tests in `test/t*.json` — the test sweep already runs `scenarios/s*.json`.

---

## Task 1: Generator skeleton + constants

**Files:**
- Create: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Create the file with docstring + imports + top-level constants**

```python
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
```

- [ ] **Step 2: Verify the file is syntactically valid**

Run: `python3 -c "import ast; ast.parse(open('tools/gen_s14_realistic_debug.py').read())"`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: scaffold s14 scenario generator (constants only)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Node builders (L1, L2, bridge)

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append node-builder functions**

Add after the constants block:

```python
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
```

- [ ] **Step 2: Smoke-test the builders in a REPL inline**

Run: `python3 -c "import sys; sys.path.insert(0, 'tools'); from gen_s14_realistic_debug import build_nodes; ns = build_nodes(); assert len(ns) == 21, len(ns); print('L1:', sum(1 for n in ns if n['config']['layer_id'] == 1 and not n['config'].get('is_gateway'))); print('L2:', sum(1 for n in ns if n['config']['layer_id'] == 2)); print('bridge:', sum(1 for n in ns if n['config'].get('is_gateway')))"`
Expected:
```
L1: 10
L2: 10
bridge: 1
```

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: s14 node builders (10 L1 + 10 L2 + bridge)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Link builders (L1 + L2 + bridge)

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append link definitions and builder**

```python
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
```

- [ ] **Step 2: Verify the link expansion produces the expected count**

Run: `python3 -c "import sys; sys.path.insert(0, 'tools'); from gen_s14_realistic_debug import build_links, L1_LINKS, L2_LINKS, BRIDGE_LINKS; ls = build_links(); assert len(ls) == 68, len(ls); asym = sum(1 for a, b, x, y in (L1_LINKS + L2_LINKS) if x != y); assert asym == 6, asym; print('directed:', len(ls), 'asymmetric pairs:', asym)"`
Expected:
```
directed: 68 asymmetric pairs: 6
```

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: s14 link plan (15+15 intra-layer + 4 bridge, 6 asymmetric)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Inject schedule (Phase 1 — DM-only)

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append Phase 1 inject data + helper**

```python
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
```

Note on payload text: hyphens not spaces — the interactive REPL's `send` parser takes the first token after `send` as the destination and the **rest of the line** as the payload, so multi-word payloads work; but the inject pipeline tokenizes by spaces in some paths. Hyphens are safe everywhere.

- [ ] **Step 2: Verify Phase 1 count and ordering**

Run: `python3 -c "import sys; sys.path.insert(0, 'tools'); from gen_s14_realistic_debug import PHASE1_INJECTS; assert len(PHASE1_INJECTS) == 22, len(PHASE1_INJECTS); assert all(PHASE1_INJECTS[i]['at_ms'] <= PHASE1_INJECTS[i+1]['at_ms'] or PHASE1_INJECTS[i]['at_ms'] - PHASE1_INJECTS[i+1]['at_ms'] < 200_000 for i in range(len(PHASE1_INJECTS) - 1)); print('phase1:', len(PHASE1_INJECTS), 'events')"`
Expected:
```
phase1: 22 events
```

(The loose-ordering check is intentional: bursts overlap.)

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: s14 phase 1 inject schedule (22 DMs, 4 burst pairs)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Inject schedule (Phase 2 — Channel-only)

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append Phase 2 inject data**

```python
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
```

- [ ] **Step 2: Verify Phase 2 count and per-layer balance**

Run: `python3 -c "import sys; sys.path.insert(0, 'tools'); from gen_s14_realistic_debug import PHASE2_INJECTS; assert len(PHASE2_INJECTS) == 13, len(PHASE2_INJECTS); l1 = sum(1 for x in PHASE2_INJECTS if x['node'] in ('eve','grace')); l2 = sum(1 for x in PHASE2_INJECTS if x['node'] in ('mia','quinn')); assert l1 + l2 == 13 and l1 == 7 and l2 == 6, (l1, l2); print('phase2:', len(PHASE2_INJECTS), 'L1:', l1, 'L2:', l2)"`
Expected:
```
phase2: 13 L1: 7 L2: 6
```

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: s14 phase 2 inject schedule (13 channel posts, 4 waves)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Inject schedule (Phase 3 — Mixed)

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append Phase 3 inject data**

```python
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
```

- [ ] **Step 2: Verify Phase 3 mix**

Run: `python3 -c "import sys; sys.path.insert(0, 'tools'); from gen_s14_realistic_debug import PHASE3_INJECTS; assert len(PHASE3_INJECTS) == 23, len(PHASE3_INJECTS); dms = sum(1 for x in PHASE3_INJECTS if 'send_channel' not in x['command']); chans = sum(1 for x in PHASE3_INJECTS if 'send_channel' in x['command']); assert dms == 17 and chans == 6, (dms, chans); print('phase3:', len(PHASE3_INJECTS), 'DM:', dms, 'channel:', chans)"`
Expected:
```
phase3: 23 DM: 17 channel: 6
```

- [ ] **Step 3: Commit**

```bash
git add tools/gen_s14_realistic_debug.py
git commit -m "$(cat <<'EOF'
tools: s14 phase 3 inject schedule (17 DM + 6 channel, interleaved)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Assembly, validation, write

**Files:**
- Modify: `tools/gen_s14_realistic_debug.py`

- [ ] **Step 1: Append assembly, validation, and main**

```python
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
```

Total inject count: 22 + 13 + 23 = **58**, not 59 — the spec said "59" loosely; the generator's count of 58 is the actual schedule. Update validate() if you re-tune the schedule.

- [ ] **Step 2: Run the generator**

Run: `python3 tools/gen_s14_realistic_debug.py`
Expected:
```
wrote scenarios/s14_realistic_debug.json: 21 nodes, 68 directed links, 58 inject events
```

- [ ] **Step 3: Validate the generated JSON is valid JSON**

Run: `python3 -c "import json; d = json.load(open('scenarios/s14_realistic_debug.json')); print(d['_name'], 'OK', len(d['nodes']), 'nodes')"`
Expected:
```
s14_realistic_debug OK 21 nodes
```

- [ ] **Step 4: Commit both files**

```bash
git add tools/gen_s14_realistic_debug.py scenarios/s14_realistic_debug.json
git commit -m "$(cat <<'EOF'
scenarios: add s14 realistic debug (21 nodes, 40 min, 3 phases)

Generator and produced JSON for the 21-node two-layer scenario
with per-layer routing SFs, asymmetric links, and a 3-phase
chat traffic schedule. Designed for isolating delivery-rate
problems before re-running against the s12 6h stress test.

Spec: docs/superpowers/specs/2026-05-22-s14-realistic-debug-
scenario-design.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Smoke run — boots and emits expected events

**Files:**
- (none modified)

- [ ] **Step 1: Confirm `lus` is built**

Run: `ls -l build/orchestrator/lus`
Expected: file exists and is executable. If not, run `cmake --build build -j 4`.

- [ ] **Step 2: Smoke-run for 30 s of simulated time (override duration)**

The scenario file has `duration_ms = 2400000`. For a smoke run we want a short pass to confirm boot. Use a temporary copy:

Run:
```bash
python3 -c "
import json, copy
d = json.load(open('scenarios/s14_realistic_debug.json'))
d['simulation']['duration_ms'] = 30_000
d['config']['debug_end_ms'] = 30_000
# Drop inject events that won't fire within 30 s
d['inject'] = [x for x in d['inject'] if x['at_ms'] < 30_000]
json.dump(d, open('/tmp/s14_smoke.json', 'w'), indent=2)
print('smoke duration:', d['simulation']['duration_ms'], 'injects:', len(d['inject']))
"
build/orchestrator/lus /tmp/s14_smoke.json --events /tmp/s14_smoke.ndjson
```

Expected: exit 0, NDJSON file produced (size > 0). No "FAIL"/"ERROR" lines on stdout.

- [ ] **Step 3: Confirm every node emitted at least one BCN**

Run:
```bash
python3 -c "
import json
bcn_by = set()
for line in open('/tmp/s14_smoke.ndjson'):
    e = json.loads(line)
    if e.get('event') == 'tx_initiating' and e.get('frame_type') == 'B':
        bcn_by.add(e['node'])
print('nodes that sent BCN:', len(bcn_by), sorted(bcn_by))
assert len(bcn_by) == 21, bcn_by
"
```
Expected: 21 nodes listed, no AssertionError.

- [ ] **Step 4: Confirm L1 BCNs are on SF8 and L2 BCNs are on SF9 (sample check)**

Run:
```bash
python3 -c "
import json
seen = {}
for line in open('/tmp/s14_smoke.ndjson'):
    e = json.loads(line)
    if e.get('event') == 'tx_initiating' and e.get('frame_type') == 'B':
        seen.setdefault(e['node'], set()).add(e.get('sf'))
print('alice BCN SFs:', seen.get('alice'))
print('kate  BCN SFs:', seen.get('kate'))
print('bridge BCN SFs:', seen.get('bridge'))
assert seen.get('alice') == {8}, seen.get('alice')
assert seen.get('kate') == {9}, seen.get('kate')
assert seen.get('bridge') >= {8}, seen.get('bridge')
"
```
Expected:
```
alice BCN SFs: {8}
kate  BCN SFs: {9}
bridge BCN SFs: {8, 9} or {8}    (depends on whether the 15 s visit window happened to overlap a BCN trigger in 30 s)
```

- [ ] **Step 5: Run the unit-test suite to confirm no regressions**

Run: `bash test/run_tests.sh test/t*.json 2>&1 | tail -10`
Expected: every test ending in PASS, summary line "N/N PASS".

(Note: we deliberately skip the `scenarios/s*.json` pass — that would run the full 6h s12, which is for Task 10.)

- [ ] **Step 6: No commit needed for the smoke check itself.** If any of steps 2-5 failed, treat that as a defect and fix the generator before proceeding.

---

## Task 9: Document s14 in docs/SCENARIOS.md

**Files:**
- Modify: `docs/SCENARIOS.md`

- [ ] **Step 1: Read the current bottom of docs/SCENARIOS.md to find the right insertion point**

Run: `tail -40 docs/SCENARIOS.md`
Expected: a section listing s13 / current scenarios with a consistent format you can match.

- [ ] **Step 2: Append a new s14 section in the established style**

Insert after the existing s13 entry (or wherever the catalog ends). Use this content (adjust heading level to match the file's convention — likely `##` or `###`):

```markdown
### s14 — Realistic debug scenario

**File:** `scenarios/s14_realistic_debug.json`
**Generator:** `tools/gen_s14_realistic_debug.py`
**Wall-clock:** ~30-60 s for the full 40-min simulated run.

**Goal.** Small, debuggable, realistic scenario for isolating
delivery-rate problems before re-testing against s12 (6 h dense).
Clean baseline — no priority, no abuse, no mobility.

**Shape.** 21 nodes (10 L1 alice..judy + 10 L2 kate..tina + 1
dual-layer `bridge`). Per-layer routing SF separation: L1 routing
SF8 / data [7,9]; L2 routing SF9 / data [6,10]. Explicit
asymmetric link plan: 6 of 30 intra-layer pairs are asymmetric
(forward 14-18 dB / reverse 5-8 dB). Bridge time-shares 50/50
between L1 (home) and L2 (visit) on a 30 s period.

**Timeline.**

| Phase | Time     | Activity                                 |
|-------|----------|------------------------------------------|
| Quiet | 0-10 min | BCN exchange under full physics          |
| 1     | 10-18 min| DM-only, 4 burst pairs, 22 events        |
| 2     | 18-28 min| Channel-only, 4 posters x 4 waves, 13 events |
| 3     | 28-40 min| Mixed: round-2 DMs + posts, 23 events    |

**DM conversation pairs.**

| Pair             | Layer       | Expected hops |
|------------------|-------------|---------------|
| alice <-> bob    | L1          | 1             |
| carol <-> heidi  | L1          | 3 (asym link in path) |
| leo <-> rosa     | L2          | 3 (asym link in path) |
| dave <-> peter   | cross-layer | 4 (via bridge) |

**Channel posters.** eve + grace on L1 channel 7; mia + quinn on
L2 channel 7. Per Principle 11, L1 posts stay in L1 and L2 posts
stay in L2 — bridge does **not** carry channel msgs across.

**Coexistence note.** SF9 is L1-data *and* L2-routing. L1 channel
broadcasts at SF9 are received-but-discarded by L2 nodes (semantic
isolation holds), but the airtime collisions are cross-layer — a
realistic production coexistence issue this scenario exposes.

**Use.** Run, look at `tools/analyze.py` output for: DM delivery
rate per pair / hop / layer, channel reach %, per-phase counters,
asymmetric-link route choice, Principle-11 leak check, SF9
cross-layer airtime contention.
```

- [ ] **Step 3: Verify the edit landed and renders sanely**

Run: `grep -c "s14" docs/SCENARIOS.md`
Expected: at least 3 matches (the heading + filename + body references).

- [ ] **Step 4: Commit**

```bash
git add docs/SCENARIOS.md
git commit -m "$(cat <<'EOF'
docs: catalog s14 realistic debug scenario in SCENARIOS.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Full 40-min run + analyzer baseline

**Files:**
- (none modified — read-only metrics capture)

- [ ] **Step 1: Run the full scenario**

Run:
```bash
build/orchestrator/lus scenarios/s14_realistic_debug.json \
    --events /tmp/s14_full.ndjson
```
Expected: exit 0. Wall-clock ~30-60 s. NDJSON output > 10 MB likely.

- [ ] **Step 2: Run the analyzer and capture its report**

Run:
```bash
python3 tools/analyze.py scenarios/s14_realistic_debug.json /tmp/s14_full.ndjson \
    > /tmp/s14_analysis.txt 2>&1
cat /tmp/s14_analysis.txt | head -80
```
Expected: analyzer's standard 5-dimension report. No traceback / "ERROR".

- [ ] **Step 3: Pull out the key baseline numbers and report them**

Read the analysis output and note (in the next message to the user, not as a commit):
- Overall DM delivery: `delivered / sent` and `% delivered`
- Channel reach: `channel_msg_received` count per post, derived %
- Phase-bucketed counters (analyze.py likely needs phase boundaries — if it doesn't bucket by phase natively, that's a follow-up; just capture the raw events for now)
- Principle 11: any L2 node receiving an L1 channel msg (`channel_msg_received` with source L1 origin reaching an L2 node) — must be 0

Run (sanity-check Principle 11 directly):
```bash
python3 -c "
import json
l1_origins = {'alice','bob','carol','dave','eve','frank','grace','heidi','ivan','judy'}
l2_origins = {'kate','leo','mia','ned','olga','peter','quinn','rosa','sam','tina'}
violations = []
for line in open('/tmp/s14_full.ndjson'):
    e = json.loads(line)
    if e.get('event') != 'channel_msg_received': continue
    if e.get('source') == 'self_originate': continue
    rcvr = e['node']
    # Recover origin from id top byte (per channel_msg_id layout)
    mid = e.get('id', 0)
    origin_id = (mid >> 24) & 0xff
    # Map origin_id to a name (1-10 = L1, 11-20 = L2, 21 = bridge)
    if 1 <= origin_id <= 10 and rcvr in l2_origins:
        violations.append((origin_id, rcvr, e.get('channel_id')))
    if 11 <= origin_id <= 20 and rcvr in l1_origins:
        violations.append((origin_id, rcvr, e.get('channel_id')))
print('cross-layer channel leaks:', len(violations))
for v in violations[:10]: print(v)
"
```
Expected: `cross-layer channel leaks: 0`. Any non-zero is a Principle-11 regression.

- [ ] **Step 4: No commit needed.** Report findings to the user — that's the deliverable.

---

## Self-review

**Spec coverage:**
- Spec §2 (topology, names, pairs, posters) → Tasks 2, 3 (node + link builders).
- Spec §3 (timeline & phases) → Tasks 4, 5, 6 (inject schedules per phase).
- Spec §4 (inject schedule) → Tasks 4, 5, 6.
- Spec §5 (per-node config including dual-layer bridge) → Task 2.
- Spec §6 (simulation block, duty_cycle=0.01, warmup_ms=0) → Task 1 constants + Task 7 assembly.
- Spec §7 (debug window 0..duration) → Task 7 assembly.
- Spec §8 (link tables L1 + L2 + bridge) → Task 3.
- Spec §9 (file layout: `scenarios/s14_realistic_debug.json`, `_desc` with topology overview) → Task 7 (`DESC` constant).
- Spec §10 (expected metrics) → Task 10 analyzer + Principle-11 check.
- Spec §11 (open questions) → not implementation work; recorded in spec.
- Spec §12 (generator helper note) → Tasks 1-7 implement it.

No spec section is unaddressed.

**Placeholder scan:** no TBD/TODO/"appropriate"/"similar to" — every step shows the exact code or command.

**Type/signature consistency:**
- `_inject(at_ms, node, command)` used identically in Tasks 4, 5, 6.
- `make_l1_node` / `make_l2_node` / `make_bridge` all return the same node-shaped dict (verified via the consistent JSON keys).
- `build_nodes()` / `build_links()` return types are `list[dict]`, consumed in Task 7's `build_scenario()`.
- `validate()` constants (`L1_ROUTING_SF`, `BRIDGE_VISIT_DURATION_MS`, etc.) all defined in Task 1.

**Self-review issues found:** Spec §4 ("Grand totals") and §9 reference "59 injects"; the generator's actual schedule sums to 58 (22+13+23). The plan's validation hard-checks 58 — call this out in Task 7 step 1 (already done in the note above the validation block).

---

## Plan complete

Plan saved to `docs/superpowers/plans/2026-05-22-s14-realistic-debug-scenario.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, you (or I) review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session via the executing-plans skill, batch execution with checkpoints for review.

Which approach?
