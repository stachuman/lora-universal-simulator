#!/usr/bin/env python3
"""tools/analyze.py — comprehensive run analyzer.

Computes how far an actual run sits from the theoretical optimum across
five dimensions (control-plane overhead, path optimality, SF optimality,
spatial-reuse concurrency, retry overhead) and prints a single structured
report.

Usage:
  analyze.py CONFIG.json EVENTS.ndjson      # use existing events file
  analyze.py CONFIG.json --run [--lus PATH] # run lus first, write events
                                            # to /tmp/<config-stem>.ndjson

Numbers vs. theoretical bounds:
  - Control-plane: a perfect-knowledge protocol spends airtime on DATA
    only (or DATA + ACK if reliability is required). Anything in the
    "BCN", "RTS*", "CTS*", "NACK", retry buckets is overhead vs that
    bound. We report the breakdown and the data/control ratio.
  - Path optimality: per-flight hop count vs. shortest-viable hop count
    on the *actually-observed* link graph. Edges exist when we ever
    saw a successful rx between a pair (proves they can hear each
    other under simulated propagation). Delta = actual − optimal.
  - SF optimality: per delivered DATA frame, the SF used vs. the
    fastest SF whose demod threshold + margin would have decoded the
    measured RX SNR. SF tax = log2(actual_air / optimal_air).
  - Concurrency: time-weighted mean of simultaneous in-flight TXes
    across the entire run. Higher = more spatial reuse.
  - Retry overhead: airtime spent on retried initiating frames as a
    fraction of data airtime.

Caveats:
  - Link graph for path optimality only includes pairs we OBSERVED an
    rx between. Pairs that exist physically but never tried to talk
    won't show up — true theoretical optimum could be shorter.
  - Concurrency uses a simple "any TX in flight" count; doesn't model
    spatial reuse from non-overlapping geography or SF orthogonality.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from heapq import heappush, heappop


SF_DEMOD_THRESHOLD = {  # Semtech AN1200.22, CR4/5 (matches dv_dual_sf.lua)
    5: -2.5, 6: -5.0, 7: -7.5, 8: -10.0,
    9: -12.5, 10: -15.0, 11: -17.5, 12: -20.0,
}

LABEL_CLASS = {
    # data
    "DATA":    "data",
    # initiating-directed (sender owns schedule; retries here are "tax")
    "RTS":     "ctrl_initiating",
    "RTS-fwd": "ctrl_initiating",
    "NACK":    "ctrl_initiating",
    # response-directed
    "CTS":     "ctrl_response",
    "ACK":     "ctrl_response",
    # retries (still useful as a separate bucket)
    "RTS-rty": "retry_initiating",
    "CTS-dup": "retry_response",
    "K-dup":   "retry_response",
    # flood
    "BCN":     "flood",
}


def airtime_ms(sf: int, bw_hz: int, cr: int, preamble_sym: int, len_bytes: int) -> float:
    """Mirror of dv_dual_sf.lua's airtime_ms."""
    t_sym = (2 ** sf) / (bw_hz / 1000.0)
    t_pre = (preamble_sym + 4.25) * t_sym
    de = 1 if t_sym >= 16 else 0
    num = 8 * len_bytes - 4 * sf + 44
    den = 4 * (sf - 2 * de)
    pay_sym = 8 + max((-(-num // den)) * cr, 0) if den > 0 else 0
    return t_pre + pay_sym * t_sym


# ---- IO -------------------------------------------------------------------

def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def maybe_run(cfg_path: str, events_path: str, lus_path: str) -> None:
    print(f"# running {lus_path} {cfg_path} → {events_path}", file=sys.stderr)
    res = subprocess.run([lus_path, cfg_path, events_path],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout, file=sys.stderr)
        print(res.stderr, file=sys.stderr)
        raise SystemExit(f"lus exited {res.returncode}")


def iter_events(path: str, since_ms: int = 0):
    """Stream events from `path`. Skip events with time_ms < since_ms — used
    to filter out the warmup window so statistics reflect steady-state."""
    with open(path) as f:
        for line in f:
            if not line:
                continue
            e = json.loads(line)
            if e.get("time_ms", 0) < since_ms:
                continue
            yield e


def find_warmup_end_ms(path: str) -> int:
    """Return the time_ms at which the runtime emitted `warmup_end`, or 0 if
    no such event exists (warmup_ms=0 runs, or pre-warmup-end-event runs)."""
    with open(path) as f:
        for line in f:
            if not line:
                continue
            e = json.loads(line)
            if e.get("type") == "warmup_end":
                return int(e.get("time_ms", 0))
    return 0


def build_pkt_label_map(path: str) -> dict[str, str]:
    """Map every tx event's packet id to its label.

    rx events do not carry the originator's label — only sf/bw/snr/etc — so
    classifying an rx by class (DATA / BCN / RTS / …) requires joining via
    the pkt id back to the corresponding tx. The map is built once across
    the WHOLE file (no warmup filter): a tx during warmup may still produce
    rx events post-warmup, and we need to classify those correctly.
    """
    pkt_label: dict[str, str] = {}
    with open(path) as f:
        for line in f:
            if not line:
                continue
            e = json.loads(line)
            if e.get("type") == "tx":
                pkt = e.get("pkt")
                lbl = e.get("label")
                if pkt and lbl:
                    pkt_label[pkt] = lbl
    return pkt_label


# ---- Section 3: control-plane overhead -----------------------------------

def section_control_plane(events_path: str, since_ms: int = 0) -> dict:
    by_class = Counter()
    by_label = Counter()
    air_by_class = Counter()
    air_by_label = Counter()
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "tx":
            continue
        lbl = e.get("label", "?")
        cls = LABEL_CLASS.get(lbl, "other")
        air = e.get("airtime_ms", 0)
        by_class[cls] += 1
        by_label[lbl] += 1
        air_by_class[cls] += air
        air_by_label[lbl] += air
    total_air = sum(air_by_class.values())
    return {
        "total_air_ms": total_air,
        "air_by_class": dict(air_by_class),
        "air_by_label": dict(air_by_label),
        "count_by_label": dict(by_label),
    }


def print_section_3(r: dict) -> None:
    print("\n=== (3) control-plane overhead ===")
    total = r["total_air_ms"]
    if total == 0:
        print("  no tx events")
        return
    classes = ["data", "ctrl_response", "ctrl_initiating", "retry_initiating",
               "retry_response", "flood", "other"]
    print(f"  {'class':<20} {'airtime_ms':>12}  {'%':>6}")
    for c in classes:
        a = r["air_by_class"].get(c, 0)
        if a == 0:
            continue
        print(f"  {c:<20} {a:>12}  {100.0*a/total:>5.1f}%")
    print(f"  {'TOTAL':<20} {total:>12}  100.0%")
    data_air = r["air_by_class"].get("data", 0)
    overhead = total - data_air
    print(f"\n  payload efficiency: {100.0 * data_air / total:.1f}% "
          f"(theoretical best: ~50% for DATA+ACK, 100% for DATA-only)")
    if data_air > 0:
        ratio = overhead / data_air
        print(f"  control-tax multiplier: {ratio:.1f}× "
              f"(every byte of payload costs {ratio:.1f} extra bytes of overhead)")
    print(f"\n  per-label breakdown:")
    for lbl, a in sorted(r["air_by_label"].items(), key=lambda kv: -kv[1]):
        cnt = r["count_by_label"][lbl]
        print(f"    {lbl:<10} count={cnt:>5}  airtime_ms={a:>10}  ({100.0*a/total:>4.1f}%)")


# ---- Section 1: path optimality ------------------------------------------

def build_link_graph(events_path: str, names_by_id: dict[int, str], since_ms: int = 0):
    """Edge (a, b) exists if any rx event from a to b was observed."""
    name_to_id = {v: k for k, v in names_by_id.items()}
    edges = defaultdict(set)  # node_id -> set of neighbor ids
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "rx":
            continue
        a = name_to_id.get(e.get("from"))
        b = name_to_id.get(e.get("to"))
        if a is None or b is None:
            continue
        edges[a].add(b)
        edges[b].add(a)
    return edges


def shortest_hops(edges: dict[int, set], src: int, dst: int) -> int | None:
    """Hop count of the shortest path from src to dst, or None if unreachable."""
    if src == dst:
        return 0
    seen = {src}
    frontier = [(0, src)]
    while frontier:
        d, u = heappop(frontier)
        if u == dst:
            return d
        for v in edges.get(u, ()):
            if v in seen:
                continue
            seen.add(v)
            heappush(frontier, (d + 1, v))
    return None


def section_path_optimality(cfg: dict, events_path: str, since_ms: int = 0) -> dict:
    names_by_id = {i: n["name"] for i, n in enumerate(cfg["nodes"])}
    name_to_id = {v: k for k, v in names_by_id.items()}
    edges = build_link_graph(events_path, names_by_id, since_ms)

    # For each delivered message, recover the actual hop chain by walking
    # data_tx events for that (origin, ctr), then deduping by
    # (src_node, next_hop) to collapse repeats onto a single hop.
    #
    # Why data_tx (not rts_tx): data_tx fires only after the RTS-CTS
    # handshake succeeds, so it represents a hop that actually carried
    # the payload. Failed RTS attempts that ended in path-switch (e.g.
    # destination NACKs the RTS, forwarder switches to a different
    # next-hop) emit rts_tx but no data_tx — they are not hops, just
    # exploration cost. Counting them inflates the metric vs. the
    # observed-link optimal that build_link_graph computes.
    #
    # Why dedupe by (src, next): both rts_tx (retries) and data_tx
    # (DATA retransmits when ACK is lost) fire multiple times per hop.
    # Deduping by the (src, next) pair collapses every repeat — RTS
    # retry, DATA retransmit — onto a single hop count.
    delivered = []
    data_tx_chain = defaultdict(list)  # (origin, dst, ctr) -> list of (t, src_id, next_id)
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type")
        d = e.get("data", {})
        if et == "delivered":
            delivered.append(e)
        elif et == "data_tx":
            origin = d.get("origin")
            dst = d.get("dst")
            seq = d.get("ctr")
            if origin is not None and dst is not None and seq is not None:
                # data_tx uses "to" for next-hop in dv_dual_sf.lua;
                # accept "next" as a fallback for any future scripts
                # that follow the rts_tx field naming.
                nxt = d.get("to", d.get("next"))
                data_tx_chain[(origin, dst, seq)].append((e["time_ms"], e["node"], nxt))

    deltas = []
    detail = []
    for ev in delivered:
        d = ev["data"]
        origin = d.get("origin")
        dst = d.get("dst", ev.get("node"))  # destination = node that fired delivered
        seq = d.get("ctr")
        chain = data_tx_chain.get((origin, dst, seq), [])
        if not chain:
            continue
        chain.sort()
        # Dedupe by (src, next) preserving order — collapses retransmits
        # onto the single underlying hop.
        seen = set()
        unique_chain = []
        for t, src_id, nxt in chain:
            key = (src_id, nxt)
            if key in seen:
                continue
            seen.add(key)
            unique_chain.append((t, src_id, nxt))
        actual_hops = len(unique_chain)
        # First hop's src is the originator; final hop's `next` is the dst.
        src = origin
        dst = unique_chain[-1][2] if unique_chain else None
        if src is None or dst is None:
            continue
        opt = shortest_hops(edges, src, dst)
        if opt is None or opt == 0:
            continue
        delta = actual_hops - opt
        deltas.append(delta)
        detail.append({
            "src": names_by_id.get(src, f"#{src}"),
            "dst": names_by_id.get(dst, f"#{dst}"),
            "actual": actual_hops, "optimal": opt, "delta": delta,
        })

    return {"deltas": deltas, "detail": detail, "n_delivered": len(delivered),
            "n_analyzed": len(deltas)}


def print_section_1(r: dict) -> None:
    print("\n=== (1) path optimality ===")
    print(f"  delivered messages: {r['n_delivered']}, analyzed: {r['n_analyzed']}")
    if not r["deltas"]:
        print("  (no flights to analyze)")
        return
    deltas = r["deltas"]
    total = len(deltas)
    optimal = sum(1 for d in deltas if d == 0)
    one_extra = sum(1 for d in deltas if d == 1)
    two_plus = sum(1 for d in deltas if d >= 2)
    print(f"  hop-count delta vs shortest observed-link path:")
    print(f"    Δ=0 (optimal):    {optimal:>3} ({100*optimal/total:.0f}%)")
    print(f"    Δ=1:              {one_extra:>3} ({100*one_extra/total:.0f}%)")
    print(f"    Δ≥2 (long path):  {two_plus:>3} ({100*two_plus/total:.0f}%)")
    print(f"  mean delta: {sum(deltas)/total:.2f} hops")
    if two_plus:
        print(f"  worst offenders (Δ≥2):")
        worst = sorted([d for d in r["detail"] if d["delta"] >= 2],
                       key=lambda x: -x["delta"])[:5]
        for w in worst:
            print(f"    {w['src']} -> {w['dst']}: actual={w['actual']} "
                  f"optimal={w['optimal']} (Δ={w['delta']})")


# ---- Section 2: SF optimality --------------------------------------------

def fastest_sf_for_snr(snr_db: float, allowed: list[int], margin_db: float) -> int:
    """Smallest SF in `allowed` whose threshold + margin <= snr_db."""
    for sf in sorted(allowed):
        if SF_DEMOD_THRESHOLD[sf] + margin_db <= snr_db:
            return sf
    return max(allowed)


def section_sf_optimality(cfg: dict, events_path: str,
                          pkt_label: dict[str, str], since_ms: int = 0) -> dict:
    sim = cfg.get("simulation", {})
    radio = sim.get("radio", {})
    bw_hz = int(radio.get("bw", 62)) * 1000
    cr = int(radio.get("cr", 5))
    margin_db = 5.0  # mirrors dv_dual_sf.lua default sf_margin_db
    # Allowed data SFs come from per-node config; derive a global from the
    # union over nodes (close enough for analysis).
    allowed = set()
    for n in cfg.get("nodes", []):
        nc = n.get("config", {})
        for sf in nc.get("allowed_data_sfs", []):
            allowed.add(int(sf))
    if not allowed:
        allowed = {7, 8, 9, 10, 11, 12}
    allowed = sorted(allowed)

    # Filter rx events to label=DATA only (joined via pkt id). Filtering
    # by `sf in allowed_data_sfs` is wrong: when routing_sf is in
    # allowed_data_sfs (typical for dv_dual_sf scenarios) every BCN /
    # RTS / CTS / ACK rx is miscounted as a data leg, swamping the
    # ~hundreds of real DATA events with thousands of control rx.
    rows = []  # (chosen_sf, optimal_sf, snr, airtime)
    skipped_no_label = 0
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "rx":
            continue
        lbl = pkt_label.get(e.get("pkt"))
        if lbl is None:
            skipped_no_label += 1
            continue
        if lbl != "DATA":
            continue
        sf = e.get("sf")
        snr = e.get("snr")
        if sf is None or snr is None:
            continue
        opt = fastest_sf_for_snr(snr, allowed, margin_db)
        rows.append((sf, opt, snr, e.get("airtime_ms", 0)))
    return {"rows": rows, "allowed": allowed, "margin_db": margin_db,
            "bw_hz": bw_hz, "cr": cr,
            "rx_with_no_label_join": skipped_no_label}


def print_section_2(r: dict) -> None:
    print("\n=== (2) SF optimality (DATA legs only — label-joined) ===")
    rows = r["rows"]
    if not rows:
        print("  (no DATA rx events found)")
        if r.get("rx_with_no_label_join"):
            print(f"  (note: {r['rx_with_no_label_join']} rx events had no matching tx label)")
        return
    optimal = sum(1 for sf, opt, *_ in rows if sf == opt)
    one_slow = sum(1 for sf, opt, *_ in rows if sf - opt == 1)
    two_slow = sum(1 for sf, opt, *_ in rows if sf - opt >= 2)
    total = len(rows)
    print(f"  DATA rx events: {total} (allowed SFs: {r['allowed']}, margin={r['margin_db']} dB)")
    print(f"    chose optimal:        {optimal:>4} ({100*optimal/total:.0f}%)")
    print(f"    one SF slower:        {one_slow:>4} ({100*one_slow/total:.0f}%)")
    print(f"    two+ SF slower:       {two_slow:>4} ({100*two_slow/total:.0f}%)")
    # Airtime "tax": total actual airtime vs total optimal airtime,
    # recomputing each row at its optimal SF. Uses 64 bytes as the
    # representative DATA payload.
    rep_bytes = 64
    actual_air = sum(airtime_ms(sf, r["bw_hz"], r["cr"], 16, rep_bytes)
                     for sf, *_ in rows)
    opt_air = sum(airtime_ms(opt, r["bw_hz"], r["cr"], 16, rep_bytes)
                  for _, opt, *_ in rows)
    if opt_air > 0:
        tax = (actual_air - opt_air) / opt_air
        print(f"  SF-airtime tax: {100*tax:.1f}% "
              f"(actual data airtime is {tax:+.1%} vs optimal at 64-byte rep)")
    if r.get("rx_with_no_label_join"):
        print(f"  (note: {r['rx_with_no_label_join']} rx events had no matching tx — pre-warmup tx?)")


# ---- Section 4: concurrency ----------------------------------------------

def section_concurrency(events_path: str, since_ms: int = 0) -> dict:
    # Walk tx events chronologically. Each tx implies airtime [t, t+airtime].
    # Compute time-weighted mean of simultaneous flights.
    tx_intervals = []
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "tx":
            continue
        start = e.get("time_ms", 0)
        air = e.get("airtime_ms", 0)
        tx_intervals.append((start, start + air))
    if not tx_intervals:
        return {"mean_concurrent": 0.0, "max_concurrent": 0,
                "any_tx_fraction": 0.0, "total_airtime_ms": 0,
                "wallclock_ms": 0}

    # Sweep-line: events at TX start (+1) and end (-1).
    points = []
    for s, e in tx_intervals:
        points.append((s, +1))
        points.append((e, -1))
    points.sort()
    # Time-weighted mean concurrency: sum (concurrent × interval_ms) / total_ms.
    cur = 0
    last_t = points[0][0] if points else 0
    weighted_sum = 0
    any_tx_ms = 0
    max_cur = 0
    for t, delta in points:
        if t > last_t:
            interval = t - last_t
            weighted_sum += cur * interval
            if cur > 0:
                any_tx_ms += interval
        cur += delta
        if cur > max_cur:
            max_cur = cur
        last_t = t
    wall = points[-1][0] - points[0][0] if points else 0
    mean_concur = weighted_sum / wall if wall > 0 else 0
    return {
        "mean_concurrent": mean_concur,
        "max_concurrent": max_cur,
        "any_tx_fraction": any_tx_ms / wall if wall > 0 else 0,
        "total_airtime_ms": sum(e - s for s, e in tx_intervals),
        "wallclock_ms": wall,
    }


def print_section_4(r: dict) -> None:
    print("\n=== (4) concurrency / spatial reuse ===")
    print(f"  wallclock spanned: {r['wallclock_ms']/1000:.1f} s")
    print(f"  total tx airtime:  {r['total_airtime_ms']/1000:.1f} s")
    print(f"  any-tx fraction:   {100*r['any_tx_fraction']:.1f}% "
          f"(channel busy at least one node)")
    print(f"  mean concurrent flights: {r['mean_concurrent']:.2f}")
    print(f"  peak concurrent flights: {r['max_concurrent']}")
    print(f"  (a perfectly-scheduled disjoint network would push mean → max)")


# ---- Section 5: retry overhead -------------------------------------------

def print_section_5(ctrl: dict) -> None:
    print("\n=== (5) retry overhead ===")
    air = ctrl["air_by_class"]
    data_air = air.get("data", 0)
    retry_init = air.get("retry_initiating", 0)
    retry_resp = air.get("retry_response", 0)
    if data_air == 0:
        print("  no DATA airtime — nothing to compare")
        return
    print(f"  retry airtime / data airtime:")
    print(f"    initiating retries (RTS-rty): {retry_init} ms ({100*retry_init/data_air:.1f}% of data)")
    print(f"    response retries (K-dup, CTS-dup): {retry_resp} ms ({100*retry_resp/data_air:.1f}% of data)")


# ---- Section 6: per-class SF distribution (TX side) ----------------------

def section_per_class_sf(events_path: str, since_ms: int = 0) -> dict:
    """For each (label, sf) pair: count of TX events and total airtime.

    Cuts the data the opposite way of section_control_plane (which sums by
    class only) so a glance reveals where the SF/airtime cost lives —
    e.g. "BCN at SF10 is 78% of total" or "DATA fan-out across SF8/9/10".
    """
    by_lbl_sf: dict = defaultdict(lambda: defaultdict(lambda: [0, 0]))  # [count, air]
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "tx":
            continue
        lbl = e.get("label", "?")
        sf = e.get("sf")
        air = e.get("airtime_ms", 0)
        by_lbl_sf[lbl][sf][0] += 1
        by_lbl_sf[lbl][sf][1] += air
    return by_lbl_sf


def print_section_6(r: dict, total_air: int) -> None:
    print("\n=== (6) per-class SF distribution (TX side) ===")
    if not r:
        print("  (no tx events)")
        return
    print(f"  {'label':<10} {'sf':>3} {'count':>6} {'airtime_ms':>11} {'avg_ms':>8} {'%air':>6}")
    # Sort by total airtime desc within each label, labels ordered by total airtime
    label_total = {lbl: sum(v[1] for v in sfs.values()) for lbl, sfs in r.items()}
    for lbl in sorted(r.keys(), key=lambda k: -label_total[k]):
        sfs = r[lbl]
        for sf in sorted(sfs.keys()):
            cnt, air = sfs[sf]
            avg = air / cnt if cnt else 0
            pct = 100 * air / total_air if total_air else 0
            print(f"  {lbl:<10} {sf:>3} {cnt:>6} {air:>11} {avg:>8.0f} {pct:>5.1f}%")


# ---- Section 7: drop / collision histogram -------------------------------

# Failure-mode event types emitted by the C++ runtime when an rx is rejected
# or a tx can't go out. Listed explicitly (not pattern-matched on "drop" in
# the type) so future runtime additions don't silently change the report.
DROP_TYPES = {
    "collision",          # two TXes overlap on the same SF/channel
    "drop_weak",          # rx SNR below SF demod threshold
    "drop_sf_mismatch",   # rx not listening on this SF at this moment
    "drop_preamble_miss", # preamble decode failed
    "drop_halfduplex",    # node TX'ing while a rx was arriving
    "drop_rx_blind",      # node off-air during rx
    "drop_busy",          # rx queue full / engine busy
    "drop_decoder",       # CRC / payload decoder rejected the frame
    "decoder_fail",
    "rx_failed",
    "duty_block",         # tx blocked by duty-cycle gate
    "tx_fail",
}


def section_drops(events_path: str, since_ms: int = 0) -> Counter:
    counts: Counter = Counter()
    for e in iter_events(events_path, since_ms):
        t = e.get("type", "")
        if t in DROP_TYPES:
            counts[t] += 1
    return counts


def print_section_7(r: Counter) -> None:
    print("\n=== (7) drop / collision events (post-warmup) ===")
    if not r:
        print("  (no drop or collision events observed)")
        return
    total = sum(r.values())
    for t, n in sorted(r.items(), key=lambda kv: -kv[1]):
        print(f"  {t:<22} {n:>6}  ({100*n/total:.1f}%)")
    print(f"  {'TOTAL':<22} {total:>6}")


# ---- Section 8: delivery-failure breakdown -------------------------------

def section_delivery_breakdown(events_path: str, since_ms: int = 0) -> dict:
    """For each user-originated message (originator-side tx_enqueue), record
    its terminal outcome: delivered / path_cascade_exhausted / unresolved.

    A message is identified by (origin, ctr). path_cascade_exhausted
    fires at the originator when every fallback next-hop has been tried and
    none worked; the `trigger` field in its data names the proximate cause.
    "unresolved" = a tx_enqueue at the originator with no terminal event,
    typically still in flight at sim_end or quietly dropped along the way.

    Returns enqueued_times / delivered_times / exhausted_times maps so
    downstream sections (cold-start curve, lifetime-waste) can derive
    per-message timing without re-scanning the events file.
    """
    enqueued: dict = {}    # (origin, dst, ctr) -> first enqueue time at originator
    delivered: dict = {}   # (origin, dst, ctr) -> first delivered time
    exhausted: dict = {}   # (origin, dst, ctr) -> {time_ms, trigger}
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        origin = d.get("origin")
        seq = d.get("ctr")
        if origin is None or seq is None:
            continue
        # ctr is per-(origin,dst); flight key needs dst to disambiguate.
        if et == "delivered":
            dst = d.get("dst", e.get("node"))
        else:
            dst = d.get("dst")
        if dst is None:
            continue
        key = (origin, dst, seq)
        if et == "tx_enqueue" and e.get("node") == origin and key not in enqueued:
            # Filter to the originator's own enqueue. Forwarder enqueues
            # also fire (depth>=1) and would inflate the "sent" count.
            enqueued[key] = e.get("time_ms", 0)
        elif et == "delivered" and key not in delivered:
            delivered[key] = e.get("time_ms", 0)
        elif et == "path_cascade_exhausted" and key not in exhausted:
            exhausted[key] = {
                "time_ms": e.get("time_ms", 0),
                "trigger": d.get("trigger", "?"),
            }
    n_enq = len(enqueued)
    n_del = sum(1 for k in delivered if k in enqueued)
    n_exh = sum(1 for k in exhausted if k in enqueued and k not in delivered)
    n_unresolved = n_enq - n_del - n_exh
    triggers: Counter = Counter(
        v["trigger"] for k, v in exhausted.items() if k in enqueued and k not in delivered
    )
    return {
        "n_enqueued": n_enq,
        "n_delivered": n_del,
        "n_exhausted": n_exh,
        "n_unresolved": max(0, n_unresolved),
        "exhausted_triggers": triggers,
        "enqueued_times": enqueued,
        "delivered_keys": set(delivered.keys()),
        "delivered_times": delivered,
        "exhausted_times": exhausted,
    }


def print_section_8(r: dict) -> None:
    print("\n=== (8) delivery breakdown ===")
    n = r["n_enqueued"]
    if n == 0:
        print("  (no originator-side tx_enqueue events)")
        return
    print(f"  user messages enqueued at originator: {n}")
    print(f"    delivered:                {r['n_delivered']:>4} ({100*r['n_delivered']/n:.0f}%)")
    print(f"    path_cascade_exhausted:   {r['n_exhausted']:>4} ({100*r['n_exhausted']/n:.0f}%)")
    print(f"    unresolved (still in-flight or silently dropped):"
          f" {r['n_unresolved']:>4} ({100*r['n_unresolved']/n:.0f}%)")
    if r["exhausted_triggers"]:
        print(f"  cascade-exhaustion triggers:")
        for trig, c in sorted(r["exhausted_triggers"].items(), key=lambda kv: -kv[1]):
            print(f"    {trig:<22} {c}")


# ---- Section 9: end-to-end latency for delivered -------------------------

def section_latency(events_path: str, since_ms: int = 0) -> list[int]:
    """Latency = (delivered.time_ms − originator's tx_enqueue.time_ms) per
    delivered flight (origin, dst, ctr). Useful for spotting protocols that
    "deliver" well only when given many seconds of slack.
    """
    enqueued: dict = {}
    latencies: list[int] = []
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        origin = d.get("origin")
        seq = d.get("ctr")
        if origin is None or seq is None:
            continue
        if et == "delivered":
            dst = d.get("dst", e.get("node"))
        else:
            dst = d.get("dst")
        if dst is None:
            continue
        key = (origin, dst, seq)
        if et == "tx_enqueue" and e.get("node") == origin and key not in enqueued:
            enqueued[key] = e.get("time_ms", 0)
        elif et == "delivered":
            t0 = enqueued.get(key)
            if t0 is not None:
                latencies.append(int(e.get("time_ms", 0)) - int(t0))
    return latencies


def print_section_9(latencies: list[int]) -> None:
    print("\n=== (9) end-to-end latency (delivered) ===")
    if not latencies:
        print("  (no deliveries to measure)")
        return
    s = sorted(latencies)
    n = len(s)
    median = s[n // 2]
    p95 = s[min(n - 1, int(0.95 * n))]
    p99 = s[min(n - 1, int(0.99 * n))]
    print(f"  n={n}  min={min(s)} ms  median={median} ms  "
          f"p95={p95} ms  p99={p99} ms  max={max(s)} ms")


# ---- Section 10: per-node TX hot spots -----------------------------------

def section_per_node_tx(events_path: str, cfg: dict, since_ms: int = 0,
                        top_n: int = 10) -> list[tuple]:
    """Top-N nodes by total TX airtime. Surfaces hot spots that consume
    disproportionate channel capacity (often gateway-shaped routers).

    The runtime currently emits tx.node as the node *name* string, while
    script_emit.node is the integer index. We accept either form and
    resolve to a display name via cfg.nodes when an int comes in.
    """
    air_by_node: Counter = Counter()
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "tx":
            continue
        air_by_node[e.get("node")] += e.get("airtime_ms", 0)
    name_by_idx = {i: n.get("name", f"#{i}") for i, n in enumerate(cfg.get("nodes", []))}
    rows = []
    for node_key, air_ms in air_by_node.most_common(top_n):
        if isinstance(node_key, int):
            label = name_by_idx.get(node_key, f"#{node_key}")
        else:
            label = str(node_key)
        rows.append((label, air_ms))
    return rows


def print_section_10(rows: list[tuple], total_air: int) -> None:
    print("\n=== (10) per-node TX airtime — top 10 ===")
    if not rows:
        print("  (no tx events)")
        return
    print(f"  {'node':<24} {'airtime_ms':>11} {'%total':>7}")
    for name, air in rows:
        pct = 100 * air / total_air if total_air else 0
        print(f"  {name:<24} {air:>11} {pct:>6.1f}%")


# ---- Section 11: routing churn -------------------------------------------

ROUTING_CHURN_TYPES = ("rt_aged", "rt_update", "rt_prune")


def section_routing_churn(events_path: str, since_ms: int = 0) -> dict:
    counts: Counter = Counter()
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        if et in ROUTING_CHURN_TYPES:
            counts[et] += 1
    return dict(counts)


def print_section_11(r: dict, analyzed_ms: int) -> None:
    print("\n=== (11) routing-table churn ===")
    if not r:
        print("  (no rt_aged / rt_update / rt_prune events)")
        return
    total = sum(r.values())
    sec = analyzed_ms / 1000.0 if analyzed_ms > 0 else 1.0
    for t, n in sorted(r.items(), key=lambda kv: -kv[1]):
        print(f"  {t:<22} {n:>6}  ({n/sec:.1f}/s)")
    print(f"  {'TOTAL':<22} {total:>6}  ({total/sec:.1f}/s)")


# ---- Section 12: cold-start delivery curve -------------------------------

def section_cold_start(deliv: dict, n_buckets: int = 5) -> list[dict]:
    """Bucket originator-side tx_enqueue events into N equal-time buckets
    and report delivery rate per bucket. A flat curve says "this rate is
    structural"; a rising curve says "convergence still helps later sends".
    Reuses the (origin, seq) → enqueue_time map from section_delivery_breakdown.
    """
    enqueued = deliv.get("enqueued_times") or {}
    delivered_keys = deliv.get("delivered_keys") or set()
    if not enqueued:
        return []
    items = sorted(enqueued.items(), key=lambda kv: kv[1])
    t_min = items[0][1]
    t_max = items[-1][1]
    if t_max == t_min:
        return [{"start_ms": t_min, "end_ms": t_max,
                 "sent": len(items),
                 "delivered": sum(1 for k, _ in items if k in delivered_keys)}]
    # +1 ms so the very last item lands in the final bucket via floor-division.
    bucket = (t_max - t_min) // n_buckets + 1
    out = [{"start_ms": t_min + i * bucket,
            "end_ms":   t_min + (i + 1) * bucket,
            "sent": 0, "delivered": 0} for i in range(n_buckets)]
    for key, t in items:
        idx = min((t - t_min) // bucket, n_buckets - 1)
        out[idx]["sent"] += 1
        if key in delivered_keys:
            out[idx]["delivered"] += 1
    return out


def print_section_12(rows: list[dict]) -> None:
    print("\n=== (12) cold-start delivery curve (by enqueue time) ===")
    if not rows:
        print("  (no originator-side enqueues to bucket)")
        return
    print(f"  {'window (s)':<24} {'sent':>5} {'delivered':>10} {'rate':>6}")
    for r in rows:
        s = r["sent"]
        d = r["delivered"]
        rate = (100 * d / s) if s else 0.0
        win = f"{r['start_ms']/1000:.0f}–{r['end_ms']/1000:.0f}"
        print(f"  {win:<24} {s:>5} {d:>10} {rate:>5.0f}%")


# ---- Section 13: BCN effective rate --------------------------------------

def section_bcn_effective(events_path: str, since_ms: int = 0) -> dict:
    """How often does receiving a BCN actually update the routing table?

    Compares `beacon_rx` event count (BCNs heard by neighbors) against
    `rt_update` event count (RT entries actually changed). Low ratio
    means the routing protocol is paying full BCN airtime cost for
    little informational gain — a lever for diff-only encoding.
    """
    beacon_rx = 0
    rt_update = 0
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        if et == "beacon_rx":
            beacon_rx += 1
        elif et == "rt_update":
            rt_update += 1
    return {"beacon_rx": beacon_rx, "rt_update": rt_update}


def print_section_13(r: dict) -> None:
    print("\n=== (13) BCN effectiveness ===")
    bcn_rx = r["beacon_rx"]
    upd = r["rt_update"]
    if bcn_rx == 0:
        print("  (no beacon_rx events)")
        return
    print(f"  beacon_rx events:  {bcn_rx}")
    print(f"  rt_update events:  {upd}")
    print(f"  rt_update / beacon_rx: {upd/bcn_rx:.2f} "
          f"(higher = beacons carry more new info; <1 means many BCNs are redundant)")


# ---- Section 14: per-message lifetime + cascade-requeue waste ------------

def section_lifetime_waste(deliv: dict) -> dict:
    """Per-message lifetime distribution + the channel-time-consumed ratio
    between exhausted and delivered messages. High ratio is the smell test
    for "cascade-requeue is keeping failing messages alive too long" —
    a dense-network failure mode where the protocol gives messages multiple
    retry chances, but the retries themselves saturate the channel and
    prevent ANY messages from succeeding. The "before/after" insight:

      • Delivered messages: typical lifetime is seconds (one happy-path
        RTS-CTS-DATA-ACK + maybe one retry).
      • Exhausted messages: lifetime is the per-message wallclock cap
        (cascade_requeue_total_max_ms) plus queue-wait time, often
        minutes — multiplied by however many concurrent failures exist.

    On s04 60-min with cascade_requeue_max=3 we observed median exhausted
    lifetime 178 s vs median delivered 10 s (18x), and TOTAL channel-time
    consumed by exhausted (50,880 s) vs delivered (1,700 s) at a 30x
    ratio. Section warns at ≥10x.

    Reuses the enqueued/delivered/exhausted time maps from
    section_delivery_breakdown — no second pass over the events file.
    """
    enq = deliv.get("enqueued_times") or {}
    delivered_times = deliv.get("delivered_times") or {}
    exhausted_times = deliv.get("exhausted_times") or {}

    deliv_lifetimes: list[int] = []
    for k, t_d in delivered_times.items():
        if k in enq:
            deliv_lifetimes.append(int(t_d) - int(enq[k]))
    exh_lifetimes: list[int] = []
    for k, info in exhausted_times.items():
        if k in enq:
            exh_lifetimes.append(int(info["time_ms"]) - int(enq[k]))

    return {
        "deliv_lifetimes_ms": sorted(deliv_lifetimes),
        "exh_lifetimes_ms":   sorted(exh_lifetimes),
        "total_deliv_ms":     sum(deliv_lifetimes),
        "total_exh_ms":       sum(exh_lifetimes),
    }


def print_section_14(r: dict) -> None:
    print("\n=== (14) per-message lifetime + cascade-requeue waste ===")
    def stats(s: list[int], label: str) -> str:
        if not s:
            return f"{label}: (none)"
        n = len(s)
        return (f"{label}: n={n}  min={s[0]//1000}s  "
                f"median={s[n // 2]//1000}s  "
                f"p95={s[min(n-1, int(0.95*n))]//1000}s  "
                f"max={s[-1]//1000}s")
    print(f"  {stats(r['deliv_lifetimes_ms'], 'delivered')}")
    print(f"  {stats(r['exh_lifetimes_ms'],   'exhausted')}")
    total_d_s = r["total_deliv_ms"] / 1000.0
    total_e_s = r["total_exh_ms"] / 1000.0
    print(f"  total channel-time consumed (in-system, summed across messages):")
    print(f"    delivered: {total_d_s:.0f} s")
    print(f"    exhausted: {total_e_s:.0f} s")
    if total_d_s > 0:
        ratio = total_e_s / total_d_s
        print(f"    ratio: {ratio:.1f}x")
        if ratio >= 10:
            print(f"  HIGH WASTE: exhausted messages consume {ratio:.0f}x more channel "
                  f"time than delivered.")
            print(f"  Likely cause: cascade-requeue keeping failing messages alive too "
                  f"long in a dense / overloaded network — each failed flight burns "
                  f"channel capacity that healthy flights need.")
            print(f"  Levers: cascade_requeue_max (4 attempts total today),")
            print(f"          cascade_requeue_total_max_ms (per-msg wallclock cap),")
            print(f"          or load-aware skip (drop new sends when queue is deep).")
        elif ratio >= 3:
            print(f"  Elevated waste ratio. Worth checking whether failed-message "
                  f"lifetimes are longer than the underlying flight cost justifies.")
    elif total_e_s > 0:
        print(f"    ratio: infinite (zero deliveries; every send exhausted)")


# ---- Section 15: duty-cycle consumption ----------------------------------

def section_duty_cycle(cfg: dict, events_path: str,
                       since_ms: int = 0) -> dict:
    """Per-node airtime as % of the EU868 / configured duty-cycle budget,
    plus a class-by-class breakdown of where the budget is spent.

    Duty cycle is the regulatory cap on per-radio airtime: at any sliding
    `window_ms` (default 3600 s = 1 hour), total TX airtime per node must
    not exceed `duty_cycle × window_ms` (default 1% × 3600 s = 36 s/hr).
    For a sim run of duration D, total expected max airtime per node is
    `duty_cycle × D` (the sliding window can't grant more total budget
    over D than its rate allows). When a node hits the cap, subsequent
    TXes get duty_cycle_blocked and the protocol stalls — this is real
    LoRa hardware behavior, not a simulator artifact.

    Reports:
      • config (duty_cycle %, window_ms, per-node budget for analyzed
        duration)
      • per-node TX-airtime / budget % distribution (min/p25/median/p75/max)
      • network-aggregate airtime by class with both share_of_budget
        (out of N×budget) and share_of_total (out of actual TX'd)
      • count of duty_cycle_blocked emits (TXes the protocol asked
        for but couldn't fire because of the cap)
    """
    sim = cfg.get("simulation", {})
    radio = sim.get("radio", {}) or {}
    duty_cycle = float(radio.get("duty_cycle", 0.01))
    window_ms = int(radio.get("duty_cycle_window_ms", 3_600_000))
    duration_ms = int(sim.get("duration_ms", 0))
    analyzed_ms = max(0, duration_ms - since_ms)
    # Per-node budget for the analyzed window. The duty-cycle rate is
    # constant over time so the budget scales linearly with the analyzed
    # window even if it exceeds the sliding-window length (the protocol
    # can't "save up" budget across windows).
    budget_per_node_ms = int(duty_cycle * analyzed_ms)

    air_by_node: Counter = Counter()
    air_by_label: Counter = Counter()
    blocked_count = 0
    for e in iter_events(events_path, since_ms):
        if e.get("type") == "tx":
            air_by_node[e.get("node")] += e.get("airtime_ms", 0)
            air_by_label[e.get("label", "?")] += e.get("airtime_ms", 0)
        elif e.get("type") == "script_emit" and e.get("emit_type") == "duty_cycle_blocked":
            blocked_count += 1

    # Build per-node consumption % distribution. Use cfg.nodes as the
    # universe so silent nodes count as 0% (otherwise the median is
    # biased toward heavy TX'ers).
    consumption_pct: list[float] = []
    if budget_per_node_ms > 0:
        for n in cfg.get("nodes", []):
            name = n.get("name")
            air = air_by_node.get(name, 0)
            consumption_pct.append(100.0 * air / budget_per_node_ms)
    consumption_pct.sort()

    return {
        "duty_cycle":          duty_cycle,
        "window_ms":           window_ms,
        "analyzed_ms":         analyzed_ms,
        "budget_per_node_ms":  budget_per_node_ms,
        "n_nodes":             len(cfg.get("nodes", [])),
        "consumption_pct":     consumption_pct,
        "air_by_label":        dict(air_by_label),
        "blocked_count":       blocked_count,
    }


def print_section_15(r: dict) -> None:
    print("\n=== (15) duty-cycle consumption ===")
    if r["budget_per_node_ms"] == 0:
        print("  (duty cycle disabled or zero analyzed window — nothing to compute)")
        return
    dc_pct = 100.0 * r["duty_cycle"]
    print(f"  config:           {dc_pct:.2f}% per {r['window_ms']/1000:.0f} s sliding window")
    print(f"  analyzed:         {r['analyzed_ms']/1000:.0f} s "
          f"({r['analyzed_ms']/60_000:.1f} min)")
    print(f"  per-node budget:  {r['budget_per_node_ms']/1000:.1f} s "
          f"(= {dc_pct:.2f}% × analyzed window)")
    s = r["consumption_pct"]
    n = len(s)
    if n > 0:
        def q(p: float) -> float:
            return s[min(n - 1, max(0, int(p * n)))]
        print(f"  per-node TX airtime as % of budget (n={n} nodes):")
        print(f"    min  {s[0]:>6.1f}%   p25  {q(0.25):>6.1f}%   "
              f"median {q(0.50):>6.1f}%   p75 {q(0.75):>6.1f}%   "
              f"max  {s[-1]:>6.1f}%")
    network_budget_ms = r["n_nodes"] * r["budget_per_node_ms"]
    total_air = sum(r["air_by_label"].values())
    print(f"  network total TX airtime: {total_air/1000:.0f} s "
          f"({100.0 * total_air / network_budget_ms:.1f}% of "
          f"{network_budget_ms/1000:.0f} s network budget)")
    if r["blocked_count"] > 0:
        print(f"  duty_cycle_blocked events: {r['blocked_count']} "
              f"(TXes the protocol attempted but couldn't fire)")
    if r["air_by_label"]:
        print(f"  airtime by class (share of network budget, share of actual TX):")
        print(f"    {'label':<10} {'airtime_s':>10} {'% budget':>9} {'% of TX':>9}")
        for lbl, air in sorted(r["air_by_label"].items(), key=lambda kv: -kv[1]):
            pct_budget = 100.0 * air / network_budget_ms if network_budget_ms > 0 else 0
            pct_total  = 100.0 * air / total_air if total_air > 0 else 0
            print(f"    {lbl:<10} {air/1000:>10.0f} "
                  f"{pct_budget:>8.1f}% {pct_total:>8.1f}%")


# ---- Section 16: routing-option diversity + cascade depth ----------------

def section_routing_diversity(events_path: str, since_ms: int = 0) -> dict:
    """Routing-table diversity (candidates per destination) + actual
    cascade usage per flight. Together these tell whether MAX_RT_CANDIDATES
    is the binding constraint:

      • If candidates/dst saturates the cap AND cascade depth is high,
        flights are running out of alternatives — raising the cap
        (and ensuring discovery to populate the new slots) would help.
      • If candidates/dst is well below the cap, the cap isn't binding —
        the limiting factor is discovery (Q-frames, BCN reach), not the
        cap itself.

    Reads node_state_snapshot for per-node rt diversity, and
    path_cascade / tx_blind_alt emits for per-flight cascade events.
    Originator-side tx_enqueue defines the universe of flights so
    primary-only flights (zero cascade events) count correctly.
    """
    snapshot_ratios: list[float] = []
    last_snapshot_per_node: dict = {}
    flight_cascades: dict = {}    # (origin, seq) -> int (cascade event count)

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}

        if et == "node_state_snapshot":
            dst = d.get("rt_dst_count", 0) or 0
            cand = d.get("rt_total_candidates", 0) or 0
            if dst > 0:
                snapshot_ratios.append(cand / dst)
                last_snapshot_per_node[e.get("node")] = (dst, cand)

        elif et == "tx_enqueue" and e.get("node") == d.get("origin"):
            key = (d.get("origin"), d.get("dst"), d.get("ctr"))
            if key[0] is not None and key[1] is not None and key not in flight_cascades:
                flight_cascades[key] = 0

        elif et == "path_cascade":
            key = (d.get("origin"), d.get("dst"), d.get("ctr"))
            if key in flight_cascades:
                flight_cascades[key] += 1

    snapshot_ratios.sort()
    return {
        "snapshot_ratios":  snapshot_ratios,
        "last_per_node":    last_snapshot_per_node,
        "flight_cascades":  list(flight_cascades.values()),
    }


def print_section_16(r: dict) -> None:
    print("\n=== (16) routing-option diversity ===")
    ratios = r["snapshot_ratios"]
    if not ratios:
        print("  (no node_state_snapshot events — instrumentation off?)")
        return
    n = len(ratios)
    def q(p: float) -> float:
        return ratios[min(n - 1, max(0, int(p * n)))]
    print(f"  candidates per destination (n={n} snapshots across run):")
    print(f"    min  {ratios[0]:>5.2f}   p25  {q(0.25):>5.2f}   "
          f"median {q(0.50):>5.2f}   p75 {q(0.75):>5.2f}   "
          f"max  {ratios[-1]:>5.2f}")

    if r["last_per_node"]:
        # Last snapshot per node — what each node had at sim end
        per_node = sorted(
            c / d for d, c in r["last_per_node"].values() if d > 0
        )
        if per_node:
            pn = len(per_node)
            print(f"  last-snapshot candidates/dst (n={pn} nodes, sim end):")
            print(f"    min  {per_node[0]:>5.2f}   "
                  f"median {per_node[pn//2]:>5.2f}   "
                  f"max  {per_node[-1]:>5.2f}")

    fc = r["flight_cascades"]
    if fc:
        total = len(fc)
        primary_only = sum(1 for c in fc if c == 0)
        one_alt      = sum(1 for c in fc if c == 1)
        two_three    = sum(1 for c in fc if 2 <= c <= 3)
        four_plus    = sum(1 for c in fc if c >= 4)
        print(f"  cascade depth per flight (n={total} originator-enqueued flights):")
        print(f"    primary only (0 cascades): {primary_only:>4} "
              f"({100*primary_only/total:.0f}%)")
        print(f"    1 cascade:                 {one_alt:>4} "
              f"({100*one_alt/total:.0f}%)")
        print(f"    2-3 cascades (1 cycle):    {two_three:>4} "
              f"({100*two_three/total:.0f}%)")
        print(f"    4+ cascades (multi-cycle): {four_plus:>4} "
              f"({100*four_plus/total:.0f}%)")
        # Pithy interpretation
        if primary_only < total * 0.1 and four_plus > total * 0.1:
            print(f"  Diversity is binding: nearly all flights need alts and "
                  f"{four_plus}/{total} cycle through them multiple times. "
                  f"Raising MAX_RT_CANDIDATES (currently 3) could help — but "
                  f"only if discovery populates the new slots.")


# ---- Section 17: anti-spam activity --------------------------------------

def section_anti_spam(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """1st-hop rate-limit silent drops + originator self-warnings.

    Two emit families track the anti-spam mechanism (see
    scenarios/dv_dual_sf.lua header doc block "Anti-spam: 1st-hop
    statistical rate-limit"):

      • rts_drop_originator_throttle — silent drop by a 1st-hop neighbour
        when apparent_origination[X] > threshold OR airtime > backstop.
        Fields: from (sender id), apparent_origination, airtime_ms,
        threshold_count, threshold_airtime_ms.

      • originator_self_over_budget — self-warning emitted by a node
        on its own terminal failure when own_originate_count >= warn
        threshold OR duty_cycle_tier >= STRAINED. Fields: origin,
        trigger ('rts_giveup' | 'ack_giveup' | 'budget_low'),
        own_originate_count_in_window, duty_cycle_tier.

    Detection of which trigger fired the silent drop (count vs airtime
    backstop) is by comparing the observed values against thresholds
    in the emit. If apparent_origination > threshold_count → count
    trigger; if airtime_ms > threshold_airtime_ms → airtime backstop.
    Both can be true simultaneously.
    """
    name_by_idx = {i: n.get("name", f"#{i}")
                   for i, n in enumerate(cfg.get("nodes", []))}

    drops_by_sender: Counter = Counter()
    drop_count_trigger = 0
    drop_airtime_trigger = 0
    drop_both_triggers = 0
    max_app_orig_per_sender: dict = {}    # sender -> max apparent_origination ever observed

    self_warns_by_origin: Counter = Counter()
    self_warn_by_trigger: Counter = Counter()
    self_warn_by_tier: Counter = Counter()

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "rts_drop_originator_throttle":
            sender = d.get("from")
            drops_by_sender[sender] += 1
            app_orig = d.get("apparent_origination", 0)
            air = d.get("airtime_ms", 0)
            thr_count = d.get("threshold_count", 0)
            thr_air   = d.get("threshold_airtime_ms", 0)
            count_hit   = app_orig > thr_count
            airtime_hit = air > thr_air
            if count_hit and airtime_hit:
                drop_both_triggers += 1
            elif count_hit:
                drop_count_trigger += 1
            elif airtime_hit:
                drop_airtime_trigger += 1
            prev = max_app_orig_per_sender.get(sender, 0)
            if app_orig > prev:
                max_app_orig_per_sender[sender] = app_orig
        elif et == "originator_self_over_budget":
            origin = d.get("origin")
            self_warns_by_origin[origin] += 1
            self_warn_by_trigger[d.get("trigger", "?")] += 1
            self_warn_by_tier[d.get("duty_cycle_tier", -1)] += 1

    def resolve(node_id):
        if isinstance(node_id, int):
            return name_by_idx.get(node_id, f"#{node_id}")
        return str(node_id) if node_id is not None else "?"

    # max_app_orig_by_name keeps the max for ALL senders that produced
    # drops, keyed by display name. Print path uses it to annotate the
    # top-N-by-drop-count table; previous version returned only the
    # top-5-by-max which led to "max R-C seen: 0" for senders that
    # were heavy by count but not by single-window peak.
    max_app_orig_by_name: dict = {}
    for s, v in max_app_orig_per_sender.items():
        max_app_orig_by_name[resolve(s)] = v
    return {
        "total_drops":             sum(drops_by_sender.values()),
        "unique_senders_throttled": len(drops_by_sender),
        "drops_by_sender":         [(resolve(s), c) for s, c in drops_by_sender.most_common(5)],
        "drop_count_trigger":      drop_count_trigger,
        "drop_airtime_trigger":    drop_airtime_trigger,
        "drop_both_triggers":      drop_both_triggers,
        "max_app_orig_by_name":    max_app_orig_by_name,
        "total_self_warns":        sum(self_warns_by_origin.values()),
        "self_warns_by_origin":    [(resolve(o), c) for o, c in self_warns_by_origin.most_common(5)],
        "self_warn_by_trigger":    dict(self_warn_by_trigger),
        "self_warn_by_tier":       dict(self_warn_by_tier),
    }


def print_section_17(r: dict) -> None:
    print("\n=== (17) anti-spam activity ===")
    if r["total_drops"] == 0 and r["total_self_warns"] == 0:
        print("  (no anti-spam events — clean run)")
        return

    print(f"  rts_drop_originator_throttle events: {r['total_drops']}")
    if r["total_drops"] > 0:
        print(f"  unique senders rate-limited:         {r['unique_senders_throttled']}")
        print(f"  trigger breakdown:")
        print(f"    count threshold only:       {r['drop_count_trigger']}")
        print(f"    airtime backstop only:      {r['drop_airtime_trigger']}")
        print(f"    both count + airtime:       {r['drop_both_triggers']}")
        if r["drops_by_sender"]:
            print(f"  top rate-limited senders:")
            for name, n in r["drops_by_sender"]:
                max_ao = r["max_app_orig_by_name"].get(name, 0)
                print(f"    {name:<24} {n:>5} drops   (max R-C seen: {max_ao})")

    print(f"\n  originator_self_over_budget events:  {r['total_self_warns']}")
    if r["total_self_warns"] > 0:
        if r["self_warn_by_trigger"]:
            print(f"  triggered by:")
            for trig, c in sorted(r["self_warn_by_trigger"].items(),
                                  key=lambda kv: -kv[1]):
                print(f"    {trig:<22} {c}")
        if r["self_warns_by_origin"]:
            print(f"  top self-warning originators:")
            for name, c in r["self_warns_by_origin"]:
                print(f"    {name:<24} {c} warns")
        if r["self_warn_by_tier"]:
            tier_name = {0: "HEALTHY", 1: "STRAINED",
                         2: "CRITICAL", 3: "EXHAUSTED"}
            print(f"  by duty-cycle tier at time of warn:")
            for tier, c in sorted(r["self_warn_by_tier"].items()):
                print(f"    {tier_name.get(tier, f'tier_{tier}'):<14} {c}")


# ---- Section 18: E2E delivery ACK metrics ---------------------------------

def section_e2e_ack(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """End-to-end DATA delivery ACK (§7.4 in PROTOCOL.md, commit 28ce259).

    Tracks the opt-in E2E ACK roundtrip introduced for important messages:
      • e2e_ack_pending      — originator registered send_e2e
      • e2e_ack_tx_enqueued  — destination queued the return ACK
      • delivered_confirmed  — originator matched returning E2E ACK
      • e2e_ack_unmatched    — ACK arrived but no pending entry
      • e2e_ack_timeout      — pending entry expired (no ACK in TTL)

    Confirmation rate = delivered_confirmed / e2e_ack_pending.
    """
    name_by_idx = {i: n.get("name", f"#{i}")
                   for i, n in enumerate(cfg.get("nodes", []))}

    pending = 0
    enqueued = 0
    confirmed = 0
    unmatched = 0
    timed_out = 0
    rtt_ms_list: list[int] = []
    pending_by_origin: Counter = Counter()
    confirmed_by_origin: Counter = Counter()
    timeout_by_origin: Counter = Counter()

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "e2e_ack_pending":
            pending += 1
            origin = e.get("node")
            pending_by_origin[origin] += 1
        elif et == "e2e_ack_tx_enqueued":
            enqueued += 1
        elif et == "delivered_confirmed":
            confirmed += 1
            confirmed_by_origin[e.get("node")] += 1
            rtt = d.get("rtt_ms")
            if isinstance(rtt, (int, float)) and rtt >= 0:
                rtt_ms_list.append(int(rtt))
        elif et == "e2e_ack_unmatched":
            unmatched += 1
        elif et == "e2e_ack_timeout":
            timed_out += 1
            timeout_by_origin[e.get("node")] += 1

    def resolve(nid):
        if isinstance(nid, int):
            return name_by_idx.get(nid, f"#{nid}")
        return str(nid) if nid is not None else "?"

    return {
        "pending":           pending,
        "enqueued":          enqueued,
        "confirmed":         confirmed,
        "unmatched":         unmatched,
        "timed_out":         timed_out,
        "rtt_ms":            sorted(rtt_ms_list),
        "pending_by_origin": [(resolve(o), c)
                              for o, c in pending_by_origin.most_common(5)],
        "confirmed_by_origin": dict((resolve(o), c)
                                     for o, c in confirmed_by_origin.items()),
        "timeout_by_origin":   dict((resolve(o), c)
                                     for o, c in timeout_by_origin.items()),
    }


def print_section_18(r: dict) -> None:
    print("\n=== (18) end-to-end delivery ACK ===")
    if r["pending"] == 0 and r["confirmed"] == 0 and r["timed_out"] == 0:
        print("  (no E2E ACK events — feature not exercised by this scenario)")
        return
    print(f"  send_e2e usage (e2e_ack_pending):  {r['pending']}")
    print(f"  return ACK queued at destination:  {r['enqueued']}")
    print(f"  delivered_confirmed (matched):     {r['confirmed']}")
    print(f"  e2e_ack_unmatched (late/duplicate):{r['unmatched']}")
    print(f"  e2e_ack_timeout (TTL exceeded):    {r['timed_out']}")
    if r["pending"] > 0:
        rate = 100.0 * r["confirmed"] / r["pending"]
        print(f"  confirmation rate:                 {rate:.1f}%")
    rtts = r["rtt_ms"]
    if rtts:
        n = len(rtts)
        def q(p): return rtts[min(n - 1, max(0, int(p * n)))]
        print(f"  E2E round-trip latency (ms): "
              f"min={rtts[0]}  p50={q(0.5)}  p95={q(0.95)}  max={rtts[-1]}")
    if r["pending_by_origin"]:
        print(f"  top send_e2e originators:")
        for name, c in r["pending_by_origin"]:
            conf = r["confirmed_by_origin"].get(name, 0)
            timeo = r["timeout_by_origin"].get(name, 0)
            print(f"    {name:<24} sent={c:>4}  confirmed={conf:>4}  "
                  f"timeout={timeo:>4}")


# ---- Section 19: hop & amplification analysis -----------------------------

def _trace_delivery_path(chain: list, deliver_node, deliver_t, origin) -> list:
    """Walk backward from delivery to reconstruct the ACTUAL chain of
    forwarders that produced the delivered copy. Each iteration finds
    the data_tx event with to==current that fired most recently before
    current's time. Returns the ordered list of hops (each is a dict
    with t/node/to), or None if reconstruction failed (e.g., chain
    missing the originator-side hop).

    NOTE on correctness: data_tx events from PARALLEL branches share
    the same (origin, seq) but represent independent flight copies.
    The "latest data_tx targeting `current` before deliver_t" finds the
    most-recent upstream hop, which by construction is on the branch
    that produced the delivered copy (= it had to arrive before
    delivery to cause delivery).
    """
    chain_sorted = sorted(chain, key=lambda x: x["t"])
    path = []
    current = deliver_node
    current_t = deliver_t
    while current != origin:
        candidates = [c for c in chain_sorted
                      if c["to"] == current and c["t"] <= current_t]
        if not candidates:
            return None
        best = candidates[-1]
        path.append(best)
        current = best["node"]
        current_t = best["t"]
        if len(path) > 50:  # sanity bound
            return None
    path.reverse()
    return path


def section_hop_limit(cfg: dict, events_path: str,
                       since_ms: int = 0,
                       hop_limit: int = 8) -> dict:
    """Hop-count analysis split cleanly into three orthogonal metrics:

    1. **Actual delivery-path hops** — the real chain of forwarders that
       produced the delivered copy. Reconstructed by walking BACKWARD
       from each delivered event: at each step, find the data_tx that
       targeted the current node and fired before the current time.
       This filters out parallel cascade branches.

    2. **Total unique edges traversed** — count of distinct (src, next)
       pairs across the whole (origin, seq) flight, including parallel
       branches that didn't end up delivering the message. This is what
       the original metric was measuring.

    3. **Amplification = total_unique_edges / delivery_path_hops** —
       how much extra airtime the flight consumed beyond its delivery
       path. 1.0× = clean single path; >1.0× = parallel branches still
       in flight (usually from ACK-loss → originator cascade-retry).

    Plus: duplicate-copy count per flight (from dup_drop events at
    intermediate nodes that already saw this (origin, seq)).

    Plus: fail-attribution against the hop limit — sends with shortest
    link-path > limit are physics-impossible at this limit (rare).
    """
    names_by_id = {i: n["name"] for i, n in enumerate(cfg["nodes"])}
    name_to_id = {v: k for k, v in names_by_id.items()}
    edges = build_link_graph(events_path, names_by_id, since_ms)

    delivered: dict = {}                                 # (o,s) -> (node, time_ms)
    data_tx_chain: dict[tuple, list] = defaultdict(list) # (o,s) -> list of {t,node,to}
    dup_drop_count: Counter = Counter()                  # (o,s) -> count
    path_cascade_count: Counter = Counter()              # (o,s) -> count
    sends: list[tuple[str, str]] = []

    for c in cfg.get("commands", []):
        cmd = c.get("command", "")
        at_ms = int(c.get("at_ms", 0))
        parts = cmd.split(maxsplit=2)
        verb = parts[0] if parts else ""
        if verb not in ("send", "send_e2e") or at_ms < since_ms:
            continue
        if len(parts) >= 3:
            origin = c.get("node")
            dst = parts[1]
            if origin and dst:
                sends.append((origin, dst))

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        origin = d.get("origin")
        seq = d.get("ctr")
        if et == "delivered":
            dst = d.get("dst", e.get("node"))
        else:
            dst = d.get("dst")
        if origin is None or dst is None or seq is None:
            continue
        key = (origin, dst, seq)
        if et == "delivered":
            delivered[key] = (e["node"], e["time_ms"])
        elif et == "data_tx":
            data_tx_chain[key].append({
                "t":    e["time_ms"],
                "node": e["node"],
                "to":   d.get("to", d.get("next")),
            })
        elif et == "dup_drop":
            dup_drop_count[key] += 1
        elif et == "path_cascade":
            path_cascade_count[key] += 1

    # Per-flight analysis
    path_hop_hist: Counter = Counter()
    amplification_hist: Counter = Counter()
    dup_count_hist: Counter = Counter()
    variant_count_hist: Counter = Counter()
    flights_at_limit = 0
    flights_over_limit = 0
    over_limit_examples: list[dict] = []
    top_amplified: list[dict] = []
    headroom_samples: list[int] = []
    per_flight: list[dict] = []
    total_unique_edges_all = 0
    total_path_hops_all = 0

    for key, chain in data_tx_chain.items():
        if key not in delivered:
            continue
        origin, dst, seq = key
        deliv_node, deliv_t = delivered[key]
        path = _trace_delivery_path(chain, deliv_node, deliv_t, origin)
        if path is None:
            continue
        # Count total unique edges across whole flight (incl. parallel branches)
        unique_edges = {(c["node"], c["to"]) for c in chain}
        total_unique = len(unique_edges)
        path_hops = len(path)
        if path_hops == 0:
            continue
        amp = total_unique / path_hops

        # "Variants" = independent branches the originator initiated for
        # this flight. Each data_tx event from the originator represents
        # a NEW branch (RTS-CTS-DATA happens once per successful CTS, so
        # multiple originator-side data_tx events imply cascade-after-
        # CTS-loss retries each spawning a fresh branch).
        # Note: downstream forwarders can ALSO cascade, multiplying
        # branches further — we don't count those here because
        # data_tx_chain doesn't carry forwarder cascade state.
        originator_tx_count = sum(1 for c in chain if c["node"] == origin)
        variants = max(1, originator_tx_count)

        path_hop_hist[path_hops] += 1
        total_unique_edges_all += total_unique
        total_path_hops_all += path_hops
        if path_hops == hop_limit:
            flights_at_limit += 1
        if path_hops > hop_limit:
            flights_over_limit += 1
            if len(over_limit_examples) < 5:
                over_limit_examples.append({
                    "origin": names_by_id.get(origin, f"#{origin}"),
                    "dst":    names_by_id.get(deliv_node, f"#{deliv_node}"),
                    "hops":   path_hops,
                })
        headroom_samples.append(hop_limit - path_hops)

        # Amplification buckets
        if amp <= 1.0:
            amp_bucket = "1.0× (single path)"
        elif amp <= 1.5:
            amp_bucket = "1.0-1.5×"
        elif amp <= 2.0:
            amp_bucket = "1.5-2.0×"
        elif amp <= 3.0:
            amp_bucket = "2.0-3.0×"
        else:
            amp_bucket = ">3.0×"
        amplification_hist[amp_bucket] += 1

        # Duplicate buckets
        dups = dup_drop_count.get(key, 0)
        if dups == 0:
            dup_bucket = "0 (clean)"
        elif dups == 1:
            dup_bucket = "1 dup"
        elif dups <= 3:
            dup_bucket = "2-3 dups"
        else:
            dup_bucket = "4+ dups"
        dup_count_hist[dup_bucket] += 1

        # Variant buckets
        if variants == 1:
            variant_bucket = "1 (single branch)"
        elif variants == 2:
            variant_bucket = "2 branches"
        elif variants == 3:
            variant_bucket = "3 branches"
        else:
            variant_bucket = "4+ branches"
        variant_count_hist[variant_bucket] += 1

        per_flight.append({
            "origin":            names_by_id.get(origin, f"#{origin}"),
            "dst":               names_by_id.get(deliv_node, f"#{deliv_node}"),
            "path_hops":         path_hops,
            "total_unique_edges": total_unique,
            "amplification":     amp,
            "dup_copies":        dups,
            "variants":          variants,
            "cascades":          path_cascade_count.get(key, 0),
        })

    # Top amplified flights
    top_amplified = sorted(per_flight,
                            key=lambda r: -r["amplification"])[:8]

    # Fail-attribution: sends with shortest-link-path > limit
    impossible_sends = 0
    impossible_examples: list[dict] = []
    for origin_name, dst_name in sends:
        a = name_to_id.get(origin_name)
        b = name_to_id.get(dst_name)
        if a is None or b is None:
            continue
        opt = shortest_hops(edges, a, b)
        if opt is not None and opt > hop_limit:
            impossible_sends += 1
            if len(impossible_examples) < 5:
                impossible_examples.append({
                    "src": origin_name, "dst": dst_name, "min_hops": opt,
                })

    # What-if sensitivity using ACTUAL delivery path (not unique edges)
    total_flights = sum(path_hop_hist.values())
    what_if = {}
    for trial_limit in (7, 6, 5, 4):
        if trial_limit >= hop_limit:
            continue
        too_long = sum(c for h, c in path_hop_hist.items() if h > trial_limit)
        what_if[trial_limit] = too_long

    return {
        "hop_limit":             hop_limit,
        "path_hop_hist":         dict(path_hop_hist),
        "amplification_hist":    dict(amplification_hist),
        "dup_count_hist":        dict(dup_count_hist),
        "variant_count_hist":    dict(variant_count_hist),
        "headroom_samples":      sorted(headroom_samples),
        "flights_at_limit":      flights_at_limit,
        "flights_over_limit":    flights_over_limit,
        "over_limit_examples":   over_limit_examples,
        "top_amplified":         top_amplified,
        "total_flights":         total_flights,
        "total_unique_edges_all": total_unique_edges_all,
        "total_path_hops_all":   total_path_hops_all,
        "impossible_sends":      impossible_sends,
        "impossible_examples":   impossible_examples,
        "total_sends":           len(sends),
        "what_if":               what_if,
    }


def print_section_19(r: dict) -> None:
    print(f"\n=== (19) hop & amplification analysis (limit = {r['hop_limit']}) ===")
    total = r["total_flights"]
    if total == 0:
        print("  (no delivered flights to analyze)")
        return

    # --- 1. Delivery-path hops (the TRUE hop count) ---
    print(f"  actual delivery-path hops (n={total} delivered):")
    hist = r["path_hop_hist"]
    for h in sorted(hist.keys()):
        bar = "#" * min(40, int(40 * hist[h] / total))
        marker = ""
        if h == r["hop_limit"]:
            marker = "  ← AT LIMIT"
        elif h > r["hop_limit"]:
            marker = "  ← OVER"
        print(f"    {h:>2} hop{'s' if h != 1 else ' '}: "
              f"{hist[h]:>5} ({100*hist[h]/total:>4.1f}%)  {bar}{marker}")

    headrooms = r["headroom_samples"]
    if headrooms:
        n = len(headrooms)
        median = headrooms[n // 2]
        p95_tight = headrooms[min(n - 1, int(0.05 * n))]
        worst = headrooms[0]
        print(f"  headroom to limit: median={median}, p95-tight={p95_tight}, worst={worst}")

    if r["flights_at_limit"]:
        print(f"  flights AT limit ({r['hop_limit']} hops): {r['flights_at_limit']}")
    if r["flights_over_limit"]:
        print(f"  flights OVER limit (delivery path > {r['hop_limit']}): "
              f"{r['flights_over_limit']}")
        if r["over_limit_examples"]:
            print(f"  examples of over-limit deliveries:")
            for ex in r["over_limit_examples"]:
                print(f"    {ex['origin']} → {ex['dst']}: {ex['hops']} hops")

    # --- 2. Message amplification (parallel branches) ---
    print(f"\n  message amplification (total edges burned / delivery-path hops):")
    for bucket in ["1.0× (single path)", "1.0-1.5×", "1.5-2.0×", "2.0-3.0×", ">3.0×"]:
        c = r["amplification_hist"].get(bucket, 0)
        if c > 0:
            bar = "#" * min(40, int(40 * c / total))
            print(f"    {bucket:<22}: {c:>4} ({100*c/total:>4.1f}%)  {bar}")
    if r["total_path_hops_all"] > 0:
        net_amp = r["total_unique_edges_all"] / r["total_path_hops_all"]
        wasted = r["total_unique_edges_all"] - r["total_path_hops_all"]
        wasted_pct = 100.0 * wasted / r["total_unique_edges_all"] if r["total_unique_edges_all"] else 0.0
        print(f"  network-wide: total edges={r['total_unique_edges_all']}, "
              f"delivery-path hops={r['total_path_hops_all']}")
        print(f"  fleet amplification: {net_amp:.2f}× "
              f"(= {wasted} wasted-edges, {wasted_pct:.1f}% of edges spent on dead branches)")

    # --- 3. Variants per flight (originator-initiated branches) ---
    print(f"\n  variants per flight (= distinct originator-initiated branches):")
    for bucket in ["1 (single branch)", "2 branches", "3 branches", "4+ branches"]:
        c = r["variant_count_hist"].get(bucket, 0)
        if c > 0:
            bar = "#" * min(40, int(40 * c / total))
            print(f"    {bucket:<22}: {c:>4} ({100*c/total:>4.1f}%)  {bar}")

    # --- 4. Duplicate copies (dup_drop count per flight) ---
    print(f"\n  duplicate copies per flight (dup_drop arrivals at "
          f"recipients/forwarders):")
    for bucket in ["0 (clean)", "1 dup", "2-3 dups", "4+ dups"]:
        c = r["dup_count_hist"].get(bucket, 0)
        if c > 0:
            bar = "#" * min(40, int(40 * c / total))
            print(f"    {bucket:<14}: {c:>4} ({100*c/total:>4.1f}%)  {bar}")

    # --- 5. Top amplified flights ---
    if r["top_amplified"]:
        print(f"\n  top {len(r['top_amplified'])} amplified flights "
              f"(real path × amplification = wasted airtime):")
        print(f"    {'origin':<24} {'dst':<24} {'path':>4} {'edges':>5} "
              f"{'amp':>5} {'var':>3} {'dups':>4} {'casc':>4}")
        for fl in r["top_amplified"]:
            print(f"    {fl['origin']:<24} {fl['dst']:<24} {fl['path_hops']:>4} "
                  f"{fl['total_unique_edges']:>5} {fl['amplification']:>4.1f}× "
                  f"{fl['variants']:>3} {fl['dup_copies']:>4} {fl['cascades']:>4}")

    # --- 5. Hop-limit fail attribution ---
    if r["impossible_sends"]:
        ts = r["total_sends"]
        pct = 100.0 * r["impossible_sends"] / ts if ts else 0.0
        print(f"\n  sends with shortest-path > limit (physics-impossible): "
              f"{r['impossible_sends']}/{ts} ({pct:.1f}%)")
        if r["impossible_examples"]:
            for ex in r["impossible_examples"]:
                print(f"    {ex['src']} → {ex['dst']}: min_hops={ex['min_hops']}")

    if r["what_if"]:
        print(f"\n  what-if sensitivity on delivery-path (currently-delivered flights "
              f"that would have failed):")
        for trial, lost in sorted(r["what_if"].items(), reverse=True):
            pct = 100.0 * lost / total if total else 0.0
            print(f"    if limit were {trial}: {lost} flights lost ({pct:.1f}%)")


# ---- Section 20: NACK reason breakdown ------------------------------------

def section_nack_reasons(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """NACK reason breakdown (commit 0160d79 added the reason byte).

    Two reasons defined:
      • busy_rx (legacy): receiver's pending_rx is locked to another flight
      • budget_low: receiver's duty-cycle tier >= CRITICAL — refuse forward

    Tracking the breakdown reveals what kind of pressure the network is
    under: many BUSY_RX → channel contention; many BUDGET_LOW → duty-cycle
    saturation. Also reveals which nodes are most saturated (top emitters
    of BUDGET_LOW NACKs).
    """
    name_by_idx = {i: n.get("name", f"#{i}")
                   for i, n in enumerate(cfg.get("nodes", []))}

    nack_tx_by_reason: Counter = Counter()
    nack_rx_by_reason: Counter = Counter()
    busy_tx_by_node: Counter = Counter()
    budget_tx_by_node: Counter = Counter()
    budget_rx_by_node: Counter = Counter()

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "nack_tx":
            reason = d.get("reason", "busy_rx")
            nack_tx_by_reason[reason] += 1
            node = e.get("node")
            if reason == "budget_low":
                budget_tx_by_node[node] += 1
            else:
                busy_tx_by_node[node] += 1
        elif et == "nack_rx":
            reason = d.get("reason", "busy_rx")
            nack_rx_by_reason[reason] += 1
            if reason == "budget_low":
                budget_rx_by_node[e.get("node")] += 1

    def resolve(nid):
        if isinstance(nid, int):
            return name_by_idx.get(nid, f"#{nid}")
        return str(nid) if nid is not None else "?"

    return {
        "tx_by_reason":         dict(nack_tx_by_reason),
        "rx_by_reason":         dict(nack_rx_by_reason),
        "top_budget_emitters":  [(resolve(n), c)
                                  for n, c in budget_tx_by_node.most_common(5)],
        "top_busy_emitters":    [(resolve(n), c)
                                  for n, c in busy_tx_by_node.most_common(5)],
        "top_budget_receivers": [(resolve(n), c)
                                  for n, c in budget_rx_by_node.most_common(5)],
    }


def print_section_20(r: dict) -> None:
    print("\n=== (20) NACK reason breakdown ===")
    tx = r["tx_by_reason"]
    rx = r["rx_by_reason"]
    if not tx and not rx:
        print("  (no NACK events — instrumentation may not be wired)")
        return
    total_tx = sum(tx.values())
    total_rx = sum(rx.values())
    print(f"  nack_tx (emitted by receivers refusing): {total_tx}")
    for reason, c in sorted(tx.items(), key=lambda kv: -kv[1]):
        pct = 100.0 * c / total_tx if total_tx else 0.0
        print(f"    {reason:<14}: {c:>5} ({pct:.0f}%)")
    print(f"  nack_rx (received by senders): {total_rx}")
    for reason, c in sorted(rx.items(), key=lambda kv: -kv[1]):
        pct = 100.0 * c / total_rx if total_rx else 0.0
        print(f"    {reason:<14}: {c:>5} ({pct:.0f}%)")
    if r["top_budget_emitters"]:
        print(f"  top BUDGET_LOW NACK emitters (saturated nodes):")
        for name, c in r["top_budget_emitters"]:
            print(f"    {name:<24} {c}")
    if r["top_budget_receivers"]:
        print(f"  top BUDGET_LOW NACK receivers (senders being told to back off):")
        for name, c in r["top_budget_receivers"]:
            print(f"    {name:<24} {c}")


# ---- Section 21: budget tier residence + observations ---------------------

def section_budget_tier(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """Duty-cycle budget tier analysis (residence time + event-driven obs).

    Two data sources:

    A. node_state_snapshot (periodic, sample-and-hold) — preferred.
       Each snapshot carries `budget_tier` (0=HEALTHY, 1=STRAINED,
       2=CRITICAL, 3=EXHAUSTED) and `pct_used`. The tier observed at
       time T is assumed to hold until the next snapshot — gives a true
       time-weighted residence per tier per node. Approximate for fast
       transitions but accurate for slow-changing state.

    B. Tier-revealing event counts — fallback when snapshot doesn't
       carry tier (legacy traces) and for event frequency tracking:
         • beacon_skipped_budget  — tier was >= CRITICAL on BCN fire
         • nack_tx (budget_low)   — tier was >= CRITICAL on RTS-rx
         • originator_self_over_budget — tier was >= STRAINED on giveup
       These can't measure HEALTHY time (no events fire there) but
       count "saturation incidents" useful for spotting hot nodes.

    Reports BOTH: residence-time histogram (if snapshots have tier),
    plus event-frequency breakdown.
    """
    name_by_idx = {i: n.get("name", f"#{i}")
                   for i, n in enumerate(cfg.get("nodes", []))}

    # Source A: snapshots with tier (residence time)
    samples: dict = defaultdict(list)  # node -> [(time_ms, tier_int), ...]
    transitions: Counter = Counter()   # (from, to) -> count per node
    last_tier: dict = {}               # node -> last tier seen
    pct_used_samples: list[float] = [] # network-wide pct_used distribution
    snapshot_count = 0
    snapshot_with_tier = 0

    # Source B: event-driven counts
    beacon_skipped_budget: Counter = Counter()
    nack_budget_emit: Counter = Counter()
    self_over_budget: Counter = Counter()
    tier_observations: Counter = Counter()  # tier -> total count

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "node_state_snapshot":
            snapshot_count += 1
            tier = d.get("budget_tier")
            if tier is not None:
                snapshot_with_tier += 1
                node = e.get("node")
                t = e["time_ms"]
                samples[node].append((t, int(tier)))
                prev = last_tier.get(node)
                if prev is not None and prev != tier:
                    transitions[(prev, int(tier))] += 1
                last_tier[node] = int(tier)
            pct = d.get("pct_used")
            if isinstance(pct, (int, float)):
                pct_used_samples.append(float(pct))
        elif et == "beacon_skipped_budget":
            beacon_skipped_budget[e.get("node")] += 1
            tier = d.get("tier")
            if tier is not None:
                tier_observations[int(tier)] += 1
        elif et == "nack_tx" and d.get("reason") == "budget_low":
            nack_budget_emit[e.get("node")] += 1
            tier = d.get("tier")
            if tier is not None:
                tier_observations[int(tier)] += 1
        elif et == "originator_self_over_budget":
            self_over_budget[e.get("node")] += 1
            tier = d.get("duty_cycle_tier")
            if tier is not None:
                tier_observations[int(tier)] += 1

    # Time-weighted residence per tier per node (sample-and-hold).
    # tier_ms[node][tier] = total ms in that tier.
    tier_ms: dict = defaultdict(lambda: defaultdict(int))
    for node, seq in samples.items():
        seq_sorted = sorted(seq)
        for i in range(len(seq_sorted) - 1):
            t0, tier = seq_sorted[i]
            t1 = seq_sorted[i + 1][0]
            tier_ms[node][tier] += max(0, t1 - t0)

    # Aggregate network-wide residence
    net_tier_ms: dict = defaultdict(int)
    for per in tier_ms.values():
        for tier, ms in per.items():
            net_tier_ms[tier] += ms

    pct_used_samples.sort()

    def resolve(nid):
        if isinstance(nid, int):
            return name_by_idx.get(nid, f"#{nid}")
        return str(nid) if nid is not None else "?"

    # Per-node "worst tier reached" + time in each tier (top offenders)
    per_node_summary = []
    for node, per in tier_ms.items():
        total = sum(per.values())
        if total == 0:
            continue
        worst = max(per.keys()) if per else 0
        time_in_strained_plus = sum(ms for t, ms in per.items() if t >= 1)
        per_node_summary.append({
            "name":  resolve(node),
            "total_ms": total,
            "worst":    worst,
            "strained_plus_ms": time_in_strained_plus,
            "strained_plus_pct": 100.0 * time_in_strained_plus / total if total else 0.0,
            "tier_ms":  dict(per),
        })
    per_node_summary.sort(key=lambda r: -r["strained_plus_ms"])

    return {
        "snapshot_count":        snapshot_count,
        "snapshot_with_tier":    snapshot_with_tier,
        "n_nodes_sampled":       len(samples),
        "net_tier_ms":           dict(net_tier_ms),
        "transitions":           dict(transitions),
        "per_node_summary":      per_node_summary,
        "pct_used_samples":      pct_used_samples,
        "beacon_skipped_budget": dict((resolve(n), c)
                                       for n, c in beacon_skipped_budget.items()),
        "nack_budget_emit":      dict((resolve(n), c)
                                       for n, c in nack_budget_emit.items()),
        "self_over_budget":      dict((resolve(n), c)
                                       for n, c in self_over_budget.items()),
        "tier_observations":     dict(tier_observations),
    }


def print_section_21(r: dict) -> None:
    print("\n=== (21) budget tier residence + observations ===")
    tier_name = {0: "HEALTHY", 1: "STRAINED", 2: "CRITICAL", 3: "EXHAUSTED"}

    # --- A. Residence time (preferred — needs node_state_snapshot.budget_tier)
    net = r["net_tier_ms"]
    total = sum(net.values())
    if total > 0:
        print(f"  network-wide tier residence "
              f"(sample-and-hold, n={r['n_nodes_sampled']} nodes):")
        for tier in sorted(net.keys()):
            pct = 100.0 * net[tier] / total
            tname = tier_name.get(tier, f"tier_{tier}")
            print(f"    {tname:<10}: {net[tier]/1000:>8.1f} s ({pct:>4.1f}%)")
        trans = r["transitions"]
        if trans:
            print(f"  tier transitions (top 8):")
            for (frm, to), c in sorted(trans.items(), key=lambda kv: -kv[1])[:8]:
                print(f"    {tier_name.get(frm, '?'):<10} → "
                      f"{tier_name.get(to, '?'):<10}: {c}")
        if r["per_node_summary"]:
            top = [n for n in r["per_node_summary"]
                   if n["strained_plus_ms"] > 0][:5]
            if top:
                print(f"  top nodes by time spent in STRAINED+ tiers:")
                for n in top:
                    worst_name = tier_name.get(n["worst"], f"#{n['worst']}")
                    print(f"    {n['name']:<24}  {n['strained_plus_ms']/1000:>6.1f} s "
                          f"({n['strained_plus_pct']:>4.1f}%)  worst={worst_name}")
        ps = r["pct_used_samples"]
        if ps:
            n = len(ps)
            def q(p): return ps[min(n - 1, max(0, int(p * n)))]
            print(f"  pct_used distribution (across all snapshots): "
                  f"p50={q(0.5):.1f}%  p95={q(0.95):.1f}%  max={ps[-1]:.1f}%")
    elif r["snapshot_count"] > 0 and r["snapshot_with_tier"] == 0:
        print(f"  NOTE: {r['snapshot_count']} node_state_snapshot events seen but none")
        print(f"        carry budget_tier (legacy trace). Re-run with updated lua")
        print(f"        to enable residence-time analysis.")

    # --- B. Event-driven obs (always shown; complement to residence)
    skipped = r["beacon_skipped_budget"]
    nacks   = r["nack_budget_emit"]
    selfwarn = r["self_over_budget"]
    if skipped or nacks or selfwarn:
        if total > 0:
            print()  # spacer between sections
        print(f"  tier-driven event counts:")
        if skipped:
            tot = sum(skipped.values())
            print(f"    beacon_skipped_budget:       {tot} events")
            for name, c in sorted(skipped.items(), key=lambda kv: -kv[1])[:5]:
                print(f"      {name:<22} {c} skips")
        if nacks:
            tot = sum(nacks.values())
            print(f"    budget_low NACKs emitted:    {tot}")
            for name, c in sorted(nacks.items(), key=lambda kv: -kv[1])[:5]:
                print(f"      {name:<22} {c} NACKs")
        if selfwarn:
            tot = sum(selfwarn.values())
            print(f"    originator_self_over_budget: {tot} warns")
            for name, c in sorted(selfwarn.items(), key=lambda kv: -kv[1])[:5]:
                print(f"      {name:<22} {c} warns")
    elif total == 0:
        print("  (no tier-related events — network stayed in HEALTHY tier)")


# ---- Section 22: tier-aware routing impact --------------------------------

def section_tier_routing(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """Tier-aware routing (commit 939842d) demotes saturated next-hops via
    a dB-score penalty in route_strictly_better. The mechanism's impact:

      • blind_observed with reason='nack_budget' — sender marked a peer
        blind due to receiving a budget NACK
      • rt_update events — implicitly elevated when tier changes shuffle
        the routing table (no separate "tier-driven" flag, so we can only
        count total rt_update churn for now)

    Reports the count of budget-driven blind marks and active blind window
    extent. Combined with §20 NACK reasons, this gives the full picture
    of the tier-aware routing feedback loop.
    """
    name_by_idx = {i: n.get("name", f"#{i}")
                   for i, n in enumerate(cfg.get("nodes", []))}

    blind_observed_total = 0
    blind_observed_budget = 0
    blind_observed_other = 0
    blind_by_observer: Counter = Counter()  # the OBSERVING node
    blind_for_peer: Counter = Counter()     # the BLIND-MARKED peer
    tx_blind_defer = 0
    tx_blind_alt = 0
    blind_durations_ms: list[int] = []  # all blind_until - now from blind_observed

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "blind_observed":
            blind_observed_total += 1
            reason = d.get("reason", "")
            if reason == "nack_budget":
                blind_observed_budget += 1
                blind_by_observer[e.get("node")] += 1
                blind_for_peer[d.get("node")] += 1
            else:
                blind_observed_other += 1
            # extract duration if present
            until = d.get("until_ms")
            now = e.get("time_ms")
            if isinstance(until, (int, float)) and isinstance(now, (int, float)):
                dur = int(until - now)
                if dur > 0:
                    blind_durations_ms.append(dur)
        elif et == "tx_blind_defer":
            tx_blind_defer += 1
        elif et == "tx_blind_alt":
            tx_blind_alt += 1

    def resolve(nid):
        if isinstance(nid, int):
            return name_by_idx.get(nid, f"#{nid}")
        return str(nid) if nid is not None else "?"

    return {
        "blind_observed_total":  blind_observed_total,
        "blind_observed_budget": blind_observed_budget,
        "blind_observed_other":  blind_observed_other,
        "top_observers":         [(resolve(n), c)
                                   for n, c in blind_by_observer.most_common(5)],
        "top_blind_peers":       [(resolve(n), c)
                                   for n, c in blind_for_peer.most_common(5)],
        "tx_blind_defer":        tx_blind_defer,
        "tx_blind_alt":          tx_blind_alt,
        "blind_durations_ms":    sorted(blind_durations_ms),
    }


def print_section_22(r: dict) -> None:
    print("\n=== (22) tier-aware routing impact ===")
    if r["blind_observed_total"] == 0 and r["tx_blind_defer"] == 0:
        print("  (no blind/tier events — feature inactive in this run)")
        return
    print(f"  blind_observed (total):       {r['blind_observed_total']}")
    print(f"    of which budget-driven:     {r['blind_observed_budget']}")
    print(f"    of which other (CTS overhear etc.): {r['blind_observed_other']}")
    print(f"  tx_blind_defer (held back due to blind peer):  {r['tx_blind_defer']}")
    print(f"  tx_blind_alt (switched to alt due to blind):   {r['tx_blind_alt']}")
    if r["top_observers"]:
        print(f"  top observers (sending budget-driven blind marks):")
        for name, c in r["top_observers"]:
            print(f"    {name:<24} {c}")
    if r["top_blind_peers"]:
        print(f"  top peers being marked blind (saturated):")
        for name, c in r["top_blind_peers"]:
            print(f"    {name:<24} {c}")
    durs = r["blind_durations_ms"]
    if durs:
        n = len(durs)
        def q(p): return durs[min(n - 1, max(0, int(p * n)))]
        print(f"  blind window duration: "
              f"min={durs[0]/1000:.0f}s  p50={q(0.5)/1000:.0f}s  "
              f"p95={q(0.95)/1000:.0f}s  max={durs[-1]/1000:.0f}s")


# ---- Section 23: inter-layer gateway efficiency (§7.3 — stub for now) -----

def section_inter_layer(events_path: str, cfg: dict, since_ms: int = 0) -> dict:
    """Inter-layer gateway TDM scheduling (roadmap §7.3, NOT YET IMPLEMENTED
    as of writing).

    When the feature lands, the lua will emit:
      • layer_sweep_start / layer_sweep_end — gateway tunes to/from upper layer
      • cross_layer_handoff — frame transitioned between layers
      • cross_layer_giveup — frame dropped (no overlap window)
      • gateway_schedule_announced / gateway_schedule_received

    This stub looks for those events and prints "(not implemented)" if
    absent. When the feature lands, replace the stub body with real
    aggregation; the print path will reveal real data automatically.
    """
    sweep_start = 0
    sweep_end = 0
    cross_layer_handoffs = 0
    cross_layer_giveups = 0
    gateway_schedule_announced = 0
    gateway_schedule_received = 0
    is_gateway_count: Counter = Counter()  # node -> count of BCNs with self_gateway_flag

    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        if et == "layer_sweep_start":
            sweep_start += 1
        elif et == "layer_sweep_end":
            sweep_end += 1
        elif et == "cross_layer_handoff":
            cross_layer_handoffs += 1
        elif et == "cross_layer_giveup":
            cross_layer_giveups += 1
        elif et == "gateway_schedule_announced":
            gateway_schedule_announced += 1
        elif et == "gateway_schedule_received":
            gateway_schedule_received += 1
        elif et == "beacon_tx" and d.get("self_gateway_flag"):
            is_gateway_count[e.get("node")] += 1

    return {
        "sweep_start":                 sweep_start,
        "sweep_end":                   sweep_end,
        "cross_layer_handoffs":        cross_layer_handoffs,
        "cross_layer_giveups":         cross_layer_giveups,
        "gateway_schedule_announced":  gateway_schedule_announced,
        "gateway_schedule_received":   gateway_schedule_received,
        "is_gateway_count":            dict(is_gateway_count),
    }


def print_section_23(r: dict) -> None:
    print("\n=== (23) inter-layer gateway efficiency (§7.3) ===")
    total = (r["sweep_start"] + r["cross_layer_handoffs"] +
             r["gateway_schedule_announced"] + len(r["is_gateway_count"]))
    if total == 0:
        print("  (no inter-layer events — §7.3 not yet implemented; section will "
              "populate automatically when the feature lands)")
        return
    if r["is_gateway_count"]:
        print(f"  gateway-flagged nodes: {len(r['is_gateway_count'])}")
    if r["sweep_start"]:
        print(f"  layer_sweep_start events:      {r['sweep_start']}")
        print(f"  layer_sweep_end events:        {r['sweep_end']}")
    if r["cross_layer_handoffs"]:
        print(f"  cross_layer_handoff events:    {r['cross_layer_handoffs']}")
    if r["cross_layer_giveups"]:
        print(f"  cross_layer_giveup events:     {r['cross_layer_giveups']}")
    if r["gateway_schedule_announced"]:
        print(f"  gateway_schedule_announced:    {r['gateway_schedule_announced']}")
    if r["gateway_schedule_received"]:
        print(f"  gateway_schedule_received:     {r['gateway_schedule_received']}")


# ---- Headline -------------------------------------------------------------

def print_headline(cfg: dict, events_path: str, ctrl: dict, since_ms: int = 0) -> None:
    # `sent` counts user commands whose timestamp falls in the analyzed window.
    # Pre-warmup commands are unusual (most scenarios shift commands past
    # warmup) but we filter defensively so the delivery ratio matches the
    # window the rest of the report describes.
    sent = 0
    delivered = 0
    for c in cfg.get("commands", []):
        cmd = c.get("command", "")
        at_ms = int(c.get("at_ms", 0))
        # Match both `send <dst> <text>` and `send_e2e <dst> <text>` — each
        # enqueues exactly one originator-side message.
        verb = cmd.split(maxsplit=1)[0] if cmd else ""
        if verb in ("send", "send_e2e") and at_ms >= since_ms:
            sent += 1
    for e in iter_events(events_path, since_ms):
        if e.get("type") == "script_emit" and e.get("emit_type") == "delivered":
            delivered += 1
    print("\n=== headline ===")
    print(f"  delivered: {delivered}/{sent} = {100*delivered/sent:.0f}%" if sent else f"  delivered: {delivered}")
    total = ctrl["total_air_ms"]
    data = ctrl["air_by_class"].get("data", 0)
    if total:
        print(f"  payload airtime efficiency: {100*data/total:.1f}%")


# ---- Driver ---------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("config")
    p.add_argument("events", nargs="?")
    p.add_argument("--run", action="store_true",
                   help="Run lus on the config first; events file written to /tmp.")
    p.add_argument("--lus", default="build/orchestrator/lus")
    args = p.parse_args()

    if args.events is None:
        if not args.run:
            sys.exit("either provide EVENTS.ndjson or pass --run")
        stem = os.path.splitext(os.path.basename(args.config))[0]
        args.events = f"/tmp/{stem}_analyze.ndjson"
    if args.run:
        maybe_run(args.config, args.events, args.lus)
    if not os.path.exists(args.events):
        sys.exit(f"events file does not exist: {args.events}")

    cfg = load_config(args.config)
    duration_ms = cfg.get("simulation", {}).get("duration_ms", 0)
    warmup_end_ms = find_warmup_end_ms(args.events)
    print(f"# config:   {args.config}")
    print(f"# events:   {args.events}")
    print(f"# nodes:    {len(cfg.get('nodes', []))}")
    print(f"# duration: {duration_ms} ms")
    if warmup_end_ms > 0:
        analyzed_ms = max(0, duration_ms - warmup_end_ms)
        print(f"# warmup:   skipping {warmup_end_ms} ms (warmup_end event); "
              f"analyzing {analyzed_ms} ms of steady state")
    else:
        analyzed_ms = duration_ms
        print(f"# warmup:   none (no warmup_end event in stream)")

    # One pre-pass over the file: pkt_id → label map. All sections that
    # need to classify rx events by their origin-tx label use this.
    pkt_label = build_pkt_label_map(args.events)

    ctrl = section_control_plane(args.events, warmup_end_ms)
    print_section_3(ctrl)

    print_section_6(section_per_class_sf(args.events, warmup_end_ms),
                    ctrl["total_air_ms"])

    path = section_path_optimality(cfg, args.events, warmup_end_ms)
    print_section_1(path)

    sf = section_sf_optimality(cfg, args.events, pkt_label, warmup_end_ms)
    print_section_2(sf)

    conc = section_concurrency(args.events, warmup_end_ms)
    print_section_4(conc)

    print_section_5(ctrl)

    print_section_7(section_drops(args.events, warmup_end_ms))

    deliv = section_delivery_breakdown(args.events, warmup_end_ms)
    print_section_8(deliv)

    print_section_9(section_latency(args.events, warmup_end_ms))

    print_section_10(section_per_node_tx(args.events, cfg, warmup_end_ms),
                     ctrl["total_air_ms"])

    print_section_11(section_routing_churn(args.events, warmup_end_ms),
                     analyzed_ms)

    print_section_12(section_cold_start(deliv))

    print_section_13(section_bcn_effective(args.events, warmup_end_ms))

    print_section_14(section_lifetime_waste(deliv))

    print_section_15(section_duty_cycle(cfg, args.events, warmup_end_ms))

    print_section_16(section_routing_diversity(args.events, warmup_end_ms))

    print_section_17(section_anti_spam(args.events, cfg, warmup_end_ms))

    print_section_18(section_e2e_ack(args.events, cfg, warmup_end_ms))

    print_section_19(section_hop_limit(cfg, args.events, warmup_end_ms))

    print_section_20(section_nack_reasons(args.events, cfg, warmup_end_ms))

    print_section_21(section_budget_tier(args.events, cfg, warmup_end_ms))

    print_section_22(section_tier_routing(args.events, cfg, warmup_end_ms))

    print_section_23(section_inter_layer(args.events, cfg, warmup_end_ms))

    print_headline(cfg, args.events, ctrl, warmup_end_ms)


if __name__ == "__main__":
    main()
