#!/usr/bin/env python3
"""Trace a single end-to-end message through the events.ndjson log.

Identifies a message by (origin_name, origin_seq) — the same pair the
dv_dual_sf.lua protocol uses for end-to-end identification — and prints
every script_emit event tagged with that message in time order, with
node names resolved from the config JSON.

Usage:
  trace_msg.py CONFIG.json EVENTS.ndjson ORIGIN ORIGIN_SEQ
  trace_msg.py CONFIG.json EVENTS.ndjson --by-payload "Nto1 alice->dave seq=1"

The --by-payload form scans for any script_emit whose `payload` field
matches the given substring, derives the (origin, origin_seq) from the
first match, and traces from there.
"""
from __future__ import annotations

import argparse
import json
import sys


def load_names(config_path: str) -> dict[int, str]:
    with open(config_path) as f:
        cfg = json.load(f)
    return {i: n["name"] for i, n in enumerate(cfg["nodes"])}


def name_of(names: dict[int, str], nid):
    if nid is None:
        return "—"
    return names.get(nid, f"#{nid}")


KEY_EMITS = {
    "tx_enqueue", "tx_dequeue", "tx_giveup", "tx_blind_defer",
    "rts_tx", "rts_retry", "rts_giveup", "rts_already_acked",
    "rts_rx", "rts_rx_dup", "rts_rejected_busy",
    "cts_tx", "cts_rx",
    "data_tx", "data_rx", "data_rx_timeout",
    "ack_tx", "ack_rx", "data_ack_giveup",
    "nack_tx", "nack_rx",
    "delivered", "dup_drop",
    "forward_queued", "forward_fail",
    "path_switch",
    "send_no_route",
}


def find_origin_seq_for_payload(events_path: str, payload_sub: str, names: dict[int, str]):
    with open(events_path) as f:
        for line in f:
            e = json.loads(line)
            if e.get("type") != "script_emit":
                continue
            d = e.get("data", {})
            p = d.get("payload")
            if isinstance(p, str) and payload_sub in p:
                origin = d.get("origin")
                seq = d.get("origin_seq")
                if origin is not None and seq is not None:
                    return origin, seq
    return None


def trace(config_path: str, events_path: str, origin_id: int, origin_seq: int, only_key: bool):
    names = load_names(config_path)
    print(f"# trace origin={name_of(names, origin_id)} (#{origin_id}) origin_seq={origin_seq}")
    rows = []
    with open(events_path) as f:
        for line in f:
            e = json.loads(line)
            if e.get("type") != "script_emit":
                continue
            d = e.get("data", {})
            if d.get("origin") != origin_id or d.get("origin_seq") != origin_seq:
                continue
            et = e.get("emit_type", "")
            if only_key and et not in KEY_EMITS:
                continue
            rows.append(e)

    if not rows:
        print("# (no events match — wrong origin/seq?)")
        return

    for e in rows:
        d = e["data"]
        et = e["emit_type"]
        nm = name_of(names, e["node"])
        bits = []
        for k in ("from", "src", "next", "dst", "to_next", "from_next"):
            if k in d:
                bits.append(f"{k}={name_of(names, d[k])}")
        for k in ("ctr_lo", "reason", "slot", "via"):
            if k in d:
                v = d[k]
                if k == "via":
                    v = name_of(names, v)
                bits.append(f"{k}={v}")
        if "payload" in d and et in ("tx_enqueue", "tx_dequeue", "rts_giveup",
                                      "data_ack_giveup", "delivered", "send_no_route"):
            bits.append(f"payload={d['payload']!r}")
        print(f"  t={e['time_ms']:>8} {nm:24} {et:18} {' '.join(bits)}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events")
    p.add_argument("origin_or_payload", nargs="?", help="origin name (or use --by-payload)")
    p.add_argument("origin_seq", nargs="?", type=int)
    p.add_argument("--by-payload", help="match the first script_emit whose payload contains this substring")
    p.add_argument("--all-emits", action="store_true", help="don't filter by KEY_EMITS — show every script_emit")
    args = p.parse_args()

    names = load_names(args.config)
    name_to_id = {v: k for k, v in names.items()}

    if args.by_payload:
        match = find_origin_seq_for_payload(args.events, args.by_payload, names)
        if not match:
            sys.exit(f"no events matched payload substring {args.by_payload!r}")
        origin_id, seq = match
    else:
        if args.origin_or_payload is None or args.origin_seq is None:
            sys.exit("need ORIGIN and ORIGIN_SEQ (or --by-payload)")
        origin_id = name_to_id.get(args.origin_or_payload)
        if origin_id is None:
            try:
                origin_id = int(args.origin_or_payload)
            except ValueError:
                sys.exit(f"unknown node name: {args.origin_or_payload}")
        seq = args.origin_seq

    trace(args.config, args.events, origin_id, seq, only_key=not args.all_emits)


if __name__ == "__main__":
    main()
