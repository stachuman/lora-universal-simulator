#!/usr/bin/env python3
"""Per-source / per-destination delivery summary for a sim run.

Reads the scenario config to enumerate `send …` commands, then walks
the events.ndjson to count delivered + dup_drop + giveup outcomes.
Useful to see whether a destination is unreachable systematically (vs.
random message-level loss).

Usage:
  delivery_summary.py CONFIG.json EVENTS.ndjson [--by source|dest|pair]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict


def load_names(config_path: str) -> tuple[dict[int, str], list]:
    with open(config_path) as f:
        cfg = json.load(f)
    names = {i: n["name"] for i, n in enumerate(cfg["nodes"])}
    return names, cfg.get("commands", [])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events")
    p.add_argument("--by", choices=("source", "dest", "pair"), default="dest")
    args = p.parse_args()

    names, commands = load_names(args.config)
    name_to_id = {v: k for k, v in names.items()}

    sent = Counter()       # by chosen dimension
    delivered = Counter()
    dup_drops = Counter()
    giveups_at_origin = Counter()
    giveups_at_forwarder = Counter()

    cmd_re = re.compile(r"send\s+(\S+)\s+(.+)$")

    # Build a map: (origin_id, payload-text-after-tag) → (src_name, dst_name) so
    # we can categorize delivered events. We rely on the fact that every send
    # text is unique within the scenario.
    payload_to_pair: dict[tuple[int, str], tuple[str, str]] = {}
    for c in commands:
        m = cmd_re.match(c["command"])
        if not m:
            continue
        dst = m.group(1)
        payload = m.group(2)
        src = c["node"]
        src_id = name_to_id.get(src)
        if src_id is None:
            continue
        payload_to_pair[(src_id, payload)] = (src, dst)

    def key(src, dst):
        if args.by == "source": return src
        if args.by == "dest":   return dst
        return f"{src}->{dst}"

    for src_id, payload in payload_to_pair:
        s, d = payload_to_pair[(src_id, payload)]
        sent[key(s, d)] += 1

    # Walk events
    with open(args.events) as f:
        for line in f:
            e = json.loads(line)
            if e.get("type") != "script_emit": continue
            et = e.get("emit_type")
            d = e.get("data", {})
            origin = d.get("origin")
            payload = d.get("payload")
            if origin is None or payload is None: continue
            pair = payload_to_pair.get((origin, payload))
            if not pair: continue
            s, dst = pair
            if et == "delivered":
                delivered[key(s, dst)] += 1
            elif et == "dup_drop":
                dup_drops[key(s, dst)] += 1
            elif et in ("rts_giveup", "data_ack_giveup", "tx_giveup"):
                node_id = e.get("node")
                if node_id == origin:
                    giveups_at_origin[key(s, dst)] += 1
                else:
                    giveups_at_forwarder[key(s, dst)] += 1

    keys = sorted(sent.keys())
    width = max(len(k) for k in keys) if keys else 8
    print(f"  {'key':<{width}}  sent  deliv  dup_drop  origin_gu  fwd_gu")
    total_s = total_d = total_dd = total_og = total_fg = 0
    for k in keys:
        s = sent[k]
        de = delivered[k]
        dd = dup_drops[k]
        og = giveups_at_origin[k]
        fg = giveups_at_forwarder[k]
        total_s += s; total_d += de; total_dd += dd; total_og += og; total_fg += fg
        print(f"  {k:<{width}}  {s:>4}  {de:>5}  {dd:>8}  {og:>9}  {fg:>6}")
    print(f"  {'TOTAL':<{width}}  {total_s:>4}  {total_d:>5}  {total_dd:>8}  {total_og:>9}  {total_fg:>6}")


if __name__ == "__main__":
    main()
