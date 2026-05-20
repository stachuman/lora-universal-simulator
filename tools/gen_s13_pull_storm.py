#!/usr/bin/env python3
"""Generate scenarios/s13_channel_pull_storm.json.

Minimal repro for the channel-gossip pull-on-BCN-digest contention storm
uncovered in s12 (commits 1cf3a41 / 9671c72). 12 nodes in mutual radio
range, one poster ("hub"), 11 candidates ("pull01".."pull11"). All links
are clean (~20 dB SNR, -68 dBm RSSI) so any collision we see is purely
the pull mechanism stepping on itself — not weak-signal misses.

Timeline:
  t=  0 s   nodes boot
  t=  5 s   first BCN cycle (period 30 s) — joins, route convergence
  t= 60 s   hub send_channel 7 storm-msg
  t= ~90 s  next BCN from hub carries CHANNEL_DIGEST → 11 candidates
            each schedule a pull within [0, 500] ms jitter. RTS/CTS +
            pull-response DATA frames all compete for airtime.

Expected analyzer (30) output: peak_pull_burst window shows 11
channel_pull_sent + multiple rx_collision + tx_deferred_LBT + rts_retry
in <500 ms. That's the signal a real fix should drive down.

Run:
  python3 tools/gen_s13_pull_storm.py
  build/orchestrator/lus scenarios/s13_channel_pull_storm.json \\
      --events /tmp/s13.ndjson
  python3 tools/analyze.py scenarios/s13_channel_pull_storm.json /tmp/s13.ndjson
"""
import json
import os

N_CANDIDATES = 11
HUB_NAME = "hub"

DURATION_MS = 5 * 60 * 1000     # 5 min — enough for ~10 BCN cycles
BCN_PERIOD_MS = 30_000           # tight so pull-storm shows up fast
POST_AT_MS = 60_000              # let routing converge first
SEED = 1213

# Same physical layer as s12 (CEPT g3 / SF8 / BW125 territory; the radio
# block uses BW kHz so 62.5 here).
RADIO = {
    "sf": 8, "bw": 62.5, "cr": 5,
    "max_packet_bytes": 255, "snr_coherence_ms": 0,
    "duty_cycle": 0.10,
}

def make_node(name: str, node_id: int) -> dict:
    return {
        "name":        name,
        "node_id":     node_id,
        "key_hash32":  "0xCAFE1213",        # same group key across cluster
        "script":      "scenarios/dv_dual_sf.lua",
        "config": {
            "layer_id":                  1,
            "routing_sf":                8,
            "allowed_data_sfs":          [7, 9, 10],
            "beacon_period_ms":          BCN_PERIOD_MS,
            "discovery_beacon_period_ms": 4000,
            "state_snapshot_period_ms":  30000,
            # Disable the BCN quiet-channel throttle. In a fully-meshed
            # 12-node cluster the default threshold (= BCN period) keeps
            # the hub permanently throttled because it always hears a
            # neighbour BCN within the last 30 s, so it never gets to
            # advertise the channel digest. Setting 0 lets every BCN
            # fire on schedule and the pull mechanism actually triggers.
            # (Matches the same setting in t65/t66 channel happy-path
            # tests; in real-world topologies the cluster is rarely
            # fully-meshed so the throttle doesn't deadlock like this.)
            "quiet_threshold_ms":        0,
        },
    }

names = [HUB_NAME] + [f"pull{i:02d}" for i in range(1, N_CANDIDATES + 1)]
nodes = [make_node(name, i + 1) for i, name in enumerate(names)]

# All-to-all explicit topology: every pair has a clean (~20 dB) bidir link.
# Explicit topology only — no path_loss model (project rule).
links = []
for a in names:
    for b in names:
        if a == b:
            continue
        links.append({
            "from": a, "to": b,
            "snr": 20.0, "rssi": -68.0,
            "snr_std_dev": 0, "bidir": False,
        })

scenario = {
    "_name": "s13_channel_pull_storm",
    "_desc": (
        "Minimal repro for the channel-gossip pull-on-BCN-digest "
        "contention storm uncovered in s12 (analyzer commits 1cf3a41 / "
        "9671c72). 12 nodes in mutual radio range, 1 poster + 11 "
        "candidates. BCN period 30 s; hub posts a single channel msg "
        "at t=60 s. Next BCN carries CHANNEL_DIGEST → all 11 candidates "
        "schedule Q_CHANNEL_PULL within [0, 500] ms jitter. The "
        "resulting RTS+pull-response storm collides with itself. "
        "Run analyzer; section (30) peak_pull_burst should show 11 "
        "channel_pull_sent + multiple rx_collision / tx_deferred_LBT "
        "in <500 ms — that's the symptom any pull-scheduling fix needs "
        "to drive down."
    ),
    "simulation": {
        "duration_ms":            DURATION_MS,
        "step_ms":                1,
        "warmup_ms":              0,
        "seed":                   SEED,
        "node_startup_jitter_ms": 0,
        "radio":                  RADIO,
    },
    # Scenario-wide debug window: full duration so script_log lines
    # accompany every beacon_tx / pull / channel_msg_received and we
    # can trace why the digest is or isn't populated.
    "config": {
        "debug_start_ms": 0,
        "debug_end_ms":   DURATION_MS,
    },
    "nodes": nodes,
    "topology": {"links": links},
    "commands": [
        {"at_ms": POST_AT_MS, "node": HUB_NAME,
         "command": "send_channel 7 storm-msg"},
    ],
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "scenarios", "s13_channel_pull_storm.json")
out = os.path.normpath(out)
with open(out, "w") as f:
    json.dump(scenario, f, indent=2)
print(f"wrote {out}")
print(f"  nodes={len(nodes)} links={len(links)} duration_ms={DURATION_MS} "
      f"bcn_period_ms={BCN_PERIOD_MS}")
