#!/usr/bin/env python3
"""Build the heard-by topology from beacons in events.ndjson.

For every (sender, receiver) pair where receiver heard at least one
beacon from sender, record the best/median/worst SNR observed. Use this
to understand which links are physically usable at routing_sf.

Usage:
  topology.py CONFIG.json EVENTS.ndjson [--from NODE] [--to NODE]
              [--min-snr DB] [--csv]
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict


def load_names(config_path: str) -> dict[int, str]:
    with open(config_path) as f:
        cfg = json.load(f)
    return {i: n["name"] for i, n in enumerate(cfg["nodes"])}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events")
    p.add_argument("--from", dest="src", help="filter to a specific sender")
    p.add_argument("--to", dest="dst", help="filter to a specific receiver")
    p.add_argument("--min-snr", type=float, help="only edges whose median SNR ≥ this dB")
    p.add_argument("--csv", action="store_true", help="machine-readable CSV output")
    args = p.parse_args()

    names = load_names(args.config)
    name_to_id = {v: k for k, v in names.items()}

    src_filter = name_to_id.get(args.src) if args.src else None
    dst_filter = name_to_id.get(args.dst) if args.dst else None

    # script_emit beacon_rx events carry sender id in data.src and SNR in
    # data.snr or — historically — only in the parallel rx_meta event for
    # the same (time_ms, node). The current Lua script doesn't record SNR
    # in beacon_rx data, so we cross-reference via radio rx events.
    # Fall-back: also accept an 'rx' event type with snr.
    edges = defaultdict(list)  # (sender_id, receiver_id) -> [snr,...]
    have_snr_in_beacon = False
    with open(args.events) as f:
        for line in f:
            e = json.loads(line)
            t = e.get("type")
            d = e.get("data", {}) if t == "script_emit" else None
            if t == "script_emit" and e.get("emit_type") == "beacon_rx":
                snr = d.get("snr")
                src = d.get("src")
                rx = e.get("node")
                if snr is None or src is None or rx is None:
                    continue
                have_snr_in_beacon = True
                if src_filter is not None and src != src_filter: continue
                if dst_filter is not None and rx != dst_filter: continue
                edges[(src, rx)].append(float(snr))
            elif t == "rx" and e.get("frame_type") == "beacon":
                snr = e.get("snr")
                src = e.get("from")
                rx = e.get("node")
                if snr is None or src is None or rx is None:
                    continue
                if src_filter is not None and src != src_filter: continue
                if dst_filter is not None and rx != dst_filter: continue
                edges[(src, rx)].append(float(snr))

    if not edges:
        print("# no beacon RX events found with SNR; the events log may not have rx_meta or "
              "beacon_rx may be missing snr — open one such event to confirm field names.")
        return

    if not have_snr_in_beacon:
        print("# (using physical-layer rx events — beacon_rx in script_emit didn't carry snr)")

    rows = []
    for (src, rx), snrs in edges.items():
        rows.append((
            names.get(src, f"#{src}"),
            names.get(rx, f"#{rx}"),
            len(snrs),
            min(snrs), statistics.median(snrs), max(snrs),
        ))
    rows.sort(key=lambda r: (-r[4], r[0], r[1]))

    if args.min_snr is not None:
        rows = [r for r in rows if r[4] >= args.min_snr]

    if args.csv:
        print("from,to,n,snr_min,snr_med,snr_max")
        for sender, rx, n, lo, med, hi in rows:
            print(f"{sender},{rx},{n},{lo:.1f},{med:.1f},{hi:.1f}")
    else:
        print(f"# {len(rows)} edges  (filter src={args.src} dst={args.dst} min-snr={args.min_snr})")
        print(f"  {'from':24} {'to':24} {'n':>4} {'min':>6} {'median':>7} {'max':>6}")
        for sender, rx, n, lo, med, hi in rows[:200]:
            print(f"  {sender:24} {rx:24} {n:>4} {lo:>6.1f} {med:>7.1f} {hi:>6.1f}")
        if len(rows) > 200:
            print(f"  … ({len(rows) - 200} more, use --csv to dump all)")


if __name__ == "__main__":
    main()
