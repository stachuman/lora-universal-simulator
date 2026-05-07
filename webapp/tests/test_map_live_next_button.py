"""Regression test: assert the Next-event button feature is present in
map_live.html. This is a string-presence test, not a behavioral test —
behavior verification is manual (no headless browser harness)."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.mark.asyncio
async def test_map_live_has_next_button():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.get("/static/map_live.html")
            assert r.status_code == 200, r.text
            html = r.text

    # Button markup
    assert 'id="btn-next"' in html, "Next button markup missing"
    # Filter constant — protocol-agnostic packet-level types
    assert "NEXT_EVENT_FILTER" in html, "NEXT_EVENT_FILTER constant missing"
    for ty in ("'tx'", "'rx'", "'collision'",
               "'drop_weak'", "'drop_sf_mismatch'",
               "'drop_halfduplex'", "'drop_loss'", "'tx_deferred'"):
        assert ty in html, f"NEXT_EVENT_FILTER missing type {ty}"
    # Refactored helper
    assert "fireEventsUpTo" in html, "fireEventsUpTo helper missing"
    # Iframe sync postMessage
    assert "mlv-scrub-time" in html, "iframe scrub-time postMessage missing"
    # Click handler is wired (cheap regression guard against accidental removal)
    assert "btnNext.addEventListener('click', onNextEvent)" in html, \
        "Next button click handler not wired"
    # End-of-stream finalizer dedups three call-sites
    assert "finalizeEndOfStream" in html, "finalizeEndOfStream helper missing"
