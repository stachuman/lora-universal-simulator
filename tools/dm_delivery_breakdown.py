#!/usr/bin/env python3
"""Per-DM + per-channel-post delivery breakdown for a sim run.

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
  --mode {dm,channel,all}  Which view to emit. Default `all`: prints
                           both the per-DM table and the per-post
                           channel table. `dm` and `channel` filter
                           to one mode (handy when piping to JSON).
  --run                  Run lus on the config first (writes events
                         to /tmp/<stem>_analyze.ndjson if EVENTS not
                         given).
  --lus PATH             lus binary path (default build/orchestrator/lus).
  --json                 Emit JSON instead of the table.
  --detail               Include per-message timeline (text mode) or
                         per-message event list (JSON mode).
  --pair PAIR[,PAIR...]  Filter DM rows to specific pairs. Form
                         src:dst, e.g. "heidi:carol,dave:peter".
  --post SUBSTR          Filter channel rows to posts whose payload
                         contains SUBSTR (case-insensitive). e.g.
                         --post news-3 → only the L1-news-3 post.
  --all                  Include pairs not in scenario commands.

Channel mode reports per channel post:
  reach        — count of distinct same-layer non-self nodes that
                 emitted `channel_msg_received` for the post's id
  expected     — non-gateway nodes in the originator's layer minus 1
  sources      — breakdown of how each recipient acquired the msg
                 (pull_target / forwarder / overheard / promiscuous)
  leaks        — count of recipients on a DIFFERENT layer than the
                 originator (Principle 11 violations; should be 0)

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


# Fields in event data whose value is a firmware node id; we render
# them as "name(id)" wherever they appear in detail-mode output.
NODE_ID_FIELDS = ("next", "from", "to", "via_gateway")


def fmt_node(fid, id_to_name):
    """Consistent name(id) rendering. Falls back to #id if no mapping."""
    if fid is None:
        return "?"
    name = id_to_name.get(fid)
    if name is None:
        return f"#{fid}"
    return f"{name}({fid})"


def _hash_key_to_int(k):
    """Config hashes are usually "0xHEX" strings; accept ints too."""
    if isinstance(k, int):
        return k
    if isinstance(k, str):
        k = k.strip()
        if k.startswith("0x") or k.startswith("0X"):
            return int(k, 16)
        return int(k)
    return None


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    nodes = cfg["nodes"]
    id_to_name = {n["node_id"]: n["name"] for n in nodes}
    name_to_id = {n["name"]: n["node_id"] for n in nodes}
    slot_to_id = {i: n["node_id"] for i, n in enumerate(nodes)}
    # Cross-layer destinations are addressed by key_hash32 decimal in the
    # `send_layer` command; build (target_layer_id, hash) -> name so we
    # can resolve them. layer_id lives at config.layer_id (regular nodes)
    # or, for gateways visiting another layer, in gateway_layers[].
    hash_layer_to_name = {}
    for n in nodes:
        h = _hash_key_to_int(n.get("key_hash32"))
        if h is None:
            continue
        cfg_block = n.get("config", {}) or {}
        layer = cfg_block.get("layer_id")
        if layer is not None:
            hash_layer_to_name[(layer, h)] = n["name"]
    return cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name


SEND_RE = re.compile(r"^send(?:_priority|_e2e|_e2e_priority)?\s+(\S+)\s+",
                     re.IGNORECASE)
SEND_LAYER_RE = re.compile(r"^send_layer\s+(\S+)\s+(\S+)\s+", re.IGNORECASE)
SEND_CHANNEL_RE = re.compile(r"^send_channel\s+(\S+)\s+(.+)$", re.IGNORECASE)


def configured_channel_posts(cfg, name_to_id):
    """Return list of dicts describing each `send_channel` command:
    {sender_id, sender_layer, channel_id, payload, sent_at_ms}."""
    nodes_by_id = {n["node_id"]: n for n in cfg["nodes"]}
    posts = []
    for c in cfg.get("commands", []):
        cmd = c.get("command", "")
        m = SEND_CHANNEL_RE.match(cmd)
        if not m:
            continue
        sender = c.get("node")
        sender_id = name_to_id.get(sender)
        if sender_id is None:
            continue
        try:
            channel_id = int(m.group(1))
        except ValueError:
            continue
        payload = m.group(2).strip()
        sender_node = nodes_by_id.get(sender_id, {})
        sender_layer = (sender_node.get("config") or {}).get("layer_id")
        posts.append({
            "sender_id":   sender_id,
            "sender_layer": sender_layer,
            "channel_id": channel_id,
            "payload":    payload,
            "sent_at_ms": c.get("at_ms"),
        })
    return posts


def configured_pairs(cfg, name_to_id, hash_layer_to_name):
    """Return set of (origin_id, dst_id) the scenario *intends* to deliver.

    Recognises both same-layer `send <name>` and cross-layer
    `send_layer <target_layer> <dst_key_hash32_decimal>`. For
    `send_layer`, the dst is resolved via (target_layer_id, hash) ->
    node_name, then to that node's short id.
    """
    pairs = set()
    for c in cfg.get("commands", []):
        node = c.get("node")
        cmd = c.get("command", "")
        m_layer = SEND_LAYER_RE.match(cmd)
        if m_layer:
            target_layer = int(m_layer.group(1))
            try:
                target_hash = int(m_layer.group(2))
            except ValueError:
                continue
            dst_name = hash_layer_to_name.get((target_layer, target_hash))
            if node in name_to_id and dst_name in name_to_id:
                pairs.add((name_to_id[node], name_to_id[dst_name]))
            continue
        m = SEND_RE.match(cmd)
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


def analyse(events_path, slot_to_id, hash_layer_to_name=None):
    hash_layer_to_name = hash_layer_to_name or {}
    name_to_id_local = None
    msgs = {}
    # First pass: build (origin, ctr) -> dst from events that carry dst.
    # Second pass below applies the index to events that lack dst.
    origin_ctr_to_dst = {}
    # Cross-layer arrival index: (receiver_id, payload) -> first t_ms.
    # Cross-layer messages have their on-wire origin/ctr rewritten by
    # the gateway, so payload at the target node is the only stable link
    # back to the originator's user-message.
    arrival_by_payload = {}
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        o = d.get("origin") or d.get("src")
        c = d.get("ctr")
        if c is None:
            c = d.get("ctr_lo")
        dst = d.get("dst")
        if o is not None and c is not None and dst is not None:
            origin_ctr_to_dst.setdefault((o, c), dst)
        if et == "data_rx":
            payload = d.get("payload")
            if payload is not None:
                key = (fid, payload)
                if key not in arrival_by_payload:
                    arrival_by_payload[key] = t_ms

    # Index for looking up the originator's record from gateway-side
    # handoff events. (origin, ctr) -> record_key (origin, dst, ctr)
    # where dst is the gateway short id used as the envelope wire-dst.
    origin_ctr_to_record_key = {}

    def rec_create(k):
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
                # Cross-layer extension. via_gateway flips True when the
                # originator's tx_enqueue carries it; target_id resolves
                # to the cross-layer destination (via key_hash32 lookup);
                # arrival_at_target_ms records data_rx at the resolved
                # target's slot (via payload matching, not ctr — the
                # gateway re-issues with a fresh origin/ctr).
                "via_gateway":             False,
                "target_layer_id":         None,
                "dst_key_hash32":          None,
                "target_id":               None,
                "arrival_at_target_ms":    None,
                "handoff_enqueued_ms":     None,
                "handoff_drained_ms":      None,
                "handoff_deferred_reason": None,
                "handoff_giveup_reason":   None,
            }
        return msgs[k]

    def rec_lookup(k):
        return msgs.get(k)

    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        # Gateway-side handoff events refer to the originator's record
        # via origin + ctr + via_gateway (the gateway short id). They
        # MUST NOT create new records — they only annotate existing
        # originator records with handoff lifecycle timestamps.
        if et in ("gateway_handoff_enqueued", "gateway_handoff_drained",
                  "gateway_handoff_deferred", "gateway_handoff_giveup"):
            o = d.get("origin")
            c = d.get("ctr")
            if c is None:
                c = d.get("ctr_lo")
            gw = d.get("via_gateway")
            if o is None or c is None or gw is None:
                continue
            r = rec_lookup((o, gw, c))
            if r is None:
                continue
            if et == "gateway_handoff_enqueued" and r["handoff_enqueued_ms"] is None:
                r["handoff_enqueued_ms"] = t_ms
            elif et == "gateway_handoff_drained" and r["handoff_drained_ms"] is None:
                r["handoff_drained_ms"] = t_ms
            elif et == "gateway_handoff_deferred":
                r["handoff_deferred_reason"] = d.get("reason")
            elif et == "gateway_handoff_giveup":
                r["handoff_giveup_reason"] = d.get("reason")
            continue

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

        # Record creation policy: ONLY tx_enqueue at fid==origin starts
        # a record. Everything else updates an existing record (and is
        # silently skipped if no record exists — which happens for the
        # gateway's re-issued second-leg frames whose `origin` field is
        # rewritten to the gateway's own id).
        is_originator_enqueue = (et == "tx_enqueue" and fid == origin)
        if is_originator_enqueue:
            r = rec_create(k)
        else:
            r = rec_lookup(k)
            if r is None:
                continue
        if r["payload"] is None and "payload" in d:
            r["payload"] = d["payload"]

        # Outcome timestamps. Only the *first* of each kind is kept.
        if is_originator_enqueue and r["enqueued_ms"] is None:
            r["enqueued_ms"] = t_ms
            # Cross-layer detection: originator's tx_enqueue for a
            # send_layer carries via_gateway=True, target_layer_id,
            # dst_key_hash32. The wire `dst` is the gateway; the user-
            # facing target is resolved from the hash.
            if d.get("via_gateway") is True:
                r["via_gateway"] = True
                r["target_layer_id"] = d.get("target_layer_id")
                r["dst_key_hash32"] = d.get("dst_key_hash32")
                # Cross-layer target resolution is done in a post-pass
                # below so we have access to the full name_to_id map.
            origin_ctr_to_record_key[(origin, ctr)] = k
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

    # Post-pass: resolve cross-layer target_id from key_hash + look up
    # arrival via payload at the target. This is the only honest
    # delivery signal for send_layer messages — the gateway rewrites
    # origin/ctr on the second leg.
    return msgs, arrival_by_payload


def outcome(rec):
    """Per-message terminal outcome.

    NB: `ack_ms` is the FIRST-HOP ACK from the originator's next-hop
    forwarder. It does not mean end-to-end delivery — only `arrived`
    (destination data_rx) means that. For cross-layer (`via_gateway`)
    messages, arrival is detected at the resolved target via payload
    matching, since the gateway re-issues with a fresh origin/ctr.
    """
    arr = _arrived(rec)
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


def effective_dst(rec):
    """User-facing destination id (cross-layer aware)."""
    if rec.get("via_gateway") and rec.get("target_id") is not None:
        return rec["target_id"]
    return rec["dst"]


def _arrived(rec):
    """True if the user-facing destination got the message.

    Cross-layer: arrival is at the resolved target (after gateway
    handoff), not at the gateway. Same-layer: arrival is at dst.
    """
    if rec.get("via_gateway"):
        return rec["arrival_at_target_ms"] is not None
    return rec["arrived_ms"] is not None


def summarise(msgs, pair_filter, id_to_name):
    by_pair = defaultdict(list)
    for k, r in msgs.items():
        eff_dst = effective_dst(r)
        if pair_filter is not None and (r["origin"], eff_dst) not in pair_filter:
            continue
        by_pair[(r["origin"], eff_dst)].append(r)
    rows = []
    for (origin, dst), recs in sorted(by_pair.items()):
        n = len(recs)
        arrived = sum(1 for r in recs if _arrived(r))
        acked = sum(1 for r in recs if r["ack_ms"] is not None)
        giveup = sum(1 for r in recs if outcome(r) == "giveup")
        in_flight = sum(1 for r in recs if outcome(r) == "in_flight")
        any_cross = any(r.get("via_gateway") for r in recs)
        hops_list = [len(r["carriers"]) for r in recs if _arrived(r)]
        mean_hops = (sum(hops_list) / len(hops_list)) if hops_list else None
        giveup_reasons = [r["giveup_reason"] for r in recs
                          if r["giveup_reason"]]
        rows.append({
            "origin":     fmt_node(origin, id_to_name),
            "dst":        fmt_node(dst, id_to_name),
            "sent":       n,
            "arrived":    arrived,
            "acked":      acked,
            "giveup":     giveup,
            "in_flight":  in_flight,
            "mean_hops":  mean_hops,
            "giveup_reasons": giveup_reasons,
            "cross_layer": any_cross,
        })
    return rows


def render_table(rows):
    if not rows:
        print("(no matching DM messages found)")
        return
    # "h1_ack" = originator got the hop-1 ACK; NOT end-to-end.
    # See outcome() docstring for details.
    # Pair column is wider now: "alice(1) -> bob(2)" can hit ~22 chars
    # for two-digit IDs. "*" suffix marks cross-layer rows.
    header = ["pair", "sent", "arr", "arr%", "h1ack", "h1ack%",
              "giveup", "in_flight", "mean_hops"]
    fmt = "{:<28} {:>4} {:>4} {:>5} {:>5} {:>6} {:>6} {:>9} {:>9}"
    print(fmt.format(*header))
    print("-" * 80)
    tot = {"sent": 0, "arrived": 0, "acked": 0,
           "giveup": 0, "in_flight": 0}
    for r in rows:
        tag = " *" if r.get("cross_layer") else ""
        pair = f"{r['origin']} -> {r['dst']}{tag}"
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
    # Filter on effective pair (cross-layer aware) so detail mode and
    # the summary table stay consistent on which messages appear.
    keys = []
    for k, r in msgs.items():
        eff = effective_dst(r)
        if pair_filter is None or (r["origin"], eff) in pair_filter:
            keys.append(k)
    keys.sort(key=lambda k: (k[0], k[1], k[2]))
    for k in keys:
        r = msgs[k]
        # For cross-layer messages, the wire dst is the gateway; the
        # logical/user-facing target is r["target_id"]. Show "via gw"
        # in the header so the reader sees where the handoff happened.
        origin_n = fmt_node(r["origin"], id_to_name)
        if r.get("via_gateway"):
            target_n = fmt_node(r.get("target_id"), id_to_name)
            via_n = fmt_node(r["dst"], id_to_name)
            head = f"=== {origin_n} -> {target_n} via {via_n} ctr={r['ctr']} ==="
        else:
            dst_n = fmt_node(r["dst"], id_to_name)
            head = f"=== {origin_n} -> {dst_n} ctr={r['ctr']} ==="
        out_label = outcome(r)
        hop_count = len(r["carriers"])
        head_parts = [head]
        if r["payload"] is not None:
            head_parts.append(f'payload="{r["payload"]}"')
        head_parts.append(f"outcome={out_label}")
        head_parts.append(f"carriers={hop_count}")
        if r["enqueued_ms"] is not None:
            head_parts.append(f"enq={r['enqueued_ms']}ms")
        if r.get("via_gateway") and r.get("arrival_at_target_ms") is not None:
            head_parts.append(f"arr_at_target={r['arrival_at_target_ms']}ms")
        if r["arrived_ms"] is not None:
            head_parts.append(f"arr_at_dst={r['arrived_ms']}ms")
        if r["ack_ms"] is not None:
            head_parts.append(f"ack={r['ack_ms']}ms")
        if r["giveup_ms"] is not None:
            head_parts.append(f"giveup={r['giveup_ms']}ms"
                              f"({r['giveup_reason']})")
        print(" ".join(head_parts))
        for ev in r["events"]:
            node_n = fmt_node(ev["node"], id_to_name)
            # Field values for known node-id fields get the name(id)
            # treatment so "next=alice(1)" reads cleanly.
            rendered = []
            for kk, vv in ev["fields"].items():
                if kk in NODE_ID_FIELDS and isinstance(vv, int):
                    rendered.append(f"{kk}={fmt_node(vv, id_to_name)}")
                else:
                    rendered.append(f"{kk}={vv}")
            field_str = " ".join(rendered)
            print(f"  {ev['t_ms']:>8} ms  {node_n:<12} "
                  f"{ev['type']:<22} {field_str}")
        print()


def render_json(rows, msgs, pair_filter, id_to_name, detail):
    out = {"summary": rows}
    if detail:
        keys = []
        for k, r in msgs.items():
            eff = effective_dst(r)
            if pair_filter is None or (r["origin"], eff) in pair_filter:
                keys.append(k)
        keys.sort(key=lambda k: (k[0], k[1], k[2]))
        messages = []
        for k in keys:
            r = msgs[k]
            def render_fields(fields):
                """Convert known node-id fields to name(id) strings."""
                out_f = {}
                for kk, vv in fields.items():
                    if kk in NODE_ID_FIELDS and isinstance(vv, int):
                        out_f[kk] = fmt_node(vv, id_to_name)
                    else:
                        out_f[kk] = vv
                return out_f
            entry = {
                "origin":      fmt_node(r["origin"], id_to_name),
                "dst":         fmt_node(r["dst"], id_to_name),
                "ctr":         r["ctr"],
                "payload":     r["payload"],
                "outcome":     outcome(r),
                "enqueued_ms": r["enqueued_ms"],
                "arrived_ms":  r["arrived_ms"],
                "ack_ms":      r["ack_ms"],
                "giveup_ms":   r["giveup_ms"],
                "giveup_reason": r["giveup_reason"],
                "carriers":    sorted(fmt_node(c, id_to_name)
                                      for c in r["carriers"]),
                "hops":        len(r["carriers"]),
                "events":      [
                    {"t_ms":   ev["t_ms"],
                     "node":   fmt_node(ev["node"], id_to_name),
                     "type":   ev["type"],
                     "fields": render_fields(ev["fields"])}
                    for ev in r["events"]
                ],
            }
            if r.get("via_gateway"):
                entry["via_gateway"]            = True
                entry["target"]                 = fmt_node(r.get("target_id"),
                                                           id_to_name)
                entry["target_layer_id"]        = r.get("target_layer_id")
                entry["dst_key_hash32"]         = r.get("dst_key_hash32")
                entry["arrival_at_target_ms"]   = r.get("arrival_at_target_ms")
                entry["handoff_enqueued_ms"]    = r.get("handoff_enqueued_ms")
                entry["handoff_drained_ms"]     = r.get("handoff_drained_ms")
                entry["handoff_deferred_reason"]= r.get("handoff_deferred_reason")
                entry["handoff_giveup_reason"]  = r.get("handoff_giveup_reason")
            messages.append(entry)
        out["messages"] = messages
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


CHANNEL_EVENT_TYPES = {
    "channel_msg_received",
    "channel_msg_overheard",
    "channel_msg_pulled",
    "channel_msg_already_present",
    "channel_msg_seen_by_neighbour",
    "channel_pull_sent",
    "channel_pull_received",
    "channel_pull_suppressed",
    "channel_overhear_armed",
    "channel_overhear_skipped_already_have",
    "channel_overhear_missed",
    "channel_broadcast_deduped",
    "channel_dirty_cleared",
    "channel_digest_emitted",
}

# data fields rendered when present, in channel-detail timeline lines.
CHANNEL_TIMELINE_FIELDS = (
    "source", "from", "to", "next", "channel_id",
    "reason", "overheard_from", "peer", "ad_count", "threshold",
    "chosen_data_sf", "addressed", "guard_ms",
)


def analyse_channel(events_path, slot_to_id, posts):
    """Walk events to find each post's msg_id, recipients, and event timeline.

    Each `send_channel` command gets matched to the originator's
    `channel_msg_received{source=self_originate}` event by
    (sender_id, channel_id, payload). That event carries the 32-bit
    `id` which uniquely identifies the post network-wide; every
    subsequent channel-* event with the same id is part of this
    post's lifecycle.

    Two-tier matching:
      - Events with explicit `id` -> matched by id
      - `channel_pull_received` carries `channel_ids[]` (a Q frame
        may request multiple ids in one frame); each requested id is
        added independently to its post's timeline.
      - `channel_digest_emitted` carries `dirty_ids[]`; same.
    """
    by_key = {}
    for p in posts:
        k = (p["sender_id"], p["channel_id"], p["payload"])
        by_key.setdefault(k, []).append(p)
        p["msg_id"] = None
        p["originated_ms"] = None
        p["recipients"] = {}
        p["already_present"] = 0
        p["events"] = []

    # Pass 1: find msg_id from each post's self_originate event.
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        if et != "channel_msg_received":
            continue
        if d.get("source") != "self_originate":
            continue
        k = (fid, d.get("channel_id"), d.get("payload"))
        bucket = by_key.get(k)
        if not bucket:
            continue
        for p in bucket:
            if p["msg_id"] is None:
                p["msg_id"] = d.get("id")
                p["originated_ms"] = t_ms
                break

    by_msg_id = {p["msg_id"]: p for p in posts if p["msg_id"] is not None}
    # Partial-match index for overhear events that carry (sender, ctr_lo)
    # rather than the full 32-bit id. channel_msg_id_t layout (per
    # PROTOCOL §3.4.1): id = (origin<<24) | (keyhash_lo16<<8) | ctr_lo.
    by_sender_ctrlo = {}
    for mid, p in by_msg_id.items():
        sender = (mid >> 24) & 0xff
        ctr_lo = mid & 0xff
        by_sender_ctrlo[(sender, ctr_lo)] = p

    def _push_event(p, t_ms, fid, et, d, extra_id_field=None):
        """Append a copy of the event to the post's timeline."""
        fields = {k: d[k] for k in CHANNEL_TIMELINE_FIELDS if k in d}
        if extra_id_field is not None:
            fields["_id_in_list"] = extra_id_field
        p["events"].append({"t_ms": t_ms, "node": fid,
                            "type": et, "fields": fields})

    # Per-event-type keying — see the keys-by-type table in
    # CHANNEL_EVENT_TYPES discovery.
    SINGLE_ID_EVENTS = {
        "channel_msg_received",
        "channel_msg_overheard",
        "channel_msg_already_present",
        "channel_msg_seen_by_neighbour",
        "channel_broadcast_deduped",
        "channel_dirty_cleared",
    }
    MULTI_ID_EVENTS = {
        "channel_pull_sent",
        "channel_pull_received",
        "channel_pull_suppressed",
        "channel_msg_pulled",
    }
    SENDER_CTRLO_EVENTS = {
        "channel_overhear_armed",
        "channel_overhear_skipped_already_have",
        "channel_overhear_missed",
    }

    # Pass 2: collect recipient state + per-post event timeline.
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        if et not in CHANNEL_EVENT_TYPES:
            continue
        if et in SINGLE_ID_EVENTS:
            p = by_msg_id.get(d.get("id"))
            if p is None:
                continue
            _push_event(p, t_ms, fid, et, d)
            if et == "channel_msg_received":
                if d.get("source") == "self_originate":
                    continue
                if fid not in p["recipients"]:
                    p["recipients"][fid] = {
                        "source": d.get("source"),
                        "from":   d.get("from"),
                        "t_ms":   t_ms,
                    }
            elif et == "channel_msg_already_present" and fid in p["recipients"]:
                p["already_present"] += 1
        elif et in MULTI_ID_EVENTS:
            ids = d.get("ids") or []
            for mid in ids:
                p = by_msg_id.get(mid)
                if p is None:
                    continue
                _push_event(p, t_ms, fid, et, d, extra_id_field=mid)
        elif et in SENDER_CTRLO_EVENTS:
            sender = d.get("sender")
            ctr_lo = d.get("ctr_lo")
            if sender is None or ctr_lo is None:
                continue
            p = by_sender_ctrlo.get((sender, ctr_lo))
            if p is None:
                continue
            _push_event(p, t_ms, fid, et, d)
        elif et == "channel_digest_emitted":
            # Originator's BCN included these dirty ids in its digest.
            ids = d.get("dirty_ids") or d.get("ids") or []
            for mid in ids:
                p = by_msg_id.get(mid)
                if p is None:
                    continue
                _push_event(p, t_ms, fid, et, d, extra_id_field=mid)

    # Per-post derived stats.
    for p in posts:
        p["events"].sort(key=lambda x: (x["t_ms"], x["node"]))
        # Cascade-depth tree: BFS-style fixed point on the `from` edges.
        # depth(origin)=0; depth(recipient)=depth(from)+1 if `from` is
        # known to have received the msg. Falls back to None for any
        # recipient whose `from` is missing or never resolves (e.g.
        # overhear with no from field, or pre-warmup-state weirdness).
        depths = {p["sender_id"]: 0}
        changed = True
        while changed:
            changed = False
            for rcv_id, info in p["recipients"].items():
                if rcv_id in depths:
                    continue
                from_id = info.get("from")
                if from_id is None:
                    continue
                if from_id in depths:
                    depths[rcv_id] = depths[from_id] + 1
                    info["depth"] = depths[rcv_id]
                    changed = True
        # Track unresolved depths (recipients whose `from` chain never
        # reaches origin — usually a sign of stale `from` data).
        for rcv_id, info in p["recipients"].items():
            if rcv_id not in depths:
                info["depth"] = None
        # Count secondary holders that re-broadcast: channel_msg_pulled
        # events fire at the holder when it sends an M-payload in
        # response to a Q. Count distinct nodes that fired this for the
        # post id.
        broadcasters = set()
        pulls_sent = 0
        for ev in p["events"]:
            if ev["type"] == "channel_msg_pulled":
                broadcasters.add(ev["node"])
            elif ev["type"] == "channel_pull_sent":
                pulls_sent += 1
        p["depths"] = {rid: depths[rid] for rid in p["recipients"]
                       if rid in depths}
        depth_vals = [v for v in p["depths"].values() if v is not None]
        p["max_depth"] = max(depth_vals) if depth_vals else None
        p["mean_depth"] = (sum(depth_vals) / len(depth_vals)
                           if depth_vals else None)
        p["broadcasters"] = broadcasters         # includes origin if it
                                                 # also responded to pulls
        p["pulls_sent"] = pulls_sent
    return posts


def summarise_channel(posts, cfg, id_to_name):
    """Per-post rows: reach, expected, sources, leaks."""
    # Same-layer non-gateway node count per layer.
    per_layer_nongw = defaultdict(int)
    node_layer = {}
    node_is_gw = {}
    for n in cfg["nodes"]:
        nid = n["node_id"]
        cfg_block = n.get("config") or {}
        layer = cfg_block.get("layer_id")
        is_gw = bool(cfg_block.get("is_gateway"))
        node_layer[nid] = layer
        node_is_gw[nid] = is_gw
        if not is_gw:
            per_layer_nongw[layer] += 1

    rows = []
    for p in posts:
        same_layer = 0
        leaks = 0
        sources = defaultdict(int)
        first_recv_ms = None
        last_recv_ms = None
        for rcv_id, info in p["recipients"].items():
            rcv_layer = node_layer.get(rcv_id)
            sources[info["source"] or "unknown"] += 1
            if rcv_layer == p["sender_layer"]:
                same_layer += 1
            else:
                leaks += 1
            if first_recv_ms is None or info["t_ms"] < first_recv_ms:
                first_recv_ms = info["t_ms"]
            if last_recv_ms is None or info["t_ms"] > last_recv_ms:
                last_recv_ms = info["t_ms"]
        expected = max(0, per_layer_nongw.get(p["sender_layer"], 0) - 1)
        spread_ms = (last_recv_ms - first_recv_ms) \
                    if (first_recv_ms is not None and last_recv_ms is not None) \
                    else None
        first_lat_ms = (first_recv_ms - p["originated_ms"]) \
                       if (first_recv_ms is not None
                           and p["originated_ms"] is not None) else None
        rows.append({
            "sender":      fmt_node(p["sender_id"], id_to_name),
            "layer":       p["sender_layer"],
            "channel_id":  p["channel_id"],
            "payload":     p["payload"],
            "sent_at_ms":  p["sent_at_ms"],
            "msg_id":      p["msg_id"],
            "reach":       same_layer,
            "expected":    expected,
            "leaks":       leaks,
            "sources":     dict(sources),
            "already_present": p["already_present"],
            "first_recv_lat_ms": first_lat_ms,
            "spread_ms":   spread_ms,
            "max_depth":   p.get("max_depth"),
            "mean_depth":  p.get("mean_depth"),
            "broadcasters": len(p.get("broadcasters") or []),
            "pulls_sent":  p.get("pulls_sent", 0),
        })
    return rows


def render_channel_table(rows):
    if not rows:
        print("(no channel posts in scenario)")
        return
    header = ["post (sender / payload)", "ch", "L",
              "reach", "reach%", "sources", "lat_ms", "depth",
              "bcst", "pulls", "leaks"]
    fmt = ("{:<38} {:>3} {:>2} {:>7} {:>6} "
           "{:<20} {:>7} {:>6} {:>4} {:>5} {:>5}")
    print(fmt.format(*header))
    print("-" * 112)
    total_reach = 0
    total_expected = 0
    total_leaks = 0
    for r in rows:
        reach_str = f"{r['reach']}/{r['expected']}"
        pct = (f"{100*r['reach']/r['expected']:.0f}%"
               if r["expected"] else "-")
        src_str = " ".join(
            f"{k[:3]}:{v}" for k, v in
            sorted(r["sources"].items(), key=lambda kv: -kv[1])
        ) if r["sources"] else "-"
        lat = (f"{r['first_recv_lat_ms']}"
               if r["first_recv_lat_ms"] is not None else "-")
        depth_str = (f"{r['max_depth']}"
                     if r["max_depth"] is not None else "-")
        head = f"{r['sender']:<14} {r['payload'][:22]:<22}"
        print(fmt.format(head, r["channel_id"], r["layer"],
                         reach_str, pct, src_str, lat,
                         depth_str, r["broadcasters"],
                         r["pulls_sent"], r["leaks"]))
        total_reach += r["reach"]
        total_expected += r["expected"]
        total_leaks += r["leaks"]
    print("-" * 112)
    pct = (f"{100*total_reach/total_expected:.0f}%"
           if total_expected else "-")
    print(fmt.format(
        f"TOTAL ({len(rows)} posts)",
        "-", "-",
        f"{total_reach}/{total_expected}", pct, "-", "-", "-", "-", "-",
        total_leaks))


def render_channel_detail(rows_meta, id_to_name, post_filter):
    """Per-post timeline. rows_meta is the list of post records
    (returned by analyse_channel), each with msg_id, recipients, events.
    """
    for p in rows_meta:
        if post_filter is not None:
            pat = post_filter.lower()
            if pat not in (p.get("payload") or "").lower():
                continue
        sender_n = fmt_node(p["sender_id"], id_to_name)
        head_parts = [
            f"=== {sender_n} -> ch{p['channel_id']} "
            f'"{p.get("payload","")}"',
            f"L{p.get('sender_layer')}",
            f"id=0x{(p.get('msg_id') or 0):08X}",
            f"reach={len(p['recipients'])}",
        ]
        if p.get("max_depth") is not None:
            head_parts.append(f"max_depth={p['max_depth']}")
            head_parts.append(f"mean_depth={p['mean_depth']:.2f}")
        if p.get("broadcasters"):
            head_parts.append(f"broadcasters={len(p['broadcasters'])}")
        head_parts.append(f"pulls_sent={p.get('pulls_sent', 0)}")
        if p.get("originated_ms") is not None:
            head_parts.append(f"orig={p['originated_ms']}ms")
        # Cascade total time: first->last recipient.
        if p["recipients"]:
            first_ms = min(info["t_ms"] for info in p["recipients"].values())
            last_ms = max(info["t_ms"] for info in p["recipients"].values())
            head_parts.append(f"first_recv={first_ms}ms")
            head_parts.append(f"last_recv={last_ms}ms")
            if p.get("originated_ms") is not None:
                head_parts.append(f"first_lat={first_ms - p['originated_ms']}ms")
                head_parts.append(f"cascade={last_ms - first_ms}ms")
        head_parts.append("===")
        print(" ".join(head_parts))
        # Recipients grouped by source + depth.
        if p["recipients"]:
            # Sort all recipients by depth then time so the cascade reads
            # top-down. Show one line per recipient.
            rcv_sorted = sorted(
                p["recipients"].items(),
                key=lambda kv: (kv[1].get("depth") if kv[1].get("depth") is not None else 99,
                                kv[1]["t_ms"])
            )
            for rcv_id, info in rcv_sorted:
                lat = (info["t_ms"] - p["originated_ms"]
                       if p.get("originated_ms") is not None else None)
                lat_s = f"+{lat}ms" if lat is not None else "?"
                depth = info.get("depth")
                depth_s = f"depth={depth}" if depth is not None else "depth=?"
                from_s = (f"from={fmt_node(info['from'], id_to_name)}"
                          if info.get("from") is not None else "from=?")
                src = info.get("source") or "unknown"
                print(f"  recv {fmt_node(rcv_id, id_to_name):<12} "
                      f"{depth_s:<9} {src:<14} {from_s:<18} "
                      f"@ {info['t_ms']:>8}ms ({lat_s})")
        else:
            print("  recipients: (none)")
        if not p["events"]:
            print("  (no channel-plane events captured for this id)")
            print()
            continue
        for ev in p["events"]:
            node_n = fmt_node(ev["node"], id_to_name)
            rendered = []
            for kk, vv in ev["fields"].items():
                if kk in NODE_ID_FIELDS and isinstance(vv, int):
                    rendered.append(f"{kk}={fmt_node(vv, id_to_name)}")
                else:
                    rendered.append(f"{kk}={vv}")
            field_str = " ".join(rendered)
            print(f"  {ev['t_ms']:>8} ms  {node_n:<12} "
                  f"{ev['type']:<40} {field_str}")
        print()


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
    p.add_argument("--mode", choices=("dm", "channel", "all"), default="all",
                   help="which view to emit (default: all)")
    p.add_argument("--post", default=None,
                   help="filter channel posts: payload substring "
                        "(case-insensitive), e.g. 'news-3'")
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

    cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name \
        = load_config(args.config)
    msgs, arrival_by_payload = analyse(args.events, slot_to_id,
                                       hash_layer_to_name)

    # Post-pass: resolve cross-layer target_id + arrival_at_target_ms.
    # Done here (not in analyse) because we need name_to_id which the
    # caller already has.
    for r in msgs.values():
        if not r.get("via_gateway"):
            continue
        t_layer = r.get("target_layer_id")
        t_hash = r.get("dst_key_hash32")
        if t_layer is None or t_hash is None:
            continue
        t_name = hash_layer_to_name.get((t_layer, t_hash))
        if t_name is None:
            continue
        t_id = name_to_id.get(t_name)
        if t_id is None:
            continue
        r["target_id"] = t_id
        if r["payload"] is not None:
            r["arrival_at_target_ms"] = arrival_by_payload.get((t_id, r["payload"]))

    # Pair filter: explicit --pair wins; else configured commands;
    # else (with --all) no filter at all.
    explicit = parse_pair_filter(args.pair, name_to_id)
    if explicit is not None:
        pair_filter = explicit
    elif args.all:
        pair_filter = None
    else:
        pair_filter = configured_pairs(cfg, name_to_id, hash_layer_to_name)

    rows = summarise(msgs, pair_filter, id_to_name)

    channel_rows = None
    posts_meta = None
    if args.mode in ("channel", "all"):
        posts_meta = configured_channel_posts(cfg, name_to_id)
        analyse_channel(args.events, slot_to_id, posts_meta)
        # Apply --post filter to BOTH the table and the detail view
        # so they stay consistent (mirrors --pair in DM mode).
        rows_for_summary = posts_meta
        if args.post:
            pat = args.post.lower()
            rows_for_summary = [
                p for p in posts_meta
                if pat in (p.get("payload") or "").lower()
            ]
        channel_rows = summarise_channel(rows_for_summary, cfg, id_to_name)

    if args.json:
        if args.mode == "channel":
            payload = {"channels": channel_rows or []}
        elif args.mode == "dm":
            render_json(rows, msgs, pair_filter, id_to_name, args.detail)
            return
        else:
            # Inline-render the DM JSON view into a dict so we can pair it
            # with channels under one top-level structure.
            from io import StringIO
            buf = StringIO()
            old_stdout = sys.stdout
            sys.stdout = buf
            try:
                render_json(rows, msgs, pair_filter, id_to_name, args.detail)
            finally:
                sys.stdout = old_stdout
            dm_payload = json.loads(buf.getvalue())
            payload = {**dm_payload, "channels": channel_rows or []}
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    if args.mode in ("dm", "all"):
        print("=== DM ===")
        render_table(rows)
        if args.detail:
            print()
            render_detail_text(msgs, pair_filter, id_to_name)
    if args.mode in ("channel", "all"):
        if args.mode == "all":
            print()
        print("=== Channels ===")
        render_channel_table(channel_rows)
        if args.detail:
            print()
            render_channel_detail(posts_meta, id_to_name, args.post)


if __name__ == "__main__":
    main()
