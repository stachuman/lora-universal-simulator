// orchestrator/runtime/FirmwareNode.cpp
#include "orchestrator/runtime/FirmwareNode.h"

#include "core/events/EventLog.h"
#include "core/physics/LbtModel.h"
#include "orchestrator/runtime/SnrReport.h"   // §snr-unification A: the pure report-SNR shaper (single choke point below)

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
// INode — driven by SimController; forwards into the owned mrsim::INodeRuntime
// (which wraps a meshroute::Node or a meshroute_gw::Node, per the chosen variant)
// =============================================================================

void FirmwareNode::onInit(const nlohmann::json& config) {
    // Host-side LBT knob: gates simChannelBusyUntil() (the sim's own LBT primitive). The FIRMWARE-side
    // cfg.lbt_enabled (the node's tx_initiating/tx_flood pre-check) is read in the wrapper; both mirror
    // the same config key (Lua parity). Read it here because it lives on FirmwareNode, not in the Node.
    if (config.is_object())
        _lbt_enabled = config.value("lbt_enabled", _lbt_enabled);
    // §metal-fidelity (2026-07-07): opt-in metal RX-window slop (default "idealized" -> simRxWindowSlopMs returns 0
    // -> s18 byte-identical). _sim_bw_hz is injected by SimController alongside; used by the device slop formula.
    if (config.is_object()) {
        _rx_window_slop_metal = (config.value("_sim_rx_window_slop", std::string("metal")) == "metal");
        _node_bw_hz = config.value("_sim_bw_hz", _node_bw_hz);
        // §snr-unification A: the receiver-report SNR ceiling (SimController injects it from
        // simulation.radio.snr_report_ceiling_db; default +12). Read once at init.
        _snr_report_ceiling_db = config.value("_sim_snr_report_ceiling_db", _snr_report_ceiling_db);
    }
    // Bind the firmware variant the scenario asks for: n_layers==2 => the GATEWAY lib (a second LayerRuntime;
    // the normal lib hard-REFUSES n_layers==2). Default 1 => the normal lib. setProtocolId() ran before
    // onInit, so _protocol_id is the firmware node_id the factory seeds the Node with.
    const unsigned n_layers = config.is_object() ? config.value("n_layers", 1u) : 1u;
    // Fail loud on a malformed layer count BEFORE the uint8_t narrowing in the wrapper: a domain is exactly
    // {1 = normal, 2 = gateway} (§0.1). Guarding the RAW unsigned catches both the obvious out-of-range (3, 300)
    // AND the truncation-alias trap (e.g. 258 -> uint8_t 2 would otherwise look like a valid gateway).
    if (n_layers < 1 || n_layers > 2) {
        EventLog::logScriptLog(_id, _clock.getMillis(),
            "FATAL: meshroute config n_layers out of range [1,2] (got " + std::to_string(n_layers) +
            "); node left inert");
        return;   // _runtime stays null -> onRecv/onCommand/onTimer are no-ops
    }
    _runtime.reset(n_layers >= 2
        ? mrsim::makeNodeRuntimeGw(_protocol_id, _name.c_str(), _key_hash32, *this)
        : mrsim::makeNodeRuntimeNormal(_protocol_id, _name.c_str(), _key_hash32, *this));
    const bool ok = _runtime->onInit(config);
    if (!ok) {
        // Fail loud (STANDING RULE): a refused config (bad dual-layer gateway, §3.2) must be visible — the
        // node will NOT function. Make it inert (null the runtime so onRecv/onCommand/onTimer are no-ops) and
        // scream in the log so a scenario/expect catches it, instead of silently driving a blank default node.
        EventLog::logScriptLog(_id, _clock.getMillis(),
            "FATAL: meshroute on_init REFUSED the config (bad dual-layer gateway? n_layers/layers[] invalid)");
        _runtime.reset();
    }
}

void FirmwareNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, int src_id, uint64_t sim_ms) {
    (void)link_id;
    // god-view sender id intentionally discarded: real LoRa carries no link source,
    // so the firmware must run with src_hint = -1 (unknown) exactly as it does on metal.
    (void)src_id;
    if (!_initialized || !_runtime) return;
    // §snr-unification A: the firmware sees the SX126x-REPORTED SNR (saturated + q4-quantized),
    // never the raw channel SNR. Physics already ran on the true value upstream in SimController.
    _runtime->onRecv(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(),
                     mrsim::shapeReportedSnr(snr, _snr_report_ceiling_db), rssi, /*src_hint=*/-1, sim_ms);
}

std::string FirmwareNode::onCommand(std::string_view cmd_str) {
    if (!_initialized || !_runtime) return "ERROR: node not initialized yet";
    // The sim TRANSPORT parses its command string into a typed Command inside the wrapper (lib/core never
    // sees a command string). SimController has already resolved name -> id.
    return _runtime->onCommand(cmd_str);
}

void FirmwareNode::onRadioBusy(const RadioBusyInfo& info) {
    if (!_initialized || !_runtime) return;
    // The reason-string -> BusyReason mapping + BusyInfo build happen in the wrapper (the firmware enum is
    // namespace-bound); pass the neutral primitives across.
    _runtime->onRadioBusy(info.reason.c_str(), info.tag,
                          static_cast<int16_t>(info.sf), info.busy_until_ms);
}

void FirmwareNode::onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) {
    if (!_initialized || !_runtime) return;
    // §snr-unification A: preamble-detect SNR is a report too — same saturation + quantization.
    _runtime->onPreambleDetected(time_ms, from_id, mrsim::shapeReportedSnr(snr_db, _snr_report_ceiling_db));
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
        if (_runtime) _runtime->onTimer(timer_id);
    }
    drainPushes();   // surface the Node's async app-channel pushes as telemetry
}

void FirmwareNode::drainPushes() {
    if (!_runtime) return;
    // The wrapper formats each Push to one NDJSON payload (kind/ctr/dst[,origin,payload]); we wrap it as a
    // "push" script_emit byte-identically to the legacy inline drain.
    _runtime->drainPushes([this](std::string_view ndjson_payload) {
        EventLog::logScriptEmit(_id, _clock.getMillis(), "push", std::string(ndjson_payload));
    });
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
// mrsim::ISimHal — called by the per-variant HalAdapter wrapping the Node. The
// bodies are unchanged from the legacy meshroute::Hal impl; only the names +
// the neutral Sim* parameter/return types differ.
// =============================================================================

int FirmwareNode::simTx(const uint8_t* bytes, size_t len, const mrsim::SimTxParams& p) {
    if (len > 255) return mrsim::kSimTxTooLong;  // SX1262 length register
    PendingTx t;
    t.bytes.assign(reinterpret_cast<const char*>(bytes), len);
    t.sf           = p.sf;
    t.bw_hz        = p.bw_hz;
    t.cr           = p.cr;
    t.power_dbm    = (p.power_dbm == -127) ? -127 : p.power_dbm;
    t.preamble_sym = p.preamble_sym;
    if (p.label) t.label = p.label;
    if (p.info)  t.info  = p.info;
    t.tag = p.tag;                                  // R4.5b: carry the frame-type tag for on_radio_busy
    _pending_txs.push_back(std::move(t));
    return mrsim::kSimTxOk;
}

void FirmwareNode::simSetRxSf(int sf) {
    if (!_sf_rx_set) return;
    if (sf < 5) sf = 5;
    if (sf > 12) sf = 12;
    *_sf_rx_set = { sf };
    armSfSwitchBlindWindow();
}

void FirmwareNode::simSetRxBw(uint32_t bw_hz) {
    // §metal-fidelity (2026-07-07): mirror device_radio.h:216 (_def_bw <- bw). simRxWindowSlopMs reads _node_bw_hz, so
    // a GATEWAY's per-layer 62.5<->125 kHz switch now moves the slop to the ACTIVE layer (was frozen at the layer-0 seed).
    if (bw_hz > 0) _node_bw_hz = static_cast<int>(bw_hz);
}

uint64_t FirmwareNode::simChannelBusyUntil() {
    // Gate-1: honour the lbt_enabled host knob so a disabled-LBT gate reports an
    // idle channel (the firmware LBT then never defers on the sim primitive).
    return (_lbt_enabled && _lbt) ? _lbt->busyUntil(_id) : 0;
}

uint64_t FirmwareNode::simAirtimeUsedMs(uint64_t window_ms) {
    return airtimeUsedInWindow(_clock.getMillis(), window_ms);
}

uint64_t FirmwareNode::simOldestTxEndMs() { return oldestTxEndMs(); }

uint32_t FirmwareNode::simRxWindowSlopMs(int sf) {
    // The idealized sim has no extra data-SF RX-window slop (no s18 regression); the device HAL returns the
    // bench-measured slop. Matches the meshroute::Hal default (return 0). §metal-fidelity (2026-07-07): a scenario
    // can opt into the DEVICE formula (mirror lib/hal/device_hal.h) so the CTS-wait metal turnaround surfaces —
    // default idealized (0) keeps s18 byte-identical + every existing baseline unchanged.
    if (_rx_window_slop_metal && _node_bw_hz > 0)
        return static_cast<uint32_t>(((1u << sf) * 1000u) / static_cast<uint32_t>(_node_bw_hz) + 1u + 50u);
    (void)sf;
    return 0;
}

uint64_t FirmwareNode::simNow() {
    const uint64_t wall = _clock.getMillis();
    if (_clock_drift_ppm == 0.0f) return wall;
    const double drifted = (double)wall * (1.0 + (double)_clock_drift_ppm * 1e-6);
    if (drifted < 0.0) return 0;
    return (uint64_t)(drifted + 0.5);
}

bool FirmwareNode::simAfter(uint32_t delay_ms, uint32_t timer_id) {
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

void FirmwareNode::simCancel(uint32_t timer_id) {
    auto it = _id_to_handle.find(timer_id);
    if (it == _id_to_handle.end()) return;
    _timers.cancel(it->second);
    _handle_to_id.erase(it->second);
    _id_to_handle.erase(it);
}

void FirmwareNode::simSetProtocolId(int id) {
    if (id < 0) id = 0;
    if (id > 255) id = 255;
    _protocol_id = id;
}

int FirmwareNode::simRandRange(int lo, int hi) {
    if (hi <= lo) return lo;
    std::uniform_int_distribution<int> dist(lo, hi - 1);
    return dist(_sim_rng);
}

void FirmwareNode::simEmit(const char* type, const mrsim::SimEventField* fields, size_t n) {
    // Serialize the structured fields to JSON byte-identically to ScriptedNode::api_emit
    // (nlohmann::json::dump) so S3 NDJSON parity holds. type codes: 0=i64,1=f64,2=str,3=bool.
    nlohmann::json j = nlohmann::json::object();
    for (size_t k = 0; k < n; ++k) {
        const auto& f = fields[k];
        switch (f.type) {
            case 0:  j[f.key] = f.i; break;
            case 1:  j[f.key] = f.f; break;
            case 2:  j[f.key] = (f.s ? f.s : ""); break;
            case 3:  j[f.key] = f.b; break;
            default: break;
        }
    }
    EventLog::logScriptEmit(_id, _clock.getMillis(), type, j.dump());
}

void FirmwareNode::simLog(const char* msg) {
    EventLog::logScriptLog(_id, _clock.getMillis(), msg ? msg : "");
}

void FirmwareNode::simPanic(const char* why) {
    EventLog::logScriptLog(_id, _clock.getMillis(),
                           std::string("PANIC: ") + (why ? why : "?"));
}
