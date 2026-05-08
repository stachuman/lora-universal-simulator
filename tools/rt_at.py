#!/usr/bin/env python3
"""Show a node's view of the routing table at a given simulation time.

Replays all rt_update / rt_prune events for the chosen node up to the
given time and prints the resulting rt[] state. If --dest is given,
only that destination is shown (with a small history of how it got there).

Usage:
  rt_at.py CONFIG.json EVENTS.ndjson NODE TIME_MS [--dest D] [--history]
"""
from __future__ import annotations

import argparse
import json


def load_names(config_path: str) -> dict[int, str]:
    with open(config_path) as f:
        cfg = json.load(f)
    return {i: n["name"] for i, n in enumerate(cfg["nodes"])}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events")
    p.add_argument("node", help="node name or id")
    p.add_argument("time_ms", type=int)
    p.add_argument("--dest", help="filter to a specific destination")
    p.add_argument("--history", action="store_true", help="show rt_update/rt_prune timeline for the chosen dest(s)")
    args = p.parse_args()

    names = load_names(args.config)
    name_to_id = {v: k for k, v in names.items()}

    try:
        nid = int(args.node)
    except ValueError:
        nid = name_to_id.get(args.node)
        if nid is None:
            raise SystemExit(f"unknown node: {args.node}")

    dest_id = None
    if args.dest:
        try:
            dest_id = int(args.dest)
        except ValueError:
            dest_id = name_to_id.get(args.dest)
            if dest_id is None:
                raise SystemExit(f"unknown dest: {args.dest}")

    rt = {}            # dest_id -> {"primary": {...}, "alt": {...}}
    history = []
    with open(args.events) as f:
        for line in f:
            e = json.loads(line)
            if e.get("type") != "script_emit": continue
            if e.get("node") != nid: continue
            if e["time_ms"] > args.time_ms: break
            et = e.get("emit_type")
            d = e.get("data", {})
            if dest_id is not None and d.get("dest") != dest_id: continue
            if et == "rt_update":
                slot = d.get("slot", "primary")
                ent = rt.setdefault(d["dest"], {})
                ent[slot] = {
                    "next_hop": d.get("next"),
                    "hops": d.get("hops"),
                    "score": d.get("score"),
                    "t": e["time_ms"],
                }
                history.append(("update", e["time_ms"], d.get("dest"), slot, d.get("next"), d.get("hops"), d.get("score")))
            elif et == "rt_prune":
                slot = d.get("slot")
                ent = rt.get(d.get("dest"))
                if ent and slot in ent:
                    ent.pop(slot, None)
                    # collapse
                    if "primary" not in ent and "alt" in ent:
                        ent["primary"] = ent.pop("alt")
                    if not ent:
                        rt.pop(d["dest"], None)
                history.append(("prune", e["time_ms"], d.get("dest"), slot, d.get("via"), None, None))

    if args.history:
        print(f"# history for node={names.get(nid)} ({nid}) up to t={args.time_ms}ms"
              + (f" dest={names.get(dest_id)}" if dest_id is not None else ""))
        for kind, t, dest, slot, nxt, hops, score in history:
            ds = names.get(dest, f"#{dest}") if dest is not None else "—"
            ns = names.get(nxt, f"#{nxt}") if nxt is not None else "—"
            extra = f"hops={hops} score={score}" if hops is not None else ""
            print(f"  t={t:>8} {kind:6} dest={ds:20} slot={slot:8} via={ns:24} {extra}")
        print()

    print(f"# rt at node={names.get(nid)} ({nid}) t={args.time_ms}ms — {len(rt)} entries"
          + (f" (filtered to dest={names.get(dest_id)})" if dest_id is not None else ""))
    for dest, entry in sorted(rt.items(), key=lambda kv: names.get(kv[0], str(kv[0]))):
        ds = names.get(dest, f"#{dest}")
        print(f"  {ds}:")
        for slot in ("primary", "alt"):
            slot_e = entry.get(slot)
            if slot_e is None: continue
            ns = names.get(slot_e["next_hop"], f"#{slot_e['next_hop']}")
            print(f"    {slot:8} via={ns:24} hops={slot_e['hops']:>2} score={slot_e['score']:>4}  (t={slot_e['t']})")


if __name__ == "__main__":
    main()
