# Phase R.1 — Radio physics parity for the routing-paper reproduction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking. Each task lands with a dedicated test that demonstrates the new behavior — "existing tests still pass" is necessary but not sufficient.

**Goal:** Bring the simulator's radio physics to a level where the Centelles et al. 2024 paper's findings can in principle be reproduced. Six focused fixes to the runtime, each with a dedicated test.

**Source paper:** `docs/A_Minimalistic_Distance-Vector_Routing_Protocol_for_LoRa_Mesh_Networks.pdf`

**Working repo:** `/home/staszek/lora-universal-simulator` on `main`.

---

## Conventions

- Plain commit messages, NO Co-Authored-By trailer
- Each task = ONE commit covering implementation + dedicated test
- Tests should assert **both** positive (new behavior fires under expected conditions) **and** negative (old behavior preserved when conditions don't apply) cases
- The test goes in the SAME commit as the implementation
- All existing tests (8 native + 3 integration) must continue to pass

---

## Task R.1.1 — Cross-SF orthogonality in CollisionModel

**Files:**
- Modify: `core/physics/CollisionModel.{h,cpp}`
- Create: `test/native/test_cross_sf_orthogonality.cpp`
- Modify: `test/native/build_test.sh`

**Background:** Two LoRa transmissions on the same channel using different SFs are quasi-orthogonal — they don't collide. Today `evaluateCollision` runs the 3-stage capture/grace/FEC decision regardless of SF, so cross-SF interferers are wrongly treated as colliders. Add an early return when `primary.sf != interferer.sf`.

We model perfect orthogonality for v1 (Croce 2018's imperfect-orthogonality SIR penalty is a future refinement).

- [ ] **Step 1.1.1: Add the early-return at the top of `evaluateCollision`**

In `core/physics/CollisionModel.cpp`:
```cpp
CollisionDecision evaluateCollision(const CollisionConfig& cfg,
                                     const CapturedSignal& primary,
                                     const CapturedSignal& interferer) {
    // Quasi-orthogonality: TXes on the same channel using different SFs
    // can be demodulated independently by their respective receivers.
    // (See Croce et al. 2018 for imperfect-orthogonality refinements; v1
    //  models perfect orthogonality.)
    if (primary.sf != interferer.sf) {
        return {true, /*reason*/0};   // 0 = clean
    }
    // ... existing 3-stage logic ...
}
```

(The exact `reason_code` constants live in CollisionModel.h; use whichever code you have for "clean / no collision".)

Verify the constant for "clean" — read the header to confirm. If clean is `0` use 0; if it's a named constant use that.

- [ ] **Step 1.1.2: Write `test/native/test_cross_sf_orthogonality.cpp`**

Both positive (cross-SF survives) and negative (same-SF still collides at low SNR margin):

```cpp
#include "core/physics/CollisionModel.h"
#include <cassert>
#include <cstdio>

int main() {
    CollisionConfig cfg;

    // Same-SF, low SNR margin → should collide (existing behavior)
    CapturedSignal a_sf7{ /*src*/0, /*snr*/5.0f, /*start*/100, /*end*/200,
                          /*cr*/5, /*pre_sym*/8, /*t_sym*/4.1f, /*t_pre*/49.2f };
    CapturedSignal b_sf7{ 1, 4.0f, 110, 210, 5, 8, 4.1f, 49.2f };
    auto same_sf = evaluateCollision(cfg, a_sf7, b_sf7);
    assert(!same_sf.survived);   // baseline: same-SF, low-margin still collides

    // Cross-SF (SF7 vs SF10) → should survive even with overlapping windows
    // and no SNR margin advantage
    CapturedSignal b_sf10{ 1, 4.0f, 110, 210, 5, 8, 32.8f, 393.2f };
    b_sf10.sf = 10;   // (assuming sf is settable; if cr is what was meant
                       //  for the field name, adjust to match the actual struct)
    a_sf7.sf = 7;
    auto cross_sf = evaluateCollision(cfg, a_sf7, b_sf10);
    assert(cross_sf.survived);
    // reason should indicate clean (no actual collision check ran)

    std::printf("test_cross_sf_orthogonality: OK\n");
    return 0;
}
```

(Adjust the `CapturedSignal` field initialization to match the actual struct shape — read the header. The sf field may be named `sf` or part of `cr`; verify before writing. The point is to set primary.sf = 7, interferer.sf = 10 and show it survives.)

- [ ] **Step 1.1.3: Wire into `build_test.sh`**

```bash
run test_cross_sf_orthogonality test_cross_sf_orthogonality.cpp \
    $REPO_ROOT/core/physics/CollisionModel.cpp
```

- [ ] **Step 1.1.4: Run all tests**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
bash /home/staszek/lora-universal-simulator/test/run_tests.sh
```

Expected: 9/9 native (existing 8 + new), 3/3 integration. Existing `test_physics.cpp` must still pass — its same-SF capture/grace/FEC cases are unaffected by the cross-SF early return.

- [ ] **Step 1.1.5: Commit**

```
fix(physics): cross-SF transmissions are non-colliding (quasi-orthogonal)

Two TXes on the same channel with different SFs can be demodulated
independently by their respective receivers (Croce et al. 2018).
Today's evaluateCollision ran the 3-stage capture/grace/FEC decision
against any time-overlapping interferer, regardless of SF — wrong for
LoRa. Add an early return when primary.sf != interferer.sf.

This is the foundation for the multi-SF ToA routing metric findings
in Centelles et al. 2024 (Phase R reproduction work).

Test: test_cross_sf_orthogonality asserts both directions:
  - same-SF, low SNR margin → still collides (no regression)
  - cross-SF (SF7 vs SF10) overlap → survives cleanly
```

---

## Task R.1.2 — Multi-SF reception (receivers omnivorous on single channel)

**Files:**
- Modify: `core/radio/SimRadio.{h,cpp}` — `getSnrThreshold(int sf)` overload
- Modify: `orchestrator/runtime/SimController.cpp` — call threshold with packet's SF
- Create: `test/native/test_multi_sf_reception.cpp`
- Modify: `test/native/build_test.sh`

**Background:** A single-channel LoRa receiver dynamically tunes to the SF of an incoming preamble. Today `SimRadio::getSnrThreshold()` returns the threshold for the receiver's *currently configured* SF (`_sf`). The Loop's delivery path doesn't gate on SNR threshold yet (that's R.1.3), but once it does, it must use the *packet's* SF, not the receiver's. Refactor the API now to enable that.

- [ ] **Step 1.2.1: Add `getSnrThreshold(int sf)` overload**

In `core/radio/SimRadio.h`:
```cpp
class SimRadio {
public:
    // Existing: returns threshold for current _sf
    float getSnrThreshold() const;
    // New: returns threshold for the given SF (7..12)
    static float getSnrThreshold(int sf);
};
```

In `core/radio/SimRadio.cpp`:
```cpp
float SimRadio::getSnrThreshold(int sf) {
    static const float snr_threshold[] = {
        -7.5f, -10.0f, -12.5f, -15.0f, -17.5f, -20.0f   // SF7..SF12
    };
    if (sf < 7 || sf > 12) return -100.0f;   // fallback: very tolerant
    return snr_threshold[sf - 7];
}

float SimRadio::getSnrThreshold() const {
    return getSnrThreshold(_sf);
}
```

(Adjust the table values to match what's actually in the existing implementation — keep the values the same, just add the static overload.)

- [ ] **Step 1.2.2: Document the multi-SF reception model**

Add a comment block above `getSnrThreshold(int sf)`:
```cpp
// Multi-SF reception: a single-channel LoRa receiver dynamically tunes
// its SF on each incoming preamble. The receiver's _sf only constrains
// what it transmits, not what it can receive. Therefore the SNR
// threshold lookup at delivery time uses the PACKET's SF, not the
// receiver's — call this overload from the loop's deliverReceptions.
```

- [ ] **Step 1.2.3: Write `test/native/test_multi_sf_reception.cpp`**

Verify both:
- (positive) Receiver at SF7 can decode an incoming SF10 packet if SNR > SF10 threshold
- (negative) The packet's SF determines the threshold (an SF7 packet at SF10's threshold should fail)

```cpp
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    // The static overload should not depend on radio state
    float t7  = SimRadio::getSnrThreshold(7);
    float t10 = SimRadio::getSnrThreshold(10);
    float t12 = SimRadio::getSnrThreshold(12);
    // Higher SF should tolerate lower SNR (more negative threshold)
    assert(t7  > t10);
    assert(t10 > t12);
    assert(t12 < -15.0f);   // SF12 typically below -17 dB

    // Ensure the instance method matches the static for the configured _sf
    VirtualClock clk;
    SimRadio radio(clk);
    radio.setRadioParams(/*sf=*/7, /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSnrThreshold() == SimRadio::getSnrThreshold(7));
    radio.setRadioParams(/*sf=*/10, /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSnrThreshold() == SimRadio::getSnrThreshold(10));

    std::printf("test_multi_sf_reception: OK (t7=%f t10=%f t12=%f)\n", t7, t10, t12);
    return 0;
}
```

(The actual integration with deliverReceptionsForStep happens in R.1.3 — this task only adds the static overload + verifies its semantics.)

- [ ] **Step 1.2.4: Wire into build_test.sh + run all tests**

```bash
run test_multi_sf_reception test_multi_sf_reception.cpp \
    $REPO_ROOT/core/radio/SimRadio.cpp
```

- [ ] **Step 1.2.5: Commit**

```
feat(radio): SimRadio::getSnrThreshold(sf) static overload for multi-SF reception

A single-channel LoRa receiver tunes its SF dynamically on each
incoming preamble. The receiver's _sf only constrains what it
transmits, not what it can receive. The existing instance-method
getSnrThreshold() returns the threshold for the receiver's current
_sf — wrong for delivery decisions, where we need the threshold
for the PACKET's SF.

Add a static overload getSnrThreshold(int sf). The loop will call
it in R.1.3 to gate receivability against the packet's SF.

Test: asserts SF12 threshold < SF10 < SF7 (higher SF tolerates
lower SNR), and that the instance method is consistent with the
static lookup.
```

---

## Task R.1.3 — SF-dependent SNR threshold gate in Loop → emit `drop_weak`

**Files:**
- Modify: `orchestrator/runtime/SimController.cpp` — `deliverReceptionsForStep`
- Create: `test/native/test_drop_weak.cpp` (or integration test)
- Modify: `test/native/build_test.sh` (or t03 integration)

**Background:** Today the delivery loop compares against link SNR being "configured" (snr > -100), not against the SF-dependent decoding threshold. Packets with SNR below the SF's threshold should drop with a `drop_weak` event, not silently deliver.

- [ ] **Step 1.3.1: Add the threshold gate in `deliverReceptionsForStep`**

In `SimController::deliverReceptionsForStep`, find the loop where `snr_at_rcv` is computed and `onRecv` is called. Before delivery:

```cpp
float thr = SimRadio::getSnrThreshold(in_flight[idx].sf);
if (snr_at_rcv < thr) {
    EventLog::dropWeak(now, nodes[in_flight[idx].sender_id]->name().c_str(),
                        nodes[rcv]->name().c_str(),
                        snr_at_rcv, thr);
    continue;
}
```

(Verify the `EventLog::dropWeak` signature — read `core/events/EventLog.h`. If the function doesn't take `(snr, threshold)` adjust to whatever it does take. If `dropWeak` doesn't exist yet but `drop_weak` is a documented event type, add the emitter to EventLog.{h,cpp}.)

- [ ] **Step 1.3.2: Write `test/native/test_drop_weak.cpp`** OR a JSON test

Easiest: a JSON integration test `test/t03_drop_weak.json`. Three nodes; two with link SNR low enough that an SF7 TX from one should be `drop_weak` at the other, but an SF10 TX (lower threshold) should succeed.

```json
{
  "_name": "t03_drop_weak",
  "_desc": "alice -> bob with link SNR -16 dB. SF7 TX (threshold ~-7.5 dB) → drop_weak. SF12 TX (threshold ~-20 dB) → rx.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 7, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/sf_picker.lua", "config": { "role": "originator" } },
    { "name": "bob",   "script": "examples/sf_picker.lua", "config": { "role": "receiver" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": -16.0, "rssi": -110.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 5000,  "node": "alice", "command": "send_sf 7 hello-sf7" },
    { "at_ms": 15000, "node": "alice", "command": "send_sf 12 hello-sf12" }
  ],
  "expect": [
    { "type": "event_count_min", "event_type": "drop_weak", "node": "bob", "min": 1 },
    { "type": "event_count_min", "event_type": "rx", "node": "bob", "min": 1 }
  ]
}
```

You'll need a small `examples/sf_picker.lua` that takes `send_sf <sf> <text>` and TXes at the chosen SF:

```lua
function on_init(self, config) end

function on_command(self, cmd_str)
  local sf, text = cmd_str:match("^send_sf (%d+) (.+)$")
  if not sf then return "ERROR: usage: send_sf <sf> <text>" end
  self:tx(text, { sf = tonumber(sf) })
  return "sent at sf=" .. sf
end

function on_recv(self, frame, meta)
  self:log("recv: " .. frame)
end
```

Both events asserted: drop_weak (SF7 fails) AND rx (SF12 succeeds). This proves the threshold is BOTH being checked AND respects the packet's SF.

- [ ] **Step 1.3.3: Run all tests**

`bash test/run_tests.sh` should now report 4/4 PASS (added t03).

- [ ] **Step 1.3.4: Commit**

```
feat(loop): SF-dependent SNR threshold gate; emit drop_weak

deliverReceptionsForStep now compares the link's SNR against the
packet's SF-specific decoding threshold (via SimRadio::getSnrThreshold).
Packets below threshold drop with a drop_weak event; only packets
strong enough for their SF reach the script's on_recv.

Test: t03_drop_weak with examples/sf_picker.lua exercises both
directions:
  - alice TX at SF7 over a -16dB link → drop_weak (threshold ~-7.5dB)
  - alice TX at SF12 over the same link → rx (threshold ~-20dB)
```

---

## Task R.1.4 — Per-packet preamble length override

**Files:**
- Modify: `orchestrator/runtime/ScriptedNode.{h,cpp}` — accept `preamble_sym` in tx opts
- Modify: `orchestrator/runtime/SimController.cpp` — apply preamble in airtime calc
- Modify: `core/radio/SimRadio.{h,cpp}` — already has `getPreambleSymbols()`, may need a setter
- Create: `test/native/test_preamble_override.cpp`
- Modify: `test/native/build_test.sh`

**Background:** The paper uses 16-symbol preamble; we default to 8. Easy fix: extend the `tx` opts table to accept `preamble_sym`, and apply it in the airtime calculation.

- [ ] **Step 1.4.1: Add preamble field to `PendingTx` and `api_tx`**

In `ScriptedNode.h`:
```cpp
struct PendingTx {
    std::string bytes;
    int sf = -1;
    int bw_hz = -1;
    int cr = -1;
    int power_dbm = -127;
    int preamble_sym = -1;   // -1 = use radio default
};
```

In `ScriptedNode.cpp::api_tx`, parse `opts["preamble_sym"]` and store it.

- [ ] **Step 1.4.2: Apply preamble in airtime calc**

In `SimController::registerTransmissionsForStep` (where the radio's params are set per-TX):

```cpp
int preamble = tx.preamble_sym >= 0 ? tx.preamble_sym : radios[i]->getPreambleSymbols();
radios[i]->setPreambleSymbols(preamble);   // if such a setter doesn't exist, add one
uint32_t airtime = radios[i]->getEstAirtimeFor((int)tx.bytes.size());
```

If `SimRadio` has no `setPreambleSymbols`, add it as a small setter. The airtime formula already references the preamble.

- [ ] **Step 1.4.3: Write a focused test**

`test/native/test_preamble_override.cpp`:

```cpp
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    VirtualClock clk;
    SimRadio radio(clk);
    radio.setRadioParams(7, 250000, 5);
    radio.setPreambleSymbols(8);
    uint32_t a8  = radio.getEstAirtimeFor(50);
    radio.setPreambleSymbols(16);
    uint32_t a16 = radio.getEstAirtimeFor(50);
    radio.setPreambleSymbols(32);
    uint32_t a32 = radio.getEstAirtimeFor(50);
    // Longer preamble → longer airtime
    assert(a16 > a8);
    assert(a32 > a16);
    // The difference between a16 and a8 should be ~8 symbols of t_sym
    double t_sym = radio.getSymbolMs();
    double delta = (double)(a16 - a8);
    double expected = 8.0 * t_sym;
    assert(delta >= expected - 0.5 && delta <= expected + 0.5);

    std::printf("test_preamble_override: OK (a8=%u a16=%u a32=%u t_sym=%fms)\n",
                a8, a16, a32, t_sym);
    return 0;
}
```

- [ ] **Step 1.4.4: Wire + run + commit**

Standard pattern. Commit message:
```
feat(radio): per-tx preamble_sym override + setter on SimRadio

Scripts can now opt into a longer preamble (e.g. 16 syms for paper
reproduction) per packet via self:tx(bytes, { preamble_sym = 16 }).
SimRadio gains setPreambleSymbols which the loop sets before
getEstAirtimeFor when a per-tx override is present.

Test: test_preamble_override asserts 16-sym airtime exceeds 8-sym
by exactly 8 * t_sym.
```

---

## Task R.1.5 — Wire fading into delivery (`snr_std_dev` actually applied)

**Files:**
- Modify: `orchestrator/runtime/SimController.{h,cpp}` — allocate fading state vector, call `advanceFading` in delivery
- Create: `test/native/test_fading_applied.cpp` OR JSON integration

**Background:** `LinkFadingState::advanceFading()` exists but `SimController` never allocates state vectors or calls it. Configs with `snr_std_dev > 0` are silently treated as deterministic. The paper doesn't strictly need this for its findings, but the gap is undocumented and would mislead anyone studying noisy environments.

For Y1 simplicity: use directed fading (`n*n` slots), not the symmetric `n*(n-1)/2`. Symmetric is what upstream FLoRa uses; directed is more flexible and what most real-world models assume. Document the choice; can add a config knob later.

- [ ] **Step 1.5.1: Allocate fading state**

In `SimController::initialize`, after `_links` is built:
```cpp
_fading.assign(n * n, LinkFadingState{});  // directed, n*n entries
```

`std::vector<LinkFadingState> _fading;` in the header.

- [ ] **Step 1.5.2: Apply fading in delivery**

In `deliverReceptionsForStep`, where `snr_at_rcv = lp.snr;` currently lives:

```cpp
LinkFadingState& fs = _fading[in_flight[idx].sender_id * n + rcv];
float offset = advanceFading(fs, lp.snr_std_dev,
                              _cfg.simulation.radio.snr_coherence_ms,
                              step_ms_since_last_update,
                              _rng);
float snr_at_rcv = lp.snr + offset;
```

(The exact arg order of `advanceFading` may differ; read the header.)

You'll need to track when each fading state was last updated to compute `dt`. The simplest model: update once per simulator step (in tickTimers or at delivery time). For the paper's purposes, per-delivery is fine.

- [ ] **Step 1.5.3: Write a dedicated test**

A JSON integration test is cleanest. `test/t04_fading.json` with `snr_std_dev: 4.0` and many packets sent over a borderline-SNR link. Assert that the rx count is in a range that requires variability — e.g., if rx count is exactly 100/100 OR exactly 0/100, fading isn't doing anything; if it's somewhere in between (say 30..70), fading is working.

A native unit test on the helper itself would be even cleaner:
```cpp
// test/native/test_fading_applied.cpp
#include "core/link/LinkFadingState.h"
#include <cassert>
#include <cstdio>
#include <random>

int main() {
    std::mt19937 rng(42);
    LinkFadingState s{};
    // i.i.d. (coherence=0): each call should produce a different offset
    float a = advanceFading(s, /*std_dev*/4.0f, /*coherence_ms*/0, /*step*/1, rng);
    float b = advanceFading(s, /*std_dev*/4.0f, /*coherence_ms*/0, /*step*/1, rng);
    assert(a != b);
    // OU (coherence=1000, dt small): sequential offsets should be CORRELATED
    // (consecutive draws much closer than independent ones).
    LinkFadingState ou{};
    float prev = advanceFading(ou, 4.0f, 1000, 10, rng);
    float curr = advanceFading(ou, 4.0f, 1000, 10, rng);
    assert(std::abs(curr - prev) < 4.0f);   // within 1 std_dev usually

    std::printf("test_fading_applied: OK (iid pair = %f %f, ou pair = %f %f)\n",
                a, b, prev, curr);
    return 0;
}
```

(Strengthen with a Monte Carlo if you want — generate 1000 i.i.d. samples, check sample std dev is close to expected.)

- [ ] **Step 1.5.4: Commit**

```
feat(loop): apply per-link fading (snr_std_dev) in delivery

LinkFadingState::advanceFading existed since T7 but SimController
never allocated state slots or called it — configs with snr_std_dev
> 0 were silently deterministic. Now allocate n*n directed fading
states (per-direction, not symmetric — flexibility over upstream
FLoRa's reciprocal model) and apply the offset to lp.snr at each
delivery step.

Test: test_fading_applied verifies i.i.d. mode produces uncorrelated
offsets and OU mode produces correlated ones.
```

---

## Task R.1.6 — Wire LBT into TX scheduling (`tx_deferred` event)

**Files:**
- Modify: `orchestrator/runtime/SimController.cpp` — call `lbt.isChannelBusy` before scheduling
- Modify: `core/events/EventLog.{h,cpp}` — add `txDeferred` emitter if not present
- Create: `test/native/test_lbt_defer.cpp` OR JSON integration

**Background:** `LbtModel` is allocated in SimController but `(void)lbt;` follows. The model's CAD-miss interpolation works (per R.1 cross-check), but the loop never consults it. Add a check in `registerTransmissionsForStep`: when a node tries to TX but LBT says channel is busy, drop the TX (or queue with delay; for simplicity drop with `tx_deferred` event).

For the paper, the simpler approach is: drop the pending TX, emit `tx_deferred`, let the script decide how to retry. This avoids implementing a queue + retry mechanism in the runtime.

- [ ] **Step 1.6.1: Consult LBT before scheduling**

In `registerTransmissionsForStep`, BEFORE pushing a new InFlight:

```cpp
if (_lbt->isChannelBusy(i, now)) {
    EventLog::txDeferred(now, nodes[i]->name().c_str(),
                          (int)tx.bytes.size(), "channel_busy");
    // Optionally call the script's on_radio_busy
    nodes[i]->onRadioBusy();
    continue;   // skip pushing the InFlight
}
// ...rest of existing TX scheduling logic...

// After pushing the InFlight, notify LBT so OTHER nodes see the channel busy.
_lbt->notifyChannelBusy(/*observer=*/-1, /*sender=*/i, in_flight.back().end_ms,
                        /*sender_snr_at_observer=*/0.0f);
```

Wait — `notifyChannelBusy` per the existing API takes (observer, sender, until, snr). To make it work, we'd need to call it once per (observer-node, sender-node) pair where the observer can hear the sender. That's heavier. For v1, simplify: track a global "channel busy until" derived from the latest in-flight end time, OR call notifyChannelBusy per-pair using LinkModel's reach data.

Pragmatic choice: per-pair, gated by link existence. If `_links->getLink(sender, observer).snr > -100`, call `notifyChannelBusy` so observer sees the channel busy. Otherwise skip (observer can't hear sender, so it's not affected by sender's TX).

- [ ] **Step 1.6.2: Add `EventLog::txDeferred` if missing**

Read `core/events/EventLog.h`; if `txDeferred` doesn't exist, add it. Field shape: `{"type":"tx_deferred","time_ms":...,"node":"<name>","len":N,"reason":"channel_busy"}`.

- [ ] **Step 1.6.3: Add a focused test**

JSON integration: `test/t05_lbt.json` with two nodes that both try to TX simultaneously. Without LBT, both TXes go on the wire and collide. With LBT, the second one is deferred (assert: at least one `tx_deferred` event).

Pseudo-config:
```json
{
  "_name": "t05_lbt",
  "simulation": { ... },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "carol", "script": "examples/flooder.lua", "config": { "role": "originator" } }
  ],
  "topology": {
    "links": [{ "from": "alice", "to": "carol", "snr": 8.0, "rssi": -80.0, "bidir": true }]
  },
  "commands": [
    { "at_ms": 1000, "node": "alice", "command": "send first" },
    { "at_ms": 1001, "node": "carol", "command": "send second" }
  ],
  "expect": [
    { "type": "event_count_min", "event_type": "tx_deferred", "min": 1 }
  ]
}
```

(The `1000` and `1001` ms ensure overlap — alice's airtime is ~700 ms at SF11/BW250, so carol's TX at 1001ms lands in alice's transmission window → channel busy → deferred.)

- [ ] **Step 1.6.4: Commit**

```
feat(loop): wire LBT — defer TX when channel busy; emit tx_deferred

SimController now calls _lbt->isChannelBusy before scheduling each new
TX. If busy, emit tx_deferred + notify the script via on_radio_busy
and skip the InFlight. The script decides retry policy.

After scheduling a TX, notify LBT for every reachable observer
(per LinkModel) so other nodes see the channel busy.

Test: t05_lbt with two near-simultaneous TXes from different nodes
hearing each other; at least one tx_deferred fires.
```

---

## Acceptance for Phase R.1

After all 6 tasks:

- [ ] All native tests pass (8 existing + ~6 new)
- [ ] All integration tests pass (3 existing + ~3 new = 6)
- [ ] Build clean with `-Wall -Wextra -Wpedantic`
- [ ] Perf smoke t99 still under 5 minutes (probably under 10 seconds)
- [ ] The simulator CAN now express:
  - Cross-SF transmissions don't collide
  - Receivers decode any SF on the same channel
  - Packets below the SF's threshold drop_weak
  - Per-packet preamble override
  - Per-link fading actually applied
  - LBT defers conflicting TXes

This unblocks Phase R.2 (path-loss model) which unblocks Phase R.3 (paper reproduction).

## Order

Tasks are mostly independent except R.1.3 depends on R.1.2 (the static `getSnrThreshold(sf)` overload). Recommended order: R.1.1 → R.1.2 → R.1.3 → R.1.4 → R.1.5 → R.1.6.

R.1.4 (preamble) is a quick win and can be done in parallel with anything. R.1.5 (fading) and R.1.6 (LBT) are also independent of each other and of R.1.3.
