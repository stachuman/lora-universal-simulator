# S2 — `meshroute::Hal` interface + sim backend wiring (design proposal)

**Date:** 2026-05-29  **Status:** PROPOSAL — revised after review (2026-05-29), no code written.
**Builds on:** S0 (`INode`, `caae8f6`) + S1 (`engine` + `FirmwareNode` skeleton,
`b34355b`). Sim-integration track; see `~/MeshRoute/docs/PORT_PLAN.md` §4 (the S2
row) + §2.1. The MeshCore **device** backend of this same `Hal` is a separate
track (H0–H3) — see
`~/MeshRoute/docs/specs/2026-05-29-h0-meshcore-vendor-and-device-hal-design.md`.

> **Review revisions (2026-05-29):** (1) D-S2a resolved to **B** — sim stays
> C++17; only `meshroute_core` is C++20. (2) Timer model is a **bounded
> timer-id allocator** for dynamic/parameterized timers, not a fixed
> `TimerSlot` enum. (3) `emit` no longer takes a raw JSON c-string — backends
> serialize a bounded structured payload (device may compile it out). (4) Q3
> reverted to a **raw placeholder frame** (real `pack_beacon` is codec-track
> C0/C1) to keep integration and codec failures separable. (5) The `meshroute`
> engine is **build-optional** from the start; `RxMeta.src` is a hint only — the
> Node parses `src` from the frame on both backends.

This is the step where `FirmwareNode` stops being a skeleton and connects to
**real MeshRoute `lib/core` code**, run in-loop against the sim's `SimRadio`.
PORT_PLAN success criterion: *"a `lib/core` node TXes/RXes a raw frame through
the sim's `SimRadio`; static-linked (no dlopen yet)."*

**Touches BOTH repos:** adds `Hal`/`Node` to `MeshRoute/lib/core`, and the
cross-repo build + `FirmwareNode` wiring to `lora-universal-simulator`.

---

## 1. Goal & non-goals

**Goal (S2):** the first end-to-end byte path through the real port —
`lib/core Node → Hal.tx → FirmwareNode → SimController → SimRadio → channel →
peer onRecv → FirmwareNode → Hal-deliver → lib/core Node.on_recv`. Concretely:
1. Define the **`meshroute::Hal`** interface (the C++ form of the host
   contract) + a minimal **`meshroute::Node`** in `lib/core`.
2. **Static-link `lib/core`** into the orchestrator (first cross-repo build).
3. **`FirmwareNode` implements `Hal`** (delegating to the sim's
   `TimerWheel`/`VirtualClock`/`_sim_rng`/`EventLog`/`LbtModel`/`SimRadio`) and
   **owns a `meshroute::Node`**, forwarding the `INode` callbacks to it.
4. Prove TX + RX: two `engine:"meshroute"` nodes exchange a frame.

**Non-goals (deferred):**
- **No real protocol / no real wire format.** The S2 node sends a **raw
  placeholder frame** (fixed bytes). Implementing `pack_beacon` etc. is the
  **codec track (C0/C1)**; keeping it out of S2 means a codec bug can't
  masquerade as an integration bug. (Alternative in §8-Q3.)
- **No `dlopen` plugin** (D7 = static-link first). One MeshRoute version.
- **No `NodeRuntime` base extraction** (still deferred; §8-Q5).
- No gateway/cross-layer, no NV, no crypto.

---

## 2. The cross-repo build (the riskiest part)

`lib/core` has no CMake (PlatformIO `library.json` only) and is **C++20**
(`std::span` in `frame_codec.h`); the simulator is **C++17**. Plan:

- Add a CMake cache var `MESHROUTE_DIR` (default `${CMAKE_SOURCE_DIR}/../MeshRoute`).
  If `lib/core/protocol_constants.h` isn't found there, **warn and build the sim
  without the meshroute engine** (build-optional — see §7), not a hard error.
- New static lib target `meshroute_core` compiling
  `${MESHROUTE_DIR}/lib/core/{airtime,frame_codec,Node}.cpp`, with:
  - **C++20** for that target only (`target_compile_features(meshroute_core PUBLIC cxx_std_20)`),
  - the RF-plan `-D` defines `protocol_constants.h` needs (lifted from
    MeshRoute's `platformio.ini [common]`): `PROTOCOL_VERSION=1`,
    `LORA_FREQ_HZ=869462500`, `LORA_BW_HZ=125000`, `LORA_SF=8`, `LORA_CR=5`,
    `LORA_PREAMBLE_SYM=16`, `LORA_DUTY_CYCLE_PCT=10`,
  - `target_include_directories(meshroute_core PUBLIC ${MESHROUTE_DIR}/lib/core)`.
- `orchestrator` links `meshroute_core` and gains its include dir.

### Decision D-S2a — C++ standard boundary (RESOLVED 2026-05-29: B)
`FirmwareNode.cpp` (simulator, C++17) must include the MeshRoute headers it
drives. Two ways:
- **A: bump the whole simulator to C++20.** One line in the root `CMakeLists.txt`
  (`CMAKE_CXX_STANDARD 20`). Simplest to write, but recompiles **every TU of the
  trusted simulator** under a new standard — blast radius on the repo that *is*
  our verification backbone, for no benefit here.
- **B (CHOSEN): keep sim C++17; only `meshroute_core` is C++20.** The `Hal.h` /
  `Node.h` headers `FirmwareNode` includes are **already C++17-clean** by
  construction (only `<cstdint>`/`<cstddef>`, `const uint8_t*`+`size_t` — no
  `std::span` on the public surface). `frame_codec.h`'s `std::span` stays internal
  to `meshroute_core` .cpp. Mixed C++17/20 objects link fine on one libstdc++, and
  the narrow POD/`const char*` boundary carries no layout-sensitive std types.

**Resolution: B** — zero blast radius on the trusted simulator, and ~free since
the boundary is C++17-clean anyway. (Revisit only if the boundary ever needs a
C++20-only type, which the §3 contract avoids.)

---

## 3. `meshroute::Hal` + `meshroute::Node` — FINALIZED contract (post-review 2026-05-29)

Finalized after the 3-perspective review (MeshCore device-backend mapping ·
full `dv_dual_sf` self:* surface · embedded-C++ critique). Key changes vs the
first draft: added `set_protocol_id` + `oldest_tx_end_ms` (the firmware uses
both); `tx` returns `TxResult` ([[nodiscard]], no exceptions) and `bytes` is
borrow-for-call-only + non-re-entrant; `after` returns `bool` and timer ids are
**caller-allocated from a bounded id pool** (the Node maps a small fixed pool of
ids → logical handler + recovered params, covering *dynamic* timers — per-`(dst,
ctr)` ACK timeouts, RTS retries, cascade-requeue, per-peer liveness — not just
periodic singletons; a fixed `TimerSlot` enum would not fit the 61 Lua sites),
re-arm-by-id, 64-cap;
the 5 callbacks (incl. `on_radio_busy`/`on_preamble_detected`/`on_command`) are
first-class on `Node`; `on_init` takes a **POD `NodeConfig`** (no JSON on
device); `RxMeta.src` demoted to `src_hint` (device parses src from the frame).
`tx_in_flight` / `every` / `peers` / `set_rx_sf_set` are **omitted** —
`dv_dual_sf` never calls them. Header includes only `<cstdint>`/`<cstddef>` (no
RadioLib/Arduino/sol/json/span/function) so both backends include it.

```cpp
// MeshRoute — lib/core/hal.h
#pragma once
#include <cstddef>
#include <cstdint>
namespace meshroute {

enum class TxResult : uint8_t { ok, busy, too_long, radio_error };
enum class BusyReason : uint8_t { channel_busy, self_tx_in_flight, oversized, duty_cycle_exceeded };

struct TxParams {                 // sentinel = use the radio default (RF plan SF8/BW125/CR4/5)
    int16_t sf = -1; int32_t bw_hz = -1; int8_t cr = -1;
    int8_t  power_dbm = -127; int16_t preamble_sym = -1;
    uint16_t    tag   = 0;        // opaque token echoed back in on_radio_busy (heap-free retry match)
    const char* label = nullptr;  // static-literal telemetry (e.g. "RTS"); device may ignore
    const char* info  = nullptr;  // static-literal telemetry; device may ignore
};
struct RxMeta   { float snr_db; float rssi_dbm; uint64_t recv_ms; int8_t src_hint = -1; };
struct BusyInfo { BusyReason reason; uint16_t tag; int16_t sf; uint64_t busy_until_ms; };
struct EventField {               // one telemetry key/value; bounded, heap-free — no JSON in Node
    enum class T : uint8_t { i64, f64, str, boolean };
    const char* key; T type;
    int64_t i = 0; double f = 0; const char* s = nullptr; bool b = false;  // active member per `type`
};

class Hal {
public:
    virtual ~Hal() = default;
    // radio — `bytes` borrowed for the call ONLY (impl copies); NOT re-entrant.
    [[nodiscard]] virtual TxResult tx(const uint8_t* bytes, size_t len, const TxParams& p) = 0;
    virtual void     set_rx_sf(int sf) = 0;            // clamp+ignore out-of-range; arms blind window
    virtual uint64_t channel_busy_until() = 0;         // LBT busy_until ms, or 0
    virtual uint64_t airtime_used_ms(uint64_t window_ms) = 0;
    virtual uint64_t oldest_tx_end_ms() = 0;           // duty-cycle headroom calc
    // time / timers — one-shot, caller-allocated ids, (re)arm-by-id, cap 64
    virtual uint64_t now() = 0;
    [[nodiscard]] virtual bool after(uint32_t delay_ms, uint32_t timer_id) = 0;  // false if full
    virtual void     cancel(uint32_t timer_id) = 0;    // idempotent
    // identity (runtime short-id; key_hash32 is the stable long id, ctor-fixed)
    virtual void     set_protocol_id(int id) = 0;      // clamp [0,255]; join/lease
    // rng / telemetry
    virtual int      rand_range(int lo, int hi) = 0;   // [lo,hi); shared mt19937 + draw order in sim
    // telemetry — the BACKEND serializes. Sim → NDJSON byte-identical to
    // ScriptedNode::api_emit (S3 parity); device may compile emit() to a no-op.
    // Node never formats JSON, so the 274 call sites stay format-agnostic.
    virtual void     emit(const char* type, const EventField* fields, size_t n_fields) = 0;
    virtual void     log(const char* msg) = 0;
    virtual void     panic(const char* why) { (void)why; }   // exception-free fatal hook
};
}  // namespace meshroute
```
```cpp
// MeshRoute — lib/core/node.h   (depends only on hal.h)
#pragma once
#include "hal.h"
#include <cstddef>
#include <cstdint>
namespace meshroute {

struct NodeConfig {               // POD; no heap, no JSON. (T/F-class knobs only;
    bool     is_gateway = false, is_mobile = false, join_required = false;
    bool     req_sync_on_boot = true, seen_bitmap_enabled = true;
    uint8_t  routing_sf = 7;
    uint16_t allowed_sf_bitmap = (1u << 12);   // dv_dual_sf sf_set_to_bitmap
    uint32_t beacon_period_ms = 900000, beacon_max_idle_ms = 900000;
    uint8_t  req_sync_min_routes = 8;
};                                 // PROTOCOL constants stay in protocol_constants.h (hardcoded).

class Node {
public:
    Node(Hal& hal, uint8_t node_id, uint32_t key_hash32, const char* name = nullptr);
    void on_init(const NodeConfig& cfg);                                 // cfg borrowed
    void on_recv(const uint8_t* bytes, size_t len, const RxMeta& meta);  // bytes valid during call only
    void on_timer(uint32_t timer_id);                                    // dispatch on Node-owned id
    void on_radio_busy(const BusyInfo& info);                            // deferred-TX retry/giveup
    void on_preamble_detected(uint64_t time_ms);                         // SX1262 IRQ / throttle witness
    void on_command(const char* cmd, char* out_reply, size_t reply_cap); // returns status in out_reply
private:
    Hal&     _hal;
    uint8_t  _node_id;            // reassignable via _hal.set_protocol_id (join)
    uint32_t _key_hash32;         // stable long identity
    // ... bounded fixed-size state sized by protocol_constants.h cap_* ...
};
}  // namespace meshroute
```

**S2 node behaviour (skeleton):** `on_init` arms one timer; `on_timer` `tx`es a
**raw placeholder frame** (fixed bytes — NOT a real protocol frame) + emits
`mr_node_tx`; `on_recv` emits `mr_node_rx`. The other four callbacks compile as
no-ops in S2. `NodeConfig` is defaulted (wired for real at R1).

### 3.1 No codec in S2 (Q3 reverted: raw frame)
S2 sends a **raw placeholder frame**, so it does NOT touch `frame_codec.h` or
`pack_beacon`. Implementing the §10 cmd-nibble codecs is the **codec track
(C0/C1)** — deliberately kept out of S2 so an integration failure and a codec
failure stay separable (and so C0/C1 can de-risk its test harness on a 3-byte
frame first, per PORT_PLAN §4/D2). NB: `frame_codec.h` still documents the
*stale* pre-rebaseline tag-byte layout (and 3-byte route entries); that header
gets corrected to the §10 layout when C0/C1 starts — not here.

---

## 4. `FirmwareNode` changes (simulator side)

`FirmwareNode` becomes a `meshroute::Hal` implementation that owns a
`meshroute::Node`:
- **implements `Hal`:** `tx` → push a `PendingTx` (S1 already has `_pending_txs`
  + `drainPendingTxs`); `now`/`after`/`cancel` → its `TimerWheel` (drift-scaled,
  as today) but firing now calls `_node->on_timer(id)` instead of an empty stub;
  `rand_range` → `_sim_rng` (the `[lo,hi)` `uniform_int_distribution`, identical
  to `ScriptedNode::api_rand`); `emit(type, fields[])` → serialize fields to JSON
  **byte-identical to `ScriptedNode::api_emit`** (S3 NDJSON parity), `log` →
  `EventLog`; `channel_busy_until` →
  `_lbt`; `airtime_used_ms` → its airtime log; `set_rx_sf` → `*_sf_rx_set` +
  arm blind window (port `ScriptedNode::armSfSwitchBlindWindow`).
- **forwards `INode`:** `onInit` → construct + `_node->on_init()`; `onRecv` →
  `_node->on_recv(bytes,len,{snr,rssi,src,recv_ms})`; `tickTimers` → popDue →
  `_node->on_timer(id)`; `drainPendingTxs` → returns the queue the node filled.
- The S1 `firmware_node_boot`/`firmware_node_tick` skeleton emits are removed
  (superseded by the node's own `mr_node_tx`/`mr_node_rx`); **t82 updates
  accordingly** (or is replaced by t83).

Timer plumbing: S1 stored `std::function` callbacks; S2 switches to mapping
`TimerHandle → timer_id` and dispatching `_node->on_timer(id)`. (Internal to
FirmwareNode; no INode change.)

---

## 5. Verification & test

- **New test `test/t83_firmware_tx_rx.json`:** two `engine:"meshroute"` nodes
  A,B with a good link; A's `on_init` schedules a TX; assert (via
  `script_emit_contains`) **A emits `mr_node_tx`** and **B emits `mr_node_rx`**
  — i.e. the frame crossed the real `SimRadio` channel. Optionally assert the
  received length matches.
- **Existing suite bit-identical:** re-run the S0 baseline set + diff vs
  `/tmp/baseline_s0` → **zero diff** (no existing config uses
  `engine:"meshroute"`; the C++20 bump, if chosen, recompiles everything so this
  also guards against any standard-change behaviour shift).
- **Suite count:** **83/83** (77 t-tests incl. t82+t83 + 6 scenarios).
- **Don't break MeshRoute's own build:** confirm `pio run -e native` / the
  MeshRoute side still compiles (we only *add* `hal.h`/`node.{h,cpp}`; the new
  files must also fit MeshRoute's own build).
- Clean simulator build (incl. the new C++20 `meshroute_core` target).

---

## 6. Files touched (S2)

**MeshRoute:**
| File | Change |
|---|---|
| `lib/core/hal.h` | NEW — the `Hal` interface |
| `lib/core/node.h`, `node.cpp` | NEW — minimal `Node` (raw-frame TX + rx emit) |
| `src/sim_main.cpp` / tests | possibly a unit test for `Node` against a mock Hal (optional) |

**lora-universal-simulator:**
| File | Change |
|---|---|
| `CMakeLists.txt` | `MESHROUTE_DIR` cache var; `meshroute_core` C++20 target + RF `-D`s; (D-S2a: bump to C++20?) |
| `orchestrator/CMakeLists.txt` | link `meshroute_core` + include dir |
| `orchestrator/runtime/FirmwareNode.{h,cpp}` | implement `Hal`, own a `Node`, wire callbacks |
| `test/t82_*` | update/remove skeleton-event assertions |
| `test/t83_firmware_tx_rx.json` | NEW — TX/RX round-trip across two firmware nodes |

---

## 7. Risks

- **Cross-repo coupling:** the sim build references `../MeshRoute`. Mitigation:
  `MESHROUTE_DIR` cache var, and the `meshroute` engine is **build-optional from
  the start** — if `MESHROUTE_DIR` isn't found, configure with a clear warning and
  compile the sim without `meshroute_core` (only `engine:"meshroute"` configs then
  fail, with a clear runtime error). Unrelated sim work never breaks on a
  MeshRoute move, and the Lua-only suite stays buildable standalone.
- **C++ standard:** see D-S2a; bit-identical gate catches any regression from a
  C++20 bump.
- **Determinism:** `FirmwareNode::rand_range` must use the **same** shared
  `_sim_rng` in the same `[lo,hi)` form as `ScriptedNode` so a future
  lua-vs-meshroute differential is meaningful (S3). No RNG draws happen for
  existing lua-only runs, so bit-identicality is unaffected now.

---

## 8. Open questions

1. ~~**D-S2a — C++ standard.**~~ **RESOLVED 2026-05-29: B** — sim stays C++17;
   only `meshroute_core` is C++20 (see §2).
2. **Cross-repo link mechanism:** `MESHROUTE_DIR` cache var → compile
   `lib/core/*.cpp` as a `meshroute_core` static lib (rec). OK, or prefer a
   symlink/submodule?
3. ~~**What S2 sends.**~~ **RESOLVED 2026-05-29: raw placeholder frame** — real
   `pack_beacon` is codec-track C0/C1; keep integration and codec decoupled (§3.1).
4. ~~**Hal timer API.**~~ **RESOLVED 2026-05-29: id-based** `after(delay,
   timer_id)` + `Node::on_timer(id)`, backed by a **bounded id allocator** that
   covers dynamic/parameterized timers (not a fixed enum); no heap.
5. **`NodeRuntime` base:** still defer (rec — keep ScriptedNode untouched) or
   extract now that `FirmwareNode` grows real Hal machinery?
6. **Commit boundary:** one commit, or split S2 into (a) build + Hal + one-way
   TX, then (b) RX round-trip + test?
7. **Hal naming/shape:** any changes to the proposed `Hal`/`Node` interface in §3
   before I build against it? (This is the contract everything downstream uses.)
