#!/usr/bin/env python3
"""Per-DM delivery + hop breakdown for a sim run.

Walks the events.ndjson and reconstructs the lifecycle of every
unicast DM (`send <dst> ...`) injected via the scenario's `commands`
block, splitting outcomes by:

  arrived       — destination decoded the DATA frame at least once
  ack_closed    — originator received an ACK / send_drained closure
  giveup        — originator gave up before delivery (send_giveup)
  in_flight     — neither arrival nor giveup observed by run end

Also reports hop count actually taken (distinct nodes that emitted an
RTS or DATA forward for the message), so the "expected hops" from the
scenario topology can be compared against the path the firmware
actually chose.

Identifies a message by the triple (origin_node_id, dst_node_id, ctr).
`ctr_lo` truncation is not an issue inside a single scenario where the
8-bit counter wraps only every 256 messages per origin (s14 sends at
most ~10 per origin).

Usage:
  dm_delivery_breakdown.py CONFIG.json EVENTS.ndjson [--all]

Without `--all`, only pairs that appear in the scenario's `commands`
block as `send <dst> ...` are shown. With `--all`, every observed
(origin, dst) is shown — useful for catching unexpected traffic.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict


def load_config(path: str):
    with open(path) as f:
        cfg = json.load(f)
    nodes = cfg["nodes"]
    # Firmware id ("node_id" in config) is what shows up in event
    # data.origin / data.dst. Event "node" is the orchestrator slot
    # index (0-based array position).
    id_to_name = {n["node_id"]: n["name"] for n in nodes}
    name_to_id = {n["name"]: n["node_id"] for n in nodes}
    slot_to_id = {i: n["node_id"] for i, n in enumerate(nodes)}
    return cfg, id_to_name, name_to_id, slot_to_id


def configured_pairs(cfg, name_to_id):
    """Return set of (origin_id, dst_id) pairs that the scenario injects."""
    pairs = set()
    send_re = re.compile(r"^send\s+(\S+)\s+", re.IGNORECASE)
    for c in cfg.get("commands", []):
        node = c.get("node")
        cmd = c.get("command", "")
        m = send_re.match(cmd)
        if not m:
            continue
        dst = m.group(1)
        if node in name_to_id and dst in name_to_id:
            pairs.add((name_to_id[node], name_to_id[dst]))
    return pairs


def msg_key(emit_data, default_origin=None):
    """Extract (origin, dst, ctr) from a script_emit data dict."""
    origin = emit_data.get("origin")
    if origin is None:
        origin = emit_data.get("src")
    if origin is None:
        origin = default_origin
    dst = emit_data.get("dst")
    ctr = emit_data.get("ctr_lo")
    if ctr is None:
        ctr = emit_data.get("ctr")
    if origin is None or dst is None or ctr is None:
        return None
    return (origin, dst, ctr)


def walk_events(events_path, slot_to_id):
    """Yield (firmware_id, emit_type, data) for every script_emit.

    Translates the event's `node` field (orchestrator slot index) into
    the firmware node_id used by all `data.*` references.
    """
    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("type") != "script_emit":
                continue
            slot = e.get("node")
            fid = slot_to_id.get(slot, slot)
            yield fid, e.get("emit_type"), e.get("data", {})


def analyse(events_path, slot_to_id):
    """Return dict: (origin, dst, ctr) -> dict of lifecycle facts."""
    msgs = {}

    def m(k):
        if k not in msgs:
            msgs[k] = {
                "enqueued": False,
                "arrived": False,
                "ack_closed": False,
                "giveup": False,
                "giveup_reason": None,
                "carriers": set(),
                "first_tx_ms": None,
                "arrived_ms": None,
                "closed_ms": None,
            }
        return msgs[k]

    for node, et, d in walk_events(events_path, slot_to_id):
        if et == "tx_enqueue":
            k = msg_key(d, default_origin=node)
            if k is None:
                continue
            origin, dst, ctr = k
            if origin != node:
                continue
            if d.get("flags", 0) & 0x80:
                continue
            rec = m(k)
            rec["enqueued"] = True

        elif et in ("rts_tx", "data_tx"):
            k = msg_key(d, default_origin=None)
            if k is None:
                continue
            rec = m(k)
            rec["carriers"].add(node)
            if rec["first_tx_ms"] is None and "t_ms" in d:
                rec["first_tx_ms"] = d.get("t_ms")

        elif et == "data_rx":
            k = msg_key(d, default_origin=None)
            if k is None:
                continue
            origin, dst, ctr = k
            if node != dst:
                continue
            rec = m(k)
            rec["arrived"] = True
            if rec["arrived_ms"] is None:
                rec["arrived_ms"] = d.get("t_ms")

        elif et == "send_drained":
            k = msg_key(d, default_origin=node)
            if k is None:
                continue
            origin, dst, ctr = k
            if origin != node:
                continue
            rec = m(k)
            rec["ack_closed"] = True
            rec["closed_ms"] = d.get("t_ms")

        elif et == "send_giveup":
            k = msg_key(d, default_origin=node)
            if k is None:
                continue
            origin, dst, ctr = k
            if origin != node:
                continue
            rec = m(k)
            rec["giveup"] = True
            rec["giveup_reason"] = d.get("reason") or d.get("terminal")
            rec["closed_ms"] = d.get("t_ms")

    return msgs


def summarise(msgs, pair_filter, id_to_name):
    """Roll messages up per pair. Returns list of dicts."""
    by_pair = defaultdict(list)
    for (origin, dst, ctr), rec in msgs.items():
        if pair_filter is not None and (origin, dst) not in pair_filter:
            continue
        by_pair[(origin, dst)].append(rec)

    rows = []
    for (origin, dst), recs in sorted(by_pair.items()):
        n = len(recs)
        arrived = sum(1 for r in recs if r["arrived"])
        ack_closed = sum(1 for r in recs if r["ack_closed"])
        giveup = sum(1 for r in recs if r["giveup"] and not r["arrived"])
        in_flight = n - arrived - giveup
        hops = [len(r["carriers"]) for r in recs if r["arrived"]]
        mean_hops = (sum(hops) / len(hops)) if hops else None
        giveup_reasons = [r["giveup_reason"] for r in recs
                          if r["giveup"] and not r["arrived"] and r["giveup_reason"]]
        rows.append({
            "origin":     id_to_name.get(origin, f"#{origin}"),
            "dst":        id_to_name.get(dst, f"#{dst}"),
            "sent":       n,
            "arrived":    arrived,
            "ack_closed": ack_closed,
            "giveup":     giveup,
            "in_flight":  in_flight,
            "mean_hops":  mean_hops,
            "reasons":    giveup_reasons,
        })
    return rows


def render(rows):
    if not rows:
        print("(no matching DM messages found)")
        return
    header = ["pair", "sent", "arr", "arr%", "ack", "ack%",
              "giveup", "in_flight", "mean_hops"]
    fmt = "{:<22} {:>4} {:>4} {:>5} {:>4} {:>5} {:>6} {:>9} {:>9}"
    print(fmt.format(*header))
    print("-" * 80)
    tot = {"sent": 0, "arrived": 0, "ack_closed": 0,
           "giveup": 0, "in_flight": 0}
    for r in rows:
        pair = f"{r['origin']:>10} -> {r['dst']:<8}"
        arr_pct = f"{100*r['arrived']/r['sent']:.0f}%" if r["sent"] else "-"
        ack_pct = f"{100*r['ack_closed']/r['sent']:.0f}%" if r["sent"] else "-"
        mean_hops = f"{r['mean_hops']:.1f}" if r["mean_hops"] is not None else "-"
        print(fmt.format(pair, r["sent"], r["arrived"], arr_pct,
                         r["ack_closed"], ack_pct, r["giveup"],
                         r["in_flight"], mean_hops))
        for k in tot:
            tot[k] += r[k]
    print("-" * 80)
    arr_pct = f"{100*tot['arrived']/tot['sent']:.0f}%" if tot["sent"] else "-"
    ack_pct = f"{100*tot['ack_closed']/tot['sent']:.0f}%" if tot["sent"] else "-"
    print(fmt.format("TOTAL", tot["sent"], tot["arrived"], arr_pct,
                     tot["ack_closed"], ack_pct, tot["giveup"],
                     tot["in_flight"], "-"))

    # Failure-reason breakdown.
    reasons = defaultdict(int)
    for r in rows:
        for x in r["reasons"]:
            reasons[x] += 1
    if reasons:
        print()
        print("giveup reasons:")
        for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"  {k:<40} {v}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events")
    p.add_argument("--all", action="store_true",
                   help="include pairs not present in scenario commands")
    args = p.parse_args()

    cfg, id_to_name, name_to_id, slot_to_id = load_config(args.config)
    msgs = analyse(args.events, slot_to_id)
    pair_filter = None if args.all else configured_pairs(cfg, name_to_id)
    rows = summarise(msgs, pair_filter, id_to_name)
    render(rows)


if __name__ == "__main__":
    main()
