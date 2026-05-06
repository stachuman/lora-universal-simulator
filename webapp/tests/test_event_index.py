"""Tests for event_index — fast NDJSON time-range slicing."""

from __future__ import annotations

import json
from pathlib import Path

from server.services.event_index import EventIndex, EventIndexCache


def _make_events(tmp_path: Path) -> Path:
    """Write a small NDJSON file with a mix of metadata and queryable events.

    sim_start / sim_end are consumed as metadata by _index_event and do NOT
    appear in EventIndex.events — they update sim_info instead.  The three
    remaining lines (tx, rx, script_log) become the queryable events.
    """
    p = tmp_path / "events.ndjson"
    lines = [
        {"type": "sim_start", "time_ms": 0},
        {"type": "tx", "time_ms": 1000, "node": "alice"},
        {"type": "rx", "time_ms": 1023, "from": "alice", "to": "bob"},
        {"type": "script_log", "time_ms": 5000, "node": "alice", "msg": "hello"},
        {"type": "sim_end", "time_ms": 60000},
    ]
    p.write_text("\n".join(json.dumps(e) for e in lines) + "\n")
    return p


def test_full_range_returns_all_events(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(str(p))
    # sim_start and sim_end are metadata-only; 3 queryable events remain
    events = idx.query_time_range(0, 60_000)
    assert len(events) == 3
    assert events[0]["type"] == "tx"
    assert events[-1]["type"] == "script_log"


def test_partial_range_filters_correctly(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(str(p))
    events = idx.query_time_range(500, 4000)
    types = [e["type"] for e in events]
    assert types == ["tx", "rx"]


def test_empty_range_returns_no_events(tmp_path):
    p = _make_events(tmp_path)
    idx = EventIndex(str(p))
    events = idx.query_time_range(2000, 4000)
    assert events == []


def test_cache_returns_same_instance(tmp_path):
    p = _make_events(tmp_path)
    cache = EventIndexCache(max_size=2)
    a = cache.get("sim1", str(p))
    b = cache.get("sim1", str(p))
    assert a is b


def test_cache_evicts_lru(tmp_path):
    dir_a = tmp_path / "a"
    dir_b = tmp_path / "b"
    dir_a.mkdir()
    dir_b.mkdir()

    p1 = _make_events(dir_a)
    p2 = dir_b / "events.ndjson"
    p2.write_text(json.dumps({"type": "x", "time_ms": 0}) + "\n")

    cache = EventIndexCache(max_size=1)
    idx1 = cache.get("s1", str(p1))
    cache.get("s2", str(p2))
    # s1 should have been evicted; getting it again creates a new instance.
    again = cache.get("s1", str(p1))
    assert again is not None
    assert again is not idx1
