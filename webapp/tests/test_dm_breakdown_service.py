"""compute_breakdown() must match the CANONICAL CLI tool's --json output.

This is the anti-drift pin for the 2026-07-25 de-fork: the webapp used to carry
its own 1610-line copy of the analysis, which went stale. Now it calls MeshRoute's
`tools/dm_delivery_breakdown.py` — located by `tools/meshroute_canonical.py`, NOT
copied into this repo — so this test compares the service payload against that
same script run as a subprocess."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

from server.services.dm_breakdown import compute_breakdown

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


def _canonical_cli() -> Path:
    """The one canonical script, resolved exactly as the service resolves it."""
    spec = importlib.util.spec_from_file_location(
        "meshroute_canonical", str(REPO_ROOT / "tools" / "meshroute_canonical.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.canonical_tool_path()


@pytest.fixture(scope="module")
def s13_events(tmp_path_factory):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s13 scenario missing")
    events = tmp_path_factory.mktemp("dmbd") / "s13.ndjson"
    subprocess.run([str(LUS), str(SCENARIO), str(events)],
                   check=True, capture_output=True)
    return events


def test_compute_breakdown_matches_cli(s13_events):
    got = compute_breakdown(str(SCENARIO), str(s13_events),
                            mode="all", detail=True)
    cli = subprocess.run(
        [sys.executable, str(_canonical_cli()), str(SCENARIO), str(s13_events),
         "--json", "--detail"],
        check=True, capture_output=True, text=True)
    expected = json.loads(cli.stdout)
    # The canonical `--json` view is summary/messages/channels. The service adds
    # `cross_layer` (the authoritative cross-layer metric, which --json cannot
    # express) and `warnings` (the tool's stdout diagnostics, captured rather
    # than printed) — asserted separately below.
    assert set(got) - set(expected) == {"cross_layer", "warnings"}
    for key in expected:
        assert got[key] == expected[key], f"payload key {key!r} diverged from the CLI"
    # s13 is single-layer, so the cross-layer denominator is legitimately zero —
    # the point is that the KEY exists and is populated by the shared analysis.
    assert set(got["cross_layer"]) >= {"sent", "arrived", "enqueued", "no_gateway"}
    assert got["warnings"] == []


def test_cross_layer_and_aliasing_reach_the_webapp(tmp_path):
    """The two measurements the stale fork could not make, on the scenario that
    exercises both. Pre-de-fork this reported same-layer 2/2 with one row
    mislabelled `l5_seed(1)`, no cross-layer key and no ambiguity warning.

    Uses MeshRoute's own s10 (the only corpus scenario with a genuine
    non-sentinel duplicate short id — BASELINE 2026-07-25g), found through the
    same resolver the service uses, so no path is hardcoded here."""
    if not LUS.exists():
        pytest.skip("lus binary missing")
    scenario = _canonical_cli().parents[1] / "simulation" / "s10_two_layer_separation.json"
    if not scenario.exists():
        pytest.skip(f"MeshRoute scenario not available at {scenario}")
    events = tmp_path / "s10.ndjson"
    subprocess.run([str(LUS), "-e", "meshroute", str(scenario), str(events)],
                   check=True, capture_output=True)

    got = compute_breakdown(str(scenario), str(events), mode="all", detail=True)

    # Same-layer: all four configured sends visible as four distinct rows.
    rows = got["summary"]
    assert len(rows) == 4, [r["dst"] for r in rows]
    assert sum(r["sent"] for r in rows) == 4
    assert sum(r["arrived"] for r in rows) == 4
    # Cross-layer: the authoritative tx_enqueue_xl-based metric, 2/2.
    assert got["cross_layer"]["sent"] == 2
    assert got["cross_layer"]["arrived"] == 2
    # Aliasing: reported loudly. Asserted on the CONTENT the warning must carry
    # (the colliding id and every name sharing it), not on prose wording — it is
    # derived from the canonical module's structured ALIASED_IDS, so neither a
    # reworded block nor a stdout->stderr move can empty it unnoticed.
    warns = got["warnings"]
    assert any("AMBIGUOUS NODE IDS" in w for w in warns), warns
    alias_line = next((w for w in warns if "l4_seed" in w and "l5_seed" in w), None)
    assert alias_line is not None, warns
    assert "id 1" in alias_line, alias_line
    # ...and every candidate name is rendered in the rows, not just one.
    assert all("l4_seed|l5_seed(1)" == r["origin"] for r in rows), rows
