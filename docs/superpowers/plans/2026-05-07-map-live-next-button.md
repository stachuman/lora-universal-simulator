# Map-Live Next-Event Button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Next` button to `webapp/static/map_live.html` that advances the post-sim replay to the next packet-level event (filter-based, protocol-agnostic).

**Architecture:** Frontend-only. One new button in `.mlv-controls`, a hard-coded `NEXT_EVENT_FILTER` Set, a `fireEventsUpTo(targetMs)` helper extracted from `replayFrame()`, and an `onNextEvent` click handler that scans `allEvents` from the current cursor for the next matching event, jumps to it, fires intermediate events, pauses, and posts `{type:'mlv-scrub-time', t}` to the embedded `tl-frame` iframe (which `visualize.html` already listens for).

**Tech Stack:** Vanilla HTML/JS in `webapp/static/map_live.html`; pytest + httpx + asgi_lifespan for the regression smoke test (matches existing `webapp/tests/` pattern).

**Spec:** `docs/superpowers/specs/2026-05-07-map-live-next-button-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `webapp/static/map_live.html` | Modify | Add button, constant, DOM ref, helper, handler, disable/re-enable logic, iframe postMessage |
| `webapp/tests/test_map_live_next_button.py` | Create | Static-file regression test — assert key strings appear in served HTML |

No changes elsewhere. No backend changes. No orchestrator changes.

---

## Task 1: Implement Next Button (TDD-bundled)

The Next button is a single coherent feature. We bundle the regression test and the implementation in one task so the test never lands in a failing state.

**Files:**
- Create: `webapp/tests/test_map_live_next_button.py`
- Modify: `webapp/static/map_live.html`

### Step 1.1 — Write the regression smoke test

- [ ] **Step 1.1: Write the regression smoke test**

Create `webapp/tests/test_map_live_next_button.py`:

```python
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
```

### Step 1.2 — Run the test, expect FAIL

- [ ] **Step 1.2: Run the test, expect FAIL**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/test_map_live_next_button.py -v
```

Expected: 1 failed (assertion error on `'id="btn-next"' in html`), because the implementation hasn't been added yet.

### Step 1.3 — Add the HTML button

- [ ] **Step 1.3: Add the HTML button**

In `webapp/static/map_live.html`, locate the `.mlv-controls` row (around line 275–286) and insert a Next button after Restart and before the speed buttons. Replace this block:

```html
  <div class="mlv-controls" id="controls" style="display:none">
    <button id="btn-pause" title="Pause / resume replay">⏸ Pause</button>
    <button id="btn-restart" title="Restart replay from beginning">⏮ Restart</button>
    <span class="sep">|</span>
    <span class="speed-label">Speed:</span>
    <button class="speed-btn" data-speed="1">1×</button>
    <button class="speed-btn" data-speed="10">10×</button>
    <button class="speed-btn active" data-speed="100">100×</button>
    <button class="speed-btn" data-speed="1000">1000×</button>
    <span class="sep">|</span>
    <span class="time-display" id="time-display">now: 0.0s / 0.0s</span>
  </div>
```

with:

```html
  <div class="mlv-controls" id="controls" style="display:none">
    <button id="btn-pause" title="Pause / resume replay">⏸ Pause</button>
    <button id="btn-restart" title="Restart replay from beginning">⏮ Restart</button>
    <button id="btn-next" title="Jump to next packet-level event (tx, rx, drop, collision, deferred)">⏭ Next</button>
    <span class="sep">|</span>
    <span class="speed-label">Speed:</span>
    <button class="speed-btn" data-speed="1">1×</button>
    <button class="speed-btn" data-speed="10">10×</button>
    <button class="speed-btn active" data-speed="100">100×</button>
    <button class="speed-btn" data-speed="1000">1000×</button>
    <span class="sep">|</span>
    <span class="time-display" id="time-display">now: 0.0s / 0.0s</span>
  </div>
```

### Step 1.4 — Add the DOM ref

- [ ] **Step 1.4: Add the `btnNext` DOM ref**

Find the block that sets up DOM refs (around line 311–320):

```js
const btnPause      = $('btn-pause');
const btnRestart    = $('btn-restart');
const timeDisplayEl = $('time-display');
```

Add `btnNext` right after `btnRestart`:

```js
const btnPause      = $('btn-pause');
const btnRestart    = $('btn-restart');
const btnNext       = $('btn-next');
const timeDisplayEl = $('time-display');
```

### Step 1.5 — Add the NEXT_EVENT_FILTER constant

- [ ] **Step 1.5: Add the `NEXT_EVENT_FILTER` constant**

Find the existing `RX_LIKE` constant (around line 1014–1015):

```js
const RX_LIKE = new Set(['rx', 'drop_weak', 'drop_sf_mismatch',
                         'drop_halfduplex', 'collision']);
```

Add `NEXT_EVENT_FILTER` directly below it:

```js
const RX_LIKE = new Set(['rx', 'drop_weak', 'drop_sf_mismatch',
                         'drop_halfduplex', 'collision']);

// Packet-level event types that the Next button stops at. Protocol-
// agnostic — emitted by the C++ runtime regardless of which Lua scenario
// is running. Excludes script_log / script_emit / cmd_reply (per-protocol)
// and node_ready / sim_start / sim_end (bookkeeping).
const NEXT_EVENT_FILTER = new Set([
  'tx', 'rx', 'collision',
  'drop_weak', 'drop_sf_mismatch', 'drop_halfduplex', 'drop_loss',
  'tx_deferred',
]);
```

### Step 1.6 — Extract the `fireEventsUpTo` helper

- [ ] **Step 1.6: Extract the `fireEventsUpTo` helper**

Find `replayFrame()` (around line 979–1007). Replace this block:

```js
function replayFrame(wallTs) {
  if (replayPaused) { lastRafTs = wallTs; rafHandle = requestAnimationFrame(replayFrame); return; }

  const dtWall = lastRafTs === null ? 0 : wallTs - lastRafTs;
  lastRafTs = wallTs;

  // Advance simulated cursor
  replayCursor += dtWall * playbackSpeed;
  if (replayCursor > replayEndMs) replayCursor = replayEndMs;

  // Fire all events whose time_ms <= replayCursor that haven't been fired yet
  while (replayNextIdx < allEvents.length && fireMs(allEvents[replayNextIdx]) <= replayCursor) {
    fireEvent(allEvents[replayNextIdx]);
    replayNextIdx++;
  }

  // Update counters every frame (cheap enough)
  eventCountEl.textContent = replayNextIdx + ' / ' + allEvents.length + ' events';
  updateTimeDisplay();

  if (replayCursor < replayEndMs) {
    rafHandle = requestAnimationFrame(replayFrame);
  } else {
    statusEl.textContent = 'Replay complete';
    btnPause.textContent = '▶ Replay';
    replayPaused = true;
    rafHandle = null;
  }
}
```

with:

```js
// Fire every queued event whose effective fire-time has been reached.
// Used both by the rAF replay loop and the Next-event button.
function fireEventsUpTo(targetMs) {
  while (replayNextIdx < allEvents.length && fireMs(allEvents[replayNextIdx]) <= targetMs) {
    fireEvent(allEvents[replayNextIdx]);
    replayNextIdx++;
  }
}

function replayFrame(wallTs) {
  if (replayPaused) { lastRafTs = wallTs; rafHandle = requestAnimationFrame(replayFrame); return; }

  const dtWall = lastRafTs === null ? 0 : wallTs - lastRafTs;
  lastRafTs = wallTs;

  // Advance simulated cursor
  replayCursor += dtWall * playbackSpeed;
  if (replayCursor > replayEndMs) replayCursor = replayEndMs;

  fireEventsUpTo(replayCursor);

  // Update counters every frame (cheap enough)
  eventCountEl.textContent = replayNextIdx + ' / ' + allEvents.length + ' events';
  updateTimeDisplay();

  if (replayCursor < replayEndMs) {
    rafHandle = requestAnimationFrame(replayFrame);
  } else {
    statusEl.textContent = 'Replay complete';
    btnPause.textContent = '▶ Replay';
    btnNext.disabled = true;
    replayPaused = true;
    rafHandle = null;
  }
}
```

Two changes vs. the original:
1. Inner while-loop replaced by `fireEventsUpTo(replayCursor)`.
2. End-branch now also disables `btnNext`.

### Step 1.7 — Re-enable Next on Restart

- [ ] **Step 1.7: Re-enable Next on Restart**

In `restartReplay()` (around line 1042–1056), add a `btnNext.disabled = false;` line. Replace:

```js
function restartReplay() {
  // Keep the same events & endMs, just reset cursor
  replayCursor  = 0;
  replayNextIdx = 0;
  replayPaused  = false;
  lastRafTs     = null;

  resetAllStates();
  removeAllActiveTx();
  btnPause.textContent = '⏸ Pause';
  updateTimeDisplay();

  if (rafHandle) cancelAnimationFrame(rafHandle);
  rafHandle = requestAnimationFrame(replayFrame);
}
```

with:

```js
function restartReplay() {
  // Keep the same events & endMs, just reset cursor
  replayCursor  = 0;
  replayNextIdx = 0;
  replayPaused  = false;
  lastRafTs     = null;

  resetAllStates();
  removeAllActiveTx();
  btnPause.textContent = '⏸ Pause';
  btnNext.disabled = false;
  updateTimeDisplay();

  if (rafHandle) cancelAnimationFrame(rafHandle);
  rafHandle = requestAnimationFrame(replayFrame);
}
```

### Step 1.8 — Implement `onNextEvent` and wire the click listener

- [ ] **Step 1.8: Implement `onNextEvent` and wire the click listener**

In the playback-controls section (around line 1058–1073), find:

```js
btnRestart.addEventListener('click', restartReplay);
```

Insert the new handler and listener directly below it:

```js
btnRestart.addEventListener('click', restartReplay);

// ── Next-event button ─────────────────────────────────────────────────
// Find the next packet-level event (NEXT_EVENT_FILTER), jump the cursor
// to its fire-time, fire all skipped events along the way, pause, and
// notify the embedded swim-lane iframe to recenter on the new time.
function onNextEvent() {
  if (replayCursor >= replayEndMs) return;  // already at end; button should be disabled

  // Scan from the current event cursor forward for the next match.
  let j = replayNextIdx;
  while (j < allEvents.length && !NEXT_EVENT_FILTER.has(allEvents[j].type)) {
    j++;
  }

  if (j >= allEvents.length) {
    // No more interesting events — flush to the end.
    replayCursor = replayEndMs;
    fireEventsUpTo(replayEndMs);
    statusEl.textContent = 'Replay complete';
    btnPause.textContent = '▶ Replay';
    btnNext.disabled = true;
    replayPaused = true;
    if (rafHandle) { cancelAnimationFrame(rafHandle); rafHandle = null; }
  } else {
    replayCursor = fireMs(allEvents[j]);
    fireEventsUpTo(replayCursor);
    replayPaused = true;
    btnPause.textContent = '▶ Resume';
  }

  // Update counters + time display.
  eventCountEl.textContent = replayNextIdx + ' / ' + allEvents.length + ' events';
  updateTimeDisplay();

  // Recenter the swim-lane iframe on the new cursor. visualize.html
  // listens for {type:'mlv-scrub-time', t} and recenters its viewport.
  try {
    if (tlFrame && tlFrame.contentWindow) {
      tlFrame.contentWindow.postMessage({ type: 'mlv-scrub-time', t: replayCursor }, '*');
    }
  } catch (_) { /* iframe not yet loaded — ignore */ }
}

btnNext.addEventListener('click', onNextEvent);
```

### Step 1.9 — Run the regression test, expect PASS

- [ ] **Step 1.9: Run the regression test, expect PASS**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/test_map_live_next_button.py -v
```

Expected: 1 passed.

### Step 1.10 — Run the full webapp test suite, expect all PASS

- [ ] **Step 1.10: Run the full webapp test suite, expect all PASS**

```bash
cd /home/staszek/lora-universal-simulator/webapp && \
  python -m pytest tests/ -v
```

Expected: 37 passed (the previous 36 plus the new one). No regressions.

### Step 1.11 — Commit

- [ ] **Step 1.11: Commit**

```bash
cd /home/staszek/lora-universal-simulator && \
  git add webapp/static/map_live.html webapp/tests/test_map_live_next_button.py && \
  git commit -m "$(cat <<'EOF'
feat(webapp/map_live): next-event button (replay-mode, packet-level filter)

Adds a ⏭ Next button to map_live.html that advances replay to the next
packet-level event (tx/rx/collision/drop_*/tx_deferred). Filter is hard-
coded — protocol-agnostic. Pauses on click and posts mlv-scrub-time to
the swim-lane iframe so visualize.html recenters in sync.

Spec: docs/superpowers/specs/2026-05-07-map-live-next-button-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Manual Browser Verification

The webapp tests confirm presence-of-strings only; behavior verification requires a browser. **This task must be run by the controller (or a human), not a subagent** — subagents have no browser.

**Files:** None modified. This task is verification, not code.

### Step 2.1 — Build + start the webapp

- [ ] **Step 2.1: Build + start the webapp**

```bash
cd /home/staszek/lora-universal-simulator && \
  cmake --build build -j && \
  cd webapp && \
  bash run.sh
```

Expected: uvicorn starts on `http://0.0.0.0:8000`. Leave running.

### Step 2.2 — Pick (or create) a completed sim

- [ ] **Step 2.2: Pick (or create) a completed sim**

In a browser, open `http://localhost:8000/static/simulations.html`. Pick any completed sim (status `completed`) — the s01 scenario currently fails assertions due to the user's in-flight tweaks, but a completed-with-failures sim still produces valid events that map_live can replay. Note its sim id.

If no sim exists, run one through `simulations.html` → `New simulation`, with the default config or any saved config.

### Step 2.3 — Open map_live and verify Next button appears

- [ ] **Step 2.3: Open map_live and verify Next button appears**

Navigate to `http://localhost:8000/static/map_live.html?id=<sim_id>`.

Verify:
- The header row shows: `⏸ Pause   ⏮ Restart   ⏭ Next   |   Speed: ...   |   now: ...`.
- Hovering `⏭ Next` shows the tooltip `Jump to next packet-level event (tx, rx, drop, collision, deferred)`.

### Step 2.4 — Click Next and verify behavior

- [ ] **Step 2.4: Click Next and verify behavior**

Click `⏭ Next`. Verify:
- Replay pauses (Pause button text changes to `▶ Resume`).
- Time display advances to the time of the first packet-level event.
- The map updates to reflect that event (e.g. a node lights up yellow for `tx`, blue for `rx`, red for `collision`).
- The bottom swim-lane iframe (`visualize.html`) recenters its viewport around the new time.

Click `⏭ Next` repeatedly. Each click should advance to the next packet-level event. The Pause button should stay on `▶ Resume` — pressing Next does not auto-resume.

### Step 2.5 — Verify end-of-replay disables Next

- [ ] **Step 2.5: Verify end-of-replay disables Next**

Click `⏭ Next` until status shows `Replay complete`. Verify:
- The Next button becomes greyed-out / disabled.
- Clicking it again does nothing.

### Step 2.6 — Verify Restart re-enables Next

- [ ] **Step 2.6: Verify Restart re-enables Next**

Click `⏮ Restart`. Verify:
- Replay restarts from `t=0`.
- The Next button is re-enabled.
- Clicking it advances to the first packet-level event (same as Step 2.4).

### Step 2.7 — Verify Pause/Resume + Next interplay

- [ ] **Step 2.7: Verify Pause/Resume + Next interplay**

Restart again. Click Pause. Click Next a few times — should work. Click Resume — replay resumes from the current cursor (no jump back). Click Pause + Next — works. No state corruption.

### Step 2.8 — Verify speed buttons still work after Next

- [ ] **Step 2.8: Verify speed buttons still work after Next**

Restart. Click Next once. Click `1000×` speed. Click Resume. Replay continues at 1000× from the current cursor.

### Step 2.9 — Document the result

- [ ] **Step 2.9: Document the result**

If all of 2.3–2.8 passed: record "manual verification: PASS" in the session notes / merge message. No further action.

If any step failed: stop, capture the failure (screenshot, console log, broken behavior), and surface it before considering the task done.

---

## Self-Review Notes

Coverage check vs. spec sections:
- Filter constant (spec §"Filter") → Step 1.5
- UI button (spec §"UI") → Step 1.3
- DOM ref + state (spec §"State") → Step 1.4
- Refactor `fireEventsUpTo` (spec §"Refactor") → Step 1.6
- Behavior (spec §"Behavior", numbered 1–7) → Step 1.8 implements scan/jump/fire/pause/postMessage; Step 1.6 + Step 1.7 cover disable/re-enable
- Edge cases (spec §"Edge cases") → covered by handler logic + Steps 2.4–2.7 verify them in the browser
- Test (spec §"Testing") → Step 1.1 (regression smoke) + Task 2 (manual)
- Out-of-scope items (Previous, configurable filter UI, two-way iframe sync) → not implemented, as required

No placeholders in the plan — every step has exact code or commands.
