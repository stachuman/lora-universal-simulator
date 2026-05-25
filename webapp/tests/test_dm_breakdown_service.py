"""compute_breakdown() must match the canonical CLI tool's --json output.

This pins the webapp service to tools/dm_delivery_breakdown.py so the two
never silently diverge."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from server.services.dm_breakdown import compute_breakdown

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
CLI = REPO_ROOT / "tools" / "dm_delivery_breakdown.py"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


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
        [sys.executable, str(CLI), str(SCENARIO), str(s13_events),
         "--json", "--detail"],
        check=True, capture_output=True, text=True)
    expected = json.loads(cli.stdout)
    assert got == expected
