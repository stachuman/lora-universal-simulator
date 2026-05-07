# Map-Live Next-Event Button — Design

Status: design-approved (awaiting plan)
Author: 2026-05-07 session

## Background

`webapp/static/map_live.html` is the post-simulation replay view (loaded
as `/static/map_live.html?id=<sim_id>`). All events for the run are
fetched once and replayed in the browser by advancing
`replayCursor` via `requestAnimationFrame`, scaled by `playbackSpeed`.
Today the user can Pause, Restart, and pick a speed — but cannot
single-step through events on the map.

The interactive view (`interactive.html`) already exposes a `Next`
button; it sends `{cmd: 'next'}` over the WebSocket which calls the
orchestrator's `:next` REPL meta-command. That path is irrelevant here
because in replay mode no orchestrator is running — the events are
already in the browser.

## Goal

Add a `Next` button to `map_live.html` that advances the replay to the
next packet-level event, regardless of which Lua protocol is being
visualized.

## Scope

- Frontend-only. No backend changes, no orchestrator changes,
  no events schema changes.
- Replay mode (`map_live.html?id=<sim>`) only.
- A single new button + ~40 LOC of script changes.

## Out of scope

- Previous button. Backward stepping requires rebuilding accumulated
  map state (active TX overlays, node colors) from `t=0`, which is
  doable but not requested.
- Configurable filter UI. The filter is a hard-coded constant; can be
  revisited if a future scenario needs it.
- Cursor sync from the swim-lane iframe back to the map. The data
  flow is one-directional: map drives, swim-lane follows.

## Filter — what counts as "next event"

A hard-coded set of packet-level event types that exist regardless of
the Lua protocol in use. These are emitted by the C++ runtime, not by
script logic:

```js
const NEXT_EVENT_FILTER = new Set([
  'tx',
  'rx',
  'collision',
  'drop_weak',
  'drop_sf_mismatch',
  'drop_halfduplex',
  'drop_loss',
  'tx_deferred',
]);
```

Excluded by design:
- `script_log`, `script_emit`, `cmd_reply` — protocol-specific, varies
  per Lua scenario.
- `node_ready`, `sim_start`, `sim_end` — bookkeeping, not interesting
  for stepping.
- Any other future event types fall through unless explicitly added.

## UI

In the existing `.mlv-controls` row, between `Restart` and the speed
buttons:

```
⏸ Pause    ⏮ Restart    ⏭ Next    |    Speed: 1× 10× 100× 1000×    |    now: 0.0s / 0.0s
```

- Button text: `⏭ Next`
- Tooltip: `Jump to next packet-level event (tx, rx, drop, collision, deferred)`
- Disabled state: when `replayCursor >= replayEndMs` (replay complete).
  Re-enabled by `Restart`.

## Behavior

On `Next` click (handler `onNextEvent`):

1. **Guard:** if `replayCursor >= replayEndMs`, no-op (button should
   already be disabled).
2. **Scan** `allEvents` starting at `replayNextIdx` for the first
   index `j` where `allEvents[j].type ∈ NEXT_EVENT_FILTER`.
3. **If no match found** in the remaining events:
   - Jump `replayCursor = replayEndMs`.
   - Fire any remaining events via `fireEventsUpTo(replayEndMs)`.
   - Set status to `Replay complete`.
   - Disable Next button.
4. **If a match `j` is found:**
   - Set `replayCursor = fireMs(allEvents[j])`.
   - Call `fireEventsUpTo(replayCursor)` — fires all events whose
     `fireMs <= replayCursor`, including the matched event and any
     non-interesting events between the current cursor and `j`.
   - Update `replayNextIdx` (now `j + 1` plus any further events at
     the same `fireMs`).
5. **Pause** the replay loop:
   - `replayPaused = true`
   - `btnPause.textContent = '▶ Resume'`
6. **Sync the swim-lane iframe:**
   - `tlFrame.contentWindow.postMessage({type: 'mlv-scrub-time', t: replayCursor}, '*')`
   - `visualize.html` already listens for this message
     (`visualize.html:1351-1356`) and recenters its viewport on `t`.
   - Best-effort; wrapped in `try/catch` to swallow same-origin /
     not-yet-loaded errors silently.
7. Update time display + event counter.

## Refactor

Currently `replayFrame()` contains:

```js
while (replayNextIdx < allEvents.length && fireMs(allEvents[replayNextIdx]) <= replayCursor) {
  fireEvent(allEvents[replayNextIdx]);
  replayNextIdx++;
}
```

Extract into a helper:

```js
function fireEventsUpTo(targetMs) {
  while (replayNextIdx < allEvents.length && fireMs(allEvents[replayNextIdx]) <= targetMs) {
    fireEvent(allEvents[replayNextIdx]);
    replayNextIdx++;
  }
}
```

Both `replayFrame` and `onNextEvent` call it. Same logic, different
call site.

## State

No new persistent state. The button reuses:

- `replayCursor`, `replayNextIdx`, `replayPaused`, `replayEndMs`,
  `allEvents` — all already defined.
- `btnPause`, `controlsEl` — already wired.

One new DOM ref: `btnNext = $('btn-next')`.

## Disable / re-enable rules

- **Disabled** when `replayCursor >= replayEndMs` (set in
  `replayFrame()` end-branch and in `onNextEvent`'s no-match branch).
- **Re-enabled** in `restartReplay()` (alongside the existing pause
  button reset).
- **Visible / hidden** with the rest of `.mlv-controls` (currently
  toggled in `startReplay()`).

## Edge cases

| Case | Behavior |
|---|---|
| Click while playing | Auto-pauses, then jumps. Pause-on-Next is intentional. |
| Click after Restart | Works from `t=0` again. |
| Click with no matching events left | Jump to end, disable button, status = "Replay complete". |
| Multiple events share the next `fireMs` | All fire on the single click (the inner `<=` covers them). |
| Iframe not yet loaded | postMessage wrapped in try/catch; map jump still proceeds. |
| Same-time bursts (e.g. all 4 nodes tx-deferred at t=10000) | Each Next click stops at the next distinct packet-level event; if four packet-level events share the same fireMs, one click fires all four. Acceptable per design — this is how Filter 1 + same-fireMs works. |

## Testing

The webapp's Python pytest suite is HTTP-level and doesn't drive the
browser; there is no headless browser harness in the repo. So this
feature needs **manual verification**.

Manual test plan (run after implementation):

1. Build + run webapp: `cmake --build build -j && cd webapp && bash run.sh`.
2. Use any completed sim (e.g. an earlier s01 run before the user's
   current iteration broke the assertions).
3. Open `/static/map_live.html?id=<id>`. Confirm the new `⏭ Next`
   button is visible alongside Pause/Restart.
4. Click Next: replay should pause, cursor jumps to the first
   packet-level event, swim-lane iframe recenters, time display
   updates.
5. Click Next repeatedly: each click advances; if the next event is
   far ahead time-wise, the jump is large but no events are skipped
   visually (intermediate non-interesting events fire during the
   jump).
6. After every event has fired, Next becomes disabled and status
   shows "Replay complete".
7. Click Restart: Next re-enables. Repeat from step 4.
8. Click Pause/Resume mid-stepping; confirm Next still works.
9. Speed buttons should still work after Next is used.

Document the manual test result in the implementation PR.

## Risk

Low. The change is local to `map_live.html`, reuses existing replay
machinery, doesn't touch any shared module. Worst-case regression is
that Next misbehaves; the existing Pause/Restart/Speed controls are
unaffected because the new button doesn't share their event handlers.

## Files touched

- `webapp/static/map_live.html` — only file modified.

## Estimated size

~40 LOC added, ~5 LOC refactored (the `fireEventsUpTo` extraction).
Single small commit.
