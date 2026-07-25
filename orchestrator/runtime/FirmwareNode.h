// orchestrator/runtime/FirmwareNode.h
//
// FirmwareNode runs the real MeshRoute C++ firmware in-loop inside the simulator
// (sim-integration track; ~/MeshRoute/docs/PORT_PLAN.md §2.1). It is BOTH:
//   - an INode (the surface SimController drives each step), and
//   - a mrsim::ISimHal (the NAMESPACE-NEUTRAL host services the firmware calls into).
// It owns a mrsim::INodeRuntime (a per-variant handle to a meshroute::Node OR a
// meshroute_gw::Node — Slice 5 faithful two-lib) and bridges the two: INode callbacks
// → INodeRuntime methods; the Node's Hal calls → the simulator's TimerWheel /
// VirtualClock / _sim_rng / EventLog / LbtModel / pending-tx queue, via ISimHal.
//
// Slice 5: FirmwareNode is NAMESPACE-NEUTRAL — it never names meshroute::/meshroute_gw::
// types. The two ODR-distinct firmware libs (meshroute_core_normal / meshroute_core_gw)
// each compile a wrapper TU that adapts ISimHal<->NS::Hal and INodeRuntime<->NS::Node;
// FirmwareNode binds the variant a scenario asks for (n_layers==2 => the gateway lib).
//
// Compiled only when the build found MeshRoute (MESHROUTE_ENABLED). The sim stays C++17;
// the contract headers are C++17-clean (no NS:: firmware type leaks in).
//
// Design (S1/S2): composition, no shared base. FirmwareNode owns its own TimerWheel +
// airtime log (reuses the TimerWheel class, matches ScriptedNode's drift semantics).
// ScriptedNode is untouched, so the Lua path is bit-identical.

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "orchestrator/runtime/INode.h"
#include "orchestrator/runtime/INodeRuntime.h"   // mrsim::INodeRuntime + the per-variant factories
#include "orchestrator/runtime/ISimHal.h"        // mrsim::ISimHal (the neutral host surface)
#include "orchestrator/runtime/TimerWheel.h"

#include <cstdint>
#include <deque>
#include <memory>
#include <ostream>
#include <random>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

class FirmwareNode : public INode, public mrsim::ISimHal {
public:
    FirmwareNode(int id, std::string name, uint32_t key_hash32, SimRadio& radio,
                 std::ostream& events_out, VirtualClock& clock, std::mt19937& sim_rng);

    // ---- INode (driven by SimController) -------------------------------
    void onInit(const nlohmann::json& config) override;
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, int src_id, uint64_t sim_ms) override;
    std::string onCommand(std::string_view cmd_str) override;
    void onRadioBusy(const RadioBusyInfo& info) override;
    void onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) override;
    void tickTimers(uint64_t sim_ms) override;
    std::vector<PendingTx> drainPendingTxs() override;
    void markInitialized() override { _initialized = true; }
    bool isInitialized() const override { return _initialized; }
    int  protocolId() const override { return _protocol_id; }
    void setProtocolId(int protocol_id) override { _protocol_id = protocol_id; }
    const std::string& name() const override { return _name; }
    void attachSfRxSet(std::vector<int>* slot) override { _sf_rx_set = slot; }
    void attachRxBwSlot(int* slot) override { _rx_bw_hz = slot; }   // live RX BW (Hz); written by simSetRxBw
    void attachTxInFlightSlot(uint64_t* slot) override { _tx_in_flight_until = slot; }
    void attachLbtModel(LbtModel* lbt) override { _lbt = lbt; }
    void setClockDriftPpm(float ppm) override { _clock_drift_ppm = ppm; }
    void setSfSwitchDelayMs(float ms) override { _sf_switch_delay_ms = ms; }
    // R3.x: host knob (config "lbt_enabled", default true). Read by the sim's
    // LBT-defer gate so a lossy gate can run with LBT off.
    bool lbtEnabled() const override { return _lbt_enabled; }
    void     recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) override;
    uint64_t airtimeUsedInWindow(uint64_t now, uint64_t window_ms) override;
    uint64_t oldestTxEndMs() const override;
    uint64_t rxBlindUntilMs() const override { return _rx_blind_until_ms; }

    // ---- mrsim::ISimHal (called by the per-variant HalAdapter wrapping the Node) ----
    int      simTx(const uint8_t* bytes, size_t len, const mrsim::SimTxParams& p) override;  // -> SimTxResult
    void     simSetRxSf(int sf) override;
    void     simSetRxBw(uint32_t bw_hz) override;   // the device _def_bw mirror: moves the slop bw, the live RX bw, AND the radio's default TX bw
    uint64_t simChannelBusyUntil() override;
    uint64_t simAirtimeUsedMs(uint64_t window_ms) override;
    uint64_t simOldestTxEndMs() override;
    uint32_t simRxWindowSlopMs(int sf) override;
    uint64_t simNow() override;
    bool     simAfter(uint32_t delay_ms, uint32_t timer_id) override;
    void     simCancel(uint32_t timer_id) override;
    void     simSetProtocolId(int id) override;
    int      simRandRange(int lo, int hi) override;
    void     simEmit(const char* type, const mrsim::SimEventField* fields, size_t n) override;
    void     simLog(const char* msg) override;
    void     simPanic(const char* why) override;

private:
    void     armSfSwitchBlindWindow();
    void     drainPushes();          // pull the Node's async push ring -> telemetry
    uint64_t nowWall() const { return _clock.getMillis(); }

    int               _id;
    int               _protocol_id;
    std::string       _name;
    uint32_t          _key_hash32;
    SimRadio&         _radio;          // == SimController::_radios[_id]; retuned by simSetRxBw (the device _def_bw mirror)
    std::ostream&     _events_out;     // EventLog owns its own stream
    VirtualClock&     _clock;
    std::mt19937&     _sim_rng;
    TimerWheel        _timers;
    // Bounded timer-id allocator: the Node owns the id namespace; we map id ↔
    // TimerWheel handle so after() can re-arm-by-id and cancel(id) works.
    std::unordered_map<uint32_t, TimerHandle> _id_to_handle;
    std::unordered_map<TimerHandle, uint32_t> _handle_to_id;
    std::vector<PendingTx> _pending_txs;
    bool              _initialized = false;
    std::vector<int>* _sf_rx_set = nullptr;
    int*              _rx_bw_hz  = nullptr;   // borrowed; SimController::_node_rx_bw_hz slot (live RX BW)
    uint64_t*         _tx_in_flight_until = nullptr;
    LbtModel*         _lbt = nullptr;
    bool              _lbt_enabled = true;   // R3.x host knob (config "lbt_enabled")
    float             _clock_drift_ppm = 0.0f;
    uint64_t          _rx_blind_until_ms = 0;
    float             _sf_switch_delay_ms = 0.0f;
    bool              _rx_window_slop_metal = true;
    int               _node_bw_hz = 62500;             //   the node's BW (from _sim_bw_hz), for the slop formula ((1<<sf)*1000)/bw + 1 + 50
    float             _snr_report_ceiling_db = 12.0f;  // §snr-unification A: report-only SNR saturation ceiling (config _sim_snr_report_ceiling_db; huge = disable)
    struct TxAirtimeRec { uint64_t end_ms; uint32_t airtime_ms; };
    std::deque<TxAirtimeRec> _tx_airtime_log;
    // The firmware Node, behind a namespace-neutral handle. The factory (normal vs gw,
    // chosen in onInit from n_layers) binds the right lib's wrapper. Declared LAST so it
    // is destroyed FIRST — before _name (whose c_str() the Node borrows) and the timers.
    std::unique_ptr<mrsim::INodeRuntime> _runtime;
    static constexpr size_t kMaxTimers = 64;   // matches MeshCore MAX_PENDING_TIMERS_PER_NODE
};
