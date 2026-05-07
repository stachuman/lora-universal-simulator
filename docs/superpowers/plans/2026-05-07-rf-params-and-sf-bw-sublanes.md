# RF Params + SF/BW Sub-Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-tx LoRa physical-layer params (`sf`, `bw_hz`, `cr`) to the C++ event schema, and render `(sf, bw_hz)` orthogonality as sub-rows in `visualize.html`'s lane view.

**Architecture:** Three layers, three commits.
- **C++ (Task 1):** Extend `EventLog::tx`, `rx`, `collision`, `drop*` to take `sf`/`bw_hz`/`cr`. Pass them at every emission site in `SimController.cpp` from the per-radio params already tracked at TX time.
- **Frontend (Task 2):** `visualize.html` pre-scans events for unique `(sf, bw_hz)` tuples, splits each node lane into sub-rows, routes bars to their sub-row. Click-sidebar gains `cr` row; hover tooltip gains `SFx/BWk` suffix.
- **Verification (Task 3):** Manual browser walk-through against an existing multi-SF scenario (`scenarios/s01_dv_dual_sf.json` once stable, or `test/t06_sf_mismatch.json`).

**Tech Stack:** C++17 (lus core), vanilla HTML/JS canvas (visualize.html), pytest+httpx for webapp regression tests.

**Spec:** `docs/superpowers/specs/2026-05-07-rf-params-and-sf-bw-sublanes-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `core/events/EventLog.h` | Modify | Extend `tx`/`rx`/`collision`/`drop*` signatures with `sf`, `bw_hz`, `cr` (cr only on tx/rx) |
| `core/events/EventLog.cpp` | Modify | Emit the new fields in NDJSON output |
| `orchestrator/runtime/SimController.cpp` | Modify | Pass sf/bw_hz/cr at four `EventLog::tx`/`rx` call sites + drop/collision sites |
| `test/native/test_eventlog.cpp` | Modify | Assert new fields appear in emitted JSON |
| `webapp/static/visualize.html` | Modify | Sub-row layout + sidebar + tooltip |
| `webapp/tests/test_visualize_sublanes.py` | Create | Regression smoke for visualize layout symbols |

---

## Task 1: C++ Event Schema Extension (TDD-bundled)

**Files:**
- Modify: `core/events/EventLog.h`
- Modify: `core/events/EventLog.cpp`
- Modify: `orchestrator/runtime/SimController.cpp`
- Modify: `test/native/test_eventlog.cpp`

### Step 1.1 — Update test_eventlog.cpp first to pin the new contract

- [ ] **Step 1.1: Update test_eventlog.cpp first**

In `test/native/test_eventlog.cpp`, replace the existing `EventLog::tx` and `EventLog::rx` calls (around lines 27 and 29) and add new assertions:

```cpp
    EventLog::tx(/*time_ms=*/100, /*node=*/"n0",
                 pkt_bytes, (int)sizeof(pkt_bytes), /*airtime_ms=*/120,
                 /*sf=*/7, /*bw_hz=*/125000, /*cr=*/5);
    EventLog::rx(/*time_ms=*/220, /*from=*/"n0", /*to=*/"n1",
                 /*snr=*/8.0f, /*rssi=*/-80.0f,
                 pkt_bytes, (int)sizeof(pkt_bytes), /*airtime_ms=*/120,
                 /*sf=*/7, /*bw_hz=*/125000, /*cr=*/5);
```

Add assertions (after the existing `"hex":"abcd"` check):

```cpp
    // RF params on tx/rx
    assert(s.find("\"sf\":7") != std::string::npos);
    assert(s.find("\"bw_hz\":125000") != std::string::npos);
    assert(s.find("\"cr\":5") != std::string::npos);
```

### Step 1.2 — Run native test, expect FAIL (compile error)

- [ ] **Step 1.2: Build, expect FAIL on compile**

```bash
cd /home/staszek/lora-universal-simulator && bash test/native/build_test.sh 2>&1 | tail -20
```

Expected: compile error in `test_eventlog.cpp` because `EventLog::tx`/`rx` don't yet accept the new positional args.

### Step 1.3 — Extend `EventLog.h` signatures

- [ ] **Step 1.3: Extend `EventLog.h` signatures**

Replace the existing `tx`/`rx`/`collision`/`drop*` declarations with versions that accept `sf`/`bw_hz`/`cr` (cr only on tx/rx). The new signatures (replace the corresponding lines in `core/events/EventLog.h:53-81`):

```cpp
void tx(unsigned long time_ms, const char* node,
        const uint8_t* data, int len, uint32_t airtime_ms,
        int sf, int bw_hz, int cr,
        const char* label = nullptr, const char* info = nullptr);

void rx(unsigned long time_ms, const char* from, const char* to,
        float snr, float rssi,
        const uint8_t* data, int len, uint32_t airtime_ms,
        int sf, int bw_hz, int cr);

void collision(unsigned long time_ms, const char* from, const char* to,
               float snr, float rssi,
               const uint8_t* data, int len,
               int sf, int bw_hz,
               const char* interferer = nullptr,
               float interferer_snr = 0.0f,
               float snr_margin = 0.0f);

void dropHalfDuplex(unsigned long time_ms, const char* from, const char* to,
                    const uint8_t* data, int len, uint32_t airtime_ms,
                    int sf, int bw_hz);

void dropWeak(unsigned long time_ms, const char* from, const char* to,
              float snr, float threshold,
              const uint8_t* data, int len,
              int sf, int bw_hz);

void dropLoss(unsigned long time_ms, const char* from, const char* to,
              float loss_prob,
              const uint8_t* data, int len,
              int sf, int bw_hz);

// dropSfMismatch already carries packet_sf and rx_sf — add bw_hz only
// (the new `sf` for sub-row routing is the packet's sf, equal to packet_sf;
// to avoid duplicate names, the emitted JSON gains a `bw_hz` field but
// continues to use `packet_sf` as the row-routing key in the frontend).
void dropSfMismatch(unsigned long time_ms, const char* from, const char* to,
                    int packet_sf, int rx_sf,
                    const uint8_t* data, int len,
                    int bw_hz);
```

The default `=nullptr` on `tx`'s `label`/`info` and the rx default of `airtime_ms=0` stay — but note that callers already always pass airtime_ms, and we now require sf/bw_hz/cr (no defaults — they must be supplied so we don't accidentally emit zeros).

### Step 1.4 — Update `EventLog.cpp` emit bodies

- [ ] **Step 1.4: Update `EventLog.cpp` emit bodies**

For each function in `EventLog.cpp` whose signature changed, add the new fields in the emitted NDJSON. Pattern for `tx` (the new fields go before the optional `label`/`info` suffix so the existing `extra` build-up is unaffected):

In `tx()` (around line 156–195), the existing `snprintf` should become:

```cpp
    char buf[4096];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"tx\",\"time_ms\":%lu,\"node\":\"%s\",\"pkt\":\"%s\","
        "\"hex\":\"%s\",\"airtime_ms\":%u,"
        "\"sf\":%d,\"bw_hz\":%d,\"cr\":%d%s}\n",
        time_ms, node, pkt, hex, (unsigned)airtime_ms,
        sf, bw_hz, cr, extra);
    emitLine(buf);
```

For `rx()` (around line 197–214), insert the three fields after `airtime_ms`:

```cpp
        snprintf(buf, sizeof(buf),
            "{\"type\":\"rx\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"snr_db\":%.2f,\"rssi_dbm\":%.2f,"
            "\"pkt\":\"%s\",\"airtime_ms\":%u,"
            "\"sf\":%d,\"bw_hz\":%d,\"cr\":%d}\n",
            time_ms, from, to, snr, rssi, pkt,
            (unsigned)airtime_ms, sf, bw_hz, cr);
```

(Use the existing field names — confirm by reading the current `rx()` body and adapt the format string. The change is just appending the three fields before the closing `}`.)

For `collision`, `dropWeak`, `dropLoss`, `dropHalfDuplex`, `dropSfMismatch`: add the `sf`/`bw_hz` fields in the same idiom — append them before the closing `}` in the snprintf.

For `dropSfMismatch`: the function already emits `packet_sf` — add `bw_hz` alongside it. Do NOT also emit `sf` (it would be redundant with `packet_sf`).

### Step 1.5 — Update SimController.cpp call sites

- [ ] **Step 1.5: Update SimController.cpp call sites**

Four `EventLog::tx`/`rx` calls in `orchestrator/runtime/SimController.cpp`. The new positional args go between `airtime_ms` and `label`/`info` (or before the closing paren for rx).

For the call at line 612 (the no-link-loss fast path) and line 750 (main TX path):

```cpp
                EventLog::tx(static_cast<unsigned long>(now),
                             _nodes[i]->name().c_str(),
                             reinterpret_cast<const uint8_t*>(p.bytes.data()),
                             static_cast<int>(p.bytes.size()),
                             airtime,
                             sf, bw_hz, cr,             // <-- new
                             p.label.empty() ? nullptr : p.label.c_str(),
                             p.info.empty()  ? nullptr : p.info.c_str());
```

Note: `sf`, `bw_hz`, `cr` are already in scope (lines 600–602) for the main-loop call site at line 612. For the alternate site at line 750, similar locals are computed nearby — verify by reading lines 720–750.

For the rx call sites at lines 558 and 627: the receiver's local SF/BW/CR is what matters for sub-row routing. Pass:

```cpp
EventLog::rx(static_cast<unsigned long>(now),
             _nodes[tx.sender_id]->name().c_str(),
             _nodes[rcv]->name().c_str(),
             snr_at_rcv, lp.rssi,
             reinterpret_cast<const uint8_t*>(tx.bytes.data()),
             static_cast<int>(tx.bytes.size()),
             static_cast<uint32_t>(tx.end_ms - tx.start_ms),
             _radios[rcv]->getSF(),                // <-- new
             _radios[rcv]->getBwHz(),              // <-- new
             _radios[rcv]->getCR());               // <-- new
```

For the alternate rx site at line 627 (the no-link-loss path):

```cpp
                    EventLog::rx(static_cast<unsigned long>(now),
                                 _nodes[i]->name().c_str(),
                                 _nodes[r]->name().c_str(),
                                 lp.snr, lp.rssi,
                                 reinterpret_cast<const uint8_t*>(p.bytes.data()),
                                 static_cast<int>(p.bytes.size()),
                                 airtime,
                                 _radios[r]->getSF(),
                                 _radios[r]->getBwHz(),
                                 _radios[r]->getCR());
```

For `EventLog::collision`, `dropWeak`, `dropLoss`, `dropHalfDuplex`, `dropSfMismatch`: search for these calls in `SimController.cpp` (`grep -n "EventLog::dropWeak\|EventLog::dropLoss\|EventLog::dropHalfDuplex\|EventLog::dropSfMismatch\|EventLog::collision" SimController.cpp`). At each site, pass the **packet's** sf and bw_hz — the sf/bw the packet was transmitted on, NOT the receiver's. The packet's sf is typically already in scope as part of the in-flight tracking struct (`tx.sf` / `f.sf` or similar). If not, read from `_radios[tx.sender_id]->getSF()` and `getBwHz()`.

For `dropSfMismatch`: only `bw_hz` needs to be added (sf is already there as `packet_sf`).

### Step 1.6 — Build and run native test

- [ ] **Step 1.6: Build and run native test**

```bash
cd /home/staszek/lora-universal-simulator && bash test/native/build_test.sh 2>&1 | tail -10
```

Expected: native test passes.

### Step 1.7 — Build orchestrator and run integration tests

- [ ] **Step 1.7: Build orchestrator and run integration tests**

```bash
cd /home/staszek/lora-universal-simulator && cmake --build build -j 2>&1 | tail -20 && \
  bash test/run_tests.sh 2>&1 | tail -20
```

Expected:
- Build succeeds.
- Integration suite: same pass/fail counts as the baseline (s01 still fails per user's in-flight tweaks; t01–t12 + t99 all pass). The new fields are additive — no existing assertion checks should care about extra JSON keys.

If any t-test that previously passed now fails, capture the failure and STOP — do not proceed to commit. Likely cause: a `field_count` or `event_count`–style assertion that's strict about JSON key count.

### Step 1.8 — Commit

- [ ] **Step 1.8: Commit**

```bash
cd /home/staszek/lora-universal-simulator && \
  git add core/events/EventLog.h core/events/EventLog.cpp \
          orchestrator/runtime/SimController.cpp \
          test/native/test_eventlog.cpp && \
  git commit -m "$(cat <<'EOF'
feat(events): per-tx sf, bw_hz, cr in tx/rx + bw_hz on drop/collision

Surfaces LoRa physical-layer parameters in every transmit/receive
event so the webapp lane view can render (sf, bw_hz) orthogonality.

EventLog::tx and rx grow three required positional args (sf, bw_hz,
cr) emitted as new JSON fields before the optional label/info suffix.
Drop and collision events get sf+bw_hz (packet's sf, for sub-row
routing in the frontend); cr stays on tx/rx only — the frontend
cross-references via pkt when it needs cr for a dropped packet.

dropSfMismatch already carries packet_sf — adds bw_hz only.

Native test_eventlog.cpp asserts the new fields. Integration suite
unaffected: no existing scenario assertions are strict about JSON
key counts.

Spec: docs/superpowers/specs/2026-05-07-rf-params-and-sf-bw-sublanes-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: visualize.html Sub-Row Rendering (TDD-bundled)

**Files:**
- Modify: `webapp/static/visualize.html`
- Create: `webapp/tests/test_visualize_sublanes.py`

### Step 2.1 — Write the regression smoke test

- [ ] **Step 2.1: Write the regression smoke test**

Create `webapp/tests/test_visualize_sublanes.py`:

```python
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
    # Hover tooltip suffix
    assert "/" in html and "kHz" in html, "Hover tooltip BW suffix missing"
```

### Step 2.2 — Run test, expect FAIL

- [ ] **Step 2.2: Run test, expect FAIL**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/test_visualize_sublanes.py -v
```

Expected: FAIL on `S.subRows in html` — implementation doesn't exist yet.

### Step 2.3 — Add sub-row state to S

- [ ] **Step 2.3: Add sub-row state to S**

In `webapp/static/visualize.html`, find the `const S = {` block (around line 115). Add new fields near the bottom of the object (just before `cursorMs`):

```js
    // Sub-row layout for SF/BW orthogonality. Computed once per
    // events-load by computeSubRowLayout(). Empty -> single-row
    // fallback (legacy events without sf/bw_hz).
    subRows: [],          // [{sf, bw_hz}, ...]  ordered ascending by sf, then bw_hz
    subRowIndex: new Map(),  // "sf|bw_hz" -> index into subRows
```

### Step 2.4 — Add the layout pre-scan helper

- [ ] **Step 2.4: Add the layout pre-scan helper**

After the existing `clampViewport` function (around line 444), add:

```js
// Pre-scan cached events for unique (sf, bw_hz) tuples. Called whenever
// new events arrive (i.e. after loadViewport refills S.cachedEvents).
// The result is stable across re-renders within a sim.
function computeSubRowLayout() {
    const seen = new Map();
    for (const ev of S.cachedEvents) {
        if (typeof ev.sf !== 'number' || typeof ev.bw_hz !== 'number') continue;
        const key = ev.sf + '|' + ev.bw_hz;
        if (!seen.has(key)) seen.set(key, { sf: ev.sf, bw_hz: ev.bw_hz });
    }
    // Sort: SF ascending, BW ascending within SF
    const arr = Array.from(seen.values())
        .sort((a, b) => (a.sf - b.sf) || (a.bw_hz - b.bw_hz));
    S.subRows = arr;
    S.subRowIndex = new Map(arr.map((r, i) => [r.sf + '|' + r.bw_hz, i]));
}

// Map an event to its sub-row index. Returns 0 for events without
// sf/bw_hz (legacy fallback) or with an SF/BW combo not seen during
// the layout pre-scan.
function subRowFor(ev) {
    if (S.subRows.length === 0) return 0;
    if (typeof ev.sf !== 'number' || typeof ev.bw_hz !== 'number') return 0;
    const key = ev.sf + '|' + ev.bw_hz;
    const idx = S.subRowIndex.get(key);
    return (idx == null) ? 0 : idx;
}
```

### Step 2.5 — Call `computeSubRowLayout` after every events load

- [ ] **Step 2.5: Call `computeSubRowLayout` after every events load**

Find `loadViewport()` (around line 397). After the line that populates `S.cachedEvents` (the line that ends with `S.cachedEvents = ...` or similar — confirm by reading the function), add:

```js
    computeSubRowLayout();
```

If `loadViewport` is async and there are multiple paths populating `cachedEvents`, ensure the call happens after all of them.

### Step 2.6 — Adjust lane height in render()

- [ ] **Step 2.6: Adjust lane height in render()**

The lane-drawing loop in `render()` (around line 506–519) uses `S.laneH` as the per-node height. Replace the math with:

```js
    const subRowCount = Math.max(1, S.subRows.length);
    const nodeLaneH = S.laneH * subRowCount;

    // Draw lanes (with scrollY offset)
    for (let i = 0; i < nNodes; i++) {
        const y = S.headerH + i * nodeLaneH - S.scrollY;
        if (y + nodeLaneH < S.headerH) continue;
        if (y > h) break;
        // Alternate light/dark per node, with sub-row stripes inside
        for (let s = 0; s < subRowCount; s++) {
            const subY = y + s * S.laneH;
            ctx.fillStyle = ((i + s) % 2 === 0) ? COLORS.lane_bg : COLORS.lane_bg_alt;
            ctx.fillRect(S.labelW, subY, contentW, S.laneH);
        }

        // Lane border at the bottom of the node group
        ctx.strokeStyle = COLORS.lane_border;
        ctx.beginPath();
        ctx.moveTo(S.labelW, y + nodeLaneH);
        ctx.lineTo(w, y + nodeLaneH);
        ctx.stroke();
    }
```

Also update `updateMaxScrollY` (find it and confirm) so vertical scrolling accounts for the larger total height (`nNodes * nodeLaneH`).

Also update label rendering (around line 535–550) so the node name renders centered vertically on the **node group** (not the first sub-row), and add small sub-row labels (e.g. `SF7/125k`) inside each sub-row's label-column slice:

```js
    for (let i = 0; i < nNodes; i++) {
        const y = S.headerH + i * nodeLaneH - S.scrollY;
        if (y + nodeLaneH < S.headerH) continue;
        if (y > h) break;
        const node = S.nodes[i];
        const isCompanion = node.role === 'companion';

        // Node name: centered vertically across the whole node group
        ctx.fillStyle = isCompanion ? '#2563eb' : '#6b7280';
        ctx.font = 'bold 12px monospace';
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillText(node.name, 8, y + nodeLaneH / 2);

        // Sub-row labels (one per (sf, bw_hz) tuple)
        ctx.font = '9px monospace';
        ctx.fillStyle = '#9ca3af';
        ctx.textBaseline = 'middle';
        for (let s = 0; s < subRowCount; s++) {
            const sub = S.subRows[s];
            if (!sub) continue;  // single-row fallback, no label
            const subY = y + s * S.laneH + S.laneH / 2;
            const label = 'SF' + sub.sf + '/' + Math.round(sub.bw_hz / 1000) + 'k';
            ctx.fillText(label, 64, subY);
        }
    }
```

The exact x-coordinate of the sub-row label (`64` above) depends on
`S.labelW = 160` — adjust so the node name and the sub-row labels don't
overlap. The node name occupies x ∈ [8, ~60]; sub-row labels start at
x = 64.

### Step 2.7 — Route TX/RX bars into the correct sub-row

- [ ] **Step 2.7: Route TX/RX bars into the correct sub-row**

Find the TX/RX bar rendering (around line 800–920 — search for `COLORS.tx` and `COLORS.rx`). For every place that computes the bar's Y coordinate using the node-index-times-laneH pattern, replace with sub-row-aware math:

```js
const subRowIdx = subRowFor(ev);
const y = S.headerH + nodeIdx * nodeLaneH + subRowIdx * S.laneH - S.scrollY;
```

The bar height stays at the existing inset within `S.laneH`. Confirm by tracing through the existing code; the typical pattern is `y = S.headerH + nodeIdx * S.laneH + 2` (TX bar inset by 2 px). Update to:

```js
const y = S.headerH + nodeIdx * nodeLaneH + subRowIdx * S.laneH + 2;
```

This applies to:
- TX bar drawing
- RX bar drawing
- Drop / collision bar drawing
- Trace overlays (if rendered as bars)

There may be 4–6 such Y-coordinate lines in render() and helper functions. Find them by `grep -n "S.laneH" visualize.html` and update each.

### Step 2.8 — Update click hit-testing

- [ ] **Step 2.8: Update click hit-testing**

`findEventAt(mx, my)` (line 1358) computes `laneIdx` from `my`. With sub-rows, the Y math changes; replace:

```js
const laneIdx = Math.floor((my - S.headerH + sY) / S.laneH);
```

with:

```js
const subRowCount = Math.max(1, S.subRows.length);
const nodeLaneH = S.laneH * subRowCount;
const laneIdx = Math.floor((my - S.headerH + sY) / nodeLaneH);
```

The "in upper half (TX) or lower half (RX)" logic (line 1374–1377) uses `S.laneH / 2`. With sub-rows, this needs to account for which sub-row was hit:

```js
const localY = (my - S.headerH + sY) - laneIdx * nodeLaneH;
const subRowIdx = Math.floor(localY / S.laneH);
const inUpperHalf = (localY - subRowIdx * S.laneH) < S.laneH / 2;
```

Then, when iterating over candidate events, additionally filter by `subRowFor(ev) === subRowIdx`:

```js
for (const ev of S.cachedEvents) {
    if (subRowFor(ev) !== subRowIdx) continue;
    // ... existing hit-testing logic
}
```

### Step 2.9 — Add CR to click-details sidebar

- [ ] **Step 2.9: Add CR to click-details sidebar**

Find the click-details sidebar render code — it's keyed on `S.selectedEvent` and writes HTML into `#sidebar` (search for `selectedEvent` and `#sidebar`). When rendering the packet info, append (where the existing rows like SNR are listed):

```js
if (typeof ev.sf === 'number') {
    rows.push(`<tr><td>SF</td><td>${ev.sf}</td></tr>`);
}
if (typeof ev.bw_hz === 'number') {
    rows.push(`<tr><td>BW</td><td>${(ev.bw_hz / 1000).toFixed(0)} kHz</td></tr>`);
}
if (typeof ev.cr === 'number') {
    rows.push(`<tr><td>CR </td><td>4/${ev.cr}</td></tr>`);
}
```

Adjust the variable names (`rows`, `ev`) to match the actual template structure in the file. The exact location is wherever the sidebar template emits the existing "from / to / SNR / RSSI" rows for a packet.

### Step 2.10 — Add hover tooltip suffix

- [ ] **Step 2.10: Add hover tooltip suffix**

Find the hover-tooltip render (search for `hoveredEvent` or the tooltip-drawing logic, typically a function near the end of the script that draws a small text box near the mouse position). When formatting the tooltip text, after the existing `label` / `info`, append a compact RF suffix:

```js
let rfSuffix = '';
if (typeof ev.sf === 'number' && typeof ev.bw_hz === 'number') {
    rfSuffix = ' SF' + ev.sf + '/' + Math.round(ev.bw_hz / 1000) + 'k';
}
// then use rfSuffix in the tooltip text
```

If the existing tooltip uses an array-of-lines format, add a separate line `'SF7 / 125 kHz'` instead of an inline suffix — match the existing style.

### Step 2.11 — Run regression test, expect PASS

- [ ] **Step 2.11: Run regression test, expect PASS**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/test_visualize_sublanes.py -v
```

Expected: 1 passed.

### Step 2.12 — Run full webapp suite, expect baseline+1

- [ ] **Step 2.12: Run full webapp suite**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/
```

Expected: same pass count as before + 1 new passing test. The 3 pre-existing s01-related failures stay (the user's in-flight scenario).

### Step 2.13 — Syntax sanity check

- [ ] **Step 2.13: Syntax sanity check**

```bash
node -e "
const fs = require('fs');
const html = fs.readFileSync('/home/staszek/lora-universal-simulator/webapp/static/visualize.html', 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
try { new Function(m[1]); console.log('OK'); }
catch (e) { console.log('ERR:', e.message); process.exit(1); }
"
```

Expected: `OK`.

### Step 2.14 — Commit

- [ ] **Step 2.14: Commit**

```bash
cd /home/staszek/lora-universal-simulator && \
  git add webapp/static/visualize.html webapp/tests/test_visualize_sublanes.py && \
  git commit -m "$(cat <<'EOF'
feat(webapp/visualize): SF/BW sub-rows + RF params in click-details

Splits each node lane into sub-rows by unique (sf, bw_hz) seen in the
run, so different-SF/BW transmissions visually demonstrate their
collision orthogonality. Backwards-compatible with sims whose events
don't carry sf/bw_hz: the layout collapses to a single row per node.

Click-details sidebar gains SF / BW / CR rows. Hover tooltip gains a
compact "SF7/125k" suffix for at-a-glance scanning.

Spec: docs/superpowers/specs/2026-05-07-rf-params-and-sf-bw-sublanes-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Manual Browser Verification

**Files:** None modified — verification only.

This task must run on the controller (or human) — subagents have no browser.

### Step 3.1 — Build + restart webapp

- [ ] **Step 3.1: Build + restart webapp**

```bash
cd /home/staszek/lora-universal-simulator && \
  cmake --build build -j && \
  cd webapp && bash run.sh
```

If `bash run.sh` is already running from a previous step, stop it first (`Ctrl+C`) and restart so the new lus binary is picked up — sim_manager spawns lus by absolute path; the FastAPI process needs no restart for static-file changes.

### Step 3.2 — Run a multi-SF sim

- [ ] **Step 3.2: Run a multi-SF sim**

In a browser, open `http://localhost:8000/static/simulations.html` → New Simulation. Use either:
- `scenarios/s01_dv_dual_sf.json` (uses SF7 + SF12), OR
- `test/t06_sf_mismatch.json` (uses SF7 + SF9 — guaranteed pass).

Wait for completion. Note the sim id.

### Step 3.3 — Verify lane sub-row layout

- [ ] **Step 3.3: Verify lane sub-row layout**

Open `http://localhost:8000/static/visualize.html?id=<sim_id>`. Verify:
- Every node lane is split into 2 sub-rows (or however many SFs the chosen scenario uses).
- Sub-row labels read `SF7/125k`, `SF12/125k` (or matching) in the label column.
- Node names stay centered across the whole node group, not on a single sub-row.

### Step 3.4 — Verify TX bar placement

- [ ] **Step 3.4: Verify TX bar placement**

Identify a few TX bars and verify each lands in its `(sf, bw_hz)` sub-row. For s01:
- BCN beacons fire on the routing SF (SF7 sub-row).
- DATA bursts fire on the data SF (SF12 sub-row).
- RTS/CTS handshakes fire on the routing SF.

If any bar lands in the wrong sub-row, capture the event JSON (open DevTools → Network → click the `/api/sims/<id>/events` response and grep for the pkt) and STOP — there's a routing bug.

### Step 3.5 — Verify cross-SF orthogonality is visible

- [ ] **Step 3.5: Verify cross-SF orthogonality is visible**

Find a moment where one node TXes on SF7 while another TXes on SF12 (or look near `t=31000ms` in s01 where alice starts a DATA flow while routing-SF beacons may still be firing). Verify:
- The two bars appear in different sub-rows on the canvas.
- Visually, this immediately shows "no collision" — they don't overlap in any single row.

### Step 3.6 — Verify click-details panel

- [ ] **Step 3.6: Verify click-details panel**

Click any TX bar. The sidebar should show:
- (existing) From / To / SNR / RSSI / pkt / hex / label / info
- (new) SF / BW / CR rows

Verify SF and BW match the bar's sub-row. Verify CR is sensible (typically 5 = 4/5).

### Step 3.7 — Verify hover tooltip

- [ ] **Step 3.7: Verify hover tooltip**

Hover (don't click) a TX bar. The tooltip should append `SF7/125k` (or matching) to the existing label/info display.

### Step 3.8 — Verify scrolling works

- [ ] **Step 3.8: Verify scrolling works**

Scroll vertically. Confirm:
- The whole node-group block (node name + all sub-rows) scrolls as one unit.
- The vertical scrollbar height correctly reflects total content height (`nNodes * nodeLaneH`).

### Step 3.9 — Verify backwards compatibility

- [ ] **Step 3.9: Verify backwards compatibility**

Open a pre-existing sim from `webapp/data/simulations/4d08d44b06d7/` (the one we already had) — its events.ndjson predates sf/bw_hz. Verify:
- The lane view falls back to single-row-per-node rendering.
- No JS errors in the console.

### Step 3.10 — Document the result

- [ ] **Step 3.10: Document the result**

If 3.3–3.9 all passed: record "manual verification: PASS" — task complete.

If any step failed: stop, capture the failure (screenshot, console log, network response), and surface it before considering the task done.

---

## Self-Review Notes

Coverage check vs. spec sections:
- Event schema (spec §"Event schema changes") → Task 1, Steps 1.3–1.5
- C++ tests (spec §"Test side") → Step 1.1, 1.6
- visualize.html sub-row layout (spec §"Pre-scan", "Lane height", "Sub-row labels") → Steps 2.3–2.6
- Bar routing (spec §"Bar rendering") → Step 2.7
- Hit-testing (implicit in spec) → Step 2.8
- Click-details panel (spec §"Click-details panel") → Step 2.9
- Hover tooltip (spec §"Hover tooltip") → Step 2.10
- Backwards compatibility (spec §"Backwards compatibility") → Step 3.9
- Manual verification (spec §"Manual browser verification") → Task 3, all steps

Ambiguities the implementer may hit:
- Exact line numbers in `visualize.html` may have drifted; the cues are strings to grep for, not line numbers.
- The `findEventAt` hit-testing math is the trickiest single change; getting it wrong makes click-trace mode broken. Test by clicking a bar and confirming the sidebar matches.
- If the `loadViewport` or events path is more complex than expected (e.g., density mode), `computeSubRowLayout` may need to run after both density and event paths complete. Verify both modes don't crash.
