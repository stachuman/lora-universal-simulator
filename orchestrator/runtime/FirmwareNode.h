// orchestrator/runtime/FirmwareNode.h
//
// FirmwareNode is the INode implementation that will host the MeshRoute C++
// firmware run in-loop inside the simulator (sim-integration track; see
// ~/MeshRoute/docs/PORT_PLAN.md §2.1).
//
// S1 ships a SKELETON: it proves the seam — a non-Lua node type plugs into
// SimController beside ScriptedNode and is driven by the host clock / timers /
// emit path — WITHOUT yet depending on MeshRoute/lib/core or doing any TX/RX
// (that is S2). On onInit it emits a boot event and schedules one 1 s tick.
//
// Design (S1): composition over a shared base. FirmwareNode owns its own
// TimerWheel + airtime-log (reusing the TimerWheel class and matching
// ScriptedNode's drift semantics). ScriptedNode is left untouched, so the Lua
// path stays bit-identical. A NodeRuntime base may be extracted post-S2, once
// both implementations are fleshed out and the genuinely-shared surface is
// clear.

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "orchestrator/runtime/INode.h"
#include "orchestrator/runtime/TimerWheel.h"

#include <cstdint>
#include <deque>
#include <functional>
#include <ostream>
#include <random>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

class FirmwareNode : public INode {
public:
    FirmwareNode(int id, std::string name, SimRadio& radio,
                 std::ostream& events_out, VirtualClock& clock,
                 std::mt19937& sim_rng);

    // ---- INode dispatch ------------------------------------------------
    void onInit(const nlohmann::json& config) override;
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, int src_id, uint64_t sim_ms) override;
    std::string onCommand(std::string_view cmd_str) override;
    void onRadioBusy(const RadioBusyInfo& info) override;
    void onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) override;

    // ---- per-step ------------------------------------------------------
    void tickTimers(uint64_t sim_ms) override;
    std::vector<PendingTx> drainPendingTxs() override;

    // ---- lifecycle gate ------------------------------------------------
    void markInitialized() override { _initialized = true; }
    bool isInitialized() const override { return _initialized; }

    // ---- identity ------------------------------------------------------
    int  protocolId() const override { return _protocol_id; }
    void setProtocolId(int protocol_id) override { _protocol_id = protocol_id; }
    const std::string& name() const override { return _name; }

    // ---- one-time wiring set by SimController::initialize() -------------
    void attachSfRxSet(std::vector<int>* slot) override { _sf_rx_set = slot; }
    void attachTxInFlightSlot(uint64_t* slot) override { _tx_in_flight_until = slot; }
    void attachLbtModel(LbtModel* lbt) override { _lbt = lbt; }
    void setClockDriftPpm(float ppm) override { _clock_drift_ppm = ppm; }
    void setSfSwitchDelayMs(float ms) override { _sf_switch_delay_ms = ms; }

    // ---- radio-state / duty-cycle queried by the per-step pipeline -----
    void     recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) override;
    uint64_t airtimeUsedInWindow(uint64_t now, uint64_t window_ms) override;
    uint64_t oldestTxEndMs() const override;
    uint64_t rxBlindUntilMs() const override { return _rx_blind_until_ms; }

private:
    // Host-contract helpers. scheduleAfter applies the same node-clock drift
    // scaling as ScriptedNode::api_after so the firmware sees the same timing.
    uint64_t scheduleAfter(uint64_t delay_ms, std::function<void()> cb);
    void     emit(const std::string& type, const std::string& json_data = "{}");

    int               _id;
    int               _protocol_id;
    std::string       _name;
    SimRadio&         _radio;          // for S2 (TX/RX); unused in the skeleton
    std::ostream&     _events_out;     // EventLog owns its own stream
    VirtualClock&     _clock;
    std::mt19937&     _sim_rng;        // for S2 (rand); unused in the skeleton
    TimerWheel        _timers;
    std::unordered_map<TimerHandle, std::function<void()>> _timer_cbs;
    std::vector<PendingTx> _pending_txs;   // empty until S2 wires TX
    bool              _initialized = false;
    std::vector<int>* _sf_rx_set = nullptr;
    uint64_t*         _tx_in_flight_until = nullptr;
    LbtModel*         _lbt = nullptr;
    float             _clock_drift_ppm = 0.0f;
    uint64_t          _rx_blind_until_ms = 0;
    float             _sf_switch_delay_ms = 0.0f;
    struct TxAirtimeRec { uint64_t end_ms; uint32_t airtime_ms; };
    std::deque<TxAirtimeRec> _tx_airtime_log;
};
