"""Regression test: failed and cancelled sims should NOT block the
Timeline / Map / Interactive navigation links. The events.ndjson is
written even when assertions fail, so the user must be able to
inspect the timeline of a failed run.

String-presence test against served HTML (no behavior harness)."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.mark.asyncio
async def test_simulations_list_shows_links_for_failed_and_cancelled():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.get("/static/simulations.html")
            assert r.status_code == 200, r.text
            html = r.text

    # The actions-cell builder must enable Timeline + Map for failed
    # and cancelled sims, not only completed ones.
    assert "sim.status === 'failed'" in html, \
        "simulations.html actions logic does not handle failed sims"
    assert "sim.status === 'cancelled'" in html, \
        "simulations.html actions logic does not handle cancelled sims"


@pytest.mark.asyncio
async def test_simulation_detail_shows_result_links_for_failed_and_cancelled():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.get("/static/simulation.html")
            assert r.status_code == 200, r.text
            html = r.text

    # showResultLinks() must be invoked from the failed AND cancelled
    # branches in BOTH the showFinalState path (initial-load polling)
    # and the SSE done path. We check by counting occurrences:
    # completed/failed/cancelled × 2 paths = at least 6 calls.
    n_calls = html.count("showResultLinks()")
    assert n_calls >= 6, (
        f"showResultLinks() called only {n_calls}× — expected >= 6 "
        "(completed/failed/cancelled in both showFinalState and SSE branches)"
    )
