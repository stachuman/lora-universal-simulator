# RF Parameters in Events + SF/BW Sub-Rows in Lane View — Design

Status: design (awaiting plan)
Author: 2026-05-07 session

## Goal

1. Surface the LoRa physical-layer parameters of every transmission in the
   webapp:
   - `sf` (spreading factor, 7..12)
   - `bw_hz` (bandwidth in Hz; typically 125000, 250000, 500000)
   - `cr` (coding rate denominator: 5..8 for 4/5..4/8)
2. Render `(sf, bw_hz)` orthogonality visually in the swim-lane viewer
   (`visualize.html`) by splitting each node lane into sub-rows — one
   per `(sf, bw_hz)` tuple actually used in the simulation.
3. Surface `cr` in the click-details sidebar that already exists in
   `visualize.html`. (Sub-rows already encode `sf` and `bw_hz`.)

The user motivation: "different SFs (and different BWs) don't collide,
so I want to see at a glance whether two overlapping bars are on the
same channel or not." Putting them on separate visual rows makes that
trivially obvious.

### Excluded from per-tx events (intentional)

- `tx_power_dbm` — currently a global path-loss parameter
  (`simulation.path_loss.tx_power_dbm`, single value across the run).
  Per-tx variance isn't supported in lus today. Surface in the
  sim-metadata view, not per-event.
- `freq_hz` — lus is single-channel; no frequency tracking exists.
  If multi-channel support lands later, revisit then.

## Scope

- Orchestrator C++ change to `core/events/EventLog.{h,cpp}` and the call
  sites in `orchestrator/runtime/SimController.cpp`.
- Frontend change to `webapp/static/visualize.html`: pre-scan events to
  build a sub-row layout; render bars in their sub-row; extend the
  click-details panel.
- Regression tests for both layers.

## Out of scope

- `map_live.html` map-view changes — the map shows TX state per node, not
  per-channel. SF/BW visualization on the map is a different feature.
- Per-link fading visualization — separate feature.
- Existing sims (events.ndjson without `sf`/`bw_hz` fields) — handled
  gracefully (see "Backwards compatibility" below) but not retro-fitted.

## Event schema changes

### `tx` event — add 3 fields

Current:
```json
{"type":"tx","time_ms":917,"node":"dave","pkt":"34d405f6","hex":"420300","airtime_ms":18,"label":"BCN","info":"rt=0"}
```

New:
```json
{"type":"tx","time_ms":917,"node":"dave","pkt":"34d405f6","hex":"420300","airtime_ms":18,"sf":7,"bw_hz":125000,"cr":5,"label":"BCN","info":"rt=0"}
```

The new fields go BEFORE `label`/`info` (which are optional) so the
existing optional-field-suffix logic in `EventLog::tx()` doesn't need to
change.

### `rx` event — add 3 fields

Same three fields, mirroring `tx`. Sub-row routing in the lane view
needs the rx side to know `(sf, bw_hz)` independently — the user can
have a node "listening on SF7" and the rx event lands in that sub-row
even if the tx happened to be on SF7 too.

(Note: in lus, the receiver's `(sf, bw_hz)` must match the sender's
for a successful rx — `drop_sf_mismatch` is emitted otherwise. So in
practice the rx event's `(sf, bw_hz)` equals the tx's. We still emit
both so that pkt-cross-references aren't required for sub-row routing.)

### `drop_*` events — add `sf` and `bw_hz` only

The drop events (`drop_weak`, `drop_loss`, `drop_halfduplex`,
`drop_sf_mismatch`) need `(sf, bw_hz)` for sub-row placement.
`drop_sf_mismatch` already carries `packet_sf` and `rx_sf` — the new
`sf`/`bw_hz` fields denote the **packet's** sf/bw (matches `packet_sf`),
which is the row the bar belongs in.

`cr` is not added to drop events; it's inherited from the originating
tx via the `pkt` cross-reference if a detail panel needs it.

### `tx_deferred` event — no changes required

It only references the deferring node, not a specific packet's SF/BW
(deferral happens before the radio commits to a frame). Keeping it
unchanged.

### `collision` event — add `sf` and `bw_hz`

Same as the drop events. Collision rendering needs to land in the
correct sub-row.

## Orchestrator implementation

### `core/events/EventLog.h` — extend signatures

```cpp
void tx(unsigned long time_ms, const char* node,
        const uint8_t* data, int len, uint32_t airtime_ms,
        int sf, int bw_hz, int cr,
        const char* label, const char* info);

void rx(unsigned long time_ms, const char* from, const char* to,
        float snr, float rssi,
        const uint8_t* data, int len, uint32_t airtime_ms,
        int sf, int bw_hz, int cr);

void dropWeak(unsigned long time_ms, const char* from, const char* to,
              float snr, float rssi,
              const uint8_t* data, int len, uint32_t airtime_ms,
              int sf, int bw_hz);
// ... and similarly for dropLoss, dropHalfDuplex, dropSfMismatch,
// collision
```

### `orchestrator/runtime/SimController.cpp` — pass values at every call site

The four `EventLog::tx` / `EventLog::rx` call sites at lines 558, 612,
627, 750 already compute `sf`, `bw_hz`, `cr` (lines 600–602) — pass
them through. The rx-side call sites need the receiver's local sf/bw/cr
(read from `_radios[r]->getSF()` / `getBwHz()` / `getCR()`).

`SimRadio` already exposes `getSF()`, `getBwHz()`, `getCR()`. No new
getters required.

### Test side: `test/native/test_eventlog.cpp`

Update the call to `EventLog::tx` (line 27) to include the new
positional args. Pass dummy values: `sf=7, bw_hz=125000, cr=5`.

## Frontend implementation (visualize.html)

### Pre-scan: build the sub-row layout

After events are loaded (or within the existing `loadViewport` /
`render` flow), do a one-pass scan of the in-cache events to compute:

```js
S.subRows = [];           // ordered: e.g. [{sf:7, bw_hz:125000}, {sf:9, bw_hz:125000}, {sf:12, bw_hz:125000}]
S.subRowIndex = new Map(); // key "sf|bw_hz" -> index into subRows
```

Computed lazily on first render; refreshed when new events are loaded
(invalidate when `S.cachedFrom`/`cachedTo` change).

If no event carries `sf`/`bw_hz` (legacy sim), `subRows` is empty and
sub-row mode is disabled — the lane view falls back to the existing
single-row-per-node rendering.

### Lane height

`S.laneH` (currently `22`) becomes the **sub-row height**. The total
height of each node lane is `subRows.length * laneH` (or just
`laneH` if `subRows` is empty).

### Sub-row labels

In the label column on the left, under the node name (current 14 px
font), each sub-row gets a small label: `SF7 / 125k`, `SF9 / 125k`,
`SF12 / 250k` (font 9 px monospace). Labels render only on the
sub-row's row, not repeated.

If a node has zero events for a particular `(sf, bw_hz)`, its sub-row
is empty — but still drawn as background (lighter shade) so the user
can confirm "yes, we're showing all SFs on every node."

### Bar rendering

Compute the sub-row index per event:
```js
function subRowFor(ev) {
  if (!ev.sf || !ev.bw_hz) return 0;  // legacy fallback to first row
  const key = ev.sf + '|' + ev.bw_hz;
  return S.subRowIndex.get(key) || 0;
}
```

Then bar Y = `S.headerH + nodeIdx * (subRows.length * laneH) + subRowIdx * laneH - S.scrollY`.

The bar's height shrinks slightly to fit `laneH` (already small).

### Bar color

Existing per-packet color (hash of pkt) stays — it's how the user
visually correlates a TX with its receivers. The sub-row position
already encodes SF/BW, so we don't need to also color by SF.

### Click-details panel

The sidebar (already exists; rendered when user clicks a packet) gets
new rows for the RF params. Append rows for any of `sf`, `bw_hz`, `cr`
that are present.

Format: `SF7`, `BW 125 kHz`, `CR 4/5`.

### Hover tooltip

The existing on-hover label (when the user hovers a TX bar) already
shows `label` / `info` inline. Append a compact suffix like
`SF7/125k` so the user can scan params without clicking.

## Backwards compatibility

If a sim's events don't have `sf`/`bw_hz` (e.g., generated before this
change):
- All bars land in the single fallback row.
- Sub-row layout collapses to the current behavior.
- Click-details panel skips the missing fields gracefully.

No version migration needed. Pre-existing `webapp/data/simulations/`
runs continue to work.

## Testing

### C++ — `test/native/test_eventlog.cpp`

Extend the existing test to assert the new fields are emitted:
- Call `EventLog::tx` with known `sf=7, bw_hz=125000, cr=5,
  tx_power_dbm=14, freq_hz=868100000`.
- Capture the emitted line.
- Assert the JSON contains `"sf":7`, `"bw_hz":125000`, `"cr":5`,
  `"tx_power_dbm":14`, `"freq_hz":868100000`.

Repeat for `rx` and one of the drop variants.

### Python webapp — string-presence regression

Two checks in `webapp/tests/test_visualize_sublanes.py` (new file):
1. `GET /static/visualize.html` and assert it references `S.subRows`,
   `subRowFor`, and the new sub-row rendering symbols.
2. End-to-end: start a small lus sim that uses two SFs (e.g. an
   existing `t06_sf_mismatch` scenario), then GET `/api/sims/<id>/events`
   and assert at least one event carries `sf` and `bw_hz` keys.

The end-to-end variant requires the lus binary; if unavailable, skip
(matching the pattern in `test_smoke_e2e.py`).

### Manual browser verification

Open `visualize.html?id=<sim>` for a sim that uses multiple SFs and
verify:
- Every node lane has the expected number of sub-rows.
- Sub-row labels read `SF7 / 125k`, `SF12 / 125k`, etc.
- TX bars land in the correct sub-row by SF/BW.
- Two TX bars at different SFs but overlapping in time render as
  two separate bars in different sub-rows.
- Clicking a TX bar shows all five RF params in the sidebar.

## Risks

- **Lane height grows** — for a sim with 4 unique `(sf, bw_hz)`
  combos, lane height quadruples. Mitigation: empty sub-rows render
  in a slightly different background so the user can fold mentally;
  lane-height is configurable via the same `laneH` knob.
- **Cross-reference for drop events without rx** — a `drop_sf_mismatch`
  with the wrong rx_sf still belongs in the *packet's* SF row, not
  the receiver's. The schema specifies `sf` as the packet's SF;
  callers must respect that.
- **Performance** — pre-scan over the cached events on every viewport
  load. Cheap (linear in #events) but called per-render. We compute
  once after events load, not per-frame.

## Estimated size

- C++: ~80 LOC across `EventLog.h`, `EventLog.cpp`, `SimController.cpp`,
  one test file. Single commit.
- visualize.html: ~150 LOC. Single commit.
- Tests: ~60 LOC. Bundled with each impl commit.

## Files touched

| File | Action |
|---|---|
| `core/events/EventLog.h` | modify — extend signatures |
| `core/events/EventLog.cpp` | modify — emit new fields |
| `orchestrator/runtime/SimController.cpp` | modify — pass values at call sites |
| `test/native/test_eventlog.cpp` | modify — assert new fields |
| `webapp/static/visualize.html` | modify — sub-row layout, click panel |
| `webapp/tests/test_visualize_sublanes.py` | create — regression smoke |
