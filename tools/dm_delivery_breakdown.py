#!/usr/bin/env python3
"""Per-DM delivery + path breakdown for a sim run.

Walks the events.ndjson and reconstructs the lifecycle of every
unicast DM (`send <dst> ...`) injected via the scenario's `commands`
block, classifying each by:

  arrived       — destination decoded the DATA frame at least once
  hop1_ack      — originator received an ACK from its first-hop
                  forwarder. NB: this is hop-by-hop ACK, NOT end-to-
                  end. The originator knows the next hop accepted
                  the frame; it does NOT know whether subsequent
                  hops succeeded. Only `arrived` (destination decoded
                  DATA) is the true delivery signal.
  giveup        — originator gave up before delivery (send_giveup)
  in_flight     — no terminal event observed by run end

Also reports the per-message path: every node that carried the
message (rts_tx / data_tx) plus the mean actual hop count, so the
firmware's route choice can be compared against the topology.

Messages are keyed by (origin_node_id, dst_node_id, ctr). In events,
`node` is the orchestrator slot index (0-based); `data.origin` and
`data.dst` are firmware node_ids (from config). The tool maps between
them via the scenario's node order.

Usage:
  dm_delivery_breakdown.py CONFIG.json [EVENTS.ndjson] [opts]
  dm_delivery_breakdown.py CONFIG.json --run

If EVENTS is omitted, the tool looks for the analyze.py convention
file /tmp/<config-stem>_analyze.ndjson — which means you can run
`analyze.py --run` once and then iterate on `dm_delivery_breakdown.py`
without re-simulating. Pass --run to re-execute lus before analysis.

Options:
  --run                  Run lus on the config first (writes events
                         to /tmp/<stem>_analyze.ndjson if EVENTS not
                         given).
  --lus PATH             lus binary path (default build/orchestrator/lus).
  --json                 Emit JSON instead of the table.
  --detail               Include per-message timeline (text mode) or
                         per-message event list (JSON mode).
  --pair PAIR[,PAIR...]  Filter to specific pairs. Form: src:dst,
                         e.g. "heidi:carol,dave:peter".
  --all                  Include pairs not in scenario commands.

Examples:
  # Run lus + show per-pair summary
  python3 tools/dm_delivery_breakdown.py CONFIG --run

  # Reuse the events file analyze.py just produced
  python3 tools/dm_delivery_breakdown.py CONFIG

  # Single-pair forensic timeline
  python3 tools/dm_delivery_breakdown.py CONFIG \\
      --detail --pair heidi:carol

  # JSON with full per-message event lists (for tooling / diff)
  python3 tools/dm_delivery_breakdown.py CONFIG --json --detail
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict


def maybe_run(cfg_path, events_path, lus_path):
    print(f"# running {lus_path} {cfg_path} -> {events_path}", file=sys.stderr)
    res = subprocess.run([lus_path, cfg_path, events_path],
                         capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stdout)
        sys.stderr.write(res.stderr)
        raise SystemExit(f"lus exited {res.returncode}")


# Emit types we include in the per-message timeline. Anything outside
# this set is filtered out as noise. Keep it focused on path tracking.
TIMELINE_EMITS = {
    "tx_enqueue",
    "tx_dequeue",
    "route_decision",
    "rts_attempt_detail",
    "rts_tx",
    "rts_retry",
    "rts_fwd",
    "tx_lbt_defer",
    "send_deferred",
    "send_defer_requery",
    "cts_rx",
    "data_tx",
    "data_rx",
    "ack_rx",
    "ack_snr_feedback",
    "send_drained",
    "send_giveup",
    "delivered",
}

# Per-event "interesting" fields shown in the text timeline (keys that
# exist in `data.*`). The selection avoids dumping payload bytes in
# every line — payload appears once in the header.
TIMELINE_FIELDS = (
    "next", "from", "to", "attempt_seq", "reason", "sf", "data_sf",
    "next_attempt_ms", "settle_ms", "waited_ms", "retry_idx", "depth",
)


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    nodes = cfg["nodes"]
    id_to_name = {n["node_id"]: n["name"] for n in nodes}
    name_to_id = {n["name"]: n["node_id"] for n in nodes}
    slot_to_id = {i: n["node_id"] for i, n in enumerate(nodes)}
    return cfg, id_to_name, name_to_id, slot_to_id


def configured_pairs(cfg, name_to_id):
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


def parse_pair_filter(arg, name_to_id):
    if arg is None:
        return None
    pairs = set()
    for chunk in arg.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if ":" not in chunk:
            sys.exit(f"--pair entry must be 'src:dst', got {chunk!r}")
        s, d = chunk.split(":", 1)
        if s not in name_to_id or d not in name_to_id:
            sys.exit(f"--pair {chunk!r}: unknown node name "
                     f"(known: {sorted(name_to_id)})")
        pairs.add((name_to_id[s], name_to_id[d]))
    return pairs


def msg_key(data, default_origin, origin_ctr_index):
    """Build (origin, dst, ctr) for a script_emit data dict.

    Some events (ack_rx, cts_rx, ack_snr_feedback) omit dst because
    the originator/forwarder only knows the immediate `from` peer at
    that point. We resolve dst from a pre-populated (origin, ctr) ->
    dst index built from earlier events on the same message.
    """
    origin = data.get("origin")
    if origin is None:
        origin = data.get("src")
    if origin is None:
        origin = default_origin
    dst = data.get("dst")
    ctr = data.get("ctr")
    if ctr is None:
        ctr = data.get("ctr_lo")
    if origin is None or ctr is None:
        return None
    if dst is None:
        dst = origin_ctr_index.get((origin, ctr))
        if dst is None:
            return None
    return (origin, dst, ctr)


def walk_events(events_path, slot_to_id):
    """Yield (time_ms, firmware_id, emit_type, data) for every script_emit."""
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
            yield (e.get("time_ms", 0), fid,
                   e.get("emit_type"), e.get("data", {}))


def analyse(events_path, slot_to_id):
    msgs = {}
    # First pass: build (origin, ctr) -> dst from events that carry dst.
    # Second pass below applies the index to events that lack dst.
    origin_ctr_to_dst = {}
    for _, _, _, d in walk_events(events_path, slot_to_id):
        o = d.get("origin") or d.get("src")
        c = d.get("ctr")
        if c is None:
            c = d.get("ctr_lo")
        dst = d.get("dst")
        if o is not None and c is not None and dst is not None:
            origin_ctr_to_dst.setdefault((o, c), dst)

    def rec(k):
        if k not in msgs:
            msgs[k] = {
                "origin":      k[0],
                "dst":         k[1],
                "ctr":         k[2],
                "enqueued_ms": None,
                "arrived_ms":  None,
                "ack_ms":      None,
                "giveup_ms":   None,
                "giveup_reason": None,
                "payload":     None,
                "carriers":    set(),
                "events":      [],
            }
        return msgs[k]

    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        k = msg_key(d, default_origin=fid,
                    origin_ctr_index=origin_ctr_to_dst)
        if k is None:
            continue
        origin, dst, ctr = k

        # Filter: only track DMs (no broadcasts, no channel msgs).
        # Channel msg events have separate emit types so this branch
        # is more a defensive filter than an active one.
        if d.get("flags") is not None and (d["flags"] & 0x80):
            continue

        r = rec(k)
        if r["payload"] is None and "payload" in d:
            r["payload"] = d["payload"]

        # Outcome timestamps. Only the *first* of each kind is kept.
        if et == "tx_enqueue" and fid == origin and r["enqueued_ms"] is None:
            r["enqueued_ms"] = t_ms
        elif et == "data_rx" and fid == dst and r["arrived_ms"] is None:
            r["arrived_ms"] = t_ms
        elif et == "ack_rx" and fid == origin and r["ack_ms"] is None:
            r["ack_ms"] = t_ms
        elif et == "send_giveup" and fid == origin:
            r["giveup_ms"] = t_ms
            r["giveup_reason"] = d.get("reason") or d.get("terminal")

        # Carrier set: who actually transmitted for this message?
        if et in ("rts_tx", "data_tx", "rts_fwd", "rts_retry"):
            r["carriers"].add(fid)

        # Timeline event capture.
        if et in TIMELINE_EMITS:
            fields = {kk: d[kk] for kk in TIMELINE_FIELDS if kk in d}
            r["events"].append({"t_ms": t_ms, "node": fid,
                                "type": et, "fields": fields})

    # Stable ordering for timeline rendering.
    for r in msgs.values():
        r["events"].sort(key=lambda x: (x["t_ms"], x["node"]))
    return msgs


def outcome(rec):
    """Per-message terminal outcome.

    NB: `ack_ms` is the FIRST-HOP ACK from the originator's next-hop
    forwarder. It does not mean end-to-end delivery — only `arrived`
    (destination data_rx) means that. The combinations:

      arrived_and_hop1_acked  msg reached dst AND origin got hop-1 ack
      arrived_no_hop1_ack     msg reached dst but origin didn't see ack
      hop1_acked_no_arrival   origin got hop-1 ack but msg didn't arrive
                              (cascade died downstream)
      giveup                  origin gave up before delivery
      in_flight               no terminal event by run end
    """
    arr = rec["arrived_ms"] is not None
    ack = rec["ack_ms"] is not None
    if arr and ack:
        return "arrived_and_hop1_acked"
    if arr:
        return "arrived_no_hop1_ack"
    if ack:
        return "hop1_acked_no_arrival"
    if rec["giveup_ms"] is not None:
        return "giveup"
    return "in_flight"


def summarise(msgs, pair_filter, id_to_name):
    by_pair = defaultdict(list)
    for k, r in msgs.items():
        if pair_filter is not None and (r["origin"], r["dst"]) not in pair_filter:
            continue
        by_pair[(r["origin"], r["dst"])].append(r)
    rows = []
    for (origin, dst), recs in sorted(by_pair.items()):
        n = len(recs)
        arrived = sum(1 for r in recs if r["arrived_ms"] is not None)
        acked = sum(1 for r in recs if r["ack_ms"] is not None)
        giveup = sum(1 for r in recs if outcome(r) == "giveup")
        in_flight = sum(1 for r in recs if outcome(r) == "in_flight")
        hops = [len(r["carriers"]) for r in recs if r["arrived_ms"] is not None]
        mean_hops = (sum(hops) / len(hops)) if hops else None
        giveup_reasons = [r["giveup_reason"] for r in recs
                          if r["giveup_reason"]]
        rows.append({
            "origin":     id_to_name.get(origin, f"#{origin}"),
            "dst":        id_to_name.get(dst, f"#{dst}"),
            "sent":       n,
            "arrived":    arrived,
            "acked":      acked,
            "giveup":     giveup,
            "in_flight":  in_flight,
            "mean_hops":  mean_hops,
            "giveup_reasons": giveup_reasons,
        })
    return rows


def render_table(rows):
    if not rows:
        print("(no matching DM messages found)")
        return
    # "h1_ack" = originator got the hop-1 ACK; NOT end-to-end.
    # See outcome() docstring for details.
    header = ["pair", "sent", "arr", "arr%", "h1ack", "h1ack%",
              "giveup", "in_flight", "mean_hops"]
    fmt = "{:<22} {:>4} {:>4} {:>5} {:>5} {:>6} {:>6} {:>9} {:>9}"
    print(fmt.format(*header))
    print("-" * 80)
    tot = {"sent": 0, "arrived": 0, "acked": 0,
           "giveup": 0, "in_flight": 0}
    for r in rows:
        pair = f"{r['origin']:>10} -> {r['dst']:<8}"
        arr_pct = f"{100*r['arrived']/r['sent']:.0f}%" if r["sent"] else "-"
        ack_pct = f"{100*r['acked']/r['sent']:.0f}%" if r["sent"] else "-"
        mh = f"{r['mean_hops']:.1f}" if r["mean_hops"] is not None else "-"
        print(fmt.format(pair, r["sent"], r["arrived"], arr_pct,
                         r["acked"], ack_pct, r["giveup"],
                         r["in_flight"], mh))
        for k in tot:
            tot[k] += r[k]
    print("-" * 80)
    arr_pct = f"{100*tot['arrived']/tot['sent']:.0f}%" if tot["sent"] else "-"
    ack_pct = f"{100*tot['acked']/tot['sent']:.0f}%" if tot["sent"] else "-"
    print(fmt.format("TOTAL", tot["sent"], tot["arrived"], arr_pct,
                     tot["acked"], ack_pct, tot["giveup"],
                     tot["in_flight"], "-"))
    reasons = defaultdict(int)
    for r in rows:
        for x in r["giveup_reasons"]:
            reasons[x] += 1
    if reasons:
        print()
        print("giveup reasons:")
        for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"  {k:<40} {v}")


def render_detail_text(msgs, pair_filter, id_to_name):
    keys = [k for k, r in msgs.items()
            if pair_filter is None or (r["origin"], r["dst"]) in pair_filter]
    keys.sort(key=lambda k: (k[0], k[1], k[2]))
    for k in keys:
        r = msgs[k]
        origin_n = id_to_name.get(r["origin"], f"#{r['origin']}")
        dst_n = id_to_name.get(r["dst"], f"#{r['dst']}")
        out = outcome(r)
        hop_count = len(r["carriers"])
        head_parts = [f"=== {origin_n} -> {dst_n} ctr={r['ctr']} ==="]
        if r["payload"] is not None:
            head_parts.append(f'payload="{r["payload"]}"')
        head_parts.append(f"outcome={out}")
        head_parts.append(f"carriers={hop_count}")
        if r["enqueued_ms"] is not None:
            head_parts.append(f"enq={r['enqueued_ms']}ms")
        if r["arrived_ms"] is not None:
            head_parts.append(f"arr={r['arrived_ms']}ms")
        if r["ack_ms"] is not None:
            head_parts.append(f"ack={r['ack_ms']}ms")
        if r["giveup_ms"] is not None:
            head_parts.append(f"giveup={r['giveup_ms']}ms"
                              f"({r['giveup_reason']})")
        print(" ".join(head_parts))
        for ev in r["events"]:
            node_n = id_to_name.get(ev["node"], f"#{ev['node']}")
            field_str = " ".join(f"{kk}={vv}" for kk, vv in ev["fields"].items())
            print(f"  {ev['t_ms']:>8} ms  {node_n:<8} "
                  f"{ev['type']:<22} {field_str}")
        print()


def render_json(rows, msgs, pair_filter, id_to_name, detail):
    out = {"summary": rows}
    if detail:
        keys = [k for k, r in msgs.items()
                if pair_filter is None
                or (r["origin"], r["dst"]) in pair_filter]
        keys.sort(key=lambda k: (k[0], k[1], k[2]))
        messages = []
        for k in keys:
            r = msgs[k]
            messages.append({
                "origin":      id_to_name.get(r["origin"], f"#{r['origin']}"),
                "dst":         id_to_name.get(r["dst"], f"#{r['dst']}"),
                "ctr":         r["ctr"],
                "payload":     r["payload"],
                "outcome":     outcome(r),
                "enqueued_ms": r["enqueued_ms"],
                "arrived_ms":  r["arrived_ms"],
                "ack_ms":      r["ack_ms"],
                "giveup_ms":   r["giveup_ms"],
                "giveup_reason": r["giveup_reason"],
                "carriers":    sorted(id_to_name.get(c, f"#{c}")
                                      for c in r["carriers"]),
                "hops":        len(r["carriers"]),
                "events":      [
                    {**ev,
                     "node": id_to_name.get(ev["node"], f"#{ev['node']}")}
                    for ev in r["events"]
                ],
            })
        out["messages"] = messages
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events", nargs="?",
                   help="events.ndjson path (default: "
                        "/tmp/<stem>_analyze.ndjson, the analyze.py "
                        "convention)")
    p.add_argument("--run", action="store_true",
                   help="run lus on the config before analysing")
    p.add_argument("--lus", default="build/orchestrator/lus",
                   help="lus binary path")
    p.add_argument("--json", action="store_true",
                   help="emit JSON instead of the table")
    p.add_argument("--detail", action="store_true",
                   help="include per-message timeline (text) or "
                        "per-message event list (json)")
    p.add_argument("--pair", default=None,
                   help="filter to pairs, e.g. 'heidi:carol,dave:peter'")
    p.add_argument("--all", action="store_true",
                   help="include pairs not present in scenario commands")
    args = p.parse_args()

    if args.events is None:
        stem = os.path.splitext(os.path.basename(args.config))[0]
        args.events = f"/tmp/{stem}_analyze.ndjson"
    if args.run:
        maybe_run(args.config, args.events, args.lus)
    if not os.path.exists(args.events):
        sys.exit(f"events file does not exist: {args.events}\n"
                 f"  (pass --run to generate it, or provide an "
                 f"explicit EVENTS path)")

    cfg, id_to_name, name_to_id, slot_to_id = load_config(args.config)
    msgs = analyse(args.events, slot_to_id)

    # Pair filter: explicit --pair wins; else configured commands;
    # else (with --all) no filter at all.
    explicit = parse_pair_filter(args.pair, name_to_id)
    if explicit is not None:
        pair_filter = explicit
    elif args.all:
        pair_filter = None
    else:
        pair_filter = configured_pairs(cfg, name_to_id)

    rows = summarise(msgs, pair_filter, id_to_name)

    if args.json:
        render_json(rows, msgs, pair_filter, id_to_name, args.detail)
    else:
        render_table(rows)
        if args.detail:
            print()
            render_detail_text(msgs, pair_filter, id_to_name)


if __name__ == "__main__":
    main()
