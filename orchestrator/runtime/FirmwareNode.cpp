// orchestrator/runtime/FirmwareNode.cpp
#include "orchestrator/runtime/FirmwareNode.h"

#include "core/events/EventLog.h"

#include <utility>

// Node-clock delay -> wall-clock delay, identical to ScriptedNode's helper so
// the C++ firmware experiences the same crystal-drift semantics as the Lua
// model: the node clock runs at (1 + drift) x wall, so a delay of D node-ms
// corresponds to D / (1 + drift) wall-ms.
static inline uint64_t nodeDelayToWallDelay(uint64_t delay_ms, float drift_ppm) {
    if (drift_ppm == 0.0f || delay_ms == 0) return delay_ms;
    const double scale = 1.0 + (double)drift_ppm * 1e-6;
    if (scale <= 0.0) return delay_ms;  // sanity
    const double wall = (double)delay_ms / scale;
    if (wall < 0.0) return 0;
    return (uint64_t)(wall + 0.5);
}

FirmwareNode::FirmwareNode(int id, std::string name, SimRadio& radio,
                           std::ostream& events_out, VirtualClock& clock,
                           std::mt19937& sim_rng)
    : _id(id),
      _protocol_id(id),
      _name(std::move(name)),
      _radio(radio),
      _events_out(events_out),
      _clock(clock),
      _sim_rng(sim_rng) {
    (void)_radio;        // held for S2 (TX/RX through SimRadio); unused here
    (void)_events_out;   // EventLog owns its output stream
    (void)_sim_rng;      // used once the rand() HAL primitive lands (S2)
}

uint64_t FirmwareNode::scheduleAfter(uint64_t delay_ms, std::function<void()> cb) {
    const uint64_t wall_delay = nodeDelayToWallDelay(delay_ms, _clock_drift_ppm);
    TimerHandle h = _timers.scheduleAfter(_clock.getMillis(), wall_delay, /*period=*/0);
    _timer_cbs[h] = std::move(cb);
    return h;
}

void FirmwareNode::emit(const std::string& type, const std::string& json_data) {
    EventLog::logScriptEmit(_id, _clock.getMillis(), type, json_data);
}

// -----------------------------------------------------------------------------
// INode dispatch — S1 skeleton: prove the seam + host time/timer/emit wiring.
// No lib/core, no TX/RX yet (S2).
// -----------------------------------------------------------------------------

void FirmwareNode::onInit(const nlohmann::json& /*config*/) {
    emit("firmware_node_boot", "{\"engine\":\"meshroute\"}");
    // One-shot 1 s tick proves host timer scheduling + firing round-trips.
    scheduleAfter(1000, [this]() { emit("firmware_node_tick"); });
}

void FirmwareNode::onRecv(std::string_view, float, float, int, int, uint64_t) {}
std::string FirmwareNode::onCommand(std::string_view) { return ""; }
void FirmwareNode::onRadioBusy(const RadioBusyInfo&) {}
void FirmwareNode::onPreambleDetected(uint64_t, int, float) {}

void FirmwareNode::tickTimers(uint64_t sim_ms) {
    TimerEntry e{};
    while (_timers.popDue(sim_ms, e)) {
        auto it = _timer_cbs.find(e.handle);
        if (it == _timer_cbs.end()) continue;
        std::function<void()> cb = it->second;   // copy: cb may reschedule/cancel
        if (e.period_ms == 0) _timer_cbs.erase(it);
        cb();
    }
}

std::vector<PendingTx> FirmwareNode::drainPendingTxs() {
    std::vector<PendingTx> out;
    out.swap(_pending_txs);
    return out;
}

void FirmwareNode::recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) {
    _tx_airtime_log.push_back({end_ms, airtime_ms});
}

uint64_t FirmwareNode::airtimeUsedInWindow(uint64_t now, uint64_t window_ms) {
    if (window_ms == 0) return 0;
    const uint64_t cutoff = (now > window_ms) ? (now - window_ms) : 0;
    while (!_tx_airtime_log.empty() && _tx_airtime_log.front().end_ms <= cutoff) {
        _tx_airtime_log.pop_front();
    }
    uint64_t sum = 0;
    for (const auto& e : _tx_airtime_log) sum += e.airtime_ms;
    return sum;
}

uint64_t FirmwareNode::oldestTxEndMs() const {
    if (_tx_airtime_log.empty()) return 0;
    return _tx_airtime_log.front().end_ms;
}
