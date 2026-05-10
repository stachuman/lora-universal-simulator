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
    # data_tx events for that (origin, origin_seq), then deduping by
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
    data_tx_chain = defaultdict(list)  # (origin, seq) -> list of (t, src_id, next_id)
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type")
        d = e.get("data", {})
        if et == "delivered":
            delivered.append(e)
        elif et == "data_tx":
            origin = d.get("origin")
            seq = d.get("origin_seq")
            if origin is not None and seq is not None:
                # data_tx uses "to" for next-hop in dv_dual_sf.lua;
                # accept "next" as a fallback for any future scripts
                # that follow the rts_tx field naming.
                nxt = d.get("to", d.get("next"))
                data_tx_chain[(origin, seq)].append((e["time_ms"], e["node"], nxt))

    deltas = []
    detail = []
    for ev in delivered:
        d = ev["data"]
        origin = d.get("origin")
        seq = d.get("origin_seq")
        chain = data_tx_chain.get((origin, seq), [])
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

    A message is identified by (origin, origin_seq). path_cascade_exhausted
    fires at the originator when every fallback next-hop has been tried and
    none worked; the `trigger` field in its data names the proximate cause.
    "unresolved" = a tx_enqueue at the originator with no terminal event,
    typically still in flight at sim_end or quietly dropped along the way.
    """
    enqueued: dict = {}    # (origin, seq) -> first enqueue time at originator
    delivered: dict = {}   # (origin, seq) -> first delivered time
    exhausted: dict = {}   # (origin, seq) -> trigger string
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        origin = d.get("origin")
        seq = d.get("origin_seq")
        if origin is None or seq is None:
            continue
        key = (origin, seq)
        if et == "tx_enqueue" and e.get("node") == origin and key not in enqueued:
            # Filter to the originator's own enqueue. Forwarder enqueues
            # also fire (depth>=1) and would inflate the "sent" count.
            enqueued[key] = e.get("time_ms", 0)
        elif et == "delivered" and key not in delivered:
            delivered[key] = e.get("time_ms", 0)
        elif et == "path_cascade_exhausted" and key not in exhausted:
            exhausted[key] = d.get("trigger", "?")
    n_enq = len(enqueued)
    n_del = sum(1 for k in delivered if k in enqueued)
    n_exh = sum(1 for k in exhausted if k in enqueued and k not in delivered)
    n_unresolved = n_enq - n_del - n_exh
    triggers: Counter = Counter(
        v for k, v in exhausted.items() if k in enqueued and k not in delivered
    )
    return {
        "n_enqueued": n_enq,
        "n_delivered": n_del,
        "n_exhausted": n_exh,
        "n_unresolved": max(0, n_unresolved),
        "exhausted_triggers": triggers,
        "enqueued_times": enqueued,
        "delivered_keys": set(delivered.keys()),
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
    delivered (origin, seq). Useful for spotting protocols that "deliver"
    well only when given many seconds of slack.
    """
    enqueued: dict = {}
    latencies: list[int] = []
    for e in iter_events(events_path, since_ms):
        if e.get("type") != "script_emit":
            continue
        et = e.get("emit_type", "")
        d = e.get("data") or {}
        origin = d.get("origin")
        seq = d.get("origin_seq")
        if origin is None or seq is None:
            continue
        key = (origin, seq)
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
        if cmd.startswith("send ") and at_ms >= since_ms:
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

    print_headline(cfg, args.events, ctrl, warmup_end_ms)


if __name__ == "__main__":
    main()
