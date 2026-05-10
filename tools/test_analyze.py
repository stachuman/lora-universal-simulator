"""Unit tests for tools/analyze.py.

The analyzer reads NDJSON event streams produced by the lus runtime. We
fabricate small streams in tmp files and assert each metric section
produces the expected numbers, with focus on the corner that motivated
the rewrite: rx events get classified by joining to their tx label via
the packet id, so an rx whose tx fired pre-warmup still classifies.

Run with:  pytest tools/test_analyze.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

import pytest

# tools/ isn't a package; add it to sys.path so `import analyze` works.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402


# ---- helpers --------------------------------------------------------------

def _write_ndjson(events: list[dict]) -> str:
    fd, path = tempfile.mkstemp(suffix=".ndjson")
    with os.fdopen(fd, "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    return path


def _tx(pkt: str, label: str, t_ms: int, sf: int = 10, air: int = 100,
        node: int = 0) -> dict:
    return {"type": "tx", "time_ms": t_ms, "pkt": pkt, "label": label,
            "sf": sf, "airtime_ms": air, "bw_hz": 62000, "cr": 5,
            "node": node}


def _rx(pkt: str, t_ms: int, sf: int = 10, snr: float = 5.0,
        air: int = 100, frm: str = "a", to: str = "b") -> dict:
    return {"type": "rx", "time_ms": t_ms, "pkt": pkt, "sf": sf,
            "snr": snr, "airtime_ms": air, "bw_hz": 62000, "cr": 5,
            "from": frm, "to": to}


def _emit(node: int, t_ms: int, et: str, **data) -> dict:
    return {"type": "script_emit", "node": node, "time_ms": t_ms,
            "emit_type": et, "data": data}


# ---- pkt_id → label map --------------------------------------------------

def test_build_pkt_label_map_includes_pre_warmup_tx():
    events = [
        _tx("aa", "BCN", t_ms=10),       # pre-warmup
        {"type": "warmup_end", "time_ms": 1000},
        _tx("bb", "DATA", t_ms=2000),
        _rx("aa", t_ms=2050),            # rx of the pre-warmup tx
    ]
    path = _write_ndjson(events)
    try:
        m = analyze.build_pkt_label_map(path)
        assert m == {"aa": "BCN", "bb": "DATA"}, (
            "map must cover pre-warmup tx events so post-warmup rx of "
            "those packets can still be classified"
        )
    finally:
        os.unlink(path)


# ---- SF optimality (DATA-only filter) ------------------------------------

def test_sf_optimality_ignores_control_plane_rx():
    """The bug this rewrite fixes: rx events at routing_sf=10 (a value that
    also happens to be in allowed_data_sfs) used to be counted as data legs
    and swamped the metric. With the label join, only DATA legs count."""
    cfg = {
        "simulation": {"radio": {"bw": 62, "cr": 5}},
        "nodes": [
            {"name": "a", "config": {"allowed_data_sfs": [8, 9, 10]}},
            {"name": "b", "config": {"allowed_data_sfs": [8, 9, 10]}},
        ],
    }
    events = [
        # 100 BCN rx at SF10 with high SNR → would have polluted the old
        # metric (count, +0% optimal, +100% "two slower than SF7").
        *[_tx(f"b{i}", "BCN", t_ms=1000 + i, sf=10) for i in range(100)],
        *[_rx(f"b{i}", t_ms=1100 + i, sf=10, snr=20.0) for i in range(100)],
        # 4 actual DATA rx — 2 optimal (SF8 with high SNR), 2 too slow
        # (SF10 with high SNR; could have been SF8 + 5dB margin).
        _tx("d1", "DATA", t_ms=2000, sf=8),
        _rx("d1", t_ms=2050, sf=8, snr=20.0),   # optimal
        _tx("d2", "DATA", t_ms=2100, sf=8),
        _rx("d2", t_ms=2150, sf=8, snr=20.0),   # optimal
        _tx("d3", "DATA", t_ms=2200, sf=10),
        _rx("d3", t_ms=2250, sf=10, snr=20.0),  # 2 SF too slow
        _tx("d4", "DATA", t_ms=2300, sf=10),
        _rx("d4", t_ms=2350, sf=10, snr=20.0),  # 2 SF too slow
    ]
    path = _write_ndjson(events)
    try:
        m = analyze.build_pkt_label_map(path)
        r = analyze.section_sf_optimality(cfg, path, m, since_ms=0)
        assert len(r["rows"]) == 4, (
            f"expected 4 DATA rx events, got {len(r['rows'])} — "
            "control-plane rx must be filtered out"
        )
        sfs_used = sorted(sf for sf, *_ in r["rows"])
        assert sfs_used == [8, 8, 10, 10]
    finally:
        os.unlink(path)


# ---- per-class SF distribution -------------------------------------------

def test_per_class_sf_aggregates_by_label_and_sf():
    events = [
        _tx("a", "BCN", t_ms=1000, sf=10, air=4500),
        _tx("b", "BCN", t_ms=2000, sf=10, air=4600),
        _tx("c", "DATA", t_ms=3000, sf=8, air=280),
        _tx("d", "DATA", t_ms=3100, sf=10, air=1100),
    ]
    path = _write_ndjson(events)
    try:
        r = analyze.section_per_class_sf(path)
        assert r["BCN"][10] == [2, 9100]
        assert r["DATA"][8]  == [1, 280]
        assert r["DATA"][10] == [1, 1100]
    finally:
        os.unlink(path)


# ---- drop histogram ------------------------------------------------------

def test_drop_histogram_counts_known_types():
    events = [
        {"type": "warmup_end", "time_ms": 1000},
        {"type": "collision", "time_ms": 2000},
        {"type": "collision", "time_ms": 2100},
        {"type": "drop_weak", "time_ms": 2200},
        {"type": "drop_sf_mismatch", "time_ms": 2300},
        {"type": "rx",         "time_ms": 2400, "pkt": "x", "sf": 8,
         "snr": 5.0, "airtime_ms": 100, "from": "a", "to": "b"},
        {"type": "this_is_unknown_drop", "time_ms": 2500},  # not in DROP_TYPES → ignored
    ]
    path = _write_ndjson(events)
    try:
        r = analyze.section_drops(path, since_ms=1000)
        assert r["collision"] == 2
        assert r["drop_weak"] == 1
        assert r["drop_sf_mismatch"] == 1
        assert "this_is_unknown_drop" not in r
    finally:
        os.unlink(path)


# ---- delivery breakdown --------------------------------------------------

def test_delivery_breakdown_classifies_by_outcome():
    """Three originator-side enqueues:
       - msg (1, 1) → delivered
       - msg (1, 2) → path_cascade_exhausted with trigger=rts_giveup
       - msg (1, 3) → no terminal event (unresolved)
    """
    events = [
        # msg (origin=1, seq=1): originator enqueue + delivered
        _emit(node=1, t_ms=1000, et="tx_enqueue",
              origin=1, origin_seq=1, dst=2, payload="hi-1"),
        _emit(node=2, t_ms=1500, et="delivered",
              origin=1, origin_seq=1, payload="hi-1"),
        # Forwarder enqueue at node=3 — must NOT count as a separate user msg.
        _emit(node=3, t_ms=1100, et="tx_enqueue",
              origin=1, origin_seq=1, depth=1, dst=2, payload="hi-1"),

        # msg (origin=1, seq=2): originator enqueue + path_cascade_exhausted
        _emit(node=1, t_ms=2000, et="tx_enqueue",
              origin=1, origin_seq=2, dst=4, payload="hi-2"),
        _emit(node=1, t_ms=2500, et="path_cascade_exhausted",
              origin=1, origin_seq=2, dst=4, trigger="rts_giveup",
              tried=[3, 5]),

        # msg (origin=1, seq=3): originator enqueue, no terminal
        _emit(node=1, t_ms=3000, et="tx_enqueue",
              origin=1, origin_seq=3, dst=6, payload="hi-3"),
    ]
    path = _write_ndjson(events)
    try:
        r = analyze.section_delivery_breakdown(path)
        assert r["n_enqueued"] == 3, (
            "forwarder-side tx_enqueue (node != origin) must not inflate the "
            "originator-message count"
        )
        assert r["n_delivered"] == 1
        assert r["n_exhausted"] == 1
        assert r["n_unresolved"] == 1
        assert dict(r["exhausted_triggers"]) == {"rts_giveup": 1}
    finally:
        os.unlink(path)


# ---- latency -------------------------------------------------------------

def test_latency_uses_originator_enqueue_time():
    events = [
        _emit(node=1, t_ms=1000, et="tx_enqueue",
              origin=1, origin_seq=1, payload="x"),
        # Forwarder also enqueues — latency MUST measure from originator.
        _emit(node=3, t_ms=1100, et="tx_enqueue",
              origin=1, origin_seq=1, depth=1, payload="x"),
        _emit(node=2, t_ms=1500, et="delivered",
              origin=1, origin_seq=1, payload="x"),
    ]
    path = _write_ndjson(events)
    try:
        lat = analyze.section_latency(path)
        assert lat == [500], f"expected [500] from originator-side, got {lat}"
    finally:
        os.unlink(path)


# ---- routing churn -------------------------------------------------------

def test_routing_churn_counts_only_routing_emits():
    events = [
        _emit(node=1, t_ms=1000, et="rt_aged",   dst=2),
        _emit(node=1, t_ms=1100, et="rt_update", dst=2),
        _emit(node=1, t_ms=1200, et="rt_prune",  dst=3),
        _emit(node=1, t_ms=1300, et="beacon_rx"),  # not routing churn
    ]
    path = _write_ndjson(events)
    try:
        r = analyze.section_routing_churn(path)
        assert r == {"rt_aged": 1, "rt_update": 1, "rt_prune": 1}
    finally:
        os.unlink(path)


# ---- cold-start curve ----------------------------------------------------

def test_cold_start_buckets_by_enqueue_time():
    deliv = {
        "enqueued_times": {
            (1, 1): 1000,
            (1, 2): 2000,
            (1, 3): 3000,
            (1, 4): 4000,
        },
        "delivered_keys": {(1, 3), (1, 4)},
    }
    rows = analyze.section_cold_start(deliv, n_buckets=2)
    assert len(rows) == 2
    # First bucket: msgs 1+2, neither delivered.
    assert rows[0]["sent"] == 2 and rows[0]["delivered"] == 0
    # Second bucket: msgs 3+4, both delivered.
    assert rows[1]["sent"] == 2 and rows[1]["delivered"] == 2


# ---- BCN effectiveness ---------------------------------------------------

def test_bcn_effective_ratio():
    events = [
        _emit(node=1, t_ms=1000, et="beacon_rx"),
        _emit(node=1, t_ms=1100, et="beacon_rx"),
        _emit(node=1, t_ms=1200, et="rt_update"),
    ]
    path = _write_ndjson(events)
    try:
        r = analyze.section_bcn_effective(path)
        assert r == {"beacon_rx": 2, "rt_update": 1}
    finally:
        os.unlink(path)


# ---- per-node TX hot spots -----------------------------------------------

def test_per_node_tx_resolves_int_node_ids():
    """When tx.node is an integer index, resolve it via cfg.nodes."""
    cfg = {"nodes": [{"name": "alice"}, {"name": "bob"}, {"name": "carol"}]}
    events = [
        _tx("a", "BCN", t_ms=1000, air=4000, node=0),
        _tx("b", "BCN", t_ms=1100, air=4000, node=0),
        _tx("c", "DATA", t_ms=1200, air=300, node=1),
    ]
    path = _write_ndjson(events)
    try:
        rows = analyze.section_per_node_tx(path, cfg, top_n=10)
        assert rows[0] == ("alice", 8000)
        assert rows[1] == ("bob", 300)
        assert all(name != "carol" for name, _ in rows)
    finally:
        os.unlink(path)


def test_per_node_tx_accepts_string_node_names():
    """The runtime currently emits tx.node as the name string; the analyzer
    must accept that form too without prefixing '#' to the label."""
    cfg = {"nodes": [{"name": "alice"}, {"name": "bob"}]}
    events = [
        _tx("a", "BCN", t_ms=1000, air=4000, node="alice"),
        _tx("b", "DATA", t_ms=1100, air=300, node="bob"),
    ]
    path = _write_ndjson(events)
    try:
        rows = analyze.section_per_node_tx(path, cfg, top_n=10)
        assert rows[0] == ("alice", 4000)
        assert rows[1] == ("bob", 300)
    finally:
        os.unlink(path)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
