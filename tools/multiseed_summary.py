#!/usr/bin/env python3
"""Run one scenario across seeds and aggregate protocol failure signals.

This is intentionally narrower than tools/analyze.py. It answers:
  - is delivery stable across seeds?
  - where do failures concentrate: RTS setup, DATA decode, ACK, budget?
  - which RF drop classes dominate DATA and Crow/Fremont links?
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

import analyze


RF_DROP_TYPES = {
    "collision",
    "drop_weak",
    "drop_sf_mismatch",
    "drop_preamble_miss",
    "drop_rx_blind",
    "drop_no_link",
    "drop_receiver_inactive",
    "drop_halfduplex",
    "drop_busy",
}


def load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def write_json(path: Path, data: dict) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def set_rx_preamble_miss_prob(cfg: dict, value: float | None) -> None:
    if value is None:
        return
    radio = cfg.setdefault("simulation", {}).setdefault("radio", {})
    hw = radio.setdefault("hardware", {})
    hw["rx_preamble_miss_prob"] = value


def name_maps(cfg: dict) -> tuple[dict[int, str], dict[str, int]]:
    names = {i: n.get("name", str(i)) for i, n in enumerate(cfg.get("nodes", []))}
    ids = {v: k for k, v in names.items()}
    return names, ids


def maybe_name(names: dict[int, str], value) -> str:
    if isinstance(value, int):
        return names.get(value, str(value))
    return str(value)


def summarize_events(cfg: dict, events_path: Path) -> dict:
    names, ids = name_maps(cfg)
    warmup = analyze.find_warmup_end_ms(str(events_path))
    pkt_label = analyze.build_pkt_label_map(str(events_path))
    non_deliv = analyze.section_non_delivered_classifier(str(events_path), cfg, warmup)
    delivery = analyze.section_delivery_breakdown(str(events_path), warmup)
    cold_windows = analyze.section_cold_start(delivery)
    waste = analyze.section_lifetime_waste(delivery)
    rts_setup = analyze.section_rts_setup_attribution(
        str(events_path), cfg, pkt_label, warmup)

    counts = Counter()
    rf_drops = Counter()
    rf_drops_by_label = Counter()
    data_rf_drops = Counter()
    label_airtime = Counter()
    label_count = Counter()
    top_rts_timeout_next = Counter()
    top_ack_timeout_next = Counter()
    data_timeout_sender = Counter()
    crow_fremont = Counter()
    rts_next_by_failure = Counter()
    rts_receiver_state = Counter()

    crow_id = ids.get("Crow_Repeater")
    fremont_id = ids.get("Fremont01_KF7EGZ_Sol")

    for e in analyze.iter_events(str(events_path), warmup):
        et = e.get("type")
        if et == "tx":
            label = e.get("label", "?")
            label_count[label] += 1
            label_airtime[label] += int(e.get("airtime_ms", 0) or 0)
            continue

        if et in RF_DROP_TYPES:
            label = pkt_label.get(e.get("pkt"), "?")
            rf_drops[et] += 1
            rf_drops_by_label[(label, et)] += 1
            if label == "DATA":
                data_rf_drops[et] += 1
            src = e.get("from")
            dst = e.get("to")
            if {src, dst} == {"Crow_Repeater", "Fremont01_KF7EGZ_Sol"}:
                crow_fremont[(label, et)] += 1
            continue

        if et == "rx":
            label = pkt_label.get(e.get("pkt"), "?")
            src = e.get("from")
            dst = e.get("to")
            if {src, dst} == {"Crow_Repeater", "Fremont01_KF7EGZ_Sol"}:
                crow_fremont[(label, "rx")] += 1
            continue

        if et != "script_emit":
            continue

        emit = e.get("emit_type", "")
        d = e.get("data") or {}
        counts[emit] += 1

        if emit == "rts_attempt_timeout":
            reason = d.get("reason", "?")
            nxt = d.get("next")
            if reason == "cts_timeout":
                top_rts_timeout_next[nxt] += 1
            elif reason == "ack_timeout":
                top_ack_timeout_next[nxt] += 1
        elif emit == "data_rx_timeout":
            data_timeout_sender[d.get("from")] += 1

        if crow_id is not None and fremont_id is not None:
            vals = {d.get("from"), d.get("to"), d.get("next"), d.get("dst"), d.get("origin")}
            if crow_id in vals and fremont_id in vals:
                crow_fremont[("script", emit)] += 1

    for cat, counter in rts_setup.get("top_next_by_cat", {}).items():
        if cat == "success_cts_rx":
            continue
        for node_id, count in counter.items():
            rts_next_by_failure[(cat, maybe_name(names, node_id))] += count
    for cat, counter in rts_setup.get("receiver_state_by_cat", {}).items():
        if cat == "success_cts_rx":
            continue
        for state, count in counter.items():
            rts_receiver_state[(cat, state)] += count

    total_airtime = sum(label_airtime.values())
    data_airtime = label_airtime.get("DATA", 0)
    delivery_total = non_deliv["total"]
    delivered = non_deliv["delivered"]

    return {
        "warmup_ms": warmup,
        "total": delivery_total,
        "delivered": delivered,
        "delivery_rate": delivered / delivery_total if delivery_total else 0.0,
        "payload_eff": data_airtime / total_airtime if total_airtime else 0.0,
        "label_airtime": label_airtime,
        "label_count": label_count,
        "counts": counts,
        "rf_drops": rf_drops,
        "rf_drops_by_label": rf_drops_by_label,
        "data_rf_drops": data_rf_drops,
        "state_counts": non_deliv["state_counts"],
        "cold_windows": cold_windows,
        "waste": waste,
        "top_unresolved_dst": Counter({
            name: count for name, count, _ in non_deliv["top_unresolved_dst"]
        }),
        "top_rts_timeout_next": Counter({
            maybe_name(names, k): v for k, v in top_rts_timeout_next.items()
        }),
        "top_ack_timeout_next": Counter({
            maybe_name(names, k): v for k, v in top_ack_timeout_next.items()
        }),
        "data_timeout_sender": Counter({
            maybe_name(names, k): v for k, v in data_timeout_sender.items()
        }),
        "crow_fremont": crow_fremont,
        "rts_setup_categories": rts_setup.get("categories", Counter()),
        "rts_rf_loss": rts_setup.get("rf_rts", Counter()),
        "rts_response_rf_loss": rts_setup.get("rf_resp", Counter()),
        "rts_script_drops": rts_setup.get("script_drops", Counter()),
        "rts_next_by_failure": rts_next_by_failure,
        "rts_receiver_state": rts_receiver_state,
    }


def run_one(lus: str, cfg: dict, cfg_path: Path, events_path: Path) -> None:
    write_json(cfg_path, cfg)
    res = subprocess.run([lus, str(cfg_path), str(events_path)],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout, file=sys.stderr)
        print(res.stderr, file=sys.stderr)
        raise SystemExit(f"lus exited {res.returncode} for {cfg_path}")


def print_counter(title: str, c: Counter, limit: int = 8) -> None:
    print(f"\n{title}:")
    if not c:
        print("  (none)")
        return
    for k, v in c.most_common(limit):
        if isinstance(k, tuple):
            k = "/".join(str(x) for x in k)
        print(f"  {str(k):<38} {v:>5}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("--runs", type=int, default=5)
    p.add_argument("--seed-start", type=int)
    p.add_argument("--lus", default="build/orchestrator/lus")
    p.add_argument("--out-dir", default="/tmp/lus_multiseed")
    p.add_argument("--rx-preamble-miss-prob", type=float,
                   help="Override simulation.radio.hardware.rx_preamble_miss_prob")
    p.add_argument("--keep-events", action="store_true")
    args = p.parse_args()

    base_cfg = load_json(args.config)
    base_seed = args.seed_start
    if base_seed is None:
        base_seed = int(base_cfg.get("simulation", {}).get("seed", 1))

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(args.config).stem

    summaries = []
    agg = defaultdict(Counter)
    total_msgs = 0
    total_delivered = 0
    total_airtime = Counter()
    total_label_count = Counter()
    cold_windows_total: list[Counter] = []
    waste_delivered_time_s = 0.0
    waste_exhausted_time_s = 0.0

    print(f"# config: {args.config}")
    print(f"# runs:   {args.runs}")
    print(f"# seeds:  {base_seed}..{base_seed + args.runs - 1}")
    if args.rx_preamble_miss_prob is not None:
        print(f"# rx_preamble_miss_prob override: {args.rx_preamble_miss_prob}")

    for i in range(args.runs):
        seed = base_seed + i
        cfg = json.loads(json.dumps(base_cfg))
        cfg.setdefault("simulation", {})["seed"] = seed
        set_rx_preamble_miss_prob(cfg, args.rx_preamble_miss_prob)
        cfg_path = out_dir / f"{stem}_seed{seed}.json"
        events_path = out_dir / f"{stem}_seed{seed}.ndjson"
        print(f"# running seed {seed} -> {events_path}", file=sys.stderr)
        run_one(args.lus, cfg, cfg_path, events_path)
        s = summarize_events(cfg, events_path)
        summaries.append((seed, s))
        total_msgs += s["total"]
        total_delivered += s["delivered"]
        total_airtime.update(s["label_airtime"])
        total_label_count.update(s["label_count"])
        for idx, row in enumerate(s.get("cold_windows", [])):
            while len(cold_windows_total) <= idx:
                cold_windows_total.append(Counter())
            cold_windows_total[idx]["start_ms"] += int(row.get("start_ms", 0) or 0)
            cold_windows_total[idx]["end_ms"] += int(row.get("end_ms", 0) or 0)
            cold_windows_total[idx]["sent"] += int(row.get("sent", 0) or 0)
            cold_windows_total[idx]["delivered"] += int(row.get("delivered", 0) or 0)
        waste = s.get("waste", {})
        waste_delivered_time_s += float(waste.get("total_deliv_ms", 0.0) or 0.0) / 1000.0
        waste_exhausted_time_s += float(waste.get("total_exh_ms", 0.0) or 0.0) / 1000.0
        for key in (
            "counts",
            "rf_drops",
            "rf_drops_by_label",
            "data_rf_drops",
            "state_counts",
            "top_unresolved_dst",
            "top_rts_timeout_next",
            "top_ack_timeout_next",
            "data_timeout_sender",
            "crow_fremont",
            "rts_setup_categories",
            "rts_rf_loss",
            "rts_response_rf_loss",
            "rts_script_drops",
            "rts_next_by_failure",
            "rts_receiver_state",
        ):
            agg[key].update(s[key])
        print(
            f"seed {seed}: delivered {s['delivered']}/{s['total']} "
            f"= {100*s['delivery_rate']:.1f}%, payload_eff={100*s['payload_eff']:.1f}%"
        )
        if not args.keep_events:
            try:
                cfg_path.unlink()
            except FileNotFoundError:
                pass

    total_tx_air = sum(total_airtime.values())
    data_air = total_airtime.get("DATA", 0)
    print("\n=== aggregate ===")
    print(f"messages:      {total_msgs}")
    print(f"delivered:     {total_delivered}/{total_msgs} = "
          f"{100*total_delivered/total_msgs if total_msgs else 0:.1f}%")
    print(f"payload_eff:   {100*data_air/total_tx_air if total_tx_air else 0:.1f}%")
    print(f"total_airtime: {total_tx_air/1000:.1f}s")
    if cold_windows_total:
        print("\ndelivery by enqueue-time window:")
        print(f"  {'window (s)':<18} {'sent':>6} {'delivered':>10} {'rate':>7}")
        for row in cold_windows_total:
            sent = row["sent"]
            delivered = row["delivered"]
            n_runs = max(1, args.runs)
            start_s = (row["start_ms"] / n_runs) / 1000.0
            end_s = (row["end_ms"] / n_runs) / 1000.0
            rate = 100.0 * delivered / sent if sent else 0.0
            print(f"  {start_s:5.0f}-{end_s:<8.0f} {sent:>6} {delivered:>10} {rate:>6.1f}%")
    if waste_delivered_time_s or waste_exhausted_time_s:
        ratio = (waste_exhausted_time_s / waste_delivered_time_s
                 if waste_delivered_time_s else 0.0)
        print("\nlifetime channel-time waste:")
        print(f"  delivered_time_s: {waste_delivered_time_s:.0f}")
        print(f"  exhausted_time_s: {waste_exhausted_time_s:.0f}")
        print(f"  exhausted/delivered ratio: {ratio:.1f}x")

    non_delivered_classes = Counter(agg["state_counts"])
    non_delivered_classes.pop("delivered", None)
    print_counter("final non-delivered classification", non_delivered_classes)
    print_counter("RF drops", agg["rf_drops"])
    print_counter("DATA RF drops", agg["data_rf_drops"])
    print_counter("RF drops by label", agg["rf_drops_by_label"], limit=12)
    print_counter("top unresolved destinations", agg["top_unresolved_dst"])
    print_counter("top CTS-timeout next-hops", agg["top_rts_timeout_next"])
    print_counter("top ACK-timeout next-hops", agg["top_ack_timeout_next"])
    print_counter("top DATA-wait timeout senders", agg["data_timeout_sender"])
    print_counter("directed RTS setup outcomes", agg["rts_setup_categories"], limit=12)
    print_counter("RTS RF loss at intended receiver", agg["rts_rf_loss"])
    print_counter("CTS/NACK RF loss at sender", agg["rts_response_rf_loss"])
    print_counter("RTS decoded then script dropped", agg["rts_script_drops"])
    print_counter("RTS failure next-hops", agg["rts_next_by_failure"], limit=12)
    print_counter("receiver state for failed RTS", agg["rts_receiver_state"], limit=12)
    print_counter("Crow/Fremont directed outcomes", agg["crow_fremont"], limit=16)


if __name__ == "__main__":
    main()
