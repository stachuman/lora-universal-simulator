"""Smoke test for interactive_manager — spawn lus -i, wait for readiness, send a step."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest

from server.services.interactive_manager import InteractiveSessionManager


REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"


@pytest.mark.asyncio
async def test_create_step_close(tmp_path):
    if not LUS.exists():
        pytest.skip("lus binary not built")

    mgr = InteractiveSessionManager(
        data_dir=tmp_path,
        orchestrator_path=str(LUS),
        max_sessions=1,
        idle_timeout_s=30,
        cwd=REPO_ROOT,
    )

    # Minimal viable lus config — one node, short duration.
    cfg = {
        "_name": "interactive-smoke",
        "simulation": {
            "duration_ms": 5000,
            "step_ms": 1,
            "warmup_ms": 0,
            "radio": {"sf": 7, "bw": 250, "cr": 5},
        },
        "nodes": [{"name": "n1", "script": "examples/quiet.lua", "config": {}}],
        "topology": {"links": []},
        "commands": [],
        "expect": [],
    }

    sess = await mgr.create_session(cfg)
    sess_id = sess.id

    # Wait for the session to become ready (the :nodes probe must complete).
    # The stdout reader sets status="ready" asynchronously; poll briefly.
    for _ in range(50):
        if mgr.get_session(sess_id).status == "ready":
            break
        await asyncio.sleep(0.1)

    session = mgr.get_session(sess_id)
    assert session.status == "ready", (
        f"Session did not reach 'ready'; status={session.status}, error={session.error}"
    )
    assert len(session.nodes) >= 1, "Expected at least one node from :nodes probe"

    # Send ":step 1" — wait for response dict
    response = await mgr.send_command(sess_id, ":step 1")
    assert response is not None, "send_command returned None"
    assert "error" not in response, f"send_command returned error: {response}"
    # The response should contain stepped_to_ms from the ``-> t=Nms`` line
    assert "stepped_to_ms" in response, (
        f"Expected 'stepped_to_ms' in response, got: {response}"
    )
    assert response["stepped_to_ms"] >= 1

    await mgr.close_session(sess_id)
    assert mgr.get_session(sess_id).status == "closed"
