// orchestrator/runtime/FirmwareNode.cpp
#include "orchestrator/runtime/FirmwareNode.h"

#include "core/events/EventLog.h"
#include "core/physics/LbtModel.h"

#include <string>
#include <utility>

// Node-clock delay -> wall-clock delay, identical to ScriptedNode's helper so
// the C++ firmware experiences the same crystal-drift semantics as the Lua
// model (node clock runs at (1 + drift) x wall).
static inline uint64_t nodeDelayToWallDelay(uint64_t delay_ms, float drift_ppm) {
    if (drift_ppm == 0.0f || delay_ms == 0) return delay_ms;
    const double scale = 1.0 + (double)drift_ppm * 1e-6;
    if (scale <= 0.0) return delay_ms;
    const double wall = (double)delay_ms / scale;
    if (wall < 0.0) return 0;
    return (uint64_t)(wall + 0.5);
}

FirmwareNode::FirmwareNode(int id, std::string name, uint32_t key_hash32,
                           SimRadio& radio, std::ostream& events_out,
                           VirtualClock& clock, std::mt19937& sim_rng)
    : _id(id),
      _protocol_id(id),
      _name(std::move(name)),
      _key_hash32(key_hash32),
      _radio(radio),
      _events_out(events_out),
      _clock(clock),
      _sim_rng(sim_rng) {
    (void)_radio;        // TX goes via _pending_txs (drained by SimController), not SimRadio directly
    (void)_events_out;   // EventLog owns its output stream
}

// =============================================================================
// INode — driven by SimController; forwards into the owned meshroute::Node
// =============================================================================

void FirmwareNode::onInit(const nlohmann::json& config) {
    (void)config;  // S2: NodeConfig defaulted; real config plumbing at R1.
    meshroute::NodeConfig cfg;  // defaults
    _node = std::make_unique<meshroute::Node>(
        *this, static_cast<uint8_t>(_protocol_id), _key_hash32, _name.c_str());
    _node->on_init(cfg);
}

void FirmwareNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, int src_id, uint64_t sim_ms) {
    (void)link_id;
    if (!_initialized || !_node) return;
    meshroute::RxMeta meta{snr, rssi, sim_ms, static_cast<int8_t>(src_id)};
    _node->on_recv(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), meta);
}

std::string FirmwareNode::onCommand(std::string_view cmd_str) {
    if (!_initialized || !_node) return "ERROR: node not initialized yet";
    char reply[256] = {0};
    std::string cmd(cmd_str);  // ensure null-terminated for the C ABI
    _node->on_command(cmd.c_str(), reply, sizeof(reply));
    return std::string(reply);
}

void FirmwareNode::onRadioBusy(const RadioBusyInfo& info) {
    if (!_initialized || !_node) return;
    meshroute::BusyReason reason = meshroute::BusyReason::channel_busy;
    if      (info.reason == "self_tx_in_flight")    reason = meshroute::BusyReason::self_tx_in_flight;
    else if (info.reason == "oversized")            reason = meshroute::BusyReason::oversized;
    else if (info.reason == "duty_cycle_exceeded")  reason = meshroute::BusyReason::duty_cycle_exceeded;
    meshroute::BusyInfo bi{reason, /*tag=*/0,
                           static_cast<int16_t>(info.sf), info.busy_until_ms};
    _node->on_radio_busy(bi);
}

void FirmwareNode::onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) {
    (void)from_id; (void)snr_db;
    if (!_initialized || !_node) return;
    _node->on_preamble_detected(time_ms);
}

void FirmwareNode::tickTimers(uint64_t sim_ms) {
    TimerEntry e{};
    while (_timers.popDue(sim_ms, e)) {
        auto it = _handle_to_id.find(e.handle);
        if (it == _handle_to_id.end()) continue;   // cancelled/stale
        const uint32_t timer_id = it->second;
        if (e.period_ms == 0) {                      // one-shot: clear the maps before firing
            _handle_to_id.erase(it);
            _id_to_handle.erase(timer_id);
        }
        if (_node) _node->on_timer(timer_id);
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

void FirmwareNode::armSfSwitchBlindWindow() {
    if (_sf_switch_delay_ms <= 0.0f) return;
    const uint64_t now = _clock.getMillis();
    const uint64_t blind_end = now + (uint64_t)(_sf_switch_delay_ms + 0.5f);
    if (blind_end > _rx_blind_until_ms) _rx_blind_until_ms = blind_end;
}

// =============================================================================
// meshroute::Hal — called by the owned meshroute::Node
// =============================================================================

meshroute::TxResult FirmwareNode::tx(const uint8_t* bytes, size_t len,
                                     const meshroute::TxParams& p) {
    if (len > 255) return meshroute::TxResult::too_long;  // SX1262 length register
    PendingTx t;
    t.bytes.assign(reinterpret_cast<const char*>(bytes), len);
    t.sf           = p.sf;
    t.bw_hz        = p.bw_hz;
    t.cr           = p.cr;
    t.power_dbm    = (p.power_dbm == -127) ? -127 : p.power_dbm;
    t.preamble_sym = p.preamble_sym;
    if (p.label) t.label = p.label;
    if (p.info)  t.info  = p.info;
    _pending_txs.push_back(std::move(t));
    return meshroute::TxResult::ok;
}

void FirmwareNode::set_rx_sf(int sf) {
    if (!_sf_rx_set) return;
    if (sf < 5) sf = 5;
    if (sf > 12) sf = 12;
    *_sf_rx_set = { sf };
    armSfSwitchBlindWindow();
}

uint64_t FirmwareNode::channel_busy_until() {
    return _lbt ? _lbt->busyUntil(_id) : 0;
}

uint64_t FirmwareNode::airtime_used_ms(uint64_t window_ms) {
    return airtimeUsedInWindow(_clock.getMillis(), window_ms);
}

uint64_t FirmwareNode::oldest_tx_end_ms() { return oldestTxEndMs(); }

uint64_t FirmwareNode::now() {
    const uint64_t wall = _clock.getMillis();
    if (_clock_drift_ppm == 0.0f) return wall;
    const double drifted = (double)wall * (1.0 + (double)_clock_drift_ppm * 1e-6);
    if (drifted < 0.0) return 0;
    return (uint64_t)(drifted + 0.5);
}

bool FirmwareNode::after(uint32_t delay_ms, uint32_t timer_id) {
    // Re-arm semantics: arming an already-pending id reschedules it.
    auto existing = _id_to_handle.find(timer_id);
    if (existing != _id_to_handle.end()) {
        _timers.cancel(existing->second);
        _handle_to_id.erase(existing->second);
        _id_to_handle.erase(existing);
    }
    if (_id_to_handle.size() >= kMaxTimers) return false;
    const uint64_t wall = nodeDelayToWallDelay(delay_ms, _clock_drift_ppm);
    TimerHandle h = _timers.scheduleAfter(_clock.getMillis(), wall, /*period=*/0);
    _id_to_handle[timer_id] = h;
    _handle_to_id[h] = timer_id;
    return true;
}

void FirmwareNode::cancel(uint32_t timer_id) {
    auto it = _id_to_handle.find(timer_id);
    if (it == _id_to_handle.end()) return;
    _timers.cancel(it->second);
    _handle_to_id.erase(it->second);
    _id_to_handle.erase(it);
}

void FirmwareNode::set_protocol_id(int id) {
    if (id < 0) id = 0;
    if (id > 255) id = 255;
    _protocol_id = id;
}

int FirmwareNode::rand_range(int lo, int hi) {
    if (hi <= lo) return lo;
    std::uniform_int_distribution<int> dist(lo, hi - 1);
    return dist(_sim_rng);
}

void FirmwareNode::emit(const char* type, const meshroute::EventField* fields, size_t n) {
    // Serialize the structured fields to JSON byte-identically to
    // ScriptedNode::api_emit (nlohmann::json::dump) so S3 NDJSON parity holds.
    nlohmann::json j = nlohmann::json::object();
    for (size_t k = 0; k < n; ++k) {
        const auto& f = fields[k];
        switch (f.type) {
            case meshroute::EventField::T::i64:     j[f.key] = f.i; break;
            case meshroute::EventField::T::f64:     j[f.key] = f.f; break;
            case meshroute::EventField::T::str:     j[f.key] = (f.s ? f.s : ""); break;
            case meshroute::EventField::T::boolean: j[f.key] = f.b; break;
        }
    }
    EventLog::logScriptEmit(_id, _clock.getMillis(), type, j.dump());
}

void FirmwareNode::log(const char* msg) {
    EventLog::logScriptLog(_id, _clock.getMillis(), msg ? msg : "");
}

void FirmwareNode::panic(const char* why) {
    EventLog::logScriptLog(_id, _clock.getMillis(),
                           std::string("PANIC: ") + (why ? why : "?"));
}
