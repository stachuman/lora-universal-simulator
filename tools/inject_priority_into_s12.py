#!/usr/bin/env python3
"""Patch s12 to convert ~10% of `send` commands to `send_priority`,
deterministically (seed=12). Preserves the file's existing content
(debug_window, etc.) — only mutates the commands list."""
import json
import random

PATH = "/home/staszek/lora-universal-simulator/scenarios/s12_channels_dense_two_layer.json"
PRIORITY_FRACTION = 0.10
SEED = 12

random.seed(SEED)

s = json.load(open(PATH))
cmds = s["commands"]

# Index all send (not send_channel) commands; pick 10% randomly.
send_indices = [i for i, c in enumerate(cmds) if c["command"].split()[0] == "send"]
n_priority = int(len(send_indices) * PRIORITY_FRACTION)
priority_pick = set(random.sample(send_indices, n_priority))

senders_priority_count = {}
for i in priority_pick:
    c = cmds[i]
    parts = c["command"].split(maxsplit=2)
    # "send <dst> <text>" -> "send_priority <dst> prio-<text>"
    new_cmd = f"send_priority {parts[1]} prio-{parts[2]}"
    cmds[i] = {**c, "command": new_cmd}
    senders_priority_count[c["node"]] = senders_priority_count.get(c["node"], 0) + 1

# Description: also bump the desc to mention priority injection.
desc = s.get("_desc", "")
if "priority" not in desc:
    s["_desc"] = (desc + f" PRIORITY INJECTION: {n_priority} of {len(send_indices)} "
                  f"`send` commands converted to `send_priority` (seed=12) — tests "
                  f"priority queue precedence + 5/hour cap interaction under storm.")

with open(PATH, "w") as f:
    json.dump(s, f, indent=2)

print(f"Converted {n_priority}/{len(send_indices)} send commands to send_priority.")
print(f"Across {len(senders_priority_count)} distinct senders. Max per sender: "
      f"{max(senders_priority_count.values())}")
