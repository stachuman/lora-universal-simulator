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
