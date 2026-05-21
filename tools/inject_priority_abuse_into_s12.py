#!/usr/bin/env python3
"""Patch s12 to add an abusive priority-send pattern from a SINGLE node.

Tests the originator self-cap (`priority_send_capped`) and the 1st-hop
peer throttle (`rts_drop_originator_priority_throttle`) under storm.

Pattern: pick one chatty L1 node, inject 20 send_priority commands at
~90-second intervals starting at t=300000 (5 min in). At a 5-per-hour
cap, only ~5 of those 20 should pass; the remaining 15 should be
throttled (either self-capped at the sender or 1st-hop-dropped at
neighbours).

Idempotent: looks for the "abuse-msg" prefix and skips if already
injected. Re-running re-applies cleanly.
"""
import json
import sys

PATH = "/home/staszek/lora-universal-simulator/scenarios/s12_channels_dense_two_layer.json"
ABUSER = "Cafe"     # L1 chatty node — already a channel poster
ABUSE_COUNT = 20
ABUSE_START_MS = 300_000       # 5 minutes in
ABUSE_INTERVAL_MS = 90_000     # ~90 s between sends → 30 min total
ABUSE_PREFIX = "abuse-msg"

s = json.load(open(PATH))
cmds = s["commands"]

# Idempotent guard
existing = [c for c in cmds if ABUSE_PREFIX in c.get("command", "")]
if existing:
    print(f"already injected ({len(existing)} abuse commands present); skipping.")
    sys.exit(0)

# Find a plausible victim destination — any L1 node that isn't the abuser
victims = [n["name"] for n in s["nodes"]
           if n.get("config", {}).get("layer_id") == 1 and n["name"] != ABUSER]
if not victims:
    sys.exit("no L1 victim candidates")
victim = victims[0]

added = 0
for i in range(ABUSE_COUNT):
    at_ms = ABUSE_START_MS + i * ABUSE_INTERVAL_MS
    cmds.append({
        "at_ms": at_ms,
        "node": ABUSER,
        "command": f"send_priority {victim} {ABUSE_PREFIX}-{i}",
    })
    added += 1

# Re-sort by at_ms (orchestrator usually does this anyway, but explicit is safer)
cmds.sort(key=lambda c: c["at_ms"])

desc = s.get("_desc", "")
if "ABUSE" not in desc:
    s["_desc"] = (desc + f" ABUSE INJECTION: {ABUSE_COUNT} send_priority from "
                  f"{ABUSER}→{victim} at {ABUSE_INTERVAL_MS//1000}s intervals "
                  f"starting at t={ABUSE_START_MS}ms. Tests "
                  f"originator_priority_max_per_window={s.get('config', {}).get('originator_priority_max_per_window', 5)}/h "
                  f"cap and 1st-hop throttle response.")

with open(PATH, "w") as f:
    json.dump(s, f, indent=2)

print(f"injected {added} priority abuse commands from {ABUSER} → {victim}")
print(f"  range: t={ABUSE_START_MS}ms to t={ABUSE_START_MS + (ABUSE_COUNT-1)*ABUSE_INTERVAL_MS}ms "
      f"({(ABUSE_COUNT-1)*ABUSE_INTERVAL_MS/60000:.1f} min)")
print(f"  rate:  ~{3600/((ABUSE_INTERVAL_MS//1000)):.1f}/hr (cap is 5/hr — ~{ABUSE_COUNT*15/20:.0f} should be throttled)")
