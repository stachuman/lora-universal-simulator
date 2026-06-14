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
  --failures             DM mode: break failed DMs down by routing-layer
                         mechanism (no-route / next-hop-silent / post-gateway /
                         no-gateway / in-flight), same vs cross-layer. Cross-layer
                         failures that reached the gateway but never delivered are
                         sub-classified by WHERE the second leg died — "no route
                         to target" (gw never RTS'd the forward → awaiting RREP),
                         "first-hop stalled" (RTS'd, no hop-1 ACK), "lost
                         downstream" (handed off, lost >=2 hops out), or the
                         resolve-bound cases — plus a HOME/VISIT tally of the
                         target's layer relative to the gateway.
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
import math
import os
import re
import subprocess
import sys
from collections import defaultdict, Counter

# --- LoRa airtime (mirrors dv_dual_sf.lua airtime_ms) + frame sizes ---
RTS_LEN, CTS_LEN, ACK_LEN, NACK_LEN, MAC_LEN = 8, 3, 3, 4, 4
DATA_HDR_LEN = 14          # 8 + 6-byte visited window
PREAMBLE_SYM = 16          # PROTOCOL default


def lora_airtime_ms(sf, bw_hz, cr, len_bytes, preamble_sym=PREAMBLE_SYM):
    """Port of dv_dual_sf.lua:airtime_ms — verified to match the PHY tx airtime
    (e.g. SF7/BW125, 76 B -> 146 ms)."""
    t_sym = (2 ** sf) / (bw_hz / 1000.0)
    t_pre = (preamble_sym + 4.25) * t_sym
    de = 1 if t_sym >= 16 else 0
    num = 8 * len_bytes - 4 * sf + 44
    den = 4 * (sf - 2 * de)
    pay_sym = 8 + max(math.ceil(num / den) * cr, 0)
    return math.floor(t_pre + pay_sym * t_sym)


def maybe_run(cfg_path, events_path, lus_path):
    print(f"# running {lus_path} {cfg_path} -> {events_path}", file=sys.stderr)
    res = subprocess.run([lus_path, cfg_path, events_path],
                         capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stdout)
        sys.stderr.write(res.stderr)
        raise SystemExit(f"lus exited {res.returncode}")


# Map a timeline event to the on-wire frame type it corresponds to
# (the tag the visualizer / wire dump uses): B R C K N D Q H, plus
# "D-M" for the channel M-broadcast. Events that aren't a frame
# (queue ops, route decisions, terminal markers) get "".
EMIT_FRAME_TYPE = {
    # firmware-level (script_emit) events
    "rts_tx": "R", "rts_retry": "R", "rts_fwd": "R", "rts_attempt_detail": "R",
    "cts_rx": "C",
    "data_tx": "D", "data_rx": "D",
    "ack_rx": "K", "ack_snr_feedback": "K",
    "channel_pull_sent": "Q", "channel_pull_received": "Q",
    "channel_pull_suppressed": "Q", "channel_msg_pulled": "Q",
    "channel_msg_seen_by_neighbour": "B",   # learned via a peer's BCN digest
    "channel_dirty_cleared": "B",            # cleared while building a BCN
    "h_tx": "H", "h_rx": "H", "h_forward": "H", "h_resolved": "H",
}


def frame_type_for(ev):
    """Return the on-wire frame-type tag for a timeline event, or ''.

    PHY events (`phy_*`) carry the radio's own label (RTS/DATA-M/BCN/H/
    ...); reduce it to the single-letter tag (DATA-M -> D-M). Firmware
    events map via EMIT_FRAME_TYPE.
    """
    et = ev.get("type", "")
    if et.startswith("phy_"):
        lbl = ev.get("fields", {}).get("label")
        if lbl:
            return {"RTS": "R", "RTS-fwd": "R", "RTS-rty": "R",
                    "CTS": "C", "CTS-dup": "C", "ACK": "K", "NACK": "N",
                    "DATA": "D", "DATA-M": "D-M", "BCN": "B",
                    "Q": "Q", "H": "H"}.get(lbl, lbl)
        # phy rx/drop events are keyed by a kind suffix instead of a label.
        if et.endswith("_data_m"):
            return "D-M"
        if et.endswith("_bcn"):
            return "B"
        return "?"
    return EMIT_FRAME_TYPE.get(et, "")


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
    # Node ids are positional now — the orchestrator assigns them by node order, so
    # configs no longer carry an explicit `node_id`. Normalize once so every downstream
    # `n["node_id"]` keeps working: honour an explicit id (legacy configs) else use the
    # 1-BASED slot index (i+1), matching SimController's protocol-id default — 0 is the
    # reserved "unprovisioned" sentinel. (Mutates the in-memory dicts only; file untouched.)
    for i, n in enumerate(nodes):
        n.setdefault("node_id", i + 1)
    id_to_name = {n["node_id"]: n["name"] for n in nodes}
    name_to_id = {n["name"]: n["node_id"] for n in nodes}
    slot_to_id = {i: n["node_id"] for i, n in enumerate(nodes)}
    # Cross-layer destinations are addressed by key_hash32 decimal in the
    # `send_layer` command; build (target_layer_id, hash) -> name so we
    # can resolve them. layer_id lives at config.layer_id (regular nodes)
    # or, for gateways visiting another layer, in gateway_layers[].
    hash_layer_to_name = {}
    id_to_layer = {}
    for n in nodes:
        cfg_block = n.get("config", {}) or {}
        layer = cfg_block.get("layer_id")
        if layer is not None:
            id_to_layer[n["node_id"]] = layer
        h = _hash_key_to_int(n.get("key_hash32"))
        if h is None:
            continue
        if layer is not None:
            hash_layer_to_name[(layer, h)] = n["name"]
    return cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name, id_to_layer


def gateway_layers(cfg):
    """Map each gateway id to its home layer and the list of layers it visits.
    Used to tag a cross-layer second-leg failure by whether the target sits on
    the gateway's HOME layer (present ~50% in long windows) or a VISIT layer."""
    gw_home, gw_visit = {}, {}
    for n in cfg.get("nodes", []):
        c = n.get("config") or {}
        visits = c.get("gateway_layers")
        if visits or c.get("is_gateway"):
            gw_home[n["node_id"]] = c.get("layer_id")
            gw_visit[n["node_id"]] = [v.get("layer_id") for v in (visits or [])]
    return gw_home, gw_visit


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
            # layer field may be a comma-separated source-routed hop path
            # (e.g. "1,3"); the destination sits on the LAST hop's layer.
            try:
                target_layer = int(m_layer.group(1).split(",")[-1])
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


def walk_phy_events(events_path, name_to_id):
    """Yield (time_ms, fid_or_None, phy_type, e) for physical-layer events.

    type in {tx, tx_deferred, rx, collision, drop_halfduplex,
    drop_sf_mismatch, drop_preamble_miss, drop_rx_blind, ...}. These events use
    string `node`/`from`/`to` fields, so we resolve via name_to_id.

    NB: the orchestrator emits collisions as type `collision` (not
    `drop_collision`) and off-SF drops as `drop_sf_mismatch` (not `drop_off_sf`).
    The old names matched nothing, so this walker was blind to collisions.
    """
    PHY_TYPES = {"tx", "tx_deferred", "rx", "collision", "drop_halfduplex",
                 "drop_sf_mismatch", "drop_preamble_miss", "drop_rx_blind"}
    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = e.get("type")
            if t not in PHY_TYPES:
                continue
            # `node` for tx/tx_deferred; `from`/`to` for rx/drop.
            yield e.get("time_ms", 0), t, e


def analyse(events_path, slot_to_id, hash_layer_to_name=None):
    hash_layer_to_name = hash_layer_to_name or {}
    name_to_id_local = None
    msgs = {}
    # First pass: build (origin, ctr) -> dst from events that carry dst.
    # Second pass below applies the index to events that lack dst.
    origin_ctr_to_dst = {}
    # Cross-layer arrival index: (target_id, payload) -> first t_ms.
    # The gateway rewrites origin/ctr on the second leg, so we key on the
    # target's user-facing payload. Source this from `delivered` (the target
    # firmware surfaced the message to the app), NOT `data_rx` (mere radio
    # receipt) -- data_rx also fires on relay-forwards, duplicates, and frames
    # that fail the inner/e2e check, which over-counts cross-layer arrival.
    # `delivered` carries dst (the resolved target id) and payload (the body),
    # giving a clean, collision-safe key.
    arrival_by_payload = {}
    # Cross-layer sends the originator dropped before any envelope/DATA (no
    # gateway route). These create NO record, so without this they'd be
    # invisible and the cross-layer denominator would be over-optimistic.
    drops = []
    # Cross-layer gateway-handoff giveups, keyed (origin, dst_key_hash32) —
    # the gateway received the envelope but couldn't resolve/route to the
    # target within its TTL. Distinct from a same-layer no-route giveup (both
    # surface as giveup_reason=defer_ttl, so they must be told apart here).
    gw_giveup = set()
    # Per-gateway layer-state timeline: {gw_id: [(t_ms, active_layer_id), ...]}.
    # Lets us tell, for a stalled-at-doorstep DM, whether the gateway was AWAY
    # on another layer (schedule/timing) or PRESENT-but-unresponsive (busy) at
    # the moment a neighbour RTS'd it.
    gw_layers = {}
    # --- Second-leg (cross-layer gateway forward) sub-classification ---
    # When an envelope reaches the gateway but the target never gets it, WHERE
    # did the forward die? handoff_enq: (sender, payload) -> [(gw, fwd_ctr,
    # target)] for each gateway_handoff_enqueued (binding resolved + forward
    # queued). delivered_fwd: (gw, target, fwd_ctr) the target actually decoded.
    # h_resolved / bind_set: did a resolver answer the gateway's 'H' query / did
    # the gateway learn the binding (resolve-bound drill). gw_fwd_origins: the
    # gateway ids that emit forwards (bounds the fwd-trace pass below).
    handoff_enq = defaultdict(list)
    delivered_fwd = set()
    h_resolved = set()
    bind_set = set()
    gw_fwd_origins = set()
    # Stage-funnel inputs. hops_by_payload: payload -> layer-hop path string
    # (e.g. "1,3") from the originator's envelope; len==1 -> single-gateway
    # (suburb<->center), len>=2 -> chained (suburb<->suburb via center).
    # transit_started: (origin, dst_key_hash32) that emitted a transit forward
    # (the first gw re-wrapped toward a second gw) -- i.e. Stage-2 was attempted.
    hops_by_payload = {}
    transit_started = set()
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        if et == "gateway_schedule_change":
            lyr = d.get("active_layer_id")
            if lyr is not None:
                gw_layers.setdefault(fid, []).append((t_ms, lyr))
            continue
        o = d.get("origin") or d.get("src")
        c = d.get("ctr")
        if c is None:
            c = d.get("ctr_lo")
        dst = d.get("dst")
        if o is not None and c is not None and dst is not None:
            origin_ctr_to_dst.setdefault((o, c), dst)
        if et == "delivered":
            payload = d.get("payload")
            if payload is not None and dst is not None:
                key = (dst, payload)
                if key not in arrival_by_payload:
                    arrival_by_payload[key] = t_ms
            # Second-leg arrival: for the gateway's re-issued forward, origin is
            # the gateway and ctr is the forward ctr.
            if o is not None and dst is not None and c is not None:
                delivered_fwd.add((o, dst, c))
        elif et == "gateway_envelope_dropped":
            drops.append({"origin": d.get("origin", fid),
                          "target_layer_id": d.get("target_layer_id"),
                          "dst_key_hash32": d.get("dst_key_hash32"),
                          "reason": d.get("reason")})
        elif et == "gateway_handoff_giveup":
            o2, hk = d.get("origin"), d.get("dst_key_hash32")
            if o2 is not None and hk is not None:
                gw_giveup.add((o2, hk))
        elif et == "gateway_handoff_enqueued":
            so, pl, gw = d.get("origin"), d.get("payload"), d.get("via_gateway")
            fctr, tgt = d.get("ctr"), d.get("dst")
            if so is not None and gw is not None and fctr is not None:
                handoff_enq[(so, pl)].append((gw, fctr, tgt))
                gw_fwd_origins.add(gw)
        elif et == "h_resolved":
            ho, hk = d.get("origin"), d.get("key_hash32")
            if ho is not None and hk is not None:
                h_resolved.add((ho, hk))
        elif et == "gateway_remote_bind_set":
            hk = d.get("key_hash32")
            if hk is not None:
                bind_set.add((fid, hk))
        elif et == "gateway_envelope_enqueued":
            pl, hp = d.get("payload"), d.get("hops")
            if pl is not None and hp is not None:
                hops_by_payload.setdefault(pl, str(hp))
        elif et == "gateway_envelope_transit":
            to_, hk = d.get("origin"), d.get("dst_key_hash32")
            if to_ is not None and hk is not None:
                transit_started.add((to_, hk))

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

    # Forward-trace for the second-leg classifier. The (gw, ctr) key collides
    # across targets, so carriers/gw_rts are keyed (gw, ctr, target) (rts_tx /
    # data_tx carry dst=target); hop1_ack is keyed (gw, ctr, payload) (ack_rx
    # lacks dst but carries payload). Built only for gateway forward-origins.
    fwd_carriers = defaultdict(set)
    fwd_gw_rts = set()
    fwd_hop1_ack = set()

    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        # Second-leg forward trace: who carried the gateway's forward, did the
        # gateway itself RTS it, and did the gateway get the hop-1 ACK?
        o_ = d.get("origin")
        if o_ in gw_fwd_origins:
            c_ = d.get("ctr")
            if et in ("rts_tx", "rts_retry", "rts_fwd", "data_tx"):
                dst_ = d.get("dst")
                if c_ is not None and dst_ is not None:
                    fwd_carriers[(o_, c_, dst_)].add(fid)
                    if fid == o_ and et in ("rts_tx", "rts_retry"):
                        fwd_gw_rts.add((o_, c_, dst_))
            elif et == "ack_rx" and fid == o_ and c_ is not None:
                fwd_hop1_ack.add((o_, c_, d.get("payload")))

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
    for tl in gw_layers.values():
        tl.sort()
    second_leg = {
        "handoff_enq":     handoff_enq,
        "delivered_fwd":   delivered_fwd,
        "h_resolved":      h_resolved,
        "bind_set":        bind_set,
        "fwd_gw_rts":      fwd_gw_rts,
        "fwd_hop1_ack":    fwd_hop1_ack,
        "fwd_carriers":    fwd_carriers,
        "hops_by_payload": hops_by_payload,
        "transit_started": transit_started,
    }
    return msgs, arrival_by_payload, drops, gw_giveup, gw_layers, second_leg


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


def summarise(msgs, pair_filter, id_to_name, no_gw_by_pair=None):
    no_gw_by_pair = no_gw_by_pair or {}
    by_pair = defaultdict(list)
    for k, r in msgs.items():
        eff_dst = effective_dst(r)
        if pair_filter is not None and (r["origin"], eff_dst) not in pair_filter:
            continue
        by_pair[(r["origin"], eff_dst)].append(r)
    # Drop-only pairs (every send dropped before enqueue) have no records, so
    # they're absent from by_pair -- inject them so the loss is counted.
    all_pairs = set(by_pair) | set(no_gw_by_pair)
    rows = []
    for (origin, dst) in sorted(all_pairs):
        if pair_filter is not None and (origin, dst) not in pair_filter:
            continue
        recs = by_pair.get((origin, dst), [])
        no_gw = no_gw_by_pair.get((origin, dst), 0)
        n = len(recs) + no_gw          # honest denominator: enqueued + dropped
        arrived = sum(1 for r in recs if _arrived(r))
        acked = sum(1 for r in recs if r["ack_ms"] is not None)
        giveup = sum(1 for r in recs if outcome(r) == "giveup")
        in_flight = sum(1 for r in recs if outcome(r) == "in_flight")
        # A pair is cross-layer if any record is via_gateway OR it had drops
        # (drops only come from send_layer, i.e. cross-layer).
        any_cross = any(r.get("via_gateway") for r in recs) or no_gw > 0
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
            "no_gw":      no_gw,
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
              "giveup", "no_gw", "in_flight", "mean_hops"]
    # Auto-size the (variable, long) pair column from the actual names so the
    # numeric columns stay aligned. "*" suffix marks cross-layer rows.
    pairs = [f"{r['origin']} -> {r['dst']}{' *' if r.get('cross_layer') else ''}"
             for r in rows]
    pw = max([len(p) for p in pairs] + [len("pair"), len("TOTAL")])
    fmt = ("{:<%d} {:>4} {:>4} {:>5} {:>5} {:>6} {:>6} {:>5} {:>9} {:>9}" % pw)
    hdr = fmt.format(*header)
    print(hdr)
    print("-" * len(hdr))
    tot = {"sent": 0, "arrived": 0, "acked": 0,
           "giveup": 0, "no_gw": 0, "in_flight": 0}
    for r, pair in zip(rows, pairs):
        arr_pct = f"{100*r['arrived']/r['sent']:.0f}%" if r["sent"] else "-"
        ack_pct = f"{100*r['acked']/r['sent']:.0f}%" if r["sent"] else "-"
        mh = f"{r['mean_hops']:.1f}" if r["mean_hops"] is not None else "-"
        print(fmt.format(pair, r["sent"], r["arrived"], arr_pct,
                         r["acked"], ack_pct, r["giveup"],
                         r.get("no_gw", 0), r["in_flight"], mh))
        for k in tot:
            tot[k] += r.get(k, 0)
    print("-" * len(hdr))
    arr_pct = f"{100*tot['arrived']/tot['sent']:.0f}%" if tot["sent"] else "-"
    ack_pct = f"{100*tot['acked']/tot['sent']:.0f}%" if tot["sent"] else "-"
    print(fmt.format("TOTAL", tot["sent"], tot["arrived"], arr_pct,
                     tot["acked"], ack_pct, tot["giveup"],
                     tot["no_gw"], tot["in_flight"], "-"))
    reasons = defaultdict(int)
    for r in rows:
        for x in r["giveup_reasons"]:
            reasons[x] += 1
    if reasons:
        print()
        print("giveup reasons:")
        for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"  {k:<40} {v}")


def _ev_has(rec, etype, **fields):
    """True if rec's timeline has an event of etype matching the given fields."""
    for e in rec["events"]:
        if e["type"] == etype and all(e["fields"].get(k) == v
                                      for k, v in fields.items()):
            return True
    return False


def _targeted_gateway(rec):
    """True if any carrier RTS'd the gateway directly. For a cross-layer first
    leg the wire `dst` IS the gateway short id, so an rts_* with next==dst means
    the envelope reached a direct neighbour of the gateway and tried to hand off
    — i.e. it got to the gateway's doorstep. (If never true, the envelope never
    reached the gateway's neighbourhood = a routing failure, not availability.)"""
    gw = rec["dst"]
    for e in rec["events"]:
        if e["type"] in ("rts_tx", "rts_retry", "rts_fwd") \
           and e["fields"].get("next") == gw:
            return True
    return False


def _revisited_node(rec):
    """True if some node received this message's DATA more than once — a
    forwarding loop bounced it back to a node that already held it."""
    seen = set()
    for e in rec["events"]:
        if e["type"] == "data_rx":
            n = e["node"]
            if n in seen:
                return True
            seen.add(n)
    return False


def _gateway_present_at(gw_layers, gw_id, layer, t):
    """Was gateway gw_id active on `layer` at time t? Returns True/False, or
    None if unknown (no timeline / t precedes the first recorded transition)."""
    tl = gw_layers.get(gw_id) if gw_layers else None
    if not tl:
        return None
    active = None
    for tt, lyr in tl:            # sorted ascending
        if tt <= t:
            active = lyr
        else:
            break
    return None if active is None else (active == layer)


def _doorstep_away_or_busy(rec, gw_layers, id_to_layer):
    """For a doorstep stall, classify why the gateway didn't pick up. The first
    leg runs on the origin's layer, so the gateway had to be on that layer to
    answer. Check its layer-state at each RTS-to-gateway attempt: if it was on
    another layer at ALL of them -> 'away' (schedule/timing); if present for at
    least one -> 'busy' (congestion/half-duplex/collision). None = unknown."""
    if gw_layers is None or id_to_layer is None:
        return None
    origin_layer = id_to_layer.get(rec["origin"])
    if origin_layer is None:
        return None
    gw = rec["dst"]
    seen_any = present_any = False
    for e in rec["events"]:
        if e["type"] in ("rts_tx", "rts_retry", "rts_fwd") \
           and e["fields"].get("next") == gw:
            p = _gateway_present_at(gw_layers, gw, origin_layer, e["t_ms"])
            if p is None:
                continue
            seen_any = True
            present_any = present_any or p
    if not seen_any:
        return None
    return "busy" if present_any else "away"


def classify_second_leg(rec, sl, gw_home=None, gw_visit=None, id_to_layer=None):
    """Sub-classify a cross-layer message that REACHED the gateway but whose
    target never got it — i.e. where did the gateway's forward (second leg) die?

      no route to target  — forward was enqueued but the gateway NEVER RTS'd it
                            (it had no route on the target layer → awaiting RREP)
      first-hop stalled    — gateway RTS'd but never got its hop-1 ACK
      lost downstream      — gateway GOT its hop-1 ACK (handed off), but the msg
                            died >=2 hops out among the target layer's own relays
      forward not enqueued — gateway never even queued a forward (binding
                            unresolved); drilled via h_resolved / bind_set.

    Returns (label, location) where location is HOME/VISIT/"?" — the target's
    layer relative to the gateway (gateways are part-time on every layer they
    serve, so this says which presence regime the failure sits in).
    """
    origin = rec["origin"]
    payload = rec.get("payload")
    gw = rec["dst"]                      # cross-layer wire dst == gateway id
    khash = rec.get("dst_key_hash32")
    flist = sl["handoff_enq"].get((origin, payload), [])

    loc = "?"
    target = rec.get("target_id")
    tl = id_to_layer.get(target) if (id_to_layer and target is not None) else None
    if tl is not None and gw_home is not None:
        if tl == gw_home.get(gw):
            loc = "HOME"
        elif tl in (gw_visit.get(gw) or []):
            loc = "VISIT"

    if flist:
        gw_rts = any((g, ctr, tgt) in sl["fwd_gw_rts"] for (g, ctr, tgt) in flist)
        hop1 = any((g, ctr, payload) in sl["fwd_hop1_ack"] for (g, ctr, _t) in flist)
        if not gw_rts:
            label = "XL 2nd-leg: no route to target (gw never RTS'd forward)"
        elif not hop1:
            label = "XL 2nd-leg: first-hop stalled (gw RTS'd, no hop-1 ACK)"
        else:
            label = "XL 2nd-leg: lost downstream (handed off, lost >=2 hops out)"
    else:
        answered = (gw, khash) in sl["h_resolved"]
        learned = (gw, khash) in sl["bind_set"]
        if answered and not learned:
            label = "XL 2nd-leg: resolve reply missed gw (resolver answered, gw never learned)"
        elif answered and learned:
            label = "XL 2nd-leg: resolve learned late (binding arrived, no forward)"
        else:
            label = "XL 2nd-leg: forward never enqueued (binding unresolved)"
    return label, loc


def failure_category(rec, gw_giveup, gw_layers=None, id_to_layer=None):
    """Routing-layer failure taxonomy for a DM that did NOT arrive. Distinguishes
    route non-convergence (no route at all) from next-hop-silent (route exists,
    next-hop won't answer) from the cross-layer second leg. NB: giveup_reason
    `defer_ttl` alone is ambiguous (same-layer no-route vs gateway handoff), so
    we classify by carriers + timeline events + the gateway-giveup set."""
    car = len(rec["carriers"])
    if rec.get("via_gateway"):
        if (rec["origin"], rec.get("dst_key_hash32")) in gw_giveup:
            return "XL: gateway gave up (resolve/route to target)"
        if rec["arrived_ms"] is not None:
            # Sub-classified into the second-leg mechanism by classify_second_leg
            # (set on the record in main); fall back to the flat label if absent.
            return rec.get("second_leg") or "XL: reached gateway, lost after forward"
        if car == 0 and _ev_has(rec, "send_deferred", reason="no_route"):
            return "XL: origin had no route to gateway"
        if car >= 1:
            # First-leg stall sub-taxonomy (the dominant cross-layer bucket).
            # Did the envelope reach the gateway's doorstep, or never get there?
            if _targeted_gateway(rec):
                aob = _doorstep_away_or_busy(rec, gw_layers, id_to_layer)
                if aob == "away":
                    return "XL stall: doorstep, gateway AWAY on other layer (schedule/timing)"
                if aob == "busy":
                    return "XL stall: doorstep, gateway PRESENT but no pickup (busy/collision)"
                return "XL stall: AT gateway doorstep, no pickup (gateway away/busy)"
            if _revisited_node(rec):
                return "XL stall: routing LOOP, never reached gateway"
            return "XL stall: cascade/dead-end, never reached gateway"
        return "XL: other"
    if outcome(rec) == "in_flight":
        return "SL: in-flight at end"
    if car == 0 and _ev_has(rec, "send_deferred", reason="no_route"):
        return "SL: origin no route (requery failed)"
    if _ev_has(rec, "send_deferred", reason="all_candidates_silent"):
        return "SL: next-hop silent (cts/ack timeout)"
    return f"SL: giveup ({rec.get('giveup_reason')})"


def render_dm_failures(msgs, no_gw_by_pair, gw_giveup, pair_filter, id_to_name,
                       gw_layers=None, id_to_layer=None):
    cat = Counter()
    sl_loc = Counter()        # HOME/VISIT split of the second-leg failures
    ok = 0
    for r in msgs.values():
        if pair_filter is not None and (r["origin"], effective_dst(r)) not in pair_filter:
            continue
        if _arrived(r):
            ok += 1
        else:
            cat[failure_category(r, gw_giveup, gw_layers, id_to_layer)] += 1
            if r.get("second_leg") and r.get("second_leg_loc"):
                sl_loc[r["second_leg_loc"]] += 1
    for (origin, dst), n in no_gw_by_pair.items():
        if pair_filter is not None and (origin, dst) not in pair_filter:
            continue
        cat["XL: no gateway known (never enveloped)"] += n
    fail = sum(cat.values())
    tot = ok + fail
    if tot == 0:
        print("(no matching DM messages)")
        return
    print(f"delivered {ok}/{tot} = {100*ok/tot:.1f}%;  {fail} failed, by mechanism:")
    for k, v in cat.most_common():
        print(f"  {v:>4} ({100*v/fail:4.1f}% of fails)  {k}")
    if sl_loc:
        tot_sl = sum(sl_loc.values())
        loc_str = ", ".join(f"{k} {v}" for k, v in sl_loc.most_common())
        print(f"  (2nd-leg target location, {tot_sl} fails: {loc_str})")


def _fmt_reasons(counter, top=4):
    """Compact 'reason (n)' list, most common first."""
    if not counter:
        return ""
    return "  ".join(f"{k} ({v})" for k, v in counter.most_common(top))


def render_xl_funnel(msgs, no_gw_by_pair, gw_giveup, second_leg,
                     pair_filter, id_to_name, gw_layers=None, id_to_layer=None):
    """Cross-layer stage funnel — WHERE in the pipeline do XL messages leak?

    Stages (see docs/DELIVERY_ANALYSIS.md 'Cross-layer delivery pipeline'):
      S0 enqueued        — originator built + queued the gateway envelope
      S1 reached gateway — first leg delivered the envelope to the egress gw
                           (data_rx at the wire dst == the gateway)
      S2 transited       — (chained suburb<->suburb only) the egress gw's
                           re-wrapped forward reached a SECOND gateway
      S3 final-leg queued— a gateway resolved the target + queued the forward
      S4 delivered       — the target decoded the DATA

    The headline rows count 'furthest stage reached'; the 'lost' column is the
    drop entering that stage, and the reasons come from failure_category — whose
    Stage-1 labels already split window-miss (gw AWAY on another layer) vs
    in-window (gw PRESENT -> stale-route loop / contention)."""
    handoff_enq = second_leg["handoff_enq"]
    hops_by_payload = second_leg["hops_by_payload"]
    transit_started = second_leg["transit_started"]

    recs = []
    for r in msgs.values():
        if not r.get("via_gateway"):
            continue
        if pair_filter is not None and (r["origin"], effective_dst(r)) not in pair_filter:
            continue
        recs.append(r)
    dropped = 0
    for (origin, dst), n in no_gw_by_pair.items():
        if pair_filter is not None and (origin, dst) not in pair_filter:
            continue
        dropped += n

    def path_len(r):
        hp = hops_by_payload.get(r.get("payload"))
        return len([x for x in str(hp).split(",") if x != ""]) if hp else 1

    def furthest(r):
        if _arrived(r):
            return 4
        origin, payload = r["origin"], r.get("payload")
        if handoff_enq.get((origin, payload)):
            return 3
        if r["arrived_ms"] is not None:
            if (path_len(r) >= 2
                    and (origin, r.get("dst_key_hash32")) in transit_started):
                return 2     # reached egress gw + transit fired, 2nd gw never handed off
            return 1         # reached egress gw, no transit / no handoff
        return 0             # never reached the egress gw

    enq = len(recs)
    if enq + dropped == 0:
        print("(no cross-layer messages in scope)")
        return
    nstage = Counter()
    loss_first = Counter()   # furthest == 0 (died on first leg)
    loss_gw = Counter()      # furthest in {1,2} (reached gw, died at transit/resolve)
    loss_final = Counter()   # furthest == 3 (final-leg forward queued, never arrived)
    n_two = two_reached_gw1 = two_transited = two_delivered = 0
    for r in recs:
        s = furthest(r)
        nstage[s] += 1
        cat = failure_category(r, gw_giveup, gw_layers, id_to_layer) if s < 4 else None
        if s == 0:
            loss_first[cat] += 1
        elif s in (1, 2):
            loss_gw[cat] += 1
        elif s == 3:
            loss_final[cat] += 1
        if path_len(r) >= 2:
            n_two += 1
            if r["arrived_ms"] is not None:
                two_reached_gw1 += 1
            hk = handoff_enq.get((r["origin"], r.get("payload")), [])
            if _arrived(r) or any(g != r["dst"] for (g, _c, _t) in hk):
                two_transited += 1
            if _arrived(r):
                two_delivered += 1

    r1 = sum(nstage[j] for j in range(1, 5))   # reached egress gw
    r3 = sum(nstage[j] for j in range(3, 5))   # final-leg queued
    r4 = nstage[4]                             # delivered
    total = enq + dropped
    print(f"cross-layer messages: {total}   ({dropped} dropped at enqueue: no gateway route)")
    print(f"{'stage':<30}{'reached':>8}{'lost':>6}   why it was lost entering this stage")
    print("-" * 92)
    print(f"{'S0 enqueued (envelope built)':<30}{enq:>8}{dropped:>6}   "
          f"{'(pre-enqueue: no gateway route)' if dropped else ''}")
    print(f"{'S1 reached egress gateway':<30}{r1:>8}{enq - r1:>6}   {_fmt_reasons(loss_first)}")
    print(f"{'S3 final-leg queued by a gw':<30}{r3:>8}{r1 - r3:>6}   {_fmt_reasons(loss_gw)}")
    print(f"{'S4 delivered':<30}{r4:>8}{r3 - r4:>6}   {_fmt_reasons(loss_final)}")
    if n_two:
        print(f"  chained suburb<->suburb (2-gw): {n_two} sent · "
              f"{two_reached_gw1} reached gw1 · {two_transited} transited to gw2 · "
              f"{two_delivered} delivered")


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
            ftype = frame_type_for(ev)
            print(f"  {ev['t_ms']:>8} ms  [{ftype:>3}] {node_n:<12} "
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
                if r.get("second_leg"):
                    entry["second_leg"]         = r["second_leg"]
                    entry["second_leg_loc"]     = r.get("second_leg_loc")
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


def analyse_channel(events_path, slot_to_id, posts, name_to_id):
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

    # Pass 3: per-node "dirty window" for each msg — between first
    # observation (self_originate or channel_msg_received) and the
    # corresponding channel_dirty_cleared (or run end). Any BCN tx
    # by that node within that window is a CANDIDATE carrier of the
    # msg's digest (the digest TLV holds up to K=3 dirty ids; a BCN
    # may carry zero or one of any given dirty id depending on the
    # rotation, so this is a heuristic, not proof).
    by_msg_id = {p["msg_id"]: p for p in posts if p["msg_id"] is not None}
    node_dirty = defaultdict(dict)   # fid -> msg_id -> [start, end]
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        mid = d.get("id")
        if mid not in by_msg_id:
            continue
        if et == "channel_msg_received":
            # First observation marks the start; subsequent
            # already_present events don't reset it.
            if mid not in node_dirty[fid]:
                node_dirty[fid][mid] = [t_ms, None]
        elif et == "channel_dirty_cleared":
            window = node_dirty[fid].get(mid)
            if window is not None and window[1] is None:
                window[1] = t_ms

    # Pass 4: physical-layer events for M-broadcasts + BCN ads.
    # - DATA-M tx (or tx_deferred) parses `id=0xHEX` from the M-payload
    #   tag inside `info`/`tx_info`; matches to msg_id directly.
    # - BCN tx events are attributed to all msgs whose dirty window
    #   contains this BCN tx's time at this node.
    # - rx / drop events are matched by `pkt` hash to a known tx.
    id_hex_re = re.compile(r"id=0x([0-9a-fA-F]+)")
    pkt_to_posts = {}    # pkt_hash -> {posts...} (BCN can carry multi)
    pkt_kind = {}        # pkt_hash -> "bcn" | "data_m"

    def _phy_data_extract(rec):
        """Extract msg id from the event's info string.

        `tx` events use field `info`; `tx_deferred` uses `tx_info`.
        Both formats embed `id=0xHEX` in the M-broadcast payload.
        """
        info = rec.get("info") or rec.get("tx_info") or ""
        m = id_hex_re.search(info)
        if m:
            return int(m.group(1), 16)
        return None

    # Need a name -> firmware id resolver for BCN attribution (phy
    # events carry node name strings). Build from posts: sender_id +
    # whatever is in id_bind in the events stream — but simpler to
    # rebuild from cfg passed via posts (each post knows its sender_id
    # but not the name->id map). The caller already has name_to_id;
    # we re-derive it inside this function from the unique sender_id
    # values + the events stream's own name<->slot inference is too
    # noisy. So instead, derive name->id from the script_emit pass:
    # tx_enqueue events have data.origin (firmware id) and the event's
    # `node` is the slot (we don't have the name there either).
    # Cleanest: peek at any phy event with `node` (string) and look up
    # its firmware id from a `tx_enqueue` script_emit at the same
    # event index — but that's heavy. Pragmatic shortcut: build name
    # -> id by reading phy `tx` events' `node` and matching to script
    # `tx_enqueue` events at the same t_ms.
    # For now, scan one extra pass over phy events to collect name set,
    # then look them up against the caller-provided id mapping below.
    # We accept the cost: walk phy events once to gather names, then
    # delegate name resolution to main() via a post-hook. Simplest:
    # store the raw phy events on the post and resolve later. Done in
    # render_channel_detail via name_to_id_local.

    for t_ms, phy_t, e in walk_phy_events(events_path, None):
        label = e.get("label")
        # --- DATA-M (channel broadcast) tx side ---
        if phy_t in ("tx", "tx_deferred") and label == "DATA-M":
            mid = _phy_data_extract(e)
            if mid is None:
                continue
            p = by_msg_id.get(mid)
            if p is None:
                continue
            p["events"].append({
                "t_ms": t_ms,
                "node_name": e.get("node"),
                "type": f"phy_{phy_t}",
                "fields": {
                    "label": label,
                    "sf": e.get("sf"),
                    "reason": e.get("reason"),
                    "busy_until_ms": e.get("busy_until_ms"),
                    "airtime_ms": e.get("airtime_ms"),
                    "pkt": e.get("pkt"),
                },
            })
            if phy_t == "tx" and e.get("pkt"):
                pkt_to_posts.setdefault(e["pkt"], set()).add(id(p))
                pkt_kind[e["pkt"]] = "data_m"
        # --- BCN tx side: attribute to every post whose dirty window
        #     at this node contains this t_ms ---
        elif phy_t == "tx" and label == "BCN":
            tx_name = e.get("node")
            tx_fid = name_to_id.get(tx_name) if tx_name else None
            if tx_fid is None:
                continue
            relevant_posts = []
            for mid, window in node_dirty.get(tx_fid, {}).items():
                start, end = window[0], window[1]
                if start is None:
                    continue
                if start <= t_ms and (end is None or t_ms <= end):
                    relevant_posts.append(by_msg_id[mid])
            if not relevant_posts:
                continue
            pkt = e.get("pkt")
            for p in relevant_posts:
                p["events"].append({
                    "t_ms": t_ms,
                    "node_name": tx_name,
                    "type": "phy_bcn_tx",
                    "fields": {
                        "label": "BCN",
                        "sf": e.get("sf"),
                        "airtime_ms": e.get("airtime_ms"),
                        "pkt": pkt,
                        # Mark heuristic: this BCN's dirty digest MAY
                        # have carried the msg id; we can't tell from
                        # the wire dump alone.
                        "in_dirty_window": True,
                    },
                })
                if pkt:
                    pkt_to_posts.setdefault(pkt, set()).add(id(p))
                    pkt_kind[pkt] = "bcn"
        # --- RX / drop side: match by pkt against either DATA-M or
        #     BCN known transmissions ---
        elif phy_t in ("rx", "collision", "drop_halfduplex",
                       "drop_sf_mismatch", "drop_preamble_miss", "drop_rx_blind"):
            pkt = e.get("pkt")
            post_ids = pkt_to_posts.get(pkt)
            if not post_ids:
                continue
            kind = pkt_kind.get(pkt, "?")
            # Reverse lookup id(p) -> p so we can iterate.
            id_to_post_obj = {id(p): p for p in posts}
            for pid in post_ids:
                p = id_to_post_obj.get(pid)
                if p is None:
                    continue
                p["events"].append({
                    "t_ms": t_ms,
                    "node_name": e.get("to") or e.get("node"),
                    "type": f"phy_{phy_t}_{kind}",
                    "fields": {
                        "from": e.get("from"),
                        "snr": e.get("snr"),
                        "rssi": e.get("rssi"),
                        "sf": e.get("sf"),
                        "pkt": pkt,
                    },
                })

    # Per-post derived stats.
    for p in posts:
        # Sort events; mix firmware-id and name-keyed events using
        # t_ms then a stable string.
        def sort_key(x):
            return (x["t_ms"], str(x.get("node", x.get("node_name", ""))))
        p["events"].sort(key=sort_key)
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
        # Need a name->id helper for PHY events (which carry name strings).
        # Build it lazily from id_to_name's reverse.
        name_to_id_local = {v: k for k, v in id_to_name.items()}
        for ev in p["events"]:
            if "node" in ev:
                node_n = fmt_node(ev["node"], id_to_name)
            else:
                nm = ev.get("node_name")
                node_n = fmt_node(name_to_id_local.get(nm), id_to_name) \
                         if nm in name_to_id_local else (nm or "?")
            rendered = []
            for kk, vv in ev["fields"].items():
                if vv is None:
                    continue
                if kk in NODE_ID_FIELDS and isinstance(vv, int):
                    rendered.append(f"{kk}={fmt_node(vv, id_to_name)}")
                elif kk == "from" and isinstance(vv, str):
                    # PHY rx events carry `from` as a name string.
                    fid = name_to_id_local.get(vv)
                    rendered.append(f"{kk}={fmt_node(fid, id_to_name)}"
                                     if fid is not None else f"{kk}={vv}")
                else:
                    rendered.append(f"{kk}={vv}")
            field_str = " ".join(rendered)
            ftype = frame_type_for(ev)
            print(f"  {ev['t_ms']:>8} ms  [{ftype:>3}] {node_n:<12} "
                  f"{ev['type']:<40} {field_str}")
        print()


# Fields shown (when present) on each --trace line, in order. node-id fields are
# rendered name(id). Covers the same-layer path AND the cross-layer gateway chain.
_TRACE_FIELDS = ("origin", "dst", "next", "via_gateway", "gateway", "next_gateway",
                 "target_layer_id", "hops", "remaining_hops", "entered_layer",
                 "next_layer", "dst_key_hash32", "ctr", "ctr_lo", "attempt_seq", "reason")
_TRACE_NODE_FIELDS = {"origin", "dst", "next", "via_gateway", "gateway", "next_gateway"}


def render_trace(events_path, substr, slot_to_id, id_to_name):
    """Follow a message (or messages) end-to-end through every event that touches
    it, including the cross-layer gateway chain (transit / handoff / no_binding /
    H-query / remote-bind) that the per-message --detail timeline omits.

    Selection: any script_emit whose data has a string field containing SUBSTR
    (case-insensitive) -- this catches the origin send + the delivery (both carry
    the payload). We then also follow each `dst_key_hash32` seen on a matching
    event, so the gateway-side events (which carry the hash, not the text) come
    along. Output is one chronological line per event."""
    sub = substr.lower()

    def nm(nid):
        n = id_to_name.get(nid)
        return f"{n}({nid})" if n is not None else str(nid)

    def matches(d):
        for v in d.values():
            if isinstance(v, str) and sub in v.lower():
                return True
        return False

    hashes = set()
    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") == "script_emit" and matches(e.get("data", {})):
                h = e["data"].get("dst_key_hash32")
                if isinstance(h, int):
                    hashes.add(h)

    rows = []
    with open(events_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "script_emit":
                continue
            d = e.get("data", {})
            if matches(d) or (isinstance(d.get("dst_key_hash32"), int)
                              and d["dst_key_hash32"] in hashes):
                rows.append(e)
    rows.sort(key=lambda e: e.get("time_ms", 0))

    print(f"TRACE '{substr}': {len(rows)} events; following hashes {sorted(hashes)}")

    def _node(e):
        idx = e.get("node")
        return nm(slot_to_id.get(idx, idx)) if isinstance(idx, int) else str(idx)
    node_w = max([len(_node(e)) for e in rows] + [4])   # auto-size for long names
    for e in rows:
        d = e.get("data", {})
        parts = []
        for k in _TRACE_FIELDS:
            if k in d:
                v = d[k]
                if k in _TRACE_NODE_FIELDS and isinstance(v, int):
                    v = nm(v)
                parts.append(f"{k}={v}")
        pl = d.get("payload")
        if isinstance(pl, str):
            parts.append(f"pl={pl[:20]}")
        print(f"  t={e.get('time_ms', 0):>8}  {_node(e):{node_w}s} "
              f"{e['emit_type']:30s} {' '.join(parts)}")


def analyse_copies(events_path, slot_to_id):
    """Count COPY-CREATING SWITCHES.

    A copy-creating switch is a forward that abandoned a next-hop which had
    ALREADY decoded the frame (emitted data_rx for that origin,ctr) and switched
    to a DIFFERENT node -> a 2nd live copy of a frame the abandoned hop already
    holds (and will forward). The four switch events that move a flight to a
    fresh next-hop are: path_cascade, tx_blind_alt, tx_silent_alt,
    tx_stale_next_alt. A switch whose abandoned hop never decoded is a legit
    reroute, NOT a copy.

    Also tallies per-message fan-out = distinct nodes that decoded each
    (origin,ctr) — copies inflate this above the delivering path length.

    Returns (decoders, payloads, switches, copies, reroutes):
      decoders[(origin,ctr)] = {node_id: earliest_data_rx_ms}
      payloads[(origin,ctr)] = a payload sample (str) for display
      switches / copies      = [(t, origin, ctr, from_next, to_next, label, payload)]
      reroutes               = int
    """
    SWITCH = {"path_cascade", "tx_blind_alt", "tx_silent_alt", "tx_stale_next_alt"}
    LABEL = {"tx_blind_alt": "blind_alt", "tx_silent_alt": "silent_alt",
             "tx_stale_next_alt": "stale_next"}
    decoders = defaultdict(dict)
    payloads = {}
    switches = []
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        if et == "data_rx":
            key = (d.get("origin"), d.get("ctr"))
            if key[0] is None or key[1] is None:
                continue
            prev = decoders[key].get(fid)
            if prev is None or t_ms < prev:
                decoders[key][fid] = t_ms
            if key not in payloads and isinstance(d.get("payload"), str):
                payloads[key] = d["payload"]
        elif et in SWITCH:
            label = d.get("trigger") if et == "path_cascade" else LABEL[et]
            switches.append((t_ms, d.get("origin"), d.get("ctr"),
                             d.get("from_next"), d.get("to_next"),
                             label or et, d.get("payload")))
    copies, reroutes = [], 0
    for sw in switches:
        t, o, c, frm = sw[0], sw[1], sw[2], sw[3]
        rx = decoders.get((o, c), {})
        if frm in rx and rx[frm] <= t:   # abandoned hop decoded BEFORE the switch
            copies.append(sw)
        else:
            reroutes += 1
    return decoders, payloads, switches, copies, reroutes


def render_copies(events_path, slot_to_id, id_to_name, top=12):
    def nm(nid):
        n = id_to_name.get(nid)
        return f"{n}({nid})" if n is not None else str(nid)

    decoders, payloads, switches, copies, reroutes = analyse_copies(
        events_path, slot_to_id)
    by_label = Counter(sw[5] for sw in copies)

    print("=== Copies (copy-creating switches) ===")
    print("A copy-creating switch abandons a next-hop that had ALREADY decoded")
    print("the frame (data_rx for that origin,ctr) and forwards to a DIFFERENT")
    print("node -> a 2nd live copy. Switch events: path_cascade / tx_blind_alt /")
    print("tx_silent_alt / tx_stale_next_alt.\n")
    print(f"copy-creating switches : {len(copies)}")
    for label, n in sorted(by_label.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"    {label:<16} {n}")
    print(f"reroute switches (abandoned hop never decoded — not a copy) : {reroutes}")
    print(f"total switches         : {len(switches)}")

    fan = sorted(((k, len(v)) for k, v in decoders.items()), key=lambda kv: -kv[1])
    if fan:
        mean = sum(n for _, n in fan) / len(fan)
        print(f"\nfan-out (distinct decoders per origin,ctr): {len(fan)} messages, "
              f"mean {mean:.1f} decoders/msg")
        print(f"    {'(origin,ctr)':>14}  {'decoders':>8}  payload")
        for (o, c), n in fan[:top]:
            pl = payloads.get((o, c), "")
            print(f"    {str((o, c)):>14}  {n:>8}  {str(pl)[:28]}")

    if copies:
        det = sorted(copies)[:top]
        w = max([len(nm(s[3])) for s in det] + [len(nm(s[4])) for s in det]
                + [len("abandoned"), len("to")])   # auto-size for long names
        print(f"\n  copy detail (first {len(det)} of {len(copies)}):")
        print(f"    {'t_ms':>8}  {'abandoned':>{w}} -> {'to':<{w}} {'trigger':<12} payload")
        for (t, o, c, frm, to, label, pl) in det:
            print(f"    {t:>8}  {nm(frm):>{w}} -> {nm(to):<{w}} {label:<12} {str(pl)[:24]}")


def analyse_airtime(events_path, slot_to_id):
    """Per-message airtime (ms), computed from the *_tx script_emits + the LoRa
    formula, split by category/SF: RTS+CTS (routing SF), DATA (data SF), ACK/NACK
    (routing SF). RTS/DATA/ACK/NACK carry (origin,ctr); CTS carries only
    (to,ctr_lo), so it's attributed to the most recent RTS from `to`. bw_hz/cr are
    read from a PHY tx event (uniform across a run)."""
    bw_hz, cr = 125000, 5
    with open(events_path) as f:
        for line in f:
            if '"type":"tx"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") == "tx":
                bw_hz = e.get("bw_hz", bw_hz)
                cr = e.get("cr", cr)
                break

    msgs = {}

    def m(o, c):
        k = (o, c)
        if k not in msgs:
            msgs[k] = {"dst": None, "rsf": None, "rts_air": 0, "cts_air": 0,
                       "data_air": 0, "ack_air": 0}
        return msgs[k]

    recent_rts = {}   # (rts_sender_id, ctr_lo) -> (origin, ctr)
    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        if et == "rts_tx" or et == "rts_retry":
            o, c = d.get("origin"), d.get("ctr")
            if o is None or c is None:
                continue
            rsf = d.get("tx_routing_sf") or 8
            r = m(o, c)
            r["dst"] = r["dst"] if r["dst"] is not None else d.get("dst")
            r["rsf"] = r["rsf"] or rsf
            r["rts_air"] += lora_airtime_ms(rsf, bw_hz, cr, RTS_LEN)
            recent_rts[(fid, d.get("ctr_lo"))] = (o, c)
        elif et == "cts_tx":
            k = recent_rts.get((d.get("to"), d.get("ctr_lo")))
            if k is None:
                continue
            r = m(*k)
            r["cts_air"] += lora_airtime_ms(r["rsf"] or 8, bw_hz, cr, CTS_LEN)
        elif et == "data_tx":
            o, c = d.get("origin"), d.get("ctr")
            if o is None or c is None:
                continue
            dsf = d.get("data_sf") or d.get("sf") or 7
            nbytes = DATA_HDR_LEN + len(str(d.get("payload", ""))) + MAC_LEN
            r = m(o, c)
            r["dst"] = r["dst"] if r["dst"] is not None else d.get("dst")
            r["data_air"] += lora_airtime_ms(dsf, bw_hz, cr, nbytes)
        elif et == "ack_tx" or et == "nack_tx":
            o, c = d.get("origin"), d.get("ctr")
            if o is None or c is None:
                continue
            r = m(o, c)
            r["ack_air"] += lora_airtime_ms(r["rsf"] or 8, bw_hz, cr,
                                            ACK_LEN if et == "ack_tx" else NACK_LEN)
    return msgs, bw_hz, cr


def render_airtime(events_path, slot_to_id, id_to_name, top=20):
    def nm(nid):
        n = id_to_name.get(nid)
        return f"{n}({nid})" if n is not None else str(nid)

    msgs, bw_hz, cr = analyse_airtime(events_path, slot_to_id)
    rows = []
    for (o, c), r in msgs.items():
        rtscts = r["rts_air"] + r["cts_air"]
        rows.append((rtscts + r["data_air"] + r["ack_air"], o, c, r, rtscts))
    rows.sort(reverse=True)
    s_rc = sum(r["rts_air"] + r["cts_air"] for _, _, _, r, _ in rows)
    s_d = sum(r["data_air"] for _, _, _, r, _ in rows)
    s_a = sum(r["ack_air"] for _, _, _, r, _ in rows)
    s_t = s_rc + s_d + s_a
    n = len(rows) or 1
    disp = rows[:top]
    labels = [f"{nm(o)} -> {nm(r['dst'])} ({c})" for _, o, c, r, _ in disp]
    w = max([len(x) for x in labels] + [len("origin -> dst (ctr)"),
                                        len("TOTAL (%d msgs)" % len(rows))])
    print("=== Airtime per message (ms; *_tx events + LoRa formula) ===")
    print(f"bw={bw_hz}Hz cr=4/{cr} preamble={PREAMBLE_SYM}. RTS/CTS/ACK on routing SF, "
          f"DATA on data SF.\n")
    print(f"  {'origin -> dst (ctr)':{w}} {'rsf':>3} {'RTS+CTS':>8} {'DATA':>7} "
          f"{'ACK':>6} {'TOTAL':>7}")
    for (tot, o, c, r, rtscts), lbl in zip(disp, labels):
        print(f"  {lbl:{w}} {str(r['rsf'] or '?'):>3} {rtscts:>8} "
              f"{r['data_air']:>7} {r['ack_air']:>6} {tot:>7}")
    print(f"  {'-' * (w + 35)}")
    print(f"  {('TOTAL (%d msgs)' % len(rows)):{w}} {'':>3} {s_rc:>8} {s_d:>7} "
          f"{s_a:>6} {s_t:>7}")
    print(f"  {'mean / msg':{w}} {'':>3} {s_rc // n:>8} {s_d // n:>7} "
          f"{s_a // n:>6} {s_t // n:>7}")
    print(f"\n  split: RTS+CTS {100 * s_rc // max(s_t, 1)}%  "
          f"DATA {100 * s_d // max(s_t, 1)}%  ACK {100 * s_a // max(s_t, 1)}%")


def _haversine_km(lat1, lon1, lat2, lon2):
    """Great-circle distance in km."""
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def analyse_tail(events_path, slot_to_id):
    """Per-message routing-stress metrics for the airtime tail. Keyed by
    (origin, dst, ctr) — the same key the breakdown's per-pair table uses (ctr
    is per-(origin,dst) in this firmware). Counts: rts_tx + rts_retry at origin
    + intermediates, data_tx + distinct data-TX nodes (= chain length),
    tx_blind_alt + path_cascade (copy creation), ack_tx, delivered.
    Use with render_tail to read against geographic distance."""
    msgs = {}

    def m(o, dst, c):
        k = (o, dst, c)
        if k not in msgs:
            msgs[k] = {
                "rts_tx": 0, "rts_retry": 0,
                "data_tx": 0, "data_tx_nodes": set(),
                "ack_tx": 0,
                "blind_alt": 0, "path_cascade": 0,
                "delivered": False,
                "first_t": None, "last_t": None,
            }
        return msgs[k]

    for t_ms, fid, et, d in walk_events(events_path, slot_to_id):
        o, c, dst = d.get("origin"), d.get("ctr"), d.get("dst")
        if o is None or c is None or dst is None:
            continue
        r = m(o, dst, c)
        if r["first_t"] is None:
            r["first_t"] = t_ms
        r["last_t"] = t_ms
        if et == "rts_tx":
            r["rts_tx"] += 1
        elif et == "rts_retry":
            r["rts_retry"] += 1
        elif et == "data_tx":
            r["data_tx"] += 1
            r["data_tx_nodes"].add(fid)
        elif et == "ack_tx":
            r["ack_tx"] += 1
        elif et == "delivered":
            r["delivered"] = True
        elif et == "tx_blind_alt":
            r["blind_alt"] += 1
        elif et == "path_cascade":
            r["path_cascade"] += 1
    return msgs


def render_tail(events_path, slot_to_id, id_to_name, id_to_ll, top=10,
                link_km=2.0):
    """Airtime-tail profile: top N messages by total airtime, with hop counts
    + retry/copy stress + geographic distance. The `min_h` column is the
    minimum plausible hop count (= ceil(km / link_km), where link_km is the
    expected single-hop range; default 2 km is a reasonable urban SF8 figure).
    Compare `chain` (distinct DATA forwarders, = actual hop count) to `min_h`
    to see if a route is geographically inflated. `data_tx` ≥ `chain` if any
    forwarder retransmitted; `retr` = rts_retry events anywhere along the
    chain (origin retries + intermediate retries). `D` = delivered flag."""
    def nm(nid):
        n = id_to_name.get(nid)
        return f"{n}({nid})" if n is not None else str(nid)

    # Reuse analyse_airtime for airtime totals (its key is (origin, ctr) — but
    # (origin, dst, ctr) uniquely refines it since ctr is per-(origin,dst)).
    air_msgs, _, _ = analyse_airtime(events_path, slot_to_id)
    tail_msgs = analyse_tail(events_path, slot_to_id)

    # Cross-reference: for each (o, c) in air_msgs, the dst is in air_msgs[k]["dst"]
    rows = []
    for (o, c), ar in air_msgs.items():
        dst = ar["dst"]
        if dst is None:
            continue
        total_air = ar["rts_air"] + ar["cts_air"] + ar["data_air"] + ar["ack_air"]
        tail = tail_msgs.get((o, dst, c), {})
        rows.append((total_air, o, dst, c, ar, tail))
    rows.sort(reverse=True)

    print("=== Airtime-tail profile (top {} by airtime) ===".format(top))
    print("min_h = ceil(km / {:.1f}); chain = distinct DATA forwarders "
          "(= actual hops); retr = rts_retry events; blind/casc = copy-creating "
          "switches; D = delivered.\n".format(link_km))
    labels = [f"{nm(o)} -> {nm(dst)} ({c})" for _, o, dst, c, _, _ in rows[:top]]
    w = max([len(x) for x in labels] + [len("origin -> dst (ctr)")])
    hdr = (f"  {'origin -> dst (ctr)':{w}} {'km':>5} {'min_h':>5} {'chain':>5} "
           f"{'data_tx':>7} {'retr':>4} {'blind':>5} {'casc':>4} "
           f"{'air_ms':>7} {'D':>2}")
    print(hdr)
    for (total_air, o, dst, c, _, tail), lbl in zip(rows[:top], labels):
        if not tail:
            continue
        ll_o = id_to_ll.get(o)
        ll_d = id_to_ll.get(dst)
        km = (_haversine_km(*ll_o, *ll_d) if ll_o and ll_d else 0.0)
        min_h = max(1, math.ceil(km / link_km))
        chain = len(tail["data_tx_nodes"])
        d_flag = "Y" if tail["delivered"] else "n"
        print(f"  {lbl:{w}} {km:>5.1f} {min_h:>5d} {chain:>5d} "
              f"{tail['data_tx']:>7d} {tail['rts_retry']:>4d} "
              f"{tail['blind_alt']:>5d} {tail['path_cascade']:>4d} "
              f"{total_air:>7d} {d_flag:>2}")

    # Summary stats over the top-N: airtime share + retry tax.
    top_rows = [(tot, o, dst, c, tail) for tot, o, dst, c, _, tail in rows[:top]
                if tail]
    tail_air = sum(t for t, *_ in top_rows)
    tail_retr = sum(r[4]["rts_retry"] for r in top_rows)
    tail_chain = sum(len(r[4]["data_tx_nodes"]) for r in top_rows)
    total_air = sum(r[0] for r in rows)
    total_retr = sum(t.get("rts_retry", 0) for t in tail_msgs.values())
    print()
    print(f"  top-{top} share of total airtime: {100 * tail_air / max(total_air, 1):.1f}%  "
          f"({tail_air} / {total_air} ms)")
    print(f"  top-{top} retries / total retries: {tail_retr} / {total_retr}  "
          f"(mean {tail_retr / max(len(top_rows), 1):.1f}/msg)")
    if tail_chain:
        # Tail airtime per hop is the simplest "is each hop expensive?" probe.
        print(f"  top-{top} airtime per chain-hop: {tail_air // tail_chain} ms  "
              f"(nominal single-hop RTS+CTS+DATA+ACK ≈ 500–700 ms at SF8)")


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
    p.add_argument("--failures", action="store_true",
                   help="DM mode: print failure breakdown by routing-layer "
                        "mechanism, incl. cross-layer second-leg sub-classes "
                        "(no-route-to-target / first-hop-stalled / lost-downstream "
                        "/ resolve-bound) + a HOME/VISIT target-location tally")
    p.add_argument("--post", default=None,
                   help="filter channel posts: payload substring "
                        "(case-insensitive), e.g. 'news-3'")
    p.add_argument("--trace", default=None, metavar="SUBSTR",
                   help="follow message(s) end-to-end: dump every event whose "
                        "payload contains SUBSTR (case-insensitive), plus the "
                        "gateway-chain events for the destination hash(es) they "
                        "resolve to. Shows where a cross-layer message dies "
                        "(transit / handoff / no_binding / H-query). "
                        "e.g. --trace xl-w015-e020")
    p.add_argument("--airtime", action="store_true",
                   help="per-message airtime (ms) by category/SF: RTS+CTS (routing "
                        "SF), DATA (data SF), ACK (routing SF). Computed from the "
                        "*_tx emits + the LoRa formula (matches PHY airtime). "
                        "Re-analyses existing ndjson, no re-sim.")
    p.add_argument("--copies", action="store_true",
                   help="count copy-creating switches: a forward that abandoned "
                        "a next-hop which already decoded the frame (data_rx) and "
                        "switched to a different node -> a 2nd live copy. Reports "
                        "total + breakdown by trigger + per-message fan-out. "
                        "Re-analyses existing ndjson (no re-sim).")
    p.add_argument("--tail", nargs="?", const=10, default=None, type=int,
                   metavar="N",
                   help="profile the airtime tail: top-N messages by airtime "
                        "with hop count (= distinct DATA forwarders), retries, "
                        "copy-creating switches, and geographic distance "
                        "(km src->dst, min_h at --tail-link-km). Tells you "
                        "whether airtime is dominated by inflated routes "
                        "(chain >> min_h) or by retry tax (retr/chain high). "
                        "Default N=10.")
    p.add_argument("--tail-link-km", type=float, default=2.0,
                   help="assumed single-hop range (km) for --tail's min_h "
                        "estimate (default 2.0 km, urban SF8 ballpark).")
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

    cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name, id_to_layer \
        = load_config(args.config)

    if args.trace:
        render_trace(args.events, args.trace, slot_to_id, id_to_name)
        return

    if args.copies:
        render_copies(args.events, slot_to_id, id_to_name)
        return

    if args.airtime:
        render_airtime(args.events, slot_to_id, id_to_name)
        return

    if args.tail is not None:
        id_to_ll = {n["node_id"]: (n["lat"], n["lon"])
                    for n in cfg["nodes"]
                    if n.get("lat") is not None and n.get("lon") is not None}
        render_tail(args.events, slot_to_id, id_to_name, id_to_ll,
                    top=args.tail, link_km=args.tail_link_km)
        return

    msgs, arrival_by_payload, drops, gw_giveup, gw_layers, second_leg = analyse(
        args.events, slot_to_id, hash_layer_to_name)
    gw_home, gw_visit = gateway_layers(cfg)

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
        # Second-leg sub-classification for failures in the "reached gateway,
        # lost after forward" bucket (envelope decoded at the gw, target never
        # got it, and the gateway didn't formally give up resolving).
        if (r["arrived_ms"] is not None and not _arrived(r)
                and (r["origin"], r.get("dst_key_hash32")) not in gw_giveup):
            r["second_leg"], r["second_leg_loc"] = classify_second_leg(
                r, second_leg, gw_home, gw_visit, id_to_layer)

    # Resolve dropped cross-layer sends (no gateway route) to (origin, target)
    # pairs so they count toward the honest cross-layer denominator.
    no_gw_by_pair = defaultdict(int)
    for dp in drops:
        t_name = hash_layer_to_name.get((dp["target_layer_id"], dp["dst_key_hash32"]))
        t_id = name_to_id.get(t_name) if t_name else None
        if t_id is not None:
            no_gw_by_pair[(dp["origin"], t_id)] += 1

    # Pair filter: explicit --pair wins; else configured commands;
    # else (with --all) no filter at all.
    explicit = parse_pair_filter(args.pair, name_to_id)
    if explicit is not None:
        pair_filter = explicit
    elif args.all:
        pair_filter = None
    else:
        pair_filter = configured_pairs(cfg, name_to_id, hash_layer_to_name)

    rows = summarise(msgs, pair_filter, id_to_name, no_gw_by_pair)

    channel_rows = None
    posts_meta = None
    if args.mode in ("channel", "all"):
        posts_meta = configured_channel_posts(cfg, name_to_id)
        analyse_channel(args.events, slot_to_id, posts_meta, name_to_id)
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
        if args.failures:
            print()
            print("=== Cross-layer stage funnel ===")
            render_xl_funnel(msgs, no_gw_by_pair, gw_giveup, second_leg,
                             pair_filter, id_to_name, gw_layers, id_to_layer)
            print()
            print("=== DM failures (by mechanism) ===")
            render_dm_failures(msgs, no_gw_by_pair, gw_giveup,
                               pair_filter, id_to_name, gw_layers, id_to_layer)
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
