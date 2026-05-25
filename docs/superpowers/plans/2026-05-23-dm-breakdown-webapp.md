# DM/Channel Delivery Breakdown — Webapp Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface `tools/dm_delivery_breakdown.py`'s per-DM and per-channel delivery analysis inside the webapp swim-lane viewer as a "Delivery" panel, with row-click integration into the existing flight-trace and go-to-time features.

**Architecture:** Copy the CLI tool into `webapp/server/services/dm_breakdown.py` and refactor it to expose a pure `compute_breakdown(config_path, events_path, ...) -> dict` (the existing `--json` path already proves the output is fully serializable). A small mtime-invalidated LRU cache (`DmBreakdownCache`) memoizes the full payload per sim. A new `GET /api/sims/{sim_id}/dm_breakdown` endpoint returns it with ETag/304 support. The frontend fetches once, renders two tables in the sidebar, and reuses `traceFlight()` (DM rows) and a factored `centerViewportOn()` (channel rows).

**Tech Stack:** Python 3.11 / FastAPI / pytest+httpx (asgi-lifespan) backend; vanilla-JS canvas frontend (`visualize.html`).

---

## File Structure

- **Create** `webapp/server/services/dm_breakdown.py` — copy of `tools/dm_delivery_breakdown.py` refactored so the analysis core is importable: adds `build_dm_payload()` (returns the dict that `render_json` used to print), `compute_breakdown()` (the body of `main()` minus argparse/`maybe_run`/printing), and `DmBreakdownCache`. The `main()`/CLI stays for parity but is unused by the webapp.
- **Modify** `webapp/server/routers/simulations.py` — add `GET /{sim_id}/dm_breakdown` reusing `_get_sim_or_404`, `get_config_path`, `get_events_path`, `_cached_json_response`.
- **Modify** `webapp/server/main.py:36` — add `app.state.dm_breakdown_cache = DmBreakdownCache()` in `lifespan`.
- **Modify** `webapp/static/visualize.html` — toolbar "Delivery" button, sidebar table renderer, DM-row→`traceFlight`, channel-row→`centerViewportOn`; factor `centerViewportOn(ms)` out of the existing `gotoTime()`.
- **Test** `webapp/tests/test_dm_breakdown_service.py` — `compute_breakdown()` output is byte-for-byte equal to the canonical CLI `--json --detail` output on s13.
- **Test** `webapp/tests/test_dm_breakdown_endpoint.py` — endpoint returns the breakdown JSON for a completed sim; 409 while running; 404 for unknown id.
- **Test** `webapp/tests/test_visualize_dm_breakdown.py` — HTML string-presence regression guard for the Delivery panel wiring.

**Canonical JSON contract** (what `compute_breakdown(..., mode="all", detail=True)` returns — confirmed from the existing CLI):
```
{
  "summary": [ {origin, dst, sent, arrived, acked, giveup, no_gw,
                in_flight, mean_hops, giveup_reasons, cross_layer}, ... ],
  "messages": [ {origin, dst, ctr, payload, outcome, enqueued_ms,
                 arrived_ms, ack_ms, giveup_ms, giveup_reason,
                 carriers, hops, events:[{t_ms,node,type,fields}],
                 via_gateway?, target?, ...}, ... ],
  "channels": [ {sender, layer, channel_id, payload, sent_at_ms, msg_id,
                 reach, expected, leaks, sources, already_present,
                 first_recv_lat_ms, spread_ms, max_depth, mean_depth,
                 broadcasters, pulls_sent}, ... ]
}
```
`origin`/`dst`/`sender` are `"name(id)"` strings (via `fmt_node`).

---

## Task 1: Service module — refactor CLI tool into an importable function

**Files:**
- Create: `webapp/server/services/dm_breakdown.py`
- Test: `webapp/tests/test_dm_breakdown_service.py`

- [ ] **Step 1: Copy the tool verbatim into the service module**

```bash
cp tools/dm_delivery_breakdown.py webapp/server/services/dm_breakdown.py
```

- [ ] **Step 2: Refactor `render_json` to delegate to a new `build_dm_payload`**

In `webapp/server/services/dm_breakdown.py`, find `def render_json(rows, msgs, pair_filter, id_to_name, detail):` (the function ending with `json.dump(out, sys.stdout, ...)`). Replace the whole function with a pure builder plus a thin CLI wrapper. The body is moved verbatim — only the final `json.dump`/`sys.stdout.write` lines are removed from the builder and kept in the wrapper:

```python
def build_dm_payload(rows, msgs, pair_filter, id_to_name, detail):
    """Build the DM JSON dict (returns it; does not print).

    This is the dict render_json used to dump to stdout — lifted out so
    the webapp can consume it directly instead of capturing stdout."""
    out = {"summary": rows}
    if detail:
        keys = []
        for k, r in msgs.items():
            eff = effective_dst(r)
            if pair_filter is None or (r["origin"], eff) in pair_filter:
                keys.append(k)
        keys.sort(key=lambda k: (k[0], k[1], k[2]))
        messages = []
        for k in keys:
            r = msgs[k]
            def render_fields(fields):
                out_f = {}
                for kk, vv in fields.items():
                    if kk in NODE_ID_FIELDS and isinstance(vv, int):
                        out_f[kk] = fmt_node(vv, id_to_name)
                    else:
                        out_f[kk] = vv
                return out_f
            entry = {
                "origin":      fmt_node(r["origin"], id_to_name),
                "dst":         fmt_node(r["dst"], id_to_name),
                "ctr":         r["ctr"],
                "payload":     r["payload"],
                "outcome":     outcome(r),
                "enqueued_ms": r["enqueued_ms"],
                "arrived_ms":  r["arrived_ms"],
                "ack_ms":      r["ack_ms"],
                "giveup_ms":   r["giveup_ms"],
                "giveup_reason": r["giveup_reason"],
                "carriers":    sorted(fmt_node(c, id_to_name)
                                      for c in r["carriers"]),
                "hops":        len(r["carriers"]),
                "events":      [
                    {"t_ms":   ev["t_ms"],
                     "node":   fmt_node(ev["node"], id_to_name),
                     "type":   ev["type"],
                     "fields": render_fields(ev["fields"])}
                    for ev in r["events"]
                ],
            }
            if r.get("via_gateway"):
                entry["via_gateway"]            = True
                entry["target"]                 = fmt_node(r.get("target_id"),
                                                           id_to_name)
                entry["target_layer_id"]        = r.get("target_layer_id")
                entry["dst_key_hash32"]         = r.get("dst_key_hash32")
                entry["arrival_at_target_ms"]   = r.get("arrival_at_target_ms")
                entry["handoff_enqueued_ms"]    = r.get("handoff_enqueued_ms")
                entry["handoff_drained_ms"]     = r.get("handoff_drained_ms")
                entry["handoff_deferred_reason"]= r.get("handoff_deferred_reason")
                entry["handoff_giveup_reason"]  = r.get("handoff_giveup_reason")
            messages.append(entry)
        out["messages"] = messages
    return out


def render_json(rows, msgs, pair_filter, id_to_name, detail):
    json.dump(build_dm_payload(rows, msgs, pair_filter, id_to_name, detail),
              sys.stdout, indent=2)
    sys.stdout.write("\n")
```

- [ ] **Step 3: Add `compute_breakdown()` above `def main():`**

Insert this function immediately before `def main():`. It is the body of `main()` with argparse/`maybe_run`/printing removed, the stdout-capture hack replaced by a direct `build_dm_payload` call, and `mode`/`detail`/`pair`/`post` as parameters:

```python
def compute_breakdown(config_path, events_path, *, mode="all",
                      detail=False, pair=None, post=None):
    """Importable equivalent of `main()` --json. Returns the payload dict.

    mode: "dm" | "channel" | "all". For "all"/"channel" the result has a
    "channels" key; for "all"/"dm" it has "summary" (+ "messages" if detail)."""
    cfg, id_to_name, name_to_id, slot_to_id, hash_layer_to_name \
        = load_config(config_path)
    msgs, arrival_by_payload, drops = analyse(events_path, slot_to_id,
                                              hash_layer_to_name)

    for r in msgs.values():
        if not r.get("via_gateway"):
            continue
        t_layer = r.get("target_layer_id")
        t_hash = r.get("dst_key_hash32")
        if t_layer is None or t_hash is None:
            continue
        t_name = hash_layer_to_name.get((t_layer, t_hash))
        if t_name is None:
            continue
        t_id = name_to_id.get(t_name)
        if t_id is None:
            continue
        r["target_id"] = t_id
        if r["payload"] is not None:
            r["arrival_at_target_ms"] = arrival_by_payload.get((t_id, r["payload"]))

    no_gw_by_pair = defaultdict(int)
    for dp in drops:
        t_name = hash_layer_to_name.get((dp["target_layer_id"], dp["dst_key_hash32"]))
        t_id = name_to_id.get(t_name) if t_name else None
        if t_id is not None:
            no_gw_by_pair[(dp["origin"], t_id)] += 1

    explicit = parse_pair_filter(pair, name_to_id)
    if explicit is not None:
        pair_filter = explicit
    else:
        pair_filter = configured_pairs(cfg, name_to_id, hash_layer_to_name)

    rows = summarise(msgs, pair_filter, id_to_name, no_gw_by_pair)

    channel_rows = None
    if mode in ("channel", "all"):
        posts_meta = configured_channel_posts(cfg, name_to_id)
        analyse_channel(events_path, slot_to_id, posts_meta, name_to_id)
        rows_for_summary = posts_meta
        if post:
            pat = post.lower()
            rows_for_summary = [
                p for p in posts_meta
                if pat in (p.get("payload") or "").lower()
            ]
        channel_rows = summarise_channel(rows_for_summary, cfg, id_to_name)

    if mode == "channel":
        return {"channels": channel_rows or []}
    payload = build_dm_payload(rows, msgs, pair_filter, id_to_name, detail)
    if mode == "all":
        payload["channels"] = channel_rows or []
    return payload
```

Note: this deliberately omits the CLI's `--all` (no-filter) branch — the webapp always uses configured pairs. `main()` keeps `--all`.

- [ ] **Step 4: Write the equivalence test (failing)**

Create `webapp/tests/test_dm_breakdown_service.py`:

```python
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd webapp && python -m pytest tests/test_dm_breakdown_service.py -v`
Expected: PASS (or SKIP if the lus binary is absent — build it first with the project's normal build, then re-run; do not mark complete on SKIP).

- [ ] **Step 6: Commit**

```bash
git add webapp/server/services/dm_breakdown.py webapp/tests/test_dm_breakdown_service.py
git commit -m "$(cat <<'EOF'
webapp: import dm_delivery_breakdown as a service (compute_breakdown)

Refactors the CLI tool's JSON path into an importable build_dm_payload +
compute_breakdown so the webapp can produce the per-DM / per-channel
delivery breakdown without shelling out. Equivalence test pins the
service to the canonical CLI output on s13.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Cache + endpoint

**Files:**
- Modify: `webapp/server/services/dm_breakdown.py` (append `DmBreakdownCache`)
- Modify: `webapp/server/main.py:36`
- Modify: `webapp/server/routers/simulations.py`
- Test: `webapp/tests/test_dm_breakdown_endpoint.py`

- [ ] **Step 1: Add `DmBreakdownCache` to the service module**

Append to `webapp/server/services/dm_breakdown.py` (the `import` block at top already has `json`, `os`; add `import threading` and `from collections import OrderedDict` near the existing imports — `defaultdict` is already imported from collections, so extend that line to `from collections import OrderedDict, defaultdict`):

```python
class DmBreakdownCache:
    """mtime-invalidated LRU memo of the full (mode=all, detail=True)
    breakdown payload, keyed by sim_id. The payload is small plain JSON,
    so unlike EventIndexCache this keeps the computed dict, not an index."""

    def __init__(self, max_size: int = 8):
        self._max_size = max_size
        self._cache: "OrderedDict[str, tuple[int, dict]]" = OrderedDict()
        self._lock = threading.Lock()

    def get(self, sim_id: str, config_path: str, events_path: str) -> dict:
        try:
            mtime = os.stat(events_path).st_mtime_ns
        except OSError:
            mtime = 0
        with self._lock:
            hit = self._cache.get(sim_id)
            if hit is not None and hit[0] >= mtime:
                self._cache.move_to_end(sim_id)
                return hit[1]
        # Compute outside the lock (idempotent; a concurrent double-compute
        # is harmless and cheaper than holding the lock through a file walk).
        payload = compute_breakdown(config_path, events_path,
                                    mode="all", detail=True)
        with self._lock:
            self._cache[sim_id] = (mtime, payload)
            self._cache.move_to_end(sim_id)
            while len(self._cache) > self._max_size:
                self._cache.popitem(last=False)
        return payload

    def evict(self, sim_id: str) -> None:
        with self._lock:
            self._cache.pop(sim_id, None)
```

- [ ] **Step 2: Wire the cache into app state**

In `webapp/server/main.py`, add the import next to the existing `from server.services.event_index import EventIndexCache`:

```python
from server.services.dm_breakdown import DmBreakdownCache
```

And in `lifespan`, right after the line `app.state.event_cache = EventIndexCache(max_size=5)`:

```python
    app.state.dm_breakdown_cache = DmBreakdownCache()
```

- [ ] **Step 3: Add the endpoint to the sims router**

In `webapp/server/routers/simulations.py`, add the import near the other service imports at the top:

```python
from server.services.dm_breakdown import DmBreakdownCache
```

Then add this endpoint (place it after the `sim_events` endpoint, alongside the other read endpoints):

```python
@router.get("/{sim_id}/dm_breakdown")
async def sim_dm_breakdown(sim_id: str, request: Request):
    """Per-DM + per-channel delivery breakdown (see tools/dm_delivery_breakdown.py).

    Returns {"summary": [...], "messages": [...], "channels": [...]} for a
    completed sim. 409 while still running, 404 if unknown / no events."""
    sim = _get_sim_or_404(sim_id, request)
    sim_manager: SimManager = request.app.state.sim_manager
    cache: DmBreakdownCache = request.app.state.dm_breakdown_cache

    events_path = sim_manager.get_events_path(sim_id)
    if events_path is None:
        if sim.status in ("pending", "running"):
            raise HTTPException(
                status_code=409,
                detail=f"Simulation is still {sim.status}; events not available yet",
            )
        raise HTTPException(
            status_code=404, detail="Events file not found for this simulation")

    config_path = sim_manager.get_config_path(sim_id)
    if config_path is None:
        raise HTTPException(status_code=404, detail="Config not found for this simulation")

    payload = cache.get(sim_id, str(config_path), str(events_path))
    return _cached_json_response(request, sim_id, payload)
```

- [ ] **Step 4: Write the endpoint test (failing)**

Create `webapp/tests/test_dm_breakdown_endpoint.py`:

```python
"""Integration test for GET /api/sims/{sim_id}/dm_breakdown."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from server.main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
LUS = REPO_ROOT / "build" / "orchestrator" / "lus"
SCENARIO = REPO_ROOT / "scenarios" / "s13_channel_pull_storm.json"


@pytest.mark.asyncio
async def test_dm_breakdown_after_completion(tmp_path, monkeypatch):
    if not LUS.exists() or not SCENARIO.exists():
        pytest.skip("lus binary or s13 scenario missing")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    cfg = json.loads(SCENARIO.read_text())

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.post("/api/sims", json={"config_json": cfg})
            assert r.status_code in (200, 201), r.text
            sim_id = r.json()["id"]

            for _ in range(120):
                s = await client.get(f"/api/sims/{sim_id}")
                if s.json().get("status") in ("completed", "failed"):
                    break
                await asyncio.sleep(0.5)
            assert (await client.get(f"/api/sims/{sim_id}")).json()["status"] == "completed"

            b = await client.get(f"/api/sims/{sim_id}/dm_breakdown")
            assert b.status_code == 200, b.text
            data = b.json()
            assert "summary" in data and "channels" in data
            assert isinstance(data["summary"], list)
            assert isinstance(data["channels"], list)


@pytest.mark.asyncio
async def test_dm_breakdown_unknown_sim_404(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as client:
            r = await client.get("/api/sims/does-not-exist/dm_breakdown")
            assert r.status_code == 404, r.text
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd webapp && python -m pytest tests/test_dm_breakdown_endpoint.py -v`
Expected: PASS (the 404 test always runs; the completion test SKIPs without the lus binary — build it and re-run before marking complete).

- [ ] **Step 6: Commit**

```bash
git add webapp/server/services/dm_breakdown.py webapp/server/main.py webapp/server/routers/simulations.py webapp/tests/test_dm_breakdown_endpoint.py
git commit -m "$(cat <<'EOF'
webapp: GET /api/sims/{id}/dm_breakdown endpoint + cache

Adds DmBreakdownCache (mtime-invalidated LRU memo of the full breakdown
payload) and a read endpoint with ETag/304 support, mirroring the
existing events/density endpoints.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Frontend — Delivery panel in visualize.html

**Files:**
- Modify: `webapp/static/visualize.html`
- Test: `webapp/tests/test_visualize_dm_breakdown.py`

- [ ] **Step 1: Add the toolbar button**

In `webapp/static/visualize.html`, find the toolbar line with the Rays button (`<button id="btn-rays" ...>Rays</button>`) and add a Delivery button immediately after it (before the following `<div class="sep"></div>`):

```html
    <button id="btn-delivery" title="Per-DM / per-channel delivery breakdown">Delivery</button>
```

- [ ] **Step 2: Factor `centerViewportOn` out of `gotoTime`**

Find `async function gotoTime() {` (added earlier). Replace its tail — the block from `followMode = false; updateFollowIndicator();` through `render();` — so the viewport math lives in a reusable helper:

```javascript
async function centerViewportOn(target) {
    followMode = false; updateFollowIndicator();
    const span = S.viewTo - S.viewFrom;
    S.viewFrom = target - span / 2;
    S.viewTo = target + span / 2;
    clampViewport();
    syncScrollbar();
    await loadViewport();
    render();
}

async function gotoTime() {
    const input = document.getElementById('goto-ms');
    const target = parseGotoTime(input.value);
    if (target === null) {
        input.style.borderColor = '#dc2626';
        setTimeout(() => { input.style.borderColor = ''; }, 800);
        return;
    }
    await centerViewportOn(target);
}
```

- [ ] **Step 3: Add the Delivery fetch + render logic**

Add this block near the other toolbar handlers (e.g. right after the `btn-rays` click handler). `SIM_ID`, `API_PREFIX`, `traceFlight`, `nodeIdToName`, `openSidebar`, `sidebarContent`, `escHtml`, `formatTime`, and `centerViewportOn` are all already defined in this file:

```javascript
// ── Delivery breakdown panel ───────────────────────────────────
let _dmBreakdownCache = null;

async function loadDeliveryBreakdown() {
    if (!SIM_ID) {
        openSidebar();
        sidebarContent.innerHTML =
            '<div class="event-detail"><h3>Delivery</h3>' +
            '<div class="field">Only available for completed runs.</div></div>';
        return;
    }
    if (_dmBreakdownCache) { renderDeliveryPanel(_dmBreakdownCache); return; }
    openSidebar();
    sidebarContent.innerHTML = '<div class="event-detail"><h3>Delivery</h3>' +
        '<div class="field">Loading…</div></div>';
    try {
        const r = await fetch(`/api/sims/${SIM_ID}/dm_breakdown`);
        if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
        _dmBreakdownCache = await r.json();
        renderDeliveryPanel(_dmBreakdownCache);
    } catch (e) {
        sidebarContent.innerHTML = '<div class="event-detail"><h3>Delivery</h3>' +
            `<div class="field" style="color:#dc2626">Failed: ${escHtml(String(e))}</div></div>`;
    }
}

// "name(id)" -> integer id (for traceFlight). null if no id suffix.
function _nodeIdFromLabel(label) {
    const m = /\((\d+)\)\s*$/.exec(label || '');
    return m ? parseInt(m[1], 10) : null;
}

function renderDeliveryPanel(data) {
    openSidebar();
    let html = '<div class="event-detail"><h3>Delivery</h3>';

    const dm = data.summary || [];
    html += '<h4>DM</h4>';
    if (!dm.length) {
        html += '<div class="field">No configured DM pairs.</div>';
    } else {
        html += '<table><tr><th>pair</th><th>sent</th><th>arr</th>' +
                '<th>ack</th><th>give</th><th>hops</th></tr>';
        dm.forEach((row, i) => {
            const hops = row.mean_hops == null ? '–' : row.mean_hops.toFixed(1);
            html += `<tr class="dm-row" data-dm="${i}" style="cursor:pointer">` +
                `<td>${escHtml(row.origin)}→${escHtml(row.dst)}</td>` +
                `<td>${row.sent}</td><td>${row.arrived}</td>` +
                `<td>${row.acked}</td><td>${row.giveup}</td><td>${hops}</td></tr>`;
        });
        html += '</table>';
    }

    const ch = data.channels || [];
    html += '<h4>Channels</h4>';
    if (!ch.length) {
        html += '<div class="field">No channel posts.</div>';
    } else {
        html += '<table><tr><th>post</th><th>reach</th>' +
                '<th>exp</th><th>leaks</th><th>@ms</th></tr>';
        ch.forEach((row, i) => {
            const at = row.sent_at_ms == null ? '–' : formatTime(row.sent_at_ms);
            html += `<tr class="ch-row" data-ch="${i}" style="cursor:pointer">` +
                `<td>${escHtml(String(row.payload))}</td>` +
                `<td>${row.reach}</td><td>${row.expected}</td>` +
                `<td>${row.leaks}</td><td>${at}</td></tr>`;
        });
        html += '</table>';
    }
    html += '</div>';
    sidebarContent.innerHTML = html;

    // DM row → flight trace by (origin id, payload).
    sidebarContent.querySelectorAll('.dm-row[data-dm]').forEach(tr => {
        tr.addEventListener('click', () => {
            const row = (data.messages || []).length
                ? (data.messages.find(m =>
                    m.origin === dm[+tr.dataset.dm].origin &&
                    m.dst === dm[+tr.dataset.dm].dst))
                : null;
            const summaryRow = dm[+tr.dataset.dm];
            const originId = _nodeIdFromLabel(summaryRow.origin);
            const payload = row ? row.payload : null;
            if (originId != null && payload != null) traceFlight(originId, payload);
        });
    });
    // Channel row → center viewport on the post time.
    sidebarContent.querySelectorAll('.ch-row[data-ch]').forEach(tr => {
        tr.addEventListener('click', () => {
            const at = ch[+tr.dataset.ch].sent_at_ms;
            if (at != null) centerViewportOn(at);
        });
    });
}

document.getElementById('btn-delivery').addEventListener('click', loadDeliveryBreakdown);
```

Note on the DM-row→trace mapping: the summary row identifies a *pair*; the first matching detailed message supplies a concrete `payload` for `traceFlight`. Tracing the pair's first message is the intended behavior (matches how `traceFlight` keys on a single origin+payload).

- [ ] **Step 4: Write the HTML presence test (failing)**

Create `webapp/tests/test_visualize_dm_breakdown.py`:

```python
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd webapp && python -m pytest tests/test_visualize_dm_breakdown.py -v`
Expected: PASS.

- [ ] **Step 6: Manual browser verification**

Start the webapp dev server, open `visualize.html?id=<a completed sim id>`, click **Delivery**, and confirm: (a) the DM and Channels tables render; (b) clicking a DM row lights up that flight's trace in the swim-lane; (c) clicking a channel row recenters the viewport on the post time. UI correctness is not covered by the string-presence test — actually exercise it. If a browser is unavailable in this environment, say so explicitly rather than claiming success.

- [ ] **Step 7: Commit**

```bash
git add webapp/static/visualize.html webapp/tests/test_visualize_dm_breakdown.py
git commit -m "$(cat <<'EOF'
webapp: Delivery panel in swim-lane viewer

Adds a Delivery toolbar button that fetches /api/sims/{id}/dm_breakdown
and renders the per-DM and per-channel tables in the sidebar. DM rows
drive the existing flight trace; channel rows recenter the viewport on
the post time (centerViewportOn factored out of gotoTime).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Run the full webapp suite: `cd webapp && python -m pytest -q` — expect no new failures.
- [ ] Confirm the three new test files pass (or SKIP only where the lus binary is genuinely absent).
- [ ] Confirm `tools/dm_delivery_breakdown.py` is unchanged (the webapp uses its own copy).

## Notes / decisions baked in

- **No `--run` path in the webapp.** The endpoint only serves completed runs; `maybe_run`/`lus` subprocessing stays CLI-only.
- **Filtering is client-side.** The endpoint always returns the full `mode=all, detail=True` payload; pair/post filtering, if added later, is trivial array filtering in JS. (YAGNI: no query params now.)
- **Cache holds the computed dict, not an index** — the payload is small, unlike `EventIndex`.
- **The equivalence test is the contract.** If the canonical tool's JSON shape changes, Task 1's test fails first, forcing the service copy back into sync.
