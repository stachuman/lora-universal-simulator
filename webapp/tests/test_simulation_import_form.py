"""String-presence guard for the import-run field in simulation.html.
Behavior verification is manual (no headless browser)."""

from __future__ import annotations

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app


@pytest.mark.asyncio
async def test_simulation_form_has_import_field():
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.get("/static/simulation.html")
            assert r.status_code == 200, r.text
            html = r.text

    assert 'id="result-file-path"' in html, "result-path field missing"
    assert "/api/sims/import" in html, "import endpoint POST missing"
    assert "events_path: resultPath" in html, "events_path payload not wired"
