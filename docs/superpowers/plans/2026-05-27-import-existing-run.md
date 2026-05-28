# Import Existing Run (config + result file, no lus) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the webapp register a *completed* simulation from an existing config JSON + a server-side result (events.ndjson) file path, skipping the lus run.

**Architecture:** A dedicated `SimManager.import_sim()` writes the config and copies the events file into a self-contained sim dir marked completed; a `POST /api/sims/import` endpoint validates the config (same validator as the run path) and the events path, then calls it. The existing New Simulation form gains one optional "Result file path" field that routes the submit to the import endpoint when filled.

**Tech Stack:** Python 3.11 / FastAPI / pytest+httpx (asgi-lifespan); vanilla-JS form (`simulation.html`).

**Spec:** `docs/superpowers/specs/2026-05-27-import-existing-run-design.md`

---

## File Structure

- **Modify** `webapp/server/services/sim_manager.py` — add `import_sim()` near `create_sim()`. Reuses `_sim_dir`, `_generate_id`, `_save_status`, the `SimRecord` dataclass, and the already-imported `shutil`/`time`/`json`.
- **Modify** `webapp/server/routers/simulations.py` — extend the request models and add the `POST /import` endpoint reusing `validate_lus_config` and `SimManager`.
- **Modify** `webapp/static/simulation.html` — add the optional result-path field and branch `submitSim()`.
- **Test** `webapp/tests/test_sim_manager_import.py` — `import_sim` unit test.
- **Test** `webapp/tests/test_dm_breakdown_endpoint.py`-style new file `webapp/tests/test_import_endpoint.py` — endpoint happy path + 400 negative cases.
- **Test** `webapp/tests/test_simulation_import_form.py` — HTML string-presence guard.

---

## Task 1: `SimManager.import_sim()`

**Files:**
- Modify: `webapp/server/services/sim_manager.py` (add method after `create_sim`, which ends at the `return sim_id` near line 177)
- Test: `webapp/tests/test_sim_manager_import.py`

- [ ] **Step 1: Write the failing test**

Create `webapp/tests/test_sim_manager_import.py`:

```python
"""Unit test for SimManager.import_sim — registers a completed sim from an
existing config dict + events file, without running lus."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from server.services.sim_manager import SimManager

REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.asyncio
async def test_import_sim_creates_completed_sim(tmp_path):
    # A minimal events file and config — content correctness is not import_sim's
    # job; it only copies + registers.
    src_events = tmp_path / "src.ndjson"
    src_events.write_text(
        '{"type":"sim_start","time_ms":0}\n'
        '{"type":"tx","time_ms":10,"node":"a"}\n'
        '{"type":"sim_end","time_ms":20}\n'
    )
    cfg = {"simulation": {"duration_ms": 20}, "nodes": [], "topology": {"links": []}}

    mgr = SimManager(data_dir=tmp_path, orchestrator_path="/nonexistent/lus",
                     max_concurrent=1)
    sim_id = await mgr.import_sim(cfg, str(src_events))

    assert sim_id
    rec = mgr.get_sim(sim_id)
    assert rec is not None and rec.status == "completed"
    assert rec.completed_at is not None

    sim_dir = tmp_path / "simulations" / sim_id
    assert (sim_dir / "config.json").exists()
    assert (sim_dir / "events.ndjson").exists()
    # config round-trips
    assert json.loads((sim_dir / "config.json").read_text()) == cfg
    # events copied verbatim
    assert (sim_dir / "events.ndjson").read_text() == src_events.read_text()
    # path helpers resolve
    assert mgr.get_events_path(sim_id) == sim_dir / "events.ndjson"
    assert mgr.get_config_path(sim_id) == sim_dir / "config.json"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd webapp && python -m pytest tests/test_sim_manager_import.py -v`
Expected: FAIL with `AttributeError: 'SimManager' object has no attribute 'import_sim'`.

- [ ] **Step 3: Implement `import_sim`**

In `webapp/server/services/sim_manager.py`, add this method immediately after `create_sim` (after its `return sim_id`). `shutil`, `time`, and `json` are already imported at the top of the file; `SimRecord` is defined in the same module.

```python
    async def import_sim(self, config: dict, events_path: str) -> str:
        """Register a *completed* sim from an existing config + events file.

        Writes config.json, copies the events file into the sim dir as
        events.ndjson, and marks the sim completed — no lus run. The caller
        (router) is responsible for validating config and events_path.
        """
        sim_id = self._generate_id()
        sim_dir = self._sim_dir(sim_id)
        sim_dir.mkdir(parents=True, exist_ok=True)

        config_path = sim_dir / "config.json"
        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        shutil.copyfile(events_path, sim_dir / "events.ndjson")

        now = time.time()
        record = SimRecord(
            id=sim_id,
            status="completed",
            created_at=now,
            completed_at=now,
            config=config,
        )
        self._sims[sim_id] = record
        self._save_status(sim_id)
        return sim_id
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd webapp && python -m pytest tests/test_sim_manager_import.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add webapp/server/services/sim_manager.py webapp/tests/test_sim_manager_import.py
git commit -m "$(cat <<'EOF'
webapp: SimManager.import_sim — register a completed run from disk

Writes config.json and copies an existing events file into a
self-contained sim dir marked completed, with no lus subprocess. The
startup scan already treats such dirs as completed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `POST /api/sims/import` endpoint

**Files:**
- Modify: `webapp/server/routers/simulations.py` (add request model near `CreateSimRequest` at line 31; add endpoint after `create_sim`)
- Test: `webapp/tests/test_import_endpoint.py`

- [ ] **Step 1: Write the failing test**

Create `webapp/tests/test_import_endpoint.py`:

```python
"""Integration tests for POST /api/sims/import."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


@pytest.mark.asyncio
async def test_import_happy_path(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s13 scenario missing")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    # Produce a real events file out-of-band (the thing a user would import).
    events = tmp_path / "s13.ndjson"
    subprocess.run([str(LUS), str(SCENARIO), str(events)],
                   check=True, capture_output=True)
    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(events)})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]

            s = await client.get(f"/api/sims/{sim_id}")
            assert s.json()["status"] == "completed", s.text

            ev = await client.get(f"/api/sims/{sim_id}/events",
                                   params={"from": 0, "to": 60_000_000})
            assert ev.status_code == 200
            assert ev.json()["count"] > 0


@pytest.mark.asyncio
async def test_import_missing_events_path_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(tmp_path / "nope.ndjson")})
            assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_import_empty_events_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    empty = tmp_path / "empty.ndjson"
    empty.write_text("")
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(empty)})
            assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_import_non_json_events_400(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    bad = tmp_path / "bad.ndjson"
    bad.write_text("this is not json\n")
    cfg = {"simulation": {"duration_ms": 100,
                          "radio": {"sf": 7, "bw": 250, "cr": 5}},
           "nodes": [], "topology": {"links": []}}
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims/import",
                                   json={"config_json": cfg,
                                         "events_path": str(bad)})
            assert r.status_code == 400, r.text
```

Note: the negative-case configs are intentionally minimal valid lus configs (same shape `test_post_sim_rejects_meshcore_field` uses) so they pass `validate_lus_config` and the test exercises the *events-path* validation, not config validation.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd webapp && python -m pytest tests/test_import_endpoint.py -v`
Expected: FAIL — `POST /api/sims/import` returns 404/405 (route not defined), so the assertions fail.

- [ ] **Step 3: Add the request model**

In `webapp/server/routers/simulations.py`, add after the existing `CreateSimRequest` (line 31-32):

```python
class ImportSimRequest(BaseModel):
    config_json: dict
    events_path: str
```

- [ ] **Step 4: Add the endpoint**

In `webapp/server/routers/simulations.py`, add immediately after the `create_sim` endpoint function. `json` and `os` are already imported at the top; `validate_lus_config` and `SimManager` are already imported.

```python
@router.post("/import", status_code=201, include_in_schema=True)
async def import_sim(body: ImportSimRequest, request: Request):
    """Register a completed sim from an existing config + server-side events
    file, skipping lus. The events file is copied into the sim dir."""
    parsed, errors = validate_lus_config(body.config_json)
    if errors:
        raise HTTPException(status_code=400, detail=errors)

    path = body.events_path
    if not os.path.isfile(path):
        raise HTTPException(status_code=400,
                            detail=f"events file not found: {path}")
    if os.path.getsize(path) == 0:
        raise HTTPException(status_code=400, detail="events file is empty")
    try:
        with open(path) as f:
            first = ""
            for line in f:
                if line.strip():
                    first = line
                    break
        json.loads(first)
    except (OSError, json.JSONDecodeError):
        raise HTTPException(status_code=400,
                            detail=f"not an NDJSON events file: {path}")

    sim_manager: SimManager = request.app.state.sim_manager
    sim_id = await sim_manager.import_sim(body.config_json, path)
    return {"id": sim_id}
```

Note: this endpoint is declared with the literal path `/import`. The existing
`@router.get("/{sim_id}")` is a GET, so there is no method+path collision with
this POST. Place this POST anywhere after `create_sim`; FastAPI matches the
literal `/import` for POST regardless of declaration order relative to GET
`/{sim_id}`.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd webapp && python -m pytest tests/test_import_endpoint.py -v`
Expected: PASS for the three 400 tests always; the happy-path test PASSES with the lus binary present (SKIPs without it — build lus and re-run before marking complete).

- [ ] **Step 6: Commit**

```bash
git add webapp/server/routers/simulations.py webapp/tests/test_import_endpoint.py
git commit -m "$(cat <<'EOF'
webapp: POST /api/sims/import endpoint

Validates the config (same validator as the run path) and the
server-side events path (existing, non-empty, NDJSON first line), then
registers a completed sim via SimManager.import_sim — no lus run.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: New Simulation form — optional result-path field

**Files:**
- Modify: `webapp/static/simulation.html` (form markup near line 230-237; `submitSim` near line 508-543)
- Test: `webapp/tests/test_simulation_import_form.py`

- [ ] **Step 1: Add the result-path field to the form**

In `webapp/static/simulation.html`, inside the `new-sim-card`, add a new row after the existing `file-row` block that closes at line 237 (the one containing "Load from file…"/"Save to file…"). Insert before the "Load from saved topology" row:

```html
      <div class="file-row" style="border-top:1px solid var(--border); padding-top:10px; margin-top:4px; flex-wrap:wrap; gap:8px;">
        <label for="result-file-path" style="width:100%; margin-bottom:4px; font-size:11px; color:var(--text-muted);">
          Or import an existing run — server path to an events.ndjson. If set, lus is NOT run; the file is imported as a completed simulation:
        </label>
        <input type="text" id="result-file-path" class="form-input"
               placeholder="/tmp/s13_analyze.ndjson"
               style="flex:1; min-width:240px; font-size:11px;">
      </div>
```

- [ ] **Step 2: Branch `submitSim()` on the result path**

In `webapp/static/simulation.html`, replace the body of `submitSim` (the `try { const result = await postJSON('/api/sims', { config_json }); ... }` block, lines 528-542) so it routes to the import endpoint when a result path is present. Replace from `try {` through its matching `}` :

```javascript
    const resultPath = document.getElementById('result-file-path').value.trim();

    try {
      let result;
      if (resultPath) {
        result = await postJSON('/api/sims/import',
                                { config_json, events_path: resultPath });
      } else {
        result = await postJSON('/api/sims', { config_json });
      }
      const id = result.id;
      window.location.href = '/static/simulation.html?id=' + encodeURIComponent(id);
    } catch (e) {
      errDiv.textContent = (resultPath ? 'Failed to import run: ' : 'Failed to start simulation: ') + e.message;
      errDiv.classList.remove('hidden');
    }
```

(The `config_json` parse and the empty-textarea guard above this block are unchanged — an import still requires the config in the textarea.)

- [ ] **Step 3: Write the HTML presence test**

Create `webapp/tests/test_simulation_import_form.py`:

```python
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
```

- [ ] **Step 4: Run the presence test**

Run: `cd webapp && python -m pytest tests/test_simulation_import_form.py -v`
Expected: PASS.

- [ ] **Step 5: Manual browser verification**

Start the webapp, open `simulation.html` (New Simulation). Paste an s13 config into the textarea, put the path to a pre-generated events file (e.g. `/tmp/s13_analyze.ndjson`) in the new field, click **Run Simulation**. Confirm: it lands on `simulation.html?id=…` showing the sim **completed** (no lus run), and "View Timeline" opens the swim-lane with the imported events. Then confirm leaving the field blank still runs lus as before. If a browser is unavailable here, say so explicitly rather than claiming success.

- [ ] **Step 6: Commit**

```bash
git add webapp/static/simulation.html webapp/tests/test_simulation_import_form.py
git commit -m "$(cat <<'EOF'
webapp: import-run field in New Simulation form

Adds an optional 'Result file path' input; when set, submitSim posts to
/api/sims/import (no lus) instead of /api/sims. Blank field preserves
the existing run-lus behavior.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Run the full webapp suite: `cd webapp && python -m pytest -q` — expect no new failures.
- [ ] Confirm the three new test files pass (or SKIP only where the lus binary is genuinely absent).

## Notes / decisions baked in

- **Copy, not reference** — `import_sim` copies the events file into the sim dir so all existing readers (`/events`, `/meta`, `/density`, `/dm_breakdown`) work unchanged and the sim survives `/tmp` cleanup.
- **Config still flows as JSON content** via the textarea (which already supports "Load from file"); only the events file is a path. No config-path field (YAGNI).
- **Same config validator** as the run path, so the viewer's assumptions hold.
- **Events validation is shallow** (exists / non-empty / first line is JSON) — we trust the lus run that produced the file.
