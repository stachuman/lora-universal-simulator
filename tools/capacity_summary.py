#!/usr/bin/env python3
"""Network capacity summary for a sim run.

Reports per-run aggregates that matter when comparing two runs of the
same scenario at different radio params (e.g. BW=250 vs 62.5):

  Deliveries     — count + ratio of `delivered` emits vs `send` commands
  Hops           — mean / median / max hop count per delivered message
  Latency        — origin→delivery wallclock (sim ms)
  Airtime usage  — total airtime split by label (BCN / RTS / CTS / DATA / ACK / NACK)
  Beacon share   — fraction of all airtime spent on BCN frames
  Failure modes  — rts_giveup, data_ack_giveup, dup_drop, drop_*, tx_deferred(*reasons*)

Usage:
  capacity_summary.py CONFIG.json EVENTS.ndjson
  capacity_summary.py --compare CONFIG_A.json EVENTS_A.ndjson CONFIG_B.json EVENTS_B.ndjson
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict


def load_names(config_path: str) -> tuple[dict[int, str], list]:
    with open(config_path) as f:
        cfg = json.load(f)
    names = {i: n["name"] for i, n in enumerate(cfg["nodes"])}
    return names, cfg.get("commands", [])


def parse_send_cmd(cmd: str) -> tuple[str, str] | None:
    m = re.match(r"^send\s+(\S+)\s+(.+)$", cmd or "")
    if not m:
        return None
    return m.group(1), m.group(2)


def summarize(config_path: str, events_path: str) -> dict:
    names, commands = load_names(config_path)
    n_nodes = len(names)

    # Walk events, gather aggregates.
    airtime_by_label = Counter()
    tx_count_by_label = Counter()
    tx_count = 0
    total_airtime = 0
    deferred_by_reason = Counter()
    drop_by_kind = Counter()
    delivered = []  # list of {origin, origin_seq, dst, t_delivered}
    sent = []       # list of {origin, origin_seq, dst, t_sent}
    rts_giveup = 0
    data_ack_giveup = 0
    dup_drop = 0
    blind_observed = 0
    duty_cycle_blocked = 0

    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            t = e.get("type", "")
            if t == "tx":
                lbl = e.get("label", "") or "(none)"
                a = e.get("airtime_ms", 0) or 0
                airtime_by_label[lbl] += a
                tx_count_by_label[lbl] += 1
                tx_count += 1
                total_airtime += a
            elif t == "tx_deferred":
                deferred_by_reason[e.get("reason", "?")] += 1
            elif t.startswith("drop_"):
                drop_by_kind[t] += 1
            elif t == "script_emit":
                em = e.get("emit_type", "")
                d = e.get("data", {}) or {}
                if em == "delivered":
                    delivered.append({
                        "node": e["node"],
                        "origin": d.get("origin"),
                        "origin_seq": d.get("origin_seq"),
                        "t": e["time_ms"],
                    })
                elif em == "tx_enqueue":
                    sent.append({
                        "node": e["node"],
                        "origin": d.get("origin"),
                        "origin_seq": d.get("origin_seq"),
                        "dst": d.get("dst"),
                        "t": e["time_ms"],
                    })
                elif em == "rts_giveup":
                    rts_giveup += 1
                elif em == "data_ack_giveup":
                    data_ack_giveup += 1
                elif em == "dup_drop":
                    dup_drop += 1
                elif em == "blind_observed":
                    blind_observed += 1
                elif em == "duty_cycle_blocked":
                    duty_cycle_blocked += 1

    # Match deliveries to sends to compute hops + latency.
    sent_idx = {(s["origin"], s["origin_seq"]): s for s in sent}
    latencies = []
    for d in delivered:
        s = sent_idx.get((d["origin"], d["origin_seq"]))
        if s is not None:
            latencies.append(d["t"] - s["t"])

    # Hops per delivered: count data_rx events with the same (origin, origin_seq).
    hops_by_msg = Counter()
    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") != "script_emit":
                continue
            if e.get("emit_type") != "data_rx":
                continue
            d = e.get("data", {}) or {}
            key = (d.get("origin"), d.get("origin_seq"))
            hops_by_msg[key] += 1

    delivered_keys = {(d["origin"], d["origin_seq"]) for d in delivered}
    delivered_hops = [hops_by_msg[k] for k in delivered_keys if hops_by_msg[k] > 0]

    n_send_cmds = sum(1 for c in commands
                      if (c.get("command") or "").startswith("send "))
    return {
        "n_nodes": n_nodes,
        "n_send_cmds": n_send_cmds,
        "n_sent_emits": len(sent),
        "n_delivered": len(delivered),
        "n_unique_delivered": len(delivered_keys),
        "tx_count": tx_count,
        "total_airtime_ms": total_airtime,
        "airtime_by_label": dict(airtime_by_label),
        "tx_count_by_label": dict(tx_count_by_label),
        "deferred_by_reason": dict(deferred_by_reason),
        "drop_by_kind": dict(drop_by_kind),
        "rts_giveup": rts_giveup,
        "data_ack_giveup": data_ack_giveup,
        "dup_drop": dup_drop,
        "blind_observed": blind_observed,
        "duty_cycle_blocked": duty_cycle_blocked,
        "latency_ms_mean": (statistics.mean(latencies) if latencies else 0),
        "latency_ms_p50":  (statistics.median(latencies) if latencies else 0),
        "latency_ms_max":  (max(latencies) if latencies else 0),
        "hops_mean":       (statistics.mean(delivered_hops) if delivered_hops else 0),
        "hops_p50":        (statistics.median(delivered_hops) if delivered_hops else 0),
        "hops_max":        (max(delivered_hops) if delivered_hops else 0),
    }


def fmt_one(s: dict, label: str) -> str:
    out = []
    out.append(f"=== {label} ===")
    out.append(f"  nodes={s['n_nodes']}  sends={s['n_send_cmds']}  "
               f"delivered={s['n_unique_delivered']} ({100*s['n_unique_delivered']/max(1,s['n_send_cmds']):.1f}%)")
    out.append(f"  hops:    mean={s['hops_mean']:.2f}  p50={s['hops_p50']}  max={s['hops_max']}")
    out.append(f"  latency: mean={s['latency_ms_mean']/1000:.2f}s  p50={s['latency_ms_p50']/1000:.2f}s  max={s['latency_ms_max']/1000:.2f}s")
    out.append(f"  total tx count={s['tx_count']}  total airtime={s['total_airtime_ms']/1000:.1f}s")
    if s["airtime_by_label"]:
        bcn = s["airtime_by_label"].get("BCN", 0)
        bcn_pct = 100 * bcn / max(1, s["total_airtime_ms"])
        rts = sum(s["airtime_by_label"].get(k, 0) for k in ("RTS", "RTS-fwd", "RTS-rty"))
        cts = sum(s["airtime_by_label"].get(k, 0) for k in ("CTS", "CTS-dup"))
        data = s["airtime_by_label"].get("DATA", 0)
        ack = sum(s["airtime_by_label"].get(k, 0) for k in ("ACK", "K-dup"))
        nack = s["airtime_by_label"].get("NACK", 0)
        out.append(f"  airtime split: BCN={bcn/1000:.1f}s ({bcn_pct:.0f}%)  "
                   f"RTS={rts/1000:.1f}s  CTS={cts/1000:.1f}s  DATA={data/1000:.1f}s  "
                   f"ACK={ack/1000:.1f}s  NACK={nack/1000:.1f}s")
    if s["deferred_by_reason"]:
        out.append("  defers: " + ", ".join(f"{k}={v}" for k, v in sorted(s['deferred_by_reason'].items())))
    if s["drop_by_kind"]:
        out.append("  drops:  " + ", ".join(f"{k}={v}" for k, v in sorted(s['drop_by_kind'].items())))
    fails = []
    if s["rts_giveup"]:        fails.append(f"rts_giveup={s['rts_giveup']}")
    if s["data_ack_giveup"]:   fails.append(f"data_ack_giveup={s['data_ack_giveup']}")
    if s["dup_drop"]:          fails.append(f"dup_drop={s['dup_drop']}")
    if s["duty_cycle_blocked"]: fails.append(f"duty_cycle_blocked={s['duty_cycle_blocked']}")
    if fails:
        out.append("  failures: " + ", ".join(fails))
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config", nargs="?")
    p.add_argument("events", nargs="?")
    p.add_argument("--compare", nargs=4,
                   metavar=("CFG_A", "EV_A", "CFG_B", "EV_B"),
                   help="compare two runs side-by-side")
    args = p.parse_args()

    if args.compare:
        a = summarize(args.compare[0], args.compare[1])
        b = summarize(args.compare[2], args.compare[3])
        print(fmt_one(a, args.compare[1]))
        print()
        print(fmt_one(b, args.compare[3]))
        return

    if not (args.config and args.events):
        p.error("provide CONFIG and EVENTS, or --compare")
    s = summarize(args.config, args.events)
    print(fmt_one(s, args.events))


if __name__ == "__main__":
    main()
