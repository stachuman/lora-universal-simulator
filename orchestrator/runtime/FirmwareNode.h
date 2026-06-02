// orchestrator/runtime/FirmwareNode.h
//
// FirmwareNode runs the real MeshRoute C++ firmware (lib/core meshroute::Node)
// in-loop inside the simulator (sim-integration track; ~/MeshRoute/docs/PORT_PLAN.md
// §2.1). It is BOTH:
//   - an INode (the surface SimController drives each step), and
//   - a meshroute::Hal (the host contract the meshroute::Node calls into).
// It owns a meshroute::Node and bridges the two: INode callbacks → Node methods;
// Node's Hal calls → the simulator's TimerWheel / VirtualClock / _sim_rng /
// EventLog / LbtModel / pending-tx queue.
//
// Compiled only when the build found MeshRoute (MESHROUTE_ENABLED); the Hal/Node
// headers come from meshroute_core's include dir. The sim stays C++17 — the
// meshroute headers are C++17-clean (D-S2a = B).
//
// Design (S1/S2): composition, no shared base. FirmwareNode owns its own
// TimerWheel + airtime log (reuses the TimerWheel class, matches ScriptedNode's
// drift semantics). ScriptedNode is untouched, so the Lua path is bit-identical.

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "orchestrator/runtime/INode.h"
#include "orchestrator/runtime/TimerWheel.h"

#include "hal.h"    // meshroute::Hal  (from meshroute_core include dir)
#include "node.h"   // meshroute::Node

#include <cstdint>
#include <deque>
#include <memory>
#include <ostream>
#include <random>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

class FirmwareNode : public INode, public meshroute::Hal {
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

    // ---- meshroute::Hal (called by the owned meshroute::Node) ----------
    [[nodiscard]] meshroute::TxResult tx(const uint8_t* bytes, size_t len,
                                         const meshroute::TxParams& p) override;
    void     set_rx_sf(int sf) override;
    uint64_t channel_busy_until() override;
    uint64_t airtime_used_ms(uint64_t window_ms) override;
    uint64_t oldest_tx_end_ms() override;
    uint64_t now() override;
    [[nodiscard]] bool after(uint32_t delay_ms, uint32_t timer_id) override;
    void     cancel(uint32_t timer_id) override;
    void     set_protocol_id(int id) override;
    int      rand_range(int lo, int hi) override;
    void     emit(const char* type, const meshroute::EventField* fields, size_t n_fields) override;
    void     log(const char* msg) override;
    void     panic(const char* why) override;

private:
    void     armSfSwitchBlindWindow();
    void     drainPushes();          // pull the Node's async push ring -> telemetry
    uint64_t nowWall() const { return _clock.getMillis(); }

    int               _id;
    int               _protocol_id;
    std::string       _name;
    uint32_t          _key_hash32;
    SimRadio&         _radio;          // held for parity with ScriptedNode; unused in S2 path
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
    uint64_t*         _tx_in_flight_until = nullptr;
    LbtModel*         _lbt = nullptr;
    bool              _lbt_enabled = true;   // R3.x host knob (config "lbt_enabled")
    float             _clock_drift_ppm = 0.0f;
    uint64_t          _rx_blind_until_ms = 0;
    float             _sf_switch_delay_ms = 0.0f;
    struct TxAirtimeRec { uint64_t end_ms; uint32_t airtime_ms; };
    std::deque<TxAirtimeRec> _tx_airtime_log;
    std::unique_ptr<meshroute::Node> _node;
    static constexpr size_t kMaxTimers = 64;   // matches MeshCore MAX_PENDING_TIMERS_PER_NODE
};
