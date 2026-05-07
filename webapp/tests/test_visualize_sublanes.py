"""Regression test: assert the sub-row rendering symbols are present in
visualize.html. String-presence test — behavior verification is manual."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.mark.asyncio
async def test_visualize_has_sublane_rendering():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.get("/static/visualize.html")
            assert r.status_code == 200, r.text
            html = r.text

    # Sub-row state and lookup
    assert "S.subRows" in html, "S.subRows state field missing"
    assert "S.subRowIndex" in html, "S.subRowIndex lookup missing"
    # Pre-scan helper
    assert "computeSubRowLayout" in html, "computeSubRowLayout helper missing"
    # Per-event sub-row router
    assert "subRowFor" in html, "subRowFor helper missing"
    # Click sidebar gains CR field
    assert "CR " in html, "CR row missing from click-details panel template"
    # Hover tooltip / sidebar must surface SF and BW (kHz)
    assert "kHz" in html, "BW (kHz) suffix missing from sidebar/tooltip"
    assert "SF" in html, "SF reference missing from sidebar/tooltip"
