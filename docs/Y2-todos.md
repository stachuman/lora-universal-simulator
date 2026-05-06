# Y2 follow-up TODOs

The Y1 ship (commit `37694d8`, plus the Y1-hardening pass that lands four
parity fixes against upstream `meshcore_real_sim`) covers the core
scripted-node infrastructure end-to-end but leaves several runtime-physics
features dormant for v2. They are built and unit-tested in isolation; just
not wired into the main loop.

## R.1.7 note: single-SF reception default + sf_rx_set opt-in

`nodes[i].sf_rx_set` (default empty -> resolved to `[node.sf]`) selects
which SFs the receiver decodes. Single-SF default matches real Semtech
hardware (SX1262/SX1276/LR1110/SX1280 — confirmed across datasheets and
AN1200.85). Opt into idealized multi-SF reception (e.g. `[7..12]`) for
paper-reproduction (Centelles et al. 2024) or future scanner-repeater
experiments. SF-mismatch packets emit `drop_sf_mismatch`.

## R.1.8 note: dynamic SF retune (`self:set_rx_sf`)

Scripts can retune the receiver's SF set at runtime: `self:set_rx_sf(sf)`
for single-SF and `self:set_rx_sf_set({sf, ...})` for multi-SF. The
modem doesn't reboot — change takes effect for subsequent packets.
Models the announce-and-tune pattern where one node tells listeners to
switch SF for follow-up traffic.

## R.2 note: path-loss + lat/lon topology

Per-node `lat`/`lon` plus a `simulation.path_loss` block (log-distance
model with optional log-normal shadowing) computes the link SNR/RSSI
matrix at sim init. Mixed mode: explicit `topology.links` entries
override the path-loss output for the same pair. Adaptive scripts can
poll the static link SNR via `sim:link_snr(from_name, to_name)` —
returns dB or nil if no link exists.

## Documented in T13's report

### 1. LBT gating before TX scheduling

**Where:** `orchestrator/runtime/Loop.cpp::registerTransmissions`

`LbtModel` (with `cad_miss_prob` interpolation between `cad_reliable_snr`
and `cad_marginal_snr`, matching upstream) is constructed in `runSimulation`
but the `(void)lbt;` cast acknowledges it's unused. Before emitting an
InFlight, the loop should consult `lbt.isChannelBusy(sender, now_ms)` and
either defer or drop the TX with an appropriate event.

Effort: ~1 day. The model itself is done; just wire the call site +
choose the deferral semantic (queue and retry vs drop with `tx_fail`).

### 2. Per-link fading in delivery

**Where:** `orchestrator/runtime/Loop.cpp::deliverReceptions` (where
`snr_at_rcv = lp.snr` today)

`LinkFadingState::advanceFading()` is implemented (OU + i.i.d.) but never
called. Configs with `snr_std_dev > 0` produce deterministic SNR.

Effort: ~half a day. Allocate `n*(n-1)/2` (symmetric, matching upstream) or
`n*n` (directed) `LinkFadingState` slots; update each on every delivery
step; add the offset to `lp.snr` before the link-loss / collision check.

### 3. Strict half-duplex receiver check

**Where:** `Loop.cpp::deliverReceptions`, the `// TODO(Y2)` comment

A receiver currently in TX_WAIT state should drop incoming packets (emit
`drop_halfduplex`). Today the loop just delivers them anyway. SimRadio
already exposes the necessary `isInRecvMode()` / state query.

Effort: ~1 hour. Single conditional in deliverReceptions before calling
`onRecv`.

### 4. `tx_fail_prob` plumbing

**Where:** `Loop.cpp::registerTransmissions`

`SimRadio::setTxFailProb()` exists, and `JsonConfig` parses
`nodes[i].tx_fail_prob`, but Loop never plumbs the per-node value into the
radio nor consults the radio's TX-fail counter when emitting the InFlight.

Effort: ~1 hour. Set the prob at SimRadio construction; check
`radio->getTxFailCount()` change before pushing the InFlight; emit
`tx_fail` and skip the InFlight if it bumped.

### 5. `SimRadio::notifyRxStart` / `notifyChannelBusy` from Loop

**Where:** `Loop.cpp::registerTransmissions` and `deliverReceptions`

The radio's bookkeeping methods are never called from the Loop. Upstream
calls them to maintain accurate per-radio state. Without these calls, the
radio's `isReceiving()` and `isInRecvMode()` are stuck.

Effort: built into items 1 and 3 above; no extra work.

## Diagnostic / lifecycle gaps (not blocking, but should land soon)

### 6. `node_stats` event at sim_end

Upstream emits per-node stats (packets sent / received / collided / dropped)
as a `node_stats` event during sim teardown. Target's `EventLog::nodeStats`
exists but is never called. Wire from Loop after the main loop.

Effort: ~half an hour.

## Architectural follow-ups

### 7. Configurable Lua VM per node (vs shared)

The current `LuaHost` uses one `sol::state` for the whole sim with per-node
isolation via `_LUS.nodes[id].self`. Buggy scripts can leak state via
globals. Y2 may want per-node VMs for stronger isolation (cost: 5-10x memory,
~100KB x 200 = 20MB extra at the perf-test scale; acceptable).

### 8. LuaJIT swap (escape hatch)

If perf becomes a bottleneck (Y1 measurement: 5.9s for 200 nodes x 1h ->
plenty of headroom), the Lua host can be rebuilt against `libluajit-5.1-2`.
sol2 supports both with the same source.

### 9. Map view + scenario editor + interactive REPL

The webapp components from `meshcore_real_sim/webapp/` are protocol-agnostic
and can be ported when the project needs richer UX. Y1 ships orchestrator-
only.
