// orchestrator/runtime/ISimHal.h
//
// Slice 5 (faithful two-lib): the NAMESPACE-NEUTRAL Hal surface the sim provides to a firmware Node.
//
// The firmware exists as TWO ODR-distinct static libs (meshroute_core_normal in `namespace meshroute`,
// meshroute_core_gw in `namespace meshroute_gw`). FirmwareNode can't inherit BOTH meshroute::Hal and
// meshroute_gw::Hal, so it implements this single neutral interface instead; a per-variant HalAdapter
// (which IS-A NS::Hal, compiled inside each lib's wrapper TU) forwards every NS::Hal call here.
//
// Only the two non-primitive Hal args cross the boundary as neutral mirrors (SimTxParams / SimEventField);
// everything else is primitive. Keep these structs byte-faithful to lib/core/hal.h's TxParams / EventField.
#pragma once
#include <cstddef>
#include <cstdint>

namespace mrsim {

// Mirror of meshroute::TxParams (hal.h) — the sentinel -1/-127 == "radio default".
struct SimTxParams {
    int16_t  sf           = -1;
    int32_t  bw_hz        = -1;
    int8_t   cr           = -1;
    int8_t   power_dbm    = -127;
    int16_t  preamble_sym = -1;
    uint16_t tag          = 0;        // opaque token echoed in on_radio_busy
    const char* label     = nullptr;  // static-literal telemetry
    const char* info      = nullptr;
};

// Mirror of meshroute::EventField (hal.h). `type`: 0=i64, 1=f64, 2=str, 3=bool (== EventField::T order).
struct SimEventField {
    const char* key  = nullptr;
    uint8_t     type = 0;
    int64_t     i    = 0;
    double      f    = 0.0;
    const char* s    = nullptr;
    bool        b    = false;
};

// TxResult is returned as an int to stay namespace-free: 0=ok, 1=busy, 2=too_long, 3=radio_error
// (== meshroute::TxResult order).
enum SimTxResult : int { kSimTxOk = 0, kSimTxBusy = 1, kSimTxTooLong = 2, kSimTxRadioError = 3 };

// The host services FirmwareNode provides; the per-variant HalAdapter forwards NS::Hal -> here.
class ISimHal {
public:
    virtual ~ISimHal() = default;
    virtual int      simTx(const uint8_t* bytes, size_t len, const SimTxParams& p) = 0;  // -> SimTxResult
    virtual void     simSetRxSf(int sf) = 0;
    virtual void     simSetRxBw(uint32_t /*bw_hz*/) {}   // §metal-fidelity (2026-07-07): track the ACTIVE-layer bw for the slop formula (no-op default -> Lua/idealized path unaffected)
    // §carrier (2026-07-26): retune the node's LIVE RF CARRIER. ★ THE UNIT CHANGES AT THIS SEAM AND THE
    // NAME SAYS SO: the firmware's Hal::set_rx_freq takes a `double` MHz, this takes INTEGER kHz — the
    // sim's reachability gate compares carriers for EXACT equality and a float there is a latent bug.
    // The ONE MHz->kHz rounding is the FIRMWARE's own `protocol::mhz_to_khz`, applied in the per-variant
    // HalAdapter (NodeRuntimeWrapper.cpp) — the only TU allowed to name MESHROUTE_NS. That keeps this
    // interface namespace-neutral AND makes a second, driftable conversion path impossible (U2).
    virtual void     simSetRxFreqKhz(uint32_t /*khz*/) {}
    // §cr-retune (2026-07-26): retune the node's coding rate (5..8). Until this existed, Hal::set_rx_cr's
    // empty no-op default was inherited all the way down, so a gateway with per-layer CR flew BOTH layers
    // at ONE cr in the sim while genuinely retuning on metal — the sim's airtime debit then disagreed
    // with the device's on the non-seed layer.
    virtual void     simSetRxCr(uint8_t /*cr*/) {}
    virtual uint64_t simChannelBusyUntil() = 0;
    virtual uint64_t simAirtimeUsedMs(uint64_t window_ms) = 0;
    virtual uint64_t simOldestTxEndMs() = 0;
    virtual uint32_t simRxWindowSlopMs(int sf) = 0;
    virtual uint64_t simNow() = 0;
    virtual bool     simAfter(uint32_t delay_ms, uint32_t timer_id) = 0;
    virtual void     simCancel(uint32_t timer_id) = 0;
    virtual void     simSetProtocolId(int id) = 0;
    virtual int      simRandRange(int lo, int hi) = 0;
    virtual void     simEmit(const char* type, const SimEventField* fields, size_t n) = 0;
    virtual void     simLog(const char* msg) = 0;
    virtual void     simPanic(const char* why) = 0;
};

}  // namespace mrsim
