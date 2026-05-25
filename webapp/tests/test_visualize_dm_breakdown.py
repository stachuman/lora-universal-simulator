"""String-presence regression guard for the Delivery panel wiring in
visualize.html. Behavior verification is manual (no headless browser)."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.mark.asyncio
async def test_visualize_has_delivery_panel():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.get("/static/visualize.html")
            assert r.status_code == 200, r.text
            html = r.text

    assert 'id="btn-delivery"' in html, "Delivery button markup missing"
    assert "loadDeliveryBreakdown" in html, "loadDeliveryBreakdown missing"
    assert "renderDeliveryPanel" in html, "renderDeliveryPanel missing"
    assert "/dm_breakdown" in html, "dm_breakdown fetch URL missing"
    assert "centerViewportOn" in html, "centerViewportOn helper missing"
    assert "btn-delivery').addEventListener" in html, "Delivery click handler not wired"
